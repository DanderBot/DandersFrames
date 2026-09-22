local NS = ...

-- ============================================================
-- GLOBAL FONTS PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Frames.lua
-- ------------------------------------------------------------
-- General > Global Fonts: three classic boxes. In Modern they are the Debuff
-- Bar's collapsible CARDS -- two per row inside a card wide enough, dim
-- captions, the value summary in a shut card's corner, Expand All / Collapse
-- All at the top -- and TWO COLUMNS when the window is wide (the rows were one
-- column at every width):
--
--   column 1   Global Font Settings  the scratch pad and its Apply to All
--   column 2   Shadow Settings       pinnable; the Shadow cross-link's target
--              Affected Elements     the reference list, as a card
--
-- ☠ THE PAGE HAS TWO RULES OF ITS OWN:
--   1. THE APPLY BUTTON IS A WIZARD, NOT A SETTING. It is hand-built, so the
--      census cannot see it; section 2 pins its OnClick by source pattern.
--   2. NOT ONE OF THE SCRATCH PAD'S KEYS IS A PER-MODE SETTING (DF.GlobalFontTemp
--      and the DF.db root), so nothing on the page may offer a reset for it.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY, so this file reads the page's SOURCE.
--   ✓ the CENSUS of each builder, with the store each control binds to.
--   ✓ each card's column, stable key, summary and pin.
--   ✗ nothing about runtime behaviour -- read in game.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Frames.lua"):gsub("\r\n", "\n")

local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateFontDropdown = "fontdropdown", CreateOutlineDropdown = "outlinedropdown",
    CreateShadowCheckbox = "shadowcheckbox", CreateNote = "note",
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

