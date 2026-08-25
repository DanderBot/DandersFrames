local NS = ...
local R = NS.Registry

-- ============================================================
-- FRAME + KIT STUBS
-- Panel.lua is UI-facing, so it is loaded here rather than by run.py, after
-- enough of the frame API and the DandersUI kit to build the panel for real.
-- Only the widgets the panel actually reads back are modelled; everything else
-- falls through to a no-op via __index.
-- ============================================================
local function stubFrame()
    -- fxIn/fxOut/... are plain values because Fx reads them as booleans; a
    -- __index fallback would hand back a (truthy) function and Fx.Cancel would
    -- try to :Stop() it.
    local f = { _shown = false, _alpha = 1, _scale = 1, _scripts = {}, _points = {}, _w = 0, _h = 0,
                fxIn = false, fxOut = false, fxPop = false, fxPopOut = false, fxTo = false,
                fxScale = false }
    function f:Show() self._shown = true end
    function f:Hide() self._shown = false end
    function f:IsShown() return self._shown end
    function f:SetShown(v) self._shown = v and true or false end
    function f:SetAlpha(v) self._alpha = v end
    function f:GetAlpha() return self._alpha end
    -- Real values, because Fx.ScaleTo rests wherever it is put: the hover lift
    -- is only observable as the scale it leaves behind.
    function f:SetScale(v) self._scale = v end
    function f:GetScale() return self._scale end
    function f:SetVertexColor(r, g, b, a) self._vertex = { r, g, b, a } end
    function f:SetSize(w, h) self._w, self._h = w, h end
    function f:SetWidth(w) self._w = w end
    function f:SetHeight(h) self._h = h end
    function f:GetWidth() return self._w end
    function f:GetHeight() return self._h end
    function f:GetSize() return self._w, self._h end
    function f:GetCenter() return 0, 0 end
    function f:CreateTexture() return stubFrame() end
    function f:CreateAnimationGroup() return nil end     -- Fx takes its headless path
    function f:ClearAllPoints() wipe(self._points) end
    function f:SetPoint(...) self._points[#self._points + 1] = { ... } end
    function f:SetScript(name, fn) self._scripts[name] = fn end
    function f:GetScript(name) return self._scripts[name] end
    function f:SetEnabled(v) self._enabled = v and true or false end
    function f:IsEnabled() return self._enabled ~= false end
    return setmetatable(f, { __index = function() return function() end end })
end

-- 7px per character, as in test_proxy, so the measured label columns are
-- deterministic.
local function stubFontString()
    local f = stubFrame()
    f._text = ""
    function f:SetText(t) self._text = t or "" end
    function f:GetText() return self._text end
    function f:GetStringWidth() return 7 * #self._text end
    function f:GetStringHeight() return 12 end
    return f
end

-- The dropdown surface the panel actually drives: a caption override, an
-- option set that can be swapped, and the enable state.
local function stubDropdown(opts)
    local d = stubFrame()
    d._opts = opts or {}
    d._options = d._opts.options
    d._enabled = true
    function d:SetDisplayOverride(text) self._override = text end
    function d:UpdateText() end
    function d:RebuildOptions(newOptions) if newOptions then self._options = newOptions end end
    return d
end

CreateFrame = function() return stubFrame() end
GameTooltip = stubFrame()
GetTime = function() return 0 end
IsShiftKeyDown = function() return false end
IsControlKeyDown = function() return false end
C_Timer = { After = function() end }     -- the header's deferred re-measure never fires

local COLORS = {
    textDim = { r = 0.5, g = 0.5, b = 0.5 }, text = { r = 0.9, g = 0.9, b = 0.9 },
    accent  = { r = 0.45, g = 0.45, b = 0.95 }, panel = { r = 0.12, g = 0.12, b = 0.12 },
    border  = { r = 0.25, g = 0.25, b = 0.25 }, anchored = { r = 0.55, g = 0.4, b = 0.85 },
    anchorRoot = { r = 0, g = 1, b = 0 }, danger = { r = 0.8, g = 0.2, b = 0.2 },
}
NS.UI = {
    MEDIA = "", Colors = COLORS,
    Space = { section = 10 }, RowGap = 14, RowGapTight = 8,
    RowHeight = { groupTitle = 26 },
    GetAccent = function() return COLORS.accent end,
    CreatePanelBackdrop = function() end,
    CreateElementBackdrop = function() end,
    CreateLabel = function(_, _, opts)
        local fs = stubFontString()
        if opts and opts.text then fs:SetText(opts.text) end
        return fs
    end,
    CreateButton = function(_, _, opts)
        local b = stubFrame()
        b._opts = opts
        if opts and opts.width then b._w = opts.width end
        function b:SetText(t) self._text = t end
        return b
    end,
    CreateGlyphButton = function(_, _, opts)
        local b = stubFrame()
        b._opts = opts
        if opts and opts.size then b._w, b._h = opts.size, opts.size end
        if opts and opts.width then b._w = opts.width end
        if opts and opts.height then b._h = opts.height end
        -- The kit's glyph texture, which the panel re-anchors to make room for
        -- the grip dots beside it.
        b.Icon = stubFrame()
        return b
    end,
    CreateEditBox = function(_, _, opts)
        local e = stubFrame()
        e._opts = opts
        function e:GetText() return "0" end
        function e:Refresh() end
        return e
    end,
    CreateDropdown = function(_, _, opts) return stubDropdown(opts) end,
    CreateGroupBox = function(_, _, opts)
        local box = stubFrame()
        box._opts = opts
        box.content = stubFrame()
        box.title = stubFontString()
        box.title:SetText(opts and opts.title or "")
        -- The real box is pad + title + content + pad; mirrored so the panel's
        -- measured height is the one the kit would give it.
        local pad = (opts and opts.padding) or 10
        function box:SetContentHeight(h)
            self.content:SetHeight(h)
            self:SetHeight(pad + 26 + h + pad)
        end
        box:SetContentHeight(1)
        return box
    end,
}

-- Session/Proxy stand-ins: everything the panel calls is recorded rather than
-- performed, so what is under test is the panel's own wiring.
local calls = {}
local hover = nil
NS.Proxy = {
    proxies = {},
    GetUnlockFrame = function() return stubFrame() end,
    LinkHover = function() return hover end,
    RefreshAll = function() end,
}
NS.Session = {
    selected = nil, linking = nil,
    IsActive = function() return true end,
    IsSuspended = function() return false end,
    BeginLink = function(self, el, mode)
        calls[#calls + 1] = { "begin", el.id, mode }
        self.linking = { id = el.id, mode = mode or "primary" }
    end,
    CancelLink = function(self) calls[#calls + 1] = { "cancel" }; self.linking = nil end,
    EndLink = function(self, targetId) calls[#calls + 1] = { "end", targetId }; self.linking = nil end,
    SetAnchorSpec = function(_, el, changes) calls[#calls + 1] = { "spec", el.id, changes } end,
    AnchorInPlace = function(_, el, t) calls[#calls + 1] = { "anchor", el.id, t } end,
    SetFallback = function(_, el, t) calls[#calls + 1] = { "fallback", el.id, t } end,
}
NS.Lib = NS.Lib or { callbacks = { Fire = function() end } }
load_addon_file("Picker.lua")
load_addon_file("Panel.lua")
local Pn, Sess = NS.Panel, NS.Session
local L = NS.L

local wasReady = R.ready
R.ready = true
NS.db = { showHiddenMovers = true, panelSide = "auto", addons = {} }

local function elDef(pos)
    return { title = "x", frame = FakeFrame(960, 540, 100, 40),
             getPos = function() return pos end, onChanged = function() end }
end

R:RegisterAddon("P", { title = "P" })
local freePos = { point = "CENTER", x = 0, y = 0 }
local childPos = { point = "CENTER", x = 0, y = 0 }
R:Register("P", "host", elDef({ point = "CENTER", x = 200, y = 0 }))
R:Register("P", "spare", elDef({ point = "CENTER", x = -200, y = 0 }))
R:Register("P", "free", elDef(freePos))
R:Register("P", "child", elDef(childPos))

local function refresh(id)
    Sess.selected = id
    Pn:Refresh()
    return Pn.frame
end

-- Free element: the block is all there, the Target row reads "None", and only
-- the primary handle stays live -- it is the way IN to anchoring.
do
    local f = refresh("P:free")
    -- The Target row's empty state TEACHES: the word plus the chain glyph
    -- inline, so the sentence points at the handle beside it. The Backup row
    -- stays a bare "None" -- it is greyed here and has no gesture to offer.
    local cap = f.targetRow.picker._override
    check(cap:find("None", 1, true) == 1, "free: the target caption still opens with None")
    check(cap:find("|TInterface\\AddOns\\DandersMover\\Media\\link.tga:12:12|t", 1, true) ~= nil,
        "free: the target caption carries the chain glyph inline")
    check(cap:find("link", 1, true) ~= nil, "free: the target caption names the gesture")
    eq(f.backupRow.picker._override, L["None"], "free: backup reads None")
    check(f.targetRow.handle:IsEnabled(), "free: primary handle stays enabled")
    check(not f.backupRow.handle:IsEnabled(), "free: backup handle disabled")
    check(f.backupRow.picker._enabled == false, "free: backup picker disabled")
    check(f.edgeDrop._enabled == false and f.alignDrop._enabled == false, "free: seat pair disabled")
    eq(f.edgeLabel:GetText(), L["Edge"], "free: seat labels default to Edge/Align")
    eq(f.alignLabel:GetText(), L["Align"], "free: align label")
    eq(f.targetRow.label:GetText(), L["Target"], "free: target row is labelled")
    eq(f.backupRow.label:GetText(), L["Backup"], "free: backup row is labelled")
    eq(f.anchorBox.title:GetText(), L["Anchor"], "the block is a titled sub-section")
    -- An inline dropdown's factory label is hidden, so the kit's usual
    -- label-hover tooltip has nothing to sit on: the OPENER carries one.
    eq(f.targetRow.picker.openerTooltip.title, L["Target"], "the target opener names itself")
    eq(f.backupRow.picker.openerTooltip.title, L["Backup"], "the backup opener names itself")
    eq(f.targetRow.handle._opts.tooltip.lines[1], L["Drag onto another mover to attach"],
        "the primary handle says what dragging it does")
    eq(f.backupRow.handle._opts.tooltip.lines[1], L["Drag onto another mover to set the backup anchor"],
        "the backup handle says what dragging it does")
end

-- Both label columns are measured to the wider of their pair, so the two
-- pickers start on the same column.
do
    local f = Pn.frame
    eq(f.targetRow.label:GetWidth(), f.backupRow.label:GetWidth(), "Target/Backup share a label column")
    eq(f.edgeLabel:GetWidth(), f.alignLabel:GetWidth(), "Edge/Align share a label column")
end

-- Anchoring must not change the panel's height: every row is always there.
local freeH
do
    freeH = Pn.frame:GetHeight()
    childPos.anchor = { target = "P:host", edge = "bottom", align = "start", offsetX = 0, offsetY = 0 }
    local f = refresh("P:child")
    eq(f:GetHeight(), freeH, "anchoring does not resize the panel")
    -- Anchored, the caption is the bare target name: the teaching line is the
    -- EMPTY state's job and would be noise once the row has an answer.
    eq(f.targetRow.picker._override, R:Get("P:host").title, "anchored: target names the target")
    check(f.targetRow.picker._override:find("|T", 1, true) == nil,
        "anchored: no inline glyph in the caption")
    check(f.backupRow.picker._enabled, "anchored: backup picker enabled")
    check(f.backupRow.handle:IsEnabled(), "anchored: backup handle enabled")
    check(f.edgeDrop._enabled and f.alignDrop._enabled, "anchored: seat pair enabled")
    eq(f.edgeDrop._opts.get(), "bottom", "edge reads the record")
    eq(f.alignDrop._opts.get(), "start", "align reads the record")
    f.edgeDrop._opts.set("top")
    local last = calls[#calls]
    check(last[1] == "spec" and last[3].edge == "top", "outside mode writes `edge`")
end

-- Point mode: the same pair of dropdowns, relabelled, with the 9 anchor points.
do
    childPos.anchor = { target = "P:host", mode = "point", point = "TOPLEFT",
                        relPoint = "BOTTOMLEFT", offsetX = 0, offsetY = 0 }
    local f = refresh("P:child")
    eq(f.edgeLabel:GetText(), L["Point"], "point mode: left label is Point")
    eq(f.alignLabel:GetText(), L["Rel point"], "point mode: right label is Rel point")
    eq(f.edgeDrop._options.TOPLEFT, "TOPLEFT", "point mode: the 9 points are the option set")
    eq(f.edgeDrop._opts.get(), "TOPLEFT", "point reads the record")
    eq(f.alignDrop._opts.get(), "BOTTOMLEFT", "relPoint reads the record")
    f.alignDrop._opts.set("TOP")
    local last = calls[#calls]
    check(last[1] == "spec" and last[3].relPoint == "TOP" and last[3].align == nil,
        "point mode writes `relPoint`, not `align`")
    eq(f:GetHeight(), freeH, "point mode does not resize the panel either")
    -- ...and back, so the swap is not one-way.
    childPos.anchor = { target = "P:host", edge = "bottom", align = "start", offsetX = 0, offsetY = 0 }
    f = refresh("P:child")
    eq(f.edgeLabel:GetText(), L["Edge"], "back to outside mode: labels swap back")
    eq(f.edgeDrop._options.right, L["Right"], "back to outside mode: edges are the option set")
end

-- The two handles run the same gesture with different modes, and both end it
-- on whatever the cursor was over.
do
    local f = refresh("P:child")
    wipe(calls)
    f.targetRow.handle:GetScript("OnMouseDown")(f.targetRow.handle, "LeftButton")
    eq(calls[1][3], "primary", "the target handle begins a PRIMARY link")
    hover = "P:spare"
    f.targetRow.handle:GetScript("OnMouseUp")(f.targetRow.handle, "LeftButton")
    check(calls[2][1] == "end" and calls[2][2] == "P:spare", "release ends the link on the hovered target")

    wipe(calls)
    f.backupRow.handle:GetScript("OnMouseDown")(f.backupRow.handle, "LeftButton")
    eq(calls[1][3], "fallback", "the backup handle begins a FALLBACK link")
    f.backupRow.handle:GetScript("OnMouseUp")(f.backupRow.handle, "LeftButton")
    check(calls[2][1] == "end", "the backup release ends the same gesture")

    -- Right-click during a gesture cancels from either handle.
    wipe(calls)
    Sess.linking = { id = "P:child", mode = "primary" }
    f.backupRow.handle:GetScript("OnMouseDown")(f.backupRow.handle, "RightButton")
    eq(calls[1][1], "cancel", "right-click cancels")
    hover = nil
end

-- The handles read as grips: dots beside the chain, and a hover state that
-- lifts, brightens and takes the move cursor. Both handles get the same
-- treatment -- they are the same gesture.
do
    local f = refresh("P:free")
    for _, row in ipairs({ f.targetRow, f.backupRow }) do
        local h = row.handle
        check(h.Grip ~= nil, "the handle carries grip dots beside the chain")
        check(h:GetScript("OnEnter") and h:GetScript("OnLeave"), "the handle has hover scripts")
        check(h:GetWidth() > h:GetHeight(), "the handle is a grip box, not a square icon")
    end
    -- The picker must NOT be pinned to the handle: a lift would drag it along.
    local pinnedToHandle = false
    for _, p in ipairs(f.targetRow.picker._points) do
        if p[2] == f.targetRow.handle then pinnedToHandle = true end
    end
    check(not pinnedToHandle, "the picker is anchored to the row, not to the lifting handle")
end

-- Hover: lift on enter, settle on leave, and the move cursor on the way in and
-- out. SetCursor is probed and pcall'd, so neither a missing path nor a
-- throwing API may escape into the hover.
do
    local f = refresh("P:free")
    local h = f.targetRow.handle
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
    local b = f.backupRow.handle
    check(not b:IsEnabled(), "free: the backup handle is the disabled case")
    b:GetScript("OnEnter")(b)
    eq(b:GetScale(), 1, "a disabled handle does not lift")
    eq(#cur, 0, "a disabled handle does not take the cursor")
    b:GetScript("OnLeave")(b)

    SetCursor, ResetCursor = nil, nil
end

-- The backup row names its own target, and the Target row says so when the
-- backup is the block actually holding the element.
do
    childPos.anchor = { target = "P:host", edge = "bottom", align = "start",
                        offsetX = 0, offsetY = 0,
                        fallback = { target = "P:spare", edge = "bottom", align = "start",
                                     offsetX = 0, offsetY = 0 } }
    local f = refresh("P:child")
    eq(f.backupRow.picker._override, R:Get("P:spare").title, "backup row names the backup target")
    check(f.targetRow.picker._override:find(L["(backup)"], 1, true) == nil,
        "primary available: no (backup) marker")
    -- Hide the primary: the backup takes over and the Target row says which.
    R:Get("P:host").frame._shown = false
    f = refresh("P:child")
    check(f.targetRow.picker._override:find(L["(backup)"], 1, true) == 1,
        "backup driving: the Target row is marked (backup)")
    R:Get("P:host").frame._shown = true
end

R:UnregisterAddon("P")
R.ready = wasReady
NS.db = nil
NS.Session = nil
NS.Proxy = nil
