local NS = ...

-- ============================================================
-- DEFAULTS DIFF ENGINE -- DandersFrames/Core/Defaults.lua
-- ------------------------------------------------------------
-- The engine answers "is this stored setting still the shipped default", which
-- the settings UI turns into a modified-dot and a group reset. Everything worth
-- pinning here is a rule that fails SILENTLY in game -- a dot that never lights
-- up, or one that lights up on a setting nobody touched:
--
--   1. THE REAL DEFAULTS, NOT A FIXTURE. DF.RaidDefaults is GENERATED from
--      DF.PartyDefaults (Config.lua ~3050) -- deep copy, targetedList* stripped,
--      a handful of overrides applied. This suite loads the REAL Core/Config.lua
--      and asserts those generation facts, so a drift in the generator breaks
--      here rather than showing up as a raid dot that disagrees with party.
--   2. THE OVERLAY UNWRAP. With an auto-profile runtime overlay active,
--      DF.db.raid is a read-through PROXY and the stored table is DF._realRaidDB.
--      Comparing the proxy would mark every override as user-modified.
--   3. THE EPSILON. Float noise is not a change; one slider step is.
--   4. TABLE COMPARISON OVER THE UNION of keys -- colour tables are {r,g,b} in
--      some places and {r,g,b,a} in others, and "one side has an extra key" has
--      to count as different.
--   5. UNKNOWN TABLES ANSWER FALSE. A dot must never appear on a table the
--      engine cannot reason about.
--   6. NO WRITES. The engine is read-only; a stray write into DF.PartyDefaults
--      would rewrite the shipped default for the rest of the session.
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME ACROSS EVERY TEST FILE. Config.lua needs
-- CreateFrame / GetLocale and assigns the global `DandersFrames`; all three are
-- restored below.
-- ============================================================

local savedCreateFrame    = CreateFrame
local savedGetLocale      = GetLocale
local savedDandersFrames  = DandersFrames

-- ---- the engine, on top of the real shipped defaults ---------------
-- Config.lua loads clean headlessly with exactly two stubs: it builds one frame
-- for its ADDON_LOADED media registration and one for font validation, and it
-- picks an alphabet off GetLocale. Nothing else it does at file scope touches
-- the client.
local function loadEngine()
    local df = {}
    CreateFrame = function() return FakeUIFrame() end
    GetLocale = function() return "enUS" end
    load_df_file_into("Core/Config.lua", df)
    CreateFrame, GetLocale = savedCreateFrame, savedGetLocale
    DandersFrames = savedDandersFrames      -- Config.lua claims the global
    load_df_file_into("Core/Defaults.lua", df)
    return df
end

local DF = loadEngine()

local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = deepcopy(x) end
    return t
end

