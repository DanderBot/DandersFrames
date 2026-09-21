local NS = ...

-- ============================================================
-- DEBUFF BAR PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Indicators.lua
-- ------------------------------------------------------------
-- Auras > Debuff Bar is the Buff Bar's twin plus two groups the buff row has no
-- use for: FOURTEEN groups. In Modern they are the Buff Bar's collapsible
-- CARDS -- thirteen of them -- and the fourteenth, a lone checkbox (Hide
-- Duplicate Debuffs), moved into Debuff Filters as Hide Duplicate Buffs moved
-- into Buff Filters.
--
--   column 1   "Content"  Visibility, Debuff Filters, Debuff Blacklist,
--                         Order & Limits.
--              ...then    Duration Bar, the 12.1-factory extra, under NO
--                         category header (it can hide).
--   column 2   "Icon"     Appearance, Layout, Position, Border, Important Debuffs.
--              "Text"     Duration Text, Stack Count, Dispel Text.
--
-- ...plus the two things the Buff Bar does NOT opt into, so the two can be
-- compared in game: controls TWO PER ROW inside a wide enough card, and captions
-- drawn dim so a setting never reads as a heading.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db, the blacklist
-- catalog -- so this file does what the other census files do: it reads the
-- page's SOURCE and asserts against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each extracted builder -- kind, L key, db key and
--     slot height, in order -- taken from the PRE-CHANGE source, so a builder
--     that quietly dropped a control or renamed a key fails here. This is also
--     the evidence that CLASSIC RENDERS AS IT DID: the classic branch mounts the
--     same builder into the same 280 box in the same column.
--   ✓ that ONE builder serves both layouts, and the card hands it EXACTLY what
--     classic hands it (plus hoistToggle where the tick moved to the header).
--   ✓ each card's column, stable collapse key, summary, grey gate, hide gate,
--     header tick and pin; that there is one checkbox per setting.
--   ✓ the two Debuff-Bar-only opt-ins, and that the Buff Bar asks for none.
--   ✗ nothing about runtime behaviour -- the folding, the two-per-row flow, the
--     dim captions and the greying are read in game.
-- ============================================================

-- ⚠ NORMALISED TO LF UP FRONT. This page file ships CRLF (the companion's files
-- are mixed per file), and a plain multi-line `find` for source text would miss
-- every one of them otherwise. Nothing here asserts about line endings.
local SRC  = options_file_source("GUI/Pages/Indicators.lua"):gsub("\r\n", "\n")
local CTRL = options_file_source("GUI/Controls.lua"):gsub("\r\n", "\n")
local SW   = options_file_source("GUI/SettingsWidgets.lua"):gsub("\r\n", "\n")

-- ---- the census reader (the Buff Bar page's, plus this page's own kinds) ----
-- The Debuff Bar builds its Duration Text and Stack Count blocks by hand rather
-- than through GUI:CreateTextControls, so the three text factories are kinds in
-- their own right here; the banner and the dispel cross-link are this page's two
-- other composites.
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateSeparator = "separator", CreateButton = "button",
    CreateGrowthControl = "growth", CreateTextureDropdown = "texturedropdown",
    CreateTextControls = "textcontrols", CreateBorderControls = "bordercontrols",
    CreateDurationFormatControls = "durationformat",
    CreateInfoBanner = "banner", CreateFontDropdown = "fontdropdown",
    CreateOutlineDropdown = "outlinedropdown", CreateShadowCheckbox = "shadowcheckbox",
    CreateDispelColorsPageLink = "dispelcolorslink",
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

