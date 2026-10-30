local NS = ...

-- ============================================================
-- THE PROFILES MODULE
-- DandersFrames/GUI/GUI.lua (THE PROFILES SIDEBAR), DandersFrames_Options/
-- GUI/ModuleRegistry.lua (the module), GUI/Pages/Profiles.lua (its pages),
-- GUI/Panel.lua (mode-neutral builds), DandersFrames/Core/Profile.lua (rename)
-- ------------------------------------------------------------
-- The Profiles rail item has a sidebar of its own, not tied to Party or Raid.
-- The real registry runs over recorders (as test_module_registry does), the
-- real page setup over a recording CreateSubTab, and DF:RenameProfile is lifted
-- out of source and run against a fake SavedVariables.
-- ============================================================

local savedDF = DandersFrames
local savedSV, savedChar = DandersFramesDB_v2, DandersFramesCharDB

local function between(src, a, b)
    local s = src:find(a, 1, true)
    if not s then return nil end
    local e = src:find(b, s, true)
    if not e then return nil end
    return src:sub(s, e - 1)
end

local calls
local function joined() return table.concat(calls, ",") end

-- ---- the GUI stub, with the REAL page sets from GUI.lua ------------------
local GUI = { SelectedMode = "party", GlobalView = false, Colors = { text = "TEXT" } }
local PARTY, RAID = "PARTY", "RAID"
local GUISRC = df_file_source("GUI/GUI.lua"):gsub("\r\n", "\n")
local defs = between(GUISRC, "GUI.GlobalAccent = ", "-- Registry of tabs that should show")
check(defs ~= nil, "pages: the page sets are in GUI.lua")
if defs then
    local chunk = loadstring("local GUI, GetThemeColorFor = ...\n" .. defs)
    check(chunk ~= nil, "pages: ...and compile on their own")
    if chunk then chunk(GUI, function(isRaid) return isRaid and RAID or PARTY end) end
