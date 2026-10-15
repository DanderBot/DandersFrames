local NS = ...

-- ============================================================
-- DISPEL OVERLAY PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Modules.lua
-- ------------------------------------------------------------
-- Auras > Dispel Overlay: the Debuff Bar's collapsible CARDS -- two per row
-- inside a card wide enough, dim captions, the value summary in a shut card's
-- corner, Expand All / Collapse All at the top -- FOUR of them, with Pulse
-- Overlay at the foot of Settings:
--
--   column 1   Settings (holds the PAGE gate, Enable Dispel Overlay, in its
--              body -- as Show Buffs does -- plus Pulse Overlay) and Gradient
--              (Show Gradient is its header tick).
--   column 2   Dispel Symbol and Border (Show Dispel Symbol / Show Border are
--              their header ticks).
--
-- ⚠ GRADIENT IS IN COLUMN 1, which is what balances the page.
--
-- ☠ THE PAGE GATE GREYS, IT DOES NOT HIDE: hiding a card's controls leaves a
-- header over an empty body. The three looks cards dim their headers and grey
-- their ticks, and every card body greys whole (GreyWithPage) with the switch
-- itself kept live. The one hideOn left is a widget's OWN variant gate.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db -- so this file
-- does what the other census files do: it reads the page's SOURCE and asserts
-- against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each builder -- kind, L key, db key and slot height,
--     in order.
--   ✓ how each card mounts its builder (hoistToggle where the tick lives in
--     the header).
--   ✓ each card's column, stable collapse key, summary, grey, tick and pin; that
--     there is one checkbox per setting.
--   ✓ the two opt-ins (two per row, dim captions) and that no count survives.
--   ✗ nothing about runtime behaviour -- the folding, the two-per-row flow, the
--     dim captions and the greys are read in game.
-- ============================================================

-- ⚠ NORMALISED TO LF UP FRONT. This page file ships CRLF (the companion's files
-- are mixed per file), and a plain multi-line `find` for source text would miss
-- every one of them otherwise. Nothing here asserts about line endings.
local SRC = options_file_source("GUI/Pages/Modules.lua"):gsub("\r\n", "\n")

