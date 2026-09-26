-- ============================================================
-- WOW FOREVER SPELL DATABASE + PER-VERSION FILTER STORE
--   DandersFrames/FilterRegistry/SpellDB.lua   (empty on Forever)
--   DandersFrames/FilterRegistry/Registry.lua  (store key, PruneForeignIDs)
-- Both loaded REAL.
-- ============================================================

local function loadDB(isForever)
    local ns = { IS_FOREVER = isForever or nil }
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

do  -- Forever ships nothing, but every shared shape survives
    eq(#RF.Spells, 0, "Forever ships no records")
    eq(countKeys(RF.ByID), 0, "Forever ByID is empty")
    eq(countKeys(RF.Excluded), 0, "Forever has no exclusions")
    eq(countKeys(RF.CategoryPatch), 0, "Forever has no category patch")
    eq(RF.DBStamp.flavor, "forever", "Forever stamp is marked")
    check(RF.DBStamp.gameBuild == nil and RF.DBStamp.harvest == nil,
        "Forever stamp has no harvest/build (the Options label must branch, not format them)")
    eq(#RF.Categories, #RR.Categories, "Forever keeps every category")
    for i, cat in ipairs(RR.Categories) do
        eq(RF.Categories[i] and RF.Categories[i].key, cat.key, "category " .. i .. " key matches retail")
        local bucket = RF.ByCategory[cat.key]
        check(type(bucket) == "table" and #bucket == 0,
            "Forever category '" .. cat.key .. "' exists and is empty (not nil: nil means 'deleted')")
    end
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

    eq(RF:AddSpellToCustom(id, 1459), "raw", "with no database every add is a raw id")
    eq(RF:AddSpellToCustom(id, 1459), "exists", "...and a repeat is reported")
    local list = RF:FilterSpellList(id)
    eq(#list, 1, "the custom filter lists its one id")
    eq(list[1] and list[1].raw, true, "...as a raw row")

    local catKey = RR.Categories[1].key
    local cl = RF:FilterSpellList(catKey)
    check(type(cl) == "table" and #cl == 0, "an empty category lists {} (not nil)")

    local f = RF:GetCustomFilter(id)
    check(f and f.rawIDs[1459] and not next(f.spells), "no promotion out of rawIDs with an empty database")
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
    check(imported and imported.rawIDs[1459] and not imported.spells[774], "imported filter holds only live ids")
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
