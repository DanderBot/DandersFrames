local addonName, NS = ...

-- ============================================================
-- REGISTRY
-- Consumer registrations: addons, movable elements, anchor targets.
-- Reads frame geometry; never writes to frames.
-- ============================================================
local R = { addons = {}, elements = {}, targets = {}, queue = {}, ready = false }
NS.Registry = R

local pairs, ipairs, type, error, tinsert, tsort, pcall = pairs, ipairs, type, error, table.insert, table.sort, pcall

function R.Id(addon, key) return addon .. ":" .. key end

-- ============================================================
-- VALIDATION
-- ============================================================
local function validate(def, kind)
    if type(def) ~= "table" then error("DandersMover: definition must be a table", 3) end
    if not def.frame and type(def.getFrame) ~= "function" then
        error("DandersMover: definition needs frame or getFrame", 3)
    end
    if def.getRect ~= nil and type(def.getRect) ~= "function" then
        error("DandersMover: getRect must be a function", 3)
    end
    -- isRelevant: "does this element/target take part right now?" (group type, a
    -- feature toggle, a mode that is not on screen). Absent = always relevant.
    if def.isRelevant ~= nil and type(def.isRelevant) ~= "function" then
        error("DandersMover: isRelevant must be a function", 3)
    end
    if kind == "element" then
        if type(def.getPos) ~= "function" then error("DandersMover: element needs getPos", 3) end
        if type(def.onChanged) ~= "function" then error("DandersMover: element needs onChanged", 3) end
    end
end

-- ============================================================
-- REGISTRATION
-- ============================================================
function R:RegisterAddon(name, info)
    info = info or {}
    self.addons[name] = { name = name, title = info.title or name, icon = info.icon }
end

local function insertTarget(self, addon, key, def, element)
    local id = R.Id(addon, key)
    self.targets[id] = {
        addon = addon, key = key, id = id, title = def.title or key,
        frame = def.frame, getFrame = def.getFrame, getSize = def.getSize,
        getRect = def.getRect, group = def.group, element = element,
        isRelevant = def.isRelevant,
    }
    return self.targets[id]
end

local function insertElement(self, addon, key, def)
    local id = R.Id(addon, key)
    if not self.addons[addon] then self:RegisterAddon(addon) end
    local el = {
        addon = addon, key = key, id = id, title = def.title or key,
        frame = def.frame, getFrame = def.getFrame,
        getPos = def.getPos, onChanged = def.onChanged, default = def.default,
        secure = def.secure and true or false, getSize = def.getSize,
        getRect = def.getRect, anchorable = def.anchorable ~= false, group = def.group,
        isRelevant = def.isRelevant,
        -- The record's `point` is derived by the consumer (e.g. a growth corner), not
        -- chosen: the panel hides its 9-point picker and SetAnchorPoint is a no-op.
        pointLocked = def.pointLocked and true or false,
    }
    self.elements[id] = el
    if el.anchorable then insertTarget(self, addon, key, def, el) else self.targets[id] = nil end
    return el
end

function R:Register(addon, key, def)
    validate(def, "element")
    if not self.ready then
        tinsert(self.queue, { kind = "element", addon = addon, key = key, def = def })
        return nil
    end
    return insertElement(self, addon, key, def)
end

function R:RegisterAnchorTarget(addon, key, def)
    validate(def, "target")
    if not self.ready then
        tinsert(self.queue, { kind = "target", addon = addon, key = key, def = def })
        return nil
    end
    if not self.addons[addon] then self:RegisterAddon(addon) end
    return insertTarget(self, addon, key, def, nil)
end

function R:Flush()
    self.ready = true
    local q = self.queue
    self.queue = {}
    for _, item in ipairs(q) do
        if item.kind == "element" then insertElement(self, item.addon, item.key, item.def)
        else
            if not self.addons[item.addon] then self:RegisterAddon(item.addon) end
            insertTarget(self, item.addon, item.key, item.def, nil)
        end
    end
end

function R:Unregister(addon, key)
    local id = R.Id(addon, key)
    self.elements[id] = nil
    self.targets[id] = nil
end

function R:UnregisterAddon(addon)
    for id, el in pairs(self.elements) do if el.addon == addon then self.elements[id] = nil end end
    for id, t in pairs(self.targets) do if t.addon == addon then self.targets[id] = nil end end
    self.addons[addon] = nil
end

