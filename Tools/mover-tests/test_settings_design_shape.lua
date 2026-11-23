local NS = ...

-- ============================================================
-- HOME, MODULES AND PROFILES -- DRAWN TO THE MOCKUP
-- docs/superpowers/specs/2026-10-30-settings-nav-options.html (homeLaunch,
-- modulesPage, profilesPage). Source shape only: the curved corners are the
-- kit's rounded surface (never a square backdrop), the Profiles pages are the
-- shared collapsible cards, Auto Layouts says it is raid-only, and each
-- Profiles page carries its own accent.
-- ⚠ Headless: nothing here builds a frame. The look is checked in game.
-- ============================================================

local function src(name) return options_file_source(name):gsub("\r\n", "\n") end
local HOME = src("GUI/Pages/Home.lua")
local MODS = src("GUI/Pages/ModulesPage.lua")
local PROF = src("GUI/Pages/Profiles.lua")
local PANEL = src("GUI/Panel.lua")
local REG = src("GUI/ModuleRegistry.lua")
local SEARCH = src("Features/Search.lua")
local GUISRC = df_file_source("GUI/GUI.lua"):gsub("\r\n", "\n")
local ENUS = df_file_source("Locales/enUS.lua"):gsub("\r\n", "\n")

local function count(s, plain)
    local n, at = 0, 1
    while true do
        local i = s:find(plain, at, true)
        if not i then return n end
        n, at = n + 1, i + #plain
    end
end

print("-- Settings design: Home is built from rounded surfaces")
check(HOME:find("GUI:CreateElementBackdrop", 1, true) == nil and HOME:find("GUI:CreatePanelBackdrop", 1, true) == nil,
      "home: no square backdrop left on the page")
check(HOME:find('t.surface = GUI:CreateRoundedSurface(t, { radius = 6,', 1, true) ~= nil, "home: a tile is a radius-6 rounded panel")
check(HOME:find('t.boxSurface = GUI:CreateRoundedSurface(box, { radius = 8,', 1, true) ~= nil, "home: ...with a radius-8 icon box")
check(HOME:find('p.surface = GUI:CreateRoundedSurface(p, { radius = 8,', 1, true) ~= nil, "home: a panel is radius 8")
check(HOME:find('r.plate = GUI:CreateRoundedSurface(r, { radius = 4,', 1, true) ~= nil, "home: an attention row is a rounded plate")
check(HOME:find('pill.surface = GUI:CreateRoundedSurface(pill, { radius = 8,', 1, true) ~= nil, "home: the count is a pill")
check(HOME:find('tag.surface = GUI:CreateRoundedSurface(tag, { radius = 4,', 1, true) ~= nil, "home: What's new tags are pills")
check(HOME:find("local MAX_W = 900", 1, true) ~= nil and HOME:find("local SEARCH_H = 52", 1, true) ~= nil,
      "home: the mockup's column (900) and search height (52)")
check(HOME:find("S:CreateSearchBar(view, { radius = 8,", 1, true) ~= nil, "home: the search box is the search's own bar, rounded")
check(HOME:find("Ctrl", 1, true) == nil, "home: no key hint for a shortcut that does not exist")

print("-- Settings design: the search bar's rounded well")
check(SEARCH:find("function Search:CreateSearchBar(parent, opts)", 1, true) ~= nil, "search: the bar takes opts")
check(SEARCH:find("DF.GUI:ApplyRoundedChrome(frame, { radius = opts.radius, fill = IC.fill, border = IC.edge })", 1, true) ~= nil,
      "search: ...and draws the SAME input well, rounded")
check(ui_file_source("Widgets.lua"):find("UI.InputColors = { fill = INPUT_FILL, edge = INPUT_EDGE }", 1, true) ~= nil,
      "kit: the input well's colours are published, not copied")

print("-- Settings design: the Modules page")
check(MODS:find("GUI:CreateElementBackdrop", 1, true) == nil, "modules: no square backdrop left on the page")
check(MODS:find('row.plate = GUI:CreateRoundedSurface(row, { radius = 6,', 1, true) ~= nil, "modules: a row is a rounded plate")
check(MODS:find('box.surface = GUI:CreateRoundedSurface(box, { radius = 6,', 1, true) ~= nil, "modules: ...with a rounded icon box")
check(MODS:find('note.surface = GUI:CreateRoundedSurface(note, { radius = 6,', 1, true) ~= nil, "modules: the reload note is a rounded box")
check(MODS:find("GUI:CreateCheckRow(row,", 1, true) ~= nil, "modules: the switch is the shared checkbox, not a hand-rolled one")

