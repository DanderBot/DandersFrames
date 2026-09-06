local addonName, DF = ...

-- ============================================================
-- FRAMES ICONS MODULE
-- Contains missing buff icons and aura update functions
-- ============================================================

-- Local caching of frequently used globals and WoW API for performance
local GetTime = GetTime
local UnitExists = UnitExists
local issecretvalue = issecretvalue or function() return false end

-- (Removed) a "PERFORMANCE FIX: default colors for UpdateDefensiveBar fallbacks /
-- avoids creating tables on every call" banner introducing no table -- there is no
-- default-colour table anywhere in this file. It advertised an optimisation that is
-- not here, which is worse than silence: the next reader trusts it and stops looking.

-- (Removed) DF:GetRaidBuffIcons + DF.RaidBuffIconCache — a spellID -> icon-texture
-- set built "for fallback filtering (when spellId is secret)". That fallback was
-- never wired: nothing read the cache except /df debug debugraidbuffs, a dump of the
-- thing itself. 12.1 answered the same question from the other end — the native
-- excludeSpellIDs union carries real spell IDs (missingBuffHideFromBar in
-- Features/Auras.lua) — so matching by texture is superseded, not just unused.
-- DF.RaidBuffs itself is very much live; only the icon projection is gone.

function DF:UpdateMissingBuffIcon(frame, forceUpdate)
    if not frame or not frame.unit then return end

    -- MEMORY TEST: enableMissingBuff is folded into UseFactoryForMissingBuff, not
    -- early-returned — returning here would leave the Blizzard-driven strip
    -- standing and the flag would look inert. Falling through reaches the
    -- "factory inactive -> hide the strip" path below.

    -- Use raid DB for raid frames, party DB for party frames
    local db = DF:GetFrameDB(frame)

    -- 12.1 FACTORY SEAM: the read-free layout-push widget (Auras.lua bridge) owns
    -- the feature — the UnitHasBuff scan below reads aura data, which is sealed.
    -- Routing here keeps this function's trigger cadence (aura events + the OOC
    -- timer) driving the widget's NON-aura guards. Legacy body stays for pre-12.1
    -- clients and test mode.
    if DF.UseFactoryForMissingBuff and DF:UseFactoryForMissingBuff(frame, db) then
        DF:DriveMissingBuffFactory(frame, db)
        return
    end
    -- Legacy path active (pre-12.1 / test mode): the factory strip must not linger.
    if frame.missingBuffStrip and frame.dfMissingStripShown then
        frame.missingBuffStrip:Hide()
        frame.dfMissingStripShown = false
    end

    -- 12.1: the layout-push widget above owns the feature. The legacy
    -- UnitHasBuff scan render is gone (sealed aura reads).
end

-- Update missing buff icons for all frames (called on a timer, out of combat only)
function DF:UpdateAllMissingBuffIcons()
    -- Check if in test mode - use test update functions instead
    if DF.testMode or DF.raidTestMode then
        if DF.UpdateAllTestMissingBuff then
            DF:UpdateAllTestMissingBuff()
        end
        return
    end

    -- Throttle updates to avoid spam (0.1 second minimum between updates).
    local now = GetTime()
    if DF.lastMissingBuffUpdate and (now - DF.lastMissingBuffUpdate) < 0.1 then
        return
    end
    DF.lastMissingBuffUpdate = now

    local function updateFrame(frame)
        if frame and frame:IsShown() then
            DF:UpdateMissingBuffIcon(frame)
        end
    end
    
    -- Party frames via iterator
    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(updateFrame)
    end
    
    -- Raid frames via iterator
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(updateFrame)
    end

    -- ☠ AND PINNED — same gap as the defensive sweep below; see its note.
    if DF.IteratePinnedFrames then
        DF.IteratePinnedFrames(updateFrame)
    end
end

-- ========================================
-- DEFENSIVE ICON
-- ========================================

