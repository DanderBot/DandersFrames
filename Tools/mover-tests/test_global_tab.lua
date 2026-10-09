local NS = ...

-- ============================================================
-- THE GLOBAL TAB
-- DandersFrames/GUI/GUI.lua, DandersFrames_Options/GUI/Panel.lua,
-- DandersFrames_Options/GUI/SettingsWidgets.lua
-- ------------------------------------------------------------
-- Pages that are not Party's or Raid's sit on a GLOBAL tab in their own accent;
-- Party and Raid show the rest. GUI.SelectedMode stays party/raid underneath.
-- The routing functions are lifted out by name and run over fake nav rows; the
-- wiring around them is checked in the source.
-- ============================================================

local GUISRC   = df_file_source("GUI/GUI.lua"):gsub("\r\n", "\n")
local PANEL    = options_file_source("GUI/Panel.lua"):gsub("\r\n", "\n")
local SW       = options_file_source("GUI/SettingsWidgets.lua"):gsub("\r\n", "\n")
local CONTROLS = options_file_source("GUI/Controls.lua"):gsub("\r\n", "\n")
local AUTOPROF = options_file_source("GUI/Pages/AutoProfiles.lua"):gsub("\r\n", "\n")
local OPTIONS  = options_file_source("GUI/Pages/Options.lua"):gsub("\r\n", "\n")

local function between(src, a, b)
    local s = src:find(a, 1, true)
    if not s then return nil end
    local e = src:find(b, s, true)
    if not e then return nil end
    return src:sub(s, e - 1)
end

-- ---- which pages, and the accent -------------------------------------
print("-- Global tab: the pages and the accent")
local defs = between(GUISRC, "GUI.GlobalAccent = ", "-- Registry of tabs that should show")
check(defs ~= nil, "global: the GLOBAL definitions are in GUI.lua")
local G = { SelectedMode = "party" }
local PARTY, RAID = { r = 0.45 }, { r = 1.0 }
if defs then
    local chunk = loadstring("local GUI, GetThemeColorFor = ...\n" .. defs)
    check(chunk ~= nil, "global: ...and compile on their own")
    if chunk then chunk(G, function(isRaid) return isRaid and RAID or PARTY end) end
end
local want = { "general_settings", "general_integrations", "general_nicknames", "general_fonts", "display_classcolors",
               "auras_filterdesigner", "profiles_manage", "profiles_importexport", "profiles_changed_global", "debug_console" }
for _, id in ipairs(want) do
    check(G.IsGlobalPage and G.IsGlobalPage(id), "pages: " .. id .. " is on GLOBAL")
