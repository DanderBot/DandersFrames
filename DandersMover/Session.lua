local addonName, NS = ...
-- A copy that lost the LibStub race (a renamed duplicate install) must go
-- fully inert: Core.lua only sets NS.Lib on the winning copy.
if not NS.Lib then return end

-- ============================================================
-- SESSION
-- The unlock lifecycle. Snapshots on enter, pending edits on the live records,
-- Save/Discard on exit, suspend/resume around combat, undo stack, keyboard.
-- ============================================================
local Sess = { active = false, suspended = false, snapshots = {}, dirty = false, selected = nil }
NS.Session = Sess

local Registry, Solver, Proxy, Grid, L = NS.Registry, NS.Solver, NS.Proxy, NS.Grid, NS.L
local Undo = LibStub("DandersUndo-1.0")
local Lib = NS.Lib
local pairs, ipairs, format, wipe, sqrt = pairs, ipairs, string.format, wipe, math.sqrt
local InCombatLockdown, UIParent, IsShiftKeyDown, IsControlKeyDown = InCombatLockdown, UIParent, IsShiftKeyDown, IsControlKeyDown
local C_Timer, debugprofilestop = C_Timer, debugprofilestop

local SCREEN_SNAP = 8
-- Only reached when the SV predate the setting; NS.DEFAULTS.snapDistance is the value.
local SNAP_DISTANCE = 25

local function panel(method) if NS.Panel then NS.Panel[method](NS.Panel) end end

-- PERF instrumentation (debug-gated, /mover debug). debugprofilestop() is
-- wall-clock ms since some epoch; deltas of it are the per-block cost. Kept
-- permanently: it is a handful of subtractions behind the debug flag, and the
-- unlock/lock hitch investigation needs real in-game numbers to stay honest.
local function perfStart()
    return NS.db and NS.db.debug and debugprofilestop and debugprofilestop() or nil
end
local function perfLog(t0, label)
    if t0 then NS:Debug(format("PERF %s %.1fms", label, debugprofilestop() - t0)) end
end

function Sess:IsActive() return self.active end
function Sess:IsSuspended() return self.suspended end

-- ============================================================
-- APPLY / COMMIT
-- ============================================================
-- Push the element's record to its consumer and everything anchored to it.
local function apply(el, reason)
    NS:Notify(el, reason)
    NS:ReapplyDescendants(el.id, "parent")
    Proxy:RefreshAll()
    panel("Refresh")
end

local function restore(el, snap, reason)
    NS.CopyPos(snap, Registry:GetPos(el))
    -- An anchored snapshot carries the x/y solved at commit time; re-solve
    -- against the target's current rect (holds if the target is missing).
    NS:ResolveElement(el)
    apply(el, reason)
end

local function commit(el, before, label)
    local after = NS.CopyPos(Registry:GetPos(el))
    Sess.dirty = true
    Sess.undo:Push({
        label = format(label, el.title),
        undo = function() restore(el, before, "undo") end,
        redo = function() restore(el, after, "redo") end,
    })
end

-- ============================================================
-- LIFECYCLE
-- ============================================================
function Sess:Unlock(filter)
    if self.active then return end
    if InCombatLockdown() then NS:Print(L["Movers cannot be unlocked in combat."]) return end
    filter = Registry:NormalizeFilter(filter)
    self.filter = filter
    -- Keys named in the filter take part even when their isRelevant() says no, and
    -- are forced relevant for the whole session (snap + be snapped to). Set BEFORE the
    -- snapshot walk and before Unlocked fires, so both see the same answer.
    wipe(NS.forcedRelevant)
    if filter and filter.keySet then
        for key in pairs(filter.keySet) do NS.forcedRelevant[Registry.Id(filter.addon, key)] = true end
    end
    -- Snapshot everything IN the session, proxied or not: other addons' elements can
    -- gain a proxy mid-session (showOtherAddons) and Discard must restore them too.
    wipe(self.snapshots)
    for _, el in ipairs(Registry:SortedElements()) do
        if Registry:IsInSession(filter, el) then
            self.snapshots[el.id] = NS.CopyPos(Registry:GetPos(el))
        end
    end
    self.undo = Undo:New({ limit = 100 })
    self.undo.RegisterCallback(self, "Changed", function() panel("Refresh") end)
    self.dirty = false
    self.selected = nil
    self.active = true
    self.suspended = false
    -- Fire before Build: consumers commonly show preview/test frames from this
    -- callback, and the proxies must be measured against what the consumer ends
    -- up showing, not what was on screen a moment earlier. Snapshots are taken
    -- above so the record is captured before any consumer-side mutation.
    local tTotal = perfStart()
    Lib.callbacks:Fire("Unlocked")
    perfLog(tTotal, "Unlocked callbacks")
    local tBuild = perfStart()
    Proxy:Build(filter, true)     -- animate: slabs fade in with a stagger
    perfLog(tBuild, "Proxy:Build")
    Grid:Refresh()
    self:EnableKeyboard(true)
    perfLog(tTotal, "Unlock total (callbacks+build+grid)")
    -- Anything the consumer only shows on the next frame (secure headers, test
    -- containers) has no rect yet at Build time; re-measure once it does.
    C_Timer.After(0, function()
        if Sess.active and not Sess.suspended then
            Proxy:RefreshAll()
            Grid:Refresh()
            if NS.Panel then NS.Panel:Refresh() end
        end
    end)
