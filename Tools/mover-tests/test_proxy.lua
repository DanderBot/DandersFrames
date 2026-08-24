local NS = ...
local R = NS.Registry

-- ============================================================
-- FRAME STUBS
-- Proxy.lua only needs frames that remember shown state and swallow every
-- other call; a __index fallback hands out no-op methods for the rest.
-- ============================================================
-- Fx (animation) stubs: a permissive no-op animation group so FadeIn/FadeOut
-- run their state logic (Show/Hide, transition guards) without any animation.
local function permissiveAnim()
    local t = setmetatable({}, { __index = function() return function() end end })
    t.IsPlaying = function() return false end
    return t
end
local function stubAnimationGroup()
    local g = permissiveAnim()
    g.CreateAnimation = function() return permissiveAnim() end
    return g
end

local function stubFrame()
    -- dragging is read as a plain boolean by Proxy:Refresh; without a real
    -- value the __index fallback would hand back a (truthy) function and
    -- Refresh would bail before Highlight ran. fxIn/fxOut/tagShown are plain
    -- values read by Fx and applyLook for the same reason.
    local f = { _shown = false, _scripts = {}, dragging = false, _w = 10, _h = 10,
                fxIn = false, fxOut = false, fxPop = false, fxPopOut = false, fxTo = false,
                tagShown = false }
    function f:CreateAnimationGroup() return stubAnimationGroup() end
    function f:Show() self._shown = true end
    function f:Hide() self._shown = false end
    function f:IsShown() return self._shown end
    function f:SetShown(v) self._shown = v and true or false end
    function f:GetCenter() return 0, 0 end
    -- Real sizes, because the slab layout drops the coords/icon/title below
    -- fixed widths -- a stub that always answered 10 would render every proxy
    -- in its title-only form and the marker checks below would be meaningless.
    function f:SetSize(w, h) self._w, self._h = w, h end
    function f:GetWidth() return self._w end
    function f:GetHeight() return self._h end
    function f:GetSize() return self._w, self._h end
    -- Vertex colour is how the role now reads (the dot), so it is recorded.
    function f:SetVertexColor(r, g, b, a) self._vertex = { r, g, b, a } end
    function f:CreateTexture() return stubFrame() end
    function f:CreateLine() return stubFrame() end
    function f:SetScript(name, fn) self._scripts[name] = fn end
    function f:GetScript(name) return self._scripts[name] end
    return setmetatable(f, { __index = function() return function() end end })
end

