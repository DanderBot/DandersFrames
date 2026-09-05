local NS = ...

-- ============================================================
-- THE SHARED POPOUT-PAGE MACHINERY -- GUI:CreatePopoutPageTools
-- DandersFrames_Options/GUI/Controls.lua
-- ------------------------------------------------------------
-- The Frame page built the first copy of this inline: the eager popout holders,
-- the reflow, the key claim, the modified tick, the footer's two verbs, the
-- hoisted-toggle search repair, the band width and the non-classic prologue.
-- Five more pages need all of it, and five copies would drift -- the first thing
-- to drift being one of the load-bearing notes rather than the code under it.
--
-- The Frame page was the last to come home, in its own commit with its own test
-- edit: its census tests read that page's source line by line, so the port was
-- never something the lift could do on its way past. What is pinned here is that
-- the helper exists, that it exposes every verb, and that no page -- the Frame
-- page included -- keeps a second copy of any of it.
--
-- Mostly source-level, like the page-builder tests: the parts that matter build
-- real frames and read DF.db / GUI.SelectedMode. But the helper's PROLOGUE and
-- its verb declarations touch nothing but the page table, so section 6 lifts the
-- function out by source, compiles it into a stub environment and drives the key
-- claim and the hoisted toggle against the REAL Features/Search.lua -- which is
-- the only way to measure what a search breadcrumb actually ends up saying.
-- ============================================================

local SRC = options_file_source("GUI/Controls.lua")

-- The helper's declaration and its closing `end` at column zero. BODY stops
-- short of the `end` (every source assertion below only wants what is inside
-- it); CHUNK includes it, because section 6 COMPILES AND RUNS the helper.
local DECL_AT, END_AT = (function()
    local a = SRC:find("function GUI:CreatePopoutPageTools(page)", 1, true)
    check(a ~= nil, "source: Controls.lua declares GUI:CreatePopoutPageTools")
    if not a then return nil, nil end
    local b = SRC:find("\nend\n", a, true)
    check(b ~= nil and b > a, "source: ...and it closes at the file's own indent")
    return a, b
end)()

local BODY  = (DECL_AT and END_AT) and SRC:sub(DECL_AT, END_AT) or ""
local CHUNK = (DECL_AT and END_AT) and SRC:sub(DECL_AT, END_AT + 4) or ""

print("-- Popout page tools: one page argument, and a classic-safe early return")
do
    -- ☠ THE CLEAR COMES FIRST, BEFORE THE LAYOUT TEST. The map only ever has
    -- entries in the popout layout, but a map left behind by a PREVIOUS new-UI
    -- build would point the settings-search jump at rows this build has retired
    -- -- so a page that flips to classic has to lose it too.
    local clearAt   = BODY:find("page._popoutRowForKey = nil", 1, true)
    local classicAt = BODY:find("if DF:IsClassicSettingsLayout() then return nil end", 1, true)
    check(clearAt ~= nil, "tools: the stale row map is cleared on every build")
    check(classicAt ~= nil, "tools: ...and the classic layout returns nil, doing nothing else")
    check(clearAt and classicAt and clearAt < classicAt,
          "tools: ...the clear happening BEFORE the classic bail, so classic loses it too")

    -- ☠ AND SO DOES THE CLOSE, for the same reason and a sharper one. The FLIP to
    -- classic is itself a rebuild, and it is the one rebuild that happens with a
    -- panel standing open -- the tick that flips it lives inside one. Left below
    -- the bail, the helper would hand a classic page back with an orphan panel
    -- floating beside it, wired to a row this build has already retired.
    local closeAt = BODY:find('GUI:CloseAllPopoutRows("rebuild")', 1, true)
    check(closeAt ~= nil, "tools: every open row panel is closed on every build")
    check(closeAt and classicAt and closeAt < classicAt,
          "tools: ...BEFORE the classic bail, so a flip to classic takes the panels down too")
    -- Still guarded, so an older embedded copy of the pack without the verb cannot
    -- break a page -- and so the close is a plain no-op on a classic build that
    -- never had a panel open.
    check(BODY:find("if GUI.CloseAllPopoutRows then GUI:CloseAllPopoutRows(\"rebuild\") end", 1, true) ~= nil,
          "tools: ...and guarded on the verb, not called bare")
end

print("-- Popout page tools: the non-classic prologue, in order")
do
    -- Three moves, and the first is the one that matters: an open popout from the
    -- previous build is wired to the db table THAT build captured, so after a
    -- mode switch a slider dragged in a stale panel writes the wrong mode.
    local close   = BODY:find('GUI:CloseAllPopoutRows("rebuild")', 1, true)
    local retire  = BODY:find("for _, holder in ipairs(page._popoutHolders) do", 1, true)
    local mapNew  = BODY:find("page._popoutRowForKey = {}", 1, true)
    check(close ~= nil, "prologue: every open row panel is closed first")
    check(BODY:find("if GUI.CloseAllPopoutRows then", 1, true) ~= nil,
          "prologue: ...guarded, so an older embedded pack cannot break the page")
    check(retire ~= nil, "prologue: the previous build's holders are retired")
    check(BODY:find("page._popoutHolders = {}", 1, true) ~= nil,
          "prologue: ...and the list starts empty")
    check(mapNew ~= nil, "prologue: the row map is published fresh")
    check(close and retire and close < retire, "prologue: closing precedes retiring")
    check(retire and mapNew and retire < mapNew, "prologue: ...and retiring precedes the new map")

    -- The holders go to the trash frame, which is what keeps them off the page:
    -- they are deliberately not in page.children, so DoBuild's retire loop never
    -- sees them and this is the only thing that does.
    check(BODY:find("local trash = GUI._trashFrame", 1, true) ~= nil,
          "prologue: the retired holders are re-parented to the trash frame")
end

print("-- Popout page tools: every verb the pages call")
do
    -- The nine named verbs plus the band skin, each declared and each returned.
    -- Named rather than counted so a rename fails here instead of quietly
    -- shrinking what the next page can use.
    local VERBS = {
        "PopoutContent", "RowDB", "ClaimKeys", "WireModifiedTick", "WireFooter",
        "RegisterHoistedToggle", "RegisterControlRow", "ReflowMounted", "BandWidth",
    }
    for _, v in ipairs(VERBS) do
        check(BODY:find("local function " .. v .. "(", 1, true) ~= nil,
              "verbs: " .. v .. " is declared inside the helper")
        check(BODY:find(v .. "%s+=%s+" .. v) ~= nil,
              "verbs: ...and handed back on the tools table")
    end
    check(BODY:find("INLINE_BOX            = { bandStyle = true }", 1, true) ~= nil,
          "verbs: the stay-inline box's band skin comes back as one shared table")

    -- ReflowPane and the three gates are internal -- the pages never call them
    -- directly -- but they are the ones the semantics live in.
    for _, v in ipairs({ "ReflowPane", "RefreshAfterGroupWrite", "CombatReason", "HoldReason",
                         "RowLabel", "AnchorRow", "StampSection" }) do
        check(BODY:find("local function " .. v .. "(", 1, true) ~= nil,
              "verbs: " .. v .. " is the helper's own, not a page's")
    end
end

