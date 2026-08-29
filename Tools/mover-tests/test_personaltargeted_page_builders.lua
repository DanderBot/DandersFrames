local NS = ...

-- ============================================================
-- PERSONAL TARGETED PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Indicators.lua
-- ------------------------------------------------------------
-- Indicators > Personal Targeted is the surviving personal display after the
-- group on-frame Targeted Spells feature was removed on 12.1. NINE groups:
-- eight become feature rows and the ninth -- Growth, one dropdown -- becomes a
-- CONTROL ROW, in three bands:
--
--   "Content" band     Settings (hoists personalTargetedSpellEnabled, the PAGE
--                      gate) and Content Types
--   "Appearance" band  Size, Growth Direction (the control row), Border (hoists
--                      personalTargetedSpellShowBorder) and Duration Text
--   "Effects" band     Highlight Settings (hoists
--                      personalTargetedSpellHighlightImportant), Interrupt
--                      Settings (hoists personalTargetedSpellShowInterrupted)
--                      and X Mark (hoists personalTargetedSpellInterruptedShowX)
--
-- ☠ THE DURATION TEXT ROW HOISTS NOTHING, AND THAT IS A VERDICT RATHER THAN AN
-- OMISSION. "Show Duration" looks like the group's master and is not one: the
-- cooldown SWIPE beside it is gated only on the feature itself and stays usable
-- with the duration text off. A hoisted tick gates the whole pane behind it (the
-- kit's own syncGate), so hoisting this one would have greyed a control classic
-- leaves live.
--
-- ☠ AND NO GateHide SEAM. This page's gate has always been a GREY --
-- `disableOn = HidePersonalOptions` on each dependent control -- so it reads the
-- same in the box and in the pane and is handed to the widgets unchanged. The
-- popout adds the ROW's own grey on top.
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
--     same builder into the same 280 box, in the same column, in the same Add
--     order.
--   ✓ the wiring every row must have, the declared counts (less whatever the row
--     hoisted), the claim/tick/footer trio, the control row and the three bands.
--   ✗ nothing about how any of it LOOKS or behaves in the client -- the panels,
--     the greys and the summaries are read by eye and by the in-game checklist.
-- ============================================================

-- ⚠ NORMALISED TO LF UP FRONT. This page file ships CRLF (the companion's files
-- are mixed per file), and a plain multi-line `find` for source text would miss
-- every one of them otherwise. Nothing here asserts about line endings.
local SRC = options_file_source("GUI/Pages/Indicators.lua"):gsub("\r\n", "\n")

-- ---- the census reader (the sweep's, plus this page's three font kinds) ----
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateSeparator = "separator", CreateButton = "button",
    CreateGrowthControl = "growth", CreateTextureDropdown = "texturedropdown",
    CreateTextControls = "textcontrols", CreateBorderControls = "bordercontrols",
    CreateDurationFormatControls = "durationformat", CreateInfoBanner = "banner",
    -- ⚠ THE THREE THIS PAGE ADDS. A factory the reader does not know is SKIPPED,
    -- and its chunk then merges into the previous entry -- which would move that
    -- entry's slot height and pass. The Duration Text group is font / scale /
    -- outline / shadow, so all three have to be named.
    CreateFontDropdown = "fontdropdown", CreateOutlineDropdown = "outlinedropdown",
    CreateShadowCheckbox = "shadowcheckbox",
}

-- The body of a `local function <name>(tools2)` at the page builder's own indent.
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

