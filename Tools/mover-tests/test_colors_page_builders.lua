local NS = ...

-- ============================================================
-- COLORS PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Auras.lua
-- ------------------------------------------------------------
-- Display > Colors: four boxes in classic; in modern, the Debuff Bar's
-- collapsible CARDS, one per box, in the columns classic has always used:
--
--   column 1   Class Colors, Dispel Type Colors
--   column 2   Role Colors, Color by Time
--
-- ☠ WHAT THIS SUITE PINS:
--   * the three palette builders' census and their page-scope lists;
--   * that ONE builder serves both layouts and the card hands it exactly what
--     classic does;
--   * the palettes are pinnable and summary-less; Color by Time is a card with
--     no pin, because its structural edits rebuild the page;
--   * the reset buttons repaint through the value sweep, never a rebuild;
--   * the two cross-link anchors ("Dispel Type Colors", "Color by Time") are
--     card titles, which Search:ScrollToSection finds and expands.
--   ✗ nothing about runtime behaviour -- read in game.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Auras.lua")

-- ---- the census reader (the Integrations page's) ----------------------
--
-- ⚠ IT TAKES THE DB TABLE'S NAME, because none of these three groups binds to
-- the page's own `db`: they bind to classColorsDB / roleColorsDB /
-- dispelColorsDB. The key match is anchored on the table name.
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

local function census(body, dbName)
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
        local key   = chunk:match('%f[%w]' .. dbName .. ',%s*"([%w_]+)"') or "(none)"
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

-- The Colors page, scoped by its own two ends. Auras.lua holds several pages --
-- Sorting, Nicknames, Integrations, Colors and every Bars page after it -- and a
-- bare 280 box on one of the others is not this pass's business.
local PAGE
do
    local a = SRC:find("-- Display > Colors", 1, true)
    local b = SRC:find("-- CATEGORY: Bars", 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Colors page builder is locatable by its own ends")
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

-- What all three palettes have in common.
local function checkShared(builder, label, boxVar, column, key, col)
    local calls = 0
    for _ in PAGE:gmatch(builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, label .. ": declared once, mounted twice -- classic box and card")

    local esc = label:gsub("%p", "%%%0")
    check(PAGE:find("local " .. boxVar .. " = GUI:CreateSettingsGroup(self.child, 280)", 1, true) ~= nil,
          label .. ": the classic 280 box is unchanged")
    check(PAGE:find(boxVar .. ':AddWidget%(GUI:CreateHeader%(self%.child, L%["' .. esc .. '"%]%), 40%)') ~= nil,
          label .. ": ...with its own header")
    check(PAGE:find("Add(" .. boxVar .. ", nil, " .. column .. ")", 1, true) ~= nil,
          label .. ": ...still added to column " .. column)

    -- ☠ A PALETTE HAS NO ON/OFF AND NOTHING TO SUMMARISE, and it decides how
    -- frames look -- so a pin, no tick, no summary, no gates.
    local block, call = sectionBlock(label)
    check(block:find('OpenSection(L["' .. label .. '"], "' .. key .. '", ' .. col .. ', nil, nil, nil, ' .. builder .. ')', 1, true) ~= nil,
          label .. ": a card keyed " .. key .. " in column " .. col .. ", no summary, pinnable from its own builder")
    check(call:find('key = "', 1, true) == nil, label .. ": ...and no header tick -- a palette is always in force")
    local mount = builder .. "({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end, })"
    check(block:find(mount, 1, true) ~= nil, label .. ": mounts the builder exactly as classic does")
end

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED CARD HELPER, AND THE POPOUT FURNITURE IS GONE
-- ============================================================
print("-- Colors page: the shared card helper")
do
    check(PAGE:find("local classicLayout = DF:IsClassicSettingsLayout()", 1, true) ~= nil,
          "tools: the page asks which layout it is building")
    check(PAGE:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true) ~= nil,
          "tools: ...and takes the shared machinery unconditionally")

    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "tools.PopoutContent(", "tools.ClaimKeys(",
                            "tools.WireModifiedTick(", "tools.WireFooter(",
                            "tools.RegisterHoistedToggle(", "paletteBand", "_COUNT = ",
                            "footerStrip", "inline = true", "popout = true,", ".GetText = function()" }) do
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
    local stripAt = PAGE:find("tools.SectionControls", 1, true)
    local firstCard = PAGE:find('OpenSection(L["Class Colors"]', 1, true)
    check(stripAt and firstCard and stripAt < firstCard, "bulk: ...above the first card")

    -- ---- the page-scope helpers, above every builder -------------------
    for _, spec in ipairs({ { "dispelColorsDB", "local %s" }, { "dispelGamePalette", "local %s" },
                            { "DISPEL_LIST", "local %s" }, { "DispelColorChanged", "local function %s(" },
                            { "DispelColorLive", "local function %s(" },
                            { "RepaintSwatches", "local function %s(" } }) do
        local h  = spec[1]
        local at = PAGE:find(spec[2]:format(h), 1, true)
        check(at ~= nil, "helpers: " .. h .. " is declared at page scope")
        for _, b in ipairs({ "BuildClassColorsGroup", "BuildRoleColorsGroup",
                             "BuildDispelColorsGroup" }) do
            local bAt = PAGE:find("local function " .. b .. "(tools2)", 1, true)
            check(at ~= nil and bAt ~= nil and at < bAt,
                  "helpers: ..." .. b .. " is declared after it, so it closes over the real one")
        end
    end