end
GUI.GetThemeColorFor = function(isRaid) return isRaid and RAID or PARTY end
function GUI:SetAccent(c) calls[#calls + 1] = "accent:" .. tostring(c) end
function GUI.UpdateThemeColors() calls[#calls + 1] = "theme" end
function GUI:ShowNormalContent()
    calls[#calls + 1] = "normal" .. (GUI._redirectingTab and "(held)" or "")
end
function GUI:ShowClickCastingContent() calls[#calls + 1] = "clickcontent" end
function GUI:ShowPlaceholderContent(def) calls[#calls + 1] = "placeholder:" .. tostring(def.id) end
function GUI:UpdateTabAvailability() calls[#calls + 1] = "avail" end
function GUI:RefreshCurrentPageForModeSwitch() calls[#calls + 1] = "refresh" end
function GUI:LastTabInView()
    if GUI.ProfilesView then return GUI._lastProfilesPage or "profiles_manage" end
    return GUI.GlobalView and "general_settings" or "general_frame"
end
function GUI:EnterView(g)
    calls[#calls + 1] = "view:" .. tostring(g)
    if GUI.SelectedMode == "clicks" then GUI.SelectedMode = GUI._lastFrameMode or "party" end
    GUI.GlobalView = g and true or false
end
GUI.SelectTab = function(n) calls[#calls + 1] = "tab:" .. tostring(n) end
GUI.Tabs = { profiles_manage = {}, profiles_auto = {}, profiles_changed = {}, general_frame = {} }

local partyDb, raidDb = { locked = true }, { raidLocked = true }
local DF = { GUI = GUI }
DF.L = setmetatable({}, { __index = function(_, k) return k end })
function DF:Debug() end
function DF:DebugWarn() calls[#calls + 1] = "warn" end
function DF:DebugError() calls[#calls + 1] = "error" end
function DF:SyncLinkedSections() calls[#calls + 1] = "sync" end
function DF:GetDB() return partyDb end
function DF:GetRaidDB() return raidDb end
function DF:LockFrames() calls[#calls + 1] = "lockparty" end
function DF:LockRaidFrames() calls[#calls + 1] = "lockraid" end
function DF:HideTestFrames() DF.testMode = false end
function DF:HideRaidTestFrames() DF.raidTestMode = false end
function DF:ClearTestModeOwners() end
function DF:SetTestModeOwner() end
function DF:TeardownTestModeEngines() end
DF.Search = {
    InvalidateRegistry = function() calls[#calls + 1] = "invalidate" end,
    RefreshIfActive = function() end,
    HideResults = function() end,
}
DandersFrames = DF

calls = {}
load_options_file_into("GUI/ModuleRegistry.lua", NS)

-- ---- ownership and sidebar membership --------------------------------------
print("-- Profiles module: its pages, and nobody else's")
local P = GUI:GetModule("profiles")
check(P ~= nil and P.sidebar == true, "module: Profiles has a sidebar of its own")
check(not P.placeholder and not P.view, "module: ...and is neither a placeholder nor a view")
check(GUI:IsModuleOn("profiles"), "module: ...and is always on")
for _, id in ipairs({ "profiles_manage", "profiles_spec", "profiles_auto", "profiles_clickcast",
                      "profiles_importexport", "profiles_changed" }) do
    eq(GUI:ModuleForPage(id), "profiles", "own: " .. id .. " is Profiles'")
end
eq(GUI:ModuleForPage("general_frame"), "group", "own: a frame page is still Group Frames'")
eq(GUI:ModuleForPage("general_settings"), "global", "own: a GLOBAL page is still Global's")
check(not GUI.IsGlobalPage("profiles_manage") and not GUI.IsGlobalPage("profiles_importexport"),
      "own: Manage and Import / Export left GLOBAL's sidebar")
eq(GUI.GlobalPages.profiles_changed_global, nil, "own: the Global changed-settings page is gone")

-- ---- entering and leaving ------------------------------------------------------
print("-- Profiles module: entering and leaving")
calls = {}
GUI:SelectModule("profiles")
eq(GUI.SelectedModule, "profiles", "enter: Profiles is the module showing")
check(GUI.ProfilesView == true, "enter: ...through its own view flag")
eq(GUI.SelectedMode, "party", "enter: the frame mode under it is untouched")
check(joined():find("normal(held)", 1, true) ~= nil, "enter: the sidebar comes back with the redirect held")
check(joined():find("tab:profiles_manage", 1, true) ~= nil, "enter: ...and it lands on the page it showed last")
check(not joined():find("sync", 1, true) and not joined():find("lockparty", 1, true),
      "enter: no Party/Raid switch work happens (no sync, no locks)")

calls = {}
GUI:SelectModule("profiles")
eq(#calls, 0, "enter: picking it again while it shows does nothing")

calls = {}
GUI:SelectModule("profiles", "profiles_auto")
check(joined():find("tab:profiles_auto", 1, true) ~= nil, "enter: a page asked for is the page selected")

-- back to the same mode: the view switch alone
calls = {}
GUI:SelectModule("group", "party")
eq(GUI.SelectedModule, "group", "leave: back to Group Frames")
check(GUI.ProfilesView == false, "leave: the view flag is down")
check(joined():find("view:false", 1, true) ~= nil and not joined():find("sync", 1, true),
      "leave: same mode underneath -- the view switch alone, no sync")
eq(GUI._leavingProfiles, nil, "leave: the hand-over flag never outlives the switch")

-- GLOBAL under it: GLOBAL comes back with its view and page
GUI:SelectModule("global")
check(GUI.GlobalView == true, "global: on GLOBAL first")
GUI:SelectModule("profiles")
eq(GUI.SelectedModule, "profiles", "global: Profiles over GLOBAL")
calls = {}
GUI:SelectModule("global")
eq(GUI.SelectedModule, "global", "global: back to GLOBAL")
check(joined():find("view:true", 1, true) ~= nil and joined():find("tab:general_settings", 1, true) ~= nil,
      "global: ...which re-enters its view and page, though GlobalView was already set")

-- from BINDS: steps back onto the frame mode Binds was entered from
GUI:SelectModule("group", "raid")
GUI._lastFrameMode = "raid"
GUI:SelectModule("clicks")
eq(GUI.SelectedMode, "clicks", "binds: on Binds first")
calls = {}
GUI:SelectModule("profiles")
eq(GUI.SelectedMode, "raid", "binds: Profiles from Binds puts the frame mode back under it")
check(joined():find("invalidate", 1, true) ~= nil, "binds: ...and the search index is rebuilt for it")
-- Profiles wears its page's accent (GUI.ProfilesPageAccents), not the mode's:
-- with no Profiles page up yet, the account-wide teal.
check(joined():find("accent:" .. tostring(GUI.GlobalAccent), 1, true) ~= nil, "binds: ...in the Profiles accent, not the mode's")

-- ---- the frame mode under the view (Changed Settings' scope picker) ---------
print("-- Profiles module: switching the mode underneath without leaving")
calls = {}
check(GUI:SetUnderlyingFrameMode("party"), "under: switching to Party reports success")
eq(GUI.SelectedMode, "party", "under: the mode underneath moved")
eq(GUI.SelectedModule, "profiles", "under: ...and Profiles is still showing")
check(GUI.ProfilesView == true, "under: ...view flag and all")
check(joined():find("sync", 1, true) ~= nil and joined():find("refresh", 1, true) ~= nil,
      "under: it is the whole Party/Raid switch (sync, page refresh)")
calls = {}
check(GUI:SetUnderlyingFrameMode("party"), "under: the mode already up is a no-op success")
eq(#calls, 0, "under: ...doing nothing")
check(not GUI:SetUnderlyingFrameMode("clicks"), "under: only Party or Raid")
GUI:SetModuleLocked("group", true, "raid")
check(not GUI:SetUnderlyingFrameMode("raid"), "under: a locked tab (Auto Layout editing) is refused")
eq(GUI.SelectedMode, "party", "under: ...and nothing moved")
GUI:SetModuleLocked("group", false, "raid")
local ended
DF.MoverBridge = {
    IsSessionActive = function() return true end,
    EndSessionThen = function(_, fn) ended = fn end,
}
check(not GUI:SetUnderlyingFrameMode("raid"), "under: a running mover session is ended first")
check(type(ended) == "function", "under: ...and the switch replayed after it")
DF.MoverBridge = nil

-- ---- the page set: order and membership ---------------------------------------
print("-- Profiles pages: order and sidebar")
local made, cats, built = {}, {}, {}
local pageDF = { GUI = { InvalidatePage = function() end }, L = DF.L, ChangedSettings = { PAGE_ID = "profiles_changed" } }
DandersFrames = pageDF
load_options_file_into("GUI/Pages/Profiles.lua", NS)
check(type(pageDF.SetupProfilesPages) == "function", "setup: DF:SetupProfilesPages exists")
if pageDF.SetupProfilesPages then
    pageDF:SetupProfilesPages(pageDF.GUI,
        function(name) cats[#cats + 1] = name end,
        function(cat, id) made[#made + 1] = { cat = cat, id = id }; return { tabName = id } end,
        function(page, fn) built[#built + 1] = page.tabName; check(type(fn) == "function", "setup: " .. page.tabName .. " has a builder") end)
end
eq(table.concat(cats, ","), "profiles", "setup: one category, Profiles")
local ids = {}
for i, m in ipairs(made) do
    ids[i] = m.id
    eq(m.cat, "profiles", "setup: " .. m.id .. " is in the Profiles category")
    check(GUI.IsProfilesPage(m.id), "setup: " .. m.id .. " is a Profiles page (so it is mode-neutral)")
end
eq(table.concat(ids, ","),
   "profiles_manage,profiles_spec,profiles_auto,profiles_clickcast,profiles_importexport,profiles_changed",
   "order: Manage, Spec & Character, Auto Layouts, Click Casting, Import / Export, Changed Settings")
eq(#built, 6, "setup: every page gets a builder")
local n = 0
for _ in pairs(GUI.ProfilesPages) do n = n + 1 end
eq(n, 6, "setup: and the sidebar set names exactly those six")
DandersFrames = DF

local MODULES = options_file_source("GUI/Pages/Modules.lua"):gsub("\r\n", "\n")
check(MODULES:find('CreateSubTab("profiles"', 1, true) == nil,
      "setup: Modules.lua no longer builds a Profiles page itself")
check(MODULES:find("DF:SetupProfilesPages(GUI, CreateCategory, CreateSubTab, BuildPage)", 1, true) ~= nil,
      "setup: ...it calls the setup where the category used to be")
local OPTIONS = options_file_source("GUI/Pages/Options.lua"):gsub("\r\n", "\n")
local order = OPTIONS:match("GUI%.CategoryOrder = (%b{})") or ""
check(not order:find('"clickcast"', 1, true), "order: the never-created clickcast category is gone")
check(order:find('"profiles"', 1, true) ~= nil, "order: profiles stays (its sidebar is filtered by the view)")

-- ---- mode-neutral builds -------------------------------------------------------------
print("-- Profiles pages: one build whatever mode is underneath")
local PANEL = options_file_source("GUI/Panel.lua"):gsub("\r\n", "\n")
local bp = between(PANEL, "    local function BuildPage(page, builderFunc)", "    -- Trash frame: detached") or ""
check(bp:find("if page and GUI.IsProfilesPage and GUI.IsProfilesPage(page.tabName) then page.modeNeutral = true end", 1, true) ~= nil,
      "neutral: BuildPage marks a Profiles page mode-neutral")
check(bp:find('if self.modeNeutral then return "_neutral" end', 1, true) ~= nil
      and bp:find("if self.modeNeutral then return DF.db and DF.db.party end", 1, true) ~= nil,
      "neutral: its builds are keyed on a fixed name and bound to the party table")
local _, rawModeReads = bp:gsub("DF%.db%[GUI%.SelectedMode%]", "")
eq(rawModeReads, 1, "neutral: the only raw mode-table read left is PageDb's own")
local SW = options_file_source("GUI/SettingsWidgets.lua"):gsub("\r\n", "\n")
check(SW:find('if tabName == "profiles_auto" then\n            return DF.db ~= nil and DF.db.raidEnabled == false', 1, true) ~= nil,
      "neutral: Auto Layouts greys with Raid alone; the other Profiles pages never grey")
local AUTOP = options_file_source("GUI/Pages/AutoProfiles.lua"):gsub("\r\n", "\n")
local bpAuto = between(AUTOP, "function AutoProfilesUI:BuildPage(", "-- Enable Checkbox") or ""
check(bpAuto ~= "" and not bpAuto:find("SelectedMode", 1, true),
      "neutral: the Auto Layouts page no longer reads the mode underneath")
check(AUTOP:find('GUI:SetModuleLocked("profiles", editing)', 1, true) ~= nil,
      "editing: Profiles is locked while an auto layout is being edited")
local APCORE = df_file_source("Core/AutoProfiles.lua"):gsub("\r\n", "\n")
local enter = between(APCORE, "function AutoProfilesUI:EnterEditing(", "-- Clear overlay so snapshot captures true globals") or ""
check(enter:find('GUI:SelectModule("group", "raid")', 1, true) ~= nil,
      "editing: Edit steps onto Raid before anything is written")
local RAIL = options_file_source("GUI/Rail.lua"):gsub("\r\n", "\n")
check(RAIL:find('elseif id == "profiles" then', 1, true) ~= nil,
      "reopen: the window comes back to Profiles")
local HOME = options_file_source("GUI/Pages/Home.lua"):gsub("\r\n", "\n")
check(HOME:find('GUI:SelectModule("profiles", "profiles_manage")', 1, true) ~= nil,
      "links: Home's profile link opens Profiles > Manage")
local MAIN = options_file_source("ClickCasting/UI/Main.lua"):gsub("\r\n", "\n")
check(MAIN:find('DF.GUI.SelectTab("profiles_clickcast")', 1, true) ~= nil,
      "links: Binds' Profiles tab and cog open Profiles > Click Casting")

-- ============================================================
-- RENAME (DF:RenameProfile, lifted out of Core/Profile.lua)
-- ============================================================
print("-- Rename: success, refusals, the current profile and spec assignments")
local PROFILE = df_file_source("Core/Profile.lua"):gsub("\r\n", "\n")
local fnSrc = PROFILE:match("(function DF:RenameProfile%(oldName, newName%).-\nend\n)")
check(fnSrc ~= nil, "rename: DF:RenameProfile is in Core/Profile.lua")
local RDF = { L = DF.L, GUI = {} }
local said, errs, chip = {}, {}, 0
function RDF:Say(m) said[#said + 1] = m end
function RDF:Err(m) errs[#errs + 1] = m end
RDF.GUI.UpdateProfileChip = function() chip = chip + 1 end
if fnSrc then
    assert(loadstring("local DF, format = ...\n" .. fnSrc))(RDF, string.format)
end
local function fresh()
    DandersFramesDB_v2 = { currentProfile = "Main",
        profiles = { Default = { d = 1 }, Main = { m = 1 }, Alt = { a = 1 } } }
    DandersFramesCharDB = { currentProfile = "Main", specProfiles = { [1] = "Main", [2] = "Alt", [3] = "Main" } }
    said, errs, chip = {}, {}, 0
end

if RDF.RenameProfile then
    fresh()
    local mainTable = DandersFramesDB_v2.profiles.Main
    check(RDF:RenameProfile("Main", "Raiding"), "rename: the current profile renames")
    check(DandersFramesDB_v2.profiles.Raiding == mainTable, "rename: ...the same table, under the new name")
    eq(DandersFramesDB_v2.profiles.Main, nil, "rename: ...and the old name is gone")
    eq(DandersFramesDB_v2.currentProfile, "Raiding", "rename: the account's current profile follows")
    eq(DandersFramesCharDB.currentProfile, "Raiding", "rename: ...and this character's")
    eq(DandersFramesCharDB.specProfiles[1], "Raiding", "rename: spec 1, which named it, follows")
    eq(DandersFramesCharDB.specProfiles[3], "Raiding", "rename: ...and spec 3")
    eq(DandersFramesCharDB.specProfiles[2], "Alt", "rename: a spec on another profile is left alone")
    eq(chip, 1, "rename: the title-bar chip is repainted")
    eq(#said, 1, "rename: chat says so once")

    fresh()
    check(RDF:RenameProfile("Alt", "  Spaced  "), "rename: a profile that is not current renames too")
    check(DandersFramesDB_v2.profiles.Spaced ~= nil, "rename: ...with the name trimmed")
    eq(DandersFramesDB_v2.currentProfile, "Main", "rename: ...leaving the current profile as it was")
    eq(DandersFramesCharDB.specProfiles[2], "Spaced", "rename: ...but its spec assignment follows")

    for _, case in ipairs({
        { "Main", "Alt", "exists", "a duplicate name" },
        { "Main", "Default", "exists", "Default as the new name" },
        { "Main", "", "empty", "an empty name" },
        { "Main", "   ", "empty", "a blank name" },
        { "Main", nil, "empty", "no name" },
        { "Default", "Other", "default", "renaming Default" },
        { "Nope", "Other", "missing", "a profile that does not exist" },
    }) do
        fresh()
        local before = DandersFramesDB_v2.profiles.Main
        local ok, why = RDF:RenameProfile(case[1], case[2])
        check(not ok, "refuse: " .. case[4])
        eq(why, case[3], "refuse: " .. case[4] .. " says why")
        check(DandersFramesDB_v2.profiles.Main == before and DandersFramesDB_v2.currentProfile == "Main"
              and DandersFramesCharDB.specProfiles[1] == "Main",
              "refuse: " .. case[4] .. " changes nothing")
    end

    fresh()
    check(RDF:RenameProfile("Main", "Main"), "rename: to its own name is a quiet success")
    eq(#said, 0, "rename: ...that says nothing")

    fresh()
    RDF.AutoProfilesUI = { globalSnapshotOwner = "Main" }
    RDF:RenameProfile("Main", "Raiding")
    eq(RDF.AutoProfilesUI.globalSnapshotOwner, "Raiding",
       "rename: an auto layout being edited still knows whose snapshot it holds")
    RDF.AutoProfilesUI = nil

    fresh()
    DandersFramesCharDB = nil
    check(RDF:RenameProfile("Main", "Raiding"), "rename: no character table is not an error")
end

-- The other characters: verified, not changed. Their names are handled where
-- they are read (Core.lua's login pass and the spec auto-switch).
local CORE = df_file_source("Core.lua"):gsub("\r\n", "\n")
check(CORE:find('if not DandersFramesDB_v2.profiles[currentProfile] then\n            currentProfile = "Default"', 1, true) ~= nil,
      "others: a character whose profile was renamed away logs in on Default")
check(PROFILE:find("if exists then", 1, true) ~= nil and PROFILE:find("function DF:CheckProfileAutoSwitch()", 1, true) ~= nil,
      "others: ...and its spec auto-switch skips a profile that no longer exists")

DandersFrames = savedDF
DandersFramesDB_v2, DandersFramesCharDB = savedSV, savedChar
