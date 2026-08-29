local NS = ...

-- ============================================================
-- BUFF BAR PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Indicators.lua
-- ------------------------------------------------------------
-- Auras > Buff Bar is the widest page the sweep has taken: TWELVE groups, eleven
-- of which become feature rows in four bands and one of which -- a lone checkbox
-- -- becomes a CONTROL ROW on the same plate.
--
--   "Content" band     Visibility (hoists showBuffs, the PAGE gate), Buff
--                      Filters, Order & Limits, and the Hide Duplicate Buffs
--                      control row.
--   "Icon" band        Appearance, Layout, Position, Border (hoists
--                      buffShowBorder through the toolkit's noShowToggle).
--   "Text" band        Duration Text (hoists buffShowDuration), Stack Count.
--   headerless band    Duration Bar (hoists buffDurationBarEnabled) and
--                      Pandemic (hoists buffPandemicEnabled through the new
--                      noEnableToggle) -- both carry the same hideOn, so a
--                      header would be a section title standing over nothing on
--                      a client with no factory row.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db, the filter
-- registry -- so this file does what the other census files do: it reads the
-- page's SOURCE and asserts against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each extracted builder -- kind, L key, db key and
--     slot height, in order -- taken from the PRE-CHANGE source, so a builder
--     that quietly dropped a control or renamed a key fails here. This is also
--     the evidence that CLASSIC RENDERS AS IT DID: the classic branch mounts the
--     same builder into the same 280 box in the same column.
--   ✓ that ONE builder serves both layouts.
--   ✓ that each declared row COUNT matches what its pane mounts, less whatever
--     the row hoisted.
--   ✓ that the Duration Format dropdown stopped rebuilding the page FROM INSIDE
--     A PANE, while classic still does exactly what it always did.
--   ✓ that the page gate greys exactly the rows it greyed boxes in classic.
--   ✗ nothing about runtime behaviour -- the callbacks, the greying and the
--     summaries are read by eye and by the in-game checklist.
-- ============================================================

-- ⚠ NORMALISED TO LF UP FRONT. This page file ships CRLF (the companion's files
-- are mixed per file), and a plain multi-line `find` for source text would miss
-- every one of them otherwise. Nothing here asserts about line endings.
local SRC = options_file_source("GUI/Pages/Indicators.lua"):gsub("\r\n", "\n")
local CTRL = options_file_source("GUI/Controls.lua"):gsub("\r\n", "\n")

-- ---- the census reader (the Frame page's, plus this page's composites) ----
-- The four extra kinds are the shared helpers this page mounts as single
-- widgets or single blocks. Without them the census would silently skip a
-- growth control, a whole TextStyle block and the entire border toolkit --
-- which is most of what two of these rows ARE.
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateSeparator = "separator", CreateButton = "button",
    CreateGrowthControl = "growth", CreateTextureDropdown = "texturedropdown",
    CreateTextControls = "textcontrols", CreateBorderControls = "bordercontrols",
    CreatePandemicControls = "pandemic", CreateDurationFormatControls = "durationformat",
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

-- The page, scoped by its own two ends: Indicators.lua holds four pages, and a
-- bare 280 box on one of the others is not this pass's business.
local PAGE
do
    local a = SRC:find('BuildPage(pageBuffs, function(self, db, Add, AddSpace, AddSyncPoint)', 1, true)
    local b = SRC:find('local pageDebuffs = CreateSubTab("auras", "auras_debuffs", L["Debuff Bar"])', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Buff Bar page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

local function esc(s) return (s:gsub("%p", "%%%0")) end

-- The block a row is declared in, from its label to the closing brace of the
-- CreatePopoutRow opts. ⚠ The frontier keeps `colorLabel = L[...]` (the
-- TextStyle block's own option) from answering as a row label.
local function rowOpts(labelKey)
    local a = PAGE:find('%f[%w]label%s*=%s*L%["' .. esc(labelKey) .. '"%]')
    check(a ~= nil, "source: a popout row is declared for " .. labelKey)
    if not a then return "" end
    local b = PAGE:find("}))", a, true)
    return PAGE:sub(a, (b or a) + 2)
end

-- What every converted group on this page has in common.
local function checkShared(builder, rowLabel, boxHeader, column)
    -- ONE builder, BOTH layouts: the declaration and the two mounts.
    local calls = 0
    for _ in PAGE:gmatch(builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, rowLabel .. ": declared once, mounted twice -- classic box and popout pane")

    -- The classic branch builds the box it always did, with its own header, in
    -- the column it always had.
    check(PAGE:find('GUI:CreateHeader(self.child, L["' .. boxHeader .. '"])', 1, true) ~= nil,
          rowLabel .. ": the classic box keeps its own header (" .. boxHeader .. ")")
    -- The box VARIABLE, found by walking every bare 280 box on the page and
    -- asking which one puts this header on itself. A fixed line distance would
    -- not do: two of these boxes carry a hideOn and an essay between the two
    -- lines, and one of them is four comment lines deep.
    local box
    for at, name in PAGE:gmatch("()local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)") do
        local want = name .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. boxHeader .. '"])'
        local hit = PAGE:find(want, at, true)
        if hit and hit - at < 900 then box = name break end
    end
    check(box ~= nil, rowLabel .. ": ...and that header belongs to a bare 280 box")
    if box then
        check(PAGE:find("Add(" .. box .. ", nil, " .. column .. ")", 1, true) ~= nil,
              rowLabel .. ": ...which still goes to column " .. column)
    end

    local opts = rowOpts(rowLabel)
    check(opts ~= "" and opts:find("build", 1, true) ~= nil,
          rowLabel .. ": the row is handed a pre-built mount")
    check(opts:find("window", 1, true) ~= nil,
          rowLabel .. ": ...docked outside the settings window")
    check(opts:find("clipTo", 1, true) ~= nil,
          rowLabel .. ": ...and clipped by the page's own scroll frame, not the window")
end

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED MACHINERY, AND ITS VOCABULARY MOVED UP
-- ============================================================
print("-- Buff Bar page: the shared popout machinery and the page-scope vocabulary")
do
    check(PAGE:find("local classicLayout = DF:IsClassicSettingsLayout()", 1, true) ~= nil,
          "tools: the page asks which layout it is building")
    check(PAGE:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true) ~= nil,
          "tools: ...and takes the shared machinery unconditionally")

    for _, v in ipairs({ "PopoutContent", "ReflowPane", "ReflowMounted", "ClaimKeys",
                         "WireModifiedTick", "WireFooter", "RegisterHoistedToggle",
                         "RegisterControlRow", "RefreshAfterGroupWrite", "HoldReason" }) do
        check(PAGE:find("local function " .. v .. "(", 1, true) == nil,
              "tools: the page does not re-declare " .. v)
    end
    check(PAGE:find("_popoutHolders", 1, true) == nil,
          "tools: the page never manages the popout holders itself")
    check(PAGE:find("_popoutRowForKey", 1, true) == nil,
          "tools: ...nor the search row map")

    -- ---- the four bands ----------------------------------------------
    for _, b in ipairs({ "contentBand", "iconBand", "textBand", "factoryBand" }) do
        check(PAGE:find(b .. " = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
              "bands: " .. b .. " is chromeless, at the width the layout pass will give it")
    end
    for _, pair in ipairs({ { "contentBand", "Content" }, { "iconBand", "Icon" }, { "textBand", "Text" } }) do
        check(PAGE:find(pair[1] .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. pair[2] .. '"]), 40)', 1, true) ~= nil,
              "bands: ..." .. pair[1] .. " names its section with the locale's own " .. pair[2])
    end
    -- ☠ AND THE FOURTH HAS NO HEADER. Both its rows carry HideDurationBar, so a
    -- header there would be a section title left standing over nothing.
    check(PAGE:find("factoryBand:AddWidget(GUI:CreateHeader", 1, true) == nil,
          "bands: the factory-only band is headerless, because both its rows can hide")

    -- ---- the vocabulary, at PAGE scope, declared exactly once ---------
    -- The rows print the chosen value as their summary, and a summary is built
    -- outside the group's builder -- so the word has to come out of the same
    -- table the dropdown offers.
    for _, name in ipairs({ "anchorOptions", "buffSortOptions", "durationFormatOptions",
                            "durBarPositionOptions" }) do
        local decls = 0
        for _ in PAGE:gmatch("local " .. name .. " = {") do decls = decls + 1 end
        eq(decls, 1, "vocab: " .. name .. " is declared exactly once, at page scope")
    end
    check(PAGE:find('DEFAULT = L["Default (Slot Order)"]', 1, true) ~= nil
      and PAGE:find('TIMER = L["Timer"]', 1, true) ~= nil,
          "vocab: ...and they are the same tables the dropdowns have always offered")

    -- ⚠ ABOVE EVERY BUILDER. A builder is a closure and captures the upvalue that
    -- exists when it is created, so one declared above these would see nil.
    local vocabAt = PAGE:find("local anchorOptions = {", 1, true)
    for _, b in ipairs({ "BuildVisibilityGroup", "BuildBuffFilterGroup", "BuildBuffOrderGroup",
                         "BuildBuffAppearanceGroup", "BuildBuffLayoutGroup",
                         "BuildBuffPositionGroup", "BuildBuffBorderGroup",
                         "BuildBuffDurationGroup", "BuildBuffStackGroup",
                         "BuildBuffDurationBarGroup", "BuildBuffPandemicGroup" }) do
        local at = PAGE:find("local function " .. b .. "(tools2)", 1, true)
        check(at ~= nil and vocabAt ~= nil and vocabAt < at,
              "vocab: " .. b .. " is declared after it, so it closes over the real tables")
    end

    -- The registry hook block runs ONCE PER PAGE BUILD, in both layouts -- not
    -- once per pane instance, which is what leaving it in the builder would mean.
    check(PAGE:find("self.dfBuffFilterSignature = RegistrySignature()", 1, true) ~= nil,
          "vocab: the filter-registry signature is taken at page scope")
    local hooks = 0
    for _ in PAGE:gmatch("self:HookScript%(\"OnShow\"") do hooks = hooks + 1 end
    eq(hooks, 1, "vocab: ...and the OnShow invalidation is hooked exactly once")
    check(builderBody("BuildBuffFilterGroup"):find("HookScript", 1, true) == nil,
          "vocab: ...from outside the builder, so a pinned second pane cannot re-take it")
end

-- ============================================================
-- 2. THE PAGE GATE -- showBuffs greys the rows it greyed boxes
-- ============================================================
print("-- Buff Bar page: the page gate")
do
    check(PAGE:find("local function BuffsOffRow(d) return not (d or db).showBuffs end", 1, true) ~= nil,
          "gate: the page names its own gate once")

    -- Nine rows greyed, and they are exactly the nine groups classic dims.
    for _, row in ipairs({ "orderRow", "appearanceRow", "layoutRow", "positionRow",
                           "borderRow", "durationRow", "stackRow", "durBarRow" }) do
        check(PAGE:find(row .. ".disableOn = BuffsOffRow", 1, true) ~= nil,
              "gate: " .. row .. " greys while the bar is off")
    end
    -- Pandemic greys for a second reason as well: the silent-capability-skip
    -- rule, which the suppressed Enable checkbox used to carry itself.
    check(PAGE:find("return not pandemicSupported or BuffsOffRow(d)", 1, true) ~= nil,
          "gate: the Pandemic row greys on an unsupported client too, since it holds that tick now")

    -- ...and the three that classic has NEVER dimmed do not start now.
    check(PAGE:find("visRow.disableOn", 1, true) == nil,
          "gate: the Visibility row is not greyed -- it carries the gate's own tick")
    check(PAGE:find("filterRow.disableOn", 1, true) == nil,
          "gate: the Buff Filters row is not greyed -- its box never was")
    check(PAGE:find("dedupRow.disableOn", 1, true) == nil,
          "gate: the Hide Duplicate Buffs control row is not greyed -- its box never was")

    -- ☠ THE GROUP GATE SKIPS CHILD ONE, WHICH IN A PANE IS NOT A HEADER. Only
    -- the three panes whose first child is a GATED CONTROL need the repair.
    check(PAGE:find("local function GatePaneFirstChild(group)", 1, true) ~= nil,
          "gate: the index-1 repair is declared once")
    -- Call SITES only: the declaration line is `local function
    -- GatePaneFirstChild(group)`, which has code rather than only whitespace
    -- between the line break and the name.
    local gated = 0
    for _ in PAGE:gmatch("\n%s+GatePaneFirstChild%(group%)\n") do gated = gated + 1 end
    eq(gated, 3, "gate: ...and applied at exactly three mounts (Order & Limits, Duration Text, Stack Count)")
    -- Each of those three is a builder that sets a group-wide gate; a pane that
    -- opens on a label or on a control with its own disableOn does not need it.
    for _, b in ipairs({ "BuildBuffOrderGroup", "BuildBuffDurationGroup", "BuildBuffStackGroup" }) do
        check(builderBody(b):find("group.disableChildrenOn = function(d) return not d.showBuffs end", 1, true) ~= nil,
              "gate: " .. b .. " carries the group gate that skips index 1")
    end
end

-- ============================================================
-- 3. THE DURATION FORMAT GATE -- classic still rebuilds, the pane must not
-- Picking a format re-gates the two Hide Above controls (neither composes with
-- Percent). Classic has always paid for that with a page REBUILD and still does.
-- A rebuild inside a pane retires the row the user is clicking through.
-- ============================================================
print("-- Buff Bar page: the duration format gate")
do
    local gate = PAGE:match("local function DurationFormatRefresh%(tools2%)(.-)\n        end")
    check(gate ~= nil, "format gate: the page decides this once, in a named function")
    if gate then
        check(gate:find("if tools2.popout then", 1, true) ~= nil,
              "format gate: ...branching on which layout the group was built for")
        check(gate:find("tools2.refreshStates()", 1, true) ~= nil,
              "format gate: ...the pane re-runs the state passes")
        check(gate:find("GUI:RefreshCurrentPage()", 1, true) ~= nil,
              "format gate: ...and classic still rebuilds, exactly as it always did")
    end

    -- ...and that is the ONLY page rebuild left anywhere on this page.
    local rebuilds = 0
    for _ in PAGE:gmatch("GUI:RefreshCurrentPage") do rebuilds = rebuilds + 1 end
    eq(rebuilds, 1, "format gate: exactly one page rebuild left on the page, and it is classic's")

    for _, b in ipairs({ "BuildVisibilityGroup", "BuildBuffFilterGroup", "BuildBuffOrderGroup",
                         "BuildBuffAppearanceGroup", "BuildBuffLayoutGroup",
                         "BuildBuffPositionGroup", "BuildBuffBorderGroup",
                         "BuildBuffDurationGroup", "BuildBuffStackGroup",
                         "BuildBuffDurationBarGroup", "BuildBuffPandemicGroup" }) do
        check(builderBody(b):find("GUI:RefreshCurrentPage", 1, true) == nil,
              "format gate: " .. b .. " never rebuilds the page from inside itself")
    end

    -- Every popout mount declares itself as one; eleven rows, eleven mounts.
    local popouts = 0
    for _ in PAGE:gmatch("popout = true,") do popouts = popouts + 1 end
    eq(popouts, 11, "format gate: all eleven popout mounts declare themselves as panes")
end

-- ============================================================
-- 4. THE ELEVEN BUILDERS, CONTROL BY CONTROL
-- Every golden below is the census of the PRE-CHANGE source: same factories,
-- same L keys, same db keys, same slot heights, in the same order.
-- ============================================================
local VISIBILITY = {
    { "checkbox", "Show Buffs", "showBuffs", 30 },
    { "slider",   "Max Buffs",  "buffMax",   55 },
}
-- The filter list is DATA: two scope switches, the rule, the caption, ONE
-- SelectionCheckbox factory (which the two loops and the complement bucket all
-- go through), the tracking count and Manage Filters.
local BUFF_FILTERS = {
    { "checkbox",  "All Buffs",     "directBuffShowAll",  30 },
    { "checkbox",  "Only My Buffs", "directBuffOnlyMine", 30 },
    { "separator", "(none)",        "(none)",             14 },
    { "label",     "(none)",        "(none)",             35 },
    { "checkbox",  "(none)",        "(none)",             30 },
    { "label",     "(none)",        "(none)",             24 },
    { "button",    "Manage Filters", "(none)",            30 },
}
local BUFF_ORDER = {
    { "dropdown", "Sort Order",                 "directBuffSortOrder",      55 },
    { "checkbox", "My Auras First",             "directBuffSortMineFirst",  30 },
    { "checkbox", "Reverse Order",              "directBuffSortReverse",    30 },
    { "checkbox", "Hide Long Buffs",            "buffMaxDurationEnabled",   30 },
    { "slider",   "Hide Longer Than (minutes)", "buffMaxDurationMinutes",   55 },
    { "checkbox", "Hide Permanent Auras",       "buffHidePermanent",        30 },
}
local BUFF_APPEARANCE = {
    { "slider", "Icon Size", "buffSize",  55 },
    { "slider", "Scale",     "buffScale", 55 },
    { "slider", "Alpha",     "buffAlpha", 55 },
}
local BUFF_LAYOUT = {
    { "slider", "Icons Per Row", "buffWrap",     55 },
    { "slider", "Spacing X",     "buffPaddingX", 55 },
    { "slider", "Spacing Y",     "buffPaddingY", 55 },
}
local BUFF_POSITION = {
    { "dropdown", "Anchor",   "buffAnchor",  55 },
    { "growth",   "(none)",   "buffGrowth",  155 },
    { "slider",   "Offset X", "buffOffsetX", 55 },
    { "slider",   "Offset Y", "buffOffsetY", 55 },
}
local BUFF_BORDER = {
    -- The key the census reads off this one is the PREFIX the toolkit is handed,
    -- not a setting -- every one of its eighteen keys is built from it.
    { "bordercontrols", "(none)", "buff", nil },
}
local BUFF_DURATION = {
    { "checkbox",       "Show Duration",                    "buffShowDuration",              30 },
    { "checkbox",       "Hide Cooldown Swipe",              "buffHideSwipe",                 30 },
    { "durationformat", "(none)",                           "buffDurationFormat",            nil },
    { "textcontrols",   "(none)",                           "buffDuration",                  nil },
    { "checkbox",       "Color by Time Remaining",          "buffDurationColorByTime",       30 },
    { "checkbox",       "Hide Above Threshold",             "buffDurationHideAboveEnabled",  30 },
    { "slider",         "Hide Above (seconds)",             "buffDurationHideAboveThreshold", 55 },
    { "checkbox",       "Hide Duration on Permanent Auras", "buffDurationHideOnPermanent",   30 },
}
local BUFF_STACK = {
    { "textcontrols", "(none)", "buffStack", nil },
}
local BUFF_DURBAR = {
    { "label",            "Shows a bar on each icon that drains with the aura's remaining time.", "(none)", 30 },
    { "checkbox",         "Enable Duration Bar", "buffDurationBarEnabled",    30 },
    { "dropdown",         "Position",            "buffDurationBarPosition",   55 },
    { "slider",           "Height",              "buffDurationBarHeight",     55 },
    { "slider",           "Gap",                 "buffDurationBarGap",        55 },
    { "dropdown",         "Color Mode",          "buffDurationBarColorMode",  55 },
    { "texturedropdown",  "Texture",             "buffDurationBarTexture",    55 },
    { "colorpicker",      "Bar Color",           "buffDurationBarColor",      30 },
    { "colorpicker",      "Background Color",    "buffDurationBarBGColor",    30 },
    { "checkbox",         "Reverse Fill",        "buffDurationBarReverseFill", 30 },
}
local BUFF_PANDEMIC = {
    { "label",    "Highlights each icon once the aura can be refreshed without losing time.", "(none)", 30 },
    { "pandemic", "(none)", "(none)", nil },
}

-- ---- the rows that hoist a tick --------------------------------------
local HOISTED = {
    { builder = "BuildVisibilityGroup", label = "Visibility", boxHeader = "Visibility",
      golden = VISIBILITY, countVar = "VISIBILITY_COUNT", column = "1", hoistedIn = 1,
      row = "visRow", band = "contentBand", toggleKey = "showBuffs",
      toggleLabel = "Show Buffs", commit = "OnShowBuffsToggle",
      summary = "VisibilitySummary" },
    { builder = "BuildBuffBorderGroup", label = "Border", boxHeader = "Border",
      golden = BUFF_BORDER, countVar = "BUFF_BORDER_COUNT", column = "1", hoistedIn = 0,
      row = "borderRow", band = "iconBand", toggleKey = "buffShowBorder",
      toggleLabel = "Show Border", commit = "OnBuffBorderToggle",
      summary = "BuffBorderSummary", apply = "ApplyBuffBorder" },
    { builder = "BuildBuffDurationGroup", label = "Duration Text", boxHeader = "Duration Text",
      golden = BUFF_DURATION, countVar = "BUFF_DURATION_COUNT", column = "2", hoistedIn = 1,
      row = "durationRow", band = "textBand", toggleKey = "buffShowDuration",
      toggleLabel = "Show Duration", commit = "OnBuffDurationToggle",
      summary = "BuffDurationSummary", apply = "ApplyBuffDurationText" },
    { builder = "BuildBuffDurationBarGroup", label = "Duration Bar", boxHeader = "Duration Bar",
      golden = BUFF_DURBAR, countVar = "BUFF_DURBAR_COUNT", column = "2", hoistedIn = 1,
      row = "durBarRow", band = "factoryBand", toggleKey = "buffDurationBarEnabled",
      toggleLabel = "Enable Duration Bar", commit = "OnBuffDurationBarToggle",
      summary = "BuffDurationBarSummary", apply = "BuffBarChanged" },
    { builder = "BuildBuffPandemicGroup", label = "Pandemic", boxHeader = "Pandemic",
      golden = BUFF_PANDEMIC, countVar = "BUFF_PANDEMIC_COUNT", column = "2", hoistedIn = 0,
      row = "pandemicRow", band = "factoryBand", toggleKey = "buffPandemicEnabled",
      toggleLabel = "Enable", commit = "OnBuffPandemicToggle",
      summary = "BuffPandemicSummary", apply = "ApplyBuffPandemic" },
}

for _, g in ipairs(HOISTED) do
    print("-- Buff Bar page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())
    checkShared(g.builder, g.label, g.boxHeader, g.column)

    -- The hoist. Two shapes: a checkbox the page itself builds (skipped behind
    -- the flag, because classic still needs it), or a composite helper told not
    -- to build its own -- noShowToggle for the border toolkit, noEnableToggle
    -- for the pandemic section.
    if g.hoistedIn == 1 then
        check(body:find("if not tools2.hoistToggle then", 1, true) ~= nil,
              g.label .. ": the enable checkbox is skipped when the row has hoisted it")
    else
        check(body:find("tools2.hoistToggle or nil", 1, true) ~= nil,
              g.label .. ": the composite is told not to build its own toggle when the row has it")
    end

    local declared = tonumber(PAGE:match("local " .. g.countVar .. "%s*=%s*(%d+)"))
    check(declared ~= nil, g.label .. ": the page declares the row's count in one place")

    local opts = rowOpts(g.label)
    check(opts:find('toggle%s*=%s*{%s*key%s*=%s*"' .. g.toggleKey .. '"%s*}') ~= nil,
          g.label .. ": the row's tick is the group's own enable key")
    check(opts:find("summary%s*=%s*" .. g.summary) ~= nil,
          g.label .. ": ...it declares a summary of its own")
    check(opts:find("count%s*=%s*" .. g.countVar) ~= nil,
          g.label .. ": ...and the declared count, not a literal")
    check(opts:find("onToggle%s*=%s*" .. g.commit) ~= nil,
          g.label .. ": ...and a commit that is not a page rebuild")

    -- ...into the right band.
    check(PAGE:find("local " .. g.row .. " = " .. g.band .. ":AddWidget(GUI:CreatePopoutRow(", 1, true) ~= nil,
          g.label .. ": the row is mounted into the " .. g.band)

    -- ☠ THE COMMIT IS NOT A PAGE REBUILD.
    local commit = PAGE:match("local function " .. g.commit .. "%(%)(.-)\n            end")
                or PAGE:match("local function " .. g.commit .. "%(%)(.-)\n        end")
    check(commit ~= nil, g.label .. ": the popout commit is a named function")
    if commit then
        check(commit:find("RefreshCurrentPage", 1, true) == nil,
              g.label .. ": ...and never rebuilds the page")
        check(commit:find("RefreshStates()", 1, true) ~= nil,
              g.label .. ": ...it re-runs the state passes instead")
        check(commit:find("ReflowMounted()", 1, true) ~= nil,
              g.label .. ": ...and reflows the open panes")
    end

    -- The hoisted toggle keeps its search entry under the SAME label and key the
    -- suppressed checkbox carried, or the setting becomes unfindable in the
    -- popout layout while staying findable in classic.
    check(PAGE:find('tools.RegisterHoistedToggle(' .. g.row .. ', L["' .. g.toggleLabel .. '"], "' .. g.toggleKey .. '", ' .. g.commit .. ')', 1, true) ~= nil,
          g.label .. ": the hoisted toggle keeps its search entry")

    -- The strip.
    check(PAGE:find("tools.ClaimKeys(" .. g.row .. ", ", 1, true) ~= nil,
          g.label .. ": the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(" .. g.row .. ")", 1, true) ~= nil,
          g.label .. ": ...its amber tick asks about exactly those keys")
    if g.apply then
        check(PAGE:find("tools.WireFooter(" .. g.row .. ", " .. g.apply .. ")", 1, true) ~= nil,
              g.label .. ": ...and Reset Group / Hold: Defaults push the change into the frames")
    else
        check(PAGE:find("tools.WireFooter(" .. g.row .. ", function()", 1, true) ~= nil,
              g.label .. ": ...and a footer with the group's own apply")
    end
end

-- ---- the rows with no tick to hoist ----------------------------------
local WAYIN = {
    { builder = "BuildBuffFilterGroup", label = "Buff Filters", boxHeader = "Buff Filters",
      golden = BUFF_FILTERS, column = "1", row = "filterRow", band = "contentBand",
      summary = "BuffFilterSummary" },
    { builder = "BuildBuffOrderGroup", label = "Order & Limits", boxHeader = "Order & Limits",
      golden = BUFF_ORDER, countVar = "BUFF_ORDER_COUNT", column = "1",
      row = "orderRow", band = "contentBand", summary = "BuffOrderSummary",
      apply = "BuffOrderChanged" },
    { builder = "BuildBuffAppearanceGroup", label = "Appearance", boxHeader = "Appearance",
      golden = BUFF_APPEARANCE, countVar = "BUFF_APPEARANCE_COUNT", column = "2",
      row = "appearanceRow", band = "iconBand", summary = "BuffAppearanceSummary",
      apply = "ApplyBuffPosition" },
    { builder = "BuildBuffLayoutGroup", label = "Layout", boxHeader = "Layout",
      golden = BUFF_LAYOUT, countVar = "BUFF_LAYOUT_COUNT", column = "1",
      row = "layoutRow", band = "iconBand", summary = "BuffLayoutSummary",
      apply = "ApplyBuffPosition" },
    { builder = "BuildBuffPositionGroup", label = "Position", boxHeader = "Position",
      golden = BUFF_POSITION, countVar = "BUFF_POSITION_COUNT", column = "1",
      row = "positionRow", band = "iconBand", summary = "BuffPositionSummary" },
    { builder = "BuildBuffStackGroup", label = "Stack Count", boxHeader = "Stack Count",
      golden = BUFF_STACK, countVar = "BUFF_STACK_COUNT", column = "2",
      row = "stackRow", band = "textBand", summary = "BuffStackSummary",
      apply = "ApplyBuffStackText" },
}

for _, g in ipairs(WAYIN) do
    print("-- Buff Bar page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())
    checkShared(g.builder, g.label, g.boxHeader, g.column)

    check(body:find("hoistToggle", 1, true) == nil,
          g.label .. ": the builder has no hoist branch, because there is nothing to hoist")

    local opts = rowOpts(g.label)
    check(opts:find("%f[%w]toggle%s*=") == nil,
          g.label .. ": the row declares no toggle")
    check(opts:find("onToggle", 1, true) == nil,
          g.label .. ": ...and so no commit either")
    check(opts:find("summary%s*=%s*" .. g.summary) ~= nil,
          g.label .. ": ...it does declare a summary")
    check(PAGE:find("local " .. g.row .. " = " .. g.band .. ":AddWidget(GUI:CreatePopoutRow(", 1, true) ~= nil,
          g.label .. ": the row is mounted into the " .. g.band)
    check(PAGE:find("tools.ClaimKeys(" .. g.row .. ", ", 1, true) ~= nil,
          g.label .. ": the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(" .. g.row .. ")", 1, true) ~= nil,
          g.label .. ": ...and its amber tick asks about exactly those keys")

    if g.countVar then
        local declared = tonumber(PAGE:match("local " .. g.countVar .. "%s*=%s*(%d+)"))
        check(declared ~= nil, g.label .. ": the page declares the row's count in one place")
        check(opts:find("count%s*=%s*" .. g.countVar) ~= nil,
              g.label .. ": ...and hands the row that constant, not a literal")
    end
    if g.apply then
        check(PAGE:find("tools.WireFooter(" .. g.row .. ", " .. g.apply .. ")", 1, true) ~= nil,
              g.label .. ": ...and its footer pushes the change into the frames")
    end
end

-- ============================================================
-- 5. THE COUNT ARITHMETIC
-- Each declared count is what the PANE mounts, which is the builder's census
-- less whatever left it for the row -- and for the two composite rows, what the
-- shared helper builds for the include set this page passes it.
-- ============================================================
print("-- Buff Bar page: the declared counts")
do
    local function declared(name) return tonumber(PAGE:match("local " .. name .. "%s*=%s*(%d+)")) end

    eq(declared("VISIBILITY_COUNT"), #VISIBILITY - 1,
       "counts: Visibility is the census less the hoisted Show Buffs tick")
    eq(declared("BUFF_ORDER_COUNT"), #BUFF_ORDER,
       "counts: Order & Limits is the whole census, nothing hoisted out of it")
    eq(declared("BUFF_APPEARANCE_COUNT"), #BUFF_APPEARANCE, "counts: Appearance")
    eq(declared("BUFF_LAYOUT_COUNT"), #BUFF_LAYOUT, "counts: Layout")
    eq(declared("BUFF_POSITION_COUNT"), #BUFF_POSITION,
       "counts: Position, the growth control counting as the one widget it is")
    eq(declared("BUFF_DURATION_COUNT"), 15,
       "counts: Duration Text -- the six page widgets it keeps, the format control, and the TextStyle block's eight, less the hoisted tick")
    eq(declared("BUFF_STACK_COUNT"), 8,
       "counts: Stack Count is exactly the TextStyle block's eight")
    eq(declared("BUFF_DURBAR_COUNT"), #BUFF_DURBAR - 1,
       "counts: Duration Bar is the census less the hoisted Enable tick")

    -- ☠ THE TWO COMPOSITE COUNTS, DERIVED FROM THE HELPER RATHER THAN ASSERTED
    -- AT IT. CreateBorderControls builds a fixed set plus one widget per include
    -- key, and this page's include set is { inset, offset, blendMode, gradient,
    -- shadow, alpha } with no colour source -- so the number moves the moment the
    -- toolkit gains a control, and a literal in the page would quietly stop
    -- matching what the pane mounts.
    local BORDER_BASE = 4          -- Show Border, thickness, style, texture
    local BORDER_COLOR = 1         -- the static colour picker
    local BORDER_GRADIENT = 3      -- start, end, direction
    local BORDER_SHADOW = 5        -- the block's tick plus colour, size, two offsets
    local BORDER_ALPHA, BORDER_INSET, BORDER_BLEND = 1, 1, 1
    local BORDER_OFFSET = 2
    local borderAll = BORDER_BASE + BORDER_COLOR + BORDER_GRADIENT + BORDER_SHADOW
                    + BORDER_ALPHA + BORDER_INSET + BORDER_BLEND + BORDER_OFFSET
    eq(borderAll, 18, "counts: the border toolkit builds eighteen for this include set")
    eq(declared("BUFF_BORDER_COUNT"), borderAll - 1,
       "counts: Border is those eighteen less the hoisted Show Border")

    -- Pandemic mounts the SAME toolkit for its BORDER mode, with noShowToggle
    -- already set by the helper -- so seventeen -- plus its own eight (the nine
    -- it builds less the tick this row now hoists) plus the page's own blurb.
    local PANDEMIC_OWN = 9         -- enable, explain, unsupported note, type, flash, speed, tint colour/alpha/inset
    eq(declared("BUFF_PANDEMIC_COUNT"), 1 + (PANDEMIC_OWN - 1) + (borderAll - 1),
       "counts: Pandemic is the blurb, its own eight, and the border toolkit's seventeen")

    -- The filter row's count is the one that is DATA rather than a constant.
    check(PAGE:find("local function BuffFilterCount()", 1, true) ~= nil,
          "counts: Buff Filters counts its own rows instead of declaring a literal")
    check(PAGE:find("return 7 + #R.Categories + customs", 1, true) ~= nil,
          "counts: ...the seven fixed widgets plus one per category and per custom filter")
    check(rowOpts("Buff Filters"):find("count%s*=%s*BuffFilterCount()") ~= nil,
          "counts: ...and the row is handed that count, not a number")
end

-- ============================================================
-- 6. THE CLAIMS, AND THE ONE FOOTER THIS PAGE REFUSES
-- ============================================================
print("-- Buff Bar page: the claims and the footer refusal")
do
    -- ⚠ TWO KEYS THE WALK CANNOT SEE, both named through `extra`.
    check(PAGE:find('tools.ClaimKeys(filterRow, filterContent, { "buffFilterSelection" })', 1, true) ~= nil,
          "claims: the filter row names the selection table -- every tick behind it is a custom get/set with no db binding")
    check(PAGE:find('tools.ClaimKeys(positionRow, positionContent, { "buffGrowth" })', 1, true) ~= nil,
          "claims: the position row names buffGrowth -- the growth control registers nothing with search")

    -- ☠ NO FOOTER ON THE FILTER ROW. Reset Group writes DeepCopy(default) into
    -- the key, which for buffFilterSelection REPLACES the table -- and the aura
    -- pipeline holds references to that table and its inner tables.
    check(PAGE:find("tools.WireFooter(filterRow", 1, true) == nil,
          "footer: the Buff Filters row has no footer, because a reset would strand the pipeline's references")
    check(PAGE:find("tools.WireModifiedTick(filterRow)", 1, true) ~= nil,
          "footer: ...but it keeps the amber tick, which only reads")

    -- Every other converted row has one.
    for _, row in ipairs({ "visRow", "orderRow", "appearanceRow", "layoutRow", "positionRow",
                           "borderRow", "durationRow", "stackRow", "durBarRow", "pandemicRow" }) do
        check(PAGE:find("tools.WireFooter(" .. row, 1, true) ~= nil,
              "footer: " .. row .. " carries Reset Group / Hold: Defaults")
    end
end

-- ============================================================
-- 7. THE CONTROL ROW, THE HIDDEN ROWS, THE BANDS AND THE PAGE'S OWN ORDER
-- ============================================================
print("-- Buff Bar page: the control row, the bands and the order")
do
    -- ---- the one single-option group: a CONTROL ROW ------------------
    check(PAGE:find('label%s*=%s*L%["Hide Duplicate Buffs"%],\n%s*kind%s*=%s*"checkbox"') ~= nil,
          "control row: Hide Duplicate Buffs is a checkbox control row")
    check(PAGE:find("contentBand:AddWidget(GUI:CreateControlRow(", 1, true) ~= nil,
          "control row: ...mounted into the Content band with the rows it belongs beside")
    check(PAGE:find("})), 30)", 1, true) == nil,
          "control row: ...with no call-site slot height, because the factory owns it")
    -- ⚠ NAMED FOR THE SETTING, not for the box: of "Deduplication" and "Hide
    -- Duplicate Buffs" the sentence is the one that survives standing alone -- and
    -- it is the caption the classic checkbox registers, so the search result reads
    -- the same in both layouts.
    check(PAGE:find('tools.RegisterControlRow(dedupRow, "checkbox", "buffDeduplicateDefensives", false, DedupChanged)', 1, true) ~= nil,
          "control row: ...registered with search through the shared verb, carrying the classic callback")
    check(PAGE:find('GUI:CreateHeader(self.child, L["Deduplication"])', 1, true) ~= nil,
          "control row: classic still builds the box under its own header")
    check(PAGE:find('GUI:CreateCheckbox(self.child, L["Hide Duplicate Buffs"], db, "buffDeduplicateDefensives", DedupChanged)', 1, true) ~= nil,
          "control row: ...and the tick it always had")
    check(PAGE:find("Add(dedupGroup, nil, 1)", 1, true) ~= nil,
          "control row: ...in column 1, where it has always been")
    -- ONE callback and ONE tooltip, shared by both layouts, so they cannot drift.
    local dedupFns = 0
    for _ in PAGE:gmatch("local function DedupChanged%(%)") do dedupFns = dedupFns + 1 end
    eq(dedupFns, 1, "control row: the callback is declared once and used by both layouts")
    local dedupTips = 0
    for _ in PAGE:gmatch("local DEDUP_TIP = L%[") do dedupTips = dedupTips + 1 end
    eq(dedupTips, 1, "control row: ...and so is the tooltip")

    -- ---- the two rows that can hide entirely -------------------------
    -- The box's own hideOn becomes the ROW's, so the band collapses the slot
    -- rather than leaving a gap where a bar the client cannot draw would be.
    check(PAGE:find("durBarRow.hideOn = HideDurationBar", 1, true) ~= nil,
          "hidden rows: the Duration Bar row carries the box's own factory gate")
    check(PAGE:find("pandemicRow.hideOn = HideDurationBar", 1, true) ~= nil,
          "hidden rows: ...and so does the Pandemic row")
    check(PAGE:find("durBarGroup.hideOn = HideDurationBar", 1, true) ~= nil
      and PAGE:find("pandemicGroup.hideOn = HideDurationBar", 1, true) ~= nil,
          "hidden rows: ...and classic still puts it on the boxes")

    -- ---- twelve bare 280 boxes left, all inside a classicLayout arm ---
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 12, "boxes: twelve bare 280 boxes left, and they are the classic branch's own")
    check(PAGE:find("280, tools", 1, true) == nil,
          "boxes: no stay-inline 280 box is left on the page")
    check(PAGE:find("bandStyle", 1, true) == nil,
          "boxes: the band skin is never restated as a literal (this page needs none)")

    -- ---- the Add order ------------------------------------------------
    -- Four full-width bands in reading order. With nothing left in a column
    -- there is no flow to unbalance.
    local a = PAGE:find('Add(contentBand, nil, "both")', 1, true)
    local b = PAGE:find('Add(iconBand, nil, "both")', 1, true)
    local c = PAGE:find('Add(textBand, nil, "both")', 1, true)
    local d = PAGE:find('Add(factoryBand, nil, "both")', 1, true)
    check(a and b and c and d and a < b and b < c and c < d,
          "order: the four bands span both columns, in reading order")

    -- ---- the page's own furniture is untouched -------------------------
    check(PAGE:find('Add(adBanner, 32, "both")', 1, true) ~= nil
      and PAGE:find('Add(adPromoBanner, 32, "both")', 1, true) ~= nil,
          "page: both Aura Designer banners survive, above everything")
    check(PAGE:find('{pageId = "auras_filterdesigner", label = L["Filter Designer"]}', 1, true) ~= nil,
          "page: ...and the See Also block is unchanged")
    check(PAGE:find('CreateCopyButton(self.child, {"buff", "showBuffs", "directBuff", "buffFilterSelection"}', 1, true) ~= nil,
          "page: ...and the copy button keeps the four prefixes it owns")
end

-- ============================================================
-- 8. THE TWO SHARED-HELPER CHANGES THIS PAGE NEEDED
-- Both live in GUI/Controls.lua, both are opt-in, and both are the same move a
-- previous page already made on a neighbouring helper.
-- ============================================================
print("-- Buff Bar page: the shared helpers it needed")
do
    -- (a) CreatePandemicControls gains noEnableToggle -- CreateBorderControls'
    -- noShowToggle, for the section that owns THIS toggle. Without it the pane
    -- would draw the same switch the row's tick already is.
    check(CTRL:find("if not opts.noEnableToggle then", 1, true) ~= nil,
          "helpers: CreatePandemicControls can be told not to build its own Enable tick")
    local pandemicBody = CTRL:match("function GUI:CreatePandemicControls%(group, dbTable, opts%)(.-)\nend\n")
    check(pandemicBody ~= nil, "helpers: ...the function is locatable")
    if pandemicBody then
        check(pandemicBody:find("w.enable.keepEnabled = true", 1, true) ~= nil,
              "helpers: ...the classic path still builds the tick exactly as it did")
        -- ☠ THE KEY IS STILL READ. The group gate folds Enabled in whether or not
        -- the checkbox exists, so a pane greys behind a hoisted tick.
        check(pandemicBody:find("return not supported or gated(db) or not enabled()", 1, true) ~= nil,
              "helpers: ...and the group gate still reads the Enabled key, so the pane greys behind a hoisted tick")
    end

    -- (b) The duration-format example joins the group-wide VALUE sweep. A
    -- dropdown's own refreshValue repaints the caption and knows nothing about
    -- the fontstring this helper bolted onto it, so a Reset Group left the
    -- example describing a format the user no longer had.
    check(CTRL:find("local ddRefreshValue = dd.refreshValue", 1, true) ~= nil,
          "helpers: the duration-format example repaints on a group-wide value sweep")
    check(CTRL:find("if ddRefreshValue then ddRefreshValue() end", 1, true) ~= nil,
          "helpers: ...chained rather than replaced, so the caption still repaints too")
end
