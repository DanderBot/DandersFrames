local NS = ...

-- ============================================================
-- RESOURCE BAR PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Auras.lua
-- ------------------------------------------------------------
-- Bars > Resource Bar: nine 280 boxes in classic; in modern, the Debuff Bar's
-- collapsible CARDS, one per box, in two page columns under the three category
-- headers the popout bands had:
--
--   column 1   "General"  Resource Bar Settings, Class Filter
--              "Layout"   Size, Position (+ Frame Level)
--   column 2   "Style"    Appearance, Background (header tick), Border (header
--                         tick), Resource Colors
--
-- ☠ FOUR THINGS THIS SUITE IS HERE TO PIN:
--
--   1. ENABLE RESOURCE BAR IS THE PAGE GATE and stays in the first card's body
--      -- no tick, no hoist -- as Show Debuffs does on the Debuff Bar. Every
--      other card greys its header with it (dimOn), and its controls through
--      the group gate each builder has always carried.
--   2. SHOW BACKGROUND AND SHOW BORDER MOVE INTO THEIR CARDS' HEADERS, through
--      the hoistToggle seam, so there is one checkbox per setting.
--   3. FRAME LEVEL -- the page's one lone control -- MOVES INTO POSITION.
--   4. THE ORIENTATION PICK STILL REACHES A PINNED SIZE PANEL, and the colour
--      reset still repaints one.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY -- it is welded to the panel -- so this
-- file reads the page's SOURCE and asserts against it.
--
--   ✓ the widget CENSUS of each builder -- kind, L key, db key and slot height,
--     in order -- taken from the pre-card source, so classic renders as it did.
--   ✓ that ONE builder serves both layouts, and the card hands it EXACTLY what
--     classic hands it (plus hoistToggle where the tick moved to the header).
--   ✓ each card's column, stable collapse key, summary, grey gate, tick and pin.
--   ✗ nothing about runtime behaviour -- read in game.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Auras.lua"):gsub("\r\n", "\n")

