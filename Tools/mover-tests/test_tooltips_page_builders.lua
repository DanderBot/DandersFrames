local NS = ...

-- ============================================================
-- TOOLTIPS PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Options.lua
-- ------------------------------------------------------------
-- Display > Tooltips is the widest page in the sweep so far: SEVEN groups, six
-- of which become feature rows in two bands and one of which -- a lone checkbox
-- -- becomes a CONTROL ROW in a third band, the same plate carrying the setting
-- itself instead of a way in to fifteen of them.
--
--   "Unit Frame" band   Frame Tooltips, Binding Tooltips (hoisted enables)
--   "Auras" band        Buff, Debuff, Defensive Icon (hoisted enables) and
--                       Aura Designer Tooltips (NO tick -- three independent
--                       surfaces, so there is no single boolean to hoist)
--   headerless band     Resurrection Icon Tooltips, as a control row
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db -- so this file
-- does what test_frame_page_builders / test_sorting_page_builders do: it reads
-- the page's SOURCE and asserts against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each extracted builder -- kind, L key, db key and
--     slot height, in order -- taken from the PRE-CHANGE source, so a builder
--     that quietly dropped a control or renamed a key fails here. This is also
--     the evidence that CLASSIC RENDERS AS IT DID: the classic branch mounts the
--     same builder into the same 280 box in the same column.
--   ✓ that ONE builder serves both layouts.
--   ✓ that each declared row COUNT matches what its pane mounts, less the
--     hoisted toggle.
--   ✓ that the Anchor To dropdowns stopped rebuilding the page FROM INSIDE A
--     PANE, while classic still does exactly what it always did.
--   ✗ nothing about runtime behaviour -- the callbacks, the greying and the
--     summaries are read by eye and by the in-game checklist.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Options.lua")

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

