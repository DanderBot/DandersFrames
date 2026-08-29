local NS = ...

-- ============================================================
-- DISPEL OVERLAY PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Modules.lua
-- ------------------------------------------------------------
-- Auras > Dispel Overlay is the first page in the Modules file to convert, and
-- the first anywhere whose page gate was written as a HIDE rather than a grey.
-- FIVE groups: four become feature rows, and Display -- which holds one checkbox
-- -- becomes a CONTROL ROW.
--
--   "Content" band      Settings (hoists dispelOverlayEnabled, the PAGE gate).
--   "Appearance" band   Pulse Overlay (the control row), Dispel Symbol (hoists
--                       dispelShowIcon), Border (hoists dispelShowBorder) and
--                       Gradient (hoists dispelShowGradient).
--
-- ☠ THE PAGE GATE IS SAID TWICE, AND THE TWO LAYOUTS SAY IT DIFFERENTLY. Classic
-- HIDES every dependent control and four of the five boxes, and keeps doing
-- exactly that -- every hideOn below is asserted where it always was. The popout
-- layout cannot: hiding a row's whole contents leaves a live row over an empty
-- panel, and hiding the rows leaves the "Appearance" header standing over
-- nothing. So it says the gate ONCE, as a GREY on the row, which is what every
-- other converted page says and what this page's own source already states as
-- the addon-wide convention for a boolean toggle.
--
-- The one seam that carries it is GateHide(tools2, w[, also]): classic gets the
-- widget's hideOn, the pane gets nothing -- except where the widget also carries
-- its OWN variant gate, which survives in both layouts (one widget, Show On
-- Current Health Only, and it is checked by name below).
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
--     same builder into the same 280 box, in the same column, in the same order.
--   ✓ the wiring every row must have: the shared machinery rather than a copy of
--     it, the hoisted ticks, the declared counts, the claim/tick/footer trio and
--     the two bands.
--   ✗ nothing about how any of it LOOKS or behaves in the client -- the panels,
--     the greys and the summaries are read by eye and by the in-game checklist.
-- ============================================================

-- ⚠ NORMALISED TO LF UP FRONT. This page file ships CRLF (the companion's files
-- are mixed per file), and a plain multi-line `find` for source text would miss
-- every one of them otherwise. Nothing here asserts about line endings.
local SRC = options_file_source("GUI/Pages/Modules.lua"):gsub("\r\n", "\n")

