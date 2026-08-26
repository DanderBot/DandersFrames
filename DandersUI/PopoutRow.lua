local addonName, NS = ...
local UI = NS.__DandersUI
if not UI then return end

-- ============================================================
-- POPOUT ROW -- a settings row that hands its controls to a popout.
--
-- A feature with fifteen controls does not want fifteen rows on the page. It
-- wants ONE row that says what the feature is and what it is currently set to,
-- and a way in. That is this: toggle, name, live summary, count, chevron -- and
-- the whole row opens a popout carrying the group's real controls.
--
-- ☠ ONE PANEL ACROSS EVERY ROW OF A HOST. All rows share ONE popout key, so
-- clicking row B while row A's unpinned popout is up hands back the SAME pooled
-- instance and the shell GLIDES it across (see Popout.lua's retarget glide).
-- That is the whole reason the row is worth having: a column of these reads as
-- one inspector that follows the row you picked, not as a litter of boxes.
--
-- Which forces the content model. The shell runs `build` ONCE PER INSTANCE, so
-- this file's own build mounts nothing but a bare container, and each ROW's
-- content is a pane built into that container the first time that row is opened
-- on that instance. Swapping rows hides one pane and shows another. The cache is
-- therefore keyed by INSTANCE first (it lives on the popout, so it dies with it)
-- and by row second -- a pinned instance keeps the panes it built, and the next
-- row click gets a fresh instance with an empty cache.
--
-- ☠ SHADOW HAZARD -- ALWAYS CALL THE *Native FACTORY NAMES FROM THIS FILE, for
-- exactly the reason Sections.lua spells out at its head: a consumer may define
-- POSITIONAL CreateSlider / CreateDropdown / CreateAnchorGrid / CreateCheckbox /
-- CreateEditBox / CreateButton / CreateLabel on its own host, which shadows the
-- pack's native factories for that consumer only. Those seven go through the
-- *Native alias; everything else here (StyleCheckButton, CreatePopout,
-- CreateElementBackdrop) has no shadowable twin and is called by its plain name.
-- CreateElementBackdrop is reached as a HOST method rather than through
-- UI._priv the way Sections.lua takes it, matching Popout.lua's own
-- host:CreatePanelBackdrop -- one convention across the popout family.
--
-- Canonical source lives at <repo>/DandersUI; never edit the copies under
-- */Libs/.
-- ============================================================
local CreateFrame, UIParent = CreateFrame, UIParent
local rawget, rawset, type, pairs, ipairs = rawget, rawset, type, pairs, ipairs
local xpcall, geterrorhandler, tostring = xpcall, geterrorhandler, tostring
local format = string.format
local tremove = table.remove
local max = math.max

local C_TEXT, C_TEXT_DIM = UI.Colors.text, UI.Colors.textDim
local C_ELEMENT, C_BORDER = UI.Colors.element, UI.Colors.border
local C_HOVER, C_BACKGROUND = UI.Colors.hover, UI.Colors.background
local ICON_PATH = UI.MEDIA .. "Icons\\"

-- EVERY metric this file draws with lives in Theme.lua (UI.PopoutRow), for the
-- reason the row heights do: a widget whose numbers are file-locals can only be
-- retuned by editing the widget, and a look retuned that way drifts from the one
-- everything else was tuned against. See that table for what each value is and
-- why -- including why the row no longer takes a checkbox's slot.
local M = UI.PopoutRow

-- The slot, and the visible PLATE inside it. M.gap of the slot is the gap BELOW
-- the row and nothing is painted there, so everything the row draws is anchored
-- inside the plate.
local ROW_H   = M.slot
local PLATE_H = M.plate

-- ⚠ NO rowKind. rowKind drives UI.RowCompact's run-tightening, and a value that
-- is not IN RowCompact silently BREAKS a run of checkboxes it sits between --
-- the same trap the removed `toggle` entry was. A row with no kind at all is
-- laid out at whatever its own slot says, and this row's slot already carries
-- the gap it wants below it (M.gap), so there is nothing for RowCompact to do.

-- Greyed like every other widget's SetEnabled: 0.4 on the whole thing.
local DIM_ALPHA = 0.4
-- Toggled OFF is a softer statement than disabled -- the row is still yours to
-- click, it just has nothing to report -- so the glyphs half-fade and the text
-- goes dim rather than the whole row dropping to 0.4.
local OFF_ALPHA = 0.5

-- The height ceiling, as a fraction of the screen. A group with thirty controls
-- would otherwise open a popout taller than the monitor, and a panel whose top
-- and bottom are both off-screen cannot be read OR dismissed.
local CAP_FRAC = 0.6

-- One key per host by default, which is what makes the single-panel behaviour
-- above the DEFAULT rather than something every call site has to remember.
local DEFAULT_KEY = "DandersUI-popoutRow"

-- {r,g,b[,a]} or {[1],[2],[3][,4]} -> a plain {r,g,b,a}; nil for anything else.
-- (The same normaliser Popout.lua keeps; two files, one shape of colour.)
local function normColor(c)
    if type(c) ~= "table" then return nil end
    local r, g, b = c.r or c[1], c.g or c[2], c.b or c[3]
    if not (r and g and b) then return nil end
    return { r = r, g = g, b = b, a = c.a or c[4] or 1 }
end

local function safeCall(fn, ...)
    if type(fn) ~= "function" then return end
    local a, b = ...
    return xpcall(function() return fn(a, b) end, geterrorhandler())
end

-- opts.db may be a TABLE or a FUNCTION returning one, and it is re-resolved on
-- EVERY read rather than captured once. A consumer whose settings table is
-- swapped underneath it -- a party/raid mode switch is the obvious one -- would
-- otherwise keep summarising the table it was built against forever.
local function resolveDB(v)
    if type(v) == "function" then return v() end
    return v
end

-- ============================================================
-- PER-HOST STORE
-- The shared instance per key, and every instance PINNED out of one. Host state
-- rather than library state, for the reason Popout.lua's own store gives:
-- two consumers may both be running rows and must not close each other's
-- panels. rawget/rawset, because a host's __index is the library and a plain
-- read would find the library's field (or another host's) instead of its own.
-- ============================================================
local function storeFor(host)
    local s = rawget(host, "_popoutRows")
    if not s then
        s = { shared = {}, pinned = {} }
        rawset(host, "_popoutRows", s)
    end
    return s
