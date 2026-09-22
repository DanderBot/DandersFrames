local NS = ...

-- ============================================================
-- MISSING BUFFS PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Indicators.lua
-- ------------------------------------------------------------
-- Auras > Missing Buffs: FIVE groups. In Modern they are the Debuff Bar's
-- collapsible CARDS -- two per row inside a card wide enough, dim captions, the
-- value summary in a shut card's corner, Expand All / Collapse All at the top.
--
--   column 1   "Content"  Settings (holds the PAGE gate, Enable Missing Buff
--                         Icon, in its body -- as Show Buffs does) and Buffs to
--                         Check (Manual Mode), which hides, header and band
--                         together, while auto-detect is on.
--   column 2   "Icon"     Appearance, Position, Border (Show Border is the
--                         header's tick, through the toolkit's noShowToggle).
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db -- so this file
-- does what the other census files do: it reads the page's SOURCE and asserts
-- against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each builder -- kind, L key, db key and slot height,
--     in order -- taken from the PRE-CHANGE source. This is also the evidence
--     that CLASSIC RENDERS AS IT DID: the classic branch mounts the same builder
--     into the same 280 box in the same column.
--   ✓ that ONE builder serves both layouts, and the card hands it EXACTLY what
--     classic hands it (plus hoistToggle where the tick moved to the header).
--   ✓ each card's column, stable collapse key, summary, grey gate, hide gate,
--     header tick and pin; that there is one checkbox per setting.
--   ✓ the two opt-ins (two per row, dim captions) and that no count survives.
--   ✗ nothing about runtime behaviour -- the folding, the two-per-row flow, the
--     dim captions and the greying are read in game.
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

