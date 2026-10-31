local addonName, UF = ...

-- ============================================================
-- PREVIEW (spec §1.8)
-- Sample frames for every unit this build draws, so an absent unit (no target,
-- no focus, no pet) can be seen, styled and dragged.
--
-- ★ SEPARATE NON-SECURE FRAMES. A secure unit button cannot be forced to show
-- in combat, so the preview never touches the live buttons' shown state. It
-- builds its own plain Buttons the way DandersFrames' test pool does
-- (DandersFrames_Options/TestMode/TestFramePool.lua: CreateFrameElements +
-- ApplyFrameStyle, dfIsTestFrame), makes them standalone frames on the unit's
-- own settings table, and paints them with DandersFrames' test painter
-- (DF:UpdateTestFrame), which takes each frame's own fake unit from
-- frame.dfTestData (DF:GetTestDataForFrame). frame.dfPreview puts them in test
-- scope (DF:FrameInTestScope).
-- While the preview is up the live frames' holders are faded to alpha 0 (alpha
-- is legal in combat; Show/Hide is not) so the two never draw on top of each
-- other.
--
-- Owners -- the preview is up while ANY of them wants it (DandersFrames' test
-- mode ownership model, TestMode/Shim.lua):
--   "unlock"    a DandersMover session (Mover.lua's Unlocked / Locked)
--   "test"      DandersFrames' test mode is on screen and the module-wide
--               "Include Unit Frames in Test Mode" is ticked (OnTestModeChanged)
--   "settings"  the Preview switch on the module's Settings page (this session)
-- ============================================================

local DF = DandersFrames
if not DF then return end

local pairs, ipairs, type = pairs, ipairs, type

local P = { owners = {}, frames = {}, shown = false, LEVEL_ABOVE_LIVE = 100 }
UF.Preview = P

-- ============================================================
-- FAKE UNITS
-- Shaped like DF:GetTestUnitData's answer (the fields its painter reads), plus
-- the unit-frame ones: reaction / isTapped (health colour), level and
-- classification (Text Designer).
-- ============================================================
local function Base()
    return {
        index = 1, name = "?", class = nil, role = nil, specID = 0,
        healthPercent = 1, maxHealth = 100000, currentHealth = 100000,
        powerPercent = 0.8, absorbPercent = 0, reducedMaxPct = 0,
        healAbsorbPercent = 0, healPredictionPercent = 0,
        status = nil, outOfRange = false, isLeader = false, isAssist = false,
        raidTarget = nil, dispelType = nil, centerStatus = nil,
        isMainTank = false, isMainAssist = false, isAFK = false, isPhased = false,
        inVehicle = false, isBGCarrier = false, isInCombat = false,
        targetName = nil, reaction = 5, isTapped = nil, level = nil, classification = nil,
        showDefensive = false, showMissingBuff = false, showReadyCheck = false, showPing = false,
    }
end

local function SetHealth(t, pct)
    t.healthPercent = pct
    t.currentHealth = math.floor(pct * t.maxHealth)
end

function P:PlayerName()
    local name = UnitName and UnitName("player")
    if type(name) ~= "string" or (issecretvalue and issecretvalue(name)) then name = "Player" end
    return name
end

function P:PlayerClass()
    local class
    if UnitClass then class = select(2, UnitClass("player")) end
    if type(class) ~= "string" or (issecretvalue and issecretvalue(class)) then class = "WARRIOR" end
    return class
end

-- Health of the sample bosses, slot by slot.
P.BOSS_HEALTH = { 0.92, 0.71, 0.55, 0.38, 0.2, 0.84, 0.63, 0.47 }

-- Sample names are display-only stand-ins (like the test pool's), never stored.
-- `slot` is the boss slot (boss previews only).
function P:TestData(unit, slot)
    local t = Base()
    local me, myClass = P:PlayerName(), P:PlayerClass()
    local lvl = (UnitLevel and UnitLevel("player")) or 80
    if type(lvl) ~= "number" or (issecretvalue and issecretvalue(lvl)) then lvl = 80 end
    if unit == "player" or unit == "targettarget" or unit == "focustarget" then
        t.name, t.class, t.role = me, myClass, "DAMAGER"
        t.level = lvl
        SetHealth(t, unit == "player" and 0.85 or 0.85)
        t.absorbPercent = (unit == "player") and 0.10 or 0
        t.isInCombat = true
    elseif unit == "target" then
        t.index = 2
        t.name, t.reaction, t.classification = "Training Dummy", 2, "elite"
        t.level = lvl + 1
        SetHealth(t, 0.62)
        t.powerPercent = 0.4
        t.targetName = me
    elseif unit == "focus" then
        t.index = 3
        t.name, t.reaction, t.classification = "Ember Root", 2, "rare"
        t.level = lvl
        SetHealth(t, 0.35)
        t.powerPercent = 0.9
        t.targetName = me
    elseif unit == "pet" then
        t.index = 4
        t.name, t.reaction = "Wolf", 5
        t.level = lvl
        SetHealth(t, 0.9)
        t.powerPercent = 0.6
    elseif unit == "boss" then
        -- A hidden level (-1, drawn "??") and the world-boss classification, the way
        -- an encounter's bosses report themselves.
        slot = slot or 1
        t.index = 4 + slot
        local L = DF.L
        t.name = string.format("%s %d", (L and L["Boss"]) or "Boss", slot)
        t.reaction, t.classification, t.level = 2, "worldboss", -1
        SetHealth(t, P.BOSS_HEALTH[slot] or 0.5)
        t.powerPercent = 0.5
        t.targetName = me
    end
    return t
end

-- ============================================================
-- TEST AURAS
-- The aura rows preview through DandersFrames' own test path: the test painter
-- (DF:UpdateTestFrame -> DF:UpdateTestAuras) drives the unit's real buff and
-- debuff rows, and the aura containers paint them from the test mode's sample
-- pool (DF.TestData) with the unit's own layout, size, max and borders. A preview
-- frame (dfPreview) is always in that preview shape, test mode on or not
-- (AuraContainer testShapeFor), so the mover session and the Preview switch show
-- them too. Nothing here makes auras of its own.
-- ============================================================

-- The test panel's AURAS switches -- Show Auras, the Buffs / Debuffs counts, Dispel
-- Overlay, Missing Buff, Aura Designer. They are stored in the PARTY or RAID table,
-- never a unit's, so a preview frame reads them from the test mode on screen (the
-- raid table while raid test mode is up, else the party table): the unit frames
-- follow the same switches as the group frames. Every other key is the unit's own.
P.TEST_KEYS = {
    testShowAuras = true, testBuffCount = true, testDebuffCount = true,
    testShowDispelGlow = true, testShowMissingBuff = true, testShowAuraDesigner = true,
}

function P:TestModeDB()
    if DF.raidTestMode and DF.GetRaidDB then return DF:GetRaidDB() end
    return DF.GetDB and DF:GetDB() or nil
end

-- A preview frame's settings table: the unit's own (UF:GetUnitDB), with the keys
-- above read from the test mode's table. Writes go to the unit's table. One per
-- unit, remade when the unit's table changes (a profile switch).
local previewDBs = {}
function P:PreviewDB(unit)
    local db = UF:GetUnitDB(unit)
    local cached = previewDBs[unit]
    if cached and cached.src == db then return cached.proxy end
    local proxy = setmetatable({}, {
        __index = function(_, key)
            if P.TEST_KEYS[key] then
                local t = P:TestModeDB()
                local v = t and t[key]
                if v ~= nil then return v end
            end
            return db[key]
        end,
        __newindex = function(_, key, value) db[key] = value end,
    })
    previewDBs[unit] = { src = db, proxy = proxy }
    return proxy
end

-- Which window of the sample pool each preview frame's rows draw (the frame's
-- dfTestAuraSeed; DandersFrames' testPoolOffset). The unit tokens carry no number,
-- so without a seed every frame would show the same samples. At the default count
-- of two the debuff windows are: player (no seed) Bleed + Disease, target Curse +
-- Poison (5 stacks), focus Magic + Curse, pet two untyped, so between them every
-- debuff type shows. The boss slots seed from their own tokens (boss1..boss5).
P.AURA_SEEDS = { target = 4, focus = 2, pet = 3, targettarget = 1, focustarget = 5 }

-- ============================================================
-- OWNERS
-- ============================================================
function P:IsActive()
    for _, wanted in pairs(P.owners) do
        if wanted then return true end
    end
    return false
end

function P:IsOwnedBy(owner) return P.owners[owner] and true or false end

function P:SetOwner(owner, wanted)
    P.owners[owner] = wanted and true or nil
    P:Reconcile()
    -- The boss preview depends on WHICH owners want it (Boss.lua PreviewWanted).
    if P.shown and UF.Boss and UF.Boss.PreviewRefresh then UF.Boss:PreviewRefresh() end
end

function P:Reconcile()
    local want = P:IsActive()
    if want and not P.shown then P:Show()
    elseif not want and P.shown then P:Hide() end
end

-- DandersFrames' test mode: on screen in either scope, when the option allows.
function P:SyncTestMode()
    local on = DF.IsTestModeActive and (DF:IsTestModeActive("party") or DF:IsTestModeActive("raid"))
    P:SetOwner("test", (on and UF:IncludeInTestMode()) and true or false)
end

function P:Init()
    if P.initialised then return end
    P.initialised = true
    if DF.RegisterCallback then
        DF.RegisterCallback(P, "OnTestModeChanged", function() P:SyncTestMode() end)
    end
end

-- ============================================================
-- FRAMES
-- ============================================================
function P:GetParent()
    if P.parent then return P.parent end
    local p = CreateFrame("Frame", "DandersUnitFramesPreview", UIParent)
    p:SetAllPoints(UIParent)
    -- ABOVE THE LIVE FRAMES, so the mouse reaches the preview. The live holders are
    -- only faded (alpha 0 still takes clicks), and switching their mouse off is not
    -- an option: EnableMouse on a protected button is blocked in combat. So the
    -- preview's own (plain) parent is lifted over the live parent instead -- set
    -- here, before any preview frame exists, so every one inherits it. +100 clears
    -- the deepest level offset inside a frame (+60). Never touches a secure frame.
    local live = UF.Units and UF.Units.parent
    if live then
        p:SetFrameStrata(live:GetFrameStrata())
        p:SetFrameLevel(live:GetFrameLevel() + P.LEVEL_ABOVE_LIVE)
    end
    P.parent = p
    return p
end

local function OnEnter(self)
    self.dfIsHovered = true
    if DF.UpdateHighlights then DF:UpdateHighlights(self) end
end

local function OnLeave(self)
    self.dfIsHovered = false
    if DF.UpdateHighlights then DF:UpdateHighlights(self) end
end

-- One preview frame on `unit`'s settings, named `name`, under `parent`. `slot`:
-- the boss slot it stands for (Boss.lua builds those), nil otherwise.
function P:Build(unit, name, parent, slot)
    local db = P:PreviewDB(unit)
    local f = CreateFrame("Button", name, parent)
    -- Marked BEFORE the elements are built, so everything they read resolves to the
    -- unit's own table and to test scope.
    f.dfIsTestFrame = true
    f.dfIsDandersFrame = true
    f.dfPreview = true
    f.dfStandalone = true
    f.dfDB = db
    f.dfUFUnit = unit
    f.dfUFSlot = slot
    f.dfUFPreview = true
    f.isRaidFrame = false
    f.unit = slot and (unit .. slot) or unit
    f.dfTestData = P:TestData(unit, slot)
    f.dfTestAuraSeed = P.AURA_SEEDS[unit]
    f.index = f.dfTestData.index
    f:EnableMouse(true)
    if DF.CreateFrameElements then DF:CreateFrameElements(f, false) end
    if DF.ApplyFrameStyle then DF:ApplyFrameStyle(f) end
    if DF.InitStandaloneFrame then DF:InitStandaloneFrame(f, db) end
    -- The unit-frame-only pieces (cast bar, class power, portrait, unit icons),
    -- built without event listeners: a preview frame only ever shows fake data.
    if UF.Elements then UF.Elements:Call("Attach", f) end
    f:SetScript("OnEnter", OnEnter)
    f:SetScript("OnLeave", OnLeave)
    f:Hide()
    return f
end

function P:Acquire(unit)
    local f = P.frames[unit]
    if f then return f end
    local names = UF.Units and UF.Units.FRAME_NAMES
    f = P:Build(unit, names and names[unit] and (names[unit] .. "Preview") or nil, P:GetParent())
    P.frames[unit] = f
    return f
end

function P:ApplyPosition(unit)
    local f = P.frames[unit]
    if not f or not UF.Units then return end
    UF.Units:PlaceAt(f, UF:GetPositionRecord(unit))
end

-- The test painter lives in the options addon; without it (it failed to load)
-- the live refresh still paints the frame in test scope.
function P:Paint(f)
    local db = P:PreviewDB(f.dfUFUnit)
    f.dfDB = db
    f.dfTextPresetOverride = db.textDesignerPreset
    f.dfMirrorText = UF.IsTextMirrored and UF:IsTextMirrored(f.dfUFUnit) or false
    f.dfTestData = P:TestData(f.dfUFUnit, f.dfUFSlot)
    if DF.ApplyFrameLayout then DF:ApplyFrameLayout(f) end
    if f.dfUFSlot then
        -- A boss slot: scaled and placed by its container (Boss.lua).
        f:SetScale(1)
    else
        f:SetScale(db.frameScale or 1)
        P:ApplyPosition(f.dfUFUnit)
    end
    if DF._optionsAddonLoaded and DF.UpdateTestFrame then
        DF:UpdateTestFrame(f, f.index)
    elseif DF.FullFrameRefresh then
        DF:FullFrameRefresh(f)
    end
    -- A cast mid-way, class power half full, the portrait and icons (spec §1.8).
    if UF.Elements then UF.Elements:Call("Preview", f) end
end

-- The units that get a preview: those this build draws itself. Boss has its own
-- (a container of slots, Boss.lua).
function P:Units()
    local list = {}
    for _, unit in ipairs(UF.SPAWNED_UNITS) do
        if unit ~= "boss" and UF.frames[unit] then list[#list + 1] = unit end
    end
    return list
end

local function FadeLive(alpha)
    local holders = UF.Units and UF.Units.holders
    for _, h in pairs(holders or {}) do h:SetAlpha(alpha) end
end

-- ============================================================
-- FOLLOWING THE TEST PANEL
-- The test panel's aura switches (P.TEST_KEYS) repaint the GROUP test frames only:
-- DF:UpdateTestAuras per frame, or DF:UpdateAllTestDispelGlow / ...MissingBuff /
-- ...AuraDesigner. So the preview listens on those, and when the switches it reads
-- have moved since its last paint it repaints once, on the next frame. The compare
-- keeps it quiet on every other group repaint (a settings drag, a roster change).
-- Hooked once, after the painter (the options addon) has loaded.
-- ============================================================
function P:TestKeysSig()
    local t = P:TestModeDB()
    if not t then return "" end
    return tostring(t.testShowAuras) .. "|" .. tostring(t.testBuffCount) .. "|" .. tostring(t.testDebuffCount)
        .. "|" .. tostring(t.testShowDispelGlow) .. "|" .. tostring(t.testShowMissingBuff)
        .. "|" .. tostring(t.testShowAuraDesigner)
end

function P:RequestRefresh()
    if not P.shown or P.refreshQueued then return end
    P.refreshQueued = true
    C_Timer.After(0, function()
        P.refreshQueued = false
        P:Refresh()
    end)
end

local function OnGroupAurasPainted(_, frame)
    if frame and frame.dfUFPreview then return end   -- our own paint
    if P.shown and P:TestKeysSig() ~= P.testSig then P:RequestRefresh() end
end

function P:HookTestPanel()
    if P.panelHooked or not hooksecurefunc or type(DF.UpdateTestAuras) ~= "function" then return end
    P.panelHooked = true
    hooksecurefunc(DF, "UpdateTestAuras", OnGroupAurasPainted)
    for _, name in ipairs({ "UpdateAllTestDispelGlow", "UpdateAllTestMissingBuff", "UpdateAllTestAuraDesigner" }) do
        if type(DF[name]) == "function" then hooksecurefunc(DF, name, OnGroupAurasPainted) end
    end
end

function P:Show()
    -- The painter is in the load-on-demand options addon. Loading it is what
    -- DandersFrames' own mover session does too; never mid-fight.
    if not DF._optionsAddonLoaded and DF.EnsureOptionsLoaded and not InCombatLockdown() then
        DF:EnsureOptionsLoaded()
    end
    P:HookTestPanel()
    P.shown = true
    P.testSig = P:TestKeysSig()
    -- The parent carries the DETACHED pieces too (a detached preview cast bar is
    -- parented here, not to its frame), so it is shown and hidden with the preview.
    P:GetParent():Show()
    for _, unit in ipairs(P:Units()) do
        local f = P:Acquire(unit)
        f:Show()
        P:Paint(f)
    end
    if UF.Boss and UF.Boss.PreviewRefresh then UF.Boss:PreviewRefresh() end
    FadeLive(0)
    UF.Debug("preview on")
end

function P:Hide()
    P.shown = false
    for _, f in pairs(P.frames) do f:Hide() end
    if UF.Boss and UF.Boss.PreviewHide then UF.Boss:PreviewHide() end
    if P.parent then P.parent:Hide() end
    FadeLive(1)
    -- The live frames missed nothing (they kept their events), but a repaint costs
    -- little and settles anything a settings change did meanwhile.
    if UF.RequestRefresh then UF:RequestRefresh() end
    UF.Debug("preview off")
end

-- Settings changed, or the profile did: repaint what is up.
function P:Refresh()
    if not P.shown then return end
    P.testSig = P:TestKeysSig()
    for _, unit in ipairs(P:Units()) do
        local f = P:Acquire(unit)
        if not f:IsShown() then f:Show() end
        P:Paint(f)
    end
    if UF.Boss and UF.Boss.PreviewRefresh then UF.Boss:PreviewRefresh() end
end
