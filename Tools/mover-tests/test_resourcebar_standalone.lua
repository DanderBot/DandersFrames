local NS = ...

-- ============================================================
-- RESOURCE BAR: A STANDALONE FRAME KEEPS ITS BAR
-- DF:UpdateResourceBar hid the bar on any unit other than player / partyN /
-- raidN. FullFrameRefresh runs ApplyResourceBarLayout (shows it) and then this,
-- so a standalone frame on another unit lost its bar until the unit's power
-- next changed. Lifted and run against stubs.
-- ============================================================

local function norm(s) return (s:gsub("\r\n", "\n")) end
local SRC = norm(df_file_source("Frames/Bars.lua"))
local a = SRC:find("\nfunction DF:UpdateResourceBar%(")
local b = a and SRC:find("\nend\n", a, true)
check(a ~= nil and b ~= nil, "lift: DF:UpdateResourceBar")
if not (a and b) then return end

local function bar()
    local t = { shown = true }
    function t:IsShown() return self.shown end
    function t:Hide() self.shown = false end
    function t:SetMinMaxValues(lo, hi) self.max = hi end
    function t:SetStatusBarColor() end
    return t
end

local db = { resourceBarEnabled = true }
local DFs = {}
function DFs:GetFrameDB() return db end
function DFs:GetResourceBarColor() return 1, 1, 1 end
DFs.SetBarValue = function(b, v) b.value = v end

local f, err = loadstring(SRC:sub(a + 1, b + 4), "=UpdateResourceBar")
check(f ~= nil, "lift: parses (" .. tostring(err) .. ")")
if not f then return end
setfenv(f, setmetatable({
    DF = DFs,
    UnitExists = function() return true end,
    UnitPower = function() return 40 end,
    UnitPowerMax = function() return 100 end,
}, { __index = _G }))
f()

local standalone = { unit = "target", dfStandalone = true, dfPowerBar = bar() }
DFs:UpdateResourceBar(standalone)
check(standalone.dfPowerBar.shown, "a standalone frame on target keeps its bar")
eq(standalone.dfPowerBar.value, 40, "...and gets its value")

local group = { unit = "target", dfPowerBar = bar() }
DFs:UpdateResourceBar(group)
check(not group.dfPowerBar.shown, "a group frame on a non-group unit still hides it, as before")

-- The same unit gate in the absorb, heal absorb and heal prediction painters:
-- every one exempts a standalone frame, so a target or focus frame paints them.
do
    local _, n = SRC:gsub("not frame%.dfStandalone and unit ~= \"player\"", "")
    eq(n, 4, "resource, absorb, heal absorb and heal prediction all exempt a standalone frame")
    local _, raw = SRC:gsub("%(unit ~= \"player\" and not unit:match", "")
    eq(raw, 0, "...and no ungated copy of the check is left")
end

local party = { unit = "party2", dfPowerBar = bar() }
DFs:UpdateResourceBar(party)
check(party.dfPowerBar.shown and party.dfPowerBar.value == 40, "a party unit is unchanged")
