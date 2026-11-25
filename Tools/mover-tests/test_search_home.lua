local NS = ...

-- ============================================================
-- HOME'S SEARCH -- Features/Search.lua (Find, ResultRowModel, NavigateToTab)
-- ------------------------------------------------------------
-- Home's box reads the same sources as the side menu's filter: every page's live
-- entries when it has a current build, else its prebuilt rows. It builds no
-- page, ranks as before, and every result is a "go to setting" row that lands
-- through the shared settings link (which clears the side menu's filter first).
-- Drives the REAL search files against a fake window.
-- ☠ ONE LUA RUNTIME FOR EVERY SUITE: globals swapped here are restored at the end.
-- ============================================================

local savedDF, savedTimer, savedLocale = DandersFrames, C_Timer, GetLocale
C_Timer = { After = function() end, NewTimer = function() return { Cancel = function() end } end }
GetLocale = function() return "enUS" end

local DF = {}
DF.L = setmetatable({}, { __index = function(_, k) return k end })
DF.PartyDefaults = setmetatable({}, { __index = function() return 0 end })
DF.RaidDefaults = DF.PartyDefaults
function DF:DebugWarn() end
DF.db = { party = {} }
local links = {}
local GUI = {
    SelectedMode = "party", CurrentPageName = "general_frame", Pages = {}, Tabs = {},
    SettingsBox = { pad = 10, group = 280, colMargin = 15, minCol = 290, colGutter = 20 },
}
function GUI:LinkToSetting(target) links[#links + 1] = target end
function GUI:IsTabInView(btn) return btn.inView end
function GUI:UpdateTabLayout() end
local MODULE = {
    general_frame = "group", display_fading = "group", uf_player_health = "units",
    auras_auradesigner = "group", global_fonts = "global",
}
local LABEL = { group = "Group Frames", units = "Unit Frames", global = "Global" }
function GUI:ModuleForPage(name) return MODULE[name] end
function GUI:GetModule(id) return { id = id, label = function() return LABEL[id] end } end
DF.GUI = GUI

local builds = 0
local function Page(name, label, searchLabel)
    local p = { tabName = name, tabLabel = label, searchTabLabel = searchLabel, children = {} }
    function p:GetIndexEntries() return nil end   -- no page built this session
    function p:Refresh() builds = builds + 1 end
    p.RefreshForIndex = p.Refresh
    function p:IsShown() return false end
    function p:Hide() end
    function p:Show() end
    GUI.Pages[name] = p
    GUI.Tabs[name] = { tabName = name, inView = true }
    return p
end
Page("general_frame", "Frame")
Page("display_fading", "Fading")
Page("uf_player_health", "Health", "Player \194\183 Health")
Page("auras_auradesigner", "Aura Designer")
Page("global_fonts", "Fonts")

DandersFrames = DF
load_options_file_into("Features/Search.lua", NS)
load_options_file_into("Features/SearchSynonyms.lua", NS)
load_options_file_into("Features/SearchMatch.lua", NS)
load_options_file_into("Features/SearchPrebuilt.lua", NS)
load_options_file_into("Features/SearchFilter.lua", NS)
DandersFrames = savedDF
local S = DF.Search

S.PrebuiltIndex = {
    version = "t", commit = "0", rows = 7,
    S = { "Global Frame Fade", "Appearance", "frameFadeAlpha", "Fades the whole frame.",
          "Frame Fade", "Health Bar Alpha", "Colors", "healthBarAlpha", "Border Thickness", "Icon",
          "Font Outline", "Fonts", "globalFontOutline", "Fade Thing" },
    C = {},
    P = {
        general_frame      = { 1, 2, 3, 4, 0, 0,   2, 2, 0, 0, 0, 1 },
        display_fading     = { 14, 5, 0, 0, 0, 0 },
        uf_player_health   = { 6, 7, 8, 0, 0, 0 },
        auras_auradesigner = { 9, 10, 0, 0, 0, 0 },
        global_fonts       = { 11, 12, 13, 0, 0, 0 },
    },
}

local function find(q, label)
    for _, e in ipairs(S:Find(q)) do if e.label == label then return e end end
end

print("-- Home search: builds no page")
local r = S:Find("fade")
check(#r >= 2, "find: results from the prebuilt index (" .. #r .. ")")
eq(builds, 0, "find: no page was built")
check(not S.RegistryBuilding and (S._buildToken or 0) == 0, "find: no index build was started")

print("-- Home search: ranking stays as it was")
eq(S:Find("global frame fade")[1].label, "Global Frame Fade", "rank: the closest name first")
local any = S:Find("border zzzq")
check(#any >= 1 and any[1].label == "Border Thickness", "rank: any-word fallback only when no entry has every word")

print("-- Home search: every result is a 'go to' row")
local m = S:ResultRowModel(find("global frame fade", "Global Frame Fade"))
eq(m.label, "Global Frame Fade", "row: the label")
check(m.path:find("Group Frames", 1, true) and m.path:find("Frame", 1, true) and m.path:find("Appearance", 1, true),
      "row: the path names module, page and card (" .. m.path .. ")")
eq(m.tip, "Fades the whole frame.", "row: the tooltip is the subline")
eq(m.page, "general_frame", "row: goes to its page")
eq(m.section, "Appearance", "row: ...and its card")
eq(m.key, "frameFadeAlpha", "row: ...for its setting")
local u = S:ResultRowModel(find("health bar alpha", "Health Bar Alpha"))
check(u.page == "uf_player_health" and u.path:find("Unit Frames", 1, true) and u.path:find("Player", 1, true),
      "row: a unit frame result goes to that unit's page (" .. u.path .. ")")
local sec = find("appearance", "Appearance")
check(sec and sec.isSection and S:ResultRowModel(sec).page == "general_frame", "row: a card's own row goes to the card")

print("-- Home search: a click lands through the shared link, filter cleared first")
S:SetFilterText("fade")
S.Filter.text = "fade"
S.Filter.active = true
local function click(model) S:NavigateToTab(model.page, model.section, model.key) end
links = {}
click(m)
check(links[1] and links[1].page == "general_frame" and links[1].section == "Appearance", "land: the group page and card")
check(S.Filter.text == "" and not S:FilterActive(), "land: the side menu's filter was cleared first")
links = {}
click(u)
eq(links[1] and links[1].page, "uf_player_health", "land: the unit's own page (SelectTab moves the unit tab)")
links = {}
click(S:ResultRowModel(find("border thickness", "Border Thickness")))
eq(links[1] and links[1].page, "auras_auradesigner", "land: a designer page")
links = {}
click(S:ResultRowModel(find("font outline", "Font Outline")))
eq(links[1] and links[1].page, "global_fonts", "land: a global page")
eq(builds, 0, "land: and still nothing built by the search itself")

print("-- Home search: the wiring")
local SRC = options_file_source("Features/Search.lua"):gsub("\r\n", "\n")
check(SRC:find("local MAX_RESULTS = 60", 1, true) and SRC:find("panel.rowPool[i]", 1, true),
      "wiring: a fixed pool of at most MAX_RESULTS rows")
check(not SRC:find("CreateInlineCheckbox", 1, true) and not SRC:find("cardCacheKey(", 1, true),
      "wiring: no live controls in results (one kind of row)")

DandersFrames, C_Timer, GetLocale = savedDF, savedTimer, savedLocale