-- The page, scoped by its own two ends: Indicators.lua holds six pages, and a
-- bare 280 box on one of the others is not this pass's business.
local PAGE
do
    local a = SRC:find('BuildPage(pageMissingBuffs, function(self, db, Add, AddSpace, AddSyncPoint)', 1, true)
    local b = SRC:find('local pageDefensiveIcon = CreateSubTab("auras", "auras_defensiveicon", L["Defensive Icon"])', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Missing Buffs page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- ONE CARD'S BLOCK: its OpenSection call, the builder mount under it and the
-- CloseSection that puts its band in, flattened. `call` is just the OpenSection
-- call -- everything before the band mount -- which is where the pin (a builder
-- argument) and the tick are declared.
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
-- 1. THE SHARED MACHINERY, AND THE POPOUT FURNITURE GONE
-- ============================================================
print("-- Missing Buffs page: the shared machinery and the page-scope vocabulary")
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

    -- ☠ THE ROW FURNITURE IS GONE ENTIRELY, not half-gone: rows, panes on a
    -- plate, claims, counts, footers, hoisted search repairs, the bands and the
    -- index-1 repair were all PopoutRow furniture.
    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "tools.PopoutContent(", "tools.ClaimKeys(",
                            "tools.WireModifiedTick(", "tools.WireFooter(",
                            "tools.RegisterHoistedToggle(", "tools.RegisterControlRow(",
                            "GUI:CreateControlRow(", "GatePaneFirstChild", "footerStrip",
                            "inline = true", "popout = true,", "_COUNT = ", "count =",
                            "contentBand", "iconBand", "ApplyMissingSettings",
                            "OnMissingEnableToggle", "OnMissingBorderToggle" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end

    -- ---- the section helpers: forwards to the shared ones, with both opt-ins
    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: every card goes through the shared helper, two per row and dim captions")
    check(PAGE:find("local function CloseSection(band)\n            tools.CloseSection(Add, band)\n        end", 1, true) ~= nil,
          "sections: ...and closes through the shared helper too")

    -- ---- the two category headers, added straight to a column ----------
    for _, pair in ipairs({ { "Content", "1" }, { "Icon", "2" } }) do
        local n = 0
        for _ in PAGE:gmatch('Add%(GUI:CreateHeader%(self%.child, L%["' .. pair[1] .. '"%]%), 40, ' .. pair[2] .. '%)') do n = n + 1 end
        eq(n, 1, "headers: the " .. pair[1] .. " category header opens column " .. pair[2] .. ", once")
    end

    -- ---- the vocabulary, at PAGE scope, above every builder -------------
    local decls = 0
    for _ in PAGE:gmatch("local anchorOptions = {") do decls = decls + 1 end
    eq(decls, 1, "vocab: anchorOptions is declared exactly once, at page scope")
    local vocabAt = PAGE:find("local anchorOptions = {", 1, true)
    for _, b in ipairs({ "BuildMissingSettingsGroup", "BuildMissingBuffsToCheckGroup",
                         "BuildMissingAppearanceGroup", "BuildMissingPositionGroup",
                         "BuildMissingBorderGroup" }) do
        local at = PAGE:find("local function " .. b .. "(tools2)", 1, true)
        check(at ~= nil and vocabAt ~= nil and vocabAt < at,
              "vocab: " .. b .. " is declared after it, so it closes over the real table")
    end
    for _, g in ipairs({ "HideMissingBuffOptions", "HideManualBuffVariant", "refreshMissing", "MissingOffRow" }) do
        local n = 0
        for _ in PAGE:gmatch("local function " .. g .. "%(") do n = n + 1 end
        eq(n, 1, "vocab: " .. g .. " is declared exactly once")
    end

    -- Every builder still declares the group gate it always did, so the bodies
    -- grey under the page gate in both layouts.
    for _, b in ipairs({ "BuildMissingSettingsGroup", "BuildMissingBuffsToCheckGroup",
                         "BuildMissingAppearanceGroup", "BuildMissingPositionGroup" }) do
        check(builderBody(b):find("group.disableChildrenOn = HideMissingBuffOptions", 1, true) ~= nil,
              "gate: " .. b .. " carries the group gate the classic box had")
    end
    check(builderBody("BuildMissingBorderGroup"):find("tools2.group.disableChildrenOn = HideMissingBuffOptions", 1, true) ~= nil,
          "gate: the border builder carries it too, after the toolkit has mounted")

    check(PAGE:find("GUI:RefreshCurrentPage", 1, true) == nil,
          "rebuild: the page never rebuilds itself, in either layout")
end

-- ============================================================
-- 2. THE FIVE BUILDERS, CONTROL BY CONTROL, AND THEIR CARDS
-- Every golden below is the census of the PRE-CHANGE source.
-- ============================================================
local MISSING_SETTINGS = {
    { "label",    "Shows icon when party members are missing raid buffs.", "(none)", 30 },
    { "banner",   "(none)",                          "(none)",                    nil },
    { "checkbox", "Enable Missing Buff Icon",        "missingBuffIconEnabled",     30 },
    { "checkbox", "Auto-detect (your class's buff)", "missingBuffClassDetection",  30 },
    { "checkbox", "Hide Raid Buffs from Buff Bar",   "missingBuffHideFromBar",     30 },
}
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
    -- The key the census reads off this one is the PREFIX the toolkit is handed.
    { "bordercontrols", "(none)", "missingBuffIcon", nil },
}

