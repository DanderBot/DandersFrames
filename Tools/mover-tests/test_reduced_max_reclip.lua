-- ============================================================
-- REDUCED MAX HEALTH RE-CLIP (Frames/ReducedMaxHealth.lua + Update.lua)
-- A layout pass re-anchors the health bar to the full frame. The reduced-max clip
-- re-runs only when its geometry changes, so the re-anchor has to forget the clip
-- or the health fill runs under the reduced band. ReducedMaxHealth.lua is loaded
-- REAL; DF:AnchorHealthBarsToPadding is lifted from Update.lua by its source text.
-- ============================================================

local saved = {}
local function stub(name, value) saved[name] = _G[name]; _G[name] = value end
local function restore() for k, v in pairs(saved) do _G[k] = v end; saved = {} end

local function Region()
    local r = { points = {} }
    function r:ClearAllPoints() self.points = {} end
    function r:SetPoint(p, a, b) self.points[p] = (type(a) == "table") and a or "frame" end
    function r:SetBlendMode() end
    return r
end

local function Bar()
    local b = Region()
    b.fill = Region()
    function b:GetStatusBarTexture() return self.fill end
    function b:SetMinMaxValues() end
    function b:SetValue(v) self.value = v end
    function b:SetReverseFill() end
    function b:SetOrientation() end
    function b:SetStatusBarColor() end
    function b:SetFrameLevel() end
    function b:GetFrameLevel() return 3 end
    function b:Show() self.shown = true end
    function b:Hide() self.shown = false end
    return b
end

stub("CreateFrame", function()
    local f = Bar()
    function f:RegisterEvent() end
    function f:SetScript() end
    return f
end)
stub("issecretvalue", function() return false end)

local db = {
    reducedMaxHealthEnabled = true, reducedMaxHealthClipHealthBar = true,
    reducedMaxHealthColor = { r = 0.5, g = 0.5, b = 0.5, a = 0.8 },
    healthOrientation = "HORIZONTAL", framePadding = 1,
}
local DF = {
    GetFrameDB = function() return db end,
    SafeSetStatusBarTexture = function() return true end,
    ApplyBarFillOrientation = function() end,
    BarTextureLayersWanted = function() return false end,
    DebugWarn = function() end,
}
load_df_file_into("Frames/ReducedMaxHealth.lua", DF)

local src = df_file_source("Frames/Update.lua")
local a = src:find("function DF:AnchorHealthBarsToPadding(frame, db)", 1, true)
local e = a and src:find("\nend\r?\n", a)
check(a and e, "setup: lifted AnchorHealthBarsToPadding")
assert(loadstring("local DF = ...\n" .. src:sub(a, e + 4), "@anchor"))(DF)

local frame = { dfIsTestFrame = true, dfTestReducedMaxPct = 0.25, healthBar = Bar() }
DF:CreateReducedMaxHealthBar(frame, db)
local rmh = frame.dfReducedMaxHealthBar
check(rmh ~= nil, "setup: the reduced-max bar exists")

local function clippedToBand()
    return frame.healthBar.points.TOPRIGHT == rmh.fill and frame.healthBar.points.BOTTOMRIGHT == rmh.fill
end

DF:UpdateReducedMaxHealth(frame)
check(clippedToBand(), "first pass: the health bar's full-health edge sits on the reduced band")

-- a layout pass (live UpdateUnitFrame, the test-mode update, a resize drag)
DF:AnchorHealthBarsToPadding(frame, db)
check(not clippedToBand(), "layout pass: the health bar is back to the full rect")
eq(frame.dfReducedMaxHealthClipping, nil, "layout pass: ...and the clip is forgotten")

DF:UpdateReducedMaxHealth(frame)
check(clippedToBand(), "next reduced-max pass: clipped again, not left running under the band")

-- the per-health-tick path still skips the re-anchor when nothing moved
local calls = 0
local orig = frame.healthBar.ClearAllPoints
frame.healthBar.ClearAllPoints = function(self) calls = calls + 1; orig(self) end
DF:UpdateReducedMaxHealth(frame)
eq(calls, 0, "health tick: an already-clipped bar is not re-anchored")

restore()
