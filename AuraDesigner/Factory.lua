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
-- SCOPE (this file, P4.0 scaffold + P4.1 + P4.2): gates, identity->includeSpellIDs, and the
-- frame-level indicators that CAN be driven read-free — HEALTH-BAR (filled mirror + flat
-- tint), BACKGROUND tint, and static BORDER. framealpha / nametext / healthtext are 12.1
-- casualties (see NOTES at
-- the file foot). Placed indicators (icon/square/bar) are P4.3-P4.4. The legacy engine stays
-- fully intact behind DF:UseFactoryForAD.
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
-- Used by the FLAT whole-bar tint path and to derive the tint-mode mirror's alpha. The
-- filled-mirror path now expresses current-health-fill tracking read-free (a duplicate
-- StatusBar fed the secret percent), so tintWholeBar=false is no longer a divergence.
local function healthbarBlend(mode, blendCfg, a)
    if mode == "replace" then return a end
    return (blendCfg or 0.5) * a
end

-- Build an OVERLAY-TINT container config (health-bar tint, background tint). mode="overlay":
-- the slot covers the host region and its tint texture (child of the slot) inherits the
-- slot's secret visibility; DF.AuraContainer handles SetEnabled-last + combat deferral.
-- levelOffset is added on top of the caller's anchor level; the tint texture then lands a
-- further +2 above (anchor -> container -> slot nesting). Callers pick the anchor + offset so
-- the tint seats correctly: health-bar tint hosts on frame.healthBar with offset 1 (tint above
-- the real fill); background tint hosts on a frame parked at healthBar-3 with offset 0 (tint at
-- healthBar-1 — above frame.background, below every bar). See the two call sites for the math.
local function buildOverlayTintConfig(unit, map, r, g, b, blend, levelOffset)
    return {
        unit = unit,
        mode = "overlay",
        -- Buff-only for now: the AD spell-ID whitelist (Config.SpellIDs) carries no
        -- buff/debuff classification and every configured entry is a helpful aura. A
        -- harmful spell-ID map is inert on friendly party/raid frames anyway (the assist
        -- gate), so harmful triggers on enemy/arena frames are deferred to a later pass.
        filter = "HELPFUL",
        candidateFilters = { includeSpellIDs = map },
        enabled = true,
        frameLevelOffset = levelOffset,
        style = { overlay = { tintColor = { r, g, b, blend } } },
    }
end

-- Build a FILLED HEALTH-MIRROR container config (health-bar indicator, replace/tint fill).
-- The slot hosts a duplicate StatusBar fed the unit's secret health percent render-side, so
-- it mirrors the real bar's fill+texture+motion (fixing the flat whole-bar tint patch). Level
-- offset 1 = healthBar level + 1 (above the real fill, below the +2 power / content overlay),
-- exactly where the legacy tint sat (Indicators.lua:1299). Colour/texture/alpha are static
-- config; the onBar callback hands the live bar back so SyncFrame can stash it for feeding.
local function buildHealthMirrorConfig(unit, map, r, g, b, alpha, texture, onBar)
    return {
        unit = unit,
        mode = "overlay",
        filter = "HELPFUL",
        candidateFilters = { includeSpellIDs = map },
        enabled = true,
        frameLevelOffset = 1,
        style = { overlay = { healthMirror = { texture = texture, color = { r, g, b }, alpha = alpha, onBar = onBar } } },
    }
end

-- Build a whole-frame BORDER container config. mode="overlay": the slot covers the unit
-- frame; DF.Border (secretRect, static art only — animations are forbidden on native
-- buttons and stripped engine-side) renders as a child of the slot and inherits the slot's
-- secret visibility. levelOffset 10 lifts the ring above the class border (frame+10 inside
-- the slot) so it reads as an AD border, mirroring the legacy draw-above default
-- (Indicators.lua:1145-1147). Z-order polish is a P4.7 concern.
local function buildBorderConfig(unit, map, spec)
    return {
        unit = unit,
        mode = "overlay",
        filter = "HELPFUL",
        candidateFilters = { includeSpellIDs = map },
        enabled = true,
        frameLevelOffset = 10,
        style = { border = { spec = spec } },
    }
