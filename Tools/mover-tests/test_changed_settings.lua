local NS = ...

-- ============================================================
-- CHANGED-SETTINGS LEDGER -- DandersFrames_Options/Features/ChangedSettings.lua
-- ------------------------------------------------------------
-- The ledger is a REPORT: it claims, in one number and one list, that these and
-- only these settings differ from what the addon ships. Every way that claim can
-- be quietly wrong is pinned here, because none of them announces itself in game
-- -- a wrong ledger looks exactly like a right one:
--
--   1. THE COUNT IS SETTINGS, NOT REGISTRATIONS. The same db key is registered
--      from more than one page (a control that appears on two surfaces), so
--      counting rows would over-report and list the setting twice.
--   2. NAV ORDER DECIDES THE HOME PAGE, not registry order -- BuildFullRegistry
--      walks GUI.Pages with pairs(), which is arbitrary. A duplicate key must
--      report against the page a user would look on first.
--   3. ROW ORDER IS DETERMINISTIC. The grouping goes through a hash table, so
--      without an explicit tiebreak the same profile would render its rows in a
--      different order on each visit.
--   4. UNBOUND ENTRIES ARE NOT ROWS. A custom control registers with no dbKey;
--      there is no stored value to compare and it must not appear.
--   5. THE FORMATTER. Numbers, booleans, colours, opaque tables and the float
--      epsilon's neighbourhood all have exactly one rendering each, and the
--      ASCII (copy-to-clipboard) rendering never emits a non-ASCII byte.
--   6. EMPTY IS EMPTY. Zero modified settings is a count of zero and no groups,
--      never an empty group or a nil.
--
-- The diff half is NOT re-implemented here: the fixtures feed Collect the exact
-- shape DF.Defaults:DiffKeys returns, and the last section runs the REAL engine
-- over the REAL shipped defaults to prove the two halves still fit together.
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME ACROSS EVERY TEST FILE. This file
-- replaces the `DandersFrames` global (ChangedSettings.lua takes its host off it,
-- not off the varargs) and Config.lua needs CreateFrame / GetLocale. All are
-- restored at the end.
-- ============================================================

local savedDF         = DandersFrames
local savedCreateFrame = CreateFrame
local savedGetLocale   = GetLocale

-- ---- the host surface ChangedSettings.lua reads at file scope -------
local DF = {}
DF.L = setmetatable({}, { __index = function(_, k) return k end })
DandersFrames = DF

load_options_file_into("Features/ChangedSettings.lua", NS)
local CS = DF.ChangedSettings
check(CS ~= nil, "ledger: the file publishes DF.ChangedSettings")
check(CS.PAGE_ID == "profiles_changed", "ledger: the page id is in the profiles_* style")

