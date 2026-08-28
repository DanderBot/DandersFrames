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
