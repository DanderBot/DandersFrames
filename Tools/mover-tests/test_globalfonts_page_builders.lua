local NS = ...

-- ============================================================
-- GLOBAL FONTS PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Frames.lua
-- ------------------------------------------------------------
-- General > Global Fonts is the sweep's fifth page. Its two REAL groups become
-- popout feature rows -- Global Font Settings, Shadow Settings -- and Affected
-- Elements stays inline wearing the band skin, because it holds a header, a
-- twelve-line reference list and a caution note and ZERO controls: a row buys a
-- page space by folding CONTROLS away behind a click, and folding away the list
-- a user reads while deciding whether to press Apply to All buys nothing.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db -- so this file
-- does what the four page-builder suites before it do: it reads the page's
-- SOURCE and asserts against it.
--
-- ☠ AND THIS PAGE HAS TWO RULES OF ITS OWN, which is most of why it has a test:
--
--   1. THE APPLY BUTTON IS A WIZARD, NOT A SETTING. It is hand-built (no shared
--      helper covers "write ~30 per-mode font keys plus the Aura Designer and
--      Text Designer configs in one press"), so the census reader below CANNOT
--      SEE IT -- there is no GUI:Create* call to find. Section 2 asserts it by
--      source pattern instead, including four distinctive lines of its OnClick
--      body, so a "tidy-up" that rewrote any of those writes breaks a test
--      instead of quietly changing what a button press does to a profile.
--
--   2. NOT ONE OF THE FONT SELECTION ROW'S KEYS IS A PER-MODE SETTING. The font
--      and outline dropdowns and the shadow tick are bound to DF.GlobalFontTemp
--      -- a session scratch table -- and the SDF tick to the DF.db ROOT. So that
--      row claims its keys (for the search jump) and wires NEITHER the amber
--      modified tick NOR the Reset Group / Hold: Defaults footer, exactly as the
--      Integrations row does and for the same reason. Section 4 is there so a
--      later sweep "completing" the row breaks a test instead of stamping
--      per-mode defaults for keys that live somewhere else.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each extracted builder -- kind, L key, qualified db
--     key and slot height, in order -- taken from the PRE-CHANGE source, so a
--     builder that quietly dropped a control or renamed a key fails here. This
--     is also the evidence that CLASSIC RENDERS AS IT DID: the classic branch
--     mounts the same builder into the same 280 box in the same column.
--   ✓ that ONE builder serves both layouts.
--   ✓ that the declared row COUNT matches what the pane mounts.
--   ✗ nothing about runtime behaviour -- the callbacks, the greying and the
--     summary are read by eye and by the in-game checklist.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Frames.lua")

-- ---- the census reader (the Group Labels page's, with CreateNote added) ----
--
-- ⚠ THE FONT TRIO IS IN THE MAP, as it is in the Group Labels copy: a chunk runs
-- to the start of the next KNOWN call, so an unknown factory is invisible rather
-- than merely unnamed, and a reader missing CreateFontDropdown /
-- CreateOutlineDropdown / CreateShadowCheckbox would fold three of this page's
-- controls into their neighbours. CreateNote joins them for the Affected
-- Elements box, whose third widget is one.
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateFontDropdown = "fontdropdown", CreateOutlineDropdown = "outlinedropdown",
    CreateShadowCheckbox = "shadowcheckbox", CreateNote = "note",
}

-- The body of a `local function <name>(tools2)` at the page builder's own
-- indent. Terminated on a newline + EIGHT spaces + `end`, which is that indent:
-- everything inside one of these bodies is indented further -- the Apply
-- button's OnClick included, which is why its closing `end)` at twelve spaces
-- cannot end this search early.
local function builderBody(name)
    local head = "local function " .. name .. "(tools2)"
    local a = SRC:find(head, 1, true)
    check(a ~= nil, "source: the page declares " .. name)
    if not a then return "" end
    local b = SRC:find("\n        end\n", a, true)
    check(b ~= nil and b > a, "source: ..." .. name .. " closes at the page builder's indent")
    return SRC:sub(a, b or a)
end

-- ⚠ THE KEY COLUMN IS QUALIFIED -- "<table>.<key>", not the bare key. Every
-- earlier page in the sweep bound every control to one table and could anchor
-- the match on its name; this page binds to THREE (DF.GlobalFontTemp, DF.db and
-- the page's own per-mode db) and WHICH table a control writes is the whole
-- point of section 4. A reader that printed only the key would call the font
-- dropdown's binding "font" and say nothing about where that lives.
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
        local tbl, k = chunk:match('([%w_%.]+)%s*,%s*"([%w_]+)"')
        local h     = tonumber(chunk:match('%)%s*,%s*(%d+)%s*%)'))
        out[#out + 1] = { kind = at.kind, label = label,
                          key = (tbl and (tbl .. "." .. k)) or "(none)", height = h }
    end
    return out
end

-- "(any)" in the expected label is an explicit pass, used once: the Affected
-- Elements list is a twelve-line bullet string whose exact bytes are pinned by
-- its own check below rather than by retyping it here.
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
            if e[2] ~= "(any)" then
                eq(g.label, e[2], string.format("%s: row %d label", tag, i))
            end
            eq(g.key,    e[3], string.format("%s: row %d db key", tag, i))
            eq(g.height, e[4], string.format("%s: row %d slot height", tag, i))
        end
    end
end

-- The Global Fonts page, scoped by its own two ends: Frames.lua holds several
-- pages, and a bare 280 box (or a `label = L["Font Settings"]`) on Group Labels
-- below is not this pass's business. Everything about THIS page reads PAGE
-- rather than SRC for exactly that reason.
local PAGE
do
    local a = SRC:find('Add(CreateCopyButton(self.child, {"fontShadow"}', 1, true)
    local b = SRC:find("-- General > Group Labels", 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Global Fonts page builder is locatable by its own ends")
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

-- What every converted group on this page has in common.
local function checkShared(builder, rowLabel)
    -- ONE builder, BOTH layouts: the declaration and the two mounts.
    local calls = 0
    for _ in PAGE:gmatch(builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, rowLabel .. ": declared once, mounted twice -- classic box and popout pane")

    -- The classic branch builds the box it always did, with its own header.
    local box = PAGE:match("local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)\n%s*%1:AddWidget%(GUI:CreateHeader%(self%.child, L%[\"" .. rowLabel:gsub("%p", "%%%0") .. "\"%]%)")
    check(box ~= nil, rowLabel .. ": the classic 280 box is built with its own header")

    local opts = rowOpts(rowLabel)
    check(opts ~= "" and opts:find("build", 1, true) ~= nil,
          rowLabel .. ": the row is handed a pre-built mount")
    check(opts:find("window  = DF.GUIFrame", 1, true) ~= nil,
          rowLabel .. ": ...docked outside the settings window")
    check(opts:find("clipTo", 1, true) ~= nil,
          rowLabel .. ": ...and clipped by the page's own scroll frame, not the window")
    check(opts:find("db      = tools.RowDB", 1, true) ~= nil,
          rowLabel .. ": ...reading the per-mode table through the shared resolver")
end

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED MACHINERY
-- Same contract the three pages before it signed: the verbs come off
-- GUI:CreatePopoutPageTools rather than out of a fifth copy on the page.
-- ============================================================
print("-- Global Fonts page: the shared popout machinery, not a fifth copy of it")
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

    -- ☠ THE SESSION SCRATCH TABLE IS SEEDED AT PAGE SCOPE, BEFORE THE BUILDERS,
    -- and it must stay there. It is seeded FROM THE PROFILE, so moving it inside
    -- a builder would move WHEN it runs -- once per pane instance in the popout
    -- layout, and not at all on a build where the user never opens the row.
    local seed = PAGE:find("if not DF.GlobalFontTemp then", 1, true)
    local firstBuilder = PAGE:find("local function BuildFontSelectionGroup(tools2)", 1, true)
    check(seed ~= nil and firstBuilder ~= nil and seed < firstBuilder,
          "seed: DF.GlobalFontTemp is seeded at page scope, ahead of the builders")
    check(PAGE:find('font = db.nameFont or "Fonts\\\\FRIZQT__.TTF",', 1, true) ~= nil,
          "seed: ...from the same two keys it always read")
    check(PAGE:find('outline = db.nameTextOutline or "OUTLINE",', 1, true) ~= nil,
          "seed: ...both of them")

    -- The two shadow applies stay at PAGE scope as well: the classic box and
    -- every pane instance have to drive the same work, and neither closes over
    -- anything group-specific.
    local apply = PAGE:find("local function UpdateShadowSettings()", 1, true)
    check(apply ~= nil and firstBuilder ~= nil and apply < firstBuilder,
          "applies: UpdateShadowSettings is a page-scope local, shared by both layouts")
    check(PAGE:find("local function LightweightShadowUpdate()", 1, true) ~= nil,
          "applies: ...and so is the drag-time lightweight one")
end

-- ============================================================
-- 2. GLOBAL FONT SETTINGS -- six widgets the census can see, plus the wizard
-- ⚠ THE APPLY BUTTON IS NOT IN THIS TABLE and cannot be: it is a hand-built
-- Button, not a GUI:Create* call, so the reader has nothing to find. It is
-- asserted by source pattern immediately below, and the row's declared count is
-- checked against this census PLUS ONE for exactly that reason.
-- ============================================================
local FONT_SELECTION = {
    { "label",           "Set a font and outline style, then click Apply to update ALL text elements.", "(none)", 40 },
    { "fontdropdown",    "Font",    "DF.GlobalFontTemp.font",    55 },
    { "outlinedropdown", "Outline", "DF.GlobalFontTemp.outline", 55 },
    { "shadowcheckbox",  "Shadow",  "DF.GlobalFontTemp.outline", 30 },
    { "checkbox",        "Crisp Font Rendering (SDF)", "DF.db.fontSlug", 30 },
    { "label",           "Renders text with signed-distance-field smoothing for sharper edges at any size. Applies to None and Outline styles only (not Monochrome, Thick, or Shadow).", "(none)", 50 },
}

print("-- Global Fonts page: Global Font Settings")
do
    local body = builderBody("BuildFontSelectionGroup")
    checkCensus(census(body), FONT_SELECTION, "global font settings")
    checkShared("BuildFontSelectionGroup", "Global Font Settings")

    -- ⚠ TWO CONTROLS, ONE KEY -- and unlike the Group Labels page's pair, this
    -- one is a field of the SESSION SCRATCH table. The outline dropdown and the
    -- shadow tick are two views of one value, so the census names it twice.
    eq(FONT_SELECTION[3][3], FONT_SELECTION[4][3],
       "global font settings: the outline dropdown and the shadow tick share one stored key")

    -- ---- the hand-built wizard button ---------------------------------
    check(body:find('local applyBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")', 1, true) ~= nil,
          "apply: the button is built into the BUILDER's parent, not the page's child")
    check(body:find('GUI:StyleButton(applyBtn, { width = 120, height = 28, text = L["Apply to All"] })', 1, true) ~= nil,
          "apply: ...still themed through the shared button styler")
    check(body:find("group:AddWidget(applyBtn, 35)", 1, true) ~= nil,
          "apply: ...and added to the group at the slot height it always had")

    -- ☠ FOUR DISTINCTIVE LINES OF THE OnClick BODY, still inside the builder.
    -- This press writes ~30 per-mode font keys plus the Aura Designer and Text
    -- Designer configs; a layout pass is not allowed to change any of that, and
    -- each of these four is a fix that was earned the hard way (the AFK timer
    -- override, the spec-keyed instance walk, the nil-hole in the legacy
    -- per-type tables, the user-facing confirmation).
    for _, line in ipairs({
        "db.afkIconTimerFont = nil; db.afkIconTimerOutline = nil",
        "local function _clearAuraRecord(rec)",
        'for _, tk in pairs({ "icon", "square", "bar" }) do',
        "_tdCfg.globalDefaults.font = font",
        'DF:Say("Applied global font settings to all text elements.")',
    }) do
        check(body:find(line, 1, true) ~= nil,
              "apply: the OnClick body still carries `" .. line .. "`")
    end
    -- ...and the SHAPE of the write, counted rather than read: every assignment
    -- of the chosen font and outline. A press that started writing one more key
    -- (or one fewer) is a settings change, and it lands here.
    local fontWrites, outlineWrites = 0, 0
    for _ in body:gmatch("= font%f[%W]") do fontWrites = fontWrites + 1 end
    for _ in body:gmatch("= outline%f[%W]") do outlineWrites = outlineWrites + 1 end
    eq(fontWrites, 20, "apply: the press writes the chosen font in twenty places")
    eq(outlineWrites, 20, "apply: ...and the outline beside each one")

    -- ---- the row ------------------------------------------------------
    local declared = tonumber(PAGE:match("local FONT_SELECTION_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "global font settings: the page declares the row's count in one place")
    eq(declared, #FONT_SELECTION + 1,
       "global font settings: ...the census plus the Apply button the census cannot see")

    local opts = rowOpts("Global Font Settings")
    check(opts:find("toggle", 1, true) == nil,
          "global font settings: the row declares no toggle -- there is no on/off in here")
    check(opts:find("count%s*=%s*FONT_SELECTION_COUNT") ~= nil,
          "global font settings: ...it does declare the count, and not as a literal")
    -- ☠ NO SUMMARY, and that is the honest answer rather than a gap: the two
    -- dropdowns show a SELECTION the user may never have pressed Apply on, and
    -- the page's real fonts are per-element and set on a dozen other pages.
    check(opts:find("summary", 1, true) == nil,
          "global font settings: ...and NO summary -- nothing behind this row is applied state")
end

-- ============================================================
-- 3. SHADOW SETTINGS -- four widgets, no toggle
-- ============================================================
local SHADOW_SETTINGS = {
    { "label",       "These settings apply when using 'Shadow' outline style. Use larger offsets for more dramatic shadows.", "(none)", 40 },
    { "slider",      "Shadow X Offset", "db.fontShadowOffsetX", 50 },
    { "slider",      "Shadow Y Offset", "db.fontShadowOffsetY", 50 },
    { "colorpicker", "Shadow Color",    "db.fontShadowColor",   40 },
}

print("-- Global Fonts page: Shadow Settings")
do
    local body = builderBody("BuildShadowSettingsGroup")
    checkCensus(census(body), SHADOW_SETTINGS, "shadow settings")
    checkShared("BuildShadowSettingsGroup", "Shadow Settings")

    -- The two applies are REFERENCED from inside the builder and DECLARED
    -- outside it (section 1), which is what lets one builder serve both layouts.
    check(body:find("UpdateShadowSettings, LightweightShadowUpdate", 1, true) ~= nil,
          "shadow settings: the sliders keep their full apply and their drag-time one")
    check(body:find("local function UpdateShadowSettings", 1, true) == nil,
          "shadow settings: ...and neither is re-declared inside the builder")

    local declared = tonumber(PAGE:match("local SHADOW_SETTINGS_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "shadow settings: the page declares the row's count in one place")
    eq(declared, #SHADOW_SETTINGS,
       "shadow settings: ...the whole census, because nothing is hoisted")

    local opts = rowOpts("Shadow Settings")
    check(opts:find("toggle", 1, true) == nil, "shadow settings: the row declares no toggle")
    check(opts:find("summary%s*=%s*ShadowSettingsSummary") ~= nil,
          "shadow settings: ...it does declare a summary")
    check(opts:find("count%s*=%s*SHADOW_SETTINGS_COUNT") ~= nil,
          "shadow settings: ...and the declared count, not a literal")

    check(PAGE:find("tools.ClaimKeys(shadowRow, shadowContent)", 1, true) ~= nil,
          "shadow settings: the row claims whatever the pane registered")

    -- ☠ AND THAT ONE LINE IS ALSO THIS PAGE'S ONLY SECTION ANCHOR. Every
    -- per-element "Shadow" checkbox in the addon sits under a link built by
    -- UI:CreateGlobalFontsShadowLink, which jumps here by SECTION NAME -- and
    -- that jump is Search:ScrollToSection, which finds a section by asking every
    -- page child, and every settings-group child, for :GetText(). In classic the
    -- box's own HEADER answers. In this layout no header is built at all: the
    -- row's name is a FontString INSIDE the row, which the walk never reaches, so
    -- the link scrolled nowhere and flashed nothing -- a DebugWarn, and a dead
    -- cross-link the user just sees do nothing.
    --
    -- ClaimKeys is what puts the answer back: it stamps every row it is handed
    -- with a GetText returning that row's own label (GUI/Controls.lua, and
    -- test_popout_page_tools drives it). So the three facts below have to agree,
    -- and all three are READ rather than retyped -- the link's target comes out
    -- of the kit's source, the row's label out of the page's, and the mechanism
    -- out of the helper's. Any one of them moving on its own fails here instead
    -- of going quiet in game.
    do
        local KIT  = ui_file_source("Sections.lua")
        local link = KIT:match("function UI:CreateGlobalFontsShadowLink%(parent, width%)(.-)\nend")
        check(link ~= nil, "shadow link: the kit declares CreateGlobalFontsShadowLink")
        if link then
            check(link:find('page    = "general_fonts",', 1, true) ~= nil,
                  "shadow link: ...aimed at this page")
            local target = link:match('section = L%["([^"]+)"%]')
            eq(target, "Shadow Settings",
               "shadow link: ...and at this row's own label, which is the anchor it needs")
        end

        local CTRL  = options_file_source("GUI/Controls.lua")
        local claim = CTRL:match("local function ClaimKeys%(row, group, extra%)(.-)\n    end")
        check(claim ~= nil and claim:find("AnchorRow(row)", 1, true) ~= nil,
              "shadow link: the shared key claim anchors every row it is handed")
        check(CTRL:find("row.GetText = function() return name end", 1, true) ~= nil,
              "shadow link: ...with a GetText answering the row's own label")
    end
    check(PAGE:find("tools.WireModifiedTick(shadowRow)", 1, true) ~= nil,
          "shadow settings: ...its amber tick asks about exactly those keys")
    check(PAGE:find("tools.WireFooter(shadowRow, UpdateShadowSettings)", 1, true) ~= nil,
          "shadow settings: ...and Reset Group / Hold: Defaults drive the group's own apply")

    -- ⚠ NO GATES ON THIS ROW, which mirrors classic exactly: the box had none
    -- either. The offsets are read by whichever elements use the Shadow outline
    -- style, and this page cannot know which those are.
    check(PAGE:find("shadowRow.hideOn", 1, true) == nil,
          "shadow settings: the row carries no hideOn, as the box carried none")
    check(PAGE:find("shadowRow.disableOn", 1, true) == nil,
          "shadow settings: ...and no disableOn either")

    -- The summary prints the offset pair and only when it is not 0,0 -- the
    -- Border Shadow row's own convention -- but at THIS page's resolution.
    local sum = PAGE:match("local function ShadowSettingsSummary%(d%)(.-)\n            end")
    check(sum ~= nil, "shadow settings: the summary is a named function on the page")
    if sum then
        check(sum:find("if ox ~= 0 or oy ~= 0 then", 1, true) ~= nil,
              "shadow settings: ...the offsets print only when they are not both zero")
        -- ☠ %g, NOT %d. These sliders step in HALVES, so the Border Shadow row's
        -- math.floor would print "0, 0" for a real half-pixel offset -- a summary
        -- saying the opposite of the state it reports.
        check(sum:find('format("%g, %g", ox, oy)', 1, true) ~= nil,
              "shadow settings: ...as one pair, at half-pixel resolution")
        check(sum:find("math.floor", 1, true) == nil,
              "shadow settings: ...never floored, which would swallow a half-pixel offset")
        check(sum:find("\\194\\183", 1, true) ~= nil,
              "shadow settings: ...joined by the convention's dot")
        local items = 0
        for _ in sum:gmatch("parts%[#parts %+ 1%]") do items = items + 1 end
        check(items <= 4, "shadow settings: at most four items reach the string at once")
    end
end

-- ============================================================
-- 4. THE WIZARD ROW'S RULE -- claimed, but no tick and no footer
-- ☠ THIS SECTION IS HALF THE POINT OF THE FILE. DF.Defaults answers for
-- DF.db.party / DF.db.raid / the stored raid baseline and nothing else, and not
-- one of this row's three keys lives there: "font" and "outline" are fields of
-- DF.GlobalFontTemp (a session scratch table) and fontSlug is at the DF.db ROOT.
-- So the tick could never light, and the footer would stamp PER-MODE defaults
-- for keys that live elsewhere while the values the row is showing sat
-- untouched. A later sweep "completing" the row breaks these checks.
-- ============================================================
print("-- Global Fonts page: the wizard row's rule")
do
    check(PAGE:find("tools.ClaimKeys(fontRow, fontContent)", 1, true) ~= nil,
          "wizard row: the keys ARE claimed -- that is what feeds the search jump's row map")
    check(PAGE:find("tools.WireModifiedTick(fontRow)", 1, true) == nil,
          "wizard row: no amber tick -- the defaults engine cannot answer for these keys")
    check(PAGE:find("tools.WireFooter(fontRow", 1, true) == nil,
          "wizard row: no Reset Group / Hold strip -- it would write per-mode defaults")
    -- ...and the reason is written down at the site, not just here.
    check(PAGE:find("DF.Defaults", 1, true) ~= nil,
          "wizard row: the row site names the engine that cannot answer for these keys")
    check(PAGE:find("DF.GlobalFontTemp", 1, true) ~= nil,
          "wizard row: ...and the scratch table the three selectors are bound to")

    -- Nothing is hoisted off this row, so nothing needs re-registering with
    -- search either -- the claim above is the whole search repair here.
    check(PAGE:find("RegisterHoistedToggle", 1, true) == nil,
          "wizard row: no toggle is hoisted on this page, so none is re-registered")
end

-- ============================================================
-- 5. WHAT STAYED INLINE, THE BAND, AND THE PAGE'S OWN ORDER
-- ============================================================
local INFO_GROUP = {
    { "header", "Affected Elements", "(none)",  40 },
    { "label",  "(any)",             "(none)", 235 },
    { "note",   "Font sizes are not changed. Adjust sizes in each element's page.", "(none)", 40 },
}

print("-- Global Fonts page: the stay-inline box, the band and the page's own order")
do
    -- ---- the skin, at the one stay-inline site and nowhere else ------
    local sites = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280, tools and tools%.INLINE_BOX or nil%)") do
        sites = sites + 1
    end
    eq(sites, 1, "inline: exactly one group stays inline and wears the band skin")
    check(PAGE:find("local infoGroup = GUI:CreateSettingsGroup(self.child, 280, tools and tools.INLINE_BOX or nil)", 1, true) ~= nil,
          "inline: ...and it is Affected Elements")
    -- ⚠ THE FLAG IS NEVER WRITTEN AS A LITERAL ON THIS PAGE. One shared table off
    -- the tools, so classic gets nil -- which is what "no opts" already meant.
    check(PAGE:find("bandStyle", 1, true) == nil,
          "inline: the skin is taken from the tools, never restated as a literal")

    -- The box's own three widgets are unchanged, and it is the one group on the
    -- page with ZERO controls -- which is the whole argument for leaving it out
    -- in the open where it can be read.
    -- ⚠ BOUNDED AT THE NOTE'S OWN CLOSING `, 40)`, not at the box's Add. The
    -- census reads the LAST `<table>, "<key>"` pair it can see in a chunk, and
    -- the final widget's chunk runs to the end of whatever it is handed -- so a
    -- slice reaching as far as `Add(fontBand, nil, "both")` would report the
    -- caution note as bound to a key called "both".
    local infoBody
    do
        local a = PAGE:find("local infoGroup = GUI:CreateSettingsGroup", 1, true)
        local b = PAGE:find('prefix = "Note", width = 250}), 40)', 1, true)
        check(a ~= nil and b ~= nil and b > a, "inline: the Affected Elements box is locatable")
        infoBody = PAGE:sub(a or 1, (b or 1) + 34)
    end
    checkCensus(census(infoBody), INFO_GROUP, "affected elements")
    -- The bullet list itself, spot-checked at both ends rather than retyped.
    check(infoBody:find("• Text Designer (Name, Health, Status & custom text)", 1, true) ~= nil,
          "inline: the list still opens on the Text Designer")
    check(infoBody:find("• Pinned Frames", 1, true) ~= nil,
          "inline: ...and still closes on the pinned pool")
    check(infoBody:find('{tone = "caution", prefix = "Note", width = 250}', 1, true) ~= nil,
          "inline: the caution note keeps its tone, prefix and width")

    -- ---- the band ----------------------------------------------------
    check(PAGE:find("fontBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
          "band: the band is chromeless, at the width the layout pass will give it")
    -- ☠ NO HEADER. The two rows' own labels already carry the page's one subject
    -- between them; a "Global Fonts" header would repeat the tab name.
    check(PAGE:find("fontBand:AddWidget(GUI:CreateHeader", 1, true) == nil,
          "band: ...and carries no header, because its rows' labels already name it")
    -- Both rows go into it, in classic's own column-1 reading order.
    local order = {}
    for name in PAGE:gmatch("fontBand:AddWidget%(GUI:CreatePopoutRow%(self%.child, {\n%s*label%s*=%s*L%[\"([^\"]+)\"%]") do
        order[#order + 1] = name
    end
    eq(#order, 2, "band: two rows go into the band")
    eq(order[1], "Global Font Settings", "band: the font row opens it")
    eq(order[2], "Shadow Settings",      "band: ...then Shadow Settings, classic's column-1 order")

    -- ---- the Add order ------------------------------------------------
    local adds = {}
    for name, col in PAGE:gmatch("Add%((%a[%w_]*),%s*nil,%s*([%w\"_]+)%)") do
        adds[#adds + 1] = { name = name, col = col }
    end
    local function indexOf(name, col)
        for i, e in ipairs(adds) do
            if e.name == name and (col == nil or e.col == col) then return i end
        end
    end
    -- ☠ THE BAND IS ADDED AFTER ITS LAST ROW AND BEFORE THE INLINE BOX, and both
    -- halves of that are forced. `Add` resolves a widget's slot height on the
    -- spot, so a band added before its rows would be measured empty; and "both"
    -- is a sync point, so a full-width band dropped in BELOW the lone column-2
    -- box would leave a hole beside it.
    check(indexOf("fontBand", '"both"') ~= nil, "order: the band spans both columns")
    check(indexOf("infoGroup", "2") ~= nil, "order: Affected Elements keeps column 2")
    local bandAt, infoAt = indexOf("fontBand", '"both"'), indexOf("infoGroup", "2")
    check(bandAt ~= nil and infoAt ~= nil and bandAt < infoAt,
          "order: the band is added first, then the inline box")
    -- The box's own Add is shared by both layouts -- it was already the last
    -- thing on the page in classic, so the popout arm needs no second copy.
    check(PAGE:find("if not classicLayout then\n            Add(fontBand, nil, \"both\")\n        end\n        Add(infoGroup, nil, 2)", 1, true) ~= nil,
          "order: ...and classic reaches the same Add with no band in front of it")

    -- The classic column assignments, unchanged -- the one thing this pass was
    -- not allowed to move.
    local CLASSIC_COL = { fontSelectGroup = "1", shadowGroup = "1" }
    for name, col in pairs(CLASSIC_COL) do
        check(indexOf(name, col) ~= nil,
              "order: the classic " .. name .. " still goes to column " .. col)
    end
    -- Two bare 280 boxes are left, and both are inside the classicLayout arm: a
    -- third appearing outside one is the drift this counts.
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 2, "order: two bare 280 boxes left, and they are the classic branch's own")

    -- ---- the copy button is untouched ---------------------------------
    check(PAGE:find('Add(CreateCopyButton(self.child, {"fontShadow"}, L["Global Fonts"], "general_fonts"), 25, 2)', 1, true) ~= nil,
          "page: the copy button is still the first thing on the page, on the same prefix")
end
