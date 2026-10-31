local NS = ...

-- ============================================================
-- UNIT FRAMES COMPANION -- PREVIEW
-- DandersFrames_UnitFrames/Preview.lua (+ the Mover.lua callbacks and the
-- units test mode: its own mode, never mixed with DF's party / raid one)
-- ------------------------------------------------------------
-- Separate NON-SECURE frames, one per drawn unit, painted by DF's test painter
-- with their own fake unit (dfPreview, dfTestData). Owners: a mover session and
-- the units test mode (its panel, the Test button on a Unit Frames page).
-- The live secure buttons are never shown or hidden by any of it -- their
-- holders are only faded (alpha is legal in combat).
-- ============================================================

local G, G_NAMES = {}, { "DandersFrames", "CreateFrame", "C_Timer", "RegisterUnitWatch", "RegisterStateDriver",
                     "ClickCastFrames", "UnitGUID", "UnitExists", "UnitHasVehicleUI", "IsInInstance", "LibStub",
                     "UnitName", "UnitClass", "UnitLevel", "hooksecurefunc" }
for _, k in ipairs(G_NAMES) do G[k] = _G[k] end

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

-- ---- DF stub ----
local painted, built, loads = {}, {}, 0
local dfCallbacks = {}
local DF = { PartyDefaults = {}, registered = {}, _testActive = { party = false, raid = false } }
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable(key, spec) self.registered[key] = spec; return true end
function DF:InitStandaloneFrame(f, db) f.dfStandalone = true; f.dfDB = db; return f end
function DF:RegisterRangeFrame() end
function DF:CreateFrameElements(f, isRaid)
    -- Everything the elements read must already resolve to the unit and to test scope.
    built[#built + 1] = { unit = f.dfUFUnit, preview = f.dfPreview, standalone = f.dfStandalone,
                          db = f.dfDB, test = f.dfIsTestFrame, raid = isRaid }
end
function DF:ApplyFrameStyle() end
function DF:ApplyFrameLayout() end
function DF:FullFrameRefresh() end
function DF:UpdateTextDesigner() end
function DF:UpdateRange() end
function DF:UpdateHighlights() end
function DF:UpdateTestFrame(f, index)
    painted[#painted + 1] = { unit = f.dfUFUnit, index = index, data = f.dfTestData }
end
function DF:EnsureOptionsLoaded() loads = loads + 1; DF._optionsAddonLoaded = true; return true end
function DF:IsTestModeActive(scope) return self._testActive[scope] end
-- DF's test mode ownership (TestMode/Shim.lua), as far as the units test mode reads it.
DF._owners = { party = {}, raid = {} }
function DF:IsTestModeOwnedBy(scope, owner) return self._owners[scope][owner] and true or false end
function DF:SetTestModeOwner(scope, owner, wanted) self._owners[scope][owner] = wanted and true or nil end
local said = {}
function DF:Say(msg) said[#said + 1] = msg end
DF.RegisterCallback = function(owner, event, fn) dfCallbacks[event] = { owner = owner, fn = fn } end
DF.L = setmetatable({}, { __index = function(_, k) return k end })

-- ---- client stubs ----
C_Timer = { After = function(_, fn) fn() end, NewTicker = function() return { Cancel = function() end } end }
RegisterUnitWatch = function() end
RegisterStateDriver = function() end
ClickCastFrames = {}
UnitGUID = function() return nil end
UnitExists = function(u) return u == "player" end
UnitHasVehicleUI = function() return false end
IsInInstance = function() return false end
UnitName = function() return "Danders" end
UnitClass = function() return "Priest", "PRIEST" end
UnitLevel = function() return 80 end
hooksecurefunc = function(t, name, fn)
    local orig = t[name]
    t[name] = function(...) local r = orig(...); fn(...); return r end
end

local created = {}
CreateFrame = function(kind, name, parent, template)
    local f = setmetatable(FakeUIFrame(100, 20), nil)
    f._kind, f._name, f._template = kind, name, template
    f._shown = true      -- a new frame is shown, as in the client
    f._attrs, f._events, f._hooks = {}, {}, {}
    f:SetFakeParent(parent)
    function f:GetName() return self._name end
    function f:SetAttribute(k, v) self._attrs[k] = v end
    function f:RegisterEvent(ev) self._events[ev] = true end
    function f:RegisterUnitEvent(ev) self._events[ev] = true end
    function f:UnregisterEvent(ev) self._events[ev] = nil end
    function f:HookScript() end
    function f:EnableMouse() end
    function f:IsVisible()
        if not self._shown then return false end
        local p = rawget(self, "_parent")
        if type(p) == "table" and p.IsVisible and p ~= UIParent then return p:IsVisible() end
        return true
    end
    created[#created + 1] = f
    return f
end

-- ---- a fake DandersMover-1.0 with callbacks ----
local lib = { addons = {}, defs = {}, cbs = {} }
function lib:RegisterAddon(name, opts) self.addons[name] = opts end
function lib:Register(addon, key, def) self.defs[addon .. ":" .. key] = def end
function lib:Apply() end
lib.ApplyPosition = function(f, pos) f._placed = pos end
lib.RegisterCallback = function(owner, event, fn) lib.cbs[event] = fn end
LibStub = function(name) if name == "DandersMover-1.0" then return lib end end

DandersFrames = DF
local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Defaults.lua", UF)
load_uf_file_into("Units.lua", UF)
load_uf_file_into("Preview.lua", UF)
load_uf_file_into("Mover.lua", UF)
DF.db = { unitframes = deepcopy(DF.registered.unitframes.defaults) }
local P, M, Units = UF.Preview, UF.Mover, UF.Units

UF:Init()
local A = "DandersFrames_UnitFrames"

print("-- Spawned and registered: focus and pet included")
for _, unit in ipairs({ "player", "target", "targettarget", "focus", "pet" }) do
    check(UF.frames[unit] ~= nil, unit .. ": spawned")
    check(lib.defs[A .. ":" .. unit] ~= nil, unit .. ": a mover element")
end
eq(lib.defs[A .. ":focus"].title, "Focus", "focus element title")
eq(lib.defs[A .. ":pet"].title, "Pet", "pet element title")
eq(lib.defs[A .. ":pet"].default.anchor, nil, "pet: free by default (not anchored to the player)")
eq(lib.defs[A .. ":pet"].default.x .. "," .. lib.defs[A .. ":pet"].default.y, "-365,-242", "...below-left of the player")
eq(lib.defs[A .. ":focus"].default.x, -280, "focus default x")
eq(lib.defs[A .. ":focus"].default.y, -300, "focus default y")
check(type(lib.defs[A .. ":target"].getRect) == "function", "elements report a rect")

print("-- Off by default")
eq(P:IsActive(), false, "no owner: off")
eq(next(P.frames), nil, "no preview frames built until needed")
eq(dfCallbacks.OnTestModeChanged, nil, "DandersFrames' party / raid test mode never brings the preview up")
check(type(lib.cbs.Unlocked) == "function" and type(lib.cbs.Locked) == "function", "listens for mover sessions")

print("-- Mover session: Unlocked turns it on, Locked off")
painted, built = {}, {}
local liveShown = {}
for unit, f in pairs(UF.frames) do liveShown[unit] = f._shown end
lib.cbs.Unlocked()
eq(P:IsActive(), true, "unlocked: on")
eq(P:IsOwnedBy("unlock"), true, "...owned by the session")
eq(loads, 1, "the options addon (the painter) is loaded")
for _, unit in ipairs({ "player", "target", "targettarget", "focus", "focustarget", "pet" }) do
    local f = P.frames[unit]
    check(f ~= nil, unit .. ": a preview frame")
    if f then
        eq(f._kind, "Button", unit .. ": a plain Button")
        eq(f._template, nil, unit .. ": NO secure template")
        eq(f.dfPreview, true, unit .. ": dfPreview (in test scope)")
        eq(f.dfIsTestFrame, true, unit .. ": a test frame for the painters")
        eq(f.dfDB, P:PreviewDB(unit), unit .. ": the unit's own settings (through the preview's table)")
        eq(f.dfDB.frameWidth, UF:GetUnitDB(unit).frameWidth, unit .. ": ...which reads the unit's values")
        eq(f.dfTestAuraSeed, P.AURA_SEEDS[unit], unit .. ": its window of the sample auras")
        check(type(f.dfTestData) == "table", unit .. ": its own fake unit (dfTestData)")
        eq(f:IsShown(), true, unit .. ": shown")
        check(f ~= UF.frames[unit], unit .. ": not the live button")
        eq(f._placed, UF:GetPositionRecord(unit), unit .. ": placed at the unit's record")
    end
end
eq(#built, 6, "elements built once per unit")
for _, b in ipairs(built) do
    check(b.preview and b.standalone and b.test and b.db == P:PreviewDB(b.unit) and b.raid == false,
          b.unit .. ": marked standalone + preview BEFORE its elements were built")
end
eq(#painted, 6, "each painted by DF's test painter")
eq(P.frames.target.dfTestData.reaction, 2, "target: a hostile sample")
eq(P.frames.focustarget.dfTestData.name, P.frames.targettarget.dfTestData.name,
   "focus target: the same sample as target of target (the focus targets you)")
eq(P.frames.target.dfTestData.class, nil, "...an NPC (no class)")
eq(P.frames.player.dfTestData.class, "PRIEST", "player: your own class")
eq(P.frames.player.dfTestData.name, "Danders", "...and name")
eq(P.frames.targettarget.dfTestData.name, "Danders", "target of target: you")
eq(P.frames.focus.dfTestData.classification, "rare", "focus: a classification for the Text Designer")
eq(P.frames.pet.dfTestData.reaction, 5, "pet: friendly")
for unit, h in pairs(Units.holders) do
    eq(h._alpha, 0, unit .. ": live holder faded out under the preview")
end
for unit, f in pairs(UF.frames) do
    eq(f._shown, liveShown[unit], unit .. ": live button's shown state untouched")
end

print("-- The mover measures the preview frame while it is up")
local def = lib.defs[A .. ":target"]
eq(def.getFrame(), P.frames.target, "getFrame: the preview frame")
P.frames.target:SetFakeCenter(1240, 340)
local r = def.getRect()
check(r ~= nil, "getRect: a rect for an absent unit (no target)")
if r then
    eq(r.x, 280, "...x from UIParent's centre")
    eq(r.y, -200, "...y from UIParent's centre")
    eq(r.w, 100, "...width")
end
P.frames.focus._placed = nil
lib.defs[A .. ":focus"].onChanged()
eq(P.frames.focus._placed, UF:GetPositionRecord("focus"), "a move re-places the preview frame at once")

lib.cbs.Locked()
eq(P:IsActive(), false, "locked: off")
for unit, f in pairs(P.frames) do eq(f:IsShown(), false, unit .. ": preview hidden") end
for unit, h in pairs(Units.holders) do eq(h._alpha, 1, unit .. ": live holder back") end
eq(def.getFrame(), UF.frames.target, "getFrame: the live frame again")
eq(def.getRect(), nil, "getRect: nothing while the live target is absent")

print("-- The units test mode: its own mode")
painted = {}
eq(P:SetTestMode(true), true, "on")
eq(P:IsTestMode(), true, "...the 'test' owner")
eq(P:IsActive(), true, "...the preview is up")
eq(#painted, 6, "every preview painted")
eq(P:SetTestMode(false), true, "off")
eq(P:IsActive(), false, "...down")

print("-- It never mixes with the party / raid test mode")
DF._owners.party.user = true
DF._owners.party.unlock = true
P:SetTestMode(true)
eq(DF._owners.party.user, nil, "turning it on drops the user's party claim")
eq(DF._owners.party.unlock, true, "...a mover session's claim is left alone")
local heard = {}
P:AddListener(function(on, reason) heard[#heard + 1] = tostring(on) .. ":" .. reason end)
DF:SetTestModeOwner("raid", "user", true)
eq(P:IsTestMode(), false, "the user claiming raid test mode turns it off")
eq(heard[#heard], "false:group", "...and says why (its panel closes)")
DF._owners.raid.user = nil
P:SetTestMode(true)
DF:SetTestModeOwner("party", "unlock", true)
eq(P:IsTestMode(), true, "a mover session's party claim does not")
DF:SetTestModeOwner("party", "user", false)
eq(P:IsTestMode(), true, "...nor does a release")
DF._owners.party.unlock = nil

print("-- Combat: refused on, ended on entry (as DF's own)")
IN_COMBAT = true
P:OnCombat()
eq(P:IsTestMode(), false, "entering combat ends it")
eq(said[#said], "Test mode ended — entering combat.", "...with DF's chat line")
eq(P:SetTestMode(true), false, "turning it on in combat is refused")
eq(said[#said], "Cannot enter test mode during combat.", "...and says so")
eq(P:IsActive(), false, "...still off")
IN_COMBAT = false
check(P.eventFrame and P.eventFrame._events.PLAYER_REGEN_DISABLED, "listens for combat entry")

print("-- Owners stack")
P:SetTestMode(true)
lib.cbs.Unlocked()
lib.cbs.Locked()
eq(P:IsActive(), true, "the session ending leaves the test mode's preview up")
P:SetTestMode(false)
eq(P:IsActive(), false, "...until it is switched off too")

print("-- The panel's Frames switches (not during a mover session)")
local tdb = UF:GetTestDB()
P:SetTestMode(true)
tdb.showPet = false
P:Refresh()
eq(P.frames.pet:IsShown(), false, "Pet off: its preview hides")
eq(P.frames.player:IsShown(), true, "...the others stay")
lib.cbs.Unlocked()
eq(P.frames.pet:IsShown(), true, "a mover session shows every preview (something to drag)")
lib.cbs.Locked()
eq(P.frames.pet:IsShown(), false, "...and the switch is back after it")
tdb.showPet = true
P:SetTestMode(false)

print("-- The preview sits above the live frames (the mouse reaches it, not the faded buttons)")
do
    local live, prev = UF.Units.parent, P.parent
    check(live and prev, "both parents exist")
    if live and prev then
        eq(prev:GetFrameStrata(), live:GetFrameStrata(), "same strata as the live parent")
        check(prev:GetFrameLevel() >= live:GetFrameLevel() + 100, "...and 100 levels above it")
    end
end

print("-- Combat: the preview never touches the secure buttons")
IN_COMBAT = true
local before = {}
for unit, f in pairs(UF.frames) do before[unit] = f._shown end
lib.cbs.Unlocked()
eq(P:IsActive(), true, "a mover session's preview works in combat (plain frames)")
for unit, f in pairs(UF.frames) do eq(f._shown, before[unit], unit .. ": live button not shown or hidden") end
lib.cbs.Locked()
for unit, f in pairs(UF.frames) do eq(f._shown, before[unit], unit .. ": ...nor on the way out") end
IN_COMBAT = false

print("-- Settings refresh repaints what is up")
P:SetTestMode(true)
painted = {}
UF:RefreshAll()
eq(#painted, 6, "every preview frame repainted")
P:SetTestMode(false)
painted = {}
UF:RefreshAll()
eq(#painted, 0, "nothing painted while off")

print("-- Test settings: the units test panel's own, never the party / raid table's")
do
    local party = { testShowAuras = false, testBuffCount = 5, frameWidth = 999 }
    function DF:GetDB() return party end
    function DF:GetRaidDB() return party end
    local db = P:PreviewDB("target")
    eq(db.testShowAuras, true, "Show Auras: the units test setting (on by default)")
    eq(db.testBuffCount, 2, "...the buff count too")
    tdb.testDebuffCount = 4
    eq(db.testDebuffCount, 4, "...and follows the units panel")
    tdb.testDebuffCount = 2
    eq(db.testShowAbsorbs, true, "Absorbs: the units test setting")
    eq(db.frameWidth, UF:GetUnitDB("target").frameWidth, "any other key: the unit's own (never the party table's)")
    eq(rawget(DF.db.unitframes.global, "testMode"), tdb, "stored under the module table (testMode)")
    db.buffMax = 6
    eq(UF:GetStoredUnit("target").buffMax, 6, "a write lands in the unit's own table")
    db.buffMax = nil
    eq(P:PreviewDB("target"), db, "one table per unit")
    eq(P.AURA_SEEDS.boss, nil, "boss slots seed from their own tokens (boss1..boss5)")
    local seen = {}
    for u, n in pairs(P.AURA_SEEDS) do
        check(not seen[n], u .. ": a seed of its own")
        seen[n] = true
    end
    DF.GetDB, DF.GetRaidDB = nil, nil
end

print("-- Test settings shape the sample units")
do
    eq(P:TestData("target").classification, "elite", "target: elite by default")
    tdb.classification = "normal"
    eq(P:TestData("target").classification, nil, "Normal: no classification")
    tdb.classification = "rareelite"
    eq(P:TestData("target").classification, "rareelite", "Rare Elite")
    tdb.reaction = "neutral"
    eq(P:TestData("target").reaction, 4, "Neutral: reaction 4")
    eq(P:TestData("focus").classification, "rare", "the focus keeps its own sample")
    tdb.classification, tdb.reaction = "elite", "hostile"
    eq(P:TestData("target").raidTarget, 8, "a raid target icon on the target")
    eq(P:TestData("boss", 3).raidTarget, 3, "...a boss slot wears its slot's")
    tdb.showRaidTarget = false
    eq(P:TestData("target").raidTarget, nil, "Raid Target Icon off: none")
    tdb.showRaidTarget = true
    eq(P:TestData("player").isLeader, true, "player: leader")
    eq(P:TestData("player").isInCombat, true, "...in combat")
    tdb.showLeader, tdb.showCombat = false, false
    eq(P:TestData("player").isLeader, false, "Leader Icon off")
    eq(P:TestData("player").isInCombat, false, "Combat Icon off")
    tdb.showLeader, tdb.showCombat = true, true
    eq(P:TestData("target").healthPercent, 0.62, "health: the sample's own")
    tdb.fixedHealth, tdb.healthPercent = true, 40
    eq(P:TestData("target").healthPercent, 0.4, "Fixed Health: every preview at the slider's value")
    eq(P:TestData("pet").healthPercent, 0.4, "...the pet too")
    tdb.fixedHealth = false
    eq(P:TestData("player").healAbsorbPercent > 0 and P:TestData("player").healPredictionPercent > 0, true,
       "the player sample has a heal absorb and heal prediction to show")
end

print("-- Animate Health: its own ticker while the preview is up")
do
    local ticks = {}
    local savedTicker = C_Timer.NewTicker
    C_Timer.NewTicker = function(_, fn)
        local t = { fn = fn, Cancel = function(self) self.cancelled = true end }
        ticks[#ticks + 1] = t
        return t
    end
    local healthOnly = 0
    DF.UpdateTestFrameHealthOnly = function() healthOnly = healthOnly + 1 end
    tdb.testAnimateHealth = true
    P:SetTestMode(true)
    eq(#ticks, 1, "a ticker starts")
    ticks[1].fn()
    eq(healthOnly, 6, "...and steps the health of every shown preview")
    check(P.frames.target.dfTestData.healthPercent ~= 0.62, "...off the sample's own value")
    P:SetTestMode(false)
    eq(ticks[1].cancelled, true, "stops when the preview goes")
    tdb.testAnimateHealth = false
    C_Timer.NewTicker = savedTicker
    DF.UpdateTestFrameHealthOnly = nil
end

print("-- The Settings page and the panel")
local pages = options_file_source("UnitFrames/Pages.lua")
check(not pages:find("Include Unit Frames in Test Mode", 1, true), "Settings page: no party test mode option any more")
check(not pages:find("UFO.SetTestMode(v)", 1, true), "Settings page: no Test Mode switch of its own (the Test button)")
check(pages:find('testModeId = "units"', 1, true), "the module names its own test mode (the Test button follows it)")
local panelSrc = options_file_source("GUI/Panel.lua")
check(panelSrc:find("GUI.ModuleTestMode()", 1, true), "the window's Test button asks the module first")
local toc = options_file_source("DandersFrames_Options.toc")
check(toc:find("UnitFrames\\TestMode.lua", 1, true), "the units test mode is in the options TOC")
local tm = options_file_source("TestMode/TestMode.lua")
check(tm:find("DF:GetTestDataForFrame(frame, index, isRaid, isBoss)", 1, true),
      "the test painter takes a frame's own data")

print("-- Health colour defaults: hostile-capable units use class-or-reaction")
for _, unit in ipairs({ "target", "targettarget", "focus", "boss" }) do
    eq(UF.UnitDefaults[unit].healthColorMode, "CLASS_REACTION", unit .. ": CLASS_REACTION (tapped grey)")
end
eq(UF.UnitDefaults.player.healthColorMode, "CLASS", "player: class")
check(options_file_source("UnitFrames/Pages.lua"):find("CLASS_REACTION = L[\"Class / Reaction\"]", 1, true),
      "the Health Bar page offers the two modes")

for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
IN_COMBAT = false
