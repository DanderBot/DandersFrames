local NS = ...

-- ============================================================
-- FILTER DESIGNER PAGE BUILDERS -- FilterRegistry/UI/Options.lua
-- ------------------------------------------------------------
-- `auras_filterdesigner` was the last page in the aura family still an island,
-- and the last aura entry in WIDE_PAGES: a two-column master/detail that forced
-- a 640-wide window to 850 exactly as the two designers used to. It is also
-- where the converted pages send people -- Layout Groups' "Create Filter" and
-- "Manage Filters" both jump here -- so it was the one page in the family that
-- could still yank the window wider from inside a page that had just stopped
-- doing that.
--
-- ☠ AND THEN THE PAGE STOPPED BEING ONE FILTER'S SPELL LIST. e879d644 put the
-- master behind a popout row, which fixed the WIDTH and left the page answering
-- the wrong question: you could not see the list of filters and a filter's
-- contents at the same time, and you could never see two filters at once. The
-- page is now THE LIST OF FILTERS -- one popout row each -- and every row's panel
-- carries that filter's own header and its own spell list. Several claims in this
-- file were written against the master-row shape and are REWRITTEN below rather
-- than deleted: what they pinned still matters, it is just a different answer.
--
-- ☠ AND THE ISLAND IS STILL NOT FORKED. Every frame is built exactly as it always
-- was, anchored off the page child; the band arm takes three of those roots DOWN
-- and builds its own column beside them. That is the property this file exists to
-- pin -- a rowsMode test threaded through 2,700 lines of one closure would fork
-- every site it touched, and the two layouts would drift the first time anyone
-- edited one of them.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY -- it is welded to a real ScrollFrame, a
-- real settings group, GUI.contentFrame and DF.db -- so this file does what
-- test_auradesigner_page_builders does and asserts against the SOURCE.
--
-- What that buys, and what it does not:
--   the SHAPE is derived rather than hardcoded -- the band arithmetic below is
--   computed from the same constants the addon lays out with, so a retuned
--   window or scrollbar moves this test with it.
--   nothing about runtime behaviour. That the pixels land is an in-game check.
-- ============================================================

local SRC   = options_file_source("FilterRegistry/UI/Options.lua")
local AURAS = options_file_source("GUI/Pages/Auras.lua")
local PANEL = options_file_source("GUI/Panel.lua")

-- ============================================================
-- 1. WHICH LAYOUT THIS IS
-- ------------------------------------------------------------
-- `Add` is the tell, and it is the Aura Designer's own: a caller holding
-- BuildPage's Add can be served bands, one that cannot -- an older call site, or
-- classic -- gets the island. The host has to actually hand it over, which is
-- the half that is easy to leave out and impossible to see.
-- ============================================================
print("-- Filter Designer: which layout this is")
do
    check(SRC:find("function DF.BuildFilterDesignerPage(guiRef, pageRef, dbRef, Add, AddSpace)", 1, true) ~= nil,
          "layout: the builder takes the harness's Add and AddSpace")
    -- SCOPED TO THE PAGE'S OWN BUILDER CALL, not the file: Auras.lua also builds
    -- the Aura Designer, which has taken Add for several phases, so a file-wide
    -- find answers "does anything here pass Add" and passes with this call left
    -- exactly as it was.
    local call = AURAS:match("if DF%.BuildFilterDesignerPage then(.-)\n        end")
    check(call ~= nil, "layout: the page host's call to it can be read")
    call = call or ""
    check(call:find("DF.BuildFilterDesignerPage(GUI, self, db, Add, AddSpace)", 1, true) ~= nil,
          "layout: ...and the host actually hands them over")

    check(SRC:find("local rowsMode = (Add ~= nil) and (tools ~= nil)", 1, true) ~= nil,
          "layout: the band arm is gated on having an Add")
    check(SRC:find("not DF:IsClassicSettingsLayout()", 1, true) ~= nil,
          "layout: ...and on not being in the classic layout")

    -- THE SHELL IS REFUSED, DELIBERATELY. Asserted as the CALL form: the source
    -- names GUI:BuildDesignerShell in prose to say why it is not used, so a bare
    -- name search would fail on the very comment that records the decision.
    check(SRC:find("BuildDesignerShell(", 1, true) == nil,
          "layout: the page does not build a designer shell -- it is a list of filters")
    check(SRC:find("GUI:CreatePopoutPageTools(pageRef)", 1, true) ~= nil,
          "layout: it takes the shared popout tools, which is the part that fits")
end

