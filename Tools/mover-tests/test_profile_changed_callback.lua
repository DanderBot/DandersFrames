local NS = ...

-- ============================================================
-- OnProfileChanged -- DandersFrames/Core/Profile.lua, Core/API.lua
-- ------------------------------------------------------------
-- An API callback for external subscribers, fired at the END of a profile
-- switch / reset (ActivateProfile) and after an import (ApplyImportedProfile),
-- with the name of the profile now live. ActivateProfile runs for real here over
-- stubs; the import's fire is checked where it sits.
-- ============================================================

local SRC = df_file_source("Core/Profile.lua"):gsub("\r\n", "\n")
local function lift(name)
    local a = SRC:find("\nfunction DF:" .. name .. "(", 1, true)
    local b = a and SRC:find("\nend\n", a, true)
    check(a ~= nil and b ~= nil, "lift: found DF:" .. name)
    return (a and b) and SRC:sub(a + 1, b + 4) or ""
end

local order = {}
local fired = {}
local DF = {}
function DF:Debug() end
function DF:DebugActive() return true end
function DF:WrapDB() end
function DF:ApplyProfileRootDefaults() end
function DF:FullProfileRefresh() order[#order + 1] = "refresh" end
function DF:Say() order[#order + 1] = "say" end
function DF:FireAPICallback(event, ...)
    order[#order + 1] = "fire"
    fired[#fired + 1] = { event = event, arg = ... }
end
local f, err = loadstring(lift("ActivateProfile"), "=ActivateProfile")
check(f ~= nil, "lift: ActivateProfile parses (" .. tostring(err) .. ")")
if f then
    setfenv(f, setmetatable({ DF = DF, C_Timer = { After = function() end } }, { __index = _G }))
    f()
    local savedSV = DandersFramesDB_v2
    DandersFramesDB_v2 = { profiles = { Other = { party = {}, raid = {} } } }
    DF:ActivateProfile("Other", "switched")
    eq(#fired, 1, "a switch fires once")
    eq(fired[1] and fired[1].event, "OnProfileChanged", "...OnProfileChanged")
    eq(fired[1] and fired[1].arg, "Other", "...with the profile now live")
    eq(order[#order], "fire", "...as the last thing the switch does (after the refresh)")
    eq(DF.db, DandersFramesDB_v2.profiles.Other, "...with DF.db already the new profile")
    DandersFramesDB_v2 = savedSV
end

print("-- Import fires it too, after the apply")
local apply = lift("ApplyImportedProfile")
local fireAt = apply:find('DF:FireAPICallback("OnProfileChanged"', 1, true)
local refreshAt = apply:find("DF:FullProfileRefresh()", 1, true)
local retAt = apply:find("\n    return true\nend", 1, true)
check(fireAt and refreshAt and retAt and refreshAt < fireAt and fireAt < retAt,
      "ApplyImportedProfile: fires after the refresh, just before it returns success")
check(apply:find('"OnProfileChanged", DandersFramesDB_v2 and DandersFramesDB_v2.currentProfile', 1, true),
      "...with the current profile's name")

print("-- Documented beside the other API callbacks")
local api = df_file_source("Core/API.lua")
check(api:find('RegisterCallback(self, "OnProfileChanged"', 1, true), "API.lua documents OnProfileChanged")
