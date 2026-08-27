local addonName, NS = ...

-- ============================================================
-- LIBRARY OBJECT
-- The public API lives on the LibStub object; internals live on NS.
-- ============================================================
-- MINOR 2 adds Lib:RefreshMovedTargets (see MOVED-TARGET SWEEP below).
local MAJOR, MINOR = "DandersMover-1.0", 2
local Lib = LibStub:NewLibrary(MAJOR, MINOR)
if not Lib then return end
NS.Lib = Lib
Lib.callbacks = Lib.callbacks or LibStub("CallbackHandler-1.0"):New(Lib)
NS.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata(addonName, "Version")) or "dev"

local L = NS.L

-- The shared UI toolkit. A hard dependency (RequiredDeps in the TOC), so this
-- cannot be nil: LibStub itself would have failed to load first.
NS.UI = LibStub("DandersUI-1.0"):NewHost("DandersMover", {
    L     = L,
    print = function(msg) NS:Print(msg) end,
})
NS.UI:SetAccent(0.18, 0.612, 0.792)   -- the mover's own blue, from the old Theme.C.accent

local Registry, Solver = NS.Registry, NS.Solver
local pairs, ipairs, type, pcall, xpcall, geterrorhandler = pairs, ipairs, type, pcall, xpcall, geterrorhandler
local InCombatLockdown, CreateFrame, UIParent = InCombatLockdown, CreateFrame, UIParent
local tinsert, wipe, strsplit, strlower = table.insert, wipe, strsplit, string.lower
local abs = math.abs

function NS:Print(msg) print("|cff2e9cc9DandersMover:|r " .. tostring(msg)) end
function NS:Debug(msg) if NS.db and NS.db.debug then print("|cff888888DandersMover:|r " .. tostring(msg)) end end