-- ============================================================
-- 2. THE BANDS, AND THEIR ORDER
-- ------------------------------------------------------------
-- Within a column the Add() order IS the layout order. The actions that CREATE a
-- filter have to come before the list they create into, or the page reads back
-- to front.
--
-- ☠ REWRITTEN. This section used to pin five roots RE-HOMED from the island --
-- banner, chip row, master row, detail, freshness note. Three of those are no
-- longer bands at all: the chip row and the master panel and the detail are taken
-- DOWN, and what stands in their place is an action band and one band of rows.
-- ============================================================
print("-- Filter Designer: the bands, and their order")
do
    -- SCOPED TO AdoptBands' OWN BODY. Every one of these names is declared
    -- elsewhere in the same file -- `banner` is built by the island 2,500 lines
    -- earlier -- so a file-wide find answers "does this frame exist" and never
    -- "is it a band".
    local adopt = SRC:match("local function AdoptBands%(addFn%)(.-)\n        end")
    check(adopt ~= nil, "bands: the adopt pass can be read on its own")
    adopt = adopt or ""

    local atBanner = adopt:find("addFn(banner,", 1, true)
    local atGap    = adopt:find("addFn(bannerGap,", 1, true)
    local atAction = adopt:find("addFn(actionBand,", 1, true)
    local atRows   = adopt:find("addFn(filterBand,", 1, true)
    local atFresh  = adopt:find("addFn(freshHost,", 1, true)
    check(atBanner and atGap and atAction and atRows and atFresh,
          "bands: all five bands are added")
    check(atBanner < atGap,    "bands: the banner is first...")
    check(atGap < atAction,    "bands: ...then the rhythm's own band, which the banner does not own...")
    check(atAction < atRows,   "bands: ...then New and Import, above the list they create into...")
    check(atRows < atFresh,    "bands: ...then the filters themselves, then the database note")

    -- ☠ AND THE CHIP ROW IS STILL NOT A BAND -- but no longer because it is behind
    -- a Used By row. That row is GONE: "used by" is a fact about ONE filter, and on
    -- a page listing seventeen of them it has no single answer, so it moved into
    -- each panel's own header. Asserted as an ABSENCE, because that is the only
    -- thing that fails if somebody adds either one back.
    check(adopt:find("addFn(chipRow,", 1, true) == nil,
          "bands: ...and the chip row is not a band -- used-by is per FILTER now")
    check(adopt:find("addFn(consumerRow,", 1, true) == nil,
          "bands: ...so there is no Used By row above the list either")
    -- ☠ NOR IS THE DETAIL. There is no single filter being edited any more, so the
    -- header-plus-spell-list the island calls `rightArea` has nothing to show: each
    -- filter's panel carries its own.
    check(adopt:find("addFn(rightArea,", 1, true) == nil,
          "bands: ...and the island's detail is not a band -- every panel carries one")

    -- ☠ THE ONE FLUSH SEAM STILL GETS ITS OWN BAND. The others breathe because each
    -- carries BAND_GAP in its SLOT, but the banner's slot is `banner.layoutHeight`
    -- -- a number CreateInfoBanner's deferred re-measure rewrites, so a gap folded
    -- into it is discarded on the next re-wrap.
    check(atBanner < atGap and atGap < atAction,
          "bands: ...with the rhythm's own band between the banner and the row below it")
    -- ⚠ BUILT ONCE, OUTSIDE THE ADOPT PASS. It runs on EVERY build, and frames
    -- cannot be garbage-collected in this client -- a frame created in there is one
    -- leaked per rebuild.
    check(adopt:find("CreateFrame(", 1, true) == nil,
          "bands: ...created outside the pass, which re-runs on every build")
    check(SRC:find("local bannerGap = CreateFrame(\"Frame\", nil, parent)", 1, true) ~= nil,
          "bands: ...where the other bands are built")
    -- ⚠ AND THE ISLAND'S CHROME SUM IS UNTOUCHED. PANEL_CHROME_H is the ISLAND's,
    -- and the island has no band gaps at all.
    check(SRC:find("local PANEL_CHROME_H = 22 + TOP_INSET + CHIP_ROW_H\n", 1, true) ~= nil,
          "bands: ...so the island's chrome sum is untouched")

    -- Full width, every one. The all-rows rule: the page has one left edge and
    -- one right edge.
    check(select(2, adopt:gsub('"both"', "")) == 6,
          "bands: every band spans both columns")
    -- ☠ SIX, BECAUSE "USED BY" IS BACK ON THE PAGE. It was taken off in the pass
    -- that made the page a list of filters, on the reasoning that used-by is
    -- per-FILTER. That holds for the line in each panel's header and NOT for these
    -- three: they answer "how many filters does the Buff Bar use", which is a fact
    -- about the consumer and does not move with the selection.
    check(adopt:find("addFn(USEDBY.band", 1, true) ~= nil,
          "bands: ...and Used By is one of them, above the filters it describes")

    -- A settings group carries its OWN height (calculatedHeight), re-read by the
    -- layout pass on every RefreshStates -- which is the whole reason the filter
    -- list can grow and shrink without a page rebuild.
    check(adopt:find("addFn(filterBand, nil, \"both\")", 1, true) ~= nil,
          "bands: the list band reports its own height rather than a number copied out of it")

    -- RUN ON EVERY BUILD. DoBuild retires every Add()ed child -- hides it, clears
    -- its points, reparents it to the trash -- so a page that builds its frames
    -- once has to hand its roots back through the fresh Add it is given.
    check(SRC:find("pageRef._fdAdoptBands = AdoptBands", 1, true) ~= nil,
          "bands: the adopt pass is published for the rebuild guard")
    local guard = SRC:match("if pageRef%._filterDesignerBuilt then(.-)\n        return\n    end")
    check(guard ~= nil, "bands: the rebuild guard can be read")
    guard = guard or ""
    check(guard:find("pageRef._fdAdoptBands(Add)", 1, true) ~= nil,
          "bands: ...and the guard calls it with the Add of THIS build")

    -- ☠ THE ISLAND'S THREE ROOTS COME DOWN, NOT MERELY UN-ANCHORED. The chip row is
    -- anchored to the banner, the master panel to the chip row and the detail to the
    -- master -- and the banner IS a band here, so a chain left standing would redraw
    -- the whole island over the column that replaced it. An anchor is geometry, not
    -- visibility: hiding a frame does not stop its neighbours being positioned off it.
    check(SRC:find("banner:ClearAllPoints()", 1, true) ~= nil,
          "bands: the banner drops its island anchor")
    for _, name in ipairs({ "chipRow", "leftPanel", "rightArea" }) do
        check(SRC:find(name .. ":ClearAllPoints()", 1, true) ~= nil,
              "bands: " .. name .. " drops its island anchor...")
        check(SRC:find(name .. ":Hide()", 1, true) ~= nil,
              "bands: ...and is hidden, so it cannot draw over the column")
    end
end

-- ============================================================
-- 2b. THE ACTION BAND -- WHAT HAS NO FILTER TO BELONG TO
-- ------------------------------------------------------------
-- Every other verb on this page acts on ONE filter and now lives in that filter's
-- own panel. New and Import CREATE one, so they sit above the list they create
-- into -- the same argument that kept them out of the island's bottom strip.
--
-- ☠ REWRITTEN. This section used to assert that the three consumer chips moved
-- into a panel behind a "Used By" row. That row is gone (see section 2), and the
-- help popup it also carried had to find a new home or the band layout would have
-- lost it -- which is what the action band's "?" is.
-- ============================================================
print("-- Filter Designer: the action band")
do
    check(SRC:find("local actionBand = CreateFrame(\"Frame\", nil, parent)", 1, true) ~= nil,
          "action: the band exists")
    check(SRC:find("local newBtn = GUI:CreateButton(actionBand,", 1, true) ~= nil,
          "action: New is on it...")
    check(SRC:find("local importBtn = GUI:CreateButton(actionBand,", 1, true) ~= nil,
          "action: ...and so is Import")

    -- The help popup is opened from two places, so it is a verb rather than two
    -- copies of a five-slot format().
    check(SRC:find("local function ShowFilterHelp()", 1, true) ~= nil,
          "action: the how-this-works popup is one verb...")
    check(SRC:find('helpBtn:SetScript("OnClick", ShowFilterHelp)', 1, true) ~= nil,
          "action: ...called by the island's glyph...")
    check(SRC:find('helpBandBtn:SetScript("OnClick", ShowFilterHelp)', 1, true) ~= nil,
          "action: ...and by the band's own, which is the only thing keeping it reachable here")

    -- ☠ THE IMPORT FLOW HAS ONE WRITER. It is a five-branch popup chain -- decode,
    -- name clash, content match, import-as-copy, use-existing -- and the band's
    -- button DRIVES the island's row rather than carrying a second copy of it.
    check(SRC:find('local fn = importRow:GetScript("OnClick")', 1, true) ~= nil,
          "action: Import drives the island's own handler rather than duplicating it")

    -- ☠ SIZED FROM THE BAND, NOT GIVEN A NUMBER. Two fixed-width buttons anchored
    -- from opposite ends do not shrink, they overlap -- the Class-2 failure this
    -- page has already paid for twice.
    local lab = SRC:match("local function LayoutActionBand%(%)(.-)\n        end")
    check(lab ~= nil, "action: the band's layout can be read on its own")
    lab = lab or ""
    check(lab:find("local w = actionBand:GetWidth() or 0", 1, true) ~= nil,
          "action: ...asked of the band rather than assumed")
    check(lab:find("newBtn:SetWidth(bw)", 1, true) ~= nil and lab:find("importBtn:SetWidth(bw)", 1, true) ~= nil,
          "action: ...and both buttons take the share it computes")
    check(SRC:find('actionBand:SetScript("OnSizeChanged", LayoutActionBand)', 1, true) ~= nil,
          "action: ...re-taken whenever the band changes width")

    -- Their parent is the band, not the page child, so the page's theme walk never
    -- reaches them. This is the list RefreshLeft re-themes.
    check(SRC:find("bandButtons[#bandButtons + 1] = newBtn", 1, true) ~= nil,
          "action: the band's buttons are registered for re-theming")
    local left = SRC:match("RefreshLeft = function%(%)(.-)\n        HideStandingRegions%(%)")
    check(left ~= nil, "action: the left refresh can be read on its own")
    check((left or ""):find("for _, b in ipairs(bandButtons) do", 1, true) ~= nil,
          "action: ...and the page's refresh walks that list")