end

-- ============================================================
-- THE POPOUT SIDE
-- ============================================================

-- The shell's build, run ONCE PER INSTANCE: a bare container and an empty pane
-- cache. Everything a ROW puts in the popout is mounted into this later, by
-- paneFor, so that the instance can outlive any one row's content.
local function mountBare(po, content)
    local mount = CreateFrame("Frame", nil, content)
    mount:SetPoint("TOPLEFT", 0, 0)
    mount:SetWidth(po.width or UI.PopoutContentWidth)
    mount:SetHeight(1)
    po._rowMount = mount
    po._rowPanes = {}
    po._rowActive = nil
end

local function capHeight()
    return (UIParent:GetHeight() or 0) * CAP_FRAC
end

-- ============================================================
-- THE OFF GATE
-- A feature switched OFF has a popout full of controls that do nothing, and a
-- live control that does nothing is a lie. So the row's toggle gates its own
-- pane: off greys every widget in it and stops it taking input, exactly the
-- grey-when-disabled treatment every other gated control in the pack gets.
--
-- WHAT IT DOES NOT TOUCH. The popout's HEADER toggle, its pin and its cross all
-- live in the title bar, and the gate only ever walks the PANE -- so the tick
-- you need to switch the feature back on never greys with the things it
-- governs. Same statement the ROW makes when it dims its label and glyphs but
-- leaves its own tick alone.
--
-- ⚠ NOT the dependent grey. opts.enabled is a separate mechanism about a
-- feature you cannot act on YET, and it deliberately leaves the popout's
-- contents live (the control that would satisfy the dependency is often one of
-- them). The gate keys off the TOGGLE and nothing else.
-- ============================================================

-- ☠ THE GATE IS NOT THE ONLY WRITER. A mounted widget may carry its own gating
-- -- a page's disableOn, a sub-option that only applies in one mode -- and a
-- gate that simply enabled everything on the way back out would resurrect a
-- control its own logic had disabled. So the gate does not enable widgets: it
-- BORROWS the enabled state and hands back exactly what it took.
--
-- The borrow is a wrapper on the widget's own SetEnabled, installed once, at
-- build. It records what the caller WANTED and applies it only while the gate
-- is open; while the gate is shut it swallows the call and keeps the number.
-- Opening the gate replays the last wanted value, so a widget disabled before
-- the gate closed stays disabled, and a widget re-gated while it was shut comes
-- back in the state its own logic last asked for.
local function armGate(w)
    if w._dfGateApply then return end
    local native = w.SetEnabled
    if type(native) ~= "function" then return end

    -- The seed is what the widget can be ASKED. `enabled` is what the kit's own
    -- containers record; IsEnabled is what a native Button/CheckButton/EditBox
    -- answers. A widget that can say neither is taken as enabled -- which is what
    -- it is, unless the consumer disabled it DURING build, before this wrapper
    -- existed to hear it. Consumers gate in a pass after build (that is what
    -- RefreshChildStates is), so that hole is narrow and documented rather than
    -- guessed at.
    local wanted = true
    if type(w.enabled) == "boolean" then
        wanted = w.enabled
    elseif type(w.IsEnabled) == "function" then
        local ok, v = xpcall(function() return w:IsEnabled() end, geterrorhandler())
        if ok and type(v) == "boolean" then wanted = v end
    end
    w._dfGateWanted = wanted
    w._dfGateApply = function(enabled) return native(w, enabled) end
    w.SetEnabled = function(self, enabled)
        enabled = enabled and true or false
        self._dfGateWanted = enabled
        if self._dfGateShut then return self end
        return native(self, enabled)
    end
    return true
end

