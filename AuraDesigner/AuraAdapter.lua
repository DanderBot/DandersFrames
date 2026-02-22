local addonName, DF = ...

-- ============================================================
-- AURA DESIGNER - DATA SOURCE ADAPTER
-- Abstraction layer between the Aura Designer and the aura data
-- source. This is the ONLY file that knows about the external
-- data provider (currently Harrek's Advanced Raid Frames).
--
-- Any future provider must implement:
--   :IsAvailable()              → boolean
--   :GetSourceName()            → string
--   :GetUnitAuras(unit)         → { [auraName] = normalizedData }
--   :RegisterCallback(owner, cb)
--   :UnregisterCallback(owner)
--
-- Normalized aura data format:
--   {
--     spellId        = number,   -- spell ID
--     icon           = number,   -- texture ID
--     duration       = number,   -- total duration (0 = permanent)
--     expirationTime = number,   -- GetTime()-based expiry
--     stacks         = number,   -- stack/application count
--     caster         = string,   -- who applied it
--     auraInstanceID = number,   -- unique instance ID for C_UnitAuras API
--   }
-- ============================================================

local pairs, ipairs, type = pairs, ipairs, type
local GetTime = GetTime
local issecretvalue = issecretvalue or function() return false end
local GetAuraDataByAuraInstanceID = C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID

DF.AuraDesigner = DF.AuraDesigner or {}

local AuraAdapter = {}
DF.AuraDesigner.Adapter = AuraAdapter

-- ============================================================
-- PROVIDER ABSTRACTION
-- The adapter auto-selects the best available provider:
--   1. Harrek's Advanced Raid Frames (if installed)
--   2. Fallback: direct C_UnitAuras scanning
-- ============================================================

local activeProvider = nil  -- Set during initialization

-- ============================================================
-- HARREK'S PROVIDER
-- Uses AdvancedRaidFramesAPI for fast aura presence checks,
-- then enriches with C_UnitAuras for duration/stacks/icon.
-- ============================================================

local HarrekProvider = {}

function HarrekProvider:IsAvailable()
    return AdvancedRaidFramesAPI ~= nil
end

function HarrekProvider:GetSourceName()
    return "Harrek's Advanced Raid Frames"
end

function HarrekProvider:GetUnitAuras(unit, spec)
    local API = AdvancedRaidFramesAPI
    if not API then return {} end

    local spellIDs = DF.AuraDesigner.SpellIDs[spec]
    if not spellIDs then return {} end

    local result = {}
    for _, auraInfo in ipairs(DF.AuraDesigner.TrackableAuras[spec] or {}) do
        local auraName = auraInfo.name
        -- HARF tracks this aura — check if it's active on the unit
        local harfData = API.GetUnitAura(unit, auraName)
        if harfData then
            -- Aura is active — enrich with C_UnitAuras data
            local spellId = spellIDs[auraName]
            local entry = {
                spellId = spellId,
                icon = nil,
                duration = 0,
                expirationTime = 0,
                stacks = 0,
                caster = nil,
            }
            -- Enrich from Blizzard API
            -- First try BlizzardAuraCache (secret-safe: uses auraInstanceIDs)
            local enriched = false
            local blizzCache = DF.BlizzardAuraCache and DF.BlizzardAuraCache[unit]
            if blizzCache and spellId then
                local sources = { blizzCache.buffs, blizzCache.debuffs }
                for _, sourceSet in ipairs(sources) do
                    if sourceSet and not enriched then
                        for auraInstanceID in pairs(sourceSet) do
                            if not enriched then
                                local ad = GetAuraDataByAuraInstanceID and GetAuraDataByAuraInstanceID(unit, auraInstanceID)
                                if ad then
                                    local sid = ad.spellId
                                    if sid and not issecretvalue(sid) and sid == spellId then
                                        entry.icon = ad.icon
                                        entry.duration = ad.duration
                                        entry.expirationTime = ad.expirationTime
                                        entry.stacks = ad.applications
                                        entry.caster = ad.sourceUnit
                                        entry.auraInstanceID = auraInstanceID
                                        enriched = true
                                    end
                                end
                            end
                        end
                    end
                end
            end
            -- Fallback: try ForEachAura with pcall protection (may fail with secret values in combat)
            if not enriched and spellId then
                pcall(function()
                    AuraUtil.ForEachAura(unit, "HELPFUL", nil, function(auraData)
                        if auraData.spellId == spellId then
                            entry.icon = auraData.icon
                            entry.duration = auraData.duration
                            entry.expirationTime = auraData.expirationTime
                            entry.stacks = auraData.applications
                            entry.caster = auraData.sourceUnit
                            entry.auraInstanceID = auraData.auraInstanceID
                            enriched = true
                            return true
                        end
                    end)
                end)
            end
            -- Fallback icon from C_Spell if enrichment didn't find it
            if not entry.icon and spellId and C_Spell and C_Spell.GetSpellTexture then
                entry.icon = C_Spell.GetSpellTexture(spellId)
            end
            result[auraName] = entry
        end
    end

    return result
end

-- Callback registry for Harrek provider
local harrekCallbacks = {}

function HarrekProvider:RegisterCallback(owner, callback)
    harrekCallbacks[owner] = callback
    -- Wire to HARF's callback system
    if AdvancedRaidFramesAPI and AdvancedRaidFramesAPI.RegisterCallback then
        AdvancedRaidFramesAPI.RegisterCallback(owner, "HARF_UNIT_AURA", function(_, unit, auraData)
            if callback then callback(unit) end
        end)
    end
end

function HarrekProvider:UnregisterCallback(owner)
    harrekCallbacks[owner] = nil
    if AdvancedRaidFramesAPI and AdvancedRaidFramesAPI.UnregisterCallback then
        AdvancedRaidFramesAPI.UnregisterCallback(owner, "HARF_UNIT_AURA")
    end
end

-- ============================================================
-- FALLBACK PROVIDER
-- Uses DF.BlizzardAuraCache (populated by the Blizzard frame
-- hook in Features/Auras.lua) for secret-safe aura queries.
-- Falls back to direct C_UnitAuras scan with pcall protection.
-- ============================================================

local FallbackProvider = {}

function FallbackProvider:IsAvailable()
    return true  -- Always available
end

function FallbackProvider:GetSourceName()
    return "Built-in (BlizzardAuraCache)"
end

-- Build a reverse lookup: spellId → auraName for fast matching
local spellIdLookup = {}  -- { [spec] = { [spellId] = auraName } }

local function GetSpellIdLookup(spec)
    if spellIdLookup[spec] then return spellIdLookup[spec] end
    local lookup = {}
    local ids = DF.AuraDesigner.SpellIDs[spec]
    if ids then
        for auraName, spellId in pairs(ids) do
            lookup[spellId] = auraName
        end
    end
    spellIdLookup[spec] = lookup
    return lookup
end

-- Persistent cache: auraInstanceID → auraName
-- Populated when spellId is non-secret, used in combat when spellId is secret.
-- auraInstanceIDs are monotonically increasing and never reused within a session.
local instanceIdToAuraName = {}  -- { [auraInstanceID] = auraName }

-- Debug throttle for adapter (shares interval with engine)
local adapterDebugLast = 0
local ADAPTER_DEBUG_INTERVAL = 3

function FallbackProvider:GetUnitAuras(unit, spec)
    local lookup = GetSpellIdLookup(spec)  -- { [spellId] = auraName }
    if not lookup or not next(lookup) then return {} end

    local forwardLookup = DF.AuraDesigner.SpellIDs[spec]  -- { [auraName] = spellId }

    local now = GetTime()
    local shouldLog = (now - adapterDebugLast) >= ADAPTER_DEBUG_INTERVAL

    local result = {}
    local scannedCount = 0
    local matchedCount = 0
    local cacheHits = 0

    -- PRIMARY PATH: Use BlizzardAuraCache (secret-safe)
    -- DF.BlizzardAuraCache is populated by the hooksecurefunc on
    -- CompactUnitFrame_UpdateAuras in Features/Auras.lua. It stores
    -- non-secret auraInstanceIDs captured from Blizzard's own frames.
    local blizzCache = DF.BlizzardAuraCache and DF.BlizzardAuraCache[unit]
    if blizzCache then
        local sources = { blizzCache.buffs, blizzCache.debuffs }
        for _, sourceSet in ipairs(sources) do
            if sourceSet then
                for auraInstanceID in pairs(sourceSet) do
                    scannedCount = scannedCount + 1
                    local auraData = GetAuraDataByAuraInstanceID and GetAuraDataByAuraInstanceID(unit, auraInstanceID)
                    if auraData then
                        local auraName = nil

                        -- Try spellId lookup (works when not secret, i.e. out of combat)
                        local sid = auraData.spellId
                        if sid and not issecretvalue(sid) then
                            auraName = lookup[sid]
                            -- Update persistent cache for combat use
                            if auraName then
                                instanceIdToAuraName[auraInstanceID] = auraName
                            end
                        else
                            -- In combat (secret): use cached mapping
                            auraName = instanceIdToAuraName[auraInstanceID]
                            if auraName then cacheHits = cacheHits + 1 end
                        end

                        if auraName then
                            matchedCount = matchedCount + 1
                            result[auraName] = {
                                spellId = forwardLookup and forwardLookup[auraName] or 0,  -- our known non-secret ID
                                icon = auraData.icon,              -- might be secret; OK for SetTexture
                                duration = auraData.duration,       -- might be secret; OK for SetCooldown
                                expirationTime = auraData.expirationTime,  -- might be secret
                                stacks = auraData.applications,     -- might be secret
                                caster = auraData.sourceUnit,
                                auraInstanceID = auraInstanceID,    -- non-secret
                            }
                        end
                    end
                end
            end
        end
    else
        -- FALLBACK PATH: No BlizzardAuraCache (e.g., during early init)
        -- Use direct scan with pcall protection against secret values
        local i = 1
        while true do
            local auraData = C_UnitAuras.GetBuffDataByIndex(unit, i)
            if not auraData then break end
            scannedCount = scannedCount + 1

            -- pcall protects against "table index is secret" in combat
            local ok, auraName = pcall(function()
                return lookup[auraData.spellId]
            end)

            if ok and auraName then
                matchedCount = matchedCount + 1
                -- Build entry with pcall (other fields might also be secret)
                pcall(function()
                    result[auraName] = {
                        spellId = forwardLookup and forwardLookup[auraName] or 0,
                        icon = auraData.icon,
                        duration = auraData.duration,
                        expirationTime = auraData.expirationTime,
                        stacks = auraData.applications,
                        caster = auraData.sourceUnit,
                        auraInstanceID = auraData.auraInstanceID,
                    }
                end)
            end
            i = i + 1
        end
    end

    if shouldLog then
        adapterDebugLast = now
        DF:Debug("AD", "Fallback: unit=%s spec=%s scanned=%d matched=%d cacheHits=%d blizzCache=%s",
            unit, spec, scannedCount, matchedCount, cacheHits,
            blizzCache and "yes" or "no")
    end

    return result
end

-- Fallback uses a simple event frame for UNIT_AURA
local fallbackCallbacks = {}
local fallbackEventFrame

function FallbackProvider:RegisterCallback(owner, callback)
    fallbackCallbacks[owner] = callback
    if not fallbackEventFrame then
        fallbackEventFrame = CreateFrame("Frame")
        fallbackEventFrame:RegisterEvent("UNIT_AURA")
        fallbackEventFrame:SetScript("OnEvent", function(_, _, unit)
            for _, cb in pairs(fallbackCallbacks) do
                cb(unit)
            end
        end)
    end
end

function FallbackProvider:UnregisterCallback(owner)
    fallbackCallbacks[owner] = nil
    -- Clean up event frame if no callbacks remain
    if fallbackEventFrame and not next(fallbackCallbacks) then
        fallbackEventFrame:UnregisterAllEvents()
        fallbackEventFrame = nil
    end
end

-- ============================================================
-- PROVIDER SELECTION
-- ============================================================

local function SelectProvider()
    if HarrekProvider:IsAvailable() then
        activeProvider = HarrekProvider
    else
        activeProvider = FallbackProvider
    end
end

-- ============================================================
-- PUBLIC ADAPTER API
-- These methods delegate to the active provider.
-- ============================================================

-- Returns true if a data source is available
function AuraAdapter:IsAvailable()
    if not activeProvider then SelectProvider() end
    return activeProvider:IsAvailable()
end

-- Returns a display name for the current data source
function AuraAdapter:GetSourceName()
    if not activeProvider then SelectProvider() end
    return activeProvider:GetSourceName()
end

-- ============================================================
-- SPEC / AURA QUERIES (uses local Config data)
-- These are provider-independent — always sourced from
-- DF.AuraDesigner tables in Config.lua.
-- ============================================================

-- Returns a list of supported spec keys
function AuraAdapter:GetSupportedSpecs()
    local specs = {}
    for spec in pairs(DF.AuraDesigner.SpecInfo) do
        specs[#specs + 1] = spec
    end
    return specs
end

-- Returns the display name for a spec key
function AuraAdapter:GetSpecDisplayName(specKey)
    local info = DF.AuraDesigner.SpecInfo[specKey]
    return info and info.display or specKey
end

-- Returns the list of trackable auras for a spec
-- Each entry: { name = "InternalName", display = "Display Name", color = {r,g,b} }
function AuraAdapter:GetTrackableAuras(specKey)
    return DF.AuraDesigner.TrackableAuras[specKey] or {}
end

-- ============================================================
-- PLAYER SPEC DETECTION
-- ============================================================

-- Returns the spec key for the current player, or nil if not supported
function AuraAdapter:GetPlayerSpec()
    local _, englishClass = UnitClass("player")
    local specIndex = GetSpecialization and GetSpecialization() or nil
    if not englishClass or not specIndex then return nil end

    local key = englishClass .. "_" .. specIndex
    return DF.AuraDesigner.SpecMap[key]
end

-- ============================================================
-- RUNTIME DATA
-- Delegates to the active provider for live aura queries.
-- ============================================================

-- Returns a table of currently active tracked auras for a unit
-- Format: { [auraName] = { spellId, icon, duration, expirationTime, stacks, caster } }
function AuraAdapter:GetUnitAuras(unit, spec)
    if not activeProvider then SelectProvider() end
    if not spec then spec = self:GetPlayerSpec() end
    if not spec then return {} end
    return activeProvider:GetUnitAuras(unit, spec)
end

-- Registers a callback for when a unit's auras change
-- callback(unit) is called whenever unit auras may have changed
function AuraAdapter:RegisterCallback(owner, callback)
    if not activeProvider then SelectProvider() end
    activeProvider:RegisterCallback(owner, callback)
end

function AuraAdapter:UnregisterCallback(owner)
    if not activeProvider then SelectProvider() end
    activeProvider:UnregisterCallback(owner)
end

-- Force re-selection of provider (e.g., after addon load order settles)
function AuraAdapter:RefreshProvider()
    activeProvider = nil
    SelectProvider()
end

-- ============================================================
-- UTILITY
-- ============================================================

-- Check if Aura Designer is enabled for a frame
function DF:IsAuraDesignerEnabled(frame)
    local frameDB = frame and DF.GetFrameDB and DF:GetFrameDB(frame)
    if frameDB and frameDB.auraDesigner then
        return frameDB.auraDesigner.enabled
    end
    return false
end
