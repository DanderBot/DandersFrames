local addonName, NS = ...
local UI = NS.__DandersUI
if not UI then return end

-- ============================================================
-- POPOUT
-- A small panel that DOCKS BESIDE A THING: it picks the side that fits, follows
-- the thing while it moves, and can be pinned loose -- at which point a tether
-- beam keeps saying which thing it belongs to.
--
-- Host-bound, like every factory here: `host:CreatePopout(opts)`. The shell
-- knows nothing about what it contains or what closing it MEANS -- the consumer
-- mounts widgets in `build` and decides in `onClose`. Nothing in this file may
-- name a consumer, and it owns no saved state of its own.
--
-- POOLING. Per host+key there is ONE unpinned popout. Asking for a key that
-- already has one hands the same object back, re-targeted, WITHOUT re-running
-- build -- so a popout that opens on every selection costs one frame, not one
-- per selection. Pin() promotes an instance out of the pool (it keeps the
-- content it was built with) and the next request for that key builds a fresh
-- one. `build` is therefore re-runnable by construction: per-instance state
-- belongs on the popout object, never in a file-scope local.
--
-- ⚠ A popout is built HIDDEN. Placement is what presents it -- Follow(region)
-- or PlaceFree(x, y) -- because the entrance pops out of the edge it docks
-- against, and that edge is not known until it has something to dock to.
-- ============================================================
local CreateFrame, UIParent, C_Timer = CreateFrame, UIParent, C_Timer
local setmetatable, rawget, rawset, type, error = setmetatable, rawget, rawset, type, error
local ipairs, pairs, xpcall, geterrorhandler = ipairs, pairs, xpcall, geterrorhandler
local tinsert, tremove = table.insert, table.remove
local min, max, abs = math.min, math.max, math.abs

local Fx = UI.Fx

local PAD        = 10        -- outer inset around the content
local TITLE_H    = 22        -- the title bar strip
local DOCK_GAP   = 12        -- popout <-> source distance when docked
local ADJ_GAP    = 16        -- "still beside it": beyond this the beam appears
local POP_DUR    = 0.22      -- entrance
local OUT_DUR    = 0.18      -- exit, the entrance run backwards
local PIN_DUR    = 0.12      -- the little confirm pop when pinning by hand
local BEAM_DUR   = 0.15      -- beam fade in / out
local CLOSE_SIZE = 18
local PIN_SIZE   = 14
local ICON_SIZE  = 14
-- Two layered lines, not one: a wide soft under-glow so the beam reads over
-- busy art, and a thin bright core so it still reads as a LINE.
local BEAM_GLOW_W, BEAM_GLOW_A = 5, 0.15
local BEAM_CORE_W, BEAM_CORE_A = 3, 0.55

-- ============================================================
-- PURE GEOMETRY
-- Deliberately free of frames and of host state so the docking and beam rules
-- can be tested head-on rather than inferred from where a frame ended up.
-- Rects are CENTRE-BASED and in UIParent-centre units: { x, y, w, h }.
-- ============================================================

-- Candidate positions beside a source rect, in tie-break priority order.
-- right/left hang from the source's TOP edge (a popout reads as a continuation
-- of the thing's header); above/below centre on it.
local function dockCandidates(src, w, h, gap)
    local top = src.y + src.h / 2
    return {
        { side = "right", x = src.x + src.w / 2 + gap + w / 2, y = top - h / 2 },
        { side = "left",  x = src.x - src.w / 2 - gap - w / 2, y = top - h / 2 },
        { side = "below", x = src.x, y = src.y - src.h / 2 - gap - h / 2 },
        { side = "above", x = src.x, y = src.y + src.h / 2 + gap + h / 2 },
    }
end

-- The side to dock on: the first candidate that fits FULLY on screen, in
-- priority order. Obstacle awareness is deliberately not modelled -- the shell
-- has no idea what else is on screen, and a consumer that does can force a side
-- through Follow's opts. nil when nothing fits; the caller flips on the screen
-- edge instead.
--
-- Exposed on the library (not on a host) because it is a pure function of its
-- arguments and both the popout and its tests want it.
function UI.PopoutPickSide(src, w, h, gap, screenW, screenH)
    local halfW, halfH = screenW / 2, screenH / 2
    for _, c in ipairs(dockCandidates(src, w, h, gap or DOCK_GAP)) do
        if c.x - w / 2 >= -halfW and c.x + w / 2 <= halfW
        and c.y - h / 2 >= -halfH and c.y + h / 2 <= halfH then
            return c.side
        end
    end
    return nil