-- Update defensive icon for a single frame
-- Uses Blizzard's CenterDefensiveBuff cache - they decide which defensive to show
-- ============================================================
-- SHARED DEFENSIVE BAR LAYOUT (live + test mode)
-- ============================================================
-- Pure layout math from db alone — no unit reads — so test mode positions
-- through the exact code live uses. Single source: before this, test mode
-- kept its own copy that skipped the pixel-perfect scale fold and the
-- pixel-grid snap (the drift class that caused bug 951).
--
function DF:UpdateDefensiveBar(frame)
    if not frame or not frame.unit then return end

    -- MEMORY TEST: enableDefensive is folded into UseFactoryForDefensive, not
    -- early-returned — see UpdateMissingBuffIcon above for why.

    -- Use raid DB for raid frames, party DB for party frames
    local db = DF:GetFrameDB(frame)
    local unit = frame.unit
    
    -- Check if feature is enabled
    -- ☠ SetIntentShown, never GetFrame():Hide(): the raw hide left the handle's
    -- intent as "shown" and the identity-gate sweep re-showed the disabled icon
    -- with live auras (the "defensive icon comes back while disabled" reports).
    if not db.defensiveIconEnabled then
        if frame.defensiveFactory then
            frame.defensiveFactory:SetIntentShown(false)
            frame.dfDefFactoryShown = false   -- keep DriveDefensiveFactory's shown-cache coherent
        end
        return
    end

    -- Check if unit exists
    if not UnitExists(unit) then
        if frame.defensiveFactory then
            frame.defensiveFactory:SetIntentShown(false)
            frame.dfDefFactoryShown = false
        end
        return
    end

    -- Factory defensive row (12.1): route through DF.AuraContainer when active. The
    -- container self-updates from UNIT_AURA, so there's no per-tick render here.
    if DF:UseFactoryForDefensive(frame, db) then
        DF:DriveDefensiveFactory(frame, db)
        return
    end
    -- A container was built but the factory path is now inactive (test mode / toggle off):
    -- hide it so the legacy render below can't double up.
    if frame.defensiveFactory then
        frame.defensiveFactory:SetIntentShown(false)
        frame.dfDefFactoryShown = false
    end

    -- 12.1: the container path above owns all live rendering. The only way
    -- here is the transient in-combat IsSupported()=false window before the
    -- login warm; render nothing rather than read sealed aura data.
end

-- Update defensive icons for all frames
function DF:UpdateAllDefensiveBars()
    -- Setting changes route through here; bump the shared layout version so the factory
    -- defensive path re-applies on the next update (mirrors the buff callbacks).
    if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
    -- Check if in test mode - use test update functions instead
    if DF.testMode or DF.raidTestMode then
        if DF.UpdateAllTestDefensiveBar then
            DF:UpdateAllTestDefensiveBar()
        end
        return
    end
    
    local function updateFrame(frame)
        if frame and frame:IsShown() then
            DF:UpdateDefensiveBar(frame)
        end
    end
    
    -- Party frames via iterator
    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(updateFrame)
    end
    
    -- Raid frames via iterator
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(updateFrame)
    end

    -- ☠ AND PINNED. This is the fullUpdate for the whole Defensive Icon page (~20 call
    -- sites in the Indicators page), so without it every setting there was inert on pinned
    -- frames until some aura event happened by — which for a quiet unit is minutes, and
    -- mid-fight never. DF:UpdateAllAuras a few lines down has always walked pinned; these
    -- siblings were never given the same treatment. (Audit 2026-08-17.)
    if DF.IteratePinnedFrames then
        DF.IteratePinnedFrames(updateFrame)
    end
end

-- Legacy function for backwards compatibility
function DF:UpdateExternalDefIcon(frame)
    -- Redirect to new defensive bar
    DF:UpdateDefensiveBar(frame)
end

