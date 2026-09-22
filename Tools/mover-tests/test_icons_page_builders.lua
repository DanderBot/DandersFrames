local NS = ...

-- ============================================================
-- ICONS PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Modules.lua
-- ------------------------------------------------------------
-- Indicators > Icons is the biggest page in the addon: one shared typography
-- block plus THIRTEEN status icons, each carrying the same Settings /
-- Appearance / Position trio (AFK adds a fourth box for its timer).
--
-- ☠ THE SHAPE IS WRITTEN ONCE AND PARAMETERISED, WHICH CHANGES WHAT A CENSUS
-- IS. Every other page is pinned by reading its per-group builder bodies control
-- by control. Here there are only FIVE bodies for forty-one groups: three shared
-- ones whose labels and keys are `spec` fields, plus the two genuinely bespoke
-- blocks (Role's Settings and AFK's Timer Text). So this file pins BOTH HALVES
-- and they are only evidence together:
--   (a) the five builder bodies, control by control, in order -- the SHAPE;
--   (b) all thirteen SPEC tables, field by field -- the VALUES the shape is
--       given.
-- Shape x specs is the whole page. A control dropped from a builder fails (a); a
-- key or label typo'd in one icon fails (b).
--
-- MODERN is the Debuff Bar's collapsible-card design with ONE CARD PER ICON:
-- the icon's three builders mounted one after another into the same card, two
-- per row when it is wide enough, captions dim, the icon's Enable as the card's
-- header tick (Role has none), every card pinnable. Icon Text Settings is a card
-- of its own at the top of column 1, and AFK's Timer Text is a card of its own
-- under the AFK card. Header previews stay classic-only.
--
--   column 1   Icon Text Settings, Role, Leader, Target Marker, Ready Check,
--              Ping, Summon
--   column 2   BG Carrier, Combat, Resurrection, Phased, AFK (+ Timer Text),
--              Vehicle, Raid Role
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
--   ✓ each card's column, stable collapse key, summary, tick and pin; that
--     there is one checkbox per setting; the two opt-ins; that no count,
--     footer or plate survives.
--   ✗ nothing about how any of it LOOKS or behaves in the client -- the folding,
--     the two-per-row flow, the greys and the summaries are read in game.
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

