local NS = ...

-- ============================================================
-- FADING PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Options.lua
-- ------------------------------------------------------------
-- Display > Fading: three classic boxes. In Modern they are the Debuff Bar's
-- collapsible CARDS -- two per row inside a card wide enough, dim captions, the
-- value summary in a shut card's corner, Expand All / Collapse All at the top --
-- and the Out of Range box is split in two:
--
--   column 1   Out of Range            the range check: NO on/off (it fades
--                                      either way), no pin
--              Element-Specific Alpha  tick: oorEnabled, pinnable
--   column 2   Dead/Offline Fading     tick: fadeDeadFrames, pinnable
--              Health Threshold Fading tick: healthFadeEnabled, pinnable
--
-- ☠ THE SPLIT IS THE RISK THIS FILE COVERS. Classic still builds ONE Out of
-- Range box by mounting the two halves back to back (BuildOutOfRangeGroup), so
-- the census of the two halves, in order, must be the PRE-CHANGE census of the
-- one builder -- or classic silently lost or reordered a control.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY, so this file reads the page's SOURCE.
--   ✓ the CENSUS of each builder (the pre-change goldens), classic's mounts.
--   ✓ each card's column, stable collapse key, summary, tick and pin.
--   ✓ the two BUILD-TIME db seeds still sit inside the range builder.
--   ✗ nothing about runtime behaviour -- read in game.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Options.lua"):gsub("\r\n", "\n")

-- ⚠ CreateInput IS IN THE MAP: the custom range spell ID is an edit box. It is
-- not db-bound, so its census row carries no key.
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateInput = "input",
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

local PAGE
do
    local a = SRC:find('Add(CreateCopyButton(self.child, {"rangeFade"', 1, true)
    local b = SRC:find('{pageId = "display_visibility", label = L["Visibility"]}', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Fading page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- ONE CARD'S BLOCK: its OpenSection call up to the CloseSection that puts its
-- band in, flattened; `call` is everything before the builder MOUNT (the pin, a
-- builder argument, sits inside the call).
local function sectionBlock(labelKey, builder)
    local a = PAGE:find('OpenSection(L["' .. labelKey .. '"]', 1, true)
    check(a ~= nil, "source: a card is opened for " .. labelKey)
    if not a then return "", "" end
    local b = PAGE:find("CloseSection(", a, true)
    local c = b and PAGE:find(")", b, true)
    check(b ~= nil, "source: ..." .. labelKey .. "'s band is closed after its controls")
    local block = PAGE:sub(a, c or a):gsub("%s+", " ")
    local m = block:find(builder .. "({", 1, true)
    return block, m and block:sub(1, m - 1) or block
end

-- ============================================================
-- 1. THE SHARED MACHINERY, THE HELPERS, AND THE ROW FURNITURE GONE
-- ============================================================
print("-- Fading page: the shared machinery and the page-scope helpers")
do
    check(PAGE:find("local classicLayout = DF:IsClassicSettingsLayout()", 1, true) ~= nil,
          "tools: the page asks which layout it is building")
    check(PAGE:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true) ~= nil,
          "tools: ...and takes the shared machinery unconditionally")
    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "GUI:CreateControlRow(", "tools.PopoutContent(",
                            "tools.ClaimKeys(", "tools.WireModifiedTick(", "tools.WireFooter(",
                            "tools.RegisterHoistedToggle(", "footerStrip", "inline = true",
                            "_COUNT", "count =", "fadeBand", "chromeless", "INLINE_BOX",
                            "OnDeadFadeToggle", "OnHealthFadeToggle", "ApplyOutOfRange",
                            "ApplyDeadFade", "ApplyHealthFade" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end
    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: every card goes through the shared helper, two per row and dim captions")
    check(PAGE:find("local function CloseSection(band)\n            tools.CloseSection(Add, band)\n        end", 1, true) ~= nil,
          "sections: ...and closes through the shared helper too")
    check(PAGE:find("GUI:RefreshCurrentPage", 1, true) == nil,
          "rebuild: nothing on the page rebuilds it")

    for _, h in ipairs({ "RefreshRangeInfoLabel", "SetRangeSpellValue", "RefreshHealthFade" }) do
        local at = PAGE:find("local function " .. h .. "()", 1, true)
        local decls = 0
        for _ in PAGE:gmatch("local function " .. h .. "%(%)") do decls = decls + 1 end
        eq(decls, 1, "helpers: " .. h .. " is declared exactly once, at page scope")
        for _, b in ipairs({ "BuildRangeCheckGroup", "BuildElementAlphaGroup", "BuildDeadFadeGroup", "BuildHealthFadeGroup" }) do
            local bAt = PAGE:find("local function " .. b .. "(tools2)", 1, true)
            check(at ~= nil and bAt ~= nil and at < bAt,
                  "helpers: " .. b .. " is declared after " .. h .. ", so it closes over the real function")
        end
    end
    check(PAGE:find("local function HideOOROptions(d)", 1, true) ~= nil
      and PAGE:find("local function HideFrameLevelAlpha(d)", 1, true) ~= nil,
          "helpers: the element grey and the frame-alpha hide predicates are still page scope")
