local NS = ...

-- ============================================================
-- THE FILTER LIST, AND WHAT IS INSIDE A FILTER
-- DandersFrames/FilterRegistry/Registry.lua                (R:ListFilters, R:FilterSpellList)
-- DandersFrames_Options/FilterRegistry/UI/SpellPicker.lua  (R:OpenFilterPicker)
-- ------------------------------------------------------------
-- Spec section 27.2 moved "start from a filter" out of a 240px anchored dropdown
-- and into the SAME full overlay the spell database opens in; 27.3 put the peek
-- -- what a filter actually contains, enabled and disabled -- inside that
-- overlay's rows rather than in a second surface the user explicitly ruled out.
--
-- Two halves, and this file drives both:
--
--   the DERIVATION -- which filters there are, in what order, and which of a
--   filter's spells are switched off. Pure functions over a synthetic store, so
--   the enabled rule is asserted rather than inferred from a screenshot;
--
--   the RENDER -- the real refresh pass, lifted out of the picker file the way
--   test_addindicator_pane.lua lifts the add panel's builder, driven through
--   fake frames. What it can prove is what the pass BOUND: one row per filter, a
--   peek that appears on a click and carries the disabled spells too, and a pool
--   that hides what it stopped using.
--
-- ⚠ WHAT IT CANNOT PROVE. Headless frames record anchors rather than resolving
-- them, so nothing here shows that the rows land where they should or that a
-- 75-spell filter scrolls. The layout decision behind them -- expand-in-place
-- rather than a master/detail split, because the content area is 333px at the
-- window's 520px minimum -- is arithmetic in the source and needs eyes in game.
-- ============================================================

