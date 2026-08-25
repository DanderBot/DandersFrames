local addonName, NS = ...
-- A copy that lost the LibStub race (a renamed duplicate install) must go
-- fully inert: Core.lua only sets NS.Lib on the winning copy.
if not NS.Lib then return end

-- ============================================================
-- ELEMENT PANEL
-- One DandersUI popout per element being edited. The shell (host:CreatePopout)
-- owns the frame, the title bar, the docking, the pin and the tether beam; this
-- file owns what goes INSIDE it and what closing it means.
--
-- ONE PANEL AT A TIME. Every element panel is opened in the family
-- "mover.panel", and a family is an exclusivity CLAIM in the shell: opening one
-- member closes every other, PINNED ONES INCLUDED. So there is never more than
-- one panel on screen -- selecting a mover leaves exactly the pooled popout,
-- following that mover's proxy.
--
-- PIN therefore means "stop following", not "keep a second one". A pinned panel
-- stays where it is and keeps editing ITS mover while the selection is cleared
-- or comes back to it; selecting a DIFFERENT mover closes it (reason "family")
-- and opens a fresh FOLLOWING panel over there. The shell still supports
-- several pinned members for consumers that want them -- the mover does not,
-- because a screen full of panels was never what the editor is for.
--
-- ⚠ Nothing here may read Session.selected inside a control. `build` runs ONCE
-- per instance and every closure it creates belongs to THAT instance, so a
-- control acts on `popout.el` -- the element its own panel is bound to -- which
-- for a pinned panel is not the selected one and never becomes it again.
--
-- Deliberately NOT a settings window, and no longer the session's action bar
-- either: the verbs that act on the SESSION (save, discard, undo, redo,
-- settings) live on the legend strip, because they are not about the element
-- whose panel you happen to have open. What is left is element content only.
-- ============================================================
local Pn = { live = {} }
NS.Panel = Pn

local Registry, Sess, Proxy, Solver, UI, L = NS.Registry, NS.Session, NS.Proxy, NS.Solver, NS.UI, NS.L
local CreateFrame, UIParent, IsShiftKeyDown, IsControlKeyDown = CreateFrame, UIParent, IsShiftKeyDown, IsControlKeyDown
local xpcall, geterrorhandler = xpcall, geterrorhandler
local format, tonumber, ipairs, pairs, floor, max, min = string.format, tonumber, ipairs, pairs, math.floor, math.max, math.min
local tremove, wipe = table.remove, wipe

