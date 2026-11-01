local NS = ...

-- ============================================================
-- UNIT FRAMES -- AURA DESIGNER ON THE PREVIEW FRAMES (per-unit designers, phase 3)
-- The REAL Aura Designer gate of the test painter (cut out of DF:UpdateTestFrame),
-- the REAL enable check (DF:IsAuraDesignerEnabled), the REAL party / raid test
-- refresh (DF:UpdateAllTestAuraDesigner) and the REAL preview (Preview.lua, its
-- settings table over the real unit defaults) -- the factory is a recorder: which
-- frames it was asked to draw, with which template, and which it cleared.
-- ============================================================

local saved = { DandersFrames = DandersFrames, CreateFrame = CreateFrame, GetLocale = GetLocale,
                hooksecurefunc = hooksecurefunc, C_Timer = C_Timer }

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

local function cut(src, marker, closer)
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
function DF:RegisterProfileRootTable() return true end
DF.RegisterCallback = function() end

local party, raid = deepcopy(DF.PartyDefaults), deepcopy(DF.PartyDefaults)
party.auraDesignerPreset = "Party"
function DF:GetDB() return party end
function DF:GetRaidDB() return raid end
function DF:GetFrameDB(f) return rawget(f, "dfDB") or party end
function DF:GetModeDesignerPresetName(kind, mode) return (mode == "raid" and raid or party).auraDesignerPreset end
local modeEnabled = { party = true, raid = false }
function DF:IsAuraDesignerEnabledForMode(mode) return modeEnabled[mode] end
function DF:IsTestFrameDead() return false end
DF._optionsAddonLoaded = true

-- The real enable check.
local adapter = df_file_source("AuraDesigner/AuraAdapter.lua"):gsub("\r\n", "\n")
assert(loadstring("local DF = ...\n" .. cut(adapter, "function DF:IsAuraDesignerEnabled(frame)", "end")))(DF)

