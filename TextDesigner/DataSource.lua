local addonName, DF = ...

-- ============================================================
-- TEXT DESIGNER — DATA SOURCE
-- Abstraction layer between the Resolver and the underlying
-- data (real unit-frame state OR synthetic mock values).
-- Both factories return an object implementing the same getter
-- interface, so the Resolver is phase-agnostic.
-- ============================================================

DF.TextDesigner = DF.TextDesigner or {}
local DataSource = {}
DF.TextDesigner.DataSource = DataSource

local MS = nil  -- resolved lazily; MidnightSafe loads before Resolver but file load order is TextDesigner→MidnightSafe→DataSource

local function getMS()
    if not MS then MS = DF.TextDesigner.MidnightSafe end
    return MS
end

-- ============================================================
-- MOCK DATA — synthetic values for the preview
--
-- The unit is alive, connected, in-range, with a slight max-HP debuff,
-- a small absorb + heal absorb, and some threat. This exercises
-- as many content types as possible in a single static state.
--
-- Content types that INTENTIONALLY render empty in this baseline:
--   - status_text  (the unit is alive + connected — no status to show)
--   - range_text   (in range — no "OOR" prefix)
--   - custom_static (defaults to empty user-supplied text)
--
-- For full state coverage, see /df test (whole-frame multi-state preview).
-- ============================================================

local MOCK_DATA = {
    -- Identity
    name             = "Danders",
    classToken       = "SHAMAN",
    classLocalized   = "Shaman",
    level            = 80,
    race             = "Draenei",
    raceLocalized    = "Draenei",
    faction          = "Alliance",
    groupNumber      = 2,
    -- Health (slight max-reduction added)
    hpCurrent        = 287456,
    hpMax            = 471140,
    hpPercent        = 61,
    hpDeficit        = 183684,
    hpMaxReductionPct = 0.05,  -- 5% reduction → -5%
    -- Power
    powerCurrent     = 154000,
    powerMax         = 278460,
    powerPercent     = 55,
    powerDeficit     = 124460,
    powerTypeToken   = "MANA",
    powerTypeString  = "Mana",
    -- Shields & Heals (absorb + heal_absorb)
    absorbAmount     = 25000,
    healAbsorbAmount = 5000,
    incomingHealTotal = 12000,
    incomingHealFromPlayer = 8000,
    -- Status / Threat / Range (still alive/connected/in-range — those types are "" by design)
    isDead           = false,
    isGhost          = false,
    isConnected      = true,
    isFeignDeath     = false,
    aggroFlag        = 2,        -- "++"
    threatPercent    = 75,       -- "75%"
    isInRange        = true,
}

-- ============================================================
-- MOCK FACTORY
-- Returns a source that reads from MOCK_DATA. Used for the preview.
-- ============================================================

local mockSourceInstance  -- singleton — mock data is shared

local MockSource = {}
MockSource.__index = MockSource

-- Marks the single preview mock unit (NOT the per-frame test source). The
-- status_text resolver uses this to show a sample status in the preview even
-- though the mock unit is "alive", so the element is visible/stylable. Test
-- frames must NOT set this — they show real per-unit status (no overlap).
function MockSource:_isPreviewSample() return true end

function MockSource:GetName() return MOCK_DATA.name end
function MockSource:GetClassToken() return MOCK_DATA.classToken end
function MockSource:GetClassLocalized() return MOCK_DATA.classLocalized end
function MockSource:GetLevel() return MOCK_DATA.level end
function MockSource:GetRace() return MOCK_DATA.raceLocalized end
function MockSource:GetFaction() return MOCK_DATA.faction end
function MockSource:GetGroupNumber() return MOCK_DATA.groupNumber end

function MockSource:GetHPCurrent() return MOCK_DATA.hpCurrent end
function MockSource:GetHPMax() return MOCK_DATA.hpMax end
function MockSource:GetHPPercent() return MOCK_DATA.hpPercent end
function MockSource:GetHPDeficit() return MOCK_DATA.hpDeficit end
function MockSource:GetHPMaxReductionPct() return MOCK_DATA.hpMaxReductionPct end

