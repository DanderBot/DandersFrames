local NS = ...

-- ============================================================
-- BUFF BAR: THE FILTER TICKS EDIT THE TABLE THE PAGE IS BUILT FOR
-- DandersFrames_Options/GUI/Pages/Indicators.lua  BuffSelection
-- ------------------------------------------------------------
-- A unit frame's Buff Bar page runs the party page's builder against the unit's
-- own settings table (GUI.PageBuildDb). Every control on it writes `db`, but the
-- category ticks resolved their table from the frame MODE alone -- so on a unit
-- page they edited Party (or Raid) and the unit's own buffFilterSelection never
-- moved: with All Buffs off, whatever was ticked, the unit showed only what its
-- untouched default selection allowed. The real helper is lifted by name and run
-- on plain tables.
-- ============================================================

print("-- Buff Bar: filter ticks edit the page's own table")

local src = options_file_source("GUI/Pages/Indicators.lua"):gsub("\r\n", "\n")
local a = src:find("        local function BuffSelection()\n", 1, true)
check(a ~= nil, "selection: the Buff Bar page declares BuffSelection")
if not a then return end
local stop = src:find("\n        end\n", a, true)
check(stop ~= nil, "selection: ...and it closes at the page builder's indent")
if not stop then return end
local chunk = assert(loadstring("local DF, GUI, self = ...\n" .. src:sub(a, stop + 12)
    .. "\nreturn BuffSelection", "=Indicators.lua:BuffSelection"))

local function sel(presets)
    return { presets = presets or {}, customs = {}, uncategorised = false }
end

-- ---- a party/raid page: no table of its own, so the frame mode's (unchanged) ----
do
    local party = { buffFilterSelection = sel({ healing = true }) }
    local raid  = { buffFilterSelection = sel({ raidDefensives = true }) }
    local DF = { db = { party = party, raid = raid } }
    local page = {}
    local GUI = { SelectedMode = "raid", PageBuildDb = function() return nil end }
    local BuffSelection = chunk(DF, GUI, page)
    check(BuffSelection() == raid.buffFilterSelection, "mode page: Raid edits the raid table, by identity")
    GUI.SelectedMode = "party"
    check(BuffSelection() == party.buffFilterSelection, "mode page: Party edits the party table, by identity")
    GUI.SelectedMode = nil
    check(BuffSelection() == party.buffFilterSelection, "mode page: no mode falls back to Party")
    -- No PageBuildDb at all (the module registry not loaded): still the mode's.
    GUI.PageBuildDb = nil
    GUI.SelectedMode = "raid"
    check(BuffSelection() == raid.buffFilterSelection, "mode page: no PageBuildDb hook, still the mode's table")
end

-- ---- a unit frame's page: its own table, never the mode's ----
do
    local party = { buffFilterSelection = sel({ healing = true }) }
    local unitDb = { buffFilterSelection = sel({ healing = true, offensiveCooldowns = true }) }
    local DF = { db = { party = party, raid = { buffFilterSelection = sel() } } }
    local unitPage = {}
    local GUI = {
        SelectedMode = "party",
        PageBuildDb = function(p) if p == unitPage then return unitDb end end,
    }
    local BuffSelection = chunk(DF, GUI, unitPage)
    local s = BuffSelection()
    check(s == unitDb.buffFilterSelection, "unit page: the tick reads the unit's own selection")
    -- What the Raid Buffs checkbox's setter does.
    s.presets.raidBuffs = true
    check(unitDb.buffFilterSelection.presets.raidBuffs == true, "unit page: ticking lands in the unit's table")
    check(party.buffFilterSelection.presets.raidBuffs == nil, "unit page: ...and leaves Party's alone")
    -- Raid selected under the unit page: still the unit's.
    GUI.SelectedMode = "raid"
    check(BuffSelection() == unitDb.buffFilterSelection, "unit page: the frame mode does not redirect it")
end

-- ---- a unit table with no selection yet: created in place on the unit ----
do
    local party = { buffFilterSelection = sel({ healing = true }) }
    local unitDb = {}
    local DF = { db = { party = party } }
    local unitPage = {}
    local GUI = { SelectedMode = "party", PageBuildDb = function() return unitDb end }
    local s = chunk(DF, GUI, unitPage)()
    check(type(unitDb.buffFilterSelection) == "table" and s == unitDb.buffFilterSelection,
          "unit page: a missing selection is created on the unit")
    check(type(s.presets) == "table" and type(s.customs) == "table", "unit page: ...with its inner tables")
    check(s ~= party.buffFilterSelection, "unit page: ...not borrowed from Party")
end
