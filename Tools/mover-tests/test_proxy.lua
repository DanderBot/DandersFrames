local NS = ...
local R = NS.Registry

-- ============================================================
-- FRAME STUBS
-- Proxy.lua only needs frames that remember shown state and swallow every
-- other call; a __index fallback hands out no-op methods for the rest.
-- ============================================================
local function stubFrame()
    -- dragging is read as a plain boolean by Proxy:Refresh; without a real
    -- value the __index fallback would hand back a (truthy) function and
    -- Refresh would bail before Highlight ran.
    local f = { _shown = false, _scripts = {}, dragging = false }
    function f:Show() self._shown = true end
    function f:Hide() self._shown = false end
    function f:IsShown() return self._shown end
    function f:SetShown(v) self._shown = v and true or false end
    function f:GetCenter() return 0, 0 end
    function f:GetSize() return 10, 10 end
    function f:CreateTexture() return stubFrame() end
    function f:SetScript(name, fn) self._scripts[name] = fn end
    function f:GetScript(name) return self._scripts[name] end
    return setmetatable(f, { __index = function() return function() end end })
end
CreateFrame = function() return stubFrame() end
local cursorX, cursorY = 960, 540
GetCursorPosition = function() return cursorX, cursorY end
GameTooltip = stubFrame()
local shiftDown, ctrlDown = false, false
IsShiftKeyDown = function() return shiftDown end
IsControlKeyDown = function() return ctrlDown end
NS.UI = {
    MEDIA = "",
    Colors = { textDim = { r = 0.5, g = 0.5, b = 0.5 }, anchorRoot = { r = 0, g = 1, b = 0 }, background = { r = 0, g = 0, b = 0 } },
    Space = { section = 10 }, RowGap = 14, RowGapTight = 8, RowHeight = { checkbox = 35 },
    GetAccent = function() return { r = 0, g = 0, b = 1 } end,
    CreateElementBackdrop = function() end,
    CreateLabel = function() return stubFrame() end,
    CreateCheckbox = function() return stubFrame() end,
}
NS.Grid = { HidePreview = function() end }
load_addon_file("Proxy.lua")
local P = NS.Proxy

local function elDef(pos)
    return { title = "x", frame = FakeFrame(960, 540, 100, 40),
             getPos = function() return pos end, onChanged = function() end }
end

-- Build only makes proxies for enabled elements, and a rebuild drops a proxy
-- whose element was turned off mid-session (the /mover config toggle path).
do
    -- test_registry.lua (which runs later) asserts the pre-Flush queueing, so
    -- register directly here and put the readiness flag back afterwards.
    local wasReady = R.ready
    R.ready = true
    NS.db = { showHiddenMovers = true, addons = {} }
    R:RegisterAddon("X", { title = "X" })
    R:Register("X", "party", elDef({ point = "CENTER", x = 0, y = 0 }))
    R:Register("X", "raid", elDef({ point = "CENTER", x = 0, y = 0 }))

    P:Build()
    check(P.proxies["X:party"] and P.proxies["X:raid"], "both proxies built while both enabled")

    R:SetEnabled("X", "party", false)
    P:DestroyAll()
    P:Build()
    check(P.proxies["X:party"] == nil, "disabled element gets no proxy")
    check(P.proxies["X:raid"] ~= nil and P.proxies["X:raid"]:IsShown(), "enabled element still has a shown proxy")
    check(P:GetUnlockFrame():IsShown(), "unlock frame shown")

    -- addon filter composes with the toggle
    P:DestroyAll()
    P:Build(R:NormalizeFilter("X"))
    check(P.proxies["X:party"] == nil, "filter does not bypass the toggle")

    -- table filter: listed keys only, none for unlisted or irrelevant elements
    R:SetEnabled("X", "party", true)
    R:Register("X", "off", elDef({ point = "CENTER", x = 0, y = 0 }))
    R:Get("X:off").isRelevant = function() return false end
    P:DestroyAll()
    P:Build(R:NormalizeFilter({ addon = "X", keys = { "party" } }))
    check(P.proxies["X:party"] ~= nil, "listed key gets a proxy")
    check(P.proxies["X:raid"] == nil, "unlisted key gets NO proxy (not a dimmed one)")
    check(P.proxies["X:off"] == nil, "irrelevant unlisted element gets no proxy")
    P:DestroyAll()
    P:Build(R:NormalizeFilter("X"))
    check(P.proxies["X:off"] == nil and P.proxies["X:raid"] ~= nil, "addon filter: relevance decides")
    P:DestroyAll()
    P:Build(R:NormalizeFilter({ addon = "X", keys = { "off" } }))
    check(P.proxies["X:off"] ~= nil, "listed irrelevant key IS proxied (key filter beats isRelevant)")
    R:Unregister("X", "off")

    -- other addons in a filtered session: zones yes, proxies only with showOtherAddons
    R:RegisterAddon("Y", { title = "Y" })
    R:Register("Y", "thing", elDef({ point = "CENTER", x = 300, y = 0 }))
    NS.db.snapToFrames = true
    NS.Session = { selected = nil, filter = R:NormalizeFilter({ addon = "X", keys = { "party" } }) }
    P:DestroyAll()
    P:Build(NS.Session.filter)
    check(P.proxies["X:party"] ~= nil and P.proxies["Y:thing"] == nil, "other addon: no proxy by default")
    P:ShowZones(R:Get("X:party"))
    local sawY = false
    for _, z in ipairs(P.dragZones) do if z.target == "Y:thing" then sawY = true end end
    check(sawY, "other addon's element still offers snap zones")
    P:HideZones()
    NS.db.showOtherAddons = true
    P:DestroyAll()
    P:Build(NS.Session.filter)
    check(P.proxies["Y:thing"] ~= nil, "other addon proxied with showOtherAddons")
    NS.db.showOtherAddons = false
    NS.Session = nil
    P:DestroyAll()
    R:UnregisterAddon("Y")

    -- addon-level toggle removes everything
    R:SetEnabled("X", nil, false)
    P:DestroyAll()
    P:Build()
    check(next(P.proxies) == nil, "addon off -> no proxies at all")

    -- Refresh on an element with no proxy is a no-op (Bridge:Init -> Lib:Apply path)
    check(pcall(P.Refresh, P, "X:party"), "Refresh of a missing proxy does not error")

    P:DestroyAll()
    R:UnregisterAddon("X")
    R.ready = wasReady
    NS.db = nil
