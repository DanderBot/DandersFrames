local NS = ...

-- ============================================================
-- PRE-V5 IMPORT: FRAME LEVELS
-- DandersFrames/Core.lua  DF:ConvertPreV5FrameLevels
-- ------------------------------------------------------------
-- 4.x stored status-icon frame levels as 0 = "built-in default". An import keeps the
-- receiving profile's migration flags, so the payload itself must be converted before
-- it is applied. The real function and its level table are lifted from source.
-- ============================================================

print("-- Pre-v5 import: frame-level sentinels are converted on the payload")

local src = df_file_source("Core.lua"):gsub("\r\n", "\n")
local function cut(startPlain, endPlain)
    local a = src:find(startPlain, 1, true)
    local b = a and src:find(endPlain, a, true)
    check(a ~= nil and b ~= nil, "source: " .. startPlain:sub(1, 40) .. " is locatable")
    return (a and b) and src:sub(a, b + #endPlain - 1) or ""
end
local levels = cut("local ABS_LEVEL_SENTINEL_DEFAULT = {", "\n}\n")
local fn     = cut("function DF:ConvertPreV5FrameLevels(payload)", "\nend\n")
local DF = assert(loadstring("local DF = {}\n" .. levels .. fn .. "\nreturn DF"))()

local function payload(version, party)
    return { version = version, party = party, raid = { roleIconFrameLevel = 0 } }
end

do
    local p = payload("v4.10.0-alpha.1", {
        roleIconFrameLevel = 0, defensiveIconFrameLevel = 0, missingBuffIconFrameLevel = 0,
        combatIconFrameLevel = 12,
    })
    DF:ConvertPreV5FrameLevels(p)
    eq(p.party.roleIconFrameLevel, 30, "v4: a sentinel status-icon level becomes its built-in level")
    eq(p.party.defensiveIconFrameLevel, 65, "v4: the defensive sentinel lands on the current baseline")
    eq(p.party.missingBuffIconFrameLevel, 60, "v4: the missing-buff sentinel lands on the current baseline")
    eq(p.party.combatIconFrameLevel, 12, "v4: a level the user set is left as it was")
    eq(p.raid.roleIconFrameLevel, 30, "v4: the raid table is converted too")
end

do
    local p = payload("v5.4.0", { roleIconFrameLevel = 0 })
    DF:ConvertPreV5FrameLevels(p)
    eq(p.party.roleIconFrameLevel, 0, "v5: a payload already in the absolute shape is untouched")
end

do
    local p = payload(nil, { roleIconFrameLevel = 0 })
    DF:ConvertPreV5FrameLevels(p)
    eq(p.party.roleIconFrameLevel, 30, "no version: treated as pre-v5")
end

do
    local p = payload("v4.7.3", { auraDesigner = { defaults = { indicatorFrameLevel = 5 } } })
    DF:ConvertPreV5FrameLevels(p)
    eq(p.party.auraDesigner.defaults.indicatorFrameLevel, 5, "v4: the Aura Designer level is not shifted")
end
