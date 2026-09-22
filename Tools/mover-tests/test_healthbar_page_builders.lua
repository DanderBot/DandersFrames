local NS = ...

-- ============================================================
-- HEALTH BAR PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Auras.lua
-- ------------------------------------------------------------
-- Bars > Health Bar: three full-width collapsible sections over seven boxes in
-- classic; in modern, the Debuff Bar's collapsible CARDS -- one per box, the two
-- gradient editors included -- in two page columns:
--
--   column 1   Color, Gradient (hidden unless Health Gradient), Missing Health,
--              Gradient (missing health's, same kind of rule)
--   column 2   Texture, Background, Reduced Max Health (header tick)
--
-- ☠ THREE RULES MAKE THIS PAGE DIFFERENT FROM ITS SIBLINGS:
--
--   1. THE FULL-WIDTH SECTIONS AND THEIR SPACERS ARE CLASSIC'S ONLY. Each is a
--      "both" widget -- a sync point -- so in modern it would end both card
--      columns. Built through expressions so classic's arms are untouched.
--   2. THE GRADIENT EDITORS ARE CARDS WITHOUT A PIN: every structural edit
--      rebuilds the page, which would close a pinned copy. Section 7.
--   3. REDUCED MAX HEALTH'S ENABLE MOVES INTO ITS CARD'S HEADER (hoistToggle),
--      one checkbox per setting. Section 5.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY -- it is welded to the panel (a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db) -- so this file
-- does what every page-builder suite before it does: it reads the page's SOURCE
-- and asserts against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each extracted builder -- kind, L key, db key and
--     slot height, in order -- taken from the PRE-CHANGE source, so a builder
--     that quietly dropped a control or renamed a key fails here. This is also
--     the evidence that CLASSIC RENDERS AS IT DID: the classic branch mounts the
--     same builder into the same 280 box, under the same header, in the same
--     column, in the same order.
--   ✓ that ONE builder serves both layouts, and the card hands it EXACTLY what
--     classic hands it (plus hoistToggle where the tick moved to the header).
--   ✓ each card's column, stable collapse key, summary, hide gate, tick and pin;
--     the two opt-ins; Expand/Collapse All; no popout furniture or counts left.
--   ✓ that the four mode dropdowns route through tools2.refreshStates.
--   ✓ that every summary reads its words out of the dropdown table the control
--     itself offers, and that the page adds NO new locale string.
--   ✗ nothing about runtime behaviour -- the callbacks, the greying and the
--     summaries are read by eye and by the in-game checklist.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Auras.lua"):gsub("\r\n", "\n")

-- ---- the census reader (the Tooltips page's, plus the texture dropdown) ----
--
-- ⚠ CreateTextureDropdown IS IN THE MAP HERE and was not on any earlier page:
-- four of this page's controls are texture pickers, and a census that skipped
-- them would pass while a builder silently lost one.
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateTextureDropdown = "texturedropdown",
    CreateHeader = "header", CreateLabel = "label",
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

-- The page, scoped by its own two ends: Auras.lua holds a dozen pages, and a
-- bare 280 box on one of the others is not this pass's business.
local PAGE
do
    local a = SRC:find('L["Health Bar"], "bars_health")', 1, true)
    local b = SRC:find('{pageId = "bars_absorbs", label = L["Absorbs"]}', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Health Bar page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- ONE CARD'S BLOCK: its OpenSection call, the builder mount under it and the
-- CloseSection that puts its band in, flattened. `call` is just the OpenSection
-- call -- where the pin (a builder argument) and a tick are declared.
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

-- What every converted box on this page has in common. `boxHeader` is passed
-- separately from the card's label because two of the five boxes are headed
-- "Settings" in classic; their cards take the section's name instead.
local function checkShared(g)
    -- ONE builder, BOTH layouts: the declaration, the classic box's mount and
    -- the card's (a pin's panel copy is built by the shared helper).
    local calls = 0
    for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, g.label .. ": declared once, mounted twice -- classic box and card")

    check(PAGE:find("local " .. g.box .. " = GUI:CreateSettingsGroup(self.child, 280)", 1, true) ~= nil,
          g.label .. ": the classic 280 box is built")
    check(PAGE:find(g.box .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. g.boxHeader .. '"]), 40)', 1, true) ~= nil,
          g.label .. ": ...under the header it always had (" .. g.boxHeader .. ")")
    check(PAGE:find("AddToSection(" .. g.box .. ", nil, " .. g.column .. ")", 1, true) ~= nil,
          g.label .. ": ...and still goes to column " .. g.column .. ", inside its section")

    local block, call = sectionBlock(g.label)
    check(block:find('OpenSection(L["' .. g.label .. '"], "' .. g.key .. '", ' .. g.col .. ', ' .. g.summary .. ', nil, nil,', 1, true) ~= nil,
          g.label .. ": a card keyed " .. g.key .. " in column " .. g.col .. ", printing its summary")
    check(call:find(g.builder, 1, true) ~= nil,
          g.label .. ": pinnable, from its own builder -- it decides how the bar LOOKS")
    local mount = g.builder .. "({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end,"
        .. (g.tick and " hoistToggle = true," or "") .. " })"
    check(block:find(mount, 1, true) ~= nil,
          g.label .. (g.tick and ": mounts the builder as classic does, plus hoistToggle for its header tick"
                              or ": mounts the builder exactly as classic does"))
    return block, call
end

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED CARD HELPER, AND THE POPOUT FURNITURE IS GONE
-- ============================================================
print("-- Health Bar page: the shared card helper")
do
    check(PAGE:find("local classicLayout = DF:IsClassicSettingsLayout()", 1, true) ~= nil,
          "tools: the page asks which layout it is building")
    check(PAGE:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true) ~= nil,
          "tools: ...and takes the shared machinery unconditionally")
    check(PAGE:find("_popoutHolders", 1, true) == nil,
          "tools: the page never manages the popout holders itself")

    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "tools.PopoutContent(", "tools.ClaimKeys(",
                            "tools.WireModifiedTick(", "tools.WireFooter(",
                            "tools.RegisterHoistedToggle(", "healthBand", "missingBand", "reducedBand",
                            "_COUNT = ", "footerStrip", "inline = true", "popout = true,",
                            "tools.INLINE_BOX", "OnReducedMaxToggle",
                            "ApplyHealthColor", "ApplyHealthTexture", "ApplyHealthBackground",
                            "ApplyMissingHealth", "ApplyReducedMaxHealth" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end
    check(PAGE:find("count%s*=%s*[%w_]") == nil, "counts: no card declares a settings count")

    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: every card goes through the shared helper, two per row with quiet captions")
    check(PAGE:find("local function CloseSection(band)\n            tools.CloseSection(Add, band)\n        end", 1, true) ~= nil,
          "sections: ...and closes through the shared helper too")
    -- ⚠ ABOVE the gradient builder, which opens its card through it.
    local openAt = PAGE:find("local function OpenSection(label", 1, true)
    local gradAt = PAGE:find("local function BuildGradientStopBox(prefix, hideOn)", 1, true)
    check(openAt and gradAt and openAt < gradAt,
          "sections: the helper is declared above the gradient builder that closes over it")

    local n = 0
    for _ in PAGE:gmatch('Add%(tools%.SectionControls%(self%.child%), 24, "both"%)') do n = n + 1 end
    eq(n, 1, "bulk: the page adds the Expand/Collapse pair once, spanning both columns")
    local stripAt = PAGE:find("tools.SectionControls", 1, true)
    local firstCard = PAGE:find('OpenSection(L["Color"]', 1, true)
    check(stripAt and firstCard and stripAt < firstCard, "bulk: ...above the first card")