-- ---- the census reader (the Missing Buffs page's, plus this page's link) ----
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateSeparator = "separator", CreateButton = "button",
    CreateGrowthControl = "growth", CreateTextureDropdown = "texturedropdown",
    CreateTextControls = "textcontrols", CreateBorderControls = "bordercontrols",
    CreateDurationFormatControls = "durationformat", CreateInfoBanner = "banner",
    -- The shared cross-link to the account-wide dispel palette. Not a setting --
    -- it has no db key at all -- but it IS a control the builder mounts.
    CreateDispelColorsPageLink = "pagelink",
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
    local a = SRC:find('BuildPage(pageDispel, function(self, db, Add, AddSpace, AddSyncPoint)', 1, true)
    local b = SRC:find('CreateCategory("profiles", L["Profiles"])', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Dispel Overlay page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- ONE CARD'S BLOCK: its OpenSection call, the builder mount under it and the
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
    call = call:gsub("Build[%w]+%($", "")
    return block, call
end

-- ============================================================
-- 1. THE SHARED MACHINERY, AND THE POPOUT FURNITURE GONE
-- ============================================================
print("-- Dispel Overlay page: the shared machinery and the page-scope vocabulary")
do
    check(PAGE:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true) ~= nil,
          "tools: ...and takes the shared machinery unconditionally")
    for _, v in ipairs({ "PopoutContent", "ReflowPane", "ReflowMounted", "ClaimKeys",
                         "WireModifiedTick", "WireFooter", "RegisterHoistedToggle",
                         "RegisterControlRow", "RefreshAfterGroupWrite", "HoldReason" }) do
        check(PAGE:find("local function " .. v .. "(", 1, true) == nil,
              "tools: the page does not re-declare " .. v)
    end

    -- ☠ THE ROW FURNITURE IS GONE ENTIRELY, not half-gone: rows, the control
    -- row, panes on a plate, claims, counts, footers, hoisted search repairs, the
    -- two bands and their per-row commits were all PopoutRow furniture.
    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "tools.PopoutContent(", "tools.ClaimKeys(",
                            "tools.WireModifiedTick(", "tools.WireFooter(",
                            "tools.RegisterHoistedToggle(", "tools.RegisterControlRow(",
                            "GUI:CreateControlRow(", "GatePaneFirstChild", "footerStrip",
                            "inline = true", "popout = true,", "_COUNT = ", "count =",
                            "contentBand", "appearanceBand", "animateRow",
                            "OnDispelEnableToggle", "OnDispelIconToggle",
                            "OnDispelBorderToggle", "OnDispelGradientToggle" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end

    -- ---- the section helpers: forwards to the shared ones, with both opt-ins
    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: every card goes through the shared helper, two per row and dim captions")
    check(PAGE:find("local function CloseSection(band)\n            tools.CloseSection(Add, band)\n        end", 1, true) ~= nil,
          "sections: ...and closes through the shared helper too")

    -- ---- the vocabulary, at PAGE scope, declared exactly once ---------
    for _, v in ipairs({ "dispelIndicatorOptions", "iconPositions", "gradientStyles", "blendModes" }) do
        local decls = 0
        for _ in PAGE:gmatch("local " .. v .. " = {") do decls = decls + 1 end
        eq(decls, 1, "vocab: " .. v .. " is declared exactly once, at page scope")
    end
    check(PAGE:find('["TOPRIGHT"]= L["Top Right"]', 1, true) ~= nil,
          "vocab: ...and iconPositions is the same table the Symbol Position dropdown has always offered")
    check(PAGE:find('["EDGE"]= L["Edge Glow (All Sides)"]', 1, true) ~= nil,
          "vocab: ...and gradientStyles the same one Gradient Position has always offered")
    local lastVocab = PAGE:find("local blendModes = {", 1, true)
    for _, b in ipairs({ "BuildDispelSettingsGroup", "BuildDispelIconGroup",
                         "BuildDispelBorderGroup", "BuildDispelGradientGroup" }) do
        local at = PAGE:find("local function " .. b .. "(tools2)", 1, true)
        check(at ~= nil and lastVocab ~= nil and lastVocab < at,
              "vocab: " .. b .. " is declared after it, so it closes over the real tables")
    end
    for _, g in ipairs({ "ApplyDispelSettings", "InvalidateCurves",
                         "OnDispelTypeChanged", "DispelOffRow", "GreyWithPage",
                         "OnDispelCardTick" }) do
        local n = 0
        for _ in PAGE:gmatch("local function " .. g .. "%(") do n = n + 1 end
        eq(n, 1, "vocab: " .. g .. " is declared exactly once")
    end
    for _, gone in ipairs({ "HideIfDisabled", "HideDispelOptions", "GateHide" }) do
        check(PAGE:find(gone, 1, true) == nil, "vocab: " .. gone .. " is gone -- the page gate never hides")
    end
    for _, g in ipairs({ "DisableIfNoGradient", "DisableIfNoBorder", "DisableIfNoIcon" }) do
        local n = 0
        for _ in PAGE:gmatch("local " .. g .. " = function") do n = n + 1 end
        eq(n, 1, "vocab: " .. g .. " is declared exactly once, at page scope")
    end
    -- ⚠ ABOVE THE BUILDERS: they close over it.
    local greyAt = PAGE:find("local function GreyWithPage(tools2)", 1, true)
    local firstBuilder = PAGE:find("local function BuildDispelSettingsGroup(tools2)", 1, true)
    check(greyAt and firstBuilder and greyAt < firstBuilder,
          "vocab: GreyWithPage is declared above every builder")
end