-- ============================================================
-- 5. THE FORMATTER
-- ============================================================
do
    local F = CS.FormatValue

    -- Numbers. "As-is" means a whole number stays whole -- %g alone turns
    -- 1000000 into 1e+06, which is not what a spell id should look like.
    eq(F(0), "0", "format: zero")
    eq(F(26), "26", "format: a whole number has no decimal part")
    eq(F(-4), "-4", "format: a negative whole number")
    eq(F(1000000), "1000000", "format: a large whole number is not exponential")
    eq(F(0.35), "0.35", "format: a fraction keeps its digits and gains no zeros")
    eq(F(0.05), "0.05", "format: a small fraction")
    eq(F(-6.666610717773438), "-6.66661", "format: the raid position default, to six figures")
    eq(F(1/3), "0.333333", "format: a repeating fraction stops at six figures")

    -- Right at the diff engine's epsilon. A value this close to its default is
    -- never a ROW (the engine filters it), but if one ever reaches the formatter
    -- it must not render as something that looks like a different number.
    eq(F(0.5 + 5e-7), "0.5", "format: a value inside the diff epsilon reads as the round number")
    eq(F(0.5 + 1e-3), "0.501", "format: a value outside it does not")

    -- Non-finite. Named rather than run through %g, whose spelling for these is
    -- platform-dependent -- this test would otherwise pass or fail by machine.
    eq(F(0/0), "nan", "format: NaN is named")
    eq(F(math.huge), "inf", "format: infinity is named")
    eq(F(-math.huge), "-inf", "format: negative infinity is named")

    -- Booleans, localised and ASCII.
    eq(F(true), "On", "format: true is On")
    eq(F(false), "Off", "format: false is Off")
    eq(F(true, true), "On", "format: ASCII true")
    eq(F(false, true), "Off", "format: ASCII false")

    -- Strings pass through -- an anchor, a font name, a texture key.
    eq(F("BOTTOMLEFT"), "BOTTOMLEFT", "format: a string is itself")
    eq(F(""), "", "format: an empty string is not turned into a dash")

    -- Colours, both spellings that appear in a profile.
    eq(F({ r = 1, g = 1, b = 1 }), "#FFFFFF", "format: white, keyed")
    eq(F({ r = 0, g = 0, b = 0, a = 1 }), "#000000", "format: black, with alpha present")
    eq(F({ 1, 0, 0 }), "#FF0000", "format: red, as a plain array")
    eq(F({ r = 0.5, g = 0.25, b = 0.75 }), "#8040BF", "format: a mid colour rounds to nearest")
    -- Out of range rather than erroring: an imported profile can carry one.
    eq(F({ r = 2, g = -1, b = 0.5 }), "#FF0080", "format: channels clamp instead of overflowing")

    -- Anything else table-shaped has no honest one-line form.
    eq(F({ x = 0, y = -325 }), "\226\128\166", "format: an opaque table is an ellipsis")
    eq(F({ x = 0, y = -325 }, true), "...", "format: ...and three dots in ASCII")
    eq(F({}), "\226\128\166", "format: an empty table too")
    eq(F({ r = 1, g = 1 }), "\226\128\166", "format: a table with only two channels is not a colour")

    eq(F(nil), "-", "format: a missing value is a dash, not the word nil")

    -- ☠ THE ASCII FORM IS ACTUALLY ASCII. The copy block is pasted into
    -- Discord, forums and bug reports from every client; one stray multi-byte
    -- glyph is what makes a paste render as mojibake for the person reading it.
    for _, v in ipairs({ 26, 0.35, true, false, "BOTTOMLEFT" }) do
        local s = CS.FormatValue(v, true)
        local clean = true
        for i = 1, #s do if s:byte(i) > 126 then clean = false end end
        check(clean, "format: the ASCII form of " .. tostring(v) .. " is 7-bit")
    end
    local s = CS.FormatValue({ x = 1 }, true)
    local clean = true
    for i = 1, #s do if s:byte(i) > 126 then clean = false end end
    check(clean, "format: the ASCII form of an opaque table is 7-bit")
end

