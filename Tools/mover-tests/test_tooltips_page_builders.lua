local NS = ...

-- ============================================================
-- TOOLTIPS PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Options.lua
-- ------------------------------------------------------------
-- Display > Tooltips: SEVEN groups. In Modern they are the Debuff Bar's
-- collapsible CARDS -- two per row inside a card wide enough, dim captions, the
-- value summary in a shut card's corner, Expand All / Collapse All at the top:
--
--   column 1   "Unit Frame"  Frame Tooltips, Binding Tooltips (enables in the
--                            header), Resurrection Icon Tooltips (its one
--                            checkbox in the body)
--   column 2   "Auras"       Buff, Debuff, Defensive Icon (enables in the
--                            header) and Aura Designer Tooltips (NO tick --
--                            three independent surfaces)
--
-- When and where a tooltip appears is behaviour, so no card is pinnable.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY, so this file reads the page's SOURCE.
--   ✓ the widget CENSUS of each builder -- taken from the PRE-CHANGE source, so
--     it is also the evidence that CLASSIC RENDERS AS IT DID.
--   ✓ that ONE builder serves both layouts, and the card hands it exactly what
--     classic hands it (plus hoistToggle where the tick moved to the header).
--   ✓ each card's column, stable collapse key, summary, tick and (absent) pin.
--   ✗ nothing about runtime behaviour -- read in game.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Options.lua"):gsub("\r\n", "\n")

