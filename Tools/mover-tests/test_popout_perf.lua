local NS = ...

-- ============================================================
-- WHAT ONE OPEN COSTS -- DandersUI/Popout.lua + PopoutRow.lua
-- ------------------------------------------------------------
-- Danders, after fourteen pages had been converted to popout rows: "sometimes
-- when clicking to popout the menu, there is a stutter and freeze when it pops
-- out or closes." Intermittent, because it is not a cost of the open -- it is a
-- cost of everything opened BEFORE it.
--
-- ONE panel serves every row on a host. Each row's pane is built once and then
-- KEPT under the same mount: an unpinned panel is POOLED on close, not
-- destroyed, so the mount's children are every group the user has opened on
-- every page since login. The shell's accent cascade walked that whole pile on
-- every open, twice -- once from adopt() and again from the row's bind. Measured
-- here before the fix, on 14 rows of 8 controls:
--
--     open #1   getChildren= 27   applyThemeColor= 11
--     open #7   getChildren=143   applyThemeColor=106
--     open #14  getChildren=283   applyThemeColor=218
--     re-open   getChildren=292   applyThemeColor=226   <- and it never comes down
--
-- ...and 2 full chrome re-issues and 2 footer re-layouts per open for a colour,
-- a shape and a strip that had not moved.
--
-- WHAT IS PINNED HERE, and the first claim is the whole point:
--
--   1. A RE-OPEN COSTS THE SAME WHATEVER IS ALREADY BUILT. Asserted as an
--      EQUALITY between a page of 2 rows and a page of 12, not against a
--      remembered number -- a constant would go stale the first time the shell
--      grew a frame, and the claim is about the SHAPE of the cost, not its size.
--   2. THE PANE THAT IS UP IS THE PANE THAT IS PAINTED, and the ones that are
--      not looking catch up on the swap that shows them. That is the bargain the
--      speed is bought with, so it is tested harder than the speed is.
--   3. NO PAINT WITHOUT A CHANGE -- chrome, footer strip -- and a real change
--      still paints. Both halves, because a compare-before-paint that never
--      paints is not faster, it is broken.
-- ============================================================
local UI = NS.__DandersUI

-- ---- what the other popout suites would have installed -------------
-- Guarded throughout, for the reason test_popout_footer.lua gives at its own
-- copy: `run.py popout_perf` on its own has to work, and on a full run the
-- suites before this one already own these on the shared table.
UI.MEDIA = UI.MEDIA or ""
UI.Colors = UI.Colors or { text = { r = 0.9, g = 0.9, b = 0.9 },
                           textDim = { r = 0.5, g = 0.5, b = 0.5 } }
UI.Colors.panel      = UI.Colors.panel      or { r = 0.12, g = 0.12, b = 0.12 }
UI.Colors.element    = UI.Colors.element    or { r = 0.18, g = 0.18, b = 0.18, a = 1 }
UI.Colors.border     = UI.Colors.border     or { r = 0.25, g = 0.25, b = 0.25, a = 1 }
UI.Colors.hover      = UI.Colors.hover      or { r = 0.22, g = 0.22, b = 0.22, a = 1 }
UI.Colors.background = UI.Colors.background or { r = 0.08, g = 0.08, b = 0.08, a = 0.95 }
UI.Colors.notice     = UI.Colors.notice     or { r = 0.91, g = 0.66, b = 0.25, a = 1 }
if not UI.GetAccent then
    local A = { r = 0.45, g = 0.45, b = 0.95, a = 1 }
    function UI:GetAccent() return A end
end
if not UI.CreatePanelBackdrop then
    function UI:CreatePanelBackdrop(frame, opts) frame._panelOpts = opts return frame end
end
if not UI.ApplyPixelBorder then
    function UI:ApplyPixelBorder(frame, color) frame._pxColor = color return frame end
end
if not UI.CreateElementBackdrop then
    function UI:CreateElementBackdrop(frame, opts) frame._elementOpts = opts return frame end
end
if not UI.CreateLabel then
    function UI:CreateLabel(_, opts)
        local fs = FakeUIFrame()
        if opts and opts.text then fs:SetText(opts.text) end
        return fs
    end
end
UI.CreateLabelNative = UI.CreateLabelNative or UI.CreateLabel
if not UI.CreateCloseButton then
    local function stubButton(opts)
        local b = FakeUIFrame(16, 16)
        b._opts = opts
        b:Show()
        return b
    end
    function UI:CreateCloseButton(_, opts) return stubButton(opts) end
    function UI:CreateGlyphButton(_, opts) return stubButton(opts) end
