local NS = ...

-- ============================================================
-- TEXT DESIGNER PAGE BUILDERS
-- ------------------------------------------------------------
-- ⚠ 2026-09-26: the popout "rows" page (TextDesigner/UI/Rows.lua) and the
-- designer shell were deleted; the designer only builds its split panel. The
-- checks that pinned the rows page went with them; what is left pins the shared
-- section builders. The history below is kept for context.
--
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
-- 1. THE PAGE IS THE SPLIT PANEL
-- 2026-09-26: the rows page (TextDesigner/UI/Rows.lua) and the designer shell
-- were deleted; the designer builds its split panel in both settings layouts.
-- ============================================================
print("-- Text Designer: the page is the split panel")
do
    check(AURAS:find("DF.BuildTextDesignerPage(GUI, self, db, Add, AddSpace)", 1, true) ~= nil,
          "harness: the page registration passes Add and AddSpace through")
    check(TD:find("function DF.BuildTextDesignerPage(GUI, page, db, Add, AddSpace)", 1, true) ~= nil,
          "harness: ...and the entry point takes them")
    check(TD:find("BuildTextDesignerRowsPage", 1, true) == nil,
          "harness: the designer has no rows arm")
    check(TD:find("return BuildTextDesignerIsland(GUI, page, db)", 1, true) ~= nil,
          "harness: ...and builds the split panel")
    check(TOC:find("TextDesigner\\UI\\Rows.lua", 1, true) == nil,
          "toc: the row page is gone from the companion's manifest")
end

-- ============================================================
-- 3. THE SECTION BUILDERS
-- ============================================================
print("-- Text Designer: the section builders")
do
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
-- 6. THE RECORD AND THE CARD'S FOLD KEY
-- ============================================================
print("-- Text Designer: the element record and the card's fold key")
do
    check(TD:find("if TD_OVERRIDABLE[k] then\n                elem.overrides = elem.overrides or {}", 1, true) ~= nil,
          "wiring: the record's own __newindex marks an override")
    check(TD:find('local cardKey = "td_elem_" .. tostring(elem.id)', 1, true) ~= nil,
          "expand: the card folds under a key built from the element's id")
end

-- ============================================================
-- 8. THE CANVAS IS THE AURA DESIGNER'S -- DECISION 4
-- One description of the frame's anatomy, not two. Which needs three things the
-- canvas previously assumed about its host.
-- ============================================================
print("-- Text Designer: the shared canvas")
do
    check(TD:find("local previewNote = previewPanel:CreateFontString", 1, true) ~= nil,
          "canvas: ...while the split panel still draws its own, which is classic's")

    for _, opt in ipairs({ "compact   = true,", "scaleDB   = tdDB,",
                           "placement = false,", "unitText  = false," }) do
    end

    -- ☠ WHY EACH OF THE THREE EXISTS, pinned against the canvas itself.
    -- scaleDB: the two designers keep previewScale in DIFFERENT tables, and
    -- without it the Text Designer's slider would write the Aura Designer's key.
    check(CARDS:find("local scaleDB = (opts and opts.scaleDB) or adDB", 1, true) ~= nil,
          "canvas: scaleDB defaults to the Aura Designer's own config")
    check(CARDS:find('GUI:CreateSlider(container, L["Preview Scale"], 0.75, 2.5, 0.05, scaleDB, "previewScale",', 1, true) ~= nil,
          "canvas: ...and the split panel's inline slider binds to it, not to a fixed table")
    -- ☠ THE BAND'S SLIDER IS IN A POOLED PANEL and cannot capture the table at
    -- all -- see the Aura Designer's census. What it captures is the KEY, and the
    -- live canvas registers scaleDB behind it.
    check(CARDS:find("scaleHosts[popKey] = { db = scaleDB, apply = ApplyPreviewScale }", 1, true) ~= nil,
          "canvas: ...and the band's glyph panel reaches it through the live registration")
    check(CARDS:find("function P.CanvasWantedHeight(compact, scaleDB)", 1, true) ~= nil,
          "canvas: ...as does the band-height verb, which must read the same number")

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


end

