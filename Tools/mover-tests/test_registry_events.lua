local NS = ...
local R = NS.Registry

-- ============================================================
-- RegistryChanged: every registration / unregistration announces itself, and
-- the drained login queue announces itself exactly once.
-- ============================================================
-- Core.lua owns the public API and the fires, so it has to be loaded here. It
-- needs a few client globals and the shared UI host; stub them the way
-- test_proxy.lua stubs the frame API for Proxy.lua. The frame stub remembers
-- scripts so the ADDON_LOADED handler can be driven directly.
local function stubFrame()
    local f = { _scripts = {} }
    function f:SetScript(name, fn) self._scripts[name] = fn end
    function f:GetScript(name) return self._scripts[name] end
    return setmetatable(f, { __index = function() return function() end end })
end
local created = {}
CreateFrame = function() local f = stubFrame(); created[#created + 1] = f; return f end
SlashCmdList = SlashCmdList or {}
local uiLib = LibStub:NewLibrary("DandersUI-1.0", 1)
if uiLib then uiLib.NewHost = function() return stubFrame() end end
load_addon_file("Core.lua")
local Lib = NS.Lib

-- Core's event frame: the one thing it builds with an OnEvent script.
local eventFrame
for _, f in ipairs(created) do if f:GetScript("OnEvent") then eventFrame = f end end

local listener, fired = {}, {}
Lib.RegisterCallback(listener, "RegistryChanged", function(event, addon, key)
    fired[#fired + 1] = { event = event, addon = addon, key = key }
end)
local function last() return fired[#fired] end
local function clear() for i = #fired, 1, -1 do fired[i] = nil end end

local function elDef()
    return { title = "x", frame = FakeFrame(0, 0, 10, 10),
             getPos = function() return { point = "CENTER", x = 0, y = 0 } end, onChanged = function() end }
end

-- addon / element / anchor target registration
do
    local wasReady = R.ready
    R.ready = true
    clear()
    Lib:RegisterAddon("EV", { title = "EV" })
    eq(#fired, 1, "RegisterAddon fires once")
    eq(last().event, "RegistryChanged", "event name")
    eq(last().addon, "EV", "addon named")
    check(last().key == nil, "no key for an addon-level change")

    clear()
    Lib:Register("EV", "one", elDef())
    eq(#fired, 1, "Register fires once")
    eq(last().addon, "EV", "register: addon"); eq(last().key, "one", "register: key")

    clear()
    Lib:RegisterAnchorTarget("EV", "t", { title = "t", frame = FakeFrame(0, 0, 10, 10) })
    eq(#fired, 1, "RegisterAnchorTarget fires once")
    eq(last().key, "t", "anchor target: key")

    -- the wrappers still hand back what the Registry returned
    check(Lib:Register("EV", "two", elDef()) ~= nil, "Register still returns the element")
    check(Lib:RegisterAnchorTarget("EV", "t2", { title = "t2", frame = FakeFrame(0, 0, 10, 10) }) ~= nil,
        "RegisterAnchorTarget still returns the target")

    clear()
    Lib:Unregister("EV", "one")
    eq(#fired, 1, "Unregister fires once")
    eq(last().addon, "EV", "unregister: addon"); eq(last().key, "one", "unregister: key")
    check(R:Get("EV:one") == nil, "unregister still removes the element")

    clear()
    Lib:UnregisterAddon("EV")
    eq(#fired, 1, "UnregisterAddon fires once")
    eq(last().addon, "EV", "unregister addon: addon"); check(last().key == nil, "unregister addon: no key")
    check(R:GetAddon("EV") == nil, "unregister addon still removes it")
    R.ready = wasReady
end

-- ADDON_LOADED drains the queue and announces it ONCE, with no addon/key
do
    local wasReady, wasDb = R.ready, NS.db
    R.ready = false
    R:RegisterAddon("FL", { title = "FL" })
    clear()
    Lib:Register("FL", "a", elDef())
    Lib:Register("FL", "b", elDef())
    eq(#fired, 2, "queued registrations still fire per call")
    check(R:Get("FL:a") == nil, "still queued until the flush")

    clear()
    -- The real handler: Core.lua's event frame, driven the way the client does.
    check(eventFrame ~= nil, "Core installed an OnEvent handler")
    eventFrame:GetScript("OnEvent")(eventFrame, "ADDON_LOADED", "DandersMover")
    eq(#fired, 1, "the drained queue is announced exactly once")
    check(last().addon == nil and last().key == nil, "wholesale change carries no addon/key")
    check(R:Get("FL:a") ~= nil and R:Get("FL:b") ~= nil, "queue actually drained")

    Lib:UnregisterAddon("FL")
    R.ready, NS.db = wasReady, wasDb
end

Lib.UnregisterCallback(listener, "RegistryChanged")
