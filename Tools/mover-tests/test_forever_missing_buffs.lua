local NS = ...

-- ============================================================
-- WOW FOREVER MISSING BUFFS: WHICH BUFFS EACH MEMBER IS CHECKED FOR
-- DandersFrames/Features/Auras.lua  missingTrackedBuffs (+ its rule helpers)
-- DandersFrames/FilterRegistry/SpellDB_Forever.lua  DF.RaidBuffs / DF.ClassToRaidBuff
-- ------------------------------------------------------------
-- The real helpers are lifted by name out of Auras.lua and run against the REAL
-- generated Forever data, with the unit/spell APIs stubbed per case.
--   manaOnly   Arcane Intellect, Divine Spirit: never on warriors or rogues
--   notTank    Salvation: never on a tank
--   tankOption Thorns: tanks only while the option is on (the player's own frame solo)
--   opt        the Forever extras: own switch under auto-detect too, and only once
--              the player knows a rank
--   blessings  one paladin cell per member, icon by role, Kings fallback; a paladin
--              is checked for THEIR OWN blessing (HELPFUL|PLAYER)
-- ✗ nothing about the container itself -- the badges are read in game.
-- ============================================================

print("-- Forever missing buffs: per-member rules")

local src = df_file_source("Features/Auras.lua"):gsub("\r\n", "\n")
local a = src:find("-- ---- Per-unit rules (WoW Forever)", 1, true)
local b = src:find("DF._missingTrackedBuffs = missingTrackedBuffs", 1, true)
check(a ~= nil and b ~= nil and a < b, "source: the rules and missingTrackedBuffs are locatable")
if not (a and b) then return end

-- The real Forever data.
local DFns = { IS_FOREVER = true }
load_df_file_into("FilterRegistry/SpellDB_Forever.lua", DFns)
eq(#DFns.RaidBuffs, 8, "data: Forever tracks eight buffs")

-- Stubbed world, swapped per case.
local W = {}
local env = setmetatable({
    DF = DFns,
    UnitClass = function(unit)
        local c = (unit == "player") and W.playerClass or (W.classes[unit] or "PRIEST")
        return c, c
    end,
    IsPlayerSpell = function(id) return W.known[id] == true end,
    IsInGroup = function() return W.inGroup end,
}, { __index = _G })
function DFns:GetUnitRole(unit) return W.roles[unit] or "NONE" end

local chunk = assert(loadstring(src:sub(a, b - 1)
    .. "\nreturn missingTrackedBuffs, missingKnownCache"))
setfenv(chunk, env)
local tracked, knownCache = chunk()

local function world(t)
    W.playerClass = t.playerClass or "MAGE"
    W.classes = t.classes or {}
    W.roles = t.roles or {}
    W.known = t.known or {}
    W.inGroup = t.inGroup ~= false
    for k in pairs(knownCache) do knownCache[k] = nil end
end

local function keysFor(db, unit)
    local out = {}
    for _, info in ipairs(tracked(db, unit)) do out[#out + 1] = info.sig or info[2] end
    return table.concat(out, ",")
end

local function allOn(extra)
    local db = {
        missingBuffCheckStamina = true, missingBuffCheckIntellect = true,
        missingBuffCheckVersatility = true, missingBuffCheckAttackPower = true,
        missingBuffCheckSpirit = true, missingBuffCheckThorns = true,
        missingBuffCheckSalvation = true, missingBuffCheckBlessing = true,
        missingBuffThornsTankOnly = true,
        missingBuffBlessingTank = "might", missingBuffBlessingHealer = "wisdom", missingBuffBlessingDPS = "might",
    }
    for k, v in pairs(extra or {}) do db[k] = v end
    return db
end

-- ---- manual mode: the per-member rules --------------------------------------------
do
    world({ playerClass = "MAGE", classes = { party1 = "WARRIOR", party2 = "PRIEST" },
            roles = { party1 = "TANK", party2 = "HEALER" } })
    local db = allOn()
    eq(keysFor(db, "party1"),
       "missingBuffCheckStamina,missingBuffCheckVersatility,missingBuffCheckAttackPower,missingBuffCheckThorns,missingBuffCheckBlessing:might",
       "manual: a warrior tank gets no Intellect or Spirit (no mana), no Salvation (tank), Thorns and Might")
    eq(keysFor(db, "party2"),
       "missingBuffCheckStamina,missingBuffCheckIntellect,missingBuffCheckVersatility,missingBuffCheckAttackPower,missingBuffCheckSpirit,missingBuffCheckSalvation,missingBuffCheckBlessing:wisdom",
       "manual: a priest healer gets Intellect, Spirit, Salvation and Wisdom, but no tanks-only Thorns")
    db.missingBuffThornsTankOnly = false
    check(keysFor(db, "party2"):find("missingBuffCheckThorns", 1, true) ~= nil,
          "manual: with Thorns on Tanks Only off, Thorns goes on everyone")
    db.missingBuffCheckSalvation = false
    check(keysFor(db, "party2"):find("Salvation", 1, true) == nil, "manual: Salvation's own switch turns it off")

    -- solo: the player's own frame keeps tanks-only Thorns
    world({ playerClass = "DRUID", inGroup = false })
    check(keysFor(allOn(), "player"):find("missingBuffCheckThorns", 1, true) ~= nil,
          "solo: tanks-only Thorns still shows on your own frame")

    -- a non-paladin is checked for anyone's blessing
    world({ playerClass = "MAGE", roles = { party1 = "DAMAGER" } })
    local cells = tracked(allOn(), "party1")
    local bless = cells[#cells]
    eq(bless[2], "missingBuffCheckBlessing", "blessing: the cell keeps the check's key")
    eq(bless.filter, "HELPFUL", "blessing: a non-paladin counts any paladin's blessing")
    eq(bless.icon, 19740, "blessing: a DPS shows Blessing of Might")
    check(type(bless[1]) == "table" and #bless[1] >= 18, "blessing: ...and any rank of Might, Wisdom or Kings counts")
end

-- ---- Light and Salvation satisfy the check, without changing the pick ------------------
-- The cell is a "missing" container over bless[1]: an aura whose id is in that list
-- means the badge stays hidden. So "counts as present" = the id is in the cell's list.
do
    local function inCell(cell, id)
        for _, x in ipairs(cell[1]) do if x == id then return true end end
        return false
    end
    local SALVATION, GREATER_SALV, LIGHT, GREATER_LIGHT = 1038, 25895, 19977, 25890
    world({ playerClass = "PALADIN", roles = { party1 = "DAMAGER", party2 = "HEALER" },
            known = { [19740] = true, [19742] = true } })
    local db = allOn({ missingBuffCheckSalvation = false })
    local dps = tracked(db, "party1"); dps = dps[#dps]
    eq(dps.icon, 19740, "satisfy: a DPS is still asked for Might")
    check(inCell(dps, SALVATION) and inCell(dps, GREATER_SALV),
          "satisfy: a DPS with only Salvation from you counts as blessed (Salvation check off)")
    local healer = tracked(db, "party2"); healer = healer[#healer]
    eq(healer.icon, 19742, "satisfy: a healer is still asked for Wisdom")
    check(inCell(healer, LIGHT) and inCell(healer, GREATER_LIGHT),
          "satisfy: a healer with only Light from you counts as blessed")
    eq(healer.filter, "HELPFUL|PLAYER", "satisfy: ...still only your own blessings count")
end

-- ---- the paladin's own blessing, with a Kings fallback ---------------------------------
do
    local MIGHT1, WISDOM1, KINGS = 19740, 19742, 20217
    world({ playerClass = "PALADIN", roles = { party1 = "HEALER" }, known = { [MIGHT1] = true, [KINGS] = true } })
    local cells = tracked(allOn(), "party1")
    local bless = cells[#cells]
    eq(bless.filter, "HELPFUL|PLAYER", "paladin: checked for YOUR OWN blessing, so several paladins each cover everyone")
    eq(bless.icon, KINGS, "paladin: a healer wants Wisdom; you don't know it, so Kings")
    world({ playerClass = "PALADIN", roles = { party1 = "HEALER" }, known = { [WISDOM1] = true } })
    cells = tracked(allOn(), "party1")
    eq(cells[#cells].icon, WISDOM1, "paladin: ...and Wisdom once you know it")
    world({ playerClass = "PALADIN", roles = { party1 = "HEALER" }, known = { [MIGHT1] = true } })
    check(keysFor(allOn(), "party1"):find("Blessing", 1, true) == nil,
          "paladin: knowing neither the pick nor Kings means no blessing cell")
    world({ playerClass = "PALADIN", roles = { party1 = "TANK" }, known = { [MIGHT1] = true } })
    eq(keysFor(allOn({ missingBuffBlessingTank = "bogus" }), "party1"):match("Blessing:(%w+)"), "might",
       "paladin: an unknown saved value falls back to the role's default")
end

-- ---- auto-detect: your class's buffs, the extras behind their switch and your spellbook --
do
    local db = allOn({ missingBuffClassDetection = true })
    world({ playerClass = "PRIEST", roles = { party1 = "HEALER" } })
    eq(keysFor(db, "party1"), "missingBuffCheckStamina", "auto: a priest without Divine Spirit watches Fortitude only")
    world({ playerClass = "PRIEST", roles = { party1 = "HEALER" }, known = { [14752] = true } })
    eq(keysFor(db, "party1"), "missingBuffCheckStamina,missingBuffCheckSpirit", "auto: ...and Spirit once the talent is known")
    db.missingBuffCheckSpirit = false
    eq(keysFor(db, "party1"), "missingBuffCheckStamina", "auto: Spirit's own switch still counts under auto-detect")

    world({ playerClass = "PALADIN", roles = { party1 = "DAMAGER" }, known = { [19740] = true, [1038] = true } })
    eq(keysFor(allOn({ missingBuffClassDetection = true, missingBuffCheckSalvation = false }), "party1"),
       "missingBuffCheckBlessing:might:own", "auto: a paladin watches their blessing; Salvation stays off by its default")
    world({ playerClass = "WARRIOR" })
    eq(keysFor(allOn({ missingBuffClassDetection = true }), "party1"), "missingBuffCheckAttackPower",
       "auto: a warrior still watches Battle Shout alone")
    world({ playerClass = "ROGUE" })
    eq(keysFor(allOn({ missingBuffClassDetection = true }), "party1"), "", "auto: a class with no raid buff watches nothing")
end

-- ---- the shipped defaults ----------------------------------------------------------
do
    local cfg = df_file_source("Core/Config.lua"):gsub("\r\n", "\n")
    local party = cfg:sub(cfg:find("DF.PartyDefaults = {", 1, true) or 1)
    for key, want in pairs({ missingBuffCheckSpirit = "true", missingBuffCheckThorns = "true",
                             missingBuffThornsTankOnly = "true", missingBuffCheckBlessing = "true",
                             missingBuffCheckSalvation = "false",
                             missingBuffBlessingTank = '"might"', missingBuffBlessingHealer = '"wisdom"',
                             missingBuffBlessingDPS = '"might"' }) do
        check(party:find("\n    " .. key .. " = " .. want .. ",", 1, true) ~= nil,
              "defaults: " .. key .. " = " .. want)
    end
end