end

-- ============================================================
-- 3. ONE ROW PER FILTER, ACQUIRED ON DEMAND
-- ------------------------------------------------------------
-- ☠ REWRITTEN. This section used to pin the MASTER going behind a single row.
-- There is no master: the page is the list, and the two facts that make that hard
-- are pinned instead -- the page builds its frames ONCE, and filters are created
-- at RUNTIME.
--
-- The way through is that CreatePopoutPageTools is called BELOW the guard's early
-- return, so it runs exactly once for this page and the registry it closes over
-- lives for the session. A row created on the fortieth filter joins the same
-- registry as the first -- there is no build pass to be outside of.
-- ============================================================
print("-- Filter Designer: one row per filter")
do
    check(SRC:find("local function AcquireFilterRow(i)", 1, true) ~= nil,
          "rows: rows are acquired, not built in a loop at page build")

    local acq = SRC:match("local function AcquireFilterRow%(i%)(.-)\n        end")
    check(acq ~= nil, "rows: the acquire can be read on its own")
    acq = acq or ""
    -- POOLED AND NEVER DESTROYED, exactly as the island's list rows are: WoW frees
    -- no frame, so a row handed back is a row reused.
    check(acq:find("local row = filterRows[i]", 1, true) ~= nil
          and acq:find("if row then return row end", 1, true) ~= nil,
          "rows: ...cached, so a row is created once and reused forever")
    check(acq:find("filterBand:AddWidget(row)", 1, true) ~= nil,
          "rows: ...and joins the band's group at creation, which is what makes Add unnecessary later")
    -- ⚠ THE SLOT EXISTS BEFORE THE ROW DOES. PopoutContent runs its builder EAGERLY,
    -- inside the acquire itself, so at the moment the pane is built CreatePopoutRow
    -- has not been called and there is no row to hand it.
    check(acq:find("local slot = {}", 1, true) ~= nil,
          "rows: ...through a slot, because the pane is built before the row exists")
    check(acq:find("BuildFilterPane(group, holder, slot)", 1, true) ~= nil,
          "rows: ...which is what the pane reads its filter from")

    -- NO SCHEMA CHANGE, AND NO CLAIM. This page owns no per-mode db keys at all --
    -- CreateCopyButton is called with an empty list for that reason -- so there is
    -- no key for a modified tick to test and nothing a Reset Group could write.
    check(SRC:find("tools.ClaimKeys", 1, true) == nil,
          "rows: a row claims no db keys, because the page owns none")
    check(SRC:find("tools.WireFooter", 1, true) == nil,
          "rows: ...and takes no reset footer it could not honour")
    -- ☠ AND IT IS COMPACT, WHICH MEANS NO STRIP -- the one page in the addon
    -- whose rows do not carry one. Seventeen filters at a strip row's 48+10 is
    -- 986px of scrolling for a list whose every row is a single line of text.
    -- The strip is not dropped for its 18 points: it exists so a plate covered
    -- in sliders has one place that opens the panel, and this plate carries
    -- nothing, so the whole-row click it was protecting against is safe again.
    check(SRC:find("compact = true", 1, true) ~= nil,
          "rows: ...and is COMPACT, one text line per filter")
    check(SRC:find("footerStrip = true", 1, true) == nil,
          "rows: ...so it carries no footer strip, the only page in the addon that does not")
    -- ⚠ AND THE CORNER STILL PAINTS. A strip row's summary is blanked while it is
    -- on; this row has no strip, so the count and the consumers -- the two facts
    -- that make a LIST of filters readable without opening all seventeen -- reach
    -- the plate through the ordinary path.
    check(SRC:find("summary = function()", 1, true) ~= nil,
          "rows: ...and still declares the summary its corner paints")

    -- ---- THE REFRESH: NO REBUILD, AND NO Add ----
    -- ☠ REJECTED: clearing _filterDesignerBuilt to force a rebuild when a filter is
    -- added. Frames cannot be garbage-collected in this client, and
    -- CreatePopoutPageTools closes every open panel on every build -- the panel the
    -- user is working in would snap shut each time.
    check(SRC:find("pageRef._filterDesignerBuilt = nil", 1, true) == nil,
          "rows: nothing forces a page rebuild to show a new filter")

    local refresh = SRC:match("RefreshFilterRows = function%(%)(.-)\n        end")
    check(refresh ~= nil, "rows: the list refresh can be read on its own")
    refresh = refresh or ""
    check(refresh:find("local list = R:ListFilters()", 1, true) ~= nil,
          "rows: the list comes from the registry's own ordered answer")
    check(refresh:find("local row = AcquireFilterRow(i)", 1, true) ~= nil,
          "rows: ...one row per entry, created if this is the first time that many existed")
    -- ☠ A PRESET'S `name` IS A LOCALE KEY AND A CUSTOM'S IS USER TEXT.
    check(refresh:find("local name = entry.custom and entry.name or L[entry.name]", 1, true) ~= nil,
          "rows: ...a preset's name goes through L[], a custom's does not")
    -- The kit writes the plate's label ONCE, at build, from row._label -- so a row
    -- that changes which filter it shows has to repaint it.
    check(refresh:find("row.label:SetText(name)", 1, true) ~= nil,
          "rows: ...and the plate's label is repainted, not merely re-declared")
    -- HIDDEN THROUGH THE GROUP, not by hand: the group's layout pass is what
    -- ANNOUNCES the hide, and a popout row answers that by closing any loose panel
    -- docked to it. A bare Hide() would leave the panel standing over whatever moved up.
    check(refresh:find("filterBand:SetChildHidden(row, true)", 1, true) ~= nil,
          "rows: ...surplus rows are hidden through the group, which announces it")
    check(refresh:find("filterBand:SetChildHidden(row, false)", 1, true) ~= nil,
          "rows: ...and shown through it again, which is what makes that reversible")
    -- ☠ NO Add() HERE. Add only ever arrives inside a build; this runs from
    -- RefreshAll, which has none. RefreshStates is what re-lays the group and
    -- spends its new height.
    check(refresh:find("Add(", 1, true) == nil,
          "rows: ...and nothing here calls Add, which only exists inside a build")
    check(refresh:find("pageRef:RefreshStates()", 1, true) ~= nil,
          "rows: ...the page's own layout pass re-reads the band's height instead")

    -- ...and the writes that happen elsewhere reach it. A filter can be deleted from
    -- inside its own panel, or its consumers changed on another page entirely.
    local all = SRC:match("RefreshAll = function%(%)(.-)\n    end")
    check(all ~= nil, "rows: the page's refresh can be read on its own")
    all = all or ""
    check(all:find("if RefreshFilterRows then RefreshFilterRows() end", 1, true) ~= nil,
          "rows: ...and the page's own refresh re-binds the list")
    -- Guarded, because it is only assigned in the band arm -- and forward-declared,
    -- because RefreshAll is written ~1,000 lines before that arm. A `local` after
    -- the reader would capture nothing and the guard would be permanently false.
    local declAt = SRC:find("local RefreshFilterRows\r\n", 1, true)
                   or SRC:find("local RefreshFilterRows\n", 1, true)
    local useAt  = SRC:find("if RefreshFilterRows then RefreshFilterRows() end", 1, true)
    check(declAt and useAt and declAt < useAt,
          "rows: ...through a forward declaration, not a nil upvalue")
