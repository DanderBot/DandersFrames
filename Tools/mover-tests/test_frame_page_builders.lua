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

-- The body of a `local function <name>(tools)` at the page builder's own indent.
-- ⚠ Terminated on a newline + EIGHT spaces + `end`, which is the page builder's
-- indent level: everything inside one of these bodies is indented further, so
-- this is the function's own close and not one of its inline closures'.
local function builderBody(name)
    local head = "local function " .. name .. "(tools)"
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
        local label = chunk:match('L%["([^"]+)"%]') or "(none)"
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
    check(body:find("if not tools.hoistToggle then") ~= nil,
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
    check(SRC:find("GUI:CreateSettingsGroup(self.child, moverBandW, { chromeless = true })", 1, true) ~= nil,
          "permanent mover: the band is chromeless, because the row IS the surface")
    check(SRC:find("moverBandW = math.max(", 1, true) ~= nil,
          "permanent mover: ...at the width the layout pass will stretch it to")
    check(SRC:find('Add(permMoverBand, nil, "both")', 1, true) ~= nil,
          "permanent mover: ...and spanning both columns")
    -- ...and NO header above it. The row's own label already says the words.
    check(SRC:find('permMoverBand:AddWidget(GUI:CreateHeader', 1, true) == nil,
          "permanent mover: the band carries no header -- the row's label is the name")
end

-- ============================================================
-- 3. THE PAGE ORDER -- primaries first, then the bands
-- Appearance sat ABOVE Frame Size while it was the page's only band, and for a
-- real reason: layoutCol "both" is a SYNC POINT (LayoutPage drops both columns
-- to the lower of the two), so a band added into the middle of an unbalanced
-- flow leaves a hole beside whatever was above it. Hoisting it to the top made
-- that sync free, because both columns were still at zero.
--
-- With the page now mostly bands, the answer is the other end instead: a band
-- added AFTER every column box syncs where the flow was ending anyway, which
-- is what a sync point is for -- and the page reads primaries-then-features
-- rather than opening on a band.
--
-- ☠ AND THE COLUMNS ARE NOW EMPTY IN THE POPOUT LAYOUT. Every stay-inline box
-- spans "both" as well (see section 4 -- uniform width was the point), so the
-- page's own column engine has nothing left in a numbered column. That is safe
-- by construction rather than by luck: a run of "both" widgets is a run of sync
-- points over two columns that are already equal, which is a plain single
-- stack. The hole the old hoist existed to prevent needs an UNBALANCED flow,
-- and there is no longer a flow to unbalance.
--
-- ⚠ WHAT THIS TEST CAN AND CANNOT SEE. Add() order IS page order (LayoutPage
-- walks self.children), so the source order of the Add calls is the claim. It
-- is not a geometry test: the page cannot be built headlessly, so the widths
-- are on the in-game checklist.
-- ============================================================
do
    -- Every Add on the Frame page, in source order, with what it was given.
    -- Scoped to the page: the builder runs from the Frame page's own copy
    -- button to the See Also bar at its foot.
    local a = SRC:find('Add(CreateCopyButton(self.child, {"frame", "permanentMover"', 1, true)
    local b = SRC:find('{pageId = "general_sorting", label = L["Sorting"]}', 1, true)
    check(a ~= nil and b ~= nil and b > a, "order: the Frame page builder is locatable by its own ends")
    local page = SRC:sub(a or 1, b or 1)

    -- ⚠ The column argument is no longer always a literal: the stay-inline boxes
    -- pass INLINE_COL_1 / INLINE_COL_2, which ARE the literal in classic and
    -- "both" in the popout layout (asserted below). So the capture has to accept
    -- an identifier as well as a number or a quoted word.
    local adds = {}
    for name, col in page:gmatch("Add%((%a[%w_]*),%s*nil,%s*([%w\"_]+)%)") do
        adds[#adds + 1] = { name = name, col = col }
    end
    check(#adds >= 8, "order: the page's Add calls are readable (" .. #adds .. " found)")

    -- ⚠ BY NAME AND COLUMN. `appearanceGroup` is added TWICE in the source --
    -- once as the classic 280 box into column 2, once as the band -- and they
    -- are two different layouts, never both live. The column tells them apart.
    local function indexOf(name, col)
        for i, e in ipairs(adds) do
            if e.name == name and (col == nil or e.col == col) then return i end
        end
    end

    -- The two bands are added at the END, in the layout-order block, and the
    -- Appearance band is no longer the page's first widget.
    local bandA, bandB = indexOf("appearanceGroup", '"both"'), indexOf("permMoverBand")
    check(bandA ~= nil, "order: the Appearance container is added")
    check(bandB ~= nil, "order: ...and so is the Permanent Mover band")
    eq(adds[bandA] and adds[bandA].col, '"both"', "order: the Appearance band spans both columns")
    eq(adds[bandB] and adds[bandB].col, '"both"', "order: ...and so does the mover band")

    -- ---- the two shared column names, and what they resolve to -------
    -- One place decides where a stay-inline box is added, gated on the layout,
    -- for the same reason INLINE_BOX is one name: a per-site literal is the one
    -- that gets missed.
    check(SRC:find('local INLINE_COL_1 = classicLayout and 1 or "both"', 1, true) ~= nil,
          "order: column 1 is the classic column, or the full width in the new layout")
    check(SRC:find('local INLINE_COL_2 = classicLayout and 2 or "both"', 1, true) ~= nil,
          "order: ...and so is column 2")

    -- ☠ NOTHING IS LEFT IN A NUMBERED COLUMN IN THE POPOUT LAYOUT. Every
    -- remaining numeric Add on the page is inside a `classicLayout` arm -- the
    -- three boxes that layout keeps (Appearance, Frame Fade, Permanent Mover).
    -- Stated as the rule so a new group added at `1` fails here rather than
    -- shipping as the one narrow box on a page of full-width plates.
    local CLASSIC_ONLY = {
        appearanceGroup = true, frameFadeGroup = true, permMoverGroup = true,
    }
    for _, e in ipairs(adds) do
        if e.col == "1" or e.col == "2" then
            check(CLASSIC_ONLY[e.name] == true,
                  "order: " .. e.name .. " is added at a numbered column, so it must be classic-only")
        end
    end
    -- ...and the stay-inline boxes go through the shared names, never a literal.
    local shared = 0
    for _, e in ipairs(adds) do
        if e.col == "INLINE_COL_1" or e.col == "INLINE_COL_2" then shared = shared + 1 end
    end
    eq(shared, 7, "order: all seven stay-inline boxes are added through the shared column names")

    -- The bands are still added AFTER every stay-inline box, which is what keeps
    -- the page reading primaries-then-features in either layout.
    local lastInline = 0
    for i, e in ipairs(adds) do
        if e.col == "INLINE_COL_1" or e.col == "INLINE_COL_2" then lastInline = i end
    end
    check(lastInline > 0, "order: the page still has stay-inline boxes")
    check(bandA > lastInline, "order: the Appearance band is added after every stay-inline box")
    check(bandB > lastInline, "order: ...and so is the mover band")

    -- Primaries first, and by name: Frame Size then Layout Direction, both
    -- before anything that is a band.
    local size, layout = indexOf("sizeGroup"), indexOf("layoutGroup")
    check(size ~= nil and layout ~= nil, "order: both primary boxes are added")
    check(size < layout, "order: Frame Size comes before Layout Direction")
    check(layout < bandA, "order: ...and both come before the first band")

    -- And the Add pair is guarded, so the classic layout adds neither band.
    check(SRC:find("if not classicLayout then\n            Add(appearanceGroup, nil, \"both\")", 1, true) ~= nil,
          "order: the bands are added only in the popout layout")
end

-- ============================================================
-- 4. ONE VISUAL LANGUAGE -- THE STAY-INLINE BOXES WEAR THE BAND SKIN
--
-- The conversion left the page speaking two languages at once: the converted
-- sections are an accent header above a stack of fat row plates, the survivors
-- are the classic dense box with its title inside a faint white rectangle.
-- Danders: "Layout Direction does not match the Appearance settings."
--
-- opts.bandStyle (DandersUI/Sections.lua, covered headlessly in
-- test_sections_group) is the survivors' half. What is pinned HERE is the page's
-- side of it, which is only three claims and all three are source-level:
--   ✓ the opt-in is declared ONCE, gated on the layout, and passed by name
--   ✓ every stay-inline box on this page passes it -- an eighth box added later
--     without it is the exact drift this section exists to catch
--   ✓ the CLASSIC branch passes nothing, so it builds the box it always did
-- ============================================================
do
    -- ---- the opt-in, declared once and gated ------------------------
    check(SRC:find("local INLINE_BOX = (not classicLayout) and { bandStyle = true } or nil", 1, true) ~= nil,
          "band skin: the page declares the opt-in once, gated on the layout")

    -- ☠ AND NOWHERE ELSE. A per-site literal is what gets missed on the eighth
    -- box; one shared name is what makes "every stay-inline box" checkable at
    -- all. Exactly one occurrence of the literal, and it is the declaration.
    local literals = 0
    for _ in SRC:gmatch("bandStyle%s*=%s*true") do literals = literals + 1 end
    eq(literals, 1, "band skin: the flag is written once, not copied to each call site")

    -- ---- every stay-inline box on the Frame page --------------------
    -- The full census of boxes that did NOT become bands: the two primaries and
    -- the five raid boxes, each with the opt table it is built with. Named
    -- rather than counted, so a rename fails here instead of quietly reducing
    -- the count -- and the OPT is named too, because which boxes take the
    -- two-track interior is a per-box judgement (see section 5) and a box that
    -- silently changed shape is exactly the drift this list exists to catch.
    local STAY_INLINE = {
        { "sizeGroup",        "INLINE_GRID" },  -- Frame Size: five sliders
        { "layoutGroup",      "INLINE_GRID" },  -- Layout Direction: two dropdowns
        { "raidModeGroup",    "INLINE_BOX"  },  -- Raid Layout Mode: a tick and a blurb
        { "groupLayoutGroup", "INLINE_GRID" },  -- Group Layout Settings
        { "groupVisGroup",    "INLINE_GRID" },  -- Group Visibility: eight ticks
        { "groupOrderGroup",  "INLINE_BOX"  },  -- Group Display Order: the drag list
        { "flatGridGroup",    "INLINE_GRID" },  -- Flat Grid Settings
    }
    -- Scoped to the Frame page: `sizeGroup` and `layoutGroup` are also the names
    -- of boxes on OTHER pages in this file, and those are not part of this sweep.
    local a = SRC:find("local INLINE_BOX = (not classicLayout)", 1, true)
    local b = SRC:find('{pageId = "general_sorting", label = L["Sorting"]}', 1, true)
    check(a ~= nil and b ~= nil and b > a, "band skin: the Frame page builder is locatable")
    local page = SRC:sub(a or 1, b or 1)

    for _, e in ipairs(STAY_INLINE) do
        local decl = "local " .. e[1] .. " = GUI:CreateSettingsGroup(self.child, INLINE_W, " .. e[2] .. ")"
        check(page:find(decl, 1, true) ~= nil,
              "band skin: " .. e[1] .. " is built with the skin, at the page's width, as " .. e[2])
    end

    -- Nothing else on the page builds a 280 box WITHOUT it. This is the claim the
    -- named list above cannot make on its own: it says the seven are opted in,
    -- not that they are all of them.
    local bare = 0
    for _ in page:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    -- The three that remain are the CLASSIC branch's own boxes -- Appearance,
    -- Frame Fade and Permanent Mover, each inside a `classicLayout` arm, and each
    -- of which has to stay exactly as it was.
    eq(bare, 3, "band skin: the only bare 280 boxes left are the classic branch's three")

    -- ---- and the classic branch is untouched ------------------------
    -- ☠ THE LOAD-BEARING CLAIM OF THE WHOLE SWEEP. In classic, INLINE_BOX is nil
    -- -- which is precisely what "no opts" means to CreateSettingsGroup -- and
    -- the classic-only boxes never mention it at all.
    check(SRC:find("local frameFadeGroup = GUI:CreateSettingsGroup(self.child, 280)", 1, true) ~= nil,
          "band skin: the classic Frame Fade box is built exactly as before")
    check(SRC:find("local permMoverGroup = GUI:CreateSettingsGroup(self.child, 280)", 1, true) ~= nil,
          "band skin: ...and so is the classic Permanent Mover box")
    check(page:find("appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)", 1, true) ~= nil,
          "band skin: ...and the classic Appearance box")

    -- ---- the bands do NOT take it -----------------------------------
    -- A band is chromeless because its ROWS are the surface; a plate drawn round
    -- a band would be the second panel the chromeless opt exists to avoid.
    check(page:find("GUI:CreateSettingsGroup(self.child, bandW, { chromeless = true })", 1, true) ~= nil,
          "band skin: the Appearance band stays chromeless")
    check(page:find("GUI:CreateSettingsGroup(self.child, moverBandW, { chromeless = true })", 1, true) ~= nil,
          "band skin: ...and so does the mover band")
end

-- ============================================================
-- 5. ONE WIDTH -- THE STAY-INLINE BOXES SPAN THE PAGE TOO
--
-- The skin made the survivors LOOK like the bands and left them 280 wide beside
-- a band running to the corridor. Danders: "there is still an issue with their
-- width -- Appearance spans the whole width, the others do not."
--
-- The fix is two halves and they only work together:
--   ✓ WIDTH   -- every stay-inline box is built at the page's usable width, the
--                SAME expression the two bands are built at, and added "both"
--   ✓ DENSITY -- the boxes whose contents are pairs of compact controls flow
--                their interior across TWO tracks (opts.innerColumns, covered
--                headlessly in test_sections_group), so the extra width buys a
--                second control rather than a 400px slider
--
-- What is pinned here is the page's side: the width is asked for and not
-- guessed, it is the band's own expression, and the per-box judgement about
-- which boxes take two tracks is recorded. The geometry itself is on the
-- in-game checklist -- the page cannot be built headlessly.
-- ============================================================
do
    local a = SRC:find("local INLINE_BOX = (not classicLayout)", 1, true)
    local b = SRC:find('{pageId = "general_sorting", label = L["Sorting"]}', 1, true)
    local page = SRC:sub(a or 1, b or 1)

    -- ---- the width, declared once and DERIVED ------------------------
    check(page:find("local INLINE_W = classicLayout and GUI.SettingsBox.group or math.max(", 1, true) ~= nil,
          "width: the stay-inline width is declared once, gated on the layout")
    local decls = 0
    for _ in page:gmatch("local INLINE_W%s*=") do decls = decls + 1 end
    eq(decls, 1, "width: ...exactly once, not per call site")

    -- ☠ THE EQUALITY CLAIM: a box and a band are built at the SAME number. Read
    -- as the expression rather than as a value, because there is no value to
    -- read headlessly -- but an expression copied character for character from
    -- the band's cannot resolve to something else.
    local BAND_EXPR = [[math.max(
                GUI.PageUsableWidth(GUI.PageChildWidth(
                    GUI.contentFrame and GUI.contentFrame:GetWidth() or 0)),
                GUI.SettingsBox.group)]]
    -- The bands' own copies sit one indent level deeper than INLINE_W's, so the
    -- comparison is made on the whitespace-collapsed text.
    local function flat(s) return (s:gsub("%s+", " ")) end
    local wanted = flat(BAND_EXPR)
    local seen = 0
    for chunk in page:gmatch("math%.max%([^;]-GUI%.SettingsBox%.group%)") do
        if flat(chunk) == wanted then seen = seen + 1 end
    end
    -- Three: the Appearance band's bandW, the mover band's moverBandW, and
    -- INLINE_W. Any one of them drifting is the page going back to two widths.
    eq(seen, 3, "width: the boxes and both bands ask for the width the same way")

    -- ...and it is the width the LAYOUT PASS will hand out, not a literal: the
    -- helper is the one PageRefreshStates stretches a \"both\" widget to.
    check(page:find("GUI.PageUsableWidth(GUI.PageChildWidth(", 1, true) ~= nil,
          "width: ...through the page's own helper, so it cannot drift from the layout pass")

    -- ---- the two-track opt, DERIVED from the one-track one -----------
    -- Section 4 pins that `bandStyle = true` is written exactly once. That stays
    -- true only because INLINE_GRID takes the flag off INLINE_BOX rather than
    -- restating it -- which is also what stops the two tables disagreeing about
    -- the skin.
    check(page:find("local INLINE_GRID = INLINE_BOX", 1, true) ~= nil,
          "grid: the two-track opt is derived from the one-track opt")
    check(page:find("and { bandStyle = INLINE_BOX.bandStyle, innerColumns = 2 }", 1, true) ~= nil,
          "grid: ...taking the skin off it rather than restating the flag")
    local cols = 0
    for _ in page:gmatch("innerColumns%s*=%s*2") do cols = cols + 1 end
    eq(cols, 1, "grid: the track count is written once, not copied to each call site")

    -- ---- and the blurbs opt OUT of the grid ---------------------------
    -- A wrapping hint describes the whole box, not the control beside it, and
    -- half a plate is where a one-line hint becomes a three-line one. The three
    -- boxes that are BOTH two-track AND carry a blurb each mark theirs.
    local FULL_ROW = {
        "groupLayoutHintLabel",  -- Group Layout Settings
        "groupVisHintLabel",     -- Group Visibility
        "flatGridHintLabel",     -- Flat Grid Settings
    }
    for _, name in ipairs(FULL_ROW) do
        check(page:find(name .. ".fullRow = true", 1, true) ~= nil,
              "grid: " .. name .. " spans the plate rather than one track")
    end
    local marks = 0
    for _ in page:gmatch("%.fullRow%s*=%s*true") do marks = marks + 1 end
    eq(marks, #FULL_ROW, "grid: ...and those are the only opt-outs on the page")
end
