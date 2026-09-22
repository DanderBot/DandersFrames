local NS = ...

-- ============================================================
-- INTEGRATIONS PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Auras.lua
-- ------------------------------------------------------------
-- General > Integrations is the smallest card page: one real group, Color
-- Picker, which is one 280 box in classic and one of the Debuff Bar's
-- collapsible CARDS in modern -- no header tick, no pin. The See Also block and
-- the two removed-group notes are not settings groups and are untouched.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY -- it is welded to the panel -- so this
-- file does what the three page-builder suites before it do: it reads the page's
-- SOURCE and asserts against it.
--
-- ☠ AND THIS PAGE HAS ONE RULE OF ITS OWN, which is most of why it has a test:
-- its two settings live in the ACCOUNT-WIDE db, not in DF.db.party/raid. So the
-- card wires NEITHER an amber modified tick NOR a Reset Group / Hold: Defaults
-- footer -- both run through the per-mode defaults engine -- and its summary
-- reads the account-wide table rather than the per-mode one the page pass hands
-- a card's corner.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Auras.lua"):gsub("\r\n", "\n")

-- ---- the census reader (the Frame page's) ----------------------------
--
-- ⚠ IT TAKES THE DB TABLE'S NAME. Every other page binds its controls to the
-- page's own `db`; this one binds to `pickerDB`, and the reader's key match is
-- anchored on the table name, so a hardcoded "db" would report "(none)" for both
-- checkboxes and pin nothing.
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

-- The Integrations page, scoped by its own two ends. Auras.lua holds several
-- pages -- Sorting, Nicknames, Integrations, Colors and more -- and a bare 280
-- box on one of the others is not this pass's business.
local PAGE
do
    local a = SRC:find("-- General > Integrations", 1, true)
    local b = SRC:find("-- Display > Colors", 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Integrations page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED CARD HELPER, AND THE POPOUT FURNITURE IS GONE
-- ============================================================
print("-- Integrations page: the shared card helper")
do
    check(PAGE:find("local classicLayout = DF:IsClassicSettingsLayout()", 1, true) ~= nil,
          "tools: the page asks which layout it is building")
    check(PAGE:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true) ~= nil,
          "tools: ...and takes the shared machinery unconditionally")
    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "tools.PopoutContent(", "tools.ClaimKeys(",
                            "tools.WireModifiedTick(", "tools.WireFooter(",
                            "tools.RegisterHoistedToggle(", "colorPickerBand", "_COUNT",
                            "footerStrip", "inline = true", "popout = true," }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end
    check(PAGE:find("count%s*=%s*[%w_]") == nil, "counts: no card declares a settings count")
    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: the card goes through the shared helper, two per row with quiet captions")
    check(PAGE:find("local function CloseSection(band)\n            tools.CloseSection(Add, band)\n        end", 1, true) ~= nil,
          "sections: ...and closes through the shared helper too")
    local n = 0
    for _ in PAGE:gmatch('Add%(tools%.SectionControls%(self%.child%), 24, "both"%)') do n = n + 1 end
    eq(n, 1, "bulk: the page adds the Expand/Collapse pair once, above its card")
end

-- ============================================================
-- 2. COLOR PICKER -- four widgets, no toggle
-- Neither tick is the group's "am I doing anything": they are two INDEPENDENT
-- overrides -- this addon's colour pickers, and every other addon's -- and
-- either can be on without the other. So nothing is hoisted into the header.
-- ============================================================
local COLOR_PICKER = {
    { "checkbox", "Use DF Color Picker",                 "colorPickerOverride",       30 },
    { "label",    "Replace Blizzard's color picker with the DandersFrames color picker for this addon.", "(none)", 40 },
    { "checkbox", "Use DF Color Picker for All Addons",  "colorPickerGlobalOverride", 30 },
    { "label",    "Show the DF color picker when any addon opens a color picker.", "(none)", 30 },
}

