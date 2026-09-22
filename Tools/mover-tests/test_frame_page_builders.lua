local NS = ...

-- ============================================================
-- FRAME PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Options.lua
-- ------------------------------------------------------------
-- General > Frame: ten groups. In Modern they are the Debuff Bar's collapsible
-- CARDS -- two per row inside a card wide enough, dim captions, the value
-- summary in a shut card's corner, Expand All / Collapse All at the top -- and
-- every one of them now behaves the same way (the old page had three kinds of
-- row: plated with a strip, behind a panel, and with hoisted controls):
--
--   column 1   "Layout"      Frame Size, Layout Direction, Raid Layout Mode,
--                            Group Layout Settings, Group Visibility, Group
--                            Display Order, Flat Grid Settings
--              "Movement"    Permanent Mover (tick: permanentMover)
--   column 2   "Appearance"  Border (tick: frameShowBorder), Border Shadow
--                            (tick: frameBorderShadowEnabled), Frame Fade
--                            (tick: frameFadeEnabled)
--
-- Each conversion is allowed to change WHERE a group is mounted and nothing
-- else: same widgets, same order, same L keys, same db keys, same slot heights,
-- because the classic box and the card are handed the SAME builder.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY, so this file reads the page's SOURCE.
--   ✓ the widget CENSUS of each builder, taken from the pre-change source.
--   ✓ that ONE builder serves both layouts, and each card's column, stable
--     collapse key, summary, grey and hide gates, header tick and pin.
--   ✓ the Frame Fade engine's own reading of its tick (section 1b, driven).
--   ✗ nothing about runtime behaviour -- read in game.
--
-- ⚠ THIS FILE ALSO CARRIES TWO ADDON-WIDE ROLLS (section 6): every popout row
-- on every page carries the footer strip, and exactly which pages still opt a
-- row onto the plate.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Options.lua"):gsub("\r\n", "\n")

local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
}

-- The body of a `local function <name>(tools2)` at the page builder's own
-- indent (a newline + EIGHT spaces + `end`).
local function builderBody(name)
    local head = "local function " .. name .. "(tools2)"
    local a = SRC:find(head, 1, true)
    check(a ~= nil, "source: the page declares " .. name)
    if not a then return "" end
    local b = SRC:find("\n        end\n", a, true)
    check(b ~= nil and b > a, "source: ..." .. name .. " closes at the page builder's indent")
    return SRC:sub(a, b or a)
end

-- ☠ THE LABEL IS THE CALL'S SECOND ARGUMENT, so a control labelled from a
-- VARIABLE (the two flat-grid controls whose names swap with the growth
-- direction) honestly reads "(none)".
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

