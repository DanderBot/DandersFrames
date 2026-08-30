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
-- ☠ IT IS NOT A DESIGNER SHELL, AND THAT IS THE FINDING RATHER THAN A SHORTCUT.
-- GUI:BuildDesignerShell is a preview-plus-tabs shape: a canvas, a strip saying
-- what the canvas is showing, a view switcher, then the caller's own bands. This
-- page has none of those three. It is a MASTER/DETAIL -- a list of filters, and
-- the spells inside the one you picked -- so it would have used one of the
-- shell's six slots. What it borrows from the rework is the COLUMN: the master
-- goes behind a popout row (the all-rows rule -- more than one option opens a
-- panel) and the detail becomes the page's own band.
--
-- ☠ AND THE ISLAND IS NOT FORKED. Every frame is built exactly as it always was,
-- anchored off the page child; the band arm RE-HOMES five roots at the end. That
-- is the property this file exists to pin -- a rowsMode test threaded through
-- 2,700 lines of one closure would fork every site it touched, and the two
-- layouts would drift the first time anyone edited one of them.
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
          "layout: the page does not build a designer shell -- it is a master/detail")
    check(SRC:find("GUI:CreatePopoutPageTools(pageRef)", 1, true) ~= nil,
          "layout: it takes the shared popout tools, which is the part that fits")
end

-- ============================================================
-- 2. FIVE ROOTS, RE-HOMED -- AND IN THE RIGHT ORDER
-- ------------------------------------------------------------
-- Within a column the Add() order IS the layout order. The master has to come
-- before the detail or the page reads back to front.
-- ============================================================
print("-- Filter Designer: the bands, and their order")
do
    -- SCOPED TO AdoptBands' OWN BODY. Every one of these five names is declared
    -- elsewhere in the same file -- `banner`, `chipRow`, `rightArea` are all
    -- built by the island 1,500 lines earlier -- so a file-wide find answers
    -- "does this frame exist" and never "is it a band".
    local adopt = SRC:match("local function AdoptBands%(addFn%)(.-)\n        end")
    check(adopt ~= nil, "bands: the adopt pass can be read on its own")
    adopt = adopt or ""

    local atBanner = adopt:find("addFn(banner,", 1, true)
    local atChips  = adopt:find("addFn(chipRow,", 1, true)
    local atRow    = adopt:find("addFn(filterRow,", 1, true)
    local atDetail = adopt:find("addFn(rightArea,", 1, true)
    local atFresh  = adopt:find("addFn(freshHost,", 1, true)
    check(atBanner and atChips and atRow and atDetail and atFresh,
          "bands: all five roots are added")
    check(atBanner < atChips, "bands: the banner is first...")
    check(atChips < atRow,    "bands: ...then the consumer chips...")
    check(atRow < atDetail,   "bands: ...then the MASTER, before the detail it selects...")
    check(atDetail < atFresh, "bands: ...then the detail, then the database note")

    -- Full width, every one. The all-rows rule: the page has one left edge and
    -- one right edge.
    check(select(2, adopt:gsub('"both"', "")) == 5,
          "bands: every band spans both columns")

    -- A popout row is fixedRowHeight, so ResolveRowHeight takes the kit's own
    -- plate + gap. A number copied out of the kit is a number that can drift.
    check(adopt:find("addFn(filterRow, nil, \"both\")", 1, true) ~= nil,
          "bands: the master's row takes the kit's own slot height, not a copy of it")

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

    -- The layout pass ClearAllPoints()es and re-anchors every child it places, so
    -- an island anchor left on a band (banner -> parent, chip row -> banner) is a
    -- stale claim about who owns that frame's geometry until the next refresh.
    check(SRC:find("banner:ClearAllPoints()", 1, true) ~= nil,
          "bands: the banner drops its island anchor")
    check(SRC:find("rightArea:ClearAllPoints()", 1, true) ~= nil,
          "bands: ...and so does the detail")
end

