local NS = ...

-- ============================================================
-- BUFF BAR PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Indicators.lua
-- ------------------------------------------------------------
-- Auras > Buff Bar is the widest page the sweep has taken: TWELVE groups.
--
-- ☠ AND IT IS NOW THE COLLAPSIBLE-SECTION TEST. Eleven of those twelve were
-- popout ROWS -- a plate with a bottom strip that opened a floating panel, a
-- "N more settings" badge and a pin. Testers could not find settings in it, and
-- a control hoisted onto a row while the same control sat in the panel behind it
-- read as two settings. So on THIS PAGE ONLY they are collapsible SECTIONS: the
-- whole header opens and shuts the section in place, the controls live on the
-- page, and a shut header keeps the row's old summary string in its right
-- corner. The twelfth, a lone checkbox, is still a CONTROL ROW.
--
--   column 1   "Content"  Visibility, Buff Filters, Order & Limits and the
--                         Hide Duplicate Buffs control row.
--              ...then    Duration Bar and Pandemic, the two 12.1-factory
--                         extras, under NO category header: both carry the same
--                         hideOn, so a header there would be a title standing
--                         over nothing on a client with no factory row.
--   column 2   "Icon"     Appearance, Layout, Position, Border.
--              "Text"     Duration Text, Stack Count.
--
-- ☠ THE DEBUFF BAR USES THE SAME CARDS (the section helper was lifted into the
-- page tools for it), and this page now takes its two opt-ins as well -- two
-- per row and dim captions -- so the twin pages match. The Debuff Bar's census
-- file pins how the opt-ins work; this one pins that the Buff Bar asks for both.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db, the filter
-- registry -- so this file does what the other census files do: it reads the
-- page's SOURCE and asserts against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each extracted builder -- kind, L key, db key and
--     slot height, in order -- UNCHANGED from the golden taken before the popout
--     sweep, which is the evidence that neither layout's controls moved.
--   ✓ that ONE builder still serves both layouts, and that the section branch
--     now hands it EXACTLY what the classic branch hands it.
--   ✓ that every section is in the column its band was in, with a STABLE
--     collapse key rather than its localised title.
--   ✓ that each section's summary and grey gate are the row's, verbatim.
--   ✓ that the popout furniture is gone from this page ENTIRELY rather than
--     half-removed -- no rows, no claims, no counts, no footers, no hoists.
--   ✗ nothing about runtime behaviour -- the folding, the greying and the
--     summaries are read by eye and by the in-game checklist.
-- ============================================================

-- ⚠ NORMALISED TO LF UP FRONT. This page file ships CRLF (the companion's files
-- are mixed per file), and a plain multi-line `find` for source text would miss
-- every one of them otherwise. Nothing here asserts about line endings.
local SRC = options_file_source("GUI/Pages/Indicators.lua"):gsub("\r\n", "\n")
local CTRL = options_file_source("GUI/Controls.lua"):gsub("\r\n", "\n")
local WIDGETS = options_file_source("GUI/SettingsWidgets.lua"):gsub("\r\n", "\n")

