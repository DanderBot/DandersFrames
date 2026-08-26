local NS = ...

-- ============================================================
-- PAGE PARKING + THE ACCENT LISTENER REGISTRY
-- ------------------------------------------------------------
-- Two fixes that came out of the same performance hunt.
--
-- 1. THE PAGE DOCK (DandersFrames_Options/GUI/Panel.lua). Settings search
--    indexes by BUILDING every page, so one search left all 34 of them --
--    700+ widgets -- parented, hidden, under the settings window. From then on
--    showing that window measured 7774ms and hiding it about 2000ms, with only
--    ~52 of our own OnShow handlers firing in the whole 7.7 seconds: the cost
--    is the ENGINE walking a huge hidden subtree, not Lua we run. A page that
--    is not the one on screen is now REPARENTED to a detached dock, and the
--    same measurement drops to 90ms.
--
-- 2. THE HOST ACCENT LISTENER LIST (DandersUI/Core.lua). It held bare
--    functions and only ever grew -- CreateGroupBox added one closure per box
--    and nothing could take it off again.
--
-- ☠ WHAT THIS FILE CAN AND CANNOT REACH. DandersUI's files load headlessly, so
-- section 1 drives the REAL Core.lua and Widgets.lua. Features/Search.lua takes
-- its host off the `DandersFrames` global, so section 2 drives the REAL
-- BuildFullRegistry against a stub GUI that records what it was asked to park.
-- GUI/Panel.lua is far too tangled in the live client to load, so section 3
-- reads its SOURCE and pins the call sites -- weaker than a behavioural test and
-- deliberately limited to structure that cannot be checked any other way.
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME ACROSS EVERY TEST FILE. This file swaps
-- LibStub (so loading the real DandersUI does not claim the "DandersUI-1.0"
-- slot that test_registry_events registers a stub into), CreateFrame and the
-- `DandersFrames` global. All three are restored before it returns.
-- ============================================================

local savedLibStub, savedCreateFrame, savedDF = LibStub, CreateFrame, DandersFrames
local savedScreenSize, savedUIParent = GetPhysicalScreenSize, UIParent

-- ============================================================
-- 1. THE ACCENT LISTENER REGISTRY -- real DandersUI
-- ============================================================
-- ⚠ FakeUIFrame's catch-all __index hands back a no-op FUNCTION for any key it
-- does not know, which the pixel-border code reads as "this frame already has a
-- border/colour table" and then indexes. Seeding the two fields false is enough
-- to send it down its create-from-scratch path.
--
-- ⚠ And this has to be in place BEFORE the load: DandersUI's files cache
-- CreateFrame as a file local, so swapping the global afterwards changes
-- nothing for code already loaded.
local function themedFrame()
    local f = FakeUIFrame()
    f._pxBorder, f._pxColor = false, false
    return f
end

local UILIB
do
    local tns = {}
    LibStub = { NewLibrary = function() return {} end }
    CreateFrame = function() return themedFrame() end
    -- The pixel-border maths wants a screen to derive its device pixel from.
    GetPhysicalScreenSize = function() return 2560, 1440 end
    UIParent = UIParent or themedFrame()
    load_ui_file_into("Core.lua", tns)
    load_ui_file_into("Theme.lua", tns)
    load_ui_file_into("Fonts.lua", tns)
    load_ui_file_into("Widgets.lua", tns)
    LibStub, CreateFrame = savedLibStub, savedCreateFrame
    UILIB = tns.__DandersUI
    check(UILIB ~= nil, "accent: the real DandersUI loads headlessly")
    check(type(UILIB.CreateGroupBox) == "function", "accent: ...far enough to reach CreateGroupBox")
end

local function newHost(name)
    return UILIB.NewHost(UILIB, name, { L = setmetatable({}, { __index = function(_, k) return k end }) })
end

