local NS = ...

-- ============================================================
-- TARGETED LIST PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Indicators.lua
-- ------------------------------------------------------------
-- Indicators > Targeted List: THIRTEEN groups. In Modern they are the Debuff
-- Bar's collapsible CARDS -- two per row inside a card wide enough, dim
-- captions, the value summary in a shut card's corner, Expand All / Collapse All
-- at the top -- in the columns and the order the old bands had:
--
--   column 1   "Content"     Settings (holds the PAGE gate, Enable, in its
--                            body -- as every other page's master switch is),
--                            Size & Spacing.
--              "Appearance"  Bar Style, Bar Color, Border (Show Border is the
--                            header's tick), Icon (Show Icon is the header's
--                            tick) and Timing.
--   column 2   "Text"        Show Text, Text Font and the four per-element
--                            position cards.
--
-- ☠ THE ENABLE SWITCH NOW FOLLOWS EVERY OTHER PAGE'S RULE. It was the tick on
-- a Settings row whose controls sat behind a panel -- the only master switch in
-- the addon flipped without seeing what it governed. It is now in the Settings
-- card's body, and the other twelve cards grey their headers with it.
--
-- ☠ THE SHARED MACHINERY IS STILL TAKEN ABOVE THE RAID BAIL: its prologue
-- closes a pinned panel the switch into raid would otherwise strand.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY, so this file reads the page's SOURCE
-- and asserts against it, as the other census files do.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each builder, taken from the PRE-CHANGE source -- the
--     evidence that CLASSIC RENDERS AS IT DID -- and classic's Add order.
--   ✓ that ONE builder serves both layouts, and the card hands it EXACTLY what
--     classic hands it (plus hoistToggle where the tick moved to the header).
--   ✓ each card's column, stable collapse key, summary, grey gate, header tick
--     and pin; that there is one checkbox per setting; the Add order the
--     one-column fold reads in; the preset's no-rebuild path in Modern.
--   ✗ nothing about how any of it LOOKS or behaves in the client.
-- ============================================================

-- ⚠ NORMALISED TO LF UP FRONT. This page file ships CRLF.
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
    CreateFontDropdown = "fontdropdown", CreateOutlineDropdown = "outlinedropdown",
    CreateShadowCheckbox = "shadowcheckbox",
}

-- The body of a `local function <name>(tools2)` at the page builder's own indent.
-- ⚠ TWELVE SPACES, NOT EIGHT. This page's BuildPage body carries one extra
-- indent level and always has; the terminator is that indent.
local function builderBody(name)
    local head = "local function " .. name .. "(tools2)"
    local a = SRC:find(head, 1, true)
    check(a ~= nil, "source: the page declares " .. name)
    if not a then return "" end
    local b = SRC:find("\n            end\n", a, true)
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
    local a = SRC:find('BuildPage(pageTargetedList, function(self, db, Add, AddSpace, AddSyncPoint)', 1, true)
    local b = SRC:find('-- Indicators > Personal Targeted Spells', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Targeted List page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- ONE CARD'S BLOCK: its OpenSection call, the builder mount under it and the
-- CloseSection that puts its band in, flattened. `call` is just the OpenSection
-- call. Timing's band is `tband` (it is opened beside Icon's).
local function sectionBlock(labelKey)
    local a = PAGE:find('OpenSection(L["' .. labelKey .. '"]', 1, true)
    check(a ~= nil, "source: a card is opened for " .. labelKey)
    if not a then return "", "" end
    local b, e = PAGE:find("CloseSection%(t?band%)", a)
    check(b ~= nil, "source: ..." .. labelKey .. "'s band is closed after its controls")
    local block = PAGE:sub(a, e or a):gsub("%s+", " ")
    local m = block:find("({ group = band,", 1, true) or block:find("({ group = tband,", 1, true)
    local call = m and block:sub(1, m) or block
    call = call:gsub("Build[%w]+%($", "")
    return block, call
