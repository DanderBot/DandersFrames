local NS = ...

-- ============================================================
-- TEST HOST
-- ------------------------------------------------------------
-- run.py installs Fx onto `ns.__DandersUI`, a PLAIN table standing in for the
-- library (a headless run never loads Core.lua, so there is no LibStub lib and
-- no NewHost). Popout.lua's own handshake is `NS.__DandersUI`, so that table IS
-- the library as far as it is concerned.
--
-- The runtime shape is: a HOST whose metatable __index is the library, factories
-- called on the host (`self:CreateLabel(...)` inside a `function UI:CreatePopout`
-- body resolves through that __index with self = the host), and everything that
-- differs per consumer -- locale, accent -- read off the host. The fake host
-- below is exactly that, with stub factories standing in for Widgets.lua.
--
-- Popout.lua's host surface is deliberately SMALL, and this list is the whole of
-- it: if it grows, this stub has to grow with it and the honesty of the test
-- goes with it.
-- ============================================================
local UI = NS.__DandersUI

UI.MEDIA = ""
UI.Colors = { text = { r = 0.9, g = 0.9, b = 0.9 }, textDim = { r = 0.5, g = 0.5, b = 0.5 } }

local ACCENT = { r = 0.45, g = 0.45, b = 0.95, a = 1 }
function UI:GetAccent() return ACCENT end
function UI:CreatePanelBackdrop() end
function UI:CreateLabel(parent, opts)
    local fs = FakeUIFrame()
    if opts and opts.text then fs:SetText(opts.text) end
    return fs
end
-- Buttons come back SHOWN, as a freshly created WoW button does -- "the pin
-- button hides once pinned" is only a real assertion if it started visible.
local function stubButton(opts)
    local b = FakeUIFrame(16, 16)
    b._opts = opts
    b:Show()
    return b
end
function UI:CreateCloseButton(_, opts) return stubButton(opts) end
function UI:CreateGlyphButton(_, opts) return stubButton(opts) end

-- Locale passthrough: the mover's own L falls back to the key, so a stub that
-- answers with the key is the honest stand-in.
local L = setmetatable({}, { __index = function(_, k) return k end })

local host = setmetatable({ hooks = { L = L } }, { __index = UI })

