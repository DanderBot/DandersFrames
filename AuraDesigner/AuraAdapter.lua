local addonName, DF = ...

-- ============================================================
-- AURA DESIGNER - DATA SOURCE ADAPTER
-- Abstraction layer between the Aura Designer and the aura data
-- source (currently HARF). This is the ONLY file that knows about
-- the external data provider.
-- ============================================================

local pairs, ipairs, type = pairs, ipairs, type

DF.AuraDesigner = DF.AuraDesigner or {}

local AuraAdapter = {}
DF.AuraDesigner.Adapter = AuraAdapter

-- ============================================================
-- DATA SOURCE DETECTION
-- ============================================================

-- Returns true if a compatible data source (HARF) is available
function AuraAdapter:IsAvailable()
    return AdvancedRaidFramesAPI ~= nil
end

-- Returns a display name for the current data source (shown in the UI)
function AuraAdapter:GetSourceName()
    if self:IsAvailable() then
        return "Harrek's Advanced Raid Frames"
    end
    return nil
end

-- ============================================================
-- SPEC / AURA QUERIES (stub — uses local data)
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

-- Returns the spec key for the current player, or nil if not a supported spec
function AuraAdapter:GetPlayerSpec()
    local _, englishClass = UnitClass("player")
    local specIndex = GetSpecialization and GetSpecialization() or nil
    if not englishClass or not specIndex then return nil end

    local key = englishClass .. "_" .. specIndex
    return DF.AuraDesigner.SpecMap[key]
end

-- ============================================================
-- RUNTIME DATA (stubs — will be implemented with real HARF wiring)
-- ============================================================

-- Returns a table of currently active auras for a unit
-- Format: { [auraName] = auraData, ... }
function AuraAdapter:GetUnitAuras(unit)
    -- Stub: no live data yet
    return {}
end

-- Registers a callback for when a unit's auras change
function AuraAdapter:RegisterCallback(owner, callback)
    -- Stub: will wire to HARF callbacks
end

function AuraAdapter:UnregisterCallback(owner)
    -- Stub
end

-- ============================================================
-- UTILITY: Check if Aura Designer is enabled for a frame
-- ============================================================

function DF:IsAuraDesignerEnabled(frame)
    local frameDB = frame and DF.GetFrameDB and DF:GetFrameDB(frame)
    if frameDB and frameDB.auraDesigner then
        return frameDB.auraDesigner.enabled
    end
    return false
end
