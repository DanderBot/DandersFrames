local NS = ...

-- ============================================================
-- SETTINGS PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Options.lua
-- ------------------------------------------------------------
-- General > Settings: seven classic boxes under an info banner. In Modern they
-- are the Debuff Bar's collapsible CARDS -- two per row inside a card wide
-- enough, dim captions, the value summary in a shut card's corner, Expand All /
-- Collapse All at the top -- keeping the page's two-band split as its columns:
--
--   column 1   Frame Modes, Blizzard Frames, Notifications   (what it DOES)
--   column 2   Rendering, Settings Panel Appearance           (how it LOOKS)
--              Minimap, Language -- each classic box's one control as a card
--
-- No header ticks (every group is independent switches). Pins on Rendering and
-- Settings Panel Appearance.
--
-- ☠☠ THIS PAGE OWNS NO PLAIN PER-MODE PROFILE KEY: the mode enables and the
-- settings-font keys are at the DF.db ROOT, the Blizzard / minimap /
-- pixel-perfect toggles are read party-canonical and written to BOTH mode
-- tables, the update rate and the notification ticks are account-wide, the
-- language override is per-character, and the classic-layout flag has no table.
-- So a card's summary must read ITS OWN store (the page's state pass hands it
-- the per-mode table), and no reset may ever be wired here -- section 6.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY, so this file reads the page's SOURCE.
--   ✓ the CENSUS of each builder (the pre-change goldens -- classic renders as
--     it did), with the store each control binds to.
--   ✓ each card's column, stable collapse key, summary store, tick and pin.
--   ✓ the classic-layout escape hatch's decision (section 5).
--   ✗ nothing about runtime behaviour -- read in game.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Options.lua"):gsub("\r\n", "\n")

-- ⚠ CreateSeparator AND CreateInfoBanner ARE IN THE MAP: the divider between
-- the third and fourth Blizzard ticks is a real widget in the group's roster.
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateFontDropdown = "fontdropdown", CreateOutlineDropdown = "outlinedropdown",
    CreateShadowCheckbox = "shadowcheckbox", CreateNote = "note",
    CreateSeparator = "separator", CreateInfoBanner = "banner",
}

local function builderBody(name)
    local head = "local function " .. name .. "(tools2)"
    local a = SRC:find(head, 1, true)
    check(a ~= nil, "source: the page declares " .. name)
    if not a then return "" end
    local b = SRC:find("\n        end\n", a, true)
    check(b ~= nil and b > a, "source: ..." .. name .. " closes at the page builder's indent")
    return SRC:sub(a, b or a)
end

-- ⚠ THE KEY COLUMN IS QUALIFIED -- "<table>.<key>" -- because WHICH store a
-- control writes is this page's whole argument. A control the reader cannot
-- bind (custom get/set, `nil, nil`) comes back "(none)" and is pinned by source
-- pattern in its own section.
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
        if not tbl then
            tbl, k = chunk:match('(DF:GetGlobalDB%(%))%s*,%s*"([%w_]+)"')
        end
        local h = tonumber(chunk:match('%)%s*,%s*(%d+)%s*%)'))
        out[#out + 1] = { kind = at.kind, label = label,
                          key = (tbl and (tbl .. "." .. k)) or "(none)", height = h }
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