-- label, stable collapse key, card column, classic box header and column, the
-- summary; `dim` = greys with the page gate, `hide` = the hide gate on both
-- halves, `pin` = passes its builder (decides how the icon LOOKS), `tick` = its
-- on/off moved into the header.
local CARDS = {
    { label = "Settings", key = "missingbuffs_settings", col = 1, box = "Settings", classicCol = 1,
      builder = "BuildMissingSettingsGroup", golden = MISSING_SETTINGS, summary = "MissingSettingsSummary" },
    { label = "Buffs to Check (Manual Mode)", key = "missingbuffs_buffs", col = 1,
      box = "Buffs to Check (Manual Mode)", classicCol = 1,
      builder = "BuildMissingBuffsToCheckGroup", golden = MISSING_BUFFS, summary = "MissingBuffsToCheckSummary",
      dim = true, hide = "HideManualBuffVariant" },
    { label = "Appearance", key = "missingbuffs_appearance", col = 2, box = "Appearance", classicCol = 2,
      builder = "BuildMissingAppearanceGroup", golden = MISSING_APPEARANCE, summary = "MissingAppearanceSummary",
      dim = true, pin = true },
    { label = "Position", key = "missingbuffs_position", col = 2, box = "Position", classicCol = 1,
      builder = "BuildMissingPositionGroup", golden = MISSING_POSITION, summary = "MissingPositionSummary",
      dim = true, pin = true },
    { label = "Border", key = "missingbuffs_border", col = 2, box = "Border", classicCol = 2,
      builder = "BuildMissingBorderGroup", golden = MISSING_BORDER, summary = "MissingBorderSummary",
      dim = true, pin = true, composite = true,
      tick = { key = "missingBuffIconShowBorder", name = "Show Border" } },
}

for _, g in ipairs(CARDS) do
    print("-- Missing Buffs page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())

    local calls = 0
    for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, g.label .. ": declared once, mounted twice -- classic box and card")

    local box
    for at, name in PAGE:gmatch("()local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)") do
        local want = name .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. g.box .. '"])'
        local hit = PAGE:find(want, at, true)
        if hit and hit - at < 900 then box = name break end
    end
    check(box ~= nil, g.label .. ": the classic box keeps its own header (" .. g.box .. ")")
    if box then
        check(PAGE:find("Add(" .. box .. ", nil, " .. g.classicCol .. ")", 1, true) ~= nil,
              g.label .. ": ...which still goes to column " .. g.classicCol)
    end

    local block, call = sectionBlock(g.label)
    check(block:find('OpenSection(L["' .. g.label .. '"], "' .. g.key .. '", ' .. g.col .. ', ' .. g.summary, 1, true) ~= nil,
          g.label .. ": a card keyed " .. g.key .. " in column " .. g.col .. ", printing the group's own summary")

    eq(call:find(g.summary .. ", MissingOffRow", 1, true) ~= nil, g.dim == true,
       g.label .. (g.dim and ": greys with the page gate, as its row did" or ": never greys with the page gate -- it holds the switch"))

    if g.hide then
        check(call:find("MissingOffRow, " .. g.hide .. ")", 1, true) ~= nil,
              g.label .. ": hides, header and band together, on " .. g.hide)
    else
        check(call:find("HideManualBuffVariant", 1, true) == nil, g.label .. ": carries no hide gate")
    end

    eq(call:find(g.builder, 1, true) ~= nil, g.pin == true,
       g.label .. (g.pin and ": pinnable, from its own builder" or ": decides what SHOWS, so it grows no pin"))

    if g.tick then
        check(call:find('db = db, key = "' .. g.tick.key .. '", label = L["' .. g.tick.name .. '"]', 1, true) ~= nil,
              g.label .. ": the header tick is bound to " .. g.tick.key .. " under its own name")
        check(call:find("disableOn = MissingOffRow", 1, true) ~= nil,
              g.label .. ": ...greyed with the page gate")
        check(call:find("onChanged = function()", 1, true) ~= nil
          and call:find("self:RefreshStates()", 1, true) ~= nil
          and call:find("refreshMissing()", 1, true) ~= nil
          and call:find("RefreshCurrentPage", 1, true) == nil,
              g.label .. ": ...committing through a state pass and the icon's refresh, never a page rebuild")
        if g.composite then
            check(body:find("tools2.hoistToggle or nil", 1, true) ~= nil,
                  g.label .. ": the composite is told not to build its own toggle")
        end
    else
        check(call:find("key = \"", 1, true) == nil, g.label .. ": no header tick")
    end

    local mount = g.builder .. "({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end,"
        .. (g.tick and " hoistToggle = true," or "") .. " })"
    check(block:find(mount, 1, true) ~= nil,
          g.label .. (g.tick and ": mounts the builder as classic does, plus hoistToggle for its header tick"
                              or ": mounts the builder exactly as classic does"))
