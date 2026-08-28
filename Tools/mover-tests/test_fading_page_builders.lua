local NS = ...

-- ============================================================
-- FADING PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Options.lua
-- ------------------------------------------------------------
-- Display > Fading is three groups and nothing else, so all three become
-- feature rows in ONE band and the page keeps no inline box at all:
--
--   Out of Range              a way in with NO tick -- oorEnabled is a sub-MODE
--                             (frame alpha vs twelve element alphas) and it
--                             HIDES the frame-level slider, so a hoisted tick
--                             would grey the one control the group is left with
--   Dead/Offline Fading       hoisted `fadeDeadFrames`   (keepEnabled + gate)
--   Health Threshold Fading   hoisted `healthFadeEnabled` (keepEnabled + gate)
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db -- so this file
-- does what test_frame_page_builders / test_tooltips_page_builders do: it reads
-- the page's SOURCE and asserts against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each extracted builder -- kind, L key, db key and
--     slot height, in order -- taken from the PRE-CHANGE source, so a builder
--     that quietly dropped a control or renamed a key fails here. This is also
--     the evidence that CLASSIC RENDERS AS IT DID: the classic branch mounts the
--     same builder into the same 280 box in the same column.
--   ✓ that ONE builder serves both layouts.
--   ✓ that each declared row COUNT matches what its pane mounts, less the
--     hoisted toggle.
--   ✓ that the page's two BUILD-TIME db seeds are still inside the builder, at
--     the point they always were -- a pane is built eagerly, so they land when
--     they always did, which is what the export byte-identity gate measures.
--   ✓ that every locale string the page asks for already ships in enUS.
--   ✗ nothing about runtime behaviour -- the callbacks, the greying and the
--     summaries are read by eye and by the in-game checklist.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Options.lua")

