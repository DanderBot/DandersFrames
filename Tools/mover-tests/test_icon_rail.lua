local NS = ...

-- ============================================================
-- UI:CreateIconRail -- the settings window's module rail (DandersUI/IconRail.lua)
--
-- The real file is loaded over a stub host: its own frames, a recording
-- selection marker and recording tooltips. What is checked is the rail's
-- contract -- slots, order, select (paint only), badge, disabled -- not pixels.
--
-- ⚠ A FRESH NAMESPACE and private frames: FakeUIFrame answers every unset key
-- with a truthy no-op, which would read as "hovered" / "disabled" here.
-- ☠ Every global it replaces is restored at the end.
-- ============================================================

local prevCreateFrame = CreateFrame

local function Region()
    local r = { shown = true, points = {}, alpha = 1 }
    function r:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function r:ClearAllPoints() self.points = {} end
    function r:SetAllPoints() end
    function r:SetSize(w, h) self.w, self.h = w, h end
    function r:SetWidth(w) self.w = w end
    function r:SetHeight(h) self.h = h end
    function r:Show() self.shown = true end
    function r:Hide() self.shown = false end
    function r:IsShown() return self.shown end
    function r:SetAlpha(a) self.alpha = a end
    function r:SetTexture(t) self.texture = t end
    function r:SetVertexColor(r_, g, b, a) self.color = { r_, g, b, a } end
    function r:SetColorTexture(r_, g, b, a) self.color = { r_, g, b, a } end
    function r:SetTextColor(r_, g, b) self.color = { r_, g, b } end
    function r:SetText(t) self.text = t end
    function r:GetText() return self.text end
    function r:SetJustifyH() end
    function r:SetWordWrap() end
    return r
end