print("-- Popout page tools: the semantics that were lifted verbatim")
do
    -- ---- eager building, per instance, with the group handed back ----
    check(BODY:find("local pending = fresh()", 1, true) ~= nil,
          "semantics: the content is built EAGERLY at page-build time")
    check(BODY:find("local st = pending or fresh()", 1, true) ~= nil,
          "semantics: ...and a SECOND instance builds a fresh one through the same builder")
    check(BODY:find("end, pending.group", 1, true) ~= nil,
          "semantics: the eager group comes back beside the mount, for the key walk")
    -- The buildInto contract's exact shape: reflow THIS pane, then the page.
    check(BODY:find("buildInto(st.group, holder, function()", 1, true) ~= nil,
          "semantics: buildInto is handed the group, the holder and a refresh")
    check(BODY:find("ReflowPane(st)\n                page:RefreshStates()", 1, true) ~= nil,
          "semantics: ...whose refresh reflows this instance and then the page")

    -- ---- the values opt-in ------------------------------------------
    check(BODY:find("if values and g.RefreshChildValues then g:RefreshChildValues() end", 1, true) ~= nil,
          "semantics: the value repaint is OPT-IN, not part of every reflow")
    check(BODY:find("ReflowMounted(true)", 1, true) ~= nil,
          "semantics: ...and a group write is the one path that opts in")

    -- ---- the two-source key walk ------------------------------------
    check(BODY:find("local k  = (se and (se.dbKey or se.searchKey)) or (w and w.overrideDbKey)", 1, true) ~= nil,
          "semantics: the key walk reads the search entry AND the override stamp")
    check(BODY:find("for _, k in ipairs(extra or {}) do", 1, true) ~= nil,
          "semantics: ...with the extra-keys door for controls the walk cannot see")

    -- ---- claimed BY REFERENCE ---------------------------------------
    -- ClaimKeys fills row._claimedKeys AFTER the row is built, so a copy taken
    -- inside WireFooter would be the empty one.
    local footer = BODY:match("local function WireFooter%(row, apply, rowDB%)(.-)\n    end")
    check(footer ~= nil, "semantics: the footer is locatable")
    if footer then
        check(footer:find("local claimed", 1, true) == nil,
              "semantics: the footer never copies the claimed keys")

        -- ☠ THE VERBS WRITE WHERE THE ROW'S KEYS LIVE, WHICH IS NOT ALWAYS DF.db.
        -- A designer row's keys live on one indicator record behind a metatable
        -- proxy; handed the page db, Reset Group would resolve nothing and Hold:
        -- Defaults would snapshot the wrong table, both while reporting success.
        -- The override defaults to RowDB, which is every other caller, and there
        -- must be NO RowDB() left inside the verbs or one of the three would
        -- silently keep writing to the page.
        check(footer:find("rowDB = rowDB or RowDB", 1, true) ~= nil,
              "semantics: the footer's db defaults to the page's, and can be overridden")
        local rowDBcalls = 0
        for _ in footer:gmatch("rowDB%(%)") do rowDBcalls = rowDBcalls + 1 end
        eq(rowDBcalls, 3, "semantics: ...and all three verbs go through it")
        check(footer:find("RowDB()", 1, true) == nil,
              "semantics: ...with no verb left reading the page db directly")
        local refs = 0
        for _ in footer:gmatch("row%._claimedKeys or {}") do refs = refs + 1 end
        eq(refs, 3, "semantics: ...it re-reads them by reference at each verb")
        -- The undo engine gets the SAME apply reference, or an undo of a reset
        -- restores the numbers and leaves the frames where they were.
        check(footer:find("row._title or row._label, ApplyGroup)", 1, true) ~= nil,
              "semantics: the reset hands its apply to the undo engine")
        -- ...and the release is unthrottled, because that is the moment the user
        -- is watching for their settings to come back.
        check(footer:find('GUI:Call("refreshNow")', 1, true) ~= nil,
              "semantics: the hold's release applies unthrottled")
    end

    -- ---- the hold gate ----------------------------------------------
    local hold = BODY:match("local function HoldReason%(%)(.-)\n    end")
    check(hold ~= nil, "semantics: the hold gate is locatable")
    if hold then
        check(hold:find("CombatReason()", 1, true) ~= nil,
              "semantics: the hold gate is combat PLUS its own reason")
        check(hold:find("AP.IsEditing and AP:IsEditing()", 1, true) ~= nil
          and hold:find("AP.IsLayoutActive and AP:IsLayoutActive()", 1, true) ~= nil,
              "semantics: ...the raid auto-layout being edited or running")
        check(hold:find('GUI.SelectedMode == "raid"', 1, true) ~= nil,
              "semantics: ...and only in raid mode, where that machinery lives")
    end
    -- RESET stays available in both states, so the combat gate is the only one
    -- it carries.
    check(BODY:find("enabled     = CombatReason,", 1, true) ~= nil,
          "semantics: Reset Group is gated on combat alone")
    check(BODY:find("enabled     = HoldReason,", 1, true) ~= nil,
          "semantics: ...and only the hold takes the layout gate as well")

    -- ---- the write-back sweep ---------------------------------------
    local after = BODY:match("local function RefreshAfterGroupWrite%(apply%)(.-)\n    end")
    check(after ~= nil, "semantics: the post-write sweep is locatable")
    if after then
        check(after:find("if apply then apply() end", 1, true) ~= nil,
              "semantics: the group's own apply runs first")
        check(after:find("GUI.RefreshAllOverrideIndicators()", 1, true) ~= nil,
              "semantics: ...then the override indicators")
        check(after:find("page:RefreshStates()", 1, true) ~= nil,
              "semantics: ...then the page's own state pass")
    end

    -- ---- the band width is asked for, never a literal ---------------
    check(BODY:find("GUI.PageUsableWidth(GUI.PageChildWidth(", 1, true) ~= nil,
          "semantics: the band width comes from the page's own helper")
    check(BODY:find("GUI.SettingsBox.group)", 1, true) ~= nil,
          "semantics: ...floored at a box's width for a page with no size yet")

    -- ---- the hoisted toggle's search repair -------------------------
    check(BODY:find("Search:RegisterCheckbox(label, key, nil, false, onToggle)", 1, true) ~= nil,
          "semantics: a hoisted toggle keeps the entry its checkbox used to register")
    check(BODY:find("if not (Search and Search.RegisterCheckbox) then return end", 1, true) ~= nil,
          "semantics: ...guarded on the METHOD, so the page need not know search exists")

    -- ---- the control row's search repair ----------------------------
    -- ☠ ADOPT, THEN REGISTER WHAT IS MISSING -- because one of the two kinds is
    -- ALREADY in the registry by the time this runs. A control row's dropdown is
    -- the kit's own, and the kit fires the `registerSearch` host hook whenever it
    -- has a dbKey; a checkbox row's tick is hand-built from the shared styler and
    -- registers nothing. Registering both would put one setting in twice.
    local ctrl = BODY:match("local function RegisterControlRow%(row, kind, key, custom, callback%)(.-)\n    end")
    check(ctrl ~= nil, "semantics: the control row's registration is locatable")
    if ctrl then
        check(ctrl:find("local entry = row.control and row.control.searchEntry", 1, true) ~= nil,
              "control row: whatever the embedded factory already registered is adopted")
        check(ctrl:find('if not entry and kind == "checkbox" and Search.RegisterCheckbox then', 1, true) ~= nil,
              "control row: ...and only a kind that registered nothing is registered here")
        check(ctrl:find("Search:RegisterCheckbox(RowLabel(row), key, nil, custom and true or false, callback)", 1, true) ~= nil,
              "control row: ...under the ROW's own name, which is the only name it draws")
        check(ctrl:find("AnchorRow(row)", 1, true) ~= nil,
              "control row: the row answers to that name, so a jump can land on it")
        check(ctrl:find("StampSection(row, entry)", 1, true) ~= nil,
              "control row: ...and the entry says it lives there, not in the last band header")
        -- ⚠ NO ROW MAP ENTRY. That map exists so a hit on a control hidden BEHIND a
        -- row can open the panel it is behind; a control row opens nothing.
        check(ctrl:find("_popoutRowForKey", 1, true) == nil,
              "control row: ...and nothing is written to the row map, because there is no panel to open")
        local anchorAt = ctrl:find("AnchorRow(row)", 1, true)
        local guardAt  = ctrl:find("if not Search then return end", 1, true)
        check(anchorAt ~= nil and guardAt ~= nil and anchorAt < guardAt,
              "control row: the anchor is above the search guard, so a row is named either way")
    end
end

print("-- Popout page tools: the Frame page comes home")
do
    -- The page that WROTE this machinery is the last to take it back off the
    -- shelf, so the sweep ends with one copy instead of six.
    -- ⚠ SCOPED TO THE FRAME PAGE'S OWN SLICE, not to the whole file. Pages/
    -- Options.lua holds several pages, and a whole-file search would answer about
    -- General > Settings -- which sits above this one and was converted earlier --
    -- as readily as about this one.
    local SRC = options_file_source("GUI/Pages/Options.lua")
    local a = SRC:find('Add(CreateCopyButton(self.child, {"frame", "permanentMover"', 1, true)
    local b = SRC:find('{pageId = "general_sorting", label = L["Sorting"]}', 1, true)
    check(a ~= nil and b ~= nil and b > a, "frame page: locatable by its own ends")
    local page = SRC:sub(a or 1, b or 1)

    check(page:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true) ~= nil,
          "frame page: takes the shared machinery, unconditionally")
    for _, v in ipairs({ "PopoutContent", "ReflowPane", "ReflowMounted", "RowDB",
                         "ClaimKeys", "WireModifiedTick", "RefreshAfterGroupWrite",
                         "CombatReason", "HoldReason", "WireFooter",
                         "RegisterHoistedToggle" }) do
        check(page:find("local function " .. v .. "(", 1, true) == nil,
              "frame page: no longer re-declares " .. v)
    end
    -- The prologue's own state is the helper's too: a page that still touched
    -- either of these would be running half a second copy.
    check(page:find("_popoutHolders", 1, true) == nil,
          "frame page: never manages the popout holders itself")
    check(page:find("_popoutRowForKey", 1, true) == nil,
          "frame page: ...nor the search row map")

    -- ⚠ AND ITS BUILDERS TOOK THE HOUSE RENAME. Every builder on a converted page
    -- takes its opts as `tools2`, because `tools` is the page-scope machinery --
    -- a builder that shadowed the name could never reach the page's verbs.
    check(page:find("local function BuildFrameSizeGroup(tools2)", 1, true) ~= nil,
          "frame page: its builders take tools2, so nothing shadows the page's tools")
    check(page:find("(tools)", 1, true) == nil,
          "frame page: ...and no builder is left taking the shadowing name")