end

-- ============================================================
-- 4. THE PANEL -- THE HEADER TRAVELS, IN FULL
-- ------------------------------------------------------------
-- ☠ THE PART THE USER SINGLED OUT: "the bit that has the title of the filter, the
-- number that's being tracked, and where that filter is being used, as well as a
-- working search bar, an add by spell ID, and an add from a database button. All
-- those need to be in each pop-up." Six parts, every panel, nothing trimmed.
-- ============================================================
print("-- Filter Designer: the six header parts")
do
    -- SCOPED TO THE PANE BUILDER'S OWN BODY. Every one of these names also exists
    -- on the island's header panel, built 2,000 lines earlier, so a file-wide find
    -- answers "does this page have a search box" and never "does the PANEL".
    local pane = SRC:match("local function BuildFilterPane%(group, holder, slot%)(.-)\n        end")
    check(pane ~= nil, "panel: the pane builder's body can be read")
    pane = pane or ""

    -- ☠ ONE CONTAINER FRAME, WHICH IS THE ONLY REASON ANY OF THIS TRAVELS.
    -- PopoutContent builds into a hidden holder and moves FRAMES into the group; a
    -- REGION made on that holder -- a FontString -- stays behind and is never drawn,
    -- silently. Four of the six parts are FontStrings.
    check(pane:find("local c = CreateFrame(\"Frame\", nil, holder)", 1, true) ~= nil,
          "panel: everything is built into ONE container frame...")
    check(pane:find("group:AddWidget(c, PANE.paneH)", 1, true) ~= nil,
          "panel: ...which is what goes into the group, as one object")
    -- Every FontString in the pane hangs off that container, never off the holder.
    check(pane:find("holder:CreateFontString", 1, true) == nil,
          "panel: ...and nothing makes a region on the holder, which would never draw")

    -- (1) which kind of filter, (2) the name and what it tracks, (3) who uses it
    check(pane:find("local eyebrow = c:CreateFontString", 1, true) ~= nil,
          "panel: (1) the built-in / custom caption")
    check(pane:find("local title = c:CreateFontString", 1, true) ~= nil,
          "panel: (2) the filter's name...")
    check(pane:find("local countText = c:CreateFontString", 1, true) ~= nil,
          "panel: (2) ...and the number it tracks")
    check(pane:find("local usedText = c:CreateFontString", 1, true) ~= nil,
          "panel: (3) where the filter is being used")
    -- (4) a WORKING search bar -- wired to this pane's own query, not the page's.
    check(pane:find("local searchBoxP = GUI:CreateEditBox(c,", 1, true) ~= nil,
          "panel: (4) a search box of its own...")
    check(pane:find('searchBoxP.EditBox:HookScript("OnTextChanged"', 1, true) ~= nil,
          "panel: (4) ...wired to something, which is what makes it a working one")
    check(pane:find("pane.query = q", 1, true) ~= nil,
          "panel: (4) ...its OWN query, so two open panels do not share one search")
    -- (5) add by spell ID, (6) add from the database
    check(pane:find("local addBoxP = GUI:CreateEditBox(c,", 1, true) ~= nil,
          "panel: (5) an add-by-spell-ID box...")
    check(pane:find("local addBtnP = GUI:CreateButton(c,", 1, true) ~= nil,
          "panel: (5) ...and the button beside it")
    check(pane:find("local dbBtnP = GUI:CreateButton(c,", 1, true) ~= nil,
          "panel: (6) an add-from-database button")

    -- ☠ (5) AND (6) ARE GREYED ON A BUILT-IN FILTER, NEVER ABSENT. You cannot add or
    -- remove a spell from a preset, only tick what is in it -- but a header that
    -- changes SHAPE between the two kinds makes the reader re-learn it on every row.
    local paint = SRC:match("local function Paint%(%)(.-)\n            end")
    check(paint ~= nil, "panel: the repaint verb's body can be read")
    paint = paint or ""
    check(paint:find("addBoxP:SetEnabled(isCustom)", 1, true) ~= nil,
          "panel: (5) is disabled for a preset...")
    check(paint:find("addBtnP:SetDisabled(not isCustom)", 1, true) ~= nil,
          "panel: (5) ...both halves of it...")
    check(paint:find("dbBtnP:SetDisabled(not isCustom)", 1, true) ~= nil,
          "panel: (6) ...and so is the database button")
    check(paint:find("addBoxP:Hide()", 1, true) == nil
          and paint:find("dbBtnP:Hide()", 1, true) == nil,
          "panel: ...and neither is hidden, so the header keeps one shape everywhere")

    -- ☠ A PANE IS BUILT ONCE PER (INSTANCE, ROW) AND NEVER REBUILT, while the ROW is
    -- re-bound to a different filter whenever one is created or deleted. So nothing
    -- that varies by filter may be captured at build: it is read through the SLOT, by
    -- the repaint verb. The Aura Designer's filter panel shipped showing "All"
    -- forever for exactly this reason.
    check(paint:find("local kind, key = slot.kind, slot.key", 1, true) ~= nil,
          "panel: the repaint reads its filter from the slot, at paint time")
    check(pane:find("pane.Paint = Paint", 1, true) ~= nil,
          "panel: ...and the verb is published so the row binding can call it")
    check(pane:find("c.refreshContent = function() Paint() end", 1, true) ~= nil,
          "panel: ...and the group re-asks it on every re-flow, which is the kit's own name for it")

    -- (3) is read LIVE from the db, per filter -- the two facts the old page made
    -- you open two different things to learn.
    check(paint:find("FilterConsumers(kind, key)", 1, true) ~= nil,
          "panel: who is using it is asked of the db, for THIS filter")
    check(paint:find("R:PresetCounts(key)", 1, true) ~= nil,
          "panel: ...and so is what it tracks")

    -- ☠ THE PER-FILTER ACTIONS REPLACED THE MASTER'S STRIP. Duplicate / Rename /
    -- Export / Delete and Reset used to act on "the selection"; with a row per filter
    -- there is no selection, so they belong to the filter whose panel they are in.
    for _, name in ipairs({ "dupBtnP", "renameBtnP", "exportBtnP", "delBtnP", "resetBtnP" }) do
        check(pane:find("local " .. name, 1, true) ~= nil,
              "panel: the panel carries its own " .. name)
    end
    check(paint:find("resetBtnP:SetShown((isPreset and R:IsPresetModified(key)) or false)", 1, true) ~= nil,
          "panel: Reset shows only for a preset that differs from its defaults")
    check(paint:find("delBtnP:SetDisabled(not isCustom)", 1, true) ~= nil,
          "panel: ...and Delete is refused on one, which has no store entry to delete")

    -- ☠ THE PANEL GOES WITH THE FILTER. Rows are POOLED and re-bound, so a panel
    -- left standing over a deleted filter silently becomes the NEXT filter's.
    check(pane:find('r:ClosePopout("deleted")', 1, true) ~= nil,
          "panel: deleting a filter closes the panel it was deleted from")

    -- ☠ BUILD THE SPELL ROWS LAZILY. PopoutContent runs a row's builder EAGERLY, at
    -- page build, for EVERY row -- seventeen filters' worth of spell rows up front is
    -- a cost the old page never paid, because it only ever had one list.
    -- ⚠ THE BUILDER, WITHOUT ITS REPAINT VERB. Paint is written INSIDE this builder
    -- and is where the rows do come from, so an absence claim over the whole body is
    -- answered by the very function it is about. Cut it out, then ask.
    local paneBuild = pane:gsub("local function Paint%(%).-\n            end", "")
    check(paneBuild:find("AcquirePaneSpellRow", 1, true) == nil,
          "panel: the builder creates NO spell rows...")
    check(paint:find("AcquirePaneSpellRow(pane, usedRows)", 1, true) ~= nil,
          "panel: ...they arrive on the pane's first paint instead")
    check(SRC:find("local function AcquirePaneSpellRow(pane, i)", 1, true) ~= nil,
          "panel: ...from that pane's OWN pool")
    -- ⚠ ONLY THE PANES ON SCREEN. A closed pane lives in a hidden holder, and
    -- repainting seventeen of those on every write is the cost the lazy build exists
    -- to avoid -- they paint on the way in, through refreshContent.
    check(SRC:find("if p.container:IsVisible() then p.Paint() end", 1, true) ~= nil,
          "panel: ...and a list re-bind only repaints the panels the user can see")