-- The page, scoped by its own two ends: Options.lua holds a dozen pages, and a
-- bare 280 box on one of the others is not this pass's business.
local PAGE
do
    local a = SRC:find('Add(CreateCopyButton(self.child, {"tooltip"}, L["Tooltips"], "display_tooltips")', 1, true)
    local b = SRC:find('{pageId = "auras_auradesigner", label = L["Aura Designer"]}', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Tooltips page builder is locatable by its own ends")
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
local function checkShared(builder, rowLabel, column)
    -- ONE builder, BOTH layouts: the declaration and the two mounts.
    local calls = 0
    for _ in PAGE:gmatch(builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, rowLabel .. ": declared once, mounted twice -- classic box and popout pane")

    -- The classic branch builds the box it always did, with its own header, in
    -- the column it always had.
    local esc = rowLabel:gsub("%p", "%%%0")
    local box = PAGE:match("local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)\n%s*%1:AddWidget%(GUI:CreateHeader%(self%.child, L%[\"" .. esc .. "\"%]%)")
    check(box ~= nil, rowLabel .. ": the classic 280 box is built with its own header")
    if box then
        check(PAGE:find("Add(" .. box .. ", nil, " .. column .. ")", 1, true) ~= nil,
              rowLabel .. ": ...and still goes to column " .. column)
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
-- 1. THE PAGE TAKES THE SHARED MACHINERY, AND ITS SHARED VOCABULARY MOVED UP
-- ============================================================
print("-- Tooltips page: the shared popout machinery and the page-scope vocabulary")
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

    -- ---- the two bands -----------------------------------------------
    check(PAGE:find("frameBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
          "bands: the Unit Frame band is chromeless, at the width the layout pass will give it")
    check(PAGE:find("auraBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
          "bands: ...and so is the Auras band")
    -- Both hold more than one row, so both name their SECTION. Neither header is
    -- a new locale string.
    check(PAGE:find('frameBand:AddWidget(GUI:CreateHeader(self.child, L["Unit Frame"]), 40)', 1, true) ~= nil,
          "bands: the hover band names itself with the word its own Anchor To dropdowns use")
    check(PAGE:find('auraBand:AddWidget(GUI:CreateHeader(self.child, L["Auras"]), 40)', 1, true) ~= nil,
          "bands: ...and the icon band with the one the locale already ships")

    -- ---- the five Anchor To value lists, at PAGE scope ----------------
    -- The rows print the chosen anchor as their summary, and the summary is
    -- built outside the group's builder -- so the word for FRAME has to come out
    -- of the same table the dropdown offers, or a row could say "Unit Frame"
    -- while the control under it says "Buff Icon".
    for _, pair in ipairs({
        { "frameAnchorValues",  "Unit Frame" },
        { "bindAnchorValues",   "Unit Frame" },
        { "buffAnchorValues",   "Buff Icon" },
        { "debuffAnchorValues", "Debuff Icon" },
        { "defAnchorValues",    "Defensive Icon" },
    }) do
        local decl = PAGE:match("local " .. pair[1] .. " = {(.-)}")
        check(decl ~= nil, "vocab: " .. pair[1] .. " is declared at page scope")
        if decl then
            check(decl:find('FRAME = L["' .. pair[2] .. '"]', 1, true) ~= nil,
                  "vocab: ..." .. pair[1] .. " names the frame case " .. pair[2])
            check(decl:find('DEFAULT = L["Game Default"]', 1, true) ~= nil
              and decl:find('CURSOR = L["Cursor"]', 1, true) ~= nil,
                  "vocab: ...with the two shared cases unchanged")
        end
        -- ...and NOT re-declared inside a builder, which is where they used to be.
        local decls = 0
        for _ in PAGE:gmatch("local " .. pair[1] .. " = {") do decls = decls + 1 end
        eq(decls, 1, "vocab: " .. pair[1] .. " is declared exactly once")
    end

    -- ---- RefreshAuraTooltips, above every builder that closes over it --
    -- ☠ A closure captures the upvalue that exists when it is CREATED, so a
    -- builder declared above this line would see nil instead of the function.
    local refreshAt = PAGE:find("local RefreshAuraTooltips = function()", 1, true)
    check(refreshAt ~= nil, "vocab: RefreshAuraTooltips is declared at page scope")
    for _, b in ipairs({ "BuildBuffTooltipGroup", "BuildDebuffTooltipGroup",
                         "BuildDefTooltipGroup", "BuildADTooltipGroup" }) do
        local at = PAGE:find("local function " .. b .. "(tools2)", 1, true)
        check(at ~= nil and refreshAt ~= nil and refreshAt < at,
              "vocab: ..." .. b .. " is declared after it, so it closes over the real function")
    end
    local refreshDecls = 0
    for _ in PAGE:gmatch("local RefreshAuraTooltips = function%(%)") do refreshDecls = refreshDecls + 1 end
    eq(refreshDecls, 1, "vocab: ...and there is exactly one of it")
end

-- ============================================================
-- 2. THE ANCHOR GATE -- classic still rebuilds, the pane must not
-- Picking an Anchor To re-gates the three controls under it. Classic has always
-- paid for that with a page REBUILD and still does. A rebuild inside a pane
-- retires the row the user is clicking through and the helper's prologue closes
-- the panel on the way in, so the pane runs the state passes instead -- which is
-- what the rebuild was buying.
-- ============================================================
print("-- Tooltips page: the Anchor To gate")
do
    local gate = PAGE:match("local function AnchorGateRefresh%(tools2%)(.-)\n        end")
    check(gate ~= nil, "anchor gate: the page decides this once, in a named function")
    if gate then
        check(gate:find("if tools2.popout then", 1, true) ~= nil,
              "anchor gate: ...branching on which layout the group was built for")
        check(gate:find("tools2.refreshStates()", 1, true) ~= nil,
              "anchor gate: ...the pane re-runs the state passes")
        check(gate:find("GUI:RefreshCurrentPage()", 1, true) ~= nil,
              "anchor gate: ...and classic still rebuilds, exactly as it always did")
    end

    -- No builder rebuilds the page directly any more, and every popout mount
    -- declares itself as one.
    for _, b in ipairs({ "BuildFrameTooltipGroup", "BuildBindTooltipGroup",
                         "BuildBuffTooltipGroup", "BuildDebuffTooltipGroup",
                         "BuildDefTooltipGroup", "BuildADTooltipGroup" }) do
        local body = builderBody(b)
        check(body:find("GUI:RefreshCurrentPage", 1, true) == nil,
              "anchor gate: " .. b .. " never rebuilds the page from inside itself")
    end
    local popouts = 0
    for _ in PAGE:gmatch("popout = true,") do popouts = popouts + 1 end
    eq(popouts, 6, "anchor gate: all six popout mounts declare themselves as panes")
end

-- ============================================================
-- 3. THE TWO SUMMARY SHAPES
-- Both reuse words the locale already ships -- the anchor words come out of the
-- dropdowns' own tables, "Combat" is the word the Frame Fade row already prints,
-- and the visibility words are the five-way vocabulary those dropdowns offer.
-- ZERO new locale strings on this page.
-- ============================================================
print("-- Tooltips page: the summaries")
do
    local hover = PAGE:match("local function HoverTipSummary%(anchorValues, anchorKey, combatKey%)(.-)\n        end")
    check(hover ~= nil, "summary: the hover shape is a named factory on the page")
    if hover then
        check(hover:find("anchorValues[d[anchorKey]]", 1, true) ~= nil,
              "summary: ...the anchor word comes from the dropdown's own table")
        check(hover:find('combat ~= "SHOW"', 1, true) ~= nil,
              "summary: ...the in-combat pick is named only when it is not the plain Always")
        check(hover:find('L%["Combat"%]') ~= nil,
              "summary: ...labelled with the word the Frame Fade row already uses")
        check(hover:find("VIS_VALUES[combat]", 1, true) ~= nil,
              "summary: ...and spelled with the dropdown's own five-way vocabulary")
        check(hover:find("\\194\\183", 1, true) ~= nil,
              "summary: ...separated by the convention's dot")
        local items = 0
        for _ in hover:gmatch("parts%[#parts %+ 1%]") do items = items + 1 end
        check(items <= 4, "summary: at most four items, per the summary convention")
    end

    local aura = PAGE:match("local function AuraTipSummary%(anchorValues, anchorKey, combatKey%)(.-)\n        end")
    check(aura ~= nil, "summary: the aura shape is a named factory on the page")
    if aura then
        check(aura:find("anchorValues[d[anchorKey]]", 1, true) ~= nil,
              "summary: ...the anchor word comes from the dropdown's own table here too")
        -- The aura groups gate combat with a CHECKBOX rather than a five-way
        -- pick, and it reports through the same words the hover rows use for the
        -- same meaning.
        check(aura:find('L%["Combat"%]') ~= nil and aura:find('L%["Never"%]') ~= nil,
              "summary: ...and Disable in Combat says what the hover rows say for it")
        local items = 0
        for _ in aura:gmatch("parts%[#parts %+ 1%]") do items = items + 1 end
        check(items <= 4, "summary: at most four items here too")
    end
end

-- ============================================================
-- 4. THE FIVE HOISTED-TOGGLE ROWS
-- Each group's enable is the textbook hoist: keepEnabled + disableChildrenOn in
-- classic, which is the shape of "am I doing anything at all".
-- ============================================================
local FRAME_TOOLTIP = {
    { "checkbox", "Enable Frame Tooltips", "tooltipFrameEnabled",       30 },
    { "dropdown", "Show Out of Combat",    "tooltipFrameOutOfCombat",   55 },
    { "dropdown", "Show In Combat",        "tooltipFrameCombat",        55 },
    { "dropdown", "Anchor To",             "tooltipFrameAnchor",        55 },
    { "dropdown", "Anchor",                "tooltipFrameAnchorPos",     55 },
    { "slider",   "Offset X",              "tooltipFrameX",             55 },
    { "slider",   "Offset Y",              "tooltipFrameY",             55 },
}
local BIND_TOOLTIP = {
    { "checkbox", "Enable Binding Tooltips", "tooltipBindingEnabled",     30 },
    { "dropdown", "Show Out of Combat",      "tooltipBindingOutOfCombat", 55 },
    { "dropdown", "Show In Combat",          "tooltipBindingCombat",      55 },
    { "dropdown", "Anchor To",               "tooltipBindingAnchor",      55 },
    { "dropdown", "Anchor",                  "tooltipBindingAnchorPos",   55 },
    { "slider",   "Offset X",                "tooltipBindingX",           55 },
    { "slider",   "Offset Y",                "tooltipBindingY",           55 },
}
local BUFF_TOOLTIP = {
    { "checkbox", "Enable Buff Tooltips", "tooltipBuffEnabled",           30 },
    { "checkbox", "Disable in Combat",    "tooltipBuffDisableInCombat",   30 },
    { "dropdown", "Anchor To",            "tooltipBuffAnchor",            55 },
    { "dropdown", "Anchor",               "tooltipBuffAnchorPos",         55 },
    { "slider",   "Offset X",             "tooltipBuffX",                 55 },
    { "slider",   "Offset Y",             "tooltipBuffY",                 55 },
}
local DEBUFF_TOOLTIP = {
    { "checkbox", "Enable Debuff Tooltips", "tooltipDebuffEnabled",         30 },
    { "checkbox", "Disable in Combat",      "tooltipDebuffDisableInCombat", 30 },
    { "dropdown", "Anchor To",              "tooltipDebuffAnchor",          55 },
    { "dropdown", "Anchor",                 "tooltipDebuffAnchorPos",       55 },
    { "slider",   "Offset X",               "tooltipDebuffX",               55 },
    { "slider",   "Offset Y",               "tooltipDebuffY",               55 },
}
local DEF_TOOLTIP = {
    { "checkbox", "Enable Defensive Icon Tooltips", "tooltipDefensiveEnabled",         30 },
    { "checkbox", "Disable in Combat",              "tooltipDefensiveDisableInCombat", 30 },
    { "dropdown", "Anchor To",                      "tooltipDefensiveAnchor",          55 },
    { "dropdown", "Anchor",                         "tooltipDefensiveAnchorPos",       55 },
    { "slider",   "Offset X",                       "tooltipDefensiveX",               55 },
    { "slider",   "Offset Y",                       "tooltipDefensiveY",               55 },
}

local HOISTED = {
    { builder = "BuildFrameTooltipGroup",  label = "Frame Tooltips",
      golden = FRAME_TOOLTIP,  countVar = "FRAME_TOOLTIP_COUNT",  column = "1",
      row = "frameRow",  toggleKey = "tooltipFrameEnabled",
      toggleLabel = "Enable Frame Tooltips",  commit = "OnFrameTipToggle",
      band = "frameBand", summary = "HoverTipSummary", apply = nil },
    { builder = "BuildBindTooltipGroup",   label = "Binding Tooltips",
      golden = BIND_TOOLTIP,   countVar = "BIND_TOOLTIP_COUNT",   column = "2",
      row = "bindRow",   toggleKey = "tooltipBindingEnabled",
      toggleLabel = "Enable Binding Tooltips", commit = "OnBindTipToggle",
      band = "frameBand", summary = "HoverTipSummary", apply = nil },
    { builder = "BuildBuffTooltipGroup",   label = "Buff Tooltips",
      golden = BUFF_TOOLTIP,   countVar = "BUFF_TOOLTIP_COUNT",   column = "1",
      row = "buffRow",   toggleKey = "tooltipBuffEnabled",
      toggleLabel = "Enable Buff Tooltips",  commit = "OnBuffTipToggle",
      band = "auraBand",  summary = "AuraTipSummary", apply = "RefreshAuraTooltips" },
    { builder = "BuildDebuffTooltipGroup", label = "Debuff Tooltips",
      golden = DEBUFF_TOOLTIP, countVar = "DEBUFF_TOOLTIP_COUNT", column = "2",
      row = "debuffRow", toggleKey = "tooltipDebuffEnabled",
      toggleLabel = "Enable Debuff Tooltips", commit = "OnDebuffTipToggle",
      band = "auraBand",  summary = "AuraTipSummary", apply = "RefreshAuraTooltips" },
    { builder = "BuildDefTooltipGroup",    label = "Defensive Icon Tooltips",
      golden = DEF_TOOLTIP,    countVar = "DEF_TOOLTIP_COUNT",    column = "1",
      row = "defRow",    toggleKey = "tooltipDefensiveEnabled",
      toggleLabel = "Enable Defensive Icon Tooltips", commit = "OnDefTipToggle",
      band = "auraBand",  summary = "AuraTipSummary", apply = "RefreshAuraTooltips" },
}

for _, g in ipairs(HOISTED) do
    print("-- Tooltips page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())
    checkShared(g.builder, g.label, g.column)

    -- The hoist, and the arithmetic it implies: the checkbox is still IN the
    -- builder -- classic needs it -- behind the one flag the popout passes.
    check(body:find("if not tools2.hoistToggle then", 1, true) ~= nil,
          g.label .. ": the enable checkbox is skipped when the row has hoisted it")
    check(body:find(".keepEnabled = true", 1, true) ~= nil,
          g.label .. ": ...and in classic it stays live under the group's own grey")
    local declared = tonumber(PAGE:match("local " .. g.countVar .. "%s*=%s*(%d+)"))
    check(declared ~= nil, g.label .. ": the page declares the row's count in one place")
    eq(declared, #g.golden - 1, g.label .. ": ...the census less the hoisted tick")

    -- ☠ THE GROUP GATE MOVED INSIDE THE BUILDER. In classic it was a property of
    -- the page-level box; left there, the pane would not grey while the group is
    -- off and the two layouts would disagree.
    check(body:find("group.disableChildrenOn = function(d) return not d." .. g.toggleKey .. " end", 1, true) ~= nil,
          g.label .. ": the group's grey-while-off gate is inside the builder")

    local opts = rowOpts(g.label)
    check(opts:find('toggle%s*=%s*{%s*key%s*=%s*"' .. g.toggleKey .. '"%s*}') ~= nil,
          g.label .. ": the row's tick is the group's own enable key")
    check(opts:find("summary%s*=%s*" .. g.summary .. "%(") ~= nil,
          g.label .. ": ...it declares a summary of the right shape")
    check(opts:find("count%s*=%s*" .. g.countVar) ~= nil,
          g.label .. ": ...and the declared count, not a literal")
    check(opts:find("onToggle%s*=%s*" .. g.commit) ~= nil,
          g.label .. ": ...and a commit that is not a page rebuild")
    check(opts:find("offText", 1, true) == nil,
          g.label .. ": no offText -- off here really does mean no tooltip")

    -- ...into the right band.
    check(PAGE:find("local " .. g.row .. " = " .. g.band .. ":AddWidget(GUI:CreatePopoutRow(", 1, true) ~= nil,
          g.label .. ": the row is mounted into the " .. g.band)

    -- ☠ THE COMMIT IS NOT A PAGE REBUILD, for the reason the anchor gate is not.
    local commit = PAGE:match("local function " .. g.commit .. "%(%)(.-)\n            end")
    check(commit ~= nil, g.label .. ": the popout commit is a named function")
    if commit then
        check(commit:find("RefreshCurrentPage", 1, true) == nil,
              g.label .. ": ...and never rebuilds the page")
        check(commit:find("self:RefreshStates()", 1, true) ~= nil,
              g.label .. ": ...it re-runs the state passes instead")
        check(commit:find("tools.ReflowMounted()", 1, true) ~= nil,
              g.label .. ": ...and reflows the open panes")
        if g.apply then
            check(commit:find(g.apply .. "()", 1, true) ~= nil,
                  g.label .. ": ...having first run what the suppressed checkbox ran")
        end
    end

    -- The hoisted toggle keeps its search entry under the SAME label and key the
    -- suppressed checkbox carried, or the setting becomes unfindable in the
    -- popout layout while staying findable in classic.
    check(PAGE:find('tools.RegisterHoistedToggle(' .. g.row .. ', L["' .. g.toggleLabel .. '"], "' .. g.toggleKey .. '", ' .. g.commit .. ')', 1, true) ~= nil,
          g.label .. ": the hoisted toggle keeps its search entry")

    -- The strip. Every key here is a per-mode profile key the defaults engine
    -- answers for, so all five rows get the amber tick and the footer.
    check(PAGE:find("tools.ClaimKeys(" .. g.row .. ", ", 1, true) ~= nil,
          g.label .. ": the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(" .. g.row .. ")", 1, true) ~= nil,
          g.label .. ": ...its amber tick asks about exactly those keys")
    if g.apply then
        check(PAGE:find("tools.WireFooter(" .. g.row .. ", " .. g.apply .. ")", 1, true) ~= nil,
              g.label .. ": ...and Reset Group / Hold: Defaults push the change into the aura buttons")
    else
        -- ⚠ A FOOTER WITH NO APPLY, and it is the honest answer rather than a
        -- gap: every control in these two groups is read at HOVER time, which is
        -- why all six of their own callbacks are empty.
        check(PAGE:find("tools.WireFooter(" .. g.row .. ")", 1, true) ~= nil,
              g.label .. ": ...and a footer with no apply, because nothing needs pushing")
    end
end

-- ============================================================
-- 5. AURA DESIGNER TOOLTIPS -- a row with no tick
-- Three INDEPENDENT surfaces. Hoisting one would claim it speaks for all three
-- (the Color Picker row's precedent), and inventing a fourth key to gate them is
-- a migration for a row's ornament -- so the row is a way in and nothing else.
-- ============================================================
local AD_TOOLTIP = {
    { "checkbox", "Groups",     "tooltipADGroupsEnabled",     30 },
    { "checkbox", "Indicators", "tooltipADIndicatorsEnabled", 30 },
    { "checkbox", "Bars",       "tooltipADBarsEnabled",       30 },
}

print("-- Tooltips page: Aura Designer Tooltips")
do
    local body = builderBody("BuildADTooltipGroup")
    checkCensus(census(body), AD_TOOLTIP, "aura designer tooltips")
    checkShared("BuildADTooltipGroup", "Aura Designer Tooltips", "2")

    -- No hoist and no group gate: there is no boolean here that means "am I
    -- doing anything at all".
    check(body:find("hoistToggle", 1, true) == nil,
          "aura designer tooltips: the builder has no hoist branch, because there is nothing to hoist")
    check(body:find("disableChildrenOn", 1, true) == nil,
          "aura designer tooltips: ...and no group gate, because no key gates the other two")

    local declared = tonumber(PAGE:match("local AD_TOOLTIP_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "aura designer tooltips: the page declares the row's count in one place")
    eq(declared, #AD_TOOLTIP, "aura designer tooltips: ...the whole census, nothing hoisted out of it")

    local opts = rowOpts("Aura Designer Tooltips")
    check(opts:find("toggle", 1, true) == nil,
          "aura designer tooltips: the row declares no toggle -- three independent ticks have no single on/off")
    check(opts:find("onToggle", 1, true) == nil,
          "aura designer tooltips: ...and so no commit either")
    check(opts:find("summary%s*=%s*ADTooltipSummary") ~= nil,
          "aura designer tooltips: ...it does declare a summary")
    check(opts:find("count%s*=%s*AD_TOOLTIP_COUNT") ~= nil,
          "aura designer tooltips: ...and the declared count, not a literal")
    check(PAGE:find("local adRow = auraBand:AddWidget(GUI:CreatePopoutRow(", 1, true) ~= nil,
          "aura designer tooltips: the row is mounted into the Auras band")

    -- The tick and the footer still apply: all three keys are ordinary per-mode
    -- profile keys, which is what the defaults engine answers for.
    check(PAGE:find("tools.ClaimKeys(adRow, adContent)", 1, true) ~= nil,
          "aura designer tooltips: the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(adRow)", 1, true) ~= nil,
          "aura designer tooltips: ...its amber tick asks about exactly those keys")
    check(PAGE:find("tools.WireFooter(adRow, RefreshAuraTooltips)", 1, true) ~= nil,
          "aura designer tooltips: ...and its footer pushes the change into the aura buttons")

    -- The summary names the surfaces that are on, in the checkboxes' own words.
    local sum = PAGE:match("local function ADTooltipSummary%(d%)(.-)\n            end")
    check(sum ~= nil, "aura designer tooltips: the summary is a named function on the page")
    if sum then
        for _, k in ipairs({ "Groups", "Indicators", "Bars" }) do
            check(sum:find('L%["' .. k .. '"%]') ~= nil,
                  "aura designer tooltips: ..." .. k .. " comes from the locale, not a literal")
        end
        check(sum:find("\\194\\183", 1, true) ~= nil,
              "aura designer tooltips: ...separated by the convention's dot")
    end
end

-- ============================================================
-- 6. THE CONTROL ROW, THE BANDS AND THE PAGE'S OWN ORDER
-- ============================================================
print("-- Tooltips page: the control row, the bands and the order")
do
    -- ---- the one single-option group: a CONTROL ROW in a band of its own ----
    -- Still not a popout row -- a pane holding one checkbox is a click that buys
    -- nothing -- but no longer a 280 box beside two full-width bands either. The
    -- checkbox wears the row plate, in a chromeless band at the same width.
    check(PAGE:find('label%s*=%s*L%["Resurrection Icon Tooltips"%],\n%s*kind%s*=%s*"checkbox"') ~= nil,
          "control row: Resurrection Icon Tooltips is a checkbox control row")
    check(PAGE:find("resBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
          "control row: ...in a chromeless band at the width the layout pass will give it")
    check(PAGE:find("resBand:AddWidget(GUI:CreateControlRow(", 1, true) ~= nil,
          "control row: ...mounted into that band")
    -- ⚠ NO HEIGHT PASSED. The factory owns the slot (fixedRowHeight plus the
    -- popout row's own preferredHeight), which is what makes a control row and a
    -- feature row share one rhythm.
    check(PAGE:find("})), 30)", 1, true) == nil,
          "control row: ...with no call-site slot height, because the factory owns it")
    -- ONE label, and it is the group's own title -- the tick beside it already
    -- says "enable", and this is the vocabulary the rows above are named in.
    check(PAGE:find('GUI:CreateControlRow(self.child, {\n                label = L["Resurrection Icon Tooltips"]', 1, true) ~= nil,
          "control row: ...named with the box's own title, not the tick's caption")
    check(PAGE:find('tools.RegisterControlRow(resRow, "checkbox", "tooltipResurrectionEnabled")', 1, true) ~= nil,
          "control row: ...and registered with search through the shared verb")
    -- The classic arm still builds the box it always built, tick caption and all.
    check(PAGE:find('local resTooltipGroup = GUI:CreateSettingsGroup(self.child, 280)\n            resTooltipGroup:AddWidget(GUI:CreateHeader(self.child, L["Resurrection Icon Tooltips"]), 40)', 1, true) ~= nil,
          "control row: classic still builds the bare 280 box with its own header")
    check(PAGE:find('GUI:CreateCheckbox(self.child, L["Enable Resurrection Icon Tooltips"], db, "tooltipResurrectionEnabled", nil)', 1, true) ~= nil,
          "control row: ...and the tick it always had, unchanged")
    -- ⚠ NOTHING IS LEFT MOUNTED AT A COLUMN'S 280 BESIDE THE BANDS.
    check(PAGE:find("280, tools and tools.INLINE_BOX or nil", 1, true) == nil,
          "control row: no stay-inline 280 box is left on the page")
    -- ⚠ THE FLAG IS NEVER WRITTEN AS A LITERAL, wherever the skin is still used.
    check(PAGE:find("bandStyle", 1, true) == nil,
          "inline: the skin is taken from the tools, never restated as a literal")

    -- ---- seven bare 280 boxes left, all inside a classicLayout arm -----
    -- Seven rather than six: the Resurrection box moved out of the shared
    -- construction and into the classic arm, where it is bare like the rest.
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 7, "boxes: seven bare 280 boxes left, and they are the classic branch's own")

    -- ---- the Add order ------------------------------------------------
    -- Three full-width bands in reading order. With nothing left in a column
    -- there is no flow to unbalance, so this is purely the order the page reads
    -- in -- the sync-point hole the old note was about cannot arise.
    local a = PAGE:find('Add(frameBand, nil, "both")', 1, true)
    local b = PAGE:find('Add(auraBand, nil, "both")', 1, true)
    local c = PAGE:find('Add(resBand, nil, "both")', 1, true)
    check(a ~= nil and b ~= nil and a < b,
          "order: the two bands span both columns, hover band first")
    check(c ~= nil and b ~= nil and b < c,
          "order: ...and the Resurrection band spans them too, last of the three")
    -- Classic still adds its box at its own slot, in column 2.
    check(PAGE:find("Add(resTooltipGroup, nil, 2)", 1, true) ~= nil,
          "order: classic adds the Resurrection box at its own slot, column 2")
    local col2 = 0
    for _ in PAGE:gmatch("Add%(resTooltipGroup, nil, 2%)") do col2 = col2 + 1 end
    eq(col2, 1, "order: ...exactly once, because only classic builds it")

    -- ---- the page's own furniture is untouched -------------------------
    check(PAGE:find("AddSyncPoint()", 1, true) ~= nil,
          "page: the sync point before See Also survives")
    check(PAGE:find('{pageId = "auras_buffs", label = L["Buff Bar"]}', 1, true) ~= nil,
          "page: ...and the See Also block is unchanged")
end