end

print("-- Popout page tools: a row is a section, in source")
do
    -- ☠ THE BUG THIS FIXES, stated once so the assertions below read as
    -- consequences rather than as taste. `entry.section` is stamped from
    -- Search.CurrentSection at registration, and CurrentSection is only ever
    -- moved by GUI:CreateHeader and GUI:CreateCollapsibleSection. A classic page
    -- interleaves those with its controls, so each entry inherits the header
    -- above it. A CONVERTED page does not: its band headers are built UP FRONT
    -- and then every row's pane is built eagerly, so every entry on the page
    -- inherited whichever band header was created LAST -- the whole Tooltips page
    -- reading "Auras". Section 6 drives the real thing and proves it; this
    -- section pins WHERE the repair lives, because "in the shared helper" is what
    -- makes it true of the pages already converted and of the ones still to come.
    check(BODY:find("Search:SetEntrySection(entry, name)", 1, true) ~= nil,
          "section: the stamp goes through Search's own door, not by hand")
    check(BODY:find("if not (entry and Search and Search.SetEntrySection) then return end", 1, true) ~= nil,
          "section: ...guarded on the METHOD, so a page need not know search exists")

    -- The row's name is read from the SAME pair the footer reads for the undo
    -- entry's heading, so a row is called one thing everywhere.
    check(BODY:find("local name = row and (row._title or row._label)", 1, true) ~= nil,
          "section: the row's name is _title or _label, the footer's own pair")

    -- ---- the anchor, and why it is inseparable from the stamp -------
    -- Renaming a breadcrumb to a section name nothing on the page answers to
    -- would leave the jump scrolling nowhere and flashing nothing.
    check(BODY:find("row.GetText = function() return name end", 1, true) ~= nil,
          "anchor: a row answers to its own name, as CreateHeader's container does")
    local anchorAt = BODY:find("AnchorRow(row)", 1, true)
    local guardAt  = BODY:find("if not (group and group.groupChildren) then return end", 1, true)
    check(anchorAt ~= nil and guardAt ~= nil and anchorAt < guardAt,
          "anchor: ...stamped ABOVE the group guard, so an empty pane still names its row")

    -- ---- the walk stamps, the extras deliberately do not ------------
    local claim = BODY:match("local function ClaimKeys%(row, group, extra%)(.-)\n    end")
    check(claim ~= nil, "section: the key walk is locatable")
    if claim then
        check(claim:find("StampSection(row, se)", 1, true) ~= nil,
              "section: every control the walk sees is re-sectioned onto the row")
        -- ⚠ AND THE EXTRA KEYS ARE NOT. An extra is named precisely because the
        -- walk cannot see it, so there is no searchEntry to stamp -- and reaching
        -- one would mean hunting the Registry by dbKey, which the search card
        -- cache's own key proves is ambiguous across pages.
        local extras = claim:match("for _, k in ipairs%(extra or {}%) do(.-)\n        end")
        check(extras ~= nil, "section: the extra-keys arm is locatable")
        check(extras == nil or extras:find("StampSection", 1, true) == nil,
              "section: ...and it re-sections nothing, because it has no entry to stamp")
    end

    -- ---- the hoisted toggle takes the same name ---------------------
    -- Its entry is registered from the PAGE builder rather than from inside a
    -- pane, so the walk never reaches it -- but it inherited the same wrong
    -- section, and the tick IS the row.
    local hoist = BODY:match("local function RegisterHoistedToggle%(row, label, key, onToggle%)(.-)\n    end")
    check(hoist ~= nil, "section: the hoisted toggle's registration is locatable")
    if hoist then
        check(hoist:find("StampSection(row, row.searchEntry)", 1, true) ~= nil,
              "section: a hoisted toggle's own entry is re-sectioned onto its row")
        check(hoist:find("AnchorRow(row)", 1, true) ~= nil,
              "section: ...and a row that only hoists a toggle is still anchored")
    end
end

