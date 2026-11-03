local addonName, DF = ...

-- ============================================================
-- UNIT FRAMES INVITE
-- The Unit Frames module ships switched off (## DefaultState in its TOC). Once per
-- account, this asks whether to try it. Yes switches the addon on and reloads; either
-- answer is final, and the Modules page's switch is there afterwards. Lives in the
-- resident addon because the module it offers isn't loaded yet.
-- ============================================================
local Invite = {}
DF.UnitFramesInvite = Invite

Invite.ADDON = "DandersFrames_UnitFrames"
Invite.KEY = "unitFramesInviteShown"
-- The popup is a singleton and may be busy (the changelog, a wizard): wait for it, and
-- for combat to end, then give up until the next login.
Invite.RETRY_SECONDS = 2
Invite.MAX_TRIES = 30

function Invite.Accept()
    local A = C_AddOns
    if A and A.EnableAddOn then A.EnableAddOn(Invite.ADDON) end
    ReloadUI()
end

function Invite.ShouldOffer()
    local db = DandersFramesDB_v2
    if type(db) ~= "table" or db[Invite.KEY] then return false end
    local A = C_AddOns
    if not (A and A.DoesAddOnExist and A.DoesAddOnExist(Invite.ADDON)) then return false end
    -- Someone already running it, or who switched it on themselves, needs no invitation.
    if (A.IsAddOnLoaded and A.IsAddOnLoaded(Invite.ADDON))
        or (A.GetAddOnEnableState and (A.GetAddOnEnableState(Invite.ADDON, nil) or 0) > 0) then
        db[Invite.KEY] = true
        return false
    end
    return true
end

function Invite.Show(tries)
    if not Invite.ShouldOffer() or not DF.ShowPopupAlert then return end
    if InCombatLockdown() or (DF.IsPopupShown and DF:IsPopupShown()) then
        if (tries or 0) < Invite.MAX_TRIES then
            C_Timer.After(Invite.RETRY_SECONDS, function() Invite.Show((tries or 0) + 1) end)
        end
        return
    end
    DandersFramesDB_v2[Invite.KEY] = true
    local L = DF.L
    DF:ShowPopupAlert({
        title = L["Unit Frames"],
        message = L["DandersFrames now has Unit Frames: player, target, focus, pet and boss frames.\n\nWould you like to try them? Yes turns them on and reloads your UI. You can turn them on or off any time from the Modules page."],
        buttons = {
            { label = L["Yes"], onClick = Invite.Accept },
            { label = L["No"] },
        },
    })
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function()
    C_Timer.After(3, function() Invite.Show(0) end)
end)
