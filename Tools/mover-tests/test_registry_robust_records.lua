local NS = ...
local R = NS.Registry

-- ============================================================
-- A BAD RECORD STAYS THAT ADDON'S PROBLEM
--   1. A getPos that fails (returns nothing, or errors) is reported once, keeps
--      its element out of sessions, and never reaches onChanged. It must not stop
--      anyone else's element, and it heals as soon as getPos returns a table.
--   2. Anchoring to a target that is not available yet leaves the frame where it
--      is, whichever point its record uses.
-- ============================================================
local savedCreateFrame, savedProxy, savedHandler = CreateFrame, NS.Proxy, geterrorhandler
local wasReady = R.ready
NS.Proxy = nil
R.ready = true

if not LibStub("DandersMover-1.0", true) then
    local function stub()
        local f = { _scripts = {} }
        function f:SetScript(name, fn) self._scripts[name] = fn end
        return setmetatable(f, { __index = function() return function() end end })
    end
    CreateFrame = function() return stub() end
    SlashCmdList = SlashCmdList or {}
    local uiLib = LibStub:NewLibrary("DandersUI-1.0", 1)
    if uiLib then uiLib.NewHost = function() return stub() end end
    load_addon_file("Core.lua")
    CreateFrame = savedCreateFrame
end

local Lib = LibStub("DandersMover-1.0", true)
local ADDON = "RobustRecords"

local reported = {}
geterrorhandler = function() return function(msg) reported[#reported + 1] = tostring(msg) end end

-- ---- 1. a getPos that returns nothing ---------------------------------------
local record, applied = nil, 0
Lib:Register(ADDON, "late", {
    frame     = FakeFrame(960, 540, 100, 20),
    default   = { point = "CENTER", x = 5, y = 6 },
    getPos    = function() return record end,
    onChanged = function() applied = applied + 1 end,
})
local goodPos, goodApplied = { point = "CENTER", x = 0, y = 0 }, 0
Lib:Register(ADDON, "good", {
    frame     = FakeFrame(960, 540, 100, 20),
    getPos    = function() return goodPos end,
    onChanged = function() goodApplied = goodApplied + 1 end,
})
local late, good = R:Get(ADDON .. ":late"), R:Get(ADDON .. ":good")

check(not R:IsInSession(nil, late), "a nil record keeps its element out of the session")
check(R:IsInSession(nil, good), "another addon's element is unaffected")
eq(#reported, 1, "the failure is reported")
check(reported[1]:find("must return a table", 1, true) ~= nil, "the report says what is wrong")

-- The walks every session makes: none of them may throw now.
R:Children(ADDON .. ":good")
R:WouldCreateCycle(ADDON .. ":good", ADDON .. ":late")
for _ = 1, 3 do R:GetPos(late) end
eq(#reported, 1, "it is reported once, not on every read")

Lib:Apply(ADDON, "late")
eq(applied, 0, "onChanged never receives the stand-in")
Lib:Apply(ADDON, "good")
eq(goodApplied, 1, "the other element still applies")

eq(R:GetPos(late).x, 5, "the stand-in starts from the default")

-- ---- ...and heals -----------------------------------------------------------
record = { point = "CENTER", x = 1, y = 2 }
eq(R:GetPos(late), record, "the live record is used as soon as it exists")
check(R:IsInSession(nil, late), "the element rejoins sessions")
Lib:Apply(ADDON, "late")
eq(applied, 1, "onChanged runs again")

-- A second failure after healing is news, so it is reported again.
record = nil
R:GetPos(late)
eq(#reported, 2, "a new failure is reported")

-- ---- a getPos that errors ---------------------------------------------------
Lib:Register(ADDON, "thrower", {
    frame     = FakeFrame(960, 540, 100, 20),
    getPos    = function() error("consumer bug") end,
    onChanged = function() end,
})
check(not R:IsInSession(nil, R:Get(ADDON .. ":thrower")), "an erroring getPos stays out too")
check(reported[3]:find("consumer bug", 1, true) ~= nil, "its own error is what gets reported")

-- ---- 2. anchoring to a target that is not there -----------------------------
local cornerPos = { point = "TOPLEFT", x = 100, y = 50 }
Lib:Register(ADDON, "corner", {
    frame     = FakeFrame(960, 540, 200, 40),
    getPos    = function() return cornerPos end,
    onChanged = function() end,
})
check(Lib:SetAnchor(ADDON, "corner", { target = "NotLoadedYet:thing", edge = "bottom" }),
    "SetAnchor accepts a missing target")
eq(cornerPos.point, "CENTER", "the record becomes a CENTER point")
-- A TOPLEFT at (100, 50) on a 200x40 frame has its centre at (200, 30).
eq(cornerPos.x, 200, "x is converted, so the frame does not move")
eq(cornerPos.y, 30, "y is converted, so the frame does not move")

-- A record already at CENTER is left alone.
local centrePos = { point = "CENTER", x = 7, y = 8 }
Lib:Register(ADDON, "centre", {
    frame     = FakeFrame(960, 540, 200, 40),
    getPos    = function() return centrePos end,
    onChanged = function() end,
})
Lib:SetAnchor(ADDON, "centre", { target = "NotLoadedYet:thing", edge = "bottom" })
eq(centrePos.x, 7, "a CENTER record keeps x")
eq(centrePos.y, 8, "a CENTER record keeps y")

-- No size to convert by: the point stays with its coordinates.
local unsizedPos = { point = "TOPLEFT", x = 3, y = 4 }
Lib:Register(ADDON, "unsized", {
    getFrame  = function() return nil end,
    getPos    = function() return unsizedPos end,
    onChanged = function() end,
})
Lib:SetAnchor(ADDON, "unsized", { target = "NotLoadedYet:thing", edge = "bottom" })
eq(unsizedPos.point, "TOPLEFT", "with no size the point is left alone")
eq(unsizedPos.x, 3, "with no size x is left alone")

Lib:UnregisterAddon(ADDON)
geterrorhandler = savedHandler
NS.Proxy = savedProxy
R.ready = wasReady