end

-- ============================================================
-- 3. THE CARDS TOGETHER
-- ============================================================
print("-- Missing Buffs page: the cards together")
do
    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "),
       "Settings | Buffs to Check (Manual Mode) | Appearance | Position | Border",
       "order: the five cards open in the order the old bands read: Content, Icon")
    local iconAt = PAGE:find('Add(GUI:CreateHeader(self.child, L["Icon"]), 40, 2)', 1, true)
    local appAt  = PAGE:find('OpenSection(L["Appearance"]', 1, true)
    check(iconAt and appAt and iconAt < appAt, "order: Icon heads Appearance")

    -- ---- one checkbox per setting --------------------------------------
    local hoists = 0
    for _ in PAGE:gmatch("hoistToggle = true,") do hoists = hoists + 1 end
    eq(hoists, 1, "ticks: exactly one mount asks its builder to skip the in-body toggle (Border)")
    check((sectionBlock("Border")):find("hoistToggle = true,", 1, true) ~= nil,
          "ticks: ...and it is the ticked card's")

    -- ☠ THE PAGE'S MASTER SWITCH STAYS IN SETTINGS' BODY, as Show Buffs does.
    check((sectionBlock("Settings")):find("missingBuffIconEnabled", 1, true) == nil,
          "ticks: Enable Missing Buff Icon is not hoisted into Settings' header")
    check(builderBody("BuildMissingSettingsGroup"):find('L["Enable Missing Buff Icon"], db, "missingBuffIconEnabled"', 1, true) ~= nil,
          "ticks: ...its builder still builds it in the body")

    -- ---- Expand All / Collapse All --------------------------------------
    check(PAGE:find('Add(tools.SectionControls(self.child), 24, "both")', 1, true) ~= nil,
          "bulk: the page adds the pair at the top, spanning both columns")
    local stripAt   = PAGE:find("tools.SectionControls", 1, true)
    local contentAt = PAGE:find('Add(GUI:CreateHeader(self.child, L["Content"]), 40, 1)', 1, true)
    check(stripAt and contentAt and stripAt < contentAt,
          "bulk: ...above the first category header, because it acts on the whole page")

    -- ⚠ THE SUMMARY'S KEY TABLE AND THE BUILDER CANNOT DRIFT.
    local body = builderBody("BuildMissingBuffsToCheckGroup")
    local listed = 0
    for k in PAGE:gmatch('"(missingBuffCheck%w+)"') do
        if body:find('db, "' .. k .. '"', 1, true) then listed = listed + 1 end
    end
    eq(listed, 12, "summary: every key in MISSING_BUFF_KEYS is one the builder actually binds")

    -- ---- five classic boxes, in the order they always had ---------------
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 5, "classic: five bare 280 boxes, and they are the classic branch's own")
    local ADDS = { "settingsGroup, nil, 1", "buffsGroup, nil, 1", "appearanceGroup, nil, 2",
                   "positionGroup, nil, 1", "borderGroup, nil, 2" }
    local prev = 0
    for _, a in ipairs(ADDS) do
        local at = PAGE:find("Add(" .. a .. ")", 1, true)
        check(at ~= nil and at > prev, "classic: still calls Add(" .. a .. ") in sequence")
        prev = at or prev
    end
    check(PAGE:find("buffsGroup.hideOn = HideManualBuffVariant", 1, true) ~= nil,
          "classic: ...and still puts the variant gate on its box")

    -- ---- the page's own furniture is untouched -------------------------
    check(PAGE:find('CreateCopyButton(self.child, {"missingBuff"}, L["Missing Buffs"], "auras_missingbuffs")', 1, true) ~= nil,
          "page: the copy button keeps the prefix it owns")
    check(PAGE:find('{pageId = "auras_buffs", label = L["Buff Bar"]}', 1, true) ~= nil,
          "page: ...and the See Also block is unchanged")
end
