local NS = ...

-- ============================================================
-- DEFENSIVE ICON PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Indicators.lua
-- ------------------------------------------------------------
-- Auras > Defensive Icon is the fourth and last page in the Indicators file to
-- convert: NINE groups, all nine of which become feature rows in four bands.
-- There is no single-setting group on it, so no control row.
--
--   "Content" band  Settings (hoists defensiveIconEnabled, the PAGE gate) and
--                   Defensive Filters -- whether the icon exists, and which
--                   cooldowns reach it.
--   "Icon" band     Layout, Appearance, Position, Border (hoists
--                   defensiveIconShowBorder through the toolkit's noShowToggle).
--   "Text" band     Duration Text (hoists defensiveIconShowDuration), Stack
--                   Count. Stack Count can hide with the factory gate; Duration
--                   Text cannot, so the header is never left over nothing.
--   headerless band Duration Bar (hoists defensiveDurationBarEnabled) -- the one
--                   12.1-factory-only group, and the reason that band has no
--                   header: the row can hide.
--
-- ☠ THE FILTER ROW REFUSES A FOOTER, AND ITS TWIN ON THE DEBUFF PAGE DOES NOT.
-- That is a decision about the KEYS. Debuff Filters is seven booleans and a
-- string, so Reset Group writes values; defensiveFilterSelection is a TABLE the
-- aura pipeline holds references into, and a reset would replace it. The Buff
-- Bar's filter row refused for exactly the same reason.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db, the filter
-- registry -- so this file does what the other census files do: it reads the
-- page's SOURCE and asserts against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each extracted builder -- kind, L key, db key and
--     slot height, in order -- taken from the PRE-CHANGE source.
--   ✓ that ONE builder serves both layouts, and that classic still adds its
--     nine boxes in the columns and the ORDER it always did.
--   ✓ that each declared row COUNT matches what its pane mounts, less whatever
--     the row hoisted.
--   ✓ that the page gate greys exactly the rows it greyed boxes in classic.
--   ✗ nothing about runtime behaviour -- the callbacks, the greying and the
--     summaries are read by eye and by the in-game checklist.
-- ============================================================

-- ⚠ NORMALISED TO LF UP FRONT. This page file ships CRLF.
local SRC = options_file_source("GUI/Pages/Indicators.lua"):gsub("\r\n", "\n")

local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateSeparator = "separator", CreateButton = "button",
    CreateGrowthControl = "growth", CreateTextureDropdown = "texturedropdown",
    CreateTextControls = "textcontrols", CreateBorderControls = "bordercontrols",
    CreateDurationFormatControls = "durationformat", CreateInfoBanner = "banner",
}

-- The body of a `local function <name>(tools2)` at the page builder's own
-- indent. Terminated on a newline + EIGHT spaces + `end`, which is that indent.
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

