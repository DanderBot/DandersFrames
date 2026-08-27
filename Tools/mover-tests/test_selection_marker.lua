local NS = ...

-- ============================================================
-- UI:CreateSelectionMarker -- ONE BAR PER GROUP, WHICH MOVES
--
-- The settings shell has two groups whose selection used to be drawn as N
-- stripes switching off here and on there: the mode tabs along deck 2, and the
-- nav's left rail. Both now share one bar that GLIDES between members. What is
-- under test is the DECISION -- glide or land instantly, and where -- not the
-- animation itself, which is Fx.MoveTo's and is tested in test_fx.lua.
--
--   * a group with nothing selected yet lands instantly; there is no "from";
--   * so does one whose previous member has since been hidden, or whose bar is
--     not on screen -- a glide out of a stale position reads worse than a blink;
--   * a normal switch between two visible members glides, at the group's
--     duration, and the new member's accent is worn from the START of it;
--   * the bar takes the member's whole edge -- bottom for a tab row, left for a
--     nav list -- so a translated label carries it without anyone measuring;
--   * hiding the member it marks takes the bar down with it, which a per-member
--     stripe got for free and a shared one has to be told;
--   * and StyleButton can be asked for a tab with NO stripe of its own, which is
--     what lets a group hand its selection to one of these.
--
-- ⚠ A FRESH NAMESPACE, NOT THE SHARED ONE -- the same rule test_widgets_slider
-- states: this file installs the REAL Widgets.lua, which would replace factories
-- the popout and panel suites build their fixtures from.
--
-- ☠ Every global it replaces is restored at the end.
-- ============================================================

local prevCreateFrame, prevTimer = CreateFrame, C_Timer

local ns = {}
local UI = {
    _state = {}, _priv = {}, MEDIA = "",
    Colors = {
        panel   = { r = 0.12, g = 0.12, b = 0.12, a = 1 },
        element = { r = 0.18, g = 0.18, b = 0.18, a = 1 },
        border  = { r = 0.25, g = 0.25, b = 0.25, a = 1 },
        hover   = { r = 0.22, g = 0.22, b = 0.22, a = 1 },
        accent  = { r = 0.45, g = 0.45, b = 0.95, a = 1 },
        text    = { r = 0.9, g = 0.9, b = 0.9 },
        textDim = { r = 0.5, g = 0.5, b = 0.5 },
    },
    RowHeight = { slider = 50, checkbox = 35 },
    RowGap = 14,
}
ns.__DandersUI = UI
function UI.SnapLen(_, n) return n end
function UI.SnapHeightEven(_, n) return n end
function UI.StyleScrollBar() end
function UI._priv.CreateElementBackdrop(frame) return frame end
function UI._priv.CreatePanelBackdrop(frame) return frame end
local ACCENT = { r = 0.45, g = 0.45, b = 0.95, a = 1 }
function UI:GetAccent() return ACCENT end
function UI:Hook(name) local h = rawget(self, "hooks") return h and h[name] or nil end
function UI:Call(name, ...) local fn = self:Hook(name) if not fn then return nil end return fn(...) end

-- ---- Fx, RECORDED ---------------------------------------------------
-- The marker's job stops at "call MoveTo or place it directly". Swapping the
-- real helper for a recorder is what makes that boundary assertable -- and it is
-- honest: Fx.MoveTo's own contract (anchors first, reversed Translation,
-- cancel-safety) is pinned in test_fx.lua against the real function.
local fxLog = { moves = 0, cancels = 0, dur = nil }
UI.Fx = {
    MoveTo = function(target, place, dur)
        fxLog.moves = fxLog.moves + 1
        fxLog.dur = dur
        place(target)                       -- as the real one does: anchors first
    end,
    Cancel = function() fxLog.cancels = fxLog.cancels + 1 end,
}

-- ---- frame stub -----------------------------------------------------
local DATA_KEYS = { ThemeListeners = true, Text = true, Icon = true, Texture = true,
                    dfTabStripe = true, dfActive = true, dfDisabled = true,
                    Highlight = true, owner = true, UpdateTheme = true }
