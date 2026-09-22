local NS = ...

-- ============================================================
-- HEAL PREDICTION PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Auras.lua
-- ------------------------------------------------------------
-- Bars > Heal Prediction: three 280 boxes in classic, three of the Debuff Bar's
-- collapsible CARDS in modern, in two page columns:
--
--   column 1   Heal Prediction        (the page's master switch, in its body)
--   column 2   Floating Bar Position  (hidden unless the bar is floating)
--              Floating Bar Anchor    (hidden unless the bar is floating)
--
-- ☠ THREE THINGS THIS SUITE IS HERE TO PIN:
--
--   1. THE COLOUR PICKERS BRANCH ON LAYOUT. Classic decides the picker SET at
--      build time from the db -- Split builds two, every other mode builds one
--      bound to that mode's key -- so changing the source has to REBUILD THE
--      PAGE. Modern builds all three and gates them with hideOn instead, so a
--      pinned panel is never slammed shut by a rebuild. Section 3.
--   2. THE FLOATING hideOn IS ONE NAMED PREDICATE handed to the classic boxes
--      and to the cards alike. Section 6.
--   3. ENABLE HEAL PREDICTION IS THE PAGE GATE and stays in the first card's
--      body, as Show Debuffs does on the Debuff Bar -- no header tick, no
--      hoistToggle. Section 5.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY -- it is welded to the panel (a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db) -- so this file
-- reads the page's SOURCE and asserts against it.
--
--   ✓ the widget CENSUS of each builder -- kind, L key, db key and slot height,
--     in order -- taken from the pre-card source, BOTH arms of the picker branch
--     included, so classic renders what it always did.
--   ✓ that ONE builder serves both layouts, and the card hands it EXACTLY what
--     classic hands it.
--   ✓ each card's column, stable collapse key, summary, grey gate, hide gate and
--     pin; the two opt-ins (two per row, quiet captions); Expand/Collapse All.
--   ✗ nothing about runtime behaviour -- the folding, the two-per-row flow and
--     the greying are read in game.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Auras.lua"):gsub("\r\n", "\n")

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

-- ONE CARD'S BLOCK: its OpenSection call, the builder mount under it and the
-- CloseSection that puts its band in, flattened. `call` is just the OpenSection
-- call -- where the pin (a builder argument) and a tick would be declared.
local function sectionBlock(labelKey)
    local a = PAGE:find('OpenSection(L["' .. labelKey .. '"]', 1, true)
    check(a ~= nil, "source: a card is opened for " .. labelKey)
    if not a then return "", "" end
    local b = PAGE:find("CloseSection(band)", a, true)
    check(b ~= nil, "source: ..." .. labelKey .. "'s band is closed after its controls")
    local block = PAGE:sub(a, (b or a) + #"CloseSection(band)"):gsub("%s+", " ")
    local m = block:find("({ group = band,", 1, true)
    local call = m and block:sub(1, m) or block
    call = call:gsub("Build[%w]+%($", "")
    return block, call
end

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED CARD HELPER, AND THE POPOUT FURNITURE IS GONE
-- ============================================================
print("-- Heal Prediction page: the shared card helper")
do
    check(PAGE:find("local classicLayout = DF:IsClassicSettingsLayout()", 1, true) ~= nil,
          "tools: the page asks which layout it is building")
    check(PAGE:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true) ~= nil,
          "tools: ...and takes the shared machinery unconditionally")
    check(PAGE:find("_popoutHolders", 1, true) == nil,
          "tools: the page never manages the popout holders itself")

    -- ☠ NO ROWS LEFT, and none of their furniture: the band, the counts, the
    -- claims, the footers, the hoisted-toggle repair, the named applies.
    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "tools.PopoutContent(", "tools.ClaimKeys(",
                            "tools.WireModifiedTick(", "tools.WireFooter(",
                            "tools.RegisterHoistedToggle(", "healPredBand", "_COUNT = ",
                            "footerStrip", "inline = true", "popout = true,",
                            "OnHealPredictionToggle", "ApplyHealPrediction" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end

    -- The Debuff Bar's forward, opt-ins and all.
    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: every card goes through the shared helper, two per row with quiet captions")
    check(PAGE:find("local function CloseSection(band)\n            tools.CloseSection(Add, band)\n        end", 1, true) ~= nil,
          "sections: ...and closes through the shared helper too")

    -- Expand All / Collapse All, once, at the top, spanning both columns.
    local n = 0
    for _ in PAGE:gmatch('Add%(tools%.SectionControls%(self%.child%), 24, "both"%)') do n = n + 1 end
    eq(n, 1, "bulk: the page adds the Expand/Collapse pair once, spanning both columns")
    local stripAt = PAGE:find("tools.SectionControls", 1, true)
    local firstCard = PAGE:find("OpenSection(L[", 1, true)
    check(stripAt and firstCard and stripAt < firstCard, "bulk: ...above the first card")

    -- No "N settings" count anywhere.
    check(PAGE:find("count%s*=%s*[%w_]") == nil,
          "counts: no card or row declares a settings count")
end

-- ============================================================
-- 2. THE DROPDOWN VOCABULARY AT PAGE SCOPE
-- A card prints the chosen value as its SUMMARY, written outside the builder --
-- so the word has to come out of the same table the dropdown offers.
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
    local showDecl = PAGE:match("local showModeOptions = {(.-)\n        }")
    check(showDecl ~= nil and showDecl:find('_order = { "ALL", "MINE", "OTHERS", "SPLIT" }', 1, true) ~= nil,
          "vocab: ...and showModeOptions keeps the reading order of its four sources")
    local at = PAGE:find("local blendOptions = {", 1, true)
    local firstBuilder = PAGE:find("local function BuildHealPredictionSettingsGroup(tools2)", 1, true)
    check(at ~= nil and firstBuilder ~= nil and at > firstBuilder,
          "vocab: blendOptions stays inside the builder that offers it")
end

-- ============================================================
-- 3. THE LAYOUT-CONDITIONAL COLOUR PICKERS
-- ============================================================
print("-- Heal Prediction page: the colour pickers, one set per layout")
do
    local body = builderBody("BuildHealPredictionSettingsGroup")

    -- ☠ MODERN, NOT "A PANE": the card on the page and its pinned panel both
    -- take the three-picker arm, so neither needs a rebuild.
    check(body:find("if tools2.popout then", 1, true) == nil,
          "pickers: the branch is no longer keyed on being a pane")
    local arms = 0
    for _ in body:gmatch("if not classicLayout then") do arms = arms + 1 end
    eq(arms, 2, "pickers: the picker set and the source callback both branch on the layout")

    for _, p in ipairs({
        { "My Heals Color",       "healPredictionMyColor" },
        { "Others' Heals Color",  "healPredictionOthersColor" },
        { "Heal Prediction Color","healPredictionAllColor" },
    }) do
        check(body:find('GUI:CreateColorPicker(parent, L["' .. p[1] .. '"], db, "' .. p[2] .. '"', 1, true) ~= nil,
              "pickers: modern builds " .. p[1] .. " bound to " .. p[2])
    end
    check(body:find('allColor.hideOn = function(d) return d.healPredictionShowMode ~= "ALL" end', 1, true) ~= nil,
          "pickers: ...and the All swatch shows only for All Incoming")
    check(body:find('return d.healPredictionShowMode ~= "SPLIT" and d.healPredictionShowMode ~= "MINE"', 1, true) ~= nil,
          "pickers: ...My Heals for Split and Mine")
    check(body:find('return d.healPredictionShowMode ~= "SPLIT" and d.healPredictionShowMode ~= "OTHERS"', 1, true) ~= nil,
          "pickers: ...and Others' Heals for Split and Others")

    check(body:find('if db.healPredictionShowMode == "SPLIT" then', 1, true) ~= nil,
          "pickers: classic still decides its picker set at build time, from the db")
    check(body:find('local showModeColorKey = (db.healPredictionShowMode == "ALL" and "healPredictionAllColor")', 1, true) ~= nil,
          "pickers: ...and still binds its single picker to the mode's own key")

    local rebuilds = 0
    for _ in PAGE:gmatch("GUI:RefreshCurrentPage%(%)") do rebuilds = rebuilds + 1 end
    eq(rebuilds, 1, "pickers: exactly one page rebuild left on this page")
    local sourceArm = body:match("if not classicLayout then(.-)\n                else")
    check(sourceArm ~= nil, "pickers: the source dropdown's modern arm is locatable")
    if sourceArm then
        check(sourceArm:find("RefreshCurrentPage", 1, true) == nil,
              "pickers: ...and the one rebuild left on this page is NOT in it")
        check(sourceArm:find("tools2.refreshStates()", 1, true) ~= nil,
              "pickers: ...which runs the state pass instead")
    end
end

-- ============================================================
-- 4. THE THREE CARDS -- census, classic box, card
-- ============================================================
local HP_SETTINGS = {
    { "checkbox",        "Enable Heal Prediction", "healPredictionEnabled",       30 },
    { "checkbox",        "Show Overheal",          "healPredictionShowOverheal",  30 },
    { "dropdown",        "Display Mode",           "healPredictionMode",          55 },
    { "dropdown",        "Show Heals From",        "healPredictionShowMode",      55 },
    { "texturedropdown", "Texture",                "healPredictionTexture",       55 },
    -- the MODERN arm's three
    { "colorpicker",     "My Heals Color",         "healPredictionMyColor",       35 },
    { "colorpicker",     "Others' Heals Color",    "healPredictionOthersColor",   35 },
    { "colorpicker",     "Heal Prediction Color",  "healPredictionAllColor",      35 },
    -- ...and the CLASSIC arm's, which are the same widgets built by the db
    { "colorpicker",     "My Heals Color",         "healPredictionMyColor",       35 },
    { "colorpicker",     "Others' Heals Color",    "healPredictionOthersColor",   35 },
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
    { "slider",      "Frame Level",      "healPredictionFrameLevel",      55 },
}

-- label, stable collapse key, card column, classic box and column, summary;
-- `dim` = header greys with the page gate, `hide` = the floating gate on both
-- halves, `pin` = passes its builder (decides how the bar LOOKS).
local CARDS = {
    { label = "Heal Prediction",       key = "healpred_settings", col = 1, box = "settingsGroup", classicCol = "1",
      builder = "BuildHealPredictionSettingsGroup", golden = HP_SETTINGS,
      summary = "HealPredictionCardSummary", pin = true },
    { label = "Floating Bar Position", key = "healpred_floating", col = 2, box = "floatingGroup", classicCol = "1",
      builder = "BuildHealPredictionFloatingGroup", golden = HP_FLOATING,
      summary = "HealPredictionFloatingSummary", dim = true, hide = true, pin = true },
    { label = "Floating Bar Anchor",   key = "healpred_anchor",   col = 2, box = "anchorGroup",   classicCol = "2",
      builder = "BuildHealPredictionAnchorGroup", golden = HP_ANCHOR,
      summary = "HealPredictionAnchorSummary", dim = true, hide = true, pin = true },
}

for _, g in ipairs(CARDS) do
    print("-- Heal Prediction page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())

    -- ONE builder, BOTH layouts: the declaration, the classic box's mount and
    -- the card's (the pin's panel copy is built by the shared helper).
    local calls = 0
    for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, g.label .. ": declared once, mounted twice -- classic box and card")

    check(PAGE:find("local " .. g.box .. " = GUI:CreateSettingsGroup(self.child, 280)", 1, true) ~= nil,
          g.label .. ": the classic 280 box is built")
    check(PAGE:find(g.box .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. g.label .. '"]), 40)', 1, true) ~= nil,
          g.label .. ": ...under the header it always had")
    check(PAGE:find("Add(" .. g.box .. ", nil, " .. g.classicCol .. ")", 1, true) ~= nil,
          g.label .. ": ...and still goes to column " .. g.classicCol)

    local block, call = sectionBlock(g.label)
    check(block:find('OpenSection(L["' .. g.label .. '"], "' .. g.key .. '", ' .. g.col .. ', ' .. g.summary, 1, true) ~= nil,
          g.label .. ": a card keyed " .. g.key .. " in column " .. g.col .. ", printing its summary")
    eq(call:find("HealPredOffRow", 1, true) ~= nil, g.dim == true,
       g.label .. (g.dim and ": its header greys with the page gate" or ": holds the page gate, so it never greys with it"))
    eq(call:find("HealPredFloatingHiddenOn", 1, true) ~= nil, g.hide == true,
       g.label .. (g.hide and ": hides, header and band together, unless the bar floats" or ": carries no hide gate"))
    eq(call:find(g.builder, 1, true) ~= nil, g.pin == true,
       g.label .. (g.pin and ": pinnable, from its own builder" or ": grows no pin"))
    check(call:find('key = "', 1, true) == nil, g.label .. ": no header tick")

    local mount = g.builder .. "({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end, })"
    check(block:find(mount, 1, true) ~= nil, g.label .. ": mounts the builder exactly as classic does")
