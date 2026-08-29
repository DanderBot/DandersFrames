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
    local footer = BODY:match("local function WireFooter%(row, apply%)(.-)\n    end")
    check(footer ~= nil, "semantics: the footer is locatable")
    if footer then
        check(footer:find("local claimed", 1, true) == nil,
              "semantics: the footer never copies the claimed keys")
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