function MockSource:GetPowerCurrent() return MOCK_DATA.powerCurrent end
function MockSource:GetPowerPercent() return MOCK_DATA.powerPercent end
function MockSource:GetPowerDeficit() return MOCK_DATA.powerDeficit end
function MockSource:GetPowerTypeString() return MOCK_DATA.powerTypeString end

function MockSource:GetAbsorbAmount() return MOCK_DATA.absorbAmount end
function MockSource:GetHealAbsorbAmount() return MOCK_DATA.healAbsorbAmount end
function MockSource:GetIncomingHealTotal() return MOCK_DATA.incomingHealTotal end
function MockSource:GetIncomingHealFromPlayer() return MOCK_DATA.incomingHealFromPlayer end

function MockSource:IsDead() return MOCK_DATA.isDead end
function MockSource:IsGhost() return MOCK_DATA.isGhost end
function MockSource:IsConnected() return MOCK_DATA.isConnected end
function MockSource:IsFeignDeath() return MOCK_DATA.isFeignDeath end
function MockSource:GetAggroFlag() return MOCK_DATA.aggroFlag end
function MockSource:GetThreatPercent() return MOCK_DATA.threatPercent end
function MockSource:IsInRange() return MOCK_DATA.isInRange end

function DataSource.Mock()
    if not mockSourceInstance then
        mockSourceInstance = setmetatable({}, MockSource)
    end
    return mockSourceInstance
end

DataSource.MOCK_DATA = MOCK_DATA  -- expose so Preview can read it for chrome rendering

-- ============================================================
-- LIVE FACTORY
-- Returns a source bound to a real DF frame.unit. Reads from
-- cached frame state where available, falls back to direct API.
-- Note: this is fully implemented now so Phase C plugs in cleanly,
-- but isn't yet consumed by the preview pipeline.
-- ============================================================

local LiveSource = {}
LiveSource.__index = LiveSource

function LiveSource:GetName()
    if DF.GetFrameName then return DF:GetFrameName(self.unit) end
    return UnitName(self.unit) or ""
end

function LiveSource:GetClassToken()
    local _, token = UnitClass(self.unit)
    return token or "WARRIOR"  -- fallback so RAID_CLASS_COLORS lookup never returns nil
end

function LiveSource:GetClassLocalized()
    local localized = UnitClass(self.unit)
    -- Secret class string: return verbatim; the `~= ""` below would throw on it.
    if getMS().IsSecret(localized) then return localized end
    if localized and localized ~= "" then return localized end
    -- Match GetClassToken's "WARRIOR" fallback so downstream gets
    -- consistent class info even on missing unit data.
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE.WARRIOR) or "Warrior"
end

function LiveSource:GetLevel()
    local lvl = UnitLevel(self.unit)
    if getMS().IsSecret(lvl) then return "??" end
    if not lvl or lvl <= 0 then return "??" end
    return lvl
end

function LiveSource:GetRace()
    return UnitRace(self.unit) or ""
end

function LiveSource:GetFaction()
    return UnitFactionGroup(self.unit) or ""
end

function LiveSource:GetGroupNumber()
    local idx = UnitInRaid(self.unit)
    if not idx then return nil end
    local _, _, subgroup = GetRaidRosterInfo(idx)
    if getMS().IsSecret(subgroup) then return nil end
    return subgroup
end

function LiveSource:GetHPCurrent()
    return UnitHealth(self.unit)
end

function LiveSource:GetHPMax()
    return UnitHealthMax(self.unit)
end

function LiveSource:GetHPPercent()
    if _G.UnitHealthPercent then
        return UnitHealthPercent(self.unit, true, getMS().ScaleTo100)
    end
    return nil
end

function LiveSource:GetHPDeficit()
    if _G.UnitHealthMissing then
        return UnitHealthMissing(self.unit)
    end
    return nil
end

function LiveSource:GetHPMaxReductionPct()
    if _G.GetUnitTotalModifiedMaxHealthPercent then
        return GetUnitTotalModifiedMaxHealthPercent(self.unit)
    end
    return 0
end

function LiveSource:GetPowerCurrent()
    return UnitPower(self.unit)
end

function LiveSource:GetPowerPercent()
    if _G.UnitPowerPercent then
        return UnitPowerPercent(self.unit, nil, false, getMS().ScaleTo100)
    end
    return nil
