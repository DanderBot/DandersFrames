local NS = ...

-- ============================================================
-- TEXT DESIGNER PAGE BUILDERS -- the popout layout's rows
-- ------------------------------------------------------------
-- The Text Designer was the second and last 50/50 split-panel ISLAND: a preview
-- welded to the left half, a three-tab settings column to the right, everything
-- hand-anchored inside frames the page harness never saw. Phase 4 of the designer
-- rework puts it on the shared shell (GUI/DesignerShell.lua) and turns each text
-- element into a collapsible section holding one popout row per settings group.
--
-- ☠ THE TWO FAILURES THIS FILE EXISTS FOR, and both are silent.
--
-- 1. A CONTROL THAT MOVED PANE BUT LOST ITS BINDING reads the fallback and looks
--    completely correct while writing nowhere. So the census below asserts the DB
--    KEY AND THE DB TABLE each control binds, not merely that the control exists.
--
-- 2. A ROW BOUND TO THE ELEMENT rather than to its defaults RECORD has a
--    permanently dark modified tick and a Reset Group that writes nothing while
--    saying it had -- the diff engine understands three tables and a text element
--    is none of them. And the mirror of that mistake is just as quiet: binding
--    the CONTROLS to the record marks an override flag on every write, so merely
--    building an Appearance pane would pin all five overridable fields and stop
--    the element following the Global tab. Section 6 pins both halves.
--
-- ☠ AND THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, real settings groups, GUI.SelectedMode, DF.db -- so this file does
-- what test_auradesigner_page_builders / test_visibility_page_builders do: it
-- reads the source and asserts the census against it.
--
-- What that buys, and what it does not:
--   ✓ the ROW LIST per element kind, and that a text group gets one more.
--   ✓ the widget census of all four section builders -- kind, L key, db table and
--     db key, in order.
--   ✓ that the shipped-defaults table the diff engine answers from AGREES, value
--     by value, with the inline literals the builders actually seed.
--   ✓ that the row page takes the shared machinery, at the band's width, and
--     wires each row's keys, tick and footer to the RECORD.
--   ✓ that the fold state never reaches the per-title collapsed-groups store.
--   ✓ that the canvas is the Aura Designer's, with the three opts that make it
--     safe for a second host.
--   ✗ nothing about runtime behaviour -- the panels, the greying and the canvas
--     are read by eye and by the in-game checklist.
-- ============================================================

local TD    = options_file_source("TextDesigner/UI/Options.lua")
local ROWS  = options_file_source("TextDesigner/UI/Rows.lua")
local SHELL = options_file_source("GUI/DesignerShell.lua")
local CARDS = options_file_source("AuraDesigner/UI/Cards.lua")
local AURAS = options_file_source("GUI/Pages/Auras.lua")
local TOC   = options_file_source("DandersFrames_Options.toc")

