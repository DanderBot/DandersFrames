local NS = ...

-- ============================================================
-- STANDALONE FRAMES AND THE PER-FRAME SETTINGS TABLE
-- DandersFrames/Frames/Core.lua     (DF:GetFrameDB)
-- DandersFrames/Frames/Headers.lua  (DF:InitStandaloneFrame, InitializeHeaderChild)
-- DandersFrames/Frames/Bars.lua     (DF:ShouldShowResourceBar)
-- ------------------------------------------------------------
-- A frame may carry its own settings table (frame.dfDB). Pinned frames set it
-- for Hide Auras / Hide Icons, a standalone frame for everything. A standalone
-- frame is never raid/arena/pinned, never enters the shared unit dispatch, is
-- never adopted as DF.playerFrame and reports no sort.
-- ============================================================

local function lift(src, name)
    src = src:gsub("\r\n", "\n")
    local a = src:find("\nfunction DF:" .. name .. "%(")
    local b = a and src:find("\nend\n", a, true)
    check(a ~= nil and b ~= nil, "lift: found DF:" .. name)
    return (a and b) and src:sub(a + 1, b + 4) or ""
end

local function load(chunk, env, label)
    local f, err = loadstring(chunk, "=" .. label)
    check(f ~= nil, "lift: " .. label .. " parses (" .. tostring(err) .. ")")
    if f then setfenv(f, setmetatable(env, { __index = _G })); f() end
end

local partyDB, raidDB = { who = "party" }, { who = "raid" }

-- ---- GetFrameDB ----------------------------------------------------------
print("-- GetFrameDB: a frame's own table wins, else the mode's")
local DF = { raidFrameRegistry = {} }
function DF:GetDB() return partyDB end
function DF:GetRaidDB() return raidDB end
function DF:IsRaidFrame(f) return f and (f.isRaidFrame or self.raidFrameRegistry[f]) or false end
load(lift(df_file_source("Frames/Core.lua"), "GetFrameDB"), { DF = DF }, "GetFrameDB")

eq(DF:GetFrameDB(nil), partyDB, "nil frame: the party table (unchanged)")
eq(DF:GetFrameDB({}), partyDB, "party frame: the party table (unchanged)")
eq(DF:GetFrameDB({ isRaidFrame = true }), raidDB, "raid frame: the raid table (unchanged)")
local own = { who = "own" }
eq(DF:GetFrameDB({ dfDB = own }), own, "a frame's own table is the answer")
eq(DF:GetFrameDB({ dfDB = own, isRaidFrame = true }), own, "...even on a frame classed raid (pinned in a raid)")

print("-- Pinned frames moved onto the one field")
for _, rel in ipairs({ "Frames/Core.lua", "Features/PinnedFrames.lua", "Frames/Headers.lua" }) do
    check(not df_file_source(rel):find("dfPinnedEffDB", 1, true), rel .. ": no dfPinnedEffDB left")
end
local _, pinnedWrites = df_file_source("Features/PinnedFrames.lua"):gsub("%.dfDB = ", "")
eq(pinnedWrites, 4, "PinnedFrames: the four effective-db writes now set dfDB")