local PAGE
do
    local a = SRC:find('local pageGeneral = CreateSubTab("general", "general_settings"', 1, true)
    local b = SRC:find("    -- General > Frame", 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Settings page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

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

-- ============================================================
-- 1. THE SHARED MACHINERY, AND THE ROW FURNITURE GONE
-- ============================================================
print("-- Settings page: the shared machinery, and the row furniture gone")
do
    check(PAGE:find("local classicLayout = DF:IsClassicSettingsLayout()", 1, true) ~= nil,
          "tools: the page asks which layout it is building")
    check(PAGE:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true) ~= nil,
          "tools: ...and takes the shared machinery unconditionally")
    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "GUI:CreateControlRow(", "tools.PopoutContent(",
                            "tools.ClaimKeys(", "tools.RegisterControlRow(", "footerStrip",
                            "inline = true", "_COUNT", "count =", "settingsBand", "looksBand",
                            "minimapBand", "languageBand", "chromeless", "INLINE_BOX",
                            "WriteMinimapButton", "openerTooltip" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " is gone from the page")
    end
    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: every card goes through the shared helper, two per row and dim captions")
    check(PAGE:find("local function CloseSection(band)\n            tools.CloseSection(Add, band)\n        end", 1, true) ~= nil,
          "sections: ...and closes through the shared helper too")

    -- The info banner is untouched and still first; the bulk verbs go under it.
    local bannerAt = PAGE:find("local banner = GUI:CreateInfoBanner(self.child, {", 1, true)
    local stripAt  = PAGE:find('Add(tools.SectionControls(self.child), 24, "both")', 1, true)
    local firstAt  = PAGE:find('OpenSection(L["Frame Modes"]', 1, true)
    check(bannerAt and stripAt and firstAt and bannerAt < stripAt and stripAt < firstAt,
          "bulk: the banner, then Expand All / Collapse All spanning both columns, then the first card")
    check(PAGE:find("if not classicLayout then\n            Add(tools.SectionControls(self.child), 24, \"both\")\n        end", 1, true) ~= nil,
          "bulk: ...and only in Modern")
end

-- ============================================================
-- 2. THE BUILDERS, CONTROL BY CONTROL, AND THEIR CARDS
-- Every golden below is the census of the PRE-CHANGE source.
-- ============================================================
local FRAME_MODES = {
    { "checkbox", "Enable Party Frames", "DF.db.partyEnabled", 30 },
    { "checkbox", "Enable Raid Frames",  "DF.db.raidEnabled",  30 },
    { "label", "Completely enable or disable the Party or Raid frame system. Disabled modes are never created, consuming zero performance in the background. Requires a UI reload to apply.", "(none)", 80 },
}
local BLIZZARD_FRAMES = {
    { "checkbox",  "Disable Blizzard Party Frames", "DF.db.party.hideBlizzardPartyFrames", 30 },
    { "checkbox",  "Disable Blizzard Raid Frames",  "DF.db.party.hideBlizzardRaidFrames",  30 },
    { "checkbox",  "Hide Blizzard Player Frame",    "(none)",                              30 },
    { "separator", "(none)",                        "(none)",                              14 },
    { "checkbox",  "Show Party/Raid Side Menu",     "DF.db.party.showBlizzardSideMenu",    30 },
}
local RENDERING = {
    { "checkbox", "Pixel-Perfect Scaling",     "(none)", 30 },
    { "label",    "Snaps sizes and borders to exact pixels for crisp rendering.", "(none)", 42 },
    { "label",    "(none)",                    "(none)", 250 },
    { "dropdown", "Aura Duration Update Rate", "DF:GetGlobalDB().auraDurationUpdateInterval", 55 },
    { "label",    "How often aura countdown text refreshes. Smooth updates ten times a second, Performance once a second. Normal keeps the standard rate.", "(none)", 52 },
}
local PANEL_APPEARANCE = {
    { "fontdropdown",    "Settings Font",         "DF.db.settingsFont",        55 },
    { "outlinedropdown", "Settings Font Outline", "DF.db.settingsFontOutline", 55 },
    { "label", "Font used for this settings panel. Does not affect in-game frame text — use the Text Designer for those.", "(none)", 60 },
    { "checkbox",        "Use classic settings layout", "(none)",              30 },
}
local NOTIFICATIONS = {
    { "checkbox", "Notify me when a newer version is available", "DF:GetGlobalDB().notifyOutdated",  30 },
    { "checkbox", "Show the login message",                      "DF:GetGlobalDB().showLoginMessage", 30 },
}

