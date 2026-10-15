local addonName, NS = ...
-- A copy that lost the LibStub race (a renamed duplicate install) must go
-- fully inert: Core.lua only sets NS.Lib on the winning copy.
if not NS.Lib then return end

-- ============================================================
-- DEMO CONSUMER
-- Exercises the public API exactly as a third-party addon would: three plain
-- frames (one scaled, one hidden), one real secure frame, one dynamic anchor
-- target. Positions live in DandersMoverDB.demo — the only positions the lib
-- ever stores, and only because this consumer has no home of its own.
-- ============================================================
local D = { active = false, frames = {}, dynIndex = 1 }
NS.Demo = D

local Lib, L = NS.Lib, NS.L
local CreateFrame, UIParent, InCombatLockdown = CreateFrame, UIParent, InCombatLockdown
local ipairs, format = ipairs, string.format

local DEFS = {
    { key = "alpha", w = 160, h = 50, color = { 0, 0.7, 0.2 }, default = { point = "CENTER", x = -300, y = 150 } },
    { key = "beta", w = 100, h = 100, color = { 0.7, 0.2, 0.7 }, scale = 0.8, default = { point = "CENTER", x = 0, y = 150 } },
    { key = "gamma", w = 200, h = 30, color = { 0.9, 0.6, 0.1 }, hidden = true, default = { point = "TOPLEFT", x = -900, y = 500 } },
}

local function makeFrame(def)
    local f = D.frames[def.key]
    if not f then
        if def.secure then
            f = CreateFrame("Button", "DandersMoverDemo_" .. def.key, UIParent, "SecureUnitButtonTemplate")
            f:SetAttribute("unit", "player")
        else
            f = CreateFrame("Frame", "DandersMoverDemo_" .. def.key, UIParent)
        end
        f:SetSize(def.w, def.h)
        if def.scale then f:SetScale(def.scale) end
        f.tex = f:CreateTexture(nil, "BACKGROUND")
        f.tex:SetAllPoints()
        f.tex:SetColorTexture(def.color[1], def.color[2], def.color[3], 0.6)
        f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.label:SetPoint("CENTER")
        f.label:SetText(def.key)
        D.frames[def.key] = f
    end
    if def.hidden then f:Hide() else f:Show() end
    return f
end

local function record(key, default)
    NS.db.demo[key] = NS.db.demo[key] or NS.CopyPos(default)
    return NS.db.demo[key]
end

function D:Start()
    if self.active then return end
    self.active = true
    Lib:RegisterAddon("Demo", { title = "Demo" })
    for _, def in ipairs(DEFS) do
        local f = makeFrame(def)
        local pos = record(def.key, def.default)
        Lib:Register("Demo", def.key, {
            title = "Demo " .. def.key, frame = f, default = def.default,
            getPos = function() return pos end,
            onChanged = function(p) Lib.ApplyPosition(f, p) end,
        })
        Lib.ApplyPosition(f, pos)
    end

    local secureDef = { key = "secure", w = 120, h = 40, color = { 0.9, 0.2, 0.2 }, secure = true,
                        default = { point = "CENTER", x = 300, y = 150 } }
    local s = makeFrame(secureDef)
    local spos = record("secure", secureDef.default)
    Lib:Register("Demo", "secure", {
        title = "Demo secure", frame = s, secure = true, default = secureDef.default,
        getPos = function() return spos end,
        onChanged = function(p) if not InCombatLockdown() then Lib.ApplyPosition(s, p) end end,
    })
    if not InCombatLockdown() then Lib.ApplyPosition(s, spos) end

    Lib:RegisterAnchorTarget("Demo", "dynamic", {
        title = "Demo dynamic (alpha/beta)",
        getFrame = function() return self.dynIndex == 1 and self.frames.alpha or self.frames.beta end,
    })
    NS:Print(L["Demo started. /mover to unlock. /mover demo off | refresh | reset"])
end

function D:Refresh()
    self.dynIndex = 3 - self.dynIndex
    Lib:RefreshAnchorTarget("Demo", "dynamic")
    NS:Print(format(L["Demo dynamic target now points at %s."], self.dynIndex == 1 and "alpha" or "beta"))
end

function D:Stop()
    if not self.active then return end
    Lib:UnregisterAddon("Demo")
    for _, f in pairs(self.frames) do f:Hide() end
    self.active = false
    NS:Print(L["Demo stopped."])
end

function D:Command(rest)
    rest = rest or ""
    -- Start/stop/reset create, size, attribute and hide the secure demo frame,
    -- all protected calls in combat. Refresh only touches records, so it is fine.
    if rest ~= "refresh" and InCombatLockdown() then
        NS:Print(L["Demo cannot be started or stopped in combat."])
        return
    end
    if rest == "off" then self:Stop()
    elseif rest == "refresh" then self:Refresh()
    elseif rest == "reset" then self:Stop(); wipe(NS.db.demo); self:Start()
    else self:Start() end
end