-- ============================================================
-- 2. THE PAGE GATE -- a GREY
-- ============================================================
print("-- Dispel Overlay page: the page gate")
do
    check(PAGE:find("local function DispelOffRow(d) return not (d or db).dispelOverlayEnabled end", 1, true) ~= nil,
          "gate: the page names the grey half of its gate once")

    -- ---- the grey: every builder greys whole in a card or a pinned panel ----
    local grey = (PAGE:match("local function GreyWithPage%(tools2%)(.-)\n        end") or ""):gsub("%s+", " ")
    check(grey:find("tools2.group.disableChildrenOn = DispelOffRow", 1, true) ~= nil,
          "gate: GreyWithPage greys the whole group")
    for _, b in ipairs({ "BuildDispelSettingsGroup", "BuildDispelIconGroup",
                         "BuildDispelBorderGroup", "BuildDispelGradientGroup" }) do
        check(builderBody(b):find("GreyWithPage(tools2)", 1, true) ~= nil,
              "gate: " .. b .. " greys with the page in a card")
    end
    -- ☠ THE SWITCH ITSELF STAYS LIVE, or nothing could lift the grey.
    local settings = builderBody("BuildDispelSettingsGroup")
    check(settings:find("enableCb.keepEnabled = true", 1, true) ~= nil,
          "gate: Enable Dispel Overlay is spared by the grey it drives")
    local gates = 0
    for _ in PAGE:gmatch("%.disableChildrenOn%s*=") do gates = gates + 1 end
    eq(gates, 1, "gate: GreyWithPage is the page's only group-level child gate")

    -- ---- no hide on the page gate --------------------------------------
    -- ☠ A hideOn on the page gate would hide controls in a CARD, the empty body
    -- the grey exists to avoid. The ONE hideOn is a variant gate.
    for _, b in ipairs({ "BuildDispelSettingsGroup", "BuildDispelIconGroup",
                         "BuildDispelBorderGroup" }) do
        check(builderBody(b):find(".hideOn", 1, true) == nil,
              "gate: " .. b .. " hides nothing")
    end
    local grad = builderBody("BuildDispelGradientGroup")
    local hides = 0
    for _ in grad:gmatch("%.hideOn%s*=") do hides = hides + 1 end
    eq(hides, 1, "gate: BuildDispelGradientGroup hides one control")
    check(grad:find('onHealthCheck.hideOn = function(d) return d.dispelGradientStyle ~= "FULL" end', 1, true) ~= nil,
          "gate: ...Show On Current Health Only, on its own variant gate")

    -- ---- no page rebuild ---------------------------------------------
    check(PAGE:find("GUI:RefreshCurrentPage", 1, true) == nil,
          "rebuild: no page rebuild left on the page")
    check(settings:find("tools2.refreshStates()", 1, true) ~= nil,
          "rebuild: the Enable checkbox runs the state pass, and nothing more")
    for _, b in ipairs({ "BuildDispelSettingsGroup", "BuildDispelIconGroup",
                         "BuildDispelBorderGroup", "BuildDispelGradientGroup" }) do
        check(builderBody(b):find("self:RefreshStates()", 1, true) == nil,
              "rebuild: " .. b .. " never reaches past its own tools2 for a state pass")
    end
    local tick = (PAGE:match("local function OnDispelCardTick%(%)(.-)\n        end") or "")
    check(tick:find("ApplyDispelSettings()", 1, true) ~= nil
      and tick:find("self:RefreshStates()", 1, true) ~= nil
      and tick:find("tools.ReflowMounted()", 1, true) ~= nil
      and tick:find("RefreshCurrentPage", 1, true) == nil,
          "rebuild: the three header ticks commit what their checkbox ran, a state pass and a panel repaint -- never a rebuild")
end

-- ============================================================
-- 3. THE FOUR BUILDERS, CONTROL BY CONTROL, AND THEIR CARDS
-- ============================================================
local DISPEL_SETTINGS = {
    { "checkbox", "Enable Dispel Overlay", "dispelOverlayEnabled",    30 },
    { "dropdown", "Dispellable",           "dispelOverlayDispelType", 55 },
    -- The Colors-page cross-link. No L label of its own (its text is built by
    -- the shared factory) and its slot height is an expression, so the reader
    -- sees neither.
    { "pagelink", "(none)",                "(none)",                  nil },
}
local DISPEL_ICON = {
    { "checkbox", "Show Dispel Symbol", "dispelShowIcon",      30 },
    { "slider",   "Symbol Size",        "dispelIconSize",      55 },
    { "slider",   "Max Symbols",        "dispelIconMax",       55 },
    { "slider",   "Symbol Opacity",     "dispelIconAlpha",     55 },
    { "dropdown", "Symbol Position",    "dispelIconPosition",  55 },
    { "slider",   "Offset X",           "dispelIconOffsetX",   55 },
    { "slider",   "Offset Y",           "dispelIconOffsetY",   55 },
}
local DISPEL_BORDER = {
    { "checkbox", "Show Border",      "dispelShowBorder",  30 },
    { "slider",   "Border Thickness", "dispelBorderSize",  55 },
    { "slider",   "Border Inset",     "dispelBorderInset", 55 },
    { "slider",   "Border Opacity",   "dispelBorderAlpha", 55 },
}
local DISPEL_GRADIENT = {
    { "checkbox", "Show Gradient",                "dispelShowGradient",           30 },
    { "dropdown", "Gradient Position",            "dispelGradientStyle",          55 },
    { "checkbox", "Show On Current Health Only",  "dispelGradientOnCurrentHealth",30 },
    { "slider",   "Gradient Size",                "dispelGradientSize",           55 },
    { "slider",   "Gradient Opacity",             "dispelGradientAlpha",          55 },
    -- Frame Level is wrapped in SetFrameLevelTooltip, which the reader steps
    -- through: the factory underneath is still the slider it always was.
    { "slider",   "Frame Level",                  "dispelOverlayFrameLevel",      55 },
    { "dropdown", "Blend Mode",                   "dispelGradientBlendMode",      55 },
    { "checkbox", "Darken Behind Gradient",       "dispelGradientDarkenEnabled",  30 },
    { "slider",   "Darken Amount",                "dispelGradientDarkenAlpha",    55 },
}

