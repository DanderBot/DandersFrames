local addonName, NS = ...

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
local pairs, ipairs, format, wipe = pairs, ipairs, string.format, wipe
local InCombatLockdown, UIParent, IsShiftKeyDown, IsControlKeyDown = InCombatLockdown, UIParent, IsShiftKeyDown, IsControlKeyDown

local SCREEN_SNAP = 8

local function panel(method) if NS.Panel then NS.Panel[method](NS.Panel) end end

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
    self.filter = filter
    wipe(self.snapshots)
    for _, el in ipairs(Registry:SortedElements()) do
        if (not filter or el.addon == filter) and Registry:IsEnabled(el.addon, el.key) then
            self.snapshots[el.id] = NS.CopyPos(Registry:GetPos(el))
        end
    end
    self.undo = Undo:New({ limit = 100 })
    self.undo.RegisterCallback(self, "Changed", function() panel("Refresh") end)
    self.dirty = false
    self.selected = nil
    self.active = true
    self.suspended = false
    Proxy:Build(filter)
    Grid:Refresh()
    self:EnableKeyboard(true)
    Lib.callbacks:Fire("Unlocked")
end

function Sess:Lock()
    if not self.active then return end
    if self.dirty then StaticPopup_Show("DANDERSMOVER_EXIT") else self:Finish("save") end
end

function Sess:Finish(mode)
    if not self.active then return end
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
    Proxy:DestroyAll()
    Grid:Hide()
    panel("Hide")
    wipe(self.snapshots)
    self.active, self.suspended, self.dirty, self.selected = false, false, false, nil
    -- Clear after the state reset: Clear fires "Changed" -> panel Refresh,
    -- which must see the session as inactive so it cannot re-show the panel.
    if self.undo then self.undo:Clear() end
    Lib.callbacks:Fire("Locked")
    Lib.callbacks:Fire(mode == "discard" and "Discarded" or "Saved")
end

function Sess:Toggle() if self.active then self:Lock() else self:Unlock() end end

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

function Sess:Nudge(el, dx, dy)
    local pos = Registry:GetPos(el)
    local before = NS.CopyPos(pos)
    if pos.anchor then
        pos.anchor.offsetX = (pos.anchor.offsetX or 0) + dx
        pos.anchor.offsetY = (pos.anchor.offsetY or 0) + dy
        NS:ResolveElement(el)
    else
        pos.x, pos.y = (pos.x or 0) + dx, (pos.y or 0) + dy
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
    end
    apply(el, "nudge")
    commit(el, before, L["Move %s"])
end

function Sess:SetAnchorPoint(el, point)
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

function Sess:Anchor(el, targetId, edge, align)
    if Registry:WouldCreateCycle(el.id, targetId) then
        NS:Print(L["Anchoring would create a loop."])
        return false
    end
    local pos = Registry:GetPos(el)
    local before = NS.CopyPos(pos)
    pos.anchor = { target = targetId, edge = edge, align = align, offsetX = 0, offsetY = 0 }
    pos.point = "CENTER"
    NS:ResolveElement(el)
    apply(el, "anchor")
    commit(el, before, L["Anchor %s"])
    return true
end

function Sess:Detach(el)
    local pos = Registry:GetPos(el)
    if not pos.anchor then return end
    local before = NS.CopyPos(pos)
    pos.anchor = nil
    apply(el, "detach")
    commit(el, before, L["Detach %s"])
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

function Sess:Undo() if self.undo then self.undo:Undo() end end
function Sess:Redo() if self.undo then self.undo:Redo() end end

-- ============================================================
-- DRAG
-- ============================================================
function Sess:BeginDrag(el)
    local pos = Registry:GetPos(el)
    self.dragBefore = NS.CopyPos(pos)
    self.dragStartPos = NS.CopyPos(pos)
    self.dragStartCx, self.dragStartCy = visualCenter(el, pos)
end

function Sess:DragTo(el, cx, cy)
    local db = NS.db
    local w, h = sizeOf(el)
    -- Frame zones are tested on the RAW cursor position and win outright; grid
    -- and screen snapping only apply when no zone is hit. Quantising first would
    -- make zones on off-grid targets unreachable (a 20px grid vs a zone at y=150).
    local zone
    if db.snapToFrames and #Proxy.dragZones > 0 then
        zone = Solver.BestZone(cx, cy, w, h, Proxy.dragZones, 0.1)
    end
    if zone then
        cx, cy = zone.x, zone.y
        Grid:HidePreview()
    else
        local snapped = false
        if db.snapToGrid then cx, cy = Solver.SnapToGrid(cx, cy, db.gridSize); snapped = true end
        if db.snapToScreen then
            local sx, sy
            cx, cy, sx, sy = Solver.SnapToScreen({ x = cx, y = cy, w = w, h = h }, UIParent:GetWidth(), UIParent:GetHeight(), SCREEN_SNAP)
            snapped = snapped or sx or sy
        end
        if snapped then Grid:ShowPreview(cx, cy) else Grid:HidePreview() end
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
    self.dragBefore, self.dragStartPos, self.dragStartCx, self.dragStartCy = nil, nil, nil, nil
    local pos = Registry:GetPos(el)
    if zone then
        if Registry:WouldCreateCycle(el.id, zone.target) then
            zone = nil
        else
            pos.anchor = { target = zone.target, edge = zone.edge, align = zone.align, offsetX = 0, offsetY = 0 }
            pos.point = "CENTER"
            NS:ResolveElement(el)
        end
    end
    apply(el, zone and "anchor" or "drag")
    commit(el, before, zone and L["Anchor %s"] or L["Move %s"])
    self:Select(el.id)
end

-- ============================================================
-- KEYBOARD
-- Esc = lock, arrows = nudge (Shift x10), Ctrl+Z / Ctrl+Y = undo/redo.
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
                local step = IsShiftKeyDown() and 10 or 1
                Sess:Nudge(el, ARROWS[key][1] * step, ARROWS[key][2] * step)
                handled = true
            end
        elseif IsControlKeyDown() and key == "Z" then Sess:Undo(); handled = true
        elseif IsControlKeyDown() and key == "Y" then Sess:Redo(); handled = true
        end
        frame:SetPropagateKeyboardInput(not handled)
    end)
end
