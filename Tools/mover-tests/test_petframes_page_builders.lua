local NS = ...

-- ============================================================
-- PET FRAMES PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Options.lua
-- ------------------------------------------------------------
-- Display > Pet Frames: TEN groups. In Modern they are the Debuff Bar's
-- collapsible CARDS -- two per row inside a card wide enough, dim captions, the
-- value summary in a shut card's corner, Expand All / Collapse All at the top:
--
--   column 1   Pet Frame Settings  the PAGE gate (Enable Pet Frames) in its body
--              "Layout"            Layout Mode (rebuilds the page), Group
--                                  Settings (grouped only), Size, Position
--                                  (attached only)
--              "Text"              Name Text, Health Text
--   column 2   "Frame"             Appearance, Border (Show Border is the
--                                  header's tick), Health Bar
--
-- Every card but the first greys with the page gate. Pins on the eight that
-- decide how the pets LOOK.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY, so this file reads the page's SOURCE.
--   ✓ the CENSUS of each builder (the pre-change goldens -- classic renders as
--     it did), in both mode variants where a group changes shape.
--   ✓ each card's column, stable collapse key, summary, grey gate, tick, pin.
--   ✓ the page-rebuild gate: only the layout dropdown rebuilds.
--   ✗ nothing about runtime behaviour -- read in game.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Options.lua"):gsub("\r\n", "\n")

local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateTextureDropdown = "texturedropdown",
    CreateFontDropdown = "fontdropdown",
    CreateOutlineDropdown = "outlinedropdown",
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
    local a = SRC:find('Add(CreateCopyButton(self.child, {"pet"}, L["Pet Frames"], "display_pets"), 25, 2)', 1, true)
    local b = SRC:find('local pageGeneral = CreateSubTab("general", "general_settings", L["Settings"])', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Pet Frames page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- ONE CARD'S BLOCK: from its OpenSection call to the CloseSection that puts its
-- band in, flattened; `call` is everything before the builder MOUNT.
local function sectionBlock(labelKey, builder)
    local a = PAGE:find('OpenSection(L["' .. labelKey .. '"]', 1, true)
    check(a ~= nil, "source: a card is opened for " .. labelKey)
    if not a then return "", "" end
    local b = PAGE:find("CloseSection(", a, true)
    local c = b and PAGE:find(")", b, true)
    check(b ~= nil, "source: ..." .. labelKey .. "'s band is closed after its controls")
    local block = PAGE:sub(a, c or a):gsub("%s+", " ")
    local m = block:find(builder .. "({", 1, true)
    return block, m and block:sub(1, m - 1) or block
end

-- ============================================================
-- 1. THE SHARED MACHINERY, AND THE ROW FURNITURE GONE
-- ============================================================
print("-- Pet Frames page: the shared machinery, and the row furniture gone")
do
    check(PAGE:find("local classicLayout = DF:IsClassicSettingsLayout()", 1, true) ~= nil,
          "tools: the page asks which layout it is building")
    check(PAGE:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true) ~= nil,
          "tools: ...and takes the shared machinery unconditionally")
    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "GUI:CreateControlRow(", "tools.PopoutContent(",
                            "tools.ClaimKeys(", "tools.WireModifiedTick(", "tools.WireFooter(",
                            "tools.RegisterHoistedToggle(", "footerStrip", "inline = true",
                            "_COUNT", "count =", "petLayoutBand", "petFrameBand", "petTextBand",
                            "chromeless", "INLINE_BOX", "GatePaneFirstChild", "OnPetBorderToggle",
                            "ApplyPetSize", "ApplyPetAppearance", "ApplyPetHealthBar",
                            "ApplyPetText", "ApplyPetPosition" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end
    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: every card goes through the shared helper, two per row and dim captions")
    check(PAGE:find("local function CloseSection(band)\n            tools.CloseSection(Add, band)\n        end", 1, true) ~= nil,
          "sections: ...and closes through the shared helper too")

    -- Three category headers, each opening its run of cards.
    for _, pair in ipairs({ { "Layout", "1" }, { "Frame", "2" }, { "Text", "1" } }) do
        local n = 0
        for _ in PAGE:gmatch('Add%(GUI:CreateHeader%(self%.child, L%["' .. pair[1] .. '"%]%), 40, ' .. pair[2] .. '%)') do n = n + 1 end
        eq(n, 1, "headers: the " .. pair[1] .. " category header, in column " .. pair[2] .. ", once")
    end
end

-- ============================================================
-- 2. THE PAGE-REBUILD GATE AND THE PAGE GATE
-- ============================================================
print("-- Pet Frames page: the rebuild gate and the petEnabled gate")
do
    local gate = PAGE:match("local function GateRefresh%(tools2%)(.-)\n        end")
    check(gate ~= nil and gate:find("tools2.refreshStates()", 1, true) ~= nil
      and gate:find("GUI.RelayoutCurrentPage()", 1, true) ~= nil
      and gate:find("GUI:RefreshCurrentPage()", 1, true) == nil,
          "gate: a pinned pane reflows itself, a page widget (box or card) re-lays the page, nothing rebuilds")
    local uses = 0
    for _ in PAGE:gmatch("GateRefresh%(tools2%)") do uses = uses + 1 end
    eq(uses, 6, "gate: five callbacks go through it, plus its own declaration")
    local rebuilds = 0
    for _ in PAGE:gmatch("GUI:RefreshCurrentPage%(%)") do rebuilds = rebuilds + 1 end
    eq(rebuilds, 1, "gate: one rebuild on the page -- the layout dropdown, which changes which cards exist")
    check(builderBody("BuildPetLayoutModeGroup"):find("GUI:RefreshCurrentPage()", 1, true) ~= nil,
          "gate: ...and it is in the layout mode builder")

    check(PAGE:find("local function PetsOffRow(d) return not (d or db).petEnabled end", 1, true) ~= nil,
          "gate: the page-wide predicate is named once")
    check(PAGE:find("disableWhen  = tools2.popout and PetsOffRow or nil", 1, true) ~= nil,
          "gate: a pinned border panel takes the gate through the factory's consumer door")
end

-- ============================================================
-- 3. THE BUILDERS, CONTROL BY CONTROL, AND THEIR CARDS
-- Every golden below is the census of the PRE-CHANGE source.
-- ============================================================
local GENERAL = {
    { "checkbox", "Enable Pet Frames", "petEnabled", 30 },
    { "label",    "Show health bars for player and party/raid member pets, anchored to their owner's frame. Pet frames hide when owner dies.", "(none)", nil },
}
local LAYOUT_MODE = {
    { "dropdown", "Layout Mode", "petGroupMode", 55 },
    { "label", "Pet frames are positioned relative to their owner's frame.", "(none)", nil },
    { "label", "Pet frames are grouped together in a separate container.", "(none)", nil },
}
local GROUP_SETTINGS = {
    { "dropdown", "Group Position",   "petGroupAnchor",    55 },
    { "dropdown", "Growth Direction", "petGroupGrowth",    55 },
    { "slider",   "Spacing",          "petGroupSpacing",   55 },
    { "slider",   "Group X Offset",   "petGroupOffsetX",   55 },
    { "slider",   "Group Y Offset",   "petGroupOffsetY",   55 },
    { "checkbox", "Show Group Label", "petGroupShowLabel", 30 },
}
local SIZE = {
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

-- label, stable key, card column, classic box column, builder, golden, summary
-- (the text as it appears in the call), dim = greys with the page gate, pin =
-- passes its builder.
local CARDS = {
    { label = "Pet Frame Settings", key = "pets_settings", col = 1, classicCol = 1,
      builder = "BuildPetGeneralGroup", golden = GENERAL, summary = "nil" },
    { label = "Layout Mode", key = "pets_layoutmode", col = 1, classicCol = 1,
      builder = "BuildPetLayoutModeGroup", golden = LAYOUT_MODE, summary = "nil", dim = true },
    { label = "Group Settings", key = "pets_group", col = 1, classicCol = 1,
      builder = "BuildPetGroupSettingsGroup", golden = GROUP_SETTINGS, summary = "PetGroupSummary", dim = true, pin = true },
    { label = "Size", key = "pets_size", col = 1, classicCol = 1,
      builder = "BuildPetSizeGroup", golden = SIZE, summary = "PetSizeSummary", dim = true, pin = true },
    { label = "Appearance", key = "pets_appearance", col = 2, classicCol = 2,
      builder = "BuildPetAppearanceGroup", golden = APPEARANCE, summary = "PetAppearanceSummary", dim = true, pin = true },
    { label = "Health Bar", key = "pets_healthbar", col = 2, classicCol = 2,
      builder = "BuildPetHealthBarGroup", golden = HEALTH_BAR, summary = "PetHealthBarSummary", dim = true, pin = true },
    { label = "Name Text", key = "pets_nametext", col = 1, classicCol = 2,
      builder = "BuildPetNameTextGroup", golden = NAME_TEXT,
      summary = 'TextRowSummary("petNameFont", "petNameFontSize", "petNameAnchor")', dim = true, pin = true },
    { label = "Position", key = "pets_position", col = 1, classicCol = 1,
      builder = "BuildPetPositionGroup", golden = POSITION, summary = "PetPositionSummary", dim = true, pin = true },
    { label = "Health Text", key = "pets_healthtext", col = 1, classicCol = 2,
      builder = "BuildPetHealthTextGroup", golden = HEALTH_TEXT,
      summary = 'TextRowSummary("petHealthFont", "petHealthFontSize", "petHealthAnchor")', dim = true, pin = true },
}

for _, g in ipairs(CARDS) do
    print("-- Pet Frames page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())
    check(body:find("group.disableChildrenOn = function(d) return not d.petEnabled end", 1, true) ~= nil,
          g.label .. ": the body greys behind petEnabled, from inside the builder, in both layouts")

    local calls = 0
    for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, g.label .. ": declared once, mounted twice -- classic box and card")
    local esc = g.label:gsub("%p", "%%%0")
    local box = PAGE:match("local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)\n%s*%1:AddWidget%(GUI:CreateHeader%(self%.child, L%[\"" .. esc .. "\"%]%)")
    check(box ~= nil and PAGE:find("Add(" .. box .. ", nil, " .. g.classicCol .. ")", 1, true) ~= nil,
          g.label .. ": the classic box keeps its header and column " .. g.classicCol)

    local block, call = sectionBlock(g.label, g.builder)
    local flatSummary = g.summary:gsub("%s+", " ")
    check(call:find('OpenSection(L["' .. g.label .. '"], "' .. g.key .. '", ' .. g.col .. ', ' .. flatSummary, 1, true) ~= nil,
          g.label .. ": a card keyed " .. g.key .. " in column " .. g.col)
    eq(call:find("PetsOffRow", 1, true) ~= nil, g.dim == true,
       g.label .. (g.dim and ": greys with the page gate" or ": never greys -- it holds the switch"))
    eq(call:find(g.builder, 1, true) ~= nil, g.pin == true,
       g.label .. (g.pin and ": pinnable, from its own builder" or ": behaviour, so no pin"))
    check(call:find('key = "', 1, true) == nil, g.label .. ": no header tick")
    check(block:find(g.builder .. "({ group = ", 1, true) ~= nil and block:find("hoistToggle", 1, true) == nil,
          g.label .. ": mounts the builder as classic does")
end

-- The two cards whose builders change shape with the layout mode.
print("-- Pet Frames page: the mode-dependent cards")
do
    local grouped = PAGE:find("if isGroupedMode then", 1, true)
    local groupCard = PAGE:find('OpenSection(L["Group Settings"]', 1, true)
    check(grouped and groupCard and grouped < groupCard, "mode: Group Settings is built in grouped mode only")
    local attached = PAGE:find("if not isGroupedMode then\n            if classicLayout then", 1, true)
    local posCard = PAGE:find('OpenSection(L["Position"]', 1, true)
    check(attached and posCard and attached < posCard, "mode: Position is built in attached mode only")
    check(builderBody("BuildPetGroupSettingsGroup"):find("if isRaidMode then", 1, true) ~= nil,
          "mode: the group label tick exists only in raid")
    check(builderBody("BuildPetSizeGroup"):find("if not isGroupedMode then", 1, true) ~= nil,
          "mode: the two Match Owner ticks exist only when attached")
end

-- ============================================================
-- 4. BORDER -- the one card with a header tick
-- ============================================================
print("-- Pet Frames page: Border")
do
    local body = builderBody("BuildPetBorderGroup")
    check(body:find('GUI:CreateBorderControls(tools2.group, db, "pet", {', 1, true) ~= nil
      and body:find("include      = { alpha = true, inset = true, blendMode = true,", 1, true) ~= nil
      and body:find("gradient = true, shadow = true },", 1, true) ~= nil
      and body:find("sizeMin = 1, sizeMax = 6, sizeStep = 1,", 1, true) ~= nil,
          "border: one toolkit call, the include set and the thickness range exactly as they were")
    check(body:find("noShowToggle = tools2.hoistToggle or nil,", 1, true) ~= nil,
          "border: the header tick is the toolkit's own noShowToggle")
    check(body:find("group.disableChildrenOn = function(d)", 1, true) == nil,
          "border: the builder sets no group gate, because the toolkit owns the group")
    check(PAGE:find("petBorderGroup.disableChildrenOn = function(d) return not d.petEnabled end", 1, true) ~= nil
      and PAGE:find("Add(petBorderGroup, nil, 2)", 1, true) ~= nil,
          "border: classic still gates its box and keeps column 2")

    local calls = 0
    for _ in PAGE:gmatch("BuildPetBorderGroup%(") do calls = calls + 1 end
    eq(calls, 3, "border: declared once, mounted twice -- classic box and card")

    local block, call = sectionBlock("Border", "BuildPetBorderGroup")
    check(call:find('OpenSection(L["Border"], "pets_border", 2, PetBorderSummary, PetsOffRow, nil, BuildPetBorderGroup, {', 1, true) ~= nil,
          "border: a card keyed pets_border in column 2, greying with the page gate, pinnable")
    check(call:find('db = db, key = "petShowBorder", label = L["Show Border"]', 1, true) ~= nil,
          "border: the header tick is bound to petShowBorder under the checkbox's own name")
    check(call:find("disableOn = PetsOffRow", 1, true) ~= nil,
          "border: ...greyed with the page gate")
    check(call:find("ApplyPetBorder() self:RefreshStates() tools.ReflowMounted()", 1, true) ~= nil
      and call:find("RefreshCurrentPage", 1, true) == nil,
          "border: ...committing what the toolkit ran, a state pass and a pinned-panel repaint -- never a rebuild")
    check(block:find("band.disableChildrenOn = function(d) return not d.petEnabled end BuildPetBorderGroup({", 1, true) ~= nil,
          "border: the band carries the page gate, set before the build, as classic sets it on its box")
    check(block:find("BuildPetBorderGroup({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end, hoistToggle = true, })", 1, true) ~= nil,
          "border: mounts the builder as classic does, plus hoistToggle for its header tick")
end

-- ============================================================
-- 5. THE CARDS TOGETHER, THE CLASSIC BOXES AND THE LOCALE
-- ============================================================
print("-- Pet Frames page: the cards together")
do
    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "),
       "Pet Frame Settings | Layout Mode | Group Settings | Size | Appearance | Border | Health Bar | Position | Name Text | Health Text",
       "order: the cards open in the order they stack -- Name Text after Position, so the Text cards follow Layout in column 1")
    local hoists = 0
    for _ in PAGE:gmatch("hoistToggle = true,") do hoists = hoists + 1 end
    eq(hoists, 1, "ticks: exactly one mount skips its in-body toggle (Border)")
    check((select(1, sectionBlock("Pet Frame Settings", "BuildPetGeneralGroup"))):find("petEnabled", 1, true) == nil,
          "ticks: Enable Pet Frames is not hoisted -- it is the page gate, in the first card's body")

    check(PAGE:find('Add(tools.SectionControls(self.child), 24, "both")', 1, true) ~= nil,
          "bulk: Expand All / Collapse All at the top, spanning both columns")
    local stripAt = PAGE:find("tools.SectionControls", 1, true)
    local firstAt = PAGE:find('OpenSection(L["Pet Frame Settings"]', 1, true)
    check(stripAt and firstAt and stripAt < firstAt, "bulk: ...above the first card")

    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 10, "classic: ten bare 280 boxes, all the classic branch's own")

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
