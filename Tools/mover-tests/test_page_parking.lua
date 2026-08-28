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
        -- THE REAL TABLE, off the kit loaded in section 1. Search.lua reads its
        -- card and column geometry off the host at file scope now instead of
        -- carrying literals justified by a comment, so this is also the check
        -- that the keys it reads are the keys the kit actually publishes.
        SettingsBox = UILIB.SettingsBox,
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

    -- ☠ THE OPT-OUT. The changed-settings ledger BUILDS ITSELF from this
    -- registry, so refreshing it from here calls back into the half-built thing
    -- -- unbounded recursion, and wrong even one level deep (a nested Refresh
    -- resets a page's children and strands what the outer pass already placed).
    -- Any page may set `skipSearchIndex`; this one is the reason the flag exists.
    local optedOut = fakePage("profiles_changed", false)
    optedOut.skipSearchIndex = true

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

    -- The opted-out page is not touched AT ALL: not built, not shown, not
    -- hidden, and not parked (nothing adopted it, so there is nothing to park).
    eq(optedOut.builds, 0, "index: a skipSearchIndex page is never refreshed")
    eq(optedOut.shows, 0, "index: ...never shown")
    eq(optedOut.hides, 0, "index: ...never hidden")
    eq(parkedSet["profiles_changed"], nil, "index: ...and never parked")
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
    -- The RIGHT offset is the scrollbar GUTTER, not the inset -- see THE CONTENT
    -- CORRIDOR in Panel.lua. Both offsets have to survive the park/adopt trip, so
    -- both are stashed on the page and both are re-asserted.
    eq(countOf('page:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -gutter, inset)'), 2,
       "panel: ...and so does the bottom-right one, at the gutter rather than the inset")
    has("page._contentInset = inset", "the inset is kept on the page for AdoptPage to reuse")
    has("page._contentGutter = gutter", "...and so is the gutter")

    -- ---- THE CONTENT CORRIDOR, ACCOUNTED ----------------------------
    -- The strip between the right edge of a widget on a page and the right edge
    -- of the settings window. It is not decoration: a feature row's popout docks
    -- OUTSIDE the window and runs a beam back across this strip, so its total is
    -- the length of that beam, and it used to be five literals spread over four
    -- functions with no one place that added them up.
    --
    -- The window-chrome half is pinned as SOURCE (Panel.lua does not load
    -- headlessly) and the widget half comes off the REAL kit, so the sum below
    -- breaks if either side moves without the other being reconsidered.
    has("windowPad = 12,", "the window margin is declared in PageBox, not inline")
    has("navGap    = 8,", "...and so is the gap to the nav pane")
    has("inset     = 8,", "...and the content box's inset")
    has("gutter    = GUI.Scroll.gutter,", "...and the right edge is the KIT's scrollbar gutter")

    -- The child is the viewport, DERIVED, at both sites that size it -- the build
    -- and every relayout. Each used to carry its own `- 30`.
    eq(countOf("GUI.PageChildWidth("), 4,
       "panel: one helper defines the child width, and all three consumers call it")
    has("self.child:SetWidth(GUI.PageChildWidth(GUI.contentFrame:GetWidth()))",
        "the relayout sizes the child through the helper, not a copy of its arithmetic")
    has("SnapLen(page, GUI.PageChildWidth(content:GetWidth() or 0))",
        "...and so does the build")
    -- The usable width is the CHILD less the page's two margins, so it cannot
    -- drift from the child the way a second literal did.
    has("local childWidth = GUI.PageChildWidth(contentWidth)",
        "the column maths measures against the CHILD, not the content box outside it")
    -- ...and the usable width is now a HELPER rather than a line inside the
    -- layout loop, because a page needs the same number: a full-width feature
    -- band has to be BUILT at the width the loop is about to stretch it to, or
    -- its children lay out at the group's constructed 280 on the first pass.
    has("function GUI.PageUsableWidth(childWidth)",
        "the usable width is a helper, so a page can ask for it too")
    has("return (childWidth or 0) - 2 * SettingsBox.colMargin",
        "...still derived from the child and the page's own margin")
    has("local usableWidth = GUI.PageUsableWidth(childWidth)",
        "...and the layout loop goes through it rather than keeping a copy")
    -- Rule 2 of the two-column test: column 2 has to fit the rect the ScrollFrame
    -- clips to, or its box loses its right border at the cutover.
    has("and (math.floor(contentWidth / 2) + SettingsBox.group) <= childWidth",
        "two columns require column 2 to fit the viewport, not just to clear column 1")
    -- The bar is PINNED into the gutter. Left on ScrollFrameTemplate's own
    -- anchors it floats outside the viewport, which is how the corridor came to
    -- reserve the gutter twice and show it once.
    has("GUI.PinScrollBar(page, content, -inset, inset)",
        "the page's scrollbar is pinned into the gutter against the content box")
    -- The two numbers the band's width arithmetic below borrows from the window
    -- rather than from the kit. Pinned so a wider nav (or a bigger default
    -- window) fails here instead of quietly making 521 wrong.
    has("tabFrame:SetWidth(SnapLen(frame, 155))", "the nav pane is 155 wide")
    -- ⚠ THE DEFAULT ONLY. A stored guiDb.width wins over it, so this number is
    -- what a fresh install opens at and nothing else. It came down from 760x520:
    -- 760 was just over the two-column cutover, so the shipped window opened
    -- two-column, and the height went up because a one-column page is longer.
    has("local defaultWidth  = GUI.WindowDefaults.width",
        "...and the window's default size comes from the resident declaration")
    has("local defaultHeight = GUI.WindowDefaults.height", "...both halves of it")
    -- The resize FLOOR is deliberately NOT the default -- a user who wants the
    -- window smaller than it opens can still drag it there.
    has("local minWidth, minHeight = 520, 400", "...with the resize floor left below it")

    do
        local PAGE_WINDOW_PAD, PAGE_INSET = 12, 8
        local box, scroll = UILIB.SettingsBox, UILIB.Scroll
        eq(scroll.gutter, scroll.bar + scroll.pad,
           "corridor: the gutter is the bar plus its air, derived not declared")
        eq(UILIB.PopoutContentWidth, box.group - 2 * box.pad,
           "corridor: a popout's content width IS a settings group's inner width")
        check(box.minCol > box.group,
              "corridor: the two-column minimum exceeds a group's width, so columns never touch")

        -- Widget edge -> window edge, in order outwards.
        local corridor = box.pad          -- inside the group box
                       + box.colMargin    -- group box -> scroll child
                       + scroll.gutter    -- child -> content box (the bar lives here)
                       + PAGE_WINDOW_PAD  -- content box -> window
        eq(corridor, 41, "corridor: a full-width widget's right edge sits 41px inside the window")
        -- What is BLANK in that 41: the bar occupies its own gutter and the group
        -- padding is the box reading as a box, so only these two are dead air.
        eq(corridor - scroll.gutter - box.pad, 17,
           "corridor: ...of which 17px is blank (was 39 when the gutter was paid for twice)")
        -- The page viewport is inset by the gutter on the right, NOT by `inset`,
        -- and the child then fills it -- the change that returned 8px to the page.
        eq(scroll.gutter - PAGE_INSET, 6,
           "corridor: the right edge gives up 6px to the bar and takes back 14 from the child")

        -- ---- AND THE SAME CORRIDOR FOR A FEATURE ROW ----------------
        -- A full-width feature band is a CHROMELESS group, not a bare widget on
        -- the page: no fill, no border, but the standard box padding. That is
        -- what puts a row's right edge on the SAME line a slider's value box in
        -- an ordinary box lands on -- the corridor above, unchanged -- instead of
        -- 10px further out where a padding-less container would put it.
        local bandRowEdge = box.pad + box.colMargin + scroll.gutter + PAGE_WINDOW_PAD
        eq(bandRowEdge, corridor,
           "corridor: a full-width feature row ends on the same line as a boxed widget")

        -- What the band actually BUYS, at the 640 default window: the content box
        -- is the window less its two margins and the nav pane, the child is that
        -- less the inset and the gutter, and a row is the child less the page's
        -- two margins and the band's two paddings. The old 280-box row stopped
        -- well inside the window; this is the number that replaces it.
        -- The nav pane's width and the gap beside it are Panel.lua's, pinned as
        -- source above (`navGap    = 8,`) and by the nav's own SetWidth(155).
        --
        -- ☠ 640 IS PINNED TO THE DECLARATION, not copied into this test. The
        -- window's default size is resident (GUI.WindowDefaults) because `/df
        -- resetgui` writes it back from Core.lua, which can run before this
        -- companion has ever loaded -- and the two used to be separate literals
        -- free to disagree.
        local NAV_W, NAV_GAP, DEFAULT_WIN = 155, 8, 640
        do
            local gui = df_file_source("GUI/GUI.lua")
            check(gui:find("GUI.WindowDefaults = { width = 640, height = 600 }", 1, true) ~= nil,
                  "band: the shipped default really is 640x600")
            local core = df_file_source("Core.lua")
            check(core:find("DF.GUI.WindowDefaults) or { width = 640, height = 600 }", 1, true) ~= nil,
                  "band: ...and /df resetgui restores that, not a literal of its own")
        end
        local contentW = DEFAULT_WIN - PAGE_WINDOW_PAD - NAV_W - NAV_GAP - PAGE_WINDOW_PAD
        local childW   = contentW - PAGE_INSET - scroll.gutter
        local rowW     = childW - 2 * box.colMargin - 2 * box.pad
        check(contentW < box.minCol * 2 + box.colGutter,
              "band: the default window is a ONE-column page, so the band is the whole of it")
        eq(rowW, 401, "band: a feature row is 401 wide at the default window")
        -- ...against what it was inside the 280 box: the inner width of a group.
        eq(rowW - (box.group - 2 * box.pad), 141,
           "band: which is 141px wider than the same row inside a 280 box")
        -- And the boxed row's right edge really was that far inside the window.
        eq(childW - (box.colMargin + box.pad + (box.group - 2 * box.pad))
           + scroll.gutter + PAGE_WINDOW_PAD, 182,
           "band: the boxed row used to stop 182px inside the window; the band stops at 41")

        -- ☠ THE CUTOVER IS STILL ABOVE THE DEFAULT, AND WAS ALREADY ABOVE THE
        -- OLD ONE. 640 is not what makes the shipped window single-column -- the
        -- cutover is 590 content pixels, which is a 777px window once the two
        -- margins, the nav and its gap are paid for, so 760 was under it too.
        -- Pinned so "narrowing the default made everything one column" cannot be
        -- believed, and so a future default that crosses 777 fails here.
        local cutoverWindow = box.minCol * 2 + box.colGutter
                            + PAGE_WINDOW_PAD + NAV_W + NAV_GAP + PAGE_WINDOW_PAD
        eq(cutoverWindow, 777, "band: two columns need a 777px window")
        check(DEFAULT_WIN < cutoverWindow, "band: ...which the 640 default is under")
        check(760 < cutoverWindow, "band: ...and so was the 760 it replaced")
    end

    -- ---- SelectTab: park the outgoing, adopt the incoming ------------
    has("if k ~= name then GUI:ParkPage(page) end",
        "SelectTab parks every page except the one it is about to show")
    local adoptAt = src:find("GUI:AdoptPage(GUI.Pages[name])", 1, true)
    local showAt  = src:find("GUI.Pages[name]:Show()", 1, true)
    check(adoptAt ~= nil, "panel: SelectTab adopts the incoming page")
    check(showAt ~= nil, "panel: SelectTab still shows it")
    check(adoptAt and showAt and adoptAt < showAt,
          "panel: ...and adopts it BEFORE showing it, never while detached")

    -- ---- THE PAGE CROSSFADE, and its four safety rails ---------------
    -- Pages cross-fade on a tab switch: they occupy the identical rect, so both
    -- can be visible for ~90ms with no layout to jump. That puts a page in a
    -- state the parking work was built to prevent -- shown, parented, and NOT the
    -- current one -- so every way out of it is pinned here.
    --
    -- 1. It only happens when there is something to cross-fade FROM: a visible
    --    outgoing page, a different one arriving, and a window already on screen.
    --    The first page of a window-open gets none of it.
    has("local fading = frame:IsShown()", "the crossfade needs a window already on screen")
    has("and leavingTab and leavingTab ~= name", "...a DIFFERENT page to arrive at")
    has("if fading and not fading:IsShown() then fading = nil end",
        "...and an outgoing page that is actually visible")
    -- 2. The fading page is the ONE page the hide/park loop skips.
    has("if page ~= fading then", "the loop leaves the fading page shown, and only that one")
    -- 3. The fades start AFTER the incoming page is adopted, shown and rebuilt --
    --    the expensive part of a tab switch -- so nothing stalls mid-animation and
    --    no half-laid-out page is ever rendered.
    local buildAt = src:find("GUI.Pages[name]:RefreshCached()", 1, true)
    local fadeAt  = src:find("GUI.Fx.FadeOut(fading, 0.09", 1, true)
    local fadeInAt = src:find("GUI.Fx.FadeIn(GUI.Pages[name], 0.12)", 1, true)
    check(buildAt and fadeAt and buildAt < fadeAt,
          "panel: the crossfade starts after the incoming page is built, not before")
    check(fadeInAt and fadeAt < fadeInAt, "panel: out and in are started together")
    -- 4. Three ways the fade can be interrupted, and none of them may strand a
    --    page: the deferred park asks again before firing, the window's close
    --    finishes the job the stopped animation cannot, and PARKING ITSELF
    --    cancels -- which is what makes "a parked page is at alpha 1" true for
    --    every caller, search's index pass included.
    has("if GUI.Pages[GUI.CurrentPageName] == fading then return end",
        "the deferred park re-checks, so spamming two tabs cannot park the visible one")
    has("if GUI.ParkPage and GUI._fadingPage then",
        "closing the window inside a fade still parks the page that was leaving")
    local parkAt = src:find("function GUI:ParkPage(page)", 1, true)
    local cancelAt = src:find("if GUI.Fx and GUI.Fx.Cancel then GUI.Fx.Cancel(page) end", 1, true)
    check(parkAt and cancelAt and cancelAt > parkAt and cancelAt - parkAt < 400,
          "panel: ParkPage cancels any running fade, so a parked page is never left translucent")

    -- ---- the shell's TWO shared selection markers --------------------
    -- The behaviour is UI:CreateSelectionMarker's and is tested against the real
    -- factory in test_selection_marker.lua. What only the source can say is that
    -- the shell actually WIRED it -- and, the part that would silently draw two
    -- bars at once, that no member still carries a stripe of its own.
    has('GUI:CreateSelectionMarker(deck2, { axis = "x", thickness = 3 })',
        "the mode tabs share one underline, parented to deck 2")
    has('GUI:CreateSelectionMarker(tabContainer, { axis = "y", thickness = 3 })',
        "...and the nav shares one rail, parented to the scroll child so it scrolls")
    has("modeUnderline:SetTo(activeMode, activeModeAccent, not frame:IsShown())",
        "the underline follows the active mode, instant while the window is hidden")
    has("navMarker:SetTo(GUI.Tabs[name], nc, not frame:IsShown())",
        "...and the rail follows the selected page, by the same rule")
    -- Three tabs, three opt-outs -- plus the one in the comment that explains it.
    eq(countOf("tabStripe = false"), 4,
       "panel: all three mode tabs decline StyleButton's own stripe")
    check(src:find("btn.accent", 1, true) == nil,
          "panel: and no nav row builds a left accent bar of its own any more")

    -- ---- the two OVERLAY scroll panes --------------------------------
    -- The variant's own behaviour is tested against the real Theme.lua in
    -- test_overlay_scrollbar.lua. Source can only say which panes opted in --
    -- and the point of pinning it is that it is exactly TWO: the nav and the
    -- page, the panes you look at while you work. Everything else in the addon
    -- (dialogs, pickers, the changelog on this very file) keeps the plain bar.
    has("StyleScrollBar(tabScroll, { overlay = true })", "the nav's bar is an overlay")
    has("StyleScrollBar(page, { overlay = true })", "...and so is every settings page's")
    eq(countOf("overlay = true"), 2, "panel: and nothing else in the window opted in")
    has("StyleScrollBar(clScroll)", "the changelog pane keeps the plain bar")

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