end

-- ============================================================
-- 2. THE DROPDOWN VOCABULARY MOVED TO PAGE SCOPE
-- The rows print the chosen value as their SUMMARY, and a summary is written
-- outside the group's builder -- so the word has to come out of the same table
-- the dropdown offers, or a row could say one thing while the control behind it
-- says another.
-- ============================================================
print("-- Health Bar page: the dropdown vocabulary at page scope")
do
    local VOCAB = {
        { "colorModes",             'PERCENT= L["Health Gradient"]' },
        { "orientOptions",          'HORIZONTAL= L["Left to Right"]' },
        { "bgModes",                'CUSTOM= L["Custom Color"]' },
        { "bgFillModes",            'BACKGROUND= L["Background Only"]' },
        { "missingHealthColorModes",'PERCENT= L["Health Gradient"]' },
        { "reducedBlendOpts",       'BLEND = L["Blend"]' },
    }
    for _, pair in ipairs(VOCAB) do
        local decls = 0
        for _ in PAGE:gmatch("local " .. pair[1] .. " = {") do decls = decls + 1 end
        eq(decls, 1, "vocab: " .. pair[1] .. " is declared exactly once")
        -- ...and ABOVE every builder, so a closure sees the real table rather
        -- than the nil upvalue a later declaration would leave it.
        local at = PAGE:find("local " .. pair[1] .. " = {", 1, true)
        local firstBuilder = PAGE:find("local function BuildHealthColorGroup(tools2)", 1, true)
        check(at ~= nil and firstBuilder ~= nil and at < firstBuilder,
              "vocab: ..." .. pair[1] .. " is declared above the first builder")
        local decl = PAGE:match("local " .. pair[1] .. " = {(.-)}")
        check(decl ~= nil and decl:find(pair[2], 1, true) ~= nil,
              "vocab: ..." .. pair[1] .. " still offers " .. pair[2])
    end

    -- The texture resolver, shared by three of the five summaries: the addon's
    -- own media display-name function, which is the one the texture dropdown
    -- prints on its own button -- so a row and the control behind it cannot
    -- disagree about what the texture is called.
    check(PAGE:find("local function TextureName(path)", 1, true) ~= nil,
          "vocab: the texture-name resolver is a named page-scope helper")
    check(PAGE:find("DF:GetTextureNameFromPath(path)", 1, true) ~= nil,
          "vocab: ...and it is the addon's own resolver, not a path split")