-- ============================================================
-- 9. THE FURNITURE THAT HAS NOT CONVERTED YET STILL RENDERS
-- The add flow is phase 5. Until then the page has to be fully usable, so the
-- CTA, the caption and the filter chips render exactly what they rendered inside
-- the split panel -- as one full-width object in the band column.
-- ============================================================
print("-- Text Designer: the add flow, one definition and two hosts")
do
    check(TD:find("local function BuildTextsHeadArea(GUI, parent, state, tdDB, page)", 1, true) ~= nil,
          "legacy: the Texts head area is declared once")
    check(TD:find("local function BuildGroupsHeadArea(GUI, parent, state, tdDB, page)", 1, true) ~= nil,
          "legacy: ...and so is the Text Groups one")
    check(TD:find("BuildTextsHeadArea(GUI, parent, state, tdDB, page)\n", 1, true) ~= nil,
          "legacy: the split panel's Texts tab mounts it")
    check(TD:find('addBtn:SetPoint("RIGHT", parent, "RIGHT", -RIGHT_INSET, 0)', 1, true) ~= nil,
          "legacy: ...which is the whole of the difference between the two hosts")
    -- The rows layout's redraw branch went with it (2026-09-26).
    check(TD:find("rowsMode", 1, true) == nil,
          "legacy: no redraw verb branches on a rows layout any more")
end

