local NS = ...

-- ============================================================
-- SORTING PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Auras.lua
-- ------------------------------------------------------------
-- General > Sorting: five 280 boxes in classic; in modern, the Debuff Bar's
-- collapsible CARDS in the two columns classic has always drawn:
--
--   column 1   Unit Frame Sorting (+ Self Position), FrameSort Integration
--              (only with the FrameSort addon; header tick)
--   column 2   "Priority"  Role Priority, Class Priority
--
-- ☠ WHAT THIS SUITE PINS:
--   * each builder's census (pre-card source) -- classic renders as it did;
--   * ONE builder per box, and the card hands it exactly what classic does
--     (plus hoistToggle where the tick moved into the header);
--   * Enable Custom Sorting stays in the first card's body -- it is the PAGE
--     gate -- and that card says Off while sorting is off;
--   * Use FrameSort Addon is the FrameSort card's header tick;
--   * Self Position, the page's lone control, is in Unit Frame Sorting;
--   * no pins: every card decides ORDER, which is behaviour;
--   * the priority cards' hide and grey gates, and the Priority header hiding
--     with them.
--   ✗ nothing about runtime behaviour -- read in game.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Auras.lua"):gsub("\r\n", "\n")

-- ---- the census reader (the Frame page's, verbatim) ------------------
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
}

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