-- label, stable collapse key, card column, the summary;
-- `dim` = greys with the page gate, `pin` = passes its builder (decides how the
-- overlay LOOKS), `tick` = its on/off moved into the header.
local CARDS = {
    { label = "Settings", key = "dispel_settings", col = 1,
      builder = "BuildDispelSettingsGroup", golden = DISPEL_SETTINGS, summary = "DispelSettingsSummary" },
    { label = "Dispel Symbol", key = "dispel_symbol", col = 2,
      builder = "BuildDispelIconGroup", golden = DISPEL_ICON, summary = "DispelIconSummary",
      dim = true, pin = true, tick = { key = "dispelShowIcon", name = "Show Dispel Symbol" } },
    { label = "Border", key = "dispel_border", col = 2,
      builder = "BuildDispelBorderGroup", golden = DISPEL_BORDER, summary = "DispelBorderSummary",
      dim = true, pin = true, tick = { key = "dispelShowBorder", name = "Show Border" } },
    { label = "Gradient", key = "dispel_gradient", col = 2,
      builder = "BuildDispelGradientGroup", golden = DISPEL_GRADIENT, summary = "DispelGradientSummary",
      dim = true, pin = true, tick = { key = "dispelShowGradient", name = "Show Gradient" } },
}

for _, g in ipairs(CARDS) do
    print("-- Dispel Overlay page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())

    local block, call = sectionBlock(g.label)
    check(block:find('OpenSection(L["' .. g.label .. '"], "' .. g.key .. '", ' .. g.col .. ', ' .. g.summary, 1, true) ~= nil,
          g.label .. ": a card keyed " .. g.key .. " in column " .. g.col .. ", printing the group's own summary")
    eq(call:find(g.summary .. ", DispelOffRow", 1, true) ~= nil, g.dim == true,
       g.label .. (g.dim and ": its header dims with the page gate" or ": never dims -- it holds the switch"))
    check(call:find(", nil, " .. g.builder, 1, true) ~= nil or not g.pin,
          g.label .. ": carries no hide gate")
    eq(call:find(g.builder, 1, true) ~= nil, g.pin == true,
       g.label .. (g.pin and ": pinnable, from its own builder" or ": decides what SHOWS, so it grows no pin"))

    if g.tick then
        check(call:find('db = db, key = "' .. g.tick.key .. '", label = L["' .. g.tick.name .. '"]', 1, true) ~= nil,
              g.label .. ": the header tick is bound to " .. g.tick.key .. " under its own name")
        check(call:find('isOn = function(d) return d.' .. g.tick.key .. ' ~= false end', 1, true) ~= nil,
              g.label .. ": ...reading off only when explicitly false, as its greys do")
        check(call:find("disableOn = DispelOffRow", 1, true) ~= nil,
              g.label .. ": ...greyed with the page gate")
        check(call:find("onChanged = OnDispelCardTick", 1, true) ~= nil,
              g.label .. ": ...committing through the page's tick commit")
        check(body:find("if not tools2.hoistToggle then", 1, true) ~= nil,
              g.label .. ": the builder skips its in-body copy when the header carries it")
        local mount = g.builder .. "({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end, hoistToggle = true, })"
        check(block:find(mount, 1, true) ~= nil,
              g.label .. ": mounts its builder with hoistToggle")
    else
        check(call:find("key = \"", 1, true) == nil, g.label .. ": no header tick")
        check(body:find("hoistToggle", 1, true) == nil,
              g.label .. ": ...and its builder has no hoist branch -- the page gate stays in the body")
        local mount = g.builder .. "({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end, })"
        check(block:find(mount, 1, true) ~= nil,
              g.label .. ": mounts its builder into the card's band")
    end
end

-- ============================================================
-- 4. THE CARDS TOGETHER, PULSE OVERLAY AND THE PAGE'S OWN FURNITURE
-- ============================================================
print("-- Dispel Overlay page: the cards together")
do
    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "), "Settings | Dispel Symbol | Border | Gradient",
       "order: the four cards open in reading order")

    -- The groups: Content over the dispel choice in column 1, Appearance over
    -- the three looks in column 2, each header before its first card.
    local function before(a, b) local i, j = PAGE:find(a, 1, true), PAGE:find(b, 1, true); return i and j and i < j end
    check(before('Add(GUI:CreateHeader(self.child, L["Content"]), 40, 1)', 'OpenSection(L["Settings"]'),
          "groups: Content heads column 1, before Settings")
    check(before('Add(GUI:CreateHeader(self.child, L["Appearance"]), 40, 2)', 'OpenSection(L["Dispel Symbol"]'),
          "groups: Appearance heads column 2, before Dispel Symbol")

    -- ---- one checkbox per setting --------------------------------------
    local hoists = 0
    for _ in PAGE:gmatch("hoistToggle = true,") do hoists = hoists + 1 end
    eq(hoists, 3, "ticks: exactly three mounts ask their builder to skip the in-body toggle")
    check((sectionBlock("Settings")):find("dispelOverlayEnabled", 1, true) == nil,
          "ticks: Enable Dispel Overlay is not hoisted into Settings' header")

    -- ---- Pulse Overlay moved into Settings -----------------------------
    local settings = sectionBlock("Settings")
    check(settings:find('local pulse = band:AddWidget(GUI:CreateCheckbox(self.child, L["Pulse Overlay"], db, "dispelAnimate", ApplyDispelSettings), 30)', 1, true) ~= nil,
          "pulse: Pulse Overlay is a checkbox at the foot of the Settings card, applying the settings")
    check(settings:find("pulse.fullRow = true", 1, true) ~= nil,
          "pulse: ...on a row of its own")
    local n = 0
    for _ in PAGE:gmatch('"dispelAnimate"') do n = n + 1 end
    eq(n, 1, "pulse: ...and dispelAnimate is bound once on the page")

    -- ---- Expand All / Collapse All --------------------------------------
    check(PAGE:find('Add(tools.SectionControls(self.child), 24, "both")', 1, true) ~= nil,
          "bulk: the page adds the pair at the top, spanning both columns")
    local stripAt = PAGE:find("tools.SectionControls", 1, true)
    local firstAt = PAGE:find("OpenSection(L[", 1, true)
    check(stripAt and firstAt and stripAt < firstAt,
          "bulk: ...above the first card, because it acts on the whole page")

    check(PAGE:find("GUI:CreateSettingsGroup(self.child, 280)", 1, true) == nil,
          "page: no fixed-width box is left on the page")

    -- ---- the page's own furniture is untouched -------------------------
    check(PAGE:find('CreateCopyButton(self.child, {"dispel"}, L["Dispel Overlay"], "auras_dispel")', 1, true) ~= nil,
          "page: the copy button keeps the prefix it owns")
    check(PAGE:find('{pageId = "auras_debuffs", label = L["Debuff Bar"]}', 1, true) ~= nil,
          "page: ...and the See Also block still points at the Debuff Bar")
    check(PAGE:find('{pageId = "indicators_highlights", label = L["Highlights"]}', 1, true) ~= nil,
          "page: ...and at Highlights")
