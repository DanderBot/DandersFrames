local NS = ...

-- ============================================================
-- HIGHLIGHTS PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Modules.lua
-- ------------------------------------------------------------
-- Indicators > Highlights is the second page in the Modules file to convert, and
-- the first anywhere whose COLLAPSIBLE SECTIONS become the bands. FOUR groups
-- inside three sections, and all four become feature rows:
--
--   "Selection Highlight" band  Selection Settings
--   "Hover Highlight" band      Hover Settings
--   "Aggro Highlight" band      Aggro Settings and Threat Colors
--
-- ☠ THE SECTIONS BECOME BANDS RATHER THAN SURVIVING AS SECTIONS. A collapsible
-- section is KEPT where it holds several boxes worth folding away together (the
-- Health Bar precedent, and the Icons page's, whose section headers also draw a
-- live preview). Here each one wraps a single group -- and a row IS a fold, so
-- keeping the section would put a fold inside a fold with one thing in it. Every
-- band header is the locale string the section already used, so the page adds no
-- new strings and the classic layout keeps all three sections untouched.
--
-- ☠ AND NOTHING ON THIS PAGE HOISTS A TICK, which is a verdict rather than an
-- omission. Each highlight's master control is its MODE -- a dropdown whose
-- "Hidden" entry is the off switch -- not a boolean. Threat Colors' "Use Custom
-- Colors" looks like a candidate and is not one: with it off the group still
-- does something (the game's own threat palette), so it is a MODE rather than an
-- enable, and a hoisted tick would have printed "Off" over a group that was
-- still colouring frames. Left in the pane it also rides that row's Reset Group,
-- which a hoisted tick never does. There is no page-wide gate here either: three
-- independent features, so no row greys another.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db -- so this file
-- does what the other census files do: it reads the page's SOURCE and asserts
-- against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each extracted builder -- kind, L key, db key and
--     slot height, in order -- taken from the PRE-CHANGE source, so a builder
--     that quietly dropped a control or renamed a key fails here. This is also
--     the evidence that CLASSIC RENDERS AS IT DID: the classic branch mounts the
--     same builder into the same 280 box, in the same section, in the same
--     column.
--   ✓ the wiring every row must have: the shared machinery rather than a copy of
--     it, the declared counts, the claim/tick/footer trio and the three bands.
--   ✗ nothing about how any of it LOOKS or behaves in the client -- the panels,
--     the hides and the summaries are read by eye and by the in-game checklist.
-- ============================================================

-- ⚠ NORMALISED TO LF UP FRONT. This page file ships CRLF (the companion's files
-- are mixed per file), and a plain multi-line `find` for source text would miss
-- every one of them otherwise. Nothing here asserts about line endings.
local SRC = options_file_source("GUI/Pages/Modules.lua"):gsub("\r\n", "\n")

-- ---- the census reader (the sweep's, unchanged) ----------------------
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

-- The page, scoped by its own two ends: Modules.lua holds five pages, and a bare
-- 280 box on one of the others is not this pass's business.
local PAGE
do
    local a = SRC:find('BuildPage(pageHighlights, function(self, db, Add, AddSpace, AddSyncPoint)', 1, true)
    local b = SRC:find('local pageDispel = CreateSubTab("auras", "auras_dispel", L["Dispel Overlay"])', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Highlights page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

local function esc(s) return (s:gsub("%p", "%%%0")) end

-- The block a row is declared in, from its label to the closing brace of the
-- CreatePopoutRow opts.
local function rowOpts(labelKey)
    local a = PAGE:find('%f[%w]label%s*=%s*L%["' .. esc(labelKey) .. '"%]')
    check(a ~= nil, "source: a popout row is declared for " .. labelKey)
    if not a then return "" end
    local b = PAGE:find("}))", a, true)
    return PAGE:sub(a, (b or a) + 2)
end

-- What every converted group on this page has in common.
--
-- ⚠ THE CLASSIC MOUNT IS AddToSection, NOT Add. Every box on this page belongs
-- to one of the three collapsible sections, and it is that call which registers
-- it as the section's child -- so the fold still folds it.
local function checkShared(builder, rowLabel, boxHeader, column)
    -- ONE builder, BOTH layouts: the declaration and the two mounts.
    local calls = 0
    for _ in PAGE:gmatch(builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, rowLabel .. ": declared once, mounted twice -- classic box and popout pane")

    -- The classic branch builds the box it always did, with its own header, in
    -- the column it always had.
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
        check(PAGE:find("AddToSection(" .. box .. ", nil, " .. column .. ")", 1, true) ~= nil,
              rowLabel .. ": ...which still goes to column " .. column .. ", inside its section")
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
-- 1. THE PAGE TAKES THE SHARED MACHINERY, AND ITS VOCABULARY IS AT PAGE SCOPE
-- ============================================================
print("-- Highlights page: the shared popout machinery and the page-scope vocabulary")
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

    -- ---- the three bands ----------------------------------------------
    for _, b in ipairs({ "selectionBand", "hoverBand", "aggroBand" }) do
        check(PAGE:find(b .. " = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
              "bands: " .. b .. " is chromeless, at the width the layout pass will give it")
    end
    for _, pair in ipairs({ { "selectionBand", "Selection Highlight" },
                            { "hoverBand", "Hover Highlight" },
                            { "aggroBand", "Aggro Highlight" } }) do
        check(PAGE:find(pair[1] .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. pair[2] .. '"]), 40)', 1, true) ~= nil,
              "bands: ..." .. pair[1] .. " takes the name its collapsible section already had")
    end
    -- ...and the section it took the name from is still built in classic.
    for _, s in ipairs({ "Selection Highlight", "Hover Highlight", "Aggro Highlight" }) do
        check(PAGE:find('GUI:CreateCollapsibleSection(self.child, L["' .. s .. '"], true), 36, "both")', 1, true) ~= nil,
              "bands: classic still folds " .. s .. " into its own section")
    end
    local sections = 0
    for _ in PAGE:gmatch("GUI:CreateCollapsibleSection%(") do sections = sections + 1 end
    eq(sections, 3, "bands: three sections built, and only the classic arms build them")
    check(PAGE:find("local function AddToSection(widget, height, col)", 1, true) ~= nil,
          "bands: the section-registering mount survives for the classic arms")

    -- ☠ ONLY ONE ROW ON THE PAGE CAN HIDE, so every band header stands over
    -- something: Aggro Settings carries the mode that hides Threat Colors and
    -- never hides itself.
    for _, r in ipairs({ "selectionRow", "hoverRow", "aggroRow" }) do
        check(PAGE:find(r .. ".hideOn", 1, true) == nil,
              "bands: " .. r .. " never hides")
    end
    check(PAGE:find("threatRow.hideOn = HideAggroModeNone", 1, true) ~= nil,
          "bands: ...and the one that does carries the box's own gate")

    -- ---- the vocabulary, at PAGE scope, declared exactly once ---------
    for _, v in ipairs({ "highlightModes", "aggroModes" }) do
        local decls = 0
        for _ in PAGE:gmatch("local " .. v .. " = {") do decls = decls + 1 end
        eq(decls, 1, "vocab: " .. v .. " is declared exactly once, at page scope")
    end
    check(PAGE:find('["CORNERS"] = L["Corners Only"]', 1, true) ~= nil,
          "vocab: ...and they are the same tables the Mode dropdowns have always offered")
    check(PAGE:find('["HEALTH_COLOR"] = L["Health Bar Color"]', 1, true) ~= nil,
          "vocab: ...including the aggro-only entry")
    check(PAGE:find("local TIP_HL_INSET = L[", 1, true) ~= nil,
          "vocab: the shared Inset tooltip is still written once for all three")

    -- ⚠ ABOVE EVERY BUILDER. A builder is a closure and captures the upvalue that
    -- exists when it is created, so one declared above these would see nil.
    local vocabAt = PAGE:find("local aggroModes = {", 1, true)
    for _, b in ipairs({ "BuildSelectionHighlightGroup", "BuildHoverHighlightGroup",
                         "BuildAggroHighlightGroup", "BuildThreatColorsGroup" }) do
        local at = PAGE:find("local function " .. b .. "(tools2)", 1, true)
        check(at ~= nil and vocabAt ~= nil and vocabAt < at,
              "vocab: " .. b .. " is declared after it, so it closes over the real tables")
    end

    -- The page's own gates and applies are named once and shared by both layouts.
    for _, g in ipairs({ "HideSelectionOptions", "HideHoverOptions", "HideAggroOptions",
                         "HideAggroModeNone", "HideCustomColorOptions", "HideNonTankingColors",
                         "ApplySelectionHighlight", "ApplyHoverHighlight", "ApplyAggroHighlight" }) do
        local n = 0
        for _ in PAGE:gmatch("local function " .. g .. "%(") do n = n + 1 end
        eq(n, 1, "vocab: " .. g .. " is declared exactly once")
    end
end

-- ============================================================
-- 2. NOTHING HOISTS, AND NOTHING GATES THE PAGE
-- Three independent features and no boolean master switch anywhere, so no row
-- carries a tick and no row greys another.
-- ============================================================
print("-- Highlights page: no hoist, no page gate")
do
    check(PAGE:find("RegisterHoistedToggle", 1, true) == nil,
          "hoist: no row on this page hoists a toggle")
    check(PAGE:find("hoistToggle", 1, true) == nil,
          "hoist: ...so no builder carries a hoist branch either")
    for _, r in ipairs({ "selectionRow", "hoverRow", "aggroRow", "threatRow" }) do
        local opts = rowOpts(({ selectionRow = "Selection Settings", hoverRow = "Hover Settings",
                                aggroRow = "Aggro Settings", threatRow = "Threat Colors" })[r])
        check(opts:find("%f[%w]toggle%s*=") == nil, r .. ": declares no toggle")
        check(opts:find("onToggle", 1, true) == nil, r .. ": ...and so no commit either")
        check(PAGE:find(r .. ".disableOn", 1, true) == nil,
              r .. ": ...and nothing greys it, because there is no page gate")
    end
    -- Use Custom Colors stays IN the pane, which is what puts it under that row's
    -- Reset Group -- the thing a hoisted tick never gets.
    check(builderBody("BuildThreatColorsGroup"):find('db, "aggroUseCustomColors"', 1, true) ~= nil,
          "hoist: Use Custom Colors is a mode, not an enable, so it stays in the pane")

    -- No group-level child gate anywhere, so no index-1 repair is needed.
    check(PAGE:find("disableChildrenOn", 1, true) == nil,
          "gate: no group-level child gate on this page")
    check(PAGE:find("GatePaneFirstChild", 1, true) == nil,
          "gate: ...and no index-1 repair is declared")
end

-- ============================================================
-- 3. NO PAGE REBUILD, IN EITHER LAYOUT
-- This page never had one, and the conversion must not introduce one: a rebuild
-- retires the row the user is clicking through.
-- ============================================================
print("-- Highlights page: no page rebuild")
do
    check(PAGE:find("GUI:RefreshCurrentPage", 1, true) == nil,
          "rebuild: the page rebuilds itself from nowhere, in either layout")

    -- Every popout mount declares itself as one; four rows, four mounts.
    local popouts = 0
    for _ in PAGE:gmatch("popout = true,") do popouts = popouts + 1 end
    eq(popouts, 4, "rebuild: all four popout mounts declare themselves as panes")

    -- The state pass a builder runs is the LAYOUT-AWARE one, never the page's.
    for _, b in ipairs({ "BuildSelectionHighlightGroup", "BuildHoverHighlightGroup",
                         "BuildAggroHighlightGroup", "BuildThreatColorsGroup" }) do
        check(builderBody(b):find("self:RefreshStates()", 1, true) == nil,
              "rebuild: " .. b .. " never reaches past its own tools2 for a state pass")
    end
    -- ...and the three controls that move ANOTHER row all go through it.
    check(builderBody("BuildAggroHighlightGroup"):find("tools2.refreshStates()", 1, true) ~= nil,
          "rebuild: the aggro mode and the tanking tick re-gate Threat Colors through the state pass")
    check(builderBody("BuildThreatColorsGroup"):find("tools2.refreshStates()", 1, true) ~= nil,
          "rebuild: ...and Use Custom Colors re-gates its own three swatches the same way")
end

-- ============================================================
-- 4. THE FOUR BUILDERS, CONTROL BY CONTROL
-- Every golden below is the census of the PRE-CHANGE source: same factories,
-- same L keys, same db keys, same slot heights, in the same order.
-- ============================================================
local SELECTION = {
    { "dropdown",    "Mode",        "selectionHighlightMode",       55 },
    { "slider",      "Thickness",   "selectionHighlightThickness",  55 },
    { "slider",      "Inset",       "selectionHighlightInset",      55 },
    -- Frame Level is wrapped in SetFrameLevelTooltip, which the reader steps
    -- through: the factory underneath is still the slider it always was.
    { "slider",      "Frame Level", "selectionHighlightFrameLevel", 55 },
    { "slider",      "Alpha",       "selectionHighlightAlpha",      55 },
    { "colorpicker", "Color",       "selectionHighlightColor",      35 },
}
local HOVER = {
    { "dropdown",    "Mode",        "hoverHighlightMode",       55 },
    { "slider",      "Thickness",   "hoverHighlightThickness",  55 },
    { "slider",      "Inset",       "hoverHighlightInset",      55 },
    { "slider",      "Frame Level", "hoverHighlightFrameLevel", 55 },
    { "slider",      "Alpha",       "hoverHighlightAlpha",      55 },
    { "colorpicker", "Color",       "hoverHighlightColor",      35 },
}
local AGGRO = {
    { "dropdown", "Mode",                   "aggroHighlightMode",       55 },
    { "checkbox", "Only Show When Tanking", "aggroOnlyTanking",         28 },
    { "checkbox", "Hide on Tanks",          "aggroHideOnTanks",         28 },
    { "slider",   "Thickness",              "aggroHighlightThickness",  55 },
    { "slider",   "Inset",                  "aggroHighlightInset",      55 },
    { "slider",   "Frame Level",            "aggroHighlightFrameLevel", 55 },
    { "slider",   "Alpha",                  "aggroHighlightAlpha",      55 },
}
local THREAT = {
    { "checkbox",    "Use Custom Colors",                        "aggroUseCustomColors",    28 },
    { "colorpicker", "High Threat (Yellow)",                     "aggroColorHighThreat",    30 },
    { "colorpicker", "Highest Threat (Orange)",                  "aggroColorHighestThreat", 30 },
    { "colorpicker", "Tanking (Red)",                            "aggroColorTanking",       30 },
    { "label",       "Yellow=high, Orange=highest, Red=tanking.", "(none)",                 25 },
}

-- ⚠ EVERY ROW TAKES A FOOTER, which is a decision about the KEYS rather than the
-- shape: every setting behind these four rows is a plain profile setting the
-- defaults engine can write -- numbers, strings, booleans and four colour tables
-- whose swatches re-read their table on the value sweep, so a reset that
-- replaces one is repainted rather than detached.
local ROWS = {
    { builder = "BuildSelectionHighlightGroup", label = "Selection Settings",
      boxHeader = "Selection Settings", golden = SELECTION, countVar = "SELECTION_COUNT",
      column = "1", row = "selectionRow", band = "selectionBand",
      summary = "SelectionSettingsSummary", apply = "ApplySelectionHighlight" },
    { builder = "BuildHoverHighlightGroup", label = "Hover Settings",
      boxHeader = "Hover Settings", golden = HOVER, countVar = "HOVER_COUNT",
      column = "1", row = "hoverRow", band = "hoverBand",
      summary = "HoverSettingsSummary", apply = "ApplyHoverHighlight" },
    { builder = "BuildAggroHighlightGroup", label = "Aggro Settings",
      boxHeader = "Aggro Settings", golden = AGGRO, countVar = "AGGRO_COUNT",
      column = "1", row = "aggroRow", band = "aggroBand",
      summary = "AggroSettingsSummary", apply = "ApplyAggroHighlight" },
    { builder = "BuildThreatColorsGroup", label = "Threat Colors",
      boxHeader = "Threat Colors", golden = THREAT, countVar = "THREAT_COUNT",
      column = "2", row = "threatRow", band = "aggroBand",
      summary = "ThreatColorsSummary", apply = "ApplyAggroHighlight" },
}

for _, g in ipairs(ROWS) do
    print("-- Highlights page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())
    checkShared(g.builder, g.label, g.boxHeader, g.column)

    local declared = tonumber(PAGE:match("local " .. g.countVar .. "%s*=%s*(%d+)"))
    check(declared ~= nil, g.label .. ": the page declares the row's count in one place")
    eq(declared, #g.golden, g.label .. ": ...and it is the whole census, nothing hoisted out of it")

    local opts = rowOpts(g.label)
    check(opts:find("summary%s*=%s*" .. g.summary) ~= nil,
          g.label .. ": the row declares a summary of its own")
    check(opts:find("count%s*=%s*" .. g.countVar) ~= nil,
          g.label .. ": ...and the declared count, not a literal")
    check(opts:find("db%s*=%s*tools.RowDB") ~= nil,
          g.label .. ": ...bound through the function form, so a mode switch is followed")

    check(PAGE:find("local " .. g.row .. " = " .. g.band .. ":AddWidget(GUI:CreatePopoutRow(", 1, true) ~= nil,
          g.label .. ": the row is mounted into the " .. g.band)
    check(PAGE:find("tools.ClaimKeys(" .. g.row .. ", ", 1, true) ~= nil,
          g.label .. ": the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(" .. g.row .. ")", 1, true) ~= nil,
          g.label .. ": ...its amber tick asks about exactly those keys")
    check(PAGE:find("tools.WireFooter(" .. g.row .. ", " .. g.apply .. ")", 1, true) ~= nil,
          g.label .. ": ...and Reset Group / Hold: Defaults push the change into the frames")
end

-- ============================================================
-- 5. THE BOXES, THE BAND ORDER AND THE PAGE'S OWN FURNITURE
-- ============================================================
print("-- Highlights page: the boxes, the bands and the order")
do
    -- ---- four bare 280 boxes left, all inside a classicLayout arm ----
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 4, "boxes: four bare 280 boxes left, and they are the classic branch's own")
    check(PAGE:find("280, tools", 1, true) == nil,
          "boxes: no stay-inline 280 box is left on the page")
    check(PAGE:find("bandStyle", 1, true) == nil,
          "boxes: the band skin is never restated as a literal (this page needs none)")
    check(PAGE:find("GUI:CreateControlRow", 1, true) == nil,
          "boxes: no control row -- every group on this page has more than one setting")
    -- The one box that hid in classic still does.
    check(PAGE:find("threatGroup.hideOn = HideAggroModeNone", 1, true) ~= nil,
          "boxes: the Threat Colors box keeps the gate its row now also carries")

    -- ---- the Add order ------------------------------------------------
    local a = PAGE:find('Add(selectionBand, nil, "both")', 1, true)
    local b = PAGE:find('Add(hoverBand, nil, "both")', 1, true)
    local c = PAGE:find('Add(aggroBand, nil, "both")', 1, true)
    check(a and b and c and a < b and b < c,
          "order: the three bands span both columns, in the order the three sections had")

    -- ---- the page's own furniture is untouched -------------------------
    check(PAGE:find('CreateCopyButton(self.child, {"selectionHighlight", "hoverHighlight", "aggroHighlight", "aggro"}, L["Highlights"], "indicators_highlights")', 1, true) ~= nil,
          "page: the copy button keeps the four prefixes it owns")
    check(PAGE:find('{pageId = "auras_dispel", label = L["Dispel Overlay"]}', 1, true) ~= nil,
          "page: ...and the See Also block still points at the Dispel Overlay")
end

-- ============================================================
-- 6. THE SUMMARIES
-- Read by eye in the client; what is asserted here is that each one exists, is
-- declared once, joins with the sweep's separator and reads the same tables the
-- controls behind it offer -- so a row cannot say one thing while its dropdown
-- says another.
-- ============================================================
print("-- Highlights page: the summaries")
do
    check(PAGE:find('local function Join(parts) return table.concat(parts, " \\194\\183 ") end', 1, true) ~= nil,
          "summary: the sweep's separator is named once")

    -- Selection and Hover are the same four facts about the same four keys, so
    -- the body is written ONCE and given the prefix.
    check(PAGE:find("local function HighlightSummary(d, prefix)", 1, true) ~= nil,
          "summary: the shared Selection/Hover body is written once")
    check(PAGE:find('local function SelectionSettingsSummary(d) return HighlightSummary(d, "selection") end', 1, true) ~= nil,
          "summary: ...and Selection is that body with its prefix")
    check(PAGE:find('local function HoverSettingsSummary(d) return HighlightSummary(d, "hover") end', 1, true) ~= nil,
          "summary: ...and Hover likewise")

    for _, s in ipairs({ "HighlightSummary", "AggroSettingsSummary", "ThreatColorsSummary" }) do
        local body = PAGE:match("local function " .. s .. "%(.-%)(.-)\n        end")
        check(body ~= nil and body:find("Join(parts)", 1, true) ~= nil,
              "summary: " .. s .. " joins with the shared separator")
        check(body ~= nil and body:find("if not d then return \"\" end", 1, true) ~= nil,
              "summary: ..." .. s .. " answers an absent db rather than erroring on it")
    end

    -- The mode WORD comes out of the dropdown's own table, in both shapes.
    check(PAGE:find("local word = highlightModes[mode]", 1, true) ~= nil,
          "summary: Selection and Hover name the mode from the dropdown's own table")
    check(PAGE:find("local word = aggroModes[mode]", 1, true) ~= nil,
          "summary: ...and Aggro from its own, which has the extra entry")
    -- ⚠ AND EACH ONE STOPS WHERE THE CONTROLS DO. With the mode on Hidden there
    -- is no thickness, inset or alpha behind the row -- classic hides those
    -- outright -- so the summary says the mode word and nothing else.
    check(PAGE:find('if mode == "NONE" then return Join(parts) end', 1, true) ~= nil,
          "summary: a hidden highlight reports its mode and nothing behind it")
    check(PAGE:find('if mode ~= "HEALTH_COLOR" then', 1, true) ~= nil,
          "summary: ...and the aggro health-bar tint has no thickness to report either")
end