-- ============================================================
-- 3. THE MASTER GOES BEHIND A ROW
-- ------------------------------------------------------------
-- Two tall lists stacked in one column is a page you scroll to change what you
-- are looking at. Behind a row it is the all-rows rule, and DF popouts dock
-- OUTSIDE the window -- so a docked filter list beside a narrow window is the
-- old two-column view with the window's width handed back.
-- ============================================================
print("-- Filter Designer: the master")
do
    check(SRC:find("tools.PopoutContent(function(group, holder)", 1, true) ~= nil,
          "master: the filter list is built as popout content")

    -- SCOPED TO THE CONTENT BUILDER'S BODY. `leftPanel` is created, sized and
    -- anchored a thousand lines above this, so a file-wide find for it says
    -- nothing about whether it ever reaches the pane.
    local pane = SRC:match("tools%.PopoutContent%(function%(group, holder%)(.-)\n        end%)")
    check(pane ~= nil, "master: the content builder's body can be read")
    pane = pane or ""
    -- A FRAME, WHICH IS THE ONLY REASON THIS TRAVELS. PopoutContent builds into a
    -- hidden holder and moves FRAMES into the group; a REGION made on that holder
    -- -- a FontString -- stays behind and is never drawn, silently. That trap has
    -- already killed five captions in this rework.
    check(pane:find("leftPanel:SetParent(holder)", 1, true) ~= nil,
          "master: the whole panel is re-parented into the holder...")
    check(pane:find("group:AddWidget(leftPanel, PANE_MASTER_H)", 1, true) ~= nil,
          "master: ...and moved into the group as ONE frame")

    check(SRC:find("pageRef._fdFilterRow = filterRow", 1, true) ~= nil,
          "master: the row is published, so the focus entry points can open it")

    -- ☠ TWO THINGS INSIDE THE MASTER WERE SIZED AGAINST THE ONE WIDTH IT USED TO
    -- BE. A popout pane is narrower than the island's panel, and both of these
    -- fail QUIETLY at any width but 270 -- one by overlapping, one by clipping.
    local strip = SRC:match("local function LayoutActionStrip%(%)(.-)\n    end")
    check(strip ~= nil, "master: the action strip's layout can be read on its own")
    strip = strip or ""
    -- Two buttons anchored from opposite corners at a FIXED width do not shrink,
    -- they overlap: 6 + 127 + 127 + 6 = 266 against a 260px pane.
    check(strip:find("local bw = mfloor((w - 12 - 4) / 2)", 1, true) ~= nil,
          "master: the action buttons are sized from the PANEL, not from LEFT_W")
    check(strip:find("local w = leftPanel:GetWidth() or 0", 1, true) ~= nil,
          "master: ...asked of the panel rather than assumed")
    check(SRC:find('leftPanel:SetScript("OnSizeChanged", LayoutActionStrip)', 1, true) ~= nil,
          "master: ...and re-taken whenever the panel changes width")

    -- Every filter row spans leftContent corner to corner, and leftContent was
    -- pinned at LEFT_W - 28 -- so in a narrower panel the rows overhang the
    -- viewport and each row's spell count, which sits at its right edge, is cut off.
    check(SRC:find("leftScroll:SetScript(\"OnSizeChanged\", function(_, w)", 1, true) ~= nil,
          "master: the filter list's rows follow the viewport's width...")
    local lsync = SRC:match("leftScroll:SetScript%(\"OnSizeChanged\", function%(_, w%)(.-)\n    end%)")
    check(lsync ~= nil, "master: ...and that sync's body can be read")
    check((lsync or ""):find("leftContent:SetWidth(w)", 1, true) ~= nil,
          "master: ...by re-sizing the scroll child, as the spell list already did")
    check(SRC:find("summary = function() return CurrentDisplayName() end", 1, true) ~= nil,
          "master: the row's summary answers 'which one am I editing'")

    -- NO SCHEMA CHANGE, AND NO CLAIM. This page owns no per-mode db keys at all --
    -- CreateCopyButton is called with an empty list for that reason -- so there is
    -- no key for a modified tick to test and nothing a Reset Group could write.
    check(SRC:find("tools.ClaimKeys", 1, true) == nil,
          "master: the row claims no db keys, because the page owns none")
    check(SRC:find("tools.WireFooter", 1, true) == nil,
          "master: ...and takes no reset footer it could not honour")
end

