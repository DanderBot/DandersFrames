local NS = ...

-- ============================================================
-- DEBUFF BAR PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Indicators.lua
-- ------------------------------------------------------------
-- Auras > Debuff Bar is the Buff Bar's twin plus two groups the buff row has no
-- use for: FOURTEEN groups, thirteen of which become feature rows in four bands
-- and one of which -- a lone checkbox -- becomes a CONTROL ROW on the same
-- plate.
--
--   "Content" band     Visibility (hoists showDebuffs, the PAGE gate), Debuff
--                      Filters, Debuff Blacklist, Order & Limits, and the Hide
--                      Duplicate Debuffs control row.
--   "Icon" band        Appearance, Layout, Position, Border (hoists
--                      debuffShowBorder through the toolkit's noShowToggle) and
--                      Important Debuffs (hoists debuffImportantHighlight).
--   "Text" band        Duration Text (hoists debuffShowDuration), Stack Count,
--                      Dispel Text (hoists debuffDispelSymbolEnabled).
--   headerless band    Duration Bar (hoists debuffDurationBarEnabled) -- one row
--                      rather than the buff page's two, because debuffs have no
--                      Pandemic box; a header there would be a section title
--                      standing over nothing on a client with no factory row.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db, the blacklist
-- catalog -- so this file does what the other census files do: it reads the
-- page's SOURCE and asserts against it.
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
--   ✓ that the Duration Format dropdown stopped rebuilding the page FROM INSIDE
--     A PANE, while classic still does exactly what it always did.
--   ✓ that the page gate greys exactly the rows it greyed boxes in classic.
--   ✓ that a pane can now answer GUI:RelayoutHost's walk, which is what the
--     caution banner behind the Debuff Filters row needed.
--   ✗ nothing about runtime behaviour -- the callbacks, the greying and the
--     summaries are read by eye and by the in-game checklist.
-- ============================================================

-- ⚠ NORMALISED TO LF UP FRONT. This page file ships CRLF (the companion's files
-- are mixed per file), and a plain multi-line `find` for source text would miss
-- every one of them otherwise. Nothing here asserts about line endings.
local SRC  = options_file_source("GUI/Pages/Indicators.lua"):gsub("\r\n", "\n")
local CTRL = options_file_source("GUI/Controls.lua"):gsub("\r\n", "\n")
local SW   = options_file_source("GUI/SettingsWidgets.lua"):gsub("\r\n", "\n")

-- ---- the census reader (the Buff Bar page's, plus this page's own kinds) ----
-- The Debuff Bar builds its Duration Text and Stack Count blocks by hand rather
-- than through GUI:CreateTextControls, so the three text factories are kinds in
-- their own right here; the banner and the dispel cross-link are this page's two
-- other composites.
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateSeparator = "separator", CreateButton = "button",
    CreateGrowthControl = "growth", CreateTextureDropdown = "texturedropdown",
    CreateTextControls = "textcontrols", CreateBorderControls = "bordercontrols",
    CreateDurationFormatControls = "durationformat",
    CreateInfoBanner = "banner", CreateFontDropdown = "fontdropdown",
    CreateOutlineDropdown = "outlinedropdown", CreateShadowCheckbox = "shadowcheckbox",
    CreateDispelColorsPageLink = "dispelcolorslink",
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

-- The page, scoped by its own two ends: Indicators.lua holds six pages, and a
-- bare 280 box on one of the others is not this pass's business.
local PAGE
do
    local a = SRC:find('BuildPage(pageDebuffs, function(self, db, Add, AddSpace, AddSyncPoint)', 1, true)
    local b = SRC:find('local pageMissingBuffs = CreateSubTab("auras", "auras_missingbuffs", L["Missing Buffs"])', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Debuff Bar page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

local function esc(s) return (s:gsub("%p", "%%%0")) end

-- The block a row is declared in, from its label to the closing brace of the
-- CreatePopoutRow opts. ⚠ The frontier keeps `colorLabel = L[...]` (the
-- TextStyle block's own option) from answering as a row label.
local function rowOpts(labelKey)
    local a = PAGE:find('%f[%w]label%s*=%s*L%["' .. esc(labelKey) .. '"%]')
    check(a ~= nil, "source: a popout row is declared for " .. labelKey)
    if not a then return "" end
    local b = PAGE:find("}))", a, true)
    return PAGE:sub(a, (b or a) + 2)
end

-- What every converted group on this page has in common.
-- `boxHeader` is nil for the one box whose header is a NAMED local (Important
-- Debuffs hangs a live preview swatch off it), which the generic walk below
-- cannot find; that box is asserted by hand in section 7.
local function checkShared(builder, rowLabel, boxHeader, column)
    -- ONE builder, BOTH layouts: the declaration and the two mounts.
    local calls = 0
    for _ in PAGE:gmatch(builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, rowLabel .. ": declared once, mounted twice -- classic box and popout pane")

    if boxHeader then
        -- The classic branch builds the box it always did, with its own header, in
        -- the column it always had.
        check(PAGE:find('GUI:CreateHeader(self.child, L["' .. boxHeader .. '"])', 1, true) ~= nil,
              rowLabel .. ": the classic box keeps its own header (" .. boxHeader .. ")")
        -- The box VARIABLE, found by walking every bare 280 box on the page and
        -- asking which one puts this header on itself. A fixed line distance would
        -- not do: two of these boxes carry a hideOn and an essay between the two
        -- lines.
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
-- 1. THE PAGE TAKES THE SHARED MACHINERY, AND ITS VOCABULARY MOVED UP
-- ============================================================
print("-- Debuff Bar page: the shared popout machinery and the page-scope vocabulary")
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

    -- ---- the four bands ----------------------------------------------
    for _, b in ipairs({ "contentBand", "iconBand", "textBand", "factoryBand" }) do
        check(PAGE:find(b .. " = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
              "bands: " .. b .. " is chromeless, at the width the layout pass will give it")
    end
    for _, pair in ipairs({ { "contentBand", "Content" }, { "iconBand", "Icon" }, { "textBand", "Text" } }) do
        check(PAGE:find(pair[1] .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. pair[2] .. '"]), 40)', 1, true) ~= nil,
              "bands: ..." .. pair[1] .. " names its section with the locale's own " .. pair[2])
    end
    -- ☠ AND THE FOURTH HAS NO HEADER. Its one row carries NoFactoryRow, so a
    -- header there would be a section title left standing over nothing.
    check(PAGE:find("factoryBand:AddWidget(GUI:CreateHeader", 1, true) == nil,
          "bands: the factory-only band is headerless, because its row can hide")

    -- ---- the vocabulary, at PAGE scope, declared exactly once ---------
    -- The rows print the chosen value as their summary, and a summary is built
    -- outside the group's builder -- so the word has to come out of the same
    -- table the dropdown offers.
    for _, name in ipairs({ "anchorOptions", "debuffSortOptions", "debuffDurationFormatOptions",
                            "durBarPositionOptions", "badgePoints", "dispelModeOptions",
                            "DEBUFF_CATEGORIES" }) do
        local decls = 0
        for _ in PAGE:gmatch("local " .. name .. " = {") do decls = decls + 1 end
        eq(decls, 1, "vocab: " .. name .. " is declared exactly once, at page scope")
    end
    check(PAGE:find('DEFAULT = L["Default (Slot Order)"]', 1, true) ~= nil
      and PAGE:find('TIMER = L["Timer"]', 1, true) ~= nil
      and PAGE:find('ALL    = L["All Dispellable"]', 1, true) ~= nil,
          "vocab: ...and they are the same tables the dropdowns have always offered")
    -- The blacklist's catalog is read once for the page: the row's count and its
    -- summary are both arithmetic over it, and both live outside the builder.
    check(PAGE:find("local blacklistCatalog = (DF.AuraBlacklist and DF.AuraBlacklist.DebuffSpells) or {}", 1, true) ~= nil,
          "vocab: the blacklist catalog is read once, at page scope")

    -- ⚠ ABOVE EVERY BUILDER. A builder is a closure and captures the upvalue that
    -- exists when it is created, so one declared above these would see nil.
    local vocabAt = PAGE:find("local anchorOptions = {", 1, true)
    for _, b in ipairs({ "BuildDebuffVisibilityGroup", "BuildDebuffFilterGroup",
                         "BuildDebuffBlacklistGroup", "BuildDebuffOrderGroup",
                         "BuildDebuffAppearanceGroup", "BuildDebuffLayoutGroup",
                         "BuildDebuffPositionGroup", "BuildDebuffBorderGroup",
                         "BuildImportantDebuffsGroup", "BuildDebuffDurationGroup",
                         "BuildDebuffStackGroup", "BuildDebuffDispelTextGroup",
                         "BuildDebuffDurationBarGroup" }) do
        local at = PAGE:find("local function " .. b .. "(tools2)", 1, true)
        check(at ~= nil and vocabAt ~= nil and vocabAt < at,
              "vocab: " .. b .. " is declared after it, so it closes over the real tables")
    end

    -- ⚠ THE "ANY" SELF-HEAL STAYS INSIDE THE FILTER BUILDER, unlike the Buff Bar's
    -- registry signature. It has to run before the dropdown that would show the
    -- stale value is built, INCLUDING for a second pane instance built after a
    -- mid-session import; it is equality-gated and idempotent, so once per
    -- instance costs nothing.
    check(builderBody("BuildDebuffFilterGroup"):find('if db.directDebuffDispellableMode == "ANY" then', 1, true) ~= nil,
          "vocab: the ANY -> ALL self-heal runs inside the group that shows the value")
end

-- ============================================================
-- 2. THE PAGE GATE -- showDebuffs greys the rows it greyed boxes
-- ============================================================
print("-- Debuff Bar page: the page gate")
do
    check(PAGE:find("local function DebuffsOffRow(d) return not (d or db).showDebuffs end", 1, true) ~= nil,
          "gate: the page names its own gate once")

    -- Ten rows greyed, and they are exactly the ten groups classic dims.
    for _, row in ipairs({ "orderRow", "appearanceRow", "layoutRow", "positionRow",
                           "borderRow", "importantRow", "durationRow", "stackRow",
                           "dispelRow", "durBarRow" }) do
        check(PAGE:find(row .. ".disableOn = DebuffsOffRow", 1, true) ~= nil,
              "gate: " .. row .. " greys while the bar is off")
    end

    -- ...and the four that classic has NEVER dimmed do not start now.
    check(PAGE:find("visRow.disableOn", 1, true) == nil,
          "gate: the Visibility row is not greyed -- it carries the gate's own tick")
    check(PAGE:find("filterRow.disableOn", 1, true) == nil,
          "gate: the Debuff Filters row is not greyed -- its box never was")
    check(PAGE:find("blacklistRow.disableOn", 1, true) == nil,
          "gate: the Debuff Blacklist row is not greyed -- its box never was")
    check(PAGE:find("dedupRow.disableOn", 1, true) == nil,
          "gate: the Hide Duplicate Debuffs control row is not greyed -- its box never was")

    -- ☠ THE GROUP GATE SKIPS CHILD ONE, WHICH IN A PANE IS NOT A HEADER. Only the
    -- four panes whose first child is a GATED CONTROL need the repair.
    check(PAGE:find("local function GatePaneFirstChild(group)", 1, true) ~= nil,
          "gate: the index-1 repair is declared once")
    -- Call SITES only: the declaration line is `local function
    -- GatePaneFirstChild(group)`, which has code rather than only whitespace
    -- between the line break and the name.
    local gated = 0
    for _ in PAGE:gmatch("\n%s+GatePaneFirstChild%(group%)\n") do gated = gated + 1 end
    eq(gated, 4, "gate: ...and applied at exactly four mounts (Order & Limits, Duration Text, Stack Count, Dispel Text)")
    -- Each of those four is a builder that sets a group-wide gate; a pane that
    -- opens on a label or on a control with the page gate already on it does not
    -- need one.
    for _, b in ipairs({ "BuildDebuffOrderGroup", "BuildDebuffDurationGroup",
                         "BuildDebuffStackGroup", "BuildDebuffDispelTextGroup" }) do
        check(builderBody(b):find("disableChildrenOn = function(d) return not d.showDebuffs end", 1, true) ~= nil,
              "gate: " .. b .. " carries the group gate that skips index 1")
    end
end

-- ============================================================
-- 3. THE DURATION FORMAT GATE -- classic still rebuilds, the pane must not
-- Picking a format re-gates the two Hide Above controls (neither composes with
-- Percent). Classic has always paid for that with a page REBUILD and still does.
-- A rebuild inside a pane retires the row the user is clicking through.
-- ============================================================
print("-- Debuff Bar page: the duration format gate")
do
    local gate = PAGE:match("local function DurationFormatRefresh%(tools2%)(.-)\n        end")
    check(gate ~= nil, "format gate: the page decides this once, in a named function")
    if gate then
        check(gate:find("if tools2.popout then", 1, true) ~= nil,
              "format gate: ...branching on which layout the group was built for")
        check(gate:find("tools2.refreshStates()", 1, true) ~= nil,
              "format gate: ...the pane re-runs the state passes")
        check(gate:find("GUI:RefreshCurrentPage()", 1, true) ~= nil,
              "format gate: ...and classic still rebuilds, exactly as it always did")
    end

    -- ...and that is the ONLY page rebuild left anywhere on this page.
    local rebuilds = 0
    for _ in PAGE:gmatch("GUI:RefreshCurrentPage") do rebuilds = rebuilds + 1 end
    eq(rebuilds, 1, "format gate: exactly one page rebuild left on the page, and it is classic's")

    for _, b in ipairs({ "BuildDebuffVisibilityGroup", "BuildDebuffFilterGroup",
                         "BuildDebuffBlacklistGroup", "BuildDebuffOrderGroup",
                         "BuildDebuffAppearanceGroup", "BuildDebuffLayoutGroup",
                         "BuildDebuffPositionGroup", "BuildDebuffBorderGroup",
                         "BuildImportantDebuffsGroup", "BuildDebuffDurationGroup",
                         "BuildDebuffStackGroup", "BuildDebuffDispelTextGroup",
                         "BuildDebuffDurationBarGroup" }) do
        check(builderBody(b):find("GUI:RefreshCurrentPage", 1, true) == nil,
              "format gate: " .. b .. " never rebuilds the page from inside itself")
    end

    -- Every popout mount declares itself as one; thirteen rows, thirteen mounts.
    local popouts = 0
    for _ in PAGE:gmatch("popout = true,") do popouts = popouts + 1 end
    eq(popouts, 13, "format gate: all thirteen popout mounts declare themselves as panes")
end

-- ============================================================
-- 4. THE THIRTEEN BUILDERS, CONTROL BY CONTROL
-- Every golden below is the census of the PRE-CHANGE source: same factories,
-- same L keys, same db keys, same slot heights, in the same order.
-- ============================================================
local VISIBILITY = {
    { "checkbox", "Show Debuffs", "showDebuffs", 30 },
    { "slider",   "Max Debuffs",  "debuffMax",   55 },
}
-- The category list is DATA: the caption, the All Debuffs switch, the caution
-- banner, ONE checkbox factory (which the loop over DEBUFF_CATEGORIES goes
-- through) and the dispel-mode dropdown.
local DEBUFF_FILTERS = {
    { "label",    "(none)",              "(none)",                      35 },
    { "checkbox", "All Debuffs",         "directDebuffShowAll",         30 },
    { "banner",   "(none)",              "(none)",                      nil },
    { "checkbox", "(none)",              "(none)",                      30 },
    { "dropdown", "Dispellable Debuffs", "directDebuffDispellableMode", 55 },
}
-- The blacklist is DATA too: the caption, ONE checkbox factory (the loop over
-- the shipped catalog) and the group's own Reset.
local DEBUFF_BLACKLIST = {
    { "label",    "(none)", "(none)", 45 },
    { "checkbox", "(none)", "(none)", 30 },
    { "button",   "Reset",  "(none)", 30 },
}
local DEBUFF_ORDER = {
    { "dropdown", "Sort Order",                 "directDebuffSortOrder",          55 },
    { "checkbox", "My Auras First",             "directDebuffSortMineFirst",      30 },
    { "checkbox", "Reverse Order",              "directDebuffSortReverse",        30 },
    { "checkbox", "Hide Long Debuffs",          "debuffMaxDurationEnabled",       30 },
    { "slider",   "Hide Longer Than (minutes)", "debuffMaxDurationMinutes",       55 },
    { "checkbox", "Keep important debuffs",     "debuffMaxDurationKeepImportant", 30 },
}
local DEBUFF_APPEARANCE = {
    { "slider", "Icon Size", "debuffSize",  55 },
    { "slider", "Scale",     "debuffScale", 55 },
    { "slider", "Alpha",     "debuffAlpha", 55 },
}
local DEBUFF_LAYOUT = {
    { "slider", "Icons Per Row", "debuffWrap",     55 },
    { "slider", "Spacing X",     "debuffPaddingX", 55 },
    { "slider", "Spacing Y",     "debuffPaddingY", 55 },
}
local DEBUFF_POSITION = {
    { "dropdown", "Anchor",   "debuffAnchor",  55 },
    { "growth",   "(none)",   "debuffGrowth",  155 },
    { "slider",   "Offset X", "debuffOffsetX", 55 },
    { "slider",   "Offset Y", "debuffOffsetY", 55 },
}
-- ☠ THREE ENTRIES, NOT ONE, and that is the difference from the buff row: the
-- toolkit's eighteen plus the two controls this group adds by hand and the
-- cross-link under them. The key the census reads off the first is the PREFIX
-- the toolkit is handed, not a setting.
local DEBUFF_BORDER = {
    { "bordercontrols",   "(none)",               "debuff",                   nil },
    { "checkbox",         "Color by Dispel Type", "debuffBorderColorByType",  30 },
    { "slider",           "Dispel Border Inset",  "debuffDispelBorderInset",  55 },
    { "dispelcolorslink", "(none)",               "(none)",                   nil },
}
local DEBUFF_IMPORTANT = {
    { "label",       "Makes boss, role and priority debuffs stand out in the normal debuff row.", "(none)", 30 },
    { "checkbox",    "Highlight Important Debuffs", "debuffImportantHighlight",   30 },
    { "slider",      "Size Step",                   "debuffImportantScale",       55 },
    { "checkbox",    "Show Corner Marker",          "debuffImportantBadge",       30 },
    { "slider",      "Marker Size",                 "debuffImportantBadgeSize",   55 },
    { "dropdown",    "Marker Corner",               "debuffImportantBadgePoint",  55 },
    { "slider",      "Marker Offset X",             "debuffImportantBadgeX",      55 },
    { "slider",      "Marker Offset Y",             "debuffImportantBadgeY",      55 },
    { "colorpicker", "Marker Color",                "debuffImportantBadgeColor",  35 },
    { "colorpicker", "Marker Symbol Color",         "debuffImportantMarkColor",   35 },
}
-- ⚠ HAND-BUILT, not GUI:CreateTextControls. The buff page's Duration Text block
-- went through the shared helper; this one has always spelled its eight text
-- controls out, and the census pins that rather than tidying it -- classic has
-- to render byte for byte what it did.
local DEBUFF_DURATION = {
    { "checkbox",        "Show Duration",                    "debuffShowDuration",              30 },
    { "checkbox",        "Hide Cooldown Swipe",              "debuffHideSwipe",                 30 },
    { "durationformat",  "(none)",                           "debuffDurationFormat",            nil },
    { "fontdropdown",    "Font",                             "debuffDurationFont",              55 },
    { "slider",          "Scale",                            "debuffDurationScale",             55 },
    { "outlinedropdown", "Outline",                          "debuffDurationOutline",           55 },
    { "shadowcheckbox",  "Shadow",                           "debuffDurationOutline",           30 },
    { "dropdown",        "Anchor",                           "debuffDurationAnchor",            55 },
    { "slider",          "Offset X",                         "debuffDurationX",                 55 },
    { "slider",          "Offset Y",                         "debuffDurationY",                 55 },
    { "colorpicker",     "Duration Color",                   "debuffDurationColor",             30 },
    { "checkbox",        "Color by Time Remaining",          "debuffDurationColorByTime",       30 },
    { "checkbox",        "Hide Above Threshold",             "debuffDurationHideAboveEnabled",  30 },
    { "slider",          "Hide Above (seconds)",             "debuffDurationHideAboveThreshold", 55 },
    { "checkbox",        "Hide Duration on Permanent Auras", "debuffDurationHideOnPermanent",   30 },
}
local DEBUFF_STACK = {
    { "fontdropdown",    "Font",     "debuffStackFont",    55 },
    { "slider",          "Scale",    "debuffStackScale",   55 },
    { "outlinedropdown", "Outline",  "debuffStackOutline", 55 },
    { "shadowcheckbox",  "Shadow",   "debuffStackOutline", 30 },
    { "dropdown",        "Anchor",   "debuffStackAnchor",  55 },
    { "slider",          "Offset X", "debuffStackX",       55 },
    { "slider",          "Offset Y", "debuffStackY",       55 },
    { "colorpicker",     "Color",    "debuffStackColor",   30 },
}
-- Dispel Text DOES go through the shared block, which is why it is two entries
-- where Stack Count is eight.
local DEBUFF_DISPEL = {
    { "checkbox",     "Show Dispel Text", "debuffDispelSymbolEnabled", 30 },
    { "textcontrols", "(none)",           "debuffDispelSymbol",        nil },
}
local DEBUFF_DURBAR = {
    { "label",           "Shows a bar on each icon that drains with the aura's remaining time.", "(none)", 30 },
    { "checkbox",        "Enable Duration Bar", "debuffDurationBarEnabled",     30 },
    { "dropdown",        "Position",            "debuffDurationBarPosition",    55 },
    { "slider",          "Height",              "debuffDurationBarHeight",      55 },
    { "slider",          "Gap",                 "debuffDurationBarGap",         55 },
    { "dropdown",        "Color Mode",          "debuffDurationBarColorMode",   55 },
    { "texturedropdown", "Texture",             "debuffDurationBarTexture",     55 },
    { "colorpicker",     "Bar Color",           "debuffDurationBarColor",       30 },
    { "colorpicker",     "Background Color",    "debuffDurationBarBGColor",     30 },
    { "checkbox",        "Reverse Fill",        "debuffDurationBarReverseFill", 30 },
}

-- ---- the rows that hoist a tick --------------------------------------
local HOISTED = {
    { builder = "BuildDebuffVisibilityGroup", label = "Visibility", boxHeader = "Visibility",
      golden = VISIBILITY, countVar = "DEBUFF_VISIBILITY_COUNT", column = "1", hoistedIn = 1,
      row = "visRow", band = "contentBand", toggleKey = "showDebuffs",
      toggleLabel = "Show Debuffs", commit = "OnShowDebuffsToggle",
      summary = "DebuffVisibilitySummary" },
    { builder = "BuildDebuffBorderGroup", label = "Border", boxHeader = "Border",
      golden = DEBUFF_BORDER, countVar = "DEBUFF_BORDER_COUNT", column = "1", hoistedIn = 0,
      row = "borderRow", band = "iconBand", toggleKey = "debuffShowBorder",
      toggleLabel = "Show Border", commit = "OnDebuffBorderToggle",
      summary = "DebuffBorderSummary", apply = "ApplyDebuffBorder" },
    { builder = "BuildImportantDebuffsGroup", label = "Important Debuffs", boxHeader = nil,
      golden = DEBUFF_IMPORTANT, countVar = "DEBUFF_IMPORTANT_COUNT", column = "2", hoistedIn = 1,
      row = "importantRow", band = "iconBand", toggleKey = "debuffImportantHighlight",
      toggleLabel = "Highlight Important Debuffs", commit = "OnImportantToggle",
      summary = "ImportantDebuffsSummary", apply = "ImportantChanged" },
    { builder = "BuildDebuffDurationGroup", label = "Duration Text", boxHeader = "Duration Text",
      golden = DEBUFF_DURATION, countVar = "DEBUFF_DURATION_COUNT", column = "2", hoistedIn = 1,
      row = "durationRow", band = "textBand", toggleKey = "debuffShowDuration",
      toggleLabel = "Show Duration", commit = "OnDebuffDurationToggle",
      summary = "DebuffDurationSummary", apply = "ApplyDebuffDurationText" },
    { builder = "BuildDebuffDispelTextGroup", label = "Dispel Text", boxHeader = "Dispel Text",
      golden = DEBUFF_DISPEL, countVar = "DEBUFF_DISPEL_COUNT", column = "2", hoistedIn = 1,
      row = "dispelRow", band = "textBand", toggleKey = "debuffDispelSymbolEnabled",
      toggleLabel = "Show Dispel Text", commit = "OnDispelTextToggle",
      summary = "DebuffDispelSummary", apply = "ApplyDispelText" },
    { builder = "BuildDebuffDurationBarGroup", label = "Duration Bar", boxHeader = "Duration Bar",
      golden = DEBUFF_DURBAR, countVar = "DEBUFF_DURBAR_COUNT", column = "2", hoistedIn = 1,
      row = "durBarRow", band = "factoryBand", toggleKey = "debuffDurationBarEnabled",
      toggleLabel = "Enable Duration Bar", commit = "OnDebuffDurationBarToggle",
      summary = "DebuffDurationBarSummary", apply = "DebuffBarChanged" },
}

for _, g in ipairs(HOISTED) do
    print("-- Debuff Bar page: " .. g.label)
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

    -- ...into the right band.
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
    end

    -- The hoisted toggle keeps its search entry under the SAME label and key the
    -- suppressed checkbox carried, or the setting becomes unfindable in the
    -- popout layout while staying findable in classic.
    check(PAGE:find('tools.RegisterHoistedToggle(' .. g.row .. ', L["' .. g.toggleLabel .. '"], "' .. g.toggleKey .. '", ' .. g.commit .. ')', 1, true) ~= nil,
          g.label .. ": the hoisted toggle keeps its search entry")

    -- The strip.
    check(PAGE:find("tools.ClaimKeys(" .. g.row .. ", ", 1, true) ~= nil,
          g.label .. ": the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(" .. g.row .. ")", 1, true) ~= nil,
          g.label .. ": ...its amber tick asks about exactly those keys")
    if g.apply then
        check(PAGE:find("tools.WireFooter(" .. g.row .. ", " .. g.apply .. ")", 1, true) ~= nil,
              g.label .. ": ...and Reset Group / Hold: Defaults push the change into the frames")
    else
        check(PAGE:find("tools.WireFooter(" .. g.row .. ", function()", 1, true) ~= nil,
              g.label .. ": ...and a footer with the group's own apply")
    end
end

-- ---- the rows with no tick to hoist ----------------------------------
local WAYIN = {
    { builder = "BuildDebuffFilterGroup", label = "Debuff Filters", boxHeader = "Debuff Filters",
      golden = DEBUFF_FILTERS, column = "1", row = "filterRow", band = "contentBand",
      summary = "DebuffFilterSummary", apply = "DebuffFilterChanged" },
    { builder = "BuildDebuffBlacklistGroup", label = "Debuff Blacklist", boxHeader = "Debuff Blacklist",
      golden = DEBUFF_BLACKLIST, column = "1", row = "blacklistRow", band = "contentBand",
      summary = "DebuffBlacklistSummary" },
    { builder = "BuildDebuffOrderGroup", label = "Order & Limits", boxHeader = "Order & Limits",
      golden = DEBUFF_ORDER, countVar = "DEBUFF_ORDER_COUNT", column = "1",
      row = "orderRow", band = "contentBand", summary = "DebuffOrderSummary",
      apply = "DebuffFilterChanged" },
    { builder = "BuildDebuffAppearanceGroup", label = "Appearance", boxHeader = "Appearance",
      golden = DEBUFF_APPEARANCE, countVar = "DEBUFF_APPEARANCE_COUNT", column = "2",
      row = "appearanceRow", band = "iconBand", summary = "DebuffAppearanceSummary",
      apply = "ApplyDebuffPosition" },
    { builder = "BuildDebuffLayoutGroup", label = "Layout", boxHeader = "Layout",
      golden = DEBUFF_LAYOUT, countVar = "DEBUFF_LAYOUT_COUNT", column = "1",
      row = "layoutRow", band = "iconBand", summary = "DebuffLayoutSummary",
      apply = "ApplyDebuffPosition" },
    { builder = "BuildDebuffPositionGroup", label = "Position", boxHeader = "Position",
      golden = DEBUFF_POSITION, countVar = "DEBUFF_POSITION_COUNT", column = "1",
      row = "positionRow", band = "iconBand", summary = "DebuffPositionSummary" },
    { builder = "BuildDebuffStackGroup", label = "Stack Count", boxHeader = "Stack Count",
      golden = DEBUFF_STACK, countVar = "DEBUFF_STACK_COUNT", column = "2",
      row = "stackRow", band = "textBand", summary = "DebuffStackSummary",
      apply = "ApplyDebuffStackText" },
}

for _, g in ipairs(WAYIN) do
    print("-- Debuff Bar page: " .. g.label)
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

    if g.countVar then
        local declared = tonumber(PAGE:match("local " .. g.countVar .. "%s*=%s*(%d+)"))
        check(declared ~= nil, g.label .. ": the page declares the row's count in one place")
        check(opts:find("count%s*=%s*" .. g.countVar) ~= nil,
              g.label .. ": ...and hands the row that constant, not a literal")
    end
    if g.apply then
        check(PAGE:find("tools.WireFooter(" .. g.row .. ", " .. g.apply .. ")", 1, true) ~= nil,
              g.label .. ": ...and its footer pushes the change into the frames")
    end
end

-- ============================================================
-- 5. THE COUNT ARITHMETIC
-- Each declared count is what the PANE mounts, which is the builder's census
-- less whatever left it for the row -- and for the composite row, what the
-- shared helper builds for the include set this page passes it.
-- ============================================================
print("-- Debuff Bar page: the declared counts")
do
    local function declared(name) return tonumber(PAGE:match("local " .. name .. "%s*=%s*(%d+)")) end

    eq(declared("DEBUFF_VISIBILITY_COUNT"), #VISIBILITY - 1,
       "counts: Visibility is the census less the hoisted Show Debuffs tick")
    eq(declared("DEBUFF_ORDER_COUNT"), #DEBUFF_ORDER,
       "counts: Order & Limits is the whole census, nothing hoisted out of it")
    eq(declared("DEBUFF_APPEARANCE_COUNT"), #DEBUFF_APPEARANCE, "counts: Appearance")
    eq(declared("DEBUFF_LAYOUT_COUNT"), #DEBUFF_LAYOUT, "counts: Layout")
    eq(declared("DEBUFF_POSITION_COUNT"), #DEBUFF_POSITION,
       "counts: Position, the growth control counting as the one widget it is")
    eq(declared("DEBUFF_IMPORTANT_COUNT"), #DEBUFF_IMPORTANT - 1,
       "counts: Important Debuffs is the census less the hoisted Highlight tick")
    eq(declared("DEBUFF_DURATION_COUNT"), (#DEBUFF_DURATION - 1) + 1,
       "counts: Duration Text is its fourteen remaining widgets plus the Colors-page cross-link the census cannot see")
    eq(declared("DEBUFF_STACK_COUNT"), #DEBUFF_STACK,
       "counts: Stack Count is its own eight, spelled out rather than helper-built")
    eq(declared("DEBUFF_DISPEL_COUNT"), 8,
       "counts: Dispel Text is exactly the TextStyle block's eight, the tick hoisted")
    eq(declared("DEBUFF_DURBAR_COUNT"), #DEBUFF_DURBAR - 1,
       "counts: Duration Bar is the census less the hoisted Enable tick")

    -- ☠ THE COMPOSITE COUNT, DERIVED FROM THE HELPER RATHER THAN ASSERTED AT IT.
    -- CreateBorderControls builds a fixed set plus one widget per include key, and
    -- this page's include set is { inset, offset, blendMode, gradient, shadow,
    -- alpha } with no colour source -- so the number moves the moment the toolkit
    -- gains a control, and a literal in the page would quietly stop matching what
    -- the pane mounts.
    local BORDER_BASE = 4          -- Show Border, thickness, style, texture
    local BORDER_COLOR = 1         -- the static colour picker
    local BORDER_GRADIENT = 3      -- start, end, direction
    local BORDER_SHADOW = 5        -- the block's tick plus colour, size, two offsets
    local BORDER_ALPHA, BORDER_INSET, BORDER_BLEND = 1, 1, 1
    local BORDER_OFFSET = 2
    local borderAll = BORDER_BASE + BORDER_COLOR + BORDER_GRADIENT + BORDER_SHADOW
                    + BORDER_ALPHA + BORDER_INSET + BORDER_BLEND + BORDER_OFFSET
    eq(borderAll, 18, "counts: the border toolkit builds eighteen for this include set")
    -- ...plus the three this group adds by hand, which the buff row does not have.
    eq(declared("DEBUFF_BORDER_COUNT"), (borderAll - 1) + 3,
       "counts: Border is those eighteen less the hoisted Show Border, plus Color by Dispel Type, the dispel inset and the palette link")

    -- The two rows whose counts are DATA rather than constants.
    check(PAGE:find("local function DebuffFilterCount()", 1, true) ~= nil,
          "counts: Debuff Filters counts its own rows instead of declaring a literal")
    check(PAGE:find("return 4 + #DEBUFF_CATEGORIES", 1, true) ~= nil,
          "counts: ...the four fixed widgets plus one per Blizzard category")
    check(rowOpts("Debuff Filters"):find("count%s*=%s*DebuffFilterCount()") ~= nil,
          "counts: ...and the row is handed that count, not a number")

    check(PAGE:find("local function DebuffBlacklistCount()", 1, true) ~= nil,
          "counts: Debuff Blacklist counts the shipped catalog instead of declaring a literal")
    check(PAGE:find("return 2 + #blacklistCatalog", 1, true) ~= nil,
          "counts: ...the caption and Reset plus one per catalog entry")
    check(rowOpts("Debuff Blacklist"):find("count%s*=%s*DebuffBlacklistCount()") ~= nil,
          "counts: ...and the row is handed that count, not a number")
end

-- ============================================================
-- 6. THE CLAIMS, AND THE ONE FOOTER THIS PAGE REFUSES
-- ============================================================
print("-- Debuff Bar page: the claims and the footer refusal")
do
    -- ⚠ TWO KEYS THE WALK CANNOT SEE, both named through `extra`.
    check(PAGE:find('tools.ClaimKeys(blacklistRow, blContent, { "debuffBlacklist" })', 1, true) ~= nil,
          "claims: the blacklist row names the stored set -- every tick behind it is a custom get/set with no db binding")
    check(PAGE:find('tools.ClaimKeys(positionRow, positionContent, { "debuffGrowth" })', 1, true) ~= nil,
          "claims: the position row names debuffGrowth -- the growth control registers nothing with search")

    -- ☠ NO FOOTER ON THE BLACKLIST ROW, and for a reason of its own rather than
    -- the Buff Filters one: the GROUP ALREADY SHIPS A RESET, inside the pane, and
    -- the two do not do the same thing -- the group's button mutates the stored set
    -- IN PLACE while Reset Group writes DeepCopy(default) and replaces the table.
    check(PAGE:find("tools.WireFooter(blacklistRow", 1, true) == nil,
          "footer: the Debuff Blacklist row has no footer -- the group already carries its own Reset")
    check(PAGE:find("tools.WireModifiedTick(blacklistRow)", 1, true) ~= nil,
          "footer: ...but it keeps the amber tick, which only reads")
    check(builderBody("BuildDebuffBlacklistGroup"):find('GUI:CreateButton(parent, L["Reset"]', 1, true) ~= nil,
          "footer: ...and that Reset is the one inside the pane")

    -- ✓ AND THE FILTER ROW DOES GET ONE, which is where this page parts company
    -- with the Buff Bar. Every key behind it is a scalar -- seven booleans, All
    -- Debuffs and one string -- so a reset writes values rather than replacing a
    -- table anything holds a reference to.
    check(PAGE:find("tools.WireFooter(filterRow, DebuffFilterChanged)", 1, true) ~= nil,
          "footer: the Debuff Filters row DOES carry one -- nothing behind it is a table")

    -- Every other converted row has one.
    for _, row in ipairs({ "visRow", "orderRow", "appearanceRow", "layoutRow", "positionRow",
                           "borderRow", "importantRow", "durationRow", "stackRow", "dispelRow",
                           "durBarRow" }) do
        check(PAGE:find("tools.WireFooter(" .. row, 1, true) ~= nil,
              "footer: " .. row .. " carries Reset Group / Hold: Defaults")
    end
end

-- ============================================================
-- 7. THE CONTROL ROW, THE HEADER SWATCH, THE HIDDEN ROWS, THE BANDS AND THE
--    PAGE'S OWN ORDER
-- ============================================================
print("-- Debuff Bar page: the control row, the swatch, the bands and the order")
do
    -- ---- the one single-option group: a CONTROL ROW ------------------
    check(PAGE:find('label%s*=%s*L%["Hide Duplicate Debuffs"%],\n%s*kind%s*=%s*"checkbox"') ~= nil,
          "control row: Hide Duplicate Debuffs is a checkbox control row")
    check(PAGE:find("contentBand:AddWidget(GUI:CreateControlRow(", 1, true) ~= nil,
          "control row: ...mounted into the Content band with the rows it belongs beside")
    check(PAGE:find("})), 30)", 1, true) == nil,
          "control row: ...with no call-site slot height, because the factory owns it")
    -- ⚠ NAMED FOR THE SETTING, not for the box -- the caption the classic checkbox
    -- registers, so the search result reads the same in both layouts.
    check(PAGE:find('tools.RegisterControlRow(dedupRow, "checkbox", "debuffDeduplicateDesigner", false, DebuffFilterChanged)', 1, true) ~= nil,
          "control row: ...registered with search through the shared verb, carrying the classic callback")
    check(PAGE:find('GUI:CreateHeader(self.child, L["Deduplication"])', 1, true) ~= nil,
          "control row: classic still builds the box under its own header")
    check(PAGE:find('GUI:CreateCheckbox(self.child, L["Hide Duplicate Debuffs"], db, "debuffDeduplicateDesigner", DebuffFilterChanged)', 1, true) ~= nil,
          "control row: ...and the tick it always had")
    check(PAGE:find("Add(dedupGroup, nil, 1)", 1, true) ~= nil,
          "control row: ...in column 1, where it has always been")
    -- ONE tooltip, shared by both layouts, so they cannot drift.
    local dedupTips = 0
    for _ in PAGE:gmatch("local DEDUP_TIP = L%[") do dedupTips = dedupTips + 1 end
    eq(dedupTips, 1, "control row: the tooltip is declared once and used by both layouts")

    -- ---- the Important Debuffs box, whose header is a named local ------
    -- ☠ THE HEADER SWATCH IS CLASSIC-ONLY, and pinned as such: a popout row has no
    -- header to hang a live preview off, the kit's PopoutRow has no preview slot,
    -- and a header mounted INSIDE the pane would be a 40px repeat of the row's own
    -- name. Recorded here so the loss is deliberate rather than discovered.
    check(PAGE:find('local impHeader = GUI:CreateHeader(self.child, L["Important Debuffs"])', 1, true) ~= nil,
          "swatch: the classic box still builds its own header")
    check(PAGE:find("local impSwatch = GUI:AttachHeaderSwatch(impHeader, 13, 2)", 1, true) ~= nil,
          "swatch: ...and still hangs the marker preview off it")
    check(PAGE:find("Add(impGroup, nil, 2)", 1, true) ~= nil,
          "swatch: ...and the box still goes to column 2")
    local swatchAt = PAGE:find("GUI:AttachHeaderSwatch", 1, true)
    local elseAt   = PAGE:find("local DEBUFF_IMPORTANT_COUNT", 1, true)
    check(swatchAt ~= nil and elseAt ~= nil and swatchAt < elseAt,
          "swatch: ...and it is built in the classic arm only, above the popout branch")
    check(builderBody("BuildImportantDebuffsGroup"):find("AttachHeaderSwatch", 1, true) == nil,
          "swatch: the shared builder never touches it, so the pane cannot half-build one")
    -- The upvalue is still declared for BOTH layouts and guarded at every call, so
    -- the popout arm leaving it nil is not a nil-call.
    check(PAGE:find("local UpdateImportantSwatch   -- assigned below in classic", 1, true) ~= nil,
          "swatch: the upvalue is declared once for both layouts")
    check(PAGE:find("if UpdateImportantSwatch then UpdateImportantSwatch() end", 1, true) ~= nil,
          "swatch: ...and the shared callback guards it, so the popout arm's nil is safe")

    -- ---- the two rows that can hide entirely -------------------------
    -- One predicate, named for what it asks, on both the boxes and both the rows.
    check(PAGE:find("local function NoFactoryRow(d) return not DF:FactoryOwnsDebuffRow(d) end", 1, true) ~= nil,
          "hidden rows: the factory-row test is named once")
    check(PAGE:find("durBarRow.hideOn = NoFactoryRow", 1, true) ~= nil,
          "hidden rows: the Duration Bar row carries the box's own factory gate")
    check(PAGE:find("dispelRow.hideOn = NoFactoryRow", 1, true) ~= nil,
          "hidden rows: ...and so does the Dispel Text row")
    check(PAGE:find("durBarGroup.hideOn = NoFactoryRow", 1, true) ~= nil
      and PAGE:find("symbolGroup.hideOn = NoFactoryRow", 1, true) ~= nil,
          "hidden rows: ...and classic still puts it on the boxes")

    -- ---- fourteen bare 280 boxes left, all inside a classicLayout arm ---
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 14, "boxes: fourteen bare 280 boxes left, and they are the classic branch's own")
    check(PAGE:find("280, tools", 1, true) == nil,
          "boxes: no stay-inline 280 box is left on the page")
    check(PAGE:find("bandStyle", 1, true) == nil,
          "boxes: the band skin is never restated as a literal (this page needs none)")

    -- ---- the classic Add order, unchanged -----------------------------
    -- Within a column the Add() order IS the layout order, so the fourteen calls
    -- have to appear in exactly the sequence they always did -- including Important
    -- Debuffs landing after Border, which is what put it third from the bottom of
    -- column 2 rather than third from the top.
    local ADDS = { "visibilityGroup, nil, 1", "filterGroup, nil, 1", "blGroup, nil, 1",
                   "debuffOrderGroup, nil, 1", "dedupGroup, nil, 1", "appearanceGroup, nil, 2",
                   "gridGroup, nil, 1", "positionGroup, nil, 1", "borderGroup, nil, 1",
                   "impGroup, nil, 2", "durationGroup, nil, 2", "stackCountGroup, nil, 2",
                   "symbolGroup, nil, 2", "durBarGroup, nil, 2" }
    local prev = 0
    for _, a in ipairs(ADDS) do
        local at = PAGE:find("Add(" .. a .. ")", 1, true)
        check(at ~= nil and at > prev, "order: classic still calls Add(" .. a .. ") in sequence")
        prev = at or prev
    end

    -- ---- the popout Add order ------------------------------------------
    -- Four full-width bands in reading order. With nothing left in a column
    -- there is no flow to unbalance.
    local a = PAGE:find('Add(contentBand, nil, "both")', 1, true)
    local b = PAGE:find('Add(iconBand, nil, "both")', 1, true)
    local c = PAGE:find('Add(textBand, nil, "both")', 1, true)
    local d = PAGE:find('Add(factoryBand, nil, "both")', 1, true)
    check(a and b and c and d and a < b and b < c and c < d,
          "order: the four bands span both columns, in reading order")

    -- ---- the page's own furniture is untouched -------------------------
    check(PAGE:find('CreateCopyButton(self.child, {"debuff", "showDebuffs", "directDebuff", "debuffBlacklist"}', 1, true) ~= nil,
          "page: the copy button keeps the four prefixes it owns")
    check(PAGE:find('{pageId = "auras_dispel", label = L["Dispel Overlay"]}', 1, true) ~= nil,
          "page: ...and the See Also block is unchanged")
    check(PAGE:find("No Pandemic box here, unlike Buffs", 1, true) ~= nil,
          "page: ...and the note saying why this page has no Pandemic row survives")
end

-- ============================================================
-- 8. THE SHARED-MACHINERY CHANGE THIS PAGE NEEDED
-- A pane can now answer GUI:RelayoutHost's walk. The caution banner behind the
-- Debuff Filters row is the first widget the sweep has put in a pane that learns
-- its own height a frame LATE and cannot be opted out of it -- a measured label
-- with an explicit slot height is suppressed by _slotHeightExplicit, and only
-- opts.staticHeight silences a banner, which would change what classic draws.
-- ============================================================
print("-- Debuff Bar page: the shared machinery it needed")
do
    check(CTRL:find("pane.dfReflowPane = function() ReflowPane(st) end", 1, true) ~= nil,
          "relayout: the toolkit stamps the pane with its own re-flow at the mount")
    check(SW:find('if type(p.dfReflowPane) == "function" then', 1, true) ~= nil,
          "relayout: ...and RelayoutHost's walk stops at it")
    -- Above the generic page branch, and below the AD card's, so a pane is reached
    -- before the walk runs on to the settings window.
    local cardAt = SW:find("dfAD_ReflowWidgets) ==", 1, true)
    local paneAt = SW:find("dfReflowPane) ==", 1, true)
    local pageAt = SW:find('if type(p.RefreshStates) == "function" and p.children then', 1, true)
    check(cardAt and paneAt and pageAt and cardAt < paneAt and paneAt < pageAt,
          "relayout: ...between the AD card's branch and the page's")
    -- The banner is genuinely in the pane: it is built by the shared builder, so
    -- both layouts get it.
    check(builderBody("BuildDebuffFilterGroup"):find("GUI:CreateInfoBanner(parent, {", 1, true) ~= nil,
          "relayout: the caution banner is built by the shared builder, so the pane really does mount one")
end