-- The page, scoped by its own two ends.
local PAGE
do
    local a = SRC:find('BuildPage(pageDefensiveIcon, function(self, db, Add, AddSpace, AddSyncPoint)', 1, true)
    local b = SRC:find('local pageTargetedList = CreateSubTab("indicators", "indicators_targetedlist", L["Targeted List"])', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Defensive Icon page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

local function esc(s) return (s:gsub("%p", "%%%0")) end

local function rowOpts(labelKey)
    local a = PAGE:find('%f[%w]label%s*=%s*L%["' .. esc(labelKey) .. '"%]')
    check(a ~= nil, "source: a popout row is declared for " .. labelKey)
    if not a then return "" end
    local b = PAGE:find("}))", a, true)
    return PAGE:sub(a, (b or a) + 2)
end

local function checkShared(builder, rowLabel, boxHeader, column)
    local calls = 0
    for _ in PAGE:gmatch(builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, rowLabel .. ": declared once, mounted twice -- classic box and popout pane")

    check(PAGE:find('GUI:CreateHeader(self.child, L["' .. boxHeader .. '"])', 1, true) ~= nil,
          rowLabel .. ": the classic box keeps its own header (" .. boxHeader .. ")")
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
print("-- Defensive Icon page: the shared popout machinery and the page-scope vocabulary")
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
    -- ☠ AND THE FOURTH HAS NO HEADER. Its only row carries the factory gate.
    check(PAGE:find("factoryBand:AddWidget(GUI:CreateHeader", 1, true) == nil,
          "bands: the factory-only band is headerless, because its one row can hide")
    -- ...while the Text band's other row cannot, so that header always stands
    -- over something.
    check(PAGE:find("durationRow.hideOn", 1, true) == nil,
          "bands: the Duration Text row never hides, so the Text header is never stranded")

    -- ---- the vocabulary, at PAGE scope, declared exactly once ---------
    for _, name in ipairs({ "anchorOptions", "defSortOptions", "defDurFormatOptions",
                            "defBarPositionOptions" }) do
        local decls = 0
        for _ in PAGE:gmatch("local " .. name .. " = {") do decls = decls + 1 end
        eq(decls, 1, "vocab: " .. name .. " is declared exactly once, at page scope")
    end
    check(PAGE:find('DEFAULT = L["Default (Slot Order)"]', 1, true) ~= nil
      and PAGE:find('EXTERNALS = L["Externals First"]', 1, true) ~= nil
      and PAGE:find('TIMER = L["Timer"]', 1, true) ~= nil,
          "vocab: ...and they are the same tables the dropdowns have always offered")

    -- ⚠ ABOVE EVERY BUILDER. A builder is a closure and captures the upvalue that
    -- exists when it is created, so one declared above these would see nil.
    local vocabAt = PAGE:find("local anchorOptions = {", 1, true)
    for _, b in ipairs({ "BuildDefensiveSettingsGroup", "BuildDefensiveFilterGroup",
                         "BuildDefensiveLayoutGroup", "BuildDefensiveAppearanceGroup",
                         "BuildDefensivePositionGroup", "BuildDefensiveBorderGroup",
                         "BuildDefensiveDurationGroup", "BuildDefensiveStackGroup",
                         "BuildDefensiveDurationBarGroup" }) do
        local at = PAGE:find("local function " .. b .. "(tools2)", 1, true)
        check(at ~= nil and vocabAt ~= nil and vocabAt < at,
              "vocab: " .. b .. " is declared after it, so it closes over the real tables")
    end

    -- The registry hook block runs ONCE PER PAGE BUILD, in both layouts -- not
    -- once per pane instance, which is what leaving it in the builder would mean.
    check(PAGE:find("self.dfDefFilterSignature = RegistrySignature()", 1, true) ~= nil,
          "vocab: the filter-registry signature is taken at page scope")
    local hooks = 0
    for _ in PAGE:gmatch("self:HookScript%(\"OnShow\"") do hooks = hooks + 1 end
    eq(hooks, 1, "vocab: ...and the OnShow invalidation is hooked exactly once")
    check(builderBody("BuildDefensiveFilterGroup"):find("HookScript", 1, true) == nil,
          "vocab: ...from outside the builder, so a pinned second pane cannot re-take it")
end

-- ============================================================
-- 2. THE PAGE GATE -- defensiveIconEnabled greys the rows it greyed boxes
-- ============================================================
print("-- Defensive Icon page: the page gate")
do
    check(PAGE:find("local function DefensiveOffRow(d) return not (d or db).defensiveIconEnabled end", 1, true) ~= nil,
          "gate: the page names its own gate once")

    -- Eight rows greyed, and they are exactly the eight groups classic dims --
    -- the filter row INCLUDED, which is where this page parts company with the
    -- two bar pages.
    for _, row in ipairs({ "filterRow", "layoutRow", "appearanceRow", "positionRow",
                           "borderRow", "durationRow", "stackRow", "durBarRow" }) do
        check(PAGE:find(row .. ".disableOn = DefensiveOffRow", 1, true) ~= nil,
              "gate: " .. row .. " greys while the icon is off")
    end
    check(PAGE:find("settingsRow.disableOn", 1, true) == nil,
          "gate: the Settings row is not greyed -- it carries the gate's own tick")

    -- Every builder still declares the group gate it always did.
    for _, b in ipairs({ "BuildDefensiveSettingsGroup", "BuildDefensiveFilterGroup",
                         "BuildDefensiveLayoutGroup", "BuildDefensiveAppearanceGroup",
                         "BuildDefensivePositionGroup", "BuildDefensiveDurationGroup",
                         "BuildDefensiveStackGroup" }) do
        check(builderBody(b):find("group.disableChildrenOn = HideDefensiveIconOptions", 1, true) ~= nil,
              "gate: " .. b .. " carries the group gate the classic box had")
    end
    check(builderBody("BuildDefensiveBorderGroup"):find("tools2.group.disableChildrenOn = HideDefensiveIconOptions", 1, true) ~= nil,
          "gate: the border builder carries it too, after the toolkit has mounted")
    -- The Duration Bar's gate is the compound one it has always had.
    check(builderBody("BuildDefensiveDurationBarGroup"):find(
              "group.disableChildrenOn = function(d) return not d.defensiveIconEnabled or not d.defensiveDurationBarEnabled end", 1, true) ~= nil,
          "gate: the Duration Bar keeps its compound gate -- the feature AND the bar")

    -- ☠ THE GROUP GATE SKIPS CHILD ONE, WHICH IN A PANE IS NOT A HEADER.
    check(PAGE:find("local function GatePaneFirstChild(group)", 1, true) ~= nil,
          "gate: the index-1 repair is declared once")
    local gated = 0
    for _ in PAGE:gmatch("\n%s+GatePaneFirstChild%(group%)\n") do gated = gated + 1 end
    eq(gated, 5, "gate: ...and applied at exactly five mounts (Appearance, Position, Border, Duration Text, Stack Count)")
    -- The four it is NOT applied to open on a LABEL, which has nothing to grey.
    for _, b in ipairs({ "BuildDefensiveSettingsGroup", "BuildDefensiveFilterGroup",
                         "BuildDefensiveLayoutGroup", "BuildDefensiveDurationBarGroup" }) do
        check(builderBody(b):find("GUI:CreateLabel(parent,", 1, true) ~= nil,
              "gate: " .. b .. " opens its pane on a label, so index 1 has nothing to grey")
    end
end

-- ============================================================
-- 3. NO PAGE REBUILD ANYWHERE, IN EITHER LAYOUT
-- This page never had one -- unlike the two bar pages, whose Duration Format
-- dropdown re-gated a pair of Hide Above controls -- and the conversion must not
-- introduce one: a rebuild retires the row the user is clicking through.
-- ============================================================
print("-- Defensive Icon page: no page rebuild")
do
    check(PAGE:find("GUI:RefreshCurrentPage", 1, true) == nil,
          "rebuild: the page rebuilds itself from nowhere, in either layout")

    local popouts = 0
    for _ in PAGE:gmatch("popout = true,") do popouts = popouts + 1 end
    eq(popouts, 9, "rebuild: all nine popout mounts declare themselves as panes")

    for _, b in ipairs({ "BuildDefensiveSettingsGroup", "BuildDefensiveFilterGroup",
                         "BuildDefensiveLayoutGroup", "BuildDefensiveAppearanceGroup",
                         "BuildDefensivePositionGroup", "BuildDefensiveBorderGroup",
                         "BuildDefensiveDurationGroup", "BuildDefensiveStackGroup",
                         "BuildDefensiveDurationBarGroup" }) do
        check(builderBody(b):find("self:RefreshStates()", 1, true) == nil,
              "rebuild: " .. b .. " never reaches past its own tools2 for a state pass")
    end
end

-- ============================================================
-- 4. THE NINE BUILDERS, CONTROL BY CONTROL
-- Every golden below is the census of the PRE-CHANGE source: same factories,
-- same L keys, same db keys, same slot heights, in the same order.
-- ============================================================
local DEFENSIVE_SETTINGS = {
    { "label",    "Shows an icon when party members have a defensive cooldown active (Pain Suppression, Ironbark, etc.).", "(none)", 45 },
    { "checkbox", "Enable Defensive Icon", "defensiveIconEnabled",   30 },
    { "checkbox", "Hide Cooldown Swipe",   "defensiveIconHideSwipe", 30 },
}
-- The filter list is DATA: the caption, ONE SelectionCheckbox factory (which the
-- two loops and the complement bucket all go through) and Manage Filters.
local DEFENSIVE_FILTERS = {
    { "label",    "(none)",         "(none)", 35 },
    { "checkbox", "(none)",         "(none)", 30 },
    { "button",   "Manage Filters", "(none)", 30 },
}
local DEFENSIVE_LAYOUT = {
    { "label",    "Controls how multiple defensive icons are arranged.", "(none)", 45 },
    { "growth",   "(none)",        "defensiveBarGrowth",  155 },
    { "slider",   "Max Icons",     "defensiveBarMax",      55 },
    { "dropdown", "Sort Order",    "defensiveSortOrder",   55 },
    { "slider",   "Icons Per Row", "defensiveBarWrap",     55 },
    { "slider",   "Spacing",       "defensiveBarSpacing",  55 },
}
local DEFENSIVE_APPEARANCE = {
    { "slider", "Icon Size",   "defensiveIconSize",       55 },
    { "slider", "Scale",       "defensiveIconScale",      55 },
    { "slider", "Frame Level", "defensiveIconFrameLevel", 55 },
}
local DEFENSIVE_POSITION = {
    { "dropdown", "Anchor",   "defensiveIconAnchor", 55 },
    { "slider",   "Offset X", "defensiveIconX",      55 },
    { "slider",   "Offset Y", "defensiveIconY",      55 },
}
local DEFENSIVE_BORDER = {
    -- The key the census reads off this one is the PREFIX the toolkit is handed,
    -- not a setting -- every one of its nineteen keys is built from it.
    { "bordercontrols", "(none)", "defensiveIcon", nil },
}
local DEFENSIVE_DURATION = {
    { "checkbox",       "Show Duration",                    "defensiveIconShowDuration",            30 },
    { "durationformat", "(none)",                           "defensiveIconDurationFormat",          nil },
    { "textcontrols",   "(none)",                           "defensiveIconDuration",                nil },
    { "checkbox",       "Color by Time Remaining",          "defensiveIconDurationColorByTime",     30 },
    { "checkbox",       "Hide Duration on Permanent Auras", "defensiveIconDurationHideOnPermanent", 30 },
}
local DEFENSIVE_STACK = {
    { "textcontrols", "(none)", "defensiveIconStack", nil },
}
local DEFENSIVE_DURBAR = {
    { "label",           "Shows a bar on each icon that drains with the aura's remaining time.", "(none)", 30 },
    { "checkbox",        "Enable Duration Bar", "defensiveDurationBarEnabled",     30 },
    { "dropdown",        "Position",            "defensiveDurationBarPosition",    55 },
    { "slider",          "Height",              "defensiveDurationBarHeight",      55 },
    { "slider",          "Gap",                 "defensiveDurationBarGap",         55 },
    { "dropdown",        "Color Mode",          "defensiveDurationBarColorMode",   55 },
    { "texturedropdown", "Texture",             "defensiveDurationBarTexture",     55 },
    { "colorpicker",     "Bar Color",           "defensiveDurationBarColor",       30 },
    { "colorpicker",     "Background Color",    "defensiveDurationBarBGColor",     30 },
    { "checkbox",        "Reverse Fill",        "defensiveDurationBarReverseFill", 30 },
}

-- ---- the rows that hoist a tick --------------------------------------
local HOISTED = {
    { builder = "BuildDefensiveSettingsGroup", label = "Settings", boxHeader = "Settings",
      golden = DEFENSIVE_SETTINGS, countVar = "DEFENSIVE_SETTINGS_COUNT", column = "1", hoistedIn = 1,
      row = "settingsRow", band = "contentBand", toggleKey = "defensiveIconEnabled",
      toggleLabel = "Enable Defensive Icon", commit = "OnDefensiveEnableToggle",
      summary = "DefensiveSettingsSummary", apply = "ApplyDefensive" },
    { builder = "BuildDefensiveBorderGroup", label = "Border", boxHeader = "Border",
      golden = DEFENSIVE_BORDER, countVar = "DEFENSIVE_BORDER_COUNT", column = "2", hoistedIn = 0,
      row = "borderRow", band = "iconBand", toggleKey = "defensiveIconShowBorder",
      toggleLabel = "Show Border", commit = "OnDefensiveBorderToggle",
      summary = "DefensiveBorderSummary", apply = "ApplyDefensive" },
    { builder = "BuildDefensiveDurationGroup", label = "Duration Text", boxHeader = "Duration Text",
      golden = DEFENSIVE_DURATION, countVar = "DEFENSIVE_DURATION_COUNT", column = "1", hoistedIn = 1,
      row = "durationRow", band = "textBand", toggleKey = "defensiveIconShowDuration",
      toggleLabel = "Show Duration", commit = "OnDefensiveDurationToggle",
      summary = "DefensiveDurationSummary", apply = "ApplyDefensiveDurationText" },
    { builder = "BuildDefensiveDurationBarGroup", label = "Duration Bar", boxHeader = "Duration Bar",
      golden = DEFENSIVE_DURBAR, countVar = "DEFENSIVE_DURBAR_COUNT", column = "1", hoistedIn = 1,
      row = "durBarRow", band = "factoryBand", toggleKey = "defensiveDurationBarEnabled",
      toggleLabel = "Enable Duration Bar", commit = "OnDefensiveDurationBarToggle",
      summary = "DefensiveDurationBarSummary", apply = "DefBarChanged" },
}

for _, g in ipairs(HOISTED) do
    print("-- Defensive Icon page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())
    checkShared(g.builder, g.label, g.boxHeader, g.column)

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

    check(PAGE:find('tools.RegisterHoistedToggle(' .. g.row .. ', L["' .. g.toggleLabel .. '"], "' .. g.toggleKey .. '", ' .. g.commit .. ')', 1, true) ~= nil,
          g.label .. ": the hoisted toggle keeps its search entry")

    check(PAGE:find("tools.ClaimKeys(" .. g.row .. ", ", 1, true) ~= nil,
          g.label .. ": the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(" .. g.row .. ")", 1, true) ~= nil,
          g.label .. ": ...its amber tick asks about exactly those keys")
    check(PAGE:find("tools.WireFooter(" .. g.row .. ", " .. g.apply .. ")", 1, true) ~= nil,
          g.label .. ": ...and Reset Group / Hold: Defaults push the change into the frames")
end

-- ---- the rows with no tick to hoist ----------------------------------
local WAYIN = {
    { builder = "BuildDefensiveFilterGroup", label = "Defensive Filters",
      boxHeader = "Defensive Filters", golden = DEFENSIVE_FILTERS, column = "2",
      row = "filterRow", band = "contentBand", summary = "DefensiveFilterSummary" },
    { builder = "BuildDefensiveLayoutGroup", label = "Layout", boxHeader = "Layout",
      golden = DEFENSIVE_LAYOUT, countVar = "DEFENSIVE_LAYOUT_COUNT", column = "1",
      row = "layoutRow", band = "iconBand", summary = "DefensiveLayoutSummary",
      apply = "ApplyDefensive" },
    { builder = "BuildDefensiveAppearanceGroup", label = "Appearance", boxHeader = "Appearance",
      golden = DEFENSIVE_APPEARANCE, countVar = "DEFENSIVE_APPEARANCE_COUNT", column = "2",
      row = "appearanceRow", band = "iconBand", summary = "DefensiveAppearanceSummary",
      apply = "ApplyDefensive" },
    { builder = "BuildDefensivePositionGroup", label = "Position", boxHeader = "Position",
      golden = DEFENSIVE_POSITION, countVar = "DEFENSIVE_POSITION_COUNT", column = "1",
      row = "positionRow", band = "iconBand", summary = "DefensivePositionSummary",
      apply = "ApplyDefensive" },
    { builder = "BuildDefensiveStackGroup", label = "Stack Count", boxHeader = "Stack Count",
      golden = DEFENSIVE_STACK, countVar = "DEFENSIVE_STACK_COUNT", column = "1",
      row = "stackRow", band = "textBand", summary = "DefensiveStackSummary",
      apply = "ApplyDefensive" },
}

for _, g in ipairs(WAYIN) do
    print("-- Defensive Icon page: " .. g.label)
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
-- ============================================================
print("-- Defensive Icon page: the declared counts")
do
    local function declared(name) return tonumber(PAGE:match("local " .. name .. "%s*=%s*(%d+)")) end

    eq(declared("DEFENSIVE_SETTINGS_COUNT"), #DEFENSIVE_SETTINGS - 1,
       "counts: Settings is the census less the hoisted Enable tick")
    eq(declared("DEFENSIVE_LAYOUT_COUNT"), #DEFENSIVE_LAYOUT,
       "counts: Layout is the whole census, the growth control counting as the one widget it is")
    eq(declared("DEFENSIVE_APPEARANCE_COUNT"), #DEFENSIVE_APPEARANCE, "counts: Appearance")
    eq(declared("DEFENSIVE_POSITION_COUNT"), #DEFENSIVE_POSITION, "counts: Position")
    eq(declared("DEFENSIVE_DURBAR_COUNT"), #DEFENSIVE_DURBAR - 1,
       "counts: Duration Bar is the census less the hoisted Enable tick")

    -- The two blocks the TextStyle helper expands: font, scale, outline, shadow,
    -- colour, anchor and two offsets.
    local TEXTSTYLE = 8
    eq(declared("DEFENSIVE_STACK_COUNT"), TEXTSTYLE,
       "counts: Stack Count is exactly the TextStyle block's eight")
    -- Duration Text: the census less the hoisted tick and less the TextStyle
    -- placeholder, plus that block's eight, plus the Colors cross-link -- which
    -- is not a GUI:Create call, so the census cannot see it.
    eq(declared("DEFENSIVE_DURATION_COUNT"), (#DEFENSIVE_DURATION - 1 - 1) + TEXTSTYLE + 1,
       "counts: Duration Text -- the format control, the TextStyle block's eight, Color by Time, its cross-link and the permanent-aura tick")
    check(builderBody("BuildDefensiveDurationGroup"):find("AddColorsPageLink(group, parent)", 1, true) ~= nil,
          "counts: ...and that cross-link really is mounted into the group")

    -- ☠ THE COMPOSITE COUNT, DERIVED FROM THE HELPER RATHER THAN ASSERTED AT IT.
    -- CreateBorderControls builds a fixed set plus one widget per include key.
    -- This page's include set is the Buff Bar's plus the two colour resolvers,
    -- which between them add ONE widget: the Colour Source dropdown.
    local BORDER_BASE = 4          -- Show Border, thickness, style, texture
    local BORDER_COLOR = 1         -- the static colour picker
    local BORDER_GRADIENT = 3      -- start, end, direction
    local BORDER_SOURCE = 1        -- the Colour Source dropdown (class/role opted in)
    local BORDER_SHADOW = 5        -- the block's tick plus colour, size, two offsets
    local BORDER_ALPHA, BORDER_INSET, BORDER_BLEND = 1, 1, 1
    local BORDER_OFFSET = 2
    local borderAll = BORDER_BASE + BORDER_COLOR + BORDER_GRADIENT + BORDER_SOURCE
                    + BORDER_SHADOW + BORDER_ALPHA + BORDER_INSET + BORDER_BLEND
                    + BORDER_OFFSET
    eq(borderAll, 19, "counts: the border toolkit builds nineteen for this include set")
    eq(declared("DEFENSIVE_BORDER_COUNT"), borderAll - 1,
       "counts: Border is those nineteen less the hoisted Show Border")

    -- ⚠ NO ANIMATION HERE, and that is the difference from the Missing Buffs
    -- border: 12.1 forbids driving a container button's border while auras are
    -- secret, so the include set does not ask for it.
    local body = builderBody("BuildDefensiveBorderGroup")
    check(body:find("animate = true", 1, true) == nil,
          "counts: ...and the include set does not ask for animation on this page")
    for _, k in ipairs({ "inset", "offset", "blendMode", "gradient", "shadow",
                         "alpha", "classColor", "roleColor" }) do
        check(body:find(k .. " = true", 1, true) ~= nil,
              "counts: ...the include set still asks for " .. k)
    end

    -- The filter row's count is the one that is DATA rather than a constant.
    check(PAGE:find("local function DefensiveFilterCount()", 1, true) ~= nil,
          "counts: Defensive Filters counts its own rows instead of declaring a literal")
    check(PAGE:find("return 3 + #R.Categories + customs", 1, true) ~= nil,
          "counts: ...the three fixed widgets plus one per category and per custom filter")
    check(rowOpts("Defensive Filters"):find("count%s*=%s*DefensiveFilterCount()") ~= nil,
          "counts: ...and the row is handed that count, not a number")
end

-- ============================================================
-- 6. THE CLAIMS, AND THE ONE FOOTER THIS PAGE REFUSES
-- ============================================================
print("-- Defensive Icon page: the claims and the footer refusal")
do
    -- ⚠ TWO KEYS THE WALK CANNOT SEE, both named through `extra`.
    check(PAGE:find('tools.ClaimKeys(filterRow, filterContent, { "defensiveFilterSelection" })', 1, true) ~= nil,
          "claims: the filter row names the selection table -- every tick behind it is a custom get/set with no db binding")
    check(PAGE:find('tools.ClaimKeys(layoutRow, layoutContent, { "defensiveBarGrowth" })', 1, true) ~= nil,
          "claims: the layout row names defensiveBarGrowth -- the growth control registers nothing with search")

    -- ☠ NO FOOTER ON THE FILTER ROW. Reset Group writes DeepCopy(default) into
    -- the key, which for defensiveFilterSelection REPLACES the table -- and the
    -- aura pipeline holds references to that table and its inner tables. The
    -- Debuff Bar's filter row DOES take one, because every key behind that group
    -- is a scalar.
    check(PAGE:find("tools.WireFooter(filterRow", 1, true) == nil,
          "footer: the Defensive Filters row has no footer, because a reset would strand the pipeline's references")
    check(PAGE:find("tools.WireModifiedTick(filterRow)", 1, true) ~= nil,
          "footer: ...but it keeps the amber tick, which only reads")

    -- Every other converted row has one.
    for _, row in ipairs({ "settingsRow", "layoutRow", "appearanceRow", "positionRow",
                           "borderRow", "durationRow", "stackRow", "durBarRow" }) do
        check(PAGE:find("tools.WireFooter(" .. row, 1, true) ~= nil,
              "footer: " .. row .. " carries Reset Group / Hold: Defaults")
    end
end

-- ============================================================
-- 7. THE HIDDEN ROWS, THE BANDS AND THE PAGE'S OWN ORDER
-- ============================================================
print("-- Defensive Icon page: the hidden rows, the bands and the order")
do
    -- ---- the two rows that can hide entirely -------------------------
    check(PAGE:find("local function NoFactoryRow(d) return not DF:FactoryOwnsDefensiveRow(d) end", 1, true) ~= nil,
          "hidden rows: the two 12.1-only groups share one predicate, named for what it asks")
    check(PAGE:find("stackRow.hideOn = NoFactoryRow", 1, true) ~= nil,
          "hidden rows: the Stack Count row carries the box's own factory gate")
    check(PAGE:find("durBarRow.hideOn = NoFactoryRow", 1, true) ~= nil,
          "hidden rows: ...and so does the Duration Bar row")
    check(PAGE:find("defStackGroup.hideOn = NoFactoryRow", 1, true) ~= nil
      and PAGE:find("durBarGroup.hideOn = NoFactoryRow", 1, true) ~= nil,
          "hidden rows: ...and classic still puts it on the boxes")

    -- ---- nine bare 280 boxes left, all inside a classicLayout arm ----
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 9, "boxes: nine bare 280 boxes left, and they are the classic branch's own")
    check(PAGE:find("280, tools", 1, true) == nil,
          "boxes: no stay-inline 280 box is left on the page")
    check(PAGE:find("bandStyle", 1, true) == nil,
          "boxes: the band skin is never restated as a literal (this page needs none)")
    check(PAGE:find("GUI:CreateControlRow", 1, true) == nil,
          "boxes: no control row -- every group on this page has more than one setting")

    -- ---- classic's Add order is the order it always had ---------------
    -- Within a column the Add() order IS the layout order, so this is what makes
    -- "classic is unchanged" structural rather than a promise.
    local order = { "settingsGroup", "layoutGroup", "appearanceGroup", "positionGroup",
                    "borderGroup", "filterGroup", "durationGroup", "defStackGroup",
                    "durBarGroup" }
    local prev = 0
    for _, name in ipairs(order) do
        local at = PAGE:find("Add(" .. name .. ", nil,", 1, true)
        check(at ~= nil and at > prev, "order: classic adds " .. name .. " in its original place")
        prev = at or prev
    end

    -- ---- the Add order of the bands ------------------------------------
    local a = PAGE:find('Add(contentBand, nil, "both")', 1, true)
    local b = PAGE:find('Add(iconBand, nil, "both")', 1, true)
    local c = PAGE:find('Add(textBand, nil, "both")', 1, true)
    local d = PAGE:find('Add(factoryBand, nil, "both")', 1, true)
    check(a and b and c and d and a < b and b < c and c < d,
          "order: the four bands span both columns, in reading order")

    -- ---- the page's own furniture is untouched -------------------------
    check(PAGE:find('CreateCopyButton(self.child, {"defensiveIcon", "defensiveFilterSelection", "defensiveSortOrder", "defensiveDurationBar", "defensiveBar"}', 1, true) ~= nil,
          "page: the copy button keeps the five prefixes it owns")
    check(PAGE:find('{pageId = "auras_filterdesigner", label = L["Filter Designer"]}', 1, true) ~= nil,
          "page: ...and the See Also block is unchanged")
end