-- summary = the argument as it appears in the call; `store` = the table the
-- summary is made to read instead of the per-mode one it is handed.
local CARDS = {
    { label = "Frame Modes", key = "general_framemodes", col = 1, classicCol = 1,
      builder = "BuildFrameModesGroup", golden = FRAME_MODES,
      summary = "function() return FrameModesSummary(DF.db) end" },
    { label = "Blizzard Frames", key = "general_blizzard", col = 1, classicCol = 1,
      builder = "BuildBlizzardFramesGroup", golden = BLIZZARD_FRAMES, summary = "nil" },
    { label = "Rendering", key = "general_rendering", col = 2, classicCol = 1,
      builder = "BuildRenderingGroup", golden = RENDERING,
      summary = "function() return RenderingSummary(DF:GetGlobalDB()) end", pin = true },
    { label = "Settings Panel Appearance", key = "general_panelappearance", col = 2, classicCol = 2,
      builder = "BuildPanelAppearanceGroup", golden = PANEL_APPEARANCE,
      summary = "function() return PanelAppearanceSummary(DF.db) end", pin = true },
    { label = "Notifications", key = "general_notifications", col = 1, classicCol = 2,
      builder = "BuildNotificationsGroup", golden = NOTIFICATIONS, summary = "nil" },
}

for _, g in ipairs(CARDS) do
    print("-- Settings page: " .. g.label)
    local body = builderBody(g.builder)
    checkCensus(census(body), g.golden, g.label:lower())

    local calls = 0
    for _ in PAGE:gmatch(g.builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, g.label .. ": declared once, mounted twice -- classic box and card")
    local esc = g.label:gsub("%p", "%%%0")
    local box = PAGE:match("local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)\n%s*%1:AddWidget%(GUI:CreateHeader%(self%.child, L%[\"" .. esc .. "\"%]%)")
    check(box ~= nil and PAGE:find("Add(" .. box .. ", nil, " .. g.classicCol .. ")", 1, true) ~= nil,
          g.label .. ": the classic box keeps its header and column " .. g.classicCol)

    local block, call = sectionBlock(g.label, g.builder .. "({")
    check(call:find('OpenSection(L["' .. g.label .. '"], "' .. g.key .. '", ' .. g.col .. ', ' .. g.summary, 1, true) ~= nil,
          g.label .. ": a card keyed " .. g.key .. " in column " .. g.col .. ", its summary reading its own store")
    eq(call:find(", " .. g.builder, 1, true) ~= nil, g.pin == true,
       g.label .. (g.pin and ": pinnable, from its own builder" or ": behaviour, so no pin"))
    check(call:find('key = "', 1, true) == nil, g.label .. ": no header tick -- independent switches")
    check(block:find(g.builder .. "({ group = band, parent = self.child, refreshStates = function() self:RefreshStates() end, })", 1, true) ~= nil,
          g.label .. ": mounts the builder exactly as classic does")
end

