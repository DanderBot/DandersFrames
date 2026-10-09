local NS = ...

-- ============================================================
-- FILTER DESIGNER PAGE BUILDERS -- FilterRegistry/UI/Options.lua
-- ------------------------------------------------------------
-- `auras_filterdesigner` is a two-column master/detail ISLAND: the list of
-- filters on the left, the selected filter's header and spell list on the right,
-- anchored straight onto the page child with a spacer carrying its height
-- through the standard layout pass.
--
-- ⚠ 2026-09-26: the page's Modern "band arm" -- one popout row per filter, each
-- panel carrying that filter's own header and spell list -- was deleted along
-- with the other designers' rows pages. The designers build their classic
-- version in both settings layouts (decided 2026-09-22), so the arm had been
-- unreachable since then. What is left here pins the island.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY -- it is welded to a real ScrollFrame, a
-- real settings group, GUI.contentFrame and DF.db -- so this file does what
-- test_auradesigner_page_builders does and asserts against the SOURCE.
-- ============================================================

local SRC   = options_file_source("FilterRegistry/UI/Options.lua")
local AURAS = options_file_source("GUI/Pages/Auras.lua")
local PANEL = options_file_source("GUI/Panel.lua")

-- ============================================================
-- 1. THE PAGE IS THE ISLAND
-- ============================================================
print("-- Filter Designer: the page is the island")
do
    check(SRC:find("function DF.BuildFilterDesignerPage(guiRef, pageRef, dbRef, Add, AddSpace)", 1, true) ~= nil,
          "layout: the builder keeps BuildPage's signature")
    -- SCOPED TO THE PAGE'S OWN BUILDER CALL, not the file: Auras.lua also builds
    -- the Aura Designer, so a file-wide find answers "does anything here pass Add".
    local call = AURAS:match("if DF%.BuildFilterDesignerPage then(.-)\n        end")
    check(call ~= nil, "layout: the page host's call to it can be read")
    call = call or ""
    check(call:find("DF.BuildFilterDesignerPage(GUI, self, db, Add, AddSpace)", 1, true) ~= nil,
          "layout: ...and the host hands them over")

    -- The band arm is gone, and nothing is left that asked for it.
    check(SRC:find("CreatePopoutPageTools", 1, true) == nil,
          "layout: the page takes no popout page tools")
    check(SRC:find("rowsMode", 1, true) == nil,
          "layout: ...and nothing branches on a rows layout")
    check(SRC:find("BuildDesignerShell(", 1, true) == nil,
          "layout: the page does not build a designer shell")
    check(SRC:find("_fdAdoptBands", 1, true) == nil,
          "layout: ...and has no bands to re-adopt on a rebuild")

    -- The island's own height reaches the page through its spacer, on every build.
    check(SRC:find('local spacer = CreateFrame("Frame", nil, parent)', 1, true) ~= nil,
          "layout: the island's spacer is always built")
    check(SRC:find("pageRef._fdSpacer:SetParent(p)", 1, true) ~= nil,
          "layout: ...and re-adopted on a rebuild, since the frames are built once")
end

-- ============================================================
-- 2. THE NARROW WINDOW -- WHAT 850px WAS HIDING HERE
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
    check(bandW > 290 and bandW < 315,
          "narrow: the band at the window's minimum is ~301px")

    -- ---- the consumer chips share a row, and wrap ----
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
    check(chips:find("chipRow:SetHeight(h)", 1, true) ~= nil,
          "narrow: ...and the row takes the height of the rows it wrapped to")
    check(SRC:find('chipRow:SetScript("OnSizeChanged", LayoutChips)', 1, true) ~= nil,
          "narrow: ...re-taken whenever the band changes width")
    check(SRC:find("helpBtn", 1, true) == nil and SRC:find("ShowFilterHelp", 1, true) == nil,
          "narrow: no help glyph -- the banner already says what its popup said")

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
end

-- ============================================================
-- 3. THE CROSS-PAGE ENTRY POINTS STILL LAND
-- ------------------------------------------------------------
-- Three other pages navigate here by name and then call one of these two. A cue
-- that lands off screen is no cue at all, so the scroll is part of it.
-- ============================================================
print("-- Filter Designer: the entry points")
do
    local newf = SRC:match("pageRef%._fdFocusNewFilter = function%(%)(.-)\n    end")
    check(newf ~= nil, "entry: the new-filter entry point can be read")
    newf = newf or ""
    check(newf:find("leftScroll:SetVerticalScroll(", 1, true) ~= nil,
          "entry: 'Create Filter' scrolls the add row into view")
    check(newf:find("DF:HighlightWidget(addRow)", 1, true) ~= nil,
          "entry: ...and pulses it")

    local focus = SRC:match("pageRef%._fdFocusFilter = function%(kind, key%)(.-)\n    end")
    check(focus ~= nil, "entry: the named-filter entry point can be read")
    focus = focus or ""
    -- BEFORE the row is looked for: SelectFilter runs RefreshAll, which re-binds
    -- every pooled row, so the walk has to happen after that or the row is a
    -- different filter's.
    local s = focus:find("SelectFilter(kind, key)", 1, true)
    local w = focus:find("for _, row in ipairs(leftRows) do", 1, true)
    check(s and w and s < w,
          "entry: 'Manage Filters' selects first, then finds the re-bound row")
    check(focus:find("DF:HighlightWidget(row)", 1, true) ~= nil,
          "entry: ...and pulses THAT filter's row")
end

-- ============================================================
-- 4. THE FLOOR IS GONE -- THE ACCEPTANCE TEST
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
-- 5. NO SCHEMA CHANGE
-- ------------------------------------------------------------
-- Filters are user data. The one place a page silently writes a new profile key
-- is a collapsible section, which persists its fold under the section's TITLE
-- TEXT unless told otherwise -- and filter names are typed by the user.
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
