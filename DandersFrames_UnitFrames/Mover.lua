local addonName, UF = ...

-- ============================================================
-- DANDERSMOVER BRIDGE
-- Registers the spawned unit frames with DandersMover-1.0 (spec §1.5).
-- The lib is OPTIONAL: without it, each frame's record point/x/y is applied by
-- Units:ApplyPosition and `anchor` is ignored -- the same rule DandersFrames'
-- own positions follow.
--
-- The record lives in the unit's settings (units[u].position) and the lib
-- mutates it in place, then calls onChanged, which re-applies it. Unit frames
-- are secure buttons, so every element is `secure`: the lib holds a combat-time
-- write until PLAYER_REGEN_ENABLED.
--
--   key            default                         notes
--   player         CENTER (-280, -200)
--   target         CENTER (280, -200)
--   targettarget   beside target's right edge      relevant only while you have a target
--   focus          CENTER (-280, -300)
--   pet            under player's bottom edge
--
-- While the preview is up (UF.Preview: a mover session turns it on), each
-- element measures and reports the PREVIEW frame, so an absent unit (no target,
-- no pet) is still a visible, draggable slab.
-- ============================================================

local DF = DandersFrames
if not DF then return end

local ipairs, pairs, pcall, type = ipairs, pairs, pcall, type

local Lib = LibStub and LibStub("DandersMover-1.0", true)

local M = { lib = Lib }
UF.Mover = M

M.ADDON_KEY = "DandersFrames_UnitFrames"

-- Element titles, looked up at registration time (an L read at file scope would
-- freeze on English before the language override is applied).
function M:Title(unit)
    local L = DF.L
    if not L then return unit end
    if unit == "player" then return L["Player"] end
    if unit == "target" then return L["Target"] end
    if unit == "targettarget" then return L["Target of Target"] end
    if unit == "focus" then return L["Focus"] end
    if unit == "pet" then return L["Pet"] end
    return unit
end

-- The frame an element stands for right now: the preview frame while the
-- preview is up, the live one otherwise.
function M:FrameFor(unit)
    local P = UF.Preview
    local pf = P and P:IsActive() and P.frames and P.frames[unit]
    if pf then return pf end
    return UF.frames[unit]
end

-- The element's visible rect in UIParent units from UIParent's centre, or nil
-- when nothing is on screen (the lib then falls back to getSize).
function M:RectFor(unit)
    local f = M:FrameFor(unit)
    if not (f and f:IsVisible()) then return nil end
    local cx, cy = f:GetCenter()
    if not cx then return nil end
    local ratio = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local ux, uy = UIParent:GetCenter()
    local w, h = f:GetSize()
    return { x = cx * ratio - ux, y = cy * ratio - uy, w = w * ratio, h = h * ratio }
end

-- Extra fields per element.
M.EXTRA = {
    targettarget = {
        isRelevant = function() return UnitExists("target") and true or false end,
    },
}

function M:BuildDef(unit)
    local L = DF.L or {}
    local defaults = UF.UnitDefaults and UF.UnitDefaults[unit]
    local def = {
        title     = M:Title(unit),
        group     = L["Unit Frames"] or "Unit Frames",
        getFrame  = function() return M:FrameFor(unit) end,
        getRect   = function() return M:RectFor(unit) end,
        getPos    = function() return UF:GetPositionRecord(unit) end,
        onChanged = function()
            local f = UF.frames[unit]
            if f then UF:RunOutOfCombat("position:" .. unit, function() UF.Units:ApplyPosition(f) end) end
            -- The preview frame is not secure: it follows at once, in combat too.
            if UF.Preview and UF.Preview.ApplyPosition then UF.Preview:ApplyPosition(unit) end
        end,
        default   = defaults and defaults.position and DF:DeepCopy(defaults.position) or nil,
        secure    = true,
        -- A hidden frame (no target) still has its size; report it in UIParent units.
        getSize   = function()
            local f = M:FrameFor(unit)
            if not f then return nil end
            local w, h = f:GetSize()
            local ratio = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
            return w * ratio, h * ratio
        end,
    }
    for k, v in pairs(M.EXTRA[unit] or {}) do def[k] = v end
    return def
