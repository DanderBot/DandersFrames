local NS = ...
local R = NS.Registry

-- ============================================================
-- KIT + SHELL STUBS
-- Panel.lua is a CONSUMER of DandersUI's popout shell, so the real Popout.lua
-- is loaded here too and driven for real -- pooling, pinning, the cross and the
-- tether all come from it, and a panel test that stubbed them would be testing
-- a drawing of the thing.
--
-- Shape mirrors the runtime: the LIBRARY table is NS.__DandersUI (run.py already
-- put Fx on it), the HOST is a small table whose __index is the library, and
-- factories are called on the host. Only the widget surface the panel actually
-- reads back is modelled; everything else falls through FakeUIFrame's __index.
-- ============================================================
local KIT = NS.__DandersUI

local COLORS = {
    textDim = { r = 0.5, g = 0.5, b = 0.5 }, text = { r = 0.9, g = 0.9, b = 0.9 },
    accent  = { r = 0.45, g = 0.45, b = 0.95 }, panel = { r = 0.12, g = 0.12, b = 0.12 },
    border  = { r = 0.25, g = 0.25, b = 0.25 }, anchored = { r = 0.55, g = 0.4, b = 0.85 },
    anchorRoot = { r = 0, g = 1, b = 0 }, danger = { r = 0.8, g = 0.2, b = 0.2 },
}
KIT.MEDIA = ""
KIT.Colors = COLORS
KIT.Space = { section = 10 }
KIT.RowGap = 14
KIT.RowGapTight = 8
KIT.RowHeight = { groupTitle = 26, checkbox = 35 }

function KIT:GetAccent() return COLORS.accent end
function KIT:CreatePanelBackdrop() end
function KIT:CreateElementBackdrop() end
-- The shell paints the popout's accent border and the source outline through
-- this; the panel asserts nothing about either, so recording is enough.
function KIT:ApplyPixelBorder(frame, color) frame._pxColor = color end

-- A FontString that records whether its caption clips or wraps: the difference
-- between a long string staying in its row and falling through the one below.
local function stubFontString(text)
    local fs = FakeUIFrame()
    fs:SetText(text or "")
    function fs:SetWordWrap(v) self._wordWrap = v and true or false end
    return fs
end

function KIT:CreateLabel(_, opts)
    return stubFontString(opts and opts.text)
end

-- Every button ever built by the panel, so "the panel has no session verbs on
-- it" can be asserted over the whole set rather than over the handful of fields
-- the panel happens to keep.
local builtButtons = {}
local function stubButton(opts, w, h)
    local b = FakeUIFrame(w or (opts and opts.width) or 0, h or (opts and opts.height) or 0)
    b._opts = opts
    b:Show()
    return b