end

-- ============================================================
-- 5. THE PANE'S HEIGHT IS FIXED, AND THE ARITHMETIC SAYS WHY
-- ------------------------------------------------------------
-- DandersUI caps a popout pane at a fraction of the screen and wraps anything
-- taller in a scroll frame of its own, and the decision is made at BUILD time.
-- This pane already HAS one -- round its spell list -- so a viewport-sized pane
-- would be a list scrolling inside a list.
--
-- ☠ REWRITTEN. The same claim, one frame along: it used to be about the master's
-- pane, which held the filter list. The master is gone; every filter's pane is
-- the thing that now has to fit.
-- ============================================================
print("-- Filter Designer: the pane's height")
do
    -- SCOPED TO ResolvePanelHeight'S BODY. leftPanel:SetHeight appears at its
    -- construction too, so a file-wide find cannot tell "the viewport does not
    -- reach it" from "it is never sized at all".
    local resolve = SRC:match("local function ResolvePanelHeight%(%)(.-)\n    end")
    check(resolve ~= nil, "paneh: the height verb's body can be read")
    resolve = resolve or ""
    -- ☠ NOTHING IN THE BAND ARM IS SIZED FROM THE VIEWPORT. Every band carries its
    -- own height and every pane is fixed, so this verb has nothing to do there --
    -- which is the honest answer, rather than a chrome sum for bands that no longer
    -- stand where it thinks they do.
    check(resolve:find("if rowsMode then return end", 1, true) ~= nil,
          "paneh: the band arm sizes nothing from the window...")
    check(resolve:find("leftPanel:SetHeight(PANEL_H)", 1, true) ~= nil,
          "paneh: ...while the island's two panels still take it")
    check(resolve:find("rightArea:SetHeight(PANEL_H)", 1, true) ~= nil,
          "paneh: ...both of them")
    check(resolve:find("spacer.layoutHeight", 1, true) ~= nil,
          "paneh: ...and the island still carries its total on the spacer")
    -- The band-layout chrome sum is GONE rather than retuned: it counted exactly two
    -- popout rows above a detail band, and there is neither.
    -- ⚠ CODE ONLY. An ABSENCE claim over source that still carries its comments is
    -- answered by the comment EXPLAINING the absence -- which is how this assertion
    -- first failed. Strip them, then ask.
    local SRC_CODE = SRC:gsub("%-%-[^\n]*", "")
    check(SRC_CODE:find("FILTERROW_H", 1, true) == nil,
          "paneh: the two-rows-above-the-detail sum is gone, not merely retuned")

    -- The numbers, read out of the two files that own them rather than copied.
    local function num(src, pat) return tonumber((src:match(pat))) end
    local capFrac = num(ui_file_source("PopoutRow.lua"), "local CAP_FRAC = ([%d%.]+)")
    local gap   = num(SRC, "PANE%.gap, PANE%.titleH, PANE%.ebH, PANE%.btnH, PANE%.echoH = (%d+)")
    local titleH = num(SRC, "PANE%.gap, PANE%.titleH, PANE%.ebH, PANE%.btnH, PANE%.echoH = %d+, (%d+)")
    local ebH    = num(SRC, "PANE%.gap, PANE%.titleH, PANE%.ebH, PANE%.btnH, PANE%.echoH = %d+, %d+, (%d+)")
    local btnH   = num(SRC, "PANE%.gap, PANE%.titleH, PANE%.ebH, PANE%.btnH, PANE%.echoH = %d+, %d+, %d+, (%d+)")
    local echoH  = num(SRC, "PANE%.gap, PANE%.titleH, PANE%.ebH, PANE%.btnH, PANE%.echoH = %d+, %d+, %d+, %d+, (%d+)")
    local eyebrowH = num(SRC, "local EYEBROW_H = (%d+)")
    local statusH  = num(SRC, "local STATUS_ROW_H = (%d+)")
    -- ⚠ NOT A LITERAL ANY MORE. The list takes what the screen will give it, so
    -- what is pinned here is the BUDGET it is allowed to spend, recomputed below
    -- on the shortest screen in use. The floor is what a short screen falls back
    -- to and is still read from the file.
    local listFloor = num(SRC, "PANE%.listH    = math%.max%((%d+),")
    local listCeil  = num(SRC, "PANE%.listH    = math%.max%(%d+, math%.min%((%d+),")
    local margin    = num(SRC, "math%.floor%(capH %- (%d+) %- PANE%.headH")
    local listH     = listFloor
    local actH     = num(SRC, "PANE%.actH     = (%d+)")
    check(capFrac and gap and titleH and ebH and btnH and echoH and eyebrowH
          and statusH and listH and listCeil and margin and actH,
          "paneh: every term of the pane's height can be read from the file that owns it")
    capFrac = capFrac or 0
    -- The same sum the page writes, recomputed here from its own parts: the six
    -- header rows, the list, the action strip and the two seams between them.
    local headH = eyebrowH + titleH + statusH
                  + gap + ebH        -- (4) search
                  + gap + ebH        -- (5) spell id + Add
                  + gap + btnH       -- (6) add from database
                  + 2 + echoH        -- the add-by-id echo
    local paneH = headH + gap + listH + gap + actH
    -- A 768px UIParent is the shortest the client allows, and the pane holds the
    -- whole header, the list and the actions under it. If this ever fails the panel
    -- needs a different shape rather than a bigger number -- past the cap the kit
    -- wraps it in a SECOND scroll frame around the one the spell list already has.
    check(paneH < capFrac * 768,
          "paneh: a filter's panel fits the pane's ceiling on the shortest screen in use")
    -- ☠ AND SO DOES THE GROWN ONE, WHICH IS THE POINT OF LETTING IT GROW. The page
    -- spends (cap - margin - chrome) on the list; recomputed here at three real
    -- screen heights, the resulting pane must still clear the cliff at each. A
    -- margin that ever went to zero would put the pane exactly ON the ceiling,
    -- which is the same failure as being over it.
    for _, screenH in ipairs({ 768, 1080, 1440 }) do
        local capH = screenH * capFrac
        local grown = math.max(listH, math.min(listCeil,
                          math.floor(capH - margin - headH - gap * 2 - actH)))
        check(headH + gap + grown + gap + actH < capH,
              "paneh: ...and the grown list still clears the ceiling at " .. screenH .. "px")
    end
    -- ...and it really does grow: six spells at a time was the complaint.
    do
        local capH = 1080 * capFrac
        local grown = math.max(listH, math.min(listCeil,
                          math.floor(capH - margin - headH - gap * 2 - actH)))
        check(grown >= listH * 1.8,
              "paneh: ...and a 1080p screen buys a materially longer list")
    end
    -- ...and it is DECLARED, not measured: the cap decision is made at build time,
    -- so a pane that grows afterwards is past the ceiling with nothing to catch it.
    check(SRC:find("PANE.paneH    = PANE.headH + PANE.gap + PANE.listH + PANE.gap + PANE.actH", 1, true) ~= nil,
          "paneh: ...and the page writes it as the same sum, not as a literal")
    -- ⚠ The budget is measured off the SCREEN, not off the window: the cap the kit
    -- applies is a fraction of UIParent, so sizing against anything else is sizing
    -- against the wrong thing.
    check(SRC:find("UIParent:GetHeight()", 1, true) ~= nil,
          "paneh: ...and the budget is measured off the screen the cap is a fraction of")

    -- ============================================================
    -- ☠ AND THE BLOCK IS RUN, NOT JUST READ.
    -- ------------------------------------------------------------
    -- Everything above this line reads the page as TEXT, and text cannot tell you
    -- that a term is read one line above where it is assigned. That shipped: the
    -- list height spent PANE.actH from above `PANE.actH = 80`, so the arithmetic
    -- met a nil, threw inside the builder, and took the whole page down -- the
    -- FOURTH runtime fault in one day that a green suite had nothing to say about.
    --
    -- This block is pure arithmetic with no frame in it, so the test can simply
    -- EXECUTE it against stubs and find out. Anything the page adds here that
    -- reads a term before its line now fails as a nil-arithmetic error, named.
    -- ============================================================
    do
        local block = SRC:match("(local PANE = %{.-PANE%.paneH%s*=%C*)")
        check(block ~= nil, "paneh: the PANE block can be lifted out whole")
        if block then
            for _, screenH in ipairs({ 768, 1080, 1440 }) do
                local env = {
                    math = math,
                    EYEBROW_H = eyebrowH, STATUS_ROW_H = statusH,
                    UIParent = { GetHeight = function() return screenH end },
                }
                local fn, err = loadstring(block .. " return PANE")
                check(fn ~= nil, "paneh: ...and it compiles on its own: " .. tostring(err))
                if fn then
                    setfenv(fn, env)
                    local ok, pane = pcall(fn)
                    check(ok, "paneh: ...and RUNS at " .. screenH .. "px: " .. tostring(pane))
                    if ok then
                        -- The numbers it produces are the ones asserted above, so a
                        -- formula that compiles and runs but computes nonsense still
                        -- has to answer for itself.
                        eq(pane.paneH, pane.headH + pane.gap + pane.listH + pane.gap + pane.actH,
                           "paneh: ...and its own sum holds at " .. screenH .. "px")
                        check(pane.paneH < capFrac * screenH,
                           "paneh: ...and it clears the kit's ceiling at " .. screenH .. "px")
                    end
                end
            end
        end
    end