end

-- ============================================================
-- 5. THE SUMMARIES
-- ============================================================
print("-- Dispel Overlay page: the summaries")
do
    check(PAGE:find('local function Join(parts) return table.concat(parts, " \\194\\183 ") end', 1, true) ~= nil,
          "summary: the sweep's separator is named once")
    for _, s in ipairs({ "DispelSettingsSummary", "DispelIconSummary",
                         "DispelBorderSummary", "DispelGradientSummary" }) do
        local n = 0
        for _ in PAGE:gmatch("local function " .. s .. "%(d%)") do n = n + 1 end
        eq(n, 1, "summary: " .. s .. " is declared exactly once")
        local body = PAGE:match("local function " .. s .. "%(d%)(.-)\n        end")
        check(body ~= nil and body:find("Join(parts)", 1, true) ~= nil,
              "summary: ..." .. s .. " joins with the shared separator")
        check(body ~= nil and body:find("if not d then return \"\" end", 1, true) ~= nil,
              "summary: ..." .. s .. " answers an absent db rather than erroring on it")
    end
    check(PAGE:find("dispelIndicatorOptions[d.dispelOverlayDispelType]", 1, true) ~= nil,
          "summary: Settings names the dispel type from the dropdown's own table")
    check(PAGE:find("iconPositions[d.dispelIconPosition]", 1, true) ~= nil,
          "summary: Dispel Symbol names the position from the dropdown's own table")
    check(PAGE:find("gradientStyles[d.dispelGradientStyle]", 1, true) ~= nil,
          "summary: Gradient names the wash from the dropdown's own table")
end
