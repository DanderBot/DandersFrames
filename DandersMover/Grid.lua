local addonName, NS = ...

-- ============================================================
-- GRID OVERLAY
-- Full-screen grid on BACKGROUND strata plus the snap-preview crosshairs.
-- Line textures are pooled: textures cannot be freed, so a fresh set per
-- refresh would leak. (Pattern from DandersCDM UI/Position.lua.)
-- ============================================================
local G = {}
NS.Grid = G

local CreateFrame, UIParent = CreateFrame, UIParent

-- Lavender, not white. A white grid over a dark UI is the loudest thing on
-- screen while the one thing that should be loud is the frame being dragged, so
-- the grid takes the same accent as everything else in the session and sits
-- back: barely-there minor lines, the two centre lines a step up, and the snap
-- preview -- which IS a statement -- at full strength.
local C_GRID = NS.UI.Colors.accent
local A_LINE, A_CENTER, A_PREVIEW = 0.10, 0.30, 0.9
local W_LINE, W_CENTER, W_PREVIEW = 1, 2, 2
local A_LOCK = 0.8                       -- centre line while its axis is the locked one

local function buildLines(grid)
    local pool, used = grid.lines, 0
    local function acquire()
        used = used + 1
        local line = pool[used]
        if not line then line = grid:CreateTexture(nil, "BACKGROUND"); pool[used] = line end
        return line
    end
    local size = NS.db.gridSize or 20
    local w, h = UIParent:GetWidth(), UIParent:GetHeight()
    local function vline(x, alpha, thick)
        local l = acquire()
        l:SetColorTexture(C_GRID.r, C_GRID.g, C_GRID.b, alpha); l:SetSize(thick, h)
        l:ClearAllPoints(); l:SetPoint("CENTER", grid, "CENTER", x, 0); l:Show()
        return l
    end
    local function hline(y, alpha, thick)
        local l = acquire()
        l:SetColorTexture(C_GRID.r, C_GRID.g, C_GRID.b, alpha); l:SetSize(w, thick)
        l:ClearAllPoints(); l:SetPoint("CENTER", grid, "CENTER", 0, y); l:Show()
        return l
    end
    -- Kept by name for the axis-lock tint; every rebuild resets them to the
    -- resting alpha, which is exactly the wanted baseline.
    grid.centerV = vline(0, A_CENTER, W_CENTER)
    grid.centerH = hline(0, A_CENTER, W_CENTER)
    local x = size
    while x <= w / 2 do vline(x, A_LINE, W_LINE); vline(-x, A_LINE, W_LINE); x = x + size end
    local y = size
    while y <= h / 2 do hline(y, A_LINE, W_LINE); hline(-y, A_LINE, W_LINE); y = y + size end
    for i = used + 1, #pool do pool[i]:Hide() end
end

local function ensure()
    if G.frame then return G.frame end
    local grid = CreateFrame("Frame", "DandersMoverGrid", UIParent)
    grid:SetAllPoints(UIParent)
    grid:SetFrameStrata("BACKGROUND")
    grid:Hide()
    grid.lines = {}
    grid.previewV = grid:CreateTexture(nil, "OVERLAY")
    grid.previewV:SetColorTexture(C_GRID.r, C_GRID.g, C_GRID.b, A_PREVIEW)
    grid.previewV:SetSize(W_PREVIEW, UIParent:GetHeight()); grid.previewV:Hide()
    grid.previewH = grid:CreateTexture(nil, "OVERLAY")
    grid.previewH:SetColorTexture(C_GRID.r, C_GRID.g, C_GRID.b, A_PREVIEW)
    grid.previewH:SetSize(UIParent:GetWidth(), W_PREVIEW); grid.previewH:Hide()
    grid:SetScript("OnShow", function(self) buildLines(self) end)
    G.frame = grid
    return grid
end

function G:Show() if NS.db.showGrid then ensure():Show() end end
function G:Hide() if self.frame then self.frame:Hide() end end
function G:Refresh()
    local f = ensure()
    if NS.db.showGrid and NS.Session and NS.Session:IsActive() and not NS.Session:IsSuspended() then
        f:Show(); buildLines(f)
    else
        f:Hide()
    end
end

-- Preview lines live on the grid frame but are shown even when the grid is off.
-- lineX / lineY are the grid or screen lines the drag snapped to; nil on an
-- axis that did not snap hides that line.
--
-- Off by default (NS.db.showSnapPreview): a full-height crosshair on every
-- snapped drag frame is louder than the frame being dragged. Gated here rather
-- than at the call site so every caller gets the setting for free; HidePreview
-- stays ungated so turning it off mid-session clears whatever is up.
function G:ShowPreview(lineX, lineY)
    if not NS.db.showSnapPreview then return end
    local f = ensure()
    if not f:IsShown() then f:Show(); if not NS.db.showGrid then for _, l in ipairs(f.lines) do l:Hide() end end end
    if lineX then
        f.previewV:ClearAllPoints(); f.previewV:SetPoint("CENTER", f, "CENTER", lineX, 0); f.previewV:Show()
    else
        f.previewV:Hide()
    end
    if lineY then
        f.previewH:ClearAllPoints(); f.previewH:SetPoint("CENTER", f, "CENTER", 0, lineY); f.previewH:Show()
    else
        f.previewH:Hide()
    end
