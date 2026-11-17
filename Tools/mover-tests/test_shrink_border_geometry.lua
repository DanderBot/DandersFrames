-- ============================================================
-- SHRINK HEALTH BAR TO FIT -- GEOMETRY AGAINST THE FRAME BORDER
-- Field report (2026-11-17): with the shrink on, "the frame border no longer
-- covers the edges of the resource bar". The bar draws at +20, above the frame
-- border at +14, so wherever the bar overlaps the border band it hides the border.
-- With Adjust For Frame Border OFF a matched bar's ends run to the padding edge,
-- i.e. through the border's side columns. With the shrink, the bar is its own
-- strip under the health bar, so the border visibly stops at the bar.
--
-- The REAL DF:LayoutResourceBar (lifted from Bars.lua) and the REAL HealthRect.lua
-- run together; the bar's anchors and the health bar's insets are resolved into
-- rectangles (frame coords, origin bottom-left) and compared with the border band.
-- ============================================================

local saved = {}
local function stub(name, value) saved[name] = _G[name]; _G[name] = value end
local function restore() for k, v in pairs(saved) do _G[k] = v end; saved = {} end
stub("C_Timer", { After = function() end })

local function norm(s) return (s:gsub("\r\n", "\n")) end
local SRC = norm(df_file_source("Frames/Bars.lua"))
local a = SRC:find("\nDF.DETACHED_BAR_POINT = {", 1, true)
local s2 = a and SRC:find("\nfunction DF:LayoutResourceBar(", a, true)
local b = s2 and SRC:find("\nend\n", s2, true)
check(a ~= nil and s2 ~= nil and b ~= nil, "lift: DF:LayoutResourceBar from Bars.lua")
if not (a and s2 and b) then return end

local DF = {}
function DF:SafeSetStatusBarTexture() end
function DF:ApplyBarFillOrientation() end
function DF:BarTextureLayersWanted() return false end
function DF:GetFrameDB(frame) return frame.db end
load_df_file_into("Frames/HealthRect.lua", DF)

local f, err = loadstring(SRC:sub(a + 1, b + 4), "=LayoutResourceBar")
check(f ~= nil, "lift: parses (" .. tostring(err) .. ")")
if not f then return end
setfenv(f, setmetatable({ DF = DF }, { __index = _G }))
f()

local function Region()
    local t = { points = {} }
    function t:Show() self.shown = true end
    function t:Hide() self.shown = false end
    function t:IsShown() return self.shown end
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

local W, H = 120, 50
local function Frame(db, opts)
    local fr = { db = db, dfPowerBar = Region(), healthBar = Region(), missingHealthBar = Region() }
    for k, v in pairs(opts or {}) do fr[k] = v end
    function fr:GetFrameLevel() return 10 end
    return fr
end

local function baseDB(over)
    local db = {
        frameWidth = W, frameHeight = H, framePadding = 0, pixelPerfect = false,
        frameShowBorder = true, frameBorderSize = 1,
        resourceBarEnabled = true, resourceBarMatchWidth = true, resourceBarShrinkHealth = true,
        resourceBarMatchAdjustFrameBorder = false,
        resourceBarAnchor = "BOTTOM", resourceBarOrientation = "HORIZONTAL",
        resourceBarHeight = 4, resourceBarWidth = 50, resourceBarX = 0, resourceBarY = 1,
    }
    for k, v in pairs(over or {}) do db[k] = v end
    return db
end

-- A frame point name -> its coordinate on the frame (origin bottom-left).
local function pointXY(p)
    local x = p:find("LEFT") and 0 or (p:find("RIGHT") and W or W / 2)
    local y = p:find("BOTTOM") and 0 or (p:find("TOP") and H or H / 2)
    return x, y
end

-- Resolve the matched bar (two end points + a fixed cross size) into a rect.
local function barRect(bar, vertical)
    local p1, p2 = bar.points[1], bar.points[2]
    assert(p1 and p2, "matched bar has two points")
    local x1, y1 = pointXY(p1[3]); x1, y1 = x1 + p1[4], y1 + p1[5]
    local x2, y2 = pointXY(p2[3]); x2, y2 = x2 + p2[4], y2 + p2[5]
    if vertical then
        local l, r
        if p1[1]:find("LEFT") then l = x1; r = x1 + bar.w
        else r = x1; l = x1 - bar.w end
        return { l = l, r = r, b = math.min(y1, y2), t = math.max(y1, y2) }
    end
    local bot, top
    if p1[1]:find("BOTTOM") then bot = y1; top = y1 + bar.h
    else top = y1; bot = y1 - bar.h end
    return { l = math.min(x1, x2), r = math.max(x1, x2), b = bot, t = top }
end

local function healthRect(fr)
    local l, r, t, bb = DF:GetHealthBarInsets(fr, fr.db)
    return { l = l, r = W - r, b = bb, t = H - t }
end

local function near(x, y) return math.abs(x - y) < 1e-9 end

local function layout(db, opts)
    local fr = Frame(db, opts)
    DF:LayoutResourceBar(fr, db)
    return fr, barRect(fr.dfPowerBar, db.resourceBarOrientation == "VERTICAL")
end