-- ============================================================
-- 4. BoundKeys -- WHICH ENTRIES ARE LEDGER MATERIAL
-- ============================================================
do
    local registry = {
        { dbKey = "frameWidth",  label = "Width" },
        { searchKey = "custom_Enable", label = "Enable" },      -- no db key: not a row
        { dbKey = "frameWidth",  label = "Width", tab = "b" },  -- same key, second page
        { dbKey = "frameHeight", label = "Height" },
        { label = "A header with nothing bound" },
        { dbKey = 42, label = "A non-string key" },
    }
    local keys = CS.BoundKeys(registry)
    eq(#keys, 2, "boundkeys: only the two distinct bound keys")
    eq(keys[1], "frameWidth", "boundkeys: registry order is preserved")
    eq(keys[2], "frameHeight", "boundkeys: ...for the second too")

    eq(#CS.BoundKeys({}), 0, "boundkeys: an empty registry yields none")
    eq(#CS.BoundKeys(nil), 0, "boundkeys: nil yields none, rather than erroring")
end

-- ============================================================
-- 1-3. Collect -- THE DIFF WALK
-- ============================================================

-- Two pages' worth of controls, deliberately NOT in nav order (BuildFullRegistry
-- walks GUI.Pages with pairs(), so registry order really is arbitrary).
local function fixture()
    return {
        { dbKey = "borderSize",  label = "Border Size",  tab = "display_frame", tabLabel = "Frame",   section = "Border" },
        { dbKey = "frameWidth",  label = "Width",        tab = "display_frame", tabLabel = "Frame",   section = "Size" },
        { searchKey = "custom_Enable", label = "Enable", tab = "display_frame", tabLabel = "Frame",   section = "Size" },
        { dbKey = "healthColor", label = "Health Color", tab = "bars_health",   tabLabel = "Health",  section = "Colors" },
        { dbKey = "frameWidth",  label = "Frame Width",  tab = "bars_health",   tabLabel = "Health",  section = "Layout" },
        { dbKey = "untouched",   label = "Untouched",    tab = "bars_health",   tabLabel = "Health",  section = "Layout" },
    }
end
local NAV = { "bars_health", "display_frame" }   -- Health sits ABOVE Frame in the sidebar

do
    local diff = {
        borderSize  = { current = 2,   default = 1 },
        frameWidth  = { current = 90,  default = 72 },
        healthColor = { current = { r = 1, g = 0, b = 0 }, default = { r = 0, g = 1, b = 0 } },
    }
    local report = CS.Collect(fixture(), NAV, diff)

    -- 1. THE COUNT IS SETTINGS, NOT REGISTRATIONS.
    eq(report.count, 3, "collect: three settings differ, not the four registrations that match")

    -- 2. NAV ORDER, not registry order -- and the duplicate reports against the
    -- page that comes first in the sidebar, not the one registered first.
    eq(#report.groups, 2, "collect: two pages have hits")
    eq(report.groups[1].tab, "bars_health", "collect: the first group is the first page in NAV order")
    eq(report.groups[2].tab, "display_frame", "collect: ...and the second is the second")
    eq(report.groups[1].label, "Health", "collect: a group is labelled with the page's own label")

    eq(#report.groups[1].rows, 2, "collect: the duplicated key landed on the nav-first page")
    eq(#report.groups[2].rows, 1, "collect: ...and NOT also on the other one")
    eq(report.groups[1].rows[1].label, "Health Color", "collect: rows keep the registry label")
    eq(report.groups[1].rows[2].label, "Frame Width",
        "collect: the duplicate uses the label from the page it reports against")
    eq(report.groups[2].rows[1].key, "borderSize", "collect: the other page keeps its own key")

    -- 3. ROW ORDER IS DETERMINISTIC, and it is the order the page lays its
    -- controls out (registry sequence within the page).
    eq(report.groups[1].rows[1].key, "healthColor", "collect: rows follow build order inside a page")
    eq(report.groups[1].rows[2].key, "frameWidth", "collect: ...not hash order")

    -- ...asserted rather than assumed: the same input twice must agree.
    local again = CS.Collect(fixture(), NAV, diff)
    for gi = 1, #report.groups do
        eq(again.groups[gi].tab, report.groups[gi].tab, "collect: group order is stable across runs")
        for ri = 1, #report.groups[gi].rows do
            eq(again.groups[gi].rows[ri].key, report.groups[gi].rows[ri].key,
                "collect: row order is stable across runs")
        end
    end

    -- Values ride along by reference, exactly as DiffKeys handed them over.
    eq(report.groups[2].rows[1].current, 2, "collect: current is the stored value")
    eq(report.groups[2].rows[1].default, 1, "collect: default is the shipped value")
    check(report.groups[1].rows[1].current == diff.healthColor.current,
        "collect: table values are not copied")

    -- 4. An unmodified key and a keyless entry are both absent.
    for _, group in ipairs(report.groups) do
        for _, row in ipairs(group.rows) do
            check(row.key ~= "untouched", "collect: an unmodified key is never a row")
            check(row.label ~= "Enable", "collect: a keyless custom control is never a row")
        end
    end
end

-- 6. EMPTY IS EMPTY
do
    local report = CS.Collect(fixture(), NAV, {})
    eq(report.count, 0, "collect: nothing modified counts zero")
    eq(#report.groups, 0, "collect: ...and produces no groups at all, not an empty one")

    local nilDiff = CS.Collect(fixture(), NAV, nil)
    eq(nilDiff.count, 0, "collect: a nil diff map counts zero")
    eq(#CS.Collect({}, NAV, { frameWidth = { current = 1, default = 2 } }).groups, 0,
        "collect: an empty registry has nothing to report against")
    eq(CS.Collect(nil, nil, nil).count, 0, "collect: all three nil is still a valid empty report")
end

-- A page missing from the nav order still reports, at the end.
--
-- A page can be created `hidden` (never added to a category's children), and a
-- deprecated-but-not-deleted page still owns real settings. Dropping its rows
-- would silently under-report exactly the settings nobody can find.
do
    local registry = {
        { dbKey = "ghostKey", label = "Ghost", tab = "not_in_nav", tabLabel = "Ghost Page" },
        { dbKey = "frameWidth", label = "Width", tab = "display_frame", tabLabel = "Frame" },
    }
    local report = CS.Collect(registry, NAV, {
        ghostKey   = { current = 1, default = 0 },
        frameWidth = { current = 90, default = 72 },
    })
    eq(report.count, 2, "collect: a page absent from the nav order still reports")
    eq(report.groups[1].tab, "display_frame", "collect: known pages come first")
    eq(report.groups[2].tab, "not_in_nav", "collect: ...and the unknown one sorts after them")
end

-- ============================================================
-- BuildText -- THE COPY BLOCK
-- ============================================================
do
    local report = CS.Collect(fixture(), NAV, {
        frameWidth = { current = 90, default = 72 },
        borderSize = { current = 2, default = 1 },
    })
    local text = CS.BuildText(report, { modeLabel = "Party" })
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end

    eq(lines[1], "DandersFrames (Party)", "text: the title carries the mode it describes")
    eq(lines[2], "2 settings differ from defaults.", "text: the count is on its own line")
    eq(lines[3], "", "text: a blank line before the list")
    eq(lines[4], "Health > Frame Width: 90 (default: 72)", "text: page > label: current (default: x)")
    eq(lines[5], "Frame > Border Size: 2 (default: 1)", "text: one line per row, in report order")
    eq(#lines, 5, "text: nothing else is emitted")

    -- ☠ EVERYTHING THE BLOCK ITSELF WRITES IS 7-BIT -- the title, the count
    -- sentence, "default:", and every value spelling. Same reason as the
    -- formatter's ASCII form: a non-ASCII byte in the STRUCTURE can turn a
    -- pasted report into mojibake for the person trying to read it.
    -- ⚠ This is not a claim about the whole string in game: the labels come
    -- from the user's locale and are not ASCII in most of them. The fixture's
    -- labels are English precisely so this measures the scaffolding.
    local wide = CS.BuildText(CS.Collect(fixture(), NAV, {
        healthColor = { current = { r = 1, g = 0, b = 0 }, default = { r = 0, g = 1, b = 0 } },
        frameWidth  = { current = true, default = false },
        borderSize  = { current = { nested = true }, default = 1 },
    }), { modeLabel = "Raid" })
    local clean = true
    for i = 1, #wide do if wide:byte(i) > 126 then clean = false end end
    check(clean, "text: everything the copy block writes itself is 7-bit ASCII")
    check(wide:find("#FF0000", 1, true) ~= nil, "text: a colour renders as hex")
    check(wide:find("On", 1, true) ~= nil, "text: a boolean renders as a word")
    check(wide:find("...", 1, true) ~= nil, "text: an opaque table renders as three dots")

    -- The empty report is still a valid, honest block rather than a bare title.
    local empty = CS.BuildText(CS.Collect({}, NAV, {}), { modeLabel = "Party" })
    check(empty:find("0 settings differ from defaults.", 1, true) ~= nil,
        "text: an empty report says so in words")
    check(CS.BuildText(nil, {}):find("0 settings", 1, true) ~= nil,
        "text: a nil report does not error")
end

-- ============================================================
-- PageOrder -- THE NAV WALK
-- ============================================================
do
    local GUI = {
        CategoryOrder = { "general", "profiles" },
        Categories = {
            general  = { children = { { tabName = "general_settings" }, { tabName = "general_fonts" } } },
            profiles = { children = { { tabName = "profiles_manage" } } },
            -- A category declared but not in CategoryOrder contributes nothing.
            orphan   = { children = { { tabName = "orphan_page" } } },
        },
    }
    local order = CS:PageOrder(GUI)
    eq(#order, 3, "pageorder: only categories named in CategoryOrder")
    eq(order[1], "general_settings", "pageorder: category order, then child order")
    eq(order[2], "general_fonts", "pageorder: ...second child of the first category")
    eq(order[3], "profiles_manage", "pageorder: ...then the next category")

    eq(#CS:PageOrder(nil), 0, "pageorder: no GUI yields an empty order, not an error")
    eq(#CS:PageOrder({ Categories = {} }), 0, "pageorder: no CategoryOrder yields an empty order")
end

-- ============================================================
-- THE TWO HALVES ACTUALLY FIT
-- Everything above feeds Collect a hand-written diff map. This runs the REAL
-- diff engine over the REAL shipped defaults and hands its output straight in,
-- so a change to DiffKeys' return shape breaks here rather than in game.
-- ============================================================
do
    CreateFrame = function() return FakeUIFrame() end
    GetLocale = function() return "enUS" end
    load_df_file_into("Core/Config.lua", DF)
    CreateFrame, GetLocale = savedCreateFrame, savedGetLocale
    DandersFrames = DF          -- Config.lua claims the global
    load_df_file_into("Core/Defaults.lua", DF)

    check(type(DF.Defaults) == "table", "live: the real diff engine loaded")
    check(type(DF.PartyDefaults) == "table", "live: the real shipped defaults loaded")

    local function deepcopy(v)
        if type(v) ~= "table" then return v end
        local t = {}
        for k, x in pairs(v) do t[k] = deepcopy(x) end
        return t
    end
    local party = {}
    for k, v in pairs(DF.PartyDefaults) do party[k] = deepcopy(v) end
    DF.db = { party = party, raid = {} }
    DF._realRaidDB = nil

    -- Three real settings, three shapes: a number, a boolean and a colour.
    local registry = {
        { dbKey = "absorbBarHeight",  label = "Height",  tab = "bars_absorb", tabLabel = "Absorbs", section = "Bar" },
        { dbKey = "absorbBarReverse", label = "Reverse", tab = "bars_absorb", tabLabel = "Absorbs", section = "Bar" },
        { dbKey = "fontShadowColor",  label = "Shadow",  tab = "general_fonts", tabLabel = "Fonts", section = "Text" },
        { dbKey = "absorbBarAnchor",  label = "Anchor",  tab = "bars_absorb", tabLabel = "Absorbs", section = "Bar" },
    }
    local nav = { "general_fonts", "bars_absorb" }

    local function reportNow()
        local diff = DF.Defaults:DiffKeys(DF.db.party, CS.BoundKeys(registry))
        return CS.Collect(registry, nav, diff)
    end

    eq(reportNow().count, 0, "live: a fresh profile reports nothing changed")

    party.absorbBarHeight  = DF.PartyDefaults.absorbBarHeight + 3
    party.absorbBarReverse = not DF.PartyDefaults.absorbBarReverse
    party.fontShadowColor  = { r = 1, g = 0, b = 0, a = 1 }

    local report = reportNow()
    eq(report.count, 3, "live: three real settings changed, three rows")
    eq(report.groups[1].tab, "general_fonts", "live: nav order still decides the group order")
    eq(#report.groups[1].rows, 1, "live: the fonts page owns one of them")
    eq(#report.groups[2].rows, 2, "live: the absorbs page owns the other two")
    eq(CS.FormatValue(report.groups[1].rows[1].current), "#FF0000",
        "live: the engine's colour value formats as hex")
    eq(CS.FormatValue(report.groups[2].rows[1].current),
       tostring(DF.PartyDefaults.absorbBarHeight + 3),
       "live: the engine's number value formats as the stored number")

    -- ☠ A CHANGE MADE AND UNMADE LEAVES NOTHING BEHIND. The page is rebuilt on
    -- every Refresh precisely so an undo or a group reset drops out of the
    -- report -- if it did not, the ledger would be describing a configuration
    -- the user no longer has.
    party.absorbBarHeight  = DF.PartyDefaults.absorbBarHeight
    party.absorbBarReverse = DF.PartyDefaults.absorbBarReverse
    party.fontShadowColor  = deepcopy(DF.PartyDefaults.fontShadowColor)
    eq(reportNow().count, 0, "live: reverting every change empties the ledger again")

    -- Float noise under the diff engine's epsilon is not a row, and that has to
    -- hold through the ledger too -- a report that lights up on 1e-7 is noise.
    party.absorbBarHeight = DF.PartyDefaults.absorbBarHeight + 5e-7
    eq(reportNow().count, 0, "live: a change inside the diff epsilon is not a row")
    party.absorbBarHeight = DF.PartyDefaults.absorbBarHeight + 1
    eq(reportNow().count, 1, "live: a change outside it is")
end

-- ============================================================
-- BuildReport -- THE REFUSALS
-- The page renders whatever this returns, so "cannot answer" has to be
-- distinguishable from "nothing changed". They look identical on screen and
-- mean opposite things: one says the profile is clean, the other says nothing
-- was measured. Runs after the section above, which is what loaded the real
-- defaults and left a profile on DF.db.
-- ============================================================
do
    local GUI = { SelectedMode = "party", CategoryOrder = {}, Categories = {} }

    -- A stand-in for Features/Search.lua: the entry points BuildReport uses,
    -- with a build that is recorded rather than performed. The REAL pair is
    -- driven by test_search_registry; what matters here is only which of them
    -- BuildReport calls, and when.
    --
    -- ⚠ THE BUILD IS ASYNC NOW. EnsureRegistryAsync starts a budgeted build and
    -- answers "building"; the report is not available in the same call, and the
    -- page shows its building state until the waiter fires. `finish` is this
    -- fake's stand-in for the frames that would have passed.
    local builds, waiter = 0, nil
    local fakeSearch = {
        Registry = { { dbKey = "absorbBarHeight", label = "Height", tab = "bars_absorb", tabLabel = "Absorbs" } },
        stale = false,
    }
    function fakeSearch:RegistryIsStale() return self.stale end
    function fakeSearch:EnsureRegistryAsync(onReady)
        if not self.stale then return "ready" end
        builds = builds + 1
        self.RegistryBuilding = true
        waiter = onReady
        return "building"
    end
    local function finish()
        fakeSearch.stale = false
        fakeSearch.RegistryBuilding = false
        local fn = waiter; waiter = nil
        if fn then fn(true) end
    end
    DF.Search = fakeSearch

    DF.db.party.absorbBarHeight = DF.PartyDefaults.absorbBarHeight + 2

    -- Out of combat, registry fresh: a normal report and no build.
    IN_COMBAT = false
    local report, reason = CS:BuildReport(GUI)
    check(report ~= nil, "report: a fresh registry answers")
    eq(reason, nil, "report: ...with no reason attached")
    eq(report.count, 1, "report: and it found the one changed setting")
    eq(builds, 0, "report: a fresh registry is not rebuilt")

    -- ☠ IN COMBAT WITH A STALE REGISTRY: refuse, and do not build. Building it
    -- re-runs every page builder, which is a hitch in the middle of a pull.
    IN_COMBAT = true
    fakeSearch.stale = true
    report, reason = CS:BuildReport(GUI)
    eq(report, nil, "report: a stale registry in combat refuses")
    eq(reason, "combat", "report: ...naming combat as the reason")
    eq(builds, 0, "report: ...and no build was started")

    -- ...but an ALREADY-BUILT registry keeps working right through combat. The
    -- guard is on the BUILD, not on the page: open the ledger before the pull
    -- and it does not go blank when the pull happens.
    fakeSearch.stale = false
    report, reason = CS:BuildReport(GUI)
    check(report ~= nil, "report: an already-built registry answers in combat")
    eq(report.count, 1, "report: ...with the same answer as out of combat")

    -- Out of combat, stale: it starts a BUDGETED build and says so. ☠ THE PAGE
    -- MUST NOT GET A REPORT HERE. This call is made from inside the ledger's own
    -- page build; answering it synchronously is what put ~34 page builders in
    -- the frame that drew the page ("lags like crazy").
    IN_COMBAT = false
    fakeSearch.stale = true
    report, reason = CS:BuildReport(GUI)
    eq(builds, 1, "report: out of combat a stale registry starts a build")
    eq(report, nil, "report: ...and does NOT answer in the same call")
    eq(reason, "building", "report: ...it names the build as the reason")

    -- ...and once the build lands, the same call answers.
    finish()
    report, reason = CS:BuildReport(GUI)
    check(report ~= nil, "report: a landed build answers")
    eq(reason, nil, "report: ...with no reason attached")
    eq(builds, 1, "report: ...and started no second build")

    -- A build already in flight is not a second build, and is still not an
    -- answer: two surfaces (the ledger and the search box) can be waiting on one.
    fakeSearch.RegistryBuilding = true
    report, reason = CS:BuildReport(GUI)
    eq(report, nil, "report: a build in flight does not answer")
    eq(reason, "building", "report: ...it reports the build")
    eq(builds, 1, "report: ...and does not start another")
    fakeSearch.RegistryBuilding = false

    -- The other refusals, each with the honest reason rather than an empty report.
    local savedSearch = DF.Search
    DF.Search = nil
    report, reason = CS:BuildReport(GUI)
    eq(report, nil, "report: no search module means no report")
    eq(reason, "unbuilt", "report: ...reported as unbuilt")
    DF.Search = savedSearch

    fakeSearch.Registry = {}
    report, reason = CS:BuildReport(GUI)
    eq(report, nil, "report: an empty registry is not an empty ledger")
    eq(reason, "unbuilt", "report: ...it is unbuilt")
    fakeSearch.Registry = { { dbKey = "absorbBarHeight", label = "Height", tab = "bars_absorb" } }

    local savedDb = DF.db
    DF.db = { party = nil }
    report, reason = CS:BuildReport(GUI)
    eq(report, nil, "report: no profile for the selected mode means no report")
    eq(reason, "unbuilt", "report: ...reported as unbuilt")
    DF.db = savedDb

    DF.Search = nil
    IN_COMBAT = false
end

CreateFrame   = savedCreateFrame
GetLocale     = savedGetLocale
DandersFrames = savedDF
