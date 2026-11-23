local NS = ...

-- ============================================================
-- UNIT FRAMES COMPANION -- BLIZZARD FRAME HIDING
-- DandersFrames_UnitFrames/BlizzardHide.lua
-- ------------------------------------------------------------
-- Per unit source: claims (so DF's own Hide Default Player Frame stands down),
-- event strip + reparent through DF.BlizzardHide, the combat queue, the alt-power
-- bars (events only, never reparented) and the one-frame-later re-hide after
-- Edit Mode re-parents a frame.
-- ============================================================

local G, G_NAMES = {}, { "DandersFrames", "CreateFrame", "C_Timer", "hooksecurefunc", "EditModeManagerFrame",
                     "PlayerFrame", "TargetFrame", "TargetFrameToT", "AlternatePowerBar", "MonkStaggerBar",
                     "EvokerEbonMightBar", "DemonHunterSoulFragmentsBar", "FocusFrame", "FocusFrameToT" }
for _, k in ipairs(G_NAMES) do G[k] = _G[k] end

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

local HIDDEN = { name = "hiddenParent" }

local function BlizzFrame(name, unit)
    local f = { _name = name, unit = unit, _parent = UIParent, _unregistered = 0, _hidden = false }
    function f:GetName() return self._name end
    function f:GetParent() return self._parent end
    function f:SetParent(p)
        self._parent = p
        if self._setParentHook then self._setParentHook(self, p) end
    end
    function f:UnregisterAllEvents() self._unregistered = self._unregistered + 1 end
    function f:Hide() self._hidden = true end
    return f
end

local claims, stripped, reparented = {}, {}, {}
local DF = { PartyDefaults = {}, registered = {} }
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable(key, spec) self.registered[key] = spec; return true end
function DF:ClaimBlizzardFrame(name, owner) claims[name] = owner; return true end
DF.BlizzardHide = {
    StripEvents = function(frame, full) stripped[frame] = full end,
    Reparent = function(frame)
        reparented[frame] = (reparented[frame] or 0) + 1
        frame:SetParent(HIDDEN)
        frame:Hide()
    end,
}

local timers = {}
C_Timer = { After = function(d, fn) timers[#timers + 1] = { d = d, fn = fn } end }
local function runTimers()
    local list = timers
    timers = {}
    for _, t in ipairs(list) do t.fn() end
end
hooksecurefunc = function(obj, method, fn)
    if method == "SetParent" then obj._setParentHook = fn end
end
EditModeManagerFrame = { _shown = false, IsShown = function(self) return self._shown end }
local editModeExit = {}
EventRegistry = { RegisterCallback = function(_, event, fn) editModeExit[#editModeExit + 1] = event == "EditMode.Exit" and fn or nil end }
CreateFrame = nil

local function freshWorld()
    PlayerFrame = BlizzFrame("PlayerFrame", "player")
    PlayerFrame.healthbar = BlizzFrame("PlayerFrameHealthBar")
    TargetFrame = BlizzFrame("TargetFrame", "target")
    TargetFrame.totFrame = BlizzFrame("TargetFrameToTChild")
    TargetFrameToT = BlizzFrame("TargetFrameToT", "targettarget")
    AlternatePowerBar = BlizzFrame("AlternatePowerBar")
    MonkStaggerBar = BlizzFrame("MonkStaggerBar")
    EvokerEbonMightBar = nil       -- absent on this client: must not error
    DemonHunterSoulFragmentsBar = BlizzFrame("DemonHunterSoulFragmentsBar")
    claims, stripped, reparented = {}, {}, {}
end

DandersFrames = DF
local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Defaults.lua", UF)
load_uf_file_into("BlizzardHide.lua", UF)
local BH = UF.BlizzardHide
DF.db = { unitframes = deepcopy(DF.registered.unitframes.defaults) }

print("-- Source DF: claimed, stripped, reparented")
freshWorld()
BH:ApplyAll()
eq(claims.PlayerFrame, "DandersFrames_UnitFrames", "PlayerFrame claimed by the companion")
eq(claims.TargetFrame, "DandersFrames_UnitFrames", "TargetFrame claimed")
eq(claims.TargetFrameToT, "DandersFrames_UnitFrames", "TargetFrameToT claimed")
eq(stripped[PlayerFrame], true, "PlayerFrame events stripped (full)")
eq(reparented[PlayerFrame], 1, "PlayerFrame reparented")
eq(PlayerFrame:GetParent(), HIDDEN, "...to the hidden parent")
eq(PlayerFrame.healthbar._unregistered, 1, "its bars' events too")
eq(TargetFrame.totFrame._unregistered, 1, "TargetFrame's ToT child's events too")
eq(reparented[TargetFrame], 1, "TargetFrame reparented")
eq(AlternatePowerBar._unregistered, 1, "alt power bar: events unregistered")
eq(MonkStaggerBar._unregistered, 1, "stagger bar: events unregistered")
eq(reparented[MonkStaggerBar], nil, "...never reparented")
eq(MonkStaggerBar:GetParent(), UIParent, "...keeps its parent")

print("-- Source Blizzard / Hidden")
freshWorld()
UF:GetUnitDB("player").source = "Blizzard"
UF:GetUnitDB("target").source = "Hidden"
BH:ApplyAll()
eq(claims.PlayerFrame, nil, "Blizzard source: PlayerFrame not claimed")
eq(reparented[PlayerFrame], nil, "...not hidden")
eq(AlternatePowerBar._unregistered, 0, "...alt power bars left alone")
eq(claims.TargetFrame, "DandersFrames_UnitFrames", "Hidden source: TargetFrame claimed")
eq(reparented[TargetFrame], 1, "...and hidden")
UF:GetUnitDB("player").source = nil
UF:GetUnitDB("target").source = nil

print("-- Combat: claim now, hide later")
freshWorld()
IN_COMBAT = true
BH:HideUnit("player")
eq(claims.PlayerFrame, "DandersFrames_UnitFrames", "claimed at once (bookkeeping, combat-safe)")
eq(reparented[PlayerFrame], nil, "not reparented in combat")
eq(stripped[PlayerFrame], nil, "not stripped in combat")
eq(AlternatePowerBar._unregistered, 1, "alt power bars: events off at once (combat-legal)")
check(UF:IsQueued("hide:PlayerFrame"), "the hide is queued")
eq(BH:HideFrame("PlayerFrame"), false, "a direct hide in combat refuses")
IN_COMBAT = false
UF:FlushCombatQueue()
eq(reparented[PlayerFrame], 1, "after combat: reparented")
eq(stripped[PlayerFrame], true, "...and stripped")

print("-- Edit Mode re-parents: re-hidden one frame later")
freshWorld()
BH:HideUnit("player")
eq(reparented[PlayerFrame], 1, "hidden")
eq(#timers, 0, "our own reparent schedules nothing")
PlayerFrame:SetParent(UIParent)          -- Edit Mode's layout pass
eq(PlayerFrame:GetParent(), UIParent, "not undone inside the hook")
eq(#timers, 1, "a re-hide is scheduled")
eq(timers[1] and timers[1].d, 0, "...one frame later")
PlayerFrame:SetParent(UIParent)
eq(#timers, 1, "a second re-parent before it runs schedules nothing more")
runTimers()
eq(reparented[PlayerFrame], 2, "re-hidden")
eq(PlayerFrame:GetParent(), HIDDEN, "...back on the hidden parent")

print("-- ...but not while Edit Mode is open")
EditModeManagerFrame._shown = true
PlayerFrame:SetParent(UIParent)
runTimers()
eq(reparented[PlayerFrame], 2, "Edit Mode open: waits")
eq(#timers, 0, "...without polling")
eq(#editModeExit, 1, "one EditMode.Exit callback")
EditModeManagerFrame._shown = false
editModeExit[1]()
runTimers()
eq(reparented[PlayerFrame], 3, "Edit Mode closed: re-hidden")

print("-- ...and not in combat")
PlayerFrame:SetParent(UIParent)
IN_COMBAT = true
runTimers()
eq(reparented[PlayerFrame], 3, "combat: waits")
check(UF:IsQueued("rehide:PlayerFrame"), "...queued for combat end")
IN_COMBAT = false
UF:FlushCombatQueue()
eq(reparented[PlayerFrame], 4, "combat over: re-hidden")

print("-- Missing frames")
local saveTF = TargetFrameToT
TargetFrameToT = nil
eq(BH:HideFrame("TargetFrameToT"), false, "a frame the client does not have: nothing happens")
TargetFrameToT = saveTF

print("-- Blizzard's player cast bar follows ours (spec Q7)")
local heldCB = PlayerCastingBarFrame
local g = UF:GetGlobalDB()
g.hideBlizzardCastbar = nil
eq(BH:ShouldHideCastBar(), true, "unset, our player cast bar on (the default): Blizzard's hidden")
UF:GetUnitDB("player").castbarEnabled = false
eq(BH:ShouldHideCastBar(), false, "our player cast bar off: Blizzard's shown (never none)")
UF:GetUnitDB("player").castbarEnabled = nil
UF:GetUnitDB("player").source = "Blizzard"
eq(BH:ShouldHideCastBar(), false, "Blizzard draws the player: its cast bar too")
UF:GetUnitDB("player").source = nil
g.hideBlizzardCastbar = false
eq(BH:ShouldHideCastBar(), false, "the user's own 'no' wins")
g.hideBlizzardCastbar = true
UF:GetUnitDB("player").castbarEnabled = false
eq(BH:ShouldHideCastBar(), true, "...and their own 'yes'")
UF:GetUnitDB("player").castbarEnabled = nil
g.hideBlizzardCastbar = nil
freshWorld()
PlayerCastingBarFrame = BlizzFrame("PlayerCastingBarFrame", "player")
BH:ApplyAll()
eq(reparented[PlayerCastingBarFrame], 1, "ApplyAll: hidden by default with the player frame")
PlayerCastingBarFrame = heldCB

print("-- Focus target (v1.1): FocusFrameToT")
freshWorld()
FocusFrame = BlizzFrame("FocusFrame", "focus")
FocusFrameToT = BlizzFrame("FocusFrameToT", "focustarget")
BH:ApplyAll()
eq(claims.FocusFrame, "DandersFrames_UnitFrames", "FocusFrame claimed (its own target-of-focus goes with it)")
eq(claims.FocusFrameToT, "DandersFrames_UnitFrames", "FocusFrameToT claimed for the focus target")
eq(reparented[FocusFrameToT], 1, "...and hidden")
freshWorld()
FocusFrame = BlizzFrame("FocusFrame", "focus")
FocusFrameToT = BlizzFrame("FocusFrameToT", "focustarget")
UF:GetUnitDB("focus").source = "Blizzard"
BH:ApplyAll()
eq(claims.FocusFrame, nil, "a Blizzard focus: FocusFrame left alone")
eq(reparented[FocusFrameToT], 1, "...but ours (or a hidden) focus target still hides Blizzard's")
UF:GetUnitDB("focustarget").source = "Blizzard"
freshWorld()
FocusFrame = BlizzFrame("FocusFrame", "focus")
FocusFrameToT = BlizzFrame("FocusFrameToT", "focustarget")
BH:ApplyAll()
eq(reparented[FocusFrameToT], nil, "a Blizzard focus target under a Blizzard focus: left alone")
UF:GetUnitDB("focus").source = nil
UF:GetUnitDB("focustarget").source = nil

-- By NAME, not pairs(G): a global that was nil before is skipped by pairs and
-- would leak this file's stub into every later suite.
for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
IN_COMBAT = false