-- The page, scoped by its own two ends: Indicators.lua holds six pages, and a
-- bare 280 box on one of the others is not this pass's business.
local PAGE
do
    local a = SRC:find('BuildPage(pageDebuffs, function(self, db, Add, AddSpace, AddSyncPoint)', 1, true)
    local b = SRC:find('local pageMissingBuffs = CreateSubTab("auras", "auras_missingbuffs", L["Missing Buffs"])', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Debuff Bar page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- The Buff Bar page, for the checks that say it does NOT take this page's
-- opt-ins. Scoped by its own two ends, like PAGE.
local BUFFPAGE
do
    local a = SRC:find('BuildPage(pageBuffs, function(self, db, Add, AddSpace, AddSyncPoint)', 1, true)
    local b = SRC:find('local pageDebuffs = CreateSubTab("auras", "auras_debuffs", L["Debuff Bar"])', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Buff Bar page builder is locatable by its own ends")
    BUFFPAGE = SRC:sub(a or 1, b or 1)
end

-- The shared section helper and its two opt-ins, in the page tools.
local TOOLS = CTRL:match("\nfunction GUI:CreatePopoutPageTools%(page%)(.-)\nend\n") or ""
local OPEN = (TOOLS:match("\n    local function OpenSection%(Add, .-\n    end\n") or ""):gsub("%s+", " ")
local CLOSE = TOOLS:match("\n    local function CloseSection%(Add, band%)(.-)\n    end\n") or ""

-- ONE SECTION'S BLOCK: its OpenSection call, the builder mount under it and the
-- CloseSection that puts its band in, flattened. `call` is just the OpenSection
-- call -- everything before the band mount -- which is where the pin (a builder
-- argument) and the tick are declared.
local function sectionBlock(labelKey)
    local a = PAGE:find('OpenSection(L["' .. labelKey .. '"]', 1, true)
    check(a ~= nil, "source: a card is opened for " .. labelKey)
    if not a then return "", "" end
    local b = PAGE:find("CloseSection(band)", a, true)
    check(b ~= nil, "source: ..." .. labelKey .. "'s band is closed after its controls")
    local block = PAGE:sub(a, (b or a) + #"CloseSection(band)"):gsub("%s+", " ")
    local m = block:find("({ group = band,", 1, true)
    local call = m and block:sub(1, m) or block
    -- Back off to the start of the builder name that the mount opens with.
    call = call:gsub("Build[%w]+%($", "")
    return block, call
end

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED MACHINERY, AND ITS VOCABULARY MOVED UP
-- ============================================================
print("-- Debuff Bar page: the shared machinery and the page-scope vocabulary")
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

    -- ---- the popout furniture is gone ENTIRELY, not half-gone ----------
    -- No rows, no panes on a plate, no claims, no counts, no footers, no hoisted
    -- search repairs, no control row, no bands and no index-1 repair: all of it
    -- was PopoutRow furniture, and there is no row left to hang it on.
    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "tools.PopoutContent(", "tools.ClaimKeys(",
                            "tools.WireModifiedTick(", "tools.WireFooter(",
                            "tools.RegisterHoistedToggle(", "tools.RegisterControlRow(",
                            "GUI:CreateControlRow(", "GatePaneFirstChild(", "footerStrip",
                            "inline = true", "popout = true,", "_COUNT = ",
                            "contentBand", "iconBand", "textBand", "factoryBand",
                            "DebuffFilterCount", "DebuffBlacklistCount", "OnShowDebuffsToggle" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end

    -- ---- the section helpers: this page's forwards to the shared ones ----
    check(PAGE:find("local function OpenSection(label, key, col, summaryFn, dimFn, hideFn, builder, toggle)", 1, true) ~= nil,
          "sections: the page opens a card in one named place")
    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle,", 1, true) ~= nil,
          "sections: ...forwarding to the SAME helper the Buff Bar uses, argument for argument")
    check(PAGE:find("local function CloseSection(band)\n            tools.CloseSection(Add, band)\n        end", 1, true) ~= nil,
          "sections: ...and closes one through the shared helper too")
    -- The helper itself: the Buff Bar's card, lifted rather than copied.
    check(OPEN:find("GUI:CreateCollapsibleSection(page.child, label, true, BandWidth(col), { collapseKey = key, summary = summaryFn, dimOn = dimFn, pin = pin, card = true, toggle = toggle })", 1, true) ~= nil,
          "sections: the shared helper builds the kit's section as a CARD, expanded on a first run, at its column's width")
    check(OPEN:find("Add(section, 36, col)", 1, true) ~= nil
      and OPEN:find("GUI:CreateSettingsGroup(page.child, BandWidth(col), { chromeless = true })", 1, true) ~= nil
      and OPEN:find("section:RegisterChild(band)", 1, true) ~= nil,
          "sections: ...header and band are both page children, the band registered to the header")
    check(OPEN:find("section.hideOn = hideFn", 1, true) ~= nil and OPEN:find("band.hideOn = hideFn", 1, true) ~= nil,
          "sections: ...a hide gate goes on both halves")
    check(OPEN:find("section.layoutColFill = true", 1, true) ~= nil and OPEN:find("band.layoutColFill = true", 1, true) ~= nil,
          "sections: ...and both halves fill their column")
    check(OPEN:find("RegisterSection(section)", 1, true) ~= nil,
          "sections: ...and every card joins the page's Expand/Collapse roster")
    check(CLOSE:find("Add(band, nil, band.dfSectionCol)", 1, true) ~= nil,
          "sections: the band goes in after its last control, in its section's column")

    -- ---- the three category headers, added straight to a column ----------
    for _, pair in ipairs({ { "Content", "1" }, { "Icon", "2" }, { "Text", "2" } }) do
        local n = 0
        for _ in PAGE:gmatch('Add%(GUI:CreateHeader%(self%.child, L%["' .. pair[1] .. '"%]%), 40, ' .. pair[2] .. '%)') do n = n + 1 end
        eq(n, 1, "headers: the " .. pair[1] .. " category header opens column " .. pair[2] .. ", once")
    end

    -- ---- the vocabulary, at PAGE scope, declared exactly once ---------
    for _, name in ipairs({ "anchorOptions", "debuffSortOptions", "debuffDurationFormatOptions",
                            "durBarPositionOptions", "badgePoints", "dispelModeOptions",
                            "DEBUFF_CATEGORIES" }) do
        local decls = 0
        for _ in PAGE:gmatch("local " .. name .. " = {") do decls = decls + 1 end
        eq(decls, 1, "vocab: " .. name .. " is declared exactly once, at page scope")
    end
    check(PAGE:find('DEFAULT = L["Default (Slot Order)"]', 1, true) ~= nil
      and PAGE:find('TIMER = L["Timer"]', 1, true) ~= nil
      and PAGE:find('ALL    = L["All Dispellable"]', 1, true) ~= nil,
          "vocab: ...and they are the same tables the dropdowns have always offered")
    check(PAGE:find("local blacklistCatalog = (DF.AuraBlacklist and DF.AuraBlacklist.DebuffSpells) or {}", 1, true) ~= nil,
          "vocab: the blacklist catalog is read once, at page scope")
    local vocabAt = PAGE:find("local anchorOptions = {", 1, true)
    for _, b in ipairs({ "BuildDebuffVisibilityGroup", "BuildDebuffFilterGroup",
                         "BuildDebuffBlacklistGroup", "BuildDebuffOrderGroup",
                         "BuildDebuffAppearanceGroup", "BuildDebuffLayoutGroup",
                         "BuildDebuffPositionGroup", "BuildDebuffBorderGroup",
                         "BuildImportantDebuffsGroup", "BuildDebuffDurationGroup",
                         "BuildDebuffStackGroup", "BuildDebuffDispelTextGroup",
                         "BuildDebuffDurationBarGroup" }) do
        local at = PAGE:find("local function " .. b .. "(tools2)", 1, true)
        check(at ~= nil and vocabAt ~= nil and vocabAt < at,
              "vocab: " .. b .. " is declared after it, so it closes over the real tables")
    end
    check(builderBody("BuildDebuffFilterGroup"):find('if db.directDebuffDispellableMode == "ANY" then', 1, true) ~= nil,
          "vocab: the ANY -> ALL self-heal runs inside the group that shows the value")
end

-- ============================================================
-- 2. THE DURATION FORMAT GATE -- a state pass, never a rebuild
-- ============================================================
print("-- Debuff Bar page: the duration format gate")
do
    local gate = PAGE:match("local function DurationFormatRefresh%(tools2%)(.-)\n        end")
    check(gate ~= nil, "format gate: the page decides this once, in a named function")
    if gate then
        check(gate:find("if tools2.popout then", 1, true) ~= nil,
              "format gate: ...branching on whether the group is a pinned panel's")
        check(gate:find("tools2.refreshStates()", 1, true) ~= nil,
              "format gate: ...the panel re-runs its state passes")
        check(gate:find("GUI.RelayoutCurrentPage()", 1, true) ~= nil,
              "format gate: ...and a card or a classic box re-lays the page")
        check(gate:find("GUI:RefreshCurrentPage()", 1, true) == nil,
              "format gate: ...without rebuilding it (the rebuild leaked the page)")
    end
    local rebuilds = 0
    for _ in PAGE:gmatch("GUI:RefreshCurrentPage") do rebuilds = rebuilds + 1 end
    eq(rebuilds, 0, "format gate: no page rebuild left on the page")
    -- The pinned panel's copy declares itself -- in the shared helper, which is
    -- the only place a panel copy is built now.
    check(OPEN:find("builder({ group = group, parent = holder, refreshStates = reflow, popout = true })", 1, true) ~= nil,
          "format gate: the pinned panel's copy is the one mount that says popout")
end

-- ============================================================
-- THE THIRTEEN BUILDERS, CONTROL BY CONTROL
-- Every golden below is the census of the PRE-CHANGE source: same factories,
-- same L keys, same db keys, same slot heights, in the same order.
-- ============================================================
local VISIBILITY = {
    { "checkbox", "Show Debuffs", "showDebuffs", 30 },
    { "slider",   "Max Debuffs",  "debuffMax",   55 },
}
-- The category list is DATA: the caption, the All Debuffs switch, the caution
-- banner, ONE checkbox factory (which the loop over DEBUFF_CATEGORIES goes
-- through) and the dispel-mode dropdown.
local DEBUFF_FILTERS = {
    { "label",    "(none)",              "(none)",                      35 },
    { "checkbox", "All Debuffs",         "directDebuffShowAll",         30 },
    { "banner",   "(none)",              "(none)",                      nil },
    { "checkbox", "(none)",              "(none)",                      30 },
    { "dropdown", "Dispellable Debuffs", "directDebuffDispellableMode", 55 },
}
-- The blacklist is DATA too: the caption, ONE checkbox factory (the loop over
-- the shipped catalog) and the group's own Reset.
local DEBUFF_BLACKLIST = {
    { "label",    "(none)", "(none)", 45 },
    { "checkbox", "(none)", "(none)", 30 },
    { "button",   "Reset",  "(none)", 30 },
}
local DEBUFF_ORDER = {
    { "dropdown", "Sort Order",                 "directDebuffSortOrder",          55 },
    { "checkbox", "My Auras First",             "directDebuffSortMineFirst",      30 },
    { "checkbox", "Reverse Order",              "directDebuffSortReverse",        30 },
    { "checkbox", "Hide Long Debuffs",          "debuffMaxDurationEnabled",       30 },
    { "slider",   "Hide Longer Than (minutes)", "debuffMaxDurationMinutes",       55 },
    { "checkbox", "Keep important debuffs",     "debuffMaxDurationKeepImportant", 30 },
}
local DEBUFF_APPEARANCE = {
    { "slider", "Icon Size", "debuffSize",  55 },
    { "slider", "Scale",     "debuffScale", 55 },
    { "slider", "Alpha",     "debuffAlpha", 55 },
}
local DEBUFF_LAYOUT = {
    { "slider", "Icons Per Row", "debuffWrap",     55 },
    { "slider", "Spacing X",     "debuffPaddingX", 55 },
    { "slider", "Spacing Y",     "debuffPaddingY", 55 },
}
local DEBUFF_POSITION = {
    { "dropdown", "Anchor",   "debuffAnchor",  55 },
    { "growth",   "(none)",   "debuffGrowth",  155 },
    { "slider",   "Offset X", "debuffOffsetX", 55 },
    { "slider",   "Offset Y", "debuffOffsetY", 55 },
}
-- ☠ THREE ENTRIES, NOT ONE, and that is the difference from the buff row: the
-- toolkit's eighteen plus the two controls this group adds by hand and the
-- cross-link under them. The key the census reads off the first is the PREFIX
-- the toolkit is handed, not a setting.
local DEBUFF_BORDER = {
    { "bordercontrols",   "(none)",               "debuff",                   nil },
    { "checkbox",         "Color by Dispel Type", "debuffBorderColorByType",  30 },
    { "slider",           "Dispel Border Inset",  "debuffDispelBorderInset",  55 },
    { "dispelcolorslink", "(none)",               "(none)",                   nil },
}
local DEBUFF_IMPORTANT = {
    { "label",       "Makes boss, role and priority debuffs stand out in the normal debuff row.", "(none)", 30 },
    { "checkbox",    "Highlight Important Debuffs", "debuffImportantHighlight",   30 },
    { "slider",      "Size Step",                   "debuffImportantScale",       55 },
    { "checkbox",    "Show Corner Marker",          "debuffImportantBadge",       30 },
    { "slider",      "Marker Size",                 "debuffImportantBadgeSize",   55 },
    { "dropdown",    "Marker Corner",               "debuffImportantBadgePoint",  55 },
    { "slider",      "Marker Offset X",             "debuffImportantBadgeX",      55 },
    { "slider",      "Marker Offset Y",             "debuffImportantBadgeY",      55 },
    { "colorpicker", "Marker Color",                "debuffImportantBadgeColor",  35 },
    { "colorpicker", "Marker Symbol Color",         "debuffImportantMarkColor",   35 },
}
-- ⚠ HAND-BUILT, not GUI:CreateTextControls. The buff page's Duration Text block
-- went through the shared helper; this one has always spelled its eight text
-- controls out, and the census pins that rather than tidying it -- classic has
-- to render byte for byte what it did.
local DEBUFF_DURATION = {
    { "checkbox",        "Show Duration",                    "debuffShowDuration",              30 },
    { "checkbox",        "Hide Cooldown Swipe",              "debuffHideSwipe",                 30 },
    { "durationformat",  "(none)",                           "debuffDurationFormat",            nil },
    { "fontdropdown",    "Font",                             "debuffDurationFont",              55 },
    { "slider",          "Scale",                            "debuffDurationScale",             55 },
    { "outlinedropdown", "Outline",                          "debuffDurationOutline",           55 },
    { "shadowcheckbox",  "Shadow",                           "debuffDurationOutline",           30 },
    { "dropdown",        "Anchor",                           "debuffDurationAnchor",            55 },
    { "slider",          "Offset X",                         "debuffDurationX",                 55 },
    { "slider",          "Offset Y",                         "debuffDurationY",                 55 },
    { "colorpicker",     "Duration Color",                   "debuffDurationColor",             30 },
    { "checkbox",        "Color by Time Remaining",          "debuffDurationColorByTime",       30 },
    { "checkbox",        "Hide Above Threshold",             "debuffDurationHideAboveEnabled",  30 },
    { "slider",          "Hide Above (seconds)",             "debuffDurationHideAboveThreshold", 55 },
    { "checkbox",        "Hide Duration on Permanent Auras", "debuffDurationHideOnPermanent",   30 },
}
local DEBUFF_STACK = {
    { "fontdropdown",    "Font",     "debuffStackFont",    55 },
    { "slider",          "Scale",    "debuffStackScale",   55 },
    { "outlinedropdown", "Outline",  "debuffStackOutline", 55 },
    { "shadowcheckbox",  "Shadow",   "debuffStackOutline", 30 },
    { "dropdown",        "Anchor",   "debuffStackAnchor",  55 },
    { "slider",          "Offset X", "debuffStackX",       55 },
    { "slider",          "Offset Y", "debuffStackY",       55 },
    { "colorpicker",     "Color",    "debuffStackColor",   30 },
}
-- Dispel Text DOES go through the shared block, which is why it is two entries
-- where Stack Count is eight.
local DEBUFF_DISPEL = {
    { "checkbox",     "Show Dispel Text", "debuffDispelSymbolEnabled", 30 },
    { "textcontrols", "(none)",           "debuffDispelSymbol",        nil },
}
local DEBUFF_DURBAR = {
    { "label",           "Shows a bar on each icon that drains with the aura's remaining time.", "(none)", 30 },
    { "checkbox",        "Enable Duration Bar", "debuffDurationBarEnabled",     30 },
    { "dropdown",        "Position",            "debuffDurationBarPosition",    55 },
    { "slider",          "Height",              "debuffDurationBarHeight",      55 },
    { "slider",          "Gap",                 "debuffDurationBarGap",         55 },
    { "dropdown",        "Color Mode",          "debuffDurationBarColorMode",   55 },
    { "texturedropdown", "Texture",             "debuffDurationBarTexture",     55 },
    { "colorpicker",     "Bar Color",           "debuffDurationBarColor",       30 },
    { "colorpicker",     "Background Color",    "debuffDurationBarBGColor",     30 },
    { "checkbox",        "Reverse Fill",        "debuffDurationBarReverseFill", 30 },
}

-- ---- the thirteen cards ------------------------------------------------
-- label, stable collapse key, card column, classic box header and column, the
-- row's summary; `dim` = greys with the page gate, `hide` = the factory gate on
-- both halves, `pin` = passes its builder (decides how the bar LOOKS), `tick` =
-- its on/off moved into the header.
local CARDS = {
    { label = "Visibility",        key = "debuffs_visibility",  col = 1, box = "Visibility",       classicCol = 1,
      builder = "BuildDebuffVisibilityGroup", golden = VISIBILITY,        summary = "DebuffVisibilitySummary" },
    { label = "Debuff Filters",    key = "debuffs_filters",     col = 1, box = "Debuff Filters",   classicCol = 1,
      builder = "BuildDebuffFilterGroup",     golden = DEBUFF_FILTERS,    summary = "DebuffFilterSummary" },
    { label = "Debuff Blacklist",  key = "debuffs_blacklist",   col = 1, box = "Debuff Blacklist", classicCol = 1,
      builder = "BuildDebuffBlacklistGroup",  golden = DEBUFF_BLACKLIST,  summary = "DebuffBlacklistSummary" },
    { label = "Order & Limits",    key = "debuffs_order",       col = 1, box = "Order & Limits",   classicCol = 1,
      builder = "BuildDebuffOrderGroup",      golden = DEBUFF_ORDER,      summary = "DebuffOrderSummary", dim = true },
    { label = "Appearance",        key = "debuffs_appearance",  col = 2, box = "Appearance",       classicCol = 2,
      builder = "BuildDebuffAppearanceGroup", golden = DEBUFF_APPEARANCE, summary = "DebuffAppearanceSummary",
      dim = true, pin = true },
    { label = "Layout",            key = "debuffs_layout",      col = 2, box = "Layout",           classicCol = 1,
      builder = "BuildDebuffLayoutGroup",     golden = DEBUFF_LAYOUT,     summary = "DebuffLayoutSummary", dim = true, pin = true },
    { label = "Position",          key = "debuffs_position",    col = 2, box = "Position",         classicCol = 1,
      builder = "BuildDebuffPositionGroup",   golden = DEBUFF_POSITION,   summary = "DebuffPositionSummary", dim = true, pin = true },
    { label = "Border",            key = "debuffs_border",      col = 2, box = "Border",           classicCol = 1,
      builder = "BuildDebuffBorderGroup",     golden = DEBUFF_BORDER,     summary = "DebuffBorderSummary",
      dim = true, pin = true,
      tick = { key = "debuffShowBorder", name = "Show Border" }, composite = true },
    { label = "Important Debuffs", key = "debuffs_important",   col = 2, box = nil,                classicCol = 2,
      builder = "BuildImportantDebuffsGroup", golden = DEBUFF_IMPORTANT,  summary = "ImportantDebuffsSummary",
      dim = true, pin = true, tick = { key = "debuffImportantHighlight", name = "Highlight Important Debuffs" } },
    { label = "Duration Text",     key = "debuffs_duration",    col = 2, box = "Duration Text",    classicCol = 2,
      builder = "BuildDebuffDurationGroup",   golden = DEBUFF_DURATION,   summary = "DebuffDurationSummary",
      dim = true, pin = true, tick = { key = "debuffShowDuration", name = "Show Duration" } },
    { label = "Stack Count",       key = "debuffs_stack",       col = 2, box = "Stack Count",      classicCol = 2,
      builder = "BuildDebuffStackGroup",      golden = DEBUFF_STACK,      summary = "DebuffStackSummary", dim = true, pin = true },
    { label = "Dispel Text",       key = "debuffs_dispeltext",  col = 2, box = "Dispel Text",      classicCol = 2,
      builder = "BuildDebuffDispelTextGroup", golden = DEBUFF_DISPEL,     summary = "DebuffDispelSummary",
      dim = true, hide = true, pin = true,
      tick = { key = "debuffDispelSymbolEnabled", name = "Show Dispel Text" } },
    { label = "Duration Bar",      key = "debuffs_durationbar", col = 1, box = "Duration Bar",     classicCol = 2,
      builder = "BuildDebuffDurationBarGroup", golden = DEBUFF_DURBAR,    summary = "DebuffDurationBarSummary",
      dim = true, hide = true, pin = true,
      tick = { key = "debuffDurationBarEnabled", name = "Enable Duration Bar" } },
}

for _, g in ipairs(CARDS) do
    print("-- Debuff Bar page: " .. g.label)
    local body = builderBody(g.builder)
    -- The census is the PRE-CHANGE one: classic renders what it always did.
    checkCensus(census(body), g.golden, g.label:lower())

    -- ONE builder, BOTH layouts: the declaration, the classic box's mount and the
    -- card's. (The pin's panel copy is built by the shared helper, which calls
    -- whatever builder it was handed -- not a fourth call site here.)
    local calls = 0
    for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, g.label .. ": declared once, mounted twice -- classic box and card")

    -- The classic box, with its own header, in the column it always had.
    if g.box then
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
    end

    local block, call = sectionBlock(g.label)
    -- ☠ A STABLE COLLAPSE KEY, NEVER THE TITLE, and the card's column.
    check(block:find('OpenSection(L["' .. g.label .. '"], "' .. g.key .. '", ' .. g.col .. ', ' .. g.summary, 1, true) ~= nil,
          g.label .. ": a card keyed " .. g.key .. " in column " .. g.col .. ", printing the row's own summary")

    -- The page gate: exactly the cards whose rows greyed.
    local dimmed = call:find(g.summary .. ", DebuffsOffRow", 1, true) ~= nil
    eq(dimmed, g.dim == true,
       g.label .. (g.dim and ": greys with the page gate, as its row did" or ": never greys with the page gate, as its row never did"))

    -- The factory gate, on both halves (see the shared helper).
    eq(call:find("NoFactoryRow", 1, true) ~= nil, g.hide == true,
       g.label .. (g.hide and ": hides, header and band together, on a client with no factory row" or ": carries no hide gate"))

    -- ☠ THE PIN: the section's OWN builder handed to OpenSection, and only on a
    -- card that decides how the bar LOOKS.
    eq(call:find(g.builder, 1, true) ~= nil, g.pin == true,
       g.label .. (g.pin and ": pinnable, from its own builder" or ": decides what SHOWS, so it grows no pin"))

    -- The header tick, and the in-body copy it replaces.
    if g.tick then
        check(call:find('db = db, key = "' .. g.tick.key .. '", label = L["' .. g.tick.name .. '"]', 1, true) ~= nil,
              g.label .. ": the header tick is bound to " .. g.tick.key .. " under its own name")
        check(call:find("disableOn = DebuffsOffRow", 1, true) ~= nil,
              g.label .. ": ...greyed by the gate its in-body checkbox carried")
        check(call:find("onChanged = function()", 1, true) ~= nil
          and call:find("self:RefreshStates()", 1, true) ~= nil
          and call:find("RefreshCurrentPage", 1, true) == nil,
              g.label .. ": ...committing through a state pass, never a page rebuild")
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
        check(call:find("key = \"", 1, true) == nil,
              g.label .. ": no header tick")
    end

    -- The card hands the builder EXACTLY what classic hands it, plus hoistToggle
    -- where the tick moved to the header -- so there is ONE checkbox per setting.
    local mount = g.builder .. "({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end,"
        .. (g.tick and " hoistToggle = true," or "") .. " })"
    check(block:find(mount, 1, true) ~= nil,
          g.label .. (g.tick and ": mounts the builder as classic does, plus hoistToggle for its header tick"
                              or ": mounts the builder exactly as classic does"))

