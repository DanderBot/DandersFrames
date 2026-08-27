-- ============================================================
-- POPOUT ROW DEMO -- the permanent workbench for the DandersUI popout look.
--
-- Gate one of the DF popout settings redesign. Open it with /df popoutdemo.
--
-- ☠ ALL POPOUT CHROME POLISH IS ITERATED HERE, never against a real settings
-- page. The rows below sit over a throwaway table of made-up settings, so the
-- beam, the notch, the retarget glide, the edge flip, the height cap, the
-- off-state and the dependent grey can all be pushed around without a single
-- user setting being at risk -- and without dragging a page rebuild into every
-- one-pixel adjustment. When a behaviour looks right HERE, it goes to the
-- pages; not the other way round.
--
-- THE OFF GATE, where to see it: Border Shadow starts toggled OFF, so opening it
-- shows a pane that is already dead -- every control greyed and unclickable while
-- the popout's own header tick, pin and cross stay live. Flip that tick (from the
-- row OR from the header) to watch the whole group grey and un-grey in place.
-- Highlights is the counter-case: Border switched off greys the ROW, but its own
-- toggle is still on, so its popout's controls stay live.
--
-- THE SCALE BUTTON, where to see the other half. The real settings window has a
-- user scale slider and this one had nothing, so every scale bug the popout has
-- ever had was invisible here and had to be found in-game. Cycle the title bar's
-- Scale button with a popout open: the panel should take the same scale, the beam
-- should stay touching the row's plate, and clicking another row should land the
-- panel exactly beside it.
--
-- THE CORNERS BUTTON, the rounded-corner trial. Cycles Square (what we ship) ->
-- R4 -> R6 -> R8, swapping FOUR surfaces at once: the row plates, this window
-- itself, this window's title strip, and -- with a popout open -- the panel's own
-- chrome and ITS title strip. The popout's accent border becomes a rounded ring
-- in the accent colour; both title strips become top-corners-only surfaces so
-- they follow the curve of the panel under them instead of squaring it off.
-- PROTOTYPE: it drives UI:CreateRoundedSurface (DandersUI/Round.lua), which no
-- real settings page touches, and Square restores the shipping look exactly.
-- What it is FOR is judging whether the curve stays crisp at a real UI scale, so
-- cycle the Scale button underneath each radius rather than looking at 100% only.
--
-- ...and rounded mode also takes TWO PIECES OF SQUARE CHROME out of the way,
-- both of them things that read as a second corner beside a rounded one: the
-- popout's source outline (the accent box the shell lays over the active row --
-- see hookPopout) and the title bars' cross, which is nudged inboard of the arc
-- (see insetTitleButton). Both are per-instance and both come straight back on
-- Square.
--
-- Dev-facing on purpose: every string is a plain literal and NOTHING here is
-- localised. Same rule as the rest of /df debug -- these words are for whoever
-- is working on the chrome, not for players.
--
-- ☠ SHADOW HAZARD -- the *Native factory names are used throughout. DF defines
-- POSITIONAL CreateSlider / CreateDropdown / CreateCheckbox / CreateEditBox /
-- CreateButton / CreateLabel on this very host (DandersFrames/GUI/Compat.lua),
-- which shadows the pack's opts-table factories for us. Calling the plain names
-- from here would silently hit the positional shim and mis-read every argument.
-- ============================================================

-- ☠ Companion addon: `...` yields THIS addon's private table, not the parent's.
-- Take the parent's table from the global it publishes (DandersFrames/Core.lua).
local DF = DandersFrames
local GUI = DF.GUI          -- the DandersUI host, created by the resident GUI.lua
local UI = LibStub("DandersUI-1.0")

local CreateFrame, UIParent = CreateFrame, UIParent
local ipairs, pairs, format = ipairs, pairs, string.format
local max, floor = math.max, math.floor

local C = UI.Colors

-- Widened from 420 when the Corners button joined the title bar: four buttons
-- plus the cross need 328px of the bar, and at 420 they ran into the title.
local WIN_W, WIN_H = 480, 500
local TITLE_H      = 26
local PAD          = 12
local FILLER_ROWS  = 20      -- enough below the rows that the list really scrolls
local FILLER_H     = 20

-- ============================================================
-- THE THROWAWAY SETTINGS
-- A plain file-local table standing in for a profile. Nothing reads it but this
-- file, nothing saves it, and it resets on every /reload -- which is exactly
-- what a chrome workbench wants.
-- ============================================================
local demoDB = {
    border = {
        enabled = true, size = 2, alpha = 0.8, texture = "Solid",
    },
    shadow = {
        enabled = false, size = 4, alpha = 0.6, offsetX = 0, offsetY = 0,
        quality = "High", color = "Black", growDirection = "Outward",
        matchBorder = false,
    },
    fading = {
        enabled = true, amount = 55, minAlpha = 20, outOfRangeAlpha = 35,
        updateRate = 0.2, combatOnly = false, fadeNames = true, fadeAuras = false,
        fadeHealthBar = true, fadePowerBar = true, ignoreDead = false,
        mode = "Alpha", curve = "Smooth", rangeCheck = "Spell", customRange = 40,
    },
    highlight = {
        enabled = true, hover = true, target = true, style = "Outline",
    },
}

-- ============================================================
-- STATE
-- ============================================================
local win                       -- the demo window; nil until first toggle
local rows = {}                 -- name -> the PopoutRow frame
local accentMode = "party"

local function accentColor()
    return (accentMode == "raid") and C.raid or C.accent
end