-- ---- the census reader (the Health Bar page's, plus one fallback) ----
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateTextureDropdown = "texturedropdown",
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
        -- ⚠ The Custom Color picker is built into a LOCAL first and added a line
        -- later, so its height is read off the AddWidget that follows.
        local h = tonumber(chunk:match('%)%s*,%s*(%d+)%s*%)'))
                or tonumber(chunk:match('AddWidget%(%s*[%w_]+%s*,%s*(%d+)%s*%)'))
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
    local a = SRC:find('L["Resource Bar"], "bars_resource")', 1, true)
    local b = SRC:find('local pageAbsorb = CreateSubTab("bars", "bars_absorb"', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Resource Bar page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- ONE CARD'S BLOCK, flattened; `call` is just its OpenSection call.
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
-- 1. THE SHARED CARD HELPER, AND THE POPOUT FURNITURE GONE
-- ============================================================
print("-- Resource Bar page: the shared card helper")
do
    check(PAGE:find("local classicLayout = DF:IsClassicSettingsLayout()", 1, true) ~= nil,
          "tools: the page asks which layout it is building")
    check(PAGE:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true) ~= nil,
          "tools: ...and takes the shared machinery unconditionally")

    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "tools.PopoutContent(", "tools.ClaimKeys(",
                            "tools.WireModifiedTick(", "tools.WireFooter(",
                            "tools.RegisterHoistedToggle(", "tools.RegisterControlRow(",
                            "GUI:CreateControlRow(", "GatePaneFirstChild", "generalBand", "layoutBand",
                            "styleBand", "frameLevelBand", "_COUNT = ", "footerStrip", "inline = true",
                            "popout = true,", "OnResourceEnableToggle", "OnResourceBorderToggle",
                            "ApplyResourceSettings", "ApplyResourceSize", "ApplyResourcePosition",
                            "ApplyResourceAppearance", "ApplyResourceBackground", "ApplyResourceColors" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end
    check(PAGE:find("count%s*=%s*[%w_]") == nil, "counts: no card declares a settings count")

    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: every card goes through the shared helper, two per row with quiet captions")
    check(PAGE:find("local function CloseSection(band)\n            tools.CloseSection(Add, band)\n        end", 1, true) ~= nil,
          "sections: ...and closes through the shared helper too")

    local n = 0
    for _ in PAGE:gmatch('Add%(tools%.SectionControls%(self%.child%), 24, "both"%)') do n = n + 1 end
    eq(n, 1, "bulk: the page adds the Expand/Collapse pair once, spanning both columns")
    local stripAt = PAGE:find("tools.SectionControls", 1, true)
    local generalAt = PAGE:find('Add(GUI:CreateHeader(self.child, L["General"]), 40, 1)', 1, true)
    check(stripAt and generalAt and stripAt < generalAt, "bulk: ...above the first category header")

    -- The three category headers, straight onto a column, once each.
    for _, pair in ipairs({ { "General", "1" }, { "Layout", "1" }, { "Style", "2" } }) do
        local c = 0
        for _ in PAGE:gmatch('Add%(GUI:CreateHeader%(self%.child, L%["' .. pair[1] .. '"%]%), 40, ' .. pair[2] .. '%)') do c = c + 1 end
        eq(c, 1, "headers: the " .. pair[1] .. " category header opens column " .. pair[2] .. ", once")
    end
end

-- ============================================================
-- 2. THE VOCABULARY AT PAGE SCOPE
-- ============================================================
print("-- Resource Bar page: the vocabulary at page scope")
do
    for _, name in ipairs({ "RB_CLASS_LIST", "anchorOptions", "orientOptions", "RESOURCE_COLOR_MODES" }) do
        local decls = 0
        for _ in PAGE:gmatch("local " .. name .. " = {") do decls = decls + 1 end
        eq(decls, 1, "vocab: " .. name .. " is declared exactly once")
        local at = PAGE:find("local " .. name .. " = {", 1, true)
        local firstBuilder = PAGE:find("local function BuildResourceSettingsGroup(tools2)", 1, true)
        check(at and firstBuilder and at < firstBuilder, "vocab: ..." .. name .. " is above the first builder")
    end
    check(PAGE:find("local function TextureName(path)", 1, true) ~= nil,
          "vocab: the texture-name resolver is a named page-scope helper")
end

-- ============================================================
-- 3. THE CARDS
-- ============================================================
local RESOURCE_SETTINGS = {
    { "checkbox", "Enable Resource Bar", "resourceBarEnabled",           30 },
    { "checkbox", "Healers",             "resourceBarShowHealer",        30 },
    { "checkbox", "Tanks",               "resourceBarShowTank",          30 },
    { "checkbox", "DPS",                 "resourceBarShowDPS",           30 },
    { "checkbox", "Show in Solo Mode",   "resourceBarShowInSoloMode",    30 },
}
-- ⚠ ONE CENSUS ROW FOR THIRTEEN: they come out of a loop over RB_CLASS_LIST.
local RESOURCE_CLASS_FILTER = { { "checkbox", "(none)", "(none)", 25 } }
local RESOURCE_SIZE = {
    { "checkbox", "Match Health Bar Width",   "resourceBarMatchWidth",             30 },
    { "checkbox", "Adjust For Frame Border",  "resourceBarMatchAdjustFrameBorder", 30 },
    { "slider",   "Width",                    "resourceBarWidth",                  55 },
    { "slider",   "Thickness",                "resourceBarHeight",                 55 },
}
local RESOURCE_POSITION = {
    { "dropdown", "Anchor",   "resourceBarAnchor", 55 },
    { "slider",   "Offset X", "resourceBarX",      55 },
    { "slider",   "Offset Y", "resourceBarY",      55 },
}
local RESOURCE_APPEARANCE = {
    { "texturedropdown", "Texture",                "resourceBarTexture",     55 },
    { "dropdown",        "Orientation",            "resourceBarOrientation", 55 },
    { "checkbox",        "Reverse Fill Direction", "resourceBarReverseFill", 30 },
    { "checkbox",        "Smooth Bar Animation",   "resourceBarSmooth",      30 },
}
local RESOURCE_BACKGROUND = {
    { "checkbox",    "Show Background",  "resourceBarBackgroundEnabled", 30 },
    { "colorpicker", "Background Color", "resourceBarBackgroundColor",   35 },
}
-- No census: CreateBorderControls builds the whole group (test_border_builders.lua).
local RESOURCE_BORDER = {}
local RESOURCE_COLORS = {
    { "label",       "Customize resource bar colors per power type. Shared across party and raid frames.",
                     "(none)",                  40 },
    { "dropdown",    "Color Mode",   "resourceBarColorMode",   54 },
    { "colorpicker", "Custom Color", "resourceBarCustomColor", 30 },
    { "colorpicker", "(none)",       "(none)",                 30 },
}

-- label, stable collapse key, card column, classic box and column, summary;
-- `dim` = header greys with the page gate, `pin` = passes its builder (decides
-- how the bar LOOKS), `tick` = its on/off moved into the header.
local CARDS = {
    { label = "Resource Bar Settings", key = "resource_settings", col = 1, box = "settingsGroup", classicCol = 1,
      builder = "BuildResourceSettingsGroup", golden = RESOURCE_SETTINGS, summary = "ResourceSettingsCardSummary" },
    { label = "Class Filter", key = "resource_classfilter", col = 1, box = "classFilterGroup", classicCol = 1,
      builder = "BuildResourceClassFilterGroup", golden = RESOURCE_CLASS_FILTER,
      summary = "ResourceClassFilterSummary", dim = true },
    { label = "Size", key = "resource_size", col = 1, box = "sizeGroup", classicCol = 1,
      builder = "BuildResourceSizeGroup", golden = RESOURCE_SIZE, summary = "ResourceSizeSummary", dim = true, pin = true },
    { label = "Position", key = "resource_position", col = 1, box = "positionGroup", classicCol = 1,
      builder = "BuildResourcePositionGroup", golden = RESOURCE_POSITION, summary = "ResourcePositionSummary",
      dim = true, pin = true },
    { label = "Appearance", key = "resource_appearance", col = 2, box = "appearanceGroup", classicCol = 2,
      builder = "BuildResourceAppearanceGroup", golden = RESOURCE_APPEARANCE, summary = "ResourceAppearanceSummary",
      dim = true, pin = true },
    { label = "Background", key = "resource_background", col = 2, box = "bgGroup", classicCol = 2,
      builder = "BuildResourceBackgroundGroup", golden = RESOURCE_BACKGROUND, summary = "nil",
      dim = true, pin = true, tick = { key = "resourceBarBackgroundEnabled", name = "Show Background" } },
    { label = "Border", key = "resource_border", col = 2, box = "borderGroup", classicCol = 2,
      builder = "BuildResourceBorderGroup", golden = RESOURCE_BORDER, summary = "ResourceBorderSummary",
      dim = true, pin = true, tick = { key = "resourceBarShowBorder", name = "Show Border" }, composite = true },
    { label = "Resource Colors", key = "resource_colors", col = 2, box = "colorGroup", classicCol = 2,
      builder = "BuildResourceColorsGroup", golden = RESOURCE_COLORS, summary = "ResourceColorsSummary",
      dim = true, pin = true },
}

for _, g in ipairs(CARDS) do
    print("-- Resource Bar page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())

    local calls = 0
    for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, g.label .. ": declared once, mounted twice -- classic box and card")

    check(PAGE:find("local " .. g.box .. " = GUI:CreateSettingsGroup(self.child, 280)", 1, true) ~= nil,
          g.label .. ": the classic 280 box is built")
    check(PAGE:find(g.box .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. g.label .. '"]), 40)', 1, true) ~= nil,
          g.label .. ": ...under the header it always had")
    check(PAGE:find("Add(" .. g.box .. ", nil, " .. g.classicCol .. ")", 1, true) ~= nil,
          g.label .. ": ...and still goes to column " .. g.classicCol)

    local block, call = sectionBlock(g.label)
    check(block:find('OpenSection(L["' .. g.label .. '"], "' .. g.key .. '", ' .. g.col .. ', ' .. g.summary, 1, true) ~= nil,
          g.label .. ": a card keyed " .. g.key .. " in column " .. g.col .. ", printing " .. g.summary)
    eq(call:find("ResourceOffRow", 1, true) ~= nil and call:find(g.summary .. ", ResourceOffRow", 1, true) ~= nil, g.dim == true,
       g.label .. (g.dim and ": its header greys with the page gate" or ": holds the page gate, so never greys with it"))
    eq(call:find(g.builder, 1, true) ~= nil, g.pin == true,
       g.label .. (g.pin and ": pinnable, from its own builder" or ": decides what the bar DOES, so it grows no pin"))

    if g.tick then
        check(call:find('db = db, key = "' .. g.tick.key .. '", label = L["' .. g.tick.name .. '"]', 1, true) ~= nil,
              g.label .. ": the header tick is bound to " .. g.tick.key .. " under its own name")
        check(call:find("disableOn = ResourceOffRow", 1, true) ~= nil,
              g.label .. ": ...greyed by the page gate")
        check(call:find("onChanged = function()", 1, true) ~= nil
          and call:find("self:RefreshStates()", 1, true) ~= nil
          and call:find("tools.ReflowMounted()", 1, true) ~= nil
          and call:find("RefreshCurrentPage", 1, true) == nil,
              g.label .. ": ...committing through a state pass and a panel reflow, never a page rebuild")
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
        check(call:find('key = "', 1, true) == nil, g.label .. ": no header tick")
    end

    local mount = g.builder .. "({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end,"
        .. (g.tick and " hoistToggle = true," or "") .. " })"
    check(block:find(mount, 1, true) ~= nil,
          g.label .. (g.tick and ": mounts the builder as classic does, plus hoistToggle for its header tick"
                              or ": mounts the builder exactly as classic does"))
end

-- ============================================================
-- 4. THE PAGE GATE, THE ORIENTATION PICK AND THE COLOUR RESET
-- ============================================================
print("-- Resource Bar page: the gate, the orientation pick and the reset")
do
    check(PAGE:find("local function ResourceOffRow(d) return not (d or db).resourceBarEnabled end", 1, true) ~= nil,
          "gate: the page gate is named once")
    -- ☠ THE MASTER SWITCH STAYS IN THE BODY.
    local body = builderBody("BuildResourceSettingsGroup")
    check(body:find('GUI:CreateCheckbox(parent, L["Enable Resource Bar"], db, "resourceBarEnabled"', 1, true) ~= nil
      and body:find("resourceBarEnable.keepEnabled = true", 1, true) ~= nil,
          "gate: the builder still builds Enable Resource Bar, live under its own grey")
    check((sectionBlock("Resource Bar Settings")):find("hoistToggle", 1, true) == nil,
          "gate: ...and its card never hoists it")
    local s = PAGE:match("local function ResourceSettingsCardSummary%(d%)(.-)\n        end")
    check(s ~= nil and s:find('if d and not d.resourceBarEnabled then return L["Off"] end', 1, true) ~= nil,
          "gate: the first card's corner says Off while the bar is off")
    -- Every builder but the border carries the group gate it always had.
    for _, b in ipairs({ "BuildResourceSettingsGroup", "BuildResourceClassFilterGroup", "BuildResourceSizeGroup",
                         "BuildResourcePositionGroup", "BuildResourceAppearanceGroup",
                         "BuildResourceBackgroundGroup", "BuildResourceColorsGroup" }) do
        check(builderBody(b):find("group.disableChildrenOn = function(d) return not d.resourceBarEnabled end", 1, true) ~= nil,
              "gate: " .. b .. " keeps its group gate")
    end
    -- The border factory owns its group, so the gate goes in as its consumer gate
    -- -- in modern (card and pinned panel alike), never in classic.
    check(builderBody("BuildResourceBorderGroup"):find("disableWhen  = tools and ResourceOffRow or nil,", 1, true) ~= nil,
          "gate: the border's controls take the page gate through the factory in modern")

    -- ☠ THE ORIENTATION PICK REACHES A PINNED SIZE PANEL.
    local gate = PAGE:match("local function OrientationChanged%(tools2%)(.-)\n        end")
    check(gate ~= nil and gate:find("tools2.refreshStates()", 1, true) ~= nil
      and gate:find("if tools then tools.ReflowMounted() end", 1, true) ~= nil,
          "orientation: a state pass, then -- in modern -- a reflow of every mounted panel")

    -- The colour reset repaints the card's own band, then any pinned copy.
    local colors = builderBody("BuildResourceColorsGroup")
    check(colors:find("group:RefreshChildValues()\n                    if tools then tools.ReflowMounted(true) end", 1, true) ~= nil,
          "reset: the card sweeps its own swatches and then any pinned copy's")

    local rebuilds = 0
    for _ in PAGE:gmatch("RefreshCurrentPage") do rebuilds = rebuilds + 1 end
    eq(rebuilds, 0, "no builder or tick rebuilds the page")
end

-- ============================================================
-- 5. FRAME LEVEL MOVED INTO POSITION
-- ============================================================
print("-- Resource Bar page: Frame Level inside Position")
do
    local block = sectionBlock("Position")
    check(block:find('band:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "resourceBarFrameLevel", nil, function() DF:LightweightUpdateResourceBarFrameLevel() end, true)), 55)', 1, true) ~= nil,
          "frame level: the Position card ends in classic's own slider call -- same key, range, callbacks and tooltip")
    local frames = 0
    for _ in PAGE:gmatch('L%["Frame Level"%], 0, 100, 1, db, "resourceBarFrameLevel"') do frames = frames + 1 end
    eq(frames, 2, "frame level: two sliders on the page -- classic's box and the Position card")
    check(PAGE:find("local frameLevelGroup = GUI:CreateSettingsGroup(self.child, 280)", 1, true) ~= nil
      and PAGE:find('frameLevelGroup:AddWidget(GUI:CreateHeader(self.child, L["Frame Level"]), 40)', 1, true) ~= nil
      and PAGE:find("Add(frameLevelGroup, nil, 1)", 1, true) ~= nil,
          "frame level: classic keeps its own box, header and column")
end

-- ============================================================
-- 6. THE ORDER -- classic unmoved, and the cards in the same sequence
-- ============================================================
print("-- Resource Bar page: the Add order in both layouts")
do
    local ORDER = {
        "Add(settingsGroup, nil, 1)", "Add(classFilterGroup, nil, 1)", "Add(sizeGroup, nil, 1)",
        "Add(positionGroup, nil, 1)", "Add(appearanceGroup, nil, 2)", "Add(bgGroup, nil, 2)",
        "Add(borderGroup, nil, 2)", "Add(frameLevelGroup, nil, 1)", "Add(colorGroup, nil, 2)",
    }
    local prev = 0
    for _, a in ipairs(ORDER) do
        local at = PAGE:find(a, 1, true)
        check(at ~= nil and at > prev, "classic: still calls " .. a .. " in sequence")
        prev = at or prev
    end
    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "),
       "Resource Bar Settings | Class Filter | Size | Position | Appearance | Background | Border | Resource Colors",
       "order: the cards open in classic's order, which is the one-column fold's")
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 9, "classic: nine bare 280 boxes, the classic arms' own")
    check(SRC:find('CreateCopyButton(self.child, {"resourceBar"}, L["Resource Bar"], "bars_resource")', 1, true) ~= nil,
          "page: the copy button is untouched")
end

-- ============================================================
-- 7. ZERO NEW LOCALE STRINGS
-- ============================================================
print("-- Resource Bar page: every locale string the page asks for already ships")
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