print("-- Settings page: what each builder binds, and the summaries")
do
    local modes = builderBody("BuildFrameModesGroup")
    check(modes:find('function() PromptReloadAfterModeToggle("party") end', 1, true) ~= nil
      and modes:find('function() PromptReloadAfterModeToggle("raid") end', 1, true) ~= nil,
          "frame modes: both ticks still raise the contextual reload prompt")
    local sum = PAGE:match("local function FrameModesSummary%(d%)(.-)\n            end")
    check(sum ~= nil and sum:find("d.partyEnabled == false", 1, true) ~= nil
      and sum:find("d.raidEnabled  == false", 1, true) ~= nil and sum:find("not d.partyEnabled", 1, true) == nil,
          "frame modes: the summary tests presence, never truthiness -- absent means enabled")

    local bliz = builderBody("BuildBlizzardFramesGroup")
    local playerKeys = 0
    for _ in bliz:gmatch('"hideDefaultPlayerFrame"') do playerKeys = playerKeys + 1 end
    eq(playerKeys, 3, "blizzard frames: the player tick still names its key three times -- get, set, overrideKey")
    check(bliz:find('makeBlizSet("hideBlizzardPartyFrames", function() DF:UpdateBlizzardFrameVisibility() end)', 1, true) ~= nil,
          "blizzard frames: ...and the party tick still writes both tables")
    check(bliz:find("return not (p and (p.hideBlizzardPartyFrames or p.hideBlizzardRaidFrames))", 1, true) ~= nil,
          "blizzard frames: the side-menu gate is unchanged, inside the builder")

    local render = builderBody("BuildRenderingGroup")
    check(render:find('makeBlizGet("pixelPerfect"), makeBlizSet("pixelPerfect"), "pixelPerfect"', 1, true) ~= nil,
          "rendering: the pixel-perfect tick keeps its get / set / overrideKey trio")
    check(render:find("scaleHint.refreshContent = function()", 1, true) ~= nil
      and render:find("group:AddWidget(scaleHint, 72)", 1, true) ~= nil,
          "rendering: the live scale hint keeps its refreshContent and its slot height")
    local rsum = PAGE:match("local function RenderingSummary%(d%)(.-)\n            end")
    check(rsum ~= nil and rsum:find('rate == "SMOOTH"', 1, true) ~= nil and rsum:find("pixelPerfect", 1, true) == nil,
          "rendering: the summary names a non-default rate and nothing about the other store")

    local psum = PAGE:match("local function PanelAppearanceSummary%(d%)(.-)\n            end")
    check(psum ~= nil and psum:find("DF:GetFontNameFromPath(d.settingsFont)", 1, true) ~= nil,
          "panel appearance: the summary is the font's name, through the dropdown's own resolver")
end

-- ============================================================
-- 3. MINIMAP AND LANGUAGE -- one control each, as a card
-- ============================================================
print("-- Settings page: Minimap and Language")
do
    local MINIMAP = 'GUI:CreateCheckbox(self.child, L["Show Minimap Button"], nil, nil, function() DF:UpdateMinimapButton() end, makeBlizGet("showMinimapButton"), makeBlizSet("showMinimapButton"), "showMinimapButton"), 30)'
    local LANGUAGE = 'GUI:CreateDropdown(self.child, L["Addon Language"], languageValues, DandersFramesCharDB, "languageOverride", PromptLanguageReload), 55)'
    local flat = PAGE:gsub("%s+", " ")
    check(flat:find("minimapGroup:AddWidget(" .. MINIMAP, 1, true) ~= nil
      and PAGE:find("Add(minimapGroup, nil, 1)", 1, true) ~= nil,
          "minimap: classic keeps its box, its tick and column 1")
    check(flat:find("languageGroup:AddWidget(" .. LANGUAGE, 1, true) ~= nil
      and PAGE:find("Add(languageGroup, nil, 2)", 1, true) ~= nil,
          "language: classic keeps its box, its dropdown and column 2")

    local mblock, mcall = sectionBlock("Minimap", "minimapCard:AddWidget(")
    check(mcall:find('OpenSection(L["Minimap"], "general_minimap", 2, nil)', 1, true) ~= nil,
          "minimap: a card keyed general_minimap in column 2 -- no tick, no pin")
    check(mblock:find("minimapCard:AddWidget(" .. MINIMAP, 1, true) ~= nil,
          "minimap: ...holding the SAME call classic makes -- party-canonical read, write to both")

    local lblock, lcall = sectionBlock("Language", "languageCard:AddWidget(")
    check(lcall:find('OpenSection(L["Language"], "general_language", 2, nil)', 1, true) ~= nil,
          "language: a card keyed general_language in column 2 -- no tick, no pin")
    check(lblock:find("languageCard:AddWidget(" .. LANGUAGE, 1, true) ~= nil,
          "language: ...holding the SAME dropdown classic builds, on the per-character store")
    check(lblock:find("Translations are community-contributed and may be incomplete.\"], GUI:GroupInnerWidth(languageCard)))", 1, true) ~= nil,
          "language: ...and its blurb, measured at the card's own width")

    -- ☠ BUILT AT THE FOOT, so they stack after Rendering and Panel Appearance.
    local panelAt = PAGE:find('OpenSection(L["Settings Panel Appearance"]', 1, true)
    local notifyAt = PAGE:find('OpenSection(L["Notifications"]', 1, true)
    local miniAt = PAGE:find('OpenSection(L["Minimap"]', 1, true)
    local langAt = PAGE:find('OpenSection(L["Language"]', 1, true)
    check(panelAt and notifyAt and miniAt and langAt and panelAt < miniAt and notifyAt < miniAt and miniAt < langAt,
          "order: Minimap and Language are the last two cards built")
