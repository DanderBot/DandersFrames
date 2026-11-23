local NS = ...
local R = NS.Registry

-- ============================================================
-- THE DEVELOPER GUIDE'S COMPLETE ADDON
-- Authors copy this example as it stands, so it is lifted out of the guide and
-- run through its load event here. If the API moves on and the example does not,
-- this fails rather than the first person to paste it.
-- ============================================================
local GUIDE = "DandersMover/docs/DEVELOPER_GUIDE.md"

local function readExample()
    local file = io.open(GUIDE, "r")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    return text:match("<!%-%- doc%-example: complete%-addon %-%->%s*```lua\r?\n(.-)```")
end

local source = readExample()
check(source ~= nil, "docs: the guide's complete addon example was found")
if not source then return end

local savedCreateFrame, savedLibStub, savedProxy = CreateFrame, LibStub, NS.Proxy
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

local Lib, libMinor = LibStub("DandersMover-1.0", true)
check(libMinor >= 9, "docs: the library is new enough for the example's version check")

-- Nothing here is about the watcher: test_watcher.lua owns that.
local W = NS.Watcher
local wasLoggedIn = W.loggedIn
W.loggedIn = false

-- Loads the example as addon `name`, with `libStub` as its LibStub (nil = not installed).
-- Hands back its bar, a function firing an event at its handler, and its events frame.
local function loadExample(name, libStub)
    local bar, handler, handlerFrame
    CreateFrame = function(_, frameName)
        local f = FakeFrame(960, 340, 200, 30)
        f._shown, f.points = true, {}
        function f:IsVisible() return true end
        function f:ClearAllPoints() self.points = {} end
        function f:SetPoint(point, rel, relPoint, x, y)
            self.points = { point = point, rel = rel, relPoint = relPoint, x = x, y = y }
            self._cx, self._cy = 960 + x, 540 + y
        end
        function f:SetScript(script, fn)
            if script == "OnEvent" then handler, handlerFrame = fn, self end
        end
        function f:RegisterEvent() end
        function f:UnregisterEvent(event) self.unregistered = event end
        function f:SetSize() end
        if frameName == "MyAddonBar" then bar = f end
        return f
    end
    LibStub = libStub
    local chunk = assert((loadstring or load)(source, "@guide-example"))
    chunk(name)
    local function fire(event, arg)
        LibStub = libStub
        handler(handlerFrame, event, arg)
        LibStub = savedLibStub
    end
    LibStub, CreateFrame = savedLibStub, savedCreateFrame
    return bar, fire, handlerFrame
end

-- ---- with the library -------------------------------------------------------
MyAddonDB = nil
local bar, fire, events = loadExample("DocExample", savedLibStub)
check(bar ~= nil, "docs: the example builds its frame")

fire("ADDON_LOADED", "SomeOtherAddon")
check(MyAddonDB == nil, "docs: another addon's ADDON_LOADED is ignored")
eq(events.unregistered, nil, "docs: the example keeps listening after another addon's load")

fire("ADDON_LOADED", "DocExample")
eq(events.unregistered, "ADDON_LOADED", "docs: the example stops listening after its own load")
eq(MyAddonDB.barPosition.y, -200, "docs: the library seeds a fresh install from the default")
eq(bar.points.y, -200, "docs: the frame is placed on load")
check(R:Get("DocExample:bar") ~= nil, "docs: the element is registered")
eq(R:GetAddon("DocExample").title, "DocExample", "docs: the addon's title falls back to its name")
eq(R:Get("DocExample:bar").title, "My Bar", "docs: the element's title is registered")

-- What the editor does: edit the live record, then notify.
local record = MyAddonDB.barPosition
record.x, record.y = 50, 60
NS:Notify(R:Get("DocExample:bar"), "drag")
eq(bar.points.x, 50, "docs: onChanged moves the frame")
eq(bar.points.y, 60, "docs: onChanged moves the frame on both axes")

-- /mover reset myaddon
NS:ResetPositions("DocExample")
eq(MyAddonDB.barPosition, record, "docs: a reset keeps the same saved table")
eq(record.y, -200, "docs: a reset restores the default")
eq(bar.points.y, -200, "docs: a reset moves the frame back")

-- A reset must not have written through to the example's own defaults.
record.y = 123
NS:ResetPositions("DocExample")
eq(record.y, -200, "docs: the default survives the record being edited")

-- The guide's "Anchor from your code": a target that has not registered yet.
record.x, record.y = 10, 20
check(Lib:SetAnchor("DocExample", "bar", { target = "LaterAddon:thing", edge = "bottom" }),
    "docs: SetAnchor accepts a target that is not registered yet")
eq(record.x, 10, "docs: the element holds while its target is missing")
eq(record.y, 20, "docs: the element holds on both axes")

Lib:RegisterAnchorTarget("LaterAddon", "thing", {
    frame = FakeFrame(960, 540, 100, 100),
    getRect = function() return { x = 0, y = 0, w = 100, h = 100 } end,
})
Lib:RefreshAnchorTarget("LaterAddon", "thing")
eq(record.x, 0, "docs: the element follows once the target arrives")
check(record.y < -50, "docs: it lands on the edge the anchor named")
check(Lib:Detach("DocExample", "bar"), "docs: Detach frees the element")
check(record.anchor == nil, "docs: Detach clears the anchor")

Lib:UnregisterAddon("LaterAddon")
Lib:UnregisterAddon("DocExample")

-- ---- a later login, with a saved position -----------------------------------
local saved = { point = "TOPLEFT", x = 7, y = 8 }
MyAddonDB = { barPosition = saved }
local savedBar, savedFire = loadExample("DocExampleSaved", savedLibStub)
savedFire("ADDON_LOADED", "DocExampleSaved")
eq(savedBar.points.point, "TOPLEFT", "docs: a saved point is used on load")
eq(savedBar.points.y, 8, "docs: a saved position is used on load")
eq(MyAddonDB.barPosition, saved, "docs: registering keeps the saved table")
eq(saved.y, 8, "docs: registering keeps the saved values")
Lib:UnregisterAddon("DocExampleSaved")

-- ---- without the library ----------------------------------------------------
MyAddonDB = nil
local plainBar, plainFire = loadExample("DocExamplePlain", nil)
plainFire("ADDON_LOADED", "DocExamplePlain")
eq(plainBar.points.y, -200, "docs: the example works with DandersMover missing")
check(R:Get("DocExamplePlain:bar") == nil, "docs: nothing registers with DandersMover missing")

-- ---- with a copy that is too old --------------------------------------------
MyAddonDB = nil
local oldCalled = false
local function oldLibStub() return { Register = function() oldCalled = true end }, 8 end
local oldBar, oldFire = loadExample("DocExampleOld", oldLibStub)
oldFire("ADDON_LOADED", "DocExampleOld")
eq(oldBar.points.y, -200, "docs: the example still places its frame on an older copy")
check(not oldCalled, "docs: the example doesn't register with an older copy")

MyAddonDB = nil
W.loggedIn = wasLoggedIn
NS.Proxy = savedProxy
R.ready = wasReady