-- Every control inside a popout calls this so the row's summary repaints while
-- you are still dragging the slider that changed it. The row is looked up by
-- name rather than captured, because the panes are built lazily -- the first
-- open happens long after this closure was written.
local function refreshRow(name)
    local r = rows[name]
    if r then r.Refresh() end
end

-- ============================================================
-- PANE BUILDING
-- The pack runs a row's `build` ONCE per (instance, row) and the consumer must
-- SIZE the pane it was handed -- nothing else can measure a column it did not
-- lay out. So: stack, total, set.
-- ============================================================
local function stack(pane, widgets)
    local y = 0
    for _, w in ipairs(widgets) do
        w:ClearAllPoints()
        w:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, -y)
        if w.fixedRowHeight then w:SetWidth(UI.PopoutContentWidth) end
        y = y + (w.preferredHeight or ((w:GetHeight() or 20) + UI.RowGap))
    end
    pane:SetHeight(max(y, 1))
end

local function slider(pane, label, minV, maxV, step, tbl, key, rowName)
    return GUI:CreateSliderNative(pane, {
        label = label, min = minV, max = maxV, step = step,
        get = function() return tbl[key] end,
        set = function(v) tbl[key] = v end,
        -- BOTH, deliberately: onChanged is skipped while the host reports a drag
        -- in progress, and the live summary is the thing this demo exists to
        -- show. lightweight is the per-frame path during that drag.
        onChanged   = function() refreshRow(rowName) end,
        lightweight = function() refreshRow(rowName) end,
    })
end

local function dropdown(pane, label, options, tbl, key, rowName)
    return GUI:CreateDropdownNative(pane, {
        label = label, options = options,
        get = function() return tbl[key] end,
        set = function(v) tbl[key] = v end,
        onChanged = function() refreshRow(rowName) end,
    })
end

local function checkbox(pane, label, tbl, key, rowName)
    return GUI:CreateCheckboxNative(pane, {
        label = label,
        get = function() return tbl[key] end,
        set = function(v) tbl[key] = v end,
        onChanged = function() refreshRow(rowName) end,
    })
end

-- A labelled edit box, wrapped in one container frame. The wrapper is what keeps
-- the declared control count honest: the pack counts a pane's direct CHILD
-- FRAMES, so a bare label + box would count as one control and read as two.
local function editbox(pane, label, tbl, key, rowName)
    local box = CreateFrame("Frame", nil, pane)
    box:SetSize(UI.PopoutContentWidth, UI.RowHeight.editbox)
    box.preferredHeight = UI.RowHeight.editbox
    box.fixedRowHeight = true

    local lbl = GUI:CreateLabelNative(box, { text = label, size = 11, color = C.text })
    lbl:SetPoint("TOPLEFT", 0, 0)

    local eb = GUI:CreateEditBoxNative(box, {
        width = 80, height = 22, numeric = true,
        get = function() return tbl[key] end,
        set = function(v) tbl[key] = tonumber(v) or tbl[key] end,
        onCommit = function() refreshRow(rowName) end,
    })
    eb:SetPoint("TOPLEFT", 0, -16)

    -- The wrapper forwards SetEnabled to what it wraps, the way every kit
    -- container does. The row's off-gate walks the pane's DIRECT children, so a
    -- wrapper that answered nothing would be dimmed as decoration and leave the
    -- live box inside it still typeable in a dead group.
    --
    -- Label and box separately, NOT SetAlpha on the wrapper: the box dims itself
    -- to 0.4 inside SetEnabled, so a 0.4 on the parent as well would land it at
    -- 0.16 and make this one control darker than everything beside it.
    box.SetEnabled = function(_, enabled)
        local c = enabled and C.text or C.textDim
        lbl:SetTextColor(c.r, c.g, c.b)
        eb:SetEnabled(enabled)
    end
    return box
end

-- ============================================================
-- THE FOUR ROWS
-- ============================================================

local TEXTURES = { Solid = "Solid", Blizzard = "Blizzard", Smooth = "Smooth",
                   Flat = "Flat", _order = { "Solid", "Blizzard", "Smooth", "Flat" } }
local QUALITY  = { Low = "Low", Medium = "Medium", High = "High", Ultra = "Ultra",
                   _order = { "Low", "Medium", "High", "Ultra" } }
local SHADOWCOL = { Black = "Black", Class = "Class Colour", Custom = "Custom",
                    _order = { "Black", "Class", "Custom" } }
local GROWDIR  = { Outward = "Outward", Inward = "Inward", Both = "Both",
                   _order = { "Outward", "Inward", "Both" } }
local FADEMODE = { Alpha = "Alpha", Desaturate = "Desaturate", Both = "Both",
                   _order = { "Alpha", "Desaturate", "Both" } }
local CURVE    = { Linear = "Linear", Smooth = "Smooth", Snap = "Snap",
                   _order = { "Linear", "Smooth", "Snap" } }
local RANGEBY  = { Spell = "Spell", Interact = "Interact", Custom = "Custom",
                   _order = { "Spell", "Interact", "Custom" } }
local HLSTYLE  = { Outline = "Outline", Glow = "Glow", Fill = "Fill",
                   _order = { "Outline", "Glow", "Fill" } }

-- 1. BORDER -- the small group. Three controls, a summary carrying units.
local function buildBorder(po, pane)
    local d = demoDB.border
    stack(pane, {
        slider(pane, "Size", 1, 8, 1, d, "size", "border"),
        slider(pane, "Alpha", 0, 1, 0.05, d, "alpha", "border"),
        dropdown(pane, "Texture", TEXTURES, d, "texture", "border"),
    })
end

local function borderSummary(db)
    local d = db.border
    return format("%dpx \194\183 \206\177 %.2f \194\183 %s", d.size, d.alpha, d.texture)
end

