local NS = ...

-- ============================================================
-- GROUP LABELS PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Frames.lua
-- ------------------------------------------------------------
-- General > Group Labels: the Debuff Bar's collapsible CARDS, raid +
-- group-based only -- two per row inside a card wide enough, dim captions, the
-- value summary in a shut card's corner, Expand All / Collapse All at the top:
--
--   column 1   Raid Group Labels (the page's master switch, Enable Group
--              Labels, in its body), Position
--   column 2   Text Format (its lone dropdown, now a card), Font Settings
--
-- Every card hides outside raid + groups, header and band together; the three
-- after the first grey with the enable. Pins on the three that decide how a
-- label LOOKS.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY, so this file reads the page's SOURCE.
--   ✓ the CENSUS of each builder.
--   ✓ each card's column, stable key, summary, grey and hide gates, pin.
--   ✗ nothing about runtime behaviour -- read in game.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Frames.lua"):gsub("\r\n", "\n")

local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateFontDropdown = "fontdropdown", CreateOutlineDropdown = "outlinedropdown",
    CreateShadowCheckbox = "shadowcheckbox",
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
    local a = SRC:find('Add(CreateCopyButton(self.child, {"groupLabel"}', 1, true)
    local b = SRC:find("-- General > Pinned Frames", 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Group Labels page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

local function sectionBlock(labelKey, mount)
    local a = PAGE:find('OpenSection(L["' .. labelKey .. '"]', 1, true)
    check(a ~= nil, "source: a card is opened for " .. labelKey)
    if not a then return "", "" end
    local b = PAGE:find("CloseSection(", a, true)
    local c = b and PAGE:find(")", b, true)
    check(b ~= nil, "source: ..." .. labelKey .. "'s band is closed after its controls")
    local block = PAGE:sub(a, c or a):gsub("%s+", " ")
    local m = block:find(mount, 1, true)
    return block, m and block:sub(1, m - 1) or block
end

-- ============================================================
-- 1. THE SHARED MACHINERY, AND THE ROW FURNITURE GONE
-- ============================================================
print("-- Group Labels page: the shared machinery, and the row furniture gone")
do
    check(PAGE:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true) ~= nil,
          "tools: ...and takes the shared machinery unconditionally")
    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "GUI:CreateControlRow(", "tools.PopoutContent(",
                            "tools.ClaimKeys(", "tools.WireModifiedTick(", "tools.WireFooter(",
                            "tools.RegisterHoistedToggle(", "tools.RegisterControlRow(",
                            "footerStrip", "inline = true", "_COUNT", "count =", "labelBand",
                            "formatBand", "chromeless", "OnGroupLabelsToggle" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end
    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: every card goes through the shared helper, two per row and dim captions")
    check(PAGE:find("local function CloseSection(band)\n            tools.CloseSection(Add, band)\n        end", 1, true) ~= nil,
          "sections: ...and closes through the shared helper too")
    check(PAGE:find("local function HideGroupLabelOptions()", 1, true) ~= nil
      and PAGE:find("local function DisableGroupLabelOptions(d)", 1, true) ~= nil,
          "gates: the page's two gates are named once, at page scope")
end

-- ============================================================
-- 2. THE BUILDERS AND THEIR CARDS
-- Every golden below is the builder's census.
-- ============================================================
local LABEL_SETTINGS = {
    { "label",    "Display labels above or beside each raid group.", "(none)",            25 },
    { "checkbox", "Enable Group Labels",                             "groupLabelEnabled", 30 },
}
local FONT_SETTINGS = {
    { "fontdropdown",    "Font",        "groupLabelFont",     55 },
    { "slider",          "Font Size",   "groupLabelFontSize", 55 },
    { "outlinedropdown", "Outline",     "groupLabelOutline",  55 },
    { "shadowcheckbox",  "Shadow",      "groupLabelOutline",  30 },
    { "colorpicker",     "Label Color", "groupLabelColor",    35 },
}
local POSITION = {
    { "dropdown", "Label Position", "groupLabelPosition", 55 },
    { "slider",   "Offset X",       "groupLabelOffsetX",  55 },
    { "slider",   "Offset Y",       "groupLabelOffsetY",  55 },
    { "label",    "Start: Above/left of groups.\\nCenter: Middle of the group.\\nEnd: Below/right of groups.", "(none)", 50 },
}
local TEXT_FORMAT = {
    { "dropdown", "Label Format", "groupLabelFormat", 55 },
}

