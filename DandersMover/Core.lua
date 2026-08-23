local addonName, NS = ...

-- ============================================================
-- LIBRARY OBJECT
-- The public API lives on the LibStub object; internals live on NS.
-- ============================================================
local MAJOR, MINOR = "DandersMover-1.0", 1
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
local pairs, ipairs, type, xpcall, geterrorhandler = pairs, ipairs, type, xpcall, geterrorhandler
local InCombatLockdown, CreateFrame, UIParent = InCombatLockdown, CreateFrame, UIParent
local tinsert, wipe, strsplit, strlower = table.insert, wipe, strsplit, string.lower

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
    keyboardNudge = true, panelSide = "auto", showHiddenMovers = true, showOtherAddons = false, debug = false,
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
    local a = pos.anchor
    if not a then return false end
    local target = Registry:GetTarget(a.target)
    if not target then return false end
    -- Unavailable target (hidden, or a getRect that reports nothing on screen):
    -- hold the last solved position rather than snapping to a stale rect.
    if not Registry:IsTargetAvailable(target) then return false end
    local rect = Registry:GetRect(target)
    local w, h = Registry:GetSize(el)
    if not rect or not w then return false end
    local cx, cy = Solver.Resolve(a, w, h, rect, Solver.SPACING)
    if not cx then return false end
    local changed = pos.point ~= "CENTER" or pos.x ~= cx or pos.y ~= cy
    pos.point, pos.x, pos.y = "CENTER", cx, cy
    return changed
end

function NS:ReapplyDescendants(targetId, reason)
    local list = Registry:Descendants(targetId)
    if #list == 0 then return end
    local ids = {}
    for _, el in ipairs(list) do tinsert(ids, el.id) end
    local order = Solver.ResolutionOrder(ids, function(id) return NS:ParentOf(id) end)
    for _, id in ipairs(order) do
        local el = Registry:Get(id)
        if el and NS:ResolveElement(el) then NS:Notify(el, reason or "parent") end
    end
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
    Registry:Unregister(addon, key)
    if NS.Proxy then NS.Proxy:Remove(Registry.Id(addon, key)) end
    registryChanged(addon, key)
end
function Lib:UnregisterAddon(addon)
    Registry:UnregisterAddon(addon)
    if NS.Proxy then NS.Proxy:RemoveAddon(addon) end
    registryChanged(addon)
end

function Lib:RefreshAnchorTarget(addon, key)
    NS:ReapplyDescendants(Registry.Id(addon, key), "parent")
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
