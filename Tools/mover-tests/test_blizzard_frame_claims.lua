local NS = ...

-- ============================================================
-- BLIZZARD FRAME CLAIMS AND THE SHARED HIDE HELPERS
-- DandersFrames/Core.lua (DF:ClaimBlizzardFrame, DF:UpdateDefaultPlayerFrame)
-- DandersFrames/Features/Auras.lua (DF.BlizzardHide)
-- ------------------------------------------------------------
-- A module that owns a Blizzard frame claims it, and DandersFrames' own handling
-- of that frame (today: Hide Default Player Frame) stands down. No claim: the
-- player frame behaves exactly as before.
-- ============================================================

local SRC = df_file_source("Core.lua"):gsub("\r\n", "\n")
local a = SRC:find("\nfunction DF:ShouldHideDefaultPlayerFrame()", 1, true)
local s = SRC:find("\nfunction DF:UpdateDefaultPlayerFrame()", 1, true)
local b = s and SRC:find("\nend\n", s, true)
check(a and s and b and a < s, "lift: found the player-frame block")
if not (a and b) then return end

local hidden, shown = 0, 0
local showHook
local PF
PF = {
    Hide = function() hidden = hidden + 1 end,
    Show = function() shown = shown + 1; if showHook then showHook(PF) end end,
}
local db = { hideDefaultPlayerFrame = true }
local DF = {}
function DF:GetDB() return db end
function DF:Debug() end
local env = setmetatable({
    DF = DF, PlayerFrame = PF,
    IsInRaid = function() return false end,
    hooksecurefunc = function(_, _, fn) showHook = fn end,
}, { __index = _G })
local f, err = loadstring(SRC:sub(a + 1, b + 4), "=playerframe")
check(f ~= nil, "lift: parses (" .. tostring(err) .. ")")
if not f then return end
setfenv(f, env)
f()

print("-- No claim: unchanged")
DF:UpdateDefaultPlayerFrame()
eq(hidden, 1, "setting on: the player frame is hidden")
eq(DF.playerFrameHiddenByUs, true, "...and recorded as hidden by us")
PF.Show()
eq(hidden, 2, "Blizzard re-shows it: the hook hides it again")
db.hideDefaultPlayerFrame = false
DF:UpdateDefaultPlayerFrame()
eq(shown, 2, "setting off: shown again (once by us)")

print("-- Claims")
eq(DF:IsBlizzardFrameClaimed("PlayerFrame"), false, "nothing claimed")
check(not DF:ClaimBlizzardFrame(nil, "x") and not DF:ClaimBlizzardFrame("", "x"), "a claim needs a frame name")
check(DF:ClaimBlizzardFrame("PlayerFrame", "Other"), "claim")
local claimed, owner = DF:IsBlizzardFrameClaimed("PlayerFrame")
check(claimed == true and owner == "Other", "claimed, with its owner")
check(not DF:ReleaseBlizzardFrame("PlayerFrame", "Someone"), "another owner cannot release it")

print("-- Claimed: DandersFrames stands down")
db.hideDefaultPlayerFrame = true
hidden, shown = 0, 0
DF.pendingPlayerFrameUpdate = true
DF:UpdateDefaultPlayerFrame()
eq(hidden, 0, "setting on but claimed: not hidden by us")
eq(DF.pendingPlayerFrameUpdate, nil, "...and no combat-deferred update left pending")
PF.Show()
eq(hidden, 0, "the re-hide hook stands down too")
IN_COMBAT = true
DF:UpdateDefaultPlayerFrame()
IN_COMBAT = false
eq(DF.pendingPlayerFrameUpdate, nil, "claimed in combat: nothing deferred")

check(DF:ReleaseBlizzardFrame("PlayerFrame", "Other"), "the owner releases it")
DF:UpdateDefaultPlayerFrame()
eq(hidden, 1, "released: DandersFrames' setting applies again")

print("-- The hide helpers are shared")
local AU = df_file_source("Features/Auras.lua"):gsub("\r\n", "\n")
for name, fn in pairs({ StripEvents = "StripUnitFrameEvents", Reparent = "ReparentToHidden", Restore = "RestoreParent" }) do
    local decl = AU:find("\nlocal function " .. fn .. "(", 1, true)
    local pub = AU:find("\nDF.BlizzardHide." .. name .. " = " .. fn .. "\n", 1, true)
    check(decl and pub and decl < pub, "DF.BlizzardHide." .. name .. " = " .. fn .. ", published after it is declared")
end
