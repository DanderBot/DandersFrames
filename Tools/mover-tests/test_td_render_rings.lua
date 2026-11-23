local NS = ...

-- ============================================================
-- TEXT DESIGNER: SPOT ANCHORS, BACKGROUND ELEMENTS, SHOW ON HOVER
-- DandersFrames/TextDesigner/Render.lua, loaded REAL over stub frames (the
-- resolver and the secret helpers are stubbed). Checked: a ring spot asks the
-- frame and else uses the frame's own edge, mirrors left / right, and only
-- re-anchors when it moved; a background is an empty region with a rounded
-- surface on the text overlay (Front) or an underlay (Behind), text can anchor to
-- it, it hides with its element; Show on Hover elements render at the hover alpha,
-- fade in and out on DF:OnFrameHoverChanged, slide, and the frame's own hover hook
-- runs. Not pixels.
-- ============================================================

local saved = { CreateFrame = CreateFrame, RAID_CLASS_COLORS = RAID_CLASS_COLORS, issecretvalue = issecretvalue }
issecretvalue = function() return false end

local function Make(kind, parent)
    local f = setmetatable(FakeUIFrame(0, 0), nil)
    f._kind, f._shown, f._level, f._parentFrame = kind, true, 1, parent
    f._scripts = {}
    function f:SetScript(n, fn) self._scripts[n] = fn end
    function f:SetFrameLevel(l) self._level = l end
    function f:GetFrameLevel() return self._level end
    function f:SetAllPoints() end
    function f:CreateFontString() return Make("FontString", self) end
    function f:CreateTexture(_, layer, _, sub) local t = Make("Texture", self); t._layer, t._sub = layer, sub; return t end
    function f:SetText(t) self._text = t end
    function f:SetTextColor() end
    function f:SetFont() return true end
    function f:SetColorTexture(r, g, b, a) self._color = { r, g, b, a } end
    return f
end
CreateFrame = function(kind, _, parent) return Make(kind, parent) end

