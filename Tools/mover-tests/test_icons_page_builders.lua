local NS = ...

-- ============================================================
-- ICONS PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Modules.lua
-- ------------------------------------------------------------
-- Indicators > Icons is the biggest page in the addon and the LAST of the sweep:
-- one shared typography block plus THIRTEEN status icons, each carrying the same
-- Settings / Appearance / Position trio (AFK adds a fourth box for its timer).
-- Forty-one groups, 154 mounted controls, and every icon says the same three
-- things with a different prefix.
--
-- ☠ SO THE SHAPE IS WRITTEN ONCE AND PARAMETERISED, WHICH CHANGES WHAT A CENSUS
-- IS. Every other page in the sweep is pinned by reading its per-group builder
-- bodies control by control. Here there are only FIVE bodies for forty-one
-- groups: three shared ones whose labels and keys are `spec` fields, plus the two
-- genuinely bespoke blocks (Role's Settings and AFK's Timer Text). So this file
-- pins BOTH HALVES and they are only evidence together:
--   (a) the five builder bodies, control by control, in order -- the SHAPE;
--   (b) all thirteen SPEC tables, field by field -- the VALUES the shape is
--       given.
-- Shape x specs is the whole page. A control dropped from a builder fails (a); a
-- key or label typo'd in one icon fails (b).
--
-- ☠ AND THE THIRTEEN COLLAPSIBLE SECTIONS ARE KEPT, IN BOTH LAYOUTS -- the one
-- page in the sweep where that is the verdict rather than the Highlights page's
-- "sections become bands". They do two things a band cannot: they carry the LIVE
-- HEADER PREVIEW of the icon they control (SetPreviewIcons, desaturated when the
-- icon is off), and they fold 41 plates down to 14 headers. Icon Text Settings is
-- the one section that DOES dissolve -- no preview, one block of controls.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db -- so this file
-- does what the other census files do: it reads the page's SOURCE and asserts
-- against it.
--
-- What that buys, and what it does not:
--   ✓ the widget census of every builder, and every spec field it is handed --
--     which together are the evidence that CLASSIC RENDERS AS IT DID, because
--     the classic branch mounts the same builders into the same 280 boxes, in
--     the same sections, in the same column.
--   ✓ the wiring every row must have: the shared machinery rather than a copy of
--     it, the declared counts, the claim/tick/footer trio, the composed titles
--     and the per-icon greys.
--   ✗ nothing about how any of it LOOKS or behaves in the client -- the panels,
--     the hides, the previews and the summaries are read by eye and by the
--     in-game checklist.
-- ============================================================

-- ⚠ NORMALISED TO LF UP FRONT. This page file ships CRLF (the companion's files
-- are mixed per file), and a plain multi-line `find` for source text would miss
-- every one of them otherwise. Nothing here asserts about line endings.
local SRC = options_file_source("GUI/Pages/Modules.lua"):gsub("\r\n", "\n")

-- ---- the census reader (the sweep's) ---------------------------------
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateSeparator = "separator", CreateButton = "button",
    CreateGrowthControl = "growth", CreateTextureDropdown = "texturedropdown",
    CreateTextControls = "textcontrols", CreateBorderControls = "bordercontrols",
    CreateDurationFormatControls = "durationformat", CreateInfoBanner = "banner",
    CreateFontDropdown = "fontdropdown", CreateOutlineDropdown = "outlinedropdown",
    CreateShadowCheckbox = "shadowcheckbox",
    -- ⚠ THE TWO THIS PAGE ADDS. A factory the reader does not know is SKIPPED,
    -- and its chunk then merges into the previous entry -- which would move that
    -- entry's slot height and pass. This page mounts sixteen EDIT BOXES (three
    -- role icon paths and thirteen status texts) and two SHADOW LINKS, so both
    -- have to be named.
    CreateEditBox = "editbox", CreateGlobalFontsShadowLink = "shadowlink",
}

-- The body of a `local function <name>(...)` at the page builder's own indent.
-- Terminated on a newline + EIGHT spaces + `end`, which is that indent:
-- everything inside one of these bodies is indented further.
local function builderBody(name)
    local head = "local function " .. name .. "("
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