end

-- Drag axis locks: Shift pins Y to the drag-start centre, Ctrl pins X, both
-- held is a free drag. Drives the proxy's OnDragStart/OnUpdate scripts with a
-- recording Session stub so only the proxy's own maths is under test.
do
    local wasReady = R.ready
    R.ready = true
    NS.db = { showHiddenMovers = true, snapToFrames = false, addons = {} }
    local got = {}
    NS.Session = {
        selected = nil,
        BeginDrag = function() end,
        DragTo = function(_, el, x, y) got.x, got.y = x, y; return x, y, nil end,
    }
    R:RegisterAddon("D", { title = "D" })
    -- Proxy centre is FakeFrame (960,540) = UIParent centre -> start centre (0,0).
    R:Register("D", "a", elDef({ point = "CENTER", x = 0, y = 0 }))
    P:Build()
    local b = P.proxies["D:a"]
    b.GetCenter = function() return 960, 540 end

    cursorX, cursorY = 960, 540
    b:GetScript("OnDragStart")(b)
    local tick = b:GetScript("OnUpdate")
    check(tick ~= nil, "drag installs an OnUpdate")

    cursorX, cursorY = 1000, 570               -- cursor moved +40, +30
    shiftDown, ctrlDown = false, false
    tick(b); eq(got.x, 40, "free drag x"); eq(got.y, 30, "free drag y")

    shiftDown, ctrlDown = true, false
    tick(b); eq(got.x, 40, "shift: x follows"); eq(got.y, 0, "shift: y pinned to start")

    shiftDown, ctrlDown = false, true
    tick(b); eq(got.x, 0, "ctrl: x pinned to start"); eq(got.y, 30, "ctrl: y follows")

    shiftDown, ctrlDown = true, true
    tick(b); eq(got.x, 40, "both: free x"); eq(got.y, 30, "both: free y")

    -- Releasing mid-drag frees the axis again (no first-axis latch).
    shiftDown, ctrlDown = false, false
    cursorX, cursorY = 990, 600
    tick(b); eq(got.x, 30, "released: x free again"); eq(got.y, 60, "released: y free again")

    b.dragging = false
    b:SetScript("OnUpdate", nil)
    P:DestroyAll()
    R:UnregisterAddon("D")
    R.ready = wasReady
    NS.Session = nil
    NS.db = nil
end

-- Role markers: an element something is anchored to shows the root marker,
-- an anchored element shows the link icon, a free element shows neither.
-- (Colours go through stubbed SetBackdrop* calls, so only the markers are
-- observable here.)
do
    local wasReady = R.ready
    R.ready = true
    NS.db = { showHiddenMovers = true, addons = {} }
    NS.Session = { selected = nil }
    R:RegisterAddon("R", { title = "R" })
    R:Register("R", "root",  elDef({ point = "CENTER", x = 0, y = 0 }))
    R:Register("R", "child", elDef({ point = "CENTER", x = 0, y = 0,
        anchor = { target = "R:root", edge = "bottom", align = "start", offsetX = 0, offsetY = 0 } }))
    R:Register("R", "free",  elDef({ point = "CENTER", x = 0, y = 0 }))
    P:Build()
    local root, child, free = P.proxies["R:root"], P.proxies["R:child"], P.proxies["R:free"]
    check(root.root:IsShown() and not root.link:IsShown(), "root: marker on, link off")
    check(child.link:IsShown() and not child.root:IsShown(), "child: link on, marker off")
    check(not free.root:IsShown() and not free.link:IsShown(), "free: neither")
    check(P.legend and P.legend:IsShown(), "legend shown for the session")
    P:DestroyAll()
    check(not P.legend:IsShown(), "legend hidden on DestroyAll")
    R:UnregisterAddon("R")
    R.ready = wasReady
    NS.Session = nil
    NS.db = nil
end