local CARDS = {
    { label = "Raid Group Labels", key = "grouplabels_settings", col = 1, 
      builder = "BuildLabelSettingsGroup", golden = LABEL_SETTINGS,
      call = 'OpenSection(L["Raid Group Labels"], "grouplabels_settings", 1, GroupLabelsSummary, nil, HideGroupLabelOptions)' },
    { label = "Text Format", key = "grouplabels_format", col = 2, 
      builder = "BuildTextFormatGroup", golden = TEXT_FORMAT, pin = true,
      call = 'OpenSection(L["Text Format"], "grouplabels_format", 2, LabelFormatSummary, DisableGroupLabelOptions, HideGroupLabelOptions, BuildTextFormatGroup)' },
    { label = "Font Settings", key = "grouplabels_font", col = 2, 
      builder = "BuildFontGroup", golden = FONT_SETTINGS, pin = true,
      call = 'OpenSection(L["Font Settings"], "grouplabels_font", 2, FontSettingsSummary, DisableGroupLabelOptions, HideGroupLabelOptions, BuildFontGroup)' },
    { label = "Position", key = "grouplabels_position", col = 1, 
      builder = "BuildPositionGroup", golden = POSITION, pin = true,
      call = 'OpenSection(L["Position"], "grouplabels_position", 1, PositionSummary, DisableGroupLabelOptions, HideGroupLabelOptions, BuildPositionGroup)' },
}

for _, g in ipairs(CARDS) do
    print("-- Group Labels page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())

    -- Declared once and mounted once, by its card.
    local calls = 0
    for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
    eq(calls, 2, g.label .. ": declared once, mounted once")

    local box = PAGE:match("local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)\n%s*%1:AddWidget%(GUI:CreateHeader%(self%.child, L%[\"" .. g.label:gsub("%p", "%%%0") .. "\"%]%)")

    local block, call = sectionBlock(g.label, g.builder .. "({")
    check(call:find(g.call, 1, true) ~= nil,
          g.label .. ": a card keyed " .. g.key .. " in column " .. g.col .. ", hidden outside raid + groups"
          .. (g.pin and ", greying with the enable, pinnable" or ", never greying -- it holds the switch"))
    check(call:find('key = "', 1, true) == nil, g.label .. ": no header tick")
    check(block:find("({ group = ", 1, true) ~= nil and block:find("refreshStates = function() self:RefreshStates() end, })", 1, true) ~= nil,
          g.label .. ": mounts its builder")
end

print("-- Group Labels page: the builders' own gates, and Text Format")
do
    check(builderBody("BuildLabelSettingsGroup"):find(".keepEnabled = true", 1, true) ~= nil,
          "settings: the enable stays live when the rest is off")
    check((select(2, sectionBlock("Raid Group Labels", "BuildLabelSettingsGroup({"))):find("hoistToggle", 1, true) == nil,
          "settings: the page's master switch stays in the first card's body")
    for _, b in ipairs({ "BuildFontGroup", "BuildPositionGroup", "BuildTextFormatGroup" }) do
        check(builderBody(b):find("group.disableChildrenOn = DisableGroupLabelOptions", 1, true) ~= nil,
              b .. ": the body greys with the enable, from inside the builder")
    end
    -- Text Format: the card's builder builds the dropdown.
    check(builderBody("BuildTextFormatGroup"):find('GUI:CreateDropdown(parent, L["Label Format"], formatOptions, db, "groupLabelFormat", UpdateLabels), 55)', 1, true) ~= nil,
          "text format: ...and the card's builder builds that same call")
    local fmtAt = PAGE:find("local formatOptions = {", 1, true)
    local bAt = PAGE:find("local function BuildTextFormatGroup(tools2)", 1, true)
    check(fmtAt and bAt and fmtAt < bAt, "text format: ...after the options it closes over")
end

-- ============================================================
-- 3. THE CARDS TOGETHER, AND THE PAGE'S MESSAGES
-- ============================================================
print("-- Group Labels page: the cards together")
do
    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "), "Raid Group Labels | Text Format | Font Settings | Position",
       "order: the four cards open in reading order")
    check(PAGE:find('local strip = Add(tools.SectionControls(self.child), 24, "both")\n        strip.hideOn = HideGroupLabelOptions', 1, true) ~= nil,
          "bulk: Expand All / Collapse All at the top, hidden with the cards outside raid + groups")
    local stripAt = PAGE:find("tools.SectionControls", 1, true)
    local firstAt = PAGE:find('OpenSection(L["Raid Group Labels"]', 1, true)
    check(stripAt and firstAt and stripAt < firstAt, "bulk: ...above the first card")

    local sum = PAGE:match("local function FontSettingsSummary%(d%)(.-)\n        end")
    check(sum ~= nil and sum:find("DF:GetFontNameFromPath(d.groupLabelFont)", 1, true) ~= nil,
          "summary: Font Settings names its font through the dropdown's own resolver")
    local psum = PAGE:match("local function PositionSummary%(d%)(.-)\n        end")
    check(psum ~= nil and psum:find('L["Start"]', 1, true) ~= nil,
          "summary: Position uses the short placement words")

    check(PAGE:find('partyMsg.hideOn = function() return GUI.SelectedMode == "raid" end', 1, true) ~= nil
      and PAGE:find('flatMsg.hideOn = function() return GUI.SelectedMode ~= "raid" or db.raidUseGroups end', 1, true) ~= nil,
          "page: the party and flat messages are unchanged")
end
