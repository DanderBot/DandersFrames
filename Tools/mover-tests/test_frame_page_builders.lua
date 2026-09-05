local NS = ...

-- ============================================================
-- FRAME PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Options.lua
-- ------------------------------------------------------------
-- The sweep turns the Frame page's remaining checkbox-gated groups into popout
-- feature rows. Each conversion is allowed to change WHERE a group is mounted
-- and nothing else: same widgets, same order, same L keys, same db keys, same
-- slot heights, in both layouts, because the classic box and the popout pane
-- are handed the SAME builder.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db. So this file does
-- what test_border_builders does for its own source-level claims (the declared
-- counts, the hoisted toggles, the band): it reads the page's SOURCE and asserts
-- against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each extracted builder -- kind, L key, db key and
--     slot height, in order. This is the inventory the group had INLINE before
--     the move, copied here from a census of the pre-change source, so a
--     builder that quietly dropped a control or renamed a key fails here.
--   ✓ that ONE builder serves both layouts (the classic branch and the popout
--     branch name the same function), which is what makes "classic is identical
--     to main" a structural fact rather than a promise.
--   ✓ that the declared row COUNT matches what the builder mounts, less any
--     hoisted toggle -- the badge is a claim about how much is inside.
--   ✗ nothing about runtime behaviour. The callbacks, the greying and the
--     summaries are read by eye and by the in-game checklist.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Options.lua")

-- ---- the census reader ----------------------------------------------
-- Every GUI:Create<Kind> call in a builder's body, in order, with the label,
-- the db key and the height AddWidget was given.
--
-- Newlines are collapsed first so a call split across four lines reads as one,
-- and each call's chunk runs to the START OF THE NEXT ONE -- which is what makes
-- "the first L[...] in the chunk" the label rather than some tooltip's string
-- three lines below it.
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
}

-- The body of a `local function <name>(tools2)` at the page builder's own indent.
-- ⚠ Terminated on a newline + EIGHT spaces + `end`, which is the page builder's
-- indent level: everything inside one of these bodies is indented further, so
-- this is the function's own close and not one of its inline closures'.
--
-- ⚠ `tools2`, NOT `tools`. The page took GUI:CreatePopoutPageTools, so `tools` is
-- the page-scope machinery table and a builder's own opts argument had to move
-- aside -- the same rename every other converted page made, for the same reason:
-- a builder that shadowed the name could never reach the page's verbs.
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
    -- Where every call starts, so a chunk can run to the next one.
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
        -- ☠ THE LABEL IS THE CALL'S SECOND ARGUMENT, not "the first L[...] in the
        -- chunk". The looser reading held only while every widget was followed by
        -- its own tooltip; the sweep put option TABLES between calls, and a
        -- `{ CENTER = L["Center"] }` declared after one control and used by the
        -- next made that control report "Center" as its name. Anchored to the
        -- call, so a control labelled from a VARIABLE (the two flat-grid controls
        -- whose names swap with the growth direction) honestly reads "(none)"
        -- rather than borrowing a word from the line below it.
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

-- The block a row is declared in, from its label down to the closing brace of
-- the CreatePopoutRow opts. Used to ask what the row DECLARED -- a toggle, a
-- count, a summary -- without building one.
local function rowOpts(labelKey)
    local a = SRC:find('label%s*=%s*L%["' .. labelKey .. '"%]')
    check(a ~= nil, "source: a popout row is declared for " .. labelKey)
    if not a then return "" end
    local b = SRC:find("}))", a, true)
    return SRC:sub(a, (b or a) + 2)
end

-- ============================================================
-- 1. FRAME FADE -- the toggle-less row
-- Seven controls behind one row, and NO tick on it: the group has no boolean
-- meaning "am I doing anything". frameFadeSplitCombat is a MODE (both states
-- fade) and it HIDES the global slider, so hoisting it would have given the row
-- a tick that greys the one control the group exists for.
-- ============================================================
local FRAME_FADE = {
    { "slider",   "Global Frame Fade",                 "frameFadeAlpha",              55 },
    { "checkbox", "Separate Combat Fade",              "frameFadeSplitCombat",        30 },
    { "slider",   "Out of Combat Frame Fade",          "frameFadeAlphaOutOfCombat",   55 },
    { "slider",   "In Combat Frame Fade",              "frameFadeAlphaInCombat",      55 },
    { "checkbox", "Use In-Combat Fade In Instances",   "frameFadeInstanceUsesCombat", 30 },
    { "checkbox", "Show In-Combat Fade When Hovering", "frameFadeHoverUsesCombat",    30 },
    { "dropdown", "Hover Applies To",                  "frameFadeHoverScope",         55 },
}