-- Mouse state, but only when the frame can actually be ASKED for it. A widget
-- that answers nothing gets its mouse left alone rather than re-enabled on the
-- way out -- the gate hands back what it took, and it cannot take what it never
-- read.
local function mouseOn(w)
    if type(w.IsMouseEnabled) ~= "function" then return nil end
    local ok, v = xpcall(function() return w:IsMouseEnabled() end, geterrorhandler())
    if ok and type(v) == "boolean" then return v end
    return nil
end

-- Per-widget gating that changed WHILE the gate was shut never reached a
-- SetEnabled call to be recorded -- a page's disableOn only re-runs when the
-- page refreshes it. So opening the gate hands the pane back to whoever wired
-- it: a settings group re-runs its own child-state pass, and anything else gets
-- its widgets' refreshContent. Both are no-ops on a pane that has no wiring of
-- its own, which is the demo's case.
local function rewire(po, rec)
    local pane = rec.pane
    if type(pane.RefreshChildStates) == "function" then
        return safeCall(pane.RefreshChildStates, pane)
    end
    local db = po.host and po.host:Call("getSettingsDB")
    for _, w in ipairs(rec.kids) do
        if type(w.RefreshChildStates) == "function" then
            safeCall(w.RefreshChildStates, w)
        elseif type(w.refreshContent) == "function" then
            safeCall(w.refreshContent, w, db)
        end
    end
end

-- Shut or open the gate on one built pane. Idempotent: the state is kept on the
-- record, so the refresh that follows every toggle write can call this on every
-- bound instance without re-walking a pane that is already in the right state.
local function gatePane(po, rec, shut)
    shut = shut and true or false
    if rec.gateShut == shut then return end
    rec.gateShut = shut
    for _, w in ipairs(rec.kids) do
        if w._dfGateApply then
            w._dfGateShut = shut or nil
            -- ⚠ Spelled out, NOT `shut and false or wanted`: that idiom cannot
            -- yield false, so the shut branch handed the widget its own wanted
            -- value back and nothing ever greyed.
            if shut then w._dfGateApply(false) else w._dfGateApply(w._dfGateWanted) end
        else
            -- No SetEnabled at all -- a note, a separator, a consumer's own
            -- frame. Dimmed to the SAME depth a disabled widget lands at, so a
            -- shut pane reads as one dead block rather than a mix.
            if shut then
                if w._dfGateAlpha == nil and type(w.GetAlpha) == "function" then
                    w._dfGateAlpha = w:GetAlpha() or 1
                end
                if type(w.SetAlpha) == "function" then w:SetAlpha(DIM_ALPHA) end
                if mouseOn(w) then
                    w._dfGateMouse = true
                    w:EnableMouse(false)
                end
            else
                if type(w.SetAlpha) == "function" then w:SetAlpha(w._dfGateAlpha or 1) end
                w._dfGateAlpha = nil
                if w._dfGateMouse then
                    w._dfGateMouse = nil
                    w:EnableMouse(true)
                end
            end
        end
    end
    if not shut then rewire(po, rec) end
end

-- The gate for a row's pane ON THIS INSTANCE, if that pane has been built. Safe
-- to call for a row whose pane this instance has never seen.
local function syncGate(po, row, rec)
    rec = rec or (po._rowPanes and po._rowPanes[row])
    if not rec then return end
    gatePane(po, rec, not row._Read())
end

