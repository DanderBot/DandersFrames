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
local max, min, ceil, floor = math.max, math.min, math.ceil, math.floor

-- Perf marks, the same pair Popout.lua declares and for the same reason -- see
-- its PERF MARKS block. Written into `host.perf`, printed by UI:PerfReport, and
-- one rawget when nothing is recording. Kept file-local rather than shared off
-- the library: they are two closures, and a published pair would be a surface
-- the kit does not want to owe anybody.
local debugprofilestop = debugprofilestop or function() return 0 end

local function perfStart(host)
    if type(host) ~= "table" or not rawget(host, "_perfActive") then return nil end
    return debugprofilestop()
end

local function perfStop(host, name, t0)
    if not t0 then return end
    local p = rawget(host, "perf")
    if not p then return end
    p.counts[name] = (p.counts[name] or 0) + 1
    p.ms[name] = (p.ms[name] or 0) + (debugprofilestop() - t0)
end

local C_TEXT, C_TEXT_DIM = UI.Colors.text, UI.Colors.textDim
local C_ELEMENT, C_BORDER = UI.Colors.element, UI.Colors.border
local C_HOVER, C_BACKGROUND = UI.Colors.hover, UI.Colors.background
-- The amber notice token. The per-control modified-dots inside the popout wear
-- it too (Widgets.lua), so the row and the controls it opens say "not the
-- shipped default" in one colour.
local C_NOTICE = UI.Colors.notice
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

-- ☠ THE LABEL'S x, AND THE CONTROL LINES' LEFT EDGE, ARE ONE CONSTANT. The tick's
-- column is reserved whether or not a tick is drawn (see the label's anchor
-- below), and a control line is indented to the NAME -- so a row's second line
-- starts under the first line's first letter rather than under its tick. Named
-- once here because three things now read it; ControlRow.lua computes the same
-- expression for the same reason and says so at its own LABEL_X.
local LABEL_X = M.padX + M.check + M.labelGap

-- The hoist half's metrics, all from the same table for the reason above it.
-- LINE_H is the whole CELL and the two tiers inside it are NAME_H above
-- CONTROL_H -- the name is over the control, not beside it, so a cell's control
-- is the cell's full width.
local LINE_H, NAME_H      = M.lineH, M.nameH
local CONTROL_H, LINE_PAD = M.controlH, M.linePad
local CELL_GAP            = M.cellGap
local FOOTER_H            = M.footer
local MIN_CONTROL, SPLIT_CELL = M.minControl, M.splitCell

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

-- Re-measure the pane that is CURRENTLY showing and put the panel back around
-- it. A pane's height is not the constant paneFor took it for: a consumer whose
-- pane holds a settings group re-flows that group whenever a hideOn changes
-- (Border Style = TEXTURE shows the texture dropdown), and the pane then grows
-- or shrinks under a panel still sized to what it measured at build.
--
-- ⚠ THE CAP DECISION IS STILL BUILD-TIME, so a scroll-wrapped pane is left
-- alone: its host is the scroll region and its height IS the cap, whatever the
-- pane inside now measures. The other side of that -- a pane which grows PAST
-- the cap after build stays unwrapped and simply opens a taller panel (the shell
-- clamps it to the screen) -- is deliberate: wrapping it here would mean
-- re-parenting a live pane into a scroll child mid-interaction, under the user's
-- cursor, which is the exact thing paneFor decides once in order to avoid.
local function syncRowPaneHeight(po)
    local rec = po._rowActive
    if not rec or rec.scroll then return po end
    rec.h = max(rec.pane:GetHeight() or 0, 1)
    po.content:SetHeight(rec.h)
    po:Resize()
    return po
end

