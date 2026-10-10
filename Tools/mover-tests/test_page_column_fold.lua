local NS = ...

-- ============================================================
-- A CARD LAYS OUT AT THE WIDTH IT IS ABOUT TO HAVE
-- DandersFrames_Options/GUI/Panel.lua (PageRefreshStates)
-- ------------------------------------------------------------
-- A settings group lays its children out off its CURRENT width, so the page
-- pass must size a filling band BEFORE laying it out. Sized after, the pass
-- that folds the page to one column, or back to two, lays every card out for
-- the old width: two tracks spilling out of a card that has just narrowed, a
-- widened card's controls still at the narrow width.
--
-- Panel.lua does not load headlessly, so the real functions are lifted out of
-- it by name (as test_resize_split_guide.lua does) and run over fake frames.
-- ============================================================

local src = options_file_source("GUI/Panel.lua"):gsub("\r\n", "\n")

local function cut(header)
    local s = src:find(header, 1, true)
    if not s then return nil end
    local e = src:find("\nend\n", s, true)
    return src:sub(s, e + 4)
end

local BOX = { colMargin = 5, colGutter = 20, minCol = 285, group = 280 }
local PAGEBOX = { inset = 8, gutter = 14 }
local contentW = 500
local GUIt = {
    SettingsBox = BOX, SelectedMode = "party", Space = { footer = 10 },
    contentFrame = { GetWidth = function() return contentW end },
}
local DFt = { db = { party = {} } }

local parts = { "local GUI, SettingsBox, PageBox, DF, SnapLen = ..." }
for _, header in ipairs({
    "function GUI.PageChildWidth(contentWidth)",
    "function GUI.UsesTwoColumns()",
    "function GUI.ColumnWidth()",
    "function GUI.PageUsableWidth(childWidth)",
    "function GUI.Column2X(contentWidth)",
    "local function LayoutWidthFor(widget, usesTwoColumns, usableWidth)",
    "local function PageRefreshStates(self)",
}) do
    local body = cut(header)
    check(body ~= nil, "fold: found " .. header)
    parts[#parts + 1] = body or ""
end
parts[#parts + 1] = "GUI.PageRefreshStates = PageRefreshStates"
local chunk = loadstring(table.concat(parts, "\n"), "@Panel.lua:fold")
check(chunk ~= nil, "fold: the lifted layout pass compiles")
if not chunk then do return end end
chunk(GUIt, BOX, PAGEBOX, DFt, function(_, v) return v end)

local function frame(t)
    t = t or {}
    t._w, t._shown = t._w or 280, true
    function t:SetWidth(w) self._w = w end
    function t:GetWidth() return self._w end
    function t:GetHeight() return self.calculatedHeight or self.layoutHeight or 0 end
    function t:SetHeight() end
    function t:ClearAllPoints() end
    function t:SetPoint() end
    function t:IsShown() return self._shown end
    function t:Show() self._shown = true end
    function t:Hide() self._shown = false end
    return t
end

-- A card's band: records the width it was laid out at.
local function band(col)
    local b = frame({ isSettingsGroup = true, layoutColFill = true, layoutCol = col })
    function b:LayoutChildren() self.laidOutAt = self._w; self.calculatedHeight = 100; return 100 end
    function b:RefreshChildStates() end
    return b
end

local b1, b2 = band(1), band(2)
-- A classic box: built at a fixed width, never resized.
local classic = band(1)
classic.layoutColFill = nil
local page = frame({ children = { b1, b2, classic }, child = frame() })

local function pass(w)
    contentW = w
    GUIt.PageRefreshStates(page)
end

-- usable = content - inset - gutter - 2 * colMargin
pass(500)
check(not GUIt.UsesTwoColumns(), "fold: (500 wide is one column)")
eq(b1.laidOutAt, 468, "fold: one column -- the band lays out at the full usable width")
eq(b2.laidOutAt, 468, "fold: one column -- a column-2 band does too")

pass(900)
check(GUIt.UsesTwoColumns(), "fold: (900 wide is two columns)")
local colW = GUIt.ColumnWidth()
eq(b1.laidOutAt, colW, "fold: to two columns -- the band lays out at the column width on THE SAME pass")
eq(b2.laidOutAt, colW, "fold: to two columns -- so does the column-2 band")
eq(b1:GetWidth(), b1.laidOutAt, "fold: the band's final width is the width it laid out at")

pass(500)
eq(b1.laidOutAt, 468, "fold: back to one column -- the band lays out full width on the same pass")

eq(classic.laidOutAt, 280, "fold: a classic box keeps its own width through every fold")
