local addonName, DF = ...
local L = DF.L

local type, ipairs, pcall, tostring = type, ipairs, pcall, tostring
local format = string.format
local UnitGUID = UnitGUID
local issecretvalue = issecretvalue
local hooksecurefunc = hooksecurefunc
local GetCVarBool, SetCVar = GetCVarBool, SetCVar
local CreateFrame = CreateFrame

-- ============================================================
-- PING MIRROR
-- Shows a group member's ping on the DF frame of the unit they pinged, the way
-- Blizzard's 12.1 raid frames do.
--
-- ☠ WHY THIS IS A MIRROR AND NOT A LISTENER. Blizzard drives its icon from two
-- events, UNIT_PING_PIN_ADDED / UNIT_PING_PIN_REMOVED. Both are protected:
-- addon code calling RegisterEvent on them is ADDON_ACTION_FORBIDDEN (verified on
-- 12.1.0.69404), and the icon template (UnitPingIconFrameTemplate) plus its mixin
-- live in a forbidden scope, so we cannot build one of Blizzard's icons either.
-- What IS allowed: the icon frames Blizzard already created on its own compact
-- frames (`CompactRaidFrameN.pingIconFrame` etc.) are ordinary, non-forbidden
-- objects, and hooksecurefunc on their ShowPing / ClearPing methods fires with the
-- texture kit. Blizzard resolves the event's GUID to a unit for us; we read the
-- owner frame's `.unit`, remember the ping by GUID, and paint our own icon on
-- whichever DF frame shows that GUID.
--
-- Two things this depends on, both handled here or in HardDisableBlizzardFrames:
--   * Blizzard's hidden compact frames must keep getting units. Party tokens are
--     fixed, but raid frames are created and assigned by CompactRaidFrameContainer
--     on roster events — so the hard-disable skips unregistering the container
--     while this feature is on (see Features/Auras.lua).
--   * The CVar showPingsOnRaidFrames must be on: Blizzard's handler returns before
--     ShowPing when it is off. EnsurePingCVar turns it on.
-- ============================================================

local PING_CVAR = "showPingsOnRaidFrames"
-- Blizzard clears pins from the engine side (UNIT_PING_PIN_REMOVED). If a ClearPing is
-- ever missed (frame recycled under us), this stops the icon sticking forever.
local SAFETY_EXPIRE = 20

local activePings  = {}   -- guid -> texture kit ("Attack", "Warning", ...)
local expireTokens = {}   -- guid -> token for the safety timer
local hookedIcons  = 0

-- ============================================================
-- HELPERS
-- ============================================================

function DF:IsPingIconEnabledAnywhere()
    local p = DF.GetDB and DF:GetDB("party")
    local r = DF.GetRaidDB and DF:GetRaidDB()
    return (p and p.pingIconEnabled) or (r and r.pingIconEnabled) or false
end

local function SafeGUID(unit)
    if not unit then return nil end
    local guid = UnitGUID(unit)
    if guid == nil or (issecretvalue and issecretvalue(guid)) then return nil end
    return guid
end

local function ForEachFrame(fn)
    if DF.IterateAllFrames then DF:IterateAllFrames(fn) end
    -- The pinned walker takes a bare callback and is called with a DOT.
    if DF.IteratePinnedFrames then DF.IteratePinnedFrames(fn) end
end

local function RefreshFramesForGUID(guid)
    ForEachFrame(function(frame)
        if frame and frame.pingIcon and frame.unit and SafeGUID(frame.unit) == guid then
            DF:UpdatePingIcon(frame)
        end
    end)
end

-- ============================================================
-- BLIZZARD ICON HOOKS
-- ============================================================

local function OnBlizzardShowPing(icon, kit)
    if not DF:IsPingIconEnabledAnywhere() then return end
    if type(kit) ~= "string" then return end
    local owner = icon:GetParent()
    local unit = owner and owner.unit
    local guid = SafeGUID(unit)
    if not guid then
        DF:Debug("PING", "ShowPing on %s with no readable unit/guid (unit=%s)",
            owner and owner:GetName() or "?", tostring(unit))
        return
    end
    icon.dfPingGUID = guid
    activePings[guid] = kit
    local token = (expireTokens[guid] or 0) + 1
    expireTokens[guid] = token
    C_Timer.After(SAFETY_EXPIRE, function()
        if expireTokens[guid] == token and activePings[guid] == kit then
            activePings[guid] = nil
            RefreshFramesForGUID(guid)
            DF:Debug("PING", "Safety expiry cleared ping on %s", tostring(unit))
        end
    end)
    DF:Debug("PING", "Ping %s on %s (%s)", kit, tostring(unit), owner and owner:GetName() or "?")
    RefreshFramesForGUID(guid)
end

local function OnBlizzardClearPing(icon)
    local guid = icon.dfPingGUID
    icon.dfPingGUID = nil
    if not guid or activePings[guid] == nil then return end
    activePings[guid] = nil
    DF:Debug("PING", "Ping cleared (%s)", tostring(icon:GetParent() and icon:GetParent().unit))
    RefreshFramesForGUID(guid)
end

local function HookIcon(icon)
    if not icon or icon.dfPingHooked then return end
    local ok, forbidden = pcall(icon.IsForbidden, icon)
    if not ok or forbidden then
        DF:DebugWarn("PING", "Blizzard ping icon is forbidden on this build; mirror cannot hook it")
        return
    end
    icon.dfPingHooked = true
    hooksecurefunc(icon, "ShowPing", OnBlizzardShowPing)
    hooksecurefunc(icon, "ClearPing", OnBlizzardClearPing)
    hookedIcons = hookedIcons + 1
