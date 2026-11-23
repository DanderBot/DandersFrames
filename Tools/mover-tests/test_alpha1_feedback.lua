local NS = ...

-- ============================================================
-- v6.0.0-alpha.1 FEEDBACK
-- Pieces cut out of the source and run over stubs: the Unit Frames module's Unlock
-- button and the preview's duration binding. The two walks at the end only read the
-- source. None of it says how the game behaves.
-- ============================================================

local passed, failed = 0, 0
local function check(ok, name)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end
end
local function norm(s) return (s:gsub("\r\n", "\n")) end
local function cut(src, from, to)
    local a = src:find(from, 1, true)
    local b = src:find(to, a or 1, true)
    assert(a and b, from)
    return src:sub(a, b - 1)
end

print("-- Unlock button: the Unit Frames module's own session")
do
    local src = norm(options_file_source("UnitFrames/Pages.lua"))
    local body = cut(src, "function UFO.MoverButtonOwned()", "function UFO.ResetPosition(unit)")
    local unlockedWith, locks, active = nil, 0, false
    local lib = {
        IsUnlocked = function() return active end,
        Lock = function() locks = locks + 1; active = false end,
        Unlock = function(_, filter) unlockedWith = filter; active = true end,
    }
    local said
    local DF = { UnitFrames = { Mover = { lib = lib, ADDON_KEY = "DandersFrames_UnitFrames" } } }
    function DF:Say(text) said = text end
    local module = "party"
    local GUI = { CurrentModuleId = function() return module end }
    local UFO = { MODULE = "units" }
    local L = setmetatable({}, { __index = function(_, k) return k end })
    assert(loadstring("local DF, GUI, UFO, L = ...\n" .. body, "mover button"))(DF, GUI, UFO, L)

    check(UFO.MoverButtonOwned() == false, "on another module the button stays party or raid")
    module = "units"
    check(UFO.MoverButtonOwned() == true, "on Unit Frames it's theirs")
    UFO.ToggleMoverSession()
    check(unlockedWith == "DandersFrames_UnitFrames", "unlocks these frames")
    check(UFO.MoverSessionActive() == true, "the button can read the session")
    UFO.ToggleMoverSession()
    check(locks == 1 and UFO.MoverSessionActive() == false, "a second click locks")
    DF.UnitFrames.Mover.lib = nil
    UFO.ToggleMoverSession()
    check(said == "DandersMover is disabled", "says so with the mover off")
    check(UFO.MoverSessionActive() == false, "and reads as locked")
end

print("-- Preview duration: letting go of a colour curve")
do
    local src = norm(df_file_source("Frames/AuraContainer.lua"))
    local body = cut(src, "function AuraContainer.BindDurationTextPreview(", "local function armTestDuration(")
    local made = {}
    C_DurationUtil_held = C_DurationUtil
    C_DurationUtil = { CreateDurationTextBinding = function()
        local b = { enabled = nil }
        function b:SetFontString() end
        function b:SetDuration() end
        function b:SetEnabled(v) self.enabled = v end
        function b:SetTextColorCurve(c) self.curve = c end
        made[#made + 1] = b
        return b
    end }
    local AuraContainer = {}
    assert(loadstring("local AuraContainer, applyDurationFormatter = ...\n" .. body, "binding"))(AuraContainer, function() end)

    local store, fs, dur = {}, {}, {}
    local curve = {}
    AuraContainer.BindDurationTextPreview(fs, { colorCurve = curve, colorProperty = 1 }, dur, store, "b")
    check(#made == 1 and made[1].curve == curve, "ticked: the countdown ramps")
    AuraContainer.BindDurationTextPreview(fs, { colorCurve = curve, colorProperty = 1 }, dur, store, "b")
    check(#made == 1, "a repaint reuses the binding")
    AuraContainer.BindDurationTextPreview(fs, {}, dur, store, "b")
    check(#made == 2, "unticked: a new binding")
    check(made[1].enabled == false, "the old one stops")
    check(made[2].curve == nil and made[2].enabled == true, "the new one has no curve")
    check(store.b == made[2], "and is the one kept")
    AuraContainer.BindDurationTextPreview(fs, {}, dur, store, "b")
    check(#made == 2, "no churn while it stays unticked")
    C_DurationUtil = C_DurationUtil_held
    C_DurationUtil_held = nil
end

print("-- Frame Fade: both walks reach unit frames (source read)")
do
    local src = norm(df_file_source("Features/ElementAppearance.lua"))
    local sweep = cut(src, "local function SweepFrameFade()", "-- Hover edge for the")
    check(sweep:find("DF.StandaloneFrames", 1, true) ~= nil, "the combat and hover sweep")
    local all = cut(src, "function DF:UpdateAllFrameAppearances()", "-- (Removed) the 18-name")
    check(all:find("DF.StandaloneFrames", 1, true) ~= nil, "the settings refresh")
end

print(passed .. " passed, " .. failed .. " failed")
assert(failed == 0, "test_alpha1_feedback")
