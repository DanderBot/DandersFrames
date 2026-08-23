local NS = ...
local R = NS.Registry

-- ============================================================
-- FRAME STUBS
-- Proxy.lua only needs frames that remember shown state and swallow every
-- other call; a __index fallback hands out no-op methods for the rest.
-- ============================================================
local function stubFrame()
    local f = { _shown = false }
    function f:Show() self._shown = true end
    function f:Hide() self._shown = false end
    function f:IsShown() return self._shown end
    function f:GetCenter() return 0, 0 end
    function f:GetSize() return 10, 10 end
    function f:CreateTexture() return stubFrame() end
    return setmetatable(f, { __index = function() return function() end end })
end
CreateFrame = function() return stubFrame() end
GetCursorPosition = function() return 0, 0 end
GameTooltip = stubFrame()
IsShiftKeyDown = function() return false end
IsControlKeyDown = function() return false end
NS.UI = {
    Colors = { textDim = { r = 0.5, g = 0.5, b = 0.5 } },
    GetAccent = function() return { r = 0, g = 0, b = 1 } end,
    CreateElementBackdrop = function() end,
    CreateLabel = function() return stubFrame() end,
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
    P:Build("X")
    check(P.proxies["X:party"] == nil, "filter does not bypass the toggle")

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
