local addonName, DF = ...

-- ============================================================
-- AURA DESIGNER — NATIVE FACTORY BRIDGE (P4.x)
--
-- The 12.1 revival path for the Aura Designer. On live (pre-12.1) clients the
-- legacy AuraDesigner\Engine.lua read-path still drives every indicator; on 12.1
-- the aura-read API is sealed, so that engine renders nothing. This bridge rebuilds
-- AD indicators on the Blizzard-driven container system (DF.AuraContainer) instead:
-- identity comes from the STATIC per-spec spell-ID whitelist (Config.SpellIDs), and
-- Blizzard drives each slot's secret show/hide — we only attach art. Zero secret reads.
--
-- SCOPE (this file, P4.0 scaffold + P4.1 first slice): gates, identity->includeSpellIDs,
-- and the HEALTH-BAR TINT indicator only. P4.2-P4.7 extend SyncFrame to the rest of the
-- indicator family; the legacy engine stays fully intact behind DF:UseFactoryForAD.
--
-- COMBAT / SECRET obligations (delegated to the DF.AuraContainer handle, the #205-proven
-- path): containers are created/enabled OUT of combat and deferred to PLAYER_REGEN_ENABLED
-- in lockdown (Create/_deferRebuild, Rebuild/_deferRebuild, ApplyStyle/_pendingRestyle);
-- SetEnabled runs LAST; identity is static config, never a live aura's spellId/duration/
-- applications/dispelName. SyncFrame's own per-tick work is a cheap sig-compare table walk
-- and only touches a handle on an actual config change (build-once-leave-it).
-- ============================================================

local pairs, ipairs, type = pairs, ipairs, type
local tostring, tconcat, tsort = tostring, table.concat, table.sort
local slower = string.lower
local wipe = wipe

DF.AuraDesigner = DF.AuraDesigner or {}
DF.AuraDesigner.Factory = DF.AuraDesigner.Factory or {}
local Factory = DF.AuraDesigner.Factory

local DBG = "AD"

-- ============================================================
-- GATES  (mirror Features/Auras.lua UseFactoryForBuffs / FactoryOwnsBuffRow)
-- ============================================================

-- Render gate: is the native AD path active for this frame right now? Hard-gated to
-- 12.1 (IsSupported) and OFF in test mode (the legacy preview painter owns test mode
-- until native test mode ships in P5). Default ON: only an explicit false disables it.
function DF:UseFactoryForAD(frame, db)
    return DF.db and DF.db.adUseFactory ~= false
        and DF.AuraContainer and DF.AuraContainer.IsSupported()
        and not (DF.testMode or DF.raidTestMode)
end

-- GUI-facing predicate: does the factory own AD for this mode's db? Unlike the render
-- gate it must NOT flip in test mode — else "blocked" overlays would wrongly lift while
-- previewing (mirror FactoryOwnsBuffRow). Used by P4.7 GUI when() predicates.
function DF:FactoryOwnsAD(db)
    return (DF.db and DF.db.adUseFactory ~= false
        and DF.AuraContainer and DF.AuraContainer.IsSupported()) or false
end

-- ============================================================
-- IDENTITY  (static spell-ID whitelist -> native includeSpellIDs map)
-- Mirrors the shape of Auras.lua BuildBuffExcludeMap: a { includeSpellIDs = map }
-- table Blizzard evaluates container-side. Built purely from the static per-spec
-- config (SpellIDs + AlternateSpellIDs), never from a live aura. Returns nil when the
-- aura name has no known spell ID (caller then skips — an empty include map would
-- wrongly match EVERY helpful aura).
-- ============================================================
function DF:BuildADIdentityFilters(spec, auraName)
    local specIDs = DF.AuraDesigner.SpellIDs and DF.AuraDesigner.SpellIDs[spec]
    local map
    local primary = specIDs and specIDs[auraName]
    if primary then
        map = map or {}
        map[primary] = true
    end
    local alts = DF.AuraDesigner.AlternateSpellIDs and DF.AuraDesigner.AlternateSpellIDs[spec]
    if alts then
        for altID, primaryName in pairs(alts) do
            if primaryName == auraName then
                map = map or {}
                map[altID] = true
            end
        end
    end
    if not map then return nil end
    return { includeSpellIDs = map }
end

-- ============================================================
-- HELPERS
-- ============================================================

