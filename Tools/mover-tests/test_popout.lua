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
-- panel/border are the title strip's two tokens: the raised fill over the body
-- and the hairline under the bar.
UI.Colors = { text = { r = 0.9, g = 0.9, b = 0.9 }, textDim = { r = 0.5, g = 0.5, b = 0.5 },
              panel = { r = 0.12, g = 0.12, b = 0.12 }, border = { r = 0.25, g = 0.25, b = 0.25 } }

-- ---- Theme.lua metrics --------------------------------------------
-- Mirrors of the real values, for the reason test_popout_row.lua spells out at
-- its own copy: Theme.lua is not loadable headless (it wants GetPhysicalScreenSize,
-- Mixin and BackdropTemplateMixin), and Popout.lua reads both of these at FILE
-- SCOPE -- so they have to be here before the load at the foot of this block.
-- Mirrored whole, and PopoutTitleHeight DERIVED from it exactly as Theme.lua
-- derives it, so a retune of the strip cannot leave the two disagreeing here.
UI.PopoutTitle = UI.PopoutTitle or { topPad = 6, row = 28, fill = 0.9, sepAlpha = 0.8 }
UI.PopoutTitleHeight = UI.PopoutTitleHeight or (UI.PopoutTitle.topPad + UI.PopoutTitle.row)
UI.PopoutPad = UI.PopoutPad or 10

local ACCENT = { r = 0.45, g = 0.45, b = 0.95, a = 1 }
function UI:GetAccent() return ACCENT end
-- Both backdrop factories RECORD what they were asked to paint: the accent
-- chrome is only observable as the colour these were handed.
function UI:CreatePanelBackdrop(frame, opts)
    frame._panelOpts = opts
    return frame
end
function UI:ApplyPixelBorder(frame, color, weight)
    frame._pxColor, frame._pxWeight = color, weight
    return frame
end
function UI:CreateLabel(parent, opts)
    local fs = FakeUIFrame()
    if opts and opts.text then fs:SetText(opts.text) end
    return fs