-- ---- back compatibility: an owner is optional -----------------------
do
    local host = newHost("acc_plain")
    local hits = 0
    host:RegisterAccentListener(function() hits = hits + 1 end)
    host:SetAccent(0.1, 0.2, 0.3)
    eq(hits, 1, "accent: RegisterAccentListener(fn) with no owner still fires")
    eq(#host.accentListeners, 1, "accent: ...and stays on the list")
    host:SetAccent(0.4, 0.5, 0.6)
    eq(hits, 2, "accent: ...on every change")
    -- An unchanged colour is not a change, so nothing is called.
    host:SetAccent(0.4, 0.5, 0.6)
    eq(hits, 2, "accent: ...but not when the colour did not move")
end

-- ---- an owned listener can be dropped -------------------------------
do
    local host = newHost("acc_owned")
    local owner, hits = {}, 0
    local entry = host:RegisterAccentListener(function() hits = hits + 1 end, owner)
    check(entry ~= nil, "accent: registering with an owner hands back a handle")
    host:SetAccent(0.1, 0.2, 0.3)
    eq(hits, 1, "accent: an owned listener fires like any other")

    host:UnregisterAccentListener(owner)
    eq(#host.accentListeners, 0, "accent: unregistering by OWNER takes the entry off the list")
    host:SetAccent(0.7, 0.7, 0.7)
    eq(hits, 1, "accent: ...and it is not called again")
end

do
    local host = newHost("acc_byfn")
    local hits = 0
    local fn = function() hits = hits + 1 end
    host:RegisterAccentListener(fn, {})
    host:UnregisterAccentListener(fn)
    eq(#host.accentListeners, 0, "accent: unregistering by the FUNCTION works too")
    host:SetAccent(0.1, 0.2, 0.3)
    eq(hits, 0, "accent: ...and it never fires")
end

-- ---- a collected owner is compacted out on the next SetAccent -------
-- ⚠ This is the weak half, and it is honest about its reach: WoW never collects
-- a Frame, so a frame owner keeps its entry for the session and the UNREGISTER
-- path above is what actually bounds the list in the game. What is pinned here
-- is that the registry does not itself pin the owner alive, and that a dead
-- entry is dropped rather than called.
do
    local host = newHost("acc_weak")
    local liveHits, deadHits = 0, 0
    local keptOwner = {}
    host:RegisterAccentListener(function() liveHits = liveHits + 1 end, keptOwner)
    do
        local doomed = {}
        -- The closure must not capture the owner, or the entry would keep it alive.
        host:RegisterAccentListener(function() deadHits = deadHits + 1 end, doomed)
    end
    eq(#host.accentListeners, 2, "accent: two owned listeners registered")
    collectgarbage("collect")
    collectgarbage("collect")
    host:SetAccent(0.1, 0.2, 0.3)
    eq(#host.accentListeners, 1, "accent: the collected owner's entry is compacted away")
    eq(liveHits, 1, "accent: the surviving listener still fires")
    eq(deadHits, 0, "accent: the dead one does not")
end

-- ---- CreateGroupBox owns its listener -------------------------------
-- The leak, head-on: one box used to mean one permanent listener, so N rebuilds
-- meant N dead closures for every later SetAccent to walk and call.
do
    local host = newHost("acc_groupbox")
    -- The pixel border wants real geometry off every frame it touches, which the
    -- stub cannot invent -- and none of it is what is under test here. Swapped
    -- on the LIBRARY table, which is where CreateElementBackdrop looks it up.
    local savedApply = UILIB.ApplyPixelBorder
    UILIB.ApplyPixelBorder = function() end
    local parent = themedFrame()
    local boxes = {}
    for i = 1, 3 do boxes[i] = host:CreateGroupBox(parent, { title = "Box " .. i }) end
    UILIB.ApplyPixelBorder = savedApply

    eq(#host.accentListeners, 3, "groupbox: one listener per box, as before")
    for i = 1, 3 do
        check(type(boxes[i]._accentListener) == "function",
              "groupbox: the box keeps its own listener (" .. i .. ")")
    end
    -- Each is addressable BY ITS BOX, which is the whole point of the change.
    host:UnregisterAccentListener(boxes[2])
    eq(#host.accentListeners, 2, "groupbox: dropping one box drops exactly one listener")
    host:UnregisterAccentListener(boxes[1])
    host:UnregisterAccentListener(boxes[3])
    eq(#host.accentListeners, 0, "groupbox: ...and the list can be emptied again")
end

-- ============================================================
-- 2. SEARCH'S INDEX PASS PARKS WHAT IT BUILDS -- real Search.lua
-- ============================================================
do
    local DF = {}
    DF.L = setmetatable({}, { __index = function(_, k) return k end })
    DF.PartyDefaults = {}
    DF.RaidDefaults = {}
    function DF:DebugWarn() end

    local parked, adopted = {}, {}
    local GUI = {
        SelectedMode = "party",
        CurrentPageName = "general_frame",
        Pages = {},
    }
    function GUI:ParkPage(page)  parked[#parked + 1] = page.tabName end
    function GUI:AdoptPage(page) adopted[#adopted + 1] = page.tabName end
    DF.GUI = GUI

    local function fakePage(name, shown)
        local p = { tabName = name, tabLabel = name, _shown = shown or false,
                    builds = 0, shows = 0, hides = 0 }
        function p:IsShown() return self._shown end
        function p:Show() self._shown = true; self.shows = self.shows + 1 end
        function p:Hide() self._shown = false; self.hides = self.hides + 1 end
        function p:Refresh() self.builds = self.builds + 1 end
        function p:RefreshStates() end
        GUI.Pages[name] = p
        return p
    end

    -- The page on screen, plus three parked ones -- the shape after any tab
    -- switch has happened.
    local current = fakePage("general_frame", true)
    local others = {
        fakePage("general_settings", false),
        fakePage("auras_buffs", false),
        fakePage("text_designer", false),
    }

    DandersFrames = DF
    load_options_file_into("Features/Search.lua", NS)
    local Search = DF.Search
    check(Search ~= nil, "index: the file publishes DF.Search")

    Search:BuildFullRegistry()
    DandersFrames = savedDF

    -- Every page is BUILT -- that is what indexing is, and it is why the pages
    -- end up expensive enough to matter.
    eq(current.builds, 1, "index: the visible page is rebuilt")
    for _, p in ipairs(others) do
        eq(p.builds, 1, "index: every other page is built too (" .. p.tabName .. ")")
    end

    -- ...and every built page that was not the visible one goes back in the dock.
    eq(#parked, 3, "index: every page it built and hid is parked")
    local parkedSet = {}
    for _, n in ipairs(parked) do parkedSet[n] = (parkedSet[n] or 0) + 1 end
    for _, p in ipairs(others) do
        eq(parkedSet[p.tabName], 1, "index: parked exactly once (" .. p.tabName .. ")")
    end
    eq(parkedSet["general_frame"], nil, "index: the page on screen is never parked")

    -- The page the user is looking at is adopted and shown before this returns.
    eq(#adopted, 1, "index: exactly one page is adopted back")
    eq(adopted[1], "general_frame", "index: ...the one that was current")
    check(current:IsShown(), "index: ...and it is left shown")

    -- Regression guard on the behaviour that was already there.
    for _, p in ipairs(others) do
        check(not p:IsShown(), "index: the pages it built are left hidden (" .. p.tabName .. ")")
    end
    check(Search.RegistryBuilt, "index: the registry is marked built")
end

-- ============================================================
-- 3. THE PANEL'S CALL SITES -- source, not behaviour
-- ------------------------------------------------------------
-- ⚠ GUI/Panel.lua cannot be loaded headlessly (2600 lines of live client
-- surface), so these read the file. They pin STRUCTURE that has no other reach
-- from here: that the dock exists and is hidden, that the two helpers do what
-- their names say, and -- the part that actually broke -- that every call site
-- parks and adopts in the right order. A source check is a weak test and this
-- is the only place in the suite that should be using one.
-- ============================================================
do
    local src = options_file_source("GUI/Panel.lua")

    local function has(needle, msg)
        check(src:find(needle, 1, true) ~= nil, "panel: " .. msg)
    end
    local function countOf(needle)
        local n, from = 0, 1
        while true do
            local s = src:find(needle, from, true)
            if not s then return n end
            n, from = n + 1, s + 1
        end
    end

    -- ---- the dock itself --------------------------------------------
    has('GUI._pageDock = CreateFrame("Frame")', "the page dock is a detached, parentless frame")
    has("GUI._pageDock:Hide()", "...and is hidden")
    has("page:SetParent(GUI._pageDock)", "ParkPage moves the page into the dock")
    has("page:SetParent(content)", "AdoptPage brings it back under the content frame")

    -- ---- anchors survive the round trip -----------------------------
    -- `content` is named EXPLICITLY in both CreateSubTab and AdoptPage: a parked
    -- page has to keep measuring at full size, because search builds it there.
    eq(countOf('page:SetPoint("TOPLEFT", content, "TOPLEFT", inset, -inset)'), 2,
       "panel: the top-left anchor names content in both CreateSubTab and AdoptPage")
    eq(countOf('page:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -inset, inset)'), 2,
       "panel: ...and so does the bottom-right one")
    has("page._contentInset = inset", "the inset is kept on the page for AdoptPage to reuse")

    -- ---- SelectTab: park the outgoing, adopt the incoming ------------
    has("if k ~= name then GUI:ParkPage(page) end",
        "SelectTab parks every page except the one it is about to show")
    local adoptAt = src:find("GUI:AdoptPage(GUI.Pages[name])", 1, true)
    local showAt  = src:find("GUI.Pages[name]:Show()", 1, true)
    check(adoptAt ~= nil, "panel: SelectTab adopts the incoming page")
    check(showAt ~= nil, "panel: SelectTab still shows it")
    check(adoptAt and showAt and adoptAt < showAt,
          "panel: ...and adopts it BEFORE showing it, never while detached")

    -- ---- the window's own two edges ---------------------------------
    local onShowAt = src:find('frame:HookScript("OnShow"', 1, true)
    local onHideAt = src:find('frame:SetScript("OnHide"', 1, true)
    local adoptOnShow = src:find("if GUI.AdoptPage and GUI.Pages and GUI.CurrentPageName then", 1, true)
    local parkOnHide  = src:find("if GUI.ParkPage and GUI.Pages and GUI.CurrentPageName then", 1, true)
    check(onShowAt and adoptOnShow and adoptOnShow > onShowAt and adoptOnShow < onHideAt,
          "panel: the window's OnShow adopts the current page back out of the dock")
    check(onHideAt and parkOnHide and parkOnHide > onHideAt,
          "panel: ...and its OnHide parks it")
end

-- Everything this file swapped, put back -- one runtime serves every suite.
LibStub, CreateFrame, DandersFrames = savedLibStub, savedCreateFrame, savedDF
GetPhysicalScreenSize, UIParent = savedScreenSize, savedUIParent
