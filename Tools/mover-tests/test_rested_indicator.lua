local NS = ...

-- ============================================================
-- RESTED INDICATOR BUILDER -- DandersFrames/Frames/Create.lua
-- ------------------------------------------------------------
-- DF:CreateRestedIndicator is lifted out of Create.lua by its section header
-- and run against tiny recording fakes (Create.lua itself builds tooltips at
-- file scope, so it is not loaded whole). Pins:
--   1. the build: 3 Zs at 8/11/14, offsets, 24x18, hidden, level parent+5,
--      glow only when a host is given;
--   2. animated (default): an OnUpdate is set and drives alpha/size + glow;
--   3. static: no OnUpdate, Zs at alpha 1 and base size, glow at 0.3;
--   4. SetZScale scales sizes, offsets and the container.
-- ============================================================

local src = df_file_source("Frames/Create.lua")
local a = src:find("-- RESTED INDICATOR BUILDER", 1, true)
local b = src:find("-- SAFE UNIT WATCH REGISTRATION", 1, true)
check(a and b and a < b, "rested: builder section found in Create.lua")
if not (a and b) then return end
local body = src:sub(a, b - 1):gsub("%-%- =+%s*$", "")

local function newRegion(kind)
    local r = { kind = kind, points = {}, scripts = {}, shown = true, alpha = 1, level = 0 }
    function r:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function r:ClearAllPoints() self.points = {} end
    function r:SetSize(w, h) self.w, self.h = w, h end
    function r:SetAlpha(v) self.alpha = v end
    function r:GetAlpha() return self.alpha end
    function r:Show() self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end
    function r:Hide() self.shown = false; if self.scripts.OnHide then self.scripts.OnHide(self) end end
    function r:IsShown() return self.shown end
    function r:SetScript(k, fn) self.scripts[k] = fn end
    function r:GetScript(k) return self.scripts[k] end
    function r:SetFrameLevel(l) self.level = l end
    function r:GetFrameLevel() return self.level end
    function r:SetText(t) self.text = t end
    function r:SetTextColor(...) self.color = { ... } end
    function r:SetTexture(t) self.texture = t end
    function r:SetVertexColor(...) self.vertex = { ... } end
    function r:SetBlendMode(m) self.blend = m end
    function r:CreateFontString(_, layer) local f = newRegion("FontString"); f.layer = layer; return f end
    function r:CreateTexture(_, layer, _, sub) local t = newRegion("Texture"); t.layer = layer; t.sub = sub; return t end
    return r
end

local fakeDF = {}
function fakeDF:SafeSetFont(fs, _, size, flags) fs.fontSize, fs.flags = size, flags end
local function fakeCreateFrame(_, _, parent)
    local f = newRegion("Frame"); f.parent = parent; return f
end

local chunk = assert(loadstring("local DF, CreateFrame, ipairs = ...\n" .. body, "@rested_builder"))
chunk(fakeDF, fakeCreateFrame, ipairs)
check(type(fakeDF.CreateRestedIndicator) == "function", "rested: DF:CreateRestedIndicator defined")
if type(fakeDF.CreateRestedIndicator) ~= "function" then return end