-- ---- WoW globals the popout touches -------------------------------
local prevCreateFrame, prevTimer = CreateFrame, C_Timer
CreateFrame = function() return FakeUIFrame() end
-- Fires immediately, and RECORDS the delay: the Fx sequencing claims (the beam
-- waits out the pop-in, the beam leaves before the popout does) are about ORDER
-- and about which duration was waited on, neither of which needs real time.
local delays = {}
C_Timer = { After = function(d, fn) delays[#delays + 1] = d; fn() end }

-- UIParent is the shim's 1920x1080 rect centred at (960, 540), so a region's
-- "UIParent-centre" rect is its screen centre minus that.
local CX, CY = 960, 540

-- A followable source: a shown rect the test can move with SetFakeCenter.
local function source(w, h, x, y)
    local f = FakeUIFrame(w, h, x or CX, y or CY)
    f:Show()
    return f
end

-- Every popout in these tests is 100 wide with a 50-tall content, so the frame
-- is 120 x (22 + 10 + 50 + 10) = 120 x 92. The dock geometry below is worked
-- out from those numbers.
local W, FRAME_W, FRAME_H = 100, 120, 92
local DOCK_GAP = 12

local builds = 0
local function buildContent(_, content)
    builds = builds + 1
    content:SetHeight(50)
    content._built = builds
end

local function popout(opts)
    opts.width = opts.width or W
    opts.build = opts.build or buildContent
    return host:CreatePopout(opts)
end

load_ui_file("Popout.lua")

-- ============================================================
-- 1. POOLING
-- Per host+key there is ONE unpinned popout, and asking twice must not build
-- twice -- that is the entire point of the pool.
-- ============================================================
do
    builds = 0
    local a = popout({ key = "pool", title = "First" })
    local b = popout({ key = "pool", title = "Second" })
    check(a == b, "pool: the same key hands back the same instance")
    eq(builds, 1, "pool: build ran once")
    eq(a.titleFS:GetText(), "Second", "pool: the reused instance took the new header")
    eq(a.content._built, 1, "pool: the content is the one build mounted")
    a:Close()
end

-- ============================================================
-- 2. PIN PROMOTION
-- Pinning takes the instance OUT of the pool with its content intact; the next
-- request for the key gets a fresh frame and a fresh build.
-- ============================================================
do
    builds = 0
    local src = source(80, 40)
    local pinned = popout({ key = "promote", title = "Pinned" })
    pinned:Follow(src)
    check(not pinned.frame:IsMovable(), "promote: not draggable before pinning")
    check(pinned.titleBar:GetScript("OnDragStart") == nil, "promote: no drag script before pinning")
    pinned:Pin()
    check(pinned:IsPinned(), "promote: Pin pins")
    check(pinned.frame:IsMovable(), "promote: pinned means draggable")
    check(pinned.titleBar:GetScript("OnDragStart") ~= nil, "promote: the title bar drags once pinned")
    check(not pinned.pinBtn:IsShown(), "promote: the pin button hides once pinned")

    local fresh = popout({ key = "promote", title = "Fresh" })
    check(fresh ~= pinned, "promote: the key builds a NEW instance once the old one is pinned")
    eq(builds, 2, "promote: the fresh instance ran build")
    eq(pinned.content._built, 1, "promote: the pinned instance kept its own content")
    eq(fresh.content._built, 2, "promote: ...and the fresh one has its own")
    check(not pinned.closed, "promote: the pinned instance is still live")
    pinned:Close(); fresh:Close()
end

-- ============================================================
-- 3. FAMILY EXCLUSIVITY
-- A family is an exclusivity CLAIM, so it evicts pinned members too. A nil
-- family coexists with everything.
-- ============================================================
do
    local reasons = {}
    local one = popout({ key = "fam1", family = "sidecar",
                         onClose = function(_, r) reasons.one = r end })
    one:Follow(source(80, 40))
    one:Pin()
    check(one:IsPinned(), "family: the first member is pinned")

    local two = popout({ key = "fam2", family = "sidecar",
                         onClose = function(_, r) reasons.two = r end })
    check(one.closed, "family: opening a sibling closes the pinned member")
    eq(reasons.one, "family", "family: ...with reason 'family'")
    check(not two.closed, "family: the newcomer stays")

    local free1 = popout({ key = "free1", onClose = function(_, r) reasons.free1 = r end })
    local free2 = popout({ key = "free2" })
    check(not free1.closed, "family: a nil family coexists with its own kind")
    check(not two.closed, "family: a nil family does not evict a family member")
    eq(reasons.free1, nil, "family: no close fired for the coexisting popout")
    two:Close(); free1:Close(); free2:Close()
end

-- ============================================================
-- 4. pinnable = false
-- No pin button, AutoPin does nothing, and the popout dies with its source --
-- it has no way to outlive it.
-- ============================================================
do
    local reason
    local src = source(80, 40)
    local p = popout({ key = "nopin", pinnable = false,
                       onClose = function(_, r) reason = r end })
    check(p.pinBtn == nil, "unpinnable: no pin button is built")
    p:Follow(src)
    p:AutoPin()
    check(not p:IsPinned(), "unpinnable: AutoPin is a no-op")
    p:Pin()
    check(not p:IsPinned(), "unpinnable: an explicit Pin is refused too")

    src:Hide()
    p.frame:GetScript("OnUpdate")(p.frame)
    check(p.closed, "unpinnable: a vanished source closes it")
    eq(reason, "source", "unpinnable: ...with reason 'source'")
end

-- A PINNABLE popout must NOT be closed by source loss: outliving its source is
-- exactly what pinning is for, and what that means is the consumer's call.
do
    local closed = false
    local src = source(80, 40)
    local p = popout({ key = "survives", onClose = function() closed = true end })
    p:Follow(src)
    p:Pin()
    src:Hide()
    p.frame:GetScript("OnUpdate")(p.frame)
    check(not closed, "pinned: source loss does not close a pinnable popout")
    p:Close()
end

-- ============================================================
-- 5. canAutoPin
-- Evaluated PER CALL, so the same popout can be refused now and allowed later.
-- It gates only the AUTOMATIC path: an explicit Pin is the user asking.
-- ============================================================
do
    local allow = false
    local src = source(80, 40)
    local p = popout({ key = "gate", canAutoPin = function() return allow end })
    p:Follow(src)
    p:AutoPin()
    check(not p:IsPinned(), "canAutoPin: a false gate makes AutoPin a no-op")
    allow = true
    p:AutoPin()
    check(p:IsPinned(), "canAutoPin: a true gate pins")
    check(not p.pinBtn:IsShown(), "canAutoPin: the silent pin still retires the button")
    p:Close()

    local hard = popout({ key = "gatehard", canAutoPin = false })
    hard:Follow(source(80, 40))
    hard:AutoPin()
    check(not hard:IsPinned(), "canAutoPin: a plain false gates AutoPin")
    hard:Pin()
    check(hard:IsPinned(), "canAutoPin: an explicit Pin is not gated")
    hard:Close()
end

-- ============================================================
-- 6. CLOSE REASONS
-- The shell reports WHY; it never decides what closing means.
-- ============================================================
do
    local reason
    local cross = popout({ key = "cross", onClose = function(_, r) reason = r end })
    cross:Follow(source(80, 40))
    cross.closeBtn._opts.onClick()
    eq(reason, "cross", "close: the cross reports 'cross'")

    reason = nil
    local api = popout({ key = "api", onClose = function(_, r) reason = r end })
    api:Follow(source(80, 40))
    api:Close()
    eq(reason, "api", "close: Close() defaults to 'api'")

    reason = nil
    api:Close()
    eq(reason, nil, "close: closing twice fires onClose once")
end

-- ============================================================
-- 7. FOLLOW RE-DOCK
-- The follow is one OnUpdate that early-outs while nothing has moved. Driven
-- here by hand, which is the whole reason it is a plain script.
-- ============================================================
do
    local src = source(80, 40, CX, CY)
    local p = popout({ key = "follow" })
    p:Follow(src)
    eq(p.side, "right", "follow: a source in open screen docks right")
    eq(p.frame:GetHeight(), FRAME_H, "follow: the frame sized itself to the content")
    eq(p.frame._points[1][1], "TOPLEFT", "follow: right-docked hangs from the source's top-right")

    -- Count re-anchors so the early-out is proved, not assumed.
    local docks = 0
    local realSetPoint = p.frame.SetPoint
    p.frame.SetPoint = function(s, ...) docks = docks + 1 return realSetPoint(s, ...) end

    p.frame:GetScript("OnUpdate")(p.frame)
    eq(docks, 0, "follow: a tick with nothing moved re-docks nothing")

    -- Hard against the right screen edge there is no room on the right, so the
    -- side flips -- which is the observable proof the re-dock ran.
    src:SetFakeCenter(1850, CY)
    p.frame:GetScript("OnUpdate")(p.frame)
    check(docks > 0, "follow: a moved source re-docks")
    eq(p.side, "left", "follow: the side is re-picked for the new position")
    eq(p.frame._points[1][1], "TOPRIGHT", "follow: left-docked hangs from the source's top-left")

    p.frame.SetPoint = realSetPoint
    p:Close()
end

-- The pure side-picker, head-on. Priority order is right > left > below >
-- above, and the first candidate that fits FULLY on screen wins.
do
    local centre = { x = 0, y = 0, w = 80, h = 40 }
    eq(UI.PopoutPickSide(centre, FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080), "right",
        "pick: open screen goes right")
    local rightEdge = { x = 890, y = 0, w = 80, h = 40 }
    eq(UI.PopoutPickSide(rightEdge, FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080), "left",
        "pick: no room on the right flips left")
    -- A source wider than the screen leaves no side that fits at all.
    local huge = { x = 0, y = 0, w = 3000, h = 3000 }
    eq(UI.PopoutPickSide(huge, FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080), nil,
        "pick: nothing fits -> nil, and the caller flips on the screen edge")
end

-- ============================================================
-- 8. THE TETHER BEAM
-- Hidden while the popout is still beside its source; drawn once it has been
-- pinned AND moved away. Endpoints are the nearest edge midpoints, so the line
-- leaves the faces that are looking at each other.
-- ============================================================

-- The predicate first, on plain rects.
do
    local a = { x = 0, y = 0, w = 100, h = 50 }
    check(UI.PopoutIsAdjacent(a, { x = 62, y = 0, w = 20, h = 50 }, 16),
        "adjacent: a 2px gap counts as beside")
    check(UI.PopoutIsAdjacent(a, { x = 0, y = 0, w = 20, h = 20 }, 16),
        "adjacent: overlapping counts as beside")
    check(not UI.PopoutIsAdjacent(a, { x = 200, y = 0, w = 20, h = 50 }, 16),
        "adjacent: a long way off is not beside")
    check(not UI.PopoutIsAdjacent(a, { x = 0, y = 200, w = 20, h = 20 }, 16),
        "adjacent: away on the OTHER axis is not beside either")
    check(not UI.PopoutIsAdjacent(a, nil, 16), "adjacent: a missing rect is not beside anything")
end

do
    local src = source(80, 40, CX, CY)
    local p = popout({ key = "beam" })
    p:Follow(src)
    -- The stub resolves no anchors, so where the dock PUT the frame is stated
    -- rather than measured: right of the source, DOCK_GAP away.
    local dockedX = CX + 40 + DOCK_GAP + FRAME_W / 2
    p.frame:SetFakeCenter(dockedX, CY)
    p:Pin()
    check(p.beam == nil or not p.beam:IsShown(), "beam: a popout still beside its source draws none")

    -- Drag it away: the beam appears, with both layers coloured from the host
    -- accent and the core the thinner, brighter of the two.
    p.titleBar:GetScript("OnDragStart")()
    check(p.frame._flags.moving, "beam: the drag actually moved the frame")
    p.frame:SetFakeCenter(400, 200)
    p.frame:GetScript("OnUpdate")(p.frame)
    check(p.beam:IsShown(), "beam: pinned and away from the source, the beam shows")
    local glow, core = p.beam.glow, p.beam.core
    check(glow:IsShown() and core:IsShown(), "beam: both layers are up")
    eq(core._thickness, 3, "beam: the core is the thin bright line")
    eq(glow._thickness, 5, "beam: the glow is the wide soft one")
    eq(core._color.r, ACCENT.r, "beam: the core takes the host accent")
    eq(core._color.a, 0.55, "beam: ...at the core alpha")
    eq(glow._color.a, 0.15, "beam: ...and the glow at the under-glow alpha")
    check(core._start ~= nil and core._end ~= nil, "beam: the core has both endpoints")
    eq(core._start.rel, UIParent, "beam: endpoints are stated in UIParent-centre units")
    -- Popout centre (400,200) is left of and below the source (960,540): the
    -- nearest faces are the popout's RIGHT edge and the source's LEFT edge.
    eq(core._start.x, 400 - CX + FRAME_W / 2, "beam: it leaves the popout's near edge midpoint")
    eq(core._end.x, -40, "beam: ...and lands on the source's near edge midpoint")

    -- The reveal waited out the entrance rather than racing it.
    local waited = false
    for _, d in ipairs(delays) do if d == 0.22 then waited = true end end
    check(waited, "beam: the reveal was deferred by the pop-in duration")

    -- Back beside it and the beam has nothing left to say.
    p.frame:SetFakeCenter(dockedX, CY)
    p.frame:GetScript("OnUpdate")(p.frame)
    check(not p.beam:IsShown(), "beam: moved back beside the source, the beam goes away")
    p.titleBar:GetScript("OnDragStop")()
    check(not p.frame._flags.moving, "beam: the drag released the frame")
    p:Close()
end

-- ============================================================
-- 9. RESERVED OPTS
-- `actions` and `badge` are accepted so the call sites that will want them can
-- be written now; the shell draws neither.
-- ============================================================
do
    local p = popout({ key = "reserved", actions = { "one", "two" }, badge = 3 })
    eq(p.badge, 3, "reserved: badge is kept")
    eq(#p.actions, 2, "reserved: actions is kept")
    check(not p.frame:IsShown(), "reserved: a built popout stays hidden until it is placed")
    p:Follow(source(80, 40))
    check(p.frame:IsShown(), "reserved: placing it presents it")
    p:Close()
end

-- ============================================================
-- 10. SetHeader
-- ============================================================
do
    local p = popout({ key = "header", title = "Before", icon = "Interface\\Icons\\a" })
    eq(p.titleFS:GetText(), "Before", "header: the build-time title landed")
    check(p.iconTex:IsShown(), "header: a build-time icon shows")
    p:SetHeader("After", "Interface\\Icons\\b")
    eq(p.titleFS:GetText(), "After", "header: SetHeader updates the title")
    eq(p.iconTex:GetTexture(), "Interface\\Icons\\b", "header: SetHeader updates the icon")
    p:SetHeader("Bare")
    check(not p.iconTex:IsShown(), "header: dropping the icon hides it")
    eq(p:GetTitle(), "Bare", "header: the title reads back")
    p:Close()
end

-- ---- PlaceFree: absolute placement, nothing to follow or tether to ----
do
    local p = popout({ key = "freeplace" })
    p:PlaceFree(120, -80)
    check(p.frame:IsShown(), "free: PlaceFree presents the popout")
    eq(p.frame._points[1][4], 120, "free: it took the x it was given")
    eq(p.frame._points[1][5], -80, "free: ...and the y")
    p:Pin()
    p.frame:GetScript("OnUpdate")(p.frame)
    check(p.beam == nil or not p.beam:IsShown(), "free: with no source there is no beam")
    p:Close()
end

CreateFrame, C_Timer = prevCreateFrame, prevTimer