end

-- "Still beside it": the two rects are within `gap` of touching on BOTH axes.
-- A docked popout sits DOCK_GAP from its source and overlaps it on the other
-- axis, so it passes; drag it away and it stops passing, which is exactly when
-- the beam has something to say.
function UI.PopoutIsAdjacent(a, b, gap)
    if not a or not b then return false end
    gap = gap or ADJ_GAP
    local dx = max(abs(a.x - b.x) - (a.w + b.w) / 2, 0)
    local dy = max(abs(a.y - b.y) - (a.h + b.h) / 2, 0)
    return dx <= gap and dy <= gap
end

-- The midpoints of a rect's four edges, in the order top, bottom, left, right.
local function edgeMids(r)
    return {
        { r.x, r.y + r.h / 2 }, { r.x, r.y - r.h / 2 },
        { r.x - r.w / 2, r.y }, { r.x + r.w / 2, r.y },
    }
end

-- The closest pair of edge midpoints between two rects. The beam wants to leave
-- and arrive at the faces that are actually looking at each other; centre-to-
-- centre would draw a line straight through both boxes.
local function nearestEdgePair(a, b)
    local bestD, ax, ay, bx, by
    for _, p in ipairs(edgeMids(a)) do
        for _, q in ipairs(edgeMids(b)) do
            local d = (p[1] - q[1]) ^ 2 + (p[2] - q[2]) ^ 2
            if not bestD or d < bestD then bestD, ax, ay, bx, by = d, p[1], p[2], q[1], q[2] end
        end
    end
    return ax, ay, bx, by
end

-- Rect of a region in UIParent-centre units; nil while it has no geometry yet.
local function rectOf(region)
    if not region or not region.GetCenter then return nil end
    local cx, cy = region:GetCenter()
    if not cx then return nil end
    local ux, uy = UIParent:GetCenter()
    return { x = cx - ux, y = cy - uy, w = region:GetWidth() or 0, h = region:GetHeight() or 0 }
end

-- The entrance drift and scale origin for a dock side: the popout pops out of
-- (and back into) the edge it is docked against. Shared by the entrance and the
-- exit so closing is the opening run backwards.
local function dockFx(side)
    if side == "right" then return -8, 0, "LEFT"
    elseif side == "left" then return 8, 0, "RIGHT"
    elseif side == "below" then return 0, 8, "TOP"
    elseif side == "above" then return 0, -8, "BOTTOM" end
    return 0, 0, "CENTER"
end

-- C_Timer with a synchronous fallback. Headless (and any client without the
-- timer API) still gets the SEQUENCE right -- beam out, then pop out -- it just
-- gets it all in one frame.
local function after(delay, fn)
    if C_Timer and C_Timer.After then return C_Timer.After(delay, fn) end
    fn()
end

local function safeCall(fn, ...)
    if type(fn) ~= "function" then return end
    local a, b = ...
    xpcall(function() return fn(a, b) end, geterrorhandler())
end

-- ============================================================
-- PER-HOST STORE
-- The pool and the family registry are HOST state, not library state: two
-- consumers may both use the key "aura" and must not collide. rawget/rawset,
-- because a host's __index is the library and a plain read would find the
-- library's field (or another host's) instead of the host's own.
-- ============================================================
local function storeFor(host)
    local s = rawget(host, "_popouts")
    if not s then
        s = { pooled = {}, live = {} }
        rawset(host, "_popouts", s)
    end
    return s
end

-- ============================================================
-- THE POPOUT OBJECT
-- ============================================================
local Popout = {}
local popoutMeta = { __index = Popout }

-- ---- placement ---------------------------------------------------

-- Dock beside `region`. opts.side forces a side ("left"/"right"/"above"/
-- "below"); without it the side is picked by what fits. Re-docks for free
-- whenever the region moves -- see _Tick.
function Popout:Follow(region, opts)
    if not region then return end
    self.source = region
    self.forcedSide = opts and opts.side or nil
    self.free = false
    -- A pinned popout has been taken off its leash by hand; re-pointing its
    -- SOURCE (so the beam knows where to land) must not drag it back to it.
    if self.pinned then
        self:_UpdateBeam()
        return self
    end
    self.following = true
    self:_Dock()
    return self