end
local n = 0
for _ in pairs(G.GlobalPages or {}) do n = n + 1 end
eq(n, #want, "pages: and nothing else")
for _, id in ipairs({ "general_frame", "auras_auradesigner", "text_designer",
                      "profiles_auto", "auras_buffs" }) do
    check(G.IsGlobalPage and not G.IsGlobalPage(id), "pages: " .. id .. " stays on Party/Raid")
end
local ga = G.GlobalAccent or {}
check(ga.r == 0.25 and ga.g == 0.78 and ga.b == 0.85, "accent: GLOBAL is teal-cyan")
if G.CurrentAccent then
    G.GlobalView = true
    check(G.CurrentAccent() == G.GlobalAccent, "accent: GLOBAL up -- its own")
    G.GlobalView = false; G.SelectedMode = "raid"
    check(G.CurrentAccent() == RAID, "accent: otherwise the mode's")
    G.SelectedMode = "party"
end

-- ---- the routing: which rows show, and where a tab lands -------------------
print("-- Global tab: the sidebar and the landing page")
local block = between(PANEL, "    function GUI:IsTabInView(btn)", "    -- Show GLOBAL (true) or the Party/Raid tab under it")
check(block ~= nil, "route: the view helpers are in Panel.lua")
if block then
    local chunk = loadstring("local GUI = ...\n" .. block)
    check(chunk ~= nil, "route: ...and compile on their own")
    if chunk then chunk(G) end
end
local function tab(name, extra)
    local t = { tabName = name }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end
G.Tabs = {}
for _, id in ipairs({ "general_settings", "general_frame", "general_fonts", "display_visibility",
                      "display_classcolors", "debug_console" }) do
    G.Tabs[id] = tab(id, id == "display_visibility" and { partyOnly = true } or nil)
end
G.Categories = {
    general = { children = { G.Tabs.general_settings, G.Tabs.general_frame, G.Tabs.general_fonts } },
    display = { children = { G.Tabs.display_classcolors, G.Tabs.display_visibility },
                navSpec = { "display_visibility", "display_classcolors" } },
    debug   = { children = { G.Tabs.debug_console } },
}
G.CategoryOrder = { "general", "display", "debug" }

if G.IsTabInView and G.FirstTabInView and G.LastTabInView then
    G.GlobalView, G.SelectedMode = false, "party"
    check(not G:IsTabInView(G.Tabs.general_settings), "view: Party does not list Settings")
    check(G:IsTabInView(G.Tabs.general_frame), "view: ...and lists Frame")
    eq(G:FirstTabInView(), "general_frame", "land: Party opens on its first page, Frame")
    G.SelectedMode = "raid"
    check(not G:IsTabInView(G.Tabs.display_visibility), "view: a party-only page is still hidden in raid")
    G.GlobalView = true
    check(G:IsTabInView(G.Tabs.general_settings), "view: GLOBAL lists Settings")
    check(G:IsTabInView(G.Tabs.general_fonts), "view: ...and Fonts")
    check(not G:IsTabInView(G.Tabs.general_frame), "view: ...and not Frame, which is per mode")
    eq(G:FirstTabInView(), "general_settings", "land: GLOBAL opens on its first page, Settings")
    G._lastGlobalPage = "debug_console"
    eq(G:LastTabInView(), "debug_console", "land: GLOBAL comes back to the page it showed last")
    G.GlobalView, G.SelectedMode = false, "party"
    G._lastModePage = "display_visibility"
    eq(G:LastTabInView(), "display_visibility", "land: ...and so does Party")
    G.SelectedMode = "raid"
    eq(G:LastTabInView(), "general_frame", "land: a last page not listed here (party-only in raid) falls back to the first")
    G.SelectedMode = "party"
    G._lastModePage = "general_settings"
    eq(G:LastTabInView(), "general_frame", "land: ...as does one from the other tab")
end

-- ---- the wiring ---------------------------------------------------------
print("-- Global tab: the wiring")
check(PANEL:find('GUI:StyleButton(btnGlobal, { tab = true, tabStripe = false, text = L["GLOBAL"], accent = C_GLOBAL,', 1, true) ~= nil,
      "tab: a GLOBAL tab in its own accent")
check(PANEL:find('btnGlobal:SetPoint("LEFT", deck2, "LEFT", SnapLen(btnGlobal, 12), 1)', 1, true) ~= nil
      and PANEL:find('btnParty:SetPoint("LEFT", btnGlobal, "RIGHT", SnapLen(btnParty, 4), 0)', 1, true) ~= nil,
      "tab: ...left of PARTY, heading the chain")
check(PANEL:find("btnParty:SetActive(not globalView and GUI.SelectedMode == \"party\")", 1, true) ~= nil
      and PANEL:find("local activeModeAccent = (activeMode == btnGlobal and C_GLOBAL)", 1, true) ~= nil,
      "tab: GLOBAL up lights it and not the mode under it; the underline wears its accent")
local sel = between(PANEL, "    local function SelectTab(name)", "        -- ☠ CLOSE OPEN MENUS FIRST.") or ""
check(sel:find("GUI:EnterView(GUI.IsGlobalPage(name))", 1, true) ~= nil,
      "select: asking for a page switches to the tab it lives on (search, cross-links)")
check(PANEL:find("if GUI.IsGlobalPage(name) then GUI._lastGlobalPage = name else GUI._lastModePage = name end", 1, true) ~= nil,
      "select: each tab remembers its last page")
for _, h in ipairs({ "btnParty", "btnRaid", "btnClicks" }) do
    local body = between(PANEL, h .. ':SetScript("OnClick", function()', "DF:SyncLinkedSections()")
              or between(PANEL, h .. ':SetScript("OnClick", function()', "-- Clean up any test/unlock state")
              or ""
    check(body:find("GUI.GlobalView = false", 1, true) ~= nil, "leave: " .. h .. " leaves GLOBAL")
end
check(PANEL:find("local first = GUI:FirstTabInView()\n    if first then SelectTab(first) end", 1, true) ~= nil,
      "open: the window's first page is the first on the tab it opens on")
check(SW:find("if cur and not GUI:IsTabInView(cur) then", 1, true) ~= nil
      and SW:find('GUI.SelectTab("general_settings")', 1, true) == nil,
      "redirect: a page no longer listed moves to the tab's last page, not to Settings (now GLOBAL's)")
check(SW:find("if GUI.IsGlobalPage and GUI.IsGlobalPage(tabName) then return false end", 1, true) ~= nil,
      "greyed: a GLOBAL page is never greyed by a mode being off")
check(CONTROLS:find("GUI:SetAccent(GUI.CurrentAccent())", 1, true) ~= nil,
      "open: the window reopens in the accent of the tab it was closed on")
check(AUTOPROF:find("local buttonsToDisable = {GUI.GlobalButton, GUI.PartyButton, GUI.ClicksButton}", 1, true) ~= nil,
      "editing: GLOBAL is locked with Party and Binds while an auto layout is edited")
check(OPTIONS:find("Settings on this page apply globally", 1, true) == nil,
      "settings: the 'applies globally' banner is gone -- the tab says it")

print("-- Global tab: a page painted in the other tab's accent is repainted whole")
do
    local fn = PANEL:match("\n    local function RepaintTree%(frame, depth%).-\n    end\n")
    check(fn ~= nil, "repaint: the tree walk can be read")
    local RepaintTree = fn and loadstring(fn .. "\nreturn RepaintTree")()
    if RepaintTree then
        local painted = {}
        local function w(name) return { UpdateTheme = function() painted[#painted + 1] = name end } end
        local function node(list, ...)
            local kids = { ... }
            return { ThemeListeners = list, GetChildren = function() return unpack(kids) end }
        end
        local strip = node({ w("expand"), w("collapse") })
        local card  = node({ w("arrow") }, node({ w("nested") }))
        RepaintTree(node(nil, strip, card), 0)
        eq(table.concat(painted, ","), "expand,collapse,arrow,nested",
           "repaint: listeners on a strip and inside a card are reached")
    end
    check(PANEL:find("if built and built._themedAccent ~= stamp then", 1, true) ~= nil
      and PANEL:find("for _, child in ipairs(built) do RepaintTree(child, 0) end", 1, true) ~= nil,
          "repaint: only the active build is walked, once per accent it is shown in")
    local SECT = ui_file_source("Sections.lua"):gsub("\r\n", "\n")
    local tone = SECT:match("function banner:SetTone%(toneName%).-\n    end\n")
    check(tone and tone:find("table.insert(p.ThemeListeners, self)", 1, true) ~= nil,
          "repaint: an accent-bordered banner registers for the repaint")
    local WID = ui_file_source("Widgets.lua"):gsub("\r\n", "\n")
    local apply = WID:match("btn.ApplyThemeColor = function%(c%)(.-)\n        applyWash%(c%)")
    check(apply and apply:find("if btn.dfDisabled then", 1, true) and apply:find("hl:SetVertexColor(c.r, c.g, c.b, 0)", 1, true),
          "repaint: a greyed button stays greyed -- its hover wash is not brought back")
end

print("-- Global tab: back to the mode it sat on is not a mode switch")
do
    local fn = PANEL:match("\n    local function LeaveGlobalTo%(mode%).-\n    end\n")
    check(fn ~= nil, "leave: the shortcut can be read")
    local LeaveGlobalTo = fn and loadstring("local GUI = ...\n" .. fn .. "\nreturn LeaveGlobalTo")
    if LeaveGlobalTo then
        local calls = {}
        local G = { GlobalView = true, SelectedMode = "party" }
        function G:EnterView(g) calls[#calls + 1] = "view:" .. tostring(g); self.GlobalView = g end
        function G:LastTabInView() return "general_frame" end
        G.SelectTab = function(n) calls[#calls + 1] = "tab:" .. n end
        local leave = LeaveGlobalTo(G)
        eq(leave("raid"), false, "leave: to the OTHER mode it is a real switch")
        eq(#calls, 0, "leave: ...and the shortcut touches nothing")
        eq(leave("party"), true, "leave: to the mode underneath it takes the shortcut")
        eq(table.concat(calls, ","), "view:false,tab:general_frame", "leave: ...the view, then the page that tab showed last")
        G.GlobalView = false; calls = {}
        eq(leave("party"), false, "leave: from Party itself it does nothing")
    end
    check(PANEL:find('btnParty:SetScript("OnClick", function()\n        if LeaveGlobalTo("party") then return end', 1, true) ~= nil
      and PANEL:find('btnRaid:SetScript("OnClick", function()\n        if LeaveGlobalTo("raid") then return end', 1, true) ~= nil,
          "leave: both mode buttons ask first")
end