end

print("-- Debuff Bar page: the cards together")
do
    -- ---- the order, which is also the one-column fold's order ----------
    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "),
       "Visibility | Debuff Filters | Debuff Blacklist | Order & Limits | Appearance | Layout | Position | Border | Important Debuffs | Duration Text | Stack Count | Dispel Text | Duration Bar",
       "order: the thirteen cards open in the order the old bands read: Content, Icon, Text, Duration Bar")
    -- The two category headers in column 2 open ABOVE the card that leads them.
    local iconAt = PAGE:find('Add(GUI:CreateHeader(self.child, L["Icon"]), 40, 2)', 1, true)
    local appAt  = PAGE:find('OpenSection(L["Appearance"]', 1, true)
    local textAt = PAGE:find('Add(GUI:CreateHeader(self.child, L["Text"]), 40, 2)', 1, true)
    local durAt  = PAGE:find('OpenSection(L["Duration Text"]', 1, true)
    check(iconAt and appAt and iconAt < appAt, "order: Icon heads Appearance")
    check(textAt and durAt and textAt < durAt, "order: Text heads Duration Text")

    -- ---- one checkbox per setting --------------------------------------
    -- Five ticks, five hoists, every hoist inside a ticked card -- so the classic
    -- boxes still build their checkbox and no card builds it twice.
    local hoists = 0
    for _ in PAGE:gmatch("hoistToggle = true,") do hoists = hoists + 1 end
    eq(hoists, 5, "ticks: exactly five mounts ask their builder to skip the in-body toggle")
    local inCards = 0
    for _, g in ipairs(CARDS) do
        if g.tick then inCards = inCards + select(2, (sectionBlock(g.label)):gsub("hoistToggle = true,", "")) end
    end
    eq(inCards, hoists, "ticks: ...and every one is a ticked card's -- classic never passes it")

    -- ☠ NOT VISIBILITY. Show Debuffs is the page's master switch: it stays in the
    -- body, built by the builder, exactly as Show Buffs does on the Buff Bar.
    check((sectionBlock("Visibility")):find("showDebuffs", 1, true) == nil,
          "ticks: Show Debuffs is not hoisted into Visibility's header")
    check(builderBody("BuildDebuffVisibilityGroup"):find('L["Show Debuffs"], db, "showDebuffs"', 1, true) ~= nil,
          "ticks: ...its builder still builds it in the body")

    -- ---- Expand All / Collapse All --------------------------------------
    check(PAGE:find('Add(tools.SectionControls(self.child), 24, "both")', 1, true) ~= nil,
          "bulk: the page adds the pair at the top, spanning both columns")
    local stripAt   = PAGE:find("tools.SectionControls", 1, true)
    local contentAt = PAGE:find('Add(GUI:CreateHeader(self.child, L["Content"]), 40, 1)', 1, true)
    check(stripAt and contentAt and stripAt < contentAt,
          "bulk: ...above the first category header, because it acts on the whole page")

    -- ---- Hide Duplicate Debuffs moved INTO Debuff Filters ----------------
    local filters = sectionBlock("Debuff Filters")
    check(filters:find('band:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Duplicate Debuffs"], db, "debuffDeduplicateDesigner", DebuffFilterChanged), 30)', 1, true) ~= nil,
          "dedup: Hide Duplicate Debuffs sits at the foot of Debuff Filters -- it decides which debuffs show")
    check(filters:find("dedupCb.tooltip = DEDUP_TIP", 1, true) ~= nil,
          "dedup: ...with the tooltip it always had")
    check(filters:find("dedupCb.fullRow = true", 1, true) ~= nil,
          "dedup: ...on a row of its own")
    local tips = 0
    for _ in PAGE:gmatch("local DEDUP_TIP = L%[") do tips = tips + 1 end
    eq(tips, 1, "dedup: the tooltip is declared once, for both layouts")
    local tipAt = PAGE:find("local DEDUP_TIP = L[", 1, true)
    local filtersAt = PAGE:find('OpenSection(L["Debuff Filters"]', 1, true)
    check(tipAt and filtersAt and tipAt < filtersAt, "dedup: ...above the card that uses it")
    -- Classic keeps its own box.
    check(PAGE:find('GUI:CreateHeader(self.child, L["Deduplication"])', 1, true) ~= nil
      and PAGE:find('GUI:CreateCheckbox(self.child, L["Hide Duplicate Debuffs"], db, "debuffDeduplicateDesigner", DebuffFilterChanged)', 1, true) ~= nil
      and PAGE:find("Add(dedupGroup, nil, 1)", 1, true) ~= nil,
          "dedup: classic still builds its own Deduplication box in column 1")

    -- ---- the Important Debuffs swatch stays classic-only -----------------
    check(PAGE:find("local impSwatch = GUI:AttachHeaderSwatch(impHeader, 13, 2)", 1, true) ~= nil,
          "swatch: the classic box still hangs the marker preview off its header")
    check(builderBody("BuildImportantDebuffsGroup"):find("AttachHeaderSwatch", 1, true) == nil,
          "swatch: ...the shared builder never touches it")
    check(PAGE:find("if UpdateImportantSwatch then UpdateImportantSwatch() end", 1, true) ~= nil,
          "swatch: ...and the shared callback guards it, so the card's nil is safe")

    -- ---- fourteen classic boxes, in the order they always had ----------
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 14, "classic: fourteen bare 280 boxes, and they are the classic branch's own")
    local ADDS = { "visibilityGroup, nil, 1", "filterGroup, nil, 1", "blGroup, nil, 1",
                   "debuffOrderGroup, nil, 1", "dedupGroup, nil, 1", "appearanceGroup, nil, 2",
                   "gridGroup, nil, 1", "positionGroup, nil, 1", "borderGroup, nil, 1",
                   "impGroup, nil, 2", "durationGroup, nil, 2", "stackCountGroup, nil, 2",
                   "symbolGroup, nil, 2", "durBarGroup, nil, 2" }
    local prev = 0
    for _, a in ipairs(ADDS) do
        local at = PAGE:find("Add(" .. a .. ")", 1, true)
        check(at ~= nil and at > prev, "classic: still calls Add(" .. a .. ") in sequence")
        prev = at or prev
    end
    check(PAGE:find("durBarGroup.hideOn = NoFactoryRow", 1, true) ~= nil
      and PAGE:find("symbolGroup.hideOn = NoFactoryRow", 1, true) ~= nil,
          "classic: ...and still puts the factory gate on its two boxes")

    -- ---- the page's own furniture is untouched -------------------------
    check(PAGE:find('CreateCopyButton(self.child, {"debuff", "showDebuffs", "directDebuff", "debuffBlacklist"}', 1, true) ~= nil,
          "page: the copy button keeps the four prefixes it owns")
    check(PAGE:find('{pageId = "auras_dispel", label = L["Dispel Overlay"]}', 1, true) ~= nil,
          "page: ...and the See Also block is unchanged")
    check(PAGE:find("No Pandemic box here, unlike Buffs", 1, true) ~= nil,
          "page: ...and the note saying why there is no Pandemic card survives")