-- Union the includeSpellIDs of a frame-level indicator's triggers into one map.
-- Triggers are AD aura NAMES; no triggers => the owning aura name. Multi-trigger
-- degrades to OR-presence (union) — the accepted 12.1 tradeoff (AND / duration
-- priority need remaining-time reads, unportable; P4.6). Read-free (static config).
local function unionIdentity(spec, auraName, typeCfg)
    local triggers = typeCfg.triggers
    local map
    if triggers and #triggers > 0 then
        for _, name in ipairs(triggers) do
            local f = DF:BuildADIdentityFilters(spec, name)
            if f and f.includeSpellIDs then
                map = map or {}
                for id in pairs(f.includeSpellIDs) do map[id] = true end
            end
        end
    else
        local f = DF:BuildADIdentityFilters(spec, auraName)
        if f then map = f.includeSpellIDs end
    end
    return map
end

-- Stable structural signature of an includeSpellIDs map (sorted IDs). Changing the set
-- is STRUCTURAL (candidateFilters are declared at container build) -> Rebuild, not restyle.
local function includeSig(map)
    if not map then return "" end
    local ids = {}
    for id in pairs(map) do ids[#ids + 1] = id end
    tsort(ids)
    return tconcat(ids, ",")
end

-- Read an AD colour config (array or {r,g,b,a} form) — never a live/secret value.
local function readADColor(c)
    if type(c) ~= "table" then return 1, 1, 1, 1 end
    return c[1] or c.r or 1, c[2] or c.g or 1, c[3] or c.b or 1, c[4] or c.a or 1
end

-- Health-bar overlay alpha per mode — the exact semantics of Indicators:ApplyHealthBar
-- (Indicators.lua:1325-1329), read from CONFIG only:
--   replace: overlay opacity = the colour picker's alpha.
--   tint:    overlay opacity = blend slider x colour alpha (so the bar colour shows through).
-- NOTE: this port renders BOTH modes as a whole-bar overlay tint child of the slot; the
-- legacy tint's current-health tracking (tintWholeBar=false) is not expressible read-free
-- on 12.1 — a documented divergence (see the return message / reviewer notes).
local function healthbarBlend(mode, blendCfg, a)
    if mode == "replace" then return a end
    return (blendCfg or 0.5) * a
end

-- Build the overlay container config for one health-bar indicator. mode="overlay":
-- the slot covers frame.healthBar and its tint texture (child of the slot) inherits the
-- slot's secret visibility; DF.AuraContainer handles SetEnabled-last + combat deferral.
-- frameLevelOffset=1 matches the legacy tint overlay (healthBar level + 1, Indicators.lua:1299).
local function buildHealthbarConfig(frame, map, r, g, b, blend)
    return {
        unit = frame.unit,
        mode = "overlay",
        -- Buff-only for now: the AD spell-ID whitelist (Config.SpellIDs) carries no
        -- buff/debuff classification and every configured entry is a helpful aura. A
        -- harmful spell-ID map is inert on friendly party/raid frames anyway (the assist
        -- gate), so harmful triggers on enemy/arena frames are deferred to a later pass.
        filter = "HELPFUL",
        candidateFilters = { includeSpellIDs = map },
        enabled = true,
        frameLevelOffset = 1,
        style = { overlay = { tintColor = { r, g, b, blend } } },
    }
end

-- Reused per-call scratch (single-threaded; wiped each SyncFrame) so the desired-set
-- diff allocates nothing per tick.
local desiredScratch = {}

-- ============================================================
-- PER-FRAME SYNC  (P4.1 — health-bar tint only)
-- Reads the CONFIGURED health-bar indicators in adDB.auras[spec] (never a live aura
-- list), picks the SINGLE highest-priority one (legacy priority-picks; two overlays
-- would double-darken the bar), and stands up / restyles / tears it down.
-- ============================================================
function Factory:SyncFrame(frame)
    if not frame or not frame.unit then return end
    if not (DF.AuraContainer and DF.AuraContainer.IsSupported()) then return end

    local adDB = DF.ResolveAuraDesigner and DF:ResolveAuraDesigner(frame)
    if not adDB then return end

    -- The factory owns AD here, so Engine:UpdateFrame never runs and never maintains the
    -- buff-bar dedup set. Clear any set left populated by a prior legacy run so it can't
    -- wrongly hide real buffs in the buff row. (Cross-group dedup itself is the accepted
    -- decision-3 gap — we just don't leave a stale set behind.)
    if frame.dfAD_activeInstanceIDs then wipe(frame.dfAD_activeInstanceIDs) end

    local Engine = DF.AuraDesigner.Engine
    local spec = Engine and Engine.ResolveSpec and Engine:ResolveSpec(adDB)
    if not spec then
        self:ClearFrame(frame)
        return
    end

    -- Same lazy migrations UpdateFrame runs, so adDB.auras[spec] is in the shape we read.
    -- Priorities included because we now honour auraCfg.priority for the winner pick
    -- (mirror Engine:UpdateFrame, Engine.lua:391-401). Border-key fold is left for P4.2.
    if (not adDB._specScopedV1 or not adDB._specScopedV2) and DF.MigrateAuraDesignerSpecScope then
        DF.MigrateAuraDesignerSpecScope(adDB)
    end
    if DF.MigrateAuraDesignerInstancesLazy then DF.MigrateAuraDesignerInstancesLazy(adDB) end
    if DF.MigrateAuraDesignerPrioritiesLazy then DF.MigrateAuraDesignerPrioritiesLazy(adDB) end

    local healthBar = frame.healthBar
    if not healthBar then return end

    local store = frame.dfADFactory
    if not store then store = {}; frame.dfADFactory = store end
    local hb = store.healthbar
    if not hb then hb = {}; store.healthbar = hb end

    local specAuras = adDB.auras and adDB.auras[spec]

    -- Pick the single highest-priority configured health-bar indicator. priority is
    -- static config (Engine.lua:502, default 5); ties broken by aura name for stability
    -- (deterministic winner across ticks — no flapping). Read-free.
    local bestName, bestCfg, bestMap, bestPrio
    if specAuras then
        for auraName, auraCfg in pairs(specAuras) do
            local typeCfg = (type(auraCfg) == "table") and auraCfg.healthbar
            if typeCfg and typeCfg.color then
                local map = unionIdentity(spec, auraName, typeCfg)
                if map then
                    local prio = auraCfg.priority or 5
                    if (not bestName)
                        or prio > bestPrio
                        or (prio == bestPrio and auraName < bestName) then
                        bestName, bestCfg, bestMap, bestPrio = auraName, typeCfg, map, prio
                    end
                end
            end
        end
    end

    local desired = desiredScratch
    wipe(desired)

    if bestName then
        desired[bestName] = true

        local r, g, b, a = readADColor(bestCfg.color)
        local mode = slower(bestCfg.mode or "replace")
        local blend = healthbarBlend(mode, bestCfg.blend, a)

        local structSig = includeSig(bestMap)
        -- Cosmetic sig: colour + resolved alpha. A change here is an ApplyStyle (in-place
        -- tint recolour), NOT a rebuild — only the identity set is structural.
        local coSig = tconcat({ tostring(r), tostring(g), tostring(b), tostring(blend) }, "|")

        local entry = hb[bestName]
        if not entry then
            local handle = DF.AuraContainer:Create(healthBar, buildHealthbarConfig(frame, bestMap, r, g, b, blend))
            if handle then
                hb[bestName] = { handle = handle, structSig = structSig, coSig = coSig }
            end
        elseif entry.structSig ~= structSig then
            entry.structSig = structSig
            entry.coSig = coSig
            entry.handle:Rebuild(buildHealthbarConfig(frame, bestMap, r, g, b, blend))
        elseif entry.coSig ~= coSig then
            entry.coSig = coSig
            entry.handle:ApplyStyle({ overlay = { tintColor = { r, g, b, blend } } })
        end
    end

    -- Tear down every container that is not the current winner (winner changed, aura
    -- de-configured, or health-bar indicator removed).
    for auraName, entry in pairs(hb) do
        if not desired[auraName] then
            if entry.handle then entry.handle:Destroy() end
            hb[auraName] = nil
        end
    end
end

-- ============================================================
-- TEARDOWN  (hung off the AD clear path — Engine:ClearFrame calls this)
-- Destroy is combat-safe (hides the plain anchor now, defers secure teardown to regen).
-- ============================================================
function Factory:ClearFrame(frame)
    local store = frame and frame.dfADFactory
    if not store then return end
    local hb = store.healthbar
    if hb then
        for auraName, entry in pairs(hb) do
            if entry.handle then entry.handle:Destroy() end
            hb[auraName] = nil
        end
    end
end

DF:Debug(DBG, "Factory (native AD bridge) loaded")
