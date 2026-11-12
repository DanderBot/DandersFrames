local NS = ...

-- ============================================================
-- UNIT FRAMES: FADE WHEN OUT OF RANGE (rangeFadeEnabled)
-- A per-unit switch on the Fading page (bug #1147 item 1). On by default on every
-- unit DF's range tick fades (Units.lua RANGED); off, Features/Range.lua treats the
-- frame as always in range, so the frame alpha and every per-element alpha resolve
-- to full. Pins the defaults, the link classification, the off state's full alpha,
-- the switch back on, and the page gates.
-- ============================================================

print("-- Unit frames: Fade When Out of Range switch")

local function lf(s) return (s:gsub("\r\n", "\n")) end
local function cut(src, start, closer)
    local s = src:find(start, 1, true)
    local e = s and src:find(closer or "\nend\n", s, true)
    return s and e and src:sub(s, e + #(closer or "\nend\n") - 1)
end

-- ---- defaults: every ranged unit, on; Player never --------------------------
local UNITS = lf(uf_file_source("Units.lua"))
local rangedLine = UNITS:match("local RANGED = (%b{})")
check(rangedLine ~= nil, "Units.lua has its RANGED list")
local RANGED = {}
for u in (rangedLine or ""):gmatch("(%w+) = true") do RANGED[u] = true end
check(RANGED.target and RANGED.boss and RANGED.pet, "...with target, pet and boss in it")

local DEFAULTS = lf(uf_file_source("Defaults.lua"))
local function unitBlock(unit)
    return cut(DEFAULTS, "\n    " .. unit .. " = {\n", "\n    },\n")
end
for unit in pairs(RANGED) do
    local block = unitBlock(unit)
    check(block ~= nil, unit .. ": has a defaults block")
    check(block and block:find("\n        rangeFadeEnabled = true,", 1, true) ~= nil,
        unit .. ": Fade When Out of Range is on by default")
end
local player = unitBlock("player")
check(player ~= nil and player:find("rangeFadeEnabled", 1, true) == nil,
    "player: no range fade, so no switch")

-- ---- links: an on/off switch, never linked -----------------------------------
local LINKS = lf(uf_file_source("Links.lua"))
local onOff = cut(LINKS, "Links.ON_OFF = {", "\n}\n")
check(onOff ~= nil and onOff:find('rangeFadeEnabled = "fading"', 1, true) ~= nil,
    "rangeFadeEnabled is a Fading on/off switch (Links.ON_OFF)")

-- ---- Range.lua: off = always in range ---------------------------------------
local RANGE = lf(df_file_source("Features/Range.lua"))
local updateFn = cut(RANGE, "function DF:UpdateRange(frame)")
check(updateFn ~= nil, "DF:UpdateRange can be cut out")
if not updateFn then return end

local secretFlag = {}
local answer = false                      -- what the range check says
local appearance = 0
local chunk, err = loadstring(
    "local DF, issecretvalue, CheckUnitRange, rangeCache, debugStats, DebugPrint, IsInGroup, IsInRaid, pcall = ...\n"
    .. updateFn)
check(chunk ~= nil, "the cut parses (" .. tostring(err) .. ")")
if not chunk then return end
local DF = {
    MemTestDisabled = function() return false end,
    FrameInTestScope = function() return false end,
    UnitIsUnit = function() return false end,
    DebugActive = function() return false end,
    UpdateRangeAppearance = function() appearance = appearance + 1 end,
}
local rangeCache = {}
chunk(DF, function(v) return v == secretFlag end, function() return answer end, rangeCache,
    { checks = 0, cacheHits = 0, cacheMisses = 0 }, function() end,
    function() return true end, function() return false end, pcall)

local db = { rangeFadeEnabled = false }
local f = { unit = "target", dfStandalone = true, dfDB = db, dfInRange = false }
DF:UpdateRange(f)
eq(f.dfInRange, true, "off: an out-of-range target reads as in range")
eq(appearance, 1, "...and its appearance repaints at full alpha")
DF:UpdateRange(f)
eq(appearance, 1, "...once: an unchanged answer repaints nothing")

f.dfInRange = secretFlag
DF:UpdateRange(f)
eq(f.dfInRange, true, "off: a secret answer left over is replaced, never tested")
eq(appearance, 2, "...and repainted")

db.rangeFadeEnabled = true
DF:UpdateRange(f)
eq(f.dfInRange, false, "back on: the very next check fades again, no reload")
eq(appearance, 3, "...and repaints")

rangeCache.target = false
f.dfInRange = true
DF:UpdateRange(f)
eq(f.dfInRange, false, "back on with the range answer cached: the frame still updates")

db.rangeFadeEnabled = nil
f.dfInRange = true
DF:UpdateRange(f)
eq(f.dfInRange, false, "no key (an old profile): fades as before")

local group = { unit = "party1", dfInRange = true, dfDB = { rangeFadeEnabled = false } }
DF:UpdateRange(group)
eq(group.dfInRange, false, "a group frame (not standalone) never reads the switch")

-- ---- element fades read full alpha off the forced answer --------------------
local ELEMENTS = lf(uf_file_source("Elements.lua"))
local rangeAlpha = cut(ELEMENTS, "function K.RangeAlpha(")
check(rangeAlpha ~= nil, "K.RangeAlpha can be cut out")
if rangeAlpha then
    local K = { DB = function(fr) return fr.dfDB end }
    assert(loadstring("local K, issecretvalue = ...\n" .. rangeAlpha))(K, function(v) return v == secretFlag end)
    local el = { SetAlpha = function(self, a) self.alpha = a end }
    local frame = { unit = "focus", dfStandalone = true, dfInRange = false,
        dfDB = { rangeFadeEnabled = false, oorEnabled = true } }
    DF:UpdateRange(frame)
    K.RangeAlpha(frame, el, 1, 0.2)
    eq(el.alpha, 1, "off: an element range fade draws at full alpha")
end

-- ---- the Fading page ---------------------------------------------------------
local PAGES = lf(options_file_source("UnitFrames/Pages.lua"))
local gateFn = cut(PAGES, "function UFO.Gate(")
local switchFn = cut(PAGES, "function UFO.RangeFadeSwitch(")
check(gateFn ~= nil and switchFn ~= nil, "UFO.Gate and UFO.RangeFadeSwitch can be cut out")
check(PAGES:find("self.dfRangeFade = UFO.RangeFadeSwitch(unit)", 1, true) ~= nil,
    "the Fading page hands the builder its switch")
if gateFn and switchFn then
    local UFO = { gateReasons = {} }
    local L = setmetatable({}, { __index = function(_, k) return k end })
    local DFo = { UnitFrames = { Units = { RANGED = RANGED } } }
    assert(loadstring("local UFO, L, DF, GUI, RefreshFrames, format = ...\n" .. gateFn .. switchFn))(
        UFO, L, DFo, {}, function() end, string.format)
    check(UFO.RangeFadeSwitch("player") == nil, "player: no switch on its page")
    local sw = UFO.RangeFadeSwitch("target")
    check(sw ~= nil and type(sw.build) == "function", "target: a switch the builder draws")
    if sw then
        check(sw.gate({ rangeFadeEnabled = false }), "off: the range alphas grey")
        check(not sw.gate({ rangeFadeEnabled = true }), "on: they don't")
        check(sw.elementGate({ rangeFadeEnabled = false, oorEnabled = true }), "off: element alphas grey too")
        check(sw.elementGate({ rangeFadeEnabled = true, oorEnabled = false }), "element alpha off: still grey")
        check(not sw.elementGate({ rangeFadeEnabled = true, oorEnabled = true }), "both on: live")
    end
end

local OPTIONS = lf(options_file_source("GUI/Pages/Options.lua"))
check(OPTIONS:find('local ufRangeFade = rawget(self, "dfRangeFade")', 1, true) ~= nil,
    "the party builder reads the switch with rawget (party / raid never get one)")
check(OPTIONS:find("if ufRangeFade then ufRangeFade.build(self, db, Add) end", 1, true) ~= nil,
    "...and draws it under its Range header")