-- ============================================================
-- LOOKUP
-- ============================================================
function R:Get(id) return self.elements[id] end
function R:GetTarget(id) return self.targets[id] end
function R:GetAddon(name) return self.addons[name] end

function R:SortedElements()
    local list = {}
    for _, el in pairs(self.elements) do tinsert(list, el) end
    tsort(list, function(a, b) return a.id < b.id end)
    return list
end

function R:SortedTargets()
    local list = {}
    for _, t in pairs(self.targets) do tinsert(list, t) end
    tsort(list, function(a, b) return a.id < b.id end)
    return list
end

-- ============================================================
-- GEOMETRY (read-only)
-- ============================================================
function R:GetFrame(entry)
    if entry.getFrame then return entry.getFrame() end
    return entry.frame
end

-- getRect returning nil means "not visible right now", not "no size": fall through
-- to getSize / the frame so hidden elements still have a measurable proxy.
function R:GetSize(entry)
    if entry.getRect then
        local r = entry.getRect()
        if r then return r.w, r.h end
    end
    -- getSize is declared in UIParent units (the consumer reports what is visible).
    if entry.getSize then return entry.getSize() end
    local f = self:GetFrame(entry)
    if not f then return nil end
    local w, h = f:GetSize()
    if not w then return nil end
    local ratio = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    return w * ratio, h * ratio
end

-- rect in UIParent units relative to UIParent centre.
-- getRect, when given, is the visible rect and already in those units.
function R:GetRect(entry)
    if entry.getRect then
        local r = entry.getRect()
        if not r then return nil end
        return { x = r.x, y = r.y, w = r.w, h = r.h }
    end
    local f = self:GetFrame(entry)
    if not f then return nil end
    local cx, cy = f:GetCenter()
    if not cx then return nil end
    local ratio = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local ux, uy = UIParent:GetCenter()
    local w, h = self:GetSize(entry)   -- already UIParent units
    if not w then return nil end
    return { x = cx * ratio - ux, y = cy * ratio - uy, w = w, h = h }
end

-- Is this entry currently a usable anchor target / resolvable parent?
-- A consumer that supplies getRect owns the "is it visible" question outright:
-- returning nil is how it says "not meaningfully on screen right now", and that
-- must win even when the backing frame happens to be shown (e.g. a container
-- that is always shown but holds nothing). Without getRect, fall back to the
-- frame's own shown state.
function R:IsTargetAvailable(entry)
    if not entry then return false end
    -- Irrelevant right now (wrong group type, feature off): not a snap target, and a
    -- child anchored to it HOLDS its last solved position (NS:ResolveElement) rather
    -- than jumping to a rect that is not meaningfully on screen.
    if not self:IsRelevant(entry) then return false end
    if entry.getRect then return entry.getRect() ~= nil end
    local f = self:GetFrame(entry)
    return f ~= nil and f:IsShown() and true or false
end

function R:GetPos(el)
    local pos = el.getPos()
    if type(pos) ~= "table" then error("DandersMover: getPos for " .. el.id .. " must return a table") end
    return pos
end

-- ============================================================
-- GRAPH
-- ============================================================
-- A getFrame anchor target can resolve to a frame that belongs to a registered
-- element (e.g. "first raid frame" while the roster is one frame). Graph logic
-- must see through that alias or an element can be anchored to itself.
function R:CanonicalId(targetId)
    local target = self.targets[targetId]
    if not target then return targetId end
    if target.element then return target.element.id end
    local f = self:GetFrame(target)
    if not f then return targetId end
    for id, el in pairs(self.elements) do
        if self:GetFrame(el) == f then return id end
    end
    return targetId
end

function R:ParentId(elId)
    local el = self.elements[elId]
    if not el then return nil end
    local pos = self:GetPos(el)
    return pos.anchor and self:CanonicalId(pos.anchor.target) or nil
end

function R:Children(targetId)
    local canon = self:CanonicalId(targetId)
    local out = {}
    for _, el in pairs(self.elements) do
        if self:ParentId(el.id) == canon then tinsert(out, el) end
    end
    return out
end

-- Would anchoring elId to targetId create a loop (including through aliases)?
function R:WouldCreateCycle(elId, targetId)
    return NS.Solver.WouldCreateCycle(function(id) return self:ParentId(id) end, elId, self:CanonicalId(targetId))
end

