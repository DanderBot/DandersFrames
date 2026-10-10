local NS = ...

-- ============================================================
-- THE RESIZE GRIP'S COLUMN SPLIT GUIDE
-- DandersFrames_Options/GUI/Panel.lua
-- ------------------------------------------------------------
-- While the settings window's resize corner is held, a thin accent line is drawn
-- over the page where its two columns will split at the current width, hidden with
-- one column and on release.
--
-- ⚠ Panel.lua does not load headlessly (see test_page_parking.lua), so the REAL
-- code is lifted out of it by name: the column helpers as written, and the guide's
-- two local functions with the upvalues they close over handed in. Nothing here is
-- a copy of the arithmetic -- if the file changes, this runs the change.
-- ============================================================

local src = options_file_source("GUI/Panel.lua"):gsub("\r\n", "\n")

-- A function from its header to the first `end` at its own indent.
local function cut(header, indent)
    local s = src:find(header, 1, true)
    check(s ~= nil, "guide: found " .. header)
    if not s then return "" end
    local e = src:find("\n" .. (indent or "") .. "end\n", s, true)
    return src:sub(s, e + #(indent or "") + 4)
end

-- ---- the column helpers, as the layout pass uses them ----------------
local BOX = { colMargin = 5, colGutter = 20, minCol = 285, group = 280 }
local PAGEBOX = { inset = 8, gutter = 14 }
local GUIt = { SettingsBox = BOX }
local contentW = 700
GUIt.contentFrame = { GetWidth = function() return contentW end }

local helpers = table.concat({
    "local GUI, SettingsBox, PageBox = ...",
    cut("function GUI.PageChildWidth(contentWidth)"),
    cut("function GUI.UsesTwoColumns()"),
    cut("function GUI.ColumnWidth()"),
    cut("function GUI.PageUsableWidth(childWidth)"),
    cut("function GUI.Column2X(contentWidth)"),
    cut("function GUI.ColumnSplitX()"),
}, "\n")
assert(loadstring(helpers, "@Panel.lua:helpers"))(GUIt, BOX, PAGEBOX)
-- Missing helpers are a FAIL, not an error that stops every suite after this one.
if not (GUIt.ColumnSplitX and GUIt.Column2X) then
    check(false, "guide: the column split helpers exist")
    do return end
end

-- The layout pass places column 2 through the SAME helper the guide reads.
check(src:find("local col2X = usesTwoColumns and GUI.Column2X(contentWidth) or x1", 1, true) ~= nil,
      "guide: the layout pass starts column 2 at GUI.Column2X")

contentW = 500
check(not GUIt.UsesTwoColumns(), "guide: (500 wide is one column)")
eq(GUIt.ColumnSplitX(), nil, "guide: one column has no split")
contentW = 700
check(GUIt.UsesTwoColumns(), "guide: (700 wide is two columns)")
local split = GUIt.ColumnSplitX()
local col1Right = BOX.colMargin + GUIt.ColumnWidth()
local col2Left = math.floor(contentW / 2)
check(split and split > col1Right and split < col2Left,
      "guide: the split lies in the gap between column 1's right edge and column 2's left")
eq(split, (col1Right + col2Left) / 2, "guide: ...at its centre")

-- ---- the guide itself -------------------------------------------------
local body = src:match("\n(    local splitGuide, splitLine\n.-\n    local function HideSplitGuide%(%)\n.-\n    end\n)")
check(body ~= nil, "guide: the guide's two functions are found in the resize block")
if not body then do return end end
local created, textures, mouseOn = 0, 0, 0
local function fakeFrame()
    local f = { _shown = false, _level = 0 }
    function f:Show() self._shown = true end
    function f:Hide() self._shown = false end
    function f:IsShown() return self._shown end
    function f:EnableMouse(v) if v then mouseOn = mouseOn + 1 end self._mouse = v and true or false end
    function f:SetAllPoints(t) self._all = t end
    function f:SetFrameLevel(l) self._level = l end
    function f:GetFrameLevel() return self._level end
    function f:GetEffectiveScale() return 1 end
    function f:CreateTexture(_, layer)
        textures = textures + 1
        -- The recorders reuse their own tables, so the allocation check below
        -- measures the guide and not this stub.
        local t = { _layer = layer, _points = { {}, {} }, _n = 0, _c = {} }
        function t:SetColorTexture(r, g, b, a) local c = self._c; c[1], c[2], c[3], c[4] = r, g, b, a end
        function t:ClearAllPoints() self._n = 0 end
        function t:SetPoint(p, rel, rp, x, y)
            self._n = self._n + 1
            local pt = self._points[self._n]
            pt[1], pt[2], pt[3], pt[4], pt[5] = p, rel, rp, x, y
        end
        function t:SetWidth(w) self._w = w end
        return t
    end
    return f
end
local content = fakeFrame()
content._level = 5
content.GetWidth = function() return contentW end
GUIt.contentFrame = content
GUIt.SelectedMode = "party"
-- A card page: a box in each column, plus the right-aligned Copy button.
local function widget(col, extra)
    local w = { layoutCol = col, layoutHeight = 30, _shown = true }
    function w:IsShown() return self._shown end
    for k, v in pairs(extra or {}) do w[k] = v end
    return w
end
local col2Card = widget(2)
GUIt.Pages = {
    cards = { children = { widget(2, { rightAlign = true }), widget(1), col2Card } },
    -- The designers: everything full width, and the Copy button still added as column 2.
    designer = { children = { widget(2, { rightAlign = true }), widget("both"), widget(1) } },
    -- The Filter Designer has nothing to copy: an empty zero-height frame stands in.
    filterdesigner = { children = { widget(2, { layoutHeight = 0 }), widget("both") } },
    -- A group's own rows are added at the page's column but placed by the group.
    grouped = { children = { widget(1), widget(2, { settingsGroup = {} }) } },
    -- A settings group in column 2 is measured by its calculated height.
    group2 = { children = { widget(2, { isSettingsGroup = true, layoutHeight = 0, calculatedHeight = 120 }) } },
}
GUIt.CurrentPageName = "cards"
GUIt._priv = { PixelsPerUnit = function() return 2 end }   -- a 2x screen: one pixel is 0.5 units
local ACCENT = { r = 0.6, g = 0.3, b = 0.9 }
local function snap(_, v) return math.floor(v * 2 + 0.5) / 2 end
local prevCreateFrame = CreateFrame
-- Records what the guide builds: the frame it creates, and the texture made on it.
local guide, line
CreateFrame = function()
    created = created + 1
    guide = fakeFrame()
    local ct = guide.CreateTexture
    guide.CreateTexture = function(self, ...) line = ct(self, ...); return line end
    return guide
end
local Update, Hide = assert(loadstring(
    "local GUI, SnapLen, PageBox, GetThemeColor = ...\n" .. body ..
    "\nreturn UpdateSplitGuide, HideSplitGuide", "@Panel.lua:splitGuide"))(
    GUIt, snap, PAGEBOX, function() return ACCENT end)

contentW = 500
Update()
eq(created, 0, "guide: one column builds nothing")

contentW = 700
Update()
eq(created, 1, "guide: two columns build its one frame")
eq(textures, 1, "guide: ...and its one texture")
eq(mouseOn, 0, "guide: ...which never takes the mouse")
check(guide and guide:IsShown(), "guide: shown while the page has two columns")
check(guide._all == content and guide._mouse == false,
      "guide: laid over the page's content box, explicitly click-through")
eq(guide:GetFrameLevel(), content:GetFrameLevel() + 100, "guide: ...above the page's widgets")
eq(line._layer, "OVERLAY", "guide: drawn on the overlay layer")
eq(line._w, 0.5, "guide: one DEVICE pixel wide")
check(line._c[1] == ACCENT.r and line._c[2] == ACCENT.g and line._c[3] == ACCENT.b and line._c[4] < 0.5,
      "guide: in the accent, at low alpha")
local p1 = line._points[1]
local wantLeft = snap(nil, PAGEBOX.inset + GUIt.ColumnSplitX() - 0.25)
eq(p1[4], wantLeft, "guide: positioned by ColumnSplitX, past the page inset, on the pixel grid")
eq(p1[2], content, "guide: ...anchored to the content box")

-- Wider: the line follows, with nothing built.
local before = created
contentW = 900
Update()
eq(created, before, "guide: resizing builds nothing new")
eq(line._points[1][4], snap(nil, PAGEBOX.inset + GUIt.ColumnSplitX() - 0.25),
   "guide: ...and the line moves to the new split")

-- No allocation per update once built.
collectgarbage("collect")
collectgarbage("stop")
local k0 = collectgarbage("count")
for i = 1, 500 do contentW = 700 + (i % 50); Update() end
local used = collectgarbage("count") - k0
collectgarbage("restart")
check(used < 8, string.format("guide: 500 updates allocate nothing (%.1f KB)", used))

-- Narrow to one column mid-drag: gone.
contentW = 500
Update()
check(not guide:IsShown(), "guide: narrowing to one column takes it down")
contentW = 700
Update()
check(guide:IsShown(), "guide: ...and widening brings it back")
-- Click casting has no columns.
GUIt.SelectedMode = "clicks"
Update()
check(not guide:IsShown(), "guide: never over the click-casting panel")
GUIt.SelectedMode = "party"
Update()
check(guide:IsShown(), "guide: (back on the card page)")
-- A full-width page has no split to show, however wide the window.
GUIt.CurrentPageName = "designer"
Update()
check(not guide:IsShown(), "guide: never over a full-width page (the Copy button is not column 2)")
GUIt.CurrentPageName = "filterdesigner"
Update()
check(not guide:IsShown(), "guide: ...nor the empty Copy stand-in, which takes no height")
GUIt.CurrentPageName = "group2"
Update()
check(guide:IsShown(), "guide: a column-2 settings group counts by its calculated height")
GUIt.CurrentPageName = "grouped"
Update()
check(not guide:IsShown(), "guide: a group's own rows are not the page's column 2")
GUIt.CurrentPageName = "cards"
col2Card._shown = false
Update()
check(not guide:IsShown(), "guide: a hidden column-2 box leaves the page one column")
col2Card._shown = true
Update()
check(guide:IsShown(), "guide: ...and it returns with the box")
Hide()
check(not guide:IsShown(), "guide: HideSplitGuide takes it down")

-- ---- wired to the grip ------------------------------------------------
check(src:find("        lastW, lastH = w, h\n        -- Only when a number moved, like the readout: the split cannot move otherwise.\n        UpdateSplitGuide()", 1, true) ~= nil,
      "guide: the grip's readout updates it, and only when the size moved")
check(src:find("        self:SetScript(\"OnUpdate\", nil)\n        HideSplitGuide()", 1, true) ~= nil,
      "guide: release takes it down")
check(src:find('resizeHandle:HookScript("OnHide", HideSplitGuide)', 1, true) ~= nil,
      "guide: ...and so does the window closing under a held grip")

CreateFrame = prevCreateFrame