-- 2. BORDER SHADOW -- starts toggled OFF, so the off render and its grey are
-- the first thing the window shows. Eight controls, longer words in the summary.
local function buildShadow(po, pane)
    local d = demoDB.shadow
    stack(pane, {
        slider(pane, "Shadow Size", 1, 16, 1, d, "size", "shadow"),
        slider(pane, "Shadow Alpha", 0, 1, 0.05, d, "alpha", "shadow"),
        slider(pane, "Offset X", -20, 20, 1, d, "offsetX", "shadow"),
        slider(pane, "Offset Y", -20, 20, 1, d, "offsetY", "shadow"),
        dropdown(pane, "Render Quality", QUALITY, d, "quality", "shadow"),
        dropdown(pane, "Shadow Colour", SHADOWCOL, d, "color", "shadow"),
        dropdown(pane, "Growth Direction", GROWDIR, d, "growDirection", "shadow"),
        checkbox(pane, "Match Border Colour", d, "matchBorder", "shadow"),
    })
end

local function shadowSummary(db)
    local d = db.shadow
    return format("%dpx \194\183 \206\177 %.2f \194\183 %s quality \194\183 %s",
                  d.size, d.alpha, d.quality, d.growDirection)
end

-- 3. RANGE FADING -- the big one. Fourteen controls, which is well past the
-- popout's 60%-of-screen height cap, so the pack wraps the pane in its own
-- scroll region. Long summary, to prove the row truncates rather than shoves.
local function buildFading(po, pane)
    local d = demoDB.fading
    stack(pane, {
        slider(pane, "Fade Amount", 0, 100, 1, d, "amount", "fading"),
        slider(pane, "Minimum Alpha", 0, 100, 1, d, "minAlpha", "fading"),
        slider(pane, "Out Of Range Alpha", 0, 100, 1, d, "outOfRangeAlpha", "fading"),
        slider(pane, "Update Rate", 0.05, 1, 0.05, d, "updateRate", "fading"),
        dropdown(pane, "Fade Mode", FADEMODE, d, "mode", "fading"),
        dropdown(pane, "Fade Curve", CURVE, d, "curve", "fading"),
        dropdown(pane, "Range Check", RANGEBY, d, "rangeCheck", "fading"),
        editbox(pane, "Custom Range (yards)", d, "customRange", "fading"),
        checkbox(pane, "Combat Only", d, "combatOnly", "fading"),
        checkbox(pane, "Fade Names", d, "fadeNames", "fading"),
        checkbox(pane, "Fade Auras", d, "fadeAuras", "fading"),
        checkbox(pane, "Fade Health Bar", d, "fadeHealthBar", "fading"),
        checkbox(pane, "Fade Power Bar", d, "fadePowerBar", "fading"),
        checkbox(pane, "Ignore Dead Units", d, "ignoreDead", "fading"),
    })
end

local function fadingSummary(db)
    local d = db.fading
    -- floor, not a raw %d: the range comes from a typed edit box and a user who
    -- enters 37.5 must not blow up the summary on a stricter Lua.
    return format("%d%% \194\183 %s \194\183 %s curve \194\183 %d yd range",
                  floor(d.amount), d.combatOnly and "Combat only" or "Always",
                  d.curve, floor(d.customRange or 0))
end

-- 4. HIGHLIGHTS -- the dependent-grey demo. Its own toggle is independent, but
-- the WHOLE row greys whenever Border is switched off, which is the state a
-- feature-gated group is in on a real page.
local function buildHighlights(po, pane)
    local d = demoDB.highlight
    stack(pane, {
        checkbox(pane, "Hover Highlight", d, "hover", "highlights"),
        checkbox(pane, "Target Highlight", d, "target", "highlights"),
        dropdown(pane, "Highlight Style", HLSTYLE, d, "style", "highlights"),
    })
end

local function highlightSummary(db)
    local d = db.highlight
    local out = ""
    local function add(s)
        out = (out == "") and s or (out .. " \194\183 " .. s)
    end
    if d.hover then add("Hover") end
    if d.target then add("Target") end
    add(d.style)
    return out
end

local ROW_DEFS = {
    {
        name = "border", label = "Border", count = 3,
        toggle = { db = demoDB.border, key = "enabled" },
        summary = borderSummary, build = buildBorder,
        -- Border gates Highlights, so its toggle has to repaint that row too:
        -- the grey is only worth demoing if it is live.
        onToggle = function() refreshRow("highlights") end,
    },
    {
        name = "shadow", label = "Border Shadow", count = 8,
        toggle = { db = demoDB.shadow, key = "enabled" },
        summary = shadowSummary, build = buildShadow,
    },
    {
        name = "fading", label = "Range Fading", count = 14,
        toggle = { db = demoDB.fading, key = "enabled" },
        summary = fadingSummary, build = buildFading,
    },
    {
        name = "highlights", label = "Highlights", count = 3,
        toggle = { db = demoDB.highlight, key = "enabled" },
        summary = highlightSummary, build = buildHighlights,
        enabled = function() return demoDB.border.enabled and true or false end,
    },
}

-- ============================================================
-- ACCENT SWITCHER
-- Party purple <-> raid orange, on the ROWS only. NOT GUI:SetAccent -- that is
-- the host accent and would re-theme the real settings panel from a dev tool.
-- row:SetAccent walks the row's bound popouts, so an open (or pinned) panel
-- re-tints in place rather than waiting to be reopened.
-- ============================================================
local function applyAccent(btn)
    local c = accentColor()
    for _, r in pairs(rows) do r:SetAccent(c) end
    if btn then
        btn:SetText((accentMode == "raid") and "Accent: Raid" or "Accent: Party")
    end
