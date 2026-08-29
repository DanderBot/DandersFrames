local NS = ...

-- ============================================================
-- HEALTH BAR PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Auras.lua
-- ------------------------------------------------------------
-- Bars > Health Bar is the first page in the sweep with a SECOND LEVEL: three
-- collapsible sections over seven boxes. Five of those boxes become feature
-- rows, in one headerless band per section, and the two gradient stop editors
-- stay inline wearing the band skin.
--
--   "Health Bar"          Color, Texture, Background   + the health ramp inline
--   "Missing Health"      Missing Health               + its own ramp inline
--   "Reduced Max Health"  Reduced Max Health (hoisted enable)
--
-- ☠ THREE RULES MAKE THIS PAGE DIFFERENT FROM ITS SIBLINGS:
--
--   1. THE COLLAPSIBLE SECTIONS SURVIVE IN BOTH LAYOUTS. A section collapses
--      and persists that fold per title in SavedVariables; a band does neither.
--      They are also what folds the two inline gradient editors away with the
--      feature they belong to. Section 6 pins that they are still built
--      unconditionally and that the bands go in THROUGH them (AddToSection), so
--      a later "tidy" that swaps them for band headers breaks a test instead of
--      silently dropping the fold.
--   2. THE BANDS CARRY NO HEADER -- the section bar above each one already
--      names it (the Fading page's sortBand rule).
--   3. THE GRADIENT EDITORS STAY INLINE, for the reason Color by Time does:
--      every structural edit ends in a full page Refresh, which inside a pane
--      retires the pane and closes the panel it was clicked in. Section 7 pins
--      that they are still inline, still called once per layout arm, and that
--      they now wear tools.INLINE_BOX.
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
--   ✓ that ONE builder serves both layouts.
--   ✓ that each declared row COUNT matches what its pane mounts, less the one
--     hoisted toggle.
--   ✓ that the four mode dropdowns stopped calling the PAGE's RefreshStates
--     from inside a pane and route through tools2.refreshStates instead.
--   ✓ that every summary reads its words out of the dropdown table the control
--     itself offers, and that the page adds NO new locale string.
--   ✗ nothing about runtime behaviour -- the callbacks, the greying and the
--     summaries are read by eye and by the in-game checklist.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Auras.lua")

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

-- The block a row is declared in, from its label to the closing brace of the
-- CreatePopoutRow opts.
local function rowOpts(labelKey)
    local a = PAGE:find('label%s*=%s*L%["' .. labelKey .. '"%]')
    check(a ~= nil, "source: a popout row is declared for " .. labelKey)
    if not a then return "" end
    local b = PAGE:find("}))", a, true)
    return PAGE:sub(a, (b or a) + 2)
end

-- What every converted group on this page has in common. `boxHeader` is passed
-- separately from `rowLabel` because two of the five rows do NOT take their
-- classic box's header: both of those boxes are headed "Settings", and two rows
-- called "Settings" would break the breadcrumb jump, which finds a row BY LABEL.
local function checkShared(g)
    -- ONE builder, BOTH layouts: the declaration and the two mounts.
    local calls = 0
    for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, g.label .. ": declared once, mounted twice -- classic box and popout pane")

    -- The classic branch builds the box it always did, with its own header, in
    -- the column it always had -- and through AddToSection, so it is still a
    -- child of its collapsible section.
    check(PAGE:find("local " .. g.box .. " = GUI:CreateSettingsGroup(self.child, 280)", 1, true) ~= nil,
          g.label .. ": the classic 280 box is built")
    check(PAGE:find(g.box .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. g.boxHeader .. '"]), 40)', 1, true) ~= nil,
          g.label .. ": ...under the header it always had (" .. g.boxHeader .. ")")
    check(PAGE:find("AddToSection(" .. g.box .. ", nil, " .. g.column .. ")", 1, true) ~= nil,
          g.label .. ": ...and still goes to column " .. g.column .. ", inside its section")

    local opts = rowOpts(g.label)
    check(opts ~= "" and opts:find("build", 1, true) ~= nil,
          g.label .. ": the row is handed a pre-built mount")
    check(opts:find("window", 1, true) ~= nil,
          g.label .. ": ...docked outside the settings window")
    check(opts:find("clipTo", 1, true) ~= nil,
          g.label .. ": ...and clipped by the page's own scroll frame, not the window")
    check(opts:find("count%s*=%s*" .. g.countVar) ~= nil,
          g.label .. ": ...and the declared count, not a literal")
    check(opts:find("summary%s*=%s*" .. g.summary) ~= nil,
          g.label .. ": ...with the summary written for it")

    -- ...into the right band.
    check(PAGE:find("local " .. g.row .. " = " .. g.band .. ":AddWidget(GUI:CreatePopoutRow(", 1, true) ~= nil,
          g.label .. ": the row is mounted into the " .. g.band)

    -- The strip. EVERY key on this page is a per-mode profile key living in
    -- DF.PartyDefaults, which is exactly what the defaults engine answers for --
    -- so every row gets the amber tick and the Reset Group / Hold: Defaults
    -- footer, and every footer is handed the group's own apply.
    check(PAGE:find("tools.ClaimKeys(" .. g.row .. ", ", 1, true) ~= nil,
          g.label .. ": the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(" .. g.row .. ")", 1, true) ~= nil,
          g.label .. ": ...its amber tick asks about exactly those keys")
    check(PAGE:find("tools.WireFooter(" .. g.row .. ", " .. g.apply .. ")", 1, true) ~= nil,
          g.label .. ": ...and its footer runs the group's own apply")