do
    local body = builderBody("BuildFrameFadeGroup")
    checkCensus(census(body), FRAME_FADE, "frame fade")

    -- The count badge is a CLAIM about how much is behind the row. Read out of
    -- the page rather than retyped, so the two cannot drift.
    local declared = tonumber(SRC:match("local FRAME_FADE_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "frame fade: the page declares the row's count in one place")
    eq(declared, #FRAME_FADE, "frame fade: ...and it is what the builder mounts")

    -- Nothing is hoisted, so nothing is suppressed: all seven controls are in
    -- the pane, and all seven keep the search entries their factories give them.
    check(body:find("noEnableToggle") == nil and body:find("noShowToggle") == nil,
          "frame fade: no toggle is suppressed, because none is hoisted")

    local opts = rowOpts("Frame Fade")
    check(opts:find("toggle", 1, true) == nil,
          "frame fade: the row declares no toggle -- it is a way in, not a switch")
    check(opts:find("summary%s*=%s*FrameFadeSummary") ~= nil,
          "frame fade: ...it does declare a summary")
    check(opts:find("count%s*=%s*FRAME_FADE_COUNT") ~= nil,
          "frame fade: ...and the declared count, not a literal")

    -- ONE builder, BOTH layouts. This is the whole of "classic is identical to
    -- main": the classic branch does not carry a copy of the widgets, it mounts
    -- the same function into the box it always built.
    local calls = 0
    for _ in SRC:gmatch("BuildFrameFadeGroup%(") do calls = calls + 1 end
    eq(calls, 3, "frame fade: declared once, mounted twice -- classic box and popout pane")
    check(SRC:find('frameFadeGroup:AddWidget%(GUI:CreateHeader%(self%.child, L%["Frame Fade"%]%)') ~= nil,
          "frame fade: the classic box still builds its own header above the group")

    -- The summary reuses words the locale already ships. A summary is the one
    -- place a page is tempted to invent a string for; these two are the same
    -- keys the border row's summary uses.
    local sum = SRC:match("local function FrameFadeSummary%(d%)(.-)local FRAME_FADE_COUNT")
    check(sum ~= nil, "frame fade: the summary is a named function on the page")
    if sum then
        check(sum:find('L%["Alpha"%]') ~= nil, "frame fade: ...labelling the opacity with an existing key")
        check(sum:find('L%["Combat"%]') ~= nil, "frame fade: ...and the in-combat one with another")
        check(sum:find("\\194\\183", 1, true) ~= nil, "frame fade: ...separated by the convention's dot")
    end
end

-- ============================================================
-- 2. PERMANENT MOVER -- the page's textbook conversion
-- One checkbox meaning "am I doing anything" and fifteen controls greying
-- behind it. The tick is HOISTED onto the row, so the builder is told to skip
-- it -- and the fifteen it still mounts is what the badge claims.
-- ============================================================
local PERM_MOVER = {
    { "checkbox",    "Enable Permanent Mover", "permanentMover",                  30 },
    { "dropdown",    "Handle Position",        "permanentMoverAnchor",            55 },
    { "dropdown",    "Attach To",              "permanentMoverAttachTo",          55 },
    { "slider",      "Offset X",               "permanentMoverOffsetX",           55 },
    { "slider",      "Offset Y",               "permanentMoverOffsetY",           55 },
    { "slider",      "Handle Width",           "permanentMoverWidth",             55 },
    { "slider",      "Handle Height",          "permanentMoverHeight",            55 },
    { "checkbox",    "Show on Hover Only",     "permanentMoverShowOnHover",       30 },
    { "checkbox",    "Hide in Combat",         "permanentMoverHideInCombat",      30 },
    { "colorpicker", "Handle Color",           "permanentMoverColor",             35 },
    { "colorpicker", "Combat Color",           "permanentMoverCombatColor",       35 },
    { "dropdown",    "Left Click",             "permanentMoverActionLeft",        55 },
    { "dropdown",    "Right Click",            "permanentMoverActionRight",       55 },
    { "dropdown",    "Shift+Left Click",       "permanentMoverActionShiftLeft",   55 },
    { "dropdown",    "Shift+Right Click",      "permanentMoverActionShiftRight",  55 },
    { "slider",      "Pull Timer Duration",    "permanentMoverPullTimerDuration", 55 },
}

do
    local body = builderBody("BuildPermanentMoverGroup")
    checkCensus(census(body), PERM_MOVER, "permanent mover")

    -- The hoist, and the arithmetic it implies. The checkbox is still IN the
    -- builder -- the classic box needs it -- behind the one flag the popout
    -- passes, so the pane mounts one fewer than the census.
    check(body:find("if not tools2.hoistToggle then") ~= nil,
          "permanent mover: the enable checkbox is skipped when the row has hoisted it")
    local declared = tonumber(SRC:match("local PERM_MOVER_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "permanent mover: the page declares the row's count in one place")
    eq(declared, #PERM_MOVER - 1, "permanent mover: ...the census less the hoisted tick")

    -- The thirteen dependents keep greying on the key in BOTH layouts. The row's
    -- toggle gate covers the pane, but the predicates are what the classic box
    -- greys with, and one builder serves both -- so losing them would silently
    -- ungrey the classic layout.
    local greys = 0
    for _ in body:gmatch("disableOn%s*=%s*function%(d%) return not d%.permanentMover end") do
        greys = greys + 1
    end
    eq(greys, #PERM_MOVER - 1, "permanent mover: every control but the enable greys on it")

    local opts = rowOpts("Permanent Mover")
    check(opts:find('toggle%s*=%s*{%s*key%s*=%s*"permanentMover"%s*}') ~= nil,
          "permanent mover: the row's tick is the group's own enable key")
    check(opts:find("summary%s*=%s*PermMoverSummary") ~= nil,
          "permanent mover: ...it declares a summary")
    check(opts:find("count%s*=%s*PERM_MOVER_COUNT") ~= nil,
          "permanent mover: ...and the declared count, not a literal")
    check(opts:find("onToggle%s*=%s*OnPermMoverToggle") ~= nil,
          "permanent mover: ...and a commit that is not a page rebuild")

    -- The hoisted toggle is re-registered with search under the SAME label and
    -- key the suppressed checkbox carried, or the setting becomes unfindable in
    -- the popout layout while staying findable in classic.
    local hoisted = SRC:match('RegisterHoistedToggle%(moverRow,%s*L%["([^"]+)"%],%s*"([^"]+)"')
    eq(hoisted, PERM_MOVER[1][2], "permanent mover: the hoisted toggle is re-registered under its own label")
    local _, hoistedKey = SRC:match('RegisterHoistedToggle%(moverRow,%s*L%["([^"]+)"%],%s*"([^"]+)"')
    eq(hoistedKey, PERM_MOVER[1][3], "permanent mover: ...and its own db key")

    -- ONE builder, BOTH layouts, same as Frame Fade.
    local calls = 0
    for _ in SRC:gmatch("BuildPermanentMoverGroup%(") do calls = calls + 1 end
    eq(calls, 3, "permanent mover: declared once, mounted twice -- classic box and popout pane")

    -- The row's own band: chromeless, built at the page's usable width (never a
    -- literal) and spanning both columns, so its right edge lands on the same
    -- corridor the Appearance band's rows do.
    check(SRC:find("permMoverBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
          "permanent mover: the band is chromeless, because the row IS the surface")
    -- ...at the width the layout pass will stretch it to, asked for through the
    -- shared helper rather than computed here. Section 5 pins that all three of
    -- the page's bands ask the same way; the expression behind the name is
    -- test_popout_page_tools' claim.
    check(SRC:find("moverBandW", 1, true) == nil,
          "permanent mover: ...at the width the layout pass will stretch it to")
    check(SRC:find('Add(permMoverBand, nil, "both")', 1, true) ~= nil,
          "permanent mover: ...and spanning both columns")
    -- ...and NO header above it. The row's own label already says the words.
    check(SRC:find('permMoverBand:AddWidget(GUI:CreateHeader', 1, true) == nil,
          "permanent mover: the band carries no header -- the row's label is the name")
end

-- ============================================================
-- 3. THE PAGE IS ROWS -- WHERE THE THREE BANDS ARE ADDED
--
-- Danders: "make the whole frame page using popouts -- I want to see the
-- difference." So every group on this page is a feature row now, in one of three
-- full-width bands, and the popout layout adds nothing else at all.
--
-- ☠ THAT SUSPENDS THE PRIMARIES-STAY RULE, deliberately and for this page only.
-- Frame Size and Layout Direction are what a new user opens the page for, and
-- normally a primary does not go behind a click. They are rows here so the
-- comparison is honest -- a page that kept two boxes at the top would be
-- answering a softer question -- and the revert is one tag away because the
-- classic layout is byte-identical either way, which is what section 4 pins.
--
-- The ORDER note that used to live here is still true and no longer applies:
-- layoutCol "both" is a sync point (LayoutPage drops both columns to the lower of
-- the two), so a band added into the middle of an UNBALANCED two-column flow
-- leaves a hole beside whatever was above it. There is no flow left to unbalance
-- -- a run of "both" widgets over two equal columns is a plain single stack -- so
-- the order below is purely reading order.
--
-- ⚠ WHAT THIS TEST CAN AND CANNOT SEE. Add() order IS page order (LayoutPage
-- walks self.children), so the source order of the Add calls is the claim. It is
-- not a geometry test: the page cannot be built headlessly, so the widths are on
-- the in-game checklist.
-- ============================================================

-- The Frame page's own source, from its copy button to the See Also bar at its
-- foot. Scoped because `sizeGroup`, `layoutGroup` and `appearanceGroup` are the
-- house names for those boxes and OTHER pages in this same file use them.
local function framePage()
    local a = SRC:find('Add(CreateCopyButton(self.child, {"frame", "permanentMover"', 1, true)
    local b = SRC:find('{pageId = "general_sorting", label = L["Sorting"]}', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Frame page builder is locatable by its own ends")
    return SRC:sub(a or 1, b or 1)
end

-- The ten groups that became rows or were already rows, with the row LABEL each
-- one wears in the popout layout and the classic box variable it keeps. Named in
-- band order, which is also source order.
--
-- ⚠ Raid Layout Mode carries a toggle and NO count; every other converted group
-- is toggle-less with a count. Both facts are per-row claims, checked in
-- section 4 -- this list is only the roster.
local LAYOUT_ROWS = {
    { "sizeGroup",        "Frame Size"            },
    { "layoutGroup",      "Layout Direction"      },
    { "raidModeGroup",    "Raid Layout Mode"      },
    { "groupLayoutGroup", "Group Layout Settings" },
    { "groupVisGroup",    "Group Visibility"      },
    { "groupOrderGroup",  "Group Display Order"   },
    { "flatGridGroup",    "Flat Grid Settings"    },
}

do
    local page = framePage()

    local adds = {}
    for name, col in page:gmatch("Add%((%a[%w_]*),%s*nil,%s*([%w\"_]+)%)") do
        adds[#adds + 1] = { name = name, col = col }
    end
    check(#adds >= 10, "order: the page's Add calls are readable (" .. #adds .. " found)")

    local function indexOf(name, col)
        for i, e in ipairs(adds) do
            if e.name == name and (col == nil or e.col == col) then return i end
        end
    end

    -- ---- the three bands, in reading order, at the foot ---------------
    local bandL = indexOf("layoutBand", '"both"')
    local bandA = indexOf("appearanceGroup", '"both"')
    local bandM = indexOf("permMoverBand", '"both"')
    check(bandL ~= nil, "order: the Layout band is added")
    check(bandA ~= nil, "order: ...and the Appearance band")
    check(bandM ~= nil, "order: ...and the Permanent Mover band")
    check(bandL and bandA and bandL < bandA, "order: Layout comes before Appearance")
    check(bandA and bandM and bandA < bandM, "order: ...and Appearance before the mover")

    -- ...and they are the LAST three, which is the whole of "the popout layout
    -- adds nothing else": everything before them is inside a classicLayout arm.
    local n = #adds
    check(bandL == n - 2 and bandA == n - 1 and bandM == n,
          "order: the three bands are the last three Adds on the page")

    -- The Add trio is guarded, so the classic layout adds none of them.
    check(SRC:find("if not classicLayout then\n            Add(layoutBand, nil, \"both\")", 1, true) ~= nil,
          "order: the bands are added only in the popout layout")

    -- ☠ NOTHING IS LEFT IN A NUMBERED COLUMN IN THE POPOUT LAYOUT, and after this
    -- sweep that is a stronger claim than it was: EVERY numbered Add on the page
    -- belongs to a box the classic branch builds. Stated as a roster rather than a
    -- count so a new group added at column 1 outside a classicLayout arm fails
    -- here rather than shipping as the one narrow box on a page of plates.
    local CLASSIC_ONLY = {
        appearanceGroup = true, frameFadeGroup = true, permMoverGroup = true,
    }
    for _, e in ipairs(LAYOUT_ROWS) do CLASSIC_ONLY[e[1]] = true end
    for _, e in ipairs(adds) do
        if e.col == "1" or e.col == "2" then
            check(CLASSIC_ONLY[e.name] == true,
                  "order: " .. e.name .. " is added at a numbered column, so it must be classic-only")
        end
    end

    -- ...and every one of the ten IS added at a numbered column, which is what
    -- says the classic page still has all of them.
    for _, e in ipairs(LAYOUT_ROWS) do
        check(indexOf(e[1], "1") ~= nil or indexOf(e[1], "2") ~= nil,
              "order: " .. e[1] .. " is still added as a classic box")
    end

    -- ---- the classic column assignments, unchanged -------------------
    -- The one thing this pass was not allowed to move. Group Display Order is
    -- column 2 and everything else in the layout chain is column 1, exactly as
    -- before -- which is also why the BAND's row order is the page's old source
    -- order rather than a tidied one (Group Layout and Flat Grid would read
    -- better adjacent, and moving one past Group Visibility would have moved its
    -- classic Add with it).
    local CLASSIC_COL = {
        sizeGroup = "1", layoutGroup = "1", raidModeGroup = "1",
        groupLayoutGroup = "1", groupVisGroup = "1", groupOrderGroup = "2",
        flatGridGroup = "1", appearanceGroup = "2", frameFadeGroup = "2",
        permMoverGroup = "2",
    }
    for name, col in pairs(CLASSIC_COL) do
        check(indexOf(name, col) ~= nil,
              "order: the classic " .. name .. " still goes to column " .. col)
    end

    -- ---- and the band ROW order is the source order ------------------
    -- A row is mounted with layoutBand:AddWidget, so the order of those calls IS
    -- the band's order. Read as positions so a reordering fails here.
    local prev = 0
    for _, e in ipairs(LAYOUT_ROWS) do
        local at = page:find('label   = L["' .. e[2] .. '"]', 1, true)
                or page:find('label    = L["' .. e[2] .. '"]', 1, true)
        check(at ~= nil, "band order: the " .. e[2] .. " row is declared")
        check(at == nil or at > prev, "band order: ...after the row above it")
        prev = at or prev
    end
end

-- ============================================================
-- 4. THE SEVEN CONVERSIONS
--
-- One builder per group, mounted TWICE -- into the classic box and into the
-- popout pane -- which is what makes "classic is identical to main" a structural
-- fact rather than a promise. Each is checked the way Frame Fade and Permanent
-- Mover are above: the widget census it had inline, the declared count against
-- what the builder mounts, and the row's own declarations.
-- ============================================================

-- What every converted group on this page has in common, so the seven blocks
-- below only have to state what is true of themselves.
local function checkShared(builder, rowLabel, wide)
    -- ONE builder, BOTH layouts. Three occurrences: the declaration and the two
    -- mounts.
    local calls = 0
    for _ in SRC:gmatch(builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, rowLabel .. ": declared once, mounted twice -- classic box and popout pane")

    -- The classic branch builds the box it always did, at the literal every other
    -- classic-only box on this page uses.
    local classicBox = SRC:match("local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)\n%s*%1:AddWidget%(GUI:CreateHeader%(self%.child, L%[\"" .. rowLabel:gsub("%p", "%%%0") .. "\"%]%)")
    check(classicBox ~= nil, rowLabel .. ": the classic 280 box is built with its own header")

    -- The row is a member of the Layout band and carries the page's eager-holder
    -- discipline: content built at page-build time, keys claimed off it, the
    -- amber tick wired to those keys.
    local opts = rowOpts(rowLabel)
    check(opts ~= "" and opts:find("build", 1, true) ~= nil,
          rowLabel .. ": the row is handed a pre-built mount")
    check(opts:find("window   = DF.GUIFrame", 1, true) ~= nil
       or opts:find("window  = DF.GUIFrame", 1, true) ~= nil,
          rowLabel .. ": ...docked outside the settings window")
    check(opts:find("clipTo", 1, true) ~= nil,
          rowLabel .. ": ...and clipped by the page's own scroll frame, not the window")
end

-- 4.1 FRAME SIZE -- the first primary to go behind a click.
local FRAME_SIZE = {
    { "slider", "Frame Width",   "frameWidth",   55 },
    { "slider", "Frame Height",  "frameHeight",  55 },
    { "slider", "Frame Padding", "framePadding", 55 },
    { "slider", "Frame Scale",   "frameScale",   55 },
    { "slider", "Frame Spacing", "frameSpacing", 55 },
}
do
    local body = builderBody("BuildFrameSizeGroup")
    checkCensus(census(body), FRAME_SIZE, "frame size")
    checkShared("BuildFrameSizeGroup", "Frame Size")

    local declared = tonumber(SRC:match("local FRAME_SIZE_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "frame size: the page declares the row's count in one place")
    eq(declared, #FRAME_SIZE, "frame size: ...and it is what the builder mounts")

    local opts = rowOpts("Frame Size")
    check(opts:find("toggle", 1, true) == nil,
          "frame size: the row declares no toggle -- there is no 'am I doing anything' here")
    check(opts:find("summary%s*=%s*FrameSizeSummary") ~= nil,
          "frame size: ...it does declare a summary")
    check(opts:find("count%s*=%s*FRAME_SIZE_COUNT") ~= nil,
          "frame size: ...and the declared count, not a literal")

    -- The summary prints the size with an ASCII x, for the reason the border
    -- summary spells out L["Alpha"]: the settings font has no multiplication
    -- sign, and the Permanent Mover row already prints its handle size this way.
    local sum = SRC:match("local function FrameSizeSummary%(d%)(.-)local FRAME_SIZE_COUNT")
    check(sum ~= nil, "frame size: the summary is a named function on the page")
    if sum then
        check(sum:find('"%%dx%%d"') ~= nil, "frame size: ...printing WxH in ASCII")
        check(sum:find("\\195\\151", 1, true) == nil, "frame size: ...and never the multiplication sign")
        -- The other three items appear only when they are doing something, and
        -- "doing something" is asked of the defaults ENGINE rather than compared
        -- against a number copied out of Config.lua.
        check(sum:find("D:IsModified(d, key)", 1, true) ~= nil,
              "frame size: ...and the conditional items ask the defaults engine")
        for _, k in ipairs({ "frameScale", "framePadding", "frameSpacing" }) do
            check(sum:find('changed("' .. k .. '")', 1, true) ~= nil,
                  "frame size: ..." .. k .. " is conditional on being non-default")
        end
        -- Four items at most, which is the convention: the size plus three.
        local items = 0
        for _ in sum:gmatch("parts%[#parts %+ 1%]") do items = items + 1 end
        eq(items, 4, "frame size: at most four items, per the summary convention")
    end
end

-- 4.2 LAYOUT DIRECTION -- three dropdowns, at most two ever visible.
local LAYOUT_DIR = {
    { "dropdown", "Growth Direction", "growDirection", 55 },
    { "dropdown", "Growth Direction", "growDirection", 55 },
    { "dropdown", "Frames Grow From", "growthAnchor",  55 },
}
do
    local body = builderBody("BuildLayoutDirectionGroup")
    checkCensus(census(body), LAYOUT_DIR, "layout direction")
    checkShared("BuildLayoutDirectionGroup", "Layout Direction")

    local declared = tonumber(SRC:match("local LAYOUT_DIR_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "layout direction: the page declares the row's count in one place")
    eq(declared, #LAYOUT_DIR, "layout direction: ...and it is what the builder mounts")

    -- ☠ THE TWO INVERTED LABEL MAPS SURVIVED THE MOVE. This is the regression the
    -- ☠☠ note above the dropdowns exists to prevent, and moving them into a
    -- builder is exactly the kind of edit that would quietly unify them.
    --
    -- ⚠ THEY LIVE AT PAGE SCOPE NOW, IN ONE FUNCTION, because the row HOISTS this
    -- dropdown onto its own plate and a third copy of a map whose whole hazard is
    -- that it has an inverse would be the same bug one edit away. So the claim is
    -- read where the maps are, and the builder is checked for having no copy of
    -- its own -- which is strictly more than the old body search said.
    local maps = SRC:match("local function GrowDirectionOptions%(grouped%)(.-)\n        end")
    check(maps ~= nil, "layout direction: the two dialects are one page-scope function")
    if maps then
        check(maps:find('HORIZONTAL = L["Columns"], VERTICAL = L["Rows"]', 1, true) ~= nil,
              "layout direction: the grouped-raid map is unchanged")
        check(maps:find('HORIZONTAL = L["Rows"], VERTICAL = L["Columns"]', 1, true) ~= nil,
              "layout direction: ...and the flat/party map is still its inverse")
    end
    check(body:find('HORIZONTAL = L["', 1, true) == nil,
          "layout direction: ...with no copy of either left in the builder")
    check(body:find("GrowDirectionOptions(false)", 1, true) ~= nil
      and body:find("GrowDirectionOptions(true)", 1, true) ~= nil,
          "layout direction: the builder asks for both dialects by name")

    -- ☠ THE FOOTER MUST NOT REBUILD THE PAGE. OnGrowthDirectionChanged defers a
    -- GUI:RefreshCurrentPage, and Hold: Defaults releases on the footer button's
    -- own mouse-up -- a rebuild between the press and the release would retire
    -- that button and leave the user's settings sitting at the defaults with
    -- nothing left to restore them.
    local apply = SRC:match("local function ApplyLayoutDirection%(%)(.-)\n            end")
    check(apply ~= nil, "layout direction: the group's apply is a named function")
    if apply then
        check(apply:find("RefreshCurrentPage", 1, true) == nil,
              "layout direction: ...and it never rebuilds the page")
    end
    check(SRC:find("WireFooter(dirRow, ApplyLayoutDirection)", 1, true) ~= nil,
          "layout direction: ...which is what the footer runs")

    local opts = rowOpts("Layout Direction")
    check(opts:find("toggle", 1, true) == nil,
          "layout direction: the row declares no toggle")
    check(opts:find("summary%s*=%s*LayoutDirectionSummary") ~= nil,
          "layout direction: ...it does declare a summary")
    check(opts:find("count%s*=%s*LAYOUT_DIR_COUNT") ~= nil,
          "layout direction: ...and the declared count, not a literal")

    -- The summary reads the table it is handed, not the build-time edge words.
    local sum = SRC:match("local function LayoutDirectionSummary%(d%)(.-)\n            end")
    check(sum ~= nil, "layout direction: the summary is a named function on the page")
    if sum then
        check(sum:find("MAIN_START", 1, true) == nil and sum:find("CROSS_START", 1, true) == nil,
              "layout direction: ...and never the build-time edge words, which go stale")
        check(sum:find("d.raidUseGroups", 1, true) ~= nil,
              "layout direction: ...it picks the dialect the dropdown would")
    end
end

-- 4.3 RAID LAYOUT MODE -- the one row whose TOGGLE is the group.
local RAID_MODE = {
    { "checkbox", "Use Group-Based Layout", "raidUseGroups", 30 },
    { "label",    "Enabled: Players organized by raid groups (1-8).\\nDisabled: All players in one flat grid.", "(none)", 45 },
}
do
    local body = builderBody("BuildRaidModeGroup")
    checkCensus(census(body), RAID_MODE, "raid layout mode")
    checkShared("BuildRaidModeGroup", "Raid Layout Mode")

    check(body:find("if not tools2.hoistToggle then") ~= nil,
          "raid layout mode: the checkbox is skipped when the row has hoisted it")

    local opts = rowOpts("Raid Layout Mode")
    check(opts:find('toggle%s*=%s*{%s*key%s*=%s*"raidUseGroups"%s*}') ~= nil,
          "raid layout mode: the row's tick is the group's own key")
    check(opts:find("offText%s*=%s*L%[\"Flat\"%]") ~= nil,
          "raid layout mode: ...and OFF is spelled Flat, because both states are a layout")
    check(opts:find("count", 1, true) == nil,
          "raid layout mode: no count -- there are no controls behind this row, only a blurb")

    -- ☠ NO FOOTER. Reset Group and Hold: Defaults write through the generic
    -- engine, and raidUseGroups cannot be written that way: flipping it has to
    -- invert growDirection at the same moment or the raid silently re-orients,
    -- and that compensation is only correct for a deliberate toggle.
    check(SRC:find("WireFooter(raidModeRow", 1, true) == nil,
          "raid layout mode: the row has no footer, because its key cannot be reset generically")
    check(SRC:find("ClaimKeys(raidModeRow", 1, true) == nil,
          "raid layout mode: ...and claims nothing, for the same reason")

    -- The hoisted toggle is re-registered with search under its own label and key.
    check(SRC:find('RegisterHoistedToggle(raidModeRow, L["Use Group-Based Layout"], "raidUseGroups"', 1, true) ~= nil,
          "raid layout mode: the hoisted toggle keeps its search entry")

    -- ☠ THE REBUILD IS DEFERRED IN THE POPOUT LAYOUT AND IMMEDIATE IN CLASSIC.
    -- The row's write path runs onToggle and THEN row.Refresh() on the row it
    -- just wrote through, so a synchronous rebuild would leave that Refresh
    -- landing on a retired frame.
    check(SRC:find("local function OnRaidModeToggle()", 1, true) ~= nil,
          "raid layout mode: the popout commit is a named function")
    local commit = SRC:match("local function OnRaidModeToggle%(%)(.-)\n            end")
    check(commit ~= nil and commit:find("C_Timer.After(0", 1, true) ~= nil,
          "raid layout mode: ...and its page rebuild is deferred a frame")
    check(body:find("if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end", 1, true) ~= nil,
          "raid layout mode: ...while the classic checkbox rebuilds immediately, as it always did")

    -- The apply is shared by both, so the growDirection compensation cannot end
    -- up in one layout and not the other.
    check(SRC:find("local function ApplyRaidUseGroups()", 1, true) ~= nil,
          "raid layout mode: the toggle's work is named once for both layouts")
    local apply = SRC:match("local function ApplyRaidUseGroups%(%)(.-)\n        end")
    check(apply ~= nil and apply:find('db.growDirection = (db.growDirection == "HORIZONTAL") and "VERTICAL" or "HORIZONTAL"', 1, true) ~= nil,
          "raid layout mode: ...including the growDirection compensation")

    -- RAID ONLY, on the ROW, exactly as it was on the box.
    check(SRC:find('raidModeRow.hideOn = function() return GUI.SelectedMode ~= "raid" end', 1, true) ~= nil,
          "raid layout mode: the row is raid-only, the same predicate the box carried")
end

-- 4.4 GROUP LAYOUT SETTINGS -- and the two named refreshes that had to move.
local GROUP_LAYOUT = {
    { "label",    "(none)",              "(none)",              25 },
    { "slider",   "Group Spacing",       "raidGroupSpacing",    55 },
    { "slider",   "Wrap Spacing",        "raidRowColSpacing",   55 },
    { "slider",   "Groups Before Wrap",  "raidGroupsPerRow",    55 },
    { "dropdown", "Center Mode",         "raidGroupCenterMode", 55 },
    { "dropdown", "Players Grow From",   "raidPlayerAnchor",    55 },
}
do
    local body = builderBody("BuildGroupLayoutGroup")
    -- ⚠ SIX, NOT SEVEN. The census reader knows the six shared FACTORIES; the
    -- corner picker is CreateAnchorGrid and is checked by name below. It is still
    -- a control the pane mounts, which is why the declared count is seven.
    checkCensus(census(body), GROUP_LAYOUT, "group layout")
    checkShared("BuildGroupLayoutGroup", "Group Layout Settings")
    check(body:find('GUI:CreateAnchorGrid(parent, L["Groups Anchor"], db, "raidGroupAnchor", "raidGroupRowGrowth"', 1, true) ~= nil,
          "group layout: the corner picker is mounted, on both its keys")

    local declared = tonumber(SRC:match("local GROUP_LAYOUT_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "group layout: the page declares the row's count in one place")
    eq(declared, #GROUP_LAYOUT + 1, "group layout: ...the census plus the corner picker")

    -- ☠ THE TWO NAMED REFRESHES ARE INSIDE THE BUILDER NOW, and that is the whole
    -- of the sweep-1 finding. UpdateFramesAndGates re-asks the GROUP for a state
    -- pass and UpdatePinMainGroup re-asks the anchor GRID for a repaint; both used
    -- to close over the page-level box, so left outside they would have gone on
    -- refreshing the classic branch's object -- or, in the popout layout, the
    -- eagerly built holder rather than whichever instance the user has open.
    check(body:find("local function UpdateFramesAndGates()", 1, true) ~= nil,
          "group layout: the gate refresh is declared inside the builder")
    check(body:find("if group.RefreshChildStates then group:RefreshChildStates() end", 1, true) ~= nil,
          "group layout: ...and refreshes the group it was handed, not a captured one")
    check(body:find("groupLayoutGroup", 1, true) == nil,
          "group layout: ...with no reference left to the page-level box")
    check(body:find("local function UpdatePinMainGroup()", 1, true) ~= nil,
          "group layout: the pin commit is declared inside the builder too")
    check(body:find("if groupAnchorGrid and groupAnchorGrid.Refresh then groupAnchorGrid:Refresh() end", 1, true) ~= nil,
          "group layout: ...refreshing this pane's own picker")

    local opts = rowOpts("Group Layout Settings")
    check(opts:find("toggle", 1, true) == nil, "group layout: the row declares no toggle")
    check(opts:find("count%s*=%s*GROUP_LAYOUT_COUNT") ~= nil,
          "group layout: ...and the declared count, not a literal")
    check(SRC:find('groupLayoutRow.hideOn = function() return GUI.SelectedMode ~= "raid" or not db.raidUseGroups end', 1, true) ~= nil,
          "group layout: the row carries the box's own raid+groups predicate")
end

-- 4.5 GROUP VISIBILITY -- eight ticks, and the only two-track pane on the page.
local GROUP_VIS = {
    { "label",    "Choose which groups to display.", "(none)", 25 },
    { "checkbox", "Group",                           "(none)", 25 },
}
do
    local body = builderBody("BuildGroupVisGroup")
    -- ⚠ TWO ENTRIES FOR NINE WIDGETS: the eight ticks are ONE textual call inside
    -- `for i = 1, 8`. The declared count below is what the pane actually mounts.
    checkCensus(census(body), GROUP_VIS, "group visibility")
    checkShared("BuildGroupVisGroup", "Group Visibility")
    check(body:find("for i = 1, 8 do", 1, true) ~= nil,
          "group visibility: the ticks are a loop over the eight groups")

    local declared = tonumber(SRC:match("local GROUP_VIS_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "group visibility: the page declares the row's count in one place")
    eq(declared, 9, "group visibility: ...the hint plus eight ticks")

    -- The pane takes two tracks; the classic box does not, and neither does any
    -- other pane on this page.
    check(SRC:find("end, 2)", 1, true) ~= nil,
          "group visibility: the pane is built with a second track")
    check(SRC:find("groupVisHintLabel.fullRow = true", 1, true) ~= nil,
          "group visibility: ...so the blurb takes the whole plate rather than one track")

    -- ☠ THE REAL KEY IS NAMED TO ClaimKeys. The eight ticks are custom-get/set
    -- over ONE table setting and each stamps a per-index override key the profile
    -- does not ship, so the walk alone would leave the row with eight keys the
    -- defaults engine cannot answer for: no amber tick, and a Reset Group that
    -- wrote nothing while saying it had.
    check(SRC:find('tools.ClaimKeys(groupVisRow, groupVisContent, { "raidGroupVisible" })', 1, true) ~= nil,
          "group visibility: the row claims the table key its ticks stand for")
    -- ⚠ THE DOOR IS READ WHERE IT NOW LIVES. The claimer moved to the shared
    -- helper with the rest of the machinery; the claim is unchanged -- there IS a
    -- third argument for keys the walk cannot see, and this page is the one that
    -- uses it.
    check(options_file_source("GUI/Controls.lua")
              :find("local function ClaimKeys(row, group, extra)", 1, true) ~= nil,
          "group visibility: ...through the shared claimer's own extra-keys door")

    check(SRC:find('groupVisRow.hideOn = function() return GUI.SelectedMode ~= "raid" end', 1, true) ~= nil,
          "group visibility: the row is raid-only, the same predicate the box carried")
end

-- 4.6 GROUP DISPLAY ORDER -- the drag list, in a pane.
local GROUP_ORDER = {
    { "label",    "Drag to reorder groups. Top = first.", "(none)",               25 },
    { "checkbox", "My Group First",                       "raidPlayerGroupFirst", 25 },
}
do
    local body = builderBody("BuildGroupOrderGroup")
    checkCensus(census(body), GROUP_ORDER, "group order")
    checkShared("BuildGroupOrderGroup", "Group Display Order")
    check(body:find('GUI:CreateGroupOrderList(parent, db, "raidGroupDisplayOrder"', 1, true) ~= nil,
          "group order: the drag list is mounted into the pane's own parent")

    local declared = tonumber(SRC:match("local GROUP_ORDER_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "group order: the page declares the row's count in one place")
    eq(declared, #GROUP_ORDER + 1, "group order: ...the census plus the drag list")

    -- ☠ THE LIST HAS TO REPAINT AFTER A WRITE IT DID NOT MAKE. It is bound to a
    -- TABLE setting and the row wires Reset Group / Hold: Defaults, so without the
    -- value-sweep alias a reset moved the raid and left the eight rows showing the
    -- order the user had before it. Checked in the factory rather than the page,
    -- which is where the gap was.
    local controls = options_file_source("GUI/Controls.lua")
    local list = controls:match("function GUI:CreateGroupOrderList(.-)\nend\n")
    check(list ~= nil, "group order: the factory is locatable")
    if list then
        check(list:find("container.refreshValue = container.Refresh", 1, true) ~= nil,
              "group order: ...and answers to the group-wide value sweep")
    end

    check(SRC:find('groupOrderRow.hideOn = function() return GUI.SelectedMode ~= "raid" or not db.raidUseGroups end', 1, true) ~= nil,
          "group order: the row carries the box's own raid+groups predicate")
end

-- 4.7 FLAT GRID SETTINGS -- the other side of raidUseGroups.
local FLAT_GRID = {
    { "label",    "All players in a unified grid. Sorting applies raid-wide.", "(none)",                    25 },
    { "slider",   "(none)",              "raidPlayersPerRow",         55 },
    { "dropdown", "Grid Alignment",      "raidFlatGrowthAnchor",      55 },
    { "dropdown", "(none)",              "raidFlatColumnAnchor",      55 },
    { "dropdown", "Players Grow From",   "raidFlatFrameAnchor",       55 },
    { "slider",   "Horizontal Spacing",  "raidFlatHorizontalSpacing", 55 },
    { "slider",   "Vertical Spacing",    "raidFlatVerticalSpacing",   55 },
}
do
    local body = builderBody("BuildFlatGridGroup")
    -- ⚠ TWO "(none)" LABELS, and they are not omissions: those two controls are
    -- labelled from a VARIABLE that swaps with the growth direction (Players Per
    -- Row / Per Column, Rows / Columns Grow From), so there is no L key at the
    -- call site to read.
    checkCensus(census(body), FLAT_GRID, "flat grid")
    checkShared("BuildFlatGridGroup", "Flat Grid Settings")

    local declared = tonumber(SRC:match("local FLAT_GRID_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "flat grid: the page declares the row's count in one place")
    eq(declared, #FLAT_GRID, "flat grid: ...and it is what the builder mounts")

    check(SRC:find('flatGridRow.hideOn = function() return GUI.SelectedMode ~= "raid" or db.raidUseGroups end', 1, true) ~= nil,
          "flat grid: the row carries the box's own raid+flat predicate")

    -- ...and the two mode rows are exact opposites, which is what keeps exactly
    -- one of them in the band at a time.
    check(SRC:find("or not db.raidUseGroups end", 1, true) ~= nil
      and SRC:find("or db.raidUseGroups end", 1, true) ~= nil,
          "flat grid: ...the inverse of the grouped row's, so the two never coexist")
end

-- ============================================================
-- 5. ONE WIDTH, AND NOTHING LEFT INLINE
--
-- The width batch gave every stay-inline box the page's usable width and a
-- two-track interior so the extra width bought a second control. There are no
-- stay-inline boxes any more, so the page-local INLINE_* names that batch
-- introduced are gone with them -- what STAYS is the kit half (Sections'
-- opts.bandStyle and opts.innerColumns), which other pages have yet to use.
--
-- What is pinned here is what replaced them: three bands, all built at the same
-- expression, and ten classic-only 280 boxes.
-- ============================================================
do
    local page = framePage()

    -- ---- the INLINE_* names are gone from this page ------------------
    -- Named individually rather than as a prefix scan, so this reads as a list of
    -- things that were removed rather than as a ban on the letters.
    for _, name in ipairs({ "INLINE_BOX", "INLINE_GRID", "INLINE_W", "INLINE_COL_1", "INLINE_COL_2" }) do
        check(page:find(name, 1, true) == nil,
              "inline: " .. name .. " is gone -- there are no stay-inline boxes left")
    end
    -- ...and the SKIN is gone with them: a band's rows are the surface, so no box
    -- on this page asks for the plate treatment any more.
    check(page:find("bandStyle", 1, true) == nil,
          "inline: and nothing on the page asks for the band skin, because nothing is a box in the band's company")

    -- ---- the three bands, at ONE width ------------------------------
    -- ⚠ THE THREE COPIES OF ONE EXPRESSION ARE GONE, which is exactly what the
    -- note that used to stand here asked for and could not take: it was blocked on
    -- the page owning its own machinery, and it no longer does. All three bands
    -- ask tools.BandWidth() -- ONE name, resolved in one place -- and the
    -- expression behind that name is pinned by test_popout_page_tools, where it
    -- now lives, rather than retyped here.
    --
    -- Pinned as name-plus-call rather than as a bare count, so a band that kept
    -- the width but lost the chromeless skin (or vice versa) still fails.
    local BAND = "GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })"
    local seen, from = 0, 1
    while true do
        local s = page:find(BAND, from, true)
        if not s then break end
        seen, from = seen + 1, s + 1
    end
    -- Three: the Layout band, the Appearance band and the mover band. Any one of
    -- them drifting is the page going back to more than one width.
    eq(seen, 3, "width: all three bands ask for the width the same way")
    -- ...and NOTHING on the page computes it inline any more, which is the half
    -- the count above cannot say on its own.
    check(page:find("GUI.PageUsableWidth(GUI.PageChildWidth(", 1, true) == nil,
          "width: ...through the shared helper, with no copy of the expression left on the page")

    -- Each band is chromeless, because its ROWS are the surface -- and each is one
    -- of the three names the page is allowed to build at that width.
    for _, band in ipairs({ "layoutBand", "appearanceGroup", "permMoverBand" }) do
        check(page:find(band .. " = " .. BAND, 1, true) ~= nil,
              "width: the " .. band .. " band is chromeless, at the shared width")
    end

    -- The Layout band carries a HEADER and the mover band does not, and both are
    -- the same rule: a header names a SECTION, and a band of one row whose label
    -- already says the words does not need one said twice.
    check(page:find('layoutBand:AddWidget(GUI:CreateHeader(self.child, L["Layout"]), 40)', 1, true) ~= nil,
          "width: the Layout band names itself above its rows")
    check(page:find("permMoverBand:AddWidget(GUI:CreateHeader", 1, true) == nil,
          "width: ...and the one-row mover band still does not")

    -- ---- the classic boxes, all ten of them -------------------------
    local bare = 0
    for _ in page:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 10, "width: ten bare 280 boxes -- the seven converted here plus the sweep's three")

    -- ---- the interior grid is per ROW, not per page -----------------
    -- PopoutContent takes the track count as an argument and passes it straight
    -- to the group, so a pane of sliders stays one track while the pane of eight
    -- one-word checkboxes takes two.
    --
    -- ⚠ READ OUT OF THE SHARED HELPER, not the page: PopoutContent moved to
    -- Controls.lua with the rest of the machinery. The claim is untouched -- the
    -- track count is a per-ROW argument and not a per-page one -- so it is checked
    -- where the argument now lives, and the page's own half (exactly one blurb
    -- opting out of a track) stays below.
    local controls = options_file_source("GUI/Controls.lua")
    check(controls:find("local function PopoutContent(buildInto, innerColumns)", 1, true) ~= nil,
          "grid: the pane's track count is a per-row argument")
    check(controls:find("innerColumns = innerColumns }", 1, true) ~= nil,
          "grid: ...handed to the group rather than restated")
    local marks = 0
    for _ in page:gmatch("%.fullRow%s*=%s*true") do marks = marks + 1 end
    eq(marks, 1, "grid: exactly one blurb opts out of a track, in the one two-track pane")
end

-- ============================================================
-- 6. THE FOOTER STRIP, AND WHAT THIS PAGE HOISTS
--
-- The popout sweep put every setting behind a click and the feedback was "less
-- overwhelming but much harder to find what ur looking for". So this page --
-- and, for now, only this page -- puts its commonly-changed controls back ON the
-- plate, named, and moves the way in to a footer strip so that a row WITH
-- hoisted controls and a row without still open the same way, from the same
-- place.
--
-- ☠ A HOISTED CONTROL IS THE PANEL'S OWN SETTING SHOWN TWICE, NEVER A COPY OF
-- DATA. Which makes this section's real job arithmetic rather than inventory:
-- every hoisted key must be one the row's OWN builder still mounts, and every
-- hoisted name must be the string that builder labels it with. If either drifts,
-- the plate is showing a second setting that merely looks like the first.
--
-- What this can and cannot see: source only, like the rest of this file. That
-- the two widgets end up bound to one table is driven in
-- test_popout_page_tools.lua; that the plate lays them out is driven in
-- test_popout_row.lua.
-- ============================================================

-- Every popout row this page declares, by the variable it is assigned to. Read
-- out of the source rather than listed, so a row added without a strip fails
-- here rather than shipping as the one row on the page with its cog somewhere
-- else.
local function pageRows()
    local out = {}
    for var in framePage():gmatch("local ([%w_]+) = %w+:AddWidget%(GUI:CreatePopoutRow%(") do
        out[#out + 1] = var
    end
    return out
end

-- One row's `tools.RegisterHoistedToggle(<row>, { ... })` block, or nil.
local function hoistBlock(rowVar)
    local page = framePage()
    local a = page:find("tools.RegisterHoistedToggle(" .. rowVar .. ", {", 1, true)
    if not a then return nil end
    local b = page:find("\n            })", a, true)
    return page:sub(a, (b or a) + 16)
end

-- The declarations inside one, as { name, kind, key, gated }. Newlines are
-- collapsed first so a declaration split over three lines reads as one, and each
-- chunk runs to the START OF THE NEXT -- the same reader shape the widget census
-- at the top of this file uses, and for the same reason: a nested brace would
-- defeat a balanced match.
local function hoistEntries(block)
    local out = {}
    if not block then return out end
    local flat = block:gsub("%s+", " ")
    local starts, i = {}, 1
    while true do
        local s = flat:find("{ name = ", i, true)
        if not s then break end
        starts[#starts + 1] = s
        i = s + 1
    end
    for n, s in ipairs(starts) do
        local chunk = flat:sub(s, (starts[n + 1] and starts[n + 1] - 1) or #flat)
        out[#out + 1] = {
            name  = chunk:match('name = L%["([^"]+)"%]'),
            kind  = chunk:match('kind = "(%a+)"'),
            key   = chunk:match('key = "([%w_]+)"'),
            gated = chunk:find("visible =", 1, true) ~= nil,
        }
    end
    return out
end

do
    local page = framePage()
    local rows = pageRows()
    check(#rows == 11, "strip: the page declares its eleven rows (" .. #rows .. ")")

    -- ---- every row gets the strip -----------------------------------
    -- The whole of "the way in is in the same place on every row". A row that
    -- hoists nothing gets it too, with its cog and its count moved onto it.
    for _, var in ipairs(rows) do
        local a = page:find("local " .. var .. " = ", 1, true)
        local b = page:find("}))", a or 1, true)
        local opts = (a and b) and page:sub(a, b + 2) or ""
        check(opts:find("footerStrip = true", 1, true) ~= nil,
              "strip: " .. var .. " declares the footer strip")
    end

    -- ---- and NOTHING ELSE ON ANY OTHER PAGE DOES --------------------
    -- Stated here rather than in the all-rows rule because it is this page's
    -- claim: the sweep reaches the others once this one has been seen in game.
    local TOC = options_file_source("DandersFrames_Options.toc")
    local elsewhere = {}
    for name in TOC:gmatch("GUI\\(Pages\\[%w_]+%.lua)") do
        local path = "GUI/" .. name:gsub("\\", "/")
        local src = options_file_source(path)
        local n = 0
        for _ in src:gmatch("footerStrip = true") do n = n + 1 end
        if path ~= "GUI/Pages/Options.lua" and n > 0 then
            elsewhere[#elsewhere + 1] = path .. " (" .. n .. ")"
        end
    end
    eq(#elsewhere, 0,
       "strip: no other page has moved yet -- " .. table.concat(elsewhere, ", "))
    -- ...and inside THIS file, only the Frame page: Options.lua carries a dozen
    -- other pages, and eleven is exactly the roster above.
    local total = 0
    for _ in SRC:gmatch("footerStrip = true") do total = total + 1 end
    eq(total, #rows, "strip: ...and only the Frame page's rows inside this file")

    -- ---- which rows hoist, and what --------------------------------
    -- ☠ EVERY NAME IS THE PANEL'S OWN L KEY AND EVERY KEY IS ONE THE PANE STILL
    -- MOUNTS, checked against the census tables at the top of this file rather
    -- than against a second list -- so a hoist that drifted from the control it
    -- is meant to be a second view of fails here.
    local HOISTS = {
        { row = "sizeRow", census = FRAME_SIZE, want = {
            { "Frame Width",  "slider",   "frameWidth",          false },
            { "Frame Height", "slider",   "frameHeight",         false },
        } },
        { row = "dirRow", census = LAYOUT_DIR, want = {
            { "Growth Direction", "dropdown", "growDirection",   false },
        } },
        { row = "moverRow", census = PERM_MOVER, want = {
            { "Handle Width",  "slider", "permanentMoverWidth",  true },
            { "Handle Height", "slider", "permanentMoverHeight", true },
        } },
    }

    local hoistedRows = 0
    for _, var in ipairs(rows) do
        if hoistBlock(var) then hoistedRows = hoistedRows + 1 end
    end
    -- Three from the table above plus the Border row, whose two controls come
    -- from the shared border helper rather than from a builder census here.
    eq(hoistedRows, 4, "hoist: four of the eleven rows hoist anything at all")

    for _, spec in ipairs(HOISTS) do
        local got = hoistEntries(hoistBlock(spec.row))
        eq(#got, #spec.want, "hoist: " .. spec.row .. " hoists the declared number")
        local seen = {}
        for i, w in ipairs(spec.want) do
            local g = got[i]
            if not g then
                check(false, "hoist: " .. spec.row .. " is missing " .. w[1])
            else
                eq(g.name, w[1], "hoist: " .. spec.row .. " control " .. i .. " is named")
                eq(g.kind, w[2], "hoist: ..." .. w[1] .. " is the kind the panel draws")
                eq(g.key,  w[3], "hoist: ..." .. w[1] .. " is bound to the panel's key")
                eq(g.gated, w[4], "hoist: ..." .. w[1] .. "'s gate is as declared")

                -- ONE WIDGET PER KEY ON THE PLATE. A key declared twice would be
                -- two tracks writing the same setting, which is not "shown twice"
                -- -- it is two of the same thing on one row.
                check(not seen[g.key], "hoist: " .. spec.row .. " binds " .. tostring(g.key) .. " once")
                seen[g.key] = true

                -- ...and the KEY and the NAME both come from the row's own pane.
                local found
                for _, c in ipairs(spec.census) do
                    if c[3] == w[3] then found = c end
                end
                check(found ~= nil,
                      "hoist: " .. w[1] .. " is a control the pane still mounts")
                if found then
                    eq(w[1], found[2],
                       "hoist: ...under the very L key the pane labels it with")
                    eq(w[2], found[1], "hoist: ...and the same kind of control")
                end
            end
        end
    end

    -- ---- the BORDER row, whose controls come from the shared helper --
    -- Its pane is built by GUI:CreateBorderControls, so there is no census table
    -- here to check against; the claim is made against the HELPER's own source
    -- instead, which is the same claim one file along.
    local bgot = hoistEntries(hoistBlock("borderRow"))
    eq(#bgot, 2, "border: the row hoists two controls")
    eq(bgot[1].name, "Border Thickness", "border: the thickness slider")
    eq(bgot[1].key,  "frameBorderSize",  "border: ...on the prefixed size key")
    eq(bgot[2].name, "Border Style",     "border: and the style dropdown")
    eq(bgot[2].key,  "frameBorderStyle", "border: ...on the prefixed style key")
    check(bgot[1].gated and bgot[2].gated,
          "border: both gated -- a control for a border that is OFF is never hoisted")
    local widgets = options_file_source("GUI/SettingsWidgets.lua")
    check(widgets:find('L["Border Thickness"], sizeMin, sizeMax, sizeStep', 1, true) ~= nil,
          "border: ...and the helper labels its own slider with that same key")
    check(widgets:find('GUI:CreateDropdown(parent, L["Border Style"],', 1, true) ~= nil,
          "border: ...and its dropdown with the other")

    -- ☠ ONE OPTION MAP, ASKED FOR RATHER THAN RETYPED. The hoisted dropdown and
    -- the pane's own dropdown read the SAME helper, so a fourth border style
    -- appears in both or in neither -- the drift the two growth-direction maps
    -- carry a ☠☠ about, one control along.
    check(widgets:find("function GUI:BorderStyleOptions(includeGradient)", 1, true) ~= nil,
          "border: the style map is a named helper")
    check(widgets:find("local styleOptions = GUI:BorderStyleOptions(include.gradient)", 1, true) ~= nil,
          "border: ...which the pane's own dropdown reads")
    check(page:find("options = GUI:BorderStyleOptions(true)", 1, true) ~= nil,
          "border: ...and so does the hoisted one, rather than a copy of it")
    -- The same rule for the write: switching to Texture with no texture picked
    -- seeds one, and it has to happen whichever of the two widgets was dragged.
    check(widgets:find("function GUI:SeedBorderTexture(dbTable, prefix)", 1, true) ~= nil,
          "border: the Texture seeding is a named helper too")
    check(widgets:find("GUI:SeedBorderTexture(dbTable, prefix)", 1, true) ~= nil,
          "border: ...run by the pane's own dropdown")
    check(page:find('GUI:SeedBorderTexture(db, "frame")', 1, true) ~= nil,
          "border: ...and by the hoisted one, so the two agree what Texture means")

    -- ---- the counts did NOT move ------------------------------------
    -- The strongest single statement of "shown twice, not moved": every declared
    -- count is what the pane mounts, hoisting or no hoisting. Section 4 already
    -- pins each number against its builder; this says the four hoisting rows are
    -- among them rather than exceptions to them.
    for _, name in ipairs({ "FRAME_SIZE_COUNT", "LAYOUT_DIR_COUNT", "PERM_MOVER_COUNT" }) do
        check(SRC:match("local " .. name .. "%s*=%s*%d+") ~= nil,
              "hoist: " .. name .. " is still declared in one place")
    end
    check(SRC:find("local BORDER_COUNT, SHADOW_COUNT = 13, 4", 1, true) ~= nil,
          "hoist: ...and the border row still claims all thirteen behind it")

    -- ---- every summary takes the db, and nothing else -----------------
    -- ☠ THE SUBTRACTION IS GONE, AND SO IS THE ARGUMENT IT NEEDED. For one pass
    -- the four hoisting rows took a SECOND argument -- the set of keys currently
    -- on the plate -- and left those keys out of the title line, because the
    -- Frame Size row was printing "125x64 · Spacing 2" while 125 and 64 sat in
    -- the two sliders directly beneath it. Then a strip row stopped painting a
    -- summary AT ALL while it is on (test_popout_row.lua 24.11), which made every
    -- one of those subtractions unreachable -- every hoisting row on this page has
    -- a strip. The shown set found a better consumer: it is what HIDES the pane's
    -- own copy of a hoisted control, so the setting is drawn once and the strip's
    -- count and the panel behind it agree. The summaries went back to one
    -- argument, the db.
    --
    -- Pinned on all six summaries the hoisting rows and their neighbours declare,
    -- not just the four that changed, so reviving the contract anywhere on the
    -- page is a red suite.
    for _, fn in ipairs({ "FrameSizeSummary", "BorderSummary", "ShadowSummary",
                          "FrameFadeSummary", "LayoutDirectionSummary",
                          "PermMoverSummary" }) do
        check(SRC:find("local function " .. fn .. "(d)", 1, true) ~= nil,
              "summary: " .. fn .. " takes the db table and nothing else")
        check(SRC:find("local function " .. fn .. "(d, shown)", 1, true) == nil,
              "summary: ..." .. fn .. " has no second argument left behind")
    end
    -- ...and no BODY still reads one. The name could survive the signature as an
    -- upvalue read -- `shown` would then be a global, nil, and every gate would
    -- silently stop firing rather than erroring.
    for _, fn in ipairs({ "FrameSizeSummary", "BorderSummary",
                          "LayoutDirectionSummary", "PermMoverSummary" }) do
        local body = SRC:match("local function " .. fn .. "%(d%)(.-)\n            end")
        check(body ~= nil, "summary: " .. fn .. "'s body is readable")
        check(body == nil or body:find("shown", 1, true) == nil,
              "summary: ..." .. fn .. " never mentions the plate set")
    end
    check(SRC:find("not (shown and ", 1, true) == nil,
          "summary: and no row anywhere on the page still subtracts a plate set")

    -- ---- the general verb, not a sibling ----------------------------
    -- One door for both kinds of hoist. A second exported name would be a second
    -- place that has to remember the row's name, the section stamp and the
    -- search rules -- and they are the same rules read from either end.
    local controls = options_file_source("GUI/Controls.lua")
    check(controls:find("local function RegisterHoistedControls(row, list, dbFn)", 1, true) ~= nil,
          "verb: the controls form is declared")
    check(controls:find("if type(label) == \"table\" then", 1, true) ~= nil,
          "verb: ...and reached by overloading RegisterHoistedToggle's second argument")
    check(controls:find("RegisterHoistedControls = ", 1, true) == nil,
          "verb: ...with no second name exported beside it")
end