end

-- ============================================================
-- 2. THE THREE PALETTE LISTS -- the real inventory
-- The pickers are LOOP-BUILT, so the census below sees one factory call per
-- group and the list is what actually says how many swatches there are. A
-- dropped class, a renamed role or a reordered dispel type shows up here.
-- ============================================================
local CLASS_LIST = {
    { "WARRIOR", "Warrior" }, { "PALADIN", "Paladin" }, { "HUNTER", "Hunter" },
    { "ROGUE", "Rogue" }, { "PRIEST", "Priest" }, { "DEATHKNIGHT", "Death Knight" },
    { "SHAMAN", "Shaman" }, { "MAGE", "Mage" }, { "WARLOCK", "Warlock" },
    { "MONK", "Monk" }, { "DRUID", "Druid" }, { "DEMONHUNTER", "Demon Hunter" },
    { "EVOKER", "Evoker" },
}
local ROLE_LIST = {
    { "TANK", "Tank" }, { "HEALER", "Healer" }, { "DAMAGER", "Damager" },
}
local DISPEL_LIST = {
    { "Magic", "Magic" }, { "Curse", "Curse" }, { "Disease", "Disease" },
    { "Poison", "Poison" }, { "Bleed", "Bleed / Enrage" },
}

local function listEntries(varName, field)
    local body = PAGE:match("local " .. varName .. " = {(.-)\n        }")
    check(body ~= nil, "lists: " .. varName .. " is declared at page scope")
    local out = {}
    for tok, name in (body or ""):gmatch(field .. '%s*=%s*"([%w_]+)"%s*,%s*name%s*=%s*L%["([^"]+)"%]') do
        out[#out + 1] = { tok, name }
    end
    return out
end

print("-- Colors page: the three palette lists")
do
    for _, spec in ipairs({
        { "CLASS_LIST",  "token", CLASS_LIST  },
        { "ROLE_LIST",   "token", ROLE_LIST   },
        { "DISPEL_LIST", "key",   DISPEL_LIST },
    }) do
        local got, want = listEntries(spec[1], spec[2]), spec[3]
        eq(#got, #want, spec[1] .. ": entry count")
        for i = 1, math.min(#got, #want) do
            eq(got[i][1], want[i][1], spec[1] .. ": entry " .. i .. " token")
            eq(got[i][2], want[i][2], spec[1] .. ": entry " .. i .. " name")
        end
    end
end

-- ============================================================
-- 3. THE THREE PALETTE BUILDERS
-- Each is a blurb, the group's own Reset All button and one loop of pickers.
-- ============================================================
local CLASS_BLURB = "Customize class colors used throughout DandersFrames. Changes apply to health bars, name text, borders, and all other class-colored elements."
local ROLE_BLURB  = "Customize role colors used by any border whose Color Source is set to Role. Applies to Tank, Healer, and Damager assignments."
local DISPEL_BLURB = "Colours for each dispel type, used by the dispel overlay and the debuff-icon border (when Color by Dispel Type is on). Reset restores the game's colours."

local PALETTES = {
    { builder = "BuildClassColorsGroup", label = "Class Colors",
      dbName = "classColorsDB", boxVar = "col1", column = "1", key = "colors_class", col = 1,
      list = CLASS_LIST, blurb = CLASS_BLURB, blurbH = 50, resetVar = "resetAllBtn" },
    { builder = "BuildRoleColorsGroup", label = "Role Colors",
      dbName = "roleColorsDB", boxVar = "col2", column = "2", key = "colors_role", col = 2,
      list = ROLE_LIST, blurb = ROLE_BLURB, blurbH = 50, resetVar = "roleResetBtn" },
    { builder = "BuildDispelColorsGroup", label = "Dispel Type Colors",
      dbName = "dispelColorsDB", boxVar = "dispelCol", column = "1", key = "colors_dispel", col = 1,
      list = DISPEL_LIST, blurb = DISPEL_BLURB, blurbH = 55, resetVar = "dispelResetBtn" },
}

for _, p in ipairs(PALETTES) do
    print("-- Colors page: " .. p.label)
    local body = builderBody(p.builder)

    -- The census: the blurb and the ONE loop-built picker factory. The reset
    -- button is a raw CreateFrame + GUI:StyleButton, so it is pinned by name
    -- just below rather than through the shared reader.
    checkCensus(census(body, p.dbName), {
        { "label",       p.blurb, "(none)", p.blurbH },
        { "colorpicker", "(none)", "(none)", 30 },
    }, p.label:lower())

    checkShared(p.builder, p.label, p.boxVar, p.column, p.key, p.col)

    -- The group's own Reset All button, inside its group where it always was --
    -- parented to the BUILDER's parent (self.child, or a pinned panel's holder).
    check(body:find('local ' .. p.resetVar .. ' = CreateFrame("Button", nil, parent, "BackdropTemplate")', 1, true) ~= nil,
          p.label .. ": the reset button is built into the builder's own parent")
    check(body:find('GUI:StyleButton(' .. p.resetVar .. ', { width = 260, height = 24, text = L["Reset All to Default"] })', 1, true) ~= nil,
          p.label .. ": ...with the same style, width and label")
    check(body:find("group:AddWidget(" .. p.resetVar .. ", 30)", 1, true) ~= nil,
          p.label .. ": ...at the same slot height")

    -- ☠ THE BUILD-TIME COLOUR SEEDS STAY INSIDE THE BUILDER, ahead of the
    -- picker that reads each one. A card is built with the page, so they still
    -- land at the moment they always did -- these are writes that change the
    -- SHAPE of a profile.
    check(body:find("for i = 1, #", 1, true) ~= nil,
          p.label .. ": the pickers are built from the page's list")
    check(body:find(p.dbName .. "[", 1, true) ~= nil,
          p.label .. ": ...and the seed writes are still in that loop")

    -- No hoist branch and no group gate: there is no boolean in a palette.
    check(body:find("hoistToggle", 1, true) == nil,
          p.label .. ": the builder has no hoist branch, because there is nothing to hoist")
    check(body:find("disableChildrenOn", 1, true) == nil,
          p.label .. ": ...and no group gate either")


end

-- ============================================================
-- 4. THE PAGE'S ORDER -- four cards, in the source's own order
-- ============================================================
print("-- Colors page: the cards' order and the page's own furniture")
do
    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "), "Class Colors | Role Colors | Dispel Type Colors | Color by Time",
       "order: the four cards open in the page's own order, which is the one-column fold's")

    -- Four bare 280 boxes: the three classic palettes' own, and the Color by
    -- Time editor's classic box.
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 4, "boxes: four bare 280 boxes -- three classic palettes and classic's editor box")
    check(PAGE:find("INLINE_BOX", 1, true) == nil, "boxes: nothing wears the old band skin")

    -- The page still has no copy button: nothing on it is per-mode.
    check(PAGE:find("CreateCopyButton", 1, true) == nil,
          "page: no copy button -- nothing on this page is a per-mode setting")