end

function Sess:Lock()
    if not self.active then return end
    if self.dirty then StaticPopup_Show("DANDERSMOVER_EXIT") else self:Finish("save") end
end

function Sess:Finish(mode)
    if not self.active then return end
    local tTotal = perfStart()
    if mode == "discard" then
        for id, snap in pairs(self.snapshots) do
            local el = Registry:Get(id)
            if el then NS.CopyPos(snap, Registry:GetPos(el)) end
        end
        for id in pairs(self.snapshots) do
            local el = Registry:Get(id)
            if el then NS:Notify(el, "discard") end
        end
    end
    self:EnableKeyboard(false)
    Proxy:DismissAll()            -- fade out, then destroy (combat suspend stays instant)
    Grid:Hide()
    panel("Hide")
    wipe(self.snapshots)
    wipe(NS.forcedRelevant)
    self.filter = nil
    self.active, self.suspended, self.dirty, self.selected = false, false, false, nil
    -- Clear after the state reset: Clear fires "Changed" -> panel Refresh,
    -- which must see the session as inactive so it cannot re-show the panel.
    if self.undo then self.undo:Clear() end
    local tLocked = perfStart()
    Lib.callbacks:Fire("Locked")
    perfLog(tLocked, "Locked callbacks")
    Lib.callbacks:Fire(mode == "discard" and "Discarded" or "Saved")
    perfLog(tTotal, "Finish total")
end

function Sess:Toggle() if self.active then self:Lock() else self:Unlock() end end

