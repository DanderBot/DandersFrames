local NS = ...

-- ============================================================
-- PET FRAMES PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Options.lua
-- ------------------------------------------------------------
-- Display > Pet Frames is TEN groups. Eight become feature rows in three bands;
-- two stay inline, wearing the band skin:
--
--   Pet Frame Settings      INLINE -- the page-wide enable plus a blurb. Hoisting
--                           petEnabled would leave a pane holding nothing but the
--                           paragraph, and the key gates all eight rows, so no one
--                           row can speak for it
--   Layout Mode             INLINE -- one dropdown and a sentence, and the
--                           dropdown REBUILDS the page (it changes which groups
--                           exist), which a pane cannot host
--   Group Settings          ROW, grouped mode only, no tick
--   Size                    ROW, no tick
--   Position                ROW, attached mode only, no tick
--   Appearance              ROW, no tick
--   Border                  ROW, hoisted `petShowBorder` (CreateBorderControls'
--                           noShowToggle)
--   Health Bar              ROW, no tick
--   Name Text               ROW, no tick
--   Health Text             ROW, no tick
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db -- so this file
-- does what test_fading_page_builders / test_tooltips_page_builders do: it reads
-- the page's SOURCE and asserts against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each extracted builder -- kind, L key, db key and
--     slot height, in order -- taken from the PRE-CHANGE source, so a builder
--     that quietly dropped a control or renamed a key fails here. This is also
--     the evidence that CLASSIC RENDERS AS IT DID: the classic branch mounts the
--     same builder into the same 280 box in the same column.
--   ✓ that ONE builder serves both layouts.
--   ✓ that each declared row COUNT matches what its pane mounts -- in BOTH mode
--     variants, because three of these groups change shape with the layout mode
--     and one with party/raid.
--   ✓ that the five page-rebuilding callbacks now go through the layout-aware
--     gate, and that the ONE that still rebuilds unconditionally is the layout
--     dropdown, which is on the page in both layouts.
--   ✓ that every locale string the page asks for already ships in enUS.
--   ✗ nothing about runtime behaviour -- the callbacks, the greying and the
--     summaries are read by eye and by the in-game checklist. The Border row's
--     count is pinned in test_border_builders.lua, which drives a pet-shaped
--     CreateBorderControls call and counts what comes out.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Options.lua")