-- The mover's own art, not the kit's (UI.MEDIA): the link glyph ships with this
-- addon because it is this addon's verb. 64px supersampled TGA so it stays
-- crisp at the 14px the drag handles draw it (SVG rendered as error squares
-- in-game -- see the note on Proxy.lua's copy of these constants).
local MEDIA = "Interface\\AddOns\\DandersMover\\Media\\"
local LINK_ICON = MEDIA .. "link"
-- The grip dots beside the chain: a 2x3 dot grid on its own 32px canvas, drawn
-- at 9px. Its ink is only the middle ~half of that canvas, so the drawn square
-- is wider than the dots look -- the margins are what keep the dots round.
local GRIP_ICON = MEDIA .. "grip"
local DEFAULT_ICON = UI.MEDIA .. "DF_Icon"

-- The pool key, and the family name -- deliberately the same string, because
-- for the mover they say the same thing. Per host+key the shell keeps ONE
-- unpinned instance (the panel that follows the selection); the FAMILY is what
-- extends that to pinned ones, so opening a panel for another element closes
-- whatever was up.
local POPOUT_KEY = "mover.panel"

-- Spacing comes from the theme so this panel keeps the rhythm of every other
-- DandersUI surface: PAD is the outer padding, GAP the gap between rows of
-- different kinds, TIGHT the gap inside a run of like things (buttons in a
-- row, the two X/Y pairs).
-- 260, not the old 236: the anchor block carries a label column and a drag
-- handle on the same row as its picker, and at 236 the picker was down to about
-- half the row. The shell insets the content by its own PAD, so what is handed
-- to CreatePopout is the CONTENT width and 260 is what the frame measures.
local W = 260
local PAD, GAP, TIGHT = UI.Space.section, UI.RowGap, UI.RowGapTight
local CW = W - PAD * 2            -- content width
local DOCK_GAP = 12               -- panel <-> proxy distance
local ADDON_H = 12                -- the dim addon-name line under the title bar
local HEADER_BTN_H = 18           -- the Configure row under it
local BOX_W = 62                  -- X / Y edit boxes
local NUDGE_CELL, NUDGE_ICON = 22, 14
local DOT, DOT_GAP = 16, 4        -- 9-point picker cells
local BTN_H = 20
-- ---- the anchor block --------------------------------------------
-- Its own group box, so "Anchor" reads as one subject rather than as three
-- dropdowns that happen to be stacked. UI.Space.section is a PAGE inset and a
-- 260px panel cannot spare 10px a side, so the box takes a tighter one.
local ANCHOR_PAD = 6
local ROW_H = 20                  -- the Target and Backup rows
local SPEC_H = 18                 -- the edge/align (or point/relPoint) pair
-- The link-drag handle at a picker row's right end. Wider than it is tall
-- because it is a GRIP, not an icon: grip dots on the left, the chain glyph on
-- the right, both inside a backdrop so the thing reads as a control you take
-- hold of rather than a decoration printed on the row. 24 is what those two
-- glyphs plus their insets measure -- the width buys an affordance, not a label,
-- and the picker beside it gives up 8px for it.
local HANDLE_W, HANDLE_H = 24, 16
local GRIP, HANDLE_GLYPH = 9, 12  -- the two glyph sizes inside that box
-- Hover: a small lift, quick enough to read as a response rather than an
-- animation. 1.15 on a 24x16 button is ~3px of growth.
local HOVER_SCALE, HOVER_DUR = 1.15, 0.08
-- The label column of the Target/Backup rows, measured from the labels
-- themselves (layoutAnchorBlock) and held between these: below the minimum the
-- rows stop lining up, above the maximum a long translation would eat the
-- picker instead of wrapping.
local LABEL_MIN, LABEL_MAX = 34, 96
-- What the seat pair's dropdowns keep for themselves whatever their labels
-- measure. Point mode is the tight case ("Rel point" beside "BOTTOMLEFT"), and
-- a clipped VALUE is a worse read than a clipped label -- the value is the thing
-- being set.
local SPEC_DROP_MIN = 56
local ACW = CW - ANCHOR_PAD * 2   -- the group box's inner content width
-- The kit's own grey-when-disabled dim (UI:CreateDropdown SetEnabled), matched
-- so a disabled label and the disabled dropdown beside it fade to the same depth.
local DISABLED_ALPHA = 0.4
local POINTS = { "TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT" }
-- Which of the anchor block's two fields a dropdown edits, per mode. The pair
-- is positional -- left dropdown, right dropdown -- and the mode decides what
-- each one means.
local SPEC_KEYS = { outside = { "edge", "align" }, point = { "point", "relPoint" } }
local SPEC_FALLBACK = { edge = "right", align = "center", point = "CENTER", relPoint = "CENTER" }

local function step() return Solver.NudgeStep(IsShiftKeyDown(), IsControlKeyDown()) end

-- The Target row's caption while the element is free. "None" on its own names
-- the state and stops there, which on the ONE row that has a gesture behind it
-- is a wasted line: the empty state teaches the gesture instead, with the chain
-- glyph inline so the sentence points at the handle sitting beside it.
--
-- The texture escape is assembled here and never inside the locale key -- a
-- translator gets the sentence with a gap, not a file path to preserve.
local function unanchoredCaption()
    return format(L["None — drag %s to link"], "|T" .. LINK_ICON .. ".tga:12:12|t")
end

-- The anchor mode of whatever element a panel is bound to. Every control that
-- edits the seat pair asks this rather than a cached flag, because two panels
-- open at once can be in different modes.
local function specModeOf(el)
    if not el then return "outside" end
    local a = Registry:GetPos(el).anchor
    return (a and a.mode == "point") and "point" or "outside"
end

-- ============================================================
-- GRAB CURSOR
-- The move cursor while the pointer is over a drag handle: the one affordance
-- that says "this is draggable" before you press anything.
--
-- ☠ SetCursor is SILENT about a path it cannot resolve -- it draws a BLACK
-- SQUARE where the pointer should be rather than erroring -- so a pcall is not
-- a guard against a wrong path, only against a missing API. The path is
-- therefore PROBED first through a throwaway texture: SetTexture answers false
-- for a file that is not in the client, the same idiom the header uses to fall
-- back on the addon icon. A probe that fails, or is inconclusive on a stub,
-- drops the whole affordance rather than risking the square.
--
-- Looked up through _G at call time, not cached at file scope: the headless
-- tests inject their own to see that both guards hold.
-- ============================================================
local GRAB_CURSOR = "Interface\\CURSOR\\UI-Cursor-Move"
local cursorProbe                 -- nil = not probed yet, then true/false

local function setGrabCursor(on)
    local set, reset = _G.SetCursor, _G.ResetCursor
    if type(set) ~= "function" or type(reset) ~= "function" then return end
    if cursorProbe == nil then
        cursorProbe = false
        local ok, probe = pcall(function() return UIParent:CreateTexture(nil, "BACKGROUND") end)
        if ok and probe then
            cursorProbe = probe:SetTexture(GRAB_CURSOR) ~= false
            probe:Hide()
        end
    end
    if not cursorProbe then return end
    if on then pcall(set, GRAB_CURSOR) else pcall(reset) end
end

-- A row of equal-width buttons spanning the content width.
local function buttonRow(parent, y, height, defs)
    local n = #defs
    local bw = floor((CW - TIGHT * (n - 1)) / n)
    local out = {}
    for i, d in ipairs(defs) do
        local b = UI:CreateButton(parent, {
            text = d.text, width = bw, height = height, onClick = d.onClick,
            style = d.style, tone = d.tone, fitText = false,
        })
        b:SetPoint("TOPLEFT", (i - 1) * (bw + TIGHT), y)
        out[i] = b
    end
    return out
end

-- ============================================================
-- ANCHOR BLOCK LAYOUT
-- Every row is always there -- an unanchored element greys the ones it has no
-- answer for rather than dropping them, so the block never changes height and
-- the panel never jumps as you anchor and detach. What IS measured here is the
-- label columns: a FontString reads 0 wide until its font resolves, and the
-- labels also swap with the anchor mode, so the columns are re-measured on every
-- layout rather than fixed at build.
--
-- Returns the height the block consumes, gap to the rows below included.
-- ============================================================
-- Grey a whole picker row: the kit dims the dropdown itself, the label and the
-- handle are ours to match. A disabled Button already refuses OnMouseDown, and
-- Sess:BeginLink refuses a fallback link with no primary anyway -- the alpha is
-- there to say so before the user tries.
local function setRowEnabled(row, enabled)
    row.picker:SetEnabled(enabled)
    row.label:SetAlpha(enabled and 1 or DISABLED_ALPHA)
    row.handle:SetEnabled(enabled)
    row.handle:SetAlpha(enabled and 1 or DISABLED_ALPHA)
end

-- Both labels of a pair take the wider of the two, so the two pickers start on
-- the same column and the rows read as a table.
local function labelColumn(a, b, floorW, ceilW)
    local w = max(a:GetStringWidth() or 0, b:GetStringWidth() or 0)
    w = min(max(w, floorW), max(floorW, ceilW))
    a:SetWidth(w); b:SetWidth(w)
    return w
end

local function layoutAnchorBlock(ui)
    labelColumn(ui.targetRow.label, ui.backupRow.label, LABEL_MIN, LABEL_MAX)
    -- The seat pair sits in half a row each, and its labels swap with the mode
    -- ("Rel point" is twice "Align"), so the column is capped at whatever leaves
    -- the dropdown its own minimum rather than at a fixed number.
    local halfW = floor((ACW - GAP) / 2)
    labelColumn(ui.edgeLabel, ui.alignLabel, 24, halfW - SPEC_DROP_MIN)

    local contentH = ROW_H + TIGHT + SPEC_H + TIGHT + ROW_H
    ui.anchorBox:SetContentHeight(contentH)
    local h = (ui.anchorBox:GetHeight() or contentH) + GAP
    ui.rest:ClearAllPoints()
    ui.rest:SetPoint("TOPLEFT", 0, -h)
    return h
end

-- Size the X/Y group to its current labels so it stays centred. Both labels
-- take the wider of the two, so the pairs mirror each other; the boxes give up
-- width when the labels are long ("Offset X") so the group never overflows.
local function layoutXY(ui)
    local lw = max(ui.xLabel:GetStringWidth() or 0, ui.yLabel:GetStringWidth() or 0)
    ui.xLabel:SetWidth(lw); ui.yLabel:SetWidth(lw)
    local pair = lw + TIGHT - 2
    local bw = max(40, floor(min(BOX_W, (CW - GAP) / 2 - pair)))
    ui.xBox:SetWidth(bw); ui.yBox:SetWidth(bw)
    ui.xyRow:SetWidth((pair + bw) * 2 + GAP)
end

-- The addon line is always there; Configure only exists for elements whose def
-- offers openSettings. Returns the height consumed above the body.
local function layoutContent(ui, canConfigure)
    ui.btnConfigure:SetShown(canConfigure)
    local top = ADDON_H + (canConfigure and (TIGHT + HEADER_BTN_H) or 0) + GAP
    ui.body:ClearAllPoints()
    ui.body:SetPoint("TOPLEFT", 0, -top)
    return top
end

-- ============================================================
-- DRAG HANDLE LOOK
-- The glyph button gives us the chain, the tooltip and the click plumbing; this
-- is the GRIP half -- the part that says the control is draggable before you
-- have touched it. A backdrop box so it reads as a thing rather than as art
-- printed on the row, grip dots beside the chain, and a hover state that lifts,
-- brightens and takes the move cursor.
--
-- Both handles come through here: primary and backup are the same gesture, so
-- they must not look like different kinds of control.
-- ============================================================
local function styleHandle(btn)
    UI:CreateElementBackdrop(btn)
    -- The kit centres its glyph; here it shares the box with the dots, so each
    -- is pinned to its own end.
    btn.Icon:ClearAllPoints()
    btn.Icon:SetPoint("RIGHT", -1, 0)
    btn.Grip = btn:CreateTexture(nil, "OVERLAY")
    btn.Grip:SetTexture(GRIP_ICON)
    btn.Grip:SetSize(GRIP, GRIP)
    btn.Grip:SetPoint("LEFT", 1, 0)
    local dim, border = UI.Colors.textDim, UI.Colors.border
    btn.Grip:SetVertexColor(dim.r, dim.g, dim.b)

    -- Chained, not replaced: the kit's own OnEnter owns the chain tint and the
    -- tooltip, and both handles keep theirs.
    local prevEnter, prevLeave = btn:GetScript("OnEnter"), btn:GetScript("OnLeave")
    -- Whether the cursor currently on screen is OURS. An upvalue rather than a
    -- field on the button: the pair of scripts is per handle anyway, and a flag
    -- that lives in the closure cannot be read back wrong.
    local grabbed = false
    btn:SetScript("OnEnter", function(self, ...)
        if prevEnter then prevEnter(self, ...) end
        -- A greyed backup handle refuses the gesture, so it must not advertise
        -- it either -- no lift, no cursor.
        if not self:IsEnabled() then return end
        local accent = UI:GetAccent()
        NS.Fx.ScaleTo(self, HOVER_SCALE, HOVER_DUR)
        self.Grip:SetVertexColor(1, 1, 1)
        self:SetBackdropBorderColor(accent.r, accent.g, accent.b, 1)
        -- Mid-gesture the cursor belongs to the GESTURE, which may have set its
        -- own. The button keeps mouse capture between press and release, so the
        -- pointer comes back over it while a link is live and grabbing here
        -- would fight the drag.
        if not Sess.linking then
            grabbed = true
            setGrabCursor(true)
        end
    end)
    btn:SetScript("OnLeave", function(self, ...)
        if prevLeave then prevLeave(self, ...) end
        NS.Fx.ScaleTo(self, 1, HOVER_DUR)
        self.Grip:SetVertexColor(dim.r, dim.g, dim.b)
        self:SetBackdropBorderColor(border.r, border.g, border.b, 0.5)
        -- Only ours to put back: an enter that skipped the cursor (disabled, or
        -- mid-gesture) must not reset one the gesture set.
        if grabbed then
            grabbed = false
            setGrabCursor(false)
        end
    end)
end

-- ============================================================
-- BUILD
-- Runs ONCE per popout instance (the shell re-runs it only for a genuinely new
-- frame), so everything it makes is stored on `po.ui` and every closure it
-- creates closes over `po` -- never over the selection.
-- ============================================================
local function buildPanel(po, content)
    local ui = {}
    po.ui = ui

    -- ---- the addon this element belongs to --------------------------
    -- The shell's title bar carries the icon and the element's own title; the
    -- addon name is context under it, muted, one line.
    ui.addon = UI:CreateLabel(content, { size = 10, color = UI.Colors.textDim })
    ui.addon:SetWidth(CW)
    ui.addon:SetWordWrap(false)
    ui.addon:SetPoint("TOPLEFT", 0, 0)

    -- ---- Configure --------------------------------------------------
    -- The CONSUMER entry point (this element's own options page). Full width,
    -- and only for defs that offer openSettings -- the session's own Settings
    -- window lives on the legend strip now, not here.
    ui.btnConfigure = UI:CreateButton(content, {
        text = L["Configure"], width = CW, height = HEADER_BTN_H, style = "ghost", fitText = false,
        tooltip = { title = L["Configure"], lines = { L["Open this element's own settings."] } },
        onClick = function()
            local el = po.el
            if el and el.openSettings then xpcall(el.openSettings, geterrorhandler()) end
        end,
    })
    ui.btnConfigure:SetPoint("TOPLEFT", 0, -(ADDON_H + TIGHT))
    ui.btnConfigure:Hide()

    -- ---- body -------------------------------------------------------
    -- Its own frame so the two header lines above can come and go: these rows
    -- keep their build-time offsets and only the body's single anchor moves.
    local body = CreateFrame("Frame", nil, content)
    body:SetWidth(CW)
    body:SetPoint("TOPLEFT", 0, 0)          -- layoutContent re-anchors it
    ui.body = body

    -- ---- anchor block ------------------------------------------------
    -- One titled sub-section, three labelled rows: what this element is
    -- anchored TO, how it sits on it, and where it goes when that target is off
    -- screen. Every row is labelled, because three unlabelled dropdowns in a
    -- column tell you nothing about which is which.
    ui.anchorBox = UI:CreateGroupBox(body, { title = L["Anchor"], width = CW, padding = ANCHOR_PAD })
    ui.anchorBox:SetPoint("TOPLEFT", 0, 0)
    local ac = ui.anchorBox.content

    -- ---- Target / Backup rows ----------------------------------------
    -- Both are built by the same helper so they line up without either one
    -- knowing about the other. Each is a muted label, a picker taking the rest
    -- of the row, and a link-drag handle at the right end.
    --
    -- The handle is the aimed form of what the picker chooses: hold it, drag
    -- the line onto a target and let go. Press and release are deliberately
    -- OnMouseDown/OnMouseUp rather than an onClick -- the gesture has to START
    -- on the press and FINISH wherever the cursor ended up, which a click (down
    -- and up on the same button) cannot express. The button keeps mouse capture
    -- between the two, so the release comes back here even though the cursor is
    -- over a proxy by then.
    local function pickerRow(parent, o)
        local row = CreateFrame("Frame", nil, parent)
        row:SetSize(ACW, ROW_H)
        row.label = UI:CreateLabel(row, { text = o.label, size = 10, color = UI.Colors.textDim })
        -- The column is capped (labelColumn), so a long translation has to clip
        -- rather than wrap: a second line would fall through the row below it.
        row.label:SetWordWrap(false)
        row.label:SetPoint("LEFT", 0, 0)
        row.handle = UI:CreateGlyphButton(row, {
            texture = LINK_ICON, width = HANDLE_W, height = HANDLE_H,
            iconSize = HANDLE_GLYPH, tooltip = o.handleTooltip,
        })
        row.handle:SetPoint("RIGHT", 0, 0)
        styleHandle(row.handle)
        row.handle:RegisterForClicks("AnyUp", "AnyDown")
        row.handle:SetScript("OnMouseDown", function(_, button)
            local el = po.el
            if not el then return end
            if button == "LeftButton" then
                -- Taking hold of the chain is editing: the panel earns its keep.
                po:AutoPin()
                Sess:BeginLink(el, o.mode)
            elseif button == "RightButton" and Sess.linking then Sess:CancelLink() end
        end)
        row.handle:SetScript("OnMouseUp", function(_, button)
            if button == "LeftButton" and Sess.linking then
                Sess:EndLink(Proxy.LinkHover and Proxy:LinkHover() or nil)
            end
        end)
        row.picker = UI:CreateDropdown(row, o.dropdown)
        -- An inline dropdown's factory label is hidden, so the kit's usual
        -- label-hover tooltip has nothing to sit on; openerTooltip puts it on
        -- the opener itself. Worth having: "Target" alone does not say that
        -- picking one MOVES NOTHING, which is the whole point of the row.
        row.picker.openerTooltip = o.tooltip
        -- The opener's caption CLIPS, it does not wrap. Its FontString is
        -- anchored to both edges with word wrap left on by the kit, so a caption
        -- wider than the opener takes a second line and spills straight out of a
        -- 20px row. Short captions never showed it; the Target row's empty state
        -- ("None -- drag [chain] to link") is close to the width in English and a
        -- translation will pass it.
        row.picker.opener.Text:SetWordWrap(false)
        row.picker:SetHeight(ROW_H)
        -- Two-point anchored rather than sized, so the picker absorbs whatever
        -- the measured label column leaves it.
        --
        -- ☠ The right edge is measured off the ROW, not off the handle sitting
        -- there. Anchor offsets resolve in screen space, so a picker pinned to
        -- the handle's LEFT would slide every time the handle's hover lift
        -- scaled it -- the whole dropdown jittering because you passed the
        -- cursor over the grip.
        row.picker:SetPoint("LEFT", row.label, "RIGHT", TIGHT, 0)
        row.picker:SetPoint("RIGHT", row, "RIGHT", -(HANDLE_W + TIGHT), 0)
        return row
    end

    -- Anchoring without dragging: pick a target and the element stays exactly
    -- where it is (Sess:AnchorInPlace derives the spec that reproduces its
    -- current seat). The list is rebuilt on every open (optionsFunc) because
    -- what is legal changes with the graph and with what is on screen -- and
    -- that same open is one of the auto-pin triggers.
    ui.targetRow = pickerRow(ac, {
        label = L["Target"], mode = "primary",
        tooltip = { title = L["Target"],
                    lines = { L["What this element is anchored to. Picking one does not move it."] } },
        handleTooltip = { title = L["Anchor"], lines = { L["Drag onto another mover to attach"] } },
        dropdown = {
            inline = true, searchable = true,
            optionsFunc = function()
                po:AutoPin()
                local el = po.el
                return el and NS.Picker:Options(el) or { _order = {} }
            end,
            get = function()
                local el = po.el; if not el then return nil end
                local a = Registry:GetPos(el).anchor
                return a and a.target or nil
            end,
            set = function(targetId)
                local el = po.el
                if el then Sess:AnchorInPlace(el, targetId) end
            end,
        },
    })
    ui.targetRow:SetPoint("TOPLEFT", 0, 0)
    -- refreshInstance owns this caption from here on; set once so the opener
    -- never renders the raw value between build and the refresh that follows it.
    ui.targetRow.picker:SetDisplayOverride(unanchoredCaption())

    -- Where the element goes when the primary target is not on screen. Only
    -- meaningful once there IS a primary, so both the picker and its handle go
    -- grey while the element is free.
    ui.backupRow = pickerRow(ac, {
        label = L["Backup"], mode = "fallback",
        tooltip = { title = L["Backup"],
                    lines = { L["Where this element goes while the target above is off screen."] } },
        handleTooltip = { title = L["Backup"], lines = { L["Drag onto another mover to set the backup anchor"] } },
        dropdown = {
            inline = true, searchable = true,
            optionsFunc = function()
                po:AutoPin()
                local el = po.el
                return el and NS.Picker:Options(el, "fallback") or { _order = {} }
            end,
            get = function()
                local el = po.el; if not el then return NS.Picker.NONE end
                local a = Registry:GetPos(el).anchor
                return a and a.fallback and a.fallback.target or NS.Picker.NONE
            end,
            set = function(targetId)
                local el = po.el; if not el then return end
                if targetId == NS.Picker.NONE then Sess:ClearFallback(el) else Sess:SetFallback(el, targetId) end
            end,
        },
    })
    ui.backupRow:SetPoint("TOPLEFT", 0, -(ROW_H + TIGHT + SPEC_H + TIGHT))
    ui.backupRow.picker:SetDisplayOverride(L["None"])

    -- ---- the seat: edge/align, or point/relPoint ---------------------
    -- One pair of dropdowns whose SUBJECT follows the anchor's mode, because the
    -- two modes describe a seat with different fields and only one of them is
    -- ever live. The refresh swaps both the labels and the option sets.
    ui.specRow = CreateFrame("Frame", nil, ac)
    ui.specRow:SetSize(ACW, SPEC_H)
    ui.specRow:SetPoint("TOPLEFT", 0, -(ROW_H + TIGHT))
    local halfW = floor((ACW - GAP) / 2)
    -- The 9 anchor points are API identifiers, not prose -- they read the same
    -- in every locale and the panel already spells them out raw elsewhere, so
    -- the same table serves both point-mode slots.
    local POINT_OPTS = { _order = POINTS }
    for _, p in ipairs(POINTS) do POINT_OPTS[p] = p end
    ui.specOptions = {
        outside = {
            { _order = { "right", "left", "top", "bottom" },
              right = L["Right"], left = L["Left"], top = L["Top"], bottom = L["Bottom"] },
            { _order = { "start", "center", "end" },
              start = L["Start"], center = L["Center"], ["end"] = L["End"] },
        },
        point = { POINT_OPTS, POINT_OPTS },
    }
    local function specDrop(slot)
        local drop = UI:CreateDropdown(ui.specRow, {
            inline = true, options = ui.specOptions.outside[slot],
            -- Opening the menu is editing, and the set it opens on follows the
            -- element THIS panel is bound to -- two panels can be in two modes.
            optionsFunc = function()
                po:AutoPin()
                return ui.specOptions[specModeOf(po.el)][slot]
            end,
            get = function()
                local el = po.el
                local key = SPEC_KEYS[specModeOf(el)][slot]
                if not el then return SPEC_FALLBACK[key] end
                local a = Registry:GetPos(el).anchor
                return (a and a[key]) or SPEC_FALLBACK[key]
            end,
            set = function(v)
                local el = po.el; if not el then return end
                Sess:SetAnchorSpec(el, { [SPEC_KEYS[specModeOf(el)][slot]] = v })
            end,
        })
        drop:SetHeight(SPEC_H)
        return drop
    end
    ui.edgeLabel = UI:CreateLabel(ui.specRow, { text = L["Edge"], size = 10, color = UI.Colors.textDim })
    ui.edgeLabel:SetWordWrap(false)
    ui.edgeLabel:SetPoint("LEFT", 0, 0)
    ui.edgeDrop = specDrop(1)
    ui.edgeDrop:SetPoint("LEFT", ui.edgeLabel, "RIGHT", TIGHT, 0)
    ui.edgeDrop:SetPoint("RIGHT", ui.specRow, "LEFT", halfW, 0)
    ui.alignLabel = UI:CreateLabel(ui.specRow, { text = L["Align"], size = 10, color = UI.Colors.textDim })
    ui.alignLabel:SetWordWrap(false)
    ui.alignLabel:SetPoint("LEFT", ui.specRow, "LEFT", halfW + GAP, 0)
    ui.alignDrop = specDrop(2)
    ui.alignDrop:SetPoint("LEFT", ui.alignLabel, "RIGHT", TIGHT, 0)
    ui.alignDrop:SetPoint("RIGHT", ui.specRow, "RIGHT", 0, 0)
    ui.specMode = "outside"

    -- ---- everything below the anchor block ---------------------------
    -- Its own frame so the block above can sit at whatever height the group box
    -- measures: these rows keep their build-time offsets and only ui.rest's
    -- single anchor moves.
    local rest = CreateFrame("Frame", nil, body)
    rest:SetWidth(CW)
    rest:SetPoint("TOPLEFT", 0, 0)          -- layoutAnchorBlock re-anchors it
    ui.rest = rest

    local y = 0
    -- Reserve a row of height h and return its top; gap is the space to leave below it.
    local function row(h, gap) local cur = y; y = y - h - (gap or GAP); return cur end

    -- ---- X / Y: two label+box pairs centred as one group ------------
    -- The pairs live in a container whose width is recomputed on every refresh
    -- (the labels change between "X" and "Offset X"), and the container is
    -- centred in the panel, so the group stays centred whatever the labels say.
    local ry = row(20)
    ui.xyRow = CreateFrame("Frame", nil, rest)
    ui.xyRow:SetSize(CW, 20)
    ui.xyRow:SetPoint("TOP", rest, "TOP", 0, ry)
    ui.xLabel = UI:CreateLabel(ui.xyRow, { text = L["X"], size = 11, justify = "RIGHT" })
    ui.xLabel:SetPoint("LEFT", 0, 0)
    ui.xBox = UI:CreateEditBox(ui.xyRow, {
        width = BOX_W, numeric = true,
        get = function()
            local el = po.el; if not el then return 0 end
            local pos = Registry:GetPos(el)
            return pos.anchor and (pos.anchor.offsetX or 0) or floor((pos.x or 0) + 0.5)
        end,
        onCommit = function(v)
            local el = po.el
            if el then Sess:SetXY(el, v, tonumber(ui.yBox:GetText()) or 0) end
        end,
    })
    ui.xBox:SetPoint("LEFT", ui.xLabel, "RIGHT", TIGHT - 2, 0)
    ui.yLabel = UI:CreateLabel(ui.xyRow, { text = L["Y"], size = 11, justify = "RIGHT" })
    ui.yLabel:SetPoint("LEFT", ui.xBox, "RIGHT", GAP, 0)
    ui.yBox = UI:CreateEditBox(ui.xyRow, {
        width = BOX_W, numeric = true,
        get = function()
            local el = po.el; if not el then return 0 end
            local pos = Registry:GetPos(el)
            return pos.anchor and (pos.anchor.offsetY or 0) or floor((pos.y or 0) + 0.5)
        end,
        onCommit = function(v)
            local el = po.el
            if el then Sess:SetXY(el, tonumber(ui.xBox:GetText()) or 0, v) end
        end,
    })
    ui.yBox:SetPoint("LEFT", ui.yLabel, "RIGHT", TIGHT - 2, 0)
    -- Taking focus in a coordinate box is the clearest "I am editing THIS one"
    -- there is, and it is also the moment a panel that keeps re-docking under
    -- the cursor is most in the way.
    for _, box in ipairs({ ui.xBox, ui.yBox }) do
        box:HookScript("OnEditFocusGained", function() po:AutoPin() end)
    end

    -- ---- nudge cluster | 9-point picker: two equal halves ------------
    -- Each cluster sits in its own container, centred in its half of the
    -- content width and on the same vertical centre.
    local clusterH = max(NUDGE_CELL * 3, DOT * 3 + DOT_GAP * 2)
    local ny = row(clusterH)
    local half = CW / 2

    ui.nudge = CreateFrame("Frame", nil, rest)
    ui.nudge:SetSize(NUDGE_CELL * 3, NUDGE_CELL * 3)
    ui.nudge:SetPoint("CENTER", rest, "TOPLEFT", half / 2, ny - clusterH / 2)
    local ARROWS = {   -- icon, dx, dy, column, row (0-based in the 3x3 cluster)
        { "expand_less",   0,  1, 1, 0 },
        { "chevron_left", -1,  0, 0, 1 },
        { "chevron_right", 1,  0, 2, 1 },
        { "expand_more",   0, -1, 1, 2 },
    }
    ui.nudgeButtons = {}
    for i, a in ipairs(ARROWS) do
        local icon, dx, dy, col, rowi = a[1], a[2], a[3], a[4], a[5]
        local b = UI:CreateGlyphButton(ui.nudge, {
            texture = UI.MEDIA .. "Icons\\" .. icon, size = NUDGE_CELL, iconSize = NUDGE_ICON,
            onClick = function()
                local el = po.el
                if not el then return end
                -- Pin BEFORE the nudge: a following panel would otherwise
                -- re-dock under the cursor on the very keypress that asked for
                -- a run of them.
                po:AutoPin()
                Sess:Nudge(el, dx * step(), dy * step())
            end,
            tooltip = { title = L["Nudge"], lines = { L["Hold Shift for 10 units, Ctrl for 100."] } },
        })
        b:SetPoint("TOPLEFT", col * NUDGE_CELL, -rowi * NUDGE_CELL)
        ui.nudgeButtons[i] = b
    end

    ui.picker = CreateFrame("Frame", nil, rest)
    ui.picker:SetSize(DOT * 3 + DOT_GAP * 2, DOT * 3 + DOT_GAP * 2)
    ui.picker:SetPoint("CENTER", rest, "TOPLEFT", half + half / 2, ny - clusterH / 2)
    ui.points = {}
    for i, point in ipairs(POINTS) do
        local col, rowi = (i - 1) % 3, floor((i - 1) / 3)
        local b = UI:CreateButton(ui.picker, {
            width = DOT, height = DOT,
            onClick = function()
                local el = po.el
                if not el then return end
                po:AutoPin()
                Sess:SetAnchorPoint(el, point)
            end,
            tooltip = point,
        })
        b:SetPoint("TOPLEFT", col * (DOT + DOT_GAP), -rowi * (DOT + DOT_GAP))
        b.point = point
        ui.points[i] = b
    end

    -- ---- actions -------------------------------------------------
    local acts = buttonRow(rest, row(BTN_H), BTN_H, {
        { text = L["Center"], onClick = function() local el = po.el; if el then Sess:Center(el) end end },
        { text = L["Reset"],  onClick = function() local el = po.el; if el then Sess:Reset(el) end end },
        { text = L["Detach"], onClick = function() local el = po.el; if el then Sess:Detach(el) end end },
    })
    ui.btnCenter, ui.btnReset, ui.btnDetach = acts[1], acts[2], acts[3]

    -- Copy-to-twin: full-width bottom row, only for elements whose def names a
    -- twin (the refresh shows it and grows the panel by the row).
    -- ☠ `text = ""`, not omitted. The label is only knowable at refresh time (it
    -- names the twin), but UI:StyleButton creates the button's FontString --
    -- and registers it via SetFontString, which is what makes the NATIVE
    -- Button:SetText work -- ONLY when `text` is passed. Omit it and the
    -- button has no font string at all, so the SetText below silently no-ops
    -- and the row renders blank. An empty string is enough to get the font
    -- string built; `fitText = false` keeps it from resizing off it.
    ui.btnCopy = UI:CreateButton(rest, {
        text = "", width = CW, height = BTN_H, fitText = false,
        onClick = function() local el = po.el; if el then Sess:CopyToTwin(el) end end,
    })
    ui.btnCopy:SetPoint("TOPLEFT", 0, row(BTN_H, 0))
    ui.btnCopy:Hide()

    -- Heights of the rows BELOW the anchor block, with and without the copy row.
    -- The block adds its own on top (layoutAnchorBlock) and the two header lines
    -- their own above that (layoutContent), so the total is settled per refresh.
    ui.restFullH = -y
    ui.restBaseH = ui.restFullH - BTN_H - GAP
    rest:SetHeight(ui.restBaseH)
end

-- ============================================================
-- PER-INSTANCE REFRESH
-- Everything a panel shows comes from ITS OWN element, never from the
-- selection: a pinned panel keeps reporting the mover it was pinned for while
-- the selection has moved on.
-- ============================================================
local function refreshInstance(po)
    if po.closed or not po.ui then return end
    local el = po.elId and Registry:Get(po.elId) or nil
    if not el then return end
    po.el = el
    local ui = po.ui
    local pos = Registry:GetPos(el)

    local addon = Registry:GetAddon(el.addon)
    local icon = addon and addon.icon or DEFAULT_ICON
    po:SetHeader(el.title, icon)
    -- SetTexture answers false for a file the client does not have; the shell
    -- takes whatever it is handed, so the fallback is ours to apply.
    if po.iconTex and po.iconTex:SetTexture(icon) == false then po.iconTex:SetTexture(DEFAULT_ICON) end
    ui.addon:SetText(addon and addon.title or el.addon)

    local top = layoutContent(ui, el.openSettings ~= nil)

    local a = pos.anchor
    if a then
        -- Name whichever block is actually driving the element: the backup
        -- taking over is the one thing the panel must not stay quiet about, and
        -- naming the primary's target while the backup holds it would be a lie.
        -- Just the NAME -- the seat has its own labelled row underneath, so the
        -- old "(right/center)" tail is said twice over.
        local active = Registry:ActiveAnchor(el)
        local blk = active or a
        local target = Registry:GetTarget(blk.target)
        local text = target and target.title or L["(unavailable)"]
        if active ~= nil and active == a.fallback then text = L["(backup)"] .. " " .. text end
        ui.targetRow.picker:SetDisplayOverride(text)
        ui.xLabel:SetText(L["Offset X"]); ui.yLabel:SetText(L["Offset Y"])
        ui.btnDetach:SetEnabled(true)
        for _, b in ipairs(ui.points) do b:Hide() end
    else
        ui.targetRow.picker:SetDisplayOverride(unanchoredCaption())
        ui.xLabel:SetText(L["X"]); ui.yLabel:SetText(L["Y"])
        ui.btnDetach:SetEnabled(false)
        local cur = pos.point or "CENTER"
        for _, b in ipairs(ui.points) do
            -- pointLocked: the consumer derives `point` (e.g. a growth corner); a
            -- picker would be silently overwritten, so it is not offered.
            b:SetShown(not el.pointLocked)
            b:SetActive(b.point == cur)
        end
    end

    -- Backup: only meaningful once there IS a primary to fall back FROM, so the
    -- row greys rather than vanishing -- an empty row you can see is what tells
    -- you the setting exists at all.
    local ftext = L["None"]
    local fb = a and a.fallback
    if fb then
        local ft = Registry:GetTarget(fb.target)
        ftext = ft and ft.title or L["(unavailable)"]
        if ft and not Registry:IsTargetAvailable(ft) then ftext = ftext .. " " .. L["(hidden)"] end
    end
    ui.backupRow.picker:SetDisplayOverride(ftext)

    -- The seat pair follows the mode. Swapping the option set rebuilds the menu
    -- rows, so it is done only when the mode actually CHANGED -- a refresh runs
    -- on every nudge and a rebuild per keypress would be pure churn.
    local mode = specModeOf(el)
    if ui.specMode ~= mode then
        ui.specMode = mode
        ui.edgeLabel:SetText(mode == "point" and L["Point"] or L["Edge"])
        ui.alignLabel:SetText(mode == "point" and L["Rel point"] or L["Align"])
        ui.edgeDrop:RebuildOptions(ui.specOptions[mode][1])
        ui.alignDrop:RebuildOptions(ui.specOptions[mode][2])
    else
        ui.edgeDrop:UpdateText(); ui.alignDrop:UpdateText()
    end

    -- Grey-when-disabled: a free element has no seat and no backup to set, but
    -- the PRIMARY handle stays live -- dragging it is the way in.
    local anchored = a ~= nil
    setRowEnabled(ui.backupRow, anchored)
    ui.edgeDrop:SetEnabled(anchored); ui.alignDrop:SetEnabled(anchored)
    ui.edgeLabel:SetAlpha(anchored and 1 or DISABLED_ALPHA)
    ui.alignLabel:SetAlpha(anchored and 1 or DISABLED_ALPHA)

    local blockH = layoutAnchorBlock(ui)

    layoutXY(ui)
    ui.xBox:Refresh(); ui.yBox:Refresh()

    -- Copy-to-twin row: shown only while the twin is actually registered (a
    -- pinned set's opposite-mode twin can be missing).
    local twin = el.twin and Registry:Get(el.twin) or nil
    local restH
    if twin then
        ui.btnCopy:SetText(format(L["Copy to %s"], twin.title))
        ui.btnCopy:Show()
        restH = ui.restFullH
    else
        ui.btnCopy:Hide()
        restH = ui.restBaseH
    end
    ui.rest:SetHeight(restH)
    ui.body:SetHeight(blockH + restH)
    po.content:SetHeight(top + blockH + restH)
    po:Resize()
end

-- ============================================================
-- DOCK SIDE
-- The shell picks a side from what FITS; it has no idea what else is on screen.
-- The mover does, so it computes the side itself and forces it -- least-covering
-- against the other proxies and the legend strip.
-- ============================================================
local function rectOf(fr)
    local cx, cy = fr:GetCenter()
    if not cx then return nil end
    local ux, uy = UIParent:GetCenter()
    return { x = cx - ux, y = cy - uy, w = fr:GetWidth() or 0, h = fr:GetHeight() or 0 }
end

local function autoSide(po, proxy)
    local pr = rectOf(proxy)
    if not pr then return nil end
    local obstacles = {}
    for _, b in pairs(Proxy.proxies) do
        if b ~= proxy and b:IsShown() then
            local r = rectOf(b)
            if r then obstacles[#obstacles + 1] = r end
        end
    end
    if Proxy.legend and Proxy.legend:IsShown() then
        local r = rectOf(Proxy.legend)
        if r then obstacles[#obstacles + 1] = r end
    end
    return Solver.BestDockSide(pr, W, po.frame:GetHeight() or 0, DOCK_GAP, obstacles,
        UIParent:GetWidth(), UIParent:GetHeight())
end

local function dockSide(po, proxy)
    local side = NS.db.panelSide
    if side == "left" or side == "right" then return side end
    side = autoSide(po, proxy)
    if not side then
        -- Nothing fits: the old edge flip, and the shell clamps the overhang.
        side = ((proxy:GetRight() or 0) + DOCK_GAP + W > (UIParent:GetRight() or 0)) and "left" or "right"
    end
    return side
end

-- ============================================================
-- INSTANCES
-- ============================================================

-- The cross, the pool sweep and a family eviction all land here; the shell
-- reports WHY and this decides what it meant.
function Pn:OnClose(po, reason)
    for i = #self.live, 1, -1 do
        if self.live[i] == po then tremove(self.live, i) end
    end
    local wasFollowing = (self.following == po)
    if wasFollowing then self.following = nil end
    -- Crossing the FOLLOWING panel is "I am done with this one": the selection
    -- goes with it. Crossing a pinned panel closes only that panel -- it was
    -- never the selection to begin with.
    if reason == "cross" and wasFollowing and Sess.selected then
        Sess:Select(nil)
    end
    -- A closed pinned panel's slab must drop its pin marker; Highlight repaints
    -- every slab from the current selection, which is what the marker reads off.
    Proxy:Highlight(Sess.selected)
end

-- Does a live panel hold this element pinned open? The slab's resting look asks
-- per repaint (Proxy's applyLook). Family exclusivity means the list is at most
-- one long, and it is still a walk rather than a cached field because there is
-- then no index to keep honest.
function Pn:IsElementPinned(id)
    if not id then return false end
    for _, po in ipairs(self.live) do
        if not po.closed and po.elId == id and po:IsPinned() then return true end
    end
    return false
end

function Pn:Create()
    local po = UI:CreatePopout({
        key = POPOUT_KEY,
        -- The exclusivity claim: opening this closes any panel already up, and
        -- a pinned one is no exception. See the header.
        family = POPOUT_KEY,
        pinnable = true,
        parent = Proxy:GetUnlockFrame(),   -- combat suspend hides the lot for free
        width = CW,
        build = buildPanel,
        canAutoPin = function() return NS.db.autoPinPanels end,
        -- The beam's far end is this panel's OWN mover, which after a pin is not
        -- what it is docked to (it is docked to nothing) and not the selection.
        tetherSource = function(p) return p.elId and Proxy.proxies[p.elId] or nil end,
        onClose = function(p, reason) Pn:OnClose(p, reason) end,
        onPin = function(p)
            -- ☠ Stop counting it as the follower NOW, not at the next Refresh.
            -- Between a hand pin and whatever refreshes next, a stale
            -- `following` makes OnClose read the cross as "done with the
            -- selection" (and clear it), and makes HideFollowing take the
            -- pinned panel down for a drag it is not attached to.
            if Pn.following == p then Pn.following = nil end
            -- Pinning changes what a slab looks like at rest (the pin marker),
            -- and nothing else repaints on it: auto-pin fires from a control the
            -- user touched, not from a selection change.
            Proxy:Highlight(Sess.selected)
        end,
    })
    local found = false
    for _, other in ipairs(self.live) do if other == po then found = true end end
    if not found then self.live[#self.live + 1] = po end
    return po
end

-- Instant hide of one panel, animations cancelled.
local function hideInstance(po)
    if not po then return end
    NS.Fx.Cancel(po.frame)
    po.frame:Hide()
    -- The tether beam and the source outline are not children of the popout's
    -- frame, so hiding it does not take them; the shell's own instant path does.
    po:HideChrome()
end

-- Instant hide of every live panel: combat suspend and session teardown, both of
-- which take the whole session off screen. The instances survive -- the next
-- Refresh shows them again -- because neither is the user closing anything.
function Pn:Hide()
    for _, po in ipairs(self.live) do hideInstance(po) end
end

-- Just the follower: a drag is starting, and the following panel is docked to
-- the slab that is about to move. A PINNED panel sits at its own screen position
-- and has no reason to go anywhere, so it stays up for the drag -- which is why
-- this is not simply Hide().
function Pn:HideFollowing()
    hideInstance(self.following)
end

-- Session over: the panels go with it, pinned ones included. The unpinned one
-- returns to the pool, so the next session revives it rather than rebuilding.
function Pn:CloseAll()
    local list = {}
    for i, po in ipairs(self.live) do list[i] = po end
    self.following = nil
    for _, po in ipairs(list) do
        po:Close("api")
        hideInstance(po)
    end
    wipe(self.live)
end

-- Retarget and re-render EVERY live panel, then re-dock the one that follows.
-- Called on every mutation, on every rebuild and on every selection change.
function Pn:Refresh()
    if not Sess:IsActive() then self:CloseAll() return end
    if Sess:IsSuspended() then self:Hide() return end

    -- A pinned panel outlives the selection, not the session: once its element
    -- is gone from the registry or has no proxy left, it is a panel about
    -- nothing.
    for i = #self.live, 1, -1 do
        local po = self.live[i]
        if po.closed then
            tremove(self.live, i)
        elseif po:IsPinned() and not (po.elId and Registry:Get(po.elId) and Proxy.proxies[po.elId]) then
            po:Close("api")
        end
    end

    local el = Sess.selected and Registry:Get(Sess.selected) or nil
    local proxy = el and Proxy.proxies[el.id] or nil

    local fo = self.following
    -- Auto-pinning promotes the follower out of the pool; from that moment it is
    -- just another pinned panel and the next selection gets a fresh one.
    if fo and (fo.closed or fo:IsPinned()) then fo = nil; self.following = nil end

    local want = (el and proxy and proxy:IsShown()) and true or false
    -- ...unless the panel already up is a pinned one on THIS VERY element.
    --
    -- ☠ LOAD-BEARING FOR AUTO-PIN, not a nicety. Pinning clears `following`, so
    -- without this the next mutation -- the very nudge that auto-pinned it --
    -- would open a fresh follower for the still-selected element, and the family
    -- sweep would close the panel that had just been pinned.
    if want then
        for _, po in ipairs(self.live) do
            if po ~= fo and po.elId == el.id then want = false break end
        end
    end

    if not want then
        if fo then self.following = nil; fo:Close("api") end
        fo = nil
    else
        if not fo then fo = self:Create(); self.following = fo end
        fo.elId, fo.el = el.id, el
    end

    for _, po in ipairs(self.live) do refreshInstance(po) end

    -- The dock side is recomputed here rather than once at open: the least-
    -- covering answer changes as the proxies move.
    if fo and not fo.closed and self.following == fo then
        fo:Follow(proxy, { side = dockSide(fo, proxy) })
    end
    -- A pinned panel that a drag (or a suspend) hid comes back; Follow has
    -- nothing to say for a pinned instance, so the show is ours.
    for _, po in ipairs(self.live) do
        if po ~= self.following and not po.closed and not po.frame:IsShown() then po.frame:Show() end
    end
end

-- Belt and braces on the teardown: Finish hides the panels, then clears the
-- undo stack (which refreshes and finds the session inactive). This is the
-- direct path for it, so a session that ends without an undo stack still starts
-- the next one clean.
if NS.Lib.RegisterCallback then
    NS.Lib.RegisterCallback(Pn, "Locked", function() Pn:CloseAll() end)
end