-- ============================================================
-- 4. THE MASTER'S HEIGHT IS FIXED, AND THE ARITHMETIC SAYS WHY
-- ------------------------------------------------------------
-- DandersUI caps a popout pane at a fraction of the screen and wraps anything
-- taller in a scroll frame of its own. The master already HAS one -- leftScroll
-- -- so a viewport-sized master would be a list scrolling inside a list.
-- ============================================================
print("-- Filter Designer: the master's height")
do
    check(SRC:find("local PANE_MASTER_H = PANEL_H_MIN", 1, true) ~= nil,
          "paneh: the master takes the page's own floor as a fixed height")

    -- SCOPED TO ResolvePanelHeight'S BODY. leftPanel:SetHeight appears at its
    -- construction too, so a file-wide find cannot tell "the viewport does not
    -- reach it" from "it is never sized at all".
    local resolve = SRC:match("local function ResolvePanelHeight%(%)(.-)\n    end")
    check(resolve ~= nil, "paneh: the height verb's body can be read")
    resolve = resolve or ""
    check(resolve:find("if not rowsMode then leftPanel:SetHeight(PANEL_H) end", 1, true) ~= nil,
          "paneh: the viewport sizes the master in the ISLAND only")
    check(resolve:find("rightArea:SetHeight(PANEL_H)", 1, true) ~= nil,
          "paneh: ...while the detail takes it in both layouts")
    -- TWO NUMBERS: the SLOT carries the gap to the next band, the FRAME is only as
    -- tall as what it draws. One number lets AdoptBands' `GetHeight() + BAND_GAP`
    -- read a height that already contains a gap, and every rebuild adds another.
    check(resolve:find("rightArea.dfSetHeight(PANEL_H + BAND_GAP, PANEL_H)", 1, true) ~= nil,
          "paneh: ...and re-reports it to the band, which is what the layout reads")
    check(resolve:find("spacer.layoutHeight", 1, true) ~= nil,
          "paneh: ...the island still carries its total on the spacer")

    -- The numbers, read out of the two files that own them rather than copied.
    local capFrac = tonumber((ui_file_source("PopoutRow.lua"):match("local CAP_FRAC = ([%d%.]+)")))
    local floorH  = tonumber((SRC:match("local PANEL_H_MIN = (%d+)")))
    check(capFrac and floorH, "paneh: the cap fraction and the page's floor can be read")
    capFrac, floorH = capFrac or 0, floorH or 0
    -- A 768px screen is the shortest anyone plays on, and the pane holds the
    -- master plus the action strip under it. If the floor ever grows past the cap
    -- this fails, which is the moment the master needs a different home rather
    -- than a bigger number.
    check(floorH < capFrac * 768,
          "paneh: the master fits the pane's ceiling on the shortest screen in use")
end