local surfaces = {}
local DF = {
    L = setmetatable({}, { __index = function(_, k) return k end }),
    Debug = function() end, DebugWarn = function() end,
    DebugActive = function() return false end,
    MemTestDisabled = function() return false end,
}
function DF:SafeSetFont() return true end
function DF:GetFrameDB(f) return f.dfDB or {} end
DF.GUI = {}
function DF.GUI:CreateRoundedSurface(frame, opts)
    local s = { frame = frame, opts = opts, shown = true, textures = { Make("Texture", frame), Make("Texture", frame) } }
    function s:Hide() self.shown = false end
    function s:Show() self.shown = true end
    surfaces[#surfaces + 1] = s
    return s
end
load_df_file_into("TextDesigner/Render.lua", DF)
local Render = DF.TextDesigner.Render
DF.TextDesigner.Resolver = { Resolve = function(_, elem) return elem.contentType end }
DF.TextDesigner.MidnightSafe = { SafeText = function(t) return t end }

local function Frame()
    local f = Make("Button")
    f.unit = "player"
    f.dfDB = {}
    return f
end
local function elem(id, ct, extra)
    local e = { id = id, contentType = ct, enabled = true, anchor = "CENTER", offsetX = 0, offsetY = 0, anchorTo = "FRAME" }
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
end
local SRC = { GetClassToken = function() return nil end }

print("-- TD spots: ring anchors")
do
    local f = Frame()
    local td = { enabled = true, elements = { elem(1, "name", { anchor = "BOTTOM", anchorTo = "RING_ABOVE" }) } }
    Render:UpdateFrame(f, td, SRC, "all")
    local spot = f._tdSpots and f._tdSpots.RING_ABOVE
    check(spot ~= nil, "a spot region for the anchor")
    local p = spot._points[#spot._points]
    check(p[1] == "CENTER" and p[2] == f and p[3] == "TOP", "a frame that does not answer: its own top edge")
    local fs = f._tdFontStrings[1]
    local fp = fs._points[#fs._points]
    check(fp[1] == "BOTTOM" and fp[2] == spot and fp[3] == "BOTTOM", "the element pins the same point of itself to the spot")
    f.dfTDAnchorSpot = function(_, key) if key == "RING_ABOVE" then return 0, 40 end end
    Render:UpdateFrame(f, td, SRC, "all")
    p = spot._points[#spot._points]
    check(p[3] == "CENTER" and p[5] == 40, "a ring frame answers: 40 above its centre")
    local n = #spot._points
    Render:UpdateFrame(f, td, SRC, "all")
    eq(#spot._points, n, "an unmoved spot is not re-anchored")
    td.elements[1].anchorTo = "RING_GAP_LEFT"
    f.dfMirrorText = true
    Render:UpdateFrame(f, td, SRC, "all")
    check(f._tdSpots.RING_GAP_RIGHT ~= nil, "mirrored text: the left gap becomes the right")
    eq(Render.SPOTS.RING_CENTER, "CENTER", "the five spots are published (Anchor To lists them)")
end

print("-- TD backgrounds")
do
    surfaces = {}
    local f = Frame()
    local bd = elem(1, "backdrop", { width = 80, height = 16, shape = "PILL", color = { r = 0.1, g = 0.2, b = 0.3, a = 0.5 } })
    local txt = elem(2, "name", { anchorTo = "1" })
    local td = { enabled = true, elements = { txt, bd } }
    Render:UpdateFrame(f, td, SRC, "all")
    local region = f._tdBackdrops[1]
    check(region ~= nil and region._w == 80 and region._h == 16, "an empty region at its size")
    eq(f._tdFontStrings[1], nil, "no FontString for a background")
    local s = surfaces[#surfaces]
    check(s.frame == f._tdOverlay, "Front: the surface lives on the text overlay")
    check(s.opts.anchorTo == region and s.opts.radius == 8, "...stretched over the region, a pill's radius")
    eq(s.opts.fill[4], 0.5, "its colour")
    check(s.opts.border == false, "no border unless asked")
    local fs = f._tdFontStrings[2]
    eq(fs._points[#fs._points][2], region, "a text anchored to it (listed BEFORE it) finds it on the first pass")
    bd.layer = "BEHIND"
    Render:UpdateFrame(f, td, SRC, "all")
    s = surfaces[#surfaces]
    check(s.frame == f._tdUnderlay and f._tdUnderlay._level == f._level + 1, "Behind: on an underlay just above the frame")
    bd.enabled = false
    Render:UpdateFrame(f, td, SRC, "all")
    check(not region._shown and not s.shown, "a disabled background hides")
    bd.enabled = true
    td.elements = { txt }
    Render:UpdateFrame(f, td, SRC, "all")
    check(not region._shown, "a deleted background hides")
    td.enabled = false
    td.elements = { txt, bd }
    Render:UpdateFrame(f, { enabled = true, elements = { bd } }, SRC, "all")
    Render:UpdateFrame(f, td, SRC, "all")
    check(not region._shown, "the master toggle hides backgrounds too")
    Render:Teardown(f)
    eq(f._tdBackdrops, nil, "teardown drops them")
end

print("-- TD show on hover")
do
    local f = Frame()
    local h = elem(1, "hp_percent", { showOnHover = true, hoverSlide = 10, offsetX = 5 })
    local plain = elem(2, "name")
    local td = { enabled = true, elements = { h, plain } }
    Render:UpdateFrame(f, td, SRC, "all")
    local fs, ps = f._tdFontStrings[1], f._tdFontStrings[2]
    eq(fs._alpha, 0, "not hovered: a hover element is drawn see-through")
    eq(ps._alpha, 1, "...the others as ever")
    eq(fs._points[#fs._points][4], 15, "slid out by its Slide In")
    local hooked
    f.dfHoverHook = function(_, on) hooked = on end
    DF:OnFrameHoverChanged(f, true)
    eq(hooked, true, "the frame's own hover hook runs")
    local tick = f._tdOverlay._scripts.OnUpdate
    check(tick ~= nil, "a fade starts")
    tick(f._tdOverlay, Render.HOVER_FADE / 2)
    check(math.abs(fs._alpha - 0.5) < 1e-9, "half way in")
    eq(fs._points[#fs._points][4], 10, "...and half way home")
    tick(f._tdOverlay, Render.HOVER_FADE)
    eq(fs._alpha, 1, "fully shown")
    eq(fs._points[#fs._points][4], 5, "at its own offset")
    eq(f._tdOverlay._scripts.OnUpdate, nil, "the fade stops")
    Render:UpdateFrame(f, td, SRC, "health")
    eq(fs._alpha, 1, "a repaint while hovered keeps it shown")
    DF:OnFrameHoverChanged(f, false)
    f._tdOverlay._scripts.OnUpdate(f._tdOverlay, 1)
    eq(fs._alpha, 0, "mouse gone: faded out")
    eq(hooked, false, "...and the hook heard it")
    f._tdForceHover = true
    DF:OnFrameHoverChanged(f, false)
    f._tdOverlay._scripts.OnUpdate(f._tdOverlay, 1)
    eq(fs._alpha, 1, "Show Hover State holds it on")
    f._tdForceHover = nil
    h.showOnHover = false
    Render:UpdateFrame(f, td, SRC, "all")
    eq(fs._alpha, 1, "no longer a hover element: shown")
    check(not f._tdHoverEls[1], "...and no longer tracked")
    local g = Frame()
    DF:OnFrameHoverChanged(g, true)
    eq(g._tdHoverT, 1, "a frame with nothing to fade just records its hover")
end

print("-- TD hover: who calls it")
do
    for _, f in ipairs({ "Frames/Create.lua", "Frames/Headers.lua" }) do
        local src = df_file_source(f)
        local _, n = src:gsub("if DF.OnFrameHoverChanged then DF:OnFrameHoverChanged%(self, self.dfIsHovered%) end", "")
        eq(n, 2, f .. ": the hover handlers (enter and leave) call it, after the highlight")
    end
    local pv = uf_file_source("Preview.lua")
    check(pv:find("DF:OnFrameHoverChanged(self, true)", 1, true) and pv:find("DF:OnFrameHoverChanged(self, false)", 1, true),
          "unit frame previews: enter and leave")
    for _, f in ipairs({ "Units.lua", "Preview.lua" }) do
        local src = uf_file_source(f)
        check(src:find("f.dfTDAnchorSpot = UF.Rings and UF.Rings.AnchorSpot or nil", 1, true)
              and src:find("f.dfHoverHook = UF.OnHover", 1, true), f .. ": frames carry the ring spots and the hover hook")
    end
end

CreateFrame, RAID_CLASS_COLORS, issecretvalue = saved.CreateFrame, saved.RAID_CLASS_COLORS, saved.issecretvalue
