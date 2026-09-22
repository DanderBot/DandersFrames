local NS = ...

-- ============================================================
-- VISIBILITY PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Options.lua
-- ------------------------------------------------------------
-- Display > Visibility: ONE classic box ("Frame Display") holding two unrelated
-- things. In Modern they are the Debuff Bar's collapsible CARDS -- two per row
-- inside a card wide enough, dim captions, the value summary in a shut card's
-- corner, Expand All / Collapse All at the top:
--
--   column 1   Solo Mode       Solo Mode is the header's tick; the three
--                              rested controls grey behind it.
--   column 2   Frame Display   Hide Self from Party Frames -- independent of
--                              Solo Mode, so never behind its tick.
--
-- ☠ THE SPLIT IS THE WHOLE RISK THIS FILE COVERS. Classic still builds ONE box
-- with all six controls in their original order; it does it by mounting the two
-- builders into the same group, one after the other. If either builder drifts,
-- or if the classic arm stops mounting both, classic silently loses controls --
-- so the census below is taken from the PRE-CHANGE source and both builders are
-- checked against it.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel, so this file
-- reads the page's SOURCE and asserts against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each builder -- kind, L key, db key and slot height.
--   ✓ that ONE builder serves both layouts, and each card hands it exactly what
--     classic hands it (plus hoistToggle where the tick moved to the header).
--   ✓ each card's column, stable collapse key, summary, tick and (absent) pin.
--   ✗ nothing about runtime behaviour -- read in game.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Options.lua"):gsub("\r\n", "\n")

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

