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
    -- The popout's rect is { x = 112, y = -26, 120 x 92 }; right-docked, the
    -- connection point's tip is half a notch left of its left edge.
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
    eq(first[5], -26, "glide: ...on both axes")
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
-- and its TOP level with the row's top.
local OUT_X = WIN_W / 2 + DOCK_GAP + FRAME_W / 2            -- 372
local OUT_Y = ROW.y + ROW.h / 2 - FRAME_H / 2               -- 24

-- Build the pair the live tests drive: a window at screen centre and a row
-- inside it, `dy` above/below the window's middle.
local function outsideWindow() return source(WIN_W, WIN_H, CX, CY) end
local function outsideRow(dy, h) return source(ROW_W, h or ROW_H, CX + ROW.x, CY + (dy or ROW.y)) end

-- ---- the pure geometry, head-on ----------------------------------
do
    local side, x, y = UI.PopoutOutsidePos(WIN, ROW, FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080)
    eq(side, "right", "outside: open screen docks outside the window's RIGHT edge")
    eq(x, OUT_X, "outside: its left edge a gap clear of that edge")
    eq(y, OUT_Y, "outside: hanging from the ROW's top, not the window's")

    -- The row is what moves the popout vertically -- that is the whole reason
    -- this is not just "dock beside the window".
    local _, _, y2 = UI.PopoutOutsidePos(WIN, { x = -100, y = -50, w = ROW_W, h = ROW_H },
                                         FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080)
    eq(y2, -50 + ROW_H / 2 - FRAME_H / 2, "outside: a lower row lowers the popout by the same amount")
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

-- The window clamp: the popout's TOP is held inside the window's vertical span.
-- For a row IN VIEW that is a no-op (its top is inside the span by definition),
-- which is what keeps "level with the row's top" exact.
do
    local below = { x = -100, y = -400, w = ROW_W, h = ROW_H }   -- scrolled off the bottom
    local _, _, y = UI.PopoutOutsidePos(WIN, below, FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080)
    eq(y, -WIN_H / 2 - FRAME_H / 2, "outside: a row below the window pins the popout's top to its bottom edge")
    local above = { x = -100, y = 400, w = ROW_W, h = ROW_H }
    _, _, y = UI.PopoutOutsidePos(WIN, above, FRAME_W, FRAME_H, DOCK_GAP, 1920, 1080)
    eq(y, WIN_H / 2 - FRAME_H / 2, "outside: and a row above it pins the top to the window's top edge")

    -- A popout TALLER than the window is not squeezed -- only its top is clamped,
    -- so it hangs below the window rather than being centred in it.
    _, _, y = UI.PopoutOutsidePos(WIN, ROW, FRAME_W, 600, DOCK_GAP, 1920, 1080)
    eq(y, ROW.y + ROW.h / 2 - 300, "outside: a popout taller than the window still hangs from the row")
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
    eq(p.frame._points[1][5], -WIN_H / 2 - FRAME_H / 2,
        "clip: its top clamps to the window's bottom edge rather than trailing the row")

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
    eq(p.frame._points[1][5], -150 + ROW_H / 2 - FRAME_H / 2,
        "outglide: and the ordinary follow works from the landing")
    p.frame.SetPoint = realSetPoint
    p:Close()
end

-- ---- the connection point on a THIN row ---------------------------
-- ☠ The slide clamp keeps the diamond NOTCH_EDGE_INSET (14) clear of the
-- popout's corners, and the popout's top is level with the row's top -- so for
-- any row shorter than 2*14 = 28 the row's centre is INSIDE that inset and the
-- point cannot quite reach it. It stops 14 below the popout's top instead. The
-- beam still lands on the row (a 20-tall row spans ±10 of its centre, and the
-- miss is 4), so this is a cosmetic ceiling on the alignment, not a break -- but
-- it is a real one, and it is asserted here so a change to either number is
-- caught rather than discovered on screen.
do
    local win, row = outsideWindow(), outsideRow(ROW.y, 20)
    local p = popout({ key = "outsidethin" })
    local thinY = ROW.y + 10 - FRAME_H / 2                      -- top of a 20-tall row
    p.frame:SetFakeCenter(CX + OUT_X, CY + thinY)
    p:Follow(row, { outsideOf = win })
    eq(p.frame._points[1][5], thinY, "thin: the popout still hangs from the row's top")
    eq(p.beam.core._start.y, thinY + FRAME_H / 2 - 14,
        "thin: the point stops at the corner inset rather than reaching the row's centre")
    check(p.beam.core._start.y < ROW.y, "thin: ...which is a little below it")
    check(p.beam.core._end.y >= ROW.y - 10 and p.beam.core._end.y <= ROW.y + 10,
        "thin: and the beam still lands ON the row")
    p:Close()
end

CreateFrame, C_Timer = prevCreateFrame, prevTimer