local frames = {}
local function Frame()
    local f = Region()
    f.scripts = {}
    f.mouse = true
    function f:SetScript(k, fn) self.scripts[k] = fn end
    function f:HookScript(k, fn) self.scripts[k] = fn end
    function f:RegisterForClicks() end
    function f:EnableMouse(v) self.mouse = v end
    function f:CreateTexture() return Region() end
    function f:CreateFontString() return Region() end
    function f:GetFrameLevel() return 1 end
    function f:SetFrameLevel() end
    frames[#frames + 1] = f
    return f
end
CreateFrame = function() return Frame() end

local markerLog = {}
local tips = {}
local ACCENT = { r = 0.1, g = 0.2, b = 0.3 }
local UI = {
    Colors = {
        text = { r = 0.9, g = 0.9, b = 0.9 }, textDim = { r = 0.6, g = 0.6, b = 0.6 },
        hover = { r = 0.22, g = 0.22, b = 0.22 }, notice = { r = 0.91, g = 0.66, b = 0.25 },
        border = { r = 0.25, g = 0.25, b = 0.25 },
    },
}
function UI:GetAccent() return ACCENT end
function UI:ShowTooltip(owner, spec) tips[#tips + 1] = spec.title end
function UI:HideTooltip() tips[#tips + 1] = "hide" end
function UI:CreateSelectionMarker(parent, opts)
    local m = Region()
    m.axis = opts.axis
    function m:SetTo(target, color, instant)
        markerLog[#markerLog + 1] = { target = target, color = color, instant = instant }
        self.owner = target
    end
    function m:Clear() self.owner = nil; markerLog[#markerLog + 1] = { clear = true } end
    return m
end
local ns = { __DandersUI = UI }
load_ui_file_into("IconRail.lua", ns)

print("-- Icon rail: API, slots and order")
check(type(UI.CreateIconRail) == "function", "api: CreateIconRail is on the library")
local picked = {}
local rail = UI:CreateIconRail(Frame(), { width = 62, onSelect = function(id) picked[#picked + 1] = id end })
eq(rail.w, 62, "width: the rail takes opts.width")
eq(rail.Marker.axis, "y", "marker: a y-axis selection marker down the left edge")

local RED = { r = 1, g = 0, b = 0 }
local labelLang = "Frames"
rail:SetItems({
    { id = "group",  icon = "grid.png",  label = function() return labelLang end, accent = RED, slot = "top" },
    { id = "clicks", icon = "mouse.png", label = "Binds", tooltip = "Click-Casting", slot = "top" },
    { id = "global", icon = "gear.png",  label = "Global", slot = "bottom" },
})
eq(table.concat(rail:GetItemIds(), ","), "group,clicks,global", "items: kept in the order given")
local g, c, gl = rail:GetItem("group"), rail:GetItem("clicks"), rail:GetItem("global")
check(g and c and gl, "items: a button per item")
eq(g.Icon.texture, "grid.png", "icon: the item's texture")
eq(g.Label.text, "Frames", "label: a function label is resolved")
eq(g.points[1][1], "TOP", "slot: the first top item hangs from the rail's top")
eq(c.points[1][2], g, "slot: ...the next one under it")
eq(gl.points[1][1], "BOTTOM", "slot: a bottom item sits on the rail's bottom edge")
eq(gl.points[1][2], rail, "slot: ...anchored to the rail itself")

print("-- Icon rail: select paints, never fires onSelect")
rail:Select("group", true)
eq(rail:GetSelected(), "group", "select: remembered")
eq(#picked, 0, "select: a programmatic select does not call onSelect")
local last = markerLog[#markerLog]
check(last.target == g and last.color == RED and last.instant == true, "select: the marker lands on the item in its accent")
eq(g.Label.color[1], 1, "select: the selected label wears the accent")
check(g.Plate.shown, "select: ...over a tinted plate")
check(not c.Plate.shown, "select: the others rest with no plate")
rail:Select("clicks")
last = markerLog[#markerLog]
check(last.target == c and last.color == ACCENT, "select: no accent given falls back to the host accent")
rail:Select("nope")
check(rail:GetSelected() == nil and markerLog[#markerLog].clear, "select: an unknown id clears the marker")
rail:Select("group", true)

print("-- Icon rail: clicks, hover and tooltip")
c.scripts.OnClick(c)
eq(picked[1], "clicks", "click: onSelect gets the item id")
c.scripts.OnEnter(c)
eq(tips[#tips], "Click-Casting", "tooltip: a string tooltip is the title")
check(c.Plate.shown, "hover: the hover plate shows")
c.scripts.OnLeave(c)
check(not c.Plate.shown and tips[#tips] == "hide", "hover: ...and leaves with the tooltip")
gl.scripts.OnEnter(gl)
eq(tips[#tips - 0], "Global", "tooltip: no tooltip falls back to the label")
gl.scripts.OnLeave(gl)

print("-- Icon rail: badge")
rail:SetBadge("group", "New")
check(g.Badge.shown and g.Badge.text == "New", "badge: shown with its text")
eq(rail:GetBadge("group"), "New", "badge: readable")
rail:SetBadge("group", nil)
check(not g.Badge.shown and rail:GetBadge("group") == nil, "badge: nil removes it")

print("-- Icon rail: disabled")
rail:SetDisabled("clicks", true)
check(rail:IsDisabled("clicks") and c.alpha == 0.4 and c.mouse == false, "disabled: dimmed and deaf")
c.scripts.OnClick(c)
eq(#picked, 1, "disabled: a click does nothing")
rail:SetDisabled("clicks", false)
check(not rail:IsDisabled("clicks") and c.alpha == 1 and c.mouse == true, "disabled: back to normal")

print("-- Icon rail: refresh and re-items")
labelLang = "Cadres"
rail:Refresh()
eq(g.Label.text, "Cadres", "refresh: labels re-resolve (a language change)")
rail:SetItems({
    { id = "clicks", icon = "mouse.png", label = "Binds" },
    { id = "global", icon = "gear.png",  label = "Global", slot = "bottom" },
})
check(not g.shown, "items: an item left out is hidden")
check(rail:GetSelected() == nil, "items: ...and a selection on it is dropped")
check(rail:GetItem("clicks") == c, "items: buttons are pooled by id")

print("-- Icon rail: dividers")
rail:SetItems({
    { id = "home",   icon = "home.png",  label = "Home", slot = "top", dividerAfter = true },
    { id = "group",  icon = "grid.png",  label = "Groups", slot = "top" },
    { id = "clicks", icon = "mouse.png", label = "Binds", slot = "top" },
    { id = "global", icon = "gear.png",  label = "Global", slot = "bottom" },
})
local h = rail:GetItem("home")
local div = g.points[1][2]
check(div ~= h and div ~= rail and div.points and div.points[1][2] == h,
      "divider: the item after a dividerAfter hangs from a divider under it")
eq(div.h, 1, "divider: ...a 1px hairline")
eq(c.points[1][2], g, "divider: items without one stack as before")
rail:SetItems({
    { id = "group",  icon = "grid.png",  label = "Groups", slot = "top" },
    { id = "clicks", icon = "mouse.png", label = "Binds", slot = "top" },
})
eq(c.points[1][2], g, "divider: a set without dividers lays out without one")
check(not div.shown, "divider: ...and the unused one is hidden")

print("-- Icon rail: the kit names no consumer")
do
    local src = ui_file_source("IconRail.lua")
    check(not src:find("DF[%.:]") and not src:find("DandersFrames") and not src:find("DandersMover"),
          "kit: no DF / DandersFrames / DandersMover reference")
    local xml = ui_file_source("DandersUI_Options.xml")
    check(xml:find('<Script file="IconRail.lua"/>', 1, true) ~= nil, "manifest: listed in the options manifest")
    local core = ui_file_source("Core.lua")
    local opt = ui_file_source("OptionsCore.lua")
    local m = core:match('MINOR = "DandersUI%-1%.0", (%d+)')
    local e = opt:match("EXPECTED_MINOR = (%d+)")
    check(m ~= nil and m == e, "minor: MINOR and EXPECTED_MINOR agree")
end

CreateFrame = prevCreateFrame
