local NS = ...

-- ============================================================
-- HIGHLIGHTS PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Modules.lua
-- ------------------------------------------------------------
-- Indicators > Highlights: FOUR groups inside three classic sections. In Modern
-- they are the Debuff Bar's collapsible CARDS -- two per row inside a card wide
-- enough, dim captions, the value summary in a shut card's corner, Expand All /
-- Collapse All at the top -- one card per group, named for the highlight:
--
--   column 1   Aggro Highlight, Threat Colors (hides, header and band together,
--              while the aggro mode is Hidden)
--   column 2   Selection Highlight, Hover Highlight
--
-- ☠ NOTHING ON THIS PAGE TAKES A HEADER TICK, which is a verdict rather than an
-- omission. Each highlight's master control is its MODE -- a dropdown whose
-- "Hidden" entry is the off switch -- not a boolean. Threat Colors' "Use Custom
-- Colors" is a mode too: with it off the card still does something (the game's
-- own threat palette). There is no page-wide gate either: three independent
-- features, so no card greys another. All four decide how a highlight LOOKS, so
-- all four take a pin.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db -- so this file
-- does what the other census files do: it reads the page's SOURCE and asserts
-- against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each builder -- kind, L key, db key and slot height,
--     in order -- taken from the PRE-CHANGE source. This is also the evidence
--     that CLASSIC RENDERS AS IT DID: the classic branch mounts the same builder
--     into the same 280 box, in the same section, in the same column.
--   ✓ that ONE builder serves both layouts, and the card hands it EXACTLY what
--     classic hands it.
--   ✓ each card's column, stable collapse key, summary, hide gate and pin; that
--     no card carries a tick or a grey.
--   ✓ the two opt-ins (two per row, dim captions) and that no count survives.
--   ✗ nothing about runtime behaviour -- the folding, the two-per-row flow, the
--     dim captions and the hides are read in game.
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