-- ☠ (Removed) DF:UpdateAllExternalDefIcons, a one-line forward to
-- DF:UpdateAllDefensiveBars kept "for backwards compatibility". Nothing called it in
-- either addon; its only other mention was a PROFILED_FUNCTIONS string, which wraps
-- DF[name] and never calls it, so it profiled nothing.
--
-- ⚠ Its SINGULAR sibling above, DF:UpdateExternalDefIcon, is a different matter and
-- stays: that one has seven real call sites.

-- Update auras on all frames (combat transitions and the full profile refresh).
--
-- ☠☠ CHUNKED, and the reason is a HARD FAILURE, not a hitch. Run synchronously this
-- walks every party, raid and pinned frame and rebuilds the whole Aura Designer
-- signature set for each — placedCoSig/placedStructSig per indicator per member group,
-- string-built. On a full raid with a busy Aura Designer profile that is enough for
-- Blizzard's watchdog to fire "script ran too long", and the watchdog does not warn, it
-- ABORTS THE EXECUTION. Field report 2026-08-30, via an auto-profile switch:
--     Factory.lua:890 script ran too long
--     ... SyncFrame -> UpdateAuras -> IterateRaidFrames -> UpdateAllAuras
--         -> FullProfileRefresh -> ApplyRuntimeProfile -> EvaluateAndApply
-- Everything in FullProfileRefresh AFTER this call — the rested indicator, name
-- truncation, the rest of the pass — never ran. A profile switch could half-apply and
-- leave frames stale with nothing to re-drive them.
--
-- ⚠ THE WATCHDOG MEASURES ONE EXECUTION, so splitting the walk across frames removes the
-- failure outright rather than just making it less likely. Same shape as
-- AuraContainer._kickLiveParse (read its header): the work list is SNAPSHOTTED up front
-- because the iterators walk live registries that churn, each frame is RE-VALIDATED at
-- execution time, and a generation token lets a newer call supersede a pending one
-- instead of two walks interleaving.
--
-- ⚠ The caller returns immediately now. That is the point — FullProfileRefresh completes
-- and the aura pass lands over the next few frames. Nothing downstream reads aura state
-- back out of this call; both call sites treat it as fire-and-forget.
local AURA_CHUNK = 8      -- frames refreshed per tick
local updateAllGen = 0

function DF:UpdateAllAuras()
    local work = {}
    local function collect(frame)
        if frame then work[#work + 1] = frame end
    end

    -- Party frames via iterator
    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(collect)
    end

    -- Raid frames via iterator
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(collect)
    end

    -- Pinned frames
    if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.headers then
        for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
            local header = DF.PinnedFrames.headers[setIndex]
            if header then
                for i = 1, 40 do
                    local child = header:GetAttribute("child" .. i)
                    if child then
                        collect(child)
                    end
                end
            end
        end
    end

    -- Also update pinned boss frames
    if DF.PinnedFrames and DF.PinnedFrames.bossFrames then
        for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
            local frames = DF.PinnedFrames.bossFrames[setIndex]
            if frames then
                for i = 1, 8 do
                    collect(frames[i])
                end
            end
        end
    end

    if #work == 0 then return end

    updateAllGen = updateAllGen + 1
    local gen, i = updateAllGen, 0
    local function step()
        -- A newer call has taken over: drop this walk rather than interleave two.
        if gen ~= updateAllGen then return end
        local stop = math.min(i + AURA_CHUNK, #work)
        while i < stop do
            i = i + 1
            local frame = work[i]
            -- ⚠ RE-VALIDATED HERE, not at snapshot time: a frame can be recycled,
            -- hidden or retargeted between chunks, and IsShown was always the gate.
            if frame:IsShown() then
                DF:UpdateAuras(frame)
            end
        end
        if i < #work then C_Timer.After(0, step) end
    end
    -- First chunk runs INLINE, so the common small-group case (a 5-man is one chunk)
    -- behaves exactly as it did before and nothing is deferred that never needed to be.
    step()
end

