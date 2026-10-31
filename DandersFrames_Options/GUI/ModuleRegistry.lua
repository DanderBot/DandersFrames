-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). See the same note at the head of GUI/Panel.lua.
local DF = DandersFrames
local GUI = DF.GUI
local L = DF.L

local ipairs, pairs, type, tostring, pcall = ipairs, pairs, type, tostring, pcall
local format = string.format
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
-- Unit Frames' fixed identity accent (violet, #a66bff): its rail item, deck-2
-- tabs and pages.
GUI.UnitsAccent = GUI.UnitsAccent or { r = 0.651, g = 0.420, b = 1.0 }

-- Page name -> owning module id (declared resident in DandersFrames/GUI/GUI.lua;
-- here too so this file never indexes nil). See GUI:SetPageModule below.
GUI.ModulePageOwner = GUI.ModulePageOwner or {}

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
-- ({ {id, label, deckLabel, accent, mark}, ... }, optional), activeTab(), sidebar (bool),
-- isEnabled(), ownsPage(name), pageMark(name) (see STATE MARKS), onEnter(tabId), onEnterForPage(tabId, pageName),
-- onLeave(), endsMoverSession, railLabel (short label under the rail icon),
-- alwaysInRail (listed in the rail even while isEnabled() is false),
-- status() (one line for Home's tile and the Modules page), description,
-- noTile (never a Home tile: Home, Modules, Profiles), comingSoon (listed,
-- nothing to switch on yet), view (a full-window page of its own, shown and
-- hidden through showView / hideView -- Home, Modules).
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
        -- A REPLACED module's deck-2 tabs go with it: the rail builds the new
        -- def's own (GUI/Rail.lua builds tabs for any module that has none yet).
        if old._deckTabs and old._deckTabs ~= def._deckTabs then
            for tabId, b in pairs(old._deckTabs) do
                if b.Hide then b:Hide() end
                if def._buttons[tabId] == b then def._buttons[tabId] = nil end
            end
        end
    end
    -- Bumped on every registration so the rail re-reads its items even when the
    -- set of ids it shows is the same (a module replaced in place).
    GUI._moduleGen = (GUI._moduleGen or 0) + 1
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
    -- A sidebar module of its own (GUI:EnterModuleView) sits over the mode the
    -- same way Profiles does.
    if GUI.ModuleView then return GUI.ModuleView end
    -- Profiles sits over the frame mode (and GLOBAL, if it was up) the same way.
    if GUI.ProfilesView then return "profiles" end
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

-- Is a module ON: switched on, and something you can use today. A
-- placeholder or coming-soon module is never on; one without isEnabled is
-- always on (Global).
function GUI:IsModuleOn(def)
    if type(def) == "string" then def = modules[def] end
    if not def or def.placeholder or def.comingSoon then return false end
    if def.isEnabled then return def.isEnabled() and true or false end
    return true
end

-- The module's one-line status, or "" (status() is optional, and a broken
-- one must not take Home down with it).
function GUI:ModuleStatus(def)
    if type(def) == "string" then def = modules[def] end
    local fn = def and def.status
    if type(fn) ~= "function" then return "" end
    local ok, text = pcall(fn)
    return (ok and type(text) == "string") and text or ""
end

-- A def field that may be a string or a function returning one.
function GUI:ModuleText(def, field)
    local v = def and def[field]
    if type(v) == "function" then return v() end
    return v
end

-- Which module a sidebar page belongs to (nil: none claims it). A page given to
-- a module (GUI:SetPageModule) is that module's, whatever the catch-alls say.
function GUI:ModuleForPage(name)
    local owner = name and GUI.ModulePageOwner and GUI.ModulePageOwner[name]
    if owner and modules[owner] then return owner end
    for i = 1, #ordered do
        local def = ordered[i]
        if def.ownsPage and def.ownsPage(name) then return def.id end
    end
end

