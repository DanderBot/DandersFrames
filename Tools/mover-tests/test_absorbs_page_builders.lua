local NS = ...

-- ============================================================
-- ABSORBS PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Auras.lua
-- ------------------------------------------------------------
-- Bars > Absorbs is the sweep's first LOOSE-WIDGET page. Every page converted
-- before it built BOXES in classic, so a builder could be handed the box and
-- call `group:AddWidget(w, h)` in both layouts. There is no box here: the two
-- collapsible sections hold thirty-six widgets added STRAIGHT onto the page,
-- each with its own slot height and its own COLUMN.
--
-- So the one thing that differs between the layouts is named and handed in --
-- classic passes AddToSection, a pane passes a closure that drops the column and
-- mounts into its group -- and each section's pile becomes ONE feature row:
--
--   "Absorb Shield"   Absorb Shield   (21 widgets, no tick)
--   "Heal Absorb"     Heal Absorb     (15 widgets, no tick)
--
-- ☠ THREE THINGS THIS SUITE IS HERE TO PIN:
--
--   1. THE `add` SEAM. Section 4 asserts each builder takes tools2.add, that the
--      classic arm hands it AddToSection, and that the popout arm hands it a
--      closure onto the pane's group -- so "classic renders as it did" is
--      structural rather than a promise.
--   2. THE COLUMNS SURVIVE. The census below records the COLUMN of every widget
--      as well as its height, taken from the pre-change source. A builder that
--      quietly moved the floating header out of column 2 fails here.
--   3. THE COLLAPSIBLE SECTIONS SURVIVE IN BOTH LAYOUTS, and the bands go in
--      THROUGH them -- the Health Bar page's rule, for two of its three reasons
--      (a section persists its fold per title; Panel.lua calls a section the
--      page's second level for parallel sub-features).
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY -- it is welded to the panel (a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db) -- so this file
-- does what every page-builder suite before it does: it reads the page's SOURCE
-- and asserts against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each extracted builder -- kind, L key, db key, slot
--     height and column, in order -- taken from the PRE-CHANGE source.
--   ✓ that ONE builder serves both layouts.
--   ✓ that each declared row COUNT matches what its pane mounts.
--   ✓ that the two mode dropdowns stopped calling the PAGE's RefreshStates from
--     inside a pane and route through tools2.refreshStates instead.
--   ✓ that both summaries read their words out of the mode table the control
--     itself offers, and that the page adds NO new locale string.
--   ✗ nothing about runtime behaviour -- the callbacks, the greying and the
--     summaries are read by eye and by the in-game checklist.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Auras.lua")

-- ---- the census reader (the Health Bar page's, plus the COLUMN) ----
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateTextureDropdown = "texturedropdown",
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

-- ⚠ THE HEIGHT AND THE COLUMN COME OUT TOGETHER, because on this page they are
-- written together: `add(<widget>, <height>, <column>)`. Reading only the height
-- would let a widget slide from column 2 to column 1 without failing anything.
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
        local h, c  = chunk:match('%)%s*,%s*(%d+)%s*,%s*(%d+)%s*%)')
        out[#out + 1] = { kind = at.kind, label = label, key = key,
                          height = tonumber(h), column = tonumber(c) }
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
            eq(g.column, e[5], string.format("%s: row %d column", tag, i))
        end
    end
end

-- The page, scoped by its own two ends: Auras.lua holds a dozen pages, and a
-- bare band on one of the others is not this pass's business.
local PAGE
do
    -- ⚠ ANCHORED ON THE SUB-TAB, NOT ON `L["Absorbs"], "bars_absorb")` -- that
    -- string's first occurrence is inside the COPY BUTTON, which would leave the
    -- button itself half outside the slice and unassertable.
    local a = SRC:find('local pageAbsorb = CreateSubTab("bars", "bars_absorb", L["Absorbs"])', 1, true)
    local b = SRC:find("-- Bars > Heal Prediction", 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Absorbs page builder is locatable by its own ends")
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

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED MACHINERY, AND ITS TWO BANDS ARE HEADERLESS
-- ============================================================
print("-- Absorbs page: the shared popout machinery and the two bands")
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

    -- ---- two bands, one per section, both chromeless -------------------
    for _, b in ipairs({ "absorbBand", "healAbsorbBand" }) do
        check(PAGE:find(b .. "     = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil
           or PAGE:find(b .. " = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
              "bands: " .. b .. " is chromeless, at the width the layout pass will give it")
        -- ☠ AND NEITHER CARRIES A HEADER. The collapsible section bar directly
        -- above each band already names it; a header under it would say the same
        -- word twice. (The Fading page's sortBand rule, kept by the Health Bar
        -- page for the same reason.)
        check(PAGE:find(b .. ":AddWidget(GUI:CreateHeader(", 1, true) == nil,
              "bands: ..." .. b .. " carries no header of its own")
    end

    -- ...and neither band exists in classic, where `tools` is nil.
    check(PAGE:find("local absorbBand, healAbsorbBand", 1, true) ~= nil,
          "bands: both are declared before the layout branch and built only under tools")
    check(PAGE:find("if tools then", 1, true) ~= nil,
          "bands: ...so classic builds neither")
end

-- ============================================================
-- 2. THE DROPDOWN VOCABULARY MOVED TO PAGE SCOPE
-- The rows print the chosen mode as their SUMMARY, and a summary is written
-- outside the group's builder -- so the word has to come out of the same table
-- the dropdown offers, or a row could say one thing while the control behind it
-- says another.
--
-- ⚠ Orientation and Anchor move for a SECOND reason: they were declared in the
-- absorb-shield block and READ by the heal-absorb one, which is fine while both
-- are straight-line page code and is not once each is a closure of its own.
-- ============================================================
print("-- Absorbs page: the dropdown vocabulary at page scope")
do
    local VOCAB = {
        { "modeOptions",     'ATTACHED_OVERFLOW = L["Attached + Overflow"]' },
        { "healModeOptions", 'OVERLAY = L["Overlay (on health bar)"]' },
        { "orientOptions",   'HORIZONTAL= L["Horizontal"]' },
        { "anchorOptions",   'BOTTOMRIGHT= L["Bottom Right"]' },
    }
    for _, pair in ipairs(VOCAB) do
        local decls = 0
        for _ in PAGE:gmatch("local " .. pair[1] .. " = {") do decls = decls + 1 end
        eq(decls, 1, "vocab: " .. pair[1] .. " is declared exactly once")
        -- ...and ABOVE every builder, so a closure sees the real table rather
        -- than the nil upvalue a later declaration would leave it.
        local at = PAGE:find("local " .. pair[1] .. " = {", 1, true)
        local firstBuilder = PAGE:find("local function BuildAbsorbShieldGroup(tools2)", 1, true)
        check(at ~= nil and firstBuilder ~= nil and at < firstBuilder,
              "vocab: ..." .. pair[1] .. " is declared above the first builder")
        local decl = PAGE:match("local " .. pair[1] .. " = {(.-)}")
        check(decl ~= nil and decl:find(pair[2], 1, true) ~= nil,
              "vocab: ..." .. pair[1] .. " still offers " .. pair[2])
    end

    -- The texture resolver, shared by both summaries: the addon's own media
    -- display-name function, which is the one the texture dropdown prints on its
    -- own button -- so a row and the control behind it cannot disagree.
    check(PAGE:find("local function TextureName(path)", 1, true) ~= nil,
          "vocab: the texture-name resolver is a named page-scope helper")
    check(PAGE:find("DF:GetTextureNameFromPath(path)", 1, true) ~= nil,
          "vocab: ...and it is the addon's own resolver, not a path split")

    -- ⚠ THE FOUR TABLES THAT DID NOT MOVE. The two blend tables, the clamp modes
    -- and the overshield styles are read by nothing outside their own builder, so
    -- they stay where the dropdown that offers them is built.
    for _, name in ipairs({ "blendOptions", "healBlendOptions",
                            "absorbClampOptions", "absorbOvershieldStyleOptions" }) do
        local at = PAGE:find("local " .. name .. " = {", 1, true)
        local firstBuilder = PAGE:find("local function BuildAbsorbShieldGroup(tools2)", 1, true)
        check(at ~= nil and firstBuilder ~= nil and at > firstBuilder,
              "vocab: " .. name .. " stays inside the builder that offers it")
    end
end

-- ============================================================
-- 3. THE TWO MODE DROPDOWNS -- the page's own RefreshStates, routed
-- Picking a display mode hides and shows controls inside the SAME group, so the
-- pane changes height when it is clicked and the panel around it has to be told.
-- Classic paid for that with self:RefreshStates() -- NOT GUI:RefreshCurrentPage,
-- so there is no rebuild to unpick -- and tools2.refreshStates IS that call in
-- classic, while in a pane it is ReflowPane plus the page's own pass.
-- ============================================================
print("-- Absorbs page: the mode dropdowns route through the tools")
do
    for _, b in ipairs({ "BuildAbsorbShieldGroup", "BuildHealAbsorbGroup" }) do
        local body = builderBody(b)
        check(body:find("GUI:RefreshCurrentPage", 1, true) == nil,
              "gate: " .. b .. " never rebuilds the page from inside itself")
        check(body:find("self:RefreshStates", 1, true) == nil,
              "gate: ..." .. b .. " never calls the PAGE's RefreshStates from inside a pane")
        check(body:find("tools2.refreshStates()", 1, true) ~= nil,
              "gate: ..." .. b .. "'s display mode routes its state pass through the tools")
    end

    local routed = 0
    for _ in PAGE:gmatch("tools2%.refreshStates%(%)") do routed = routed + 1 end
    eq(routed, 2, "gate: exactly two callbacks route their state pass through the tools")

    -- Every popout mount declares itself as one.
    local popouts = 0
    for _ in PAGE:gmatch("popout = true,") do popouts = popouts + 1 end
    eq(popouts, 2, "gate: both popout mounts declare themselves as panes")
end

-- ============================================================
-- 4. THE TWO ROWS -- census, the `add` seam, and no tick on either
-- ☠ NEITHER BAR HAS AN ENABLE KEY. The Display Mode dropdown IS the master and
-- neither list of modes has an off, so each row is a way in and nothing else --
-- the Out of Range row's judgement, reached by a different route.
-- ============================================================
local ABSORB_SHIELD = {
    { "dropdown",        "Display Mode",         "absorbBarMode",              55, 1 },
    { "texturedropdown", "Texture",              "absorbBarTexture",           55, 1 },
    { "colorpicker",     "Bar Color",            "absorbBarColor",             35, 1 },
    { "dropdown",        "Blend Mode",           "absorbBarBlendMode",         55, 1 },
    { "checkbox",        "Reverse Overlay Fill", "absorbBarOverlayReverse",    25, 1 },
    { "dropdown",        "Clamp Mode",           "absorbBarAttachedClampMode", 55, 1 },
    { "checkbox",        "Show Overshield Glow", "absorbBarShowOvershield",    25, 1 },
    { "dropdown",        "Glow Style",           "absorbBarOvershieldStyle",   55, 1 },
    { "colorpicker",     "Glow Color",           "absorbBarOvershieldColor",   35, 1 },
    { "slider",          "Glow Alpha",           "absorbBarOvershieldAlpha",   55, 1 },
    { "checkbox",        "Reverse Position",     "absorbBarOvershieldReverse", 25, 1 },
    -- ⚠ THE SWEEP'S FIRST HEADER INSIDE A PANE, and it keeps column 2 in classic.
    { "header",          "Floating Bar Position", "(none)",                    45, 2 },
    { "dropdown",        "Orientation",          "absorbBarOrientation",       55, 1 },
    { "checkbox",        "Reverse Fill",         "absorbBarReverse",           25, 2 },
    { "slider",          "Width",                "absorbBarWidth",             55, 1 },
    { "slider",          "Height",               "absorbBarHeight",            55, 1 },
    { "dropdown",        "Anchor",               "absorbBarAnchor",            55, 1 },
    { "slider",          "Offset X",             "absorbBarX",                 55, 1 },
    { "slider",          "Offset Y",             "absorbBarY",                 55, 1 },
    { "colorpicker",     "Background Color",     "absorbBarBackgroundColor",   35, 2 },
    { "slider",          "Frame Level",          "absorbBarFrameLevel",        55, 1 },
}

local HEAL_ABSORB = {
    { "label",           "Shows effects that reduce incoming healing (like Necrotic stacks).",
                                                 "(none)",                       25, 1 },
    { "dropdown",        "Display Mode",         "healAbsorbBarMode",            55, 1 },
    { "texturedropdown", "Texture",              "healAbsorbBarTexture",         55, 1 },
    { "colorpicker",     "Bar Color",            "healAbsorbBarColor",           35, 1 },
    { "dropdown",        "Blend Mode",           "healAbsorbBarBlendMode",       55, 1 },
    { "checkbox",        "Reverse Overlay Fill", "healAbsorbBarOverlayReverse",  25, 1 },
    { "header",          "Floating Bar Position", "(none)",                      45, 2 },
    { "dropdown",        "Orientation",          "healAbsorbBarOrientation",     55, 1 },
    { "checkbox",        "Reverse Fill",         "healAbsorbBarReverse",         25, 2 },
    { "slider",          "Width",                "healAbsorbBarWidth",           55, 1 },
    { "slider",          "Height",               "healAbsorbBarHeight",          55, 1 },
    { "dropdown",        "Anchor",               "healAbsorbBarAnchor",          55, 1 },
    { "slider",          "Offset X",             "healAbsorbBarX",               55, 1 },
    { "slider",          "Offset Y",             "healAbsorbBarY",               55, 1 },
    { "colorpicker",     "Background Color",     "healAbsorbBarBackgroundColor", 35, 2 },
}

local ROWS = {
    { builder = "BuildAbsorbShieldGroup", label = "Absorb Shield", golden = ABSORB_SHIELD,
      countVar = "ABSORB_SHIELD_COUNT", row = "absorbRow", band = "absorbBand",
      summary = "AbsorbShieldSummary", apply = "ApplyAbsorbShield",
      mount = "absorbMount", content = "absorbContent" },
    { builder = "BuildHealAbsorbGroup", label = "Heal Absorb", golden = HEAL_ABSORB,
      countVar = "HEAL_ABSORB_COUNT", row = "healAbsorbRow", band = "healAbsorbBand",
      summary = "HealAbsorbSummary", apply = "ApplyHealAbsorb",
      mount = "healMount", content = "healContent" },
}

for _, g in ipairs(ROWS) do
    print("-- Absorbs page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())

    -- ---- ONE builder, BOTH layouts: the declaration and the two mounts ----
    local calls = 0
    for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, g.label .. ": declared once, mounted twice -- classic page and popout pane")

    -- ---- THE `add` SEAM -------------------------------------------------
    -- ☠ THE ONE THING THAT DIFFERS BETWEEN THE LAYOUTS, named and handed in.
    -- Classic gets AddToSection, which is what the page always called; the pane
    -- gets a closure that DROPS the column and mounts into its own group.
    check(body:find("local add, parent = tools2.add, tools2.parent", 1, true) ~= nil,
          g.label .. ": the builder takes its add from the tools, not a group")
    check(body:find("group:AddWidget", 1, true) == nil,
          g.label .. ": ...and never reaches for a group of its own")
    check(PAGE:find("add = AddToSection,", 1, true) ~= nil,
          g.label .. ": classic hands it the page's own AddToSection")
    check(PAGE:find("add = function(w, h) return group:AddWidget(w, h) end,", 1, true) ~= nil,
          g.label .. ": ...and a pane hands it a closure that drops the column")

    -- ---- the row --------------------------------------------------------
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
    check(PAGE:find("local " .. g.row .. " = " .. g.band .. ":AddWidget(GUI:CreatePopoutRow(", 1, true) ~= nil,
          g.label .. ": the row is mounted into the " .. g.band)

    -- ---- the strip ------------------------------------------------------
    -- Every key on this page is a per-mode profile key living in
    -- DF.PartyDefaults, so both rows get the amber tick and the Reset Group /
    -- Hold: Defaults footer, and each footer is handed the group's own apply.
    check(PAGE:find("tools.ClaimKeys(" .. g.row .. ", " .. g.content .. ")", 1, true) ~= nil,
          g.label .. ": the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(" .. g.row .. ")", 1, true) ~= nil,
          g.label .. ": ...its amber tick asks about exactly those keys")
    check(PAGE:find("tools.WireFooter(" .. g.row .. ", " .. g.apply .. ")", 1, true) ~= nil,
          g.label .. ": ...and its footer runs the group's own apply")

    -- ---- no tick, and nothing hoisted -----------------------------------
    check(body:find("hoistToggle", 1, true) == nil,
          g.label .. ": the builder has no hoist branch, because there is no enable to hoist")
    check(opts:find("toggle", 1, true) == nil,
          g.label .. ": the row declares no toggle")
    check(opts:find("onToggle", 1, true) == nil,
          g.label .. ": ...and so no commit either")

    -- ---- the count is the whole census ----------------------------------
    local declared = tonumber(PAGE:match("local " .. g.countVar .. "%s*=%s*(%d+)"))
    check(declared ~= nil, g.label .. ": the page declares the row's count in one place")
    eq(declared, #g.golden, g.label .. ": ...the whole census, nothing hoisted out of it")
end

-- ============================================================
-- 5. THE SECTIONS SURVIVE, AND THE BANDS GO IN THROUGH THEM
-- ============================================================
print("-- Absorbs page: the collapsible sections and the page's own order")
do
    for _, s in ipairs({
        { "absorbSection",     "Absorb Shield" },
        { "healAbsorbSection", "Heal Absorb" },
    }) do
        check(PAGE:find("local " .. s[1] .. ' = Add(GUI:CreateCollapsibleSection(self.child, L["' .. s[2] .. '"], true), 36, "both")', 1, true) ~= nil,
              "sections: " .. s[2] .. " is still a collapsible section, in both layouts")
    end

    -- ---- the bands go in THROUGH the section, so a fold hides them ------
    for _, b in ipairs({ "absorbBand", "healAbsorbBand" }) do
        check(PAGE:find('AddToSection(' .. b .. ', nil, "both")', 1, true) ~= nil,
              "sections: " .. b .. " is registered to its section, so folding hides its row")
        check(PAGE:find('Add(' .. b .. ', nil, "both")', 1, true) == nil,
              "sections: ..." .. b .. " never bypasses the section with a bare Add")
    end

    -- ---- the section helper and the between-sections spacer survive -----
    check(PAGE:find("local function AddToSection(widget, height, col)", 1, true) ~= nil,
          "sections: the page keeps its own section-registering Add")
    local spacers = 0
    for _ in PAGE:gmatch('AddSpace%(GUI%.Space%.section, "both"%)') do spacers = spacers + 1 end
    eq(spacers, 1, "page: the one between-section spacer survives")

    -- ---- the copy button is untouched -----------------------------------
    check(PAGE:find('CreateCopyButton(self.child, {"absorbBar", "healAbsorb"}, L["Absorbs"], "bars_absorb")', 1, true) ~= nil,
          "page: the copy button still covers both bars")

    -- ---- and no 280 box was invented ------------------------------------
    -- ☠ THIS PAGE NEVER HAD ONE. Every widget went straight onto the page, and
    -- the conversion did not quietly wrap the classic arm in a box to make the
    -- builders easier to write -- that would have changed what classic renders.
    check(PAGE:find("GUI:CreateSettingsGroup(self.child, 280", 1, true) == nil,
          "page: classic still builds no settings box at all")
end

-- ============================================================
-- 6. ZERO NEW LOCALE STRINGS
-- Every label and every summary word on this page already shipped: the two
-- summaries reuse the mode dropdowns' own vocabulary, which is the whole reason
-- those tables moved to page scope.
-- ============================================================
print("-- Absorbs page: every locale string the page asks for already ships")
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
