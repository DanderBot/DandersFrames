local NS = ...

-- ============================================================
-- GROUP LABELS PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Frames.lua
-- ------------------------------------------------------------
-- General > Group Labels is the sweep's third page. Three of its four groups
-- become popout feature rows -- Raid Group Labels, Font Settings, Position --
-- and the one single-option group (Text Format) becomes a CONTROL ROW: a pane
-- holding one dropdown is a click that buys nothing, but a 280 box beside a
-- full-width band is the one shape a column of plates cannot absorb.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db -- so this file
-- does what test_frame_page_builders and test_sorting_page_builders do: it
-- reads the page's SOURCE and asserts against it.
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
--   ✓ that the boxes' own gates moved onto the rows rather than being dropped.
--   ✗ nothing about runtime behaviour -- the callbacks, the greying and the
--     summaries are read by eye and by the in-game checklist.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Frames.lua")

-- ---- the census reader (the Frame page's, with three kinds added) ----
--
-- ⚠ THE FONT TRIO IS IN THE MAP, unlike the two earlier copies of this reader.
-- CreateFontDropdown / CreateOutlineDropdown / CreateShadowCheckbox are three of
-- the five controls in the Font Settings group, and a reader that skipped them
-- would fold all five into two census rows -- a chunk runs to the start of the
-- next KNOWN call, so an unknown factory is invisible rather than merely
-- unnamed. Naming them is what makes this group's inventory actually pinned.
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateFontDropdown = "fontdropdown", CreateOutlineDropdown = "outlinedropdown",
    CreateShadowCheckbox = "shadowcheckbox",
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

-- The Group Labels page, scoped by its own two ends: Frames.lua holds several
-- pages, and a bare 280 box (or a `label = L["Position"]`) on one of the others
-- is not this pass's business. Everything below that is about THIS page reads
-- PAGE rather than SRC for exactly that reason.
local PAGE
do
    local a = SRC:find('Add(CreateCopyButton(self.child, {"groupLabel"}', 1, true)
    local b = SRC:find("-- General > Pinned Frames", 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Group Labels page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- The block a row is declared in, from its label to the closing brace of the
-- CreatePopoutRow opts.
local function rowOpts(labelKey)
    local a = PAGE:find('label%s*=%s*L%["' .. labelKey .. '"%]')
    check(a ~= nil, "source: a popout row is declared for " .. labelKey)
    if not a then return "" end
    local b = PAGE:find("}))", a, true)
    return PAGE:sub(a, (b or a) + 2)
end

-- What every converted group on this page has in common.
local function checkShared(builder, rowLabel)
    -- ONE builder, BOTH layouts: the declaration and the two mounts.
    local calls = 0
    for _ in PAGE:gmatch(builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, rowLabel .. ": declared once, mounted twice -- classic box and popout pane")

    -- The classic branch builds the box it always did, with its own header.
    local box = PAGE:match("local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)\n%s*%1:AddWidget%(GUI:CreateHeader%(self%.child, L%[\"" .. rowLabel:gsub("%p", "%%%0") .. "\"%]%)")
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
-- Same contract the Sorting page signed: the eight verbs come off
-- GUI:CreatePopoutPageTools rather than out of a third copy on the page.
-- ============================================================
print("-- Group Labels page: the shared popout machinery, not a third copy of it")
do
    check(PAGE:find("local classicLayout = DF:IsClassicSettingsLayout()", 1, true) ~= nil,
          "tools: the page asks which layout it is building")
    check(PAGE:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true) ~= nil,
          "tools: ...and takes the shared machinery unconditionally")

    for _, v in ipairs({ "PopoutContent", "ReflowPane", "ReflowMounted", "ClaimKeys",
                         "WireModifiedTick", "WireFooter", "RegisterHoistedToggle",
                         "RefreshAfterGroupWrite", "HoldReason" }) do
        check(PAGE:find("local function " .. v .. "(", 1, true) == nil,
              "tools: the page does not re-declare " .. v)
    end
    check(PAGE:find("_popoutHolders", 1, true) == nil,
          "tools: the page never manages the popout holders itself")
    check(PAGE:find("_popoutRowForKey", 1, true) == nil,
          "tools: ...nor the search row map")
end

-- ============================================================
-- 2. RAID GROUP LABELS -- the page's one hoisted toggle
-- Two controls, one of them the "am I doing anything" tick, which goes onto the
-- row. What is left in the pane is the blurb -- which is what decides that this
-- row carries no count, no footer and no tick.
-- ============================================================
local LABEL_SETTINGS = {
    { "label",    "Display labels above or beside each raid group.", "(none)",            25 },
    { "checkbox", "Enable Group Labels",                             "groupLabelEnabled", 30 },
}

print("-- Group Labels page: Raid Group Labels")
do
    local body = builderBody("BuildLabelSettingsGroup")
    checkCensus(census(body), LABEL_SETTINGS, "raid group labels")
    checkShared("BuildLabelSettingsGroup", "Raid Group Labels")

    -- The hoist: the checkbox is still IN the builder -- classic needs it --
    -- behind the one flag the popout passes.
    check(body:find("if not tools2.hoistToggle then", 1, true) ~= nil,
          "raid group labels: the enable checkbox is skipped when the row has hoisted it")
    check(body:find("groupLabelEnable.keepEnabled = true", 1, true) ~= nil,
          "raid group labels: ...and in classic it stays live under the group's own grey")

    local opts = rowOpts("Raid Group Labels")
    check(opts:find('toggle%s*=%s*{%s*key%s*=%s*"groupLabelEnabled"%s*}') ~= nil,
          "raid group labels: the row's tick is the group's own enable key")
    check(opts:find("onToggle%s*=%s*OnGroupLabelsToggle") ~= nil,
          "raid group labels: ...and a commit that is not a page rebuild")

    -- ☠ NO COUNT, NO FOOTER, NO TICK -- the Raid Layout Mode precedent. Once the
    -- tick is hoisted the pane holds an explanation and nothing else: a badge
    -- would claim controls that are not there, and a reset strip would be
    -- offered over zero claimed keys.
    check(opts:find("count", 1, true) == nil,
          "raid group labels: no count badge -- the pane behind it holds no controls")
    check(opts:find("summary", 1, true) == nil,
          "raid group labels: ...and no summary, because the tick is the whole story")
    check(PAGE:find("tools.WireFooter(labelsRow", 1, true) == nil,
          "raid group labels: no footer -- a reset over zero claimed keys would lie")
    check(PAGE:find("tools.WireModifiedTick(labelsRow", 1, true) == nil,
          "raid group labels: ...and no amber tick, for the same reason")
    check(PAGE:find("tools.ClaimKeys(labelsRow", 1, true) == nil,
          "raid group labels: ...and nothing to claim")

    -- ☠ THE COMMIT IS NOT A PAGE REBUILD. A rebuild retires the row being
    -- clicked, and the row's write path calls row.Refresh() after onToggle
    -- returns -- on a dead frame.
    local commit = PAGE:match("local function OnGroupLabelsToggle%(%)(.-)\n            end")
    check(commit ~= nil, "raid group labels: the popout commit is a named function")
    if commit then
        check(commit:find("RefreshCurrentPage", 1, true) == nil,
              "raid group labels: ...and never rebuilds the page")
        check(commit:find("self:RefreshStates()", 1, true) ~= nil,
              "raid group labels: ...it re-runs the state passes instead")
        check(commit:find("tools.ReflowMounted()", 1, true) ~= nil,
              "raid group labels: ...and reflows the open panes, which grey on this key")
    end

    -- The hoisted toggle is re-registered with search under the SAME label and
    -- key the suppressed checkbox carried, or the setting becomes unfindable in
    -- the popout layout while staying findable in classic.
    check(PAGE:find('tools.RegisterHoistedToggle(labelsRow, L["Enable Group Labels"], "groupLabelEnabled", OnGroupLabelsToggle)', 1, true) ~= nil,
          "raid group labels: the hoisted toggle keeps its search entry")

    -- The box's own gate, on the row.
    check(PAGE:find("labelsRow.hideOn = HideGroupLabelOptions", 1, true) ~= nil,
          "raid group labels: the row hides outside raid + group layout, as the box did")
end

-- ============================================================
-- 3. FONT SETTINGS -- five controls, no toggle
-- ============================================================
local FONT_SETTINGS = {
    { "fontdropdown",    "Font",        "groupLabelFont",     55 },
    { "slider",          "Font Size",   "groupLabelFontSize", 55 },
    { "outlinedropdown", "Outline",     "groupLabelOutline",  55 },
    { "shadowcheckbox",  "Shadow",      "groupLabelOutline",  30 },
    { "colorpicker",     "Label Color", "groupLabelColor",    35 },
}

print("-- Group Labels page: Font Settings")
do
    local body = builderBody("BuildFontGroup")
    checkCensus(census(body), FONT_SETTINGS, "font settings")
    checkShared("BuildFontGroup", "Font Settings")

    -- ⚠ TWO CONTROLS, ONE KEY. The outline dropdown and the shadow tick are two
    -- views of the same stored value, which is why the census above names
    -- groupLabelOutline twice -- and why the row claims it twice. Harmless: the
    -- tick asks "is any of these modified" and the reset writes defaults, and
    -- neither answer is count-sensitive.
    eq(FONT_SETTINGS[3][3], FONT_SETTINGS[4][3],
       "font settings: the outline dropdown and the shadow tick share one stored key")

    local declared = tonumber(PAGE:match("local FONT_SETTINGS_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "font settings: the page declares the row's count in one place")
    eq(declared, #FONT_SETTINGS, "font settings: ...the whole census, because nothing is hoisted")

    -- ☠ THE GROUP GATE MOVED INSIDE THE BUILDER. In classic it was a property of
    -- the page-level box; left there, the pane would not grey while group labels
    -- are off and the two layouts would disagree.
    check(body:find("group.disableChildrenOn = DisableGroupLabelOptions", 1, true) ~= nil,
          "font settings: the group's grey-while-off gate is inside the builder")

    local opts = rowOpts("Font Settings")
    check(opts:find("toggle", 1, true) == nil,
          "font settings: the row declares no toggle -- there is no on/off in here")
    check(opts:find("summary%s*=%s*FontSettingsSummary") ~= nil,
          "font settings: ...it does declare a summary")
    check(opts:find("count%s*=%s*FONT_SETTINGS_COUNT") ~= nil,
          "font settings: ...and the declared count, not a literal")

    check(PAGE:find("tools.ClaimKeys(fontRow, fontContent)", 1, true) ~= nil,
          "font settings: the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(fontRow)", 1, true) ~= nil,
          "font settings: ...its amber tick asks about exactly those keys")
    check(PAGE:find("tools.WireFooter(fontRow, UpdateLabels)", 1, true) ~= nil,
          "font settings: ...and Reset Group / Hold: Defaults redraw the labels")

    -- The box's two gates, on the row: HIDDEN outside raid + group layout,
    -- GREYED while group labels are off.
    check(PAGE:find("fontRow.hideOn = HideGroupLabelOptions", 1, true) ~= nil,
          "font settings: the row hides where the box did")
    check(PAGE:find("fontRow.disableOn = DisableGroupLabelOptions", 1, true) ~= nil,
          "font settings: ...and greys on the key the box's children did")

    -- The summary names the font the way the dropdown behind it does -- through
    -- the addon's own resolver, not a second one -- and localises its one word.
    local sum = PAGE:match("local function FontSettingsSummary%(d%)(.-)\n            end")
    check(sum ~= nil, "font settings: the summary is a named function on the page")
    if sum then
        check(sum:find("DF:GetFontNameFromPath(d.groupLabelFont)", 1, true) ~= nil,
              "font settings: ...taking the font name from the addon's own resolver")
        check(sum:find("DF.GetFontNameFromPath and", 1, true) ~= nil,
              "font settings: ...guarded, because the engine is in the resident addon")
        check(sum:find('L%["Thick Outline"%]') ~= nil,
              "font settings: ...and the outline word comes from the locale")
        check(sum:find("\\194\\183", 1, true) ~= nil,
              "font settings: ...separated by the convention's dot")
        local items = 0
        for _ in sum:gmatch("parts%[#parts %+ 1%]") do items = items + 1 end
        check(items <= 7, "font settings: at most four items reach the string at once")
    end
end

-- ============================================================
-- 4. POSITION -- four widgets, no toggle
-- ============================================================
local POSITION = {
    { "dropdown", "Label Position", "groupLabelPosition", 55 },
    { "slider",   "Offset X",       "groupLabelOffsetX",  55 },
    { "slider",   "Offset Y",       "groupLabelOffsetY",  55 },
    { "label",    "Start: Above/left of groups.\\nCenter: Middle of the group.\\nEnd: Below/right of groups.", "(none)", 50 },
}

print("-- Group Labels page: Position")
do
    local body = builderBody("BuildPositionGroup")
    checkCensus(census(body), POSITION, "position")
    checkShared("BuildPositionGroup", "Position")

    -- The dropdown's option table moved into the builder with it, so the pane
    -- and the classic box offer the same three placements.
    for _, k in ipairs({ "Start of Group", "Center of Group", "End of Group" }) do
        check(body:find('L%["' .. k .. '"%]') ~= nil,
              "position: the " .. k .. " option rode along into the builder")
    end

    local declared = tonumber(PAGE:match("local POSITION_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "position: the page declares the row's count in one place")
    eq(declared, #POSITION, "position: ...the whole census, explainer included")

    check(body:find("group.disableChildrenOn = DisableGroupLabelOptions", 1, true) ~= nil,
          "position: the group's grey-while-off gate is inside the builder")

    local opts = rowOpts("Position")
    check(opts:find("toggle", 1, true) == nil, "position: the row declares no toggle")
    check(opts:find("summary%s*=%s*PositionSummary") ~= nil, "position: ...it does declare a summary")
    check(opts:find("count%s*=%s*POSITION_COUNT") ~= nil,
          "position: ...and the declared count, not a literal")

    check(PAGE:find("tools.ClaimKeys(positionRow, posContent)", 1, true) ~= nil,
          "position: the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(positionRow)", 1, true) ~= nil,
          "position: ...and its amber tick asks about exactly those keys")
    check(PAGE:find("tools.WireFooter(positionRow, UpdateLabels)", 1, true) ~= nil,
          "position: ...and the footer redraws the labels")
    check(PAGE:find("positionRow.hideOn = HideGroupLabelOptions", 1, true) ~= nil,
          "position: the row hides where the box did")
    check(PAGE:find("positionRow.disableOn = DisableGroupLabelOptions", 1, true) ~= nil,
          "position: ...and greys on the key the box's children did")

    -- The summary prints the SHORT placement word plus the offset pair, which is
    -- the Border Shadow row's own convention: the numbers only when they are not
    -- both zero.
    local sum = PAGE:match("local function PositionSummary%(d%)(.-)\n            end")
    check(sum ~= nil, "position: the summary is a named function on the page")
    if sum then
        for _, k in ipairs({ "Start", "Center", "End" }) do
            check(sum:find('L%["' .. k .. '"%]') ~= nil,
                  "position: ..." .. k .. " comes from the locale, not a literal")
        end
        check(sum:find("if ox ~= 0 or oy ~= 0 then", 1, true) ~= nil,
              "position: ...and the offsets print only when they are not both zero")
        check(sum:find('format("%d, %d"', 1, true) ~= nil,
              "position: ...as one pair, the way the shadow row spells it")
    end
end

-- ============================================================
-- 5. TEXT FORMAT'S CONTROL ROW, AND THE PAGE'S OWN ORDER
-- The one single-option group becomes a control row in a band of its own; the
-- two mode messages and the copy button are not settings groups at all and are
-- untouched.
-- ============================================================
print("-- Group Labels page: the Text Format control row, the band and the page's own order")
do
    -- ---- nothing is mounted at a column's 280 any more ---------------
    local narrow = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280, tools") do narrow = narrow + 1 end
    eq(narrow, 0, "inline: no box on this page is still mounted at a column's 280")
    check(PAGE:find("bandStyle", 1, true) == nil,
          "inline: the band skin is never restated as a literal")

    -- ---- Text Format is a CONTROL ROW --------------------------------
    -- It is still NOT a popout row: a pane holding one dropdown buys nothing.
    check(PAGE:find('label   = L["Label Format"]', 1, true) == nil,
          "control row: no popout row is declared for one dropdown")
    check(PAGE:find('label     = L["Label Format"],\n                kind      = "dropdown",', 1, true) ~= nil,
          "control row: Text Format is a dropdown control row")
    check(PAGE:find("formatBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
          "control row: ...in a chromeless band at the width the layout pass will give it")
    check(PAGE:find("formatBand:AddWidget(GUI:CreateControlRow(", 1, true) ~= nil,
          "control row: ...mounted into that band")
    check(PAGE:find("formatBand:AddWidget(GUI:CreateHeader", 1, true) == nil,
          "control row: ...and no band header, because the row's own label names it")
    -- ⚠ THE CONTROL'S OWN NAME, NOT THE BOX'S TITLE. "Text Format" named a
    -- SECTION; "Label Format" is what the dropdown has always been called, so the
    -- entry the kit registers off this label is the SAME entry classic registers.
    check(PAGE:find('label     = L["Text Format"]', 1, true) == nil,
          "control row: ...named 'Label Format', not the box's section title")
    -- The TABLE binding, which is what keeps the override markers and the search
    -- index addressing the same (table, key) pair the classic dropdown gave them.
    check(PAGE:find('options   = formatOptions,\n                db        = db,\n                key       = "groupLabelFormat",', 1, true) ~= nil,
          "control row: the options and the TABLE binding ride the row")
    check(PAGE:find("onChanged = UpdateLabels,", 1, true) ~= nil,
          "control row: ...and the page's own apply, unchanged")
    check(PAGE:find("hideOn    = HideGroupLabelOptions,", 1, true) ~= nil,
          "control row: ...the box's hideOn becomes the ROW's, so the slot collapses")
    check(PAGE:find("formatRow.disableOn = DisableGroupLabelOptions", 1, true) ~= nil,
          "control row: ...and its disableChildrenOn becomes the row's own grey")
    check(PAGE:find('tools.RegisterControlRow(formatRow, "dropdown", "groupLabelFormat")', 1, true) ~= nil,
          "control row: ...and it reaches search through the shared verb")

    -- ---- classic still builds the box it always built -----------------
    check(PAGE:find("local formatGroup = GUI:CreateSettingsGroup(self.child, 280)", 1, true) ~= nil,
          "control row: classic keeps the bare 280 box")
    check(PAGE:find('formatGroup:AddWidget(GUI:CreateHeader(self.child, L["Text Format"]), 40)', 1, true) ~= nil,
          "control row: ...under the header it always had")
    check(PAGE:find('formatGroup:AddWidget(GUI:CreateDropdown(self.child, L["Label Format"], formatOptions, db, "groupLabelFormat", UpdateLabels), 55)', 1, true) ~= nil,
          "control row: ...with the dropdown call it always made")
    check(PAGE:find("formatGroup.hideOn = HideGroupLabelOptions", 1, true) ~= nil
      and PAGE:find("formatGroup.disableChildrenOn = DisableGroupLabelOptions", 1, true) ~= nil,
          "control row: ...and both of the box's own gates")
    -- The option table is declared ONCE and read by both arms.
    local opts = 0
    for _ in PAGE:gmatch("local formatOptions = {") do opts = opts + 1 end
    eq(opts, 1, "control row: the four format options are declared once, for both arms")

    -- ---- the band ----------------------------------------------------
    check(PAGE:find("labelBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
          "band: the band is chromeless, at the width the layout pass will give it")
    -- ☠ NO HEADER. The first row's own label already says "Raid Group Labels",
    -- and a header repeating it says the page's one subject twice.
    check(PAGE:find("labelBand:AddWidget(GUI:CreateHeader", 1, true) == nil,
          "band: ...and carries no header, because its first row's label already names it")
    -- All three rows go into it, in the page's own reading order.
    local order = {}
    for name in PAGE:gmatch("labelBand:AddWidget%(GUI:CreatePopoutRow%(self%.child, {\n%s*label%s*=%s*L%[\"([^\"]+)\"%]") do
        order[#order + 1] = name
    end
    eq(#order, 3, "band: three rows go into the band")
    eq(order[1], "Raid Group Labels", "band: the enable row opens it")
    eq(order[2], "Font Settings",     "band: ...then Font Settings")
    eq(order[3], "Position",          "band: ...then Position, the page's old reading order")

    -- ---- the Add order ------------------------------------------------
    local adds = {}
    for name, col in PAGE:gmatch("Add%((%a[%w_]*),%s*nil,%s*([%w\"_]+)%)") do
        adds[#adds + 1] = { name = name, col = col }
    end
    local function indexOf(name, col)
        for i, e in ipairs(adds) do
            if e.name == name and (col == nil or e.col == col) then return i end
        end
    end
    -- ☠ THE BAND IS ADDED AFTER ITS LAST ROW, AND THE CONTROL ROW'S BAND AFTER
    -- IT. `Add` resolves a widget's slot height on the spot, so a band added
    -- before its rows would be measured empty. Both are "both", so what follows
    -- is purely the page's reading order. The classic arm keeps the box's own Add
    -- exactly where it always was.
    check(indexOf("labelBand", '"both"') ~= nil, "order: the band spans both columns")
    check(indexOf("formatBand", '"both"') ~= nil, "order: ...and so does the Text Format band")
    check(indexOf("formatGroup", "2") ~= nil, "order: classic still puts Text Format in column 2")
    check(PAGE:find('Add(labelBand, nil, "both")\n            Add(formatBand, nil, "both")', 1, true) ~= nil,
          "order: in the popout layout the band is added first, then the control row's band")
    check(PAGE:find("Add(formatGroup, nil, 2)", 1, true) ~= nil,
          "order: ...and classic still adds Text Format at its own slot")

    -- The classic column assignments, unchanged -- the one thing this pass was
    -- not allowed to move.
    local CLASSIC_COL = {
        settingsGroup = "1", fontGroup = "2", positionGroup = "1",
    }
    for name, col in pairs(CLASSIC_COL) do
        check(indexOf(name, col) ~= nil,
              "order: the classic " .. name .. " still goes to column " .. col)
    end
    -- Four bare 280 boxes are left, and every one is inside a classicLayout arm:
    -- a fifth appearing outside one is the drift this counts.
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 4, "order: four bare 280 boxes left, and they are the classic branch's own")

    -- ---- the copy button and the two mode messages are untouched -------
    check(PAGE:find('Add(CreateCopyButton(self.child, {"groupLabel"}, L["Group Labels"], "general_labels"), 25, 2)', 1, true) ~= nil,
          "page: the copy button is still the first thing on the page")
    check(PAGE:find("partyMsg.hideOn = function() return GUI.SelectedMode == \"raid\" end", 1, true) ~= nil,
          "page: the party-mode message keeps its own gate")
    check(PAGE:find("flatMsg.hideOn = function() return GUI.SelectedMode ~= \"raid\" or db.raidUseGroups end", 1, true) ~= nil,
          "page: ...and the flat-layout message keeps its own")
end