end
function KIT:CreateButton(_, opts)
    builtButtons[#builtButtons + 1] = opts
    return stubButton(opts)
end
function KIT:CreateGlyphButton(_, opts)
    local b = stubButton(opts, opts and (opts.width or opts.size), opts and (opts.height or opts.size))
    -- The kit's glyph texture, which the panel re-anchors to make room for the
    -- grip dots beside it.
    b.Icon = FakeUIFrame()
    return b
end
function KIT:CreateCloseButton(_, opts) return stubButton(opts, 18, 18) end

function KIT:CreateEditBox(_, opts)
    local e = FakeUIFrame(opts and opts.width or 0, 20)
    e._opts = opts
    e:SetText("0")
    function e:Refresh() self:SetText(tostring((opts.get and opts.get()) or 0)) end
    return e
end

-- The dropdown surface the panel actually drives: a caption override, an option
-- set that can be swapped, and the enable state.
function KIT:CreateDropdown(_, opts)
    local d = FakeUIFrame()
    d._opts = opts or {}
    d._options = d._opts.options
    d.opener = FakeUIFrame()
    d.opener.Text = stubFontString()
    function d:SetDisplayOverride(text) self._override = text end
    function d:UpdateText() end
    function d:RebuildOptions(newOptions) if newOptions then self._options = newOptions end end
    -- What "opening the menu" is, headlessly: the kit calls optionsFunc on the
    -- opener's click and rebuilds from what comes back.
    function d:Open() if self._opts.optionsFunc then self:RebuildOptions(self._opts.optionsFunc()) end end
    return d
end

local groupBoxes = 0
function KIT:CreateGroupBox(_, opts)
    groupBoxes = groupBoxes + 1
    local box = FakeUIFrame()
    box._opts = opts
    box.content = FakeUIFrame()
    box.title = stubFontString(opts and opts.title or "")
    -- The real box is pad + title + content + pad; mirrored so the panel's
    -- measured height is the one the kit would give it.
    local pad = (opts and opts.padding) or 10
    function box:SetContentHeight(h)
        self.content:SetHeight(h)
        self:SetHeight(pad + 26 + h + pad)
    end
    box:SetContentHeight(1)
    return box
end

-- The host: hooks (the shell reads the Pin tooltip out of it) plus the library
-- behind __index.
NS.UI = setmetatable({ hooks = { L = NS.L } }, { __index = KIT })

-- ---- WoW globals ---------------------------------------------------
CreateFrame = function() return FakeUIFrame() end
GameTooltip = FakeUIFrame()
GetTime = function() return 0 end
IsShiftKeyDown = function() return false end
IsControlKeyDown = function() return false end
-- Fires immediately: the shell's beam/exit sequencing is about ORDER, and a
-- headless run wants that order in one frame.
C_Timer = { After = function(_, fn) fn() end }

-- ---- Session / Proxy stand-ins -------------------------------------
-- Everything the panel calls is recorded rather than performed, so what is
-- under test is the panel's own wiring -- and, crucially, WHICH element each
-- control carried.
local calls = {}
local hover = nil
local proxies = {}
local unlockFrame = FakeUIFrame(1920, 1080, 0, 0)
unlockFrame:Show()

-- Every slab repaint the panel asks for. The pin marker lives on the slab, so
-- "pinning repainted the slabs" is only observable here.
local highlights = {}
NS.Proxy = {
    proxies = proxies,
    GetUnlockFrame = function() return unlockFrame end,
    LinkHover = function() return hover end,
    RefreshAll = function() end,
    -- `or false`: a repaint with nothing selected is still a repaint, and a nil
    -- would not grow the list.
    Highlight = function(_, id) highlights[#highlights + 1] = id or false end,
}
NS.Session = {
    selected = nil, linking = nil, active = true, suspended = false,
    IsActive = function(self) return self.active end,
    IsSuspended = function(self) return self.suspended end,
    Select = function(self, id)
        self.selected = id
        calls[#calls + 1] = { "select", id }
        NS.Panel:Refresh()
    end,
    BeginLink = function(self, el, mode)
        calls[#calls + 1] = { "begin", el.id, mode }
        self.linking = { id = el.id, mode = mode or "primary" }
    end,
    CancelLink = function(self) calls[#calls + 1] = { "cancel" }; self.linking = nil end,
    EndLink = function(self, targetId) calls[#calls + 1] = { "end", targetId }; self.linking = nil end,
    SetAnchorSpec = function(_, el, changes) calls[#calls + 1] = { "spec", el.id, changes } end,
    AnchorInPlace = function(_, el, t) calls[#calls + 1] = { "anchor", el.id, t } end,
    SetFallback = function(_, el, t) calls[#calls + 1] = { "fallback", el.id, t } end,
    ClearFallback = function(_, el) calls[#calls + 1] = { "clearfallback", el.id } end,
    SetXY = function(_, el, x, y) calls[#calls + 1] = { "setxy", el.id, x, y } end,
    SetAnchorPoint = function(_, el, p) calls[#calls + 1] = { "point", el.id, p } end,
    Nudge = function(_, el, dx, dy) calls[#calls + 1] = { "nudge", el.id, dx, dy } end,
    Center = function(_, el) calls[#calls + 1] = { "center", el.id } end,
    Reset = function(_, el) calls[#calls + 1] = { "reset", el.id } end,
    Detach = function(_, el) calls[#calls + 1] = { "detach", el.id } end,
    CopyToTwin = function(_, el) calls[#calls + 1] = { "copytwin", el.id } end,
}
NS.Lib = NS.Lib or { callbacks = { Fire = function() end } }

load_ui_file("Popout.lua")
load_addon_file("Picker.lua")
load_addon_file("Panel.lua")
local Pn, Sess, Proxy = NS.Panel, NS.Session, NS.Proxy
local L = NS.L

local wasReady = R.ready
R.ready = true
NS.db = { showHiddenMovers = true, panelSide = "auto", autoPinPanels = false, addons = {} }

local function elDef(pos, extra)
    local def = { title = "x", frame = FakeFrame(960, 540, 100, 40),
                  getPos = function() return pos end, onChanged = function() end }
    for k, v in pairs(extra or {}) do def[k] = v end
    return def
end

R:RegisterAddon("P", { title = "Panels" })
local freePos = { point = "CENTER", x = 0, y = 0 }
local childPos = { point = "CENTER", x = 0, y = 0 }
R:Register("P", "host", elDef({ point = "CENTER", x = 200, y = 0 }))
R:Register("P", "spare", elDef({ point = "CENTER", x = -200, y = 0 }))
R:Register("P", "free", elDef(freePos))
R:Register("P", "child", elDef(childPos))

-- Proxies near the screen centre, so the dock-side solver has a side that fits
-- and the panel never falls back to the screen-edge flip.
local function proxyFor(id, x, y)
    local b = FakeUIFrame(80, 40, 960 + (x or 0), 540 + (y or 0))
    b:Show()
    proxies[id] = b
    return b
end
proxyFor("P:host", 200, 0)
proxyFor("P:spare", -200, 0)
proxyFor("P:free", 0, 0)
proxyFor("P:child", 0, -80)

-- Select an element and return the panel that ends up following it.
local function refresh(id)
    Sess.selected = id
    Pn:Refresh()
    return Pn.following
end

local function reset()
    Pn:CloseAll()
    Sess.selected = nil
    Sess.linking = nil
    wipe(calls)
end

-- ============================================================
-- 1. FREE ELEMENT: the block is all there, the Target row reads "None", and
-- only the primary handle stays live -- it is the way IN to anchoring.
-- ============================================================
do
    local po = refresh("P:free")
    check(po ~= nil, "free: selecting an element opens a following panel")
    local ui = po.ui
    eq(po:GetTitle(), R:Get("P:free").title, "free: the shell title bar names the element")
    eq(ui.addon:GetText(), "Panels", "free: the addon line names the addon")
    check(not po:IsPinned(), "free: a freshly opened panel follows, it is not pinned")

    -- The Target row's empty state TEACHES: the word plus the chain glyph
    -- inline, so the sentence points at the handle beside it. The Backup row
    -- stays a bare "None" -- it is greyed here and has no gesture to offer.
    local cap = ui.targetRow.picker._override
    check(cap:find("None", 1, true) == 1, "free: the target caption still opens with None")
    check(cap:find("|TInterface\\AddOns\\DandersMover\\Media\\link.tga:12:12|t", 1, true) ~= nil,
        "free: the target caption carries the chain glyph inline")
    check(cap:find("link", 1, true) ~= nil, "free: the target caption names the gesture")
    eq(ui.backupRow.picker._override, L["None"], "free: backup reads None")
    -- ...and that caption has to CLIP. Word wrap on a both-edges-anchored
    -- FontString would put the overflow on a second line, straight through the
    -- row below it.
    eq(ui.targetRow.picker.opener.Text._wordWrap, false, "free: the target caption clips, not wraps")
    eq(ui.backupRow.picker.opener.Text._wordWrap, false, "free: the backup caption clips, not wraps")
    check(ui.targetRow.handle:IsEnabled(), "free: primary handle stays enabled")
    check(not ui.backupRow.handle:IsEnabled(), "free: backup handle disabled")
    check(ui.backupRow.picker._enabled == false, "free: backup picker disabled")
    check(ui.edgeDrop._enabled == false and ui.alignDrop._enabled == false, "free: seat pair disabled")
    eq(ui.edgeLabel:GetText(), L["Edge"], "free: seat labels default to Edge/Align")
    eq(ui.alignLabel:GetText(), L["Align"], "free: align label")
    eq(ui.targetRow.label:GetText(), L["Target"], "free: target row is labelled")
    eq(ui.backupRow.label:GetText(), L["Backup"], "free: backup row is labelled")
    eq(ui.anchorBox.title:GetText(), L["Anchor"], "the block is a titled sub-section")
    -- An inline dropdown's factory label is hidden, so the kit's usual
    -- label-hover tooltip has nothing to sit on: the OPENER carries one.
    eq(ui.targetRow.picker.openerTooltip.title, L["Target"], "the target opener names itself")
    eq(ui.backupRow.picker.openerTooltip.title, L["Backup"], "the backup opener names itself")
    eq(ui.targetRow.handle._opts.tooltip.lines[1], L["Drag onto another mover to attach"],
        "the primary handle says what dragging it does")
    eq(ui.backupRow.handle._opts.tooltip.lines[1], L["Drag onto another mover to set the backup anchor"],
        "the backup handle says what dragging it does")

    -- Both label columns are measured to the wider of their pair, so the two
    -- pickers start on the same column.
    eq(ui.targetRow.label:GetWidth(), ui.backupRow.label:GetWidth(), "Target/Backup share a label column")
    eq(ui.edgeLabel:GetWidth(), ui.alignLabel:GetWidth(), "Edge/Align share a label column")
end

-- ============================================================
-- 2. THE PANEL HOLDS ELEMENT CONTENT ONLY
-- The session verbs moved to the legend strip: with several panels pinned at
-- once, an Undo button on each one would be the same button drawn many times.
-- ============================================================
do
    local ui = Pn.following.ui
    check(ui.btnUndo == nil and ui.btnRedo == nil, "verbs: no undo/redo on the panel")
    check(ui.btnSave == nil and ui.btnDiscard == nil, "verbs: no save/discard on the panel")
    check(ui.btnSettings == nil, "verbs: no Settings button on the panel")
    local banned = { [L["Undo"]] = true, [L["Redo"]] = true, [L["Save & Exit"]] = true,
                     [L["Discard"]] = true, [L["Settings"]] = true }
    local found
    for _, opts in ipairs(builtButtons) do
        if opts and opts.text and banned[opts.text] then found = opts.text end
    end
    eq(found, nil, "verbs: no session verb was built anywhere in the panel")
    -- What IS there is element content.
    check(ui.btnCenter and ui.btnReset and ui.btnDetach, "content: Center/Reset/Detach are still here")
    check(ui.btnCopy ~= nil, "content: the copy-to-twin row is still here")
    check(ui.btnConfigure ~= nil, "content: Configure is still here")
    check(not ui.btnConfigure:IsShown(), "content: ...and hidden for an element with no openSettings")
end

-- ============================================================
-- 3. ANCHORED: the height does not change, and the caption names the target.
-- ============================================================
local freeH
do
    freeH = Pn.following.content:GetHeight()
    childPos.anchor = { target = "P:host", edge = "bottom", align = "start", offsetX = 0, offsetY = 0 }
    local po = refresh("P:child")
    local ui = po.ui
    eq(po.content:GetHeight(), freeH, "anchoring does not resize the panel")
    -- Anchored, the caption is the bare target name: the teaching line is the
    -- EMPTY state's job and would be noise once the row has an answer.
    eq(ui.targetRow.picker._override, R:Get("P:host").title, "anchored: target names the target")
    check(ui.targetRow.picker._override:find("|T", 1, true) == nil,
        "anchored: no inline glyph in the caption")
    check(ui.backupRow.picker._enabled, "anchored: backup picker enabled")
    check(ui.backupRow.handle:IsEnabled(), "anchored: backup handle enabled")
    check(ui.edgeDrop._enabled and ui.alignDrop._enabled, "anchored: seat pair enabled")
    eq(ui.edgeDrop._opts.get(), "bottom", "edge reads the record")
    eq(ui.alignDrop._opts.get(), "start", "align reads the record")
    ui.edgeDrop._opts.set("top")
    local last = calls[#calls]
    check(last[1] == "spec" and last[2] == "P:child" and last[3].edge == "top",
        "outside mode writes `edge`, for the panel's own element")
end

-- ============================================================
-- 4. POINT MODE: the same pair of dropdowns, relabelled, with the 9 points.
-- ============================================================
do
    childPos.anchor = { target = "P:host", mode = "point", point = "TOPLEFT",
                        relPoint = "BOTTOMLEFT", offsetX = 0, offsetY = 0 }
    local po = refresh("P:child")
    local ui = po.ui
    eq(ui.edgeLabel:GetText(), L["Point"], "point mode: left label is Point")
    eq(ui.alignLabel:GetText(), L["Rel point"], "point mode: right label is Rel point")
    eq(ui.edgeDrop._options.TOPLEFT, "TOPLEFT", "point mode: the 9 points are the option set")
    eq(ui.edgeDrop._opts.get(), "TOPLEFT", "point reads the record")
    eq(ui.alignDrop._opts.get(), "BOTTOMLEFT", "relPoint reads the record")
    ui.alignDrop._opts.set("TOP")
    local last = calls[#calls]
    check(last[1] == "spec" and last[3].relPoint == "TOP" and last[3].align == nil,
        "point mode writes `relPoint`, not `align`")
    eq(po.content:GetHeight(), freeH, "point mode does not resize the panel either")
    -- ...and back, so the swap is not one-way.
    childPos.anchor = { target = "P:host", edge = "bottom", align = "start", offsetX = 0, offsetY = 0 }
    po = refresh("P:child")
    eq(po.ui.edgeLabel:GetText(), L["Edge"], "back to outside mode: labels swap back")
    eq(po.ui.edgeDrop._options.right, L["Right"], "back to outside mode: edges are the option set")
end

-- ============================================================
-- 5. LINK HANDLES: the same gesture with different modes, ended on whatever
-- the cursor was over.
-- ============================================================
do
    local ui = refresh("P:child").ui
    wipe(calls)
    ui.targetRow.handle:GetScript("OnMouseDown")(ui.targetRow.handle, "LeftButton")
    eq(calls[1][3], "primary", "the target handle begins a PRIMARY link")
    eq(calls[1][2], "P:child", "...for the panel's own element")
    hover = "P:spare"
    ui.targetRow.handle:GetScript("OnMouseUp")(ui.targetRow.handle, "LeftButton")
    check(calls[2][1] == "end" and calls[2][2] == "P:spare", "release ends the link on the hovered target")

    wipe(calls)
    ui.backupRow.handle:GetScript("OnMouseDown")(ui.backupRow.handle, "LeftButton")
    eq(calls[1][3], "fallback", "the backup handle begins a FALLBACK link")
    ui.backupRow.handle:GetScript("OnMouseUp")(ui.backupRow.handle, "LeftButton")
    check(calls[2][1] == "end", "the backup release ends the same gesture")

    -- Right-click during a gesture cancels from either handle.
    wipe(calls)
    Sess.linking = { id = "P:child", mode = "primary" }
    ui.backupRow.handle:GetScript("OnMouseDown")(ui.backupRow.handle, "RightButton")
    eq(calls[1][1], "cancel", "right-click cancels")
    hover = nil
    Sess.linking = nil
end

-- ============================================================
-- 6. THE HANDLES READ AS GRIPS: dots beside the chain, and a hover that lifts,
-- brightens and takes the move cursor. Both handles get the same treatment --
-- they are the same gesture.
-- ============================================================
do
    local ui = refresh("P:free").ui
    for _, row in ipairs({ ui.targetRow, ui.backupRow }) do
        local h = row.handle
        check(h.Grip ~= nil, "the handle carries grip dots beside the chain")
        check(h:GetScript("OnEnter") and h:GetScript("OnLeave"), "the handle has hover scripts")
        check(h:GetWidth() > h:GetHeight(), "the handle is a grip box, not a square icon")
    end
    -- The picker must NOT be pinned to the handle: a lift would drag it along.
    local pinnedToHandle = false
    for _, p in ipairs(ui.targetRow.picker._points) do
        if p[2] == ui.targetRow.handle then pinnedToHandle = true end
    end
    check(not pinnedToHandle, "the picker is anchored to the row, not to the lifting handle")
end

-- Hover: lift on enter, settle on leave, and the move cursor on the way in and
-- out. SetCursor is probed and pcall'd, so neither a missing path nor a
-- throwing API may escape into the hover.
do
    local ui = refresh("P:free").ui
    local h = ui.targetRow.handle
    local cur = {}
    -- Probe surface: a texture whose SetTexture answers "not false", i.e. the
    -- cursor file resolved.
    UIParent.CreateTexture = function() return { SetTexture = function() end, Hide = function() end } end
    SetCursor = function(path) cur[#cur + 1] = path end
    ResetCursor = function() cur[#cur + 1] = "reset" end

    h:GetScript("OnEnter")(h)
    check(h:GetScale() > 1, "hovering lifts the handle")
    eq(cur[1], "Interface\\CURSOR\\UI-Cursor-Move", "hovering takes the move cursor")
    h:GetScript("OnLeave")(h)
    eq(h:GetScale(), 1, "leaving settles the handle back to rest scale")
    eq(cur[2], "reset", "leaving puts the cursor back")

    -- A SetCursor that throws (missing file, older client) must not break the
    -- hover: the pcall swallows it and the lift still happens.
    cur = {}
    SetCursor = function() error("no such cursor") end
    h:GetScript("OnEnter")(h)
    check(h:GetScale() > 1, "a throwing SetCursor still leaves the hover working")
    h:GetScript("OnLeave")(h)
    eq(h:GetScale(), 1, "...and the leave still settles")

    -- Mid-gesture the cursor is the gesture's. The button keeps mouse capture
    -- between press and release, so the pointer comes back over it while a link
    -- is live -- grabbing there would fight the drag.
    cur = {}
    SetCursor = function(path) cur[#cur + 1] = path end
    Sess.linking = { id = "P:free", mode = "primary" }
    h:GetScript("OnEnter")(h)
    h:GetScript("OnLeave")(h)
    eq(#cur, 0, "a live link gesture keeps its own cursor")
    Sess.linking = nil

    -- A greyed handle refuses the gesture, so it must not advertise it.
    cur = {}
    local b = ui.backupRow.handle
    check(not b:IsEnabled(), "free: the backup handle is the disabled case")
    b:GetScript("OnEnter")(b)
    eq(b:GetScale(), 1, "a disabled handle does not lift")
    eq(#cur, 0, "a disabled handle does not take the cursor")
    b:GetScript("OnLeave")(b)

    SetCursor, ResetCursor = nil, nil
end

-- ============================================================
-- 7. THE BACKUP ROW names its own target, and the Target row says so when the
-- backup is the block actually holding the element.
-- ============================================================
do
    childPos.anchor = { target = "P:host", edge = "bottom", align = "start",
                        offsetX = 0, offsetY = 0,
                        fallback = { target = "P:spare", edge = "bottom", align = "start",
                                     offsetX = 0, offsetY = 0 } }
    local ui = refresh("P:child").ui
    eq(ui.backupRow.picker._override, R:Get("P:spare").title, "backup row names the backup target")
    check(ui.targetRow.picker._override:find(L["(backup)"], 1, true) == nil,
        "primary available: no (backup) marker")
    -- Hide the primary: the backup takes over and the Target row says which.
    R:Get("P:host").frame._shown = false
    ui = refresh("P:child").ui
    check(ui.targetRow.picker._override:find(L["(backup)"], 1, true) == 1,
        "backup driving: the Target row is marked (backup)")
    R:Get("P:host").frame._shown = true
    childPos.anchor = nil
end

reset()

-- ============================================================
-- 8. MULTI-PIN
-- Two pinned panels bound to two different elements, while the selection has
-- moved on to a third. Each one shows ITS OWN element and each control acts on
-- ITS OWN element -- the whole point of building on per-instance bindings.
-- ============================================================
do
    local a = refresh("P:free")
    a:Pin()
    check(a:IsPinned(), "multi: the first panel is pinned")

    local b = refresh("P:child")
    check(b ~= a, "multi: selecting another element opens a FRESH panel")
    check(not b:IsPinned(), "multi: ...which follows until it is pinned too")
    b:Pin()

    local c = refresh("P:host")
    check(c ~= a and c ~= b, "multi: and a third, still following")
    eq(#Pn.live, 3, "multi: three panels are live at once")
    eq(Sess.selected, "P:host", "multi: the selection is on the third element")

    -- Each panel reports its own element.
    eq(a.el.id, "P:free", "multi: panel A stayed bound to its element")
    eq(b.el.id, "P:child", "multi: panel B stayed bound to its element")
    eq(a:GetTitle(), R:Get("P:free").title, "multi: A's title bar names A's element")
    -- A is free, B is anchored: the two panels are showing genuinely different
    -- states at the same time.
    childPos.anchor = { target = "P:host", edge = "bottom", align = "start", offsetX = 0, offsetY = 0 }
    Pn:Refresh()
    check(a.ui.targetRow.picker._override:find("None", 1, true) == 1, "multi: A still reads as free")
    eq(b.ui.targetRow.picker._override, R:Get("P:host").title, "multi: B reads as anchored")
    check(a.ui.edgeDrop._enabled == false, "multi: A's seat pair is greyed")
    check(b.ui.edgeDrop._enabled, "multi: B's seat pair is live")

    -- Each control carries its own element, not the selection.
    wipe(calls)
    a.ui.targetRow.picker._opts.set("P:spare")
    check(calls[1][1] == "anchor" and calls[1][2] == "P:free", "multi: A's target picker acts on A")
    b.ui.xBox._opts.onCommit(7)
    check(calls[2][1] == "setxy" and calls[2][2] == "P:child" and calls[2][3] == 7,
        "multi: B's X box acts on B")
    a.ui.nudgeButtons[1]._opts.onClick()
    check(calls[3][1] == "nudge" and calls[3][2] == "P:free", "multi: A's nudge acts on A")
    c.ui.btnCenter._opts.onClick()
    check(calls[4][1] == "center" and calls[4][2] == "P:host", "multi: the follower acts on the selection")
    b.ui.btnDetach._opts.onClick()
    check(calls[5][1] == "detach" and calls[5][2] == "P:child", "multi: B's Detach acts on B")

    -- The tether beam's far end is each panel's OWN mover, not what it docked to.
    eq(a.tetherSource(a), proxies["P:free"], "multi: A tethers back to A's proxy")
    eq(b.tetherSource(b), proxies["P:child"], "multi: B tethers back to B's proxy")

    childPos.anchor = nil
end

-- Crossing a PINNED panel closes that one only; the selection is untouched.
do
    local pinnedA, pinnedB
    for _, po in ipairs(Pn.live) do
        if po.elId == "P:free" then pinnedA = po elseif po.elId == "P:child" then pinnedB = po end
    end
    local before = Sess.selected
    pinnedA.closeBtn._opts.onClick()
    check(pinnedA.closed, "cross/pinned: the pinned panel closed")
    eq(Sess.selected, before, "cross/pinned: the selection is intact")
    check(not pinnedB.closed and not Pn.following.closed, "cross/pinned: the others are untouched")
    eq(#Pn.live, 2, "cross/pinned: only that one left the live set")
end

-- Crossing the FOLLOWING panel is "I am done": it deselects and closes.
do
    local following = Pn.following
    check(following ~= nil, "cross/following: there is one to cross")
    following.closeBtn._opts.onClick()
    check(following.closed, "cross/following: the panel closed")
    eq(Sess.selected, nil, "cross/following: ...and the element was deselected")
    check(Pn.following == nil, "cross/following: nothing follows any more")
    check(not following.frame:IsShown(), "cross/following: the frame is down")
end

-- ============================================================
-- 9. SESSION END closes the pinned panels too -- the next session starts clean.
-- ============================================================
do
    check(#Pn.live > 0, "end: a pinned panel is still up going in")
    Sess.active = false
    Pn:Refresh()
    eq(#Pn.live, 0, "end: an inactive session leaves no panel behind")
    check(Pn.following == nil, "end: and nothing following")
    Sess.active = true
end

reset()

-- ============================================================
-- 10. A PINNED PANEL DIES WITH ITS ELEMENT
-- It may outlive the selection -- that is what pinning is for -- but not the
-- thing it is about.
-- ============================================================
do
    R:Register("P", "temp", elDef({ point = "CENTER", x = 40, y = 40 }))
    proxyFor("P:temp", 40, 40)
    local po = refresh("P:temp")
    po:Pin()
    refresh("P:free")
    check(not po.closed, "unregister: the pinned panel survives a selection change")

    R:Unregister("P", "temp")
    proxies["P:temp"] = nil
    Pn:Refresh()
    check(po.closed, "unregister: ...but not its element leaving the session")
    check(not po.frame:IsShown(), "unregister: the frame came down with it")
end

reset()

-- ============================================================
-- 11. AUTO-PIN
-- The gate is DandersMoverDB.autoPinPanels, asked per call by the shell. OFF,
-- the triggers must do nothing at all -- the pin button is still the way.
-- ============================================================
do
    NS.db.autoPinPanels = false
    local po = refresh("P:free")
    po.ui.nudgeButtons[1]._opts.onClick()
    check(not po:IsPinned(), "autopin off: a nudge does not pin")
    po.ui.xBox:GetScript("OnEditFocusGained")(po.ui.xBox)
    check(not po:IsPinned(), "autopin off: taking focus in a coordinate box does not pin")
    po.ui.targetRow.picker:Open()
    check(not po:IsPinned(), "autopin off: opening the target picker does not pin")
    po.ui.edgeDrop:Open()
    check(not po:IsPinned(), "autopin off: opening the seat pair does not pin")
    po.ui.targetRow.handle:GetScript("OnMouseDown")(po.ui.targetRow.handle, "LeftButton")
    check(not po:IsPinned(), "autopin off: taking the link handle does not pin")
    Sess.linking = nil
    po.ui.points[1]._opts.onClick()
    check(not po:IsPinned(), "autopin off: the 9-point picker does not pin")
    -- The pin BUTTON is the user asking, and is never gated.
    po.pinBtn._opts.onClick()
    check(po:IsPinned(), "autopin off: the pin button still pins")
end

reset()

do
    NS.db.autoPinPanels = true
    local po = refresh("P:free")
    check(not po:IsPinned(), "autopin on: still not pinned merely by opening")
    po.ui.nudgeButtons[1]._opts.onClick()
    check(po:IsPinned(), "autopin on: a nudge press pins the panel")
    eq(calls[#calls][1], "nudge", "autopin on: ...and the nudge still went through")

    -- Each trigger on its own, from a fresh panel each time.
    local function triggered(name, fire)
        reset()
        local p = refresh("P:free")
        fire(p)
        check(p:IsPinned(), "autopin on: " .. name .. " pins")
        Sess.linking = nil
    end
    triggered("an edit box taking focus", function(p) p.ui.xBox:GetScript("OnEditFocusGained")(p.ui.xBox) end)
    triggered("opening the target picker", function(p) p.ui.targetRow.picker:Open() end)
    triggered("opening the seat pair", function(p) p.ui.edgeDrop:Open() end)
    triggered("taking the link handle", function(p)
        p.ui.targetRow.handle:GetScript("OnMouseDown")(p.ui.targetRow.handle, "LeftButton")
    end)
    triggered("the 9-point picker", function(p) p.ui.points[1]._opts.onClick() end)
    NS.db.autoPinPanels = false
end

reset()

-- ============================================================
-- 12. THE POOL
-- One unpinned panel per key: re-selecting must not build a second frame, and
-- pinning is what makes the next selection build one.
-- ============================================================
do
    local a = refresh("P:free")
    local before = groupBoxes
    local b = refresh("P:child")
    check(a == b, "pool: retargeting the follower reuses the same instance")
    eq(groupBoxes, before, "pool: ...without a second build")
    a:Pin()
    local c = refresh("P:host")
    check(c ~= a, "pool: once pinned, the next selection gets a new instance")
    eq(groupBoxes, before + 1, "pool: ...and that one built")
    eq(#Pn.live, 2, "pool: both are live")
    -- The element already wearing a pinned panel does not get a second one --
    -- two panels for one mover is a duplicate, not multi-pin.
    refresh("P:child")
    eq(#Pn.live, 1, "pool: an element with a pinned panel gets no duplicate follower")
    check(Pn.following == nil, "pool: ...the follower stood down instead")
    check(a:IsPinned() and not a.closed, "pool: the pinned one is what is left")
end

reset()

-- ============================================================
-- 13. SUSPEND / RESUME
-- Combat hides everything and keeps it: the panels come back, they are not
-- rebuilt.
-- ============================================================
do
    local po = refresh("P:free")
    po:Pin()
    refresh("P:child")
    local built = groupBoxes
    Sess.suspended = true
    Pn:Refresh()
    check(not po.frame:IsShown(), "suspend: the pinned panel is hidden")
    check(not Pn.following.frame:IsShown(), "suspend: the follower is hidden too")
    eq(#Pn.live, 2, "suspend: nothing was closed")
    Sess.suspended = false
    Pn:Refresh()
    check(po.frame:IsShown(), "resume: the pinned panel is back")
    check(Pn.following.frame:IsShown(), "resume: and so is the follower")
    eq(groupBoxes, built, "resume: nothing was rebuilt")
end

reset()

-- ============================================================
-- 14. DOCK SIDE
-- The mover computes the side itself (it knows what else is on screen) and
-- forces it on the shell; the panelSide setting overrides that outright.
-- ============================================================
do
    NS.db.panelSide = "left"
    local po = refresh("P:free")
    eq(po.side, "left", "panelSide: a forced side wins")
    eq(po.forcedSide, "left", "panelSide: ...as a forced side on the shell, not a hint")
    NS.db.panelSide = "right"
    Pn:Refresh()
    eq(po.side, "right", "panelSide: and it is recomputed on every refresh")
    NS.db.panelSide = "auto"
    Pn:Refresh()
    check(po.side == "left" or po.side == "right" or po.side == "above" or po.side == "below",
        "panelSide: auto still lands on a real side")
    check(po.forcedSide ~= nil, "panelSide: auto is forced too -- the shell must not re-pick")
end

reset()

-- ============================================================
-- 15. CONFIGURE
-- Only for elements whose def offers openSettings, and it opens THAT element's
-- settings -- not the selected one's.
-- ============================================================
do
    local opened
    R:Register("P", "cfg", elDef({ point = "CENTER", x = 0, y = 0 },
        { openSettings = function() opened = "P:cfg" end }))
    proxyFor("P:cfg", 120, 120)
    local po = refresh("P:cfg")
    check(po.ui.btnConfigure:IsShown(), "configure: shown for an element that offers it")
    po:Pin()
    refresh("P:free")
    check(not Pn.following.ui.btnConfigure:IsShown(), "configure: hidden on the panel next door")
    po.ui.btnConfigure._opts.onClick()
    eq(opened, "P:cfg", "configure: the pinned panel opened ITS element's settings")
    R:Unregister("P", "cfg")
    proxies["P:cfg"] = nil
end

-- ============================================================
-- 16. A LINK STARTED FROM A PINNED PANEL links FROM that panel's element.
-- The handle closes over the panel's own binding, so a pinned panel's chain
-- reaches out from ITS mover even though the selection is somewhere else --
-- which is the only way to link two movers neither of which is selected.
-- ============================================================
do
    local a = refresh("P:free")
    a:Pin()
    refresh("P:host")
    eq(Sess.selected, "P:host", "pinned link: the selection has moved on")
    wipe(calls)
    a.ui.targetRow.handle:GetScript("OnMouseDown")(a.ui.targetRow.handle, "LeftButton")
    eq(calls[1][1], "begin", "pinned link: the handle starts a link")
    eq(calls[1][2], "P:free", "pinned link: FROM the pinned panel's element, not the selection")
    hover = "P:spare"
    a.ui.targetRow.handle:GetScript("OnMouseUp")(a.ui.targetRow.handle, "LeftButton")
    check(calls[2][1] == "end" and calls[2][2] == "P:spare",
        "pinned link: the release lands on whatever the cursor was over")
    hover = nil
    Sess.linking = nil
end

reset()

-- ============================================================
-- 17. A DRAG HIDES ONLY THE FOLLOWER
-- The following panel is docked to the slab that is about to move; a pinned one
-- sits at its own screen position and has no reason to go anywhere. Hiding the
-- lot would flash every pinned panel off and on for every drag.
-- ============================================================
do
    local pinned = refresh("P:free")
    pinned:Pin()
    local fo = refresh("P:child")
    check(pinned.frame:IsShown() and fo.frame:IsShown(), "drag: both panels are up going in")
    Pn:HideFollowing()
    check(not fo.frame:IsShown(), "drag: the follower goes down with the slab it is docked to")
    check(pinned.frame:IsShown(), "drag: the pinned panel stays on screen")
    -- Suspend and teardown still take everything.
    Pn:Hide()
    check(not pinned.frame:IsShown(), "suspend: Hide still takes every panel down")
end

reset()

-- ============================================================
-- 18. THE PIN MARKER'S SOURCE
-- The slab asks the panel module whether anything holds its element pinned, and
-- a pin-state change has to repaint: neither pinning nor crossing goes through
-- a selection change, which is the only other thing that repaints slabs.
-- ============================================================
do
    local po = refresh("P:free")
    check(not Pn:IsElementPinned("P:free"), "marker: a FOLLOWING panel is not a pin")
    local before = #highlights
    po:Pin()
    check(Pn:IsElementPinned("P:free"), "marker: pinning makes the element read as pinned")
    check(#highlights > before, "marker: ...and repaints the slabs so the marker appears")
    check(not Pn:IsElementPinned("P:host"), "marker: only the element the panel is bound to")
    check(not Pn:IsElementPinned(nil), "marker: no element, no pin")

    -- Move the selection on, so what is crossed below is a purely pinned panel
    -- and not one the mover still counts as its follower.
    refresh("P:host")
    check(Pn:IsElementPinned("P:free"), "marker: the pin survives a selection change")
    before = #highlights
    po.closeBtn._opts.onClick()
    check(not Pn:IsElementPinned("P:free"), "marker: crossing the panel drops the pin")
    check(#highlights > before, "marker: ...and repaints so the marker goes")
end

reset()
R:UnregisterAddon("P")
R.ready = wasReady
NS.db = nil
NS.Session = nil
NS.Proxy = nil
