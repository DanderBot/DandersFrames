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
--   "unlock"    a DandersMover session (Mover.lua's Unlocked / Locked). Every
--               preview shows, so there is something to drag.
--   "test"      the UNITS TEST MODE (P:SetTestMode): the Test button on a Unit
--               Frames page, the test popup's Units mode, /df test units. The
--               mode's Frames switches pick which previews show.
--
-- ★ THE UNITS TEST MODE AND DANDERSFRAMES' PARTY / RAID TEST MODE NEVER MIX.
-- Turning this one on drops the user's party and raid claims (and closes their
-- panel); the user claiming either of those turns this one off (the
-- SetTestModeOwner hook in P:Init). Party and raid test mode never show unit
-- frames. A mover session's own claims are left alone on both sides.
-- ============================================================

local DF = DandersFrames
if not DF then return end

local pairs, ipairs, type, pcall, tonumber = pairs, ipairs, type, pcall, tonumber
local sin, max, min, floor, pi = math.sin, math.max, math.min, math.floor, math.pi

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
    t.currentHealth = floor(pct * t.maxHealth)
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

-- ============================================================
-- THE UNITS TEST SETTINGS (the test panel's; UF:GetTestDB, Defaults.lua)
-- ============================================================

-- The settings table, or the defaults before the profile exists.
function P:TestDB()
    return (UF.GetTestDB and UF:GetTestDB()) or UF.TestDefaults or {}
end

-- One switch: on unless switched off.
function P:TestOn(key)
    return P:TestDB()[key] ~= false
end

P.REACTION = { hostile = 2, neutral = 4, friendly = 5 }
-- The classifications the frames draw (the Elite / Rare icon, the Text Designer's
-- Classification token). "normal" draws none.
P.CLASSIFICATIONS = { normal = true, elite = true, rare = true, rareelite = true, worldboss = true }
-- The raid target icon each sample enemy wears (a boss slot wears its slot's).
P.RAID_TARGET = { target = 8, focus = 7 }

-- The animated health wave -- the party test mode's: the unit's own health +/-
-- 15%, offset per frame. P.animPhase is nil while nothing animates.
function P:AnimatedHealth(base, index)
    if not P.animPhase then return base end
    local wave = sin((P.animPhase + ((index or 1) * 0.13) % 1) * pi * 2)
    return max(0.1, min(1, base + wave * 0.15))
end

-- The test panel's choices, laid over a sample unit.
function P:ApplyTestSettings(t, unit, slot)
    local tdb = P:TestDB()
    if unit == "target" then
        local c = tdb.classification
        if P.CLASSIFICATIONS[c] then t.classification = (c ~= "normal") and c or nil end
        t.reaction = P.REACTION[tdb.reaction] or t.reaction
    end
    if tdb.showRaidTarget ~= false then
        if unit == "boss" then t.raidTarget = slot or 1 else t.raidTarget = P.RAID_TARGET[unit] end
    end
    if unit == "player" then
        t.isLeader = tdb.showLeader ~= false
        t.isInCombat = tdb.showCombat ~= false
    end
    local base = t.healthPercent
    if tdb.fixedHealth then
        local pct = tonumber(tdb.healthPercent) or 75
        base = max(0.01, min(1, pct / 100))
    end
    t.baseHealth = base
    SetHealth(t, tdb.testAnimateHealth and P:AnimatedHealth(base, t.index) or base)
end

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
        SetHealth(t, 0.85)
        if unit == "player" then
            -- Something for each of the test panel's Bars switches to show.
            t.absorbPercent, t.healAbsorbPercent, t.healPredictionPercent = 0.10, 0.08, 0.10
        end
    elseif unit == "target" then
        t.index = 2
        t.name, t.reaction, t.classification = "Training Dummy", 2, "elite"
        t.level = lvl + 1
        SetHealth(t, 0.62)
        t.powerPercent = 0.4
        t.absorbPercent = 0.12
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
    P:ApplyTestSettings(t, unit, slot)
    return t
end

-- ============================================================
-- TEST AURAS
-- The aura rows preview through DandersFrames' own test path: the test painter
-- (DF:UpdateTestFrame -> DF:UpdateTestAuras) drives the unit's real buff and
-- debuff rows, and the aura containers paint them from the test mode's sample
-- pool (DF.TestData) with the unit's own layout, size, max and borders. A preview
-- frame (dfPreview) is always in that preview shape, test mode on or not
-- (AuraContainer testShapeFor), so the mover session shows them too. Nothing
-- here makes auras of its own.
-- ============================================================

-- The keys DandersFrames' test painter reads off a frame's settings table
-- (DF:UpdateTestFrame, DF:UpdateTestAuras, the status icon painter). A preview
-- frame answers them from the UNITS test settings (UF:GetTestDB), never from the
-- party or raid table: the units test panel is the one that moves them. Every
-- other key is the unit's own.
P.TEST_KEYS = {
    testShowAuras = true, testBuffCount = true, testDebuffCount = true,
    testShowAbsorbs = true, testShowHealPrediction = true,
    testShowStatusIcons = true, testAnimateHealth = true,
    testShowSelection = true, testShowAggro = true,
    testShowLabels = true, testShowAuraDesigner = true,
}

-- Which preview shows the Selection highlight (DF:UpdateHighlights reads
-- frame.dfTestSelected ahead of its party-slot rule). The pet: a friendly frame,
-- where a selection outline means something, and Target's own is off for good.
-- Aggro follows the slot rule on frame.index: the player tanks (1), the pet
-- holds high threat (4); hostile frames have their aggro highlight off.
P.SELECTED_UNIT = "pet"

-- A preview frame's settings table: the unit's own (UF:GetUnitDB), with the keys
-- above read from the units test settings, and a RING-style unit's frame answers
-- (Rings.lua R.FrameValue). Writes go to the unit's table. One per
-- unit, remade when the unit's table changes (a profile switch).
local previewDBs = {}
function P:PreviewDB(unit)
    local db = UF:GetUnitDB(unit)
    local cached = previewDBs[unit]
    if cached and cached.src == db then return cached.proxy end
    local proxy = setmetatable({}, {
        __index = function(_, key)
            if P.TEST_KEYS[key] then
                local v = P:TestDB()[key]
                if v ~= nil then return v end
            end
            -- RING style: the same answers the live frame's view gives (Rings.lua).
            local R = UF.Rings
            if R then
                local handled, v = R.FrameValue(db, key)
                if handled then return v end
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
    local had = P.owners[owner] and true or false
    P.owners[owner] = wanted and true or nil
    if P.shown and P:IsActive() and had ~= (wanted and true or false) then
        -- Still up, but WHICH previews show depends on the owners (a mover session
        -- shows every one; the test mode only those its panel picks). Refresh
        -- repaints the boss slots too (Boss.lua PreviewWanted).
        P:Refresh()
    else
        P:Reconcile()
    end
end

function P:Reconcile()
    local want = P:IsActive()
    if want and not P.shown then P:Show()
    elseif not want and P.shown then P:Hide() end
end

-- ============================================================
-- THE UNITS TEST MODE
-- ============================================================
P.listeners = {}

-- fn(on, reason): the test mode went on or off. reason: "user" (its own
-- switches), "combat", or "group" (the party / raid test mode took over).
function P:AddListener(fn)
    if type(fn) == "function" then P.listeners[#P.listeners + 1] = fn end
end

local function Notify(on, reason)
    for _, fn in ipairs(P.listeners) do pcall(fn, on, reason) end
    if DF.GUI and DF.GUI.UpdateTestButtonState then DF.GUI.UpdateTestButtonState() end
end

function P:IsTestMode() return P:IsOwnedBy("test") end

-- The party / raid test mode the USER asked for. A mover session's claim is not
-- the user's, and is left alone.
local function GroupTestOwned()
    if not DF.IsTestModeOwnedBy then return false end
    return DF:IsTestModeOwnedBy("party", "user") or DF:IsTestModeOwnedBy("raid", "user")
end

local function ReleaseGroupTest()
    -- The test popup showing Party / Raid releases both claims as it closes
    -- (TestMode.lua, the popup's OnHide). Showing Units (the popup's Units mode
    -- is what turns this on), it stays: the claims are dropped below.
    local panel = DF.TestPanel
    if panel and panel.IsShown and panel:IsShown() then
        local st = panel.state
        if not (st and st.modeId == "units") then panel:Hide() end
    end
    if DF.SetTestModeOwner and GroupTestOwned() then
        DF:SetTestModeOwner("party", "user", false, true)
        DF:SetTestModeOwner("raid", "user", false, true)
    end
end

-- Turn the units test mode on or off. Turning it on is refused in combat, the
-- same as the party and raid test mode (whose combat entry ends it too -- see
-- P:OnCombat). Returns whether the mode is now what was asked.
function P:SetTestMode(on, reason)
    on = on and true or false
    if on == P:IsTestMode() then return true end
    if on and InCombatLockdown and InCombatLockdown() then
        local L = DF.L
        if DF.Say and L then DF:Say(L["Cannot enter test mode during combat."]) end
        return false
    end
    if on then
        P.releasingGroup = true
        ReleaseGroupTest()
        P.releasingGroup = nil
    end
    P:SetOwner("test", on)
    Notify(on, reason or "user")
    return true
end

function P:ToggleTestMode()
    return P:SetTestMode(not P:IsTestMode())
end

-- After DandersFrames' SetTestModeOwner ran: the USER claimed the party or raid
-- test mode, so this one steps aside.
local function OnGroupOwner(_, scope, owner, wanted)
    if P.releasingGroup or owner ~= "user" or not wanted then return end
    if P:IsTestMode() then P:SetTestMode(false, "group") end
end

-- Entering combat ends the test mode, as DandersFrames does to its own, with the
-- same chat line. A mover session's preview is the mover's business.
function P:OnCombat()
    if not P:IsTestMode() then return end
    P:SetTestMode(false, "combat")
    local L = DF.L
    if DF.Say and L then DF:Say(L["Test mode ended — entering combat."]) end
end

function P:Init()
    if P.initialised then return end
    P.initialised = true
    if hooksecurefunc and type(DF.SetTestModeOwner) == "function" then
        hooksecurefunc(DF, "SetTestModeOwner", OnGroupOwner)
    end
    -- An Aura Designer edit refreshes the designer on every frame through the
    -- engine; the previews' half of that is P:RefreshAuraDesigner.
    local Engine = DF.AuraDesigner and DF.AuraDesigner.Engine
    if hooksecurefunc and Engine and type(Engine.ForceRefreshAllFrames) == "function" then
        hooksecurefunc(Engine, "ForceRefreshAllFrames", function() P:RefreshAuraDesigner() end)
    end
    if CreateFrame then
        local ev = CreateFrame("Frame")
        ev:RegisterEvent("PLAYER_REGEN_DISABLED")
        ev:SetScript("OnEvent", function() P:OnCombat() end)
        P.eventFrame = ev
    end
end

-- Does `unit`'s preview show? Every one during a mover session; under the test
-- mode alone, the ones its panel's Frames switches leave on. (Boss: Boss.lua
-- PreviewWanted.)
P.SHOW_KEY = { player = "showPlayer", target = "showTarget", targettarget = "showTargetTarget",
               focus = "showFocus", focustarget = "showFocusTarget", pet = "showPet" }
function P:UnitWanted(unit)
    if P:IsOwnedBy("unlock") then return true end
    local key = P.SHOW_KEY[unit]
    return not key or P:TestOn(key)
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
    if DF.OnFrameHoverChanged then DF:OnFrameHoverChanged(self, true) end
end

local function OnLeave(self)
    self.dfIsHovered = false
    if DF.UpdateHighlights then DF:UpdateHighlights(self) end
    if DF.OnFrameHoverChanged then DF:OnFrameHoverChanged(self, false) end
end

-- Indicator Info's click-to-open-settings (DandersFrames_Options/TestMode/Labels.lua,
-- the "units" frame source in DandersFrames_Options/UnitFrames/TestLabels.lua). A
-- no-op unless that option is on and an element is marked under the cursor; it
-- refuses in combat and during a mover session itself. Looked up per click: the
-- options addon loads on demand.
local function OnClick(self, button)
    local TL = DF.TestLabels
    if TL and TL.HandleClick then TL:HandleClick(self, button) end
end

-- One preview frame on `unit`'s settings, named `name`, under `parent`. `slot`:
-- the boss slot it stands for (Boss.lua builds those), nil otherwise.
function P:Build(unit, name, parent, slot, token)
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
    -- `token`: a sample's "none" (P:BuildSample), set before anything is built on it.
    f.unit = token or (slot and (unit .. slot) or unit)
    f.dfTestData = P:TestData(unit, slot)
    f.dfTestAuraSeed = P.AURA_SEEDS[unit]
    -- Where its aura rows sit, as on the live frame (Elements.lua).
    f.dfAuraRowPlacement = UF.AuraRowPlacement
    -- Purgeable enemy buffs lead its buff row, ringed (Elements.lua UF.BuffPurgeable).
    f.dfBuffPurgeable = UF.BuffPurgeable
    -- Its highlights' outline, as on the live frame (Indicators.lua).
    f.dfHighlightShape = UF.Indicators and UF.Indicators.HighlightShape or nil
    -- Text Designer ring anchors and hover, as on the live frame (Units:Build).
    f.dfTDAnchorSpot = UF.Rings and UF.Rings.AnchorSpot or nil
    f.dfHoverHook = UF.OnHover
    f.index = f.dfTestData.index
    f.dfTestSelected = (unit == P.SELECTED_UNIT)
    f:EnableMouse(true)
    if DF.CreateFrameElements then DF:CreateFrameElements(f, false) end
    if DF.ApplyFrameStyle then DF:ApplyFrameStyle(f) end
    if DF.InitStandaloneFrame then DF:InitStandaloneFrame(f, db) end
    -- The unit-frame-only pieces (cast bar, class power, portrait, unit icons),
    -- built without event listeners: a preview frame only ever shows fake data.
    if UF.Elements then UF.Elements:Call("Attach", f) end
    f:SetScript("OnEnter", OnEnter)
    f:SetScript("OnLeave", OnLeave)
    f:SetScript("OnClick", OnClick)
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
    UF:StampDesigners(f, db)
    f.dfMirrorText = UF.IsTextMirrored and UF:IsTextMirrored(f.dfUFUnit) or false
    f.dfTestData = P:TestData(f.dfUFUnit, f.dfUFSlot)
    if DF.ApplyFrameLayout then DF:ApplyFrameLayout(f) end
    if f.dfUFSample then
        -- A settings sample (P:BuildSample): its owner places and scales it.
    elseif f.dfUFSlot then
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

-- ============================================================
-- SAMPLES (a settings page's own preview of a unit: the Text Designer's on a unit
-- page, DandersFrames_Options/UnitFrames/Pages.lua UFO.DesignerTarget)
-- One frame built and painted EXACTLY as a test-mode preview is (P:Build, P:Paint:
-- the unit's real look -- rings, portrait shape, a detached resource bar, the cast
-- bar, auras), but owned by the page that asked: never placed on the screen,
-- never in P.frames (the preview's show / hide / refresh never touch it), drawn
-- whether or not the preview is up, and deaf to the mouse. Its DETACHED cast bar
-- and class power (mover records: screen places) go to a hidden holder of its own.
-- UF:RefreshAll repaints the visible ones (P:RefreshSamples), so a setting changed
-- on another page is there when the sample's page shows again.
-- ============================================================
P.samples = setmetatable({}, { __mode = "k" })

-- ☠ NO UNIT TOKEN. A preview frame keeps its unit's real token (player, target,
-- boss1) and is painted from sample data -- but every DandersFrames painter has a
-- LIVE fallback that reads the frame's token (UnitHealthPercent, UnitHealthMissing,
-- UnitHealth, the class / reaction colours...), and a live answer is SECRET in
-- restricted content. A secret fed to a StatusBar makes its fill's size secret, and
-- a sample lives INSIDE the settings page's scroll content: the page's scroll range
-- went secret with it, and the page's scroll bar then compared and SetEnabled-ed a
-- secret ("Button:SetEnabled(): Cannot be called with secrets", the Text Designer
-- page, 2026-11-01). So a sample answers to "none", a token that never exists: any
-- live read on it is empty and plain. What the sample draws comes from its sample
-- data (dfTestData) and from the literal "player" where a preview asks for the
-- player's own look (portrait, class power, power colour).
P.SAMPLE_TOKEN = "none"

function P:BuildSample(unit, parent)
    local f = P:Build(unit, nil, parent, unit == "boss" and 1 or nil, P.SAMPLE_TOKEN)
    f.dfUFSample = true
    f.dfUFSampleHold = CreateFrame("Frame", nil, f)
    f.dfUFSampleHold:Hide()
    f:EnableMouse(false)
    f:SetScript("OnEnter", nil)
    f:SetScript("OnLeave", nil)
    f:SetScript("OnClick", nil)
    P.samples[f] = true
    return f
end

function P:PaintSample(f)
    if not (f and f.dfUFSample) then return end
    f:Show()
    P:Paint(f)
end

function P:RefreshSamples()
    for f in pairs(P.samples) do
        if f:IsVisible() then P:Paint(f) end
    end
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
-- ANIMATED HEALTH (the units test panel's Animate Health)
-- Its own ticker, at the party test mode's rhythm: 20 steps a second, health
-- only (DF:UpdateTestFrameHealthOnly), each frame's own sample as the centre.
-- ============================================================
local function EachShownFrame(fn)
    for _, f in pairs(P.frames) do
        if f:IsShown() then fn(f) end
    end
    local boss = UF.Boss and UF.Boss.preview
    for _, f in pairs(boss or {}) do
        if f:IsShown() then fn(f) end
    end
end

local function AnimateFrame(f)
    local d = f.dfTestData
    if not (d and d.baseHealth) then return end
    SetHealth(d, P:AnimatedHealth(d.baseHealth, d.index))
    if DF.UpdateTestFrameHealthOnly then DF:UpdateTestFrameHealthOnly(f, f.index) end
end

-- ============================================================
-- AURA DESIGNER (docs/superpowers/specs/2026-11-01-uf-per-unit-designers.md, phase 3)
-- The test painter runs the Aura Designer on every preview it paints
-- (DF:UpdateTestFrame -> the factory), gated on testShowAuraDesigner -- a units
-- test key (P.TEST_KEYS), on by default -- and on the unit's OWN enable
-- (DF:IsAuraDesignerEnabled answers a standalone frame from its own table). The
-- template is the unit's own stamp (UF:StampDesigners in P:Paint): its own, or
-- Party's while it follows Party.
-- ⚠ An editor change does not repaint whole frames: it calls the engine's
-- ForceRefreshAllFrames, whose test refresh (DF:UpdateAllTestAuraDesigner) walks
-- the party and raid test frames only, and only in their test mode. Its standalone
-- walk skips preview frames on purpose. P:RefreshAuraDesigner is the previews'
-- half, hooked onto it (P:Init): the same gate, the same factory calls and the
-- same appearance pass after them, as that test refresh does per frame.
-- Sound alerts never arm from a preview (the factory's sound reconcile skips
-- dfPreview frames; its sync skips sound in test scope).
-- ============================================================
function P:AuraDesignerWanted(f)
    local db = f.dfDB
    if not (db and db.testShowAuraDesigner) then return false end
    if not (DF.IsAuraDesignerEnabled and DF:IsAuraDesignerEnabled(f)) then return false end
    return not (DF.IsTestFrameDead and DF:IsTestFrameDead(f))
end

function P:SyncAuraDesigner(f)
    local Factory = DF.AuraDesigner and DF.AuraDesigner.Factory
    if not Factory then return end
    local db = P:PreviewDB(f.dfUFUnit)
    f.dfDB = db
    -- Re-stamped: a unit following Party draws whatever Party points at NOW.
    UF:StampDesigners(f, db)
    if P:AuraDesignerWanted(f) then
        Factory:SyncFrame(f)
    else
        Factory:ClearFrame(f)
    end
    -- The appearance pass goes after the sync (SyncFrame re-styles to base alpha).
    if DF.UpdateAuraDesignerAppearance then DF:UpdateAuraDesignerAppearance(f) end
    if DF.UpdateHealthBarAppearance then DF:UpdateHealthBarAppearance(f) end
end

function P:RefreshAuraDesigner()
    if not P.shown then return end
    EachShownFrame(function(f) P:SyncAuraDesigner(f) end)
end

-- Every preview drops what the designer drew on it (the preview going away).
-- Only frames that ever drew it: ClearFrame has nothing to do on the rest.
function P:ClearAuraDesigner()
    local Factory = DF.AuraDesigner and DF.AuraDesigner.Factory
    if not Factory then return end
    local function Clear(f)
        if rawget(f, "dfADFactory") then Factory:ClearFrame(f) end
    end
    for _, f in pairs(P.frames) do Clear(f) end
    local boss = UF.Boss and UF.Boss.preview
    for _, f in pairs(boss or {}) do Clear(f) end
end

function P:AnimateStep()
    P.animPhase = ((P.animPhase or 0) + 0.02) % 1
    EachShownFrame(AnimateFrame)
end

function P:SyncAnimation()
    local want = (P.shown and P:TestDB().testAnimateHealth) and true or false
    if want and not P.animTicker and C_Timer and C_Timer.NewTicker then
        P.animPhase = 0
        P.animTicker = C_Timer.NewTicker(0.05, function() P:AnimateStep() end)
    elseif not want and P.animTicker then
        P.animTicker:Cancel()
        P.animTicker = nil
        P.animPhase = nil
    end
end

-- ============================================================
-- SHOW / HIDE / REFRESH
-- ============================================================
function P:RequestRefresh()
    if not P.shown or P.refreshQueued then return end
    P.refreshQueued = true
    C_Timer.After(0, function()
        P.refreshQueued = false
        P:Refresh()
    end)
end

-- Show and paint the previews that are wanted (P:UnitWanted), hide the rest.
function P:PaintUnits()
    for _, unit in ipairs(P:Units()) do
        if P:UnitWanted(unit) then
            local f = P:Acquire(unit)
            if not f:IsShown() then f:Show() end
            P:Paint(f)
        elseif P.frames[unit] then
            P.frames[unit]:Hide()
        end
    end
end

function P:Show()
    -- The painter is in the load-on-demand options addon. Loading it is what
    -- DandersFrames' own mover session does too; never mid-fight.
    if not DF._optionsAddonLoaded and DF.EnsureOptionsLoaded and not InCombatLockdown() then
        DF:EnsureOptionsLoaded()
    end
    P.shown = true
    -- The parent carries the DETACHED pieces too (a detached preview cast bar is
    -- parented here, not to its frame), so it is shown and hidden with the preview.
    P:GetParent():Show()
    P:PaintUnits()
    if UF.Boss and UF.Boss.PreviewRefresh then UF.Boss:PreviewRefresh() end
    FadeLive(0)
    P:SyncAnimation()
    UF.Debug("preview on")
end

function P:Hide()
    P.shown = false
    P:SyncAnimation()
    for _, f in pairs(P.frames) do f:Hide() end
    if UF.Boss and UF.Boss.PreviewHide then UF.Boss:PreviewHide() end
    P:ClearAuraDesigner()
    if P.parent then P.parent:Hide() end
    FadeLive(1)
    -- The live frames missed nothing (they kept their events), but a repaint costs
    -- little and settles anything a settings change did meanwhile.
    if UF.RequestRefresh then UF:RequestRefresh() end
    UF.Debug("preview off")
end

-- Settings changed, the profile did, or the test panel moved a switch: repaint
-- what is up.
function P:Refresh()
    if not P.shown then return end
    P:PaintUnits()
    if UF.Boss and UF.Boss.PreviewRefresh then UF.Boss:PreviewRefresh() end
    P:SyncAnimation()
end