-- The Frame page's own source, from its copy button to the See Also bar.
local PAGE
do
    local a = SRC:find('Add(CreateCopyButton(self.child, {"frame", "permanentMover"', 1, true)
    local b = SRC:find('{pageId = "general_sorting", label = L["Sorting"]}', 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Frame page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- ONE CARD'S BLOCK: from its OpenSection call to the CloseSection that puts its
-- band in, flattened; `call` is everything before `mount` (the builder mount).
local function sectionBlock(labelKey, mount)
    local a = PAGE:find('OpenSection(L["' .. labelKey .. '"]', 1, true)
    check(a ~= nil, "source: a card is opened for " .. labelKey)
    if not a then return "", "" end
    local b = PAGE:find("CloseSection(", a, true)
    local c = b and PAGE:find(")", b, true)
    check(b ~= nil, "source: ..." .. labelKey .. "'s band is closed after its controls")
    local block = PAGE:sub(a, c or a):gsub("%s+", " ")
    local m = block:find(mount, 1, true)
    return block, m and block:sub(1, m - 1) or block
end

-- The classic box each group is still built into, with its own header.
local function classicBox(label)
    return PAGE:match("local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)\n%s*%1:AddWidget%(GUI:CreateHeader%(self%.child, L%[\"" .. label:gsub("%p", "%%%0") .. "\"%]%)")
end

-- ============================================================
-- 1. FRAME FADE -- its enable is the card's header tick
-- The group had no boolean meaning "am I doing anything" for a whole release;
-- frameFadeSplitCombat is a MODE and it HIDES the global slider, so the boolean
-- was ADDED -- frameFadeEnabled, shipped true -- rather than borrowed.
-- ============================================================
local FRAME_FADE = {
    { "checkbox", "Enable Frame Fade",                 "frameFadeEnabled",            30 },
    { "slider",   "Global Frame Fade",                 "frameFadeAlpha",              55 },
    { "checkbox", "Separate Combat Fade",              "frameFadeSplitCombat",        30 },
    { "slider",   "Out of Combat Frame Fade",          "frameFadeAlphaOutOfCombat",   55 },
    { "slider",   "In Combat Frame Fade",              "frameFadeAlphaInCombat",      55 },
    { "checkbox", "Use In-Combat Fade In Instances",   "frameFadeInstanceUsesCombat", 30 },
    { "checkbox", "Show In-Combat Fade When Hovering", "frameFadeHoverUsesCombat",    30 },
    { "dropdown", "Hover Applies To",                  "frameFadeHoverScope",         55 },
}

print("-- Frame page: Frame Fade")
do
    local body = builderBody("BuildFrameFadeGroup")
    checkCensus(census(body), FRAME_FADE, "frame fade")
    check(body:find("if not tools2.hoistToggle then", 1, true) ~= nil
      and body:find(".keepEnabled = true", 1, true) ~= nil,
          "frame fade: the enable is skipped when the header carries it, and stays live in classic")

    -- ☠ ...AND THE BODY'S FIRST CONTROL IS EXPECTED TO GREY. With the header
    -- carrying the tick, the Global Frame Fade slider is child ONE of a band with
    -- no header -- and the only mark that would spare it is a keepEnabled it must
    -- not have. The kit spares by MARK now, not by position.
    local hoisted = body:match("if not tools2%.hoistToggle then.-\n            end\n(.*)")
    check(hoisted ~= nil, "frame fade: the builder's other half reads on its own")
    if hoisted then
        local first = census(hoisted)[1]
        check(first ~= nil and first.key == FRAME_FADE[2][3], "frame fade: ...the global slider first")
        eq(select(2, hoisted:gsub("%.keepEnabled", "")), 0,
           "frame fade: ...and nothing in the body is spared from the gate")
    end
    local sections = ui_file_source("Sections.lua")
    check(sections:find("groupOff and i > 1", 1, true) == nil
      and sections:find('rawget(widget, "isSectionHeader")', 1, true) ~= nil
      and sections:find('rawget(widget, "keepEnabled")', 1, true) ~= nil,
          "frame fade: the group gate spares the header and the Enable by their marks, not by position")
    check(options_file_source("GUI/SettingsWidgets.lua"):find("container.isSectionHeader = true", 1, true) ~= nil,
          "frame fade: ...which GUI:CreateHeader stamps")
    check(body:find("group.disableChildrenOn = function(d) return not d.frameFadeEnabled end", 1, true) ~= nil,
          "frame fade: the group's grey-while-off gate is inside the builder")

    check(df_file_source("Locales/enUS.lua"):find('L["' .. FRAME_FADE[1][2] .. '"] = true', 1, true) ~= nil,
          "frame fade: the tick's label is a shipped enUS phrase")
    check(options_file_source("Core/ExportCategories.lua"):find('"' .. FRAME_FADE[1][3] .. '"', 1, true) ~= nil,
          "frame fade: ...and the key travels in a profile export")

    local calls = 0
    for _ in PAGE:gmatch("BuildFrameFadeGroup%(") do calls = calls + 1 end
    eq(calls, 3, "frame fade: declared once, mounted twice -- classic box and card")
    local box = classicBox("Frame Fade")
    check(box ~= nil and PAGE:find("Add(" .. box .. ", nil, 2)", 1, true) ~= nil,
          "frame fade: the classic box keeps its header and column 2")

    local block, call = sectionBlock("Frame Fade", "BuildFrameFadeGroup({")
    check(call:find('OpenSection(L["Frame Fade"], "frame_fade", 2, FrameFadeSummary, nil, nil, BuildFrameFadeGroup, {', 1, true) ~= nil,
          "frame fade: a card keyed frame_fade in column 2, pinnable from its own builder")
    check(call:find('db = db, key = "frameFadeEnabled", label = L["Enable Frame Fade"]', 1, true) ~= nil,
          "frame fade: the header tick is bound to frameFadeEnabled under the checkbox's own name")
    check(call:find("RefreshFrameFade() self:RefreshStates() tools.ReflowMounted()", 1, true) ~= nil
      and call:find("RefreshCurrentPage", 1, true) == nil,
          "frame fade: ...committing the engine refresh, a state pass and a pinned-panel repaint -- never a rebuild")
    check(block:find("BuildFrameFadeGroup({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end, hoistToggle = true, })", 1, true) ~= nil,
          "frame fade: mounts the builder as classic does, plus hoistToggle for its header tick")

    local sum = PAGE:match("local function FrameFadeSummary%(d%)(.-)\n            end")
    check(sum ~= nil and sum:find('L%["Alpha"%]') ~= nil and sum:find('L%["Combat"%]') ~= nil,
          "frame fade: the summary labels its opacities in words the locale ships")
end

-- ============================================================
-- 1b. FRAME FADE -- WHAT THE TICK ACTUALLY DOES
-- The setting is read in ONE place -- DF:GetFrameBaseAlpha
-- (Features/ElementAppearance.lua) -- so that resolver is driven here.
--
-- ☠ THE FUNCTION IS LIFTED OUT OF THE SHIPPED SOURCE, not copied into this file.
--   * FALSE -> 1, whatever the sliders and the split say.
--   * NIL   -> exactly what the function did before the key existed.
-- ============================================================
print("-- Frame page: the Frame Fade engine")
do
    local ENGINE = df_file_source("Features/ElementAppearance.lua")
    local fnBody = ENGINE:match("function DF:GetFrameBaseAlpha%(db, frame%)\n(.-)\nend\n")
    check(fnBody ~= nil, "frame fade engine: the resolver is where the page says it is")

    if fnBody then
        local code = fnBody:gsub("%-%-[^\n]*", "")
        local gateAt  = code:find("db.frameFadeEnabled == false", 1, true)
        local splitAt = code:find("db.frameFadeSplitCombat", 1, true)
        check(gateAt ~= nil, "frame fade engine: the enable is read in the resolver")
        check(gateAt and splitAt and gateAt < splitAt,
              "frame fade engine: ...before the split branch reads any slider")
        check(code:find("not db.frameFadeEnabled", 1, true) == nil,
              "frame fade engine: ...and a nil is not read as off")

        local chunk = table.concat({
            "local S = ...",
            "local function AnyFrameHovered() return S.hovered end",
            "local function UnitAffectingCombat() return S.combat end",
            "local function IsInInstance() return S.instance end",
            "local DF = {}",
            "function DF:GetFrameBaseAlpha(db, frame)",
            fnBody,
            "end",
            "return DF",
        }, "\n")
        local S = { hovered = false, combat = false, instance = false }
        local mk = (loadstring or load)(chunk, "@GetFrameBaseAlpha")
        check(mk ~= nil, "frame fade engine: ...and it compiles on its own")
        local DFE = mk and mk(S)
        check(DFE ~= nil, "frame fade engine: ...and returns the resolver")

        if DFE then
            local function fadeDB(extra)
                local d = {
                    frameFadeEnabled          = false,
                    frameFadeAlpha            = 0.10,
                    frameFadeAlphaOutOfCombat = 0.20,
                    frameFadeAlphaInCombat    = 0.30,
                    frameFadeHoverScope       = "ALL",
                }
                for k, v in pairs(extra or {}) do d[k] = v end
                return d
            end
            local function unmigrated(extra)
                local d = fadeDB(extra)
                d.frameFadeEnabled = nil
                return d
            end

            eq(DFE:GetFrameBaseAlpha(fadeDB()), 1,
               "frame fade engine: off with the split off resolves to 1, not the global slider")
            eq(DFE:GetFrameBaseAlpha(fadeDB({ frameFadeSplitCombat = true })), 1,
               "frame fade engine: ...off with the split on too, not the out-of-combat value")
            S.combat = true
            eq(DFE:GetFrameBaseAlpha(fadeDB({ frameFadeSplitCombat = true })), 1,
               "frame fade engine: ...and in combat, not the in-combat value")
            S.combat = false
            S.instance = true
            eq(DFE:GetFrameBaseAlpha(fadeDB({ frameFadeSplitCombat = true,
                                              frameFadeInstanceUsesCombat = true })), 1,
               "frame fade engine: ...and inside an instance")
            S.instance = false
            S.hovered = true
            eq(DFE:GetFrameBaseAlpha(fadeDB({ frameFadeSplitCombat = true,
                                              frameFadeHoverUsesCombat = true })), 1,
               "frame fade engine: ...and under the mouse")
            S.hovered = false

            eq(DFE:GetFrameBaseAlpha(unmigrated()), 0.10,
               "frame fade engine: a nil enable still fades -- the global slider")
            eq(DFE:GetFrameBaseAlpha(unmigrated({ frameFadeSplitCombat = true })), 0.20,
               "frame fade engine: ...and the out-of-combat value under the split")
            S.combat = true
            eq(DFE:GetFrameBaseAlpha(unmigrated({ frameFadeSplitCombat = true })), 0.30,
               "frame fade engine: ...and the in-combat value in combat")
            S.combat = false
            eq(DFE:GetFrameBaseAlpha(fadeDB({ frameFadeEnabled = true })), 0.10,
               "frame fade engine: an enabled fade is untouched by the gate")
        end
    end
end

-- ============================================================
-- 2. PERMANENT MOVER -- its enable is the card's header tick
-- ============================================================
local PERM_MOVER = {
    { "checkbox",    "Enable Permanent Mover", "permanentMover",                  30 },
    { "dropdown",    "Handle Position",        "permanentMoverAnchor",            55 },
    { "dropdown",    "Attach To",              "permanentMoverAttachTo",          55 },
    { "slider",      "Offset X",               "permanentMoverOffsetX",           55 },
    { "slider",      "Offset Y",               "permanentMoverOffsetY",           55 },
    { "slider",      "Handle Width",           "permanentMoverWidth",             55 },
    { "slider",      "Handle Height",          "permanentMoverHeight",            55 },
    { "checkbox",    "Show on Hover Only",     "permanentMoverShowOnHover",       30 },
    { "checkbox",    "Hide in Combat",         "permanentMoverHideInCombat",      30 },
    { "colorpicker", "Handle Color",           "permanentMoverColor",             35 },
    { "colorpicker", "Combat Color",           "permanentMoverCombatColor",       35 },
    { "dropdown",    "Left Click",             "permanentMoverActionLeft",        55 },
    { "dropdown",    "Right Click",            "permanentMoverActionRight",       55 },
    { "dropdown",    "Shift+Left Click",       "permanentMoverActionShiftLeft",   55 },
    { "dropdown",    "Shift+Right Click",      "permanentMoverActionShiftRight",  55 },
    { "slider",      "Pull Timer Duration",    "permanentMoverPullTimerDuration", 55 },
}

print("-- Frame page: Permanent Mover")
do
    local body = builderBody("BuildPermanentMoverGroup")
    checkCensus(census(body), PERM_MOVER, "permanent mover")
    check(body:find("if not tools2.hoistToggle then", 1, true) ~= nil,
          "permanent mover: the enable is skipped when the header carries it")
    local greys = 0
    for _ in body:gmatch("disableOn%s*=%s*function%(d%) return not d%.permanentMover end") do greys = greys + 1 end
    eq(greys, #PERM_MOVER - 1, "permanent mover: every control but the enable greys on it, in both layouts")

    local calls = 0
    for _ in PAGE:gmatch("BuildPermanentMoverGroup%(") do calls = calls + 1 end
    eq(calls, 3, "permanent mover: declared once, mounted twice -- classic box and card")
    check(PAGE:find("BuildPermanentMoverGroup({ group = permMoverGroup, parent = self.child })", 1, true) ~= nil
      and PAGE:find("Add(permMoverGroup, nil, 2)", 1, true) ~= nil,
          "permanent mover: classic mounts it exactly as it always did, in column 2")

    local block, call = sectionBlock("Permanent Mover", "BuildPermanentMoverGroup({")
    check(call:find('OpenSection(L["Permanent Mover"], "frame_permanentmover", 1, PermMoverSummary, nil, nil, nil, {', 1, true) ~= nil,
          "permanent mover: a card keyed frame_permanentmover in column 1 -- behaviour, so no pin")
    check(call:find('db = db, key = "permanentMover", label = L["Enable Permanent Mover"]', 1, true) ~= nil,
          "permanent mover: the header tick is bound to permanentMover under the checkbox's own name")
    check(call:find("DF:UpdatePermanentMoverVisibility() self:RefreshStates()", 1, true) ~= nil
      and call:find("RefreshCurrentPage", 1, true) == nil,
          "permanent mover: ...committing what the checkbox ran plus a state pass, never a rebuild")
    check(block:find("BuildPermanentMoverGroup({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end, hoistToggle = true, })", 1, true) ~= nil,
          "permanent mover: mounts the builder plus hoistToggle for its header tick")

    -- The card sits under a header naming what it is ABOUT, never its own name.
    local headerAt = PAGE:find('Add(GUI:CreateHeader(self.child, L["Movement"]), 40, 1)', 1, true)
    local cardAt   = PAGE:find('OpenSection(L["Permanent Mover"]', 1, true)
    check(headerAt and cardAt and headerAt < cardAt, "permanent mover: the Movement header opens its run in column 1")
    check(PAGE:find('CreateHeader(self.child, L["Permanent Mover"]), 40, 1)', 1, true) == nil,
          "permanent mover: ...and the header is not the card's own name said twice")
end

-- ============================================================
-- 3. THE BORDER PAIR -- two cards, two header ticks, one gate between them
-- ============================================================
print("-- Frame page: Border and Border Shadow")
do
    local border = builderBody("BuildBorderGroup")
    check(border:find("noShowToggle = tools2.hoistToggles or nil,", 1, true) ~= nil,
          "border: the toolkit's own Show Border is skipped when the header carries it")
    local shadow = builderBody("BuildBorderShadowGroup")
    check(shadow:find("noEnableToggle = tools2.hoistToggles or nil,", 1, true) ~= nil
      and shadow:find("disableWhen  = tools2.shadowDisableWhen,", 1, true) ~= nil,
          "border shadow: its enable is skipped the same way, and it takes Show Border's grey from outside")

    -- Classic: the one box, the one header, both builders back to back.
    check(PAGE:find("if classicLayout then\n            appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)\n        end", 1, true) ~= nil,
          "classic: the Appearance box is built in classic only")
    check(PAGE:find('if classicLayout then\n            appearanceGroup:AddWidget(GUI:CreateHeader(self.child, L["Appearance"]), 40)\n        end', 1, true) ~= nil,
          "classic: ...with its header, in classic only")
    check(PAGE:find("BuildBorderGroup(borderTools)\n            BuildBorderShadowGroup(borderTools)", 1, true) ~= nil
      and PAGE:find("shadowDisableWhen = BorderOff,", 1, true) ~= nil
      and PAGE:find("if classicLayout then Add(appearanceGroup, nil, 2) end", 1, true) ~= nil,
          "classic: ...mounting both builders into it, with the shadow gate, in column 2")

    local bblock, bcall = sectionBlock("Border", "BuildBorderGroup({")
    check(bcall:find('OpenSection(L["Border"], "frame_border", 2, BorderSummary, nil, nil, BuildBorderGroup, {', 1, true) ~= nil,
          "border: a card keyed frame_border in column 2, pinnable")
    check(bcall:find('db = db, key = "frameShowBorder", label = L["Show Border"]', 1, true) ~= nil
      and bcall:find("isOn = function(d) return d.frameShowBorder ~= false end", 1, true) ~= nil
      and bcall:find("onChanged = OnBorderToggle", 1, true) ~= nil,
          "border: the header tick is frameShowBorder (absent reads as on), committing OnBorderToggle")
    check(bblock:find("BuildBorderGroup({ group = borderBand, parent = self.child, refreshStates = function() self:RefreshStates() end, hoistToggles = true, })", 1, true) ~= nil,
          "border: mounts the builder with hoistToggles")

    local sblock, scall = sectionBlock("Border Shadow", "BuildBorderShadowGroup({")
    check(scall:find('OpenSection(L["Border Shadow"], "frame_bordershadow", 2, ShadowSummary, ShadowGatedOff, nil, BuildBorderShadowPinned, {', 1, true) ~= nil,
          "border shadow: a card keyed frame_bordershadow in column 2, greying with Show Border, pinnable")
    check(scall:find('db = db, key = "frameBorderShadowEnabled", label = L["Border Shadow"]', 1, true) ~= nil
      and scall:find("disableOn = ShadowGatedOff", 1, true) ~= nil,
          "border shadow: the header tick is frameBorderShadowEnabled, and greys while Show Border is off")
    check(sblock:find("BuildBorderShadowGroup({ group = shadowBand, parent = self.child, refreshStates = function() self:RefreshStates() end, shadowDisableWhen = BorderOff, hoistToggles = true, })", 1, true) ~= nil,
          "border shadow: mounts the builder with the shadow gate and hoistToggles")
    -- ☠ A pinned panel mounts the section's builder with the standard fields
    -- only -- so the pin goes through a wrapper that hands it the same gate.
    local pinned = PAGE:match("local function BuildBorderShadowPinned%(tools2%)(.-)\n            end")
    check(pinned ~= nil and pinned:find("tools2.shadowDisableWhen = BorderOff", 1, true) ~= nil
      and pinned:find("BuildBorderShadowGroup(tools2)", 1, true) ~= nil,
          "border shadow: the pin mounts the same builder with the same gate")

    local toggle = PAGE:match("local function OnBorderToggle%(%)(.-)\n            end")
    check(toggle ~= nil and toggle:find("ApplyBorder()", 1, true) ~= nil
      and toggle:find("self:RefreshStates()", 1, true) ~= nil and toggle:find("RefreshCurrentPage", 1, true) == nil,
          "border: the ticks' commit applies, re-runs the state pass, never rebuilds")
    for _, fn in ipairs({ "BorderSummary", "ShadowSummary" }) do
        check(PAGE:find("local function " .. fn .. "(d)", 1, true) ~= nil,
              "summary: " .. fn .. " takes the db table and nothing else")
    end
    check(PAGE:find("not (shown and ", 1, true) == nil, "summary: no card subtracts a plate set")
end

-- ============================================================
-- 4. THE LAYOUT CARDS
-- ============================================================
local FRAME_SIZE = {
    { "slider", "Frame Width",   "frameWidth",   55 },
    { "slider", "Frame Height",  "frameHeight",  55 },
    { "slider", "Frame Padding", "framePadding", 55 },
    { "slider", "Frame Scale",   "frameScale",   55 },
    { "slider", "Frame Spacing", "frameSpacing", 55 },
}
local LAYOUT_DIR = {
    { "dropdown", "Growth Direction", "growDirection", 55 },
    { "dropdown", "Growth Direction", "growDirection", 55 },
    { "dropdown", "Frames Grow From", "growthAnchor",  55 },
}
local RAID_MODE = {
    { "checkbox", "Use Group-Based Layout", "raidUseGroups", 30 },
    { "label",    "Enabled: Players organized by raid groups (1-8).\\nDisabled: All players in one flat grid.", "(none)", 45 },
}
local GROUP_LAYOUT = {
    { "label",    "(none)",              "(none)",              25 },
    { "slider",   "Group Spacing",       "raidGroupSpacing",    55 },
    { "slider",   "Wrap Spacing",        "raidRowColSpacing",   55 },
    { "slider",   "Groups Before Wrap",  "raidGroupsPerRow",    55 },
    { "dropdown", "Center Mode",         "raidGroupCenterMode", 55 },
    { "dropdown", "Players Grow From",   "raidPlayerAnchor",    55 },
}
local GROUP_VIS = {
    { "label",    "Choose which groups to display.", "(none)", 25 },
    { "checkbox", "Group",                           "(none)", 25 },
}
local GROUP_ORDER = {
    { "label",    "Drag to reorder groups. Top = first.", "(none)",               25 },
    { "checkbox", "My Group First",                       "raidPlayerGroupFirst", 25 },
}
local FLAT_GRID = {
    { "label",    "All players in a unified grid. Sorting applies raid-wide.", "(none)",                    25 },
    { "slider",   "(none)",              "raidPlayersPerRow",         55 },
    { "dropdown", "Grid Alignment",      "raidFlatGrowthAnchor",      55 },
    { "dropdown", "(none)",              "raidFlatColumnAnchor",      55 },
    { "dropdown", "Players Grow From",   "raidFlatFrameAnchor",       55 },
    { "slider",   "Horizontal Spacing",  "raidFlatHorizontalSpacing", 55 },
    { "slider",   "Vertical Spacing",    "raidFlatVerticalSpacing",   55 },
}

local RAID      = 'function() return GUI.SelectedMode ~= "raid" end'
local GROUPED   = 'function() return GUI.SelectedMode ~= "raid" or not db.raidUseGroups end'
local FLAT      = 'function() return GUI.SelectedMode ~= "raid" or db.raidUseGroups end'

-- label, key, classic column, builder, golden, summary, hide gate (nil = none),
-- pin (passes its builder).
local LAYOUT = {
    { label = "Frame Size", key = "frame_size", classicCol = 1, builder = "BuildFrameSizeGroup",
      golden = FRAME_SIZE, summary = "FrameSizeSummary", pin = true },
    { label = "Layout Direction", key = "frame_layoutdirection", classicCol = 1, builder = "BuildLayoutDirectionGroup",
      golden = LAYOUT_DIR, summary = "LayoutDirectionSummary" },
    { label = "Raid Layout Mode", key = "frame_raidmode", classicCol = 1, builder = "BuildRaidModeGroup",
      golden = RAID_MODE, summary = "RaidModeSummary", hide = RAID },
    { label = "Group Layout Settings", key = "frame_grouplayout", classicCol = 1, builder = "BuildGroupLayoutGroup",
      golden = GROUP_LAYOUT, summary = "GroupLayoutSummary", hide = GROUPED, pin = true },
    { label = "Group Visibility", key = "frame_groupvisibility", classicCol = 1, builder = "BuildGroupVisGroup",
      golden = GROUP_VIS, summary = "GroupVisSummary", hide = RAID },
    { label = "Group Display Order", key = "frame_grouporder", classicCol = 2, builder = "BuildGroupOrderGroup",
      golden = GROUP_ORDER, summary = "GroupOrderSummary", hide = GROUPED },
    { label = "Flat Grid Settings", key = "frame_flatgrid", classicCol = 1, builder = "BuildFlatGridGroup",
      golden = FLAT_GRID, summary = "FlatGridSummary", hide = FLAT, pin = true },
}

for _, g in ipairs(LAYOUT) do
    print("-- Frame page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())

    local calls = 0
    for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, g.label .. ": declared once, mounted twice -- classic box and card")
    local box = classicBox(g.label)
    check(box ~= nil and PAGE:find("Add(" .. box .. ", nil, " .. g.classicCol .. ")", 1, true) ~= nil,
          g.label .. ": the classic box keeps its header and column " .. g.classicCol)

    local block, call = sectionBlock(g.label, g.builder .. "({")
    local want = 'OpenSection(L["' .. g.label .. '"], "' .. g.key .. '", 1, ' .. g.summary
    if g.hide or g.pin then want = want .. ", nil, " .. (g.hide or "nil") end
    if g.pin then want = want .. ", " .. g.builder end
    check(call:find(want, 1, true) ~= nil,
          g.label .. ": a card keyed " .. g.key .. " in column 1" .. (g.hide and ", hidden outside its mode" or "")
          .. (g.pin and ", pinnable" or ""))
    eq(call:find(", " .. g.builder, 1, true) ~= nil, g.pin == true,
       g.label .. (g.pin and ": pinnable from its own builder" or ": no pin"))
    check(call:find('key = "', 1, true) == nil, g.label .. ": no header tick")
    check(block:find(g.builder .. "({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end, })", 1, true) ~= nil,
          g.label .. ": mounts the builder exactly as classic does")
end

print("-- Frame page: what the layout builders still own")
do
    -- Frame Size's summary: WxH in ASCII, the rest only when changed.
    local sum = PAGE:match("local function FrameSizeSummary%(d%)(.-)\n            end")
    check(sum ~= nil and sum:find('"%%dx%%d"') ~= nil and sum:find("\\195\\151", 1, true) == nil
      and sum:find("D:IsModified(d, key)", 1, true) ~= nil,
          "frame size: the summary prints WxH in ASCII and asks the defaults engine what changed")

    -- Layout Direction: the two dialects, one page-scope map each.
    local maps = PAGE:match("local function GrowDirectionOptions%(grouped%)(.-)\n        end")
    check(maps ~= nil and maps:find('HORIZONTAL = L["Columns"], VERTICAL = L["Rows"]', 1, true) ~= nil
      and maps:find('HORIZONTAL = L["Rows"], VERTICAL = L["Columns"]', 1, true) ~= nil,
          "layout direction: the grouped-raid map and its inverse, once, at page scope")
    local dir = builderBody("BuildLayoutDirectionGroup")
    check(dir:find("GrowDirectionOptions(false)", 1, true) ~= nil and dir:find("GrowDirectionOptions(true)", 1, true) ~= nil
      and dir:find('HORIZONTAL = L["', 1, true) == nil,
          "layout direction: the builder asks for both dialects by name, with no copy of either")
    local anchorLiterals = 0
    for _ in PAGE:gmatch('_order = { "START", "CENTER", "END" }, START= MAIN_START') do anchorLiterals = anchorLiterals + 1 end
    eq(anchorLiterals, 1, "layout direction: the anchor map is written out once")
    local dsum = PAGE:match("local function LayoutDirectionSummary%(d%)(.-)\n            end")
    check(dsum ~= nil and dsum:find("MAIN_START", 1, true) == nil and dsum:find("d.raidUseGroups", 1, true) ~= nil,
          "layout direction: the summary derives its words from d, in the dropdown's dialect")

    -- Raid Layout Mode: the tick is a MODE, so it stays in the body.
    local raid = builderBody("BuildRaidModeGroup")
    check(raid:find("if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end", 1, true) ~= nil,
          "raid layout mode: the checkbox rebuilds the page, a page widget in both layouts")
    check((select(2, sectionBlock("Raid Layout Mode", "BuildRaidModeGroup({"))):find("hoistToggle", 1, true) == nil,
          "raid layout mode: the tick is not hoisted -- flat is a layout too, a shut card must not read Off")
    local rsum = PAGE:match("local function RaidModeSummary%(d%)(.-)\n            end")
    check(rsum ~= nil and rsum:find('L["Groups"]', 1, true) ~= nil and rsum:find('L["Flat"]', 1, true) ~= nil,
          "raid layout mode: the summary names the mode either way")
    local apply = PAGE:match("local function ApplyRaidUseGroups%(%)(.-)\n        end")
    check(apply ~= nil and apply:find('db.growDirection = (db.growDirection == "HORIZONTAL") and "VERTICAL" or "HORIZONTAL"', 1, true) ~= nil,
          "raid layout mode: ...and the flip still carries the growDirection compensation")

    -- Group Layout Settings: the two named refreshes are the instance's own.
    local gl = builderBody("BuildGroupLayoutGroup")
    check(gl:find('GUI:CreateAnchorGrid(parent, L["Groups Anchor"], db, "raidGroupAnchor", "raidGroupRowGrowth"', 1, true) ~= nil,
          "group layout: the corner picker is mounted, on both its keys")
    check(gl:find("local function UpdateFramesAndGates()", 1, true) ~= nil
      and gl:find("if group.RefreshChildStates then group:RefreshChildStates() end", 1, true) ~= nil
      and gl:find("groupLayoutGroup", 1, true) == nil,
          "group layout: the gate refresh is the builder's own, never the classic box")
    check(gl:find("if groupAnchorGrid and groupAnchorGrid.Refresh then groupAnchorGrid:Refresh() end", 1, true) ~= nil,
          "group layout: ...and the pin commit refreshes this instance's own picker")

    -- Group Visibility: eight ticks and one full-row blurb.
    local gv = builderBody("BuildGroupVisGroup")
    check(gv:find("for i = 1, 8 do", 1, true) ~= nil and gv:find("groupVisHintLabel.fullRow = true", 1, true) ~= nil,
          "group visibility: a loop over the eight groups, the hint a row of its own")
    local marks = 0
    for _ in PAGE:gmatch("%.fullRow%s*=%s*true") do marks = marks + 1 end
    eq(marks, 1, "group visibility: ...and the only fullRow mark on the page")

    -- Group Display Order: the drag list answers to the group-wide value sweep.
    check(builderBody("BuildGroupOrderGroup"):find('GUI:CreateGroupOrderList(parent, db, "raidGroupDisplayOrder"', 1, true) ~= nil,
          "group order: the drag list is mounted into the builder's own parent")
    local list = options_file_source("GUI/Controls.lua"):match("function GUI:CreateGroupOrderList(.-)\nend\n")
    check(list ~= nil and list:find("container.refreshValue = container.Refresh", 1, true) ~= nil,
          "group order: ...and answers to the group-wide value sweep")

    -- The grouped and flat cards read opposite sides of raidUseGroups.
    check(PAGE:find(GROUPED, 1, true) ~= nil and PAGE:find(FLAT, 1, true) ~= nil,
          "flat grid: the grouped and flat cards' gates are inverses, so the two never coexist")
end

-- ============================================================
-- 5. THE CARDS TOGETHER, AND THE ROW FURNITURE GONE
-- ============================================================
print("-- Frame page: the cards together")
do
    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "GUI:CreateControlRow(", "tools.PopoutContent(",
                            "tools.ClaimKeys(", "tools.WireModifiedTick(", "tools.WireFooter(",
                            "tools.RegisterHoistedToggle(", "footerStrip", "inline = true",
                            "_COUNT", "count =", "layoutBand", "permMoverBand", "chromeless",
                            "INLINE_BOX", "layoutDirRow", "OpenPopout", "ApplyFrameSize",
                            "ApplyGroupOrder", "ApplyLayoutDirection", "OnRaidModeToggle",
                            "OnFrameFadeToggle", "OnPermMoverToggle" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end
    check(SRC:find("local layoutDirRow", 1, true) == nil,
          "furniture: ...and so is the file-scope row handle the panel reopen needed")

    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: every card goes through the shared helper, two per row and dim captions")
    check(PAGE:find("local function CloseSection(band)\n            tools.CloseSection(Add, band)\n        end", 1, true) ~= nil,
          "sections: ...and closes through the shared helper too")

    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "),
       "Frame Size | Border | Border Shadow | Frame Fade | Layout Direction | Raid Layout Mode | Group Layout Settings | Group Visibility | Group Display Order | Flat Grid Settings | Permanent Mover",
       "order: the cards open in the order they stack -- column 1's layout chain in classic's order")

    -- The three category headers, each once, each opening its run.
    for _, pair in ipairs({ { "Layout", "1", "Frame Size" }, { "Appearance", "2", "Border" }, { "Movement", "1", "Permanent Mover" } }) do
        local n = 0
        for _ in PAGE:gmatch('Add%(GUI:CreateHeader%(self%.child, L%["' .. pair[1] .. '"%]%), 40, ' .. pair[2] .. '%)') do n = n + 1 end
        eq(n, 1, "headers: the " .. pair[1] .. " header, in column " .. pair[2] .. ", once")
        local hAt = PAGE:find('Add(GUI:CreateHeader(self.child, L["' .. pair[1] .. '"]), 40, ' .. pair[2] .. ')', 1, true)
        local cAt = PAGE:find('OpenSection(L["' .. pair[3] .. '"]', 1, true)
        check(hAt and cAt and hAt < cAt, "headers: ..." .. pair[1] .. " heads " .. pair[3])
    end

    local hoists = 0
    for _ in PAGE:gmatch("hoistToggles? = true,") do hoists = hoists + 1 end
    eq(hoists, 4, "ticks: four mounts skip their in-body toggle -- Border, Border Shadow, Frame Fade, Permanent Mover")

    check(PAGE:find('Add(tools.SectionControls(self.child), 24, "both")', 1, true) ~= nil,
          "bulk: Expand All / Collapse All at the top, spanning both columns")
    local stripAt = PAGE:find("tools.SectionControls", 1, true)
    local layoutAt = PAGE:find('Add(GUI:CreateHeader(self.child, L["Layout"]), 40, 1)', 1, true)
    check(stripAt and layoutAt and stripAt < layoutAt, "bulk: ...above the first category header")

    -- Classic's own columns, untouched.
    local CLASSIC_COL = {
        sizeGroup = "1", layoutGroup = "1", raidModeGroup = "1",
        groupLayoutGroup = "1", groupVisGroup = "1", groupOrderGroup = "2",
        flatGridGroup = "1", frameFadeGroup = "2", permMoverGroup = "2",
    }
    for name, col in pairs(CLASSIC_COL) do
        check(PAGE:find("Add(" .. name .. ", nil, " .. col .. ")", 1, true) ~= nil,
              "classic: " .. name .. " still goes to column " .. col)
    end
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 10, "classic: ten bare 280 boxes, all the classic branch's own")
end