-- ---- the census reader (the Frame page's, plus this page's composites) ----
-- The four extra kinds are the shared helpers this page mounts as single
-- widgets or single blocks. Without them the census would silently skip a
-- growth control, a whole TextStyle block and the entire border toolkit --
-- which is most of what two of these sections ARE.
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateSeparator = "separator", CreateButton = "button",
    CreateGrowthControl = "growth", CreateTextureDropdown = "texturedropdown",
    CreateTextControls = "textcontrols", CreateBorderControls = "bordercontrols",
    CreatePandemicControls = "pandemic", CreateDurationFormatControls = "durationformat",
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
    local a = SRC:find('BuildPage(pageBuffs, function(self, db, Add, AddSpace, AddSyncPoint)', 1, true)
    local b = SRC:find('local pageDebuffs = CreateSubTab("auras", "auras_debuffs", L["Debuff Bar"])', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Buff Bar page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- ⚠ THE SECTION HELPER'S BODY LIVES IN THE PAGE TOOLS (GUI/Controls.lua) since
-- the Debuff Bar was converted: this page's own OpenSection / CloseSection are
-- one-line forwards to tools.OpenSection / tools.CloseSection, with the SAME
-- arguments in the same order and no `extra`. Every check below that read the
-- page's local body reads the shared one instead, flattened the same way.
local OPEN = (CTRL:match("\n    local function OpenSection%(Add, .-\n    end\n") or ""):gsub("%s+", " ")
local CLOSE = CTRL:match("\n    local function CloseSection%(Add, band%)(.-)\n    end\n")

-- ONE SECTION'S BLOCK: its OpenSection call, the builder mount under it and the
-- CloseSection that puts its band in. Read as "from the call to the close" for
-- the same reason the Frame page's census reads declaration-to-declaration: two
-- of these calls wrap onto a second line, so a line-bounded match would drop
-- half of what they say.
local function sectionBlock(labelKey)
    local a = PAGE:find('OpenSection(L["' .. labelKey .. '"]', 1, true)
    check(a ~= nil, "source: a collapsible section is opened for " .. labelKey)
    if not a then return "" end
    local b = PAGE:find("CloseSection(band)", a, true)
    check(b ~= nil, "source: ..." .. labelKey .. "'s band is closed after its controls")
    return PAGE:sub(a, (b or a) + #"CloseSection(band)"):gsub("%s+", " ")
end

-- What every converted group on this page has in common.
local function checkShared(builder, label, boxHeader, classicColumn, collapseKey, column, summary, ticked)
    -- ONE builder, BOTH layouts: the declaration and the two mounts.
    local calls = 0
    for _ in PAGE:gmatch(builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, label .. ": declared once, mounted twice -- classic box and page section")

    -- The classic branch builds the box it always did, with its own header, in
    -- the column it always had. Not one line of it moved for the fold.
    check(PAGE:find('GUI:CreateHeader(self.child, L["' .. boxHeader .. '"])', 1, true) ~= nil,
          label .. ": the classic box keeps its own header (" .. boxHeader .. ")")
    -- The box VARIABLE, found by walking every bare 280 box on the page and
    -- asking which one puts this header on itself. A fixed line distance would
    -- not do: two of these boxes carry a hideOn and an essay between the two
    -- lines, and one of them is four comment lines deep.
    local box
    for at, name in PAGE:gmatch("()local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)") do
        local want = name .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. boxHeader .. '"])'
        local hit = PAGE:find(want, at, true)
        if hit and hit - at < 900 then box = name break end
    end
    check(box ~= nil, label .. ": ...and that header belongs to a bare 280 box")
    if box then
        check(PAGE:find("Add(" .. box .. ", nil, " .. classicColumn .. ")", 1, true) ~= nil,
              label .. ": ...which still goes to column " .. classicColumn)
    end

    -- ---- and the section half -----------------------------------------
    local block = sectionBlock(label)
    -- ☠ A STABLE COLLAPSE KEY, NEVER THE TITLE. CreateCollapsibleSection keys
    -- its SavedVariables slot on whatever it is handed, so a localised or
    -- reworded title would write a second slot and orphan the user's fold.
    check(block:find('OpenSection(L["' .. label .. '"], "' .. collapseKey .. '", ' .. column .. ',', 1, true) ~= nil,
          label .. ": the section carries a stable collapse key and sits in column " .. column)
    check(block:find(summary, 1, true) ~= nil,
          label .. ": ...and prints the row's own summary in its shut corner")
    -- The SAME builder the classic arm calls, handed the SAME table: no
    -- `popout`, so the two mounts are one call twice. A section whose on/off
    -- tick lives in its HEADER adds exactly one field, `hoistToggle = true`,
    -- which is what stops the builder drawing that checkbox a second time.
    local mount = builder .. "({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end,"
        .. (ticked and " hoistToggle = true," or "") .. " })"
    check(block:find(mount, 1, true) ~= nil,
          label .. (ticked and ": ...and mounts the builder as classic does, plus hoistToggle for its header tick"
                            or ": ...and mounts the builder exactly as classic does"))
    return block
end

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED MACHINERY, AND ITS VOCABULARY MOVED UP
-- ============================================================
print("-- Buff Bar page: the shared machinery and the page-scope vocabulary")
do
    check(PAGE:find("local classicLayout = DF:IsClassicSettingsLayout()", 1, true) ~= nil,
          "tools: the page asks which layout it is building")
    -- ⚠ STILL TAKEN IN FULL, with no row left on the page. Its PROLOGUE closes
    -- any panel a previous build left standing and retires that build's holders
    -- -- a mode switch into this page can arrive with one open from the Debuff
    -- Bar page -- and the page still wants BandWidth and RegisterControlRow.
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

    -- ---- the section helpers, declared once ---------------------------
    -- ☠ THE SECTION AND ITS BAND ARE BOTH PAGE CHILDREN, and that is the whole
    -- mechanism. Panel.lua's state pass is the only thing that reads
    -- `widget.collapsibleSection` and hides what a shut section registered; a
    -- group nested inside another group never reaches it.
    check(PAGE:find("local function OpenSection(label, key, col, summaryFn, dimFn, hideFn, builder, toggle)", 1, true) ~= nil,
          "sections: the page opens a section in one named place")
    check(PAGE:find("local function CloseSection(band)", 1, true) ~= nil,
          "sections: ...and closes one in another")
    -- ...each a forward to the shared helper, now with the Debuff Bar's two
    -- opt-ins (two tracks, quiet captions), so the twin pages match.
    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: ...the page's OpenSection forwards to the shared one, asking for two per row and dim captions")
    -- The moved dedup takes a row of its own on a two-track card.
    check(sectionBlock("Buff Filters"):find("dedupCb.fullRow = true", 1, true) ~= nil,
          "sections: Hide Duplicate Buffs sits on a row of its own at the foot of Buff Filters")
    check(PAGE:find("tools.CloseSection(Add, band)", 1, true) ~= nil,
          "sections: ...and so does its CloseSection")
    local open = OPEN
    check(open:find("GUI:CreateCollapsibleSection(page.child, label, true, BandWidth(col), { collapseKey = key, summary = summaryFn, dimOn = dimFn, pin = pin, card = true, toggle = toggle })", 1, true) ~= nil,
          "sections: ...built from the kit's own section, at its column's width")
    check(open:find("Add(section, 36, col)", 1, true) ~= nil,
          "sections: ...the header is a page child, so the state pass can reach it")
    check(open:find("GUI:CreateSettingsGroup(page.child, BandWidth(col), { chromeless = true })", 1, true) ~= nil,
          "sections: ...the band is chromeless, at the width the layout pass will give it")
    check(open:find("section:RegisterChild(band)", 1, true) ~= nil,
          "sections: ...and registered to the section, which is what makes the fold hide it")
    -- ☠ EXPANDED ON A FIRST RUN. This is a test of FOLDING, so nothing may start
    -- hidden; the user's own folds are what persist after that.
    check(open:find("label, true,", 1, true) ~= nil,
          "sections: ...and every section starts expanded, so nothing is hidden by default")
    -- ☠ THE BAND GOES IN AFTER ITS LAST CONTROL. `Add` resolves a widget's slot
    -- height on the spot, so a band Add'd while still empty gets no room.
    local close = CLOSE
    check(close ~= nil and close:find("Add(band, nil, band.dfSectionCol)", 1, true) ~= nil,
          "sections: the band is added in its own right, in the column its section is in")

    -- ---- the three category headers -----------------------------------
    -- ⚠ ADDED STRAIGHT TO A COLUMN, not into a band: there is no band spanning a
    -- whole category any more, so the header that names one is a page child like
    -- the sections under it.
    for _, pair in ipairs({ { "Content", "1" }, { "Icon", "2" }, { "Text", "2" } }) do
        check(PAGE:find('Add(GUI:CreateHeader(self.child, L["' .. pair[1] .. '"]), 40, ' .. pair[2] .. ')', 1, true) ~= nil,
              "bands: the " .. pair[1] .. " category header opens column " .. pair[2])
    end
    -- ☠ AND THE FACTORY PAIR HAS NO HEADER. Both carry HideDurationBar, so a
    -- header there would be a section title left standing over nothing.
    for _, band in ipairs({ "contentBand", "iconBand", "textBand", "factoryBand" }) do
        check(PAGE:find(band, 1, true) == nil,
              "bands: the old " .. band .. " is gone -- every section carries a band of its own")
    end

    -- ---- the vocabulary, at PAGE scope, declared exactly once ---------
    -- The sections print the chosen value as their SUMMARY, and a summary is
    -- built outside the group's builder -- so the word has to come out of the
    -- same table the dropdown offers.
    for _, name in ipairs({ "anchorOptions", "buffSortOptions", "durationFormatOptions",
                            "durBarPositionOptions" }) do
        local decls = 0
        for _ in PAGE:gmatch("local " .. name .. " = {") do decls = decls + 1 end
        eq(decls, 1, "vocab: " .. name .. " is declared exactly once, at page scope")
    end
    check(PAGE:find('DEFAULT = L["Default (Slot Order)"]', 1, true) ~= nil
      and PAGE:find('TIMER = L["Timer"]', 1, true) ~= nil,
          "vocab: ...and they are the same tables the dropdowns have always offered")

    -- ⚠ ABOVE EVERY BUILDER. A builder is a closure and captures the upvalue that
    -- exists when it is created, so one declared above these would see nil.
    local vocabAt = PAGE:find("local anchorOptions = {", 1, true)
    for _, b in ipairs({ "BuildVisibilityGroup", "BuildBuffFilterGroup", "BuildBuffOrderGroup",
                         "BuildBuffAppearanceGroup", "BuildBuffLayoutGroup",
                         "BuildBuffPositionGroup", "BuildBuffBorderGroup",
                         "BuildBuffDurationGroup", "BuildBuffStackGroup",
                         "BuildBuffDurationBarGroup", "BuildBuffPandemicGroup" }) do
        local at = PAGE:find("local function " .. b .. "(tools2)", 1, true)
        check(at ~= nil and vocabAt ~= nil and vocabAt < at,
              "vocab: " .. b .. " is declared after it, so it closes over the real tables")
    end

    -- The registry hook block runs ONCE PER PAGE BUILD, in both layouts -- not
    -- once per pane instance, which is what leaving it in the builder would mean.
    check(PAGE:find("self.dfBuffFilterSignature = RegistrySignature()", 1, true) ~= nil,
          "vocab: the filter-registry signature is taken at page scope")
    local hooks = 0
    for _ in PAGE:gmatch("self:HookScript%(\"OnShow\"") do hooks = hooks + 1 end
    eq(hooks, 1, "vocab: ...and the OnShow invalidation is hooked exactly once")
    check(builderBody("BuildBuffFilterGroup"):find("HookScript", 1, true) == nil,
          "vocab: ...from outside the builder, so nothing can re-take it per instance")
end

-- ============================================================
-- 2. THE PAGE GATE -- showBuffs greys the sections it greyed rows
-- ============================================================
print("-- Buff Bar page: the page gate")
do
    check(PAGE:find("local function BuffsOffRow(d) return not (d or db).showBuffs end", 1, true) ~= nil,
          "gate: the page names its own gate once")

    -- Eight sections greyed, and they are exactly the eight the rows greyed --
    -- which are exactly the groups classic dims. `dimOn` is the header half:
    -- the kit greys the section title, the band's own disableOn/disableChildrenOn
    -- greys the controls under it, exactly as they did inside a pane.
    for _, name in ipairs({ "Order & Limits", "Appearance", "Layout", "Position",
                            "Border", "Duration Text", "Stack Count", "Duration Bar" }) do
        check(sectionBlock(name):find("BuffsOffRow", 1, true) ~= nil,
              "gate: the " .. name .. " section greys while the bar is off")
    end
    -- Pandemic greys for a second reason as well: the silent-capability-skip
    -- rule, which the suppressed Enable checkbox used to carry itself.
    check(PAGE:find("return not pandemicSupported or BuffsOffRow(d)", 1, true) ~= nil,
          "gate: the Pandemic section greys on an unsupported client too")

    -- ...and the three that classic has NEVER dimmed do not start now.
    for _, name in ipairs({ "Visibility", "Buff Filters" }) do
        check(sectionBlock(name):find("BuffsOffRow", 1, true) == nil,
              "gate: the " .. name .. " section is not greyed -- its box never was")
    end
    check(PAGE:find("dedupRow.disableOn", 1, true) == nil,
          "gate: the Hide Duplicate Buffs control row is not greyed -- its box never was")

    -- ☠ AND THE INDEX-1 REPAIR IS GONE, as a deletion rather than an omission. A
    -- group gate used to skip child one because in a classic box that child is
    -- the HEADER; a band's first child is a real control. DandersUI Sections'
    -- RefreshChildStates now skips on the `isSectionHeader` MARK instead of on
    -- the position, so a band greys from `group.disableChildrenOn` on its own.
    -- ⚠ THE DECLARATION AND THE CALL SITES, not the WORD. The border builder's
    -- own comment still names the repair to say why that group never needed one,
    -- and that sentence is as true now as it was.
    check(PAGE:find("local function GatePaneFirstChild(", 1, true) == nil,
          "gate: the index-1 repair is gone -- the kit skips on the header MARK now")
    local gated = 0
    for _ in PAGE:gmatch("\n%s+GatePaneFirstChild%(group%)\n") do gated = gated + 1 end
    eq(gated, 0, "gate: ...and nothing on the page still applies it")
    check(WIDGETS:find("container.isSectionHeader = true", 1, true) ~= nil,
          "gate: ...and GUI:CreateHeader is what stamps that mark")
    -- The three builders that carry a group-wide gate still carry it, because a
    -- band is a group like any other.
    for _, b in ipairs({ "BuildBuffOrderGroup", "BuildBuffDurationGroup", "BuildBuffStackGroup" }) do
        check(builderBody(b):find("group.disableChildrenOn = function(d) return not d.showBuffs end", 1, true) ~= nil,
              "gate: " .. b .. " still carries the group gate")
    end
end

-- ============================================================
-- 3. THE DURATION FORMAT GATE -- a state pass, never a rebuild
-- Picking a format re-gates the two Hide Above controls (neither composes with
-- Percent). Classic used to pay for that with a page REBUILD, which leaked the
-- whole page into GUI._trashFrame per pick; it re-lays the page now.
-- ============================================================
print("-- Buff Bar page: the duration format gate")
do
    local gate = PAGE:match("local function DurationFormatRefresh%(tools2%)(.-)\n        end")
    check(gate ~= nil, "format gate: the page decides this once, in a named function")
    if gate then
        -- ⚠ THE PANE BRANCH STAYS, UNEXERCISED. The builder is untouched, and
        -- leaving the branch in is what keeps it one function rather than two
        -- the day a row comes back.
        check(gate:find("if tools2.popout then", 1, true) ~= nil,
              "format gate: ...branching on which layout the group was built for")
        check(gate:find("GUI.RelayoutCurrentPage()", 1, true) ~= nil,
              "format gate: ...and the page arm re-lays the page")
        check(gate:find("GUI:RefreshCurrentPage()", 1, true) == nil,
              "format gate: ...without rebuilding it (the rebuild leaked the page)")
    end

    -- ...and no page rebuild is left anywhere on this page.
    local rebuilds = 0
    for _ in PAGE:gmatch("GUI:RefreshCurrentPage") do rebuilds = rebuilds + 1 end
    eq(rebuilds, 0, "format gate: no page rebuild left on the page")

    for _, b in ipairs({ "BuildVisibilityGroup", "BuildBuffFilterGroup", "BuildBuffOrderGroup",
                         "BuildBuffAppearanceGroup", "BuildBuffLayoutGroup",
                         "BuildBuffPositionGroup", "BuildBuffBorderGroup",
                         "BuildBuffDurationGroup", "BuildBuffStackGroup",
                         "BuildBuffDurationBarGroup", "BuildBuffPandemicGroup" }) do
        check(builderBody(b):find("GUI:RefreshCurrentPage", 1, true) == nil,
              "format gate: " .. b .. " never rebuilds the page from inside itself")
    end

    -- ☠ AND NOT ONE MOUNT DECLARES ITSELF A PANE ANY MORE. Eleven did; a section
    -- hands the builder the classic table, so a `popout = true` left behind here
    -- would be a builder taking the pane branch on a page that has no panes.
    local popouts = 0
    for _ in PAGE:gmatch("popout = true,") do popouts = popouts + 1 end
    eq(popouts, 0, "format gate: no mount on the page declares itself a pane")
end

-- ============================================================
-- 4. THE ELEVEN BUILDERS, CONTROL BY CONTROL
-- Every golden below is the census of the PRE-CHANGE source: same factories,
-- same L keys, same db keys, same slot heights, in the same order. Not one of
-- them moved for the fold, which is the point of keeping them here unchanged.
-- ============================================================
local VISIBILITY = {
    { "checkbox", "Show Buffs", "showBuffs", 30 },
    { "slider",   "Max Buffs",  "buffMax",   55 },
}
-- The filter list is DATA: two scope switches, the rule, the caption, ONE
-- SelectionCheckbox factory (which the two loops and the complement bucket all
-- go through), the tracking count and Manage Filters.
local BUFF_FILTERS = {
    { "checkbox",  "All Buffs",     "directBuffShowAll",  30 },
    { "checkbox",  "Only My Buffs", "directBuffOnlyMine", 30 },
    { "separator", "(none)",        "(none)",             14 },
    { "label",     "(none)",        "(none)",             35 },
    { "checkbox",  "(none)",        "(none)",             30 },
    { "label",     "(none)",        "(none)",             24 },
    { "button",    "Manage Filters", "(none)",            30 },
}
local BUFF_ORDER = {
    { "dropdown", "Sort Order",                 "directBuffSortOrder",      55 },
    { "checkbox", "My Auras First",             "directBuffSortMineFirst",  30 },
    { "checkbox", "Reverse Order",              "directBuffSortReverse",    30 },
    { "checkbox", "Hide Long Buffs",            "buffMaxDurationEnabled",   30 },
    { "slider",   "Hide Longer Than (minutes)", "buffMaxDurationMinutes",   55 },
    { "checkbox", "Hide Permanent Auras",       "buffHidePermanent",        30 },
}
local BUFF_APPEARANCE = {
    { "slider", "Icon Size", "buffSize",  55 },
    { "slider", "Scale",     "buffScale", 55 },
    { "slider", "Alpha",     "buffAlpha", 55 },
}
local BUFF_LAYOUT = {
    { "slider", "Icons Per Row", "buffWrap",     55 },
    { "slider", "Spacing X",     "buffPaddingX", 55 },
    { "slider", "Spacing Y",     "buffPaddingY", 55 },
}
local BUFF_POSITION = {
    { "dropdown", "Anchor",   "buffAnchor",  55 },
    { "growth",   "(none)",   "buffGrowth",  155 },
    { "slider",   "Offset X", "buffOffsetX", 55 },
    { "slider",   "Offset Y", "buffOffsetY", 55 },
}
local BUFF_BORDER = {
    -- The key the census reads off this one is the PREFIX the toolkit is handed,
    -- not a setting -- every one of its eighteen keys is built from it.
    { "bordercontrols", "(none)", "buff", nil },
}
local BUFF_DURATION = {
    { "checkbox",       "Show Duration",                    "buffShowDuration",              30 },
    { "checkbox",       "Hide Cooldown Swipe",              "buffHideSwipe",                 30 },
    { "durationformat", "(none)",                           "buffDurationFormat",            nil },
    { "textcontrols",   "(none)",                           "buffDuration",                  nil },
    { "checkbox",       "Color by Time Remaining",          "buffDurationColorByTime",       30 },
    { "checkbox",       "Hide Above Threshold",             "buffDurationHideAboveEnabled",  30 },
    { "slider",         "Hide Above (seconds)",             "buffDurationHideAboveThreshold", 55 },
    { "checkbox",       "Hide Duration on Permanent Auras", "buffDurationHideOnPermanent",   30 },
}
local BUFF_STACK = {
    { "textcontrols", "(none)", "buffStack", nil },
}
local BUFF_DURBAR = {
    { "label",            "Shows a bar on each icon that drains with the aura's remaining time.", "(none)", 30 },
    { "checkbox",         "Enable Duration Bar", "buffDurationBarEnabled",    30 },
    { "dropdown",         "Position",            "buffDurationBarPosition",   55 },
    { "slider",           "Height",              "buffDurationBarHeight",     55 },
    { "slider",           "Gap",                 "buffDurationBarGap",        55 },
    { "dropdown",         "Color Mode",          "buffDurationBarColorMode",  55 },
    { "texturedropdown",  "Texture",             "buffDurationBarTexture",    55 },
    { "colorpicker",      "Bar Color",           "buffDurationBarColor",      30 },
    { "colorpicker",      "Background Color",    "buffDurationBarBGColor",    30 },
    { "checkbox",         "Reverse Fill",        "buffDurationBarReverseFill", 30 },
}
local BUFF_PANDEMIC = {
    { "label",    "Highlights each icon once the aura can be refreshed without losing time.", "(none)", 30 },
    { "pandemic", "(none)", "(none)", nil },
}

-- The eleven, in the order the page builds them. `classicColumn` is where the
-- 280 box still goes; `column` is where the SECTION goes, which is where the
-- band that held the row went -- the two differ on Border and Pandemic, which
-- classic crosses for column balance and the swept layout never did.
local SECTIONS = {
    { builder = "BuildVisibilityGroup", label = "Visibility", boxHeader = "Visibility",
      golden = VISIBILITY, classicColumn = "1", key = "buffs_visibility", column = "1",
      summary = "VisibilitySummary", hoistedIn = 1 },
    { builder = "BuildBuffFilterGroup", label = "Buff Filters", boxHeader = "Buff Filters",
      golden = BUFF_FILTERS, classicColumn = "1", key = "buffs_filters", column = "1",
      summary = "BuffFilterSummary" },
    { builder = "BuildBuffOrderGroup", label = "Order & Limits", boxHeader = "Order & Limits",
      golden = BUFF_ORDER, classicColumn = "1", key = "buffs_order", column = "1",
      summary = "BuffOrderSummary" },
    { builder = "BuildBuffAppearanceGroup", label = "Appearance", boxHeader = "Appearance",
      golden = BUFF_APPEARANCE, classicColumn = "2", key = "buffs_appearance", column = "2",
      summary = "BuffAppearanceSummary" },
    { builder = "BuildBuffLayoutGroup", label = "Layout", boxHeader = "Layout",
      golden = BUFF_LAYOUT, classicColumn = "1", key = "buffs_layout", column = "2",
      summary = "BuffLayoutSummary" },
    { builder = "BuildBuffPositionGroup", label = "Position", boxHeader = "Position",
      golden = BUFF_POSITION, classicColumn = "1", key = "buffs_position", column = "2",
      summary = "BuffPositionSummary" },
    { builder = "BuildBuffBorderGroup", label = "Border", boxHeader = "Border",
      golden = BUFF_BORDER, classicColumn = "1", key = "buffs_border", column = "2",
      summary = "BuffBorderSummary", hoistedIn = 0,
      tick = { key = "buffShowBorder", label = "Show Border" } },
    { builder = "BuildBuffDurationGroup", label = "Duration Text", boxHeader = "Duration Text",
      golden = BUFF_DURATION, classicColumn = "2", key = "buffs_duration", column = "2",
      summary = "BuffDurationSummary", hoistedIn = 1,
      tick = { key = "buffShowDuration", label = "Show Duration" } },
    { builder = "BuildBuffStackGroup", label = "Stack Count", boxHeader = "Stack Count",
      golden = BUFF_STACK, classicColumn = "2", key = "buffs_stack", column = "2",
      summary = "BuffStackSummary" },
    { builder = "BuildBuffDurationBarGroup", label = "Duration Bar", boxHeader = "Duration Bar",
      golden = BUFF_DURBAR, classicColumn = "2", key = "buffs_durationbar", column = "1",
      summary = "BuffDurationBarSummary", hoistedIn = 1, hide = true,
      tick = { key = "buffDurationBarEnabled", label = "Enable Duration Bar" } },
    { builder = "BuildBuffPandemicGroup", label = "Pandemic", boxHeader = "Pandemic",
      golden = BUFF_PANDEMIC, classicColumn = "2", key = "buffs_pandemic", column = "1",
      summary = "BuffPandemicSummary", hoistedIn = 0, hide = true,
      tick = { key = "buffPandemicEnabled", label = "Enable" } },
}

for _, g in ipairs(SECTIONS) do
    print("-- Buff Bar page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())
    local block = checkShared(g.builder, g.label, g.boxHeader, g.classicColumn, g.key, g.column, g.summary, g.tick ~= nil)

    -- ☠ THE HOIST BRANCH IS TAKEN AGAIN, BY THE HEADER TICK. Five builders can
    -- suppress their own enable control; four of them are now asked to, because
    -- that control lives in their section HEADER. Visibility can, and is never
    -- asked to: Show Buffs is the page's master switch and stays in the body.
    if g.hoistedIn == 1 then
        check(body:find("if not tools2.hoistToggle then", 1, true) ~= nil,
              g.label .. ": the builder can still skip its enable checkbox")
    elseif g.hoistedIn == 0 then
        check(body:find("tools2.hoistToggle or nil", 1, true) ~= nil,
              g.label .. ": the composite can still be told not to build its own toggle")
    else
        check(body:find("hoistToggle", 1, true) == nil,
              g.label .. ": the builder has no hoist branch, because there was never anything to hoist")
    end
    local hoists = select(2, block:gsub("hoistToggle = true", ""))
    if g.tick then
        eq(hoists, 1, g.label .. ": ...and the section mount asks for the hoist, once -- the tick is in the header")
    else
        eq(hoists, 0, g.label .. ": ...and the section mount asks for no hoist")
    end

    -- The two that can vanish outright carry the box's own factory gate, on BOTH
    -- halves: with no factory row there is no bar, and a header standing over a
    -- band the page has folded away would be a title over nothing.
    if g.hide then
        check(block:find("HideDurationBar", 1, true) ~= nil,
              g.label .. ": the section hides with the factory gate its box carries")
    else
        check(block:find("HideDurationBar", 1, true) == nil,
              g.label .. ": the section has no factory gate, because its box never had one")
    end
end

-- ============================================================
-- 5. THE POPOUT FURNITURE IS GONE FROM THIS PAGE, NOT HALF-GONE
--
-- ☠ WHAT THE ROWS TOOK WITH THEM, NAMED. No pin, no "N more settings" badge, no
-- amber modified tick and no Reset Group / Hold: Defaults footer: all four are
-- PopoutRow's, and there is no row left to hang them on. Classic has never had
-- any of them either. This section is what stops the page drifting back into a
-- half-state -- a claim without a row, a count constant nothing reads -- while
-- the fold is being judged.
-- ============================================================
print("-- Buff Bar page: the popout furniture is gone")
do
    -- ⚠ tools.PopoutContent IS NO LONGER ON THIS LIST, and that is the pin.
    -- The page mounts a panel's worth of content again -- but exactly ONCE, in
    -- OpenSection, for a section that asked for a pin. Pinned to a COUNT in
    -- section 8 rather than to zero, so a builder that quietly grows a second
    -- mount is still caught. Everything else a ROW brought stays gone: the page
    -- builds no row of its own (the kit owns the one behind the pin), claims no
    -- keys, promises no count and hangs no footer.
    for _, verb in ipairs({ "GUI:CreatePopoutRow", "tools.ClaimKeys",
                            "tools.WireModifiedTick", "tools.WireFooter",
                            "tools.RegisterHoistedToggle", "tools.ReflowMounted",
                            "inline = true", "footerStrip" }) do
        check(PAGE:find(verb, 1, true) == nil,
              "furniture: no " .. verb .. " left on the page")
    end
    -- The count constants went with the badge that read them.
    local counts = 0
    for _ in PAGE:gmatch("_COUNT") do counts = counts + 1 end
    eq(counts, 0, "furniture: no row-count constant left, because nothing promises a number now")
    -- ...and so did the commit callbacks a hoisted tick needed.
    for _, fn in ipairs({ "OnShowBuffsToggle", "OnBuffBorderToggle", "OnBuffDurationToggle",
                          "OnBuffDurationBarToggle", "OnBuffPandemicToggle" }) do
        check(PAGE:find(fn, 1, true) == nil,
              "furniture: the hoisted-tick commit " .. fn .. " is gone with the tick")
    end

    -- ☠ THE ONE THING THAT DID NOT GO: the filter row's refusal of a footer is
    -- now moot, but the REASON is still true and still written down, because the
    -- day a footer comes back to this page it must not come back here. Reset
    -- Group writes DeepCopy(default) into the key, which for buffFilterSelection
    -- REPLACES the table -- and the aura pipeline holds references to it.
    check(PAGE:find("NEVER reassign buffFilterSelection", 1, true) ~= nil,
          "furniture: the filter selection table's no-reassign rule is still stated")

    -- ---- and SEARCH is covered by the section, not by a claim ---------
    -- ☠ A ROW HAD TO BE TOLD ITS OWN NAME (ClaimKeys' two halves): it has no
    -- header, so nothing on the page answered to it and every control behind it
    -- registered under whichever band header was built last. A SECTION needs
    -- neither half. CreateCollapsibleSection moves Search.CurrentSection itself,
    -- so every control built after it takes that breadcrumb through the ordinary
    -- widget path -- exactly as it does in classic -- and its GetText is what
    -- ScrollToSection and every GUI:LinkToSetting{ section = ... } find it by.
    check(WIDGETS:find("DF.Search:SetCurrentSection(text)", 1, true) ~= nil,
          "search: CreateCollapsibleSection stamps the breadcrumb every control after it registers under")
    check(WIDGETS:find("section.GetText = function(self) return self.sectionTitleText end", 1, true) ~= nil,
          "search: ...and answers to its own name, which is what a jump finds it by")
end

-- ============================================================
-- 6. THE SUMMARY OPT-IN THE KIT GAINED
-- A popout row painted its summary; a section had nowhere to put one. Added to
-- GUI:CreateCollapsibleSection as `opts.summary` (and `opts.dimOn` beside it),
-- both opt-in, so no existing section moves.
-- ============================================================
print("-- Buff Bar page: the section summary opt-in")
do
    check(WIDGETS:find("local summaryFn = opts and opts.summary or nil", 1, true) ~= nil
      and WIDGETS:find("local dimFn     = opts and opts.dimOn or nil", 1, true) ~= nil,
          "summary: the section reads both options off opts")
    -- ⚠ OPT-IN, and that is what keeps every existing caller still: no summary
    -- and no dim means no fontstring and no refreshContent at all.
    check(WIDGETS:find("if summaryFn or dimFn or toggleOpts then", 1, true) ~= nil,
          "summary: ...and builds nothing at all for a caller that passes neither")
    -- Painted the way a popout row paints its own: right-aligned, never wrapped.
    check(WIDGETS:find('section.summary:SetPoint("RIGHT", section, "RIGHT", -10, 0)', 1, true) ~= nil,
          "summary: ...pinned to the header's right corner")
    check(WIDGETS:find('section.summary:SetJustifyH("RIGHT")', 1, true) ~= nil,
          "summary: ...right-justified, like the row's was")
    -- ☠ SHUT ONLY. Expanded, the controls themselves are the answer.
    check(WIDGETS:find("if not self.expanded and summaryFn then", 1, true) ~= nil,
          "summary: ...and shown only while the section is shut")
    -- ⚠ DEDUPED. refreshContent runs on EVERY state pass and SetText re-measures.
    check(WIDGETS:find("if self._dfSummaryText ~= text then", 1, true) ~= nil,
          "summary: ...written only when the rendered string actually moved")
    -- The dim half routes through the section's existing greying verb rather
    -- than a second colour path of its own.
    check(WIDGETS:find("if dimFn then self:SetPreviewDimmed(dimFn(d) and true or false) end", 1, true) ~= nil,
          "summary: the grey gate goes through the section's own SetPreviewDimmed")
    -- A bounded title (a pinned header) must be told to sit left, or it centres
    -- in the box SetHeaderRightInset gives it -- every pinned header did.
    local inset = WIDGETS:find("section.SetHeaderRightInset = function", 1, true)
    check(inset ~= nil and WIDGETS:find('self.title:SetJustifyH("LEFT")', inset, true) ~= nil,
          "summary: a bounded header title is left-justified, not centred")
    -- With a pin the summary takes its width from apply(), never from the tag,
    -- or it is left a zero-width slot and draws nothing.
    check(WIDGETS:find('self.tag:SetPoint("RIGHT", self.summary, "LEFT", -8, 0)', 1, true) ~= nil,
          "summary: beside a pin, the tag stops at the summary rather than squeezing it out")
end

-- ============================================================
-- 7. THE CONTROL ROW, THE SECTIONS THAT CAN HIDE, AND THE PAGE'S OWN ORDER
-- ============================================================
print("-- Buff Bar page: the control row, the columns and the order")
do
    -- ---- the one single-option group: INSIDE BUFF FILTERS in Modern ----
    -- As a lone control row between the cards it was the one element with its
    -- own width, height and indent. It decides which buffs show, so it is a
    -- filter: in Modern it is the last control of the Buff Filters section.
    local filtersOpen = PAGE:find('OpenSection(L["Buff Filters"], "buffs_filters"', 1, true)
    local dedupInBand = filtersOpen and PAGE:find('band:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Duplicate Buffs"], db, "buffDeduplicateDefensives", DedupChanged), 30)', filtersOpen, true)
    local filtersClose = filtersOpen and PAGE:find("CloseSection(band)", filtersOpen, true)
    check(dedupInBand ~= nil and filtersClose ~= nil and dedupInBand < filtersClose,
          "dedup: Modern puts Hide Duplicate Buffs inside the Buff Filters section")
    check(PAGE:find("dedupCb.tooltip = DEDUP_TIP", 1, true) ~= nil,
          "dedup: ...carrying the tooltip it always had")
    check(PAGE:find("CreateControlRow(", 1, true) == nil and PAGE:find("dedupBand", 1, true) == nil,
          "dedup: ...and the lone control row is gone from the page")
    -- The hook and tooltip are declared BEFORE Buff Filters, which uses them first.
    local fnAt = PAGE:find("local function DedupChanged%(%)")
    check(fnAt ~= nil and filtersOpen ~= nil and fnAt < filtersOpen,
          "dedup: the callback is declared above the section that uses it")
    check(PAGE:find('GUI:CreateHeader(self.child, L["Deduplication"])', 1, true) ~= nil,
          "control row: classic still builds the box under its own header")
    check(PAGE:find('GUI:CreateCheckbox(self.child, L["Hide Duplicate Buffs"], db, "buffDeduplicateDefensives", DedupChanged)', 1, true) ~= nil,
          "control row: ...and the tick it always had")
    check(PAGE:find("Add(dedupGroup, nil, 1)", 1, true) ~= nil,
          "control row: ...in column 1, where it has always been")
    -- ONE callback and ONE tooltip, shared by both layouts, so they cannot drift.
    local dedupFns = 0
    for _ in PAGE:gmatch("local function DedupChanged%(%)") do dedupFns = dedupFns + 1 end
    eq(dedupFns, 1, "control row: the callback is declared once and used by both layouts")
    local dedupTips = 0
    for _ in PAGE:gmatch("local DEDUP_TIP = L%[") do dedupTips = dedupTips + 1 end
    eq(dedupTips, 1, "control row: ...and so is the tooltip")

    -- ---- the two sections that can hide entirely ---------------------
    check(PAGE:find("durBarGroup.hideOn = HideDurationBar", 1, true) ~= nil
      and PAGE:find("pandemicGroup.hideOn = HideDurationBar", 1, true) ~= nil,
          "hidden sections: classic still puts the factory gate on the boxes")
    -- ...and OpenSection puts the same predicate on the header AND its band, so
    -- neither half is left standing when the other goes.
    local open = OPEN
    check(open:find("section.hideOn = hideFn", 1, true) ~= nil
      and open:find("band.hideOn = hideFn", 1, true) ~= nil,
          "hidden sections: ...and a section hides its header and its band together")

    -- ---- twelve bare 280 boxes left, all inside a classicLayout arm ---
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 12, "boxes: twelve bare 280 boxes left, and they are the classic branch's own")
    check(PAGE:find("280, tools", 1, true) == nil,
          "boxes: no stay-inline 280 box is left on the page")
    check(PAGE:find("bandStyle", 1, true) == nil,
          "boxes: the band skin is never restated as a literal (this page needs none)")

    -- ---- the two-column split, and the order inside each column ------
    -- Content and the factory pair left, Icon and Text right -- the same split
    -- the four bands had. Within a column the Add order IS the layout order, so
    -- the sections are asserted in sequence rather than merely present.
    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "),
       "Visibility | Buff Filters | Order & Limits | Appearance | Layout | Position | Border | Duration Text | Stack Count | Duration Bar | Pandemic",
       "order: the eleven sections are opened in the order the page reads in one column")

    -- ☠ AND BOTH HALVES FILL THEIR COLUMN. The layout pass only resizes an
    -- indented widget otherwise, so a header or a band placed in a column without
    -- this keeps the width it was built at -- and on a narrow window, where the
    -- page folds back to ONE column, a half-width header would sit over a
    -- full-width band.
    check(open:find("section.layoutColFill = true", 1, true) ~= nil
      and open:find("band.layoutColFill = true", 1, true) ~= nil,
          "order: a section's header and its band both fill their column")

    -- ---- the page's own furniture is untouched -------------------------
    check(PAGE:find('Add(adBanner, 32, "both")', 1, true) ~= nil
      and PAGE:find('Add(adPromoBanner, 32, "both")', 1, true) ~= nil,
          "page: both Aura Designer banners survive, above everything")
    check(PAGE:find('{pageId = "auras_filterdesigner", label = L["Filter Designer"]}', 1, true) ~= nil,
          "page: ...and the See Also block is unchanged")
    check(PAGE:find('CreateCopyButton(self.child, {"buff", "showBuffs", "directBuff", "buffFilterSelection"}', 1, true) ~= nil,
          "page: ...and the copy button keeps the four prefixes it owns")
end

-- ============================================================
-- 8. THE TWO SHARED-HELPER CHANGES THE POPOUT SWEEP NEEDED
-- Both live in GUI/Controls.lua, both are opt-in. The Buff Bar page no longer
-- ASKS for the first of them -- a section has no tick to hoist -- but the Debuff
-- Bar page still does, and the builder still carries the branch, so the helper's
-- contract is pinned here as it always was.
-- ============================================================
print("-- Buff Bar page: the shared helpers it needed")
do
    -- (a) CreatePandemicControls gains noEnableToggle -- CreateBorderControls'
    -- noShowToggle, for the section that owns THIS toggle.
    check(CTRL:find("if not opts.noEnableToggle then", 1, true) ~= nil,
          "helpers: CreatePandemicControls can be told not to build its own Enable tick")
    local pandemicBody = CTRL:match("function GUI:CreatePandemicControls%(group, dbTable, opts%)(.-)\nend\n")
    check(pandemicBody ~= nil, "helpers: ...the function is locatable")
    if pandemicBody then
        check(pandemicBody:find("w.enable.keepEnabled = true", 1, true) ~= nil,
              "helpers: ...the classic path still builds the tick exactly as it did")
        -- ☠ THE KEY IS STILL READ. The group gate folds Enabled in whether or not
        -- the checkbox exists, so a pane greys behind a hoisted tick.
        check(pandemicBody:find("return not supported or gated(db) or not enabled()", 1, true) ~= nil,
              "helpers: ...and the group gate still reads the Enabled key")
    end

    -- (b) The duration-format example joins the group-wide VALUE sweep. A
    -- dropdown's own refreshValue repaints the caption and knows nothing about
    -- the fontstring this helper bolted onto it, so a Reset Group left the
    -- example describing a format the user no longer had.
    check(CTRL:find("local ddRefreshValue = dd.refreshValue", 1, true) ~= nil,
          "helpers: the duration-format example repaints on a group-wide value sweep")
    check(CTRL:find("if ddRefreshValue then ddRefreshValue() end", 1, true) ~= nil,
          "helpers: ...chained rather than replaced, so the caption still repaints too")
end

-- ============================================================
-- 8. THE PIN -- one small icon, on the eight sections that decide how it LOOKS
--
-- ☠ WHAT SURVIVED, AND WHY ONLY THIS. Popouts are no longer how settings are
-- REVEALED on this page -- section 1 is the fold that replaced them. The one job
-- pinning kept is COMPARISON: holding a section's settings open in a window of
-- their own so two pages can be read, or matched, side by side. So the header
-- gains an icon and nothing else -- no gear, no chevron, no count, all of which
-- were second ways IN, and the header already is the way in.
--
-- ☠ EIGHT SECTIONS, NOT ELEVEN, AND THE SPLIT IS THE POINT. A pin is only worth
-- having where there is something to MATCH against another page: Appearance,
-- Layout, Position, Border, Duration Text, Stack Count, Duration Bar, Pandemic.
-- Visibility, Buff Filters and Order & Limits decide what SHOWS rather than how
-- it looks, and the Hide Duplicate Buffs control row is one checkbox. Those four
-- must stay bare, so the negative half of this is asserted as hard as the
-- positive half -- a pin that creeps onto Buff Filters is the drift this catches.
--
--   ✓ which sections pass a builder and therefore get a pin, and which cannot
--   ✓ that the panel is built by the section's OWN builder, not a second list
--   ✓ that the title is page-qualified out of the page's own tab label
--   ✓ the kit's opt-in guard -- a section passing nothing builds nothing
--   ✓ that the icon is a real button with the shared tooltip, above the fold's
--     own click area, and that it yields nothing to the summary corner
--   ✗ nothing about runtime: that a press opens a panel, that the panel lands
--     beside the window and that two of them can stand at once are read by eye.
-- ============================================================
print("-- Buff Bar page: the pin")

-- The eight that decide how the bar LOOKS...
local PINNED = {
    { label = "Appearance",   builder = "BuildBuffAppearanceGroup" },
    { label = "Layout",       builder = "BuildBuffLayoutGroup" },
    { label = "Position",     builder = "BuildBuffPositionGroup" },
    { label = "Border",       builder = "BuildBuffBorderGroup" },
    { label = "Duration Text",builder = "BuildBuffDurationGroup" },
    { label = "Stack Count",  builder = "BuildBuffStackGroup" },
    { label = "Duration Bar", builder = "BuildBuffDurationBarGroup" },
    { label = "Pandemic",     builder = "BuildBuffPandemicGroup" },
}
-- ...and the three that decide what SHOWS. (The fourth abstainer, Hide Duplicate
-- Buffs, is a control row and never had an OpenSection call to put a pin on.)
local UNPINNED = { "Visibility", "Buff Filters", "Order & Limits" }

do
    -- ---- (a) who has one, and who must not ----------------------------
    for _, g in ipairs(PINNED) do
        local block = sectionBlock(g.label)
        -- ☠ THE SECTION'S OWN BUILDER IS WHAT THE PANEL IS BUILT FROM. The
        -- builder is the LAST argument to OpenSection and it is the opt-in: a
        -- panel showing a curated subset of its section is the exact defect the
        -- fold exists to remove, so the page may not name a second list of
        -- controls anywhere. One builder, mounted twice.
        -- (A ticked section passes its header tick after the builder.)
        check(block:find(g.builder .. ")", 1, true) ~= nil or block:find(g.builder .. ", {", 1, true) ~= nil,
              g.label .. ": the pin is opted in with the section's OWN builder")
        -- ...and it is still the same builder the band and the classic box use,
        -- so "mounted twice" became "mounted three times" and no more.
        local calls = 0
        for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
        eq(calls, 3, g.label .. ": ...still declared once and CALLED three times -- classic box, band, panel")
    end
    for _, label in ipairs(UNPINNED) do
        local block = sectionBlock(label)
        -- The call ends at the last predicate it was given; nothing follows it.
        check(block:find("Group)", 1, true) == nil,
              label .. ": decides what SHOWS, so it is handed no builder and grows no pin")
    end

    -- ---- (b) exactly one mount, in one named place --------------------
    -- Pinned to a COUNT, which is what section 5 stopped doing when it let
    -- PopoutContent back onto the page. Two would mean a section had grown a
    -- private mount of its own outside OpenSection.
    -- (The one place is the shared OpenSection now, so the page itself mounts
    -- none -- and the shared body mounts exactly one.)
    local mounts = 0
    for _ in PAGE:gmatch("tools%.PopoutContent%(") do mounts = mounts + 1 end
    eq(mounts, 0, "pin: the page mounts no panel content of its own -- OpenSection does")
    local open = OPEN
    eq(select(2, open:gsub("PopoutContent%(", "")), 1,
       "pin: ...and the shared OpenSection mounts it in exactly ONE place")
    check(open:find("local mount = PopoutContent(function(group, holder, reflow)", 1, true) ~= nil,
          "pin: ...and that mount is the pin's")
    -- ☠ THE SAME TABLE THE BAND GETS. `popout = true` is the only field that
    -- differs and it picks no controls -- DurationFormatRefresh reads it to
    -- re-flow the PANE rather than re-lay the page out (section 3).
    check(open:find("builder({ group = group, parent = holder, refreshStates = reflow, popout = true })", 1, true) ~= nil,
          "pin: ...handed the section's builder with the band's own table")

    -- ---- (c) the title names its PAGE ---------------------------------
    -- ☠ TWO PINNED PANELS BOTH READING "Appearance" ARE UNUSABLE, and comparing
    -- exactly those two -- this page's and the Debuff Bar's -- is what the pin is
    -- FOR. Out of the page's own tab label, never a string per section: a second
    -- copy of the page's name goes stale the day the tab is renamed.
    check(open:find('title = string.format("%s / %s", page.tabLabel or "", label)', 1, true) ~= nil,
          "pin: the panel's title is the PAGE's own name and the section's")
    check(PAGE:find('"Buff Bar /', 1, true) == nil,
          "pin: ...and no section hardcodes the page's name")
    check(open:find("window = DF.GUIFrame", 1, true) ~= nil,
          "pin: ...the panel docks outside the settings window")
    check(open:find("clipTo = page", 1, true) ~= nil,
          "pin: ...and the page's scroll frame is what clips its connected chrome")

    -- ---- (d) the eager build registers nothing with search -------------
    -- ☠ PopoutContent BUILDS ITS FIRST INSTANCE AT PAGE-BUILD TIME and every
    -- db-bound factory registers what it is handed, so without this the registry
    -- would carry TWO entries for every setting in a pinnable section -- one from
    -- the band, one from the panel's copy: two identical result cards under one
    -- label, one key and one section. The same guard a hoisted control's build
    -- takes (Controls.lua), and the reason section 5's search claim still holds.
    check(open:find("if Search then Search.SuppressRegistration = true end", 1, true) ~= nil,
          "pin: the panel's eager copy is suppressed from the settings registry")
    check(open:find("if Search then Search.SuppressRegistration = held end", 1, true) ~= nil,
          "pin: ...and the previous value is handed back, never hardcoded to nil")
    local SEARCH = options_file_source("Features/Search.lua"):gsub("\r\n", "\n")
    check(SEARCH:find("if self.SuppressRegistration then", 1, true) ~= nil,
          "pin: ...against a flag Search:Register still honours")

    -- ---- (e) the kit's opt-in guard ------------------------------------
    -- ⚠ A SECTION THAT PASSES NOTHING BUILDS NOTHING -- exactly how `summary`
    -- and `dimOn` behave, so no existing section on any other page moves.
    check(WIDGETS:find('local pinOpts = opts and type(opts.pin) == "table" and opts.pin or nil', 1, true) ~= nil,
          "pin kit: the section reads opts.pin defensively")
    check(WIDGETS:find('if pinOpts and type(pinOpts.build) == "function" then', 1, true) ~= nil,
          "pin kit: ...and builds nothing at all without a mount to open")
    check(WIDGETS:find("if pinRightInset then section:SetHeaderRightInset(pinRightInset) end", 1, true) ~= nil,
          "pin kit: ...a pinned header tells the title and tag what it took; a bare one is unbounded as before")

    -- ---- (f) the icon itself -------------------------------------------
    -- ☠ A REAL BUTTON WITH A REAL TOOLTIP. CreateGlyphButton wires
    -- host:ShowTooltip / HideTooltip for us, which is the pack's only tooltip
    -- route -- a bare texture with a click handler bolted on would have neither.
    check(WIDGETS:find("local pinBtn = GUI:CreateGlyphButton(section, {", 1, true) ~= nil,
          "pin kit: the pin is built from the kit's glyph button, not hand-rolled")
    check(WIDGETS:find('tooltip = { title = L["Pin settings in popout"] },', 1, true) ~= nil,
          "pin kit: ...with a localised tooltip through the shared helper")
    -- ...rather than the raw frame. Matched on the CALLS, not on the word: the
    -- rule itself is written down in a comment a few lines above the pin.
    check(WIDGETS:find("GameTooltip:SetOwner", 1, true) == nil
          and WIDGETS:find("GameTooltip:Show", 1, true) == nil,
          "pin kit: ...and this file drives no raw GameTooltip")
    -- ☠ ABOVE THE FOLD'S OWN CLICK AREA. clickArea is SetAllPoints over the whole
    -- header; a sibling at the same frame level takes none of the presses that
    -- land on it, so the pin would FOLD the section instead of pinning it.
    check(WIDGETS:find("pinBtn:SetFrameLevel(clickArea:GetFrameLevel() + 2)", 1, true) ~= nil,
          "pin kit: ...and sits above the click area that folds the section")
    check(WIDGETS:find('pinBtn:SetPoint("RIGHT", section, "RIGHT", -PIN_EDGE, 0)', 1, true) ~= nil,
          "pin kit: the icon owns the header's far right")
    -- ...and the summary steps inboard of it. The summary corner is section 6's,
    -- and it must not be drawn under the icon.
    check(WIDGETS:find('section.summary:SetPoint("RIGHT", section.pinBtn, "LEFT", -6, 0)', 1, true) ~= nil,
          "pin kit: ...and the value summary stops short of it")
    check(WIDGETS:find('section.summary:SetPoint("RIGHT", section, "RIGHT", -10, 0)', 1, true) ~= nil,
          "pin kit: ...while a section with no pin keeps the edge it always had")

    -- ---- (g) the panel machinery is REUSED, not re-written --------------
    -- ☠ NO SECOND PANEL IMPLEMENTATION. The row behind the pin is the kit's own
    -- PopoutRow, so the panel it opens is created, tethered, pinned, closed and
    -- SWEPT by the code every other page's rows already use -- including the
    -- mode switch's CloseAllPopoutRows, which walks the host's panel store and
    -- therefore finds these without being told about them.
    check(WIDGETS:find("row = GUI:CreatePopoutRow(section, {", 1, true) ~= nil,
          "pin kit: the panel is the kit's PopoutRow, not a second implementation")
    check(WIDGETS:find("GUI:CreatePopout(", 1, true) == nil,
          "pin kit: ...and the section never reaches past it to the raw popout shell")
    check(WIDGETS:find("build   = pinOpts.build,", 1, true) ~= nil,
          "pin kit: ...opening the mount the page handed it")
    -- ☠ IT OPENS ALREADY PINNED. An unpinned panel lives in the host's shared
    -- pool, ONE per key, so a second section's press would RE-TARGET the first's
    -- panel rather than stand beside it -- and two panels standing at once is the
    -- entire feature. Popout:Pin takes the instance out of that pool.
    check(WIDGETS:find("if po and not po.closed and not po.pinned then po:Pin(true) end", 1, true) ~= nil,
          "pin kit: a press pins the panel out of the shared pool, so two can stand at once")
    check(WIDGETS:find("r:TogglePopout()", 1, true) ~= nil,
          "pin kit: ...and a second press on a lit pin takes that panel down again")
    check(WIDGETS:find("onClose = function() section:SetPinLit(false) end,", 1, true) ~= nil,
          "pin kit: any close -- the cross, a mode switch's sweep -- returns the header to plain")

    -- ---- (h) the tether, which is the header and not the row -------------
    -- ☠ THE ROW IS A CONTROLLER WITH NOTHING ON THE PAGE. It is never laid out
    -- and never shown, so its own rect is the origin: left to tether to itself
    -- the panel would dock in the corner of the screen with its beam pointing at
    -- nothing. opts.tetherTo is the kit's answer, and BOTH readers take it --
    -- Popout's contract is that the dock, the beam and the clip gate describe ONE
    -- rect.
    check(WIDGETS:find("tetherTo = section,", 1, true) ~= nil,
          "pin kit: the panel leaves the HEADER the user pressed")
    -- ...and the row itself never draws. Asserted on the wiring UNIQUE to the
    -- pin rather than on a bare `row:Hide()`, which this file already contains
    -- in a dropdown menu loop and which therefore proves nothing.
    check(WIDGETS:find("row:SetOnPanelPinned(function() section:SetPinLit(true) end)", 1, true) ~= nil,
          "pin kit: ...and the header lights the moment its panel is pinned")
    check(WIDGETS:find('row:SetPoint("TOPLEFT", section, "TOPLEFT", 0, 0)', 1, true) ~= nil,
          "pin kit: ...while the controller row is parked on the header and hidden")
    local ROW = ui_file_source("PopoutRow.lua"):gsub("\r\n", "\n")
    check(ROW:find("row._tetherTo = opts.tetherTo", 1, true) ~= nil,
          "kit: CreatePopoutRow takes an explicit tether region")
    check(ROW:find("return t or (stripLive and strip) or row", 1, true) ~= nil,
          "kit: ...falling back to the strip-or-row every existing page already gets")
    check(ROW:find("tetherSource = tetherRegion(),", 1, true) ~= nil,
          "kit: ...the beam and the source outline take it")
    check(ROW:find("po:Follow(tetherRegion(), { outsideOf = row._window, clipTo = row._clipTo })", 1, true) ~= nil,
          "kit: ...and so does the dock, so all three describe one rect")
end

-- ============================================================
-- 9. EXPAND ALL / COLLAPSE ALL -- the two verbs a page of folds needs
--
-- ☠ WHAT WAS MISSING. Eleven folds, and the only way to shut them was eleven
-- presses -- with no way back at all. Fold the page by hand and it is a wall of
-- headers you must now re-open one at a time; the missing Expand All is what the
-- design critique named.
--
-- ☠ THE STORE IS ADDON-WIDE AND THE VERBS ARE NOT. Every fold in the addon --
-- the Text Designer's cards, the Aura Designer's rows, every other page's
-- sections -- persists into the ONE table GetCollapsedGroups hands back. A bulk
-- verb that walked THAT would silently unfold half the addon, so these walk a
-- roster the page registered instead: a key this page never created is a key it
-- cannot reach. That negative is asserted here as hard as the positive.
--
-- ☠ AND IT RELAYOUTS RATHER THAN REBUILDS. A rebuild retires the whole page into
-- the trash frame and builds a second copy (Panel.lua's ONE RETAINED BUILD PER
-- MODE) for a change that moves no widget and creates none. So the sections move
-- through SetExpanded -- the fold WITHOUT the repaint -- and the page's own state
-- pass runs once, at the end.
--
--   ✓ the pair exists, at the top of the page, spanning both columns
--   ✓ the helper is GENERIC -- page tools, not page markup -- and every section
--     on the page is registered with it
--   ✓ the store is written through the section's own persist path
--   ✓ the disabled rule, both ends of it
--   ✗ nothing about runtime: that a press actually folds eleven sections, and
--     that the pair greys at the ends, are read by eye.
-- ============================================================
print("-- Buff Bar page: Expand All / Collapse All")
do
    local CTRL_RAW = options_file_source("GUI/Controls.lua"):gsub("\r\n", "\n")

    -- ---- (a) the page mounts the pair, once, above everything ----------
    check(PAGE:find('Add(tools.SectionControls(self.child), 24, "both")', 1, true) ~= nil,
          "bulk: the page adds the pair at the top, spanning both columns")
    -- ☠ col "both" RATHER THAN A COLUMN. The pair governs sections in BOTH
    -- columns, so put in column 1 it would read as part of Content -- and "both"
    -- is what carries it through the one-column fold intact. It is also a sync
    -- point, which costs nothing at the top of a page where both columns are at
    -- zero.
    local stripAt = PAGE:find("tools.SectionControls", 1, true)
    local contentAt = PAGE:find('Add(GUI:CreateHeader(self.child, L["Content"]), 40, 1)', 1, true)
    check(stripAt ~= nil and contentAt ~= nil and stripAt < contentAt,
          "bulk: ...above the first category header, because it acts on the whole page")
    local mounts = 0
    for _ in PAGE:gmatch("tools%.SectionControls%(") do mounts = mounts + 1 end
    eq(mounts, 1, "bulk: ...and exactly once")

    -- ---- (b) every section on the page is on the roster -----------------
    -- In OpenSection, so no section can be left off by hand -- there is one
    -- registration site for all eleven rather than eleven chances to forget one.
    -- (The shared OpenSection in the page tools, since the lift.)
    local open = OPEN
    check(open:find("RegisterSection(section)", 1, true) ~= nil,
          "bulk: OpenSection puts every section it builds on the page's roster")
    eq(select(2, open:gsub("RegisterSection%(section%)", "")), 1,
       "bulk: ...from the one place that builds them, not once per call site")
    local regs = 0
    for _ in PAGE:gmatch("tools%.RegisterSection%(") do regs = regs + 1 end
    eq(regs, 0, "bulk: ...and nowhere else")

    -- ---- (c) the helper is GENERIC ---------------------------------------
    -- ⚠ THE NEXT PAGE CONVERTED PASSES ONE THING, not a copy of this markup.
    -- Both verbs live in the shared page tools and neither knows what a buff is.
    check(CTRL_RAW:find("RegisterSection       = RegisterSection,", 1, true) ~= nil,
          "bulk helper: the roster verb is on the shared page tools")
    check(CTRL_RAW:find("SectionControls       = SectionControls,", 1, true) ~= nil,
          "bulk helper: ...and so is the strip")
    local scBody = CTRL_RAW:match("local function SectionControls%(parent%)(.-)\n    end\n")
    check(scBody ~= nil, "bulk helper: ...the strip builder is locatable")
    if scBody then
        for _, word in ipairs({ "buff", "Buff", "debuff", "Debuff" }) do
            check(scBody:find(word, 1, true) == nil,
                  "bulk helper: ...and says nothing about " .. word .. " -- it is page-agnostic")
        end
        -- ☠ THE PAGE'S OWN SECTIONS AND NOBODY ELSE'S. If this ever reads the
        -- store directly it stops being scoped to the page, and Expand All starts
        -- unfolding the Text Designer.
        check(scBody:find("GetCollapsedGroups", 1, true) == nil,
              "bulk helper: the strip never reads the addon-wide collapse store")
        check(scBody:find("eachVisibleSection", 1, true) ~= nil,
              "bulk helper: ...it walks the page's registered sections instead")
        -- ...and a REBUILD would retire the whole page into the trash frame for a
        -- change that creates no widget. Relayout only.
        check(scBody:find("page:RefreshStates()", 1, true) ~= nil,
              "bulk: a press relayouts through the page's own state pass")
        for _, verb in ipairs({ "BuildPage", "DoBuild", "GUI:RefreshCurrentPage", "page:Refresh()" }) do
            check(scBody:find(verb, 1, true) == nil,
                  "bulk: ...and never " .. verb .. ", which would rebuild the page")
        end
        -- ⚠ AND ONLY WHEN SOMETHING MOVED. The buttons grey when they would do
        -- nothing, so this is belt and braces -- but a state pass over a page of
        -- folds is not free.
        check(scBody:find("if moved and page.RefreshStates then", 1, true) ~= nil,
              "bulk: ...and only when a section actually moved")
    end
    -- ⚠ HIDDEN SECTIONS DO NOT COUNT. The Buff Bar's two 12.1-factory extras are
    -- off the page on a client that draws neither; counting them would leave
    -- Expand All lit with every visible section already open.
    check(CTRL_RAW:find("if s and s:IsShown() and s.SetExpanded then", 1, true) ~= nil,
          "bulk: only sections the user can actually see are counted or moved")

    -- ---- (d) the disabled rule, both ends --------------------------------
    -- ☠ GREY, NOT HIDDEN -- the pack's standard gating model. A control that
    -- vanishes and returns as the user folds things is worse than one that dims.
    check(CTRL_RAW:find("expandBtn:SetDisabled(n == 0 or shut == 0)", 1, true) ~= nil,
          "bulk: Expand All greys when every visible section is already open")
    check(CTRL_RAW:find("collapseBtn:SetDisabled(n == 0 or open == 0)", 1, true) ~= nil,
          "bulk: Collapse All greys when every visible section is already shut")
    -- Driven from the page's state pass -- the pass that has just decided which
    -- sections are shown -- so the verdict is never a frame stale.
    check(CTRL_RAW:find("strip.refreshContent = function()", 1, true) ~= nil,
          "bulk: ...re-judged on every page state pass, like every other gated control")

    -- ---- (e) the store, written the way a manual fold writes it ----------
    -- ☠ ONE PERSIST PATH, SHARED WITH THE HEADER. SetExpanded is Toggle's first
    -- half split out: the arrow and the SavedVariables slot, and nothing else. So
    -- a bulk fold and a click on a header leave the store in exactly the same
    -- state, and both survive a reload the same way.
    local setExp = WIDGETS:match("section%.SetExpanded = function%(self, want%)(.-)\n    end\n")
    check(setExp ~= nil, "bulk store: the section exposes a repaint-free fold")
    if setExp then
        check(setExp:find("local persistKey = self.collapseKey or self.sectionTitleText", 1, true) ~= nil,
              "bulk store: ...keyed on the section's own stable collapse key")
        check(setExp:find("saved[persistKey] = (not self.expanded) or nil", 1, true) ~= nil,
              "bulk store: ...writing the same slot a manual fold writes")
        check(setExp:find("if self.expanded == want then return false end", 1, true) ~= nil,
              "bulk store: ...and reports whether it actually moved, so a no-op costs no pass")
        check(setExp:find("RefreshStates", 1, true) == nil,
              "bulk store: ...with no page pass of its own -- that is the caller's, once")
    end
    -- ...and Toggle is now the pair of halves rather than a second copy of one.
    check(WIDGETS:find("section.Toggle = function(self)\r\n        self:SetExpanded(not self.expanded)", 1, true) ~= nil
          or WIDGETS:find("section.Toggle = function(self)\n        self:SetExpanded(not self.expanded)", 1, true) ~= nil,
          "bulk store: a header click goes through the very same fold")

    -- ---- (e2) the glyphs ---------------------------------------------------
    -- The corner-bracket pair, generated by Tools/generate_expand_collapse_icons.py.
    for _, icon in ipairs({ "expand_content", "collapse_content" }) do
        check(CTRL_RAW:find(icon, 1, true) ~= nil,
              "bulk glyphs: the pair carries its icon (" .. icon .. ")")
    end

    -- ---- (f) the strings ---------------------------------------------------
    local ENUS = df_file_source("Locales/enUS.lua"):gsub("\r\n", "\n")
    for _, key in ipairs({ "Expand All", "Collapse All" }) do
        check(CTRL_RAW:find('L["' .. key .. '"]', 1, true) ~= nil,
              "bulk strings: the button text is localised (" .. key .. ")")
        check(ENUS:find('L["' .. key .. '"] = true', 1, true) ~= nil,
              "bulk strings: ...and the key is declared in enUS (" .. key .. ")")
    end
end

-- ============================================================
-- 11. ONE CARD PER SECTION (opts.card)
-- The approved design draws each section as ONE card -- header and band in a
-- single rounded plate, a hairline between them, an 8px gap to the next card.
-- The band stays a separate page child (the state pass has to reach it), so the
-- card is a kit rounded surface whose textures live on the header and whose
-- rect is anchored header-top -> band-bottom. OPT-IN: this page is the only
-- caller, and every other section must build exactly what it built before.
--
-- ✗ Source-shape only, like the rest of this file: nothing here builds a
-- frame, so how the card LOOKS is unverified until it is read in game.
-- ============================================================
print("-- Buff Bar page: one card per section")
do
    -- The body of CreateCollapsibleSection, and nothing past it.
    local fn = WIDGETS:match("function GUI:CreateCollapsibleSection%(.-\nend\n") or ""
    check(fn ~= "", "card: the section factory is readable")

    -- ---- the opt-in guard -------------------------------------------
    check(fn:find("local CARD = opts and opts.card and GUI.SectionCard or nil", 1, true) ~= nil,
          "card: the look is read off opts.card and nothing else")
    -- ☠ A CALLER WITHOUT IT BUILDS THE BAR IT ALWAYS HAD: the old backdrop is
    -- the non-card arm, and every piece of card chrome sits in the other one.
    local plain, cardArm = fn:match("\n    if not CARD then\n(.-)\n    else\n(.-)\n    end\n")
    check(plain ~= nil and plain:find("GUI:CreateElementBackdrop(section, {", 1, true) ~= nil,
          "card: without the opt-in the header keeps its old element backdrop")
    check(cardArm ~= nil and select(2, cardArm:gsub("GUI:CreateRoundedSurface%(section,", "")) == 2,
          "card: ...and both rounded surfaces are built only in the card arm")
    check(select(2, fn:gsub("GUI:CreateRoundedSurface%(", "")) == 2,
          "card: ...and nowhere else in the factory")
    check(cardArm ~= nil and cardArm:find('cardLine = section:CreateTexture(nil, "BORDER")', 1, true) ~= nil,
          "card: the hairline texture is card-only too")
    -- The fold hook exists only for a card, and every later reach for it is
    -- guarded on its presence -- so a plain section's fold, registration and
    -- hover run exactly the old code.
    check(fn:find("\n    if CARD then\n        section.fixedRowHeight = true\n        section._ApplyCardFold = function(self)", 1, true) ~= nil,
          "card: the fold hook is defined only under the opt-in")
    check(fn:find("if self._ApplyCardFold then self:_ApplyCardFold() end", 1, true) ~= nil,
          "card: ...SetExpanded reaches it only when it exists")
    check(fn:find("if self._ApplyCardFold and widget.isSettingsGroup and not self.cardBody then", 1, true) ~= nil,
          "card: ...and so does RegisterChild")
    check(fn:find("if cardHover then cardHover:Show() return end", 1, true) ~= nil
      and fn:find("if cardHover then cardHover:Hide() return end", 1, true) ~= nil,
          "card: the hover wash replaces the backdrop tint only when there is a card")
    check(fn:find('section.arrow:SetPoint("LEFT", CARD and CARD.edge or 8, 0)', 1, true) ~= nil
      and fn:find("local TICK_X = CARD and (CARD.edge + CARD.chevron + CARD.titleGap) or 26", 1, true) ~= nil
      and fn:find("local TITLE_X = TICK_X\n", 1, true) ~= nil,
          "card: a plain section keeps its 8px arrow and 26px title")

    -- ---- Buff Bar passes it -----------------------------------------
    local open = OPEN
    check(open:find("pin = pin, card = true, toggle = toggle })", 1, true) ~= nil,
          "card: Buff Bar's OpenSection opts every section in")

    -- ---- the 40px header --------------------------------------------
    check(WIDGETS:find("header      = 40,", 1, true) ~= nil,
          "card: the header row is 40 tall")
    check(fn:find("if CARD then section:SetHeight(CARD.header) end", 1, true) ~= nil,
          "card: ...the header frame is built at that height")
    check(fn:find("local slot = open and CARD.header or (CARD.header + CARD.gap)", 1, true) ~= nil,
          "card: ...open, its slot is exactly the header so the body starts under the seam; shut, it carries the gap")
    check(fn:find("widget.margin = CARD.gap", 1, true) ~= nil
      and fn:find("widget.padding = CARD.pad", 1, true) ~= nil,
          "card: the body takes the card's inset and the gap to the next card")

    -- ---- the title is TEXT, the accent is the chevron ----------------
    local ut = fn:match("\n    if CARD then\n        section%.title%.UpdateTheme = function%(%)(.-)\n        end\n")
    check(ut ~= nil, "card: the card repaints its title through its own UpdateTheme")
    if ut then
        check(ut:find("section.title:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)", 1, true) ~= nil,
              "card: ...the title is the text colour")
        check(ut:find("section.title:SetTextColor(nc.r", 1, true) == nil,
              "card: ...never the accent")
        check(ut:find("section.arrow:SetVertexColor(nc.r, nc.g, nc.b)", 1, true) ~= nil,
              "card: ...the chevron carries the accent")
        check(ut:find("section.title:SetTextColor(0.5, 0.5, 0.5)", 1, true) ~= nil
          and ut:find("section.arrow:SetVertexColor(0.5, 0.5, 0.5)", 1, true) ~= nil,
              "card: ...and dimmed greys both at SetPreviewDimmed's grey")
    end

    -- ---- the hairline -----------------------------------------------
    check(fn:find("cardLine:SetHeight(1)", 1, true) ~= nil,
          "card: the header/body seam is a 1-unit hairline")
    check(fn:find("cardLine:SetShown(open)", 1, true) ~= nil,
          "card: ...shown only while the body is showing")
    local bA = tonumber(WIDGETS:match("borderAlpha = ([%d%.]+)"))
    local lA = tonumber(WIDGETS:match("lineAlpha   = ([%d%.]+)"))
    check(bA ~= nil and lA ~= nil and lA < bA,
          "card: ...a shade under the card's border")

    -- ---- the dim summary stays readable on a card --------------------
    check(fn:find("if self.previewDimmed and not self.isCard then", 1, true) ~= nil,
          "card: the summary keeps its readable dim on a card (0.5 grey fails 4.5:1)")

    -- ---- nobody else opts in ----------------------------------------
    -- Every file that calls CreateCollapsibleSection today. A NEW caller in a
    -- file not listed here is not covered -- the harness cannot list a folder.
    local callers = {
        "GUI/Pages/Indicators.lua", "GUI/Pages/Modules.lua", "GUI/Pages/Auras.lua",
        "GUI/DesignerShell.lua", "AuraDesigner/UI/Rows.lua", "TextDesigner/UI/Rows.lua",
        "GUI/Controls.lua",
    }
    local calls, carded, cardedIn = 0, 0, nil
    for _, path in ipairs(callers) do
        local src = options_file_source(path):gsub("\r\n", "\n")
        local pos = 1
        while true do
            local s, e = src:find("GUI:CreateCollapsibleSection(", pos, true)
            if not s then break end
            -- The whole call, by balancing parentheses from its opening one.
            local depth, i = 1, e + 1
            while depth > 0 and i <= #src do
                local ch = src:sub(i, i)
                if ch == "(" then depth = depth + 1 elseif ch == ")" then depth = depth - 1 end
                i = i + 1
            end
            local call = src:sub(s, i - 1)
            calls = calls + 1
            if call:find("card%s*=") then
                carded = carded + 1
                cardedIn = path
            end
            pos = i
        end
    end
    check(calls >= 20, "card: every known caller was scanned (" .. calls .. " calls)")
    -- The one carded call is the shared OpenSection (the page tools), which
    -- only the two converted aura bars reach.
    check(carded == 1 and cardedIn == "GUI/Controls.lua",
          "card: ...and the shared OpenSection is the only one that opts in")
end

-- ============================================================
-- 12. THE HEADER TICK -- a section's on/off, moved into its header
-- Sections whose feature has an on/off carry that tick in the HEADER, so the
-- feature can be switched without opening the section. MOVED, not copied: the
-- in-body checkbox is not built in Modern (hoistToggle), so there is exactly
-- one live copy. Classic still builds it inside its box.
--
-- ✗ Source-shape only: nothing here builds a frame, so where the tick draws,
-- that it takes the click rather than folding, and how it greys are all read
-- in game.
-- ============================================================
print("-- Buff Bar page: the header tick")
do
    -- ---- exactly these four sections get one ----------------------------
    -- Stack Count has no on/off at all (the game draws the count whenever an
    -- aura has one), so there is nothing to put in its header.
    local TICKED = {
        { label = "Border",        key = "buffShowBorder",         name = "Show Border" },
        { label = "Duration Text", key = "buffShowDuration",       name = "Show Duration" },
        { label = "Duration Bar",  key = "buffDurationBarEnabled", name = "Enable Duration Bar" },
        { label = "Pandemic",      key = "buffPandemicEnabled",    name = "Enable" },
    }
    local UNTICKED = { "Visibility", "Buff Filters", "Order & Limits", "Appearance",
                       "Layout", "Position", "Stack Count" }
    for _, t in ipairs(TICKED) do
        local block = sectionBlock(t.label)
        check(block:find('db = db, key = "' .. t.key .. '", label = L["' .. t.name .. '"]', 1, true) ~= nil,
              "tick: " .. t.label .. " carries a header tick bound to " .. t.key .. " under its own name")
        check(block:find("onChanged = function()", 1, true) ~= nil,
              "tick: ...and hands it the in-body checkbox's commit")
        check(block:find("disableOn = ", 1, true) ~= nil,
              "tick: ...and the gate the in-body checkbox carried")
    end
    for _, label in ipairs(UNTICKED) do
        local block = sectionBlock(label)
        check(block:find("key = \"", 1, true) == nil and block:find("hoistToggle", 1, true) == nil,
              "tick: " .. label .. " has no header tick")
    end
    -- ☠ NOT VISIBILITY. Show Buffs is the page's master switch: it stays in the
    -- body, built by the builder, and no header anywhere binds it.
    check(sectionBlock("Visibility"):find("showBuffs", 1, true) == nil,
          "tick: Visibility's Show Buffs is not hoisted into its header")
    check(builderBody("BuildVisibilityGroup"):find('L["Show Buffs"], db, "showBuffs"', 1, true) ~= nil,
          "tick: ...its builder still builds Show Buffs in the body")
    local ticks = 0
    for _ in PAGE:gmatch("hoistToggle = true,") do ticks = ticks + 1 end
    eq(ticks, 4, "tick: exactly four mounts ask their builder to skip the in-body toggle")

    -- ---- no duplicate in Modern, and classic still builds it ------------
    -- The hoist reaches the checkbox in each of the four: two builders guard
    -- it themselves, the two composites pass it through to the helper, and
    -- the helpers skip on it.
    for _, b in ipairs({ "BuildBuffDurationGroup", "BuildBuffDurationBarGroup" }) do
        local body = builderBody(b)
        local guard = body:find("if not tools2.hoistToggle then", 1, true)
        local cb = body:find("GUI:CreateCheckbox(parent, L[", guard or 1, true)
        check(guard ~= nil and cb ~= nil and cb > guard,
              "tick: " .. b .. " builds its toggle only when not hoisted")
    end
    check(builderBody("BuildBuffBorderGroup"):find("noShowToggle  = tools2.hoistToggle or nil", 1, true) ~= nil,
          "tick: the border toolkit is told to skip Show Border when hoisted")
    check(WIDGETS:find("if not opts.noShowToggle then\n        w.show = group:AddWidget(GUI:CreateCheckbox(parent, L[\"Show Border\"]", 1, true) ~= nil,
          "tick: ...and the toolkit honours it")
    check(builderBody("BuildBuffPandemicGroup"):find("noEnableToggle = tools2.hoistToggle or nil", 1, true) ~= nil,
          "tick: the Pandemic helper is told to skip Enable when hoisted")
    check(CTRL:find("if not opts.noEnableToggle then\n        w.enable = group:AddWidget(GUI:CreateCheckbox(parent, L[\"Enable\"]", 1, true) ~= nil,
          "tick: ...and the helper honours it")
    -- Classic: none of the four classic mounts passes the hoist. Every
    -- `hoistToggle = true` on the page sits inside a section block (counted
    -- above: four, one per ticked section), so the classic boxes have none.
    local inBlocks = 0
    for _, t in ipairs(TICKED) do
        inBlocks = inBlocks + select(2, sectionBlock(t.label):gsub("hoistToggle = true,", ""))
    end
    eq(inBlocks, ticks, "tick: every hoist is a Modern section mount -- classic still builds the toggle in its box")

    -- ---- the factory: opt-in, above the click area, real checkbox -------
    local fn = WIDGETS:match("function GUI:CreateCollapsibleSection%(.-\nend\n") or ""
    check(fn:find('local toggleOpts = opts and type(opts.toggle) == "table" and type(opts.toggle.key) == "string"', 1, true) ~= nil,
          "tick: the factory reads opts.toggle, and a spec with no key is no spec")
    check(fn:find("if toggleOpts then TITLE_X = TICK_X + TICK_SIZE", 1, true) ~= nil,
          "tick: ...the title moves right only on a ticked header")
    local tickAt = fn:find("\n    if toggleOpts then\n        local tick = GUI:CreateCheckbox(section, toggleOpts.label, toggleOpts.db,", 1, true)
    check(tickAt ~= nil, "tick: ...built only under the opt-in, from the shared checkbox factory")
    check(fn:find("tick:SetFrameLevel(clickArea:GetFrameLevel() + 2)", 1, true) ~= nil,
          "tick: ...above the header's click area, so a press toggles and never folds")
    check(fn:find('tick:SetPoint("LEFT", section, "LEFT", TICK_X, 0)', 1, true) ~= nil,
          "tick: ...between the chevron and the title")
    local crumb = fn:find("DF.Search:SetCurrentSection(text)", 1, true)
    check(crumb ~= nil and tickAt ~= nil and crumb < tickAt,
          "tick: ...after the section's search breadcrumb, so its entry lands under this section")
    check(WIDGETS:find("container.searchEntry = DF.Search:RegisterCheckbox(label, dbKey, nil, false, callback)", 1, true) ~= nil,
          "tick: ...and the factory registers it under its own label and key")
    check(fn:find("box:HookScript(\"OnEnter\", function(self) GUI:ShowTooltip(self, spec) end)", 1, true) ~= nil,
          "tick: the tooltip goes through the shared helper")

    -- ---- off means greyed, never folded ----------------------------------
    local rc = fn:match("section%.refreshContent = function%(self, d%)(.-)\n        end\n") or ""
    check(rc:find('text = L["Off"]', 1, true) ~= nil,
          "tick: unticked and shut, the corner reads Off")
    check(rc:find("SetExpanded", 1, true) == nil and rc:find("Toggle(", 1, true) == nil,
          "tick: ...and nothing on the state pass folds the section")
    check(rc:find("tick:SetEnabled(enabled)", 1, true) ~= nil,
          "tick: the tick greys through its own gate on the state pass")

    -- ---- nobody else opts in ---------------------------------------------
    local callers = {
        "GUI/Pages/Indicators.lua", "GUI/Pages/Modules.lua", "GUI/Pages/Auras.lua",
        "GUI/DesignerShell.lua", "AuraDesigner/UI/Rows.lua", "TextDesigner/UI/Rows.lua",
        "GUI/Controls.lua",
    }
    local toggled = 0
    for _, path in ipairs(callers) do
        local src = options_file_source(path):gsub("\r\n", "\n")
        for call in src:gmatch("GUI:CreateCollapsibleSection%b()") do
            if call:find("toggle%s*=") then toggled = toggled + 1 end
        end
    end
    eq(toggled, 1, "tick: the shared OpenSection is the only caller that passes a toggle")
end