end

-- ============================================================
-- 4. THE CARDS TOGETHER AND THE CLASSIC BOXES
-- ============================================================
print("-- Settings page: the cards together")
do
    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "),
       "Frame Modes | Blizzard Frames | Rendering | Settings Panel Appearance | Notifications | Minimap | Language",
       "order: the seven cards open in the order they stack")
    check(PAGE:find("hoistToggle", 1, true) == nil, "ticks: nothing on this page has a header tick")
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 7, "classic: seven bare 280 boxes, all the classic branch's own")
end

-- ============================================================
-- 5. THE CLASSIC-LAYOUT ESCAPE HATCH
-- ============================================================
print("-- Settings page: the classic-layout escape hatch")
do
    local body = builderBody("BuildPanelAppearanceGroup")
    check(body:find("GUI:FlipSettingsLayout(", 1, true) ~= nil,
          "escape hatch: the flip routes through the one shared function")
    local panelSrc = options_file_source("GUI/Panel.lua")
    local fa = panelSrc:find("function GUI:FlipSettingsLayout", 1, true)
    local flipBody = fa and panelSrc:sub(fa, panelSrc:find("\nend\n", fa, true) or #panelSrc) or ""
    local closeAt  = flipBody:find('GUI:CloseAllPopoutRows("layoutFlip")', 1, true)
    local invalAt  = flipBody:find("GUI:InvalidateAllPages()", 1, true)
    local rebuildAt = flipBody:find("GUI:RefreshCurrentPage()", 1, true)
    check(closeAt and invalAt and rebuildAt and closeAt < invalAt and invalAt < rebuildAt,
          "escape hatch: ...which closes the open panels (a pinned copy's included), drops every build, then rebuilds")
    check(body:find("C_Timer.After", 1, true) == nil,
          "escape hatch: the rebuild is synchronous")
    check(body:find("function() return DF:IsClassicSettingsLayout() end", 1, true) ~= nil
      and body:find("function(val) DF:SetClassicSettingsLayout(val) end", 1, true) ~= nil,
          "escape hatch: still read from and written to the account-level flag")
end

-- ============================================================
-- 6. THE PAGE'S RULE -- no reset of any kind, anywhere on the page
-- ☠ The per-mode defaults engine can answer for none of these keys, and for the
-- write-both ones a per-mode write would desync the pair.
-- ============================================================
print("-- Settings page: no reset of any kind")
do
    check(PAGE:find("tools.WireModifiedTick(", 1, true) == nil,
          "page rule: WireModifiedTick is not called on this page")
    check(PAGE:find("tools.WireFooter(", 1, true) == nil,
          "page rule: ...nor WireFooter")
    check(PAGE:find("RegisterHoistedToggle", 1, true) == nil,
          "page rule: nothing is hoisted, so nothing is re-registered")
    check(PAGE:find("DF.Defaults", 1, true) ~= nil and PAGE:find("makeBlizSet", 1, true) ~= nil,
          "page rule: the page names the engine that cannot answer, and the setter a reset would desync")
end
