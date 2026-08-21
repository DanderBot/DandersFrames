local addonName, DF = ...

-- ============================================================
-- AURA DESIGNER - ENGINE
-- Runtime loop that reads per-aura config, queries the adapter
-- for active auras, and dispatches to indicator renderers.
--
-- Called from the frame update cycle (UpdateAuras) when the
-- Aura Designer is enabled for a frame's mode.
-- ============================================================

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
    -- ☠ THROUGH THE SHARED WALKER, NOT A HAND-ROLLED HEADER LOOP — this walked
    -- PinnedFrames.headers only, so an Aura Designer edit never reached a pinned BOSS
    -- frame, and neither did the AD-off teardown. (Audit 2026-08-17.)
    if DF.IteratePinnedFrames then
        DF.IteratePinnedFrames(TryUpdate)
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

        -- ☠ AND RE-MEASURE INDICATOR INFO, which the line above had just invalidated.
        -- Test mode's Indicator Info caches a rect per element and only rebuilds from
        -- DF:RefreshTestFrames / DF:UpdateRaidTestFrames -- neither of which is on any
        -- Aura Designer path. So every editor action that reaches this function moved,
        -- created or destroyed indicators behind a region list that nobody rebuilt:
        -- switching the designer preset with test mode open left the new preset's
        -- indicators unhoverable until Indicator Info was toggled off and on, and the
        -- elements it had NOT touched kept their marks throughout, which is what made
        -- it read as "only the defensive icon has info" (Krathe, 2026-08-21).
        -- ★ HERE rather than at the ~20 call sites: this is the single chokepoint every
        -- one of them already funnels through, and a fix per site is a fix for the
        -- sites someone happened to look at.
        -- Deferred one tick for the reason the test-mode refresh defers its own call:
        -- the containers were rebuilt on THIS tick and an anchor-derived rect is 0
        -- until the layout settles, so measuring now would find nothing. (The settle
        -- retry would recover it, but starting from a measurable pass is cheaper and
        -- keeps the marks from blinking.)
        if DF.UpdateTestLabels and C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                if DF.UpdateTestLabels then DF:UpdateTestLabels() end
            end)
        end
    end
end
