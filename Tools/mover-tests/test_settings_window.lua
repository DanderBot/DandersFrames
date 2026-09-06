local NS = ...
local R = NS.Registry

-- ============================================================
-- THE MOVER'S SETTINGS WINDOW -- Settings.lua's lifecycle, not its widgets
-- ------------------------------------------------------------
-- Two things the window does that are invisible to a widget test:
--
--   1. IT CLOSES WITH THE SESSION IT WAS OPENED IN. It is a UIParent child (it
--      has to work with no session at all, from /mover config), so nothing took
--      it down when Save & Exit tore the session down -- only Esc did. A window
--      opened OUTSIDE a session is the user's own and stays.
--   2. IT WEARS THE CHROME SCALE, and re-takes it when the setting moves.
--
-- build() lays out a whole palette of kit widgets; none of that is under test,
-- so the frame is stood in for and Refresh is given the handful of fields it
-- walks. Every global and namespace field replaced here is restored at the end.
-- ============================================================
local prevUI, prevSession, prevDB, prevCreateFrame = NS.UI, NS.Session, NS.db, CreateFrame
local prevRegister = NS.Lib.RegisterCallback

-- The kit surface Settings.lua reads at FILE scope (row metrics) and inside
-- Refresh (a label, a colour).
NS.UI = {
    Space = { section = 10 }, RowGap = 14, RowGapTight = 8,
    RowHeight = { checkbox = 35, dropdown = 44 },
    Colors = { textDim = { r = 0.5, g = 0.5, b = 0.5 }, background = { r = 0, g = 0, b = 0 } },
    CreateLabel = function() return FakeUIFrame() end,
}
CreateFrame = function() return FakeUIFrame() end
NS.db = { scale = 1, addons = {} }
-- The scale reader lives in Proxy.lua (it sizes the strip and the toast). In
-- the full run that module is loaded; a filtered run of this file has no
-- reader, and what is under test is that the window TAKES the reader's answer.
local ownReader = NS.ChromeScale == nil
if ownReader then NS.ChromeScale = function() return NS.db.scale end end

-- Registrations are recorded rather than made: the assertions fire the handler
-- directly, and in a filtered run there may be no CallbackHandler behind the
-- library at all.
local handlers = {}
NS.Lib.RegisterCallback = function(_, event, fn) handlers[event] = fn end
local sessionActive = false
NS.Session = { IsActive = function() return sessionActive end }
load_addon_file("Settings.lua")
NS.Lib.RegisterCallback = prevRegister
local St = NS.Settings

check(type(handlers.Locked) == "function", "settings: the window listens for the session ending")
check(type(handlers.RegistryChanged) == "function", "settings: ...and still for registry changes")

-- A stand-in for build(): the fields Refresh walks, nothing else.
local function fakeWindow()
    local f = FakeUIFrame()
    f.cb, f.rows, f.expanded = {}, {}, {}
    f.gridSlider, f.snapDistSlider, f.zoneShowSlider, f.scaleSlider, f.sideRow = FakeUIFrame(), FakeUIFrame(), FakeUIFrame(), FakeUIFrame(), FakeUIFrame()
    f.content, f.listWidth = FakeUIFrame(), 100
    return f
end

-- 1. Opened from the strip mid-session: the lock takes it down.
do
    St.frame = fakeWindow()
    sessionActive = true
    St:Show()
    check(St.frame:IsShown(), "in session: Show shows")
    handlers.Locked("Locked")
    check(not St.frame:IsShown(), "in session: the session ending hides the window")
end

-- 2. Opened with no session up: a later session's end leaves it alone.
do
    St.frame = fakeWindow()
    sessionActive = false
    St:Show()
    check(St.frame:IsShown(), "no session: Show shows")
    sessionActive = true
    handlers.Locked("Locked")
    check(St.frame:IsShown(), "no session: a session ending later does not close a window the user opened on their own")
    -- ...and the user's own close resets that: re-opened inside a session, it
    -- is session chrome again.
    St:Hide()
    St:Show()
    handlers.Locked("Locked")
    check(not St.frame:IsShown(), "re-opened in session: closes with it")
    sessionActive = false
end

-- 3. The chrome scale.
do
    St.frame = fakeWindow()
    NS.db.scale = 1.3
    St:ApplyChromeScale()
    eq(St.frame:GetScale(), 1.3, "scale: the window takes the setting")
    NS.db.scale = 0.75
    St:ApplyChromeScale()
    eq(St.frame:GetScale(), 0.75, "scale: ...and re-takes it when it moves")
    St.frame = nil
    check(pcall(St.ApplyChromeScale, St), "scale: no window built yet is a no-op")
end

if ownReader then NS.ChromeScale = nil end
NS.UI, NS.Session, NS.db, CreateFrame = prevUI, prevSession, prevDB, prevCreateFrame