end

function LiveSource:GetPowerDeficit()
    if _G.UnitPowerMissing then
        return UnitPowerMissing(self.unit)
    end
    return nil
end

-- "RUNIC_POWER" -> "Runic Power", "FOCUS" -> "Focus". Used as a guaranteed
-- fallback so we never leak a raw token like "POWER_TYPE_FOCUS" to the display.
local function prettyPowerToken(token)
    local parts = {}
    for word in token:gmatch("[^_]+") do
        parts[#parts + 1] = word:sub(1, 1):upper() .. word:sub(2):lower()
    end
    return table.concat(parts, " ")
end

function LiveSource:GetPowerTypeString()
    local _, token = UnitPowerType(self.unit)
    if not token then return "" end
    -- WoW exposes localized power-type names as BARE-token global strings
    -- (FOCUS = "Focus", MANA = "Mana", RUNIC_POWER = "Runic Power"). The old
    -- "POWER_TYPE_"..token lookup hit no such global and leaked the raw key
    -- ("POWER_TYPE_FOCUS"). Prefer the localized global; fall back to a
    -- title-cased token if it's missing.
    local name = _G[token]
    if type(name) == "string" and name ~= "" then
        return name
    end
    return prettyPowerToken(token)
end

function LiveSource:GetAbsorbAmount()
    return UnitGetTotalAbsorbs(self.unit) or 0
end

function LiveSource:GetHealAbsorbAmount()
    return UnitGetTotalHealAbsorbs(self.unit) or 0
end

function LiveSource:GetIncomingHealTotal()
    -- Prefer the value stashed by UpdateHealPrediction. It may be a SECRET
    -- number on Midnight, so test IsSecret BEFORE the `~= nil` comparison —
    -- comparing a secret with ~= throws "execution tainted" (same class as
    -- the dfInRange guard in Range.lua). A secret value is, by definition,
    -- present, so the IsSecret branch short-circuits the nil check.
    if self.frame then
        local v = self.frame.dfTotalHeals
        if getMS().IsSecret(v) then return v end
        if v ~= nil then return v end
    end
    return UnitGetIncomingHeals(self.unit) or 0
end

function LiveSource:GetIncomingHealFromPlayer()
    if self.frame then
        local v = self.frame.dfMyHeals
        if getMS().IsSecret(v) then return v end
        if v ~= nil then return v end
    end
    return UnitGetIncomingHeals(self.unit, "player") or 0
end

function LiveSource:IsDead()
    return UnitIsDead(self.unit) or false
end

function LiveSource:IsGhost()
    return UnitIsGhost(self.unit) or false
end

function LiveSource:IsConnected()
    return UnitIsConnected(self.unit)
end

function LiveSource:IsFeignDeath()
    return UnitIsFeignDeath(self.unit) or false
end

function LiveSource:GetAggroFlag()
    -- Prefer the value stashed by UpdateHighlights (Features/Highlights.lua)
    -- so we don't call UnitThreatSituation a second time per refresh.
    if self.frame and self.frame.dfThreatStatus ~= nil then
        return self.frame.dfThreatStatus
    end
    return UnitThreatSituation(self.unit) or 0
end

function LiveSource:GetThreatPercent()
    -- This unit's scaled threat % against its current target (e.g. a raid
    -- member's threat on the boss). The old ("player", unit) form measured the
    -- PLAYER's threat against this unit, which is always nil on friendly frames.
    local _, _, pct = UnitDetailedThreatSituation(self.unit, self.unit .. "target")
    return pct
end

function LiveSource:IsInRange()
    -- frame.dfInRange is populated by the Range module. May be secret —
    -- guard via MidnightSafe.
    if self.frame and self.frame.dfInRange ~= nil then
        return getMS().SafeBoolean(self.frame.dfInRange, true)
    end
    -- Fallback: direct API call (also potentially secret)
    return getMS().SafeBoolean(UnitInRange(self.unit), true)
end

function DataSource.Live(frame)
    local instance = setmetatable({}, LiveSource)
    instance.frame = frame
    instance.unit = frame and frame.unit or nil
    return instance
end

-- ============================================================
-- TEST FACTORY
-- Reads per-unit simulated data (DF:GetTestUnitData) so TD text renders on
-- /df test frames with values that vary per frame. Crucially, status text and
-- range text come from each unit's own test data, so "Dead" / "OOR" only show
-- on the units actually simulated in those states (no overlapping text).
-- ============================================================

local TestSource = {}
TestSource.__index = TestSource

local function tdata(self) return self.data or {} end

-- Health as 0-1. While the "Animate Health" test demo is running, the bar
-- follows frame.testAnimatedHealth — use it so TD health text tracks the
-- animation. Otherwise fall back to the static simulated value.
local function animHP01(self)
    local f = self.frame
    if f and f.testAnimatedHealth ~= nil and DF.TestData and DF.TestData.animationTimer then
        return f.testAnimatedHealth
    end
    return tdata(self).healthPercent or 0
end

function TestSource:GetName() return tdata(self).name or "" end
function TestSource:GetClassToken() return tdata(self).class end
function TestSource:GetClassLocalized()
    local c = tdata(self).class
    if not c then return "" end
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[c]) or c
end
function TestSource:GetGroupNumber()
    if self.isRaid and self.index then return math.ceil(self.index / 5) end
    return nil