print("-- Settings design: every Profiles page is the shared cards")
check(PROF:find("GUI:CreateSettingsGroup", 1, true) == nil, "profiles: no bare settings box left")
check(PROF:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true) ~= nil
      and PROF:find("tools.OpenSection(Add, label, key, col, summaryFn, nil, hideFn, nil, nil, { kind = kind })", 1, true) ~= nil,
      "profiles: the cards are the page tools' OpenSection")
for _, fn in ipairs({ "BuildManage", "BuildSpec", "BuildClickCast", "BuildImportExport", "BuildChangedSettings" }) do
    local a = PROF:find("local function " .. fn .. "(", 1, true)
    local b = a and PROF:find("\nend\n", a, true)
    local body = (a and b) and PROF:sub(a, b) or ""
    check(body:find("Cards(self, Add)", 1, true) ~= nil, "profiles: " .. fn .. " builds its cards")
    -- At least one Close per Open (an early return closes its card too).
    check(count(body, "K.Open(") > 0 and count(body, "K.Close(") >= count(body, "K.Open("),
          "profiles: " .. fn .. " closes every card it opens")
end
for _, key in ipairs({ "Active", "Actions", "Automatic", "Import", "Export" }) do
    check(PROF:find('K.Header(L["' .. key .. '"]', 1, true) ~= nil, "profiles: a " .. key .. " group header")
end

print("-- Settings design: Auto Layouts is raid only, and says so")
local BANNER = "Auto Layouts change your raid frames by content. Party frames are not affected."
check(PROF:find('dismissKey = "profiles_auto_raidonly"', 1, true) ~= nil and PROF:find('L["' .. BANNER .. '"]', 1, true) ~= nil,
      "auto: the raid-only banner")
check(ENUS:find('L["' .. BANNER .. '"] = true', 1, true) ~= nil and ENUS:find('L["Active"] = true', 1, true) ~= nil
      and ENUS:find('L["Automatic"] = true', 1, true) ~= nil, "locale: the new strings ship in enUS")
check(PROF:find('tag:SetText(L["RAID"])', 1, true) ~= nil and PROF:find("autoTab.raidTag = tag", 1, true) ~= nil,
      "auto: a RAID tag on its sidebar row")
check(PROF:find('function() return GUI.ProfilesAccentFor("profiles_auto") end', 1, true) ~= nil,
      "auto: the banner wears the page's accent")

print("-- Settings design: a Profiles page carries its own accent")
check(GUISRC:find("profiles_auto      = function() return GetThemeColorFor(true) end,", 1, true) ~= nil,
      "accent: Auto Layouts is Raid's")
check(GUISRC:find("profiles_clickcast = function() return GUI.ClicksAccent or GUI.GlobalAccent end,", 1, true) ~= nil,
      "accent: Click Casting is Binds' green")
check(GUISRC:find("return f and f() or GUI.GlobalAccent", 1, true) ~= nil, "accent: every other Profiles page is teal")
check(PANEL:find("if GUI.ProfilesView and GUI.CurrentAccent then GUI:SetAccent(GUI.CurrentAccent(name)) end", 1, true) ~= nil,
      "accent: SelectTab moves the accent with the page, before the page shows")
check(REG:find("if GUI.ProfilesView and GUI.CurrentAccent then return GUI.CurrentAccent() end", 1, true) ~= nil,
      "accent: the rail item and deck 2's crumb follow it")

print("-- Settings design: buttons on Home and Modules are rounded")
do
    local W = ui_file_source("Widgets.lua"):gsub("\r\n", "\n")
    check(W:find("if opts.rounded and not rawget(btn, \"RoundedSurface\") then", 1, true) ~= nil,
          "kit: StyleButton takes opts.rounded")
    check(W:find("btn.SetBackdropColor = function(_, r, g, b, a) surf:SetFillColor(r, g, b, a) end", 1, true) ~= nil,
          "kit: ...and every backdrop paint lands on the rounded surface")
    local H, M = src("GUI/Pages/Home.lua"), src("GUI/Pages/ModulesPage.lua")
    check(H:find('text = L["Manage modules"], height = 24, tinted = true, rounded = true,', 1, true) ~= nil,
          "home: Manage modules is a rounded button")
    check(H:find('width = 80, height = 24, rounded = true', 1, true) ~= nil, "home: attention fix buttons are rounded")
    check(M:find('width = 62, height = 24, rounded = true', 1, true) ~= nil, "modules: Open buttons are rounded")
end
