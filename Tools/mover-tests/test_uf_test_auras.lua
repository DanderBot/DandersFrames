local NS = ...

-- ============================================================
-- UNIT FRAMES -- TEST AURAS ON THE PREVIEW FRAMES
-- What each unit frame preview's buff and debuff rows draw: the REAL test-mode
-- seam (DF:UpdateTestAuras, cut out of TestMode.lua) deciding which rows run and
-- their preview count, on the REAL preview settings table (Preview.lua's
-- P:PreviewDB over the real unit defaults), and the REAL sample pool and window
-- maths (DF.TestData; AuraContainer's testSlotCount / testPoolOffset) deciding
-- which samples fill them. Headless: no frame is built, so what it looks like is
-- for the game to say.
-- ============================================================

local saved = { DandersFrames = DandersFrames, CreateFrame = CreateFrame, GetLocale = GetLocale }

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

-- A top-level block cut out of a source file: from `marker` to the first line
-- that is exactly `closer` after it.
local function cut(src, marker, closer)
    src = src:gsub("\r\n", "\n")
    local s = src:find(marker, 1, true)
    assert(s, "marker not found: " .. marker)
    local e = src:find("\n" .. closer .. "\n", s, true)
    assert(e, "closer not found after: " .. marker)
    return src:sub(s, e + #closer)
end

-- ---- DandersFrames: the real defaults ----------------------------------------
local DF = {}
CreateFrame = function() return FakeUIFrame() end
GetLocale = function() return "enUS" end
load_df_file_into("Core/Config.lua", DF)
DandersFrames = DF
DF.L = setmetatable({}, { __index = function(_, k) return k end })
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable(key, spec) DF.rootSpec = spec; return true end
DF.RegisterCallback = function() end

-- The test-mode tables the panel writes (party and raid profile tables).
local party, raid = deepcopy(DF.PartyDefaults), deepcopy(DF.PartyDefaults)
function DF:GetDB() return party end
function DF:GetRaidDB() return raid end

-- ---- the companion ------------------------------------------------------------
CreateFrame = nil
local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Links.lua", UF)
load_uf_file_into("Defaults.lua", UF)
load_uf_file_into("Preview.lua", UF)
DF.db = { unitframes = deepcopy(UF.ProfileDefaults) }
local P = UF.Preview

-- ---- the real seam and the real window maths ----------------------------------
local tm = options_file_source("TestMode/TestMode.lua")
assert(loadstring("local DF = ...\n" .. cut(tm, "DF.TestData = {", "}")))(DF)
assert(loadstring("local DF = ...\n" .. cut(tm, "function DF:UpdateTestAuras(frame)", "end")))(DF)
local ac = df_file_source("Frames/AuraContainer.lua"):gsub("\r\n", "\n")
local function liftTo(text, from, to)
    local s = text:find(from, 1, true)
    local e = s and text:find(to, s, true)
    assert(s and e, "block not found: " .. from)
    return text:sub(s, e - 1)
end
local testSlotCount = assert(loadstring(cut(ac, "local function testSlotCount(config, pool)", "end")
    .. "\nreturn testSlotCount"))()
local testPoolOffset = assert(loadstring(liftTo(ac, "local function gcd(a, b)", "\nlocal Handle = {}")
    .. "\nreturn testPoolOffset"))()
check(type(DF.UpdateTestAuras) == "function" and type(DF.TestData) == "table", "setup: the real seam and pool")

-- The seam's collaborators: a supported engine, the frame's own table, and drives
-- that record what they were asked for (the rows' config is BuildAuraRowConfig's:
-- max = <prefix>Max, testMax, unit, testSeed).
DF.AuraContainer = { IsSupported = function() return true end }
function DF:GetFrameDB(f) return f.dfDB end
function DF:IsTestFrameDead() return false end
local function Handle(row)
    return {
        SetTestMax = function(_, n) row.testMax = n end,
        SetIntentShown = function(_, on) row.shown = on end,
    }
end
function DF:DriveBuffFactory(f, db)
    f.rows.buff = f.rows.buff or {}
    f.rows.buff.driven, f.rows.buff.shown, f.rows.buff.max = true, true, db.buffMax
    f.buffFactory = f.buffFactory or Handle(f.rows.buff)
end
function DF:DriveDebuffFactory(f, db)
    f.rows.debuff = f.rows.debuff or {}
    f.rows.debuff.driven, f.rows.debuff.shown, f.rows.debuff.max = true, true, db.debuffMax
    f.debuffFactory = f.debuffFactory or Handle(f.rows.debuff)
end

-- A preview frame as P:Build stamps it (test_uf_preview pins Build itself).
local function Preview(unit, slot)
    return { dfUFPreview = true, dfPreview = true, dfIsTestFrame = true, dfUFUnit = unit,
             unit = slot and (unit .. slot) or unit, dfDB = P:PreviewDB(unit),
             dfTestAuraSeed = P.AURA_SEEDS[unit], rows = {} }
end

-- What a driven row draws: the container's preview slot count and pool window.
local function Drawn(f, prefix)
    local row = f.rows[prefix]
    if not (row and row.driven and row.shown) then return nil end
    local pool = (prefix == "debuff") and DF.TestData.debuffs or DF.TestData.buffs
    local config = { unit = f.unit, testSeed = f.dfTestAuraSeed, max = row.max, testMax = row.testMax }
    local n = testSlotCount(config, pool)
    local off = testPoolOffset(config, #pool, n)
    local out = {}
    for i = 1, n do out[i] = pool[((off + i - 1) % #pool) + 1] end
    return out
end

local UNITS = { "player", "target", "targettarget", "focus", "focustarget", "pet" }
local function PaintAll()
    local frames = {}
    for _, u in ipairs(UNITS) do frames[u] = Preview(u) end
    for i = 1, 5 do frames["boss" .. i] = Preview("boss", i) end
    for _, f in pairs(frames) do DF:UpdateTestAuras(f) end
    return frames
end

-- ============================================================
print("-- Test auras: Show Auras off (the default) shows none")
do
    eq(party.testShowAuras, false, "the test panel's Show Auras is off by default")
    local frames = PaintAll()
    for key, f in pairs(frames) do
        eq(Drawn(f, "buff"), nil, key .. ": no buff row")
        eq(Drawn(f, "debuff"), nil, key .. ": no debuff row")
    end
end

print("-- Test auras: Show Auras on, the counts honour each unit's max")
do
    party.testShowAuras, party.testBuffCount, party.testDebuffCount = true, 5, 5
    local frames = PaintAll()
    local function count(key, prefix)
        local d = Drawn(frames[key], prefix)
        return d and #d or 0
    end
    eq(count("player", "buff"), 0, "player: buffs off, no row")
    eq(count("player", "debuff"), 5, "player: 5 debuffs (count 5, max 5)")
    eq(count("target", "buff"), 5, "target: 5 buffs (count 5 under max 8)")
    eq(count("target", "debuff"), 5, "target: 5 debuffs")
    eq(count("focus", "buff"), 0, "focus: buffs off, no row")
    eq(count("focus", "debuff"), 5, "focus: 5 debuffs")
    eq(count("pet", "debuff"), 4, "pet: 4 debuffs (count 5, capped by max 4)")
    eq(count("pet", "buff"), 0, "pet: no buffs")
    for _, u in ipairs({ "targettarget", "focustarget" }) do
        eq(count(u, "buff") + count(u, "debuff"), 0, u .. ": no aura rows")
    end
    for i = 1, 5 do
        eq(count("boss" .. i, "debuff"), 4, "boss" .. i .. ": 4 debuffs (capped by max 4)")
        eq(count("boss" .. i, "buff"), 0, "boss" .. i .. ": buffs off")
    end

    -- A unit's own max below the count wins, and so does a count below the max.
    UF:GetStoredUnit("target").buffMax = 2
    frames = PaintAll()
    eq(count("target", "buff"), 2, "target with Max Buffs 2: 2 buffs")
    UF:GetStoredUnit("target").buffMax = nil
    party.testBuffCount = 1
    frames = PaintAll()
    eq(count("target", "buff"), 1, "test count 1: 1 buff")
    party.testDebuffCount = 0
    frames = PaintAll()
    eq(count("target", "debuff"), 0, "test count 0: the debuff row is hidden, as on group frames")
end

print("-- Test auras: at the default count every debuff type, stacks and timers show")
do
    party.testBuffCount, party.testDebuffCount = 2, 2
    local frames = PaintAll()
    local types, stacks, durations, windows = {}, 0, {}, {}
    local short, long, permanent = false, false, false
    for key, f in pairs(frames) do
        for _, prefix in ipairs({ "buff", "debuff" }) do
            local d = Drawn(f, prefix)
            if d then
                local names = {}
                for _, e in ipairs(d) do
                    if prefix == "debuff" then types[e.debuffType or "none"] = true end
                    if (e.stacks or 0) > 1 then stacks = stacks + 1 end
                    durations[e.duration] = true
                    if e.duration > 0 and e.duration <= 5 then short = true end
                    if e.duration >= 600 then long = true end
                    if e.duration == 0 then permanent = true end
                    names[#names + 1] = e.name
                end
                windows[key .. ":" .. prefix] = table.concat(names, ",")
            end
        end
    end
    for _, t in ipairs({ "Magic", "Curse", "Disease", "Poison", "Bleed", "none" }) do
        check(types[t], "debuff type shown somewhere: " .. t)
    end
    check(stacks >= 1, "a stacked sample shows")
    local nd = 0
    for _ in pairs(durations) do nd = nd + 1 end
    check(nd >= 5, "varied durations (" .. nd .. " different)")
    check(short, "a short one that runs out and restarts")
    check(long, "a long one (minutes)")
    check(windows["player:debuff"] ~= windows["target:debuff"], "player and target show different debuffs")
    check(windows["target:debuff"] ~= windows["focus:debuff"], "target and focus too")
    -- Target's row is not narrowed to your own debuffs: the preview draws the pool
    -- (the filters choose live auras, not samples), so it is a mix by construction.
    eq(UF:GetUnitDB("target").debuffFilterMine, true, "target's live debuff row shows yours only")
    check(Drawn(frames.target, "debuff") ~= nil, "...while its preview still draws samples")
end

print("-- Test auras: raid test mode's switches")
do
    party.testShowAuras = true
    raid.testShowAuras = false
    DF.raidTestMode = true
    local frames = PaintAll()
    eq(Drawn(frames.target, "buff"), nil, "raid test mode up with its Show Auras off: no rows")
    raid.testShowAuras, raid.testDebuffCount = true, 3
    frames = PaintAll()
    eq(#Drawn(frames.target, "debuff"), 3, "...on, with the raid table's count")
    DF.raidTestMode = nil
end

print("-- Test auras: party and raid test frames are untouched")
do
    -- A party frame's own table never had a seed or a preview table: the seam reads
    -- its switches from that table, as before.
    local pf = { unit = "party2", dfDB = party, rows = {} }
    party.testShowAuras, party.testBuffCount, party.testDebuffCount = true, 2, 2
    DF:UpdateTestAuras(pf)
    local d = Drawn(pf, "debuff")
    eq(#d, 2, "party2: 2 debuffs")
    local off = testPoolOffset({ unit = "party2" }, #DF.TestData.debuffs, 2)
    eq(d[1].name, DF.TestData.debuffs[off + 1].name, "party2: its window from its token, as before")
end

DandersFrames, CreateFrame, GetLocale = saved.DandersFrames, saved.CreateFrame, saved.GetLocale