-- ---- InitStandaloneFrame ---------------------------------------------------
print("-- InitStandaloneFrame: reclassify and release the shared claims")
local HSRC = df_file_source("Frames/Headers.lua")
local map = {}
local layouts, rebuilt = {}, 0
local DF2 = { raidFrameRegistry = {} }
function DF2:Debug() end
local errors = 0
function DF2:DebugError() errors = errors + 1 end
function DF2:ApplyFrameLayout(f) layouts[#layouts + 1] = f end
function DF2:RebuildUnitFrameMap() rebuilt = rebuilt + 1 end
load(lift(HSRC, "InitStandaloneFrame"), { DF = DF2, unitFrameMap = map }, "InitStandaloneFrame")

local partyFrame = { GetName = function() return "P" end }
local f = { isRaidFrame = true, isArenaFrame = true, isPinnedFrame = true, isPinnedBossFrame = true,
            dfIsRaidCombinedChild = true, GetName = function() return "F" end }
DF2.raidFrameRegistry[f] = true
map.player = f
map.party1 = partyFrame
DF2.playerFrame = f
local db = { frameWidth = 200 }
eq(DF2:InitStandaloneFrame(f, db), f, "returns the frame")
check(f.dfStandalone == true and f.dfDB == db, "marked standalone, carrying its table")
check(f.isRaidFrame == false and f.isArenaFrame == false and f.isPinnedFrame == false
      and f.isPinnedBossFrame == nil and f.dfIsRaidCombinedChild == false, "classification undone")
eq(DF2.raidFrameRegistry[f], nil, "out of the raid registry")
eq(map.player, nil, "its unitFrameMap claim released")
eq(map.party1, partyFrame, "...and nobody else's touched")
eq(DF2.playerFrame, nil, "no longer DF.playerFrame")
eq(rebuilt, 1, "a released claim rebuilds the map")
eq(layouts[1], f, "laid out again from its own table")

local g = { GetName = function() return "G" end }
IN_COMBAT = true
DF2:InitStandaloneFrame(g, {})
IN_COMBAT = false
eq(#layouts, 1, "in combat: no layout (size is protected)")
eq(rebuilt, 1, "nothing claimed: no map rebuild")
DF2:InitStandaloneFrame(g, nil)
eq(errors, 1, "no table: refused with a debug error")

print("-- InitializeHeaderChild: every shared-dispatch write skips standalone frames")
local ihc = lift(HSRC, "InitializeHeaderChild")
local mapWrites = 0
for line in ihc:gmatch("[^\n]+") do
    if line:find("unitFrameMap%[[%w%.]+%] = self") or line:find("unitFrameMap%[[%w%.]+%] = frame") then
        mapWrites = mapWrites + 1
    end
end
check(mapWrites >= 4, "found the unitFrameMap writes (" .. mapWrites .. ")")
local _, standaloneMentions = ihc:gsub("dfStandalone", "")
check(standaloneMentions >= 6, "every map write, the player adoption and the sort callback name dfStandalone ("
      .. standaloneMentions .. ")")
check(ihc:find("if not self.isPinnedFrame and not self.dfStandalone then\n%s*DF.playerFrame = self"),
      "DF.playerFrame adoption skips standalone frames")
check(ihc:find("if not self.dfStandalone then\n%s*local sortType"), "OnFramesSorted is not fired for standalone frames")
check(ihc:find("if self.unit and not self.dfStandalone and"), "OnShow: no map write for standalone frames")

-- ---- ShouldShowResourceBar -------------------------------------------------
print("-- ShouldShowResourceBar: standalone frames skip the role gates only")
local DF3 = {}
function DF3:GetUnitRole() return "TANK" end
DF3.UnitIsUnit = function() return false end
load(lift(df_file_source("Frames/Bars.lua"), "ShouldShowResourceBar"),
     { DF = DF3, IsInGroup = function() return true end, IsInRaid = function() return false end,
       UnitClass = function() return "Warrior", "WARRIOR" end, issecretvalue = function() return false end },
     "ShouldShowResourceBar")
local rdb = { resourceBarEnabled = true, resourceBarShowHealer = true }
eq(DF3:ShouldShowResourceBar("party1", rdb, nil, nil, nil, {}), false, "party frame: a tank fails a healer-only filter (unchanged)")
eq(DF3:ShouldShowResourceBar("target", rdb, nil, nil, nil, { dfStandalone = true }), true, "standalone: no role gate")
eq(DF3:ShouldShowResourceBar("target", {}, nil, nil, nil, { dfStandalone = true }), false, "standalone: still off when the bar is disabled")
rdb.resourceBarClassFilter = { WARRIOR = false }
eq(DF3:ShouldShowResourceBar("target", rdb, nil, nil, nil, { dfStandalone = true }), false, "standalone: the class filter still applies")
eq(DF3:ShouldShowResourceBar("party1", { resourceBarEnabled = true }, nil, nil, nil, {}), false,
   "party frame, grouped, no role filter: off (unchanged)")
