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
        if def.openSettings ~= nil and type(def.openSettings) ~= "function" then
            error("DandersMover: openSettings must be a function", 3)
        end
        if def.twin ~= nil and type(def.twin) ~= "string" then
            error("DandersMover: twin must be an \"addon:key\" string", 3)
        end
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
        -- false = the target builds no snap zones; the picker and link-drag still reach it.
        snappable = def.snappable ~= false,
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
        -- false = the target builds no snap zones; the picker and link-drag still reach
        -- it. The paired insertTarget below gets the same def, so the target copy that
        -- ShowZones reads is stamped there; this copy is for symmetry/introspection.
        snappable = def.snappable ~= false,
        -- Consumer-side settings entry: the panel offers a Configure button
        -- that calls this (e.g. DF opens its options window on the page).
        openSettings = def.openSettings,
        -- "addon:key" of this element's counterpart (party <-> raid); the
        -- panel offers Copy to <twin> while the twin is registered.
        twin = def.twin,
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

-- Points a record's anchor blocks (primary and backup) away from oldId. The record
-- is the consumer's live table, so this edits it in place; the position itself does
-- not move, which is why no rename path Notifies.
local function rewriteRecord(pos, oldId, newId)
    if type(pos) ~= "table" then return end
    local a = pos.anchor
    if not a then return end
    if a.target == oldId then a.target = newId end
    if a.fallback and a.fallback.target == oldId then a.fallback.target = newId end
end

-- Every registered element's record and twin string, moved off oldId. Shared by
-- R:RenameKey and the Flush replay below (see R:RenameKey for why both need it).
local function rewriteRegistered(self, oldId, newId)
    for _, el in pairs(self.elements) do
        local ok, pos = pcall(el.getPos)
        if ok then rewriteRecord(pos, oldId, newId) end
        if el.twin == oldId then el.twin = newId end
    end
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
    -- A consumer can register between a rename and this Flush, carrying a record that
    -- still names the old id. Replay the renames over what just landed.
    if self.pendingRenames then
        for oldId, newId in pairs(self.pendingRenames) do rewriteRegistered(self, oldId, newId) end
        self.pendingRenames = nil
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
-- RENAME
-- ============================================================
-- Moves an element's key: the user toggle, the registry entry (with its paired
-- anchor target) and every record or twin string that names the old id follow it.
-- The element keeps its table and its position -- nothing is re-registered and
-- nothing is Notified, so live closures and the saved position both survive.
-- Refuses (false, no throw) a no-op rename or one onto a key already in use.
function R:RenameKey(addon, old, new)
    if old == new then return false end
    local oldId, newId = R.Id(addon, old), R.Id(addon, new)
    if self.elements[newId] or self.targets[newId] then return false end

    -- The toggle outlives the registration: move it even with nothing registered.
    local db = NS.db
    local a = db and db.addons and db.addons[addon]
    if a and a.elements and a.elements[old] ~= nil then
        a.elements[new] = a.elements[old]
        a.elements[old] = nil
    end

    local el = self.elements[oldId]
    if el then
        self.elements[oldId] = nil
        el.key, el.id = new, newId
        self.elements[newId] = el
    end
    -- An anchorable element's target IS this entry, so re-keying it here covers both.
    local target = self.targets[oldId]
    if target then
        self.targets[oldId] = nil
        target.key, target.id = new, newId
        self.targets[newId] = target
    end

    rewriteRegistered(self, oldId, newId)
    for _, item in ipairs(self.queue) do
        if item.kind == "element" then
            local ok, pos = pcall(item.def.getPos)
            if ok then rewriteRecord(pos, oldId, newId) end
            if item.def.twin == oldId then item.def.twin = newId end
        end
    end

    -- Anything that registers after this but before Flush is caught by the replay there.
    self.pendingRenames = self.pendingRenames or {}
    self.pendingRenames[oldId] = newId
    return true
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

