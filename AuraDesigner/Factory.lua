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
-- SCOPE (this file, P4.0 scaffold + P4.1 + P4.2 + P4.3 + P4.4): gates, identity->includeSpellIDs,
-- the frame-level indicators that CAN be driven read-free — HEALTH-BAR (filled mirror + flat
-- tint), BACKGROUND tint, static BORDER — and the PLACED ICON / SQUARE / BAR indicators (native
-- SetIcon / solid-colour fill + native cooldown + native stacks + static border for icon/square;
-- a native SetDurationBar-driven StatusBar for the bar, one 1-slot container per configured
-- indicator, many coexisting). Placed duration text supports colour-by-time via the #205 discrete
-- BUCKET formatter (C-side |c escapes — no Lua time read). framealpha / nametext / healthtext are
-- 12.1 casualties (see NOTES at the file foot). Sound + showWhenMissing are P4.5. The factory
-- is the only AD render path now — the legacy read-path engine was removed.
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
-- 12.1 (IsSupported) and OFF in test mode — the test drives call the factory
-- themselves (DF:UpdateAllTestAuraDesigner), so the live path must not double-drive.
function DF:UseFactoryForAD(frame, db)
    return DF.AuraContainer and DF.AuraContainer.IsSupported()
        and not (DF.testMode or DF.raidTestMode)
end

-- GUI-facing predicate: does the factory own AD for this mode's db? Unlike the render
-- gate it must NOT flip in test mode — else "blocked" overlays would wrongly lift while
-- previewing (mirror FactoryOwnsBuffRow). Used by P4.7 GUI when() predicates.
function DF:FactoryOwnsAD(db)
    return (DF.AuraContainer and DF.AuraContainer.IsSupported()) or false
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
-- BUFF-BAR DEDUP UNION  (derived — the exclusion set the buff row folds in)
-- The union of every spell ID tracked by ANY configured Aura Designer indicator for the
-- frame's ACTIVE spec. Recomputed from the AD config (the source of truth) whenever the
-- buff row rebuilds, so it stays correct across indicator add/remove, whole-aura delete,
-- profile import/switch and spec change with NO stored state and NO refcount. Read-free
-- (static config only): walks adDB.auras[spec] and unions BuildADIdentityFilters (primary
-- + alternates) for every aura carrying at least one configured indicator of ANY type.
-- "Tracked" = the aura has an indicator the factory actually RENDERS ON THE BUFF SLOT (i.e.
-- while the aura is PRESENT) on 12.1: a PRESENT-mode placed indicator (icon/square/bar) or a
-- PRESENT-mode frame-level key (border / healthbar / background). Two deliberate exclusions:
--   * SOUND — now recovered (P4.5: it PLAYS on-apply via C_UnitAuras.AddAuraAppliedSound), but
--     a sound is NOT a visual replacement for the buff icon. A sound-only aura must keep showing
--     on the buff bar (audio cue + visible icon), so sound is DELIBERATELY excluded from the
--     dedup union even though it renders (plays). (nametext / healthtext / framealpha remain
--     casualties that render nothing — also excluded, add back if/when recovered.)
--   * SHOW-WHEN-MISSING indicators — a missing-mode indicator shows NOTHING while the aura is
--     present (it only appears on ABSENCE), so the buff-bar icon is the aura's only present-time
--     visual and must not be hidden. A missing-ONLY aura therefore contributes nothing to dedup.
-- Returns nil when AD is disabled, off-spec, empty, or the factory doesn't own AD for this db
-- (caller then contributes nothing). BUFF (HELPFUL) only: every AD entry is a helpful aura, and
-- a harmful map is inert on friendly frames.
local function auraHasTrackedIndicator(auraCfg)
    if type(auraCfg) ~= "table" then return false end
    local inds = auraCfg.indicators
    if inds then
        for _, ind in ipairs(inds) do
            -- Bars ignore missing mode entirely (no duration data when absent — legacy
            -- Engine.lua:510), so a bar always renders present and always dedups.
            if ind.type == "bar" or not ind.showWhenMissing then return true end
        end
    end
    local hb, bg, bd = auraCfg.healthbar, auraCfg.background, auraCfg.border
    if hb and not hb.showWhenMissing then return true end
    if bg and not bg.showWhenMissing then return true end
    if bd and not bd.showWhenMissing then return true end
    -- Text colour-by-cover (recovered): a present-mode name/health text indicator is a
    -- rendering visual, so it dedups. SWM-flagged text renders nothing (unsupported).
    local nt, ht = auraCfg.nametext, auraCfg.healthtext
    if nt and nt.color and not nt.showWhenMissing then return true end
    if ht and ht.color and not ht.showWhenMissing then return true end
    return false
end

