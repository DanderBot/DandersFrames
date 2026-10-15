local NS = ...

-- ============================================================
-- BUFF BAR: HIDE DUPLICATE BUFFS HIDES ONLY YOUR OWN CASTS OF A MY BUFFS SPELL
-- DandersFrames/Features/Auras.lua  SplitBuffRowForOwnCasts
-- ------------------------------------------------------------
-- My Buffs renders "HELPFUL|PLAYER". An id it tracks may be hidden from the buff bar
-- only for your casts, or another player's copy shows nowhere. The real helper is
-- lifted by name and run on plain tables.
-- ============================================================

print("-- Buff Bar: Hide Duplicate Buffs keeps other players' casts")

local src = df_file_source("Features/Auras.lua"):gsub("\r\n", "\n")
local a = src:find("local function SplitBuffRowForOwnCasts(", 1, true)
local b = src:find("function DF:BuildAuraRowConfig(", 1, true)
check(a ~= nil and b ~= nil and a < b, "split: the helper sits above the row builder")
if not (a and b) then return end
local stop = src:find("\nend\n", a, true)
local split = assert(loadstring(src:sub(a, stop + 4) .. "\nreturn SplitBuffRowForOwnCasts"))()

local REJUV, SHIELD, OTHER = 774, 17, 1126

-- ---- nothing mine-only: the row is untouched -------------------------------------
do
    local f, cf = { "HELPFUL" }, { excludeSpellIDs = { [OTHER] = true } }
    local f2, cf2 = split(f, cf, nil)
    check(f2 == f and cf2 == cf, "none: no mine-only ids leaves filter and candidates as they were")
end

-- ---- Only Mine off: split into your casts and everyone else's ------------------------
do
    local cf = { excludeSpellIDs = { [OTHER] = true } }
    local f2, cf2 = split({ "HELPFUL" }, cf, { [REJUV] = true })
    check(type(f2) == "table" and #f2 == 2, "split: two records")
    local mine, others = f2[1], f2[2]
    eq(mine.filter, "HELPFUL|PLAYER", "split: the first record is your casts")
    eq(mine.key, "mine", "split: ...keyed mine")
    check(mine.candidateFilters.excludeSpellIDs[REJUV] and mine.candidateFilters.excludeSpellIDs[OTHER],
          "split: ...hiding the My Buffs id and keeping the shared excludes")
    eq(others.filter, "HELPFUL|!PLAYER", "split: the second record is everyone else's casts")
    eq(others.key, "others", "split: ...keyed others")
    check(not others.candidateFilters.excludeSpellIDs[REJUV],
          "split: ...where another player's copy of the My Buffs spell still shows")
    check(others.candidateFilters.excludeSpellIDs[OTHER],
          "split: ...and the any-caster excludes still apply")
    check(cf.excludeSpellIDs[REJUV] == nil, "split: the caller's candidate table is not mutated")
end

-- ---- Only Mine on: one record, the id simply excluded --------------------------------
do
    local f = { "HELPFUL|PLAYER" }
    local f2, cf2 = split(f, nil, { [REJUV] = true })
    check(f2 == f, "only mine: the filter list stays a single record")
    check(cf2 and cf2.excludeSpellIDs and cf2.excludeSpellIDs[REJUV], "only mine: the id is excluded")
end

-- ---- include mode: subtract from the include list instead -------------------------
do
    local cf = { includeSpellIDs = { [REJUV] = true, [SHIELD] = true } }
    local f2 = split({ "HELPFUL" }, cf, { [REJUV] = true })
    local mineCf, othersCf = f2[1].candidateFilters, f2[2].candidateFilters
    check(not mineCf.includeSpellIDs[REJUV] and mineCf.includeSpellIDs[SHIELD],
          "include: your half drops the My Buffs id from the include list")
    check(mineCf.excludeSpellIDs == nil, "include: ...without growing an exclude list beside it")
    check(othersCf.includeSpellIDs[REJUV], "include: others' half keeps it")
end

-- ---- a negated PLAYER is not Only Mine ---------------------------------------------
do
    local f2 = split({ "HELPFUL|!PLAYER" }, nil, { [REJUV] = true })
    eq(#f2, 2, "negation: !PLAYER is not read as Only Mine")
end

-- ---- the factory returns the two maps separately ----------------------------------
do
    local fac = df_file_source("AuraDesigner/Factory.lua"):gsub("\r\n", "\n")
    check(fac:find("return union, mineOnly", 1, true) ~= nil,
          "factory: GetADTrackedSpellIDs returns the any-caster and mine-only maps")
    check(fac:find("for id in pairs(union) do mineOnly[id] = nil end", 1, true) ~= nil,
          "factory: ...and an id shown for any caster is not also mine-only")
end

-- ---- the split row opts out of the visibility latch --------------------------------
-- Out of your world both halves fail open (an aura shows once, or a tracked one twice);
-- the latch would blank the whole row, other players' buffs included.
do
    local f2 = split({ "HELPFUL" }, nil, { [REJUV] = true })
    check(f2[1].noVisLatch == true and f2[2].noVisLatch == true, "latch: both halves opt out")
    local ac = df_file_source("Frames/AuraContainer.lua"):gsub("\r\n", "\n")
    check(ac:find("noVisLatch = f.noVisLatch", 1, true) ~= nil,
          "latch: normalizeFilters carries the opt-out through")
    local _, n = ac:gsub("if not rec%.noVisLatch and filterSourceRelative%(", "")
    eq(n, 2, "latch: both source-relative stamps honour it")
end

-- ---- every included id is mine-only: no empty include list on your half -----------
do
    local cf = { includeSpellIDs = { [REJUV] = true } }
    local f2 = split({ "HELPFUL" }, cf, { [REJUV] = true })
    eq(#f2, 1, "empty include: your half is dropped rather than sent an empty list")
    eq(f2[1].key, "others", "empty include: ...others' half stays")
    check(f2[1].candidateFilters.includeSpellIDs[REJUV], "empty include: ...and still shows their copies")
end
