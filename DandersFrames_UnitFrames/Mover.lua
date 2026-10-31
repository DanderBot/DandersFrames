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
    return unit
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
        getFrame  = function() return UF.frames[unit] end,
        getPos    = function() return UF:GetPositionRecord(unit) end,
        onChanged = function()
            local f = UF.frames[unit]
            if f then UF:RunOutOfCombat("position:" .. unit, function() UF.Units:ApplyPosition(f) end) end
        end,
        default   = defaults and defaults.position and DF:DeepCopy(defaults.position) or nil,
        secure    = true,
        -- A hidden frame (no target) still has its size; report it in UIParent units.
        getSize   = function()
            local f = UF.frames[unit]
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