-- ---- the census reader ----------------------------------------------
-- The Aura Designer's, with one change: a Text Designer control's db table is
-- `elem` (a text element), `capturedItem` (one of a text group's members) or
-- `defaults` (the Global tab's block) -- never a proxy -- so the TABLE is read
-- out alongside the key. Which of the three a control binds is exactly what
-- section 6 is about, so it is part of the census rather than an aside.
local KIND = {
    CreateCheckbox        = "checkbox",
    CreateSlider          = "slider",
    CreateDropdown        = "dropdown",
    CreateColorPicker     = "colorpicker",
    CreateFontDropdown    = "fontdropdown",
    CreateOutlineDropdown = "outlinedropdown",
    CreateShadowCheckbox  = "shadowcheckbox",
    CreateEditBox         = "editbox",
    CreateButton          = "button",
    CreateNote            = "note",
}

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
        local tbl, key = chunk:match('%f[%w](elem),%s*"([%w_]+)"')
        if not tbl then tbl, key = chunk:match('%f[%w](capturedItem),%s*"([%w_]+)"') end
        if not tbl then tbl, key = chunk:match('%f[%w](defaults),%s*"([%w_]+)"') end
        out[#out + 1] = { kind = at.kind, label = label, tbl = tbl or "(none)", key = key or "(none)" }
    end
    return out
end

-- ☠ A WIDGET THAT IS BUILT AND NEVER PLACED IS INVISIBLE ON THE PAGE, and the
-- census cannot tell: it reads the construction, and a control dropped from a
-- pane is still constructed. So every widget a builder NAMES is followed to a
-- placement verb as well. (Widgets anchored inside another widget -- the glyph
-- buttons on an item bar -- are not built through GUI:Create and are not in
-- scope here; they cannot go missing without their host going with them.)
local function checkPlaced(body, tag)
    local n = 0
    for name in body:gmatch("([%w_]+) = GUI:Create%a+%(") do
        n = n + 1
        local ok = body:find("place(" .. name, 1, true)
                or body:find("placeWide(" .. name, 1, true)
                or body:find("placeItem(" .. name, 1, true)
                or body:find("group:AddWidget(" .. name, 1, true)
        check(ok ~= nil, tag .. ": " .. name .. " reaches a placement verb")
    end
    check(n > 0, tag .. ": ...and the reader actually found widgets (" .. n .. ")")
end

local function checkCensus(got, want, tag)
    eq(#got, #want, tag .. ": control count")
    for i = 1, math.max(#got, #want) do
        local g, e = got[i], want[i]
        if not g then
            check(false, string.format("%s: row %d missing (wanted %s)", tag, i, e[2]))
        elseif not e then
            check(false, string.format("%s: row %d unexpected (%s %s %s.%s)",
                                       tag, i, g.kind, g.label, g.tbl, g.key))
        else
            eq(g.kind,  e[1], string.format("%s: row %d kind", tag, i))
            eq(g.label, e[2], string.format("%s: row %d label", tag, i))
            eq(g.tbl,   e[3], string.format("%s: row %d db TABLE", tag, i))
            eq(g.key,   e[4], string.format("%s: row %d db key", tag, i))
        end
    end
end

-- One top-level function's body. Every one of these closes with `end` in column
-- zero, and every `end` inside is indented, so the first unindented one is the
-- function's own.
local function funcBody(src, header)
    local a = src:find(header, 1, true)
    check(a ~= nil, "source: " .. header)
    if not a then return "" end
    local b = src:find("\nend\n", a, true)
    check(b ~= nil, "source: ...and it closes")
    return src:sub(a, b or a)
end

-- ============================================================
-- 1. THE PAGE IS ON THE STANDARD HARNESS, AND TAKES THE SHARED MACHINERY
-- The whole point of the conversion: the designer stops being an island. It
-- cannot get a band, a row, a modified tick or a search entry without these.
-- ============================================================
print("-- Text Designer: the page joins the column system")
do
    check(AURAS:find("DF.BuildTextDesignerPage(GUI, self, db, Add, AddSpace)", 1, true) ~= nil,
          "harness: the page registration passes Add and AddSpace through")
    check(TD:find("function DF.BuildTextDesignerPage(GUI, page, db, Add, AddSpace)", 1, true) ~= nil,
          "harness: ...and the entry point takes them")
    check(TD:find("if Add and P.BuildTextDesignerRowsPage and not DF:IsClassicSettingsLayout() then", 1, true) ~= nil,
          "harness: the popout arm needs Add AND a non-classic layout")
    check(TD:find("local function BuildTextDesignerIsland(GUI, page, db)", 1, true) ~= nil,
          "harness: ...and the split panel survives as classic's arm")

    -- ☠ THE ISLAND IS NOT IN page.children -- it never went through Add -- so
    -- DoBuild's own retire loop cannot see it. The popout arm has to drop it by
    -- hand or it sits under the bands showing the last mode's controls.
    check(TD:find('for _, key in ipairs({ "presetBar", "controlsBar", "previewPanel",', 1, true) ~= nil,
          "harness: the popout arm retires the island's own surfaces")
    -- ...and the island's RefreshStates, which REPLACES the harness's on the page
    -- object and would otherwise lay the band column out with a verb that reaches
    -- for a preview panel that no longer exists.
    check(TD:find("page.RefreshStates = function(self) return GUI.PageRefreshStates(self) end", 1, true) ~= nil,
          "harness: ...and puts the harness's own RefreshStates back")

    check(ROWS:find("local tools = GUI:CreatePopoutPageTools(page)", 1, true) ~= nil,
          "tools: the row page takes the shared machinery")
    check(ROWS:find("if not tools then return end", 1, true) ~= nil,
          "tools: ...and bails where it answers nil, which is classic")
    for _, v in ipairs({ "PopoutContent", "ReflowPane", "ReflowMounted", "ClaimKeys",
                         "WireModifiedTick", "WireFooter", "RegisterHoistedToggle",
                         "RefreshAfterGroupWrite", "HoldReason", "BandWidth" }) do
        check(ROWS:find("local function " .. v .. "(", 1, true) == nil,
              "tools: the row page does not re-declare " .. v)
    end
    check(ROWS:find("_popoutHolders", 1, true) == nil,
          "tools: the row page never manages the popout holders itself")
    check(ROWS:find("_popoutRowForKey", 1, true) == nil,
          "tools: ...nor the search row map")

    -- The all-rows rule, for this page.
    check(ROWS:find("GUI:CreateSettingsGroup(page.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
          "band: the element's band is chromeless, at the width the layout pass gives it")
    check(ROWS:find("GUI:CreateSettingsGroup(page.child, 280", 1, true) == nil,
          "band: ...and nothing on the page is mounted at a column width")
    local addBoth = 0
    for _ in ROWS:gmatch('Add%([%w_%.]+,%s*[%w_%.]*,?%s*"both"%)') do addBoth = addBoth + 1 end
    check(addBoth >= 4, "band: every object the page adds is added \"both\" (" .. addBoth .. ")")

    -- The manifest, which is also what the all-rows sweep reads the page off.
    check(TOC:find("TextDesigner\\UI\\Rows.lua", 1, true) ~= nil,
          "toc: the row page is in the companion's manifest")
    local optAt = TOC:find("TextDesigner\\UI\\Options.lua", 1, true)
    local rowAt = TOC:find("TextDesigner\\UI\\Rows.lua", 1, true)
    local cardAt = TOC:find("AuraDesigner\\UI\\Cards.lua", 1, true)
    check(optAt and rowAt and optAt < rowAt,
          "toc: ...after the file whose private table it aliases at load")
    check(cardAt and rowAt and cardAt < rowAt,
          "toc: ...and after the file whose canvas it borrows")
end

-- ============================================================
-- 2. THE SHELL IS THE SHARED ONE, AND THE TEXT DESIGNER FILLS IT IN
-- The shell was written with a second caller in mind. This is that caller, so
-- this is where "it is generic" stops being a claim and becomes a fact.
-- ============================================================
print("-- Text Designer: the shared designer shell")
do
    check(ROWS:find("GUI:BuildDesignerShell(page, {", 1, true) ~= nil,
          "shell: the page is built through the shared shell")
    for _, opt in ipairs({ "banner = function(parent)", "canvas = function(host, shell)",
                           "canvasHeight = function()", "tabs = {", "activeTab = state.activeTab",
                           "onTab     = function(key)", "buildTab = function(key, shell)" }) do
        check(ROWS:find(opt, 1, true) ~= nil, "shell: it supplies " .. opt)
    end
    -- The Text Designer has no pool strip -- that is the Aura Designer's, and it
    -- is a parameter for exactly this reason.
    check(ROWS:find("strips", 1, true) == nil,
          "shell: ...and no strips, which the Aura Designer alone has")
    -- The shell still knows nothing about either designer.
    local SHELL_CODE = SHELL:gsub("%-%-[^\n]*", "")
    check(SHELL_CODE:find("TextDesigner", 1, true) == nil,
          "shell: the shell never reaches for the Text Designer either")

    -- The three tabs, in the order the split panel had them.
    local tabs = {}
    for key in ROWS:gmatch('{ key = "(%a+)",%s*label = L%[') do tabs[#tabs + 1] = key end
    eq(#tabs, 3, "shell: three tabs")
    eq(tabs[1], "texts",  "shell: tab 1")
    eq(tabs[2], "groups", "shell: tab 2")
    eq(tabs[3], "global", "shell: tab 3")

    -- A tab click is the harness's own rebuild, not a show/hide of hidden frames:
    -- the split panel's three tab-content frames are gone.
    check(ROWS:find("state.activeTab = key", 1, true) ~= nil,
          "shell: a tab click records which tab")
    check(ROWS:find("if page.Refresh then page:Refresh() end", 1, true) ~= nil,
          "shell: ...and rebuilds the page")
end

-- ============================================================
-- 3. THE ROWS PER ELEMENT
-- Content / Appearance / Position, and one more on a text group. Declared in ONE
-- place, because a second list is a second chance to disagree with the builders.
-- ============================================================
print("-- Text Designer: the rows per element")
do
    local mount = TD and true
    local rows = {}
    for label in ROWS:gmatch('AddRow%(L%["([^"]+)"%]') do rows[#rows + 1] = label end
    eq(#rows, 4, "rows: four AddRow call sites")
    eq(rows[1], "Content",    "rows: 1 is Content")
    eq(rows[2], "Items",      "rows: 2 is Items")
    eq(rows[3], "Appearance", "rows: 3 is Appearance")
    eq(rows[4], "Position",   "rows: 4 is Position")

    -- ...and Items is the only conditional one.
    check(ROWS:find('if isGroup then\n        AddRow(L["Items"]', 1, true) ~= nil,
          "rows: Items exists only on a text group")
    check(ROWS:find('local isGroup = elem.contentType == "group"', 1, true) ~= nil,
          "rows: ...and 'a text group' is the contentType the runtime uses")

    -- Each row mounts the builder that already existed, not a copy of it.
    check(ROWS:find("BuildContentSection(GUI, holder, elem, tdDB, state, page, card, 0, false, group)", 1, true) ~= nil,
          "rows: Content mounts the split panel's own Content builder")
    check(ROWS:find("BuildGroupItemsSection(GUI, holder, elem, tdDB, state, page, card, 0, group)", 1, true) ~= nil,
          "rows: Items mounts the item list")
    check(ROWS:find("BuildAppearanceSection(GUI, holder, elem, card, 0, group)", 1, true) ~= nil,
          "rows: Appearance mounts the Appearance builder")
    check(ROWS:find("BuildPositionSection(GUI, holder, elem, tdDB, card, 0, group)", 1, true) ~= nil,
          "rows: Position mounts the Position builder")

    -- ☠ ONE BUILDER, TWO HOSTS. `place` is the whole of the difference between a
    -- card body and a pane -- if a builder grew a second copy of its widgets for
    -- the pane, the two layouts could disagree about what a text element has.
    local places = 0
    for _ in TD:gmatch("local function place%(w, step") do places = places + 1 end
    eq(places, 5, "rows: five builders, five `place` seams and no second widget set")
    check(TD:find("if group then group:AddWidget(w) return end", 1, true) ~= nil,
          "rows: ...which ADDS to the pane's group where there is one")

    -- The item list is a section of its own now, and the card still renders it
    -- straight on under the separator.
    check(TD:find("function BuildGroupItemsSection(GUI, parent, elem, tdDB, state, page, card, yStart, group)", 1, true) ~= nil,
          "rows: the item list is its own builder")
    check(TD:find("y = BuildGroupItemsSection(GUI, parent, elem, tdDB, state, page, card, y)", 1, true) ~= nil,
          "rows: ...which the split panel's Content section still calls inline")
    check(TD:find("if not group then\n            y = BuildGroupItemsSection", 1, true) ~= nil,
          "rows: ...and the pane does NOT, because it has a row for it")
end

-- ============================================================
-- 4. THE CENSUS -- WHAT EACH ROW HOLDS, AND WHAT IT BINDS
-- The db TABLE and the db KEY, not merely the presence of a control.
-- ============================================================
print("-- Text Designer: the Content section's census")
do
    checkCensus(census(funcBody(TD, "local function BuildContentSection(GUI, parent, elem, tdDB, state, page, card, yStart, isGroupItem, group)")), {
        { "editbox",  "Label (optional)",   "elem", "label" },
        -- numeric amounts
        { "checkbox", "Abbreviate",         "elem", "abbreviate" },
        { "checkbox", "Hide when 0",        "elem", "hideWhenZero" },
        -- percentages
        { "slider",   "Decimal Places",     "elem", "decimals" },
        { "checkbox", "Hide % Symbol",      "elem", "hidePercent" },
        -- name
        { "slider",   "Max Length (0=off)", "elem", "nameLength" },
        { "dropdown", "Truncate Mode",      "elem", "truncateMode" },
        -- custom static text
        { "editbox",  "Text",               "elem", "staticText" },
        -- group number
        { "dropdown", "Format",             "elem", "groupFormat" },
        -- aggro flag
        { "editbox",  "Gaining Aggro Text", "elem", "aggroText1" },
        { "editbox",  "Tanking Text",       "elem", "aggroText2" },
        { "editbox",  "Has Aggro Text",     "elem", "aggroText3" },
        -- range text
        { "editbox",  "In Range Text",      "elem", "rangeInText" },
        { "editbox",  "Out of Range Text",  "elem", "rangeOutText" },
        -- text group
        { "editbox",  "Separator",          "elem", "groupSeparator" },
    }, "content")
    checkPlaced(funcBody(TD, "local function BuildContentSection(GUI, parent, elem, tdDB, state, page, card, yStart, isGroupItem, group)"), "content")
end

print("-- Text Designer: the Items section's census")
do
    checkCensus(census(funcBody(TD, "function BuildGroupItemsSection(GUI, parent, elem, tdDB, state, page, card, yStart, group)")), {
        -- the empty state, in a pane only
        { "note",     "No items yet",     "(none)",       "(none)" },
        -- one expanded item's own colour controls; its content fields come from
        -- the recursive BuildContentSection call, censused above
        { "checkbox", "Use Class Color",  "capturedItem", "useClassColor" },
        { "checkbox", "Custom Color",     "capturedItem", "useColor" },
        { "colorpicker", "Color",         "capturedItem", "color" },
        { "button",   "Add Item",         "(none)",       "(none)" },
    }, "items")
    checkPlaced(funcBody(TD, "function BuildGroupItemsSection(GUI, parent, elem, tdDB, state, page, card, yStart, group)"), "items")

    -- ☠ THE PER-ITEM EDITOR RECURSES, and in a pane its fields belong to the SAME
    -- group -- a nested call that dropped `group` would build them onto the pane's
    -- hidden holder, where they are never seen.
    check(TD:find("BuildContentSection(GUI, parent, capturedItem, tdDB, state, page, card, y, true, group)", 1, true) ~= nil,
          "items: the per-item editor passes the pane's group down")
end

print("-- Text Designer: the Appearance section's census")
do
    checkCensus(census(funcBody(TD, "local function BuildAppearanceSection(GUI, parent, elem, card, yStart, group)")), {
        { "fontdropdown",    "Font",            "elem", "font" },
        { "dropdown",        "Font",            "elem", "font" },   -- the no-LSM fallback
        { "slider",          "Size",            "elem", "fontSize" },
        { "outlinedropdown", "Outline",         "elem", "outline" },
        { "shadowcheckbox",  "Shadow",          "elem", "outline" },
        { "colorpicker",     "Color",           "elem", "color" },
        { "checkbox",        "Use Class Color", "elem", "useClassColor" },
    }, "appearance")
    checkPlaced(funcBody(TD, "local function BuildAppearanceSection(GUI, parent, elem, card, yStart, group)"), "appearance")

    -- The five fields the RENDERER resolves through overrides are exactly the five
    -- these controls write, and each callback still sets the flag itself.
    for _, key in ipairs({ "font", "fontSize", "outline", "color", "useClassColor" }) do
        check(TD:find("elem.overrides." .. key .. " = true", 1, true) ~= nil,
              "appearance: " .. key .. "'s callback still marks its own override")
    end
end

print("-- Text Designer: the Position section's census")
do
    checkCensus(census(funcBody(TD, "local function BuildPositionSection(GUI, parent, elem, tdDB, card, yStart, group)")), {
        { "slider",   "Offset X",  "elem", "offsetX" },
        { "slider",   "Offset Y",  "elem", "offsetY" },
        { "dropdown", "Anchor To", "elem", "anchorTo" },
    }, "position")
    checkPlaced(funcBody(TD, "local function BuildPositionSection(GUI, parent, elem, tdDB, card, yStart, group)"), "position")

    -- ...plus the 9-point anchor grid, which is NOT a kit widget. The kit's
    -- CreateAnchorGrid is a 3x2 CORNER picker over TWO keys (a raid block's align
    -- and wrap axes); this is a 3x3 point picker over ONE. Different control,
    -- different data, so it stays hand-rolled -- and it is one widget now.
    check(TD:find("local grid = CreateAnchorGrid(GUI, parent, elem, card)", 1, true) ~= nil,
          "position: the anchor grid is the page's own 9-point picker")
    check(TD:find("elem.anchor = point", 1, true) ~= nil,
          "position: ...writing the one key the runtime reads")
    -- ☠ AND IT CARRIES ITS OWN CAPTION. A FontString built on `parent` stays on
    -- the pane's HIDDEN holder -- a group can only take frames -- so the caption
    -- had to move inside the grid or it would simply never be drawn.
    check(TD:find('local gridLabel = grid:CreateFontString(nil, "OVERLAY")', 1, true) ~= nil,
          "position: the grid's caption is inside the grid, not a sibling")
    check(TD:find('gridLabel:SetPoint("TOP", btns.BOTTOM, "BOTTOM", 0, -2)', 1, true) ~= nil,
          "position: ...anchored to the buttons, which a stretched pane does not move")
end

print("-- Text Designer: the Global tab's census")
do
    checkCensus(census(funcBody(TD, "local function BuildGlobalTab(GUI, parent, state, tdDB, page, group)")), {
        { "note", "These defaults apply to all text elements that haven't been individually customized.",
                             "(none)",   "(none)" },
        { "fontdropdown",    "Font",            "defaults", "font" },
        { "dropdown",        "Font",            "defaults", "font" },     -- the no-LSM fallback
        { "slider",          "Size",            "defaults", "fontSize" },
        { "outlinedropdown", "Outline",         "defaults", "outline" },
        { "shadowcheckbox",  "Shadow",          "defaults", "outline" },
        { "colorpicker",     "Color",           "defaults", "color" },
        { "checkbox",        "Use Class Color", "defaults", "useClassColor" },
        { "note", "Rebuild the element list from your current built-in name, health, and status text. This replaces all existing Text Designer elements for this mode.",
                             "(none)",   "(none)" },
        { "button",          "Import Current Text Settings", "(none)", "(none)" },
    }, "global")
    checkPlaced(funcBody(TD, "local function BuildGlobalTab(GUI, parent, state, tdDB, page, group)"), "global")

    -- One row, not seven: the Global tab IS one group of settings.
    check(ROWS:find("local function BuildGlobalTabRows(ctx)", 1, true) ~= nil,
          "global: the tab is built as rows")
    check(ROWS:find("BuildGlobalTab(GUI, holder, state, tdDB, page, group)", 1, true) ~= nil,
          "global: ...mounting the split panel's own builder into the pane")
end

-- ============================================================
-- 5. THE SHIPPED DEFAULTS AGREE WITH THE LITERALS THEY WERE COLLECTED FROM
-- ------------------------------------------------------------
-- Phase 0 concluded that Content and Position "cannot get a working modified tick
-- without a schema change", because only five fields have an override flag. That
-- was wrong: shipped defaults for the rest DO exist, as inline literals in the
-- builders. TD_SHIPPED is those literals gathered so the adapter can answer from
-- them -- which means TD_SHIPPED and the builders are TWO SPELLINGS OF ONE
-- NUMBER, and the moment they disagree the tick lies in a way nothing else here
-- would catch. So both sides are read out of the source and compared.
-- ============================================================
print("-- Text Designer: the shipped defaults are the builders' own literals")
do
    local block = TD:match("local TD_SHIPPED = {(.-)\n}")
    check(block ~= nil, "defaults: the shipped-defaults table can be read from the source")
    block = block or ""

    local shipped, order = {}, {}
    for line in block:gmatch("[^\n]+") do
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-),%s*$")
        if key then
            shipped[key] = value
            order[#order + 1] = key
        end
    end
    check(#order >= 19, "defaults: ...and it has every field (" .. #order .. ")")

    -- What the builders actually seed, in either of the two shapes they use.
    local function seedOf(key)
        for line in TD:gmatch("[^\n]+") do
            if not line:match("^%s*%-%-") then
                local v = line:match("^%s*elem%." .. key .. " = elem%." .. key .. " or (.+)$")
                if v then return (v:gsub("%s+$", "")) end
                v = line:match("^%s*if elem%." .. key .. " == nil then elem%." .. key .. " = (.-) end%s*$")
                if v then return v end
            end
        end
    end

    -- The two fields with NO seed at all. Their absence is the whole reason the
    -- shipped value is `false`: an unticked checkbox writes nothing, so nil is
    -- what an untouched element holds and false is what it means.
    local UNSEEDED = { hidePercent = true, useColor = true }

    for _, key in ipairs(order) do
        local want = shipped[key]
        local got = seedOf(key)
        if UNSEEDED[key] then
            eq(want, "false", "defaults: " .. key .. " ships false")
            check(got == nil, "defaults: ...and nothing seeds it, which is why")
        else
            check(got ~= nil, "defaults: " .. key .. " is seeded by a builder")
            eq(got or "(none)", want, "defaults: " .. key .. " matches the literal it was collected from")
        end
    end

    -- ⚠ `label` IS NOT IN THE TABLE, and must not be: creation writes
    -- ComputeAutoLabel's answer, which is not a static value, so a "" default
    -- would report every auto-numbered element's own name as a user edit.
    check(shipped.label == nil, "defaults: label is deliberately absent")
    check(TD:find("label       = ComputeAutoLabel(tdDB, ct),", 1, true) ~= nil,
          "defaults: ...because creation writes a computed one")

    -- The adapter answers from both chains, and compares the second by VALUE --
    -- the builders MATERIALISE these defaults onto the element as a pane builds,
    -- so presence proves nothing. (ValuesEqual is Core/Defaults.lua's, asserted
    -- there; here we pin that the adapter goes through it rather than presence.)
    check(TD:find("if TD_SHIPPED[k] == nil then return nil end", 1, true) ~= nil,
          "defaults: GetStored answers only for keys that are settings here")
    check(TD:find("return rawget(elem, k)", 1, true) ~= nil,
          "defaults: ...and reads RAW, never back through anything that resolves")
    check(TD:find("return TD_SHIPPED[k]", 1, true) ~= nil,
          "defaults: GetDefault falls back to the shipped literal")

    -- Reset: the five follow the Global tab again; the rest are WRITTEN, because
    -- there is no global for them to follow and a widget on screen needs a value.
    check(TD:find("elseif TD_SHIPPED[k] ~= nil then\n                elem[k] = TD_SHIPPED[k]", 1, true) ~= nil,
          "defaults: reset writes the shipped value for a field with no global")
    check(TD:find("if ovr then ovr[k] = nil end", 1, true) ~= nil,
          "defaults: ...and clears the override for one that has")
    -- Every shipped value is a SCALAR, so ClearKey's write cannot leak a shared
    -- table onto a profile the way a table default would.
    for _, key in ipairs(order) do
        local v = shipped[key] or ""
        check(v:find("{", 1, true) == nil,
              "defaults: " .. key .. "'s shipped value is a scalar, so reset cannot alias it")
    end
end

-- ============================================================
-- 6. THE ROWS ARE WIRED TO THE RECORD; THE CONTROLS ARE NOT
-- Both halves, because each mistake is silent in its own direction.
-- ============================================================
print("-- Text Designer: each row's tick, keys and footer")
do
    check(ROWS:find("local record = ElementDefaultsRecord(elem, tdDB)", 1, true) ~= nil,
          "wiring: the row page resolves the element's defaults record")
    check(ROWS:find("local RowRecord = function() return record end", 1, true) ~= nil,
          "wiring: ...as a function, so a mode switch is followed rather than frozen")
    -- ⚠ COUNTED, NOT MERELY FOUND. There is more than one CreatePopoutRow site
    -- on this page, and a `find` is satisfied by the one that is still right --
    -- so re-binding the other to the element would pass. Every row, every time.
    local popoutRows, bound, claims, ticks, footers = 0, 0, 0, 0, 0
    for _ in ROWS:gmatch("GUI:CreatePopoutRow%(") do popoutRows = popoutRows + 1 end
    for _ in ROWS:gmatch("db      = RowRecord,") do bound = bound + 1 end
    for _ in ROWS:gmatch("tools%.ClaimKeys%(row, content%)") do claims = claims + 1 end
    for _ in ROWS:gmatch("tools%.WireModifiedTick%(row%)") do ticks = ticks + 1 end
    for _ in ROWS:gmatch("tools%.WireFooter%(row, ApplyElementGroup, RowRecord%)") do footers = footers + 1 end
    eq(popoutRows, 2, "wiring: the page has two popout-row sites -- an element's, and Global's")
    eq(bound,   popoutRows, "wiring: ...and EVERY one takes the record")
    eq(claims,  popoutRows, "wiring: ...claims the keys its pane registered")
    eq(ticks,   popoutRows, "wiring: ...gets the amber modified tick")
    eq(footers, popoutRows, "wiring: ...and a footer whose verbs write through the record")
    check(ROWS:find("tools.RowDB", 1, true) == nil,
          "wiring: no designer row is wired to DF.db[mode]")

    -- ☠ AND THE OTHER HALF. The controls bind to `elem`; a write through the
    -- record marks an override flag, so binding them to it would pin all five
    -- appearance fields the moment a pane was built.
    check(ROWS:find("BuildAppearanceSection(GUI, holder, record", 1, true) == nil,
          "wiring: no section builder is handed the record instead of the element")
    check(ROWS:find("BuildContentSection(GUI, holder, record", 1, true) == nil,
          "wiring: ...not the Content one either")
    check(TD:find("if TD_OVERRIDABLE[k] then\n                elem.overrides = elem.overrides or {}", 1, true) ~= nil,
          "wiring: ...and the record's own __newindex is what would have marked them")

    -- The count badge is derived, never declared: what a Content pane holds
    -- varies with the element's content type.
    check(ROWS:find("count   = content and content.groupChildren and #content.groupChildren or nil", 1, true) ~= nil,
          "wiring: the count badge is read off the pane that was actually built")

    -- The Global tab's row takes the OTHER record, over the preset's own block.
    check(ROWS:find("local record = GlobalDefaultsRecord(tdDB)", 1, true) ~= nil,
          "wiring: the Global row takes the global-defaults record")
end

-- ============================================================
-- 7. THE ELEMENT ROW EXPANDS; IT DOES NOT OPEN A PANEL
-- ...and its fold state adds no db key, which is the trap the Aura Designer's
-- conversion nearly shipped.
-- ============================================================
print("-- Text Designer: the element is a section, its groups are the rows")
do
    check(ROWS:find("local section = GUI:CreateCollapsibleSection(page.child, title, false, bandW)", 1, true) ~= nil,
          "expand: an element is a collapsible section at the band's width")
    check(ROWS:find("section:RegisterChild(band)", 1, true) ~= nil,
          "expand: ...and its band is a section child, so the fold collapses the rows with it")
    check(ROWS:find("if not section.expanded then return end", 1, true) ~= nil,
          "expand: a collapsed element builds no rows at all")

    -- ☠ NO NEW DB KEYS. CreateCollapsibleSection persists its fold under the
    -- section TITLE, and a text element's title is a USER-EDITABLE LABEL -- one
    -- permanent profile key per element per rename. The card layout already
    -- persists this under a stable id key; that is the key this uses.
    check(ROWS:find('local foldKey = (isGroup and "td_group_" or "td_elem_") .. tostring(elem.id)', 1, true) ~= nil,
          "expand: the fold key is the card layout's own stable id key")
    check(TD:find('local cardKey = "td_elem_" .. tostring(elem.id)', 1, true) ~= nil,
          "expand: ...which is the same key the card writes")
    check(ROWS:find("section.Toggle = function(self)", 1, true) ~= nil,
          "expand: Toggle is REPLACED, so the factory's own title write never runs")
    check(ROWS:find("saved[foldKey] = self.expanded and true or nil", 1, true) ~= nil,
          "expand: ...and writes the id key rather than the title")
    -- The only GetCollapsedGroups read on this page is through that key.
    local gcg = 0
    for _ in ROWS:gmatch("GetCollapsedGroups") do gcg = gcg + 1 end
    eq(gcg, 1, "expand: the collapsed-groups store is touched in exactly one place")
end

-- ============================================================
-- 8. THE CANVAS IS THE AURA DESIGNER'S -- DECISION 4
-- One description of the frame's anatomy, not two. Which needs three things the
-- canvas previously assumed about its host.
-- ============================================================
print("-- Text Designer: the shared canvas")
do
    check(ROWS:find("AD.CreateFramePreview(host, 0, nil, {", 1, true) ~= nil,
          "canvas: the row page mounts the Aura Designer's canvas")
    check(TD:find("local previewNote = previewPanel:CreateFontString", 1, true) ~= nil,
          "canvas: ...while the split panel still draws its own, which is classic's")

    for _, opt in ipairs({ "compact   = true,", "scaleDB   = tdDB,",
                           "placement = false,", "unitText  = false," }) do
        check(ROWS:find(opt, 1, true) ~= nil, "canvas: it passes " .. opt)
    end

    -- ☠ WHY EACH OF THE THREE EXISTS, pinned against the canvas itself.
    -- scaleDB: the two designers keep previewScale in DIFFERENT tables, and
    -- without it the Text Designer's slider would write the Aura Designer's key.
    check(CARDS:find("local scaleDB = (opts and opts.scaleDB) or adDB", 1, true) ~= nil,
          "canvas: scaleDB defaults to the Aura Designer's own config")
    check(CARDS:find('GUI:CreateSlider(container, L["Preview Scale"], 0.75, 2.5, 0.05, scaleDB, "previewScale",', 1, true) ~= nil,
          "canvas: ...and the slider binds to it, not to a fixed table")
    check(CARDS:find("function P.CanvasWantedHeight(compact, scaleDB)", 1, true) ~= nil,
          "canvas: ...as does the band-height verb, which must read the same number")
    check(ROWS:find("AD.CanvasWantedHeight(true, tdDB)", 1, true) ~= nil,
          "canvas: ...and the Text Designer's band asks with its own table")

    -- placement: anchorDots is ONE module-level table and dragHintText ONE state
    -- field. A second canvas building them re-points the Aura Designer's own drop
    -- targets at this page's mock -- and settings search rebuilds EVERY page.
    check(CARDS:find("local placement = not (opts and opts.placement == false)", 1, true) ~= nil,
          "canvas: placement defaults on, so the Aura Designer is unchanged")
    check(CARDS:find("if placement then\n    wipe(anchorDots)", 1, true) ~= nil,
          "canvas: ...and gates the wipe of the shared anchor-dot table")
    check(CARDS:find("if placement then\n    S.dragHintText = container:CreateFontString", 1, true) ~= nil,
          "canvas: ...and the shared drag hint")
    check(CARDS:find("if not placement then instrRows = {} end", 1, true) ~= nil,
          "canvas: ...and the drag instructions, which describe placing an indicator")

    -- unitText: the mock's built-in name and health strings would be drawn on top
    -- of the very text elements this page configures.
    check(CARDS:find("local unitText  = not (opts and opts.unitText == false)", 1, true) ~= nil,
          "canvas: unitText defaults on")
    check(CARDS:find("if unitText then\n    -- Resolve fonts from settings", 1, true) ~= nil,
          "canvas: ...and gates the mock's own name and health strings")

    -- The band grows with the preview scale, exactly as the Aura Designer's does.
    check(ROWS:find("canvas.onWantHeight = function(want)", 1, true) ~= nil,
          "canvas: the canvas reports the height it now wants")
    check(ROWS:find("if shell and shell.SetCanvasHeight then shell.SetCanvasHeight(want) end", 1, true) ~= nil,
          "canvas: ...and the shell regrows the band in place")
    check(ROWS:find("local CANVAS_H = 132", 1, true) ~= nil,
          "canvas: 132 is the FLOOR, which is the artifact's figure")

    -- The preview module is re-bound to the new mock, or the page would draw text
    -- onto a frame that no longer exists.
    check(ROWS:find("DF.TextDesigner.Preview:Init(canvas.mockFrame, tdDB)", 1, true) ~= nil,
          "canvas: the text preview is bound to the shared canvas's mock")
    check(ROWS:find('host:HookScript("OnShow", function()', 1, true) ~= nil,
          "canvas: ...and re-reads its geometry when the page shows")
end

-- ============================================================
-- 9. THE FURNITURE THAT HAS NOT CONVERTED YET STILL RENDERS
-- The add flow is phase 5. Until then the page has to be fully usable, so the
-- CTA, the caption and the filter chips render exactly what they rendered inside
-- the split panel -- as one full-width object in the band column.
-- ============================================================
print("-- Text Designer: the add flow, one definition and two hosts")
do
    check(SHELL:find("function GUI:AddDesignerLegacyTab(shell, build)", 1, true) ~= nil,
          "legacy: the shell has a door for unconverted furniture")
    check(ROWS:find("GUI:AddDesignerLegacyTab(shell, function(host)", 1, true) ~= nil,
          "legacy: the row page uses it for the tab's head area")
    check(TD:find("local function BuildTextsHeadArea(GUI, parent, state, tdDB, page, rightInset)", 1, true) ~= nil,
          "legacy: the Texts head area is declared once")
    check(TD:find("local function BuildGroupsHeadArea(GUI, parent, state, tdDB, page, rightInset)", 1, true) ~= nil,
          "legacy: ...and so is the Text Groups one")
    check(TD:find("BuildTextsHeadArea(GUI, parent, state, tdDB, page)\n", 1, true) ~= nil,
          "legacy: the split panel's Texts tab mounts it")
    check(ROWS:find("BuildTextsHeadArea(GUI, host, state, tdDB, page, 0)", 1, true) ~= nil,
          "legacy: ...and the band mounts it with no scrollbar to clear")
    check(TD:find('addBtn:SetPoint("RIGHT", parent, "RIGHT", -RIGHT_INSET, 0)', 1, true) ~= nil,
          "legacy: ...which is the whole of the difference between the two hosts")

    -- ☠ AND THE CHIP THAT REDRAWS THE LIST HAD TO LEARN WHICH LIST. In the popout
    -- layout the list IS the page, and RenderCardList returns early without a card
    -- list -- so the chip would have looked selected and changed nothing.
    check(TD:find("if state.rowsMode then\n                if P.RowsRedraw then P.RowsRedraw(page) end", 1, true) ~= nil,
          "legacy: the filter chip redraws the right list")
    check(TD:find('if state and state.rowsMode then\n        if P.RowsRedraw then P.RowsRedraw(page) end', 1, true) ~= nil,
          "legacy: ...and so does FullRebuildCards, which thirty call sites reach")
    check(TD:find("GetState(page).rowsMode = false", 1, true) ~= nil,
          "legacy: ...and the island clears the flag, so a layout flip is not stuck")
end

-- ============================================================
-- 10. A STRUCTURAL CHANGE INSIDE A PANE RE-OPENS THE PANE
-- Adding or removing a group item changes WHAT IS IN a pane, and the popout kit
-- builds a pane's contents once -- so the only rebuild available is the page's,
-- which closes every panel including the one the click landed in.
-- ============================================================
print("-- Text Designer: a rebuild puts the open panel back")
do
    check(ROWS:find("P.RowsRedraw = function(page)", 1, true) ~= nil,
          "reopen: the row page owns the redraw verb")
    check(ROWS:find("if row.popout then reopenTitle = title break end", 1, true) ~= nil,
          "reopen: ...which records the open panel before rebuilding")
    check(ROWS:find("rowsByTitle[rowTitle] = row", 1, true) ~= nil,
          "reopen: every row is registered by the title it would be found under")
    check(ROWS:find("if row and row.OpenPopout then row:OpenPopout() end", 1, true) ~= nil,
          "reopen: ...and the rebuilt page re-opens it")
    check(ROWS:find("wipe(rowsByTitle)", 1, true) ~= nil,
          "reopen: the registry is cleared per build, so it never holds a retired row")
end

-- ============================================================
-- 11. THE WIDE-PAGE FLOOR IS GONE
-- The Text Designer's half of the acceptance test; the Aura Designer's census
-- asserts the same thing from its own side, deliberately, because either page
-- regressing to a split layout would need its floor back.
-- ============================================================
print("-- Text Designer: the wide-page floor is gone")
do
    local PANEL = options_file_source("GUI/Panel.lua")
    -- ⚠ THE TABLE'S BODY, NOT THE FILE. Both page ids also appear in the
    -- slash-command alias map (Panel.lua:977, :998), so a file-wide find answers
    -- "is this string anywhere" and never "is this page still a wide page".
    local WIDE = PANEL:match("local WIDE_PAGES = {(.-)}")
    check(WIDE ~= nil, "wide: the WIDE_PAGES table can be found")
    check(WIDE:find("text_designer", 1, true) == nil,
          "wide: the Text Designer no longer forces the window to 850")
    check(WIDE:find("auras_auradesigner", 1, true) == nil,
          "wide: ...and neither does the Aura Designer")
end

-- ============================================================
-- 12. THE NARROW WINDOW -- WHAT 850px WAS HIDING
-- ------------------------------------------------------------
-- Section 11 removed the floor, so this page now renders in the 640px default
-- window: a band of roughly 410px, and as little as ~280 at the window's own
-- minimum. The Aura Designer's census documents the three classes of layout bug
-- that width exposed; this is the Text Designer's half of the same sweep, because
-- the two pages share the shell, the preset bar and the section header and would
-- regress independently.
-- ============================================================
print("-- Text Designer: the narrow window")
do
    local SW = options_file_source("GUI/SettingsWidgets.lua")

    -- ---- class one: the Texts head area's chip row ----------------------
    local HEAD = TD:match("local function BuildTextsHeadArea.-\n    return Measure%(%)\nend")
    check(HEAD ~= nil, "narrow: the Texts head area can be read")
    HEAD = HEAD or ""
    check(HEAD:find("local hostW = parent:GetWidth()", 1, true) ~= nil,
          "narrow: the head area derives its column from the host it was sized to")
    check(HEAD:find("local COL_W = (hostW > 40) and (hostW - 8 - RIGHT_INSET) or nil", 1, true) ~= nil,
          "narrow: ...as the host's width less the left inset and the caller's right one")
    check(HEAD:find("if maxW <= 0 then maxW = COL_W or 260 end", 1, true) ~= nil,
          "narrow: the chips wrap to that column, not to a hardcoded 260")
    check(HEAD:find("local function Measure()", 1, true) ~= nil,
          "narrow: the head area's height is a verb, so it can be asked twice")
    -- (X) THE ABSENCE IS THE ASSERTION. The old shape computed the same sum in
    -- the `return`, once, off a chip row that had not been laid out yet.
    check(HEAD:find('chipRow:SetScript("OnSizeChanged", LayoutChips)', 1, true) == nil,
          "narrow: a re-wrap does more than re-wrap -- it does not stop at LayoutChips")
    local reflow = HEAD:match('chipRow:SetScript%("OnSizeChanged", function%(%)(.-)end%)')
    check(reflow ~= nil, "narrow: the chip row re-flows on resize")
    reflow = reflow or ""
    check(reflow:find("parent.dfSetHeight(Measure())", 1, true) ~= nil,
          "narrow: ...and re-reports the band's height through the shell's verb")
    check(SHELL:find("host.dfSetHeight = function", 1, true) ~= nil,
          "narrow: ...which the shell is what provides")

    -- ---- class two: the preset bar --------------------------------------
    -- New + Duplicate + Rename + Delete is 250px of labelled buttons; with the
    -- caption and the template dropdown that is 467, against a ~410px band. The
    -- Aura Designer's band already used the icon form.
    local BANNER = ROWS:match("banner = function%(parent%)(.-)\n        end,")
    check(BANNER ~= nil, "narrow: the row page's banner arm can be read")
    BANNER = BANNER or ""
    check(BANNER:find("iconButtons = true", 1, true) ~= nil,
          "narrow: the band's preset bar takes the compact icon actions")
    -- ...and the split panel, which still has the 850px the labels were chosen
    -- for, still gets them.
    local ISLAND = TD:match('GUI:CreateDesignerPresetBar%(page%.child, {(.-)\n        }%)')
    check(ISLAND ~= nil, "narrow: the split panel's own preset bar can be read")
    check((ISLAND or ""):find("iconButtons", 1, true) == nil,
          "narrow: ...and it is untouched -- it keeps the labelled actions")

    -- ---- class three: the section header ---------------------------------
    -- An element's title is a label the user typed, and it ran rightward under
    -- the eye and the delete coming the other way.
    check(SW:find("section.SetHeaderRightInset = function", 1, true) ~= nil,
          "narrow: a section header can be told what its right-hand furniture cost")
    check(ROWS:find("section:SetHeaderRightInset(56)", 1, true) ~= nil,
          "narrow: ...and an element's header declares its eye and delete")
end
