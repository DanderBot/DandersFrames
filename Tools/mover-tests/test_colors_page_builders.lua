local NS = ...

-- ============================================================
-- COLORS PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Auras.lua
-- ------------------------------------------------------------
-- Display > Colors is four groups: three PALETTES and one editor.
--
--   Class Colors         a way in with NO tick -- 13 swatches, a blurb and the
--                        group's own Reset All button
--   Role Colors          the same shape, 3 swatches
--   Dispel Type Colors   the same shape, 5 swatches, and the page's one
--                        incoming SECTION anchor
--   Color by Time        STAYS INLINE in both layouts (section 7)
--
-- ☠ TWO RULES MAKE THIS PAGE DIFFERENT FROM ITS SIBLINGS, and they are most of
-- why it has a suite of its own:
--
--   1. EVERY KEY BEHIND THE THREE ROWS IS A NON-PROFILE KEY. classColors /
--      roleColors / dispelColors live at the ROOT of DF.db -- one set per
--      profile, shared by party and raid -- and DF.Defaults answers only for
--      DF.db.party / DF.db.raid / the stored raid baseline. So the rows claim
--      their keys (that is the search jump's row map) and wire NEITHER the amber
--      modified tick NOR the Reset Group / Hold: Defaults footer. Section 6 is
--      there so a later sweep "completing" a row breaks a test instead of
--      stamping per-mode defaults for keys that live somewhere else. (The
--      Integrations page's Color Picker row is the same rule, one page up.)
--
--   2. "RESET ALL TO DEFAULT" REBUILT THE PAGE. Classic still does; a pane must
--      not, because the shared helper's prologue closes every open panel on a
--      rebuild, so the panel the button was clicked in would slam shut. Section
--      5 pins the one page-scope helper that branches, and pins that no builder
--      reaches for the rebuild directly.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY -- it is welded to the panel -- so this
-- file does what every page-builder suite before it does: it reads the page's
-- SOURCE and asserts against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each extracted builder -- kind, L key, db key and
--     slot height, in order -- taken from the PRE-CHANGE source. This is also
--     the evidence that CLASSIC RENDERS AS IT DID: the classic branch mounts the
--     same builder into the same 280 box in the same column.
--   ✓ the three palette LISTS, which are the real inventory: the pickers are
--     loop-built, so a dropped class is a dropped list entry, not a dropped
--     factory call.
--   ✓ that ONE builder serves both layouts.
--   ✓ that each declared row COUNT is the blurb, the reset button and the list.
--   ✓ that the build-time colour SEEDS are still inside the builders, at the
--     point they always were -- a pane is built eagerly, so they land when they
--     always did.
--   ✓ that the Color by Time cross-link's anchor and the dispel cross-link's
--     anchor both still resolve (sections 5 and 7).
--   ✓ that every locale string the page asks for already ships in enUS.
--   ✗ nothing about runtime behaviour -- the callbacks and the greying are read
--     by eye and by the in-game checklist.
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

-- The block a row is declared in, from its label to the closing brace of the
-- CreatePopoutRow opts.
local function rowOpts(labelKey)
    local a = PAGE:find('label%s*=%s*L%["' .. labelKey:gsub("%p", "%%%0") .. '"%]')
    check(a ~= nil, "source: a popout row is declared for " .. labelKey)
    if not a then return "" end
    local b = PAGE:find("}))", a, true)
    return PAGE:sub(a, (b or a) + 2)
end

-- What all three palettes have in common.
local function checkShared(builder, rowLabel, boxVar, column)
    -- ONE builder, BOTH layouts: the declaration and the two mounts.
    local calls = 0
    for _ in PAGE:gmatch(builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, rowLabel .. ": declared once, mounted twice -- classic box and popout pane")

    -- The classic branch builds the box it always did, with its own header, in
    -- the column it always had.
    local esc = rowLabel:gsub("%p", "%%%0")
    check(PAGE:find("local " .. boxVar .. " = GUI:CreateSettingsGroup(self.child, 280)", 1, true) ~= nil,
          rowLabel .. ": the classic 280 box is unchanged")
    check(PAGE:find(boxVar .. ':AddWidget%(GUI:CreateHeader%(self%.child, L%["' .. esc .. '"%]%), 40%)') ~= nil,
          rowLabel .. ": ...with its own header")
    check(PAGE:find("Add(" .. boxVar .. ", nil, " .. column .. ")", 1, true) ~= nil,
          rowLabel .. ": ...still added to column " .. column)

    local opts = rowOpts(rowLabel)
    check(opts ~= "" and opts:find("build", 1, true) ~= nil,
          rowLabel .. ": the row is handed a pre-built mount")
    check(opts:find("window", 1, true) ~= nil,
          rowLabel .. ": ...docked outside the settings window")
    check(opts:find("clipTo", 1, true) ~= nil,
          rowLabel .. ": ...and clipped by the page's own scroll frame, not the window")

    -- ☠ A PALETTE HAS NO ON/OFF AND NOTHING TO SUMMARISE. No toggle (nothing
    -- here means "am I doing anything"), and no summary: thirteen -- or five, or
    -- three -- swatches have no four-item line, and the alternatives all mean
    -- inventing a locale string or picking one swatch at random. The kit still
    -- draws the label and the count badge, which is what an empty summary is
    -- for (the Global Font Settings row is the sweep's own precedent for a row
    -- with a count and no summary).
    check(opts:find("toggle", 1, true) == nil,
          rowLabel .. ": the row declares no toggle -- a palette is always in force")
    check(opts:find("onToggle", 1, true) == nil,
          rowLabel .. ": ...and so no commit either")
    check(opts:find("summary", 1, true) == nil,
          rowLabel .. ": ...and no summary, rather than an invented one")

    -- ⚠ THE PROFILE ROOT, NOT tools.RowDB. These palettes are one set per
    -- profile, shared by both modes; a row pointed at DF.db[mode] would be
    -- describing a table it is not showing.
    check(opts:find("db      = function() return DF.db end", 1, true) ~= nil,
          rowLabel .. ": the row reads the profile root, where its colours live")
    check(opts:find("db%s*=%s*tools%.RowDB") == nil,
          rowLabel .. ": ...and never the per-mode table")

    check(PAGE:find("local %w+ = paletteBand:AddWidget%(GUI:CreatePopoutRow%(") ~= nil,
          rowLabel .. ": ...and it is mounted into the page's one band")
end

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED MACHINERY, AND ITS ONE BAND CARRIES NO HEADER
-- ============================================================
print("-- Colors page: the shared popout machinery and the page's one band")
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
    check(PAGE:find("paletteBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
          "band: the page's one band is chromeless, at the width the layout pass will give it")
    -- ⚠ NO HEADER, and that is the Sorting page's sortBand rule rather than an
    -- omission: a header names the SECTION, and the section over three rows
    -- called Class / Role / Dispel Type Colors is just "Colors" -- the word the
    -- tab already says.
    check(PAGE:find("paletteBand:AddWidget(GUI:CreateHeader", 1, true) == nil,
          "band: ...and carries no header, because the tab already says Colors")
    local bands = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, tools%.BandWidth%(%)") do bands = bands + 1 end
    eq(bands, 1, "band: one band, not three -- all three palettes share it")

    -- ---- the page-scope helpers, above every builder -------------------
    -- ☠ A closure captures the upvalue that exists when it is CREATED, so a
    -- builder declared above one of these would see nil rather than the table or
    -- the function.
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
      dbName = "classColorsDB", boxVar = "col1", column = "1",
      row = "classRow", content = "classContent", mount = "classMount",
      countVar = "CLASS_COLORS_COUNT", list = CLASS_LIST, blurb = CLASS_BLURB,
      blurbH = 50, resetVar = "resetAllBtn" },
    { builder = "BuildRoleColorsGroup", label = "Role Colors",
      dbName = "roleColorsDB", boxVar = "col2", column = "2",
      row = "roleRow", content = "roleContent", mount = "roleMount",
      countVar = "ROLE_COLORS_COUNT", list = ROLE_LIST, blurb = ROLE_BLURB,
      blurbH = 50, resetVar = "roleResetBtn" },
    { builder = "BuildDispelColorsGroup", label = "Dispel Type Colors",
      dbName = "dispelColorsDB", boxVar = "dispelCol", column = "1",
      row = "dispelRow", content = "dispelContent", mount = "dispelMount",
      countVar = "DISPEL_COLORS_COUNT", list = DISPEL_LIST, blurb = DISPEL_BLURB,
      blurbH = 55, resetVar = "dispelResetBtn" },
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

    checkShared(p.builder, p.label, p.boxVar, p.column)

    -- The group's own Reset All button, inside the pane where it always was --
    -- and parented to the BUILDER's parent, which is the popout holder in one
    -- layout and self.child in the other. That is the only thing the move is
    -- allowed to change about it.
    check(body:find('local ' .. p.resetVar .. ' = CreateFrame("Button", nil, parent, "BackdropTemplate")', 1, true) ~= nil,
          p.label .. ": the reset button is built into the builder's own parent")
    check(body:find('GUI:StyleButton(' .. p.resetVar .. ', { width = 260, height = 24, text = L["Reset All to Default"] })', 1, true) ~= nil,
          p.label .. ": ...with the same style, width and label")
    check(body:find("group:AddWidget(" .. p.resetVar .. ", 30)", 1, true) ~= nil,
          p.label .. ": ...at the same slot height")

    -- ☠ THE BUILD-TIME COLOUR SEEDS STAY INSIDE THE BUILDER, ahead of the
    -- picker that reads each one. A pane is built EAGERLY (page build, not first
    -- open), so they still land at the moment they always did -- these are
    -- writes that change the SHAPE of a profile.
    check(body:find("for i = 1, #", 1, true) ~= nil,
          p.label .. ": the pickers are built from the page's list")
    check(body:find(p.dbName .. "[", 1, true) ~= nil,
          p.label .. ": ...and the seed writes are still in that loop")

    -- No hoist branch and no group gate: there is no boolean in a palette.
    check(body:find("hoistToggle", 1, true) == nil,
          p.label .. ": the builder has no hoist branch, because there is nothing to hoist")
    check(body:find("disableChildrenOn", 1, true) == nil,
          p.label .. ": ...and no group gate either")

    -- The count is the blurb, the reset button and the list -- which is what the
    -- pane MOUNTS, and what the kit compares its declared number against.
    local declared = tonumber(PAGE:match("local " .. p.countVar .. "%s*=%s*(%d+)"))
    check(declared ~= nil, p.label .. ": the page declares the row's count in one place")
    eq(declared, #p.list + 2, p.label .. ": ...the blurb, the reset button and every swatch")
    local opts = rowOpts(p.label)
    check(opts:find("count%s*=%s*" .. p.countVar) ~= nil,
          p.label .. ": ...and the row is handed that name, not a literal")

    -- The pane is built through the shared factory, and it is told it IS a pane
    -- (which is what the reset button branches on -- section 5).
    check(PAGE:find("local " .. p.mount .. ", " .. p.content .. " = tools.PopoutContent(function(group, holder, reflow)", 1, true) ~= nil,
          p.label .. ": the pane content comes from the shared factory")
    check(PAGE:find(p.builder .. "({\n                    group = group, parent = holder,\n                    refreshStates = reflow,\n                    popout = true,\n                })", 1, true) ~= nil,
          p.label .. ": ...and the builder is told it is building into a pane")
end

-- ============================================================
-- 4. THE PAGE'S ORDER -- three rows in one band, in the source's own order
-- ============================================================
print("-- Colors page: the band's order and the page's own furniture")
do
    local order = {}
    for name in PAGE:gmatch("paletteBand:AddWidget%(GUI:CreatePopoutRow%(self%.child, {\n%s*label%s*=%s*L%[\"([^\"]+)\"%]") do
        order[#order + 1] = name
    end
    eq(#order, 3, "order: three rows go into the band")
    eq(order[1], "Class Colors",       "order: Class Colors opens it")
    eq(order[2], "Role Colors",        "order: ...then Role Colors")
    eq(order[3], "Dispel Type Colors", "order: ...then Dispel Type Colors, the page's own order")

    -- ☠ `Add` resolves a widget's slot height on the spot, so a band has to be
    -- added AFTER the last row has been put into it.
    local bandAdd = PAGE:find('Add(paletteBand, nil, "both")', 1, true)
    local lastRow
    do
        local at = 1
        while true do
            local s = PAGE:find("paletteBand:AddWidget(GUI:CreatePopoutRow(", at, true)
            if not s then break end
            lastRow, at = s, s + 1
        end
    end
    check(bandAdd ~= nil and lastRow ~= nil and lastRow < bandAdd,
          "order: the band spans both columns and goes in after its last row")

    -- Four bare 280 boxes: the three classic branches' own, and the Color by
    -- Time editor's, which is inline in BOTH layouts.
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 4, "boxes: four bare 280 boxes -- three classic branches and the inline editor")
    -- Nothing on this page stays inline WEARING THE BAND SKIN: the one group
    -- that stays is the Color by Time editor, whose title is a CollapsibleSection
    -- rather than a header inside the box -- and bandStyle starts its plate below
    -- the group's FIRST row, which for a headerless group would leave the unit
    -- tabs stranded outside it.
    check(PAGE:find("INLINE_BOX", 1, true) == nil,
          "boxes: the inline editor does not wear the band skin -- it has no header to lift out")

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
              "reset: ...it branches on which layout it is running in")
        check(helper:find("tools.ReflowMounted(true)", 1, true) ~= nil,
              "reset: ...the pane gets the VALUE sweep, which repaints the swatches in place")
        check(helper:find("pageColors:Refresh()", 1, true) ~= nil,
              "reset: ...and classic keeps the page rebuild it always had")
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

    -- ☠ THE DISPEL ROW CARRIES A SECTION ANCHOR, and it is the only row on the
    -- page that needs one. Two other pages link HERE through
    -- UI:CreateDispelColorsPageLink -> LinkToSetting{ section = L["Dispel Type
    -- Colors"] }, and Search:ScrollToSection resolves a section by asking every
    -- page child -- and every settings-group child -- for :GetText(). In classic
    -- the box's HEADER answers; in the popout layout no header is built, and the
    -- row's name is a FontString inside the row that the walk never reaches. One
    -- line puts the answer back, the same way GUI:CreateHeader's own container
    -- answers for the fontstring inside it.
    check(PAGE:find('dispelRow.GetText = function() return L["Dispel Type Colors"] end', 1, true) ~= nil,
          "anchor: the dispel row answers to its own section name, so the cross-link still lands")
    -- ...and the two halves are pinned TOGETHER: the link lives in the pack, and
    -- if it is ever renamed the anchor above has to move with it.
    check(ui_file_source("Sections.lua"):find('section = L["Dispel Type Colors"]', 1, true) ~= nil,
          "anchor: ...and the link in the pack still aims at exactly that section name")
    -- Nothing links to the other two by section, and an anchor nobody jumps to
    -- is a claim to keep in step for no one.
    check(PAGE:find("classRow.GetText", 1, true) == nil,
          "anchor: no invented anchor on Class Colors -- nothing links to it")
    check(PAGE:find("roleRow.GetText", 1, true) == nil,
          "anchor: ...nor on Role Colors")
end

-- ============================================================
-- 6. THE NON-PROFILE RULE -- claimed, but no tick and no footer
-- ☠ THIS SECTION IS THE POINT OF THE FILE. DF.Defaults answers for
-- DF.db.party / DF.db.raid / the stored raid baseline and nothing else, and
-- these three palettes live at the ROOT of DF.db. So on all three rows the tick
-- could never light, and the footer would write PER-MODE defaults for keys that
-- live somewhere else -- inventing settings in the wrong table while the colours
-- the row is showing sat untouched. A later sweep "completing" a row breaks
-- these checks.
--
-- The claim itself is NOT inert: every picker registers a search entry under its
-- own token (Search:RegisterColorPicker), so the claim is what lets a hit on
-- "Warrior" open the panel that swatch is behind. It also cannot reach the
-- Changed Settings ledger, which builds its key list from the SEARCH registry
-- rather than from any row's claim (Features/ChangedSettings.lua, BoundKeys).
-- ============================================================
print("-- Colors page: the non-profile rule")
do
    for _, p in ipairs(PALETTES) do
        check(PAGE:find("tools.ClaimKeys(" .. p.row .. ", " .. p.content .. ")", 1, true) ~= nil,
              p.label .. ": the keys ARE claimed -- that is what feeds the search jump's row map")
    end
    check(PAGE:find("tools.WireModifiedTick(", 1, true) == nil,
          "non-profile: no amber tick anywhere on the page -- the defaults engine cannot answer for these keys")
    check(PAGE:find("tools.WireFooter(", 1, true) == nil,
          "non-profile: no Reset Group / Hold strip either -- it would write per-mode defaults")
    check(PAGE:find("tools.RegisterHoistedToggle(", 1, true) == nil,
          "non-profile: and nothing is hoisted, because no palette has an on/off")
    -- ...and the reason is written down at the site, not just here.
    check(PAGE:find("DF.Defaults", 1, true) ~= nil,
          "non-profile: the page names the engine that cannot answer for these keys")
    -- Each group's own Reset All button IS the reset story on this page.
    local resets = 0
    for _ in PAGE:gmatch('text = L%["Reset All to Default"%]') do resets = resets + 1 end
    eq(resets, 3, "non-profile: three Reset All buttons, one per palette, still inside the panes")
end

-- ============================================================
-- 7. COLOR BY TIME STAYS INLINE
-- The editor rebuilds the PAGE on every structural edit -- a stop added or
-- removed, a threshold committed, the s/% tab flipped -- because each one
-- changes which widgets it has. Inside a pane that is fatal: the shared helper's
-- prologue closes every open panel on a rebuild, so the editor would slam its
-- own panel shut on each + click. Its title is also the anchor every aura page
-- and the Aura Designer flash through UI:CreateColorsPageLink, and a
-- CollapsibleSection is the one target Search:ScrollToSection expands before it
-- flashes. Left inline, both stay true for free.
-- ============================================================
print("-- Colors page: Color by Time stays inline")
do
    check(PAGE:find("BuildSection", 1, true) ~= nil,
          "cbt: the editor is still built by its own BuildSection")
    check(PAGE:find("local function BuildColorByTimeGroup(tools2)", 1, true) == nil,
          "cbt: ...and was NOT turned into a popout builder")
    local rows = 0
    for _ in PAGE:gmatch("GUI:CreatePopoutRow%(") do rows = rows + 1 end
    eq(rows, 3, "cbt: three rows on the page, so the editor is not one of them")

    -- The anchor: still a top-level CollapsibleSection page child, which is what
    -- ScrollToSection expands and flashes.
    check(PAGE:find('cbtSection = Add(GUI:CreateCollapsibleSection(self.child, L["Color by Time"], true, 280), 36, cbtColumn)', 1, true) ~= nil,
          "cbt: the section title is still a collapsible page child -- the cross-link's anchor")

    -- ⚠ IT CHANGES COLUMN, and it is the only thing on the page that moves.
    -- Classic keeps it in column 2 beside the dispel palette; in the popout
    -- layout the palettes have left the columns for the band, so a 280 box pinned
    -- right with nothing beside it would read as a rendering fault.
    check(PAGE:find("local cbtColumn = classicLayout and 2 or 1", 1, true) ~= nil,
          "cbt: the editor's column is chosen by layout, 2 in classic as it always was")
    check(PAGE:find("Add(cbtGroup, nil, cbtColumn)", 1, true) ~= nil,
          "cbt: ...and the box follows its own section")

    -- Its structural edits still rebuild the page, untouched: six call sites --
    -- the tab flip, a committed threshold, a removed stop, an added stop, the
    -- reset and the duration-text unit toggle.
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