local function dataAwareMeta(_, k)
    if DATA_KEYS[k] then return nil end
    if type(k) == "string" and k:byte(1) == 95 then return nil end   -- "_"
    return function() end
end

CreateFrame = function(kind, _, parent)
    local f = FakeUIFrame()
    setmetatable(f, { __index = dataAwareMeta })
    f._kind = kind
    f._children = {}
    f._parent = parent
    f.GetParent = function(self) return self._parent end
    -- HookScript COMPOSES here, unlike the shared stub's replace-in-place: the
    -- marker hooks OnHide/OnShow on members that may already own one.
    f.HookScript = function(self, name, fn)
        local prev = self._scripts[name]
        self._scripts[name] = prev and function(...) prev(...) return fn(...) end or fn
    end
    if type(parent) == "table" then
        local kids = rawget(parent, "_children")
        if not kids then kids = {}; parent._children = kids end
        kids[#kids + 1] = f
    end
    return f
end
C_Timer = { After = function(_, fn) fn() end }

load_ui_file_into("Widgets.lua", ns)

local host = setmetatable({ hooks = { L = setmetatable({}, { __index = function(_, k) return k end }) } },
                          { __index = UI })
local function fire(frame, script, ...) local fn = frame:GetScript(script) if fn then return fn(frame, ...) end end
local function member(parent) local m = CreateFrame("Button", nil, parent); m:Show(); return m end
-- The anchor the marker last laid down, as (point, relativeTo, relativePoint).
local function anchorOf(marker, i)
    local p, rel, rp = marker:GetPoint(i)
    return p, rel, rp
end

check(type(UI.CreateSelectionMarker) == "function", "marker: the factory is published")
eq(UI.CreateSelectionMarkerNative, UI.CreateSelectionMarker,
   "marker: ...with the *Native alias every other factory carries")

-- ============================================================
-- 1. WHAT THE FACTORY BUILDS
-- ============================================================
do
    local deck = CreateFrame("Frame")
    deck:SetFrameLevel(4)
    local m = host:CreateSelectionMarker(deck, { axis = "x", thickness = 3 })
    eq(m:GetHeight(), 3, "build: an x-axis marker is sized on its SHORT axis (height)")
    check(not m:IsShown(), "build: it starts hidden -- nothing is selected yet")
    eq(m:GetOwner(), nil, "build: ...and marks nothing")
    eq(m._flags.level, 9, "build: it sits above the members it marks (container + 5)")
    eq(m._flags.mouse, false, "build: and never takes a click off the tab under it")
    check(m.Texture ~= nil, "build: it carries one flat texture")
    eq(m.Texture._allPoints, m, "build: filling the bar")

    local rail = host:CreateSelectionMarker(deck, { axis = "y", thickness = 3 })
    eq(rail:GetWidth(), 3, "build: a y-axis marker is sized on ITS short axis (width)")
end

-- ============================================================
-- 2. THE FIRST SELECTION LANDS INSTANTLY
-- ============================================================
do
    fxLog.moves, fxLog.cancels = 0, 0
    local deck = CreateFrame("Frame")
    local a, b = member(deck), member(deck)
    local m = host:CreateSelectionMarker(deck, { axis = "x" })

    m:SetTo(a, { r = 1, g = 0, b = 0 })
    eq(fxLog.moves, 0, "first: nothing to glide from, so no glide")
    check(m:IsShown(), "first: the bar is on screen")
    eq(m:GetOwner(), a, "first: ...marking the member it was given")
    eq(m.Texture._color.r, 1, "first: wearing the colour it was handed")

    local p1, rel1, rp1 = anchorOf(m, 1)
    local p2, rel2, rp2 = anchorOf(m, 2)
    eq(p1, "BOTTOMLEFT", "first: an underline spans the member's BOTTOM edge")
    eq(rel1, a, "first: ...anchored to that member")
    eq(rp1, "BOTTOMLEFT", "first: ...corner to corner")
    eq(p2, "BOTTOMRIGHT", "first: ...and the far end too")
    eq(rel2, a, "first: ...on the same member")
    eq(rp2, "BOTTOMRIGHT", "first: ...corner to corner")
    eq(m:GetNumPoints(), 2, "first: exactly two anchors -- the bar takes the whole edge")
end

-- ============================================================
-- 3. A NORMAL SWITCH GLIDES, AND SWAPS COLOUR AT THE START OF IT
-- ============================================================
do
    fxLog.moves, fxLog.dur = 0, nil
    local deck = CreateFrame("Frame")
    local party, raid = member(deck), member(deck)
    local m = host:CreateSelectionMarker(deck, { axis = "x", duration = 0.12 })

    m:SetTo(party, { r = 0.45, g = 0.45, b = 0.95 })
    m:SetTo(raid, { r = 0.95, g = 0.5, b = 0.2 })
    eq(fxLog.moves, 1, "glide: two visible members and a bar on screen -- it glides")
    eq(fxLog.dur, 0.12, "glide: at the group's duration")
    eq(m:GetOwner(), raid, "glide: the new member is the owner")
    eq(m.Texture._color.r, 0.95, "glide: and the RAID accent is already on before it moves")
    local _, rel = anchorOf(m, 1)
    eq(rel, raid, "glide: the anchors are the destination's, laid down at once")

    -- ...and back again is another glide, not a special case.
    m:SetTo(party, { r = 0.45, g = 0.45, b = 0.95 })
    eq(fxLog.moves, 2, "glide: the return trip glides too")
end

-- ============================================================
-- 4. THE THREE WAYS IT LANDS INSTANTLY INSTEAD
-- ============================================================
do
    -- (a) the caller says so -- what a window that is not shown yet passes.
    fxLog.moves = 0
    local deck = CreateFrame("Frame")
    local a, b = member(deck), member(deck)
    local m = host:CreateSelectionMarker(deck, {})
    m:SetTo(a)
    m:SetTo(b, nil, true)
    eq(fxLog.moves, 0, "instant: an explicit instant never glides")
    eq(m:GetOwner(), b, "instant: ...but still lands on the new member")
end

do
    -- (b) the previous member has been hidden since -- a collapsed nav category.
    fxLog.moves = 0
    local deck = CreateFrame("Frame")
    local a, b = member(deck), member(deck)
    local m = host:CreateSelectionMarker(deck, { axis = "y" })
    m:SetTo(a)
    a:Hide()
    m:SetTo(b)
    eq(fxLog.moves, 0, "instant: a hidden 'from' has no visible position to sweep out of")
    eq(m:GetOwner(), b, "instant: ...and the bar lands on the new row")
    local p1, _, _ = anchorOf(m, 1)
    local p2, _, _ = anchorOf(m, 2)
    eq(p1, "TOPLEFT", "instant: a y-axis rail runs down the member's LEFT edge")
    eq(p2, "BOTTOMLEFT", "instant: ...top to bottom of it")
end

do
    -- (c) the bar itself is not on screen (it was cleared, or never shown).
    fxLog.moves = 0
    local deck = CreateFrame("Frame")
    local a, b = member(deck), member(deck)
    local m = host:CreateSelectionMarker(deck, {})
    m:SetTo(a)
    m:Clear()
    m:SetTo(b)
    eq(fxLog.moves, 0, "instant: a bar that is not on screen cannot glide onto anything")
    check(m:IsShown(), "instant: ...it simply appears where it belongs")
end

-- Re-selecting the SAME member is not a move.
do
    fxLog.moves = 0
    local deck = CreateFrame("Frame")
    local a = member(deck)
    local m = host:CreateSelectionMarker(deck, {})
    m:SetTo(a); m:SetTo(a); m:SetTo(a)
    eq(fxLog.moves, 0, "same: re-selecting the member already marked glides nowhere")
    eq(m:GetOwner(), a, "same: ...and it still marks it")
end

-- ============================================================
-- 5. CLEARING
-- ============================================================
do
    fxLog.cancels = 0
    local deck = CreateFrame("Frame")
    local a, b = member(deck), member(deck)
    local m = host:CreateSelectionMarker(deck, {})
    m:SetTo(a)

    m:ClearIf(b)
    check(m:IsShown(), "clear: ClearIf on a member it does NOT mark changes nothing")
    eq(m:GetOwner(), a, "clear: ...and the owner is untouched")

    m:ClearIf(a)
    check(not m:IsShown(), "clear: ClearIf on the member it DOES mark takes the bar down")
    eq(m:GetOwner(), nil, "clear: ...and it marks nothing")
    check(fxLog.cancels > 0, "clear: a running glide is cancelled, not left to land on a dead member")

    -- SetTo(nil) is Clear.
    m:SetTo(a)
    m:SetTo(nil)
    check(not m:IsShown(), "clear: SetTo(nil) clears it")
    eq(m:GetOwner(), nil, "clear: ...owner and all")
end

-- ============================================================
-- 6. THE BAR GOES DOWN WITH THE MEMBER IT MARKS
-- A per-member stripe was a CHILD of the member and got this for free. A shared
-- bar is parented to the container, so collapsing the nav category holding the
-- selected page would otherwise leave the rail beside whichever row moved up.
-- ============================================================
do
    local deck = CreateFrame("Frame")
    local a, b = member(deck), member(deck)
    local m = host:CreateSelectionMarker(deck, { axis = "y" })
    m:SetTo(a)
    check(m:IsShown(), "follow: the bar is up")

    a:Hide(); fire(a, "OnHide")
    check(not m:IsShown(), "follow: hiding the marked row takes the bar with it")
    a:Show(); fire(a, "OnShow")
    check(m:IsShown(), "follow: ...and showing it again brings the bar back")

    -- ...but only while that member is still the one being marked.
    m:SetTo(b)
    a:Hide(); fire(a, "OnHide")
    check(m:IsShown(), "follow: a row that is no longer marked cannot hide the bar")
    eq(m:GetOwner(), b, "follow: which still marks the current one")
end

-- A member's OWN OnHide handler survives the marker hooking it: HookScript
-- composes, and a nav row that already had one must keep it.
do
    local deck = CreateFrame("Frame")
    local a = member(deck)
    local own = 0
    a:SetScript("OnHide", function() own = own + 1 end)
    local m = host:CreateSelectionMarker(deck, {})
    m:SetTo(a)
    fire(a, "OnHide")
    eq(own, 1, "follow: the member's own OnHide still runs")
    check(not m:IsShown(), "follow: ...alongside the marker's")
end

-- ============================================================
-- 7. StyleButton CAN BE ASKED FOR A TAB WITH NO STRIPE
-- Which is what lets a group hand its selection to a shared marker. Everything
-- else about the tab style is unchanged -- that is the whole point.
-- ============================================================
do
    local deck = CreateFrame("Frame")
    local accent = { r = 0.2, g = 0.8, b = 0.4 }

    local plain = host:StyleButton(CreateFrame("Button", nil, deck),
        { tab = true, text = "PARTY", accent = accent })
    check(plain.dfTabStripe ~= nil, "stripe: an underline tab still draws its own stripe by default")

    local shared = host:StyleButton(CreateFrame("Button", nil, deck),
        { tab = true, tabStripe = false, text = "PARTY", accent = accent })
    eq(shared.dfTabStripe, nil, "stripe: tabStripe=false builds none")

    -- SetActive still does everything ELSE a tab's SetActive does.
    shared:SetActive(true)
    eq(shared.dfActive, true, "stripe: SetActive still marks it active")
    shared:SetActive(false)
    eq(shared.dfActive, false, "stripe: ...and back")
end

-- ---- restore the globals -------------------------------------------
CreateFrame, C_Timer = prevCreateFrame, prevTimer
