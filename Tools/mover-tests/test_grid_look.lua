local NS = ...

-- ============================================================
-- THE GRID'S LOOK: LINE THICKNESS AND THE BACKGROUND DIM
-- ------------------------------------------------------------
-- Tester report (alpha.12): the grid was barely visible unless facing a wall.
--   * Grid line thickness, 1-5 DEVICE pixels, clamped, each line a whole
--     number of pixels wide and starting on a pixel boundary at any UI scale.
--   * An optional black wash behind the grid for the length of a session:
--     BACKGROUND strata at the bottom level (over the world, under the grid,
--     the slabs and the chrome) and never taking the mouse.
--
-- ☠ Every global and namespace field replaced here is restored at the end.
-- ============================================================
local prevUI, prevDB, prevSession, prevGrid, prevCreateFrame = NS.UI, NS.db, NS.Session, NS.Grid, CreateFrame
local prevPhys = GetPhysicalScreenSize

local frames = {}
CreateFrame = function(_, name)
    local f = FakeUIFrame()
    f._name = name
    frames[#frames + 1] = f
    return f
end
NS.UI = { Colors = { accent = { r = 0.5, g = 0.5, b = 1 } }, CreateLabel = function() return FakeUIFrame() end }
NS.db = { showGrid = true, gridSize = 20, gridThickness = 1, dimBackground = true, dimAlpha = 0.4 }
local active, suspended = true, false
NS.Session = { IsActive = function() return active end, IsSuspended = function() return suspended end }
-- 1080 device pixels tall at UIParent's 1080 units: 1.40625 px per unit at a
-- UI scale of 1 -- deliberately NOT 1:1, so an unsnapped line would be
-- visibly fractional.
GetPhysicalScreenSize = function() return 1920, 1080 end
load_addon_file("Grid.lua")
local G = NS.Grid

local PPU = 1080 / 768
local function isWholePx(v) local p = v * PPU return math.abs(p - math.floor(p + 0.5)) < 1e-6 end

-- ============================================================
-- THICKNESS
-- ============================================================
print("-- Grid look: line thickness")
do
    NS.db.gridThickness = 0;   eq(G:Thickness(), 1, "thickness: below 1 clamps to 1")
    NS.db.gridThickness = 9;   eq(G:Thickness(), 5, "thickness: above 5 clamps to 5 (max 5 px)")
    NS.db.gridThickness = 2.4; eq(G:Thickness(), 2, "thickness: whole pixels only")
    NS.db.gridThickness = nil; eq(G:Thickness(), 1, "thickness: missing setting reads as 1")

    for px = 1, 5 do
        NS.db.gridThickness = px
        G:Refresh()
        local grid = G.frame
        local minor = grid.lines[3]           -- 1 and 2 are the centre lines
        local w = minor and minor:GetWidth()
        eq(w and w * PPU, px, "thickness " .. px .. ": a minor line is exactly " .. px .. " device px wide")
        local cw = grid.centerV:GetWidth()
        eq(cw * PPU, px + 1, "thickness " .. px .. ": the centre line is one px heavier")
        local allSnapped = true
        for i = 1, #grid.lines do
            local l = grid.lines[i]
            if l:IsShown() then
                local p = l._points[1]
                local off = (p[1] == "LEFT") and p[4] or p[5]
                if not isWholePx(off) then allSnapped = false end
            end
        end
        check(allSnapped, "thickness " .. px .. ": every line starts on a pixel boundary")
    end
end

-- ============================================================
-- DIM
-- ============================================================
print("-- Grid look: the background dim")
do
    NS.db.gridThickness = 1
    NS.db.dimBackground, NS.db.dimAlpha = true, 0.4
    active, suspended = true, false
    G:Refresh()
    local d, grid = G.dim, G.frame
    check(d ~= nil and d:IsShown(), "dim: shown while a session is open")
    eq(d and d:GetFrameStrata(), "BACKGROUND", "dim: BACKGROUND strata -- over the world, under every mover strata")
    check(d and d:GetFrameLevel() < grid:GetFrameLevel(), "dim: under the grid")
    eq(grid:GetFrameStrata(), "BACKGROUND", "dim: ...which shares its strata")
    eq(d and d._flags.mouse, false, "dim: never takes the mouse")
    eq(d and d._flags.mouseClick, false, "dim: ...no clicks")
    eq(d and d.tex._color and d.tex._color.a, 0.4, "dim: its alpha is the setting")
    eq(d and d.tex._color and d.tex._color.r, 0, "dim: black")
    eq(grid._flags.mouse, false, "grid: never takes the mouse either")

    NS.db.dimAlpha = 0.7
    G:Refresh()
    eq(d.tex._color.a, 0.7, "dim: the amount applies live")

    NS.db.dimBackground = false
    G:Refresh()
    check(not d:IsShown(), "dim: turning it off hides it live")
    NS.db.dimBackground = true

    suspended = true
    G:Refresh()
    check(not d:IsShown(), "dim: down while the session is suspended for combat")
    suspended = false
    G:Refresh()
    check(d:IsShown(), "dim: back after combat")

    G:Hide()
    check(not d:IsShown() and not grid:IsShown(), "dim: the session ending takes it down with the grid")

    active = false
    G:Refresh()
    check(not d:IsShown(), "dim: never up outside a session")
    active = true

    -- Independent of the grid toggle: the dim is about the world, not the lines.
    NS.db.showGrid = false
    G:Refresh()
    check(d:IsShown() and not grid:IsShown(), "dim: stays with the grid itself turned off")
    NS.db.showGrid = true
    G:Hide()
end

NS.UI, NS.db, NS.Session, NS.Grid, CreateFrame = prevUI, prevDB, prevSession, prevGrid, prevCreateFrame
GetPhysicalScreenSize = prevPhys
