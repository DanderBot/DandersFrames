local NS = ...

-- ============================================================
-- UNIT FRAMES COMPANION -- PREVIEW
-- DandersFrames_UnitFrames/Preview.lua (+ the Mover.lua callbacks, the
-- Settings page switch, and DandersFrames' OnTestModeChanged hook)
-- ------------------------------------------------------------
-- Separate NON-SECURE frames, one per drawn unit, painted by DF's test painter
-- with their own fake unit (dfPreview, dfTestData). Owners: a mover session,
-- DF's test mode (when the module option allows), the Settings page switch.
-- The live secure buttons are never shown or hidden by any of it -- their
-- holders are only faded (alpha is legal in combat).
-- ============================================================

local G, G_NAMES = {}, { "DandersFrames", "CreateFrame", "C_Timer", "RegisterUnitWatch", "RegisterStateDriver",
                     "ClickCastFrames", "UnitGUID", "UnitExists", "UnitHasVehicleUI", "IsInInstance", "LibStub",
                     "UnitName", "UnitClass", "UnitLevel" }
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
eq(lib.defs[A .. ":pet"].default.anchor.target, A .. ":player", "pet: anchored to the player by default")
eq(lib.defs[A .. ":pet"].default.anchor.edge, "bottom", "...its bottom edge")
eq(lib.defs[A .. ":focus"].default.x, -280, "focus default x")
eq(lib.defs[A .. ":focus"].default.y, -300, "focus default y")
check(type(lib.defs[A .. ":target"].getRect) == "function", "elements report a rect")

print("-- Off by default")
eq(P:IsActive(), false, "no owner: off")
eq(next(P.frames), nil, "no preview frames built until needed")
check(type(dfCallbacks.OnTestModeChanged) == "table", "listens for DandersFrames' test mode")
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
        eq(f.dfDB, UF:GetUnitDB(unit), unit .. ": the unit's own settings")
        check(type(f.dfTestData) == "table", unit .. ": its own fake unit (dfTestData)")
        eq(f:IsShown(), true, unit .. ": shown")
        check(f ~= UF.frames[unit], unit .. ": not the live button")
        eq(f._placed, UF:GetPositionRecord(unit), unit .. ": placed at the unit's record")
    end
end
eq(#built, 6, "elements built once per unit")
for _, b in ipairs(built) do
    check(b.preview and b.standalone and b.test and b.db == UF:GetUnitDB(b.unit) and b.raid == false,
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

print("-- DandersFrames test mode (/df test)")
DF._testActive.party = true
dfCallbacks.OnTestModeChanged.fn("OnTestModeChanged", "party", true)
eq(P:IsOwnedBy("test"), true, "test mode on: the preview follows")
eq(P:IsActive(), true, "...on")
DF._testActive.party = false
dfCallbacks.OnTestModeChanged.fn("OnTestModeChanged", "party", false)
eq(P:IsActive(), false, "test mode off: off")
UF:GetGlobalDB().includeInTestMode = false
eq(UF:IncludeInTestMode(), false, "option off")
DF._testActive.raid = true
dfCallbacks.OnTestModeChanged.fn("OnTestModeChanged", "raid", true)
eq(P:IsActive(), false, "option off: test mode leaves unit frames alone")
UF:GetGlobalDB().includeInTestMode = nil
eq(UF:IncludeInTestMode(), true, "unset: on (the default)")
P:SyncTestMode()
eq(P:IsActive(), true, "re-synced when the option changes (raid test still on)")
DF._testActive.raid = false
P:SyncTestMode()
eq(P:IsActive(), false, "off again")

print("-- Owners stack")
P:SetOwner("settings", true)
lib.cbs.Unlocked()
lib.cbs.Locked()
eq(P:IsActive(), true, "the session ending leaves the Settings switch's preview up")
P:SetOwner("settings", false)
eq(P:IsActive(), false, "...until it is switched off too")

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
P:SetOwner("settings", true)
eq(P:IsActive(), true, "the switch works in combat (plain frames)")
for unit, f in pairs(UF.frames) do eq(f._shown, before[unit], unit .. ": live button not shown or hidden") end
P:SetOwner("settings", false)
for unit, f in pairs(UF.frames) do eq(f._shown, before[unit], unit .. ": ...nor on the way out") end
IN_COMBAT = false

print("-- Settings refresh repaints what is up")
P:SetOwner("settings", true)
painted = {}
UF:RefreshAll()
eq(#painted, 6, "every preview frame repainted")
P:SetOwner("settings", false)
painted = {}
UF:RefreshAll()
eq(#painted, 0, "nothing painted while off")

print("-- The Settings page and DandersFrames' hook")
local pages = options_file_source("UnitFrames/Pages.lua")
check(pages:find('L["Include Unit Frames in Test Mode"]', 1, true), "Settings page: the test-mode option")
check(pages:find('P:SetOwner("settings", on)', 1, true), "Settings page: Preview switch owns 'settings'")
local shim = df_file_source("TestMode/Shim.lua")
check(shim:find('FireAPICallback("OnTestModeChanged", scope, active)', 1, true), "DF fires OnTestModeChanged")
check(shim:find("DF:NotifyTestModeChanged(scope)", 1, true), "...from ReconcileTestMode")
local tm = options_file_source("TestMode/TestMode.lua")
local _, nNotify = tm:gsub("DF:NotifyTestModeChanged%(", "")
eq(nNotify, 4, "...and from the four Show/Hide test-frame functions")
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
