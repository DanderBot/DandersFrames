local NS = ...

-- ============================================================
-- THE SETTINGS MODULE REGISTRY
-- DandersFrames_Options/GUI/ModuleRegistry.lua
-- ------------------------------------------------------------
-- The real file is loaded over a stub GUI/DF; the built-in modules' switch
-- bodies run against recorders, so what is checked is the order things happen
-- in, not that a frame moved.
-- ============================================================

local savedDF = DandersFrames

local calls
local function rec(name) return function() calls[#calls + 1] = name end end

local GUI = {
    SelectedMode = "party",
    GlobalView = false,
    GlobalAccent = { r = 0.25 },
    GlobalPages = { general_settings = true },
}
function GUI.IsGlobalPage(name) return GUI.GlobalPages[name] == true end
function GUI.GetThemeColorFor(isRaid) return isRaid and "RAID" or "PARTY" end
function GUI:SetAccent(c) calls[#calls + 1] = "accent:" .. tostring(c) end
function GUI.UpdateThemeColors() calls[#calls + 1] = "theme" end
function GUI:ShowNormalContent() calls[#calls + 1] = "normal" end
function GUI:ShowClickCastingContent() calls[#calls + 1] = "clickcontent" end
function GUI:UpdateTabAvailability() calls[#calls + 1] = "avail" end
function GUI:RefreshCurrentPageForModeSwitch() calls[#calls + 1] = "refresh" end
function GUI:LastTabInView() return GUI.GlobalView and "general_settings" or "general_frame" end
function GUI:EnterView(g)
    calls[#calls + 1] = "view:" .. tostring(g)
    if GUI.SelectedMode == "clicks" then GUI.SelectedMode = GUI._lastFrameMode or "party" end
    GUI.GlobalView = g and true or false
end
GUI.SelectTab = function(n) calls[#calls + 1] = "tab:" .. tostring(n) end

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
function DF:LockRaidFrames() calls[#calls + 1] = "lockraid"; raidDb.raidLocked = true end
function DF:HideTestFrames() calls[#calls + 1] = "hidepartytest"; DF.testMode = false end
function DF:HideRaidTestFrames() calls[#calls + 1] = "hideraidtest"; DF.raidTestMode = false end
function DF:ClearTestModeOwners(s) calls[#calls + 1] = "clear:" .. s end
function DF:SetTestModeOwner(s) calls[#calls + 1] = "own:" .. s end
function DF:TeardownTestModeEngines() calls[#calls + 1] = "teardown" end
DF.Search = {
    InvalidateRegistry = function() calls[#calls + 1] = "invalidate" end,
    RefreshIfActive = function() end,
    HideResults = function() calls[#calls + 1] = "hideresults" end,
}
DandersFrames = DF

calls = {}
load_options_file_into("GUI/ModuleRegistry.lua", NS)

local function joined() return table.concat(calls, ",") end

-- ---- register / order / get -----------------------------------------
print("-- Module registry: register, order, get")
check(GUI.RegisterModule and GUI.SelectModule and GUI.GetModule and GUI.GetModules
      and GUI.SetModuleLocked and GUI.IsModuleLocked, "api: the registry API is on GUI")
local ids = {}
for _, def in ipairs(GUI:GetModules()) do ids[#ids + 1] = def.id end
eq(table.concat(ids, ","), "group,clicks,global", "order: the three built-ins, top slot first, global at the bottom")
eq(GUI.SelectedModule, "group", "state: the window starts on Group Frames")
eq(GUI:GetModule().id, "group", "get: no id is the module showing")
eq(GUI:GetModule("clicks").id, "clicks", "get: ...and an id is that module")
eq(GUI:ModuleLabel(GUI:GetModule("group")), "Group Frames", "label: resolved through L at call time")
eq(#GUI:GetModule("group").tabs, 2, "tabs: Group Frames carries Party and Raid")
eq(GUI:ModuleForPage("general_settings"), "global", "page: a GLOBAL page is Global's")
eq(GUI:ModuleForPage("general_frame"), "group", "page: ...anything else Group Frames'")

GUI:RegisterModule({ id = "zz_test", order = 5, slot = "top" })
GUI:RegisterModule({ id = "zz_bottom", order = 1, slot = "bottom" })
ids = {}
for _, def in ipairs(GUI:GetModules()) do ids[#ids + 1] = def.id end
eq(table.concat(ids, ","), "zz_test,group,clicks,zz_bottom,global", "order: by slot, then order")
GUI:RegisterModule({ id = "zz_test", order = 50 })
ids = {}
for _, def in ipairs(GUI:GetModules()) do ids[#ids + 1] = def.id end
eq(table.concat(ids, ","), "group,clicks,zz_test,zz_bottom,global", "register: re-registering an id replaces it, not duplicates it")
calls = {}
check(GUI:RegisterModule({}) == nil and joined() == "error", "register: no id is refused, loudly in debug")
calls = {}
check(GUI:SelectModule("nope") == false and joined() == "warn", "select: an unknown id does nothing")

-- ---- select: Party <-> Raid -----------------------------------------
print("-- Module registry: Party <-> Raid through group.onEnter")
calls = {}
GUI.SelectedMode = "party"; partyDb.locked = false; DF.testMode = true
GUI:SelectModule("group", "raid")
eq(GUI.SelectedMode, "raid", "raid: the mode moved")
check(partyDb.locked == true, "raid: the departing party frames were locked")
eq(joined(), "sync,lockparty,hidepartytest,clear:party,accent:RAID,invalidate,theme,normal,avail,refresh,own:raid,teardown",
   "raid: sync, lock + hand test mode over, new accent and index, refresh, re-claim test mode")
check(GUI._holdPageRepaint == nil and DF._testModeHandover == nil, "raid: the hold and the hand-over are both released")

calls = {}
raidDb.raidLocked = false; DF.raidTestMode = true
GUI:SelectModule("group", "party")
eq(GUI.SelectedMode, "party", "party: the mode moved back")
eq(joined(), "sync,lockraid,hideraidtest,clear:raid,accent:PARTY,invalidate,theme,normal,avail,refresh,own:party,teardown",
   "party: the mirror image, LockRaidFrames owning the raid lock")

calls = {}
GUI:SelectModule("group")
eq(joined(), "sync,accent:PARTY,invalidate,theme,normal,avail,refresh",
   "group: no tab asked for lands on the mode showing, and re-runs it (as a click on the lit tab did)")

-- ---- select: Global ---------------------------------------------------
print("-- Module registry: Global keeps the mode underneath")
calls = {}
GUI:SelectModule("global")
check(GUI.GlobalView == true and GUI.SelectedMode == "party", "global: GLOBAL up, Party underneath")
eq(GUI.SelectedModule, "global", "global: SelectedModule follows GlobalView")
eq(joined(), "view:true,tab:general_settings", "global: the view, then the page it showed last")
calls = {}
GUI:SelectModule("global")
eq(joined(), "", "global: picking it again does nothing")
calls = {}
GUI:SelectModule("group", "party")
eq(joined(), "view:false,tab:general_frame", "global: back to the mode underneath is the shortcut, not a switch")
eq(GUI.SelectedModule, "group", "global: ...and SelectedModule follows")

-- ---- select: Binds ----------------------------------------------------
print("-- Module registry: Binds")
calls = {}
partyDb.locked = false; DF.testMode = true
GUI:SelectModule("clicks")
eq(GUI.SelectedMode, "clicks", "binds: SelectedMode is clicks")
eq(GUI.SelectedModule, "clicks", "binds: ...and so is the module")
eq(joined(), "lockparty,hidepartytest,clear:party,accent:PARTY,hideresults,theme,clickcontent",
   "binds: the frames are locked, the preview dropped, then the binds panel shown")
GUI._lastFrameMode = "raid"
eq(GUI:GetModule("group").defaultTab(), "raid", "binds: Group Frames with no tab goes back to the frame mode left")

-- ---- forPage: SelectTab's path --------------------------------------
print("-- Module registry: the page path changes only the view")
calls = {}
GUI:SelectModule("group", nil, { forPage = "general_frame" })
eq(joined(), "view:false", "page: from Binds, only the view (the caller selects the page)")
eq(GUI.SelectedMode, "raid", "page: ...onto the frame mode Binds was entered from")
eq(GUI.SelectedModule, "group", "page: ...and SelectedModule follows")
calls = {}
GUI:SelectModule("global", nil, { forPage = "general_settings" })
eq(joined(), "view:true", "page: to a GLOBAL page, the view only")
GUI:SelectModule("group", nil, { forPage = "general_frame" })

-- ---- mover session ----------------------------------------------------
print("-- Module registry: a switch ends a mover session first")
local replay
DF.MoverBridge = {
    IsSessionActive = function() return true end,
    EndSessionThen = function(_, fn) replay = fn end,
}
calls = {}
GUI.SelectedMode = "raid"
check(GUI:SelectModule("group", "party") == false and replay ~= nil and joined() == "",
      "mover: a mode switch is held until the session ends")
DF.MoverBridge.IsSessionActive = function() return false end
replay()
eq(GUI.SelectedMode, "party", "mover: ...and replayed after")
DF.MoverBridge.IsSessionActive = function() return true end
replay = nil
calls = {}
GUI:SelectModule("group", "party")
check(replay == nil and calls[1] == "sync", "mover: the mode already showing switches nothing, so ends nothing")
GUI._moverOwnedClick = true
GUI:SelectModule("group", "raid")
check(replay == nil and GUI.SelectedMode == "raid", "mover: Configure's own switch keeps the session")
GUI._moverOwnedClick = nil
GUI:SelectModule("global")
check(replay == nil and GUI.GlobalView == true, "mover: GLOBAL ends no session")
GUI:SelectModule("group", "raid")
GUI:SelectModule("group", "raid")
replay = nil
GUI:SelectModule("group", "raid", { forPage = "general_frame" })
check(replay == nil, "mover: the page path ends no session")
DF.MoverBridge = nil

-- ---- locks ------------------------------------------------------------
print("-- Module registry: locks")
local function button()
    local b = { mouse = true, Text = {} }
    function b:EnableMouse(v) self.mouse = v end
    function b.Text:SetTextColor(r) b.textR = r end
    function b.Text:SetAlpha(a) b.textA = a end
    function b:SetBackdropColor() end
    function b:SetBackdropBorderColor() end
    return b
end
local bG, bP, bR, bC = button(), button(), button(), button()
GUI:AttachModuleButton("global", nil, bG)
GUI:AttachModuleButton("group", "party", bP)
GUI:AttachModuleButton("group", "raid", bR)
GUI:AttachModuleButton("clicks", nil, bC)
GUI:SetModuleLocked("global", true)
GUI:SetModuleLocked("group", true, "party")
GUI:SetModuleLocked("clicks", true)
check(bG.disabled and not bG.mouse and bP.disabled and not bP.mouse and bC.disabled and not bC.mouse,
      "lock: Global, Party and Binds greyed and deaf, as Auto Layout editing did")
check(not bR.disabled and bR.mouse, "lock: ...Raid untouched")
check(GUI:IsModuleLocked("global") and GUI:IsModuleLocked("group", "party")
      and not GUI:IsModuleLocked("group") and not GUI:IsModuleLocked("group", "raid"),
      "lock: IsModuleLocked answers per module and per tab")
eq(bP.textR, 0.2, "lock: the editor's dark grey label")
calls = {}
GUI.SelectedMode = "raid"; GUI.GlobalView = false
GUI:SelectModule("group", "party")
eq(GUI.SelectedMode, "party", "lock: a programmatic switch still goes through (EnableMouse never stopped :Click())")
GUI:SetModuleLocked("global", false)
GUI:SetModuleLocked("group", false, "party")
GUI:SetModuleLocked("clicks", false)
check(not bG.disabled and bG.mouse and not bP.disabled and bP.mouse and not bC.disabled and bC.mouse
      and bP.textA == 1, "lock: unlocked, all three take the mouse again")

DandersFrames = savedDF

-- ---- the callers (source shape) -------------------------------------
print("-- Module registry: nothing clicks a mode tab any more")
do
    local PANEL  = options_file_source("GUI/Panel.lua"):gsub("\r\n", "\n")
    local BRIDGE = df_file_source("Features/MoverBridge.lua"):gsub("\r\n", "\n")
    local AUTOP  = options_file_source("GUI/Pages/AutoProfiles.lua"):gsub("\r\n", "\n")
    for _, b in ipairs({ "GlobalButton", "PartyButton", "RaidButton", "ClicksButton" }) do
        for name, src in pairs({ Panel = PANEL, MoverBridge = BRIDGE, AutoProfiles = AUTOP }) do
            check(not src:find("GUI." .. b .. ":Click()", 1, true) and not src:find("GUI." .. b .. " then GUI." .. b, 1, true),
                  "callers: " .. name .. " does not click " .. b)
        end
    end
    check(BRIDGE:find('pcall(GUI.SelectModule, GUI, "group", (mode == "raid") and "raid" or "party")', 1, true) ~= nil,
          "callers: the mover's Configure switches mode through SelectModule, flagged")
    check(PANEL:find('GUI:SelectModule("clicks")\n            return', 1, true) ~= nil
          and PANEL:find('if GUI.SelectedMode == "clicks" then GUI:SelectModule("group", "party") end', 1, true) ~= nil,
          "callers: the changelog's links switch through SelectModule")
    check(AUTOP:find("local buttonsToDisable", 1, true) == nil,
          "callers: Auto Layout editing locks modules, not buttons")
end
