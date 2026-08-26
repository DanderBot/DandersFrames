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

local WIN_W, WIN_H = 420, 500
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

    local title = GUI:CreateLabelNative(bar, { text = "Popout Row Demo", size = 13, color = C.text })
    title:SetPoint("LEFT", PAD, 0)

    local closeBtn = GUI:CreateCloseButton(bar, {
        size = 18,
        tooltip = "Close",
        onClick = function() f:Hide() end,
    })
    closeBtn:SetPoint("RIGHT", -6, 0)

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
        y = y + (row.preferredHeight or UI.RowHeight.checkbox)
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
