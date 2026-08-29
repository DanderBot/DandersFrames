local NS = ...

-- ============================================================
-- MISSING BUFFS PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Indicators.lua
-- ------------------------------------------------------------
-- Auras > Missing Buffs is the third page in the Indicators file to convert, and
-- the narrowest of the three: FIVE groups, all five of which become feature rows
-- in two bands. There is no single-setting group on it, so no control row.
--
--   "Content" band  Settings (hoists missingBuffIconEnabled, the PAGE gate) and
--                   Buffs to Check (Manual Mode), which carries the box's own
--                   variant gate on the ROW so the band collapses the slot when
--                   auto-detect takes the list over.
--   "Icon" band     Appearance, Position, Border (hoists
--                   missingBuffIconShowBorder through the toolkit's
--                   noShowToggle).
--
-- ☠ BUFFS TO CHECK IS A WAY IN, NOT A STRUCTURAL SKIP. It looks like a spell
-- list and is not one: a fixed, shipped catalog of six raid buffs behind six
-- boolean profile keys, with nothing to add and nothing to remove. That is the
-- Debuff Blacklist's verdict -- and unlike the blacklist it DOES take a footer,
-- because every key behind it is a scalar the defaults engine can write.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db -- so this file
-- does what the other census files do: it reads the page's SOURCE and asserts
-- against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each extracted builder -- kind, L key, db key and
--     slot height, in order -- taken from the PRE-CHANGE source, so a builder
--     that quietly dropped a control or renamed a key fails here. This is also
--     the evidence that CLASSIC RENDERS AS IT DID: the classic branch mounts the
--     same builder into the same 280 box in the same column.
--   ✓ that ONE builder serves both layouts.
--   ✓ that each declared row COUNT matches what its pane mounts, less whatever
--     the row hoisted.
--   ✓ that the page gate greys exactly the rows it greyed boxes in classic.
--   ✗ nothing about runtime behaviour -- the callbacks, the greying and the
--     summaries are read by eye and by the in-game checklist.
-- ============================================================

-- ⚠ NORMALISED TO LF UP FRONT. This page file ships CRLF (the companion's files
-- are mixed per file), and a plain multi-line `find` for source text would miss
-- every one of them otherwise. Nothing here asserts about line endings.
local SRC = options_file_source("GUI/Pages/Indicators.lua"):gsub("\r\n", "\n")

-- ---- the census reader (the Buff Bar page's, plus this page's banner) ----
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateSeparator = "separator", CreateButton = "button",
    CreateGrowthControl = "growth", CreateTextureDropdown = "texturedropdown",
    CreateTextControls = "textcontrols", CreateBorderControls = "bordercontrols",
    CreateDurationFormatControls = "durationformat", CreateInfoBanner = "banner",
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