function DF:GetADTrackedSpellIDs(frame, db)
    if not frame then return nil end
    -- Gate: AD must be enabled for this frame AND the native factory must own AD for this
    -- mode's db (mirror the render gates). Off on either -> contribute nothing.
    if not (DF.IsAuraDesignerEnabled and DF:IsAuraDesignerEnabled(frame)) then return nil end
    if not (DF.FactoryOwnsAD and DF:FactoryOwnsAD(db)) then return nil end

    local adDB = DF.ResolveAuraDesigner and DF:ResolveAuraDesigner(frame)
    if not adDB or not adDB.enabled then return nil end

    -- Active spec resolved exactly as Factory:SyncFrame does (auto -> player's live spec).
    local Engine = DF.AuraDesigner and DF.AuraDesigner.Engine
    local spec = Engine and Engine.ResolveSpec and Engine:ResolveSpec(adDB)
    if not spec then return nil end

    local specAuras = adDB.auras and adDB.auras[spec]
    if not specAuras then return nil end

    local union
    for auraName, auraCfg in pairs(specAuras) do
        if auraHasTrackedIndicator(auraCfg) then
            local f = DF:BuildADIdentityFilters(spec, auraName)
            if f and f.includeSpellIDs then
                union = union or {}
                for id in pairs(f.includeSpellIDs) do union[id] = true end
            end
        end
    end
    return union   -- nil when nothing is tracked -> caller unions nothing
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

-- Stable string form of an AD colour config, for signatures ("" when unset -> default).
local function colSig(c)
    if type(c) ~= "table" then return "" end
    local r, g, b, a = readADColor(c)
    return tconcat({ tostring(r), tostring(g), tostring(b), tostring(a) }, ",")
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

-- AD text-colour types -> the Text Designer mirror category they cover.
local TEXT_MIRROR_TYPES = { nametext = "name", healthtext = "health" }

-- Overlay container whose only style region is a MIRROR HOST: a plain slot-child frame
-- handed back via onHost, to which the Text Designer parents its colour-by-cover mirror
-- FontStrings (Render:EnableMirrors). The host contributes ONLY the slot's secret
-- visibility (aura present -> covers render); the mirrors position themselves on the
-- real FontStrings. frameLevelOffset 30: the host lands ~frame+32 (anchor + container +
-- slot nesting), above the TD overlay (frame+25) so the cover draws over the real text.
local function buildMirrorHostConfig(unit, map, onHost)
    return {
        unit = unit,
        mode = "overlay",
        filter = "HELPFUL",
        candidateFilters = { includeSpellIDs = map },
        enabled = true,
        frameLevelOffset = 30,
        style = { overlay = { mirrorHost = { onHost = onHost } } },
    }
end

-- Resolve the DF.Border spec for an AD border indicator from its CONFIG block (never a
-- live aura), mirroring Indicators:ApplyBorderToOverlay: canonical keys via BuildSpec (the
-- border-key fold ran in SyncFrame), black default colour. Returns nil when the border
-- resolves disabled (ShowBorder=false) — the caller then renders no container. Animations
-- are NO LONGER dropped here: the AuraContainer allowlist (SAFE_OVERLAY_ANIM) is the single
-- filter, keeping the DF-owned overlay animations and stripping the taint-prone LCG glows.
-- The GUI restricts the AD dropdown to the recoverable types, so only safe types reach here.
local function buildBorderSpec(frame, borderCfg)
    if not DF.Border then return nil end
    local spec = DF.Border:BuildSpec(borderCfg, "")
    if not spec or spec.enabled == false then return nil end
    if not spec.color then spec.color = { r = 0, g = 0, b = 0, a = 1 } end
    local fdb = DF:GetFrameDB(frame) or {}
    spec.pixelPerfect = fdb.pixelPerfect
    -- Fed geometry for the DF particle effects (DF Dash / DF Orbit): the AD border wraps
    -- the WHOLE frame (the overlay slot does slot:SetAllPoints(handle.frame)), whose live
    -- rect is secret on 12.1. Feed the frame's own configured width/height so they lay out
    -- from a plain config number instead of measuring the secret slot. Ignored otherwise.
    spec.knownWidth  = fdb.frameWidth
    spec.knownHeight = fdb.frameHeight
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
-- PLACED INDICATORS (icon / square)  — P4.3
-- Unlike the frame-level effects (ONE-per-region, single highest-priority winner), each
-- configured icon/square indicator is its OWN placed display at its OWN position/size, and
-- MANY coexist (different auras, different spots — or even the same spell shown twice). So
-- there is NO winner pick: SyncFrame stands up one 1-slot container per configured
-- indicator, keyed by its stable instanceKey (auraName#id), and tears down by key.
--
-- CONTAINER SHAPE: mode="row" with max=1. Row mode is the ONLY mode that builds the icon
-- content regions (icon texture / cooldown swipe / stack count / border) and binds them to
-- Blizzard's native inbound setters (SetIcon / SetDurationCooldown / SetApplicationCount) —
-- overlay mode is a bare presence box. max=1 = a single button; the container's flow layout
-- anchors that one button at the indicator's configured anchor+offset+size, exactly like the
-- legacy icon:SetPoint(anchor, frame, anchor, offsetX, offsetY) + SetSize(size, size).
-- ============================================================

-- Stable per-indicator key (mirror Engine GetInstanceKey: "auraName#id").
local function placedKey(auraName, indicator)
    return auraName .. "#" .. tostring(indicator.id)
end

-- Build the DF.Border spec for a placed icon/square indicator from its CONFIG (read-free),
-- mirroring Indicators:ConfigureIcon's border block: canonical keys via BuildSpec, AD's
-- size = BorderSize (band thickness) + inset = -BorderInset (outward extension) semantics,
-- enabled gated on ShowBorder AND not hideIcon (a ring around a hidden icon looks broken),
-- translucent-black default colour. Returns nil when the border resolves off. Gradient
-- degrades to solid on the secret-anchored slot (P4.7 overlays the gradient control) — same
-- known casualty as the frame-level border. Border ANIMATIONS now run (the row container sets
-- config.adBorderAnim, so the SAFE_OVERLAY_ANIM allowlist recovers the DF-owned types); the LCG
-- glows stay stripped and are removed from the GUI dropdown (animExcludeTypes). knownWidth/
-- knownHeight are fed so DF_DASH lays its dash count out from the configured icon size instead
-- of the secret slot rect (mirror the frame-level border's frameWidth/Height feed).
local function buildPlacedBorderSpec(frame, indicator, hideIcon)
    if not DF.Border then return nil end
    local borderEnabled = indicator.ShowBorder
    if borderEnabled == nil then borderEnabled = indicator.borderEnabled end
    if borderEnabled == nil then borderEnabled = indicator.showBorder end
    if borderEnabled == nil then borderEnabled = true end
    if not borderEnabled or hideIcon then return nil end
    local thickness = indicator.BorderSize or indicator.borderThickness or 1
    local inset     = indicator.BorderInset or indicator.borderInset or 0
    local spec = DF.Border:BuildSpec(indicator, "")
    if not spec then return nil end
    spec.enabled = true
    spec.size    = thickness
    spec.inset   = -inset
    if not spec.color then spec.color = { r = 0, g = 0, b = 0, a = 0.8 } end
    local fdb = DF:GetFrameDB(frame) or {}
    spec.pixelPerfect = fdb.pixelPerfect
    -- Fed geometry for DF_DASH: the icon/square slot is square at the configured size (floored
    -- at 8, matching buildPlacedLayout), whose live rect is secret on 12.1.
    local sz = math.max(8, tonumber(indicator.size) or 24)
    spec.knownWidth  = sz
    spec.knownHeight = sz
    return spec
end

-- Cheap RAW-config border gate (no BuildSpec, no allocation) — the same predicate the built
-- spec keys off (Border.lua:217, enabled = ShowBorder ~= false), plus not-hideIcon (a ring
-- around a hidden icon is force-disabled). Used PER-TICK for the structural border-on
-- decision; the real spec is built ONLY on (re)build / restyle, never every pass (FIX C).
local function placedBorderOn(indicator, hideIcon)
    if hideIcon then return false end
    local e = indicator.ShowBorder
    if e == nil then e = indicator.borderEnabled end
    if e == nil then e = indicator.showBorder end
    return e ~= false
end

-- RAW-config cosmetic signature of the placed border — the per-tick alloc-free replacement
-- for borderSpecSig(BuildSpec(...)). Enumerates the exact keys DF.Border:BuildSpec("") reads
-- that affect the RENDERED row border (style/texture/size/inset/offset/blend/gradient/shadow
-- + legacy thickness/inset fallbacks). ANIMATION keys are INCLUDED: placed containers opt
-- into the DF-owned border animations via config.adBorderAnim, so an animation-key change
-- alters the rendered ring and must restyle (Apply re-runs Start/StopAnimation with the new
-- type). This changes iff the built spec's rendered result changes -> IDENTICAL
-- rebuild/restyle decisions, minus the alloc.
local PLACED_BORDER_KEYS = {
    "BorderStyle", "BorderTexture", "BorderSize", "borderThickness",
    "BorderInset", "borderInset", "BorderOffsetX", "BorderOffsetY", "BorderBlendMode",
    "BorderGradientEnabled", "BorderGradientDirection",
    "BorderShadowEnabled", "BorderShadowSize", "BorderShadowOffsetX", "BorderShadowOffsetY",
    -- Animation keys (every scalar BuildSpec folds into spec.animation): needed so
    -- configuring/changing a border animation on a placed indicator hot-applies.
    "BorderAnimationType", "BorderAnimationFrequency", "BorderAnimationParticles",
    "BorderAnimationLength", "BorderAnimationThickness", "BorderAnimationScale",
    "BorderAnimationInset", "BorderAnimationOffsetX", "BorderAnimationOffsetY",
    "BorderAnimationMask", "BorderAnimationSidesAxis", "BorderAnimationCornerLength",
    "BorderAnimationProcStart",
    -- Colour-source keys: not exposed by the AD border UI today (source is always CUSTOM),
    -- but hashed defensively so an imported profile or a future class/role border option
    -- can't leave the border stale until /reload.
    "BorderColorSource", "BorderUseClassColor", "BorderUseRoleColor",
}
local PLACED_BORDER_COLOR_KEYS = {
    "BorderColor", "BorderGradientStartColor", "BorderGradientEndColor", "BorderShadowColor",
    "BorderAnimationColor",
}
local function placedBorderRawSig(indicator, borderOn)
    if not borderOn then return "" end
    local parts = {}
    for _, kk in ipairs(PLACED_BORDER_KEYS) do
        parts[#parts + 1] = tostring(indicator[kk])
    end
    for _, kk in ipairs(PLACED_BORDER_COLOR_KEYS) do
        parts[#parts + 1] = colSig(indicator[kk])
    end
    return tconcat(parts, ",")
end

-- Native stack-count TextStyle spec from the AD stack config keys (font/scale/outline/
-- anchor/offset/colour). Read-free — the COUNT itself is filled secure-side by Blizzard's
-- SetApplicationCount (no formatter — secret trap), shown at >1.
local function buildStackSpec(indicator)
    local outline = indicator.stackOutline or "OUTLINE"
    if outline == "NONE" then outline = "" end
    return {
        show    = true,
        font    = indicator.stackFont,
        size    = 10 * (tonumber(indicator.stackScale) or 1),
        outline = outline,
        anchor  = indicator.stackAnchor or "BOTTOMRIGHT",
        offsetX = tonumber(indicator.stackX) or 0,
        offsetY = tonumber(indicator.stackY) or 0,
        color   = indicator.stackColor,
    }
end

-- Layout for the single placed button: the container anchors it at the indicator's
-- configured corner + offset (mirror the legacy icon anchor). Size floored at 8 (old
-- configs predate the current slider floor). Growth/wrap are inert with one slot.
local function buildPlacedLayout(indicator)
    return {
        anchor  = (type(indicator.anchor) == "string" and indicator.anchor) or "TOPLEFT",
        offsetX = tonumber(indicator.offsetX) or 0,
        offsetY = tonumber(indicator.offsetY) or 0,
        size    = math.max(8, tonumber(indicator.size) or 24),
        scale   = tonumber(indicator.scale) or 1,
        growth  = "RIGHT_DOWN",
        wrap    = 1,
    }
end

-- Shared styleable duration-text spec for EVERY placed indicator (icon / square / bar). The
-- countdown is filled secret-safe by native SetDurationText (Blizzard formats the remaining
-- time C-side; no Lua read). "Color by Time Remaining" (P4.4) routes through the #205 discrete
-- BUCKET formatter (DF:GetFactoryDurationFormatter -> |cRRGGBB escapes baked into the native
-- NumericRuleFormatter bands, evaluated C-side against the SECRET remaining time: red <5s /
-- orange <15s / yellow <60s / green fresh — the same thresholds the buff/debuff rows use). The
-- smooth per-percent curve stays dead on container buttons (buckets only). When colour-by-time
-- owns the colour the spec leaves `color` nil so DF.TextStyle never stomps the escapes; a static
-- duration colour applies only when colour-by-time is off. NOTE: the colorByTime flag is part of
-- the STRUCTURAL signature — SetDurationText binds the formatter ONCE per slot, so a toggle must
-- Rebuild the slot to swap it (see durationFmtKey + the struct sigs).
-- Resolve the hide-above-threshold seconds (or nil when off). Legacy default 10s. The native
-- bucket formatter blanks its bands above this remaining time — evaluated C-side against the
-- SECRET remaining time, no Lua read (the exact secret-safe path #205 buff/debuff rows use).
local function durationHideAboveT(indicator)
    if not indicator.durationHideAboveEnabled then return nil end
    return tonumber(indicator.durationHideAboveThreshold) or 10
end

local function buildDurationTextSpec(indicator, defaultShow)
    local showDuration = indicator.showDuration
    if showDuration == nil then showDuration = defaultShow end
    if not showDuration then return nil end
    local dOutline = indicator.durationOutline or "OUTLINE"
    if dOutline == "NONE" then dOutline = "" end
    local colorByTime = indicator.durationColorByTime and true or false
    local hideAboveT = durationHideAboveT(indicator)
    -- Always attach the NUMBER formatter (bare "45" / "2m" / "1h") — the same default the
    -- buff/debuff/defensive rows use, and what the pre-12.1 icons showed (native cooldown
    -- numbers). Without it the container's own SetDurationText default renders "45s". The
    -- one formatter also carries colour-by-time buckets + hide-above blanking when set.
    local formatter = DF.GetFactoryDurationFormatter
        and DF:GetFactoryDurationFormatter("NUMBER", hideAboveT, colorByTime) or nil
    return {
        show      = true,
        font      = indicator.durationFont,
        size      = 10 * (tonumber(indicator.durationScale) or 1),
        outline   = dOutline,
        anchor    = indicator.durationAnchor or "CENTER",
        offsetX   = tonumber(indicator.durationX) or 0,
        offsetY   = tonumber(indicator.durationY) or 0,
        formatter = formatter,   -- nil unless colour-by-time / hide-above; |c escapes own colour
        color     = (not colorByTime) and indicator.durationColor or nil,
    }
end

-- Stable duration-text format key for the STRUCTURAL signature: the native SetDurationText
-- formatter is creation-frozen (bind-once), so a colour-by-time OR hide-above change must
-- Rebuild the slot to swap it. "" when duration text is off. Mirrors #205's dur.formatKey.
local function durationFmtKey(indicator, defaultShow)
    local showDuration = indicator.showDuration
    if showDuration == nil then showDuration = defaultShow end
    if not showDuration then return "" end
    local hideAboveT = durationHideAboveT(indicator)
    return "NUMBER"
        .. (indicator.durationColorByTime and ":C" or "")
        .. (hideAboveT and (":H" .. tostring(hideAboveT)) or "")
end

-- Build the style table for a placed icon/square. icon = native spell texture (unless
-- hideIcon = text-only); square = solid config colour fill (no SetIcon). Both keep the
-- native cooldown swipe, the styleable duration-text fontstring, the native stack count,
-- and the static border.
local function buildPlacedStyle(indicator, isSquare, borderSpec)
    local hideIcon = indicator.hideIcon and true or false
    local style = {}

    if isSquare then
        -- Solid-colour box (legacy SetColorTexture). hideIcon = no fill (text-only). The
        -- fill insets by the border thickness so the ring frames it (legacy parity).
        if not hideIcon then
            local r, g, b = readADColor(indicator.color)
            local inset = borderSpec and (indicator.BorderSize or indicator.borderThickness or 1) or 0
            style.square = { color = { r, g, b, 1 }, inset = inset }
        end
    else
        -- Spell icon. hideIcon = text-only: skip the icon texture, keep cooldown/border/
        -- stacks. Art inset matches the border thickness so the ring frames the art.
        local inset = borderSpec and (indicator.BorderSize or indicator.borderThickness or 1) or 1
        style.icon = { show = not hideIcon, inset = inset }
    end

    -- Cooldown swipe: Blizzard drives it from the matched aura's Duration object
    -- (SetDurationCooldown) — no Lua time read. hideSwipe toggles the swipe (also off in
    -- text-only mode). Native countdown numbers are OFF — duration text renders through the
    -- styleable SetDurationText fontstring below (positionable, matching the legacy icon).
    local hideSwipe = indicator.hideSwipe and true or false
    style.cooldown = { show = true, swipe = (not hideSwipe) and (not hideIcon), numbers = false }

    -- Duration text: a DF-owned fontstring the native SetDurationText fills secret-safe
    -- (Blizzard formats the remaining time C-side; no Lua read). Colour-by-time now routes
    -- through the #205 bucket formatter — see buildDurationTextSpec. Default show = true.
    style.duration = buildDurationTextSpec(indicator, true)

    -- Stacks: native count, shown at >1. NO formatter (secret trap — see bindNative). A
    -- custom stackMinimum is NOT expressible on the no-formatter native path (deferred).
    local showStacks = indicator.showStacks; if showStacks == nil then showStacks = true end
    if showStacks then style.stacks = buildStackSpec(indicator) end

    if borderSpec then style.border = { spec = borderSpec } end
    return style
end

-- Full row config for one placed indicator (max=1 single-slot container). frameLevelOffset
-- 40 = the buff-icon level (above the frame's content overlay) so placed AD indicators read
-- on top, nudged by the indicator's own frameLevel; z-order polish is a P4.7 concern.
-- Test-preview entry for a placed container: the indicator previews its OWN
-- configured spell (icon/name/tooltip resolved from the live spell ID by the
-- shared test paint). Built at config time -- one tiny table per container.
local function testEntryForMap(map)
    local id = map and next(map)
    if not id then return nil end
    local name
    if C_Spell and C_Spell.GetSpellName then
        local ok, nm = pcall(C_Spell.GetSpellName, id)
        if ok then name = nm end
    end
    local icon
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, tex = pcall(C_Spell.GetSpellTexture, id)
        if ok then icon = tex end
    end
    return { { spellID = id, name = name, icon = icon, duration = 12, stacks = 0 } }
end

local function buildPlacedConfig(unit, map, indicator, isSquare, borderSpec)
    return {
        unit = unit,
        mode = "row",
        max = 1,
        filter = "HELPFUL",
        candidateFilters = { includeSpellIDs = map },
        testEntries = testEntryForMap(map),
        enabled = true,
        tooltips = false,
        -- adBorderAnim: opt this ROW container into the DF-owned border animations (edge-alpha
        -- / DF_DASH / Wipe / Ripple) the shared allowlist otherwise reserves to overlay mode.
        -- The #205 buff/debuff rows never set it, so they still strip. Safe: the animation runs
        -- off our own secretRect border textures via the external UIParent driver, not the LCG
        -- glows (which stay stripped by SAFE_OVERLAY_ANIM regardless).
        adBorderAnim = true,
        frameLevelOffset = 40 + (tonumber(indicator.frameLevel) or 0),
        layout = buildPlacedLayout(indicator),
        style = buildPlacedStyle(indicator, isSquare, borderSpec),
    }
end

-- STRUCTURAL signature: candidateFilters (declared at build), icon-vs-square, and which
-- REGIONS exist — hideIcon, stacks on/off, duration text on/off, border on/off — plus
-- frameLevel (set once at Create) and the duration-text FORMAT KEY (SetDurationText binds the
-- colour-by-time bucket formatter once per slot, so a colorByTime toggle must Rebuild to
-- re-bind it). styleButton_regions only ever CREATES regions (never hides/removes them), so
-- toggling a region OFF must Rebuild the container to drop it; a plain ApplyStyle would leave
-- the old region visible. A change here forces a whole-container Rebuild (slots can't be
-- patched). Cosmetic styling of a live region is coSig.
local function placedStructSig(map, isSquare, hideIcon, showStacks, showDuration, borderOn, indicator)
    return includeSig(map)
        .. "|" .. (isSquare and "sq" or "ic")
        .. "|" .. (hideIcon and "hi" or "")
        .. "|" .. (showStacks and "st" or "")
        .. "|" .. (showDuration and "du" or "")
        .. "|" .. (borderOn and "bd" or "")
        .. "|fl=" .. tostring(tonumber(indicator.frameLevel) or 0)
        .. "|df=" .. durationFmtKey(indicator, true)
end

-- COSMETIC signature: size/anchor/offset/scale/alpha, swipe, duration/stack styling, square
-- colour, and the RAW-config border sig (no BuildSpec alloc — FIX C). A change here
-- hot-applies via ApplyStyle(style, layout); the actual border spec is built only then.
local function placedCoSig(indicator, isSquare, borderOn, alpha)
    local parts = {
        "sz=" .. tostring(math.max(8, tonumber(indicator.size) or 24)),
        "sc=" .. tostring(tonumber(indicator.scale) or 1),
        "an=" .. tostring(indicator.anchor or "TOPLEFT"),
        "ox=" .. tostring(tonumber(indicator.offsetX) or 0),
        "oy=" .. tostring(tonumber(indicator.offsetY) or 0),
        "al=" .. tostring(alpha),
        "sw=" .. tostring(indicator.hideSwipe and 1 or 0),
        "du=" .. tconcat({
            tostring(indicator.showDuration ~= false and 1 or 0),
            tostring(indicator.durationFont), tostring(indicator.durationScale),
            tostring(indicator.durationOutline), tostring(indicator.durationAnchor),
            tostring(indicator.durationX), tostring(indicator.durationY),
            tostring(indicator.durationColorByTime and 1 or 0),
            colSig(indicator.durationColor),
        }, ","),
        "stk=" .. tconcat({
            tostring(indicator.stackFont), tostring(indicator.stackScale),
            tostring(indicator.stackOutline), tostring(indicator.stackAnchor),
            tostring(indicator.stackX), tostring(indicator.stackY),
            colSig(indicator.stackColor),
        }, ","),
        "bd=" .. placedBorderRawSig(indicator, borderOn),
    }
    if isSquare then
        local r, g, b = readADColor(indicator.color)
        parts[#parts + 1] = "co=" .. tconcat({ tostring(r), tostring(g), tostring(b) }, ",")
    end
    return tconcat(parts, "|")
end

-- Placed base alpha rides the plain anchor frame (combat-safe; alpha is not a secret).
local function applyPlacedAlpha(handle, alpha)
    handle._dfADBaseAlpha = alpha   -- read by the OOR fade (ElementAppearance)
    local f = handle and handle.GetFrame and handle:GetFrame()
    if f then pcall(function() f:SetAlpha(alpha) end) end
end

-- ============================================================
-- PLACED BAR INDICATOR  — P4.4
-- A bar is a placed indicator like icon/square (per-indicator, many coexist, keyed by
-- instanceKey, torn down by key), but its slot content is a StatusBar bound via native
-- SetDurationBar: Blizzard drives the fill from the aura's Duration object render-side (no
-- Lua time read). Identity / size / colour / texture / orientation are static config; the
-- countdown is the secure-side fill. Duration text rides the SAME styleable SetDurationText
-- fontstring as icon/square (colour-by-time via the #205 bucket formatter). The FILL colour-
-- by-time (barColorByTime) and every expiring effect are remaining-time-driven casualties —
-- GUI-blocked (the Expiring group gets the "limitation" overlay), never approximated here.
-- ============================================================

-- Resolve the placed bar's rendered width/height from CONFIG (read-free): matchFrameWidth/
-- Height pull the frame's CONFIGURED size (mirror the border knownWidth feed), else the explicit
-- width/height. Shared by the layout (slot size) and the border's fed DF_DASH geometry so both
-- agree without measuring the secret slot rect.
local function resolveBarSize(frame, indicator)
    local fdb = DF:GetFrameDB(frame) or {}
    local matchW = indicator.matchFrameWidth; if matchW == nil then matchW = true end
    local matchH = indicator.matchFrameHeight and true or false
    local width  = tonumber(indicator.width)  or 60
    local height = tonumber(indicator.height) or 6
    if matchW then width  = tonumber(fdb.frameWidth)  or width end
    if matchH then height = tonumber(fdb.frameHeight) or height end
    return math.max(1, width), math.max(1, height)
end

-- Bar border spec from CONFIG (read-free). Mirrors buildPlacedBorderSpec minus the hideIcon
-- gate (a bar has no icon), and the legacy bar's outward-band math: the ring's inner edge sits
-- at the bar edge (Inset 0 = flush) and grows outward. Gradient degrades to solid on the
-- secret-anchored slot (P4.7 overlays the gradient control), same casualty as icon/square.
-- Border ANIMATIONS run (buildBarConfig sets config.adBorderAnim); LCG glows stay stripped +
-- GUI-excluded. knownWidth/knownHeight feed DF_DASH the configured bar size (secret slot rect
-- otherwise), so dashed borders lay out correctly.
local function buildBarBorderSpec(frame, indicator)
    if not DF.Border then return nil end
    if not placedBorderOn(indicator, false) then return nil end
    local thickness = indicator.BorderSize or indicator.borderThickness or 1
    local inset     = indicator.BorderInset or indicator.borderInset or 0
    local spec = DF.Border:BuildSpec(indicator, "")
    if not spec then return nil end
    spec.enabled = true
    spec.size    = thickness
    spec.inset   = -(inset + thickness)   -- fully outward from the bar edge (legacy parity)
    if not spec.color then spec.color = { r = 0, g = 0, b = 0, a = 1 } end
    local fdb = DF:GetFrameDB(frame) or {}
    spec.pixelPerfect = fdb.pixelPerfect
    local w, h = resolveBarSize(frame, indicator)
    spec.knownWidth  = w
    spec.knownHeight = h
    return spec
end

-- Layout for the placed bar: sizeX = width, sizeY = height (a bar is not square). Size comes
-- from resolveBarSize (matchFrameWidth/Height read-free from config). Anchor/offset from config
-- (legacy bar default anchor BOTTOM).
local function buildBarLayout(frame, indicator)
    local width, height = resolveBarSize(frame, indicator)
    return {
        anchor  = (type(indicator.anchor) == "string" and indicator.anchor) or "BOTTOM",
        offsetX = tonumber(indicator.offsetX) or 0,
        offsetY = tonumber(indicator.offsetY) or 0,
        sizeX   = math.max(1, width),
        sizeY   = math.max(1, height),
        scale   = tonumber(indicator.scale) or 1,
        growth  = "RIGHT_DOWN",
        wrap    = 1,
    }
end

-- Bar style: the StatusBar fills the slot (no icon / no square / no cooldown swipe — the fill
-- IS the countdown). Fill colour / texture / orientation / reverse-fill / background from
-- config; native SetDurationBar (bindNative) drives the value. Duration text via the shared
-- styleable fontstring (colour-by-time buckets). Interpolation/direction are creation-frozen
-- opts (bind-once) — Immediate + RemainingTime match the legacy bar's SetTimerDuration call.
local function buildBarStyle(indicator, borderSpec)
    local fr, fg, fb, fa = readADColor(indicator.fillColor)
    local style = {
        icon     = { show = false },
        cooldown = { show = false },
        bar = {
            show          = true,
            fill          = true,
            texture       = indicator.texture,
            color         = { fr, fg, fb, fa },
            bgColor       = indicator.bgColor,
            orientation   = (indicator.orientation == "VERTICAL") and "VERTICAL" or "HORIZONTAL",
            reverseFill   = indicator.reverseFill and true or false,
            interpolation = "Immediate",
            direction     = "RemainingTime",
        },
    }
    -- Legacy bar default for Show Duration is OFF (unlike icon/square, which default ON).
    style.duration = buildDurationTextSpec(indicator, false)
    if borderSpec then style.border = { spec = borderSpec } end
    return style
end

-- Full row config for one placed bar (max=1 single-slot container). Same frame-level band as
-- the icon/square placed indicators (40 + per-indicator frameLevel).
local function buildBarConfig(frame, unit, map, indicator, borderSpec)
    return {
        unit = unit,
        mode = "row",
        max = 1,
        filter = "HELPFUL",
        candidateFilters = { includeSpellIDs = map },
        testEntries = testEntryForMap(map),
        enabled = true,
        tooltips = false,
        adBorderAnim = true,   -- opt into DF-owned border animations (see buildPlacedConfig)
        frameLevelOffset = 40 + (tonumber(indicator.frameLevel) or 0),
        layout = buildBarLayout(frame, indicator),
        style = buildBarStyle(indicator, borderSpec),
    }
end

-- ============================================================
-- EDITOR PREVIEW CONFIG (AD editor canvas)
-- The same style/layout the live container gets, minus the container-only
-- parts — the editor styles a plain PREVIEW SLOT with it
-- (AuraContainer.StylePreviewSlot/PaintPreviewSlot), so the canvas preview
-- is the factory's own rendering. Returns (config, structSig): the editor
-- recreates its slot frame when the sig changes (regions are create-only,
-- mirror the live Rebuild rule).
-- ============================================================
function Factory:BuildPreviewConfig(frame, indicator, typeKey, spellID)
    local entries = spellID and testEntryForMap({ [spellID] = true }) or nil
    if typeKey == "bar" then
        local borderSpec = placedBorderOn(indicator, false)
            and buildPlacedBorderSpec(frame, indicator, false) or nil
        local cfg = {
            mode = "row", max = 1, filter = "HELPFUL",
            adBorderAnim = true,
            layout = buildBarLayout(frame, indicator),
            style = buildBarStyle(indicator, borderSpec),
            testEntries = entries,
        }
        local sig = "bar|" .. tostring(borderSpec ~= nil)
            .. "|" .. tostring(cfg.style.duration ~= nil)
            .. "|" .. durationFmtKey(indicator, false)
        return cfg, sig
    end
    local isSquare = (typeKey == "square")
    local hideIcon = indicator.hideIcon and true or false
    local borderSpec = placedBorderOn(indicator, hideIcon)
        and buildPlacedBorderSpec(frame, indicator, hideIcon) or nil
    local cfg = {
        mode = "row", max = 1, filter = "HELPFUL",
        adBorderAnim = true,
        layout = buildPlacedLayout(indicator),
        style = buildPlacedStyle(indicator, isSquare, borderSpec),
        testEntries = entries,
    }
    local sig = (isSquare and "square|" or "icon|") .. tostring(hideIcon)
        .. "|" .. tostring(cfg.style.stacks ~= nil)
        .. "|" .. tostring(cfg.style.duration ~= nil)
        .. "|" .. tostring(borderSpec ~= nil)
        .. "|" .. durationFmtKey(indicator, true)
    return cfg, sig
end

-- STRUCTURAL signature: identity, duration-text on/off + format key (SetDurationText / SetDuration
-- Bar bind ONCE), border on/off, frame level. Cosmetic bar styling is barCoSig.
local function barStructSig(map, indicator, borderOn)
    return includeSig(map)
        .. "|bar"
        .. "|df=" .. durationFmtKey(indicator, false)
        .. "|" .. (borderOn and "bd" or "")
        .. "|fl=" .. tostring(tonumber(indicator.frameLevel) or 0)
end

-- COSMETIC signature: size (width/height + match-frame + the fed frame size), anchor/offset/
-- scale/alpha, texture/fill/bg/orientation/reverse, duration-text styling, and the raw-config
-- border sig (no BuildSpec alloc). A change hot-applies via ApplyStyle(style, layout).
local function barCoSig(frame, indicator, borderOn, alpha)
    local fdb = DF:GetFrameDB(frame) or {}
    return tconcat({
        "w="  .. tostring(tonumber(indicator.width)  or 60),
        "h="  .. tostring(tonumber(indicator.height) or 6),
        "mw=" .. tostring(indicator.matchFrameWidth ~= false and 1 or 0) .. ":" .. tostring(fdb.frameWidth),
        "mh=" .. tostring(indicator.matchFrameHeight and 1 or 0) .. ":" .. tostring(fdb.frameHeight),
        "an=" .. tostring(indicator.anchor or "BOTTOM"),
        "ox=" .. tostring(tonumber(indicator.offsetX) or 0),
        "oy=" .. tostring(tonumber(indicator.offsetY) or 0),
        "sc=" .. tostring(tonumber(indicator.scale) or 1),
        "al=" .. tostring(alpha),
        "tex=" .. tostring(indicator.texture),
        "or=" .. tostring(indicator.orientation or "HORIZONTAL"),
        "rf=" .. tostring(indicator.reverseFill and 1 or 0),
        "fc=" .. colSig(indicator.fillColor),
        "bc=" .. colSig(indicator.bgColor),
        "du=" .. tconcat({
            tostring(indicator.showDuration == true and 1 or 0),
            tostring(indicator.durationFont), tostring(indicator.durationScale),
            tostring(indicator.durationOutline), tostring(indicator.durationAnchor),
            tostring(indicator.durationX), tostring(indicator.durationY),
            tostring(indicator.durationColorByTime and 1 or 0),
            colSig(indicator.durationColor),
        }, ","),
        "bd=" .. placedBorderRawSig(indicator, borderOn),
    }, "|")
end

-- ============================================================
-- SHOW-WHEN-MISSING  — P4.5
-- An indicator/effect with showWhenMissing set INVERTS its trigger: it renders while the
-- tracked aura is ABSENT (a "you're missing this" reminder) instead of on presence. Driven
-- READ-FREE by DF.AuraContainer's mode="missing" layout-push inversion (probe 32): a clip
-- WINDOW parks a handle-owned BADGE inside itself while the spellID-filtered group is empty
-- (aura absent); one blank button's cell pushes the badge fully out of the window when the
-- aura is present (renders nothing). We size the window/badge to the indicator's art and style
-- the badge from GetBadgeFrame(). Zero secret reads — identity + geometry + colour are static
-- config; Blizzard's secret show/hide drives the push.
--
-- SCOPE: icon / square (placed) and border / healthbar / background (frame-level). BARS are
-- excluded — legacy has no missing mode for bars (no duration data when absent, Engine.lua:510),
-- and the GUI never offered showWhenMissing for a bar. Cooldown / duration text / stacks are
-- NOT rendered on a missing indicator (nothing to count when the aura is absent).
--
-- ANIMATION: missing-window borders must NEVER animate. The badge border is a handle-owned
-- DF.Border (secretRect -> its animation driver hosts on UIParent), and the badge is NOT a slot
-- in any handle's self.buttons, so _teardownContainer's StopAnimation loop never reaches it — an
-- animated badge would leave an orphaned ticker running forever. So every missing badge-border
-- spec is hard-nilled (spec.animation = nil), exactly the missing-buff badge precedent
-- (Features/Auras.lua:3122). (StopAnimation is not cleanly reachable from the AD missing teardown
-- for the same "badge isn't in self.buttons" reason, so hard-nil is the correct choice here.)
-- ============================================================

-- Primary static spell ID for an AD aura (config, never a live aura): the SpellIDs whitelist
-- entry, used to fetch the STATIC icon texture (Blizzard won't fill art for an absent aura).
local function primaryADSpellID(spec, auraName)
    local specIDs = DF.AuraDesigner.SpellIDs and DF.AuraDesigner.SpellIDs[spec]
    local p = specIDs and specIDs[auraName]
    if type(p) == "table" then p = p[1] end
    return p
end

-- Static icon texture for a missing indicator (mirror Engine buildSyntheticAuraData): the
-- AD IconTextures override, else C_Spell.GetSpellTexture on the static primary ID, else the
-- generic question-mark fallback. Read-free (config + a static spell-ID texture lookup).
local function missingIconTexture(spec, auraName)
    local tex = DF.AuraDesigner.IconTextures and DF.AuraDesigner.IconTextures[auraName]
    if not tex then
        local pid = primaryADSpellID(spec, auraName)
        if pid and C_Spell and C_Spell.GetSpellTexture then tex = C_Spell.GetSpellTexture(pid) end
    end
    return tex or 136243
end

-- Missing-mode config for a PLACED icon/square: mode="missing", badge sized to the indicator's
-- square art. Same frame-level band as the present placed indicators. candidateFilters is the
-- static identity map (structural — bound at build).
local function buildPlacedMissingConfig(unit, map, indicator)
    local size = math.max(8, tonumber(indicator.size) or 24)
    return {
        unit = unit,
        mode = "missing",
        filter = "HELPFUL",
        candidateFilters = { includeSpellIDs = map },
        badge = { w = size, h = size },
        enabled = true,
        frameLevelOffset = 40 + (tonumber(indicator.frameLevel) or 0),
    }
end

-- Missing-mode config for a FRAME-LEVEL effect (healthbar / background / border): the window/
-- badge covers the target region, sized READ-FREE from the frame's CONFIGURED width/height
-- (fdb.frameWidth/frameHeight — the same fed-size the border uses; the live rect is secret on
-- 12.1). The push cell width (AuraContainer build = badge.w + MISSING_PAD) is therefore >= the
-- window width, so presence evacuates the whole region FULLY. Frame-level band matches the
-- present frame-level effects (border uses +10; tints seat lower — see callers).
local function buildFrameLevelMissingConfig(unit, map, w, h, levelOffset)
    return {
        unit = unit,
        mode = "missing",
        filter = "HELPFUL",
        candidateFilters = { includeSpellIDs = map },
        badge = { w = math.max(1, w), h = math.max(1, h) },
        enabled = true,
        frameLevelOffset = levelOffset,
    }
end

-- Style a PLACED missing badge: static spell icon (or solid colour square), optional border
-- (animation stripped), optional desaturate. No cooldown / duration / stacks (nothing to show
-- while absent). The badge is handle-owned; we attach art to GetBadgeFrame().
local function stylePlacedMissingBadge(h, frame, spec, auraName, indicator, isSquare)
    local badge = h.GetBadgeFrame and h:GetBadgeFrame()
    if not badge then return end
    local hideIcon = indicator.hideIcon and true or false

    -- Border (config, read-free) — animation ALWAYS stripped on a missing badge (orphan-ticker
    -- hazard; see section header + Auras.lua:3122). buildPlacedBorderSpec returns nil when the
    -- border resolves off (or hideIcon), matching the present path.
    local borderSpec = buildPlacedBorderSpec(frame, indicator, hideIcon)
    if borderSpec then borderSpec.animation = nil end
    local artInset = borderSpec and (borderSpec.size or indicator.BorderSize or 1) or 0

    if isSquare then
        if not badge.dfADFill then badge.dfADFill = badge:CreateTexture(nil, "ARTWORK") end
        local fill = badge.dfADFill
        if hideIcon then
            fill:Hide()
        else
            local r, g, b = readADColor(indicator.color)
            fill:SetColorTexture(r, g, b, 1)
            fill:ClearAllPoints()
            fill:SetPoint("TOPLEFT", artInset, -artInset)
            fill:SetPoint("BOTTOMRIGHT", -artInset, artInset)
            fill:Show()
        end
        if badge.dfADIcon then badge.dfADIcon:Hide() end
    else
        if not badge.dfADIcon then
            badge.dfADIcon = badge:CreateTexture(nil, "ARTWORK")
            badge.dfADIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
        local icon = badge.dfADIcon
        icon:SetTexture(missingIconTexture(spec, auraName))
        icon:SetDesaturated(indicator.missingDesaturate and true or false)
        icon:SetShown(not hideIcon)
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", artInset, -artInset)
        icon:SetPoint("BOTTOMRIGHT", -artInset, artInset)
        if badge.dfADFill then badge.dfADFill:Hide() end
    end

    if borderSpec then
        if not badge.dfADBorder then
            badge.dfADBorder = DF.Border:New(badge, { secretRect = true, frameLevelOffset = 0 })
        end
        DF.Border:Apply(badge.dfADBorder, borderSpec)
    elseif badge.dfADBorder then
        DF.Border:Apply(badge.dfADBorder, { enabled = false })
    end

    -- Base alpha rides the clip window (combat-safe; alpha is not a secret).
    local f = h.GetFrame and h:GetFrame()
    if f then pcall(function() f:SetAlpha(tonumber(indicator.alpha) or 1) end) end
end

-- Style a FRAME-LEVEL missing badge as a flat TINT fill (healthbar / background colour-when-
-- missing). The fill covers the whole window (== the region). Colour/blend from config.
local function styleTintMissingBadge(h, r, g, b, blend)
    local badge = h.GetBadgeFrame and h:GetBadgeFrame()
    if not badge then return end
    if not badge.dfADFill then badge.dfADFill = badge:CreateTexture(nil, "ARTWORK") end
    badge.dfADFill:SetColorTexture(r, g, b, blend)
    badge.dfADFill:ClearAllPoints()
    badge.dfADFill:SetAllPoints(badge)
    badge.dfADFill:Show()
end

-- Style a FRAME-LEVEL missing badge as a whole-frame BORDER ring (border-when-missing).
-- secretRect + animation stripped (orphan-ticker hazard). borderSpec built read-free by the
-- caller via buildBorderSpec.
local function styleBorderMissingBadge(h, borderSpec)
    local badge = h.GetBadgeFrame and h:GetBadgeFrame()
    if not badge or not borderSpec then return end
    borderSpec.animation = nil
    if not badge.dfADBorder then
        badge.dfADBorder = DF.Border:New(badge, { secretRect = true, frameLevelOffset = 0 })
    end
    DF.Border:Apply(badge.dfADBorder, borderSpec)
end

-- Sync one FRAME-LEVEL missing container (healthbar / background / border winner in missing
-- mode). structSig = identity-only (candidateFilters bind at build). coSig = the caller's
-- cosmetic hash; apply(handle) styles the badge. Handles create / identity Destroy+recreate /
-- cosmetic restyle, re-positions the window over its region, and hot-resizes on a size change.
-- parent = the frame the window PARENTS to (must be a Frame); anchorTo = the region it covers
-- (may be a texture, e.g. frame.background); levelOffset = z-band above parent.
local function syncFrameLevelMissing(store, keyName, map, frame, parent, anchorTo, w, hgt, levelOffset, coSig, apply)
    w = math.max(1, tonumber(w) or 1); hgt = math.max(1, tonumber(hgt) or 1)
    local structSig = includeSig(map) .. "|miss"
    local function place(handle)
        handle:ClearAllPoints()
        handle:SetPoint("TOPLEFT", anchorTo, "TOPLEFT", 0, 0)
    end
    local entry = store[keyName]
    -- A missing container's identity is bound at build AND its window/badge sizing is applied
    -- only in Create (Rebuild leaves h.frame/h.badge at the old size). So an identity change is
    -- a Destroy+recreate, not a Rebuild — re-running Create resizes cleanly. (Size-only changes
    -- hot-apply via SetBadgeSize below.)
    if entry and entry.structSig ~= structSig then
        entry.handle:Destroy(); store[keyName] = nil; entry = nil
    end
    if not entry then
        local handle = DF.AuraContainer:Create(parent, buildFrameLevelMissingConfig(frame.unit, map, w, hgt, levelOffset))
        if handle then
            place(handle)
            apply(handle)
            store[keyName] = { handle = handle, structSig = structSig, coSig = coSig, missing = true }
        end
    elseif entry.coSig ~= coSig then
        entry.coSig = coSig
        if entry.handle.SetBadgeSize then entry.handle:SetBadgeSize(w, hgt) end
        place(entry.handle)
        apply(entry.handle)
    end
end

-- ============================================================
-- SOUND INDICATOR  (native on-apply)  — P4.5
-- The 12.1 revival of the sound indicator. C_UnitAuras.AddAuraAppliedSound({ unitToken,
-- spellID, soundFileName|soundFileID, outputChannel }) plays a sound when the tracked aura is
-- APPLIED to the unit — the ONLY read-free sound the API supports (there is NO on-fade /
-- AuraRemovedSound hook, and no per-play volume). This REPLACES the legacy read-based
-- SoundEngine on the factory path (which alerted while a buff was MISSING / EXPIRING — both
-- presence/remaining-time driven, sealed on 12.1). Registration is NOT a secure-frame op, but
-- the lab did NOT confirm combat-legality, so (re)registration is DEFERRED out of combat, the
-- same OOC/regen discipline the containers use (consistency over cleverness). Registration
-- handles are tracked per aura and unregistered on every teardown path — a leaked registration
-- is the failure mode this is designed against.
-- ============================================================

local VALID_SOUND_CHANNELS = { Master = true, SFX = true, Music = true, Ambience = true, Dialog = true }

local function resolveSoundChannel(adDB)
    local ch = adDB and adDB.soundChannel
    if not ch or not VALID_SOUND_CHANNELS[ch] then ch = "Master" end
    return ch
end

-- Resolve the configured sound to the native struct field. DF:GetSoundPath returns a file
-- PATH string (LSM Fetch), so we pass soundFileName; a raw numeric fileID passes soundFileID.
-- Returns key, value (or nil when unresolved -> the indicator registers nothing).
local function resolveSoundArg(soundCfg)
    local snd = DF:GetSoundPath(soundCfg.soundLSMKey) or soundCfg.soundFile
    if type(snd) == "number" then return "soundFileID", snd end
    if type(snd) == "string" and snd ~= "" then return "soundFileName", snd end
    return nil
end

local function registerAppliedSound(unit, spellID, argKey, argVal, channel)
    local add = C_UnitAuras and C_UnitAuras.AddAuraAppliedSound
    if type(add) ~= "function" then return nil end
    local args = { unitToken = unit, spellID = spellID, outputChannel = channel }
    args[argKey] = argVal
    local ok, id = pcall(add, args)
    if ok then return id end
    DF:DebugWarn(DBG, "AddAuraAppliedSound failed (spell %s): %s", tostring(spellID), tostring(id))
    return nil
end

local function unregisterAppliedSound(id)
    local rem = C_UnitAuras and C_UnitAuras.RemoveAuraAppliedSound
    if id ~= nil and type(rem) == "function" then pcall(rem, id) end
end

-- OOC-only reconcile of a frame's applied-sound registrations to its CONFIG. Desired = every
-- enabled sound indicator on the active spec whose identity + sound resolve. Diff against the
-- per-aura store (keyed by aura name); a changed signature (unit / spell set / sound / channel)
-- unregisters the old handles then re-registers. Gate off / spec nil / config removed -> desired
-- empty -> full teardown. Idempotent — safe to call repeatedly (SyncFrame tail, regen flush).
local function reconcileSoundNow(frame)
    if not (C_UnitAuras and C_UnitAuras.AddAuraAppliedSound) then return end   -- pre-12.1: legacy owns it
    local store = frame.dfADFactory
    if not store then return end

    local desired
    local enabled = DF.IsAuraDesignerEnabled and DF:IsAuraDesignerEnabled(frame)
    local db = DF.GetFrameDB and DF:GetFrameDB(frame)
    local owns = DF.FactoryOwnsAD and DF:FactoryOwnsAD(db)
    if enabled and owns and frame.unit then
        local adDB = DF.ResolveAuraDesigner and DF:ResolveAuraDesigner(frame)
        if adDB and adDB.enabled then
            local Engine = DF.AuraDesigner and DF.AuraDesigner.Engine
            local spec = Engine and Engine.ResolveSpec and Engine:ResolveSpec(adDB)
            local specAuras = spec and adDB.auras and adDB.auras[spec]
            if specAuras then
                local channel = resolveSoundChannel(adDB)
                for auraName, auraCfg in pairs(specAuras) do
                    local sc = (type(auraCfg) == "table") and auraCfg.sound
                    if sc and sc.enabled then
                        local ids = DF:BuildADIdentityFilters(spec, auraName)
                        local map = ids and ids.includeSpellIDs
                        local argKey, argVal = resolveSoundArg(sc)
                        if map and argKey then
                            desired = desired or {}
                            desired[auraName] = {
                                map = map, argKey = argKey, argVal = argVal, channel = channel,
                                sig = frame.unit .. "|" .. includeSig(map) .. "|"
                                    .. argKey .. "=" .. tostring(argVal) .. "|" .. channel,
                            }
                        end
                    end
                end
            end
        end
    end

    local soundStore = store.sound
    if not desired and not soundStore then return end
    soundStore = soundStore or {}; store.sound = soundStore

    -- Tear down entries no longer desired or whose signature changed.
    for auraName, entry in pairs(soundStore) do
        local d = desired and desired[auraName]
        if not d or d.sig ~= entry.sig then
            for _, id in ipairs(entry.ids) do unregisterAppliedSound(id) end
            soundStore[auraName] = nil
        end
    end
    -- Register newly-desired / changed auras (one handle per spell ID in the identity map).
    if desired then
        for auraName, d in pairs(desired) do
            if not soundStore[auraName] then
                local ids = {}
                for spellID in pairs(d.map) do
                    local id = registerAppliedSound(frame.unit, spellID, d.argKey, d.argVal, d.channel)
                    if id ~= nil then ids[#ids + 1] = id end
                end
                soundStore[auraName] = { ids = ids, sig = d.sig }
            end
        end
    end
end

-- Frames whose sound reconcile is deferred to combat-end (weak-keyed so a dropped frame GCs).
Factory._soundPending = Factory._soundPending or setmetatable({}, { __mode = "k" })
local soundRegenFrame
local function ensureSoundRegen()
    if soundRegenFrame then return end
    soundRegenFrame = CreateFrame("Frame")
    soundRegenFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    soundRegenFrame:SetScript("OnEvent", function()
        for f in pairs(Factory._soundPending) do
            Factory._soundPending[f] = nil
            reconcileSoundNow(f)
        end
    end)
end

-- Public entry — reconcile a frame's applied-sound registrations. Registration legality in
-- combat is unverified, so in lockdown we DEFER to PLAYER_REGEN_ENABLED (mirrors the container
-- OOC discipline); OOC we reconcile immediately.
function Factory:SyncSound(frame)
    if not frame or not frame.unit then return end
    if not (C_UnitAuras and C_UnitAuras.AddAuraAppliedSound) then return end
    if InCombatLockdown() then
        Factory._soundPending[frame] = true
        ensureSoundRegen()
        return
    end
    reconcileSoundNow(frame)
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

    -- The factory owns AD here (the legacy read-path engine is gone), so nothing maintains the
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

    -- UNIT RETARGET (roster churn): frames are reused across units, but every container's
    -- unit is declared at Create and none of the sigs carry it — so re-point any live handle
    -- whose unit no longer matches the frame (mirror DriveMissingBuffFactory's h:SetUnit pass;
    -- SetUnit self-defers to regen in combat). Cheap per-pass: one config read per handle.
    do
        local u = frame.unit
        for _, storeKey in ipairs({ "healthbar", "background", "border", "placed",
                                    "nametext", "healthtext" }) do
            local t = store[storeKey]
            if t then
                for _, entry in pairs(t) do
                    local h = entry and entry.handle
                    if h and h.GetUnit and h:GetUnit() ~= u and h.SetUnit then
                        h:SetUnit(u)
                    end
                end
            end
        end
    end

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
            local existingHB = hb[bestName]
            local wantMissingHB = bestCfg.showWhenMissing and true or false
            if existingHB and (existingHB.missing and true or false) ~= wantMissingHB then
                existingHB.handle:Destroy(); hb[bestName] = nil
                frame.dfADHealthMirror = nil
            end
          if wantMissingHB then
            -- SHOW-WHEN-MISSING: a flat tint over the health-bar region while the buff is ABSENT.
            -- Window/badge sized read-free from the frame's CONFIGURED size (the live rect is
            -- secret on 12.1); single-anchored to the health bar's TOPLEFT so it covers the region
            -- (config-size approximation — precise region + z-order are P4.7 polish). The filled
            -- mirror is a present-only concept, so nil the feed ref while in missing mode.
            frame.dfADHealthMirror = nil
            local r, g, b, a = readADColor(bestCfg.color)
            local mode = slower(bestCfg.mode or "replace")
            local blend = (mode == "replace") and a or healthbarBlend(mode, bestCfg.blend, a)
            local fdb = (DF.GetFrameDB and DF:GetFrameDB(frame)) or {}
            local mw, mh = tonumber(fdb.frameWidth) or 100, tonumber(fdb.frameHeight) or 20
            local coSig = tconcat({ "miss", tostring(r), tostring(g), tostring(b), tostring(blend), tostring(mw), tostring(mh) }, "|")
            syncFrameLevelMissing(hb, bestName, bestMap, frame, healthBar, healthBar, mw, mh, 1, coSig,
                function(handle) styleTintMissingBadge(handle, r, g, b, blend) end)
          else
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
            local existingBG = bg[bestName]
            local wantMissingBG = bestCfg.showWhenMissing and true or false
            if existingBG and (existingBG.missing and true or false) ~= wantMissingBG then
                existingBG.handle:Destroy(); bg[bestName] = nil
            end
          if wantMissingBG then
            -- SHOW-WHEN-MISSING: flat tint over the background region while the buff is ABSENT.
            -- Sized read-free from config; anchored to frame.background (parents to `frame`, which
            -- must be a Frame). z-order below the bars is a P4.7 polish concern (uses offset 0).
            local r, g, b, a = readADColor(bestCfg.color)
            local mode = slower(bestCfg.mode or "tint")
            local blend = healthbarBlend(mode, bestCfg.blend, a)
            local fdb = (DF.GetFrameDB and DF:GetFrameDB(frame)) or {}
            local mw, mh = tonumber(fdb.frameWidth) or 100, tonumber(fdb.frameHeight) or 20
            local coSig = tconcat({ "miss", tostring(r), tostring(g), tostring(b), tostring(blend), tostring(mw), tostring(mh) }, "|")
            syncFrameLevelMissing(bg, bestName, bestMap, frame, frame, frame.background, mw, mh, 0, coSig,
                function(handle) styleTintMissingBadge(handle, r, g, b, blend) end)
          else
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
            local borderCfg = specAuras[bestName].border
            local wantMissingBD = (borderCfg and borderCfg.showWhenMissing) and true or false
            local existingBD = bd[bestName]
            if existingBD and (existingBD.missing and true or false) ~= wantMissingBD then
                existingBD.handle:Destroy(); bd[bestName] = nil
            end
          if wantMissingBD then
            -- SHOW-WHEN-MISSING: the ring shows while the buff is ABSENT. Window covers the WHOLE
            -- frame (config-sized: fdb.frameWidth/Height, live rect secret); badge = the static
            -- border art with animation STRIPPED (the badge is not a slot in self.buttons, so no
            -- _teardownContainer StopAnimation loop reaches its UIParent driver -> hard-nil, per
            -- the missing-buff badge precedent). NEW USE of the missing mechanism at FRAME size —
            -- the cell push (badge.w + pad) must evacuate the wide window fully on presence
            -- (flag for in-game validation).
            local fdb = (DF.GetFrameDB and DF:GetFrameDB(frame)) or {}
            local mw, mh = tonumber(fdb.frameWidth) or 100, tonumber(fdb.frameHeight) or 20
            local capturedSpec = bestSpec
            local coSig = "miss|" .. borderSpecSig(bestSpec) .. "|" .. tostring(mw) .. "x" .. tostring(mh)
            syncFrameLevelMissing(bd, bestName, bestMap, frame, frame, frame, mw, mh, 10, coSig,
                function(handle) styleBorderMissingBadge(handle, capturedSpec) end)
          else
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
        end
        teardownExcept(bd, bestName)
    end

    -- ---- NAME / HEALTH TEXT (colour-by-cover via Text Designer mirrors) --------------
    -- Recovered 12.1 casualties. The factory never touches the real fontstrings: it
    -- stands up an overlay container whose slot-child HOST is handed to the Text
    -- Designer (Render:EnableMirrors), which keeps glyph-identical coloured covers in
    -- sync with the real elements. Aura present -> slot shows -> covers render over the
    -- text; absent -> covers hide. Single highest-priority winner per category (one
    -- cover colour per element, like the other frame-level effects). Show-when-missing
    -- is NOT supported for text (rendering an SWM indicator present-mode would invert
    -- the user's intent) — SWM-flagged text indicators render nothing and don't dedup.
    do
        local TDRender = DF.TextDesigner and DF.TextDesigner.Render
        for typeKey, category in pairs(TEXT_MIRROR_TYPES) do
            local st = store[typeKey]
            if not st then st = {}; store[typeKey] = st end

            local bestName, bestCfg, bestMap = pickWinner(spec, specAuras, typeKey,
                function(c) return c.color and not c.showWhenMissing end)
            if bestName and TDRender then
                local r, g, b, a = readADColor(bestCfg.color)
                local color = { r = r, g = g, b = b, a = a }
                local structSig = includeSig(bestMap)
                local coSig = colSig(bestCfg.color)
                -- onHost fires on every style pass (create/ApplyStyle/Blizzard re-init):
                -- stash the host for the TD-teardown recovery below and (re)register the
                -- mirrors — EnableMirrors is idempotent per parent and restamps colour.
                local function onHost(host)
                    local e = st[bestName]
                    if e then e.host = host end
                    st._lastHost = host
                    TDRender:EnableMirrors(frame, category, host, color)
                end
                local entry = st[bestName]
                if not entry then
                    local handle = DF.AuraContainer:Create(frame,
                        buildMirrorHostConfig(frame.unit, bestMap, onHost))
                    if handle then
                        st[bestName] = { handle = handle, structSig = structSig,
                                         coSig = coSig, host = st._lastHost }
                    end
                elseif entry.structSig ~= structSig then
                    entry.structSig, entry.coSig = structSig, coSig
                    entry.handle:Rebuild(buildMirrorHostConfig(frame.unit, bestMap, onHost))
                elseif entry.coSig ~= coSig then
                    entry.coSig = coSig
                    entry.handle:ApplyStyle({ overlay = { mirrorHost = { onHost = onHost } } })
                elseif entry.host and not (frame._tdMirrors and frame._tdMirrors[category]) then
                    -- TD Teardown (mode/profile switch) dropped the mirror registry while
                    -- our container persisted — re-register on the stashed host. Cheap
                    -- nil-check per pass, only fires after a TD teardown.
                    TDRender:EnableMirrors(frame, category, entry.host, color)
                end
            elseif TDRender then
                TDRender:DisableMirrors(frame, category)
            end
            -- _lastHost is a scratch field, not an entry: keep teardownExcept off it.
            st._lastHost = nil
            teardownExcept(st, bestName)
        end
    end

    -- ---- PLACED ICON / SQUARE / BAR (per-indicator 1-slot containers) ----------------
    -- NO winner pick: every configured icon/square/bar indicator is its own placed display,
    -- keyed by instanceKey; many coexist (all share the `store.placed` store and per-key
    -- teardown). A structural change (identity set / icon-vs-square / hideIcon / stacks
    -- on-off / duration-format / frame level) rebuilds the whole container; a cosmetic change
    -- (size/anchor/offset/scale/alpha/colour/border/stack style) hot-applies via ApplyStyle.
    -- The bar is another placed indicator (its slot is a StatusBar driven by SetDurationBar) —
    -- same machinery, its own builders/sigs. Torn down per key when the indicator is removed.
    do
        local placed = store.placed
        if not placed then placed = {}; store.placed = placed end
        local live = {}

        if specAuras then
            for auraName, auraCfg in pairs(specAuras) do
                local indicators = (type(auraCfg) == "table") and auraCfg.indicators
                if indicators then
                    for _, indicator in ipairs(indicators) do
                        local isSquare = indicator.type == "square"
                        local isBar = indicator.type == "bar"
                        if isBar then
                            local ids = DF:BuildADIdentityFilters(spec, auraName)
                            local map = ids and ids.includeSpellIDs
                            if map then
                                local key = placedKey(auraName, indicator)
                                live[key] = true
                                local borderOn = placedBorderOn(indicator, false)
                                local alpha = tonumber(indicator.alpha) or 1
                                local structSig = barStructSig(map, indicator, borderOn)
                                local coSig = barCoSig(frame, indicator, borderOn, alpha)

                                local entry = placed[key]
                                if not entry then
                                    local borderSpec = borderOn and buildBarBorderSpec(frame, indicator) or nil
                                    local handle = DF.AuraContainer:Create(frame,
                                        buildBarConfig(frame, frame.unit, map, indicator, borderSpec))
                                    if handle then
                                        applyPlacedAlpha(handle, alpha)
                                        placed[key] = { handle = handle, structSig = structSig, coSig = coSig }
                                    end
                                elseif entry.structSig ~= structSig then
                                    local borderSpec = borderOn and buildBarBorderSpec(frame, indicator) or nil
                                    entry.structSig, entry.coSig = structSig, coSig
                                    entry.handle:Rebuild(buildBarConfig(frame, frame.unit, map, indicator, borderSpec))
                                    applyPlacedAlpha(entry.handle, alpha)
                                elseif entry.coSig ~= coSig then
                                    local borderSpec = borderOn and buildBarBorderSpec(frame, indicator) or nil
                                    entry.coSig = coSig
                                    entry.handle:ApplyStyle(
                                        buildBarStyle(indicator, borderSpec),
                                        buildBarLayout(frame, indicator))
                                    applyPlacedAlpha(entry.handle, alpha)
                                end
                            end
                        elseif isSquare or indicator.type == "icon" then
                            local ids = DF:BuildADIdentityFilters(spec, auraName)
                            local map = ids and ids.includeSpellIDs
                            if map then
                                local key = placedKey(auraName, indicator)
                                live[key] = true
                                local hideIcon = indicator.hideIcon and true or false
                                local wantMissingP = indicator.showWhenMissing and true or false
                                local existingP = placed[key]
                                if existingP and (existingP.missing and true or false) ~= wantMissingP then
                                    existingP.handle:Destroy(); placed[key] = nil
                                end
                              if wantMissingP then
                                -- SHOW-WHEN-MISSING placed icon/square: static spell icon (or solid
                                -- colour square) + border, shown while the buff is ABSENT. No
                                -- cooldown / duration / stacks (nothing to count when absent). Border
                                -- animation is stripped on the badge (orphan-ticker hazard).
                                local size = math.max(8, tonumber(indicator.size) or 24)
                                local borderOnM = placedBorderOn(indicator, hideIcon)
                                local anchorM = (type(indicator.anchor) == "string" and indicator.anchor) or "TOPLEFT"
                                local oxM, oyM = tonumber(indicator.offsetX) or 0, tonumber(indicator.offsetY) or 0
                                local scaleM = tonumber(indicator.scale) or 1
                                local structSig = includeSig(map) .. "|" .. (isSquare and "sq" or "ic")
                                    .. "|miss|fl=" .. tostring(tonumber(indicator.frameLevel) or 0)
                                local coSig = tconcat({
                                    "sz=" .. tostring(size), "sc=" .. tostring(scaleM),
                                    "an=" .. anchorM, "ox=" .. tostring(oxM), "oy=" .. tostring(oyM),
                                    "al=" .. tostring(tonumber(indicator.alpha) or 1),
                                    "hi=" .. tostring(hideIcon and 1 or 0),
                                    "ds=" .. tostring(indicator.missingDesaturate and 1 or 0),
                                    "co=" .. (isSquare and colSig(indicator.color) or ""),
                                    "bd=" .. placedBorderRawSig(indicator, borderOnM),
                                }, "|")
                                local function placeM(handle)
                                    handle:ClearAllPoints()
                                    handle:SetPoint(anchorM, frame, anchorM, oxM, oyM)
                                    local f = handle.GetFrame and handle:GetFrame()
                                    if f then pcall(function() f:SetScale(scaleM) end) end
                                end
                                local entry = placed[key]
                                -- Identity/struct change on a missing container = Destroy+recreate
                                -- (Rebuild doesn't re-size h.frame/h.badge — only Create does).
                                if entry and entry.structSig ~= structSig then
                                    entry.handle:Destroy(); placed[key] = nil; entry = nil
                                end
                                if not entry then
                                    local handle = DF.AuraContainer:Create(frame,
                                        buildPlacedMissingConfig(frame.unit, map, indicator))
                                    if handle then
                                        placeM(handle)
                                        stylePlacedMissingBadge(handle, frame, spec, auraName, indicator, isSquare)
                                        placed[key] = { handle = handle, structSig = structSig, coSig = coSig, missing = true }
                                    end
                                elseif entry.coSig ~= coSig then
                                    entry.coSig = coSig
                                    if entry.handle.SetBadgeSize then entry.handle:SetBadgeSize(size, size) end
                                    placeM(entry.handle)
                                    stylePlacedMissingBadge(entry.handle, frame, spec, auraName, indicator, isSquare)
                                end
                              else
                                local showStacks = indicator.showStacks
                                if showStacks == nil then showStacks = true end
                                showStacks = showStacks and true or false
                                local showDuration = indicator.showDuration ~= false
                                local borderOn = placedBorderOn(indicator, hideIcon)
                                local alpha = tonumber(indicator.alpha) or 1

                                -- Sigs are computed from RAW config every tick (no BuildSpec
                                -- alloc — FIX C); the actual border spec is built ONLY inside a
                                -- create/rebuild/restyle branch below, never per pass.
                                local structSig = placedStructSig(map, isSquare, hideIcon, showStacks,
                                    showDuration, borderOn, indicator)
                                local coSig = placedCoSig(indicator, isSquare, borderOn, alpha)

                                local entry = placed[key]
                                if not entry then
                                    local borderSpec = borderOn and buildPlacedBorderSpec(frame, indicator, hideIcon) or nil
                                    local handle = DF.AuraContainer:Create(frame,
                                        buildPlacedConfig(frame.unit, map, indicator, isSquare, borderSpec))
                                    if handle then
                                        applyPlacedAlpha(handle, alpha)
                                        placed[key] = { handle = handle, structSig = structSig, coSig = coSig }
                                    end
                                elseif entry.structSig ~= structSig then
                                    local borderSpec = borderOn and buildPlacedBorderSpec(frame, indicator, hideIcon) or nil
                                    entry.structSig, entry.coSig = structSig, coSig
                                    entry.handle:Rebuild(buildPlacedConfig(frame.unit, map, indicator, isSquare, borderSpec))
                                    applyPlacedAlpha(entry.handle, alpha)
                                elseif entry.coSig ~= coSig then
                                    local borderSpec = borderOn and buildPlacedBorderSpec(frame, indicator, hideIcon) or nil
                                    entry.coSig = coSig
                                    entry.handle:ApplyStyle(
                                        buildPlacedStyle(indicator, isSquare, borderSpec),
                                        buildPlacedLayout(indicator))
                                    applyPlacedAlpha(entry.handle, alpha)
                                end
                              end
                            end
                        end
                    end
                end
            end
        end

        -- Tear down any placed container whose indicator is gone / de-configured.
        for key, entry in pairs(placed) do
            if not live[key] then
                if entry.handle then entry.handle:Destroy() end
                placed[key] = nil
            end
        end
    end

    -- ---- SOUND (native on-apply registrations) --------------------------------------
    -- Reconcile C_UnitAuras.AddAuraAppliedSound registrations to the sound-indicator config
    -- (combat-deferred inside SyncSound). NOT a container — its own OOC/regen discipline.
    -- Skipped in test mode: previews must not register real on-apply sounds.
    if not (DF.testMode or DF.raidTestMode) then
        self:SyncSound(frame)
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
    teardownExcept(store.placed or {}, nil)   -- per-indicator icon/square/bar containers
    teardownExcept(store.nametext or {}, nil)
    teardownExcept(store.healthtext or {}, nil)
    -- Release the Text Designer mirror covers owned by the two text containers above.
    if DF.TextDesigner and DF.TextDesigner.Render then
        DF.TextDesigner.Render:DisableMirrors(frame, "name")
        DF.TextDesigner.Render:DisableMirrors(frame, "health")
    end
    releaseBgAnchor(store)   -- containers gone above; drop the background anchor too
    frame.dfADHealthMirror = nil   -- health-mirror bar torn down; drop the feed ref
    -- Sound: reconcile to config with AD now off -> unregisters every applied-sound handle
    -- (combat-deferred to regen inside SyncSound). No leaked registrations.
    self:SyncSound(frame)
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
--  * nametext / healthtext — RECOVERED (colour-by-cover). Originally written off: the
--    real fontstring can't be recoloured (presence-gated call on a secret), and a clone
--    was thought impossible for health text ("the string is secret in combat"). Both
--    conclusions fell to the secret-passthrough finding: FontStrings ACCEPT secret
--    values, so the Text Designer feeds a duplicate cover FontString the SAME resolved
--    font + SafeText value it gives the real element (glyph-identical by construction,
--    zero reads — TextDesigner/Render.lua EnableMirrors), and the cover rides an AD
--    overlay slot's secret visibility. See the NAME / HEALTH TEXT block in SyncFrame.
--    Residual limits: expiring colour swaps stay dead (remaining-time), text SWM is
--    unsupported, inline |c codes in group items keep their embedded colour, and the
--    cover ignores the OOR text fade (it lives outside the TD overlay).
-- ============================================================

-- ============================================================
-- DIAGNOSTICS — /df admissing
-- Developer probe for the show-when-missing push mechanism. Dumps every AD
-- missing-mode container AND (as the control group) the Missing Buffs cells
-- on the same frames, so the two consumers of the identical backend can be
-- A/B-compared live. Run once with the tracked aura ABSENT and once with it
-- APPLIED: the container child count is the money reading — if children
-- appear on apply but the badge stays visible, the anchor/clip side is
-- broken; if no children appear, the group/filter/enable side is.
-- Developer output: raw prints by design (slash diagnostic, not localized).
-- Every read off Blizzard widgets is pcall+secret-guarded.
-- ============================================================
do
    local function safeNum(fn, obj)
        local ok, v = pcall(fn, obj)
        if not ok then return "err" end
        if issecretvalue and issecretvalue(v) then return "secret" end
        return tostring(v)
    end
    local function dumpHandle(tag, key, h)
        if not h then print("    " .. tag .. " [" .. key .. "] handle=nil") return end
        local backend = h.backend
        local c = backend and backend.container
        local groups = backend and backend.groupKeys and #backend.groupKeys or 0
        local badge = h.badge
        local win = h.frame
        local badgeAnchorOK = "?"
        if badge and c then
            local ok, _, relTo = pcall(badge.GetPoint, badge, 1)
            if ok then badgeAnchorOK = tostring(relTo == c) end
        end
        print(("    %s [%s] unit=%s groups=%d container=%s children=%s enabled=%s badgeShown=%s badge->container=%s clip=%s winSize=%sx%s"):format(
            tag, key, tostring(h.config and h.config.unit),
            groups, tostring(c ~= nil),
            c and safeNum(c.GetNumChildren, c) or "-",
            c and safeNum(c.IsEnabled, c) or "-",
            badge and safeNum(badge.IsShown, badge) or "-",
            badgeAnchorOK,
            win and safeNum(win.DoesClipChildren, win) or "-",
            win and safeNum(win.GetWidth, win) or "-",
            win and safeNum(win.GetHeight, win) or "-"))
    end
    -- Visual push probe: a bright marker parented to UIParent (so the clip window can
    -- never hide it), CROSS-ANCHORED to the badge. Anchoring to a secret-derived rect is
    -- render-side and legal (we never read it). If the layout-push happens, the marker
    -- visibly slides with the badge; if the marker never moves on aura apply, the
    -- container never laid out the blank button at all.
    local markers = {}
    local function markBadge(tag, h)
        local badge = h and h.badge
        if not badge then return end
        local m = markers[badge]
        if not m then
            m = CreateFrame("Frame", nil, UIParent)
            m:SetSize(10, 10)
            m:SetFrameStrata("TOOLTIP")
            local t = m:CreateTexture(nil, "OVERLAY")
            t:SetAllPoints(m)
            t:SetColorTexture(tag == "MB" and 0 or 1, tag == "MB" and 1 or 0, 1, 1)
            markers[badge] = m
        end
        m:ClearAllPoints()
        m:SetPoint("CENTER", badge, "TOPLEFT", 0, 0)
        m:Show()
    end
    function DF:DebugADMissingMark()
        local n = 0
        local function scan(frame)
            local store = frame and frame.dfADFactory
            if store then
                for _, storeKey in ipairs({ "healthbar", "background", "border", "placed" }) do
                    local t = store[storeKey]
                    if t then
                        for _, entry in pairs(t) do
                            if entry and entry.missing and entry.handle then
                                markBadge("AD", entry.handle); n = n + 1
                            end
                        end
                    end
                end
            end
            if frame and frame.missingFactory then
                for _, h in pairs(frame.missingFactory) do markBadge("MB", h); n = n + 1 end
            end
        end
        if DF.IteratePartyFrames then DF:IteratePartyFrames(scan) end
        if DF.IterateRaidFrames then DF:IterateRaidFrames(scan) end
        print("|cff7373f2DandersFrames|r admissing markers placed: " .. n
            .. " (magenta = AD, cyan = MB; watch whether they SLIDE when the aura is applied)")
    end
    function DF:DebugADMissing()
        print("|cff7373f2DandersFrames|r AD missing-mode probe:")
        local function scan(frame)
            if not frame or not frame.unit then return end
            local shown
            local store = frame.dfADFactory
            if store then
                for _, storeKey in ipairs({ "healthbar", "background", "border", "placed" }) do
                    local t = store[storeKey]
                    if t then
                        for key, entry in pairs(t) do
                            if entry and entry.missing then
                                if not shown then shown = true; print("  frame unit=" .. tostring(frame.unit)) end
                                dumpHandle("AD:" .. storeKey, tostring(key), entry.handle)
                            end
                        end
                    end
                end
            end
            -- Control group: the proven Missing Buffs cells on the same frame.
            if frame.missingFactory then
                for key, h in pairs(frame.missingFactory) do
                    if not shown then shown = true; print("  frame unit=" .. tostring(frame.unit)) end
                    dumpHandle("MB", tostring(key), h)
                end
            end
        end
        if DF.IteratePartyFrames then DF:IteratePartyFrames(scan) end
        if DF.IterateRaidFrames then DF:IterateRaidFrames(scan) end
        print("  (run once with the aura absent, once applied; compare 'children')")
    end
end

DF:Debug(DBG, "Factory (native AD bridge) loaded")
