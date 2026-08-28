local NS = ...

-- ============================================================
-- HEAL PREDICTION PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Auras.lua
-- ------------------------------------------------------------
-- Bars > Heal Prediction turns its three 280 boxes into three feature rows in
-- ONE headerless band (the Fading page's shape -- three rows do not need
-- dividing, and a band header over the only band on a page repeats the page's
-- own name):
--
--   Heal Prediction        (hoisted enable)
--   Floating Bar Position  (hidden unless the bar is floating)
--   Floating Bar Anchor    (hidden unless the bar is floating)
--
-- ☠ THREE THINGS THIS SUITE IS HERE TO PIN:
--
--   1. THE COLOUR PICKERS ARE THE SWEEP'S FIRST LAYOUT-CONDITIONAL BUILDER
--      BRANCH. Classic decides the picker SET at build time from the db -- Split
--      builds two, every other mode builds one bound to that mode's key -- so
--      changing the source has to REBUILD THE PAGE, which inside a pane closes
--      the panel the dropdown was clicked in. The pane builds all three and
--      gates them with hideOn instead. Section 3 pins both arms and pins that
--      only the classic one still rebuilds.
--   2. THE TWO GROUP-LEVEL hideOns BECOME ROW-LEVEL ONES, off ONE named
--      predicate handed to both layouts. Section 6.
--   3. THE PAGE-WIDE GATE REACHES THE ROWS -- the Pet Frames rule -- with the
--      Settings row excepted because it carries the gate's own tick. Section 6.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY -- it is welded to the panel (a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db) -- so this file
-- does what every page-builder suite before it does: it reads the page's SOURCE
-- and asserts against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each extracted builder -- kind, L key, db key and
--     slot height, in order -- taken from the PRE-CHANGE source, BOTH arms of the
--     picker branch included.
--   ✓ that ONE builder serves both layouts.
--   ✓ that each declared row COUNT matches what its pane mounts.
--   ✓ that the display-mode dropdown routes through tools2.refreshStates and
--     that GUI:RefreshCurrentPage survives on the CLASSIC side only.
--   ✓ that every summary reads its words out of the dropdown table the control
--     itself offers, and that the page adds NO new locale string.
--   ✗ nothing about runtime behaviour -- the callbacks, the greying and the
--     summaries are read by eye and by the in-game checklist.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Auras.lua")

-- ---- the census reader (the Health Bar page's, verbatim) ----
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateTextureDropdown = "texturedropdown",
    CreateHeader = "header", CreateLabel = "label",
}

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

