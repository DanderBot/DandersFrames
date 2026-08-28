local NS = ...

-- ============================================================
-- INTEGRATIONS PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Auras.lua
-- ------------------------------------------------------------
-- General > Integrations is the sweep's fourth page and its smallest: one real
-- group, Color Picker, which becomes a single toggle-less feature row in a
-- one-row band. The See Also block and the two removed-group notes are not
-- settings groups and are untouched.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY -- it is welded to the panel -- so this
-- file does what the three page-builder suites before it do: it reads the page's
-- SOURCE and asserts against it.
--
-- ☠ AND THIS PAGE HAS ONE RULE OF ITS OWN, which is most of why it has a test:
-- its two settings live in the ACCOUNT-WIDE db, not in DF.db.party/raid. The row
-- therefore claims its keys (for the search jump) but wires NEITHER the amber
-- modified tick NOR the Reset Group / Hold: Defaults footer -- both run through
-- DF.Defaults, which answers only for the per-mode tables. Section 3 below is
-- there so a later sweep "completing" the row breaks a test instead of writing
-- per-mode defaults into the wrong table.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Auras.lua")

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

-- The block a row is declared in, from its label to the closing brace of the
-- CreatePopoutRow opts.
local function rowOpts(labelKey)
    local a = PAGE:find('label%s*=%s*L%["' .. labelKey .. '"%]')
    check(a ~= nil, "source: a popout row is declared for " .. labelKey)
    if not a then return "" end
    local b = PAGE:find("}))", a, true)
    return PAGE:sub(a, (b or a) + 2)
end

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED MACHINERY
-- ============================================================
print("-- Integrations page: the shared popout machinery")
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
end

-- ============================================================
-- 2. COLOR PICKER -- four widgets, no toggle
-- Neither tick is the group's "am I doing anything": they are two INDEPENDENT
-- overrides -- this addon's colour pickers, and every other addon's -- and
-- either can be on without the other. So nothing is hoisted and the row is a
-- way in and nothing else.
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
    eq(calls, 3, "color picker: declared once, mounted twice -- classic box and popout pane")

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

    local opts = rowOpts("Color Picker")
    check(opts:find("toggle", 1, true) == nil,
          "color picker: the row declares no toggle -- two independent overrides have no shared on/off")
    check(opts:find("summary%s*=%s*ColorPickerSummary") ~= nil,
          "color picker: ...it does declare a summary")
    check(opts:find("count%s*=%s*COLOR_PICKER_COUNT") ~= nil,
          "color picker: ...and the declared count, not a literal")
    check(opts:find("build", 1, true) ~= nil, "color picker: the row is handed a pre-built mount")
    check(opts:find("window  = DF.GUIFrame", 1, true) ~= nil,
          "color picker: ...docked outside the settings window")
    check(opts:find("clipTo", 1, true) ~= nil,
          "color picker: ...and clipped by the page's own scroll frame")

    local declared = tonumber(PAGE:match("local COLOR_PICKER_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "color picker: the page declares the row's count in one place")
    eq(declared, #COLOR_PICKER, "color picker: ...the whole census, because nothing is hoisted")

    -- ☠ THE ROW'S db IS THE GLOBAL TABLE, NOT tools.RowDB. Every other row on the
    -- sweep hands the kit the per-mode table because that is where its keys live;
    -- these two do not, and a row pointed at the per-mode table would read nil
    -- for both and print a summary about settings it is not showing.
    check(opts:find("db      = function() return DF:GetGlobalDB() end", 1, true) ~= nil,
          "color picker: the row reads the account-wide table, not the per-mode one")
    -- The FIELD, not the words: the note at the site names tools.RowDB in prose
    -- to say what this row is deliberately not doing.
    check(opts:find("db%s*=%s*tools%.RowDB") == nil,
          "color picker: ...and never the per-mode one")

    -- The summary uses a word the locale already ships, for the one state worth
    -- a word, and says nothing otherwise rather than inventing a string.
    local sum = PAGE:match("local function ColorPickerSummary%(d%)(.-)\n            end")
    check(sum ~= nil, "color picker: the summary is a named function on the page")
    if sum then
        check(sum:find('L%["All"%]') ~= nil,
              "color picker: ...naming the every-other-addon state from the locale")
        check(sum:find('return ""', 1, true) ~= nil,
              "color picker: ...and saying nothing when there is no existing word for the state")
    end
end

-- ============================================================
-- 3. THE ACCOUNT-WIDE RULE -- claimed, but no tick and no footer
-- ☠ THIS SECTION IS THE POINT OF THE FILE. DF.Defaults answers for
-- DF.db.party / DF.db.raid / the stored raid baseline and nothing else, so on
-- this row the tick could never light and the footer would write PER-MODE
-- defaults for two keys that live in the account-wide table -- inventing
-- settings in the wrong place while the values the row is showing sat
-- untouched. A later sweep "completing" the row breaks these two checks.
-- ============================================================
print("-- Integrations page: the account-wide rule")
do
    check(PAGE:find("tools.ClaimKeys(pickerRow, pickerContent)", 1, true) ~= nil,
          "account-wide: the keys ARE claimed -- that is what feeds the search jump's row map")
    check(PAGE:find("tools.WireModifiedTick(pickerRow)", 1, true) == nil,
          "account-wide: no amber tick -- the defaults engine cannot answer for these keys")
    check(PAGE:find("tools.WireFooter(", 1, true) == nil,
          "account-wide: no Reset Group / Hold strip -- it would write per-mode defaults")
    -- ...and the reason is written down at the site, not just here.
    check(PAGE:find("DF.Defaults", 1, true) ~= nil,
          "account-wide: the row site names the engine that cannot answer for these keys")
end

-- ============================================================
-- 4. THE BAND, THE ORDER, AND WHAT WAS LEFT ALONE
-- ============================================================
print("-- Integrations page: the band, the order and what was left alone")
do
    check(PAGE:find("colorPickerBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
          "band: the band is chromeless, at the width the layout pass will give it")
    -- One row whose own label already says "Color Picker", so no header: the
    -- Sorting page's sortBand rule.
    check(PAGE:find("colorPickerBand:AddWidget(GUI:CreateHeader", 1, true) == nil,
          "band: ...and carries no header, because its one row's label already names it")
    check(PAGE:find('Add(colorPickerBand, nil, "both")', 1, true) ~= nil,
          "band: it spans both columns, where the 280 box used to take column 1")

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