end

-- ============================================================
-- 3. THE MODE DROPDOWNS -- the page's own RefreshStates, routed
-- Picking a colour mode re-gates controls inside the group AND the gradient
-- editor that stays out on the page. Classic paid for that with
-- self:RefreshStates() -- NOT GUI:RefreshCurrentPage, so there is no rebuild to
-- unpick -- and tools2.refreshStates IS that call in classic, while in a pane it
-- is ReflowPane plus the page's own pass. One call, both jobs.
-- ============================================================
print("-- Health Bar page: the mode dropdowns route through the tools")
do
    local BUILDERS = { "BuildHealthColorGroup", "BuildHealthTextureGroup",
                       "BuildHealthBackgroundGroup", "BuildMissingHealthGroup",
                       "BuildReducedMaxHealthGroup" }
    for _, b in ipairs(BUILDERS) do
        local body = builderBody(b)
        check(body:find("GUI:RefreshCurrentPage", 1, true) == nil,
              "gate: " .. b .. " never rebuilds the page from inside itself")
        check(body:find("self:RefreshStates", 1, true) == nil,
              "gate: ..." .. b .. " never calls the PAGE's RefreshStates from inside a pane")
    end

    -- Four gates in all: the health colour mode, the background colour mode,
    -- the background fill and the missing-health colour mode. Plus the enable
    -- tick's own, which only the classic arm ever builds.
    local routed = 0
    for _ in PAGE:gmatch("tools2%.refreshStates%(%)") do routed = routed + 1 end
    eq(routed, 5, "gate: five callbacks route their state pass through the tools")

end

-- ============================================================
-- 4. THE FOUR CARDS WITH NO TICK
-- None of these groups has a boolean meaning "am I doing anything at all":
-- Color, Texture and Background are always in play, and Missing Health is gated
-- by a three-way PICK rather than a tick.
-- ============================================================
local HEALTH_COLOR = {
    { "dropdown",    "Color Mode",          "healthColorMode", 55 },
    { "slider",      "Health Bar Alpha",    "classColorAlpha", 55 },
    { "colorpicker", "Custom Health Color", "healthColor",     35 },
}
local HEALTH_TEXTURE = {
    { "texturedropdown", "Texture",              "healthTexture",     55 },
    { "dropdown",        "Fill Direction",       "healthOrientation", 55 },
    { "checkbox",        "Smooth Bar Animation", "smoothBars",        30 },
}
local HEALTH_BACKGROUND = {
    { "dropdown",        "Background Mode",    "backgroundColorMode",  55 },
    { "texturedropdown", "Background Texture", "backgroundTexture",    55 },
    { "colorpicker",     "Background Color",   "backgroundColor",      35 },
    { "slider",          "Background Alpha",   "backgroundClassAlpha", 55 },
}
local MISSING_HEALTH = {
    { "dropdown",        "Background Fill",        "backgroundMode",             55 },
    { "texturedropdown", "Missing Health Texture", "missingHealthTexture",       55 },
    { "dropdown",        "Color Mode",             "missingHealthColorMode",     55 },
    { "colorpicker",     "Missing Health Color",   "missingHealthColor",         35 },
    { "slider",          "Class Color Alpha",      "missingHealthClassAlpha",    55 },
    { "slider",          "Gradient Color Alpha",   "missingHealthGradientAlpha", 55 },
}

