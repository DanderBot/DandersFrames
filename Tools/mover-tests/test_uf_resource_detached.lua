local NS = ...

-- ============================================================
-- UNIT FRAMES COMPANION -- DETACHED RESOURCE BAR
-- DandersFrames/Frames/Bars.lua, DETACHED RESOURCE BAR (DF:LayoutResourceBar)
-- ------------------------------------------------------------
-- A standalone frame with resourceBarDetached lays its bar out at its own size,
-- OUTSIDE the frame at a point of its edge; every other frame (and a standalone
-- one left attached) keeps the anchor / match-width layout it always had. The
-- same function draws the test preview, so the preview follows. Lifted from the
-- source and run against stubs.
-- ============================================================

local function norm(s) return (s:gsub("\r\n", "\n")) end
local SRC = norm(df_file_source("Frames/Bars.lua"))
local a = SRC:find("\nDF.DETACHED_BAR_POINT = {", 1, true)
local s2 = a and SRC:find("\nfunction DF:LayoutResourceBar(", a, true)
local b = s2 and SRC:find("\nend\n", s2, true)
check(a ~= nil and s2 ~= nil and b ~= nil, "lift: the detached bar table, its predicate and DF:LayoutResourceBar")
if not (a and s2 and b) then return end

local DFs = {}
function DFs:SafeSetStatusBarTexture() end
function DFs:ApplyBarFillOrientation() end
function DFs:BarTextureLayersWanted() return false end
function DFs:PixelPerfect(v) return math.floor(v + 0.5) end

local f, err = loadstring(SRC:sub(a + 1, b + 4), "=LayoutResourceBar")
check(f ~= nil, "lift: parses (" .. tostring(err) .. ")")
if not f then return end
setfenv(f, setmetatable({ DF = DFs }, { __index = _G }))
f()

local function Bar()
    local t = { points = {} }
    function t:Show() self.shown = true end
    function t:ClearAllPoints() self.points = {} end
    function t:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function t:SetSize(w, h) self.w, self.h = w, h end
    function t:SetWidth(w) self.w = w end
    function t:SetHeight(h) self.h = h end
    function t:SetOrientation() end
    function t:SetReverseFill() end
    function t:SetFrameLevel(l) self.level = l end
    function t:GetFrameLevel() return self.level or 0 end
    return t
end
local function Frame(db, standalone)
    local fr = { dfPowerBar = Bar(), dfStandalone = standalone or nil }
    function fr:GetFrameLevel() return 10 end
    return fr, db
end

local function base()
    return { frameWidth = 220, frameHeight = 46, frameShowBorder = false, resourceBarMatchWidth = true,
             resourceBarAnchor = "BOTTOM", resourceBarHeight = 6, resourceBarX = 0, resourceBarY = 1 }
end

print("-- Attached (and every group frame): the layout it always had")
do
    local db = base()
    local fr = Frame(db, true)
    DFs:LayoutResourceBar(fr, db)
    local bar = fr.dfPowerBar
    eq(#bar.points, 2, "match width: pinned by its two ends")
    eq(bar.points[1][1] .. ">" .. bar.points[1][3], "BOTTOMLEFT>BOTTOMLEFT", "...inside the frame's bottom")
    eq(bar.h, 6, "...its thickness")
    db.resourceBarDetached = true
    local party = Frame(db, false)
    DFs:LayoutResourceBar(party, db)
    eq(#party.dfPowerBar.points, 2, "a party frame with the key set: never detached (not standalone)")
    eq(DFs:IsResourceBarDetached(party, db), false, "...the predicate says so")
end

print("-- Detached: its own size, outside the frame")
do
    local db = base()
    db.resourceBarDetached = true
    local fr = Frame(db, true)
    eq(DFs:IsResourceBarDetached(fr, db), true, "a standalone frame with Detach on")
    DFs:LayoutResourceBar(fr, db)
    local bar = fr.dfPowerBar
    eq(#bar.points, 1, "one point")
    local p = bar.points[1]
    eq(p[1] .. ">" .. p[3], "TOP>BOTTOM", "the default (no anchor stored): hangs under the frame")
    eq(p[2], fr, "...relative to the frame")
    eq(bar.w .. "x" .. bar.h, "220x8", "Match Frame Width (default on) and the default 8 high")
    db.resourceBarDetachedMatchWidth = false
    db.resourceBarDetachedWidth = 150
    db.resourceBarDetachedHeight = 12
    db.resourceBarDetachedX, db.resourceBarDetachedY = 5, -4
    DFs:LayoutResourceBar(fr, db)
    p = bar.points[1]
    eq(bar.w .. "x" .. bar.h, "150x12", "its own width and height")
    eq(p[4] .. "," .. p[5], "5,-4", "its own offsets")
    local want = { TOP = "BOTTOM>TOP", LEFT = "RIGHT>LEFT", RIGHT = "LEFT>RIGHT", CENTER = "CENTER>CENTER",
                   TOPLEFT = "BOTTOMLEFT>TOPLEFT", TOPRIGHT = "BOTTOMRIGHT>TOPRIGHT",
                   BOTTOMLEFT = "TOPLEFT>BOTTOMLEFT", BOTTOMRIGHT = "TOPRIGHT>BOTTOMRIGHT", BOTTOM = "TOP>BOTTOM" }
    for anchor, w in pairs(want) do
        db.resourceBarDetachedAnchor = anchor
        DFs:LayoutResourceBar(fr, db)
        p = bar.points[1]
        eq(p[1] .. ">" .. p[3], w, anchor .. ": the bar's opposite point on the frame's")
    end
    db.resourceBarDetachedAnchor = "NOWHERE"
    DFs:LayoutResourceBar(fr, db)
    eq(bar.points[1][1] .. ">" .. bar.points[1][3], "TOP>BOTTOM", "an unknown stored anchor: under the frame")
    db.resourceBarDetachedAnchor = nil
    eq(bar.level, 30, "the frame level setting still applies (10 + 20)")
    db.resourceBarDetached = false
    DFs:LayoutResourceBar(fr, db)
    eq(#bar.points, 2, "re-attached: back to the anchor layout, its own settings untouched")
end
