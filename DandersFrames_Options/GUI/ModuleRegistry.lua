-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). See the same note at the head of GUI/Panel.lua.
local DF = DandersFrames
local GUI = DF.GUI
local L = DF.L

local ipairs, pairs, type, tostring = ipairs, pairs, type, tostring
local tsort = table.sort

-- ============================================================
-- SETTINGS MODULE REGISTRY
-- The settings window's top-level places (Group Frames with its Party / Raid
-- tabs, Binds, Global) as data, and the ONE way to move between them:
-- GUI:SelectModule(id, tabId).
--
-- The icon rail and deck 2's module tabs (GUI/Rail.lua) read GUI:GetModules()
-- and are thin callers of SelectModule. Everything a
-- switch DOES -- the Party/Raid sync, locking the departing mode's frames,
-- carrying test mode across, ending a mover session first -- lives in the
-- modules below, not in whatever widget asked for it.
--
-- ☠ STATE IS STILL GUI.SelectedMode + GUI.GlobalView. Every page reads
-- DF.db[GUI.SelectedMode], and GLOBAL keeps the mode underneath it (THE GLOBAL
-- TAB, DandersFrames/GUI/GUI.lua). GUI.SelectedModule is DERIVED from those
-- two and refreshed after every switch -- it is never the thing written.
-- ============================================================

local modules = {}       -- id -> def
local ordered = {}       -- defs, slot then order
local locks = {}         -- id or "id:tab" -> true

local SLOT_RANK = { top = 1, bottom = 2 }

-- Click-Casting's fixed identity accent (green). Here rather than in Panel.lua
-- so the rail can read it: it loads before the panel (companion TOC order).
GUI.ClicksAccent = GUI.ClicksAccent or { r = 0.2, g = 0.8, b = 0.4 }

local ICONS = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"

local function Resort()
    tsort(ordered, function(a, b)
        local sa, sb = SLOT_RANK[a.slot] or 1, SLOT_RANK[b.slot] or 1
        if sa ~= sb then return sa < sb end
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)
end