end

local function HookOwner(frame)
    if frame and frame.pingIconFrame then HookIcon(frame.pingIconFrame) end
end

-- Every compact frame Blizzard may have built already. Frames built later are caught
-- by the setup hooks below; this sweep is cheap (a few dozen table reads) and guarded
-- per icon, so it is safe to run on every roster change as a belt-and-braces.
local function SweepBlizzardFrames()
    for i = 1, 40 do HookOwner(_G["CompactRaidFrame" .. i]) end
    for g = 1, 8 do
        for i = 1, 5 do HookOwner(_G["CompactRaidGroup" .. g .. "Member" .. i]) end
    end
    for i = 1, 5 do HookOwner(_G["CompactPartyFrameMember" .. i]) end
end

local setupHooked = false
local function InstallSetupHooks()
    if setupHooked then return end
    setupHooked = true
    -- Blizzard runs these on every compact frame it sets up (it is where it calls
    -- SetGUIDMatch on the ping icon), so new raid frames get hooked as they appear.
    if type(DefaultCompactUnitFrameSetup) == "function" then
        hooksecurefunc("DefaultCompactUnitFrameSetup", HookOwner)
    end
    if type(DefaultCompactMiniFrameSetup) == "function" then
        hooksecurefunc("DefaultCompactMiniFrameSetup", HookOwner)
    end
end

function DF:EnsurePingCVar()
    if not DF:IsPingIconEnabledAnywhere() then return end
    if not GetCVarBool(PING_CVAR) then
        SetCVar(PING_CVAR, "1")
        DF:Debug("PING", "Turned on CVar %s (Blizzard drops raid-frame pings without it)", PING_CVAR)
    end
end

-- ============================================================
-- DF FRAME ICON
-- ============================================================

function DF:CreatePingIcon(frame)
    if not frame or frame.pingIcon or not frame.contentOverlay then return end
    local icon = CreateFrame("Frame", nil, frame.contentOverlay)
    icon:SetSize(30, 30)
    icon:SetPoint("CENTER", frame, "CENTER", 0, 0)
    icon:SetFrameLevel(frame.contentOverlay:GetFrameLevel() + 5)
    -- Same contract as the status icons: alpha is set explicitly by ApplyIconSettings
    -- (base alpha × range/dead fade), so the whole-frame cascade must not stack on it.
    icon:SetIgnoreParentAlpha(true)
    icon:Hide()

    -- Atlas-sized like Blizzard's: the marker backing and the ping glyph are different
    -- sizes and both sit centred.
    icon.bg = icon:CreateTexture(nil, "OVERLAY", nil, 6)
    icon.bg:SetPoint("CENTER")
    icon.texture = icon:CreateTexture(nil, "OVERLAY", nil, 7)
    icon.texture:SetPoint("CENTER")

    frame.pingIcon = icon
end

-- Paint (or hide) the ping icon on one DF frame from the active-ping table.
function DF:UpdatePingIcon(frame)
    if not frame or not frame.pingIcon then return end
    -- Test mode paints its own sample ping; the live table has nothing for test units.
    if DF.testMode or DF.raidTestMode then return end

    local db = DF:GetFrameDB(frame)
    if not db or not db.pingIconEnabled then
        frame.pingIcon:Hide()
        return
    end
    if db.pingIconHideInCombat and DF.playerInCombat then
        frame.pingIcon:Hide()
        return
    end

    local guid = SafeGUID(frame.unit)
    local kit = guid and activePings[guid]
    if not kit then
        frame.pingIcon:Hide()
        return
    end

    DF:SetPingIconKit(frame.pingIcon, kit)
    DF:ApplyStatusIconSettings(frame.pingIcon, db, "pingIcon")
    frame.pingIcon:Show()
end

-- Shared with test mode so the preview uses the real atlases.
function DF:SetPingIconKit(icon, kit)
    if not icon then return end
    icon.bg:SetAtlas("Ping_Frame_BG_" .. kit, true)
    icon.texture:SetAtlas("Ping_Frame_" .. kit, true)
end

function DF:UpdateAllPingIcons()
    ForEachFrame(function(frame)
        if frame and frame.pingIcon then DF:UpdatePingIcon(frame) end
    end)
end

-- GUI toggle callback. Raid frames only work if Blizzard's container is still
-- running; if this session already killed it (hard-disable ran before the feature
-- was turned on), the only way back is a reload.
function DF:OnPingIconToggled()
    DF:EnsurePingCVar()
    SweepBlizzardFrames()
    DF:UpdateAllPingIcons()
    if DF:IsPingIconEnabledAnywhere() and DF.blizzardContainerKilled and DF.ShowPopupAlert then
        DF:ShowPopupAlert({
            title = L["Reload Required"],
            message = L["Ping icons in raids need the hidden Blizzard raid frames running in the background. Reload to apply this.\n\nReload now?"],
            width = 560,
            buttonWidth = 170,
            buttonHeight = 44,
            buttons = {
                { label = L["Reload"], onClick = function() ReloadUI() end },
                { label = L["Reload Later"] },
            },
        })
    end
end

-- ============================================================
-- INIT
-- ============================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        InstallSetupHooks()
        SweepBlizzardFrames()
        DF:EnsurePingCVar()
        DF:Debug("PING", "Ping mirror ready: %d Blizzard icon(s) hooked, enabled=%s",
            hookedIcons, tostring(DF:IsPingIconEnabledAnywhere()))
    elseif event == "GROUP_ROSTER_UPDATE" then
        SweepBlizzardFrames()
    end
end)