end

function G:HidePreview()
    if not self.frame then return end
    self.frame.previewV:Hide(); self.frame.previewH:Hide()
    if not NS.db.showGrid then self.frame:Hide() end
end

-- ============================================================
-- AXIS LOCK TINT
-- While Shift (horizontal-only drag) or Ctrl (vertical-only) is held
-- mid-drag, the centre line of the axis the drag still moves along brightens:
-- Shift lights the horizontal line, Ctrl the vertical. Only visible while the
-- grid is up; (false, false) restores the resting alpha.
-- ============================================================
function G:SetAxisLock(lockH, lockV)
    local f = self.frame
    if not f or not f.centerH then return end
    f.centerH:SetColorTexture(C_GRID.r, C_GRID.g, C_GRID.b, lockH and A_LOCK or A_CENTER)
    f.centerV:SetColorTexture(C_GRID.r, C_GRID.g, C_GRID.b, lockV and A_LOCK or A_CENTER)
end

-- ============================================================
-- MEASURE LINES (drag only)
-- Thin lines from the dragged slab to the nearest screen edge on each axis,
-- with a px readout at the midpoint (idea from EllesmereUI's unlock mode).
-- Same lavender as the rest of the session, on the grid frame's OVERLAY layer
-- like the snap preview, and shown even while the grid itself is off.
-- ============================================================
local A_MEASURE = 0.8

local function ensureMeasure(f)
    if f.measureH then return end
    f.measureH = f:CreateTexture(nil, "OVERLAY")
    f.measureH:SetColorTexture(C_GRID.r, C_GRID.g, C_GRID.b, A_MEASURE)
    f.measureH:SetHeight(1)
    f.measureV = f:CreateTexture(nil, "OVERLAY")
    f.measureV:SetColorTexture(C_GRID.r, C_GRID.g, C_GRID.b, A_MEASURE)
    f.measureV:SetWidth(1)
    f.measureHText = NS.UI:CreateLabel(f, { size = 10, color = C_GRID })
    f.measureVText = NS.UI:CreateLabel(f, { size = 10, color = C_GRID })
end

-- One axis: place the line between fromCoord and toCoord (screen units along
-- the axis) at cross on the other axis, with the readout at the midpoint.
local function measureAxis(line, label, horizontal, a, b, cross)
    local len = b - a
    if len <= 1 then line:Hide(); label:Hide(); return end
    line:ClearAllPoints()
    label:ClearAllPoints()
    if horizontal then
        line:SetPoint("LEFT", line:GetParent(), "CENTER", a, cross)
        line:SetWidth(len)
        label:SetPoint("BOTTOM", line:GetParent(), "CENTER", (a + b) / 2, cross + 3)
    else
        line:SetPoint("BOTTOM", line:GetParent(), "CENTER", cross, a)
        line:SetHeight(len)
        label:SetPoint("LEFT", line:GetParent(), "CENTER", cross + 4, (a + b) / 2)
    end
    label:SetText(string.format("%d px", len + 0.5))
    line:Show(); label:Show()
end

-- Off by default (NS.db.showMeasures); same gating rule as ShowPreview.
function G:ShowMeasure(cx, cy, w, h)
    if not NS.db.showMeasures then return end
    local f = ensure()
    ensureMeasure(f)
    if not f:IsShown() then f:Show(); if not NS.db.showGrid then for _, l in ipairs(f.lines) do l:Hide() end end end
    local halfW, halfH = UIParent:GetWidth() / 2, UIParent:GetHeight() / 2
    -- Slab edge to the NEARER screen edge on each axis, judged by the centre.
    if cx < 0 then measureAxis(f.measureH, f.measureHText, true, -halfW, cx - w / 2, cy)
    else           measureAxis(f.measureH, f.measureHText, true, cx + w / 2, halfW, cy) end
    if cy < 0 then measureAxis(f.measureV, f.measureVText, false, -halfH, cy - h / 2, cx)
    else           measureAxis(f.measureV, f.measureVText, false, cy + h / 2, halfH, cx) end
end

function G:HideMeasure()
    local f = self.frame
    if not f or not f.measureH then return end
    f.measureH:Hide(); f.measureV:Hide()
    f.measureHText:Hide(); f.measureVText:Hide()
    -- Mirror HidePreview's rule: the frame only stays up for the grid.
    if not NS.db.showGrid and not f.previewV:IsShown() and not f.previewH:IsShown() then f:Hide() end
end
