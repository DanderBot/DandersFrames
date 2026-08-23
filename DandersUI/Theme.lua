local addonName, NS = ...
local UI = NS.__DandersUI
if not UI then return end

local S = UI._state
local P = UI._priv

local math, ipairs, pairs, setmetatable = math, ipairs, pairs, setmetatable
local CreateFrame, UIParent, Mixin = CreateFrame, UIParent, Mixin
local GetCursorPosition, GetPhysicalScreenSize = GetCursorPosition, GetPhysicalScreenSize
local BackdropTemplateMixin = BackdropTemplateMixin

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
-- Amber: "configured, but this will not render" notes in the Aura Designer — a state the
-- user can fix, so it reads softer than the red above, which marks a behaviour change.
-- ⚠ ADDED because the raw triple was hardcoded at SEVEN sites across three files, four of
-- them added in one round — and the first even carried the comment "the editor's warning
-- amber", naming a shared colour that did not exist. Theme against this, never the numbers.
local C_NOTICE     = {r = 0.91, g = 0.66, b = 0.25, a = 1}
-- Green: a mover that OTHER movers are anchored to (an anchor root). Sits
-- between the accent (free) and the anchored purple so the three roles read
-- apart at a glance on the unlock overlay.
local C_ANCHOR_ROOT = {r = 0.35, g = 0.78, b = 0.45, a = 1}
-- Purple: a mover that is anchored to ANOTHER mover (a child). The third pole of
-- the same three-role set as C_ACCENT (free) and C_ANCHOR_ROOT (root). Lifted
-- verbatim out of DandersMover/Proxy.lua, which had been carrying it as a
-- private literal -- the same drift C_NOTICE above was added to stop.
local C_ANCHORED   = {r = 0.55, g = 0.40, b = 0.85, a = 1}
-- Red: a surface that is BLOCKED -- today the mover's snap zones that already
-- have something in them. Deliberately not C_WARNING (a softer red for caution
-- text) and not the button `tone = "danger"` reds in Widgets.lua, which are
-- lightened for label text on a dark button and would wash out as a fill.
local C_DANGER     = {r = 0.8,  g = 0.2,  b = 0.2,  a = 1}

-- Exported palette: other files should theme against these shared tables instead
-- of re-declaring private copies or hardcoding the raw numbers. These are the
-- SAME table references as the locals above. For the mode-aware accent, use
-- host:GetAccent() (Core.lua), or UI.Colors.raid for a pinned raid surface.
UI.Colors = {
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
    notice     = C_NOTICE,   -- amber for "configured but will not render" notes
    anchorRoot = C_ANCHOR_ROOT, -- green for a mover other movers are anchored to
    anchored   = C_ANCHORED,    -- purple for a mover anchored to another mover
    danger     = C_DANGER,      -- red for a blocked/occupied surface
}

