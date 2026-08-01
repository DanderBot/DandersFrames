local addonName, DF = ...

-- ============================================================
-- AURA DESIGNER - ENGINE
-- Runtime loop that reads per-aura config, queries the adapter
-- for active auras, and dispatches to indicator renderers.
--
-- Called from the frame update cycle (UpdateAuras) when the
-- Aura Designer is enabled for a frame's mode.
-- ============================================================

local pairs, ipairs, type = pairs, ipairs, type
local wipe = table.wipe



DF.AuraDesigner = DF.AuraDesigner or {}

local Engine = {}
DF.AuraDesigner.Engine = Engine

local Adapter   -- Set during init
local SoundEngine -- Set during init (AuraDesigner/SoundEngine.lua)

-- ============================================================
-- SPEC RESOLUTION
-- ============================================================

function Engine:ResolveSpec(adDB)
    if adDB.spec == "auto" then
        if not Adapter then
            Adapter = DF.AuraDesigner.Adapter
        end
        if not Adapter then return nil end
        return Adapter:GetPlayerSpec()
    end
    return adDB.spec
end

-- ============================================================
-- HIDE ALL INDICATORS
-- Called when Aura Designer is disabled or unit doesn't exist.
-- ============================================================

function Engine:ClearFrame(frame)
    -- Tear down any native-factory AD containers (12.1 path) hung off this frame.
    if DF.AuraDesigner.Factory then
        DF.AuraDesigner.Factory:ClearFrame(frame)
    end
    -- Stop sound engine when AD is disabled
    if not SoundEngine then
        SoundEngine = DF.AuraDesigner.SoundEngine
    end
    if SoundEngine then
        SoundEngine:StopAll()
    end
    -- Clear active instance IDs so buff bar dedup doesn't stale-filter
    if frame.dfAD_activeInstanceIDs then
        wipe(frame.dfAD_activeInstanceIDs)
    end
end

-- ============================================================
-- FORCE REFRESH ALL AD-ENABLED FRAMES
-- Re-runs UpdateFrame on every visible AD frame so changed
-- global defaults (fonts, sizes, etc.) take effect immediately.
-- ============================================================

function Engine:ForceRefreshAllFrames()
    local Factory = DF.AuraDesigner and DF.AuraDesigner.Factory
    local function TryUpdate(frame)
        if not frame then return end
        if DF:IsAuraDesignerEnabled(frame) then
            -- Live 12.1 path: re-sync the factory containers immediately so an
            -- editor change applies now, not one aura event late.
            if frame:IsVisible() and Factory and DF.UseFactoryForAD
                and DF:UseFactoryForAD(frame, DF:GetFrameDB(frame)) then
                Factory:SyncFrame(frame)
            end
        else
            -- AD is OFF for this frame's mode (toggled off, or a profile swap to
            -- an AD-off profile) -- tear down any leftover indicators so they
            -- don't linger on screen until the next /reload.
            Engine:ClearFrame(frame)
        end
    end

    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(TryUpdate)
    end
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(TryUpdate)
    end
    if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.headers then
        for setIndex = 1, 2 do
            local header = DF.PinnedFrames.headers[setIndex]
            if header and header:IsShown() then
                for i = 1, 40 do
                    local child = header:GetAttribute("child" .. i)
                    if child then TryUpdate(child) end
                end
            end
        end
    end

    -- The native factory buff row derives its Aura-Designer dedup set from the AD
    -- config at build time, so an AD config change must re-drive the buff row for
    -- the derived exclusion to follow (sig-gated, cheap when unchanged).
    if DF.InvalidateAuraLayout then
        DF:InvalidateAuraLayout()
    end

    -- Refresh the test previews too when the editor is used with test mode open.
    if (DF.testMode or DF.raidTestMode) and DF.UpdateAllTestAuraDesigner then
        DF:UpdateAllTestAuraDesigner()
    end
end