-- ============================================================
-- 6. TWO ADDON-WIDE ROLLS, AND THE SHARED VERBS THEY LEAN ON
-- ============================================================
print("-- Frame page: the addon-wide strip and inline rolls")
do
    -- ☠ EVERY POPOUT ROW ON EVERY PAGE CARRIES THE FOOTER STRIP. A row without
    -- one is a new row that forgot it or a page a later sweep missed.
    -- ⚠ GUI/PopoutDemo.lua is deliberately not in this walk: it is the kit's own
    -- fixture for the no-strip tether.
    local TOC = options_file_source("DandersFrames_Options.toc")
    local naked = {}
    for name in TOC:gmatch("GUI\\(Pages\\[%w_]+%.lua)") do
        local path = "GUI/" .. name:gsub("\\", "/")
        local src = options_file_source(path)
        local rows, strips = 0, 0
        for _ in src:gmatch("CreatePopoutRow") do rows = rows + 1 end
        for _ in src:gmatch("footerStrip = true") do strips = strips + 1 end
        if rows ~= strips then
            naked[#naked + 1] = path .. " (" .. strips .. "/" .. rows .. ")"
        end
    end
    eq(#naked, 0, "strip: every popout row on every page carries it -- " .. table.concat(naked, ", "))

    -- The strip's two phrases ship side by side, and the kit asks for the pin one.
    local ENUS = df_file_source("Locales/enUS.lua")
    local moreAt = ENUS:find('L["%d more settings"] = true', 1, true)
    local pinAt  = ENUS:find('L["Pin settings in popout"] = true', 1, true)
    check(moreAt ~= nil and pinAt ~= nil and pinAt > moreAt and (pinAt - moreAt) < 400,
          "locale: the strip's count and pin phrases ship side by side")
    check(ui_file_source("PopoutRow.lua"):find('L["Pin settings in popout"]', 1, true) ~= nil,
          "locale: ...and PopoutRow asks for the pin phrase through the host's own L")

    local controls = options_file_source("GUI/Controls.lua")
    check(controls:find("local function RegisterHoistedControls(row, list, dbFn)", 1, true) ~= nil
      and controls:find("if type(label) == \"table\" then", 1, true) ~= nil
      and controls:find("RegisterHoistedControls = ", 1, true) == nil,
          "verb: hoisted controls are reached through RegisterHoistedToggle, one exported name")
    check(controls:find("local function PopoutContent(buildInto, innerColumns, opts)", 1, true) ~= nil
      and controls:find("innerColumns = innerColumns }", 1, true) ~= nil,
          "grid: a pane's track count is a per-row argument of the shared helper")

    -- ☠ WHICH PAGES STILL OPT A ROW ONTO THE PLATE, with exact counts. A page
    -- that opts a row in without an argument having been made for it fails
    -- here, and a page that silently gains or loses one fails on the NUMBER.
    local SWEPT = {
        -- ⚠ 0: every page in Options.lua is cards now -- Visibility, Tooltips,
        -- Fading, Pet Frames, Settings and, last, this Frame page (its four:
        -- Frame Size, Layout Direction, Border Shadow, Group Display Order).
        ["GUI/Pages/Options.lua"]    = 0,
        -- ⚠ 0 since Personal Targeted followed the other aura pages onto cards.
        ["GUI/Pages/Indicators.lua"] = 0,
        -- ⚠ 4, NOT 7, since Highlights became cards: its three went. ⚠ 1,
        -- NOT 4, since the Dispel Overlay followed: its three went too. ⚠ 0
        -- since Icons followed: every settings page in the file is cards now.
        ["GUI/Pages/Modules.lua"]    = 0,
        ["GUI/Pages/Frames.lua"]     = 2,   -- Group Labels 2
        -- ⚠ Auras.lua's pages move onto the Debuff Bar's cards one by one, and a
        -- card has no plate to opt onto: Heal Prediction's 2 went first, then Health Bar's 5
        -- and Resource Bar's 5, Colors' 1 (Role Colors), Sorting's 1 and Integrations' 1:
        -- the whole file is cards now, so it opts nothing onto a plate.
        ["GUI/Pages/Auras.lua"]      = 0,
    }
    local wrong = {}
    for name in TOC:gmatch("GUI\\(Pages\\[%w_]+%.lua)") do
        local path = "GUI/" .. name:gsub("\\", "/")
        local src = options_file_source(path)
        local n, want = 0, SWEPT[path] or 0
        for _ in src:gmatch("inline = true") do n = n + 1 end
        if n ~= want then
            wrong[#wrong + 1] = path .. " (" .. n .. ", want " .. want .. ")"
        end
    end
    eq(#wrong, 0, "inline: every page opts in exactly what the roll says -- " .. table.concat(wrong, ", "))

    check(controls:find("local INLINE_MAX = 6", 1, true) ~= nil
      and controls:find("eager.group:CountVisibleChildren() <= INLINE_MAX", 1, true) ~= nil,
          "inline: the helper carries the threshold, measured off the PANE")
    check(options_file_source("Features/Search.lua"):find("row:IsShowingInlineContent() then return end", 1, true) ~= nil,
          "inline: the search jump stops at a row that is showing the setting")
end

-- ============================================================
-- 7. GROWTH DIRECTION STILL REBUILDS THE PAGE -- AND NOTHING HAS TO COME BACK
-- ------------------------------------------------------------
-- Growth Direction bakes the WORDS and VALUES of seven dropdowns at build, so
-- its write rebuilds the page, deferred a frame so the dropdown's own click
-- handler unwinds first. With the row gone there is no panel to put back: the
-- Layout Direction card is a page widget, and its fold is persisted on a stable
-- key, so it is open again on the other side of the rebuild by itself.
-- ============================================================
print("-- Frame page: Growth Direction rebuilds, and the card survives it")
do
    local fn = PAGE:match("local function OnGrowthDirectionChanged%(%)(.-)\n        end")
    check(fn ~= nil, "growth: the growth-direction commit is a named function")
    if fn then
        check(fn:find("C_Timer.After(0, function()\n                if GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end\n            end)", 1, true) ~= nil,
              "growth: the rebuild is deferred a frame")
        check(fn:find("OpenPopout", 1, true) == nil and fn:find("Pin(true)", 1, true) == nil,
              "growth: ...and there is no panel to reopen or re-pin")
    end
    check(PAGE:find('L["Frames Grow From"], anchorOptions, db, "growthAnchor", UpdateFrames', 1, true) ~= nil,
          "growth: Frames Grow From still needs no rebuild")
end