-- ============================================================
-- STATE MARKS on a module's sidebar rows and deck-2 tabs
-- def.pageMark(pageName) -> spec | nil   a glyph after that page's sidebar label
-- tab.mark() -> spec | nil               a glyph after that deck-2 tab's label
-- spec is UI:SetLabelMark's (texture, size, gap, color). Only pages given to a
-- module with GUI:SetPageModule are asked -- the catch-all ownsPage is not walked
-- for every row on every layout. Repainted on every sidebar layout and deck
-- refresh; a consumer whose state changed calls GUI:RefreshPageMarks() (rows) and
-- GUI:RefreshModuleShell() (tabs).
-- ============================================================
function GUI:RefreshPageMarks()
    if not (GUI.Tabs and GUI.SetLabelMark) then return end
    local owners = GUI.ModulePageOwner or {}
    for name, btn in pairs(GUI.Tabs) do
        local def = owners[name] and modules[owners[name]]
        local fn = def and def.pageMark
        local spec
        if fn then
            local ok, s = pcall(fn, name)
            spec = ok and s or nil
        end
        if spec or rawget(btn, "dfLabelMark") then GUI:SetLabelMark(btn, spec) end
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
    -- Home's tiles and the Modules page's Open buttons grey with the lock too
    -- (both refreshes do nothing while their page is hidden).
    if GUI.RefreshHomeView then GUI:RefreshHomeView() end
    if GUI.RefreshModulesView then GUI:RefreshModulesView() end
end

function GUI:IsModuleLocked(id, tabId)
    if locks[id] then return true end
    return tabId ~= nil and locks[LockKey(id, tabId)] == true
end

-- ★ FOR A USER-FACING WAY INTO A MODULE THAT IS NOT THE RAIL (Home's tiles and
-- profile link, the Modules page's Open buttons, a Needs-attention fix): is
-- the pick refused? As the rail's own click is. A pick without a tab lands
-- on the module's default one, so that is the tab whose lock counts (Group
-- Frames while an Auto Layout is edited: Raid is open, Party is not).
-- SelectModule itself still refuses nothing -- see LOCKS above.
function GUI:IsModulePickLocked(id, tabId)
    local def = modules[id]
    if not def then return false end
    if tabId == nil and def.defaultTab then tabId = def.defaultTab() end
    return GUI:IsModuleLocked(id, tabId)
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
    local paintsBefore = GUI._shellPaints
    if fromId ~= id then
        local from = modules[fromId]
        if from and from.onLeave then from.onLeave() end
    end

    if forPage then
        if def.onEnterForPage then def.onEnterForPage(tabId, forPage) end
    elseif def.onEnter then
        def.onEnter(tabId)
    end
    -- Set by Profiles' onLeave for the one onEnter that follows it (see
    -- LeaveGlobalTo); never outlives the switch.
    GUI._leavingProfiles = nil
    GUI:SyncSelectedModule()
    -- ★ THE RAIL AND DECK 2 FOLLOW EVERY SWITCH. Most onEnters end in a page
    -- select or UpdateThemeColors, which repaints them; one that has nothing
    -- to do (GLOBAL picked again from Home, with its view still up underneath)
    -- returns early, and the rail stayed lit on the module just left -- with
    -- a click on the right one then ignored as "already showing". Painted
    -- here only when the switch did not paint it already (RefreshModuleShell
    -- counts its paints), so nothing glides twice. Not on the page path:
    -- SelectTab is mid-switch and ends in its own repaint.
    if not forPage and GUI.RefreshModuleShell and GUI._shellPaints == paintsBefore then
        local f = DF.GUIFrame
        GUI:RefreshModuleShell(not (f and f.IsShown and f:IsShown()))
    end
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
-- ALSO PROFILES' WAY BACK (GUI._leavingProfiles, set by its onLeave): Profiles
-- sat over the mode too, so returning to that same mode is the view switch
-- alone.
local function LeaveGlobalTo(mode)
    if not ((GUI.GlobalView or GUI._leavingProfiles) and GUI.SelectedMode == mode) then return false end
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
    -- Party or Raid frames switched on. With both off the module leaves the
    -- rail; the Modules page is the way back in (GUI/Pages/ModulesPage.lua).
    isEnabled = function()
        local db = DF.db
        return not db or db.partyEnabled ~= false or db.raidEnabled ~= false
    end,
    -- "Party · Raid", "Party only", "Raid only" or "Off" -- what the Frame
    -- Modes card says. ⚠ `~= false`: ABSENT MEANS ENABLED for these two keys.
    status = function()
        local db = DF.db
        local party = not db or db.partyEnabled ~= false
        local raid = not db or db.raidEnabled ~= false
        if party and raid then return format("%s \194\183 %s", L["Party"], L["Raid"]) end
        if party then return format(L["%s only"], L["Party"]) end
        if raid then return format(L["%s only"], L["Raid"]) end
        return L["Off"]
    end,
    description = function() return L["Party and raid frames: layout, bars, auras and indicators."] end,
    -- Every page that is not GLOBAL's, Profiles' or given to another module
    -- (GUI:SetPageModule) is Party's/Raid's.
    ownsPage = function(name)
        return not GUI.IsGlobalPage(name)
            and not (GUI.IsProfilesPage and GUI.IsProfilesPage(name))
            and not (GUI.ModulePageOwner and GUI.ModulePageOwner[name])
    end,
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
    -- Switched off, it leaves the rail -- see Group Frames. ⚠ TRUTHINESS, as
    -- CC:IsEnabled reads it: click-casting is opt-in (off by default), so an
    -- unset flag is OFF -- the opposite of partyEnabled / raidEnabled.
    isEnabled = function()
        local CC = DF.ClickCast
        return not (CC and CC.db) or CC.db.enabled and true or false
    end,
    status = function()
        local CC = DF.ClickCast
        if CC and CC.db and not CC.db.enabled then return L["Off"] end
        local list = CC and CC.db and CC.db.bindings
        if type(list) ~= "table" then return L["On"] end
        return format(L["%d bindings"], #list)
    end,
    description = function() return L["Click-cast bindings for every frame."] end,
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
    -- Settings, not a module: no Home tile and not counted in "N of M on".
    noTile = true,
    isEnabled = function() return true end,
    status = function() return L["Fonts, colors and integrations"] end,
    ownsPage = function(name) return GUI.IsGlobalPage(name) end,
    onEnter = function()
        -- Already up -- unless Profiles was over it (_leavingProfiles), when
        -- the view and page still have to come back.
        if GUI.GlobalView and not GUI._leavingProfiles then return end
        GUI:EnterView(true)
        GUI.SelectTab(GUI:LastTabInView())
    end,
    onEnterForPage = function() GUI:EnterView(true) end,
})