print("-- Integrations page: Color Picker")
do
    local body = builderBody("BuildColorPickerGroup")
    checkCensus(census(body, "pickerDB"), COLOR_PICKER, "color picker")

    -- ONE builder, BOTH layouts: the declaration and the two mounts.
    local calls = 0
    for _ in PAGE:gmatch("BuildColorPickerGroup%(") do calls = calls + 1 end
    eq(calls, 3, "color picker: declared once, mounted twice -- classic box and card")

    -- The classic branch builds the box it always did, with its own header, in
    -- the column it always had.
    check(PAGE:find("local colorPickerGroup = GUI:CreateSettingsGroup(self.child, 280)", 1, true) ~= nil,
          "color picker: the classic 280 box is unchanged")
    check(PAGE:find('colorPickerGroup:AddWidget(GUI:CreateHeader(self.child, L["Color Picker"]), 40)', 1, true) ~= nil,
          "color picker: ...with its own header")
    check(PAGE:find("Add(colorPickerGroup, nil, 1)", 1, true) ~= nil,
          "color picker: ...still added to column 1")

    -- ⚠ THE ACCOUNT-WIDE TABLE IS READ ONCE AT PAGE SCOPE and closed over by the
    -- builder, so the classic box and every pane instance write the same table.
    check(PAGE:find("local pickerDB = DF:GetGlobalDB()", 1, true) ~= nil,
          "color picker: the account-wide table is resolved once, at page scope")

    local a = PAGE:find('OpenSection(L["Color Picker"]', 1, true)
    local b = a and PAGE:find("CloseSection(band)", a, true)
    local block = (a and b) and PAGE:sub(a, b):gsub("%s+", " ") or ""
    check(block:find('OpenSection(L["Color Picker"], "integrations_colorpicker", 1, ColorPickerSummary)', 1, true) ~= nil,
          "color picker: a card keyed integrations_colorpicker in column 1 -- no gates, no pin, no tick")
    check(block:find("BuildColorPickerGroup({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end, })", 1, true) ~= nil,
          "color picker: ...mounting the builder exactly as classic does")

    -- ☠ THE SUMMARY READS THE ACCOUNT-WIDE TABLE. The page pass hands a card's
    -- corner the per-mode table, which never holds these keys.
    local sum = PAGE:match("local function ColorPickerSummary%(%)(.-)\n            end")
    check(sum ~= nil, "color picker: the summary is a named function on the page, taking no table")
    if sum then
        check(sum:find("local g = DF:GetGlobalDB()", 1, true) ~= nil,
              "color picker: ...reading the account-wide table itself")
        check(sum:find('L%["All"%]') ~= nil,
              "color picker: ...naming the every-other-addon state from the locale")
        check(sum:find('return ""', 1, true) ~= nil,
              "color picker: ...and saying nothing when there is no existing word for the state")
    end
end

-- ============================================================
-- 3. THE ACCOUNT-WIDE RULE -- no tick and no footer
-- ============================================================
print("-- Integrations page: the account-wide rule")
do
    check(PAGE:find("tools.WireModifiedTick(", 1, true) == nil,
          "account-wide: no amber tick -- the defaults engine cannot answer for these keys")
    check(PAGE:find("tools.WireFooter(", 1, true) == nil,
          "account-wide: no Reset Group / Hold strip -- it would write per-mode defaults")
    check(PAGE:find("NO RESET STRIP, AS BEFORE", 1, true) ~= nil,
          "account-wide: ...and the reason is written down at the card")
end

-- ============================================================
-- 4. THE ORDER, AND WHAT WAS LEFT ALONE
-- ============================================================
print("-- Integrations page: the order and what was left alone")
do
    -- Exactly one bare 280 box left on the page, and it is the classic branch's.
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 1, "order: one bare 280 box left, and it is the classic branch's own")
    -- Nothing stays inline here, so the band skin is never reached for.
    check(PAGE:find("INLINE_BOX", 1, true) == nil,
          "order: no stay-inline box on this page, so no band skin either")

    -- ⚠ STILL NO COPY BUTTON, and the note saying why is still there. Both
    -- settings on this page are account-wide, so there is no per-mode value to
    -- copy to the other mode -- a copy button here would be a button that does
    -- nothing.
    check(PAGE:find("CreateCopyButton", 1, true) == nil,
          "page: no copy button -- both settings are account-wide, so there is nothing to copy")
    check(PAGE:find("No copy-to-other-mode button", 1, true) ~= nil,
          "page: ...and the note saying why survived the move")

    -- The See Also block is untouched.
    check(PAGE:find('{pageId = "auras_buffs", label = L["Buff Bar"]}', 1, true) ~= nil,
          "page: the See Also block still links the three aura pages")
end
