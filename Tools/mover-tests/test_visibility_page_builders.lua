local NS = ...

-- ============================================================
-- VISIBILITY PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Options.lua
-- ------------------------------------------------------------
-- Display > Visibility is the sweep's first DISPLAY page, and the first one
-- whose conversion SPLITS a classic box rather than lifting it whole. The page
-- has always had exactly one group -- "Frame Display" -- holding two unrelated
-- things: Solo Mode with its three rested controls (a gated group, which becomes
-- a feature ROW with the enable hoisted onto it) and "Hide Self from Party
-- Frames" (an independent single tick, which stays INLINE wearing the band
-- skin).
--
-- ☠ THE SPLIT IS THE WHOLE RISK THIS FILE COVERS. Classic still builds ONE box
-- with all six controls in their original order; it does it by mounting the two
-- builders into the same group, one after the other. If either builder drifts,
-- or if the classic arm stops mounting both, classic silently loses controls --
-- so the census below is taken from the PRE-CHANGE source and both builders are
-- checked for being declared once and mounted twice.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db -- so this file
-- does what test_frame_page_builders / test_sorting_page_builders do: it reads
-- the page's SOURCE and asserts against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each extracted builder -- kind, L key, db key and
--     slot height, in order.
--   ✓ that ONE builder serves both layouts.
--   ✓ that the declared row COUNT matches what the pane mounts, less the hoisted
--     toggle.
--   ✗ nothing about runtime behaviour -- the callbacks, the greying and the
--     summary are read by eye and by the in-game checklist.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Options.lua")