-- The page, scoped by its own two ends: Modules.lua holds several pages, and a
-- bare 280 box on one of the others is not this pass's business.
local PAGE
do
    local a = SRC:find('BuildPage(pageHighlights, function(self, db, Add, AddSpace, AddSyncPoint)', 1, true)
    local b = SRC:find('local pageDispel = CreateSubTab("auras", "auras_dispel", L["Dispel Overlay"])', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Highlights page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- ONE CARD'S BLOCK: its OpenSection call, the builder mount under it and the
-- CloseSection that puts its band in, flattened. `call` is just the OpenSection
-- call -- everything before the band mount -- which is where the pin (a builder
-- argument) and any tick are declared.
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
-- 1. THE SHARED MACHINERY, AND THE POPOUT FURNITURE GONE
-- ============================================================
print("-- Highlights page: the shared machinery and the page-scope vocabulary")
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

    -- ☠ THE ROW FURNITURE IS GONE ENTIRELY, not half-gone: rows, panes on a
    -- plate, claims, counts, footers, the three bands and their applies were all
    -- PopoutRow furniture.
    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "tools.PopoutContent(", "tools.ClaimKeys(",
                            "tools.WireModifiedTick(", "tools.WireFooter(",
                            "tools.RegisterHoistedToggle(", "tools.RegisterControlRow(",
                            "GUI:CreateControlRow(", "GatePaneFirstChild", "footerStrip",
                            "inline = true", "popout = true,", "_COUNT = ", "count =",
                            "selectionBand", "hoverBand", "aggroBand",
                            "ApplySelectionHighlight", "ApplyHoverHighlight", "ApplyAggroHighlight" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end

    -- ---- the section helpers: forwards to the shared ones, with both opt-ins
    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: every card goes through the shared helper, two per row and dim captions")
    check(PAGE:find("local function CloseSection(band)\n            tools.CloseSection(Add, band)\n        end", 1, true) ~= nil,
          "sections: ...and closes through the shared helper too")

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
    for _, g in ipairs({ "HideSelectionOptions", "HideHoverOptions", "HideAggroOptions",
                         "HideAggroModeNone", "HideCustomColorOptions", "HideNonTankingColors" }) do
        local n = 0
        for _ in PAGE:gmatch("local function " .. g .. "%(") do n = n + 1 end
        eq(n, 1, "vocab: " .. g .. " is declared exactly once")
    end

    -- ---- no tick, no page gate, no rebuild ---------------------------
    check(PAGE:find("hoistToggle", 1, true) == nil,
          "ticks: no builder carries a hoist branch -- every master here is a MODE")
    check(PAGE:find("disableChildrenOn", 1, true) == nil,
          "gate: no group-level child gate on this page")
    check(PAGE:find("GUI:RefreshCurrentPage", 1, true) == nil,
          "rebuild: the page never rebuilds itself, in either layout")
    for _, b in ipairs({ "BuildSelectionHighlightGroup", "BuildHoverHighlightGroup",
                         "BuildAggroHighlightGroup", "BuildThreatColorsGroup" }) do
        check(builderBody(b):find("self:RefreshStates()", 1, true) == nil,
              "rebuild: " .. b .. " never reaches past its own tools2 for a state pass")
    end
    check(builderBody("BuildAggroHighlightGroup"):find("tools2.refreshStates()", 1, true) ~= nil,
          "rebuild: the aggro mode and the tanking tick re-gate Threat Colors through the state pass")
    check(builderBody("BuildThreatColorsGroup"):find("tools2.refreshStates()", 1, true) ~= nil,
          "rebuild: ...and Use Custom Colors re-gates its own three swatches the same way")
    check(builderBody("BuildThreatColorsGroup"):find('db, "aggroUseCustomColors"', 1, true) ~= nil,
          "ticks: Use Custom Colors is a mode, not an enable, so it stays in the body")
end

-- ============================================================
-- 2. THE FOUR BUILDERS, CONTROL BY CONTROL, AND THEIR CARDS
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

-- label, stable collapse key, card column, classic box header and column, the
-- summary; `hide` = the hide gate on both halves. Every card pins (all four
-- decide how a highlight LOOKS) and none carries a tick or a grey.
local CARDS = {
    { label = "Selection Highlight", key = "highlights_selection", col = 2,
      box = "Selection Settings", classicCol = 1,
      builder = "BuildSelectionHighlightGroup", golden = SELECTION, summary = "SelectionSettingsSummary" },
    { label = "Hover Highlight", key = "highlights_hover", col = 2,
      box = "Hover Settings", classicCol = 1,
      builder = "BuildHoverHighlightGroup", golden = HOVER, summary = "HoverSettingsSummary" },
    { label = "Aggro Highlight", key = "highlights_aggro", col = 1,
      box = "Aggro Settings", classicCol = 1,
      builder = "BuildAggroHighlightGroup", golden = AGGRO, summary = "AggroSettingsSummary" },
    { label = "Threat Colors", key = "highlights_threat", col = 1,
      box = "Threat Colors", classicCol = 2,
      builder = "BuildThreatColorsGroup", golden = THREAT, summary = "ThreatColorsSummary",
      hide = "HideAggroModeNone" },
}

for _, g in ipairs(CARDS) do
    print("-- Highlights page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())

    -- ONE builder, BOTH layouts: the declaration, the classic box, the card, and
    -- the pin (a builder argument).
    local calls = 0
    for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, g.label .. ": declared once, mounted twice -- classic box and card")

    -- ⚠ THE CLASSIC MOUNT IS AddToSection, NOT Add: every box on this page
    -- belongs to one of the three collapsible sections, and it is that call which
    -- registers it as the section's child.
    local box
    for at, name in PAGE:gmatch("()local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)") do
        local want = name .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. g.box .. '"])'
        local hit = PAGE:find(want, at, true)
        if hit and hit - at < 900 then box = name break end
    end
    check(box ~= nil, g.label .. ": the classic box keeps its own header (" .. g.box .. ")")
    if box then
        check(PAGE:find("AddToSection(" .. box .. ", nil, " .. g.classicCol .. ")", 1, true) ~= nil,
              g.label .. ": ...which still goes to column " .. g.classicCol .. ", inside its section")
    end

    local block, call = sectionBlock(g.label)
    check(block:find('OpenSection(L["' .. g.label .. '"], "' .. g.key .. '", ' .. g.col .. ', ' .. g.summary, 1, true) ~= nil,
          g.label .. ": a card keyed " .. g.key .. " in column " .. g.col .. ", printing the group's own summary")
    check(call:find(g.summary .. ", nil,", 1, true) ~= nil,
          g.label .. ": never greys -- there is no page gate")

    if g.hide then
        check(call:find(g.summary .. ", nil, " .. g.hide .. ", " .. g.builder, 1, true) ~= nil,
              g.label .. ": hides, header and band together, on " .. g.hide)
    else
        check(call:find(g.summary .. ", nil, nil, " .. g.builder, 1, true) ~= nil,
              g.label .. ": carries no hide gate")
    end

    check(call:find(g.builder, 1, true) ~= nil, g.label .. ": pinnable, from its own builder")
    check(call:find("key = \"", 1, true) == nil, g.label .. ": no header tick")

    local mount = g.builder .. "({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end, })"
    check(block:find(mount, 1, true) ~= nil, g.label .. ": mounts the builder exactly as classic does")
end

-- ============================================================
-- 3. THE CARDS TOGETHER, THE BOXES AND THE PAGE'S OWN FURNITURE
-- ============================================================
print("-- Highlights page: the cards together")
do
    -- ⚠ ADDED IN THE ORDER THE THREE SECTIONS HAD, because that is the order a
    -- narrow window folds them back into when the page drops to one column.
    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "),
       "Selection Highlight | Hover Highlight | Aggro Highlight | Threat Colors",
       "order: the four cards open in the order the three sections had")

    -- ---- Expand All / Collapse All --------------------------------------
    check(PAGE:find('Add(tools.SectionControls(self.child), 24, "both")', 1, true) ~= nil,
          "bulk: the page adds the pair at the top, spanning both columns")
    local stripAt = PAGE:find("tools.SectionControls", 1, true)
    local firstAt = PAGE:find("OpenSection(L[", 1, true)
    check(stripAt and firstAt and stripAt < firstAt,
          "bulk: ...above the first card, because it acts on the whole page")

    -- ---- the classic arms, untouched ---------------------------------
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 4, "classic: four bare 280 boxes, and they are the classic branch's own")
    for _, s in ipairs({ "Selection Highlight", "Hover Highlight", "Aggro Highlight" }) do
        check(PAGE:find('GUI:CreateCollapsibleSection(self.child, L["' .. s .. '"], true), 36, "both")', 1, true) ~= nil,
              "classic: still folds " .. s .. " into its own section")
    end
    local sections = 0
    for _ in PAGE:gmatch("GUI:CreateCollapsibleSection%(") do sections = sections + 1 end
    eq(sections, 3, "classic: three sections built directly, and only the classic arms build them")
    check(PAGE:find("local function AddToSection(widget, height, col)", 1, true) ~= nil,
          "classic: the section-registering mount survives for the classic arms")
    check(PAGE:find("threatGroup.hideOn = HideAggroModeNone", 1, true) ~= nil,
          "classic: the Threat Colors box keeps the gate its card now also carries")

    -- ---- the page's own furniture is untouched -------------------------
    check(PAGE:find('CreateCopyButton(self.child, {"selectionHighlight", "hoverHighlight", "aggroHighlight", "aggro"}, L["Highlights"], "indicators_highlights")', 1, true) ~= nil,
          "page: the copy button keeps the four prefixes it owns")
    check(PAGE:find('{pageId = "auras_dispel", label = L["Dispel Overlay"]}', 1, true) ~= nil,
          "page: ...and the See Also block still points at the Dispel Overlay")
end

-- ============================================================
-- 4. THE SUMMARIES
-- Read by eye in the client; what is asserted here is that each one exists, is
-- declared once, joins with the sweep's separator and reads the same tables the
-- controls behind it offer.
-- ============================================================
print("-- Highlights page: the summaries")
do
    check(PAGE:find('local function Join(parts) return table.concat(parts, " \\194\\183 ") end', 1, true) ~= nil,
          "summary: the sweep's separator is named once")
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
    check(PAGE:find("local word = highlightModes[mode]", 1, true) ~= nil,
          "summary: Selection and Hover name the mode from the dropdown's own table")
    check(PAGE:find("local word = aggroModes[mode]", 1, true) ~= nil,
          "summary: ...and Aggro from its own, which has the extra entry")
    check(PAGE:find('if mode == "NONE" then return Join(parts) end', 1, true) ~= nil,
          "summary: a hidden highlight reports its mode and nothing behind it")
    check(PAGE:find('if mode ~= "HEALTH_COLOR" then', 1, true) ~= nil,
          "summary: ...and the aggro health-bar tint has no thickness to report either")
end