-- ============================================================
-- 9a. THE CATEGORY FILTER CHIPS
-- A wrapping chip row under the TEXT ELEMENTS caption. (The rows page reached the
-- same chips through a glyph and a pooled popout; both went with it on
-- 2026-09-26.)
-- ============================================================
print("-- Text Designer: the category filter chips")
do
    check(TD:find("local function BuildTextFilterChips(GUI, host, state, width, page, tdDB)", 1, true) ~= nil,
          "tdfilter: the chips are declared once")
    check(TD:find("local function TextFilterChips()", 1, true) ~= nil,
          "tdfilter: ...from one list of the categories")
    -- ⚠ A FUNCTION, not a file-scope table: a table of L[...] lookups built at
    -- load freezes on whatever locale was live then, which is the very reason
    -- CONTENT_CATEGORY_LABELS is rebuilt through DF:RegisterLocaleRefresh.
    check(TD:find("local TEXT_FILTER_CHIPS = {", 1, true) == nil,
          "tdfilter: ...which is a verb, so it cannot freeze on the load-time locale")
    -- The glyph, its pooled panel and its label helper are gone.
    check(TD:find("OpenTextFilterPopout", 1, true) == nil
          and TD:find("ActiveTextFilterLabel", 1, true) == nil
          and TD:find("TD_FILTER_", 1, true) == nil,
          "tdfilter: the rows page's glyph and panel went with it")
    check(TD:find("opts.skipChips", 1, true) == nil and TD:find("opts.filterGlyph", 1, true) == nil,
          "tdfilter: ...and so did the head area's opt-outs")

    -- The re-sync verb stays: the add flow resets the filter to All and has to
    -- repaint the chip row it did not click.
    local CHIPS = TD:match("local function BuildTextFilterChips.-\nend\nP%.BuildTextFilterChips")
    check(CHIPS ~= nil, "tdfilter: the chip builder can be read")
    CHIPS = CHIPS or ""
    check(CHIPS:find("return LayoutChips, SyncActive", 1, true) ~= nil,
          "tdfilter: the builder hands back the re-flow and the re-sync verbs")
    check(TD:find("state.ApplyChipState = SyncActive", 1, true) ~= nil,
          "tdfilter: ...and the split panel keeps the re-sync")
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
    -- ☠ THE FLOW MOVED, THE RULE DID NOT. The chips are one declaration with two
    -- hosts now (this row and the filter glyph's pane), so the head area's job is
    -- to HAND DOWN the column it derived; the fallback lives with the flow. Told
    -- its width, not asked for it -- reading it off the child is what made the
    -- chips wrap at a hardcoded 260.
    check(HEAD:find("BuildTextFilterChips(GUI, chipRow, state, COL_W, page, tdDB)", 1, true) ~= nil,
          "narrow: the chips wrap to that column, not to a hardcoded 260")
    local CHIPS = TD:match("local function BuildTextFilterChips.-\nend\nP%.BuildTextFilterChips")
    check(CHIPS ~= nil, "narrow: the shared chip builder can be read")
    check((CHIPS or ""):find("if maxW <= 0 then maxW = width or 260 end", 1, true) ~= nil,
          "narrow: ...and falls back only when it was told nothing at all")
    check(HEAD:find("local function Measure()", 1, true) ~= nil,
          "narrow: the head area's height is a verb, so it can be asked twice")
    -- (X) THE ABSENCE IS THE ASSERTION. The old shape computed the same sum in
    -- the `return`, once, off a chip row that had not been laid out yet.
    check(HEAD:find('chipRow:SetScript("OnSizeChanged", LayoutChips)', 1, true) == nil,
          "narrow: a re-wrap does more than re-wrap -- it does not stop at LayoutChips")
    local reflow = HEAD:match('chipRow:SetScript%("OnSizeChanged", function%(%)(.-)end%)')
    check(reflow ~= nil, "narrow: the chip row re-flows on resize")
    reflow = reflow or ""

    -- ---- class two: the preset bar --------------------------------------
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
end

-- ============================================================
-- 13. THE CHROME DIET, WHERE IT MAPS  (spec section 18)
-- ------------------------------------------------------------
-- Of the four moves, two apply to this page unchanged -- it shares the canvas
-- through those three opts -- and one applies in part:
--
--   2. Preview Scale behind a glyph: shared, but the panel is POOLED BY KEY, so
--      this page must name its own or it gets the one already bound to the Aura
--      Designer's preview scale.
--   3. the preset bar's four actions behind one menu: applies. The row merge does
--      not -- there is no spec picker on this page to merge with.
--   4. the canvas folds: shared, under a key of this page's own.
--
-- Move 1 does NOT map. This page's add flow is already one 32px CTA opening a
-- floating picker, not a 230px block of standing cards -- there is nothing to
-- reclaim, and converting it would trade a working flow for a re-implemented one.
-- ============================================================
print("-- Text Designer: the chrome diet, where it maps")
do
    local SW = options_file_source("GUI/SettingsWidgets.lua")

    check(CARDS:find('local popKey = (opts and opts.scaleKey) or "df.previewscale.aura"', 1, true) ~= nil,
          "diet: ...and the canvas takes the key from its host")

    -- ---- move 3: the four actions behind one menu -----------------------
    check(SW:find("if opts.overflowActions then", 1, true) ~= nil,
          "diet: ...which is the shared bar's own option, not a copy here")
    -- ...and the split panel, which has the 850px the labels were chosen for, is
    -- untouched: it asks for neither the icons nor the menu.
    local ISLAND = TD:match('GUI:CreateDesignerPresetBar%(page%.child, {(.-)\n        }%)')
    check(ISLAND ~= nil, "diet: the split panel's own preset bar can be read")
    check((ISLAND or ""):find("overflowActions", 1, true) == nil,
          "diet: ...and keeps its four labelled buttons")


    -- ---- move 1 does not map, and the CTA is still there ----------------
    check(TD:find('text = L["Add Text Element"]', 1, true) ~= nil,
          "diet: the add CTA is untouched -- it was never the 230px block")
end

-- ============================================================
-- THE TABS SAY HOW MUCH THEY HOLD, IN BOTH LAYOUTS
-- ------------------------------------------------------------
-- ☠ REPORTED AS "Tabs (Texts, Text Groups) don't show the numbers of existing
-- elements, compared to the classic layout that do shows them". Which tab holds
-- the default current/max health is not obvious from its name; the split panel
-- answered that with a count on the tab and the row layout shipped without one,
-- because the conversion nilled the verb that painted it.
--
-- ONE piece of arithmetic, read by both strips: two copies is two tabs that can
-- disagree about the same profile.
-- ============================================================
print("-- Text Designer: the tabs say how much they hold")
do
    check(TD:find("local function TabElementCounts(countDB)", 1, true) ~= nil,
          "tabcount: the bucketing is declared once")
    check(TD:find("local counts = TabElementCounts(countDB or tdDB)", 1, true) ~= nil,
          "tabcount: the classic strip reads that one copy rather than its own loop")
    local _, n = TD:gsub("local counts = { texts = 0, groups = 0 }", "")
    eq(n, 1, "tabcount: and the loop it used to inline is gone from the classic arm")
end