end

-- Resolve the DF.Border spec for an AD border indicator from its CONFIG block (never a
-- live aura), mirroring Indicators:ApplyBorderToOverlay: canonical keys via BuildSpec (the
-- border-key fold ran in SyncFrame), black default colour. Returns nil when the border
-- resolves disabled (ShowBorder=false) — the caller then renders no container. Animations
-- are dropped: frame-level expiring border art reads remaining time (unportable, P4.7),
-- and the container engine strips spec.animation on native buttons anyway.
local function buildBorderSpec(frame, borderCfg)
    if not DF.Border then return nil end
    local spec = DF.Border:BuildSpec(borderCfg, "")
    if not spec or spec.enabled == false then return nil end
    if not spec.color then spec.color = { r = 0, g = 0, b = 0, a = 1 } end
    spec.pixelPerfect = (DF:GetFrameDB(frame) or {}).pixelPerfect
    spec.animation = nil
    -- KNOWN DEGRADATION (GRADIENT → solid): the AuraContainer overlay-border builder creates
    -- the DF.Border with solidOnly=true (AuraContainer.lua:298), because container slots are
    -- anchored by Blizzard's flow layout with SECRET / unresolved rects and gradient rendering
    -- needs a resolved rect to compute its direction+extent (the same rect problem that forces
    -- the secretRect anchor-only path — see AuraContainer.lua:291-294). So a user's GRADIENT
    -- border style renders as a SOLID ring here (texture styles still render). Threading
    -- solidOnly=false was deliberately NOT done: that flag lives on the SHARED slot-border
    -- builder used by the #205 buff/debuff rows too, and enabling gradients on a secret-anchored
    -- rect is unverified (likely broken), which would be worse than a clean solid. → P4.7 must
    -- FROST / API-limit-mark the gradient border-style control for factory-owned AD.
    return spec
end