end

-- ============================================================
-- 2. OUT OF RANGE -- ONE CLASSIC BOX, TWO BUILDERS, TWO CARDS
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

print("-- Fading page: Out of Range and Element-Specific Alpha")
do
    local range = builderBody("BuildRangeCheckGroup")
    local element = builderBody("BuildElementAlphaGroup")
    checkCensus(census(range .. "\n" .. element), OUT_OF_RANGE, "out of range (both halves, in order)")
    eq(#census(range), 5, "out of range: the range half is the first five of the classic box's controls")

    -- ☠ CLASSIC STILL MOUNTS THE WHOLE BOX: both halves, back to back, once.
    local whole = PAGE:match("local function BuildOutOfRangeGroup%(tools2%)(.-)\n        end\n") or ""
    check(whole:find("BuildRangeCheckGroup(tools2)\n            BuildElementAlphaGroup(tools2)", 1, true) ~= nil,
          "classic: BuildOutOfRangeGroup mounts the range half then the element half, into one box")
    local rangeAt = PAGE:find("local function BuildRangeCheckGroup(tools2)", 1, true)
    local elemAt  = PAGE:find("local function BuildElementAlphaGroup(tools2)", 1, true)
    local wholeAt = PAGE:find("local function BuildOutOfRangeGroup(tools2)", 1, true)
    check(rangeAt and elemAt and wholeAt and rangeAt < elemAt and elemAt < wholeAt,
          "classic: ...declared after both halves, so it closes over the real functions")
    local box = PAGE:match('local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)\n%s*%1:AddWidget%(GUI:CreateHeader%(self%.child, L%["Out of Range"%]%)')
    check(box ~= nil and PAGE:find("BuildOutOfRangeGroup({\n                group = " .. box .. ",", 1, true) ~= nil
      and PAGE:find("Add(" .. box .. ", nil, 1)", 1, true) ~= nil,
          "classic: the Out of Range box still mounts the whole builder, in column 1")

    -- The two build-time seeds, still ahead of the controls that read them.
    check(range:find("if db.rangeCheckSpellID == nil then", 1, true) ~= nil
      and range:find("if db.rangeUpdateInterval == nil then", 1, true) ~= nil,
          "out of range: both db seeds are still in the range builder")
    local seeds = 0
    for _ in PAGE:gmatch("if db%.range%w+ == nil then") do seeds = seeds + 1 end
    eq(seeds, 2, "out of range: ...two seeds on the page -- neither was duplicated")
    check(range:find("self.rangeSpellInput = customSpellInput", 1, true) ~= nil
      and range:find("self.rangeSpellInfoLabel = infoLabel", 1, true) ~= nil,
          "out of range: the custom spell box and the active-spell label are still published on the page")

    -- The element half: its switch skipped when the header carries it; the
    -- tick's callback still reflows whatever it is built into.
    check(element:find("if not tools2.hoistToggle then", 1, true) ~= nil,
          "element alpha: the in-body switch is skipped when the header carries it")
    local tick = element:match('CreateCheckbox%(parent, L%["Enable Element%-Specific Alpha"%].-end%), 30%)')
    check(tick ~= nil and tick:find("tools2.refreshStates()", 1, true) ~= nil,
          "element alpha: ...and in classic it still reflows through tools2")
    check(range:find("hoistToggle", 1, true) == nil and range:find("disableChildrenOn", 1, true) == nil,
          "out of range: the range half has no toggle and no group gate")

    local block, call = sectionBlock("Out of Range", "BuildRangeCheckGroup")
    check(call:find('OpenSection(L["Out of Range"], "fading_range", 1, OutOfRangeSummary)', 1, true) ~= nil,
          "out of range: a card keyed fading_range in column 1 -- no tick, no pin")
    check(block:find("BuildRangeCheckGroup({ group = rangeBand, parent = self.child, refreshStates = function() self:RefreshStates() end, })", 1, true) ~= nil,
          "out of range: mounts the range half as classic does")

    local block2, call2 = sectionBlock("Element-Specific Alpha", "BuildElementAlphaGroup")
    check(call2:find('OpenSection(L["Element-Specific Alpha"], "fading_elements", 1, ElementAlphaSummary, nil, nil, BuildElementAlphaGroup, {', 1, true) ~= nil,
          "element alpha: a card keyed fading_elements in column 1, pinnable from its own builder")
    check(call2:find('db = db, key = "oorEnabled", label = L["Enable Element-Specific Alpha"]', 1, true) ~= nil,
          "element alpha: the header tick is bound to oorEnabled under the checkbox's own name")
    check(call2:find("self:RefreshStates()", 1, true) ~= nil and call2:find("RefreshCurrentPage", 1, true) == nil,
          "element alpha: ...committing through a state pass (which swaps the frame-level slider), never a rebuild")
    check(block2:find("BuildElementAlphaGroup({ group = elementBand, parent = self.child, refreshStates = function() self:RefreshStates() end, hoistToggle = true, })", 1, true) ~= nil,
          "element alpha: mounts the element half plus hoistToggle for its header tick")

    local oor = PAGE:match("local function OutOfRangeSummary%(d%)(.-)\n            end")
    check(oor ~= nil and oor:find("if d.oorEnabled then return \"\" end", 1, true) ~= nil and oor:find('L%["Alpha"%]') ~= nil,
          "summary: Out of Range names the frame-level alpha, and only while it is the one in use")
    local ele = PAGE:match("local function ElementAlphaSummary%(d%)(.-)\n            end")
    check(ele ~= nil and ele:find('L%["Health Bar Alpha"%]') ~= nil,
          "summary: Element-Specific Alpha names which alpha it prints")
end

-- ============================================================
-- 3. THE TWO FEATURE FADES
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

local CARDS = {
    { builder = "BuildDeadFadeGroup", label = "Dead/Offline Fading", key = "fading_dead",
      golden = DEAD_FADE, summary = "DeadFadeSummary", toggleKey = "fadeDeadFrames",
      toggleLabel = "Enable Dead Fade", runs = "DF:UpdateAllFrames()" },
    { builder = "BuildHealthFadeGroup", label = "Health Threshold Fading", key = "fading_health",
      golden = HEALTH_FADE, summary = "HealthFadeSummary", toggleKey = "healthFadeEnabled",
      toggleLabel = "Enable Health Threshold Fade", runs = "DF:UpdateAllFrames()" },
}

for _, g in ipairs(CARDS) do
    print("-- Fading page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())

    local calls = 0
    for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
    -- declaration, classic mount, card mount, and the card's pin argument
    eq(calls, 3, g.label .. ": declared once, mounted twice -- classic box and card")
    local esc = g.label:gsub("%p", "%%%0")
    local box = PAGE:match("local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)\n%s*%1:AddWidget%(GUI:CreateHeader%(self%.child, L%[\"" .. esc .. "\"%]%)")
    check(box ~= nil and PAGE:find("Add(" .. box .. ", nil, 2)", 1, true) ~= nil,
          g.label .. ": the classic box keeps its header and column 2")

    check(body:find("if not tools2.hoistToggle then", 1, true) ~= nil and body:find(".keepEnabled = true", 1, true) ~= nil,
          g.label .. ": the in-body enable is skipped under hoistToggle, and stays live in classic")
    check(body:find("group.disableChildrenOn = function(d) return not d." .. g.toggleKey .. " end", 1, true) ~= nil,
          g.label .. ": the body greys while the tick is off, from inside the builder")

    local block, call = sectionBlock(g.label, g.builder .. "({ group")
    check(call:find('OpenSection(L["' .. g.label .. '"], "' .. g.key .. '", 2, ' .. g.summary .. ', nil, nil, ' .. g.builder .. ', {', 1, true) ~= nil,
          g.label .. ": a card keyed " .. g.key .. " in column 2, its own summary, pinnable from its own builder")
    check(call:find('db = db, key = "' .. g.toggleKey .. '", label = L["' .. g.toggleLabel .. '"]', 1, true) ~= nil,
          g.label .. ": the header tick is bound to " .. g.toggleKey .. " under the checkbox's own name")
    check(call:find(g.runs, 1, true) ~= nil and call:find("self:RefreshStates()", 1, true) ~= nil
      and call:find("RefreshCurrentPage", 1, true) == nil,
          g.label .. ": ...committing what the checkbox ran plus a state pass, never a rebuild")
    check(block:find(g.builder .. "({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end, hoistToggle = true, })", 1, true) ~= nil,
          g.label .. ": mounts the builder as classic does, plus hoistToggle for its header tick")
end

-- ============================================================
-- 4. THE CARDS TOGETHER, THE CLASSIC BOXES AND THE LOCALE
-- ============================================================
print("-- Fading page: the cards together, the classic boxes, the locale")
do
    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "),
       "Out of Range | Element-Specific Alpha | Dead/Offline Fading | Health Threshold Fading",
       "order: the four cards open in reading order")
    local hoists = 0
    for _ in PAGE:gmatch("hoistToggle = true,") do hoists = hoists + 1 end
    eq(hoists, 3, "ticks: three mounts skip their in-body toggle -- one checkbox per setting")
    check(PAGE:find('Add(tools.SectionControls(self.child), 24, "both")', 1, true) ~= nil,
          "bulk: Expand All / Collapse All at the top, spanning both columns")
    local stripAt = PAGE:find("tools.SectionControls", 1, true)
    local firstAt = PAGE:find('OpenSection(L["Out of Range"]', 1, true)
    check(stripAt and firstAt and stripAt < firstAt, "bulk: ...above the first card")

    check(PAGE:find('Add(CreateCopyButton(self.child, {"rangeFade", "rangeCheck", "rangeUpdate", "oor", "fadeDead", "healthFade", "hf"}, L["Fading"], "display_fading"), 25, 2)', 1, true) ~= nil,
          "page: the copy button's prefix list is exactly what it was")
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 3, "classic: three bare 280 boxes, all the classic branch's own")
    local spacer = 0
    for _ in PAGE:gmatch("AddSpace%(GUI%.Space%.block, 2%)") do spacer = spacer + 1 end
    eq(spacer, 1, "classic: the column-2 spacer is declared once, inside the classic arm")

    -- Every string the page asks for ships in enUS. ONE is new with this
    -- conversion: the second card's title, "Element-Specific Alpha".
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
    eq(missing, 0, "locale: every string this page asks for exists in enUS")
    check(have["Element-Specific Alpha"] == true, "locale: ...including the one new title")
end