-- ============================================================
-- VIEW MODULES: HOME, MODULES -- AND A PLACEHOLDER: UNITS
-- A view is a full-window page of its own over the rect Binds' panel uses
-- (Home: GUI/Pages/Home.lua, Modules: GUI/Pages/ModulesPage.lua); a
-- placeholder shows a "coming in a later update" panel until its page is
-- built. Like GLOBAL they leave the mode under them exactly as it is -- no
-- test-mode or unlock hand-over, no mover session to end -- and leaving one
-- puts the normal content back first.
-- GUI:ShowPlaceholderContent (GUI/Panel.lua) hides the sidebar and page and
-- hands over to GUI:PaintPlaceholderPanel (GUI/Rail.lua), which shows the
-- module's view, or the placeholder panel when it has none.
-- ============================================================

local function ViewModule(def)
    if not def.view then def.placeholder = true end
    def.sidebar = false
    def.accent = def.accent or function() return GUI.Colors.text end
    def.onEnter = function()
        GUI.PlaceholderView = def.id
        GUI:ShowPlaceholderContent(def)
        GUI.UpdateThemeColors()
    end
    def.onLeave = function()
        GUI.PlaceholderView = nil
        if def.hideView then def.hideView() end
        GUI:ShowNormalContent()
    end
    GUI:RegisterModule(def)
end

ViewModule({
    id = "home",
    label = function() return L["Home"] end,
    icon = ICONS .. "home.png",
    order = 0,
    slot = "top",
    dividerAfter = true,
    noTile = true,
    view = true,
    -- Late-bound: the page files load after this one.
    showView = function() if GUI.ShowHomeView then GUI:ShowHomeView() end end,
    hideView = function() if GUI.HideHomeView then GUI:HideHomeView() end end,
})

ViewModule({
    id = "units",
    label = function() return L["Unit Frames"] end,
    railLabel = function() return L["Units"] end,
    icon = ICONS .. "person.png",
    order = 15,
    slot = "top",
    accent = function() return GUI.UnitsAccent end,
    comingSoon = true,
    status = function() return L["Coming in a later update."] end,
    description = function() return L["Player, target, target of target, focus, pet and boss frames."] end,
})

