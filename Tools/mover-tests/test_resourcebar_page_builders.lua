local NS = ...

-- ============================================================
-- RESOURCE BAR PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Auras.lua
-- ------------------------------------------------------------
-- Bars > Resource Bar is nine 280 boxes in classic. EIGHT of them become feature
-- rows across three HEADED bands, and the ninth -- Frame Level, one slider --
-- becomes a CONTROL ROW in a headerless band of its own:
--
--   "General"   Resource Bar Settings (hoisted enable), Class Filter
--   "Layout"    Size, Position
--                  ...then the Frame Level control row, in its own band
--   "Style"     Appearance, Background, Border (hoisted Show Border),
--               Resource Colors
--
-- ☠ FIVE RULES MAKE THIS PAGE DIFFERENT FROM ITS SIBLINGS:
--
--   1. IT IS THE SECOND PAGE WITH A PAGE-WIDE GATE. Every group greys behind
--      resourceBarEnabled, so the rows grey too (ResourceOffRow) and every gated
--      pane needs GatePaneFirstChild -- the Pet Frames answer to the kit's
--      index-1 skip, which in a headless pane is a control rather than a header.
--      Section 3 pins both halves.
--   2. THE ORIENTATION PICK RE-GATES A DIFFERENT PANE. It renames the two Size
--      controls through their refreshContent hooks, and Size is a row of its own
--      -- so the callback needs tools.ReflowMounted() on top of the pane's own
--      refresh. Section 4.
--   3. THE CLASS FILTER ROW TAKES THE TICK AND REFUSES THE FOOTER. Its thirteen
--      checkboxes are bound to a SUB-TABLE captured at build time, and a reset
--      writes a table-valued key by REPLACING the table -- which would leave all
--      thirteen reading a detached copy. Section 7.
--   4. THE RESOURCE COLORS ROW IS THE SWEEP'S ONE MIXED ROW: two per-mode
--      profile keys and ten that live at the root of DF.db. Section 8.
--   5. THE THREE BANDS DO CARRY HEADERS (the Health Bar page's do not), because
--      this page has no collapsible sections above them to do the naming -- and
--      not one header repeats a row label. Section 1.
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
--   ✓ that each declared row COUNT matches what its pane mounts, less any
--     hoisted toggle.
--   ✓ that no builder rebuilds the page or calls the PAGE's RefreshStates from
--     inside a pane.
--   ✓ that every summary reads its words out of the table the control itself
--     offers, and that the page adds NO new locale string.
--   ✗ nothing about runtime behaviour -- the callbacks, the greying and the
--     summaries are read by eye and by the in-game checklist.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Auras.lua")

-- ---- the census reader (the Health Bar page's, plus one fallback) ----
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
        -- ⚠ THE FALLBACK IS FOR ONE CONTROL AND IT IS NOT COSMETIC. The Custom
        -- Color picker is built into a LOCAL first -- it needs a hideOn before it
        -- goes in -- and added a line later, so the `), H)` shape every other
        -- control ends in does not appear in its chunk at all. Without this the
        -- reader would report no slot height for it and the golden would have to
        -- carry a hole where a real number belongs.
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

-- The page, scoped by its own two ends: Auras.lua holds a dozen pages, and a
-- bare 280 box on one of the others is not this pass's business.
local PAGE
do
    local a = SRC:find('L["Resource Bar"], "bars_resource")', 1, true)
    local b = SRC:find('local pageAbsorb = CreateSubTab("bars", "bars_absorb"', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Resource Bar page builder is locatable by its own ends")
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

-- What every converted group on this page has in common.
local function checkShared(g)
    -- ONE builder, BOTH layouts: the declaration and the two mounts.
    local calls = 0
    for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, g.label .. ": declared once, mounted twice -- classic box and popout pane")

    -- The classic branch builds the box it always did, with its own header, in
    -- the column it always had.
    check(PAGE:find("local " .. g.box .. " = GUI:CreateSettingsGroup(self.child, 280)", 1, true) ~= nil,
          g.label .. ": the classic 280 box is built")
    check(PAGE:find(g.box .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. g.boxHeader .. '"]), 40)', 1, true) ~= nil,
          g.label .. ": ...under the header it always had (" .. g.boxHeader .. ")")
    check(PAGE:find("Add(" .. g.box .. ", nil, " .. g.column .. ")", 1, true) ~= nil,
          g.label .. ": ...and still goes to column " .. g.column)

    local opts = rowOpts(g.label)
    check(opts ~= "" and opts:find("build", 1, true) ~= nil,
          g.label .. ": the row is handed a pre-built mount")
    check(opts:find("window", 1, true) ~= nil,
          g.label .. ": ...docked outside the settings window")
    check(opts:find("clipTo", 1, true) ~= nil,
          g.label .. ": ...and clipped by the page's own scroll frame, not the window")
    check(opts:find("count%s*=%s*" .. g.countVar) ~= nil,
          g.label .. ": ...and the declared count, not a literal")
    if g.summary then
        check(opts:find("summary%s*=%s*" .. g.summary) ~= nil,
              g.label .. ": ...with the summary written for it")
    else
        check(opts:find("summary", 1, true) == nil,
              g.label .. ": ...and deliberately no summary")
    end

    -- ...into the right band.
    check(PAGE:find("local " .. g.row .. " = " .. g.band .. ":AddWidget(GUI:CreatePopoutRow(", 1, true) ~= nil,
          g.label .. ": the row is mounted into the " .. g.band)

    check(PAGE:find("tools.ClaimKeys(" .. g.row .. ", ", 1, true) ~= nil,
          g.label .. ": the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(" .. g.row .. ")", 1, true) ~= nil,
          g.label .. ": ...its amber tick asks about exactly those keys")
    if g.apply then
        check(PAGE:find("tools.WireFooter(" .. g.row .. ", " .. g.apply .. ")", 1, true) ~= nil,
              g.label .. ": ...and its footer runs the group's own apply")
    else
        check(PAGE:find("tools.WireFooter(" .. g.row, 1, true) == nil,
              g.label .. ": ...and it wires no footer at all")
    end

    -- The page gate reaches the row itself, unless the row IS the gate.
    if g.gated then
        check(PAGE:find(g.row .. ".disableOn = ResourceOffRow", 1, true) ~= nil,
              g.label .. ": the row greys while the resource bar is off")
    else
        check(PAGE:find(g.row .. ".disableOn", 1, true) == nil,
              g.label .. ": the row carrying the page gate never greys itself")
    end
end

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED MACHINERY, AND ITS THREE BANDS ARE HEADED
-- ============================================================
print("-- Resource Bar page: the shared popout machinery and the three bands")
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

    -- ---- three bands, all chromeless, all at the layout pass's own width ----
    for _, b in ipairs({ "generalBand", "layoutBand", "styleBand" }) do
        check(PAGE:find(b .. " = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
              "bands: " .. b .. " is chromeless, at the width the layout pass will give it")
    end

    -- ☠ AND EACH ONE CARRIES A HEADER, unlike the Health Bar page's three: there
    -- is no collapsible section above these to do the naming.
    for _, b in ipairs({ { "generalBand", "General" }, { "layoutBand", "Layout" },
                         { "styleBand", "Style" } }) do
        check(PAGE:find(b[1] .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. b[2] .. '"]), 40)', 1, true) ~= nil,
              "bands: " .. b[1] .. " is headed " .. b[2])
    end

    -- ⚠ NO HEADER REPEATS A ROW LABEL -- the Pet Frames rule. "Appearance" is a
    -- ROW on this page, which is exactly why the band holding it is "Style".
    local ROW_LABELS = { "Resource Bar Settings", "Class Filter", "Size", "Position",
                         "Appearance", "Background", "Border", "Resource Colors" }
    for _, header in ipairs({ "General", "Layout", "Style" }) do
        for _, label in ipairs(ROW_LABELS) do
            check(header ~= label, "bands: the header " .. header .. " is not also a row label")
        end
    end
end

-- ============================================================
-- 2. THE VOCABULARY MOVED TO PAGE SCOPE
-- The rows print the chosen value as their SUMMARY, and a summary is written
-- outside the group's builder -- so the word has to come out of the same table
-- the dropdown offers, or a row could say one thing while the control behind it
-- says another.
-- ============================================================
print("-- Resource Bar page: the vocabulary at page scope")
do
    local VOCAB = {
        { "RB_CLASS_LIST",        'token = "DEATHKNIGHT",  name = L["Death Knight"]' },
        { "anchorOptions",        'TOPLEFT= L["Top Left"]' },
        { "orientOptions",        'HORIZONTAL = L["Horizontal"]' },
        { "RESOURCE_COLOR_MODES", 'POWER_TYPE = L["Power Type"]' },
    }
    local firstBuilder = PAGE:find("local function BuildResourceSettingsGroup(tools2)", 1, true)
    check(firstBuilder ~= nil, "vocab: the first builder is locatable")
    for _, pair in ipairs(VOCAB) do
        local decls = 0
        for _ in PAGE:gmatch("local " .. pair[1] .. " = {") do decls = decls + 1 end
        eq(decls, 1, "vocab: " .. pair[1] .. " is declared exactly once")
        -- ...and ABOVE every builder, so a closure sees the real table rather
        -- than the nil upvalue a later declaration would leave it.
        local at = PAGE:find("local " .. pair[1] .. " = {", 1, true)
        check(at ~= nil and firstBuilder ~= nil and at < firstBuilder,
              "vocab: ..." .. pair[1] .. " is declared above the first builder")
        check(PAGE:find(pair[2], 1, true) ~= nil,
              "vocab: ..." .. pair[1] .. " still offers " .. pair[2])
    end

    -- ⚠ THE POWER LIST DID NOT MOVE, and that is the honest split rather than an
    -- oversight: nothing outside the Resource Colors builder reads it (the row's
    -- summary is the colour MODE's word), and it sits beside the ten seeds it
    -- drives.
    check(PAGE:find("local POWER_LIST = {", 1, true) ~= nil,
          "vocab: the power list is still declared")
    local powerAt = PAGE:find("local POWER_LIST = {", 1, true)
    local colorsBuilder = PAGE:find("local function BuildResourceColorsGroup(tools2)", 1, true)
    check(powerAt ~= nil and colorsBuilder ~= nil and powerAt > colorsBuilder,
          "vocab: ...and it is still inside the Resource Colors builder, beside its seeds")

    -- The texture resolver, its own copy: the Health Bar page's helper of the
    -- same name is a local inside THAT page's closure.
    check(PAGE:find("local function TextureName(path)", 1, true) ~= nil,
          "vocab: the texture-name resolver is a named page-scope helper")
    check(PAGE:find("DF:GetTextureNameFromPath(path)", 1, true) ~= nil,
          "vocab: ...and it is the addon's own resolver, not a path split")
end

-- ============================================================
-- 3. THE PAGE-WIDE GATE, IN BOTH HALVES
-- ☠ The rows grey with the page (ResourceOffRow) AND every gated pane's first
-- child is gated by hand (GatePaneFirstChild) -- the kit's disableChildrenOn
-- skips index 1, which is a header in a box and a CONTROL in a headless pane.
-- ============================================================
print("-- Resource Bar page: the page-wide gate reaches rows and panes")
do
    check(PAGE:find("local function ResourceOffRow(d) return not (d or db).resourceBarEnabled end", 1, true) ~= nil,
          "gate: the page's off-predicate is named once")
    check(PAGE:find("local function GatePaneFirstChild(group)", 1, true) ~= nil,
          "gate: ...and the pane's index-1 repair is a named helper")
    check(PAGE:find("w.disableOn = function(d) return ResourceOffRow(d) or (prev and prev(d)) or false end", 1, true) ~= nil,
          "gate: ...composed with whatever predicate the widget already carries")

    -- Seven panes take it. The eighth -- Border -- does not, and must not: its
    -- group has no disableChildrenOn to skip index 1, because
    -- CreateBorderControls owns the group and writes disableOn onto every widget
    -- it builds. That gate goes in through the factory's own disableWhen door.
    local applied = 0
    for _ in PAGE:gmatch("\n                GatePaneFirstChild%(group%)") do applied = applied + 1 end
    eq(applied, 7, "gate: seven panes take the index-1 repair")
    check(PAGE:find("disableWhen  = tools2.popout and ResourceOffRow or nil", 1, true) ~= nil,
          "gate: ...and the border's goes in through CreateBorderControls' own door")

    -- Every builder but the border's carries the group gate ITSELF, so a pane
    -- greys exactly as its box did. Left on the page-level box, the pane would
    -- stay bright while the bar is off and the two layouts would disagree.
    local inBuilder = 0
    for _ in PAGE:gmatch("group%.disableChildrenOn = function%(d%) return not d%.resourceBarEnabled end") do
        inBuilder = inBuilder + 1
    end
    eq(inBuilder, 7, "gate: seven builders carry the group gate themselves")

    -- The classic border box keeps its own, exactly as it always had.
    check(PAGE:find("borderGroup.disableChildrenOn = function(d) return not d.resourceBarEnabled end", 1, true) ~= nil,
          "gate: the classic border box keeps the gate it always had")
    -- ⚠ AND FRAME LEVEL SAYS THE GATE THE WAY EACH SHAPE ON THIS PAGE SAYS IT:
    -- the classic BOX carries it inline as a disableChildrenOn, exactly as it
    -- always did and exactly as the classic border box does; the control ROW takes
    -- ResourceOffRow, exactly as the page's other eight rows do. A third spelling
    -- for one setting is what this avoids.
    check(PAGE:find("frameLevelGroup.disableChildrenOn = function(d) return not d.resourceBarEnabled end", 1, true) ~= nil,
          "gate: the classic Frame Level box keeps the gate it always had")
    check(PAGE:find("frameLevelRow.disableOn = ResourceOffRow", 1, true) ~= nil,
          "gate: ...and the control row greys off the page's own row predicate")
end

-- ============================================================
-- 4. NO BUILDER REBUILDS THE PAGE, AND THE ORIENTATION PICK REACHES THE OTHER PANE
-- ============================================================
print("-- Resource Bar page: the callbacks route through the tools")
do
    local BUILDERS = { "BuildResourceSettingsGroup", "BuildResourceClassFilterGroup",
                       "BuildResourceSizeGroup", "BuildResourcePositionGroup",
                       "BuildResourceAppearanceGroup", "BuildResourceBackgroundGroup",
                       "BuildResourceBorderGroup", "BuildResourceColorsGroup" }
    for _, b in ipairs(BUILDERS) do
        local body = builderBody(b)
        check(body:find("GUI:RefreshCurrentPage", 1, true) == nil,
              "gate: " .. b .. " never rebuilds the page from inside itself")
        check(body:find("self:RefreshStates", 1, true) == nil,
              "gate: ..." .. b .. " never calls the PAGE's RefreshStates from inside a pane")
    end

    -- Five callbacks buy a state pass: the classic-only enable tick, the Match
    -- tick, the orientation pick, Show Background and the colour mode.
    local routed = 0
    for _ in PAGE:gmatch("tools2%.refreshStates%(%)") do routed = routed + 1 end
    eq(routed, 5, "gate: five callbacks route their state pass through the tools")

    -- Every popout mount declares itself as one -- eight rows, eight declarations.
    local popouts = 0
    for _ in PAGE:gmatch("popout = true,") do popouts = popouts + 1 end
    eq(popouts, 8, "gate: all eight popout mounts declare themselves as panes")

    -- ☠ THE CROSS-PANE CASE. Picking an orientation renames the two SIZE controls
    -- through their refreshContent hooks, and Size is a DIFFERENT pane -- so the
    -- pane's own refresh (ReflowPane here, plus the page pass) cannot reach it.
    -- ReflowMounted is the page-scope repaint that does. Without values: this is a
    -- state change, and a value sweep mid-drag snaps a slider thumb back.
    check(PAGE:find("local function OrientationChanged(tools2)", 1, true) ~= nil,
          "orientation: the cross-pane refresh is named once")
    local oc = PAGE:match("local function OrientationChanged%(tools2%)(.-)\n        end")
    check(oc ~= nil, "orientation: ...and its body is locatable")
    if oc then
        check(oc:find("tools2.refreshStates()", 1, true) ~= nil,
              "orientation: ...it runs the pane's own refresh (self:RefreshStates in classic)")
        check(oc:find("if tools2.popout then tools.ReflowMounted() end", 1, true) ~= nil,
              "orientation: ...and re-flows the OTHER mounted panes, in the popout layout only")
        check(oc:find("ReflowMounted(true)", 1, true) == nil,
              "orientation: ...without the value sweep, which would snap a dragged thumb")
    end
    check(PAGE:find("OrientationChanged(tools2)", 1, true) ~= nil,
          "orientation: ...and the dropdown calls it")

    -- The two refreshContent hooks that make the cross-pane refresh worth having
    -- are still there, on the controls they always named.
    check(PAGE:find("rbMatch.refreshContent = function(w, d)", 1, true) ~= nil,
          "orientation: the Match tick still renames itself by orientation")
    check(PAGE:find("widthSlider.refreshContent = function(w, d)", 1, true) ~= nil,
          "orientation: ...and so does the matched length slider")
end

-- ============================================================
-- 5. THE FIVE PLAIN ROWS -- census, classic box, wiring
-- ============================================================
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

local PLAIN = {
    { builder = "BuildResourceSizeGroup", label = "Size", boxHeader = "Size",
      box = "sizeGroup", column = "1", golden = RESOURCE_SIZE,
      countVar = "RESOURCE_SIZE_COUNT", row = "sizeRow", band = "layoutBand",
      summary = "ResourceSizeSummary", apply = "ApplyResourceSize", gated = true },
    { builder = "BuildResourcePositionGroup", label = "Position", boxHeader = "Position",
      box = "positionGroup", column = "1", golden = RESOURCE_POSITION,
      countVar = "RESOURCE_POSITION_COUNT", row = "positionRow", band = "layoutBand",
      summary = "ResourcePositionSummary", apply = "ApplyResourcePosition", gated = true },
    { builder = "BuildResourceAppearanceGroup", label = "Appearance", boxHeader = "Appearance",
      box = "appearanceGroup", column = "2", golden = RESOURCE_APPEARANCE,
      countVar = "RESOURCE_APPEARANCE_COUNT", row = "appearanceRow", band = "styleBand",
      summary = "ResourceAppearanceSummary", apply = "ApplyResourceAppearance", gated = true },
    { builder = "BuildResourceBackgroundGroup", label = "Background", boxHeader = "Background",
      box = "bgGroup", column = "2", golden = RESOURCE_BACKGROUND,
      countVar = "RESOURCE_BACKGROUND_COUNT", row = "bgRow", band = "styleBand",
      -- ⚠ NO SUMMARY: two controls, a tick and the colour it gates, and a swatch
      -- has no word. Repeating the tick's own label back at the user would be
      -- noise (the Class Colors row's precedent for an absent summary).
      summary = nil, apply = "ApplyResourceBackground", gated = true },
}

for _, g in ipairs(PLAIN) do
    print("-- Resource Bar page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())
    checkShared(g)

    check(body:find("hoistToggle", 1, true) == nil,
          g.label .. ": the builder has no hoist branch, because there is nothing to hoist")

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
-- 6. RESOURCE BAR SETTINGS -- the page gate's own row
-- keepEnabled + disableChildrenOn in classic, which is the shape of "am I doing
-- anything at all". The row carries the tick; the builder skips the checkbox.
-- ============================================================
local RESOURCE_SETTINGS = {
    { "checkbox", "Enable Resource Bar", "resourceBarEnabled",           30 },
    { "checkbox", "Healers",             "resourceBarShowHealer",        30 },
    { "checkbox", "Tanks",               "resourceBarShowTank",          30 },
    { "checkbox", "DPS",                 "resourceBarShowDPS",           30 },
    { "checkbox", "Show in Solo Mode",   "resourceBarShowInSoloMode",    30 },
}

print("-- Resource Bar page: Resource Bar Settings")
do
    local g = { builder = "BuildResourceSettingsGroup", label = "Resource Bar Settings",
                boxHeader = "Resource Bar Settings", box = "settingsGroup", column = "1",
                countVar = "RESOURCE_SETTINGS_COUNT", row = "settingsRow",
                band = "generalBand", summary = "ResourceSettingsSummary",
                apply = "ApplyResourceSettings", gated = false }
    local body = builderBody(g.builder)
    checkCensus(census(body), RESOURCE_SETTINGS, "resource bar settings")
    checkShared(g)

    check(body:find("if not tools2.hoistToggle then", 1, true) ~= nil,
          "settings: the enable checkbox is skipped when the row has hoisted it")
    check(body:find("resourceBarEnable.keepEnabled = true", 1, true) ~= nil,
          "settings: ...and in classic it stays live under the group's own grey")

    -- ⚠ FOUR IN BOTH MODES. Show in Solo Mode is HIDDEN in raid, not skipped, so
    -- the pane still MOUNTS it -- unlike the Pet Frames rows whose counts are
    -- `isRaidMode and 6 or 5` because those builders skip a control outright.
    local declared = tonumber(PAGE:match("local RESOURCE_SETTINGS_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "settings: the page declares the row's count in one place")
    eq(declared, #RESOURCE_SETTINGS - 1, "settings: ...the census less the hoisted tick")
    check(PAGE:find("showInSolo.hideOn = function() return GUI.SelectedMode == \"raid\" end", 1, true) ~= nil,
          "settings: Show in Solo Mode is hidden in raid, not skipped -- which is why the count is not mode-dependent")

    local opts = rowOpts("Resource Bar Settings")
    check(opts:find('toggle%s*=%s*{%s*key%s*=%s*"resourceBarEnabled"%s*}') ~= nil,
          "settings: the row's tick is the page's own enable key")
    check(opts:find("onToggle%s*=%s*OnResourceEnableToggle") ~= nil,
          "settings: ...and a commit that is not a page rebuild")

    local commit = PAGE:match("local function OnResourceEnableToggle%(%)(.-)\n            end")
    check(commit ~= nil, "settings: the popout commit is a named function")
    if commit then
        check(commit:find("RefreshCurrentPage", 1, true) == nil,
              "settings: ...and never rebuilds the page")
        check(commit:find("DF:UpdateAllPowerEventRegistration()", 1, true) ~= nil,
              "settings: ...it runs what the suppressed checkbox ran (the event re-registration)")
        check(commit:find("DF:UpdateAllFrames()", 1, true) ~= nil,
              "settings: ...and the full update with it")
        check(commit:find("self:RefreshStates()", 1, true) ~= nil,
              "settings: ...re-runs the state passes")
        check(commit:find("tools.ReflowMounted()", 1, true) ~= nil,
              "settings: ...and reflows every open pane, because this is the PAGE gate")
    end

    check(PAGE:find('tools.RegisterHoistedToggle(settingsRow, L["Enable Resource Bar"], "resourceBarEnabled", OnResourceEnableToggle)', 1, true) ~= nil,
          "settings: the hoisted toggle keeps its search entry")
end

-- ============================================================
-- 7. CLASS FILTER -- the tick without the footer
-- ☠ THE REFUSAL IS STRUCTURAL. The thirteen ticks are bound to
-- db.resourceBarClassFilter, a SUB-TABLE captured at build time.
-- GroupActions:ResetKeys writes a table-valued key by REPLACING it with a deep
-- copy of the default, so after a Reset Group every checkbox would be reading and
-- writing a detached table: the frames would move, the ticks would show the
-- pre-reset state, and all thirteen would be dead until the next page rebuild.
-- The amber tick is a READ of the same key and is perfectly honest, so it stays.
-- ============================================================
print("-- Resource Bar page: Class Filter")
do
    local g = { builder = "BuildResourceClassFilterGroup", label = "Class Filter",
                boxHeader = "Class Filter", box = "classFilterGroup", column = "1",
                countVar = "RESOURCE_CLASS_FILTER_COUNT", row = "classFilterRow",
                band = "generalBand", summary = "ResourceClassFilterSummary",
                apply = nil, gated = true }
    local body = builderBody(g.builder)
    -- ⚠ ONE CENSUS ROW FOR THIRTEEN CONTROLS, because they come out of a LOOP over
    -- RB_CLASS_LIST: the label is info.name and the key is a token off the
    -- sub-table, so neither is a literal the reader can see. The list's own length
    -- is pinned below instead.
    checkCensus(census(body), { { "checkbox", "(none)", "(none)", 25 } }, "class filter")
    checkShared(g)

    -- The seed stays in the builder, ahead of the ticks that read it -- a
    -- build-time write to the profile, and a pane is built EAGERLY, so it still
    -- lands at the moment it always did.
    check(body:find("if not db.resourceBarClassFilter then", 1, true) ~= nil,
          "class filter: the sub-table seed is still inside the builder")
    check(body:find("db.resourceBarClassFilter[info.token] = true", 1, true) ~= nil,
          "class filter: ...seeding every class on, exactly as before")

    -- Thirteen classes, and the count says thirteen.
    local list = PAGE:match("local RB_CLASS_LIST = {(.-)\n        }")
    check(list ~= nil, "class filter: the class list is locatable")
    local tokens = 0
    for _ in (list or ""):gmatch("token = \"") do tokens = tokens + 1 end
    eq(tokens, 13, "class filter: thirteen classes in the list")
    local declared = tonumber(PAGE:match("local RESOURCE_CLASS_FILTER_COUNT%s*=%s*(%d+)"))
    eq(declared, 13, "class filter: ...and the row's count is the same thirteen")

    -- Two tracks in the pane, one in the classic box. Read out of THIS mount's
    -- own block rather than by finding "end, 2)" anywhere on the page: the second
    -- argument to PopoutContent is the only innerColumns on this page, and a bare
    -- find would pass on any unrelated two.
    local mount = PAGE:match("local classFilterMount, classFilterContent = (.-)\n            local classFilterRow")
    check(mount ~= nil, "class filter: the mount block is locatable")
    check(mount ~= nil and mount:find("end, 2)", 1, true) ~= nil,
          "class filter: the pane takes two interior tracks")
    check(mount ~= nil and mount:find("tools.PopoutContent(function(group, holder, reflow)", 1, true) ~= nil,
          "class filter: ...through PopoutContent's own innerColumns argument")

    -- ☠ THE EXTRA KEY IS THE REAL ONE. The walk sees thirteen bare class tokens
    -- (right for the search map, useless to the defaults engine); the profile key
    -- is named through ClaimKeys' third argument, as Group Visibility names
    -- raidGroupVisible.
    check(PAGE:find('tools.ClaimKeys(classFilterRow, classFilterContent, { "resourceBarClassFilter" })', 1, true) ~= nil,
          "class filter: the row claims the profile key the walk cannot see")
    check(PAGE:find("tools.WireModifiedTick(classFilterRow)", 1, true) ~= nil,
          "class filter: ...the amber tick reads it")
    check(PAGE:find("tools.WireFooter(classFilterRow", 1, true) == nil,
          "class filter: ...and NOTHING writes it -- no Reset Group, no Hold: Defaults")
    -- ...and the refusal is written down where the next reader will look.
    check(PAGE:find("captured the OLD sub-table", 1, true) ~= nil,
          "class filter: the refusal carries its reason in the source")
end

-- ============================================================
-- 8. BORDER AND RESOURCE COLORS -- the composite and the mixed row
-- ============================================================
print("-- Resource Bar page: Border")
do
    local body = builderBody("BuildResourceBorderGroup")
    -- No census: CreateBorderControls builds the whole group, and
    -- test_border_builders.lua is what pins what it builds.
    checkCensus(census(body), {}, "border")

    check(body:find('GUI:CreateBorderControls(tools2.group, db, "resourceBar", {', 1, true) ~= nil,
          "border: the composite still builds against the resourceBar prefix")
    check(body:find("include      = { alpha = true, inset = true, blendMode = true,", 1, true) ~= nil,
          "border: ...with the include set it always had")
    check(body:find("classColor = true, roleColor = true }", 1, true) ~= nil,
          "border: ...including the two colour resolvers, which is why it has a source dropdown")
    check(body:find("noShowToggle = tools2.hoistToggle or nil", 1, true) ~= nil,
          "border: ...and the built-in Show Border is suppressed when the row hoists it")

    checkShared({ builder = "BuildResourceBorderGroup", label = "Border", boxHeader = "Border",
                  box = "borderGroup", column = "2",
                  countVar = "RESOURCE_BORDER_COUNT", row = "borderRow", band = "styleBand",
                  summary = "ResourceBorderSummary", apply = "ApplyResourceBorder",
                  gated = true })

    -- Seventeen for this include set (the pet row's sixteen plus the Border Color
    -- Source dropdown that classColor/roleColor add), less the hoisted tick.
    local declared = tonumber(PAGE:match("local RESOURCE_BORDER_COUNT%s*=%s*(%d+)"))
    eq(declared, 16, "border: sixteen behind the row -- the seventeen it builds, less Show Border")

    local opts = rowOpts("Border")
    check(opts:find('toggle%s*=%s*{%s*key%s*=%s*"resourceBarShowBorder"%s*}') ~= nil,
          "border: the row's tick is the factory's own show key")
    check(PAGE:find('tools.RegisterHoistedToggle(borderRow, L["Show Border"], "resourceBarShowBorder", OnResourceBorderToggle)', 1, true) ~= nil,
          "border: ...and it keeps the suppressed checkbox's search entry")

    local commit = PAGE:match("local function OnResourceBorderToggle%(%)(.-)\n            end")
    check(commit ~= nil, "border: the popout commit is a named function")
    if commit then
        check(commit:find("RefreshCurrentPage", 1, true) == nil,
              "border: ...and never rebuilds the page")
        check(commit:find("ApplyResourceBorder()", 1, true) ~= nil,
              "border: ...it runs the group's own apply")
        check(commit:find("tools.ReflowMounted()", 1, true) ~= nil,
              "border: ...and reflows the open panes")
    end
end

local RESOURCE_COLORS = {
    { "label",       "Customize resource bar colors per power type. Shared across party and raid frames.",
                     "(none)",                  40 },
    { "dropdown",    "Color Mode",   "resourceBarColorMode",   54 },
    { "colorpicker", "Custom Color", "resourceBarCustomColor", 30 },
    { "colorpicker", "(none)",       "(none)",                 30 },
}

print("-- Resource Bar page: Resource Colors")
do
    local g = { builder = "BuildResourceColorsGroup", label = "Resource Colors",
                boxHeader = "Resource Colors", box = "colorGroup", column = "2",
                countVar = "RESOURCE_COLORS_COUNT", row = "colorsRow", band = "styleBand",
                summary = "ResourceColorsSummary", apply = "ApplyResourceColors",
                gated = true }
    local body = builderBody(g.builder)
    -- The fourth census row is the TEN power swatches, which come out of a loop
    -- over POWER_LIST -- same reason the class filter collapses to one.
    checkCensus(census(body), RESOURCE_COLORS, "resource colors")
    checkShared(g)

    -- Ten powers, and the count is blurb + mode + custom + ten + the reset button.
    local list = PAGE:match("local POWER_LIST = {(.-)\n            }")
    check(list ~= nil, "resource colors: the power list is locatable")
    local tokens = 0
    for _ in (list or ""):gmatch("token = \"") do tokens = tokens + 1 end
    eq(tokens, 10, "resource colors: ten power types in the list")
    local declared = tonumber(PAGE:match("local RESOURCE_COLORS_COUNT%s*=%s*(%d+)"))
    eq(declared, 3 + tokens + 1,
       "resource colors: fourteen behind the row -- blurb, mode, custom swatch, ten powers, reset")

    -- The ten seeds stay in the builder, ahead of the picker that reads each one.
    check(body:find("if not powerColorsDB[token] then", 1, true) ~= nil,
          "resource colors: the ten seeds are still inside the builder")
    check(body:find("local powerColorsDB = DF.db.powerColors", 1, true) ~= nil,
          "resource colors: ...and so is the root-table resolve they need")

    -- ☠ THE RESET BUTTON NO LONGER REBUILDS THE PAGE FROM INSIDE A PANE. Classic
    -- still does; a pane runs the group-wide value sweep, which is what the
    -- rebuild was actually buying (RefreshChildValues repaints every swatch).
    check(body:find("if tools2.popout then", 1, true) ~= nil,
          "resource colors: the reset button branches on the layout")
    check(body:find("tools.ReflowMounted(true)", 1, true) ~= nil,
          "resource colors: ...a pane repaints its swatches with the value sweep")
    check(body:find("elseif pageResource and pageResource.Refresh then", 1, true) ~= nil,
          "resource colors: ...and classic keeps the page rebuild it always had")
    check(body:find("GUI:StyleButton(resetPowerBtn", 1, true) ~= nil,
          "resource colors: the bespoke Reset All button is still in the pane")

    -- ⚠ THE MIXED CLAIM. Twelve keys the walk can see: two per-mode profile keys
    -- and the ten power tokens, which live at the ROOT of DF.db and which the
    -- defaults engine therefore skips in silence. Tick and footer both, because
    -- the engine CAN answer for two of them -- unlike the Colors page's palette
    -- rows, where it can answer for none.
    check(PAGE:find("tools.ClaimKeys(colorsRow, colorsContent)", 1, true) ~= nil,
          "resource colors: the row claims what the pane registered, tokens included")
    check(PAGE:find("tools.WireModifiedTick(colorsRow)", 1, true) ~= nil,
          "resource colors: ...the amber tick reads the two keys the engine ships")
    check(PAGE:find("tools.WireFooter(colorsRow, ApplyResourceColors)", 1, true) ~= nil,
          "resource colors: ...and the footer writes those two and passes over the ten")
    check(PAGE:find("THE ONE MIXED ROW ON THE SWEEP", 1, true) ~= nil,
          "resource colors: the mixed claim carries its reasoning in the source")
end

-- ============================================================
-- 9. FRAME LEVEL -- the page's one CONTROL ROW
-- ⚠ One slider is not a feature to open, so it never earned a popout row. But a
-- 280 box between two full-width bands is the one shape a column of plates
-- cannot absorb, so the slider wears the row plate instead -- the band skin
-- settled the border and never the edge.
-- ============================================================
print("-- Resource Bar page: the Frame Level control row")
do
    -- ---- still not a popout row --------------------------------------
    check(PAGE:find('label   = L["Frame Level"]', 1, true) == nil,
          "frame level: no popout row is declared for one slider")

    -- ---- the row -----------------------------------------------------
    check(PAGE:find('label       = L["Frame Level"],\n                kind        = "slider",', 1, true) ~= nil,
          "frame level: it is a slider control row")
    check(PAGE:find("local frameLevelBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
          "frame level: ...in a chromeless band at the width the layout pass will give it")
    check(PAGE:find("frameLevelBand:AddWidget(GUI:CreateControlRow(", 1, true) ~= nil,
          "frame level: ...mounted into that band")
    -- ⚠ NO BAND HEADER. The box was headed "Frame Level" over a slider captioned
    -- "Frame Level"; a row draws ONE name, so a header would be the third copy.
    check(PAGE:find("frameLevelBand:AddWidget(GUI:CreateHeader", 1, true) == nil,
          "frame level: ...and no band header, because the row's own label names it")
    check(PAGE:find("min         = 0, max = 100, step = 1,", 1, true) ~= nil,
          "frame level: the slider's range is the one it always had")
    -- The TABLE binding, which is what keeps the override markers and the search
    -- index addressing the same (table, key) pair the classic slider gave them.
    check(PAGE:find('db          = db,\n                key         = "resourceBarFrameLevel",', 1, true) ~= nil,
          "frame level: ...bound to the page's own table, not a function")
    -- ☠ THE CALLBACK STAYS ON THE PREVIEW HALF. The classic call passed nothing on
    -- commit and the frame-level reapply on the drag tick (positional slots 8 and
    -- 9); `lightweight` is the kit's own name for that half.
    check(PAGE:find("lightweight = function() DF:LightweightUpdateResourceBarFrameLevel() end,", 1, true) ~= nil,
          "frame level: ...and the reapply is still the drag-tick preview, not a commit")
    -- ...and NOTHING on commit, which is what the classic call's nil slot 8 said.
    local rowOpts
    do
        local a = PAGE:find('label       = L["Frame Level"],', 1, true)
        local b = a and PAGE:find("}))", a, true)
        rowOpts = a and PAGE:sub(a, (b or a) + 2) or ""
    end
    check(rowOpts:find("onChanged", 1, true) == nil,
          "frame level: ...with nothing hung on commit, exactly as before")
    check(PAGE:find("tooltip     = GUI:FrameLevelTooltip(),", 1, true) ~= nil,
          "frame level: ...and the shared Frame Level sentence, from the one helper")
    check(PAGE:find('tools.RegisterControlRow(frameLevelRow, "slider", "resourceBarFrameLevel")', 1, true) ~= nil,
          "frame level: ...and it reaches search through the shared verb")

    -- ---- classic still builds the box it always built ------------------
    check(PAGE:find("local frameLevelGroup = GUI:CreateSettingsGroup(self.child, 280)", 1, true) ~= nil,
          "frame level: classic keeps the bare 280 box")
    check(PAGE:find('frameLevelGroup:AddWidget(GUI:CreateHeader(self.child, L["Frame Level"]), 40)', 1, true) ~= nil,
          "frame level: ...with the header it always had")
    check(PAGE:find('frameLevelGroup:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(self.child, L["Frame Level"], 0, 100, 1, db, "resourceBarFrameLevel", nil, function() DF:LightweightUpdateResourceBarFrameLevel() end, true)), 55)', 1, true) ~= nil,
          "frame level: ...and the slider call it always made, tooltip helper and all")
    -- ⚠ THE FLAG IS NEVER WRITTEN AS A LITERAL. One shared table off the tools.
    check(PAGE:find("bandStyle", 1, true) == nil,
          "frame level: the band skin is never restated as a literal")
end

-- ============================================================
-- 10. THE ORDER -- classic unmoved, and the popout page's four blocks
-- ============================================================
print("-- Resource Bar page: the Add order in both layouts")
do
    -- ---- classic: nine boxes, the order and the columns it always had -----
    local ORDER = {
        "Add(settingsGroup, nil, 1)",
        "Add(classFilterGroup, nil, 1)",
        "Add(sizeGroup, nil, 1)",
        "Add(positionGroup, nil, 1)",
        "Add(appearanceGroup, nil, 2)",
        "Add(bgGroup, nil, 2)",
        "Add(borderGroup, nil, 2)",
        "Add(frameLevelGroup, nil, 1)",
        "Add(colorGroup, nil, 2)",
    }
    local prev = 0
    for i, needle in ipairs(ORDER) do
        local at = PAGE:find(needle, 1, true)
        check(at ~= nil, "order: classic still adds " .. needle)
        check(at ~= nil and at > prev, "order: ...in position " .. i)
        prev = at or prev
    end

    -- ---- popout: General, Layout, the Frame Level band, Style -------------
    -- ☠ THE BANDS ARE ADDED AT FOUR DIFFERENT POINTS, not in one block at the
    -- end, because the Frame Level band sits BETWEEN two of them -- in the slot
    -- classic gives its box (eighth), so neither layout has to move for the other.
    -- Every one of the four is "both", which is the alignment rule as an Add.
    local gen   = PAGE:find('Add(generalBand, nil, "both")', 1, true)
    local lay   = PAGE:find('Add(layoutBand, nil, "both")', 1, true)
    local level = PAGE:find('Add(frameLevelBand, nil, "both")', 1, true)
    local style = PAGE:find('Add(styleBand, nil, "both")', 1, true)
    check(gen and lay and level and style, "order: all four page-level Adds are present, all of them sync points")
    check(gen and lay and gen < lay, "order: the General band goes in before the Layout band")
    check(lay and level and lay < level, "order: ...the Layout band before the Frame Level band")
    check(level and style and level < style, "order: ...and the Frame Level band before the Style band")

    -- Each band is added after its LAST row, because `Add` resolves a widget's
    -- slot height on the spot.
    check(PAGE:find("local classFilterRow = generalBand:AddWidget", 1, true) < gen,
          "order: the General band goes in after its last row")
    check(PAGE:find("local positionRow = layoutBand:AddWidget", 1, true) < lay,
          "order: ...the Layout band after its last row")
    check(PAGE:find("local colorsRow = styleBand:AddWidget", 1, true) < style,
          "order: ...and the Style band after its last row")

    -- ---- nine bare 280 boxes, and every one is a classic arm's -----------
    -- The eight converted boxes plus Frame Level's own classic width, which is
    -- now written out rather than shared with the popout arm.
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 9, "boxes: nine bare 280 boxes left -- the classic arms' own")
    -- ☠ THE ALIGNMENT RULE, ON THIS PAGE: nothing is mounted at a column's 280
    -- with the tools in hand. A 280 box only ever appears with NO opts, which is
    -- the classic arm's signature.
    local narrow = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280, tools") do narrow = narrow + 1 end
    eq(narrow, 0, "boxes: ...and none of them is a new-UI mount at 280")
end

-- ============================================================
-- 11. ZERO NEW LOCALE STRINGS
-- Every label, band header and summary word on this page already shipped.
-- ============================================================
print("-- Resource Bar page: every locale string the page asks for already ships")
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
