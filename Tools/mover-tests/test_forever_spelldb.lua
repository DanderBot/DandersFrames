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
end

do  -- Missing Buffs: the four shared group buffs, every rank, under the retail keys
    eq(#forever.RaidBuffs, 4, "Forever tracks four raid buffs")
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
    eq(forever.ClassToRaidBuff.PRIEST, "missingBuffCheckStamina", "Priest -> Fortitude")
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