ViewModule({
    id = "modules",
    label = function() return L["Modules"] end,
    icon = ICONS .. "extension.png",
    order = 80,
    slot = "bottom",
    noTile = true,
    view = true,
    showView = function() if GUI.ShowModulesView then GUI:ShowModulesView() end end,
    hideView = function() if GUI.HideModulesView then GUI:HideModulesView() end end,
})

-- ============================================================
-- PROFILES -- a sidebar module of its own (GUI/Pages/Profiles.lua)
-- Not tied to Party or Raid: its pages are mode-neutral (THE PROFILES SIDEBAR,
-- GUI/GUI.lua) and a page that needs a mode asks on the page. Like GLOBAL it
-- leaves the frame mode under it exactly as it is -- no test-mode or unlock
-- hand-over, no mover session to end -- except from BINDS, where it steps back
-- onto the frame mode BINDS was entered from, as GLOBAL does (GUI:EnterView).
-- ☠ GUI.GlobalView IS LEFT ALONE UNDERNEATH. Profiles is read first everywhere
-- (CurrentModuleId, GUI:IsTabInView, GUI.CurrentAccent), and its onLeave flags
-- the one switch that follows (GUI._leavingProfiles) so GLOBAL and Party/Raid
-- bring their view and page back even when the state under it already says them.
-- ============================================================

local function EnterProfilesView()
    if GUI.SelectedMode == "clicks" then
        GUI.SelectedMode = GUI._lastFrameMode or "party"
        -- The index is per frame mode, and BINDS had none.
        if DF.Search and DF.Search.InvalidateRegistry then DF.Search:InvalidateRegistry() end
    end
    GUI.ProfilesView = true
    GUI:SyncSelectedModule()
    if GUI.CurrentAccent then GUI:SetAccent(GUI.CurrentAccent()) end
    -- The page is the caller's to pick, so the redirect off a page this view
    -- does not list is held off, as GUI:EnterView does.
    local held = GUI._redirectingTab
    GUI._redirectingTab = true
    GUI:ShowNormalContent()
    GUI._redirectingTab = held
end