end

-- Absolute placement, for consumers that own their own layout. No source, so
-- nothing to follow and nothing to tether to.
function Popout:PlaceFree(x, y)
    self.free = true
    self.following = false
    local f = self.frame
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", x or 0, y or 0)
    self:_Present("CENTER")
    return self
end

function Popout:_Dock()
    local f, src = self.frame, self.source
    local sr = rectOf(src)
    if not sr then return end
    -- The ticker's baseline is taken HERE, not on the first tick: without it the
    -- very next frame would read "the source moved" and re-dock for nothing.
    self._srcX, self._srcY, self._srcW, self._srcH = sr.x, sr.y, sr.w, sr.h
    local side = self.forcedSide
    if not side then
        side = UI.PopoutPickSide(sr, f:GetWidth() or 0, f:GetHeight() or 0, DOCK_GAP,
                                 UIParent:GetWidth() or 0, UIParent:GetHeight() or 0)
        -- Nothing fits: flip onto whichever side of the screen has more room,
        -- and let SetClampedToScreen deal with the overhang.
        if not side then side = (sr.x > 0) and "left" or "right" end
    end
    f:ClearAllPoints()
    if side == "left" then f:SetPoint("TOPRIGHT", src, "TOPLEFT", -DOCK_GAP, 0)
    elseif side == "below" then f:SetPoint("TOP", src, "BOTTOM", 0, -DOCK_GAP)
    elseif side == "above" then f:SetPoint("BOTTOM", src, "TOP", 0, DOCK_GAP)
    else f:SetPoint("TOPLEFT", src, "TOPRIGHT", DOCK_GAP, 0) end
    self.side = side
    self:_Present(side)
end

-- Show it if it is not already up. The entrance is only ever played ONCE per
-- open: _Dock runs on every source move and a pop per move would be a strobe.
function Popout:_Present(side)
    local f = self.frame
    self:_Resize()
    if not f:IsShown() then
        local ox, oy, origin = dockFx(side)
        if Fx then Fx.PopIn(f, POP_DUR, ox, oy, 0.92, origin) end
        f:Show()
        self._popDur = POP_DUR      -- the beam waits this long before fading in
    end
    self:_StartTick()
    self:_UpdateBeam()
end

-- Height follows the content the consumer mounted; width was fixed at build.
function Popout:_Resize()
    local h = self.content:GetHeight() or 0
    self.frame:SetHeight(TITLE_H + PAD + h + PAD)
    return self
end
Popout.Resize = Popout._Resize      -- public: call after changing content height

-- ---- the follow / beam ticker ------------------------------------

-- ONE OnUpdate drives everything that has to react to movement: the re-dock
-- when the source moves, the source-death close, and the live beam (which also
-- has to keep up during a title-bar drag, when nothing else fires).
--
-- It early-outs the moment nothing has moved, which is the overwhelmingly
-- common case, and it is a plain script so a headless test can drive one tick
-- by hand: popout.frame:GetScript("OnUpdate")(popout.frame).
local function onUpdate(frame)
    local po = frame._popout
    if po then po:_Tick() end
end

function Popout:_StartTick()
    self.frame:SetScript("OnUpdate", onUpdate)
end

function Popout:_StopTick()
    self.frame:SetScript("OnUpdate", nil)
end

function Popout:_Tick()
    if self.closed then return end
    local f = self.frame
    if not f:IsShown() then return end

    -- Source death. Only meaningful for a popout that CANNOT be pinned: a
    -- pinnable one may legitimately outlive what it was opened from, and
    -- deciding what that means is the consumer's call, not the shell's.
    if not self.pinnable and self.source and not self:_SourceAlive() then
        self:Close("source")
        return
    end

    local sr = rectOf(self.source)
    local moved = sr and (sr.x ~= self._srcX or sr.y ~= self._srcY
                          or sr.w ~= self._srcW or sr.h ~= self._srcH)
    if moved then self._srcX, self._srcY, self._srcW, self._srcH = sr.x, sr.y, sr.w, sr.h end

    if moved and self.following then self:_Dock() end
    -- The beam is redrawn on a source move OR while the popout itself is being
    -- dragged; both ends can move independently.
    if moved or self.dragging then self:_UpdateBeam() end