end

-- ============================================================
-- 6. THE NARROW WINDOW -- WHAT 850px WAS HIDING HERE
-- ------------------------------------------------------------
-- The band is DERIVED, not quoted: window minimum, less the nav pane and the
-- window's own padding, less the page's inset and scroll gutter, less the two
-- column margins. Every one of those is read from the file that declares it, so
-- a retuned scrollbar or a wider nav moves this test with the layout.
--
-- Everything below is about the ISLAND, which still draws the chips and the
-- two-column header. The band arm draws neither.
-- ============================================================
print("-- Filter Designer: the narrow window")
do
    local function num(src, pat)
        return tonumber((src:match(pat)))
    end
    local TH        = ui_file_source("Theme.lua")
    local minWidth  = num(PANEL, "local minWidth, minHeight = (%d+)")
    local navW      = num(PANEL, "tabFrame:SetWidth%(SnapLen%(frame, (%d+)%)%)")
    local windowPad = num(PANEL, "windowPad = (%d+)")
    local navGap    = num(PANEL, "navGap    = (%d+)")
    local inset     = num(PANEL, "inset     = (%d+)")
    local bar       = num(TH,    "bar = (%d+)")
    local pad       = num(TH,    "pad = (%d+)")
    local colMargin = num(TH,    "colMargin  = (%d+)")
    local groupW    = num(TH,    "group      = (%d+)")
    check(minWidth and navW and windowPad and navGap and inset and bar and pad
          and colMargin and groupW,
          "narrow: every term of the band arithmetic can be read from its own file")

    -- contentFrame -> page child -> the width a "both" widget is stretched to.
    local contentW = minWidth - windowPad - navW - navGap - windowPad
    local childW   = contentW - inset - (bar + pad)
    local bandW    = math.max(childW - 2 * colMargin, groupW)
    check(bandW > 290 and bandW < 315,
          "narrow: the band at the window's minimum is ~301px")

    -- ---- the consumer chips: the ISLAND's copy, which still shares a row ----
    local chipMin  = num(SRC, "local CHIP_MIN_W  = (%d+)")
    local chipGap  = num(SRC, "local CHIP_GAP  = (%d+)")
    local chipH    = num(SRC, "local CHIP_H = (%d+)")
    check(chipMin and chipGap and chipH, "narrow: the chip constants can be read")
    local chipsNeed = 3 * chipMin + 2 * chipGap + chipH + chipGap
    check(chipsNeed > bandW,
          "narrow: three chips on one row do not fit the narrowest band...")

    -- SCOPED TO LayoutChips' OWN BODY. `chipRow` and `CHIP_GAP` are all over this
    -- file, so a file-wide find for the wrap terms would pass with the wrap gone.
    local chips = SRC:match("local function LayoutChips%(%)(.-)\n    end")
    check(chips ~= nil, "narrow: the chip layout can be read on its own")
    chips = chips or ""
    check(chips:find("local rows = mceil(n / perRow)", 1, true) ~= nil,
          "narrow: ...so they wrap to as many rows as they need")
    check(chips:find("chipRow.dfSetHeight(h + BAND_GAP, h)", 1, true) ~= nil,
          "narrow: ...and the band is TOLD, so nothing below sits at a stale offset")
    check(chips:find("chipRow.dfSetHeight(h + BAND_GAP, h)\n        else\n            chipRow:SetHeight(h)", 1, true) ~= nil,
          "narrow: ...by ONE writer, the band's or the island's, never both")

    -- ...and the band's own height verb keeps the two apart.
    local bh = SRC:match("local function BandHeight%(host%)(.-)\n        end")
    check(bh ~= nil, "narrow: the band's height verb can be read on its own")
    bh = bh or ""
    check(bh:find("host.layoutHeight = slotH", 1, true) ~= nil,
          "narrow: the SLOT takes the gap...")
    check(bh:find("host:SetHeight(frameH)", 1, true) ~= nil,
          "narrow: ...and the frame only what it draws, so a rebuild cannot stack gaps")
    check(bh:find("if host.layoutHeight == slotH and (host:GetHeight() or 0) == frameH then", 1, true) ~= nil,
          "narrow: ...and it early-outs on both, so a re-flow cannot loop")
    check(SRC:find('chipRow:SetScript("OnSizeChanged", LayoutChips)', 1, true) ~= nil,
          "narrow: ...re-taken whenever the band changes width")
    check(SRC:find('helpBtn:SetPoint("TOPRIGHT", 0, 0)', 1, true) ~= nil,
          "narrow: ...and the help glyph stays beside the FIRST row of chips")

    -- ---- ...AND THE PANEL IS WIDER FOR ANY ONE OF THEM THAN THE BAND WAS ----
    -- ☠ WRAPPING WAS NEVER THE WHOLE FAULT. Three chips "fit" the DEFAULT ~410 band
    -- -- each getting ~123px, with ~113 left for text -- while a label like
    -- "Defensive Icon  2 filters" is half as long again. Fitting and being readable
    -- are different claims, and only the first was ever tested. The panel's width
    -- does not depend on the window's at all.
    local defaultBand = 410
    local perChip = math.floor((defaultBand - chipH - chipGap - 2 * chipGap) / 3)
    check(perChip < 150,
          "narrow: three chips on the DEFAULT band get less than a label's width each")
    local paneW = num(SRC, "local paneW = GUI.PopoutContentWidth or (%d+)")
    check(paneW ~= nil, "narrow: the pane's width can be read from the page")
    check(paneW and paneW > perChip,
          "narrow: ...where a panel gives a line more room than the band did")

    -- ---- CLASS TWO: header row 3, a row of fixed-width children ----
    -- The island's Spell ID box, Add button and Add-from-Database button are all
    -- fixed, so with the echo squeezed to nothing the row still overruns the band.
    check(SRC:find("local ROW3_ONE_LINE_W = 10 + 90 + 6 + 50 + 8 + 130 + 10", 1, true) ~= nil,
          "narrow: row 3's threshold is written as the sum of its own parts")
    check(10 + 90 + 6 + 50 + 8 + 130 + 10 > bandW,
          "narrow: ...which is wider than the narrowest band, so it cannot hold")
    local hdr = SRC:match("local function LayoutHeaderRows%(%)(.-)\n    end")
    check(hdr ~= nil, "narrow: the header layout can be read on its own")
    hdr = hdr or ""
    check(hdr:find('dbBtn:SetPoint("TOPLEFT", 10, -(ROW3_Y + BTN_ON_EB + ROW4_H))', 1, true) ~= nil,
          "narrow: ...so the picker drops to a row of its own")
    check(hdr:find("local wantH = HEADER_H + (oneLine and 0 or ROW4_H)", 1, true) ~= nil,
          "narrow: ...and the header grows by exactly that row")
    check(hdr:find("if (headerPanel:GetHeight() or 0) ~= wantH then headerPanel:SetHeight(wantH) end", 1, true) ~= nil,
          "narrow: ...written back only when it changed, so the resize cannot loop")
    check(hdr:find('echoText:SetPoint("RIGHT", headerPanel, "RIGHT", -10, 0)', 1, true) ~= nil,
          "narrow: ...and the echo takes the room the picker left")
    check(SRC:find('headerPanel:SetScript("OnSizeChanged", LayoutHeaderRows)', 1, true) ~= nil,
          "narrow: re-taken on resize, not decided once at build")

    -- ...AND THE PANEL TAKES THE SAME LESSON. At 260px the three fixed children of
    -- the island's row 3 cannot share a line at all, so the panel puts the database
    -- button and the echo on lines of their own from the start.
    check(90 + 6 + 50 + 8 + 130 > (paneW or 0),
          "narrow: the island's row 3 does not fit a panel either...")
    check(SRC:find('dbBtnP:SetPoint("TOPLEFT", 0, -PANE.yDB)', 1, true) ~= nil,
          "narrow: ...so the panel's database button has a line of its own")
    check(SRC:find('echoText:SetPoint("TOPLEFT", 0, -PANE.yEcho)', 1, true) ~= nil,
          "narrow: ...and so does the echo, which is the only feedback an add-by-ID gives")