end

-- ============================================================
-- 1. THE SHARED MACHINERY, ABOVE THE RAID BAIL, AND THE ROWS GONE
-- ============================================================
print("-- Targeted List page: the shared machinery and the page-scope vocabulary")
do
    check(PAGE:find("local classicLayout = DF:IsClassicSettingsLayout()", 1, true) ~= nil,
          "tools: the page asks which layout it is building")
    local at = PAGE:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true)
    local bail = PAGE:find('if GUI.SelectedMode == "raid" then', 1, true)
    check(at ~= nil and bail ~= nil and at < bail,
          "tools: taken unconditionally, before the party-only bail, so a mode switch still closes a pinned panel")
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
                            "contentBand", "appearanceBand", "textBand",
                            "OnTargetedListEnableToggle", "OnTargetedListBorderToggle",
                            "OnTargetedListIconToggle" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end

    local fwd = (PAGE:match("local function OpenSection%(label.-\n            end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: every card goes through the shared helper, two per row and dim captions")
    check(PAGE:find("local function CloseSection(band)\n                tools.CloseSection(Add, band)\n            end", 1, true) ~= nil,
          "sections: ...and closes through the shared helper too")

    for _, pair in ipairs({ { "Content", "1" }, { "Appearance", "1" }, { "Text", "2" } }) do
        local n = 0
        for _ in PAGE:gmatch('Add%(GUI:CreateHeader%(self%.child, L%["' .. pair[1] .. '"%]%), 40, ' .. pair[2] .. '%)') do n = n + 1 end
        eq(n, 1, "headers: the " .. pair[1] .. " category header sits in column " .. pair[2] .. ", once")
    end

    for _, v in ipairs({ "growthOptions", "iconPosOptions", "stylePresetOptions",
                         "sortOptions", "textAnchorOptions", "textAlignOptions" }) do
        local decls = 0
        for _ in PAGE:gmatch("local " .. v .. " = {") do decls = decls + 1 end
        eq(decls, 1, "vocab: " .. v .. " is declared exactly once, at page scope")
    end
    local vocabAt = PAGE:find("local textAlignOptions = {", 1, true)
    for _, b in ipairs({ "BuildTargetedListSettingsGroup", "BuildTargetedListLayoutGroup",
                         "BuildTargetedListPresetGroup", "BuildTargetedListColorGroup",
                         "BuildTargetedListBorderGroup", "BuildTargetedListIconGroup",
                         "BuildTargetedListShowTextGroup", "BuildTargetedListFontGroup",
                         "BuildTargetedListSpellNamePosGroup", "BuildTargetedListTargetNamePosGroup",
                         "BuildTargetedListDurationPosGroup", "BuildTargetedListInterruptPosGroup",
                         "BuildTargetedListTimingGroup" }) do
        local at2 = PAGE:find("local function " .. b .. "(tools2)", 1, true)
        check(at2 ~= nil and vocabAt ~= nil and vocabAt < at2,
              "vocab: " .. b .. " is declared after it, so it closes over the real tables")
    end
    for _, g in ipairs({ "HideTLOptions", "HideIconOptions", "HideTargetNameOptions",
                         "HideSelfTargetOptions", "HideHighlightOptions",
                         "HideDurationPosOptions", "TLOffRow", "TargetedListUpdate" }) do
        local n = 0
        for _ in PAGE:gmatch("local function " .. g .. "%(") do n = n + 1 end
        eq(n, 1, "vocab: " .. g .. " is declared exactly once")
    end

    -- ☠ NO GROUP-LEVEL CHILD GATE: every grey on this page is a per-widget
    -- disableOn, unchanged.
    check(PAGE:find("disableChildrenOn", 1, true) == nil, "gate: no group-level child gate on this page")
    check(PAGE:find("local function TLOffRow(d) return not (d or db).targetedListEnabled end", 1, true) ~= nil,
          "gate: the page gate is named once")
end

-- ============================================================
-- 2. THE PRESET: CLASSIC REBUILDS, MODERN REPAINTS IN PLACE
-- ============================================================
print("-- Targeted List page: the preset's layout-aware refresh")
do
    local n = 0
    for _ in PAGE:gmatch("RefreshCurrentPage") do n = n + 1 end
    eq(n, 2, "rebuild: exactly one guarded RefreshCurrentPage call is left on the page")
    local a = PAGE:find("local function TargetedListPresetChanged(tools2)", 1, true)
    check(a ~= nil, "rebuild: the preset's commit is named once")
    local b = PAGE:find("\n            end\n", a or 1, true)
    local body = PAGE:sub(a or 1, b or (a or 1))
    check(body:find("if tools2.popout or tools then", 1, true) ~= nil,
          "rebuild: a pinned panel AND a Modern card take the in-place path")
    check(body:find("for _, w in ipairs(self.children or {}) do", 1, true) ~= nil
      and body:find("if w.RefreshChildValues then w:RefreshChildValues() end", 1, true) ~= nil,
          "rebuild: ...a card sweeps the VALUES of every band on the page, because a state pass never repaints a value")
    check(body:find("tools.ReflowMounted(true)", 1, true) ~= nil
      and body:find("self:RefreshStates()", 1, true) ~= nil
      and body:find("GUI.RefreshAllOverrideIndicators", 1, true) ~= nil,
          "rebuild: ...plus the pinned panels, the summaries and the override indicators")
    check(body:find("GUI:RefreshCurrentPage()", 1, true) ~= nil,
          "rebuild: ...while classic (no tools) still rebuilds the page, exactly as it always did")
end

-- ============================================================
-- 3. THE THIRTEEN BUILDERS, CONTROL BY CONTROL, AND THEIR CARDS
-- Every golden below is the census of the PRE-CHANGE source.
-- ============================================================
local TL_SETTINGS = {
    { "label",    "Shows a bar when an enemy is casting a spell targeting a party/raid member.", "(none)", 35 },
    { "label",    "(none)",                     "(none)",                        30 },
    { "checkbox", "Enable",                     "targetedListEnabled",           30 },
    { "checkbox", "Important Spells Only",      "targetedListImportantOnly",     30 },
    { "checkbox", "Hide Casts Targeting You",   "targetedListHideOwnCasts",      30 },
    { "checkbox", "Show Untargeted Casts",      "targetedListShowUntargeted",    30 },
    { "checkbox", "Hide Out-of-Combat Casts",   "targetedListHideOutOfCombat",   30 },
    { "checkbox", "Show Offscreen Nameplates",  "(none)",                        30 },
    { "slider",   "Max Bars",                   "targetedListMaxBars",           55 },
}
local TL_LAYOUT = {
    { "slider",   "Bar Width",        "targetedListWidth",     55 },
    { "slider",   "Bar Height",       "targetedListHeight",    55 },
    { "slider",   "Spacing",          "targetedListSpacing",   55 },
    { "dropdown", "Growth Direction", "targetedListGrowth",    55 },
    { "dropdown", "Sort Order",       "targetedListSortOrder", 55 },
}
local TL_PRESET = {
    { "dropdown",        "Bar Style",        "targetedListStylePreset",     55 },
    { "texturedropdown", "Texture",          "targetedListTexture",         55 },
    { "slider",          "Background Alpha", "targetedListBackgroundAlpha", 55 },
}
local TL_COLOR = {
    { "colorpicker", "Interruptible Color",        "targetedListInterruptibleColor",     35 },
    { "colorpicker", "Uninterruptible Color",      "targetedListUninterruptibleColor",   35 },
    { "checkbox",    "Self-Target Color",          "targetedListSelfTargetColorEnabled", 30 },
    { "colorpicker", "Self-Target Color",          "targetedListSelfTargetColor",        35 },
    { "checkbox",    "Highlight Important Spells", "targetedListHighlightImportant",     30 },
    { "colorpicker", "Highlight Color",            "targetedListHighlightColor",         35 },
    { "button",      "Reset Colors to Default",    "(none)",                             30 },
}
local TL_BORDER = {
    { "bordercontrols", "(none)", "targetedList", nil },
}
local TL_ICON = {
    { "checkbox", "Show Icon",     "targetedListShowIcon",     30 },
    { "dropdown", "Icon Position", "targetedListIconPosition", 55 },
    { "checkbox", "Zoom Icon",     "targetedListZoomIcon",     30 },
}
local TL_SHOWTEXT = {
    { "checkbox", "Show Spell Name",         "targetedListShowSpellName",        30 },
    { "checkbox", "Show Target Name",        "targetedListShowTargetName",       30 },
    { "checkbox", "Show Duration",           "targetedListShowDuration",         30 },
    { "checkbox", "Target Name Class Color", "targetedListTargetNameClassColor", 30 },
    { "checkbox", "Show Arrow Prefix",       "targetedListShowArrowPrefix",      30 },
    { "checkbox", "Show Arrow Suffix",       "targetedListShowArrowSuffix",      30 },
}
local TL_FONT = {
    { "fontdropdown",    "Font",      "targetedListFont",        55 },
    { "slider",          "Font Size", "targetedListFontSize",    55 },
    { "outlinedropdown", "Outline",   "targetedListFontOutline", 55 },
    { "shadowcheckbox",  "Shadow",    "targetedListFontOutline", 30 },
}
local TL_SPELLNAME = {
    { "slider",   "Font Size",      "targetedListSpellNameFontSize", 55 },
    { "slider",   "Max Text Width", "targetedListSpellNameWidth",    55 },
    { "dropdown", "Anchor",         "targetedListSpellNameAnchor",   55 },
    { "dropdown", "Alignment",      "targetedListSpellNameAlign",    55 },
    { "slider",   "Offset X",       "targetedListSpellNameX",        55 },
    { "slider",   "Offset Y",       "targetedListSpellNameY",        55 },
}
local TL_TARGETNAME = {
    { "slider",   "Font Size",      "targetedListTargetNameFontSize", 55 },
    { "slider",   "Max Text Width", "targetedListTargetNameWidth",    55 },
    { "dropdown", "Anchor",         "targetedListTargetNameAnchor",   55 },
    { "dropdown", "Alignment",      "targetedListTargetNameAlign",    55 },
    { "slider",   "Offset X",       "targetedListTargetNameX",        55 },
    { "slider",   "Offset Y",       "targetedListTargetNameY",        55 },
}
local TL_DURATIONPOS = {
    { "slider",   "Font Size", "targetedListDurationFontSize", 55 },
    { "dropdown", "Anchor",    "targetedListDurationAnchor",   55 },
    { "dropdown", "Alignment", "targetedListDurationAlign",    55 },
    { "slider",   "Offset X",  "targetedListDurationX",        55 },
    { "slider",   "Offset Y",  "targetedListDurationY",        55 },
}
local TL_INTERRUPTPOS = {
    { "slider",   "Font Size",      "targetedListInterruptTextFontSize", 55 },
    { "slider",   "Max Text Width", "targetedListInterruptTextWidth",    55 },
    { "dropdown", "Anchor",         "targetedListInterruptTextAnchor",   55 },
    { "dropdown", "Alignment",      "targetedListInterruptTextAlign",    55 },
    { "slider",   "Offset X",       "targetedListInterruptTextX",        55 },
    { "slider",   "Offset Y",       "targetedListInterruptTextY",        55 },
}
local TL_TIMING = {
    { "slider", "Fade Out Duration",          "targetedListFadeOutDuration",          55 },
    { "slider", "Interrupted Flash Duration", "targetedListInterruptedFlashDuration", 55 },
}

-- label, stable collapse key, card column, classic box column; `dim` = greys
-- its header with the page gate, `pin` = passes its builder (how a bar LOOKS),
-- `tick` = its on/off moved into the header.
local CARDS = {
    { label = "Settings", key = "targetedlist_settings", col = 1, classicCol = 1,
      builder = "BuildTargetedListSettingsGroup", golden = TL_SETTINGS, summary = "TargetedListSettingsSummary" },
    { label = "Size & Spacing", key = "targetedlist_layout", col = 1, classicCol = 1,
      builder = "BuildTargetedListLayoutGroup", golden = TL_LAYOUT, summary = "TargetedListLayoutSummary",
      dim = true, pin = true },
    { label = "Bar Style", key = "targetedlist_barstyle", col = 1, classicCol = 2,
      builder = "BuildTargetedListPresetGroup", golden = TL_PRESET, summary = "TargetedListPresetSummary",
      dim = true, pin = true },
    { label = "Bar Color", key = "targetedlist_barcolor", col = 1, classicCol = 2,
      builder = "BuildTargetedListColorGroup", golden = TL_COLOR, summary = "TargetedListColorSummary",
      dim = true, pin = true },
    { label = "Border", key = "targetedlist_border", col = 1, classicCol = 2,
      builder = "BuildTargetedListBorderGroup", golden = TL_BORDER, summary = "TargetedListBorderSummary",
      dim = true, pin = true, composite = true,
      tick = { key = "targetedListShowBorder", name = "Show Border" } },
    { label = "Icon", key = "targetedlist_icon", col = 1, classicCol = 2,
      builder = "BuildTargetedListIconGroup", golden = TL_ICON, summary = "TargetedListIconSummary",
      dim = true, pin = true,
      tick = { key = "targetedListShowIcon", name = "Show Icon" } },
    { label = "Timing", key = "targetedlist_timing", col = 1, classicCol = 1, band = "tband",
      builder = "BuildTargetedListTimingGroup", golden = TL_TIMING, summary = "TargetedListTimingSummary",
      dim = true },
    { label = "Show Text", key = "targetedlist_showtext", col = 2, classicCol = 1,
      builder = "BuildTargetedListShowTextGroup", golden = TL_SHOWTEXT, summary = "TargetedListShowTextSummary",
      dim = true },
    { label = "Text Font", key = "targetedlist_font", col = 2, classicCol = 2,
      builder = "BuildTargetedListFontGroup", golden = TL_FONT, summary = "TargetedListFontSummary",
      dim = true, pin = true },
    { label = "Spell Name Position", key = "targetedlist_spellnamepos", col = 2, classicCol = 1,
      builder = "BuildTargetedListSpellNamePosGroup", golden = TL_SPELLNAME, summary = "TargetedListSpellNameSummary",
      dim = true, pin = true },
    { label = "Target Name Position", key = "targetedlist_targetnamepos", col = 2, classicCol = 2,
      builder = "BuildTargetedListTargetNamePosGroup", golden = TL_TARGETNAME, summary = "TargetedListTargetNameSummary",
      dim = true, pin = true },
    { label = "Duration Position", key = "targetedlist_durationpos", col = 2, classicCol = 1,
      builder = "BuildTargetedListDurationPosGroup", golden = TL_DURATIONPOS, summary = "TargetedListDurationPosSummary",
      dim = true, pin = true },
    { label = "Interrupt Text Position", key = "targetedlist_interruptpos", col = 2, classicCol = 2,
      builder = "BuildTargetedListInterruptPosGroup", golden = TL_INTERRUPTPOS, summary = "TargetedListInterruptPosSummary",
      dim = true, pin = true },
}

for _, g in ipairs(CARDS) do
    print("-- Targeted List page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())

    local calls = 0
    for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, g.label .. ": declared once, mounted twice -- classic box and card")

    local box
    for at, name in PAGE:gmatch("()local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)") do
        local want = name .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. g.label .. '"])'
        local hit = PAGE:find(want, at, true)
        if hit and hit - at < 900 then box = name break end
    end
    check(box ~= nil, g.label .. ": the classic box keeps its own header")
    if box then
        check(PAGE:find("Add(" .. box .. ", nil, " .. g.classicCol .. ")", 1, true) ~= nil,
              g.label .. ": ...which still goes to column " .. g.classicCol)
    end

    local block, call = sectionBlock(g.label)
    check(block:find('OpenSection(L["' .. g.label .. '"], "' .. g.key .. '", ' .. g.col .. ', ' .. g.summary, 1, true) ~= nil,
          g.label .. ": a card keyed " .. g.key .. " in column " .. g.col .. ", printing the group's own summary")
    eq(call:find(g.summary .. ", TLOffRow", 1, true) ~= nil, g.dim == true,
       g.label .. (g.dim and ": greys its header with the page gate" or ": never greys -- it holds the switch"))
    eq(call:find(g.builder, 1, true) ~= nil, g.pin == true,
       g.label .. (g.pin and ": pinnable, from its own builder" or ": visibility or behaviour, so it grows no pin"))

    if g.tick then
        check(call:find('db = db, key = "' .. g.tick.key .. '", label = L["' .. g.tick.name .. '"]', 1, true) ~= nil,
              g.label .. ": the header tick is bound to " .. g.tick.key .. " under its own name")
        check(call:find("disableOn = TLOffRow", 1, true) ~= nil,
              g.label .. ": ...greyed with the page gate")
        check(call:find("onChanged = function()", 1, true) ~= nil
          and call:find("self:RefreshStates()", 1, true) ~= nil
          and call:find("TargetedListUpdate()", 1, true) ~= nil
          and call:find("RefreshCurrentPage", 1, true) == nil,
              g.label .. ": ...committing what its in-body checkbox ran, never a page rebuild")
        if g.composite then
            check(body:find("noShowToggle = tools2.hoistToggle or nil", 1, true) ~= nil,
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

    local mount = g.builder .. "({ group = " .. (g.band or "band") .. ", parent = self.child, refreshStates = function() self:RefreshStates() end,"
        .. (g.tick and " hoistToggle = true," or "") .. " })"
    check(block:find(mount, 1, true) ~= nil,
          g.label .. (g.tick and ": mounts the builder as classic does, plus hoistToggle for its header tick"
                              or ": mounts the builder exactly as classic does"))
end

-- ============================================================
-- 4. THE CARDS TOGETHER
-- ============================================================
print("-- Targeted List page: the cards together")
do
    -- ☠ THE ADD ORDER IS THE ONE-COLUMN FOLD'S ORDER: Content, Appearance (with
    -- Timing fifth), Text. Timing is opened beside Icon for exactly this reason.
    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "),
       "Settings | Size & Spacing | Bar Style | Bar Color | Border | Icon | Timing | Show Text | Text Font | Spell Name Position | Target Name Position | Duration Position | Interrupt Text Position",
       "order: the thirteen cards open in the old bands' order -- Content, Appearance, Text")
    local contentAt = PAGE:find('Add(GUI:CreateHeader(self.child, L["Content"]), 40, 1)', 1, true)
    local appAt     = PAGE:find('Add(GUI:CreateHeader(self.child, L["Appearance"]), 40, 1)', 1, true)
    local styleAt   = PAGE:find('OpenSection(L["Bar Style"]', 1, true)
    local textAt    = PAGE:find('Add(GUI:CreateHeader(self.child, L["Text"]), 40, 2)', 1, true)
    local showAt    = PAGE:find('OpenSection(L["Show Text"]', 1, true)
    check(contentAt and appAt and styleAt and contentAt < appAt and appAt < styleAt,
          "order: Content comes first, then Appearance heads Bar Style")
    check(textAt and showAt and textAt < showAt, "order: Text heads Show Text")
    -- Timing's builder is declared before the Icon card that opens it...
    local timingDecl = PAGE:find("local function BuildTargetedListTimingGroup(tools2)", 1, true)
    local timingCard = PAGE:find('OpenSection(L["Timing"]', 1, true)
    check(timingDecl and timingCard and timingDecl < timingCard,
          "order: Timing's builder is declared before the card that calls it")
    -- ...while classic's Timing box is still Add'd last, its Modern half a pointer.
    check(PAGE:find("Add(timingGroup, nil, 1)\n            else\n                -- Modern opened this card above", 1, true) ~= nil,
          "order: the classic Timing arm is untouched, its Modern half a pointer")

    -- ---- one checkbox per setting --------------------------------------
    local hoists = 0
    for _ in PAGE:gmatch("hoistToggle = true,") do hoists = hoists + 1 end
    eq(hoists, 2, "ticks: exactly two mounts ask their builder to skip the in-body toggle (Border, Icon)")
    local inCards = 0
    for _, g in ipairs(CARDS) do
        if g.tick then inCards = inCards + select(2, (sectionBlock(g.label)):gsub("hoistToggle = true,", "")) end
    end
    eq(inCards, hoists, "ticks: ...and every one is a ticked card's -- classic never passes it")

    -- ☠ THE MASTER SWITCH FOLLOWS EVERY OTHER PAGE NOW: in Settings' body.
    check((sectionBlock("Settings")):find("targetedListEnabled", 1, true) == nil,
          "ticks: Enable is not in Settings' header")
    check(builderBody("BuildTargetedListSettingsGroup"):find('L["Enable"], db, "targetedListEnabled"', 1, true) ~= nil,
          "ticks: ...its builder builds it in the body, in both layouts")

    -- ---- Expand All / Collapse All --------------------------------------
    check(PAGE:find('Add(tools.SectionControls(self.child), 24, "both")', 1, true) ~= nil,
          "bulk: the page adds the pair at the top, spanning both columns")
    local stripAt = PAGE:find("tools.SectionControls", 1, true)
    local bail = PAGE:find('if GUI.SelectedMode == "raid" then', 1, true)
    check(stripAt and contentAt and bail and bail < stripAt and stripAt < contentAt,
          "bulk: ...after the raid bail and above the first category header")

    -- ---- thirteen classic boxes, in the order they always had -----------
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 13, "classic: thirteen bare 280 boxes, and they are the classic branch's own")
    local prev = 0
    for _, name in ipairs({ "settingsGroup", "layoutGroup", "presetGroup", "colorGroup",
                            "borderGroup", "iconGroup", "textToggleGroup", "fontGroup",
                            "spellNamePosGroup", "targetNamePosGroup", "durationPosGroup",
                            "interruptPosGroup", "timingGroup" }) do
        local at = PAGE:find("Add(" .. name .. ", nil,", 1, true)
        check(at ~= nil and at > prev, "classic: adds " .. name .. " in its original place")
        prev = at or prev
    end

    -- ---- the page's own furniture is untouched -------------------------
    check(PAGE:find('CreateCopyButton(self.child, {"targetedList"}, L["Targeted List"], "indicators_targetedlist")', 1, true) ~= nil,
          "page: the copy button keeps the prefix it owns")
    check(PAGE:find('{pageId = "indicators_personal_targeted", label = L["Personal Targeted"]}', 1, true) ~= nil,
          "page: ...and the See Also block still points at Personal Targeted")
    check(PAGE:find('L["Targeted List is a Party-only feature. Switch to Party mode to configure."]', 1, true) ~= nil,
          "page: ...and raid mode still gets the party-only message")
    check(PAGE:find("local function TargetedTextSummary(d, prefix)", 1, true) ~= nil,
          "page: the four position cards still share one summary body")
end
