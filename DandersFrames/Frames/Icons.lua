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
    if not db.defensiveIconEnabled then
        if frame.defensiveFactory then
            frame.defensiveFactory:GetFrame():Hide()
            frame.dfDefFactoryShown = false   -- keep DriveDefensiveFactory's shown-cache coherent
        end
        return
    end

    -- Check if unit exists
    if not UnitExists(unit) then
        if frame.defensiveFactory then
            frame.defensiveFactory:GetFrame():Hide()
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
        frame.defensiveFactory:GetFrame():Hide()
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

-- Update auras on all frames (used when entering/leaving combat)
function DF:UpdateAllAuras()
    local function updateFrame(frame)
        if frame and frame:IsShown() then
            DF:UpdateAuras(frame)
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
    
    -- Pinned frames
    if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.headers then
        for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
            local header = DF.PinnedFrames.headers[setIndex]
            if header then
                for i = 1, 40 do
                    local child = header:GetAttribute("child" .. i)
                    if child then
                        updateFrame(child)
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
                    updateFrame(frames[i])
                end
            end
        end
    end
end

