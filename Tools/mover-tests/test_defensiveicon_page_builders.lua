local NS = ...

-- ============================================================
-- DEFENSIVE ICON PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Indicators.lua
-- ------------------------------------------------------------
-- Auras > Defensive Icon: NINE groups. In Modern they are the Debuff Bar's
-- collapsible CARDS -- two per row inside a card wide enough, dim captions, the
-- value summary in a shut card's corner, Expand All / Collapse All at the top --
-- in the columns and the order the old bands had:
--
--   column 1   "Content"  Settings (holds the PAGE gate, Enable Defensive Icon,
--                         in its body -- as Show Buffs does) and Defensive
--                         Filters.
--   column 2   "Icon"     Layout, Appearance, Position, Border (Show Border is
--                         the header's tick, through the toolkit's noShowToggle).
--   column 1   "Text"     Duration Text (Show Duration is the header's tick),
--                         Stack Count (hides with the factory gate).
--              ...then    Duration Bar (Enable Duration Bar is the header's tick),
--                         the 12.1-factory extra, under NO category header.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY, so this file reads the page's SOURCE
-- and asserts against it, as the other census files do.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each builder, taken from the PRE-CHANGE source -- the
--     evidence that CLASSIC RENDERS AS IT DID.
--   ✓ that ONE builder serves both layouts, and the card hands it EXACTLY what
--     classic hands it (plus hoistToggle where the tick moved to the header).
--   ✓ each card's column, stable collapse key, summary, grey gate, hide gate,
--     header tick and pin; that there is one checkbox per setting; the Add
--     order that the one-column fold reads in.
--   ✗ nothing about runtime behaviour -- read in game.
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

-- ONE CARD'S BLOCK: its OpenSection call, the builder mount under it and the
-- CloseSection that puts its band in, flattened. `call` is just the OpenSection
-- call. The Defensive Filters card closes `fband` rather than `band`.
local function sectionBlock(labelKey)
    local a = PAGE:find('OpenSection(L["' .. labelKey .. '"]', 1, true)
    check(a ~= nil, "source: a card is opened for " .. labelKey)
    if not a then return "", "" end
    local b, e = PAGE:find("CloseSection%(f?band%)", a)
    check(b ~= nil, "source: ..." .. labelKey .. "'s band is closed after its controls")
    local block = PAGE:sub(a, e or a):gsub("%s+", " ")
    local m = block:find("({ group = band,", 1, true) or block:find("({ group = fband,", 1, true)
    local call = m and block:sub(1, m) or block
    call = call:gsub("Build[%w]+%($", "")
    return block, call
end

-- ============================================================
-- 1. THE SHARED MACHINERY, AND THE POPOUT FURNITURE GONE
-- ============================================================
print("-- Defensive Icon page: the shared machinery and the page-scope vocabulary")
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

    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "tools.PopoutContent(", "tools.ClaimKeys(",
                            "tools.WireModifiedTick(", "tools.WireFooter(",
                            "tools.RegisterHoistedToggle(", "tools.RegisterControlRow(",
                            "GUI:CreateControlRow(", "GatePaneFirstChild", "footerStrip",
                            "inline = true", "popout = true,", "_COUNT = ", "count =",
                            "contentBand", "iconBand", "textBand", "factoryBand",
                            "DefensiveFilterCount", "ApplyDefensiveDurationText",
                            "OnDefensiveEnableToggle", "OnDefensiveBorderToggle",
                            "OnDefensiveDurationToggle", "OnDefensiveDurationBarToggle" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end

    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: every card goes through the shared helper, two per row and dim captions")
    check(PAGE:find("local function CloseSection(band)\n            tools.CloseSection(Add, band)\n        end", 1, true) ~= nil,
          "sections: ...and closes through the shared helper too")

    for _, pair in ipairs({ { "Content", "1" }, { "Icon", "2" }, { "Text", "1" } }) do
        local n = 0
        for _ in PAGE:gmatch('Add%(GUI:CreateHeader%(self%.child, L%["' .. pair[1] .. '"%]%), 40, ' .. pair[2] .. '%)') do n = n + 1 end
        eq(n, 1, "headers: the " .. pair[1] .. " category header sits in column " .. pair[2] .. ", once")
    end

    for _, name in ipairs({ "anchorOptions", "defSortOptions", "defDurFormatOptions",
                            "defBarPositionOptions" }) do
        local decls = 0
        for _ in PAGE:gmatch("local " .. name .. " = {") do decls = decls + 1 end
        eq(decls, 1, "vocab: " .. name .. " is declared exactly once, at page scope")
    end
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

    -- The registry hook block runs ONCE PER PAGE BUILD, in both layouts.
    check(PAGE:find("self.dfDefFilterSignature = RegistrySignature()", 1, true) ~= nil,
          "vocab: the filter-registry signature is taken at page scope")
    local hooks = 0
    for _ in PAGE:gmatch("self:HookScript%(\"OnShow\"") do hooks = hooks + 1 end
    eq(hooks, 1, "vocab: ...and the OnShow invalidation is hooked exactly once")

    -- The page gate, named once; every builder keeps the group gate it had.
    check(PAGE:find("local function DefensiveOffRow(d) return not (d or db).defensiveIconEnabled end", 1, true) ~= nil,
          "gate: the page names its own gate once")
    for _, b in ipairs({ "BuildDefensiveSettingsGroup", "BuildDefensiveFilterGroup",
                         "BuildDefensiveLayoutGroup", "BuildDefensiveAppearanceGroup",
                         "BuildDefensivePositionGroup", "BuildDefensiveDurationGroup",
                         "BuildDefensiveStackGroup" }) do
        check(builderBody(b):find("group.disableChildrenOn = HideDefensiveIconOptions", 1, true) ~= nil,
              "gate: " .. b .. " carries the group gate the classic box had")
    end
    check(builderBody("BuildDefensiveBorderGroup"):find("tools2.group.disableChildrenOn = HideDefensiveIconOptions", 1, true) ~= nil,
          "gate: the border builder carries it too, after the toolkit has mounted")
    check(builderBody("BuildDefensiveDurationBarGroup"):find(
              "group.disableChildrenOn = function(d) return not d.defensiveIconEnabled or not d.defensiveDurationBarEnabled end", 1, true) ~= nil,
          "gate: the Duration Bar keeps its compound gate -- the feature AND the bar")

    check(PAGE:find("GUI:RefreshCurrentPage", 1, true) == nil,
          "rebuild: the page never rebuilds itself, in either layout")
end

-- ============================================================
-- 2. THE NINE BUILDERS, CONTROL BY CONTROL, AND THEIR CARDS
-- Every golden below is the census of the PRE-CHANGE source.
-- ============================================================
local DEFENSIVE_SETTINGS = {
    { "label",    "Shows an icon when party members have a defensive cooldown active (Pain Suppression, Ironbark, etc.).", "(none)", 45 },
    { "checkbox", "Enable Defensive Icon", "defensiveIconEnabled",   30 },
    { "checkbox", "Hide Cooldown Swipe",   "defensiveIconHideSwipe", 30 },
}
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

-- label, stable collapse key, card column, classic box header and column;
-- `dim` = greys with the page gate, `hide` = the factory gate on both halves,
-- `pin` = passes its builder (decides how the icon LOOKS), `tick` = its on/off
-- moved into the header.
local CARDS = {
    { label = "Settings", key = "defensiveicon_settings", col = 1, box = "Settings", classicCol = 1,
      builder = "BuildDefensiveSettingsGroup", golden = DEFENSIVE_SETTINGS, summary = "DefensiveSettingsSummary" },
    { label = "Defensive Filters", key = "defensiveicon_filters", col = 1, box = "Defensive Filters", classicCol = 2,
      builder = "BuildDefensiveFilterGroup", golden = DEFENSIVE_FILTERS, summary = "DefensiveFilterSummary",
      dim = true },
    { label = "Layout", key = "defensiveicon_layout", col = 2, box = "Layout", classicCol = 1,
      builder = "BuildDefensiveLayoutGroup", golden = DEFENSIVE_LAYOUT, summary = "DefensiveLayoutSummary",
      dim = true, pin = true },
    { label = "Appearance", key = "defensiveicon_appearance", col = 2, box = "Appearance", classicCol = 2,
      builder = "BuildDefensiveAppearanceGroup", golden = DEFENSIVE_APPEARANCE, summary = "DefensiveAppearanceSummary",
      dim = true, pin = true },
    { label = "Position", key = "defensiveicon_position", col = 2, box = "Position", classicCol = 1,
      builder = "BuildDefensivePositionGroup", golden = DEFENSIVE_POSITION, summary = "DefensivePositionSummary",
      dim = true, pin = true },
    { label = "Border", key = "defensiveicon_border", col = 2, box = "Border", classicCol = 2,
      builder = "BuildDefensiveBorderGroup", golden = DEFENSIVE_BORDER, summary = "DefensiveBorderSummary",
      dim = true, pin = true, composite = true,
      tick = { key = "defensiveIconShowBorder", name = "Show Border", commit = "ApplyDefensive()" } },
    { label = "Duration Text", key = "defensiveicon_duration", col = 1, box = "Duration Text", classicCol = 1,
      builder = "BuildDefensiveDurationGroup", golden = DEFENSIVE_DURATION, summary = "DefensiveDurationSummary",
      dim = true, pin = true,
      tick = { key = "defensiveIconShowDuration", name = "Show Duration", commit = "ApplyDefensive()" } },
    { label = "Stack Count", key = "defensiveicon_stack", col = 1, box = "Stack Count", classicCol = 1,
      builder = "BuildDefensiveStackGroup", golden = DEFENSIVE_STACK, summary = "DefensiveStackSummary",
      dim = true, hide = true, pin = true },
    { label = "Duration Bar", key = "defensiveicon_durationbar", col = 1, box = "Duration Bar", classicCol = 1,
      builder = "BuildDefensiveDurationBarGroup", golden = DEFENSIVE_DURBAR, summary = "DefensiveDurationBarSummary",
      dim = true, hide = true, pin = true,
      tick = { key = "defensiveDurationBarEnabled", name = "Enable Duration Bar", commit = "DefBarChanged()" } },
}

for _, g in ipairs(CARDS) do
    print("-- Defensive Icon page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())

    local calls = 0
    for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, g.label .. ": declared once, mounted twice -- classic box and card")

    local box
    for at, name in PAGE:gmatch("()local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)") do
        local want = name .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. g.box .. '"])'
        local hit = PAGE:find(want, at, true)
        if hit and hit - at < 900 then box = name break end
    end
    check(box ~= nil, g.label .. ": the classic box keeps its own header (" .. g.box .. ")")
    if box then
        check(PAGE:find("Add(" .. box .. ", nil, " .. g.classicCol .. ")", 1, true) ~= nil,
              g.label .. ": ...which still goes to column " .. g.classicCol)
    end

    local block, call = sectionBlock(g.label)
    check(block:find('OpenSection(L["' .. g.label .. '"], "' .. g.key .. '", ' .. g.col .. ', ' .. g.summary, 1, true) ~= nil,
          g.label .. ": a card keyed " .. g.key .. " in column " .. g.col .. ", printing the group's own summary")

    eq(call:find(g.summary .. ", DefensiveOffRow", 1, true) ~= nil, g.dim == true,
       g.label .. (g.dim and ": greys with the page gate, as its row did" or ": never greys with the page gate -- it holds the switch"))
    eq(call:find("NoFactoryRow", 1, true) ~= nil, g.hide == true,
       g.label .. (g.hide and ": hides, header and band together, on a client with no factory row" or ": carries no hide gate"))
    eq(call:find(g.builder, 1, true) ~= nil, g.pin == true,
       g.label .. (g.pin and ": pinnable, from its own builder" or ": decides what SHOWS, so it grows no pin"))

    if g.tick then
        check(call:find('db = db, key = "' .. g.tick.key .. '", label = L["' .. g.tick.name .. '"]', 1, true) ~= nil,
              g.label .. ": the header tick is bound to " .. g.tick.key .. " under its own name")
        check(call:find("disableOn = DefensiveOffRow", 1, true) ~= nil,
              g.label .. ": ...greyed with the page gate")
        check(call:find("onChanged = function()", 1, true) ~= nil
          and call:find("self:RefreshStates()", 1, true) ~= nil
          and call:find(g.tick.commit, 1, true) ~= nil
          and call:find("RefreshCurrentPage", 1, true) == nil,
              g.label .. ": ...committing what its in-body checkbox ran, never a page rebuild")
        if g.composite then
            check(body:find("tools2.hoistToggle or nil", 1, true) ~= nil,
                  g.label .. ": the composite is told not to build its own toggle")
        else
            local guard = body:find("if not tools2.hoistToggle then", 1, true)
            local cb = body:find('GUI:CreateCheckbox(parent, L["' .. g.tick.name .. '"]', guard or 1, true)
            check(guard ~= nil and cb ~= nil and cb > guard,
                  g.label .. ": the builder builds that checkbox only when not hoisted")
        end
    else
        check(call:find("key = \"", 1, true) == nil, g.label .. ": no header tick")
    end

    local bandName = (g.label == "Defensive Filters") and "fband" or "band"
    local mount = g.builder .. "({ group = " .. bandName .. ", parent = self.child, refreshStates = function() self:RefreshStates() end,"
        .. (g.tick and " hoistToggle = true," or "") .. " })"
    check(block:find(mount, 1, true) ~= nil,
          g.label .. (g.tick and ": mounts the builder as classic does, plus hoistToggle for its header tick"
                              or ": mounts the builder exactly as classic does"))
end

-- ============================================================
-- 3. THE CARDS TOGETHER
-- ============================================================
print("-- Defensive Icon page: the cards together")
do
    -- ☠ THE ADD ORDER IS THE ONE-COLUMN FOLD'S ORDER, so it has to read as the
    -- old bands did: Content, Icon, Text, Duration Bar. Defensive Filters is
    -- opened in the first mount for exactly this reason.
    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "),
       "Settings | Defensive Filters | Layout | Appearance | Position | Border | Duration Text | Stack Count | Duration Bar",
       "order: the nine cards open in the old bands' order -- Content, Icon, Text, Duration Bar")
    local contentAt = PAGE:find('Add(GUI:CreateHeader(self.child, L["Content"]), 40, 1)', 1, true)
    local setAt     = PAGE:find('OpenSection(L["Settings"]', 1, true)
    local filtAt    = PAGE:find('OpenSection(L["Defensive Filters"]', 1, true)
    local iconAt    = PAGE:find('Add(GUI:CreateHeader(self.child, L["Icon"]), 40, 2)', 1, true)
    local layAt     = PAGE:find('OpenSection(L["Layout"]', 1, true)
    local textAt    = PAGE:find('Add(GUI:CreateHeader(self.child, L["Text"]), 40, 1)', 1, true)
    local durAt     = PAGE:find('OpenSection(L["Duration Text"]', 1, true)
    check(contentAt and setAt and filtAt and contentAt < setAt and setAt < filtAt,
          "order: Content heads Settings and Defensive Filters")
    check(filtAt and iconAt and layAt and filtAt < iconAt and iconAt < layAt,
          "order: ...then Icon heads Layout")
    check(textAt and durAt and textAt < durAt, "order: Text heads Duration Text")
    -- The classic Filters arm keeps its else, holding only a pointer to the card.
    check(PAGE:find("Add(filterGroup, nil, 2)\n        else\n            -- Modern opened this card above", 1, true) ~= nil,
          "order: the classic Defensive Filters arm is untouched, its Modern half a pointer")

    -- ---- one checkbox per setting --------------------------------------
    local hoists = 0
    for _ in PAGE:gmatch("hoistToggle = true,") do hoists = hoists + 1 end
    eq(hoists, 3, "ticks: exactly three mounts ask their builder to skip the in-body toggle")
    local inCards = 0
    for _, g in ipairs(CARDS) do
        if g.tick then inCards = inCards + select(2, (sectionBlock(g.label)):gsub("hoistToggle = true,", "")) end
    end
    eq(inCards, hoists, "ticks: ...and every one is a ticked card's -- classic never passes it")

    check((sectionBlock("Settings")):find("defensiveIconEnabled", 1, true) == nil,
          "ticks: Enable Defensive Icon is not hoisted into Settings' header")
    check(builderBody("BuildDefensiveSettingsGroup"):find('L["Enable Defensive Icon"], db, "defensiveIconEnabled"', 1, true) ~= nil,
          "ticks: ...its builder still builds it in the body")

    -- ---- Expand All / Collapse All --------------------------------------
    check(PAGE:find('Add(tools.SectionControls(self.child), 24, "both")', 1, true) ~= nil,
          "bulk: the page adds the pair at the top, spanning both columns")
    local stripAt = PAGE:find("tools.SectionControls", 1, true)
    check(stripAt and contentAt and stripAt < contentAt,
          "bulk: ...above the first category header, because it acts on the whole page")

    -- ---- nine classic boxes, in the order they always had ---------------
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 9, "classic: nine bare 280 boxes, and they are the classic branch's own")
    local ADDS = { "settingsGroup, nil, 1", "layoutGroup, nil, 1", "appearanceGroup, nil, 2",
                   "positionGroup, nil, 1", "borderGroup, nil, 2", "filterGroup, nil, 2",
                   "durationGroup, nil, 1", "defStackGroup, nil, 1", "durBarGroup, nil, 1" }
    local prev = 0
    for _, a in ipairs(ADDS) do
        local at = PAGE:find("Add(" .. a .. ")", 1, true)
        check(at ~= nil and at > prev, "classic: still calls Add(" .. a .. ") in sequence")
        prev = at or prev
    end
    check(PAGE:find("defStackGroup.hideOn = NoFactoryRow", 1, true) ~= nil
      and PAGE:find("durBarGroup.hideOn = NoFactoryRow", 1, true) ~= nil,
          "classic: ...and still puts the factory gate on its two boxes")

    -- ---- the page's own furniture is untouched -------------------------
    check(PAGE:find('CreateCopyButton(self.child, {"defensiveIcon", "defensiveFilterSelection", "defensiveSortOrder", "defensiveDurationBar", "defensiveBar"}', 1, true) ~= nil,
          "page: the copy button keeps the five prefixes it owns")
    check(PAGE:find('{pageId = "general_integrations", label = L["Integrations"]}', 1, true) ~= nil,
          "page: ...and the See Also block is unchanged")
end