end

function Popout:_SourceAlive()
    local src = self.source
    if not src then return false end
    if src.IsShown and not src:IsShown() then return false end
    return true
end

-- ---- the tether beam ---------------------------------------------

-- The far end of the beam: an explicit tetherSource when the consumer gave one
-- (the thing the popout is ABOUT may not be the thing it docked to), otherwise
-- whatever it is following.
function Popout:_TetherRegion()
    local t = self.tetherSource
    if type(t) == "function" then t = t(self) end
    return t or self.source
end

function Popout:_EnsureBeam()
    if self.beam then return self.beam end
    -- Its own frame, parented to UIParent so the lines may span the gap, and
    -- faded as a UNIT -- animating a Frame's alpha carries both its lines, which
    -- is the whole reason the beam is not two loose lines on the popout.
    local b = CreateFrame("Frame", nil, UIParent)
    b:SetAllPoints(UIParent)
    b:SetFrameStrata("BACKGROUND")
    b:Hide()
    -- Guarded exactly as the mover's tethers are: a headless stub (or a client
    -- without Line objects) leaves them false and every beam call no-ops.
    b.glow = b.CreateLine and b:CreateLine(nil, "ARTWORK", nil, -1) or false
    b.core = b.CreateLine and b:CreateLine(nil, "ARTWORK", nil, 0) or false
    self.beam = b
    return b
end

-- Draw / show / hide the beam for the current state. It exists only while the
-- popout is PINNED and has been moved off its source: docked, the two boxes are
-- touching and a line between them would be noise.
function Popout:_UpdateBeam()
    local want = self.pinned and not self.closed
    local target = want and self:_TetherRegion() or nil
    local tr = target and rectOf(target) or nil
    local pr = tr and rectOf(self.frame) or nil
    if tr and pr and UI.PopoutIsAdjacent(pr, tr, ADJ_GAP) then want = false end
    if not (want and tr and pr) then
        self:_HideBeam()
        return
    end

    local b = self:_EnsureBeam()
    local ax, ay, bx, by = nearestEdgePair(pr, tr)
    local c = self.host:GetAccent()
    for _, line in ipairs({ b.glow, b.core }) do
        if line then
            line:SetStartPoint("CENTER", UIParent, ax, ay)
            line:SetEndPoint("CENTER", UIParent, bx, by)
        end
    end
    if b.glow then
        b.glow:SetThickness(BEAM_GLOW_W)
        b.glow:SetColorTexture(c.r, c.g, c.b, BEAM_GLOW_A)
        b.glow:Show()
    end
    if b.core then
        b.core:SetThickness(BEAM_CORE_W)
        b.core:SetColorTexture(c.r, c.g, c.b, BEAM_CORE_A)
        b.core:Show()
    end
    if b:IsShown() then return end
    -- Fx sequencing: the beam lands AFTER the popout has finished popping in,
    -- so the two read as one gesture rather than as two things happening at
    -- once. _popDur is consumed, so only the first beam after an entrance waits.
    local wait = self._popDur
    self._popDur = nil
    local function reveal()
        if self.closed or not self.pinned then return end
        if Fx then Fx.FadeIn(b, BEAM_DUR) else b:Show() end
    end
    if wait then after(wait, reveal) else reveal() end
end

function Popout:_HideBeam()
    local b = self.beam
    if not b or not b:IsShown() then return end
    if Fx then Fx.FadeOut(b, BEAM_DUR, function() b:Hide() end) else b:Hide() end
end

-- ---- pinning -----------------------------------------------------