end

-- ============================================================
-- CHILD ELEMENTS (spec §1.5): a DETACHED cast bar / class power is an element of
-- its own, `<unit>.castbar` / `player.classpower`, registered only while it is
-- detached (attached, it is laid out inside the frame and is no element). Its
-- record lives in the unit's settings (castbarPosition / classPowerPositionRecord)
-- and starts anchored to its owner, so a first detach moves nothing. Not secure:
-- these are plain frames, so a write applies at once, in combat too.
-- ============================================================
M.CHILDREN = {
    castbar = { record = "castbarPosition", detached = "castbarDetached", enabled = "castbarEnabled",
                field = "dfUFCastBar", edge = "bottom" },
    classpower = { record = "classPowerPositionRecord", detached = "classPowerDetached",
                   enabled = "classPowerEnabled", field = "dfUFClassPower", edge = "top" },
}
M.children = M.children or {}

function M.ChildKey(unit, kind) return unit .. "." .. kind end

function M:ChildTitle(unit, kind)
    local L = DF.L or {}
    local what = (kind == "castbar") and (L["Cast Bar"] or "Cast Bar") or (L["Class Power"] or "Class Power")
    return string.format("%s \194\183 %s", M:Title(unit), what)
end

-- The element frame a child stands for right now (the preview's while it is up).
function M:ChildFrame(unit, kind)
    local spec = M.CHILDREN[kind]
    local owner = M:FrameFor(unit)
    return owner and spec and owner[spec.field] or nil
end

function M:ChildRect(unit, kind)
    local el = M:ChildFrame(unit, kind)
    if not (el and el:IsVisible()) then return nil end
    local cx, cy = el:GetCenter()
    if not cx then return nil end
    local ratio = el:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local ux, uy = UIParent:GetCenter()
    local w, h = el:GetSize()
    return { x = cx * ratio - ux, y = cy * ratio - uy, w = w * ratio, h = h * ratio }
end

-- Re-place the live and preview copies at the record.
function M:PlaceChild(unit, kind)
    local spec = M.CHILDREN[kind]
    local record = UF:GetUnitDB(unit)[spec.record]
    local K = UF.Elements and UF.Elements.Kit
    for _, owner in ipairs({ UF.frames[unit], UF.Preview and UF.Preview.frames and UF.Preview.frames[unit] }) do
        local el = owner and owner[spec.field]
        if el and K then K.PlaceDetached(el, owner, record) end
    end
end

function M:BuildChildDef(unit, kind)
    local L = DF.L or {}
    local spec = M.CHILDREN[kind]
    local defaults = UF.UnitDefaults and UF.UnitDefaults[unit]
    return {
        title     = M:ChildTitle(unit, kind),
        group     = L["Unit Frames"] or "Unit Frames",
        getFrame  = function() return M:ChildFrame(unit, kind) end,
        getRect   = function() return M:ChildRect(unit, kind) end,
        getPos    = function() return UF:GetUnitDB(unit)[spec.record] end,
        onChanged = function() M:PlaceChild(unit, kind) end,
        default   = defaults and defaults[spec.record] and DF:DeepCopy(defaults[spec.record]) or nil,
        getSize   = function()
            local el = M:ChildFrame(unit, kind)
            if not el then return nil end
            local w, h = el:GetSize()
            local ratio = el:GetEffectiveScale() / UIParent:GetEffectiveScale()
            return w * ratio, h * ratio
        end,
    }
end

-- Should this child be an element now? Its owner is registered, and the piece is
-- on and detached.
function M:WantsChild(unit, kind)
    local spec = M.CHILDREN[kind]
    if not spec or not (M.registered and M.registered[unit]) then return false end
    local db = UF:GetUnitDB(unit)
    return (db[spec.enabled] and db[spec.detached]) and true or false
end

-- Register / unregister one child to match its settings. Called from the
-- element's Layout (every settings change) and after Init.
function M:SyncChild(unit, kind)
    if not Lib or not M.initialised or not M.CHILDREN[kind] then return false end
    local key = M.ChildKey(unit, kind)
    local want = M:WantsChild(unit, kind)
    if want and not M.children[key] then
        Lib:Register(M.ADDON_KEY, key, M:BuildChildDef(unit, kind))
        M.children[key] = true
        pcall(Lib.Apply, Lib, M.ADDON_KEY, key)
        UF.Debug("mover: %s registered", key)
    elseif not want and M.children[key] then
        if Lib.Unregister then pcall(Lib.Unregister, Lib, M.ADDON_KEY, key) end
        M.children[key] = nil
        UF.Debug("mover: %s unregistered", key)
    end
    return want
end

function M:SyncChildren()
    for _, unit in ipairs(UF.SPAWNED_UNITS) do
        for kind in pairs(M.CHILDREN) do M:SyncChild(unit, kind) end
    end
end

-- "Follow the Frame" on a detached child's card: anchored to its owner's edge
-- (Lib:SetAnchor), or free where it stands (Lib:Detach). Without the mover the
-- record's anchor is written directly (and, as for every record, ignored until
-- the mover is installed).
function M:IsChildFollowing(unit, kind)
    local spec = M.CHILDREN[kind]
    local rec = spec and UF:GetUnitDB(unit)[spec.record]
    return type(rec) == "table" and type(rec.anchor) == "table"