function R:Descendants(targetId)
    local out, seen, frontier = {}, {}, { targetId }
    while #frontier > 0 do
        local next = {}
        for _, id in ipairs(frontier) do
            for _, child in ipairs(self:Children(id)) do
                if not seen[child.id] then
                    seen[child.id] = true
                    tinsert(out, child)
                    tinsert(next, child.id)
                end
            end
        end
        frontier = next
    end
    return out
end

function R:IsOccupied(targetId, edge, align, excludeId)
    local canon = self:CanonicalId(targetId)
    for _, el in pairs(self.elements) do
        if el.id ~= excludeId then
            local a = self:GetPos(el).anchor
            if a and a.edge == edge and a.align == align and self:CanonicalId(a.target) == canon then return true end
        end
    end
    return false
end

-- ============================================================
-- RELEVANCE + SESSION FILTER
-- ============================================================
-- Keys named in an Unlock filter are FORCED relevant for the session (that is how a
-- solo player edits raid frames): they snap and are snapped to even though their
-- isRelevant() says no. Session owns the writes; Finish wipes it.
NS.forcedRelevant = {}

function R:IsRelevant(entry)
    if not entry then return false end
    if NS.forcedRelevant[entry.id] then return true end
    if entry.isRelevant == nil then return true end
    local ok, res = pcall(entry.isRelevant)
    if not ok then geterrorhandler()(res); return true end   -- fail OPEN
    return res and true or false
end

-- Unlock(filter): nil = everything; "Addon" = that addon initiated the session;
-- { addon = "Addon", keys = { "k", ... } } = it initiated it and only those keys of
-- its own take part. Normalised once into { addon = <string|nil>, keySet = <set|nil> }.
-- keys without addon is a hard error: keys are unique per addon only.
function R:NormalizeFilter(filter)
    if filter == nil then return nil end
    if type(filter) == "string" then return { addon = filter } end
    if type(filter) ~= "table" then error("DandersMover: Unlock filter must be nil, a string or a table", 3) end
    local out = { addon = filter.addon }
    if filter.keys ~= nil then
        if type(filter.keys) ~= "table" then error("DandersMover: Unlock filter.keys must be a table", 3) end
        if type(out.addon) ~= "string" then error("DandersMover: Unlock filter.keys needs filter.addon", 3) end
        out.keySet = {}
        for _, key in ipairs(filter.keys) do out.keySet[key] = true end
    end
    return out
end

-- Does this element take part in the session at all (snapshot, resolve, snap)?
-- The filter names the INITIATING addon: its elements follow the key filter; every
-- OTHER addon's elements are in on their own terms (enabled + relevant) so they stay
-- anchor targets -- the whole point of a consumer-initiated session is often to glue a
-- third-party element to the initiator's frames.
-- Precedence: user toggle > key filter > isRelevant.
function R:IsInSession(filter, el)
    if not self:IsEnabled(el.addon, el.key) then return false end   -- toggle wins
    if filter and filter.addon == el.addon and filter.keySet then
        return filter.keySet[el.key] == true                        -- key filter wins
    end
    return self:IsRelevant(el)
end

-- Does it get a PROXY? The initiator's in-session elements always; other addons'
-- only when the user asked to see them (showOtherAddons). An unfiltered session has
-- no "other" addons.
function R:WantsProxy(filter, el)
    if not self:IsInSession(filter, el) then return false end
    if filter and filter.addon and el.addon ~= filter.addon then
        return (NS.db and NS.db.showOtherAddons) and true or false
    end
    return true
end

-- ============================================================
-- USER TOGGLES
-- ============================================================
function R:IsEnabled(addon, key)
    local db = NS.db
    if not db or not db.addons then return true end
    local a = db.addons[addon]
    if not a then return true end
    if a.enabled == false then return false end
    if key and a.elements and a.elements[key] == false then return false end
    return true
end

-- Writes the toggle IsEnabled reads. Off is stored as an explicit false and on
-- as nil (absent = enabled), so a fresh registration is on without a migration.
-- ⚠ Explicit branches, not `cond and false or nil`: a false middle operand makes
-- that idiom fall through to nil, which is how the element toggle used to write
-- "enabled" whichever way it was clicked.
function R:SetEnabled(addon, key, enabled)
    local db = NS.db
    if not db then return end
    db.addons = db.addons or {}
    local a = db.addons[addon]
    if not a then a = { enabled = true, elements = {} }; db.addons[addon] = a end
    a.elements = a.elements or {}
    if key then
        if enabled then a.elements[key] = nil else a.elements[key] = false end
    else
        a.enabled = enabled and true or false
    end
end
