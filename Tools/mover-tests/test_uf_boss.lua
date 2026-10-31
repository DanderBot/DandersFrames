local NS = ...

-- ============================================================
-- UNIT FRAMES COMPANION -- BOSS
-- DandersFrames_UnitFrames/Boss.lua (+ its hooks in Units, Core, Preview,
-- BlizzardHide and Mover)
-- ------------------------------------------------------------
-- N slots on one shared settings table, per-slot unit events, the engage settle
-- (a secret GUID counts as changed), the layout per growth direction / spacing /
-- wrap, Blizzard's boss container claimed and reparented (and only it), the
-- combat queue, the mover element's union rect + visible offset + slot targets,
-- and the preview slots.
-- ============================================================

local G, G_NAMES = {}, { "DandersFrames", "CreateFrame", "C_Timer", "RegisterUnitWatch", "RegisterStateDriver",
                     "ClickCastFrames", "UnitGUID", "UnitExists", "UnitHasVehicleUI", "issecretvalue",
                     "LibStub", "hooksecurefunc", "MAX_BOSS_FRAMES", "BossTargetFrameContainer",
                     "Boss1TargetFrame", "Boss2TargetFrame", "Boss3TargetFrame", "Boss4TargetFrame",
                     "Boss5TargetFrame", "EditModeManagerFrame" }
for _, k in ipairs(G_NAMES) do G[k] = _G[k] end

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

-- ---- DF stub: every updater counts its calls per frame (by frame key) ----
local count = {}
local function key(f) return tostring(f and (f.dfUFKey or f.dfUFUnit)) end
local function bump(name, f) local k = name .. ":" .. key(f); count[k] = (count[k] or 0) + 1 end
local function n(name, k) return count[name .. ":" .. k] or 0 end

local DF = { PartyDefaults = { frameWidth = 125 }, registered = {}, standalone = {}, ranged = {},
             claims = {}, reparented = {}, stripped = {} }