-- ---- WoW globals -------------------------------------------------
-- ☠ A CREATED FRAME IS SHOWN. The shim's fakes start hidden, which is the
-- opposite of the client and would make a row pool unobservable: a row created
-- by this refresh and a row hidden by it would both read as hidden, and "the
-- pool put away what it stopped using" is exactly what has to be asserted.
local prevCreateFrame = CreateFrame
CreateFrame = function(kind, _, parent)
    local f = FakeUIFrame()
    f._kind = kind
    f._parent = parent
    f._kids = {}
    f:Show()
    f.GetParent = function(self) return rawget(self, "_parent") end
    if type(parent) == "table" and rawget(parent, "_kids") then
        parent._kids[#parent._kids + 1] = f
    end
    return f
end

-- ============================================================
-- 1. THE DERIVATION, OUT OF THE REAL Registry.lua
-- Loaded whole rather than sliced: the file declares functions and touches no
-- frame at load, and its store accessors are the very thing under test.
-- ============================================================
local DFR = {
    db = {},                     -- the profile: preset overrides live here
    _global = {},                -- ...and the account-wide store here
}
function DFR:GetGlobalDB() return self._global end
load_df_file_into("FilterRegistry/Registry.lua", DFR)

local R = DFR.FilterRegistry
check(type(R) == "table", "registry: the module installed itself")
check(type(R.ListFilters) == "function", "registry: ...with the filter listing")
check(type(R.FilterSpellList) == "function", "registry: ...and the filter contents")

-- A synthetic database, small enough to reason about and shaped like the real
-- one: three records in one category, two in another, one of them shipped OFF.
local RECS = {
    { id = 101, n = "Barkskin",   class = "DRUID"  },
    { id = 102, n = "Ancestral",  class = "SHAMAN" },
    { id = 103, n = "Cocoon",     class = "MONK", off = true },
    { id = 201, n = "Sprint",     class = "ROGUE"  },
}
R.Spells = RECS
R.Categories = {
    { key = "defensives", name = "Defensives" },
    { key = "movement",   name = "Movement"   },
}
R.ByCategory = {
    defensives = { RECS[1], RECS[2], RECS[3] },
    movement   = { RECS[4] },
}
R.ByID = {}
for _, rec in ipairs(RECS) do R.ByID[rec.id] = rec end

-- ⚠ GUARDED READS, EVERYWHERE A LIST IS INDEXED. A mutant that drops entries has
-- to FAIL an assertion, not abort the run on a nil index -- everything after it
-- would stop reporting, which is the difference between a red suite and a broken
-- one. A sentinel rather than nil, so a missing entry and a nil field read
-- differently, and `false` survives the read.
local MISSING = "<missing>"
local function at(list, i, field)
    local e = list and list[i]
    if e == nil then return MISSING end
    return e[field]
end
-- ...and the same for a pooled row's font strings.
local function rowText(pool, i, part)
    local row = pool and pool[i]
    local fs = row and row[part]
    if fs == nil then return MISSING end
    return fs:GetText()
end

print("-- Filter list: presets in their own order, customs after them by name")
do
    local list = R:ListFilters()
    eq(#list, 2, "list: the two presets, and no custom filters yet")
    eq(at(list, 1, "key"), "defensives", "list: presets keep the Categories order...")
    eq(at(list, 2, "key"), "movement", "list: ...rather than a name sort")
    -- ☠ THE COUNT IS THE LIVE ONE. A record shipped OFF is in the filter and not
    -- switched on, which is two different numbers and the reason the row shows
    -- both.
    eq(at(list, 1, "total"), 3, "list: a preset's total is everything in it...")
    eq(at(list, 1, "enabled"), 2, "list: ...and its enabled count leaves out what ships off")
    eq(at(list, 1, "custom"), nil, "list: a preset is not a custom filter")

    -- ⚠ THE NAME IS A LOCALE KEY FOR A PRESET AND USER TEXT FOR A CUSTOM, and
    -- the caller is told which. A registry that localised would have to know
    -- which of the two it was holding, and would get it wrong for the one people
    -- type themselves.
    eq(at(list, 1, "name"), "Defensives", "list: a preset hands back its locale key")

    DFR._global.auraFilters = { nextFilterID = 3, customFilters = {
        cf1 = { name = "Zebra",  spells = { [101] = true, [999] = true }, rawIDs = {} },
        cf2 = { name = "Apple",  spells = { [201] = true }, rawIDs = { [4242] = true } },
    } }
    list = R:ListFilters()
    eq(#list, 4, "list: the custom filters join the presets")
    eq(at(list, 3, "key"), "cf2", "list: ...name-sorted, so Apple comes first...")
    eq(at(list, 4, "key"), "cf1", "list: ...and Zebra after it")
    eq(at(list, 3, "custom"), true, "list: a custom filter says it is one")
    eq(at(list, 3, "total"), 2, "list: ...and counts its raw ids as part of itself")
    eq(at(list, 3, "enabled"), at(list, 3, "total"),
       "list: ...with nothing switched off, because everything in one is in it")

    -- ...and a consumer that already owns a filter can keep it off the list.
    local trimmed = R:ListFilters(function(kind, key)
        return kind == "preset" and key == "movement"
    end)
    eq(#trimmed, 3, "list: isLinked drops a candidate...")
    for _, e in ipairs(trimmed) do
        check(e.key ~= "movement", "list: ...the one it named")
    end
end

print("-- Filter contents: every spell, and which of them are off")
do
    local list = R:FilterSpellList("defensives")
    check(list ~= nil, "peek: a preset resolves")
    eq(#list, 3, "peek: ...to everything in it, switched on or not")
    eq(at(list, 1, "name"), "Ancestral", "peek: name-sorted...")
    eq(at(list, 2, "name"), "Barkskin", "peek: ...")
    eq(at(list, 3, "name"), "Cocoon", "peek: ...")
    -- ☠ BOTH STATES, WHICH IS THE WHOLE POINT OF THE PEEK. A list that showed
    -- only the enabled spells would answer a different question -- "what does
    -- this filter DO" -- and the user asked what is IN one.
    eq(at(list, 1, "enabled"), true, "peek: a shipped-on spell reads as on")
    eq(at(list, 3, "enabled"), false, "peek: ...and one shipped off reads as off")

    -- ...and a profile override is what actually decides it.
    DFR.db.filterPresetOverrides = { defensives = { [101] = false, [103] = true } }
    list = R:FilterSpellList("defensives")
    eq(at(list, 2, "name"), "Barkskin", "peek: the same three spells, in the same order")
    eq(at(list, 2, "enabled"), false, "peek: ...but the profile's override turns one off")
    eq(at(list, 3, "enabled"), true, "peek: ...and another back on")
    DFR.db.filterPresetOverrides = nil

    -- A custom filter: its spells, plus the ids the database has no record for,
    -- which sort last because a "#4242" among names is noise anywhere else.
    local cf = R:FilterSpellList("cf2")
    check(cf ~= nil, "peek: a custom filter resolves too")
    eq(#cf, 2, "peek: ...to its spells and its raw ids together")
    eq(at(cf, 1, "name"), "Sprint", "peek: named spells first...")
    eq(at(cf, 2, "raw"), true, "peek: ...and the raw id last")
    eq(at(cf, 2, "name"), "#4242", "peek: ...rendered as the id it is")
    eq(at(cf, 1, "enabled"), true, "peek: everything in a custom filter is in it")

    -- An id the database USED to carry and no longer does is a raw id now,
    -- because that is all that is left of it.
    local orphan = R:FilterSpellList("cf1")
    eq(#orphan, 2, "peek: an orphaned id still draws")
    eq(at(orphan, 2, "name"), "#999", "peek: ...as a raw id, rather than vanishing")

    -- ☠ NIL, NOT AN EMPTY LIST, for a reference that resolves to nothing. A
    -- deleted custom filter is exactly that, and a caller showing a stale
    -- reference has to be able to tell "empty" from "gone".
    eq(R:FilterSpellList("cf99"), nil, "peek: a dead reference answers nil")
    eq(R:FilterSpellList("nosuchpreset"), nil, "peek: ...and so does an unknown preset")
end

-- ============================================================
-- 2. THE OVERLAY'S REFRESH PASS, LIFTED OUT OF SpellPicker.lua
-- The slice starts at the picker's own constants -- the row pools and the
-- refresh close over each other and over them, and stubbing either pool would
-- be testing the stub rather than the rows the user clicks.
-- ============================================================
local SRC = options_file_source("FilterRegistry/UI/SpellPicker.lua")
local SLICE = (function()
    local a = SRC:find("\nlocal FILTER_ROW_H = 26", 1, true)
    check(a ~= nil, "source: the filter picker declares its row metrics")
    return a and SRC:sub(a) or ""
end)()

local shellOpens = {}
local function FakeShell(parent, inst)
    inst.frame = CreateFrame("Frame", nil, parent)
    inst.title = inst.frame:CreateFontString()
    inst.subtitle = inst.frame:CreateFontString()
    inst.searchBox = { EditBox = { GetText = function() return "" end,
                                   SetText = function() end } }
    inst.listBg = CreateFrame("Frame", nil, inst.frame)
    inst.content = CreateFrame("Frame", nil, inst.listBg)
    inst.empty = inst.listBg:CreateFontString()
    -- The three verbs the real shell hands every overlay that wears it. Faked to
    -- the same contract, because `Refresh` re-running the caller's own render is
    -- what makes the pooled-build hazard testable at all.
    function inst:Close() self.frame:Hide() end
    function inst:IsOpen() return self.frame:IsShown() end
    function inst:Refresh()
        if self.frame:IsShown() and self.Render then self.Render(self) end
    end
    return inst
end

local GUI = {
    GetThemeColor = function() return { r = 0.4, g = 0.5, b = 0.9 } end,
    HideTooltip = function() end,
}
function GUI:CreateElementBackdrop(f) return f end
function GUI:CreateButton(parent, text, w, h, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    b.Text = b:CreateFontString()
    b.Text:SetText(text or "")
    b:SetScript("OnClick", onClick)
    return b
end

local pickerEnv = {
    CreateFrame = CreateFrame, ipairs = ipairs, pairs = pairs, type = type,
    format = string.format, mmax = math.max,
    L = setmetatable({}, { __index = function(_, k) return k end }),
    R = R, DF = { GUI = GUI, FilterRegistry = R },
    FALLBACK_ICON = 134400,
    ApplyNameColor = function() end,
    ShowSpellTooltip = function() end,
    BuildOverlayShell = FakeShell,
    OpenOverlayShell = function(inst, opts, listTop)
        shellOpens[#shellOpens + 1] = { inst = inst, opts = opts, listTop = listTop }
    end,
}
setmetatable(pickerEnv, { __index = _G })
do
    local fn = (loadstring or load)(SLICE, "@FilterPicker")
    check(fn ~= nil, "source: the filter picker's block compiles on its own")
    if fn then setfenv(fn, pickerEnv) fn() end
end
check(type(R.OpenFilterPicker) == "function",
      "live: the filter picker installs itself on the registry")

local function ShownRows(pool)
    local n = 0
    for _, row in ipairs(pool) do
        if row:IsShown() then n = n + 1 end
    end
    return n
end

-- ============================================================
-- 3. THE SHARED SHELL'S OPEN HALF, LIFTED ON ITS OWN
-- ☠ TWO OVERLAYS WEAR IT NOW. Before this pass the spell database's open path
-- was one function with one caller and nothing asserted about it; extracting it
-- makes a change there a change to BOTH lists at once, which is exactly the kind
-- of shared code that has to be pinned. Sliced separately from the block above
-- because it sits above the filter picker in the file -- and driven rather than
-- grepped, because "it titles the overlay" is a claim about what runs.
-- ============================================================
local shellSlice = (function()
    local a = SRC:find("local function OpenOverlayShell(inst, opts, listTop)", 1, true)
    check(a ~= nil, "source: the picker file declares the shared open half")
    local b = a and SRC:find("\nend\n", a, true)
    check(b ~= nil, "source: ...and it closes at the file's own indent")
    return (a and b) and SRC:sub(a, b + 4) or ""
end)()

print("-- The shared overlay shell: where it sits, what it is called, and a clean box")
do
    local shellEnv = {
        ipairs = ipairs, type = type,
        InCombatLockdown = function() return false end,
        L = pickerEnv.L,
    }
    setmetatable(shellEnv, { __index = _G })
    local mk = (loadstring or load)(shellSlice .. "\nreturn OpenOverlayShell", "@Shell")
    check(mk ~= nil, "shell: the open half compiles on its own")
    local Open = mk and (function() setfenv(mk, shellEnv) return mk() end)()
    check(type(Open) == "function", "shell: ...and hands itself back")

    if type(Open) == "function" then
        local parent = CreateFrame("Frame", nil, nil)
        parent:SetFrameLevel(7)
        local box = CreateFrame("Frame", nil, parent)
        local typed = "leftover"
        local inst = {
            frame = box,
            title = box:CreateFontString(),
            subtitle = box:CreateFontString(),
            listBg = CreateFrame("Frame", nil, box),
            searchBox = { EditBox = { GetText = function() return typed end,
                                      SetText = function(_, t) typed = t end } },
            search = "stale",
        }
        Open(inst, { parent = parent, subtitle = function() return "Add Indicator" end,
                     subtitleColor = { r = 1, g = 0, b = 0 } }, -50)

        -- ☠ IT COVERS THE HOST, AND SITS ABOVE IT. Both are what make an overlay
        -- an overlay rather than a panel that happens to be big.
        eq(#box._points, 2, "shell: the overlay is pinned by two opposite corners")
        eq(box:GetFrameLevel(), 37, "shell: ...well above the surface it covers")
        -- ...and it is TITLED. Nothing asserted this while the spell database was
        -- its only caller, and it is now the line that names two lists.
        eq(inst.title:GetText(), "Add from Database",
           "shell: ...carrying a title, defaulted for a caller that gives none")
        eq(inst.subtitle:GetText(), "Add Indicator",
           "shell: ...and a subtitle, which may be a verb rather than a string")

        -- ⚠ FRESH TRANSIENT STATE PER OPEN. The instance is cached per host, so
        -- a search left in the box is the previous open's, and the state field
        -- goes first so the box's own change handler has nothing to re-render.
        eq(inst.search, "", "shell: the search state is cleared...")
        eq(typed, "", "shell: ...and so is the box")

        -- ...and the list box is hung off the number the caller passed, which is
        -- the one thing about the body the shell does not decide.
        eq(#inst.listBg._points, 2, "shell: the list box is pinned by two corners")
        eq(inst.listBg._points[1][3], -50, "shell: ...the top one at the caller's own offset")

        local named = { parent = parent, title = "Filters" }
        Open(inst, named, -50)
        eq(inst.title:GetText(), "Filters", "shell: a caller's own title wins")
        eq(inst.subtitle:GetText(), "", "shell: ...and no subtitle leaves none behind")
    end
end

print("-- Filter overlay: one row per filter, in the SAME shell as the spell database")
local host, picked, inst
do
    host = CreateFrame("Frame", nil, nil)
    picked = {}
    inst = R:OpenFilterPicker({
        parent = host,
        onPick = function(kind, key, label)
            picked[#picked + 1] = { kind = kind, key = key, label = label }
        end,
    })
    check(inst ~= nil, "overlay: it opens")
    -- ☠ THROUGH THE SHARED SHELL, which is what "it opens the way the spell
    -- database does" means in code rather than in prose. A second hand-built
    -- panel would pass this file and still look like a different control.
    eq(#shellOpens, 1, "overlay: ...through the shared overlay shell")
    eq(shellOpens[1].listTop, -50,
       "overlay: ...with the list straight under the search box, having no dropdowns")
    eq(ShownRows(inst.filterRows), 4, "overlay: one row per filter")
    eq(ShownRows(inst.peekRows), 0, "overlay: ...and nothing expanded yet")

    -- A parent with no overlay is not an error to be thrown at the caller.
    eq(R:OpenFilterPicker({}), nil, "overlay: no host, no overlay")
end

print("-- Filter overlay: a filter opens in place, and shows what is off")
do
    local row = inst.filterRows[1]
    eq(row and row._entry and row._entry.key or MISSING, "defensives", "peek: the first row is the first preset")
    eq(row and row.count:GetText() or MISSING, "2/3", "peek: ...saying how much of itself is switched on")

    row:GetScript("OnClick")(row)
    -- ☠ IN PLACE, IN THE SAME LIST. The alternative the user ruled out was a
    -- second surface; the alternative the width ruled out was a detail column.
    -- So the spells are rows of this list, under the filter they belong to.
    eq(ShownRows(inst.peekRows), 3, "peek: the filter's three spells appear beneath it")
    eq(ShownRows(inst.filterRows), 4, "peek: ...without displacing any of the filters")
    eq(rowText(inst.peekRows, 1, "name"), "Ancestral", "peek: ...name-sorted")
    -- ...and BOTH states, which a list of what the filter DOES would not show.
    eq(rowText(inst.peekRows, 1, "state"), "", "peek: an enabled spell carries no mark")
    eq(rowText(inst.peekRows, 3, "name"), "Cocoon", "peek: a disabled spell is still listed")
    eq(rowText(inst.peekRows, 3, "state"), "Disabled", "peek: ...and says that it is off")

    -- Clicking again puts it away, and the pool goes with it.
    row:GetScript("OnClick")(row)
    eq(ShownRows(inst.peekRows), 0, "peek: clicking again closes it")
    eq(ShownRows(inst.filterRows), 4, "peek: ...and the filters are all still there")

    -- An empty filter says so rather than opening onto nothing.
    DFR._global.auraFilters.customFilters.cf3 =
        { name = "Empty", spells = {}, rawIDs = {} }
    inst:Refresh()
    local empties = 0
    for _, r in ipairs(inst.filterRows) do
        if r:IsShown() and r._entry and r._entry.key == "cf3" then
            r:GetScript("OnClick")(r)
            empties = empties + 1
        end
    end
    eq(empties, 1, "peek: the empty filter is on the list")
    eq(rowText(inst.peekRows, 1, "name"), "This filter is empty.",
       "peek: ...and opening it says so")
    DFR._global.auraFilters.customFilters.cf3 = nil
end

print("-- Filter overlay: the row's button answers, the row itself only peeks")
do
    inst:Refresh()
    local row
    for _, r in ipairs(inst.filterRows) do
        if r:IsShown() and r._entry and r._entry.key == "movement" then row = r end
    end
    check(row ~= nil, "pick: the Movement row is reachable")
    -- ☠ TWO THINGS TO DO ON ONE ROW, AND THEY MUST NOT BE THE SAME CLICK. The
    -- peek exists so you can look before committing; if looking committed, it
    -- would not be a peek.
    eq(#picked, 0, "pick: peeking has chosen nothing")
    local btn = row and row.action
    check(btn ~= nil, "pick: ...and the row carries its own action button")
    if btn then btn:GetScript("OnClick")(btn) end
    eq(#picked, 1, "pick: the button is what answers")
    eq(picked[1].kind, "preset", "pick: ...naming the kind the caller stores")
    eq(picked[1].key, "movement", "pick: ...and the key")
    -- ...and the overlay is gone before the caller's handler runs, so a handler
    -- that opens something of its own is not opening it underneath this.
    eq(inst.frame:IsShown(), false, "pick: ...with the overlay closed behind it")
end

print("-- Filter overlay: it re-reads the world on every open and every refresh")
do
    -- ☠ THE POOLED-BUILD HAZARD, in the place it has now bitten twice. This
    -- overlay is cached per host and its rows are pooled, so anything read once
    -- at construction is wrong for the rest of the session. Both counts and fold
    -- state are re-derived, and this is what says so.
    --
    -- Reopened first: the block above answered with the row button, which closes
    -- the overlay -- and Refresh on a closed overlay is deliberately a no-op.
    eq(R:OpenFilterPicker({ parent = host, onPick = function() end }), inst,
       "live: the overlay is reused for the same host")
    local defRow
    for _, r in ipairs(inst.filterRows) do
        if r:IsShown() and r._entry and r._entry.key == "defensives" then defRow = r end
    end
    check(defRow ~= nil, "live: the Defensives row is reachable")
    eq(defRow.count:GetText(), "2/3", "live: showing the count it had")
    DFR.db.filterPresetOverrides = { defensives = { [103] = true } }
    inst:Refresh()
    eq(defRow.count:GetText(), "3/3",
       "live: ...and a toggle elsewhere moves it, with no rebuild")
    DFR.db.filterPresetOverrides = nil

    -- ⚠ AND THE FOLD IS TRANSIENT. A peek is a glance on the way to choosing,
    -- not a setting; a second open that came back scrolled past its own first
    -- rows would be the panel remembering something nobody asked it to.
    defRow:GetScript("OnClick")(defRow)
    check(ShownRows(inst.peekRows) > 0, "live: a filter is left open...")
    R:OpenFilterPicker({ parent = host, onPick = function() end })
    eq(ShownRows(inst.peekRows), 0, "live: ...and the next open starts folded")
end

print("-- Filter overlay: the search narrows the list")
do
    inst.search = "move"
    inst:Refresh()
    eq(ShownRows(inst.filterRows), 1, "search: only the matching filter is drawn")
    eq(at(inst.filterRows, 1, "_entry") ~= MISSING and inst.filterRows[1]._entry.key or MISSING, "movement", "search: ...and it is the right one")
    eq(inst.empty:IsShown(), false, "search: ...so nothing says the list is empty")
    inst.search = "nothingmatchesthis"
    inst:Refresh()
    eq(ShownRows(inst.filterRows), 0, "search: a miss draws no rows")
    eq(inst.empty:IsShown(), true, "search: ...and says so")
    eq(inst.empty:GetText(), "No results found",
       "search: ...as a search that found nothing, not as an empty registry")
    inst.search = ""
    inst:Refresh()
end

CreateFrame = prevCreateFrame