local PLAIN = {
    { builder = "BuildHealthColorGroup", label = "Color", boxHeader = "Color",
      box = "colorGroup", column = "1", golden = HEALTH_COLOR,
      key = "health_color", col = 1, summary = "HealthColorSummary" },
    { builder = "BuildHealthTextureGroup", label = "Texture", boxHeader = "Texture",
      box = "textureGroup", column = "2", golden = HEALTH_TEXTURE,
      key = "health_texture", col = 2, summary = "HealthTextureSummary" },
    { builder = "BuildHealthBackgroundGroup", label = "Background", boxHeader = "Background",
      box = "bgGroup", column = "2", golden = HEALTH_BACKGROUND,
      key = "health_background", col = 2, summary = "HealthBackgroundSummary" },
    { builder = "BuildMissingHealthGroup", label = "Missing Health", boxHeader = "Settings",
      box = "missingGroup", column = "1", golden = MISSING_HEALTH,
      key = "health_missing", col = 1, summary = "MissingHealthSummary" },
}

for _, g in ipairs(PLAIN) do
    print("-- Health Bar page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())
    local _, call = checkShared(g)

    check(body:find("hoistToggle", 1, true) == nil,
          g.label .. ": the builder has no hoist branch, because there is nothing to hoist")
    check(body:find("disableChildrenOn", 1, true) == nil,
          g.label .. ": ...and no group gate either")
    check(call:find('key = "', 1, true) == nil, g.label .. ": no header tick")
end

-- ============================================================
-- 5. REDUCED MAX HEALTH -- the page's one header tick
-- keepEnabled + disableChildrenOn in classic, which is the shape of "am I doing
-- anything at all". The card's header carries the tick; the builder skips the
-- checkbox (hoistToggle), so there is one checkbox per setting.
-- ============================================================
local REDUCED_MAX = {
    { "checkbox",        "Enable",          "reducedMaxHealthEnabled",       30 },
    { "checkbox",        "Clip Health Bar", "reducedMaxHealthClipHealthBar", 30 },
    { "texturedropdown", "Texture",         "reducedMaxHealthTexture",       55 },
    { "colorpicker",     "Bar Color",       "reducedMaxHealthColor",         35 },
    { "dropdown",        "Blend Mode",      "reducedMaxHealthBlendMode",     55 },
}

print("-- Health Bar page: Reduced Max Health")
do
    local g = { builder = "BuildReducedMaxHealthGroup", label = "Reduced Max Health",
                boxHeader = "Settings", box = "reducedGroup", column = "1",
                key = "health_reduced", col = 2, summary = "ReducedMaxHealthSummary", tick = true }
    local body = builderBody(g.builder)
    checkCensus(census(body), REDUCED_MAX, "reduced max health")
    local _, call = checkShared(g)

    local guard = body:find("if not tools2.hoistToggle then", 1, true)
    local cb = body:find('GUI:CreateCheckbox(parent, L["Enable"], db, "reducedMaxHealthEnabled"', guard or 1, true)
    check(guard ~= nil and cb ~= nil and cb > guard,
          "reduced max health: the builder builds the enable only when not hoisted")
    check(body:find(".keepEnabled = true", 1, true) ~= nil,
          "reduced max health: ...and in classic it stays live under the group's own grey")
    check(body:find("group.disableChildrenOn = function(d) return not d.reducedMaxHealthEnabled end", 1, true) ~= nil,
          "reduced max health: the group's grey-while-off gate is inside the builder")

    check(call:find('db = db, key = "reducedMaxHealthEnabled", label = L["Enable"]', 1, true) ~= nil,
          "reduced max health: the header tick is bound to the group's own enable key, under its own label")
    check(call:find("onChanged = function()", 1, true) ~= nil
      and call:find("DF:UpdateAllFrames()", 1, true) ~= nil
      and call:find("self:RefreshStates()", 1, true) ~= nil
      and call:find("tools.ReflowMounted()", 1, true) ~= nil
      and call:find("RefreshCurrentPage", 1, true) == nil,
          "reduced max health: ...committing what the checkbox ran plus a state pass, never a page rebuild")
    local hoists = 0
    for _ in PAGE:gmatch("hoistToggle = true,") do hoists = hoists + 1 end
    eq(hoists, 1, "reduced max health: the only mount on the page that skips its in-body toggle")
end

-- ============================================================
-- 6. THE SECTIONS ARE CLASSIC'S, AND THE CARDS FOLLOW CLASSIC'S ORDER
-- ============================================================
print("-- Health Bar page: the collapsible sections and the Add order")
do
    -- ---- all three are classic's only, through an expression ------------
    for _, s in ipairs({
        { "healthBarSection", "Health Bar" },
        { "missingSection",   "Missing Health" },
        { "reducedSection",   "Reduced Max Health" },
    }) do
        check(PAGE:find("local " .. s[1] .. ' = classicLayout\n            and Add(GUI:CreateCollapsibleSection(self.child, L["' .. s[2] .. '"], true), 36, "both")\n            or nil', 1, true) ~= nil,
              "sections: " .. s[2] .. " is still classic's collapsible section, and never built in modern")
    end
    local spacers = 0
    for _ in PAGE:gmatch('if classicLayout then AddSpace%(GUI%.Space%.section, "both"%) end') do spacers = spacers + 1 end
    eq(spacers, 2, "page: the two between-section spacers survive, in classic only")
    local bare = 0
    for _ in PAGE:gmatch('AddSpace%(GUI%.Space%.section, "both"%)') do bare = bare + 1 end
    eq(bare, 2, "page: ...and there is no other copy of them")

    -- ---- the classic Add order is unchanged -----------------------------
    local classicArm = PAGE:match("if classicLayout then(.-)\n        else")
    check(classicArm ~= nil, "order: the Health Bar section's classic arm is locatable")
    if classicArm then
        local a = classicArm:find("AddToSection(colorGroup, nil, 1)", 1, true)
        local b = classicArm:find("AddToSection(textureGroup, nil, 2)", 1, true)
        local c = classicArm:find('BuildGradientStopBox("healthColor"', 1, true)
        local d = classicArm:find("AddToSection(bgGroup, nil, 2)", 1, true)
        check(a and b and c and d and a < b and b < c and c < d,
              "order: classic still adds Color, Texture, the gradient editor, then Background")
    end

    -- ---- the cards open in the same order -- the one-column fold's --------
    local order = {}
    for at, name in PAGE:gmatch('()OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "), "Gradient | Color | Texture | Background | Missing Health | Reduced Max Health",
       "order: the gradient builder's card (declared once) and the five boxes' cards, in source order")
    local function at(needle) return PAGE:find(needle, 1, true) end
    local seq = { 'OpenSection(L["Color"]', 'OpenSection(L["Texture"]', 'BuildGradientStopBox("healthColor", HealthGradientHiddenOn)\n\n            local band = OpenSection(L["Background"]',
                  'OpenSection(L["Missing Health"]', 'BuildGradientStopBox("missingHealthColor", MissingGradientHiddenOn)\n        end',
                  'OpenSection(L["Reduced Max Health"]' }
    local prev = 0
    for _, n in ipairs(seq) do
        local p = PAGE:find(n, prev + 1, true)
        check(p ~= nil and p > prev, "order: modern adds " .. n:match("^[^\n]+") .. " next")
        prev = p or prev
    end

    -- ---- the page's own furniture is untouched --------------------------
    check(PAGE:find('Add(GUI:CreateSeeAlso(self.child, {', 1, true) ~= nil,
          "page: the See Also block survives")
    check(PAGE:find('{pageId = "general_frame", label = L["Frame"]}', 1, true) ~= nil,
          "page: ...with the links it always had")
    local spacers = 0
    for _ in PAGE:gmatch('AddSpace%(GUI%.Space%.section, "both"%)') do spacers = spacers + 1 end
    eq(spacers, 2, "page: the two between-section spacers survive")
end

-- ============================================================
-- 7. THE TWO GRADIENT EDITORS ARE CARDS -- WITHOUT A PIN
-- ☠ Structural, not taste: GradRebuild ends in pageHealthBar:Refresh(), a full
-- PAGE REBUILD, and it has to -- adding a stop, removing one and committing a
-- threshold each change which WIDGETS the editor has. A pinned copy of the
-- editor would be closed by the rebuild its own + click caused.
-- ============================================================
print("-- Health Bar page: the two gradient editor cards")
do
    check(PAGE:find("local function BuildGradientStopBox(prefix, hideOn)", 1, true) ~= nil,
          "gradient: the one builder still serves both ramps")
    check(PAGE:find("if pageHealthBar and pageHealthBar.Refresh then pageHealthBar:Refresh() end", 1, true) ~= nil,
          "gradient: ...and it still rebuilds the PAGE on a structural edit, which is why it has no pin")

    -- The box: classic's bare 280, modern's card in column 1 under a stable key
    -- per ramp, hidden with its colour mode -- and no pin (no builder argument).
    check(PAGE:find("local gradGroup = classicLayout\n            and GUI:CreateSettingsGroup(self.child, 280)\n            or OpenSection(L[\"Gradient\"], (prefix == \"healthColor\") and \"health_gradient\" or \"health_missinggradient\",\n                1, nil, nil, hideOn)", 1, true) ~= nil,
          "gradient: classic's 280 box, or a card keyed per ramp in column 1, hidden with its mode, with no pin")
    check(PAGE:find('if classicLayout then gradGroup:AddWidget(GUI:CreateHeader(self.child, L["Gradient"]), 40) end', 1, true) ~= nil,
          "gradient: ...only classic's box takes a header -- the card's title already says Gradient")
    check(PAGE:find("if classicLayout then AddToSection(gradGroup, nil, 1) else CloseSection(gradGroup) end", 1, true) ~= nil,
          "gradient: ...column 1 in classic, the card's own band close in modern")
    check(PAGE:find("local function BuildGradientStopBox(prefix, hideOn)\n        local listKey", 1, true) ~= nil,
          "gradient: ...and the builder still opens on its one local")
    check(PAGE:find("bandStyle", 1, true) == nil,
          "gradient: no band skin is restated as a literal")

    -- Its hideOn is named once per ramp and handed to both layout arms, so the
    -- two cannot drift.
    check(PAGE:find("local function HealthGradientHiddenOn(d) return d.healthColorMode ~= \"PERCENT\" end", 1, true) ~= nil,
          "gradient: the health ramp's visibility rule is named once")
    check(PAGE:find("local function MissingGradientHiddenOn(d)", 1, true) ~= nil,
          "gradient: ...and so is the missing-health ramp's")
    local health, missing = 0, 0
    for _ in PAGE:gmatch('BuildGradientStopBox%("healthColor", HealthGradientHiddenOn%)') do health = health + 1 end
    for _ in PAGE:gmatch('BuildGradientStopBox%("missingHealthColor", MissingGradientHiddenOn%)') do missing = missing + 1 end
    eq(health, 2, "gradient: the health ramp is built once per layout arm")
    eq(missing, 2, "gradient: ...and so is the missing-health ramp")

    -- ---- six bare 280 boxes left, and they are the classic branch's own ----
    -- Five section boxes plus the gradient editor's own classic width.
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 6, "boxes: six bare 280 boxes left -- the classic arms' own")
    -- ☠ THE ALIGNMENT RULE, ON THIS PAGE: no box is mounted at a column's 280 with
    -- the tools in hand. A 280 box only ever appears with NO opts, which is the
    -- classic arm's signature.
    local narrow = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280, tools") do narrow = narrow + 1 end
    eq(narrow, 0, "boxes: ...and none of them is a new-UI mount at 280")
end

-- ============================================================
-- 8. ZERO NEW LOCALE STRINGS
-- Every label, band word and summary word on this page already shipped. The
-- summaries reuse the dropdowns' own vocabulary, which is the whole reason those
-- tables moved to page scope.
-- ============================================================
print("-- Health Bar page: every locale string the page asks for already ships")
do
    local ENUS = options_file_source("../DandersFrames/Locales/enUS.lua")
    local seen = {}
    for key in PAGE:gmatch('L%["([^"]+)"%]') do seen[key] = true end
    local missing = 0
    for key in pairs(seen) do
        -- The escapes in a Lua source string are literal here (the locale file
        -- writes them the same way), so a plain find is the right comparison.
        if not ENUS:find('L["' .. key .. '"] = true', 1, true) then
            missing = missing + 1
            check(false, "locale: enUS ships L[\"" .. key .. "\"]")
        end
    end
    eq(missing, 0, "locale: the page adds no new string")
end