-- ---- the census reader (the Missing Buffs page's, plus this page's link) ----
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateSeparator = "separator", CreateButton = "button",
    CreateGrowthControl = "growth", CreateTextureDropdown = "texturedropdown",
    CreateTextControls = "textcontrols", CreateBorderControls = "bordercontrols",
    CreateDurationFormatControls = "durationformat", CreateInfoBanner = "banner",
    -- The shared cross-link to the account-wide dispel palette. Not a setting --
    -- it has no db key at all -- but it IS a control the pane mounts, so the
    -- reader has to see it or the declared count would look one short.
    CreateDispelColorsPageLink = "pagelink",
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
    local a = SRC:find('BuildPage(pageDispel, function(self, db, Add, AddSpace, AddSyncPoint)', 1, true)
    local b = SRC:find('CreateCategory("profiles", L["Profiles"])', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Dispel Overlay page builder is locatable by its own ends")
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
local function checkShared(builder, rowLabel, boxHeader, column, boxHides)
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
        -- ...and the box still HIDES with the overlay, which is what classic has
        -- always done and what the popout layout deliberately does not copy.
        --
        -- ⚠ EXCEPT THE SETTINGS BOX, which never hid: it holds the gate's own
        -- tick, so hiding it would leave no way to switch the overlay back on --
        -- the same reason its ROW is the one that is not greyed.
        if boxHides then
            check(PAGE:find(box .. ".hideOn = HideDispelOptions", 1, true) ~= nil,
                  rowLabel .. ": ...and still carries the box's own hide gate")
        else
            check(PAGE:find(box .. ".hideOn", 1, true) == nil,
                  rowLabel .. ": ...and never hid, because it holds the gate's own tick")
        end
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
-- 1. THE PAGE TAKES THE SHARED MACHINERY, AND ITS VOCABULARY IS AT PAGE SCOPE
-- ============================================================
print("-- Dispel Overlay page: the shared popout machinery and the page-scope vocabulary")
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

    -- ---- the two bands ------------------------------------------------
    for _, b in ipairs({ "contentBand", "appearanceBand" }) do
        check(PAGE:find(b .. " = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
              "bands: " .. b .. " is chromeless, at the width the layout pass will give it")
    end
    for _, pair in ipairs({ { "contentBand", "Content" }, { "appearanceBand", "Appearance" } }) do
        check(PAGE:find(pair[1] .. ':AddWidget(GUI:CreateHeader(self.child, L["' .. pair[2] .. '"]), 40)', 1, true) ~= nil,
              "bands: ..." .. pair[1] .. " names its section with the locale's own " .. pair[2])
    end
    -- ☠ NEITHER HEADER CAN BE LEFT OVER NOTHING, which is the whole reason the
    -- popout layout greys instead of hiding. No row and no control row on this
    -- page declares a hideOn at all.
    for _, r in ipairs({ "settingsRow", "animateRow", "iconRow", "borderRow", "gradientRow" }) do
        check(PAGE:find(r .. ".hideOn", 1, true) == nil,
              "bands: " .. r .. " never hides, so both band headers always stand over something")
    end

    -- ---- the vocabulary, at PAGE scope, declared exactly once ---------
    for _, v in ipairs({ "dispelIndicatorOptions", "iconPositions", "gradientStyles", "blendModes" }) do
        local decls = 0
        for _ in PAGE:gmatch("local " .. v .. " = {") do decls = decls + 1 end
        eq(decls, 1, "vocab: " .. v .. " is declared exactly once, at page scope")
    end
    check(PAGE:find('["TOPRIGHT"]= L["Top Right"]', 1, true) ~= nil,
          "vocab: ...and iconPositions is the same table the Symbol Position dropdown has always offered")
    check(PAGE:find('["EDGE"]= L["Edge Glow (All Sides)"]', 1, true) ~= nil,
          "vocab: ...and gradientStyles the same one Gradient Position has always offered")

    -- ⚠ ABOVE EVERY BUILDER. A builder is a closure and captures the upvalue that
    -- exists when it is created, so one declared above these would see nil.
    local vocabAt = PAGE:find("local dispelIndicatorOptions = {", 1, true)
    local lastVocab = PAGE:find("local blendModes = {", 1, true)
    check(vocabAt ~= nil and lastVocab ~= nil and vocabAt < lastVocab, "vocab: the tables are declared as one block")
    for _, b in ipairs({ "BuildDispelSettingsGroup", "BuildDispelIconGroup",
                         "BuildDispelBorderGroup", "BuildDispelGradientGroup" }) do
        local at = PAGE:find("local function " .. b .. "(tools2)", 1, true)
        check(at ~= nil and lastVocab ~= nil and lastVocab < at,
              "vocab: " .. b .. " is declared after it, so it closes over the real tables")
    end

    -- The page's own gates and applies are still named once and shared by both
    -- layouts.
    for _, g in ipairs({ "HideIfDisabled", "ApplyDispelSettings", "InvalidateCurves",
                         "OnDispelTypeChanged", "DispelOffRow", "GateHide" }) do
        local n = 0
        for _ in PAGE:gmatch("local function " .. g .. "%(") do n = n + 1 end
        eq(n, 1, "vocab: " .. g .. " is declared exactly once")
    end
    check(PAGE:find("local HideDispelOptions = HideIfDisabled", 1, true) ~= nil,
          "vocab: ...and the alias the widget wiring reads is still the same function")
    for _, g in ipairs({ "DisableIfNoGradient", "DisableIfNoBorder", "DisableIfNoIcon" }) do
        local n = 0
        for _ in PAGE:gmatch("local " .. g .. " = function") do n = n + 1 end
        eq(n, 1, "vocab: " .. g .. " is declared exactly once, at page scope")
    end
end

-- ============================================================
-- 2. THE PAGE GATE -- a HIDE in classic, a GREY on the rows
-- ============================================================
print("-- Dispel Overlay page: the page gate, said twice")
do
    check(PAGE:find("local function DispelOffRow(d) return not (d or db).dispelOverlayEnabled end", 1, true) ~= nil,
          "gate: the page names the popout half of its gate once")

    -- Four objects greyed, and they are exactly the four groups classic hides.
    for _, row in ipairs({ "animateRow", "iconRow", "borderRow", "gradientRow" }) do
        check(PAGE:find(row .. ".disableOn = DispelOffRow", 1, true) ~= nil,
              "gate: " .. row .. " greys while the overlay is off")
    end
    -- ...and the one that carries the gate's own tick does not.
    check(PAGE:find("settingsRow.disableOn", 1, true) == nil,
          "gate: the Settings row is not greyed -- it carries the gate's own tick")

    -- ---- the classic half, unchanged ---------------------------------
    -- The four boxes still hide, and so does the one control the Display box had.
    for _, box in ipairs({ "displayGroup", "iconGroup", "borderGroup", "gradientGroup" }) do
        check(PAGE:find(box .. ".hideOn = HideDispelOptions", 1, true) ~= nil,
              "gate: classic still hides " .. box .. " with the overlay")
    end
    check(PAGE:find("animate.hideOn = HideDispelOptions", 1, true) ~= nil,
          "gate: ...and the Pulse Overlay checkbox inside the Display box")

    -- ---- the seam ----------------------------------------------------
    -- ☠ EVERY DEPENDENT CONTROL GOES THROUGH GateHide. A raw `w.hideOn =` inside
    -- a builder would hide that control in the PANE as well, which is the empty
    -- panel this whole arrangement exists to avoid.
    for _, b in ipairs({ "BuildDispelSettingsGroup", "BuildDispelIconGroup",
                         "BuildDispelBorderGroup", "BuildDispelGradientGroup" }) do
        local body = builderBody(b)
        check(body:find("GateHide(tools2,", 1, true) ~= nil,
              "gate: " .. b .. " states its hides through the seam")
        check(body:find(".hideOn", 1, true) == nil,
              "gate: ..." .. b .. " never writes a hideOn straight onto a widget")
    end
    check(PAGE:find("if tools2.popout then", 1, true) ~= nil,
          "gate: ...and the seam is the one place that asks which layout it is in")

    -- ⚠ ONE WIDGET CARRIES ITS OWN VARIANT GATE AS WELL, and that half survives
    -- in BOTH layouts: with the wash set to anything but Full Frame there is no
    -- current-health option to offer, whatever the overlay is doing.
    check(builderBody("BuildDispelGradientGroup")
            :find('GateHide(tools2, onHealthCheck, function(d) return d.dispelGradientStyle ~= "FULL" end)', 1, true) ~= nil,
          "gate: Show On Current Health Only keeps its own variant gate through the seam")

    -- ☠ NO GatePaneFirstChild ON THIS PAGE, and that is a fact about the gates
    -- rather than an omission. The index-1 repair exists because a group-level
    -- disableChildrenOn skips its first child (a header on a page box, a real
    -- control in a pane). Nothing here uses one: every grey is a per-widget
    -- disableOn, which DandersUI applies to index 1 like any other.
    check(PAGE:find("disableChildrenOn", 1, true) == nil,
          "gate: no group-level child gate, so no index-1 repair is needed")
    check(PAGE:find("GatePaneFirstChild", 1, true) == nil,
          "gate: ...and none is declared")
end

-- ============================================================
-- 3. THE PAGE REBUILD LIVES AND DIES IN THE CLASSIC-ONLY BRANCH
-- Classic has always paid for the gate with a whole-page rebuild. A pane must
-- not: a rebuild retires the row the user is clicking through, and the shared
-- helper's own prologue closes every open panel on the way in.
-- ============================================================
print("-- Dispel Overlay page: no page rebuild in the popout layout")
do
    local rebuilds = 0
    for _ in PAGE:gmatch("GUI:RefreshCurrentPage%(%)") do rebuilds = rebuilds + 1 end
    eq(rebuilds, 1, "rebuild: exactly one page rebuild left on the page")

    -- ...and it is inside the branch that only classic reaches.
    local body = builderBody("BuildDispelSettingsGroup")
    local hoistArm = body:match("if not tools2%.hoistToggle then(.-)\n            end")
    check(hoistArm ~= nil, "rebuild: the Enable checkbox is built behind the hoist guard")
    if hoistArm then
        check(hoistArm:find("GUI:RefreshCurrentPage()", 1, true) ~= nil,
              "rebuild: ...and the rebuild is inside it, where only classic goes")
    end

    -- Every popout mount declares itself as one; four rows, four mounts.
    local popouts = 0
    for _ in PAGE:gmatch("popout = true,") do popouts = popouts + 1 end
    eq(popouts, 4, "rebuild: all four popout mounts declare themselves as panes")

    -- The state pass a builder runs is the LAYOUT-AWARE one, never the page's.
    for _, b in ipairs({ "BuildDispelSettingsGroup", "BuildDispelIconGroup",
                         "BuildDispelBorderGroup", "BuildDispelGradientGroup" }) do
        check(builderBody(b):find("self:RefreshStates()", 1, true) == nil,
              "rebuild: " .. b .. " never reaches past its own tools2 for a state pass")
    end
end

-- ============================================================
-- 4. THE FOUR BUILDERS, CONTROL BY CONTROL
-- Every golden below is the census of the PRE-CHANGE source: same factories,
-- same L keys, same db keys, same slot heights, in the same order.
-- ============================================================
local DISPEL_SETTINGS = {
    { "checkbox", "Enable Dispel Overlay", "dispelOverlayEnabled",    30 },
    { "dropdown", "Show Overlay For",      "dispelOverlayDispelType", 55 },
    -- The Colors-page cross-link. No L label of its own (its text is built by
    -- the shared factory) and its slot height is an expression, so the reader
    -- sees neither -- but it IS one of the controls the pane mounts.
    { "pagelink", "(none)",                "(none)",                  nil },
}
local DISPEL_ICON = {
    { "checkbox", "Show Dispel Symbol", "dispelShowIcon",      30 },
    { "slider",   "Symbol Size",        "dispelIconSize",      55 },
    { "slider",   "Symbol Opacity",     "dispelIconAlpha",     55 },
    { "dropdown", "Symbol Position",    "dispelIconPosition",  55 },
    { "slider",   "Offset X",           "dispelIconOffsetX",   55 },
    { "slider",   "Offset Y",           "dispelIconOffsetY",   55 },
}
local DISPEL_BORDER = {
    { "checkbox", "Show Border",      "dispelShowBorder",  30 },
    { "slider",   "Border Thickness", "dispelBorderSize",  55 },
    { "slider",   "Border Inset",     "dispelBorderInset", 55 },
    { "slider",   "Border Opacity",   "dispelBorderAlpha", 55 },
}
local DISPEL_GRADIENT = {
    { "checkbox", "Show Gradient",                "dispelShowGradient",           30 },
    { "dropdown", "Gradient Position",            "dispelGradientStyle",          55 },
    { "checkbox", "Show On Current Health Only",  "dispelGradientOnCurrentHealth",30 },
    { "slider",   "Gradient Size",                "dispelGradientSize",           55 },
    { "slider",   "Gradient Opacity",             "dispelGradientAlpha",          55 },
    -- Frame Level is wrapped in SetFrameLevelTooltip, which the reader steps
    -- through: the factory underneath is still the slider it always was.
    { "slider",   "Frame Level",                  "dispelOverlayFrameLevel",      55 },
    { "dropdown", "Blend Mode",                   "dispelGradientBlendMode",      55 },
    { "checkbox", "Darken Behind Gradient",       "dispelGradientDarkenEnabled",  30 },
    { "slider",   "Darken Amount",                "dispelGradientDarkenAlpha",    55 },
}

-- ---- the four rows, every one of which hoists a tick ------------------
-- ⚠ AND EVERY ONE OF THEM TAKES A FOOTER, which is a decision about the KEYS
-- rather than the shape: every setting behind these four rows is a plain scalar
-- in the profile -- a boolean, a number, a string -- so Reset Group writes
-- VALUES. There is no table for it to replace and nothing downstream holding a
-- reference to one, which is what made the Buff Bar's filter row refuse.
local ROWS = {
    { builder = "BuildDispelSettingsGroup", label = "Settings", boxHeader = "Settings",
      golden = DISPEL_SETTINGS, countVar = "DISPEL_SETTINGS_COUNT", column = "1",
      row = "settingsRow", band = "contentBand", toggleKey = "dispelOverlayEnabled",
      toggleLabel = "Enable Dispel Overlay", commit = "OnDispelEnableToggle",
      summary = "DispelSettingsSummary", boxHides = false },
    { builder = "BuildDispelIconGroup", label = "Dispel Symbol", boxHeader = "Dispel Symbol",
      golden = DISPEL_ICON, countVar = "DISPEL_ICON_COUNT", column = "2",
      row = "iconRow", band = "appearanceBand", toggleKey = "dispelShowIcon",
      toggleLabel = "Show Dispel Symbol", commit = "OnDispelIconToggle",
      summary = "DispelIconSummary", boxHides = true },
    { builder = "BuildDispelBorderGroup", label = "Border", boxHeader = "Border",
      golden = DISPEL_BORDER, countVar = "DISPEL_BORDER_COUNT", column = "2",
      row = "borderRow", band = "appearanceBand", toggleKey = "dispelShowBorder",
      toggleLabel = "Show Border", commit = "OnDispelBorderToggle",
      summary = "DispelBorderSummary", boxHides = true },
    { builder = "BuildDispelGradientGroup", label = "Gradient", boxHeader = "Gradient",
      golden = DISPEL_GRADIENT, countVar = "DISPEL_GRADIENT_COUNT", column = "1",
      row = "gradientRow", band = "appearanceBand", toggleKey = "dispelShowGradient",
      toggleLabel = "Show Gradient", commit = "OnDispelGradientToggle",
      summary = "DispelGradientSummary", boxHides = true },
}

for _, g in ipairs(ROWS) do
    print("-- Dispel Overlay page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())
    checkShared(g.builder, g.label, g.boxHeader, g.column, g.boxHides)

    -- The hoist: a checkbox the page itself builds, skipped behind the flag
    -- because classic still needs it.
    check(body:find("if not tools2.hoistToggle then", 1, true) ~= nil,
          g.label .. ": the group's own toggle is skipped when the row has hoisted it")

    local declared = tonumber(PAGE:match("local " .. g.countVar .. "%s*=%s*(%d+)"))
    check(declared ~= nil, g.label .. ": the page declares the row's count in one place")

    local opts = rowOpts(g.label)
    check(opts:find('toggle%s*=%s*{%s*key%s*=%s*"' .. g.toggleKey .. '"%s*}') ~= nil,
          g.label .. ": the row's tick is the group's own enable key")
    check(opts:find("summary%s*=%s*" .. g.summary) ~= nil,
          g.label .. ": ...it declares a summary of its own")
    check(opts:find("count%s*=%s*" .. g.countVar) ~= nil,
          g.label .. ": ...and the declared count, not a literal")
    check(opts:find("onToggle%s*=%s*" .. g.commit) ~= nil,
          g.label .. ": ...and a commit that is not a page rebuild")

    check(PAGE:find("local " .. g.row .. " = " .. g.band .. ":AddWidget(GUI:CreatePopoutRow(", 1, true) ~= nil,
          g.label .. ": the row is mounted into the " .. g.band)

    -- ☠ THE COMMIT IS NOT A PAGE REBUILD.
    local commit = PAGE:match("local function " .. g.commit .. "%(%)(.-)\n            end")
    check(commit ~= nil, g.label .. ": the popout commit is a named function")
    if commit then
        check(commit:find("RefreshCurrentPage", 1, true) == nil,
              g.label .. ": ...and never rebuilds the page")
        check(commit:find("self:RefreshStates()", 1, true) ~= nil,
              g.label .. ": ...it re-runs the page's state pass instead")
        check(commit:find("tools.ReflowMounted()", 1, true) ~= nil,
              g.label .. ": ...and reflows the open panes")
        check(commit:find("ApplyDispelSettings()", 1, true) ~= nil,
              g.label .. ": ...and drives the overlay, which is what the suppressed tick did")
    end

    check(PAGE:find('tools.RegisterHoistedToggle(' .. g.row .. ', L["' .. g.toggleLabel .. '"], "' .. g.toggleKey .. '", ' .. g.commit .. ')', 1, true) ~= nil,
          g.label .. ": the hoisted toggle keeps its search entry")

    check(PAGE:find("tools.ClaimKeys(" .. g.row .. ", ", 1, true) ~= nil,
          g.label .. ": the row claims whatever the pane registered")
    check(PAGE:find("tools.WireModifiedTick(" .. g.row .. ")", 1, true) ~= nil,
          g.label .. ": ...its amber tick asks about exactly those keys")
    -- InvalidateCurves is ApplyDispelSettings with the colour curve dropped
    -- first: a reset can move an opacity, and every opacity on this page is
    -- baked into that curve.
    check(PAGE:find("tools.WireFooter(" .. g.row .. ", InvalidateCurves)", 1, true) ~= nil,
          g.label .. ": ...and Reset Group / Hold: Defaults push the change into the frames")
end

-- ============================================================
-- 5. THE COUNT ARITHMETIC
-- Each declared count is the builder's census less the tick the row hoisted.
-- ============================================================
print("-- Dispel Overlay page: the declared counts")
do
    local function declared(name) return tonumber(PAGE:match("local " .. name .. "%s*=%s*(%d+)")) end

    eq(declared("DISPEL_SETTINGS_COUNT"), #DISPEL_SETTINGS - 1,
       "counts: Settings is the census less the hoisted Enable tick")
    eq(declared("DISPEL_ICON_COUNT"), #DISPEL_ICON - 1,
       "counts: Dispel Symbol is the census less the hoisted Show Dispel Symbol")
    eq(declared("DISPEL_BORDER_COUNT"), #DISPEL_BORDER - 1,
       "counts: Border is the census less the hoisted Show Border")
    eq(declared("DISPEL_GRADIENT_COUNT"), #DISPEL_GRADIENT - 1,
       "counts: Gradient is the census less the hoisted Show Gradient")
end

-- ============================================================
-- 6. THE CONTROL ROW, THE BOXES AND THE PAGE'S OWN ORDER
-- ============================================================
print("-- Dispel Overlay page: the control row, the boxes and the order")
do
    -- ---- Display: one setting, so a control row -----------------------
    check(PAGE:find('local animateRow = appearanceBand:AddWidget(GUI:CreateControlRow(self.child, {', 1, true) ~= nil,
          "control row: Pulse Overlay is a control row, mounted into a band")
    check(PAGE:find('label     = L["Pulse Overlay"],', 1, true) ~= nil,
          "control row: ...named for its SETTING, not for the Display box it came out of")
    check(PAGE:find('kind      = "checkbox",', 1, true) ~= nil,
          "control row: ...and it is the checkbox the box held")
    check(PAGE:find("db        = tools.RowDB,", 1, true) ~= nil,
          "control row: ...bound through the function form, so a mode switch is followed")
    check(PAGE:find('tools.RegisterControlRow(animateRow, "checkbox", "dispelAnimate", false, ApplyDispelSettings)', 1, true) ~= nil,
          "control row: ...and it is registered with search, with the callback the classic tick carried")
    -- A control row offers no footer and no amber tick -- there is no group
    -- behind it to reset.
    check(PAGE:find("tools.WireFooter(animateRow", 1, true) == nil,
          "control row: no footer -- a control row carries a setting, not a group")
    check(PAGE:find("tools.WireModifiedTick(animateRow", 1, true) == nil,
          "control row: ...and no group tick either")
    -- The band header the box's own header became.
    check(PAGE:find('GUI:CreateHeader(self.child, L["Display"])', 1, true) ~= nil,
          "control row: the Display header survives in classic, on the box it always titled")

    -- ---- five bare 280 boxes left, all inside a classicLayout arm ----
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 5, "boxes: five bare 280 boxes left, and they are the classic branch's own")
    check(PAGE:find("280, tools", 1, true) == nil,
          "boxes: no stay-inline 280 box is left on the page")
    check(PAGE:find("bandStyle", 1, true) == nil,
          "boxes: the band skin is never restated as a literal (this page needs none)")

    -- ---- the Add order ------------------------------------------------
    local a = PAGE:find('Add(contentBand, nil, "both")', 1, true)
    local b = PAGE:find('Add(appearanceBand, nil, "both")', 1, true)
    check(a and b and a < b, "order: the two bands span both columns, in reading order")

    -- ---- the page's own furniture is untouched -------------------------
    check(PAGE:find('CreateCopyButton(self.child, {"dispel"}, L["Dispel Overlay"], "auras_dispel")', 1, true) ~= nil,
          "page: the copy button keeps the prefix it owns")
    check(PAGE:find('{pageId = "auras_debuffs", label = L["Debuff Bar"]}', 1, true) ~= nil,
          "page: ...and the See Also block still points at the Debuff Bar")
    check(PAGE:find('{pageId = "indicators_highlights", label = L["Highlights"]}', 1, true) ~= nil,
          "page: ...and at Highlights")
end

-- ============================================================
-- 7. THE SUMMARIES
-- Read by eye in the client; what is asserted here is that each one exists, is
-- declared once, joins with the sweep's separator and reads the same tables the
-- controls behind it offer -- so a row cannot say one thing while its dropdown
-- says another.
-- ============================================================
print("-- Dispel Overlay page: the summaries")
do
    check(PAGE:find('local function Join(parts) return table.concat(parts, " \\194\\183 ") end', 1, true) ~= nil,
          "summary: the sweep's separator is named once")
    for _, s in ipairs({ "DispelSettingsSummary", "DispelIconSummary",
                         "DispelBorderSummary", "DispelGradientSummary" }) do
        local n = 0
        for _ in PAGE:gmatch("local function " .. s .. "%(d%)") do n = n + 1 end
        eq(n, 1, "summary: " .. s .. " is declared exactly once")
        local body = PAGE:match("local function " .. s .. "%(d%)(.-)\n        end")
        check(body ~= nil and body:find("Join(parts)", 1, true) ~= nil,
              "summary: ..." .. s .. " joins with the shared separator")
        check(body ~= nil and body:find("if not d then return \"\" end", 1, true) ~= nil,
              "summary: ..." .. s .. " answers an absent db rather than erroring on it")
    end
    -- The two that print a WORD read it out of the dropdown's own table.
    check(PAGE:find("dispelIndicatorOptions[d.dispelOverlayDispelType]", 1, true) ~= nil,
          "summary: Settings names the dispel type from the dropdown's own table")
    check(PAGE:find("iconPositions[d.dispelIconPosition]", 1, true) ~= nil,
          "summary: Dispel Symbol names the position from the dropdown's own table")
    check(PAGE:find("gradientStyles[d.dispelGradientStyle]", 1, true) ~= nil,
          "summary: Gradient names the wash from the dropdown's own table")
end
