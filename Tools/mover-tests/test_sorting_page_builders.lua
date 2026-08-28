local NS = ...

-- ============================================================
-- SORTING PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Auras.lua
-- ------------------------------------------------------------
-- General > Sorting is the sweep's second page. Three of its five groups become
-- popout feature rows -- Unit Frame Sorting, Role Priority, Class Priority --
-- and the two single-option groups stay inline wearing the band skin, because a
-- pane holding one dropdown is a click that buys nothing.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db -- so this file
-- does what test_frame_page_builders does: it reads the page's SOURCE and
-- asserts against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each extracted builder -- kind, L key, db key and
--     slot height, in order -- taken from the PRE-CHANGE source, so a builder
--     that quietly dropped a control or renamed a key fails here. This is also
--     the evidence that CLASSIC RENDERS AS IT DID: the classic branch mounts the
--     same builder into the same 280 box in the same column.
--   ✓ that ONE builder serves both layouts.
--   ✓ that the declared row COUNT matches what the pane mounts, less the hoisted
--     toggle.
--   ✗ nothing about runtime behaviour -- the callbacks, the greying and the
--     summaries are read by eye and by the in-game checklist.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Auras.lua")

-- ---- the census reader (the Frame page's, verbatim) ------------------
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
}

-- The body of a `local function <name>(tools2)` at the page builder's own
-- indent. Terminated on a newline + EIGHT spaces + `end`, which is that indent:
-- everything inside one of these bodies is indented further.
local function builderBody(name)
    local head = "local function " .. name .. "(tools2)"
    local a = SRC:find(head, 1, true)
    check(a ~= nil, "source: the page declares " .. name)
    if not a then return "" end
    local b = SRC:find("\n        end\n", a, true)
    check(b ~= nil and b > a, "source: ..." .. name .. " closes at the page builder's indent")
    return SRC:sub(a, b or a)
end