-- Take the popout off its leash: it stops following, becomes draggable by the
-- title bar, and from here on the only way out is the cross.
--
-- `silent` is AutoPin's path -- the confirm pop is feedback for a click, and
-- playing it for something the consumer decided would look like a glitch.
function Popout:Pin(silent)
    if self.pinned or not self.pinnable or self.closed then return self end
    self.pinned = true
    self.following = false

    -- Out of the pool: this instance keeps the content it was built with, and
    -- the next request for the key gets a fresh one.
    local store = storeFor(self.host)
    if store.pooled[self.key] == self then store.pooled[self.key] = nil end

    -- Re-anchor to the screen at the position it currently occupies. Left
    -- anchored to the source it would keep travelling with it, which is the one
    -- thing pinning is supposed to stop.
    local f = self.frame
    local pr = rectOf(f)
    if pr then
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", pr.x, pr.y)
    end

    -- Draggable ONLY now: a docked popout that could be dragged would fight the
    -- follow, so none of this is wired until pinning.
    f:SetMovable(true)
    local bar = self.titleBar
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function()
        f:StartMoving()
        self.dragging = true
    end)
    bar:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        self.dragging = false
        self:_UpdateBeam()
    end)

    -- v1 does not unpin, so the button would be a lie about what it does.
    if self.pinBtn then self.pinBtn:Hide() end

    if not silent and Fx then Fx.PopIn(f, PIN_DUR, 0, 0, 0.96, "CENTER") end
    self:_UpdateBeam()
    safeCall(self.onPin, self)
    return self
end

-- Pin without being asked: the consumer's own rule decided this popout has
-- earned staying. Gated on `canAutoPin`, which may be a value or a function
-- evaluated PER CALL -- the answer can change between two opens of the same key.
function Popout:AutoPin()
    if self.pinned or not self.pinnable or self.closed then return self end
    local gate = self.canAutoPin
    if type(gate) == "function" then
        if not gate(self) then return self end
    elseif gate ~= nil and not gate then
        return self
    end
    return self:Pin(true)
end

function Popout:IsPinned() return self.pinned == true end

-- ---- header ------------------------------------------------------

function Popout:SetHeader(title, icon)
    self.headerTitle, self.headerIcon = title, icon
    self.titleFS:SetText(title or "")
    if self.iconTex then
        self.iconTex:SetShown(icon ~= nil)
        if icon then self.iconTex:SetTexture(icon) end
    end
    return self
end

function Popout:GetTitle() return self.headerTitle end

-- ---- closing -----------------------------------------------------

-- reason: "cross" | "family" | "source" | "api". The shell never decides what
-- closing MEANS -- it reports why it happened and the consumer acts on it.
--
-- The exit is the entrance backwards, and the beam goes FIRST: a beam still
-- hanging in the air while its popout shrinks away reads as two events.
function Popout:Close(reason)
    if self.closed then return self end
    self.closed = true
    self.following = false
    self.dragging = false
    self:_StopTick()

    local store = storeFor(self.host)
    for i = #store.live, 1, -1 do
        if store.live[i] == self then tremove(store.live, i) end
    end
    -- A PINNED instance is discarded: it left the pool when it was pinned and
    -- its frame is not offered back. An unpinned one stays pooled and is
    -- revived by the next request for its key -- that is what the pool is for.

    local f = self.frame
    local ox, oy, origin = dockFx(self.side)
    local function popOut()
        if Fx then
            Fx.PopOut(f, OUT_DUR, ox, oy, 0.92, origin, function() f:Hide() end)
        else
            f:Hide()
        end
    end
    local b = self.beam
    if b and b:IsShown() then
        self:_HideBeam()
        after(BEAM_DUR, popOut)
    else
        popOut()
    end

    safeCall(self.onClose, self, reason or "api")
    return self
end

function Popout:IsShown() return self.frame:IsShown() end

-- ============================================================
-- FACTORY
-- ============================================================

-- Everything a re-used instance is allowed to change. build is NOT among them:
-- the content was mounted once and is what makes the pooled frame worth keeping.
local function adopt(po, opts)
    po.family      = opts.family
    po.onClose     = opts.onClose
    po.onPin       = opts.onPin
    po.onUnpin     = opts.onUnpin          -- accepted; v1 never unpins
    po.canAutoPin  = opts.canAutoPin
    po.tetherSource = opts.tetherSource
    -- Reserved. Accepted and ignored so the call sites that will want a header
    -- action row or a count badge can be written before the shell grows them.
    po.actions     = opts.actions
    po.badge       = opts.badge
    po:SetHeader(opts.title, opts.icon)
end

-- Opening a popout in a family closes every OTHER popout in that family --
-- pinned ones included, because a family is an exclusivity claim, not a
-- politeness. A nil family coexists with everything.
local function sweepFamily(host, po)
    if not po.family then return end
    local store = storeFor(host)
    for i = #store.live, 1, -1 do
        local other = store.live[i]
        if other ~= po and not other.closed and other.family == po.family then
            other:Close("family")
        end
    end