-- ============================================================
-- 6. THE SAME THING, RUN RATHER THAN READ
-- ------------------------------------------------------------
-- ☠ THE HELPER CAN BE CALLED HEADLESSLY AFTER ALL -- but only the helper. Its
-- PROLOGUE touches nothing but the page table (the close is guarded, the holder
-- retire is skipped on a first build), and every verb it hands back is declared
-- there and then; the frames only appear inside PopoutContent, which this
-- section never calls. So the function is lifted out of Controls.lua BY SOURCE
-- -- the file as a whole is far too tangled in the panel to load -- compiled
-- into an environment holding a stub GUI and DF, and driven against the REAL
-- Features/Search.lua.
--
-- That is what makes this worth its length: the entry a row corrects is a
-- genuine registry entry, registered by the genuine Register under a genuine
-- stale section, so the correction is measured rather than asserted.
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME ACROSS EVERY TEST FILE. This section
-- replaces the `DandersFrames` global (Search.lua takes its host off it, not off
-- the varargs); it is restored at the end.
-- ============================================================
print("-- Popout page tools: a row is a section, driven for real")
do
    local savedDF = DandersFrames

    local DF = {}
    DF.L = setmetatable({}, { __index = function(_, k) return k end })
    -- Register drops any entry the current mode has no default for, so the two
    -- keys under test have to exist here or nothing would ever be registered.
    DF.PartyDefaults = { tooltipFrameX = 0, tooltipFrameEnabled = true,
                         tooltipResurrectionEnabled = true }
    DF.RaidDefaults  = { tooltipFrameX = 0, tooltipFrameEnabled = true,
                         tooltipResurrectionEnabled = true }
    -- The live settings tables RowDB answers with. A hoisted control is bound to
    -- the very table the panel's own control writes, so the verb has to have one
    -- to resolve.
    DF.db = { party = { tooltipFrameX = 0 }, raid = { tooltipFrameX = 0 } }
    function DF:DebugWarn() end
    -- SettingsBox only has to EXIST for Search.lua's file scope to load; the real
    -- table is driven against Search.lua in test_page_parking.
    DF.GUI = {
        SelectedMode = "party",
        Pages = {},
        SettingsBox = { group = 280, pad = 10, colMargin = 5, minCol = 285, colGutter = 20 },
    }
    local classic = false
    DF.IsClassicSettingsLayout = function() return classic end
    DandersFrames = DF

    load_options_file_into("Features/Search.lua", NS)
    local Search = DF.Search
    check(Search ~= nil, "live: the real Search file loads")
    check(Search and Search.SetEntrySection ~= nil,
          "live: ...and publishes the after-the-fact section door the helper calls")

    -- The helper, compiled into its own environment. `GUI` and `DF` are file
    -- locals in Controls.lua, so as a standalone chunk they are globals -- which
    -- setfenv is exactly for. Everything else falls through to the real _G.
    local env = setmetatable({ GUI = DF.GUI, DF = DF, L = DF.L }, { __index = _G })
    local fn = (loadstring or load)(CHUNK, "@CreatePopoutPageTools")
    check(fn ~= nil, "live: the helper's source compiles on its own")
    if fn then
        setfenv(fn, env)
        fn()
    end
    check(DF.GUI.CreatePopoutPageTools ~= nil, "live: ...and installs itself on GUI")

    -- One page's worth of registrations, in the order a CONVERTED page makes
    -- them: the band header first (which is all SetCurrentSection ever hears),
    -- then every pane's controls, eagerly, underneath it.
    local function registerUnder(section, label, key)
        Search:SetCurrentSection(section)
        return Search:RegisterCheckbox(label, key)
    end

    local page, tools, band, hoisted, ctrlTick, ctrlDrop
    local function buildPage()
        Search.Registry = {}
        Search.RegistryBuilt = false
        Search:SetCurrentTab("tooltips", "Tooltips")
        page  = {}
        tools = DF.GUI:CreatePopoutPageTools(page)
        -- The LAST band header on the page -- the wrong answer every entry below
        -- it inherits, which is the whole bug.
        band  = registerUnder("Auras", "Show Out of Combat", "tooltipFrameX")
        hoisted, ctrlTick, ctrlDrop = nil, nil, nil
        if tools then
            local row = { _label = "Frame Tooltips" }
            tools.ClaimKeys(row, { groupChildren = { { widget = { searchEntry = band } } } })

            local togRow = { _label = "Binding Tooltips" }
            tools.RegisterHoistedToggle(togRow, "Enable Binding Tooltips",
                                        "tooltipFrameEnabled", function() end)
            hoisted = { row = togRow, entry = togRow.searchEntry }

            -- A CHECKBOX control row. Its tick is hand-built from the shared
            -- styler, so NOTHING has registered it and the verb has to.
            local tickRow = { _label = "Resurrection Icon Tooltips" }
            local before  = #Search.Registry
            tools.RegisterControlRow(tickRow, "checkbox", "tooltipResurrectionEnabled")
            ctrlTick = { row = tickRow, added = #Search.Registry - before }

            -- A DROPDOWN control row. The kit's own dropdown fires the
            -- registerSearch host hook and stamps the entry on the container, so
            -- by the time the verb runs the setting is ALREADY in the registry --
            -- under the stale band section, like everything else on the page.
            local ddEntry = registerUnder("Auras", "Addon Language", "tooltipFrameX")
            local ddRow   = { _label = "Addon Language", control = { searchEntry = ddEntry } }
            before = #Search.Registry
            tools.RegisterControlRow(ddRow, "dropdown", "tooltipFrameX")
            ctrlDrop = { row = ddRow, entry = ddEntry, added = #Search.Registry - before }

            return row, togRow
        end
    end

    -- ---- the popout layout: the row names what is behind it ---------
    classic = false
    local row, togRow = buildPage()
    check(tools ~= nil, "live: the popout layout hands back the tools")
    eq(band.section, "Frame Tooltips",
       "live: a claimed control reads its ROW's name, not the last band header")
    eq(page._popoutRowForKey["tooltipFrameX"], row,
       "live: ...and the row map still points the jump at that row")
    eq(row.GetText and row:GetText(), "Frame Tooltips",
       "live: ...and the row answers to that same name, so the jump can land")

    -- The stale section's words go with it. They are not cosmetic: Find scores a
    -- keyword hit, so "auras" left behind would keep matching every control on a
    -- page that has nothing to do with auras.
    local words = {}
    for _, k in ipairs(band.keywords or {}) do words[k] = true end
    check(not words["auras"], "live: the old section's keywords are dropped, not kept")
    check(words["frame"] and words["tooltips"],
          "live: ...and the new one's are indexed in their place")
    check(words["combat"], "live: ...while the entry's own label survives untouched")

    -- ---- the hoisted toggle -----------------------------------------
    check(hoisted ~= nil and hoisted.entry ~= nil, "live: the hoisted toggle registered an entry")
    if hoisted and hoisted.entry then
        eq(hoisted.entry.section, "Binding Tooltips",
           "live: a hoisted toggle's entry reads its own row, not the last band header")
        eq(togRow.GetText and togRow:GetText(), "Binding Tooltips",
           "live: ...and that row is anchored too, though it claimed nothing")
    end

    -- ---- the control rows -------------------------------------------
    check(ctrlTick ~= nil and ctrlTick.row.searchEntry ~= nil,
          "live: a checkbox control row registers the entry nothing else would")
    if ctrlTick then
        eq(ctrlTick.added, 1, "live: ...exactly one entry, not two")
        eq(ctrlTick.row.searchEntry.dbKey, "tooltipResurrectionEnabled",
           "live: ...against the key the row is bound to")
        eq(ctrlTick.row.searchEntry.label, "Resurrection Icon Tooltips",
           "live: ...under the row's own name, which is the only name it draws")
        eq(ctrlTick.row.searchEntry.section, "Resurrection Icon Tooltips",
           "live: ...and it says it lives on that row, not under the last band header")
        eq(ctrlTick.row.GetText and ctrlTick.row:GetText(), "Resurrection Icon Tooltips",
           "live: ...which the row answers to, so the jump can land on it")
        -- ⚠ NO ROW MAP ENTRY: a control row opens nothing, so there is no panel
        -- for the jump's last step to open.
        eq(page._popoutRowForKey["tooltipResurrectionEnabled"], nil,
           "live: ...and the row map is left alone, because there is no panel behind it")
    end

    check(ctrlDrop ~= nil, "live: a dropdown control row is driven")
    if ctrlDrop then
        -- ☠ THE POINT OF THE WHOLE SHAPE OF THE VERB: the kit already put this one
        -- in, so the verb must correct it rather than register one setting twice.
        eq(ctrlDrop.added, 0, "live: a dropdown control row adds NO second entry")
        eq(ctrlDrop.row.searchEntry, ctrlDrop.entry,
           "live: ...it adopts the entry the kit's own factory registered")
        eq(ctrlDrop.entry.section, "Addon Language",
           "live: ...and re-sections it onto the row, off the stale band header")
        local ddWords = {}
        for _, k in ipairs(ctrlDrop.entry.keywords or {}) do ddWords[k] = true end
        check(not ddWords["auras"], "live: ...dropping the old section's words with it")
        eq(ctrlDrop.row.GetText and ctrlDrop.row:GetText(), "Addon Language",
           "live: ...and that row is anchored too")
    end

    -- ---- the hoisted CONTROLS, the same verb's other form ------------
    -- A hoisted CONTROL is the panel's own setting shown twice: a second widget
    -- on the SAME table and key. Two things have to be true of that and neither
    -- is observable in source.
    --
    --   * SEARCH MUST NOT SEE IT TWICE. The pane's own control is already in the
    --     registry under that label, key and section; a second registration is
    --     two identical result cards for one setting.
    --   * THE KEY IS CLAIMED ONCE. ClaimKeys walks the PANE, and a hoisted
    --     control is not in it -- so the row's claimed set (its amber tick, its
    --     Reset Group, its Hold) counts the key exactly once however many widgets
    --     are bound to it.
    do
        Search.Registry = {}
        Search.RegistryBuilt = false
        Search:SetCurrentTab("frame", "Frame")
        local hpage = {}
        local htools = DF.GUI:CreatePopoutPageTools(hpage)
        check(htools ~= nil, "hoist: the tools are up")

        -- The pane's own control, registered the way a page's builder registers
        -- it -- under whichever band header was built last.
        Search:SetCurrentSection("Auras")
        local paneEntry = Search:RegisterCheckbox("Frame Width", "tooltipFrameX")
        local hrow = { _label = "Frame Size" }
        htools.ClaimKeys(hrow, { groupChildren = { { widget = { searchEntry = paneEntry } } } })
        eq(#hrow._claimedKeys, 1, "hoist: the pane's control claimed its key once")

        -- ...and now the row hoists it. The row stands in for a real PopoutRow:
        -- what the verb is being asked for is the LIST it hands over.
        -- ☠ THE STUB REGISTERS, BECAUSE THE REAL ONE DOES. SetHoistedControls
        -- builds the control with the KIT's own factory, and every db-bound kit
        -- factory fires the `registerSearch` host hook -- which is the whole
        -- reason the verb has to suppress anything. A stub that quietly built
        -- nothing would let the suppression assertion below pass against a verb
        -- that had never suppressed a thing.
        local handed
        hrow.SetHoistedControls = function(self, list)
            handed = list
            for _, h in ipairs(list) do
                Search:RegisterSlider(h.name, h.key, h.min, h.max, h.step)
            end
            return self
        end
        local before = #Search.Registry
        htools.RegisterHoistedToggle(hrow, {
            { name = "Frame Width", kind = "slider", key = "tooltipFrameX",
              min = 60, max = 300, step = 1 },
        })
        check(handed ~= nil, "hoist: the table form reaches the row's own declaration door")
        eq(#handed, 1, "hoist: ...with the one control it was given")
        eq(handed[1].name, "Frame Width",
           "hoist: named with the panel's own string, so the two are provably one setting")
        eq(handed[1].key, "tooltipFrameX", "hoist: ...on the panel's own key")
        check(handed[1].db ~= nil, "hoist: ...and bound to a real TABLE, not left to a getter")

        -- The two claims this block exists for.
        eq(#Search.Registry - before, 0,
           "hoist: a hoisted control registers NOTHING -- the pane's twin is already indexed")
        eq(#hrow._claimedKeys, 1,
           "hoist: ...and the key is still claimed once, not twice")

        -- The suppression is a bracket, not a switch someone has to remember to
        -- turn off: an ordinary registration straight afterwards still lands.
        local after = #Search.Registry
        Search:RegisterCheckbox("Frame Height", "tooltipFrameEnabled")
        eq(#Search.Registry - after, 1, "hoist: and search is live again the moment it returns")

        -- The TOGGLE form is untouched by the overload -- second argument a
        -- string, and it registers exactly as it always did.
        local togBefore = #Search.Registry
        local trow = { _label = "Border" }
        htools.RegisterHoistedToggle(trow, "Show Border", "tooltipResurrectionEnabled", function() end)
        eq(#Search.Registry - togBefore, 1,
           "hoist: the toggle form still registers its own entry, which nothing else would")
    end

    -- ---- and CLASSIC is untouched, by construction -------------------
    -- The helper returns nil before it declares a single verb, so there is
    -- nothing in the classic layout that could stamp anything: an entry keeps
    -- exactly the section CreateHeader gave it.
    classic = true
    buildPage()
    check(tools == nil, "classic: the helper hands back nothing at all")
    eq(band.section, "Auras",
       "classic: ...so an entry keeps exactly the section its header set")
    local classicWords = {}
    for _, k in ipairs(band.keywords or {}) do classicWords[k] = true end
    check(classicWords["auras"], "classic: ...keywords and all")

    DandersFrames = savedDF
end

-- ============================================================
-- THE PANE LOSES ITS COPY OF A HOISTED CONTROL -- driven, end to end
-- ------------------------------------------------------------
-- ☠ THE COUNT AND THE PANEL HAVE TO AGREE. The strip promised "3 more settings"
-- and the panel then opened with five, two of them the sliders the user had just
-- looked at on the row's own plate. A key on the plate is HIDDEN in the pane --
-- never removed, because the fold, the split and the gate all take a key back
-- off the plate and the setting has to be reachable again the moment they do.
--
-- Three parts meet here and none of them knows the other two: the ROW knows
-- which keys are on its plate (DandersUI/PopoutRow.lua), the GROUP knows how to
-- leave a child out of a layout (DandersUI/Sections.lua's SetChildHidden), and
-- ClaimKeys knows which widget carries which key. So this is the one place the
-- claim can be made honestly, and it is DRIVEN rather than censused: real
-- frames, the real kit, the real helper compiled out of Controls.lua.
--
-- ⚠ A PRIVATE KIT, for test_control_row.lua's reason -- this file runs BEFORE
-- test_popout_row.lua and test_sections_group.lua alphabetically, and installing
-- a stub onto the shared library table is a stub those suites would adopt. The
-- token tables are the REAL Theme.lua's, loaded into a throwaway namespace, so
-- the arithmetic below is the shipped rhythm rather than numbers invented here.
-- ============================================================
print("-- Popout page tools: a hoisted control leaves the pane behind the row")
do
    local savedDF, savedCreateFrame = DandersFrames, CreateFrame

    -- ---- the private kit ---------------------------------------------
    local themeNS = { __DandersUI = { _state = {}, _priv = {} } }
    load_ui_file_into("Theme.lua", themeNS)
    local T = themeNS.__DandersUI

    local UI = {
        MEDIA = "",
        Colors = T.Colors,
        RowGap = T.RowGap, RowGapTight = T.RowGapTight, RowCompact = {},
        RowHeight = T.RowHeight,
        SettingsBox = T.SettingsBox,
        PopoutContentWidth = T.PopoutContentWidth,
        PopoutPad = T.PopoutPad,
        PopoutRow = T.PopoutRow,
        _state = {},
        _priv = {
            INFO_BANNER_TONES = {},
            AddTooltipLines = function() end,
            CURSOR_LIFT_X = 0, CURSOR_LIFT_Y = 0,
            -- Sections.lua takes this off _priv and calls it WITHOUT a self.
            CreateElementBackdrop = function(frame, opts) frame._elementOpts = opts return frame end,
        },
    }
    do
        local SHARED = NS.__DandersUI
        for _, name in ipairs({ "SurfaceStyle", "ResolveSurfaceStyle", "SetSurfaceStyle",
                                "GetSurfaceStyle", "HidePixelBorder",
                                "CreateRoundedSurface", "GetRoundedSurface",
                                "ApplyRoundedChrome", "RemoveRoundedChrome" }) do
            UI[name] = SHARED[name]
        end
    end
    -- No snapping: every number below is the arithmetic the layout did, and a
    -- rounding pass would make it about the device grid instead.
    function UI.SnapLen(_, n) return n end
    UI.ResolveRowHeight = T.ResolveRowHeight
    local ACCENT = { r = 0.45, g = 0.45, b = 0.95, a = 1 }
    function UI:GetAccent() return ACCENT end
    function UI:Hook(name) local h = rawget(self, "hooks") return h and h[name] or nil end
    function UI:Call(name, ...)
        local fn = self:Hook(name)
        if not fn then return nil end
        return fn(...)
    end
    function UI:CreateElementBackdrop(frame, opts)
        opts = opts or {}
        frame._elementOpts = opts
        frame.SetBackdropColor = function(self, r, g, b, a) self._fill = { r, g, b, a } end
        frame.SetBackdropBorderColor = function(self, r, g, b, a) self._edge = { r, g, b, a } end
        return frame
    end
    function UI:ApplyPixelBorder(frame, color, weight)
        frame._pxColor, frame._pxWeight = color, weight
        return frame
    end
    function UI:StyleCheckButton(cb, opts)
        opts = opts or {}
        cb:SetSize(opts.size or 18, opts.size or 18)
        cb.Check = cb.Check or FakeUIFrame()
        cb.ApplyThemeColor = function(c) cb._tint = c end
        return cb.Check
    end
    function UI:CreateLabelNative(parent, opts)
        local fs = FakeUIFrame()
        fs.SetTextColor = function(self, r, g, b, a) self._textColor = { r, g, b, a } end
        if opts and opts.text then fs:SetText(opts.text) end
        return fs
    end
    function UI:ShowTooltip() end
    function UI:HideTooltip() end
    local function boundValue(opts)
        if opts.get then return opts.get() end
        if opts.dbRef and opts.dbRef.db then return opts.dbRef.db[opts.dbRef.key] end
        return nil
    end
    function UI:CreateSliderNative(parent, opts)
        local c = CreateFrame("Frame", nil, parent)
        c._sliderOpts = opts
        c.label = FakeUIFrame()
        c.label:Show()
        c.refreshValue = function(self) self._value = boundValue(opts) end
        c:refreshValue()
        return c
    end
    function UI:CreateDropdownNative(parent, opts)
        local c = CreateFrame("Frame", nil, parent)
        c._dropdownOpts = opts
        c.label = FakeUIFrame()
        c.refreshValue = function(self) self._value = boundValue(opts) end
        c:refreshValue()
        return c
    end

    -- ☠ A MISSING DATA FIELD MUST READ nil, NOT A FUNCTION. FakeUIFrame answers
    -- every unknown key with a no-op function, which is right for METHODS and
    -- wrong for STATE -- and this suite turns on two pieces of state read straight
    -- off a widget: `hideOn` (Sections' entryVisible) and `searchEntry` /
    -- `overrideDbKey` (ClaimKeys' KeyOf, which would then INDEX a function).
    local DATA_KEYS = { hideOn = true, searchEntry = true, overrideDbKey = true,
                        tooltip = true, control = true, dfDisabled = true }
    CreateFrame = function(kind, _, parent)
        local f = FakeUIFrame()
        setmetatable(f, { __index = function(_, k)
            if DATA_KEYS[k] then return nil end
            if type(k) == "string" and k:byte(1) == 95 then return nil end   -- "_"
            return function() end
        end })
        f._kind = kind
        f._parent = parent
        f.GetParent = function(self) return self._parent end
        f.SetParent = function(self, p) self._parent = p end
        if kind == "CheckButton" then
            f.SetChecked = function(self, v) self._checked = v and true or false end
            f.GetChecked = function(self) return self._checked end
        end
        return f
    end

    -- The row plate's box model, off the REAL Theme.lua: the fold width below is
    -- the shipped floor rather than a number invented here.
    local M0 = UI.PopoutRow
    local kitL = setmetatable({}, { __index = function(_, k) return k end })
    local kitHost = setmetatable({ hooks = { L = kitL } }, { __index = UI })
    local PRIVATE_NS = { __DandersUI = UI }
    load_ui_file_into("Sections.lua", PRIVATE_NS)
    load_ui_file_into("PopoutRow.lua", PRIVATE_NS)

    -- ---- the addon surface the helper compiles against ---------------
    local paneDB = { frameWidth = 100, frameHeight = 50,
                     frameScale = 1, framePadding = 0, frameSpacing = 0 }
    local DF = {}
    DF.L = kitL
    DF.db = { party = paneDB, raid = paneDB }
    function DF:DebugWarn() end
    DF.IsClassicSettingsLayout = function() return false end
    local GUIstub = {
        SelectedMode = "party",
        Pages = {},
        SettingsBox = T.SettingsBox,
        PopoutContentWidth = T.PopoutContentWidth,
        _trashFrame = CreateFrame("Frame"),
        CreateSettingsGroup = function(_, parent, width, opts)
            return kitHost:CreateSettingsGroup(parent, width, opts)
        end,
    }
    DF.GUI = GUIstub
    DandersFrames = DF

    local env = setmetatable({ GUI = GUIstub, DF = DF, L = kitL }, { __index = _G })
    local fn = (loadstring or load)(CHUNK, "@CreatePopoutPageTools")
    check(fn ~= nil, "pane: the helper's source compiles on its own")
    if fn then setfenv(fn, env) fn() end

    local page = { child = CreateFrame("Frame") }
    function page:RefreshStates() end
    local tools = GUIstub:CreatePopoutPageTools(page)
    check(tools ~= nil, "pane: the tools are up")

    -- ---- the fixture: five keyed controls behind one row -------------
    -- Deliberately five PLAIN keyed widgets rather than real factories: what is
    -- under test is which of them the layout places, and a widget whose whole
    -- contract is "I am bound to this key" is the honest stand-in for that.
    local KEYS = { "frameWidth", "frameHeight", "frameScale", "framePadding", "frameSpacing" }
    local function paneControl(key)
        local w = CreateFrame("Frame")
        w.preferredHeight = 30
        w.overrideDbKey = key
        return w
    end
    local built = {}
    local mount, group = tools.PopoutContent(function(g)
        local mine = {}
        for _, key in ipairs(KEYS) do
            local w = paneControl(key)
            g:AddWidget(w, 30)
            mine[#mine + 1] = w
        end
        built[#built + 1] = mine
    end)
    check(group ~= nil and group.groupChildren ~= nil, "pane: the eager group came back")
    eq(#group.groupChildren, 5, "pane: ...with all five of the row's controls in it")

    -- How many of a group's children the LAYOUT actually placed. Read off the
    -- widgets rather than off the marks, because the mark is the input and the
    -- Show is what the user sees.
    local function visible(g)
        local n = 0
        for _, e in ipairs(g.groupChildren) do
            if e.widget and e.widget:IsShown() then n = n + 1 end
        end
        return n
    end

    -- ---- the row, at a width that draws both hoisted cells -----------
    local row = kitHost:CreatePopoutRow(page.child, {
        label = "Frame Size", db = tools.RowDB, count = #KEYS,
        footerStrip = true, build = function() end,
    })
    row:SetWidth(401)

    -- ☠ THE WAY IN, ON THE SHIPPED TOKENS. test_popout_row.lua's section 24
    -- drives the strip's mouse against that file's MIRROR of UI.PopoutRow; this
    -- kit reads the real Theme.lua, so this is the one place where the numbers the
    -- user actually sees are the numbers under test. The strip is the only thing
    -- that opens the panel and the only thing that lights.
    do
        local strip = row.footerStrip
        eq(strip._kind, "Button", "way in: the strip is a Button, because it answers a click")
        check(strip._flags.mouseClick, "way in: ...with the mouse actually on it")
        check(strip:GetScript("OnClick") ~= nil, "way in: it carries the click")
        eq(row._stripFill._color.a, M0.footerFill, "way in: and rests at the shipped fill alpha")
        strip:GetScript("OnEnter")(strip)
        eq(row._stripFill._color.a, M0.footerHover, "way in: hovering it lights the band")
        eq(row._stripFill._color.r, T.Colors.hover.r, "way in: ...in the shipped hover colour")
        strip:GetScript("OnLeave")(strip)
        eq(row._stripFill._color.a, M0.footerFill, "way in: and leaving puts it back")
    end

    -- ⚠ CLAIM FIRST, HOIST SECOND -- the order the Frame page uses (ClaimKeys,
    -- the tick, the footer, THEN RegisterHoistedToggle). The second order is
    -- driven at the foot of this block.
    tools.ClaimKeys(row, group)
    eq(#row._claimedKeys, 5, "pane: the row claims every key behind it, hoisted or not")
    -- ⚠ NOT LAID OUT YET, and that is the eager build being eager: the group is
    -- parked in a hidden holder until a panel mounts it or something re-flows it.
    -- The count on the strip is the row's own arithmetic and is already right.
    eq(visible(group), 0, "pane: the eagerly built group has not been laid out yet")
    eq(row.stripCount:GetText(), "5 more settings", "pane: ...which is what the strip says")

    tools.RegisterHoistedToggle(row, {
        { name = "Frame Width", kind = "slider", key = "frameWidth",
          min = 60, max = 300, step = 1 },
        { name = "Frame Height", kind = "slider", key = "frameHeight",
          min = 20, max = 300, step = 1 },
    })

    -- ☠ THE ASSERTION THE WHOLE SECTION EXISTS FOR.
    eq(row:GetShownHoistCount(), 2, "pane: the row draws its two hoisted controls")
    eq(visible(group), 3, "pane: ...and the pane behind it draws exactly the other three")
    eq(row.stripCount:GetText(), "3 more settings", "pane: ...which is the number the strip promises")
    eq(#group.groupChildren, 5, "pane: HIDDEN, never removed -- all five entries are still there")
    for _, e in ipairs(group.groupChildren) do
        local k = e.widget.overrideDbKey
        local onPlate = (k == "frameWidth" or k == "frameHeight")
        local drawn = e.widget:IsShown() and true or false
        eq(drawn, not onPlate, "pane: " .. k .. " is drawn in exactly one place")
    end

    -- ⚠ SEARCH IS UNTOUCHED. The jump opens the ROW (Search:OpenOwningPopoutRow
    -- reads page._popoutRowForKey), never the pane child -- so a hidden copy is
    -- never a jump target, and the map still names the row for a hoisted key.
    eq(page._popoutRowForKey["frameWidth"], row,
       "pane: a hoisted key still maps to the row the panel hangs off")
    eq(page._popoutRowForKey["frameSpacing"], row,
       "pane: ...and so does one that stayed behind the click")

    -- ---- the way back: the fold ---------------------------------------
    -- Below the width where a line cannot hold one named control the row folds,
    -- and every setting has to be reachable again -- which is the whole of
    -- "hidden, never removed".
    row:SetWidth(M0.padX + M0.check + M0.labelGap + M0.padX + M0.minControl - 1)
    row._LayoutPlate()
    eq(row:GetShownHoistCount(), 0, "fold: under the floor the row draws no controls")
    eq(visible(group), 5, "fold: ...and all five come back into the pane")
    eq(row.stripCount:GetText(), "5 more settings", "fold: ...with the strip's count back up")

    row:SetWidth(401)
    row._LayoutPlate()
    eq(row:GetShownHoistCount(), 2, "fold: widening puts them back on the plate")
    eq(visible(group), 3, "fold: ...and takes them out of the pane again")

    -- ---- the SECOND instance ------------------------------------------
    -- Pin the panel open and click the row again and the shell asks the factory
    -- for content a second time. That instance is built AFTER the row last
    -- announced its set, so nothing would ever have told it -- the mount is what
    -- does, and a panel that opened showing the duplicate is exactly the bug.
    local function fakePanel()
        local pane = CreateFrame("Frame")
        local po = { closed = false, SyncRowPaneHeight = function() end }
        return po, pane
    end
    local po1, pane1 = fakePanel()
    mount(po1, pane1)
    eq(#built, 1, "second: the FIRST mount adopts the eagerly built group")
    eq(visible(group), 3, "second: ...which is still hiding the two on the plate")

    local po2, pane2 = fakePanel()
    mount(po2, pane2)
    eq(#built, 2, "second: a second mount builds a fresh instance through the same builder")
    -- The fresh group is the one the SECOND run of the builder filled, found
    -- through the widgets it made rather than by reaching into the factory.
    local second = built[2]
    local function shownIn(list)
        local n = 0
        for _, w in ipairs(list) do if w:IsShown() then n = n + 1 end end
        return n
    end
    eq(shownIn(second), 3, "second: ...and it opens with the same three, not with all five")

    -- ...and it goes on tracking the row. A change after BOTH are open has to
    -- reach both: a hide applied to the eager instance alone would leave the
    -- pinned panel showing the duplicate the moment the row folded and came back.
    row:SetWidth(M0.padX + M0.check + M0.labelGap + M0.padX + M0.minControl - 1)
    row._LayoutPlate()
    eq(shownIn(built[1]), 5, "second: the fold puts all five back in the first panel")
    eq(shownIn(second), 5, "second: ...and in the second one too")
    row:SetWidth(401)
    row._LayoutPlate()
    eq(shownIn(built[1]), 3, "second: widening takes the two out of the first panel again")
    eq(shownIn(second), 3, "second: ...and out of the second, which is the whole point of the list")

    -- ---- ...UNLESS THE PANEL IS PINNED ---------------------------------
    -- ☠ A PINNED PANEL SHOWS EVERY SETTING. Pinning detaches a panel from
    -- the row it came out of, and the user pins one in order to CHANGE PAGE --
    -- at which point the row carrying the width and height sliders on its plate
    -- is not on screen at all, and a panel that had left them out would be a
    -- panel with no way to reach them. So the hide above is the LOOSE panel's
    -- rule, and a pinned instance opts out of it whatever the row says.
    --
    -- ⚠ WHAT THIS DRIVES AND WHAT IT DOES NOT. The shell's half -- Popout:Pin
    -- flipping the flag and calling the row's onPin, and the row announcing that
    -- to whoever asked -- is driven against a REAL Popout in test_popout_row.lua
    -- (24.14). There is no shell in this file's private kit, so `pinPanel` below
    -- is that contract in miniature: set the flag, then tell the row's consumer.
    -- What is under test up here is what CONTROLS.LUA does once it is told.
    local pinRow = kitHost:CreatePopoutRow(page.child, {
        label = "Pinnable", db = tools.RowDB, count = #KEYS,
        footerStrip = true, build = function() end,
    })
    pinRow:SetWidth(401)
    local pinBuilt = {}
    local pinMount, pinGroup = tools.PopoutContent(function(g)
        local mine = {}
        for _, key in ipairs(KEYS) do
            local w = paneControl(key)
            g:AddWidget(w, 30)
            mine[#mine + 1] = w
        end
        pinBuilt[#pinBuilt + 1] = mine
    end)
    -- The row's own verb, captured on the way past rather than reached for
    -- afterwards: what ClaimKeys registered is exactly what the shell would
    -- eventually call, so the test plays the shell and nothing else is faked.
    local pinHook
    local realSetPin = pinRow.SetOnPanelPinned
    pinRow.SetOnPanelPinned = function(self, fn)
        pinHook = fn
        return realSetPin(self, fn)
    end
    tools.ClaimKeys(pinRow, pinGroup)
    check(pinHook ~= nil, "pin: the claim asks the row to tell it when a panel is pinned")
    tools.RegisterHoistedToggle(pinRow, {
        { name = "Frame Width", kind = "slider", key = "frameWidth",
          min = 60, max = 300, step = 1 },
        { name = "Frame Height", kind = "slider", key = "frameHeight",
          min = 20, max = 300, step = 1 },
    })
    eq(pinRow:GetShownHoistCount(), 2, "pin: the row draws its two hoisted controls")

    local function pinPanel(po)
        po.pinned = true
        pinHook(pinRow, po)
    end

    local pinnedPo, pinnedPane = fakePanel()
    pinMount(pinnedPo, pinnedPane)
    eq(shownIn(pinBuilt[1]), 3, "pin: the panel opens with the other three, like any loose one")
    pinPanel(pinnedPo)
    eq(shownIn(pinBuilt[1]), 5, "pin: pinning it puts every setting back")
    eq(pinRow.stripCount:GetText(), "3 more settings",
       "pin: the strip is about the LOOSE panel, so it does not move")

    -- ☠ ...AND IT DOES NOT MOVE WHEN SOMETHING REPAINTS IT EITHER, which is
    -- the half the line above cannot see. The number is painted from the layout
    -- and from the refresh, and the pin ran between two of them -- so a strip that
    -- was merely STALE would read the same thing there and flip on the next pass.
    -- It does not, because the provider counts the pane AS THE LOOSE PANEL WOULD
    -- DRAW IT: the marks on the instance it can reach are not consulted at all.
    -- Wired to the eager group, which is exactly the instance just pinned.
    pinRow._LayoutPlate()
    eq(pinRow.stripCount:GetText(), "3 more settings",
       "pin: ...and a repaint after the pin says the same number")
    pinRow.Refresh()
    eq(pinRow.stripCount:GetText(), "3 more settings", "pin: ...as does a refresh")
    eq(shownIn(pinBuilt[1]), 5,
       "pin: ...while the pinned panel it is counting still draws every setting")

    -- The row's next click asks the factory for content again, because the pin
    -- promoted that instance out of the pool. That one is not pinned, so it hides
    -- exactly as before -- the rule is per INSTANCE, not per row.
    local loosePo, loosePane = fakePanel()
    pinMount(loosePo, loosePane)
    eq(#pinBuilt, 2, "pin: the next panel is a fresh instance through the same builder")
    eq(shownIn(pinBuilt[2]), 3, "pin: ...and it opens hiding the two on the plate")
    eq(shownIn(pinBuilt[1]), 5, "pin: ...while the pinned one still shows all five")

    -- ☠ AND THE ROW GOES ON MOVING UNDERNEATH BOTH OF THEM. The fold reaches
    -- every instance, so the loose one gets its copies back -- and the widening
    -- that follows must NOT take them off the pinned one again, which is the one
    -- way a rule written in the announcement rather than in the apply would fail.
    pinRow:SetWidth(M0.padX + M0.check + M0.labelGap + M0.padX + M0.minControl - 1)
    pinRow._LayoutPlate()
    eq(shownIn(pinBuilt[2]), 5, "pin: the fold puts all five back in the loose panel")
    eq(shownIn(pinBuilt[1]), 5, "pin: ...and leaves the pinned one whole")
    eq(pinRow.stripCount:GetText(), "5 more settings",
       "pin: ...and the strip has its whole number back, pinned instance or not")
    pinRow:SetWidth(401)
    pinRow._LayoutPlate()
    eq(shownIn(pinBuilt[2]), 3, "pin: widening takes them out of the loose panel again")
    eq(shownIn(pinBuilt[1]), 5, "pin: ...and STILL leaves the pinned one whole")
    eq(pinRow.stripCount:GetText(), "3 more settings",
       "pin: ...and the strip is back to three, though the pinned panel keeps its five")

    -- ⚠ AND A PIN ANSWERS FOR THE INSTANCE IT NAMES, NOT FOR THE LIST. The
    -- hook is handed one panel; a loose one standing beside it has to go on
    -- hiding. Driven straight, because the shell hands a row ONE loose panel at a
    -- time and would therefore never expose a mistake here until the day it did.
    local thirdPo, thirdPane = fakePanel()
    pinMount(thirdPo, thirdPane)
    eq(#pinBuilt, 3, "pin: a third instance came through the same builder")
    eq(shownIn(pinBuilt[3]), 3, "pin: ...hiding the two on the plate, like any loose panel")
    pinPanel(thirdPo)
    eq(shownIn(pinBuilt[3]), 5, "pin: pinning it gives that one every setting")
    eq(shownIn(pinBuilt[2]), 3, "pin: ...and leaves the panel that is still loose hiding")

    -- ---- AN EMPTY PANE, PINNED ----------------------------------------
    -- ☠ THE ROW THE FOLLOW-UP WAS REPORTED ON. Every setting behind this row
    -- is on its plate, so the pane draws nothing and the strip stops promising a
    -- count and offers to pin instead -- and the click that reads those words
    -- pins. A count read off the pinned instance's marks would then say "2 more
    -- settings" over a panel that is already open, and the next click would only
    -- raise it: wrong words for a right click. The words have to survive the very
    -- gesture they asked for.
    local emptyBuilt = {}
    local emptyMount, emptyGroup = tools.PopoutContent(function(g)
        local mine = {}
        for _, key in ipairs({ "frameWidth", "frameHeight" }) do
            local w = paneControl(key)
            g:AddWidget(w, 30)
            mine[#mine + 1] = w
        end
        emptyBuilt[#emptyBuilt + 1] = mine
    end)
    local emptyRow = kitHost:CreatePopoutRow(page.child, {
        label = "All hoisted", db = tools.RowDB, count = 2,
        footerStrip = true, build = function() end,
    })
    emptyRow:SetWidth(401)
    local emptyHook
    local realEmptyPin = emptyRow.SetOnPanelPinned
    emptyRow.SetOnPanelPinned = function(self, fn)
        emptyHook = fn
        return realEmptyPin(self, fn)
    end
    tools.ClaimKeys(emptyRow, emptyGroup)
    tools.RegisterHoistedToggle(emptyRow, {
        { name = "Frame Width", kind = "slider", key = "frameWidth",
          min = 60, max = 300, step = 1 },
        { name = "Frame Height", kind = "slider", key = "frameHeight",
          min = 20, max = 300, step = 1 },
    })
    eq(emptyRow:GetShownHoistCount(), 2, "empty: the plate is drawing both settings")
    eq(visible(emptyGroup), 0, "empty: ...so the pane behind it draws none")
    eq(emptyRow.stripCount:GetText(), "Pin settings in popout",
       "empty: ...and the strip offers to pin instead of promising a count")

    local emptyPo, emptyPane = fakePanel()
    emptyMount(emptyPo, emptyPane)
    emptyPo.pinned = true
    emptyHook(emptyRow, emptyPo)
    eq(shownIn(emptyBuilt[1]), 2, "empty: pinning it puts both settings into the panel")
    emptyRow._LayoutPlate()
    eq(emptyRow.stripCount:GetText(), "Pin settings in popout",
       "empty: ...and the strip STILL offers, because the offer is about the loose panel")
    emptyRow.Refresh()
    eq(emptyRow.stripCount:GetText(), "Pin settings in popout",
       "empty: ...and a refresh does not change its mind either")

    -- ...and the fold is still the way back: with nothing on the plate the pane
    -- has both settings to draw again, so the corner goes back to a count -- and
    -- says two whether the instance it is counting is pinned or not.
    emptyRow:SetWidth(M0.padX + M0.check + M0.labelGap + M0.padX + M0.minControl - 1)
    emptyRow._LayoutPlate()
    eq(emptyRow:GetShownHoistCount(), 0, "empty: under the floor the row folds")
    eq(emptyRow.stripCount:GetText(), "2 more settings",
       "empty: ...and the strip counts the two the pane would draw")
    emptyRow:SetWidth(401)
    emptyRow._LayoutPlate()
    eq(emptyRow.stripCount:GetText(), "Pin settings in popout",
       "empty: ...and widening puts the offer back")

    -- ---- and the OTHER order: hoists declared BEFORE the claim ---------
    -- A page is free to call RegisterHoistedToggle first. Then no later layout
    -- would announce a set that is already on the plate, and the immediate call
    -- inside SetOnShownKeysChanged is what closes the gap.
    local lateBuilt = {}
    local lateMount, lateGroup = tools.PopoutContent(function(g)
        local mine = {}
        for _, key in ipairs(KEYS) do
            local w = paneControl(key)
            g:AddWidget(w, 30)
            mine[#mine + 1] = w
        end
        lateBuilt[#lateBuilt + 1] = mine
    end)
    local lateRow = kitHost:CreatePopoutRow(page.child, {
        label = "Frame Size Late", db = tools.RowDB, count = #KEYS,
        footerStrip = true, build = function() end,
    })
    lateRow:SetWidth(401)
    tools.RegisterHoistedToggle(lateRow, {
        { name = "Frame Width", kind = "slider", key = "frameWidth",
          min = 60, max = 300, step = 1 },
        { name = "Frame Height", kind = "slider", key = "frameHeight",
          min = 20, max = 300, step = 1 },
    })
    eq(lateRow:GetShownHoistCount(), 2, "late: the row is already drawing two before any claim")
    eq(visible(lateGroup), 0, "late: ...and its pane has not been laid out at all yet")
    tools.ClaimKeys(lateRow, lateGroup)
    eq(visible(lateGroup), 3, "late: the claim applies the set the row is already showing")
    eq(lateRow.stripCount:GetText(), "3 more settings", "late: ...and the two agree about the count")


    -- ---- THE STRIP'S NUMBER IS THE PANE'S, NOT A DECLARED CONSTANT ----
    -- ☠ A DECLARED COUNT CANNOT FOLLOW THE MODE. Layout Direction declares
    -- three -- a Growth Direction dropdown per mode, one hideOn-gated away, plus
    -- a party-only anchor -- because the badge is about what is BEHIND the row
    -- rather than what today's mode is showing. Hoist one of them and the strip
    -- painted three less one, promising "2 more settings" over a pane that draws
    -- exactly ONE control in party and NONE in raid. So the row asks the group
    -- how many children a layout would place, and says that instead.
    --
    -- ⚠ hideOn IS ONLY CONSULTED WITH A DB IN HAND (see Sections' predicate),
    -- so the host answers `getSettingsDB` from here on. Wired at the foot of this
    -- block, after everything above has had its say against the plain shape.
    kitHost.hooks.getSettingsDB = function() return paneDB end

    local DIR_OPTS = { _order = { "HORIZONTAL" }, HORIZONTAL = "Rows" }
    local ANCHOR_OPTS = { _order = { "START" }, START = "Top" }
    local dirBuilt = {}
    local dirMount, dirGroup = tools.PopoutContent(function(g)
        -- The row's real shape: ONE key on two widgets, each gated to a mode,
        -- and a third control the raid mode does not use at all.
        local flat = paneControl("growDirection")
        flat.hideOn = function() return GUIstub.SelectedMode == "raid" end
        g:AddWidget(flat, 30)
        local grouped = paneControl("growDirection")
        grouped.hideOn = function() return GUIstub.SelectedMode ~= "raid" end
        g:AddWidget(grouped, 30)
        local anchor = paneControl("growthAnchor")
        anchor.hideOn = function() return GUIstub.SelectedMode == "raid" end
        g:AddWidget(anchor, 30)
        dirBuilt[#dirBuilt + 1] = { flat, grouped, anchor }
    end)
    local dirRow = kitHost:CreatePopoutRow(page.child, {
        label = "Layout Direction", db = tools.RowDB, count = 3,
        footerStrip = true, build = function() end,
    })
    dirRow:SetWidth(401)
    tools.ClaimKeys(dirRow, dirGroup)
    eq(#dirGroup.groupChildren, 3, "dir: three controls behind the row")
    -- ☠ AND THE STRIP ALREADY DISAGREES WITH THE DECLARED THREE, before a
    -- single control is hoisted: party never shows the grouped-raid dropdown.
    eq(dirRow.stripCount:GetText(), "2 more settings",
       "dir: the strip counts what the pane will draw, not what the page declared")

    tools.RegisterHoistedToggle(dirRow, {
        { name = "Growth Direction", kind = "dropdown", key = "growDirection",
          options = DIR_OPTS },
        { name = "Frames Grow From", kind = "dropdown", key = "growthAnchor",
          options = ANCHOR_OPTS,
          visible = function() return GUIstub.SelectedMode ~= "raid" end },
    })

    -- PARTY: both on the plate, nothing left behind the click.
    eq(dirRow:GetShownHoistCount(), 2, "dir: party draws both settings on the plate")
    eq(visible(dirGroup), 0, "dir: ...and the pane behind it has nothing left to draw")
    eq(dirRow.stripCount:GetText(), "Pin settings in popout",
       "dir: ...so the strip offers to pin rather than promising nothing")

    -- RAID: the anchor leaves the plate with the mode, and the pane is empty
    -- there too -- one dropdown gated away, the other one on the plate.
    GUIstub.SelectedMode = "raid"
    dirRow._LayoutPlate()
    eq(dirRow:GetShownHoistCount(), 1, "dir: raid takes the party-only anchor off the plate")
    eq(visible(dirGroup), 0, "dir: ...and raid's pane is empty as well")
    eq(dirRow.stripCount:GetText(), "Pin settings in popout",
       "dir: ...so raid offers to pin too")

    GUIstub.SelectedMode = "party"
    dirRow._LayoutPlate()
    eq(dirRow.stripCount:GetText(), "Pin settings in popout",
       "dir: back in party it is the same offer")

    -- UN-HOIST ONE and the pane has something behind the click again, which is
    -- the phrase coming back rather than a state the row cannot leave.
    tools.RegisterHoistedToggle(dirRow, {
        { name = "Growth Direction", kind = "dropdown", key = "growDirection",
          options = DIR_OPTS },
    })
    eq(dirRow:GetShownHoistCount(), 1, "dir: one control on the plate")
    eq(visible(dirGroup), 1, "dir: ...and the anchor is back in the pane")
    eq(dirRow.stripCount:GetText(), "1 more settings",
       "dir: ...which is exactly what the strip promises")

    -- ...and the mount is told the same thing, so a panel opened now draws the
    -- one control the strip just named.
    local dirPo, dirPane = fakePanel()
    dirMount(dirPo, dirPane)
    eq(shownIn(dirBuilt[1]), 1, "dir: the panel opens with the one control behind the row")
    DandersFrames, CreateFrame = savedDF, savedCreateFrame
end
