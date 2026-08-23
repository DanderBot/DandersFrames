local addonName, NS = ...

-- ============================================================
-- GRID OVERLAY
-- Full-screen grid on BACKGROUND strata plus red snap-preview crosshairs.
-- Line textures are pooled: textures cannot be freed, so a fresh set per
-- refresh would leak. (Pattern from DandersCDM UI/Position.lua.)
-- ============================================================
local G = {}
NS.Grid = G

local CreateFrame, UIParent = CreateFrame, UIParent

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
        l:SetColorTexture(1, 1, 1, alpha); l:SetSize(thick, h)
        l:ClearAllPoints(); l:SetPoint("CENTER", grid, "CENTER", x, 0); l:Show()
    end
    local function hline(y, alpha, thick)
        local l = acquire()
        l:SetColorTexture(1, 1, 1, alpha); l:SetSize(w, thick)
        l:ClearAllPoints(); l:SetPoint("CENTER", grid, "CENTER", 0, y); l:Show()
    end
    vline(0, 0.5, 2); hline(0, 0.5, 2)
    local x = size
    while x <= w / 2 do vline(x, 0.15, 1); vline(-x, 0.15, 1); x = x + size end
    local y = size
    while y <= h / 2 do hline(y, 0.15, 1); hline(-y, 0.15, 1); y = y + size end
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
    grid.previewV:SetColorTexture(1, 0.2, 0.2, 0.8); grid.previewV:SetSize(2, UIParent:GetHeight()); grid.previewV:Hide()
    grid.previewH = grid:CreateTexture(nil, "OVERLAY")
    grid.previewH:SetColorTexture(1, 0.2, 0.2, 0.8); grid.previewH:SetSize(UIParent:GetWidth(), 2); grid.previewH:Hide()
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
function G:ShowPreview(lineX, lineY)
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
