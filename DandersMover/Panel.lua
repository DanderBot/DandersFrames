local addonName, NS = ...
-- A copy that lost the LibStub race (a renamed duplicate install) must go
-- fully inert: Core.lua only sets NS.Lib on the winning copy.
if not NS.Lib then return end

-- ============================================================
-- MINI-PANEL
-- Docks beside the selected proxy on whichever side covers the least (auto),
-- or on the side the user pinned. Parented to the unlock frame so combat
-- suspension hides it for free.
--
-- Deliberately NOT a settings window: it holds only what acts on the SELECTED
-- element plus the session verbs. Editor preferences (snapping, grid size)
-- live behind the cog, because a preference you set once does not belong in a
-- panel you read on every drag.
-- ============================================================
local Pn = {}
NS.Panel = Pn

local Registry, Sess, Proxy, Solver, UI, L = NS.Registry, NS.Session, NS.Proxy, NS.Solver, NS.UI, NS.L
local CreateFrame, UIParent, IsShiftKeyDown, IsControlKeyDown = CreateFrame, UIParent, IsShiftKeyDown, IsControlKeyDown
local xpcall, geterrorhandler = xpcall, geterrorhandler
local GetTime, C_Timer = GetTime, C_Timer
local format, tonumber, ipairs, pairs, floor, max, min = string.format, tonumber, ipairs, pairs, math.floor, math.max, math.min

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

-- Spacing comes from the theme so this panel keeps the rhythm of every other
-- DandersUI surface: PAD is the outer padding, GAP the gap between rows of
-- different kinds, TIGHT the gap inside a run of like things (buttons in a
-- row, the two X/Y pairs).
-- 260, not the old 236: the anchor block now carries a label column and a drag
-- handle on the same row as its picker, and at 236 the picker was down to about
-- half the row.
local W = 260
local PAD, GAP, TIGHT = UI.Space.section, UI.RowGap, UI.RowGapTight
local CW = W - PAD * 2            -- content width
local DOCK_GAP = 12               -- panel <-> proxy distance
local ICON = 24                   -- header icon, drawn from the full 64px source
local TITLE_W = CW - (ICON + TIGHT - 2)   -- the title column, right of the icon
local HEADER_LINE = 14            -- fallback line height before the font resolves
local HEADER_BTN_H = 18           -- the Configure / Settings row under the header
local BOX_W = 62                  -- X / Y edit boxes
local NUDGE_CELL, NUDGE_ICON = 22, 14
local DOT, DOT_GAP = 16, 4        -- 9-point picker cells
local BTN_H, CTA_H = 20, 22
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

local function selectedElement()
    return Sess.selected and Registry:Get(Sess.selected) or nil
end

local function step() return Solver.NudgeStep(IsShiftKeyDown(), IsControlKeyDown()) end

-- ============================================================
-- GRAB CURSOR
-- The move cursor while the pointer is over a drag handle: the one affordance
-- that says "this is draggable" before you press anything.
--
-- ☠ SetCursor is SILENT about a path it cannot resolve -- it draws a BLACK
-- SQUARE where the pointer should be rather than erroring -- so a pcall is not
-- a guard against a wrong path, only against a missing API. The path is
-- therefore PROBED first through a throwaway texture: SetTexture answers false
-- for a file that is not in the client, the same idiom Refresh uses to fall
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
        b:SetPoint("TOPLEFT", PAD + (i - 1) * (bw + TIGHT), y)
        out[i] = b
    end
    return out
end

-- ============================================================
-- ANCHOR BLOCK LAYOUT
-- Every row is always there now -- an unanchored element greys the ones it has
-- no answer for rather than dropping them, so the block never changes height
-- and the panel never jumps as you anchor and detach. What IS measured here is
-- the label columns: a FontString reads 0 wide until its font resolves, and the
-- labels also swap with the anchor mode, so the columns are re-measured on every
-- layout rather than fixed at build.
--
-- Returns the height the block consumes, gap to the rows below included -- the
-- same trick layoutHeader plays on f.body.
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

