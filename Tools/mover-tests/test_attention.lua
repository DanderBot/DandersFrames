local NS = ...

-- ============================================================
-- NEEDS ATTENTION
-- The resident registry (DandersFrames/Features/Attention.lua): register,
-- order, severity sort, dismissals (session / version / forever), the combat
-- cache, a failing check; every v1 check against stubs, on and off; and the
-- Home side (GUI/Pages/Home.lua + GUI/Rail.lua): rows drawn from the list,
-- fix buttons greyed in combat, the dismiss "x", the rail badge count and
-- Q3's open-on-Home rule.
-- ============================================================

local saved = {
    DF = DandersFrames, SV = DandersFramesDB_v2, CharDB = DandersFramesCharDB,
    CreateFrame = CreateFrame, C_Timer = C_Timer, LibStub = LibStub, ReloadUI = ReloadUI,
}

local events = {}
-- ⚠ Without FakeUIFrame's catch-all: Home tests `if r.Fix then` on its rows,
-- and the catch-all answers every unset key with a (truthy) function.
CreateFrame = function()
    local f = setmetatable(FakeUIFrame(), nil)
    f.RegisterEvent = function(self, e) events[e] = self end
    f.UnregisterEvent = function() end
    return f
end
C_Timer = { After = function(_, fn) fn() end }
local reloads = 0
ReloadUI = function() reloads = reloads + 1 end
local moverLib = nil
LibStub = setmetatable({}, { __call = function(_, name) if name == "DandersMover-1.0" then return moverLib end end })
DandersFramesDB_v2 = {}
DandersFramesCharDB = {}
IN_COMBAT = false

local GUI = {
    SelectedMode = "party",
    GlobalView = false,
    Colors = {
        text = { r = 1, g = 1, b = 1 }, textDim = { r = 0.6, g = 0.6, b = 0.6 },
        textCaption = { r = 0.7, g = 0.7, b = 0.7 },
        panel = { r = 0.1, g = 0.1, b = 0.1 }, border = { r = 0.3, g = 0.3, b = 0.3 },
    },
}
function GUI.IsGlobalPage() return false end
local DF = { GUI = GUI, VERSION = "5.7.0" }
DF.L = setmetatable({}, { __index = function(_, k) return k end })
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
DandersFrames = DF

-- Everything quiet: every v1 check reads "nothing wrong".
local function Quiet()
    DF.db = {
        partyEnabled = true, raidEnabled = true,
        party = { hideBlizzardPartyFrames = true, hideBlizzardRaidFrames = true, locked = true },
        raid = { hideBlizzardPartyFrames = true, hideBlizzardRaidFrames = true, raidLocked = true },
    }
end
Quiet()

load_df_file_into("Features/Attention.lua", DF)
local A = DF.Attention
check(A and A.Register and A.GetActive and A.Dismiss and A.Count, "api: DF.Attention is published")
A:SnapshotLoaded()

local function ids(list)
    local out = {}
    for i, item in ipairs(list) do out[i] = item.id end
    return table.concat(out, ",")
end
local function find(id)
    for _, item in ipairs(A:GetActive()) do
        if item.id == id then return item end
    end
end

