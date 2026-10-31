local NS = ...

-- ============================================================
-- TEXT DESIGNER: LEVEL (DIFFICULTY COLOUR), CLASSIFICATION, TARGET NAME,
-- AND DEAD / OFFLINE / GHOST / AFK
-- TextDesigner/DataSource.lua (Live, Test and Mock sources) and
-- TextDesigner/Resolver.lua, loaded REAL into a fresh namespace over stubbed
-- unit APIs. A secret is a sentinel table the stubbed issecretvalue knows.
-- ============================================================

local SECRET_LEVEL, SECRET_CLASS, SECRET_AFK = {}, {}, {}
local secrets = { [SECRET_LEVEL] = true, [SECRET_CLASS] = true, [SECRET_AFK] = true }
local W = {}  -- the unit world the stubs answer from
local STUBS = {
    issecretvalue = function(v) return secrets[v] == true end,
    UnitLevel = function(u) return W.level end,
    UnitClassification = function(u) return W.classification end,
    UnitExists = function(u) return W.exists[u] == true end,
    UnitName = function(u) return W.names[u] end,
    UnitIsAFK = function(u) return W.afk end,
    UnitIsDead = function(u) return W.dead end,
    UnitIsGhost = function(u) return false end,
    UnitIsConnected = function(u) return W.connected end,
    UnitIsFeignDeath = function(u) return false end,
    UnitClass = function() return "Warrior", "WARRIOR" end,
    GetCreatureDifficultyColor = function(level) return { r = 1, g = 0.82, b = 0 } end,
}
local saved = {}
for k, v in pairs(STUBS) do saved[k] = _G[k]; _G[k] = v end

local DF = {
    L = setmetatable({}, { __index = function(_, k) return k end }),
    Debug = function() end,
    DebugActive = function() return false end,
}
function DF:UTF8Len(s) return #s end
function DF:UTF8Sub(s, i, j) return s:sub(i, j) end
load_df_file_into("TextDesigner/MidnightSafe.lua", DF)
load_df_file_into("TextDesigner/DataSource.lua", DF)
load_df_file_into("TextDesigner/Resolver.lua", DF)

local TD = DF.TextDesigner
local R = TD.Resolver
local function resolve(ct, source, extra)
    local elem = { contentType = ct }
    for k, v in pairs(extra or {}) do elem[k] = v end
    return R:Resolve(elem, source)
end
local function world(t)
    W = { level = 80, classification = "normal", exists = {}, names = {}, afk = false,
          dead = false, connected = true }
    for k, v in pairs(t or {}) do W[k] = v end
end

print("-- the tokens exist (power value and percent already did)")
for _, key in ipairs({ "level_difficulty", "classification", "target_name", "status_afk",
                       "level", "power_current", "power_percent", "status_text" }) do
    check(R._RESOLVERS[key] ~= nil, "resolver: " .. key)
end

print("-- Level (Difficulty Color), live")
local live = TD.DataSource.Live({ unit = "target" })
world({ level = 80 })
eq(resolve("level_difficulty", live), "|cffffd10080|r", "a level wears the game's difficulty colour")
eq(resolve("level", live), "80", "the plain Level token is unchanged")
world({ level = -1 })
eq(resolve("level_difficulty", live), "|cffff1a1a??|r", "a hidden level is a red ??")
world({ level = SECRET_LEVEL })
eq(resolve("level_difficulty", live), "??", "a secret level is ?? in the element's own colour")
world({ level = 80 })
local saveColor = _G.GetCreatureDifficultyColor
_G.GetCreatureDifficultyColor = nil
eq(resolve("level_difficulty", live), "80", "no colour API: the bare level")
_G.GetCreatureDifficultyColor = saveColor

print("-- Classification, live")
for cls, want in pairs({ elite = "+", rare = "Rare", rareelite = "Rare Elite", worldboss = "Boss",
                         normal = "", trivial = "", minus = "" }) do
    world({ classification = cls })
    eq(resolve("classification", live), want, "classification " .. cls)
end
world({ classification = SECRET_CLASS })
eq(resolve("classification", live), "", "a secret classification shows nothing")

print("-- Target Name, live")
world({ exists = { targettarget = true }, names = { targettarget = "Ragnaros the Firelord" } })
eq(resolve("target_name", live), "Ragnaros the Firelord", "the unit's target is named")
eq(resolve("target_name", live, { nameLength = 8 }), "Ragnaros...", "with Name's length settings")
eq(resolve("target_name", TD.DataSource.Live({ unit = "party1" })), "", "no target: nothing")
world({ exists = { party1target = true }, names = { party1target = "Healbot" } })
eq(resolve("target_name", TD.DataSource.Live({ unit = "party1" })), "Healbot", "<unit>target, any unit")

