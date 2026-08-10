local addonName, DF = ...
local GUI = {}
DF.GUI = GUI

-- Mutable module state.
-- These four were file-scope locals, and two of them are read and written more
-- than 6,000 lines apart. That is harmless in one file and silently broken the
-- moment the file is split: a `local` re-declared in the second half becomes an
-- independent variable, so the two halves stop sharing state with no error.
-- Holding them on one table keeps a future split honest -- each part reads the
-- same table via `local S = GUI._state`. Read-only aliases (the C_* colours, L,
-- GUI itself) do not need this: re-declaring those yields the same value.
-- Private by convention -- nothing outside this file should touch GUI._state.
local S = {}
GUI._state = S

-- Shared private helpers.
-- A `local function` is invisible to any other file, so a helper used thousands
-- of lines from its declaration pins this file together: it cannot be split
-- while a later section still calls it. Publishing the wide-reaching ones here
-- lets a sibling file re-declare `local X = GUI._priv.X` -- the same function
-- object, so no call site changes and behaviour is identical.
-- Only helpers spanning >1000 lines are listed; narrow ones stay private.
-- Private by convention -- nothing outside GUI/ should touch GUI._priv.
local P = {}
GUI._priv = P

-- =========================================================================
-- MODERN UI CONSTANTS & STYLING (Matching Original v2.3.8)
-- =========================================================================

local C_BACKGROUND = {r = 0.08, g = 0.08, b = 0.08, a = 0.95}  -- Dark charcoal
local C_PANEL      = {r = 0.12, g = 0.12, b = 0.12, a = 1}     -- Slightly lighter
local C_ELEMENT    = {r = 0.18, g = 0.18, b = 0.18, a = 1}     -- Element backgrounds
local C_BORDER     = {r = 0.25, g = 0.25, b = 0.25, a = 1}     -- Subtle borders
local C_ACCENT     = {r = 0.45, g = 0.45, b = 0.95, a = 1}       -- Party Purple-Blue
local C_RAID       = {r = 1.0, g = 0.5, b = 0.2, a = 1}        -- Raid Orange
local C_HOVER      = {r = 0.22, g = 0.22, b = 0.22, a = 1}
local C_TEXT       = {r = 0.9, g = 0.9, b = 0.9, a = 1}
local C_TEXT_DIM   = {r = 0.6, g = 0.6, b = 0.6, a = 1}
local C_WARNING    = {r = 0.95, g = 0.35, b = 0.35, a = 1}     -- Soft red: behaviour-change / caution notes

-- Exported palette: other files should theme against these shared tables instead
-- of re-declaring private copies or hardcoding the raw numbers. These are the
-- SAME table references as the locals above. For the mode-aware accent, use
-- GUI.GetThemeColor() (returns party purple or raid orange).
GUI.Colors = {
    background = C_BACKGROUND,
    panel      = C_PANEL,
    element    = C_ELEMENT,
    border     = C_BORDER,
    accent     = C_ACCENT,   -- party purple
    raid       = C_RAID,     -- raid orange
    hover      = C_HOVER,
    text       = C_TEXT,
    textDim    = C_TEXT_DIM,
    warning    = C_WARNING,  -- soft red for behaviour-change / caution notes
}

-- Dialog chrome. Popup.lua is a standalone dialog rather than a settings page and
-- wanted the same handful of extras on top of the shared neutrals — so it had
-- grown a private copy of the WHOLE palette (11 hardcoded colours), matching
-- today only by luck. (WizardBuilder.lua was the other such dialog, since
-- deleted as dead code — hence "three separate copies" in the note below.)
-- One owner: the neutrals below are the SAME tables as GUI.Colors, so they
-- theme-track in lockstep, and only what genuinely differs is declared here.
-- Read-only by convention — these tables are shared, so nothing may mutate them.
GUI.DialogColors = {
    -- Dialogs use the SAME ground as the pages. This was a bespoke 0.97 in three
    -- separate copies, a shade denser than the pages' 0.95 for no reason anyone
    -- could point at; consolidating the copies made the difference visible and
    -- it went. Chrome now reads identically whether it's a page or a dialog.
    background = C_BACKGROUND,
    panel      = C_PANEL,
    element    = C_ELEMENT,
    border     = C_BORDER,
    accent     = C_ACCENT,     -- fallback only; live dialogs read GetThemeColor()
    hover      = C_HOVER,
    text       = C_TEXT,
    textDim    = C_TEXT_DIM,
    selected   = {r = 0.28, g = 0.28, b = 0.45, a = 1},
    -- Status pair for dialog content (valid/invalid rows, ok/error dots).
    green      = {r = 0.2,  g = 0.9,  b = 0.2},
    red        = {r = 0.9,  g = 0.25, b = 0.25},
    orange     = {r = 0.85, g = 0.55, b = 0.1},
}

