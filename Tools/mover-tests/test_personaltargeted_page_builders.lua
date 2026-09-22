local NS = ...

-- ============================================================
-- PERSONAL TARGETED PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Indicators.lua
-- ------------------------------------------------------------
-- Indicators > Personal Targeted: NINE classic boxes. In Modern they are the
-- Debuff Bar's collapsible CARDS -- two per row inside a card wide enough, dim
-- captions, the value summary in a shut card's corner, Expand All / Collapse
-- All at the top -- in the columns and the order the old bands had:
--
--   column 1   "Content"     Settings (holds the PAGE gate in its body),
--                            Content Types.
--   column 2   "Appearance"  Size (Growth Direction at its foot), Border (Show
--                            Border is the header's tick), Duration Text.
--   column 1   "Effects"     Highlight Settings, Border Shadow, Border
--                            Animation, Interrupt Settings, X Mark.
--
-- ☠ TWO THINGS MOVED. Growth Direction was a lone control row; it now sits at
-- the foot of Size. Highlight Settings was one panel of twenty-eight controls;
-- Modern splits it into three cards (ring, shadow, animation) built by three
-- builders from the same shared helpers, while classic still mounts the one
-- original builder into its one box.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY, so this file reads the page's SOURCE.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each original builder (the PRE-CHANGE one) -- the
--     evidence CLASSIC RENDERS AS IT DID -- and classic's Add order.
--   ✓ that the three split builders together ask the helpers for exactly what
--     the original asked for, on the same keys, with the same gate.
--   ✓ each card's column, stable collapse key, summary, grey gate, header tick
--     and pin; one checkbox per setting; the moved Growth Direction.
--   ✗ nothing about how any of it LOOKS or behaves in the client.
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
    CreateFontDropdown = "fontdropdown", CreateOutlineDropdown = "outlinedropdown",
    CreateShadowCheckbox = "shadowcheckbox",
    CreateBorderShadowControls = "bordershadow", CreateAnimationControls = "animation",
}