-- ---- 1. build ------------------------------------------------------
local parent = newRegion("Frame"); parent.level = 10
local host = newRegion("Frame")
local ind = fakeDF:CreateRestedIndicator(parent, host)
eq(ind.parent, parent, "rested: parented to the given parent")
eq(ind.level, 15, "rested: frame level parent + 5")
eq(ind.w, 24, "rested: width 24"); eq(ind.h, 18, "rested: height 18")
eq(ind:IsShown(), false, "rested: starts hidden")
eq(#ind.points, 0, "rested: caller anchors (no point set)")
eq(#ind.zTexts, 3, "rested: three Zs")
local SZ, OX, OY = { 8, 11, 14 }, { 0, 5, 12 }, { 0, 3, 7 }
for i = 1, 3 do
    local z = ind.zTexts[i]
    eq(z.text, "Z", "rested: Z" .. i .. " text")
    eq(z.fontSize, SZ[i], "rested: Z" .. i .. " size")
    eq(z.flags, "OUTLINE", "rested: Z" .. i .. " outline")
    eq(z.points[1][4], OX[i], "rested: Z" .. i .. " x offset")
    eq(z.points[1][5], OY[i], "rested: Z" .. i .. " y offset")
    eq(z.alpha, 0, "rested: Z" .. i .. " starts transparent (animated)")
end
check(ind.glow ~= nil, "rested: glow built when a host is given")
eq(ind.glow.blend, "ADD", "rested: glow is additive")
eq(ind.glow.layer, "BACKGROUND", "rested: glow on BACKGROUND")
eq(ind.glow.sub, -8, "rested: glow sublevel -8")
eq(ind.glow.vertex[4], 0.3, "rested: glow vertex alpha 0.3")
eq(ind.glow.points[1][4], -4, "rested: glow 4px outset left")
eq(ind.glow.points[2][4], 4, "rested: glow 4px outset right")
eq(ind.glow.shown, false, "rested: glow starts hidden")

local noGlow = fakeDF:CreateRestedIndicator(parent)
eq(noGlow.glow, nil, "rested: no glow without a host")

-- ---- 2. animated ---------------------------------------------------
local onUpdate = ind:GetScript("OnUpdate")
check(type(onUpdate) == "function", "rested: animated by default (OnUpdate set)")
ind:Show(); ind.glow:Show()
onUpdate(ind, 0.5)   -- progress 0.25: Z1 in its fade-in
check(ind.zTexts[1].alpha > 0 and ind.zTexts[1].alpha < 1, "rested: Z1 mid fade-in after 0.5s")
check(ind.zTexts[1].fontSize < 8, "rested: Z1 scaled down while fading in")
check(ind.glow.alpha >= 0.15 and ind.glow.alpha <= 0.45, "rested: glow pulses within 0.15-0.45")
onUpdate(noGlow, 0.5)  -- no glow: must not error
check(true, "rested: OnUpdate without glow is safe")

-- ---- 3. static -----------------------------------------------------
ind:SetAnimated(false)
eq(ind:GetScript("OnUpdate"), nil, "rested: static stops the OnUpdate")
for i = 1, 3 do
    eq(ind.zTexts[i].alpha, 1, "rested: static Z" .. i .. " full alpha")
    eq(ind.zTexts[i].fontSize, SZ[i], "rested: static Z" .. i .. " base size")
end
eq(ind.glow.alpha, 0.3, "rested: static glow fixed at 0.3")
ind:SetAnimated(true)
check(ind:GetScript("OnUpdate") ~= nil, "rested: animation switches back on")

-- ---- 4. scale ------------------------------------------------------
ind:SetAnimated(false)
ind:SetZScale(2)
eq(ind.w, 48, "rested: scale 2 doubles width"); eq(ind.h, 36, "rested: scale 2 doubles height")
for i = 1, 3 do
    eq(ind.zTexts[i].fontSize, SZ[i] * 2, "rested: scaled Z" .. i .. " size")
    eq(ind.zTexts[i].points[1][4], OX[i] * 2, "rested: scaled Z" .. i .. " x offset")
    eq(ind.zTexts[i].points[1][5], OY[i] * 2, "rested: scaled Z" .. i .. " y offset")
end

-- ---- party/raid call sites use the builder ---------------------------
local n = 0
for _ in src:gmatch("frame%.restedIndicator = DF:CreateRestedIndicator%(frame%.contentOverlay, frame%)") do n = n + 1 end
eq(n, 2, "rested: both party/raid build sites use the builder")
check(not src:find('frame.restedIndicator = CreateFrame(', 1, true), "rested: no hand-rolled copy left")