end

-- ============================================================
-- SCALE SWITCHER
-- ☠ THE ONE THING THIS WORKBENCH COULD NOT SHOW. The real settings window carries
-- a user scale slider and this one carried nothing, so an unscaled window was the
-- only case the demo ever rendered -- which is exactly the case where a popout at
-- UIParent scale and a window at its own scale happen to agree. Every scale bug
-- the popout has had (the beam's far end landing out in the gutter, and then the
-- panel's controls coming up bigger than the page's) was invisible here for that
-- reason and had to be found in-game.
--
-- Dev-facing, so a button that cycles a handful of values rather than a slider:
-- the point is to be able to LOOK at 80% in one click, next to the accent toggle
-- it is modelled on. Cycling stops at 70% because below that the row list stops
-- being readable and nothing about the chrome is learned from it.
-- ============================================================
local SCALES = { 1.0, 0.9, 0.8, 0.7 }
local scaleIndex = 1

-- The FRAME is passed in rather than read off the file-local `win`: this runs once
-- during buildWindow, before the toggle has assigned it.
local function applyScale(f, btn)
    local v = SCALES[scaleIndex] or 1
    if f then f:SetScale(v) end
    if btn then btn:SetText(format("Scale: %d%%", floor(v * 100 + 0.5))) end
end

-- ============================================================
-- CORNER SWITCHER -- the rounded-corner trial.
--
-- ⚠ PROTOTYPE, AND ONLY HERE. UI:CreateRoundedSurface (DandersUI/Round.lua) is a
-- parallel primitive to the kit's square CreateElementBackdrop; no real settings
-- page touches it, and this button is the only thing in the addon that does. The
-- question it exists to answer is whether the corners read CRISP at the scale
-- Danders actually plays at -- see the SLICE CONTRACT note in Round.lua's header
-- -- so cycle it with the Scale button and look at the curve, not at the colours.
-- The OTHER thing to drive is the popout's open/close animation: the surface is a
-- single nine-sliced texture per layer precisely so no joint can flicker open
-- while Fx runs the frame's scale through fractional values, and repeating that
-- at R6 is the test that shape change was made to pass.
--
-- Two widths on screen at once, deliberately: the row plates and this window take
-- a 1px ring and the popout's accent border takes 2px, which is the pair worth
-- comparing. The two title strips carry NO ring at all -- they are a fill that has
-- to follow the curve of the panel beneath them, not an outlined thing of their
-- own, and giving them an edge would draw a second line where the separator
-- already is. Note
-- that neither is quite the square version's weight -- the kit's pixel border is
-- 2 DEVICE pixels at 0.7 alpha, while these are 1 and 2 UI UNITS at full alpha
-- -- so a rounded edge reads a little lighter at 1px and a little heavier at
-- 2px than the square one it replaced. That is a property of the trial, not a
-- bug to squint at.
--
-- SQUARES RESTORE EXACTLY. Going back to Square hides the rounded textures (they
-- are ours; nothing else takes them down) and re-issues the ORIGINAL factory
-- call, so the demo returns to the shipping look rather than to an approximation
-- of it.
-- ============================================================
local CORNER_MODES = { false, 4, 6, 8 }     -- false = the square look we ship
local cornerIndex  = 1

local function cornerRadius() return CORNER_MODES[cornerIndex] end

-- ---- the title bar's cross, and the corner it was standing in --------
--
-- The other half of the same report: the cross's square hover box poked past the
-- panel's rounded top-right corner. It is a StyleButton -- a filled, 1px-outlined
-- rectangle -- parked HDR_EDGE in from the bar's right edge, which was chosen
-- against a square panel where "in from the edge" is the same distance whatever
-- height you read it at. Against an arc it is not: the last few units of the top
-- band belong to the curve, and a square box sitting in them reads as a corner
-- laid over a corner.
--
-- The fix is clearance, not a second rounded surface. A tr-only rounded backdrop
-- on the button would only be right if the button were flush INTO the panel's
-- corner, which it is not (it is inset on both axes and it is a different size
-- from the corner box), so it would put a curve of the wrong radius near a curve
-- of the right one -- which is the same complaint again. Moving it inboard by
-- half the radius takes it out of the corner box entirely at every radius the
-- trial offers, and costs one anchor.
--
-- ⚠ THE ORIGINAL OFFSET IS REMEMBERED, not recomputed. HDR_EDGE and the title
-- row's vertical nudge are Popout.lua file-locals; reading the anchor back and
-- shifting it means this stays correct if either is ever retuned, and means the
-- Square restore is the ORIGINAL number rather than an equal-looking literal
-- copied over here. Stored on the first shift so a second radius shifts from the
-- original rather than from the last shift -- the same rule roundPlate follows
-- for the backdrop methods it swaps.
local function edgeInset(radius)
    return radius and floor(radius / 2 + 0.5) or 0
end

local function insetTitleButton(btn, radius)
    if type(btn) ~= "table" or type(btn.GetPoint) ~= "function" then return end
    local point, rel, relPoint, x, y = btn:GetPoint(1)
    -- The 5-value shape or nothing. GetPoint always answers that in-game, so this
    -- is really a guard against being handed a button anchored some other way --
    -- and refusing is the right answer there, because re-issuing a point from
    -- values that do not mean what this thinks they mean would MOVE the button
    -- somewhere arbitrary rather than leave it where it was.
    if not point or type(rel) ~= "table" then return end
    if btn._demoSquareX == nil then btn._demoSquareX = x or 0 end
    btn:ClearAllPoints()
    -- Inboard is NEGATIVE x here: every one of these hangs off a RIGHT anchor.
    btn:SetPoint(point, rel, relPoint, btn._demoSquareX - edgeInset(radius), y or 0)
