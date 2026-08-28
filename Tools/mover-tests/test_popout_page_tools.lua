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
-- ⚠ THE FRAME PAGE IS NOT PORTED THIS PASS and this file does NOT ask it to be.
-- Its census tests read that page's source line by line, so moving it onto the
-- helper is its own commit with its own test edit. What is pinned here is that
-- the helper exists, that it exposes every verb, and that the Frame page still
-- compiles its own copy -- so the lift cannot have quietly hollowed it out.
--
-- Source-level, like the page-builder tests: the helper builds real frames and
-- reads DF.db / GUI.SelectedMode, so it cannot be called headlessly.
-- ============================================================

local SRC = options_file_source("GUI/Controls.lua")

-- The helper's own body, from its declaration to the next `end` at column zero.
local BODY = (function()
    local a = SRC:find("function GUI:CreatePopoutPageTools(page)", 1, true)
    check(a ~= nil, "source: Controls.lua declares GUI:CreatePopoutPageTools")
    if not a then return "" end
    local b = SRC:find("\nend\n", a, true)
    check(b ~= nil and b > a, "source: ...and it closes at the file's own indent")
    return SRC:sub(a, b or a)
end)()

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
    -- The eight named verbs plus the band skin, each declared and each returned.
    -- Named rather than counted so a rename fails here instead of quietly
    -- shrinking what the next page can use.
    local VERBS = {
        "PopoutContent", "RowDB", "ClaimKeys", "WireModifiedTick", "WireFooter",
        "RegisterHoistedToggle", "ReflowMounted", "BandWidth",
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
    for _, v in ipairs({ "ReflowPane", "RefreshAfterGroupWrite", "CombatReason", "HoldReason" }) do
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
end

print("-- Popout page tools: the Frame page keeps its own copy this pass")
do
    -- The lift is additive. The Frame page still declares every piece inline, so
    -- nothing was hollowed out of it in the move -- and its census tests, which
    -- read that source directly, still have something to read.
    -- ⚠ SCOPED TO THE FRAME PAGE'S OWN SLICE, not to the whole file. Pages/
    -- Options.lua holds several pages, and General > Settings -- converted in
    -- this same sweep -- DOES take the shared machinery. A whole-file search
    -- would read that page's `local tools = GUI:CreatePopoutPageTools(self)` as
    -- the Frame page having been ported behind this test's back.
    local SRC = options_file_source("GUI/Pages/Options.lua")
    local a = SRC:find('Add(CreateCopyButton(self.child, {"frame", "permanentMover"', 1, true)
    local b = SRC:find('{pageId = "general_sorting", label = L["Sorting"]}', 1, true)
    check(a ~= nil and b ~= nil and b > a, "frame page: locatable by its own ends")
    local page = SRC:sub(a or 1, b or 1)
    for _, v in ipairs({ "PopoutContent", "ReflowPane", "ReflowMounted", "RowDB",
                         "ClaimKeys", "WireModifiedTick", "RefreshAfterGroupWrite",
                         "CombatReason", "HoldReason", "WireFooter",
                         "RegisterHoistedToggle" }) do
        check(page:find("local function " .. v .. "(", 1, true) ~= nil,
              "frame page: still compiles its own " .. v)
    end
    -- ...and it does NOT call the helper yet. Stated so that porting it is a
    -- deliberate edit here rather than a silent one.
    check(page:find("CreatePopoutPageTools", 1, true) == nil,
          "frame page: and does not take the shared helper this pass")
end
