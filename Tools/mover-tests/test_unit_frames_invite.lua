local NS = ...

-- ============================================================
-- THE UNIT FRAMES INVITE
-- DandersFrames/Features/UnitFramesInvite.lua, run over stubs. Checked: who is asked,
-- that it asks once, what Yes and No do, and that it waits for combat and for another
-- popup. Stubs: that the client honours ## DefaultState is for the game.
-- ============================================================

local passed, failed = 0, 0
local function check(ok, name)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end
end

local G_NAMES = { "C_AddOns", "C_Timer", "CreateFrame", "DandersFramesDB_v2", "InCombatLockdown", "ReloadUI" }
local G = {}
for _, k in ipairs(G_NAMES) do G[k] = _G[k] end

local exists, loaded, enabled, enabledCalls, reloads, combat, popupBusy, timers
local function Reset()
    exists, loaded, enabled, enabledCalls, reloads, combat, popupBusy = true, false, 0, 0, 0, false, false
    timers = {}
    DandersFramesDB_v2 = {}
end

C_AddOns = {
    DoesAddOnExist = function() return exists end,
    IsAddOnLoaded = function() return loaded end,
    GetAddOnEnableState = function() return enabled end,
    EnableAddOn = function(name)
        if name == "DandersFrames_UnitFrames" then enabledCalls = enabledCalls + 1 end
    end,
}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
CreateFrame = function()
    return { RegisterEvent = function() end, SetScript = function() end }
end
InCombatLockdown = function() return combat end
ReloadUI = function() reloads = reloads + 1 end

local shown
local DF = { L = setmetatable({}, { __index = function(_, k) return k end }) }
function DF:ShowPopupAlert(config) shown = config end
function DF:IsPopupShown() return popupBusy end

load_df_file_into("Features/UnitFramesInvite.lua", DF)
local Invite = DF.UnitFramesInvite

print("-- Unit frames invite: who is asked")
Reset(); shown = nil
Invite.Show(0)
check(shown ~= nil, "switched off: asked")
check(DandersFramesDB_v2.unitFramesInviteShown == true, "remembered as soon as it shows")
shown = nil
Invite.Show(0)
check(shown == nil, "only once")

Reset(); shown = nil; loaded = true
Invite.Show(0)
check(shown == nil, "already running: not asked")
check(DandersFramesDB_v2.unitFramesInviteShown == true, "...and never will be")

Reset(); shown = nil; enabled = 2
Invite.Show(0)
check(shown == nil, "switched on, not reloaded yet: not asked")

Reset(); shown = nil; exists = false
Invite.Show(0)
check(shown == nil, "not installed: not asked")
check(DandersFramesDB_v2.unitFramesInviteShown == nil, "...and still asked once it is")

print("-- Unit frames invite: the answers")
Reset(); shown = nil
Invite.Show(0)
check(shown.buttons[1].label == "Yes" and shown.buttons[2].label == "No", "Yes, then No")
check(shown.buttons[2].onClick == nil, "No only closes")
check(enabledCalls == 0 and reloads == 0, "nothing happens before an answer")
shown.buttons[1].onClick()
check(enabledCalls == 1, "Yes switches the addon on")
check(reloads == 1, "...and reloads")

print("-- Unit frames invite: waits its turn")
Reset(); shown = nil; combat = true
Invite.Show(0)
check(shown == nil, "not in combat")
check(DandersFramesDB_v2.unitFramesInviteShown == nil, "...and not used up")
combat = false
timers[1]()
check(shown ~= nil, "after combat")

Reset(); shown = nil; popupBusy = true
Invite.Show(0)
check(shown == nil, "not over another popup")
popupBusy = false
timers[1]()
check(shown ~= nil, "after it closes")

Reset(); shown = nil; popupBusy = true
Invite.Show(Invite.MAX_TRIES)
check(#timers == 0, "gives up after a while")
check(DandersFramesDB_v2.unitFramesInviteShown == nil, "...and asks at the next login")

for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
print(passed .. " passed, " .. failed .. " failed")
assert(failed == 0, "test_unit_frames_invite")