-- The page, scoped by its own two ends: Auras.lua holds a dozen pages, and a
-- bare 280 box on one of the others is not this pass's business.
local PAGE
do
    local a = SRC:find('local pageHealPrediction = CreateSubTab("bars", "bars_healpred", L["Heal Prediction"])', 1, true)
    local b = SRC:find("-- CATEGORY: Text", 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Heal Prediction page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

local function rowOpts(labelKey)
    local a = PAGE:find('label%s*=%s*L%["' .. labelKey .. '"%]')
    check(a ~= nil, "source: a popout row is declared for " .. labelKey)
    if not a then return "" end
    local b = PAGE:find("}))", a, true)
    return PAGE:sub(a, (b or a) + 2)
end

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED MACHINERY, AND ITS ONE BAND IS HEADERLESS
-- ============================================================
print("-- Heal Prediction page: the shared popout machinery and the band")
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

    check(PAGE:find("healPredBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
          "band: healPredBand is chromeless, at the width the layout pass will give it")
    -- ☠ AND IT CARRIES NO HEADER. It is the only band on the page, so a header
    -- would repeat the page's own name back at the reader. (The Fading page's
    -- rule for its single band.)
    check(PAGE:find("healPredBand:AddWidget(GUI:CreateHeader(", 1, true) == nil,
          "band: ...and carries no header of its own")
    check(PAGE:find('Add(healPredBand, nil, "both")', 1, true) ~= nil,
          "band: ...and goes in full-width, after its last row")
end

-- ============================================================
-- 2. THE DROPDOWN VOCABULARY MOVED TO PAGE SCOPE
-- The rows print the chosen value as their SUMMARY, and a summary is written
-- outside the group's builder -- so the word has to come out of the same table
-- the dropdown offers, or a row could say one thing while the control behind it
-- says another.
-- ============================================================
print("-- Heal Prediction page: the dropdown vocabulary at page scope")
do
    local VOCAB = {
        { "modeOptions",     'FLOATING= L["Floating Bar"]' },
        { "showModeOptions", 'SPLIT = L["Split (Mine + Others)"]' },
        { "orientOptions",   'HORIZONTAL= L["Horizontal"]' },
        { "anchorOptions",   'BOTTOMRIGHT= L["Bottom Right"]' },
    }
    for _, pair in ipairs(VOCAB) do
        local decls = 0
        for _ in PAGE:gmatch("local " .. pair[1] .. " = {") do decls = decls + 1 end
        eq(decls, 1, "vocab: " .. pair[1] .. " is declared exactly once")
        local at = PAGE:find("local " .. pair[1] .. " = {", 1, true)
        local firstBuilder = PAGE:find("local function BuildHealPredictionSettingsGroup(tools2)", 1, true)
        check(at ~= nil and firstBuilder ~= nil and at < firstBuilder,
              "vocab: ..." .. pair[1] .. " is declared above the first builder")
        local decl = PAGE:match("local " .. pair[1] .. " = {(.-)}")
        check(decl ~= nil and decl:find(pair[2], 1, true) ~= nil,
              "vocab: ..." .. pair[1] .. " still offers " .. pair[2])
    end

    -- ⚠ showModeOptions KEEPS ITS _order. The four sources read in a deliberate
    -- order (all, mine, others, split) that an unordered table would scramble.
    local showDecl = PAGE:match("local showModeOptions = {(.-)\n        }")
    check(showDecl ~= nil and showDecl:find('_order = { "ALL", "MINE", "OTHERS", "SPLIT" }', 1, true) ~= nil,
          "vocab: ...and showModeOptions keeps the reading order of its four sources")

    -- The blend table did not move: nothing outside its own builder reads it.
    local at = PAGE:find("local blendOptions = {", 1, true)
    local firstBuilder = PAGE:find("local function BuildHealPredictionSettingsGroup(tools2)", 1, true)
    check(at ~= nil and firstBuilder ~= nil and at > firstBuilder,
          "vocab: blendOptions stays inside the builder that offers it")
end

-- ============================================================
-- 3. THE LAYOUT-CONDITIONAL COLOUR PICKERS
-- ☠ THE SWEEP'S FIRST BUILDER BRANCH ON LAYOUT, and it is a structural refusal
-- rather than taste. Classic decides the picker SET at build time from the db,
-- so changing the source rebinds by REBUILDING THE PAGE -- fatal in a pane,
-- which the rebuild retires along with the panel it was clicked in. The pane
-- builds all three and gates them with hideOn: same write targets, no rebuild.
-- ============================================================
print("-- Heal Prediction page: the colour pickers, one set per layout")
do
    local body = builderBody("BuildHealPredictionSettingsGroup")

    check(body:find("if tools2.popout then", 1, true) ~= nil,
          "pickers: the builder branches on the layout, once, and says so")

    -- ---- the popout arm: three pickers, three real keys, three hideOns ----
    for _, p in ipairs({
        { "My Heals Color",       "healPredictionMyColor" },
        { "Others' Heals Color",  "healPredictionOthersColor" },
        { "Heal Prediction Color","healPredictionAllColor" },
    }) do
        check(body:find('GUI:CreateColorPicker(parent, L["' .. p[1] .. '"], db, "' .. p[2] .. '"', 1, true) ~= nil,
              "pickers: the pane builds " .. p[1] .. " bound to " .. p[2])
    end
    check(body:find('allColor.hideOn = function(d) return d.healPredictionShowMode ~= "ALL" end', 1, true) ~= nil,
          "pickers: ...and the All swatch shows only for All Incoming")
    check(body:find('return d.healPredictionShowMode ~= "SPLIT" and d.healPredictionShowMode ~= "MINE"', 1, true) ~= nil,
          "pickers: ...My Heals for Split and Mine")
    check(body:find('return d.healPredictionShowMode ~= "SPLIT" and d.healPredictionShowMode ~= "OTHERS"', 1, true) ~= nil,
          "pickers: ...and Others' Heals for Split and Others")

    -- ---- the classic arm is untouched -----------------------------------
    check(body:find('if db.healPredictionShowMode == "SPLIT" then', 1, true) ~= nil,
          "pickers: classic still decides its picker set at build time, from the db")
    check(body:find('local showModeColorKey = (db.healPredictionShowMode == "ALL" and "healPredictionAllColor")', 1, true) ~= nil,
          "pickers: ...and still binds its single picker to the mode's own key")

    -- ---- and only classic still rebuilds --------------------------------
    -- ☠ THE REBUILD SURVIVES ON EXACTLY ONE SIDE. Left in the popout arm it
    -- would slam the panel shut on every source change; removed from the classic
    -- arm the single picker would go on writing the previous mode's key.
    local rebuilds = 0
    for _ in PAGE:gmatch("GUI:RefreshCurrentPage%(%)") do rebuilds = rebuilds + 1 end
    eq(rebuilds, 1, "pickers: exactly one page rebuild left on this page")
    -- ⚠ THE SOURCE DROPDOWN'S OWN popout arm, matched at ITS indent -- sixteen
    -- spaces, inside a callback inside the builder -- rather than the pickers'
    -- branch twelve spaces out. The two both open with `if tools2.popout then`,
    -- and the looser pattern ran from the first straight past the classic rebuild
    -- that sits between them.
    local sourceArm = body:match("if tools2%.popout then(.-)\n                else")
    check(sourceArm ~= nil, "pickers: the source dropdown's popout arm is locatable")
    if sourceArm then
        check(sourceArm:find("RefreshCurrentPage", 1, true) == nil,
              "pickers: ...and the one rebuild left on this page is NOT in it")
        check(sourceArm:find("tools2.refreshStates()", 1, true) ~= nil,
              "pickers: ...which runs the state pass instead")
    end
end

-- ============================================================
-- 4. THE THREE ROWS -- census, counts, and the shared strip
-- ============================================================
local HP_SETTINGS = {
    { "checkbox",        "Enable Heal Prediction", "healPredictionEnabled",       30 },
    { "checkbox",        "Show Overheal",          "healPredictionShowOverheal",  30 },
    { "dropdown",        "Display Mode",           "healPredictionMode",          55 },
    { "dropdown",        "Show Heals From",        "healPredictionShowMode",      55 },
    { "texturedropdown", "Texture",                "healPredictionTexture",       55 },
    -- the POPOUT arm's three
    { "colorpicker",     "My Heals Color",         "healPredictionMyColor",       35 },
    { "colorpicker",     "Others' Heals Color",    "healPredictionOthersColor",   35 },
    { "colorpicker",     "Heal Prediction Color",  "healPredictionAllColor",      35 },
    -- ...and the CLASSIC arm's, which are the same widgets built by the db
    { "colorpicker",     "My Heals Color",         "healPredictionMyColor",       35 },
    { "colorpicker",     "Others' Heals Color",    "healPredictionOthersColor",   35 },
    -- ⚠ the single picker's key is a VARIABLE (showModeColorKey), which is the
    -- whole reason the mode change had to rebuild the page in the first place.
    { "colorpicker",     "Heal Prediction Color",  "(none)",                      35 },
    { "dropdown",        "Blend Mode",             "healPredictionBlendMode",     55 },
}

local HP_FLOATING = {
    { "dropdown", "Orientation",  "healPredictionOrientation", 55 },
    { "checkbox", "Reverse Fill", "healPredictionReverse",     30 },
    { "slider",   "Width",        "healPredictionWidth",       55 },
    { "slider",   "Height",       "healPredictionHeight",      55 },
}

local HP_ANCHOR = {
    { "dropdown",    "Anchor",           "healPredictionAnchor",          55 },
    { "slider",      "Offset X",         "healPredictionX",               55 },
    { "slider",      "Offset Y",         "healPredictionY",               55 },
    { "colorpicker", "Background Color", "healPredictionBackgroundColor", 35 },
    -- ⚠ the once-unreachable key keeps its control (see the note in the page).
    { "slider",      "Frame Level",      "healPredictionFrameLevel",      55 },
}

local ROWS = {
    { builder = "BuildHealPredictionSettingsGroup", label = "Heal Prediction",
      boxHeader = "Heal Prediction", box = "settingsGroup", column = "1",
      golden = HP_SETTINGS, countVar = "HEAL_PREDICTION_COUNT", row = "settingsRow",
      content = "settingsContent", summary = "HealPredictionSettingsSummary",
      apply = "ApplyHealPredictionSettings", count = 8 },
    { builder = "BuildHealPredictionFloatingGroup", label = "Floating Bar Position",
      boxHeader = "Floating Bar Position", box = "floatingGroup", column = "1",
      golden = HP_FLOATING, countVar = "HEAL_PREDICTION_FLOATING_COUNT", row = "floatingRow",
      content = "floatingContent", summary = "HealPredictionFloatingSummary",
      apply = "ApplyHealPredictionFloating", count = 4 },
    { builder = "BuildHealPredictionAnchorGroup", label = "Floating Bar Anchor",
      boxHeader = "Floating Bar Anchor", box = "anchorGroup", column = "2",
      golden = HP_ANCHOR, countVar = "HEAL_PREDICTION_ANCHOR_COUNT", row = "anchorRow",
      content = "anchorContent", summary = "HealPredictionAnchorSummary",
      apply = "ApplyHealPredictionAnchor", count = 5 },
}

for _, g in ipairs(ROWS) do
    print("-- Heal Prediction page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())

    -- ONE builder, BOTH layouts: the declaration and the two mounts.
    local calls = 0
    for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, g.label .. ": declared once, mounted twice -- classic box and popout pane")

    -- The classic branch builds the box it always did, with its own header, in
    -- the column it always had.
    check(PAGE:find("local " .. g.box .. " = GUI:CreateSettingsGroup(self.child, 280)", 1, true) ~= nil,
          g.label .. ": the classic 280 box is built")
    check(PAGE:find(g.box .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. g.boxHeader .. '"]), 40)', 1, true) ~= nil,
          g.label .. ": ...under the header it always had (" .. g.boxHeader .. ")")
    check(PAGE:find("Add(" .. g.box .. ", nil, " .. g.column .. ")", 1, true) ~= nil,
          g.label .. ": ...and still goes to column " .. g.column)

    local opts = rowOpts(g.label)
    check(opts ~= "" and opts:find("build", 1, true) ~= nil,
          g.label .. ": the row is handed a pre-built mount")
    check(opts:find("window", 1, true) ~= nil,
          g.label .. ": ...docked outside the settings window")
    check(opts:find("clipTo", 1, true) ~= nil,
          g.label .. ": ...and clipped by the page's own scroll frame, not the window")
    check(opts:find("count%s*=%s*" .. g.countVar) ~= nil,
          g.label .. ": ...and the declared count, not a literal")
    check(opts:find("summary%s*=%s*" .. g.summary) ~= nil,
          g.label .. ": ...with the summary written for it")
    check(PAGE:find("local " .. g.row .. " = healPredBand:AddWidget(GUI:CreatePopoutRow(", 1, true) ~= nil,
          g.label .. ": the row is mounted into the page's one band")

    -- The strip. EVERY key on this page is a per-mode profile key living in
    -- DF.PartyDefaults, so every row gets the amber tick and the Reset Group /
    -- Hold: Defaults footer, and every footer is handed the group's own apply.
    check(PAGE:find("tools.ClaimKeys(" .. g.row .. ", " .. g.content .. ")", 1, true) ~= nil,
          g.label .. ": the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(" .. g.row .. ")", 1, true) ~= nil,
          g.label .. ": ...its amber tick asks about exactly those keys")
    check(PAGE:find("tools.WireFooter(" .. g.row .. ", " .. g.apply .. ")", 1, true) ~= nil,
          g.label .. ": ...and its footer runs the group's own apply")

    -- The count, declared in one place.
    local declared = tonumber(PAGE:match("local " .. g.countVar .. "%s*=%s*(%d+)"))
    check(declared ~= nil, g.label .. ": the page declares the row's count in one place")
    eq(declared, g.count, g.label .. ": ...and it is what the PANE mounts")

    -- ⚠ NO GatePaneFirstChild ANYWHERE ON THIS PAGE, unlike the Resource Bar's.
    -- That repair exists for a group-level `disableChildrenOn`, which skips child
    -- one; this page has never had one -- every widget carries its own disableOn.
    check(body:find("disableChildrenOn", 1, true) == nil,
          g.label .. ": no group gate -- every control carries its own")