-- The page, scoped by its own two ends: Modules.lua holds five pages, and a bare
-- 280 box on one of the others is not this pass's business.
local PAGE
do
    local a = SRC:find("BuildPage(pageIcons, function(self, db, Add, AddSpace, AddSyncPoint)", 1, true)
    local b = SRC:find("BuildPage(pageHighlights, function(self, db, Add, AddSpace, AddSyncPoint)", 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Icons page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

local function esc(s) return (s:gsub("%p", "%%%0")) end

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED MACHINERY, AND SAYS THE SHAPE ONCE
-- ============================================================
print("-- Icons page: the shared popout machinery, and one builder for thirteen icons")
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
    check(PAGE:find("_popoutHolders", 1, true) == nil,
          "tools: the page never manages the popout holders itself")
    check(PAGE:find("_popoutRowForKey", 1, true) == nil,
          "tools: ...nor the search row map")

    -- ☠ THE WHOLE POINT OF THIS PAGE'S CONVERSION. Thirteen icons, and exactly
    -- ONE declaration of each of the three shared builders and ONE of the mount
    -- that drives both layouts. Thirteen copies would drift, and the first thing
    -- to drift would be one of the callbacks.
    for _, b in ipairs({ "BuildIconSettingsGroup", "BuildIconAppearanceGroup",
                         "BuildIconPositionGroup", "MountIcon" }) do
        local n = 0
        for _ in PAGE:gmatch("local function " .. b .. "%(") do n = n + 1 end
        eq(n, 1, "shape: " .. b .. " is declared exactly once")
    end

    -- ...and MountIcon is what every icon goes through.
    local mounts = 0
    for _ in PAGE:gmatch("MountIcon%(%{") do mounts = mounts + 1 end
    eq(mounts, 13, "shape: all thirteen icons are mounted through the one function")

    -- The classic arm's boxes are built in MountIcon too, so there are FOUR bare
    -- 280 boxes in the source for forty groups on the page: Settings, the extra
    -- (AFK's Timer Text), Appearance and Position.
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 4, "boxes: four bare 280 boxes in the source, and they are the classic branch's own")
    check(PAGE:find("280, tools", 1, true) == nil,
          "boxes: no stay-inline 280 box is left on the page")
    check(PAGE:find("bandStyle", 1, true) == nil,
          "boxes: the band skin is never restated as a literal (this page needs none)")
end

-- ============================================================
-- 2. THE SECTIONS STAY, AND THE BANDS GO INSIDE THEM
-- ============================================================
print("-- Icons page: the sections stay in both layouts, and the bands go inside them")
do
    -- One helper, two spellings: classic keeps the 280 header in column 1; the
    -- popout builds the same header at the band's width and adds it "both".
    check(PAGE:find('return Add(GUI:CreateCollapsibleSection(self.child, label, false, 280), 36, 1)', 1, true) ~= nil,
          "sections: classic keeps the 280 section header in column 1, at slot 36")
    check(PAGE:find('return Add(GUI:CreateCollapsibleSection(self.child, label, false, tools.BandWidth()), 36, "both")', 1, true) ~= nil,
          "sections: ...and the popout builds it at the band's width, spanning both columns")

    -- The band is the section's CHILD, which is what makes the fold fold it.
    check(PAGE:find("local band = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
          "bands: a section's band is chromeless, at the width the layout pass will give it")
    check(PAGE:find("section:RegisterChild(band)", 1, true) ~= nil,
          "bands: ...and registered to the section, so collapsing takes the plates with it")
    check(PAGE:find('Add(band, nil, "both")', 1, true) ~= nil,
          "bands: ...and added after its rows are mounted, spanning both columns")

    -- Icon Text Settings is the one that dissolves.
    check(PAGE:find('textSection = Add(GUI:CreateCollapsibleSection(self.child, L["Icon Text Settings"], false, 280), 36, 1)', 1, true) ~= nil,
          "sections: classic keeps the Icon Text Settings section exactly as it was")
    check(PAGE:find("local textBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
          "sections: ...and the popout gives it a headerless band instead")
    check(PAGE:find('Add(textBand, nil, "both")', 1, true) ~= nil,
          "sections: ...added at the top of the page")

    -- Every group the classic arm builds is still a section child.
    for _, g in ipairs({ "settingsGroup", "extraGroup", "appearanceGroup", "positionGroup" }) do
        check(PAGE:find("section:RegisterChild(" .. g .. ")", 1, true) ~= nil,
              "sections: the classic " .. g .. " is registered to its section")
        check(PAGE:find("Add(" .. g .. ", nil, 1)", 1, true) ~= nil,
              "sections: ...in column 1, where it always was")
    end
    -- ...with the header the box always drew.
    for _, h in ipairs({ "Settings", "Appearance", "Position" }) do
        check(PAGE:find('GUI:CreateHeader(self.child, L["' .. h .. '"]), GUI.RowHeight.sectionHeader', 1, true) ~= nil,
              "sections: the classic box keeps its own " .. h .. " header")
    end
    check(PAGE:find("GUI:CreateHeader(self.child, spec.extraGroup.label), GUI.RowHeight.sectionHeader", 1, true) ~= nil,
          "sections: ...and the extra box takes its header from the spec")
end

-- ============================================================
-- 3. THE FIVE BUILDER BODIES -- THE SHAPE
-- The three shared builders read their labels and keys off the spec, so the
-- census sees "(none)" wherever a value is parameterised. That is the point: the
-- shape is pinned here, the values in section 4.
-- ============================================================
print("-- Icons page: the shared builders")
do
    checkCensus(census(builderBody("BuildIconSettingsGroup")), {
        -- the enable tick, suppressed when the row carries it
        { "checkbox", "(none)",       "(none)", 30 },
        -- the one explanatory label some icons carry
        { "label",    "(none)",       "(none)", nil },
        -- the Show as Text block: the tick, one edit box per status string, and
        -- the colour, which comes through the page's own AddTextColor helper and
        -- is asserted separately below
        { "checkbox", "Show as Text", "(none)", 30 },
        { "editbox",  "(none)",       "(none)", 55 },
    }, "settings builder")
    -- ⚠ THE SEVENTH CONTROL IS NOT A GUI:Create CALL. AddTextColor is the page's
    -- own helper (one colour picker, hidden unless that icon is in text mode), so
    -- the reader cannot see it and it is named here instead.
    check(PAGE:find('AddTextColor(group, parent, L["Text Color"], spec.key .. "TextColor", spec.showTextKey)', 1, true) ~= nil,
          "settings builder: the text colour is mounted through the page's own helper")
    check(PAGE:find("local function AddTextColor(group, parent, label, key, showKey)", 1, true) ~= nil,
          "settings builder: ...which now takes its parent, because a pane's is not self.child")
    check(PAGE:find("w.hideOn = function(d) return not d[showKey] end", 1, true) ~= nil,
          "settings builder: ...and still hides while that icon is in icon mode")

    checkCensus(census(builderBody("BuildIconAppearanceGroup")), {
        { "slider",   "Scale",       "(none)", 55 },
        { "slider",   "Alpha",       "(none)", 55 },
        { "slider",   "Frame Level", "(none)", 55 },
        { "checkbox", "(none)",      "(none)", 30 },   -- Hide in Combat, where the icon has one
    }, "appearance builder")

    checkCensus(census(builderBody("BuildIconPositionGroup")), {
        { "dropdown", "Anchor",   "(none)", 55 },
        { "slider",   "Offset X", "(none)", 55 },
        { "slider",   "Offset Y", "(none)", 55 },
    }, "position builder")

    -- ---- the two bespoke blocks ---------------------------------------
    checkCensus(census(builderBody("BuildIconTextGroup")), {
        { "label",           "Font settings for icons displayed as text (Summon, Res, AFK, etc.)", "(none)",                30 },
        { "fontdropdown",    "Font",      "statusIconFont",        55 },
        { "slider",          "Font Size", "statusIconFontSize",    55 },
        { "outlinedropdown", "Outline",   "statusIconFontOutline", 55 },
        { "shadowcheckbox",  "Shadow",    "statusIconFontOutline", 30 },
        { "shadowlink",      "(none)",    "(none)",                nil },
    }, "icon text settings")

    checkCensus(census(builderBody("BuildRoleSettingsGroup")), {
        { "dropdown", "Icon Style",       "roleIconStyle",          55 },
        { "editbox",  "Tank Icon Path",   "roleIconExternalTank",   55 },
        { "editbox",  "Healer Icon Path", "roleIconExternalHealer", 55 },
        { "editbox",  "DPS Icon Path",    "roleIconExternalDPS",    55 },
        -- ⚠ the escaped backslash is doubled AGAIN here: the reader sees the
        -- page's SOURCE text, where the string literal reads `Interface\\.`
        { "label",    "Paths are relative to your WoW folder and must start with Interface\\\\. Pasting a full path works — anything before 'Interface' is stripped. Leave empty for DF Icons.", "(none)", 70 },
        { "checkbox", "Show Tank",        "roleIconShowTank",       30 },
        { "checkbox", "Show Healer",      "roleIconShowHealer",     30 },
        { "checkbox", "Show DPS",         "roleIconShowDPS",        30 },
    }, "role settings")

    checkCensus(census(builderBody("BuildAFKTimerGroup")), {
        { "fontdropdown",    "Font",     "afkIconTimerFont",     55 },
        { "slider",          "Size",     "afkIconTimerFontSize", 55 },
        { "outlinedropdown", "Outline",  "afkIconTimerOutline",  55 },
        { "shadowcheckbox",  "Shadow",   "afkIconTimerOutline",  30 },
        { "shadowlink",      "(none)",   "(none)",               nil },
        { "colorpicker",     "Color",    "afkIconTimerColor",    30 },
        { "slider",          "Offset X", "afkIconTimerX",        55 },
        { "slider",          "Offset Y", "afkIconTimerY",        55 },
    }, "afk timer text")
end

-- ============================================================
-- 4. THE THIRTEEN SPECS -- THE VALUES
-- Every field the shape reads, pinned against the census taken from the
-- pre-change source. This is where a mistyped key or a swapped label fails.
-- ============================================================
local ICONS = {
    { section = "Role Icon", key = "roleIcon", id = "role", verdict = "row",
      settingsBuilder = "BuildRoleSettingsGroup", count = 8,
      summary = "RoleSettingsSummary", hideInCombat = "Hide In Combat",
      hideInCombatApply = "function() DF:UpdateAllRoleIcons() end",
      afterMount = "UpdateRolePreview" },
    { section = "Leader Icon", key = "leaderIcon", id = "leader", verdict = "controlrow",
      enableKey = "leaderIconEnabled", enableLabel = "Enable Leader Icon",
      hideInCombat = "Hide in Combat" },
    { section = "Target Marker Icon", key = "raidTargetIcon", id = "raidTarget", verdict = "controlrow",
      enableKey = "raidTargetIconEnabled", enableLabel = "Enable Target Marker Icon",
      hideInCombat = "Hide in Combat" },
    { section = "Ready Check Icon", key = "readyCheckIcon", id = "readyCheck", verdict = "row",
      enableKey = "readyCheckIconEnabled", enableLabel = "Enable Ready Check Icon",
      count = 1, hideInCombat = "Hide in Combat",
      after = { { "slider", "Persist (seconds)", "readyCheckIconPersist", 55 } } },
    { section = "Ping Icon", key = "pingIcon", id = "ping", verdict = "controlrow",
      enableKey = "pingIconEnabled", enableLabel = "Enable Ping Icon",
      tooltip = "Shows a group member's ping on the frame of the unit they pinged.",
      hideInCombat = "Hide in Combat" },
    { section = "Summon Icon", key = "summonIcon", id = "summon", verdict = "row",
      enableKey = "summonIconEnabled", enableLabel = "Enable Summon Icon",
      showTextKey = "summonIconShowText", count = 5, hideInCombat = "Hide in Combat",
      texts = { { "Pending Text", "summonIconTextPending" },
                { "Accepted Text", "summonIconTextAccepted" },
                { "Declined Text", "summonIconTextDeclined" } } },
    { section = "BG Carrier Icon", key = "bgCarrierIcon", verdict = "row",
      enableKey = "bgCarrierIconEnabled", enableLabel = "Enable BG Carrier Icon",
      note = "Shows on a friendly party/raid member carrying a battleground objective (flag, orb). Only active inside battlegrounds.",
      noteHeight = 44, showTextKey = "bgCarrierIconShowText", count = 4,
      texts = { { "Carrier Text", "bgCarrierIconText" } } },
    { section = "Combat Icon", key = "combatIcon", verdict = "controlrow",
      enableKey = "combatIconEnabled", enableLabel = "Enable Combat Icon",
      note = "Shows crossed swords on a party/raid member who is in combat.", noteHeight = 44 },
    { section = "Resurrection Icon", key = "resurrectionIcon", id = "resurrection", verdict = "row",
      enableKey = "resurrectionIconEnabled", enableLabel = "Enable Resurrection Icon",
      showTextKey = "resurrectionIconShowText", count = 3,
      texts = { { "Casting Text", "resurrectionIconTextCasting" } } },
    { section = "Phased Icon", key = "phasedIcon", id = "phased", verdict = "row",
      enableKey = "phasedIconEnabled", enableLabel = "Enable Phased Icon",
      showTextKey = "phasedIconShowText", count = 4, hideInCombat = "Hide in Combat",
      texts = { { "Status Text", "phasedIconText" } },
      after = { { "checkbox", "Show LFG Eye for Cross-Instance", "phasedIconShowLFGEye", 30 } } },
    { section = "AFK Icon", key = "afkIcon", id = "afk", verdict = "row",
      enableKey = "afkIconEnabled", enableLabel = "Enable AFK Icon",
      showTextKey = "afkIconShowText", count = 5, hideInCombat = "Hide in Combat",
      texts = { { "Status Text", "afkIconText" } },
      after = { { "checkbox", "Show Timer", "afkIconShowTimer", 30 },
                { "label", "In Text mode the timer joins the status text and uses its font, colour and position.", "(none)", 40 } },
      extra = { label = "Timer Text", count = 8, builder = "BuildAFKTimerGroup",
                summary = "AFKTimerSummary", hideOn = "AFKTimerHidden" } },
    { section = "Vehicle Icon", key = "vehicleIcon", id = "vehicle", verdict = "row",
      enableKey = "vehicleIconEnabled", enableLabel = "Enable Vehicle Icon",
      showTextKey = "vehicleIconShowText", count = 3, hideInCombat = "Hide in Combat",
      texts = { { "Status Text", "vehicleIconText" } } },
    { section = "Raid Role Icon (MT/MA)", key = "raidRoleIcon", id = "raidRole", verdict = "row",
      enableKey = "raidRoleIconEnabled", enableLabel = "Enable Raid Role Icon",
      showTextKey = "raidRoleIconShowText", count = 6, hideInCombat = "Hide in Combat",
      before = { { "checkbox", "Show Main Tank", "raidRoleIconShowTank", 30 },
                 { "checkbox", "Show Main Assist", "raidRoleIconShowAssist", 30 } },
      texts = { { "Tank Text", "raidRoleIconTextTank" },
                { "Assist Text", "raidRoleIconTextAssist" } } },
}

-- Each MountIcon call's own table, from `MountIcon({` to the `})` at the page
-- builder's indent.
local SPECS = {}
do
    local at = 1
    while true do
        local a = PAGE:find("MountIcon({", at, true)
        if not a then break end
        local b = PAGE:find("\n        })", a, true)
        SPECS[#SPECS + 1] = PAGE:sub(a, (b or a) + 11)
        at = (b or a) + 1
    end
    eq(#SPECS, #ICONS, "specs: one spec table per icon, in the page's reading order")
end

print("-- Icons page: the thirteen specs")
for i, want in ipairs(ICONS) do
    local spec = SPECS[i] or ""
    local tag = want.section

    -- ORDER MATTERS: the specs are read top to bottom and each one adds its
    -- section where it stands, so this also pins the page's reading order.
    check(spec:find('section = L["' .. want.section .. '"]', 1, true) ~= nil,
          tag .. ": spec " .. i .. " is this icon's, in this position")
    check(spec:find('key = "' .. want.key .. '"', 1, true) ~= nil,
          tag .. ": ...with its db prefix")
    if want.id then
        check(spec:find('id = "' .. want.id .. '"', 1, true) ~= nil,
              tag .. ": ...and the lightweight render tag its own callbacks want")
    else
        -- ☠ NO TAG MEANS NO LIGHTWEIGHT PATH. BG Carrier and Combat repaint
        -- through DF:UpdateAllFramesStatusIcons for scale, alpha, frame level and
        -- position alike -- they always did, and a copy-paste conversion is
        -- exactly how that difference gets flattened.
        check(spec:find("id = ", 1, true) == nil,
              tag .. ": ...and NO render tag, so it repaints through the status-icon pass")
    end

    if want.enableKey then
        check(spec:find('enableKey = "' .. want.enableKey .. '"', 1, true) ~= nil,
              tag .. ": the master switch is named")
        check(spec:find('enableLabel = L["' .. want.enableLabel .. '"]', 1, true) ~= nil,
              tag .. ": ...with the label the checkbox always drew")
    else
        -- ☠ ROLE IS THE ONE ICON WITH NO ENABLE. Three per-role Show toggles and
        -- no master boolean, so its Settings row hoists nothing and its other two
        -- rows grey with nothing. A fourth distinct reason a row refuses a tick,
        -- after "the master is a MODE" (Highlights) and "not everything in the
        -- group depends on it" (Personal Targeted): there is no single master.
        check(spec:find("enableKey", 1, true) == nil,
              tag .. ": has no master switch at all, so nothing is hoisted")
    end

    if want.verdict == "controlrow" then
        check(spec:find("controlRow = true", 1, true) ~= nil,
              tag .. ": one setting in the box, so the plate IS the setting")
        check(spec:find("settingsCount", 1, true) == nil,
              tag .. ": ...and a control row declares no count, because it opens nothing")
    else
        check(spec:find("controlRow", 1, true) == nil,
              tag .. ": more than one setting in the box, so the plate is a way IN")
        eq(tonumber(spec:match("settingsCount = (%d+)")), want.count,
           tag .. ": the Settings row declares what its pane mounts, minus any hoisted tick")
    end

    if want.showTextKey then
        check(spec:find('showTextKey = "' .. want.showTextKey .. '"', 1, true) ~= nil,
              tag .. ": the Show as Text block is asked for")
        for _, t in ipairs(want.texts) do
            check(spec:find('label = L["' .. t[1] .. '"],   key = "' .. t[2] .. '"', 1, true) ~= nil
                  or spec:find('label = L["' .. t[1] .. '"],  key = "' .. t[2] .. '"', 1, true) ~= nil
                  or spec:find('label = L["' .. t[1] .. '"], key = "' .. t[2] .. '"', 1, true) ~= nil,
                  tag .. ": ...with its " .. t[1] .. " box bound to " .. t[2])
        end
    else
        check(spec:find("showTextKey", 1, true) == nil,
              tag .. ": has no text mode, so no Show as Text block and no text colour")
    end

    if want.note then
        check(spec:find('note = L["' .. want.note .. '"]', 1, true) ~= nil,
              tag .. ": keeps its explanatory sentence")
        eq(tonumber(spec:match("noteHeight = (%d+)")), want.noteHeight,
           tag .. ": ...at the slot height it always had")
    end
    if want.tooltip then
        check(spec:find('enableTooltip = L["' .. want.tooltip .. '"]', 1, true) ~= nil,
              tag .. ": keeps the tooltip on its switch")
    end

    if want.hideInCombat then
        check(spec:find('hideInCombatLabel = L["' .. want.hideInCombat .. '"]', 1, true) ~= nil,
              tag .. ": its Appearance box keeps Hide in Combat")
    else
        -- BG Carrier and Combat never had one.
        check(spec:find("hideInCombatLabel", 1, true) == nil,
              tag .. ": its Appearance box never had a Hide in Combat and still does not")
    end

    for _, side in ipairs({ "before", "after" }) do
        if want[side] then
            checkCensus(census(spec:match("%f[%w]" .. side .. " = function%(group, parent%)(.-)\n            end,") or ""),
                        want[side], tag .. " " .. side)
        end
    end

    if want.extra then
        check(spec:find('label = L["' .. want.extra.label .. '"], build = ' .. want.extra.builder, 1, true) ~= nil,
              tag .. ": its fourth box is asked for by name")
        check(spec:find("count = " .. want.extra.count, 1, true) ~= nil,
              tag .. ": ...declaring what its pane mounts")
        check(spec:find("summary = " .. want.extra.summary, 1, true) ~= nil,
              tag .. ": ...with a summary of its own")
        check(spec:find("hideOn = " .. want.extra.hideOn, 1, true) ~= nil,
              tag .. ": ...and the gate the box always carried")
    end
end

-- ============================================================
-- 5. THE WIRING EVERY ROW GETS -- ONCE, IN MountIcon
-- ============================================================
print("-- Icons page: the rows, the greys and the footers")
do
    -- ---- the plate name is short, the title is long --------------------
    -- ☠ AND THE TITLE IS NOT DECORATION. ClaimKeys stamps a row's title as the
    -- search breadcrumb AND as the anchor Search:ScrollToSection finds the row
    -- by, so thirteen rows called "Settings" would send every jump to the first
    -- one. It is also the open panel's header and the Reset Group undo entry.
    check(PAGE:find('local function RowTitle(section, part) return format("%s \\226\\128\\148 %s", section, part) end', 1, true) ~= nil,
          "titles: the long form is composed once, from two strings that are already translated")
    for _, part in ipairs({ "Settings", "Appearance", "Position" }) do
        check(PAGE:find('label    = L["' .. part .. '"],', 1, true) ~= nil
              or PAGE:find('label   = L["' .. part .. '"],', 1, true) ~= nil,
              "titles: the " .. part .. " plate draws the short name")
        check(PAGE:find('RowTitle(spec.section, L["' .. part .. '"])', 1, true) ~= nil,
              "titles: ...and answers to the long one")
    end
    check(PAGE:find("RowTitle(spec.section, spec.extraGroup.label)", 1, true) ~= nil,
          "titles: ...and the extra row takes the same treatment")

    -- ---- the claim / tick / footer trio, on every row ------------------
    for _, r in ipairs({ "textRow", "settingsRow", "extraRow", "appearanceRow", "positionRow" }) do
        check(PAGE:find("tools.ClaimKeys(" .. r .. ", ", 1, true) ~= nil,
              "wiring: " .. r .. " claims whatever its pane registered")
        check(PAGE:find("tools.WireModifiedTick(" .. r .. ")", 1, true) ~= nil,
              "wiring: ..." .. r .. "'s amber tick asks about exactly those keys")
        -- ⚠ A FOOTER ON EVERY ROW, and that is a decision about the KEYS. Every
        -- setting behind every plate on this page is a plain profile scalar
        -- except the three text colours, whose swatches re-read their table on
        -- the value sweep -- so a reset that REPLACES one is repainted rather
        -- than detached (the Highlights precedent).
        check(PAGE:find("tools.WireFooter(" .. r .. ", ApplyIconGroup)", 1, true) ~= nil,
              "wiring: ..." .. r .. " takes Reset Group / Hold: Defaults")
    end
    check(PAGE:find("local function ApplyIconGroup()", 1, true) ~= nil,
          "wiring: one apply for the page, because one reset can move three render paths")

    -- ---- the hoisted tick, and the row that refuses one ----------------
    check(PAGE:find("toggle   = spec.enableKey and { key = spec.enableKey } or nil", 1, true) ~= nil,
          "hoist: a Settings row carries its icon's switch -- unless the icon has none")
    check(PAGE:find("tools.RegisterHoistedToggle(settingsRow, spec.enableLabel, spec.enableKey, OnEnableToggle)", 1, true) ~= nil,
          "hoist: ...and the suppressed checkbox's search entry moves onto the row")
    check(PAGE:find("hoistToggle = spec.enableKey ~= nil", 1, true) ~= nil,
          "hoist: ...which is what suppresses it inside the pane")
    check(PAGE:find("if spec.enableKey and not tools2.hoistToggle then", 1, true) ~= nil,
          "hoist: ...and the builder draws it in classic, where it is the only switch")

    -- ---- the greys -----------------------------------------------------
    -- ☠ THE ICON'S GATE REACHES THE ROWS THEMSELVES, not only the panes -- the
    -- Resource Bar rule. In classic the whole section visibly dims while the icon
    -- is off; bright plates over grey panes would be the popout saying something
    -- classic does not.
    check(PAGE:find('spec.gate = spec.enableKey and function(d) return not (d or db)[spec.enableKey] end or nil', 1, true) ~= nil,
          "grey: the icon's gate is derived from its own enable key, once")
    for _, r in ipairs({ "extraRow", "appearanceRow", "positionRow" }) do
        check(PAGE:find(r .. ".disableOn = spec.gate", 1, true) ~= nil,
              "grey: " .. r .. " dims with the icon it belongs to")
    end
    check(PAGE:find("settingsRow.disableOn", 1, true) == nil,
          "grey: ...and the Settings row does NOT, because it carries the switch")

    -- ...and the panes behind them, which need the index-1 repair.
    check(PAGE:find("local function GatePaneFirstChild(group, gate)", 1, true) ~= nil,
          "grey: the pane's index-1 repair is on the page (a pane has no header to skip)")
    local repairs = 0
    for _ in PAGE:gmatch("GatePaneFirstChild%(group, spec%.gate%)") do repairs = repairs + 1 end
    eq(repairs, 3, "grey: ...applied to the three TICKLESS panes and nowhere else")
    -- ⚠ NOT ON A SETTINGS PANE. Where the row carries a hoisted tick the kit's
    -- own syncGate greys the pane whole, so the builder drops the group gate
    -- rather than saying the same thing twice -- the Dispel Overlay page's rule.
    check(PAGE:find("group.disableChildrenOn = spec.gate", 1, true) ~= nil,
          "grey: the group gate lives inside the builders, so a pane greys as its box did")

    -- ---- the control rows ---------------------------------------------
    check(PAGE:find("local enableRow = band:AddWidget(GUI:CreateControlRow(self.child, {", 1, true) ~= nil,
          "control row: mounted into a band, never straight into a column")
    check(PAGE:find("db        = tools.RowDB,", 1, true) ~= nil,
          "control row: bound through the function form, so a mode switch is followed")
    check(PAGE:find("tooltip   = spec.enableTooltip or spec.note,", 1, true) ~= nil,
          "control row: Combat's sentence and Ping's tooltip both land on the plate")
    check(PAGE:find('tools.RegisterControlRow(enableRow, "checkbox", spec.enableKey, false, OnEnableToggle)', 1, true) ~= nil,
          "control row: ...and it registers with search under its own label")

    -- ---- what the toggle actually runs ---------------------------------
    -- ☠ NOT A PAGE REBUILD OF ANY KIND: a rebuild retires every widget on the
    -- page including the row being clicked, and the row's write path calls
    -- row.Refresh() after this returns -- on a dead frame.
    check(PAGE:find("local function OnEnableToggle()", 1, true) ~= nil,
          "toggle: what the suppressed checkbox ran is named once per icon")
    check(PAGE:find("GUI:RefreshCurrentPage", 1, true) == nil,
          "toggle: ...and there is no page rebuild left anywhere on this page")
    check(PAGE:find("tools.ReflowMounted()", 1, true) ~= nil,
          "toggle: ...the panes standing open are re-flowed instead")

    -- ---- the counts the rows declare -----------------------------------
    check(PAGE:find("count   = spec.hideInCombatLabel and 4 or 3,", 1, true) ~= nil,
          "counts: the Appearance row counts its Hide in Combat only where the icon has one")
    check(PAGE:find("count   = 3,", 1, true) ~= nil,
          "counts: the Position row is always anchor plus two offsets")
    check(PAGE:find("count    = spec.settingsCount,", 1, true) ~= nil,
          "counts: the Settings row declares the spec's count, not a literal")
    eq(tonumber(PAGE:match("local ICON_TEXT_COUNT = (%d+)")), 6,
       "counts: Icon Text Settings declares its six")
end

-- ============================================================
-- 6. THE PREVIEWS, WHICH ARE WHY THE SECTIONS SURVIVED
-- ============================================================
print("-- Icons page: the header previews")
do
    check(PAGE:find("local function WireStatusPreview(section, opts)", 1, true) ~= nil,
          "preview: the status-icon preview wiring is still on the page")
    check(PAGE:find("if spec.preview then WireStatusPreview(section, spec.preview) end", 1, true) ~= nil,
          "preview: ...and every icon's opts come out of its own spec")
    -- Twelve status icons take WireStatusPreview; Role has its own, because its
    -- preview depends on three Show toggles rather than one enable.
    local previews = 0
    for _ in PAGE:gmatch("preview = {") do previews = previews + 1 end
    eq(previews, 12, "preview: twelve status icons declare one")
    check(PAGE:find("local function UpdateRolePreview()", 1, true) ~= nil,
          "preview: ...and Role keeps its own, which reads three toggles rather than one")
    check(PAGE:find("if spec.onSection then spec.onSection(section) end", 1, true) ~= nil,
          "preview: ...reaching its section through the spec")
    check(PAGE:find("afterMount = UpdateRolePreview", 1, true) ~= nil,
          "preview: ...and painted once at build, as it always was")

    -- The hook that keeps every preview live is untouched, and still hooks the
    -- BODY rather than the arm-stub.
    check(PAGE:find('hooksecurefunc(DF, "UpdateAllFrames_Now", function() DF:RefreshIconPreviews() end)', 1, true) ~= nil,
          "preview: the sweep hook is on the real body, not the arm-stub")
    check(PAGE:find("if DF.iconPreviewRefreshers then wipe(DF.iconPreviewRefreshers) end", 1, true) ~= nil,
          "preview: ...and the refresher list is still wiped before the first is registered")
    local wipeAt = PAGE:find("wipe(DF.iconPreviewRefreshers)", 1, true)
    local firstMount = PAGE:find("MountIcon({", 1, true)
    check(wipeAt and firstMount and wipeAt < firstMount,
          "preview: ...which is what moving the block above the sections had to preserve")
end

-- ============================================================
-- 7. THE SUMMARIES
-- Read by eye in the client; what is asserted here is that each one exists, is
-- written once, joins with the sweep's separator and answers an absent db.
-- ============================================================
print("-- Icons page: the summaries")
do
    check(PAGE:find('local function Join(parts) return table.concat(parts, " \\194\\183 ") end', 1, true) ~= nil,
          "summary: the sweep's separator is named once")
    for _, s in ipairs({ "IconTextSummary", "RoleSettingsSummary", "AFKTimerSummary" }) do
        local body = PAGE:match("local function " .. s .. "%(.-%)(.-)\n        end")
        check(body ~= nil and body:find("Join(parts)", 1, true) ~= nil,
              "summary: " .. s .. " joins with the shared separator")
        check(body ~= nil and body:find('if not d then return "" end', 1, true) ~= nil,
              "summary: ..." .. s .. " answers an absent db rather than erroring on it")
    end
    -- The three shared summaries are FACTORIES -- one body, thirteen prefixes.
    for _, s in ipairs({ "IconSettingsSummary", "IconAppearanceSummary", "IconPositionSummary" }) do
        check(PAGE:find("local function " .. s .. "(spec)", 1, true) ~= nil,
              "summary: " .. s .. " is written once and given the icon's prefix")
    end
    -- The anchor WORD comes out of the dropdown's own table, so a row cannot say
    -- one thing while the control behind it says another.
    check(PAGE:find('local anchor = anchorOptions[d[spec.key .. "Anchor"]]', 1, true) ~= nil,
          "summary: the position row names the anchor from the dropdown's own table")
    check(PAGE:find("local style = roleStyleOptions[d.roleIconStyle]", 1, true) ~= nil,
          "summary: ...and Role names the style from its own")
    -- ⚠ SILENT ON A DEFAULT PROFILE. Thirteen icons on one page, so a summary
    -- that recited its defaults would be thirteen lines of noise: scale and
    -- alpha ship at 1 and are printed only once moved.
    check(PAGE:find("if scale and scale ~= 1 then", 1, true) ~= nil,
          "summary: a default scale is not printed back at the reader")
    check(PAGE:find("if alpha and alpha < 1 then", 1, true) ~= nil,
          "summary: ...nor a default alpha")
end

-- ============================================================
-- 8. THE PAGE'S OWN FURNITURE, AND THE EDIT BOX REPAIR
-- ============================================================
print("-- Icons page: the furniture, and the value sweep an edit box now answers")
do
    check(PAGE:find('CreateCopyButton(self.child, {"roleIcon", "leaderIcon", "raidTargetIcon", "readyCheckIcon", "pingIcon", "summonIcon", "resurrectionIcon", "phasedIcon", "afkIcon", "vehicleIcon", "raidRoleIcon", "bgCarrierIcon", "combatIcon", "statusIconFont", "statusIconFontSize", "statusIconFontOutline"}, L["Icons"], "indicators_icons")', 1, true) ~= nil,
          "page: the copy button keeps all sixteen prefixes it owns")

    -- ☠ THE ONE WIDGET IN A PANE ON THIS PAGE THAT DID NOT REPAINT. A group
    -- reset, a Hold: Defaults or the undo of either writes the db behind the
    -- widgets' backs and repaints them through DandersUI Sections'
    -- RefreshChildValues, which calls widget.refreshValue. GUI:CreateEditBox had
    -- none -- it repainted on OnShow only -- so a reset left sixteen boxes on this
    -- page showing the string the user had typed while the profile already held
    -- the default. This page is the first to mount edit boxes inside a pane,
    -- which is what surfaced it.
    local WIDGETS = options_file_source("GUI/SettingsWidgets.lua"):gsub("\r\n", "\n")
    local editbox = WIDGETS:match("function GUI:CreateEditBox%(.-\n(.-)\nend\n")
    check(editbox ~= nil, "editbox: the factory is locatable")
    check(editbox ~= nil and editbox:find("frame.refreshValue = RefreshDisplay", 1, true) ~= nil,
          "editbox: it answers to the group-wide value sweep")
    check(editbox ~= nil and editbox:find('frame:SetScript("OnShow", RefreshDisplay)', 1, true) ~= nil,
          "editbox: ...through the same body OnShow already used, rather than a second copy")
end
