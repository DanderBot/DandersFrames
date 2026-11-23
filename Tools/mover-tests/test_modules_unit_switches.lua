local NS = ...

-- ============================================================
-- THE MODULES PAGE: PER-FRAME UNIT SWITCHES AND FOLDED LISTS
-- DandersFrames_Options/GUI/Pages/ModulesPage.lua (GUI:ModuleSubSwitches,
-- GUI:IsModuleListFolded) + DandersFrames_Options/UnitFrames/Pages.lua
-- (UFO.SubSwitches, UFO.OffSource, UFO.GetSource read while unloaded).
-- ------------------------------------------------------------
-- The real module registry, companion Core / Links / Defaults and UF pages file
-- over stub frames. Checked: the entry list (one per frame, Boss once), on = our
-- frame, off = Blizzard's or Hidden where Blizzard is not allowed, the reload
-- prompt, the greyed state while the module is not running, Group Frames'
-- Party / Raid entries, and the remembered fold. Not pixels: the view itself is
-- never drawn here, so a green run is not proof the page renders.
-- ☠ Every global it replaces is restored at the end.
-- ============================================================

local saved = {
    DandersFrames = DandersFrames, CreateFrame = CreateFrame, C_AddOns = C_AddOns,
    C_Timer = C_Timer, ReloadUI = ReloadUI, DandersFramesDB_v2 = DandersFramesDB_v2,
}
C_Timer = { After = function(_, fn) fn() end }
ReloadUI = function() end

local function noop() end
local FrameMT = { __index = function(_, k)
    if type(k) == "string" and k:match("^%u") then return noop end
end }
local function Frame()
    local f = setmetatable({ shown = true }, FrameMT)
    f.Hide = function(self) self.shown = false end
    f.Show = function(self) self.shown = true end
    f.IsShown = function(self) return self.shown end
    f.CreateFontString = function() return setmetatable({ GetStringWidth = function() return 40 end }, FrameMT) end
    return f
end

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

