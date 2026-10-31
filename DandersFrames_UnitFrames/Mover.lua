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

local ipairs, pairs, pcall = ipairs, pairs, pcall

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