-- Tear the proxies down and build them again against the current filter: a toggle
-- changed what should be on screen (an addon/element switch, hidden movers, other
-- addons' movers). Settings and the legend checkbox both come through here.
function Sess:RebuildProxies()
    if not self.active or self.suspended then return end
    -- A rebuild can follow an element being unregistered mid-session. Proxy:Build
    -- will not make one for an id that no longer exists, but the selection would
    -- keep pointing at it -- and the panel docks to the selected proxy.
    if self.selected and not Registry:Get(self.selected) then self.selected = nil end
    Proxy:DestroyAll()
    Proxy:Build(self.filter)          -- also re-draws the legend
    Grid:Refresh()
    panel("Refresh")                  -- hides itself when the selection is gone
end

-- Elements can come and go WHILE a session is open: DandersFrames re-registers
-- its whole pinned list every time a set is added or removed, so without this a
-- proxy sits over a container that is not there any more (and a new set gets no
-- proxy until the next unlock). Debounced to the end of the frame because that
-- re-registration is a burst of unregister/register calls, not one change.
local rebuildPending = false
Lib.RegisterCallback(Sess, "RegistryChanged", function()
    if rebuildPending or not Sess.active or Sess.suspended then return end
    rebuildPending = true
    C_Timer.After(0, function()
        rebuildPending = false
        Sess:RebuildProxies()
    end)
end)

function Sess:Suspend()
    if not self.active or self.suspended then return end
    self.suspended = true
    Proxy:GetUnlockFrame():Hide()
    Grid:Hide()
    panel("Hide")
    NS:Print(L["Movers suspended for combat."])
end

function Sess:Resume()
    if not self.active or not self.suspended then return end
    self.suspended = false
    Proxy:GetUnlockFrame():Show()
    Proxy:RefreshAll()
    Grid:Refresh()
    panel("Refresh")
end

function Sess:Select(id)
    self.selected = id
    -- An explicit selection always docks immediately, nudge hold or not.
    if NS.Panel then NS.Panel:ClearHold() end
    Proxy:Highlight(id)
    panel("Refresh")
end

StaticPopupDialogs["DANDERSMOVER_EXIT"] = {
    text = L["You have unsaved mover changes."],
    button1 = L["Save"], button2 = L["Cancel"], button3 = L["Discard"],
    OnAccept = function() Sess:Finish("save") end,
    OnAlt = function() Sess:Finish("discard") end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- ============================================================
-- MUTATIONS (each = one undo step)
-- ============================================================
local function sizeOf(el)
    local w, h = Registry:GetSize(el)
    return w or 24, h or 24
end

-- Where the element actually is on screen. Falls back to the record's implied
-- centre when the frame has no rect yet (hidden, or a getFrame that is nil).
local function visualCenter(el, pos)
    local rect = Registry:GetRect(el)
    if rect then return rect.x, rect.y end
    local w, h = sizeOf(el)
    return Solver.PointToCenter(pos.point or "CENTER", pos.x or 0, pos.y or 0, w, h)
end

-- Free elements: after a record change, pull the visible rect back on screen.
-- The consumer must have applied the record first (Notify), so the rect is current.
local function clampFree(el, pos)
    local rect = Registry:GetRect(el)
    if not rect then return end
    local cx, cy = Solver.ClampToScreen(rect.x, rect.y, rect.w, rect.h, UIParent:GetWidth(), UIParent:GetHeight())
    pos.x, pos.y = (pos.x or 0) + (cx - rect.x), (pos.y or 0) + (cy - rect.y)
end

function Sess:Nudge(el, dx, dy)
    -- Park the panel: a run of nudges must not re-dock it under the cursor.
    if NS.Panel then NS.Panel:HoldDock() end
    local pos = Registry:GetPos(el)
    local before = NS.CopyPos(pos)
    if pos.anchor then
        pos.anchor.offsetX = (pos.anchor.offsetX or 0) + dx
        pos.anchor.offsetY = (pos.anchor.offsetY or 0) + dy
        NS:ResolveElement(el)
    else
        pos.x, pos.y = (pos.x or 0) + dx, (pos.y or 0) + dy
        NS:Notify(el, "nudge"); clampFree(el, pos)
    end
    apply(el, "nudge")
    commit(el, before, L["Nudge %s"])
end

-- Panel edit boxes: free element -> absolute x/y; anchored -> offsets.
function Sess:SetXY(el, x, y)
    local pos = Registry:GetPos(el)
    local before = NS.CopyPos(pos)
    if pos.anchor then
        pos.anchor.offsetX, pos.anchor.offsetY = x, y
        NS:ResolveElement(el)
    else
        pos.x, pos.y = x, y
        NS:Notify(el, "nudge"); clampFree(el, pos)
    end
    apply(el, "nudge")
    commit(el, before, L["Move %s"])
end

function Sess:SetAnchorPoint(el, point)
    if el.pointLocked then return end
    local pos = Registry:GetPos(el)
    if pos.anchor or pos.point == point then return end
    local before = NS.CopyPos(pos)
    local w, h = sizeOf(el)
    local cx, cy = Solver.PointToCenter(pos.point or "CENTER", pos.x or 0, pos.y or 0, w, h)
    pos.point = point
    pos.x, pos.y = Solver.CenterToPoint(point, cx, cy, w, h)
    apply(el, "nudge")
    commit(el, before, L["Anchor point %s"])
end

-- Re-anchoring to a new primary keeps whatever backup was already set: the
-- element's fall-back plan is a separate choice from where it normally sits.
-- Dropped only when the new primary IS the backup, which would make the two
-- the same link.
local function carryFallback(pos, before, targetId)
    local fb = before.anchor and before.anchor.fallback
    if not fb or fb.target == targetId then return end
    pos.anchor.fallback = { target = fb.target, mode = fb.mode, edge = fb.edge, align = fb.align,
                            point = fb.point, relPoint = fb.relPoint,
                            offsetX = fb.offsetX, offsetY = fb.offsetY }
end

function Sess:Anchor(el, targetId, edge, align)
    if Registry:WouldCreateCycle(el.id, targetId) then
        NS:Print(L["Anchoring would create a loop."])
        return false
    end
    local pos = Registry:GetPos(el)
    local before = NS.CopyPos(pos)
    pos.anchor = { target = targetId, edge = edge, align = align, offsetX = 0, offsetY = 0 }
    carryFallback(pos, before, targetId)
    pos.point = "CENTER"
    NS:ResolveElement(el)
    apply(el, "anchor")
    commit(el, before, L["Anchor %s"])
    return true
end

-- Anchor to a target WITHOUT moving: the picker's verb. Solver.AnchorInPlace
-- derives the spec that reproduces where the element already sits, so choosing
-- a parent from the panel is a change of relationship, not of position.
function Sess:AnchorInPlace(el, targetId)
    if Registry:WouldCreateCycle(el.id, targetId) then
        NS:Print(L["Anchoring would create a loop."])
        return
    end
    local pos = Registry:GetPos(el)
    local before = NS.CopyPos(pos)
    local childRect = Registry:GetRect(el)
    if not childRect then
        local cx, cy = visualCenter(el, pos)
        local w, h = sizeOf(el)
        childRect = { x = cx, y = cy, w = w, h = h }
    end
    local target = Registry:GetTarget(targetId)
    local targetRect = target and Registry:GetRect(target) or nil
    if not targetRect then
        -- Anchoring in place is impossible with no rect: there is no geometry to
        -- measure a seat against, so nothing can be reproduced. The element HOLDS
        -- where it is (ResolveElement finds no available anchor) and takes the
        -- centre-on-centre spec -- the one case where picking a target moves the
        -- element later, once that target finally appears.
        pos.anchor = { target = targetId, mode = "point", point = "CENTER", relPoint = "CENTER",
                       offsetX = 0, offsetY = 0 }
    else
        local spec = Solver.AnchorInPlace(childRect, targetRect, Solver.SPACING)
        pos.anchor = { target = targetId, mode = spec.mode, edge = spec.edge, align = spec.align,
                       point = spec.point, relPoint = spec.relPoint,
                       offsetX = spec.offsetX, offsetY = spec.offsetY }
    end
    carryFallback(pos, before, targetId)
    pos.point = "CENTER"
    NS:ResolveElement(el)
    apply(el, "anchor")
    commit(el, before, L["Anchor %s"])
end

-- Edit the live spec of an existing outside-mode anchor (the panel's edge and
-- align dropdowns). Point mode has no edge/align to set, so it is left alone.
function Sess:SetAnchorSpec(el, changes)
    local pos = Registry:GetPos(el)
    if not pos.anchor or pos.anchor.mode == "point" then return end
    local before = NS.CopyPos(pos)
    for k, v in pairs(changes) do pos.anchor[k] = v end
    NS:ResolveElement(el)
    apply(el, "anchor")
    commit(el, before, L["Anchor %s"])
end

function Sess:Detach(el)
    local pos = Registry:GetPos(el)
    if not pos.anchor then return end
    local before = NS.CopyPos(pos)
    pos.anchor = nil
    apply(el, "detach")
    commit(el, before, L["Detach %s"])
end

-- The backup anchor: where the element goes when its primary target is not on
-- screen. It takes the primary's whole spec with only the target swapped --
-- the same seat on a different parent -- so the element keeps its shape of
-- attachment either way.
function Sess:SetFallback(el, targetId)
    local pos = Registry:GetPos(el)
    if not pos.anchor then return end
    -- Same as the primary is a no-op, not a mistake worth a message.
    if targetId == pos.anchor.target then return end
    if Registry:WouldCreateCycle(el.id, targetId) then
        NS:Print(L["Anchoring would create a loop."])
        return
    end
    local before = NS.CopyPos(pos)
    local a = pos.anchor
    a.fallback = { target = targetId, mode = a.mode, edge = a.edge, align = a.align,
                   point = a.point, relPoint = a.relPoint,
                   offsetX = a.offsetX, offsetY = a.offsetY }
    -- Only actually moves the element if the primary is already unavailable,
    -- which is exactly when the backup is meant to take over.
    NS:ResolveElement(el)
    apply(el, "fallback")
    commit(el, before, L["Backup anchor %s"])
end

function Sess:ClearFallback(el)
    local pos = Registry:GetPos(el)
    if not pos.anchor or not pos.anchor.fallback then return end
    local before = NS.CopyPos(pos)
    pos.anchor.fallback = nil
    apply(el, "fallback")
    commit(el, before, L["Clear backup %s"])
end

function Sess:Center(el)
    local pos = Registry:GetPos(el)
    local before = NS.CopyPos(pos)
    -- Move the record by whatever it takes to put the visible rect on 0,0.
    local cx, cy = visualCenter(el, pos)
    pos.anchor = nil
    pos.x, pos.y = (pos.x or 0) - cx, (pos.y or 0) - cy
    apply(el, "center")
    commit(el, before, L["Center %s"])
end

function Sess:Reset(el)
    if not el.default then return self:Center(el) end
    local pos = Registry:GetPos(el)
    local before = NS.CopyPos(pos)
    NS.CopyPos(el.default, pos)
    if pos.anchor then NS:ResolveElement(el) end
    apply(el, "reset")
    commit(el, before, L["Reset %s"])
end

-- Copy this element's record onto its declared twin (def.twin = "addon:key"):
-- party container onto raid container, pinned N onto the other mode's N. The
-- twin takes the whole record -- anchor included, unless carrying it over
-- would create a cycle, in which case the twin lands free at the same
-- coordinates. One undo entry, named for the twin.
function Sess:CopyToTwin(el)
    local twin = el.twin and Registry:Get(el.twin)
    if not twin then return end
    local dst = Registry:GetPos(twin)
    local before = NS.CopyPos(dst)
    NS.CopyPos(Registry:GetPos(el), dst)
    if dst.anchor and Registry:WouldCreateCycle(twin.id, dst.anchor.target) then dst.anchor = nil end
    -- The backup is dropped on its own if only IT would loop; the primary stays.
    if dst.anchor and dst.anchor.fallback and Registry:WouldCreateCycle(twin.id, dst.anchor.fallback.target) then
        dst.anchor.fallback = nil
    end
    if dst.anchor then NS:ResolveElement(twin) end
    apply(twin, "copy")
    commit(twin, before, L["Copy to %s"])
end

-- The toast needs the entry's label, and Undo/Redo POP the entry -- so Peek
-- before popping, and only toast when something was actually undone/redone.
function Sess:Undo()
    if not self.undo then return end
    local label = self.undo:Peek()
    if self.undo:Undo() and label then
        Proxy:ShowToast(format(L["Undid: %s"], label))
    end
end

function Sess:Redo()
    if not self.undo then return end
    local label = self.undo:PeekRedo()
    if self.undo:Redo() and label then
        Proxy:ShowToast(format(L["Redid: %s"], label))
    end
end

-- ============================================================
-- DRAG
-- ============================================================
function Sess:BeginDrag(el)
    local pos = Registry:GetPos(el)
    self.dragBefore = NS.CopyPos(pos)
    self.dragStartPos = NS.CopyPos(pos)
    self.dragStartCx, self.dragStartCy = visualCenter(el, pos)
    -- Anchored: arm the tether. Pull is measured from the RESOLVED anchor
    -- position, which is exactly where the element sits at drag start (the
    -- record was solved). Proxy reads this table to draw the strain.
    if pos.anchor then
        local a = pos.anchor
        self.tether = { target = a.target,
                        spec = { mode = a.mode, edge = a.edge, align = a.align,
                                 point = a.point, relPoint = a.relPoint },
                        homeX = self.dragStartCx, homeY = self.dragStartCy,
                        state = "held", strain = 0, snapped = false }
    else
        self.tether = nil
    end
end

function Sess:DragTo(el, cx, cy)
    local db = NS.db
    local w, h = sizeOf(el)
    -- Frame zones are tested on the RAW cursor position and win outright; grid
    -- and screen snapping only apply when no zone is hit. Quantising first would
    -- make zones on off-grid targets unreachable (a 20px grid vs a zone at y=150).
    local zone
    if db.snapToFrames and #Proxy.dragZones > 0 then
        zone = Solver.NearestZone(cx, cy, w, h, Proxy.dragZones, db.snapDistance or SNAP_DISTANCE)
    end
    if zone then
        cx, cy = zone.x, zone.y
        Grid:HidePreview()
    else
        -- The preview lines sit on the grid / screen line each axis actually
        -- snapped to (an edge or the centre), not on the element's centre.
        -- Screen snap runs last, so its line wins on an axis it moved.
        local lineX, lineY
        if db.snapToGrid then cx, cy, lineX, lineY = Solver.SnapRectToGrid(cx, cy, w, h, db.gridSize) end
        if db.snapToScreen then
            local sx, sy, lx, ly
            cx, cy, sx, sy, lx, ly = Solver.SnapToScreen({ x = cx, y = cy, w = w, h = h }, UIParent:GetWidth(), UIParent:GetHeight(), SCREEN_SNAP)
            if sx then lineX = lx end
            if sy then lineY = ly end
        end
        if lineX or lineY then Grid:ShowPreview(lineX, lineY) else Grid:HidePreview() end
    end
    cx, cy = Solver.ClampToScreen(cx, cy, w, h, UIParent:GetWidth(), UIParent:GetHeight())
    Grid:ShowMeasure(cx, cy, w, h)
    -- Tether strain-and-snap: pulling an anchored element past the thresholds
    -- (Solver.TETHER_HOLD/SNAP x snapDistance, measured from the resolved
    -- anchor position) first strains the tether, then snaps it -- the element
    -- is free from that moment and EndDrag's spring-back no longer applies.
    local t = self.tether
    if t and not t.snapped then
        local dist = sqrt((cx - t.homeX) ^ 2 + (cy - t.homeY) ^ 2)
        local snapR = db.snapDistance or SNAP_DISTANCE
        t.state = Solver.TetherState(dist, snapR)
        t.strain = Solver.TetherStrain(dist, snapR)
        if t.state == "snapped" then
            t.snapped = true
            Proxy:SnapTether(el)
        end
    end
    local pos = Registry:GetPos(el)
    pos.anchor = nil
    pos.x, pos.y = Solver.DragDelta(self.dragStartPos, self.dragStartCx, self.dragStartCy, cx, cy)
    NS:Notify(el, "drag")
    NS:ReapplyDescendants(el.id, "parent")
    Proxy:RefreshAll()
    return cx, cy, zone
end

function Sess:EndDrag(el, cx, cy, zone)
    local before = self.dragBefore or NS.CopyPos(Registry:GetPos(el))
    local tether = self.tether
    self.dragBefore, self.dragStartPos, self.dragStartCx, self.dragStartCy = nil, nil, nil, nil
    self.tether = nil
    local pos = Registry:GetPos(el)
    if zone and Registry:WouldCreateCycle(el.id, zone.target) then zone = nil end
    if zone then
        pos.anchor = { target = zone.target, edge = zone.edge, align = zone.align, offsetX = 0, offsetY = 0 }
        carryFallback(pos, before, zone.target)
        pos.point = "CENTER"
        NS:ResolveElement(el)
    elseif before.anchor and not (tether and tether.snapped) then
        -- The anchor SURVIVED the drag (never pulled past the snap threshold):
        -- dropped outside every zone, it springs back and re-solves. Nothing
        -- changed, so no undo entry. A snapped tether skips this branch -- the
        -- element detached mid-drag and the drop commits it as free.
        NS.CopyPos(before, pos)
        NS:ResolveElement(el)
        apply(el, "reapply")
        self:Select(el.id)
        return
    end
    apply(el, zone and "anchor" or "drag")
    local label = zone and L["Anchor %s"] or (before.anchor and L["Detach %s"] or L["Move %s"])
    -- Pulled free of a record that also named a backup: the backup went with the
    -- primary, and that is worth saying out loud -- it is a link the user set up
    -- deliberately and would otherwise notice only much later.
    if not zone and before.anchor and before.anchor.fallback then
        Proxy:ShowToast(L["Detached — backup anchor cleared"])
    end
    commit(el, before, label)
    self:Select(el.id)
end

-- ============================================================
-- KEYBOARD
-- Esc = lock, arrows = nudge (Shift x10, Ctrl x100), Ctrl+Z / Ctrl+Y = undo/redo.
-- Only ever enabled while the unlock frame is shown, which never happens in combat.
-- ============================================================
local ARROWS = { UP = { 0, 1 }, DOWN = { 0, -1 }, LEFT = { -1, 0 }, RIGHT = { 1, 0 } }

function Sess:EnableKeyboard(on)
    local f = Proxy:GetUnlockFrame()
    f:EnableKeyboard(on)
    if not on then f:SetScript("OnKeyDown", nil) return end
    f:SetScript("OnKeyDown", function(frame, key)
        local handled = false
        if key == "ESCAPE" then
            Sess:Lock(); handled = true
        elseif ARROWS[key] and NS.db.keyboardNudge and Sess.selected then
            local el = Registry:Get(Sess.selected)
            if el then
                local step = Solver.NudgeStep(IsShiftKeyDown(), IsControlKeyDown())
                Sess:Nudge(el, ARROWS[key][1] * step, ARROWS[key][2] * step)
                handled = true
            end
        elseif IsControlKeyDown() and key == "Z" then Sess:Undo(); handled = true
        elseif IsControlKeyDown() and key == "Y" then Sess:Redo(); handled = true
        end
        frame:SetPropagateKeyboardInput(not handled)
    end)
end
