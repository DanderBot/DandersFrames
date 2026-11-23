local NS = ...

-- ============================================================
-- PINNED FRAMES: RAID FLAG AND RAID REGISTRY MOVE TOGETHER
-- DF:IsRaidFrame consults the external raidFrameRegistry as well as the field.
-- A pinned child created in a raid is registered; when pinned code later resets
-- only `isRaidFrame` (now in a party), the stale registry entry kept the frame
-- reading raid settings. DF:SetRaidFrameFlag keeps both in step, and every
-- pinned site must use it.
-- ============================================================

local function norm(s) return (s:gsub("\r\n", "\n")) end

local src = norm(df_file_source("Frames/Core.lua"))
local function lift(pattern)
    local a = src:find(pattern)
    local b = a and src:find("\nend\n", a, true)
    check(a ~= nil and b ~= nil, pattern .. " is defined in Frames/Core.lua")
    return a and b and src:sub(a, b + 4) or ""
end

local DF = { raidFrameRegistry = setmetatable({}, { __mode = "k" }) }
local chunk = lift("function DF:RegisterRaidFrame%(") .. lift("function DF:SetRaidFrameFlag%(") .. lift("function DF:IsRaidFrame%(")
local f, err = loadstring(chunk, "=RaidFlag")
check(f ~= nil, "raid flag helpers parse (" .. tostring(err) .. ")")
if f then
    setfenv(f, setmetatable({ DF = DF }, { __index = _G }))
    f()
end

print("-- created in a raid, then the group becomes a party")
local child = {}
DF:RegisterRaidFrame(child)                     -- InitializeHeaderChild in a raid
eq(DF:IsRaidFrame(child), true, "raid at creation")
DF:SetRaidFrameFlag(child, false)               -- pinned layout pass in a party
eq(child.isRaidFrame, false, "field cleared")
eq(DF.raidFrameRegistry[child], nil, "registry entry cleared")
eq(DF:IsRaidFrame(child), false, "no longer read as a raid frame")
DF:SetRaidFrameFlag(child, true)
eq(DF:IsRaidFrame(child), true, "back in a raid")
eq(DF.raidFrameRegistry[child], true, "registry entry restored")
DF:SetRaidFrameFlag(child, nil)
eq(DF:IsRaidFrame(child), false, "nil means not raid")

print("-- every pinned site goes through the helper")
local pin = norm(df_file_source("Features/PinnedFrames.lua"))
local bare = 0
for line in pin:gmatch("[^\n]+") do
    if line:match("%.isRaidFrame%s*=[^=]") and not line:match("^%s*%-%-") then
        bare = bare + 1
        print("   bare assignment: " .. line)
    end
end
eq(bare, 0, "PinnedFrames.lua never assigns isRaidFrame directly")
local uses = select(2, pin:gsub("DF:SetRaidFrameFlag%(", ""))
check(uses >= 5, "PinnedFrames.lua uses DF:SetRaidFrameFlag at every site (" .. uses .. ")")