end

-- ============================================================
-- 5. THE MASTER SWITCH STAYS IN THE BODY
-- ============================================================
print("-- Heal Prediction page: the page gate stays in the first card")
do
    local body = builderBody("BuildHealPredictionSettingsGroup")
    check(body:find('GUI:CreateCheckbox(parent, L["Enable Heal Prediction"], db, "healPredictionEnabled"', 1, true) ~= nil,
          "gate: the builder still builds Enable Heal Prediction")
    check(body:find(".keepEnabled = true", 1, true) ~= nil,
          "gate: ...and it stays live whatever else greys")
    check(PAGE:find("hoistToggle = true", 1, true) == nil,
          "gate: no card asks its builder to skip the enable -- it is never hoisted")
    -- Shut, the card says Off while the bar is off.
    local s = PAGE:match("local function HealPredictionCardSummary%(d%)(.-)\n        end")
    check(s ~= nil and s:find('if d and not d.healPredictionEnabled then return L["Off"] end', 1, true) ~= nil
      and s:find("return HealPredictionSettingsSummary(d)", 1, true) ~= nil,
          "gate: the first card's corner says Off while the bar is off, its summary otherwise")
end

-- ============================================================
-- 6. WHAT HIDES AND WHAT GREYS
-- ============================================================
print("-- Heal Prediction page: what hides and what greys")
do
    check(PAGE:find('local function HealPredFloatingHiddenOn(d) return d.healPredictionMode ~= "FLOATING" end', 1, true) ~= nil,
          "hide: the floating rule is named once, at page scope")
    for _, w in ipairs({ "floatingGroup", "anchorGroup" }) do
        check(PAGE:find(w .. ".hideOn = HealPredFloatingHiddenOn", 1, true) ~= nil,
              "hide: classic's " .. w .. " takes the shared rule")
    end
    check(PAGE:find('hideOn = function(d) return d.healPredictionMode ~= "FLOATING" end', 1, true) == nil,
          "hide: ...no hand-written duplicate is left behind")
    check(PAGE:find("local function HealPredOffRow(d) return not (d or db).healPredictionEnabled end", 1, true) ~= nil,
          "gate: the page-wide gate is named once")

    local gates = 0
    for _ in PAGE:gmatch("disableOn = function%(d%) return not d%.healPredictionEnabled end") do
        gates = gates + 1
    end
    -- Twenty: eleven in the Settings builder (six of them pickers, three per
    -- layout arm), four in Floating Bar Position and five in Floating Bar Anchor.
    eq(gates, 20, "gate: every control on the page still carries the gate it always had")

    local body = builderBody("BuildHealPredictionSettingsGroup")
    check(body:find("self:RefreshStates", 1, true) == nil,
          "gate: the builder never calls the PAGE's RefreshStates -- a pinned panel's copy reflows itself")
    local routed = 0
    for _ in PAGE:gmatch("tools2%.refreshStates%(%)") do routed = routed + 1 end
    eq(routed, 3, "gate: the enable, the display mode and the source pick all route through the tools")

    -- The order, which is also the one-column fold's order.
    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "), "Heal Prediction | Floating Bar Position | Floating Bar Anchor",
       "order: the three cards open in the order the classic boxes read")
end

-- ============================================================
-- 7. ZERO NEW LOCALE STRINGS
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