print("-- Dead / Offline / Ghost / AFK, live")
world({ afk = true })
eq(resolve("status_afk", live), "AFK", "an AFK unit")
eq(resolve("status_text", live), "", "the plain status token still ignores AFK")
world({ afk = true, dead = true })
eq(resolve("status_afk", live), "Dead", "dead wins over AFK")
world({ afk = true, connected = false })
eq(resolve("status_afk", live), "Offline", "offline wins over AFK")
world({ afk = false })
eq(resolve("status_afk", live), "", "nothing to show")
world({ afk = SECRET_AFK })
eq(resolve("status_afk", live), "", "a secret AFK flag counts as not AFK")

print("-- test frames: the frame's own data, or the shared pool's fields")
local boss = TD.DataSource.Test({ dfTestData = { level = -1, classification = "worldboss", name = "Boss",
                                                 targetName = "Tankadin", isAFK = false } })
eq(resolve("level_difficulty", boss), "|cffff1a1a??|r", "test: a boss level is a red ??")
eq(resolve("level", boss), "??", "test: the plain Level token shows ?? too")
eq(resolve("classification", boss), "Boss", "test: classification")
eq(resolve("target_name", boss), "Tankadin", "test: target name")
local afkUnit = TD.DataSource.Test({ dfTestData = { level = 80, isAFK = true } })
eq(resolve("status_afk", afkUnit), "AFK", "test: AFK")
eq(resolve("classification", afkUnit), "", "test: no classification = nothing")
eq(resolve("target_name", afkUnit), "", "test: no target = nothing")
eq(resolve("level_difficulty", afkUnit), "|cffffd10080|r", "test: a level is coloured")

print("-- the designer preview (mock) shows every token")
local mock = TD.DataSource.Mock()
eq(resolve("classification", mock), "+", "mock: classification")
eq(resolve("target_name", mock), "Thrall", "mock: target name")
eq(resolve("level_difficulty", mock), "|cffffd10080|r", "mock: level")
eq(resolve("status_afk", mock), "Dead", "mock: a sample status, like Dead / Offline / Ghost")

for k in pairs(STUBS) do _G[k] = saved[k] end

print("-- wired into the picker, the refresh hints, the strings and the test data")
local function norm(s) return (s:gsub("\r\n", "\n")) end
local opts = norm(options_file_source("TextDesigner/UI/Options.lua"))
for _, key in ipairs({ "level_difficulty", "classification", "target_name", "status_afk" }) do
    check(opts:find('{ key = "' .. key .. '",', 1, true), "picker offers " .. key)
end
check(opts:find('elseif ct.key == "name" or ct.key == "target_name" then', 1, true),
      "Target Name gets Name's length controls")
local render = norm(df_file_source("TextDesigner/Render.lua"))
for key, hint in pairs({ level_difficulty = "name", classification = "name", target_name = "name",
                         status_afk = "health" }) do
    check(render:find("\n%s*" .. key .. "%s*= \"" .. hint .. "\","), "refresh hint " .. key .. " = " .. hint)
end
local enUS = norm(df_file_source("Locales/enUS.lua"))
for _, s in ipairs({ "Classification", "Dead / Offline / Ghost / AFK", "Level (Difficulty Color)",
                     "Rare", "Rare Elite", "Target Name" }) do
    local _, n = enUS:gsub('\nL%["' .. s:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$/]", "%%%0") .. '"%] = true', "")
    eq(n, 1, "enUS: " .. s)
end
local tm = norm(options_file_source("TestMode/TestMode.lua"))
local _, nTarget = tm:gsub("\n%s*targetName = ", "")
eq(nTarget, 2, "party and raid test units carry a target name")
check(tm:find('classification = "worldboss"', 1, true), "boss test units carry a classification")
local headers = norm(df_file_source("Frames/Headers.lua"))
check(headers:find('if event == "PLAYER_FLAGS_CHANGED" then\n%s*local unit = arg1\n[^\n]*\n[^\n]*\n%s*if unit and DF.UpdateTextDesigner then\n%s*tdRefresh%(unitFrameMap%[unit%], FindPinnedFrameForUnit%(unit%), "health"%)'),
      "an AFK flag change refreshes the status text")