-- ============================================================
-- THE ACCENT, AND THE PANES THAT ARE NOT LOOKING
-- ------------------------------------------------------------
-- ☠ THE PANE CACHE IS WHERE THE SESSION PILES UP. A pane is built once per
-- (instance, row) and then KEPT -- an unpinned panel is pooled rather than
-- destroyed on close, so the cache holds every group the user has opened on
-- every page since login. The shell's accent cascade used to walk that whole
-- pile on every open, twice: measured at 226 ApplyThemeColor calls and 292 frame
-- nodes for one open on a 14-row page, growing with every row ever visited. That
-- is the open-and-close stutter.
--
-- ⚠ THE PILE IS NO LONGER UNDER THE MOUNT. That was the OTHER half of the same
-- stutter and it took a second pass to find, because it costs nothing a Lua
-- counter can see -- see THE PANE DOCK below. The cache still holds every pane;
-- the MOUNT holds only the one on screen.
--
-- Only ONE of those panes is on screen. So the mount takes the cascade over
-- (Popout.lua's dfCascadeInto) and paints the ACTIVE one, remembering the colour
-- it went on in; a pane that was hidden when the colour moved catches up on the
-- swap that shows it. Every widget a user can SEE is in the colour the chrome
-- is, which is the whole of what the cascade ever promised.
-- ============================================================

-- Paint the pane that is UP, if it is not already wearing this colour, and
-- remember what it went on in. No active pane is the state the very first adopt
-- cascades in -- nothing is mounted yet -- and a pane is built ONCE and never
-- grows (see paneFor), so the stamp cannot go stale under a widget that arrived
-- after it.
--
-- Compared by VALUE, not by identity: the host's accent table is MUTATED IN
-- PLACE by a theme change, so a remembered reference to it would always agree
-- with itself and no theme change would ever repaint anything.
local function cascadeActivePane(po, c)
    local rec = po._rowActive
    if not rec then return end
    c = c or po:GetAccent()
    local a = c.a or 1
    if rec.tR == c.r and rec.tG == c.g and rec.tB == c.b and rec.tA == a then return end
    po:CascadeInto(rec.pane, c)
    rec.tR, rec.tG, rec.tB, rec.tA = c.r, c.g, c.b, a
end

-- ============================================================
-- THE PANE DOCK -- where a pane lives while it is NOT the one on screen.
-- ------------------------------------------------------------
-- ☠ THE SECOND ACCUMULATOR, and it is not Lua. The accent cascade was the first
-- (see the block above) and stopping it made a re-open flat IN CALL COUNTS --
-- measured here: walk, tint and frame-creation per re-open are identical after
-- one page and after eight. Danders still had the stutter, still growing: "it
-- gets worse the more popups I open, even when opening, switching tabs and
-- opening more."
--
-- What was still growing is the MOUNT'S CHILD LIST. A pane is built once per
-- (instance, row) and then KEPT, and every one of them stayed parented under
-- `_rowMount` -- inside `content`, inside the popout frame. That frame is
-- Show()n on every open and Hide()n on every close, and the ENGINE walks the
-- whole subtree for visibility on each. So an open cost one pane's worth of
-- engine work on the first row of the session and N panes' worth after N rows
-- had been visited, with nothing in Lua to show for it.
--
-- This is the SAME disease the settings window itself had, and it is worth
-- quoting the fix that cured it (DandersFrames_Options/GUI/Panel.lua, THE PAGE
-- DOCK): every built page used to stay parented to `content`, shown or not, and
-- that made opening the window take EIGHT SECONDS -- "the cost is the ENGINE
-- walking that hidden subtree for visibility, not Lua we run". Reparenting the
-- non-current pages away dropped the same Show from 7774ms to 90ms.
--
-- So a pane that is not the active one lives HERE instead: a detached,
-- permanently hidden frame with NO PARENT AT ALL, outside the popout's tree
-- entirely. The popout's subtree therefore holds EXACTLY ONE pane at any
-- moment, whatever the session has built.
--
-- ⚠ PARKED, NOT DISCARDED -- the same distinction Panel.lua draws between its
-- dock and its trash. The pane keeps its widgets, its gate roster, its accent
-- stamp and its measured height; it is expected back, and coming back is a
-- reparent rather than a rebuild. Nothing is built twice, which is the whole
-- reason the pane cache exists (WoW never frees a frame, so reuse is the only
-- economy there is).
--
-- ⚠ PER INSTANCE, not one dock for the library. A pinned panel has its own
-- mount and its own active pane, and a shared dock would be library state that
-- two consumers -- or two suites -- write into each other's. It also means the
-- dock is created with whatever CreateFrame this file captured, which is what a
-- headless run needs.
--
-- ⚠ A PARKED PANE KEEPS ITS ANCHORS to the mount (Panel.lua's dock relies on
-- exactly this for the same reason): it still measures at its real size, so
-- swapTo's re-measure and syncRowPaneHeight read the same numbers they always
-- did. The anchors are re-asserted on adopt anyway rather than trusted to have
-- survived the round trip -- again as AdoptPage does.
--
-- ⚠ WHAT MOVES IS rec.mounted, NOT rec.pane. Normally that is exactly one frame
-- and it is rec.host. The scroll-wrapped case is why it is a LIST: SetScrollChild
-- re-parents the pane INTO the scroll frame, so only the scroll frame hangs off
-- the mount and parking it takes the pane along -- but that wrap is GUARDED (a
-- surface with no scroll API gets an uncapped pane rather than an error), and on
-- THAT path the pane is still a child of the mount and has to be parked with it
-- or it is left behind in the very tree the dock exists to empty. Settled once,
-- at build, by asking who the mount's children actually are -- see paneFor.
-- ============================================================

-- Out of the popout's tree. Idempotent, and cheap enough to call on every swap.
local function parkPane(po, rec)
    if not rec or rec.parked then return end
    local dock = po._rowDock
    if not dock or not rec.mounted then return end
    for _, f in ipairs(rec.mounted) do f:SetParent(dock) end
    rec.parked = true
end

-- ...and back into it, anchors re-asserted rather than trusted to have survived
-- the round trip -- the same care Panel.lua's AdoptPage takes, and for the same
-- reason: the height the swap re-measures is read off these anchors.
local function adoptPane(po, rec)
    if not rec or not rec.parked then return end
    local mount = po._rowMount
    if not mount or not rec.mounted then return end
    for _, f in ipairs(rec.mounted) do
        f:SetParent(mount)
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", mount, "TOPLEFT", 0, 0)
    end
    rec.parked = nil
end

-- The shell's build, run ONCE PER INSTANCE: a bare container and an empty pane
-- cache. Everything a ROW puts in the popout is mounted into this later, by
-- paneFor, so that the instance can outlive any one row's content.
local function mountBare(po, content)
    local mount = CreateFrame("Frame", nil, content)
    mount:SetPoint("TOPLEFT", 0, 0)
    mount:SetWidth(po.width or UI.PopoutContentWidth)
    mount:SetHeight(1)
    po._rowMount = mount
    -- The dock the panes that are not on screen live in -- see THE PANE DOCK.
    -- Parentless and hidden, so nothing the engine walks can reach it.
    local dock = CreateFrame("Frame")
    dock:Hide()
    po._rowDock = dock
    po._rowPanes = {}
    po._rowActive = nil
    -- The cascade stops here and this answers for everything under it -- see the
    -- block above. On the MOUNT rather than on the content, so the shell still
    -- walks anything else a consumer parents into the panel.
    mount.dfCascadeInto = function(c) cascadeActivePane(po, c) end
    -- Published on the INSTANCE rather than kept private, because the thing that
    -- knows a pane re-flowed is the consumer's own control (see below).
    po.SyncRowPaneHeight = syncRowPaneHeight
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
    -- Every settings GROUP mounted directly in the pane, FIRST and
    -- unconditionally. The roster below takes a group's own CHILDREN as the
    -- gate's widgets and leaves the group itself out of rec.kids, so this is the
    -- only thing left that reaches the group's disableOn sweep -- and that sweep
    -- is about the widgets the group owns, so it never doubles up with either
    -- branch after it.
    for _, g in ipairs(rec.groups) do safeCall(g.RefreshChildStates, g) end
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
    local shut = not row._Read()
    gatePane(po, rec, shut)
    -- THE FOOTER GOES WITH THE PANE. The shell's action strip is body, not
    -- chrome (the header toggle, the pin and the cross stay live -- see THE OFF
    -- GATE above), and a live "reset this group" under a feature that is
    -- switched off is the same lie the gate exists to stop the pane telling.
    -- Stated on every sync rather than only on the transition: the shell's own
    -- call is idempotent, and this is also the pass that re-asks each action's
    -- `enabled` -- which answers about things the panel is never told about
    -- (combat, an auto layout going live), so it has to be re-asked whether the
    -- toggle moved or not.
    if po.SetFooterGated then po:SetFooterGated(shut) end
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

    -- The once-per-(instance, row) cost, and the one an intermittent stutter is
    -- most naturally blamed on -- so it is measured separately from the swap
    -- rather than lumped into it.
    local t0 = perfStart(po.host)

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
    --
    -- ☠ A SETTINGS GROUP IS NOT A WIDGET, it is a bag of them. A consumer that
    -- mounts a real settings group into the pane (which is what a page does: its
    -- group's AddWidget RE-PARENTS every control into the group frame) hands this
    -- walk ONE direct child, and arming that child buys nothing -- a group has no
    -- SetEnabled, and EnableMouse(false) on a frame does NOT stop its children
    -- taking input, so the "dead" pane would still be fully clickable. So a group
    -- is opened up: its groupChildren entries' widgets go on the roster and the
    -- group frame itself does not. rewire above is what keeps the group's own
    -- state pass reachable once it is off the list.
    --
    -- ⚠ rawget for both markers. A test double (and any frame whose metatable
    -- answers unknown keys) would report a truthy method for `isSettingsGroup`,
    -- and a plain read would then treat every ordinary child as a group.
    local kids, groups = {}, {}
    if type(pane.GetChildren) == "function" then
        for _, w in ipairs({ pane:GetChildren() }) do
            if type(w) == "table" then
                local entries = rawget(w, "isSettingsGroup") and rawget(w, "groupChildren")
                if type(entries) == "table" then
                    groups[#groups + 1] = w
                    for _, entry in ipairs(entries) do
                        local cw = entry and entry.widget
                        if type(cw) == "table" then
                            kids[#kids + 1] = cw
                            armGate(cw)
                        end
                    end
                else
                    kids[#kids + 1] = w
                    armGate(w)
                end
            end
        end
    end

    -- gateShut starts FALSE rather than nil: a pane is built with its widgets in
    -- whatever state the consumer left them, which is the open state, so the
    -- first sync on an already-on row is a no-op instead of a pointless rewire.
    rec = { pane = pane, host = pane, h = h, kids = kids, groups = groups, gateShut = false }

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

    -- WHAT ACTUALLY HANGS OFF THE MOUNT, settled once, here -- the set the dock
    -- parks and adopts as a unit. See THE PANE DOCK for why this is a list and
    -- not simply rec.host: SetScrollChild is guarded, and where it did not take,
    -- the pane is still the mount's child and must travel with the scroll frame.
    local mounted = { rec.host }
    if rec.pane ~= rec.host and type(rec.pane.GetParent) == "function"
       and rec.pane:GetParent() == po._rowMount then
        mounted[#mounted + 1] = rec.pane
    end
    rec.mounted = mounted

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
    --
    -- Measured against the ROSTER rather than pane:GetNumChildren(), and the two
    -- only differ where the roster does: a pane of plain direct children collects
    -- exactly those children, so the number is unchanged there. A pane holding a
    -- settings group would have counted 1 -- the group -- and reported every
    -- honest declaration as a mismatch.
    if row._count then
        local n = #kids
        if n ~= row._count then
            local dbg = po.host:Call("debug", "popoutrow")
            if dbg then
                dbg(format("%s: declared %s controls, mounted %s",
                           tostring(row._label), tostring(row._count), tostring(n)))
            end
        end
    end
    perfStop(po.host, "popoutrow:paneBuild", t0)
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
    -- The footer belongs to the row that has the panel, exactly as the title and
    -- the accent above it do. Re-stated on the BIND rather than only on the
    -- adopt so a PINNED instance re-bound to another row (which never re-adopts)
    -- gets that row's verbs rather than keeping the ones it was pinned with.
    if po.SetActions then po:SetActions(row._actions) end
    syncHeader(row, po)
    if prev and prev ~= row then safeCall(prev._SyncActive) end
    safeCall(row._SyncActive)
end

-- Show `row`'s pane on this instance and take the old one down.
local function swapTo(po, row)
    local t0 = perfStart(po.host)
    local prev = po._rowActive
    local rec = paneFor(po, row)
    -- Re-synced on every swap, not just on build: a CACHED pane's row may have
    -- been toggled from somewhere else while this instance was showing a
    -- different row, and a hidden pane takes no refresh of its own.
    syncGate(po, row, rec)
    -- THE PANE THAT IS LEAVING GOES OUT OF THE TREE, not merely out of sight --
    -- see THE PANE DOCK. Hidden-but-parented is exactly the state that made an
    -- open cost more the more rows the session had visited.
    if prev and prev ~= rec then
        prev.host:Hide()
        parkPane(po, prev)
    end
    -- ...and the one arriving comes back in. A no-op on the pane just built,
    -- which has never been parked.
    adoptPane(po, rec)
    rec.pane:Show()
    rec.host:Show()
    po._rowActive = rec
    -- RE-MEASURED, not replayed. rec.h was fixed at build, and a CACHED pane may
    -- have re-flowed since (a hideOn inside it changed while another row had the
    -- panel), so reapplying the stale number opens the panel at the wrong height
    -- and leaves a gap or a clipped last row. The scroll-wrapped case keeps its
    -- number: rec.h IS the cap there -- see syncRowPaneHeight.
    if not rec.scroll then rec.h = max(rec.pane:GetHeight() or 0, 1) end
    po.content:SetHeight(rec.h)
    po:Resize()
    -- ...and the bind is ALSO what re-tints the pane just mounted. Its SetAccent
    -- runs the shell's cascade, which reaches the mount's hand-off, which paints
    -- whichever pane _rowActive now names -- this one. That is why _rowActive is
    -- set ABOVE the bind and not below it, and why the swap needs no cascade of
    -- its own. See THE ACCENT, AND THE PANES THAT ARE NOT LOOKING.
    bindRow(po, row)
    perfStop(po.host, "popoutrow:swap", t0)
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

-- ============================================================
-- ONE PANEL PER ROW
-- ------------------------------------------------------------
-- A row that already has a panel up does not get a second one, and the POOL
-- alone cannot promise that. Pinning takes an instance OUT of the pool -- that
-- is what pinning IS -- so a second click on the very same row found no pooled
-- instance for the key and built a fresh one: two panels, one row, the same
-- controls in both. Reported in-game as "if a popout is pinned, it shouldn't be
-- able to open again as an unpinned popout. Only 1 of each popout."
--
-- So the question the open path asks is about the ROW, not about the key: is any
-- LIVE instance currently bound to me. `_bound` is the set that answers it -- the
-- same set _SyncActive walks to paint the row ACTIVE -- and `_boundRow` is what
-- makes the answer honest: the shared instance appears in several rows' bound
-- sets over its life and is only ABOUT one of them at a time.
--
-- A pinned instance wins the tie. Two live panels about one row is the state
-- this exists to stop, so the tie is unreachable once the open path uses it --
-- but `pairs` has no order, and a rule that has to pick has to say which.
local function livePanel(row)
    local pinned, loose
    for po in pairs(row._bound) do
        if po and not po.closed and po._boundRow == row then
            if po.pinned then pinned = pinned or po else loose = loose or po end
        end
    end
    return pinned or loose
end

-- Every UNPINNED panel this row currently has, closed -- the row is going away
-- and a panel still docked to it, with a beam and an outline drawn on it, would
-- be describing something that is no longer on screen.
--
-- PINNED ones are left, by definition: pinning is the gesture that detaches a
-- panel from the row it came out of, and a detached panel does not care where
-- that row went.
--
-- Collected before anything is closed: Close fires onClose, which reaches back
-- into `_bound` through forgetInstance, and mutating a table mid-`pairs` is how
-- one of two panels silently survives.
local function closeLoosePanels(row, reason)
    local doomed
    for po in pairs(row._bound) do
        if po and not po.closed and not po.pinned and po._boundRow == row then
            doomed = doomed or {}
            doomed[#doomed + 1] = po
        end
    end
    if not doomed then return end
    for _, po in ipairs(doomed) do
        if not po.closed then po:Close(reason or "source") end
    end
end

local function forgetInstance(host, po, reason)
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
    -- The ROW's own close hook (opts.onClose), last of all, so it observes the
    -- world with the unbind already done -- a consumer that reacts by rebuilding
    -- its page must not find the row still claiming the panel. Fired for the row
    -- the panel was ABOUT when it closed (one panel serves many rows), with the
    -- shell's close reason ("cross"|"family"|"source"|"api", plus whatever a
    -- CloseAllPopoutRows caller passed through).
    if row and row._onClose then safeCall(row._onClose, row, reason) end
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
--              A {db, key} write goes through the host's interceptWrite /
--              onSettingWritten hooks, like every other db-bound widget in the
--              kit; a {get, set} one does not -- see row._Write
--              OFF also GATES the popout: every widget in this row's pane greys
--              and stops taking input. The popout's own header toggle, pin and
--              cross stay live -- see THE OFF GATE above
--              OMIT IT for a group that has no on/off of its own -- a way IN and
--              nothing else. No tick is drawn (here or in the popout's header),
--              the row reads as permanently on (no offText, no off gate), and the
--              tick's COLUMN is still reserved so the row lines up with toggled
--              rows beside it
--   summary    fn(db) -> string, rendered live in the row
--   offText    the single word shown instead of the summary while toggled off
--   count      declared number of controls in the group (the badge, and the
--              number the build-time count check is measured against). Counted
--              off the gate's roster, so a pane whose content is a settings
--              group is measured by the CONTROLS in it, not by the one child
--   build      fn(popout, pane) -> mounts the group's widgets; ONCE per
--              (instance, row), and it must size its pane. A pane that re-flows
--              LATER (a hideOn inside it changed) tells the panel so with
--              popout:SyncRowPaneHeight()
--   modified   fn(db) -> bool. True paints a small amber tick on the count
--              badge, meaning "at least one setting behind this row is not the
--              shipped default". Absent = no tick is ever drawn, which is every
--              consumer that has not opted in. Also settable AFTER creation with
--              row:SetModifiedCheck(fn) -- a consumer that learns the group's
--              key set by WALKING the pane it built cannot know it at this point
--   actions    an array of verbs about the GROUP as a whole (reset it, preview
--              it at its defaults), rendered as a strip along the foot of the
--              panel. Forwarded straight to the shell -- see CreatePopout's
--              `actions` for the descriptor shape and the hold contract. Absent
--              = no footer, and the panel is the height it always was. Also
--              settable after creation with row:SetActions(list), for the same
--              reason SetModifiedCheck exists. The strip GREYS with the pane
--              when the row's toggle is off
--   accent     {r,g,b[,a]} per-row accent override (else the host accent)
--   enabled    bool or fn(db) -> bool; false greys the WHOLE row, and the popout
--              still opens -- the controls inside gate themselves. ⚠ A SEPARATE
--              mechanism from the toggle's gate: a dependent-grey row whose own
--              toggle is ON keeps its popout contents live
--   onToggle   fn(newValue) after a toggle write from either place
--   onClose    fn(row, reason) after a panel that was ABOUT this row closes
--              (any close: the cross, the family sweep, a source death, an api
--              call -- `reason` is the shell's close reason). Fired after the
--              unbind, so the row no longer claims the panel when it runs. NOT
--              fired when the shared panel is merely retargeted to another row
--              -- the panel is still up, just about something else. For a
--              consumer whose pane edits data some other surface displays: the
--              close is "done editing", so this is where that surface refreshes
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
--   surface    the SURFACE STYLE this row wears (Theme.lua's UI.SurfaceStyle).
--              A table rounds the PLATE at that radius and the style's
--              rowBorderWidth, declares the radius on the tether contract
--              (row.popoutRadius) so the panel's source outline traces the plate
--              with a matching ring, and is FORWARDED to the panel the row opens
--              so the pair cannot disagree. `false` forces square on a host that
--              has opted in; OMIT and the row takes the host's own declaration,
--              which is nothing unless the consumer called host:SetSurfaceStyle
--
-- Returns the row frame with .Refresh() / .refreshContent(db), :SetEnabled(bool),
-- :SetModifiedCheck(fn), :SetActions(list), :SetAccent(c), :SetSurface(style) / :GetSurface(),
-- :OpenPopout(), :ClosePopout(reason) and .popout.
--
-- :OpenPopout() on a row that ALREADY has a panel about it raises that panel
-- instead of opening a second -- see ONE PANEL PER ROW. The row also answers the
-- kit's layout-hidden contract (UI:NotifyLayoutHidden): whatever hides the row as
-- part of a layout -- a section folding, a hideOn flipping -- takes the row's
-- unpinned panels down with it.
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
    row._modified = (type(opts.modified) == "function") and opts.modified or nil
    row._actions = (type(opts.actions) == "table") and opts.actions or nil
    row._build   = opts.build
    row._window  = opts.window
    row._clipTo  = opts.clipTo
    row._key     = opts.popoutKey or DEFAULT_KEY
    row._accent  = normColor(opts.accent)
    row._onClose = (type(opts.onClose) == "function") and opts.onClose or nil
    row._hasToggle = opts.toggle ~= nil
    row._bound   = {}
    local offText = opts.offText or (L and L["Off"]) or "Off"

    -- ☠ ASKED BEFORE ANYTHING IS DRAWN, because the TITLE LINE'S OWN HEIGHT
    -- depends on it. A plain row's plate IS its title line and is the 44 every
    -- other page's census pins; a strip row's plate is a title line, some control
    -- lines and a strip, and 44 for the top third of that is what read in game as
    -- "very chonky". So a strip row's title line is M.plateStrip and a plain
    -- row's is M.plate -- one number each, resolved once here, and nothing on an
    -- unconverted page moves by a pixel.
    row._strip = opts.footerStrip and true or false
    local HEAD_H = row._strip and M.plateStrip or PLATE_H

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
    plate:SetHeight(HEAD_H)
    row.plate = plate

    -- ---- the plate's SHAPE, and the one paint path both shapes share ----
    --
    -- ☠ THE STATE PAINT MUST NOT KNOW WHICH SHAPE IT IS PAINTING. Rest, hover
    -- and the active accent wash are three colour pairs the row computes from
    -- its own state, and there are already several ways in (a hover, a retarget,
    -- a toggle, an accent change). The trial routed them by SWAPPING the plate's
    -- SetBackdropColor / SetBackdropBorderColor methods for shims -- a shadow,
    -- which works and is exactly the kind of thing that has to stop being true
    -- when a look ships: two sets of methods on one frame, restorable only by
    -- remembering the originals, and invisible to anyone reading paintState.
    --
    -- So the shape lives in ONE function that the state paint calls with four
    -- numbers twice, and the rounded and square arms are siblings rather than
    -- one wearing the other's clothes.
    local plateSurface          -- the rounded handle, nil while square

    local function applyPlateShape()
        local s = row._surface
        if not s then
            plateSurface = nil
            UI:RemoveRoundedChrome(plate)
            -- The ORIGINAL call. CreateElementBackdrop re-issues the backdrop AND
            -- re-shows the pixel border, so square is restored rather than
            -- approximated.
            host:CreateElementBackdrop(plate, {
                bgColor     = { C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, M.restFill },
                borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, M.restBorder },
            })
            -- The tether contract's shape half, cleared with the shape: the
            -- popout's source outline reads this to decide whether to trace this
            -- plate with a ring or with a square pixel border.
            row.popoutRadius = nil
            return
        end
        plateSurface = UI:ApplyRoundedChrome(plate, {
            radius      = s.radius,
            -- The ROW weight, not the panel's -- see UI.SurfaceStyle on why the
            -- one token carries both.
            borderWidth = s.rowBorderWidth or s.borderWidth,
            fill        = { C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, M.restFill },
            border      = { C_BORDER.r, C_BORDER.g, C_BORDER.b, M.restBorder },
        })
        row.popoutRadius = s.radius
    end

    local function paintPlate(fr, fg, fb, fa, br, bg, bb, ba)
        if plateSurface then
            plateSurface:SetFillColor(fr, fg, fb, fa)
            plateSurface:SetBorderColor(br, bg, bb, ba)
        else
            plate:SetBackdropColor(fr, fg, fb, fa)
            plate:SetBackdropBorderColor(br, bg, bb, ba)
        end
    end

    row._surface = UI.ResolveSurfaceStyle(host, opts.surface)
    applyPlateShape()

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

    -- The MODIFIED TICK -- "something behind this row is not the shipped
    -- default". Parented to the PILL rather than to the plate, deliberately: it
    -- then inherits the pill's own "no count declared, no pill" hide below and
    -- can never be left floating beside a column that is not drawn.
    --
    -- Notched on the pill's top-right CORNER (its CENTRE on the corner, so it
    -- straddles the border rather than sitting inside the chip): the count is
    -- already the thing that says "how much is in here", and a mark on that chip
    -- is the smallest place on the row that is unambiguously about the group's
    -- CONTENTS rather than about its name or its current value. Anywhere in the
    -- text columns would read as part of the label or the summary.
    local modTick = badgePill:CreateTexture(nil, "OVERLAY")
    modTick:SetSize(M.modTick, M.modTick)
    modTick:SetTexture(ICON_PATH .. "dot")
    modTick:SetVertexColor(C_NOTICE.r, C_NOTICE.g, C_NOTICE.b)
    modTick:SetPoint("CENTER", badgePill, "TOPRIGHT", 0, 0)
    modTick:Hide()
    row.modifiedTick = modTick

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
    -- ☠ THE TICK'S COLUMN IS RESERVED WHETHER OR NOT A TICK IS DRAWN, exactly as
    -- the count badge's is (see badgePill:SetShown just above: no count, no pill,
    -- but the gear still hangs off the pill's RECT so the right-hand columns land
    -- at the same x on every row).
    --
    -- The left column had the other rule until a page mixed the two kinds. A row
    -- with a feature to switch on and a row that is only a way IN to a group are
    -- both rows, they sit in the same band, and anchoring the label to `cb or
    -- plate` started their names 26px apart -- which is the ragged list the
    -- right-hand columns were made fixed to avoid. One constant, both kinds.
    label:SetPoint("LEFT", plate, "LEFT", M.padX + M.check + M.labelGap, 0)
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

    -- ============================================================
    -- THE FOOTER STRIP, AND THE CONTROL LINES
    -- ------------------------------------------------------------
    -- ☠ OPT-IN, ROW BY ROW, AND EVERY LINE BELOW IS DEAD ON A ROW THAT DID NOT
    -- ASK. `opts.footerStrip` is what a page passes; a row without it never
    -- builds a strip, never re-anchors one of the six title-line regions above,
    -- and draws exactly what it drew before this block existed. That is not
    -- politeness -- a dozen pages' census suites pin those rows' anatomy, and the
    -- Frame page is the only one converted in this pass.
    --
    -- WHAT THE STRIP IS FOR. Every setting went behind a row in the popout sweep,
    -- so every setting is invisible until a panel opens; the answer is to put a
    -- feature's most-reached-for controls back ON the plate, named, and move the
    -- way IN to a strip along the bottom so it is in the same place on every row
    -- whether or not anything was hoisted. The cog, the count and the chevron all
    -- move down onto it; the title line keeps its tick, its name and its summary
    -- and is otherwise untouched.
    --
    -- ☠ THE STRIP TAKES NO MOUSE. Two reasons and either is sufficient: a frame
    -- drawn over a control eats that control's clicks (it has shipped twice in
    -- this rework), and the WHOLE ROW is already the click target -- so a
    -- mouse-enabled strip would buy nothing and would steal the row's own
    -- OnEnter/OnLeave the moment the cursor crossed onto it, dropping the hover
    -- paint while the user is over the thing they are about to click.
    local strip                    -- the footer strip's frame, nil unless asked for
    local stripFill, stripLine     -- its square wash and the hairline above it
    local stripClip, stripShape    -- ...and the ROUNDED wash's clip and its holder
    local stripSurface             -- the rounded handle, nil while the plate is square
    local stripCount               -- "N more settings"

    if row._strip then
        strip = CreateFrame("Frame", nil, plate)
        strip:SetPoint("BOTTOMLEFT", plate, "BOTTOMLEFT", 0, 0)
        strip:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", 0, 0)
        strip:SetHeight(FOOTER_H)
        row.footerStrip = strip

        -- ☠ A BOTTOM-CORNERS-ONLY WASH, BUILT FROM THE TWO SHAPES Round.lua
        -- BAKES. The strip runs to the plate's bottom edge, so on a rounded plate
        -- its wash has to be square at the top (it meets the plate's interior)
        -- and curved at the bottom (it IS the plate's bottom edge). The generator
        -- bakes all-four and top-two only, and the first attempt at this dodged
        -- the problem by insetting the wash 4px off the arc -- which read in game
        -- as a floating bar sitting inside the plate rather than as the plate's
        -- own foot.
        --
        -- So the missing shape is made from the ones that exist: a CLIP frame the
        -- strip's own height holding an ALL-FOUR-corners surface that is
        -- M.stripArc taller and anchored to the clip's BOTTOM. The clip cuts the
        -- overhang off, and the top curve goes with it. Square top, round bottom,
        -- flush, full width.
        --
        -- ☠ THE CLIP IS SIZED BEFORE THE SHAPE GOES IN IT. SetClipsChildren
        -- clips at the frame's own RECT, and a holder anchored inside a clip with
        -- no resolved height is measured against nothing -- the surface would be
        -- stretched over a zero rect and never appear.
        --
        -- ⚠ AND NEITHER FRAME TAKES THE MOUSE, said out loud rather than left to
        -- the default. Both lie over the strip, the strip lies over the plate,
        -- and the whole row is the click target -- a mouse-enabled frame anywhere
        -- in that stack is the "anything drawn over a control eats its clicks"
        -- bug this rework has shipped twice.
        stripFill = strip:CreateTexture(nil, "BACKGROUND")
        stripFill:SetPoint("TOPLEFT", strip, "TOPLEFT", 0, -1)
        stripFill:SetPoint("BOTTOMRIGHT", strip, "BOTTOMRIGHT", 0, 0)

        stripClip = CreateFrame("Frame", nil, strip)
        stripClip:SetPoint("TOPLEFT", strip, "TOPLEFT", 0, -1)
        stripClip:SetPoint("BOTTOMRIGHT", strip, "BOTTOMRIGHT", 0, 0)
        stripClip:SetHeight(FOOTER_H - 1)
        stripClip:EnableMouse(false)
        if stripClip.SetClipsChildren then stripClip:SetClipsChildren(true) end
        -- ☠ THE WASH DRAWS UNDER THE STRIP'S OWN REGIONS, AND THAT NEEDS SAYING WITH A
        -- LEVEL. The count, the cog and the chevron are regions ON `strip`; this clip
        -- and the rounded shape inside it are child FRAMES of `strip`, and a child
        -- frame's textures draw above every region of its parent whatever layer the
        -- region asked for. Left at its default (strip + 1) the wash painted straight
        -- over "3 more settings" -- in game the text read as nearly black, and it
        -- looked like a colour problem when it was an order problem. At the PLATE's
        -- level the clip still draws above the plate's fill (same level, created
        -- later) and now below the strip's regions (strip is plate + 1).
        --
        -- ⚠ RE-ASSERTED in _ApplyStripShape, not set once: anything that re-levels
        -- the plate later would otherwise leave the clip stranded underneath it --
        -- the standing lesson of section 15 of the designer rework.
        -- The strip's own level is STATED, not inherited: the client would give a
        -- child plate + 1 by default, but a relationship the whole fix depends on
        -- should be in the code, not in a default -- and the headless shim does
        -- not model the default at all, so without this line the test that pins
        -- "clip below strip" could not be written.
        strip:SetFrameLevel(plate:GetFrameLevel() + 1)
        stripClip:SetFrameLevel(plate:GetFrameLevel())
        row._stripClip = stripClip

        stripShape = CreateFrame("Frame", nil, stripClip)
        stripShape:SetHeight(FOOTER_H - 1 + M.stripArc)
        stripShape:EnableMouse(false)
        row._stripShape = stripShape

        row._ApplyStripShape = function()
            local s = row._surface
            -- ☠ BOTH ARMS ARE SWITCHED BY ONE PAIR OF CALLS, not by each arm
            -- hiding the other's. A shape change runs this again, and "hide the
            -- one I am not" leaves whichever was never shown in the first place
            -- looking correct while the toggle that would have moved it does
            -- nothing -- exactly the kind of state a Hide/Show pair per branch
            -- grows. One condition, both frames, every time.
            stripFill:SetShown(s == nil)
            stripClip:SetShown(s ~= nil)
            strip:SetFrameLevel(plate:GetFrameLevel() + 1)
            stripClip:SetFrameLevel(plate:GetFrameLevel())
            if not s then
                -- Square plate, square strip: one flat quad, flush, full width.
                if stripSurface then stripSurface:Hide() end
                return
            end
            -- ⚠ INSET BY THE PLATE'S OWN BORDER WEIGHT, and by nothing else. The
            -- plate's ring is a texture on the PLATE and the strip is a child
            -- frame over it, so a wash run right to the edge would paint out the
            -- plate's bottom border. One border width back is the border itself,
            -- not the 4px clearance that made this read as a floating bar.
            local bw = s.rowBorderWidth or s.borderWidth or 0
            stripShape:ClearAllPoints()
            stripShape:SetPoint("BOTTOMLEFT", stripClip, "BOTTOMLEFT", bw, bw)
            stripShape:SetPoint("BOTTOMRIGHT", stripClip, "BOTTOMRIGHT", -bw, bw)
            stripShape:SetHeight(FOOTER_H - 1 + M.stripArc - bw)
            stripSurface = UI:CreateRoundedSurface(stripShape, {
                radius = s.radius,
                -- NO RING. The plate already draws one round the whole row and a
                -- second traced up the strip's own sides would double it.
                border = false,
                fill   = { C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, M.footerFill },
            })
            stripSurface:Show()
        end
        row._ApplyStripShape()
        -- The hairline that parts the strip from the plate. Full width in both
        -- shapes: it sits FOOTER_H up from the plate's bottom, which is clear of
        -- any radius the kit bakes.
        stripLine = strip:CreateTexture(nil, "BORDER")
        stripLine:SetPoint("TOPLEFT", strip, "TOPLEFT", 0, 0)
        stripLine:SetPoint("TOPRIGHT", strip, "TOPRIGHT", 0, 0)
        stripLine:SetHeight(1)
        -- Published for the reason the cells are: the strip's look is only
        -- observable as the colours these two were handed.
        row._stripFill, row._stripLine = stripFill, stripLine

        -- ONE PAINT PATH FOR TWO SHAPES, exactly as paintPlate is for the plate:
        -- the state paint computes four numbers and must not know whether it is
        -- tinting a quad or a nine-sliced surface.
        row._PaintStrip = function(r, g, b, a)
            if row._surface and stripSurface then stripSurface:SetFillColor(r, g, b, a)
            else stripFill:SetColorTexture(r, g, b, a) end
        end

        -- The words. "N MORE settings" is the honest count once some of the
        -- group is on the plate: opts.count is what the PANE holds, and every
        -- hoisted control is one of those shown a second time here -- so what is
        -- left behind the click is the count less whatever this row is currently
        -- showing. Fold the lines away and the number goes back up on its own.
        stripCount = host:CreateLabelNative(strip, { size = M.badgeSize, color = C_TEXT_DIM })
        if stripCount.SetJustifyH then stripCount:SetJustifyH("RIGHT") end
        if stripCount.SetWordWrap then stripCount:SetWordWrap(false) end
        row.stripCount = stripCount

        -- ☠ THE CLUSTER MOVES; IT IS NOT REBUILT. The gear and the chevron are
        -- the same two textures the title line carried, re-anchored onto the
        -- strip -- so the row's own Refresh goes on fading them with the toggle
        -- and there is no second pair to keep in step. Right-aligned in the same
        -- order and at the same gaps they had up there: cog, count, chevron.
        chevron:ClearAllPoints()
        chevron:SetPoint("RIGHT", strip, "RIGHT", -M.padX, 0)
        stripCount:SetPoint("RIGHT", chevron, "LEFT", -M.colGap, 0)
        gear:ClearAllPoints()
        gear:SetPoint("RIGHT", stripCount, "LEFT", -M.colGap, 0)

        -- ...and the count PILL goes, because the words replace it. Which
        -- rehouses the modified tick, whose whole argument was "a mark on the
        -- chip that says how much is in here".
        --
        -- ☠ NOT ON THE COG. The first try notched it on the cog's top-right
        -- corner, on the reading that the cog is what says "how much is in here"
        -- now -- and in game the 5px dot landed ON the 14px glyph and read as a
        -- smudge on it. The two are the same size class; a NOTCH needs something
        -- bigger than itself to be notched on, which the pill was and the cog is
        -- not. So it goes after the CHEVRON at the strip's far right: the end of
        -- the way-in cluster, touching none of it, and still unambiguously about
        -- the group's contents rather than about the row's name or its value.
        badgePill:Hide()
        modTick:SetParent(strip)
        modTick:ClearAllPoints()
        modTick:SetPoint("LEFT", chevron, "RIGHT", M.modTickGap, 0)
    end

    -- ---- the control lines ----------------------------------------
    -- One CELL per hoisted control, in two tiers: the name across the cell's
    -- full width, the control across the cell's full width beneath it. Cells on
    -- a line are equal and every row indents to the same LABEL_X, which is the
    -- whole of "the tracks start and end at the same x down the page" -- the
    -- argument the four right-hand columns above are fixed for, one axis over.
    local hoists = nil             -- the declarations, in the order they were given
    local hoistCells = nil         -- the cell frames, one per declaration
    local shownHoists = 0          -- how many are drawn RIGHT NOW (the gate, the fold)

    -- What is left BEHIND the click: the pane's count, less whatever this row is
    -- currently showing on its own plate. Written from the LAYOUT rather than
    -- only from the refresh, because the fold and the split move it and a window
    -- drag runs the layout alone -- a count that only followed a refresh would
    -- go on claiming three while five sit behind the click.
    local function paintStripCount()
        if not stripCount then return end
        if not row._count then stripCount:SetText("") return end
        local left = max(row._count - shownHoists, 0)
        local fmt = L and L["%d more settings"]
        stripCount:SetText(format(fmt or "%d", left))
    end

    -- ---- the summary ------------------------------------------------
    -- ☠ THE SUMMARY IS TOLD WHAT THE PLATE IS ALREADY SHOWING. A Frame Size row
    -- that hoists width and height was still printing "125x64 · Spacing 2" on
    -- the title line while 125 and 64 sat in the controls directly beneath it --
    -- the row saying the same thing twice and spending its one line of detail on
    -- the half the user can already read. So the consumer's summary function
    -- takes a SECOND argument: the set of keys currently on the plate, or nil
    -- when there are none. A consumer that ignores it gets exactly what it got
    -- before, which is what every unconverted page does.
    --
    -- ⚠ RE-PAINTED FROM THE LAYOUT, not only from the refresh. The set moves
    -- when a line folds, splits or gates -- a window drag runs the layout alone,
    -- and a summary that only followed a refresh would go on hiding a number
    -- that had just left the plate. Guarded on the toggle having been read at
    -- least once: construction lays out before its first Refresh, and `on` is
    -- what decides between the summary and the off text.
    local function paintSummary()
        if row._toggledOn == nil then return end
        local text
        if row._toggledOn then
            -- ☠ A STRIP ROW PAINTS NO SUMMARY WHEN IT IS ON. On the title line, a
            -- fragment like "Spacing 2" or "Alpha 0.30 · Combat 1.00" stands alone
            -- in the corner with nothing to explain it, and in game it read as
            -- out of place ("makes no sense on its own"). The controls beneath say
            -- what the row is, and the strip says there is more. The one word
            -- that DOES earn the corner is "Off" -- the else arm below -- because
            -- a switched-off row has nothing beneath it to say so.
            --
            -- ⚠ Keyed on the STRIP, not on the hoists: a strip row with nothing
            -- hoisted (Frame Fade) was showing "Alpha 0.30 · Combat 1.00" and is
            -- the row the feedback named. Rows without a strip -- every other page
            -- -- keep their summary, byte for byte.
            if strip then
                text = ""
            else
                local shown = (shownHoists > 0) and row._shownKeys or nil
                text = opts.summary and opts.summary(resolveDB(opts.db), shown) or ""
            end
        else
            text = offText
        end
        summary:SetText(text or "")
    end

    -- Is this control's feature switched on? A control for a feature that is OFF
    -- is never hoisted -- an inert track on the plate says the feature is there
    -- to tune when it is not doing anything at all.
    local function hoistVisible(h, db)
        if type(h.visible) ~= "function" then return true end
        local ok = h.visible(db)
        return ok and true or false
    end

    -- ---- the plate's own size, and everything anchored inside it ----
    --
    -- ☠ ONE FUNCTION, RE-RUN, RATHER THAN ARITHMETIC DONE ONCE AT BUILD. Three
    -- things move it: the row's WIDTH (a narrow window splits a two-cell line
    -- into two one-cell lines and, at the floor, folds them away entirely), the
    -- GATE on any hoisted control, and the declaration itself, which arrives
    -- after the row has already been added to its band. Each of those has to
    -- re-report the row's height to the layout that is holding a slot for it.
    local function plateLayout()
        if not (strip or hoists) then return end

        local db = resolveDB(opts.db)

        -- The width available to a control line: the plate, less the name
        -- indent on the left and the plate's own padding on the right. DERIVED
        -- FROM THE PLATE rather than read off a cell -- at build the cells have
        -- no resolved width and would answer 0.
        local plateW = plate:GetWidth() or 0
        if not plateW or plateW <= 0 then plateW = row:GetWidth() or 0 end
        if not plateW or plateW <= 0 then plateW = UI.PopoutContentWidth or 260 end
        local lineW = plateW - LABEL_X - M.padX

        -- Two cells, one, or none. NEVER three: three minimum controls and two
        -- gaps do not fit the plate at any window size the shell allows.
        --
        -- ☠ TWO DIFFERENT THRESHOLDS, and they are not interchangeable. SPLIT is
        -- generous (a pair is only worth having while each half is still a
        -- draggable control), FOLD is the hard floor (below it there is no
        -- control left to draw at all). One number doing both would either split
        -- rows that had plenty of room or leave 40px stubs on a narrow window --
        -- see Theme.lua's splitCell.
        local perLine = 0
        if lineW >= 2 * SPLIT_CELL + CELL_GAP then perLine = 2
        elseif lineW >= MIN_CONTROL then perLine = 1 end

        -- Which declarations are drawable at all, in declaration order.
        local live = {}
        for i, h in ipairs(hoists or {}) do
            if hoistCells[i] and hoistVisible(h, db) then live[#live + 1] = i end
        end
        -- THE FOLD. Below the width where a line cannot hold one named control,
        -- the row goes back to its title line and its summary -- today's row --
        -- and the strip's count goes back up by what it was showing.
        if perLine == 0 then live = {} end

        shownHoists = #live
        -- WHICH KEYS ARE ON THE PLATE, as a set the consumer's summary reads so
        -- it can leave out what the user can already see. Rebuilt here rather
        -- than derived at paint time because the fold, the split and the gate all
        -- move it, and re-used rather than re-allocated -- this runs on every
        -- refresh and on every window drag.
        local keys = row._shownKeys
        if not keys then keys = {}; row._shownKeys = keys end
        for k in pairs(keys) do keys[k] = nil end
        for _, idx in ipairs(live) do
            local key = hoists[idx] and hoists[idx].key
            if type(key) == "string" then keys[key] = true end
        end
        local lines = (perLine > 0) and ceil(shownHoists / perLine) or 0
        local cellW = (perLine == 2) and floor((lineW - CELL_GAP) / 2) or lineW

        -- ⚠ THE CELLS ARE ONLY RE-PLACED WHEN THEIR PLACEMENT CHANGED. This runs
        -- on every refresh -- and a refresh is cheap only if it does nothing when
        -- nothing moved. The signature is exactly what the placement below is a
        -- function of: which declarations are live, in what order, at what cell
        -- width. The plate's own height still falls through, because the gate may
        -- have moved it without moving a cell.
        local sig = cellW .. "|" .. perLine .. "|" .. table.concat(live, ",")
        if sig ~= row._hoistSig then
            row._hoistSig = sig
            for i = 1, #(hoists or {}) do
                local cell = hoistCells[i]
                if cell then cell:Hide() end
            end
            for n, idx in ipairs(live) do
                local cell = hoistCells[idx]
                local lineN = ceil(n / perLine)
                local col   = (n - 1) % perLine
                cell:SetSize(cellW, LINE_H)
                cell:ClearAllPoints()
                cell:SetPoint("TOPLEFT", plate, "TOPLEFT",
                              LABEL_X + col * (cellW + CELL_GAP),
                              -(HEAD_H + (lineN - 1) * LINE_H))
                -- The control gets the WHOLE cell, because the name is above it
                -- rather than beside it. Re-sized here because the cell's width
                -- is the thing that just changed.
                local h = hoists[idx]
                if h.control then
                    h.control:SetSize(max(cellW, 1),
                                      (h.kind == "slider") and M.sliderH or M.dropdownH)
                end
                -- ☠ THE HOVER HIT IS RE-SEATED WITH THE CELL, for the two reasons
                -- anything built once has to be. Its WIDTH is the words, not the
                -- lane: the name FontString is stretched across the whole cell so
                -- it truncates, so its rect is no guide to how much of the row's
                -- click target a hole would cost -- the string's own width is, and
                -- the cell width just moved. Its LEVEL is relative to the name
                -- tier it now hangs off rather than to the control it came from,
                -- and is re-stated here because this is the pass that re-places
                -- every cell.
                --
                -- ⚠ rawget, the convention this file already uses for a private
                -- field that may be absent: a headless frame answers an unset key
                -- with a no-op FUNCTION, so a plain read is truthy on every cell
                -- that was built without a hit and the block below would index it.
                local hit = h.control and rawget(h.control, "dfTooltipHit")
                if hit and h.nameBox and h.nameText then
                    local w = h.nameText.GetStringWidth and h.nameText:GetStringWidth() or 0
                    hit:ClearAllPoints()
                    hit:SetPoint("TOPLEFT", h.nameBox, "TOPLEFT", 0, 0)
                    hit:SetPoint("BOTTOMLEFT", h.nameBox, "BOTTOMLEFT", 0, 0)
                    hit:SetWidth(max(min(w, cellW), 1))
                    hit:SetFrameLevel((h.nameBox:GetFrameLevel() or 0) + 1)
                end
                cell:Show()
            end
        end

        -- ---- the plate, and the row's slot ---------------------------
        -- LINE_PAD is air under the LAST control line only -- a row showing none
        -- is its title line and its strip and nothing between them, which is what
        -- makes a bare strip row visibly shorter than a hoisted one rather than
        -- carrying a hoisted row's slack for nothing.
        local plateH = HEAD_H + lines * LINE_H
                     + ((lines > 0) and LINE_PAD or 0)
                     + (strip and FOOTER_H or 0)
        local headDY = (plateH - HEAD_H) / 2
        if plate:GetHeight() ~= plateH then plate:SetHeight(plateH) end

        -- ☠ EVERY REGION ON THE TITLE LINE TAKES THE SAME y, or two of them
        -- disagree about where the middle is. They are anchored LEFT/RIGHT --
        -- i.e. by their VERTICAL MIDDLE -- to the plate, and the plate's middle
        -- is no longer the title line's once anything is drawn under it. One
        -- offset, applied to all of them, keeps the constraints consistent by
        -- construction (see section 24 of the rework log for what two vertical
        -- constraints that disagree actually do to a frame).
        if headDY ~= (row._headDY or 0) then
            row._headDY = headDY
            if cb then
                cb:ClearAllPoints()
                cb:SetPoint("LEFT", plate, "LEFT", M.padX, headDY)
            end
            label:ClearAllPoints()
            label:SetPoint("LEFT", plate, "LEFT", LABEL_X, headDY)
            summary:ClearAllPoints()
            summary:SetPoint("LEFT", label, "RIGHT", M.colGap, 0)
            if strip then
                -- The cluster is on the strip, so the summary runs to the
                -- plate's own padding instead of stopping at the gear.
                summary:SetPoint("RIGHT", plate, "RIGHT", -M.padX, headDY)
            else
                summary:SetPoint("RIGHT", gear, "LEFT", -M.colGap, 0)
                chevron:ClearAllPoints()
                chevron:SetPoint("RIGHT", plate, "RIGHT", -M.padX, headDY)
            end
        end

        local slotH = plateH + M.gap
        -- ☠ THE FRAME'S HEIGHT IS RE-ASSERTED WHENEVER IT DISAGREES, and that is
        -- NOT the same test as the one below it. A layout pass may have set the
        -- row to whatever slot it was holding at the time; the row is the
        -- authority on how tall it is, so it says so again. Guarding both halves
        -- on `preferredHeight` alone let a stale frame height survive every later
        -- layout, because the number it is compared against was already right.
        if row:GetHeight() ~= slotH then row:SetHeight(slotH) end
        if row.preferredHeight ~= slotH then
            row.preferredHeight = slotH
            -- The layout pass reads `layoutHeight` off the widget; the group's
            -- own stored slot is corrected by RelayoutHost below. Both, because
            -- a row whose height changes AFTER it was added has to tell the
            -- thing already holding a slot for it -- the idiom the info banner
            -- and the designer canvas already use.
            row.layoutHeight = slotH
            if host.RelayoutHost then host:RelayoutHost(row, slotH) end
        end

        paintStripCount()
        -- ...and the summary, because what is on the plate is what it leaves out.
        paintSummary()
    end
    row._LayoutPlate = plateLayout

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
            paintPlate(accent.r, accent.g, accent.b,
                       row._hovered and M.activeHover or M.activeFill,
                       accent.r, accent.g, accent.b, M.activeBorder)
        else
            local f = row._hovered and C_HOVER or C_ELEMENT
            paintPlate(f.r, f.g, f.b,
                       row._hovered and M.hoverFill or M.restFill,
                       C_BORDER.r, C_BORDER.g, C_BORDER.b, M.restBorder)
        end
        -- OFF outranks ACTIVE on the label. A row with its feature switched off
        -- has nothing to be the subject of, open panel or not -- and an accent
        -- label over a dimmed summary would read as the opposite.
        local c = (not on) and C_TEXT_DIM or (active and accent or C_TEXT)
        label:SetTextColor(c.r, c.g, c.b, 1)

        -- THE STRIP IS THE WAY IN, SO IT SAYS SO IN THE ACCENT. At rest it is a
        -- hole in the plate (the count pill's own idiom, spread along the bottom
        -- edge) with the cluster in the accent; when this row's panel is open it
        -- LIGHTS -- an accent wash, brighter than the plate's, and the beam
        -- leaves its right end because the strip is the panel's tether.
        if stripFill then
            if active then
                row._PaintStrip(accent.r, accent.g, accent.b, M.footerOn)
                stripLine:SetColorTexture(accent.r, accent.g, accent.b, M.activeBorder)
            else
                row._PaintStrip(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, M.footerFill)
                stripLine:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, M.footerBorder)
            end
            stripCount:SetTextColor(accent.r, accent.g, accent.b, on and 1 or OFF_ALPHA)
        end
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
    --
    -- ☠ A {db, key} TOGGLE IS A SETTING, AND SETTINGS GO THROUGH THE HOST'S
    -- SETTING HOOKS. Every other db-bound widget in the kit brackets its write
    -- with interceptWrite / onSettingWritten (Widgets.lua: the slider's
    -- OnValueChanged, the dropdown menu button's OnClick, the align grid's
    -- WriteKey), because a consumer may be running a RUNTIME OVERLAY -- where the
    -- write belongs to a baseline table rather than the live one -- or EDITING a
    -- layout, where the write also has to be recorded as an override. This row's
    -- tick used to write the key bare, so a tick and an ordinary checkbox bound to
    -- the SAME key disagreed: half the consumer's own panel honoured its overlay
    -- and half of it wrote straight through. One key, one write path.
    --
    -- A {get, set} toggle is NOT the kit's db to gate -- set() IS the consumer's
    -- write path, and it is left entirely alone.
    function row._Write(v)
        v = v and true or false
        local t = opts.toggle
        if t then
            if t.set then safeCall(t.set, v)
            else
                local tdb = resolveDB(t.db or opts.db)
                if tdb and t.key then
                    if host:Call("interceptWrite", tdb, t.key, v) then
                        -- REDIRECTED: the live value did not change, so neither
                        -- the write nor onToggle happens -- exactly what the
                        -- slider and the dropdown do (they return before their
                        -- callback) and what the align grid spells out as
                        -- `if liveWrite and callback`. The Refresh still runs:
                        -- the tick has already moved ITSELF by the time it gets
                        -- here, and only a re-read puts it back on the live value.
                        row.Refresh()
                        return
                    end
                    tdb[t.key] = v
                    -- The row's title names the tick: the toggle has no label of
                    -- its own (it IS the row), so the row's own heading is the
                    -- only thing a consumer could show for it. `onToggle` is
                    -- this row's COMMIT -- the exact function the line below
                    -- runs -- and it rides along as the fifth argument so a host
                    -- replaying the edit (an undo stack) can run the apply and
                    -- not just the write.
                    host:Call("onSettingWritten", tdb, t.key, v, row._title, opts.onToggle)
                end
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
        -- were still doing them. (The body is shared with the layout pass -- see
        -- paintSummary: a fold or a gate changes what the summary may leave out
        -- without anything having refreshed.)
        paintSummary()

        -- The modified tick rides the SUMMARY's cadence, which is the point: a
        -- write inside the popout already repaints the row's summary, so the
        -- tick is live for free and cannot drift from what the row is reporting.
        -- Guarded on the CHECK, not on the texture -- a consumer that never
        -- declared one leaves the tick hidden for the row's whole life.
        --
        -- Painted whatever the toggle says. A group that is switched off still
        -- HOLDS non-default values, and hiding the mark there would say it had
        -- been reset. The row's own dim carries "not currently doing anything".
        if row._modified then modTick:SetShown(row._modified(db) and true or false) end

        -- ---- the hoisted controls ------------------------------------
        -- ☠ THE VALUES COME FROM HERE, NOT FROM CONSTRUCTION. A hoisted control
        -- is the panel's own setting shown a SECOND time -- same table, same key
        -- -- so the pane's twin, a group Reset, a hold and an undo all move it
        -- without this widget doing anything. re-reading on the row's own
        -- cadence is what makes "drag either and the other follows" true.
        --
        -- ⚠ THE SELF GOES IN. The kit's own factories alias their private
        -- repaints onto `refreshValue` and at least one of them USES its self
        -- (the checkbox's is `function(self) self:Refresh() end`), so a bare
        -- call would error on the day this row hoists one -- the same fallback
        -- chain ControlRow.lua spells out at its own RefreshValue.
        for _, h in ipairs(hoists or {}) do
            local w = h.control
            if w then
                if type(w.refreshValue) == "function" then safeCall(w.refreshValue, w)
                elseif type(w.RefreshValue) == "function" then safeCall(w.RefreshValue, w)
                elseif type(w.Refresh) == "function" then safeCall(w.Refresh, w) end
            end
        end
        -- ...and the GATE, which may have moved with the toggle that was just
        -- written: a control for a feature that is off is not drawn at all, and
        -- the row is that much shorter. Re-runs the fold and the split with it.
        plateLayout()

        -- Dependent-grey dims the WHOLE row, toggle included. Toggled-off dims
        -- only what the toggle governs -- so the tick you need to click to turn
        -- it back on never fades with everything it controls.
        row:SetAlpha(enabled and 1 or DIM_ALPHA)
        -- The plate and the label, in one place shared with the active repaint.
        paintState()
        summary:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, on and 1 or 0.7)
        if strip then
            -- ON THE STRIP THE CLUSTER IS THE WAY IN, and the way in is drawn in
            -- the accent -- cog, count and chevron together, so the strip reads
            -- as one object rather than as two grey glyphs either side of a
            -- coloured phrase. On the title line they stay the neutral glyphs
            -- they have always been.
            local acc = row._accent or host:GetAccent()
            gear:SetVertexColor(acc.r, acc.g, acc.b, on and 1 or OFF_ALPHA)
            chevron:SetVertexColor(acc.r, acc.g, acc.b, on and 1 or OFF_ALPHA)
            paintStripCount()
        else
            gear:SetVertexColor(1, 1, 1, on and 0.6 or OFF_ALPHA * 0.6)
            chevron:SetVertexColor(1, 1, 1, on and 0.5 or OFF_ALPHA * 0.5)
        end

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

    -- Declare (or withdraw) the modified check AFTER creation. Every other opt
    -- on this row is known at the call, and this one often is not: a consumer
    -- that derives the group's key set by WALKING the pane it just built has
    -- nothing to hand CreatePopoutRow at the moment it calls it. Repaints
    -- immediately, so a caller does not also have to remember a Refresh.
    function row:SetModifiedCheck(fn)
        row._modified = (type(fn) == "function") and fn or nil
        if not row._modified then modTick:Hide() end
        row.Refresh()
        return row
    end

    -- Declare (or withdraw) the popout's footer actions AFTER creation, for the
    -- reason SetModifiedCheck exists: a consumer whose verbs close over the
    -- group's key set has nothing to hand CreatePopoutRow at the moment it calls
    -- it -- that set is derived by walking the pane, which does not exist yet.
    -- Reaches every panel this row currently has open (a pinned one included,
    -- which is why the bound set is walked rather than just row.popout), so a
    -- late declaration lands on a panel that is already up.
    function row:SetActions(list)
        row._actions = (type(list) == "table") and list or nil
        for po in pairs(row._bound) do
            if po and not po.closed and po._boundRow == row and po.SetActions then
                po:SetActions(row._actions)
            end
        end
        return row
    end

    -- ---- the hoisted controls -------------------------------------
    --
    -- Declare the controls this row shows a SECOND time on its own plate. Each
    -- entry:
    --
    --   name      REQUIRED. The setting's own display name -- the SAME string
    --             the panel labels it with, already localised. Drawn in the
    --             cell's name tier, and handed to the embedded factory as its
    --             label so the tooltip, the override markers and the search
    --             index all name one thing
    --   kind      "slider" | "dropdown"
    --   db, key   the settings TABLE and the key inside it. The same pair the
    --             panel's own control is bound to -- that is what makes this a
    --             second WIDGET rather than a second copy of the value
    --   visible   fn(db) -> bool. False and the control is not drawn at all: a
    --             track for a feature that is switched off invites a tune that
    --             does nothing
    --   min/max/step/lightweight     forwarded to the slider
    --   options/optionsFunc          forwarded to the dropdown
    --   onChanged                    the panel's own apply for this key
    --   tooltip   the SAME spec the panel's own control carries -- one setting,
    --             one explanation. Its hover rides the cell's NAME, never the
    --             control; omit it and the cell builds no hover rect at all,
    --             which is the right answer for a setting the panel does not
    --             explain either
    --
    -- ☠ DECLARED AFTER THE ROW IS IN ITS BAND, which is why the layout below
    -- re-reports the height rather than assuming the slot it was given is still
    -- right. Same shape as SetModifiedCheck and SetActions and for the same
    -- reason: what a page can hand CreatePopoutRow at the moment it calls it is
    -- not everything the row ends up owning.
    function row:SetHoistedControls(list)
        if type(list) ~= "table" then return row end
        hoists, hoistCells = {}, {}
        -- ...and the layout's memo of what it last placed, or a second
        -- declaration with the same shape would keep the first one's cells.
        row._hoistSig = nil
        -- Published under the underscore convention -- private fields a consumer
        -- may READ (a driven test asks the plate what it laid out) and must not
        -- write. Same shape as row._bound and row._claimedKeys.
        row._hoists, row._hoistCells = hoists, hoistCells
        for _, h in ipairs(list) do
            if type(h) == "table" and type(h.name) == "string" then
                local n = #hoists + 1
                hoists[n] = h
                -- ☠ THE NAME LIVES IN A FRAME, NOT ON THE PLATE. A FontString is
                -- a region, not a frame -- so one created on a parent that a
                -- later pass moves frames out of is left behind and never drawn
                -- (the hidden-holder trap this rework has already been bitten
                -- by). The cell is a frame; the name goes in it, and the two
                -- move together for ever after.
                local cell = CreateFrame("Frame", nil, plate)
                cell:SetSize(SPLIT_CELL, LINE_H)
                hoistCells[n] = cell

                -- ☠ TWO TIERS: THE NAME ABOVE, THE CONTROL BENEATH. Beside the
                -- control the name had a fixed 62px lane and the panel's own
                -- labels did not fit it -- "FRAME WI...", "GROWTH DI..." -- while
                -- the control it stole the width from was left with 46px of live
                -- track. Above, the name has the cell's whole width and so does
                -- the control: the two things the row is for both get 172px
                -- instead of both getting neither.
                --
                -- Its OWN FRAME, with its OWN height, for the reason the cell is
                -- one: a bare FontString anchored inside a rect has no height of
                -- its own, and everything under it would be anchored to nothing.
                --
                -- ⚠ AND IT TAKES NO MOUSE. It lies directly above a control on a
                -- plate that is itself a click target -- the one place in this
                -- cell where an enabled frame would eat a drag.
                local nameBox = CreateFrame("Frame", nil, cell)
                nameBox:SetPoint("TOPLEFT", cell, "TOPLEFT", 0, 0)
                nameBox:SetPoint("TOPRIGHT", cell, "TOPRIGHT", 0, 0)
                nameBox:SetHeight(NAME_H)
                nameBox:EnableMouse(false)
                h.nameBox = nameBox

                local nameFS = host:CreateLabelNative(nameBox, { size = M.nameSize, color = C_TEXT_DIM })
                nameFS:SetText((h.name:upper()))
                nameFS:SetPoint("LEFT", nameBox, "LEFT", 0, 0)
                nameFS:SetPoint("RIGHT", nameBox, "RIGHT", 0, 0)
                -- LEFT, not the lane's RIGHT: a name over its control reads from
                -- the same edge the track starts at.
                if nameFS.SetJustifyH then nameFS:SetJustifyH("LEFT") end
                if nameFS.SetWordWrap then nameFS:SetWordWrap(false) end
                h.nameText = nameFS

                -- ⚠ dbRef OR get/set, NEVER BOTH -- Widgets.lua's slider and
                -- dropdown fire interceptWrite / onSettingWritten themselves
                -- whenever a dbKey is present, so passing both runs the host's
                -- setting hooks twice for one edit. ControlRow.lua states the
                -- same rule at its own binding.
                local dbRef = (type(h.db) == "table" and type(h.key) == "string")
                              and { db = h.db, key = h.key } or nil

                -- ☠ WHERE THE TOOLTIP'S HOVER RECT GOES, decided HERE and passed
                -- INTO the factory rather than fixed up afterwards. The factory
                -- builds it over the caption, and this cell hides the caption --
                -- on a slider that rect is the container's top 18px, which under
                -- the two tiers covers the name AND the top of the track; on an
                -- inline dropdown it is the opener itself. The name tier is the
                -- region that stands in for the caption here, so that is what the
                -- hover rides, and it is the ONE part of the cell with no control
                -- under it.
                --
                -- ⚠ THE PRICE IS A HOLE IN THE ROW'S OWN CLICK TARGET. The plate
                -- is a Button and a motion-taking child drops its hover paint for
                -- as long as the cursor is inside -- so the hit is narrowed to the
                -- WORDS in plateLayout (the lane is the whole cell width because
                -- the FontString is stretched across it to truncate), and it is
                -- only built for a declaration that actually carries a tooltip.
                -- No tooltip, no frame, no hole.
                --
                -- ☠ AND THE TIER MUST HAVE A RESOLVED HEIGHT before anything is
                -- anchored to both its corners; a zero-height frame silently puts
                -- the child somewhere else. nameBox is given NAME_H above, and
                -- this refuses rather than trusts.
                local nameH = nameBox:GetHeight() or 0
                local hitBox = (h.tooltip ~= nil and nameH > 0) and nameBox or nil

                local c
                if h.kind == "dropdown" then
                    -- `inline` hides the caption and lets the opener fill the
                    -- container, so the cell's own SetSize decides its size. The
                    -- label is PASSED and hidden rather than omitted: an empty
                    -- one registers the setting under no name at all.
                    c = host:CreateDropdownNative(cell, {
                        label       = h.name,
                        inline      = true,
                        options     = h.options,
                        optionsFunc = h.optionsFunc,
                        get         = (not dbRef) and h.get or nil,
                        set         = (not dbRef) and h.set or nil,
                        dbRef       = dbRef,
                        onChanged   = h.onChanged,
                        accent      = row._accent,
                        tooltip     = h.tooltip,
                        tooltipHit   = hitBox,
                        noTooltipHit = (hitBox == nil),
                    })
                    -- Centred in the CONTROL TIER, which starts under the name.
                    c:ClearAllPoints()
                    c:SetPoint("TOPRIGHT", cell, "TOPRIGHT", 0,
                               -(NAME_H + (CONTROL_H - M.dropdownH) / 2))
                elseif h.kind == "slider" then
                    c = host:CreateSliderNative(cell, {
                        label       = h.name,
                        min         = h.min, max = h.max, step = h.step,
                        get         = (not dbRef) and h.get or nil,
                        set         = (not dbRef) and h.set or nil,
                        dbRef       = dbRef,
                        onChanged   = h.onChanged,
                        lightweight = h.lightweight,
                        accent      = row._accent,
                        tooltip     = h.tooltip,
                        tooltipHit   = hitBox,
                        noTooltipHit = (hitBox == nil),
                    })
                    -- The factory has no `inline`, so its caption is hidden
                    -- after the fact -- ControlRow's move, for its reason.
                    if c.label then c.label:Hide() end
                    -- ☠ CENTRED BY THE BAR, NOT BY THE CONTAINER, and centred on
                    -- the CONTROL TIER rather than on the cell. See
                    -- M.sliderBarMid: the container's top 18px hold the caption
                    -- just hidden, so centring the container would park the
                    -- track low and leave dead space doing the balancing. The
                    -- tier's middle is NAME_H + CONTROL_H/2 below the cell's top,
                    -- which puts the 20px value box 2px clear of the name above
                    -- it and 2px clear of the cell's foot.
                    c:ClearAllPoints()
                    c:SetPoint("TOPRIGHT", cell, "TOPRIGHT", 0,
                               -(NAME_H + CONTROL_H / 2) + M.sliderBarMid)
                else
                    local dbg = host:Call("debug", "popoutrow")
                    if dbg then
                        dbg(format("%s: unknown hoisted control kind %s",
                                   tostring(h.name), tostring(h.kind)))
                    end
                end
                h.control = c
            end
        end
        -- The declaration is what changed the row's height, so the layout runs
        -- here rather than waiting for the next refresh.
        plateLayout()
        row.Refresh()
        return row
    end

    -- What the row is CURRENTLY showing on its plate. The strip's count is the
    -- pane's total less this, so a consumer's own tests can ask the row rather
    -- than re-deriving the fold.
    function row:GetShownHoistCount() return shownHoists end

    -- ---- the popout -----------------------------------------------

    function row:OpenPopout()
        -- Without a window there is nothing to dock OUTSIDE of, and docking
        -- beside the row would put the panel on top of the list it came from --
        -- which is the whole reason the outsideOf placement exists.
        if not row._window then return row end
        -- THE WHOLE CLICK, end to end: the adopt (or the build), the pane swap,
        -- the dock and the chrome. Every other mark in this pair of files
        -- decomposes this one, so a report that shows a slow open says in the
        -- same breath which part of it was slow. The raise below is a click too,
        -- and is booked under the same name.
        local t0 = perfStart(host)
        -- ALREADY OPEN ABOUT THIS ROW? Then this click means "show me that one",
        -- not "make me another" -- see ONE PANEL PER ROW. It goes through the
        -- same swap the ordinary open does, because the swap is what re-states
        -- the panel (the gate, the pane's measured height, the header, the
        -- footer's `enabled` verdicts) and every one of those may have moved
        -- since it was last bound. What it does NOT do is create anything: no
        -- adopt, no build, no dock, no entrance -- the panel is already all of
        -- that. It comes to the front of the stack, and pops once so the click
        -- reads as having done something.
        local up = livePanel(row)
        if up then
            swapTo(up, row)
            up:Raise(true)
            row.popout = up
            perfStop(host, "popoutrow:open", t0)
            return row
        end
        local po = host:CreatePopout({
            key     = row._key,
            title   = row._title,
            width   = UI.PopoutContentWidth,
            accent  = row._accent,
            -- ☠ FORWARDED, NOT LEFT TO THE HOST. The panel and the plate it
            -- comes out of are one object as far as the eye is concerned -- they
            -- share an accent, a beam and, now, an outline traced on the plate at
            -- the plate's own radius. A row that was handed an explicit style
            -- (the chrome workbench holding its Square baseline against a rounded
            -- host is the case that forces this) and a panel that resolved its
            -- own from the host would disagree about the shape of the thing they
            -- are both drawing.
            --
            -- `false` survives the trip intact: row._surface is nil for a square
            -- row, and nil would mean "ask the host" to the popout -- so it is
            -- spelled as an explicit false.
            surface = row._surface or false,
            -- FORWARDED like `surface`, and for the same reason: the panel is
            -- the row's, so the verbs at its foot are the row's. Re-read on
            -- every adopt, so the shared instance shows whichever row's actions
            -- last asked for it rather than the first row's forever.
            actions = row._actions,
            -- ☠ THE STRIP IS THE TETHER WHEN THERE IS ONE, AND THE ROW WHEN
            -- THERE IS NOT. The strip is the way in -- the cog, the count and a
            -- chevron pointing RIGHT at where the panel appears -- so the beam
            -- has to leave IT rather than the middle of a plate that may now be
            -- three lines tall. Reusing tetherSource rather than inventing a
            -- second anchor keeps the shell's three readers (the source outline,
            -- the beam and the clip gate) describing ONE rect, which is the
            -- contract _TetherRegion exists to hold. A strip declares no
            -- popoutInset, so its whole rect is ink -- which it is.
            tetherSource = strip or row,
            build   = mountBare,
            headerControls = function(p, bar) return buildHeaderControls(host, p, bar) end,
            onClose = function(p, reason) forgetInstance(host, p, reason) end,
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
        perfStop(host, "popoutrow:open", t0)
        return row
    end

    function row:ClosePopout(reason)
        local po = row.popout
        if po and not po.closed then po:Close(reason or "api") end
        row.popout = nil
        return row
    end

    -- ☠ THE ROW WENT AWAY UNDER ITS OWN PANEL. A section folding, or a hideOn
    -- flipping, takes the row off the page WITHOUT telling anything docked to it
    -- -- so the panel stayed up, and with it the outline traced on the row, the
    -- connection point and the beam. The row's slot is re-flowed the same frame,
    -- so that outline is now a bright accent rectangle lying across whatever
    -- moved up into the space. Reported in-game as "if a collapsible section
    -- collapses when something is popped out, it leaves a highlight overlapping
    -- other parts of the settings".
    --
    -- This is the kit's LAYOUT-HIDDEN contract (see UI:NotifyLayoutHidden in
    -- Sections.lua): whatever hides a widget as part of a layout says so, and the
    -- widget decides what that means. For a row it means every UNPINNED panel it
    -- has open closes -- a pinned one is detached by definition and stays.
    --
    -- The chrome comes down INSTANTLY rather than fading with the panel: the
    -- thing it was drawn on has already gone, so a 0.15s fade would be exactly
    -- the stray highlight this is here to remove, just briefer.
    row._OnLayoutHidden = function()
        for po in pairs(row._bound) do
            if po and not po.closed and not po.pinned and po._boundRow == row
               and po.HideChrome then
                po:HideChrome()
            end
        end
        closeLoosePanels(row, "source")
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

    -- Change the row's SHAPE, and take everything it is bound to with it. Same
    -- structure as SetAccent above and for the same reason: the row and the panel
    -- it opened are one object as far as the eye is concerned, so a change to
    -- either has to reach both while they are up.
    --
    -- The plate re-issues its chrome, the state paint REPLAYS through the new
    -- shape (applyPlateShape only writes the rest colours, so a hovered or ACTIVE
    -- plate would otherwise come back in the wrong one), the declared curve
    -- follows, and every bound panel -- a pinned one included, which is why the
    -- bound set is walked rather than just row.popout -- is re-shaped to match.
    --
    -- `false` forces square on a host that has opted in; nil hands the row back
    -- to whatever the host declares.
    function row:SetSurface(style)
        row._surface = UI.ResolveSurfaceStyle(host, style)
        applyPlateShape()
        -- The strip's wash clears the plate's arc by a margin taken FROM the
        -- radius, so a shape change moves it too.
        if row._ApplyStripShape then row._ApplyStripShape() end
        row.Refresh()
        for po in pairs(row._bound) do
            if po and not po.closed and po.SetSurface then
                -- Spelled false, not nil: nil means "ask the host" to the popout,
                -- and the host may be the one this row is overriding.
                po:SetSurface(row._surface or false)
            end
        end
        return row
    end

    function row:GetSurface() return row._surface end

    -- ---- interaction ----------------------------------------------
    -- ☠ THE SPLIT AND THE FOLD ARE FUNCTIONS OF THE ROW'S WIDTH, so the row has
    -- to be told when that changes. Installed ONLY on a row that draws something
    -- under its title line -- a plain row's geometry does not depend on its
    -- width, and an OnSizeChanged it never had is a script every other page's
    -- rows would start running for nothing.
    --
    -- ⚠ RE-ENTRANT BY CONSTRUCTION: plateLayout sets the row's HEIGHT, which
    -- fires this again. Guarded on the width actually having moved, which the
    -- height change cannot do.
    if opts.footerStrip then
        row:SetScript("OnSizeChanged", function(self, w)
            w = w or self:GetWidth()
            if w == row._laidOutAt then return end
            row._laidOutAt = w
            plateLayout()
        end)
    end

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