local function layoutAnchorBlock(f)
    labelColumn(f.targetRow.label, f.backupRow.label, LABEL_MIN, LABEL_MAX)
    -- The seat pair sits in half a row each, and its labels swap with the mode
    -- ("Rel point" is twice "Align"), so the column is capped at whatever leaves
    -- the dropdown its own minimum rather than at a fixed number.
    local halfW = floor((ACW - GAP) / 2)
    labelColumn(f.edgeLabel, f.alignLabel, 24, halfW - SPEC_DROP_MIN)

    local contentH = ROW_H + TIGHT + SPEC_H + TIGHT + ROW_H
    f.anchorBox:SetContentHeight(contentH)
    local h = (f.anchorBox:GetHeight() or contentH) + GAP
    f.rest:ClearAllPoints()
    f.rest:SetPoint("TOPLEFT", 0, -h)
    return h
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

local function build()
    local f = CreateFrame("Frame", "DandersMoverPanel", Proxy:GetUnlockFrame(), "BackdropTemplate")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetWidth(W)
    UI:CreatePanelBackdrop(f)
    f:EnableMouse(true)

    -- ---- header row 1: icon | full title over the addon name --------
    -- The title owns the whole content width and may run to two lines, so the
    -- header's height is not known until Refresh has put a title in it.
    -- Everything below lives on f.body, which layoutHeader slides down to
    -- whatever the header measured -- that single anchor is the only thing
    -- that moves, so the body keeps its build-time offsets.
    f.icon = f:CreateTexture(nil, "OVERLAY")
    f.icon:SetSize(ICON, ICON)
    f.icon:SetPoint("TOPLEFT", PAD, -PAD)
    f.title = UI:CreateLabel(f, { size = 12, color = UI.Colors.text, width = TITLE_W })
    -- Two lines is the budget: a title long enough to need a third does not
    -- belong in a 236px panel.
    if f.title.SetMaxLines then f.title:SetMaxLines(2) end
    f.title:SetPoint("TOPLEFT", PAD + ICON + TIGHT - 2, -PAD)
    f.addon = UI:CreateLabel(f, { size = 10, color = UI.Colors.textDim })
    f.addon:SetWidth(TITLE_W)
    f.addon:SetWordWrap(false)
    f.addon:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -1)

    -- ---- header row 2: Configure | Settings -------------------------
    -- Their own row across the content width, so the title above never has to
    -- give up room to them. Configure is the CONSUMER entry point (the
    -- selected element's own options page) and exists only for defs that offer
    -- openSettings; Settings opens the LIB's window, is always there, and
    -- takes the whole row when Configure is hidden (layoutHeader).
    f.btnConfigure = UI:CreateButton(f, {
        text = L["Configure"], height = HEADER_BTN_H, style = "ghost", fitText = false,
        tooltip = { title = L["Configure"], lines = { L["Open this element's own settings."] } },
        onClick = function()
            local el = selectedElement()
            if el and el.openSettings then xpcall(el.openSettings, geterrorhandler()) end
        end,
    })
    f.btnConfigure:Hide()
    f.btnSettings = UI:CreateButton(f, {
        text = L["Settings"], height = HEADER_BTN_H, style = "ghost", fitText = false,
        tooltip = { title = L["Settings"], lines = { L["Snapping, grid and per-addon mover toggles."] } },
        onClick = function() if NS.Settings then NS.Settings:Toggle() end end,
    })

    -- ---- body -------------------------------------------------------
    local body = CreateFrame("Frame", nil, f)
    body:SetWidth(W)
    body:SetPoint("TOPLEFT", 0, 0)          -- layoutHeader re-anchors it
    f.body = body

    -- ---- anchor block ------------------------------------------------
    -- One titled sub-section, three labelled rows: what this element is
    -- anchored TO, how it sits on it, and where it goes when that target is off
    -- screen. Every row is labelled, because three unlabelled dropdowns in a
    -- column tell you nothing about which is which.
    f.anchorBox = UI:CreateGroupBox(body, { title = L["Anchor"], width = CW, padding = ANCHOR_PAD })
    f.anchorBox:SetPoint("TOPLEFT", PAD, 0)
    local ac = f.anchorBox.content

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
            local el = selectedElement()
            if not el then return end
            if button == "LeftButton" then Sess:BeginLink(el, o.mode)
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
    -- what is legal changes with the graph and with what is on screen.
    f.targetRow = pickerRow(ac, {
        label = L["Target"], mode = "primary",
        tooltip = { title = L["Target"],
                    lines = { L["What this element is anchored to. Picking one does not move it."] } },
        handleTooltip = { title = L["Anchor"], lines = { L["Drag onto another mover to attach"] } },
        dropdown = {
            inline = true, searchable = true,
            optionsFunc = function()
                local el = selectedElement()
                return el and NS.Picker:Options(el) or { _order = {} }
            end,
            get = function()
                local el = selectedElement(); if not el then return nil end
                local a = Registry:GetPos(el).anchor
                return a and a.target or nil
            end,
            set = function(targetId)
                local el = selectedElement()
                if el then Sess:AnchorInPlace(el, targetId) end
            end,
        },
    })
    f.targetRow:SetPoint("TOPLEFT", 0, 0)
    -- Refresh owns this caption from here on; set once so the opener never
    -- renders the raw value between build and the Refresh that follows it.
    f.targetRow.picker:SetDisplayOverride(L["None"])

    -- Where the element goes when the primary target is not on screen. Only
    -- meaningful once there IS a primary, so both the picker and its handle go
    -- grey while the element is free.
    f.backupRow = pickerRow(ac, {
        label = L["Backup"], mode = "fallback",
        tooltip = { title = L["Backup"],
                    lines = { L["Where this element goes while the target above is off screen."] } },
        handleTooltip = { title = L["Backup"], lines = { L["Drag onto another mover to set the backup anchor"] } },
        dropdown = {
            inline = true, searchable = true,
            optionsFunc = function()
                local el = selectedElement()
                return el and NS.Picker:Options(el, "fallback") or { _order = {} }
            end,
            get = function()
                local el = selectedElement(); if not el then return NS.Picker.NONE end
                local a = Registry:GetPos(el).anchor
                return a and a.fallback and a.fallback.target or NS.Picker.NONE
            end,
            set = function(targetId)
                local el = selectedElement(); if not el then return end
                if targetId == NS.Picker.NONE then Sess:ClearFallback(el) else Sess:SetFallback(el, targetId) end
            end,
        },
    })
    f.backupRow:SetPoint("TOPLEFT", 0, -(ROW_H + TIGHT + SPEC_H + TIGHT))
    f.backupRow.picker:SetDisplayOverride(L["None"])

    -- ---- the seat: edge/align, or point/relPoint ---------------------
    -- One pair of dropdowns whose SUBJECT follows the anchor's mode, because the
    -- two modes describe a seat with different fields and only one of them is
    -- ever live. Refresh swaps both the labels and the option sets (specMode).
    f.specRow = CreateFrame("Frame", nil, ac)
    f.specRow:SetSize(ACW, SPEC_H)
    f.specRow:SetPoint("TOPLEFT", 0, -(ROW_H + TIGHT))
    local halfW = floor((ACW - GAP) / 2)
    -- Which of the anchor block's two fields a dropdown edits, per mode. The
    -- pair is positional -- left dropdown, right dropdown -- and the mode
    -- decides what each one means.
    local SPEC_KEYS = { outside = { "edge", "align" }, point = { "point", "relPoint" } }
    local SPEC_FALLBACK = { edge = "right", align = "center", point = "CENTER", relPoint = "CENTER" }
    -- The 9 anchor points are API identifiers, not prose -- they read the same
    -- in every locale and the panel already spells them out raw elsewhere, so
    -- the same table serves both point-mode slots.
    local POINT_OPTS = { _order = POINTS }
    for _, p in ipairs(POINTS) do POINT_OPTS[p] = p end
    f.specOptions = {
        outside = {
            { _order = { "right", "left", "top", "bottom" },
              right = L["Right"], left = L["Left"], top = L["Top"], bottom = L["Bottom"] },
            { _order = { "start", "center", "end" },
              start = L["Start"], center = L["Center"], ["end"] = L["End"] },
        },
        point = { POINT_OPTS, POINT_OPTS },
    }
    local function specMode()
        local el = selectedElement(); if not el then return "outside" end
        local a = Registry:GetPos(el).anchor
        return (a and a.mode == "point") and "point" or "outside"
    end
    local function specDrop(slot)
        local drop = UI:CreateDropdown(f.specRow, {
            inline = true, options = f.specOptions.outside[slot],
            get = function()
                local key = SPEC_KEYS[specMode()][slot]
                local el = selectedElement(); if not el then return SPEC_FALLBACK[key] end
                local a = Registry:GetPos(el).anchor
                return (a and a[key]) or SPEC_FALLBACK[key]
            end,
            set = function(v)
                local el = selectedElement(); if not el then return end
                Sess:SetAnchorSpec(el, { [SPEC_KEYS[specMode()][slot]] = v })
            end,
        })
        drop:SetHeight(SPEC_H)
        return drop
    end
    f.edgeLabel = UI:CreateLabel(f.specRow, { text = L["Edge"], size = 10, color = UI.Colors.textDim })
    f.edgeLabel:SetWordWrap(false)
    f.edgeLabel:SetPoint("LEFT", 0, 0)
    f.edgeDrop = specDrop(1)
    f.edgeDrop:SetPoint("LEFT", f.edgeLabel, "RIGHT", TIGHT, 0)
    f.edgeDrop:SetPoint("RIGHT", f.specRow, "LEFT", halfW, 0)
    f.alignLabel = UI:CreateLabel(f.specRow, { text = L["Align"], size = 10, color = UI.Colors.textDim })
    f.alignLabel:SetWordWrap(false)
    f.alignLabel:SetPoint("LEFT", f.specRow, "LEFT", halfW + GAP, 0)
    f.alignDrop = specDrop(2)
    f.alignDrop:SetPoint("LEFT", f.alignLabel, "RIGHT", TIGHT, 0)
    f.alignDrop:SetPoint("RIGHT", f.specRow, "RIGHT", 0, 0)
    f.specMode = "outside"

    -- ---- everything below the anchor block ---------------------------
    -- Its own frame so the block above can sit at whatever height the group box
    -- measures: these rows keep their build-time offsets and only f.rest's
    -- single anchor moves.
    local rest = CreateFrame("Frame", nil, body)
    rest:SetWidth(W)
    rest:SetPoint("TOPLEFT", 0, 0)          -- layoutAnchorBlock re-anchors it
    f.rest = rest

    local y = 0
    -- Reserve a row of height h and return its top; gap is the space to leave below it.
    local function row(h, gap) local cur = y; y = y - h - (gap or GAP); return cur end

    -- ---- X / Y: two label+box pairs centred as one group ------------
    -- The pairs live in a container whose width is recomputed on Refresh
    -- (the labels change between "X" and "Offset X"), and the container is
    -- centred in the panel, so the group stays centred whatever the labels say.
    local ry = row(20)
    f.xyRow = CreateFrame("Frame", nil, rest)
    f.xyRow:SetSize(CW, 20)
    f.xyRow:SetPoint("TOP", rest, "TOP", 0, ry)
    f.xLabel = UI:CreateLabel(f.xyRow, { text = L["X"], size = 11, justify = "RIGHT" })
    f.xLabel:SetPoint("LEFT", 0, 0)
    f.xBox = UI:CreateEditBox(f.xyRow, {
        width = BOX_W, numeric = true,
        get = function()
            local el = selectedElement(); if not el then return 0 end
            local pos = Registry:GetPos(el)
            return pos.anchor and (pos.anchor.offsetX or 0) or floor((pos.x or 0) + 0.5)
        end,
        onCommit = function(v)
            local el = selectedElement()
            if el then Sess:SetXY(el, v, tonumber(f.yBox:GetText()) or 0) end
        end,
    })
    f.xBox:SetPoint("LEFT", f.xLabel, "RIGHT", TIGHT - 2, 0)
    f.yLabel = UI:CreateLabel(f.xyRow, { text = L["Y"], size = 11, justify = "RIGHT" })
    f.yLabel:SetPoint("LEFT", f.xBox, "RIGHT", GAP, 0)
    f.yBox = UI:CreateEditBox(f.xyRow, {
        width = BOX_W, numeric = true,
        get = function()
            local el = selectedElement(); if not el then return 0 end
            local pos = Registry:GetPos(el)
            return pos.anchor and (pos.anchor.offsetY or 0) or floor((pos.y or 0) + 0.5)
        end,
        onCommit = function(v)
            local el = selectedElement()
            if el then Sess:SetXY(el, tonumber(f.xBox:GetText()) or 0, v) end
        end,
    })
    f.yBox:SetPoint("LEFT", f.yLabel, "RIGHT", TIGHT - 2, 0)

    -- ---- nudge cluster | 9-point picker: two equal halves ------------
    -- Each cluster sits in its own container, centred in its half of the
    -- content width and on the same vertical centre.
    local clusterH = max(NUDGE_CELL * 3, DOT * 3 + DOT_GAP * 2)
    local ny = row(clusterH)
    local half = CW / 2

    f.nudge = CreateFrame("Frame", nil, rest)
    f.nudge:SetSize(NUDGE_CELL * 3, NUDGE_CELL * 3)
    f.nudge:SetPoint("CENTER", rest, "TOPLEFT", PAD + half / 2, ny - clusterH / 2)
    local ARROWS = {   -- icon, dx, dy, column, row (0-based in the 3x3 cluster)
        { "expand_less",   0,  1, 1, 0 },
        { "chevron_left", -1,  0, 0, 1 },
        { "chevron_right", 1,  0, 2, 1 },
        { "expand_more",   0, -1, 1, 2 },
    }
    for _, a in ipairs(ARROWS) do
        local icon, dx, dy, col, rowi = a[1], a[2], a[3], a[4], a[5]
        local b = UI:CreateGlyphButton(f.nudge, {
            texture = UI.MEDIA .. "Icons\\" .. icon, size = NUDGE_CELL, iconSize = NUDGE_ICON,
            onClick = function()
                local el = selectedElement()
                if el then Sess:Nudge(el, dx * step(), dy * step()) end
            end,
            tooltip = { title = L["Nudge"], lines = { L["Hold Shift for 10 units, Ctrl for 100."] } },
        })
        b:SetPoint("TOPLEFT", col * NUDGE_CELL, -rowi * NUDGE_CELL)
    end

    f.picker = CreateFrame("Frame", nil, rest)
    f.picker:SetSize(DOT * 3 + DOT_GAP * 2, DOT * 3 + DOT_GAP * 2)
    f.picker:SetPoint("CENTER", rest, "TOPLEFT", PAD + half + half / 2, ny - clusterH / 2)
    f.points = {}
    for i, point in ipairs(POINTS) do
        local col, rowi = (i - 1) % 3, floor((i - 1) / 3)
        local b = UI:CreateButton(f.picker, {
            width = DOT, height = DOT,
            onClick = function()
                local el = selectedElement()
                if el then Sess:SetAnchorPoint(el, point) end
            end,
            tooltip = point,
        })
        b:SetPoint("TOPLEFT", col * (DOT + DOT_GAP), -rowi * (DOT + DOT_GAP))
        b.point = point
        f.points[i] = b
    end

    -- ---- actions -------------------------------------------------
    local acts = buttonRow(rest, row(BTN_H, TIGHT), BTN_H, {
        { text = L["Center"], onClick = function() local el = selectedElement(); if el then Sess:Center(el) end end },
        { text = L["Reset"],  onClick = function() local el = selectedElement(); if el then Sess:Reset(el) end end },
        { text = L["Detach"], onClick = function() local el = selectedElement(); if el then Sess:Detach(el) end end },
    })
    f.btnCenter, f.btnReset, f.btnDetach = acts[1], acts[2], acts[3]

    local hist = buttonRow(rest, row(BTN_H), BTN_H, {
        { text = L["Undo"], onClick = function() Sess:Undo() end },
        { text = L["Redo"], onClick = function() Sess:Redo() end },
    })
    f.btnUndo, f.btnRedo = hist[1], hist[2]

    local fin = buttonRow(rest, row(CTA_H), CTA_H, {
        { text = L["Save & Exit"], style = "primary", onClick = function() Sess:Finish("save") end },
        { text = L["Discard"], tone = "danger", onClick = function() Sess:Finish("discard") end },
    })
    f.btnSave, f.btnDiscard = fin[1], fin[2]

    -- Copy-to-twin: full-width bottom row, only for elements whose def names a
    -- twin (Refresh shows it and grows the panel by the row).
    -- ☠ `text = ""`, not omitted. The label is only knowable in Refresh (it
    -- names the twin), but UI:StyleButton creates the button's FontString --
    -- and registers it via SetFontString, which is what makes the NATIVE
    -- Button:SetText work -- ONLY when `text` is passed. Omit it and the
    -- button has no font string at all, so Refresh's SetText below silently
    -- no-ops and the row renders blank. An empty string is enough to get the
    -- font string built; `fitText = false` keeps it from resizing off it.
    f.btnCopy = UI:CreateButton(rest, {
        text = "", width = CW, height = BTN_H, fitText = false,
        onClick = function() local el = selectedElement(); if el then Sess:CopyToTwin(el) end end,
    })
    f.btnCopy:SetPoint("TOPLEFT", PAD, row(BTN_H, 0))
    f.btnCopy:Hide()

    -- Heights of the rows BELOW the anchor block, with and without the copy row.
    -- The block adds its own on top (layoutAnchorBlock) and the header its own
    -- above that (layoutHeader), so the panel's total is settled in Refresh.
    f.restFullH = -y
    f.restBaseH = f.restFullH - BTN_H - GAP
    rest:SetHeight(f.restBaseH)
    local blockH = layoutAnchorBlock(f)
    body:SetHeight(blockH + f.restBaseH)
    f:SetHeight(PAD + ICON + TIGHT + HEADER_BTN_H + GAP + blockH + f.restBaseH + PAD)
    f:Hide()
    return f
end

-- ============================================================
-- HEADER LAYOUT
-- The title wraps, so the header's height -- and therefore the body's top and
-- the panel's own height -- is only knowable once the title is in. Returns the
-- height consumed above the body, and whether the font had resolved (a
-- FontString measures 0 until it has, and Refresh retries once if so).
-- ============================================================
local function layoutHeader(f, canConfigure)
    local th, ah = f.title:GetStringHeight() or 0, f.addon:GetStringHeight() or 0
    local resolved = th > 0
    if th <= 0 then th = HEADER_LINE end
    if ah <= 0 then ah = HEADER_LINE - 2 end
    local textH = th + 1 + ah
    local hh = max(ICON, textH)
    -- Whichever of the icon and the text block is shorter centres against the
    -- other, so a one-line title still sits level with the icon and a two-line
    -- one does not push the icon off the top.
    f.icon:ClearAllPoints()
    f.icon:SetPoint("TOPLEFT", PAD, -PAD - (hh - ICON) / 2)
    f.title:ClearAllPoints()
    f.title:SetPoint("TOPLEFT", PAD + ICON + TIGHT - 2, -PAD - (hh - textH) / 2)

    local by = -PAD - hh - TIGHT
    f.btnConfigure:ClearAllPoints()
    f.btnSettings:ClearAllPoints()
    if canConfigure then
        local bw = floor((CW - TIGHT) / 2)
        f.btnConfigure:SetWidth(bw)
        f.btnSettings:SetWidth(bw)
        f.btnConfigure:SetPoint("TOPLEFT", PAD, by)
        f.btnSettings:SetPoint("TOPLEFT", PAD + bw + TIGHT, by)
    else
        f.btnSettings:SetWidth(CW)
        f.btnSettings:SetPoint("TOPLEFT", PAD, by)
    end
    f.body:ClearAllPoints()
    f.body:SetPoint("TOPLEFT", 0, by - HEADER_BTN_H - GAP)
    return PAD + hh + TIGHT + HEADER_BTN_H + GAP, resolved
end

-- Size the X/Y group to its current labels so it stays centred. Both labels
-- take the wider of the two, so the pairs mirror each other; the boxes give up
-- width when the labels are long ("Offset X") so the group never overflows.
local function layoutXY(f)
    local lw = max(f.xLabel:GetStringWidth() or 0, f.yLabel:GetStringWidth() or 0)
    f.xLabel:SetWidth(lw); f.yLabel:SetWidth(lw)
    local pair = lw + TIGHT - 2
    local bw = max(40, floor(min(BOX_W, (CW - GAP) / 2 - pair)))
    f.xBox:SetWidth(bw); f.yBox:SetWidth(bw)
    f.xyRow:SetWidth((pair + bw) * 2 + GAP)
end

function Pn:Ensure()
    if not self.frame then self.frame = build() end
    return self.frame
end

-- Instant hide: combat suspend, session teardown, selection loss mid-refresh.
-- Cancels any running fade so a stale "hide when done" cannot land later.
function Pn:Hide()
    self.holdUntil = nil          -- a hidden panel has nothing to hold in place
    self.dockedTo = nil
    self.dockSide = nil
    if self.frame then
        NS.Fx.Cancel(self.frame)
        self.frame:Hide()
    end
end

-- The entrance drift and scale origin for a dock side: the panel pops out of
-- (and back into) the proxy edge it is docked against. Shared by Dock and
-- FadeOut so the exit is the entrance run backwards.
local function dockFx(side)
    if side == "right" then return -8, 0, "LEFT"
    elseif side == "left" then return 8, 0, "RIGHT"
    elseif side == "below" then return 0, 8, "TOP"
    elseif side == "above" then return 0, -8, "BOTTOM" end
    return 0, 0, "CENTER"
end

-- Deselection: the entrance in reverse -- shrink back toward the docked proxy
-- edge while fading (PopOut, 0.18s), then hide. Suspend never comes through
-- here; it takes the instant Hide above.
function Pn:FadeOut()
    self.holdUntil = nil
    self.dockedTo = nil
    local side = self.dockSide
    self.dockSide = nil
    local f = self.frame
    if not f or not f:IsShown() then return end
    local ox, oy, origin = dockFx(side)
    NS.Fx.PopOut(f, 0.18, ox, oy, 0.92, origin, function() f:Hide() end)
end

-- ============================================================
-- NUDGE HOLD
-- Re-docking on every keypress makes the panel chase the frame around, so a
-- nudge parks it: each nudge pushes the deadline out, and one C_Timer chain
-- re-docks once after the LAST nudge's hold expires. Session:Select clears the
-- hold, so an explicit selection always docks immediately.
-- ============================================================
local HOLD = 2

function Pn:HoldDock()
    self.holdUntil = GetTime() + HOLD
    if self.holdTimerArmed then return end
    self.holdTimerArmed = true
    local function tick()
        if not self.holdUntil then self.holdTimerArmed = false return end
        local left = self.holdUntil - GetTime()
        if left > 0 then
            C_Timer.After(left, tick)
        else
            self.holdTimerArmed = false
            self.holdUntil = nil
            if Sess:IsActive() and not Sess:IsSuspended() then self:Dock() end
        end
    end
    C_Timer.After(HOLD, tick)
end

function Pn:ClearHold() self.holdUntil = nil end

-- Rect of a frame in UIParent-centre units; nil while it has no geometry yet.
local function rectOf(fr)
    local cx, cy = fr:GetCenter()
    if not cx then return nil end
    local ux, uy = UIParent:GetCenter()
    return { x = cx - ux, y = cy - uy, w = fr:GetWidth() or 0, h = fr:GetHeight() or 0 }
end

-- "auto": the candidate beside the proxy that covers the least, scored against
-- every OTHER visible proxy and the legend (Solver.BestDockSide). nil when no
-- candidate fits fully on screen.
local function autoSide(f, proxy)
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
    return Solver.BestDockSide(pr, W, f:GetHeight() or 0, DOCK_GAP, obstacles,
        UIParent:GetWidth(), UIParent:GetHeight())
end

function Pn:Dock()
    local f = self.frame
    local proxy = Sess.selected and Proxy.proxies[Sess.selected]
    if not f or not proxy or not proxy:IsShown() then self:Hide() return end
    -- Parked by a nudge: keep the panel where it is until the hold expires.
    if self.holdUntil then
        if GetTime() < self.holdUntil then return end
        self.holdUntil = nil
    end
    local side = NS.db.panelSide
    if side == "auto" then
        -- Least-covering side; when nothing fits on screen, the old edge flip.
        side = autoSide(f, proxy)
        if not side then
            side = ((proxy:GetRight() or 0) + DOCK_GAP + W > (UIParent:GetRight() or 0)) and "left" or "right"
        end
    end
    f:ClearAllPoints()
    if side == "left" then f:SetPoint("TOPRIGHT", proxy, "TOPLEFT", -DOCK_GAP, 0)
    elseif side == "below" then f:SetPoint("TOP", proxy, "BOTTOM", 0, -DOCK_GAP)
    elseif side == "above" then f:SetPoint("BOTTOM", proxy, "TOP", 0, DOCK_GAP)
    else f:SetPoint("TOPLEFT", proxy, "TOPRIGHT", DOCK_GAP, 0) end

    -- Entrance: pop from behind the proxy -- scale up from 0.92 with the scale
    -- originating at the docked edge, sliding from the proxy's side onto the
    -- anchor, ease-out (Fx.PopIn). Target changed while the panel was already
    -- up: a quick fade-swap, no pop. Same target: nothing -- Dock runs on
    -- every Refresh and must not flicker the panel.
    local wasShown = f:IsShown()
    if not wasShown then
        local ox, oy, origin = dockFx(side)
        NS.Fx.PopIn(f, 0.22, ox, oy, 0.92, origin)
    elseif self.dockedTo ~= Sess.selected then
        NS.Fx.FadeIn(f, 0.08)
    end
    self.dockedTo = Sess.selected
    self.dockSide = side          -- FadeOut retraces this edge on deselect
    f:Show()
end

function Pn:Refresh()
    if not Sess:IsActive() or Sess:IsSuspended() then self:Hide() return end
    local el = selectedElement()
    if not el then self:FadeOut() return end
    local f = self:Ensure()
    local pos = Registry:GetPos(el)

    f.title:SetText(el.title)
    local addon = Registry:GetAddon(el.addon)
    local icon = addon and addon.icon or (UI.MEDIA .. "DF_Icon")
    if f.icon:SetTexture(icon) == false then f.icon:SetTexture(UI.MEDIA .. "DF_Icon") end
    f.addon:SetText(addon and addon.title or el.addon)
    -- Configure only exists for elements whose def offers openSettings; without
    -- it Settings takes the whole button row.
    local canConfigure = el.openSettings ~= nil
    f.btnConfigure:SetShown(canConfigure)
    local headerH, resolved = layoutHeader(f, canConfigure)
    -- A FontString measures 0 until its font object resolves, which on the very
    -- first Refresh would size a wrapped two-line title as one. One deferred
    -- retry, flagged so repeated Refreshes cannot stack timers.
    if not resolved and not f.headerRetry and C_Timer then
        f.headerRetry = true
        C_Timer.After(0, function() f.headerRetry = nil; Pn:Refresh() end)
    end

    local a = pos.anchor
    if a then
        -- Name whichever block is actually driving the element: the backup
        -- taking over is the one thing the panel must not stay quiet about, and
        -- naming the primary's target while the backup holds it would be a lie.
        -- Just the NAME now -- the seat has its own labelled row underneath, so
        -- the old "(right/center)" tail is said twice over.
        local active = Registry:ActiveAnchor(el)
        local blk = active or a
        local target = Registry:GetTarget(blk.target)
        local text = target and target.title or L["(unavailable)"]
        if active ~= nil and active == a.fallback then text = L["(backup)"] .. " " .. text end
        f.targetRow.picker:SetDisplayOverride(text)
        f.xLabel:SetText(L["Offset X"]); f.yLabel:SetText(L["Offset Y"])
        f.btnDetach:SetEnabled(true)
        for _, b in ipairs(f.points) do b:Hide() end
    else
        f.targetRow.picker:SetDisplayOverride(L["None"])
        f.xLabel:SetText(L["X"]); f.yLabel:SetText(L["Y"])
        f.btnDetach:SetEnabled(false)
        local cur = pos.point or "CENTER"
        for _, b in ipairs(f.points) do
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
    f.backupRow.picker:SetDisplayOverride(ftext)

    -- The seat pair follows the mode. Swapping the option set rebuilds the menu
    -- rows, so it is done only when the mode actually CHANGED -- Refresh runs on
    -- every nudge and a rebuild per keypress would be pure churn.
    local mode = (a and a.mode == "point") and "point" or "outside"
    if f.specMode ~= mode then
        f.specMode = mode
        f.edgeLabel:SetText(mode == "point" and L["Point"] or L["Edge"])
        f.alignLabel:SetText(mode == "point" and L["Rel point"] or L["Align"])
        f.edgeDrop:RebuildOptions(f.specOptions[mode][1])
        f.alignDrop:RebuildOptions(f.specOptions[mode][2])
    else
        f.edgeDrop:UpdateText(); f.alignDrop:UpdateText()
    end

    -- Grey-when-disabled: a free element has no seat and no backup to set, but
    -- the PRIMARY handle stays live -- dragging it is the way in.
    local anchored = a ~= nil
    setRowEnabled(f.backupRow, anchored)
    f.edgeDrop:SetEnabled(anchored); f.alignDrop:SetEnabled(anchored)
    f.edgeLabel:SetAlpha(anchored and 1 or DISABLED_ALPHA)
    f.alignLabel:SetAlpha(anchored and 1 or DISABLED_ALPHA)

    local blockH = layoutAnchorBlock(f)

    layoutXY(f)
    f.xBox:Refresh(); f.yBox:Refresh()

    f.btnUndo:SetEnabled(Sess.undo and Sess.undo:CanUndo() or false)
    f.btnRedo:SetEnabled(Sess.undo and Sess.undo:CanRedo() or false)

    -- Copy-to-twin row: shown only while the twin is actually registered (a
    -- pinned set's opposite-mode twin can be missing).
    local twin = el.twin and Registry:Get(el.twin) or nil
    local restH
    if twin then
        f.btnCopy:SetText(format(L["Copy to %s"], twin.title))
        f.btnCopy:Show()
        restH = f.restFullH
    else
        f.btnCopy:Hide()
        restH = f.restBaseH
    end
    f.rest:SetHeight(restH)
    f.body:SetHeight(blockH + restH)
    f:SetHeight(headerH + blockH + restH + PAD)
    self:Dock()
end