end
UI.CreateLabelNative = UI.CreateLabel   -- lib files call the shim-proof alias
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
-- ☠ THIS is the stub every popout frame in BOTH popout suites is built from.
-- Popout.lua captures CreateFrame as a file-scope local when it LOADS, and in a
-- full run it loads here -- so a capability the shell needs has to be in THIS
-- stub, not only in test_popout_row's richer one, or it works when that file is
-- run alone and silently does nothing in the full suite.
--
-- The frame TREE is such a capability: the accent cascade walks down from the
-- popout's frame looking for ThemeListeners lists, and a stub whose frames have
-- no children gives it nothing to find.
CreateFrame = function(_, _, parent)
    local f = FakeUIFrame()
    f._children = {}
    f.GetChildren = function(self) return unpack(self._children) end
    -- rawget: FakeUIFrame answers every unknown key with a no-op FUNCTION, so a
    -- plain read would hand back that function and #kids would blow up on it.
    if type(parent) == "table" then
        local kids = rawget(parent, "_children")
        if not kids then kids = {}; parent._children = kids end
        kids[#kids + 1] = f
    end
    return f
end
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
-- is (100 + 2 x PAD) x (TITLE_H + PAD + 50 + PAD) = 120 x 98. Stated as the
-- arithmetic rather than as two literals: the title bar's height is a THEME
-- number now, and a test that hard-codes what it happens to be today reports a
-- deliberate change to it as a dock-geometry failure.
local W = 100
local FRAME_W = W + UI.PopoutPad * 2
local FRAME_H = UI.PopoutTitleHeight + UI.PopoutPad + 50 + UI.PopoutPad
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
-- Up for the whole time the popout FOLLOWS, and only then: a short line from
-- the connection point's tip across the dock gap to the nearest point on the
-- source's outline. Pinning takes it away -- pinned is visually detached.
-- ============================================================

-- The adjacency predicate is published geometry the shell no longer consults;
-- it is still exercised here because consumers can call it.
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

-- Where the dock PUTS the frame, stated rather than measured: the stub resolves
-- no anchors, so a test that wants the beam's real endpoints has to say where
-- the popout ended up. Right of the source, DOCK_GAP away, hanging from the
-- source's TOP edge.
local function dockedRightOfCentre()
    return CX + 40 + DOCK_GAP + FRAME_W / 2, CY + 20 - FRAME_H / 2
end

do
    local src = source(80, 40, CX, CY)
    local p = popout({ key = "beam" })
    p.frame:SetFakeCenter(dockedRightOfCentre())
    local before = #delays
    p:Follow(src)
    check(p.beam:IsShown(), "beam: FOLLOWING, the beam is up -- docked is exactly when it means something")
    local glow, core = p.beam.glow, p.beam.core
    check(glow:IsShown() and core:IsShown(), "beam: both layers are up")
    eq(core._thickness, 3, "beam: the core is the thin bright line")
    eq(glow._thickness, 5, "beam: the glow is the wide soft one")
    eq(core._color.r, ACCENT.r, "beam: the core takes the host accent")
    eq(core._color.a, 0.55, "beam: ...at the core alpha")
    eq(glow._color.a, 0.15, "beam: ...and the glow at the under-glow alpha")
    eq(core._start.rel, UIParent, "beam: endpoints are stated in UIParent-centre units")
    -- The popout's rect is { x = 112, y = 20 - FRAME_H/2, FRAME_W x FRAME_H };
    -- right-docked, the connection point's tip is half a notch left of its left edge.
    eq(core._start.x, 112 - FRAME_W / 2, "beam: it starts under the connection point, on the frame edge")
    -- The tip SLIDES along the edge to meet the source: the source's centre
    -- (y = 0) is inside the edge's clamp range, so the tip sits level with it
    -- rather than at the edge's midpoint (-26).
    eq(core._start.y, 0, "beam: slid level with the source's centre")
    -- ...and lands on the nearest point of the source's outline: its right face
    -- (x = 40), dead level, so the beam crosses the dock gap horizontally.
    eq(core._end.x, 40, "beam: and lands on the source outline's near face")
    eq(core._end.y, 0, "beam: level -- straight across the dock gap")

    -- The reveal waited out the entrance rather than racing it.
    local waited = false
    for i = before + 1, #delays do if delays[i] == 0.22 then waited = true end end
    check(waited, "beam: the reveal was deferred by the pop-in duration")

    -- PINNED is detached: the beam goes, and dragging the popout miles away does
    -- not bring it back.
    p:Pin()
    check(not p.beam:IsShown(), "beam: pinning takes the beam away")
    p.titleBar:GetScript("OnDragStart")()
    check(p.frame._flags.moving, "beam: the drag actually moved the frame")
    p.frame:SetFakeCenter(400, 200)
    p.frame:GetScript("OnUpdate")(p.frame)
    check(not p.beam:IsShown(), "beam: a pinned popout stays beamless however far it is dragged")
    p.titleBar:GetScript("OnDragStop")()
    check(not p.frame._flags.moving, "beam: the drag released the frame")
    check(not p.beam:IsShown(), "beam: ...and letting go does not bring it back either")
    p:Close()
end

-- The beam re-sides with the dock: flipped left, it leaves the popout's RIGHT
-- face and lands on the source's left one.
do
    local src = source(80, 40, CX, CY)
    local p = popout({ key = "beamflip" })
    -- Left-docked at the same offsets, mirrored.
    p.frame:SetFakeCenter(CX - 40 - DOCK_GAP - FRAME_W / 2, CY + 20 - FRAME_H / 2)
    p:Follow(src, { side = "left" })
    eq(p.beam.core._start.x, -112 + FRAME_W / 2, "beam: left-docked, it starts under the point on the RIGHT face")
    eq(p.beam.core._end.x, -40, "beam: and lands on the source's left face")
    p:Close()
end

-- ============================================================
-- 8a. THE RETARGET GLIDE
-- Pointing an OPEN following popout at a different thing slides it across
-- instead of teleporting. The re-dock is suspended for the duration -- a
-- following popout is anchored to its source and cannot be driven while that
-- anchor holds -- and the landing is exact.
-- ============================================================
do
    local a = source(80, 40, CX, CY)
    local b = source(80, 40, CX - 500, CY)
    local p = popout({ key = "glide" })
    p.frame:SetFakeCenter(dockedRightOfCentre())
    p:Follow(a)
    check(not p.gliding, "glide: the first placement is not a glide -- there is nowhere to come from")
    eq(p.frame._points[1][2], a, "glide: ...it is anchored straight to its source")

    -- Record every re-anchor, so "it took an explicit screen anchor while
    -- gliding and a source anchor when it landed" is observable rather than
    -- inferred from a position the stub does not resolve.
    local moves = {}
    local realSetPoint = p.frame.SetPoint
    p.frame.SetPoint = function(s, ...) moves[#moves + 1] = { ... } return realSetPoint(s, ...) end

    p:Follow(b)
    check(p.gliding, "glide: retargeting a shown following popout glides")
    local first = moves[#moves]
    eq(first[1], "CENTER", "glide: it takes an explicit screen anchor for the ride")
    eq(first[2], UIParent, "glide: ...off UIParent, not the source")
    eq(first[4], 112, "glide: starting exactly where it already was")
    eq(first[5], 20 - FRAME_H / 2, "glide: ...on both axes")
    -- The connected chrome commits to the NEW source at once.
    eq(p.srcOutline._points[1][2], b, "glide: the source outline snaps to the new source at once")

    -- Part-way: still gliding, still on its own anchor, and the beam's near end
    -- has travelled with the frame.
    local midStart = p.beam.core._start.x
    p.frame:GetScript("OnUpdate")(p.frame, 0.06)
    check(p.gliding, "glide: part-way through, it is still gliding")
    check(p._gX < 112 and p._gX > -388, "glide: ...and somewhere between the two docks")
    eq(moves[#moves][1], "CENTER", "glide: still driving its own anchor")
    check(p.beam.core._start.x < midStart, "glide: the beam's near end tracks the gliding frame")

    -- ☠ The re-dock is SUSPENDED. A source move mid-glide must not yank the
    -- frame onto the destination on the very next frame.
    b:SetFakeCenter(CX - 500, CY + 100)
    p.frame:GetScript("OnUpdate")(p.frame, 0.02)
    check(p.gliding, "glide: a source move mid-glide does not end the glide")
    eq(moves[#moves][1], "CENTER", "glide: ...and does not re-dock underneath it")
    b:SetFakeCenter(CX - 500, CY)

    -- Run it out. It lands on the computed dock point and hands the anchor back
    -- to the source, so the ordinary follow works again from there.
    p.frame:GetScript("OnUpdate")(p.frame, 1)
    check(not p.gliding, "glide: it finishes")
    local landed, docked
    for i = #moves, 1, -1 do
        if not docked then docked = moves[i] end
        if moves[i][1] == "CENTER" and moves[i][2] == UIParent then landed = moves[i] break end
    end
    local tx, ty = UI.PopoutDockPos({ x = -500, y = 0, w = 80, h = 40 },
                                    "right", FRAME_W, FRAME_H, DOCK_GAP)
    eq(landed[4], tx, "glide: the last driven position IS the dock point")
    eq(landed[5], ty, "glide: ...on both axes")
    eq(docked[1], "TOPLEFT", "glide: and it ends re-anchored to the source")
    eq(docked[2], b, "glide: ...to the NEW source")
    p.frame.SetPoint = realSetPoint
    p:Close()
end

-- The dock position as a pure function -- the same point the SetPoint in _Dock
-- resolves to, which is what makes the glide's landing exact.
do
    local src = { x = 0, y = 0, w = 80, h = 40 }
    local x, y = UI.PopoutDockPos(src, "right", 120, 92, 12)
    eq(x, 112, "dockpos: right of the source, a gap away")
    eq(y, -26, "dockpos: hanging from the source's top edge")
    x, y = UI.PopoutDockPos(src, "left", 120, 92, 12)
    eq(x, -112, "dockpos: mirrored on the left")
    x, y = UI.PopoutDockPos(src, "above", 120, 92, 12)
    eq(x, 0, "dockpos: above centres on the source")
    eq(y, 20 + 12 + 46, "dockpos: ...clear of its top edge")
    x, y = UI.PopoutDockPos(src, "below", 120, 92, 12)
    eq(y, -20 - 12 - 46, "dockpos: and below clears its bottom")
    eq(UI.PopoutDockPos(src, "sideways", 120, 92, 12), nil, "dockpos: an unknown side has no position")
    eq(UI.PopoutDockPos(nil, "right", 120, 92, 12), nil, "dockpos: no source, no position")
end

-- What does NOT glide.
do
    local a = source(80, 40, CX, CY)
    local p = popout({ key = "noglide" })
    p.frame:SetFakeCenter(dockedRightOfCentre())
    p:Follow(a)
    p:Follow(a)
    check(not p.gliding, "glide: re-Following the SAME source re-docks, it does not glide")
    p:Follow(a, { side = "below" })
    check(not p.gliding, "glide: nor does changing the forced side on one source")
    eq(p.side, "below", "glide: ...which still re-docks")
    p:Close()

    -- A pinned popout is off its leash; Follow only re-points its beam.
    local q = popout({ key = "glidepin" })
    q.frame:SetFakeCenter(dockedRightOfCentre())
    q:Follow(a)
    q:Pin()
    q:Follow(source(80, 40, CX - 500, CY))
    check(not q.gliding, "glide: a pinned popout does not glide anywhere")
    q:Close()

    -- PlaceFree owns its own position, so it cancels a glide outright.
    local r = popout({ key = "glidefree" })
    r.frame:SetFakeCenter(dockedRightOfCentre())
    r:Follow(a)
    r:Follow(source(80, 40, CX - 500, CY))
    check(r.gliding, "glide: gliding going in")
    r:PlaceFree(0, 0)
    check(not r.gliding, "glide: PlaceFree stops it dead")
    eq(r.frame._points[1][4], 0, "glide: ...at the position it was given")
    r:Close()
end

-- ============================================================
-- 8b. ACCENT CHROME
-- The popout, the connection point and the source outline are all drawn in ONE
-- colour, so the two ends read as two halves of one object. The host accent by
-- default; opts.accent overrides it per popout.
-- ============================================================
do
    local p = popout({ key = "accent" })
    local bc = p.frame._panelOpts and p.frame._panelOpts.borderColor
    check(bc ~= nil, "accent: the popout's backdrop was given a border colour")
    eq(bc.r, ACCENT.r, "accent: the border takes the host accent")
    eq(bc.b, ACCENT.b, "accent: ...on every channel")
    p:Close()

    local mine = { 1, 0.5, 0 }
    local q = popout({ key = "accentopt", accent = mine })
    eq(q.frame._panelOpts.borderColor.r, 1, "accent: opts.accent overrides the host")
    eq(q.frame._panelOpts.borderColor.g, 0.5, "accent: ...as an array triple")
    eq(q:GetAccent().b, 0, "accent: GetAccent answers the override")
    q:Close()

    -- The override is per ADOPT, so a pooled popout re-opened without one falls
    -- back to the host again rather than keeping the last consumer's colour.
    local back = popout({ key = "accentopt" })
    check(back == q, "accent: the pooled instance came back")
    eq(back:GetAccent().r, ACCENT.r, "accent: ...and dropped the override with the opts")
    back:Close()
end

-- ============================================================
-- 8c. THE CONNECTION POINT
-- A small accent diamond centred on the edge the popout docked against. It
-- re-sides with the dock and it is gone the moment the popout is pinned, which
-- is when the relationship it describes stops holding.
-- ============================================================
do
    local src = source(80, 40, CX, CY)
    local p = popout({ key = "notch" })
    check(not p.notch:IsShown(), "notch: a built popout has no connection point yet")
    p:Follow(src)
    check(p.notch:IsShown(), "notch: following, the point is up")
    eq(p.notch:GetTexture(), "Icons\\notch", "notch: it wears the diamond")
    eq(p.notch._vertex.r, ACCENT.r, "notch: tinted with the accent")
    eq(p.notch:GetWidth(), 10, "notch: ~10px")
    local pt = p.notch._points[#p.notch._points]
    eq(pt[1], "CENTER", "notch: its CENTRE sits on the edge")
    eq(pt[3], "LEFT", "notch: right-docked, that is the popout's LEFT edge")

    -- Flip the dock and the point crosses with it.
    src:SetFakeCenter(1850, CY)
    p.frame:GetScript("OnUpdate")(p.frame)
    eq(p.side, "left", "notch: the dock flipped")
    eq(p.notch._points[#p.notch._points][3], "RIGHT",
        "notch: left-docked, the point moves to the popout's RIGHT edge")

    p:Follow(src, { side = "above" })
    eq(p.notch._points[#p.notch._points][3], "BOTTOM", "notch: above-docked points DOWN")
    p:Follow(src, { side = "below" })
    eq(p.notch._points[#p.notch._points][3], "TOP", "notch: below-docked points UP")

    p:Pin()
    check(not p.notch:IsShown(), "notch: pinning takes the connection point away")
    p:Close()

    -- PlaceFree has no dock side, so there is nothing to point at.
    local free = popout({ key = "notchfree" })
    free:PlaceFree(0, 0)
    check(not free.notch:IsShown(), "notch: a free-placed popout draws none")
    free:Close()
end

-- The tip geometry, head-on: the outer vertex of a diamond straddling the
-- source-facing edge, half its size proud of it.
do
    local pr = { x = 100, y = 20, w = 120, h = 92 }
    local x, y = UI.PopoutNotchTip(pr, "right", 10)
    eq(x, 100 - 60 - 5, "tip: right-docked, the tip is left of the popout's left edge")
    eq(y, 20, "tip: on that edge's midpoint")
    x, y = UI.PopoutNotchTip(pr, "left", 10)
    eq(x, 100 + 60 + 5, "tip: left-docked, the tip is right of the right edge")
    x, y = UI.PopoutNotchTip(pr, "above", 10)
    eq(y, 20 - 46 - 5, "tip: above-docked, the tip is below the bottom edge")
    x, y = UI.PopoutNotchTip(pr, "below", 10)
    eq(y, 20 + 46 + 5, "tip: below-docked, the tip is above the top edge")
    eq(UI.PopoutNotchTip(pr, nil, 10), nil, "tip: no dock side, no tip")
    eq(UI.PopoutNotchTip(nil, "right", 10), nil, "tip: no rect, no tip")
end

-- With a source rect the tip SLIDES along the edge to meet it, clamped 14
-- (NOTCH_EDGE_INSET) clear of the corners.
do
    local pr = { x = 100, y = 20, w = 120, h = 92 }   -- edge spans y 20 ± 32 after inset
    local src = function(sx, sy) return { x = sx, y = sy, w = 40, h = 20 } end
    local _, y = UI.PopoutNotchTip(pr, "right", 10, src(0, 30))
    eq(y, 30, "slide: level with a source inside the range")
    _, y = UI.PopoutNotchTip(pr, "right", 10, src(0, 200))
    eq(y, 52, "slide: clamped at the top inset for a source far above")
    _, y = UI.PopoutNotchTip(pr, "right", 10, src(0, -200))
    eq(y, -12, "slide: clamped at the bottom inset for a source far below")
    local x = UI.PopoutNotchTip(pr, "above", 10, src(-500, 0))
    eq(x, 100 - 60 + 14, "slide: above/below docks slide horizontally, same clamp")
end

-- Nearest point on a rect's outline. The tip is always OUTSIDE the source, so
-- clamping onto the rect lands on its perimeter.
do
    local r = { x = 0, y = 0, w = 100, h = 50 }
    local x, y = UI.PopoutNearestOnRect(r, 200, 0)
    eq(x, 50, "nearest: clamped onto the right face")
    eq(y, 0, "nearest: ...at the height it came from")
    x, y = UI.PopoutNearestOnRect(r, -200, 100)
    eq(x, -50, "nearest: the left face")
    eq(y, 25, "nearest: ...and the top, for a point off the corner")
    eq(UI.PopoutNearestOnRect(nil, 0, 0), nil, "nearest: no rect, no point")
end

-- ============================================================
-- 8d. THE SOURCE OUTLINE
-- While following, the shell draws the SAME 1px accent border over the tether
-- source that the popout wears, so the two visibly share an edge.
-- ============================================================
do
    local src = source(80, 40, CX, CY)
    local p = popout({ key = "outline" })
    check(p.srcOutline == nil, "outline: nothing is built until the popout is placed")
    p:Follow(src)
    check(p.srcOutline ~= nil and p.srcOutline:IsShown(), "outline: following, it is up")
    eq(p.srcOutline._pxColor[1], ACCENT.r, "outline: the same accent as the popout's border")
    eq(p.srcOutline._points[1][1], "TOPLEFT", "outline: it covers the source rect")
    eq(p.srcOutline._points[1][2], src, "outline: ...anchored to the source itself")
    eq(p.srcOutline._points[2][1], "BOTTOMRIGHT", "outline: on both corners")

    -- Anchored to the region, so it tracks a moving source for free -- and must
    -- not pay for a re-anchor and a border relayout on every re-dock.
    local repaints = 0
    local realApply = UI.ApplyPixelBorder
    UI.ApplyPixelBorder = function(s, frame, ...) repaints = repaints + 1 return realApply(s, frame, ...) end
    src:SetFakeCenter(CX + 30, CY)
    p.frame:GetScript("OnUpdate")(p.frame)
    src:SetFakeCenter(CX + 60, CY)
    p.frame:GetScript("OnUpdate")(p.frame)
    eq(repaints, 0, "outline: a source move re-docks without touching the outline")
    UI.ApplyPixelBorder = realApply

    p:Pin()
    check(not p.srcOutline:IsShown(), "outline: pinning is visually detached, so it goes")
    p:Close()
end

-- It follows the TETHER source, not the dock source, and it leaves on close.
do
    local src = source(80, 40, CX, CY)
    local far = source(60, 40, CX - 400, CY)
    local p = popout({ key = "outlinetether", tetherSource = far })
    p:Follow(src)
    eq(p.srcOutline._points[1][2], far, "outline: it outlines the TETHER target")
    p:Close()
    check(not p.srcOutline:IsShown(), "outline: closing takes it down")
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

-- ---- the title bar has room to breathe ----------------------------
-- The bar used to be 22 tall around an 18px close button, and every gap in it was
-- 2 or 4 -- so title, badge, pin and cross were packed against each other and the
-- caption sat all but on the panel's own accent border. The claims here are the
-- ones that stop that coming back: the bar is a THEME number (so a change to it
-- is a deliberate one, made in one place), the tallest control in it clears both
-- edges, and the content below is inset by the same PAD on both sides of the
-- panel rather than hugging the bar with double the slack underneath.
--
-- ...and the second half of the same complaint, which the height alone did not
-- answer: the row was centred in the WHOLE strip, so the caption was as close to
-- the panel's accent border as it was to the content, and nothing but the
-- spacing said where the chrome stopped. Now the strip carries a top MARGIN, a
-- raised fill and a hairline under it -- so the claims below are also that the
-- row hangs under that margin rather than being centred through it, and that the
-- separator exists and is drawn in the border tone.
do
    local p = popout({ key = "titlebar" })
    eq(p.titleBar:GetHeight(), UI.PopoutTitleHeight, "titlebar: its height is the theme's, not a literal")
    eq(UI.PopoutTitleHeight, UI.PopoutTitle.topPad + UI.PopoutTitle.row,
        "titlebar: the published height is the top pad plus the row, not a second literal")
    check(UI.PopoutTitle.topPad > 0, "titlebar: the strip has real air above its row")

    -- The clearance the row actually gets, measured in the region UNDER the top
    -- margin -- not across the whole strip, which would count the margin twice
    -- and pass however badly the row was centred.
    local clearance = (UI.PopoutTitle.row - p.closeBtn:GetHeight()) / 2
    check(clearance >= 4, "titlebar: the tallest control in it clears both edges of the row")

    -- Both offsets of an anchor against a given relative frame. Read off the
    -- recorded anchors, because the stub resolves none of them.
    local function offsetOf(region, rel)
        for _, pt in ipairs(region._points) do
            if pt[2] == rel then return pt[4], pt[5] end
        end
    end

    -- The row hangs half a top-pad below the bar's own centre, which is what
    -- centres it in that region rather than in the strip.
    eq(select(2, offsetOf(p.closeBtn, p.titleBar)), -UI.PopoutTitle.topPad / 2,
        "titlebar: the cross sits centred under the top margin, not through it")
    eq(select(2, offsetOf(p.iconTex, p.titleBar)), -UI.PopoutTitle.topPad / 2,
        "titlebar: ...and so does the icon the caption chains off")

    -- THE SEPARATION, said in ink rather than in spacing. Both pieces are on the
    -- FRAME, not on the bar: a texture on the bar (a child) would draw over the
    -- popout's own accent border along the top and the upper corners.
    check(p.titleSep ~= nil, "titlebar: there is a separator under the bar")
    eq(p.titleSep:GetHeight(), 1, "titlebar: ...drawn as a hairline")
    eq(p.titleSep._color.r, UI.Colors.border.r, "titlebar: ...in the border tone")
    eq(p.titleSep._color.a, UI.PopoutTitle.sepAlpha, "titlebar: ...at the theme's separator weight")
    local sepPts = p.titleSep._points
    eq(sepPts[1][1], "BOTTOMLEFT", "titlebar: the separator starts at the bar's bottom-left")
    eq(sepPts[2][1], "BOTTOMRIGHT", "titlebar: ...and runs the full width to its bottom-right")
    check(p.titleFill ~= nil, "titlebar: the strip carries its own raised fill")
    eq(p.titleFill._color.r, UI.Colors.panel.r, "titlebar: ...in the kit's panel tone over the body")
    eq(p.titleFill._color.a, UI.PopoutTitle.fill, "titlebar: ...at the theme's strip alpha")

    -- The frame's box model, stated as the arithmetic the consumer is promised.
    eq(p.frame:GetHeight(), UI.PopoutTitleHeight + UI.PopoutPad + 50 + UI.PopoutPad,
        "titlebar: height is title + pad + content + pad")
    local cpt = p.content._points[1]
    eq(cpt[2], UI.PopoutPad, "titlebar: the content is inset by PAD on the left")
    eq(cpt[3], -(UI.PopoutTitleHeight + UI.PopoutPad),
        "titlebar: ...and hangs a PAD BELOW the bar rather than flush against it")

    -- The gaps across the button cluster -- what is being asserted is that no gap
    -- in the row is one of the old 2/4px ones.
    check(-offsetOf(p.closeBtn, p.titleBar) >= 6, "titlebar: the cross stands off the bar's right edge")
    check(-offsetOf(p.pinBtn, p.closeBtn) >= 6, "titlebar: the pin is not jammed against the cross")
    check(-offsetOf(p.titleFS, p.pinBtn) >= 8, "titlebar: and the caption stops clear of the pin")
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

-- ============================================================
-- 11. THE REST OF THE CONTRACT
-- The claims the sections above imply but do not actually exercise: that the
-- pool survives a close and does NOT cross hosts, that a forced side beats the
-- auto pick, that tetherSource re-points the beam, that the exit is ordered,
-- and that a popout without a key is refused.
-- ============================================================

-- The pool outlives a CLOSE. That is what makes it a pool rather than a cache
-- of things currently on screen: a popout that opens on every selection must
-- cost one build, not one per selection.
do
    builds = 0
    local p = popout({ key = "revive" })
    p:Follow(source(80, 40))
    p:Close()
    check(p.closed, "revive: the popout closed")
    local again = popout({ key = "revive" })
    check(again == p, "revive: a closed unpinned popout is revived, not rebuilt")
    eq(builds, 1, "revive: build did not run a second time")
    eq(again.content._built, 1, "revive: it still has the content it built")
    check(not again.closed, "revive: reviving clears the closed flag")
    again:Follow(source(80, 40))
    check(again:IsShown(), "revive: and it presents again")
    eq(again.frame:GetWidth(), FRAME_W, "revive: the frame is the content width plus the padding")
    again:Close()
end

-- The pool is per HOST, not global. Two consumers may both call a popout
-- "detail" and must not be handed each other's frame -- which is the whole
-- reason the store is rawset onto the host rather than kept on the library.
do
    builds = 0
    local mine = popout({ key = "shared-key" })
    local theirs = setmetatable({ hooks = { L = L } }, { __index = UI })
    local other = theirs:CreatePopout({ key = "shared-key", width = W, build = buildContent })
    check(other ~= mine, "hosts: the same key on another host is another popout")
    eq(builds, 2, "hosts: and it built its own content")
    check(rawget(theirs, "_popouts") ~= rawget(host, "_popouts"), "hosts: each host has its own store")
    mine:Close(); other:Close()
end

-- A key is the pool's identity, so there is no sensible popout without one.
do
    check(not pcall(function() return host:CreatePopout({}) end), "factory: a missing key is refused")
    check(not pcall(function() return host:CreatePopout({ key = "" }) end), "factory: an empty key is refused")
    check(not pcall(function() return host:CreatePopout() end), "factory: no opts at all is refused")
end

-- Pinning re-anchors to the SCREEN. Left hanging off the source, a pinned
-- popout would still be towed around by it, which is the one thing pinning is
-- supposed to stop -- and the beam would then never have anything to say.
do
    local src = source(80, 40, CX, CY)
    local p = popout({ key = "reanchor" })
    p:Follow(src)
    eq(p.frame._points[1][2], src, "reanchor: a following popout is anchored to its source")
    p:Pin()
    eq(p.frame._points[1][1], "CENTER", "reanchor: pinning re-anchors by the centre")
    eq(p.frame._points[1][2], UIParent, "reanchor: ...to the screen, not to the source")
    check(not p.following, "reanchor: and it stops following")
    p:Close()
end

-- opts.side beats the auto pick: a consumer that knows what else is on screen
-- can say where the popout goes, which is the shell's answer to not modelling
-- obstacles itself.
do
    local src = source(80, 40, CX, CY)
    local p = popout({ key = "forced" })
    p:Follow(src, { side = "below" })
    eq(p.side, "below", "forced: opts.side wins over the auto pick")
    eq(p.frame._points[1][1], "TOP", "forced: below-docked hangs its top")
    eq(p.frame._points[1][3], "BOTTOM", "forced: ...off the source's bottom")
    p:Follow(src, { side = "above" })
    eq(p.side, "above", "forced: and it can be changed")
    eq(p.frame._points[1][1], "BOTTOM", "forced: above-docked hangs its bottom")
    eq(p.frame._points[1][3], "TOP", "forced: ...off the source's top")
    -- Dropping the force hands the side back to the picker.
    p:Follow(src)
    eq(p.side, "right", "forced: without a forced side the picker decides again")
    p:Close()
end

-- The gate is asked ONCE PER CALL and is handed the popout, so a consumer can
-- answer differently for two popouts sharing one gate function.
do
    local asked, got = 0, nil
    local p = popout({ key = "gatecount", canAutoPin = function(po) asked = asked + 1; got = po; return false end })
    p:Follow(source(80, 40))
    p:AutoPin()
    eq(asked, 1, "gate: asked once")
    p:AutoPin()
    eq(asked, 2, "gate: asked again on the next call")
    eq(got, p, "gate: the popout is handed to the gate")
    p:Close()

    -- No gate at all is not a closed gate.
    local free = popout({ key = "nogate" })
    free:Follow(source(80, 40))
    free:AutoPin()
    check(free:IsPinned(), "gate: no canAutoPin means AutoPin just pins")
    free:Close()
end

-- A family claim keeps holding: the THIRD member evicts the second exactly as
-- the second evicted the first.
do
    local reasons = {}
    local function member(key)
        local p = popout({ key = key, family = "stack", onClose = function(_, r) reasons[key] = r end })
        p:Follow(source(80, 40))
        return p
    end
    local first = member("stack1")
    local second = member("stack2")
    eq(reasons.stack1, "family", "stack: the second member evicted the first")
    local third = member("stack3")
    eq(reasons.stack2, "family", "stack: and the third evicted the second")
    check(not third.closed, "stack: only the newcomer is left")
    eq(third.family, "stack", "stack: the family is carried on the instance")
    third:Close()
end

-- tetherSource: the beam's far end is not always the thing the popout DOCKED
-- to -- a popout about a row inside a list may dock to the list.
do
    local src = source(80, 40, CX, CY)
    -- Well away to the left of the dock target, so "which of the two did the
    -- beam actually land on" is unambiguous.
    local far = source(60, 40, CX - 400, CY)
    local p = popout({ key = "tether", tetherSource = far })
    p.frame:SetFakeCenter(dockedRightOfCentre())
    p:Follow(src)
    check(p.beam:IsShown(), "tether: following, the beam shows")
    eq(p.beam.core._start.x, 112 - FRAME_W / 2, "tether: it starts under the connection point, on the frame edge")
    eq(p.beam.core._end.x, -370, "tether: and lands on the TETHER target's near face")
    eq(p.beam.core._end.y, 0, "tether: level with the tether target, not the dock target")
    -- The outline follows the same target, so both ends of the "connected" look
    -- agree about what the popout is about.
    eq(p.srcOutline._points[1][2], far, "tether: the source outline is on the tether target too")
    p:Close()

    -- The function form is resolved when the beam is drawn, so the target can
    -- change between two opens of the same popout.
    local calls = 0
    local q = popout({ key = "tetherfn", tetherSource = function() calls = calls + 1; return far end })
    q.frame:SetFakeCenter(dockedRightOfCentre())
    q:Follow(source(80, 40, CX, CY))
    check(calls > 0, "tether: a function tetherSource is called")
    eq(q.beam.core._end.x, -370, "tether: and the region it returns is used")
    q:Close()
end

-- The exit is ORDERED: the beam fades first and the popout's own pop-out waits
-- that fade out, so the two read as one gesture instead of two events.
do
    local p = popout({ key = "closeorder" })
    p.frame:SetFakeCenter(dockedRightOfCentre())
    p:Follow(source(80, 40, CX, CY))
    check(p.beam:IsShown(), "exit: the beam is up going in")
    local before = #delays
    p:Close()
    local waited = false
    for i = before + 1, #delays do if delays[i] == 0.15 then waited = true end end
    check(waited, "exit: the popout's exit waits out the beam's fade")
    check(not p.beam:IsShown(), "exit: the beam went first")
    check(not p:IsShown(), "exit: and the popout followed")
end

-- The pin button wears the kit glyph and a tooltip out of the HOST's locale --
-- the shell adds no locale file of its own.
do
    local p = popout({ key = "pinglyph" })
    eq(p.pinBtn._opts.texture, "Icons\\pin", "glyph: the pin button uses the pin art")
    eq(p.pinBtn._opts.tooltip.title, "Pin", "glyph: with a tooltip read from the host locale")
    p:Close()
end

-- The adjacency slack is a boundary, and boundaries are where these go wrong.
do
    local a = { x = 0, y = 0, w = 100, h = 50 }
    check(UI.PopoutIsAdjacent(a, { x = 116, y = 0, w = 100, h = 50 }, 16),
        "adjacent: exactly at the slack still counts as beside")
    check(not UI.PopoutIsAdjacent(a, { x = 117, y = 0, w = 100, h = 50 }, 16),
        "adjacent: one step past it does not")
end

-- ============================================================
-- 12. THE SETTINGS PLACEMENT -- Follow(row, { outsideOf = window })
-- ------------------------------------------------------------
-- A popout about a ROW inside a scrolling WINDOW docks outside the WINDOW's
-- vertical edge at the ROW's height, not beside the row -- beside the row it
-- would sit on top of the list the row was picked from. Two rects decide the
-- position: the window gives x, the row gives y.
--
-- Every rect below is in UIParent-centre units:
--   window { 0, 0, 600 x 400 }    -> edges at x = ±300, y = ±200
--   row    { -100, 50, 200 x 40 } -> its TOP at y = 70
-- ============================================================
local WIN_W, WIN_H = 600, 400
local ROW_W, ROW_H = 200, 40
local WIN = { x = 0, y = 0, w = WIN_W, h = WIN_H }
local ROW = { x = -100, y = 50, w = ROW_W, h = ROW_H }
-- Right-docked: the popout's LEFT edge a gap clear of the window's RIGHT edge,
-- and the row A THIRD down the popout (centre = row - h/6; dead-centre made
-- tall popouts feel like they hung below the row -- Danders 2026-08-26). The
-- window clamp is a no-op here -- a 98-tall popout may stray 151 from the
-- window's middle before an edge of it leaves.
local OUT_X = WIN_W / 2 + DOCK_GAP + FRAME_W / 2            -- 372
local OUT_Y = ROW.y - FRAME_H / 6                            -- 50 - 16.33

-- Build the pair the live tests drive: a window at screen centre and a row
-- inside it, `dy` above/below the window's middle.
local function outsideWindow() return source(WIN_W, WIN_H, CX, CY) end
local function outsideRow(dy, h) return source(ROW_W, h or ROW_H, CX + ROW.x, CY + (dy or ROW.y)) end

-- ---- the pure geometry, head-on ----------------------------------
do
    local side, x, y = UI.PopoutOutsidePos(WIN, ROW, FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080)
    eq(side, "right", "outside: open screen docks outside the window's RIGHT edge")
    eq(x, OUT_X, "outside: its left edge a gap clear of that edge")
    eq(y, OUT_Y, "outside: the row a third down the popout, not window-centred")

    -- The row is what moves the popout vertically -- that is the whole reason
    -- this is not just "dock beside the window".
    local _, _, y2 = UI.PopoutOutsidePos(WIN, { x = -100, y = -50, w = ROW_W, h = ROW_H },
                                         FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080)
    eq(y2, -50 - FRAME_H / 6, "outside: a lower row lowers the popout by the same amount")

    -- ☠ The third rule, not the row's top and not dead-centre. Hung from the
    -- top, a 400-tall popout is 200px of panel below its row; dead-centred it
    -- still read as hanging (in-game feedback). A third down keeps the row at
    -- a reader's natural focus line whatever the height.
    local _, _, tallY = UI.PopoutOutsidePos(WIN, ROW, FRAME_W, 300, DOCK_GAP, 1920, 1080)
    eq(tallY, ROW.y - 300 / 6, "outside: a TALL popout keeps its row a third down, not dropped below")
end

-- No room to the right of the window: the popout crosses to the OTHER side of
-- the window rather than overhanging the screen.
do
    -- Window pushed right until its right edge is at x = 900: 900 + 12 + 120
    -- overruns the 960 half-screen.
    local win = { x = 600, y = 0, w = WIN_W, h = WIN_H }
    local side, x = UI.PopoutOutsidePos(win, ROW, FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080)
    eq(side, "left", "outside: no screen room on the right flips to the window's LEFT edge")
    eq(x, 600 - WIN_W / 2 - DOCK_GAP - FRAME_W / 2, "outside: right edge a gap clear of the window's left")

    -- Exactly at the boundary: the popout's right edge lands ON the screen edge,
    -- which counts as fitting. One pixel further and it does not.
    local fits = { x = 960 - FRAME_W - DOCK_GAP - WIN_W / 2, y = 0, w = WIN_W, h = WIN_H }
    eq(UI.PopoutOutsidePos(fits, ROW, FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080), "right",
        "outside: flush against the screen edge still fits")
    local over = { x = fits.x + 1, y = 0, w = WIN_W, h = WIN_H }
    eq(UI.PopoutOutsidePos(over, ROW, FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080), "left",
        "outside: one step past it does not")
end

-- A forced side beats the fit test, in both directions. Only left/right mean
-- anything out here, so anything else hands the choice back to the fit test.
do
    local side, x = UI.PopoutOutsidePos(WIN, ROW, FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080, "left")
    eq(side, "left", "outside: opts.side forces the left edge even with room on the right")
    eq(x, -OUT_X, "outside: mirrored about the window's centre")
    local cramped = { x = 600, y = 0, w = WIN_W, h = WIN_H }
    side, x = UI.PopoutOutsidePos(cramped, ROW, FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080, "right")
    eq(side, "right", "outside: ...and forcing right keeps it right where it would have flipped")
    eq(x, 600 + WIN_W / 2 + DOCK_GAP + FRAME_W / 2, "outside: overhang and all -- SetClampedToScreen deals with it")
    eq(UI.PopoutOutsidePos(WIN, ROW, FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080, "above"), "right",
        "outside: above/below are meaningless here, so the fit test decides")
end

-- The vertical screen clamp. A tall window can put a row past the top or bottom
-- of the screen; the popout may not go with it.
do
    local tall = { x = 0, y = 0, w = WIN_W, h = 1400 }
    local high = { x = -100, y = 590, w = ROW_W, h = 20 }        -- top at 600
    local _, _, y = UI.PopoutOutsidePos(tall, high, FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080)
    eq(y, 540 - FRAME_H / 2, "outside: clamped to the top of the screen")
    local low = { x = -100, y = -590, w = ROW_W, h = 20 }
    _, _, y = UI.PopoutOutsidePos(tall, low, FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080)
    eq(y, -540 + FRAME_H / 2, "outside: and to the bottom")
end

-- The window clamp: the whole popout is held inside the window's vertical span,
-- so a row scrolled out of the list leaves the panel beside the LIST rather than
-- trailing off after a row nobody can see. `slack` is how far its centre may
-- stray from the window's before an edge of it leaves.
local SLACK = WIN_H / 2 - FRAME_H / 2
do
    local below = { x = -100, y = -400, w = ROW_W, h = ROW_H }   -- scrolled off the bottom
    local _, _, y = UI.PopoutOutsidePos(WIN, below, FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080)
    eq(y, -SLACK, "outside: a row below the window holds the popout inside its bottom edge")
    local above = { x = -100, y = 400, w = ROW_W, h = ROW_H }
    _, _, y = UI.PopoutOutsidePos(WIN, above, FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080)
    eq(y, SLACK, "outside: and a row above it holds the popout inside the top edge")

    -- A popout TALLER than the window has no position that satisfies the clamp:
    -- every one of them leaves the window top and bottom. So the clamp stands
    -- down rather than jamming the panel against an arbitrary edge, and the
    -- popout stays centred on the row it is about.
    _, _, y = UI.PopoutOutsidePos(WIN, ROW, FRAME_W, 600, DOCK_GAP, 1920, 1080)
    eq(y, ROW.y - 600 / 6, "outside: a popout taller than the window keeps the third rule on its row")
end

-- Missing rects have no answer, the same way PopoutDockPos has none.
do
    eq(UI.PopoutOutsidePos(nil, ROW, FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080), nil,
        "outside: no window, no position")
    eq(UI.PopoutOutsidePos(WIN, nil, FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080), nil,
        "outside: no row, no position")
end

-- ---- the live dock ------------------------------------------------
-- An EXPLICIT SCREEN ANCHOR, not a frame anchor: the y is a function of the row
-- AND of two clamps, and no SetPoint against either frame can say that.
do
    local win, row = outsideWindow(), outsideRow()
    local p = popout({ key = "outside" })
    p.frame:SetFakeCenter(CX + OUT_X, CY + OUT_Y)
    p:Follow(row, { outsideOf = win })
    eq(p.side, "right", "outside: it docked outside the window's right edge")
    eq(p.outsideOf, win, "outside: the mode is stored on the instance")
    local pt = p.frame._points[1]
    eq(pt[1], "CENTER", "outside: anchored by its centre")
    eq(pt[2], UIParent, "outside: ...to the SCREEN, not to the window or the row")
    eq(pt[4], OUT_X, "outside: at the x PopoutOutsidePos computed")
    eq(pt[5], OUT_Y, "outside: and the y")

    -- Both baselines are taken at dock time, so the very next tick reads
    -- "nothing moved" rather than re-docking for free.
    eq(p._srcX, ROW.x, "outside: the row baseline is set")
    eq(p._winW, WIN_W, "outside: and the window has one of its own")

    -- The tether is the ROW throughout: the window is only where the popout
    -- stands, never what it is about.
    check(p.beam:IsShown(), "outside: the beam is up")
    check(p.notch:IsShown(), "outside: so is the connection point")
    eq(p.notch._points[#p.notch._points][3], "LEFT", "outside: right-docked, on the popout's LEFT edge")
    eq(p.srcOutline._points[1][2], row, "outside: the source outline is on the ROW, not the window")
    eq(p.beam.core._start.x, OUT_X - FRAME_W / 2, "outside: the beam leaves the popout's left face")
    eq(p.beam.core._start.y, ROW.y, "outside: slid level with the row's centre")
    eq(p.beam.core._end.x, ROW.x + ROW_W / 2, "outside: and lands on the row's near face")
    eq(p.beam.core._end.y, ROW.y, "outside: straight across -- over the window, to the row")
    p:Close()
end

-- A forced side, live.
do
    local win, row = outsideWindow(), outsideRow()
    local p = popout({ key = "outsideforced" })
    p:Follow(row, { outsideOf = win, side = "left" })
    eq(p.side, "left", "outside: opts.side forces the window edge")
    eq(p.frame._points[1][4], -OUT_X, "outside: ...and the popout is on the other side of it")
    p:Close()
end

-- A plain Follow afterwards CLEARS the mode: the popout goes back to docking
-- beside its source like any other.
do
    local win, row = outsideWindow(), outsideRow()
    local p = popout({ key = "outsideclear" })
    p:Follow(row, { outsideOf = win })
    check(p.outsideOf ~= nil, "outside: the mode is on")
    p:Follow(row)
    eq(p.outsideOf, nil, "outside: a plain Follow clears it")
    eq(p.frame._points[1][2], row, "outside: ...and it anchors to the row again")
    p:Close()

    local q = popout({ key = "outsidefree" })
    q:Follow(outsideRow(), { outsideOf = outsideWindow() })
    q:PlaceFree(0, 0)
    eq(q.outsideOf, nil, "outside: PlaceFree clears it too -- absolute placement docks to nothing")
    q:Close()
end

-- ---- the two-rect ticker ------------------------------------------
-- The row moves when the list scrolls AND when the window is dragged; the window
-- moves on its own when it is RESIZED. Both have to re-dock, and neither may
-- cost anything while nothing has moved.
do
    local win, row = outsideWindow(), outsideRow()
    local p = popout({ key = "outsidetick" })
    p.frame:SetFakeCenter(CX + OUT_X, CY + OUT_Y)
    p:Follow(row, { outsideOf = win })

    local docks = 0
    local realSetPoint = p.frame.SetPoint
    p.frame.SetPoint = function(s, ...) docks = docks + 1 return realSetPoint(s, ...) end

    p.frame:GetScript("OnUpdate")(p.frame)
    eq(docks, 0, "outside: a tick with neither rect moved re-docks nothing")

    -- Scrolled: the row drops 100, so the popout drops 100 with it.
    row:SetFakeCenter(CX + ROW.x, CY + ROW.y - 100)
    p.frame:GetScript("OnUpdate")(p.frame)
    check(docks > 0, "outside: a moved ROW re-docks")
    eq(p.frame._points[1][5], OUT_Y - 100, "outside: the y follows the row")
    eq(p.frame._points[1][4], OUT_X, "outside: the x does not -- the window did not move")

    -- Resized wider on the right: the row is unmoved, but the edge the popout
    -- stands outside of is not where it was. This is the case the source
    -- baseline alone cannot see.
    docks = 0
    win:SetSize(WIN_W + 200, WIN_H)
    p.frame:GetScript("OnUpdate")(p.frame)
    check(docks > 0, "outside: a WINDOW resize re-docks even though the row never moved")
    eq(p.frame._points[1][4], (WIN_W + 200) / 2 + DOCK_GAP + FRAME_W / 2,
        "outside: the popout tracked the window's new right edge")
    eq(p.frame._points[1][5], OUT_Y - 100, "outside: ...without disturbing the row-tracked y")

    -- And a plain window move.
    docks = 0
    win:SetSize(WIN_W, WIN_H)
    win:SetFakeCenter(CX + 40, CY)
    p.frame:GetScript("OnUpdate")(p.frame)
    check(docks > 0, "outside: a moved WINDOW re-docks")
    eq(p.frame._points[1][4], OUT_X + 40, "outside: the x travelled with it")

    docks = 0
    p.frame:GetScript("OnUpdate")(p.frame)
    eq(docks, 0, "outside: and it settles again -- both baselines were re-taken")

    p.frame.SetPoint = realSetPoint
    p:Close()
end

-- ---- the row scrolled out of view ---------------------------------
-- ⚠ A clipped row is still IsShown(). The chrome is gated on the row's rect
-- still overlapping the window's, and ONLY the chrome: the popout stays up and
-- stays docked, because scrolling a list must not close the panel you scrolled
-- the list to configure.
do
    local win, row = outsideWindow(), outsideRow()
    local p = popout({ key = "outsideclip" })
    p.frame:SetFakeCenter(CX + OUT_X, CY + OUT_Y)
    p:Follow(row, { outsideOf = win })
    check(p.beam:IsShown() and p.notch:IsShown() and p.srcOutline:IsShown(),
        "clip: all three pieces of chrome are up while the row is in view")

    -- Scrolled clean out of the bottom of the window.
    row:SetFakeCenter(CX + ROW.x, CY - 400)
    p.frame:GetScript("OnUpdate")(p.frame)
    check(p:IsShown(), "clip: the popout stays up")
    check(not p.closed, "clip: and stays open -- a clipped row is not a dead one")
    check(not p.beam:IsShown(), "clip: the beam goes -- it pointed at a row nobody can see")
    check(not p.notch:IsShown(), "clip: so does the connection point")
    check(not p.srcOutline:IsShown(), "clip: and the source outline")
    eq(p.frame._points[1][5], -(WIN_H / 2 - FRAME_H / 2),
        "clip: it holds inside the window's bottom edge rather than trailing the row")

    -- Scrolled back.
    row:SetFakeCenter(CX + ROW.x, CY + ROW.y)
    p.frame:GetScript("OnUpdate")(p.frame)
    check(p.beam:IsShown(), "clip: scrolled back into view, the beam returns")
    check(p.notch:IsShown(), "clip: ...and the point")
    check(p.srcOutline:IsShown(), "clip: ...and the outline")
    eq(p.srcOutline._points[1][2], row, "clip: re-anchored to the row it came back on")
    eq(p.frame._points[1][5], OUT_Y, "clip: and the popout is level with the row again")
    p:Close()
end

-- ---- the clipper is not the window --------------------------------
-- ☠ A settings window is not its list. Its title bar, its blurb and its padding
-- all sit INSIDE the window and OUTSIDE the viewport, so a row scrolled off the
-- top of the list stops being drawn a good 50px before its rect stops
-- overlapping the window. Gated on the window, the beam and the outline spent
-- that whole stretch drawn over the window's own title bar, pointing at a row
-- nobody could see. opts.clipTo names the rect that really clips.
do
    local win = outsideWindow()
    -- The viewport: the window less 72px of chrome above the list and padding
    -- below it, so it spans y = -200 .. 164 where the window spans -200 .. 200.
    local view = source(WIN_W - 24, WIN_H - 72, CX, CY - 36)
    local row = outsideRow()
    local p = popout({ key = "outsideclipto" })
    p.frame:SetFakeCenter(CX + OUT_X, CY + OUT_Y)
    p:Follow(row, { outsideOf = win, clipTo = view })
    check(p.beam:IsShown() and p.srcOutline:IsShown(), "clipto: in the viewport, the chrome is up")

    -- Scrolled up behind the window's own title bar: the row spans 170..210 --
    -- clean out of the VIEWPORT, still comfortably inside the WINDOW.
    row:SetFakeCenter(CX + ROW.x, CY + 190)
    p.frame:GetScript("OnUpdate")(p.frame)
    check(p:_TetherClipped(), "clipto: gated on the viewport, that row counts as clipped")
    check(not p.beam:IsShown(), "clipto: so the beam goes")
    check(not p.srcOutline:IsShown(), "clipto: and the outline with it")
    check(p:IsShown() and not p.closed, "clipto: while the popout itself stays up, as ever")

    -- The very same rects with no clipTo. This is the old answer, and it is the
    -- bug: the window alone still calls that row visible.
    p.clipTo = nil
    check(not p:_TetherClipped(), "clipto: the window alone reads the same row as still on screen")
    p:Close()
end

-- ---- the ink rect: a region says which part of it is drawn ---------
-- A settings row's frame is its whole layout SLOT, gap to the next row included,
-- and nothing is painted in that gap. `region.popoutInset` trims it, and every
-- rect the shell takes honours it -- so the outline is drawn round the plate
-- rather than round the slot, and the beam aims at the plate.
-- A DELIBERATELY EXAGGERATED trim -- 30 of the 40-tall slot, leaving a 10-tall
-- strip of ink along its top. A real row trims RowGap, but at that size the
-- beam's landing point falls inside the ink either way and the claim below could
-- not tell a working inset from a broken one.
local INK_TRIM = 30
do
    local win = outsideWindow()
    local row = outsideRow()
    row.popoutInset = { 0, 0, 0, INK_TRIM }
    -- Trimming the bottom of the slot lifts its centre by half the trim, and the
    -- placement puts the PLATE a third down the popout -- so this IS where it lands.
    local INK_Y = ROW.y + INK_TRIM / 2 - FRAME_H / 6
    local p = popout({ key = "outsideink" })
    p.frame:SetFakeCenter(CX + OUT_X, CY + INK_Y)
    p:Follow(row, { outsideOf = win })

    eq(p.frame._points[1][5], INK_Y, "ink: the placement centres on the PLATE, not on the whole slot")

    -- The stub resolves no anchors, so the outline's OFFSETS are the claim: it is
    -- inset by the trim rather than laid flush over the frame.
    local tl, br = p.srcOutline._points[1], p.srcOutline._points[2]
    eq(tl[1], "TOPLEFT", "ink: the outline still starts at the region's top-left")
    eq(tl[4], 0, "ink: ...flush on x")
    eq(tl[5], 0, "ink: ...and on y, because nothing is trimmed off the top")
    eq(br[1], "BOTTOMRIGHT", "ink: and it ends at the region's bottom-right")
    eq(br[5], INK_TRIM, "ink: lifted clear of the trimmed gap")

    -- The beam stops at the INK's bottom edge rather than reaching down into the
    -- part of the slot that paints nothing: the ink is the top (ROW_H - INK_TRIM)
    -- of the slot, so its bottom edge is that far below the row's top.
    local inkBottom = ROW.y + ROW_H / 2 - (ROW_H - INK_TRIM)
    check(p.beam.core._end.y >= inkBottom,
        "ink: and the beam lands on the plate, not down in the slot's empty gap")
    p:Close()
end

-- Outside the mode there is no clipper to ask about, so an ordinary popout is
-- never gated by any of this.
do
    local src = source(80, 40, CX, CY)
    local p = popout({ key = "outsidenoclip" })
    p.frame:SetFakeCenter(dockedRightOfCentre())
    p:Follow(src)
    check(not p:_TetherClipped(), "clip: a plain Follow is never clipped")
    check(p.beam:IsShown(), "clip: ...so its chrome is untouched")
    p:Close()
end

-- ---- the retarget glide, in the settings placement -----------------
do
    local win = outsideWindow()
    local rowA, rowB = outsideRow(), outsideRow(-100)     -- rowB's rect sits at y = -100
    -- The destination, stated up front: it is PopoutOutsidePos of rowB, and every
    -- claim below about where the glide goes is measured against it.
    local _, GX, GY = UI.PopoutOutsidePos(WIN, { x = ROW.x, y = -100, w = ROW_W, h = ROW_H },
                                          FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080)
    local p = popout({ key = "outsideglide" })
    p.frame:SetFakeCenter(CX + OUT_X, CY + OUT_Y)
    p:Follow(rowA, { outsideOf = win })
    check(not p.gliding, "outglide: the first placement is not a glide")

    local moves = {}
    local realSetPoint = p.frame.SetPoint
    p.frame.SetPoint = function(s, ...) moves[#moves + 1] = { ... } return realSetPoint(s, ...) end

    p:Follow(rowB, { outsideOf = win })
    check(p.gliding, "outglide: retargeting to another row glides")
    local first = moves[#moves]
    eq(first[1], "CENTER", "outglide: it drives its own screen anchor for the ride")
    eq(first[2], UIParent, "outglide: ...off UIParent")
    eq(first[4], OUT_X, "outglide: starting exactly where it already was")
    eq(first[5], OUT_Y, "outglide: ...on both axes")
    eq(p.srcOutline._points[1][2], rowB, "outglide: the outline commits to the new row at once")

    p.frame:GetScript("OnUpdate")(p.frame, 0.06)
    check(p.gliding, "outglide: part-way through, still gliding")
    eq(p._gX, OUT_X, "outglide: the x never changes -- only the row's height did")
    check(p._gY < OUT_Y and p._gY > GY, "outglide: ...and the y is between the two rows")

    -- Run it out. The landing keeps the EXPLICIT anchor -- _Dock's outsideOf arm
    -- re-takes it rather than handing the frame back to a source anchor it cannot
    -- express.
    p.frame:GetScript("OnUpdate")(p.frame, 1)
    check(not p.gliding, "outglide: it finishes")
    local landed = moves[#moves]
    eq(landed[1], "CENTER", "outglide: it lands on an explicit screen anchor")
    eq(landed[2], UIParent, "outglide: ...still off UIParent, not the row")
    eq(landed[4], GX, "outglide: exactly on PopoutOutsidePos of the new row")
    eq(landed[5], GY, "outglide: ...on both axes")
    eq(p.source, rowB, "outglide: and it is following the new row")
    check(p.beam:IsShown(), "outglide: with its chrome back on the row it arrived at")

    -- The follow works again from there: the ticker's baselines were re-taken on
    -- the way through, so a fresh scroll still moves it.
    p.frame:SetFakeCenter(CX + GX, CY + GY)
    rowB:SetFakeCenter(CX + ROW.x, CY - 150)
    p.frame:GetScript("OnUpdate")(p.frame)
    -- Third rule wants -150 - h/6 = -166.33, but the row now sits close enough
    -- to the window's bottom that the span clamp engages: the popout holds at
    -- the clamp instead.
    eq(p.frame._points[1][5], -SLACK,
        "outglide: and the ordinary follow works from the landing (clamped)")
    p.frame.SetPoint = realSetPoint
    p:Close()
end

-- ---- the connection point on a THIN row ---------------------------
-- The slide clamp keeps the diamond NOTCH_EDGE_INSET (14) clear of the popout's
-- corners. While the popout HUNG FROM THE ROW'S TOP that clamp bit on every row
-- shorter than 2 x 14 = 28: the row's centre sat inside the inset and the point
-- stopped 14 below the popout's top instead of reaching it, leaving the beam
-- running at a slight diagonal. Centring the popout on the row retires that
-- whole class of miss -- the row's centre IS the popout's centre, which is as
-- far from either corner as a point can get.
do
    local win, row = outsideWindow(), outsideRow(ROW.y, 20)
    local p = popout({ key = "outsidethin" })
    p.frame:SetFakeCenter(CX + OUT_X, CY + ROW.y)
    p:Follow(row, { outsideOf = win })
    eq(p.frame._points[1][5], ROW.y - FRAME_H / 6, "thin: a 20-tall row places the popout exactly as any other does")
    eq(p.beam.core._start.y, ROW.y, "thin: so the point reaches the row's centre instead of stopping short")
    eq(p.beam.core._end.y, ROW.y, "thin: ...and the beam runs dead level rather than at a diagonal")
    p:Close()
end

-- The clamp has NOT gone, it has just stopped mattering for the everyday case.
-- It still bites when the window clamp has pulled the popout off its row -- a row
-- against the window's own edge with a panel that only just fits beside it.
do
    -- A 396-tall popout in a 400-tall window leaves 2px of slack, so a row 190
    -- above the window's middle cannot be centred on: the popout is held at y = 2
    -- and the row is 188 above THAT. The point may slide 396/2 - 14 = 184, so it
    -- stops at 186 -- 4 short of the row, and clear of the corner, which is what
    -- the inset is for.
    local TALL = 396
    local thin = { x = ROW.x, y = 190, w = ROW_W, h = 20 }
    local _, _, y = UI.PopoutOutsidePos(WIN, thin, FRAME_W, TALL, DOCK_GAP, 1920, 1080)
    eq(y, WIN_H / 2 - TALL / 2, "inset: the window clamp pulls a tall popout off its row")
    local pr = { x = OUT_X, y = y, w = FRAME_W, h = TALL }
    local _, ty = UI.PopoutNotchTip(pr, "right", 0, thin)
    eq(ty, y + TALL / 2 - 14, "inset: and the point stops at the corner inset rather than reaching it")
    check(ty < thin.y, "inset: ...a little short of the row, which is the cosmetic ceiling that remains")
end

-- ============================================================
-- 13. THE SCALED WINDOW -- the real settings page's geometry
-- ------------------------------------------------------------
-- ☠ A FRAME'S OWN GEOMETRY IS NOT IN UIPARENT UNITS. GetCenter/GetWidth answer
-- in the frame's OWN coordinate space -- the screen divided by its EFFECTIVE
-- scale -- and DandersFrames' settings window carries a user scale slider. Every
-- rect in Popout.lua is declared to be in UIParent-centre units, so a region
-- under that window has to be converted before it can be compared with the
-- popout's (which lives at UIParent scale) or handed to a screen anchor.
--
-- Left unconverted, the error is (distance from UIParent's centre) x (1/s - 1),
-- which at the window's edge is over a hundred pixels: the popout docked a long
-- way clear of the window and the beam's far end stopped short of the row's
-- plate, hanging in dead space to the right of it. Reported in-game 2026-08-26,
-- and invisible in /df popoutdemo for the reason it is invisible in every test
-- above -- an unscaled window is the one case where the two spaces agree.
--
-- The scene below is the real one, in the real proportions: a 1000 x 700 window
-- at 85%, and a 260-wide row whose plate stops well inside the window's right
-- edge (page padding + scrollbar gutter + the column beside it).
-- ============================================================
local S = 0.85                       -- the settings window's scale slider
-- own units -> UIParent units, and back. The window and everything in it is
-- laid out in DESIGN pixels (its own space); the beam is not.
local function up(v) return v * S end
local function own(v) return v / S end

-- ⚠ THE POPOUT IS ONE OF THE SCALED THINGS TOO. In outsideOf mode it takes the
-- window's scale as its own, so a slider inside it matches the identical slider
-- on the page it was opened from (Danders, in-game: "popouts should also scale by
-- the UI scale value too"). Its FRAME is still FRAME_W x FRAME_H -- that is a box
-- in its own units and the scale does not change it -- but the rect it occupies
-- on screen, which is what every number in this file is stated in, is that box
-- times S. Both spellings are needed below: the anchor it records is read in its
-- own units, everything else in UIParent's.
local PFW, PFH = up(FRAME_W), up(FRAME_H)

do
    -- ---- the window ------------------------------------------------
    -- 1000 x 700 design pixels, centred on the screen -> 850 x 595 on it.
    local SW_OWN, SH_OWN = 1000, 700
    local win = source(SW_OWN, SH_OWN, own(CX), own(CY))
    win:SetScale(S)
    local WIN_RIGHT = up(SW_OWN) / 2                  -- +425 from the screen centre

    -- ---- the row ---------------------------------------------------
    -- A PopoutRow's real box model: a 50-tall SLOT whose bottom 6 is the gap to
    -- the next row, so the visible plate is the top 44. Declared exactly as
    -- PopoutRow.lua declares it -- in the row's OWN units, which is what the
    -- inset protocol is stated in.
    local SLOT_OWN, PLATE_OWN, GAP_OWN, ROW_W_OWN = 50, 44, 6, 260
    -- Where the PLATE's right edge lands: 120 screen px inside the window's own
    -- right edge. That is the page padding, the scrollbar gutter and the column
    -- to its right -- the stretch of dead space the beam has to cross, and the
    -- stretch it was stopping short in.
    local PLATE_RIGHT = WIN_RIGHT - 120
    local PLATE_CY    = 80                            -- above the screen centre
    -- Back out the SLOT's centre from the plate's, in UIParent units, then say
    -- it in the row's own units -- which is the only space the stub can be told
    -- a centre in, and the only one WoW would answer one in.
    local ROW_CX = PLATE_RIGHT - up(ROW_W_OWN) / 2
    local ROW_CY = PLATE_CY - up(GAP_OWN) / 2
    local row = source(ROW_W_OWN, SLOT_OWN, own(CX + ROW_CX), own(CY + ROW_CY))
    row:SetScale(S)
    row.popoutInset = { 0, 0, 0, GAP_OWN }

    -- Where the dock is about to put it, ON SCREEN. Said UP FRONT because the stub
    -- resolves no anchors: the beam's NEAR end is read off the frame's own rect,
    -- so a frame left at the origin would draw the beam from off-screen and the
    -- far end would clamp onto the wrong face of the row. Every live dock test
    -- above seeds it the same way -- in the frame's OWN units, which for a popout
    -- wearing the window's scale is the screen position divided by it.
    local DOCK_X = WIN_RIGHT + DOCK_GAP + PFW / 2
    local DOCK_Y = PLATE_CY - PFH / 6

    local p = popout({ key = "scaled" })
    p.frame:SetFakeCenter(own(CX + DOCK_X), own(CY + DOCK_Y))
    p:Follow(row, { outsideOf = win })

    -- ---- the scale -------------------------------------------------
    -- The panel and the page it was opened from are ONE surface, so they are one
    -- size. Left at 1.0 the popout's sliders came up visibly bigger than the
    -- identical sliders on the page behind them.
    eq(p.frame:GetScale(), S, "scaled: the popout wears the window's scale")

    -- ---- the dock --------------------------------------------------
    -- The SetPoint offset is read in the popout frame's own units, so the screen
    -- position it resolves to comes back through that scale.
    eq(p.side, "right", "scaled: it still docks outside the window's right edge")
    eq(p.frame._points[1][4], own(DOCK_X),
        "scaled: a gap clear of the window's edge ON SCREEN, not of its unscaled rect")
    eq(p.frame._points[1][5], own(DOCK_Y),
        "scaled: and a third down from the PLATE's screen height")

    -- ---- the beam --------------------------------------------------
    -- The whole of the report: the far end has to land ON the plate's edge --
    -- the accent-bordered box the user sees, and the same rect the source
    -- outline is drawn round -- not somewhere out in the gutter beside it.
    check(p.beam:IsShown(), "scaled: the beam is up")
    eq(p.beam.core._start.x, WIN_RIGHT + DOCK_GAP, "scaled: it leaves the popout's left face")
    eq(p.beam.core._end.x, PLATE_RIGHT, "scaled: and TOUCHES the plate's right edge")
    eq(p.beam.core._end.y, PLATE_CY, "scaled: dead level with the plate, gap and all")
    eq(p.beam.core._start.y, PLATE_CY, "scaled: ...so the beam runs flat rather than at a diagonal")

    -- The source outline is ANCHORED to the row, so it was always right; this is
    -- the assertion that the beam now agrees with it about where the row is.
    eq(p.srcOutline._points[1][2], row, "scaled: the outline is still on the row itself")
    -- The outline hangs off the popout's PARENT, not off the row, so the row's
    -- own 6px gap is read back at the parent's scale -- the same trip the beam
    -- makes, which is what keeps the two describing one rect.
    eq(p.srcOutline._points[2][5], up(GAP_OWN),
        "scaled: the outline trims the gap at the scale it is actually drawn at")
    p:Close()
end

-- A row that declares SIDE padding too: the beam stops at the ink, not at the
-- slot, and the inset is read in the row's own units before the conversion.
do
    local SW_OWN = 1000
    local win = source(SW_OWN, 700, own(CX), own(CY))
    win:SetScale(S)
    local WIN_RIGHT = up(SW_OWN) / 2

    local SLOT_W_OWN, PAD_OWN = 260, 20
    local SLOT_RIGHT = WIN_RIGHT - 120
    local row = source(SLOT_W_OWN, 44, own(CX + SLOT_RIGHT - up(SLOT_W_OWN) / 2), own(CY))
    row:SetScale(S)
    row.popoutInset = { PAD_OWN, PAD_OWN, 0, 0 }

    local p = popout({ key = "scaledinset" })
    p.frame:SetFakeCenter(own(CX + WIN_RIGHT + DOCK_GAP + PFW / 2), own(CY - PFH / 6))
    p:Follow(row, { outsideOf = win })
    eq(p.beam.core._end.x, SLOT_RIGHT - up(PAD_OWN),
        "inset: the beam lands on the INK's edge, a scaled pad inside the slot's")
    p:Close()
end

-- tetherSource is documented as a REGION, and a texture is one: it answers
-- GetCenter/GetWidth in its parent's space and has no GetEffectiveScale of its
-- own. Falling back to 1 for those would be the whole bug again, so the ratio
-- walks up to the nearest frame that can answer.
do
    local SW_OWN = 1000
    local win = source(SW_OWN, 700, own(CX), own(CY))
    win:SetScale(S)
    local WIN_RIGHT = up(SW_OWN) / 2
    local row = source(260, 44, own(CX + 100), own(CY))
    row:SetScale(S)

    -- A bare region: no SetScale, no GetEffectiveScale, parented to the scaled
    -- row. Built by hand rather than from FakeUIFrame, whose stubs answer
    -- everything -- including the method whose ABSENCE is the case under test.
    local TEX_W = 120
    local TEX_RIGHT = WIN_RIGHT - 200
    local tex = {
        GetCenter = function() return own(CX + TEX_RIGHT) - TEX_W / 2, own(CY) end,
        GetWidth  = function() return TEX_W end,
        GetHeight = function() return 20 end,
        GetParent = function() return row end,
        IsShown   = function() return true end,
    }
    setmetatable(tex, { __index = function() return function() end end })

    local p = popout({ key = "scaledtex", tetherSource = tex })
    p.frame:SetFakeCenter(own(CX + WIN_RIGHT + DOCK_GAP + PFW / 2), own(CY - PFH / 6))
    p:Follow(row, { outsideOf = win })
    eq(p.beam.core._end.x, TEX_RIGHT,
        "texregion: the beam lands on the texture's edge, measured at its PARENT's scale")
    p:Close()
end

-- The clip gate is a comparison of two rects, and both of them are under the
-- scaled window: a row inside the viewport keeps its chrome, one scrolled clear
-- of it loses the lot.
do
    local win = source(1000, 700, own(CX), own(CY))
    win:SetScale(S)
    -- The viewport: the window less its title bar and padding, so a row can be
    -- inside the WINDOW and outside the LIST -- the case clipTo exists for.
    local sf = source(960, 560, own(CX), own(CY - 40))
    sf:SetScale(S)
    local row = source(260, 44, own(CX + 100), own(CY))
    row:SetScale(S)

    local p = popout({ key = "scaledclip" })
    p:Follow(row, { outsideOf = win, clipTo = sf })
    check(p.beam:IsShown(), "scaledclip: a row inside the viewport keeps its beam")

    -- Scrolled off the top of the LIST while still inside the window: 340 own
    -- units up puts the row clear of the 560-tall viewport and only just clear
    -- of the 700-tall window, which is the stretch the window-only gate missed.
    row:SetFakeCenter(own(CX + 100), own(CY - 40) + 340)
    p:_UpdateBeam()
    check(not p.beam:IsShown(), "scaledclip: scrolled out of the viewport takes it away again")
    p:Close()
end

-- ============================================================
-- 14. THE FRAME STACK -- where the connected chrome is DRAWN
-- ------------------------------------------------------------
-- ☠ THE BEAM'S CROSSING SEGMENT IS DRAWN OVER THE WINDOW'S BODY. In outsideOf
-- mode the popout stands outside the window's edge and the beam runs from it, in
-- over that edge, across the window's padding and its page, to a row. Every pixel
-- of that after the dock gap is over something the window owns -- so if the beam
-- is not ABOVE the window's whole subtree, the only part of it that is ever drawn
-- is the short stretch in the gap. Which is precisely what "the beam stops short
-- of the row" looks like, and it is what Danders was still seeing in-game on
-- 2026-08-27 with the window at 100% scale (i.e. with the scale conversion of
-- section 13 already in and ruled out).
--
-- Clearing the WINDOW is not enough, and that was the bug: the old margin was the
-- window's level + 10, while the row itself is already the window's level plus
-- four or five (window -> content -> page -> scroll child -> row -> plate) and a
-- settings window's own widgets bump their level off their container by +10 for a
-- control that must draw over its neighbours and by +50 for a disabled overlay
-- laid across a group. WINDOW_CLEARANCE is the margin that beats all of them.
-- ============================================================
-- Mirrors Popout.lua's own constant, for the reason the theme metrics at the top
-- of this file are mirrored: a retune of the margin should fail HERE, out loud,
-- rather than quietly re-baseline itself.
local CLEARANCE = 60

do
    local win, row = outsideWindow(), outsideRow()
    local p = popout({ key = "stack" })
    p.frame:SetFakeCenter(CX + OUT_X, CY + OUT_Y)
    p:Follow(row, { outsideOf = win })

    local WL = win:GetFrameLevel()
    eq(p.frame:GetFrameLevel(), WL + CLEARANCE,
        "stack: the popout stands a full clearance above the window, not +10")
    eq(p.beam:GetFrameLevel(), WL + CLEARANCE - 1,
        "stack: the beam is in the sliver just under it -- over the body, under the notch")
    eq(p.srcOutline:GetFrameLevel(), WL + CLEARANCE - 1,
        "stack: and so is the source outline, which lies ON a row inside the window")

    -- One strata for the three, and it is the WINDOW's: a level only orders frames
    -- within a strata, so a beam one strata below what it crosses is under it
    -- whatever its level says.
    eq(p.frame._flags.strata, "DIALOG", "stack: the popout is on the window's strata")
    eq(p.beam._flags.strata, "DIALOG", "stack: the beam with it")
    eq(p.srcOutline._flags.strata, "DIALOG", "stack: the outline too -- the three are one object")
    p:Close()
end

-- A window that is NOT where the last one was in the stack: the popout is placed
-- against whatever it is actually handed, strata and level both.
do
    local win, row = outsideWindow(), outsideRow()
    win:SetFrameStrata("FULLSCREEN_DIALOG")
    win:SetFrameLevel(90)
    local p = popout({ key = "stackhigh" })
    p.frame:SetFakeCenter(CX + OUT_X, CY + OUT_Y)
    p:Follow(row, { outsideOf = win })
    eq(p.frame:GetFrameLevel(), 90 + CLEARANCE, "stack: measured off THIS window's level")
    eq(p.frame._flags.strata, "FULLSCREEN_DIALOG", "stack: ...and it follows its strata up")
    eq(p.beam._flags.strata, "FULLSCREEN_DIALOG", "stack: the beam does not get left behind on DIALOG")
    eq(p.srcOutline._flags.strata, "FULLSCREEN_DIALOG", "stack: nor the outline")

    -- ⚠ AND IT IS RE-DERIVED, not taken once. DandersFrames' settings window is
    -- SetToplevel(true): it raises itself above everything in its strata the
    -- moment it is clicked, WITHOUT MOVING A PIXEL -- so the two-rect compare the
    -- ticker already does cannot see it, and a level taken once at Follow is stale
    -- from the first click onwards. That is a beam that was fine when the panel
    -- opened and sank under the window a moment later.
    win:SetFrameLevel(400)
    p.frame:GetScript("OnUpdate")(p.frame)
    eq(p.frame:GetFrameLevel(), 400 + CLEARANCE, "stack: a window RAISE is caught on the next tick")
    eq(p.beam:GetFrameLevel(), 400 + CLEARANCE - 1, "stack: the beam comes up with it")
    eq(p.srcOutline:GetFrameLevel(), 400 + CLEARANCE - 1, "stack: and so does the outline")

    -- EXACTLY the clearance, never "at least" it: settling on one answer is what
    -- stops a raise from ratcheting the pair ten levels higher every time, and it
    -- lets a popout re-pointed at a lower window come back down.
    win:SetFrameLevel(20)
    p.frame:GetScript("OnUpdate")(p.frame)
    eq(p.frame:GetFrameLevel(), 20 + CLEARANCE, "stack: it settles back down again rather than ratcheting")

    -- Leaving the mode puts everything back on the base strata. A POOLED popout is
    -- re-used for whatever the next consumer asks of it, and one that inherited a
    -- window's strata must not carry it into a placement that has no window.
    p:Follow(row)
    eq(p.frame._flags.strata, "DIALOG", "stack: a plain Follow hands the popout back to DIALOG")
    eq(p.beam._flags.strata, "DIALOG", "stack: the beam with it")
    eq(p.srcOutline._flags.strata, "DIALOG", "stack: and the outline")
    p:Close()
end

-- THE MOVER'S CONTEXT, which has no window at all: the popout hangs off an unlock
-- overlay and its own level is the only thing the beam and outline can be placed
-- against. That relative sync is the fallback, and it must survive untouched.
do
    local p = popout({ key = "stackfree" })
    local src = source(40, 40, CX - 200, CY)
    p:Follow(src)
    -- The outline is built as a SIBLING of the proxy slab it outlines -- both hang
    -- off the unlock overlay -- and the level it is built with is the one that
    -- puts it over that slab. Stand in for it with a level of its own and watch it
    -- survive: dropping it to popout-1 out here would put it a level BELOW the
    -- slab and the outline would stop being visible at all.
    p.srcOutline:SetFrameLevel(77)
    p.frame:SetFrameLevel(40)          -- as a popout parented to an overlay would be
    p:_UpdateBeam()
    p:_UpdateSourceOutline()
    eq(p.beam:GetFrameLevel(), 39, "movercase: the beam still sits just under the popout")
    eq(p.srcOutline:GetFrameLevel(), 77, "movercase: the outline is left where its parent put it")
    eq(p.frame._flags.strata, "DIALOG", "movercase: no window, so nothing moved off the base strata")
    p:Close()
end

-- ============================================================
-- 15. THE POPOUT WEARS THE WINDOW'S SCALE
-- ------------------------------------------------------------
-- "Popouts should also scale by the UI scale value too" (Danders, 2026-08-27).
-- The settings window has a user scale slider; a popout parented to UIParent
-- renders at 1.0 whatever that slider says, so the sliders inside the panel came
-- up bigger than the identical sliders on the page it was opened from and the two
-- stopped reading as one surface.
--
-- The whole change is one SetScale. Everything downstream survives it because
-- every rect in Popout.lua is in UIParent units and every one of them already
-- converts through the frame's own ratio -- so this section is the proof of that
-- claim rather than of the SetScale: dock, beam, connection point and glide
-- landing, all at 80%, all still agreeing with each other.
-- ============================================================
local S2 = 0.8
local function up2(v) return v * S2 end
local function own2(v) return v / S2 end

do
    -- The window: 1000 x 600 design px at 80% -> 800 x 480 on screen.
    local win = source(1000, 600, own2(CX), own2(CY))
    win:SetScale(S2)
    local WIN_RIGHT = up2(1000) / 2                    -- +400

    -- The row: a 50-tall slot whose bottom 6 is the gap, plate 100 screen px
    -- inside the window's right edge.
    local SLOT_OWN, GAP_OWN, ROW_W_OWN = 50, 6, 260
    local PLATE_RIGHT, PLATE_CY = WIN_RIGHT - 100, 60
    local row = source(ROW_W_OWN, SLOT_OWN,
                       own2(CX + PLATE_RIGHT - up2(ROW_W_OWN) / 2),
                       own2(CY + PLATE_CY - up2(GAP_OWN) / 2))
    row:SetScale(S2)
    row.popoutInset = { 0, 0, 0, GAP_OWN }

    -- The popout's SCREEN size, which is its own box times the window's scale.
    local PW, PH = up2(FRAME_W), up2(FRAME_H)
    local DOCK_X = WIN_RIGHT + DOCK_GAP + PW / 2
    local DOCK_Y = PLATE_CY - PH / 6

    local p = popout({ key = "scale80" })
    p.frame:SetFakeCenter(own2(CX + DOCK_X), own2(CY + DOCK_Y))
    p:Follow(row, { outsideOf = win })

    eq(p.frame:GetScale(), S2, "scale80: the popout took the window's scale")

    -- ---- the dock ---------------------------------------------------
    eq(p.frame._points[1][4], own2(DOCK_X), "scale80: docked a gap clear of the window's edge on SCREEN")
    eq(p.frame._points[1][5], own2(DOCK_Y), "scale80: with the row a third down its SCALED height")

    -- ---- the beam ---------------------------------------------------
    -- The endpoints are UIParent-centre and the beam frame is unscaled, so they
    -- are read straight off -- which is the point: the popout shrank and the two
    -- ends still meet.
    eq(p.beam.core._start.x, WIN_RIGHT + DOCK_GAP, "scale80: the beam leaves the popout's left face")
    eq(p.beam.core._end.x, PLATE_RIGHT, "scale80: and TOUCHES the plate's right edge")
    eq(p.beam.core._start.y, PLATE_CY, "scale80: dead level with the plate")
    eq(p.beam.core._end.y, PLATE_CY, "scale80: ...at both ends, so it runs flat")

    -- ---- the connection point ---------------------------------------
    -- It slides along the popout's left edge to meet the row. The slide is a
    -- UIParent-unit difference and the offset is read in the popout's own units,
    -- so it comes back through the scale it is now wearing -- get that wrong and
    -- the diamond drifts off the end of the beam.
    local np = p.notch._points[#p.notch._points]
    eq(np[3], "LEFT", "scale80: the point is on the popout's left edge")
    eq(np[4], 0, "scale80: no horizontal slide on a left/right dock")
    eq(np[5], own2(PLATE_CY - DOCK_Y), "scale80: slid to the row, measured back in the popout's own units")

    -- ---- the glide --------------------------------------------------
    -- Retarget to a row 120 screen px lower. The destination is PopoutOutsidePos
    -- of that row at the SCALED popout size, and the landing has to be exact.
    local rowB = source(ROW_W_OWN, SLOT_OWN,
                        own2(CX + PLATE_RIGHT - up2(ROW_W_OWN) / 2),
                        own2(CY + PLATE_CY - 120 - up2(GAP_OWN) / 2))
    rowB:SetScale(S2)
    rowB.popoutInset = { 0, 0, 0, GAP_OWN }
    local _, GX, GY = UI.PopoutOutsidePos({ x = 0, y = 0, w = up2(1000), h = up2(600) },
                                          { x = PLATE_RIGHT - up2(ROW_W_OWN) / 2, y = PLATE_CY - 120,
                                            w = up2(ROW_W_OWN), h = up2(SLOT_OWN - GAP_OWN) },
                                          PW, PH, DOCK_GAP, 1920, 1080)

    local moves = {}
    local realSetPoint = p.frame.SetPoint
    p.frame.SetPoint = function(s, ...) moves[#moves + 1] = { ... } return realSetPoint(s, ...) end

    p:Follow(rowB, { outsideOf = win })
    check(p.gliding, "scale80: retargeting glides rather than teleporting")
    p.frame:GetScript("OnUpdate")(p.frame, 1)
    check(not p.gliding, "scale80: and it finishes")
    local landed = moves[#moves]
    eq(landed[4], own2(GX), "scale80: it lands exactly on the new row's dock x")
    eq(landed[5], own2(GY), "scale80: ...and its y, both in the popout's own units")
    p.frame.SetPoint = realSetPoint
    p:Close()
end

-- Leaving the mode gives the scale back. A pooled popout is re-used for whatever
-- comes next, and one still wearing a window's 80% would hand a PlaceFree
-- consumer a panel two sizes too small for the numbers it is about to be given.
do
    local win, row = outsideWindow(), outsideRow()
    win:SetScale(0.7)
    local p = popout({ key = "scaleclear" })
    p:Follow(row, { outsideOf = win })
    eq(p.frame:GetScale(), 0.7, "scaleclear: docked outside a 70% window, it is at 70%")
    p:PlaceFree(0, 0)
    eq(p.frame:GetScale(), 1, "scaleclear: PlaceFree hands it back to 1.0")
    p:Close()

    local q = popout({ key = "scaleclear2" })
    q:Follow(row, { outsideOf = win })
    q:Follow(row)
    eq(q.frame:GetScale(), 1, "scaleclear: and so does a plain Follow")
    q:Close()
end

-- PINNING KEEPS IT. Pinning detaches the panel from the window by hand; snapping
-- it back to 1.0 under the user's cursor would read as the panel jumping, which
-- is the one thing the pin gesture must not do.
do
    local win, row = outsideWindow(), outsideRow()
    win:SetScale(0.75)
    local p = popout({ key = "scalepin" })
    p:Follow(row, { outsideOf = win })
    p:Pin()
    eq(p.frame:GetScale(), 0.75, "scalepin: a pinned popout keeps the scale it was wearing")
    -- ...and re-pointing a pinned popout's SOURCE (which the beam still needs)
    -- does not take it away either.
    p:Follow(outsideRow(-80))
    eq(p.frame:GetScale(), 0.75, "scalepin: re-pointing its source does not resize it")
    p:Close()
end

-- A window with no scale is the case every test above this section is: the ratio
-- comes out 1 and nothing is touched, which is why none of them had to change.
do
    local win, row = outsideWindow(), outsideRow()
    local p = popout({ key = "scaleone" })
    p:Follow(row, { outsideOf = win })
    eq(p.frame:GetScale(), 1, "scaleone: an unscaled window leaves the popout at 1.0")
    p:Close()
end

CreateFrame, C_Timer = prevCreateFrame, prevTimer