-- ---- the census reader (the Frame page's, verbatim) ------------------
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
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

-- The page, scoped by its own two ends: Options.lua holds a dozen pages, and a
-- bare 280 box on one of the others is not this pass's business.
local PAGE
do
    local a = SRC:find('Add(CreateCopyButton(self.child, {"soloMode", "hidePlayerFrame", "restedIndicator"}', 1, true)
    local b = SRC:find('GUI.Tabs["display_visibility"].partyOnly = true', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Visibility page builder is locatable by its own ends")
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

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED MACHINERY
-- Never its own copy: the helper exists so seven pages do not carry seven
-- drifting copies of the eager holders and the footer verbs.
-- ============================================================
print("-- Visibility page: the shared popout machinery, not a seventh copy of it")
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

    -- The page's one band: chromeless, at the width the layout pass will give
    -- it, and WITHOUT a header -- its single row's own label already says "Solo
    -- Mode", which is the Sorting page's sortBand rule.
    check(PAGE:find("soloBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
          "band: the solo band is chromeless, at the width the layout pass will give it")
    check(PAGE:find("soloBand:AddWidget(GUI:CreateHeader", 1, true) == nil,
          "band: ...and carries no header, because its one row's label already does")
end

-- ============================================================
-- 2. SOLO MODE -- the page's one hoisted toggle
-- Five controls, one of them the "am I doing anything" tick, which goes onto the
-- row. The blurb stays in the pane.
-- ============================================================
--
-- ⚠ THE TWO SUB-TICK LABELS ARE ONE SPACE HERE, FOUR IN THE SOURCE. The census
-- reader flattens the body with `%s+` -> " " before it matches, so the indent
-- that pins "    Show ZZZ Icon" under its parent collapses along with every
-- other run of whitespace. Written down rather than papered over: the real
-- locale keys keep their four spaces, and the enUS entries are what a translator
-- sees.
local SOLO_MODE = {
    { "checkbox", "Solo Mode",           "soloMode",             30 },
    { "checkbox", "Rested Indicator",    "restedIndicator",      30 },
    { "checkbox", " Show ZZZ Icon",      "restedIndicatorIcon",  30 },
    { "checkbox", " Show Frame Glow",    "restedIndicatorGlow",  30 },
    { "label",    "Solo Mode: Show your player frame when not in a group.", "(none)", 30 },
}

print("-- Visibility page: Solo Mode")
do
    local body = builderBody("BuildSoloModeGroup")
    checkCensus(census(body), SOLO_MODE, "solo mode")

    -- Declared once, mounted twice -- the classic box and the popout pane.
    local calls = 0
    for _ in PAGE:gmatch("BuildSoloModeGroup%(") do calls = calls + 1 end
    eq(calls, 3, "solo mode: declared once, mounted twice -- classic box and popout pane")

    -- The hoist, and the arithmetic it implies: the checkbox is still IN the
    -- builder -- classic needs it -- behind the one flag the popout passes.
    check(body:find("if not tools2.hoistToggle then", 1, true) ~= nil,
          "solo mode: the enable checkbox is skipped when the row has hoisted it")
    local declared = tonumber(PAGE:match("local SOLO_MODE_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "solo mode: the page declares the row's count in one place")
    eq(declared, #SOLO_MODE - 1, "solo mode: ...the census less the hoisted tick")

    -- ⚠ THE COMPOUND GREY PREDICATES SURVIVED THE MOVE VERBATIM, including the
    -- "not d.soloMode" half the row's own off-gate already covers. Classic has
    -- no row and needs that half.
    check(body:find("restedIndicator.disableOn = function(d) return not d.soloMode end", 1, true) ~= nil,
          "solo mode: the indicator greys while solo mode is off, as it always did")
    local compound = 0
    for _ in body:gmatch("disableOn = function%(d%) return not d%.soloMode or not d%.restedIndicator end") do
        compound = compound + 1
    end
    eq(compound, 2, "solo mode: ...and both sub-ticks keep the two-condition predicate")

    -- Every widget in this group keeps its own raid guard. The tab is partyOnly
    -- as well, and both belts stay.
    local hides = 0
    for _ in body:gmatch('hideOn = function%(%) return GUI%.SelectedMode == "raid" end') do
        hides = hides + 1
    end
    eq(hides, 5, "solo mode: all five controls keep their own raid guard")
    check(SRC:find('GUI.Tabs["display_visibility"].partyOnly = true', 1, true) ~= nil,
          "solo mode: ...and the tab is still party-only")

    local opts = rowOpts("Solo Mode")
    check(opts:find('toggle%s*=%s*{%s*key%s*=%s*"soloMode"%s*}') ~= nil,
          "solo mode: the row's tick is the group's own enable key")
    check(opts:find("summary%s*=%s*SoloModeSummary") ~= nil,
          "solo mode: ...it declares a summary")
    check(opts:find("count%s*=%s*SOLO_MODE_COUNT") ~= nil,
          "solo mode: ...and the declared count, not a literal")
    check(opts:find("onToggle%s*=%s*OnSoloModeToggle") ~= nil,
          "solo mode: ...and a commit that is not a page rebuild")
    check(opts:find("window", 1, true) ~= nil and opts:find("clipTo", 1, true) ~= nil,
          "solo mode: ...docked outside the window and clipped by the page's scroll frame")
    check(opts:find("offText", 1, true) == nil,
          "solo mode: no offText -- off here really does mean no solo frame")

    -- ⚠ NO hideOn ON THE ROW, mirroring classic: the box had none either, only
    -- its children did.
    check(PAGE:find("soloRow.hideOn", 1, true) == nil,
          "solo mode: the row is always visible, exactly as the box was")

    -- ☠ THE COMMIT IS NOT A PAGE REBUILD. A rebuild retires the row being
    -- clicked, and the row's write path calls row.Refresh() after onToggle
    -- returns -- on a dead frame.
    local commit = PAGE:match("local function OnSoloModeToggle%(%)(.-)\n            end")
    check(commit ~= nil, "solo mode: the popout commit is a named function")
    if commit then
        check(commit:find("RefreshCurrentPage", 1, true) == nil,
              "solo mode: ...and never rebuilds the page")
        check(commit:find("DF:UpdateAllFrames()", 1, true) ~= nil
          and commit:find("DF:UpdateDefaultPlayerFrame()", 1, true) ~= nil,
              "solo mode: ...it runs what the suppressed checkbox's callback ran")
        check(commit:find("self:RefreshStates()", 1, true) ~= nil,
              "solo mode: ...re-runs the state passes")
        check(commit:find("tools.ReflowMounted()", 1, true) ~= nil,
              "solo mode: ...and reflows the open panes")
    end

    -- The hoisted toggle is re-registered with search under the SAME label and
    -- key the suppressed checkbox carried, or the setting becomes unfindable in
    -- the popout layout while staying findable in classic.
    check(PAGE:find('tools.RegisterHoistedToggle(soloRow, L["Solo Mode"], "soloMode", OnSoloModeToggle)', 1, true) ~= nil,
          "solo mode: the hoisted toggle keeps its search entry")

    -- The strip: claimed keys, the amber tick, and a footer whose apply is the
    -- union of what the group's four callbacks do.
    check(PAGE:find("tools.ClaimKeys(soloRow, soloContent)", 1, true) ~= nil,
          "solo mode: the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(soloRow)", 1, true) ~= nil,
          "solo mode: ...its amber tick asks about exactly those keys")
    check(PAGE:find("tools.WireFooter(soloRow, ApplySoloMode)", 1, true) ~= nil,
          "solo mode: ...and Reset Group / Hold: Defaults run the group's own apply")
    local apply = PAGE:match("local function ApplySoloMode%(%)(.-)\n            end")
    check(apply ~= nil, "solo mode: the group's apply is a named function")
    if apply then
        check(apply:find("DF:UpdateRestedIndicator()", 1, true) ~= nil,
              "solo mode: ...covering the three rested controls")
        check(apply:find("DF:UpdateAllFrames()", 1, true) ~= nil
          and apply:find("DF:UpdateDefaultPlayerFrame()", 1, true) ~= nil,
              "solo mode: ...and the solo frame itself")
    end

    -- The summary reuses words the locale already ships and separates them with
    -- the convention's dot -- no new locale string was invented for this page.
    local sum = PAGE:match("local function SoloModeSummary%(d%)(.-)\n            end")
    check(sum ~= nil, "solo mode: the summary is a named function on the page")
    if sum then
        check(sum:find('L%["Rested Indicator"%]') ~= nil,
              "solo mode: ...naming the one feature behind the row")
        check(sum:find('L%["Icon"%]') ~= nil and sum:find('L%["Glow"%]') ~= nil,
              "solo mode: ...and the two ways it is drawn, in words the locale already has")
        check(sum:find('L%["    Show ZZZ Icon"%]') == nil,
              "solo mode: ...not the indented sub-tick labels, which are not summary words")
        check(sum:find("\\194\\183", 1, true) ~= nil,
              "solo mode: ...separated by the convention's dot")
        local items = 0
        for _ in sum:gmatch("parts%[#parts %+ 1%]") do items = items + 1 end
        check(items <= 3, "solo mode: at most four items, per the summary convention")
    end
end

-- ============================================================
-- 3. HIDE SELF FROM PARTY FRAMES -- the single option that stays inline
-- One independent tick. It is NOT behind Solo Mode's gate and never was, which
-- is the whole reason the box was split rather than lifted whole.
-- ============================================================
local HIDE_SELF = {
    { "checkbox", "Hide Self from Party Frames", "hidePlayerFrame", 30 },
}

print("-- Visibility page: Hide Self from Party Frames")
do
    local body = builderBody("BuildHideSelfGroup")
    checkCensus(census(body), HIDE_SELF, "hide self")

    local calls = 0
    for _ in PAGE:gmatch("BuildHideSelfGroup%(") do calls = calls + 1 end
    eq(calls, 3, "hide self: declared once, mounted twice -- the classic box and the inline box")

    -- ☠ THE SECURE WRITE IS UNTOUCHED AND STILL COMBAT-GATED.
    check(body:find("if not InCombatLockdown() and DF.partyHeader then", 1, true) ~= nil,
          "hide self: the secure attribute write is still gated on combat")
    check(body:find('DF.partyHeader:SetAttribute("showPlayer", not db.hidePlayerFrame)', 1, true) ~= nil,
          "hide self: ...and writes the same attribute it always did")
    check(body:find("DF:ApplyHeaderSettings()", 1, true) ~= nil
      and body:find("DF:UpdateAllFrames()", 1, true) ~= nil,
          "hide self: ...followed by the same two refreshes")
    check(body:find('hidePlayer.tooltip = L["Removes your player frame from the DandersFrames party display."]', 1, true) ~= nil,
          "hide self: the tooltip rode along")

    -- It is NOT a row: no popout is declared for it.
    check(PAGE:find('label%s*=%s*L%["Hide Self from Party Frames"%]') == nil,
          "hide self: no popout row -- a pane holding one checkbox is a click that buys nothing")
end

-- ============================================================
-- 4. THE TWO BOXES, THE SKIN AND THE ADD ORDER
-- Classic builds one bare 280 box and mounts both builders into it. The popout
-- layout builds the band, then keeps what is left of Frame Display as an inline
-- box wearing the band skin.
-- ============================================================
print("-- Visibility page: the boxes, the skin and the page's own order")
do
    -- ---- classic: ONE bare box, both builders, its own header ---------
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 1, "boxes: exactly one bare 280 box left, and it is the classic branch's own")
    check(PAGE:find('local frameDisplayGroup = GUI:CreateSettingsGroup(self.child, 280)\n            frameDisplayGroup:AddWidget(GUI:CreateHeader(self.child, L["Frame Display"]), 40)', 1, true) ~= nil,
          "boxes: the classic box is built with the header it always had")

    -- ---- popout: the inline box, wearing the skin --------------------
    check(PAGE:find("local frameDisplayGroup = GUI:CreateSettingsGroup(self.child, 280, tools.INLINE_BOX)", 1, true) ~= nil,
          "boxes: what is left of Frame Display stays inline and wears the band skin")
    -- ⚠ THE FLAG IS NEVER WRITTEN AS A LITERAL. One shared table off the tools.
    check(PAGE:find("bandStyle", 1, true) == nil,
          "boxes: the skin is taken from the tools, never restated as a literal")
    -- Both boxes keep the same header, because it is the same group.
    local headers = 0
    for _ in PAGE:gmatch('GUI:CreateHeader%(self%.child, L%["Frame Display"%]%)') do headers = headers + 1 end
    eq(headers, 2, "boxes: both layouts head the box with L[\"Frame Display\"] -- no new locale string")

    -- ---- the Add order -----------------------------------------------
    -- ☠ THE BAND FIRST. Add's "both" is a sync point, so a full-width band
    -- dropped in below a lone column box would leave a hole beside it.
    local band = PAGE:find('Add(soloBand, nil, "both")', 1, true)
    check(band ~= nil, "order: the band spans both columns")
    local lastBox, at = nil, 1
    while true do
        local s = PAGE:find("Add(frameDisplayGroup, nil, 1)", at, true)
        if not s then break end
        lastBox, at = s, s + 1
    end
    check(lastBox ~= nil and band ~= nil and band < lastBox,
          "order: ...and comes before the inline box, so nothing is left holed")
    -- The classic box keeps column 1, which is the one thing this pass was not
    -- allowed to move.
    local firstBox = PAGE:find("Add(frameDisplayGroup, nil, 1)", 1, true)
    check(firstBox ~= nil and firstBox < band,
          "order: the classic branch still adds its box to column 1")

    -- ---- the page's own furniture is untouched ------------------------
    check(PAGE:find('Add(CreateCopyButton(self.child, {"soloMode", "hidePlayerFrame", "restedIndicator"}, L["Visibility"], "display_visibility"), 25, 2)', 1, true) ~= nil,
          "page: the copy button keeps its key list and its slot")
end