-- The page, scoped by its own two ends.
local PAGE
do
    local a = SRC:find('Add(CreateCopyButton(self.child, {"soloMode", "hidePlayerFrame", "restedIndicator"}', 1, true)
    local b = SRC:find('GUI.Tabs["display_visibility"].partyOnly = true', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Visibility page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- ONE CARD'S BLOCK: its OpenSection call up to the CloseSection that puts its
-- band in, flattened. `call` is the OpenSection call alone.
local function sectionBlock(labelKey)
    local a = PAGE:find('OpenSection(L["' .. labelKey .. '"]', 1, true)
    check(a ~= nil, "source: a card is opened for " .. labelKey)
    if not a then return "", "" end
    local b = PAGE:find("CloseSection(", a, true)
    local c = b and PAGE:find(")", b, true)
    check(b ~= nil, "source: ..." .. labelKey .. "'s band is closed after its controls")
    local block = PAGE:sub(a, c or a):gsub("%s+", " ")
    local m = block:find("%)%s*Build%w+%(")
    return block, m and block:sub(1, m) or block
end

-- ============================================================
-- 1. THE SHARED MACHINERY, AND THE POPOUT FURNITURE GONE
-- ============================================================
print("-- Visibility page: the shared machinery, and the row furniture gone")
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
    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "GUI:CreateControlRow(", "tools.PopoutContent(",
                            "tools.ClaimKeys(", "tools.WireModifiedTick(", "tools.WireFooter(",
                            "tools.RegisterHoistedToggle(", "tools.RegisterControlRow(",
                            "footerStrip", "inline = true", "_COUNT", "count =",
                            "hideSelfBand", "OnSoloModeToggle", "ApplySoloMode",
                            "INLINE_BOX", "bandStyle", "chromeless" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end

    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: every card goes through the shared helper, two per row and dim captions")
    check(PAGE:find("local function CloseSection(band)\n            tools.CloseSection(Add, band)\n        end", 1, true) ~= nil,
          "sections: ...and closes through the shared helper too")
    check(PAGE:find("GUI:RefreshCurrentPage", 1, true) == nil,
          "rebuild: the page never rebuilds itself, in either layout")
end

-- ============================================================
-- 2. THE TWO BUILDERS, CONTROL BY CONTROL, AND THEIR CARDS
-- ============================================================
--
-- ⚠ THE TWO SUB-TICK LABELS ARE ONE SPACE HERE, FOUR IN THE SOURCE: the census
-- reader flattens whitespace before it matches.
local SOLO_MODE = {
    { "checkbox", "Solo Mode",           "soloMode",             30 },
    { "checkbox", "Rested Indicator",    "restedIndicator",      30 },
    { "checkbox", " Show ZZZ Icon",      "restedIndicatorIcon",  30 },
    { "checkbox", " Show Frame Glow",    "restedIndicatorGlow",  30 },
    { "label",    "Solo Mode: Show your player frame when not in a group.", "(none)", 30 },
}
local HIDE_SELF = {
    { "checkbox", "Hide Self from Party Frames", "hidePlayerFrame", 30 },
}

print("-- Visibility page: Solo Mode")
do
    local body = builderBody("BuildSoloModeGroup")
    checkCensus(census(body), SOLO_MODE, "solo mode")

    local calls = 0
    for _ in PAGE:gmatch("BuildSoloModeGroup%(") do calls = calls + 1 end
    eq(calls, 3, "solo mode: declared once, mounted twice -- classic box and card")

    check(body:find("if not tools2.hoistToggle then", 1, true) ~= nil,
          "solo mode: the in-body checkbox is skipped when the header carries it")
    check(body:find("restedIndicator.disableOn = function(d) return not d.soloMode end", 1, true) ~= nil,
          "solo mode: the indicator greys while solo mode is off, as it always did")
    local compound = 0
    for _ in body:gmatch("disableOn = function%(d%) return not d%.soloMode or not d%.restedIndicator end") do
        compound = compound + 1
    end
    eq(compound, 2, "solo mode: ...and both sub-ticks keep the two-condition predicate")
    local hides = 0
    for _ in body:gmatch('hideOn = function%(%) return GUI%.SelectedMode == "raid" end') do hides = hides + 1 end
    eq(hides, 5, "solo mode: all five controls keep their own raid guard")
    check(SRC:find('GUI.Tabs["display_visibility"].partyOnly = true', 1, true) ~= nil,
          "solo mode: ...and the tab is still party-only")

    local block, call = sectionBlock("Solo Mode")
    check(call:find('OpenSection(L["Solo Mode"], "visibility_solo", 1, SoloModeSummary, nil, nil, nil, {', 1, true) ~= nil,
          "solo mode: a card keyed visibility_solo in column 1, printing the group's summary, no grey, no hide, no pin")
    check(call:find('db = db, key = "soloMode", label = L["Solo Mode"]', 1, true) ~= nil,
          "solo mode: the header tick is bound to soloMode under the checkbox's own name")
    check(call:find("DF:UpdateAllFrames() DF:UpdateDefaultPlayerFrame() self:RefreshStates()", 1, true) ~= nil,
          "solo mode: ...committing what the checkbox ran, then a state pass")
    check(block:find("BuildSoloModeGroup({ group = soloBand, parent = self.child, refreshStates = function() self:RefreshStates() end, hoistToggle = true, })", 1, true) ~= nil,
          "solo mode: mounts the builder as classic does, plus hoistToggle for its header tick")

    local sum = PAGE:match("local function SoloModeSummary%(d%)(.-)\n            end")
    check(sum ~= nil, "solo mode: the summary is a named function on the page")
    if sum then
        check(sum:find('L%["Rested Indicator"%]') ~= nil and sum:find('L%["Icon"%]') ~= nil
          and sum:find('L%["Glow"%]') ~= nil, "solo mode: ...in words the locale already has")
        check(sum:find("\\194\\183", 1, true) ~= nil, "solo mode: ...separated by the convention's dot")
    end
end

print("-- Visibility page: Hide Self from Party Frames")
do
    local body = builderBody("BuildHideSelfGroup")
    checkCensus(census(body), HIDE_SELF, "hide self")

    local calls = 0
    for _ in PAGE:gmatch("BuildHideSelfGroup%(") do calls = calls + 1 end
    eq(calls, 3, "hide self: declared once, mounted twice -- classic box and card")

    local apply = PAGE:match("local function ApplyHideSelf%(%)(.-)\n        end")
    check(apply ~= nil, "hide self: the apply is a named function at page scope")
    if apply then
        check(apply:find("if not InCombatLockdown() and DF.partyHeader then", 1, true) ~= nil,
              "hide self: the secure attribute write is still gated on combat")
        check(apply:find('DF.partyHeader:SetAttribute("showPlayer", not db.hidePlayerFrame)', 1, true) ~= nil,
              "hide self: ...and writes the same attribute it always did")
    end
    check(body:find('"hidePlayerFrame", ApplyHideSelf)', 1, true) ~= nil,
          "hide self: the tick runs that one copy")

    local block, call = sectionBlock("Frame Display")
    check(call:find('OpenSection(L["Frame Display"], "visibility_framedisplay", 2, nil)', 1, true) ~= nil,
          "hide self: the box's own name as a card, keyed visibility_framedisplay, in column 2 -- no tick, no pin")
    check(block:find("BuildHideSelfGroup({ group = displayBand, parent = self.child, refreshStates = function() self:RefreshStates() end, })", 1, true) ~= nil,
          "hide self: mounts the builder exactly as classic does")
end

-- ============================================================
-- 3. THE CARDS TOGETHER, AND THE CLASSIC BOX
-- ============================================================
print("-- Visibility page: the cards together, and the classic box")
do
    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "), "Solo Mode | Frame Display", "order: the two cards, in reading order")

    local hoists = 0
    for _ in PAGE:gmatch("hoistToggle = true,") do hoists = hoists + 1 end
    eq(hoists, 1, "ticks: exactly one mount skips its in-body toggle (Solo Mode)")

    check(PAGE:find('Add(tools.SectionControls(self.child), 24, "both")', 1, true) ~= nil,
          "bulk: Expand All / Collapse All at the top, spanning both columns")
    local stripAt = PAGE:find("tools.SectionControls", 1, true)
    local firstAt = PAGE:find('OpenSection(L["Solo Mode"]', 1, true)
    check(stripAt and firstAt and stripAt < firstAt, "bulk: ...above the first card")

    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 1, "classic: exactly one bare 280 box, the classic branch's own")
    check(PAGE:find('local frameDisplayGroup = GUI:CreateSettingsGroup(self.child, 280)\n            frameDisplayGroup:AddWidget(GUI:CreateHeader(self.child, L["Frame Display"]), 40)', 1, true) ~= nil,
          "classic: the box is built with the header it always had")
    check(PAGE:find("Add(frameDisplayGroup, nil, 1)", 1, true) ~= nil,
          "classic: ...and still goes to column 1")
    check(PAGE:find('Add(CreateCopyButton(self.child, {"soloMode", "hidePlayerFrame", "restedIndicator"}, L["Visibility"], "display_visibility"), 25, 2)', 1, true) ~= nil,
          "page: the copy button keeps its key list and its slot")
end