-- ============================================================
print("-- Shrink OFF renders exactly as before (Adjust ON and OFF)")
-- ============================================================
for _, adjust in ipairs({ true, false }) do
    for _, pad in ipairs({ 0, 2 }) do
        for _, border in ipairs({ 1, 3 }) do
            local db = baseDB({ resourceBarShrinkHealth = false, resourceBarMatchAdjustFrameBorder = adjust,
                                framePadding = pad, frameBorderSize = border })
            local fr, bar = layout(db)
            local ends = adjust and math.max(pad, border) or pad
            local tag = ("adjust=%s pad=%d border=%d"):format(tostring(adjust), pad, border)
            check(near(bar.l, ends) and near(bar.r, W - ends), "shrink off, " .. tag .. ": ends inset as before")
            local h = healthRect(fr)
            check(near(h.b, pad) and near(h.l, pad) and near(h.t, H - pad),
                "shrink off, " .. tag .. ": full padding rect, health runs under the bar")
        end
    end
end

-- ============================================================
print("-- Shrink ON: the bar's ends stay inside the border band (the field bug)")
-- ============================================================
for _, adjust in ipairs({ true, false }) do
    for _, pad in ipairs({ 0, 2 }) do
        for _, border in ipairs({ 1, 3 }) do
            local db = baseDB({ resourceBarMatchAdjustFrameBorder = adjust, framePadding = pad, frameBorderSize = border })
            local _, bar = layout(db)
            local tag = ("adjust=%s pad=%d border=%d"):format(tostring(adjust), pad, border)
            check(bar.l >= border - 1e-9 and bar.r <= W - border + 1e-9,
                "shrink on, " .. tag .. ": bar ends clear the border's side columns")
            check(near(bar.l, math.max(pad, border)), "shrink on, " .. tag .. ": ...flush with the innermost boundary")
        end
    end
end
do
    local db = baseDB({ frameShowBorder = false, framePadding = 2, frameBorderSize = 3 })
    local _, bar = layout(db)
    check(near(bar.l, 2) and near(bar.r, W - 2), "shrink on, border hidden: ends at the padding (no band to clear)")
    db = baseDB({ resourceBarAnchor = "CENTER", resourceBarMatchAdjustFrameBorder = false, frameBorderSize = 3 })
    _, bar = layout(db)
    check(near(bar.l, 0), "shrink on but a centred bar (shrink not possible): Adjust OFF honoured as before")
end

-- ============================================================
print("-- Unit frames (standalone): same geometry; a detached bar is left alone")
-- ============================================================
do
    local db = baseDB({ frameBorderSize = 2 })
    local fr, bar = layout(db, { dfStandalone = true })
    check(near(bar.l, 2) and near(bar.r, W - 2), "standalone: ends clear the border band")
    local h = healthRect(fr)
    check(near(h.b, bar.t), "standalone: health bottom = bar top")
    db = baseDB({ frameBorderSize = 2, resourceBarDetached = true })
    fr = Frame(db, { dfStandalone = true })
    DF:LayoutResourceBar(fr, db)
    eq(#fr.dfPowerBar.points, 1, "standalone detached: the bar keeps its own one-point layout")
    h = healthRect(fr)
    check(near(h.b, 0) and near(h.t, H), "standalone detached: health keeps the full rect")
end

-- ============================================================
print("-- Shrink ON: the health bar meets the bar exactly (no gap, no overlap)")
-- ============================================================
for _, pad in ipairs({ 0, 2 }) do
    for _, offY in ipairs({ 0, 1, 3 }) do
        for _, border in ipairs({ 1, 3 }) do
            local db = baseDB({ framePadding = pad, resourceBarY = offY, frameBorderSize = border })
            local fr, bar = layout(db)
            local h = healthRect(fr)
            local tag = ("pad=%d offY=%d border=%d"):format(pad, offY, border)
            check(near(h.b, math.max(pad, bar.t)), "bottom, " .. tag .. ": health bottom = bar top (or padding)")
            check(near(h.l, pad) and near(h.r, W - pad), "bottom, " .. tag .. ": the other sides keep the padding")
        end
    end
end
do
    local db = baseDB({ resourceBarAnchor = "TOP", resourceBarY = -2, frameBorderSize = 2 })
    local fr, bar = layout(db)
    local h = healthRect(fr)
    check(near(h.t, bar.b), "top anchor: health top = bar bottom")
    check(bar.l >= 2 and bar.r <= W - 2, "top anchor: ends clear the border")
    for _, side in ipairs({ "LEFT", "RIGHT" }) do
        db = baseDB({ resourceBarOrientation = "VERTICAL", resourceBarAnchor = side,
                      resourceBarX = side == "LEFT" and 1 or -1, resourceBarY = 0, frameBorderSize = 2 })
        fr, bar = layout(db)
        h = healthRect(fr)
        if side == "LEFT" then check(near(h.l, bar.r), "vertical left: health left = bar right")
        else check(near(h.r, bar.l), "vertical right: health right = bar left") end
        check(bar.b >= 2 and bar.t <= H - 2, "vertical " .. side .. ": ends clear the border")
    end
end

-- ============================================================
print("-- Pixel perfect: the health edge and the bar edge are the same number")
-- ============================================================
do
    local scale = 0.64
    DF.PixelPerfect = function(_, v) return math.floor(v / scale + 0.5) * scale end
    for _, offY in ipairs({ 1, 0.3, 2.5 }) do
        local db = baseDB({ pixelPerfect = true, resourceBarY = offY, resourceBarHeight = 4 })
        local fr, bar = layout(db)
        local h = healthRect(fr)
        check(near(h.b, bar.t), ("pixel perfect offY=%s: health bottom == bar top"):format(offY))
    end
    DF.PixelPerfect = nil
end

restore()