end

-- ---- the row plates ------------------------------------------------
-- The plate's hover/active repaint lives in a closure inside PopoutRow.lua and
-- drives plate:SetBackdropColor / :SetBackdropBorderColor. Rather than reach in
-- there, the two METHODS are swapped for ones that paint the rounded surface --
-- the same trick ApplyPixelBorder uses to keep ~150 existing hover call sites
-- working after their border stopped being a backdrop edge. So the row keeps
-- calling exactly what it always called, and hover and the active accent wash
-- both stay live on a rounded plate with no changes in the library.
local function roundPlate(plate, radius)
    plate:SetBackdrop(nil)
    UI:HidePixelBorder(plate)

    local M = UI.PopoutRow
    local rs = UI:CreateRoundedSurface(plate, {
        radius      = radius,
        borderWidth = 1,
        fill        = { C.element.r, C.element.g, C.element.b, M.restFill },
        border      = { C.border.r, C.border.g, C.border.b, M.restBorder },
    })

    -- Saved ONCE. A second round at a different radius must not capture the
    -- shims as though they were the originals -- that would make Square
    -- unreachable, and the failure would look like the button not working.
    if not plate._demoSquareFill then
        plate._demoSquareFill   = plate.SetBackdropColor
        plate._demoSquareBorder = plate.SetBackdropBorderColor
    end
    plate.SetBackdropColor       = function(_, r, g, b, a) rs:SetFillColor(r, g, b, a) end
    plate.SetBackdropBorderColor = function(_, r, g, b, a) rs:SetBorderColor(r, g, b, a) end
end

local function squarePlate(plate)
    local rs = UI:GetRoundedSurface(plate)
    if rs then rs:Hide() end
    if plate._demoSquareFill then
        plate.SetBackdropColor       = plate._demoSquareFill
        plate.SetBackdropBorderColor = plate._demoSquareBorder
    end
    -- The ORIGINAL call, verbatim from PopoutRow.lua's build. CreateElementBackdrop
    -- re-issues the backdrop AND re-shows the pixel border, and it reinstalls the
    -- border shim over the method just restored above -- which is correct: that
    -- shim IS the shipping behaviour.
    local M = UI.PopoutRow
    GUI:CreateElementBackdrop(plate, {
        bgColor     = { C.element.r, C.element.g, C.element.b, M.restFill },
        borderColor = { C.border.r, C.border.g, C.border.b, M.restBorder },
    })
end

-- ---- the title strip ------------------------------------------------
--
-- ☠ THE SQUARE STRIP WAS PAINTING OVER THE ROUNDED CORNERS, and that is the whole
-- of what "the title bar isn't rounded" turned out to be. `titleFill` is a flat
-- texture on the popout's FRAME at ARTWORK sublevel 1, and ARTWORK is above the
-- whole of BACKGROUND -- where the rounded surface lives. In SQUARE mode that is
-- harmless, because the pixel border sits higher again (ARTWORK 7) and wins the
-- edges. In rounded mode there is no pixel border to win them: the strip simply
-- covered the two upper arcs with a square block of C_PANEL, which against the
-- world behind the panel reads as an unmistakably square corner.
--
-- So in rounded mode the strip stops being that texture and becomes a SURFACE
-- with tl/tr round and bl/br square, at the same radius as the panel, so its
-- curve lies exactly on the panel fill's.
--
-- WHERE IT SITS, and why it needs Round's `sublevel` and `anchorTo` at all:
--
--     BACKGROUND -4   the panel's fill
--     BACKGROUND -3   THIS -- the strip, over the fill...
--     BACKGROUND -2   the panel's accent ring, over the strip
--
-- It has to be UNDER the ring or it eats the border along the top exactly the way
-- the square texture did, and a texture is only under the ring if it is on the
-- same frame (a child frame's regions draw above all of its parent's layers). So
-- the surface goes on the popout FRAME at a sublevel of its own, measured against
-- the title BAR's rect.
local STRIP_SUBLEVEL = -3

-- Fill tokens verbatim from Popout.lua's own titleFill: C_PANEL at PopoutTitle's
-- alpha. Deliberately not "something that shows up better" -- the trial is about
-- the SHAPE, and a strip that changed colour when it changed corners would make
-- the two modes incomparable.
local function roundStrip(frame, bar, radius)
    return UI:CreateRoundedSurface(frame, {
        radius   = radius,
        corners  = { tl = true, tr = true },
        border   = false,
        fill     = { C.panel.r, C.panel.g, C.panel.b, UI.PopoutTitle.fill },
        sublevel = STRIP_SUBLEVEL,
        anchorTo = bar,
    })
end

local function squareStrip(frame, titleFill)
    local s = UI:GetRoundedSurface(frame, STRIP_SUBLEVEL)
    if s then s:Hide() end
    if titleFill then titleFill:Show() end
end

