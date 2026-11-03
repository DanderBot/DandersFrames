local NS = ...

-- ============================================================
-- UNIT FRAMES SETTINGS -- WHAT A RING DOESN'T USE
-- DandersFrames_Options/UnitFrames/Pages.lua, that section cut out and RUN over stub
-- widgets. Checked: a control a ring ignores greys and says why, on rings only; a
-- control a ring uses stays free of a stored switch the ring ignores; a colour behind
-- a mode the ring doesn't have stays reachable; Bars style reads the unit untouched.
-- Stubs: whether the real builders' controls get their keys is for the game.
-- ============================================================

local passed, failed = 0, 0
local function check(ok, name)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end
end

local src = options_file_source("UnitFrames/Pages.lua"):gsub("\r\n", "\n")
local s0 = src:find("-- WHAT A RING DOESN'T USE", 1, true)
local s1 = src:find("-- LIVE SLIDERS AND COLOURS", 1, true)
assert(s0 and s1, "the ring section in Pages.lua")

local hasClassPower = false
local DF = { UnitFrames = { Rings = { HasBar = function(_, bar) return bar == "CLASSPOWER" and hasClassPower end } } }
local UFO = { gateReasons = setmetatable({}, { __mode = "k" }) }
local L = setmetatable({}, { __index = function(_, k) return k end })
local chunk = assert(loadstring("local DF, UFO, L = ...\n" .. src:sub(s0, s1 - 1), "ring gates"))
chunk(DF, UFO, L)

local ring = { frameStyle = "RING", resourceBarEnabled = false, backgroundColorMode = "CLASS",
               healPredictionEnabled = false, classPowerEnabled = false }
local bars = { frameStyle = "BARS", resourceBarEnabled = false, backgroundColorMode = "CLASS",
               healPredictionEnabled = false, classPowerEnabled = false }

print("-- Ring gates: a control the ring ignores")
do
    local w = { dfDbKey = "resourceBarWidth" }
    UFO.ApplyRingGates({ w }, "resource")
    check(w.disableOn(ring) == true, "greys on a ring")
    check(w.disableOn(bars) == false, "stays on with Bars")
    check(w.disableReason(ring) == "Set Frame Style to Bars to change this.", "says why")
    check(w.disableReason(bars) == nil, "no reason with Bars")

    local b = { dfDbKey = "resourceBarBorderSize" }
    UFO.ApplyRingGates({ b }, "resource")
    check(b.disableOn(ring) == true, "a family by its prefix")

    local other = { dfDbKey = "resourceBarWidth" }
    UFO.ApplyRingGates({ other }, "castbar")
    check(rawget(other, "disableOn") == nil, "only on its own page")
end

print("-- Ring gates: a control the ring uses")
do
    local texture = { dfDbKey = "resourceBarTexture", disableOn = function(d) return not d.resourceBarEnabled end }
    UFO.ApplyRingGates({ texture }, "resource")
    check(texture.disableOn(ring) == false, "a stored switch the ring ignores can't grey it")
    check(texture.disableOn(bars) == true, "...and still does with Bars")

    local group = { disableChildrenOn = function(d) return not d.resourceBarEnabled end }
    UFO.ApplyRingGates({ group }, "resource")
    check(group.disableChildrenOn(ring) == false, "the same for a whole group")
    check(group.disableChildrenOn(bars) == true, "...with Bars too")

    local color = { dfDbKey = "backgroundColor", hideOn = function(d) return d.backgroundColorMode ~= "CUSTOM" end }
    UFO.ApplyRingGates({ color }, "health")
    check(color.hideOn(ring) == false, "Background Color stays reachable on a ring")
    check(color.hideOn(bars) == true, "...and follows its mode with Bars")
    check(UFO.RingView(bars) == bars, "Bars reads the unit itself")
end

print("-- Ring gates: an existing reason and a nested control")
do
    local why = function() return "Turn on X" end
    local gated = { dfDbKey = "resourceBarTexture", disableOn = function() return true end, disableReason = why }
    UFO.ApplyRingGates({ gated }, "resource")
    check(gated.disableReason(ring) == "Turn on X", "a page gate keeps its own reason")

    local child = { dfDbKey = "healPredictionWidth" }
    local parent = { groupChildren = { { widget = child } } }
    UFO.ApplyRingGates({ parent }, "healpred")
    check(child.disableOn(ring) == true, "inside a group")
end

print("-- Ring gates: Class Power only with a section of its own")
do
    local w = { dfDbKey = "classPowerWidth" }
    UFO.ApplyRingGates({ w }, "classpower")
    hasClassPower = false
    check(w.disableOn(ring) == false, "no section: the bar's layout applies")
    hasClassPower = true
    check(w.disableOn(ring) == true, "a section: it greys")
    check(w.disableReason(ring) == "Take Class Power off the rings to change this.", "says why")
    check(w.disableOn(bars) == false, "Bars never")

    local tex = { dfDbKey = "classPowerTexture", disableOn = function(d) return not d.classPowerEnabled end }
    UFO.ApplyRingGates({ tex }, "classpower")
    check(tex.disableOn(ring) == false, "a section draws whatever the stored switch says")
    hasClassPower = false
    check(tex.disableOn(ring) == true, "no section: the switch counts")
end

print("-- Ring gates: 3D controls on a 2D ring portrait")
do
    local w = { dfDbKey = "portrait3DZoom" }
    UFO.ApplyRingGates({ w }, "portrait")
    local two = { frameStyle = "RING", ringPortrait3D = "2D" }
    local three = { frameStyle = "RING", ringPortrait3D = "COVER" }
    check(w.disableOn(two) == true, "greys on 2D")
    check(w.disableOn(three) == false, "stays on 3D")
end

print(passed .. " passed, " .. failed .. " failed")
assert(failed == 0, "test_uf_ring_gates")
