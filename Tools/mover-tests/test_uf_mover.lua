local NS = ...

-- ============================================================
-- UNIT FRAMES COMPANION -- DANDERSMOVER BRIDGE
-- DandersFrames_UnitFrames/Mover.lua
-- ------------------------------------------------------------
-- Registration keys, titles and defaults per spec §1.5, the record handed to the
-- lib being the stored table itself, secure elements, ToT relevance, and the
-- lib-absent fallback (nothing registered; Units applies point/x/y).
-- ============================================================

local G, G_NAMES = {}, { "DandersFrames", "CreateFrame", "LibStub", "UnitExists" }
for _, k in ipairs(G_NAMES) do G[k] = _G[k] end

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

local DF = { PartyDefaults = {}, registered = {} }
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable(key, spec) self.registered[key] = spec; return true end
DF.L = setmetatable({}, { __index = function(_, k) return "L:" .. k end })
DandersFrames = DF
CreateFrame = nil

-- ---- a fake DandersMover-1.0 ----
local lib = { addons = {}, defs = {}, applied = {} }
function lib:RegisterAddon(name, opts) self.addons[name] = opts end
function lib:Register(addon, key, def) self.defs[addon .. ":" .. key] = def end
function lib:Apply(addon, key) self.applied[#self.applied + 1] = addon .. ":" .. key end
lib.ApplyPosition = function() end
lib.targets, lib.refreshed = {}, {}
function lib:RegisterAnchorTarget(addon, key, def) self.targets[addon .. ":" .. key] = def end
function lib:RefreshMovedTargets(addon, keys)
    self.refreshed[#self.refreshed + 1] = addon .. ":" .. table.concat(keys, ",")
    return 0
end
LibStub = function(name, silent)
    if name == "DandersMover-1.0" then return lib end
end

local exists = {}
UnitExists = function(u) return exists[u] and true or false end

local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Defaults.lua", UF)
load_uf_file_into("Mover.lua", UF)
local M = UF.Mover
DF.db = { unitframes = deepcopy(DF.registered.unitframes.defaults) }

local positioned = {}
UF.Units = { ApplyPosition = function(_, f) positioned[#positioned + 1] = f.dfUFUnit end }

local function fakeFrame(unit)
    local f = FakeUIFrame(110, 24)
    f.dfUFUnit = unit
    f:SetFakeParent(UIParent)
    return f
end

print("-- Lib present")
eq(M.lib, lib, "the lib is picked up through LibStub")
UF.frames.player = fakeFrame("player")
UF.frames.target = fakeFrame("target")
UF.frames.targettarget = fakeFrame("targettarget")
check(M:Init(), "registered")
check(M:Init(), "a second init is a no-op")
local A = "DandersFrames_UnitFrames"
eq(M.ADDON_KEY, A, "addon key")
check(lib.addons[A] ~= nil, "addon registered")
eq(lib.addons[A] and lib.addons[A].title, "L:Unit Frames", "...titled from the locale")

local P, T, TT = lib.defs[A .. ":player"], lib.defs[A .. ":target"], lib.defs[A .. ":targettarget"]
check(P and T and TT, "player, target and target of target registered")
eq(lib.defs[A .. ":focus"], nil, "nothing for units not spawned")
if P and T and TT then
    eq(P.title, "L:Player", "player title")
    eq(T.title, "L:Target", "target title")
    eq(TT.title, "L:Target of Target", "target of target title")
    for key, def in pairs({ player = P, target = T, targettarget = TT }) do
        eq(def.secure, true, key .. ": secure (combat writes deferred)")
        eq(def.getFrame(), UF.frames[key], key .. ": its frame")
        eq(def.getPos(), DF.db.unitframes.units[key].position, key .. ": the stored record itself")
        eq(def.group, "L:Unit Frames", key .. ": grouped")
        check(def.default ~= UF.UnitDefaults[key].position, key .. ": default is a copy")
    end
    eq(P.default.point, "CENTER", "player default point")
    eq(P.default.x, -280, "player default x")
    eq(P.default.y, -200, "player default y")
    eq(T.default.x, 280, "target default x")
    eq(T.default.y, -200, "target default y")
    eq(TT.default.anchor and TT.default.anchor.target, A .. ":target.outer", "target of target anchors to target's outer rect")
    eq(TT.default.anchor and TT.default.anchor.edge, "right", "...its right edge")
    eq(TT.default.anchor and TT.default.anchor.align, "start", "...aligned to the start")
    local fb = TT.default.anchor and TT.default.anchor.fallback
    eq(fb and fb.target, A .. ":target", "...falling back to the target frame")
    eq(fb and (fb.edge .. "/" .. fb.align .. "/" .. fb.offsetX), "right/start/49",
        "...past the default portrait (2 + 46 + 1)")
    eq(TT.default.x .. "," .. TT.default.y, "496,-189", "...x/y the solve gives at the default target and portrait")
    eq(P.isRelevant, nil, "player always relevant")
    eq(T.isRelevant, nil, "target always relevant (an absent target holds its place)")
    eq(TT.isRelevant(), false, "target of target: irrelevant without a target")
    exists.target = true
    eq(TT.isRelevant(), true, "...relevant with one")
    local w, h = TT.getSize()
    eq(w, 110, "size in UIParent units")
    eq(h, 24, "size in UIParent units")

    positioned = {}
    local rec = P.getPos()
    rec.x = 10
    P.onChanged(rec, "drag")
    eq(positioned[1], "player", "onChanged re-applies the frame's position")
    IN_COMBAT = true
    T.onChanged(T.getPos(), "drag")
    eq(positioned[2], nil, "in combat: waits")
    IN_COMBAT = false
    UF:FlushCombatQueue()
    eq(positioned[2], "target", "...then applies")
end

lib.applied = {}
M:ApplyAll()
eq(#lib.applied, 3, "apply re-solves every registered element")

print("-- Focus target (v1.1): its own element, anchored to focus")
UF.frames.focus = fakeFrame("focus")
UF.frames.focustarget = fakeFrame("focustarget")
local FT = M:BuildDef("focustarget")
check(FT ~= nil, "focus target: an element of its own (registered at Init like every spawned unit)")
if FT then
    eq(FT.title, "L:Focus Target", "focus target title")
    eq(FT.getFrame(), UF.frames.focustarget, "its frame")
    eq(FT.default.anchor and FT.default.anchor.target, A .. ":focus.outer", "anchors to the focus's outer rect")
    eq(FT.default.anchor and FT.default.anchor.fallback and FT.default.anchor.fallback.target, A .. ":focus",
        "...falling back to the focus frame")
    eq(FT.default.anchor and FT.default.anchor.edge, "right", "...its right edge, like target of target")
    exists.focus = false
    eq(FT.isRelevant(), false, "irrelevant without a focus")
    exists.focus = true
    eq(FT.isRelevant(), true, "...relevant with one")
end

print("-- Outer rects: the frame widened by a portrait outside it")
do
    local OT = lib.targets[A .. ":target.outer"]
    check(OT ~= nil, "target.outer: an anchor target")
    eq(lib.targets[A .. ":focus.outer"], nil, "...none for a unit that was not registered at Init")
    if OT then
        eq(OT.partOf, A .. ":target", "...part of the target element (no anchoring target to it)")
        eq(OT.snappable, false, "...no snap zones")
        check(OT.title:find("L:Target", 1, true) == 1 and OT.title:find("L:Portrait", 1, true) ~= nil, "...titled from the locale")
        eq(OT.getFrame(), UF.frames.target, "...the target frame")
    end
    -- Geometry: a stand-in portrait reach, 0 on the left and 49 on the right.
    local reach = { 0, 49 }
    local savedPO, savedE = UF.Portrait, UF.Elements
    UF.Portrait = { OutsideExtent = function() return reach[1], reach[2] end }
    UF.Elements = { Kit = { DB = function() return {} end } }
    local f = UF.frames.target
    f:Show()
    f:SetFakeCenter(1240, 340)
    local plain, outer = M:RectFor("target"), M:OuterRect("target")
    eq(outer.w, plain.w + 49, "a portrait on the right: 49 wider")
    eq(outer.x, plain.x + 24.5, "...grown to the right only (the centre moves half of it)")
    eq(outer.y .. "," .. outer.h, plain.y .. "," .. plain.h, "...the frame's height and centre line (alignment unchanged)")
    eq(outer.x + outer.w / 2, plain.x + plain.w / 2 + 49, "...its right edge past the portrait")
    reach = { 30, 0 }
    outer = M:OuterRect("target")
    eq(outer.x - outer.w / 2, plain.x - plain.w / 2 - 30, "a portrait on the left: grown to the left")
    eq(outer.x + outer.w / 2, plain.x + plain.w / 2, "...its right edge is the frame's")
    reach = { 0, 0 }
    local o0, r0 = M:OuterRect("target"), M:RectFor("target")
    eq(o0.x .. "," .. o0.y .. "," .. o0.w .. "," .. o0.h, r0.x .. "," .. r0.y .. "," .. r0.w .. "," .. r0.h,
        "no portrait outside: the frame's own rect")
    f:Hide()
    eq(M:OuterRect("target"), nil, "nothing on screen: nothing (the lib holds what is anchored to it)")
    UF.Portrait, UF.Elements = savedPO, savedE
    -- The layout tick asks the lib to re-solve what hangs off an outer rect that moved.
    lib.refreshed = {}
    M:RefreshOuter()
    eq(lib.refreshed[1], A .. ":target.outer,focus.outer", "RefreshOuter: the outer keys")
    check(uf_file_source("Core.lua"):find("if UF.Mover and UF.Mover.RefreshOuter then UF.Mover:RefreshOuter() end", 1, true),
        "UF:RefreshAll runs it after every layout pass")
end

print("-- Lib absent")
LibStub = function() return nil end
local UF2 = {}
load_uf_file_into("Core.lua", UF2)
load_uf_file_into("Defaults.lua", UF2)
load_uf_file_into("Mover.lua", UF2)
eq(UF2.Mover.lib, nil, "no lib")
eq(UF2.Mover:Init(), false, "nothing registered without the mover")
UF2.Mover:ApplyAll()   -- must not error
check(true, "apply is a no-op without the mover")
local src = uf_file_source("Units.lua")
check(src:find("Without DandersMover", 1, true) and src:find('SetPoint(pos.point or "CENTER", UIParent, "CENTER"', 1, true),
      "Units applies point/x/y itself when the lib is absent")

-- By NAME, not pairs(G): a global that was nil before is skipped by pairs and
-- would leak this file's stub into every later suite.
for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
DandersFrames = G.DandersFrames
IN_COMBAT = false