-- The factory, recording.
local log = {}
local appearance = 0
local Factory = {}
function Factory:SyncFrame(f)
    log[#log + 1] = { op = "sync", f = f, preset = rawget(f, "dfAuraPresetOverride") }
    rawset(f, "dfADFactory", rawget(f, "dfADFactory") or {})
end
function Factory:ClearFrame(f) log[#log + 1] = { op = "clear", f = f } end
function DF:UpdateAuraDesignerAppearance() appearance = appearance + 1 end
function DF:UpdateHealthBarAppearance() end
local Engine = {}
DF.AuraDesigner = { Factory = Factory, Engine = Engine }

-- The real AD gate of the test painter, as the whole of a stand-in UpdateTestFrame.
local tm = options_file_source("TestMode/TestMode.lua"):gsub("\r\n", "\n")
do
    local s = tm:find("    local ADFactory = DF.AuraDesigner and DF.AuraDesigner.Factory\n", 1, true)
    assert(s, "UpdateTestFrame's Aura Designer block")
    local e = tm:find("\n    end\n", s, true)
    local block = tm:sub(s, e + #"\n    end")
    assert(loadstring("local DF = ...\nfunction DF:UpdateTestFrame(frame)\n    local db = DF:GetFrameDB(frame)\n"
        .. block .. "\nend"))(DF)
end
-- The real party / raid test refresh (and the surface repaint it ends with).
assert(loadstring("local DF = ...\n" .. cut(tm, "local function RepaintTestSurface(frame, which)", "end")
    .. "\n" .. cut(tm, "function DF:UpdateAllTestAuraDesigner()", "end")))(DF)

-- The engine's editor refresh, as far as test mode goes (Engine.lua's tail).
function Engine:ForceRefreshAllFrames()
    if (DF.testMode or DF.raidTestMode) and DF.UpdateAllTestAuraDesigner then
        DF:UpdateAllTestAuraDesigner()
    end
end

-- ---- the companion ------------------------------------------------------------
hooksecurefunc = function(t, name, fn)
    local orig = t[name]
    t[name] = function(...) local r = orig(...); fn(...); return r end
end
C_Timer = nil
CreateFrame = nil
local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Links.lua", UF)
load_uf_file_into("Defaults.lua", UF)
load_uf_file_into("Preview.lua", UF)
DF.db = { unitframes = deepcopy(UF.ProfileDefaults), party = party, raid = raid }
local P = UF.Preview
P:Init()

local function Frame(fields)
    local f = setmetatable(FakeUIFrame(100, 20), nil)
    for k, v in pairs(fields) do f[k] = v end
    return f
end
local function PreviewFrame(unit, slot)
    local f = Frame({ dfUFPreview = true, dfPreview = true, dfIsTestFrame = true, dfStandalone = true,
                      dfUFUnit = unit, dfUFSlot = slot, unit = slot and (unit .. slot) or unit,
                      dfDB = P:PreviewDB(unit), isRaidFrame = false })
    f.index = 1
    f:Show()
    return f
end

local UNITS = { "player", "target", "pet" }
for _, u in ipairs(UNITS) do P.frames[u] = PreviewFrame(u) end
UF.Boss = { preview = { PreviewFrame("boss", 1), PreviewFrame("boss", 2) } }
P.shown = true

local function PaintAll()
    for _, f in pairs(P.frames) do P:Paint(f) end
    for _, f in pairs(UF.Boss.preview) do P:Paint(f) end
end
local function Last(f)
    for i = #log, 1, -1 do if log[i].f == f then return log[i] end end
end
local function Reset() for i = #log, 1, -1 do log[i] = nil end end
local function Unit(u) return UF:GetUnitDB(u) end

-- ============================================================
print("-- Preview AD: the units test settings answer the switch")
eq(UF.TestDefaults.testShowAuraDesigner, true, "on by default in the units test settings")
check(P.TEST_KEYS.testShowAuraDesigner, "a units test key")
eq(P:PreviewDB("player").testShowAuraDesigner, true, "a preview's table answers it from the units test settings")
eq(DF.PartyDefaults.testShowAuraDesigner, false, "...not from the party default it would otherwise inherit")

print("-- Preview AD: off for a unit -> nothing drawn")
do
    Reset()
    PaintAll()
    for _, u in ipairs(UNITS) do
        eq(Last(P.frames[u]) and Last(P.frames[u]).op, "clear", u .. ": cleared, never synced")
    end
end

print("-- Preview AD: on -> the unit's own template; following Party -> Party's")
do
    Unit("player").auraDesignerEnabled = true
    Unit("target").auraDesignerEnabled = true
    Unit("target").auraDesignerPreset = "Target"
    Reset()
    PaintAll()
    local p, t = Last(P.frames.player), Last(P.frames.target)
    eq(p and p.op, "sync", "player (enabled) is synced")
    eq(p and p.preset, "Party", "...with Party's template while it follows Party")
    eq(t and t.op, "sync", "target (enabled) is synced")
    eq(t and t.preset, "Target", "...with its own template")
    eq(Last(P.frames.pet).op, "clear", "pet (its own enable off) is cleared")
    eq(modeEnabled.party, true, "(Party's own enable is on: a unit answers its OWN enable)")
end

print("-- Preview AD: a unit's enable is its own, never Party's")
do
    modeEnabled.party = false
    Reset()
    PaintAll()
    eq(Last(P.frames.player).op, "sync", "player still synced with Party's designer off")
    modeEnabled.party = true
end

print("-- Preview AD: the test switch off -> nothing drawn")
do
    local tdb = UF:GetTestDB()
    tdb.testShowAuraDesigner = false
    Reset()
    PaintAll()
    eq(Last(P.frames.player).op, "clear", "player cleared")
    eq(Last(P.frames.target).op, "clear", "target cleared")
    tdb.testShowAuraDesigner = true
end

print("-- Preview AD: boss slots use the boss unit's settings")
do
    Reset()
    PaintAll()
    eq(Last(UF.Boss.preview[1]).op, "clear", "boss off: slot 1 cleared")
    Unit("boss").auraDesignerEnabled = true
    Unit("boss").auraDesignerPreset = "Bosses"
    Reset()
    PaintAll()
    for i = 1, 2 do
        local r = Last(UF.Boss.preview[i])
        eq(r and r.op, "sync", "boss slot " .. i .. " synced")
        eq(r and r.preset, "Bosses", "...with the boss unit's template")
    end
end

print("-- Preview AD: an editor change repaints the previews")
do
    -- Party's template switched: the player (following Party) follows at once.
    party.auraDesignerPreset = "Party 2"
    Reset()
    appearance = 0
    Engine:ForceRefreshAllFrames()
    eq(Last(P.frames.player) and Last(P.frames.player).preset, "Party 2", "player re-synced on Party's new template")
    eq(Last(P.frames.target) and Last(P.frames.target).preset, "Target", "target keeps its own")
    eq(Last(UF.Boss.preview[1]) and Last(UF.Boss.preview[1]).op, "sync", "boss slots re-synced too")
    eq(appearance, 5, "the appearance pass follows each sync (five shown previews)")
    -- The enable toggled off on a unit's page.
    Unit("target").auraDesignerEnabled = false
    Reset()
    Engine:ForceRefreshAllFrames()
    eq(Last(P.frames.target).op, "clear", "target's enable off: cleared on the next editor refresh")
    Unit("target").auraDesignerEnabled = true
    -- A hidden preview is skipped; previews down -> no work at all.
    P.frames.pet:Hide()
    Reset()
    Engine:ForceRefreshAllFrames()
    eq(Last(P.frames.pet), nil, "a hidden preview is not touched")
    P.frames.pet:Show()
end

print("-- Preview AD: the units test mode off clears the previews")
do
    Reset()
    P:Hide()
    eq(Last(P.frames.player) and Last(P.frames.player).op, "clear", "player cleared")
    eq(Last(P.frames.target) and Last(P.frames.target).op, "clear", "target cleared")
    eq(Last(UF.Boss.preview[1]) and Last(UF.Boss.preview[1]).op, "clear", "boss slot cleared")
    eq(Last(P.frames.pet), nil, "pet never drew the designer: nothing to clear")
    Reset()
    Engine:ForceRefreshAllFrames()
    eq(#log, 0, "an editor change with the previews down touches no preview")
end

print("-- Preview AD: party and raid test frames are unchanged")
do
    local pf = Frame({ unit = "party1", isRaidFrame = false })
    pf:Show()
    DF.testMode = true
    DF.testPartyFrames = { [0] = pf }
    party.testShowAuraDesigner = true
    Reset()
    Engine:ForceRefreshAllFrames()
    eq(#log, 1, "one factory call: the party test frame only")
    eq(log[1] and log[1].f, pf, "...on the party frame")
    eq(log[1] and log[1].op, "sync", "...synced on the party table's switch and the party enable")
    eq(log[1] and log[1].preset, nil, "...with no unit template stamped on it")
    party.testShowAuraDesigner = false
    Reset()
    Engine:ForceRefreshAllFrames()
    eq(log[1] and log[1].op, "clear", "party's own switch off: the party frame clears, as before")
    -- The units test settings never reach a party frame.
    UF:GetTestDB().testShowAuraDesigner = true
    eq(DF:GetFrameDB(pf).testShowAuraDesigner, false, "the party frame reads the party table, not the units one")
    DF.testMode, DF.testPartyFrames = nil, nil
end

print("-- Preview AD: shared code stays neutral and party-identical")
do
    local fac = df_file_source("AuraDesigner/Factory.lua")
    check(fac:find("if enabled and owns and frame.unit and not frame.dfIsTestFrame and not frame.dfPreview then", 1, true),
          "the sound reconcile never arms alerts from a preview frame")
    local eng = df_file_source("AuraDesigner/Engine.lua")
    check(eng:find("if not f.dfPreview and (f.dfADFactory or DF:IsAuraDesignerEnabled(f)) then TryUpdate(f) end", 1, true),
          "the engine's standalone walk still leaves preview frames to the preview")
    local src = uf_file_source("Preview.lua")
    check(src:find('hooksecurefunc(Engine, "ForceRefreshAllFrames"', 1, true), "the preview hooks the editor refresh")
end

DandersFrames, CreateFrame, GetLocale = saved.DandersFrames, saved.CreateFrame, saved.GetLocale
hooksecurefunc, C_Timer = saved.hooksecurefunc, saved.C_Timer