end

function M:SetChildFollowing(unit, kind, follow)
    local spec = M.CHILDREN[kind]
    if not spec then return false end
    local key = M.ChildKey(unit, kind)
    local anchor = { target = M.ADDON_KEY .. ":" .. unit, edge = spec.edge, align = "center",
                     offsetX = 0, offsetY = 0 }
    if Lib and M.children[key] then
        if follow then return Lib:SetAnchor(M.ADDON_KEY, key, anchor) and true or false end
        return Lib:Detach(M.ADDON_KEY, key) and true or false
    end
    local rec = UF:GetUnitDB(unit)[spec.record]
    if type(rec) ~= "table" then return false end
    rec.anchor = follow and anchor or nil
    M:PlaceChild(unit, kind)
    return true
end

-- Register every spawned frame. Returns false when the lib is not installed.
function M:Init()
    if not Lib then return false end
    if M.initialised then return true end
    M.initialised = true
    local L = DF.L or {}
    Lib:RegisterAddon(M.ADDON_KEY, {
        title = L["Unit Frames"] or "Unit Frames",
        icon  = "Interface\\AddOns\\DandersFrames\\Media\\DF_Icon",
    })
    for _, unit in ipairs(UF.SPAWNED_UNITS) do
        if UF.frames[unit] then
            Lib:Register(M.ADDON_KEY, unit, M:BuildDef(unit))
            M.registered = M.registered or {}
            M.registered[unit] = true
        end
    end
    -- A session needs something to drag: the preview's "unlock" claim (spec §1.5,
    -- DandersFrames' MoverBridge claims test mode the same way). Every session
    -- claims it -- the lib has no public way to ask which addon opened it -- and
    -- Locked releases it whichever way the session ended.
    if Lib.RegisterCallback then
        Lib.RegisterCallback(M, "Unlocked", function()
            if UF.Preview then UF.Preview:SetOwner("unlock", true) end
        end)
        Lib.RegisterCallback(M, "Locked", function()
            if UF.Preview then UF.Preview:SetOwner("unlock", false) end
        end)
    end
    M:SyncChildren()
    UF.Debug("registered unit frames with DandersMover")
    return true
end

-- Re-solve every registered element (login, profile change): a saved anchor's
-- x/y were solved against last session's target rect.
function M:ApplyAll()
    if not Lib or not M.registered then return end
    for _, unit in ipairs(UF.SPAWNED_UNITS) do
        if M.registered[unit] then
            local ok, err = pcall(Lib.Apply, Lib, M.ADDON_KEY, unit)
            if not ok then DF:DebugError("UF", "mover apply %s failed: %s", unit, tostring(err)) end
        end
    end
end