DF.L = setmetatable({}, { __index = function(_, k) return k end })
function DF:Debug() end
function DF:DebugWarn() end
local errs = {}
function DF:DebugError(_, fmt, ...) errs[#errs + 1] = string.format(fmt, ...) end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable(k, spec) self.registered[k] = spec; return true end
function DF:InitStandaloneFrame(f, db) self.standalone[f] = db; f.dfStandalone = true; f.dfDB = db; return f end
function DF:RegisterRangeFrame(f) self.ranged[f] = true end
function DF:ClaimBlizzardFrame(name, owner) self.claims[name] = owner end
for _, name in ipairs({ "FullFrameRefresh", "UpdateHealthFast", "UpdatePower", "UpdateAbsorb", "UpdateHealAbsorb",
                        "UpdateHealPrediction", "UpdateAuras", "UpdateDefensiveBar", "UpdateDispelOverlay",
                        "UpdateName", "UpdateFrameBorderUnitColor", "UpdateUnitFrame", "UpdateHighlights",
                        "UpdateRange", "ApplyFrameLayout", "UpdateTextDesigner" }) do
    DF[name] = function(_, f) bump(name, f) end
end
local hiddenParent = { _name = "hidden" }
DF.BlizzardHide = {
    StripEvents = function(frame) DF.stripped[frame] = true end,
    Reparent = function(frame) DF.reparented[frame] = true; frame:SetParent(hiddenParent) end,
}

-- ---- client stubs ----
local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
local function runTimers()
    local list = timers
    timers = {}
    for _, fn in ipairs(list) do fn() end
end
local watched, drivers = {}, {}
RegisterUnitWatch = function(f) watched[f] = true end
RegisterStateDriver = function(f, state, cond) drivers[#drivers + 1] = { f = f, state = state, cond = cond } end
ClickCastFrames = {}
local guids = {}
UnitGUID = function(u) return guids[u] end
UnitExists = function() return false end
UnitHasVehicleUI = function() return false end
local SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
issecretvalue = function(v) return v == SECRET end
local hooks = {}
hooksecurefunc = function(obj, method, fn) hooks[#hooks + 1] = { obj = obj, method = method, fn = fn } end
MAX_BOSS_FRAMES = 5
EditModeManagerFrame = nil

-- ---- a fake DandersMover-1.0 ----
local lib = { defs = {}, targets = {}, applied = {} }
function lib:RegisterAddon() end
function lib:Register(addon, k, def) self.defs[addon .. ":" .. k] = def end
function lib:RegisterAnchorTarget(addon, k, def) self.targets[addon .. ":" .. k] = def end
function lib:Apply(addon, k) self.applied[#self.applied + 1] = addon .. ":" .. k end
function lib.RegisterCallback() end
lib.ApplyPosition = function(frame, pos)
    frame:ClearAllPoints()
    frame:SetPoint(pos.point or "CENTER", UIParent, "CENTER", pos.x or 0, pos.y or 0)
end
LibStub = function(name) if name == "DandersMover-1.0" then return lib end end

local created = {}
CreateFrame = function(kind, name, parent, template)
    local f = setmetatable(FakeUIFrame(0, 0), nil)
    f._kind, f._name, f._template, f._shown = kind, name, template, true
    f._attrs, f._events, f._hooks = {}, {}, {}
    f:SetFakeParent(parent)
    function f:GetName() return self._name end
    function f:SetParent(p) self._parent = p end
    function f:SetAttribute(k, v) self._attrs[k] = v end
    function f:GetAttribute(k) return self._attrs[k] end
    function f:RegisterEvent(ev) self._events[ev] = { "*" } end
    function f:RegisterUnitEvent(ev, ...) self._events[ev] = { ... } end
    function f:UnregisterEvent(ev) self._events[ev] = nil end
    function f:HookScript(name2, fn)
        self._hooks[name2] = self._hooks[name2] or {}
        table.insert(self._hooks[name2], fn)
    end
    local function fire(self, name2)
        for _, fn in ipairs(self._hooks[name2] or {}) do fn(self) end
    end
    function f:Show() if not self._shown then self._shown = true; fire(self, "OnShow") end end
    function f:Hide() if self._shown then self._shown = false; fire(self, "OnHide") end end
    created[#created + 1] = f
    return f
end

-- Blizzard's boss frames.
local function Blizz(name, unit)
    local f = { _name = name, unit = unit, _parent = UIParent, _hidden = false, _unregistered = 0 }
    function f:GetName() return self._name end
    function f:GetParent() return self._parent end
    function f:SetParent(p) self._parent = p end
    function f:Hide() self._hidden = true end
    function f:UnregisterAllEvents() self._unregistered = self._unregistered + 1 end
    return f
end
BossTargetFrameContainer = Blizz("BossTargetFrameContainer")
for i = 1, 5 do _G["Boss" .. i .. "TargetFrame"] = Blizz("Boss" .. i .. "TargetFrame", "boss" .. i) end

DandersFrames = DF
local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Defaults.lua", UF)
load_uf_file_into("Units.lua", UF)
load_uf_file_into("Preview.lua", UF)
load_uf_file_into("Boss.lua", UF)
load_uf_file_into("BlizzardHide.lua", UF)
load_uf_file_into("Mover.lua", UF)
local Units, B, BH, M, P = UF.Units, UF.Boss, UF.BlizzardHide, UF.Mover, UF.Preview
DF.db = { unitframes = deepcopy(DF.registered.unitframes.defaults) }
local db = UF:GetUnitDB("boss")
local N = UF.BOSS_COUNT

print("-- The count is one constant (Q13)")
eq(N, 5, "v1 draws boss1-5")
check(B.driver and B.driver._events.INSTANCE_ENCOUNTER_ENGAGE_UNIT, "a shared listener for INSTANCE_ENCOUNTER_ENGAGE_UNIT")
eq(UF.SPAWNED_UNITS[#UF.SPAWNED_UNITS], "boss", "boss is one of the spawned units")

print("-- Defaults")
eq(db.healthColorMode, "CLASS_REACTION", "health: class / reaction")
eq(db.castbarEnabled, true, "cast bar on")
eq(db.portraitEnabled, false, "portrait off")
eq(db.bossGrowth, "DOWN", "grows down")
eq(db.bossSpacing, 40, "40 between frames")
eq(db.bossUnitsPerRow, N, "every slot in one line")
eq(db.bossPreviewNum, N, "all five sample bosses")

print("-- Spawn: not in combat")
IN_COMBAT = true
eq(Units:Spawn("boss"), nil, "in combat: no secure frames made")
eq(B.container, nil, "...no container")
UF:RunOutOfCombat("init", function() Units:SpawnAll() end)
check(UF:IsQueued("init"), "start-up in combat waits for the fight to end")
IN_COMBAT = false
UF:FlushCombatQueue()

print("-- Spawn: N slots, one shared table")
local c = B.container
check(c ~= nil, "a container")
eq(c:GetName(), "DandersUnitFrameBossContainer", "...named")
eq(c._template, "SecureFrameTemplate", "...secure, it hosts secure buttons")
eq(c:GetParent(), Units.holders.boss, "...under the boss holder (the Visibility driver)")
eq(#B.frames, N, "N slots")
for i = 1, N do
    local f = B.frames[i]
    eq(f:GetName(), "DandersUnitFrameBoss" .. i, "slot " .. i .. ": named")
    eq(f._attrs.unit, "boss" .. i, "slot " .. i .. ": unit boss" .. i)
    eq(f.unit, "boss" .. i, "slot " .. i .. ": .unit for the ping mixin")
    eq(f.dfUFUnit, "boss", "slot " .. i .. ": the boss settings unit")
    eq(f.dfUFSlot, i, "slot " .. i .. ": knows its slot")
    eq(DF.standalone[f], db, "slot " .. i .. ": standalone on the ONE boss table (Q8)")
    eq(UF.frames["boss" .. i], f, "slot " .. i .. ": UF.frames.boss" .. i)
    check(watched[f], "slot " .. i .. ": unit watch")
    check(DF.ranged[f], "slot " .. i .. ": range fading (DF's registry)")
    check(ClickCastFrames[f], "slot " .. i .. ": click-casting")
    eq(f:GetParent(), c, "slot " .. i .. ": in the container")
    check(not f:IsShown(), "slot " .. i .. ": hidden until its boss exists")
end
eq(UF.frames.boss, nil, "no frame under the bare settings unit")
eq(Units:Spawn("boss"), c, "spawning again answers the container")
eq(#B.frames, N, "...and makes nothing new")
local holderDriver
for _, d in ipairs(drivers) do if d.f == Units.holders.boss then holderDriver = d end end
check(holderDriver and holderDriver.cond:find("%[petbattle%] hide"), "the holder carries the visibility driver")

print("-- Profile change: every slot follows to the new boss table")
local oldDb = db
DF.db = { unitframes = deepcopy(DF.registered.unitframes.defaults) }
UF:RebuildUnitDBs()
db = UF:GetUnitDB("boss")
check(db ~= oldDb, "a new boss table")
for i = 1, N do eq(B.frames[i].dfDB, db, "slot " .. i .. " reads it") end
eq(DF.db.unitframes.units.boss1, nil, "no per-slot table was made")

print("-- Events: per slot, only while shown")
local f3 = B.frames[3]
f3:Show()
eq(f3._events.UNIT_HEALTH and f3._events.UNIT_HEALTH[1], "boss3", "UNIT_HEALTH for boss3 only")
eq(f3._events.UNIT_TARGETABLE_CHANGED and f3._events.UNIT_TARGETABLE_CHANGED[1], "boss3", "...UNIT_TARGETABLE_CHANGED")
check(n("FullFrameRefresh", "boss3") >= 1, "shown: a full repaint")
Units.OnEvent(f3, "UNIT_HEALTH", "boss2")
eq(n("UpdateHealthFast", "boss3"), 0, "another boss's event is ignored")
Units.OnEvent(f3, "UNIT_HEALTH", "boss3")
eq(n("UpdateHealthFast", "boss3"), 1, "its own is painted")
f3:Hide()
eq(next(f3._events), nil, "hidden: every event dropped")

print("-- Engage settle: identity re-check, a secret GUID counts as changed")
for i = 1, N do guids["boss" .. i] = nil end
guids.boss1, guids.boss2 = "Creature-1", "Creature-2"
local f1, f2 = B.frames[1], B.frames[2]
f1:Show(); f2:Show()
runTimers()
eq(f1.dfUFLastGUID, "Creature-1", "shown: its GUID noted")
local before1, before2 = n("FullFrameRefresh", "boss1"), n("FullFrameRefresh", "boss2")
B.driver:GetScript("OnEvent")(B.driver, "INSTANCE_ENCOUNTER_ENGAGE_UNIT")
eq(#timers, 3, "engage: a next-frame repaint per shown slot + one settle check")
runTimers()
eq(n("FullFrameRefresh", "boss1"), before1 + 1, "...slot 1 repainted")
eq(n("FullFrameRefresh", "boss2"), before2 + 1, "...slot 2 repainted")
eq(n("FullFrameRefresh", "boss3"), 1, "...a hidden slot is not")
-- After the settle: the same NPC is left alone; a swapped one is repainted.
guids.boss2 = "Creature-9"
B.driver:GetScript("OnEvent")(B.driver, "INSTANCE_ENCOUNTER_ENGAGE_UNIT")
B.driver:GetScript("OnEvent")(B.driver, "INSTANCE_ENCOUNTER_ENGAGE_UNIT")
local settles = 0
for _ in ipairs(timers) do settles = settles + 1 end
eq(settles, 3, "two engages in one frame: coalesced (2 slot repaints + 1 settle)")
local b1, b2 = n("FullFrameRefresh", "boss1"), n("FullFrameRefresh", "boss2")
runTimers()
eq(n("FullFrameRefresh", "boss1"), b1 + 1, "settle: slot 1 had its next-frame repaint only (same GUID)")
eq(n("FullFrameRefresh", "boss2"), b2 + 2, "settle: slot 2's new NPC repainted again by the identity check")
eq(f2.dfUFLastGUID, "Creature-9", "...and noted")
guids.boss1 = SECRET
check(B:CheckIdentity(f1), "a secret GUID counts as changed")
eq(f1.dfUFLastGUID, nil, "...and is never stored")
check(B:CheckIdentity(f1), "...every time")
guids.boss1 = "Creature-1"
check(B:CheckIdentity(f1), "back to a plain GUID: changed once")
check(not B:CheckIdentity(f1), "...then settled")
-- UNIT_TARGETABLE_CHANGED: that slot only.
local t1, t2 = n("FullFrameRefresh", "boss1"), n("FullFrameRefresh", "boss2")
Units.OnEvent(f2, "UNIT_TARGETABLE_CHANGED", "boss2")
runTimers()
eq(n("FullFrameRefresh", "boss2"), t2 + 1, "targetable changed: that slot repainted")
eq(n("FullFrameRefresh", "boss1"), t1, "...no other")
f1:Hide(); f2:Hide()
eq(f1.dfUFLastGUID, nil, "hidden: identity forgotten")

print("-- Layout: growth direction, spacing, wrap")
local function pts(f) local p = f._points[1]; return p and table.concat({ p[1], tostring(p[3]), p[4], p[5] }, " ") end
db.frameWidth, db.frameHeight, db.bossSpacing, db.bossRowSpacing, db.frameScale = 180, 40, 40, 4, 1.2
db.bossGrowth, db.bossUnitsPerRow = "DOWN", 5
B:ApplyLayout()
eq(pts(B.frames[1]), "TOPLEFT TOPLEFT 0 0", "down: slot 1 at the top-left corner")
eq(pts(B.frames[2]), "TOPLEFT TOPLEFT 0 -80", "down: slot 2 one frame + spacing below")
eq(pts(B.frames[5]), "TOPLEFT TOPLEFT 0 -320", "down: slot 5")
eq(c._w .. "x" .. c._h, "180x360", "down: the container fits all five (5*40 + 4*40)")
eq(c._scale, 1.2, "frame scale is the container's")
Units:ApplyLayout(B.frames[1])
eq(B.frames[1]._scale, 1, "...a slot itself stays at 1")
db.bossGrowth = "UP"
B:ApplyLayout()
eq(pts(B.frames[2]), "BOTTOMLEFT BOTTOMLEFT 0 80", "up: from the bottom-left corner, upwards")
db.bossGrowth = "RIGHT"
B:ApplyLayout()
eq(pts(B.frames[3]), "TOPLEFT TOPLEFT 440 0", "right: frame + spacing to the right")
eq(c._w .. "x" .. c._h, "1060x40", "right: one row")
db.bossGrowth = "LEFT"
B:ApplyLayout()
eq(pts(B.frames[2]), "TOPRIGHT TOPRIGHT -220 0", "left: from the top-right corner, leftwards")
db.bossGrowth, db.bossUnitsPerRow = "RIGHT", 2
B:ApplyLayout()
eq(pts(B.frames[3]), "TOPLEFT TOPLEFT 0 -44", "right, 2 per row: slot 3 wraps to a row below (+ row spacing)")
eq(pts(B.frames[4]), "TOPLEFT TOPLEFT 220 -44", "...slot 4 beside it")
eq(c._w .. "x" .. c._h, "400x128", "...three rows")
db.bossGrowth = "DOWN"
B:ApplyLayout()
eq(pts(B.frames[3]), "TOPLEFT TOPLEFT 184 0", "down, 2 per column: slot 3 wraps to a column on the right")
db.bossUnitsPerRow = 99
eq(B:Params().perRow, N, "units per row clamps to the slot count")
db.bossGrowth = "SIDEWAYS"
eq(B:Params().growth, "DOWN", "an unknown growth falls back to down")
db.bossGrowth, db.bossUnitsPerRow, db.frameScale = "DOWN", 5, 1
B:ApplyLayout()
IN_COMBAT = true
db.bossGrowth = "UP"
UF:RefreshAll()
eq(pts(B.frames[2]), "TOPLEFT TOPLEFT 0 -80", "in combat: the layout waits")
check(UF:IsQueued("layout:bosscontainer"), "...queued for the fight's end")
check(UF:IsQueued("layout:boss2"), "...each slot under its own key")
IN_COMBAT = false
UF:FlushCombatQueue()
eq(pts(B.frames[2]), "BOTTOMLEFT BOTTOMLEFT 0 80", "...applied after it")
db.bossGrowth = "DOWN"
B:ApplyLayout()

print("-- Position: the container carries the record")
local pos = UF:GetPositionRecord("boss")
eq(pos.point .. " " .. pos.x .. " " .. pos.y, "CENTER 480 120", "default CENTER (480, 120)")
c:ClearAllPoints()
Units:ApplyPosition(B.frames[4])
local cp = c._points[1]
eq(cp and (cp[1] .. " " .. cp[4] .. " " .. cp[5]), "CENTER 480 120", "a slot's ApplyPosition places the container")

print("-- Blizzard: only the container is reparented; combat queues it")
IN_COMBAT = true
BH:HideUnit("boss")
eq(DF.claims.BossTargetFrameContainer, "DandersFrames_UnitFrames", "container claimed")
eq(DF.claims.Boss3TargetFrame, "DandersFrames_UnitFrames", "boss frames claimed")
check(UF:IsQueued("hide:boss"), "in combat: queued")
eq(BossTargetFrameContainer:GetParent(), UIParent, "...nothing moved yet")
IN_COMBAT = false
UF:FlushCombatQueue()
eq(BossTargetFrameContainer:GetParent(), hiddenParent, "the container is reparented to the hidden parent")
for i = 1, 5 do
    local bf = _G["Boss" .. i .. "TargetFrame"]
    eq(bf:GetParent(), UIParent, "Boss" .. i .. "TargetFrame keeps its parent")
    check(bf._hidden and DF.stripped[bf], "...but is hidden and its events stripped")
end
local hooked = false
for _, h in ipairs(hooks) do if h.obj == BossTargetFrameContainer and h.method == "SetParent" then hooked = true end end
check(hooked, "the container is re-hidden after Edit Mode re-parents it")
DF.reparented = {}
local bossSource = db.source
db.source = "Blizzard"
check(not BH:ShouldHide("boss"), "source Blizzard: left alone")
db.source = bossSource

print("-- Mover: element + slot targets")
M:Init()
local def = lib.defs["DandersFrames_UnitFrames:boss"]
check(def ~= nil, "element 'boss' registered")
check(M.registered.boss, "...known to the bridge (Edit in Mover)")
eq(def.title, "Boss", "titled Boss")
eq(def.secure, true, "secure (its slots are)")
eq(def.pointLocked, nil, "not pointLocked (DF's party container is not)")
eq(def.getPos(), pos, "the record is the stored table itself")
for i = 1, N do
    local t = lib.targets["DandersFrames_UnitFrames:boss.slot" .. i]
    check(t ~= nil, "slot target " .. i)
    if t then
        eq(t.partOf, "DandersFrames_UnitFrames:boss", "...part of the boss element")
        eq(t.snappable, false, "...no snap zones")
        eq(t.title, "Boss " .. i, "...titled")
    end
end
eq(lib.defs["DandersFrames_UnitFrames:boss.castbar"], nil, "no detached boss cast bar element")
eq(def.getRect(), nil, "no boss up: no rect (the lib holds children)")
-- Slots 1 and 2 up, at known centres.
f1:Show(); f2:Show()
f1._w, f1._h, f2._w, f2._h = 180, 40, 180, 40
f1:SetFakeCenter(960 + 570, 540 + 140)
f2:SetFakeCenter(960 + 570, 540 + 60)
local r = def.getRect()
eq(r and string.format("%g %g %g %g", r.x, r.y, r.w, r.h), "570 100 180 120", "rect: the union of the shown slots")
eq(lib.targets["DandersFrames_UnitFrames:boss.slot2"].getRect().y, 60, "slot target: that slot's rect")
eq(lib.targets["DandersFrames_UnitFrames:boss.slot3"].getRect(), nil, "...nil while its boss is absent")
-- visibleOffset: down, 180x40 frames, 40 spacing -> container 180x360, CENTER record.
local dx, dy = def.visibleOffset({ point = "CENTER", x = 0, y = 0 })
eq(string.format("%g %g", dx, dy), "0 120", "visible offset: slots 1-2 sit 120 above the container's centre")
dx, dy = def.visibleOffset({ point = "TOPLEFT", x = 0, y = 0 })
eq(string.format("%g %g", dx, dy), "90 -60", "...from a TOPLEFT record: half a frame right, 60 down")
f1:Hide(); f2:Hide()
eq(def.visibleOffset({ point = "CENTER", x = 0, y = 0 }), nil, "no slot shown: the plain write")
local wantW, wantH = def.getSize()
eq(wantW .. "x" .. wantH, "180x360", "size: the container's")

print("-- Preview: N sample bosses, one casting")
P:SetOwner("unlock", true)
check(B.previewShown, "a mover session shows the boss preview")
local pc = B.previewContainer
check(pc and pc:IsShown(), "...in a non-secure container")
eq(#B.preview, N, "...N sample bosses")
for i = 1, N do
    local pf = B.preview[i]
    eq(pf.dfUFSlot, i, "preview " .. i .. ": its slot")
    eq(pf.dfUFUnit, "boss", "preview " .. i .. ": the boss table")
    check(pf.dfIsTestFrame and pf.dfPreview, "preview " .. i .. ": a test frame in test scope")
    eq(pf.dfTestData.level, -1, "preview " .. i .. ": level -1 (drawn ??)")
    eq(pf.dfTestData.classification, "worldboss", "preview " .. i .. ": a world boss")
    eq(pf.dfTestData.name, "Boss " .. i, "preview " .. i .. ": named")
    eq(pf.dfUFPreviewIdle, i ~= 1, "preview " .. i .. ": " .. (i == 1 and "casting" or "idle"))
    check(pf:IsShown(), "preview " .. i .. ": shown")
end
eq(pts(B.preview[2]), "TOPLEFT TOPLEFT 0 -80", "laid out like the live slots")
local ppc = pc._points[1]
eq(ppc and (ppc[1] .. " " .. ppc[4] .. " " .. ppc[5]), "CENTER 480 120", "...at the same record")
eq(def.getFrame(), pc, "the element stands for the preview container while it is up")
for i = 1, N do B.preview[i]._w, B.preview[i]._h = 180, 40; B.preview[i]:SetFakeCenter(960 + 570, 540 + 140 - (i - 1) * 80) end
r = def.getRect()
eq(r and string.format("%g %g", r.w, r.h), "180 360", "rect: the union of the preview slots")
db.bossPreviewNum = 3
P:Refresh()
check(B.preview[3]:IsShown() and not B.preview[4]:IsShown(), "Preview Frames = 3: three shown")
db.bossPreviewNum = 99
eq(B:PreviewCount(), N, "Preview Frames clamps to the slot count")
db.bossPreviewNum = N
P:SetOwner("unlock", false)
check(not B.previewShown and not pc:IsShown(), "session over: the boss preview hides")
db.bossPreviewCount = false
P:SetOwner("test", true)
check(not B.previewShown, "test mode with Show Placeholder Frames off: no boss preview")
P:SetOwner("settings", true)
check(B.previewShown, "...but the Settings page's Preview still shows them")
P:SetOwner("settings", false)
check(not B.previewShown, "...and drops them again")
db.bossPreviewCount = true
P:Refresh()
check(B.previewShown, "Show Placeholder Frames on: test mode shows them")
P:SetOwner("test", false)
check(not B.previewShown, "preview off: hidden")

print("-- Source: no detached boss cast bar on the settings page or the runtime")
local cbsrc = uf_file_source("CastBar.lua")
check(cbsrc:find("if f and f%.dfUFSlot then return false end"), "CastBar: a boss slot never detaches")
eq(#errs, 0, "no errors (" .. tostring(errs[1]) .. ")")

for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
IN_COMBAT = false
