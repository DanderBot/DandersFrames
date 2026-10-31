local NS = ...

-- ============================================================
-- UNIT FRAMES COMPANION -- CORE + DEFAULTS
-- DandersFrames_UnitFrames/Core.lua, Defaults.lua
-- ------------------------------------------------------------
-- The per-unit settings chain (stored -> unit defaults -> party DEFAULTS), the
-- profile-root registration, the migrate hook, the combat queue, the built-in
-- Text Designer presets, and the rebuild on a profile change.
-- ============================================================

local saved = {
    DandersFrames = DandersFrames, CreateFrame = CreateFrame, C_Timer = C_Timer,
}

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

local errors = {}
local DF = {
    PartyDefaults = {
        frameWidth = 125, healthColorMode = "CLASS", onlyParty = "p",
        frameBorderColor = { r = 0, g = 0, b = 0, a = 1 },
    },
    registered = {}, callbacks = {},
}
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable(key, spec) self.registered[key] = spec; return true end
DF.RegisterCallback = function(owner, event, fn) DF.callbacks[event] = { owner = owner, fn = fn } end
DF.Apply = { AddPostDrain = function(_, fn) DF.postDrain = fn end }

DandersFrames = DF
CreateFrame = nil          -- skip the file-scope event wiring
C_Timer = { After = function(_, fn) fn() end }

local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Defaults.lua", UF)