local function deepsame(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if not deepsame(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

-- A profile that is a byte-for-byte fresh install: every key at its default,
-- deep-copied so nothing shares a reference with the defaults tables.
local function freshProfile()
    local party, raid = {}, {}
    for k, v in pairs(DF.PartyDefaults) do party[k] = deepcopy(v) end
    for k, v in pairs(DF.RaidDefaults)  do raid[k]  = deepcopy(v) end
    DF.db = { party = party, raid = raid }
    DF._realRaidDB = nil
    return party, raid
end

-- ============================================================
-- THE ENGINE LOADED AT ALL
-- ============================================================
do
    check(type(DF.Defaults) == "table", "Core/Defaults.lua loaded and installed DF.Defaults")
    check(type(DF.Defaults.IsModified) == "function", "IsModified is there")
    check(type(DF.Defaults.DiffKeys) == "function", "DiffKeys is there")
    check(type(DF.Defaults.Count) == "function", "Count is there")
    check(type(DF.Defaults.GetDefault) == "function", "GetDefault is there")
end

-- ============================================================
-- THE RAID GENERATION IS THE REAL ONE
-- If any of these drift, every raid-side answer below is measuring the wrong
-- table and the suite should say so here rather than pass by accident.
-- ============================================================
do
    check(type(DF.PartyDefaults) == "table", "the real PartyDefaults loaded")
    check(type(DF.RaidDefaults) == "table", "the real RaidDefaults was generated")

    eq(DF.PartyDefaults.defensiveIconSize, 26, "party defensiveIconSize is 26")
    eq(DF.RaidDefaults.defensiveIconSize, 24, "raid overrides it to 24")
    eq(DF.PartyDefaults.defensiveBarMax, 4, "party defensiveBarMax is 4")
    eq(DF.RaidDefaults.defensiveBarMax, 3, "raid overrides it to 3")

    check(type(DF.RaidDefaults.position) == "table", "the table-valued position override landed")
    eq(DF.RaidDefaults.position.x, -6.666610717773438, "raid position.x")
    eq(DF.RaidDefaults.position.y, -25, "raid position.y")
    eq(DF.PartyDefaults.position.x, 0, "party position.x is untouched by it")
    eq(DF.PartyDefaults.position.y, -325, "party position.y is untouched by it")
    check(DF.RaidDefaults.position ~= DF.PartyDefaults.position,
        "and the two are separate tables, not one shared reference")

    local partyTL, raidTL = 0, 0
    for k in pairs(DF.PartyDefaults) do
        if k:sub(1, 12) == "targetedList" then partyTL = partyTL + 1 end
    end
    for k in pairs(DF.RaidDefaults) do
        if k:sub(1, 12) == "targetedList" then raidTL = raidTL + 1 end
    end
    check(partyTL > 0, "party ships the Targeted List family")
    eq(raidTL, 0, "and raid ships none of it")
    check(DF.RaidDefaults.testShowTargetedList == nil, "the named party-only straggler is stripped too")
    check(DF.PartyDefaults.testShowTargetedList ~= nil, "...and is still a party default")

    -- Inherited keys are deep-copied, not shared.
    check(DF.RaidDefaults.absorbBarColor ~= DF.PartyDefaults.absorbBarColor,
        "inherited table values are deep-copied per mode")
    check(deepsame(DF.RaidDefaults.absorbBarColor, DF.PartyDefaults.absorbBarColor),
        "...with equal contents")
end

-- ============================================================
-- SCALARS
-- ============================================================
do
    local party = freshProfile()
    local db = DF.db.party

    check(not DF.Defaults:IsModified(db, "absorbBarHeight"), "a fresh copy of a number default is unmodified")
    check(not DF.Defaults:IsModified(db, "absorbBarAnchor"), "...a string too")
    check(not DF.Defaults:IsModified(db, "absorbBarReverse"), "...and a boolean")

    party.absorbBarHeight = 9
    check(DF.Defaults:IsModified(db, "absorbBarHeight"), "a changed number is modified")

    party.absorbBarAnchor = "BOTTOMLEFT"
    check(DF.Defaults:IsModified(db, "absorbBarAnchor"), "a changed string is modified")

    party.absorbBarReverse = true
    check(DF.Defaults:IsModified(db, "absorbBarReverse"), "a flipped boolean is modified")

    -- Type mismatch is a difference, never an error.
    party.absorbBarHeight = "7"
    check(DF.Defaults:IsModified(db, "absorbBarHeight"), "a number default stored as a string is modified")
end

-- ============================================================
-- FLOAT EPSILON
-- ============================================================
do
    local party = freshProfile()
    local db = DF.db.party
    local base = DF.PartyDefaults.aggroHighlightAlpha
    check(type(base) == "number", "the float default under test is a number")

    party.aggroHighlightAlpha = base
    check(not DF.Defaults:IsModified(db, "aggroHighlightAlpha"), "the exact float default is unmodified")

    party.aggroHighlightAlpha = base + 5e-7
    check(not DF.Defaults:IsModified(db, "aggroHighlightAlpha"), "float noise under the epsilon is unmodified")

    party.aggroHighlightAlpha = base - 5e-7
    check(not DF.Defaults:IsModified(db, "aggroHighlightAlpha"), "...in either direction")

    party.aggroHighlightAlpha = base + 1e-3
    check(DF.Defaults:IsModified(db, "aggroHighlightAlpha"), "a real change above the epsilon is modified")

    -- NaN: equal to nothing, including itself, unless both sides are NaN.
    local nan = 0 / 0
    party.aggroHighlightAlpha = nan
    check(DF.Defaults:IsModified(db, "aggroHighlightAlpha"), "a stored NaN against a number default is modified")
end

-- ============================================================
-- COLOUR TABLES
-- ============================================================
do
    local party = freshProfile()
    local db = DF.db.party
    local def = DF.PartyDefaults.fontShadowColor
    check(type(def) == "table" and def.a ~= nil, "the colour default under test is an {r,g,b,a} table")

    party.fontShadowColor = { r = def.r, g = def.g, b = def.b, a = def.a }
    check(not DF.Defaults:IsModified(db, "fontShadowColor"), "a value-equal copy of a colour is unmodified")

    party.fontShadowColor = { r = def.r, g = def.g, b = def.b, a = def.a }
    party.fontShadowColor.r = (def.r or 0) + 0.5
    check(DF.Defaults:IsModified(db, "fontShadowColor"), "a changed channel is modified")

    party.fontShadowColor = { r = def.r, g = def.g, b = def.b, a = def.a, custom = true }
    check(DF.Defaults:IsModified(db, "fontShadowColor"), "an extra key on the stored side is modified")

    party.fontShadowColor = { r = def.r, g = def.g, b = def.b }
    check(DF.Defaults:IsModified(db, "fontShadowColor"), "a missing key on the stored side is modified")

    party.fontShadowColor = "not a table"
    check(DF.Defaults:IsModified(db, "fontShadowColor"), "a table default stored as a scalar is modified")
end

-- ============================================================
-- NESTED TABLES
-- ============================================================
do
    local party = freshProfile()
    local db = DF.db.party
    check(type(DF.PartyDefaults.auraDesigner) == "table", "the nested default under test exists")
    check(type(DF.PartyDefaults.auraDesigner.defaults) == "table", "...and is genuinely nested")

    check(not DF.Defaults:IsModified(db, "auraDesigner"), "a deep copy of a nested default is unmodified")

    party.auraDesigner.defaults.iconSize = DF.PartyDefaults.auraDesigner.defaults.iconSize + 4
    check(DF.Defaults:IsModified(db, "auraDesigner"), "a change two levels down is modified")

    party.auraDesigner = deepcopy(DF.PartyDefaults.auraDesigner)
    check(not DF.Defaults:IsModified(db, "auraDesigner"), "and restoring it clears again")

    party.auraDesigner.defaults.somethingNew = 1
    check(DF.Defaults:IsModified(db, "auraDesigner"), "an added nested key is modified")
end

-- ============================================================
-- PARTY VS RAID DIVERGENCE
-- The same stored value answers differently per mode, which is the whole point
-- of resolving the defaults table off the db rather than off the key.
-- ============================================================
do
    local party, raid = freshProfile()

    party.defensiveIconSize = 26
    raid.defensiveIconSize  = 26
    check(not DF.Defaults:IsModified(DF.db.party, "defensiveIconSize"), "26 is the party default -- unmodified")
    check(DF.Defaults:IsModified(DF.db.raid, "defensiveIconSize"), "the same 26 is modified for raid (default 24)")

    raid.defensiveIconSize = 24
    check(not DF.Defaults:IsModified(DF.db.raid, "defensiveIconSize"), "and 24 is unmodified for raid")

    -- A party-only key stored on the raid side is not a shipped raid setting,
    -- so it never lights up however far it is from the party value.
    raid.targetedListBackgroundAlpha = 0.99
    check(DF.PartyDefaults.targetedListBackgroundAlpha ~= nil, "the party-only key is a party default")
    check(DF.RaidDefaults.targetedListBackgroundAlpha == nil, "...and not a raid one")
    check(not DF.Defaults:IsModified(DF.db.raid, "targetedListBackgroundAlpha"),
        "a party-only key on a raid db is never modified")
    party.targetedListBackgroundAlpha = 0.99
    check(DF.Defaults:IsModified(DF.db.party, "targetedListBackgroundAlpha"),
        "...while the party db still answers about it")
end

-- ============================================================
-- GetDefault
-- ============================================================
do
    eq(DF.Defaults:GetDefault("party", "defensiveBarMax"), 4, "GetDefault party -> the party value")
    eq(DF.Defaults:GetDefault("raid", "defensiveBarMax"), 3, "GetDefault raid -> the GENERATED override")
    eq(DF.Defaults:GetDefault("raid", "defensiveIconSize"), 24, "...and the second override")
    eq(DF.Defaults:GetDefault("party", "absorbBarHeight"),
       DF.Defaults:GetDefault("raid", "absorbBarHeight"), "an un-overridden key matches in both modes")
    check(DF.Defaults:GetDefault("raid", "targetedListBackgroundAlpha") == nil,
        "a party-only key has no raid default")
    check(DF.Defaults:GetDefault("party", "noSuchSettingAnywhere") == nil, "an unknown key has no default")
    check(DF.Defaults:GetDefault("raid", "position") == DF.RaidDefaults.position,
        "the return is the live reference, as documented")
end

-- ============================================================
-- THE OVERLAY UNWRAP
-- DF.db.raid is a read-through VIEW while a runtime auto profile is active. The
-- answer has to come from DF._realRaidDB underneath it.
-- ============================================================
do
    local _, raid = freshProfile()

    -- The stored table is modified; the overlay hides that behind the default.
    raid.defensiveBarMax = 8
    local overrides = { defensiveBarMax = DF.RaidDefaults.defensiveBarMax }
    local overlay = setmetatable({}, {
        __index = function(_, key)
            if overrides[key] ~= nil then return overrides[key] end
            return DF._realRaidDB[key]
        end,
    })
    DF._realRaidDB = raid
    DF.db.raid = overlay

    eq(overlay.defensiveBarMax, DF.RaidDefaults.defensiveBarMax, "the overlay really does hide the stored value")
    check(DF.Defaults:IsModified(DF.db.raid, "defensiveBarMax"),
        "IsModified answers from _realRaidDB, not the overlay view")
    check(DF.Defaults:IsModified(DF._realRaidDB, "defensiveBarMax"),
        "the real table handed in directly answers the same")

    -- ...and the reverse: an override that DIFFERS from the default must not
    -- light up a setting the user never touched.
    raid.absorbBarHeight = DF.RaidDefaults.absorbBarHeight
    overrides.absorbBarHeight = DF.RaidDefaults.absorbBarHeight + 12
    check(not DF.Defaults:IsModified(DF.db.raid, "absorbBarHeight"),
        "a runtime override is not a user modification")

    local d = DF.Defaults:DiffKeys(DF.db.raid, { "defensiveBarMax", "absorbBarHeight" })
    check(d.defensiveBarMax ~= nil, "DiffKeys unwraps the overlay too")
    check(d.absorbBarHeight == nil, "...and ignores the override-only key")
    eq(d.defensiveBarMax.current, 8, "the current value is the STORED one")
    eq(DF.Defaults:Count(DF.db.raid, { "defensiveBarMax", "absorbBarHeight" }), 1, "Count agrees")

    DF._realRaidDB = nil
end

-- ============================================================
-- UNKNOWN TABLES, MISSING VALUES, UNKNOWN KEYS
-- ============================================================
do
    local party = freshProfile()

    local stranger = { absorbBarHeight = 999 }
    check(not DF.Defaults:IsModified(stranger, "absorbBarHeight"), "an unknown table is never modified")
    check(next(DF.Defaults:DiffKeys(stranger, { "absorbBarHeight" })) == nil, "DiffKeys returns {} for it")
    eq(DF.Defaults:Count(stranger, { "absorbBarHeight" }), 0, "Count returns 0 for it")

    check(not DF.Defaults:IsModified(nil, "absorbBarHeight"), "nil is never modified")
    eq(DF.Defaults:Count(nil, { "absorbBarHeight" }), 0, "...and counts 0")
    check(not DF.Defaults:IsModified("party", "absorbBarHeight"), "a non-table is never modified")

    party.absorbBarHeight = nil
    check(not DF.Defaults:IsModified(DF.db.party, "absorbBarHeight"),
        "a stored value that is missing entirely is not reported as modified")

    check(not DF.Defaults:IsModified(DF.db.party, "noSuchSettingAnywhere"),
        "a key that is not a shipped default is not modified")
    party.noSuchSettingAnywhere = 12
    check(not DF.Defaults:IsModified(DF.db.party, "noSuchSettingAnywhere"),
        "...even when the profile carries a value for it")
end

-- ============================================================
-- DiffKeys / Count SHAPE
-- ============================================================
do
    local party = freshProfile()
    local db = DF.db.party
    local keys = { "absorbBarHeight", "absorbBarAnchor", "absorbBarReverse", "fontShadowColor", "noSuchSettingAnywhere" }

    eq(DF.Defaults:Count(db, keys), 0, "a fresh profile counts zero modified")
    check(next(DF.Defaults:DiffKeys(db, keys)) == nil, "...and diffs to an empty table")

    party.absorbBarHeight = 21
    party.fontShadowColor = { r = 1, g = 1, b = 1, a = 1 }

    local d = DF.Defaults:DiffKeys(db, keys)
    local n = 0
    for _ in pairs(d) do n = n + 1 end
    eq(n, 2, "only the modified keys are present")
    eq(DF.Defaults:Count(db, keys), n, "Count agrees with the diff size")

    eq(d.absorbBarHeight.current, 21, "current is the stored value")
    eq(d.absorbBarHeight.default, DF.PartyDefaults.absorbBarHeight, "default is the shipped value")
    check(d.fontShadowColor.current == party.fontShadowColor, "table values come back by reference")
    check(d.fontShadowColor.default == DF.PartyDefaults.fontShadowColor, "...on both sides")
    check(d.absorbBarAnchor == nil, "an unmodified key is absent")
    check(d.noSuchSettingAnywhere == nil, "an unknown key is absent")

    eq(DF.Defaults:Count(db, {}), 0, "an empty key list counts zero")
    check(next(DF.Defaults:DiffKeys(db, {})) == nil, "...and diffs empty")
    eq(DF.Defaults:Count(db, nil), 0, "a nil key list counts zero")
    check(next(DF.Defaults:DiffKeys(db, nil)) == nil, "...and diffs empty")
end

-- ============================================================
-- THE ENGINE WRITES NOTHING
-- Not the profile, not the defaults. A stray write into DF.PartyDefaults would
-- rewrite the shipped default for the rest of the session and every later
-- comparison would agree with the damage.
-- ============================================================
do
    local party, raid = freshProfile()
    party.absorbBarHeight = 33
    raid.defensiveIconSize = 99
    party.fontShadowColor.r = 0.25

    local keys = {}
    for k in pairs(DF.PartyDefaults) do keys[#keys + 1] = k end

    local partyBefore    = deepcopy(party)
    local raidBefore     = deepcopy(raid)
    local pDefaultsBefore = deepcopy(DF.PartyDefaults)
    local rDefaultsBefore = deepcopy(DF.RaidDefaults)

    -- A full pass over every shipped key, through all four publics.
    for i = 1, #keys do
        DF.Defaults:IsModified(DF.db.party, keys[i])
        DF.Defaults:IsModified(DF.db.raid, keys[i])
        DF.Defaults:GetDefault("party", keys[i])
        DF.Defaults:GetDefault("raid", keys[i])
    end
    DF.Defaults:DiffKeys(DF.db.party, keys)
    DF.Defaults:DiffKeys(DF.db.raid, keys)
    DF.Defaults:Count(DF.db.party, keys)
    DF.Defaults:Count(DF.db.raid, keys)

    check(deepsame(party, partyBefore), "the stored party table is untouched by a full pass")
    check(deepsame(raid, raidBefore), "the stored raid table is untouched")
    check(deepsame(DF.PartyDefaults, pDefaultsBefore), "PartyDefaults is untouched")
    check(deepsame(DF.RaidDefaults, rDefaultsBefore), "RaidDefaults is untouched")
    eq(DF.PartyDefaults.defensiveIconSize, 26, "...spot-check: the party default did not move")
    eq(DF.RaidDefaults.defensiveIconSize, 24, "...spot-check: nor did the raid override")
end

CreateFrame   = savedCreateFrame
GetLocale     = savedGetLocale
DandersFrames = savedDandersFrames