end

-- ...and the two counts that are NOT simply the census, spelled out.
print("-- Heal Prediction page: the Settings row's arithmetic")
do
    -- Twelve in the census: five plain controls, SIX pickers (three per layout
    -- arm) and the blend pick. The pane mounts three of the six and skips the
    -- hoisted enable, which is 12 - 3 - 1.
    eq(#HP_SETTINGS - 3 - 1, 8, "settings: the pane's eight is the census less the classic arm and the hoist")
    eq(#HP_FLOATING, 4, "floating position: the pane mounts its whole census")
    eq(#HP_ANCHOR, 5, "floating anchor: ...and so does the anchor pane")
end

-- ============================================================
-- 5. THE HOISTED ENABLE
-- A plain checkbox in classic with every other control on the page carrying
-- `disableOn = not healPredictionEnabled`. The row takes the tick; the builder
-- skips the checkbox; the individual gates stay where they were.
-- ============================================================
print("-- Heal Prediction page: the hoisted enable")
do
    local body = builderBody("BuildHealPredictionSettingsGroup")
    check(body:find("if not tools2.hoistToggle then", 1, true) ~= nil,
          "hoist: the enable checkbox is skipped when the row has hoisted it")
    check(body:find(".keepEnabled = true", 1, true) ~= nil,
          "hoist: ...and in classic it stays live whatever else greys")

    local opts = rowOpts("Heal Prediction")
    check(opts:find('toggle%s*=%s*{%s*key%s*=%s*"healPredictionEnabled"%s*}') ~= nil,
          "hoist: the row's tick is the page's own enable key")
    check(opts:find("onToggle%s*=%s*OnHealPredictionToggle") ~= nil,
          "hoist: ...and a commit that is not a page rebuild")

    -- ☠ THE COMMIT IS NOT A PAGE REBUILD, and it DOES reflow the other panes:
    -- the gate this tick is reaches every control in the two floating panes.
    local commit = PAGE:match("local function OnHealPredictionToggle%(%)(.-)\n            end")
    check(commit ~= nil, "hoist: the popout commit is a named function")
    if commit then
        check(commit:find("RefreshCurrentPage", 1, true) == nil,
              "hoist: ...and never rebuilds the page")
        check(commit:find("DF:UpdateAllFrames()", 1, true) ~= nil,
              "hoist: ...it runs what the suppressed checkbox ran")
        check(commit:find("self:RefreshStates()", 1, true) ~= nil,
              "hoist: ...re-runs the state passes")
        check(commit:find("tools.ReflowMounted()", 1, true) ~= nil,
              "hoist: ...and reflows the open panes, because the gate reaches them")
    end

    check(PAGE:find('tools.RegisterHoistedToggle(settingsRow, L["Enable Heal Prediction"], "healPredictionEnabled", OnHealPredictionToggle)', 1, true) ~= nil,
          "hoist: the hoisted toggle keeps its search entry")
end

-- ============================================================
-- 6. THE FLOATING ROWS' hideOn AND THE PAGE-WIDE GATE
-- ============================================================
print("-- Heal Prediction page: what hides and what greys")
do
    -- ---- ONE predicate, both layouts -----------------------------------
    check(PAGE:find('local function HealPredFloatingHiddenOn(d) return d.healPredictionMode ~= "FLOATING" end', 1, true) ~= nil,
          "hide: the floating rule is named once, at page scope")
    local uses = 0
    for _ in PAGE:gmatch("HealPredFloatingHiddenOn") do uses = uses + 1 end
    eq(uses, 5, "hide: ...declared once and used four times -- two boxes, two rows")

    for _, w in ipairs({ "floatingGroup", "anchorGroup", "floatingRow", "anchorRow" }) do
        check(PAGE:find(w .. ".hideOn = HealPredFloatingHiddenOn", 1, true) ~= nil,
              "hide: " .. w .. " takes the shared rule, never its own copy")
    end
    -- ...and no inline copy of the predicate survives on either side.
    check(PAGE:find('hideOn = function(d) return d.healPredictionMode ~= "FLOATING" end', 1, true) == nil,
          "hide: ...no hand-written duplicate is left behind")

    -- ---- the gate reaches the rows, with the Settings row excepted ------
    check(PAGE:find("local function HealPredOffRow(d) return not (d or db).healPredictionEnabled end", 1, true) ~= nil,
          "gate: the page-wide gate is named once")
    for _, w in ipairs({ "floatingRow", "anchorRow" }) do
        check(PAGE:find(w .. ".disableOn = HealPredOffRow", 1, true) ~= nil,
              "gate: " .. w .. " greys with the feature, as its box's controls always did")
    end
    -- ⚠ THE SETTINGS ROW IS THE EXCEPTION: it carries the gate's own tick, so
    -- greying it would leave no way to turn heal prediction back on.
    check(PAGE:find("settingsRow.disableOn", 1, true) == nil,
          "gate: ...and the row holding the tick is not greyed by it")

    -- ---- the per-control gates stayed inside the builders ---------------
    local gates = 0
    for _ in PAGE:gmatch("disableOn = function%(d%) return not d%.healPredictionEnabled end") do
        gates = gates + 1
    end
    -- Twenty: eleven in the Settings builder (six of them pickers, three per
    -- layout arm), four in Floating Bar Position and five in Floating Bar Anchor.
    eq(gates, 20, "gate: every control on the page still carries the gate it always had")

    -- ---- the display-mode pick routes through the tools -----------------
    local body = builderBody("BuildHealPredictionSettingsGroup")
    check(body:find("self:RefreshStates", 1, true) == nil,
          "gate: the builder never calls the PAGE's RefreshStates from inside a pane")
    local routed = 0
    for _ in PAGE:gmatch("tools2%.refreshStates%(%)") do routed = routed + 1 end
    eq(routed, 3, "gate: the enable, the display mode and the source pick all route through the tools")

    -- Every popout mount declares itself as one.
    local popouts = 0
    for _ in PAGE:gmatch("popout = true,") do popouts = popouts + 1 end
    eq(popouts, 3, "gate: all three popout mounts declare themselves as panes")
end

-- ============================================================
-- 7. ZERO NEW LOCALE STRINGS
-- Every label and summary word already shipped -- the summaries reuse the
-- dropdowns' own vocabulary, which is why those tables moved to page scope, and
-- the popout's always-precise picker labels are ones classic already uses under
-- Split.
-- ============================================================
print("-- Heal Prediction page: every locale string the page asks for already ships")
do
    local ENUS = options_file_source("../DandersFrames/Locales/enUS.lua")
    local seen = {}
    for key in PAGE:gmatch('L%["([^"]+)"%]') do seen[key] = true end
    local missing = 0
    for key in pairs(seen) do
        if not ENUS:find('L["' .. key .. '"] = true', 1, true) then
            missing = missing + 1
            check(false, "locale: enUS ships L[\"" .. key .. "\"]")
        end
    end
    eq(missing, 0, "locale: the page adds no new string")
end