end
function TestSource:GetLevel() return tdata(self).level or UnitLevel("player") or 80 end
function TestSource:GetRace() return tdata(self).race or "" end
function TestSource:GetFaction() return tdata(self).faction or "" end

function TestSource:GetHPMax() return tdata(self).maxHealth or 0 end
function TestSource:GetHPCurrent() return math.floor(animHP01(self) * (tdata(self).maxHealth or 0)) end
function TestSource:GetHPPercent() return animHP01(self) * 100 end
function TestSource:GetHPDeficit()
    local maxH = tdata(self).maxHealth or 0
    return maxH - math.floor(animHP01(self) * maxH)
end
function TestSource:GetHPMaxReductionPct() return tdata(self).reducedMaxPct or 0 end

function TestSource:GetPowerCurrent()
    local d = tdata(self)
    return math.floor((d.powerPercent or 0) * (d.maxHealth or 100000))
end
function TestSource:GetPowerPercent() return (tdata(self).powerPercent or 0) * 100 end
function TestSource:GetPowerDeficit()
    local d = tdata(self)
    local maxP = d.maxHealth or 100000
    return maxP - math.floor((d.powerPercent or 0) * maxP)
end
function TestSource:GetPowerTypeString() return _G["POWER_TYPE_MANA"] or "Mana" end

function TestSource:GetAbsorbAmount()
    local d = tdata(self); return (d.absorbPercent or 0) * (d.maxHealth or 0)
end
function TestSource:GetHealAbsorbAmount()
    local d = tdata(self); return (d.healAbsorbPercent or 0) * (d.maxHealth or 0)
end
function TestSource:GetIncomingHealTotal()
    local d = tdata(self); return (d.healPredictionPercent or 0) * (d.maxHealth or 0)
end
function TestSource:GetIncomingHealFromPlayer() return self:GetIncomingHealTotal() end

-- Status comes straight from this unit's simulated state. Test data only sets
-- status = "Dead" (on a few indices); offline/feign/ghost aren't simulated.
function TestSource:IsDead() return tdata(self).status == "Dead" end
function TestSource:IsGhost() return tdata(self).status == "Ghost" end
function TestSource:IsConnected() return tdata(self).status ~= "Offline" end
function TestSource:IsFeignDeath() return tdata(self).status == "FD" end
function TestSource:GetAggroFlag() return 0 end          -- threat not simulated in test
function TestSource:GetThreatPercent() return nil end
function TestSource:IsInRange() return not tdata(self).outOfRange end

function DataSource.Test(frame)
    local instance = setmetatable({}, TestSource)
    instance.frame = frame
    if frame and frame.dfIsPinnedTestFrame then
        instance.index = frame.dfTestIndex
        instance.isRaid = false
        instance.isBoss = true
    else
        instance.index = frame and frame.index
        instance.isRaid = frame and frame.isRaidFrame or false
        instance.isBoss = false
    end
    if DF.GetTestUnitData and instance.index ~= nil then
        instance.data = DF:GetTestUnitData(instance.index, instance.isRaid, instance.isBoss)
    end
    return instance
end