-- def: id, label, icon, order, slot ("top"|"bottom"), accent(), tabs
-- ({ {id, label, deckLabel, accent}, ... }, optional), activeTab(), sidebar (bool),
-- isEnabled(), ownsPage(name), onEnter(tabId), onEnterForPage(tabId, pageName),
-- onLeave(), endsMoverSession, railLabel (short label under the rail icon),
-- alwaysInRail (listed in the rail even while isEnabled() is false).
-- A label may be a string or a function returning one (so a language override
-- is picked up -- a string resolved from L at file scope freezes on enUS).
function GUI:RegisterModule(def)
    if type(def) ~= "table" or type(def.id) ~= "string" then
        DF:DebugError("GUI", "RegisterModule: a module needs a string id")
        return nil
    end
    local old = modules[def.id]
    if old then
        for i = #ordered, 1, -1 do
            if ordered[i] == old then table.remove(ordered, i) end
        end
        def._buttons = def._buttons or old._buttons
    end
    def.order = def.order or 100
    def.slot = def.slot or "top"
    def._buttons = def._buttons or {}
    modules[def.id] = def
    ordered[#ordered + 1] = def
    Resort()
    return def
end

-- Every registered module, rail order (top slot first, then by order).
function GUI:GetModules()
    local out = {}
    for i = 1, #ordered do out[i] = ordered[i] end
    return out
end

-- The id of the module the window is showing, read off the state.
-- ⚠ BINDS FIRST, then GLOBAL. SelectTab's old test was "page on the other side
-- of GlobalView, OR on Binds", which this order reproduces exactly even for a
-- (never written) Binds-with-GlobalView state.
local function CurrentModuleId()
    -- A placeholder rail item (Home, Modules, Profiles) sits over whatever
    -- state the window was in, so it wins over all of it.
    if GUI.PlaceholderView then return GUI.PlaceholderView end
    if GUI.SelectedMode == "clicks" then return "clicks" end
    if GUI.GlobalView == true then return "global" end
    return "group"
end
GUI.CurrentModuleId = CurrentModuleId

-- ★ AND IT IS WHERE THE LAST PLACE IS RECORDED (account-wide window state),
-- for the next open to go back to (GUI:RestoreModuleOnOpen, GUI/Rail.lua).
-- Only while the window is SHOWN: ToggleGUI writes its party/raid auto-pick
-- and repaints before the window shows, and that is not the user's choice.
-- lastTab is recorded for later use; the open path still picks Party or Raid
-- by group type.
function GUI:SyncSelectedModule()
    local id = CurrentModuleId()
    GUI.SelectedModule = id
    local f = DF.GUIFrame
    if f and f.IsShown and f:IsShown() and DF.GetWindowState then
        local ws = DF:GetWindowState()
        if ws then
            ws.lastModule = id
            ws.lastTab = (id == "group") and GUI.SelectedMode or nil
        end
    end
    return id
end

-- The def for `id`, or for the module showing when no id is given.
function GUI:GetModule(id)
    return modules[id or CurrentModuleId()]
end

function GUI:ModuleLabel(def)
    local label = def and def.label
    if type(label) == "function" then return label() end
    return label
end

-- Which module a sidebar page belongs to (nil: none claims it).
function GUI:ModuleForPage(name)
    for i = 1, #ordered do
        local def = ordered[i]
        if def.ownsPage and def.ownsPage(name) then return def.id end
    end
end

-- ============================================================
-- LOCKS
-- A locked module (or one tab of it) cannot be picked by the USER: its control
-- is greyed and stops taking the mouse. Programmatic SelectModule calls are NOT
-- refused -- the old buttons were locked with EnableMouse(false), which never
-- stopped btn:Click(), and the mover's Configure and the changelog's links
-- relied on that.
-- ============================================================

local function LockKey(id, tabId)
    return tabId and (id .. ":" .. tostring(tabId)) or id
end

-- The look the Auto Layouts editor has always given a mode button it takes
-- out of play, and the way back. UpdateThemeColors restores the colours.
local function PaintLocked(btn, locked)
    if locked then
        btn.disabled = true
        btn:EnableMouse(false)
        btn.Text:SetTextColor(0.2, 0.2, 0.2)
        btn.Text:SetAlpha(0.8)
        btn:SetBackdropColor(0.1, 0.1, 0.1, 0.5)
        btn:SetBackdropBorderColor(0.2, 0.2, 0.2, 0.5)
    else
        btn.disabled = false
        btn:EnableMouse(true)
        btn.Text:SetAlpha(1)
    end
end

-- Lock or unlock a module, or one of its tabs when tabId is given.
-- A whole-module lock also greys its rail item (GUI.OnModuleLockChanged, set
-- by GUI/Rail.lua once the rail exists); a tab lock greys only that deck-2 tab.
function GUI:SetModuleLocked(id, locked, tabId)
    local def = modules[id]
    if not def then return end
    locks[LockKey(id, tabId)] = locked and true or nil
    for key, btn in pairs(def._buttons) do
        if tabId == nil or key == tabId then
            local isLocked = locks[id] or (key ~= "_" and locks[LockKey(id, key)]) or false
            PaintLocked(btn, isLocked)
        end
    end
    if tabId == nil and GUI.OnModuleLockChanged then
        GUI.OnModuleLockChanged(id, locks[id] == true)
    end
end

function GUI:IsModuleLocked(id, tabId)
    if locks[id] then return true end
    return tabId ~= nil and locks[LockKey(id, tabId)] == true
end

-- The deck-2 button that stands for a module's tab. GUI/Rail.lua attaches
-- them as it builds them; SetModuleLocked greys these (rail items are greyed
-- through GUI.OnModuleLockChanged instead).
function GUI:AttachModuleButton(id, tabId, btn)
    local def = modules[id]
    if not def or not btn then return end
    def._buttons[tabId or "_"] = btn
end

-- ============================================================
-- SELECT MODULE -- the one way to navigate between modules
-- ============================================================
-- opts.forPage = pageName: the switch is on the way to a page the caller is
-- about to select (SelectTab: search results, cross-links). The module then
-- only changes the VIEW (onEnterForPage) and selects no page of its own.

-- ☠ A MODE SWITCH MUST NOT OVERLAP A MOVER SESSION. The Party/Raid switch locks
-- the departing mode and carries test mode across, but with unsaved moves the
-- lock is only a PROMPT -- the switch ran on underneath it, and the prompt's
-- answer then released the session's claim against the wrong mode: test frames
-- stuck on screen, or both groups hidden (Aphoex, a15 #7). So the session is
-- ended first and the switch replayed after.
-- Not for the mover's own Configure (MoverBridge.openOptionsPage selects a mode
-- mid-session on purpose, flagged by _moverOwnedClick), and not for a pick of
-- the mode already showing, which switches nothing.
local function DeferForMoverSession(id, tabId)
    if GUI._moverOwnedClick then return false end
    if tabId and id == CurrentModuleId() and GUI.SelectedMode == tabId then return false end
    local B = DF.MoverBridge
    if not (B and B.IsSessionActive and B:IsSessionActive()) then return false end
    B:EndSessionThen(function() GUI:SelectModule(id, tabId) end)
    return true
end

function GUI:SelectModule(id, tabId, opts)
    local def = modules[id]
    if not def then
        DF:DebugWarn("GUI", "SelectModule: no module '%s'", tostring(id))
        return false
    end
    -- A module with tabs and no tab asked for lands on the one it showed last.
    if tabId == nil and def.defaultTab then tabId = def.defaultTab() end
    local forPage = opts and opts.forPage

    if not forPage and def.endsMoverSession and DeferForMoverSession(id, tabId) then
        return false
    end

    local fromId = CurrentModuleId()
    if fromId ~= id then
        local from = modules[fromId]
        if from and from.onLeave then from.onLeave() end
    end

    if forPage then
        if def.onEnterForPage then def.onEnterForPage(tabId, forPage) end
    elseif def.onEnter then
        def.onEnter(tabId)
    end
    GUI:SyncSelectedModule()
    return true
end

-- ============================================================
-- BUILT-IN MODULES: GROUP FRAMES (Party / Raid)
-- The bodies are the old Party and Raid tab handlers, moved here unchanged.
-- ============================================================

-- Back from GLOBAL to the mode it sat on. No mode changes, so the switch in
-- the handlers below -- the sync, the locks, the test hand-over, a new search
-- index, a second refresh of the page and of every override dot -- has
-- nothing to do. This is GLOBAL's own path, the other way.
local function LeaveGlobalTo(mode)
    if not (GUI.GlobalView and GUI.SelectedMode == mode) then return false end
    GUI:EnterView(false)
    GUI.SelectTab(GUI:LastTabInView())
    return true
end

local function EnterParty()
    if LeaveGlobalTo("party") then return end
    -- Leaving GLOBAL, if it was up: the page it showed is not in Party's
    -- sidebar, and UpdateTabAvailability (via ShowNormalContent) moves off it.
    GUI.GlobalView = false
    -- Copies INTO the other mode's tables (THE SYNC KEEPS TABLES, bottom of
    -- GUI/Panel.lua), so that mode's retained page builds stay valid.
    DF:SyncLinkedSections()

    -- Carry test mode across the mode switch (raid test -> party test)
    local carryTest = false
    -- Before switching tabs, clean up current mode's test mode and unlock state
    if GUI.SelectedMode == "raid" then
        -- Lock raid frames if unlocked. LockRaidFrames owns the WHOLE transition:
        -- the db flag, the container, the mover, grid, panel and pinned chrome.
        -- ⚠ Do NOT stamp raidLocked or poke the container here before calling: when
        -- LockRaidFrames' combat guard refuses, the db would say locked while every
        -- mover stayed on screen for the rest of the fight, and the Lock button then
        -- offered Unlock. In combat the state stays UNLOCKED (the guard says so in
        -- chat) and the user locks after regen. A direct SetMovable poke also fights
        -- UpdatePermanentMoverVisibility, which owns container movability.
        local raidDb = DF:GetRaidDB()
        if not raidDb.raidLocked then
            if DF.LockRaidFrames then DF:LockRaidFrames() end
        end
        -- Disable raid test mode if active
        if DF.raidTestMode then
            carryTest = true
            -- Hand-over: stay in container/pinned test mode across the swap rather
            -- than tearing every aura container down for live data we never show
            -- and rebuilding it a moment later. Cleared below.
            DF._testModeHandover = true
            DF:HideRaidTestFrames(true)  -- silent
            -- Hides directly rather than through the owners, so drop raid's
            -- claims to match. carryTest re-claims in the scope we land in.
            if DF.ClearTestModeOwners then DF:ClearTestModeOwners("raid") end
        end
    end

    GUI.SelectedMode = "party"
    GUI:SetAccent(GUI.GetThemeColorFor(false))
    if DF.Search then
        DF.Search:InvalidateRegistry()
        DF.Search:RefreshIfActive()
    end
    -- The page on screen is still the OTHER mode's build until the refresh
    -- below swaps it; repainting it here would be undone on the way back.
    GUI._holdPageRepaint = true
    GUI.UpdateThemeColors()
    GUI._holdPageRepaint = nil
    GUI:ShowNormalContent()
    GUI:UpdateTabAvailability()
    -- Cached, not forced: a mode switch shows the other mode's build if it
    -- is still good rather than trashing the page and building a new one.
    GUI:RefreshCurrentPageForModeSwitch()

    -- Keep test mode active when switching modes (just switch which mode it runs in).
    -- Carried as the USER's claim: they had a preview up and are still asking for
    -- one, just in the other scope.
    if carryTest and DF.SetTestModeOwner then
        DF:SetTestModeOwner("party", "user", true, true)   -- silent: the mode swap is the visible event
        -- ShowTestFrames (unlike ShowRaidTestFrames) doesn't refresh the GUI,
        -- so the test panel's toggle label would stay on "Enable Test Mode".
        -- Refresh it now that party test mode is active.
        if DF.TestPanel and DF.TestPanel:IsShown() then
            DF.TestPanel:UpdateStateNoCallback()
        end
    end
    if carryTest then
        -- End the hand-over and settle: ShowTestFrames can bail (combat, party
        -- frames disabled), which would otherwise leave the engines parked in
        -- test mode with nothing testing. Teardown re-reads the real flags, so
        -- it is a no-op when the incoming mode did start.
        DF._testModeHandover = nil
        if DF.TeardownTestModeEngines then DF:TeardownTestModeEngines() end
    end