-- ---- the popout's own chrome ---------------------------------------
-- The panel backdrop, the accent border -- which in rounded mode becomes the
-- rounded RING in the accent colour -- and the title strip above. The notch and
-- the beam are left alone: they are pointers, not chrome, and rounding them is a
-- separate question.
--
-- The SEPARATOR is left exactly as the library built it, full width and square.
-- Note what that costs in rounded mode: it is at ARTWORK 2 and the ring is at
-- BACKGROUND -2, so unlike the square mode's pixel border the ring does not win
-- the edges, and the hairline runs the last two pixels ACROSS the accent border
-- at both ends. Worth a look when judging the shape.
local function paintPopoutChrome(po)
    local f, radius = po.frame, cornerRadius()
    -- Both modes, first: the cross has to come back to its own offset on Square
    -- as reliably as it moves off it on R4, and putting the call before the
    -- branch is what makes that one statement instead of two.
    insetTitleButton(po.closeBtn, radius)
    if not radius then
        local rs = UI:GetRoundedSurface(f)
        if rs then rs:Hide() end
        squareStrip(f, po.titleFill)
        return
    end
    -- The square backdrop has just been re-issued by the base _ApplyAccent (see
    -- the hook below), so it is taken down again here rather than assumed gone:
    -- the rounded fill sits at a NEGATIVE BACKGROUND sublevel, under a backdrop's
    -- bgFile, so leaving it would simply render the square on top.
    f:SetBackdrop(nil)
    UI:HidePixelBorder(f)
    local c = po:GetAccent()
    UI:CreateRoundedSurface(f, {
        radius      = radius,
        borderWidth = 2,
        fill        = { C.panel.r, C.panel.g, C.panel.b, 1 },
        border      = { c.r, c.g, c.b, c.a or 1 },
    })
    if po.titleFill and po.titleBar then
        po.titleFill:Hide()
        roundStrip(f, po.titleBar, radius)
    end
end

-- Popout instances are POOLED per key and all four rows share one, so this runs
-- at most once per instance. Shadowing the method on the INSTANCE (its metatable
-- __index is the Popout class) leaves every other popout in the game untouched,
-- which is the whole point of doing it here rather than in the library.
--
-- ☠ "A SECOND CORNER AROUND A SELECTED OBJECT" -- the second shadow below.
-- The active row wore its rounded accent plate AND a square accent rectangle
-- around it, and the outer one is not the row's at all. It is the popout shell's
-- SOURCE OUTLINE: a 1px accent box the pack lays over whatever the panel is
-- tethered to, so the popout and the thing it is about share an edge
-- (Popout.lua, _UpdateSourceOutline). It goes on with ApplyPixelBorder, which is
-- square by construction and has no rounded sibling, so in rounded mode it
-- traced a hard rectangle round a plate that had just been given a curve.
--
-- In the trial the ROW'S OWN active ring already does that job -- same accent,
-- same rect, and round -- so the shell's outline is redundant here rather than
-- merely ugly, and it is suppressed rather than restyled.
--
-- The shadow READS THE MODE ON EVERY CALL instead of being installed and
-- removed. That is what makes Square exact: there is nothing to uninstall, the
-- call simply falls through to the real method again. _HideSourceOutline rather
-- than a bare Hide, because it also forgets which region the outline was
-- anchored to -- so the restore re-anchors instead of coming back on a stale
-- target, which matters here precisely because the demo's popout is pooled and
-- retargeted from row to row.
local function hookPopout(po)
    if po._demoCornerHooked then return end
    po._demoCornerHooked = true
    local base = po._ApplyAccent
    po._ApplyAccent = function(self)
        base(self)
        paintPopoutChrome(self)
    end
    local baseOutline = po._UpdateSourceOutline
    po._UpdateSourceOutline = function(self)
        if cornerRadius() then
            self:_HideSourceOutline()
            return
        end
        baseOutline(self)
    end
end

local function eachOpenPopout(fn)
    local seen = {}
    for _, r in pairs(rows) do
        local po = r.popout
        if po and not po.closed and not seen[po] then
            seen[po] = true
            fn(po)
        end
    end
end

-- ---- the demo window's own chrome ----------------------------------
-- The window was the one surface the trial did not reach: its rows and its
-- popouts rounded while the box they all sat in stayed hard-cornered, which made
-- the shape impossible to judge as a whole -- a rounded panel standing against a
-- square one reads as a mistake rather than as a look.
--
-- The same two moves as the popout, against the window's own tokens rather than
-- an accent: CreatePanelBackdrop's C_PANEL fill and C_BORDER edge. ONE unit of
-- ring, not the popout's two -- the popout's is heavier on purpose (it is the
-- accent, and it is the shared-edge story), and a neutral window border matching
-- the row plates keeps the demo showing both weights at once.
local function paintWindowChrome(f)
    local radius = cornerRadius()
    -- The window's cross sits in its top-right corner box too -- and closer than
    -- the popout's does, because this title bar is the shorter of the two. Its
    -- three sibling buttons chain off its LEFT, so moving it moves the cluster.
    insetTitleButton(f.closeBtn, radius)
    if not radius then
        local rs = UI:GetRoundedSurface(f)
        if rs then rs:Hide() end
        squareStrip(f, f.titleFill)
        -- The ORIGINAL call, verbatim from buildWindow. Re-issues the backdrop and
        -- re-shows the pixel border, the same way squarePlate restores a row.
        GUI:CreatePanelBackdrop(f)
        return
    end
    f:SetBackdrop(nil)
    UI:HidePixelBorder(f)
    UI:CreateRoundedSurface(f, {
        radius      = radius,
        borderWidth = 1,
        fill        = { C.panel.r, C.panel.g, C.panel.b, C.panel.a or 1 },
        border      = { C.border.r, C.border.g, C.border.b, 1 },
    })
    if f.titleFill and f.titleBar then
        f.titleFill:Hide()
        roundStrip(f, f.titleBar, radius)
    end
end