GUI:RegisterModule({
    id = "profiles",
    label = function() return L["Profiles"] end,
    icon = ICONS .. "account_circle.png",
    order = 85,
    slot = "bottom",
    noTile = true,
    sidebar = true,
    -- The page's own accent (GUI.ProfilesPageAccents, GUI/GUI.lua): the rail
    -- item and deck 2's crumb follow the page selected, teal when none is.
    accent = function()
        if GUI.ProfilesView and GUI.CurrentAccent then return GUI.CurrentAccent() end
        return GUI.GlobalAccent or GUI.Colors.text
    end,
    isEnabled = function() return true end,
    ownsPage = function(name) return GUI.IsProfilesPage and GUI.IsProfilesPage(name) or false end,
    -- tabId: a Profiles page to land on (Home's profile link asks for Manage);
    -- none, the page Profiles showed last.
    onEnter = function(tabId)
        local want = tabId and GUI.IsProfilesPage and GUI.IsProfilesPage(tabId)
            and GUI.Tabs and GUI.Tabs[tabId] and tabId or nil
        if GUI.ProfilesView and not want then return end
        EnterProfilesView()
        local page = want or GUI:LastTabInView()
        if page then GUI.SelectTab(page) end
    end,
    onEnterForPage = function() EnterProfilesView() end,
    onLeave = function()
        GUI.ProfilesView = false
        GUI._leavingProfiles = true
    end,
})

-- ★ SWITCH THE FRAME MODE UNDER PROFILES, WITHOUT LEAVING IT. For a Profiles
-- page whose in-page Party / Raid choice IS the frame mode (Changed Settings'
-- scope picker: its report is built from the search index, which is per mode).
-- It is the whole Party/Raid switch -- the sync, the locks, test mode carried
-- across -- so it refuses what the Party/Raid tabs refuse: a locked tab (Auto
-- Layout editing) and a running mover session (ended first, then replayed).
-- Returns true when the mode under the view is `mode` afterwards.
function GUI:SetUnderlyingFrameMode(mode)
    if mode ~= "party" and mode ~= "raid" then return false end
    if GUI.SelectedMode == mode then return true end
    if GUI:IsModuleLocked("group", mode) then return false end
    local B = DF.MoverBridge
    if B and B.IsSessionActive and B:IsSessionActive() and B.EndSessionThen then
        B:EndSessionThen(function() GUI:SetUnderlyingFrameMode(mode) end)
        return false
    end
    if mode == "raid" then EnterRaid() else EnterParty() end
    GUI:SyncSelectedModule()
    -- The switch painted the MODE's accent; Profiles wears its page's.
    if GUI.ProfilesView and GUI.CurrentAccent then
        GUI:SetAccent(GUI.CurrentAccent())
        GUI.UpdateThemeColors()
    end
    return GUI.SelectedMode == mode
end

-- ============================================================
-- SIDEBAR MODULES OF THEIR OWN, AND PAGE PROVIDERS
-- ------------------------------------------------------------
-- A module that owns pages of its own -- a sidebar like Profiles', optional
-- deck-2 tabs like Group Frames' -- registered by a page provider
-- (DF.GUIPageProviders, DandersFrames/GUI/GUI.lua) rather than written in here.
--
--   GUI:SetPageModule(pageName, moduleId)   -- the page is on that module's
--                                           -- sidebar and nobody else's
--   GUI:SidebarModule(def)                  -- register (or replace) the module
--
-- def, beyond RegisterModule's fields:
--   onTab(tabId)        -- the module's own tab state changes (tabs only);
--                          activeTab() must then report it
--   buildKey(pageName)  -- which retained build of a page this is: one build is
--                          kept per key (BuildPage, GUI/Panel.lua). Typically the
--                          current tab, so each tab keeps its own build the way
--                          Party and Raid do. nil: one build for the module.
--   buildDb(pageName)   -- the settings table the page builds against (the
--                          `db` handed to the builder). nil: DF.db[mode].
-- A page may carry page.buildKey / page.buildDb itself; those win.
-- A module whose tabs each have PAGES OF THEIR OWN (rather than one build of
-- each page per tab) adds:
--   pageInView(name)    -- false: the page is not on the tab showing (the
--                          sidebar leaves it out)
--   tabForPage(name)    -- the tab a page lives on; asking for the page moves
--                          there (SelectTab, search results, links)
--   pageForTab(tabId, from) -- the page to land on when the tab changes, given
--                          the page showing (`from`, may be nil)
-- ⚠ def.accent must not call GUI.CurrentAccent: CurrentAccent asks it.
-- ============================================================

function GUI:SetPageModule(pageName, moduleId)
    if type(pageName) ~= "string" then return end
    GUI.ModulePageOwner[pageName] = moduleId
end

-- A module whose tabs each have pages of their own (def.pageInView(name) /
-- def.tabForPage(name)): is this page on the tab showing, and does asking for it
-- mean moving to another tab? Both answer "yes, nothing to do" for any other page.
function GUI:ModulePageInView(name)
    local owner = name and GUI.ModulePageOwner[name]
    local def = owner and modules[owner]
    if def and def.pageInView then return def.pageInView(name) ~= false end
    return true
end

function GUI:PageWantsOtherTab(name)
    local owner = name and GUI.ModulePageOwner[name]
    local def = owner and modules[owner]
    if not (def and def.tabForPage and def.activeTab) then return false end
    local want = def.tabForPage(name)
    return want ~= nil and want ~= def.activeTab()
end

-- Show a sidebar module's view: its sidebar, its accent, the mode left as it is
-- underneath. Selects no page (the caller does), so the redirect off a page this
-- view does not list is held off -- as GUI:EnterView does.
function GUI:EnterModuleView(id)
    if GUI.SelectedMode == "clicks" then
        GUI.SelectedMode = GUI._lastFrameMode or "party"
        if DF.Search and DF.Search.InvalidateRegistry then DF.Search:InvalidateRegistry() end
    end
    GUI.ModuleView = id
    GUI:SyncSelectedModule()
    if GUI.CurrentAccent then GUI:SetAccent(GUI.CurrentAccent()) end
    local held = GUI._redirectingTab
    GUI._redirectingTab = true
    GUI:ShowNormalContent()
    GUI._redirectingTab = held
end

function GUI:SidebarModule(def)
    if type(def) ~= "table" or type(def.id) ~= "string" then
        DF:DebugError("GUI", "SidebarModule: a module needs a string id")
        return nil
    end
    local id = def.id
    def.sidebar = true
    def.sidebarModule = true   -- GUI:RestoreModuleOnOpen (GUI/Rail.lua) reopens it
    def.placeholder, def.comingSoon, def.view = nil, nil, nil
    def.ownsPage = def.ownsPage or function(name) return GUI.ModulePageOwner[name] == id end
    def.onEnter = function(tabId)
        local entering = GUI.ModuleView ~= id
        local from = (not entering) and GUI.CurrentPageName or nil
        if entering then GUI:EnterModuleView(id) end
        if tabId ~= nil and def.onTab then def.onTab(tabId) end
        -- Pages of their own per tab: the sidebar re-lists for the tab, and the
        -- page moves to that tab's counterpart.
        if def.pageInView and GUI.UpdateTabLayout then GUI:UpdateTabLayout() end
        if def.pageForTab then
            local page = def.pageForTab(tabId, from or GUI:LastTabInView())
            if page then GUI.SelectTab(page) end
            if not entering then GUI.UpdateThemeColors() end
        elseif entering then
            local page = GUI:LastTabInView()
            if page then GUI.SelectTab(page) end
        else
            -- A tab switch inside the module: the page swaps to that tab's build
            -- (its buildKey moved), cached rather than rebuilt.
            GUI:RefreshCurrentPageForModeSwitch()
            GUI.UpdateThemeColors()
        end
    end
    def.onEnterForPage = function(tabId, forPage)
        -- A page that lives on one tab takes the module to that tab.
        if forPage and def.tabForPage then tabId = def.tabForPage(forPage) or tabId end
        if GUI.ModuleView ~= id then GUI:EnterModuleView(id) end
        if tabId ~= nil and def.onTab then def.onTab(tabId) end
        if def.pageInView and GUI.UpdateTabLayout then GUI:UpdateTabLayout() end
    end
    def.onLeave = function()
        GUI.ModuleView = nil
        -- The view under it comes back on the next onEnter -- the flag Profiles
        -- sets for the same reason (LeaveGlobalTo, GLOBAL's onEnter).
        GUI._leavingProfiles = true
    end
    return GUI:RegisterModule(def)
end

-- The retained-build key and the settings table for a page (BuildPage). nil
-- from either: the ordinary answer (the frame mode, DF.db[mode]).
local function PageBuildFn(page, field)
    local fn = page[field]
    if fn == nil then
        local owner = page.tabName and GUI.ModulePageOwner[page.tabName]
        local def = owner and modules[owner]
        fn = def and def[field]
    end
    return fn
end

function GUI.PageBuildKey(page)
    local fn = page and PageBuildFn(page, "buildKey")
    if fn then return fn(page.tabName, page) end
end

function GUI.PageBuildDb(page)
    local fn = page and PageBuildFn(page, "buildDb")
    if fn then return fn(page.tabName, page) end
end

-- Where a builder's in-page link to page `id` should go when `page` runs it. A
-- page drawn from another page's builder against a table of its own (a module's
-- page) may point the builder's links at pages of its own:
--   page.mapPageLink(id) -> a page name, or false (no counterpart: leave the link
--   out), or nil (the id itself).
-- rawget: a headless frame answers an unset key with a no-op function.
function GUI.PageLinkFor(page, id)
    local map = type(page) == "table" and rawget(page, "mapPageLink")
    if type(map) == "function" then
        local mapped = map(id)
        if mapped ~= nil then return mapped end
    end
    return id
end

-- Run every page provider, in the order they were added. Called by DF:CreateGUI
-- (GUI/Panel.lua) after the built-in pages exist and before the rail is first
-- painted. One that throws is reported and skipped; the rest still run.
function GUI:RunPageProviders(CreateCategory, CreateSubTab, BuildPage)
    local list = DF.GUIPageProviders
    if type(list) ~= "table" then return end
    for i = 1, #list do
        local provider = list[i]
        if type(provider) == "function" then
            local ok, err = pcall(provider, GUI, CreateCategory, CreateSubTab, BuildPage, L)
            if not ok then
                DF:DebugError("GUI", "page provider %d failed: %s", i, tostring(err))
            end
        end
    end
end

GUI:SyncSelectedModule()