-- ---- the census reader (the Tooltips page's, plus one kind) -----------
-- ⚠ CreateInput IS IN THE MAP HERE and is not in the sibling suites': the Out
-- of Range group is the first converted group to hold an edit box (the custom
-- range spell ID). It is not db-bound -- it writes rangeCheckSpellID through the
-- dropdown's own key -- so its census row carries no key, which is the honest
-- record of what it is.
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateInput = "input",
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
    local a = SRC:find('Add(CreateCopyButton(self.child, {"rangeFade"', 1, true)
    local b = SRC:find('{pageId = "display_visibility", label = L["Visibility"]}', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Fading page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- The block a row is declared in, from its label to the closing brace of the
-- CreatePopoutRow opts.
local function rowOpts(labelKey)
    local a = PAGE:find('label%s*=%s*L%["' .. labelKey:gsub("%p", "%%%0") .. '"%]')
    check(a ~= nil, "source: a popout row is declared for " .. labelKey)
    if not a then return "" end
    local b = PAGE:find("}))", a, true)
    return PAGE:sub(a, (b or a) + 2)
end

-- What every converted group on this page has in common.
local function checkShared(builder, rowLabel, column)
    -- ONE builder, BOTH layouts: the declaration and the two mounts.
    local calls = 0
    for _ in PAGE:gmatch(builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, rowLabel .. ": declared once, mounted twice -- classic box and popout pane")

    -- The classic branch builds the box it always did, with its own header, in
    -- the column it always had.
    local esc = rowLabel:gsub("%p", "%%%0")
    local box = PAGE:match("local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)\n%s*%1:AddWidget%(GUI:CreateHeader%(self%.child, L%[\"" .. esc .. "\"%]%)")
    check(box ~= nil, rowLabel .. ": the classic 280 box is built with its own header")
    if box then
        check(PAGE:find("Add(" .. box .. ", nil, " .. column .. ")", 1, true) ~= nil,
              rowLabel .. ": ...and still goes to column " .. column)
    end

    local opts = rowOpts(rowLabel)
    check(opts ~= "" and opts:find("build", 1, true) ~= nil,
          rowLabel .. ": the row is handed a pre-built mount")
    check(opts:find("window", 1, true) ~= nil,
          rowLabel .. ": ...docked outside the settings window")
    check(opts:find("clipTo", 1, true) ~= nil,
          rowLabel .. ": ...and clipped by the page's own scroll frame, not the window")
    check(PAGE:find("local %w+ = fadeBand:AddWidget%(GUI:CreatePopoutRow%(") ~= nil,
          rowLabel .. ": ...and mounted into the page's one band")
end

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED MACHINERY, AND ITS ONE BAND CARRIES NO HEADER
-- ============================================================
print("-- Fading page: the shared popout machinery and the page's one band")
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

    -- ---- the one band -------------------------------------------------
    check(PAGE:find("fadeBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
          "band: the page's one band is chromeless, at the width the layout pass will give it")
    -- ⚠ NO HEADER, and that is the rule rather than an omission: a header names
    -- the SECTION, and the section here is the whole page -- which the tab
    -- already calls "Fading". (The Sorting page's sortBand, same reason.)
    check(PAGE:find("fadeBand:AddWidget(GUI:CreateHeader", 1, true) == nil,
          "band: ...and carries no header, because the tab already says Fading")
    local bands = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, tools%.BandWidth%(%)") do bands = bands + 1 end
    eq(bands, 1, "band: one band, not three -- all three rows share it")

    -- ---- the three page-scope helpers, above every builder -------------
    -- ☠ A closure captures the upvalue that exists when it is CREATED, so a
    -- builder declared above one of these would see nil rather than the
    -- function. The footers need them from outside the builders as well.
    for _, h in ipairs({ "RefreshRangeInfoLabel", "SetRangeSpellValue", "RefreshHealthFade" }) do
        local at = PAGE:find("local function " .. h .. "()", 1, true)
        check(at ~= nil, "helpers: " .. h .. " is declared at page scope")
        local decls = 0
        for _ in PAGE:gmatch("local function " .. h .. "%(%)") do decls = decls + 1 end
        eq(decls, 1, "helpers: ...and there is exactly one of it")
        for _, b in ipairs({ "BuildOutOfRangeGroup", "BuildDeadFadeGroup", "BuildHealthFadeGroup" }) do
            local bAt = PAGE:find("local function " .. b .. "(tools2)", 1, true)
            check(at ~= nil and bAt ~= nil and at < bAt,
                  "helpers: ..." .. b .. " is declared after it, so it closes over the real function")
        end
    end
    -- The two hideOn/disableOn predicates stayed where they were, at page scope.
    check(PAGE:find("local function HideOOROptions(d)", 1, true) ~= nil,
          "helpers: the element-specific grey predicate is still page scope")
    check(PAGE:find("local function HideFrameLevelAlpha(d)", 1, true) ~= nil,
          "helpers: ...and so is the frame-alpha hide predicate")
end

-- ============================================================
-- 2. OUT OF RANGE -- a row with no tick
-- oorEnabled is a sub-MODE, not an enable: out of range fades either way (one
-- frame-level alpha, or twelve per-element ones) and switching it off HIDES the
-- frame-level slider. A row tick carrying it would grey the one control the
-- group is left with -- the Frame Fade row's judgement, for the same reason.
-- ============================================================
local OUT_OF_RANGE = {
    { "dropdown", "Range Check Spell",            "rangeCheckSpellID",     55 },
    { "input",    "Custom Spell ID",              "(none)",                55 },
    { "label",    "(none)",                       "(none)",                25 },
    { "slider",   "Range Check Interval",         "rangeUpdateInterval",   55 },
    { "slider",   "Frame Alpha (Out of Range)",   "rangeFadeAlpha",        55 },
    { "checkbox", "Enable Element-Specific Alpha","oorEnabled",            30 },
    { "slider",   "Health Bar Alpha",             "oorHealthBarAlpha",     55 },
    { "slider",   "Missing Health Alpha",         "oorMissingHealthAlpha", 55 },
    { "slider",   "Background Alpha",             "oorBackgroundAlpha",    55 },
    { "slider",   "Border Alpha",                 "oorBorderAlpha",        55 },
    { "slider",   "Text Alpha",                   "oorTextAlpha",          55 },
    { "slider",   "Auras Alpha",                  "oorAurasAlpha",         55 },
    { "slider",   "Icons Alpha",                  "oorIconsAlpha",         55 },
    { "slider",   "Dispel Overlay Alpha",         "oorDispelOverlayAlpha", 55 },
    { "slider",   "Power Bar Alpha",              "oorPowerBarAlpha",      55 },
    { "slider",   "Missing Buff Alpha",           "oorMissingBuffAlpha",   55 },
    { "slider",   "Defensive Icon Alpha",         "oorDefensiveIconAlpha", 55 },
    { "slider",   "Aura Designer Alpha",          "oorAuraDesignerAlpha",  55 },
}

print("-- Fading page: Out of Range")
do
    local body = builderBody("BuildOutOfRangeGroup")
    checkCensus(census(body), OUT_OF_RANGE, "out of range")
    checkShared("BuildOutOfRangeGroup", "Out of Range", "1")

    -- No hoist and no group gate: there is no boolean here that means "am I
    -- doing anything at all".
    check(body:find("hoistToggle", 1, true) == nil,
          "out of range: the builder has no hoist branch, because there is nothing to hoist")
    check(body:find("disableChildrenOn", 1, true) == nil,
          "out of range: ...and no group gate -- oorEnabled greys twelve sliders, not the group")

    local declared = tonumber(PAGE:match("local OUT_OF_RANGE_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "out of range: the page declares the row's count in one place")
    eq(declared, #OUT_OF_RANGE, "out of range: ...the whole census, nothing hoisted out of it")

    local opts = rowOpts("Out of Range")
    check(opts:find("toggle", 1, true) == nil,
          "out of range: the row declares no toggle -- a mode switch is not an on/off")
    check(opts:find("onToggle", 1, true) == nil,
          "out of range: ...and so no commit either")
    check(opts:find("summary%s*=%s*OutOfRangeSummary") ~= nil,
          "out of range: ...it does declare a summary")
    check(opts:find("count%s*=%s*OUT_OF_RANGE_COUNT") ~= nil,
          "out of range: ...and the declared count, not a literal")

    -- The tick and the footer still apply: every key here is an ordinary
    -- per-mode profile key, which is what the defaults engine answers for.
    check(PAGE:find("tools.ClaimKeys(oorRow, oorContent)", 1, true) ~= nil,
          "out of range: the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(oorRow)", 1, true) ~= nil,
          "out of range: ...its amber tick asks about exactly those keys")
    check(PAGE:find("tools.WireFooter(oorRow, ApplyOutOfRange)", 1, true) ~= nil,
          "out of range: ...and its footer pushes spell, interval and alphas back out")

    -- The apply is the group's own half, named once: the range spell (which also
    -- repaints the active-spell label and clears the custom box), the interval,
    -- and a repaint for the alphas.
    local apply = PAGE:match("local function ApplyOutOfRange%(%)(.-)\n            end")
    check(apply ~= nil, "out of range: the group's apply is a named function")
    if apply then
        check(apply:find("SetRangeSpellValue()", 1, true) ~= nil,
              "out of range: ...it pushes the range spell back into the checker")
        check(apply:find("DF:SetRangeUpdateInterval(db.rangeUpdateInterval)", 1, true) ~= nil,
              "out of range: ...and the interval back into the ticker")
        check(apply:find("DF:RefreshAllVisibleFrames()", 1, true) ~= nil,
              "out of range: ...and repaints, which is what the alpha sliders do")
    end

    -- ☠ THE ELEMENT-SPECIFIC TICK USES THE PANE'S OWN REFRESH. It drives a
    -- hideOn inside this group, so the pane changes HEIGHT when it is clicked
    -- and the panel around it has to be told; the page's own refresh never
    -- reaches a group living in a popout holder. In classic the tools2 hook IS
    -- self:RefreshStates, so nothing changed there.
    local tick = body:match('CreateCheckbox%(parent, L%["Enable Element%-Specific Alpha"%].-\n            end%), 30%)')
    check(tick ~= nil, "out of range: the element-specific tick is in the builder")
    if tick then
        check(tick:find("tools2.refreshStates()", 1, true) ~= nil,
              "out of range: ...and it reflows the pane rather than only the page")
        check(tick:find("self:RefreshStates()", 1, true) == nil,
              "out of range: ...never the page alone, which a pane would not hear")
    end

    -- ☠ THE TWO BUILD-TIME db SEEDS STAY INSIDE THE BUILDER, ahead of the
    -- control that reads them. A pane is built EAGERLY (page build, not first
    -- open), so they still land at the moment they always did -- which is what
    -- the export byte-identity gate measures.
    check(body:find("if db.rangeCheckSpellID == nil then", 1, true) ~= nil,
          "out of range: the spell-ID seed is still in the builder")
    check(body:find("if db.rangeUpdateInterval == nil then", 1, true) ~= nil,
          "out of range: ...and so is the interval seed")
    local seeds = 0
    for _ in PAGE:gmatch("if db%.range%w+ == nil then") do seeds = seeds + 1 end
    eq(seeds, 2, "out of range: ...two seeds on the page, not four -- neither was duplicated")

    -- The bespoke plumbing: the input and the info label are reachable from the
    -- page's own fields, which is what makes SetRangeSpellValue and
    -- RefreshRangeInfoLabel work in BOTH layouts.
    check(body:find("self.rangeSpellInput = customSpellInput", 1, true) ~= nil,
          "out of range: the custom spell box is published on the page")
    check(body:find("self.rangeSpellInfoLabel = infoLabel", 1, true) ~= nil,
          "out of range: ...and so is the active-spell label")
    check(body:find("local function ApplyCustomSpellID()", 1, true) ~= nil,
          "out of range: the custom spell ID commit stays with the box it reads")
end

-- ============================================================
-- 3. THE TWO HOISTED-TOGGLE ROWS
-- Each group's enable is the textbook hoist: keepEnabled + disableChildrenOn in
-- classic, which is the shape of "am I doing anything at all".
-- ============================================================
local DEAD_FADE = {
    { "checkbox",    "Enable Dead Fade",        "fadeDeadFrames",          30 },
    { "slider",      "Background Alpha",        "fadeDeadBackground",      55 },
    { "slider",      "Health Bar Alpha",        "fadeDeadHealthBar",       55 },
    { "slider",      "Name Text Alpha",         "fadeDeadName",            55 },
    { "slider",      "Power Bar Alpha",         "fadeDeadPowerBar",        55 },
    { "slider",      "Icons Alpha",             "fadeDeadIcons",           55 },
    { "slider",      "Auras Alpha",             "fadeDeadAuras",           55 },
    { "slider",      "Status Text Alpha",       "fadeDeadStatusText",      55 },
    { "checkbox",    "Custom Dead Background",  "fadeDeadUseCustomColor",  30 },
    { "colorpicker", "Dead Background Color",   "fadeDeadBackgroundColor", 35 },
}
local HEALTH_FADE = {
    { "checkbox", "Enable Health Threshold Fade",     "healthFadeEnabled",   30 },
    { "slider",   "Health Threshold (%)",             "healthFadeThreshold", 55 },
    { "checkbox", "Cancel Fade on Dispellable Debuff","hfCancelOnDispel",    30 },
    { "slider",   "Frame Alpha (Above Threshold)",    "healthFadeAlpha",     55 },
}

local HOISTED = {
    { builder = "BuildDeadFadeGroup", label = "Dead/Offline Fading",
      golden = DEAD_FADE, countVar = "DEAD_FADE_COUNT", column = "2",
      row = "deadRow", toggleKey = "fadeDeadFrames",
      toggleLabel = "Enable Dead Fade", commit = "OnDeadFadeToggle",
      summary = "DeadFadeSummary", apply = "ApplyDeadFade",
      -- What the suppressed checkbox ran, which the commit has to run for it.
      -- Dead/Offline's is exactly its group apply, so the commit calls that by
      -- name rather than repeating its two lines.
      commitRuns = "ApplyDeadFade()" },
    { builder = "BuildHealthFadeGroup", label = "Health Threshold Fading",
      golden = HEALTH_FADE, countVar = "HEALTH_FADE_COUNT", column = "2",
      row = "hfRow", toggleKey = "healthFadeEnabled",
      toggleLabel = "Enable Health Threshold Fade", commit = "OnHealthFadeToggle",
      summary = "HealthFadeSummary", apply = "ApplyHealthFade",
      -- ⚠ NOT ApplyHealthFade. The group's apply also invalidates the fade
      -- curve, which is the ALPHA slider's half; the suppressed enable tick ran
      -- a frame update and a repaint, and the commit runs exactly that.
      commitRuns = "DF:UpdateAllFrames()" },
}

for _, g in ipairs(HOISTED) do
    print("-- Fading page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())
    checkShared(g.builder, g.label, g.column)

    -- The hoist, and the arithmetic it implies: the checkbox is still IN the
    -- builder -- classic needs it -- behind the one flag the popout passes.
    check(body:find("if not tools2.hoistToggle then", 1, true) ~= nil,
          g.label .. ": the enable checkbox is skipped when the row has hoisted it")
    check(body:find(".keepEnabled = true", 1, true) ~= nil,
          g.label .. ": ...and in classic it stays live under the group's own grey")
    local declared = tonumber(PAGE:match("local " .. g.countVar .. "%s*=%s*(%d+)"))
    check(declared ~= nil, g.label .. ": the page declares the row's count in one place")
    eq(declared, #g.golden - 1, g.label .. ": ...the census less the hoisted tick")

    -- ☠ THE GROUP GATE IS INSIDE THE BUILDER. Left on the page-level box, the
    -- pane would not grey while the group is off and the two layouts would
    -- disagree.
    check(body:find("group.disableChildrenOn = function(d) return not d." .. g.toggleKey .. " end", 1, true) ~= nil,
          g.label .. ": the group's grey-while-off gate is inside the builder")

    local opts = rowOpts(g.label)
    check(opts:find('toggle%s*=%s*{%s*key%s*=%s*"' .. g.toggleKey .. '"%s*}') ~= nil,
          g.label .. ": the row's tick is the group's own enable key")
    check(opts:find("summary%s*=%s*" .. g.summary) ~= nil,
          g.label .. ": ...it declares its own summary")
    check(opts:find("count%s*=%s*" .. g.countVar) ~= nil,
          g.label .. ": ...and the declared count, not a literal")
    check(opts:find("onToggle%s*=%s*" .. g.commit) ~= nil,
          g.label .. ": ...and a commit that is not a page rebuild")
    check(opts:find("offText", 1, true) == nil,
          g.label .. ": no offText -- off here really does mean no fading")

    -- ☠ THE COMMIT IS NOT A PAGE REBUILD: a rebuild retires every widget on the
    -- page including the row being clicked, and the row's write path calls
    -- row.Refresh() after this returns -- on a dead frame.
    local commit = PAGE:match("local function " .. g.commit .. "%(%)(.-)\n            end")
    check(commit ~= nil, g.label .. ": the popout commit is a named function")
    if commit then
        check(commit:find("RefreshCurrentPage", 1, true) == nil,
              g.label .. ": ...and never rebuilds the page")
        check(commit:find("self:RefreshStates()", 1, true) ~= nil,
              g.label .. ": ...it re-runs the state passes instead")
        check(commit:find("tools.ReflowMounted()", 1, true) ~= nil,
              g.label .. ": ...and reflows the open panes")
        check(commit:find(g.commitRuns, 1, true) ~= nil,
              g.label .. ": ...having first run what the suppressed checkbox ran")
    end

    -- The hoisted toggle keeps its search entry under the SAME label and key the
    -- suppressed checkbox carried, or the setting becomes unfindable in the
    -- popout layout while staying findable in classic.
    check(PAGE:find('tools.RegisterHoistedToggle(' .. g.row .. ', L["' .. g.toggleLabel .. '"], "' .. g.toggleKey .. '", ' .. g.commit .. ')', 1, true) ~= nil,
          g.label .. ": the hoisted toggle keeps its search entry")

    -- The strip. Every key behind these rows is a per-mode profile key the
    -- defaults engine answers for, so both get the amber tick and the footer.
    check(PAGE:find("tools.ClaimKeys(" .. g.row .. ", ", 1, true) ~= nil,
          g.label .. ": the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(" .. g.row .. ")", 1, true) ~= nil,
          g.label .. ": ...its amber tick asks about exactly those keys")
    check(PAGE:find("tools.WireFooter(" .. g.row .. ", " .. g.apply .. ")", 1, true) ~= nil,
          g.label .. ": ...and Reset Group / Hold: Defaults run the group's own apply")
end

-- The health-fade apply is the one that has to invalidate the cached curve: a
-- written alpha is not read again until it does.
print("-- Fading page: the health fade apply")
do
    local apply = PAGE:match("local function ApplyHealthFade%(%)(.-)\n            end")
    check(apply ~= nil, "health fade: the group's apply is a named function")
    if apply then
        check(apply:find("RefreshHealthFade()", 1, true) ~= nil,
              "health fade: ...and it runs the alpha slider's own refresh, curve invalidation and all")
        check(apply:find("DF:UpdateAllFrames()", 1, true) ~= nil,
              "health fade: ...plus the frame update the threshold and dispel ticks run")
    end
end

-- ============================================================
-- 4. THE THREE SUMMARIES
-- All three follow the sweep's convention: at most four items, a fixed order,
-- "\194\183" between them, WORDS localised and numbers raw -- and every word is
-- a locale string the page already ships (section 6 proves that outright).
-- ============================================================
print("-- Fading page: the summaries")
do
    -- Out of Range has TWO SHAPES because the group has two: with
    -- element-specific alpha off there is one number and it is the frame's;
    -- with it on the frame slider is HIDDEN and twelve element alphas apply, so
    -- the row names the health bar's -- the element that covers most of the
    -- frame -- under that slider's own label.
    local oor = PAGE:match("local function OutOfRangeSummary%(d%)(.-)\n            end")
    check(oor ~= nil, "summary: Out of Range has a named summary on the page")
    if oor then
        check(oor:find("if d.oorEnabled then", 1, true) ~= nil,
              "summary: ...it branches on the mode rather than printing one number for both")
        check(oor:find('L%["Health Bar Alpha"%]') ~= nil,
              "summary: ...the element-specific case names WHICH alpha it is")
        check(oor:find('L%["Alpha"%]') ~= nil,
              "summary: ...and the frame-level case uses the word the Frame Fade row prints")
        check(oor:find("\\194\\183", 1, true) ~= nil,
              "summary: ...separated by the convention's dot")
        local items = 0
        for _ in oor:gmatch("parts%[#parts %+ 1%]") do items = items + 1 end
        check(items <= 4, "summary: at most four items, per the summary convention")
    end

    -- Dead/Offline reports only what is DOING something: six of its seven alphas
    -- ship at 1, and a row reading "Health Bar Alpha 1.00" on every default
    -- profile is noise (the Border row's rule).
    local dead = PAGE:match("local function DeadFadeSummary%(d%)(.-)\n            end")
    check(dead ~= nil, "summary: Dead/Offline has a named summary on the page")
    if dead then
        check(dead:find("hp < 1", 1, true) ~= nil,
              "summary: ...the health bar alpha is named only when it actually fades")
        check(dead:find('L%["Custom Dead Background"%]') ~= nil,
              "summary: ...and the custom background in that checkbox's own words")
        local items = 0
        for _ in dead:gmatch("parts%[#parts %+ 1%]") do items = items + 1 end
        check(items <= 4, "summary: at most four items here too")
    end

    -- Health Threshold prints the two numbers the feature IS, in control order.
    local hf = PAGE:match("local function HealthFadeSummary%(d%)(.-)\n            end")
    check(hf ~= nil, "summary: Health Threshold has a named summary on the page")
    if hf then
        check(hf:find('format("%d%%"', 1, true) ~= nil,
              "summary: ...the threshold wears its percent sign")
        check(hf:find('L%["Alpha"%]') ~= nil,
              "summary: ...and the opacity the word every other row uses for one")
        local items = 0
        for _ in hf:gmatch("parts%[#parts %+ 1%]") do items = items + 1 end
        check(items <= 4, "summary: at most four items here too")
    end
end

-- ============================================================
-- 5. THE PAGE'S OWN ORDER AND FURNITURE
-- ============================================================
print("-- Fading page: the boxes, the spacer, the band and the page's own order")
do
    -- ☠ THE COPY BUTTON'S PREFIX LIST IS UNTOUCHED. The same list drives Copy,
    -- Sync AND Reset Page, and the prefixes are real key prefixes rather than
    -- the boxes' names -- which is the bug its own comment records.
    check(PAGE:find('Add(CreateCopyButton(self.child, {"rangeFade", "rangeCheck", "rangeUpdate", "oor", "fadeDead", "healthFade", "hf"}, L["Fading"], "display_fading"), 25, 2)', 1, true) ~= nil,
          "page: the copy button's prefix list is exactly what it was")

    -- ---- three bare 280 boxes left, all inside a classicLayout arm -----
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 3, "boxes: three bare 280 boxes left, and they are the classic branch's own")
    -- Nothing stays inline in the popout layout, so nothing wears the band skin.
    check(PAGE:find("INLINE_BOX", 1, true) == nil,
          "boxes: no stay-inline box on this page -- all three groups earned a row")

    -- ---- the classic-only spacer --------------------------------------
    -- A "both" widget takes the LOWER of the two columns and drops both to it,
    -- so this spacer is column 2 in classic and does not exist in the popout
    -- layout, which has no columns left to balance.
    local spacer = 0
    for _ in PAGE:gmatch("AddSpace%(GUI%.Space%.block, 2%)") do spacer = spacer + 1 end
    eq(spacer, 1, "order: the column-2 spacer is declared once")
    local spacerAt = PAGE:find("AddSpace(GUI.Space.block, 2)", 1, true)
    local hfBoxAt  = PAGE:find('hfGroup:AddWidget(GUI:CreateHeader(self.child, L["Health Threshold Fading"])', 1, true)
    check(spacerAt ~= nil and hfBoxAt ~= nil and spacerAt < hfBoxAt,
          "order: ...directly above the box it separates, inside the classic arm")

    -- ---- the band goes in after its last row --------------------------
    -- ☠ `Add` resolves a widget's slot height on the spot, so a band has to be
    -- added AFTER the last row has been put into it.
    local bandAdd = PAGE:find('Add(fadeBand, nil, "both")', 1, true)
    local lastRow = nil
    do
        local at = 1
        while true do
            local s = PAGE:find("fadeBand:AddWidget(GUI:CreatePopoutRow(", at, true)
            if not s then break end
            lastRow, at = s, s + 1
        end
    end
    check(bandAdd ~= nil and lastRow ~= nil and lastRow < bandAdd,
          "order: the band spans both columns and goes in after its last row")
    local rows = 0
    for _ in PAGE:gmatch("fadeBand:AddWidget%(GUI:CreatePopoutRow%(") do rows = rows + 1 end
    eq(rows, 3, "order: three rows in it, which is every group on the page")

    -- ---- the page's own furniture is untouched -------------------------
    check(PAGE:find('AddSpace(GUI.Space.block, "both")', 1, true) ~= nil,
          "page: the block spacer before See Also survives")
end

-- ============================================================
-- 6. ZERO NEW LOCALE STRINGS
-- Every L key this page asks for -- labels, tooltips and the three summaries'
-- own words -- already ships in enUS. A sweep that invented a string would have
-- to add it there in the same commit, and this is the gate that says so.
-- ============================================================
print("-- Fading page: no new locale strings")
do
    local loc = df_file_source("Locales/enUS.lua")
    local have = {}
    for k in loc:gmatch('L%["([^"]+)"%]%s*=%s*true') do have[k] = true end
    local seen, missing = {}, 0
    for k in PAGE:gmatch('L%["([^"]+)"%]') do
        if not seen[k] then
            seen[k] = true
            if not have[k] then
                missing = missing + 1
                check(false, 'locale: the page asks for L["' .. k .. '"], which enUS does not ship')
            end
        end
    end
    eq(missing, 0, "locale: every string this page asks for already exists -- zero new keys")
end