end

local function EnterRaid()
    if LeaveGlobalTo("raid") then return end
    -- Leaving GLOBAL, if it was up -- see EnterParty.
    GUI.GlobalView = false
    -- Copies INTO the other mode's tables (THE SYNC KEEPS TABLES, bottom of
    -- GUI/Panel.lua), so that mode's retained page builds stay valid.
    DF:SyncLinkedSections()

    -- Carry test mode across the mode switch (party test -> raid test)
    local carryTest = false
    -- Before switching tabs, clean up current mode's test mode and unlock state
    if GUI.SelectedMode == "party" then
        -- Lock party frames if unlocked
        local partyDb = DF:GetDB()
        if not partyDb.locked then
            partyDb.locked = true
            if DF.partyContainer then
                DF.partyContainer:EnableMouse(false)
                DF.partyContainer:SetMovable(false)
            end
            if DF.LockFrames then DF:LockFrames() end
        end
        -- Disable party test mode if active
        if DF.testMode then
            carryTest = true
            -- Hand-over: see EnterParty.
            DF._testModeHandover = true
            DF:HideTestFrames(true)  -- silent
            -- Hides directly rather than through the owners, so drop party's
            -- claims to match. carryTest re-claims in the scope we land in.
            if DF.ClearTestModeOwners then DF:ClearTestModeOwners("party") end
        end
    end

    GUI.SelectedMode = "raid"
    GUI:SetAccent(GUI.GetThemeColorFor(true))
    if DF.Search then
        DF.Search:InvalidateRegistry()
        DF.Search:RefreshIfActive()
    end
    -- See EnterParty.
    GUI._holdPageRepaint = true
    GUI.UpdateThemeColors()
    GUI._holdPageRepaint = nil
    GUI:ShowNormalContent()
    GUI:UpdateTabAvailability()
    -- Cached, not forced: a mode switch shows the other mode's build if it
    -- is still good rather than trashing the page and building a new one.
    GUI:RefreshCurrentPageForModeSwitch()

    -- Keep test mode active when switching modes (just switch which mode it runs in).
    -- Carried as the USER's claim: they had a preview up and are still asking for
    -- one, just in the other scope.
    if carryTest and DF.SetTestModeOwner then
        DF:SetTestModeOwner("raid", "user", true, true)    -- silent: the mode swap is the visible event
    elseif carryTest and DF.ShowRaidTestFrames then
        DF:ShowRaidTestFrames()
    end
    if carryTest then
        -- End the hand-over and settle; see EnterParty.
        DF._testModeHandover = nil
        if DF.TeardownTestModeEngines then DF:TeardownTestModeEngines() end
    end