print("-- Attention: the registry")
eq(#A:GetActive(), 0, "baseline: nothing active when everything is quiet")

local on = {}
A:Register{ id = "t_info", severity = 3, check = function() return on.info end, title = "Info" }
A:Register{ id = "t_conflict", severity = 1, check = function() return on.conflict end, title = "Conflict",
            dismiss = "session" }
A:Register{ id = "t_setup", severity = 2, check = function() return on.setup end, title = "Setup",
            dismiss = "forever" }
A:Register{ id = "t_info2", severity = 3, check = function() return on.info2, "x", 7 end,
            title = function(s, n) return s .. n end,
            detail = function(_, n) return "n=" .. n end,
            fix = function(s) return { label = "Fix " .. s, run = function() on.fixed = true end } end,
            dismiss = "version" }
A:Register{ id = "t_boom", severity = 1, check = function() if on.boom then error("boom") end end }
A:Register{ id = "t_badfix", severity = 3, check = function() return on.badfix end,
            title = function() error("title boom") end }

on.info, on.conflict, on.setup, on.info2 = true, true, true, true
local list = A:GetActive()
eq(ids(list), "t_conflict,t_setup,t_info,t_info2", "sort: by severity, then registration order")
eq(list[4].title, "x7", "args: a check's extra returns reach title()")
eq(list[4].detail, "n=7", "args: ...and detail()")
eq(list[4].fix and list[4].fix.label, "Fix x", "args: ...and a fix built by a function")
eq(list[4].fix.combatSafe, false, "fix: combatSafe defaults to false")
eq(list[1].dismiss, "session", "item: carries its dismiss mode for the view")
eq(A:Count(), 4, "count: every active item")
eq(A:Count(2), 2, "count: severity 1-2 only")

on.boom = true
eq(ids(A:GetActive()), "t_conflict,t_setup,t_info,t_info2", "pcall: a check that errors is skipped, nothing else lost")
on.boom = nil
on.badfix = true
eq(ids(A:GetActive()), "t_conflict,t_setup,t_info,t_info2", "pcall: an item whose title errors is skipped")
on.badfix = nil

A:Register{ id = "t_info", severity = 3, check = function() return on.info end, title = "Info again" }
list = A:GetActive()
eq(ids(list), "t_conflict,t_setup,t_info,t_info2", "re-register: replaces in place, keeps its order")
eq(list[3].title, "Info again", "re-register: ...with the new definition")

print("-- Attention: dismissals")
check(A:Dismiss("t_info") == false, "dismiss: an item with no dismiss mode cannot be dismissed")
check(A:Dismiss("t_conflict") == true, "dismiss: session")
eq(ids(A:GetActive()), "t_setup,t_info,t_info2", "dismiss: session hides it")
eq(DandersFramesDB_v2.attentionDismissed and DandersFramesDB_v2.attentionDismissed.t_conflict, nil,
   "dismiss: session is never stored")
A:Dismiss("t_setup")
eq(DandersFramesDB_v2.attentionDismissed.t_setup, true, "dismiss: forever stores true")
A:Dismiss("t_info2")
eq(DandersFramesDB_v2.attentionDismissed.t_info2, "5.7.0", "dismiss: version stores the running version")
eq(ids(A:GetActive()), "t_info", "dismiss: all three hidden")
DF.VERSION = "5.7.1"
eq(ids(A:GetActive()), "t_info,t_info2", "dismiss: a version dismissal comes back after an update")
check(find("t_setup") == nil, "dismiss: ...a forever one does not")
DF.VERSION = "5.7.0"
A:ResetDismissals()
eq(ids(A:GetActive()), "t_conflict,t_setup,t_info,t_info2", "dismiss: ResetDismissals forgets them all")

print("-- Attention: combat")
list = A:GetActive()
IN_COMBAT = true
on.info, on.conflict = false, false
eq(ids(A:GetActive()), "t_conflict,t_setup,t_info,t_info2", "combat: the last list, no checks run")
A:Dismiss("t_setup")
eq(ids(A:GetActive()), "t_conflict,t_info,t_info2", "combat: a dismiss still drops it from the cached list")
IN_COMBAT = false
eq(ids(A:GetActive()), "t_info2", "combat over: evaluated again")
eq(ids(A:GetActive(true)), "t_info2", "useCache: the last list")
on.info = true
eq(ids(A:GetActive(true)), "t_info2", "useCache: ...even when a check would now answer differently")
eq(A:Count(nil, true), 1, "count: cachedOnly never evaluates")
on.info, on.conflict, on.setup, on.info2 = nil, nil, nil, nil
A:ResetDismissals()
eq(#A:GetActive(), 0, "quiet again")

-- ---- the v1 checks ----------------------------------------------------------
print("-- Attention: Blizzard frames not hidden")
DF.db.party.hideBlizzardPartyFrames = false
DF.db.raid.hideBlizzardPartyFrames = false
local item = find("blizzardFrames")
check(item ~= nil, "blizzard: party enabled + Blizzard party not hidden is active")
eq(item and item.severity, 1, "blizzard: severity 1 (a conflict)")
eq(item and item.title, "Blizzard party frames are still showing", "blizzard: says which")
eq(item and item.dismiss, "forever", "blizzard: someone who wants both can dismiss it for good")
DF.db.raid.hideBlizzardRaidFrames = false
eq(find("blizzardFrames").title, "Blizzard party and raid frames are still showing", "blizzard: both")
DF.db.partyEnabled, DF.db.raidEnabled = false, false
check(find("blizzardFrames") == nil, "blizzard: DF modes off -- Blizzard's frames are wanted")
DF.db.partyEnabled, DF.db.raidEnabled = true, true
reloads = 0
find("blizzardFrames").fix.run()
check(DF.db.party.hideBlizzardPartyFrames and DF.db.raid.hideBlizzardPartyFrames
      and DF.db.party.hideBlizzardRaidFrames and DF.db.raid.hideBlizzardRaidFrames,
      "blizzard fix: sets both keys in both modes, as the existing prompt does")
eq(reloads, 1, "blizzard fix: then reloads")
check(find("blizzardFrames") == nil, "blizzard: inactive once hidden")

print("-- Attention: reload needed")
A:SnapshotLoaded()
check(find("reloadNeeded") == nil, "reload: nothing differs from the load")
DF.EnableFlagsDifferFromLoaded = function() return true end
check(find("reloadNeeded") ~= nil, "reload: party/raid enable changed")
eq(find("reloadNeeded").severity, 2, "reload: severity 2")
DF.EnableFlagsDifferFromLoaded = nil
DF.db.raid.hideBlizzardRaidFrames = false
check(find("reloadNeeded") ~= nil, "reload: a Blizzard-hide setting changed since load")
DF.db.raid.hideBlizzardRaidFrames = true
DandersFramesCharDB.languageOverride = "AUTO"
check(find("reloadNeeded") == nil, "reload: AUTO and unset are the same language")
DandersFramesCharDB.languageOverride = "deDE"
check(find("reloadNeeded") ~= nil, "reload: the language override changed")
DandersFramesCharDB.languageOverride = nil
DF.ClickCast = { db = { enabled = false } }
check(events.PLAYER_ENTERING_WORLD ~= nil, "reload: listens for the first PLAYER_ENTERING_WORLD")
events.PLAYER_ENTERING_WORLD:GetScript("OnEvent")(events.PLAYER_ENTERING_WORLD, "PLAYER_ENTERING_WORLD", true, false)
eq(A._loaded.clickCast, false, "reload: click-cast's flag is snapshotted once it has initialised")
DF.ClickCast.db.enabled = true
check(find("reloadNeeded") ~= nil, "reload: click-casting switched since load")
reloads = 0
find("reloadNeeded").fix.run()
eq(reloads, 1, "reload fix: reloads")
DF.ClickCast.db.enabled = false
check(find("reloadNeeded") == nil, "reload: back as loaded, inactive")

print("-- Attention: click-cast conflict")
local popups = {}
DF.ClickCast = {
    db = { enabled = true }, hasConflictingAddons = true, conflictingAddons = { "Clique" },
    ShowClickCastConflictPopup = function(self, c) popups[#popups + 1] = c end,
}
A:SnapshotClickCast()
item = find("clickCastConflict")
check(item ~= nil, "conflict: click-casting on with Clique loaded")
eq(item and item.severity, 1, "conflict: severity 1")
eq(item and item.title, "Click-casting conflicts with Clique", "conflict: names the addon")
item.fix.run()
eq(popups[1] and popups[1][1], "Clique", "conflict fix: the existing conflict popup")
DF.ClickCast.db.ignoreConflictWarning = true
check(find("clickCastConflict") == nil, "conflict: 'don't warn me again' means they chose to run both")
DF.ClickCast.db.ignoreConflictWarning = nil
DF.ClickCast.db.enabled = false
check(find("clickCastConflict") == nil, "conflict: ours off, no conflict")
DF.ClickCast = nil

print("-- Attention: frames unlocked / test mode")
local calls = {}
DF.LockFrames = function() calls[#calls + 1] = "party" end
DF.LockRaidFrames = function() calls[#calls + 1] = "raid" end
DF.db.party.locked = false
item = find("framesUnlocked")
check(item ~= nil, "unlocked: party lock flag off")
eq(item and item.severity, 2, "unlocked: severity 2")
DF.db.raid.raidLocked = false
find("framesUnlocked").fix.run()
eq(table.concat(calls, ","), "party,raid", "unlocked fix: locks each scope that is unlocked")
DF.db.party.locked, DF.db.raid.raidLocked = true, true
check(find("framesUnlocked") == nil, "unlocked: locked again, inactive")
DF.MoverBridge = { IsSessionActive = function() return true end }
check(find("framesUnlocked") ~= nil, "unlocked: an open mover session")
calls = {}
find("framesUnlocked").fix.run()
eq(table.concat(calls, ","), "party", "unlocked fix: a session is ended once (it restores both)")
DF.MoverBridge = nil

local owners = { party = {}, raid = {} }
DF.IsTestModeOwnedBy = function(_, s, o) return owners[s][o] and true or false end
DF.SetTestModeOwner = function(_, s, o, v) owners[s][o] = v or nil end
owners.party.unlock = true
check(find("testModeOn") == nil, "test mode: unlock's own claim is not the user leaving it on")
owners.raid.user = true
item = find("testModeOn")
check(item ~= nil, "test mode: the user's claim")
eq(item and item.severity, 2, "test mode: severity 2")
item.fix.run()
check(owners.raid.user == nil and owners.party.unlock == true, "test mode fix: releases the user's claim only")
check(find("testModeOn") == nil, "test mode: off, inactive")

print("-- Attention: Auto Layout overriding settings")
DF.AutoProfilesUI = {
    activeRuntimeProfile = { name = "Mythic", overrides = { a = 1 } },
    _priv = { CountDisplayedOverrides = function(o) return o and o.a and 5 or 0 end },
}
item = find("autoLayoutActive")
check(item ~= nil, "auto layout: a layout is driving the raid frames")
eq(item and item.severity, 3, "auto layout: info")
eq(item and item.title, "Auto Layout \"Mythic\" is active", "auto layout: names it")
eq(item and item.detail, "It is changing 5 settings on your raid frames.", "auto layout: counts the overrides")
eq(item and item.fix and item.fix.page, "profiles_auto", "auto layout fix: opens Auto Layouts")
DF.AutoProfilesUI.activeRuntimeProfile.overrides = {}
check(find("autoLayoutActive") == nil, "auto layout: no overrides, nothing to say")
DF.AutoProfilesUI.activeRuntimeProfile = nil
check(find("autoLayoutActive") == nil, "auto layout: none active")
DF.AutoProfilesUI = nil

print("-- Attention: newer version seen")
local globalDb = { notifyOutdated = true }
DF.GetGlobalDB = function() return globalDb end
DF.VersionCheck = { newestSeen = { version = "5.8.0", from = "Someone" } }
item = find("newerVersion")
check(item ~= nil, "version: a newer one was seen")
eq(item and item.fix, nil, "version: info only, no fix button")
eq(item and item.dismiss, "version", "version: dismissed per version")
A:Dismiss("newerVersion")
eq(DandersFramesDB_v2.attentionDismissed.newerVersion, "5.8.0", "version: the dismissal is for the version seen")
check(find("newerVersion") == nil, "version: dismissed")
DF.VersionCheck.newestSeen = { version = "5.9.0" }
check(find("newerVersion") ~= nil, "version: a still newer one comes back")
globalDb.notifyOutdated = false
check(find("newerVersion") == nil, "version: respects 'notify when outdated'")
DF.VersionCheck = nil
A:ResetDismissals()
local VCSRC = df_file_source("Features/VersionCheck.lua")
check(VCSRC:find("self.newestSeen = { version = payload, from = sender }", 1, true) ~= nil,
      "version: the V handler records the newest version seen")

print("-- Attention: debug logging")
DandersFramesDB_v2.debug = { enabled = true }
item = find("debugLogging")
check(item ~= nil, "debug: logging on")
eq(item and item.fix and item.fix.combatSafe, true, "debug fix: safe in combat (it only writes flags)")
DF.DebugConsole = { SetEnabled = function(_, v) DandersFramesDB_v2.debug.enabled = v end }
item.fix.run()
check(find("debugLogging") == nil, "debug fix: turned off")
DandersFramesDB_v2.profilerOnUpdateHook = true
check(find("debugLogging") ~= nil, "debug: the profiler hook left on")
find("debugLogging").fix.run()
check(DandersFramesDB_v2.profilerOnUpdateHook == nil and find("debugLogging") == nil, "debug fix: hook off too")
DF.DebugConsole = nil

print("-- Attention: DandersMover missing")
check(find("moverMissing") == nil, "mover: not raised before an unlock was tried")
DF.unlockWithoutMover = true
item = find("moverMissing")
check(item ~= nil, "mover: unlock tried and the library is missing")
eq(item and item.fix, nil, "mover: info, says how in the text")
moverLib = {}
check(find("moverMissing") == nil, "mover: present, inactive")
moverLib = nil
DF.unlockWithoutMover = nil
local POS = df_file_source("Frames/Position.lua")
local INIT = df_file_source("Frames/Init.lua")
check(POS:find("DF.unlockWithoutMover = true", 1, true) ~= nil and INIT:find("DF.unlockWithoutMover = true", 1, true) ~= nil,
      "mover: both unlock paths record the attempt")

print("-- Attention: missing textures")
DF.GetMissingTextures = function() return { "a", "b" } end
item = find("missingTextures")
check(item ~= nil, "textures: some are missing")
check(item and item.detail:find("^2 texture files") ~= nil, "textures: counts them")
DF.GetMissingTextures = function() return {} end
check(find("missingTextures") == nil, "textures: none, inactive")
DF.GetMissingTextures = nil
local CORE = df_file_source("Core.lua")
check(CORE:find("function DF:GetMissingTextures()", 1, true) ~= nil
      and CORE:find("_df_missingTextures[path] = true", 1, true) ~= nil,
      "textures: Core exposes the paths its warning reported")
check(CORE:find("DF.Attention:SnapshotLoaded()", 1, true) ~= nil, "reload: Core snapshots at the load point")
local TOC = df_file_source("DandersFrames.toc")
local ia, ib = TOC:find("Features\\Attention.lua", 1, true), TOC:find("ClickCasting\\Events.lua", 1, true)
check(ia and ib and ia > ib, "toc: Attention.lua is resident, after the systems it reads")

eq(#A:GetActive(), 0, "quiet again")

-- ---- Home -----------------------------------------------------------------
print("-- Attention: Home rows, combat, dismiss, badge, Q3")
function GUI:StyleButton(b) b.Text = FakeUIFrame() end
function GUI:CreateCloseButton(parent, opts)
    local b = FakeUIFrame()
    b._opts = opts
    b:SetScript("OnClick", function(self) if opts.onClick then opts.onClick(self) end end)
    return b
end
load_options_file_into("GUI/ModuleRegistry.lua", NS)
load_options_file_into("GUI/Pages/Home.lua", NS)
load_options_file_into("GUI/Rail.lua", NS)
local Home = GUI.Home
check(Home and Home.LayoutAttention and GUI.EvaluateAttention and Home.BadgeCount, "home: api")

local badges = {}
GUI.ModuleRail = {
    GetItemIds = function() return { "home", "group", "modules" } end,
    SetBadge = function(_, id, text) badges[id] = text end,
}

-- One of each severity: Blizzard (1, dismissable), test mode (2), debug (3, combat-safe fix).
DF.db.party.hideBlizzardPartyFrames = false
owners.party.user = true
DandersFramesDB_v2.debug = { enabled = true }
A:SnapshotLoaded()   -- as loaded: no reload pending on top
GUI:EvaluateAttention()
eq(badges.home, "2", "badge: the Home item counts severity 1-2 items")
eq(badges.group, nil, "badge: other items keep their own (none)")
eq(GUI:ModuleToOpen("group", false), "home", "Q3: a severity-1 item opens the window on Home")

local p = FakeUIFrame()
p.Title, p.Aside, p.rows = FakeUIFrame(), FakeUIFrame(), {}
local h = Home.LayoutAttention(p, 400)
check(h > 0, "rows: laid out")
eq(p.Aside:GetText(), "3", "rows: the panel's count")
local r1, r2, r3 = p.rows[1], p.rows[2], p.rows[3]
eq(r1.TitleFS:GetText(), "Blizzard party frames are still showing", "rows: sorted, conflict first")
eq(r3.TitleFS:GetText(), "Debug logging is on", "rows: info last")
check(r1.Fix and r1.Fix:IsShown() and r1.Fix:IsEnabled(), "rows: a fix button, enabled out of combat")
eq(r1.Fix.Text:GetText(), "Hide and Reload", "rows: labelled")
check(r1.Dismiss and r1.Dismiss:IsShown(), "rows: a dismiss x on a dismissable item")

IN_COMBAT = true
Home.LayoutAttention(p, 400)
check(not r1.Fix:IsEnabled(), "combat: a fix that is not combat-safe is greyed")
check(r3.Fix:IsEnabled(), "combat: a combat-safe one is not")
reloads = 0
r1.Fix:GetScript("OnClick")(r1.Fix)
eq(reloads, 0, "combat: clicking a greyed fix does nothing")
IN_COMBAT = false

r1.Dismiss:GetScript("OnClick")(r1.Dismiss)
eq(badges.home, "1", "dismiss: re-evaluated, the badge drops")
check(GUI:ModuleToOpen("group", false) ~= "home", "Q3: no conflict left, the window opens where it was")
Home.LayoutAttention(p, 400)
eq(p.rows[1].TitleFS:GetText(), "Test mode is on", "dismiss: the row is gone")

p.rows[1].Fix:GetScript("OnClick")(p.rows[1].Fix)
check(owners.party.user == nil, "fix: the click ran the fix")
eq(badges.home, nil, "fix: re-evaluated, no severity 1-2 left, no badge")

DandersFramesDB_v2.debug = nil
A:ResetDismissals()
DF.db.party.hideBlizzardPartyFrames = true
A:SnapshotLoaded()
GUI:EvaluateAttention()
Home.LayoutAttention(p, 400)
eq(p.rows[1].TitleFS:GetText(), "All good. Nothing needs your attention.", "empty: the one-line All good")
check(not (p.rows[1].Fix and p.rows[1].Fix:IsShown()) and not (p.rows[1].Dismiss and p.rows[1].Dismiss:IsShown()),
      "empty: no buttons")

-- ---- restore ----------------------------------------------------------------
IN_COMBAT = false
DandersFrames = saved.DF
DandersFramesDB_v2 = saved.SV
DandersFramesCharDB = saved.CharDB
CreateFrame = saved.CreateFrame
C_Timer = saved.C_Timer
LibStub = saved.LibStub
ReloadUI = saved.ReloadUI
