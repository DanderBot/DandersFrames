-- ============================================================
-- WOW FOREVER SPELL DATABASE + PER-VERSION FILTER STORE
--   DandersFrames/FilterRegistry/SpellDB_Forever.lua (generated; Forever's records)
--   DandersFrames/FilterRegistry/SpellDB.lua   (retail's; Forever's via its prefixes)
--   DandersFrames/FilterRegistry/Registry.lua  (store key, PruneForeignIDs)
-- Both loaded REAL.
-- ============================================================

local function loadDB(isForever)
    local ns = { IS_FOREVER = isForever or nil }
    load_df_file_into("FilterRegistry/SpellDB_Forever.lua", ns)   -- TOC order: just before SpellDB
    load_df_file_into("FilterRegistry/SpellDB.lua", ns)
    return ns
end

local function countKeys(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- ---- 1. the database itself ----------------------------------------
local retail = loadDB(false)
local forever = loadDB(true)
local RR, RF = retail.FilterRegistry, forever.FilterRegistry

do  -- retail is untouched
    check(#RR.Spells > 400, "retail ships its harvest (" .. #RR.Spells .. " records)")
    check(next(RR.ByID) ~= nil, "retail ByID is built")
    check(type(RR.DBStamp.gameBuild) == "number", "retail stamp carries a build")
    check(RR.DBStamp.flavor == nil, "retail stamp carries no flavor marker")
    check(next(RR.Excluded) ~= nil, "retail keeps its exclusion list")
end

do  -- Forever carries its OWN generated database, never retail's
    check(#RF.Spells > 50, "Forever ships its generated records (" .. #RF.Spells .. ")")
    check(RR.ForeverSpells == nil and retail.RaidBuffs == nil, "the Forever file is a no-op on retail")
    eq(countKeys(RF.Excluded), 0, "Forever has no exclusions")
    eq(countKeys(RF.CategoryPatch), 0, "Forever has no category patch")
    eq(RF.DBStamp.flavor, "forever", "Forever stamp is marked")
    check(type(RF.DBStamp.gameBuild) == "number", "Forever stamp carries the build it was generated from")
    eq(#RF.Categories, #RR.Categories, "Forever keeps every category")
    for i, cat in ipairs(RR.Categories) do
        eq(RF.Categories[i] and RF.Categories[i].key, cat.key, "category " .. i .. " key matches retail")
        check(type(RF.ByCategory[cat.key]) == "table", "Forever category '" .. cat.key .. "' exists (nil means 'deleted')")
    end
    -- every rank is its own id: the lowest rank AND the top rank both resolve
    eq(RF.ByID[139] and RF.ByID[139].n, "Renew", "Renew rank 1 resolves")
    eq(RF.ByID[25315] and RF.ByID[25315].n, "Renew", "Renew top rank resolves to the same record")
    check(RF.ByID[21562] and RF.ByID[21562] == RF.ByID[1243], "Prayer of Fortitude folds into Fortitude")
    check(RR.ByID[25315] == nil or RR.ByID[25315].n ~= "Renew", "retail does not carry Forever's rank ids")
    -- no id is claimed by two records (ByID would silently keep only the last)
    local seen, dup = {}, nil
    for _, rec in ipairs(RF.Spells) do
        for _, id in ipairs({ rec.id, unpack(rec.alts or {}) }) do
            if seen[id] then dup = id end
            seen[id] = true
        end
    end
    check(dup == nil, "no spell id appears in two Forever records (" .. tostring(dup) .. ")")

    -- consumables: all classes, one record per aura
    check(countKeys(RF.ByCategory.consumables) >= 24, "Forever lists its consumables")
    local titans = RF.ByID[17626]
    check(titans and titans.class == "ALL" and titans.cats.consumables, "Flask of the Titans is an all-class consumable")
    -- 17548 shares the name "Shadow Protection" but is the potion, not the priest buff
    local potion = RF.ByID[17548]
    check(potion and potion.class == "ALL" and potion.cats.consumables and not potion.cats.raidBuffs,
        "Greater Shadow Protection Potion is a consumable")
    check(RF.ByID[976] and RF.ByID[976] ~= potion, "...and not part of priest Shadow Protection")
    for _, id in ipairs({ 7235, 7241, 7242, 7243, 7244 }) do   -- shadow damage absorbs, not the resistance buff
        check(RF.ByID[id] ~= RF.ByID[976], id .. " is not priest Shadow Protection")
    end
    local sor = RF.ByID[27827]
    check(sor and sor.class == "PRIEST" and sor.cats.defensives, "Spirit of Redemption is a priest defensive")
    check(RF.ByID[20711] == nil, "...keyed by its aura, not the passive talent")
    -- Prayer of Mending: the cast applies its aura through a script, so the generator
    -- lists the aura ids by hand; every rank's aura resolves, the casts and the rune don't
    local pom = RF.ByID[401877]
    check(pom and pom.n == "Prayer of Mending" and pom.class == "PRIEST" and pom.cats.healing,
        "Prayer of Mending is a priest healing aura")
    check(RF.ByID[1240848] == pom and RF.ByID[1240849] == pom, "...ranks 2 and 3 resolve to the same record")
    for _, id in ipairs({ 401859, 1240826, 1240827, 402832 }) do
        check(RF.ByID[id] == nil, id .. " (cast or rune) is not a Prayer of Mending aura")
    end
    check(RR.ByID[401877] == nil, "retail does not carry Forever's Prayer of Mending ids")
    local camp = RF.ByID[1229741]
    check(camp and camp.class == "ALL" and camp.cats.utility, "Camp Benefits is all-class utility")
end

do  -- Missing Buffs: the four shared group buffs (retail keys) plus Forever's extras, every rank
    eq(#forever.RaidBuffs, 8, "Forever tracks eight raid buffs")
    local keys = {}
    for _, info in ipairs(forever.RaidBuffs) do keys[info[2]] = info end
    for _, k in ipairs({ "missingBuffCheckStamina", "missingBuffCheckIntellect",
                         "missingBuffCheckVersatility", "missingBuffCheckAttackPower" }) do
        check(keys[k] and type(keys[k][1]) == "table" and #keys[k][1] > 3, k .. " lists its ranks")
    end
    local fort = {}
    for _, id in ipairs(keys.missingBuffCheckStamina[1]) do fort[id] = true end
    check(fort[1243] and fort[10938] and fort[21562], "Fortitude counts rank 1, top rank and Prayer of Fortitude")
    eq(forever.ClassToRaidBuff.SHAMAN, nil, "no Shaman raid buff on Forever")
    eq(table.concat(forever.ClassToRaidBuff.PRIEST, ","), "missingBuffCheckStamina,missingBuffCheckSpirit",
       "Priest -> Fortitude and Divine Spirit")
    eq(table.concat(forever.ClassToRaidBuff.PALADIN, ","), "missingBuffCheckBlessing,missingBuffCheckSalvation",
       "Paladin -> a blessing and Salvation")
    eq(table.concat(forever.ClassToRaidBuff.DRUID, ","), "missingBuffCheckVersatility,missingBuffCheckThorns",
       "Druid -> Mark of the Wild and Thorns")
    -- the rules ride the entries
    check(keys.missingBuffCheckIntellect.manaOnly and keys.missingBuffCheckSpirit.manaOnly,
          "Arcane Intellect and Divine Spirit are mana users only")
    check(keys.missingBuffCheckSalvation.notTank, "Salvation is never checked on tanks")
    eq(keys.missingBuffCheckThorns.tankOption, "missingBuffThornsTankOnly", "Thorns has its tanks-only option")
    for _, k in ipairs({ "missingBuffCheckSpirit", "missingBuffCheckThorns", "missingBuffCheckSalvation", "missingBuffCheckBlessing" }) do
        check(keys[k] and keys[k].opt, k .. " is a Forever extra with its own switch")
    end
    check(not keys.missingBuffCheckStamina.opt, "the shared four are not extras")
    local bl = keys.missingBuffCheckBlessing
    local union = {}
    for _, id in ipairs(bl[1]) do union[id] = true end
    for part, first in pairs({ might = 19740, wisdom = 19742, kings = 20217 }) do
        eq(bl.blessings[part] and bl.blessings[part][1], first, "blessing: " .. part .. " leads with rank 1")
        for _, id in ipairs(bl.blessings[part] or {}) do
            check(union[id], "blessing: " .. part .. " " .. id .. " counts as blessed")
        end
    end
    check(union[25916] and union[25918] and union[25898], "blessing: the Greater blessings count")
    check(not union[1038], "blessing: Salvation is its own check, not a blessing")
end

-- ---- 2. the registry on Forever -----------------------------------
local RETAIL_STORE = {
    nextFilterID = 2,
    customFilters = { cf1 = { name = "Retail", spells = { [774] = true }, rawIDs = { [5] = true } } },
}
local function snapshot(t, seen)
    if type(t) ~= "table" then return tostring(t) end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
        local v = t[k]
        if v == nil then v = t[tonumber(k)] end
        out[#out + 1] = k .. "=" .. snapshot(v)
    end
    return "{" .. table.concat(out, ",") .. "}"
end

forever._global = { auraFilters = RETAIL_STORE }
function forever:GetGlobalDB() return self._global end
forever.db = {}
load_df_file_into("FilterRegistry/Registry.lua", forever)
local before = snapshot(RETAIL_STORE)

do  -- the store is keyed per version
    local s = RF:ReadStore()
    eq(countKeys(s.customFilters), 0, "Forever sees none of retail's filters")
    local id = RF:CreateCustomFilter("Mine")
    check(forever._global.auraFiltersForever and forever._global.auraFiltersForever.customFilters[id],
        "a Forever filter lands in auraFiltersForever")
    eq(snapshot(forever._global.auraFilters), before, "retail's store is byte-identical afterwards")

    eq(RF:AddSpellToCustom(id, 999001), "raw", "an id the database doesn't know is a raw id")
    eq(RF:AddSpellToCustom(id, 999001), "exists", "...and a repeat is reported")
    local list = RF:FilterSpellList(id)
    eq(#list, 1, "the custom filter lists its one id")
    eq(list[1] and list[1].raw, true, "...as a raw row")

    local cl = RF:FilterSpellList("tierSetAuras")
    check(type(cl) == "table" and #cl == 0, "an empty category lists {} (not nil)")
    check(#RF:FilterSpellList("healing") > 0, "a filled Forever category lists its spells")

    local f = RF:GetCustomFilter(id)
    check(f and f.rawIDs[999001] and not next(f.spells), "an unknown id stays raw")
end

do  -- rank numbers + labels
    eq(RF:GetSpellRank(139), 1, "Renew 139 is rank 1")
    eq(RF:GetSpellRank(425268), 1, "...and so is its second rank-1 id (a map, not list order)")
    eq(RF:GetSpellRank(25315), 10, "Renew 25315 is rank 10")
    eq(RF:GetSpellRank(1240849), 3, "Prayer of Mending 1240849 is rank 3")
    eq(RR.GetSpellRank and RR:GetSpellRank(139), nil, "retail has no ranks")
    forever.L = setmetatable({}, { __index = function(_, k) return k end })
    local prev = C_Spell
    C_Spell = { GetSpellSubtext = function() return nil end }   -- data not loaded yet
    eq(RF:FormatRankedName(6074, "Renew"), "Renew (Rank 2)", "falls back to the rank number")
    C_Spell = { GetSpellSubtext = function() return "Rang 2" end }
    eq(RF:FormatRankedName(6074, "Renew"), "Renew (Rang 2)", "prefers the client's own (localized) text")
    eq(RF:FormatRankedName(12042, "Arcane Power"), "Arcane Power", "a single-rank spell is left alone")
    C_Spell = prev
    eq(RF:FormatRankSpan(RF.ByID[139], "Renew"), "Renew (Ranks 1-10)", "a record shows its rank span")
    eq(RF:FormatRankSpan(RF.ByID[12042], "Arcane Power"), "Arcane Power", "...and a single-rank one doesn't")
end

-- ---- 3. the import prune -------------------------------------------
local prevCSpell = C_Spell
local function withSpells(existsFn, fn)
    C_Spell = { DoesSpellExist = existsFn }
    fn()
    C_Spell = prevCSpell
end

withSpells(function(id) return id == 6603 or id == 1459 end, function()
    local def = { spells = { [774] = true }, rawIDs = { [1459] = true, [999999] = true } }
    eq(RF:PruneForeignIDs(def), 2, "Forever prunes the two ids the client lacks")
    check(def.rawIDs[1459] and not def.rawIDs[999999] and not def.spells[774], "...and keeps the one it has")

    RF._lastImportPruned = 0
    local remap = RF:ImportCustomFilters({ x1 = { name = "Imported", spells = { [774] = true }, rawIDs = { [1459] = true } } })
    eq(RF._lastImportPruned, 1, "profile-import path counts its prune")
    local imported = RF:GetCustomFilter(remap.x1)
    -- 1459 is in the Forever database, so the import may promote it out of rawIDs
    check(imported and (imported.rawIDs[1459] or imported.spells[1459]) and not imported.spells[774],
        "imported filter holds only live ids")
end)

withSpells(function() return false end, function()
    local def = { spells = { [774] = true }, rawIDs = { [1459] = true } }
    eq(RF:PruneForeignIDs(def), 0, "an existence check that denies Auto Attack is not trusted")
    check(def.spells[774] and def.rawIDs[1459], "...so nothing is removed")
end)

withSpells(nil, function()
    C_Spell = {}   -- API missing entirely
    local def = { rawIDs = { [1459] = true } }
    eq(RF:PruneForeignIDs(def), 0, "no DoesSpellExist API: keep everything")
end)

do  -- retail never prunes
    local rns = { IS_FOREVER = nil, _global = {}, db = {} }
    function rns:GetGlobalDB() return self._global end
    load_df_file_into("FilterRegistry/SpellDB.lua", rns)
    load_df_file_into("FilterRegistry/Registry.lua", rns)
    withSpells(function(id) return id == 6603 end, function()
        local def = { rawIDs = { [999999] = true } }
        eq(rns.FilterRegistry:PruneForeignIDs(def), 0, "retail never prunes")
        check(def.rawIDs[999999], "...and keeps the id")
    end)
    rns.FilterRegistry:CreateCustomFilter("R")
    check(rns._global.auraFilters and not rns._global.auraFiltersForever, "retail keeps using auraFilters")
end