print("-- Namespace")
eq(DF.UnitFrames, UF, "DandersFrames.UnitFrames is the companion's namespace")
eq(UF.ADDON, "DandersFrames_UnitFrames", "addon name from the varargs")
eq(#UF.SPAWNED_UNITS, 7, "this build spawns seven units (boss is a container of slots)")
eq(UF.SPAWNED_UNITS[7], "boss", "...boss last")
eq(UF.SPAWNED_UNITS[5], "focustarget", "...the focus target after focus (v1.1)")

print("-- Registration")
local spec = DF.registered.unitframes
check(spec ~= nil, "unitframes registered as a profile-root table")
if spec then
    eq(spec.exportable, true, "...exportable")
    eq(spec.exportCategory, "unitframes", "...with its own export category")
    eq(type(spec.migrate), "function", "...and a migrate hook")
    eq(spec.defaults.version, 1, "defaults: version 1")
    eq(type(spec.defaults.global), "table", "defaults: a global table")
    for _, u in ipairs({ "player", "target", "targettarget", "focus", "pet", "boss" }) do
        local t = spec.defaults.units[u]
        check(type(t) == "table" and next(t) == nil, "defaults: units." .. u .. " starts empty (sparse)")
    end
end

print("-- Before the profile exists")
DF.db = nil
local pre = UF:GetUnitDB("player")
eq(pre.frameWidth, 220, "defaults read through")
pre.frameWidth = 999
eq(UF:GetUnitDB("player").frameWidth, 220, "a write before the profile is not kept")
eq(UF.UnitDefaults.player.frameWidth, 220, "...and never lands in the defaults")

print("-- The chain")
DF.db = { unitframes = deepcopy(spec.defaults) }
local P = UF:GetUnitDB("player")
local T = UF:GetUnitDB("target")
local TT = UF:GetUnitDB("targettarget")
eq(P.frameWidth, 220, "player: unit default width")
eq(P.frameHeight, 46, "player: unit default height")
eq(TT.frameWidth, 110, "target of target: smaller")
eq(TT.frameHeight, 24, "target of target: smaller")
eq(UF:GetUnitDB("focus").frameWidth, 180, "focus 180")
eq(UF:GetUnitDB("boss").frameHeight, 40, "boss 40 high")
eq(P.onlyParty, "p", "a key only DF has: party DEFAULTS")
eq(P.healthColorMode, "CLASS", "player: class colour")
eq(UF:GetUnitDB("pet").healthColorMode, "CLASS", "pet: class colour")
for _, u in ipairs({ "target", "targettarget", "focus", "boss" }) do
    eq(UF:GetUnitDB(u).healthColorMode, "CLASS_REACTION", u .. ": class or reaction")
end
for _, u in ipairs(UF.UNITS) do
    eq(UF:GetUnitDB(u).source, "DF", u .. ": source DF")
end
eq(P.resourceBarEnabled, true, "player: power bar on")
eq(T.resourceBarEnabled, true, "target: power bar on")
eq(TT.resourceBarEnabled, false, "target of target: power bar off")
eq(UF:GetUnitDB("pet").resourceBarEnabled, false, "pet: power bar off")
eq(P.showBuffs, false, "player: buffs off")
eq(T.showDebuffs, true, "target: debuffs on")
eq(T.directDebuffShowAll, true, "target: every caster's debuffs")
eq(T.debuffFilterMine, true, "...yours only once Show All is turned off")
for _, u in ipairs({ "focus", "boss" }) do
    local d = UF:GetUnitDB(u)
    eq(d.directDebuffShowAll, false, u .. ": not every debuff")
    eq(d.debuffFilterMine, true, u .. ": ...yours only")
end
for _, u in ipairs({ "target", "focus", "boss" }) do
    local d = UF:GetUnitDB(u)
    eq(tostring(d.directBuffShowAll) .. "/" .. tostring(d.directBuffOnlyMine), "true/false", u .. ": buffs from any caster")
end
eq(P.debuffFilterMine ~= true, true, "player: debuff filter not narrowed to yours")
eq(T.textDesignerPreset, UF.TEXT_PRESET, "target: the unit-frame text preset")
eq(TT.textDesignerPreset, UF.TEXT_PRESET_SMALL, "target of target: the small one")
eq(T.oorEnabled, true, "target: out-of-range fading on")
eq(T.selectionHighlightMode, "NONE", "target: no selection outline (it is always the target)")
eq(P.selectionHighlightMode, nil, "player: selection outline from DF's default")
for _, u in ipairs({ "target", "targettarget", "focus", "boss" }) do
    eq(UF:GetUnitDB(u).aggroHighlightMode, "NONE", u .. ": no aggro highlight (it reads the unit's own threat)")
end
eq(P.aggroHighlightMode, nil, "player: aggro highlight from DF's default")
eq(P.leaderIconEnabled, true, "player keeps group icons")
eq(T.leaderIconEnabled, false, "target drops them")
eq(UF:GetUnitDB("player"), P, "one proxy per unit, cached")

print("-- Writes")
local stored = DF.db.unitframes.units.player
P.frameWidth = 300
eq(stored.frameWidth, 300, "a write lands in the unit's stored table")
eq(P.frameWidth, 300, "...and reads back")
eq(UF.UnitDefaults.player.frameWidth, 220, "...defaults untouched")
eq(DF.db.unitframes.units.target.frameWidth, nil, "...other units untouched")
P.frameWidth = nil
eq(P.frameWidth, 220, "clearing the stored key falls back to the default")

print("-- Tables from a defaults link are copied, never shared")
local c = P.frameBorderColor
check(c ~= DF.PartyDefaults.frameBorderColor, "party default table not handed out")
c.r = 1
eq(DF.PartyDefaults.frameBorderColor.r, 0, "an in-place edit leaves the party default alone")
eq(stored.frameBorderColor, c, "the copy is the unit's own now")
eq(P.frameBorderColor.r, 1, "...and reads back")

print("-- Position records")
local pos = UF:GetPositionRecord("targettarget")
eq(type(pos), "table", "a record")
eq(pos, DF.db.unitframes.units.targettarget.position, "the stored table itself (the mover mutates it)")
check(pos ~= UF.UnitDefaults.targettarget.position, "not the default table")
eq(pos.anchor and pos.anchor.target, "DandersFrames_UnitFrames:target", "target of target anchors to target")
pos.x = 1
eq(UF.UnitDefaults.targettarget.position.x, 449, "moving it leaves the default")
eq(UF:GetPositionRecord("player").point, "CENTER", "player record")
eq(UF:GetPositionRecord("player").x, -280, "player default x")

print("-- Migrate")
local old = { units = { player = { frameWidth = 1 } } }
UF.MigrateProfileTable(old)
eq(old.units.player.frameWidth, 1, "existing unit values kept")
for _, u in ipairs(UF.UNITS) do
    eq(type(old.units[u]), "table", "missing unit table added: " .. u)
end
eq(type(old.global), "table", "global table added")
eq(old.version, 1, "version stamped")

print("-- Combat queue")
local ran = {}
IN_COMBAT = true
check(not UF:RunOutOfCombat("a", function() ran[#ran + 1] = "a1" end), "in combat: queued")
UF:RunOutOfCombat("b", function() ran[#ran + 1] = "b" end)
UF:RunOutOfCombat("a", function() ran[#ran + 1] = "a2" end)
eq(#ran, 0, "nothing ran in combat")
check(UF:IsQueued("a"), "a is queued")
UF:FlushCombatQueue()
eq(#ran, 0, "a flush still in combat runs nothing")
IN_COMBAT = false
UF:FlushCombatQueue()
eq(table.concat(ran, ","), "a2,b", "after combat: queue order, the later request replacing the earlier")
check(not UF:IsQueued("a"), "queue drained")
check(UF:RunOutOfCombat("c", function() ran[#ran + 1] = "c" end), "out of combat: runs at once")
eq(ran[#ran], "c", "...it did")

print("-- Text Designer presets")
local lib = { Default = {} }
DF.GetTextDesignerPresets = function() return lib end
DF.NewTextDesignerConfig = function()
    return { enabled = true, elements = {
        { contentType = "name", anchor = "TOP" },
        { contentType = "group", anchor = "CENTER" },
        { contentType = "status_text", anchor = "BOTTOM" },
    } }
end
check(UF:EnsureTextPresets(), "presets ensured")
local big, small = lib[UF.TEXT_PRESET], lib[UF.TEXT_PRESET_SMALL]
check(big and small, "both presets created")
if big and small then
    eq(big.elements[1].anchor, "LEFT", "Unit Frames: name left")
    eq(big.elements[2].anchor, "RIGHT", "Unit Frames: health right")
    eq(big.elements[3].anchor, "CENTER", "Unit Frames: status centre")
    eq(#small.elements, 1, "Small: name only")
    eq(small.elements[1].contentType, "name", "...the name")
    eq(small.elements[1].anchor, "CENTER", "...centred")
    big.userEdit = true
    UF:EnsureTextPresets()
    eq(lib[UF.TEXT_PRESET].userEdit, true, "an existing preset is never overwritten")
end

print("-- Init, post-drain and profile change")
local calls = {}
local fakeFrames = {}
UF.Units = {
    SpawnAll = function() calls[#calls + 1] = "spawn"
        for _, u in ipairs(UF.SPAWNED_UNITS) do
            fakeFrames[u] = { dfUFUnit = u, dfDB = UF:GetUnitDB(u), shown = true,
                              IsVisible = function(self) return self.shown end }
            UF.frames[u] = fakeFrames[u]
        end
    end,
    ApplyLayout = function(_, f) calls[#calls + 1] = "layout:" .. f.dfUFUnit end,
    ApplyPosition = function(_, f) calls[#calls + 1] = "position:" .. f.dfUFUnit end,
    FullRefresh = function(_, f) calls[#calls + 1] = "refresh:" .. f.dfUFUnit end,
}
UF.BlizzardHide = { ApplyAll = function() calls[#calls + 1] = "hide" end }
UF.Mover = { Init = function() calls[#calls + 1] = "mover" end,
             ApplyAll = function() calls[#calls + 1] = "moverApply" end }
check(UF:Init(), "init")
eq(table.concat(calls, ",", 1, 3), "spawn,hide,mover", "spawn, then hide Blizzard's, then the mover")
check(UF:Init(), "a second init is a no-op")
eq(calls[4], nil, "...nothing ran twice")
eq(type(DF.postDrain), "function", "a post-drain listener is installed")
check(DF.callbacks.OnProfileChanged ~= nil, "OnProfileChanged is subscribed")

calls = {}
DF.postDrain()
local has = {}
for _, c2 in ipairs(calls) do has[c2] = true end
check(has["layout:player"] and has["refresh:player"] and has["refresh:targettarget"],
      "after a drain: every frame laid out and repainted")
eq(fakeFrames.target.dfTextPresetOverride, UF.TEXT_PRESET, "...with its text preset stamped")
calls = {}
fakeFrames.target.shown = false
DF.postDrain()
has = {}
for _, c2 in ipairs(calls) do has[c2] = true end
check(has["layout:target"] and not has["refresh:target"], "a hidden frame is laid out but not painted")
fakeFrames.target.shown = true

calls = {}
IN_COMBAT = true
DF.postDrain()
has = {}
for _, c2 in ipairs(calls) do has[c2] = true end
check(has["refresh:player"] and not has["layout:player"], "in combat: repaint now, layout waits")
check(UF:IsQueued("layout:player"), "...queued")
IN_COMBAT = false
UF:FlushCombatQueue()
check(calls[#calls]:find("^layout:") ~= nil, "...and runs when combat ends")

print("-- Profile change")
local oldP = UF:GetUnitDB("player")
local newProfile = { unitframes = deepcopy(spec.defaults) }
newProfile.unitframes.units.player.frameWidth = 150
DF.db = newProfile
calls = {}
DF.callbacks.OnProfileChanged.fn("OnProfileChanged", "Other")
local newP = UF:GetUnitDB("player")
check(newP ~= oldP, "a new proxy for the new profile")
eq(newP.frameWidth, 150, "...reading the new profile's values")
eq(fakeFrames.player.dfDB, newP, "frames re-pointed at the new tables")
eq(fakeFrames.targettarget.dfDB, UF:GetUnitDB("targettarget"), "...every frame")
has = {}
for _, c2 in ipairs(calls) do has[c2] = true end
check(has["position:player"] and has["moverApply"] and has["refresh:target"],
      "positions re-applied, the mover re-solved, frames repainted")

print("-- D9: the unit tables answer DandersFrames' defaults engine")
do
    -- The real engine (DandersFrames/Core/Defaults.lua), on this file's DF.
    load_df_file_into("Core/Defaults.lua", DF)
    local D = DF.Defaults
    UF:RebuildUnitDBs()
    local target = UF:GetUnitDB("target")
    check(D:GetAdapter(target) ~= nil, "a unit's table registers an adapter")
    local stored = UF:GetStoredUnit("target")
    for k in pairs(stored) do stored[k] = nil end
    check(not D:IsModified(target, "frameWidth"), "unset: not modified (its default answers)")
    eq(D:GetDefaultFor(target, "frameWidth"), UF.UnitDefaults.target.frameWidth,
       "the default is the unit's own default...")
    eq(D:GetDefaultFor(target, "onlyParty"), "p", "...then the party DEFAULTS")
    target.frameWidth = 999
    check(D:IsModified(target, "frameWidth"), "an own value that differs: modified (the amber dot)")
    target.healthColorMode = UF.UnitDefaults.target.healthColorMode
    check(not D:IsModified(target, "healthColorMode"), "an own value equal to the default: not modified")
    local _ = target.frameBorderColor    -- copy-on-read of a table default
    check(rawget(stored, "frameBorderColor") ~= nil and not D:IsModified(target, "frameBorderColor"),
          "a copied-on-read table default is not a change")
    local diff = D:DiffKeys(target, { "frameWidth", "healthColorMode", "frameBorderColor" })
    check(diff.frameWidth and not diff.healthColorMode and not diff.frameBorderColor,
          "DiffKeys (Changed Settings): only the real change")
    check(D:ResetOverride(target, "frameWidth"), "reset drops the unit's own value")
    eq(rawget(stored, "frameWidth"), nil, "...from the stored table, which stays sparse")
    eq(target.frameWidth, UF.UnitDefaults.target.frameWidth, "...and the chain answers again")
    local player = UF:GetUnitDB("player")
    player.frameWidth = 1
    check(not D:IsModified(UF:GetUnitDB("target"), "frameWidth"), "one unit's change is not another's")
    check(not D:IsModified(DF.db.party or {}, "frameWidth"), "...nor the party table's")

    local g = UF:GetGlobalDB()
    check(D:GetAdapter(g) ~= nil, "the module table registers one too")
    g.includeInTestMode = false
    check(D:IsModified(g, "includeInTestMode"), "the module table: a change shows")
    D:ResetOverride(g, "includeInTestMode")
    eq(rawget(g, "includeInTestMode"), nil, "...and resets")
    check(rawget(target, "__dfDefaultsAdapter") == nil and rawget(stored, "__dfDefaultsAdapter") == nil,
          "nothing is written into the saved tables")

    -- A profile switch: the new proxy registers; the old one is no longer asked.
    DF.db = { unitframes = deepcopy(UF.ProfileDefaults) }
    UF:RebuildUnitDBs()
    local fresh = UF:GetUnitDB("target")
    check(fresh ~= target and D:GetAdapter(fresh) ~= nil, "a new profile's proxy has its own adapter")
    check(not D:IsModified(fresh, "frameWidth"), "...over the new profile's table")
end

eq(#errors, 0, "no errors logged (" .. table.concat(errors, "; ") .. ")")

DandersFrames, CreateFrame, C_Timer = saved.DandersFrames, saved.CreateFrame, saved.C_Timer
IN_COMBAT = false