-- The FRAME is passed in rather than read off the file-local `win`, for applyScale's
-- reason: this runs once during buildWindow, before the toggle has assigned it.
local function applyCorners(f, btn)
    local radius = cornerRadius()
    for _, r in pairs(rows) do
        if radius then roundPlate(r.plate, radius) else squarePlate(r.plate) end
        -- Repaint through the row's own state machine, so a plate that is
        -- hovered or ACTIVE comes back in the colour it should be rather than at
        -- the rest colours the factory call above just wrote.
        r.Refresh()
    end
    if f then paintWindowChrome(f) end
    -- _ApplyAccent is hooked, so this repaints the chrome in EITHER direction:
    -- rounded mode paints the ring, square mode reissues the panel backdrop and
    -- the hook then hides the rounded textures.
    --
    -- ...and the source outline is driven SEPARATELY, because _ApplyAccent does
    -- not touch whether it is SHOWN -- it only repaints one that already is (see
    -- Popout.lua). Without this the outline would keep whatever state it had when
    -- the button was pressed: still square-outlining the active row after a
    -- switch INTO a radius, and still missing after a switch back to Square,
    -- until something else happened to re-dock the panel.
    eachOpenPopout(function(po)
        po:_ApplyAccent()
        po:_UpdateSourceOutline()
    end)
    if btn then btn:SetText(radius and format("Corners: R%d", radius) or "Corners: Square") end
end