-- ---- the census reader (the Fading page's, plus three kinds) -----------
-- ⚠ THE THREE FONT/MEDIA FACTORIES ARE IN THE MAP HERE. This is the first
-- converted page whose panes mount a texture dropdown, a font dropdown, an
-- outline dropdown and a shadow tick, and a reader that did not know them would
-- report a Name Text group of five controls rather than nine -- silently, and in
-- the direction that makes a wrong count look right.
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateTextureDropdown = "texturedropdown",
    CreateFontDropdown = "fontdropdown",
    CreateOutlineDropdown = "outlinedropdown",
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

-- The page, scoped by its own two ends: Options.lua holds a dozen pages, and a
-- bare 280 box on one of the others is not this pass's business.
local PAGE
do
    local a = SRC:find('Add(CreateCopyButton(self.child, {"pet"}, L["Pet Frames"], "display_pets"), 25, 2)', 1, true)
    local b = SRC:find('local pageGeneral = CreateSubTab("general", "general_settings", L["Settings"])', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Pet Frames page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- The block a row is declared in, from its label to the closing brace of the
-- CreatePopoutRow opts.
local function rowOpts(labelKey)
    local a = PAGE:find('label%s*=%s*L%["' .. labelKey:gsub("%p", "%%%0") .. '"%]')
    check(a ~= nil, "source: a popout row is declared for " .. labelKey)
    if not a then return "" end
    local b = PAGE:find("}))", a, true)
    return PAGE:sub(a, (b or a) + 2)
end

-- What every converted group on this page has in common: one builder, two
-- mounts, the classic box unchanged, and the row wired to a real popout.
local function checkShared(builder, rowLabel, column, band)
    local calls = 0
    for _ in PAGE:gmatch(builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, rowLabel .. ": declared once, mounted twice -- classic box and popout pane")

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
    check(PAGE:find(band .. ":AddWidget(GUI:CreatePopoutRow(", 1, true) ~= nil,
          rowLabel .. ": ...and mounted into " .. band)
end

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED MACHINERY, AND ITS THREE BANDS ARE HEADED
-- ============================================================
print("-- Pet Frames page: the shared popout machinery and the page's three bands")
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

    -- ---- three bands, each headed --------------------------------------
    local bands = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, tools%.BandWidth%(%)") do bands = bands + 1 end
    eq(bands, 3, "band: three bands, which is how eight rows stop being one list")
    for band, header in pairs({ petLayoutBand = "Layout", petFrameBand = "Frame", petTextBand = "Text" }) do
        check(PAGE:find(band .. " = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
              "band: " .. band .. " is chromeless, at the width the layout pass will give it")
        check(PAGE:find(band .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. header .. '"]), 40)', 1, true) ~= nil,
              "band: ...and is headed " .. header)
    end
    -- ⚠ NO HEADER REPEATS A ROW LABEL. "Appearance" is a ROW on this page, so
    -- the band holding it is headed L["Frame"] -- a header names the section,
    -- never one of the rows under it.
    for _, rowLabel in ipairs({ "Appearance", "Border", "Size", "Position",
                                "Group Settings", "Health Bar", "Name Text", "Health Text" }) do
        for _, band in ipairs({ "petLayoutBand", "petFrameBand", "petTextBand" }) do
            check(PAGE:find(band .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. rowLabel .. '"])', 1, true) == nil,
                  "band: " .. band .. " is not headed with the name of a row it could hold")
        end
    end

    -- ---- the page-scope helpers, above every builder -------------------
    -- ☠ A closure captures the upvalue that exists when it is CREATED, so a
    -- builder declared above one of these would see nil rather than the value.
    -- The rows need them from outside the builders as well: a summary prints the
    -- dropdown's own words, and a footer has to push the group's own work.
    local BUILDERS = { "BuildPetGeneralGroup", "BuildPetLayoutModeGroup",
                       "BuildPetGroupSettingsGroup", "BuildPetSizeGroup",
                       "BuildPetAppearanceGroup", "BuildPetBorderGroup",
                       "BuildPetHealthBarGroup", "BuildPetNameTextGroup",
                       "BuildPetPositionGroup", "BuildPetHealthTextGroup" }
    for _, h in ipairs({ "textAnchorValues", "groupModeValues", "groupAnchorValues",
                         "growthValues", "anchorValues", "healthColorValues",
                         "powerColorValues", "ApplyPetGroupLayout" }) do
        local at = PAGE:find("local " .. h, 1, true)
        check(at ~= nil, "helpers: " .. h .. " is declared at page scope")
        local decls = 0
        for _ in PAGE:gmatch("local " .. h .. "%f[%s]") do decls = decls + 1 end
        eq(decls, 1, "helpers: ...and there is exactly one of it")
        for _, b in ipairs(BUILDERS) do
            local bAt = PAGE:find("local function " .. b .. "(tools2)", 1, true)
            check(at ~= nil and bAt ~= nil and at < bAt,
                  "helpers: ..." .. b .. " is declared after it, so it closes over the real value")
        end
    end
end

-- ============================================================
-- 2. THE TWO STAY-INLINE BOXES
-- Neither is a feature: one is the page's enable and a paragraph, the other is
-- one dropdown that rebuilds the page. Both keep their own header and both wear
-- the band skin in the popout layout so they do not read as a second visual
-- language beside the rows.
-- ============================================================
local GENERAL = {
    { "checkbox", "Enable Pet Frames", "petEnabled", 30 },
    { "label",    "Show health bars for player and party/raid member pets, anchored to their owner's frame. Pet frames hide when owner dies.", "(none)", nil },
}
local LAYOUT_MODE = {
    { "dropdown", "Layout Mode", "petGroupMode", 55 },
    -- Two labels, one branch each: attached explains the owner anchor, grouped
    -- the separate container. The census reads SOURCE, so both are here; only
    -- one is ever built.
    { "label", "Pet frames are positioned relative to their owner's frame.", "(none)", nil },
    { "label", "Pet frames are grouped together in a separate container.", "(none)", nil },
}

print("-- Pet Frames page: the two stay-inline boxes")
do
    checkCensus(census(builderBody("BuildPetGeneralGroup")), GENERAL, "general")
    checkCensus(census(builderBody("BuildPetLayoutModeGroup")), LAYOUT_MODE, "layout mode")

    -- Neither is a row.
    for _, label in ipairs({ "Pet Frame Settings", "Layout Mode" }) do
        check(PAGE:find('label   = L["' .. label .. '"]', 1, true) == nil
          and PAGE:find('label    = L["' .. label .. '"]', 1, true) == nil,
              "inline: " .. label .. " is not a popout row")
    end

    -- Two boxes wearing the band skin, and the columns they land in. The general
    -- box keeps column 1 in both layouts; the layout-mode box moves to column 2
    -- in the popout layout ONLY, so the full-width bands below it do not open on
    -- a two-box-tall hole (Add's "both" is a sync point).
    local skinned = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280, tools%.INLINE_BOX%)") do skinned = skinned + 1 end
    eq(skinned, 2, "inline: two boxes wear the band skin, which is both of them")
    check(PAGE:find("Add(generalGroup, nil, 1)", 1, true) ~= nil,
          "inline: the general box is column 1")
    check(PAGE:find("Add(layoutGroup, nil, 1)", 1, true) ~= nil,
          "inline: ...and classic keeps the layout box under it, in column 1")
    check(PAGE:find("Add(layoutGroup, nil, 2)", 1, true) ~= nil,
          "inline: ...while the popout layout puts it in column 2, beside it")

    -- The enable is the page's, so its refresh has to reach the rows AND any
    -- pane standing open behind one. Classic's hook is the page refresh alone,
    -- exactly as it was.
    check(PAGE:find("refreshStates = function() self:RefreshStates() tools.ReflowMounted() end", 1, true) ~= nil,
          "inline: the enable's popout refresh reflows the open panes as well as the page")
    local body = builderBody("BuildPetGeneralGroup")
    check(body:find("tools2.refreshStates()", 1, true) ~= nil,
          "inline: ...and the builder calls the hook rather than the page directly")
    check(body:find("self:RefreshStates()", 1, true) == nil,
          "inline: ...never the page alone, which a pane would not hear")
    check(body:find("petEnable.keepEnabled = true", 1, true) ~= nil,
          "inline: the enable stays live under its own group's grey")
    check(body:find("group.disableChildrenOn = function(d) return not d.petEnabled end", 1, true) ~= nil,
          "inline: ...and the blurb beside it greys with it")
end

-- ============================================================
-- 3. THE ONE CALLBACK THAT STILL REBUILDS THE PAGE, AND THE FIVE THAT DO NOT
-- Five controls used to end in GUI:RefreshCurrentPage purely to re-run a
-- hideOn/disableOn pass over a sibling. In a pane that is fatal -- a rebuild
-- retires the row being clicked and the helper's prologue closes every open
-- panel -- so they go through the layout-aware gate instead (the Tooltips page's
-- AnchorGateRefresh, same rule). The layout dropdown keeps its rebuild, because
-- what it changes is WHICH GROUPS EXIST and no state pass produces widgets that
-- were never built.
-- ============================================================
print("-- Pet Frames page: the page-rebuild gate")
do
    local gate = PAGE:match("local function GateRefresh%(tools2%)(.-)\n        end")
    check(gate ~= nil, "gate: the layout-aware refresh is a named page-scope function")
    if gate then
        check(gate:find("if tools2.popout then", 1, true) ~= nil,
              "gate: ...it branches on which layout mounted the builder")
        check(gate:find("tools2.refreshStates()", 1, true) ~= nil,
              "gate: ...the pane re-runs its own state pass")
        check(gate:find("GUI:RefreshCurrentPage()", 1, true) ~= nil,
              "gate: ...and classic still rebuilds the page, exactly as it did")
    end

    local uses = 0
    for _ in PAGE:gmatch("GateRefresh%(tools2%)") do uses = uses + 1 end
    eq(uses, 6, "gate: five callbacks go through it -- two Match Owner ticks and the three health-bar gates -- plus its own declaration")

    -- Exactly two rebuilds left on the page: the gate's classic arm, and the
    -- layout dropdown. Anything else would be a control that can be reached from
    -- inside a pane and takes the page down with it.
    local rebuilds = 0
    for _ in PAGE:gmatch("GUI:RefreshCurrentPage%(%)") do rebuilds = rebuilds + 1 end
    eq(rebuilds, 2, "gate: two rebuilds on the page -- the gate's classic arm and the layout dropdown")
    local lm = builderBody("BuildPetLayoutModeGroup")
    check(lm:find("GUI:RefreshCurrentPage()", 1, true) ~= nil,
          "gate: the layout dropdown rebuilds in BOTH layouts, because it changes which groups exist")
    check(lm:find("GateRefresh", 1, true) == nil,
          "gate: ...and never goes through the gate, which would leave the new groups unbuilt")
end

-- ============================================================
-- 4. THE PAGE-WIDE GATE
-- Every group on this page greys behind petEnabled and always has. In the popout
-- layout that gate has to reach three places: the pane (the builders' own
-- disableChildrenOn, unchanged), the ROW (so eight bright rows do not sit over
-- eight grey panes), and the pane's FIRST child -- which the kit's group gate
-- skips, because in a page box index 1 is the header and in a pane it is a real
-- control.
-- ============================================================
print("-- Pet Frames page: the petEnabled gate")
do
    check(PAGE:find("local function PetsOffRow(d) return not (d or db).petEnabled end", 1, true) ~= nil,
          "gate: the page-wide predicate is named once")
    local rows = 0
    for _ in PAGE:gmatch("%w+Row%.disableOn = PetsOffRow") do rows = rows + 1 end
    eq(rows, 8, "gate: all eight rows grey with it")

    local first = PAGE:match("local function GatePaneFirstChild%(group%)(.-)\n        end")
    check(first ~= nil, "gate: the pane's first-child repair is a named function")
    if first then
        check(first:find("group.groupChildren[1]", 1, true) ~= nil,
              "gate: ...it is about index 1, which is the one the group gate skips")
        check(first:find("PetsOffRow(d) or (prev and prev(d))", 1, true) ~= nil,
              "gate: ...and composes with whatever predicate the widget already carries")
    end
    -- Seven mounts, not eight: the Border pane's group is owned by
    -- CreateBorderControls, which takes the gate through its own disableWhen and
    -- reaches all fifteen including the first.
    local calls = 0
    for _ in PAGE:gmatch("GatePaneFirstChild%(group%)") do calls = calls + 1 end
    eq(calls, 8, "gate: seven pane mounts call it, plus its own declaration")
    check(PAGE:find("disableWhen  = tools2.popout and PetsOffRow or nil", 1, true) ~= nil,
          "gate: the border pane takes the gate through the factory's consumer door instead")
end

-- ============================================================
-- 5. THE EIGHT ROWS
-- ============================================================
local GROUP_SETTINGS = {
    { "dropdown", "Group Position",   "petGroupAnchor",    55 },
    { "dropdown", "Growth Direction", "petGroupGrowth",    55 },
    { "slider",   "Spacing",          "petGroupSpacing",   55 },
    { "slider",   "Group X Offset",   "petGroupOffsetX",   55 },
    { "slider",   "Group Y Offset",   "petGroupOffsetY",   55 },
    -- Raid only: there are no groups to label in party.
    { "checkbox", "Show Group Label", "petGroupShowLabel", 30 },
}
local SIZE = {
    -- Attached only: in grouped mode there is no owner to match.
    { "checkbox", "Match Owner Width",  "petMatchOwnerWidth",  30 },
    { "checkbox", "Match Owner Height", "petMatchOwnerHeight", 30 },
    { "slider",   "Width",              "petFrameWidth",       55 },
    { "slider",   "Height",             "petFrameHeight",      55 },
}
local APPEARANCE = {
    { "texturedropdown", "Health Bar Texture", "petTexture",          55 },
    { "colorpicker",     "Background Color",   "petBackgroundColor",  35 },
}
local HEALTH_BAR = {
    { "dropdown",    "Health Bar Color",       "petHealthColorMode", 55 },
    { "colorpicker", "Custom Health Color",    "petHealthColor",     35 },
    { "checkbox",    "Show Health Percentage", "petShowHealthText",  30 },
    { "checkbox",    "Show Power Bar",         "petShowPowerBar",    30 },
    { "slider",      "Power Bar Height",       "petPowerBarHeight",  55 },
    { "dropdown",    "Power Bar Color",        "petPowerColorMode",  55 },
    { "colorpicker", "Custom Power Color",     "petPowerColor",      35 },
}
local NAME_TEXT = {
    { "fontdropdown",    "Font",            "petNameFont",        55 },
    { "slider",          "Font Size",       "petNameFontSize",    55 },
    { "outlinedropdown", "Outline",         "petNameFontOutline", 55 },
    { "shadowcheckbox",  "Shadow",          "petNameFontOutline", 30 },
    { "slider",          "Max Name Length", "petNameMaxLength",   55 },
    { "dropdown",        "Name Anchor",     "petNameAnchor",      55 },
    { "colorpicker",     "Name Text Color", "petNameColor",       35 },
    { "slider",          "Name X Offset",   "petNameX",           55 },
    { "slider",          "Name Y Offset",   "petNameY",           55 },
}
local POSITION = {
    { "dropdown", "Anchor",   "petAnchor",  55 },
    { "slider",   "Offset X", "petOffsetX", 55 },
    { "slider",   "Offset Y", "petOffsetY", 55 },
}
local HEALTH_TEXT = {
    { "fontdropdown",    "Font",               "petHealthFont",        55 },
    { "slider",          "Font Size",          "petHealthFontSize",    55 },
    { "outlinedropdown", "Outline",            "petHealthFontOutline", 55 },
    { "shadowcheckbox",  "Shadow",             "petHealthFontOutline", 30 },
    { "colorpicker",     "Health Text Color",  "petHealthTextColor",   35 },
    { "dropdown",        "Health Text Anchor", "petHealthAnchor",      55 },
    { "slider",          "Health X Offset",    "petHealthX",           55 },
    { "slider",          "Health Y Offset",    "petHealthY",           55 },
}

-- Every row on this page except Border: no hoisted toggle, so the declared count
-- IS the census (or the mode-dependent slice of it), and the row carries a
-- summary, the amber tick, a footer and the page gate.
local ROWS = {
    { builder = "BuildPetGroupSettingsGroup", label = "Group Settings", golden = GROUP_SETTINGS,
      column = "1", band = "petLayoutBand", row = "petGroupRow", apply = "ApplyPetGroupLayout",
      summary = "PetGroupSummary", countVar = "PET_GROUP_COUNT" },
    { builder = "BuildPetSizeGroup", label = "Size", golden = SIZE,
      column = "1", band = "petLayoutBand", row = "petSizeRow", apply = "ApplyPetSize",
      summary = "PetSizeSummary", countVar = "PET_SIZE_COUNT" },
    { builder = "BuildPetAppearanceGroup", label = "Appearance", golden = APPEARANCE,
      column = "2", band = "petFrameBand", row = "petAppearanceRow", apply = "ApplyPetAppearance",
      summary = "PetAppearanceSummary", countVar = "PET_APPEARANCE_COUNT", count = 2 },
    { builder = "BuildPetHealthBarGroup", label = "Health Bar", golden = HEALTH_BAR,
      column = "2", band = "petFrameBand", row = "petHealthBarRow", apply = "ApplyPetHealthBar",
      summary = "PetHealthBarSummary", countVar = "PET_HEALTH_BAR_COUNT", count = 7 },
    { builder = "BuildPetNameTextGroup", label = "Name Text", golden = NAME_TEXT,
      column = "2", band = "petTextBand", row = "petNameTextRow", apply = "ApplyPetText",
      countVar = "PET_NAME_TEXT_COUNT", count = 9 },
    { builder = "BuildPetPositionGroup", label = "Position", golden = POSITION,
      column = "1", band = "petLayoutBand", row = "petPositionRow", apply = "ApplyPetPosition",
      summary = "PetPositionSummary", countVar = "PET_POSITION_COUNT", count = 3 },
    { builder = "BuildPetHealthTextGroup", label = "Health Text", golden = HEALTH_TEXT,
      column = "2", band = "petTextBand", row = "petHealthTextRow", apply = "ApplyPetText",
      countVar = "PET_HEALTH_TEXT_COUNT", count = 8 },
}

for _, g in ipairs(ROWS) do
    print("-- Pet Frames page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())
    checkShared(g.builder, g.label, g.column, g.band)

    -- No hoist anywhere but Border: none of these groups holds a boolean meaning
    -- "am I doing anything at all". The page's own enable is the closest thing to
    -- one and it belongs to the page, not to any row.
    check(body:find("hoistToggle", 1, true) == nil,
          g.label .. ": the builder has no hoist branch, because there is nothing to hoist")
    -- ☠ THE GROUP GATE IS INSIDE THE BUILDER. Left on the page-level box, the
    -- pane would not grey while pet frames are off and the two layouts would
    -- disagree.
    check(body:find("group.disableChildrenOn = function(d) return not d.petEnabled end", 1, true) ~= nil,
          g.label .. ": the group's grey-while-off gate is inside the builder")

    local opts = rowOpts(g.label)
    check(opts:find("toggle", 1, true) == nil,
          g.label .. ": the row declares no toggle")
    check(opts:find("onToggle", 1, true) == nil,
          g.label .. ": ...and so no commit either")
    if g.summary then
        check(opts:find("summary%s*=%s*" .. g.summary) ~= nil,
              g.label .. ": ...it does declare its own summary")
    end
    check(opts:find("count%s*=%s*" .. g.countVar) ~= nil,
          g.label .. ": ...and the declared count, not a literal")

    -- The strip. Every key behind these rows is a per-mode profile key the
    -- defaults engine answers for, so every one gets the amber tick and a footer.
    check(PAGE:find("tools.ClaimKeys(" .. g.row .. ", ", 1, true) ~= nil,
          g.label .. ": the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(" .. g.row .. ")", 1, true) ~= nil,
          g.label .. ": ...its amber tick asks about exactly those keys")
    check(PAGE:find("tools.WireFooter(" .. g.row .. ", " .. g.apply .. ")", 1, true) ~= nil,
          g.label .. ": ...and Reset Group / Hold: Defaults run the group's own apply")
    check(PAGE:find(g.row .. ".disableOn = PetsOffRow", 1, true) ~= nil,
          g.label .. ": ...and the row greys with the page's own enable")

    if g.count then
        local declared = tonumber(PAGE:match("local " .. g.countVar .. "%s*=%s*(%d+)"))
        check(declared ~= nil, g.label .. ": the page declares the row's count in one place")
        eq(declared, g.count, g.label .. ": ...which is the whole census")
        eq(g.count, #g.golden, g.label .. ": ...and the census is what the pane mounts")
    end
end

-- ============================================================
-- 6. THE TWO COUNTS THAT FOLLOW A MODE
-- A count is a CLAIM about how much is behind the row, and the kit checks it
-- against what the pane actually mounted. Two of these groups mount a different
-- number in each mode, so naming the larger of the two would be a mismatch
-- reported on every profile in the other one.
-- ============================================================
print("-- Pet Frames page: the mode-dependent counts")
do
    local raid, party = PAGE:match("local PET_GROUP_COUNT%s*=%s*isRaidMode and (%d+) or (%d+)")
    check(raid ~= nil, "counts: Group Settings declares a count per mode")
    eq(tonumber(raid), #GROUP_SETTINGS, "counts: ...raid mounts the whole census, group label included")
    eq(tonumber(party), #GROUP_SETTINGS - 1, "counts: ...party mounts it less the group label tick")

    local grouped, attached = PAGE:match("local PET_SIZE_COUNT%s*=%s*isGroupedMode and (%d+) or (%d+)")
    check(grouped ~= nil, "counts: Size declares a count per mode")
    eq(tonumber(attached), #SIZE, "counts: ...attached mounts the whole census, both Match Owner ticks")
    eq(tonumber(grouped), #SIZE - 2, "counts: ...grouped mounts the two sliders alone")
end

-- ============================================================
-- 7. THE BORDER ROW -- the page's one hoisted toggle
-- One CreateBorderControls call, not the Frame page's two: the whole pet border
-- is sixteen controls of which the shadow is five, and a row for five
-- sub-controls of another row's feature is a level of nesting this page does not
-- earn. include.shadow keeps the shadow block inside the factory's own
-- composition loop, which is what puts Show Border's grey on top of it.
--
-- The COUNT is pinned in test_border_builders.lua, which drives a pet-shaped
-- call and counts what comes out. What is checked here is the wiring.
-- ============================================================
print("-- Pet Frames page: Border")
do
    local body = builderBody("BuildPetBorderGroup")
    check(body:find('GUI:CreateBorderControls(tools2.group, db, "pet", {', 1, true) ~= nil,
          "border: one call, into the group the mount handed over")
    check(body:find("include      = { alpha = true, inset = true, blendMode = true,", 1, true) ~= nil,
          "border: the include set is exactly what it was")
    check(body:find("gradient = true, shadow = true },", 1, true) ~= nil,
          "border: ...both lines of it")
    check(body:find("sizeMin = 1, sizeMax = 6, sizeStep = 1,", 1, true) ~= nil,
          "border: ...and the thickness range is the page's, not the factory default")
    check(body:find("noShowToggle = tools2.hoistToggle or nil,", 1, true) ~= nil,
          "border: the hoist is the factory's own noShowToggle, nil in classic")

    checkShared("BuildPetBorderGroup", "Border", "2", "petFrameBand")

    -- ⚠ THE CLASSIC BOX KEEPS ITS OWN disableChildrenOn. CreateBorderControls
    -- owns the group and writes disableOn onto each of the sixteen, so this
    -- builder is the one that does NOT set the group gate itself -- classic sets
    -- it on the box exactly as it always did, and the pane takes it through
    -- disableWhen.
    -- The ASSIGNMENT, not the words: the note above disableWhen explains why this
    -- builder is the exception, and a check on the bare name would fail on its
    -- own explanation.
    check(body:find("group.disableChildrenOn = function(d)", 1, true) == nil,
          "border: the builder sets no group gate, because the factory owns the group")
    check(PAGE:find("petBorderGroup.disableChildrenOn = function(d) return not d.petEnabled end", 1, true) ~= nil,
          "border: ...classic still gates the box, unchanged")

    local opts = rowOpts("Border")
    check(opts:find('toggle%s*=%s*{%s*key%s*=%s*"petShowBorder"%s*}') ~= nil,
          "border: the row's tick is the border's own Show key")
    check(opts:find("summary%s*=%s*PetBorderSummary") ~= nil,
          "border: ...it declares its own summary")
    check(opts:find("count%s*=%s*PET_BORDER_COUNT") ~= nil,
          "border: ...and the declared count, not a literal")
    check(opts:find("onToggle%s*=%s*OnPetBorderToggle") ~= nil,
          "border: ...and a commit that is not a page rebuild")

    -- ☠ THE COMMIT IS NOT A PAGE REBUILD: a rebuild retires every widget on the
    -- page including the row being clicked, and the row's write path calls
    -- row.Refresh() after this returns -- on a dead frame.
    local commit = PAGE:match("local function OnPetBorderToggle%(%)(.-)\n            end")
    check(commit ~= nil, "border: the popout commit is a named function")
    if commit then
        check(commit:find("RefreshCurrentPage", 1, true) == nil,
              "border: ...and never rebuilds the page")
        check(commit:find("ApplyPetBorder()", 1, true) ~= nil,
              "border: ...it runs what the suppressed Show Border checkbox ran")
        check(commit:find("self:RefreshStates()", 1, true) ~= nil,
              "border: ...re-runs the state passes")
        check(commit:find("tools.ReflowMounted()", 1, true) ~= nil,
              "border: ...and reflows the open panes")
    end

    -- The hoisted toggle keeps its search entry under the SAME label and key the
    -- suppressed checkbox carried, or the setting becomes unfindable in the
    -- popout layout while staying findable in classic.
    check(PAGE:find('tools.RegisterHoistedToggle(petBorderRow, L["Show Border"], "petShowBorder", OnPetBorderToggle)', 1, true) ~= nil,
          "border: the hoisted toggle keeps its search entry")
    check(PAGE:find("tools.ClaimKeys(petBorderRow, borderContent)", 1, true) ~= nil,
          "border: the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(petBorderRow)", 1, true) ~= nil,
          "border: ...its amber tick asks about exactly those keys")
    check(PAGE:find("tools.WireFooter(petBorderRow, ApplyPetBorder)", 1, true) ~= nil,
          "border: ...and its footer pushes the border back out")
    check(PAGE:find("petBorderRow.disableOn = PetsOffRow", 1, true) ~= nil,
          "border: ...and the row greys with the page's own enable")
end

-- ============================================================
-- 8. THE SUMMARIES
-- All follow the sweep's convention: at most four items, a fixed order,
-- "\194\183" between them, WORDS localised and numbers raw -- and every word is
-- a locale string the page already ships (section 10 proves that outright).
-- ============================================================
print("-- Pet Frames page: the summaries")
do
    local function summaryBody(name, indent)
        return PAGE:match("local function " .. name .. "%(d%)(.-)\n" .. indent .. "end")
    end
    local function itemsUnderFour(sum, name)
        local items = 0
        for _ in sum:gmatch("parts%[#parts %+ 1%]") do items = items + 1 end
        check(items <= 4, "summary: " .. name .. " prints at most four items")
    end

    -- Group Settings: where the block sits, which way it grows, and the nudge --
    -- both words out of the dropdowns' own option tables, so the row cannot name
    -- a side the control does not offer.
    local grp = summaryBody("PetGroupSummary", "                ")
    check(grp ~= nil, "summary: Group Settings has a named summary on the page")
    if grp then
        check(grp:find("groupAnchorValues[d.petGroupAnchor]", 1, true) ~= nil,
              "summary: ...the side comes out of the dropdown's own table")
        check(grp:find("growthValues[d.petGroupGrowth]", 1, true) ~= nil,
              "summary: ...and so does the growth direction")
        check(grp:find('format("%d, %d"', 1, true) ~= nil,
              "summary: ...with the offsets as a pair, the Border Shadow row's convention")
        itemsUnderFour(grp, "Group Settings")
    end

    -- ⚠ SIZE PRINTS A NUMBER ONLY WHERE IT IS THE NUMBER IN USE. In attached mode
    -- either dimension can be handed to the owner's frame, and petMatchOwnerWidth
    -- ships ON -- so an unconditional width would name a value nothing renders.
    local size = summaryBody("PetSizeSummary", "            ")
    check(size ~= nil, "summary: Size has a named summary on the page")
    if size then
        check(size:find("d.petMatchOwnerWidth", 1, true) ~= nil,
              "summary: ...the width is skipped while it is matched to the owner")
        check(size:find("d.petMatchOwnerHeight", 1, true) ~= nil,
              "summary: ...and so is the height")
        check(size:find('L%["Width"%]') ~= nil and size:find('L%["Height"%]') ~= nil,
              "summary: ...both under the sliders' own labels")
        itemsUnderFour(size, "Size")
    end

    -- Appearance: the texture's NAME, through the addon's own media resolver --
    -- the one CreateTextureDropdown prints on its button, so the row and the
    -- control behind it cannot disagree.
    local app = summaryBody("PetAppearanceSummary", "            ")
    check(app ~= nil, "summary: Appearance has a named summary on the page")
    if app then
        check(app:find("DF:GetTextureNameFromPath(d.petTexture)", 1, true) ~= nil,
              "summary: ...it names the texture through the addon's own resolver")
        itemsUnderFour(app, "Appearance")
    end

    -- Border: the Frame page's, less the colour source this one does not have.
    local bd = summaryBody("PetBorderSummary", "            ")
    check(bd ~= nil, "summary: Border has a named summary on the page")
    if bd then
        check(bd:find('format("%dpx"', 1, true) ~= nil,
              "summary: ...the thickness wears its unit")
        check(bd:find('L%["Gradient"%]') ~= nil and bd:find('L%["Solid"%]') ~= nil,
              "summary: ...the style is a word, not a key")
        check(bd:find("a < 1", 1, true) ~= nil,
              "summary: ...and the alpha only when it is doing something")
        itemsUnderFour(bd, "Border")
    end

    -- Health Bar: what colour the bar is, then whether there is a second bar
    -- under it -- and the power bar only when it is on, because it ships off.
    local hb = summaryBody("PetHealthBarSummary", "            ")
    check(hb ~= nil, "summary: Health Bar has a named summary on the page")
    if hb then
        check(hb:find("healthColorValues[d.petHealthColorMode]", 1, true) ~= nil,
              "summary: ...the colour mode comes out of the dropdown's own table")
        check(hb:find('if d.petShowPowerBar then', 1, true) ~= nil,
              "summary: ...and the power bar is named only when it is on")
        itemsUnderFour(hb, "Health Bar")
    end

    -- Position: the owner's side, then the nudge.
    local pos = summaryBody("PetPositionSummary", "                ")
    check(pos ~= nil, "summary: Position has a named summary on the page")
    if pos then
        check(pos:find("anchorValues[d.petAnchor]", 1, true) ~= nil,
              "summary: ...the side comes out of the dropdown's own table")
        check(pos:find('format("%d, %d"', 1, true) ~= nil,
              "summary: ...with the offsets as a pair")
        itemsUnderFour(pos, "Position")
    end

    -- The two text rows share ONE summary factory: they differ only in their key
    -- prefix, and two copies would be two places for the convention to drift.
    local text = PAGE:match("local function TextRowSummary%(fontKey, sizeKey, anchorKey%)(.-)\n        end")
    check(text ~= nil, "summary: the two text rows share one named summary factory")
    if text then
        check(text:find("DF:GetFontNameFromPath(d[fontKey])", 1, true) ~= nil,
              "summary: ...the font is named through the addon's own resolver")
        check(text:find("textAnchorValues[d[anchorKey]]", 1, true) ~= nil,
              "summary: ...the anchor comes out of the dropdown's own table")
        local items = 0
        for _ in text:gmatch("parts%[#parts %+ 1%]") do items = items + 1 end
        check(items <= 4, "summary: ...and it prints at most four items")
    end
    check(PAGE:find('summary = TextRowSummary("petNameFont", "petNameFontSize", "petNameAnchor")', 1, true) ~= nil,
          "summary: Name Text takes the factory with its own keys")
    check(PAGE:find('summary = TextRowSummary("petHealthFont", "petHealthFontSize", "petHealthAnchor")', 1, true) ~= nil,
          "summary: ...and Health Text with its own")

    -- Every summary on this page separates with the convention's dot.
    local dots = 0
    for _ in PAGE:gmatch('table%.concat%(parts, " \\194\\183 "%)') do dots = dots + 1 end
    eq(dots, 7, "summary: seven summaries, every one separated by the convention's dot")
end

-- ============================================================
-- 9. THE PAGE'S OWN ORDER AND FURNITURE
-- ============================================================
print("-- Pet Frames page: the boxes, the bands and the page's own order")
do
    -- ☠ THE COPY BUTTON'S PREFIX LIST IS UNTOUCHED. The same list drives Copy,
    -- Sync AND Reset Page.
    check(PAGE:find('Add(CreateCopyButton(self.child, {"pet"}, L["Pet Frames"], "display_pets"), 25, 2)', 1, true) ~= nil,
          "page: the copy button's prefix list is exactly what it was")

    -- ---- ten bare 280 boxes left, all inside a classicLayout arm -------
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 10, "boxes: ten bare 280 boxes left, which is every group the page ever had")

    -- ---- the two conditional groups are still conditional --------------
    -- Built only in the mode they belong to, exactly as the boxes were. The page
    -- rebuilds when the layout mode changes, so a row that only exists in one
    -- mode is the same statement the box made.
    check(PAGE:find("if isGroupedMode then\n            if classicLayout then", 1, true) ~= nil,
          "order: Group Settings is still grouped-mode only, in both layouts")
    check(PAGE:find("if not isGroupedMode then\n            if classicLayout then", 1, true) ~= nil,
          "order: ...and Position is still attached-mode only")

    -- ---- the bands go in after their last row --------------------------
    -- ☠ `Add` resolves a widget's slot height on the spot, so a band has to be
    -- added AFTER the last row has been put into it.
    for band, rows in pairs({ petLayoutBand = 3, petFrameBand = 3, petTextBand = 2 }) do
        local bandAdd = PAGE:find("Add(" .. band .. ', nil, "both")', 1, true)
        check(bandAdd ~= nil, "order: " .. band .. " spans both columns")
        local lastRow, at = nil, 1
        while true do
            local s = PAGE:find(band .. ":AddWidget(GUI:CreatePopoutRow(", at, true)
            if not s then break end
            lastRow, at = s, s + 1
        end
        check(lastRow ~= nil and bandAdd ~= nil and lastRow < bandAdd,
              "order: ...and goes in after its last row")
        local n = 0
        for _ in PAGE:gmatch(band .. ":AddWidget%(GUI:CreatePopoutRow%(") do n = n + 1 end
        eq(n, rows, "order: " .. band .. " holds " .. rows .. " rows")
    end

    -- ...and the bands go in AFTER the two inline boxes, which is what keeps the
    -- page's own enable the first thing on it.
    local generalAdd = PAGE:find("Add(generalGroup, nil, 1)", 1, true)
    local firstBand  = PAGE:find('Add(petLayoutBand, nil, "both")', 1, true)
    check(generalAdd ~= nil and firstBand ~= nil and generalAdd < firstBand,
          "order: the enable box is added before the first band")

    -- Eight rows on the page, which is every group that is not one of the two
    -- that stay inline.
    local rows = 0
    for _ in PAGE:gmatch("GUI:CreatePopoutRow%(") do rows = rows + 1 end
    eq(rows, 8, "order: eight rows, which is ten groups less the two inline boxes")
end

-- ============================================================
-- 10. ZERO NEW LOCALE STRINGS
-- Every L key this page asks for -- labels, tooltips, the three band headers and
-- the seven summaries' own words -- already ships in enUS. A sweep that invented
-- a string would have to add it there in the same commit, and this is the gate
-- that says so.
-- ============================================================
print("-- Pet Frames page: no new locale strings")
do
    local loc = df_file_source("Locales/enUS.lua")
    local have = {}
    for k in loc:gmatch('L%["([^"]+)"%]%s*=%s*true') do have[k] = true end
    local seen, missing = {}, 0
    for k in PAGE:gmatch('L%["([^"]+)"%]') do
        if not seen[k] then
            seen[k] = true
            if not have[k] then
                missing = missing + 1
                check(false, 'locale: the page asks for L["' .. k .. '"], which enUS does not ship')
            end
        end
    end
    eq(missing, 0, "locale: every string this page asks for already exists -- zero new keys")
end
