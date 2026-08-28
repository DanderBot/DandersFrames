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
