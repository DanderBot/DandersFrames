local NS = ...

-- ============================================================
-- TARGETED LIST PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Indicators.lua
-- ------------------------------------------------------------
-- Indicators > Targeted List is the widest page in the sweep so far by group
-- count: THIRTEEN groups, and all thirteen become feature rows, in three bands:
--
--   "Content" band     Settings (hoists targetedListEnabled, the PAGE gate) and
--                      Size & Spacing
--   "Appearance" band  Bar Style, Bar Color, Border (hoists
--                      targetedListShowBorder), Icon (hoists
--                      targetedListShowIcon) and Timing
--   "Text" band        Show Text, Text Font and the four per-element position
--                      groups
--
-- ☠ NO CONTROL ROW ON THIS PAGE. Every group has at least two settings, so the
-- single-setting shape never comes up.
--
-- ☠ AND NO GateHide SEAM EITHER, unlike the Dispel Overlay. That page's gate was
-- written as a HIDE, which a pane cannot copy; this one is written as a GREY --
-- `disableOn = HideTLOptions` on each dependent control, the addon-wide
-- convention -- so it reads the same in the box and in the pane and is handed to
-- the widgets unchanged. The popout adds one thing on top: the ROW greys as
-- well, so a switched-off feature is one dim plate rather than a live plate over
-- a pane of dim controls.
--
-- ☠ THE SHARED MACHINERY IS TAKEN ABOVE THE RAID BAIL. This page returns early
-- in raid mode (it is party-only), and the switch INTO raid is a rebuild that
-- can happen with a popout panel standing open -- so the helper's prologue
-- (close every panel, retire the previous build's holders) has to run before the
-- return, or a party-mode panel floats beside the raid message wired to rows
-- this build has retired.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db -- so this file
-- does what the other census files do: it reads the page's SOURCE and asserts
-- against it.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each extracted builder -- kind, L key, db key and
--     slot height, in order -- taken from the PRE-CHANGE source, so a builder
--     that quietly dropped a control or renamed a key fails here. This is also
--     the evidence that CLASSIC RENDERS AS IT DID: the classic branch mounts the
--     same builder into the same 280 box, in the same column, in the same Add
--     order.
--   ✓ the wiring every row must have, the declared counts (less whatever the row
--     hoisted), the claim/tick/footer trio and the three bands.
--   ✗ nothing about how any of it LOOKS or behaves in the client -- the panels,
--     the greys and the summaries are read by eye and by the in-game checklist.
-- ============================================================

-- ⚠ NORMALISED TO LF UP FRONT. This page file ships CRLF (the companion's files
-- are mixed per file), and a plain multi-line `find` for source text would miss
-- every one of them otherwise. Nothing here asserts about line endings.
local SRC = options_file_source("GUI/Pages/Indicators.lua"):gsub("\r\n", "\n")

-- ---- the census reader (the sweep's, plus this page's three font kinds) ----
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateSeparator = "separator", CreateButton = "button",
    CreateGrowthControl = "growth", CreateTextureDropdown = "texturedropdown",
    CreateTextControls = "textcontrols", CreateBorderControls = "bordercontrols",
    CreateDurationFormatControls = "durationformat", CreateInfoBanner = "banner",
    -- ⚠ THE THREE THIS PAGE ADDS. A factory the reader does not know is SKIPPED,
    -- and its chunk then merges into the previous entry -- which would move that
    -- entry's slot height and pass. The Text Font group is font / size / outline
    -- / shadow, so all three have to be named.
    CreateFontDropdown = "fontdropdown", CreateOutlineDropdown = "outlinedropdown",
    CreateShadowCheckbox = "shadowcheckbox",
}