end

GUI:RegisterModule({
    id = "group",
    label = function() return L["Group Frames"] end,
    railLabel = function() return L["Groups"] end,
    icon = ICONS .. "groups.png",
    order = 10,
    slot = "top",
    tabs = {
        { id = "party", label = function() return L["Party"] end,
          deckLabel = function() return L["PARTY"] end,
          accent = function() return GUI.GetThemeColorFor(false) end },
        { id = "raid",  label = function() return L["Raid"] end,
          deckLabel = function() return L["RAID"] end,
          accent = function() return GUI.GetThemeColorFor(true) end },
    },
    -- The deck-2 tab lit while this module shows.
    activeTab = function() return GUI.SelectedMode end,
    sidebar = true,
    endsMoverSession = true,
    accent = function() return GUI.GetThemeColorFor(GUI.SelectedMode == "raid") end,
    -- Party or Raid frames switched on. ⚠ alwaysInRail until the Modules page
    -- exists: with both off the rail would otherwise have no way back in.
    isEnabled = function()
        local db = DF.db
        return not db or db.partyEnabled ~= false or db.raidEnabled ~= false
    end,
    alwaysInRail = true,
    -- Every page that is not GLOBAL's is Party's/Raid's.
    ownsPage = function(name) return not GUI.IsGlobalPage(name) end,
    -- No tab asked for: the frame mode showing, else the one Binds/GLOBAL left.
    defaultTab = function()
        if GUI.SelectedMode == "party" or GUI.SelectedMode == "raid" then return GUI.SelectedMode end
        return GUI._lastFrameMode or "party"
    end,
    onEnter = function(tabId)
        if tabId == "raid" then EnterRaid() else EnterParty() end
    end,
    -- SelectTab's own switch: the view only; the caller picks the page.
    onEnterForPage = function() GUI:EnterView(false) end,
})