-- FontString stub with deterministic metrics: 7px per character, and an
-- unbounded width so the layout's measured-fit fallback is exercised for real.
-- Records its anchor points so tests can see WHERE the title ended up.
local function stubFontString()
    local f = stubFrame()
    f._text = ""
    f._points = {}
    function f:SetText(t) self._text = t or "" end
    function f:GetText() return self._text end
    function f:GetStringWidth() return 7 * #self._text end
    function f:GetUnboundedStringWidth() return 7 * #self._text end
    function f:ClearAllPoints() wipe(self._points) end
    function f:SetPoint(...) self._points[#self._points + 1] = { ... } end
    return f
end

-- The dot's tint against a palette entry.
local function tinted(tex, color)
    local v = tex._vertex
    return v and v[1] == color.r and v[2] == color.g and v[3] == color.b
end
CreateFrame = function() return stubFrame() end
local cursorX, cursorY = 960, 540
GetCursorPosition = function() return cursorX, cursorY end
GameTooltip = stubFrame()
local shiftDown, ctrlDown = false, false
IsShiftKeyDown = function() return shiftDown end
IsControlKeyDown = function() return ctrlDown end
local COLORS = {
    textDim    = { r = 0.5,  g = 0.5,  b = 0.5 },
    text       = { r = 0.9,  g = 0.9,  b = 0.9 },
    anchorRoot = { r = 0,    g = 1,    b = 0 },
    anchored   = { r = 0.55, g = 0.40, b = 0.85 },
    accent     = { r = 0.45, g = 0.45, b = 0.95 },
    background = { r = 0,    g = 0,    b = 0 },
    panel      = { r = 0.12, g = 0.12, b = 0.12 },
    border     = { r = 0.25, g = 0.25, b = 0.25 },
    danger     = { r = 0.8,  g = 0.2,  b = 0.2 },
}
NS.UI = {
    MEDIA = "",
    Colors = COLORS,
    Space = { section = 10 }, RowGap = 14, RowGapTight = 8, RowHeight = { checkbox = 35 },
    GetAccent = function() return { r = 0, g = 0, b = 1 } end,
    CreateElementBackdrop = function() end,
    ApplyPixelBorder = function() end,
    CreateLabel = function(_, _, opts)
        local f = stubFontString()
        if opts and opts.text then f:SetText(opts.text) end
        return f
    end,
    CreateCheckbox = function() return stubFrame() end,
    CreateButton = function(_, _, opts)
        local b = stubFrame()
        if opts and opts.width then b._w = opts.width end
        return b
    end,
    CreateGlyphButton = function(_, _, opts)
        local b = stubFrame()
        if opts and opts.size then b._w, b._h = opts.size, opts.size end
        return b
    end,
}
NS.Grid = { HidePreview = function() end, HideMeasure = function() end, SetAxisLock = function() end }
NS.Lib = NS.Lib or { callbacks = { Fire = function() end } }   -- the winner marker the lost-copy guard checks
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

-- Role reads off the DOT's tint plus two markers: the link glyph while anchored,
-- and the root ring for the one case the dot cannot carry -- a root that is
-- itself anchored, whose dot already wears the anchored colour.
do
    local wasReady = R.ready
    R.ready = true
    NS.db = { showHiddenMovers = true, addons = {} }
    NS.Session = { selected = nil }
    R:RegisterAddon("R", { title = "R" })
    R:Register("R", "root",  elDef({ point = "CENTER", x = 0, y = 0 }))
    R:Register("R", "child", elDef({ point = "CENTER", x = 0, y = 0,
        anchor = { target = "R:root", edge = "bottom", align = "start", offsetX = 0, offsetY = 0 } }))
    R:Register("R", "grand", elDef({ point = "CENTER", x = 0, y = 0,
        anchor = { target = "R:child", edge = "bottom", align = "start", offsetX = 0, offsetY = 0 } }))
    R:Register("R", "free",  elDef({ point = "CENTER", x = 0, y = 0 }))
    P:Build()
    local root, child, grand, free =
        P.proxies["R:root"], P.proxies["R:child"], P.proxies["R:grand"], P.proxies["R:free"]
    check(tinted(root.dot, COLORS.anchorRoot), "root: dot is the anchorRoot green")
    check(not root.root:IsShown() and not root.link:IsShown(), "root: no ring, no link")
    check(tinted(child.dot, COLORS.anchored), "child+root: dot is the anchored purple")
    check(child.link:IsShown() and child.root:IsShown(), "child+root: link on, ring on")
    check(tinted(grand.dot, COLORS.anchored), "child: dot is the anchored purple")
    check(grand.link:IsShown() and not grand.root:IsShown(), "child: link on, ring off")
    check(tinted(free.dot, { r = 0, g = 0, b = 1 }), "free: dot is the host accent")
    check(not free.root:IsShown() and not free.link:IsShown(), "free: neither")
    check(P.legend and P.legend:IsShown(), "legend shown for the session")

    -- Narrow slab: the dot gives way to the icon, and a ROOT's ring re-homes
    -- onto the icon so the root state stays visible without the dot.
    R:Register("R", "tinyroot", { title = "t", frame = FakeFrame(960, 540, 50, 24),
        getPos = function() return { point = "CENTER", x = 0, y = 0 } end,
        onChanged = function() end })
    R:Register("R", "tinychild", elDef({ point = "CENTER", x = 0, y = 0,
        anchor = { target = "R:tinyroot", edge = "bottom", align = "start", offsetX = 0, offsetY = 0 } }))
    P:Build()
    local tiny = P.proxies["R:tinyroot"]
    check(not tiny.dot:IsShown() and tiny.icon:IsShown(), "narrow slab: icon shown instead of the dot")
    check(tiny.root:IsShown(), "narrow root: ring re-homed onto the icon")

    P:DestroyAll()
    check(not P.legend:IsShown(), "legend hidden on DestroyAll")
    R:UnregisterAddon("R")
    R.ready = wasReady
    NS.Session = nil
    NS.db = nil
end

-- Measured title fit. The size thresholds are only the fast path: a long title
-- on a slab that KEEPS the normal layout must still never ellipsise -- parts
-- drop out (coords, then the dot; the icon never drops) based on the measured
-- text width. Stub metrics: 7px per character.
do
    local wasReady = R.ready
    R.ready = true
    NS.db = { showHiddenMovers = true, addons = {} }
    NS.Session = { selected = nil }
    R:RegisterAddon("T", { title = "T" })
    local function def(title, w)
        return { title = title, frame = FakeFrame(960, 540, w, 40),
                 getPos = function() return { point = "CENTER", x = 0, y = 0 } end,
                 onChanged = function() end }
    end
    -- 200px slab: coords ("0, 0" = 28px) + icon leave 124px for the title.
    R:Register("T", "short", def("short", 200))                 --  5 ch =  35px: fits
    -- 140px slab: 64px with coords, 96px without, 116px title-only.
    R:Register("T", "mid",   def("Party Pinned1", 140))         -- 13 ch =  91px
    R:Register("T", "long",  def("Party Pinned 1 - NPC", 140))  -- 20 ch = 140px
    P:Build()
    local s, m, lg = P.proxies["T:short"], P.proxies["T:mid"], P.proxies["T:long"]
    check(s.coords:IsShown() and s.icon:IsShown() and s.dot:IsShown(), "short title keeps coords, icon and dot")
    check(m.icon:IsShown() and m.dot:IsShown() and not m.coords:IsShown(), "long title on a mid slab drops coords first, keeps icon and dot")
    eq(m.title:GetText(), "Party Pinned1", "dropped-coords title is the full text")
    check(lg.icon:IsShown() and not lg.dot:IsShown() and not lg.coords:IsShown(),
        "very long title drops coords AND the dot; the icon stays")
    eq(lg.title:GetText(), "Party Pinned 1 - NPC", "overflow title is the full text")
    local pt = lg.title._points[1]
    check(#lg.title._points == 1 and pt and pt[1] == "TOP" and pt[3] == "BOTTOM",
        "very long title floats below the slab, never truncated")
    check(lg.tagBg and lg.tagBg:IsShown(), "floating title carries its pill background")
    check(s.tagBg and not s.tagBg:IsShown(), "in-slab title has no pill")
    P:DestroyAll()
    R:UnregisterAddon("T")
    R.ready = wasReady
    NS.Session = nil
    NS.db = nil
end

-- The coords slot's "hidden" comes from Registry:IsTargetAvailable, not the raw
-- frame's IsShown: a consumer getRect owns visibility (DF's raid element measures
-- its test-mode preview while the real container is hidden), while elements
-- without getRect still read the frame's shown state.
do
    local wasReady = R.ready
    R.ready = true
    NS.db = { showHiddenMovers = true, addons = {} }
    NS.Session = { selected = nil }
    R:RegisterAddon("V", { title = "V" })
    -- Backing frame HIDDEN, but getRect says "this is what is visible" -- the
    -- DF-raid-in-a-real-raid shape (test container up, real container hidden).
    local hiddenFrame = FakeFrame(960, 540, 100, 40)
    hiddenFrame._shown = false
    R:Register("V", "preview", { title = "p", frame = hiddenFrame,
        getRect = function() return { x = 50, y = 25, w = 100, h = 40 } end,
        getPos = function() return { point = "CENTER", x = 0, y = 0 } end,
        onChanged = function() end })
    -- No getRect and a hidden frame: the demo's Combat Only shape out of combat.
    local offscreen = FakeFrame(960, 540, 100, 40)
    offscreen._shown = false
    R:Register("V", "off", { title = "o", frame = offscreen,
        getPos = function() return { point = "CENTER", x = 0, y = 0 } end,
        onChanged = function() end })
    P:Build()
    eq(P.proxies["V:preview"].coords:GetText(), "50, 25", "getRect visible while frame hidden: coords, not 'hidden'")
    eq(P.proxies["V:off"].coords:GetText(), NS.L["hidden"], "no getRect + hidden frame still reads 'hidden'")
    P:DestroyAll()
    R:UnregisterAddon("V")
    R.ready = wasReady
    NS.Session = nil
    NS.db = nil
end
