local NS = ...

-- ============================================================
-- THE SHARED PAGE TOOLS -- GUI:CreatePopoutPageTools
-- DandersFrames_Options/GUI/Controls.lua
-- ------------------------------------------------------------
-- The one copy of the page-scope machinery every card-section page takes: the
-- non-classic prologue, the eager pin-panel content, the reflow, the band width
-- and the section verbs. Pinned here: the helper exists, it exposes every verb
-- the pages call, and no page keeps a second copy of any of it.
--
-- ⚠ 2026-09-26: the popout-row machinery that used to live in the helper --
-- ClaimKeys, the modified tick, the footer's Reset Group / Hold: Defaults,
-- the hoisted toggles and controls, the control-row registration, the inline
-- arm, INLINE_BOX and the search row map -- was deleted with its last callers
-- (the designers' rows pages). The sections of this file that pinned or drove
-- it went with it; what is left pins what the card sections still use.
--
-- Source-level, like the page-builder tests: the parts that matter build real
-- frames and read DF.db / GUI.SelectedMode.
-- ============================================================

local SRC = options_file_source("GUI/Controls.lua")

-- The helper's declaration and its closing `end` at column zero. BODY stops
-- short of the `end` (every source assertion below only wants what is inside it).
local DECL_AT, END_AT = (function()
    local a = SRC:find("function GUI:CreatePopoutPageTools(page)", 1, true)
    check(a ~= nil, "source: Controls.lua declares GUI:CreatePopoutPageTools")
    if not a then return nil, nil end
    local b = SRC:find("\nend\n", a, true)
    check(b ~= nil and b > a, "source: ...and it closes at the file's own indent")
    return a, b
end)()

local BODY = (DECL_AT and END_AT) and SRC:sub(DECL_AT, END_AT) or ""

print("-- Popout page tools: one page argument, and a classic-safe early return")
do
    local classicAt = BODY:find("if DF:IsClassicSettingsLayout() then return nil end", 1, true)
    check(classicAt ~= nil, "tools: the classic layout returns nil, doing nothing else")

    -- ☠ THE CLOSE COMES BEFORE THE CLASSIC BAIL. The FLIP to classic is itself a
    -- rebuild, and it is the one rebuild that can happen with a panel standing
    -- open. Left below the bail, the helper would hand a classic page back with
    -- an orphan panel floating beside it.
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
    -- An open popout from the previous build is wired to the db table THAT build
    -- captured, so after a mode switch a slider dragged in a stale panel writes
    -- the wrong mode. Close first, then retire the old holders.
    local close  = BODY:find('GUI:CloseAllPopoutRows("rebuild")', 1, true)
    local retire = BODY:find("for _, holder in ipairs(page._popoutHolders) do", 1, true)
    check(close ~= nil, "prologue: every open row panel is closed first")
    check(retire ~= nil, "prologue: the previous build's holders are retired")
    check(BODY:find("page._popoutHolders = {}", 1, true) ~= nil,
          "prologue: ...and the list starts empty")
    check(close and retire and close < retire, "prologue: closing precedes retiring")
    -- The holders go to the trash frame, which is what keeps them off the page:
    -- they are deliberately not in page.children, so DoBuild's retire loop never
    -- sees them and this is the only thing that does.
    check(BODY:find("local trash = GUI._trashFrame", 1, true) ~= nil,
          "prologue: the retired holders are re-parented to the trash frame")
    -- The deleted search row map is not published any more.
    check(BODY:find("_popoutRowForKey", 1, true) == nil,
          "prologue: no search row map is published")
end

print("-- Popout page tools: every verb the pages call")
do
    -- Named rather than counted so a rename fails here instead of quietly
    -- shrinking what the next page can use.
    local VERBS = {
        "PopoutContent", "RowDB", "ReflowMounted", "BandWidth",
        "RegisterSection", "SectionControls", "OpenSection", "CloseSection",
    }
    for _, v in ipairs(VERBS) do
        check(BODY:find("local function " .. v .. "(", 1, true) ~= nil,
              "verbs: " .. v .. " is declared inside the helper")
        check(BODY:find(v .. "%s+=%s+" .. v) ~= nil,
              "verbs: ...and handed back on the tools table")
    end
    check(BODY:find("local function ReflowPane(", 1, true) ~= nil,
          "verbs: ReflowPane is the helper's own, not a page's")

    -- ...and the deleted row machinery is gone, not merely unused.
    for _, v in ipairs({ "ClaimKeys", "WireModifiedTick", "WireFooter", "RegisterHoistedToggle",
                         "RegisterHoistedControls", "RegisterControlRow", "RefreshAfterGroupWrite",
                         "CombatReason", "HoldReason", "RowLabel", "AnchorRow", "StampSection" }) do
        check(BODY:find("local function " .. v .. "(", 1, true) == nil,
              "verbs: " .. v .. " is gone with the rows pages")
    end
    check(BODY:find("INLINE_BOX", 1, true) == nil,
          "verbs: ...and so is the stay-inline box's band skin")
end

print("-- Popout page tools: the semantics that were lifted verbatim")
do
    -- ---- eager building, per instance, with the group handed back ----
    check(BODY:find("local pending = fresh()", 1, true) ~= nil,
          "semantics: the content is built EAGERLY at page-build time")
    check(BODY:find("local st = pending or fresh()", 1, true) ~= nil,
          "semantics: ...and a SECOND instance builds a fresh one through the same builder")
    check(BODY:find("end, eager.group", 1, true) ~= nil,
          "semantics: the eager group comes back beside the mount")
    -- The buildInto contract's exact shape: reflow THIS pane, then the page.
    check(BODY:find("buildInto(st.group, holder, reflow)", 1, true) ~= nil,
          "semantics: buildInto is handed the group, the holder and a refresh")
    local rBody = BODY:match("local reflow = function%(%)(.-)\n            end")
    check(rBody ~= nil, "semantics: the pane refresh's body is readable")
    if rBody then
        local paneAt = rBody:find("ReflowPane(st)", 1, true)
        local pageAt = rBody:find("page:RefreshStates()", 1, true)
        check(paneAt ~= nil and pageAt ~= nil and paneAt < pageAt,
              "semantics: ...whose refresh reflows this instance and then the page")
    end

    -- ☠ AND THE HOLDER ANSWERS TO THE SAME CLOSURE. Every widget factory ends
    -- a write with `if parent.RefreshStates then parent:RefreshStates() end`;
    -- `parent` inside a pane IS this holder, and until it carried the field the
    -- guard read nil and every one of those calls did nothing.
    local reflowAt = BODY:find("local reflow = function()", 1, true)
    local stampAt  = BODY:find("holder.RefreshStates = reflow", 1, true)
    local buildAt  = BODY:find("buildInto(st.group, holder, reflow)", 1, true)
    check(reflowAt ~= nil, "semantics: the pane refresh is named once")
    check(stampAt ~= nil,
          "semantics: ...and the holder carries it, so a factory's parent:RefreshStates() lands")
    check(reflowAt and stampAt and buildAt and reflowAt < stampAt and stampAt < buildAt,
          "semantics: ...declared, stamped, then handed to the builder")

    -- ---- the values opt-in ------------------------------------------
    check(BODY:find("if values and g.RefreshChildValues then g:RefreshChildValues() end", 1, true) ~= nil,
          "semantics: the value repaint is OPT-IN, not part of every reflow")

    -- ---- the band width is asked for, never a literal ---------------
    check(BODY:find("GUI.PageUsableWidth(GUI.PageChildWidth(", 1, true) ~= nil,
          "semantics: the band width comes from the page's own helper")
    check(BODY:find("GUI.SettingsBox.group)", 1, true) ~= nil,
          "semantics: ...floored at a box's width for a page with no size yet")
end

print("-- Popout page tools: the Frame page comes home")
do
    -- ⚠ SCOPED TO THE FRAME PAGE'S OWN SLICE, not to the whole file. Pages/
    -- Options.lua holds several pages, and a whole-file search would answer about
    -- General > Settings as readily as about this one.
    local SRC = options_file_source("GUI/Pages/Options.lua")
    local a = SRC:find('Add(CreateCopyButton(self.child, {"frame", "permanentMover"', 1, true)
    local b = SRC:find('{pageId = "general_sorting", label = L["Sorting"]}', 1, true)
    check(a ~= nil and b ~= nil and b > a, "frame page: locatable by its own ends")
    local page = SRC:sub(a or 1, b or 1)

    check(page:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true) ~= nil,
          "frame page: takes the shared machinery, unconditionally")
    for _, v in ipairs({ "PopoutContent", "ReflowPane", "ReflowMounted", "RowDB" }) do
        check(page:find("local function " .. v .. "(", 1, true) == nil,
              "frame page: no longer re-declares " .. v)
    end
    -- The prologue's own state is the helper's too: a page that still touched
    -- it would be running half a second copy.
    check(page:find("_popoutHolders", 1, true) == nil,
          "frame page: never manages the popout holders itself")

    -- ⚠ AND ITS BUILDERS TOOK THE HOUSE RENAME. Every builder on a converted page
    -- takes its opts as `tools2`, because `tools` is the page-scope machinery --
    -- a builder that shadowed the name could never reach the page's verbs.
    check(page:find("local function BuildFrameSizeGroup(tools2)", 1, true) ~= nil,
          "frame page: its builders take tools2, so nothing shadows the page's tools")
    check(page:find("(tools)", 1, true) == nil,
          "frame page: ...and no builder is left taking the shadowing name")
end