-- The Sorting page, scoped by its own two ends.
local PAGE
do
    local a = SRC:find('Add(CreateCopyButton(self.child, {"sort", "useFrameSort"', 1, true)
    local b = SRC:find('{pageId = "general_labels", label = L["Group Labels"]}', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Sorting page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- ONE CARD'S BLOCK, flattened; `call` is just its OpenSection call.
local function sectionBlock(labelKey)
    local a = PAGE:find('OpenSection(L["' .. labelKey .. '"]', 1, true)
    check(a ~= nil, "source: a card is opened for " .. labelKey)
    if not a then return "", "" end
    local b = PAGE:find("CloseSection(band)", a, true)
    check(b ~= nil, "source: ..." .. labelKey .. "'s band is closed after its controls")
    local block = PAGE:sub(a, (b or a) + #"CloseSection(band)"):gsub("%s+", " ")
    local m = block:find("({ group = band,", 1, true)
    local call = m and block:sub(1, m) or block
    call = call:gsub("Build[%w]+%($", "")
    return block, call
end

-- ============================================================
-- 1. THE SHARED CARD HELPER, AND THE POPOUT FURNITURE GONE
-- ============================================================
print("-- Sorting page: the shared card helper")
do
    check(PAGE:find("local classicLayout = DF:IsClassicSettingsLayout()", 1, true) ~= nil,
          "tools: the page asks which layout it is building")
    check(PAGE:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true) ~= nil,
          "tools: ...and takes the shared machinery unconditionally")
    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "tools.PopoutContent(", "tools.ClaimKeys(",
                            "tools.WireModifiedTick(", "tools.WireFooter(",
                            "tools.RegisterHoistedToggle(", "tools.RegisterControlRow(",
                            "GUI:CreateControlRow(", "tools.INLINE_BOX", "sortBand", "priorityBand",
                            "selfPosBand", "_COUNT", "footerStrip", "inline = true", "popout = true,",
                            "OnSortEnabledToggle", "ApplySortOptions" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end
    check(PAGE:find("count%s*=%s*[%w_]") == nil, "counts: no card declares a settings count")

    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: every card goes through the shared helper, two per row with quiet captions")
    check(PAGE:find("local function CloseSection(band)\n            tools.CloseSection(Add, band)\n        end", 1, true) ~= nil,
          "sections: ...and closes through the shared helper too")

    local n = 0
    for _ in PAGE:gmatch('Add%(tools%.SectionControls%(self%.child%), 24, "both"%)') do n = n + 1 end
    eq(n, 1, "bulk: the page adds the Expand/Collapse pair once, spanning both columns")
    local bannerAt = PAGE:find('Add(combatBanner, combatBanner.layoutHeight, "both")', 1, true)
    local stripAt = PAGE:find("tools.SectionControls", 1, true)
    local firstCard = PAGE:find("OpenSection(L[", 1, true)
    check(bannerAt and stripAt and firstCard and bannerAt < stripAt and stripAt < firstCard,
          "bulk: ...under the combat banner and above the first card")

    -- ☠ NO PINS: no OpenSection call on this page passes a builder.
    for name, call in PAGE:gmatch('OpenSection%(L%["([^"]+)"%](.-)\n') do
        check(call:find("Build", 1, true) == nil, "pins: " .. name .. " grows no pin -- sort order is behaviour")
    end
end

-- ============================================================
-- 2. UNIT FRAME SORTING -- the page gate stays in the body, Self Position joins
-- ============================================================
local SORT_OPTIONS = {
    { "label",    "Sort party members by role, class, and name.\\n\\nSort order: Self Position > Role > Class > Name", "(none)", 60 },
    { "label",    "Raid: Group layout sorts within each group.\\nFlat grid layout sorts all players together.",        "(none)", 35 },
    { "checkbox", "Enable Custom Sorting",           "sortEnabled",              30 },
    { "checkbox", "Separate Melee & Ranged DPS",     "sortSeparateMeleeRanged",  30 },
    { "checkbox", "Sort by Class (within role)",     "sortByClass",              30 },
    { "dropdown", "Alphabetical (within class/role)", "sortAlphabetical",        55 },
}

print("-- Sorting page: Unit Frame Sorting")
do
    local body = builderBody("BuildSortOptionsGroup")
    checkCensus(census(body), SORT_OPTIONS, "unit frame sorting")
    local calls = 0
    for _ in PAGE:gmatch("BuildSortOptionsGroup%(") do calls = calls + 1 end
    eq(calls, 3, "unit frame sorting: declared once, mounted twice -- classic box and card")
    check(PAGE:find("local sortOptionsGroup = GUI:CreateSettingsGroup(self.child, 280)", 1, true) ~= nil
      and PAGE:find('sortOptionsGroup:AddWidget(GUI:CreateHeader(self.child, L["Unit Frame Sorting"]), 40)', 1, true) ~= nil
      and PAGE:find("Add(sortOptionsGroup, nil, 1)", 1, true) ~= nil,
          "unit frame sorting: classic's box, header and column are unchanged")

    local block, call = sectionBlock("Unit Frame Sorting")
    check(block:find('OpenSection(L["Unit Frame Sorting"], "sorting_unitframes", 1, SortOptionsSummary)', 1, true) ~= nil,
          "unit frame sorting: a card keyed sorting_unitframes in column 1, no tick, no gates, no pin")
    check(block:find("BuildSortOptionsGroup({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end, })", 1, true) ~= nil,
          "unit frame sorting: mounts the builder exactly as classic does -- the enable stays in the body")
    check(body:find(".keepEnabled = true", 1, true) ~= nil
      and body:find("group.disableChildrenOn = DisableSortOptions", 1, true) ~= nil,
          "unit frame sorting: the enable stays live under the group gate that greys the rest")
    local summary = PAGE:match("local function SortOptionsSummary%(d%)(.-)\n            end")
    check(summary and summary:find('if not d.sortEnabled then return L["Off"] end', 1, true) ~= nil,
          "unit frame sorting: shut, the corner says Off while sorting is off")

    -- ☠ SELF POSITION, the lone control, at the foot of this card.
    check(block:find('local selfPos = band:AddWidget(GUI:CreateDropdown(self.child, L["Self Position"], selfPosValues, db, "sortSelfPosition", ApplySelfPosition), 55)', 1, true) ~= nil,
          "self position: the dropdown is the card's last control -- same key, options and commit as classic")
    check(block:find("selfPos.hideOn = HideSortOptions", 1, true) ~= nil,
          "self position: ...hidden under a FrameSort takeover, as classic's box was")
    local declAt = PAGE:find("local selfPosValues = {", 1, true)
    local cardAt = PAGE:find('OpenSection(L["Unit Frame Sorting"]', 1, true)
    check(declAt and cardAt and declAt < cardAt, "self position: its vocabulary is declared above the card that uses it")
    local decls = 0
    for _ in PAGE:gmatch("local selfPosValues = {") do decls = decls + 1 end
    eq(decls, 1, "self position: ...exactly once")
    check(PAGE:find("local selfPosGroup = GUI:CreateSettingsGroup(self.child, 280)", 1, true) ~= nil
      and PAGE:find('selfPosGroup:AddWidget(GUI:CreateDropdown(self.child, L["Position"], selfPosValues, db, "sortSelfPosition", ApplySelfPosition), 55)', 1, true) ~= nil
      and PAGE:find("Add(selfPosGroup, nil, 1)", 1, true) ~= nil,
          "self position: classic keeps its own box")
end

-- ============================================================
-- 3. ROLE PRIORITY and CLASS PRIORITY -- the two drag lists
-- ============================================================
local ROLE_PRIORITY = {
    { "label", "Drag to reorder. Top = first.", "sortRoleOrder", 25 },
}
local CLASS_PRIORITY = {
    { "label", "Drag to reorder. Top = first.", "sortClassOrder", 25 },
}

for _, g in ipairs({
    { label = "Role Priority", builder = "BuildRolePriorityGroup", golden = ROLE_PRIORITY, key = "sorting_rolepriority",
      box = "rolePriorityGroup", summary = "RolePrioritySummary", hide = "HideSortOptions)" },
    { label = "Class Priority", builder = "BuildClassPriorityGroup", golden = CLASS_PRIORITY, key = "sorting_classpriority",
      box = "classPriorityGroup", summary = "ClassPrioritySummary",
      hide = "function(d) return (d.useFrameSort and FrameSortApi) or not d.sortByClass end)" },
}) do
    print("-- Sorting page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())
    local calls = 0
    for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, g.label .. ": declared once, mounted twice -- classic box and card")
    check(PAGE:find("Add(" .. g.box .. ", nil, 2)", 1, true) ~= nil, g.label .. ": classic's box still goes to column 2")
    check(body:find("group.disableChildrenOn = DisableSortOptions", 1, true) ~= nil,
          g.label .. ": the list greys through the builder's group gate")
    local block = sectionBlock(g.label)
    check(block:find('OpenSection(L["' .. g.label .. '"], "' .. g.key .. '", 2, ' .. g.summary .. ', DisableSortOptions, ' .. g.hide, 1, true) ~= nil,
          g.label .. ": a card in column 2 -- header greyed while sorting is off, hidden by classic's own gate, no pin")
    check(block:find(g.builder .. "({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end, })", 1, true) ~= nil,
          g.label .. ": mounts the builder exactly as classic does")
end

print("-- Sorting page: the Priority header")
do
    check(PAGE:find('local priorityHeader = GUI:CreateHeader(self.child, L["Priority"])\n            priorityHeader.hideOn = HideSortOptions\n            Add(priorityHeader, 40, 2)', 1, true) ~= nil,
          "priority: the category header opens column 2 and hides with both cards under a FrameSort takeover")
    local hAt = PAGE:find("Add(priorityHeader, 40, 2)", 1, true)
    local rAt = PAGE:find('OpenSection(L["Role Priority"]', 1, true)
    check(hAt and rAt and hAt < rAt, "priority: ...above the cards it names")
    -- The Separate Melee & Ranged tick still repaints the newest role list.
    check(builderBody("BuildRolePriorityGroup"):find("roleOrderWidget = GUI:CreateRoleOrderList(", 1, true) ~= nil,
          "priority: the role list rebinds the page's reference on every build")
end

-- ============================================================
-- 4. FRAMESORT INTEGRATION -- the tick moves into the header
-- ============================================================
local FRAMESORT = {
    { "label",    "(none)",               "(none)",       250 },
    { "checkbox", "Use FrameSort Addon",  "useFrameSort",  30 },
}

print("-- Sorting page: FrameSort Integration")
do
    local body = builderBody("BuildFrameSortGroup")
    checkCensus(census(body), FRAMESORT, "framesort")
    local guard = body:find("if not tools2.hoistToggle then", 1, true)
    local cb = body:find('GUI:CreateCheckbox(parent, L["Use FrameSort Addon"], db, "useFrameSort", UseFrameSortChanged)', guard or 1, true)
    check(guard and cb and cb > guard, "framesort: the builder builds the tick only when not hoisted")

    local commit = PAGE:match("local function UseFrameSortChanged%(%)(.-)\n        end")
    check(commit ~= nil and commit:find("partyDB.useFrameSort = db.useFrameSort", 1, true) ~= nil
      and commit:find("raidDB.useFrameSort = db.useFrameSort", 1, true) ~= nil
      and commit:find("DF.FrameSort:OnSettingChanged()", 1, true) ~= nil
      and commit:find("TriggerSortForCurrentMode()", 1, true) ~= nil
      and commit:find("self:RefreshStates()", 1, true) ~= nil
      and commit:find("RefreshCurrentPage", 1, true) == nil,
          "framesort: one named commit -- both modes, the module, a re-sort and a state pass, never a rebuild")

    check(PAGE:find("if FrameSortApi then\n            if classicLayout then", 1, true) ~= nil,
          "framesort: only built with the FrameSort addon, in either layout")
    check(PAGE:find("BuildFrameSortGroup({ group = frameSortGroup, parent = self.child })", 1, true) ~= nil
      and PAGE:find("Add(frameSortGroup, nil, 1)", 1, true) ~= nil,
          "framesort: classic's box and column are unchanged")
    local a = PAGE:find('OpenSection(L["FrameSort Integration"]', 1, true)
    local b = a and PAGE:find("CloseSection(band)", a, true)
    local block = (a and b) and PAGE:sub(a, b):gsub("%s+", " ") or ""
    check(block:find('OpenSection(L["FrameSort Integration"], "sorting_framesort", 1, nil, nil, nil, nil, { db = db, key = "useFrameSort", label = L["Use FrameSort Addon"], onChanged = UseFrameSortChanged, })', 1, true) ~= nil,
          "framesort: a card in column 1 whose header tick is Use FrameSort Addon, same commit, no pin")
    check(block:find("BuildFrameSortGroup({ group = band, parent = self.child, hoistToggle = true })", 1, true) ~= nil,
          "framesort: ...mounting the builder with hoistToggle, so there is one checkbox")
end

-- ============================================================
-- 5. THE ORDER, AND THE PAGE'S OWN FURNITURE
-- ============================================================
print("-- Sorting page: the order and the page's own furniture")
do
    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "), "Unit Frame Sorting | FrameSort Integration | Role Priority | Class Priority",
       "order: the cards open in classic's order, which is the one-column fold's")
    local prev = 0
    for _, a in ipairs({ "Add(sortOptionsGroup, nil, 1)", "Add(frameSortGroup, nil, 1)", "Add(selfPosGroup, nil, 1)",
                         "Add(rolePriorityGroup, nil, 2)", "Add(classPriorityGroup, nil, 2)" }) do
        local at = PAGE:find(a, prev + 1, true)
        check(at ~= nil and at > prev, "classic: still calls " .. a .. " in sequence")
        prev = at or prev
    end
    check(PAGE:find('combatBanner.hideOn = function(d) return HideSortOptions(d) or not d.sortEnabled end', 1, true) ~= nil,
          "page: the combat banner keeps its own gate")
    check(PAGE:find('{pageId = "general_frame", label = L["Frame"]}', 1, true) ~= nil,
          "page: the See Also block is unchanged")
end

-- ============================================================
-- 6. ZERO NEW LOCALE STRINGS
-- ============================================================
print("-- Sorting page: every locale string the page asks for already ships")
do
    local ENUS = options_file_source("../DandersFrames/Locales/enUS.lua")
    local seen = {}
    for key in PAGE:gmatch('L%["([^"]+)"%]') do seen[key] = true end
    local missing = 0
    for key in pairs(seen) do
        if not ENUS:find('L["' .. key .. '"] = true', 1, true) then
            missing = missing + 1
            check(false, "locale: enUS ships L[\"" .. key .. "\"]")
        end
    end
    eq(missing, 0, "locale: the page adds no new string")
end