-- Canonical row heights (the "airier" scale). A fixed-height widget factory stamps its own slot
-- height onto the widget (widget.preferredHeight + widget.fixedRowHeight), so the layout uses THAT
-- and a call-site number can't make the same widget type render at a different height on a different
-- page. New callers can omit the height entirely; legacy call-site numbers on fixed widgets are
-- ignored (harmless, strippable later). Variable widgets (labels, headers, spacers) are NOT stamped
-- and keep whatever height they are given. One place to retune the whole GUI's vertical rhythm.
-- THE vertical rhythm of the whole GUI.
--
-- These are SLOT heights, not gaps -- LayoutChildren stacks rows flush
-- (y = y - height), so the gap the eye sees between two rows is:
--
--     (slot - content) of the row above  +  (content's top inset) of the row below
--
-- which means a row whose content is short inside a tall slot silently gets a big
-- gap. That is how the GUI ended up with a 4x spread. /df debug gapcheck measured it
-- across four pages (267 rows), and the content heights came back IDENTICAL on
-- every page, so the slots can be derived rather than guessed:
--
--     kind          content   old slot   old gap      new slot   new gap
--     slider          32.0       55        23.0          46        14
--     dropdown        39.8       55        15.2          54        14
--     editbox         39.0       55        16.0          53        14
--     colorpicker     23.9       30         6.1          38        14
--     checkbox        18.2       30        11.8*         35        14*
--     header          11.9    34 / 40   11.0 / 17.0      37        14
--
-- So: ONE gap, and every slot is content + RowGap. 14 is not arbitrary -- it is
-- what the dropdown rows already had (15.2), the one spacing Krathe confirmed
-- reads correctly. Sliders lose 9px of slack, colour pickers gain 8.
--
-- * the checkbox's content sits 2.9px below its slot top, so a row landing ON a
--   checkbox reads 14 + 2.9. Zeroing that would mean re-anchoring the checkbox
--   art itself, which moves the tick 3px for 3px -- not worth it.
--
-- A header keeps its 11.1px top inset, so the gap ABOVE a header is 14 + 11.1.
-- That is deliberate: a section title wants air above it and to sit close to
-- what it labels.
GUI.RowGap = 14

-- ...with ONE exception: a RUN of the same COMPACT row type closes up.
--
-- A uniform gap everywhere is right between DIFFERENT kinds -- that is the
-- boundary the eye uses to tell one control apart from the next. But eight
-- checkboxes in a column are one list, not eight things, and 14 between each of
-- them reads as a stack of unrelated rows. So consecutive rows of the same
-- compact kind get RowGapTight, and the first row of a different kind after them
-- gets the full RowGap back. Same spacing between TYPES, tighter within a type.
--
-- Compact means the label sits INLINE with the control (a checkbox's text is
-- beside its tick). Slider, dropdown and edit box are deliberately NOT compact:
-- their label sits ABOVE the control, so tightening the gap there would push the
-- next row's label into the control above it -- the same reasoning already
-- recorded on labelPad, and the reason a stack of sliders needs real air even
-- though a stack of checkboxes does not.
GUI.RowGapTight = 8
GUI.RowCompact = {
    checkbox    = true,
    toggle      = true,
    colorpicker = true,
}

-- PAGE-level spacing, a different axis from the row rhythm above: AddSpace
-- inserts a spacer into the page's COLUMN flow, between groups, not between rows
-- inside one. Groups already carry a 10px margin of their own, so these stack ON
-- TOP of that -- a `section` break reads as 20 between two groups, a `block` as
-- 30.
--
-- The audit found 58 AddSpace calls passing 9 different numbers, which looked
-- worse than it was: classified by INTENT rather than by value, two idioms cover
-- 42 of them and both were already internally consistent --
--
--   section break (after `currentSection = nil`, or a bare gap after a group)
--       19/19 at 10, plus 7 more following an Add(<group>)
--   before the See-Also links at the foot of a page
--       15/16 at 20, one stray 15
--
-- The real inconsistency was three files each picking their own number for the
-- SAME intent (NicknamesPage used 12 throughout), not 9 competing rhythms.
GUI.Space = {
    section = 10,   -- between logical sections in a page column
    block   = 20,   -- before a distinct trailing block (the See-Also links)
    footer  = 12,   -- below the See-Also bar when it is parked at the viewport bottom
}

GUI.RowHeight = {
    checkbox    = 35,   -- 2.9 top inset + 18.2 content + RowGap
    slider      = 46,   -- 32.0 content + RowGap  (was 55: a slot sized for the dropdown)
    dropdown    = 54,   -- 39.8 content + RowGap
    colorpicker = 38,   -- 23.9 content + RowGap
    editbox     = 53,   -- 39.0 content + RowGap (box at -15, h24)
    -- ⚠ NO `toggle` ENTRY, deliberately. One was declared here (35, "same content as a
    -- checkbox") and referenced by nothing: CreateRowToggle and CreateSegmentToggle are
    -- the only toggles and neither sets fixedRowHeight, so both take whatever height
    -- their call site passes. Removed rather than wired up — enforcing it would resize
    -- every existing toggle row, which is a visual change, not a tidy-up. Toggles are
    -- caller-sized by design; if that should change, change it deliberately.
    -- Labels are VARIABLE height (they wrap), so they have no fixed row — but they do
    -- have fixed CHROME, which CreateLabel adds to the measured text height: the 5px top
    -- inset its FontString sits at, plus the gap below. That gap IS the whole visible
    -- space to the next row — LayoutChildren stacks rows flush (y = y - height) and a
    -- labelled control (dropdown/slider/editbox) puts its own label at TOPLEFT 0,0 — so a
    -- smaller pad reads as a blurb crowding the control it describes.
    labelPad    = 5 + GUI.RowGap,
    -- EVERY section header, collapsible or not. CreateHeader's container is 25
    -- tall with its text pinned to the BOTTOM, so its 11.1px of internal padding
    -- all sits ABOVE the text and this slot minus 25 is the entire visible gap
    -- below it -- at exactly 25 there is none.
    --
    -- The old split was never designed: collapsible groups were handed 25 (no
    -- gap) and plain ones 40, across both files, for the same construct. Rather
    -- than sweep ~200 call sites, CreateHeader now marks itself fixedRowHeight,
    -- so ResolveRowHeight IGNORES the literal a call site passes and every header
    -- lands here. That is the same rule the other factory rows already follow.
    sectionHeader = 11.1 + 11.9 + GUI.RowGap,   -- top inset + text + the gap
}

-- Resolve the layout slot height for a widget being added to a group/page. Fixed-height widgets
-- own their height (drift-proof); everything else uses the height it was handed, then the widget's
-- own preferred height, then a sane default.
local function ResolveRowHeight(widget, height)
    if widget and widget.fixedRowHeight and widget.preferredHeight then
        return widget.preferredHeight
    end
    return height or (widget and widget.preferredHeight) or 55
end
GUI.ResolveRowHeight = ResolveRowHeight


-- "/df debug guiwidth" — width ground truth for the page on screen: every top-level child and
-- every settings-group child with its live width, flagging any that is non-positive or
-- narrower than its group allows.
-- Use it to TELL APART the two causes of truncated label text, which look identical:
--   * a real width fault  -> frames show up flagged here;
--   * a stale FontString wrap -> every width reads correct and the count is 0, yet the
--     text is visibly ellipsised (and scrolling the window snaps it back, because that
--     re-renders the string). That is CreateLabel's Reflow case, not a sizing bug.
-- Recorded because the second one cost two wrong fixes before this dump ruled out the first.
function GUI:DebugDumpWidths()
    local page = GUI.CurrentPageName and GUI.Pages[GUI.CurrentPageName]
    if not page or not page.children then
        DF:Say("GUI width", "no built page on screen", "WARN")
        return
    end
    local content = GUI.contentFrame and GUI.contentFrame:GetWidth() or -1
    local o = DF:Out("GUI Width", ("page '%s'"):format(GUI.CurrentPageName))
    o:Section("Widths")
    o:Field("content frame", ("%.0f"):format(content), content > 0 and "GOOD" or "BAD")
    o:Field("scroll child", ("%.0f"):format(page.child and page.child:GetWidth() or -1), "NEUTRAL")

    o:Section("Widgets")
    local bad = 0
    local function flag(w, limit)
        if not w or w <= 0 then bad = bad + 1; return "|cffff4444 <== NON-POSITIVE|r" end
        if limit and w < limit - 1 then bad = bad + 1; return "|cffffcc00 <== NARROW|r" end
        return ""
    end
    for i, widget in ipairs(page.children) do
        if widget.isSettingsGroup then
            local gw = widget:GetWidth() or 0
            local inner = gw - (widget.padding or 10) * 2
            print(("  [%d] group  w=%.0f inner=%.0f col=%s shown=%s%s")
                :format(i, gw, inner, tostring(widget.layoutCol), tostring(widget:IsShown()), flag(gw)))
            for j, entry in ipairs(widget.groupChildren or {}) do
                local c = entry.widget
                local cw = c and c:GetWidth() or 0
                print(("      (%d) w=%.0f h=%.0f shown=%s%s")
                    :format(j, cw, entry.height or -1, tostring(c and c:IsShown()), flag(cw, inner)))
            end
        else
            local w = widget:GetWidth() or 0
            print(("  [%d] widget w=%.0f col=%s shown=%s%s")
                :format(i, w, tostring(widget.layoutCol), tostring(widget:IsShown()), flag(w)))
        end
    end
    o:Section("Result")
    o:Field("suspect frames", bad, bad > 0 and "WARN" or "GOOD")
    o:Siblings("guiwidth")
end

-- ☠ THE REGISTRY MUST BE COMPLETE BEFORE ANYTHING READS IT.
--
-- DF:SectionOwnsKey (Core/Profile.lua) resolves prefix collisions by LONGEST MATCHING
-- PREFIX ACROSS THE WHOLE REGISTRY. That is only correct if every page is present.
-- Registration used to happen inside CreateCopyButton, inside a page's builderFunc,
-- which GUI Panel's DoBuild calls only on the FIRST VISIT to that page -- and skips
-- entirely for a page disabled in the current mode.
--
-- So the answer depended on which tabs you had opened this session. Fresh login →
-- Auras → Debuffs, without ever opening Aura Filters: auras_filterdesigner is absent,
-- its debuffFilter* / debuffBlacklist prefixes are not there to out-rank the Debuffs
-- page's plain "debuff", and Reset Page wipes the user's entire debuff blacklist and
-- all six filter toggles. Open Aura Filters first and the identical click is safe.
-- Same shape on Copy to Raid and on DF:SyncLinkedSections.
--
-- Seeding it here fixes a second, quieter case too: DF:SyncLinkedSections runs from
-- DF:UpdateAll() in the MAIN addon, which can run with the options companion never
-- loaded -- in which case the registry was simply empty and linked sections silently
-- did not sync at all.
--
-- ⚠ THIS TABLE MUST STAY IN STEP WITH THE CreateCopyButton CALL SITES. It was
-- transcribed from them via the AST rather than by hand, and CreateCopyButton still
-- writes its own entry on build, so a page that drifts self-heals once visited -- but
-- a drifted entry re-opens exactly the bug above until then. If you add or change a
-- section, change it here too.
DF.SECTION_PREFIXES = {
    -- ⚠ buffFilterSelection is listed EXPLICITLY here rather than left to "buff":
    -- it does not share a prefix with the rest, and the page that shows the control
    -- must own the key it writes.
    auras_buffs                  = { "buff", "showBuffs", "directBuff", "buffFilterSelection" },
    auras_debuffs                = { "debuff", "showDebuffs", "directDebuff", "debuffBlacklist" },
    auras_defensiveicon          = { "defensiveIcon", "defensiveFilterSelection", "defensiveSortOrder", "defensiveDurationBar", "defensiveBar" },
    auras_dispel                 = { "dispel" },
    -- ☠ auras_filterdesigner OWNS NOTHING, and the empty table is the statement.
    -- It used to claim buffFilterSelection, debuffFilter*, debuffBlacklist and the
    -- directBuff*/directDebuff* switches, because it displayed all of them. It no
    -- longer displays ANY of them -- filter selection moved to the consumer pages --
    -- so every key went back to the page whose controls now show it.
    --
    -- A control must write where it reads: leaving a claim here would let Reset Page
    -- on the filter library silently rewrite the Buff Bar's and Debuff Bar's
    -- settings, and SectionOwnsKey resolves by LONGEST matching prefix across the
    -- WHOLE registry, so a stale long entry here would outrank the real owner's
    -- shorter one and win keys back invisibly.
    --
    -- What this page does edit is not per-mode at all: preset overrides are per
    -- PROFILE, custom filters are per ACCOUNT. Neither is reachable by Copy to Raid
    -- or Sync with Raid, which is why owning nothing here is correct rather than a
    -- gap to be filled in later.
    auras_filterdesigner         = {},
    auras_missingbuffs           = { "missingBuff" },
    bars_absorb                  = { "absorbBar", "healAbsorb" },
    bars_healpred                = { "healPrediction" },
    bars_health                  = { "healthColor", "healthOrientation", "healthTexture", "classColor", "smoothBars", "background", "missingHealth", "reducedMaxHealth" },
    bars_resource                = { "resourceBar" },
    display_fading               = { "rangeFade", "rangeCheck", "rangeUpdate", "oor", "fadeDead", "healthFade", "hf" },
    display_pets                 = { "pet" },
    display_tooltips             = { "tooltip" },
    display_visibility           = { "soloMode", "hidePlayerFrame", "restedIndicator" },
    general_fonts                = { "fontShadow" },
    general_frame                = { "frame", "permanentMover", "border", "anchor" },
    general_labels               = { "groupLabel" },
    general_pinnedframes         = { "pinnedFrames" },
    general_sorting              = { "sort", "useFrameSort", "selfPosition", "rolePriority", "classPriority" },
    indicators_highlights        = { "selectionHighlight", "hoverHighlight", "aggroHighlight", "aggro" },
    indicators_icons             = { "roleIcon", "leaderIcon", "raidTargetIcon", "readyCheckIcon", "summonIcon", "resurrectionIcon", "phasedIcon", "afkIcon", "vehicleIcon", "raidRoleIcon", "bgCarrierIcon", "combatIcon", "statusIconFont", "statusIconFontSize", "statusIconFontOutline" },
    indicators_personal_targeted = { "personalTargeted" },
    indicators_targetedlist      = { "targetedList" },
}

DF.SectionRegistry = DF.SectionRegistry or {}

-- Seed eagerly at load. CreateCopyButton overwrites its own entry on first build,
-- which is harmless (same value) and keeps the self-heal described above.
for pageId, prefixes in pairs(DF.SECTION_PREFIXES) do
    if DF.SectionRegistry[pageId] == nil then
        DF.SectionRegistry[pageId] = prefixes
    end
end


-- Track selected mode
GUI.SelectedMode = "party"

-- Registry of tabs that should show a "New" badge until opened.
-- Add tab IDs here for new features; the badge auto-hides once viewed.
-- Reset each release cycle to the tabs that are new since the last stable
-- (prior entries are persisted as seen and would otherwise show stale badges).
GUI.NewTabs = {
    ["text_designer"] = true,
    ["general_nicknames"] = true,
}

-- Registry of section headers (inside a tab) that should show a "New" badge
-- until the user visits the tab and then navigates away. Keyed by
-- "<tabName>.<sectionId>" so entries are unambiguous across tabs.
-- The badge is created by GUI:AddSectionNewBadge and cleared by SelectTab
-- when the user leaves the owning tab (persisted via seenSections).
GUI.NewSections = {
}

-- Live-tracked badges pending a "seen" mark, keyed by tabName → { key = badge }.
-- Populated by AddSectionNewBadge, drained by SelectTab on tab leave.
GUI.pendingSectionBadges = {}


-- Pages that remain fully accessible regardless of whether party or raid
-- mode is disabled via General settings. All other mode-specific tabs
-- are greyed out and non-interactive when viewing a disabled mode.
-- Auto Layouts is intentionally NOT whitelisted: it edits per-profile
-- settings that would have no effect if all frames are disabled.
GUI.AlwaysAccessiblePages = {
    ["general_settings"]             = true,  -- the toggles themselves
    ["profiles_manage"]              = true,
    ["profiles_importexport"]        = true,
    ["debug_console"]                = true,
    ["indicators_targetedlist"]      = true,
    ["indicators_personal_targeted"] = true,
}



-- Track currently open dropdown menu (only one can be open at a time)
S.currentOpenDropdown = nil

-- Close any currently open dropdown
local function CloseOpenDropdown()
    if S.currentOpenDropdown and S.currentOpenDropdown:IsShown() then
        S.currentOpenDropdown:Hide()
    end
    S.currentOpenDropdown = nil
end
P.CloseOpenDropdown = CloseOpenDropdown

-- Helper to get current theme color
-- The theme colour for an EXPLICIT mode. Use this for any surface that belongs to
-- a mode rather than to whatever page the options window happens to be showing --
-- movers, pinned containers -- so a raid surface stays orange while the window is
-- on a party page. GetThemeColor() below is the follow-the-window variant.
local function GetThemeColorFor(isRaid)
    if isRaid then return C_RAID else return C_ACCENT end
end
GUI.GetThemeColorFor = GetThemeColorFor

local function GetThemeColor()
    return GetThemeColorFor(GUI.SelectedMode == "raid")
end
GUI.GetThemeColor = GetThemeColor

-- Cursor position in FRAME's own coordinate space.
--
-- ☠ NEVER DIVIDE THE CURSOR BY UIParent:GetEffectiveScale() FOR A FRAME INSIDE
-- THE SETTINGS WINDOW. GetCursorPosition returns a value you divide by a frame's
-- EFFECTIVE scale to get that frame's coordinates. The settings window carries
-- the user's UI Scale on top of UIParent's, so for anything inside it the two
-- differ by exactly that factor -- while every frame:GetTop()/GetLeft() you
-- compare against is already in the frame's own space. Divide by the wrong one
-- and the comparison is nonsense: at 140% the cursor reads 40% further from the
-- screen edge than it is, which is why drag-to-reorder only ever dropped in the
-- right place at 100%.
--
-- The exception, and why this takes a frame rather than assuming: a frame
-- PARENTED AND ANCHORED to UIParent (the Aura Designer's drag ghost) really does
-- have UIParent's effective scale, so there UIParent is the correct divisor.
-- Pass the frame whose coordinates you are comparing against and it is right
-- either way.
function GUI:CursorPos(frame)
    local scale = frame and frame.GetEffectiveScale and frame:GetEffectiveScale()
    if not scale or scale == 0 then scale = UIParent:GetEffectiveScale() end
    if not scale or scale == 0 then scale = 1 end
    local x, y = GetCursorPosition()
    return x / scale, y / scale
end

-- Physical pixels per UI unit, measured from the frame's OWN effective scale.
-- The GUI window carries a user scale (windowState.scale) on top of UIParent's and is
-- freely resizable, so this is almost never 1 and cannot be read from the
-- addon-wide DF:GetPixelScale (which is relative to UIParent).
local function PixelsPerUnit(frame)
    local eff = frame and frame.GetEffectiveScale and frame:GetEffectiveScale()
    local _, physH = GetPhysicalScreenSize()
    if not (eff and eff > 0 and physH and physH > 0) then return nil end
    return eff * physH / 768
end
P.PixelsPerUnit = PixelsPerUnit

-- ⚠ THERE IS NO RUNTIME GEOMETRY CORRECTION, AND THERE SHOULD NOT BE ONE.
--
-- This GUI used to carry a registry that nudged every bordered box onto the
-- pixel grid after the layout had placed it. It is gone, and the reason is
-- structural rather than a bug in the implementation: Lua-side snapping can only
-- correct a frame at REST, and the symptom it was chasing -- a thin border going
-- soft -- is at its worst while the content is MOVING, during a scroll.
-- Correcting mid-scroll does not fix that, it adds a half-pixel jump on top of
-- it, which reads as flicker. It also cost us the button-row drift, where an
-- unordered sweep corrected chained anchors in a different order each pass.
--
-- Three things replaced it, and between them they are enough:
--   * the LAYOUT picks whole-pixel numbers in the first place (SnapLen below, at
--     the point an offset, width or height is chosen). No runtime cost, nothing
--     to drift, nothing to flicker -- it just picks better numbers.
--   * the CLIP SURFACES are snapped (page viewport insets, the content panel,
--     the nav chain). Those were real bugs: a box clipped by a fractional edge
--     loses part of its border no matter how well the box itself is placed.
--   * the BORDER is drawn as two device pixels of our own texture rather than a
--     one-unit backdrop edge, so it cannot land badly in the first place. See
--     PIXEL BORDER further down -- that is the part that actually solved it.

-- Round a LENGTH or OFFSET (in UI units) to a whole number of device pixels at
-- the scale `frame` is drawn at. This is the layout-side half of the pixel-grid
-- work, and the half that was missing.
--
-- A box lands on the grid only if the numbers it was GIVEN were whole pixels.
-- They usually are not: a group's inner width is (its width - 2 * padding), and
-- its padding is 10 UI units, which is a whole number of device pixels only when
-- the GUI is at exactly 1:1 scale. Everywhere else the box's right and bottom
-- edges fall mid-pixel, and anything clipped by them loses part of itself.
--
-- Snapping at the point the number is CHOSEN fixes that by construction, for
-- everything a layout places, with no per-widget opt-in for anyone to forget.
local function SnapLen(frame, v)
    if not v then return v end
    local ppu = PixelsPerUnit(frame)
    if not ppu then return v end
    return math.floor(v * ppu + 0.5) / ppu
end
GUI.SnapLen = SnapLen

-- SnapLen rounds to the NEAREST device pixel, which can round a width DOWN and
-- clip the text it was measured from. This rounds up instead: for anything whose
-- length comes from a measurement (a button sized to its own label), the width
-- has to be at least what was asked for, and on the grid.
local function SnapLenUp(frame, v)
    if not v then return v end
    local ppu = PixelsPerUnit(frame)
    if not ppu then return v end
    return math.ceil(v * ppu) / ppu
end
GUI.SnapLenUp = SnapLenUp

-- Round a HEIGHT to an EVEN number of device pixels (minimum two).
--
-- Rows of controls are chained with centre-aligning anchors -- SetPoint("RIGHT",
-- prev, "LEFT", gap, 0) aligns the two frames' vertical CENTRES, and the toolbar
-- does the same with LEFT/RIGHT. A frame's centre is bottom + height/2, so if the
-- height is an ODD number of device pixels the centre falls on a half pixel, and
-- every frame chained off it inherits that half-pixel offset no matter how well
-- its own edges are snapped. Even heights make the whole row land together.
--
-- Used for control heights, which the factories set once at construction. Widths
-- do not need this: nothing centre-anchors horizontally off a control.
local function SnapHeightEven(frame, v)
    if not v then return v end
    local ppu = PixelsPerUnit(frame)
    if not ppu then return v end
    return math.max(2, math.floor(v * ppu / 2 + 0.5) * 2) / ppu
end
GUI.SnapHeightEven = SnapHeightEven

-- ============================================================
-- Stamped once when this file loads, so it identifies THIS session (and therefore
-- this build) for the pixelcheck and gapcheck captures. Declared HERE, above the
-- first function that reads it: a local declared further down the file is not an
-- upvalue for a function defined above it -- the read would silently resolve to a
-- nil global and every capture would look like a new session.
local GAP_SESSION = date and date("%Y-%m-%d %H:%M:%S") or "?"

-- /df debug pixelcheck -- measure, don't guess
--
-- The "top border of a box goes missing until you scroll" bug has now been
-- diagnosed twice from reasoning about the layout and fixed twice, and it is
-- still here. The two remaining explanations look IDENTICAL in a screenshot:
--
--   (a) sub-pixel  -- the box's top edge lands between two device rows, so the
--                     1px line is filtered across both at half intensity;
--   (b) clipping   -- the box's top edge sits within a pixel of the ScrollFrame's
--                     own clip boundary, so the line is simply cut off.
--
-- Scrolling "fixes" both, which is exactly why the screenshot can't separate
-- them. This reports the numbers for the open page so the next change is aimed.
-- Debug output: deliberately raw, like the other /df debug dumps.
-- ============================================================

-- Signed distance from `v` (UI units) to the nearest whole device pixel.
local function PixelOffsetOf(v, ppu)
    if not v or not ppu then return nil end
    local px = v * ppu
    return px - math.floor(px + 0.5)
end

local function DescribeFrame(f)
    -- Prefer a human label so the output names the card, not "Frame".
    for _, key in ipairs({ "label", "title", "titleText", "Text", "header" }) do
        local o = f[key]
        if type(o) == "table" and o.GetText then
            local t = o:GetText()
            if t and t ~= "" then return t end
        end
    end
    if f.GetRegions then
        for _, r in ipairs({ f:GetRegions() }) do
            if r.GetObjectType and r:GetObjectType() == "FontString" then
                local t = r:GetText()
                if t and t ~= "" then return t end
            end
        end
    end
    return (f.GetObjectType and f:GetObjectType()) or "Frame"
end

-- Every SHOWN descendant carrying a border -- the only frames that can exhibit
-- this bug (a fill-only surface has no edge to lose).
--
-- Both mechanisms, deliberately. Testing edgeFile alone was right when that was
-- the only way a border got drawn; now that most surfaces own their four
-- textures instead, an edgeFile-only sweep would report a converted page as
-- having no bordered frames at all and the probe would quietly stop being able
-- to see the thing it exists to measure.
local function CollectBorderedFrames(root, out, depth)
    if not root or depth > 10 then return out end
    for _, child in ipairs({ root:GetChildren() }) do
        if child:IsShown() then
            local bd = child.GetBackdrop and child:GetBackdrop()
            if (bd and bd.edgeFile) or child._pxBorder then out[#out + 1] = child end
            CollectBorderedFrames(child, out, depth + 1)
        end
    end
    return out
end

-- What sits ON the box's top border row.
--
-- Geometry came back perfect on BOTH a broken and a working page (BOX 0/n,
-- top+0.00, edge=1.00px, nothing near the clip edge), so the difference is not
-- anything the box itself measures. The one thing that tracked the symptom was
-- how far the first box sits from the top: 62.7px on a page that loses its
-- border vs 76.8px on one that doesn't -- 14.1px apart, which at 1.4062 px/unit
-- is exactly the 10-unit group padding. A box that starts hard against whatever
-- is above it loses the line; one with a gap keeps it. That is the signature of
-- the row above covering it, so: find any sibling whose rect spans the box's top
-- border row, and report it with its frame level.
local function FindTopRowOverlaps(box)
    local out = {}
    local top, bL, bR = box:GetTop(), box:GetLeft(), box:GetRight()
    local parent = box:GetParent()
    if not (top and bL and bR and parent) then return out end
    -- ~1.5 device px expressed in UI units: the border row plus a hair.
    local band = 1.5 / (PixelsPerUnit(box) or 1)
    for _, sib in ipairs({ parent:GetChildren() }) do
        if sib ~= box and sib.IsShown and sib:IsShown() then
            local sT, sB, sL, sR = sib:GetTop(), sib:GetBottom(), sib:GetLeft(), sib:GetRight()
            if sT and sB and sL and sR
                and sB <= top + band and sT >= top - band   -- spans the border row
                and sR > bL and sL < bR then                -- and overlaps horizontally
                out[#out + 1] = ("%s(lvl%d)"):format(
                    DescribeFrame(sib):sub(1, 16), sib:GetFrameLevel() or 0)
            end
        end
    end
    return out
end

function GUI.PixelCheck()
    local page, pageName
    for name, p in pairs(GUI.Pages or {}) do
        if p.IsShown and p:IsShown() then page, pageName = p, name; break end
    end
    if not page then
        DF:Say("Pixel check", "no settings page is open", "WARN")
        return
    end

    local ppu = PixelsPerUnit(page)
    if not ppu then
        DF:Say("Pixel check", "scale unresolved — is the window shown?", "WARN")
        return
    end

    local scroll = page.GetVerticalScroll and page:GetVerticalScroll() or 0
    local scrollOff = PixelOffsetOf(scroll, ppu)
    local clipTop = page:GetTop()

    local o = DF:Out("Pixel Check", ("page %s"):format(tostring(pageName)))
    o:Section("Scale")
    o:Field("effective scale", ("%.4f"):format(page:GetEffectiveScale() or 0), "NEUTRAL")
    o:Field("px per unit", ("%.4f"):format(ppu), "NEUTRAL")

    o:Section("Scroll")
    -- Reported, not judged. This used to print a red NOT SNAPPED when the offset
    -- was off-grid, back when the scroll offset was quantised and being off-grid
    -- meant something had gone wrong. Nothing quantises it now -- a 2px border
    -- draws the same ink at any offset -- so an off-grid figure here is the
    -- normal state of a scrolled page, and flagging it as a fault sends the next
    -- person reading this output after a bug that is not there.
    o:Field("offset", ("%.3f  (%.2f px off grid)"):format(scroll, scrollOff or 0), "NEUTRAL")
    o:Line("Off-grid here is expected — nothing quantises the scroll offset.", "NEUTRAL")

    -- THE CLIP BOUNDARY ITSELF. Earlier runs measured each box's DISTANCE to this
    -- edge but never whether the edge is on-grid. A ScrollFrame clips to its own
    -- rect, so if that rect's top sits on a fractional device row the cut takes a
    -- partial row off whatever is nearest it -- which is exactly the reported
    -- pattern: pages whose boxes start at the top lose the border, pages with a
    -- gap do not. The scroll child is included because content is positioned
    -- against it, so its phase is what every box inherits.
    local dPageTop = PixelOffsetOf(page:GetTop(), ppu)
    local dPageBot = PixelOffsetOf(page:GetBottom(), ppu)
    local dPageH   = PixelOffsetOf(page:GetHeight(), ppu)
    -- Flag EITHER edge. This used to test only the top, so it printed
    -- "bot-0.38" on every run for weeks and never once marked it -- and an
    -- unflagged number in a wall of numbers is an invisible one. The bottom
    -- edge clips whatever rests against it just as hard as the top does, which
    -- is the entire See-Also footer bug.
    local badTop = dPageTop and math.abs(dPageTop) > 0.05
    local badBot = dPageBot and math.abs(dPageBot) > 0.05
    o:Section("Viewport", "the clip edge")
    o:Field("offsets", ("top%+.2f  bot%+.2f  h%+.2f"):format(dPageTop or 0, dPageBot or 0, dPageH or 0),
        (badTop or badBot) and "BAD" or "GOOD")
    if badTop or badBot then
        o:Line(("Clip edge OFF-GRID (%s) — it shaves a partial row off whatever rests against it."):format(
            badTop and (badBot and "top and bottom" or "top") or "bottom"), "BAD")
    end
    local kid = page.child or (page.GetScrollChild and page:GetScrollChild())
    if kid then
        local kppu = PixelsPerUnit(kid) or ppu
        local kidBad = math.abs(PixelOffsetOf(kid:GetTop(), kppu) or 0) > 0.05
        o:Field("scroll child", ("top%+.2f  w%+.2f"):format(
            PixelOffsetOf(kid:GetTop(), kppu) or 0, PixelOffsetOf(kid:GetWidth(), kppu) or 0),
            kidBad and "BAD" or "GOOD")
        if kidBad then
            o:Line("Content is positioned against this, so every box inherits its phase.", "BAD")
        end
    end

    -- "Is it the section BOXES or the controls inside them?" is the question the
    -- first version of this could not answer -- it ranked worst-first and the top
    -- of the list was all controls, so the groups never showed. Classify, and
    -- report the boxes separately no matter where they rank.
    local function KindOf(f)
        if f.LayoutChildren then return "BOX" end        -- CreateSettingsGroup
        if f.slider then return "slider" end
        return (f.GetObjectType and f:GetObjectType()) or "frame"
    end

    local frames = CollectBorderedFrames(page.child or page, {}, 0)
    local rows, offGrid, nearClip = {}, 0, 0
    local byKind = {}
    for _, f in ipairs(frames) do
        local top, bottom, h = f:GetTop(), f:GetBottom(), f:GetHeight()
        local fppu = PixelsPerUnit(f) or ppu
        local dTop = PixelOffsetOf(top, fppu)
        local dBot = PixelOffsetOf(bottom, fppu)
        local dH   = PixelOffsetOf(h, fppu)
        -- Distance from the scroll viewport's top clip edge, in device pixels.
        local clipGap = (top and clipTop) and ((clipTop - top) * fppu) or nil
        if dTop and math.abs(dTop) > 0.05 then offGrid = offGrid + 1 end
        if clipGap and clipGap > -1.5 and clipGap < 1.5 then nearClip = nearClip + 1 end
        -- Edge THICKNESS, which is the leg two earlier revisions of this probe
        -- did not capture and the one that turned out to matter. A box can
        -- measure a perfect 0.00 on every edge and still lose its border if the
        -- edge is drawn a fractional number of device pixels wide: it bleeds
        -- into the next row at partial intensity, and a settings-group edge is
        -- only ~8% alpha over a 3% fill, so both halves can land under the
        -- visibility floor. Alpha is reported alongside because it sets that
        -- floor.
        --
        -- A pixel border reports its own thickness instead: it is authored in
        -- device pixels, so it is a whole number by construction and edgeFrac
        -- is 0 -- which is exactly the point of it, and worth being able to SEE
        -- next to a surface still on the old edge.
        local bdInfo = f.GetBackdrop and f:GetBackdrop()
        local edgeUnits = bdInfo and bdInfo.edgeSize or nil
        -- f._pxDevicePx, not a recomputation from PX_BORDER_THICKNESS: that
        -- constant is declared several hundred lines below this probe, so
        -- naming it here would resolve to a nil GLOBAL, silently. Reading what
        -- LayoutPixelBorder actually drew is both safer and more truthful.
        local edgePx = edgeUnits and (edgeUnits * fppu) or f._pxDevicePx or nil
        local edgeFrac = edgePx and (edgePx - math.floor(edgePx + 0.5)) or nil
        -- NOT `local _,_,_,a = (f:GetBackdropBorderColor())` -- the parentheses
        -- truncate a multi-return to ONE value, so alpha came back nil every time
        -- and every row printed "a=n/a". Alpha is the whole point here: a
        -- settings-group edge is ~8% over a 3% fill, so it has almost no margin.
        local borderA
        if f.GetBackdropBorderColor then
            local _, _, _, a = f:GetBackdropBorderColor()
            borderA = a
        end
        local kind = KindOf(f)
        local bad = (dTop and math.abs(dTop) > 0.05) or false
        local k = byKind[kind]
        if not k then k = { n = 0, bad = 0 }; byKind[kind] = k end
        k.n = k.n + 1
        if bad then k.bad = k.bad + 1 end
        rows[#rows + 1] = {
            label = DescribeFrame(f), kind = kind, bad = bad,
            frame = f, level = f.GetFrameLevel and f:GetFrameLevel() or nil,
            dTop = dTop or 0, dBot = dBot or 0,
            dH = dH or 0, clipGap = clipGap,
            edgePx = edgePx, edgeFrac = edgeFrac, alpha = borderA,
            score = math.max(math.abs(dTop or 0),
                             (clipGap and math.abs(clipGap) < 1.5) and 1 or 0),
        }
    end

    table.sort(rows, function(a, b) return a.score > b.score end)
    o:Section("Bordered frames", #rows)
    o:Field("off-grid top", offGrid, offGrid > 0 and "BAD" or "GOOD")
    o:Field("within 1px of the clip edge", nearClip, nearClip > 0 and "WARN" or "GOOD")

    -- Per-kind tally: this is the line that says whether fixing controls would
    -- also fix the section boxes, or whether they are a separate problem.
    local kindLine = {}
    for kind, k in pairs(byKind) do
        kindLine[#kindLine + 1] = ("%s %d/%d"):format(kind, k.bad, k.n)
    end
    table.sort(kindLine)
    o:Field("by kind (bad/total)", table.concat(kindLine, "  "), "NEUTRAL")

    local function emit(r)
        local flag = ""
        if r.bad then flag = " |cffff6060OFF-GRID|r" end
        if r.clipGap and math.abs(r.clipGap) < 1.5 then flag = flag .. " |cffffaa00AT-CLIP|r" end
        -- A fractional edge width is the failure a perfect 0.00 box can still have.
        if r.edgeFrac and math.abs(r.edgeFrac) > 0.05 then flag = flag .. " |cffff6060SOFT-EDGE|r" end
        if r.alpha and r.alpha < 0.15 then flag = flag .. " |cffffaa00FAINT|r" end
        print(("    [%s] %-22s top%+.2f bot%+.2f h%+.2f edge=%s a=%s clip=%s%s"):format(
            r.kind:sub(1, 6), r.label:sub(1, 22), r.dTop, r.dBot, r.dH,
            r.edgePx and ("%.2fpx"):format(r.edgePx) or "n/a",
            r.alpha and ("%.2f"):format(r.alpha) or "n/a",
            r.clipGap and ("%.1f"):format(r.clipGap) or "n/a", flag))
    end

    -- The section boxes ALWAYS get listed, however they rank -- they are the ones
    -- you can actually see, and ranking buried them last time.
    local boxes = 0
    for _, r in ipairs(rows) do if r.kind == "BOX" then boxes = boxes + 1 end end
    if boxes > 0 then
        o:Section("Section boxes", boxes .. " — the outlines around each section")
        local shown = 0
        for _, r in ipairs(rows) do
            if r.kind == "BOX" and shown < 10 then
                emit(r)
                -- Anything sitting ON this box's top border row is the prime
                -- suspect now that the box's own geometry measures clean.
                local over = r.frame and FindTopRowOverlaps(r.frame) or {}
                if #over > 0 then
                    print(("           |cffff6060^ COVERED BY:|r %s  (box is lvl%s)")
                        :format(table.concat(over, ", "), tostring(r.level)))
                end
                shown = shown + 1
            end
        end
    else
        o:Section("Section boxes")
        o:Line("None found on this page.", "WARN")
    end

    o:Section("Worst overall")
    o:Line("topOff/botOff/heightOff are px from the grid; clip is px below the viewport top.", "NEUTRAL")
    for i = 1, math.min(#rows, 10) do emit(rows[i]) end
    print("  |cff808080Read: OFF-GRID = geometry. SOFT-EDGE = the edge is a fractional number of device px wide, so it bleeds into the next row -- a box can be a perfect 0.00 and still lose its border this way. FAINT = so little alpha that any split is invisible.|r")
    print("  |cff808080Nothing is corrected at runtime any more. Every widget gets its whole-pixel numbers from its FACTORY at construction (nudging them afterwards is what made chained button rows drift), so an off-grid row after a scale change is expected and is not a bug. What still matters here is SOFT-EDGE and FAINT.|r")

    -- Persist, for the same reason gapcheck does: transcribing a screenful of
    -- numbers out of the chat frame is not practical remotely, and every reading
    -- of this symptom that came from eyeballing rather than the file has been
    -- wrong. Same session stamp, so a capture never mixes two builds.
    DandersFramesDebugDB = DandersFramesDebugDB or {}
    if DandersFramesDebugDB.pixelSession ~= GAP_SESSION then
        DandersFramesDebugDB.pixelcheck = nil
        DandersFramesDebugDB.pixelSession = GAP_SESSION
    end
    DandersFramesDebugDB.pixelcheck = DandersFramesDebugDB.pixelcheck or {}
    local pdump = {
        when = date("%Y-%m-%d %H:%M:%S"),
        ppu = ppu, scroll = scroll,
        viewTop = dPageTop, viewBot = dPageBot, viewH = dPageH,
        rows = {},
    }
    for i, r in ipairs(rows) do
        pdump.rows[i] = {
            label = tostring(r.label):sub(1, 40), kind = r.kind,
            dTop = r.dTop, dBot = r.dBot, dH = r.dH,
            edgePx = r.edgePx, alpha = r.alpha, clipGap = r.clipGap,
            level = r.level,
            -- Raw geometry too: the deltas alone cannot distinguish "off-grid"
            -- from "the right size but drawn somewhere unexpected".
            top = r.frame and r.frame:GetTop() or nil,
            bottom = r.frame and r.frame:GetBottom() or nil,
            height = r.frame and r.frame:GetHeight() or nil,
            width = r.frame and r.frame:GetWidth() or nil,
            points = r.frame and r.frame:GetNumPoints() or nil,
        }
    end
    -- Never overwrite an earlier run of the SAME page: the whole point of running
    -- this twice is to compare a broken state against a working one, and keying
    -- purely by page silently threw the first away. Numbered within the session.
    local key, n = tostring(pageName), 1
    while DandersFramesDebugDB.pixelcheck[key] do
        n = n + 1
        key = ("%s #%d"):format(tostring(pageName), n)
    end
    DandersFramesDebugDB.pixelcheck[key] = pdump
    print(("  |cff00ff00saved|r %d rows to DandersFramesDebugDB.pixelcheck[\"%s\"] -- |cffffcc00/reload to flush.|r")
        :format(#rows, key))
end

-- ============================================================
-- /df debug navprobe -- catch the left-nav hover flash in the act
--
-- The symptom: sweeping the cursor down the nav list shows a "ghost" -- of the
-- row's text, or of the bottom part of the hover plate. It happens at moderate
-- speed, not just fast, and it survived snapping the row geometry.
--
-- Four causes would produce that, and they are INDISTINGUISHABLE in a
-- screenshot, which is why this measures instead of reasoning:
--
--   (a) two rows lit at once -- the previous row's OnLeave never ran, so two
--       plates are visible together for a frame or two;
--   (b) focus thrash -- the cursor sits still over one row but mouse focus
--       alternates between it and something else (the scroll frame, a sibling,
--       an overlapping rect), so the plate flickers on and off in place;
--   (c) geometry -- rows overlap, or leave a dead band between them where
--       NOTHING is lit, so crossing it reads as the plate breaking up;
--   (d) none of the above -- a pure rendering artefact, in which case the trace
--       shows exactly one clean enter/leave per row and the answer is elsewhere.
--
-- Static geometry first (overlaps and dead bands are visible without moving the
-- mouse), then a live trace of every change in focus and in each row's plate
-- alpha, stamped with the frame number. (a) and (b) show up as repeated
-- transitions within a single crossing; (c) as a run of frames with nothing lit.
function GUI.NavProbe(seconds)
    local container = GUI.tabContainer
    if not (container and container:IsVisible()) then
        DF:Say("the settings window is not open.")
        return
    end
    local ppu = PixelsPerUnit(container) or 1

    -- Rows in LAYOUT order (top to bottom), which is what makes the neighbour
    -- comparison below meaningful -- GetChildren order is creation order.
    local rows = {}
    for _, catName in ipairs(GUI.CategoryOrder or {}) do
        local cat = GUI.Categories and GUI.Categories[catName]
        if cat and cat:IsShown() then
            rows[#rows + 1] = { f = cat, label = "[" .. tostring(catName) .. "]" }
            for _, btn in ipairs(cat.children or {}) do
                if btn:IsShown() then
                    rows[#rows + 1] = { f = btn, label = DescribeFrame(btn) }
                end
            end
        end
    end

    local o = DF:Out("Nav Probe")
    o:Section("Rows")
    o:Field("visible", #rows, #rows > 0 and "GOOD" or "WARN")
    o:Field("px per unit", ("%.4f"):format(ppu), "NEUTRAL")

    -- The ANCESTOR CHAIN, because a row cannot be on the grid if the frame it
    -- hangs off is not: every ancestor here is two-corner anchored, so nothing
    -- corrects them after the fact and a fraction anywhere propagates to all 42
    -- rows identically. If the rows read a uniform offset, this line says which
    -- link introduced it -- that is how the 4-unit nav inset (0.375px) was found
    -- after the rows themselves measured clean on height.
    local chain, node = {}, container
    while node and #chain < 6 do
        local t = node:GetTop()
        chain[#chain + 1] = ("%s top%+.2f"):format(
            (node.GetObjectType and node:GetObjectType() or "?"):sub(1, 6),
            PixelOffsetOf(t, PixelsPerUnit(node) or ppu) or 0)
        node = node:GetParent()
    end
    print("  chain (row -> window): " .. table.concat(chain, " | "))

    -- Geometry: the gap to the row above, in DEVICE pixels. Negative = the rows
    -- overlap (both can claim the cursor); more than ~1px positive = a dead band
    -- with no row under the cursor at all. Either one produces a visible break.
    local overlaps, bands = 0, 0
    for i, r in ipairs(rows) do
        local f = r.f
        local top, bot, h = f:GetTop(), f:GetBottom(), f:GetHeight()
        local dTop = PixelOffsetOf(top, ppu) or 0
        local dH = PixelOffsetOf(h, ppu) or 0
        local gap
        if i > 1 then
            local prevBot = rows[i - 1].f:GetBottom()
            if prevBot and top then gap = (prevBot - top) * ppu end
        end
        local flag = ""
        if gap and gap < -0.05 then flag = " |cffff6060OVERLAPS ABOVE|r"; overlaps = overlaps + 1
        elseif gap and gap > 1.05 then flag = " |cffffaa00DEAD BAND|r"; bands = bands + 1 end
        if math.abs(dTop) > 0.05 or math.abs(dH) > 0.05 then
            flag = flag .. " |cffffaa00OFF-GRID|r"
        end
        print(("    %-24s top%+.2f h%+.2f gap=%s lvl%d%s"):format(
            r.label:sub(1, 24), dTop, dH,
            gap and ("%.2fpx"):format(gap) or "n/a",
            f:GetFrameLevel() or 0, flag))
    end
    print(("  %d overlapping rows, %d dead bands between rows"):format(overlaps, bands))

    -- Live trace.
    S.navTrace = S.navTrace or CreateFrame("Frame")
    S.navTrace:SetScript("OnUpdate", nil)
    local dur = tonumber(seconds) or 8
    local elapsed, frames, events = 0, 0, 0
    local lastLit, lastFocus = nil, nil
    print(("  |cff00ff00tracing for %ds|r -- sweep the cursor across the nav list now."):format(dur))

    S.navTrace:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        frames = frames + 1

        -- Which row the shared plate is parked on. There is only one plate now, so
        -- "TWO LIT" is structurally impossible -- that is the point of the change,
        -- and this still checks for it in case the plate is ever reintroduced
        -- per-row. No parentheses around the colour call: they would truncate the
        -- multi-return to one value and alpha would read nil every frame -- the
        -- exact mistake that cost three rounds on the border bug.
        local lit = {}
        local hl = GUI.navHover
        if hl and hl:IsShown() and hl.owner then
            local _, _, _, a = hl:GetBackdropColor()
            if a and a > 0.01 then
                for _, r in ipairs(rows) do
                    if r.f == hl.owner then lit[#lit + 1] = r.label:sub(1, 18) break end
                end
            end
        end
        local litKey = table.concat(lit, "+")

        -- What actually owns the mouse. If this is NOT the lit row, the plate and
        -- the focus disagree, which is cause (b).
        local focus = "-"
        local foci = GetMouseFoci and GetMouseFoci()
        local top = (foci and foci[1]) or (GetMouseFocus and GetMouseFocus())
        if top then
            for _, r in ipairs(rows) do if r.f == top then focus = r.label:sub(1, 18) break end end
            if focus == "-" then
                focus = "<" .. ((top.GetObjectType and top:GetObjectType()) or "?") .. ">"
            end
        end

        if litKey ~= lastLit or focus ~= lastFocus then
            events = events + 1
            if events <= 120 then
                print(("    f%-5d t=%.3f  lit=%-24s focus=%s%s"):format(
                    frames, elapsed,
                    (litKey ~= "" and litKey or "(none)"),
                    focus,
                    (#lit > 1) and " |cffff6060TWO LIT|r"
                        or ((litKey == "" and focus ~= "-") and " |cffffaa00FOCUS BUT UNLIT|r" or "")))
            end
            lastLit, lastFocus = litKey, focus
        end

        if elapsed >= dur then
            S.navTrace:SetScript("OnUpdate", nil)
            print(("  |cff00ff00navprobe done|r -- %d frames, %d state changes%s"):format(
                frames, events, events > 120 and " (first 120 shown)" or ""))
            print("  |cff808080Read: one enter + one leave per row = clean, look elsewhere. Repeated flips inside one crossing = focus thrash. TWO LIT = a stale plate. lit=(none) with focus on a row = the handler did not fire.|r")
        end
    end)
end

-- ============================================================
-- /df debug gapcheck -- measure the vertical rhythm, don't eyeball it
--
-- The question this answers: "which rows are too far apart, and which are too
-- close?" It cannot be answered from GUI.RowHeight alone, because those numbers
-- are SLOT heights, not gaps. LayoutChildren stacks rows flush (y = y - height),
-- so the visible gap between two rows is:
--
--     (slot height - content bottom) of the row above
--   + (slot top - content top)      of the row below
--
-- A row whose content is short inside a tall slot gets a big gap and nothing
-- flags it. The slider is the worst case by construction: it shares the 55 slot
-- with the dropdown and edit box, whose openers reach ~40, while a slider only
-- draws to ~32 (label, an 8px track, a 20px value box) -- so it carries ~23px of
-- slack against their ~15.
--
-- Measured, not derived, for a reason: labels WRAP, override markers hang off
-- rows, banners re-measure themselves after construction, and hideOn rows drop
-- out. Only the live rects know the real content extent, which is exactly the
-- lesson from the border bug -- the arithmetic looked right there too.
--
-- Rows are compared only against their SIBLINGS IN THE SAME GROUP. That is where
-- the rhythm actually reads, and it sidesteps having to reconstruct which column
-- a widget landed in.
local function ContentExtent(f)
    local top, bottom
    local function acc(o)
        if not o or not o.IsShown or not o:IsShown() then return end
        -- Skip things that draw NOTHING: an empty label or a fully transparent
        -- placeholder still has a rect, and counting it would inflate the content
        -- and hide the very slack we are looking for.
        --
        -- FontStrings ONLY. An EditBox also answers GetText, and an empty one
        -- would have been skipped here even though its box is plainly drawn --
        -- which would have under-measured every blank input on the page.
        if o.GetObjectType and o:GetObjectType() == "FontString" then
            local s = o:GetText()
            if s == nil or s == "" then return end
        end
        if o.GetAlpha and (o:GetAlpha() or 1) <= 0.01 then return end
        local t, b = o:GetTop(), o:GetBottom()
        if t and b then
            top = (top and math.max(top, t)) or t
            bottom = (bottom and math.min(bottom, b)) or b
        end
    end
    if f.GetRegions then for _, r in ipairs({ f:GetRegions() }) do acc(r) end end
    if f.GetChildren then for _, c in ipairs({ f:GetChildren() }) do acc(c) end end
    return top, bottom
end

-- Every SHOWN SettingsGroup under the page, at any depth (the Aura Designer nests
-- its groups inside cards).
local function CollectGroups(root, out, depth)
    if not root or (depth or 0) > 8 then return out end
    if root.groupChildren and root.IsShown and root:IsShown() then out[#out + 1] = root end
    if root.GetChildren then
        for _, c in ipairs({ root:GetChildren() }) do
            if c.IsShown and c:IsShown() then CollectGroups(c, out, (depth or 0) + 1) end
        end
    end
    return out
end

function GUI.GapCheck(mode)
    if mode == "clear" then
        DandersFramesDebugDB = DandersFramesDebugDB or {}
        DandersFramesDebugDB.gapcheck = nil
        DF:Say("saved capture cleared (/reload to flush).")
        return
    end

    local page, pageName
    for name, p in pairs(GUI.Pages or {}) do
        if p.IsShown and p:IsShown() then page, pageName = p, name break end
    end
    if not page then
        DF:Say("Gap check", "no settings page is open", "WARN")
        return
    end

    local groups = CollectGroups(page.child or page, {}, 0)
    local rows, byKind, pairs_, nRows = {}, {}, {}, 0

    for _, group in ipairs(groups) do
        local prev
        for _, entry in ipairs(group.groupChildren or {}) do
            local w = entry.widget
            if w and w.IsShown and w:IsShown() and entry.height then
                local slotTop = w:GetTop()
                local cTop, cBot = ContentExtent(w)
                if slotTop and cTop and cBot then
                    -- The slot is entry.height from the widget's TOP -- NOT the
                    -- widget's own rect. LayoutChildren only sets TOPLEFT (and
                    -- width), so a container constructed at 50 sitting in a 55
                    -- slot would under-report by 5 if we used GetBottom().
                    local slotBot = slotTop - entry.height
                    local kind = w.rowKind or (w.LayoutChildren and "group")
                        or (w.GetObjectType and w:GetObjectType()) or "?"
                    local r = {
                        kind    = kind,
                        label   = (w.GetText and w:GetText()) or (w.Text and w.Text.GetText and w.Text:GetText()) or kind,
                        slot    = entry.height,
                        content = cTop - cBot,
                        padTop  = slotTop - cTop,
                        padBot  = cBot - slotBot,
                        -- Absolute edges, because the gap has to be measured from
                        -- where the rows LANDED, not from entry.height. The layout
                        -- can shorten a row after the fact (the compact-run
                        -- tightening does exactly that), and slot arithmetic
                        -- cannot see it -- the first version of this reported the
                        -- untightened number and made the feature look inert.
                        cTop    = cTop,
                        cBot    = cBot,
                        -- The slot's own top, so the height the layout ACTUALLY
                        -- used is derivable offline (prev.slotTop - this.slotTop)
                        -- and can be compared against entry.height.
                        slotTop  = slotTop,
                        tight    = w._rowTightened or false,
                        nextKind = w._rowNextKind,
                    }
                    nRows = nRows + 1
                    rows[#rows + 1] = r

                    local k = byKind[kind]
                    if not k then k = { n = 0, slot = 0, content = 0, padTop = 0, padBot = 0 } byKind[kind] = k end
                    k.n, k.slot, k.content = k.n + 1, k.slot + r.slot, k.content + r.content
                    k.padTop, k.padBot = k.padTop + r.padTop, k.padBot + r.padBot

                    -- The gap the eye actually sees: the distance between where
                    -- the previous row's content ENDED and this one's STARTS,
                    -- straight off the resolved rects.
                    if prev then
                        local gap = prev.cBot - r.cTop
                        local key = ("%s -> %s"):format(prev.kind, kind)
                        local p = pairs_[key]
                        if not p then p = { n = 0, sum = 0, min = gap, max = gap } pairs_[key] = p end
                        p.n, p.sum = p.n + 1, p.sum + gap
                        p.min, p.max = math.min(p.min, gap), math.max(p.max, gap)
                    end
                    prev = r
                end
            end
        end
    end

    if nRows == 0 then
        local o = DF:Out("Gap Check", "page " .. tostring(pageName))
        o:Line("No measurable rows — is everything collapsed?", "WARN")
        o:Siblings("gapcheck")
        return
    end

    local o = DF:Out("Gap Check", "page " .. tostring(pageName))
    o:Section("Measured", "UI units")
    o:Field("groups", #groups, "NEUTRAL")
    o:Field("rows", nRows, "NEUTRAL")

    o:Section("Per kind")
    o:Line("slot is what RowHeight hands out; content is what it actually draws.", "NEUTRAL")
    local kinds = {}
    for kind in pairs(byKind) do kinds[#kinds + 1] = kind end
    table.sort(kinds, function(a, b) return (byKind[a].padBot / byKind[a].n) > (byKind[b].padBot / byKind[b].n) end)
    for _, kind in ipairs(kinds) do
        local k = byKind[kind]
        print(("    %-12s n=%-3d slot %5.1f  content %5.1f  padTop %4.1f  |cffffcc00padBottom %4.1f|r")
            :format(kind, k.n, k.slot / k.n, k.content / k.n, k.padTop / k.n, k.padBot / k.n))
    end

    -- Did the compact-run tightening actually fire? The gap alone cannot say --
    -- it only shows the result -- and reading the source said it should while the
    -- measurement said it had not. So count the decision directly, and when a run
    -- did NOT close up, name the kind that broke it.
    local tightened, compactRows, breakers = 0, 0, {}
    for _, r in ipairs(rows) do
        if GUI.RowCompact[r.kind] then
            compactRows = compactRows + 1
            if r.tight then
                tightened = tightened + 1
            elseif r.nextKind then
                breakers[r.nextKind] = (breakers[r.nextKind] or 0) + 1
            end
        end
    end
    if compactRows > 0 then
        local why = {}
        for k, n in pairs(breakers) do why[#why + 1] = ("%s x%d"):format(k, n) end
        table.sort(why)
        print(("  compact-run tightening: |cffffcc00%d/%d|r compact rows closed up%s")
            :format(tightened, compactRows,
                #why > 0 and ("  |cff808080(run broken by: %s)|r"):format(table.concat(why, ", ")) or ""))
    end

    print("  gaps between stacked rows (padBottom above + padTop below) -- widest first:")
    local keys = {}
    for key in pairs(pairs_) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return (pairs_[a].sum / pairs_[a].n) > (pairs_[b].sum / pairs_[b].n) end)
    for _, key in ipairs(keys) do
        local p = pairs_[key]
        local avg = p.sum / p.n
        -- A pair whose min and max differ is NOT a spacing constant -- something
        -- (a wrapped label, a hand-rolled AddSpace) is varying it, and averaging
        -- would hide exactly that.
        local spread = (p.max - p.min > 0.5)
            and ("  |cffff6060varies %.1f..%.1f|r"):format(p.min, p.max) or ""
        print(("    %6.1f  %-26s x%d%s"):format(avg, key, p.n, spread))
    end

    if mode == "all" then
        print("  every row, in layout order:")
        for _, r in ipairs(rows) do
            print(("    %-12s %-22s slot %5.1f  content %5.1f  padTop %4.1f  padBottom %4.1f")
                :format(r.kind, tostring(r.label):sub(1, 22), r.slot, r.content, r.padTop, r.padBot))
        end
    end

    -- Persist the RAW rows to SavedVariables. Reading a hundred rows out of the
    -- chat frame is not practical, and transcribing them by hand would introduce
    -- exactly the kind of error this probe exists to avoid.
    --
    -- Keyed BY PAGE so visiting several pages accumulates one dataset instead of
    -- each run overwriting the last -- walk the pages you care about, then
    -- /reload ONCE. SavedVariables are only flushed on logout or reload, so a run
    -- that is never followed by one is never written.
    --
    -- Its own saved variable, not a corner of DandersFramesDB_v2: diagnostics
    -- must not sit inside the profile DB, where they would ride along with every
    -- export and show up in the export audit.
    DandersFramesDebugDB = DandersFramesDebugDB or {}
    DandersFramesDebugDB.gapcheck = DandersFramesDebugDB.gapcheck or {}
    -- Drop everything from a PREVIOUS session first. Accumulating by page is what
    -- makes a multi-page capture possible, but it also means a page you did not
    -- revisit after a code change keeps its stale rows -- and mixing two builds
    -- invents variance that is not in either of them. (It already cost one wrong
    -- diagnosis: three stale pages made the row heights look like they had not
    -- applied at all.) One /reload = one dataset.
    if DandersFramesDebugDB.gapSession ~= GAP_SESSION then
        wipe(DandersFramesDebugDB.gapcheck)
        DandersFramesDebugDB.gapSession = GAP_SESSION
    end
    local dump = { when = date("%Y-%m-%d %H:%M:%S"), rows = {} }
    if page.GetEffectiveScale then dump.scale = page:GetEffectiveScale() end
    for i, r in ipairs(rows) do
        dump.rows[i] = {
            kind = r.kind, label = tostring(r.label):sub(1, 40),
            slot = r.slot, content = r.content,
            padTop = r.padTop, padBot = r.padBot,
            cTop = r.cTop, cBot = r.cBot,   -- so gaps can be re-derived offline
            slotTop = r.slotTop, tight = r.tight, nextKind = r.nextKind,
        }
    end
    DandersFramesDebugDB.gapcheck[tostring(pageName)] = dump

    local nPages = 0
    for _ in pairs(DandersFramesDebugDB.gapcheck) do nPages = nPages + 1 end
    print(("  |cff00ff00saved|r %d rows to DandersFramesDebugDB.gapcheck[\"%s\"] -- %d page(s) captured. |cffffcc00Visit the pages you care about, then /reload to flush.|r")
        :format(#rows, tostring(pageName), nPages))
    print("  |cff808080Read: padBottom is the slack under a row -- the knob is GUI.RowHeight[kind], and slot - content IS that slack. A kind sorting to the top of the first list is over-spaced; one near zero is cramped. In the second list, 'varies' means the gap is not coming from RowHeight alone. Add 'all' for every row, 'clear' to wipe the saved capture.|r")
end
-- (Removed) GUI.GapCheckAll — a no-arg alias for GapCheck("all"), superseded once the
-- dispatcher started forwarding the mode argument. Zero callers.

-- Every frame that carries a 1px backdrop edge, so the sweep below can find them
-- without any page needing to know what it contains. Weak keys: a retired page's
-- widgets are reparented to the trash frame rather than destroyed, and this must
-- not be what keeps them reachable.

-- Re-derive the BORDER THICKNESS of everything currently on screen. Since the
-- geometry correction was removed this no longer moves or resizes anything, so
-- the only thing it can change is how many device pixels an edge is drawn at --
-- which only matters when the SCALE changes. That is why its callers are the
-- scale slider and the window drag/resize handlers, not anything per-frame.
--
-- IsVisible (not IsShown) keeps it cheap: a widget on a page that is not open
-- has a hidden ancestor and is skipped, so the work stays proportional to what
-- is displayed rather than to everything the registry has accumulated. Safe to
-- call repeatedly -- it writes only when the computed edge width actually
-- differs, so a second call in the same state does nothing at all.

-- ============================================================
-- PIXEL BORDER -- how every outlined GUI surface draws its edge.
--
-- Four textures we own, instead of a backdrop's edgeFile, because a backdrop
-- edge is drawn one UI unit wide and we cannot control how that lands on the
-- physical pixel grid. At the scales people play at, one unit is about one
-- device pixel, and a one-device-pixel line has exactly two states: [1.0, 0]
-- when it lands on the grid and [0.5, 0.5] when it does not. Identical ink,
-- completely different appearance -- so an edge that crosses the grid while the
-- page scrolls appears to flicker, and at the low alphas this GUI uses, both
-- halves of the split can fall under the visibility floor and the border simply
-- is not there.
--
-- The long way round to this was trying to place that 1px line perfectly. It
-- cannot be done. Lua-side snapping runs at discrete moments -- build,
-- scroll-settle, show -- but the line crosses the grid on EVERY frame of a
-- scroll: correcting at moment N does nothing for the next thirty frames, and
-- correcting mid-motion adds a visible jump on top of the softness. Handing it
-- to the renderer (SetSnapToPixelGrid) is worse still: it rounds the two edges
-- of a thin texture independently, so a 1px line can round to zero height and
-- vanish outright.
--
-- The answer is to stop placing a thin line accurately and draw one that does
-- not care where it lands. See PX_BORDER_THICKNESS below.
local pixelBordered = setmetatable({}, { __mode = "k" })
local PX_SIDES = { "top", "bottom", "left", "right" }

-- THE dial. Border thickness in DEVICE PIXELS, before any per-surface weight.
--
-- The floor is what matters, not the exact value: anything above 1 always covers
-- at least one FULL pixel row plus a partial, so the line can never vanish and
-- never changes its total ink as the content moves. Only 1.0 has the two-state
-- failure ([1.0, 0] when it lands on the grid, [0.5, 0.5] when it does not --
-- identical ink, completely different appearance), which is the flicker that
-- started this.
--
-- Back to 2, and the alpha carries the weight instead. THICKNESS and WEIGHT are
-- separate dials and conflating them was the mistake:
--
--   * thickness decides how UNIFORM the line looks. At 1.5 the rows come out
--     [0.25, 1.0, 0.25] or [0.5, 1.0] depending on where the box lands, so
--     neighbouring boxes render visibly different widths -- Krathe's "one
--     thinner, one thicker". The bigger the base, the smaller that proportion,
--     so 2 is noticeably more even than 1.5.
--   * alpha decides how HEAVY it looks, and does not vary with position at all.
--
-- So: hold thickness at the value that renders evenly, and take the weight out
-- of the alpha. 2px at 0.7 alpha is about the same total ink as 1.5px at full,
-- but without the width wobble.
--
-- The floor still matters if this is ever tuned down: anything above 1 always
-- covers a full row plus a partial, so it cannot vanish. Only 1.0 has the
-- two-state failure -- [1.0, 0] on the grid, [0.5, 0.5] off it, identical ink
-- and completely different appearance -- which was the original flicker.
local PX_BORDER_THICKNESS = 2

-- Applied to every pixel border's alpha. The authored colours were all chosen
-- for a 1px hairline; drawing them at 2px would read heavier than intended, and
-- this puts that correction in ONE place rather than re-tuning six call sites
-- (and whatever opts in later) by hand.
local PX_BORDER_ALPHA = 0.7

-- Thickness and anchors, re-derived whenever the scale changes.
-- frame._pxWeight is the caller's edgeSize (1 = the standard hairline), so a
-- surface that asked for a heavier outline keeps its relative weight.
local function LayoutPixelBorder(frame)
    local b = frame._pxBorder
    if not b then return end
    local ppu = PixelsPerUnit(frame)
    if not ppu then return end
    -- TWO device pixels, not one, and this is the whole finding.
    --
    -- A 1px line cannot be drawn reliably at a fractional offset. With vertex
    -- snapping ON, the top and bottom of a 1px-tall texture can round to the SAME
    -- pixel row -- height zero, line GONE. That is what the red diagnostic showed:
    -- verticals solid (X is stable), horizontals absent at certain scroll
    -- positions (Y carries the scroll's fractional phase). The old backdrop edge
    -- did it too, so this is not specific to either mechanism.
    --
    -- With snapping OFF at 2px the rows come out [partial, full, partial] --
    -- roughly 0.5 / 1.0 / 0.5 -- for ANY offset. The total ink is constant and
    -- there is always at least one fully-lit row, so the line can neither vanish
    -- nor visibly change weight as the page scrolls. A 1px line has only the two
    -- states [1.0, 0] and [0.5, 0.5]: same ink, completely different appearance,
    -- which IS the flicker.
    --
    -- So: stop trying to place a 1px line perfectly, and draw one that does not
    -- care where it lands.
    local devicePx = PX_BORDER_THICKNESS * (frame._pxWeight or 1)
    local px = devicePx / ppu
    frame._pxDevicePx = devicePx   -- what /df debug pixelcheck reports for this surface
    frame._pxPpu = ppu             -- the scale this thickness was derived at

    b.top:ClearAllPoints()
    b.top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    b.top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    b.top:SetHeight(px)

    b.bottom:ClearAllPoints()
    b.bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    b.bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    b.bottom:SetHeight(px)

    b.left:ClearAllPoints()
    b.left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    b.left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    b.left:SetWidth(px)

    b.right:ClearAllPoints()
    b.right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    b.right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    b.right:SetWidth(px)
end

-- THE SHIM, and the reason buttons could not adopt this until now.
--
-- A pixel border has no backdrop edgeFile, so SetBackdropBorderColor -- which is
-- how ~150 call sites across the addon drive hover, active and disabled states
-- -- would silently do nothing. Converting those by hand meant finding all of
-- them, and missing one meant a button whose hover just stops working, with
-- nothing to see in a log.
--
-- So the frame gets its own method that shadows the mixin's. Every existing
-- caller keeps working unchanged, and there is no list to be exhaustive about.
-- Assigning onto the frame table is enough: SetBackdropBorderColor is not a
-- native widget method, it arrives via BackdropTemplateMixin, so it is already
-- a plain table entry and ours simply takes its place.
local function SetPixelBorderColor(self, r, g, b, a)
    local bd = self._pxBorder
    if not bd then return end
    a = a or 1
    -- Mutated, not replaced. This is the hover path for every button, dropdown
    -- and swatch in the GUI -- OnEnter and OnLeave both land here -- so a fresh
    -- table per call would be pure garbage.
    local c = self._pxColor
    if c then c[1], c[2], c[3], c[4] = r, g, b, a
    else      self._pxColor = { r, g, b, a } end
    -- Alpha scaled once, here, so the authored colours stay the values a reader
    -- would expect to see (8%, 50%, 80%) rather than pre-compensated numbers.
    local drawn = a * PX_BORDER_ALPHA
    for _, side in ipairs(PX_SIDES) do
        bd[side]:SetColorTexture(r, g, b, drawn)
    end
end

-- Returns the AUTHORED colour, not the drawn one. PX_BORDER_ALPHA is a
-- rendering correction, so a caller that reads a colour back and writes it again
-- must not end up with it applied twice.
local function GetPixelBorderColor(self)
    local c = self._pxColor
    if not c then return end
    return c[1], c[2], c[3], c[4]
end

-- Re-derive on show, so a surface built at one UI scale and opened after a scale
-- change comes up at the right thickness. Self-registering on purpose: this
-- used to be an explicit call that six floating windows each had to remember to
-- make, and a bordered frame maintaining its own border cannot be forgotten.
--
-- Guarded on the scale it was last laid out at, because this fires for every
-- widget on every page open. In the ordinary case -- nothing has changed since
-- the widget was built -- it costs one float compare and returns.
local function RelayoutPixelBorderOnShow(self)
    if PixelsPerUnit(self) ~= self._pxPpu then LayoutPixelBorder(self) end
end

-- color = {r, g, b, a}; weight mirrors backdrop edgeSize (1 = standard hairline)
function GUI:ApplyPixelBorder(frame, color, weight)
    frame._pxWeight = weight or frame._pxWeight or 1
    local b = frame._pxBorder
    if not b then
        b = {}
        for _, side in ipairs(PX_SIDES) do
            -- ARTWORK at the top sublevel, not BORDER. The colour picker is
            -- what forces it up: its hue square lays a full-size ARTWORK
            -- gradient over the frame, which would cover a BORDER-layer edge
            -- completely -- and that is a trap, because the border would
            -- disappear for a reason nothing about the border explains.
            --
            -- Not OVERLAY, though. Every label, icon, check mark, grip and
            -- slider thumb in this GUI is OVERLAY, and those belong above the
            -- edge they sit inside. Sublevel 7 of ARTWORK clears the interior
            -- fills and gradients and nothing else.
            local tex = frame:CreateTexture(nil, "ARTWORK", nil, 7)
            -- Snapping OFF, deliberately, and this is a reversal of what this
            -- started out as. Vertex snapping is what COLLAPSES a thin line:
            -- rounding a 2px texture's edges independently gives a height of 1,
            -- 2 or 3 px depending on where it lands, so the border would
            -- visibly change weight as you scroll. Left un-snapped it is always
            -- exactly 2px of ink, wherever it falls -- constant, which is what
            -- the eye actually wants. Crispness was never the goal; STABILITY
            -- was.
            if tex.SetSnapToPixelGrid then tex:SetSnapToPixelGrid(false) end
            -- No half-texel offset, so the 2px spans the rows we asked for.
            if tex.SetTexelSnappingBias then tex:SetTexelSnappingBias(0) end
            b[side] = tex
        end
        frame._pxBorder = b
        pixelBordered[frame] = true
        if frame.HookScript then
            frame:HookScript("OnShow", RelayoutPixelBorderOnShow)
        end
    end
    -- Outside the create block on purpose: the textures are kept when a surface
    -- is re-issued, so keying the shim off their creation would leave a
    -- re-adopted frame with the real methods still in place and its recolours
    -- going nowhere. Assigning every time is idempotent and cannot get this
    -- wrong.
    frame.SetPixelBorderColor    = SetPixelBorderColor
    frame.SetBackdropBorderColor = SetPixelBorderColor
    frame.GetBackdropBorderColor = GetPixelBorderColor
    local c = color or { 1, 1, 1, 0.08 }
    SetPixelBorderColor(frame, c[1], c[2], c[3], c[4] or 1)
    -- Re-shown because a surface can be re-issued as fill-only and back again
    -- (FlashWidget does this on every pulse).
    for _, side in ipairs(PX_SIDES) do b[side]:Show() end
    LayoutPixelBorder(frame)
    return frame
end

-- Hand the frame its own methods back, and take the textures down. Needed by the
-- one path that leaves the pixel border behind: a surface re-issued with
-- opts.backdropEdge after it had one. Nothing does that today, but if the shim
-- were left installed the backdrop recolour that follows would go nowhere at
-- all -- a hover that silently stops working, which is precisely the failure
-- this system exists to make impossible.
local function RevertPixelBorder(frame)
    if not frame or not frame._pxBorder then return end
    GUI:HidePixelBorder(frame)
    frame.SetPixelBorderColor    = nil
    frame.SetBackdropBorderColor = BackdropTemplateMixin.SetBackdropBorderColor
    frame.GetBackdropBorderColor = BackdropTemplateMixin.GetBackdropBorderColor
end

-- Take the border down without discarding it. The textures are ours, so unlike a
-- backdrop edge nothing else will remove them when the surface is re-issued
-- without an outline.
function GUI:HidePixelBorder(frame)
    local b = frame and frame._pxBorder
    if not b then return end
    for _, side in ipairs(PX_SIDES) do b[side]:Hide() end
end


-- THE element backdrop. Every bordered/filled GUI surface goes through here, so
-- a change to the look lands everywhere at once. Three shapes, one code path:
--
--   (default)          fill + 1px outline -- dropdowns, edit boxes, buttons
--   opts.fill=false    outline only -- for a surface whose interior is drawn by
--                      something else (the colour picker's hue/alpha gradients
--                      and checkerboards), where a fill would paint over it
--   opts.outline=false fill only -- flat chips, segment buttons, label plates
--
-- opts.bgColor / opts.borderColor take {r,g,b[,a]} or {[1],[2],[3][,4]} and
-- override the C_ELEMENT / C_BORDER defaults. opts.edgeSize thickens the outline
-- (the popup and wizard chrome use 2). opts.inset (a
-- single number, applied to all four sides) pulls the fill in from the edge so it
-- does not underlap a translucent border -- default 0, i.e. the fill runs to the
-- frame edge. opts.backdropEdge draws the outline the old way, as a backdrop
-- edgeFile; see below for why nothing should want that.
local function CreateElementBackdrop(frame, opts)
    opts = opts or {}
    local fill, outline = opts.fill ~= false, opts.outline ~= false
    -- The outline is drawn as our own textures, not a backdrop edgeFile. See
    -- ApplyPixelBorder -- a 1px backdrop edge cannot be drawn reliably at a
    -- fractional offset, which is the whole missing-border story.
    --
    -- This was an opt-in while the hover states were still a problem: a pixel
    -- border is not repainted by SetBackdropBorderColor, so converting buttons
    -- blind would have silently killed every hover in the GUI. The shim in
    -- ApplyPixelBorder settles that -- the frame gets its own
    -- SetBackdropBorderColor -- so it is now the default for everything that
    -- comes through here, and opts.backdropEdge is the escape hatch for a
    -- surface that genuinely needs the old edgeFile.
    local usePixel = outline and not opts.backdropEdge
    if not frame.SetBackdrop then Mixin(frame, BackdropTemplateMixin) end
    local inset = opts.inset
    frame:SetBackdrop({
        bgFile   = fill and "Interface\\Buttons\\WHITE8x8" or nil,
        edgeFile = (outline and not usePixel) and "Interface\\Buttons\\WHITE8x8" or nil,
        edgeSize = (outline and not usePixel) and (opts.edgeSize or 1) or nil,
        insets   = inset and { left = inset, right = inset,
                               top = inset, bottom = inset } or nil,
    })
    if fill then
        local c = opts.bgColor
        if c then frame:SetBackdropColor(c.r or c[1], c.g or c[2], c.b or c[3], c.a or c[4] or 1)
        else      frame:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, C_ELEMENT.a) end
    end
    if outline then
        local c = opts.borderColor
        if usePixel then
            GUI:ApplyPixelBorder(frame,
                c and { c.r or c[1], c.g or c[2], c.b or c[3], c.a or c[4] or 1 }
                  or { C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5 },
                opts.edgeSize)
        else
            RevertPixelBorder(frame)
            if c then
                frame:SetBackdropBorderColor(c.r or c[1], c.g or c[2], c.b or c[3], c.a or c[4] or 1)
            else
                frame:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
            end
        end
    else
        -- A backdrop edge disappears on its own when the backdrop is re-issued
        -- without one; our textures do not, so an outlined surface re-issued as
        -- fill-only has to be told. FlashWidget does exactly this: it re-runs
        -- this factory on every pulse, with outline true or false depending on
        -- how the caller wants that pulse to read.
        GUI:HidePixelBorder(frame)
    end
    return frame
end

-- The window chrome: the settings window itself, the changelog overlay and the
-- dropdown menu panel. Distinct from the public GUI:CreatePanelBackdrop further
-- down (dialogs and floating panels, colour-configurable) -- this one is always
-- the dark background behind a hard black edge.
--
-- Routed through the factory rather than issuing its own backdrop, which is what
-- it used to do. It was the last thing in the GUI still drawing a border as an
-- edgeFile, and a black 1px line is the case where that reads least badly -- it
-- has enough contrast that a split across two device rows softens it instead of
-- losing it. Still worth converting: softening on every scroll is what the whole
-- pixel border exists to stop, and while this was the last holdout the entire
-- snap-registry existed to serve three call sites.
local function CreatePanelBackdrop(frame)
    return CreateElementBackdrop(frame, {
        bgColor     = C_BACKGROUND,
        borderColor = { 0, 0, 0, 1 },
    })
end
-- ☠ These two MUST be published here, on the private table, not aliased from
-- GUI.CreateElementBackdrop / GUI.CreatePanelBackdrop. Those public names are
-- METHOD WRAPPERS (`function GUI:X(...) return X(...) end`) declared later in
-- GUI/Widgets.lua -- a different object that happens to share the name. A
-- sibling part aliasing the wrapper gets nil at load time, and if it did not,
-- the wrapper would end up calling itself.
P.CreateElementBackdrop = CreateElementBackdrop
P.CreatePanelBackdrop   = CreatePanelBackdrop

-- Style a ScrollFrameTemplate scrollbar to use the pill-shaped thumb
-- All scroll frames must use ScrollFrameTemplate (not UIPanelScrollFrameTemplate)
--
-- This used to also quantise the scroll offset to whole device pixels, on the
-- reasoning that Blizzard's scrollbar drives the offset as a fraction of the
-- range and so parks the content on an arbitrary sub-pixel row. That was true,
-- and it did not help: a thin border is soft at SOME offsets no matter which
-- offsets you allow, and quantising only changed which ones. The border being
-- two device pixels wide is what made the question stop mattering -- it draws
-- the same amount of ink wherever it lands. Do not add it back.
local function StyleScrollBar(scrollFrame)
    local sb = scrollFrame.ScrollBar
    if not sb then return end

    -- Hide track background and track end caps
    if sb.Background then sb.Background:Hide() end
    if sb.Track then
        if sb.Track.Begin then sb.Track.Begin:Hide() end
        if sb.Track.End then sb.Track.End:Hide() end
        if sb.Track.Middle then sb.Track.Middle:Hide() end
    end

    -- Style the pill-shaped thumb — hide default textures, overlay with themed color
    if sb.Thumb then
        if sb.Thumb.Begin then sb.Thumb.Begin:Hide() end
        if sb.Thumb.End then sb.Thumb.End:Hide() end
        if sb.Thumb.Middle then sb.Thumb.Middle:Hide() end
        if not sb.Thumb.customBg then
            local thumb = sb.Thumb:CreateTexture(nil, "ARTWORK")
            thumb:SetAllPoints()
            thumb:SetColorTexture(0.4, 0.4, 0.4, 0.8)
            sb.Thumb.customBg = thumb
        end
    end

    -- Hide navigation buttons
    if sb.Back then sb.Back:Hide() sb.Back:SetSize(1, 1) end
    if sb.Forward then sb.Forward:Hide() sb.Forward:SetSize(1, 1) end

    -- Slim width
    sb:SetWidth(10)
end
GUI.StyleScrollBar = StyleScrollBar

-- =========================================================================
-- WIDGET FACTORY
-- =========================================================================



-- =========================================================================
-- SETTINGS GROUP - Visible container that groups related settings together
-- Ensures settings never get split across columns
-- =========================================================================

-- ============================================================
-- SHARED WITH THE SETTINGS-PANEL WIDGETS
-- ============================================================
-- DandersFrames_Options/GUI/SettingsWidgets.lua is a separate addon and cannot
-- see this file's locals. Neither is reassigned after this point, so aliasing
-- them there is safe.
P.LayoutPixelBorder = LayoutPixelBorder
P.pixelBordered = pixelBordered
