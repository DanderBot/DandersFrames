local NS = ...

-- ============================================================
-- AN ICON ROW IN THE HOUSE TOOLTIP
-- DandersUI/Widgets.lua  UI:ShowTooltip(owner, { icons = ... })
-- ------------------------------------------------------------
-- The card preview's hover used a lookalike frame with its own backdrop and font.
-- It now rides the shared tooltip: a line holding a transparent spacer reserves
-- the row, and the swatches draw over it. The REAL code is lifted by name and run
-- against a fake GameTooltip.
-- ============================================================

print("-- Tooltip icons: a swatch row inside the house tooltip")

local src = ui_file_source("Widgets.lua"):gsub("\r\n", "\n")
local a = src:find("local TIP_ICON_GAP = 6", 1, true)
local b = src:find("\nfunction UI:ShowTooltip(owner, opts)", 1, true)
check(a ~= nil and b ~= nil and a < b, "tipicons: the row helper sits just above ShowTooltip")
if not (a and b) then return end
local body = src:sub(a, b)

-- ---- a fake tooltip that keeps its lines ------------------------------
local hooks, lines = {}, {}
local function region()
    local r = { _shown = false, _points = {} }
    function r:SetText(t) self._text = t end
    function r:SetSize(w, h) self._w, self._h = w, h end
    function r:ClearAllPoints() self._points = {} end
    function r:SetPoint(...) self._points[#self._points + 1] = { ... } end
    function r:SetTexture(t) self._tex = t; self._atlas = nil end
    function r:SetAtlas(t) self._atlas = t; self._tex = nil end
    function r:SetTexCoord(...) self._coords = { ... } end
    function r:SetDesaturated(v) self._desat = v end
    function r:SetVertexColor(...) self._color = { ... } end
    function r:Show() self._shown = true end
    function r:Hide() self._shown = false end
    return r
end
local GT = region()
function GT:AddLine(text) lines[#lines + 1] = region(); lines[#lines]._text = text end
function GT:NumLines() return #lines end
function GT:GetFrameLevel() return 10 end
function GT:HookScript(name, fn) hooks[name] = hooks[name] or {}; table.insert(hooks[name], fn) end
local function fire(name) for _, fn in ipairs(hooks[name] or {}) do fn() end end

local G = setmetatable({}, { __index = function(_, k)
    local n = k:match("^GameTooltipTextLeft(%d+)$")
    return n and lines[tonumber(n)] or nil
end })
local created = {}
local function CreateFrame(_, _, parent)
    local f = region()
    f._parent = parent
    function f:SetFrameLevel(l) self._level = l end
    function f:CreateTexture() local t = region(); created[#created + 1] = t; return t end
    return f
end
local C_Texture = { GetAtlasInfo = function(v) return v == "an-atlas" and {} or nil end }

local chunk = assert(loadstring(
    "local GameTooltip, CreateFrame, _G, C_Texture, MEDIA, format, ipairs = ...\n" .. body ..
    "\nreturn AddTooltipIcons, HideTooltipIcons", "@Widgets.lua:tipIcons"))
local AddTooltipIcons = chunk(GT, CreateFrame, G, C_Texture, "Kit\\Media\\", string.format, ipairs)

-- ---- three icons: one off, one inset, one an atlas ----
AddTooltipIcons({
    { texture = "a.png" },
    { texture = "sheet", coords = { 0.25, 0.5, 0, 0.25 }, inset = 3, desaturate = true },
    { texture = "an-atlas", color = { r = 1, g = 0.5, b = 0 } },
}, 24)

eq(#lines, 1, "tipicons: the row reserves exactly one tooltip line")
eq(lines[1]._text, "|TKit\\Media\\spacer.png:24:84|t",
   "tipicons: ...a transparent spacer the row's height and width (3 x 24 + 2 x 6)")
eq(#created, 3, "tipicons: a swatch per icon")
eq(created[1]._tex, "a.png", "tipicons: ...in order")
eq(created[2]._w, 24 - 6, "tipicons: an inset shrinks its swatch on both sides")
eq(created[2]._desat, true, "tipicons: an off icon is greyed")
eq(created[2]._coords and created[2]._coords[1], 0.25, "tipicons: ...and keeps its sheet slice")
eq(created[3]._atlas, "an-atlas", "tipicons: an atlas name is drawn as an atlas")
eq(created[3]._coords and created[3]._coords[2], 1, "tipicons: ...with any earlier crop cleared first")
eq(created[3]._color and created[3]._color[2], 0.5, "tipicons: a tint is applied after the texture")
eq(created[1]._color and created[1]._color[1], 1, "tipicons: ...and an untinted one is reset to white")

-- Hidden with the tooltip, either way it goes.
fire("OnTooltipCleared")
check(hooks.OnTooltipCleared and hooks.OnHide, "tipicons: the row hooks the tooltip's clear and hide")

-- A shorter list reuses the swatches and hides the spare.
lines = {}
AddTooltipIcons({ { texture = "only.png" } }, 24)
eq(#created, 3, "tipicons: a second tooltip builds nothing new")
eq(created[2]._shown, false, "tipicons: ...and hides the swatches it does not use")
eq(lines[1]._text, "|TKit\\Media\\spacer.png:24:24|t", "tipicons: ...reserving one swatch's width")

-- An enlarged END icon (negative inset: art that is mostly padding) reserves its
-- overhang, or it runs off the tooltip's edge.
lines = {}
AddTooltipIcons({ { texture = "a.png" }, { texture = "b.png", inset = -4 } }, 24)
eq(lines[1]._text, "|TKit\\Media\\spacer.png:24:58|t",
   "tipicons: an overhanging last icon widens the reserved line (54 + 4)")
eq(created[2]._w, 32, "tipicons: ...and draws past its 24 slot")

-- ShowTooltip takes the row between the title and the body lines.
check(src:find('if type(opts.icons) == "table" and #opts.icons > 0 then AddTooltipIcons(opts.icons, opts.iconSize) end\n    AddTooltipLines(self, opts.lines)', 1, true) ~= nil,
      "tipicons: ShowTooltip draws the row under the title, before the lines")