end
if not UI.Hook then
    function UI:Hook(name)
        local h = rawget(self, "hooks")
        return h and h[name] or nil
    end
    function UI:Call(name, ...)
        local fn = self:Hook(name)
        if not fn then return nil end
        return fn(...)
    end
end

-- ---- Theme.lua metrics ---------------------------------------------
-- Mirrors of the real values, for the reason the other popout suites spell out:
-- Theme.lua is not loadable headless and both modules read these at FILE SCOPE.
UI.RowGap = UI.RowGap or 14
UI.RowHeight = UI.RowHeight or { checkbox = 35 }
UI.PopoutContentWidth = UI.PopoutContentWidth or 260
UI.PopoutTitle = UI.PopoutTitle or { topPad = 6, row = 28, fill = 0.9, sepAlpha = 0.8 }
UI.PopoutTitleHeight = UI.PopoutTitleHeight or (UI.PopoutTitle.topPad + UI.PopoutTitle.row)
UI.PopoutPad = UI.PopoutPad or 10
UI.PopoutFooter = UI.PopoutFooter or { height = 26, btnHeight = 18, gap = 6, sepAlpha = 0.8 }
UI.StyleScrollBar = UI.StyleScrollBar or function(sf) sf._styledScrollBar = true end
UI.PopoutRow = UI.PopoutRow or {
    plate = 44, gap = 6, padX = 10, labelGap = 10, colGap = 6,
    check = 16, checkTick = 9, gear = 14, chevron = 10,
    badgeW = 22, badgeH = 16, modTick = 5,
    labelSize = 12, summarySize = 11, badgeSize = 10,
    restFill = 0.55, hoverFill = 0.75, restBorder = 0.5,
    activeFill = 0.14, activeHover = 0.20, activeBorder = 1,
    badgeFill = 0.55, badgeBorder = 0.45,
}
UI.PopoutRow.slot = UI.PopoutRow.plate + UI.PopoutRow.gap
local M = UI.PopoutRow

-- ---- the counters --------------------------------------------------
-- Everything below is measured as a CALL COUNT rather than as a duration. A
-- headless run has no frames to draw and no wall time worth reading; what it can
-- answer exactly is "how many times was the expensive thing asked for", which is
-- the number that was growing.
local N = {}
local function bump(k) N[k] = (N[k] or 0) + 1 end
local function reset() N = {} end
local function got(k) return N[k] or 0 end

-- ---- WoW globals ----------------------------------------------------
local prevCreateFrame, prevTimer = CreateFrame, C_Timer
local prevPlaySound, prevSoundKit = PlaySound, SOUNDKIT
PlaySound = function() end
SOUNDKIT = { IG_MAINMENU_OPTION_CHECKBOX_ON = 1 }

-- ☠ A MISSING DATA FIELD MUST READ nil, NOT A FUNCTION -- the rule
-- test_popout_row.lua states at its own stub. `popout` is a documented part of
-- the row's contract and `dfDisabled` gates every footer press.
local function dataAwareMeta(k)
    if k == "popout" or k == "popoutRadius" or k == "dfDisabled" then return nil end
    if type(k) == "string" and k:byte(1) == 95 then return nil end   -- "_"
    return function() end
end