end

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED MACHINERY, AND ITS THREE BANDS ARE HEADERLESS
-- ============================================================
print("-- Health Bar page: the shared popout machinery and the three bands")
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
    check(PAGE:find("_popoutHolders", 1, true) == nil,
          "tools: the page never manages the popout holders itself")
    check(PAGE:find("_popoutRowForKey", 1, true) == nil,
          "tools: ...nor the search row map")

    -- ---- three bands, one per section, all chromeless ------------------
    for _, b in ipairs({ "healthBand", "missingBand", "reducedBand" }) do
        check(PAGE:find(b .. "  = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil
           or PAGE:find(b .. " = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
              "bands: " .. b .. " is chromeless, at the width the layout pass will give it")
    end

    -- ☠ AND NOT ONE OF THEM CARRIES A HEADER. The collapsible section bar
    -- directly above each band already names it; a header under it would say the
    -- same word twice. (The Fading page's sortBand rule.)
    for _, b in ipairs({ "healthBand", "missingBand", "reducedBand" }) do
        check(PAGE:find(b .. ":AddWidget(GUI:CreateHeader(", 1, true) == nil,
              "bands: ..." .. b .. " carries no header of its own")
    end
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

    -- Every popout mount declares itself as one.
    local popouts = 0
    for _ in PAGE:gmatch("popout = true,") do popouts = popouts + 1 end
    eq(popouts, 5, "gate: all five popout mounts declare themselves as panes")
end

-- ============================================================
-- 4. THE FOUR ROWS WITH NO TICK
-- None of these groups has a boolean meaning "am I doing anything at all":
-- Color, Texture and Background are always in play, and Missing Health is gated
-- by a three-way PICK rather than a tick. So each is a way in and nothing else.
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
      countVar = "HEALTH_COLOR_COUNT", row = "colorRow", band = "healthBand",
      summary = "HealthColorSummary", apply = "ApplyHealthColor" },
    { builder = "BuildHealthTextureGroup", label = "Texture", boxHeader = "Texture",
      box = "textureGroup", column = "2", golden = HEALTH_TEXTURE,
      countVar = "HEALTH_TEXTURE_COUNT", row = "textureRow", band = "healthBand",
      summary = "HealthTextureSummary", apply = "ApplyHealthTexture" },
    { builder = "BuildHealthBackgroundGroup", label = "Background", boxHeader = "Background",
      box = "bgGroup", column = "2", golden = HEALTH_BACKGROUND,
      countVar = "HEALTH_BACKGROUND_COUNT", row = "bgRow", band = "healthBand",
      summary = "HealthBackgroundSummary", apply = "ApplyHealthBackground" },
    { builder = "BuildMissingHealthGroup", label = "Missing Health", boxHeader = "Settings",
      box = "missingGroup", column = "1", golden = MISSING_HEALTH,
      countVar = "MISSING_HEALTH_COUNT", row = "missingRow", band = "missingBand",
      summary = "MissingHealthSummary", apply = "ApplyMissingHealth" },
}

for _, g in ipairs(PLAIN) do
    print("-- Health Bar page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())
    checkShared(g)

    -- No hoist and no group gate: there is no key here that gates the others.
    check(body:find("hoistToggle", 1, true) == nil,
          g.label .. ": the builder has no hoist branch, because there is nothing to hoist")
    check(body:find("disableChildrenOn", 1, true) == nil,
          g.label .. ": ...and no group gate either")

    local declared = tonumber(PAGE:match("local " .. g.countVar .. "%s*=%s*(%d+)"))
    check(declared ~= nil, g.label .. ": the page declares the row's count in one place")
    eq(declared, #g.golden, g.label .. ": ...the whole census, nothing hoisted out of it")

    local opts = rowOpts(g.label)
    check(opts:find("toggle", 1, true) == nil,
          g.label .. ": the row declares no toggle")
    check(opts:find("onToggle", 1, true) == nil,
          g.label .. ": ...and so no commit either")
end

-- ============================================================
-- 5. REDUCED MAX HEALTH -- the page's one hoisted enable
-- keepEnabled + disableChildrenOn in classic, which is the shape of "am I doing
-- anything at all". The row carries the tick; the builder skips the checkbox.
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
                countVar = "REDUCED_MAX_HEALTH_COUNT", row = "reducedRow",
                band = "reducedBand", summary = "ReducedMaxHealthSummary",
                apply = "ApplyReducedMaxHealth" }
    local body = builderBody(g.builder)
    checkCensus(census(body), REDUCED_MAX, "reduced max health")
    checkShared(g)

    -- The hoist, and the arithmetic it implies: the checkbox is still IN the
    -- builder -- classic needs it -- behind the one flag the popout passes.
    check(body:find("if not tools2.hoistToggle then", 1, true) ~= nil,
          "reduced max health: the enable checkbox is skipped when the row has hoisted it")
    check(body:find(".keepEnabled = true", 1, true) ~= nil,
          "reduced max health: ...and in classic it stays live under the group's own grey")
    local declared = tonumber(PAGE:match("local REDUCED_MAX_HEALTH_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "reduced max health: the page declares the row's count in one place")
    eq(declared, #REDUCED_MAX - 1, "reduced max health: ...the census less the hoisted tick")

    -- ☠ THE GROUP GATE MOVED INSIDE THE BUILDER. In classic it was a property of
    -- the page-level box; left there, the pane would not grey while the overlay
    -- is off and the two layouts would disagree.
    check(body:find("group.disableChildrenOn = function(d) return not d.reducedMaxHealthEnabled end", 1, true) ~= nil,
          "reduced max health: the group's grey-while-off gate is inside the builder")

    local opts = rowOpts("Reduced Max Health")
    check(opts:find('toggle%s*=%s*{%s*key%s*=%s*"reducedMaxHealthEnabled"%s*}') ~= nil,
          "reduced max health: the row's tick is the group's own enable key")
    check(opts:find("onToggle%s*=%s*OnReducedMaxToggle") ~= nil,
          "reduced max health: ...and a commit that is not a page rebuild")

    -- ☠ THE COMMIT IS NOT A PAGE REBUILD: a rebuild retires every widget on the
    -- page including the row being clicked, and the row's write path calls
    -- row.Refresh() after this returns, on a dead frame.
    local commit = PAGE:match("local function OnReducedMaxToggle%(%)(.-)\n            end")
    check(commit ~= nil, "reduced max health: the popout commit is a named function")
    if commit then
        check(commit:find("RefreshCurrentPage", 1, true) == nil,
              "reduced max health: ...and never rebuilds the page")
        check(commit:find("DF:UpdateAllFrames()", 1, true) ~= nil,
              "reduced max health: ...it runs what the suppressed checkbox ran")
        check(commit:find("self:RefreshStates()", 1, true) ~= nil,
              "reduced max health: ...re-runs the state passes")
        check(commit:find("tools.ReflowMounted()", 1, true) ~= nil,
              "reduced max health: ...and reflows the open panes")
    end

    -- The hoisted toggle keeps its search entry under the SAME label and key the
    -- suppressed checkbox carried, or the setting becomes unfindable in the
    -- popout layout while staying findable in classic.
    check(PAGE:find('tools.RegisterHoistedToggle(reducedRow, L["Enable"], "reducedMaxHealthEnabled", OnReducedMaxToggle)', 1, true) ~= nil,
          "reduced max health: the hoisted toggle keeps its search entry")
end

-- ============================================================
-- 6. THE SECTIONS SURVIVE, AND THE BANDS GO IN THROUGH THEM
-- ============================================================
print("-- Health Bar page: the collapsible sections and the Add order")
do
    -- ---- all three, built unconditionally, exactly as they always were ----
    for _, s in ipairs({
        { "healthBarSection", "Health Bar" },
        { "missingSection",   "Missing Health" },
        { "reducedSection",   "Reduced Max Health" },
    }) do
        check(PAGE:find("local " .. s[1] .. ' = Add(GUI:CreateCollapsibleSection(self.child, L["' .. s[2] .. '"], true), 36, "both")', 1, true) ~= nil,
              "sections: " .. s[2] .. " is still a collapsible section, in both layouts")
    end
    -- ...and not one of them is behind a layout branch.
    check(PAGE:find("if classicLayout then\n            local healthBarSection", 1, true) == nil,
          "sections: ...none of them is built only for classic")

    -- ---- the bands go in THROUGH the section, so a fold hides them ------
    for _, b in ipairs({ "healthBand", "missingBand", "reducedBand" }) do
        check(PAGE:find('AddToSection(' .. b .. ', nil, "both")', 1, true) ~= nil,
              "sections: " .. b .. " is registered to its section, so folding hides its rows")
        check(PAGE:find('Add(' .. b .. ', nil, "both")', 1, true) == nil,
              "sections: ..." .. b .. " never bypasses the section with a bare Add")
    end

    -- ---- the classic Add order is unchanged -----------------------------
    -- ☠ Color (1), Texture (2), the gradient editor (1), Background (2). The
    -- gradient sits BETWEEN the two column-2 boxes, which is why this page mounts
    -- a whole section per if/else rather than one arm per group: a band is a
    -- "both" widget and therefore a sync point, so it cannot be interleaved.
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

    -- ---- and the popout arm puts the full band in before the editor -----
    local popoutArm = PAGE:match("\n        else\n(.-)\n        end\n\n        currentSection = nil\n        AddSpace")
    check(popoutArm ~= nil, "order: the Health Bar section's popout arm is locatable")
    if popoutArm then
        local band = popoutArm:find('AddToSection(healthBand, nil, "both")', 1, true)
        local grad = popoutArm:find('BuildGradientStopBox("healthColor"', 1, true)
        local lastRow = popoutArm:find("local bgRow = healthBand:AddWidget", 1, true)
        check(lastRow and band and lastRow < band,
              "order: the band goes in after its last row, because Add resolves slot height on the spot")
        check(band and grad and band < grad,
              "order: ...and before the column-1 gradient editor, because \"both\" is a sync point")
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
-- 7. THE TWO GRADIENT EDITORS STAY BOXES -- FULL-WIDTH ONES
-- ☠ Structural, not taste: GradRebuild ends in pageHealthBar:Refresh(), a full
-- PAGE REBUILD, and it has to -- adding a stop, removing one and committing a
-- threshold each change which WIDGETS the editor has. Inside a pane a rebuild
-- retires the pane, and CreatePopoutPageTools' prologue closes every open panel
-- on the way in, so the editor would slam its own panel shut on each + click.
-- (Colors page, Color by Time: the same refusal for the same reason.)
-- ============================================================
print("-- Health Bar page: the two full-width gradient editors")
do
    check(PAGE:find("local function BuildGradientStopBox(prefix, hideOn)", 1, true) ~= nil,
          "gradient: the one builder still serves both ramps")
    check(PAGE:find("if pageHealthBar and pageHealthBar.Refresh then pageHealthBar:Refresh() end", 1, true) ~= nil,
          "gradient: ...and it still rebuilds the PAGE on a structural edit, which is why it is not a row")

    -- Neither ramp gets a row.
    check(PAGE:find('label%s*=%s*L%["Gradient"%]') == nil,
          "gradient: no popout row is declared for either ramp")

    -- ⚠ IT DOES WEAR THE BAND SKIN, unlike Color by Time -- and the difference is
    -- what each of them IS: Color by Time is a CollapsibleSection, which the skin
    -- does not apply to, while this is an ordinary settings box with a header.
    --
    -- ☠ AND IN THE POPOUT LAYOUT IT IS FULL WIDTH. The skin settles the BORDER and
    -- never the EDGE: a skinned 280 box under a full-width band still starts and
    -- ends somewhere nothing else on the page does. So the popout arm builds it at
    -- the band's width, and classic keeps the bare 280 box it always built.
    check(PAGE:find("local gradGroup = classicLayout", 1, true) ~= nil,
          "gradient: the editor's box picks its width from the layout")
    check(PAGE:find("and GUI:CreateSettingsGroup(self.child, 280)", 1, true) ~= nil,
          "gradient: ...the bare 280 box in classic")
    check(PAGE:find("or GUI:CreateSettingsGroup(self.child, tools.BandWidth(), tools.INLINE_BOX)", 1, true) ~= nil,
          "gradient: ...and the band's width, wearing the band skin, in the popout layout")
    -- ⚠ AN EXPRESSION, NOT A SECOND `if classicLayout then` ARM at the page
    -- builder's indent: this builder is declared above the section's own arms, and
    -- an arm here is the one their locators would find first.
    check(PAGE:find("local function BuildGradientStopBox(prefix, hideOn)\n        local listKey", 1, true) ~= nil,
          "gradient: ...and the builder still opens on its one local")
    -- The Add follows the same fork: column 1 in classic, a sync point here, which
    -- is the whole of "the editor lines up with the bands".
    check(PAGE:find('AddToSection(gradGroup, nil, classicLayout and 1 or "both")', 1, true) ~= nil,
          "gradient: ...and it is added to column 1 in classic, spanning both here")
    -- ⚠ THE FLAG IS NEVER WRITTEN AS A LITERAL. One shared table off the tools,
    -- so classic gets nil -- which is what "no opts" already meant.
    check(PAGE:find("bandStyle", 1, true) == nil,
          "gradient: the skin is taken from the tools, never restated as a literal")

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
    -- Five section boxes plus the gradient editor's own classic width, which is
    -- now written out rather than shared with the popout arm.
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