-- The page, scoped by its own two ends: Indicators.lua holds four pages, and a
-- bare 280 box on one of the others is not this pass's business.
local PAGE
do
    local a = SRC:find('BuildPage(pageMissingBuffs, function(self, db, Add, AddSpace, AddSyncPoint)', 1, true)
    local b = SRC:find('local pageDefensiveIcon = CreateSubTab("auras", "auras_defensiveicon", L["Defensive Icon"])', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Missing Buffs page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

local function esc(s) return (s:gsub("%p", "%%%0")) end

-- The block a row is declared in, from its label to the closing brace of the
-- CreatePopoutRow opts.
local function rowOpts(labelKey)
    local a = PAGE:find('%f[%w]label%s*=%s*L%["' .. esc(labelKey) .. '"%]')
    check(a ~= nil, "source: a popout row is declared for " .. labelKey)
    if not a then return "" end
    local b = PAGE:find("}))", a, true)
    return PAGE:sub(a, (b or a) + 2)
end

-- What every converted group on this page has in common.
local function checkShared(builder, rowLabel, boxHeader, column)
    -- ONE builder, BOTH layouts: the declaration and the two mounts.
    local calls = 0
    for _ in PAGE:gmatch(builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, rowLabel .. ": declared once, mounted twice -- classic box and popout pane")

    -- The classic branch builds the box it always did, with its own header, in
    -- the column it always had.
    check(PAGE:find('GUI:CreateHeader(self.child, L["' .. boxHeader .. '"])', 1, true) ~= nil,
          rowLabel .. ": the classic box keeps its own header (" .. boxHeader .. ")")
    local box
    for at, name in PAGE:gmatch("()local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)") do
        local want = name .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. boxHeader .. '"])'
        local hit = PAGE:find(want, at, true)
        if hit and hit - at < 900 then box = name break end
    end
    check(box ~= nil, rowLabel .. ": ...and that header belongs to a bare 280 box")
    if box then
        check(PAGE:find("Add(" .. box .. ", nil, " .. column .. ")", 1, true) ~= nil,
              rowLabel .. ": ...which still goes to column " .. column)
    end

    local opts = rowOpts(rowLabel)
    check(opts ~= "" and opts:find("build", 1, true) ~= nil,
          rowLabel .. ": the row is handed a pre-built mount")
    check(opts:find("window", 1, true) ~= nil,
          rowLabel .. ": ...docked outside the settings window")
    check(opts:find("clipTo", 1, true) ~= nil,
          rowLabel .. ": ...and clipped by the page's own scroll frame, not the window")
end

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED MACHINERY, AND ITS VOCABULARY IS AT PAGE SCOPE
-- ============================================================
print("-- Missing Buffs page: the shared popout machinery and the page-scope vocabulary")
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
    check(PAGE:find("_popoutHolders", 1, true) == nil,
          "tools: the page never manages the popout holders itself")
    check(PAGE:find("_popoutRowForKey", 1, true) == nil,
          "tools: ...nor the search row map")

    -- ---- the two bands ------------------------------------------------
    for _, b in ipairs({ "contentBand", "iconBand" }) do
        check(PAGE:find(b .. " = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
              "bands: " .. b .. " is chromeless, at the width the layout pass will give it")
    end
    for _, pair in ipairs({ { "contentBand", "Content" }, { "iconBand", "Icon" } }) do
        check(PAGE:find(pair[1] .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. pair[2] .. '"]), 40)', 1, true) ~= nil,
              "bands: ..." .. pair[1] .. " names its section with the locale's own " .. pair[2])
    end
    -- Both headers are locale strings the page already ships, and neither can be
    -- stranded: the Content band's first row carries the page gate and never
    -- hides, and none of the Icon band's three can hide at all.
    check(PAGE:find("appearanceRow.hideOn", 1, true) == nil
      and PAGE:find("positionRow.hideOn", 1, true) == nil
      and PAGE:find("borderRow.hideOn", 1, true) == nil
      and PAGE:find("settingsRow.hideOn", 1, true) == nil,
          "bands: only one row on the page can hide, so both headers stand over something")

    -- ---- the vocabulary, at PAGE scope, declared exactly once ---------
    local decls = 0
    for _ in PAGE:gmatch("local anchorOptions = {") do decls = decls + 1 end
    eq(decls, 1, "vocab: anchorOptions is declared exactly once, at page scope")
    check(PAGE:find('["TOPLEFT"]= L["Top Left"]', 1, true) ~= nil,
          "vocab: ...and it is the same table the Anchor dropdown has always offered")

    -- ⚠ ABOVE EVERY BUILDER. A builder is a closure and captures the upvalue that
    -- exists when it is created, so one declared above these would see nil.
    local vocabAt = PAGE:find("local anchorOptions = {", 1, true)
    for _, b in ipairs({ "BuildMissingSettingsGroup", "BuildMissingBuffsToCheckGroup",
                         "BuildMissingAppearanceGroup", "BuildMissingPositionGroup",
                         "BuildMissingBorderGroup" }) do
        local at = PAGE:find("local function " .. b .. "(tools2)", 1, true)
        check(at ~= nil and vocabAt ~= nil and vocabAt < at,
              "vocab: " .. b .. " is declared after it, so it closes over the real table")
    end

    -- The page's own gates are still named once and shared by both layouts.
    for _, g in ipairs({ "HideMissingBuffOptions", "HideManualBuffVariant", "refreshMissing" }) do
        local n = 0
        for _ in PAGE:gmatch("local function " .. g .. "%(") do n = n + 1 end
        eq(n, 1, "vocab: " .. g .. " is declared exactly once")
    end
end

-- ============================================================
-- 2. THE PAGE GATE -- missingBuffIconEnabled greys the rows it greyed boxes
-- ============================================================
print("-- Missing Buffs page: the page gate")
do
    check(PAGE:find("local function MissingOffRow(d) return not (d or db).missingBuffIconEnabled end", 1, true) ~= nil,
          "gate: the page names its own gate once")

    -- Four rows greyed, and they are exactly the four groups classic dims.
    for _, row in ipairs({ "buffsRow", "appearanceRow", "positionRow", "borderRow" }) do
        check(PAGE:find(row .. ".disableOn = MissingOffRow", 1, true) ~= nil,
              "gate: " .. row .. " greys while the icon is off")
    end
    -- ...and the one that carries the gate's own tick does not.
    check(PAGE:find("settingsRow.disableOn", 1, true) == nil,
          "gate: the Settings row is not greyed -- it carries the gate's own tick")

    -- Every builder still declares the group gate it always did, so classic is
    -- unchanged and the pane greys the same set.
    for _, b in ipairs({ "BuildMissingSettingsGroup", "BuildMissingBuffsToCheckGroup",
                         "BuildMissingAppearanceGroup", "BuildMissingPositionGroup" }) do
        check(builderBody(b):find("group.disableChildrenOn = HideMissingBuffOptions", 1, true) ~= nil,
              "gate: " .. b .. " carries the group gate the classic box had")
    end
    check(builderBody("BuildMissingBorderGroup"):find("tools2.group.disableChildrenOn = HideMissingBuffOptions", 1, true) ~= nil,
          "gate: the border builder carries it too, after the toolkit has mounted")

    -- ☠ THE GROUP GATE SKIPS CHILD ONE, WHICH IN A PANE IS NOT A HEADER.
    check(PAGE:find("local function GatePaneFirstChild(group)", 1, true) ~= nil,
          "gate: the index-1 repair is declared once")
    local gated = 0
    for _ in PAGE:gmatch("\n%s+GatePaneFirstChild%(group%)\n") do gated = gated + 1 end
    eq(gated, 3, "gate: ...and applied at exactly three mounts (Appearance, Position, Border)")
    -- The two it is NOT applied to open on a LABEL, which has nothing to grey.
    for _, b in ipairs({ "BuildMissingSettingsGroup", "BuildMissingBuffsToCheckGroup" }) do
        check(builderBody(b):find("GUI:CreateLabel(parent,", 1, true) ~= nil,
              "gate: " .. b .. " opens its pane on a label, so index 1 has nothing to grey")
    end
end

-- ============================================================
-- 3. NO PAGE REBUILD ANYWHERE, IN EITHER LAYOUT
-- This page never had one -- unlike the two bar pages, whose Duration Format
-- dropdown re-gated a pair of controls -- and the conversion must not introduce
-- one: a rebuild retires the row the user is clicking through.
-- ============================================================
print("-- Missing Buffs page: no page rebuild")
do
    check(PAGE:find("GUI:RefreshCurrentPage", 1, true) == nil,
          "rebuild: the page rebuilds itself from nowhere, in either layout")

    -- Every popout mount declares itself as one; five rows, five mounts.
    local popouts = 0
    for _ in PAGE:gmatch("popout = true,") do popouts = popouts + 1 end
    eq(popouts, 5, "rebuild: all five popout mounts declare themselves as panes")

    -- The state pass a builder runs is the LAYOUT-AWARE one, never the page's.
    for _, b in ipairs({ "BuildMissingSettingsGroup", "BuildMissingBuffsToCheckGroup",
                         "BuildMissingAppearanceGroup", "BuildMissingPositionGroup",
                         "BuildMissingBorderGroup" }) do
        check(builderBody(b):find("self:RefreshStates()", 1, true) == nil,
              "rebuild: " .. b .. " never reaches past its own tools2 for a state pass")
    end
end

-- ============================================================
-- 4. THE FIVE BUILDERS, CONTROL BY CONTROL
-- Every golden below is the census of the PRE-CHANGE source: same factories,
-- same L keys, same db keys, same slot heights, in the same order.
-- ============================================================
local MISSING_SETTINGS = {
    { "label",    "Shows icon when party members are missing raid buffs.", "(none)", 30 },
    -- The client-capability banner: an info banner has no L label of its own
    -- (its text is set afterwards) and its slot height is on a separate
    -- AddWidget line, so the reader sees neither.
    { "banner",   "(none)",                          "(none)",                    nil },
    { "checkbox", "Enable Missing Buff Icon",        "missingBuffIconEnabled",     30 },
    { "checkbox", "Auto-detect (your class's buff)", "missingBuffClassDetection",  30 },
    { "checkbox", "Hide Raid Buffs from Buff Bar",   "missingBuffHideFromBar",     30 },
}
-- A FIXED, SHIPPED CATALOG: the caption and six raid buffs, each behind its own
-- boolean profile key. Nothing to add, nothing to remove -- which is why this is
-- a way in rather than a structural skip.
local MISSING_BUFFS = {
    { "label",    "When auto-detect is OFF, select which raid buffs to monitor manually.", "(none)", 35 },
    { "checkbox", "Arcane Intellect (Mage)",        "missingBuffCheckIntellect",   30 },
    { "checkbox", "Power Word: Fortitude (Priest)", "missingBuffCheckStamina",     30 },
    { "checkbox", "Battle Shout (Warrior)",         "missingBuffCheckAttackPower", 30 },
    { "checkbox", "Mark of the Wild (Druid)",       "missingBuffCheckVersatility", 30 },
    { "checkbox", "Skyfury (Shaman)",               "missingBuffCheckSkyfury",     30 },
    { "checkbox", "Blessing of the Bronze (Evoker)", "missingBuffCheckBronze",     30 },
}
local MISSING_APPEARANCE = {
    { "slider", "Icon Size",   "missingBuffIconSize",       55 },
    { "slider", "Scale",       "missingBuffIconScale",      55 },
    { "slider", "Frame Level", "missingBuffIconFrameLevel", 55 },
}
local MISSING_POSITION = {
    { "dropdown", "Anchor",   "missingBuffIconAnchor", 55 },
    { "slider",   "Offset X", "missingBuffIconX",      55 },
    { "slider",   "Offset Y", "missingBuffIconY",      55 },
}
local MISSING_BORDER = {
    -- The key the census reads off this one is the PREFIX the toolkit is handed,
    -- not a setting -- every one of its thirty-two keys is built from it.
    { "bordercontrols", "(none)", "missingBuffIcon", nil },
}

-- ---- the rows that hoist a tick --------------------------------------
local HOISTED = {
    { builder = "BuildMissingSettingsGroup", label = "Settings", boxHeader = "Settings",
      golden = MISSING_SETTINGS, countVar = "MISSING_SETTINGS_COUNT", column = "1", hoistedIn = 1,
      row = "settingsRow", band = "contentBand", toggleKey = "missingBuffIconEnabled",
      toggleLabel = "Enable Missing Buff Icon", commit = "OnMissingEnableToggle",
      summary = "MissingSettingsSummary", apply = "ApplyMissingSettings" },
    { builder = "BuildMissingBorderGroup", label = "Border", boxHeader = "Border",
      golden = MISSING_BORDER, countVar = "MISSING_BORDER_COUNT", column = "2", hoistedIn = 0,
      row = "borderRow", band = "iconBand", toggleKey = "missingBuffIconShowBorder",
      toggleLabel = "Show Border", commit = "OnMissingBorderToggle",
      summary = "MissingBorderSummary", apply = "refreshMissing" },
}

for _, g in ipairs(HOISTED) do
    print("-- Missing Buffs page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())
    checkShared(g.builder, g.label, g.boxHeader, g.column)

    -- The hoist. Two shapes: a checkbox the page itself builds (skipped behind
    -- the flag, because classic still needs it), or a composite helper told not
    -- to build its own -- noShowToggle for the border toolkit.
    if g.hoistedIn == 1 then
        check(body:find("if not tools2.hoistToggle then", 1, true) ~= nil,
              g.label .. ": the enable checkbox is skipped when the row has hoisted it")
    else
        check(body:find("tools2.hoistToggle or nil", 1, true) ~= nil,
              g.label .. ": the composite is told not to build its own toggle when the row has it")
    end

    local declared = tonumber(PAGE:match("local " .. g.countVar .. "%s*=%s*(%d+)"))
    check(declared ~= nil, g.label .. ": the page declares the row's count in one place")

    local opts = rowOpts(g.label)
    check(opts:find('toggle%s*=%s*{%s*key%s*=%s*"' .. g.toggleKey .. '"%s*}') ~= nil,
          g.label .. ": the row's tick is the group's own enable key")
    check(opts:find("summary%s*=%s*" .. g.summary) ~= nil,
          g.label .. ": ...it declares a summary of its own")
    check(opts:find("count%s*=%s*" .. g.countVar) ~= nil,
          g.label .. ": ...and the declared count, not a literal")
    check(opts:find("onToggle%s*=%s*" .. g.commit) ~= nil,
          g.label .. ": ...and a commit that is not a page rebuild")

    check(PAGE:find("local " .. g.row .. " = " .. g.band .. ":AddWidget(GUI:CreatePopoutRow(", 1, true) ~= nil,
          g.label .. ": the row is mounted into the " .. g.band)

    -- ☠ THE COMMIT IS NOT A PAGE REBUILD.
    local commit = PAGE:match("local function " .. g.commit .. "%(%)(.-)\n            end")
                or PAGE:match("local function " .. g.commit .. "%(%)(.-)\n        end")
    check(commit ~= nil, g.label .. ": the popout commit is a named function")
    if commit then
        check(commit:find("RefreshCurrentPage", 1, true) == nil,
              g.label .. ": ...and never rebuilds the page")
        check(commit:find("RefreshStates()", 1, true) ~= nil,
              g.label .. ": ...it re-runs the state passes instead")
        check(commit:find("ReflowMounted()", 1, true) ~= nil,
              g.label .. ": ...and reflows the open panes")
        check(commit:find("refreshMissing()", 1, true) ~= nil,
              g.label .. ": ...and drives the strip, which is what the suppressed tick did")
    end

    check(PAGE:find('tools.RegisterHoistedToggle(' .. g.row .. ', L["' .. g.toggleLabel .. '"], "' .. g.toggleKey .. '", ' .. g.commit .. ')', 1, true) ~= nil,
          g.label .. ": the hoisted toggle keeps its search entry")

    check(PAGE:find("tools.ClaimKeys(" .. g.row .. ", ", 1, true) ~= nil,
          g.label .. ": the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(" .. g.row .. ")", 1, true) ~= nil,
          g.label .. ": ...its amber tick asks about exactly those keys")
    check(PAGE:find("tools.WireFooter(" .. g.row .. ", " .. g.apply .. ")", 1, true) ~= nil,
          g.label .. ": ...and Reset Group / Hold: Defaults push the change into the frames")
end

-- ---- the rows with no tick to hoist ----------------------------------
local WAYIN = {
    { builder = "BuildMissingBuffsToCheckGroup", label = "Buffs to Check (Manual Mode)",
      boxHeader = "Buffs to Check (Manual Mode)", golden = MISSING_BUFFS,
      countVar = "MISSING_BUFFS_COUNT", column = "1", row = "buffsRow",
      band = "contentBand", summary = "MissingBuffsToCheckSummary", apply = "refreshMissing" },
    { builder = "BuildMissingAppearanceGroup", label = "Appearance", boxHeader = "Appearance",
      golden = MISSING_APPEARANCE, countVar = "MISSING_APPEARANCE_COUNT", column = "2",
      row = "appearanceRow", band = "iconBand", summary = "MissingAppearanceSummary",
      apply = "refreshMissing" },
    { builder = "BuildMissingPositionGroup", label = "Position", boxHeader = "Position",
      golden = MISSING_POSITION, countVar = "MISSING_POSITION_COUNT", column = "1",
      row = "positionRow", band = "iconBand", summary = "MissingPositionSummary",
      apply = "refreshMissing" },
}

for _, g in ipairs(WAYIN) do
    print("-- Missing Buffs page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())
    checkShared(g.builder, g.label, g.boxHeader, g.column)

    check(body:find("hoistToggle", 1, true) == nil,
          g.label .. ": the builder has no hoist branch, because there is nothing to hoist")

    local opts = rowOpts(g.label)
    check(opts:find("%f[%w]toggle%s*=") == nil,
          g.label .. ": the row declares no toggle")
    check(opts:find("onToggle", 1, true) == nil,
          g.label .. ": ...and so no commit either")
    check(opts:find("summary%s*=%s*" .. g.summary) ~= nil,
          g.label .. ": ...it does declare a summary")
    check(PAGE:find("local " .. g.row .. " = " .. g.band .. ":AddWidget(GUI:CreatePopoutRow(", 1, true) ~= nil,
          g.label .. ": the row is mounted into the " .. g.band)
    check(PAGE:find("tools.ClaimKeys(" .. g.row .. ", ", 1, true) ~= nil,
          g.label .. ": the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(" .. g.row .. ")", 1, true) ~= nil,
          g.label .. ": ...and its amber tick asks about exactly those keys")

    local declared = tonumber(PAGE:match("local " .. g.countVar .. "%s*=%s*(%d+)"))
    check(declared ~= nil, g.label .. ": the page declares the row's count in one place")
    check(opts:find("count%s*=%s*" .. g.countVar) ~= nil,
          g.label .. ": ...and hands the row that constant, not a literal")
    check(PAGE:find("tools.WireFooter(" .. g.row .. ", " .. g.apply .. ")", 1, true) ~= nil,
          g.label .. ": ...and its footer pushes the change into the frames")
end

-- ============================================================
-- 5. THE COUNT ARITHMETIC
-- Each declared count is what the PANE mounts, which is the builder's census
-- less whatever left it for the row -- and for the composite row, what the
-- shared helper builds for the include set this page passes it.
-- ============================================================
print("-- Missing Buffs page: the declared counts")
do
    local function declared(name) return tonumber(PAGE:match("local " .. name .. "%s*=%s*(%d+)")) end

    eq(declared("MISSING_SETTINGS_COUNT"), #MISSING_SETTINGS - 1,
       "counts: Settings is the census less the hoisted Enable tick")
    eq(declared("MISSING_BUFFS_COUNT"), #MISSING_BUFFS,
       "counts: Buffs to Check is the whole census, nothing hoisted out of it")
    eq(declared("MISSING_APPEARANCE_COUNT"), #MISSING_APPEARANCE, "counts: Appearance")
    eq(declared("MISSING_POSITION_COUNT"), #MISSING_POSITION, "counts: Position")

    -- ☠ THE COMPOSITE COUNT, DERIVED FROM THE HELPER RATHER THAN ASSERTED AT IT.
    -- CreateBorderControls builds a fixed set plus one widget per include key,
    -- and this page's include set is the widest in the addon: everything the
    -- Buff Bar takes, PLUS a colour source (class/role) and the whole animation
    -- block. A literal in the page would quietly stop matching what the pane
    -- mounts the moment the toolkit gained a control.
    local BORDER_BASE = 4          -- Show Border, thickness, style, texture
    local BORDER_COLOR = 1         -- the static colour picker
    local BORDER_GRADIENT = 3      -- start, end, direction
    local BORDER_SOURCE = 1        -- the Colour Source dropdown (class/role opted in)
    local BORDER_SHADOW = 5        -- the block's tick plus colour, size, two offsets
    local BORDER_ANIMATE = 13      -- the type pick, the perf banner and eleven tunables
    local BORDER_ALPHA, BORDER_INSET, BORDER_BLEND = 1, 1, 1
    local BORDER_OFFSET = 2
    local borderAll = BORDER_BASE + BORDER_COLOR + BORDER_GRADIENT + BORDER_SOURCE
                    + BORDER_SHADOW + BORDER_ANIMATE + BORDER_ALPHA + BORDER_INSET
                    + BORDER_BLEND + BORDER_OFFSET
    eq(borderAll, 32, "counts: the border toolkit builds thirty-two for this include set")
    eq(declared("MISSING_BORDER_COUNT"), borderAll - 1,
       "counts: Border is those thirty-two less the hoisted Show Border")

    -- ...and the include set the count is derived from is the one the page passes.
    local body = builderBody("BuildMissingBorderGroup")
    for _, k in ipairs({ "alpha", "inset", "offset", "blendMode", "gradient",
                         "shadow", "animate", "classColor", "roleColor" }) do
        check(body:find(k .. " = true", 1, true) ~= nil,
              "counts: ...the include set still asks for " .. k)
    end
end

-- ============================================================
-- 6. THE HIDDEN ROW, THE SUMMARY TABLE AND THE PAGE'S OWN ORDER
-- ============================================================
print("-- Missing Buffs page: the hidden row, the bands and the order")
do
    -- ---- the one row that can hide entirely --------------------------
    -- The box's own variant gate becomes the ROW's, so the band collapses the
    -- slot rather than leaving a plate for a list auto-detect has taken over.
    check(PAGE:find("buffsRow.hideOn = HideManualBuffVariant", 1, true) ~= nil,
          "hidden row: the Buffs to Check row carries the box's own variant gate")
    check(PAGE:find("buffsGroup.hideOn = HideManualBuffVariant", 1, true) ~= nil,
          "hidden row: ...and classic still puts it on the box")

    -- ⚠ THE SUMMARY'S KEY TABLE AND THE BUILDER CANNOT DRIFT. The six checkboxes
    -- stay spelled out so the census is of what the classic box built; this is
    -- what stops the summary counting a key nothing writes.
    local body = builderBody("BuildMissingBuffsToCheckGroup")
    local listed = 0
    for k in PAGE:gmatch('"(missingBuffCheck%w+)"') do
        if body:find('db, "' .. k .. '"', 1, true) then listed = listed + 1 end
    end
    -- Six in the summary table plus six in the builder, each of which finds
    -- itself in the builder body.
    eq(listed, 12, "summary: every key in MISSING_BUFF_KEYS is one the builder actually binds")
    check(PAGE:find("local MISSING_BUFF_KEYS = {", 1, true) ~= nil,
          "summary: ...and the table is declared once, for the summary alone")

    -- ---- five bare 280 boxes left, all inside a classicLayout arm ----
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 5, "boxes: five bare 280 boxes left, and they are the classic branch's own")
    check(PAGE:find("280, tools", 1, true) == nil,
          "boxes: no stay-inline 280 box is left on the page")
    check(PAGE:find("bandStyle", 1, true) == nil,
          "boxes: the band skin is never restated as a literal (this page needs none)")
    check(PAGE:find("GUI:CreateControlRow", 1, true) == nil,
          "boxes: no control row -- every group on this page has more than one setting")

    -- ---- the Add order ------------------------------------------------
    local a = PAGE:find('Add(contentBand, nil, "both")', 1, true)
    local b = PAGE:find('Add(iconBand, nil, "both")', 1, true)
    check(a and b and a < b, "order: the two bands span both columns, in reading order")

    -- ---- the page's own furniture is untouched -------------------------
    check(PAGE:find('CreateCopyButton(self.child, {"missingBuff"}, L["Missing Buffs"], "auras_missingbuffs")', 1, true) ~= nil,
          "page: the copy button keeps the prefix it owns")
    check(PAGE:find('{pageId = "auras_buffs", label = L["Buff Bar"]}', 1, true) ~= nil,
          "page: ...and the See Also block is unchanged")
end
