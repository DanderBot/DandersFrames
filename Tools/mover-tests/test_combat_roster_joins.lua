-- ============================================================
-- COMBAT ROSTER JOINS (Frames/Headers.lua, Features/FlatRaidFrames.lua)
-- A name-list header shows only the names on its list, and the list cannot be
-- rewritten in combat. These pin what makes a mid-fight joiner appear once combat
-- ends, and the placeholder token that keeps a still-loading member visible.
-- The REAL code is lifted out of the addon files by its source text.
-- ============================================================

local saved = {}
local function stub(name, value) saved[name] = _G[name]; _G[name] = value end
local function restore() for k, v in pairs(saved) do _G[k] = v end; saved = {} end

-- Source text from `startText` through the first line that is exactly "end" after `endAnchor`.
local function cut(src, startText, endAnchor)
    local s = src:find(startText, 1, true)
    check(s ~= nil, "setup: found " .. startText)
    local a = src:find(endAnchor, s, true)
    check(a ~= nil, "setup: found " .. endAnchor)
    local e = src:find("\nend\r?\n", a)
    return src:sub(s, e + 4)
end

local headers = df_file_source("Frames/Headers.lua")
local flat = df_file_source("Features/FlatRaidFrames.lua")

-- ------------------------------------------------------------
-- 1. A change deferred in combat must still read as a change afterwards
-- ------------------------------------------------------------
do
    local roster = {}
    stub("IsInRaid", function() return true end)
    stub("IsInGroup", function() return true end)
    stub("GetNumGroupMembers", function() return #roster end)
    stub("GetRaidRosterInfo", function(i) local r = roster[i]; if r then return r[1], nil, r[2] end end)
    stub("UnitName", function() return nil end)
    stub("UnitExists", function() return false end)

    -- One chunk, so both functions close over the same saved roster.
    local block = cut(headers, "local rosterMembershipCache = {}", "local function InvalidateRosterSnapshot()")
    local changed, invalidate = assert(loadstring("local DF = {}\n" .. block
        .. "\nreturn HasRosterMembershipChanged, InvalidateRosterSnapshot", "@rosterSnapshot"))()

    roster = { { "Tank-Realm", 1 }, { "Heals-Realm", 1 } }
    eq(changed(), true, "first look at a roster is a change")
    eq(changed(), false, "the same roster again is not")

    roster[3] = { "Joiner-Realm", 2 }
    eq(changed(), true, "a mid-combat join is seen as a change")
    -- the grouped path defers the sort here in combat; without forgetting, the
    -- post-combat re-run would see "unchanged" and skip it
    invalidate()
    eq(changed(), true, "after a combat deferral, the post-combat re-run still sees a change")
    eq(changed(), false, "and only once")
    restore()
end

-- ------------------------------------------------------------
-- 2. The two post-combat call sites
-- ------------------------------------------------------------
do
    local deferral = cut(headers, 'DF:Debug("ROSTER", "  Roster CHANGED', "DF.pendingSortingUpdate = true")
    check(deferral:find("InvalidateRosterSnapshot()", 1, true) ~= nil,
        "the grouped combat deferral forgets the roster it just saw")

    local s = headers:find("if DF.pendingFlatLayoutRefresh then", 1, true)
    check(s ~= nil, "setup: found the post-combat flat refresh")
    local block = headers:sub(s, (headers:find("\n    end\r?\n", s)) or s)
    check(block:find("DF:ApplyRaidFlatSorting()", 1, true) ~= nil,
        "the post-combat flat refresh re-sorts, so the name list is rebuilt")
end

-- ------------------------------------------------------------
-- 3. The flat list's placeholder token
-- ------------------------------------------------------------
local function buildFlat(world)
    local members = world.members
    local secret = world.secret or {}
    stub("UNKNOWNOBJECT", "Unknown")
    stub("issecretvalue", function(v) return secret[v] == true end)
    stub("GetNumGroupMembers", function() return #members end)
    stub("GetRaidRosterInfo", function(i) local m = members[i]; if m then return m.name, nil, m.group end end)
    stub("UnitName", function() return "Me" end)
    stub("UnitGroupRolesAssigned", function(unit) local i = tonumber(unit:match("%d+")); return members[i] and members[i].role or "DAMAGER" end)
    stub("UnitClass", function() return "Mage", "MAGE" end)
    stub("UnitIsUnit", function(unit, other) local i = tonumber(unit:match("%d+")); return other == "player" and members[i] and members[i].isPlayer or false end)
    stub("GetUnitName", function() return nil end)
    stub("C_SpecializationInfo", { GetSpecialization = function() return 1 end,
        GetSpecializationInfo = function() return 63 end,
        GetInspectSpecialization = function() return 0 end })

    local db = world.db
    local DF = {
        MELEE_SPECS = {}, MELEE_CLASSES = {},
        GetPinnedHiddenNames = function() return world.hidden end,
        UnitIsUnit = function(a, b) return _G.UnitIsUnit(a, b) end,
    }
    local FRF = {}
    local src = cut(flat, "local function WithPlaceholderToken", "return result")
    local chunk = assert(loadstring("local DF, FlatRaidFrames, GetRaidDB, DebugPrint = ...\n" .. src, "@flatNameList"))
    chunk(DF, FRF, function() return db end, function() end)
    local list = FRF:BuildSortedNameList()
    restore()
    return list
end

local function raidWith(extra)
    local m = {
        { name = "Me", group = 1, role = "HEALER", isPlayer = true },
        { name = "Tank-Realm", group = 1, role = "TANK" },
        { name = "Dps-Realm", group = 2, role = "DAMAGER" },
    }
    for _, e in ipairs(extra or {}) do m[#m + 1] = e end
    return m
end

do
    local sorted = { sortEnabled = true, sortSelfPosition = "FIRST" }
    local list = buildFlat({ members = raidWith(), db = sorted })
    check(list:sub(-8) == ",Unknown", "the flat list ends with the placeholder token")
    check(list:find("Tank-Realm", 1, true) and list:find("Dps-Realm", 1, true), "real members are still listed")

    list = buildFlat({ members = raidWith({ { name = "Unknown", group = 3 } }), db = sorted })
    local _, unknowns = list:gsub("Unknown", "")
    eq(unknowns, 1, "a still-loading member is covered by the one trailing token, not listed by name")

    list = buildFlat({ members = raidWith(), db = { sortEnabled = false } })
    check(list:sub(-8) == ",Unknown", "the sorting-off (index order) list ends with the token too")

    list = buildFlat({ members = raidWith(), db = sorted, hidden = { ["Tank-Realm"] = true } })
    check(not list:find("Unknown", 1, true), "no token while a Hide from Main Frames set is active")
    check(not list:find("Tank-Realm", 1, true), "and the hidden member stays off the list")

    local hiddenGroup = { sortEnabled = true, sortSelfPosition = "FIRST", raidGroupVisible = { [3] = false } }
    list = buildFlat({ members = raidWith({ { name = "Unknown", group = 3 } }), db = hiddenGroup })
    check(not list:find("Unknown", 1, true), "no token while a placeholder sits in a hidden group")

    list = buildFlat({ members = raidWith({ { name = "Unknown", group = 2 } }), db = hiddenGroup })
    check(list:sub(-8) == ",Unknown", "a placeholder in a shown group keeps the token")

    local secretName = "SecretName"
    local ok = pcall(buildFlat, { members = raidWith({ { name = secretName, group = 2 } }),
        db = sorted, secret = { [secretName] = true } })
    check(ok, "a secret roster name is tested for secrecy before any comparison")
end