-- ============================================================
-- THE WINDOW
-- ============================================================
local function buildWindow()
    local f = CreateFrame("Frame", "DFPopoutDemo", UIParent, "BackdropTemplate")
    f:SetSize(WIN_W, WIN_H)
    f:SetPoint("CENTER", UIParent, "CENTER", -160, 0)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    GUI:CreatePanelBackdrop(f)

    -- ---- title bar (the drag surface) ------------------------------
    local bar = CreateFrame("Frame", nil, f)
    bar:SetHeight(TITLE_H)
    bar:SetPoint("TOPLEFT", 0, 0)
    bar:SetPoint("TOPRIGHT", 0, 0)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function() f:StartMoving() end)
    bar:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    f.titleBar = bar

    -- ⚠ ADDED FOR THE CORNER TRIAL, and it changes the SQUARE look too. The window
    -- had no title strip at all -- no raised fill, no hairline -- so "round the
    -- window's title bar the way the popout's is rounded" had nothing to round.
    -- Giving it the strip in BOTH modes is what keeps the comparison honest: a
    -- strip that only existed in rounded mode would make the two modes differ by
    -- more than their corners, which is the one thing this button must not do.
    --
    -- Drawn exactly the way Popout.lua draws its own -- on the FRAME, not on the
    -- bar, at ARTWORK 1 and 2, off the same PopoutTitle tokens. Same construction,
    -- same result, and the demo window now stands in for a real settings window
    -- instead of for a bare box.
    local titleFill = f:CreateTexture(nil, "ARTWORK", nil, 1)
    titleFill:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
    titleFill:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
    titleFill:SetColorTexture(C.panel.r, C.panel.g, C.panel.b, UI.PopoutTitle.fill)
    f.titleFill = titleFill

    local titleSep = f:CreateTexture(nil, "ARTWORK", nil, 2)
    titleSep:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
    titleSep:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
    titleSep:SetHeight(1)
    titleSep:SetColorTexture(C.border.r, C.border.g, C.border.b, UI.PopoutTitle.sepAlpha)
    f.titleSep = titleSep

    local title = GUI:CreateLabelNative(bar, { text = "Popout Row Demo", size = 13, color = C.text })
    title:SetPoint("LEFT", PAD, 0)

    local closeBtn = GUI:CreateCloseButton(bar, {
        size = 18,
        tooltip = "Close",
        onClick = function() f:Hide() end,
    })
    -- ⚠ THE 5-ARGUMENT FORM, where this was `SetPoint("RIGHT", -6, 0)`. Same
    -- anchor -- the implicit relative frame IS the parent -- but written out, so
    -- insetTitleButton can read it back and re-issue it. Popout.lua's own cross
    -- is anchored the long way for no reason but house style; here it is load
    -- bearing.
    closeBtn:SetPoint("RIGHT", bar, "RIGHT", -6, 0)
    -- Kept, because the corner trial moves it: insetTitleButton needs a handle on
    -- the cross, and the three buttons below chain off it so they come along.
    f.closeBtn = closeBtn

    local accentBtn = GUI:CreateButtonNative(bar, {
        text = "Accent: Party", width = 100, height = 18, style = "ghost",
        fitText = false,
        tooltip = { title = "Accent", lines = { "Swap the rows between party purple and raid orange." } },
        onClick = function(self)
            accentMode = (accentMode == "raid") and "party" or "raid"
            applyAccent(self)
        end,
    })
    accentBtn:SetPoint("RIGHT", closeBtn, "LEFT", -6, 0)
    f.accentBtn = accentBtn

    local scaleBtn = GUI:CreateButtonNative(bar, {
        text = "Scale: 100%", width = 90, height = 18, style = "ghost",
        fitText = false,
        tooltip = { title = "Window Scale", lines = {
            "Cycle this window through 100/90/80/70%, the way the real settings",
            "window's scale slider does.",
            "Open a popout first: it should take the same scale, keep its beam",
            "touching the row's plate, and land exactly on the next row when you",
            "click another one.",
        } },
        onClick = function(self)
            scaleIndex = (scaleIndex % #SCALES) + 1
            applyScale(f, self)
        end,
    })
    scaleBtn:SetPoint("RIGHT", accentBtn, "LEFT", -6, 0)
    f.scaleBtn = scaleBtn

    local cornerBtn = GUI:CreateButtonNative(bar, {
        text = "Corners: Square", width = 96, height = 18, style = "ghost",
        fitText = false,
        tooltip = { title = "Corner Radius", lines = {
            "Cycle the demo between the square look we ship and rounded corners",
            "at radius 4, 6 and 8. PROTOTYPE -- nothing outside this window changes.",
            "Swaps the row plates, this window and its title strip, and -- with a",
            "popout open -- the panel's chrome and its title strip too: the accent",
            "border becomes a rounded ring, and neither title bar squares off the",
            "corners under it any more.",
            "Rounded mode also drops the square accent outline the panel lays over",
            "the active row, and nudges both crosses clear of the arc.",
            "THE question: are the corners crisp at your UI scale? Cycle the Scale",
            "button underneath each radius and watch the curve, not the colour.",
        } },
        onClick = function(self)
            cornerIndex = (cornerIndex % #CORNER_MODES) + 1
            applyCorners(f, self)
        end,
    })
    cornerBtn:SetPoint("RIGHT", scaleBtn, "LEFT", -6, 0)
    f.cornerBtn = cornerBtn

    -- ---- intro -----------------------------------------------------
    local intro = GUI:CreateLabelNative(f, {
        text = "Gate-one demo -- rows open real popouts outside this window's edge.",
        size = 11, color = C.textDim, width = WIN_W - PAD * 2,
    })
    intro:SetPoint("TOPLEFT", PAD, -(TITLE_H + 6))

    -- ---- the scrolling row list ------------------------------------
    local sf = CreateFrame("ScrollFrame", nil, f, "ScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", PAD, -(TITLE_H + 34))
    sf:SetPoint("BOTTOMRIGHT", -(PAD + 12), PAD)
    UI.StyleScrollBar(sf)

    local childW = WIN_W - PAD - (PAD + 12)
    local child = CreateFrame("Frame", nil, sf)
    child:SetWidth(childW)
    child:SetHeight(1)
    sf:SetScrollChild(child)

    local y = 0
    for _, def in ipairs(ROW_DEFS) do
        local row = GUI:CreatePopoutRow(child, {
            label    = def.label,
            count    = def.count,
            db       = demoDB,
            toggle   = def.toggle,
            summary  = def.summary,
            build    = def.build,
            enabled  = def.enabled,
            onToggle = def.onToggle,
            window   = f,
            -- The window decides WHERE the popout stands; the scroll frame
            -- decides whether the row is still on screen. They are not the same
            -- rect -- the title bar and the intro line above sit inside the
            -- window and outside the viewport -- and gating on the window left
            -- the beam and outline drawn over that chrome for two rows' worth of
            -- scrolling after the row itself had gone.
            clipTo   = sf,
            -- Passed at BUILD, not left to SetAccent alone: an unaccented row
            -- registers a theme listener on its tick, and a later host theme
            -- change would then pull that tick back to the host colour even
            -- though the switcher had given the row one of its own.
            accent   = accentColor(),
        })
        row:SetWidth(childW)
        row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
        -- The row stamps its own slot (preferredHeight + fixedRowHeight); the
        -- fallback is the same number from the same place, so a retune of the
        -- row's box model moves this list with it.
        y = y + (row.preferredHeight or UI.PopoutRow.slot)

        -- The corner trial's one hook into the row. A popout is built lazily on
        -- the first click and pooled thereafter, so there is no earlier moment at
        -- which its frame exists to round -- and a plain "round it when the
        -- button is pressed" would miss every panel opened afterwards.
        local baseOpen = row.OpenPopout
        row.OpenPopout = function(self, ...)
            local ret = baseOpen(self, ...)
            local po = self.popout
            if po then
                hookPopout(po)
                -- Fires the hook once for a panel that was already open in
                -- square mode and has just been retargeted to this row.
                po:_ApplyAccent()
                -- ...and again for the outline, which the open we just wrapped
                -- has ALREADY shown: OpenPopout runs the pack's placement, which
                -- ends in _Present -> _UpdateSourceOutline, and on the very first
                -- click that happens before hookPopout above has installed the
                -- shadow. So the first panel of the session would come up in
                -- rounded mode still wearing the square outline. Re-running it
                -- now goes through the shadow and takes it straight back down.
                po:_UpdateSourceOutline()
            end
            return ret
        end

        rows[def.name] = row
    end

    -- Filler, and it earns its place: with a popout open, scrolling the row it
    -- belongs to out of the viewport is the T1 behaviour worth eyeballing --
    -- the beam has to hide as the row clips and come back when it returns.
    y = y + UI.Space.section
    for i = 1, FILLER_ROWS do
        local fs = GUI:CreateLabelNative(child, {
            text = format("Filler row %d -- scroll me with a popout open", i),
            size = 11, color = C.textDim,
        })
        fs:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
        y = y + FILLER_H
    end
    child:SetHeight(max(y, 1))

    -- The X, the slash toggle and any other hide all land here, so there is ONE
    -- teardown. CloseAll, not CloseUnpinned: the window going away takes the
    -- panels the user pinned loose with it. (A real settings panel would ALSO
    -- call GUI:CloseUnpinnedPopoutRows on every page change -- there are no
    -- pages here, so there is nothing to wire it to.)
    f:SetScript("OnHide", function() GUI:CloseAllPopoutRows("api") end)

    applyAccent(accentBtn)
    applyScale(f, scaleBtn)
    -- Square on build, which is a no-op paint -- but it runs the same path the
    -- button does, so a broken restore shows up on the FIRST open rather than
    -- only after a full cycle back round to Square.
    applyCorners(f, cornerBtn)
    -- Built hidden, so the first /df popoutdemo SHOWS it rather than toggling a
    -- window nobody has seen yet straight back off.
    f:Hide()
    return f
end

-- ============================================================
-- ENTRY POINT -- /df popoutdemo
-- ============================================================
function DF:TogglePopoutDemo()
    if not win then win = buildWindow() end
    win:SetShown(not win:IsShown())
    return win
end