-- The page, scoped by its own two ends: Modules.lua holds several pages, and a
-- bare 280 box on one of the others is not this pass's business.
local PAGE
do
    local a = SRC:find("BuildPage(pageIcons, function(self, db, Add, AddSpace, AddSyncPoint)", 1, true)
    local b = SRC:find("BuildPage(pageHighlights, function(self, db, Add, AddSpace, AddSyncPoint)", 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Icons page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- ============================================================
-- 1. THE SHARED MACHINERY, THE SHAPE SAID ONCE, AND THE POPOUT FURNITURE GONE
-- ============================================================
print("-- Icons page: the shared machinery, and one builder for thirteen icons")
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

    -- ☠ THE ROW FURNITURE IS GONE ENTIRELY, not half-gone: rows, control rows,
    -- panes on a plate, claims, counts, footers, hoisted search repairs, the
    -- section bands, the index-1 repair and the per-row verdicts were all
    -- PopoutRow furniture.
    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "tools.PopoutContent(", "tools.ClaimKeys(",
                            "tools.WireModifiedTick(", "tools.WireFooter(",
                            "tools.RegisterHoistedToggle(", "tools.RegisterControlRow(",
                            "GUI:CreateControlRow(", "GatePaneFirstChild", "footerStrip",
                            "inline = true", "popout = true,", "_COUNT = ", "count =",
                            "settingsCount", "controlRow = ", "SectionBand", "ApplyIconGroup",
                            "tools.BandWidth" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end

    -- ---- the section helpers: forwards to the shared ones, with both opt-ins
    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: every card goes through the shared helper, two per row and dim captions")
    check(PAGE:find("local function CloseSection(band)\n            tools.CloseSection(Add, band)\n        end", 1, true) ~= nil,
          "sections: ...and closes through the shared helper too")

    -- ☠ THE WHOLE POINT OF THIS PAGE'S SHAPE. Thirteen icons, and exactly ONE
    -- declaration of each of the three shared builders, ONE of the mount that
    -- drives both layouts, and ONE of the card it builds in Modern.
    for _, b in ipairs({ "BuildIconSettingsGroup", "BuildIconAppearanceGroup",
                         "BuildIconPositionGroup", "MountIcon", "MountIconCard" }) do
        local n = 0
        for _ in PAGE:gmatch("local function " .. b .. "%(") do n = n + 1 end
        eq(n, 1, "shape: " .. b .. " is declared exactly once")
    end
    local mounts = 0
    for _ in PAGE:gmatch("MountIcon%(%{") do mounts = mounts + 1 end
    eq(mounts, 13, "shape: all thirteen icons are mounted through the one function")

    -- ---- the classic half, untouched ---------------------------------
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 4, "classic: four bare 280 boxes in the source, and they are the classic branch's own")
    check(PAGE:find('return Add(GUI:CreateCollapsibleSection(self.child, label, false, 280), 36, 1)', 1, true) ~= nil,
          "classic: keeps the 280 section header in column 1, at slot 36")
    check(PAGE:find('textSection = Add(GUI:CreateCollapsibleSection(self.child, L["Icon Text Settings"], false, 280), 36, 1)', 1, true) ~= nil,
          "classic: keeps the Icon Text Settings section exactly as it was")
    local sections = 0
    for _ in PAGE:gmatch("GUI:CreateCollapsibleSection%(") do sections = sections + 1 end
    eq(sections, 2, "classic: two direct section builds, both classic's (Modern builds cards through the helper)")
    for _, g in ipairs({ "settingsGroup", "extraGroup", "appearanceGroup", "positionGroup" }) do
        check(PAGE:find("section:RegisterChild(" .. g .. ")", 1, true) ~= nil,
              "classic: the " .. g .. " is registered to its section")
        check(PAGE:find("Add(" .. g .. ", nil, 1)", 1, true) ~= nil,
              "classic: ...in column 1, where it always was")
    end
    for _, h in ipairs({ "Settings", "Appearance", "Position" }) do
        check(PAGE:find('GUI:CreateHeader(self.child, L["' .. h .. '"]), GUI.RowHeight.sectionHeader', 1, true) ~= nil,
              "classic: the box keeps its own " .. h .. " header")
    end
    check(PAGE:find("GUI:CreateHeader(self.child, spec.extraGroup.label), GUI.RowHeight.sectionHeader", 1, true) ~= nil,
          "classic: ...and the extra box takes its header from the spec")

    -- ☠ MODERN TAKES ITS OWN ROAD BEFORE classic's section is built, so the
    -- classic arm is reached only in classic and no Modern card is ever a
    -- classic section with a preview.
    local mount = builderBody("MountIcon")
    local early = mount:find("if not classicLayout then\n                MountIconCard(spec)\n                return\n            end", 1, true)
    local sectionAt = mount:find("local section = AddSection(spec.section)", 1, true)
    check(early and sectionAt and early < sectionAt,
          "classic: Modern returns into MountIconCard before the classic section and preview are built")
end