-- ============================================================
-- BUILT-IN MODULES: BINDS (click casting)
-- The old Binds tab handler, moved here unchanged.
-- ============================================================

local function EnterClicks()
    GUI.GlobalView = false
    -- Clean up any test/unlock state from previous mode
    if GUI.SelectedMode == "party" then
        local partyDb = DF:GetDB()
        if partyDb and not partyDb.locked then
            partyDb.locked = true
            if DF.LockFrames then DF:LockFrames() end
        end
        if DF.testMode then DF:HideTestFrames(true) end
        -- Leaving for a tab with no frames: nobody is asking for a preview
        -- any more, so drop the claims rather than let them outlive it.
        if DF.ClearTestModeOwners then DF:ClearTestModeOwners("party") end
    elseif GUI.SelectedMode == "raid" then
        local raidDb = DF:GetRaidDB()
        if raidDb and not raidDb.raidLocked then
            raidDb.raidLocked = true
            if DF.LockRaidFrames then DF:LockRaidFrames() end
        end
        if DF.raidTestMode then DF:HideRaidTestFrames(true) end
        -- As above: no preview is wanted on a tab that has no frames.
        if DF.ClearTestModeOwners then DF:ClearTestModeOwners("raid") end
    end

    GUI.SelectedMode = "clicks"
    GUI:SetAccent(GUI.GetThemeColorFor(false))
    if DF.Search then
        DF.Search:HideResults()
    end
    GUI.UpdateThemeColors()
    GUI:ShowClickCastingContent()
