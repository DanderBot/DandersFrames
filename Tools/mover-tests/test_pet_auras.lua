local NS = ...

-- ============================================================
-- GROUP PET FRAMES -- BUFF AND DEBUFF ROWS
-- Frames/Pets.lua PET AURA ROWS, cut out of the file and run against stub drives:
--   ✓ the settings view: pet keys answer the row keys, the forced keys win by
--     VALUE, everything else passes through, writes land on the mode table, and
--     a replaced mode table (profile swap) is picked up.
--   ✓ the routing: no container -> nothing; live rows drive or hide; preview
--     rows drive with the test count clamped by the row's Max; a new pet re-scans.
--   ✓ the settings sweep walks the set on screen, one set at a time.
--   ✓ the 14 defaults, the generated raid copy and the export category.
--   ✓ the Aura Designer guard: a pet frame never answers "AD on".
--   ✗ what the rows look like, and that a container really re-scans a resummoned
--     pet -- read in game.
-- ============================================================

local function cutBetween(text, from, to)
    local s = text:find(from, 1, true)
    local e = s and text:find(to, s, true)
    assert(s and e, "block not found: " .. from)
    return text:sub(s, e - 1)
end

local src = df_file_source("Frames/Pets.lua"):gsub("\r\n", "\n")
-- The file's own track names (the sweep compares against them).
local tracks = {}
for line in src:gmatch("(local PET_TRACK_[%u_]+%s*=%s*\"[%w%-]+\")") do tracks[#tracks + 1] = line end
check(#tracks == 5, "setup: the file's five track names")
tracks = table.concat(tracks, "\n")
local section = cutBetween(src, "local PET_AURA_MAP = {", "-- ============================================================\n-- APPLY PET SETTINGS")

local PET_KEYS = {
    "petShowBuffs", "petBuffMax", "petBuffSize", "petBuffAnchor", "petBuffGrowth", "petBuffOffsetX", "petBuffOffsetY",
    "petShowDebuffs", "petDebuffMax", "petDebuffSize", "petDebuffAnchor", "petDebuffGrowth", "petDebuffOffsetX", "petDebuffOffsetY",
}

-- ---- a fresh DF with stub drives ---------------------------------------------
local calls
local function newDF(supported)
    local DF = {}
    DF.petFrames, DF.partyPetFrames, DF.raidPetFrames, DF.arenaPetFrames = {}, {}, {}, {}
    DF.testPetFrames, DF.testRaidPetFrames = {}, {}
    DF.AuraContainer = { IsSupported = function() return supported end }
    DF.useFactory = true
    DF.track = "party"
    function DF:ActivePetTrack() return self.track end
    function DF:GetFrameDB(frame) return frame.modeDB end
    function DF:UseFactoryForBuffs() return self.useFactory end
    function DF:UseFactoryForDebuffs() return self.useFactory end
    local function handle(frame, kind)
        return {
            shown = true, testMax = nil, refreshed = 0,
            SetIntentShown = function(h, v) h.shown = v end,
            SetTestMax = function(h, n) h.testMax = n end,
            Refresh = function(h) h.refreshed = h.refreshed + 1 end,
        }
    end
    function DF:DriveBuffFactory(frame, db)
        calls[#calls + 1] = { "buff", frame, db }
        frame.buffFactory = frame.buffFactory or handle(frame, "buff")
        frame.buffFactory.shown = true
        frame.dfBuffFactoryShown = true
    end
    function DF:DriveDebuffFactory(frame, db)
        calls[#calls + 1] = { "debuff", frame, db }
        frame.debuffFactory = frame.debuffFactory or handle(frame, "debuff")
        frame.debuffFactory.shown = true
        frame.dfDebuffFactoryShown = true
    end
    assert(loadstring("local DF = ...\n" .. tracks .. "\n" .. section))(DF)
    return DF
end

local function mode(over)
    local t = {
        petShowBuffs = false, petBuffMax = 2, petBuffSize = 16, petBuffAnchor = "RIGHT",
        petBuffGrowth = "LEFT_DOWN", petBuffOffsetX = -30, petBuffOffsetY = 0,
        petShowDebuffs = true, petDebuffMax = 2, petDebuffSize = 16, petDebuffAnchor = "LEFT",
        petDebuffGrowth = "RIGHT_DOWN", petDebuffOffsetX = 2, petDebuffOffsetY = 0,
        -- the main rows' values the view must NOT hand a pet
        showBuffs = true, buffMax = 6, buffSize = 30, buffScale = 1.5, buffWrap = 3,
        showDebuffs = false, debuffMax = 5, debuffSize = 28, debuffImportantHighlight = true,
        buffCasterName = true, defensiveIconEnabled = true, missingBuffIconEnabled = true,
        buffDeduplicateDefensives = true,
        -- ...and the ones it must pass through
        directBuffShowAll = false, buffShowBorder = true, testBuffCount = 3, testDebuffCount = 4,
    }
    for k, v in pairs(over or {}) do t[k] = v end
    return t
end

local function petFrame(modeDB, extra)
    local f = { unit = "partypet1", modeDB = modeDB, isPetFrame = true, shownFlag = true }
    function f:IsShown() return self.shownFlag end
    for k, v in pairs(extra or {}) do f[k] = v end
    return f
end

-- ============================================================
print("-- Pet auras: the settings view")
do
    local DF = newDF(true)
    local m = mode()
    local f = petFrame(m)
    local v = DF:GetPetAuraDB(f)
    eq(v.showBuffs, false, "view: showBuffs is the pet's, not the main row's true")
    eq(v.buffMax, 2, "view: buffMax from petBuffMax")
    eq(v.buffWrap, 2, "view: buffWrap = petBuffMax -- one line")
    eq(v.buffSize, 16, "view: buffSize from petBuffSize")
    eq(v.buffAnchor, "RIGHT", "view: buffAnchor from petBuffAnchor")
    eq(v.buffGrowth, "LEFT_DOWN", "view: buffGrowth from petBuffGrowth")
    eq(v.buffOffsetX, -30, "view: buffOffsetX from petBuffOffsetX")
    eq(v.showDebuffs, true, "view: showDebuffs is the pet's, not the main row's false")
    eq(v.debuffAnchor, "LEFT", "view: debuffAnchor from petDebuffAnchor")
    eq(v.debuffWrap, 2, "view: debuffWrap = petDebuffMax")
    eq(v.buffScale, 1, "forced: scale 1")
    eq(v.debuffImportantHighlight, false, "forced: important-debuff enlarge off, though the main row has it on")
    eq(v.buffCasterName, false, "forced: no caster name")
    eq(v.defensiveIconEnabled, false, "forced: no defensive bar")
    eq(v.missingBuffIconEnabled, false, "forced: no missing-buff strip")
    eq(v.buffDeduplicateDefensives, false, "forced: no dedup (and so no Aura Designer tracked set)")
    eq(v.directBuffShowAll, false, "pass-through: filters follow the main row")
    eq(v.buffShowBorder, true, "pass-through: looks follow the main row")
    eq(v.testBuffCount, 3, "pass-through: the test panel's counts")
    check(DF:GetPetAuraDB(f) == v, "cache: the same view while the mode table is the same")

    v.buffSize = 20
    eq(m.petBuffSize, 20, "write: a row key lands on the pet key")
    eq(m.buffSize, 30, "write: ...and leaves the main row alone")
    v.someOther = 7
    eq(m.someOther, 7, "write: any other key lands on the mode table")

    local m2 = mode({ petBuffSize = 12 })
    f.modeDB = m2
    local v2 = DF:GetPetAuraDB(f)
    check(v2 ~= v, "swap: a replaced mode table builds a new view")
    eq(v2.buffSize, 12, "swap: ...reading the new table")
    eq(DF:GetPetAuraDB({ modeDB = nil }), nil, "no table: no view")
end

-- ============================================================
print("-- Pet auras: routing")
do
    -- No container on this client: nothing at all.
    local DF = newDF(false)
    calls = {}
    DF:UpdatePetAuras(petFrame(mode({ petShowBuffs = true })))
    eq(#calls, 0, "unsupported: no drive")

    -- Live: debuffs on, buffs off (the defaults).
    DF = newDF(true)
    calls = {}
    local f = petFrame(mode())
    DF:UpdatePetAuras(f)
    eq(#calls, 1, "live: one drive")
    eq(calls[1][1], "debuff", "live: ...the debuff row")
    check(calls[1][3] == DF:GetPetAuraDB(f), "live: the drive is handed the pet view, not the mode table")
    eq(f.buffFactory, nil, "live: no buff row is built while it is off")

    -- Turn buffs on, then off: the row hides through its intent.
    f.modeDB.petShowBuffs = true
    calls = {}
    DF:UpdatePetAuras(f)
    eq(#calls, 2, "live: both rows drive")
    f.modeDB.petShowBuffs = false
    calls = {}
    DF:UpdatePetAuras(f)
    eq(f.buffFactory.shown, false, "live: a row switched off is hidden through SetIntentShown")
    eq(f.dfBuffFactoryShown, false, "live: ...and the drive's shown-cache is reset")

    -- The factory path off (test mode / memory test): both rows dark.
    DF.useFactory = false
    calls = {}
    DF:UpdatePetAuras(f)
    eq(#calls, 0, "live in test mode: no drive")
    eq(f.debuffFactory.shown, false, "live in test mode: the debuff row hides")

    -- Preview pet: drives regardless of the live gate, count clamped by Max.
    calls = {}
    local t = petFrame(mode({ petShowBuffs = true, petBuffMax = 2, petDebuffMax = 6 }), { dfIsTestFrame = true })
    DF:UpdatePetAuras(t)
    eq(#calls, 2, "preview: both rows drive")
    eq(t.buffFactory.testMax, 2, "preview: test count 3 clamped to Max 2")
    eq(t.debuffFactory.testMax, 4, "preview: test count 4 under Max 6")
    t.modeDB.testShowAuras = false
    DF:UpdatePetAuras(t)
    eq(t.buffFactory.shown, false, "preview: Show Auras off hides the buff row")
    eq(t.debuffFactory.shown, false, "preview: ...and the debuff row")
    t.modeDB.testShowAuras = nil
    t.modeDB.petDebuffMax = 0
    calls = {}
    DF:UpdatePetAuras(t)
    eq(t.debuffFactory.shown, false, "preview: Max 0 hides the row instead of floor-to-one")

    -- A new pet behind the same token.
    DF:RefreshPetAuraRows(t)
    eq(t.buffFactory.refreshed, 1, "resummon: the buff row re-scans")
    eq(t.debuffFactory.refreshed, 1, "resummon: the debuff row re-scans")
    DF:RefreshPetAuraRows({})   -- no rows yet: nothing to do, no error
end

-- ============================================================
print("-- Pet auras: the settings sweep")
do
    local DF = newDF(true)
    local seen
    function DF:UpdatePetAuras(f) seen[#seen + 1] = f.tag end
    local function fr(tag, shown) return { tag = tag, IsShown = function() return shown end } end
    DF.petFrames.player = fr("player", true)
    DF.partyPetFrames[1] = fr("party1", true)
    DF.partyPetFrames[2] = fr("party2", false)
    DF.raidPetFrames[1] = fr("raid1", true)
    DF.arenaPetFrames[1] = fr("arena1", true)
    DF.testPetFrames[0] = fr("test0", true)
    DF.testRaidPetFrames[1] = fr("testraid1", true)

    seen = {}
    DF:RefreshPetAuras()
    eq(table.concat(seen, ","), "player,party1", "party: the shown party pets only")
    DF.track = "raid"
    seen = {}
    DF:RefreshPetAuras()
    eq(table.concat(seen, ","), "raid1", "raid: the raid set only")
    DF.track = "arena"
    seen = {}
    DF:RefreshPetAuras()
    eq(table.concat(seen, ","), "arena1", "arena: the arena set only")
    DF.testMode = true
    seen = {}
    DF:RefreshPetAuras()
    eq(table.concat(seen, ","), "test0", "party preview: the test pets only, no live set")
    DF.testMode, DF.raidTestMode = nil, true
    seen = {}
    DF:RefreshPetAuras()
    eq(table.concat(seen, ","), "testraid1", "raid preview: the test raid pets only")

    local auras = df_file_source("Features/Auras.lua")
    check(auras:find("if DF.RefreshPetAuras then DF:RefreshPetAuras() end", 1, true) ~= nil,
          "hook: every aura-row setting change (RefreshFactoryRows) re-drives the pets")
    check(src:find("DF:UpdatePetFrameTestMode(frame)\n        DF:SetPetFrameVisible(frame, true)\n        DF:UpdatePetAuras(frame)", 1, true) ~= nil,
          "hook: a preview pet drives its rows when shown")
    check(src:find("DF:UpdatePetPower(frame)\n        DF:SetPetFrameVisible(frame, true)\n        DF:UpdatePetAuras(frame)", 1, true) ~= nil,
          "hook: a live pet drives its rows when shown")
    check(src:find("DF:UpdatePetAuras(frame)\n                DF:RefreshPetAuraRows(frame)", 1, true) ~= nil,
          "hook: UNIT_PET re-scans the rows")
end

-- ============================================================
print("-- Pet auras: defaults and export")
do
    local saved = { CreateFrame = CreateFrame, GetLocale = GetLocale }
    local DF = {}
    CreateFrame = function() return FakeUIFrame() end
    GetLocale = function() return "enUS" end
    load_df_file_into("Core/Config.lua", DF)
    CreateFrame, GetLocale = saved.CreateFrame, saved.GetLocale
    for _, k in ipairs(PET_KEYS) do
        check(DF.PartyDefaults[k] ~= nil, "defaults: PartyDefaults has " .. k)
        eq(DF.RaidDefaults[k], DF.PartyDefaults[k], "defaults: the generated raid copy carries " .. k)
    end
    eq(DF.PartyDefaults.petShowDebuffs, true, "defaults: debuffs on")
    eq(DF.PartyDefaults.petShowBuffs, false, "defaults: buffs off")

    local exp = options_file_source("Core/ExportCategories.lua")
    for _, k in ipairs(PET_KEYS) do
        check(exp:find('"' .. k .. '",', 1, true) ~= nil, "export: " .. k .. " is in a category")
    end
    local petAt = exp:find('"petAnchor",', 1, true)
    local lastAt = exp:find('"petTexture",', 1, true)
    for _, k in ipairs(PET_KEYS) do
        local at = exp:find('"' .. k .. '",', 1, true)
        check(at and petAt and lastAt and at > petAt and at < lastAt, "export: " .. k .. " sits in the pet block")
    end
end

-- ============================================================
print("-- Pet auras: the Aura Designer guard")
do
    local ad = df_file_source("AuraDesigner/AuraAdapter.lua"):gsub("\r\n", "\n")
    local fn = cutBetween(ad, "function DF:IsAuraDesignerEnabled(frame)", "\nend\n") .. "\nend\n"
    local DF = {}
    function DF:IsAuraDesignerEnabledForMode() return true end
    function DF:DesignerFrameMode() return "party" end
    assert(loadstring("local DF = ...\n" .. fn))(DF)
    eq(DF:IsAuraDesignerEnabled({ isPetFrame = true }), false, "guard: a pet frame never draws AD, whatever the mode says")
    eq(DF:IsAuraDesignerEnabled({}), true, "guard: ...while a party frame still follows the mode")
end