end

-- ============================================================
-- 5. WHAT "RESET ALL TO DEFAULT" COSTS, AND THE DISPEL SECTION ANCHOR
-- ============================================================
print("-- Colors page: the reset repaint and the dispel section anchor")
do
    -- ONE page-scope helper, declared once, and it is what every reset button
    -- calls. In the pane it runs the group-wide VALUE sweep (which is what
    -- repaints a colour picker's swatch); in classic it rebuilds the page,
    -- exactly as it always did.
    local helper = PAGE:match("local function RepaintSwatches%(tools2%)(.-)\n        end")
    check(helper ~= nil, "reset: RepaintSwatches is a named page-scope helper")
    local decls = 0
    for _ in PAGE:gmatch("local function RepaintSwatches%(tools2%)") do decls = decls + 1 end
    eq(decls, 1, "reset: ...and there is exactly one of it")
    if helper then
        check(helper:find("if tools2.popout then", 1, true) ~= nil,
              "reset: ...a pinned panel reflows every mounted pane")
        check(helper:find("tools2.group:RefreshChildValues()\n                if tools then tools.ReflowMounted(true) end", 1, true) ~= nil,
              "reset: ...a card or a classic box sweeps its own group, and a card then any pinned copy")
        check(helper:find("pageColors:Refresh()", 1, true) ~= nil,
              "reset: ...and the page rebuild is only the fallback")
    end

    -- ☠ NO BUILDER REBUILDS THE PAGE ITSELF. A rebuild retires the pane, and the
    -- shared helper's prologue closes every open panel on the way in -- so a
    -- reset pressed inside a panel would slam it shut under the user's hand.
    for _, p in ipairs(PALETTES) do
        local body = builderBody(p.builder)
        check(body:find("RepaintSwatches(tools2)", 1, true) ~= nil,
              p.label .. ": the reset button goes through the shared repaint")
        check(body:find("pageColors:Refresh", 1, true) == nil,
              p.label .. ": ...and never rebuilds the page from inside a pane")
    end

    -- ☠ THE DISPEL SECTION ANCHOR IS THE CARD'S TITLE. Two other pages link HERE
    -- through UI:CreateDispelColorsPageLink -> LinkToSetting{ section =
    -- L["Dispel Type Colors"] }, and Search:ScrollToSection finds a page child
    -- by :GetText() -- which a collapsible section answers with its title.
    check(PAGE:find('OpenSection(L["Dispel Type Colors"], "colors_dispel"', 1, true) ~= nil,
          "anchor: the dispel card's title is the section name the cross-link aims at")
    check(ui_file_source("Sections.lua"):find('section = L["Dispel Type Colors"]', 1, true) ~= nil,
          "anchor: ...and the link in the pack still aims at exactly that section name")
    check(options_file_source("GUI/SettingsWidgets.lua"):find("section.GetText = function(self) return self.sectionTitleText end", 1, true) ~= nil,
          "anchor: ...and a section answers GetText with its title")
end

-- ============================================================
-- 6. THE NON-PROFILE RULE -- no tick and no footer anywhere
-- DF.Defaults answers for DF.db.party / DF.db.raid and nothing else, and these
-- three palettes live at the ROOT of DF.db. Each group's own Reset All button
-- IS the reset story on this page.
-- ============================================================
print("-- Colors page: the non-profile rule")
do
    check(PAGE:find("tools.WireModifiedTick(", 1, true) == nil,
          "non-profile: no amber tick anywhere on the page")
    check(PAGE:find("tools.WireFooter(", 1, true) == nil,
          "non-profile: no Reset Group / Hold strip either")
    check(PAGE:find("hoistToggle", 1, true) == nil,
          "non-profile: and nothing is hoisted, because no palette has an on/off")
    local resets = 0
    for _ in PAGE:gmatch('text = L%["Reset All to Default"%]') do resets = resets + 1 end
    eq(resets, 3, "non-profile: three Reset All buttons, one per palette, still inside their groups")
end

-- ============================================================
-- 7. COLOR BY TIME -- a card without a pin
-- The editor rebuilds the PAGE on every structural edit -- a stop added or
-- removed, a threshold committed, the s/% tab flipped -- because each one
-- changes which widgets it has; a pinned copy would be closed by the rebuild its
-- own click caused. Its title is also the anchor every aura page and the Aura
-- Designer flash through UI:CreateColorsPageLink, and a collapsible section is
-- the one target Search:ScrollToSection expands before it flashes -- which a
-- card is.
-- ============================================================
print("-- Colors page: Color by Time")
do
    check(PAGE:find("BuildSection", 1, true) ~= nil,
          "cbt: the editor is still built by its own BuildSection")
    check(PAGE:find("local cbtGroup = classicLayout\n            and GUI:CreateSettingsGroup(self.child, 280)\n            or OpenSection(L[\"Color by Time\"], \"colors_bytime\", cbtColumn)", 1, true) ~= nil,
          "cbt: classic's 280 box, or a card keyed colors_bytime in its column -- no summary, no pin")
    check(PAGE:find("if classicLayout then\n            Add(cbtGroup, nil, cbtColumn)\n            if cbtSection then cbtSection:RegisterChild(cbtGroup) end\n        else\n            CloseSection(cbtGroup)\n        end", 1, true) ~= nil,
          "cbt: ...classic adds its box under its section exactly as before; the card closes its own band")
    check(PAGE:find('cbtSection = classicLayout\n            and Add(GUI:CreateCollapsibleSection(self.child, L["Color by Time"], true, 280), 36, cbtColumn)\n            or nil', 1, true) ~= nil,
          "cbt: the full collapsible section is classic's only -- the card is modern's")
    check(PAGE:find("local cbtColumn = 2", 1, true) ~= nil,
          "cbt: column 2 in both layouts, as classic always had it")

    local rebuilds = 0
    for _ in PAGE:gmatch("if pageColors and pageColors%.Refresh then pageColors:Refresh%(%) end") do
        rebuilds = rebuilds + 1
    end
    eq(rebuilds, 6, "cbt: the editor's six structural rebuilds are untouched")
end

-- ============================================================
-- 8. ZERO NEW LOCALE STRINGS
-- Every L key this page asks for already ships in enUS. A sweep that invented a
-- string would have to add it there in the same commit, and this is the gate
-- that says so.
-- ============================================================
print("-- Colors page: no new locale strings")
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
