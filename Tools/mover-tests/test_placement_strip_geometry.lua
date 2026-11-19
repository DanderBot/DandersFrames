-- ============================================================
-- PLACEMENT STRIP GEOMETRY: THE STRIP AND THE HEALTH BAR MEET EXACTLY
-- The REAL DF:LayoutResourceBar (lifted from Bars.lua) and the REAL HealthRect.lua run
-- together; the strip's anchors and the health bar's insets are resolved into rectangles
-- (frame coords, origin bottom-left) and compared. For every side, Match on and off,
-- Adjust on and off, Keep Inside Border, offsets and pixel perfect: the health bar ends
-- exactly at the strip's inner edge (no gap, no overlap), the other three sides keep the
-- base inset, and On Top of Health Bar is untouched (full health, bar on top).
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
    local fr = { db = db, dfPowerBar = Region(), healthBar = Region(), missingHealthBar = Region(),
                 dfResourceBarWanted = true }
    for k, v in pairs(opts or {}) do fr[k] = v end
    function fr:GetFrameLevel() return 10 end
    return fr
end

local function baseDB(over)
    local db = {
        frameWidth = W, frameHeight = H, framePadding = 0, pixelPerfect = false,
        frameShowBorder = true, frameBorderSize = 1,
        resourceBarEnabled = true, resourceBarMatchWidth = true, resourceBarPlacement = "BOTTOM",
        resourceBarMatchAdjustFrameBorder = false,
        resourceBarAnchor = "CENTER", resourceBarOrientation = "HORIZONTAL",
        resourceBarHeight = 4, resourceBarWidth = 50, resourceBarX = 0, resourceBarY = 1,
        resourceBarStripX = 0, resourceBarStripY = 0,
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

-- Resolve the bar's points (each pinned to the same-named frame point) plus whatever
-- size was set into a rect: each point fixes the edge it names, a size fills the rest.
local function barRect(bar)
    local L, R, B, T, CX, CY
    for _, p in ipairs(bar.points) do
        local x, y = pointXY(p[3]); x, y = x + (p[4] or 0), y + (p[5] or 0)
        local name = p[1]
        if name:find("LEFT") then L = x elseif name:find("RIGHT") then R = x else CX = x end
        if name:find("BOTTOM") then B = y elseif name:find("TOP") then T = y else CY = y end
    end
    local w, h = bar.w, bar.h
    if not L then L = R and (R - w) or (CX - w / 2) end
    if not R then R = L + w end
    if not B then B = T and (T - h) or (CY - h / 2) end
    if not T then T = B + h end
    return { l = L, r = R, b = B, t = T }
end

local function healthRect(fr)
    local l, r, t, bb = DF:GetHealthBarInsets(fr, fr.db)
    return { l = l, r = W - r, b = bb, t = H - t }
end

local function near(x, y) return math.abs(x - y) < 1e-9 end

local function layout(db, opts)
    local fr = Frame(db, opts)
    DF:LayoutResourceBar(fr, db)
    return fr, barRect(fr.dfPowerBar)
end

-- The health edge that faces the strip, and the strip's edge that faces the health bar.
local FACE = {
    BOTTOM = function(h, s) return h.b, s.t end,
    TOP    = function(h, s) return h.t, s.b end,
    LEFT   = function(h, s) return h.l, s.r end,
    RIGHT  = function(h, s) return h.r, s.l end,
}
-- The three other sides of the health rect, at the base inset.
local function othersAtBase(h, side, base)
    local ok = true
    if side ~= "LEFT" then ok = ok and near(h.l, base) end
    if side ~= "RIGHT" then ok = ok and near(h.r, W - base) end
    if side ~= "BOTTOM" then ok = ok and near(h.b, base) end
    if side ~= "TOP" then ok = ok and near(h.t, H - base) end
    return ok
end

-- ============================================================
print("-- On Top of Health Bar renders exactly as before")
-- ============================================================
for _, adjust in ipairs({ true, false }) do
    for _, pad in ipairs({ 0, 2 }) do
        for _, border in ipairs({ 1, 3 }) do
            local db = baseDB({ resourceBarPlacement = "OVER", resourceBarAnchor = "BOTTOM",
                                resourceBarMatchAdjustFrameBorder = adjust, framePadding = pad, frameBorderSize = border })
            local fr, bar = layout(db)
            local ends = adjust and math.max(pad, border) or pad
            local tag = ("adjust=%s pad=%d border=%d"):format(tostring(adjust), pad, border)
            check(near(bar.l, ends) and near(bar.r, W - ends), "on top, " .. tag .. ": ends inset as before")
            check(othersAtBase(healthRect(fr), "NONE", pad), "on top, " .. tag .. ": full padding rect under the bar")
            eq(fr.dfPowerBar.level, 10 + 20, "on top, " .. tag .. ": Frame Level +20, above the border")
        end
    end
end

-- ============================================================
print("-- Every side: the health bar meets the strip exactly")
-- ============================================================
for _, side in ipairs({ "BOTTOM", "TOP", "LEFT", "RIGHT" }) do
    for _, match in ipairs({ true, false }) do
        for _, adjust in ipairs({ true, false }) do
            for _, pad in ipairs({ 0, 2 }) do
                for _, off in ipairs({ 0, 1, 3 }) do
                    local inward = (side == "BOTTOM" or side == "LEFT") and off or -off
                    local over = { resourceBarPlacement = side, resourceBarMatchWidth = match,
                                   resourceBarMatchAdjustFrameBorder = adjust, framePadding = pad, frameBorderSize = 3 }
                    if side == "BOTTOM" or side == "TOP" then over.resourceBarStripY = inward
                    else over.resourceBarStripX = inward end
                    local db = baseDB(over)
                    local fr, strip = layout(db)
                    local h = healthRect(fr)
                    local hEdge, sEdge = FACE[side](h, strip)
                    local tag = ("%s match=%s adjust=%s pad=%d off=%d"):format(side, tostring(match), tostring(adjust), pad, off)
                    check(near(hEdge, sEdge), tag .. ": health edge == strip inner edge (no gap, no overlap)")
                    check(othersAtBase(h, side, pad), tag .. ": the other three sides keep the padding")
                    eq(fr.dfPowerBar.level, 10 + 12, tag .. ": the strip's own level, under the border")
                    if adjust and match then
                        local across = side == "BOTTOM" or side == "TOP"
                        local lo, hi = across and strip.l or strip.b, across and strip.r or strip.t
                        local span = across and W or H
                        check(lo >= 3 - 1e-9 and hi <= span - 3 + 1e-9, tag .. ": Adjust keeps the strip inside the border")
                    end
                end
            end
        end
    end
end

-- ============================================================
print("-- Match off: a short strip, the whole side still given up")
-- ============================================================
do
    local db = baseDB({ resourceBarMatchWidth = false, resourceBarWidth = 30, resourceBarAnchor = "BOTTOMLEFT",
                        resourceBarStripX = 5 })
    local fr, strip = layout(db)
    check(near(strip.r - strip.l, 30), "Match off: the strip has its own length")
    check(near(strip.l, 5), "...seated at the left, slid along by Offset X")
    local h = healthRect(fr)
    check(near(h.b, strip.t), "...and the health bar stops at it along the WHOLE side")
    check(near(h.l, 0) and near(h.r, W), "...full width (the gap beside the strip shows the background)")
end

-- ============================================================
print("-- Keep Health Bar Inside Border")
-- ============================================================
for _, side in ipairs({ "BOTTOM", "TOP", "LEFT", "RIGHT" }) do
    local db = baseDB({ resourceBarPlacement = side, healthInsideFrameBorder = true, frameBorderSize = 3, framePadding = 1 })
    local fr, strip = layout(db)
    local h = healthRect(fr)
    local hEdge, sEdge = FACE[side](h, strip)
    check(near(hEdge, sEdge), side .. " inside border: health edge == strip inner edge")
    check(othersAtBase(h, side, 3), side .. " inside border: the other sides at the border band")
    local across = side == "BOTTOM" or side == "TOP"
    check(near(across and strip.l or strip.b, 3), side .. " inside border: the strip seats inside the band too")
end

-- ============================================================
print("-- A strip pushed out of the frame: the base wins")
-- ============================================================
do
    local db = baseDB({ resourceBarStripY = -10, framePadding = 2 })
    local fr, strip = layout(db)
    local h = healthRect(fr)
    check(strip.t < 2, "the strip sits below the padding line")
    check(near(h.b, 2), "...and the health bar keeps its padding, never less")
end

-- ============================================================
print("-- Unit frames (standalone): same geometry; a detached bar is left alone")
-- ============================================================
do
    local db = baseDB({ frameBorderSize = 2, resourceBarMatchAdjustFrameBorder = true })
    local fr, strip = layout(db, { dfStandalone = true })
    check(near(strip.l, 2) and near(strip.r, W - 2), "standalone: ends clear the border band")
    check(near(healthRect(fr).b, strip.t), "standalone: health bottom = strip top")
    db = baseDB({ frameBorderSize = 2, resourceBarDetached = true })
    fr = Frame(db, { dfStandalone = true })
    DF:LayoutResourceBar(fr, db)
    eq(#fr.dfPowerBar.points, 1, "standalone detached: the bar keeps its own one-point layout")
    local h = healthRect(fr)
    check(near(h.b, 0) and near(h.t, H), "standalone detached: health keeps the full rect")
    eq(fr.dfPowerBar.level, 10 + 20, "standalone detached: On Top's level, not the strip's")
end

-- ============================================================
print("-- Not wanted: the strip is laid out if shown, but the health bar is full")
-- ============================================================
do
    local fr = Frame(baseDB(), { dfResourceBarWanted = false })
    DF:LayoutResourceBar(fr, fr.db)
    local h = healthRect(fr)
    check(near(h.b, 0), "a frame not meant to carry a bar keeps its whole health bar")
end

-- ============================================================
print("-- Pixel perfect: the health edge and the strip edge are the same number")
-- ============================================================
do
    local scale = 0.64
    DF.PixelPerfect = function(_, v) return math.floor(v / scale + 0.5) * scale end
    for _, side in ipairs({ "BOTTOM", "TOP", "LEFT", "RIGHT" }) do
        for _, off in ipairs({ 1, 0.3, 2.5 }) do
            for _, adjust in ipairs({ true, false }) do
                local inward = (side == "BOTTOM" or side == "LEFT") and off or -off
                local over = { pixelPerfect = true, resourceBarPlacement = side, resourceBarHeight = 4,
                               framePadding = 1.3, frameBorderSize = 2, resourceBarMatchAdjustFrameBorder = adjust }
                if side == "BOTTOM" or side == "TOP" then over.resourceBarStripY = inward
                else over.resourceBarStripX = inward end
                local fr, strip = layout(baseDB(over))
                local hEdge, sEdge = FACE[side](healthRect(fr), strip)
                check(math.abs(hEdge - sEdge) < 1e-9,
                    ("pixel perfect %s off=%s adjust=%s: health edge == strip edge"):format(side, off, tostring(adjust)))
            end
        end
    end
    DF.PixelPerfect = nil
end

restore()