-- ⚠ THE KEY COLUMN IS QUALIFIED -- "<table>.<key>" -- because this page binds to
-- three stores (DF.GlobalFontTemp, DF.db and the page's per-mode db).
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
        local tbl, k = chunk:match('([%w_%.]+)%s*,%s*"([%w_]+)"')
        local h     = tonumber(chunk:match('%)%s*,%s*(%d+)%s*%)'))
        out[#out + 1] = { kind = at.kind, label = label,
                          key = (tbl and (tbl .. "." .. k)) or "(none)", height = h }
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
    local a = SRC:find('Add(CreateCopyButton(self.child, {"fontShadow"}', 1, true)
    local b = SRC:find("-- General > Group Labels", 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Global Fonts page builder is locatable by its own ends")
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
print("-- Global Fonts page: the shared machinery, and the row furniture gone")
do
    check(PAGE:find("local classicLayout = DF:IsClassicSettingsLayout()", 1, true) ~= nil,
          "tools: the page asks which layout it is building")
    check(PAGE:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true) ~= nil,
          "tools: ...and takes the shared machinery unconditionally")
    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "tools.PopoutContent(", "tools.ClaimKeys(",
                            "tools.WireModifiedTick(", "tools.WireFooter(", "RegisterHoistedToggle",
                            "footerStrip", "inline = true", "_COUNT", "count =", "fontBand",
                            "chromeless", "INLINE_BOX" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end
    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: every card goes through the shared helper, two per row and dim captions")
    check(PAGE:find("local function CloseSection(band)\n            tools.CloseSection(Add, band)\n        end", 1, true) ~= nil,
          "sections: ...and closes through the shared helper too")

    -- The scratch table stays at PAGE scope, above every builder, in both layouts.
    local tempAt = PAGE:find("if not DF.GlobalFontTemp then", 1, true)
    local buildAt = PAGE:find("local function BuildFontSelectionGroup(tools2)", 1, true)
    check(tempAt and buildAt and tempAt < buildAt, "scratch: DF.GlobalFontTemp is seeded at page scope, above the builder")
    for _, fn in ipairs({ "UpdateShadowSettings", "LightweightShadowUpdate" }) do
        local decls = 0
        for _ in PAGE:gmatch("local function " .. fn .. "%(%)") do decls = decls + 1 end
        eq(decls, 1, "applies: " .. fn .. " is declared once, at page scope")
    end
end

-- ============================================================
-- 2. GLOBAL FONT SETTINGS -- the scratch pad, working exactly as before
-- ============================================================
local FONT_SELECTION = {
    { "label",           "Set a font and outline style, then click Apply to update ALL text elements.", "(none)", 40 },
    { "fontdropdown",    "Font",    "DF.GlobalFontTemp.font",    55 },
    { "outlinedropdown", "Outline", "DF.GlobalFontTemp.outline", 55 },
    { "shadowcheckbox",  "Shadow",  "DF.GlobalFontTemp.outline", 30 },
    { "checkbox",        "Crisp Font Rendering (SDF)", "DF.db.fontSlug", 30 },
    { "label",           "Renders text with signed-distance-field smoothing for sharper edges at any size. Applies to None and Outline styles only (not Monochrome, Thick, or Shadow).", "(none)", 50 },
}

print("-- Global Fonts page: Global Font Settings")
do
    local body = builderBody("BuildFontSelectionGroup")
    checkCensus(census(body), FONT_SELECTION, "global font settings")

    check(body:find('local applyBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")', 1, true) ~= nil,
          "apply: the button is built into the BUILDER's parent")
    check(body:find('GUI:StyleButton(applyBtn, { width = 120, height = 28, text = L["Apply to All"] })', 1, true) ~= nil,
          "apply: ...still themed through the shared button styler")
    check(body:find("group:AddWidget(applyBtn, 35)", 1, true) ~= nil,
          "apply: ...and added to the group at the slot height it always had")
    for _, line in ipairs({
        "db.afkIconTimerFont = nil; db.afkIconTimerOutline = nil",
        "local function _clearAuraRecord(rec)",
        'for _, tk in pairs({ "icon", "square", "bar" }) do',
        "_tdCfg.globalDefaults.font = font",
        'DF:Say("Applied global font settings to all text elements.")',
    }) do
        check(body:find(line, 1, true) ~= nil, "apply: the OnClick body still carries `" .. line .. "`")
    end
    local fontWrites, outlineWrites = 0, 0
    for _ in body:gmatch("= font%f[%W]") do fontWrites = fontWrites + 1 end
    for _ in body:gmatch("= outline%f[%W]") do outlineWrites = outlineWrites + 1 end
    eq(fontWrites, 20, "apply: the press writes the chosen font in twenty places")
    eq(outlineWrites, 20, "apply: ...and the outline beside each one")

    local calls = 0
    for _ in PAGE:gmatch("BuildFontSelectionGroup%(") do calls = calls + 1 end
    eq(calls, 3, "global font settings: declared once, mounted twice -- classic box and card")
    check(PAGE:find('fontSelectGroup:AddWidget(GUI:CreateHeader(self.child, L["Global Font Settings"]), 40)', 1, true) ~= nil
      and PAGE:find("Add(fontSelectGroup, nil, 1)", 1, true) ~= nil,
          "global font settings: classic keeps its box, its header and column 1")

    local block, call = sectionBlock("Global Font Settings", "BuildFontSelectionGroup({")
    check(call:find('OpenSection(L["Global Font Settings"], "fonts_global", 1, nil)', 1, true) ~= nil,
          "global font settings: a card keyed fonts_global in column 1 -- no summary, no tick, no pin")
    check(block:find("BuildFontSelectionGroup({ group = fontCard, parent = self.child, refreshStates = function() self:RefreshStates() end, })", 1, true) ~= nil,
          "global font settings: mounts the builder exactly as classic does")
end

-- ============================================================
-- 3. SHADOW SETTINGS -- and the cross-link that lands on it
-- ============================================================
local SHADOW_SETTINGS = {
    { "label",       "These settings apply when using 'Shadow' outline style. Use larger offsets for more dramatic shadows.", "(none)", 40 },
    { "slider",      "Shadow X Offset", "db.fontShadowOffsetX", 50 },
    { "slider",      "Shadow Y Offset", "db.fontShadowOffsetY", 50 },
    { "colorpicker", "Shadow Color",    "db.fontShadowColor",   40 },
}

print("-- Global Fonts page: Shadow Settings")
do
    local body = builderBody("BuildShadowSettingsGroup")
    checkCensus(census(body), SHADOW_SETTINGS, "shadow settings")
    check(body:find("UpdateShadowSettings, LightweightShadowUpdate", 1, true) ~= nil,
          "shadow settings: the sliders keep their full apply and their drag-time one")

    local calls = 0
    for _ in PAGE:gmatch("BuildShadowSettingsGroup%(") do calls = calls + 1 end
    eq(calls, 3, "shadow settings: declared once, mounted twice -- classic box and card")
    check(PAGE:find('shadowGroup:AddWidget(GUI:CreateHeader(self.child, L["Shadow Settings"]), 40)', 1, true) ~= nil
      and PAGE:find("Add(shadowGroup, nil, 1)", 1, true) ~= nil,
          "shadow settings: classic keeps its box, its header and column 1")

    local block, call = sectionBlock("Shadow Settings", "BuildShadowSettingsGroup({")
    check(call:find('OpenSection(L["Shadow Settings"], "fonts_shadow", 2, ShadowSettingsSummary, nil, nil, BuildShadowSettingsGroup)', 1, true) ~= nil,
          "shadow settings: a card keyed fonts_shadow in column 2, printing its summary, pinnable")
    check(block:find("BuildShadowSettingsGroup({ group = shadowCard, parent = self.child, refreshStates = function() self:RefreshStates() end, })", 1, true) ~= nil,
          "shadow settings: mounts the builder exactly as classic does")

    local sum = PAGE:match("local function ShadowSettingsSummary%(d%)(.-)\n            end")
    check(sum ~= nil and sum:find("if ox ~= 0 or oy ~= 0 then", 1, true) ~= nil
      and sum:find('format("%g, %g", ox, oy)', 1, true) ~= nil and sum:find("math.floor", 1, true) == nil,
          "shadow settings: the summary is the offset pair, only when set, at half-pixel resolution")

    -- ☠ THE SHADOW CROSS-LINK'S TARGET. Every per-element "Shadow" checkbox sits
    -- under UI:CreateGlobalFontsShadowLink, which jumps to section
    -- L["Shadow Settings"] on this page; Search:ScrollToSection finds it by
    -- :GetText() on the page's children -- which a card answers with its title
    -- (and expands if it was shut).
    local KIT  = ui_file_source("Sections.lua")
    local link = KIT:match("function UI:CreateGlobalFontsShadowLink%(parent, width%)(.-)\nend")
    check(link ~= nil and link:find('page    = "general_fonts",', 1, true) ~= nil
      and link:match('section = L%["([^"]+)"%]') == "Shadow Settings",
          "shadow link: the kit's cross-link aims at this page's Shadow Settings")
    local widgets = options_file_source("GUI/SettingsWidgets.lua")
    check(widgets:find("section.GetText = function(self) return self.sectionTitleText end", 1, true) ~= nil,
          "shadow link: ...and a card answers :GetText() with its own title")
    local search = options_file_source("Features/Search.lua")
    check(search:find("if not widget.expanded and widget.Toggle then widget:Toggle() end", 1, true) ~= nil,
          "shadow link: ...which the jump expands if it was shut")
end

-- ============================================================
-- 4. AFFECTED ELEMENTS -- the reference list, as a card
-- ============================================================
print("-- Global Fonts page: Affected Elements")
do
    check(PAGE:find('local INFO_LIST = L["', 1, true) ~= nil and PAGE:find('local INFO_NOTE = L["', 1, true) ~= nil,
          "affected: the list and the note are one page-scope copy each, read by both layouts")
    check(PAGE:find("infoGroup:AddWidget(GUI:CreateLabel(self.child, INFO_LIST, 250), 235)", 1, true) ~= nil
      and PAGE:find('infoGroup:AddWidget(GUI:CreateNote(self.child, INFO_NOTE, {tone = "caution", prefix = "Note", width = 250}), 40)', 1, true) ~= nil
      and PAGE:find("Add(infoGroup, nil, 2)", 1, true) ~= nil,
          "affected: classic keeps its 280 box, the pinned 235 and column 2")

    local block, call = sectionBlock("Affected Elements", "local infoInner")
    check(call:find('OpenSection(L["Affected Elements"], "fonts_affected", 2, nil)', 1, true) ~= nil,
          "affected: a card keyed fonts_affected in column 2 -- no summary, no pin")
    check(block:find("local infoInner = GUI:GroupInnerWidth(band)", 1, true) ~= nil
      and block:find("band:AddWidget(GUI:CreateLabel(self.child, INFO_LIST, infoInner))", 1, true) ~= nil
      and block:find('band:AddWidget(GUI:CreateNote(self.child, INFO_NOTE, {tone = "caution", prefix = "Note", width = infoInner}), 40)', 1, true) ~= nil,
          "affected: the list is measured at the card's width, the note keeps its 40")
end

-- ============================================================
-- 5. THE CARDS TOGETHER, AND THE PAGE'S RULE
-- ============================================================
print("-- Global Fonts page: the cards together")
do
    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "), "Global Font Settings | Shadow Settings | Affected Elements",
       "order: the three cards, in the order they stack")
    check(PAGE:find('Add(tools.SectionControls(self.child), 24, "both")', 1, true) ~= nil,
          "bulk: Expand All / Collapse All at the top, spanning both columns")
    local stripAt = PAGE:find("tools.SectionControls", 1, true)
    local firstAt = PAGE:find('OpenSection(L["Global Font Settings"]', 1, true)
    check(stripAt and firstAt and stripAt < firstAt, "bulk: ...above the first card")
    check(PAGE:find("hoistToggle", 1, true) == nil, "ticks: no card on this page has a header tick")
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 3, "classic: three bare 280 boxes, all the classic branch's own")
end