-- ============================================================
-- 2. THE CARDS
-- ============================================================
print("-- Icons page: one card per icon")
do
    local card = builderBody("MountIconCard"):gsub("%s+", " ")

    -- ---- the card is the icon's three builders, in classic's box order ----
    check(card:find("local settingsBuild = spec.settings or BuildIconSettingsGroup", 1, true) ~= nil,
          "card: Role's own Settings builder still replaces the shared one")
    check(card:find("local function BuildIconCard(tools2) settingsBuild(tools2, spec) BuildIconAppearanceGroup(tools2, spec) BuildIconPositionGroup(tools2, spec) end", 1, true) ~= nil,
          "card: the three builders, reused with the icon's spec, in the order the boxes stand")

    -- ---- key, column, summary, pin, tick ---------------------------------
    check(card:find('local band = OpenSection(spec.section, "icons_" .. spec.key, spec.col, IconCardSummary(spec), nil, nil, BuildIconCard, toggle)', 1, true) ~= nil,
          "card: titled for the icon, keyed icons_<db prefix>, in its spec's column, pinnable from its own builder, ticked where it has an enable")
    check(card:find("BuildIconCard({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end, hoistToggle = spec.enableKey ~= nil, })", 1, true) ~= nil,
          "card: mounts the builders as classic does, plus hoistToggle where the header carries the enable")
    check(card:find("if spec.enableKey then toggle = { db = db, key = spec.enableKey, label = spec.enableLabel, tooltip = spec.enableTooltip,", 1, true) ~= nil,
          "tick: the header tick is the icon's own enable, under its own label and tooltip -- none for Role")
    check(card:find("onChanged = function() if spec.onEnable then spec.onEnable() end self:RefreshStates() tools.ReflowMounted() end,", 1, true) ~= nil,
          "tick: ...committing what the in-body checkbox ran, a state pass and a panel repaint")
    check(card:find("RefreshCurrentPage", 1, true) == nil and PAGE:find("GUI:RefreshCurrentPage", 1, true) == nil,
          "tick: ...never a page rebuild, anywhere on the page")
    check(PAGE:find("if spec.enableKey and not tools2.hoistToggle then", 1, true) ~= nil,
          "tick: the Settings builder skips its in-body enable when the header carries it -- one checkbox per setting")

    -- ---- the grey --------------------------------------------------------
    check(PAGE:find('spec.gate = spec.enableKey and function(d) return not (d or db)[spec.enableKey] end or nil', 1, true) ~= nil,
          "grey: the icon's gate is derived from its own enable key, once")
    local gates = 0
    for _ in PAGE:gmatch("group%.disableChildrenOn = spec%.gate") do gates = gates + 1 end
    eq(gates, 4, "grey: the group gate lives inside the builders (settings, appearance, position, timer), so a card greys as its boxes did")

    -- ---- AFK's Timer Text, a card of its own -------------------------------
    check(card:find("local function BuildExtraCard(tools2) extra.build(tools2, spec) end", 1, true) ~= nil,
          "extra: the fourth box's own builder is reused, handed the icon's spec")
    check(card:find('band = OpenSection(RowTitle(spec.section, extra.label), "icons_" .. spec.key .. "_extra", spec.col, extra.summary, spec.gate, extra.hideOn, BuildExtraCard)', 1, true) ~= nil,
          "extra: titled <Icon> -- <box>, in the icon's column, printing its own summary, dimming with the icon, hiding on the box's own gate, pinnable")
    check(PAGE:find('local function RowTitle(section, part) return format("%s \\226\\128\\148 %s", section, part) end', 1, true) ~= nil,
          "extra: the long title is composed from two strings that are already translated")
    local cardAt  = card:find("CloseSection(band) local extra", 1, true)
    check(cardAt ~= nil, "extra: ...and it opens after the icon's own card is closed, so it sits right under it")

    -- ---- Icon Text Settings ---------------------------------------------
    check(PAGE:find('local band = OpenSection(L["Icon Text Settings"], "icons_text", 1, IconTextSummary,\n                nil, nil, BuildIconTextGroup)', 1, true) ~= nil,
          "text: Icon Text Settings is a card at the top of column 1, pinnable")
    check(PAGE:find("BuildIconTextGroup({\n                group = band, parent = self.child,", 1, true) ~= nil,
          "text: ...its builder is handed the card's group")
    check(builderBody("BuildIconTextGroup"):find("add = function(widget, height) return group:AddWidget(widget, height) end", 1, true) ~= nil,
          "text: ...and adds into a group when no loose `add` is given (classic still passes one)")

    -- ---- the order and the columns ---------------------------------------
    local stripAt = PAGE:find('Add(tools.SectionControls(self.child), 24, "both")', 1, true)
    local textAt  = PAGE:find('OpenSection(L["Icon Text Settings"]', 1, true)
    local firstIcon = PAGE:find("MountIcon({", 1, true)
    check(stripAt and textAt and firstIcon and stripAt < textAt and textAt < firstIcon,
          "order: Expand All / Collapse All first, spanning both columns, then Icon Text, then the icons")

    -- ☠ NO HEADER PREVIEWS ON A CARD. The preview wiring is classic's alone.
    check(card:find("WireStatusPreview", 1, true) == nil and card:find("onSection", 1, true) == nil
          and card:find("afterMount", 1, true) == nil,
          "preview: a card never wires a header preview")
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
        -- the enable tick, suppressed when the card's header carries it
        { "checkbox", "(none)",       "(none)", 30 },
        -- the one explanatory label some icons carry
        { "label",    "(none)",       "(none)", nil },
        -- the Show as Text block: the tick, one edit box per status string, and
        -- the colour, which comes through the page's own AddTextColor helper and
        -- is asserted separately below
        { "checkbox", "Show as Text", "(none)", 30 },
        { "editbox",  "(none)",       "(none)", 55 },
    }, "settings builder")
    check(PAGE:find('AddTextColor(group, parent, L["Text Color"], spec.key .. "TextColor", spec.showTextKey)', 1, true) ~= nil,
          "settings builder: the text colour is mounted through the page's own helper")
    check(PAGE:find("local function AddTextColor(group, parent, label, key, showKey)", 1, true) ~= nil,
          "settings builder: ...which takes its parent, because a pinned panel's is not self.child")
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
-- pre-change source, plus the Modern card's column. This is where a mistyped
-- key or a swapped label fails.
-- ============================================================
local ICONS = {
    { section = "Role Icon", key = "roleIcon", id = "role", col = 1,
      settingsBuilder = "BuildRoleSettingsGroup",
      summary = "RoleSettingsSummary", hideInCombat = "Hide In Combat" },
    { section = "Leader Icon", key = "leaderIcon", id = "leader", col = 1,
      enableKey = "leaderIconEnabled", enableLabel = "Enable Leader Icon",
      hideInCombat = "Hide in Combat" },
    { section = "Target Marker Icon", key = "raidTargetIcon", id = "raidTarget", col = 1,
      enableKey = "raidTargetIconEnabled", enableLabel = "Enable Target Marker Icon",
      hideInCombat = "Hide in Combat" },
    { section = "Ready Check Icon", key = "readyCheckIcon", id = "readyCheck", col = 1,
      enableKey = "readyCheckIconEnabled", enableLabel = "Enable Ready Check Icon",
      hideInCombat = "Hide in Combat",
      after = { { "slider", "Persist (seconds)", "readyCheckIconPersist", 55 } } },
    { section = "Ping Icon", key = "pingIcon", id = "ping", col = 1,
      enableKey = "pingIconEnabled", enableLabel = "Enable Ping Icon",
      tooltip = "Shows a group member's ping on the frame of the unit they pinged.",
      hideInCombat = "Hide in Combat" },
    { section = "Summon Icon", key = "summonIcon", id = "summon", col = 1,
      enableKey = "summonIconEnabled", enableLabel = "Enable Summon Icon",
      showTextKey = "summonIconShowText", hideInCombat = "Hide in Combat",
      texts = { { "Pending Text", "summonIconTextPending" },
                { "Accepted Text", "summonIconTextAccepted" },
                { "Declined Text", "summonIconTextDeclined" } } },
    { section = "BG Carrier Icon", key = "bgCarrierIcon", col = 2,
      enableKey = "bgCarrierIconEnabled", enableLabel = "Enable BG Carrier Icon",
      note = "Shows on a friendly party/raid member carrying a battleground objective (flag, orb). Only active inside battlegrounds.",
      noteHeight = 44, showTextKey = "bgCarrierIconShowText",
      texts = { { "Carrier Text", "bgCarrierIconText" } } },
    { section = "Combat Icon", key = "combatIcon", col = 2,
      enableKey = "combatIconEnabled", enableLabel = "Enable Combat Icon",
      note = "Shows crossed swords on a party/raid member who is in combat.", noteHeight = 44 },
    { section = "Resurrection Icon", key = "resurrectionIcon", id = "resurrection", col = 2,
      enableKey = "resurrectionIconEnabled", enableLabel = "Enable Resurrection Icon",
      showTextKey = "resurrectionIconShowText",
      texts = { { "Casting Text", "resurrectionIconTextCasting" } } },
    { section = "Phased Icon", key = "phasedIcon", id = "phased", col = 2,
      enableKey = "phasedIconEnabled", enableLabel = "Enable Phased Icon",
      showTextKey = "phasedIconShowText", hideInCombat = "Hide in Combat",
      texts = { { "Status Text", "phasedIconText" } },
      after = { { "checkbox", "Show LFG Eye for Cross-Instance", "phasedIconShowLFGEye", 30 } } },
    { section = "AFK Icon", key = "afkIcon", id = "afk", col = 2,
      enableKey = "afkIconEnabled", enableLabel = "Enable AFK Icon",
      showTextKey = "afkIconShowText", hideInCombat = "Hide in Combat",
      texts = { { "Status Text", "afkIconText" } },
      after = { { "checkbox", "Show Timer", "afkIconShowTimer", 30 },
                { "label", "In Text mode the timer joins the status text and uses its font, colour and position.", "(none)", 40 } },
      extra = { label = "Timer Text", builder = "BuildAFKTimerGroup",
                summary = "AFKTimerSummary", hideOn = "AFKTimerHidden" } },
    { section = "Vehicle Icon", key = "vehicleIcon", id = "vehicle", col = 2,
      enableKey = "vehicleIconEnabled", enableLabel = "Enable Vehicle Icon",
      showTextKey = "vehicleIconShowText", hideInCombat = "Hide in Combat",
      texts = { { "Status Text", "vehicleIconText" } } },
    { section = "Raid Role Icon (MT/MA)", key = "raidRoleIcon", id = "raidRole", col = 2,
      enableKey = "raidRoleIconEnabled", enableLabel = "Enable Raid Role Icon",
      showTextKey = "raidRoleIconShowText", hideInCombat = "Hide in Combat",
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
    -- section or card where it stands, so this also pins the page's reading
    -- order -- which is the one-column fold's order too.
    check(spec:find('section = L["' .. want.section .. '"], col = ' .. want.col .. ",", 1, true) ~= nil,
          tag .. ": spec " .. i .. " is this icon's, in this position, carded in column " .. want.col)
    check(spec:find('key = "' .. want.key .. '"', 1, true) ~= nil,
          tag .. ": ...with its db prefix, which is also its card's fold key")
    if want.id then
        check(spec:find('id = "' .. want.id .. '"', 1, true) ~= nil,
              tag .. ": ...and the lightweight render tag its own callbacks want")
    else
        -- ☠ NO TAG MEANS NO LIGHTWEIGHT PATH. BG Carrier and Combat repaint
        -- through DF:UpdateAllFramesStatusIcons for scale, alpha, frame level and
        -- position alike.
        check(spec:find("id = ", 1, true) == nil,
              tag .. ": ...and NO render tag, so it repaints through the status-icon pass")
    end

    if want.enableKey then
        check(spec:find('enableKey = "' .. want.enableKey .. '"', 1, true) ~= nil,
              tag .. ": the master switch -- the card's header tick -- is named")
        check(spec:find('enableLabel = L["' .. want.enableLabel .. '"]', 1, true) ~= nil,
              tag .. ": ...with the label the checkbox always drew")
    else
        -- ☠ ROLE IS THE ONE ICON WITH NO ENABLE. Three per-role Show toggles and
        -- no master boolean, so its card carries no tick and greys with nothing.
        check(spec:find("enableKey", 1, true) == nil,
              tag .. ": has no master switch at all, so its card has no tick")
    end
    if want.settingsBuilder then
        check(spec:find("settings = " .. want.settingsBuilder, 1, true) ~= nil,
              tag .. ": swaps in its own Settings builder")
        check(spec:find("summary = " .. want.summary, 1, true) ~= nil,
              tag .. ": ...and its own Settings summary")
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
        check(spec:find('label = L["' .. want.extra.label .. '"], build = ' .. want.extra.builder .. ",", 1, true) ~= nil,
              tag .. ": its fourth box is asked for by name")
        check(spec:find("summary = " .. want.extra.summary, 1, true) ~= nil,
              tag .. ": ...with a summary of its own")
        check(spec:find("hideOn = " .. want.extra.hideOn, 1, true) ~= nil,
              tag .. ": ...and the gate the box always carried")
    end
end

-- ============================================================
-- 5. THE PREVIEWS, CLASSIC'S ALONE
-- ============================================================
print("-- Icons page: the header previews stay in classic")
do
    check(PAGE:find("local function WireStatusPreview(section, opts)", 1, true) ~= nil,
          "preview: the status-icon preview wiring is still on the page")
    check(PAGE:find("if spec.preview then WireStatusPreview(section, spec.preview) end", 1, true) ~= nil,
          "preview: ...and every icon's opts come out of its own spec")
    local previews = 0
    for _ in PAGE:gmatch("preview = {") do previews = previews + 1 end
    eq(previews, 12, "preview: twelve status icons declare one")
    check(PAGE:find("local function UpdateRolePreview()", 1, true) ~= nil,
          "preview: ...and Role keeps its own, which reads three toggles rather than one")
    check(PAGE:find("if spec.onSection then spec.onSection(section) end", 1, true) ~= nil,
          "preview: ...reaching its section through the spec")
    check(PAGE:find("afterMount = UpdateRolePreview", 1, true) ~= nil,
          "preview: ...and painted once at build, as it always was")
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
-- 6. THE SUMMARIES
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
    for _, s in ipairs({ "IconSettingsSummary", "IconAppearanceSummary", "IconPositionSummary", "IconCardSummary" }) do
        check(PAGE:find("local function " .. s .. "(spec)", 1, true) ~= nil,
              "summary: " .. s .. " is written once and given the icon's spec")
    end
    -- A card's corner is its three summaries, in the card's order, each only
    -- when it has something to say.
    local cs = builderBody("IconCardSummary"):gsub("%s+", " ")
    check(cs:find("local fns = { spec.summary or IconSettingsSummary(spec), IconAppearanceSummary(spec), IconPositionSummary(spec) }", 1, true) ~= nil,
          "summary: a card prints settings, looks and place -- Role's own settings summary where it has one")
    check(cs:find('if s ~= "" then parts[#parts + 1] = s end', 1, true) ~= nil
      and cs:find('if not d then return "" end', 1, true) ~= nil
      and cs:find("return Join(parts)", 1, true) ~= nil,
          "summary: ...skipping the silent ones, joined with the shared separator, safe on an absent db")
    check(PAGE:find('local anchor = anchorOptions[d[spec.key .. "Anchor"]]', 1, true) ~= nil,
          "summary: the position names the anchor from the dropdown's own table")
    check(PAGE:find("local style = roleStyleOptions[d.roleIconStyle]", 1, true) ~= nil,
          "summary: ...and Role names the style from its own")
    check(PAGE:find("if scale and scale ~= 1 then", 1, true) ~= nil,
          "summary: a default scale is not printed back at the reader")
    check(PAGE:find("if alpha and alpha < 1 then", 1, true) ~= nil,
          "summary: ...nor a default alpha")
end

-- ============================================================
-- 7. THE PAGE'S OWN FURNITURE, AND THE EDIT BOX REPAIR
-- ============================================================
print("-- Icons page: the furniture, and the value sweep an edit box answers")
do
    check(PAGE:find('CreateCopyButton(self.child, {"roleIcon", "leaderIcon", "raidTargetIcon", "readyCheckIcon", "pingIcon", "summonIcon", "resurrectionIcon", "phasedIcon", "afkIcon", "vehicleIcon", "raidRoleIcon", "bgCarrierIcon", "combatIcon", "statusIconFont", "statusIconFontSize", "statusIconFontOutline"}, L["Icons"], "indicators_icons")', 1, true) ~= nil,
          "page: the copy button keeps all sixteen prefixes it owns")

    -- ☠ A reset, a Hold: Defaults or an undo writes the db behind the widgets'
    -- backs and repaints them through DandersUI Sections' RefreshChildValues,
    -- which calls widget.refreshValue -- and the sixteen edit boxes on this page
    -- need one to follow it. It is also what lets an edit box share a row inside
    -- a card: only bound controls (those with refreshValue) pair up.
    local WIDGETS = options_file_source("GUI/SettingsWidgets.lua"):gsub("\r\n", "\n")
    local editbox = WIDGETS:match("function GUI:CreateEditBox%(.-\n(.-)\nend\n")
    check(editbox ~= nil, "editbox: the factory is locatable")
    check(editbox ~= nil and editbox:find("frame.refreshValue = RefreshDisplay", 1, true) ~= nil,
          "editbox: it answers to the group-wide value sweep")
    check(editbox ~= nil and editbox:find('frame:SetScript("OnShow", RefreshDisplay)', 1, true) ~= nil,
          "editbox: ...through the same body OnShow already used, rather than a second copy")
end