local function census(body)
    local flat = body:gsub("%s+", " ")
    local starts = {}
    local i = 1
    while true do
        local s, e, kind = flat:find("GUI:(Create%a+)%(", i)
        if not s then break end
        if KIND[kind] then starts[#starts + 1] = { s = s, kind = KIND[kind] } end
        i = e
    end
    local out = {}
    for n, at in ipairs(starts) do
        local stop = starts[n + 1] and (starts[n + 1].s - 1) or #flat
        local chunk = flat:sub(at.s, stop)
        local label = chunk:match('GUI:Create%a+%(%s*[%w_%.]+%s*,%s*L%["([^"]+)"%]') or "(none)"
        local key   = chunk:match('%f[%w]db,%s*"([%w_]+)"') or "(none)"
        local h     = tonumber(chunk:match('%)%s*,%s*(%d+)%s*%)'))
        out[#out + 1] = { kind = at.kind, label = label, key = key, height = h }
    end
    return out
end

local function checkCensus(got, want, tag)
    eq(#got, #want, tag .. ": control count")
    for i = 1, math.max(#got, #want) do
        local g, e = got[i], want[i]
        if not g then
            check(false, string.format("%s: row %d missing (wanted %s)", tag, i, e[2]))
        elseif not e then
            check(false, string.format("%s: row %d unexpected (%s %s)", tag, i, g.kind, g.label))
        else
            eq(g.kind,   e[1], string.format("%s: row %d kind", tag, i))
            eq(g.label,  e[2], string.format("%s: row %d label", tag, i))
            eq(g.key,    e[3], string.format("%s: row %d db key", tag, i))
            eq(g.height, e[4], string.format("%s: row %d slot height", tag, i))
        end
    end
end

-- The block a row is declared in, from its label to the closing brace of the
-- CreatePopoutRow opts.
local function rowOpts(labelKey)
    local a = SRC:find('label%s*=%s*L%["' .. labelKey .. '"%]')
    check(a ~= nil, "source: a popout row is declared for " .. labelKey)
    if not a then return "" end
    local b = SRC:find("}))", a, true)
    return SRC:sub(a, (b or a) + 2)
end

-- What every converted group on this page has in common.
local function checkShared(builder, rowLabel)
    -- ONE builder, BOTH layouts: the declaration and the two mounts.
    local calls = 0
    for _ in SRC:gmatch(builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, rowLabel .. ": declared once, mounted twice -- classic box and popout pane")

    -- The classic branch builds the box it always did, with its own header.
    local box = SRC:match("local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)\n%s*%1:AddWidget%(GUI:CreateHeader%(self%.child, L%[\"" .. rowLabel:gsub("%p", "%%%0") .. "\"%]%)")
    check(box ~= nil, rowLabel .. ": the classic 280 box is built with its own header")

    local opts = rowOpts(rowLabel)
    check(opts ~= "" and opts:find("build", 1, true) ~= nil,
          rowLabel .. ": the row is handed a pre-built mount")
    check(opts:find("window  = DF.GUIFrame", 1, true) ~= nil
       or opts:find("window   = DF.GUIFrame", 1, true) ~= nil,
          rowLabel .. ": ...docked outside the settings window")
    check(opts:find("clipTo", 1, true) ~= nil,
          rowLabel .. ": ...and clipped by the page's own scroll frame, not the window")
end

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED MACHINERY
-- The Frame page built its own copy inline; this page is the first to take
-- GUI:CreatePopoutPageTools, and every verb it uses comes off that table rather
-- than out of a second copy on the page.
-- ============================================================
print("-- Sorting page: the shared popout machinery, not a second copy of it")
do
    check(SRC:find("local classicLayout = DF:IsClassicSettingsLayout()", 1, true) ~= nil,
          "tools: the page asks which layout it is building")
    check(SRC:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true) ~= nil,
          "tools: ...and takes the shared machinery unconditionally")

    -- ☠ NOT ITS OWN COPY. The whole point of the helper is that five pages do
    -- not carry five drifting copies of the eager holders and the footer verbs.
    for _, v in ipairs({ "PopoutContent", "ReflowPane", "ReflowMounted", "ClaimKeys",
                         "WireModifiedTick", "WireFooter", "RegisterHoistedToggle",
                         "RefreshAfterGroupWrite", "HoldReason" }) do
        check(SRC:find("local function " .. v .. "(", 1, true) == nil,
              "tools: the page does not re-declare " .. v)
    end
    -- ...and it never touches the holders or the row map by hand: the prologue
    -- inside the helper owns both.
    check(SRC:find("_popoutHolders", 1, true) == nil,
          "tools: the page never manages the popout holders itself")
    check(SRC:find("_popoutRowForKey", 1, true) == nil,
          "tools: ...nor the search row map")
end

-- ============================================================
-- 2. UNIT FRAME SORTING -- the page's one hoisted toggle
-- Six controls, one of them the "am I doing anything" tick, which goes onto the
-- row. The two blurbs stay in the pane, raid note and all.
-- ============================================================
local SORT_OPTIONS = {
    { "label",    "Sort party members by role, class, and name.\\n\\nSort order: Self Position > Role > Class > Name", "(none)", 60 },
    { "label",    "Raid: Group layout sorts within each group.\\nFlat grid layout sorts all players together.",        "(none)", 35 },
    { "checkbox", "Enable Custom Sorting",           "sortEnabled",              30 },
    { "checkbox", "Separate Melee & Ranged DPS",     "sortSeparateMeleeRanged",  30 },
    { "checkbox", "Sort by Class (within role)",     "sortByClass",              30 },
    { "dropdown", "Alphabetical (within class/role)", "sortAlphabetical",        55 },
}

print("-- Sorting page: Unit Frame Sorting")
do
    local body = builderBody("BuildSortOptionsGroup")
    checkCensus(census(body), SORT_OPTIONS, "unit frame sorting")
    checkShared("BuildSortOptionsGroup", "Unit Frame Sorting")

    -- The hoist, and the arithmetic it implies: the checkbox is still IN the
    -- builder -- classic needs it -- behind the one flag the popout passes.
    check(body:find("if not tools2.hoistToggle then", 1, true) ~= nil,
          "unit frame sorting: the enable checkbox is skipped when the row has hoisted it")
    check(body:find("sortEnable.keepEnabled = true", 1, true) ~= nil,
          "unit frame sorting: ...and in classic it stays live under the group's own grey")
    local declared = tonumber(SRC:match("local SORT_OPTIONS_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "unit frame sorting: the page declares the row's count in one place")
    eq(declared, #SORT_OPTIONS - 1, "unit frame sorting: ...the census less the hoisted tick")

    -- ☠ THE GROUP GATE MOVED INSIDE THE BUILDER. In classic it was a property of
    -- the page-level box; left there, the pane would not grey while custom
    -- sorting is off and the two layouts would disagree.
    check(body:find("group.disableChildrenOn = DisableSortOptions", 1, true) ~= nil,
          "unit frame sorting: the group's grey-while-off gate is inside the builder")
    -- The three variant gates ride along unchanged: under a FrameSort takeover
    -- the options vanish while the enable tick stays.
    local hides = 0
    for _ in body:gmatch("%.hideOn = HideSortOptions") do hides = hides + 1 end
    eq(hides, 3, "unit frame sorting: the three FrameSort-takeover gates survived the move")

    local opts = rowOpts("Unit Frame Sorting")
    check(opts:find('toggle%s*=%s*{%s*key%s*=%s*"sortEnabled"%s*}') ~= nil,
          "unit frame sorting: the row's tick is the group's own enable key")
    check(opts:find("summary%s*=%s*SortOptionsSummary") ~= nil,
          "unit frame sorting: ...it declares a summary")
    check(opts:find("count%s*=%s*SORT_OPTIONS_COUNT") ~= nil,
          "unit frame sorting: ...and the declared count, not a literal")
    check(opts:find("onToggle%s*=%s*OnSortEnabledToggle") ~= nil,
          "unit frame sorting: ...and a commit that is not a page rebuild")
    -- ⚠ NO offText. Both raid layout modes are a layout, so that row spells its
    -- off state; sorting off genuinely means not sorting, and the kit's own off
    -- state says it.
    check(opts:find("offText", 1, true) == nil,
          "unit frame sorting: no offText -- off here really does mean not sorting")

    -- ☠ THE COMMIT IS NOT A PAGE REBUILD. A rebuild retires the row being
    -- clicked, and the row's write path calls row.Refresh() after onToggle
    -- returns -- on a dead frame.
    local commit = SRC:match("local function OnSortEnabledToggle%(%)(.-)\n            end")
    check(commit ~= nil, "unit frame sorting: the popout commit is a named function")
    if commit then
        check(commit:find("RefreshCurrentPage", 1, true) == nil,
              "unit frame sorting: ...and never rebuilds the page")
        check(commit:find("self:RefreshStates()", 1, true) ~= nil,
              "unit frame sorting: ...it re-runs the state passes instead")
        check(commit:find("tools.ReflowMounted()", 1, true) ~= nil,
              "unit frame sorting: ...and reflows the open panes")
    end

    -- The hoisted toggle is re-registered with search under the SAME label and
    -- key the suppressed checkbox carried, or the setting becomes unfindable in
    -- the popout layout while staying findable in classic.
    check(SRC:find('tools.RegisterHoistedToggle(sortRow, L["Enable Custom Sorting"], "sortEnabled", OnSortEnabledToggle)', 1, true) ~= nil,
          "unit frame sorting: the hoisted toggle keeps its search entry")

    -- ⚠ NO hideOn ON THE ROW, mirroring classic: the box had none either, only
    -- its children did. Under a FrameSort takeover the enable control stayed on
    -- screen while the options round it vanished.
    check(SRC:find("sortRow.hideOn", 1, true) == nil,
          "unit frame sorting: the row is always visible, exactly as the box was")

    -- The summary reuses words the locale already ships and separates them with
    -- the convention's dot. No Greek, no typographic glyphs.
    local sum = SRC:match("local function SortOptionsSummary%(d%)(.-)\n            end")
    check(sum ~= nil, "unit frame sorting: the summary is a named function on the page")
    if sum then
        check(sum:find('L%["Role"%]') ~= nil, "unit frame sorting: ...naming the always-true level")
        check(sum:find('L%["Class"%]') ~= nil, "unit frame sorting: ...the optional one")
        check(sum:find('L%["A to Z"%]') ~= nil and sum:find('L%["Z to A"%]') ~= nil,
              "unit frame sorting: ...and the alphabetical state")
        check(sum:find("\\194\\183", 1, true) ~= nil, "unit frame sorting: ...separated by the convention's dot")
        local items = 0
        for _ in sum:gmatch("parts%[#parts %+ 1%]") do items = items + 1 end
        check(items <= 3, "unit frame sorting: at most four items, per the summary convention")
    end
end

-- ============================================================
-- 3. ROLE PRIORITY and CLASS PRIORITY -- the two drag lists
-- Toggle-less rows: there is no boolean here meaning "am I doing anything", only
-- an order. Both carry the box's own two gates -- hidden under a FrameSort
-- takeover, greyed while custom sorting is off.
-- ============================================================
--
-- ⚠ THE BLURB REPORTS THE LIST'S DB KEY, and that is the census reader working
-- as designed rather than a bug in the page. A call's chunk runs to the START OF
-- THE NEXT shared-factory call, and there is no next one in these two builders
-- -- the drag list is CreateRoleOrderList / CreateClassOrderList, which the
-- reader does not know -- so the chunk runs to the end of the body and the key
-- it finds is the list's. Written down rather than papered over: it is still the
-- inventory these groups had inline, and the list itself is checked by name.
local ROLE_PRIORITY = {
    { "label", "Drag to reorder. Top = first.", "sortRoleOrder", 25 },
}
local CLASS_PRIORITY = {
    { "label", "Drag to reorder. Top = first.", "sortClassOrder", 25 },
}

print("-- Sorting page: Role Priority")
do
    local body = builderBody("BuildRolePriorityGroup")
    -- ⚠ ONE CENSUS ENTRY FOR TWO WIDGETS: the drag list is CreateRoleOrderList,
    -- which the census reader does not know, so it is checked by name below.
    checkCensus(census(body), ROLE_PRIORITY, "role priority")
    checkShared("BuildRolePriorityGroup", "Role Priority")
    check(body:find('GUI:CreateRoleOrderList(parent, db, "sortRoleOrder"', 1, true) ~= nil,
          "role priority: the drag list is mounted into the pane's own parent")
    check(body:find('end, "sortSeparateMeleeRanged")', 1, true) ~= nil,
          "role priority: ...still told which key decides its shape")

    local declared = tonumber(SRC:match("local ROLE_PRIORITY_COUNT, CLASS_PRIORITY_COUNT = (%d+)"))
    check(declared ~= nil, "role priority: the page declares the row's count in one place")
    eq(declared, #ROLE_PRIORITY + 1, "role priority: ...the blurb plus the drag list")

    -- ☠ THE WIDGET REFERENCE IS REBOUND INSIDE THE BUILDER. The Separate Melee &
    -- Ranged callback repaints whichever list the user can see, and the popout
    -- shell builds one list PER INSTANCE -- so a captured single upvalue would
    -- name whichever one happened to be built first.
    check(body:find("roleOrderWidget = GUI:CreateRoleOrderList(", 1, true) ~= nil,
          "role priority: the shared reference is assigned by the builder, per instance")
    -- ...and the older instances are covered by the value sweep, which is what
    -- the drag lists' refreshValue opt-in was added for.
    local sortBody = builderBody("BuildSortOptionsGroup")
    check(sortBody:find("if tools2.reflowValues then tools2.reflowValues() end", 1, true) ~= nil,
          "role priority: ...with the pane sweep covering any pinned second one")

    check(body:find("group.disableChildrenOn = DisableSortOptions", 1, true) ~= nil,
          "role priority: the pane greys while custom sorting is off, as the box did")
    check(SRC:find("roleRow.hideOn = HideSortOptions", 1, true) ~= nil,
          "role priority: the row hides under a FrameSort takeover, as the box did")
    check(SRC:find("roleRow.disableOn = DisableSortOptions", 1, true) ~= nil,
          "role priority: ...and greys on the same key the box's children did")

    local opts = rowOpts("Role Priority")
    check(opts:find("toggle", 1, true) == nil,
          "role priority: the row declares no toggle -- an order has no on/off")
    check(opts:find("summary%s*=%s*RolePrioritySummary") ~= nil,
          "role priority: ...it does declare a summary")
    check(opts:find("count%s*=%s*ROLE_PRIORITY_COUNT") ~= nil,
          "role priority: ...and the declared count, not a literal")

    -- The summary names the top of the list in the locale's own words, and
    -- follows the melee/ranged split -- with it off the list folds MELEE and
    -- RANGED into one DPS entry, so the raw token would name a role the user
    -- cannot see below it.
    local word = SRC:match("local function RoleWord%(role, separate%)(.-)\n            end")
    check(word ~= nil, "role priority: the role word is a named function")
    if word then
        for _, k in ipairs({ "Tank", "Healer", "Melee DPS", "Ranged DPS", "DPS" }) do
            check(word:find('L%["' .. k .. '"%]') ~= nil,
                  "role priority: ..." .. k .. " comes from the locale, not a literal")
        end
        check(word:find("if not separate then return L[\"DPS\"] end", 1, true) ~= nil,
              "role priority: ...and folds to one DPS entry when the split is off")
    end

    -- The footer's apply is the resort the list's own callback runs.
    check(SRC:find("tools.WireFooter(roleRow, TriggerSortForCurrentMode)", 1, true) ~= nil,
          "role priority: Reset Group and Hold: Defaults resort the frames")
    check(SRC:find("tools.ClaimKeys(roleRow, roleContent)", 1, true) ~= nil,
          "role priority: the row claims whatever the pane registered")
    check(SRC:find("tools.WireModifiedTick(roleRow)", 1, true) ~= nil,
          "role priority: ...and its amber tick asks about exactly those keys")
end

print("-- Sorting page: Class Priority")
do
    local body = builderBody("BuildClassPriorityGroup")
    checkCensus(census(body), CLASS_PRIORITY, "class priority")
    checkShared("BuildClassPriorityGroup", "Class Priority")
    check(body:find('GUI:CreateClassOrderList(parent, db, "sortClassOrder"', 1, true) ~= nil,
          "class priority: the drag list is mounted into the pane's own parent")

    local declared = tonumber(SRC:match("local ROLE_PRIORITY_COUNT, CLASS_PRIORITY_COUNT = %d+, (%d+)"))
    check(declared ~= nil, "class priority: the page declares the row's count in one place")
    eq(declared, #CLASS_PRIORITY + 1, "class priority: ...the blurb plus the drag list")

    check(body:find("group.disableChildrenOn = DisableSortOptions", 1, true) ~= nil,
          "class priority: the pane greys while custom sorting is off, as the box did")
    -- The box's compound predicate, unchanged: hidden under a FrameSort takeover
    -- OR while nothing is sorting by class.
    check(SRC:find('classRow.hideOn = function(d) return (d.useFrameSort and FrameSortApi) or not d.sortByClass end', 1, true) ~= nil,
          "class priority: the row carries the box's own compound gate")
    check(SRC:find("classRow.disableOn = DisableSortOptions", 1, true) ~= nil,
          "class priority: ...and greys on the enable key like everything else here")

    local opts = rowOpts("Class Priority")
    check(opts:find("toggle", 1, true) == nil, "class priority: the row declares no toggle")
    check(opts:find("count%s*=%s*CLASS_PRIORITY_COUNT") ~= nil,
          "class priority: ...and the declared count, not a literal")

    -- The summary names the top class in the CLIENT's own words, so no locale
    -- key is invented for thirteen names the game already spells.
    local sum = SRC:match("local function ClassPrioritySummary%(d%)(.-)\n            end")
    check(sum ~= nil, "class priority: the summary is a named function on the page")
    if sum then
        check(sum:find("LOCALIZED_CLASS_NAMES_MALE", 1, true) ~= nil,
              "class priority: ...taking the class names from the client")
        check(sum:find('return (names and names[top]) or ""', 1, true) ~= nil,
              "class priority: ...guarded, so an unreadable order says nothing rather than erroring")
    end

    check(SRC:find("tools.WireFooter(classRow, TriggerSortForCurrentMode)", 1, true) ~= nil,
          "class priority: Reset Group and Hold: Defaults resort the frames")
end

-- ============================================================
-- 4. WHAT STAYED INLINE, AND WHAT THE PAGE ADDS
-- Two single-option groups keep their box and take the band skin; the combat
-- banner is not a settings group at all and is untouched.
-- ============================================================
print("-- Sorting page: the stay-inline groups and the page's own order")
do
    -- Scoped to the Sorting page by its own two ends: Auras.lua holds several
    -- pages, and a bare 280 box on one of the others is not this pass's business.
    local a = SRC:find('Add(CreateCopyButton(self.child, {"sort", "useFrameSort"', 1, true)
    local b = SRC:find('{pageId = "general_labels", label = L["Group Labels"]}', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Sorting page builder is locatable by its own ends")
    local PAGE = SRC:sub(a or 1, b or 1)

    -- ---- the skin, at both stay-inline sites and nowhere else --------
    local sites = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280, tools and tools%.INLINE_BOX or nil%)") do
        sites = sites + 1
    end
    eq(sites, 2, "inline: exactly two groups stay inline and wear the band skin")
    check(SRC:find("local frameSortGroup = GUI:CreateSettingsGroup(self.child, 280, tools and tools.INLINE_BOX or nil)", 1, true) ~= nil,
          "inline: FrameSort Integration is one of them")
    check(SRC:find("local selfPosGroup = GUI:CreateSettingsGroup(self.child, 280, tools and tools.INLINE_BOX or nil)", 1, true) ~= nil,
          "inline: ...and Self Position the other")
    -- ⚠ THE FLAG IS NEVER WRITTEN AS A LITERAL ON THIS PAGE. One shared table off
    -- the tools, so classic gets nil -- which is what "no opts" already meant.
    check(PAGE:find("bandStyle", 1, true) == nil,
          "inline: the skin is taken from the tools, never restated as a literal")

    -- ---- the two bands ----------------------------------------------
    check(SRC:find("sortBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
          "bands: the sorting band is chromeless, at the width the layout pass will give it")
    check(SRC:find("priorityBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
          "bands: ...and so is the priority band")
    -- A header names a SECTION. One row that already says its own name gets
    -- none; two rows that share a word get that word.
    check(SRC:find('priorityBand:AddWidget(GUI:CreateHeader(self.child, L["Priority"]), 40)', 1, true) ~= nil,
          "bands: the two-row band names itself above its rows")
    check(SRC:find("sortBand:AddWidget(GUI:CreateHeader", 1, true) == nil,
          "bands: ...and the one-row band does not, because its row's label already does")

    -- ---- the Add order ----------------------------------------------
    local adds = {}
    for name, col in PAGE:gmatch("Add%((%a[%w_]*),%s*nil,%s*([%w\"_]+)%)") do
        adds[#adds + 1] = { name = name, col = col }
    end
    local function indexOf(name, col)
        for i, e in ipairs(adds) do
            if e.name == name and (col == nil or e.col == col) then return i end
        end
    end
    -- The two bands span both columns; the two stay-inline boxes keep column 1
    -- and the classic boxes keep the columns they always had.
    check(indexOf("sortBand", '"both"') ~= nil, "order: the sorting band spans both columns")
    check(indexOf("priorityBand", '"both"') ~= nil, "order: ...and so does the priority band")
    -- ☠ THE SORTING BAND IS ADDED ABOVE THE COLUMN BOXES, NOT AT THE FOOT. "both"
    -- is a sync point (it drops both columns to the lower of the two), so a band
    -- dropped in below the two column-1 boxes would leave a hole beside them.
    check(indexOf("sortBand", '"both"') < indexOf("frameSortGroup", "1"),
          "order: the sorting band comes before the column-1 boxes, so nothing is left holed")
    check(indexOf("frameSortGroup", "1") < indexOf("selfPosGroup", "1"),
          "order: ...and the two stay-inline boxes keep their own order")
    check(indexOf("selfPosGroup", "1") < indexOf("priorityBand", '"both"'),
          "order: ...with the priority band last, which is the page's old reading order")

    -- The classic column assignments, unchanged -- the one thing this pass was
    -- not allowed to move.
    local CLASSIC_COL = {
        sortOptionsGroup = "1", rolePriorityGroup = "2", classPriorityGroup = "2",
    }
    for name, col in pairs(CLASSIC_COL) do
        check(indexOf(name, col) ~= nil,
              "order: the classic " .. name .. " still goes to column " .. col)
    end
    -- Three bare 280 boxes are left, and all three are inside a classicLayout
    -- arm: a fourth appearing outside one is the drift this counts.
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 3, "order: three bare 280 boxes left, and they are the classic branch's own")

    -- ---- the combat banner is untouched ------------------------------
    -- Not a settings group, so not a candidate: it is the page's own full-width
    -- status line, and its hideOn and refreshContent are what keep it honest.
    check(SRC:find('Add(combatBanner, combatBanner.layoutHeight, "both")', 1, true) ~= nil,
          "banner: the combat banner is still added full width, ahead of everything")
    check(SRC:find("combatBanner.refreshContent = UpdateCombatBanner", 1, true) ~= nil,
          "banner: ...with the refresh hook that re-tones it on every page refresh")
    check(SRC:find("combatBanner.hideOn = function(d) return HideSortOptions(d) or not d.sortEnabled end", 1, true) ~= nil,
          "banner: ...and its own two-condition gate")
end
