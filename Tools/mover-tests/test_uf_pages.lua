local NS = ...

-- ============================================================
-- UNIT FRAMES SETTINGS PAGES
-- DandersFrames_Options/UnitFrames/Pages.lua, PageData.lua (generated)
-- + the neutral hooks they ride on: GUI/ModuleRegistry.lua (pageInView,
--   tabForPage, pageForTab), GUI/Controls.lua (page.sectionFilter),
--   Features/Search.lua (Search.EntryFilter), GUI/Pages/Options.lua (the copy
--   row's mark, GUI.PlayerFrameOwnerNote), AuraDesigner (standalone enable).
-- ------------------------------------------------------------
-- The real module registry, the real companion Core/Defaults and the real UF
-- pages file run over stub frames. Three install states (missing, installed and
-- switched off, loaded). The party pages' builders are stood in for by a fake
-- builder that asks the same questions a real one does (sectionFilter per card,
-- a search entry per control, the copy row); the real card filter is checked
-- separately on GUI:CreatePopoutPageTools cut out of Controls.lua.
-- ============================================================

local saved = {
    DandersFrames = DandersFrames, CreateFrame = CreateFrame, C_AddOns = C_AddOns,
    C_Timer = C_Timer, ReloadUI = ReloadUI,
}
C_Timer = { After = function(_, fn) fn() end }
ReloadUI = function() end

-- ---- stub frames -------------------------------------------------------------
local function noop() end
local FrameMT = { __index = function(_, k)
    if type(k) == "string" and k:match("^%u") then return noop end
end }
local function Frame()
    local f = setmetatable({ shown = true }, FrameMT)
    f.Hide = function(self) self.shown = false end
    f.Show = function(self) self.shown = true end
    f.IsShown = function(self) return self.shown end
    f.SetParent = function(self, p) self.parent = p end
    f.CreateFontString = function()
        return setmetatable({ GetStringWidth = function() return 40 end }, FrameMT)
    end
    return f
end
local function MakeCreateFrame() return function() return Frame() end end

-- ---- the companion (real Core + Defaults) ------------------------------------
local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

local popups, says = {}, {}
local postDrains = {}
local DF = {
    PartyDefaults = {
        frameWidth = 125, frameHeight = 64, frameSpacing = 2, healthColorMode = "CLASS",
        healthTexture = "DF Minimalist", healthColor = { r = 0.5, g = 0.7, b = 0.2, a = 1 },
        textDesignerPreset = "Default", tooltipFrameEnabled = true,
    },
    SECTION_PREFIXES = {
        bars_health = { "healthColor", "healthOrientation", "healthTexture", "classColor", "smoothBars" },
        general_frame = { "frame", "permanentMover", "border", "anchor" },
    },
}
DF.L = setmetatable({}, { __index = function(_, k) return k end })
function DF:Debug() end
function DF:DebugWarn() end
local errors = {}
function DF:DebugError(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable() return true end
DF.RegisterCallback = function() end
DF.Apply = { AddPostDrain = function(_, fn) postDrains[#postDrains + 1] = fn end }
function DF:ShowPopupAlert(cfg) popups[#popups + 1] = cfg end
function DF:Say(msg) says[#says + 1] = msg end
DandersFrames = DF

CreateFrame = nil        -- the companion's file-scope event wiring is skipped
local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Links.lua", UF)
load_uf_file_into("Defaults.lua", UF)
CreateFrame = MakeCreateFrame()
DF.db = { unitframes = deepcopy(UF.ProfileDefaults) }
UF.frames = {}

-- ---- C_AddOns, per scenario -------------------------------------------------
local addon = { exists = true, loaded = true, enabled = true }
C_AddOns = {
    DoesAddOnExist = function(name) return name == "DandersFrames_UnitFrames" and addon.exists end,
    IsAddOnLoaded = function(name) return name == "DandersFrames_UnitFrames" and addon.loaded end,
    GetAddOnEnableState = function(name) return (name == "DandersFrames_UnitFrames" and addon.enabled) and 2 or 0 end,
    EnableAddOn = function() addon.enabled = true end,
    DisableAddOn = function() addon.enabled = false end,
}

-- ---- a fresh settings window for each scenario --------------------------------
local calls
local function NewGUI()
    calls = {}
    local G = {
        SelectedMode = "party", GlobalView = false, GlobalAccent = { r = 0.25 },
        GlobalPages = { general_settings = true }, Pages = {},
        Colors = { text = { r = 1, g = 1, b = 1 }, textDim = { r = 0.5, g = 0.5, b = 0.5 },
                   panel = { r = 0, g = 0, b = 0 }, border = { r = 0.3, g = 0.3, b = 0.3 } },
    }
    function G.IsGlobalPage(name) return G.GlobalPages[name] == true end
    function G.GetThemeColorFor(isRaid) return isRaid and "RAID" or "PARTY" end
    function G:SetAccent() end
    function G.CurrentAccent() return "ACCENT" end
    function G.UpdateThemeColors() end
    function G:ShowNormalContent() calls[#calls + 1] = "normal" end
    function G:ShowPlaceholderContent() end
    function G:ShowClickCastingContent() end
    function G:RefreshCurrentPageForModeSwitch() calls[#calls + 1] = "refresh" end
    function G:UpdateTabLayout() calls[#calls + 1] = "layout" end
    function G:LastTabInView() return nil end
    function G:EnterView(g) G.GlobalView = g and true or false end
    G.SelectTab = function(n) calls[#calls + 1] = "tab:" .. tostring(n); G.CurrentPageName = n end
    function G:CreatePopoutPageTools() return nil end
    DF.GUI = G
    DF.GUIPageProviders = {}
    load_options_file_into("GUI/ModuleRegistry.lua", NS)
    return G
end

local function LoadPages()
    load_options_file_into("UnitFrames/PageData.lua", NS)
    load_options_file_into("UnitFrames/Pages.lua", NS)
    load_options_file_into("UnitFrames/LinksPage.lua", NS)
    return DF.GUI.UnitFrameOptions
end

local data = nil

-- ============================================================
-- 1. NOT INSTALLED: Unit Frames stays "Coming soon"
-- ============================================================
print("-- Not installed")
do
    addon.exists, addon.loaded, addon.enabled = false, false, false
    local G = NewGUI()
    LoadPages()
    local def = G:GetModule("units")
    check(def and def.comingSoon, "missing: still coming soon")
    check(def and def.setEnabled == nil, "missing: no switch")
    eq(#DF.GUIPageProviders, 0, "missing: no page provider")
    check(G.PlayerFrameOwnerNote == nil, "missing: DF's own player-frame ticks stay")
    load_options_file_into("GUI/Pages/ModulesPage.lua", NS)
    local _, _, soon = G:ModulesPageModel()
    local found = false
    for _, d in ipairs(soon) do if d.id == "units" then found = true end end
    check(found, "missing: the Modules page lists it under Coming soon")
end

-- ============================================================
-- 2. INSTALLED, SWITCHED OFF: an Off row with a switch, no rail item
-- ============================================================
print("-- Installed but switched off")
do
    addon.exists, addon.loaded, addon.enabled = true, false, false
    local G = NewGUI()
    local UFO = LoadPages()
    local def = G:GetModule("units")
    check(def and not def.comingSoon, "off: no longer coming soon")
    eq(type(def and def.setEnabled), "function", "off: the Modules page gets a switch")
    eq(def.isEnabled(), false, "off: isEnabled says off (the rail leaves it out)")
    eq(#DF.GUIPageProviders, 0, "off: no page provider while the addon is not loaded")
    load_options_file_into("GUI/Pages/ModulesPage.lua", NS)
    local _, off = G:ModulesPageModel()
    local found = false
    for _, d in ipairs(off) do if d.id == "units" then found = true end end
    check(found, "off: the Modules page lists it under Off")
    eq(UFO.Status(), "Off", "off: status")

    popups = {}
    def.setEnabled(true, nil, function() calls[#calls + 1] = "done" end)
    eq(addon.enabled, true, "switch on: EnableAddOn")
    eq(#popups, 1, "switch on: the reload prompt (it is not loaded yet)")
    eq(popups[1] and popups[1].title, "Reload Required", "...titled as DF's reload prompt")
    eq(def.isEnabled(), true, "switch on: isEnabled follows the enable state")
    -- Switched on, not reloaded: the rail item's panel says so, with the reload.
    eq(def.placeholderNote(), "Reload to finish turning on Unit Frames.", "on, not loaded: the panel says reload")
    local act = def.placeholderAction()
    eq(act and act.label, "Reload Now", "...with a Reload button")
    local reloaded = 0
    local heldReload = ReloadUI
    ReloadUI = function() reloaded = reloaded + 1 end
    if act then act.onClick() end
    ReloadUI = heldReload
    eq(reloaded, 1, "...that reloads")
    def.setEnabled(false)
    eq(addon.enabled, false, "switch off: DisableAddOn")
    eq(def.placeholderNote(), nil, "off: no reload note")
    eq(def.placeholderAction(), nil, "off: no button")
    local rail = options_file_source("GUI/Rail.lua")
    check(rail:find("local note = def.placeholderNote and def.placeholderNote()", 1, true)
          and rail:find("panel.Note:SetText(note or L[\"Coming in a later update.\"])", 1, true)
          and rail:find("local act = def.placeholderAction and def.placeholderAction()", 1, true),
          "the placeholder panel shows a module's own note and action")
end

-- ============================================================
-- 3. LOADED: the provider, the module, the pages
-- ============================================================
print("-- Loaded: the provider")
addon.exists, addon.loaded, addon.enabled = true, true, true
local G = NewGUI()
local UFO = LoadPages()
data = DF.UnitFramePageData
eq(#DF.GUIPageProviders, 1, "loaded: one page provider")
eq(type(G.PlayerFrameOwnerNote), "function", "loaded: the player-frame note hook is set")
check(#postDrains >= 1, "loaded: the sync rides DF's apply drain")

local made = { cats = {}, catOrder = {}, pages = {}, pageOrder = {} }
local function CreateCategory(name, label) made.cats[name] = label; made.catOrder[#made.catOrder + 1] = name end
local function CreateSubTab(cat, name, label)
    local p = { tabName = name, tabLabel = label, cat = cat, child = Frame(), children = {} }
    made.pageOrder[#made.pageOrder + 1] = name
    made.pages[name] = p
    G.Pages[name] = p
    return p
end
local function BuildPage(page, fn) page.builder = fn end
G:RunPageProviders(CreateCategory, CreateSubTab, BuildPage)
eq(#errors, 0, "the provider ran without errors (" .. tostring(errors[1]) .. ")")

print("-- Loaded: the module")
local def = G:GetModule("units")
check(def and def.sidebar and def.sidebarModule, "units: a sidebar module of its own")
check(not def.comingSoon and not def.placeholder, "units: no longer a placeholder")
check(G:IsModuleOn("units"), "units: on")
eq(def.accent(), G.UnitsAccent, "units: the violet accent")
eq(string.format("%.3f %.3f %.3f", G.UnitsAccent.r, G.UnitsAccent.g, G.UnitsAccent.b), "0.651 0.420 1.000",
   "the accent is #a66bff")
eq(#def.tabs, 6, "units: six deck-2 tabs")
local tabIds = {}
for i, t in ipairs(def.tabs) do tabIds[i] = t.id end
eq(table.concat(tabIds, ","), "player,target,targettarget,focus,pet,boss", "units: in spec order")
eq(def.tabs[3].label(), "Target of Target", "ToT's tab: full name")
eq(def.tabs[3].deckLabel(), "TOT", "...short on deck 2")
eq(G:ModuleLabel(def), "Unit Frames", "label")
eq(def.railLabel(), "Units", "rail label")
eq(def.status(), "Player \194\183 Target \194\183 ToT \194\183 Focus \194\183 Focus Target \194\183 Pet \194\183 Boss", "status: the units it draws")
load_options_file_into("GUI/Pages/ModulesPage.lua", NS)
do
    local on = G:ModulesPageModel()
    local found = false
    for _, d in ipairs(on) do if d.id == "units" then found = true end end
    check(found, "Modules page: listed On, with its switch")
end

print("-- Loaded: each unit gets exactly its pages")
eq(made.catOrder[1], "uf_module", "the module-wide category comes first")
check(made.pages.uf_settings ~= nil, "the module Settings page exists")
eq(G:ModuleForPage("uf_settings"), "units", "...on the module's sidebar")
local WANT = {
    player = "frame,visibility,tooltips,fading,portrait,health,resource,absorbs,healpred,castbar,classpower,text,buffs,debuffs,defensive,dispel,auradesigner,icons,unitIcons,highlights",
    target = "frame,visibility,tooltips,fading,portrait,health,resource,absorbs,healpred,castbar,text,buffs,debuffs,icons,unitIcons,highlights",
    targettarget = "frame,tooltips,health,text,highlights",
    focustarget = "frame,tooltips,health,text,highlights",
    focus ="frame,visibility,tooltips,fading,portrait,health,resource,absorbs,healpred,castbar,text,buffs,debuffs,icons,unitIcons,highlights",
    pet = "frame,visibility,tooltips,fading,portrait,health,resource,absorbs,healpred,castbar,text,buffs,debuffs,auradesigner,icons,highlights",
    boss = "frame,bosslayout,tooltips,fading,portrait,health,resource,absorbs,castbar,text,buffs,debuffs,icons,highlights",
}
for _, unit in ipairs(UFO.UNITS) do
    local kinds = {}
    for _, rec in ipairs(data.pages) do
        local name = "uf_" .. unit .. "_" .. rec.kind
        if made.pages[name] then
            kinds[#kinds + 1] = rec.kind
            check(not rec.later, unit .. ": no page waiting for its runtime is built (" .. rec.kind .. ")")
            eq(G:ModuleForPage(name), "units", name .. ": owned by the module")
        else
            check(rec.later or not rec.units[unit], unit .. ": " .. rec.kind .. " is in the table but was not built")
        end
    end
    eq(table.concat(kinds, ","), WANT[unit], unit .. ": its pages, in sidebar order")
end
check(made.pages.uf_boss_bosslayout ~= nil, "Boss Layout: built now the boss frames exist")
eq(made.pages.uf_boss_bosslayout.cat, "uf_general", "...under General, after Frame")
eq(made.pages.uf_player_bosslayout, nil, "...for Boss only")
eq(made.pages.uf_boss_visibility, nil, "Boss has no Visibility page (the inventory gives it none)")
check(made.pages.uf_player_castbar ~= nil and made.pages.uf_player_classpower ~= nil
      and made.pages.uf_player_portrait ~= nil and made.pages.uf_player_unitIcons ~= nil,
      "Cast Bar, Class Power, Portrait, Unit Icons: built now their runtime exists")
eq(made.pages.uf_target_classpower, nil, "...Class Power for the player only")
eq(made.pages.uf_targettarget_castbar, nil, "...no cast bar page for target of target")
eq(made.pages.uf_pet_unitIcons, nil, "...no Unit Icons page where no card reaches the unit")
do
    local icons
    for _, rec in ipairs(data.pages) do if rec.kind == "icons" then icons = rec end end
    eq(icons and icons.laterCards, nil, "the Icons page's Unit group moved to a page of its own")
end
check(made.pages.uf_player_visibility ~= nil, "Visibility: built now its runtime exists")
eq(made.pages.uf_targettarget_visibility, nil, "...but not for target of target (no card reaches it)")
eq(made.pages.uf_target_health.cat, "uf_bars", "a page sits in its own category")
eq(made.cats.uf_bars, "Bars", "...labelled as DF's")

print("-- Loaded: search page ids and labels")
eq(made.pages.uf_target_health.searchTabLabel, "Target \194\183 Health Bar", "search names the unit")
eq(made.pages.uf_targettarget_frame.searchTabLabel, "Target of Target \194\183 Frame", "...every unit")
eq(made.pages.uf_settings.searchTabLabel, "Unit Frames \194\183 Settings", "...and the module page")

print("-- Loaded: a party builder's in-page links go to the unit's own pages")
do
    eq(UFO.MapPageLink("player", "auras_auradesigner"), "uf_player_auradesigner",
       "the Aura Designer link: the unit's own Aura Designer page")
    eq(UFO.MapPageLink("target", "auras_auradesigner"), false, "...none for a unit without one (link left out)")
    eq(UFO.MapPageLink("target", "bars_health"), "uf_target_health", "a sourced page: the unit's copy")
    eq(UFO.MapPageLink("target", "auras_filterdesigner"), nil, "a page no unit has a copy of: left as it is")
    local pb = made.pages.uf_player_buffs
    eq(G.PageLinkFor(pb, "auras_auradesigner"), "uf_player_auradesigner", "GUI.PageLinkFor asks the page")
    eq(G.PageLinkFor(made.pages.uf_target_buffs, "auras_auradesigner"), false, "...false: no counterpart")
    eq(G.PageLinkFor({}, "auras_auradesigner"), "auras_auradesigner", "a page with no map: the id itself")
    local ind = options_file_source("GUI/Pages/Indicators.lua")
    check(ind:find('local target = GUI.PageLinkFor and GUI.PageLinkFor(self, "auras_auradesigner")', 1, true) ~= nil,
          "Buff Bar: Open Aura Designer goes where the page says")
    check(ind:find('return GUI.PageLinkFor ~= nil and GUI.PageLinkFor(self, "auras_auradesigner") == false', 1, true) ~= nil,
          "Buff Bar: the Aura Designer promo hides on a page with no Aura Designer to open")
    check(not ind:find('GUI.SelectTab("auras_auradesigner")', 1, true), "...no hard-wired party Aura Designer link left")
end

print("-- Loaded: unit pages join the search index lazily")
do
    local n, lazy = 0, 0
    for name, p in pairs(made.pages) do
        -- The module's own pages (Settings, Linked Frames) are two: indexed as usual.
        if name ~= "uf_settings" and name ~= "uf_links" then
            n = n + 1
            if p.deferIndex == true then lazy = lazy + 1 end
            check(not p.skipSearchIndex, name .. ": indexed (once a search is typed), not skipped")
        end
    end
    check(n > 80, "the module adds " .. n .. " unit pages")
    eq(lazy, n, "every unit page defers joining the index (Search DEFERRED PAGES)")
    check(not made.pages.uf_settings.deferIndex, "the one module page is indexed as usual")
end

print("-- Loaded: a Unit Frames scope in Changed Settings")
do
    local scope = UFO.ChangedScope()
    eq(scope.label(), "Unit Frames", "scope: labelled Unit Frames")
    check(scope.owns("uf_target_health") and scope.owns("uf_settings") and not scope.owns("bars_health"),
          "scope: the module's pages, and only those")
    check(scope.dbFor("uf_target_health") == UF:GetUnitDB("target"), "scope: a unit page against its unit's table")
    check(scope.dbFor("uf_settings") == UF:GetGlobalDB(), "scope: the module page against the module table")
    local order = scope.pageOrder()
    eq(order[1], "uf_settings", "scope order: the module page first")
    eq(order[2], "uf_player_frame", "scope order: then all of Player's pages...")
    local firstTarget, lastPlayer
    for i, name in ipairs(order) do
        if name:find("^uf_player_") then lastPlayer = i end
        if not firstTarget and name:find("^uf_target_") then firstTarget = i end
    end
    check(lastPlayer and firstTarget and lastPlayer < firstTarget, "scope order: ...grouped by unit")
    eq(scope.rowKey({ tab = "uf_target_health", dbKey = "frameWidth" }), "target:frameWidth",
       "scope: one row per unit and key")
    local included = 0
    local heldSearch = DF.Search
    DF.Search = { IncludeDeferredPages = function() included = included + 1 end }
    scope.prepare()
    DF.Search = heldSearch
    eq(included, 1, "scope: asking for it brings the deferred unit pages into the index")
    check(scope.available(), "scope: offered while the companion is loaded")
    local src = options_file_source("UnitFrames/Pages.lua")
    check(src:find("CS:RegisterScope(UFO.MODULE, UFO.ChangedScope())", 1, true) ~= nil,
          "scope: registered when the companion is loaded")
end

print("-- Loaded: one build per page, bound to the unit's own table")
local pt = made.pages.uf_target_health
eq(G.PageBuildKey(pt), "uf:target", "build key: the unit")
eq(G.PageBuildKey(made.pages.uf_player_health), "uf:player", "...per unit")
local tdb = G.PageBuildDb(pt)
check(tdb == UF:GetUnitDB("target"), "build db: the unit's proxy")
tdb.frameWidth = 333
eq(DF.db.unitframes.units.target.frameWidth, 333, "a write lands in units.target")
eq(DF.db.unitframes.units.player.frameWidth, nil, "...and nowhere else")
tdb.frameWidth = nil
check(G.PageBuildDb(made.pages.uf_settings) == DF.db.unitframes.global, "the module page builds against units' global table")
eq(made.pages.uf_target_health.extraHealthColorModes.REACTION, "Reaction", "Health Bar offers the reaction modes")
eq(made.pages.uf_target_health.extraHealthColorModes.CLASS_REACTION, "Class / Reaction", "...both")

print("-- Loaded: the tabs move the sidebar and the page")
eq(def.activeTab(), "player", "starts on Player")
check(def.pageInView("uf_player_health") and not def.pageInView("uf_target_health"),
      "the sidebar lists the tab's own unit pages only")
check(def.pageInView("uf_settings"), "...and the module page on every tab")
eq(def.tabForPage("uf_focus_buffs"), "focus", "a page names its tab")
check(G:PageWantsOtherTab("uf_focus_buffs"), "asking for another unit's page moves the tab")
check(not G:PageWantsOtherTab("uf_player_buffs"), "...not for the tab's own")
check(G:ModulePageInView("general_frame"), "a page of no such module is unaffected")
calls = {}
G:SelectModule("units", "player")
eq(G.ModuleView, "units", "entered")
G.CurrentPageName = "uf_player_health"
calls = {}
G:SelectModule("units", "target")
eq(def.activeTab(), "target", "tab switch")
local j = table.concat(calls, ",")
check(j:find("layout", 1, true) and j:find("tab:uf_target_health", 1, true),
      "...re-lists the sidebar and lands on the same page for the new unit (" .. j .. ")")
G.CurrentPageName = "uf_target_resource"
calls = {}
G:SelectModule("units", "targettarget")
check(table.concat(calls, ","):find("tab:uf_targettarget_frame", 1, true),
      "a page the unit lacks lands on its Frame page")
G.CurrentPageName = "uf_settings"
calls = {}
G:SelectModule("units", "boss")
check(table.concat(calls, ","):find("tab:uf_settings", 1, true), "the module page stays put across tabs")
-- The page path (search results, links): SelectTab's switch for a page on another tab.
calls = {}
G:SelectModule("units", nil, { forPage = "uf_pet_icons" })
eq(def.activeTab(), "pet", "a search result on another unit moves the tab")
check(table.concat(calls, ","):find("layout", 1, true), "...and re-lists the sidebar")

print("-- Focus target (v1.1): a section on the Focus tab, not a seventh tab")
eq(#def.tabs, 6, "still six deck-2 tabs (seven do not fit the 580 px window)")
check(not UFO.IsTab("focustarget") and UFO.IsUnit("focustarget"), "a unit with pages, not a tab")
eq(UFO.TabOf("focustarget"), "focus", "its pages sit on the Focus tab")
eq(made.cats.uf_focustarget, "Focus Target", "...in a sidebar category of its own")
local lastCat = made.catOrder[#made.catOrder]
eq(lastCat, "uf_focustarget", "...after Focus's own categories")
eq(made.pages.uf_focustarget_health.cat, "uf_focustarget", "every focus target page is in it")
eq(made.pages.uf_focustarget_health.searchTabLabel, "Focus Target \194\183 Health Bar", "search names it")
eq(def.tabForPage("uf_focustarget_health"), "focus", "a focus target page names the Focus tab")
G:SelectModule("units", "focus")
check(def.pageInView("uf_focustarget_health") and def.pageInView("uf_focus_health"),
      "on Focus: the focus's pages and the focus target's")
G:SelectModule("units", "target")
check(not def.pageInView("uf_focustarget_health"), "on another tab: not listed")
calls = {}
G:SelectModule("units", nil, { forPage = "uf_focustarget_text" })
eq(def.activeTab(), "focus", "a search result for it moves to the Focus tab")
check(G.PageBuildDb(made.pages.uf_focustarget_health) == UF:GetUnitDB("focustarget"),
      "its pages build against the focus target's own table")
eq(G.PageBuildKey(made.pages.uf_focustarget_health), "uf:focustarget", "...one build per page, keyed on the unit")
G.CurrentPageName = "uf_focustarget_health"
eq(UFO.EditedUnit(), "focustarget", "editing on Focus's tab, the edited unit is the page's (the sync follows it)")
G.CurrentPageName = "uf_focus_health"
eq(UFO.EditedUnit(), "focus", "...and the focus's on its own pages")
G.CurrentPageName = nil

-- ============================================================
-- 4. A UNIT PAGE BUILT FROM A PARTY PAGE
-- ============================================================
print("-- A party page's builder, filtered for the unit")
do
    -- The party page and its builder, standing in for the real ones: one card per
    -- section key the Frame page has, one control per key, the copy row first.
    local Search = { }
    DF.Search = Search
    local asked, built = {}, {}
    local dfFrame = { tabName = "general_frame" }
    dfFrame.dfBuilder = function(self, db, Add)
        local row = Frame()
        row.dfCopyRow = { prefixes = { "frame", "permanentMover", "border", "anchor" }, sectionName = "Frame", pageId = "general_frame" }
        Add(row, 25, 2)
        for _, key in ipairs({ "frame_size", "frame_groupvisibility", "frame_border", "frame_bordershadow",
                               "frame_fade", "frame_permanentmover" }) do
            asked[key] = self.sectionFilter(key)
        end
        local band = Frame()
        band.groupChildren = {}
        for _, dbKey in ipairs({ "frameWidth", "frameSpacing", "frameFadeSplitCombat" }) do
            local w = Frame()
            local entry = { dbKey = dbKey }
            if Search.EntryFilter and Search.EntryFilter(entry) == false then entry.dfFilteredOut = true end
            w.searchEntry = entry
            band.groupChildren[#band.groupChildren + 1] = { widget = w }
            built[dbKey] = w
        end
        Add(band, 100, 1)
        local seeAlso = Frame()
        seeAlso.dfLinks = { { pageId = "bars_health", label = "Health Bar" }, { pageId = "general_pinnedframes", label = "Pinned" } }
        Add(seeAlso, 30, "both")
        self.modeSeen = G.SelectedMode
    end
    G.Pages.general_frame = dfFrame
    G.SelectedMode = "raid"

    -- Widget stubs the row needs.
    local dropdowns = {}
    function G:CreateDropdown(parent, label, options, db, key, cb, get, set, opts)
        local d = Frame()
        d.label, d.options, d.get, d.set, d.opts = label, options, get, set, opts
        d.SetDisplayOverride = function(self, t) self.caption = t end
        dropdowns[#dropdowns + 1] = d
        return d
    end
    function G:StyleButton() end
    -- The link banner over every unit page (hidden while nothing is linked).
    function G:CreateInfoBanner(_, opts) local b = Frame(); b.bannerOpts = opts; return b end
    function G:CreateLabelNative(_, opts) local l = Frame(); l.text = opts and opts.text; return l end
    function G:CreateSeeAlso(parent, links) local f = Frame(); f.links = links; return f end
    function G:CreateButtonRow(parent, buttons) local f = Frame(); f.buttons = buttons; return f end
    function G:CreatePopoutPageTools() return nil end

    local page = made.pages.uf_targettarget_frame
    page.children = {}
    local added = {}
    local function Add(w, h, col) page.children[#page.children + 1] = w; added[#added + 1] = { w = w, h = h, col = col }; return w end
    -- Position card needs the tools; skip it for this unit by not being spawned? ToT is spawned,
    -- so give the tools a tiny stand-in.
    function G:CreatePopoutPageTools()
        return {
            OpenSection = function(_, label, key) local b = Frame(); b.cardKey = key; b.AddWidget = function(self, w) self.last = w; return w end; Add(b, 36, 1); return b end,
            CloseSection = function() end,
        }
    end
    page.builder(page, UF:GetUnitDB("targettarget"), Add, noop, noop)

    eq(G.SelectedMode, "raid", "the frame mode under it is put back")
    eq(page.modeSeen, "party", "the party builder draws its PARTY variant")
    eq(asked.frame_size, true, "ToT: Frame Size shows")
    eq(asked.frame_border, true, "ToT: Border shows")
    eq(asked.frame_fade, true, "ToT: Frame Fade shows")
    eq(asked.frame_bordershadow, false, "ToT: no Border Shadow (not in its relevance)")
    eq(asked.frame_groupvisibility, false, "a group-only card is filtered off")
    eq(asked.frame_permanentmover, false, "Permanent Mover is filtered off (the mover owns position)")
    check(built.frameWidth.hideOn == nil, "a relevant control stays")
    check(built.frameSpacing.hideOn and built.frameSpacing.hideOn(), "Frame Spacing is hidden for every unit")
    check(built.frameFadeSplitCombat.hideOn and built.frameFadeSplitCombat.hideOn(), "a control not relevant to ToT is hidden")
    check(Search.EntryFilter == nil, "the search filter is lifted after the build")
    check(added[1].w.dfLinkBanner, "the page opens with the link banner...")
    eq(added[1].col, "both", "...across both columns")
    check(added[1].w.hideOn and added[1].w.hideOn(), "...hidden while nothing on the page is linked")
    check(added[2].w.dfUnitRow ~= nil, "the party copy row is swapped for the unit row")
    eq(added[2].col, 2, "...in the party row's column")
    eq(UFO.prefixes.frame[1], "frame", "...taking the party row's key prefixes")
    local see = added[4].w
    eq(see.links and #see.links, 1, "See Also keeps only links to pages this unit has")
    eq(see.links and see.links[1].pageId, "uf_targettarget_health", "...pointed at the unit's own page")
    eq(#added, 4, "no card of the module's own joins a party builder's page (its pins would be retired)")

    -- The row's one picker: keeping units in step is a link now, not a per-page sync.
    local copyDD = dropdowns[1]
    eq(#dropdowns, 1, "the row has Copy to... only (no Sync with...)")
    eq(copyDD.caption, "Copy to...", "Copy: a fixed caption")
    check(added[2].w.dfUnitRow.sync == nil, "...and no sync picker behind it")
    local order = table.concat(copyDD.options._order, ",")
    eq(order, "player,target,focus,focustarget,pet,boss", "Copy: every OTHER unit that has the page")

    -- The module Settings page, built for real over the same stubs.
    local checks, labels, rows = {}, {}, {}
    function G:CreateCheckbox(_, label, db, key, cb, get, set)
        local c = Frame(); c.label, c.db, c.key, c.get, c.set = label, db, key, get, set
        checks[#checks + 1] = c
        return c
    end
    function G:CreateLabel(_, text) local l = Frame(); l.text = text; labels[#labels + 1] = text; return l end
    function G:CreateButtonRow(_, buttons) local f = Frame(); f.buttons = buttons; rows[#rows + 1] = f; return f end
    dropdowns = {}
    added = {}
    local sp = made.pages.uf_settings
    sp.children = {}
    sp.builder(sp, UF:GetGlobalDB(), Add, noop, noop)
    local cards = {}
    for _, a in ipairs(added) do if a.w.cardKey then cards[#cards + 1] = a.w.cardKey end end
    eq(table.concat(cards, ","), "uf_module,uf_preview,uf_movers,uf_source,uf_blizzard",
       "Settings: Unit Frames, Preview, Position, Frame Source, Blizzard Frames (Linked Frames is a page of its own)")
    local sources = {}
    for _, d in ipairs(dropdowns) do if d.opts and d.opts.optionsFunc and d.options and d.options.DF then sources[#sources + 1] = d end end
    eq(#sources, #UF.SPAWNED_UNITS, "Settings: one source dropdown per frame this build draws")
    eq(dropdowns[1].label, "Player", "...labelled by unit")
    eq(dropdowns[1].get(), "DF", "...reading the unit's source")
    local moverRows = {}
    for _, r in ipairs(rows) do if r.buttons[1].label == "Edit in Mover" then moverRows[#moverRows + 1] = r end end
    eq(#moverRows, #UF.SPAWNED_UNITS, "Settings: an Edit in Mover / Reset Position row per frame")
    eq(rows[1].buttons[1].label, "Edit in Mover", "...Edit in Mover first")
    eq(rows[1].buttons[2].label, "Reset Position", "...then Reset Position")
    local castbar
    for _, c in ipairs(checks) do if c.key == "hideBlizzardCastbar" then castbar = c end end
    check(castbar and castbar.db == DF.db.unitframes.global, "Settings: Hide Blizzard Player Cast Bar is module-wide")
    -- Edit in Mover without the mover: DF's "DandersMover is disabled" line.
    says = {}
    rows[1].buttons[1].onClick()
    eq(says[1], "DandersMover is disabled", "Edit in Mover without DandersMover says so")
    local unlocked
    UF.Mover = { ADDON_KEY = "DandersFrames_UnitFrames", registered = { player = true },
                 lib = { Unlock = function(_, f) unlocked = f end } }
    rows[1].buttons[1].onClick()
    eq(unlocked and unlocked.addon, "DandersFrames_UnitFrames", "Edit in Mover: the mover, filtered to the addon")
    eq(unlocked and unlocked.keys and unlocked.keys[1], "player", "...and to that unit")
    UF.Mover = nil

    -- The Settings page's Preview card: the switch and the test-mode option.
    local prevSwitch, inTest
    for _, c in ipairs(checks) do
        if c.label == "Preview" then prevSwitch = c end
        if c.label == "Include Unit Frames in Test Mode" then inTest = c end
    end
    check(prevSwitch and prevSwitch.get and prevSwitch.set, "Settings: a Preview switch (get/set, not a db key)")
    check(inTest and inTest.get, "Settings: Include Unit Frames in Test Mode")
    if inTest then
        eq(inTest.get(), true, "...on by default")
        inTest.set(false)
        eq(DF.db.unitframes.global.includeInTestMode, false, "...saved module-wide")
        inTest.set(true)
    end

    -- The Visibility page, built for real.
    for _, unit in ipairs({ "player", "target" }) do
        checks, added = {}, {}
        local vp = made.pages["uf_" .. unit .. "_visibility"]
        vp.children = {}
        vp.RefreshStates = function() end
        vp.builder(vp, UF:GetUnitDB(unit), Add, noop, noop)
        local cardKeys, keys = {}, {}
        for _, x in ipairs(added) do if x.w.cardKey then cardKeys[#cardKeys + 1] = x.w.cardKey end end
        for _, c in ipairs(checks) do keys[#keys + 1] = c.key end
        eq(table.concat(cardKeys, ","), "uf_vis_show,uf_vis_hide", unit .. " Visibility: Show When, Hide When")
        check(added[2].w.dfUnitRow ~= nil and added[1].w.dfLinkBanner, unit .. " Visibility: the link banner, then the unit row (Reset / Copy)")
        local want = (unit == "player")
            and "visAlways,visCombat,visNoCombat,visGroup,visSolo,visInstance,visHasTarget,visHasEnemyTarget,visHidePetBattle,visHideVehicle,visHideMounted,visHideSkyriding"
            or "visAlways,visCombat,visNoCombat,visGroup,visSolo,visInstance,visHidePetBattle,visHideMounted,visHideSkyriding"
        eq(table.concat(keys, ","), want, unit .. " Visibility: its controls")
        local combat = checks[2]
        check(combat and combat.disableOn, unit .. ": conditions grey while Always is on")
        if combat and combat.disableOn then
            eq(combat.disableOn(UF:GetUnitDB(unit)), true, "...Always on: greyed")
            eq(combat.disableOn({ visAlways = false }), false, "...Always off: live")
        end
    end
    eq(UFO.Prefixes("visibility")[1], "vis", "Visibility: Reset / Copy act on the vis keys")

    -- ---- the pages new in Stage F, built for real -------------------------------
    -- Every factory records the key it binds; the tools record each card and its
    -- header tick.
    local built, toggles
    -- args after the parent: (label, db, key, ...) for most; (label, min, max,
    -- step, db, key) for sliders; (label, options, db, key) for dropdowns.
    local function Collect(kind, keyIndex)
        return function(_, parent, ...)
            local w = Frame()
            w.kind = kind
            w.args = { ... }
            w.label = w.args[1]
            w.key = w.args[keyIndex]
            built[#built + 1] = w
            return w
        end
    end
    G.CreateCheckbox = Collect("check", 3)
    G.CreateSlider = Collect("slider", 6)
    G.CreateDropdown = Collect("dropdown", 4)
    G.CreateColorPicker = Collect("color", 3)
    G.CreateTextureDropdown = Collect("texture", 3)
    G.CreateFontDropdown = Collect("font", 3)
    G.CreateOutlineDropdown = Collect("outline", 3)
    G.CreateButtonRow = Collect("buttons", 99)
    G.CreateLabel = Collect("label", 99)
    function G:CreatePopoutPageTools()
        return {
            OpenSection = function(_, label, key, col, summary, dimFn, hideFn, builder, toggle)
                local b = Frame(); b.cardKey = key; b.summary = summary
                b.groupChildren = {}
                b.AddWidget = function(self, w) self.last = w; self.groupChildren[#self.groupChildren + 1] = { widget = w }; return w end
                if toggle then toggles[key] = toggle end
                Add(b, 36, col)
                return b
            end,
            CloseSection = function() end,
        }
    end
    local function BuildPage(unit, kind)
        built, toggles, added = {}, {}, {}
        local pg = made.pages["uf_" .. unit .. "_" .. kind]
        pg.children = {}
        page.children = pg.children     -- Add appends to `page.children`: make it this page's
        pg.RefreshStates = function() end
        pg.builder(pg, UF:GetUnitDB(unit), Add, noop, noop)
        local cardKeys, keys = {}, {}
        for _, x in ipairs(added) do if x.w.cardKey then cardKeys[#cardKeys + 1] = x.w.cardKey end end
        local byKey = {}
        for _, w in ipairs(built) do
            if type(w.key) == "string" then keys[#keys + 1] = w.key; byKey[w.key] = w end
        end
        return table.concat(cardKeys, ","), keys, byKey, added
    end
    local function has(list, k) for _, x in ipairs(list) do if x == k then return true end end return false end

    print("-- Stage F pages: Cast Bar")
    local cards, keys, byKey, pAdded = BuildPage("player", "castbar")
    eq(cards, "uf_cb_settings,uf_cb_size,uf_cb_position,uf_cb_style,uf_cb_colors,uf_cb_icon,uf_cb_border,uf_cb_spell,uf_cb_timer",
       "Cast Bar: Settings, Size, Position, Bar Style, Colors, Icon, Border, Spell Name, Timer")
    check(pAdded[2].w.dfUnitRow ~= nil and pAdded[1].w.dfLinkBanner, "Cast Bar: the link banner, then the unit row (Reset / Copy)")
    eq(toggles.uf_cb_settings and toggles.uf_cb_settings.key, "castbarEnabled", "Cast Bar: Enable is the Settings card's header tick")
    eq(toggles.uf_cb_icon and toggles.uf_cb_icon.key, "castbarShowIcon", "...Show Icon on the Icon card")
    eq(toggles.uf_cb_border and toggles.uf_cb_border.key, "castbarBorderEnabled", "...the cast bar's OWN border key")
    eq(toggles.uf_cb_spell and toggles.uf_cb_spell.key, "castbarShowSpell", "...Show Spell Name")
    eq(toggles.uf_cb_timer and toggles.uf_cb_timer.key, "castbarShowTimer", "...Show Timer")
    check(not has(keys, "castbarEnabled"), "...and the body never repeats a header tick")
    check(has(keys, "castbarLatency") and has(keys, "castbarEmpower"), "player: Latency and Empower Stages")
    check(not has(keys, "castbarKickTick"), "player: no kick-ready mark (an enemy-frame setting)")
    check(has(keys, "castbarDetached"), "Cast Bar: the Detach tick")
    check(not has(keys, "frameBorderSize"), "Cast Bar: never the frame's own border keys")
    local w = byKey.castbarLatency
    check(w and w.disableOn and w.disableOn({ castbarEnabled = false }) and not w.disableOn({ castbarEnabled = true }),
          "Cast Bar: controls grey while the cast bar is off")
    w = byKey.castbarSide
    check(w and w.hideOn and w.hideOn({ castbarDetached = true }) and not w.hideOn({ castbarDetached = false }),
          "Cast Bar: the attached-only controls hide while detached")
    cards, keys = BuildPage("target", "castbar")
    check(has(keys, "castbarKickTick") and has(keys, "castbarImportantGlow"), "target: kick-ready mark, important glow")
    check(not has(keys, "castbarLatency") and not has(keys, "castbarEmpower"), "target: no latency / empower (player only)")
    check(has(keys, "castbarKickNotReadyColor"), "target: the Kick Not Ready colour")
    check(has(keys, "castbarShowTarget"), "target: Show Spell Target")
    cards, keys = BuildPage("pet", "castbar")
    check(not has(keys, "castbarShowTarget"), "pet: no Spell Target (the card does not reach it)")
    eq(table.concat(UFO.Prefixes("castbar"), ","), "castbar", "Cast Bar: Reset / Copy act on the castbar keys")
    cards, keys = BuildPage("boss", "castbar")
    check(not has(keys, "castbarDetached"), "boss: no Detach (five bars, one record)")
    check(has(keys, "castbarKickTick") and has(keys, "castbarShowTarget"), "boss: kick-ready mark and Spell Target stay")

    print("-- Stage G pages: Boss Layout")
    cards, keys, byKey, pAdded = BuildPage("boss", "bosslayout")
    eq(cards, "uf_boss_arrangement,uf_boss_behaviour", "Boss Layout: Arrangement, Behaviour")
    check(pAdded[2].w.dfUnitRow ~= nil and pAdded[1].w.dfLinkBanner, "Boss Layout: the link banner, then the unit row (Reset / Copy)")
    eq(table.concat(keys, ","), "bossGrowth,bossSpacing,bossUnitsPerRow,bossRowSpacing,bossPreviewCount,bossPreviewNum",
       "Boss Layout: growth, spacing, per row, row spacing, test-mode placeholders, preview count")
    check(not has(keys, "bossRangeFade") and not has(keys, "bossRangeAlpha"),
          "...no range controls (hidden for Boss; the Fading page fades a boss)")
    w = byKey.bossGrowth
    eq(w and w.args[2] and table.concat(w.args[2]._order, ","), "DOWN,UP,LEFT,RIGHT", "Growth Direction: down, up, left, right")
    w = byKey.bossUnitsPerRow
    eq(w and w.args[3], UF.BOSS_COUNT or 5, "Units Per Row stops at the slot count")
    eq(byKey.bossPreviewNum and byKey.bossPreviewNum.args[3], UF.BOSS_COUNT or 5, "Preview Frames stops at the slot count")
    w = byKey.bossRowSpacing
    check(w and w.disableOn and w.disableOn({ bossUnitsPerRow = 5 }) and not w.disableOn({ bossUnitsPerRow = 2 }),
          "Row Spacing greys until a row wraps")
    local editRow
    for _, x in ipairs(built) do if x.kind == "buttons" then editRow = x end end
    check(editRow and editRow.args[1][1].label == "Edit in Mover", "Arrangement: Edit in Mover")
    eq(table.concat(UFO.Prefixes("bosslayout"), ","), "boss", "Boss Layout: Reset / Copy act on the boss keys")

    print("-- Greyed controls say why")
    cards, keys, byKey = BuildPage("player", "castbar")
    local function why(k, d) local w = byKey[k]; return w and type(w.disableReason) == "function" and w.disableReason(d) or nil end
    eq(why("castbarLatency", { castbarEnabled = false }), "Turn on Cast Bar to change this", "Cast Bar off: says to turn it on")
    eq(why("castbarLatency", { castbarEnabled = true }), nil, "...live: no reason")
    eq(why("castbarSpellFont", { castbarEnabled = true, castbarShowSpell = false }), "Turn on Show Spell Name to change this",
       "a nested gate names its own switch...")
    eq(why("castbarSpellFont", { castbarEnabled = false, castbarShowSpell = false }), "Turn on Cast Bar to change this",
       "...unless the feature itself is off, which comes first")
    eq(why("castbarIconSize", { castbarEnabled = true, castbarShowIcon = false }), "Turn on Show Icon to change this", "Icon card")
    eq(why("castbarBorderSize", { castbarEnabled = true, castbarBorderEnabled = false }), "Turn on Show Border to change this",
       "the border card's gate")
    local gated, explained = 0, 0
    for _, w in ipairs(built) do
        if w.disableOn then
            gated = gated + 1
            if w.disableReason then explained = explained + 1 end
        end
    end
    check(gated > 20, "Cast Bar: many gated controls (" .. gated .. ")")
    eq(explained, gated, "Cast Bar: every gated control has a reason")
    cards, keys, byKey = BuildPage("boss", "bosslayout")
    eq(why("bossRowSpacing", { bossUnitsPerRow = 5 }), "Only used when the frames wrap into more than one row",
       "Boss Row Spacing explains why it is grey")
    eq(why("bossRowSpacing", { bossUnitsPerRow = 2 }), nil, "...and says nothing while live")
    cards, keys, byKey = BuildPage("player", "portrait")
    eq(why("portraitSize", { portraitEnabled = false }), "Turn on Portrait to change this", "Portrait")
    cards, keys, byKey = BuildPage("target", "unitIcons")
    eq(why("classificationSize", { classificationEnabled = false }), "Turn on Elite / Rare to change this", "Unit Icons: per card")
    cards, keys, byKey = BuildPage("player", "visibility")
    eq(why("visCombat", { visAlways = true }), "Turn off Always to change this", "Visibility: Always has to go OFF")
    local d = { visAlways = true }
    eq(byKey.visCombat and byKey.visCombat.disableOn(d), true, "(the gate itself is unchanged)")

    print("-- Stage F pages: Class Power")
    cards, keys, byKey = BuildPage("player", "classpower")
    eq(cards, "uf_cp_settings,uf_cp_class,uf_cp_size,uf_cp_position,uf_cp_style,uf_cp_colors,uf_cp_border",
       "Class Power: Settings, Class Options, Size, Position, Bar Style, Colors, Border")
    eq(toggles.uf_cp_settings and toggles.uf_cp_settings.key, "classPowerEnabled", "Class Power: Enable is the header tick")
    check(has(keys, "classPowerRunes") and has(keys, "classPowerStagger") and has(keys, "classPowerDetached"),
          "Class Power: runes, stagger, Detach")
    w = byKey.classPowerColor
    check(w and w.hideOn and w.hideOn({ classPowerColorMode = "CLASS" }) and not w.hideOn({ classPowerColorMode = "CUSTOM" }),
          "Class Power: Custom Color shows only in Custom mode")

    print("-- Stage F pages: Portrait")
    cards, keys, byKey = BuildPage("player", "portrait")
    eq(cards, "uf_po_settings,uf_po_position,uf_po_look,uf_po_border", "Portrait: Settings, Size & Position, Look, Border")
    eq(toggles.uf_po_settings and toggles.uf_po_settings.key, "portraitEnabled", "Portrait: Show Portrait is the header tick")
    check(has(keys, "portraitMirror"), "player: Mirror")
    cards, keys = BuildPage("target", "portrait")
    check(not has(keys, "portraitMirror"), "target: no Mirror (player / pet only)")
    cards, keys = BuildPage("pet", "portrait")
    check(not has(keys, "portraitNpcMode") and not has(keys, "portraitDesatDead"), "pet: no NPC style, no desaturate")

    print("-- Stage F pages: Unit Icons")
    cards = BuildPage("player", "unitIcons")
    eq(cards, "uf_icon_resting,uf_icon_pvp", "player Unit Icons: Resting, PvP")
    eq(toggles.uf_icon_resting and toggles.uf_icon_resting.key, "restingIconEnabled", "...each icon's tick in its header")
    cards, keys = BuildPage("target", "unitIcons")
    eq(cards, "uf_icon_pvp,uf_icon_classification", "target Unit Icons: PvP, Elite / Rare")
    check(has(keys, "classificationStyle"), "...Elite / Rare: icon or text")
    eq(table.concat(UFO.Prefixes("unitIcons"), ","), "restingIcon,pvpIcon,classification",
       "Unit Icons: Reset / Copy act on the three icons' keys")

    print("-- Stage F: Hide Blizzard Player Cast Bar follows ours until set")
    built = {}
    added = {}
    local sp2 = made.pages.uf_settings
    sp2.children = {}
    sp2.builder(sp2, UF:GetGlobalDB(), Add, noop, noop)
    local hb
    for _, x in ipairs(built) do if x.key == "hideBlizzardCastbar" then hb = x end end
    local getter = hb and hb.args[5]
    local setter = hb and hb.args[6]
    check(getter and setter, "Settings: the tick reads and writes through its own get / set")
    if getter and setter then
        UF.BlizzardHide = nil
        DF.db.unitframes.global.hideBlizzardCastbar = nil
        eq(getter(), false, "...without the runtime: unset reads off")
        UF.BlizzardHide = { ShouldHideCastBar = function() return true end }
        eq(getter(), true, "...with it: unset follows our player cast bar (on by default)")
        setter(false)
        eq(DF.db.unitframes.global.hideBlizzardCastbar, false, "...a click stores the user's own choice")
        DF.db.unitframes.global.hideBlizzardCastbar = nil
        UF.BlizzardHide = nil
    end
    UF:GetStoredUnit("player").position = { point = "TOP", x = 1, y = 2 }
    rows[1].buttons[2].onClick()
    eq(UF:GetStoredUnit("player").position, nil, "Reset Position: back to the unit's default")

    G.Pages.general_frame = nil
    DF.Search = nil
end

-- ============================================================
-- 5. COPY / SYNC / RESET BETWEEN UNITS
-- ============================================================
print("-- Copy, sync and reset between units")
do
    local tgt, ply, foc = UF:GetStoredUnit("target"), UF:GetStoredUnit("player"), UF:GetStoredUnit("focus")
    tgt.healthColorMode = "CUSTOM"
    tgt.healthTexture = "Flat"
    tgt.frameWidth = 300                -- another page's key: never copied by Health Bar
    UFO.prefixes.health = nil
    local n = UFO.CopyPage("health", "target", "player")
    eq(ply.healthColorMode, "CUSTOM", "copy: the source's value")
    eq(ply.healthTexture, "Flat", "copy: ...every key the page owns")
    eq(ply.frameWidth, nil, "copy: another page's key is left alone")
    check(type(n) == "number" and n >= 2, "copy: counts what it moved")
    -- A value equal to the destination's own default is dropped, not stored.
    tgt.healthColorMode = nil            -- target's default: CLASS_REACTION
    UFO.CopyPage("health", "target", "focus")
    eq(foc.healthColorMode, nil, "copy: target's default equals focus's default -> nothing stored")
    UFO.CopyPage("health", "target", "player")
    eq(ply.healthColorMode, "CLASS_REACTION", "copy: the source's DEFAULT still moves when it differs")
    -- a table value is copied, not shared
    tgt.healthColor = { r = 1, g = 0, b = 0, a = 1 }
    UFO.CopyPage("health", "target", "player")
    check(ply.healthColor ~= tgt.healthColor and ply.healthColor.r == 1, "copy: tables are copied, not shared")
    tgt.source = "Hidden"
    UFO.prefixes.frame = { "frame", "source", "position" }
    UFO.CopyPage("frame", "target", "player")
    eq(ply.source, nil, "copy: who draws a frame never moves")
    tgt.source = nil
    UFO.prefixes.frame = nil

    -- Links replace the per-page sync: a write on a linked unit reaches its partner
    -- after the drain, from the unit being edited (Links.lua does the copying;
    -- test_uf_links.lua covers the engine, this is the settings side).
    check(UFO.SyncPage == nil and UFO.SyncPartner == nil and UFO.ApplySyncs == nil,
          "the per-page sync API is gone")
    local Lk, root = UF.Links, DF.db.unitframes
    root.global.unitLinks = {}
    Lk:SetLink(root, "focus", "target", { health = { layout = "same", look = "same" } })
    eq(UFO.Partner("focus"), "target", "link: the follower's partner")
    eq(UFO.Partner("target"), "focus", "link: ...and the leader's")
    eq(foc.healthTexture, "Flat", "link: the leader's settings are copied once on linking")
    tgt.healthTexture = "Smooth"
    G.ModuleView, UFO.unit = "units", "target"
    for _, fn in ipairs(postDrains) do fn() end
    eq(foc.healthTexture, "Smooth", "link: a write on the linked unit follows after the drain")
    UFO.unit = "player"
    tgt.healthTexture = "Glass"
    for _, fn in ipairs(postDrains) do fn() end
    eq(foc.healthTexture, "Smooth", "link: ...from the unit being edited only")
    UFO.unit = "target"

    -- What the page says about it.
    check(UFO.PageLinked("health", "target"), "the Health Bar page is linked on Target")
    check(not UFO.PageLinked("frame", "target"), "...the Frame page is not")
    local text = UFO.LinkBannerText("health", "target")
    check(text and text:find("Focus", 1, true) and text:find("position, size and style shared", 1, true),
          "banner: names the partner and how the page is linked")
    eq(UFO.LinkBannerText("frame", "target"), nil, "banner: nothing on a page that is not linked")
    eq(UFO.PageMark("uf_target_health"), UFO.ROW_MARK, "sidebar: a linked page's row carries the link mark")
    eq(UFO.PageMark("uf_target_frame"), nil, "sidebar: ...an unlinked one does not")
    eq(UFO.PageMark("uf_settings"), nil, "sidebar: the module page never does")
    eq(UFO.TabMark("target"), UFO.TAB_MARK, "deck tab: a linked unit's tab carries it")
    eq(UFO.TabMark("player"), nil, "deck tab: ...an unlinked unit's does not")
    check(UFO.TAB_MARK.grow == true and UFO.ROW_MARK.grow == false, "the tab may widen for it, a row never")
    local msg = UFO.ResetMessage("health", "target", "Health Bar")
    check(msg:find("Focus", 1, true) and msg:find("linked settings", 1, true),
          "reset on a linked page: the confirmation says the partner resets too")
    check(not UFO.ResetMessage("frame", "target", "Frame"):find("linked", 1, true),
          "reset on an unlinked page: the plain confirmation")

    -- Reset: back to the unit's own defaults for that page only -- and, linked,
    -- the partner's shared settings with it.
    tgt.healthTexture = "Glass"
    for _, fn in ipairs(postDrains) do fn() end
    eq(foc.healthTexture, "Glass", "(linked and in step)")
    tgt.frameWidth = 300
    UFO.ResetPage("health", "target")
    eq(tgt.healthTexture, nil, "reset: the page's keys go")
    eq(tgt.healthColor, nil, "reset: ...all of them")
    eq(tgt.frameWidth, 300, "reset: another page's keys stay")
    eq(foc.healthTexture, nil, "reset: the linked partner's shared settings reset too")
    -- Copy to a linked unit: its partner follows.
    ply.healthTexture = "Copied"
    UFO.CopyPage("health", "player", "target")
    eq(foc.healthTexture, "Copied", "copy into a linked unit: its partner follows")
    Lk:Unlink(root, "focus")
    eq(UFO.Partner("target"), nil, "unlink: both sides free")
    eq(UFO.TabMark("target"), nil, "...and the mark goes")
    ply.healthTexture, tgt.healthTexture, foc.healthTexture = nil, nil, nil
    tgt.frameWidth = nil
    G.ModuleView = nil
end

-- ============================================================
-- 6. MODULE SETTINGS: FRAME SOURCE, THE ToT RULE, Q9
-- ============================================================
print("-- Frame source and the target of target rule")
do
    local function has(opts, k) for _, v in ipairs(opts._order) do if v == k then return true end end return false end
    eq(UFO.GetSource("target"), "DF", "source: DandersFrames by default")
    check(has(UFO.SourceOptions("target"), "Blizzard"), "target may be Blizzard's")
    check(not has(UFO.SourceOptions("targettarget"), "Blizzard"), "ToT may not be Blizzard's while target is ours")
    popups = {}
    eq(UFO.SetSource("targettarget", "Blizzard"), false, "...and setting it is refused")
    eq(#popups, 0, "...without a reload prompt")
    eq(UFO.SetSource("target", "Blizzard"), true, "target -> Blizzard")
    eq(#popups, 1, "...asks to reload")
    check(has(UFO.SourceOptions("targettarget"), "Blizzard"), "now ToT may be Blizzard's")
    eq(UFO.SetSource("targettarget", "Blizzard"), true, "ToT -> Blizzard")
    UFO.SetSource("target", "DF")
    eq(UFO.GetSource("targettarget"), "DF", "target back to ours takes a Blizzard ToT with it")
    eq(UFO.SetSource("player", "Nonsense"), false, "an unknown source is refused")
    -- The focus target follows the same rule against the focus.
    check(not has(UFO.SourceOptions("focustarget"), "Blizzard"), "focus target may not be Blizzard's while focus is ours")
    eq(UFO.SetSource("focustarget", "Blizzard"), false, "...and setting it is refused")
    eq(UFO.SetSource("focus", "Blizzard"), true, "focus -> Blizzard")
    eq(UFO.SetSource("focustarget", "Blizzard"), true, "now the focus target may be Blizzard's")
    eq(UFO.GetSource("targettarget"), "DF", "...the target of target is untouched")
    UFO.SetSource("focus", "DF")
    eq(UFO.GetSource("focustarget"), "DF", "focus back to ours takes a Blizzard focus target with it")
    check(options_file_source("UnitFrames/Pages.lua"):find('L["Focus Target can only be Blizzard when Focus is."]', 1, true),
          "the Frame Source card says so")

    print("-- Q9: DF's Hide Blizzard Player Frame stands aside")
    check(type(G.PlayerFrameOwnerNote()) == "string", "player drawn by Unit Frames: the note shows")
    UFO.SetSource("player", "Blizzard")
    eq(G.PlayerFrameOwnerNote(), nil, "player back to Blizzard: DF's own ticks come back")
    UFO.SetSource("player", "DF")
    local opt = options_file_source("GUI/Pages/Options.lua")
    check(opt:find("disablePlayerCheck.hideOn = function() return PlayerOwnerNote() ~= nil end", 1, true),
          "Global > Blizzard Frames: Hide Blizzard Player Frame hides under the note")
    check(opt:find("playerRaidOnlyCheck.hideOn = function() return PlayerOwnerNote() ~= nil end", 1, true),
          "...and its raid-only sub-option")
    check(opt:find("ownerNote.hideOn = function() return PlayerOwnerNote() == nil end", 1, true),
          "...and the one line shows in their place")
end

-- ============================================================
-- 7. THE REAL CARD FILTER (GUI:CreatePopoutPageTools, cut out of Controls.lua)
-- ============================================================
print("-- The card filter in the shared page tools")
do
    local src = options_file_source("GUI/Controls.lua"):gsub("\r\n", "\n")
    local a = src:find("function GUI:CreatePopoutPageTools(page)", 1, true)
    local b = a and src:find("\nend\n", a, true)
    check(a and b, "the page tools can be cut out of Controls.lua")
    if a and b then
        local fn, err = loadstring("local GUI, DF, L, WireTwoTrack, StampFullRows, QuietLabels = ...\n"
            .. src:sub(a, b + 4), "@Controls.lua:CreatePopoutPageTools")
        check(fn ~= nil, "...and compiles (" .. tostring(err) .. ")")
        if fn then
            local T = {
                PopoutContentWidth = 260, SettingsBox = { group = 280 }, SectionKindByKey = {},
                contentFrame = Frame(), _trashFrame = Frame(),
            }
            function T.PageUsableWidth(w) return w end
            function T.PageChildWidth(w) return w end
            function T.UsesTwoColumns() return false end
            function T.ColumnWidth() return 280 end
            function T.PageBuildDb() return nil end
            function T:CreateSettingsGroup() local g = Frame(); g.AddWidget = function(_, w) return w end; return g end
            function T:CreateCollapsibleSection(_, label, _, _, opts)
                local s = Frame(); s.label = label; s.opts = opts
                s.RegisterChild = function(self, c) self.child = c end
                return s
            end
            function T:CreateHeader(_, label) local h = Frame(); h.label = label; return h end
            local DFx = { Search = { SuppressRegistration = false } }
            fn(T, DFx, DF.L, noop, noop, noop)
            local page = { child = Frame(), tabLabel = "Frame" }
            page.sectionFilter = function(key) return key ~= "off_card" end
            local tools = T:CreatePopoutPageTools(page)
            local addedW = {}
            local function Add(w) addedW[#addedW + 1] = w; return w end
            local keep = tools.OpenSection(Add, "Kept", "on_card", 1, nil, nil, nil, function() end)
            eq(DFx.Search.SuppressRegistration, false, "a kept card registers its controls")
            tools.CloseSection(Add, keep)
            local band = tools.OpenSection(Add, "Gone", "off_card", 1, nil, nil, function() return false end, function() end)
            eq(DFx.Search.SuppressRegistration, true, "a filtered card registers nothing with search...")
            local section = addedW[#addedW]
            check(section.hideOn and section.hideOn(), "...its header never shows")
            check(band.hideOn and band.hideOn(), "...nor its band")
            check(section.opts and section.opts.pin == nil, "...and it has no pin")
            tools.CloseSection(Add, band)
            eq(DFx.Search.SuppressRegistration, false, "...until its CloseSection puts search back")
            check(addedW[1].hideOn == nil, "the kept card's header is left alone")

            -- A card group whose every card is filtered loses its header too.
            tools.DeferCard("off_card", function() end)
            tools.DeferCard("on_card", function() end)
            addedW = {}
            tools.MountCardGroups(Add, {
                { label = "Empty", col = 1, keys = { "off_card" } },
                { label = "Full",  col = 1, keys = { "on_card" } },
            })
            check(addedW[1].hideOn and addedW[1].hideOn(), "an all-filtered group's header hides")
            check(addedW[2].hideOn == nil, "a group with a kept card keeps its header")
        end
    end
end

-- ============================================================
-- 7b. THE LINKED FRAMES PAGE (uf_links), built for real over stub widgets
-- ============================================================
print("-- The Linked Frames page")
do
    local Lk, root = UF.Links, DF.db.unitframes
    root.global.unitLinks = nil
    Lk:Ensure(root)                         -- the default link: Target follows Player

    -- Registered under the module category, right below Settings.
    local pg = made.pages.uf_links
    check(pg ~= nil, "the page exists")
    eq(pg and pg.cat, "uf_module", "...in the Unit Frames category")
    eq(made.pageOrder[1] .. "," .. made.pageOrder[2], "uf_settings,uf_links", "...right below Settings")
    eq(pg and pg.tabLabel, "Linked Frames", "...called Linked Frames")
    eq(G:ModuleForPage("uf_links"), "units", "...on the module's sidebar")
    eq(UFO.PageMark("uf_links"), UFO.ROW_MARK, "...with the link mark while a link exists")
    check(type(G.PageMinWidths.uf_links) == "function", "...and a measured minimum window width")
    calls = {}
    UFO.OpenLinkCard("target")
    eq(calls[#calls], "tab:uf_links", "a unit page's Edit link opens this page")

    -- ---- the words ---------------------------------------------------------------
    local E = Lk.BY_ID
    eq(UFO.LinkResult(E.health, "mirror", "same", "target", "player"), "Target is a mirror image of Player.", "result: mirror + same")
    eq(UFO.LinkResult(E.health, "mirror", "own", "target", "player"), "Positions mirror. Target keeps its own size and style.", "result: mirror + own")
    eq(UFO.LinkResult(E.health, "same", "same", "target", "player"), "Identical on both frames.", "result: same + same")
    eq(UFO.LinkResult(E.health, "same", "own", "target", "player"), "Same positions. Target keeps its own size and style.", "result: same + own")
    eq(UFO.LinkResult(E.health, "own", "same", "target", "player"), "Same size and style. Each frame places it on its own.", "result: own + same")
    eq(UFO.LinkResult(E.health, "own", "own", "target", "player"), "Not linked. Each frame has its own.", "result: own + own")
    eq(UFO.LinkResult(E.border, "own", "same", "target", "player"), "Same on both frames.", "result: no position, shared")
    eq(UFO.LinkResult(E.border, "own", "own", "target", "player"), "Not linked. Each frame has its own.", "result: no position, separate")
    eq(UFO.LinkResult(E.health, "mirror", "same", "focus", "target"), "Focus is a mirror image of Target.", "result: names the pair")
    local link = root.global.unitLinks.target
    check(UFO.LinkExceptText(link, "health"):find("reaction", 1, true), "always separate: health colour mode")
    check(UFO.LinkExceptText(link, "castbar"):find("latency", 1, true), "always separate: cast bar detach and latency")
    eq(UFO.LinkExceptText(link, "portrait"), nil, "...nothing for a part with no kept key")
    eq(UFO.LinkExceptText({ elements = {} }, "health"), nil, "...nothing for a link that keeps nothing apart")
    for _, e in ipairs(Lk.ELEMENTS) do
        local pos, size = UFO.LinkPartText(e.id)
        check(size ~= nil, e.id .. ": says what its size & style covers")
        check((pos ~= nil) == (e.layout and true or false), e.id .. ": a position text exactly when it has a position")
    end

    -- ---- the groups --------------------------------------------------------------
    local linked, separate = UFO.LinkPageGroups("target", "player")
    local function ids(list) local t = {} for i, e in ipairs(list) do t[i] = e.id end return table.concat(t, ",") end
    eq(ids(linked), "health,resource,portrait,castbar,text,buffs,debuffs,border", "Linked by default: the default link's parts, in page order")
    eq(ids(separate), "absorbs,healpred,icons,unitIcons,tooltips,visibility,fading,frame,highlights",
       "Separate by default: everything else both frames have")
    local n, total = UFO.LinkedPartCount("target", "player")
    eq(n .. "/" .. total, "8/17", "8 of 17 parts linked")
    linked, separate = UFO.LinkPageGroups("targettarget", "focustarget")
    eq(ids(linked) .. "|" .. ids(separate), "health,text,border|tooltips,frame,highlights", "a pair with fewer parts lists only those")

    -- ---- the layout decision -----------------------------------------------------
    local m = UFO.LinkDefaultMeasures()
    local wideNeed, stackedNeed = UFO.LinkCardNeeds(m)
    check(stackedNeed < wideNeed, "stacked needs less width than wide")
    eq(UFO.LinkCardLayout(wideNeed, m).mode, "wide", "wide at exactly what it needs")
    eq(UFO.LinkCardLayout(wideNeed - 1, m).mode, "stacked", "...stacked a pixel under it")
    local w = UFO.LinkCardLayout(wideNeed, m)
    check(w.pos > w.name + m.nameW - 1 and w.look >= w.pos + m.posW and w.result >= w.look + m.lookW,
          "wide: columns in order, never overlapping")
    eq(w.resultW, m.resultMin, "wide at its minimum: the result column gets exactly its minimum")
    local s = UFO.LinkCardLayout(stackedNeed, m)
    check(s.look + m.lookW <= stackedNeed - m.pad, "stacked at its minimum: the second segment ends inside the card")
    check(s.resultW >= m.resultMinStacked, "stacked at its minimum: the result keeps its minimum beside the name")
    eq(UFO.LinkHeaderLines(5000, m), 1, "header: one line when everything fits")
    eq(UFO.LinkHeaderLines(2 * m.pad + m.pickersW + m.gap + m.summaryW, m), 2, "...buttons below when they do not")
    eq(UFO.LinkHeaderLines(stackedNeed, m) >= 2, true, "...never one line at the stacked minimum")
    check(stackedNeed >= 2 * m.pad + m.buttonsW and stackedNeed >= 2 * m.pad + m.pickersW,
          "the stacked minimum holds the buttons and the pickers on their own lines")
    eq(UFO.LinksMinWindowWidth(m, 281), 281 + UFO.LinksMinUsableWidth(m), "min window = chrome + the narrow layout's need")
    check(UFO.LinksMinWindowWidth(m, 281) < 281 + wideNeed, "...which is less than the wide layout's")

    -- ---- built ----------------------------------------------------------------------
    local savedCF = CreateFrame
    CreateFrame = function(kind, _, parent)
        local f = FakeUIFrame()
        f._kind, f._parent = kind, parent
        return f
    end
    local segs, dds = {}, {}
    local saved3 = { G.CreateLabelNative, G.CreateElementBackdrop, G.StyleButton, G.CreateSegmentToggle,
                     G.CreateDropdown, G.SetSettingsFont, G.ShowTooltip, G.HideTooltip, G.GetAccent }
    function G:CreateLabelNative(_, o) local l = FakeUIFrame(); l:SetText(o and o.text or ""); return l end
    function G:CreateElementBackdrop(f) return f end
    function G:StyleButton(b, o) b.Text = FakeUIFrame(); b.Text:SetText(o.text or ""); b._opts = o; b:SetWidth(o.width or 60); b:SetHeight(o.height or 24) end
    function G:CreateSegmentToggle(parent, segments, _, _, _, o)
        local f = FakeUIFrame()
        f.segments, f.opts, f.parent = segments, o, parent
        -- The real helper's geometry (pinned in test_segment_toggle_page_min.lua):
        -- a rounded track has a 2px lip and 2px between pills.
        local n = #segments
        if o.rounded then f:SetSize(n * o.segmentWidth + (n - 1) * 2 + 4, o.height + 4)
        else f:SetSize(n * o.segmentWidth + 2, o.height + 2) end
        f.Refresh = function() end
        segs[#segs + 1] = f
        return f
    end
    function G:CreateDropdown(parent, label, options, _, _, _, get, set, o)
        local d = FakeUIFrame(); d.label, d.get, d.set, d.opts = label, get, set, o
        dds[#dds + 1] = d
        return d
    end
    function G:SetSettingsFont() end
    function G:ShowTooltip() end
    function G:HideTooltip() end
    function G:GetAccent() return { r = 0.6, g = 0.4, b = 1 } end
    G.PageChildWidth = function(cw) return cw - 22 end
    G.PageUsableWidth = function(cw) return cw - 10 end
    G.contentFrame = FakeUIFrame(1000, 600)

    local page = made.pages.uf_links
    page.child = FakeUIFrame()
    local blocks = {}
    page.builder(page, UF:GetGlobalDB(), function(wg, h, col) blocks[#blocks + 1] = { w = wg, h = h, col = col }; return wg end)
    eq(#blocks, 3, "head, the three explainers, one card per link")
    for _, b in ipairs(blocks) do eq(b.col, "both", "every block spans the page") end
    local card = blocks[3].w
    check(card.dfLinkCard, "the third block is the link's card")
    eq(#card.rows, 17, "a row per part both frames have")
    local byId = {}
    for _, r in ipairs(card.rows) do byId[r.elem.id] = r end
    local function values(seg) local t = {} for i, x in ipairs(seg.segments) do t[i] = x.value end return table.concat(t, ",") end
    eq(values(byId.health.pos), "same,mirror,own", "Health: Same / Mirrored / Separate")
    eq(byId.health.pos.segments[3].label, "Separate", "...the off choice reads Separate")
    check(byId.health.pos.segments[3].accent ~= nil and byId.health.pos.segments[1].accent == nil,
          "...and only it wears the neutral accent when chosen")
    for _, id in ipairs({ "absorbs", "healpred", "tooltips" }) do
        eq(values(byId[id].pos), "same,own", id .. ": Same / Separate only (no Mirrored)")
    end
    eq(rawget(byId.border, "pos"), nil, "Border: no position segment...")
    check(rawget(byId.border, "noPos") ~= nil, "...it says No position settings")
    eq(values(byId.border.look), "same,own", "Size & Style: Same / Separate")
    eq(byId.health.result:GetText(), "Target is a mirror image of Player.", "Health's result line")
    eq(byId.absorbs.result:GetText(), "Not linked. Each frame has its own.", "Absorbs' result line")
    eq(byId.health.badge:GetText(), "+1", "Health: one thing kept apart")
    eq(byId.portrait.badge:GetText(), "", "Portrait: nothing kept apart")
    eq(card.summary:GetText(), "8 of 17 parts linked", "the card's summary")
    -- The leader reads first: "Player linked with Target", results from Target's side.
    eq(card.leaderDD.get(), "player", "the first picker shows the leader (Player)")
    eq(card.followerDD.get(), "target", "...the second the follower (Target)")
    eq(table.concat(card.leaderDD.opts.optionsFunc()._order, ","), "player,target,targettarget,focus,focustarget,pet,boss",
       "both pickers offer every frame (picking the other one swaps them)")
    -- Rounded, the settings cards' recipe.
    check(byId.health.pos.opts.rounded == true and byId.health.look.opts.rounded == true,
          "both segments are the rounded track")
    eq(byId.health.pos:GetWidth(), UFO.SegTrackWidth(3, UFO.linkMeasured.segW), "a 3-choice track's width")
    eq(byId.absorbs.pos:GetWidth(), UFO.SegTrackWidth(2, UFO.linkMeasured.segW), "a 2-choice track's width")
    for _, b in ipairs(card.buttons) do check(b._opts.rounded == true, "rounded button: " .. tostring(b.Text:GetText())) end

    -- Widths: wide when it fits, stacked when it does not, nothing past the edge.
    local wideW = UFO.LinkCardNeeds(UFO.linkMeasured)
    card:Layout(wideW + 40)
    eq(card.mode, "wide", "wide when it fits")
    card:Layout(wideW - 1)
    eq(card.mode, "stacked", "stacked when it does not")
    local minUsable = UFO.LinksMinUsableWidth(UFO.linkMeasured)
    card:Layout(minUsable)
    eq(card.mode, "stacked", "stacked at the page's minimum")
    local lookSeg = byId.health.look
    local _, _, _, lx = lookSeg:GetPoint(1)
    check(lx + lookSeg:GetWidth() <= minUsable - UFO.LINK_METRICS.pad,
          "at the minimum: the last segment ends inside the card")
    eq(UFO.LinksMinWindowWidth(nil, 281), 281 + minUsable, "the page's minimum window width is the narrow layout's")

    -- ---- the actions ---------------------------------------------------------------
    local function click(cfg, label)
        for _, b in ipairs(cfg.buttons) do if b.label == label then if b.onClick then b.onClick() end return true end end
    end
    popups = {}
    byId.absorbs.look.opts.customSet("same")
    eq(#popups, 1, "sharing a part asks first")
    click(popups[1], "Link")
    eq(select(2, Lk:Aspects(root, "target", "absorbs")), "same", "...and Link shares it")
    popups = {}
    byId.absorbs.look.opts.customSet("own")
    eq(#popups, 0, "Separate copies nothing: no question")
    eq(select(2, Lk:Aspects(root, "target", "absorbs")), "own", "...applied at once")
    byId.absorbs.pos.opts.customSet("same")
    click(popups[1], "Link")
    eq((Lk:Aspects(root, "target", "absorbs")), "same", "Absorbs position: Same")

    -- Mirror All: every part, absorbs' position stays same (it cannot mirror).
    local function btn(label) for _, b in ipairs(card.buttons) do if b.Text:GetText() == label then return b end end end
    popups = {}
    btn("Mirror All"):GetScript("OnClick")()
    click(popups[1], "Mirror All")
    eq((Lk:Aspects(root, "target", "health")), "mirror", "Mirror All: health mirrored")
    eq((Lk:Aspects(root, "target", "absorbs")), "same", "Mirror All: absorbs same (never mirrored)")
    eq(select(2, Lk:Aspects(root, "target", "visibility")), "same", "Mirror All: visibility's look shared")
    popups = {}
    btn("Separate All"):GetScript("OnClick")()
    eq(#popups, 0, "Separate All copies nothing: no question")
    eq(Lk:ElementLinked(root, "target", "health"), false, "Separate All: nothing linked")
    check(Lk:LinkOf(root, "target") ~= nil, "...the link stays")
    popups = {}
    btn("Copy All"):GetScript("OnClick")()
    click(popups[1], "Copy All")
    eq((Lk:Aspects(root, "target", "health")), "same", "Copy All: shared, nothing flipped")

    -- Unlink: asks, the tooltip says nothing is reset, the link goes.
    popups = {}
    btn("Unlink"):GetScript("OnClick")()
    check(popups[1] and popups[1].message:find("keep their settings", 1, true), "Unlink asks, and says both keep their settings")
    click(popups[1], "Unlink")
    eq(UFO.Partner("target"), nil, "Unlink: gone")
    eq(UFO.PageMark("uf_links"), nil, "...and the page's mark with it")

    -- Swapping from the pickers: the first picker set to the follower turns the
    -- link round, and asks first.
    root.global.unitLinks = nil
    Lk:Ensure(root)
    blocks = {}
    page.builder(page, UF:GetGlobalDB(), function(wg, h, col) blocks[#blocks + 1] = { w = wg }; return wg end)
    local sw = blocks[3].w
    popups = {}
    sw.leaderDD.set("target")
    eq(#popups, 1, "swapping asks first")
    check(not popups[1].message:find("replaces", 1, true), "...and does not call it replacing a link")
    click(popups[1], "Link")
    eq(root.global.unitLinks.player and root.global.unitLinks.player.to, "target", "swapped: Player follows Target")
    eq(root.global.unitLinks.target, nil, "...and Target no longer follows Player")
    eq((Lk:Aspects(root, "player", "health")), "mirror", "...keeping the parts")
    Lk:Unlink(root, "player")
    -- In a draft the swap just happens.
    UFO.StartLinkDraft()
    blocks = {}
    page.builder(page, UF:GetGlobalDB(), function(wg, h, col) blocks[#blocks + 1] = { w = wg }; return wg end)
    local dr = blocks[3].w
    dr.leaderDD.set("target")
    eq(UFO.linkDraft.leader .. ">" .. UFO.linkDraft.follower, "target>player", "draft: picking the other frame swaps them")
    UFO.linkDraft = nil

    -- + Link Two Frames: a draft card with the first free pair, then Link.
    UFO.StartLinkDraft()
    eq(UFO.linkDraft and (UFO.linkDraft.leader .. ">" .. UFO.linkDraft.follower), "player>target", "the draft starts on the first two free frames")
    blocks = {}
    page.builder(page, UF:GetGlobalDB(), function(wg, h, col) blocks[#blocks + 1] = { w = wg }; return wg end)
    local draft = blocks[3].w
    eq(#draft.rows, 0, "the draft card has no rows yet")
    popups = {}
    draft.buttons[1]:GetScript("OnClick")()
    click(popups[1], "Link")
    eq(UFO.Partner("target"), "player", "Link: Target follows Player again")
    eq(root.global.unitLinks.target.elements.health.layout, "mirror", "...as the default pair")
    eq(UFO.linkDraft, nil, "...and the draft is done")

    -- Moving one end of a link keeps its parts.
    Lk:SetElement(root, "target", "absorbs", "same", "same")
    popups = {}
    UFO.ConfirmLinkPair("focus", "player", root.global.unitLinks.target.elements)
    check(popups[1].message:find("replaces", 1, true), "moving an end says it replaces the current link")
    click(popups[1], "Link")
    eq(UFO.Partner("focus"), "player", "Focus now follows Player")
    eq(UFO.Partner("target"), nil, "...Target is free")
    eq(select(2, Lk:Aspects(root, "focus", "absorbs")), "same", "...and the parts came along")
    Lk:Unlink(root, "focus")

    CreateFrame = savedCF
    G.CreateLabelNative, G.CreateElementBackdrop, G.StyleButton, G.CreateSegmentToggle, G.CreateDropdown,
        G.SetSettingsFont, G.ShowTooltip, G.HideTooltip, G.GetAccent =
        saved3[1], saved3[2], saved3[3], saved3[4], saved3[5], saved3[6], saved3[7], saved3[8], saved3[9]
    G.contentFrame = nil
end

-- ============================================================
-- 8. WIRING (source shape)
-- ============================================================
print("-- Wiring")
do
    local search = options_file_source("Features/Search.lua")
    local reg = search:find("function Search:Register(entry)", 1, true)
    local filt = search:find("if filter and entry and filter(entry) == false then", 1, true)
    local cap = search:find("local capture = self._captureEntries", 1, true)
    check(reg and filt and cap and reg < filt and filt < cap,
          "Search: a filtered entry is marked before anything else can return early")
    check(search:find("page.searchTabLabel or page.tabLabel or tabName", 1, true),
          "Search: the index labels a page by its search label")
    check(search:find("local db = EntryDB(entry)", 1, true) and not search:find("local db = DF.db[DF.GUI.SelectedMode]", 1, true),
          "Search: an inline result control edits its page's own table")
    local panel = options_file_source("GUI/Panel.lua")
    check(panel:find("if page then page.dfBuilder = builderFunc end", 1, true), "Panel: a page keeps its builder")
    check(panel:find("Search.CurrentTabLabel = self.searchTabLabel or self.tabLabel or self.tabName", 1, true),
          "Panel: a build labels its entries by the search label")
    check(panel:find("or GUI:PageWantsOtherTab(name)", 1, true), "Panel: SelectTab moves the tab for a page on another one")
    check(panel:find("local db = (GUI.PageBuildDb and GUI.PageBuildDb(self)) or DF.db[GUI.SelectedMode]", 1, true),
          "Panel: a module page's states read its own table")
    local gui = df_file_source("GUI/GUI.lua")
    check(gui:find("local own = page and GUI.PageBuildDb and GUI.PageBuildDb(page)", 1, true),
          "host: groups on a module page read its own table")
    local ctl = options_file_source("GUI/Controls.lua")
    check(ctl:find("local own = GUI.PageBuildDb and GUI.PageBuildDb(page)", 1, true),
          "tools: a pinned panel binds to the page's own table")
    local cs = options_file_source("Features/ChangedSettings.lua")
    check(cs:find("if not (owned and e.tab and owned[e.tab])", 1, true),
          "Changed Settings: a module's own pages are in neither ledger")
    local toc = options_file_source("DandersFrames_Options.toc")
    local pd, pg, mp = toc:find("UnitFrames\\PageData.lua", 1, true), toc:find("UnitFrames\\Pages.lua", 1, true),
                       toc:find("GUI\\Pages\\ModulesPage.lua", 1, true)
    check(pd and pg and mp and mp < pd and pd < pg, "TOC: the data, then the pages, after the built-in pages")
    local ad = df_file_source("AuraDesigner/AuraAdapter.lua")
    local sa, po = ad:find("if frame.dfStandalone and type(frame.dfDB) == \"table\" then", 1, true),
                   ad:find("if frame.dfAuraPresetOverride then", 1, true)
    check(sa and po and sa < po, "Aura Designer: a standalone frame's own enable, asked first")
    check(ad:find("return frame.dfDB.auraDesignerEnabled == true", 1, true), "...absent means off")
    local pr = df_file_source("Designer/Presets.lua")
    check(pr:find("function DF:IsAuraDesignerEnabledForDB(d)", 1, true), "Aura Designer: an enable per settings table")
    local ind = options_file_source("GUI/Pages/Indicators.lua")
    local _, n = ind:gsub("DF:IsAuraDesignerEnabledForDB%(d%)", "")
    eq(n, 3, "Buff Bar: its three AD banners ask the page's own table")
    -- Every string the unit frame pages and the link elements show is a real key.
    local en = df_file_source("Locales/enUS.lua")
    local known = {}
    for k in en:gmatch('\nL%["(.-)"%] = true') do known[k] = true end
    local missing = {}
    for k in options_file_source("UnitFrames/Pages.lua"):gmatch('L%["(.-)"%]') do
        if not known[k] then missing[#missing + 1] = k end
    end
    for _, e in ipairs(UF.Links.ELEMENTS) do
        if not known[e.title] then missing[#missing + 1] = e.title end
    end
    eq(table.concat(missing, " | "), "", "every L key the pages and elements use is in enUS")
    check(not en:find('L["Sync with..."]', 1, true) and not en:find('L["Stop Syncing"]', 1, true),
          "the per-page sync's own strings are gone")
    local pages = options_file_source("UnitFrames/Pages.lua")
    check(not pages:find("syncedPages", 1, true), "the settings pages no longer touch syncedPages")
    local ufcore = uf_file_source("Core.lua")
    check(ufcore:find("if stored == nil or (mt and mt.__realTable == stored) then return eff end", 1, true),
          "companion: a cached unit table is dropped when the profile under it moved")
end

-- The unit proxy follows a profile switch even before OnProfileChanged runs.
print("-- A profile switch under a cached unit table")
do
    local before = UF:GetUnitDB("target")
    DF.db = { unitframes = deepcopy(UF.ProfileDefaults) }
    local after = UF:GetUnitDB("target")
    check(after ~= before, "a new profile: a new proxy")
    after.frameWidth = 222
    eq(DF.db.unitframes.units.target.frameWidth, 222, "...writing into the new profile")
end

-- The Modules page's Reset on Unit Frames (UFO.Reset; MODULE RESET in
-- GUI/ModuleRegistry.lua). The data is UF:ResetProfile's (test_uf_reset.lua);
-- this side offers it only while the module is loaded, refreshes the settings
-- pages, and asks for the reload when a unit changed hands.
print("-- The Modules page's Reset")
do
    check(def.reset == UFO.Reset, "reset: the module carries UFO.Reset")
    check(G:GetModuleReset("units") ~= nil, "reset: offered while the module is loaded")
    addon.loaded = false
    eq(G:GetModuleReset("units"), nil, "reset: not offered while it is not loaded")
    addon.loaded = true
    local covers = table.concat(UFO.Reset.covers(), "|")
    check(covers:find("Every unit frame's settings", 1, true) and covers:find("Frame positions", 1, true)
          and covers:find("Linked frames: the default Player and Target link is made again", 1, true)
          and covers:find("The Unit Frames Settings page", 1, true),
          "reset: covers every unit, positions, links and the module's settings")
    eq(UFO.Reset.scope, nil, "reset: the current profile's (the default scope line)")

    local realReset = UF.ResetProfile
    local invalidated = 0
    G.InvalidateAllPages = function() invalidated = invalidated + 1 end
    popups = {}
    UF.ResetProfile = function() return true, true end
    eq(UFO.Reset.run(), true, "run: reports success")
    eq(invalidated, 1, "run: every settings page is rebuilt on its next show")
    local last = popups[#popups]
    eq(last and last.message, "Changing who draws a unit frame requires a UI reload to take effect.\n\nReload now?",
       "run: a unit changed hands -- the reload prompt")
    popups = {}
    UF.ResetProfile = function() return true, false end
    UFO.Reset.run()
    eq(#popups, 0, "run: no reload prompt when nothing changed hands")
    invalidated = 0
    UF.ResetProfile = function() return false end
    eq(UFO.Reset.run(), false, "run: a refused reset reports it")
    eq(invalidated, 0, "run: ...and refreshes nothing")
    UF.ResetProfile = realReset
    G.InvalidateAllPages = nil
end

DandersFrames = saved.DandersFrames
CreateFrame = saved.CreateFrame
C_AddOns = saved.C_AddOns
C_Timer = saved.C_Timer
ReloadUI = saved.ReloadUI