-- Dialog chrome. The popup is a standalone dialog rather than a settings page and
-- wanted the same handful of extras on top of the shared neutrals — so it had
-- grown a private copy of the WHOLE palette (11 hardcoded colours), matching
-- today only by luck.
-- One owner: the neutrals below are the SAME tables as GUI.Colors, so they
-- theme-track in lockstep, and only what genuinely differs is declared here.
-- Read-only by convention — these tables are shared, so nothing may mutate them.
UI.DialogColors = {
    -- Dialogs use the SAME ground as the pages. This was a bespoke 0.97 in three
    -- separate copies, a shade denser than the pages' 0.95 for no reason anyone
    -- could point at; consolidating the copies made the difference visible and
    -- it went. Chrome now reads identically whether it's a page or a dialog.
    background = C_BACKGROUND,
    panel      = C_PANEL,
    element    = C_ELEMENT,
    border     = C_BORDER,
    accent     = C_ACCENT,     -- fallback only; live dialogs read the host accent
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
-- gap. That is how the GUI ended up with a 4x spread. A gap probe measured it
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
UI.RowGap = 14

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
UI.RowGapTight = 8
-- ☠ NO `toggle` ENTRY. One was here and could never match: only six values are ever
-- written to rowKind (checkbox, colorpicker, dropdown, editbox, header, slider), so
-- the lookups in this file and in each consumer's section layout had nothing to find
-- in GUI.RowHeight was removed for the same reason -- see the note there -- and this
-- one was missed, which is exactly how a pair like that drifts apart.
UI.RowCompact = {
    checkbox    = true,
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
UI.Space = {
    section = 10,   -- between logical sections in a page column
    block   = 20,   -- before a distinct trailing block (the See-Also links)
    footer  = 12,   -- below the See-Also bar when it is parked at the viewport bottom
}

UI.RowHeight = {
    checkbox    = 35,   -- 2.9 top inset + 18.2 content + RowGap
    slider      = 46,   -- 32.0 content + RowGap  (was 55: a slot sized for the dropdown)
    dropdown    = 54,   -- 39.8 content + RowGap
    colorpicker = 38,   -- 23.9 content + RowGap
    editbox     = 53,   -- 39.0 content + RowGap (box at -15, h24)
    -- Label at 0, grid at -16, two 18px cells with a 2px gutter = 16 + 38 content.
    anchorgrid  = 16 + 38 + UI.RowGap,
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
    labelPad    = 5 + UI.RowGap,
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
    sectionHeader = 11.1 + 11.9 + UI.RowGap,   -- top inset + text + the gap
    -- A group box's title line (CreateGroupBox): the same 11.9 of DFFontNormal
    -- text as a section header plus the gap to the first row, but WITHOUT the
    -- header's 11.1 top inset -- the box's own padding already provides the
    -- air above it.
    groupTitle  = 11.9 + UI.RowGap,
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
UI.ResolveRowHeight = ResolveRowHeight

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
-- PARENTED AND ANCHORED to UIParent (a drag ghost, for instance) really does
-- have UIParent's effective scale, so there UIParent is the correct divisor.
-- Pass the frame whose coordinates you are comparing against and it is right
-- either way.
function UI:CursorPos(frame)
    local scale = frame and frame.GetEffectiveScale and frame:GetEffectiveScale()
    if not scale or scale == 0 then scale = UIParent:GetEffectiveScale() end
    if not scale or scale == 0 then scale = 1 end
    local x, y = GetCursorPosition()
    return x / scale, y / scale
end

-- Physical pixels per UI unit, measured from the frame's OWN effective scale.
-- The GUI window carries a user scale (windowState.scale) on top of UIParent's and is
-- freely resizable, so this is almost never 1 and cannot be read from the
-- a consumer own UIParent-relative pixel scale.
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
UI.SnapLen = SnapLen

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
UI.SnapLenUp = SnapLenUp

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
UI.SnapHeightEven = SnapHeightEven

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
    frame._pxDevicePx = devicePx   -- what a consumer pixel probe reports for this surface
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
-- how ~150 call sites across the consumers drive hover, active and disabled states
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
function UI:ApplyPixelBorder(frame, color, weight)
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
    UI:HidePixelBorder(frame)
    frame.SetPixelBorderColor    = nil
    frame.SetBackdropBorderColor = BackdropTemplateMixin.SetBackdropBorderColor
    frame.GetBackdropBorderColor = BackdropTemplateMixin.GetBackdropBorderColor
end

-- Take the border down without discarding it. The textures are ours, so unlike a
-- backdrop edge nothing else will remove them when the surface is re-issued
-- without an outline.
function UI:HidePixelBorder(frame)
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
    -- ⚠ NOTHING PASSES backdropEdge TODAY, in any consumer. So usePixel is `outline`
    -- in practice, the backdrop-edge arm below is unreachable, and RevertPixelBorder --
    -- which only that arm can reach -- cannot run either. Left wired rather than cut:
    -- it is the documented escape hatch for a surface that needs the old edgeFile, and
    -- its own note explains what breaks if the shim is left installed. Know that it is
    -- untested by use before relying on it.
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
            UI:ApplyPixelBorder(frame,
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
        UI:HidePixelBorder(frame)
    end
    return frame
end

-- The window chrome: the settings window itself, the changelog overlay and the
-- dropdown menu panel. Distinct from the public UI:CreatePanelBackdrop in Widgets.lua (further
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
-- UI.CreateElementBackdrop / UI.CreatePanelBackdrop. Those public names are
-- METHOD WRAPPERS (`function UI:X(...) return X(...) end`) declared later in
-- Widgets.lua -- a different object that happens to share the name. A
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
UI.StyleScrollBar = StyleScrollBar

-- ============================================================
-- SHARED WITH THE SETTINGS-PANEL WIDGETS
-- ============================================================
-- A consumer own files are separate addons and cannot
-- see this file's locals. Neither is reassigned after this point, so aliasing
-- them there is safe.
P.LayoutPixelBorder = LayoutPixelBorder
P.pixelBordered = pixelBordered