-- The page, scoped by its own two ends: Indicators.lua holds six pages, and a
-- bare 280 box on one of the others is not this pass's business.
local PAGE
do
    local a = SRC:find('BuildPage(pagePersonalTargeted, function(self, db, Add, AddSpace, AddSyncPoint)', 1, true)
    local b = SRC:find('-- Indicators > Icons', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Personal Targeted page builder is locatable by its own ends")
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
-- 1. THE PAGE TAKES THE SHARED MACHINERY, AND ITS VOCABULARY IS AT PAGE SCOPE
-- ============================================================
print("-- Personal Targeted page: the shared popout machinery and the page-scope vocabulary")
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
    for _, b in ipairs({ "contentBand", "appearanceBand", "effectsBand" }) do
        check(PAGE:find(b .. " = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
              "bands: " .. b .. " is chromeless, at the width the layout pass will give it")
    end
    for _, pair in ipairs({ { "contentBand", "Content" },
                            { "appearanceBand", "Appearance" },
                            { "effectsBand", "Effects" } }) do
        check(PAGE:find(pair[1] .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. pair[2] .. '"]), 40)', 1, true) ~= nil,
              "bands: ..." .. pair[1] .. " takes a locale string the page already ships")
    end

    -- ☠ NO ROW ON THIS PAGE HIDES, so no band header can be left standing over
    -- nothing. Every gate here is a grey.
    check(PAGE:find("Row.hideOn", 1, true) == nil,
          "bands: no row declares a hideOn, so every band always has something under it")
    check(PAGE:find("bandStyle", 1, true) == nil,
          "bands: the band skin is never restated as a literal (this page needs none)")

    -- ---- the vocabulary, at PAGE scope, declared exactly once ---------
    local decls = 0
    for _ in PAGE:gmatch("local growthOptions = {") do decls = decls + 1 end
    eq(decls, 1, "vocab: growthOptions is declared exactly once, at page scope")
    check(PAGE:find('CENTER_H= L["Center (Horizontal)"]', 1, true) ~= nil,
          "vocab: ...and it is the same table the Growth dropdown has always offered")

    -- ⚠ ABOVE EVERY BUILDER. A builder is a closure and captures the upvalue that
    -- exists when it is created, so one declared above these would see nil.
    local vocabAt = PAGE:find("local growthOptions = {", 1, true)
    for _, b in ipairs({ "BuildPersonalSettingsGroup", "BuildPersonalContentGroup",
                         "BuildPersonalSizeGroup", "BuildPersonalBorderGroup",
                         "BuildPersonalDurationGroup", "BuildPersonalHighlightGroup",
                         "BuildPersonalInterruptGroup", "BuildPersonalXMarkGroup" }) do
        local at = PAGE:find("local function " .. b .. "(tools2)", 1, true)
        check(at ~= nil and vocabAt ~= nil and vocabAt < at,
              "vocab: " .. b .. " is declared after it, so it closes over the real table")
    end

    -- The page's own gates and its one apply are named once and shared by both
    -- layouts.
    for _, g in ipairs({ "HidePersonalOptions", "HidePersonalDurationOptions",
                         "HidePersonalHighlightOptions", "HideInterruptOptions",
                         "HideInterruptXOptions", "PersonalOffRow", "InterruptOffRow",
                         "PersonalTargetedUpdate" }) do
        local n = 0
        for _ in PAGE:gmatch("local function " .. g .. "%(") do n = n + 1 end
        eq(n, 1, "vocab: " .. g .. " is declared exactly once")
    end
end

-- ============================================================
-- 2. THE PAGE GATE, AND THE FIVE HOISTS
-- ============================================================
print("-- Personal Targeted page: the page gate and the five hoisted ticks")
do
    check(PAGE:find("local function PersonalOffRow(d) return not (d or db).personalTargetedSpellEnabled end", 1, true) ~= nil,
          "gate: the page gate answers for either table -- the row's own and the page's state pass")

    -- Six rows and the control row grey with the page gate; the Settings row does
    -- not, because it CARRIES the tick that would otherwise be unreachable.
    local greyed = { "contentRow", "sizeRow", "growthRow", "borderRow", "durationRow",
                     "highlightRow", "interruptRow" }
    for _, r in ipairs(greyed) do
        check(PAGE:find(r .. ".disableOn = PersonalOffRow", 1, true) ~= nil,
              "gate: " .. r .. " greys with the page gate")
    end
    check(PAGE:find("settingsRow.disableOn", 1, true) == nil,
          "gate: ...and the Settings row does not, because it carries the tick")

    -- ☠ THE X MARK ROW TAKES THE INTERRUPTED VISUAL'S GATE, NOT THE PAGE'S. The X
    -- is drawn on that visual, so its tick greyed with Show Interrupted Visual in
    -- the box and greys with it here -- one gate that happens to include the
    -- page's.
    check(PAGE:find("xMarkRow.disableOn = InterruptOffRow", 1, true) ~= nil,
          "gate: the X Mark row greys with the interrupted visual, which includes the page gate")

    -- ☠ NO GROUP-LEVEL CHILD GATE, so no index-1 repair is needed. Every grey on
    -- this page is a per-widget disableOn, which RefreshChildStates applies to
    -- index 1 like any other -- only disableChildrenOn skips it.
    check(PAGE:find("disableChildrenOn", 1, true) == nil,
          "gate: no group-level child gate on this page")
    check(PAGE:find("GatePaneFirstChild", 1, true) == nil,
          "gate: ...and no index-1 repair is declared")

    local hoists = {
        { row = "settingsRow",  key = "personalTargetedSpellEnabled",            label = "Enable Personal Targeted Spells", commit = "OnPersonalEnableToggle" },
        { row = "borderRow",    key = "personalTargetedSpellShowBorder",         label = "Show Border",                     commit = "OnPersonalBorderToggle" },
        { row = "highlightRow", key = "personalTargetedSpellHighlightImportant", label = "Highlight Important Spells",      commit = "OnPersonalHighlightToggle" },
        { row = "interruptRow", key = "personalTargetedSpellShowInterrupted",    label = "Show Interrupted Visual",         commit = "OnPersonalInterruptToggle" },
        { row = "xMarkRow",     key = "personalTargetedSpellInterruptedShowX",   label = "Show X Mark",                     commit = "OnPersonalXMarkToggle" },
    }
    for _, h in ipairs(hoists) do
        check(PAGE:find('tools.RegisterHoistedToggle(' .. h.row .. ', L["' .. h.label .. '"], "' .. h.key .. '", ' .. h.commit .. ')', 1, true) ~= nil,
              "hoist: " .. h.row .. " keeps its search entry, with the commit the checkbox carried")
        local a = PAGE:find("local function " .. h.commit .. "()", 1, true)
        check(a ~= nil, "hoist: ..." .. h.commit .. " is declared once, in the popout arm")
        local b = PAGE:find("\n            end\n", a or 1, true)
        local body = PAGE:sub(a or 1, b or (a or 1))
        check(body:find("tools.ReflowMounted()", 1, true) ~= nil,
              "hoist: ..." .. h.commit .. " reflows the panes standing open")
        check(body:find("RefreshCurrentPage", 1, true) == nil,
              "hoist: ...and never rebuilds the page")
    end
    eq(#hoists, 5, "hoist: five rows carry a tick")

    -- The suppressed checkboxes are still built in classic.
    for _, b in ipairs({ "BuildPersonalSettingsGroup", "BuildPersonalHighlightGroup",
                         "BuildPersonalInterruptGroup", "BuildPersonalXMarkGroup" }) do
        check(builderBody(b):find("if not tools2.hoistToggle then", 1, true) ~= nil,
              "hoist: " .. b .. " skips its enable checkbox when the row has hoisted it")
    end
    check(builderBody("BuildPersonalBorderGroup"):find("noShowToggle = tools2.hoistToggle or nil", 1, true) ~= nil,
          "hoist: the border toolkit's own Show Border is suppressed the toolkit's way")

    -- ☠ THE DURATION TEXT ROW HOISTS NOTHING, AND THAT IS THE VERDICT. Show
    -- Duration is not the group's master: the cooldown swipe beside it is gated
    -- only on the feature, so a hoisted tick -- which greys the whole pane behind
    -- it -- would have greyed a control classic leaves live.
    check(builderBody("BuildPersonalDurationGroup"):find("hoistToggle", 1, true) == nil,
          "hoist: the Duration Text builder has no hoist branch")
    local durOpts = rowOpts("Duration Text")
    check(durOpts:find("%f[%w]toggle%s*=") == nil, "hoist: ...its row declares no toggle")
    check(durOpts:find("onToggle", 1, true) == nil, "hoist: ...and so no commit either")
    check(builderBody("BuildPersonalDurationGroup"):find('db, "personalTargetedSpellShowSwipe"', 1, true) ~= nil,
          "hoist: ...and the swipe that made it a verdict is still in the pane")

    -- ...and neither does Content Types or Size: three groups with no boolean
    -- master between them.
    for _, l in ipairs({ "Content Types", "Size" }) do
        local o = rowOpts(l)
        check(o:find("%f[%w]toggle%s*=") == nil, "hoist: the " .. l .. " row declares no toggle")
    end

    -- ☠ TWO SUPPRESSIONS THAT LOOK ALIKE AND ARE NOT. `noShowToggle = true` on the
    -- highlight border is UNCONDITIONAL and always was -- that border has never had
    -- its own Show tick, because the Highlight Important Spells checkbox is its
    -- gate. The HOIST is that checkbox.
    check(builderBody("BuildPersonalHighlightGroup"):find("noShowToggle  = true", 1, true) ~= nil,
          "hoist: the highlight border keeps its unconditional noShowToggle")
end

-- ============================================================
-- 3. NO PAGE REBUILD, IN EITHER LAYOUT
-- This page never had one, and the conversion must not introduce one: a rebuild
-- retires the row the user is clicking through.
-- ============================================================
print("-- Personal Targeted page: no page rebuild")
do
    check(PAGE:find("RefreshCurrentPage", 1, true) == nil,
          "rebuild: the page rebuilds itself from nowhere, in either layout")

    -- Every popout mount declares itself as one; eight rows, eight mounts (the
    -- control row has no pane).
    local popouts = 0
    for _ in PAGE:gmatch("popout = true,") do popouts = popouts + 1 end
    eq(popouts, 8, "rebuild: all eight popout mounts declare themselves as panes")

    -- No builder reaches past its own tools2 for a state pass.
    for _, b in ipairs({ "BuildPersonalSettingsGroup", "BuildPersonalDurationGroup",
                         "BuildPersonalHighlightGroup", "BuildPersonalInterruptGroup",
                         "BuildPersonalXMarkGroup" }) do
        check(builderBody(b):find("self:RefreshStates()", 1, true) == nil,
              "rebuild: " .. b .. " never reaches past its own tools2 for a state pass")
        check(builderBody(b):find("tools2.refreshStates", 1, true) ~= nil,
              "rebuild: ..." .. b .. " re-gates through the layout-aware door instead")
    end
end

-- ============================================================
-- 4. THE EIGHT BUILDERS, CONTROL BY CONTROL
-- Every golden below is the census of the PRE-CHANGE source: same factories,
-- same L keys, same db keys, same slot heights, in the same order.
-- ============================================================
local PT_SETTINGS = {
    { "label",    "Shows incoming targeted spells on YOU in the center of your screen.", "(none)", 30 },
    { "label",    "To reposition: Unlock frames (/df unlock) and drag the mover.",       "(none)", 30 },
    { "checkbox", "Enable Personal Targeted Spells", "personalTargetedSpellEnabled",       30 },
    { "checkbox", "Important Spells Only",           "personalTargetedSpellImportantOnly", 30 },
    -- The game CVar: a custom get/set tick with no db binding at all.
    { "checkbox", "Show Offscreen Nameplates",       "(none)",                             30 },
}
local PT_CONTENT = {
    { "label",    "Show in content types:",                        "(none)",                                25 },
    { "checkbox", "Open World",                                    "personalTargetedSpellInOpenWorld",      25 },
    { "checkbox", "Dungeons",                                      "personalTargetedSpellInDungeons",       25 },
    { "checkbox", "Raids",                                         "personalTargetedSpellInRaids",          25 },
    { "checkbox", "Arena",                                         "personalTargetedSpellInArena",          25 },
    { "checkbox", "Battlegrounds",                                 "personalTargetedSpellInBattlegrounds",  25 },
    { "label",    "Content type filters configured in Party tab.", "(none)",                                25 },
}
local PT_SIZE = {
    { "slider", "Icon Size", "personalTargetedSpellSize",     55 },
    { "slider", "Scale",     "personalTargetedSpellScale",    55 },
    { "slider", "Alpha",     "personalTargetedSpellAlpha",    55 },
    { "slider", "Spacing",   "personalTargetedSpellSpacing",  55 },
    { "slider", "Max Icons", "personalTargetedSpellMaxIcons", 55 },
}
local PT_BORDER = {
    -- The key the census reads off this one is the PREFIX the toolkit is handed,
    -- not a setting -- every one of its twenty-nine keys is built from it.
    { "bordercontrols", "(none)", "personalTargetedSpell", nil },
}
local PT_DURATION = {
    { "checkbox",        "Show Duration",       "personalTargetedSpellShowDuration",    30 },
    { "checkbox",        "Show Cooldown Swipe", "personalTargetedSpellShowSwipe",       30 },
    { "fontdropdown",    "Font",                "personalTargetedSpellDurationFont",    55 },
    { "slider",          "Scale",               "personalTargetedSpellDurationScale",   55 },
    { "outlinedropdown", "Outline",             "personalTargetedSpellDurationOutline", 55 },
    -- The shadow tick is a custom get/set OVER THE OUTLINE KEY, so it claims the
    -- same key the dropdown above it does. That is not a duplicate to fix: it is
    -- one setting with two handles.
    { "shadowcheckbox",  "Shadow",              "personalTargetedSpellDurationOutline", 30 },
    { "slider",          "Offset X",            "personalTargetedSpellDurationX",       55 },
    { "slider",          "Offset Y",            "personalTargetedSpellDurationY",       55 },
    { "colorpicker",     "Color",               "personalTargetedSpellDurationColor",   35 },
}
local PT_HIGHLIGHT = {
    { "checkbox",       "Highlight Important Spells", "personalTargetedSpellHighlightImportant", 30 },
    { "bordercontrols", "(none)",                     "personalTargetedSpellImportant",          nil },
}
local PT_INTERRUPT = {
    { "checkbox",    "Show Interrupted Visual", "personalTargetedSpellShowInterrupted",      30 },
    { "slider",      "Duration",                "personalTargetedSpellInterruptedDuration",  55 },
    { "colorpicker", "Tint Color",              "personalTargetedSpellInterruptedTintColor", 35 },
    { "slider",      "Tint Opacity",            "personalTargetedSpellInterruptedTintAlpha", 55 },
}
local PT_XMARK = {
    { "checkbox",    "Show X Mark", "personalTargetedSpellInterruptedShowX",  30 },
    { "colorpicker", "X Color",     "personalTargetedSpellInterruptedXColor", 35 },
    { "slider",      "X Size",      "personalTargetedSpellInterruptedXSize",  55 },
}

-- ⚠ EVERY ROW TAKES A FOOTER, which is a decision about the KEYS rather than the
-- shape: every setting behind these eight rows is a plain profile setting the
-- defaults engine can write -- numbers, strings, booleans and the colour tables
-- whose swatches re-read their table on the value sweep, so a reset that
-- replaces one is repainted rather than detached.
local ROWS = {
    { builder = "BuildPersonalSettingsGroup", label = "Settings", boxHeader = "Settings",
      golden = PT_SETTINGS, countVar = "PT_SETTINGS_COUNT", column = "1", hoistedIn = 1,
      row = "settingsRow", band = "contentBand", summary = "PersonalSettingsSummary" },
    { builder = "BuildPersonalContentGroup", label = "Content Types", boxHeader = "Content Types",
      golden = PT_CONTENT, countVar = "PT_CONTENT_COUNT", column = "2", hoistedIn = 0,
      row = "contentRow", band = "contentBand", summary = "PersonalContentSummary" },
    { builder = "BuildPersonalSizeGroup", label = "Size", boxHeader = "Size",
      golden = PT_SIZE, countVar = "PT_SIZE_COUNT", column = "1", hoistedIn = 0,
      row = "sizeRow", band = "appearanceBand", summary = "PersonalSizeSummary" },
    { builder = "BuildPersonalBorderGroup", label = "Border", boxHeader = "Border",
      golden = PT_BORDER, countVar = "PT_BORDER_COUNT", column = "2", hoistedIn = 0,
      row = "borderRow", band = "appearanceBand", summary = "PersonalBorderSummary" },
    { builder = "BuildPersonalDurationGroup", label = "Duration Text", boxHeader = "Duration Text",
      golden = PT_DURATION, countVar = "PT_DURATION_COUNT", column = "2", hoistedIn = 0,
      row = "durationRow", band = "appearanceBand", summary = "PersonalDurationSummary" },
    { builder = "BuildPersonalHighlightGroup", label = "Highlight Settings", boxHeader = "Highlight Settings",
      golden = PT_HIGHLIGHT, countVar = "PT_HIGHLIGHT_COUNT", column = "1", hoistedIn = 1,
      row = "highlightRow", band = "effectsBand", summary = "PersonalHighlightSummary" },
    { builder = "BuildPersonalInterruptGroup", label = "Interrupt Settings", boxHeader = "Interrupt Settings",
      golden = PT_INTERRUPT, countVar = "PT_INTERRUPT_COUNT", column = "2", hoistedIn = 1,
      row = "interruptRow", band = "effectsBand", summary = "PersonalInterruptSummary" },
    { builder = "BuildPersonalXMarkGroup", label = "X Mark", boxHeader = "X Mark",
      golden = PT_XMARK, countVar = "PT_XMARK_COUNT", column = "2", hoistedIn = 1,
      row = "xMarkRow", band = "effectsBand", summary = "PersonalXMarkSummary" },
}

for _, g in ipairs(ROWS) do
    print("-- Personal Targeted page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())
    checkShared(g.builder, g.label, g.boxHeader, g.column)

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
    check(PAGE:find("tools.WireFooter(" .. g.row .. ", PersonalTargetedUpdate)", 1, true) ~= nil,
          g.label .. ": ...and Reset Group / Hold: Defaults push the change into the display")

    -- The declared count is the census, less whatever the row hoisted out of it.
    -- The two border rows are the ones that are not plain widget lists -- their
    -- arithmetic is section 5.
    if g.golden ~= PT_BORDER and g.golden ~= PT_HIGHLIGHT then
        local declared = tonumber(PAGE:match("local " .. g.countVar .. "%s*=%s*(%d+)"))
        check(declared ~= nil, g.label .. ": the page declares the row's count in one place")
        eq(declared, #g.golden - g.hoistedIn,
           g.label .. ": ...and it is the census less whatever the row hoisted")
    end
end

-- ============================================================
-- 5. THE TWO BORDER COUNTS, DERIVED FROM THE HELPER RATHER THAN ASSERTED AT IT
-- CreateBorderControls builds a fixed set plus one widget per include key. Both
-- of this page's calls take the SAME include set -- the toolkit's usual set plus
-- the animation block -- and differ only in how the Show tick is suppressed.
-- ============================================================
print("-- Personal Targeted page: the two border counts")
do
    local BORDER_BASE = 4          -- Show Border, thickness, style, texture
    local BORDER_COLOR = 1         -- the static colour picker
    local BORDER_GRADIENT = 3      -- start, end, direction
    local BORDER_SHADOW = 5        -- the block's tick plus colour, size, two offsets
    local BORDER_ALPHA, BORDER_INSET, BORDER_BLEND = 1, 1, 1
    local BORDER_ANIMATE = 13      -- the type, the perf banner, the colour and ten tunables
    local borderAll = BORDER_BASE + BORDER_COLOR + BORDER_GRADIENT + BORDER_SHADOW
                    + BORDER_ALPHA + BORDER_INSET + BORDER_BLEND + BORDER_ANIMATE
    eq(borderAll, 29, "counts: the border toolkit builds twenty-nine for this include set")

    eq(tonumber(PAGE:match("local PT_BORDER_COUNT%s*=%s*(%d+)")), borderAll - 1,
       "counts: Border is those twenty-nine less the hoisted Show Border")
    -- ...and the highlight border is the same set with the toolkit's own Show tick
    -- never built at all, plus a hoisted checkbox of its own that is not the
    -- toolkit's.
    eq(tonumber(PAGE:match("local PT_HIGHLIGHT_COUNT%s*=%s*(%d+)")), borderAll - 1,
       "counts: Highlight Settings is the same set with noShowToggle already on, and its own tick hoisted")

    for _, b in ipairs({ "BuildPersonalBorderGroup", "BuildPersonalHighlightGroup" }) do
        local body = builderBody(b)
        for _, k in ipairs({ "alpha", "inset", "blendMode", "gradient", "shadow", "animate" }) do
            check(body:find(k .. " = true", 1, true) ~= nil,
                  "counts: " .. b .. "'s include set asks for " .. k)
        end
        for _, k in ipairs({ "offset", "classColor", "roleColor" }) do
            check(body:find(k .. " = true", 1, true) == nil,
                  "counts: ..." .. b .. " does not ask for " .. k)
        end
    end
    -- The gate goes in as the CONSUMER gate it has always been: the toolkit owns
    -- the whole group and writes disableOn onto each widget itself.
    check(builderBody("BuildPersonalBorderGroup"):find("disableWhen  = HidePersonalOptions", 1, true) ~= nil,
          "counts: the page gate reaches the border as the toolkit's own consumer gate")
    check(builderBody("BuildPersonalHighlightGroup"):find("disableWhen   = HidePersonalHighlightOptions", 1, true) ~= nil,
          "counts: ...and the highlight border takes the highlight's gate instead")
end

-- ============================================================
-- 6. THE CONTROL ROW
-- One dropdown, so the group becomes a plate rather than a way in to one thing.
-- ============================================================
print("-- Personal Targeted page: the Growth control row")
do
    check(PAGE:find("local growthRow = appearanceBand:AddWidget(GUI:CreateControlRow(self.child, {", 1, true) ~= nil,
          "control row: Growth is one plate in the Appearance band, not a bare box in a column")
    local a = PAGE:find("local growthRow = appearanceBand:AddWidget(GUI:CreateControlRow(", 1, true)
    local b = PAGE:find("}))", a or 1, true)
    local opts = PAGE:sub(a or 1, (b or (a or 1)) + 2)
    check(opts:find('label     = L["Growth Direction"]', 1, true) ~= nil,
          "control row: ...named for its SETTING, not for the box's own Growth header")
    check(opts:find('kind      = "dropdown"', 1, true) ~= nil, "control row: ...as a dropdown")
    check(opts:find("options   = growthOptions", 1, true) ~= nil,
          "control row: ...offering the page-scope table, not a second copy")
    check(opts:find("db        = tools.RowDB", 1, true) ~= nil,
          "control row: ...bound through the function form, so a mode switch is followed")
    check(opts:find('key       = "personalTargetedSpellGrowth"', 1, true) ~= nil,
          "control row: ...to the key the box's dropdown always wrote")
    check(PAGE:find('tools.RegisterControlRow(growthRow, "dropdown", "personalTargetedSpellGrowth")', 1, true) ~= nil,
          "control row: ...and it adopts the search entry the dropdown factory already made")

    -- Classic keeps the box, its header and its column.
    check(PAGE:find('growthGroup:AddWidget(GUI:CreateHeader(self.child, L["Growth"]), 40)', 1, true) ~= nil,
          "control row: classic keeps the Growth box with its own header")
    check(PAGE:find('local ptsGrowth = growthGroup:AddWidget(GUI:CreateDropdown(self.child, L["Growth Direction"], growthOptions, db, "personalTargetedSpellGrowth", PersonalTargetedUpdate), 55)', 1, true) ~= nil,
          "control row: ...with the dropdown it always built")
    check(PAGE:find("ptsGrowth.disableOn = HidePersonalOptions", 1, true) ~= nil,
          "control row: ...greying on the page gate exactly as before")
    check(PAGE:find("Add(growthGroup, nil, 1)", 1, true) ~= nil,
          "control row: ...in column 1, where it always was")

    local n = 0
    for _ in PAGE:gmatch("GUI:CreateControlRow%(") do n = n + 1 end
    eq(n, 1, "control row: exactly one on this page -- every other group has more than one setting")
end

-- ============================================================
-- 7. THE BOXES, THE ADD ORDER AND THE PAGE'S OWN FURNITURE
-- ============================================================
print("-- Personal Targeted page: the boxes, the bands and the order")
do
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 9, "boxes: nine bare 280 boxes left, and they are the classic branch's own")
    check(PAGE:find("280, tools", 1, true) == nil,
          "boxes: no stay-inline 280 box is left on the page")

    -- ---- classic's Add order is the order it always had ---------------
    -- Within a column the Add() order IS the layout order, so this is what makes
    -- "classic is unchanged" structural rather than a promise.
    local order = { "settingsGroup", "contentGroup", "sizeGroup", "growthGroup",
                    "borderGroup", "durationGroup", "highlightGroup", "interruptGroup",
                    "xMarkGroup" }
    local prev = 0
    for _, name in ipairs(order) do
        local at = PAGE:find("Add(" .. name .. ", nil,", 1, true)
        check(at ~= nil and at > prev, "order: classic adds " .. name .. " in its original place")
        prev = at or prev
    end

    -- ---- the Add order of the bands ------------------------------------
    local b1 = PAGE:find('Add(contentBand, nil, "both")', 1, true)
    local b2 = PAGE:find('Add(appearanceBand, nil, "both")', 1, true)
    local b3 = PAGE:find('Add(effectsBand, nil, "both")', 1, true)
    check(b1 and b2 and b3 and b1 < b2 and b2 < b3,
          "order: the three bands span both columns, in reading order")

    -- ---- the page's own furniture is untouched -------------------------
    check(PAGE:find('CreateCopyButton(self.child, {"personalTargeted"}, L["Personal Targeted"], "indicators_personal_targeted")', 1, true) ~= nil,
          "page: the copy button keeps the prefix it owns")
    check(PAGE:find('{pageId = "indicators_targetedlist", label = L["Targeted List"]}', 1, true) ~= nil,
          "page: ...and the See Also block still points at the Targeted List")
    -- The five content ticks keep their RAID-mode hide, which is a mode gate and
    -- reads the same in both layouts.
    local hides = 0
    for _ in PAGE:gmatch('hideOn = function%(%) return GUI%.SelectedMode == "raid" end') do hides = hides + 1 end
    eq(hides, 5, "page: the five content ticks keep their raid-mode hide")
end

-- ============================================================
-- 8. THE SUMMARIES
-- Read by eye in the client; what is asserted here is that each one exists, is
-- declared once, joins with the sweep's separator and reads the same tables the
-- controls behind it offer -- so a row cannot say one thing while its dropdown
-- says another.
-- ============================================================
print("-- Personal Targeted page: the summaries")
do
    check(PAGE:find('local function Join(parts) return table.concat(parts, " \\194\\183 ") end', 1, true) ~= nil,
          "summary: the sweep's separator is named once")

    for _, s in ipairs({ "PersonalContentSummary", "PersonalSizeSummary",
                         "PersonalBorderSummary", "PersonalDurationSummary",
                         "PersonalHighlightSummary", "PersonalInterruptSummary",
                         "PersonalXMarkSummary" }) do
        local body = PAGE:match("local function " .. s .. "%(.-%)(.-)\n        end")
        check(body ~= nil and body:find("Join(parts)", 1, true) ~= nil,
              "summary: " .. s .. " joins with the shared separator")
        check(body ~= nil and body:find("if not d then return \"\" end", 1, true) ~= nil,
              "summary: ..." .. s .. " answers an absent db rather than erroring on it")
    end
    -- The Settings row's is the one that reports a single tick, so it returns
    -- early rather than joining a one-item list.
    check(PAGE:find('if not d.personalTargetedSpellImportantOnly then return "" end', 1, true) ~= nil,
          "summary: Settings is silent while its one tick is off, which is the shipped profile")

    -- ☠ CONTENT TYPES NAMES WHAT IS LEFT ON, AND ONLY ONCE SOMETHING IS OFF. All
    -- five are on in the shipped profile, so the row is silent there -- and the
    -- moment any one is off there are at most four left to name, which is the
    -- four-item budget exactly.
    check(PAGE:find("if off == 0 then return \"\" end", 1, true) ~= nil,
          "summary: Content Types is silent while every content type is on")

    -- The Duration Text row has no tick of its own, so its summary is what says
    -- whether anything is drawn at all.
    check(PAGE:find("if d.personalTargetedSpellShowDuration then", 1, true) ~= nil,
          "summary: Duration Text says whether the text is on, because its row carries no tick")
    check(PAGE:find("if d.personalTargetedSpellShowSwipe then parts[#parts + 1] = L[\"Show Cooldown Swipe\"] end", 1, true) ~= nil,
          "summary: ...and whether the swipe is, which is the control that kept the tick out of the row")
end