-- One addon's elements bucketed by their `group` label, for a list that wants
-- subheadings. Pure: it reads the registry and returns plain tables.
--   { { group = nil, elements = { ... } }, { group = "Party", elements = { ... } }, ... }
-- Ungrouped elements are the FIRST bucket (rendered with no heading, so they must
-- not sit under someone else's); grouped buckets follow in the order their first
-- element is met, walking SortedElements so that order is id-stable. Elements are
-- sorted by title within a bucket, ties broken by id.
function R:GroupedElements(addon)
    local out, buckets, ungrouped = {}, {}, nil
    for _, el in ipairs(self:SortedElements()) do
        if el.addon == addon then
            if el.group == nil then
                if not ungrouped then
                    ungrouped = { group = nil, elements = {} }
                    tinsert(out, 1, ungrouped)
                end
                tinsert(ungrouped.elements, el)
            else
                local bucket = buckets[el.group]
                if not bucket then
                    bucket = { group = el.group, elements = {} }
                    buckets[el.group] = bucket
                    tinsert(out, bucket)
                end
                tinsert(bucket.elements, el)
            end
        end
    end
    for _, bucket in ipairs(out) do
        tsort(bucket.elements, function(a, b)
            if a.title == b.title then return a.id < b.id end
            return a.title < b.title
        end)
    end
    return out
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
--
-- CanonicalId is O(elements) -- the alias walk calls GetFrame on every registered
-- element -- and Children calls it once per element, so a single refresh pass can
-- run it thousands of times. Begin/EndCanonMemo scope a memo around one such pass.
-- Validity assumption: frames do not change identity inside one synchronous refresh
-- pass, so an answer computed at the top of the pass is still the answer at the end.
-- Never leave the memo open across a frame boundary or a consumer callback that can
-- re-register.
function R:BeginCanonMemo()
    self._canonDepth = (self._canonDepth or 0) + 1
    if self._canonDepth == 1 then self._canonMemo = {} end
end

function R:EndCanonMemo()
    local depth = (self._canonDepth or 0) - 1
    if depth < 0 then depth = 0 end
    self._canonDepth = depth
    if depth == 0 then self._canonMemo = nil end
end

function R:CanonicalId(targetId)
    local m = self._canonMemo; if m and m[targetId] ~= nil then return m[targetId] end
    local target = self.targets[targetId]
    if not target then if m then m[targetId] = targetId end return targetId end
    if target.element then
        local id = target.element.id
        if m then m[targetId] = id end
        return id
    end
    local f = self:GetFrame(target)
    if not f then if m then m[targetId] = targetId end return targetId end
    for id, el in pairs(self.elements) do
        if self:GetFrame(el) == f then
            if m then m[targetId] = id end
            return id
        end
    end
    if m then m[targetId] = targetId end
    return targetId
end

-- Which anchor block is actually driving this element right now: the primary,
-- its backup, or neither (hold). The single chooser the resolver, the tether
-- and the panel all go through, so none of them can disagree about which link
-- is live.
function R:ActiveAnchor(el)
    local pos = self:GetPos(el)
    local a = pos.anchor
    if not a then return nil end
    if self:IsTargetAvailable(self.targets[a.target]) then return a end
    if a.fallback and self:IsTargetAvailable(self.targets[a.fallback.target]) then return a.fallback end
    return nil
end

-- Both canonical parents (primary, backup), regardless of availability: graph
-- walks must still reach a child that is currently holding.
function R:ParentIds(elId)
    local el = self.elements[elId]
    if not el then return nil end
    local pos = self:GetPos(el)
    local a = pos.anchor
    if not a then return nil end
    local primary = self:CanonicalId(a.target)
    if a.fallback then return primary, self:CanonicalId(a.fallback.target) end
    return primary
end

-- The ACTIVE parent: what the element is resolving against at this moment.
function R:ParentId(elId)
    local el = self.elements[elId]
    if not el then return nil end
    local a = self:ActiveAnchor(el)
    return a and self:CanonicalId(a.target) or nil
end

function R:Children(targetId)
    local canon = self:CanonicalId(targetId)
    local out = {}
    for _, el in pairs(self.elements) do
        local primary, backup = self:ParentIds(el.id)
        if primary == canon or backup == canon then tinsert(out, el) end
    end
    return out
end

-- Would anchoring elId to targetId create a loop (including through aliases)?
-- Walks BOTH parent edges (primary and backup) STRUCTURALLY -- availability is
-- deliberately ignored: a cycle through a currently-hidden target is still a
-- cycle the moment that target reappears, and ParentId (the ACTIVE parent)
-- would walk right past it while the chain is holding.
function R:WouldCreateCycle(elId, targetId)
    local frontier, seen = { self:CanonicalId(targetId) }, {}
    while #frontier > 0 do
        local nxt = {}
        for _, id in ipairs(frontier) do
            if id == elId then return true end
            if not seen[id] then
                seen[id] = true
                local primary, backup = self:ParentIds(id)
                if primary then tinsert(nxt, primary) end
                if backup then tinsert(nxt, backup) end
            end
        end
        frontier = nxt
    end
    return false
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