local popups = {}
local DF = { PartyDefaults = { frameWidth = 125, frameHeight = 64 }, SECTION_PREFIXES = {} }
DF.L = setmetatable({}, { __index = function(_, k) return k end })
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable() return true end
DF.RegisterCallback = function() end
DF.Apply = { AddPostDrain = function() end }
function DF:ShowPopupAlert(cfg) popups[#popups + 1] = cfg end
function DF:PromptReloadIfEnableFlagsChanged(msg) popups[#popups + 1] = { message = msg } end
DandersFrames = DF

CreateFrame = nil        -- the companion's file-scope event wiring is skipped
local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Links.lua", UF)
load_uf_file_into("Defaults.lua", UF)
CreateFrame = function() return Frame() end
DF.db = { unitframes = deepcopy(UF.ProfileDefaults) }
UF.frames = {}

local addon = { exists = true, loaded = true, enabled = true }
C_AddOns = {
    DoesAddOnExist = function(name) return name == "DandersFrames_UnitFrames" and addon.exists end,
    IsAddOnLoaded = function(name) return name == "DandersFrames_UnitFrames" and addon.loaded end,
    GetAddOnEnableState = function(name) return (name == "DandersFrames_UnitFrames" and addon.enabled) and 2 or 0 end,
    EnableAddOn = function() addon.enabled = true end,
    DisableAddOn = function() addon.enabled = false end,
}

local collapsed = {}
local function NewGUI()
    local G = {
        SelectedMode = "party", GlobalView = false, GlobalAccent = { r = 0.25 },
        GlobalPages = {}, Pages = {},
        Colors = { text = { r = 1, g = 1, b = 1 }, textDim = { r = 0.5, g = 0.5, b = 0.5 },
                   panel = { r = 0, g = 0, b = 0 }, border = { r = 0.3, g = 0.3, b = 0.3 } },
    }
    function G.IsGlobalPage(name) return G.GlobalPages[name] == true end
    function G.GetThemeColorFor(isRaid) return isRaid and "RAID" or "PARTY" end
    function G:SetAccent() end
    function G.CurrentAccent() return "ACCENT" end
    function G.UpdateThemeColors() end
    function G:ShowNormalContent() end
    function G:ShowPlaceholderContent() end
    function G:ShowClickCastingContent() end
    function G:RefreshCurrentPageForModeSwitch() end
    function G:UpdateTabLayout() end
    function G:LastTabInView() return nil end
    function G:EnterView(g) G.GlobalView = g and true or false end
    G.SelectTab = function() end
    function G:CreatePopoutPageTools() return nil end
    function G:GetCollapsedGroups() return collapsed end
    DF.GUI = G
    DF.GUIPageProviders = {}
    load_options_file_into("GUI/ModuleRegistry.lua", NS)
    return G
end

local function Load()
    load_options_file_into("UnitFrames/PageData.lua", NS)
    load_options_file_into("UnitFrames/Pages.lua", NS)
    load_options_file_into("GUI/Pages/ModulesPage.lua", NS)
    return DF.GUI.UnitFrameOptions
end

local function byKey(list)
    local o = {}
    for _, e in ipairs(list) do o[e.key] = e end
    return o
end

-- ============================================================
-- 1. LOADED: one switch per frame, over the frame's source
-- ============================================================
print("-- Loaded: the per-frame switches")
do
    addon.exists, addon.loaded, addon.enabled = true, true, true
    local G = NewGUI()
    local UFO = Load()
    local def = G:GetModule("units")
    eq(type(def and def.subSwitches), "function", "loaded: the units module brings its sub-switches")
    local list = G:ModuleSubSwitches(def)
    local keys = {}
    for i, e in ipairs(list) do keys[i] = e.key end
    eq(table.concat(keys, ","), "player,target,targettarget,focus,focustarget,pet,boss",
       "entries: every frame, in order, Boss once for all five")
    local E = byKey(list)
    eq(E.targettarget.label, "Target of Target", "entries: the frame's own name")
    eq(E.focustarget.openTab, "focus", "entries: Open on the focus target goes to the Focus tab")
    eq(E.player.openModule, "units", "entries: ...in the Unit Frames module")
    check(not E.player.disabled(), "loaded: the switches are live")
    check(E.player.isOn(), "default: our frames are on")

    popups = {}
    E.player.setOn(false)
    eq(UFO.GetSource("player"), "Blizzard", "off: Blizzard's own frame comes back")
    eq(#popups, 1, "off: through the reload prompt")
    eq(E.player.offStatus(), "Blizzard", "off: the status says who draws it")
    check(not E.player.isOn(), "off: the switch reads off")
    E.player.setOn(true)
    eq(UFO.GetSource("player"), "DF", "on: ours again")

    E.targettarget.setOn(false)
    eq(UFO.GetSource("targettarget"), "Hidden",
       "off: ToT goes Hidden while Target is ours (Blizzard's ToT lives in its target frame)")
    eq(E.targettarget.offStatus(), "Hidden", "off: ...and says so")
    E.targettarget.setOn(true)
    UFO.SetSource("target", "Blizzard")
    E.targettarget.setOn(false)
    eq(UFO.GetSource("targettarget"), "Blizzard", "off: ToT is Blizzard's once Target is")
    UFO.SetSource("target", "DF")
    E.focustarget.setOn(false)
    eq(UFO.GetSource("focustarget"), "Hidden", "off: the focus target follows the same rule")

    E.boss.setOn(false)
    eq(UF:GetStoredUnit("boss").source, "Blizzard", "boss: one switch, one table for boss1-5")
    -- Restore for the next scenario.
    for _, u in ipairs(UFO.UNITS) do UF:GetStoredUnit(u).source = nil end
end

-- ============================================================
-- 2. NOT RUNNING: greyed, with the reason; the stored state still shows
-- ============================================================
print("-- Not running: greyed")
do
    addon.exists, addon.loaded, addon.enabled = true, false, false
    local held = DF.UnitFrames
    DF.UnitFrames = nil
    UF:GetStoredUnit("pet").source = "Hidden"     -- written before, in the raw table
    local G = NewGUI()
    local UFO = Load()
    local def = G:GetModule("units")
    eq(type(def and def.subSwitches), "function", "off: the switches are listed while the module is off")
    local E = byKey(G:ModuleSubSwitches(def))
    local off, why = E.player.disabled()
    check(off and why == "Turn on Unit Frames first.", "module off: greyed, and the row says why")
    check(E.player.isOn(), "module off: an untouched frame reads on (absent means ours)")
    check(not E.pet.isOn() and E.pet.offStatus() == "Hidden", "module off: the stored source is read raw")

    addon.enabled = true
    off, why = E.player.disabled()
    check(off and why == "Reload to finish turning on Unit Frames.", "on, not reloaded: greyed until the reload")
    DF.UnitFrames = held
    UF:GetStoredUnit("pet").source = nil
    check(UFO ~= nil, "off: the pages file loaded")
end

-- ============================================================
-- 3. GROUP FRAMES: Party and Raid ride the same entry shape
-- ============================================================
print("-- Group Frames entries")
do
    addon.loaded, addon.enabled = true, true
    local G = NewGUI()
    Load()
    local list = G:ModuleSubSwitches("group")
    eq(#list, 2, "group: Party and Raid")
    local E = byKey(list)
    eq(E.party.label, "Party Frames", "group: Party's name")
    eq(E.raid.accent, "RAID", "group: Raid in the raid accent")
    eq(E.party.openTab, "party", "group: Open goes to the mode's tab")
    local held = DF.db
    DF.db = { partyEnabled = true, raidEnabled = true }
    popups = {}
    E.raid.setOn(false)
    eq(DF.db.raidEnabled, false, "group: Raid's switch writes the existing flag")
    eq(#popups, 1, "group: through the frame-mode reload prompt")
    check(not E.raid.isOn() and E.party.isOn(), "group: isOn reads the flags")
    DF.db = held
    eq(#G:ModuleSubSwitches("clicks"), 0, "no sub-rows on a module without any")
    G:GetModule("group").subSwitches = function() error("boom") end
    eq(#G:ModuleSubSwitches("group"), 0, "a broken provider gives no rows, not an error")
end

-- ============================================================
-- 4. THE FOLD: open by default, remembered account-wide
-- ============================================================
print("-- Folded lists")
do
    local G = NewGUI()
    Load()
    check(not G:IsModuleListFolded("units"), "fold: open by default")
    G:SetModuleListFolded("units", true)
    check(G:IsModuleListFolded("units"), "fold: folded")
    eq(collapsed["modules:units"], true, "fold: kept in the collapsible-sections store")
    check(not G:IsModuleListFolded("group"), "fold: per module")
    G:SetModuleListFolded("units", false)
    eq(collapsed["modules:units"], nil, "fold: opening clears the key (nothing stored for the default)")
end

-- ============================================================
-- 5. THE VIEW USES THE KIT'S PILL SWITCH (source shape)
-- ============================================================
print("-- The view's switch")
do
    local src = options_file_source("GUI/Pages/ModulesPage.lua")
    check(src:find("GUI:CreateSwitch(row, {", 1, true) and src:find("rounded = true", 1, true),
          "view: rows use the kit's rounded switch")
    check(not src:find("CreateCheckRow", 1, true), "view: the checkbox stand-in is gone")
end

-- By name, not pairs(saved): a global that was nil before has no key in
-- `saved`, and pairs would leave this file's stub behind for the next suite.
for _, k in ipairs({ "DandersFrames", "CreateFrame", "C_AddOns", "C_Timer", "ReloadUI", "DandersFramesDB_v2" }) do
    _G[k] = saved[k]
end