end

GUI:RegisterModule({
    id = "clicks",
    label = function() return L["Click-Casting"] end,
    railLabel = function() return L["Binds"] end,
    icon = ICONS .. "mouse.png",
    order = 20,
    slot = "top",
    sidebar = false,
    endsMoverSession = true,
    -- Its fixed identity green (the rail, the deck-2 title). The HOST accent
    -- while Binds shows stays party's -- see EnterClicks.
    accent = function() return GUI.ClicksAccent end,
    -- ⚠ alwaysInRail until the Modules page exists -- see Group Frames.
    isEnabled = function()
        local CC = DF.ClickCast
        return not (CC and CC.db) or CC.db.enabled ~= false
    end,
    alwaysInRail = true,
    onEnter = EnterClicks,
})

-- ============================================================
-- BUILT-IN MODULES: GLOBAL
-- The mode under it is left exactly as it is (see THE GLOBAL TAB in
-- DandersFrames/GUI/GUI.lua), so there is no test-mode or unlock hand-over to
-- make, and no mover session to end.
-- ============================================================

GUI:RegisterModule({
    id = "global",
    label = function() return L["Global"] end,
    railLabel = function() return L["Global"] end,
    icon = ICONS .. "settings.png",
    order = 90,
    slot = "bottom",
    sidebar = true,
    accent = function() return GUI.GlobalAccent end,
    isEnabled = function() return true end,
    ownsPage = function(name) return GUI.IsGlobalPage(name) end,
    onEnter = function()
        if GUI.GlobalView then return end
        GUI:EnterView(true)
        GUI.SelectTab(GUI:LastTabInView())
    end,
    onEnterForPage = function() GUI:EnterView(true) end,
})

-- ============================================================
-- PLACEHOLDER MODULES: HOME, MODULES, PROFILES
-- In the rail now so the layout is final; each shows a "coming in a later
-- update" panel until its page is built. Like GLOBAL they leave the mode
-- under them exactly as it is -- no test-mode or unlock hand-over, no mover
-- session to end -- and leaving one puts the normal content back first.
-- ============================================================

local function Placeholder(def)
    def.placeholder = true
    def.sidebar = false
    def.accent = def.accent or function() return GUI.Colors.text end
    def.onEnter = function()
        GUI.PlaceholderView = def.id
        GUI:ShowPlaceholderContent(def)
        GUI.UpdateThemeColors()
    end
    def.onLeave = function()
        GUI.PlaceholderView = nil
        GUI:ShowNormalContent()
    end
    GUI:RegisterModule(def)
end

Placeholder({
    id = "home",
    label = function() return L["Home"] end,
    icon = ICONS .. "home.png",
    order = 0,
    slot = "top",
})

Placeholder({
    id = "modules",
    label = function() return L["Modules"] end,
    icon = ICONS .. "extension.png",
    order = 80,
    slot = "bottom",
})

Placeholder({
    id = "profiles",
    label = function() return L["Profiles"] end,
    icon = ICONS .. "account_circle.png",
    order = 85,
    slot = "bottom",
})

GUI:SyncSelectedModule()