-- ============================================================
-- SAVED VARIABLES
-- Only editor preferences and enable toggles live here. Never positions
-- (except the demo consumer's, under .demo).
-- ============================================================
NS.DEFAULTS = {
    gridSize = 20, snapToGrid = true, snapToFrames = true, snapToScreen = true, showGrid = true,
    -- How close (screen units, edge to edge) a dragged element has to get before a
    -- snap zone claims it. Fixed, not a fraction of the element: the same distance
    -- for a raid container and for a single icon. Also the zone-highlight radius.
    snapDistance = 25, zoneShowDistance = 50,
    -- Both OFF by default: the measure lines and the snap-preview crosshairs
    -- are diagnostics for someone lining a frame up to the pixel, and having
    -- them fire on every drag frame made the screen busier than the thing
    -- being dragged.
    showMeasures = false, showSnapPreview = false,
    keyboardNudge = true, panelSide = "auto", showHiddenMovers = true, showOtherAddons = false, debug = false,
    -- Interacting with a mover's side panel pins it in place automatically; off = only the pin button pins.
    autoPinPanels = true,
    stripCollapsed = false,               -- top strip folded to its slim tab
    addons = {}, demo = {},
}

local function applyDefaults(db, defaults)
    for k, v in pairs(defaults) do
        if db[k] == nil then
            if type(v) == "table" then db[k] = {} ; applyDefaults(db[k], v) else db[k] = v end
        end
    end
end

-- ============================================================
-- RECORD HELPERS
-- ============================================================
function NS.CopyPos(src, dst)
    dst = dst or {}
    wipe(dst)
    dst.point, dst.x, dst.y = src.point, src.x, src.y
    if src.anchor then
        dst.anchor = { target = src.anchor.target, mode = src.anchor.mode,
                       edge = src.anchor.edge, align = src.anchor.align,
                       point = src.anchor.point, relPoint = src.anchor.relPoint,
                       offsetX = src.anchor.offsetX, offsetY = src.anchor.offsetY }
        local fb = src.anchor.fallback
        if fb then
            dst.anchor.fallback = { target = fb.target, mode = fb.mode,
                                    edge = fb.edge, align = fb.align,
                                    point = fb.point, relPoint = fb.relPoint,
                                    offsetX = fb.offsetX, offsetY = fb.offsetY }
        end
    end
    return dst
end

-- ============================================================
-- NOTIFY (combat-aware)
-- ============================================================
NS.pending = {}

function NS:Notify(el, reason)
    if el.secure and InCombatLockdown() then
        NS.pending[el.id] = reason
        return false
    end
    local pos = Registry:GetPos(el)
    xpcall(el.onChanged, geterrorhandler(), pos, reason)
    Lib.callbacks:Fire("PositionChanged", el.addon, el.key, pos, reason)
    return true
end

function NS:FlushPending()
    if InCombatLockdown() then return end
    local ids = {}
    for id in pairs(NS.pending) do tinsert(ids, id) end
    wipe(NS.pending)
    for _, id in ipairs(ids) do
        local el = Registry:Get(id)
        if el then
            NS:ResolveElement(el)
            NS:Notify(el, "reapply")
            NS:ReapplyDescendants(el.id, "parent")
        end
    end
end

-- ============================================================
-- RESOLUTION
-- ============================================================
function NS:ParentOf(id) return Registry:ParentId(id) end

-- Re-solves an anchored element's absolute x/y from its target's current rect.
-- Returns true when x/y changed. Missing/zero-size target: hold (no change).
function NS:ResolveElement(el)
    local pos = Registry:GetPos(el)
    if not pos.anchor then return false end
    -- Primary, backup, or neither. Neither means every anchor this record names
    -- is unavailable (hidden, or a getRect that reports nothing on screen), so
    -- hold the last solved position rather than snapping to a stale rect.
    local a = Registry:ActiveAnchor(el)
    if not a then return false end
    local target = Registry:GetTarget(a.target)
    if not target then return false end
    local rect = Registry:GetRect(target)
    local w, h = Registry:GetSize(el)
    if not rect or not w then return false end
    local cx, cy = Solver.Resolve(a, w, h, rect, Solver.SPACING)
    if not cx then return false end
    local changed = pos.point ~= "CENTER" or pos.x ~= cx or pos.y ~= cy
    pos.point, pos.x, pos.y = "CENTER", cx, cy
    return changed
end

-- The body of ReapplyDescendantsMany, split out so the canon memo around it can be
-- closed on an error path as well as the normal one.
local function reapplyMany(targetIds, reason)
    local ids, seen = {}, {}
    for _, targetId in ipairs(targetIds) do
        for _, el in ipairs(Registry:Descendants(targetId)) do
            if not seen[el.id] then
                seen[el.id] = true
                tinsert(ids, el.id)
            end
        end
    end
    if #ids == 0 then return end
    local order = Solver.ResolutionOrder(ids, function(id) return NS:ParentOf(id) end)
    for _, id in ipairs(order) do
        local el = Registry:Get(id)
        if el and NS:ResolveElement(el) then NS:Notify(el, reason or "parent") end
    end
    -- EVERY descendant's slab re-measures, not just the ones whose record moved.
    -- A proxy is exactly as big as the frame it stands in for, and an anchored
    -- element can change SIZE without its solved centre changing at all (a
    -- centre-on-centre seat, or a growth the offsets absorb) -- so "did the
    -- record move" is the wrong question to gate the visual on. One pass, one
    -- repaint at the end; ids with no proxy are skipped.
    if NS.Proxy then NS.Proxy:SyncMany(order) end
end

-- Several targets moved at once (a header re-layout that shifts every sub-target):
-- one union descendant set, ONE resolution order over it, one resolve/notify pass,
-- so a shared descendant is solved once rather than once per target.
function NS:ReapplyDescendantsMany(targetIds, reason)
    -- The memo is only valid for the length of this synchronous pass, so it has to
    -- be closed however the pass ends. Errors are reported through the usual handler
    -- rather than swallowed.
    Registry:BeginCanonMemo()
    local ok, err = pcall(reapplyMany, targetIds, reason)
    Registry:EndCanonMemo()
    if not ok then geterrorhandler()(err) end
end

function NS:ReapplyDescendants(targetId, reason)
    NS:ReapplyDescendantsMany({ targetId }, reason)
end

-- ============================================================
-- MOVED-TARGET SWEEP
-- ============================================================
-- "Some of my targets may have RESIZED -- re-solve whatever depends on them."
--
-- RefreshAnchorTarget is the call for a target that MOVED, and a consumer knows
-- when that happened: it just ran the function that moved it. A target that
-- changed SIZE announces nothing -- the consumer's own layout code has no idea an
-- anchor exists -- so a child snapped to a container's right edge kept the
-- absolute x/y it was solved to back when the container was a different width.
-- That is what this sweep is for: the consumer names the keys a layout pass can
-- resize and calls it on its own layout tick, and the LIB works out whether
-- anything actually needs re-solving.
--
-- Cheap enough to call every rendered frame: it measures the named targets and
-- returns having done nothing unless one of them really moved.
--
-- ☠ THE EPSILON IS LOAD-BEARING. A rect is recomputed from live frame geometry
-- every time it is asked for, so exact equality lets sub-pixel jitter (a scale
-- ratio, a fractional container size) report "moved" forever, and every report
-- re-solves and re-notifies the whole subtree. Half a pixel is below anything a
-- user can see and above anything the maths can wobble by.
local RECT_EPSILON = 0.5

-- id -> the rect this sweep last solved that target against. Cleared on
-- Unregister so a churning key list (a consumer re-registering its elements)
-- cannot grow it without bound.
NS.lastRect = {}

-- Availability AND geometry in ONE measure. Registry:IsTargetAvailable would
-- call the consumer's getRect a second time, and this runs over every key on
-- every tick. nil = not a usable anchor target right now, which is a state of
-- its own: nil <-> rect counts as a move, because a child holding against a
-- vanished target has to re-solve the moment it comes back.
local function targetRect(target)
    if not Registry:IsRelevant(target) then return nil end
    if target.getRect then return target.getRect() end
    local f = Registry:GetFrame(target)
    if not f or not f:IsShown() then return nil end
    return Registry:GetRect(target)
end

local function movedSince(id, r)
    local prev = NS.lastRect[id]
    if r == nil then return prev ~= nil end
    if prev == nil then return true end
    return abs(prev.x - r.x) > RECT_EPSILON or abs(prev.y - r.y) > RECT_EPSILON
        or abs(prev.w - r.w) > RECT_EPSILON or abs(prev.h - r.h) > RECT_EPSILON
end

local function stampRect(id, r)
    if r == nil then NS.lastRect[id] = nil return end
    local prev = NS.lastRect[id]
    if prev then prev.x, prev.y, prev.w, prev.h = r.x, r.y, r.w, r.h
    else NS.lastRect[id] = { x = r.x, y = r.y, w = r.w, h = r.h } end
end

-- Reused across sweeps: the ids that moved this pass. Safe to reuse because the
-- sweep is re-entrancy guarded (below) and ReapplyDescendantsMany copies what it
-- needs out of it before calling anything back into the consumer.
local movedIds = {}

-- An open panel is docked to a slab and quotes the record the sweep just
-- re-solved, so it has to come along when either changes. Three states where it
-- must NOT: no live session (there is nothing on screen), a combat suspend (the
-- panels are deliberately hidden and Panel:Refresh re-shows pinned ones), and a
-- drag in flight (onDragStart hides the FOLLOWING panel on purpose, and a
-- refresh would plant it straight back under the cursor).
local function refreshSessionPanel()
    if not (NS.Panel and NS.Session) then return end
    if not NS.Session:IsActive() or NS.Session:IsSuspended() then return end
    if NS.Proxy and NS.Proxy:IsDragging() then return end
    NS.Panel:Refresh()
end

local function sweepMoved(addon, keys)
    local n = 0
    for _, key in ipairs(keys) do
        local target = Registry:GetTarget(Registry.Id(addon, key))
        if target and movedSince(target.id, targetRect(target)) then
            n = n + 1
            movedIds[n] = target.id
        end
    end
    for i = n + 1, #movedIds do movedIds[i] = nil end
    if n == 0 then return 0 end

    -- A moved target that is ALSO a movable element and is itself anchored has
    -- just had its own SIZE change, and Solver.Resolve takes the child's w/h --
    -- so its own solved position is stale too. It has to settle BEFORE the
    -- descendant pass, or the children solve against a rect their parent is
    -- about to leave. ResolveElement returns false when the solve did not
    -- actually move it, so an unanchored (or already-correct) element notifies
    -- nothing: that is the other half of "no churn".
    --
    -- ⚠ THE REASONS ARE THE EXISTING ONES ON PURPOSE: "reapply" for the element
    -- itself (what Lib:Apply sends) and "parent" for the descendants (what
    -- RefreshAnchorTarget sends). Both mean "the lib re-solved you", which is
    -- exactly what happened, and consumers already branch on that -- DandersFrames'
    -- pinned sets treat any OTHER reason as a user gesture and void a pending
    -- migration fold on it. A new reason string here would have been a silent
    -- behaviour change in someone else's file.
    for i = 1, n do
        local el = Registry:Get(movedIds[i])
        if el and NS:ResolveElement(el) then
            NS:Notify(el, "reapply")
        end
    end
    NS:ReapplyDescendantsMany(movedIds, "parent")

    -- ☠ THE SLAB HAS TO RE-MEASURE EVEN WHEN THE RECORD DID NOT CHANGE, so this
    -- is deliberately NOT inside the ResolveElement branch above. A proxy is
    -- exactly as big as the frame it stands in for, and a FREE element that got
    -- wider has no anchor to re-solve: ResolveElement returns false for it, and
    -- the old code read that as "nothing to show". So with the movers unlocked,
    -- pulling Frame Width grew the real frames while their slab kept the size it
    -- was built at. Reported in game as "when unlocked and changing a frame
    -- size, the mover does not update its size".
    --
    -- Descendants are already synced by the pass above (reapplyMany); this is
    -- the swept targets themselves. Ids with no proxy -- a pure anchor target,
    -- an element outside the session filter, no session open at all -- are
    -- skipped inside SyncMany.
    if NS.Proxy then NS.Proxy:SyncMany(movedIds) end
    refreshSessionPanel()

    -- ☠ RE-STAMP EVERY KEY, FROM A FRESH MEASURE -- not just the ones that read
    -- as moved at the top. The pass itself moves things: the self-resolve above,
    -- every descendant it re-solved, and whatever the consumer's onChanged did
    -- with the position it was handed. Anything measured before that ran is now
    -- out of date, and stamping only the movers left each re-solved DESCENDANT
    -- looking changed on the next tick -- one redundant pass every tick forever,
    -- and a chain of anchors settling one link per tick instead of all at once.
    --
    -- The flip side, deliberate: a consumer that resizes one of these targets
    -- from inside its own onChanged has that change absorbed here rather than
    -- reported next tick. It is the same statement either way -- "this is the
    -- state we have now seen" -- and the alternative is a sweep that can never
    -- go quiet.
    for _, key in ipairs(keys) do
        local target = Registry:GetTarget(Registry.Id(addon, key))
        if target then stampRect(target.id, targetRect(target)) end
    end
    return n
end

-- ============================================================
-- PUBLIC API
-- ============================================================
-- Every registry mutation announces itself, so the settings list and a live
-- session can re-render instead of showing whatever the registry looked like
-- when they were last opened. (addon, key) name what changed; BOTH nil means
-- "assume everything" -- that is the post-Flush case, where a whole login's
-- worth of queued registrations landed at once.
-- Consumers churn these in bursts (DandersFrames re-registers its entire pinned
-- list on every add/remove), so listeners debounce rather than the fire site:
-- a listener that wants to act once per burst can, one that wants each change
-- still sees each one.
local function registryChanged(addon, key)
    Lib.callbacks:Fire("RegistryChanged", addon, key)
end

function Lib:RegisterAddon(name, info)
    Registry:RegisterAddon(name, info)
    registryChanged(name)
end
function Lib:Register(addon, key, def)
    local el = Registry:Register(addon, key, def)
    registryChanged(addon, key)
    return el
end
function Lib:RegisterAnchorTarget(addon, key, def)
    local target = Registry:RegisterAnchorTarget(addon, key, def)
    registryChanged(addon, key)
    return target
end
function Lib:Unregister(addon, key)
    local id = Registry.Id(addon, key)
    Registry:Unregister(addon, key)
    NS.lastRect[id] = nil
    if NS.Proxy then NS.Proxy:Remove(id) end
    registryChanged(addon, key)
end
function Lib:UnregisterAddon(addon)
    Registry:UnregisterAddon(addon)
    local prefix = addon .. ":"
    for id in pairs(NS.lastRect) do
        if id:sub(1, #prefix) == prefix then NS.lastRect[id] = nil end
    end
    if NS.Proxy then NS.Proxy:RemoveAddon(addon) end
    registryChanged(addon)
end

-- Renames an element's key in place: the user toggle, the registry entry and every
-- registered or queued record's anchor target move with it; the position does not.
-- Ignored while unlocked -- a live session is keyed by the ids it opened with.
function Lib:RenameKey(addon, old, new)
    if Lib:IsUnlocked() then
        NS:Debug("RenameKey ignored while unlocked: " .. tostring(old))
        return false
    end
    local ok = Registry:RenameKey(addon, old, new)
    if ok then registryChanged(addon) end
    return ok
end

function Lib:RefreshAnchorTarget(addon, key)
    NS:ReapplyDescendants(Registry.Id(addon, key), "parent")
end

-- Batched RefreshAnchorTarget -- one union descendant set, one resolution order, one pass.
function Lib:RefreshAnchorTargets(addon, keys)
    local ids = {}
    for _, key in ipairs(keys) do tinsert(ids, Registry.Id(addon, key)) end
    NS:ReapplyDescendantsMany(ids, "parent")
end

-- "These targets of mine may have resized." Measures each key, and re-solves the
-- moved ones plus everything anchored to them. Returns how many actually moved,
-- so a caller can log or skip follow-up work; 0 means the call did nothing.
--
-- Meant to be called on the consumer's LAYOUT tick (after a settings sweep has
-- re-sized its frames), which is why it is guarded to a no-op rather than a
-- nested pass: a re-solve notifies the consumer, whose apply path can land right
-- back here through whatever drives its layout. The guard is what makes that a
-- stop rather than a loop; the epsilon in the sweep is what makes it converge.
--
-- `keys` is read twice -- once to find what moved, once to re-stamp -- so it must
-- stay valid for the whole call. A reused scratch table is fine (and is what
-- DandersFrames hands in); rebuilding it from a consumer callback is not.
local sweeping = false

function Lib:RefreshMovedTargets(addon, keys)
    if sweeping then return 0 end
    sweeping = true
    local ok, res = pcall(sweepMoved, addon, keys)
    sweeping = false
    if not ok then geterrorhandler()(res) return 0 end
    return res
end

function Lib:Apply(addon, key)
    local el = Registry:Get(Registry.Id(addon, key))
    if not el then return end
    NS:ResolveElement(el)
    NS:Notify(el, "reapply")
    NS:ReapplyDescendants(el.id, "parent")
    if NS.Proxy then NS.Proxy:Refresh(el.id) end
end

-- filter: nil (everything), "Addon" (that addon initiated the session), or
-- { addon = "Addon", keys = {...} } (only those keys of the initiator take part, forced
-- relevant). Other addons' enabled+relevant elements stay anchor targets in a filtered
-- session and get proxies with DandersMoverDB.showOtherAddons. See Registry:NormalizeFilter.
function Lib:Unlock(filter) if NS.Session then NS.Session:Unlock(filter) end end
function Lib:Lock() if NS.Session then NS.Session:Lock() end end
function Lib:Toggle() if NS.Session then NS.Session:Toggle() end end
function Lib:IsUnlocked() return NS.Session and NS.Session:IsActive() or false end
function Lib:IsEnabled(addon, key) return Registry:IsEnabled(addon, key) end

-- SetPoint + scale maths for consumers that want it. Safe to call without the
-- anchor block: only point/x/y are read.
function Lib.ApplyPosition(frame, pos)
    local ratio = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    frame:ClearAllPoints()
    frame:SetPoint(pos.point or "CENTER", UIParent, "CENTER", (pos.x or 0) / ratio, (pos.y or 0) / ratio)
end

-- ============================================================
-- EVENTS
-- ============================================================
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then return end
        DandersMoverDB = DandersMoverDB or {}
        applyDefaults(DandersMoverDB, NS.DEFAULTS)
        NS.db = DandersMoverDB
        Registry:Flush()
        -- One fire for the whole drained queue, not one per queued item.
        registryChanged()
        events:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_REGEN_DISABLED" then
        if NS.Session and NS.Session:IsActive() then NS.Session:Suspend() end
    elseif event == "PLAYER_REGEN_ENABLED" then
        NS:FlushPending()
        if NS.Session and NS.Session:IsSuspended() then NS.Session:Resume() end
    end
end)

-- ============================================================
-- SLASH
-- ============================================================
SLASH_DANDERSMOVER1 = "/mover"
SlashCmdList.DANDERSMOVER = function(msg)
    local cmd, rest = strsplit(" ", strlower(msg or ""), 2)
    if cmd == "" then
        Lib:Toggle()
    elseif cmd == "unlock" then Lib:Unlock()
    elseif cmd == "lock" then Lib:Lock()
    elseif cmd == "config" then if NS.Settings then NS.Settings:Toggle() end
    elseif cmd == "demo" then if NS.Demo then NS.Demo:Command(rest) end
    elseif cmd == "debug" then NS.db.debug = not NS.db.debug; NS:Print("debug " .. tostring(NS.db.debug))
    else
        NS:Print(L["Usage: /mover [unlock|lock|config|demo]"])
    end
end

-- Addon table exposed for /run diagnostics and the manual checklist.
_G.DandersMover = NS