-- Order-stable cosmetic signature of a DF.Border spec (scalars + one-level subtables).
-- Field-name-agnostic so it survives BuildSpec schema tweaks; any change → ApplyStyle
-- (in-place restyle), never a rebuild (only the identity set is structural).
local function subSig(t)
    local keys = {}
    for kk in pairs(t) do keys[#keys + 1] = kk end
    tsort(keys)
    local parts = {}
    for _, kk in ipairs(keys) do
        local v = t[kk]
        local tv = type(v)
        if tv ~= "table" and tv ~= "function" and tv ~= "userdata" and tv ~= "thread" then
            parts[#parts + 1] = tostring(kk) .. "=" .. tostring(v)
        end
    end
    return tconcat(parts, ",")
end
local function borderSpecSig(spec)
    if type(spec) ~= "table" then return "" end
    local keys = {}
    for kk in pairs(spec) do keys[#keys + 1] = kk end
    tsort(keys)
    local parts = {}
    for _, kk in ipairs(keys) do
        local v = spec[kk]
        local tv = type(v)
        if tv == "table" then
            parts[#parts + 1] = tostring(kk) .. "={" .. subSig(v) .. "}"
        elseif tv ~= "function" and tv ~= "userdata" and tv ~= "thread" then
            parts[#parts + 1] = tostring(kk) .. "=" .. tostring(v)
        end
    end
    return tconcat(parts, "|")
end

-- Pick the single highest-priority configured indicator of `typeKey` across all configured
-- auras for this spec. Frame-level effects each target ONE region, so stacking two of the
-- same type conflicts (double-tint / double-border) — one winner per type, exactly like the
-- health bar. priority is static config (Engine.lua:502, default 5); ties broken by aura
-- name for a deterministic, non-flapping winner. `validate(typeCfg)` gates which blocks
-- count (e.g. healthbar/background need .color, border must be enabled). Read-free.
local function pickWinner(spec, specAuras, typeKey, validate)
    if not specAuras then return nil end
    local bestName, bestCfg, bestMap, bestPrio
    for auraName, auraCfg in pairs(specAuras) do
        local typeCfg = (type(auraCfg) == "table") and auraCfg[typeKey]
        if typeCfg and (not validate or validate(typeCfg)) then
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
    return bestName, bestCfg, bestMap, bestPrio
end

-- Tear down every container in a per-type store that is not the current winner (winner
-- changed, aura de-configured, or the indicator was removed). Destroy is combat-safe.
local function teardownExcept(store, keepName)
    for auraName, entry in pairs(store) do
        if auraName ~= keepName then
            if entry.handle then entry.handle:Destroy() end
            store[auraName] = nil
        end
    end
end

-- Release the background anchor frame (the plain non-secure host for the background-tint
-- container). WoW frames can't be destroyed, so hide + unanchor + forget the ref; a fresh
-- one is created on the next background config. Call ONLY after the background containers
-- are torn down (their h.frame parents to this anchor). Hide is combat-safe.
local function releaseBgAnchor(store)
    local a = store.bgAnchor
    if a then
        a:Hide()
        a:ClearAllPoints()
        store.bgAnchor = nil
    end
end

-- ============================================================
-- PER-FRAME SYNC  (P4.1 health-bar + P4.2 frame-level family)
-- Reads the CONFIGURED indicators in adDB.auras[spec] (never a live aura list). Each
-- frame-level effect targets ONE region, so per type we pick the SINGLE highest-priority
-- winner (stacking two of a type conflicts) and stand it up / restyle / tear it down on
-- its own DF.AuraContainer. Types ported here: healthbar, background, border. framealpha /
-- nametext / healthtext are 12.1 casualties (see the notes below + the P4.7 overlay list).
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
    -- Priorities: winner pick honours auraCfg.priority. Border-key fold: the border winner
    -- reads canonical border keys via DF.Border:BuildSpec (mirror Engine.lua:391-401).
    if (not adDB._specScopedV1 or not adDB._specScopedV2) and DF.MigrateAuraDesignerSpecScope then
        DF.MigrateAuraDesignerSpecScope(adDB)
    end
    if DF.MigrateAuraDesignerInstancesLazy then DF.MigrateAuraDesignerInstancesLazy(adDB) end
    if DF.MigrateAuraDesignerBorderKeysLazy then DF.MigrateAuraDesignerBorderKeysLazy(adDB) end
    if DF.MigrateAuraDesignerPrioritiesLazy then DF.MigrateAuraDesignerPrioritiesLazy(adDB) end

    local store = frame.dfADFactory
    if not store then store = {}; frame.dfADFactory = store end

    local specAuras = adDB.auras and adDB.auras[spec]

    -- ---- HEALTH BAR (child of frame.healthBar, overlay) -----------------------------
    -- Two render paths, chosen by config:
    --   * FILLED MIRROR (replace, or tint without "Tint Entire Bar") — a duplicate StatusBar
    --     fed the secret health percent render-side, matching the real bar's fill/texture/
    --     motion. replace = opaque cover (alpha 1); tint = fill-matched tint (alpha = blend).
    --   * FLAT WHOLE-BAR TINT (tint + tintWholeBar) — the legacy flat texture overlay covering
    --     the whole bar incl. the missing-health region. Unchanged behaviour.
    -- Path (flat vs mirror) is folded into structSig so toggling it rebuilds the region fresh.
    local healthBar = frame.healthBar
    if healthBar then
        local hb = store.healthbar
        if not hb then hb = {}; store.healthbar = hb end

        local bestName, bestCfg, bestMap = pickWinner(spec, specAuras, "healthbar",
            function(c) return c.color end)

        if bestName then
            local r, g, b, a = readADColor(bestCfg.color)
            local mode = slower(bestCfg.mode or "replace")
            -- Whole-bar flat tint only exists in tint mode (mirror Indicators.lua:1338):
            -- replace mode always uses the fill-matched mirror.
            local wholeBar = (mode == "tint") and (bestCfg.tintWholeBar and true or false) or false

            local structSig = includeSig(bestMap) .. "|" .. (wholeBar and "flat" or "mirror")
            local entry = hb[bestName]

            if wholeBar then
                -- LEGACY FLAT PATH — whole-bar tint texture, no mirror.
                local blend = healthbarBlend(mode, bestCfg.blend, a)
                local coSig = tconcat({ "flat", tostring(r), tostring(g), tostring(b), tostring(blend) }, "|")
                if not entry then
                    frame.dfADHealthMirror = nil
                    local handle = DF.AuraContainer:Create(healthBar, buildOverlayTintConfig(frame.unit, bestMap, r, g, b, blend, 1))
                    if handle then
                        hb[bestName] = { handle = handle, structSig = structSig, coSig = coSig }
                    end
                elseif entry.structSig ~= structSig then
                    frame.dfADHealthMirror = nil
                    entry.structSig, entry.coSig = structSig, coSig
                    entry.handle:Rebuild(buildOverlayTintConfig(frame.unit, bestMap, r, g, b, blend, 1))
                elseif entry.coSig ~= coSig then
                    entry.coSig = coSig
                    entry.handle:ApplyStyle({ overlay = { tintColor = { r, g, b, blend } } })
                end
            else
                -- FILLED MIRROR PATH — duplicate StatusBar fed the secret health percent.
                local alpha = (mode == "replace") and 1 or healthbarBlend(mode, bestCfg.blend, a)
                local fdb = DF.GetFrameDB and DF:GetFrameDB(frame)
                local tex = (fdb and fdb.healthTexture) or "Interface\\TargetingFrame\\UI-StatusBar"
                local onBar = function(sb) frame.dfADHealthMirror = sb end
                local coSig = tconcat({ "mirror", tostring(r), tostring(g), tostring(b), tostring(alpha), tostring(tex) }, "|")
                if not entry then
                    frame.dfADHealthMirror = nil   -- onBar re-stashes when the slot builds
                    local handle = DF.AuraContainer:Create(healthBar, buildHealthMirrorConfig(frame.unit, bestMap, r, g, b, alpha, tex, onBar))
                    if handle then
                        hb[bestName] = { handle = handle, structSig = structSig, coSig = coSig }
                    end
                elseif entry.structSig ~= structSig then
                    frame.dfADHealthMirror = nil   -- old slot torn down; onBar re-stashes
                    entry.structSig, entry.coSig = structSig, coSig
                    entry.handle:Rebuild(buildHealthMirrorConfig(frame.unit, bestMap, r, g, b, alpha, tex, onBar))
                elseif entry.coSig ~= coSig then
                    entry.coSig = coSig
                    entry.handle:ApplyStyle({ overlay = { healthMirror = { texture = tex, color = { r, g, b }, alpha = alpha, onBar = onBar } } })
                end
            end
        end
        teardownExcept(hb, bestName)
        -- No health-bar winner this pass → the mirror bar is gone; drop the ref.
        if not bestName then frame.dfADHealthMirror = nil end
    end

    -- ---- BACKGROUND TINT (child of frame.background, overlay tint) -------------------
    -- frame.background is a TEXTURE, not a frame, so it can't parent a container. Cover it
    -- with a plain anchor frame (create-once, combat-safe — non-secure) and host the
    -- container there. LEVEL: the tint texture lands TWO levels above this anchor (the
    -- DF.AuraContainer overlay nests anchor -> native container -> AuraSlot button, each a
    -- default +1 child). To seat the tint just under the health bar (at healthBar - 1, i.e.
    -- above frame.background but below every bar), the anchor must sit at healthBar - 3.
    -- With the health/missing bars raised to frame+3 (Create.lua), healthBar - 3 == the
    -- frame's own level, so the anchor never clamps below 0. Explicit dependency on the
    -- bar level — if the Create.lua raise changes, this follows it.
    if frame.background then
        local bg = store.background
        if not bg then bg = {}; store.background = bg end

        local bestName, bestCfg, bestMap = pickWinner(spec, specAuras, "background",
            function(c) return c.color end)

        if bestName then
            local bgAnchor = store.bgAnchor
            if not bgAnchor then
                bgAnchor = CreateFrame("Frame", nil, frame)
                bgAnchor:SetAllPoints(frame.background)
                store.bgAnchor = bgAnchor
            end
            -- (Re)assert level every pass — the health bar's level is stable post-create,
            -- but keep it robust to a frame rebuild that recreates healthBar.
            local hbLevel = frame.healthBar and frame.healthBar:GetFrameLevel() or 3
            bgAnchor:SetFrameLevel(math.max(0, hbLevel - 3))

            local r, g, b, a = readADColor(bestCfg.color)
            local mode = slower(bestCfg.mode or "tint")   -- background defaults to tint
            local blend = healthbarBlend(mode, bestCfg.blend, a)

            local structSig = includeSig(bestMap)
            local coSig = tconcat({ tostring(r), tostring(g), tostring(b), tostring(blend) }, "|")

            local entry = bg[bestName]
            if not entry then
                local handle = DF.AuraContainer:Create(bgAnchor, buildOverlayTintConfig(frame.unit, bestMap, r, g, b, blend, 0))
                if handle then
                    bg[bestName] = { handle = handle, structSig = structSig, coSig = coSig }
                end
            elseif entry.structSig ~= structSig then
                entry.structSig, entry.coSig = structSig, coSig
                entry.handle:Rebuild(buildOverlayTintConfig(frame.unit, bestMap, r, g, b, blend, 0))
            elseif entry.coSig ~= coSig then
                entry.coSig = coSig
                entry.handle:ApplyStyle({ overlay = { tintColor = { r, g, b, blend } } })
            end
        end
        teardownExcept(bg, bestName)
        -- No background winner this pass → the containers are gone; drop the anchor too.
        if not bestName then releaseBgAnchor(store) end
    end

    -- ---- BORDER (whole-frame static ring via DF.Border, overlay) ---------------------
    -- AD borders are a static user-chosen colour per aura (NOT dispel-type driven — every
    -- AD entry is a helpful buff, so Blizzard's native SetAuraBorder dispel-Color path
    -- doesn't apply). Rendered as static border art (DF.Border secretRect), shown on
    -- presence via the slot. Expiring border art (thickness/anim/colour-swap near expiry)
    -- reads remaining time → unportable, base ring only (P4.7 overlays the Expiring group).
    do
        local bd = store.border
        if not bd then bd = {}; store.border = bd end

        -- Cheap RAW-config gate (no BuildSpec, no allocation on the hot path): BuildSpec
        -- keys `enabled` off exactly this key (Border.lua:217 → enabled = ShowBorder ~= false),
        -- so the winner set is identical to a full-spec enabled check. The one real spec is
        -- built ONCE below, for the chosen winner.
        local bestName, _, bestMap = pickWinner(spec, specAuras, "border",
            function(c) return c.ShowBorder ~= false end)

        local bestSpec
        if bestName then
            bestSpec = buildBorderSpec(frame, specAuras[bestName].border)
            if not bestSpec then bestName = nil end   -- resolved disabled → render nothing
        end

        if bestName then
            local structSig = includeSig(bestMap)
            local coSig = borderSpecSig(bestSpec)

            local entry = bd[bestName]
            if not entry then
                local handle = DF.AuraContainer:Create(frame, buildBorderConfig(frame.unit, bestMap, bestSpec))
                if handle then
                    bd[bestName] = { handle = handle, structSig = structSig, coSig = coSig }
                end
            elseif entry.structSig ~= structSig then
                entry.structSig, entry.coSig = structSig, coSig
                entry.handle:Rebuild(buildBorderConfig(frame.unit, bestMap, bestSpec))
            elseif entry.coSig ~= coSig then
                entry.coSig = coSig
                entry.handle:ApplyStyle({ border = { spec = bestSpec } })
            end
        end
        teardownExcept(bd, bestName)
    end

    -- framealpha / nametext / healthtext: intentionally NOT synced. No read-free,
    -- combat-safe port exists (see file-foot notes) — their GUI controls get the
    -- "Blizzard limitation" overlay in P4.7.
end

-- ============================================================
-- TEARDOWN  (hung off the AD clear path — Engine:ClearFrame calls this)
-- Destroy is combat-safe (hides the plain anchor now, defers secure teardown to regen).
-- ============================================================
function Factory:ClearFrame(frame)
    local store = frame and frame.dfADFactory
    if not store then return end
    teardownExcept(store.healthbar or {}, nil)
    teardownExcept(store.background or {}, nil)
    teardownExcept(store.border or {}, nil)
    releaseBgAnchor(store)   -- containers gone above; drop the background anchor too
    frame.dfADHealthMirror = nil   -- health-mirror bar torn down; drop the feed ref
end

-- ============================================================
-- NOTES — 12.1 CASUALTIES (P4.2): framealpha / nametext / healthtext
-- The attach-and-inherit trick shows a slot-CHILD region on presence, letting Blizzard's
-- secret show/hide drive it read-free. It works for effects that ARE a child region drawn
-- over the frame (tint textures, a border ring). It does NOT extend to these three:
--
--  * framealpha (ref Indicators:ApplyFrameAlpha) — reduces the WHOLE unit frame's alpha on
--    presence. There is no additive-child equivalent to reducing a frame's alpha (an overlay
--    darkens, it can't make the frame transparent — and the plan forbids approximation).
--    The only mechanism would be an OnShow/OnHide hook on a slot child calling frame:SetAlpha
--    — which (a) isn't part of DF.AuraContainer's supported style API (runs insecure Lua off
--    a native button's secret-driven visibility, the taint-adjacent touch the engine warns
--    against), and (b) collides with DF's existing frame-alpha owners (range fade / OOR
--    re-assert alpha every update) with no arbitration layer. → casualty. P4.7 overlays the
--    framealpha type's controls (and its Expiring group).
--
--  * healthtext (ref Indicators:ApplyHealthText) — recolours the health-text fontstring on
--    presence. Recolouring the REAL fontstring needs a presence-gated SetAuraColorOverride
--    (a Lua call gated on a secret we can't read). The duplicate-fontstring workaround is
--    impossible here: the health-text STRING is a SECRET value in combat, so a child clone
--    can't be populated read-free. → hard casualty. P4.7 overlays the healthtext controls.
--
--  * nametext (ref Indicators:ApplyNameText) — same recolour-on-presence shape. The unit
--    NAME is public, so a duplicate fontstring clone is technically read-free (unlike
--    healthtext) — but it must mirror the Text Designer's live font/anchor/justify AND its
--    formatted string (class colour, truncation, status suffixes), re-syncing on every TD
--    re-render, or it ghosts/drifts over the real name. That's a fragile reimplementation of
--    TD name rendering for a colour tint, and the failure mode is user-visible doubled text.
--    Rejected on robustness grounds (correctness > coverage). → casualty. P4.7 overlays the
--    nametext controls. (Revisit only if a clean TD-fontstring clone lands.)
-- ============================================================

DF:Debug(DBG, "Factory (native AD bridge) loaded")