-- The body of a `local function <name>(tools2)` at the page builder's own indent.
-- ⚠ TWELVE SPACES, NOT EIGHT. This page's BuildPage body carries one extra
-- indent level and always has; the terminator is that indent.
local function builderBody(name)
    local head = "local function " .. name .. "(tools2)"
    local a = SRC:find(head, 1, true)
    check(a ~= nil, "source: the page declares " .. name)
    if not a then return "" end
    local b = SRC:find("\n            end\n", a, true)
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
    local a = SRC:find('BuildPage(pageTargetedList, function(self, db, Add, AddSpace, AddSyncPoint)', 1, true)
    local b = SRC:find('-- Indicators > Personal Targeted Spells', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Targeted List page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

local function esc(s) return (s:gsub("%p", "%%%0")) end

-- The block a row is declared in, from its label to the closing brace of the
-- CreatePopoutRow opts.
local function rowOpts(labelKey)
    local a = PAGE:find('%f[%w]label%s*=%s*L%["' .. esc(labelKey) .. '"%]')
    check(a ~= nil, "source: a popout row is declared for " .. labelKey)
    if not a then return "" end
    local b = PAGE:find("}))", a, true)
    return PAGE:sub(a, (b or a) + 2)
end

-- What every converted group on this page has in common.
local function checkShared(builder, rowLabel, boxHeader, column)
    -- ONE builder, BOTH layouts: the declaration and the two mounts.
    local calls = 0
    for _ in PAGE:gmatch(builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, rowLabel .. ": declared once, mounted twice -- classic box and popout pane")

    -- The classic branch builds the box it always did, with its own header, in
    -- the column it always had.
    check(PAGE:find('GUI:CreateHeader(self.child, L["' .. boxHeader .. '"])', 1, true) ~= nil,
          rowLabel .. ": the classic box keeps its own header (" .. boxHeader .. ")")
    local box
    for at, name in PAGE:gmatch("()local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)") do
        local want = name .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. boxHeader .. '"])'
        local hit = PAGE:find(want, at, true)
        if hit and hit - at < 900 then box = name break end
    end
    check(box ~= nil, rowLabel .. ": ...and that header belongs to a bare 280 box")
    if box then
        check(PAGE:find("Add(" .. box .. ", nil, " .. column .. ")", 1, true) ~= nil,
              rowLabel .. ": ...which still goes to column " .. column)
    end

    local opts = rowOpts(rowLabel)
    check(opts ~= "" and opts:find("build", 1, true) ~= nil,
          rowLabel .. ": the row is handed a pre-built mount")
    check(opts:find("window", 1, true) ~= nil,
          rowLabel .. ": ...docked outside the settings window")
    check(opts:find("clipTo", 1, true) ~= nil,
          rowLabel .. ": ...and clipped by the page's own scroll frame, not the window")
end

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED MACHINERY, ABOVE THE RAID BAIL
-- ============================================================
print("-- Targeted List page: the shared popout machinery and the page-scope vocabulary")
do
    check(PAGE:find("local classicLayout = DF:IsClassicSettingsLayout()", 1, true) ~= nil,
          "tools: the page asks which layout it is building")
    check(PAGE:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true) ~= nil,
          "tools: ...and takes the shared machinery unconditionally")

    -- ☠ ABOVE THE RAID BAIL. The prologue that closes stale panels and retires
    -- the previous build's holders must run on the rebuild that switches INTO
    -- raid mode, which is the one this page returns early from.
    local at = PAGE:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true)
    local bail = PAGE:find('if GUI.SelectedMode == "raid" then', 1, true)
    check(at ~= nil and bail ~= nil and at < bail,
          "tools: ...before the party-only bail, so a mode switch still closes the panels")

    for _, v in ipairs({ "PopoutContent", "ReflowPane", "ReflowMounted", "ClaimKeys",
                         "WireModifiedTick", "WireFooter", "RegisterHoistedToggle",
                         "RegisterControlRow", "RefreshAfterGroupWrite", "HoldReason" }) do
        check(PAGE:find("local function " .. v .. "(", 1, true) == nil,
              "tools: the page does not re-declare " .. v)
    end
    check(PAGE:find("_popoutHolders", 1, true) == nil,
          "tools: the page never manages the popout holders itself")
    check(PAGE:find("_popoutRowForKey", 1, true) == nil,
          "tools: ...nor the search row map")

    -- ---- the three bands ----------------------------------------------
    for _, b in ipairs({ "contentBand", "appearanceBand", "textBand" }) do
        check(PAGE:find(b .. " = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
              "bands: " .. b .. " is chromeless, at the width the layout pass will give it")
    end
    for _, pair in ipairs({ { "contentBand", "Content" },
                            { "appearanceBand", "Appearance" },
                            { "textBand", "Text" } }) do
        check(PAGE:find(pair[1] .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. pair[2] .. '"]), 40)', 1, true) ~= nil,
              "bands: ..." .. pair[1] .. " takes a locale string the page already ships")
    end

    -- ☠ NO ROW ON THIS PAGE HIDES, so no band header can be left standing over
    -- nothing. Every gate here is a grey.
    check(PAGE:find("Row.hideOn", 1, true) == nil,
          "bands: no row declares a hideOn, so every band always has something under it")
    check(PAGE:find("GUI:CreateControlRow", 1, true) == nil,
          "bands: no control row -- every group on this page has more than one setting")
    check(PAGE:find("bandStyle", 1, true) == nil,
          "bands: the band skin is never restated as a literal (this page needs none)")

    -- ---- the vocabulary, at PAGE scope, declared exactly once ---------
    for _, v in ipairs({ "growthOptions", "iconPosOptions", "stylePresetOptions",
                         "sortOptions", "textAnchorOptions", "textAlignOptions" }) do
        local decls = 0
        for _ in PAGE:gmatch("local " .. v .. " = {") do decls = decls + 1 end
        eq(decls, 1, "vocab: " .. v .. " is declared exactly once, at page scope")
    end
    check(PAGE:find('STATIC = L["Static (No Reorder)"]', 1, true) ~= nil,
          "vocab: ...and they are the same tables the dropdowns have always offered")

    -- ⚠ ABOVE EVERY BUILDER. A builder is a closure and captures the upvalue that
    -- exists when it is created, so one declared above these would see nil.
    local vocabAt = PAGE:find("local textAlignOptions = {", 1, true)
    for _, b in ipairs({ "BuildTargetedListSettingsGroup", "BuildTargetedListLayoutGroup",
                         "BuildTargetedListPresetGroup", "BuildTargetedListColorGroup",
                         "BuildTargetedListBorderGroup", "BuildTargetedListIconGroup",
                         "BuildTargetedListShowTextGroup", "BuildTargetedListFontGroup",
                         "BuildTargetedListSpellNamePosGroup", "BuildTargetedListTargetNamePosGroup",
                         "BuildTargetedListDurationPosGroup", "BuildTargetedListInterruptPosGroup",
                         "BuildTargetedListTimingGroup" }) do
        local at = PAGE:find("local function " .. b .. "(tools2)", 1, true)
        check(at ~= nil and vocabAt ~= nil and vocabAt < at,
              "vocab: " .. b .. " is declared after it, so it closes over the real tables")
    end

    -- The page's own gates and its one apply are named once and shared by both
    -- layouts.
    for _, g in ipairs({ "HideTLOptions", "HideIconOptions", "HideTargetNameOptions",
                         "HideSelfTargetOptions", "HideHighlightOptions",
                         "HideDurationPosOptions", "TLOffRow", "TargetedListUpdate" }) do
        local n = 0
        for _ in PAGE:gmatch("local function " .. g .. "%(") do n = n + 1 end
        eq(n, 1, "vocab: " .. g .. " is declared exactly once")
    end
end

-- ============================================================
-- 2. THE PAGE GATE, AND THE THREE HOISTS
-- ============================================================
print("-- Targeted List page: the page gate and the three hoisted ticks")
do
    check(PAGE:find("local function TLOffRow(d) return not (d or db).targetedListEnabled end", 1, true) ~= nil,
          "gate: the page gate answers for either table -- the row's own and the page's state pass")

    -- Twelve rows grey with it; the Settings row does not, because it CARRIES the
    -- tick that would otherwise be unreachable.
    local greyed = { "layoutRow", "presetRow", "colorRow", "borderRow", "iconRow",
                     "timingRow", "showTextRow", "fontRow", "spellNameRow",
                     "targetNameRow", "durationPosRow", "interruptPosRow" }
    for _, r in ipairs(greyed) do
        check(PAGE:find(r .. ".disableOn = TLOffRow", 1, true) ~= nil,
              "gate: " .. r .. " greys with the page gate")
    end
    eq(#greyed, 12, "gate: twelve rows grey with the page gate")
    check(PAGE:find("settingsRow.disableOn", 1, true) == nil,
          "gate: ...and the Settings row does not, because it carries the tick")

    -- ☠ NO GROUP-LEVEL CHILD GATE, so no index-1 repair is needed. Every grey on
    -- this page is a per-widget disableOn, which RefreshChildStates applies to
    -- index 1 like any other -- only disableChildrenOn skips it.
    check(PAGE:find("disableChildrenOn", 1, true) == nil,
          "gate: no group-level child gate on this page")
    check(PAGE:find("GatePaneFirstChild", 1, true) == nil,
          "gate: ...and no index-1 repair is declared")

    -- Three hoists, each with its search entry restored and its own commit.
    local hoists = {
        { row = "settingsRow", key = "targetedListEnabled",    label = "Enable",      commit = "OnTargetedListEnableToggle" },
        { row = "borderRow",   key = "targetedListShowBorder", label = "Show Border", commit = "OnTargetedListBorderToggle" },
        { row = "iconRow",     key = "targetedListShowIcon",   label = "Show Icon",   commit = "OnTargetedListIconToggle" },
    }
    for _, h in ipairs(hoists) do
        check(PAGE:find('tools.RegisterHoistedToggle(' .. h.row .. ', L["' .. h.label .. '"], "' .. h.key .. '", ' .. h.commit .. ')', 1, true) ~= nil,
              "hoist: " .. h.row .. " keeps its search entry, with the commit the checkbox carried")
        check(PAGE:find("local function " .. h.commit .. "()", 1, true) ~= nil,
              "hoist: ..." .. h.commit .. " is declared once, in the popout arm")
        -- ⚠ AND NEVER A PAGE REBUILD: that would retire the row being clicked.
        local a = PAGE:find("local function " .. h.commit .. "()", 1, true)
        local b = PAGE:find("\n                end\n", a or 1, true)
        local body = PAGE:sub(a or 1, b or (a or 1))
        check(body:find("tools.ReflowMounted()", 1, true) ~= nil,
              "hoist: ..." .. h.commit .. " reflows the panes standing open")
        check(body:find("RefreshCurrentPage", 1, true) == nil,
              "hoist: ...and never rebuilds the page")
    end

    -- The suppressed checkboxes are still built in classic.
    for _, b in ipairs({ "BuildTargetedListSettingsGroup", "BuildTargetedListIconGroup" }) do
        check(builderBody(b):find("if not tools2.hoistToggle then", 1, true) ~= nil,
              "hoist: " .. b .. " skips its enable checkbox when the row has hoisted it")
    end
    check(builderBody("BuildTargetedListBorderGroup"):find("noShowToggle = tools2.hoistToggle or nil", 1, true) ~= nil,
          "hoist: the border toolkit's own Show Border is suppressed the toolkit's way")
end

-- ============================================================
-- 3. THE ONE PAGE REBUILD LEFT, AND WHERE IT LIVES
-- Picking a Bar Style preset writes a bundle of settings behind a dozen OTHER
-- rows. Classic has always paid for that with a whole-page rebuild and keeps
-- doing exactly that; the pane must not, because a rebuild retires the dropdown
-- being clicked through.
-- ============================================================
print("-- Targeted List page: the preset's layout-aware refresh")
do
    local n = 0
    for _ in PAGE:gmatch("RefreshCurrentPage") do n = n + 1 end
    eq(n, 2, "rebuild: exactly one guarded RefreshCurrentPage call is left on the page")

    check(PAGE:find("local function TargetedListPresetChanged(tools2)", 1, true) ~= nil,
          "rebuild: the preset's commit is named once and takes the layout with it")
    local a = PAGE:find("local function TargetedListPresetChanged(tools2)", 1, true)
    local b = PAGE:find("\n            end\n", a or 1, true)
    local body = PAGE:sub(a or 1, b or (a or 1))
    check(body:find("if tools2.popout then", 1, true) ~= nil,
          "rebuild: ...and asks which layout it is in")
    check(body:find("tools.ReflowMounted(true)", 1, true) ~= nil,
          "rebuild: the pane's answer repaints the VALUES the preset wrote behind the widgets")
    check(body:find("self:RefreshStates()", 1, true) ~= nil,
          "rebuild: ...the row summaries and their amber ticks")
    check(body:find("GUI.RefreshAllOverrideIndicators", 1, true) ~= nil,
          "rebuild: ...and the override indicators -- the set a group reset runs")
    check(body:find("GUI:RefreshCurrentPage()", 1, true) ~= nil,
          "rebuild: ...while classic still rebuilds the page, exactly as it always did")

    -- Every popout mount declares itself as one; thirteen rows, thirteen mounts.
    local popouts = 0
    for _ in PAGE:gmatch("popout = true,") do popouts = popouts + 1 end
    eq(popouts, 13, "rebuild: all thirteen popout mounts declare themselves as panes")

    -- No builder reaches past its own tools2 for a state pass.
    for _, b in ipairs({ "BuildTargetedListSettingsGroup", "BuildTargetedListColorGroup",
                         "BuildTargetedListIconGroup", "BuildTargetedListShowTextGroup" }) do
        check(builderBody(b):find("self:RefreshStates()", 1, true) == nil,
              "rebuild: " .. b .. " never reaches past its own tools2 for a state pass")
        check(builderBody(b):find("tools2.refreshStates()", 1, true) ~= nil,
              "rebuild: ..." .. b .. " re-gates through the layout-aware door instead")
    end
end

-- ============================================================
-- 4. THE THIRTEEN BUILDERS, CONTROL BY CONTROL
-- Every golden below is the census of the PRE-CHANGE source: same factories,
-- same L keys, same db keys, same slot heights, in the same order.
-- ============================================================
local TL_SETTINGS = {
    { "label",    "Shows a bar when an enemy is casting a spell targeting a party/raid member.", "(none)", 35 },
    -- The reposition hint is wrapped in a colour code, so the reader sees no L key.
    { "label",    "(none)",                     "(none)",                        30 },
    { "checkbox", "Enable",                     "targetedListEnabled",           30 },
    { "checkbox", "Important Spells Only",      "targetedListImportantOnly",     30 },
    { "checkbox", "Hide Casts Targeting You",   "targetedListHideOwnCasts",      30 },
    { "checkbox", "Show Untargeted Casts",      "targetedListShowUntargeted",    30 },
    { "checkbox", "Hide Out-of-Combat Casts",   "targetedListHideOutOfCombat",   30 },
    -- The game CVar: a custom get/set tick with no db binding at all.
    { "checkbox", "Show Offscreen Nameplates",  "(none)",                        30 },
    { "slider",   "Max Bars",                   "targetedListMaxBars",           55 },
}
local TL_LAYOUT = {
    { "slider",   "Bar Width",        "targetedListWidth",     55 },
    { "slider",   "Bar Height",       "targetedListHeight",    55 },
    { "slider",   "Spacing",          "targetedListSpacing",   55 },
    { "dropdown", "Growth Direction", "targetedListGrowth",    55 },
    { "dropdown", "Sort Order",       "targetedListSortOrder", 55 },
}
local TL_PRESET = {
    { "dropdown",        "Bar Style",        "targetedListStylePreset",     55 },
    { "texturedropdown", "Texture",          "targetedListTexture",         55 },
    { "slider",          "Background Alpha", "targetedListBackgroundAlpha", 55 },
}
local TL_COLOR = {
    { "colorpicker", "Interruptible Color",        "targetedListInterruptibleColor",     35 },
    { "colorpicker", "Uninterruptible Color",      "targetedListUninterruptibleColor",   35 },
    { "checkbox",    "Self-Target Color",          "targetedListSelfTargetColorEnabled", 30 },
    { "colorpicker", "Self-Target Color",          "targetedListSelfTargetColor",        35 },
    { "checkbox",    "Highlight Important Spells", "targetedListHighlightImportant",     30 },
    { "colorpicker", "Highlight Color",            "targetedListHighlightColor",         35 },
    { "button",      "Reset Colors to Default",    "(none)",                             30 },
}
local TL_BORDER = {
    -- The key the census reads off this one is the PREFIX the toolkit is handed,
    -- not a setting -- every one of its sixteen keys is built from it.
    { "bordercontrols", "(none)", "targetedList", nil },
}
local TL_ICON = {
    { "checkbox", "Show Icon",     "targetedListShowIcon",     30 },
    { "dropdown", "Icon Position", "targetedListIconPosition", 55 },
    { "checkbox", "Zoom Icon",     "targetedListZoomIcon",     30 },
}
local TL_SHOWTEXT = {
    { "checkbox", "Show Spell Name",         "targetedListShowSpellName",        30 },
    { "checkbox", "Show Target Name",        "targetedListShowTargetName",       30 },
    { "checkbox", "Show Duration",           "targetedListShowDuration",         30 },
    { "checkbox", "Target Name Class Color", "targetedListTargetNameClassColor", 30 },
    { "checkbox", "Show Arrow Prefix",       "targetedListShowArrowPrefix",      30 },
    { "checkbox", "Show Arrow Suffix",       "targetedListShowArrowSuffix",      30 },
}
local TL_FONT = {
    { "fontdropdown",    "Font",      "targetedListFont",        55 },
    { "slider",          "Font Size", "targetedListFontSize",    55 },
    { "outlinedropdown", "Outline",   "targetedListFontOutline", 55 },
    -- The shadow tick is a custom get/set OVER THE OUTLINE KEY, so it claims the
    -- same key the dropdown above it does. That is not a duplicate to fix: it is
    -- one setting with two handles.
    { "shadowcheckbox",  "Shadow",    "targetedListFontOutline", 30 },
}
local TL_SPELLNAME = {
    { "slider",   "Font Size",      "targetedListSpellNameFontSize", 55 },
    { "slider",   "Max Text Width", "targetedListSpellNameWidth",    55 },
    { "dropdown", "Anchor",         "targetedListSpellNameAnchor",   55 },
    { "dropdown", "Alignment",      "targetedListSpellNameAlign",    55 },
    { "slider",   "Offset X",       "targetedListSpellNameX",        55 },
    { "slider",   "Offset Y",       "targetedListSpellNameY",        55 },
}
local TL_TARGETNAME = {
    { "slider",   "Font Size",      "targetedListTargetNameFontSize", 55 },
    { "slider",   "Max Text Width", "targetedListTargetNameWidth",    55 },
    { "dropdown", "Anchor",         "targetedListTargetNameAnchor",   55 },
    { "dropdown", "Alignment",      "targetedListTargetNameAlign",    55 },
    { "slider",   "Offset X",       "targetedListTargetNameX",        55 },
    { "slider",   "Offset Y",       "targetedListTargetNameY",        55 },
}
local TL_DURATIONPOS = {
    { "slider",   "Font Size", "targetedListDurationFontSize", 55 },
    { "dropdown", "Anchor",    "targetedListDurationAnchor",   55 },
    { "dropdown", "Alignment", "targetedListDurationAlign",    55 },
    { "slider",   "Offset X",  "targetedListDurationX",        55 },
    { "slider",   "Offset Y",  "targetedListDurationY",        55 },
}
local TL_INTERRUPTPOS = {
    { "slider",   "Font Size",      "targetedListInterruptTextFontSize", 55 },
    { "slider",   "Max Text Width", "targetedListInterruptTextWidth",    55 },
    { "dropdown", "Anchor",         "targetedListInterruptTextAnchor",   55 },
    { "dropdown", "Alignment",      "targetedListInterruptTextAlign",    55 },
    { "slider",   "Offset X",       "targetedListInterruptTextX",        55 },
    { "slider",   "Offset Y",       "targetedListInterruptTextY",        55 },
}
local TL_TIMING = {
    { "slider", "Fade Out Duration",          "targetedListFadeOutDuration",          55 },
    { "slider", "Interrupted Flash Duration", "targetedListInterruptedFlashDuration", 55 },
}

-- ⚠ EVERY ROW TAKES A FOOTER, which is a decision about the KEYS rather than the
-- shape: every setting behind these thirteen rows is a plain profile setting the
-- defaults engine can write -- numbers, strings, booleans and four colour tables
-- whose swatches re-read their table on the value sweep, so a reset that
-- replaces one is repainted rather than detached.
local ROWS = {
    { builder = "BuildTargetedListSettingsGroup", label = "Settings", boxHeader = "Settings",
      golden = TL_SETTINGS, countVar = "TL_SETTINGS_COUNT", column = "1", hoistedIn = 1,
      row = "settingsRow", band = "contentBand", summary = "TargetedListSettingsSummary" },
    { builder = "BuildTargetedListLayoutGroup", label = "Size & Spacing", boxHeader = "Size & Spacing",
      golden = TL_LAYOUT, countVar = "TL_LAYOUT_COUNT", column = "1", hoistedIn = 0,
      row = "layoutRow", band = "contentBand", summary = "TargetedListLayoutSummary" },
    { builder = "BuildTargetedListPresetGroup", label = "Bar Style", boxHeader = "Bar Style",
      golden = TL_PRESET, countVar = "TL_PRESET_COUNT", column = "2", hoistedIn = 0,
      row = "presetRow", band = "appearanceBand", summary = "TargetedListPresetSummary" },
    { builder = "BuildTargetedListColorGroup", label = "Bar Color", boxHeader = "Bar Color",
      golden = TL_COLOR, countVar = "TL_COLOR_COUNT", column = "2", hoistedIn = 0,
      row = "colorRow", band = "appearanceBand", summary = "TargetedListColorSummary" },
    { builder = "BuildTargetedListBorderGroup", label = "Border", boxHeader = "Border",
      golden = TL_BORDER, countVar = "TL_BORDER_COUNT", column = "2", hoistedIn = 0,
      row = "borderRow", band = "appearanceBand", summary = "TargetedListBorderSummary" },
    { builder = "BuildTargetedListIconGroup", label = "Icon", boxHeader = "Icon",
      golden = TL_ICON, countVar = "TL_ICON_COUNT", column = "2", hoistedIn = 1,
      row = "iconRow", band = "appearanceBand", summary = "TargetedListIconSummary" },
    { builder = "BuildTargetedListShowTextGroup", label = "Show Text", boxHeader = "Show Text",
      golden = TL_SHOWTEXT, countVar = "TL_SHOWTEXT_COUNT", column = "1", hoistedIn = 0,
      row = "showTextRow", band = "textBand", summary = "TargetedListShowTextSummary" },
    { builder = "BuildTargetedListFontGroup", label = "Text Font", boxHeader = "Text Font",
      golden = TL_FONT, countVar = "TL_FONT_COUNT", column = "2", hoistedIn = 0,
      row = "fontRow", band = "textBand", summary = "TargetedListFontSummary" },
    { builder = "BuildTargetedListSpellNamePosGroup", label = "Spell Name Position", boxHeader = "Spell Name Position",
      golden = TL_SPELLNAME, countVar = "TL_SPELLNAME_COUNT", column = "1", hoistedIn = 0,
      row = "spellNameRow", band = "textBand", summary = "TargetedListSpellNameSummary" },
    { builder = "BuildTargetedListTargetNamePosGroup", label = "Target Name Position", boxHeader = "Target Name Position",
      golden = TL_TARGETNAME, countVar = "TL_TARGETNAME_COUNT", column = "2", hoistedIn = 0,
      row = "targetNameRow", band = "textBand", summary = "TargetedListTargetNameSummary" },
    { builder = "BuildTargetedListDurationPosGroup", label = "Duration Position", boxHeader = "Duration Position",
      golden = TL_DURATIONPOS, countVar = "TL_DURATIONPOS_COUNT", column = "1", hoistedIn = 0,
      row = "durationPosRow", band = "textBand", summary = "TargetedListDurationPosSummary" },
    { builder = "BuildTargetedListInterruptPosGroup", label = "Interrupt Text Position", boxHeader = "Interrupt Text Position",
      golden = TL_INTERRUPTPOS, countVar = "TL_INTERRUPTPOS_COUNT", column = "2", hoistedIn = 0,
      row = "interruptPosRow", band = "textBand", summary = "TargetedListInterruptPosSummary" },
    { builder = "BuildTargetedListTimingGroup", label = "Timing", boxHeader = "Timing",
      golden = TL_TIMING, countVar = "TL_TIMING_COUNT", column = "1", hoistedIn = 0,
      row = "timingRow", band = "appearanceBand", summary = "TargetedListTimingSummary" },
}

for _, g in ipairs(ROWS) do
    print("-- Targeted List page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())
    checkShared(g.builder, g.label, g.boxHeader, g.column)

    local opts = rowOpts(g.label)
    check(opts:find("summary%s*=%s*" .. g.summary) ~= nil,
          g.label .. ": the row declares a summary of its own")
    check(opts:find("count%s*=%s*" .. g.countVar) ~= nil,
          g.label .. ": ...and the declared count, not a literal")
    check(opts:find("db%s*=%s*tools.RowDB") ~= nil,
          g.label .. ": ...bound through the function form, so a mode switch is followed")

    check(PAGE:find("local " .. g.row .. " = " .. g.band .. ":AddWidget(GUI:CreatePopoutRow(", 1, true) ~= nil,
          g.label .. ": the row is mounted into the " .. g.band)
    check(PAGE:find("tools.ClaimKeys(" .. g.row .. ", ", 1, true) ~= nil,
          g.label .. ": the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(" .. g.row .. ")", 1, true) ~= nil,
          g.label .. ": ...its amber tick asks about exactly those keys")
    check(PAGE:find("tools.WireFooter(" .. g.row .. ", TargetedListUpdate)", 1, true) ~= nil,
          g.label .. ": ...and Reset Group / Hold: Defaults push the change into the bars")

    -- The declared count is the census, less whatever the row hoisted out of it.
    -- The border row is the one that is not a plain widget list -- its arithmetic
    -- is section 5.
    if g.golden ~= TL_BORDER then
        local declared = tonumber(PAGE:match("local " .. g.countVar .. "%s*=%s*(%d+)"))
        check(declared ~= nil, g.label .. ": the page declares the row's count in one place")
        eq(declared, #g.golden - g.hoistedIn,
           g.label .. ": ...and it is the census less whatever the row hoisted")
    end
end

-- ============================================================
-- 5. THE BORDER COUNT, DERIVED FROM THE HELPER RATHER THAN ASSERTED AT IT
-- CreateBorderControls builds a fixed set plus one widget per include key. This
-- page's include set is the narrowest on any converted page: no offset, no
-- animation and no colour resolvers -- the bars represent SPELLS, not units.
-- ============================================================
print("-- Targeted List page: the border count")
do
    local BORDER_BASE = 4          -- Show Border, thickness, style, texture
    local BORDER_COLOR = 1         -- the static colour picker
    local BORDER_GRADIENT = 3      -- start, end, direction
    local BORDER_SHADOW = 5        -- the block's tick plus colour, size, two offsets
    local BORDER_ALPHA, BORDER_INSET, BORDER_BLEND = 1, 1, 1
    local borderAll = BORDER_BASE + BORDER_COLOR + BORDER_GRADIENT + BORDER_SHADOW
                    + BORDER_ALPHA + BORDER_INSET + BORDER_BLEND
    eq(borderAll, 16, "counts: the border toolkit builds sixteen for this include set")
    local declared = tonumber(PAGE:match("local TL_BORDER_COUNT%s*=%s*(%d+)"))
    eq(declared, borderAll - 1,
       "counts: Border is those sixteen less the hoisted Show Border")

    local body = builderBody("BuildTargetedListBorderGroup")
    for _, k in ipairs({ "alpha", "inset", "blendMode", "gradient", "shadow" }) do
        check(body:find(k .. " = true", 1, true) ~= nil,
              "counts: the include set asks for " .. k)
    end
    for _, k in ipairs({ "animate", "offset", "classColor", "roleColor" }) do
        check(body:find(k .. " = true", 1, true) == nil,
              "counts: ...and does not ask for " .. k)
    end
    -- The gate goes in as the CONSUMER gate it has always been: the toolkit owns
    -- the whole group and writes disableOn onto each of the sixteen itself.
    check(body:find("disableWhen  = HideTLOptions", 1, true) ~= nil,
          "counts: ...and the page gate reaches them as the toolkit's own consumer gate")
end

-- ============================================================
-- 6. THE BOXES, THE ADD ORDER AND THE PAGE'S OWN FURNITURE
-- ============================================================
print("-- Targeted List page: the boxes, the bands and the order")
do
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 13, "boxes: thirteen bare 280 boxes left, and they are the classic branch's own")
    check(PAGE:find("280, tools", 1, true) == nil,
          "boxes: no stay-inline 280 box is left on the page")

    -- ---- classic's Add order is the order it always had ---------------
    -- Within a column the Add() order IS the layout order, so this is what makes
    -- "classic is unchanged" structural rather than a promise. ⚠ TIMING IS STILL
    -- LAST: its ROW reads fifth in the Appearance band, but moving the source
    -- block up the file would have reordered classic's column 1.
    local order = { "settingsGroup", "layoutGroup", "presetGroup", "colorGroup",
                    "borderGroup", "iconGroup", "textToggleGroup", "fontGroup",
                    "spellNamePosGroup", "targetNamePosGroup", "durationPosGroup",
                    "interruptPosGroup", "timingGroup" }
    local prev = 0
    for _, name in ipairs(order) do
        local at = PAGE:find("Add(" .. name .. ", nil,", 1, true)
        check(at ~= nil and at > prev, "order: classic adds " .. name .. " in its original place")
        prev = at or prev
    end

    -- ---- the Appearance band's own order, Timing last -----------------
    local a = PAGE:find("appearanceBand:AddWidget(GUI:CreatePopoutRow", 1, true)
    local t = PAGE:find("local timingRow = appearanceBand:AddWidget(", 1, true)
    local last = PAGE:find("local interruptPosRow = textBand:AddWidget(", 1, true)
    check(a and t and last and a < last and last < t,
          "order: the Timing row is mounted into the Appearance band from the foot of the page")

    -- ---- the Add order of the bands ------------------------------------
    local b1 = PAGE:find('Add(contentBand, nil, "both")', 1, true)
    local b2 = PAGE:find('Add(appearanceBand, nil, "both")', 1, true)
    local b3 = PAGE:find('Add(textBand, nil, "both")', 1, true)
    check(b1 and b2 and b3 and b1 < b2 and b2 < b3,
          "order: the three bands span both columns, in reading order")

    -- ---- the page's own furniture is untouched -------------------------
    check(PAGE:find('CreateCopyButton(self.child, {"targetedList"}, L["Targeted List"], "indicators_targetedlist")', 1, true) ~= nil,
          "page: the copy button keeps the prefix it owns")
    check(PAGE:find('{pageId = "indicators_personal_targeted", label = L["Personal Targeted"]}', 1, true) ~= nil,
          "page: ...and the See Also block still points at Personal Targeted")
    check(PAGE:find('L["Targeted List is a Party-only feature. Switch to Party mode to configure."]', 1, true) ~= nil,
          "page: ...and raid mode still gets the party-only message")
end

-- ============================================================
-- 7. THE SUMMARIES
-- Read by eye in the client; what is asserted here is that each one exists, is
-- declared once, joins with the sweep's separator and reads the same tables the
-- controls behind it offer -- so a row cannot say one thing while its dropdown
-- says another.
-- ============================================================
print("-- Targeted List page: the summaries")
do
    check(PAGE:find('local function Join(parts) return table.concat(parts, " \\194\\183 ") end', 1, true) ~= nil,
          "summary: the sweep's separator is named once")

    -- ☠ FOUR POSITION ROWS, ONE BODY. All four say the same three facts about the
    -- same three key shapes, so it is written once and given the element's prefix.
    check(PAGE:find("local function TargetedTextSummary(d, prefix)", 1, true) ~= nil,
          "summary: the four position rows share one body")
    for _, pair in ipairs({ { "TargetedListSpellNameSummary", "SpellName" },
                            { "TargetedListTargetNameSummary", "TargetName" },
                            { "TargetedListDurationPosSummary", "Duration" },
                            { "TargetedListInterruptPosSummary", "InterruptText" } }) do
        check(PAGE:find('local function ' .. pair[1] .. '(d) return TargetedTextSummary(d, "' .. pair[2] .. '") end', 1, true) ~= nil,
              "summary: ..." .. pair[1] .. " is that body with its prefix")
    end

    for _, s in ipairs({ "TargetedListSettingsSummary", "TargetedListLayoutSummary",
                         "TargetedListPresetSummary", "TargetedListColorSummary",
                         "TargetedListBorderSummary", "TargetedListIconSummary",
                         "TargetedListShowTextSummary", "TargetedListFontSummary",
                         "TargetedListTimingSummary", "TargetedTextSummary" }) do
        local body = PAGE:match("local function " .. s .. "%(.-%)(.-)\n            end")
        check(body ~= nil and body:find("Join(parts)", 1, true) ~= nil,
              "summary: " .. s .. " joins with the shared separator")
        check(body ~= nil and body:find("if not d then return \"\" end", 1, true) ~= nil,
              "summary: ..." .. s .. " answers an absent db rather than erroring on it")
    end

    -- The chosen WORD comes out of the dropdown's own table, never a second copy.
    check(PAGE:find("local g = growthOptions[d.targetedListGrowth]", 1, true) ~= nil,
          "summary: Size & Spacing names the growth from the dropdown's own table")
    check(PAGE:find("local s = sortOptions[d.targetedListSortOrder]", 1, true) ~= nil,
          "summary: ...and the sort order from its own")
    check(PAGE:find("local p = stylePresetOptions[d.targetedListStylePreset]", 1, true) ~= nil,
          "summary: Bar Style names the preset from the dropdown's own table")
    check(PAGE:find("local p = iconPosOptions[d.targetedListIconPosition]", 1, true) ~= nil,
          "summary: Icon names the side from its own")
    check(PAGE:find('local a = textAnchorOptions[d["targetedList" .. prefix .. "Anchor"]]', 1, true) ~= nil,
          "summary: ...and the four position rows from the anchor table they all share")
end