end

-- ============================================================
-- 7. THE CROSS-PAGE ENTRY POINTS STILL LAND
-- ------------------------------------------------------------
-- Three other pages navigate here by name and then call one of these two. A cue
-- that lands on a shut panel is no cue at all -- the same argument that made the
-- scroll part of them in the first place.
--
-- ☠ REWRITTEN. They used to open THE master row. There is no master row: the cue
-- is the panel of the filter actually being named, and the hooks that do it are
-- published by the band arm and read at CALL time.
-- ============================================================
print("-- Filter Designer: the entry points")
do
    check(SRC:find("local scrollTo = pageRef._fdScrollToFilters", 1, true) ~= nil,
          "entry: the opener reads the band's cue at CALL time...")
    check(SRC:find("pageRef._fdScrollToFilters = function()", 1, true) ~= nil,
          "entry: ...which the band arm publishes when it builds one")

    -- SCOPED TO EACH ENTRY POINT'S BODY. OpenFilterList is DECLARED in this file
    -- and called from both, so a file-wide find answers "is this name anywhere"
    -- and stays green with either call deleted.
    local newf = SRC:match("pageRef%._fdFocusNewFilter = function%(%)(.-)\n    end")
    check(newf ~= nil, "entry: the new-filter entry point can be read")
    newf = newf or ""
    check(newf:find("OpenFilterList()", 1, true) ~= nil,
          "entry: 'Create Filter' puts the filter band where the eye is")
    -- ☠ AND THEN IT CREATES THE FILTER. With a panel per filter there is somewhere
    -- to land, so the entry point can finish the job instead of pulsing the button
    -- that would have done it.
    check(newf:find("local newFilter = pageRef._fdNewFilter", 1, true) ~= nil,
          "entry: ...and then makes one and opens its panel, in the band layout")
    check(newf:find("DF:HighlightWidget(addRow)", 1, true) ~= nil,
          "entry: ...while the island keeps its scroll-and-pulse, which is all it has")
    check(SRC:find("pageRef._fdNewFilter = NewFilterFlow", 1, true) ~= nil,
          "entry: ...published, never captured, like every other hook here")

    local focus = SRC:match("pageRef%._fdFocusFilter = function%(kind, key%)(.-)\n    end")
    check(focus ~= nil, "entry: the named-filter entry point can be read")
    focus = focus or ""
    check(focus:find("OpenFilterList()", 1, true) ~= nil,
          "entry: 'Manage Filters' does too")
    check(focus:find("local openPanel = pageRef._fdOpenFilterPanel", 1, true) ~= nil,
          "entry: ...and lands on THAT filter's own panel")
    check(SRC:find("pageRef._fdOpenFilterPanel = FocusFilterPanel", 1, true) ~= nil,
          "entry: ...through a hook the band arm publishes")
    -- BEFORE the row is looked for: SelectFilter runs RefreshAll, which re-binds
    -- every row, so the open has to happen after that or the panel is a different
    -- filter's. This is the pooled-row trap in both layouts.
    local s = focus:find("SelectFilter(kind, key)", 1, true)
    local o = focus:find("local openPanel = pageRef._fdOpenFilterPanel", 1, true)
    check(s and o and s < o,
          "entry: ...asked AFTER the selection moves and the pool re-binds")
    -- ...and the band arm's own finder says the same thing in its own words.
    local finder = SRC:match("FocusFilterPanel = function%(kind, key%)(.-)\n        end")
    check(finder ~= nil, "entry: the band arm's finder can be read")
    check((finder or ""):find("slot.kind == kind and slot.key == key", 1, true) ~= nil,
          "entry: ...which matches on the row's live binding, not on an index")