end

-- ============================================================
-- 3. THE TWO DEBUFF-BAR-ONLY OPT-INS, AND THE BUFF BAR TAKING NONE
-- ============================================================
print("-- Debuff Bar page: two per row and quiet captions -- opt-in")
do
    -- ---- who asks -------------------------------------------------------
    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("{ twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "opt-in: every Debuff Bar card asks for two tracks and quiet captions")
    check(BUFFPAGE:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle)\n", 1, true) ~= nil,
          "opt-in: the Buff Bar forwards with NO extra argument")
    for _, word in ipairs({ "twoTrack", "quietLabels" }) do
        check(BUFFPAGE:find(word, 1, true) == nil, "opt-in: ...and never mentions " .. word)
    end
    -- In the helper: each opt-in is read off `extra` and nothing else, so a
    -- caller that passes none builds exactly the Buff Bar's card.
    check(OPEN:find("if extra and extra.twoTrack then WireTwoTrack(band) end", 1, true) ~= nil,
          "opt-in: two tracks only when asked")
    check(OPEN:find("if extra and extra.quietLabels then band.dfQuietLabels = true end", 1, true) ~= nil,
          "opt-in: quiet captions only when asked")
    check(CLOSE:find("if band.dfTwoTrack then StampFullRows(band) end", 1, true) ~= nil
      and CLOSE:find("if band.dfQuietLabels then QuietLabels(band) end", 1, true) ~= nil,
          "opt-in: ...and the band's children are touched only on an opted-in band, after the builder filled it")

    -- ---- two per row: the kit's grid, the number chosen per pass --------
    check(TOOLS:find("local SECTION_TWO_TRACK_MIN = 2 * 200 + (GUI.SettingsBox and GUI.SettingsBox.innerGap or 10)", 1, true) ~= nil,
          "two tracks: a second track needs 200px per control plus the kit's own gutter")
    local wire = TOOLS:match("local function WireTwoTrack%(band%)(.-)\n    end\n") or ""
    check(wire:find("band.LayoutChildren = function(self)", 1, true) ~= nil
      and wire:find("self.innerColumns = (inner >= SECTION_TWO_TRACK_MIN) and 2 or nil", 1, true) ~= nil
      and wire:find("local h = layout(self)", 1, true) ~= nil,
          "two tracks: decided on EVERY layout pass off the live width, then the kit's own grid lays it out")
    local nb = select(2, wire:gsub("self%.innerColumns", ""))
    local at1 = wire:find("self.innerColumns = ", 1, true)
    local at2 = wire:find("local h = layout(self)", 1, true)
    check(at1 and at2 and at1 < at2, "two tracks: ...the count is set BEFORE the kit runs")
    for _, verb in ipairs({ "RefreshCurrentPage", "BuildPage", "DoBuild", "Invalidate" }) do
        check(wire:find(verb, 1, true) == nil, "two tracks: ...relayout only, never " .. verb)
    end
    check(ui_file_source("Sections.lua"):find('local columns = rawget(self, "innerColumns") or 1', 1, true) ~= nil,
          "two tracks: the kit re-reads the count on every pass, so a fold or a resize re-flows without a rebuild")
    -- A gate stays in reading order beside what it gates: All Debuffs, which
    -- overrides the whole list, takes a row of its own; so does the moved dedup.
    check(builderBody("BuildDebuffFilterGroup"):find("showAllCb.fullRow = true", 1, true) ~= nil,
          "two tracks: All Debuffs heads the category list on a row of its own")

    -- ---- quiet captions ---------------------------------------------------
    local quiet = TOOLS:match("local function QuietLabel%(fs%)(.-)\n    end\n") or ""
    check(quiet:find("return set(self, C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, a)", 1, true) ~= nil,
          "quiet: a live caption draws in the theme's dim text colour")
    check(quiet:find("return set(self, C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.5)", 1, true) ~= nil,
          "quiet: ...a greyed one stays dim at half alpha, so off still reads as off")
    check(quiet:find("return set(self, r, g, b, a)", 1, true) ~= nil,
          "quiet: ...and any other colour passes straight through")
    check(quiet:find("SetFont", 1, true) == nil and quiet:find("upper", 1, true) == nil,
          "quiet: the font object is untouched and nothing is upper-cased")
    local labels = TOOLS:match("local function QuietLabels%(band%)(.-)\n    end\n") or ""
    check(labels:find('rawget(w, "rowKind") ~= "checkbox"', 1, true) ~= nil,
          "quiet: a checkbox's caption IS the control, so it keeps its colour")
    check(labels:find('rawget(w, "refreshValue") ~= nil', 1, true) ~= nil,
          "quiet: only bound controls are touched -- prose, notes and links are not captions")
    -- The contrast claim, on the real palette: dim text on the card's fill.
    local THEME = ui_file_source("Theme.lua")
    local function rgb(name)
        local r, g, b = THEME:match("local " .. name .. "%s*=%s*{r = ([%d%.]+), g = ([%d%.]+), b = ([%d%.]+)")
        return tonumber(r), tonumber(g), tonumber(b)
    end
    local function lum(r, g, b)
        local function ch(c) return (c <= 0.03928) and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end
        return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)
    end
    local dr, dg, db2 = rgb("C_TEXT_DIM")
    local pr, pg, pb = rgb("C_PANEL")
    check(dr and pr, "quiet: the palette is readable from Theme.lua")
    if dr and pr then
        local L1, L2 = lum(dr, dg, db2), lum(pr, pg, pb)
        local ratio = (math.max(L1, L2) + 0.05) / (math.min(L1, L2) + 0.05)
        check(ratio >= 4.5, string.format("quiet: the dim caption is %.2f:1 on the card's fill -- at least 4.5:1", ratio))
    end

    -- ---- NO HEADER PREVIEWS -------------------------------------------
    -- ☠ REMOVED ON PURPOSE (the author: "they will never be accurate; test mode
    -- is 99% accurate, so no need for demo icons"). Pinned as ABSENT so they
    -- cannot creep back: no preview option on the section, no preview argument
    -- through the helper or the page, no picture functions, and -- above all --
    -- no hook on the function every settings write passes through.
    local fn = SW:match("function GUI:CreateCollapsibleSection%(.-\nend\n") or ""
    check(fn ~= "", "no preview: the section factory is readable")
    for _, word in ipairs({ "opts.preview", "previewFn", "RefreshPreview", "previewBesideTitle",
                            "_PlacePreviewBesideTitle", "previewReserve", "_previewNoRoom",
                            "_applyHeaderRow", "_dfPreviewSig" }) do
        check(fn:find(word, 1, true) == nil, "no preview: the section factory has no " .. word)
    end
    for _, word in ipairs({ "PreviewSignature", "TrackPreviewSection", "previewSections",
                            "previewHooked" }) do
        check(SW:find(word, 1, true) == nil, "no preview: SettingsWidgets has no " .. word)
    end
    -- No file in the companion hooks the settings-write path.
    for _, path in ipairs({ "GUI/SettingsWidgets.lua", "GUI/Controls.lua", "GUI/Pages/Indicators.lua" }) do
        local src = options_file_source(path)
        check(src:find('"OnSettingWritten"', 1, true) == nil,
              "no preview: " .. path .. " hooks nothing onto OnSettingWritten")
    end
    check(TOOLS:find("extra.preview", 1, true) == nil,
          "no preview: the shared section helper passes no preview")
    check(OPEN:find("preview", 1, true) == nil, "no preview: OpenSection mentions no preview at all")
    for _, name in ipairs({ "AppearancePreview", "BorderPreview", "DispelPreview", "DurationBarPreview",
                            "PREVIEW_WHITE", "PREVIEW_OFF", "PreviewColor" }) do
        check(PAGE:find(name, 1, true) == nil, "no preview: the page declares no " .. name)
    end
    -- ...while the designers' own right-end swatches are still there.
    check(fn:find('slot:SetPoint("RIGHT", self, "RIGHT", x, 0)', 1, true) ~= nil,
          "no preview: the existing SetPreviewIcons placement is untouched")
end

-- ============================================================
-- 4. THE SHARED-MACHINERY CHANGE THIS PAGE NEEDED (still true for the
--    pinned panel, which mounts the Debuff Filters banner in a pane)
-- ============================================================
print("-- Debuff Bar page: the shared machinery it needed")
do
    check(CTRL:find("pane.dfReflowPane = function() ReflowPane(st) end", 1, true) ~= nil,
          "relayout: the toolkit stamps the pane with its own re-flow at the mount")
    check(SW:find('if type(p.dfReflowPane) == "function" then', 1, true) ~= nil,
          "relayout: ...and RelayoutHost's walk stops at it")
    check(builderBody("BuildDebuffFilterGroup"):find("GUI:CreateInfoBanner(parent, {", 1, true) ~= nil,
          "relayout: the caution banner is built by the shared builder, so a pinned panel really does mount one")
end