-- ---- the census reader (the Frame page's, verbatim) ------------------
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
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

local PAGE
do
    local a = SRC:find('Add(CreateCopyButton(self.child, {"tooltip"}, L["Tooltips"], "display_tooltips")', 1, true)
    local b = SRC:find('{pageId = "auras_auradesigner", label = L["Aura Designer"]}', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Tooltips page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- ONE CARD'S BLOCK: its OpenSection call up to the CloseSection that puts its
-- band in, flattened; `call` is everything before the builder mount.
local function sectionBlock(labelKey, builder)
    local a = PAGE:find('OpenSection(L["' .. labelKey .. '"]', 1, true)
    check(a ~= nil, "source: a card is opened for " .. labelKey)
    if not a then return "", "" end
    local b = PAGE:find("CloseSection(band)", a, true)
    check(b ~= nil, "source: ..." .. labelKey .. "'s band is closed after its controls")
    local block = PAGE:sub(a, (b or a) + #"CloseSection(band)"):gsub("%s+", " ")
    local m = builder and block:find(builder .. "({", 1, true)
        or block:find("band:AddWidget(", 1, true)
    return block, m and block:sub(1, m - 1) or block
end

-- ============================================================
-- 1. THE SHARED MACHINERY, THE VOCABULARY, AND THE ROW FURNITURE GONE
-- ============================================================
print("-- Tooltips page: the shared machinery and the page-scope vocabulary")
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
    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "GUI:CreateControlRow(", "tools.PopoutContent(",
                            "tools.ClaimKeys(", "tools.WireModifiedTick(", "tools.WireFooter(",
                            "tools.RegisterHoistedToggle(", "tools.RegisterControlRow(",
                            "footerStrip", "inline = true", "popout = true,", "_COUNT", "count =",
                            "frameBand", "auraBand", "resBand", "chromeless",
                            "OnFrameTipToggle", "OnBindTipToggle", "OnBuffTipToggle",
                            "OnDebuffTipToggle", "OnDefTipToggle" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end

    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: every card goes through the shared helper, two per row and dim captions")
    check(PAGE:find("local function CloseSection(band)\n            tools.CloseSection(Add, band)\n        end", 1, true) ~= nil,
          "sections: ...and closes through the shared helper too")

    for _, pair in ipairs({ { "Unit Frame", "1" }, { "Auras", "2" } }) do
        local n = 0
        for _ in PAGE:gmatch('Add%(GUI:CreateHeader%(self%.child, L%["' .. pair[1] .. '"%]%), 40, ' .. pair[2] .. '%)') do n = n + 1 end
        eq(n, 1, "headers: the " .. pair[1] .. " category header opens column " .. pair[2] .. ", once")
    end

    -- The five Anchor To value lists, at page scope, once each: the summaries
    -- print the chosen anchor out of the same table the dropdown offers.
    for _, pair in ipairs({
        { "frameAnchorValues",  "Unit Frame" }, { "bindAnchorValues",   "Unit Frame" },
        { "buffAnchorValues",   "Buff Icon" },  { "debuffAnchorValues", "Debuff Icon" },
        { "defAnchorValues",    "Defensive Icon" },
    }) do
        local decl = PAGE:match("local " .. pair[1] .. " = {(.-)}")
        check(decl ~= nil and decl:find('FRAME = L["' .. pair[2] .. '"]', 1, true) ~= nil,
              "vocab: " .. pair[1] .. " is declared at page scope and names the frame case " .. pair[2])
        local decls = 0
        for _ in PAGE:gmatch("local " .. pair[1] .. " = {") do decls = decls + 1 end
        eq(decls, 1, "vocab: " .. pair[1] .. " is declared exactly once")
    end
    local refreshAt = PAGE:find("local RefreshAuraTooltips = function()", 1, true)
    for _, b in ipairs({ "BuildBuffTooltipGroup", "BuildDebuffTooltipGroup",
                         "BuildDefTooltipGroup", "BuildADTooltipGroup" }) do
        local at = PAGE:find("local function " .. b .. "(tools2)", 1, true)
        check(at ~= nil and refreshAt ~= nil and refreshAt < at,
              "vocab: " .. b .. " is declared after RefreshAuraTooltips, so it closes over the real function")
    end
end

-- ============================================================
-- 2. THE ANCHOR GATE -- a state pass, never a rebuild
-- ============================================================
print("-- Tooltips page: the Anchor To gate")
do
    local gate = PAGE:match("local function AnchorGateRefresh%(tools2%)(.-)\n        end")
    check(gate ~= nil, "anchor gate: the page decides this once, in a named function")
    if gate then
        check(gate:find("tools2.refreshStates()", 1, true) ~= nil and gate:find("GUI.RelayoutCurrentPage()", 1, true) ~= nil,
              "anchor gate: a pinned pane reflows itself, a page widget (box or card) re-lays the page")
        check(gate:find("GUI:RefreshCurrentPage()", 1, true) == nil,
              "anchor gate: ...without rebuilding it (the rebuild leaked the page)")
    end
    check(PAGE:find("GUI:RefreshCurrentPage", 1, true) == nil,
          "rebuild: nothing on the page rebuilds it")
end

-- ============================================================
-- 3. THE TWO SUMMARY SHAPES
-- ============================================================
print("-- Tooltips page: the summaries")
do
    local hover = PAGE:match("local function HoverTipSummary%(anchorValues, anchorKey, combatKey%)(.-)\n        end")
    check(hover ~= nil and hover:find("anchorValues[d[anchorKey]]", 1, true) ~= nil
      and hover:find('combat ~= "SHOW"', 1, true) ~= nil and hover:find("VIS_VALUES[combat]", 1, true) ~= nil,
          "summary: the hover shape names the anchor, and the in-combat pick only when it is not Always")
    local aura = PAGE:match("local function AuraTipSummary%(anchorValues, anchorKey, combatKey%)(.-)\n        end")
    check(aura ~= nil and aura:find('L%["Combat"%]') ~= nil and aura:find('L%["Never"%]') ~= nil,
          "summary: the aura shape says Disable in Combat in the hover cards' words")
end

-- ============================================================
-- 4. THE BUILDERS, CONTROL BY CONTROL, AND THEIR CARDS
-- Every golden below is the census of the PRE-CHANGE source.
-- ============================================================
local FRAME_TOOLTIP = {
    { "checkbox", "Enable Frame Tooltips", "tooltipFrameEnabled",       30 },
    { "dropdown", "Show Out of Combat",    "tooltipFrameOutOfCombat",   55 },
    { "dropdown", "Show In Combat",        "tooltipFrameCombat",        55 },
    { "dropdown", "Anchor To",             "tooltipFrameAnchor",        55 },
    { "dropdown", "Anchor",                "tooltipFrameAnchorPos",     55 },
    { "slider",   "Offset X",              "tooltipFrameX",             55 },
    { "slider",   "Offset Y",              "tooltipFrameY",             55 },
}
local BIND_TOOLTIP = {
    { "checkbox", "Enable Binding Tooltips", "tooltipBindingEnabled",     30 },
    { "dropdown", "Show Out of Combat",      "tooltipBindingOutOfCombat", 55 },
    { "dropdown", "Show In Combat",          "tooltipBindingCombat",      55 },
    { "dropdown", "Anchor To",               "tooltipBindingAnchor",      55 },
    { "dropdown", "Anchor",                  "tooltipBindingAnchorPos",   55 },
    { "slider",   "Offset X",                "tooltipBindingX",           55 },
    { "slider",   "Offset Y",                "tooltipBindingY",           55 },
}
local BUFF_TOOLTIP = {
    { "checkbox", "Enable Buff Tooltips", "tooltipBuffEnabled",           30 },
    { "checkbox", "Disable in Combat",    "tooltipBuffDisableInCombat",   30 },
    { "dropdown", "Anchor To",            "tooltipBuffAnchor",            55 },
    { "dropdown", "Anchor",               "tooltipBuffAnchorPos",         55 },
    { "slider",   "Offset X",             "tooltipBuffX",                 55 },
    { "slider",   "Offset Y",             "tooltipBuffY",                 55 },
}
local DEBUFF_TOOLTIP = {
    { "checkbox", "Enable Debuff Tooltips", "tooltipDebuffEnabled",         30 },
    { "checkbox", "Disable in Combat",      "tooltipDebuffDisableInCombat", 30 },
    { "dropdown", "Anchor To",              "tooltipDebuffAnchor",          55 },
    { "dropdown", "Anchor",                 "tooltipDebuffAnchorPos",       55 },
    { "slider",   "Offset X",               "tooltipDebuffX",               55 },
    { "slider",   "Offset Y",               "tooltipDebuffY",               55 },
}
local DEF_TOOLTIP = {
    { "checkbox", "Enable Defensive Icon Tooltips", "tooltipDefensiveEnabled",         30 },
    { "checkbox", "Disable in Combat",              "tooltipDefensiveDisableInCombat", 30 },
    { "dropdown", "Anchor To",                      "tooltipDefensiveAnchor",          55 },
    { "dropdown", "Anchor",                         "tooltipDefensiveAnchorPos",       55 },
    { "slider",   "Offset X",                       "tooltipDefensiveX",               55 },
    { "slider",   "Offset Y",                       "tooltipDefensiveY",               55 },
}
local AD_TOOLTIP = {
    { "checkbox", "Groups",     "tooltipADGroupsEnabled",     30 },
    { "checkbox", "Indicators", "tooltipADIndicatorsEnabled", 30 },
    { "checkbox", "Bars",       "tooltipADBarsEnabled",       30 },
}

local CARDS = {
    { label = "Frame Tooltips", key = "tooltips_frame", col = 1, classicCol = 1,
      builder = "BuildFrameTooltipGroup", golden = FRAME_TOOLTIP,
      summary = 'HoverTipSummary(frameAnchorValues, "tooltipFrameAnchor", "tooltipFrameCombat")',
      tick = { key = "tooltipFrameEnabled", name = "Enable Frame Tooltips" } },
    { label = "Binding Tooltips", key = "tooltips_binding", col = 1, classicCol = 2,
      builder = "BuildBindTooltipGroup", golden = BIND_TOOLTIP,
      summary = 'HoverTipSummary(bindAnchorValues, "tooltipBindingAnchor", "tooltipBindingCombat")',
      tick = { key = "tooltipBindingEnabled", name = "Enable Binding Tooltips" } },
    { label = "Buff Tooltips", key = "tooltips_buff", col = 2, classicCol = 1,
      builder = "BuildBuffTooltipGroup", golden = BUFF_TOOLTIP,
      summary = 'AuraTipSummary(buffAnchorValues, "tooltipBuffAnchor", "tooltipBuffDisableInCombat")',
      tick = { key = "tooltipBuffEnabled", name = "Enable Buff Tooltips", aura = true } },
    { label = "Debuff Tooltips", key = "tooltips_debuff", col = 2, classicCol = 2,
      builder = "BuildDebuffTooltipGroup", golden = DEBUFF_TOOLTIP,
      summary = 'AuraTipSummary(debuffAnchorValues, "tooltipDebuffAnchor", "tooltipDebuffDisableInCombat")',
      tick = { key = "tooltipDebuffEnabled", name = "Enable Debuff Tooltips", aura = true } },
    { label = "Defensive Icon Tooltips", key = "tooltips_defensive", col = 2, classicCol = 1,
      builder = "BuildDefTooltipGroup", golden = DEF_TOOLTIP,
      summary = 'AuraTipSummary(defAnchorValues, "tooltipDefensiveAnchor", "tooltipDefensiveDisableInCombat")',
      tick = { key = "tooltipDefensiveEnabled", name = "Enable Defensive Icon Tooltips", aura = true } },
    { label = "Aura Designer Tooltips", key = "tooltips_auradesigner", col = 2, classicCol = 2,
      builder = "BuildADTooltipGroup", golden = AD_TOOLTIP, summary = "ADTooltipSummary" },
}

for _, g in ipairs(CARDS) do
    print("-- Tooltips page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())
    check(body:find("GUI:RefreshCurrentPage", 1, true) == nil,
          g.label .. ": the builder never rebuilds the page from inside itself")

    local calls = 0
    for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, g.label .. ": declared once, mounted twice -- classic box and card")

    local esc = g.label:gsub("%p", "%%%0")
    local box = PAGE:match("local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)\n%s*%1:AddWidget%(GUI:CreateHeader%(self%.child, L%[\"" .. esc .. "\"%]%)")
    check(box ~= nil, g.label .. ": the classic 280 box is built with its own header")
    if box then
        check(PAGE:find("Add(" .. box .. ", nil, " .. g.classicCol .. ")", 1, true) ~= nil,
              g.label .. ": ...and still goes to column " .. g.classicCol)
    end

    local block, call = sectionBlock(g.label, g.builder)
    local flatSummary = g.summary:gsub("%s+", " ")
    check(call:find('OpenSection(L["' .. g.label .. '"], "' .. g.key .. '", ' .. g.col .. ', ' .. flatSummary, 1, true) ~= nil,
          g.label .. ": a card keyed " .. g.key .. " in column " .. g.col .. ", printing the group's own summary")
    check(call:find("Build", 1, true) == nil,
          g.label .. ": no pin -- when a tooltip appears is behaviour, not looks")

    if g.tick then
        check(body:find("if not tools2.hoistToggle then", 1, true) ~= nil
          and body:find(".keepEnabled = true", 1, true) ~= nil,
              g.label .. ": the in-body enable is skipped under hoistToggle, and stays live in classic")
        check(body:find("group.disableChildrenOn = function(d) return not d." .. g.tick.key .. " end", 1, true) ~= nil,
              g.label .. ": the body greys while the tick is off, from inside the builder")
        check(call:find('db = db, key = "' .. g.tick.key .. '", label = L["' .. g.tick.name .. '"]', 1, true) ~= nil,
              g.label .. ": the header tick is bound to " .. g.tick.key .. " under the checkbox's own name")
        check(call:find("self:RefreshStates()", 1, true) ~= nil and call:find("RefreshCurrentPage", 1, true) == nil,
              g.label .. ": ...committing through a state pass, never a page rebuild")
        eq(call:find("RefreshAuraTooltips()", 1, true) ~= nil, g.tick.aura == true,
           g.label .. (g.tick.aura and ": ...after pushing the flag into the game's aura buttons"
                                     or ": ...with nothing to push: it is read at hover time"))
    else
        check(call:find("key = \"", 1, true) == nil, g.label .. ": no header tick -- three independent switches")
    end

    local mount = g.builder .. "({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end,"
        .. (g.tick and " hoistToggle = true," or "") .. " })"
    check(block:find(mount, 1, true) ~= nil,
          g.label .. (g.tick and ": mounts the builder as classic does, plus hoistToggle for its header tick"
                              or ": mounts the builder exactly as classic does"))
end

-- ============================================================
-- 5. RESURRECTION ICON TOOLTIPS, AND THE CARDS TOGETHER
-- ============================================================
print("-- Tooltips page: Resurrection Icon Tooltips, and the cards together")
do
    local CHECK = 'GUI:CreateCheckbox(self.child, L["Enable Resurrection Icon Tooltips"], db, "tooltipResurrectionEnabled", nil), 30)'
    check(PAGE:find('resTooltipGroup:AddWidget(' .. CHECK, 1, true) ~= nil
      and PAGE:find("Add(resTooltipGroup, nil, 2)", 1, true) ~= nil,
          "resurrection: classic keeps its box, its checkbox and column 2")
    local block, call = sectionBlock("Resurrection Icon Tooltips")
    check(call:find('OpenSection(L["Resurrection Icon Tooltips"], "tooltips_resurrection", 1, nil)', 1, true) ~= nil,
          "resurrection: a card keyed tooltips_resurrection in column 1, no tick, no pin")
    check(block:find('band:AddWidget(' .. CHECK, 1, true) ~= nil,
          "resurrection: its one checkbox is the same call classic makes, in the card's body")

    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "),
       "Frame Tooltips | Binding Tooltips | Buff Tooltips | Debuff Tooltips | Defensive Icon Tooltips | Aura Designer Tooltips | Resurrection Icon Tooltips",
       "order: the seven cards open in classic's source order")

    local hoists = 0
    for _ in PAGE:gmatch("hoistToggle = true,") do hoists = hoists + 1 end
    eq(hoists, 5, "ticks: exactly five mounts skip their in-body toggle -- one checkbox per setting")

    check(PAGE:find('Add(tools.SectionControls(self.child), 24, "both")', 1, true) ~= nil,
          "bulk: Expand All / Collapse All at the top, spanning both columns")
    local stripAt = PAGE:find("tools.SectionControls", 1, true)
    local firstAt = PAGE:find('Add(GUI:CreateHeader(self.child, L["Unit Frame"]), 40, 1)', 1, true)
    check(stripAt and firstAt and stripAt < firstAt, "bulk: ...above the first category header")

    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 7, "classic: seven bare 280 boxes, all the classic branch's own")
    check(PAGE:find('Add(CreateCopyButton(self.child, {"tooltip"}, L["Tooltips"], "display_tooltips"), 25, 2)', 1, true) ~= nil,
          "page: the copy button keeps its prefix and its slot")
end