CreateFrame = function(kind, _, parent)
    local f = FakeUIFrame()
    setmetatable(f, { __index = function(_, k) return dataAwareMeta(k) end })
    f._kind = kind
    f._children = {}
    f._parent = parent
    f.GetParent = function(self) return self._parent end
    f.SetParent = function(self, p) self._parent = p end
    f.GetNumChildren = function(self) return #self._children end
    -- THE MEASUREMENT. One call per node the accent cascade descends into, which
    -- is the walk this whole file is about.
    f.GetChildren = function(self)
        bump("getChildren")
        return unpack(self._children)
    end
    if kind == "CheckButton" then
        f.SetChecked = function(self, v) self._checked = v and true or false end
        f.GetChecked = function(self) return self._checked end
    end
    if type(parent) == "table" then
        local kids = rawget(parent, "_children")
        if not kids then kids = {}; parent._children = kids end
        kids[#kids + 1] = f
    end
    return f
end
C_Timer = { After = function(_, fn) fn() end }

local CX, CY = 960, 540
local L = setmetatable({}, { __index = function(_, k) return k end })

-- ---- the host -------------------------------------------------------
-- Every counting stub goes on the HOST, not on the shared library table: both
-- modules reach these through `self.host:` / `host:`, so a field here wins and
-- the suites either side of this one see the table exactly as they left it.
local host = setmetatable({ hooks = { L = L } }, { __index = UI })

function host:CreatePanelBackdrop(frame, opts)
    bump("paintChrome")
    frame._panelOpts = opts
    return frame
end
function host:ApplyPixelBorder(frame, color) frame._pxColor = color return frame end
function host:CreateButton(parent, opts)
    opts = opts or {}
    local b = FakeUIFrame(opts.width or 100, opts.height or 22)
    setmetatable(b, { __index = function(_, k) return dataAwareMeta(k) end })
    b._parent = parent
    b._opts = opts
    b.dfDisabled = false
    -- The footer's re-layout is only observable through what it writes, and the
    -- label is the one write that happens for every button on every render.
    b.SetText = function(s, t) bump("footerSetText"); s._text = t end
    b.SetDisabled = function(s, d) s.dfDisabled = d and true or false end
    b:Show()
    return b
end
host.CreateButtonNative = host.CreateButton
function host:ShowTooltip() end
function host:HideTooltip() end
function host:StyleCheckButton(cb, opts)
    opts = opts or {}
    cb:SetSize(opts.size or 18, opts.size or 18)
    cb.Check = cb.Check or FakeUIFrame()
    cb.ApplyThemeColor = function(c) bump("applyThemeColor"); cb._tint = c end
    if not opts.accent then
        local root = opts.themeRoot or cb:GetParent()
        if type(root) == "table" then
            local list = rawget(root, "ThemeListeners")
            if not list then list = {}; root.ThemeListeners = list end
            list[#list + 1] = cb
        end
    end
    return cb.Check
end
function host:CreateLabelNative(_, opts)
    local fs = FakeUIFrame()
    fs._labelOpts = opts
    fs.SetTextColor = function(s, r, g, b, a) s._textColor = { r = r, g = g, b = b, a = a } end
    if opts and opts.text then fs:SetText(opts.text) end
    return fs
end

if not UI.CreatePopout then load_ui_file("Popout.lua") end
if not UI.CreatePopoutRow then load_ui_file("PopoutRow.lua") end

local ACCENT = host:GetAccent()

-- ---- fixtures -------------------------------------------------------
local function window()
    local w = FakeUIFrame(600, 400, CX, CY)
    w:Show()
    return w
end

-- A pane the way a converted page mounts one: ONE settings group holding N
-- controls, each registered on the group's ThemeListeners -- which is what
-- StyleCheckButton does for an unaccented box, and so what a real page's pane
-- hands the cascade.
local WIDGETS = 8
local function groupPane(seenBox)
    return function(_, pane)
        local g = CreateFrame("Frame", nil, pane)
        g.isSettingsGroup = true
        local entries = {}
        g.groupChildren = entries
        local listeners = {}
        g.ThemeListeners = listeners
        for i = 1, WIDGETS do
            local w = CreateFrame("Frame", nil, g)
            w.enabled = true
            w.SetEnabled = function(s, e) s.enabled = e and true or false end
            w.ApplyThemeColor = function(c)
                bump("applyThemeColor")
                w._tint = c
                if seenBox then seenBox.c = c end
            end
            listeners[i] = w
            entries[i] = { widget = w }
        end
        g.RefreshChildStates = function() bump("refreshChildStates") end
        pane:SetHeight(60)
    end
end

-- One page's worth of rows, all on ONE window and so all sharing one pooled
-- panel -- which is the arrangement the cost grew under.
local function page(n, key)
    local win = window()
    local rows, acts = {}, {}
    for i = 1, n do
        acts[i] = {
            { text = "Reset", enabled = function() bump("enabledProbe"); return true end },
        }
        local row = host:CreatePopoutRow(FakeUIFrame(), {
            label = "Row " .. i, db = { on = true }, toggle = { key = "on" },
            count = WIDGETS, build = groupPane(), window = win,
            popoutKey = key, actions = acts[i],
        })
        row:SetSize(260, M.slot)
        row:SetFakeCenter(CX - 100, CY + (i * 8) - 40)
        row:Show()
        rows[i] = row
    end
    return rows
end

-- Open every row once, which is what BUILDS its pane on the shared instance.
local function visitAll(rows)
    for i = 1, #rows do rows[i]:OpenPopout() end
end

-- ============================================================
-- 1. A RE-OPEN COSTS THE SAME WHATEVER IS ALREADY BUILT
-- The headline claim, and it is stated as an EQUALITY between a small page and a
-- large one rather than against a remembered number: what was wrong was the
-- SHAPE of the cost, and a constant here would need re-tuning the first time the
-- shell grew a frame.
-- ============================================================
print("-- popout perf: a re-open does not pay for the panes already built")
do
    local small = page(2, "perfSmall")
    visitAll(small)
    reset()
    small[1]:OpenPopout()
    local smallWalk, smallTint = got("getChildren"), got("applyThemeColor")

    local big = page(12, "perfBig")
    visitAll(big)
    reset()
    big[1]:OpenPopout()
    local bigWalk, bigTint = got("getChildren"), got("applyThemeColor")

    eq(bigTint, smallTint,
       "cost: re-opening a row on a 12-row page re-tints no more widgets than on a 2-row one")
    eq(bigWalk, smallWalk,
       "cost: ...and walks no more of the frame tree")
    -- The absolute numbers matter too, or "equal" could be satisfied by both
    -- being enormous. A pane holds 8 controls; a re-open that touched even one
    -- pane's worth of them would clear this.
    check(bigTint < WIDGETS,
          "cost: ...and it is fewer than one pane's controls -- the panes are not walked at all")

    -- The pane that is UP is the one that has been painted, which is what the
    -- number above is bought with.
    eq(big[1].popout._rowActive ~= nil, true, "cost: the panel still has a pane mounted")
    big[1]:ClosePopout()
    small[1]:ClosePopout()
end

-- ...and the same for the CLOSE, which the report named alongside the open.
print("-- popout perf: closing walks nothing")
do
    local rows = page(8, "perfClose")
    visitAll(rows)
    reset()
    rows[1]:ClosePopout()
    eq(got("applyThemeColor"), 0, "close: closing re-tints nothing")
    eq(got("getChildren"), 0, "close: ...and walks nothing")
    eq(got("paintChrome"), 0, "close: ...and re-issues no chrome")
end

-- ============================================================
-- 2. NO PAINT WITHOUT A CHANGE
-- ...and its other half, which is the one that keeps the first honest.
-- ============================================================
print("-- popout perf: the chrome is re-issued only when it would differ")
do
    local rows = page(3, "perfChrome")
    rows[1]:OpenPopout()
    reset()
    rows[1]:OpenPopout()
    eq(got("paintChrome"), 0, "chrome: re-opening the same row re-issues no backdrop")
    reset()
    rows[2]:OpenPopout()
    eq(got("paintChrome"), 0, "chrome: ...nor does swapping to another row of the same colour")

    -- The half that proves the compare is a compare and not a mute.
    reset()
    rows[2]:SetAccent({ 1, 0.5, 0 })
    eq(got("paintChrome"), 1, "chrome: a real colour change paints, exactly once")
    local po = rows[2].popout
    eq(po.frame._panelOpts.borderColor.r, 1, "chrome: ...in the colour it was given")
    reset()
    rows[2]:SetAccent({ 1, 0.5, 0 })
    eq(got("paintChrome"), 0, "chrome: ...and re-stating the same colour paints nothing")
    rows[2]:SetAccent(nil)
    rows[2]:ClosePopout()
end

print("-- popout perf: the footer strip is laid out only when it would differ")
do
    local rows = page(3, "perfFooter")
    rows[1]:OpenPopout()
    reset()
    rows[1]:OpenPopout()
    eq(got("footerSetText"), 0, "footer: re-opening the same row re-labels nothing")
    -- The strip is still THERE and still asked whether it may be pressed -- the
    -- skip is the layout, not the refresh.
    check(got("enabledProbe") > 0, "footer: ...but the actions are still re-asked whether they are allowed")
    check(rows[1].popout._footerOn, "footer: ...and the strip is still up")

    -- A different row's verbs are a different strip.
    reset()
    rows[2]:OpenPopout()
    eq(got("footerSetText"), 1, "footer: swapping to a row with its own actions re-labels")

    -- ...and so is the same descriptor relabelled in place, which identity alone
    -- would sleep through.
    local po = rows[2].popout
    local act = po.actions[1]
    act.text = "Renamed"
    po:SetActions(po.actions)
    eq(po._footerBtns[1]._text, "Renamed", "footer: a descriptor relabelled in place still reaches the button")
    rows[2]:ClosePopout()
end

-- ============================================================
-- 3. THE PANE THAT IS NOT LOOKING STILL CATCHES UP
-- The bargain the speed is bought with: the cascade paints the pane that is up,
-- so a pane hidden when the colour moved has to be brought up to date by the
-- swap that shows it. Get this wrong and a user switching party/raid mode sees
-- one group in the new colour and every group they visit afterwards in the old.
-- ============================================================
print("-- popout perf: a hidden pane is re-tinted by the swap that shows it")
do
    local win = window()
    local seenA, seenB = {}, {}
    local function mk(i, seen, accent)
        local row = host:CreatePopoutRow(FakeUIFrame(), {
            label = "Stale " .. i, db = { on = true }, toggle = { key = "on" },
            count = WIDGETS, build = groupPane(seen), window = win,
            popoutKey = "perfStale", accent = accent,
        })
        row:SetSize(260, M.slot)
        row:SetFakeCenter(CX - 100, CY + (i * 8))
        row:Show()
        return row
    end
    -- Two rows with DIFFERENT colours on ONE pooled panel: the only arrangement
    -- in which a cached pane can be left wearing a colour the panel has moved on
    -- from.
    local a = mk(1, seenA, nil)                        -- the host accent
    local b = mk(2, seenB, { 1, 0.25, 0 })             -- its own

    a:OpenPopout()
    eq(seenA.c and seenA.c.r, ACCENT.r, "stale: A's pane opens in the host accent")
    b:OpenPopout()
    eq(seenB.c and seenB.c.r, 1, "stale: B's pane opens in B's own")
    -- A is now HIDDEN and was last painted in the host accent, while the panel
    -- has been B's orange throughout. Coming back to A must not hand it B's.
    a:OpenPopout()
    eq(seenA.c and seenA.c.r, ACCENT.r, "stale: swapping back to A puts A's pane back in A's colour")
    eq(seenA.c and seenA.c.g, ACCENT.g, "stale: on every channel")

    -- ...and the harder direction: the colour moves WHILE the pane is hidden.
    b:OpenPopout()                       -- A hidden again, still host-accented
    a:SetAccent({ 0, 0.75, 0.25 })       -- A's colour changes with A's pane off screen
    a:OpenPopout()
    eq(seenA.c and seenA.c.g, 0.75, "stale: a colour changed while the pane was hidden lands on the swap back")
    eq(seenA.c and seenA.c.b, 0.25, "stale: on every channel")
    a:ClosePopout()
end

print("-- popout perf: the pane that IS up still repaints live")
do
    local win = window()
    local seen = {}
    local row = host:CreatePopoutRow(FakeUIFrame(), {
        label = "Live", db = { on = true }, toggle = { key = "on" },
        count = WIDGETS, build = groupPane(seen), window = win, popoutKey = "perfLive",
    })
    row:SetSize(260, M.slot)
    row:SetFakeCenter(CX - 100, CY)
    row:Show()
    row:OpenPopout()
    eq(seen.c and seen.c.r, ACCENT.r, "live: the pane opens in the host accent")
    -- The mode switch, which is the case this cannot be allowed to break.
    row:SetAccent({ 0.9, 0.1, 0.4 })
    eq(seen.c and seen.c.r, 0.9, "live: an accent change under an OPEN panel reaches the pane it is showing")
    eq(seen.c and seen.c.b, 0.4, "live: on every channel")
    row:SetAccent(nil)
    eq(seen.c and seen.c.r, ACCENT.r, "live: clearing the override hands the pane back to the host accent")
    -- ...and the header toggle, which is NOT under the mount and so is still the
    -- shell's own to walk.
    eq(row.popout._hdrToggle._tint and row.popout._hdrToggle._tint.r, ACCENT.r,
       "live: the title bar's toggle follows too -- it is not behind the mount's hand-off")
    row:ClosePopout()
end

-- ============================================================
-- 4. THE PANE IS STILL BUILT ONCE
-- The saving must not have come from skipping work that was load-bearing.
-- ============================================================
print("-- popout perf: N opens of a row still build its pane once")
do
    local win = window()
    local builds = 0
    local row = host:CreatePopoutRow(FakeUIFrame(), {
        label = "Once", db = { on = true }, toggle = { key = "on" },
        count = 0, popoutKey = "perfOnce", window = win,
        build = function(_, pane) builds = builds + 1; pane:SetHeight(40) end,
    })
    row:SetSize(260, M.slot)
    row:SetFakeCenter(CX - 100, CY)
    row:Show()
    for _ = 1, 5 do row:OpenPopout() end
    eq(builds, 1, "build: five opens, one build")
    row:ClosePopout()
    row:OpenPopout()
    eq(builds, 1, "build: ...and a close and re-open does not rebuild it -- the panel is pooled")
    row:ClosePopout()
end

-- ============================================================
-- 5. THE OFF GATE STILL GREYS, AND STILL ONLY ONCE
-- The gate walks the same roster the cascade used to, and it is the other thing
-- a swap re-states on every pass. Nothing above was allowed to disturb it.
-- ============================================================
print("-- popout perf: the gate still greys the pane it is handed")
do
    local win = window()
    local db = { on = true }
    local row = host:CreatePopoutRow(FakeUIFrame(), {
        label = "Gated", db = db, toggle = { key = "on" },
        count = WIDGETS, build = groupPane(), window = win, popoutKey = "perfGate",
    })
    row:SetSize(260, M.slot)
    row:SetFakeCenter(CX - 100, CY)
    row:Show()
    row:OpenPopout()
    local rec = row.popout._rowActive
    eq(rec.gateShut, false, "gate: a row that is on opens with its pane live")
    check(rec.kids[1].enabled, "gate: ...and its controls enabled")

    row.checkButton:SetChecked(false)
    row.checkButton:GetScript("OnClick")(row.checkButton)
    eq(rec.gateShut, true, "gate: switching the row off shuts the gate")
    eq(rec.kids[1].enabled, false, "gate: ...and greys the controls")

    -- Re-opening an off row must find it already shut rather than re-walking it.
    reset()
    row:OpenPopout()
    eq(rec.gateShut, true, "gate: re-opening an off row keeps the gate shut")
    eq(got("refreshChildStates"), 0, "gate: ...without re-running the group's state pass for nothing")

    row.checkButton:SetChecked(true)
    row.checkButton:GetScript("OnClick")(row.checkButton)
    eq(rec.gateShut, false, "gate: switching it back on opens the gate")
    eq(rec.kids[1].enabled, true, "gate: ...and hands the controls back")
    row:ClosePopout()
end

-- ============================================================
-- 6. THE PERF MARKS
-- The library writes into the host's own `perf` buckets -- Core.lua's, the ones
-- UI:PerfReport already walks -- so a consumer that calls PerfStart gets the
-- shell's internal work in the same report as its hooks. Two claims, and the
-- second is the one that matters on every frame of every session:
--
--   * recording ON, the open and close paths book calls under their own names
--   * recording OFF, nothing is written and nothing is asked for -- which is the
--     state the marks live in, so it is the state they must cost nothing in
-- ============================================================
print("-- popout perf: the marks feed the host's own perf buckets")
do
    local win = window()
    local row = host:CreatePopoutRow(FakeUIFrame(), {
        label = "Marked", db = { on = true }, toggle = { key = "on" },
        count = WIDGETS, build = groupPane(), window = win, popoutKey = "perfMarks",
        actions = { { text = "Reset" } },
    })
    row:SetSize(260, M.slot)
    row:SetFakeCenter(CX - 100, CY)
    row:Show()

    -- OFF. The state everything above ran in, and the state that has to be free.
    row:OpenPopout()
    eq(rawget(host, "perf"), nil, "marks: nothing is recorded, or allocated, while recording is off")
    row:ClosePopout()

    -- ON -- exactly what Core.lua's PerfStart puts on the host, restated here
    -- because a headless run never loads Core.lua.
    host._perfActive = true
    host.perf = { counts = {}, ms = {}, dragCount = 0 }
    row:OpenPopout()
    local c = host.perf.counts
    eq(c["popoutrow:open"], 1, "marks: an open books one call under the row's own name")
    check((c["popoutrow:swap"] or 0) >= 1, "marks: ...and the pane swap inside it")
    check((c["popout:cascade"] or 0) >= 1, "marks: ...and the accent cascade")
    check((c["popout:adopt"] or 0) >= 1, "marks: ...and the pooled adopt")
    -- The one that must NOT be booked: the chrome did not change, so it was not
    -- painted, so there is nothing to charge for it.
    eq(c["popout:chrome"], nil, "marks: ...and a paint that did not happen books nothing")
    for name in pairs(c) do
        check(type(host.perf.ms[name]) == "number",
              "marks: every counted name carries a duration (" .. name .. ")")
    end

    row:ClosePopout()
    eq(c["popout:close"], 1, "marks: closing books one call too")

    host._perfActive = nil
    host.perf = nil
end

CreateFrame, C_Timer = prevCreateFrame, prevTimer
PlaySound, SOUNDKIT = prevPlaySound, prevSoundKit
