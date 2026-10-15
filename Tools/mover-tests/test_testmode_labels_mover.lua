local NS = ...

-- ============================================================
-- TEST MODE "INDICATOR INFO" vs A MOVER SESSION
-- DandersFrames_Options/TestMode/Labels.lua
-- ------------------------------------------------------------
-- Unlocking the movers forces test mode on, so with Indicator Info enabled the
-- hover marks run underneath the mover's slabs. Two questions, both pinned here
-- against the REAL file:
--   * can anything it draws take the mouse -- and so eat a grab meant for a slab?
--     (No: nothing it creates is mouse-enabled, and its own tooltip says so
--     explicitly rather than trusting the template.)
--   * does it keep marking elements while the user is aiming at slabs? (Not any
--     more: the hover stands down while the session is open and comes straight
--     back when it closes.)
--
-- ☠ ONE LUA RUNTIME IS SHARED BY EVERY SUITE. Every global replaced here is put
-- back at the end, and the mover lib's IsUnlocked is restored.
-- ============================================================

local saved = {
    CreateFrame = CreateFrame, C_Timer = C_Timer, GameTooltip = GameTooltip,
    GetCursorPosition = GetCursorPosition, DandersFrames = DandersFrames,
}

-- ---- frames -------------------------------------------------------
local created = {}
local mouseOn = {}          -- frames EnableMouse(true) was called on
local mouseOff = {}         -- ...and (false)

-- Unknown METHODS (capitalised, the WoW convention) answer a no-op; unknown DATA
-- fields (dfTestLabels, missingBuffStrip, ...) answer nil, as a real frame does.
local function methodsOnly(_, k)
    if type(k) == "string" and k:find("^%u") then return function() end end
    return nil
end

local function region()
    local r = { _shown = false }
    function r:Show() self._shown = true end
    function r:Hide() self._shown = false end
    function r:IsShown() return self._shown end
    function r:SetText(t) self._text = t end
    function r:GetText() return self._text end
    function r:GetStringWidth() return 40 end
    return setmetatable(r, { __index = function() return function() end end })
end

local function frame(kind, rect)
    local f = { _kind = kind, _shown = true, _alpha = 1, _scripts = {}, _strata = "MEDIUM", _level = 1 }
    if kind == "GameTooltip" then f._shown = false end
    function f:Show() self._shown = true end
    function f:Hide() self._shown = false end
    function f:SetShown(v) self._shown = v and true or false end
    function f:IsShown() return self._shown end
    function f:SetAlpha(a) self._alpha = a end
    function f:GetAlpha() return self._alpha end
    function f:SetScript(n, fn) self._scripts[n] = fn end
    function f:GetScript(n) return self._scripts[n] end
    function f:HookScript(n, fn) self._scripts[n] = fn end
    function f:EnableMouse(v)
        if v then mouseOn[#mouseOn + 1] = self else mouseOff[#mouseOff + 1] = self end
    end
    function f:SetFrameStrata(s) self._strata = s end
    function f:GetFrameStrata() return self._strata end
    function f:SetFrameLevel(l) self._level = l end
    function f:GetFrameLevel() return self._level end
    function f:GetEffectiveScale() return 1 end
    function f:CreateTexture() return region() end
    function f:CreateFontString() return region() end
    function f:SetOwner(o) self._owner = o end
    function f:GetOwner() return self._owner end
    function f:ClearLines() self._lines = {} end
    function f:AddLine(t) self._lines = self._lines or {}; self._lines[#self._lines + 1] = t end
    if rect then
        function f:GetLeft() return rect[1] end
        function f:GetRight() return rect[2] end
        function f:GetBottom() return rect[3] end
        function f:GetTop() return rect[4] end
    end
    created[#created + 1] = f
    return setmetatable(f, { __index = methodsOnly })
end

CreateFrame = function(kind) return frame(kind) end
C_Timer = { After = function() end }
GameTooltip = frame("GameTooltip")
local CX, CY = 120, 120
GetCursorPosition = function() return CX, CY end

-- ---- the DF it reads ------------------------------------------------
-- One party test frame with a missing-buff strip: the one element whose region is
-- a plain sized frame, so no aura-flow probe is needed to measure it.
local unit = frame("Button", { 100, 220, 100, 160 })
unit.missingBuffStrip = frame("Frame", { 110, 130, 110, 130 })
local db = { testShowLabels = true }
local DFt = {
    L = setmetatable({}, { __index = function(_, k) return k end }),
    testMode = true,
    testPartyFrames = { [0] = unit },
}
function DFt:GetDB() return db end
function DFt:GetRaidDB() return {} end
DandersFrames = DFt

local src = options_file_source("TestMode/Labels.lua")
assert(loadstring(src, "@Labels.lua"))()

-- ---- the mover lib's session flag -----------------------------------
local Mover = LibStub("DandersMover-1.0", true)
local fakeLib = false
if not Mover then
    -- A filtered run that never loaded the lib: register a stand-in so the file's
    -- lookup has something to find.
    Mover = LibStub:NewLibrary("DandersMover-1.0", 0)
    fakeLib = true
end
local prevIsUnlocked = rawget(Mover, "IsUnlocked")
local unlocked = false
Mover.IsUnlocked = function() return unlocked end

-- ============================================================
DFt:UpdateTestLabels()
local driver
for _, f in ipairs(created) do
    if f._scripts.OnUpdate then driver = f end
end
check(driver ~= nil, "labels: the hover driver is running with a region registered")
local function tick(n) for _ = 1, (n or 1) do driver._scripts.OnUpdate(driver, 0.06) end end
local function mark() return unit.dfTestLabels and unit.dfTestLabels.missing end
local function ownTip()
    for _, f in ipairs(created) do if f._kind == "GameTooltip" and f ~= GameTooltip then return f end end
end

-- Locked: hovering the strip marks it and names it.
tick(3)
check(mark() and mark().host:IsShown(), "labels: locked, hovering an element marks it")
check(ownTip() and ownTip():IsShown(), "labels: ...and our tooltip names it")

-- ---- (a) nothing it draws can take a slab's click ----------------
eq(#mouseOn, 0, "labels: nothing Indicator Info creates is mouse-enabled")
local tipOff = false
for _, f in ipairs(mouseOff) do if f == ownTip() then tipOff = true end end
check(tipOff, "labels: ...and its own tooltip is explicitly click-through")

-- ---- (b) a mover session stands the hover down -------------------
unlocked = true
tick()
check(not mark().host:IsShown(), "labels: unlocked, the mark comes down at once")
check(not ownTip():IsShown(), "labels: ...and so does our tooltip")
tick(5)
check(not mark().host:IsShown() and not ownTip():IsShown(),
      "labels: ...and stay down while the cursor sits over the element")
check(driver:IsShown(), "labels: ...with the driver still running, only standing down")

-- Locking again brings it straight back, with no settings pass in between.
unlocked = false
tick(3)
check(mark().host:IsShown(), "labels: locked again, the mark returns under the cursor")
check(ownTip():IsShown(), "labels: ...and the tooltip with it")

-- ============================================================
-- TEARDOWN
-- ============================================================
DFt:ClearTestLabels()
if fakeLib then Mover.IsUnlocked = nil else Mover.IsUnlocked = prevIsUnlocked end
CreateFrame, C_Timer, GameTooltip = saved.CreateFrame, saved.C_Timer, saved.GameTooltip
GetCursorPosition, DandersFrames = saved.GetCursorPosition, saved.DandersFrames