end

-- opts:
--   key           REQUIRED identity string. The pool is per host+key.
--   family        exclusivity group; opening one closes the rest of its family
--   pinnable      default true. false: no pin button, AutoPin no-ops, and the
--                 popout dies with its source
--   title / icon  title bar; changeable later with :SetHeader
--   parent        frame to parent to (default UIParent)
--   width         CONTENT width; the height follows what build mounted
--   build(popout, content)   called ONCE per instance
--   onClose(popout, reason)  reason: "cross"|"family"|"source"|"api"
--   onPin(popout) / onUnpin(popout)
--   canAutoPin    boolean or function(popout); false makes AutoPin a no-op
--   tetherSource  region or function -> region; the beam's far end
--   actions / badge          reserved, accepted and ignored
function UI:CreatePopout(opts)
    local host = self
    if type(opts) ~= "table" or type(opts.key) ~= "string" or opts.key == "" then
        error("DandersUI: CreatePopout needs opts.key", 2)
    end
    local L = host.hooks and host.hooks.L
    local store = storeFor(host)

    -- Pooled hit: same object, re-targeted, build untouched.
    local pooled = store.pooled[opts.key]
    if pooled then
        pooled.closed = false
        adopt(pooled, opts)
        local found = false
        for _, p in ipairs(store.live) do if p == pooled then found = true end end
        if not found then tinsert(store.live, pooled) end
        sweepFamily(host, pooled)
        return pooled
    end

    local po = setmetatable({
        host = host,
        key = opts.key,
        pinnable = opts.pinnable ~= false,
        width = opts.width or 220,
    }, popoutMeta)

    local f = CreateFrame("Frame", nil, opts.parent or UIParent, "BackdropTemplate")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetWidth(po.width + PAD * 2)
    f:EnableMouse(true)                       -- a panel must not leak clicks through
    f:Hide()
    f._popout = po                            -- the OnUpdate script's way back
    host:CreatePanelBackdrop(f)
    po.frame = f

    -- ---- title bar ------------------------------------------------
    -- Its own frame because it is the DRAG surface once pinned; mouse is only
    -- enabled on it at that point.
    local bar = CreateFrame("Frame", nil, f)
    bar:SetPoint("TOPLEFT", 0, 0)
    bar:SetPoint("TOPRIGHT", 0, 0)
    bar:SetHeight(TITLE_H)
    po.titleBar = bar

    local iconTex = f:CreateTexture(nil, "OVERLAY")
    iconTex:SetSize(ICON_SIZE, ICON_SIZE)
    iconTex:SetPoint("LEFT", bar, "LEFT", PAD, 0)
    iconTex:Hide()
    po.iconTex = iconTex

    po.closeBtn = host:CreateCloseButton(f, {
        size = CLOSE_SIZE,
        onClick = function() po:Close("cross") end,
    })
    po.closeBtn:SetPoint("RIGHT", bar, "RIGHT", -4, 0)

    if po.pinnable then
        po.pinBtn = host:CreateGlyphButton(f, {
            texture = UI.MEDIA .. "Icons\\pin",
            size = PIN_SIZE,
            tooltip = { title = L and L["Pin"] or "Pin" },
            onClick = function() po:Pin() end,
        })
        po.pinBtn:SetPoint("RIGHT", po.closeBtn, "LEFT", -2, 0)
    end

    -- The title takes whatever the buttons left. Anchored to the pin (or the
    -- cross when there is none) rather than to a measured width, so the two
    -- layouts need no arithmetic between them.
    po.titleFS = host:CreateLabel(f, { size = 11, color = UI.Colors and UI.Colors.text })
    po.titleFS:SetPoint("LEFT", iconTex, "RIGHT", 4, 0)
    po.titleFS:SetPoint("RIGHT", po.pinBtn or po.closeBtn, "LEFT", -4, 0)
    if po.titleFS.SetWordWrap then po.titleFS:SetWordWrap(false) end

    -- ---- content --------------------------------------------------
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", PAD, -TITLE_H)
    content:SetWidth(po.width)
    content:SetHeight(1)
    po.content = content

    adopt(po, opts)
    store.pooled[opts.key] = po
    tinsert(store.live, po)

    safeCall(opts.build, po, content)
    po:_Resize()
    sweepFamily(host, po)
    return po
end