-- Build (or fetch) the pane holding `row`'s controls on this instance.
-- Returns the record and whether this call BUILT it.
--
-- rec.pane is what the consumer mounted into; rec.host is what gets shown and
-- measured -- the same frame, unless the pane came out taller than the cap, in
-- which case it is a scroll region wrapped around it. The decision is made ONCE,
-- at build, because a pane's height is fixed the moment its controls are on it;
-- re-deciding on every swap would mean re-parenting a live frame in and out of a
-- scroll child for no change in the answer.
local function paneFor(po, row)
    local panes = po._rowPanes
    if not panes then panes = {}; po._rowPanes = panes end
    local rec = panes[row]
    if rec then return rec, false end

    local width = po.width or UI.PopoutContentWidth
    local pane = CreateFrame("Frame", nil, po._rowMount)
    pane:SetPoint("TOPLEFT", 0, 0)
    pane:SetWidth(width)
    pane:SetHeight(1)
    -- The consumer sizes its own pane, exactly as a consumer sizes the shell's
    -- `content` -- the pack cannot measure a column of widgets it did not lay out.
    safeCall(row._build, po, pane)
    local h = max(pane:GetHeight() or 0, 1)

    -- THE GATE'S ROSTER, taken once, here. A pane is built ONCE per (instance,
    -- row) and never grows afterwards, so the list of widgets the toggle governs
    -- is settled the moment the build returns -- and re-walking GetChildren on
    -- every toggle would only re-derive the same list.
    local kids = {}
    if type(pane.GetChildren) == "function" then
        for _, w in ipairs({ pane:GetChildren() }) do
            if type(w) == "table" then
                kids[#kids + 1] = w
                armGate(w)
            end
        end
    end

    -- gateShut starts FALSE rather than nil: a pane is built with its widgets in
    -- whatever state the consumer left them, which is the open state, so the
    -- first sync on an already-on row is a no-op instead of a pointless rewire.
    rec = { pane = pane, host = pane, h = h, kids = kids, gateShut = false }

    local cap = capHeight()
    if cap > 0 and h > cap then
        local sf = CreateFrame("ScrollFrame", nil, po._rowMount, "ScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 0, 0)
        sf:SetWidth(width)
        sf:SetHeight(cap)
        -- Guarded: a surface without the scroll API (a headless stub, anything
        -- that is not a real ScrollFrame) simply gets an uncapped pane rather
        -- than an error, which is the same bargain the beam's CreateLine takes.
        if sf.SetScrollChild then sf:SetScrollChild(pane) end
        if UI.StyleScrollBar then UI.StyleScrollBar(sf) end
        pane:ClearAllPoints()
        pane:SetPoint("TOPLEFT", 0, 0)
        rec.host, rec.h, rec.scroll = sf, cap, sf
    end

    rec.host:Hide()
    panes[row] = rec
    -- PRE-GREYED ON ARRIVAL. Opening the popout of a row that is already off has
    -- to show a dead group, not a live one that greys a frame later.
    syncGate(po, row, rec)

    -- THE COUNT CHECK, and it runs here or nowhere: this is the one moment the
    -- declared number and the mounted one can be compared without building the
    -- pane a second time purely to count it. Frames only -- a label is a
    -- FontString and was never a "control" -- so a row whose count includes its
    -- headers will report a mismatch, which is the report doing its job.
    if row._count then
        local n = pane.GetNumChildren and pane:GetNumChildren() or 0
        if n ~= row._count then
            local dbg = po.host:Call("debug", "popoutrow")
            if dbg then
                dbg(format("%s: declared %s controls, mounted %s",
                           tostring(row._label), tostring(row._count), tostring(n)))
            end
        end
    end
    return rec, true
end

-- Point the instance's header controls at `row`. Called on every bind, not just
-- on build, because ONE panel serves every row: the toggle in the title bar has
-- to be the toggle of whichever row the panel is currently about.
local function syncHeader(row, po)
    local cb = po._hdrToggle
    if cb then
        cb:SetShown(row._hasToggle)
        cb:SetChecked(row._Read())
    end
    local badge = po._hdrBadge
    if badge then badge:SetText(row._count and tostring(row._count) or "") end
end

-- Bind an instance to a row: the row owns its header, its title and its accent
-- from here until something else is bound.
--
-- ...and the row it takes the panel FROM has to be repainted as well as the one
-- it hands it to. ACTIVE is "the open panel is about ME", so a retarget always
-- changes the answer for exactly two rows, and painting only the winner would
-- leave a column with two rows both claiming the panel.
local function bindRow(po, row)
    local prev = po._boundRow
    if prev and prev ~= row and prev._bound then prev._bound[po] = nil end
    po._boundRow = row
    row._bound[po] = true
    po:SetHeader(row._title)
    po:SetAccent(row._accent)      -- nil resets to the host accent
    syncHeader(row, po)
    if prev and prev ~= row then safeCall(prev._SyncActive) end
    safeCall(row._SyncActive)
end

-- Show `row`'s pane on this instance and take the old one down.
local function swapTo(po, row)
    local prev = po._rowActive
    local rec = paneFor(po, row)
    -- Re-synced on every swap, not just on build: a CACHED pane's row may have
    -- been toggled from somewhere else while this instance was showing a
    -- different row, and a hidden pane takes no refresh of its own.
    syncGate(po, row, rec)
    if prev and prev ~= rec then prev.host:Hide() end
    rec.pane:Show()
    rec.host:Show()
    po._rowActive = rec
    po.content:SetHeight(rec.h)
    po:Resize()
    bindRow(po, row)
    return rec
end

-- The title bar's own toggle and count badge, built ONCE per instance and
-- REBOUND on every retarget. A popout you can toggle the feature from is the
-- difference between "a panel about that row" and "a panel that happens to be
-- open beside it" -- but the shell knows nothing about rows, so the controls are
-- built here and handed back for the shell to anchor.
local HDR_CHECK, HDR_TICK = 14, 8
local function buildHeaderControls(host, po, bar)
    local cb = CreateFrame("CheckButton", nil, bar, "BackdropTemplate")
    host:StyleCheckButton(cb, { size = HDR_CHECK, checkSize = HDR_TICK, themeRoot = bar })
    cb:SetScript("OnClick", function(self)
        -- Routed through the BOUND row's one write path, so the header and the
        -- row cannot disagree about what a toggle means or who gets told.
        local row = po._boundRow
        if row then row._Write(self:GetChecked() and true or false) end
    end)
    po._hdrToggle = cb

    -- Fixed width here too: ONE panel serves every row, so a swap from a 3-control
    -- group to a 14-control one would otherwise widen this badge and shove the
    -- title's right edge across mid-glide.
    local badge = host:CreateLabelNative(bar, { size = M.badgeSize, color = C_TEXT_DIM })
    badge:SetWidth(M.badgeW)
    if badge.SetJustifyH then badge:SetJustifyH("RIGHT") end
    po._hdrBadge = badge
    return cb, badge
end

local function forgetInstance(host, po)
    local s = storeFor(host)
    if s.shared[po.key] == po then s.shared[po.key] = nil end
    for i = #s.pinned, 1, -1 do
        if s.pinned[i] == po then tremove(s.pinned, i) end
    end
    local row = po._boundRow
    if row then
        if row._bound then row._bound[po] = nil end
        if row.popout == po then row.popout = nil end
    end
    po._boundRow = nil
    -- After the unbind, not before: _SyncActive answers by walking row._bound,
    -- and a row still holding a closed instance would paint itself active.
    if row then safeCall(row._SyncActive) end
end

-- ============================================================
-- THE ROW
-- ============================================================

-- opts:
--   label      REQUIRED row name (a display string; the consumer localises it)
--   db         the settings table handed to summary()/enabled(); a TABLE or a
--              FUNCTION -> table, re-resolved on every refresh
--   toggle     { db = t|fn, key = "k" }  (db defaults to opts.db)
--              OR { get = fn, set = fn(v) }
--              OFF also GATES the popout: every widget in this row's pane greys
--              and stops taking input. The popout's own header toggle, pin and
--              cross stay live -- see THE OFF GATE above
--   summary    fn(db) -> string, rendered live in the row
--   offText    the single word shown instead of the summary while toggled off
--   count      declared number of controls in the group (the badge, and the
--              number the build-time count check is measured against)
--   build      fn(popout, pane) -> mounts the group's widgets; ONCE per
--              (instance, row), and it must size its pane
--   accent     {r,g,b[,a]} per-row accent override (else the host accent)
--   enabled    bool or fn(db) -> bool; false greys the WHOLE row, and the popout
--              still opens -- the controls inside gate themselves. ⚠ A SEPARATE
--              mechanism from the toggle's gate: a dependent-grey row whose own
--              toggle is ON keeps its popout contents live
--   onToggle   fn(newValue) after a toggle write from either place
--   window     REQUIRED for opening: the window frame the popout docks outside
--   clipTo     the region that actually CLIPS this row -- the scroll frame the
--              list lives in. The popout's connected chrome hides while the row
--              is scrolled out of it. Without one the shell falls back to the
--              WINDOW, which is too generous by the window's own title bar and
--              padding: the beam and outline then hang over that chrome for the
--              50-odd pixels between the row leaving the viewport and its rect
--              leaving the window
--   popoutKey  override the shared pool key (default: one per host)
--   title      popout header title (default: label)
--
-- Returns the row frame with .Refresh() / .refreshContent(db), :SetEnabled(bool),
-- :SetAccent(c), :OpenPopout(), :ClosePopout(reason) and .popout.
function UI:CreatePopoutRow(parent, opts)
    local host = self
    opts = opts or {}
    local L = host.hooks and host.hooks.L

    -- A Button, because the CLICK TARGET IS THE WHOLE ROW. That is also why the
    -- gear and the chevron below are plain textures rather than glyph buttons --
    -- see CreateGlyphButton's own note: a labelled row that merely CONTAINS an
    -- icon has one hit box, not three.
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(260, ROW_H)
    row.preferredHeight = ROW_H
    row.fixedRowHeight = true
    -- WHICH PART OF THIS FRAME IS INK. The row's frame is its whole layout SLOT,
    -- and the bottom M.gap of that slot is the gap to the next row -- nothing is
    -- painted there. The popout shell reads this off any region it tethers to
    -- (Popout.lua's insetOf), so the source outline is drawn round the PLATE
    -- rather than round the slot, and the beam aims at the plate's centre. Left
    -- flush with the frame, because the plate is.
    row.popoutInset = { 0, 0, 0, M.gap }

    row._label   = opts.label or ""
    row._title   = opts.title or row._label
    row._count   = opts.count
    row._build   = opts.build
    row._window  = opts.window
    row._clipTo  = opts.clipTo
    row._key     = opts.popoutKey or DEFAULT_KEY
    row._accent  = normColor(opts.accent)
    row._hasToggle = opts.toggle ~= nil
    row._bound   = {}
    local offText = opts.offText or (L and L["Off"]) or "Off"

    -- ---- chrome ---------------------------------------------------
    -- A FRAME, not the texture this used to be, and everything the row draws is
    -- parented to IT rather than to the row. Two reasons, and the second is the
    -- one that forces it:
    --
    --   * the plate carries a real element backdrop now -- fill AND a 1px border
    --     -- and the border is the kit's own pixel border, which is four textures
    --     on a frame. A texture cannot own one.
    --   * a child frame draws ABOVE its parent's own layers. With the glyphs left
    --     on the row, the plate's fill would cover them.
    --
    -- Its rect is the row's SLOT less the gap below (see row.popoutInset): the
    -- ink is top-aligned in the slot, and the gap under it belongs to the next
    -- row.
    local plate = CreateFrame("Frame", nil, row, "BackdropTemplate")
    plate:SetPoint("TOPLEFT", 0, 0)
    plate:SetPoint("TOPRIGHT", 0, 0)
    plate:SetHeight(PLATE_H)
    host:CreateElementBackdrop(plate, {
        bgColor     = { C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, M.restFill },
        borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, M.restBorder },
    })
    row.plate = plate

    -- The toggle. A bare CheckButton put through the shared styler, so this tick
    -- and the tick on a CreateCheckbox are one control at two sizes.
    --
    -- LEFT, so it centres on the plate's midline -- which is what every anchor
    -- in this build does, and the whole of "vertically centred" for this row.
    local cb
    if row._hasToggle then
        cb = CreateFrame("CheckButton", nil, plate, "BackdropTemplate")
        cb:SetPoint("LEFT", plate, "LEFT", M.padX, 0)
        host:StyleCheckButton(cb, { size = M.check, checkSize = M.checkTick,
                                    accent = row._accent, themeRoot = parent })
        row.checkButton = cb
    end

    -- ---- the right-hand columns -----------------------------------
    -- ☠ FIXED COLUMNS, every one of them, and NOT ONE anchored off a self-sizing
    -- thing. The badge used to take whatever width its text wanted, and the gear
    -- and the summary hung off its left edge -- so a row reading "3" and a row
    -- reading "14" put their gears 6px apart and their summaries with them, and a
    -- column of these read as a ragged list instead of a table. Every offset
    -- below is a constant, so the four columns land at the same x on every row of
    -- a parent whatever any of them happens to say.
    local chevron = plate:CreateTexture(nil, "OVERLAY")
    chevron:SetSize(M.chevron, M.chevron)
    chevron:SetPoint("RIGHT", plate, "RIGHT", -M.padX, 0)
    chevron:SetTexture(ICON_PATH .. "chevron_right")
    chevron:SetVertexColor(1, 1, 1, 0.5)
    row.chevron = chevron

    -- The count badge sits between the gear and the chevron and is drawn in the
    -- accent, so "how much is in here" reads as part of the way IN rather than
    -- as another value in the summary.
    --
    -- A PILL, not a bare number: its own darker fill and 1px border, so the count
    -- reads as a chip stamped into the plate rather than as a third piece of text
    -- competing with the label and the summary. The pill is the fixed column --
    -- it is sized, never measured -- and the number is laid out INSIDE it,
    -- centred, so the box cannot move with what it says.
    local badgePill = CreateFrame("Frame", nil, plate, "BackdropTemplate")
    badgePill:SetSize(M.badgeW, M.badgeH)
    badgePill:SetPoint("RIGHT", chevron, "LEFT", -M.colGap, 0)
    host:CreateElementBackdrop(badgePill, {
        bgColor     = { C_BACKGROUND.r, C_BACKGROUND.g, C_BACKGROUND.b, M.badgeFill },
        borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, M.badgeBorder },
    })
    row.badgePill = badgePill

    local badge = host:CreateLabelNative(badgePill, { size = M.badgeSize, color = C_TEXT_DIM })
    badge:SetPoint("LEFT", badgePill, "LEFT", 0, 0)
    badge:SetPoint("RIGHT", badgePill, "RIGHT", 0, 0)
    if badge.SetJustifyH then badge:SetJustifyH("CENTER") end
    badge:SetText(row._count and tostring(row._count) or "")
    row.badge = badge

    -- No count declared, no pill: an empty bordered box beside the chevron is a
    -- chip that says nothing. The COLUMN stays either way -- the gear is anchored
    -- to the pill's rect, not to whether it is drawn -- so a row with a count and
    -- a row without still line their gears up.
    badgePill:SetShown(row._count ~= nil)

    local gear = plate:CreateTexture(nil, "OVERLAY")
    gear:SetSize(M.gear, M.gear)
    gear:SetPoint("RIGHT", badgePill, "LEFT", -M.colGap, 0)
    gear:SetTexture(ICON_PATH .. "settings")
    gear:SetVertexColor(1, 1, 1, 0.6)
    row.gear = gear

    local label = host:CreateLabelNative(plate, { size = M.labelSize, color = C_TEXT })
    label:SetText(row._label)
    label:SetPoint("LEFT", cb or plate, cb and "RIGHT" or "LEFT", cb and M.labelGap or M.padX, 0)
    label:SetJustifyH("LEFT")
    if label.SetWordWrap then label:SetWordWrap(false) end
    row.label = label

    -- The summary is ANCHORED between the label and the gear cluster rather than
    -- sized from its own text, and right-justified. Both matter: a box that
    -- resized itself would shuffle the row every time the value changed, and a
    -- value flush against the way in is where the eye already is. Its RIGHT edge
    -- is a constant off the plate now that the gear's is, so a stack of rows
    -- right-aligns its values against one another as well as against the gear.
    local summary = host:CreateLabelNative(plate, { size = M.summarySize, color = C_TEXT_DIM })
    summary:SetPoint("LEFT", label, "RIGHT", M.colGap, 0)
    summary:SetPoint("RIGHT", gear, "LEFT", -M.colGap, 0)
    summary:SetJustifyH("RIGHT")
    if summary.SetWordWrap then summary:SetWordWrap(false) end
    row.summary = summary

    -- ---- the plate's paint ----------------------------------------
    -- Everything whose colour depends on the row's STATE rather than on its
    -- values: the plate, and the label that names it.
    --
    -- Split out of Refresh because ACTIVE changes without the db changing -- one
    -- retarget repaints two rows, and re-running a consumer's summary function
    -- for each would be work for nothing.
    --
    -- The three states are NOT independent, which is why this is one function
    -- rather than a hover handler and an active handler that both write the
    -- plate. Hovering an ACTIVE row has to brighten the accent wash rather than
    -- replace it with the neutral hover: the cursor is over the row exactly when
    -- the user is reading which one is open, and that is the worst moment to
    -- stop saying so.
    local function paintState()
        local on = row._Read()
        local active = row._active
        local accent = row._accent or host:GetAccent()
        if active then
            plate:SetBackdropColor(accent.r, accent.g, accent.b,
                                   row._hovered and M.activeHover or M.activeFill)
            plate:SetBackdropBorderColor(accent.r, accent.g, accent.b, M.activeBorder)
        else
            local f = row._hovered and C_HOVER or C_ELEMENT
            plate:SetBackdropColor(f.r, f.g, f.b,
                                   row._hovered and M.hoverFill or M.restFill)
            plate:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, M.restBorder)
        end
        -- OFF outranks ACTIVE on the label. A row with its feature switched off
        -- has nothing to be the subject of, open panel or not -- and an accent
        -- label over a dimmed summary would read as the opposite.
        local c = (not on) and C_TEXT_DIM or (active and accent or C_TEXT)
        label:SetTextColor(c.r, c.g, c.b, 1)
    end

    -- ACTIVE is "the panel that is open is about ME", and it is ANSWERED by
    -- walking the bound set rather than kept as a flag someone has to remember to
    -- clear: a row may be bound to a PINNED instance as well as to the shared
    -- one, and it is still the subject of the pinned panel after the shared one
    -- has moved on to another row.
    function row._SyncActive()
        local active = false
        for po in pairs(row._bound) do
            if po and not po.closed and po._boundRow == row then
                active = true
                break
            end
        end
        if row._active == active then return end
        row._active = active
        paintState()
    end

    -- ---- state ----------------------------------------------------

    -- Read the toggle. nil-safe by construction: a row with no toggle answers
    -- true, so every "is this on?" test below reads the same either way.
    function row._Read()
        local t = opts.toggle
        if not t then return true end
        if t.get then return t.get() and true or false end
        local tdb = resolveDB(t.db or opts.db)
        if tdb and t.key then return tdb[t.key] and true or false end
        return false
    end

    -- THE ONE WRITE PATH. The row's tick and the popout header's tick both come
    -- through here, so neither can write somewhere the other does not read, and
    -- the refresh that follows repaints BOTH.
    function row._Write(v)
        v = v and true or false
        local t = opts.toggle
        if t then
            if t.set then safeCall(t.set, v)
            else
                local tdb = resolveDB(t.db or opts.db)
                if tdb and t.key then tdb[t.key] = v end
            end
        end
        safeCall(opts.onToggle, v)
        row.Refresh()
    end

    local function isEnabled(db)
        if row._enabledOverride ~= nil then return row._enabledOverride end
        local e = opts.enabled
        if e == nil then return true end
        if type(e) == "function" then return e(db) and true or false end
        return e and true or false
    end

    -- Re-render everything the row displays. Takes (and ignores) any arguments,
    -- so `row.Refresh()`, `row:Refresh()` and the settings group's
    -- `widget:refreshContent(db)` all land on the same body -- the db is
    -- re-resolved here regardless, which is the point of allowing a function.
    function row.Refresh()
        local db = resolveDB(opts.db)
        local on = row._Read()
        local enabled = isEnabled(db)
        row._toggledOn, row._enabled = on, enabled

        if cb then
            cb:SetChecked(on)
            cb:SetEnabled(enabled)
        end
        -- OFF replaces the summary outright. A row that is switched off has no
        -- settings worth reporting, and printing them anyway reads as though it
        -- were still doing them.
        local text = on and (opts.summary and opts.summary(db) or "") or offText
        summary:SetText(text or "")

        -- Dependent-grey dims the WHOLE row, toggle included. Toggled-off dims
        -- only what the toggle governs -- so the tick you need to click to turn
        -- it back on never fades with everything it controls.
        row:SetAlpha(enabled and 1 or DIM_ALPHA)
        -- The plate and the label, in one place shared with the active repaint.
        paintState()
        summary:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, on and 1 or 0.7)
        gear:SetVertexColor(1, 1, 1, on and 0.6 or OFF_ALPHA * 0.6)
        chevron:SetVertexColor(1, 1, 1, on and 0.5 or OFF_ALPHA * 0.5)

        for po in pairs(row._bound) do
            if po and not po.closed and po._boundRow == row then
                syncHeader(row, po)
                -- The LIVE half of the gate. Both ticks -- the row's and the
                -- popout header's -- write through row._Write, which lands here,
                -- so there is one path to the grey and neither tick can move the
                -- toggle without the pane following.
                syncGate(po, row)
            end
        end
    end
    row.refreshContent = row.Refresh

    -- Consistent with every other widget's grey path: an explicit call OVERRIDES
    -- opts.enabled from here on, so a page driving disableOn and a row carrying
    -- its own predicate cannot fight each other every refresh.
    function row:SetEnabled(enabled)
        row._enabledOverride = enabled and true or false
        row.Refresh()
        return row
    end

    -- ---- the popout -----------------------------------------------

    function row:OpenPopout()
        -- Without a window there is nothing to dock OUTSIDE of, and docking
        -- beside the row would put the panel on top of the list it came from --
        -- which is the whole reason the outsideOf placement exists.
        if not row._window then return row end
        local po = host:CreatePopout({
            key     = row._key,
            title   = row._title,
            width   = UI.PopoutContentWidth,
            accent  = row._accent,
            tetherSource = row,
            build   = mountBare,
            headerControls = function(p, bar) return buildHeaderControls(host, p, bar) end,
            onClose = function(p) forgetInstance(host, p) end,
            onPin   = function(p)
                local s = storeFor(host)
                if s.shared[p.key] == p then s.shared[p.key] = nil end
                s.pinned[#s.pinned + 1] = p
            end,
        })
        -- Content BEFORE placement: the dock and the glide are both computed
        -- from the frame's height, and a popout placed at the previous row's
        -- height would land in the wrong place and then jump.
        swapTo(po, row)
        po:Follow(row, { outsideOf = row._window, clipTo = row._clipTo })
        row.popout = po
        if not po.pinned then storeFor(host).shared[row._key] = po end
        return row
    end

    function row:ClosePopout(reason)
        local po = row.popout
        if po and not po.closed then po:Close(reason or "api") end
        row.popout = nil
        return row
    end

    -- Re-tint the row AND whatever it currently has open -- a pinned panel this
    -- row opened included, which is why the bound set is walked rather than just
    -- row.popout. nil clears the override and hands the row back to the host
    -- accent.
    --
    -- ⚠ A row built WITHOUT an accent registered a theme listener on its tick
    -- (StyleCheckButton does that for an unaccented box), so a later host theme
    -- change will pull that tick back to the host colour even if SetAccent has
    -- since given the row one of its own. Rows whose colour is their own should
    -- pass opts.accent at build, which suppresses the listener; SetAccent is for
    -- a row whose colour is the mode's, and there the two agree anyway.
    function row:SetAccent(c)
        row._accent = normColor(c)
        local col = row._accent or host:GetAccent()
        if cb and cb.ApplyThemeColor then cb.ApplyThemeColor(col) end
        badge:SetTextColor(col.r, col.g, col.b, 1)
        -- The ACTIVE plate and label are drawn in the accent, so a row that is
        -- open when its colour changes has to repaint here as well -- otherwise
        -- the wash keeps the old hue until the next Refresh.
        paintState()
        for po in pairs(row._bound) do
            if po and not po.closed and po.SetAccent then po:SetAccent(row._accent) end
        end
        return row
    end

    -- ---- interaction ----------------------------------------------
    row:SetScript("OnEnter", function() row._hovered = true;  paintState() end)
    row:SetScript("OnLeave", function() row._hovered = false; paintState() end)
    -- NOT gated on `enabled`. A greyed row is one whose settings do nothing YET;
    -- being able to look at them (and at the control inside that would turn the
    -- feature on) is exactly what a user in that state needs.
    row:SetScript("OnClick", function() row:OpenPopout() end)

    if cb then
        cb:SetScript("OnClick", function(self)
            row._Write(self:GetChecked() and true or false)
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)
    end

    row:SetAccent(opts.accent)
    row.Refresh()
    return row
end

-- ============================================================
-- CLOSING, FROM OUTSIDE
-- Two verbs, because the two events that close these panels mean different
-- things. Switching PAGE invalidates the rows the panel is about, but not a
-- panel the user deliberately pinned loose. Closing the WINDOW takes everything.
-- ============================================================

-- The shared instance for every key rows on this host have used.
function UI:CloseUnpinnedPopoutRows(reason)
    local s = rawget(self, "_popoutRows")
    if not s then return self end
    -- Collected first: Close fires onClose, which reaches back into this very
    -- table through forgetInstance.
    local doomed = {}
    for _, po in pairs(s.shared) do doomed[#doomed + 1] = po end
    for _, po in ipairs(doomed) do
        if not po.closed and not po.pinned then po:Close(reason or "api") end
    end
    return self
end

-- ...and every instance that was pinned out of one.
function UI:CloseAllPopoutRows(reason)
    self:CloseUnpinnedPopoutRows(reason)
    local s = rawget(self, "_popoutRows")
    if not s then return self end
    local doomed = {}
    for _, po in ipairs(s.pinned) do doomed[#doomed + 1] = po end
    for _, po in ipairs(doomed) do
        if not po.closed then po:Close(reason or "api") end
    end
    return self
end
