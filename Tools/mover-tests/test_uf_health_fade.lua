local NS = ...

-- ============================================================
-- UNIT FRAMES COMPANION -- FADE AT FULL HEALTH
-- DandersFrames/Features/HealthFade.lua on a standalone unit frame
-- ------------------------------------------------------------
-- Unit frames reuse DandersFrames' own health threshold fade (no fork): the
-- three settings resolve per unit (off by default), a live standalone frame
-- fades through the engine curve even while the PARTY test mode is on (a
-- standalone frame is never in the party test scope), and a preview frame
-- takes its stamped health fraction instead.
-- ============================================================

local G, G_NAMES = {}, { "DandersFrames", "C_CurveUtil", "CreateColor", "UnitHealthPercent", "UnitExists",
                         "issecretvalue", "LibStub" }
for _, k in ipairs(G_NAMES) do G[k] = _G[k] end

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

-- ---- the unit frames' settings chain ----------------------------------------
local DF = { PartyDefaults = { frameWidth = 125, frameHeight = 40,
                               healthFadeEnabled = false, healthFadeAlpha = 0.5, healthFadeThreshold = 100 },
             registered = {} }
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable(key, spec) self.registered[key] = spec; return true end
DandersFrames = DF
LibStub = nil

local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Defaults.lua", UF)
DF.db = { unitframes = deepcopy(DF.registered.unitframes.defaults) }

print("-- Defaults: off on every unit, DandersFrames' own numbers")
for _, unit in ipairs(UF.UNITS) do
    local db = UF:GetUnitDB(unit)
    eq(db.healthFadeEnabled, false, unit .. ": fade at full health is off")
    eq(db.healthFadeAlpha, 0.5, unit .. ": ...faded alpha from the party default")
    eq(db.healthFadeThreshold, 100, unit .. ": ...threshold from the party default")
end

-- ---- HealthFade.lua, on stubs of the engine curve ----------------------------
local lastCurve
C_CurveUtil = { CreateColorCurve = function()
    local c = { points = {} }
    function c:SetType() end
    function c:AddPoint(x, col) self.points[#self.points + 1] = { x, col } end
    lastCurve = c
    return c
end }
Enum.LuaCurveType = Enum.LuaCurveType or { Linear = 0 }
CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
local enginePct = 1
local engineCalls = 0
-- The engine resolves the curve at the unit's (secret) health; the stub answers
-- the step the curve encodes, so the test can tell the two alphas apart.
UnitHealthPercent = function(unit, _, curve)
    engineCalls = engineCalls + 1
    local below, above = curve.points[1][2].a, curve.points[#curve.points][2].a
    local a = (enginePct > 0.999) and above or below
    return { GetRGBA = function() return 1, 1, 1, a end }
end
UnitExists = function() return true end
issecretvalue = function() return false end

local HF = setmetatable({}, { __index = DF })
function DF:GetFrameDB(frame) return frame.dfDB end
function DF:FrameInTestScope(frame, scope)
    if frame and frame.dfStandalone then return frame.dfPreview and true or false end
    return (DF.testMode or DF.raidTestMode) and true or false
end
function DF:MemTestDisabled() return false end
function DF:GetFrameBaseAlpha() return 1 end
load_df_file_into("Features/HealthFade.lua", DF)
check(type(DF.ApplyHealthFadeAlpha) == "function", "HealthFade.lua loaded")

local function Frame(unit, extra)
    local f = { unit = unit, dfStandalone = true, dfDB = UF:GetUnitDB(unit) }
    function f:SetAlpha(a) self.alpha = a end
    for k, v in pairs(extra or {}) do f[k] = v end
    return f
end

print("-- A live unit frame fades through the engine curve")
local T = Frame("target")
eq(DF:ApplyHealthFadeAlpha(T), false, "off: nothing applied")
eq(T.alpha, nil, "...alpha untouched")
local tdb = UF:GetUnitDB("target")
tdb.healthFadeEnabled = true
tdb.oorEnabled = true   -- target's element-mode range fade: below-threshold alpha stays 1
enginePct = 1
eq(DF:ApplyHealthFadeAlpha(T), true, "on, at full health: applied")
eq(T.alpha, 0.5, "...at the faded alpha")
check(engineCalls > 0, "...resolved by the engine (UnitHealthPercent with a curve), never a Lua comparison")
enginePct = 0.6
DF:ApplyHealthFadeAlpha(T)
eq(T.alpha, 1, "below the threshold: full alpha")

print("-- The party test mode never reaches a standalone frame")
DF.testMode = true
enginePct = 1
T.alpha = nil
eq(DF:ApplyHealthFadeAlpha(T), true, "party test mode on: the live unit frame still fades")
eq(T.alpha, 0.5, "...at the faded alpha")
DF.testMode = nil

print("-- Per unit: one unit's switch is its own")
local P = Frame("player")
eq(DF:ApplyHealthFadeAlpha(P), false, "target's switch does not turn the player's on")
local tot = UF:GetUnitDB("targettarget")
tot.healthFadeEnabled, tot.healthFadeAlpha = true, 0.25
local TT = Frame("targettarget")
DF:ApplyHealthFadeAlpha(TT)
eq(TT.alpha, 0.25, "target of target: its own faded alpha")

print("-- A preview frame takes its stamped health fraction")
local PV = Frame("target", { dfPreview = true, dfIsTestFrame = true, dfHealthPct = 1 })
local before = engineCalls
eq(DF:ApplyHealthFadeAlpha(PV), true, "preview at full health: applied")
eq(PV.alpha, 0.5, "...faded")
eq(engineCalls, before, "...without asking the engine (there is no real unit)")
PV.dfHealthPct = 0.4
DF:ApplyHealthFadeAlpha(PV)
eq(PV.alpha, 1, "preview below the threshold: full alpha")
local PV2 = Frame("target", { dfPreview = true, dfHealthPct = 1 })
eq(DF:ApplyHealthFadeAlpha(PV2), false, "a preview frame that is not a test frame is left alone")

tdb.healthFadeEnabled, tdb.oorEnabled = nil, nil
tot.healthFadeEnabled, tot.healthFadeAlpha = nil, nil
for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