end

-- ============================================================
-- 8. THE FLOOR IS GONE -- THE ACCEPTANCE TEST
-- ------------------------------------------------------------
-- The one assertion that says the conversion achieved its purpose rather than
-- merely rearranging itself. Its twin lives in the Aura Designer's census, which
-- pinned this page's floor while it still had one and now pins its absence.
-- ============================================================
print("-- Filter Designer: the wide-page floor is gone")
do
    -- THE TABLE'S BODY, NOT THE FILE. The page id also appears in Panel.lua's
    -- slash-command alias map, so a file-wide find answers "is this string
    -- anywhere" and never "is this page still a wide page".
    local WIDE = PANEL:match("local WIDE_PAGES = {(.-)}")
    check(WIDE ~= nil, "wide: the WIDE_PAGES table can be found")
    check((WIDE or ""):find("auras_filterdesigner", 1, true) == nil,
          "wide: the Filter Designer no longer forces the window to 850")
    -- The aura family is out entirely; the two pages that have not had their own
    -- pass must NOT have been swept out with it.
    check((WIDE or ""):find("auras", 1, true) == nil,
          "wide: ...and no aura page is left in the table at all")
    check((WIDE or ""):find("general_pinnedframes", 1, true) ~= nil,
          "wide: Pinned Frames keeps its floor until its own pass")
    check((WIDE or ""):find("general_nicknames", 1, true) ~= nil,
          "wide: ...and so does Nicknames")
end

-- ============================================================
-- 9. NO SCHEMA CHANGE
-- ------------------------------------------------------------
-- Filters are user data and this was a re-presentation. The one place a
-- conversion silently writes a new profile key is a collapsible section, which
-- persists its fold under the section's TITLE TEXT unless told otherwise -- and
-- filter names are typed by the user.
-- ============================================================
print("-- Filter Designer: no schema change")
do
    check(SRC:find("CreateCollapsibleSection", 1, true) == nil,
          "schema: nothing here persists a fold under a user-typed title")
    -- The three stores this page edits, named where they are read, so a future
    -- conversion cannot quietly move one of them.
    check(SRC:find("R:ReadStore()", 1, true) ~= nil,
          "schema: custom filters still come from the registry's own store")
    check(SRC:find("filterPresetOverrides", 1, true) ~= nil,
          "schema: preset overrides are still the per-profile diff")
end

-- ============================================================
-- THE FRESHNESS NOTE IS MEASURED ON ITS STRING, NOT ITS FRAME
-- ------------------------------------------------------------
-- ☠ GUI:CreateLabel (GUI/Sections.lua) returns a FRAME WRAPPING a FontString.
-- The kit's UI:CreateLabel returns the FontString itself, and reading the kit
-- while calling the host's is how GetStringHeight ended up called on a frame --
-- a nil value, thrown the moment the page opened.
--
-- ⚠ AND THE FRAME'S OWN HEIGHT IS NOT THE FALLBACK. It converges only inside
-- a settings group; this label is anchored straight to leftPanel, so it keeps
-- the placeholder for the life of the page -- the trap already written up at the
-- top of Options.lua. The STRING wraps correctly at any width, so it is the
-- honest number.
-- ============================================================
print("-- Filter Designer: the freshness note measures its string")
do
    local SECT = options_file_source("GUI/Sections.lua")
    check(SECT:find("frame.fontString = lbl", 1, true) ~= nil,
          "note: the label wrapper exposes its FontString for callers that must measure")
    check(SRC:find("dbFreshLabel.fontString", 1, true) ~= nil,
          "note: ...and the freshness note reaches through it")
    check(SRC:find("dbFreshLabel:GetStringHeight", 1, true) == nil,
          "note: nothing calls a FontString verb on the wrapper frame")
    -- The re-report resizes the host, which re-enters OnSizeChanged.
    check(SRC:find("self._dfLastH ~= h", 1, true) ~= nil,
          "note: the height re-report bails when the number has not moved, so it terminates")
end

-- ============================================================
-- THE SPELL PICKER HAS NOWHERE TO ANCHOR ANY MORE
-- ------------------------------------------------------------
-- ☠ The island points the database overlay at the two panels' corners, and both
-- of them are taken down in the band arm. It covers the VIEWPORT instead.
-- ============================================================
print("-- Filter Designer: the picker's new home")
do
    check(SRC:find("parent = GUI.contentFrame or parent,", 1, true) ~= nil,
          "picker: the band arm parents the overlay to the viewport")
    -- ⚠ AND THE SELECTION MOVES WITH IT. RefreshAll closes the picker whenever the
    -- page's selection is not its target, and nothing else in the band arm moves
    -- that selection -- so without this the picker shut itself on the first add.
    check(SRC:find('selKind, selKey = "custom", cfId', 1, true) ~= nil,
          "picker: ...and points the page's own selection at its target")
    local all = SRC:match("RefreshAll = function%(%)(.-)\n    end") or ""
    check(all:find("selKind == \"custom\" and selKey == pickerTarget", 1, true) ~= nil,
          "picker: ...which is the guard that would otherwise close it")
end
