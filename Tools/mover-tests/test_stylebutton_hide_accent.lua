local NS = ...

-- ============================================================
-- A STYLED BUTTON HIDDEN AFTER THE ACCENT MOVED KEEPS ITS OWN COLOUR
-- DandersUI/Widgets.lua  UI:StyleButton
-- ------------------------------------------------------------
-- A tab switch sets the new accent BEFORE the page being left is hidden, and the
-- hide undoes any hover. That undo read the live accent, so it re-themed the page
-- being left -- the border and fill of a tinted/primary button, not its label --
-- while the page's repaint stamp still said it was in its own colour. Coming back
-- to it showed a half-repainted button until it was hovered.
--
-- The REAL function is lifted out of the kit by name and run against a fake button.
-- ============================================================

print("-- StyleButton: a hide restores the colour the button was painted in")

local src = ui_file_source("Widgets.lua"):gsub("\r\n", "\n")
local s = src:find("function UI:StyleButton(btn, opts)", 1, true)
check(s ~= nil, "stylebutton: found UI:StyleButton")
if not s then return end
local e = src:find("\nend\n", s, true)
local body = src:sub(s, e + 4)

local function rgb(r, g, b) return { r = r, g = g, b = b } end
local C = rgb(0.9, 0.9, 0.9)
local chunk = assert(loadstring(
    "local SnapHeightEven, CreateElementBackdrop, C_TEXT, C_TEXT_DIM, C_HOVER, C_ELEMENT, C_PANEL, C_BORDER = ...\n"
    .. "local UI = {}\n" .. body .. "\nreturn UI", "@Widgets.lua:StyleButton"))
local UI = chunk(function(_, h) return h end, function() end, C, C, C, C, C, C)

local function fakeRegion()
    local r = {}
    function r:SetText(t) self._text = t end
    function r:SetTextColor(...) self._color = { ... } end
    function r:GetStringWidth() return 10 end
    function r:ClearAllPoints() end
    function r:SetPoint() end
    function r:SetAlpha() end
    function r:SetTexture() end
    function r:SetAllPoints() end
    function r:SetVertexColor(...) self._vc = { ... } end
    function r:SetSize() end
    return r
end
local function fakeButton(parent)
    local b = { _w = 60, _h = 18, _scripts = {}, _hooks = {} }
    function b:SetSize(w, h) self._w, self._h = w, h end
    function b:GetWidth() return self._w end
    function b:GetHeight() return self._h end
    function b:SetWidth(w) self._w = w end
    function b:SetHeight(h) self._h = h end
    function b:CreateFontString() return fakeRegion() end
    function b:SetFontString() end
    function b:CreateTexture() return fakeRegion() end
    function b:GetHighlightTexture() return nil end
    function b:SetBackdropColor(...) self._bg = { ... } end
    function b:SetBackdropBorderColor(...) self._border = { ... } end
    function b:SetScript(k, f) self._scripts[k] = f end
    function b:HookScript(k, f) local t = self._hooks[k] or {}; t[#t + 1] = f; self._hooks[k] = t end
    function b:Fire(k)
        if self._scripts[k] then self._scripts[k](self) end
        for _, f in ipairs(self._hooks[k] or {}) do f(self) end
    end
    function b:IsEnabled() return true end
    function b:SetEnabled() end
    function b:SetAlpha() end
    function b:GetParent() return parent end
    return b
end

local PURPLE, TEAL = rgb(0.6, 0.3, 0.9), rgb(0.2, 0.7, 0.8)
local live = rgb(PURPLE.r, PURPLE.g, PURPLE.b)
local host = setmetatable({ GetAccent = function() return live end }, { __index = UI })
local function setLive(c) live.r, live.g, live.b = c.r, c.g, c.b end   -- mutated in place, as the host does
local function near(a, b) return math.abs(a - b) < 1e-6 end
local function borderIs(btn, c, k, tag)
    local got = btn._border or {}
    check(near(got[1] or -1, c.r * k) and near(got[2] or -1, c.g * k) and near(got[3] or -1, c.b * k), tag)
end

local parent = {}
for _, case in ipairs({ { "tinted", { tinted = true }, 0.5 }, { "primary", { primary = true }, 0.4 } }) do
    local name, extra, k = case[1], case[2], case[3]
    setLive(PURPLE)
    local btn = fakeButton(parent)
    local opts = { width = 60, height = 18, text = "Customise" }
    for kk, v in pairs(extra) do opts[kk] = v end
    host:StyleButton(btn, opts)
    borderIs(btn, PURPLE, k, name .. ": built in the accent that was up")

    -- The tab being entered sets its accent, THEN the page being left is hidden.
    setLive(TEAL)
    btn:Fire("OnHide")
    borderIs(btn, PURPLE, k, name .. ": hidden after the accent moved, it keeps its own colour")

    -- The repaint walk is what moves it, and a later hide keeps that.
    btn.UpdateTheme()
    borderIs(btn, TEAL, k, name .. ": the theme repaint moves it")
    setLive(PURPLE)
    btn:Fire("OnHide")
    borderIs(btn, TEAL, k, name .. ": ...and the next hide keeps the repainted colour")

    -- A real mouse-out still reads the live accent: it is on the page being looked at.
    btn:Fire("OnEnter")
    btn:Fire("OnLeave")
    borderIs(btn, PURPLE, k, name .. ": a mouse-out rests in the live accent")
end