-- The body of a `local function <name>(tools2)` at the page builder's own indent.
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
    local a = SRC:find('BuildPage(pagePersonalTargeted, function(self, db, Add, AddSpace, AddSyncPoint)', 1, true)
    local b = SRC:find('-- Indicators > Icons', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Personal Targeted page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- ONE CARD'S BLOCK, flattened; `call` is just the OpenSection call. The three
-- Highlight cards close `band`, `sband` and `aband`.
local function sectionBlock(labelKey)
    local a = PAGE:find('OpenSection(L["' .. labelKey .. '"]', 1, true)
    check(a ~= nil, "source: a card is opened for " .. labelKey)
    if not a then return "", "" end
    local b, e = PAGE:find("CloseSection%([sa]?band%)", a)
    check(b ~= nil, "source: ..." .. labelKey .. "'s band is closed after its controls")
    local block = PAGE:sub(a, e or a):gsub("%s+", " ")
    local m = block:find("({ group = band,", 1, true) or block:find("({ group = sband,", 1, true)
           or block:find("({ group = aband,", 1, true)
    local call = m and block:sub(1, m) or block
    call = call:gsub("Build[%w]+%($", "")
    return block, call
end

-- ============================================================
-- 1. THE SHARED MACHINERY, AND THE ROWS GONE
-- ============================================================
print("-- Personal Targeted page: the shared machinery and the page-scope vocabulary")
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
                            "contentBand", "appearanceBand", "effectsBand",
                            "OnPersonalEnableToggle", "OnPersonalBorderToggle",
                            "OnPersonalHighlightToggle", "OnPersonalInterruptToggle",
                            "OnPersonalXMarkToggle" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end

    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: every card goes through the shared helper, two per row and dim captions")
    check(PAGE:find("local function CloseSection(band)\n            tools.CloseSection(Add, band)\n        end", 1, true) ~= nil,
          "sections: ...and closes through the shared helper too")

    for _, pair in ipairs({ { "Content", "1" }, { "Appearance", "2" }, { "Effects", "1" } }) do
        local n = 0
        for _ in PAGE:gmatch('Add%(GUI:CreateHeader%(self%.child, L%["' .. pair[1] .. '"%]%), 40, ' .. pair[2] .. '%)') do n = n + 1 end
        eq(n, 1, "headers: the " .. pair[1] .. " category header sits in column " .. pair[2] .. ", once")
    end

    local decls = 0
    for _ in PAGE:gmatch("local growthOptions = {") do decls = decls + 1 end
    eq(decls, 1, "vocab: growthOptions is declared exactly once, at page scope")
    for _, g in ipairs({ "HidePersonalOptions", "HidePersonalDurationOptions", "HidePersonalHighlightOptions",
                         "HideInterruptOptions", "HideInterruptXOptions", "PersonalOffRow",
                         "InterruptOffRow", "HighlightOffRow", "PersonalTargetedUpdate" }) do
        local n = 0
        for _ in PAGE:gmatch("local function " .. g .. "%(") do n = n + 1 end
        eq(n, 1, "vocab: " .. g .. " is declared exactly once")
    end
    check(PAGE:find("GUI:RefreshCurrentPage", 1, true) == nil,
          "rebuild: the page never rebuilds itself, in either layout")
end

-- ============================================================
-- 2. THE BUILDERS, CONTROL BY CONTROL, AND THEIR CARDS
-- Every golden below is the census of the PRE-CHANGE source.
-- ============================================================
local PT_SETTINGS = {
    { "label",    "Shows incoming targeted spells on YOU in the center of your screen.", "(none)", 30 },
    { "label",    "To reposition: Unlock frames (/df unlock) and drag the mover.",       "(none)", 30 },
    { "checkbox", "Enable Personal Targeted Spells", "personalTargetedSpellEnabled",       30 },
    { "checkbox", "Important Spells Only",           "personalTargetedSpellImportantOnly", 30 },
    { "checkbox", "Show Offscreen Nameplates",       "(none)",                             30 },
}
local PT_CONTENT = {
    { "label",    "Show in content types:",                        "(none)",                                25 },
    { "checkbox", "Open World",                                    "personalTargetedSpellInOpenWorld",      25 },
    { "checkbox", "Dungeons",                                      "personalTargetedSpellInDungeons",       25 },
    { "checkbox", "Raids",                                         "personalTargetedSpellInRaids",          25 },
    { "checkbox", "Arena",                                         "personalTargetedSpellInArena",          25 },
    { "checkbox", "Battlegrounds",                                 "personalTargetedSpellInBattlegrounds",  25 },
    { "label",    "Content type filters configured in Party tab.", "(none)",                                25 },
}
local PT_SIZE = {
    { "slider", "Icon Size", "personalTargetedSpellSize",     55 },
    { "slider", "Scale",     "personalTargetedSpellScale",    55 },
    { "slider", "Alpha",     "personalTargetedSpellAlpha",    55 },
    { "slider", "Spacing",   "personalTargetedSpellSpacing",  55 },
    { "slider", "Max Icons", "personalTargetedSpellMaxIcons", 55 },
}
local PT_BORDER = {
    { "bordercontrols", "(none)", "personalTargetedSpell", nil },
}
local PT_DURATION = {
    { "checkbox",        "Show Duration",       "personalTargetedSpellShowDuration",    30 },
    { "checkbox",        "Show Cooldown Swipe", "personalTargetedSpellShowSwipe",       30 },
    { "fontdropdown",    "Font",                "personalTargetedSpellDurationFont",    55 },
    { "slider",          "Scale",               "personalTargetedSpellDurationScale",   55 },
    { "outlinedropdown", "Outline",             "personalTargetedSpellDurationOutline", 55 },
    { "shadowcheckbox",  "Shadow",              "personalTargetedSpellDurationOutline", 30 },
    { "slider",          "Offset X",            "personalTargetedSpellDurationX",       55 },
    { "slider",          "Offset Y",            "personalTargetedSpellDurationY",       55 },
    { "colorpicker",     "Color",               "personalTargetedSpellDurationColor",   35 },
}
-- Classic's ONE Highlight Settings box, untouched.
local PT_HIGHLIGHT = {
    { "checkbox",       "Highlight Important Spells", "personalTargetedSpellHighlightImportant", 30 },
    { "bordercontrols", "(none)",                     "personalTargetedSpellImportant",          nil },
}
-- ...and Modern's three cards.
local PT_HL_RING = {
    { "checkbox",       "Highlight Important Spells", "personalTargetedSpellHighlightImportant", 30 },
    { "bordercontrols", "(none)",                     "personalTargetedSpellImportant",          nil },
}
local PT_HL_SHADOW = {
    { "bordershadow", "(none)", "personalTargetedSpellImportant", nil },
}
local PT_HL_ANIM = {
    { "animation", "(none)", "personalTargetedSpellImportantBorderAnimation", nil },
}
local PT_INTERRUPT = {
    { "checkbox",    "Show Interrupted Visual", "personalTargetedSpellShowInterrupted",      30 },
    { "slider",      "Duration",                "personalTargetedSpellInterruptedDuration",  55 },
    { "colorpicker", "Tint Color",              "personalTargetedSpellInterruptedTintColor", 35 },
    { "slider",      "Tint Opacity",            "personalTargetedSpellInterruptedTintAlpha", 55 },
}
local PT_XMARK = {
    { "checkbox",    "Show X Mark", "personalTargetedSpellInterruptedShowX",  30 },
    { "colorpicker", "X Color",     "personalTargetedSpellInterruptedXColor", 35 },
    { "slider",      "X Size",      "personalTargetedSpellInterruptedXSize",  55 },
}

-- label, stable collapse key, card column; `box`/`classicCol` = the classic box
-- the SAME builder fills (nil for the two split-off cards); `dim` = the gate its
-- header greys on; `pin` = passes its builder; `tick` = its on/off moved into
-- the header, with the gate the tick itself greys on.
local CARDS = {
    { label = "Settings", key = "personaltargeted_settings", col = 1, box = "Settings", classicCol = 1,
      builder = "BuildPersonalSettingsGroup", golden = PT_SETTINGS, summary = "PersonalSettingsSummary" },
    { label = "Content Types", key = "personaltargeted_content", col = 1, box = "Content Types", classicCol = 2,
      builder = "BuildPersonalContentGroup", golden = PT_CONTENT, summary = "PersonalContentSummary",
      dim = "PersonalOffRow" },
    { label = "Size", key = "personaltargeted_size", col = 2, box = "Size", classicCol = 1,
      builder = "BuildPersonalSizeGroup", golden = PT_SIZE, summary = "PersonalSizeSummary",
      dim = "PersonalOffRow", pin = true },
    { label = "Border", key = "personaltargeted_border", col = 2, box = "Border", classicCol = 2,
      builder = "BuildPersonalBorderGroup", golden = PT_BORDER, summary = "PersonalBorderSummary",
      dim = "PersonalOffRow", pin = true, composite = "noShowToggle",
      tick = { key = "personalTargetedSpellShowBorder", name = "Show Border", gate = "PersonalOffRow" } },
    { label = "Duration Text", key = "personaltargeted_duration", col = 2, box = "Duration Text", classicCol = 2,
      builder = "BuildPersonalDurationGroup", golden = PT_DURATION, summary = "PersonalDurationSummary",
      dim = "PersonalOffRow", pin = true },
    { label = "Highlight Settings", key = "personaltargeted_highlight", col = 1,
      builder = "BuildPersonalHighlightRingGroup", golden = PT_HL_RING, summary = "PersonalHighlightSummary",
      dim = "PersonalOffRow", pin = true, split = true,
      tick = { key = "personalTargetedSpellHighlightImportant", name = "Highlight Important Spells", gate = "PersonalOffRow" } },
    { label = "Border Shadow", key = "personaltargeted_highlightshadow", col = 1, band = "sband",
      builder = "BuildPersonalHighlightShadowGroup", golden = PT_HL_SHADOW, summary = "PersonalHighlightShadowSummary",
      dim = "HighlightOffRow", pin = true, split = true, composite = "noEnableToggle",
      tick = { key = "personalTargetedSpellImportantBorderShadowEnabled", name = "Border Shadow", gate = "HighlightOffRow" } },
    { label = "Border Animation", key = "personaltargeted_highlightanim", col = 1, band = "aband",
      builder = "BuildPersonalHighlightAnimationGroup", golden = PT_HL_ANIM, summary = "nil",
      dim = "HighlightOffRow", pin = true, split = true },
    { label = "Interrupt Settings", key = "personaltargeted_interrupt", col = 1, box = "Interrupt Settings", classicCol = 2,
      builder = "BuildPersonalInterruptGroup", golden = PT_INTERRUPT, summary = "PersonalInterruptSummary",
      dim = "PersonalOffRow", pin = true,
      tick = { key = "personalTargetedSpellShowInterrupted", name = "Show Interrupted Visual", gate = "PersonalOffRow" } },
    { label = "X Mark", key = "personaltargeted_xmark", col = 1, box = "X Mark", classicCol = 2,
      builder = "BuildPersonalXMarkGroup", golden = PT_XMARK, summary = "PersonalXMarkSummary",
      dim = "InterruptOffRow", pin = true,
      tick = { key = "personalTargetedSpellInterruptedShowX", name = "Show X Mark", gate = "InterruptOffRow" } },
}

local function classicBox(header)
    for at, name in PAGE:gmatch("()local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)") do
        local want = name .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. header .. '"])'
        local hit = PAGE:find(want, at, true)
        if hit and hit - at < 900 then return name end
    end
end

for _, g in ipairs(CARDS) do
    print("-- Personal Targeted page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())

    local calls = 0
    for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
    if g.split then
        -- Declared once and mounted once, by its card -- classic never sees it.
        -- (The pin is handed the builder by name, not called.)
        eq(calls, 2, g.label .. ": declared once, mounted by its card only")
    else
        eq(calls, 3, g.label .. ": declared once, mounted twice -- classic box and card")
    end

    if g.box then
        local box = classicBox(g.box)
        check(box ~= nil, g.label .. ": the classic box keeps its own header")
        if box then
            check(PAGE:find("Add(" .. box .. ", nil, " .. g.classicCol .. ")", 1, true) ~= nil,
                  g.label .. ": ...which still goes to column " .. g.classicCol)
        end
    end

    local block, call = sectionBlock(g.label)
    check(block:find('OpenSection(L["' .. g.label .. '"], "' .. g.key .. '", ' .. g.col .. ', ' .. g.summary, 1, true) ~= nil,
          g.label .. ": a card keyed " .. g.key .. " in column " .. g.col .. ", printing " .. g.summary)
    if g.dim then
        check(call:find(g.summary .. ", " .. g.dim, 1, true) ~= nil, g.label .. ": greys its header on " .. g.dim)
    else
        check(call:find("OffRow", 1, true) == nil, g.label .. ": never greys -- it holds the page's switch")
    end
    eq(call:find(g.builder, 1, true) ~= nil, g.pin == true,
       g.label .. (g.pin and ": pinnable, from its own builder" or ": decides what SHOWS, so it grows no pin"))

    if g.tick then
        check(call:find('db = db, key = "' .. g.tick.key .. '", label = L["' .. g.tick.name .. '"]', 1, true) ~= nil,
              g.label .. ": the header tick is bound to " .. g.tick.key .. " under its own name")
        check(call:find("disableOn = " .. g.tick.gate, 1, true) ~= nil,
              g.label .. ": ...greyed on " .. g.tick.gate .. ", the gate its in-body checkbox carried")
        check(call:find("onChanged = function()", 1, true) ~= nil
          and call:find("self:RefreshStates()", 1, true) ~= nil
          and call:find("PersonalTargetedUpdate()", 1, true) ~= nil
          and call:find("RefreshCurrentPage", 1, true) == nil,
              g.label .. ": ...committing what its in-body checkbox ran, never a page rebuild")
        if g.composite then
            check(body:find(g.composite .. " = tools2.hoistToggle or nil", 1, true) ~= nil,
                  g.label .. ": the composite is told not to build its own toggle (" .. g.composite .. ")")
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
-- 3. HIGHLIGHT SETTINGS: CLASSIC'S ONE BOX, MODERN'S THREE CARDS
-- ============================================================
print("-- Personal Targeted page: Highlight Settings, split")
do
    -- Classic still mounts the ORIGINAL builder, census unchanged, into its box.
    local orig = builderBody("BuildPersonalHighlightGroup")
    checkCensus(census(orig), PT_HIGHLIGHT, "highlight (classic)")
    local calls = 0
    for _ in PAGE:gmatch("BuildPersonalHighlightGroup%(") do calls = calls + 1 end
    eq(calls, 2, "split: the original builder is declared once and mounted by classic only")
    local box = classicBox("Highlight Settings")
    check(box ~= nil and PAGE:find("Add(" .. box .. ", nil, 1)", 1, true) ~= nil,
          "split: ...into the Highlight Settings box, still in column 1")

    -- ☠ THE THREE ASK THE HELPERS FOR EXACTLY WHAT THE ONE DID.
    local flatOrig = orig:gsub("%s+", " ")
    check(flatOrig:find("include = { alpha = true, inset = true, blendMode = true, gradient = true, shadow = true, animate = true }", 1, true) ~= nil,
          "split: the original asks for the ring, the shadow and the animation")
    local ring = builderBody("BuildPersonalHighlightRingGroup"):gsub("%s+", " ")
    check(ring:find('GUI:CreateBorderControls(group, db, "personalTargetedSpellImportant", {', 1, true) ~= nil
      and ring:find("include = { alpha = true, inset = true, blendMode = true, gradient = true },", 1, true) ~= nil,
          "split: the ring card asks for the same prefix and everything but shadow and animation")
    for _, same in ipairs({ "noShowToggle = true,", "sizeMin = 0, sizeMax = 8, sizeStep = 1,",
                            "disableWhen = HidePersonalHighlightOptions,", "fullUpdate = PersonalTargetedUpdate,",
                            "lightUpdate = PersonalTargetedUpdate,", "lightColors = PersonalTargetedUpdate," }) do
        check(flatOrig:find(same, 1, true) ~= nil and ring:find(same, 1, true) ~= nil,
              "split: ...with the same " .. same)
    end
    local shadow = builderBody("BuildPersonalHighlightShadowGroup"):gsub("%s+", " ")
    check(shadow:find('GUI:CreateBorderShadowControls(tools2.group, db, "personalTargetedSpellImportant", {', 1, true) ~= nil
      and shadow:find("disableWhen = HidePersonalHighlightOptions,", 1, true) ~= nil,
          "split: the shadow card builds the toolkit's own shadow block on the same prefix, same gate")
    local anim = builderBody("BuildPersonalHighlightAnimationGroup"):gsub("%s+", " ")
    check(anim:find('GUI:CreateAnimationControls(tools2.group, db, "personalTargetedSpellImportantBorderAnimation", {', 1, true) ~= nil
      and anim:find('typeLabel = L["Border Animation"],', 1, true) ~= nil,
          "split: the animation card builds the toolkit's own animation block on the same keys and label")
    check(anim:find("tools2.group.disableChildrenOn = HidePersonalHighlightOptions", 1, true) ~= nil,
          "split: ...greyed by the same gate, as a group gate (the helper composes none)")
    -- The three cards open together, ring first.
    local r = PAGE:find('OpenSection(L["Highlight Settings"]', 1, true)
    local s = PAGE:find('OpenSection(L["Border Shadow"]', 1, true)
    local a = PAGE:find('OpenSection(L["Border Animation"]', 1, true)
    check(r and s and a and r < s and s < a, "split: Highlight Settings, Border Shadow, Border Animation, in that order")
end

-- ============================================================
-- 4. THE CARDS TOGETHER
-- ============================================================
print("-- Personal Targeted page: the cards together")
do
    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "),
       "Settings | Content Types | Size | Border | Duration Text | Highlight Settings | Border Shadow | Border Animation | Interrupt Settings | X Mark",
       "order: the ten cards open in the old bands' order -- Content, Appearance, Effects")
    local contentAt = PAGE:find('Add(GUI:CreateHeader(self.child, L["Content"]), 40, 1)', 1, true)
    local appAt     = PAGE:find('Add(GUI:CreateHeader(self.child, L["Appearance"]), 40, 2)', 1, true)
    local sizeAt    = PAGE:find('OpenSection(L["Size"]', 1, true)
    local fxAt      = PAGE:find('Add(GUI:CreateHeader(self.child, L["Effects"]), 40, 1)', 1, true)
    local hlAt      = PAGE:find('OpenSection(L["Highlight Settings"]', 1, true)
    check(contentAt and appAt and sizeAt and contentAt < appAt and appAt < sizeAt, "order: Appearance heads Size")
    check(fxAt and hlAt and fxAt < hlAt, "order: Effects heads Highlight Settings")

    -- ---- Growth Direction moved INTO Size -----------------------------
    local size = sectionBlock("Size")
    check(size:find('band:AddWidget(GUI:CreateDropdown(self.child, L["Growth Direction"], growthOptions, db, "personalTargetedSpellGrowth", PersonalTargetedUpdate), 55)', 1, true) ~= nil,
          "growth: Growth Direction sits at the foot of Size -- it arranges the icons")
    check(size:find("ptsGrowth.disableOn = HidePersonalOptions", 1, true) ~= nil,
          "growth: ...with the gate classic's box gives it")
    local g1 = size:find("BuildPersonalSizeGroup({", 1, true)
    local g2 = size:find('L["Growth Direction"]', 1, true)
    check(g1 and g2 and g1 < g2, "growth: ...after the Size builder's own controls")
    check(PAGE:find('GUI:CreateHeader(self.child, L["Growth"])', 1, true) ~= nil
      and PAGE:find("Add(growthGroup, nil, 1)", 1, true) ~= nil,
          "growth: classic still builds its own Growth box in column 1")

    -- ---- one checkbox per setting --------------------------------------
    local hoists = 0
    for _ in PAGE:gmatch("hoistToggle = true,") do hoists = hoists + 1 end
    eq(hoists, 5, "ticks: exactly five mounts ask their builder to skip the in-body toggle")
    local inCards = 0
    for _, g in ipairs(CARDS) do
        if g.tick then inCards = inCards + select(2, (sectionBlock(g.label)):gsub("hoistToggle = true,", "")) end
    end
    eq(inCards, hoists, "ticks: ...and every one is a ticked card's -- classic never passes it")
    check((sectionBlock("Settings")):find("personalTargetedSpellEnabled", 1, true) == nil,
          "ticks: Enable Personal Targeted Spells is not in Settings' header")
    check(builderBody("BuildPersonalSettingsGroup"):find('L["Enable Personal Targeted Spells"], db, "personalTargetedSpellEnabled"', 1, true) ~= nil,
          "ticks: ...its builder still builds it in the body")
    check((sectionBlock("Duration Text")):find('key = "', 1, true) == nil,
          "ticks: Duration Text has no header tick -- Show Duration does not switch the swipe off")

    -- ---- Expand All / Collapse All --------------------------------------
    check(PAGE:find('Add(tools.SectionControls(self.child), 24, "both")', 1, true) ~= nil,
          "bulk: the page adds the pair at the top, spanning both columns")
    local stripAt = PAGE:find("tools.SectionControls", 1, true)
    check(stripAt and contentAt and stripAt < contentAt,
          "bulk: ...above the first category header")

    -- ---- nine classic boxes, in the order they always had ---------------
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 9, "classic: nine bare 280 boxes, and they are the classic branch's own")
    local prev = 0
    for _, a in ipairs({ "settingsGroup, nil, 1", "contentGroup, nil, 2", "sizeGroup, nil, 1",
                         "growthGroup, nil, 1", "borderGroup, nil, 2", "durationGroup, nil, 2",
                         "highlightGroup, nil, 1", "interruptGroup, nil, 2", "xMarkGroup, nil, 2" }) do
        local at = PAGE:find("Add(" .. a .. ")", 1, true)
        check(at ~= nil and at > prev, "classic: still calls Add(" .. a .. ") in sequence")
        prev = at or prev
    end

    check(PAGE:find('CreateCopyButton(self.child, {"personalTargeted"}, L["Personal Targeted"], "indicators_personal_targeted")', 1, true) ~= nil,
          "page: the copy button keeps the prefix it owns")
    check(PAGE:find('{pageId = "indicators_targetedlist", label = L["Targeted List"]}', 1, true) ~= nil,
          "page: ...and the See Also block still points at the Targeted List")
end