-- ============================================================
-- 5. THE NARROW WINDOW -- WHAT 850px WAS HIDING HERE
-- ------------------------------------------------------------
-- The band is DERIVED, not quoted: window minimum, less the nav pane and the
-- window's own padding, less the page's inset and scroll gutter, less the two
-- column margins. Every one of those is read from the file that declares it, so
-- a retuned scrollbar or a wider nav moves this test with the layout.
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
    -- ...which is ~301px at the 520px minimum, not the ~280 the band's own floor
    -- suggests -- the floor is only reached on a window narrower than the client
    -- allows. Both of the overflows below are measured against the REAL number.
    check(bandW > 290 and bandW < 315,
          "narrow: the band at the window's minimum is ~301px")

    -- ---- the consumer chips ----
    local chipMin  = num(SRC, "local CHIP_MIN_W  = (%d+)")
    local chipGap  = num(SRC, "local CHIP_GAP  = (%d+)")
    local chipH    = num(SRC, "local CHIP_H = (%d+)")
    check(chipMin and chipGap and chipH, "narrow: the chip constants can be read")
    -- Three chips at the floor, their two gaps, the help glyph and its gutter.
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
    -- CLASS ONE: a height measured before layout and then SPENT. This runs from
    -- OnSizeChanged, when the real width finally arrives, and re-reports rather
    -- than leaving every band below it at a stale offset.
    check(chips:find("chipRow.dfSetHeight(h + BAND_GAP, h)", 1, true) ~= nil,
          "narrow: ...and the band is TOLD, so nothing below sits at a stale offset")
    -- ONE HEIGHT WRITER. Both dfSetHeight and a bare SetHeight fire OnSizeChanged,
    -- which is what re-runs this -- two of them is a size change answering a size
    -- change. The island branch is the one that may set the frame directly, because
    -- there the frame is not a band.
    check(chips:find("chipRow.dfSetHeight(h + BAND_GAP, h)\n        else\n            chipRow:SetHeight(h)", 1, true) ~= nil,
          "narrow: ...by ONE writer, the band's or the island's, never both")

    -- ...and the band's own height verb keeps the two apart. Scoped to BandHeight's
    -- body: `layoutHeight` is written by the layout pass and read all over.
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
    -- The help glyph pins to the row's TOP right: a centre anchor would slide it
    -- down as the row grows, away from the chips it belongs beside.
    check(SRC:find('helpBtn:SetPoint("TOPRIGHT", 0, 0)', 1, true) ~= nil,
          "narrow: ...and the help glyph stays beside the FIRST row of chips")

    -- ---- CLASS TWO: header row 3, a row of fixed-width children ----
    -- The Spell ID box, the Add button and the Add-from-Database button are all
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
    -- ...and only when it actually moved: this runs FROM OnSizeChanged.
    check(hdr:find("if (headerPanel:GetHeight() or 0) ~= wantH then headerPanel:SetHeight(wantH) end", 1, true) ~= nil,
          "narrow: ...written back only when it changed, so the resize cannot loop")
    -- THE ECHO KEEPS ITS ROOM, which is why the button moves instead of the three
    -- shrinking. It is the only feedback an add-by-ID gives, and at zero width it
    -- fails silently -- you type an id, nothing happens, nothing says why.
    check(hdr:find('echoText:SetPoint("RIGHT", headerPanel, "RIGHT", -10, 0)', 1, true) ~= nil,
          "narrow: ...and the echo takes the room the picker left")
    check(SRC:find('headerPanel:SetScript("OnSizeChanged", LayoutHeaderRows)', 1, true) ~= nil,
          "narrow: re-taken on resize, not decided once at build")
end

-- ============================================================
-- 6. THE CROSS-PAGE ENTRY POINTS STILL LAND
-- ------------------------------------------------------------
-- Three other pages navigate here by name and then call one of these two. A
-- pulse inside a shut panel is no cue at all -- the same argument that made the
-- scroll part of them in the first place.
-- ============================================================
print("-- Filter Designer: the entry points")
do
    check(SRC:find("local row = pageRef._fdFilterRow", 1, true) ~= nil,
          "entry: the opener reads the row at CALL time...")
    check(SRC:find("if row and row.OpenPopout then row:OpenPopout() end", 1, true) ~= nil,
          "entry: ...and opens it through the kit's own verb")

    -- SCOPED TO EACH ENTRY POINT'S BODY. OpenFilterList is DECLARED in this file
    -- and called from both, so a file-wide find answers "is this name anywhere"
    -- and stays green with either call deleted.
    local newf = SRC:match("pageRef%._fdFocusNewFilter = function%(%)(.-)\n    end")
    check(newf ~= nil, "entry: the new-filter entry point can be read")
    check((newf or ""):find("OpenFilterList()", 1, true) ~= nil,
          "entry: 'Create Filter' opens the list before it pulses the row in it")
    local focus = SRC:match("pageRef%._fdFocusFilter = function%(kind, key%)(.-)\n    end")
    check(focus ~= nil, "entry: the named-filter entry point can be read")
    check((focus or ""):find("OpenFilterList()", 1, true) ~= nil,
          "entry: 'Manage Filters' does too")
    -- BEFORE the selection moves: SelectFilter runs RefreshAll, which re-binds the
    -- pooled rows, so the open has to happen first for the pulse to land on the
    -- row this filter now occupies.
    local o = (focus or ""):find("OpenFilterList()", 1, true)
    local s = (focus or ""):find("SelectFilter(kind, key)", 1, true)
    check(o and s and o < s,
          "entry: ...and opens BEFORE the selection moves and re-binds the pool")
end

-- ============================================================
-- 7. THE FLOOR IS GONE -- THE ACCEPTANCE TEST
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
-- 8. NO SCHEMA CHANGE
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
