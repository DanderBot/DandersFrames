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
-- the frame-level indicators that CAN be driven read-free — HEALTH-BAR (fill cover + flat
-- tint), BACKGROUND tint, static BORDER — and the PLACED ICON / SQUARE / BAR indicators (native
-- SetIcon / solid-colour fill + native cooldown + native stacks + static border for icon/square;
-- a native SetDurationBar-driven StatusBar for the bar, one 1-slot container per configured
-- indicator, many coexisting). Placed duration text supports colour-by-time via the #205 discrete
-- BUCKET formatter (C-side |c escapes — no Lua time read). nametext / healthtext were recovered
-- via colour-by-cover; framealpha remains a 12.1 casualty (see NOTES at the file foot).
-- Sound + showWhenMissing are P4.5. The factory
-- is the only AD render path now — the legacy read-path engine was removed.
--
-- COMBAT / SECRET obligations (delegated to the DF.AuraContainer handle, the #205-proven
-- path): containers are created/enabled OUT of combat and deferred to PLAYER_REGEN_ENABLED
-- in lockdown (Create/_deferRebuild, Rebuild/_deferRebuild, ApplyStyle/_pendingRestyle,
-- ApplyTuning/_pendingTuning — the Wave-1 in-place group tuning path);
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

-- Store-key prefix for the spec-INDEPENDENT "Other Buffs" pool (adDB.otherAuras, B1).
-- Wherever a store key embeds an aura's name (placed instanceKeys, frame-level winner
-- keys, sound keys — and the B2 editor's expandedCards keys), the other-pool record
-- embeds OTHER_PREFIX .. auraName in the name segment, so keys can never collide with
-- a same-named spec-pool aura. Collision-proof by construction: spec-pool names are
-- SpellDB/curated spell names or ad-hoc "#<id>" keys — neither can start with "other:".
local OTHER_PREFIX = "other:"

-- One-shot (per session, per name) tripwire for OTHER-pool names that resolve to NO
-- identity map. The pool's naming contract is SpellDB names (rec.n / localized) or
-- ad-hoc "#<id>" keys — an unresolvable name here means a bad record (e.g. a curated
-- INTERNAL key like "PowerWordShield", which only resolves through a spec). The render/
-- dedup/sound paths silently skip such records; this names the culprit once instead of
-- spamming per frame per aura event. Guards B2's picker contract.
local otherIdentWarned = {}
-- ⚠ `where` names the POOL, because this now fires for BOTH. It used to be gated to the
-- Other pool (`pool == 2` / `keyPrefix ~= ""`), so a SPEC-pool record whose identity failed
-- to resolve rendered nothing with no log at all -- the silent-capability-skip class this
-- codebase has a standing rule against. That is also the dominant failure mode after a
-- dangling @custom:/@preset: reference, i.e. precisely what somebody would be trying to
-- diagnose when they turn debug on.
local function warnOtherUnresolved(auraName, where)
    if not otherIdentWarned[auraName] then
        otherIdentWarned[auraName] = true
        DF:DebugWarn(DBG, "%s aura %s has no resolvable spell identity (expected a SpellDB spell name, a #<id> key, or a live filter reference); skipping",
            where or "Other Buffs", tostring(auraName))
    end
end

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
-- FILTER REFERENCES  ("@preset:<key>" / "@custom:<id>")
-- A registry filter used where an aura NAME is expected — as an effect's trigger, or
-- as the record a frame effect hangs off. One sentinel string rather than a nested
-- selection table, so every array of aura names (triggers, store keys, card keys)
-- keeps working untouched.
--
-- ☠ CACHED, and it has to be. Resolving a selection walks the registry and a preset
-- can carry 100+ ids; the caller is BuildADIdentityFilters, which pickWinner runs once
-- per configured effect per TYPE — five times per frame on every aura event. Uncached
-- this would be a hot-path regression, not a feature. Keyed to DF.auraLayoutVersion,
-- which every filter edit / custom-filter delete / link change already bumps (the same
-- invalidation fgroupResCache rides).
--
-- The returned table is SHARED and must be treated as immutable: it is handed to
-- AuraContainer:Create and retained in the live handle's config, exactly as the filter
-- groups' cached res.map already is.
-- ============================================================
local AD_FILTER_PREFIX = "@"
local adFilterRefCache, adFilterRefCacheVer = {}, -1

-- Split a sentinel into its selection shape, or nil when it isn't one.
-- Custom-filter ids are STRINGS ("cf17" — R:CreateCustomFilter builds them as
-- "cf" .. nextFilterID), so the id travels verbatim and is never tonumber'd.
function DF:ParseADFilterRef(name)
    if type(name) ~= "string" or name:sub(1, 1) ~= AD_FILTER_PREFIX then return nil end
    local presetKey = name:match("^@preset:(.+)$")
    if presetKey then return "preset", presetKey end
    local customID = name:match("^@custom:(.+)$")
    if customID then return "custom", customID end
    return nil
end

-- Build the sentinel for a filter reference (the one place the format is written).
function DF:MakeADFilterRef(kind, key)
    if kind ~= "preset" and kind ~= "custom" then return nil end
    if key == nil or key == "" then return nil end
    return AD_FILTER_PREFIX .. kind .. ":" .. tostring(key)
end

-- Display name for a sentinel, or nil when it isn't one. Lives here rather than in the
-- options addon because the editor's card list DROPS any record it can't name
-- (CollectAllEffects) — a filter-owned effect that can't resolve a name is an effect the
-- user can never see or delete. Deleted custom filters fall back to a placeholder for
-- exactly that reason.
function DF:ADFilterRefDisplayName(name)
    local kind, key = DF:ParseADFilterRef(name)
    if not kind then return nil end
    local R = DF.FilterRegistry
    local L = DF.L
    if kind == "preset" then
        if R and R.Categories then
            for _, cat in ipairs(R.Categories) do
                if cat.key == key then return L[cat.name] or cat.name end
            end
        end
        return key
    end
    local cf = R and R.GetCustomFilter and R:GetCustomFilter(key)
    return (cf and cf.name) or L["Deleted Filter"]
end

function DF:ResolveADFilterRef(name)
    local kind, key = DF:ParseADFilterRef(name)
    if not kind then return nil end
    local ver = DF.auraLayoutVersion or 0
    if adFilterRefCacheVer ~= ver then
        adFilterRefCache = {}
        adFilterRefCacheVer = ver
    end
    local hit = adFilterRefCache[name]
    if hit ~= nil then
        -- `false` is the memoised "does not resolve" — don't re-walk the registry for it.
        if hit == false then return nil end
        return hit
    end
    local R = DF.FilterRegistry
    local res = R and R.ResolveSelection and R:ResolveSelection(
        (kind == "preset") and { presets = { [key] = true }, customs = {} }
                            or { presets = {}, customs = { [key] = true } }, false)
    -- "all" (empty selection) and "exclude" render nothing and must NOT collapse to an
    -- empty include map — that would match every helpful aura. Same gate the filter
    -- group render path applies.
    if res and res.kind == "include" and res.map and next(res.map) then
        local out = { includeSpellIDs = res.map }
        adFilterRefCache[name] = out
        return out
    end
    adFilterRefCache[name] = false
    return nil
end

-- ============================================================
-- IDENTITY  (static spell-ID whitelist -> native includeSpellIDs map)
-- A { includeSpellIDs = map } candidate-filter table Blizzard evaluates
-- container-side. Built purely from STATIC data — the per-spec config plus the
-- shipped SpellDB — never from a live aura. Returns nil when the aura name has
-- no known spell ID (caller then skips — an empty include map would wrongly
-- match EVERY helpful aura).
-- `spec` may be NIL (the Other Buffs pool, B1): the per-spec Config tables can't match
-- a nil spec key, so resolution is spec-INDEPENDENT by construction — ad-hoc "#<id>"
-- first, then SpellDB by name. Other-pool names must therefore be SpellDB names
-- (rec.n / localized) or ad-hoc keys; curated INTERNAL names ("PowerWordShield") only
-- resolve through a spec.
-- ============================================================
-- ★ PER-PLACEMENT NARROWING. A curated aura resolves to the UNION of its spell IDs, which
-- is right for "never silently miss an effect" and wrong for anyone who wants one of them.
-- Reported as: Beacon of the Savior carries the beacon buff (1244893) AND an absorb buff
-- (1244878), and there was no way to place the beacon as a square without the absorb
-- coming with it — adding it by ID snapped to the curated name and re-widened.
--
-- Stored as MUTES (ids to drop) rather than an include subset, matching the Filter page's
-- own filterMutedSpellIDs: an id the SpellDB adds LATER keeps being tracked instead of
-- silently going missing, and an absent key means today's behaviour byte-for-byte.
-- ☠ SCOPE: this is placement-scoped and the filter store is filter-scoped. They are
-- deliberately separate — muting an id for your Buff Bar filter must not silently retarget
-- an AD square, and vice versa.
--
-- ☠ ALWAYS BUILDS A FRESH TABLE. Two of the resolver's paths hand back memory that is not
-- ours: the filter-ref path returns a map held in adFilterRefCache, and the curated path is
-- built from Adapter:GetAuraSpellIDs, whose array is cached and shared. Narrowing in place
-- would corrupt the cache for every other consumer of that spell.
local function narrowByPlacementMutes(out, indicator)
    local mutes = type(indicator) == "table" and indicator.mutedSpellIDs
    if type(mutes) ~= "table" or not next(mutes) then return out end
    local src = out and out.includeSpellIDs
    if type(src) ~= "table" then return out end
    local kept, n = {}, 0
    for id in pairs(src) do
        if not mutes[id] then kept[id] = true; n = n + 1 end
    end
    -- ★ EVERY id muted = MATCHES NOTHING, and that is a legitimate thing to configure.
    -- Return nil (+ the muted flag), which is this resolver's existing "no identity, skip
    -- it" contract — the caller then renders no container at all.
    -- ☠ NEVER an empty includeSpellIDs. An empty include map matches EVERY helpful aura,
    -- which is the exact failure this resolver exists to prevent; "shows nothing" and
    -- "shows everything" are one typo apart here.
    -- The second return distinguishes "the user ticked nothing" from "we could not resolve
    -- this aura", so the unresolved warning does not fire on a deliberate choice.
    -- (This used to keep the FULL set instead, back when the card refused to untick the
    -- last id. That refusal is gone — it forced the eye to do a job the ticks should do —
    -- so the render has to be able to express the empty set.)
    if n == 0 then return nil, true end
    return { includeSpellIDs = kept }
end

-- ★ Does this placement currently match NOTHING — i.e. has the user unticked every one of
-- its spell ids? ONE answer with three consumers that must never disagree:
--   * the render, which builds no container at all;
--   * the editor canvas, which must draw no preview (a canvas showing what the frame will
--     not is the divergence class this addon keeps paying for);
--   * the card, which greys the eye so the state is legible instead of mysterious.
-- ☠ NOT the same as "unresolvable". An aura the resolver cannot identify also yields no
-- map, but that is a data problem rather than a choice — which is why the resolver returns
-- a second value instead of leaving every call site to guess from a nil.
-- Cheap-exits before resolving when there are no mutes at all, which is every indicator in
-- every profile that has not touched this feature.
function DF:ADPlacementTracksNothing(spec, auraName, indicator)
    if type(indicator) ~= "table" or type(indicator.mutedSpellIDs) ~= "table" then return false end
    local _, mutedEmpty = DF:BuildADIdentityFilters(spec, auraName, indicator)
    return mutedEmpty and true or false
end

function DF:BuildADIdentityFilters(spec, auraName, indicator)
    -- Curated identity, resolved by AuraAdapter:GetSpecIdentity -- the ONE place
    -- the ID set is decided, shared with the editor's add-by-ID snap so a
    -- placement and the picker can never disagree about a spell. Entries with no
    -- hand-curated alternates inherit the SpellDB's; see the inheritance rule
    -- documented there. A fresh map per call: callers store it into container
    -- configs, and the cached array must not become one.
    local Adapter = DF.AuraDesigner and DF.AuraDesigner.Adapter
    local ids = Adapter and Adapter.GetAuraSpellIDs and Adapter:GetAuraSpellIDs(spec, auraName)
    local map
    if ids then
        for _, id in ipairs(ids) do
            map = map or {}
            map[id] = true
        end
    end
    if map then return narrowByPlacementMutes({ includeSpellIDs = map }, indicator) end
    -- Ad-hoc add-by-ID auras (picker "Add" with an ID the SpellDB doesn't
    -- know) are stored under the key "#<id>" — the name IS the identity, so
    -- resolving the embedded id here makes the record survive reload and
    -- profile export with no side table.
    local adHocID = type(auraName) == "string" and auraName:match("^#(%d+)$")
    if adHocID then
        -- Ad-hoc auras carry exactly one id, so a mute could only ever empty the set —
        -- narrowByPlacementMutes keeps it whole in that case. Routed through it anyway so
        -- every path answers the same way and none can be the one somebody forgot.
        return narrowByPlacementMutes({ includeSpellIDs = { [tonumber(adHocID)] = true } }, indicator)
    end
    -- FILTER REFERENCES ("@preset:<key>" / "@custom:<id>"): a whole registry filter
    -- standing in for a single spell. Because this is the ONE resolver every effect
    -- goes through, teaching it here makes a filter usable both as an effect's TRIGGER
    -- and as the record a frame effect hangs off -- no second store, no extra pool.
    -- Collision-proof for the same reason "#<id>" is: no spell name starts with "@".
    local fref = DF.ResolveADFilterRef and DF:ResolveADFilterRef(auraName)
    if fref then return narrowByPlacementMutes(fref, indicator) end
    -- SpellDB fallback (all-spec support): a name the curated per-spec Config
    -- tables don't know resolves through the FilterRegistry SpellDB by display
    -- name (shipped English `rec.n` or the localized runtime name), unioning
    -- the canonical ID + every alt. This is the ONLY path for an uncurated spec.
    -- ⚠ It is NOT how a curated name widens any more — that happens inside
    -- GetSpecIdentity, which joins to the database by ID rather than by name
    -- (the curated key "EbonMight" never matches rec.n "Ebon Might"). The old
    -- comment here promised the Config tables were always consulted first "so
    -- every pre-existing indicator keeps byte-identical identity"; that promise
    -- now belongs to GetSpecIdentity's inheritance rule, which keeps it for
    -- every hand-curated multi-ID entry and only widens entries that declared
    -- nothing of their own.
    local R = DF.FilterRegistry
    local rec = R and R.GetSpellByName and R:GetSpellByName(auraName)
    if rec then
        map = { [rec.id] = true }
        if rec.alts then
            for _, altID in ipairs(rec.alts) do
                map[altID] = true
            end
        end
        return narrowByPlacementMutes({ includeSpellIDs = map }, indicator)
    end
    return nil
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
--   * HIDDEN indicators (eye toggle, `enabled == false`; nil/true = shown for legacy records) —
--     a hidden indicator renders nothing, so it must not count as tracked (its buff-row icon
--     comes back). Same gate the render paths use (SyncFrame placed loop + pickWinner).
--   * OTHERS-ONLY indicators (`othersOnly == true`, B1) — they render only OTHERS' casts
--     ("HELPFUL|!PLAYER"), so deduping would leave the player's OWN cast with no visual
--     anywhere. A spell counts as tracked only via its non-othersOnly blocks: a mixed record
--     (one othersOnly + one normal indicator) still dedups (the normal one shows the self-
--     cast), an all-othersOnly spell keeps its buff-row icon. Visible duplication of others'
--     casts is the lesser evil vs silent self-invisibility — and with the buff row's Only
--     Mine filter the two are perfectly disjoint (row = your cast, AD = others'). Gated
--     identically for BOTH pools (spec-pool records could carry the flag someday).
-- Returns nil when AD is disabled, off-spec, empty, or the factory doesn't own AD for this db
-- (caller then contributes nothing). BUFF (HELPFUL) only: every AD entry is a helpful aura, and
-- a harmful map is inert on friendly frames.
-- FILTER-GROUP RESOLUTION CACHE (A5 hot-path). Resolving a group's selection
-- walks the registry and signing it sorts the full id map (100+ ids for preset
-- links) — too heavy to run per frame per aura event. Cache the resolved result
-- AND its signature per GROUP TABLE (weak keys: deleted groups GC), keyed to
-- DF.auraLayoutVersion: every live-link invalidation (filter edit via the
-- DirectFilterChangedProxy chain, group link/unlink, eye toggle, custom-filter
-- delete) already bumps that version. Within a version, SyncFrame does a plain
-- string compare of the cached sig; on a version change each group resolves +
-- signs exactly ONCE (SelectionSignature takes the pre-resolved result — no
-- double resolve). Profile/spec switches swap the group TABLES themselves, so
-- identity keying self-invalidates even without a version bump.
local fgroupResCache = setmetatable({}, { __mode = "k" })
-- NOTE: the returned res (and res.map) is the CACHED table, shared across
-- frames and consumers within a version — treat it as immutable.
local function resolveFilterGroup(R, group)
    local ver = DF.auraLayoutVersion or 0
    local c = fgroupResCache[group]
    if c and c.version == ver then return c.res, c.sig end
    local res = R:ResolveSelection(group.filterSelection, false)
    local sig = R:SelectionSignature(group.filterSelection, false, res)
    fgroupResCache[group] = { version = ver, res = res, sig = sig }
    return res, sig
end

-- ============================================================
-- CONDITION GROUPS  (AND across groups, OR within a group)
-- An effect can carry `typeCfg.conditions` instead of the flat `triggers` list:
--
--   conditions = {
--       mode   = "ALL",                                  -- how the GROUPS combine
--       groups = { { mode = "ANY", triggers = {...} },   -- how one group's entries combine
--                  { mode = "ANY", triggers = {...} } },
--   }
--
-- ☠ WHY ONLY "ALL of ANY" RENDERS TODAY. The two operators cost completely different
-- things on 12.1:
--   * OR is FREE. A container's candidateFilters is already a spell-ID SET, so "any of
--     these" is one union in one container — exactly what the flat trigger list does.
--   * AND needs the containers STACKED. There is no read available to test two auras at
--     once, so instead each group builds a container whose slot-child frame hosts the
--     next group's container: the innermost can only be visible when every outer one is
--     too, and the game evaluated the conjunction for us. Proven in game 2026-08-09,
--     including with the buffs applied in either order and in combat.
-- So "ALL of ANY groups" is ONE chain with one visual at the end — the shape the
-- mechanism natively has. "ANY of ALL groups" ((X and Y) or (Z and W)) would need one
-- chain PER term and therefore one visual per term, which double-renders translucent
-- tints (measured in game: 25% -> 44% -> 58% over one, two and three chains), so it is
-- DISTRIBUTED into the first form by distributeTerms below rather than rendered as
-- written. Both shapes therefore draw through a single chain.
--
-- ☠ DEFINED ABOVE unionIdentity ON PURPOSE. Its caller is a `local function` too, so a
-- definition placed after it compiles the name as a GLOBAL — nil at call time, and a
-- runtime error the syntax check cannot see. That is exactly how it shipped first.
--
-- Absent `conditions` = the legacy flat `triggers` list = a single OR group. Nothing
-- about existing records changes.
-- ============================================================
local AD_MAX_CONDITION_GROUPS = 5   -- author-facing groups
local AD_MAX_CHAIN_LINKS      = 9   -- links the chain may end up with AFTER compiling

-- Union one group's entries into a single include map (the free OR).
local function groupIdentity(spec, entries)
    if type(entries) ~= "table" then return nil end
    local map
    for _, name in ipairs(entries) do
        local f = DF:BuildADIdentityFilters(spec, name)
        if f and f.includeSpellIDs then
            map = map or {}
            for id in pairs(f.includeSpellIDs) do map[id] = true end
        end
    end
    return map
end

-- DISTRIBUTE an OR-of-ANDs into the AND-of-ORs the chain can actually render.
-- terms[i] is one AND-group, held as an array of its members' maps. The result is one
-- clause per combination taking a single member from each group:
--     (X and Y) or (Z and W)  ->  (X or Z) and (X or W) and (Y or Z) and (Y or W)
-- Logically identical, one chain, ONE visual — which is the whole point. Rendering the
-- un-distributed form would mean a chain per term and therefore a visual per term, and a
-- translucent tint drawn twice composites to a darker one (measured in game 2026-08-09,
-- 25% -> 44% -> 58%). So this is not an optimisation, it is the only correct render.
--
-- Clause count is the PRODUCT of the group sizes, which grows fast (2x2 = 4, 3x2 = 8,
-- 2x3 = 9). Over the cap returns nil + the count so the editor can refuse the expression
-- up front rather than render a truncated — and therefore WRONG — conjunction.
local function distributeTerms(terms, cap)
    local total = 1
    for _, t in ipairs(terms) do
        total = total * #t
        if total > cap then return nil, total end
    end
    local clauses, idx = {}, {}
    for i = 1, #terms do idx[i] = 1 end
    while true do
        local map = {}
        for i = 1, #terms do
            for id in pairs(terms[i][idx[i]]) do map[id] = true end
        end
        clauses[#clauses + 1] = map
        -- Odometer: advance the last group, carrying left when it wraps.
        local i = #terms
        while i >= 1 do
            idx[i] = idx[i] + 1
            if idx[i] <= #terms[i] then break end
            idx[i] = 1
            i = i - 1
        end
        if i < 1 then break end
    end
    return clauses, total
end

-- Resolve an effect's conditions into an ORDERED list of include maps, one per chain link.
--
-- `conditions.mode` alone fixes the shape — the groups are always the OPPOSITE operator, so
-- a per-group mode would be redundant (and a way to express nothing new):
--     mode = "ALL"  ->  groups are ORs   ->  (A or B) and (C or D)   -- renders directly
--     mode = "ANY"  ->  groups are ANDs  ->  (A and B) or (C and D)  -- distributed above
-- Between them that covers every two-level expression in either normal form.
--
-- Returns nil when there is no renderable chain: no conditions block, fewer than two
-- groups, an empty group, a group that resolves to no spells, or an expansion over the
-- link cap. Refusing beats rendering: an unresolvable group would silently widen the
-- conjunction to "ignore this condition", which is worse than showing nothing.
-- Second return is the would-be link count, for the editor's over-cap message.
-- ☠ `spec` MUST BE nil FOR AN OTHER-POOL WINNER. Other-pool identity is spec-INDEPENDENT
-- -- pickWinner already knows this and computes `local idSpec = (pool == 1) and spec or nil`
-- before resolving -- but all four callers here passed `spec` unconditionally, even though
-- each had `bestPool` in hand on the adjacent line for poolFilter.
--
-- The divergence is not theoretical: an Other-Buffs effect on a Restoration Druid triggered
-- by Lifebloom resolves to {33763, 419207, 1227806} through the nil-spec path that drives
-- bestMap and the dedup union, but to {33763} through SpellIDs.RestorationDruid here. The
-- buff row has already hidden the variant icon via dedup while the chain never lights for
-- it -- the aura becomes invisible everywhere. Same for Rejuvenation, Regrowth and
-- HolyPaladin's Dawnlight.
local function resolveConditions(spec, typeCfg, isSpecPool)
    if isSpecPool == false then spec = nil end
    local c = typeCfg.conditions
    if type(c) ~= "table" or type(c.groups) ~= "table" then return nil end
    local groups = {}
    for _, g in ipairs(c.groups) do
        if #groups >= AD_MAX_CONDITION_GROUPS then break end
        -- ☠ SKIP an empty group rather than refusing the whole expression. Adding a
        -- condition group creates it empty, so refusing here made the effect briefly
        -- unrenderable the instant the user pressed the button — and that mid-edit
        -- churn is what surfaced the identity-gate taint. A half-configured group
        -- simply does not constrain anything yet; the card still warns about it.
        if type(g) ~= "table" or type(g.triggers) ~= "table" then return nil end
        if #g.triggers > 0 then groups[#groups + 1] = g end
    end
    if #groups < 2 then return nil end   -- one group is just a plain union

    if c.mode == "ALL" then
        local links = {}
        for _, g in ipairs(groups) do
            local map = groupIdentity(spec, g.triggers)
            if not map or not next(map) then return nil end
            links[#links + 1] = map
        end
        return links, #links
    elseif c.mode == "ANY" then
        local terms = {}
        for _, g in ipairs(groups) do
            local t = {}
            for _, name in ipairs(g.triggers) do
                local f = DF:BuildADIdentityFilters(spec, name)
                -- Every member must resolve: dropping one from a conjunction would
                -- quietly turn "A and B" into "A".
                if not (f and f.includeSpellIDs and next(f.includeSpellIDs)) then return nil end
                t[#t + 1] = f.includeSpellIDs
            end
            terms[#terms + 1] = t
        end
        return distributeTerms(terms, AD_MAX_CHAIN_LINKS)
    end
    return nil
end

-- Union the includeSpellIDs of a frame-level indicator's triggers into one map.
-- Triggers are AD aura NAMES; no triggers => the owning aura name. Multi-trigger
-- degrades to OR-presence (union) — the accepted 12.1 tradeoff (AND / duration
-- priority need remaining-time reads, unportable; P4.6). Read-free (static config).
local function unionIdentity(spec, auraName, typeCfg)
    local triggers = typeCfg.triggers
    local map
    -- Condition groups supersede the flat list. This union is only the "does this effect
    -- resolve to anything at all" answer pickWinner needs, plus the tuning signature —
    -- the CHAIN is rebuilt from resolveConditions by the consumer. The two shapes can
    -- share a union (ALL{A,B} and ANY{A,B} union identically), so the chain length is
    -- folded into the STRUCT signature to keep them apart; a mode change rebuilds.
    local links = resolveConditions(spec, typeCfg)
    if links then
        for _, m in ipairs(links) do
            map = map or {}
            for id in pairs(m) do map[id] = true end
        end
        return map
    end
    -- ★ typeCfg rides along as the MUTE CARRIER: the Tracked IDs ticks store
    -- mutedSpellIDs on this same sub-table, and BuildADIdentityFilters narrows by
    -- whatever table it is handed (see narrowByPlacementMutes). Ids are globally
    -- unique, so one mute set correctly narrows every trigger's contribution too.
    -- ☠ The CONDITIONS path above deliberately takes no mutes — narrowing one link
    -- of an ALL chain changes what the chain means, and the card hides the ticks
    -- for condition-driven effects for the same reason.
    -- The second return is "empty BY CHOICE": every id muted is a deliberate
    -- match-nothing, and callers must not fire the unresolved-aura warning on it.
    local sawMuted
    if triggers and #triggers > 0 then
        for _, name in ipairs(triggers) do
            local f, mutedEmpty = DF:BuildADIdentityFilters(spec, name, typeCfg)
            if f and f.includeSpellIDs then
                map = map or {}
                for id in pairs(f.includeSpellIDs) do map[id] = true end
            end
            sawMuted = sawMuted or mutedEmpty
        end
    else
        local f, mutedEmpty = DF:BuildADIdentityFilters(spec, auraName, typeCfg)
        if f then map = f.includeSpellIDs end
        sawMuted = mutedEmpty
    end
    return map, ((not map) and sawMuted) or nil
end

local function auraHasTrackedIndicator(auraCfg)
    if type(auraCfg) ~= "table" then return false end
    local inds = auraCfg.indicators
    if inds then
        for _, ind in ipairs(inds) do
            -- Bars ignore missing mode entirely (no duration data when absent — legacy
            -- Engine.lua:510), so a bar always renders present and always dedups.
            if ind.enabled ~= false and not ind.othersOnly
                and (ind.type == "bar" or not ind.showWhenMissing) then return true end
        end
    end
    local hb, bg, bd = auraCfg.healthbar, auraCfg.background, auraCfg.border
    if hb and hb.enabled ~= false and not hb.othersOnly and not hb.showWhenMissing then return true end
    if bg and bg.enabled ~= false and not bg.othersOnly and not bg.showWhenMissing then return true end
    if bd and bd.enabled ~= false and not bd.othersOnly and not bd.showWhenMissing then return true end
    -- Text colour-by-cover (recovered): a present-mode name/health text indicator is a
    -- rendering visual, so it dedups. SWM-flagged text renders nothing (unsupported).
    local nt, ht = auraCfg.nametext, auraCfg.healthtext
    if nt and nt.enabled ~= false and not nt.othersOnly and nt.color and not nt.showWhenMissing then return true end
    if ht and ht.enabled ~= false and not ht.othersOnly and ht.color and not ht.showWhenMissing then return true end
    return false
end

-- Union everything a record's TRACKED blocks actually match into `out`.
--
-- ☠ NOT just the owning aura name. An effect fires on its TRIGGERS -- and now on whole
-- condition groups, each of which can hold several spells or an entire filter -- so
-- keying dedup off the record's name hid only the first spell and left every other
-- trigger's icon on the bar beside a visual that was already representing it. That gap
-- predates conditions but was near-invisible while multi-trigger was rare; it is the
-- common case now.
--
-- Gating is PER BLOCK, not per record, so one othersOnly or show-when-missing block can
-- no longer drag a whole record's spells into the union (or keep them out of it). Each
-- block resolves through the same unionIdentity the RENDER path uses, so what dedup
-- hides and what the effect shows cannot drift apart.
local AD_FRAME_EFFECT_KEYS = { "healthbar", "background", "border", "nametext", "healthtext" }

local function unionTrackedIdentity(spec, auraName, auraCfg, out)
    if type(auraCfg) ~= "table" then return out end
    local function add(cfg)
        local map = unionIdentity(spec, auraName, cfg)
        if not map then return end
        out = out or {}
        for id in pairs(map) do out[id] = true end
    end
    local inds = auraCfg.indicators
    if inds then
        for _, ind in ipairs(inds) do
            -- Bars ignore missing mode (no duration data when absent), so a bar always
            -- renders present and always dedups.
            if ind.enabled ~= false and not ind.othersOnly
                and (ind.type == "bar" or not ind.showWhenMissing) then
                add(ind)
            end
        end
    end
    for _, key in ipairs(AD_FRAME_EFFECT_KEYS) do
        local c = auraCfg[key]
        if type(c) == "table" and c.enabled ~= false and not c.othersOnly
            and not c.showWhenMissing then
            -- Text colour-by-cover renders nothing without a colour, so it tracks nothing.
            if (key ~= "nametext" and key ~= "healthtext") or c.color then
                add(c)
            end
        end
    end
    return out
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

    local union
    if specAuras then
        for auraName, auraCfg in pairs(specAuras) do
            union = unionTrackedIdentity(spec, auraName, auraCfg, union)
        end
    end

    -- OTHER BUFFS pool (B1): spec-independent records (adDB.otherAuras, flat
    -- name -> cfg map) join the union exactly like spec auras — same tracked-
    -- indicator gate (eye-aware), identity resolved pool-agnostically (nil spec:
    -- ad-hoc "#<id>" -> SpellDB by name; the per-spec Config tables never apply).
    local otherAuras = adDB.otherAuras
    if otherAuras then
        for auraName, auraCfg in pairs(otherAuras) do
            -- ☠ COUNT, don't compare references. unionTrackedIdentity adds into the table it
            -- is given and returns the SAME table, so `union ~= before` only ever detected the
            -- very first allocation — every later record tripped the warning whether or not it
            -- resolved. Contribution has to be measured, not inferred from identity.
            local added = false
            local probe = unionTrackedIdentity(nil, auraName, auraCfg, nil)
            if probe and next(probe) then
                added = true
                union = union or {}
                for id in pairs(probe) do union[id] = true end
            end
            -- A tracked other-pool record that contributed NOTHING means an unresolvable
            -- name, which the pool's naming contract forbids.
            if not added and auraHasTrackedIndicator(auraCfg) then
                warnOtherUnresolved(auraName)
            end
        end
    end

    -- FILTER GROUPS (A5): a filter group renders every spell of its linked registry
    -- filters on the frame, so its resolved include map joins the dedup union (the
    -- buff row hides what the group shows). Eye-hidden groups (`enabled == false`)
    -- render nothing and contribute nothing — their buff-row icons come back. Only
    -- kind "include" maps count ("all" = empty selection renders nothing; "exclude"
    -- is unreachable from the group UI and skipped by the render path too).
    -- Both group stores contribute: the spec-keyed groups AND the flat
    -- spec-independent otherLayoutGroups (Other Buffs tab) — a filter group
    -- renders the same spells whichever tab owns it, so the row hides them
    -- identically. Same eye gate, same version-keyed resolve cache.
    -- othersOnly groups stay OUT of the union (mirror auraHasTrackedIndicator):
    -- their container shows only OTHERS' casts, so the player's own cast must
    -- keep its buff-row icon. Only the flat-store UI offers the flag; the gate
    -- reads both stores identically (spec-store parity).
    local R = DF.FilterRegistry
    if R then
        local specGroups = adDB.layoutGroups and adDB.layoutGroups[spec]
        for g = 1, 2 do
            local groups = (g == 1) and specGroups or adDB.otherLayoutGroups
            if groups then
                for _, group in ipairs(groups) do
                    if type(group) == "table" and group.kind == "filter" and group.enabled ~= false
                        and not group.othersOnly then
                        local res = resolveFilterGroup(R, group)   -- version-cached, no re-resolve
                        if res.kind == "include" and res.map then
                            for id in pairs(res.map) do
                                union = union or {}   -- only allocate when the map has entries
                                union[id] = true
                            end
                        end
                    end
                end
            end
        end
    end
    return union   -- nil when nothing is tracked -> caller unions nothing
end

-- ============================================================
-- DEBUFF-ROW CLAIM SET  (C1 — the row-skip half of debuff-group dedup)
-- The union of every ENABLED debuff group's selected categories for the frame's
-- ACTIVE preset — keys boss / role / priority / crowdControl / raid /
-- dispellable. The debuff ROW (DriveDebuffFactory) passes this into
-- BuildDirectDebuffFilters so a category an AD debuff group displays is dropped
-- from the row (no double render). Gate chain mirrors GetADTrackedSpellIDs
-- exactly: AD enabled for the frame, factory owns AD for this db, preset
-- enabled, spec resolvable (SyncFrame tears every AD container down without a
-- spec, so nothing renders and nothing may be claimed). Eye-hidden groups
-- (`enabled == false`) render nothing and claim nothing. Dispellable claims are
-- mode-AGNOSTIC by design (a group claiming dispellable claims the category
-- whatever mode either side runs — simplest rule). NO CYCLE by construction:
-- this reads group.selection tables only — it never calls the record resolver,
-- and the AD facade path (buildDebuffGroupRecords below) never consults claims.
local CLAIMABLE_CATEGORIES = { "boss", "role", "priority", "crowdControl", "raid", "dispellable" }
function DF:GetClaimedDebuffCategories(frame, db)
    if not frame then return nil end
    if not (DF.IsAuraDesignerEnabled and DF:IsAuraDesignerEnabled(frame)) then return nil end
    if not (DF.FactoryOwnsAD and DF:FactoryOwnsAD(db)) then return nil end

    local adDB = DF.ResolveAuraDesigner and DF:ResolveAuraDesigner(frame)
    if not adDB or not adDB.enabled then return nil end

    local Engine = DF.AuraDesigner and DF.AuraDesigner.Engine
    local spec = Engine and Engine.ResolveSpec and Engine:ResolveSpec(adDB)
    if not spec then return nil end

    local groups = adDB.debuffGroups
    if not groups then return nil end

    local claimed
    for _, group in ipairs(groups) do
        if type(group) == "table" and group.enabled ~= false and type(group.selection) == "table" then
            local sel = group.selection
            for i = 1, #CLAIMABLE_CATEGORIES do
                local k = CLAIMABLE_CATEGORIES[i]
                if sel[k] then
                    claimed = claimed or {}
                    claimed[k] = true
                end
            end
        end
    end
    return claimed   -- nil when no group claims anything -> row builds untouched
end

-- ============================================================
-- HELPERS
-- ============================================================

-- Slot/group filter string for an indicator/effect config (read-free). othersOnly =
-- show only OTHERS' casts of the spell, via the native "!PLAYER" negation — the exact
-- "|!TOKEN" mechanism the debuff row's dedup filters already ship (Features/Auras.lua
-- BuildDirectDebuffFilters appends "|!RAID" etc.); AuraUtil.IsValidFilterString accepts
-- negated standard tokens, and a rejected string degrades to a skipped group + DebugWarn
-- (AuraContainer build loop). STRUCTURAL: the filter string is declared at AddAuraGroup/
-- AddAuraSlot, so every consumer folds it into its struct sig (toggling rebuilds).
-- NOTE: the on-apply SOUND path can't honour othersOnly (AddAuraAppliedSound has no
-- caster filter) — sounds fire for any caster's application.
-- mine = the SPEC pool (My Buffs tab): ONLY the player's own casts light anything
-- there (maintainer decision 2026-07-16, overriding the anyone-cast resolution in
-- design doc §11.1 — "it's literally in the name"; a tester with two same-class
-- players saw indicators fire for the other player's buffs). The OTHER pool is
-- unchanged: anyone-cast, or "HELPFUL|!PLAYER" when the effect is othersOnly.
-- ACCEPTED consequence: the buff-bar dedup exclude map is caster-agnostic, so with
-- Hide Duplicate Buffs on, OTHER players' casts of a My-Buffs-tracked spell render
-- nowhere (not on the PLAYER-filtered indicator, not on the bar). Narrowing the
-- dedup to the player's own casts is a tracked follow-up, not this hotfix.
-- SELF_ONLY: a third `mine` value, not a boolean. See resolvePoolMode below for what
-- it means and why it exists; checked FIRST because a truthy string would otherwise
-- fall into the My Buffs branch, and it deliberately ignores othersOnly (an Other-pool
-- concept that has no meaning for a spell on your own frame).
local SELF_ONLY = "selfOnly"

local function poolFilter(cfg, mine)
    if mine == SELF_ONLY then return "HELPFUL" end
    if mine then return "HELPFUL|PLAYER" end
    return (type(cfg) == "table" and cfg.othersOnly) and "HELPFUL|!PLAYER" or "HELPFUL"
end

-- ☠ SELF-ONLY AURAS — the ONE case where My Buffs drops its caster filter.
-- A few buffs land on the CASTER but are credited to the unit they were cast on:
-- Symbiotic Relationship sits on the druid with `sourceUnit` = the linked ally
-- (field-confirmed, lab 029736dd). "HELPFUL|PLAYER" can therefore never pass one, so
-- a My Buffs indicator for such a spell has never rendered on the player's own frame
-- at all — not a regression, it has never worked. Config's SelfOnlySpellIDs documented
-- exactly this and was read nowhere; this is what it was written for.
--
-- ☠ SCOPED TO THE PLAYER'S OWN FRAME, deliberately. Relaxing everywhere would light
-- your indicator from another player's cast on an ally, which is precisely the
-- complaint that made the spec pool player-only ("it's literally in the name",
-- 2026-07-16). UnitIsUnit rather than `unit == "player"`: in raid frames the player's
-- own frame is a raidN unit, so the string test would silently never match.
--
-- ⚠ ACCEPTED over-match: one container has one filter string, so on your own frame the
-- slot now matches the aura whoever cast it — a second druid linking to YOU would light
-- it. Strictly better than never rendering, and not narrowable without splitting the
-- container. Flagged to the lab for a field check.
--
-- Returns `mine` untouched for everything else, so the Other pool and every ordinary
-- My Buffs spell keep byte-identical filter strings. ☠ The result is STRUCTURAL (it
-- feeds the struct/tuning sigs as well as the container config) — resolve it ONCE per
-- aura and pass that value to both, or the sigs disagree with the config and the
-- container rebuilds on every update forever.
local function resolvePoolMode(spec, auraName, frame, mine)
    if not mine then return mine end
    local Adapter = DF.AuraDesigner and DF.AuraDesigner.Adapter
    if not (Adapter and Adapter.IsSelfOnlyAura and Adapter:IsSelfOnlyAura(spec, auraName)) then
        return mine
    end
    local unit = frame and frame.unit
    if unit and UnitIsUnit and UnitIsUnit(unit, "player") then return SELF_ONLY end
    return mine
end

-- Stable signature of an includeSpellIDs map (sorted IDs). Changing the set is a TUNING
-- delta, not a structural one: candidateFilters are declared at build but the native
-- SetAuraGroupCandidateFilters / SetAuraSlotCandidateFilters mutate them in place, so a
-- selection edit rides ApplyTuning. (It WAS structural before Wave 1; every consumer of
-- this sig now feeds a tuningSig.)
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
    -- Direct concat, not tconcat over a throwaway array: the four-element table was
    -- pure garbage, and a single chained concat compiles to ONE concat over a
    -- register range, so this allocates the result string and nothing else. colSig
    -- runs several times per indicator per UNIT_AURA (once per border colour key),
    -- which put it at 3.5% of trash allocation on its own.
    return tostring(r) .. "," .. tostring(g) .. "," .. tostring(b) .. "," .. tostring(a)
end

-- Does this client have the engine's refresh-window driver at all? Capability-gated
-- everywhere: without it the pandemic variant is never emitted, so an ungated colour can
-- never masquerade as a refresh cue.
local function pandemicCapable()
    local AC = DF.AuraContainer
    return (AC and AC.HasPandemic and AC.HasPandemic()) and true or false
end

-- Does this config ask for a second, pandemic-window colour?
-- ⚠ NOT HEALTH-BAR ONLY ANY MORE, and this header said it was long after it stopped being
-- true. Health Bar Color, Background Color and Border all route through here. The original
-- objection was that the second wash needs a FRAME LEVEL to draw over its own base, and
-- only the health-bar band had one spare — that was answered by putting both washes on the
-- SAME BUTTON as sibling regions ordered by draw sublevel, which costs no level at all
-- (see the PANDEMIC COVER note in Frames/AuraContainer.lua). The constraint was real; the
-- solution removed it, and only the comment stayed behind.
local function wantsPandemicColor(cfg)
    return (cfg and cfg.pandemicColorEnabled and cfg.pandemicColor and pandemicCapable()) and true or false
end

-- Health-bar overlay alpha per mode — the exact semantics of the legacy Indicators:ApplyHealthBar (that module is gone;
-- this is now the only implementation, so the comparison is against behaviour, not source)
-- (Indicators.lua:1325-1329), read from CONFIG only:
--   replace: overlay opacity = the colour picker's alpha.
--   tint:    overlay opacity = blend slider x colour alpha (so the bar colour shows through).
-- Used by the FLAT whole-bar tint path and to derive the fill cover's alpha. The cover path
-- expresses current-health-fill tracking read-free (a texture anchored to the real fill
-- region), so tintWholeBar=false is no longer a divergence.
local function healthbarBlend(mode, blendCfg, a)
    if mode == "replace" then return a end
    return (blendCfg or 0.5) * a
end

-- ============================================================
-- LEVEL CONSTANTS (single retune point — bug #1027)
-- The container nests anchor -> native AuraContainer -> AuraSlot button, each a default
-- +1 child, and the painted regions hang off the BUTTON — so an overlay's visual lands at
--     anchor level + frameLevelOffset + 2
-- (same measured arithmetic as Frames/Create.lua:672-679). A condition-chain GATE hands
-- its mirror host back one level deeper still (a plain child frame of the button):
--     anchor level + frameLevelOffset + 3
-- That +2/+3 is derived from the code's default-child nesting, not from a live /fstack —
-- if an in-game check disagrees, retune the two constants below and nothing else.
--
--   * AD_HEALTHBAR_COVER_OFFSET seats the Health Bar Color cover (both variants: fill
--     cover and whole-bar tint). Intended seat is healthBar+1 — above the real fill,
--     BELOW the attached absorb bar at healthBar+2 (Bars.lua:790/:1036) and the +2 power
--     bar, exactly where the legacy tint sat — so -1 + 2 nesting = +1. The old value (1)
--     landed the cover at healthBar+3, occluding the absorb shield (bug #1027).
--   * AD_CHAIN_GATE_OFFSET makes a chain gate LEVEL-NEUTRAL: -3 + 3 nesting parks the
--     gate's mirror host at the anchor's own level, so the FINAL visual link — created on
--     that host with the consumer's own offset — seats exactly where the flat path puts
--     it, for ANY chain length. If chained effects render N levels above their flat twin
--     in game, lower this by N. The gate paints nothing itself, so its own level only has
--     to be legal — ApplyZOrder clamps at 0, which can lift a gate (and therefore the
--     visual) a level or two ONLY on a unit frame whose own level is under 3.
local AD_HEALTHBAR_COVER_OFFSET = -1
local AD_CHAIN_GATE_OFFSET = -3
-- Text-mirror chain gates keep the mirror-host band (+30): the visual link there is
-- itself a mirror host that must clear the TD overlay (~frame+25), and the gates always
-- sat beside it. Deliberately NOT neutralised with the others — text chains render
-- correctly today and their band has headroom; see buildMirrorHostConfig.
local AD_TEXT_CHAIN_GATE_OFFSET = 30
-- ============================================================

-- Build an OVERLAY-TINT container config (health-bar tint, background tint). mode="overlay":
-- the slot covers the host region and its tint texture (child of the slot) inherits the
-- slot's secret visibility; DF.AuraContainer handles SetEnabled-last + combat deferral.
-- levelOffset is added on top of the caller's anchor level; the tint texture then lands a
-- further +2 above (anchor -> container -> slot nesting). Callers pick the anchor + offset so
-- the tint seats correctly: health-bar tint hosts on frame.healthBar with
-- AD_HEALTHBAR_COVER_OFFSET (tint at healthBar+1 — above the fill, below the attached
-- absorb bar); background tint hosts on a frame parked at healthBar-3 with offset 0 (tint
-- at healthBar-1 — above frame.background, below every bar). See the call sites for the math.
-- `opts` carries the two cross-cutting tint options (nil for a lone tint):
--   * pandemicColor — adds a SECOND cover on the SAME button in this colour, whose Shown
--     aspect is handed to the engine's refresh-window driver (AuraContainer bindNative,
--     PANDEMIC COVER). STRUCTURAL BY PRESENCE: the region can only be created in the
--     secure init, so callers must fold "has one" into their struct signature or enabling
--     it would never build the region. The colour VALUE restyles live.
--   * sublevel — the draw-order key for stacked tints. COSMETIC (re-applied on every
--     style pass), so a priority reorder restyles rather than rebuilds.
local function buildOverlayTintConfig(unit, map, r, g, b, blend, levelOffset, filter, opts)
    return {
        unit = unit,
        mode = "overlay",
        -- Buff-only for now: the AD spell-ID whitelist (Config.SpellIDs) carries no
        -- buff/debuff classification and every configured entry is a helpful aura. A
        -- harmful spell-ID map is inert on friendly party/raid frames anyway (the assist
        -- gate), so harmful triggers on enemy/arena frames are deferred to a later pass.
        -- Callers pass poolFilter(cfg) — "HELPFUL|!PLAYER" when the effect is othersOnly.
        filter = filter or "HELPFUL",
        candidateFilters = { includeSpellIDs = map },
        enabled = true,
        frameLevelOffset = levelOffset,
        style = { overlay = { tintColor = { r, g, b, blend },
            -- Second cover on the SAME button, gated by the engine's refresh window.
            tintPandemicColor = opts and opts.pandemicColor or nil,
            sublevel          = opts and opts.sublevel or nil } },
    }
end

-- Build a HEALTH FILL COVER container config (health-bar indicator, replace/tint fill).
-- `clampTo` is the REAL health bar's fill texture. The cover is a plain texture anchored to
-- it, so it inherits the fill's rect and tracks health with NO feed and NO reads -- the aura
-- frame's access restrictions (DenyTaintedAccessWhenAurasAreSecret) forbid driving a
-- duplicate StatusBar outright, which is why the earlier mirror could never work. See the
-- HEALTH FILL COVER note in Frames/AuraContainer.lua.
-- Level: AD_HEALTHBAR_COVER_OFFSET + the 2-level container nesting = healthBar+1 (above
-- the real fill, below the +2 absorb/power bars), exactly where the legacy tint sat. This
-- comment used to claim "offset 1 = healthBar+1" — wrong by the nesting: offset 1 landed
-- the cover at healthBar+3, over the absorb shield (bug #1027). Colour/texture/alpha are
-- static config.
local function buildHealthFillConfig(unit, map, r, g, b, alpha, texture, clampTo, filter, opts)
    return {
        unit = unit,
        mode = "overlay",
        filter = filter or "HELPFUL",
        candidateFilters = { includeSpellIDs = map },
        enabled = true,
        frameLevelOffset = (opts and opts.levelOffset) or AD_HEALTHBAR_COVER_OFFSET,
        style = { overlay = { healthFill = {
            texture = texture, color = { r, g, b }, alpha = alpha, clampTo = clampTo,
            -- Second cover on the SAME button, gated by the engine's refresh window.
            pandemicColor = opts and opts.pandemicColor or nil,
        },
            sublevel = opts and opts.sublevel or nil } },
    }
end

-- Build a whole-frame BORDER container config. mode="overlay": the slot covers the unit
-- frame; DF.Border (secretRect, static art only — animations are forbidden on native
-- buttons and stripped engine-side) renders as a child of the slot and inherits the slot's
-- secret visibility. levelOffset 10 lifts the ring above the class border (frame+10 inside
-- the slot) so it reads as an AD border, mirroring the legacy draw-above default
-- (Indicators.lua:1145-1147). Z-order polish is a P4.7 concern.
-- drawAbove (the indicator's `drawAboveFrameBorder`, default true) picks which side of the
-- frame's own class/role border this ring lands on. That border is a DF.Border child at
-- frame+10 (Frames/Border.lua:69), so 10 put the two at the SAME level and left the order to
-- creation sequence -- the toggle's whole point. 11 = definitively above (the legacy
-- draw-above default), 9 = definitively tucked underneath. Wired 2026-07-25; the flag rides
-- the border structSig so toggling it rebuilds with the new offset.
-- `pandemicSpec` renders a SECOND ring on the same button in the pandemic colour,
-- gated by the engine's refresh window (AuraContainer: PANDEMIC BORDER TWIN).
-- Structural by presence, like the tint covers: its holder is created in the secure init.
local function buildBorderConfig(unit, map, spec, filter, drawAbove, pandemicSpec)
    return {
        unit = unit,
        mode = "overlay",
        filter = filter or "HELPFUL",
        candidateFilters = { includeSpellIDs = map },
        enabled = true,
        frameLevelOffset = (drawAbove ~= false) and 11 or 9,
        style = { border = { spec = spec, pandemicSpec = pandemicSpec } },
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
local function buildMirrorHostConfig(unit, map, onHost, filter)
    return {
        unit = unit,
        mode = "overlay",
        filter = filter or "HELPFUL",
        candidateFilters = { includeSpellIDs = map },
        enabled = true,
        frameLevelOffset = 30,
        style = { overlay = { mirrorHost = { onHost = onHost } } },
    }
end

-- Resolve the DF.Border spec for an AD border indicator from its CONFIG block (never a
-- live aura), mirroring the legacy Indicators:ApplyBorderToOverlay (module removed): canonical keys via BuildSpec (the
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
    -- GRADIENT: this used to carry a "KNOWN DEGRADATION (GRADIENT -> solid)" note claiming the
    -- overlay border cannot gradient because the slot's rect is SECRET and "gradient rendering
    -- needs a resolved rect to compute its direction+extent". ★ RE-READ 2026-07-25 -- that
    -- reasoning does not survive the source:
    --   * DF.Border's gradient path MEASURES NOTHING. It is SetColorTexture(1,1,1,1) then
    --     SetGradient(direction, a, b) on edges positioned by SetPoint. There is no
    --     GetWidth / GetHeight / GetLeft anywhere in Apply -- SetGradient ramps C-side across
    --     whatever the texture already spans, so an unresolved rect is not an input.
    --   * Apply's gradient branch is gated on `style == "GRADIENT" and gradient and CreateColor`
    --     with NO _solidOnly check (Frames/Border.lua), so the slot's solidOnly flag never
    --     blocked the paint in the first place.
    --   * solidOnly is about secret COLOURS, not rects -- it skips CreateColor/SetGradient
    --     because those taint on secret values (debuff dispel tints). The gradient pickers are
    --     STATIC config, and Border.lua:195 skips the ctx colour paths entirely for GRADIENT,
    --     so no secret can reach them. secretRect is the rect flag, and only TEXTURE needs it.
    -- The three gradient controls are therefore UNFROSTED (AuraDesigner/Options.lua) to find out
    -- what actually happens. If it still renders solid in game, the real cause is something not
    -- yet identified -- record it here and re-frost, rather than restoring the rect explanation.
    return spec
end

-- Order-stable cosmetic signature of a DF.Border spec (scalars + NESTED subtables).
-- Field-name-agnostic so it survives BuildSpec schema tweaks; any change → ApplyStyle
-- (in-place restyle), never a rebuild (only the identity set is structural).
--
-- ★ RECURSES (fixed 2026-07-25). This used to serialise only ONE level and silently drop
-- any table it found inside a subtable, which made whole settings invisible to the sig:
-- spec.gradient holds startColor/endColor as COLOUR TABLES, so editing a gradient colour
-- left coSig unchanged, ApplyStyle never ran, and the border kept the colours it was first
-- painted with (field-caught: "I can see the gradient but not the colours I set" -- the
-- direction dropdown worked, because direction is a scalar). spec.shadow.color had the
-- same latent hole. Depth-capped purely as a cycle guard; real specs are 2-3 deep.
-- ☠ PER-DEPTH SCRATCH, NOT ONE SHARED PAIR — subSig RECURSES.
-- The two throwaway tables per call (keys + parts) ran per indicator per
-- UNIT_AURA inside syncPlacedPool, a walk whose whole point is to be
-- allocation-free; subSig alone was 2.1% of trash allocation and it recurses up
-- to four levels, so a single shared scratch would have a nested call wipe its
-- caller's half-built list. Depth is hard-bounded at 4 by the guard below, so one
-- pair per level is both sufficient and safe.
local subSigKeys, subSigParts = {}, {}
local function subSig(t, depth)
    depth = depth or 1
    local keys = subSigKeys[depth]
    if not keys then keys = {}; subSigKeys[depth] = keys else wipe(keys) end
    for kk in pairs(t) do keys[#keys + 1] = kk end
    tsort(keys)
    local parts = subSigParts[depth]
    if not parts then parts = {}; subSigParts[depth] = parts else wipe(parts) end
    for _, kk in ipairs(keys) do
        local v = t[kk]
        local tv = type(v)
        if tv == "table" then
            if depth < 4 then
                parts[#parts + 1] = tostring(kk) .. "={" .. subSig(v, depth + 1) .. "}"
            end
        elseif tv ~= "function" and tv ~= "userdata" and tv ~= "thread" then
            parts[#parts + 1] = tostring(kk) .. "=" .. tostring(v)
        end
    end
    return tconcat(parts, ",")
end
-- Pixel-scale token folded into every cosmetic signature that gates a restyle of
-- pixel-snapped geometry (border thickness, art insets, quantized layouts). At
-- login the builds can run BEFORE UIParent's scale settles — the pixel-scale
-- cache then changes underneath values already baked with the stale one, and
-- nothing restyled (coSig unchanged) until the user touched any setting
-- (field-caught: AD icon borders uneven at every reload, perfect after any
-- toggle). With the cache in the sig, the settle flips every coSig and the next
-- drive replays exactly what the manual toggle did. Rounded so float noise
-- can't flap the sigs. Rides into placedCoSig / barCoSig / filterGroupCoSig /
-- the placed-missing inline sig via placedBorderRawSig, and into the
-- frame-level border sigs via borderSpecSig.
local function ppSigToken()
    local ps = DF.GetPixelScale and DF:GetPixelScale()
    return ps and tostring(math.floor(ps * 100000 + 0.5)) or "?"
end

local function borderSpecSig(spec)
    if type(spec) ~= "table" then return "" end
    local keys = {}
    for kk in pairs(spec) do keys[#keys + 1] = kk end
    tsort(keys)
    local parts = { "pps=" .. ppSigToken() }
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
-- auras for this spec AND the spec-independent Other Buffs pool (adDB.otherAuras) —
-- candidates from BOTH pools compete in the SAME pick, so there is one winner per effect
-- type per frame overall. Consumers: the Priority-mode border (one ring per Draw Above
-- seat) and the text-mirror colours (one cover colour per element). Health-bar /
-- background tints used to pick here too — they are MULTI now (every configured tint
-- renders on its own presence-gated container; see collectFrameTints), because a static
-- pick meant a lower-priority buff could never colour the bar even when it was the ONLY
-- buff present — presence is secret, so the pick cannot ask what is actually on the unit.
-- priority is static config (Engine.lua:502, default 5); ties broken by
-- pool (spec pool wins — byte-identical to the old name order when the other pool is empty)
-- then aura name, for a deterministic, non-flapping winner. `validate(typeCfg)` gates which
-- blocks count (e.g. border must be enabled). Read-free.
-- Hidden blocks (eye toggle, `enabled == false`; nil/true = shown for legacy records) never
-- compete — the pick falls to the next candidate, or nothing.
-- Returns the winner's STORE KEY (OTHER_PREFIX-prefixed for other-pool winners, so store
-- entries never collide with a same-named spec-pool aura), its type config, map, priority.
local function pickWinner(spec, specAuras, otherAuras, typeKey, validate)
    local bestName, bestCfg, bestMap, bestPrio, bestPool
    for pool = 1, 2 do
        local auras = (pool == 1) and specAuras or otherAuras
        -- Other-pool identity is spec-INDEPENDENT: nil spec skips the per-spec Config
        -- tables inside BuildADIdentityFilters (ad-hoc "#id" -> SpellDB by name).
        local idSpec = (pool == 1) and spec or nil
        if auras then
            for auraName, auraCfg in pairs(auras) do
                local typeCfg = (type(auraCfg) == "table") and auraCfg[typeKey]
                if typeCfg and typeCfg.enabled ~= false and (not validate or validate(typeCfg)) then
                    local map, mutedEmpty = unionIdentity(idSpec, auraName, typeCfg)
                    -- mutedEmpty = every id unticked in Tracked IDs: a choice, not a data problem.
                    if not map and not mutedEmpty then warnOtherUnresolved(auraName, (pool == 2) and "Other Buffs" or "Spec") end
                    if map then
                        local prio = auraCfg.priority or 5
                        if (not bestName)
                            or prio > bestPrio
                            or (prio == bestPrio and (pool < bestPool
                                or (pool == bestPool and auraName < bestName))) then
                            bestName, bestCfg, bestMap, bestPrio, bestPool = auraName, typeCfg, map, prio, pool
                        end
                    end
                end
            end
        end
    end
    local bestKey = bestName and ((bestPool == 2) and (OTHER_PREFIX .. bestName) or bestName)
    -- bestPool (1 = spec/My Buffs, 2 = other) drives the caster filter — see poolFilter.
    return bestKey, bestCfg, bestMap, bestPrio, bestPool
end

-- Tear down every container in a per-type store that is not the current winner (winner
-- changed, aura de-configured, or the indicator was removed). Destroy is combat-safe.
-- Destroy everything an entry owns. A condition-chain entry holds N handles, not one —
-- released INNERMOST FIRST so a link is never orphaned by its host disappearing under it.
local function destroyEntry(entry)
    if not entry then return end
    local chain = entry.chain
    if chain then
        for i = #chain, 1, -1 do
            if chain[i] then chain[i]:Destroy() end
            chain[i] = nil
        end
        entry.chain = nil
    elseif entry.handle then
        entry.handle:Destroy()
    end
    entry.handle = nil
end

local function teardownExcept(store, keepName)
    for auraName, entry in pairs(store) do
        if auraName ~= keepName then
            destroyEntry(entry)
            store[auraName] = nil
        end
    end
end

-- ============================================================
-- CONDITION CHAIN
-- Link 1 hangs off the CONSUMER'S ANCHOR (the same parent its flat path Creates on);
-- every later link hangs off the previous link's slot-child host, so it can only be
-- visible when every outer link is. The LAST link carries the effect's real visual — the
-- rest are pure gates (a mirror host and nothing else), level-neutral by default so the
-- visual seats exactly where the flat path would put it (see AD_CHAIN_GATE_OFFSET).
--
-- ☠ BUILT LAZILY, and it has to be. A link's host frame does not exist until that link's
-- own aura is actually present (the native container creates slot buttons on demand), so
-- the inner links materialise as the outer buffs land and vanish with them. Consequences
-- every caller must respect:
--   * entry.handle is NIL until the whole chain has completed at least once. Guard every
--     ApplyStyle/Rebuild on it.
--   * The visual config is read through a CLOSURE at creation time rather than captured,
--     so a colour edited while the chain is incomplete is already correct when the final
--     link appears — no pending-style bookkeeping.
--   * onHost fires on every style pass, not just the first, so each host is stamped to
--     keep exactly one child link.
-- ============================================================
local function chainGateConfig(unit, map, filt, onHost, levelOffset)
    return {
        unit = unit,
        mode = "overlay",
        filter = filt or "HELPFUL",
        candidateFilters = { includeSpellIDs = map },
        enabled = true,
        -- Per-consumer, NOT a constant. This was a hardcoded 30 copied from the
        -- text-mirror consumer, on the reasoning that "the gate paints nothing itself so
        -- the exact level only has to be legal" — true of the gate, but the FINAL visual
        -- link is created ON the gate's mirror host and inherits its level as the base
        -- for its own offset. 30 here re-seated every chained effect ~30 levels above its
        -- flat twin (bug #1027: the AND-shaped Health Bar Color covered the absorb
        -- shield). Consumers now pass their band: AD_CHAIN_GATE_OFFSET (level-neutral)
        -- for the bar-adjacent effects, AD_TEXT_CHAIN_GATE_OFFSET for text mirrors.
        frameLevelOffset = levelOffset,
        style = { overlay = { mirrorHost = { onHost = onHost } } },
    }
end

-- entry.chain[i] fills in as the links materialise. The FINAL link's config comes from
-- entry.makeVisual, read at creation time — see the note in syncConditionChain for why it
-- must be the entry's copy and not a captured parameter.
--
-- ☠ anchor = the SAME parent the consumer's flat single-container path Creates on
-- (frame.healthBar for the health-bar cover, the background's parked anchor, `frame` for
-- border/text). Link 1 IS the visual when the chain is one link long, and is the level
-- base for every gate otherwise — anchoring it anywhere else re-seats the effect (level
-- AND overlay rect) purely by the SHAPE of its condition config, which was bug #1027.
-- gateOffset = the consumer's gate band (see chainGateConfig); nil defaults to
-- level-neutral, the correct seat for any future consumer.
local function buildConditionChain(entry, anchor, unit, links, filt, gateOffset)
    entry.chain = {}
    if gateOffset == nil then gateOffset = AD_CHAIN_GATE_OFFSET end
    local function makeLink(i, parent)
        if not parent then return end
        -- ☠ REPLACE, never accumulate. A parent link rebuilding (test-mode toggle, the
        -- provider rebirth sweep, any _rebuild) produces a FRESH slot host and re-fires
        -- onHost with dfChainLink unset — so this runs again for a link that already
        -- exists. Without this the old handle is overwritten in entry.chain, stays in the
        -- registry forever and keeps rendering, and destroyEntry can never reach it.
        for k = #entry.chain, i, -1 do
            if entry.chain[k] then entry.chain[k]:Destroy() end
            entry.chain[k] = nil
        end
        if entry.chain[#links] == nil then entry.handle = nil end
        if i == #links then
            local cfg = entry.makeVisual(links[i], filt)
            -- Links after the first live inside a slot, so their visibility is the
            -- parent's and reading their own is a secret-value taint.
            if i > 1 then cfg.parentDrivenVisibility = true end
            local h = DF.AuraContainer:Create(parent, cfg)
            entry.chain[i] = h
            entry.handle = h   -- the visual link is what ApplyStyle targets
            return
        end
        local gcfg = chainGateConfig(unit, links[i], filt,
            function(host)
                if not host or host.dfChainLink then return end
                host.dfChainLink = true
                makeLink(i + 1, host)
            end, gateOffset)
        if i > 1 then gcfg.parentDrivenVisibility = true end
        local h = DF.AuraContainer:Create(parent, gcfg)
        entry.chain[i] = h
    end
    makeLink(1, anchor)
    return entry.chain[1] ~= nil
end

-- One sync pass for a condition-chained effect. Returns true when it handled the effect,
-- false when there is no chain and the caller's normal single-container path should run.
--
-- ☠ NO TUNING PATH. A single-container effect swaps its include map in place, but a chain
-- has one map PER LINK and a link count that can move, so any identity change rebuilds the
-- whole chain. That is the honest trade: the cost lands only on an edit (chains are
-- configured rarely, not driven per frame), and the alternative is per-link tuning
-- bookkeeping over handles that may not exist yet — the lazy build means link 3 can be nil
-- when the edit arrives. Everything identity-shaped rides structSig; only cosmetics tune.
-- Release a chain entry whose config no longer resolves to one. MUST run before the
-- caller's single-container branch: that branch reads entry.handle, which is NIL for
-- every incomplete chain, and its struct sig will never match a chain sig — so it would
-- drive Rebuild against nil (hard error, every pass) or rebuild the final link in place
-- and strand the gate links above it. Reached by emptying or deleting a condition group.
local function dropChainEntry(store, key)
    local e = key and store[key]
    if e and e.chain then destroyEntry(e); store[key] = nil end
end

local function syncConditionChain(store, key, anchor, unit, links, filt, structSig, coSig,
                                  makeVisual, applyStyle, gateOffset)
    if not links then return false end
    -- ☠ UNIT IS PART OF THE SIGNATURE. Every link captures the unit at build time, and the
    -- SyncFrame retarget loop only walks entry.handle — it cannot see the gate links. Without
    -- the unit here a frame reassigned by roster churn keeps gates evaluating the OLD unit and
    -- the chain can never complete again. Folding it in rebuilds the chain on a retarget.
    local parts = { "chain=" .. #links, structSig, "f=" .. tostring(filt), "u=" .. tostring(unit) }
    for i = 1, #links do parts[#parts + 1] = includeSig(links[i]) end
    local chainSig = tconcat(parts, "|")

    local entry = store[key]
    if not entry then
        entry = { structSig = chainSig, coSig = coSig }
        store[key] = entry
    end

    -- ☠ REFRESH THE BUILDERS EVERY PASS, before anything else uses them. The consumers
    -- rebuild these closures each sync over that pass's colour/texture locals, and a chain
    -- link can materialise LONG after the pass that created the chain — so a link built
    -- from a captured closure would render whatever the config was when the chain started.
    -- Concretely: set up a chain, recolour the effect while not all its buffs are up, gain
    -- the buffs, and the visual appears in the OLD colour with coSig already matching, so
    -- nothing ever corrects it. Storing them on the entry makes "current" the only option.
    entry.makeVisual, entry.applyStyle = makeVisual, applyStyle

    if entry.structSig ~= chainSig or not entry.chain then
        destroyEntry(entry)
        entry.structSig, entry.coSig = chainSig, coSig
        buildConditionChain(entry, anchor, unit, links, filt, gateOffset)
    elseif entry.coSig ~= coSig then
        entry.coSig = coSig
        -- A live visual restyles now; one that has not appeared yet gets the new config
        -- from entry.makeVisual when it does.
        if entry.handle then applyStyle(entry.handle) end
    end
    return true
end

-- Same, for the one type that can legitimately hold several containers at once: border in
-- Stacked mode. keepSet is a name -> true lookup; everything else is torn down as usual.
local function teardownExceptSet(store, keepSet)
    for auraName, entry in pairs(store) do
        if not keepSet[auraName] then
            -- destroyEntry, not entry.handle: a CONDITION-CHAINED entry holds chain[1..n]
            -- and its handle is nil until the chain completes, so releasing only the handle
            -- drops the entry while its gate containers stay live and unreachable.
            destroyEntry(entry)
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

-- Stable per-indicator key (mirrors what Engine's key builder produced: "auraName#id"; Engine.lua no longer
-- has that helper -- it defines only ResolveSpec / ClearFrame / ForceRefreshAllFrames). keyPrefix is
-- "" for the spec pool, OTHER_PREFIX for the Other Buffs pool — one shared store, no
-- cross-pool collisions ("other:<name>#<id>" vs "<name>#<id>").
local function placedKey(keyPrefix, auraName, indicator)
    return keyPrefix .. auraName .. "#" .. tostring(indicator.id)
end

-- Build the DF.Border spec for a placed icon/square indicator from its CONFIG (read-free),
-- mirroring the legacy Indicators:ConfigureIcon's border block (module removed): canonical keys via BuildSpec, AD's
-- size = BorderSize (band thickness) + inset = -BorderInset (outward extension) semantics,
-- enabled gated on ShowBorder AND not hideIcon (a ring around a hidden icon looks broken),
-- translucent-black default colour. Returns nil when the border resolves off. Gradient
-- degrades to solid on the secret-anchored slot (P4.7 overlays the gradient control) — same
-- known casualty as the frame-level border. Border ANIMATIONS now run (the row container sets
-- config.adBorderAnim, so the SAFE_OVERLAY_ANIM allowlist recovers the DF-owned types); the LCG
-- glows stay stripped and are removed from the GUI dropdown (animExcludeTypes). knownWidth/
-- knownHeight are fed so DF_DASH lays its dash count out from the configured icon size instead
-- of the secret slot rect (mirror the frame-level border's frameWidth/Height feed).
-- knownSize (optional) overrides the fed DF_DASH geometry for callers whose slot size
-- doesn't live in indicator.size (filter/debuff groups feed group.iconSize).
-- Resolve one global-defaultable key for a placed indicator: instance -> global -> caller.
-- (`defs` is built by resolveDefs, much further down; this must be declared HERE, above the
-- first build* helper that calls it, or the call sites above the declaration would resolve
-- `defOf` as a nil GLOBAL and error at runtime — the parser cannot catch that.)
-- ☠ The SIGNATURES must call this too, never read indicator[key] raw. A sig that serialises
-- the raw (nil) value cannot move when the GLOBAL default changes, so SyncFrame sees no
-- delta, never restyles, and the new default sits in the profile doing nothing until an
-- unrelated edit or a /reload flushes it — the exact "works but needs a reload" shape
-- placedCoSig's durationBar comment already documents.
-- defs is nil on the GROUP path on purpose: GLOBAL_DEFAULT_MAP has no `group` entry, so
-- filter/debuff groups deliberately do not inherit these.
local function defOf(indicator, key, defs, caller)
    local v = indicator[key]
    if v ~= nil then return v end
    if defs then
        v = defs[key]
        if v ~= nil then return v end
    end
    return caller
end

-- defs (optional): global AD defaults, so the ring's renderScale/size track the SAME
-- resolved icon geometry the art does. Read raw, a global Icon Size of 40 grew the icon and
-- left the border snapped to 24. nil on the bar/group paths — neither inherits size/scale.
local function buildPlacedBorderSpec(frame, indicator, hideIcon, knownSize, defs)
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
    -- The placed indicator renders inside a subtree scaled by indicator.scale (row mode:
    -- the container's SetScale; missing mode: the window's SetScale in placeM) — the pp
    -- thickness snap must fold that scale (Border spec.renderScale) or it snaps in the
    -- wrong space and the edges land fractional again.
    spec.renderScale = tonumber(defOf(indicator, "scale", defs, 1)) or 1
    -- Fed geometry for DF_DASH: the icon/square slot is square at the configured size (floored
    -- at 8, matching buildPlacedLayout), whose live rect is secret on 12.1.
    local sz = knownSize or math.max(8, tonumber(defOf(indicator, "size", defs, 24)) or 24)
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
-- Shared scratch: unlike subSig this CANNOT recurse (it only reaches colSig, which
-- allocates nothing and calls nothing), so one table is safe. It was 4.8% of trash
-- allocation on its own -- a fresh array per indicator per UNIT_AURA.
local placedBorderSigParts = {}
local function placedBorderRawSig(indicator, borderOn)
    if not borderOn then return "" end
    local parts = placedBorderSigParts
    wipe(parts)
    parts[1] = ppSigToken()
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
-- SetApplicationCount (no formatter — secret trap), shown at >1. defOX/defOY parameterize
-- the unset-offset defaults: placed indicators default 2/-2 (the Midnight baseline),
-- filter/debuff groups keep their historical 2/-1 (buildFilterGroupStyle's pre-style
-- hardcoded values).
local function buildStackSpec(indicator, defOX, defOY, defs)
    local outline = defOf(indicator, "stackOutline", defs, "SHADOW;OUTLINE")
    if outline == "NONE" then outline = "" end
    return {
        show    = true,
        -- default to the DF font, not the Friz fallback
        font    = defOf(indicator, "stackFont", defs, "DF Roboto SemiBold"),
        size    = 10 * (tonumber(defOf(indicator, "stackScale", defs, 1)) or 1),
        outline = outline,
        anchor  = defOf(indicator, "stackAnchor", defs, "BOTTOMRIGHT"),
        offsetX = tonumber(defOf(indicator, "stackX", defs, defOX)) or 0,
        offsetY = tonumber(defOf(indicator, "stackY", defs, defOY)) or 0,
        color   = defOf(indicator, "stackColor", defs, nil),
    }
end

-- Layout for the single placed button: the container anchors it at the indicator's
-- configured corner + offset (mirror the legacy icon anchor). Size floored at 8 (old
-- configs predate the current slider floor). Growth/wrap are inert with one slot.
local function buildPlacedLayout(indicator, defs)
    return {
        -- anchor/offset are NOT global-defaultable (GLOBAL_DEFAULT_MAP omits them) and must
        -- stay raw: this is `eff` on the grouped path, whose member-group wrapper shadows
        -- exactly these three keys to place the icon in its grid cell.
        anchor  = (type(indicator.anchor) == "string" and indicator.anchor) or "TOPLEFT",
        offsetX = tonumber(indicator.offsetX) or 0,
        offsetY = tonumber(indicator.offsetY) or 0,
        size    = math.max(8, tonumber(defOf(indicator, "size", defs, 24)) or 24),
        scale   = tonumber(defOf(indicator, "scale", defs, 1)) or 1,
        growth  = "RIGHT_DOWN",
        wrap    = 1,
    }
end

-- Shared styleable duration-text spec for EVERY placed indicator (icon / square / bar). The
-- countdown is filled secret-safe by native SetDurationText (Blizzard formats the remaining
-- time C-side; no Lua read). "Color by Time Remaining" (P4.4) routes through the #205 discrete
-- BUCKET formatter (the factory duration formatter -- the file-local GetDurationFormatter in
-- Features/Auras.lua; there is no DF:GetFactoryDurationFormatter -- |cRRGGBB escapes baked into the native
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

local function buildDurationTextSpec(indicator, defaultShow, defScale, defColorByTime, defs)
    local showDuration = defOf(indicator, "showDuration", defs, defaultShow)
    if not showDuration then return nil end
    local dOutline = defOf(indicator, "durationOutline", defs, "SHADOW;OUTLINE")
    if dOutline == "NONE" then dOutline = "" end
    -- Scale + colour-by-time default PER CALLER (placed/bar default 1.2 / ON; groups keep
    -- 1.0 / OFF) — the Factory renders from the raw instance, so the render default must
    -- match the editor's global default (adDB.defaults) or the two disagree. nil on the
    -- instance = inherit the caller's default.
    local rawCBT = indicator.durationColorByTime
    if rawCBT == nil then rawCBT = defColorByTime end
    -- Colour-by-time is a MODE (legacy instances hold a boolean -> STEP_SECONDS). On
    -- 68914+ it paints through the native colour CURVE; only the pre-68914 fallback bakes
    -- |c escapes into the formatter bands. See Features/Auras.lua for the mechanism.
    local colorMode = DF:ResolveDurationColorMode(rawCBT)
    local colorSpec = DF:GetDurationColorSpec(colorMode)
    local colorByTime = DF:DurationColorUsesBuckets(colorMode)
    local hideAboveT = durationHideAboveT(indicator)
    -- Resolve the indicator's Duration Format (default NUMBER — bare "45" / "2m" / "1h",
    -- the same default the buff/debuff/defensive rows use). Classic formats come back as
    -- a plain formatter; the percent family (PERCENT / SECONDS_PERCENT, PTR-7 #5) comes
    -- back as a SetTextFormat spec instead. The formatter also carries colour-by-time
    -- buckets + hide-above blanking when set — hide-above never composes with the
    -- percent family (see GetDurationFormatFields), zeroed here so durationFmtKey
    -- stays truthful. (The Expiry Alert is NOT part of this formatter — it is its own
    -- frame-anchored element with its own SetDurationText binding.)
    local fmtValue = indicator.durationFormat or "NUMBER"
    if DF.IsPercentDurationFormat and DF:IsPercentDurationFormat(fmtValue) then hideAboveT = nil end
    local formatter, textFormat
    if DF.GetDurationFormatFields then
        formatter, textFormat = DF:GetDurationFormatFields(fmtValue, hideAboveT, colorByTime)
    end
    return {
        show      = true,
        stableCenter = true,   -- centred countdown: stable box, no shift/wobble (shared TextStyle mode)
        -- default to the DF font, not the Friz fallback
        font      = defOf(indicator, "durationFont", defs, "DF Roboto SemiBold"),
        size      = 10 * (tonumber(defOf(indicator, "durationScale", defs, defScale)) or 1),
        outline   = dOutline,
        anchor    = defOf(indicator, "durationAnchor", defs, "CENTER"),
        offsetX   = tonumber(defOf(indicator, "durationX", defs, 0)) or 0,
        offsetY   = tonumber(defOf(indicator, "durationY", defs, 0)) or 0,
        formatter = formatter,   -- nil unless colour-by-time / hide-above; |c escapes own colour
        textFormat = textFormat, -- percent family: SetTextFormat components (tried FIRST by
                                 -- applyDurationFormatter; formatter is nil alongside it)
        -- Either colour path owns the text colour outright, so the static pick stands down.
        color     = (not colorSpec) and defOf(indicator, "durationColor", defs, nil) or nil,
        colorCurve   = colorSpec and colorSpec.curve or nil,
        colorProperty = colorSpec and colorSpec.property or nil,
        -- Hide duration text on permanent auras (Wave 4, default ON): "" flows to
        -- the native binding's zeroDurationText (renders NO text on zero-duration/
        -- unconfigured). ABSENT key = ON — style-less groups and untouched
        -- indicators get the new default; explicit false = the pre-Wave-4 spec
        -- shape (no zeroText key). Creation-frozen -> rides durationFmtKey below.
        zeroText  = (indicator.durationHideOnPermanent ~= false) and "" or nil,
        -- Duration-text update rate (Wave 5a, account-wide): nil at the NORMAL
        -- default (key absent = the binding's own cadence — byte-identical to the
        -- pre-setting spec). Creation-frozen -> rides durationFmtKey below.
        updateInterval = (DF.GetAuraDurationUpdateInterval and DF:GetAuraDurationUpdateInterval()) or nil,
    }
end

-- Stable duration-text format key for the STRUCTURAL signature: the native SetDurationText
-- formatter is creation-frozen (bind-once), so a colour-by-time OR hide-above change must
-- Rebuild the slot to swap it. "" when duration text is off. Mirrors #205's dur.formatKey.
-- defs (optional, icon/square only): showDuration is global-defaultable there, and this key
-- must agree with buildDurationTextSpec about whether text renders at all — otherwise the
-- formatter key says "" while the spec builds one (or vice versa) and the sig goes stale.
-- Bar and group callers pass nil: GLOBAL_DEFAULT_MAP gives neither a showDuration global.
local function durationFmtKey(indicator, defaultShow, defColorByTime, defs)
    local showDuration = defOf(indicator, "showDuration", defs, defaultShow)
    if not showDuration then return "" end
    -- Resolve colour-by-time with the SAME caller default as buildDurationTextSpec. Otherwise a
    -- placed icon on the default (ON, but nil on the instance) gets a COLOURED formatter while
    -- this key stays "NUMBER" — a breakpoint edit then never moves the struct signature, so the
    -- bind-once formatter is never re-bound and the colours go stale until /reload.
    local rawCBT = indicator.durationColorByTime
    if rawCBT == nil then rawCBT = defColorByTime end
    local colorMode = DF:ResolveDurationColorMode(rawCBT)
    local hideAboveT = durationHideAboveT(indicator)
    -- Format value leads the key (was hardcoded "NUMBER" pre-#5); hide-above is
    -- zeroed for the percent family EXACTLY as buildDurationTextSpec zeroes it,
    -- or a no-op hide-above toggle would rebuild slots for an unchanged render.
    local fmtValue = indicator.durationFormat or "NUMBER"
    if DF.IsPercentDurationFormat and DF:IsPercentDurationFormat(fmtValue) then hideAboveT = nil end
    -- Duration-text update rate (Wave 5a, account-wide): tokenized only when
    -- non-default (NORMAL resolves nil), so untouched sigs stay byte-identical
    -- and a rate change Rebuilds every duration-text slot (creation-frozen bind).
    local updateIv = DF.GetAuraDurationUpdateInterval and DF:GetAuraDurationUpdateInterval()
    return fmtValue
        -- Mode + that scale's stops: the curve is bind-once like the formatter, so a
        -- mode change OR a Colours-page stop edit must move this key.
        .. DF:GetDurationColorSig(colorMode)
        .. (hideAboveT and (":H" .. tostring(hideAboveT)) or "")
        -- Hide-on-permanent (Wave 4): the OFF state alone is tokenized so the
        -- absent key sigs byte-identically to explicit true (absent = ON is the
        -- default; style-less byte-identity holds). zeroText is creation-frozen
        -- on the native bind, so ON<->OFF must move the struct sig -> Rebuild.
        .. (indicator.durationHideOnPermanent == false and ":P0" or "")
        .. (updateIv and (":U" .. tostring(updateIv)) or "")
end

-- ============================================================
-- EXPIRY ALERT ELEMENT  (placed icon/square/bar indicators only)
-- A per-indicator FontString that shows the configured custom text / glyph
-- only while the tracked aura's remaining time is below the threshold —
-- natively driven by a SetDurationText binding whose formatter renders the
-- payload below the threshold and an EMPTY string above it (C-side band
-- evaluation against the SECRET remaining time, zero Lua reads).
--
-- Delivery mechanism — in-game probe history:
--   * a243064 parented the region OUTSIDE the button subtree (unit frame):
--     soft-rejected — the binding neither errored nor drove it.
--   * 014b1bb bound a button-child region as a SECOND SetDurationText on the
--     indicator's own button: REPLACE semantics — the second bind killed the
--     indicator's duration text (and above the threshold the alert's empty
--     band renders nothing, so NO text rendered at all). One duration binding
--     per button is the rule.
-- The mechanism is therefore an invisible COMPANION SLOT per alerted
-- indicator — see the EXPIRY ALERT COMPANION SLOT section further down (after
-- the layout builders it borrows). The indicator's own button carries exactly
-- one duration binding (dfDur), byte-identical to pre-alert behaviour whether
-- the alert is ON or OFF.
-- ============================================================

-- Expiry-alert MODE / geometry / structural identity now live in the DF.Expiration
-- engine (Features/Expiration.lua) so the frame-level indicators can share the same
-- secret-safe reveal. These thin locals keep the factory's own call sites reading the
-- same, passing the icon side as the engine's geometry.baseSize (BORDER auto-match reads
-- it). Size/anchor are computed inside the engine's StructSig / BuildDurationSpec /
-- BuildDurationSpec (via alertSlotStyle), so the factory no longer needs its own
-- effectiveAlertSize/Anchor.
local function alertElemMode(indicator) return DF.Expiration:Mode(indicator) end
-- geom (from alertGeometry, defined after resolveBarSize) carries the target's shape: a square
-- { baseSize } for icons/squares, or a rectangular { width, height } for bars. Defaults to the
-- square icon path when a caller has none.
local function alertElemStructKey(indicator, geom)
    return DF.Expiration:StructSig(indicator, geom or { baseSize = indicator.size })
end

-- PANDEMIC (the refresh-window cue, PTR 8). Unlike the expiry alert it needs NO companion
-- container: AddPandemicRegion attaches a real Region to the indicator's own button, so
-- this is just another entry in the style table — the same shape as style.bar.
--
-- Every AD family stores the block under the SAME bare `pandemic*` keys on its own record,
-- so they all pass prefix = nil and there is one key vocabulary across the designer.
-- `ctx` is DF.Border's build context (the cue's Border type is a real DF.Border). No unit
-- is threaded: the AD border UI never exposes a class/role colour SOURCE (it is always the
-- static picker — see PLACED_BORDER_KEYS), so the resolver has nothing to resolve and
-- plumbing a frame down to two style builders that have never needed one would be cost
-- with no reader. iconMode makes it size as an icon ring rather than a frame edge.
local PANDEMIC_CTX = { iconMode = true }
local function pandemicSpec(rec)
    return DF.Pandemic and DF.Pandemic:BuildSpec(rec, nil, PANDEMIC_CTX) or nil
end
-- Region KIND + bind are create-once -> Rebuild; everything else restyles in place. The
-- engine owns that split (StructSig / CoSig), so these two stay one line each and no
-- family can disagree with another about which keys are structural.
local function pandemicStructKey(rec)
    return DF.Pandemic and DF.Pandemic:StructSig(rec, nil) or ""
end
local function pandemicCoKey(rec)
    return DF.Pandemic and DF.Pandemic:CoSig(rec, nil) or ""
end

-- Resolve the profile's GLOBAL colour-by-time default for placed/bar duration text:
-- adDB.defaults.durationColorByTime, nil -> ON (the Midnight baseline — mirrors the
-- editor's GLOBAL_DEFAULTS_FALLBACK / TYPE_DEFAULTS). Threaded into every placed/bar
-- spec builder AND struct sig so render and editor resolve from the SAME source: the
-- editor's per-indicator proxy falls back instance -> adDB.defaults -> ON, so a
-- hardcoded render default silently disagrees with the editor on every profile whose
-- stored default is OFF (all pre-12.1 profiles — their Config factory stamped false,
-- and existing profiles deliberately keep their duration colours; only new/reset
-- profiles pick up the new ON default).
local function resolveDefCBT(adDB)
    local d = adDB and adDB.defaults
    if type(d) == "table" and d.durationColorByTime ~= nil then
        return d.durationColorByTime and true or false
    end
    -- Plain ON, never a mode string: an explicit mode OVERRIDES the account-wide dials
    -- (ResolveDurationColorMode), so returning one here would make every indicator that
    -- inherits the default deaf to the Colours page's Blend / Measure By settings.
    return true
end
-- (Deliberately NOT exported on its own any more: the editor preview takes the whole
-- defaults bundle via Factory.ResolveDefaults, which calls this. A colour-by-time-only
-- accessor would be a second way to resolve the same thing, and the two could drift.)

-- The art (icon / square fill) insets by the border's RENDERED thickness so the ring frames
-- it flush. DF.Border:Apply snaps its thickness through Border:SnapThickness (pixel-perfect
-- fold, incl. the container's render scale); the art inset must go through the SAME function
-- or the art edge and the border's inner edge drift a sub-pixel apart — visible as a hairline
-- gap (snap-down) or overlap (snap-up) when pixel-perfect is on. Reads borderSpec.size +
-- renderScale (the exact values Apply renders), so the two coincide by construction. Caller
-- supplies the no-border fallback.
local function borderArtInset(borderSpec)
    if DF.Border and DF.Border.SnapThickness then
        return DF.Border:SnapThickness(borderSpec.size, borderSpec.pixelPerfect, borderSpec.renderScale)
    end
    return borderSpec.size
end

-- Build the style table for a placed icon/square. icon = native spell texture (unless
-- hideIcon = text-only); square = solid config colour fill (no SetIcon). Both keep the
-- native cooldown swipe, the styleable duration-text fontstring, the native stack count,
-- and the static border.
local function buildPlacedStyle(indicator, isSquare, borderSpec, defs)
    local hideIcon = defOf(indicator, "hideIcon", defs, false) and true or false
    local style = {}

    if isSquare then
        -- Solid-colour box (legacy SetColorTexture). hideIcon = no fill (text-only). The
        -- fill insets by the border thickness so the ring frames it (legacy parity).
        --
        -- ⚠ ALWAYS emit style.square, even when hidden — its PRESENCE is what tells
        -- AuraContainer "this slot is a square, do not run the icon path". Omitting the
        -- table on hideIcon left both style.square and style.icon nil, and the container's
        -- `if not squareSpec and (iconSpec == nil ...)` then fell through and bound the
        -- spell icon: ticking Hide Icon on a square turned it INTO an icon. Mirrors the
        -- icon branch below, which has always used a `show` flag for the same reason.
        local r, g, b = readADColor(indicator.color)
        local inset = borderSpec and borderArtInset(borderSpec) or 0
        style.square = { show = not hideIcon, color = { r, g, b, 1 }, inset = inset }
    else
        -- Spell icon. hideIcon = text-only: skip the icon texture, keep cooldown/border/
        -- stacks. Art inset matches the border thickness so the ring frames the art.
        -- ☠ Border OFF = inset 0, full-bleed art — the 4.x behaviour users expect
        -- ("icon scales up with border off"). This was `or 1`, an accidental copy of
        -- the container's generic 1px row default: with the default BorderSize of 1,
        -- toggling Show Border changed the inset from 1 to 1 — i.e. nothing (#1035).
        -- Every sibling path (square fill above, filter/debuff groups, missing badge)
        -- already used 0.
        local inset = borderSpec and borderArtInset(borderSpec) or 0
        style.icon = { show = not hideIcon, inset = inset }
    end

    -- Cooldown swipe: Blizzard drives it from the matched aura's Duration object
    -- (SetDurationCooldown) — no Lua time read. hideSwipe toggles the swipe (also off in
    -- text-only mode). Native countdown numbers are OFF — duration text renders through the
    -- styleable SetDurationText fontstring below (positionable, matching the legacy icon).
    local hideSwipe = defOf(indicator, "hideSwipe", defs, false) and true or false
    -- reverse = true: drain like Blizzard's aura frames (and DF's own rows) — see #983.
    style.cooldown = { show = true, swipe = (not hideSwipe) and (not hideIcon), reverse = true, numbers = false }

    -- Duration text: a DF-owned fontstring the native SetDurationText fills secret-safe
    -- (Blizzard formats the remaining time C-side; no Lua read). Colour-by-time now routes
    -- through the #205 bucket formatter — see buildDurationTextSpec. Default show = true.
    style.duration = buildDurationTextSpec(indicator, true, 1.2, defs.cbt, defs)   -- placed icon/square baseline: 1.2 scale, colour-by-time per adDB.defaults

    -- Stacks: native count, shown at >1. NO formatter (secret trap — see bindNative). A
    -- custom stackMinimum is NOT expressible on the no-formatter native path (deferred).
    local showStacks = defOf(indicator, "showStacks", defs, true)
    if showStacks then style.stacks = buildStackSpec(indicator, 2, -2, defs) end   -- placed baseline stack offset

    if borderSpec then style.border = { spec = borderSpec } end

    -- Duration bar strip: the ROW's shared spec builder over the indicator's own
    -- durationBar* keys (identical keying to filter groups and the buff/debuff
    -- rows). nil when disabled/absent, so a bar-less indicator's style is
    -- byte-identical to the pre-feature output. Icon AND square both carry it —
    -- the strip hangs off the slot edge regardless of the slot's content shape.
    style.bar = DF.BuildDurationBarSpec and DF:BuildDurationBarSpec(indicator, "durationBar") or nil

    -- Pandemic cue: rendered ON THIS BUTTON (AddPandemicRegion takes a Region, and the
    -- registrar is a list, so it does not collide with anything else bound here). That is
    -- the whole difference from the expiry alert below — no companion, no extra container.
    style.pandemic = pandemicSpec(indicator)

    -- Expiry Alert element: rendered by a separate COMPANION SLOT, never by this
    -- button (one duration binding per button — see EXPIRY ALERT COMPANION SLOT).
    return style
end

-- Full row config for one placed indicator (max=1 single-slot container). Its frame level is
-- resolveLevel's ABSOLUTE value (default 40, the buff-icon band, above the content overlay)
-- — not 40 plus the indicator's own frameLevel. See resolveLevel.
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

-- Per-indicator FRAME STRATA. Companion to frameLevelOffset: level orders within a strata
-- band, strata picks the band. "INHERIT" (the stored default, and the only value that ships
-- on an untouched profile) means DON'T TOUCH — the holder keeps the unit frame's strata and
-- z-order stays governed by frameLevelOffset alone, exactly as before this was wired.
-- Returns nil for INHERIT/unset so the apply site falls back to the parent's strata, which
-- is also what RESTORES inheritance when a user switches back (a frame always has a strata;
-- there is no "unset" to write). Whitelisted rather than passed through: SetFrameStrata
-- errors on an unknown string, and this value can arrive from an imported profile.
-- ☠ BACKGROUND AND LOW ARE DELIBERATELY NOT HERE. They used to be, and a stored
-- "BACKGROUND" pinned an indicator below every MEDIUM frame on the unit button — the health
-- bar included — where no frame level could ever lift it, because strata outranks level
-- absolutely. The per-indicator picker that wrote them was removed from the editor, so the
-- values became unreachable AND still honoured: users saw an indicator buried under the
-- health bar with a Frame Level slider that did nothing (field-proven by a /df debug zorder
-- dump, 2026-08-19 — strata=BACKGROUND at level 106 losing to a health bar at level 7).
--
-- Rejecting them here makes resolveStrata fall through to the global default (INHERIT), so
-- the indicator takes the unit frame's own strata and FRAME LEVEL decides the ordering —
-- which is the baseline the absolute-levels migrations were built for.
-- ⚠ This covers what the migration cannot: an IMPORTED profile or a shared preset carrying
-- a legacy BACKGROUND arrives after the one-time pass has already stamped its flag.
-- ⚠ MEDIUM and HIGH stay valid: they are at or above the frame's own band, so they order
-- against it rather than hiding beneath it.
local STRATA_VALID = { MEDIUM = true, HIGH = true }
-- defStrata = the resolved GLOBAL default (defs.strata). Fallback order matches the editor
-- proxy exactly: instance -> global default -> nothing. An instance holding the literal
-- "INHERIT" is an explicit CHOICE and stops the chain (the editor shows Inherit for it), so
-- it must NOT fall through to the global — only a genuinely unset key does.
local function resolveStrata(indicator, defStrata)
    local s = indicator and indicator.frameStrata
    if type(s) == "string" then
        return STRATA_VALID[s] and s or nil     -- includes "INHERIT" -> nil, deliberately
    end
    return defStrata
end

-- Per-indicator FRAME LEVEL, same chain: instance -> global default -> 40.
--
-- ⚠ The returned value is ABSOLUTE (an offset from the unit frame, like every other
-- *FrameLevel setting since 09d6743). Callers pass it through as frameLevelOffset and
-- NOTHING adds a base to it — the `or 40` is a fallback for a MISSING key, not a baseline
-- that gets summed in. This comment used to claim "callers add 40 for placed, 41 for the
-- alert companion", which was true before the absolute-level change and has misled at
-- least two readers since into hunting a hidden offset that does not exist.
-- (The alert companion really does add 13 — see buildAlertCompanionConfig — but that is a
-- deliberate ONE FULL ROW over its own indicator, not a base. It was +1 until it turned out
-- a row is 13 levels thick, which parked the alert inside its own indicator's band.)
local function resolveLevel(indicator, defLevel)
    return tonumber(indicator and indicator.frameLevel) or defLevel or 40
end

-- The GLOBAL AD defaults the RENDER honours, resolved ONCE per drive pass and threaded as a
-- single named table rather than as more positional arguments. That is the point: with a
-- table a missed call site fails as a nil index on a named key, whereas a fourth positional
-- boolean/number silently slides into whatever parameter sits next to it. Same reason
-- resolveDefCBT exists — render and editor must walk the SAME fallback chain, or a stored
-- default shows in the editor and does nothing live.
-- ☠ EVERY key the editor's GLOBAL_DEFAULT_MAP offers must appear here, or the setting is a
-- LIE. The editor proxy (Options/AuraDesigner/UI/Groups.lua) falls back to adDB.defaults for
-- DISPLAY, but it only copy-on-reads TABLES back onto the instance — a scalar the user never
-- touched stays nil on the record, and the Factory then rendered its own hardcoded literal.
-- So Global Defaults could show Icon Size 32 while every untouched indicator kept rendering
-- at 24. cbt/level/strata were the only three ever plumbed. arrangeGroupList meanwhile had
-- always read adDB.defaults.iconSize/iconScale for its grid STEP, so group spacing honoured
-- the global while the icons sitting in that grid did not — members drifted off their cells.
--
-- ⚠ Each fallback below is the literal MOVED from its render site, not retyped: with no
-- stored default this collapses to today's exact behaviour, so only a profile that actually
-- set a global default can render differently.
--
-- Keys resolved against a PER-CALLER baseline (placed vs bar vs group) stay nil when unset —
-- durationScale, stackX/stackY, showDuration, showStacks — so the caller's own argument still
-- wins the tail. The chain is always: instance -> global -> caller.
local function defStr(v)  return (type(v) == "string" and v ~= "") and v or nil end
local function defBool(v) if v == nil then return nil end return v and true or false end

local function resolveDefs(adDB)
    local d = adDB and adDB.defaults
    if type(d) ~= "table" then d = nil end
    local strata = d and d.indicatorFrameStrata
    local t = {
        cbt    = resolveDefCBT(adDB),
        level  = (d and tonumber(d.indicatorFrameLevel)) or 40,
        strata = (type(strata) == "string" and STRATA_VALID[strata]) and strata or nil,

        -- Geometry (icon/square only — the bar sizes itself; see GLOBAL_DEFAULT_MAP.bar).
        size  = (d and tonumber(d.iconSize)) or 24,
        scale = (d and tonumber(d.iconScale)) or 1,

        -- Presence toggles: nil = inherit the caller's baseline (placed shows duration, the
        -- bar does not), so these must NOT collapse to a hardcoded true/false here.
        -- ⚠ NO `or nil` tail on these four. `d and defBool(v) or nil` looks equivalent but
        -- maps an explicit stored FALSE to nil, so a global default of OFF would be dropped
        -- and the key would fall through to the caller's ON baseline — the same silent-drop
        -- shape this whole block exists to fix. `d and defBool(v)` is already nil when d is
        -- nil and nil when the key is unset, so the tail buys nothing and costs correctness.
        showDuration = d and defBool(d.showDuration),
        showStacks   = d and defBool(d.showStacks),
        hideSwipe    = d and defBool(d.hideSwipe),
        hideIcon     = d and defBool(d.hideIcon),

        -- Duration text.
        durationFont    = (d and defStr(d.durationFont)) or "DF Roboto SemiBold",
        durationScale   = d and tonumber(d.durationScale) or nil,   -- nil = caller's defScale
        durationOutline = (d and defStr(d.durationOutline)) or "SHADOW;OUTLINE",
        durationAnchor  = (d and defStr(d.durationAnchor)) or "CENTER",
        durationX       = (d and tonumber(d.durationX)) or 0,
        durationY       = (d and tonumber(d.durationY)) or 0,
        durationColor   = d and d.durationColor or nil,

        -- Stack text. X/Y stay nil: the caller supplies the per-surface baseline offset
        -- (placed 2/-2, group 2/-1) and a global must sit BETWEEN the instance and it.
        stackFont    = (d and defStr(d.stackFont)) or "DF Roboto SemiBold",
        stackScale   = (d and tonumber(d.stackScale)) or 1,
        stackOutline = (d and defStr(d.stackOutline)) or "SHADOW;OUTLINE",
        stackAnchor  = (d and defStr(d.stackAnchor)) or "BOTTOMRIGHT",
        stackX       = d and tonumber(d.stackX) or nil,
        stackY       = d and tonumber(d.stackY) or nil,
        stackColor   = d and d.stackColor or nil,
    }
    -- ☠ The BAR inherits a STRICT SUBSET — mirror GLOBAL_DEFAULT_MAP.bar exactly. It has no
    -- showDuration (a bar defaults to no countdown text and the editor offers no global for
    -- it), no durationColor, and no size/scale/stack*/hideIcon/hideSwipe. buildDurationTextSpec
    -- is SHARED with icon/square, so handing it the full table would have made bars silently
    -- inherit settings their own card never shows — a global "Show Duration" tick would have
    -- switched countdown text on for every bar in the profile.
    -- Passed as the `defs` argument on the bar path; everything absent here correctly falls
    -- through to the caller's own baseline.
    t.barText = {
        durationFont    = t.durationFont,
        durationScale   = t.durationScale,
        durationOutline = t.durationOutline,
        durationAnchor  = t.durationAnchor,
        durationX       = t.durationX,
        durationY       = t.durationY,
    }
    return t
end
Factory.ResolveDefaults = resolveDefs   -- editor preview passes this into BuildPreviewConfig

-- Aura Designer tooltips (Tooltips page). Every AD surface shipped with
-- `tooltips = false` hardcoded; these three keys make it a choice.
--
-- The one worth turning on is GROUPS: a filter/debuff group renders whatever
-- matches its filter, so you never picked those icons individually. Indicators
-- and Bars are spells you placed yourself and named, so they gain little — but
-- they are exposed anyway rather than us deciding for the user.
--
-- The alert companion is deliberately NOT exposed: it is an overlay pinned to
-- another indicator, so a tooltip there would compete with that indicator's own
-- on the same hover area. That is an interaction problem, not a taste call.
local function adTooltipsOn(frame, key)
    if not frame then return false end
    local db = DF.GetFrameDB and DF:GetFrameDB(frame)
    return (db and db[key]) and true or false
end

-- ☠ THE TOOLTIP FLAGS ARE STRUCTURAL AND MUST RIDE THE STRUCT SIGS. Mouse state
-- is written exactly once per button, at initializeFrame — no restyle can flip
-- it, and the engine's own contract says a tooltips change needs Rebuild().
-- These three keys were in the container CONFIGS but in none of the SIGS, so
-- toggling any Aura Designer tooltip setting rebuilt nothing and did nothing
-- until a /reload (in BOTH directions — shipped that way in 5.0.0; field
-- report "turned tooltips off, still showing"). One combined term at every AD
-- sync site: any of the three flipping rebuilds the AD surfaces once, OOC.
local function adTooltipSig(frame)
    local db = (DF.GetFrameDB and DF:GetFrameDB(frame)) or {}
    return "|tt=" .. (db.tooltipADGroupsEnabled and "g" or "")
                  .. (db.tooltipADIndicatorsEnabled and "i" or "")
                  .. (db.tooltipADBarsEnabled and "b" or "")
end

local function buildPlacedConfig(frame, unit, map, indicator, isSquare, borderSpec, defs, mine)
    return {
        unit = unit,
        mode = "row",
        max = 1,
        -- ONE icon, so declare an AuraSlot rather than a one-icon AuraGroup:
        -- AddAuraGroup eagerly creates a whole FrameCreationBatchSize batch BEFORE
        -- maxFrameCount is applied; AddAuraSlot creates exactly one frame. Same
        -- selection (the slot carries the sort comparator), same size
        -- (styleButton_regions sizes both paths identically).
        singleSlot = true,
        filter = poolFilter(indicator, mine),   -- "HELPFUL|PLAYER" on My Buffs; othersOnly rides the other pool (structural)
        candidateFilters = { includeSpellIDs = map },
        testEntries = testEntryForMap(map),
        enabled = true,
        tooltips = adTooltipsOn(frame, "tooltipADIndicatorsEnabled"),
        -- adBorderAnim: opt this ROW container into the DF-owned border animations (edge-alpha
        -- / DF_DASH / Wipe / Ripple) the shared allowlist otherwise reserves to overlay mode.
        -- The #205 buff/debuff rows never set it, so they still strip. Safe: the animation runs
        -- off our own secretRect border textures via the external UIParent driver, not the LCG
        -- glows (which stay stripped by SAFE_OVERLAY_ANIM regardless).
        adBorderAnim = true,
        frameLevelOffset = resolveLevel(indicator, defs.level),
        frameStrata = resolveStrata(indicator, defs.strata),
        layout = buildPlacedLayout(indicator, defs),
        style = buildPlacedStyle(indicator, isSquare, borderSpec, defs),
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
-- STRUCTURAL signature: CREATE-ONLY properties only. A change here costs a full
-- teardown+recreate -- and teardown can only Hide(), because WoW never destroys frames,
-- so every rebuild permanently strands the container plus a 10-frame batch per group
-- (AddAuraGroup always creates FrameCreationBatchSize frames up front). Anything the
-- native API can mutate live therefore MUST stay out of this sig or it leaks on every
-- edit. The tracked spell-ID map used to live here; it is live-tunable via
-- candidateFilters and now rides placedTuningSig.
local function placedStructSig(isSquare, hideIcon, showStacks, showDuration, borderOn, indicator, defs)
    return (isSquare and "sq" or "ic")
        .. "|" .. (hideIcon and "hi" or "")
        .. "|" .. (showStacks and "st" or "")
        .. "|" .. (showDuration and "du" or "")
        .. "|" .. (borderOn and "bd" or "")
        .. "|fl=" .. tostring(resolveLevel(indicator, defs.level))
        .. "|fs=" .. tostring(resolveStrata(indicator, defs.strata) or "")   -- strata applies at Create, like the level
        -- ☠ "|df=" .. durationFmtKey(...) was here. Duration formatting is NOT
        -- structural: SetDurationText is reset-then-apply and re-callable, and
        -- bindNative now re-binds on a spec change from ApplyStyle. It also folded
        -- in DF:GetAuraDurationUpdateInterval(), so one account-wide setting
        -- rebuilt every container on every frame. It is a restyle now.
        -- (No alert keys: the expiry alert lives on the COMPANION slot, whose own
        -- structSig carries alertElemStructKey — an alert edit rebuilds only it.)
        -- (No filter string: it moved to placedTuningSig on 2026-08-04 — a single-record
        -- consumer cannot change its key set, so the string is live-swappable.)
        -- Duration bar PRESENCE only. ☠ The geometry half (position/height/gap) used to
        -- ride here on the theory that the strip's layout reservation could not
        -- re-derive live. It already does: ApplyStyle -> backend:applyLayout ->
        -- buildGroupLayout -> stripReservation -> SetAuraGroupLayout, and
        -- styleButton_regions re-anchors the strip every pass ("Re-anchored every pass
        -- so position/gap/height edits apply live via ApplyStyle"). colorMode only picks
        -- a curve/colour, applied live by styleBarShared, and placedCoSig carries it
        -- anyway. Only the region's EXISTENCE is create-once.
        .. "|" .. (indicator.durationBarEnabled == true and "bar" or "")
        -- Pandemic: the region's WIDGET KIND and its AddPandemicRegion bind are both
        -- create-once, so a type change (or the master toggle) rebuilds. Everything else
        -- about it hot-applies and rides placedCoSig. "" when off.
        .. "|pd=" .. pandemicStructKey(indicator)
end

-- TUNING signature: the live-mutable half of what placedStructSig used to carry. The
-- tracked spell-ID map becomes config.candidateFilters ({ includeSpellIDs = map }), and
-- the native SetAuraGroupCandidateFilters mutates that in place — so a selection edit is
-- an ApplyTuning, never a Rebuild. A placed indicator pins max = 1 (buildPlacedConfig)
-- and has no per-indicator sort. Mirrors the filter-group path's tuningSig, which has
-- worked this way since Wave 1.
--
-- ★ `filt` joined the tuning half on 2026-08-04. The filter string used to be
-- creation-frozen, so "Others Only" cost a teardown+recreate for a string change;
-- SetAuraGroup/SlotFilterString mutate it live and the engine now pushes it from
-- applyGroupTuning. Every AD family declares exactly ONE record, so its key set can
-- never move — which is the condition that makes this legal (add-only topology).
-- Shared by every AD family, so all seven call sites pass their own poolFilter result.
local function placedTuningSig(map, filt)
    return includeSig(map) .. "|f=" .. tostring(filt or "")
end

-- COSMETIC signature: size/anchor/offset/scale/alpha, swipe, duration/stack styling, square
-- colour, and the RAW-config border sig (no BuildSpec alloc — FIX C). A change here
-- hot-applies via ApplyStyle(style, layout); the actual border spec is built only then.
local function placedCoSig(indicator, isSquare, borderOn, alpha, defs)
    local parts = {
        -- ★ Duration FORMATTING moved here from the struct sig. It has to live in a
        -- signature somewhere or a format change would move nothing and silently do
        -- nothing; the cosmetic sig is the right one now that bindNative re-binds on a
        -- spec change from ApplyStyle. Passing defaultShow/defColorByTime as the struct
        -- sig did keeps the key identical, so the only thing that changed is WHICH tier
        -- reacts: restyle instead of teardown-and-recreate.
        -- ☠ defs.cbt, NOT nil. durationFmtKey resolves colour-by-time with whatever
        -- default it is handed, and buildDurationTextSpec resolves it with defs.cbt --
        -- so passing nil here made ResolveDurationColorMode(nil) answer "OFF" while the
        -- spec that actually renders answered from the profile default. An indicator
        -- left on the default then had a COLOURED formatter and a sig that said OFF, so
        -- editing the breakpoints moved nothing, no re-bind happened, and the colours
        -- stayed stale until /reload. The struct sigs already pass defs.cbt; the two
        -- cosmetic sigs were the ones that lost it. The function's own comment warns
        -- about exactly this -- it just was not being obeyed here.
        "df=" .. durationFmtKey(indicator, true, defs and defs.cbt, defs),
        -- ☠ Every global-defaultable key below resolves through defOf, NOT raw. Serialising
        -- the raw nil left the sig frozen while the GLOBAL default moved, so editing Global
        -- Defaults produced no delta and never repainted. See defOf.
        "sz=" .. tostring(math.max(8, tonumber(defOf(indicator, "size", defs, 24)) or 24)),
        "sc=" .. tostring(tonumber(defOf(indicator, "scale", defs, 1)) or 1),
        "an=" .. tostring(indicator.anchor or "TOPLEFT"),
        "ox=" .. tostring(tonumber(indicator.offsetX) or 0),
        "oy=" .. tostring(tonumber(indicator.offsetY) or 0),
        "al=" .. tostring(alpha),
        "sw=" .. tostring(defOf(indicator, "hideSwipe", defs, false) and 1 or 0),
        "du=" .. tconcat({
            tostring(defOf(indicator, "showDuration", defs, true) and 1 or 0),
            tostring(defOf(indicator, "durationFont", defs, nil)),
            tostring(defOf(indicator, "durationScale", defs, nil)),
            tostring(defOf(indicator, "durationOutline", defs, nil)),
            tostring(defOf(indicator, "durationAnchor", defs, nil)),
            tostring(defOf(indicator, "durationX", defs, nil)),
            tostring(defOf(indicator, "durationY", defs, nil)),
            -- Colour MODE verbatim (not a 1/0 flag): every mode is truthy, so a boolean
            -- token could never tell SMOOTH_PERCENT from STEP_SECONDS and a mode switch
            -- would not move the signature. (durationFmtKey carries the mode + its stops
            -- too; this keeps the per-indicator sig honest on its own.)
            tostring(indicator.durationColorByTime),
            colSig(defOf(indicator, "durationColor", defs, nil)),
        }, ","),
        "stk=" .. tconcat({
            tostring(defOf(indicator, "stackFont", defs, nil)),
            tostring(defOf(indicator, "stackScale", defs, nil)),
            tostring(defOf(indicator, "stackOutline", defs, nil)),
            tostring(defOf(indicator, "stackAnchor", defs, nil)),
            tostring(defOf(indicator, "stackX", defs, nil)),
            tostring(defOf(indicator, "stackY", defs, nil)),
            colSig(defOf(indicator, "stackColor", defs, nil)),
        }, ","),
        "bd=" .. placedBorderRawSig(indicator, borderOn),
        -- Duration-bar COSMETICS (texture / colour / bg / reverse-fill) hot-apply via
        -- styleBarShared; geometry/presence is structural (placedStructSig). Serialised
        -- only when the bar is on — an off bar contributes nothing, matching the sig.
        "bar=" .. (indicator.durationBarEnabled == true and tconcat({
            tostring(indicator.durationBarTexture),
            tostring(indicator.durationBarColorMode or "STATIC"),
            colSig(indicator.durationBarColor), colSig(indicator.durationBarBGColor),
            tostring(indicator.durationBarReverseFill and 1 or 0),
            -- ☠ POSITION / HEIGHT / GAP BELONG HERE and were in NO signature at all.
            -- BuildDurationBarSpec reads all three, and placedStructSig deliberately
            -- excludes them ("so position/gap/height edits apply live via ApplyStyle ...
            -- Only the region's EXISTENCE is create-once") -- but nothing then carried them
            -- in the cosmetic sig either, so SyncFrame saw no delta and never called
            -- ApplyStyle. Dragging Height 4 -> 10 changed the saved value and moved nothing
            -- until an unrelated cosmetic edit or a /reload flushed it, which reads as
            -- "works but needs a reload".
            --
            -- They must NOT go in the struct sig: that mints a new slot key, and
            -- AddAuraSlot is add-only, so every intermediate slider value would strand a
            -- permanent button.
            tostring(indicator.durationBarPosition or "BOTTOM"),
            tostring(tonumber(indicator.durationBarHeight) or 4),
            tostring(tonumber(indicator.durationBarGap) or 1),
        }, ",") or ""),
        -- Pandemic COSMETICS (colour / opacity / thickness / inset / size / payload /
        -- placement). All plain region writes, so they hot-apply; only the widget kind
        -- is structural (placedStructSig). "" when off.
        "pd=" .. pandemicCoKey(indicator),
        -- (No alert entry: the expiry alert renders on its COMPANION slot with
        -- its own struct/cosmetic sigs — this container never carries it.)
    }
    if isSquare then
        local r, g, b = readADColor(indicator.color)
        parts[#parts + 1] = "co=" .. tconcat({ tostring(r), tostring(g), tostring(b) }, ",")
    end
    return tconcat(parts, "|")
end

-- Placed base alpha rides a DF-owned frame (combat-safe; alpha is not a secret).
-- ☠ GetAlphaHost, not GetFrame. A container handle's host is its own anchor frame; a
-- collapsed slot's is dfLevelHost, the frame its regions hang off. GetFrame() for a slot
-- is the aura BUTTON, and every tainted write to that is refused once auras are secret --
-- the pcall here was swallowing exactly that failure silently, while the same fault
-- surfaced loudly in the out-of-range fade, which is not pcall'd.
-- ⚠ The stash below is not just for the fade: a slot's button is created in a LAZY BATCH,
-- so this very often runs before there is any host to write to. AcquireSlot's
-- initializeFrame re-asserts _dfADBaseAlpha once the host exists.
-- See SlotHandle:GetAlphaHost.
local function applyPlacedAlpha(handle, alpha)
    handle._dfADBaseAlpha = alpha   -- read by the OOR fade (ElementAppearance)
    local f = handle and handle.GetAlphaHost and handle:GetAlphaHost()
    if f then pcall(function() f:SetAlpha(alpha) end) end
end

-- ============================================================
-- SLOT-OWNER BRIDGE  (container collapse S2b)
-- ============================================================
-- Every placed indicator sets singleSlot, so each one used to get a WHOLE AuraContainer
-- holding exactly ONE slot -- ~120 per unit frame in a heavy profile, uncapped, and every
-- structural edit stranded one permanently (frames are never freed, and teardown cannot
-- release buttons because there is no public release). They now share ONE container per
-- unit frame, via AuraContainer:AcquireSlot.
--
-- ☠ THE SLOT KEY CARRIES THE STRUCT SIG. A slot's regions are built in its
-- initializeFrame, which is frozen at AddAuraSlot, so a structural change cannot mutate a
-- slot -- it acquires a NEW key and PARKS the old. One button instead of a whole
-- container, and returning to a previous structure re-adopts the parked slot by key.
--
-- ⚠ FALLS BACK ON PURPOSE. AcquireSlot declines test frames (the preview declares its own
-- topology) and declines in combat whenever satisfying the request would need a secure op
-- (no owner yet, or a NEW slot — AddAuraSlot is combat-illegal; re-adoption still works).
-- Those keep the original per-indicator container, so behaviour is unchanged wherever the
-- shared path says no.
-- Both handle kinds answer GetFrame/Destroy/ApplyStyle, so the OOR fade and teardownExcept
-- need no knowledge of which one they hold.
local function isSlotHandle(h) return h ~= nil and h.GetButton ~= nil end

-- \30 (record separator) cannot appear in an instance key or a struct sig, so the two
-- halves can never collide into a shared key.
local function placedSlotKey(key, structSig) return key .. "\30" .. structSig end

local function placedAcquire(frame, key, structSig, cfg)
    local h
    if DF.AuraContainer.AcquireSlot then
        h = DF.AuraContainer:AcquireSlot(frame, placedSlotKey(key, structSig), {
            unit             = cfg.unit,
            filter           = cfg.filter,
            candidateFilters = cfg.candidateFilters,
            config           = cfg,
        })
    end
    if h then return h end
    return DF.AuraContainer:Create(frame, cfg)
end

-- Structural change. A slot cannot be rebuilt: park it and take a new key. A real
-- container still Rebuilds, still passing structSig as its own parking key.
local function placedRestructure(entry, frame, key, structSig, cfg)
    if isSlotHandle(entry.handle) then
        entry.handle:Park()
        local h = placedAcquire(frame, key, structSig, cfg)
        if h then entry.handle = h end
    else
        entry.handle:Rebuild(cfg, structSig)
    end
    return entry.handle
end

-- Selection edit. The two kinds take different tuning shapes: a container replaces the
-- max/sort/candidateFilters trio wholesale off a fresh config; a slot takes the two values
-- it actually owns. testEntries rides along on both so a test-mode rebuild previews the
-- NEW selection rather than a stale one.
local function placedTune(handle, cfg)
    if handle.config then handle.config.testEntries = cfg.testEntries end
    if isSlotHandle(handle) then
        handle:ApplyTuning(cfg.filter, cfg.candidateFilters)
    else
        handle:ApplyTuning(cfg)
    end
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
    if matchW or matchH then
        -- Match the VISIBLE health bar, not the frame's outer edge: the border band overlaps the
        -- outer max(padding, borderInset) px on each side, so a full-frameWidth bar overhangs the
        -- border by one inset per side ("slightly too wide"). Inset it the same amount the resource
        -- bar's Match Width does (Frames/Bars.lua). Read-free from config; PP-snapped like the frame.
        local usePP    = fdb.pixelPerfect and DF.PixelPerfect
        local padding  = tonumber(fdb.framePadding) or 0
        local border   = (fdb.frameShowBorder ~= false) and (tonumber(fdb.frameBorderSize) or 1) or 0
        if usePP then padding = DF:PixelPerfect(padding); border = DF:PixelPerfect(border) end
        -- User inset ON TOP of the frame's own edge band, applied per side to whichever
        -- axes are matching. Same sign convention as every other Inset in DF: positive
        -- pulls inward, negative pushes the bar past the health bar's edge.
        --
        -- ☠ WHY THIS IS A NUMBER AND NOT "follow the border indicator". The band above is
        -- everything DF can know statically about how much frame edge is occupied. An AD
        -- BORDER indicator occupies more of it, but it is conditional on its aura being
        -- present — and presence is SECRET on 12.1, so the bar can never widen back when
        -- that border drops off. Any "account for the border" option would therefore be a
        -- fixed reservation anyway; this is that reservation, without a cross-record
        -- reference that can be deleted or a hidden thickest-wins rule the panel cannot
        -- show. (Krathe's call, 2026-08-05 — the alternatives were weighed and dropped.)
        --
        -- ★ It composes with Match rather than replacing it, which is the point: unticking
        -- Match to hand-align also gives up tracking the frame's SIZE, so every hand-set
        -- bar broke the next time frame dimensions changed.
        local userInset = tonumber(indicator.matchInset) or 0
        if usePP then userInset = DF:PixelPerfect(userInset) end
        local edgeInset = math.max(padding, border) + userInset
        if matchW then
            local fw = tonumber(fdb.frameWidth) or width
            if usePP then fw = DF:PixelPerfect(fw) end
            width = fw - 2 * edgeInset
        end
        if matchH then
            local fh = tonumber(fdb.frameHeight) or height
            if usePP then fh = DF:PixelPerfect(fh) end
            height = fh - 2 * edgeInset
        end
    end
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
    spec.renderScale = tonumber(indicator.scale) or 1   -- see buildPlacedBorderSpec

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

-- Geometry for the expiry-reveal companion (DF.Expiration): the shape it overlays. A bar is a
-- RECTANGLE (width x height from resolveBarSize) so a Tint stretches to fill it; an icon/square
-- is SQUARE (baseSize). font follows the indicator's duration font. The engine does the x0.75
-- |T calibration + inset/match from here, so callers never repeat it.
local function alertGeometry(frame, indicator, isBar, defs)
    -- baseSize/font are global-defaultable, and this geometry feeds the companion's STRUCT
    -- sig — read raw, the alert kept sizing off the hardcoded 24 (and the Friz fallback font)
    -- while the icon it sits over honoured the global, so the two visibly disagreed.
    local font = defOf(indicator, "durationFont", defs, nil)
    if isBar then
        local w, h = resolveBarSize(frame, indicator)
        return { width = w, height = h, font = font }
    end
    return { baseSize = defOf(indicator, "size", defs, nil), font = font }
end

-- Bar style: the StatusBar fills the slot (no icon / no square / no cooldown swipe — the fill
-- IS the countdown). Fill colour / texture / orientation / reverse-fill / background from
-- config; native SetDurationBar (bindNative) drives the value. Duration text via the shared
-- styleable fontstring (colour-by-time buckets). Interpolation/direction are creation-frozen
-- opts (bind-once) — Immediate + RemainingTime match the legacy bar's SetTimerDuration call.
local function buildBarStyle(indicator, borderSpec, defs)
    local fr, fg, fb, fa = readADColor(indicator.fillColor)
    -- Colour Mode: a curve (DF / Classic) swaps the fill texture for a green->red ramp the
    -- native RemainingTime drain reveals, and forces a white tint (styleBarShared honours
    -- `curve`) so the ramp shows pure — secret-safe, same mechanism as the duration-bar strips.
    -- Static keeps the configured Bar Texture + Fill Color.
    local curveTex = DF.GetDurationBarCurveTexture and DF:GetDurationBarCurveTexture(indicator.barColorMode)
    local style = {
        icon     = { show = false },
        cooldown = { show = false },
        bar = {
            show          = true,
            fill          = true,
            texture       = curveTex or indicator.texture,
            curve         = curveTex and true or nil,
            color         = { fr, fg, fb, fa },
            bgColor       = indicator.bgColor,
            orientation   = (indicator.orientation == "VERTICAL") and "VERTICAL" or "HORIZONTAL",
            reverseFill   = indicator.reverseFill and true or false,
            interpolation = "Immediate",
            direction     = "RemainingTime",
        },
    }
    -- Legacy bar default for Show Duration is OFF (unlike icon/square, which default ON).
    -- defs.barText, NOT defs: GLOBAL_DEFAULT_MAP.bar inherits only the duration FONT block.
    -- The full table would leak showDuration / durationColor onto bars, which their card
    -- never offers. barCoSig must serialise through the same subset — see resolveDefs.
    style.duration = buildDurationTextSpec(indicator, false, 1.2, defs.cbt, defs.barText)   -- placed bar baseline: 1.2 scale, colour-by-time per adDB.defaults
    -- Pandemic cue on the bar itself. A frame mode rings/washes the whole bar rect (the
    -- region anchors to the button, which IS the bar here), so a Tint reads as "this bar
    -- is refreshable now" without needing the bar's own colours.
    style.pandemic = pandemicSpec(indicator)
    if borderSpec then style.border = { spec = borderSpec } end
    -- Expiry Alert element: rendered by a separate COMPANION SLOT, never by this
    -- button (one duration binding per button — see EXPIRY ALERT COMPANION SLOT).
    return style
end

-- Full row config for one placed bar (max=1 single-slot container). Same frame-level band as
-- the icon/square placed indicators — resolveLevel's absolute value, nothing added.
local function buildBarConfig(frame, unit, map, indicator, borderSpec, defs, mine)
    return {
        unit = unit,
        mode = "row",
        max = 1,
        -- ONE icon, so declare an AuraSlot rather than a one-icon AuraGroup:
        -- AddAuraGroup eagerly creates a whole FrameCreationBatchSize batch BEFORE
        -- maxFrameCount is applied; AddAuraSlot creates exactly one frame. Same
        -- selection (the slot carries the sort comparator), same size
        -- (styleButton_regions sizes both paths identically).
        singleSlot = true,
        filter = poolFilter(indicator, mine),   -- "HELPFUL|PLAYER" on My Buffs; othersOnly rides the other pool (structural)
        candidateFilters = { includeSpellIDs = map },
        testEntries = testEntryForMap(map),
        enabled = true,
        tooltips = adTooltipsOn(frame, "tooltipADBarsEnabled"),
        adBorderAnim = true,   -- opt into DF-owned border animations (see buildPlacedConfig)
        frameLevelOffset = resolveLevel(indicator, defs.level),
        frameStrata = resolveStrata(indicator, defs.strata),
        layout = buildBarLayout(frame, indicator),
        style = buildBarStyle(indicator, borderSpec, defs),
    }
end

-- ============================================================
-- EXPIRY ALERT COMPANION SLOT
-- One duration binding per button (in-game verified on 014b1bb: a second
-- SetDurationText call REPLACES the first — the indicator's own countdown went
-- dead), so the alert cannot ride the indicator's button. Each ALERTED placed
-- indicator instead gets an invisible COMPANION container: same spell map /
-- filter / geometry as the indicator — its 1-slot button coincides with the
-- indicator's rect, derived from CONFIG values only (the same layout builders
-- that position the indicator itself; no rect reads, §20c). No icon, no swipe,
-- no border, no stacks: the companion's ONLY output is the alert text, driven
-- through THAT button's single native duration binding with the alert-element
-- formatter (payload below threshold, EMPTY above — C-side, secret-safe).
-- expiryAlertAnchor/OffsetX/OffsetY place the text at that anchor point on the
-- (invisible) button; expiryAlertSize drives the font (TEXT) / |A escape
-- (GLYPH) size.
--
-- Handle family: companions live in the SAME store.placed family as their
-- indicators, keyed "<placedKey>:alert" (collision-proof: placedKey ends in
-- "#<id>"). Ensure / struct-vs-cosmetic sig compare / end-of-pass live-sweep
-- and ClearFrame's store.placed teardown all apply unchanged.
--
-- COMBAT COST: one extra standing container per ALERTED indicator ONLY —
-- OFF-mode indicators get no companion (their key is never marked live, so
-- the sweep destroys any stale one). Dedup: the companion tracks the exact
-- spell map its indicator already tracks, and the buff-row dedup union
-- (GetADTrackedSpellIDs) is built from the CONFIG records, not from live
-- handles — the companion adds nothing to it.
-- ============================================================
-- How far the alert is lifted above the thing it annotates. ONE constant, used by the live
-- companion (over its indicator's container) and by the AD canvas (over its preview slot),
-- so the two can never be nudged apart by editing one literal. At the +1 this used to be,
-- the companion's button landed at +3, INSIDE its own indicator's band: above that
-- indicator's icon but under its border, and under every sibling indicator's border at the
-- same configured level. That is why the glyph showed under the icons.
--
-- ☠ 13 -> 8 (Z-order review, 2026-08-07) -> 10 (2026-08-08). RE-MEASURED, as the previous
-- revision of this comment instructed, because the holder ladder moved again.
--
-- The 2026-08-07 pass measured a row at 7 thick against a ladder topping out at +5. That
-- ladder was wrong: it left the dispel ring under the icon border and no room beneath the
-- border for a pandemic tint. The corrected ladder is `DF.AuraButtonLevels`
-- (Frames/AuraContainer.lua) and runs button+2..+7, so measured from the container —
-- container +0, button +2, border +5, holders +4..+9 — a row is now **9 thick**.
--
-- 10 clears that with a level spare, and keeps an indicator plus its alert inside 19
-- levels, which is what lets the user-facing bands sit 20 apart. That is now a TIGHT fit:
-- one more rung on the ladder costs two levels here and busts the band.
-- RE-MEASURE THIS if the border level or the holder ladder moves again.
Factory.ALERT_ROW_LIFT = 10

-- ☠ ...EXCEPT FOR TINT, which wants the opposite. A wash covers the whole icon, so lifting
-- it a full row puts it over the indicator's own duration text and stack count and makes
-- both hard to read (Krathe, 2026-08-05 — the same fault the pandemic cue had, same fix).
-- A wash belongs ABOVE the icon art and BELOW everything carrying information.
--
-- ★ +1 is exactly where this started. The comment above records that at +1 "the companion's
-- button landed at +3, INSIDE its own indicator's band: above that indicator's icon but
-- under its border" — which was the bug for a GLYPH and is precisely what a TINT wants. The
-- constant was never wrong, it was MODE-BLIND: +1 is right for a wash and wrong for a
-- payload, +13 is right for a payload and wrong for a wash.
--
-- ⚠ The trade the low lift buys back is that a tint also sits under a SIBLING indicator's
-- border at the same configured level. That is the correct side of it — a wash is
-- background — and the alternative is the unreadable timer this fixes.
Factory.ALERT_TINT_LIFT = 1

-- The lift for one indicator's alert, by reveal type. Shared by the live companion and the
-- AD canvas so the two can never be nudged apart, which is the whole reason the lift was a
-- named constant rather than a literal in the first place.
function Factory.AlertLift(indicator)
    if DF.Expiration and DF.Expiration:Mode(indicator) == "TINT" then
        return Factory.ALERT_TINT_LIFT
    end
    return Factory.ALERT_ROW_LIFT
end

-- THE alert's render, as ONE table. The live companion slot and the AD canvas preview
-- BOTH take their style from here, so the reveal can never be styled two ways. It used to
-- be built live from BuildDurationSpec and on the canvas from a separate path, and that
-- split is exactly how the two drifted apart on layering twice over.
--
-- The reveal's duration spec (formatter + placement + opacity) is engine-owned; the factory
-- only wraps it in AuraContainer plumbing. geom (alertGeometry) is the target's shape — a
-- square for an icon (auto-match), a rectangle for a bar (Tint fills it).
--
-- nil = no reveal, for any of three reasons: the master toggle is off / the type is unset
-- (Expiration:Mode), the pre-12.1 formatter API is missing, or the indicator is
-- SHOW-WHEN-MISSING. That last gate used to live only on the canvas path, so live built a
-- companion for missing-mode indicators anyway — and since the companion is a NORMAL
-- (non-inverted) container, it revealed while the aura was PRESENT, i.e. exactly when the
-- indicator under it was hidden. A floating alert over nothing. "Warn me before this runs
-- out" and "show me while this is absent" are contradictory settings; the canvas and the
-- surrounding comments already treated it as nonsensical, so live now agrees with them.
local function alertSlotStyle(indicator, geom)
    if indicator.showWhenMissing then return nil end
    local dur = DF.Expiration:BuildDurationSpec(indicator,
        geom or { baseSize = indicator.size, font = indicator.durationFont })
    if not dur then return nil end
    return {
        icon     = { show = false },
        cooldown = { show = false },
        duration = dur,   -- the alert IS this invisible button's duration text
    }
end

local function buildAlertCompanionConfig(unit, map, indicator, layout, mine, geom, defs)
    local style = alertSlotStyle(indicator, geom)
    if not style then return nil end
    return {
        unit = unit,
        mode = "row",
        max = 1,
        -- ONE icon, so declare an AuraSlot rather than a one-icon AuraGroup:
        -- AddAuraGroup eagerly creates a whole FrameCreationBatchSize batch BEFORE
        -- maxFrameCount is applied; AddAuraSlot creates exactly one frame. Same
        -- selection (the slot carries the sort comparator), same size
        -- (styleButton_regions sizes both paths identically).
        singleSlot = true,
        filter = poolFilter(indicator, mine),   -- mirror the indicator: My Buffs alerts only on YOUR cast
        candidateFilters = { includeSpellIDs = map },
        testEntries = testEntryForMap(map),
        enabled = true,
        tooltips = false,   -- companion overlay: see adTooltipsOn (would fight its own indicator)
        -- A FULL ROW above the indicator's own band for a payload reveal, so the alert
        -- clears its own indicator AND any sibling sharing its configured level — but a
        -- LOW lift for TINT, which must sit under the timer it would otherwise wash over.
        -- See Factory.AlertLift.
        frameLevelOffset = Factory.AlertLift(indicator) + resolveLevel(indicator, defs.level),
        -- MUST mirror the indicator's strata: the level only orders the alert above the
        -- indicator WITHIN a band, so leaving the companion in the frame's band while the
        -- indicator moves to HIGH would strand the alert text underneath it.
        frameStrata = resolveStrata(indicator, defs.strata),
        layout = layout,   -- the INDICATOR's own layout: the invisible button coincides with its rect
        style = style,
    }
end

-- Canvas twin of the companion. The AD editor has no container row to layer inside — it
-- paints a single PREVIEW SLOT — so the alert there is a second preview slot laid over the
-- indicator's, taking the SAME style table. Options.lua then only has to position it: the
-- FontString, its font, anchor, offsets, alpha and holder level all come from the shared
-- spec via styleButton_regions, exactly as they do live.
--
-- That is the whole point of this function existing. The canvas used to hand-build its own
-- FontString and hand-set the layering to a literal that merely happened to match the live
-- one; when the live number moved, the canvas could not follow, because it was never
-- derived from it. Two bugs came out of that in one day.
function Factory:BuildAlertPreviewConfig(indicator, geom, layout, entries)
    local style = alertSlotStyle(indicator, geom)
    if not style then return nil end
    return {
        mode = "row",
        max = 1,
        -- ONE icon, so declare an AuraSlot rather than a one-icon AuraGroup:
        -- AddAuraGroup eagerly creates a whole FrameCreationBatchSize batch BEFORE
        -- maxFrameCount is applied; AddAuraSlot creates exactly one frame. Same
        -- selection (the slot carries the sort comparator), same size
        -- (styleButton_regions sizes both paths identically).
        singleSlot = true,
        filter = "HELPFUL",   -- canvas sample: the pool never gates a preview slot
        testEntries = entries,
        tooltips = false,
        layout = layout,
        style = style,
    }
end

-- Companion sigs. STRUCTURAL: EVERY alert key (alertElemStructKey — formatter and
-- placement are creation-frozen -> Rebuild) and frame level. TUNING: the identity map
-- AND the filter string, via the shared placedTuningSig — both mutate live, so neither
-- may sit here (a Rebuild strands frames permanently; see placedStructSig).
-- COSMETIC (ApplyStyle): the mirrored indicator geometry — dragging / resizing the
-- indicator hot-moves its companion — plus font and alpha. Raw-config, alloc-light,
-- computed per pass like the other placed sigs (FIX C discipline).
local function alertCompanionStructSig(indicator, geom, defs)
    return "xalert"
        .. "|xa=" .. alertElemStructKey(indicator, geom)
        .. "|fl=" .. tostring(resolveLevel(indicator, defs.level))
        .. "|fs=" .. tostring(resolveStrata(indicator, defs.strata) or "")
end

local function alertCompanionCoSig(frame, indicator, isBar, alpha, defs)
    -- Icon/square only for size/scale/font: on the bar path the geometry comes from
    -- resolveBarSize and defs.barText carries just the font block (GLOBAL_DEFAULT_MAP.bar).
    local gdefs = isBar and (defs and defs.barText) or defs
    local sx, sy
    if isBar then
        sx, sy = resolveBarSize(frame, indicator)
    else
        sx = math.max(8, tonumber(defOf(indicator, "size", defs, 24)) or 24); sy = sx
    end
    return (isBar and "b|" or "p|") .. tconcat({
        "an=" .. tostring((type(indicator.anchor) == "string" and indicator.anchor)
            or (isBar and "BOTTOM" or "TOPLEFT")),
        "ox=" .. tostring(tonumber(indicator.offsetX) or 0),
        "oy=" .. tostring(tonumber(indicator.offsetY) or 0),
        "sx=" .. tostring(sx), "sy=" .. tostring(sy),
        -- scale is icon/square-only (the bar has no global for it, and buildBarLayout reads
        -- it raw), so this passes `defs` not `gdefs` — on a bar both resolve identically.
        "sc=" .. tostring(tonumber(defOf(indicator, "scale", isBar and nil or defs, 1)) or 1),
        "fo=" .. tostring(defOf(indicator, "durationFont", gdefs, nil)),
        "al=" .. tostring(alpha),
    }, "|")
end

-- Ensure / update / retire the companion for ONE placed indicator (called from
-- both the bar and the icon/square branches of syncPlacedPool; never from the
-- show-when-missing branch — nothing to count down there). `indicator` is the
-- member-group EFFECTIVE record (position overrides included) so grouped
-- indicators carry their companion to the arranged position. Marks its key
-- live on success; alert OFF / indicator death leave the key dead and the
-- caller's end-of-pass sweep destroys the handle.
local function syncAlertCompanion(frame, placed, live, key, map, indicator, isBar, alpha, mine, defs)
    if not alertElemMode(indicator) then return end
    local akey = key .. ":alert"
    local geom = alertGeometry(frame, indicator, isBar, defs)   -- square (icon) or rect (bar)
    local structSig = alertCompanionStructSig(indicator, geom, defs)
    local tuningSig = placedTuningSig(map, poolFilter(indicator, mine))
    local coSig = alertCompanionCoSig(frame, indicator, isBar, alpha, defs)
    local entry = placed[akey]
    if entry and entry.structSig == structSig and entry.tuningSig == tuningSig
       and entry.coSig == coSig then
        live[akey] = true   -- steady state: no config build, no touch
        return
    end
    local layout = isBar and buildBarLayout(frame, indicator) or buildPlacedLayout(indicator, defs)
    local cfg = buildAlertCompanionConfig(frame.unit, map, indicator, layout, mine, geom, defs)
    if not cfg then return end   -- formatter unavailable: key stays dead -> sweep
    if not entry then
        local handle = placedAcquire(frame, akey, structSig, cfg)
        if handle then
            applyPlacedAlpha(handle, alpha)
            placed[akey] = { handle = handle, structSig = structSig,
                             tuningSig = tuningSig, coSig = coSig }
            live[akey] = true
        end
    elseif entry.structSig ~= structSig then
        -- ☠ Slot + combat: skip WITHOUT stamping, so the sig delta retries after combat
        -- (see the icon/square branch for why). `live` is still marked — the entry must
        -- not be swept for having deferred.
        if isSlotHandle(entry.handle) and InCombatLockdown() then
            live[akey] = true
        else
            entry.structSig, entry.tuningSig, entry.coSig = structSig, tuningSig, coSig
            -- Slot: park the old key, take a new one (a slot's regions are frozen at
            -- creation). Container fallback: Rebuild, with structSig as its own parking key --
            -- its definition is exactly "changing this needs a new container", which is also
            -- the condition for safely re-adopting one parked under it.
            placedRestructure(entry, frame, akey, structSig, cfg)
            applyPlacedAlpha(entry.handle, alpha)
            live[akey] = true
        end
    else
        -- Selection edit with the struct sig stable: swap the include map on the live
        -- container (row mode, so applyGroupTuning runs) instead of recreating it.
        if entry.tuningSig ~= tuningSig then
            entry.tuningSig = tuningSig
            placedTune(entry.handle, cfg)
        end
        if entry.coSig ~= coSig then
            entry.coSig = coSig
            entry.handle:ApplyStyle(cfg.style, cfg.layout)
            applyPlacedAlpha(entry.handle, alpha)
        end
        live[akey] = true
    end
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
-- Editor-canvas sample for the expiry-alert element (cfg.alertPreview). This is a WHOLE
-- PREVIEW-SLOT CONFIG, not a bare spec: Options.lua lays a second preview slot over the
-- indicator's and styles/paints it through StylePreviewSlot/PaintPreviewSlot, the same
-- pipeline the indicator itself and the group blocks already use.
--
-- It used to hand back only the duration spec, leaving the canvas to build its own
-- FontString and pick its own layering — a second renderer for one feature, and the reason
-- the two drifted. nil (no slot) whenever the live companion would also be absent, since
-- both now ask alertSlotStyle.
local function buildAlertPreview(indicator, layout, entries, geom)
    return Factory:BuildAlertPreviewConfig(indicator, geom, layout, entries)
end

function Factory:BuildPreviewConfig(frame, indicator, typeKey, spellID, defs)
    -- caller passes Factory.ResolveDefaults(adDB); nil = baseline (colour-by-time ON,
    -- no global level/strata). The canvas is a standalone preview, not layered over a
    -- unit frame, so level/strata are meaningless here and are simply not applied.
    if type(defs) ~= "table" then defs = { cbt = true, level = 0, strata = nil } end
    local entries = spellID and testEntryForMap({ [spellID] = true }) or nil
    if typeKey == "bar" then
        local borderSpec = placedBorderOn(indicator, false)
            and buildPlacedBorderSpec(frame, indicator, false) or nil
        local layout = buildBarLayout(frame, indicator)
        local geom = alertGeometry(frame, indicator, true, defs)
        local cfg = {
            mode = "row", max = 1, singleSlot = true, filter = "HELPFUL",
            adBorderAnim = true,
            layout = layout,
            style = buildBarStyle(indicator, borderSpec, defs),
            testEntries = entries,
            -- The alert slot mirrors the indicator's OWN layout, so its invisible button
            -- coincides with the bar's rect — the same relationship the live companion has.
            alertPreview = buildAlertPreview(indicator, layout, entries, geom),
        }
        -- The alert's structural key rides the sig so the canvas recreates its slots on any
        -- structural alert change, mirroring the live Rebuild rule (regions are create-only).
        local sig = "bar|" .. tostring(borderSpec ~= nil)
            .. "|" .. tostring(cfg.style.duration ~= nil)
            .. "|" .. durationFmtKey(indicator, false, defs.cbt)
            .. "|xa=" .. (cfg.alertPreview and alertElemStructKey(indicator, geom) or "")
            -- ☠ Pandemic MUST be here for the same reason the alert key is: the canvas
            -- only recreates its slot when this sig moves, and the cue's holder is
            -- create-once. Without it, turning pandemic on built the holder on the
            -- existing slot and turning it back off left the holder sitting there shown
            -- — a permanent green wash over the bar, which is exactly how this was
            -- reported (Krathe, 2026-08-05). Live was fine throughout because
            -- barStructSig carries it and a real Rebuild hands over a fresh button.
            .. "|pd=" .. pandemicStructKey(indicator)
        return cfg, sig
    end
    local isSquare = (typeKey == "square")
    -- ★ defs threads through here too: the preview must resolve the global defaults the
    -- SAME way live does, or the editor canvas and the unit frame disagree the moment a
    -- Global Default is set — previews differ in DATA, never in rendering.
    local hideIcon = defOf(indicator, "hideIcon", defs, false) and true or false
    local borderSpec = placedBorderOn(indicator, hideIcon)
        and buildPlacedBorderSpec(frame, indicator, hideIcon, nil, defs) or nil
    local layout = buildPlacedLayout(indicator, defs)
    local cfg = {
        mode = "row", max = 1, singleSlot = true, filter = "HELPFUL",
        adBorderAnim = true,
        layout = layout,
        style = buildPlacedStyle(indicator, isSquare, borderSpec, defs),
        testEntries = entries,
        -- The alert slot mirrors the indicator's OWN layout, so its invisible button
        -- coincides with the icon's rect — the same relationship the live companion has.
        -- ★ geom built through alertGeometry, exactly as syncAlertCompanion does. It used
        -- to be omitted, leaving alertSlotStyle/alertElemStructKey to fall back on their
        -- own `geom or { baseSize = indicator.size }` — which reads the instance RAW. Once
        -- the live path resolves size through the global defaults, that fallback sizes the
        -- canvas alert off a different number than the live one, so the preview and the
        -- unit frame disagree. Same builder, same inputs: differ in data, never rendering.
        alertPreview = buildAlertPreview(indicator, layout, entries,
            alertGeometry(frame, indicator, false, defs)),
    }
    -- The alert's structural key rides the sig so the canvas recreates its slots on any
    -- structural alert change, mirroring the live Rebuild rule (regions are create-only).
    local sig = (isSquare and "square|" or "icon|") .. tostring(hideIcon)
        .. "|" .. tostring(cfg.style.stacks ~= nil)
        .. "|" .. tostring(cfg.style.duration ~= nil)
        .. "|" .. tostring(borderSpec ~= nil)
        .. "|" .. durationFmtKey(indicator, true, defs.cbt, defs)
        .. "|xa=" .. (cfg.alertPreview and alertElemStructKey(indicator,
            alertGeometry(frame, indicator, false, defs)) or "")
        .. "|pd=" .. pandemicStructKey(indicator)   -- see the bar branch above
    return cfg, sig
end

-- STRUCTURAL signature: duration-text on/off + format key (SetDurationText / SetDuration
-- Bar bind ONCE), border on/off, frame level. Cosmetic bar styling is barCoSig.
-- Create-only properties ONLY; the identity map AND the filter string are live-tunable
-- and ride placedTuningSig (see placedStructSig for why a needless Rebuild is a leak).
local function barStructSig(indicator, borderOn, defs)
    return "bar"
        -- ☠ "|df=" .. durationFmtKey(...) was here. Duration formatting is NOT
        -- structural: SetDurationText is reset-then-apply and re-callable, and
        -- bindNative now re-binds on a spec change from ApplyStyle. It also folded
        -- in DF:GetAuraDurationUpdateInterval(), so one account-wide setting
        -- rebuilt every container on every frame. It is a restyle now.
        -- (No alert keys: the expiry alert lives on the COMPANION slot, whose own
        -- structSig carries alertElemStructKey — an alert edit rebuilds only it.)
        .. "|" .. (borderOn and "bd" or "")
        .. "|fl=" .. tostring(resolveLevel(indicator, defs.level))
        .. "|fs=" .. tostring(resolveStrata(indicator, defs.strata) or "")
        .. "|pd=" .. pandemicStructKey(indicator)   -- see placedStructSig
end

-- COSMETIC signature: size (width/height + match-frame + the fed frame size), anchor/offset/
-- scale/alpha, texture/fill/bg/orientation/reverse, duration-text styling, and the raw-config
-- border sig (no BuildSpec alloc). A change hot-applies via ApplyStyle(style, layout).
local function barCoSig(frame, indicator, borderOn, alpha, defs)
    local fdb = DF:GetFrameDB(frame) or {}
    return tconcat({
        -- Duration formatting is cosmetic now, not structural — see placedCoSig.
        -- ☠ defs.cbt, NOT nil — same reasoning as placedCoSig.
        "df=" .. durationFmtKey(indicator, false, defs and defs.cbt),
        "w="  .. tostring(tonumber(indicator.width)  or 60),
        "h="  .. tostring(tonumber(indicator.height) or 6),
        "mw=" .. tostring(indicator.matchFrameWidth ~= false and 1 or 0) .. ":" .. tostring(fdb.frameWidth),
        "mh=" .. tostring(indicator.matchFrameHeight and 1 or 0) .. ":" .. tostring(fdb.frameHeight),
        -- Match Width/Height now insets by the frame's border+padding (resolveBarSize), so those
        -- feed the cosmetic size too — a frame border/padding change must re-apply the bar layout.
        -- The whole edge-inset input set: the frame's own band, plus the user's Inset
        -- (cosmetic — resolveBarSize is pure config, so a drag hot-applies via ApplyStyle).
        "mi=" .. tostring(fdb.framePadding) .. ":" .. tostring(fdb.frameShowBorder) .. ":" .. tostring(fdb.frameBorderSize) .. ":" .. tostring(fdb.pixelPerfect)
            .. ":" .. tostring(tonumber(indicator.matchInset) or 0),
        "an=" .. tostring(indicator.anchor or "BOTTOM"),
        "ox=" .. tostring(tonumber(indicator.offsetX) or 0),
        "oy=" .. tostring(tonumber(indicator.offsetY) or 0),
        "sc=" .. tostring(tonumber(indicator.scale) or 1),
        "al=" .. tostring(alpha),
        "tex=" .. tostring(indicator.texture),
        "cm=" .. tostring(indicator.barColorMode or "STATIC"),   -- curve swaps texture+tint (cosmetic)
        "or=" .. tostring(indicator.orientation or "HORIZONTAL"),
        "rf=" .. tostring(indicator.reverseFill and 1 or 0),
        "fc=" .. colSig(indicator.fillColor),
        "bc=" .. colSig(indicator.bgColor),
        "du=" .. tconcat({
            -- showDuration + durationColor stay RAW: GLOBAL_DEFAULT_MAP.bar omits both, so
            -- buildBarStyle resolves them against defs.barText (which omits them too) and
            -- this must agree. Only the font block is global-defaultable on a bar.
            tostring(indicator.showDuration == true and 1 or 0),
            tostring(defOf(indicator, "durationFont", defs and defs.barText, nil)),
            tostring(defOf(indicator, "durationScale", defs and defs.barText, nil)),
            tostring(defOf(indicator, "durationOutline", defs and defs.barText, nil)),
            tostring(defOf(indicator, "durationAnchor", defs and defs.barText, nil)),
            tostring(defOf(indicator, "durationX", defs and defs.barText, nil)),
            tostring(defOf(indicator, "durationY", defs and defs.barText, nil)),
            -- Colour MODE verbatim (not a 1/0 flag): every mode is truthy, so a boolean
            -- token could never tell SMOOTH_PERCENT from STEP_SECONDS and a mode switch
            -- would not move the signature. (durationFmtKey carries the mode + its stops
            -- too; this keeps the per-indicator sig honest on its own.)
            tostring(indicator.durationColorByTime),
            colSig(indicator.durationColor),
        }, ","),
        "bd=" .. placedBorderRawSig(indicator, borderOn),
        "pd=" .. pandemicCoKey(indicator),   -- see placedCoSig
        -- (No alert entry: the expiry alert renders on its COMPANION slot with
        -- its own struct/cosmetic sigs — this container never carries it.)
    }, "|")
end

-- ============================================================
-- FILTER GROUPS  — A5
-- A filter group is a container-backed, self-managing row linked to 1+ registry
-- filters (DF.FilterRegistry): Blizzard creates/anchors the buttons, the group's
-- identity is the union of its linked filters resolved at build time
-- (R:ResolveSelection -> includeSpellIDs; post-overrides, all variant IDs), and
-- styling is uniform per group (icon size / grow / spacing / per-row / max /
-- anchor+offset). No per-spell members, no per-spell styling — member groups
-- (the position-arranger model) are untouched. Live-link semantics: the group
-- stores filter REFERENCES (preset keys + custom ids), so filter edits and
-- shipped preset updates propagate via R:SelectionSignature in the structural
-- sig. One handle per group per frame, keyed "fgroup:<id>" in store.fgroups.
-- ============================================================

local LEGACY_GROW = { RIGHT = "RIGHT_DOWN", LEFT = "LEFT_DOWN", UP = "UP_RIGHT", DOWN = "DOWN_RIGHT" }
local function groupGrowth(group)
    local g = group.growDirection
    if type(g) ~= "string" then return "RIGHT_DOWN" end
    if not g:find("_") then return LEGACY_GROW[g] or "RIGHT_DOWN" end
    return g
end

-- Test-preview entries for a filter group: up to 3 spells from the resolved map
-- (sorted for determinism), icon/name resolved from the static spell ID.
local function filterGroupTestEntries(map)
    local ids = {}
    for id in pairs(map) do ids[#ids + 1] = id end
    tsort(ids)
    local entries
    for i = 1, math.min(3, #ids) do
        entries = entries or {}
        local e = testEntryForMap({ [ids[i]] = true })
        if e then entries[#entries + 1] = e[1] end
    end
    return entries
end

-- Shared by filter groups (wrap default 8) and debuff groups (wrap default 4 —
-- their creation default; pass wrapDefault to match).
local function buildFilterGroupLayout(group, wrapDefault)
    return {
        size     = math.max(8, tonumber(group.iconSize) or 24),
        spacingX = tonumber(group.spacing) or 2,
        spacingY = tonumber(group.spacing) or 2,
        anchor   = (type(group.anchor) == "string" and group.anchor) or "TOPLEFT",
        growth   = groupGrowth(group),
        wrap     = math.max(1, tonumber(group.iconsPerRow) or wrapDefault or 8),
        offsetX  = tonumber(group.offsetX) or 0,
        offsetY  = tonumber(group.offsetY) or 0,
    }
end

-- Per-group APPEARANCE config (group.style): a curated sub-table of the placed
-- indicators' style keys — duration text (show / font / scale / outline / anchor /
-- offsets / colour-by-time / colour / hide-above), stack text (show + styling),
-- cooldown swipe, and the canonical Border* keys — shared by filter groups (both
-- stores) and debuff groups. Absent or empty = the pre-style uniform defaults, so
-- existing groups render (and serialize their configs) byte-identically.
local EMPTY_STYLE = {}
local function groupStyle(group)
    local s = group.style
    return type(s) == "table" and s or EMPTY_STYLE
end

-- Group border spec: reuses the placed builder (canonical Border* keys, BuildSpec,
-- animations via config.adBorderAnim) with the group's icon size fed to DF_DASH.
-- Unlike placed indicators (default ON), a group border is OFF unless the user
-- enabled it — ShowBorder must be exactly true (style-less groups have no ring today).
local function buildGroupBorderSpec(frame, group)
    local s = groupStyle(group)
    if s.ShowBorder ~= true then return nil end
    return buildPlacedBorderSpec(frame, s, false, math.max(8, tonumber(group.iconSize) or 24))
end

-- Uniform per-group style: native spell icon + cooldown swipe, default duration
-- text (bare NUMBER formatter — the same default the buff row / placed icons use)
-- and native stacks (>1, no formatter — secret trap). All static config.
-- group.style customises it through the SAME spec builders the placed indicators
-- use (buildDurationTextSpec / buildStackSpec / the border spec passed in); with
-- no style the output is byte-identical to the pre-style hardcoded table.
-- Does this group draw solid squares instead of spell icons? nil/"icon" = icon, which is
-- what every group shipped as, so an untouched group serializes and renders identically.
-- Bar is deliberately NOT an option: a bar is its own sized widget with its own layout
-- reservation, not a cell the group flow can lay out like the other two.
local function groupIsSquare(group)
    return groupStyle(group).shape == "square"
end

local function buildFilterGroupStyle(group, borderSpec)
    local s = groupStyle(group)
    local artInset = borderSpec and borderArtInset(borderSpec) or 0
    -- ☠ EXACTLY ONE of icon/square, and the square table is emitted even when hidden.
    -- Its PRESENCE is what tells AuraContainer "this slot is a square, do not run the icon
    -- path" — the placed builder carries the same warning, having shipped the bug where
    -- omitting it turned a square back into an icon.
    local art
    if groupIsSquare(group) then
        local r, g, b = readADColor(s.color)
        art = { square = { show = true, color = { r, g, b, 1 }, inset = artInset } }
    else
        art = { icon = { show = true, zoom = true, inset = artInset } }
    end
    local style = {
        -- Art insets by the border thickness so the ring frames it (placed-icon parity).
        icon     = art.icon,
        square   = art.square,
        cooldown = { show = true, swipe = not s.hideSwipe, reverse = true, numbers = false },
        duration = buildDurationTextSpec(s, true),
        stacks   = (s.showStacks ~= false) and buildStackSpec(s, 2, -1) or nil,
        -- Duration bar strip (Wave 3): the ROW's shared spec builder over the
        -- group.style key block. nil when disabled/absent — style-less groups
        -- stay byte-identical (no style.bar key at all).
        bar      = DF.BuildDurationBarSpec and DF:BuildDurationBarSpec(s, "durationBar") or nil,
        -- (No pandemic entry. The engine and every other AD family carry it, and the three
        -- lines needed here are the same three, but the GROUP CARD has no editor for it:
        -- Cards.lua's AddSection greys imperatively and never runs hideOn/disableOn/
        -- LayoutChildren, which is the entire mechanism GUI:CreatePandemicControls uses to
        -- show the right controls per Type. Wiring the render half alone would put settings
        -- in the profile that nothing can reach. Giving AddSection that seam — or an
        -- imperative variant of the shared helper — is the prerequisite, and it is a bigger
        -- job than this feature. Filter groups are arguably where a HoT row wants this most,
        -- so it is worth doing properly rather than quickly.)
    }
    if borderSpec then style.border = { spec = borderSpec } end
    return style
end

-- STRUCTURAL style signature for filter/debuff groups — which regions exist
-- (duration / stacks / border on-off) + the duration-text FORMAT KEY (SetDurationText
-- binds its formatter once per slot). Mirrors placedStructSig's treatment; appended
-- to each group's struct sig at the sync call sites. "" fields for style-less groups.
local function groupStyleStructSig(group)
    local s = groupStyle(group)
    -- ☠ SHAPE IS STRUCTURAL. It decides which art region exists (style.square vs
    -- style.icon), and regions are create-only — a cosmetic restyle cannot swap one for
    -- the other, so a shape change has to Rebuild. Putting it in the cosmetic sig would
    -- make the control appear to do nothing. "" for icon so every pre-shape group sigs
    -- byte-identically and does not rebuild on upgrade.
    return "|" .. (groupIsSquare(group) and "sq" or "")
        .. "|" .. ((s.showStacks ~= false) and "st" or "")
        .. "|" .. ((s.showDuration ~= false) and "du" or "")
        .. "|" .. (s.ShowBorder == true and "bd" or "")
        -- ☠ "|df=" .. durationFmtKey(...) was here. Duration formatting is NOT
        -- structural: SetDurationText is reset-then-apply and re-callable, and
        -- bindNative now re-binds on a spec change from ApplyStyle. It also folded
        -- in DF:GetAuraDurationUpdateInterval(), so one account-wide setting
        -- rebuilt every container on every frame. It is a restyle now.
        -- Duration bar PRESENCE only (mirror placedStructSig, which carries the full
        -- reasoning): the strip's layout reservation re-derives live through
        -- ApplyStyle -> applyLayout -> stripReservation -> SetAuraGroupLayout, and
        -- styleButton_regions re-anchors it every pass, so position/height/gap are NOT
        -- structural. "" when disabled — absent-bar groups sig identically whether
        -- style is absent, {}, or carries durationBarEnabled = false.
        .. "|" .. (s.durationBarEnabled == true and "bar" or "")
        -- (No pandemic entry — see buildFilterGroupStyle for why groups don't carry it yet.)
end

-- EDITOR PREVIEW CONFIG for one SAMPLE slot of a filter/debuff group: the same
-- style the live group container renders (buildFilterGroupStyle + the group
-- border spec) sized to a single slot — the editor styles/paints its pooled
-- sample frames with it (AuraContainer.StylePreviewSlot/PaintPreviewSlot),
-- so group Appearance edits preview through the factory's own rendering,
-- exactly like the placed indicators' canvas preview. Returns (config,
-- structSig): the editor recreates its sample frames when the sig changes
-- (regions are create-only, mirror the live Rebuild rule).
function Factory:BuildGroupPreviewConfig(frame, group)
    local borderSpec = buildGroupBorderSpec(frame, group)
    local cfg = {
        -- filter is inert here (also for debuff groups): the editor always
        -- supplies its own testEntries, so _paintTestSlot's category-pool
        -- fallback — the only preview reader of this string — never runs.
        mode = "row", max = 1, singleSlot = true, filter = "HELPFUL",
        adBorderAnim = borderSpec and true or nil,
        layout = { size = math.max(8, tonumber(group.iconSize) or 24) },
        style = buildFilterGroupStyle(group, borderSpec),
    }
    -- PREVIEW sig only (live groupStyleStructSig untouched): strip the
    -- hide-above THRESHOLD VALUE. Live slots bake it into a bind-once native
    -- formatter (value change = Rebuild), but the preview paint re-reads the
    -- formatter from this fresh config every pass — so a threshold drag can
    -- restyle in place instead of recreating the sample pool per slider tick.
    local sig = ("gslot" .. groupStyleStructSig(group)):gsub(":H[%d%.]+", ":H")
    return cfg, sig
end

-- The group's LIVE container layout (anchor, growth, wrap, size, spacing, offsets),
-- published so the editor canvas can pin its block and flow its sample icons through
-- AuraContainer.PinLayoutBox / AuraContainer.FlowSlots rather than deriving a corner and
-- a stride of its own. Same builder the live filter/debuff group containers are built
-- from — pass the same wrapDefault the live call site passes (8 filter, 4 debuff) or the
-- preview wraps at a different column count than the frame does.
function Factory:BuildGroupLayout(group, wrapDefault)
    return buildFilterGroupLayout(group, wrapDefault)
end

-- ============================================================
-- MEMBER-GROUP FLOW, published for the canvas
-- The three things live hands its member-group container that the canvas was deriving,
-- approximating, or dropping. Published as builders rather than documented as rules,
-- because a rule the canvas has to re-implement is a fork with extra steps — the whole
-- lesson of the placement work these sit beside.
-- ============================================================

-- A member's LAYOUT SIZE. Live resolves it through the defaults chain and floors it at 8
-- (collectGroupMembers); the canvas was reading indCfg.size with its own fallback and no
-- floor, so a member inheriting its size from defaults measured differently on the canvas
-- than on the frame, and an 8-or-under size disagreed outright.
function Factory:MemberSize(ind, defs)
    return math.max(8, tonumber(defOf(ind, "size", defs, 24)) or 24)
end

-- A member's PER-RECORD STYLE, in the shape recordGroupLayout reads (Frames/AuraContainer):
-- layout.size gives the record its own cell, layoutIndex fixes its order in the flow. This
-- is the same style buildMemberGroupConfig declares per record; the button half is omitted
-- because the canvas styles its slots through StylePreviewSlot and nothing in the layout
-- path reads it.
-- ☠ THE CELL IS NOT THE BUTTON. Flowing every member at the group's fallback cell is what
-- made a large member overlap its neighbour on the canvas and not in game — the flow asks
-- for a declared cell first (GetElementSize) and only measures the button when there is
-- none. Stamp this on the slot as dfImpRecStyle and the shared flow does the rest.
function Factory:MemberRecordStyle(ind, defs, memberIdx)
    return { layout = { size = self:MemberSize(ind, defs) }, layoutIndex = memberIdx }
end

-- The CONFIG a group's flow is laid out with: its layout AND its style.
-- ☠ THE STYLE IS NOT OPTIONAL. stripReservation reads config.style.bar to reserve the
-- duration strip's height, and that reservation is folded into elementHeight — so a config
-- carrying layout alone silently drops the padding live applies, and every row of a group
-- with a duration bar sat tighter on the canvas than on the frame.
function Factory:BuildGroupFlowConfig(frame, group, wrapDefault)
    return {
        layout = buildFilterGroupLayout(group, wrapDefault),
        style  = buildFilterGroupStyle(group, buildGroupBorderSpec(frame, group)),
    }
end

-- Per-group sort (Wave 2): the group card's Sort Order dropdown + My Auras
-- First / Reverse Order checkboxes, stored as OPTIONAL per-group fields
-- (sortOrder / sortMineFirst / sortReverse — the othersOnly idiom: absent on
-- pre-Wave-2 groups AND on fresh groups until the user touches a control).
-- Mapped through the ROW's shared mapper (DF:BuildAuraSort — one function,
-- callers feed their own storage). defaultOrder preserves each family's
-- pre-Wave-2 behaviour when the field is absent: fgroups passed no sort
-- ("DEFAULT" -> nil = Blizzard slot order), dgroups hardcoded ExpirationOnly
-- ("TIME") — upgrade-neutral by construction.
local function groupSort(group, defaultOrder)
    return DF.BuildAuraSort and DF:BuildAuraSort(group.sortOrder or defaultOrder,
        group.sortMineFirst, group.sortReverse) or nil
end

-- Sort's TUNING-sig component (sort is a live mutator — SetAuraGroupSortMethod
-- rides ApplyTuning, never Rebuild). Serializes the RAW fields and returns ""
-- when none is set, so pre-Wave-2 groups (and untouched new ones) produce
-- byte-identical tuning sigs to the pre-Wave-2 format.
local function groupSortSig(group)
    local o, m, r = group.sortOrder, group.sortMineFirst, group.sortReverse
    if o == nil and not m and not r then return "" end
    return "|so=" .. tostring(o) .. (m and ",M" or "") .. (r and ",R" or "")
end

-- Full row config for one filter group. Same frame-level band as the placed
-- indicators (40) so group icons read on top of the frame content.
-- othersOnly rides poolFilter (group-level "HELPFUL|!PLAYER" — the B1 slot
-- mechanism); only the flat-store UI offers the flag, but the read is
-- pool-agnostic (spec-store parity, mirror auraHasTrackedIndicator).
-- Takes the FRAME (not unit): the border spec needs the frame db (pixelPerfect).
-- adBorderAnim (the placed containers' DF-owned border-animation opt-in) is set
-- only when a border exists, keeping style-less configs byte-identical.
-- ☠ THE TEST PANEL'S COUNT APPLIES TO EVERY PREVIEW SURFACE, NOT JUST THE ROWS.
-- Features/Auras.lua was the only place that set testMax, and only for the buff and
-- debuff rows -- so an AD group fell through to its own maxIcons and previewed up to
-- TEN icons while the row beside it previewed two.
--
-- That is not a cosmetic difference. The preview declares ONE AuraGroup per icon (the
-- only shape that keeps entry k at position k), and every AuraGroup eagerly allocates
-- FrameCreationBatchSize (10) buttons before maxFrameCount is applied. So each surplus
-- preview icon costs TEN frames, permanently -- WoW never frees them. Ten icons instead
-- of two is 100 frames instead of 20, per container, per unit frame.
--
-- Measured from the debug log 2026-08-06: containers painting indices 1..10 and 1..11
-- with testBuffCount / testDebuffCount both set to 2.
--
-- Categorised off the resolved filter string, the same way _paintTestSlot picks its
-- pool, so a debuff group honours the Debuffs slider and a buff group the Buffs one.
local function adTestMax(frame, filterStr)
    local db = DF:GetFrameDB(frame) or {}
    if type(filterStr) == "string" and filterStr:find("HARMFUL") then
        return db.testDebuffCount or 2
    end
    return db.testBuffCount or 2
end

-- defs: the global AD defaults. Its `level` is the account-wide "Default Frame Level" —
-- see the frameLevelOffset note below for why a group must follow it.
local function buildFilterGroupConfig(frame, map, group, mine, defs)
    local borderSpec = buildGroupBorderSpec(frame, group)
    local filt = poolFilter(group, mine)
    return {
        unit = frame.unit,
        mode = "row",
        max = math.max(1, tonumber(group.maxIcons) or 8),
        filter = filt,
        -- Preview-only cap. Live still renders `max`; only test mode clamps.
        testMax = adTestMax(frame, filt),
        sort = groupSort(group, "DEFAULT"),
        candidateFilters = { includeSpellIDs = map },
        testEntries = filterGroupTestEntries(map),
        enabled = true,
        tooltips = adTooltipsOn(frame, "tooltipADGroupsEnabled"),
        adBorderAnim = borderSpec and true or nil,
        -- ☠ Was a hardcoded 40, which is only coincidentally the default of the account-wide
        -- "Default Frame Level" (adDB.defaults.indicatorFrameLevel -> defs.level). The control
        -- is labelled generically and every placed indicator resolves through it, so raising
        -- the slider lifted the indicators and left the groups pinned at 40 — AD's own output
        -- split across two planes, with the groups stranded underneath their own indicators.
        -- Tracking defs.level keeps the two co-planar at EVERY slider value, not just at 40,
        -- and is a no-op for anyone who never moved it.
        -- Groups have no per-group level key (GLOBAL_DEFAULT_MAP has no `group` entry), so
        -- there is nothing to override it with — the global is the whole chain here.
        frameLevelOffset = (defs and defs.level) or 40,
        layout = buildFilterGroupLayout(group),
        style = buildFilterGroupStyle(group, borderSpec),
    }
end

-- ============================================================
-- LAYOUT-GROUP MEMBERS AS ONE CONTAINER  — v4 compaction parity
-- ============================================================
-- A layout group used to render as N single-slot containers, each pinned at an
-- offset computed from the member's INDEX IN THE CONFIG. Nothing about presence
-- entered that maths, so an absent member left a hole and the rest held station —
-- the v4 behaviour people are missing, where icons slid up to close the gap.
--
-- ☠ THE HOLE CANNOT BE CLOSED BY ARITHMETIC. Compacting means knowing which
-- members are actually up, and aura presence is a secret read on 12.1. The only
-- thing that knows is the container, so the members have to share one.
--
-- One container, one GROUP per member:
--   * each group's candidateFilters is that member's own spell-ID set, so
--     membership IS the predicate and its styling needs no read to justify it
--   * each carries `button` — its full placed-indicator style — which the shared
--     styler applies through the record's own config view (see styleConfigFor)
--   * each carries `layoutIndex`, which is what preserves the user's chosen ORDER;
--     Blizzard sorts flow groups by it, and an empty group contributes neither
--     elements nor spacing, so the survivors close up in the configured order
--
-- The container's own `style`/`layout` stay the GROUP's (its Appearance section and
-- its anchor/growth/spacing/wrap) — that is the base a member style overrides, and
-- the arrangement the flow lays out into.
local function buildMemberGroupConfig(frame, group, recs, mine, defs)
    local borderSpec = buildGroupBorderSpec(frame, group)
    -- Group-level string. Only the test cap reads it now -- matching is per record.
    local filt = poolFilter(group, mine)
    local filters, unionMap = {}, {}
    for i, r in ipairs(recs) do
        for id in pairs(r.map) do unionMap[id] = true end
        -- ☠ Compare against nil, not truthiness: `false` is a legitimate resolved
        -- mode (others' auras) and `r.mine or mine` would silently promote it.
        local rm = r.mine
        if rm == nil then rm = mine end
        filters[i] = {
            -- Resolved per member, so a self-only aura drops the caster filter for
            -- its own record while every neighbour keeps theirs.
            filter = poolFilter(group, rm),
            -- ☠ THE AURA NAME IS LOAD-BEARING, NOT DECORATION. Indicator ids are
            -- unique only WITHIN one aura (nextIndicatorID is a per-aura counter
            -- starting at 1), so "m1" collided for every user who placed one
            -- indicator per spell -- and the engine ASSERTS on a duplicate group
            -- key ("aura group 'm1' already exists", CustomAuraContainer), which
            -- our pcall swallowed. First member rendered, the rest silently never
            -- did. Shipped that way; two field reports on release day. It passed
            -- in-game testing only because a dev profile's add/delete history
            -- happens to produce distinct ids.
            -- Still keyed by identity rather than ordinal: reordering the group
            -- must move icons, not re-key every group and force a rebuild.
            key = "m:" .. tostring(r.auraName) .. ":" .. tostring(r.indicatorID),
            candidateFilters = { includeSpellIDs = r.map },
            style = {
                button      = buildPlacedStyle(r.indicator, r.isSquare, r.borderSpec, defs),
                layout      = { size = r.size },
                layoutIndex = i,
            },
        }
    end
    return {
        unit = frame.unit,
        mode = "row",
        max = #recs,
        -- The list IS the filter (normalizeFilters takes records); the plain string
        -- stays only as what each record's own filter resolves to.
        filter = filters,
        testMax = adTestMax(frame, filt),
        sort = groupSort(group, "DEFAULT"),
        -- Config-wide union: the per-record maps are the real selection, but the
        -- buff-row dedup and the test preview both read the container-level one.
        candidateFilters = { includeSpellIDs = unionMap },
        testEntries = filterGroupTestEntries(unionMap),
        enabled = true,
        tooltips = adTooltipsOn(frame, "tooltipADIndicatorsEnabled"),
        adBorderAnim = true,
        frameLevelOffset = (defs and defs.level) or 40,
        layout = buildFilterGroupLayout(group),
        style = buildFilterGroupStyle(group, borderSpec),
    }
end

-- Exclude-kind guard warned once per group (per session) — the sync runs per
-- frame per aura event, so an unconditional DebugWarn would spam the console.
-- Keyed by the group TABLE, not group.id: ids are only unique within one
-- preset's config, so id keys could collide across profiles/presets. Weak
-- keys let deleted/swapped-out group tables GC.
local fgroupExcludeWarned = setmetatable({}, { __mode = "k" })

-- COSMETIC signature: the layout fields + group.style's cosmetic fields (swipe,
-- duration/stack styling, the raw-config border sig) hot-apply via
-- ApplyStyle(style, layout). Identity (selection signature) + max slot count +
-- the region set (groupStyleStructSig) are structural, folded at the call site.
local function filterGroupCoSig(group, wrapDefault)
    local s = groupStyle(group)
    return tconcat({
        -- Duration formatting moved out of groupStyleStructSig to here — see placedCoSig.
        -- It has to sit in SOME signature or a format change would move nothing and
        -- silently do nothing.
        "df=" .. durationFmtKey(s, true),
        -- Square FILL COLOUR is cosmetic and belongs here, not in the struct sig: the
        -- region already exists (shape is what's structural), so a colour change restyles
        -- in place. "" for an icon group, so nothing pre-shape sigs differently.
        "sc=" .. (groupIsSquare(group) and colSig(s.color) or ""),
        "sz=" .. tostring(math.max(8, tonumber(group.iconSize) or 24)),
        "an=" .. tostring(group.anchor or "TOPLEFT"),
        "ox=" .. tostring(tonumber(group.offsetX) or 0),
        "oy=" .. tostring(tonumber(group.offsetY) or 0),
        "gr=" .. groupGrowth(group),
        "wr=" .. tostring(math.max(1, tonumber(group.iconsPerRow) or wrapDefault or 8)),
        "sp=" .. tostring(tonumber(group.spacing) or 2),
        "sw=" .. tostring(s.hideSwipe and 1 or 0),
        "du=" .. tconcat({
            tostring(s.durationFont), tostring(s.durationScale),
            tostring(s.durationOutline), tostring(s.durationAnchor),
            tostring(s.durationX), tostring(s.durationY),
            colSig(s.durationColor),
        }, ","),
        "stk=" .. tconcat({
            tostring(s.stackFont), tostring(s.stackScale),
            tostring(s.stackOutline), tostring(s.stackAnchor),
            tostring(s.stackX), tostring(s.stackY),
            colSig(s.stackColor),
        }, ","),
        "bd=" .. placedBorderRawSig(s, s.ShowBorder == true),
        -- Duration bar STYLING (Wave 3): texture/colours/reverse-fill hot-apply
        -- via ApplyStyle (geometry + presence live in groupStyleStructSig).
        -- Gated on Enabled so stray durationBar* keys on a disabled bar emit the
        -- same "" as a never-barred group — no churn, sigs identical.
        "dbar=" .. (s.durationBarEnabled == true and tconcat({
            tostring(s.durationBarTexture), colSig(s.durationBarColor),
            colSig(s.durationBarBGColor), tostring(s.durationBarReverseFill and 1 or 0),
            -- ☠ FOUR KEYS WERE IN NO SIGNATURE on the group families -- Position, Height,
            -- Gap and, unlike the placed family, ColorMode too. BuildDurationBarSpec reads
            -- all four; groupStyleStructSig carries only presence. So enabling a group's
            -- duration bar and then picking a DF / Classic colour curve left it on the
            -- static texture until something else moved the cosmetic sig.
            --
            -- Same rule as the placed side: cosmetic, never structural -- a struct-sig
            -- entry would mint a new slot key per edit and AddAuraSlot is add-only.
            tostring(s.durationBarPosition or "BOTTOM"),
            tostring(tonumber(s.durationBarHeight) or 4),
            tostring(tonumber(s.durationBarGap) or 1),
            tostring(s.durationBarColorMode or "STATIC"),
        }, ",") or ""),
        -- (No pandemic entry — see buildFilterGroupStyle for why groups don't carry it yet.)
    }, "|")
end

-- ============================================================
-- DEBUFF CATEGORY GROUPS — C1
-- A debuff group is a container-backed row driven by the SAME native category
-- records the main debuff row uses: its `selection` table maps onto the row's
-- flat filter keys (a facade db) and feeds DF:BuildDebuffFilterRecords — the
-- exposed form of the row's own resolver — so a group configured like the row
-- produces byte-identical records (per-record filter strings, negation-token
-- dedup, Hide Long / Keep Important semantics, the > 0 minutes guard). One
-- handle per enabled group per frame, keyed "dgroup:<id>" in store.dgroups —
-- the same live/sweep lifecycle as the A5 filter groups. Empty selection (no
-- categories) resolves to NO records -> the group renders nothing and is swept.
-- The facade NEVER passes a claim set (claims derive from these very groups —
-- feeding them back would be circular; only the real row consults claims).
-- ============================================================

-- Facade scratch (module-level, wiped per build): BuildDebuffFilterRecords only
-- READS flat scalar keys synchronously, so one shared table serves every group.
local dgroupFacade = {}
local function buildDebuffGroupRecords(group)
    local sel = group.selection
    if type(sel) ~= "table" then return nil end
    wipe(dgroupFacade)
    dgroupFacade.directDebuffShowAll          = false
    dgroupFacade.debuffFilterBoss             = sel.boss and true or false
    dgroupFacade.debuffFilterRole             = sel.role and true or false
    dgroupFacade.debuffFilterPriority         = sel.priority and true or false
    dgroupFacade.debuffFilterCrowdControl     = sel.crowdControl and true or false
    dgroupFacade.debuffFilterRaid             = sel.raid and true or false
    dgroupFacade.debuffFilterDispellable      = sel.dispellable and true or false
    dgroupFacade.directDebuffDispellableMode  = sel.dispellableMode or "PLAYER"
    dgroupFacade.debuffMaxDurationEnabled     = sel.hideLong and true or false
    -- The resolver's own "> 0 minutes" guard holds through the facade: 0 or nil
    -- minutes -> maxDur nil, exactly as on the row (no duplicate guard here).
    dgroupFacade.debuffMaxDurationMinutes     = sel.hideLongMinutes or 5
    dgroupFacade.debuffMaxDurationKeepImportant = sel.keepImportant ~= false
    return DF.BuildDebuffFilterRecords and DF:BuildDebuffFilterRecords(dgroupFacade) or nil
end

-- Version-keyed record cache (mirror of fgroupResCache): building records walks
-- the resolver and signing serializes every record — too heavy per frame per
-- aura event. Weak GROUP-TABLE keys (deleted groups GC; profile/preset switches
-- swap the tables and self-invalidate), entries keyed to DF.auraLayoutVersion
-- (C2's group edits ride the structural refresh chain, which bumps it). The
-- cached records table is SHARED across frames within a version — immutable.
-- Signed in SPLIT halves (Wave 1, the row serializers via DF): struct = record
-- strings + keys (Rebuild), tuning = per-record candidateFilters (in-place).
local dgroupResCache = setmetatable({}, { __mode = "k" })
local function resolveDebuffGroup(group)
    local ver = DF.auraLayoutVersion or 0
    local c = dgroupResCache[group]
    if c and c.version == ver then return c.records, c.structSig, c.tuningSig end
    local records = buildDebuffGroupRecords(group)
    local structSig = records and DF.DebuffFilterRecordsStructSig and DF:DebuffFilterRecordsStructSig(records) or ""
    local tuningSig = records and DF.DebuffFilterRecordsTuningSig and DF:DebuffFilterRecordsTuningSig(records) or ""
    dgroupResCache[group] = { version = ver, records = records, structSig = structSig, tuningSig = tuningSig }
    return records, structSig, tuningSig
end

-- Full row config for one debuff group. Records ride as cfg.filter exactly like
-- the main debuff row's filterList (per-record candidateFilters; no top-level
-- map — harmful spell-ID maps are inert on friendly frames). Style is the
-- uniform filter-group style; sort is the per-group Wave-2 mapping with the
-- family default "TIME" -> { method = "ExpirationOnly" } — exactly the old
-- hardcode (and the ROW's own Config-default mapping), so untouched groups
-- sort identically to before. No testEntries: the test paint's HARMFUL
-- fallback pool (TestData.debuffs) previews these rows, same as the main
-- debuff row's preview data.
local function buildDebuffGroupConfig(frame, records, group, defs)
    local borderSpec = buildGroupBorderSpec(frame, group)
    return {
        unit = frame.unit,
        mode = "row",
        max = math.max(1, tonumber(group.maxIcons) or 4),
        filter = records,
        sort = groupSort(group, "TIME"),
        enabled = true,
        tooltips = adTooltipsOn(frame, "tooltipADGroupsEnabled"),
        adBorderAnim = borderSpec and true or nil,
        frameLevelOffset = (defs and defs.level) or 40,   -- see buildFilterGroupConfig
        layout = buildFilterGroupLayout(group, 4),
        style = buildFilterGroupStyle(group, borderSpec),
    }
end

-- ============================================================
-- MEMBER LAYOUT GROUPS — position arranger (12.1 port)
-- A member ("classic") layout group arranges its members' PLACED indicators in
-- a grid computed from the group's settings (anchor / offset / grow direction /
-- icons per row / spacing). Legacy applied this at render time over the ACTIVE
-- members only (the legacy Engine group-offset pass, since removed — icons compacted as auras came
-- and went); on 12.1 aura presence is SECRET, so slots are STATIC: each member
-- owns the grid cell of its member index, exactly matching the editor preview
-- (Options.lua RefreshPlacedIndicators). An absent (or eye-hidden) member
-- leaves its cell empty — no compaction, by design (read-free).
--
-- Mechanics: positions are recomputed per SyncFrame pass from the LIVE group
-- tables (cheap arithmetic — group edits apply immediately, no version cache to
-- go stale) into pass-stamped scratch. Each member gets a persistent WRAPPER
-- table (__index = its indicator record) whose anchor/offsetX/offsetY are the
-- arranged values; the placed sync below reads position through the wrapper, so
-- the arranged position flows into the container layout AND the cosmetic sig
-- (group edits hot-apply via ApplyStyle). Zero steady-state allocation: wrapper
-- + entry alloc once per instanceKey, mutated in place thereafter.
-- ============================================================

local mgScratch = {}   -- instanceKey -> { pass, base = indicator record, wrapper }
local mgPass = 0

local function memberGrowthOffset(d, s)
    if d == "LEFT" then return -s, 0 elseif d == "RIGHT" then return s, 0
    elseif d == "UP" then return 0, s elseif d == "DOWN" then return 0, -s end
    return 0, 0
end

-- ★ THE ONE PLACE A MEMBER'S GRID CELL IS COMPUTED. Live (arrangeGroupList, below) and
-- the Aura Designer's editor canvas both ask this; neither keeps a copy. The maths lived
-- in FOUR places at once — here and three times in the editor — and they had already
-- drifted: one dropped `scale`, and a round of fixes converted exactly one of them while
-- the commit implied the class was closed.
--
-- ☠ SCOPE: this answers for the members the container does NOT pack (bars, show-when-
-- missing badges), which live places itself at their FULL member index. Packed members
-- are placed by the group container's flow, and the canvas mirrors that through
-- AuraContainer.FlowSlots — not by gridding them here. Feeding a packed member into this
-- would reintroduce the hand-rolled flow this replaced.
-- Stride comes from DF:ResolveAuraLayoutStep so there is one definition of it addon-wide.
function Factory:MemberGridOffset(group, size, scale, memberIdx, totalCount)
    local spacing = tonumber(group.spacing) or 2
    local wrap = tonumber(group.iconsPerRow) or 8
    if wrap <= 0 then wrap = 1 end
    local primary, secondary = strsplit("_", group.growDirection or "RIGHT")
    if not secondary then
        secondary = (primary == "RIGHT" or primary == "LEFT") and "DOWN" or "RIGHT"
    end
    local gox, goy = tonumber(group.offsetX) or 0, tonumber(group.offsetY) or 0
    local step = DF:ResolveAuraLayoutStep(tonumber(size) or 24, tonumber(size) or 24,
        spacing, spacing, tonumber(scale) or 1, nil)
    local total = math.max(1, tonumber(totalCount) or 1)
    local activeIdx = math.max(0, (tonumber(memberIdx) or 1) - 1)
    local col = activeIdx % wrap
    local row = math.floor(activeIdx / wrap)
    local sX, sY = memberGrowthOffset(secondary, step)
    local oX, oY
    if primary == "CENTER" then
        local iconsInRow = wrap
        local lastRow = math.floor((total - 1) / wrap)
        if row == lastRow then
            iconsInRow = ((total - 1) % wrap) + 1
        end
        local centerOff = -((iconsInRow - 1) * step) / 2
        if sX ~= 0 then
            oX = gox + (row * sX)
            oY = goy + centerOff + (col * step)
        else
            oX = gox + centerOff + (col * step)
            oY = goy + (row * sY)
        end
    else
        local pX, pY = memberGrowthOffset(primary, step)
        oX = gox + (col * pX) + (row * sX)
        oY = goy + (col * pY) + (row * sY)
    end
    return (type(group.anchor) == "string" and group.anchor) or "TOPLEFT", oX, oY
end

-- Arrange one group array's members over ONE aura pool (no pass bump — the
-- caller stamps the pass once for both pools). keyPrefix mirrors placedKey's:
-- "" for the spec pool, OTHER_PREFIX for the other pool, so scratch keys line
-- up with the instanceKeys syncPlacedPool feeds memberEffective. Returns true
-- when at least one member was arranged.
--
-- ☠ This note used to read "the math is a verbatim mirror of the editor preview
-- (Options.lua RefreshPlacedIndicators group-position block) so preview and live can
-- never disagree." Every clause of that was false: it was not verbatim (the two called
-- different stride helpers), the block had moved to another file, and there were three
-- preview copies, not one. A comment cannot make two implementations agree — only one
-- implementation can, which is why the cell now comes from Factory:MemberGridOffset.
local function arrangeGroupList(groups, auras, adDB, keyPrefix)
    local any = false
    for _, group in ipairs(groups) do
        local members = type(group) == "table" and group.kind ~= "filter" and group.members
        if members and #members > 0 then
            local totalCount = #members
            for memberIdx, member in ipairs(members) do
                -- Find the member's indicator record (size/scale feed the grid step).
                local auraCfg = auras and auras[member.auraName]
                local indCfg
                if type(auraCfg) == "table" and auraCfg.indicators then
                    for _, ind in ipairs(auraCfg.indicators) do
                        if ind.id == member.indicatorID then indCfg = ind; break end
                    end
                end
                if indCfg then
                    local size = tonumber(indCfg.size) or (adDB.defaults and adDB.defaults.iconSize) or 24
                    local scale = tonumber(indCfg.scale) or (adDB.defaults and adDB.defaults.iconScale) or 1.0
                    local gAnchor, oX, oY =
                        Factory:MemberGridOffset(group, size, scale, memberIdx, totalCount)
                    local key = keyPrefix .. member.auraName .. "#" .. tostring(member.indicatorID)
                    local e = mgScratch[key]
                    if not e or e.base ~= indCfg then
                        e = { base = indCfg, wrapper = setmetatable({}, { __index = indCfg }) }
                        mgScratch[key] = e
                    end
                    e.pass = mgPass
                    local w = e.wrapper
                    w.anchor, w.offsetX, w.offsetY = gAnchor, oX, oY
                    any = true
                end
            end
        end
    end
    return any
end

-- Compute this pass's arranged positions for BOTH pools' member groups: the
-- spec-keyed groups over the spec pool (unprefixed keys) and the flat
-- spec-independent adDB.otherLayoutGroups over the other pool (OTHER_PREFIX'd
-- keys — placedKey's scheme, collision-proof by B1's construction). One pass
-- stamp covers both, so a shared same-named key can never cross-match (the
-- prefix disambiguates; the base identity check guards the rest). Returns
-- hasMG (spec pool), hasOtherMG (other pool).
local function arrangeMemberGroups(adDB, spec, specAuras, otherAuras)
    mgPass = mgPass + 1
    local hasMG, hasOtherMG = false, false
    local specGroups = specAuras and adDB.layoutGroups and adDB.layoutGroups[spec]
    if specGroups then
        hasMG = arrangeGroupList(specGroups, specAuras, adDB, "")
    end
    local otherGroups = otherAuras and adDB.otherLayoutGroups
    if otherGroups then
        hasOtherMG = arrangeGroupList(otherGroups, otherAuras, adDB, OTHER_PREFIX)
    end
    return hasMG, hasOtherMG
end

-- Effective placed record: the group wrapper (arranged anchor/offset shadowing
-- the record's own) when this indicator is a member arranged THIS pass, else
-- the raw record. base identity check guards records swapped under a reused key
-- (profile/spec switch) and cross-adDB key collisions.
local function memberEffective(hasMG, key, indicator)
    if hasMG then
        local e = mgScratch[key]
        if e and e.pass == mgPass and e.base == indicator then return e.wrapper end
    end
    return indicator
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
    if not p then
        -- Ad-hoc "#<id>" keys resolve directly — mirror BuildADIdentityFilters
        local adHocID = type(auraName) == "string" and auraName:match("^#(%d+)$")
        if adHocID then return tonumber(adHocID) end
        -- SpellDB fallback (all-spec support) — mirror BuildADIdentityFilters
        local R = DF.FilterRegistry
        local rec = R and R.GetSpellByName and R:GetSpellByName(auraName)
        p = rec and rec.id
    end
    return p
end

-- Static icon texture for a missing indicator (mirrors the legacy Engine synthetic-aura builder, which no longer exists): the
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
local function buildPlacedMissingConfig(unit, map, indicator, mine, defs)
    local size = math.max(8, tonumber(defOf(indicator, "size", defs, 24)) or 24)
    return {
        unit = unit,
        mode = "missing",
        -- My Buffs + missing = "show while MY OWN cast is absent" (another player's
        -- copy no longer satisfies it); othersOnly + missing = "show while no OTHER
        -- player's cast is present".
        filter = poolFilter(indicator, mine),
        candidateFilters = { includeSpellIDs = map },
        badge = { w = size, h = size },
        enabled = true,
        frameLevelOffset = resolveLevel(indicator, defs.level),
        frameStrata = resolveStrata(indicator, defs.strata),
    }
end

-- Missing-mode config for a FRAME-LEVEL effect (healthbar / background / border): the window/
-- badge covers the target region, sized READ-FREE from the frame's CONFIGURED width/height
-- (fdb.frameWidth/frameHeight — the same fed-size the border uses; the live rect is secret on
-- 12.1). The push cell width (AuraContainer build = badge.w + MISSING_PAD) is therefore >= the
-- window width, so presence evacuates the whole region FULLY. Frame-level band matches the
-- present frame-level effects (border uses +10; tints seat lower — see callers).
local function buildFrameLevelMissingConfig(unit, map, w, h, levelOffset, filter)
    return {
        unit = unit,
        mode = "missing",
        filter = filter or "HELPFUL",
        candidateFilters = { includeSpellIDs = map },
        badge = { w = math.max(1, w), h = math.max(1, h) },
        enabled = true,
        frameLevelOffset = levelOffset,
    }
end

-- Style a PLACED missing badge: static spell icon (or solid colour square), optional border
-- (animation stripped), optional desaturate. No cooldown / duration / stacks (nothing to show
-- while absent). The badge is handle-owned; we attach art to GetBadgeFrame().
local function stylePlacedMissingBadge(h, frame, spec, auraName, indicator, isSquare, defs)
    local badge = h.GetBadgeFrame and h:GetBadgeFrame()
    if not badge then return end
    local hideIcon = defOf(indicator, "hideIcon", defs, false) and true or false

    -- Border (config, read-free) — animation ALWAYS stripped on a missing badge (orphan-ticker
    -- hazard; see section header + Auras.lua:3122). buildPlacedBorderSpec returns nil when the
    -- border resolves off (or hideIcon), matching the present path.
    local borderSpec = buildPlacedBorderSpec(frame, indicator, hideIcon, nil, defs)
    if borderSpec then borderSpec.animation = nil end
    local artInset = borderSpec and borderArtInset(borderSpec) or 0

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
-- ☠ filter = the slot filter string (poolFilter(cfg)), and here it STAYS structural,
-- unlike every other AD family since 2026-08-04. Not an oversight: NativeBackend
-- applyGroupTuning returns early for mode == "missing" by design — the layout-push
-- inversion that makes the badge clear its clip window is load-bearing and hard-won
-- (10d6048e), and nothing has exercised it against a live candidateFilters/filter swap.
-- The identity map is structural here for the same reason. Do not move either onto the
-- tuning path without enabling missing mode in the engine first.
local function syncFrameLevelMissing(store, keyName, map, frame, parent, anchorTo, w, hgt, levelOffset, coSig, apply, filter)
    w = math.max(1, tonumber(w) or 1); hgt = math.max(1, tonumber(hgt) or 1)
    local structSig = includeSig(map) .. "|miss|" .. (filter or "HELPFUL")
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
        local handle = DF.AuraContainer:Create(parent, buildFrameLevelMissingConfig(frame.unit, map, w, hgt, levelOffset, filter))
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
-- SOUND INDICATOR  (native, event-driven)  — P4.5 + per-event triggers
-- C_UnitAuras.AddAuraSound(trigger, { unitToken, spellID, soundFileName|soundFileID,
-- outputChannel }) plays a sound when a native EVENT fires on the tracked aura. Three
-- triggers (Enum.UnitAuraSoundTrigger): Added (applied), Removed (buff dropped / expired)
-- and ApplicationsIncreased (stack gained) — each event gets its OWN sound. No per-play
-- volume (plays at the output channel), and NO ApplicationsDecreased, so stack-LOSS has no
-- trigger. These are the read-free events the API supports; the legacy read-based alerts
-- (fire WHILE a buff is missing; fire near an expiry THRESHOLD — presence / remaining-time
-- driven) stay sealed on 12.1 (the still-blocked Missing / Expire groups). The old build's
-- apply-only AddAuraAppliedSound is dual-detected as a fallback (Added only). Registration
-- is NOT a secure-frame op but combat-legality is unconfirmed, so (re)registration DEFERS
-- out of combat (the container OOC/regen discipline). Handles are tracked per (aura, event)
-- and unregistered on every teardown path — a leaked registration is the failure mode.
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

-- The native sound API was RENAMED on the CustomAuraButton build:
--   AddAuraAppliedSound(sound)  ->  AddAuraSound(trigger, sound)   (same UnitAuraSoundInfo
--   struct; the old name is GONE with no alias, so we dual-detect both — the old code went
--   silently no-op on the renamed build). The new form adds a TRIGGER
--   (Enum.UnitAuraSoundTrigger): Added (on apply = the old behaviour), Removed (buff dropped /
--   expired) and ApplicationsIncreased (stack gained). The legacy build is apply-only. There is
--   NO ApplicationsDecreased — stack LOSS has no native trigger. Source: Gethe fa38386c.
local TRIGGER_ENUM_NAME = { applied = "Added", dropped = "Removed", stackGained = "ApplicationsIncreased" }

local function soundAPIAvailable()
    return (C_UnitAuras and (C_UnitAuras.AddAuraSound or C_UnitAuras.AddAuraAppliedSound)) and true or false
end

-- Register ONE native sound for (event, spell). Returns the handle id, or nil (event
-- unsupported by this build / call failed). event = "applied" | "dropped" | "stackGained".
local function registerAuraSound(event, unit, spellID, argKey, argVal, channel)
    if not C_UnitAuras then return nil end
    local sound = { unitToken = unit, spellID = spellID, outputChannel = channel }
    sound[argKey] = argVal
    if type(C_UnitAuras.AddAuraSound) == "function" then
        local UAST = Enum and Enum.UnitAuraSoundTrigger
        local trig = UAST and UAST[TRIGGER_ENUM_NAME[event]]
        if trig == nil then return nil end   -- this build's enum lacks the trigger
        local ok, id = pcall(C_UnitAuras.AddAuraSound, trig, sound)
        if ok then return id end
        DF:DebugWarn(DBG, "AddAuraSound failed (spell %s, %s): %s", tostring(spellID), tostring(event), tostring(id))
        return nil
    end
    -- Legacy (pre-rename) build: only the on-apply sound exists.
    if event == "applied" and type(C_UnitAuras.AddAuraAppliedSound) == "function" then
        local ok, id = pcall(C_UnitAuras.AddAuraAppliedSound, sound)
        if ok then return id end
        DF:DebugWarn(DBG, "AddAuraAppliedSound failed (spell %s): %s", tostring(spellID), tostring(id))
    end
    return nil
end

local function unregisterAuraSound(id)
    if id == nil or not C_UnitAuras then return end
    local rem = C_UnitAuras.RemoveAuraSound or C_UnitAuras.RemoveAuraAppliedSound
    if type(rem) == "function" then pcall(rem, id) end
end

-- The three per-event sounds of one indicator. The flat sc.soundLSMKey/soundFile is the
-- APPLIED sound (back-compat with the old single-sound config); dropped / stackGained read
-- their own sub-tables. Each is independently enabled. (No stacks-lost — no native trigger.)
local SOUND_EVENTS = {
    { event = "applied",     enabled = function(sc) return sc.appliedEnabled ~= false end,               cfg = function(sc) return sc end },
    { event = "dropped",     enabled = function(sc) return sc.dropped and sc.dropped.enabled end,        cfg = function(sc) return sc.dropped end },
    { event = "stackGained", enabled = function(sc) return sc.stackGained and sc.stackGained.enabled end, cfg = function(sc) return sc.stackGained end },
}

-- Collect the desired PER-EVENT sound registrations of ONE aura pool into `desired`
-- (created on first hit; store keys are keyPrefix .. auraName .. "|" .. event so the two
-- pools AND the three events can never collide). idSpec = the spec for the spec pool, NIL
-- for the Other Buffs pool. NOTE: the native sound path has no caster filter, so othersOnly
-- cannot gate sound — an othersOnly aura's sound fires for any caster. On a pre-rename
-- (apply-only) client the dropped / stackGained triggers simply fail to register (no-op).
local function collectDesiredSounds(desired, unit, auras, keyPrefix, idSpec, channel)
    for auraName, auraCfg in pairs(auras) do
        local sc = (type(auraCfg) == "table") and auraCfg.sound
        -- Filter-owned records never register sounds: the native path is per spell ID,
        -- so one filter would mean one registration per spell in it. The editor doesn't
        -- offer sound on them either; this is the render-side backstop for hand-edited
        -- or imported data.
        if sc and sc.enabled and not DF:ParseADFilterRef(auraName) then
            -- sc carries the sound effect's Tracked IDs mutes (same table the card
            -- writes mutedSpellIDs to); mutedEmpty is a choice, not a data problem.
            local ids, mutedEmpty = DF:BuildADIdentityFilters(idSpec, auraName, sc)
            local map = ids and ids.includeSpellIDs
            if not map and not mutedEmpty then warnOtherUnresolved(auraName, (keyPrefix ~= "") and "Other Buffs" or "Spec") end
            if map then
                for _, ev in ipairs(SOUND_EVENTS) do
                    if ev.enabled(sc) then
                        local argKey, argVal = resolveSoundArg(ev.cfg(sc) or {})
                        if argKey then
                            desired = desired or {}
                            desired[keyPrefix .. auraName .. "|" .. ev.event] = {
                                event = ev.event, map = map, argKey = argKey, argVal = argVal, channel = channel,
                                sig = unit .. "|" .. ev.event .. "|" .. includeSig(map) .. "|"
                                    .. argKey .. "=" .. tostring(argVal) .. "|" .. channel,
                            }
                        end
                    end
                end
            end
        end
    end
    return desired
end

-- OOC-only reconcile of a frame's applied-sound registrations to its CONFIG. Desired = every
-- enabled sound indicator on the active spec (plus the spec-independent Other Buffs pool)
-- whose identity + sound resolve. Diff against the per-aura store (keyed by pool-prefixed
-- aura name); a changed signature (unit / spell set / sound / channel) unregisters the old
-- handles then re-registers. Gate off / spec nil / config removed -> desired empty -> full
-- teardown. Idempotent — safe to call repeatedly (SyncFrame tail, regen flush).
local function reconcileSoundNow(frame)
    if not soundAPIAvailable() then return end   -- pre-12.1: legacy owns it
    local store = frame.dfADFactory
    if not store then return end

    local desired
    local enabled = DF.IsAuraDesignerEnabled and DF:IsAuraDesignerEnabled(frame)
    local db = DF.GetFrameDB and DF:GetFrameDB(frame)
    local owns = DF.FactoryOwnsAD and DF:FactoryOwnsAD(db)
    if enabled and owns and frame.unit then
        local adDB = DF.ResolveAuraDesigner and DF:ResolveAuraDesigner(frame)
        -- ☠ soundEnabled IS THE MASTER MUTE, and it had no reader anywhere in the render
        -- path. The Global tab's "Sound Alerts -> Enabled" checkbox wrote adDB.soundEnabled;
        -- this gate tested adDB.enabled (the AD master) and each indicator's own
        -- sound.enabled, and never this one. The only other thing the checkbox did was call
        -- SoundEngine:StopAll(), which is itself inert -- STATE_PLAYING is declared and
        -- compared but never assigned, so every state stays IDLE and both stop functions are
        -- unconditional no-ops.
        --
        -- So unticking it did nothing at all: every AddAuraSound registration stayed live
        -- and kept firing, this session and every session after, and the only way to silence
        -- alerts was to untick each indicator one at a time.
        --
        -- Tests ~= false, not truthiness: nil means ON (the shipped default is true, and a
        -- profile predating the key must keep its alerts).
        if adDB and adDB.enabled and adDB.soundEnabled ~= false then
            local Engine = DF.AuraDesigner and DF.AuraDesigner.Engine
            local spec = Engine and Engine.ResolveSpec and Engine:ResolveSpec(adDB)
            -- Spec gate matches SyncFrame (spec nil = AD renders nothing, sounds included).
            if spec then
                local channel = resolveSoundChannel(adDB)
                local specAuras = adDB.auras and adDB.auras[spec]
                if specAuras then
                    desired = collectDesiredSounds(desired, frame.unit, specAuras, "", spec, channel)
                end
                if adDB.otherAuras then
                    desired = collectDesiredSounds(desired, frame.unit, adDB.otherAuras, OTHER_PREFIX, nil, channel)
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
            for _, id in ipairs(entry.ids) do unregisterAuraSound(id) end
            soundStore[auraName] = nil
        end
    end
    -- Register newly-desired / changed auras (one handle per spell ID in the identity map).
    if desired then
        for auraName, d in pairs(desired) do
            if not soundStore[auraName] then
                local ids = {}
                for spellID in pairs(d.map) do
                    local id = registerAuraSound(d.event, frame.unit, spellID, d.argKey, d.argVal, d.channel)
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
    if not soundAPIAvailable() then return end
    if InCombatLockdown() then
        Factory._soundPending[frame] = true
        ensureSoundRegen()
        return
    end
    reconcileSoundNow(frame)
end
-- ☠ ONE predicate, three callers (the third is the editor canvas, through
-- Factory:MemberRenderable below). The member-group container renders exactly the
-- indicators this accepts, and syncPlacedPool skips exactly the ones it accepts. If
-- these two ever disagree an icon renders TWICE (both paths claim it) or not at all
-- (neither does), so they must not be two spellings of "the same" rule.
local function memberRenderable(ind)
    return ind ~= nil and ind.enabled ~= false
        and ind.type ~= "bar"          -- a bar is its own sized widget, not a flow icon
        and not ind.showWhenMissing    -- missing mode is a parked badge, never packed
end

-- Published for the editor canvas, which has to split a group's members exactly the way
-- the renderer does — packed members flow inside the group's box, the rest take a grid
-- cell. It kept its own spelling of this predicate (with a comment on each telling the
-- reader they must stay identical, which is not a mechanism), so make it the same
-- function. Three callers now, not "two" as the note above once said.
function Factory:MemberRenderable(ind)
    return memberRenderable(ind)
end

-- The set of member indicators a group container will draw, keyed exactly as
-- syncPlacedPool keys its own entries so the skip is a plain lookup.
local function claimedGroupMembers(groups, auras, keyPrefix)
    if not groups then return nil end
    local claimed
    for _, group in ipairs(groups) do
        if type(group) == "table" and group.kind ~= "filter" and group.enabled ~= false
           and type(group.members) == "table" then
            for _, m in ipairs(group.members) do
                local auraCfg = auras and auras[m.auraName]
                if type(auraCfg) == "table" and auraCfg.indicators then
                    for _, ind in ipairs(auraCfg.indicators) do
                        if ind.id == m.indicatorID and memberRenderable(ind) then
                            claimed = claimed or {}
                            claimed[placedKey(keyPrefix, m.auraName, ind)] = true
                        end
                    end
                end
            end
        end
    end
    return claimed
end


-- ============================================================
-- PLACED-POOL SYNC  (shared by the spec pool and the Other Buffs pool)
-- One pass over ONE aura pool's placed indicators (icon / square / bar, present and
-- missing modes), creating / rebuilding / restyling into the SHARED `placed` store and
-- marking `live` keys — the caller runs the single end-of-pass sweep, so teardown
-- (delete / eye / pool emptied) is identical for both pools. Per-pool knobs:
--   keyPrefix — "" (spec pool) or OTHER_PREFIX (other pool); prefixed into every
--               instanceKey so the pools can never collide in the store.
--   idSpec    — the spec for spec-pool identity, NIL for the other pool (spec-
--               independent: ad-hoc "#id" -> SpellDB by name inside
--               BuildADIdentityFilters; also feeds the missing-badge static icon).
--   hasMG     — member-group arrangement ran this pass (spec pool only; layout groups
--               are spec-scoped, so the other pool always passes false and
--               memberEffective returns the raw record).
-- Module-level (not a SyncFrame closure) to keep the per-aura-event hot path
-- allocation-free. Body otherwise byte-identical to the pre-B1 placed loop.
-- ============================================================
-- Expiry-alert companions ride the same `placed`/`live` stores under
-- "<key>:alert" keys (syncAlertCompanion) — the shared end-of-pass sweep
-- retires them exactly like their indicators.
local function syncPlacedPool(frame, placed, live, hasMG, auras, keyPrefix, idSpec, defs, groups)
    -- Spec pool (My Buffs) = player-cast only; the OTHER_PREFIX pool stays anyone-cast.
    local poolMine = keyPrefix == ""
    -- Members of a layout group are drawn by that group's OWN container, where the
    -- engine can pack them (syncMemberGroupList). Skipping them here is what stops
    -- them being drawn a second time as pinned single-slot containers — which is
    -- also what used to hold their positions fixed.
    local claimed = claimedGroupMembers(groups, auras, keyPrefix)
    for auraName, auraCfg in pairs(auras) do
        -- ☠ `mine` from here down is the RESOLVED pool mode for THIS aura, not the raw
        -- pool flag: a self-only aura on the player's own frame drops the caster filter
        -- (see resolvePoolMode). Resolved ONCE, here, so every container config and
        -- every signature below reads the same value — those two are compared against
        -- each other, and a disagreement rebuilds the container on every update forever.
        local mine = resolvePoolMode(idSpec, auraName, frame, poolMine)
        local indicators = (type(auraCfg) == "table") and auraCfg.indicators
        if indicators then
            for _, indicator in ipairs(indicators) do
                local isSquare = indicator.type == "square"
                local isBar = indicator.type == "bar"
                if claimed and claimed[placedKey(keyPrefix, auraName, indicator)] then
                    -- Drawn by its group's container. Not marked live -> the end-of-pass
                    -- sweep destroys the single-slot handle this indicator used to own,
                    -- so adding a member to a group migrates it rather than duplicating it.
                elseif indicator.enabled == false then
                    -- Hidden (eye toggle; nil/true = shown for legacy records):
                    -- render nothing. Not marking the key `live` lets the
                    -- end-of-pass sweep destroy any existing handle.
                elseif isBar then
                    -- mutedEmpty = the user ticked nothing, which is a CHOICE and must not
                    -- be reported as an unresolved aura. Same nil map, different reason.
                    local ids, mutedEmpty = DF:BuildADIdentityFilters(idSpec, auraName, indicator)
                    local map = ids and ids.includeSpellIDs
                    if not map and not mutedEmpty then warnOtherUnresolved(auraName, (keyPrefix ~= "") and "Other Buffs" or "Spec") end
                    if map then
                        local key = placedKey(keyPrefix, auraName, indicator)
                        live[key] = true
                        -- eff = position through the member-group wrapper when grouped
                        local eff = memberEffective(hasMG, key, indicator)
                        local borderOn = placedBorderOn(indicator, false)
                        local alpha = tonumber(indicator.alpha) or 1
                        local structSig = barStructSig(indicator, borderOn, defs) .. adTooltipSig(frame)
                        local tuningSig = placedTuningSig(map, poolFilter(indicator, mine))
                        local coSig = barCoSig(frame, eff, borderOn, alpha, defs)

                        local entry = placed[key]
                        if not entry then
                            local borderSpec = borderOn and buildBarBorderSpec(frame, indicator) or nil
                            local handle = placedAcquire(frame, key, structSig,
                                buildBarConfig(frame, frame.unit, map, eff, borderSpec, defs, mine))
                            if handle then
                                applyPlacedAlpha(handle, alpha)
                                placed[key] = { handle = handle, structSig = structSig,
                                                tuningSig = tuningSig, coSig = coSig }
                            end
                        elseif entry.structSig ~= structSig then
                            -- ☠ Slot + combat: skip WITHOUT stamping, so the sig delta
                            -- retries after combat (see the icon/square branch for why).
                            if isSlotHandle(entry.handle) and InCombatLockdown() then
                                -- deliberately empty — retried by sig delta after combat
                            else
                                local borderSpec = borderOn and buildBarBorderSpec(frame, indicator) or nil
                                entry.structSig, entry.tuningSig, entry.coSig = structSig, tuningSig, coSig
                                placedRestructure(entry, frame, key, structSig,
                                    buildBarConfig(frame, frame.unit, map, eff, borderSpec, defs, mine))
                                applyPlacedAlpha(entry.handle, alpha)
                            end
                        else
                            if entry.tuningSig ~= tuningSig then
                                -- Selection edit, struct sig stable: swap the include map on
                                -- the live container (row mode) rather than recreating it.
                                -- borderSpec nil on purpose — ApplyTuning reads only the trio.
                                entry.tuningSig = tuningSig
                                local cfg = buildBarConfig(frame, frame.unit, map, eff, nil, defs, mine)
                                placedTune(entry.handle, cfg)
                            end
                            if entry.coSig ~= coSig then
                                local borderSpec = borderOn and buildBarBorderSpec(frame, indicator) or nil
                                entry.coSig = coSig
                                entry.handle:ApplyStyle(
                                    buildBarStyle(indicator, borderSpec, defs),
                                    buildBarLayout(frame, eff))
                                applyPlacedAlpha(entry.handle, alpha)
                            end
                        end

                        -- Expiry-alert companion slot (own container, own sigs —
                        -- see the EXPIRY ALERT COMPANION SLOT section).
                        syncAlertCompanion(frame, placed, live, key, map, eff, true, alpha, mine, defs)
                    end
                elseif isSquare or indicator.type == "icon" then
                    -- mutedEmpty = the user ticked nothing, which is a CHOICE and must not
                    -- be reported as an unresolved aura. Same nil map, different reason.
                    local ids, mutedEmpty = DF:BuildADIdentityFilters(idSpec, auraName, indicator)
                    local map = ids and ids.includeSpellIDs
                    if not map and not mutedEmpty then warnOtherUnresolved(auraName, (keyPrefix ~= "") and "Other Buffs" or "Spec") end
                    if map then
                        local key = placedKey(keyPrefix, auraName, indicator)
                        live[key] = true
                        -- eff = position through the member-group wrapper when grouped
                        local eff = memberEffective(hasMG, key, indicator)
                        local hideIcon = defOf(indicator, "hideIcon", defs, false) and true or false
                        local wantMissingP = indicator.showWhenMissing and true or false
                        local existingP = placed[key]
                        if existingP and (existingP.missing and true or false) ~= wantMissingP then
                            existingP.handle:Destroy(); placed[key] = nil
                        end
                      if wantMissingP then
                        -- SHOW-WHEN-MISSING placed icon/square: static spell icon (or solid
                        -- colour square) + border, shown while the buff is ABSENT. No
                        -- cooldown / duration / stacks (nothing to count when absent) — and
                        -- no expiry-alert companion (nothing to count down;
                        -- syncAlertCompanion is never called on this path). Border
                        -- animation is stripped on the badge (orphan-ticker hazard).
                        local size = math.max(8, tonumber(defOf(indicator, "size", defs, 24)) or 24)
                        local borderOnM = placedBorderOn(indicator, hideIcon)
                        local anchorM = (type(eff.anchor) == "string" and eff.anchor) or "TOPLEFT"
                        local oxM, oyM = tonumber(eff.offsetX) or 0, tonumber(eff.offsetY) or 0
                        local scaleM = tonumber(defOf(indicator, "scale", defs, 1)) or 1
                        local structSig = includeSig(map) .. "|" .. (isSquare and "sq" or "ic")
                            .. "|miss|fl=" .. tostring(resolveLevel(indicator, defs.level))
                            .. "|fs=" .. tostring(resolveStrata(indicator, defs.strata) or "")
                            .. "|f=" .. poolFilter(indicator, mine)
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
                            if f then
                                pcall(function() f:SetScale(scaleM) end)
                                -- pp: grid-snap the window AFTER the scale is set
                                -- (the snap works in effective-scale space); the
                                -- badge + its border then render on whole pixels.
                                local pp = (DF:GetFrameDB(frame) or {}).pixelPerfect
                                DF:SnapPointToPixelGrid(f, pp)
                                if pp and not f:GetLeft() then
                                    -- Login build order: the rect isn't laid out yet, so the
                                    -- snap above no-op'd. Poll until it resolves, snap once
                                    -- (mirrors the engine's pin retry in applyContainerLayout).
                                    local tries = 0
                                    f:SetScript("OnUpdate", function(fr)
                                        tries = tries + 1
                                        -- ☠ Secret check FIRST — see the twin guard in
                                        -- AuraContainer's applyContainerLayout pin retry.
                                        -- `gl and issecretvalue(gl)` truthiness-tests gl
                                        -- before proving it safe to touch.
                                        local gl = fr:GetLeft()
                                        if issecretvalue and issecretvalue(gl) then gl = nil end
                                        if gl or tries > 600 then
                                            fr:SetScript("OnUpdate", nil)
                                            DF:SnapPointToPixelGrid(fr, true)
                                        end
                                    end)
                                end
                            end
                        end
                        local entry = placed[key]
                        -- Identity/struct change on a missing container = Destroy+recreate
                        -- (Rebuild doesn't re-size h.frame/h.badge — only Create does).
                        if entry and entry.structSig ~= structSig then
                            entry.handle:Destroy(); placed[key] = nil; entry = nil
                        end
                        if not entry then
                            local handle = DF.AuraContainer:Create(frame,
                                buildPlacedMissingConfig(frame.unit, map, indicator, mine, defs))
                            if handle then
                                placeM(handle)
                                stylePlacedMissingBadge(handle, frame, idSpec, auraName, indicator, isSquare, defs)
                                placed[key] = { handle = handle, structSig = structSig, coSig = coSig, missing = true }
                            end
                        elseif entry.coSig ~= coSig then
                            entry.coSig = coSig
                            if entry.handle.SetBadgeSize then entry.handle:SetBadgeSize(size, size) end
                            placeM(entry.handle)
                            stylePlacedMissingBadge(entry.handle, frame, idSpec, auraName, indicator, isSquare, defs)
                        end
                      else
                        -- Global-defaultable, and all three feed the STRUCT sig — resolve
                        -- through defOf so a Global Defaults edit actually rebuilds.
                        local showStacks = defOf(indicator, "showStacks", defs, true) and true or false
                        local showDuration = defOf(indicator, "showDuration", defs, true) and true or false
                        local borderOn = placedBorderOn(indicator, hideIcon)
                        local alpha = tonumber(indicator.alpha) or 1

                        -- Sigs are computed from RAW config every tick (no BuildSpec
                        -- alloc — FIX C); the actual border spec is built ONLY inside a
                        -- create/rebuild/restyle branch below, never per pass.
                        local structSig = placedStructSig(isSquare, hideIcon, showStacks,
                            showDuration, borderOn, indicator, defs) .. adTooltipSig(frame)
                        local tuningSig = placedTuningSig(map, poolFilter(indicator, mine))
                        local coSig = placedCoSig(eff, isSquare, borderOn, alpha, defs)

                        local entry = placed[key]
                        if not entry then
                            local borderSpec = borderOn and buildPlacedBorderSpec(frame, indicator, hideIcon, nil, defs) or nil
                            -- Shared slot owner (S2b); falls back to a per-indicator
                            -- container on test frames / in combat before an owner exists.
                            local handle = placedAcquire(frame, key, structSig,
                                buildPlacedConfig(frame, frame.unit, map, eff, isSquare, borderSpec, defs, mine))
                            if handle then
                                applyPlacedAlpha(handle, alpha)
                                placed[key] = { handle = handle, structSig = structSig,
                                                tuningSig = tuningSig, coSig = coSig }
                            end
                        elseif entry.structSig ~= structSig then
                            -- ☠ SLOT + COMBAT: DO NOTHING, INCLUDING THE SIG STAMP. A slot
                            -- restructure is park + AddAuraSlot, and both halves are
                            -- combat-illegal on the secure container (a refused park used
                            -- to latch anyway and render the old visual forever — bug
                            -- #1024). Leaving the sigs UNSTAMPED is the whole retry
                            -- mechanism: the next out-of-combat SyncFrame pass sees the
                            -- same sig delta and restructures naturally. Containers keep
                            -- the un-gated path — Handle:Rebuild self-defers to regen.
                            if isSlotHandle(entry.handle) and InCombatLockdown() then
                                -- deliberately empty — retried by sig delta after combat
                            else
                                local borderSpec = borderOn and buildPlacedBorderSpec(frame, indicator, hideIcon, nil, defs) or nil
                                entry.structSig, entry.tuningSig, entry.coSig = structSig, tuningSig, coSig
                                -- Slot: park the old key and take a new one (a slot's regions
                                -- are frozen at creation). Container: Rebuild as before.
                                placedRestructure(entry, frame, key, structSig,
                                    buildPlacedConfig(frame, frame.unit, map, eff, isSquare, borderSpec, defs, mine))
                                applyPlacedAlpha(entry.handle, alpha)
                            end
                        else
                            if entry.tuningSig ~= tuningSig then
                                -- Selection edit with the struct sig stable: swap the include
                                -- map on the LIVE container instead of recreating it.
                                -- ApplyTuning replaces the trio wholesale (max/sort/
                                -- candidateFilters) off the fresh config. ⚠ Stamping the sig
                                -- BEFORE the call means this branch never retries, so it is
                                -- only correct because BOTH handle kinds store-then-defer in
                                -- lockdown and replay at regen (Handle via _registerRegen,
                                -- SlotHandle via _slotRegen). This comment used to claim the
                                -- slot side self-deferred when it did not — that was bug
                                -- #1024. testEntries rides along so a test-mode rebuild
                                -- previews the NEW selection, not a stale one — same pairing
                                -- as the filter-group path. borderSpec is nil here on purpose:
                                -- ApplyTuning reads only the trio, and the cosmetic branch
                                -- below owns the style (building a spec here would be thrown
                                -- away).
                                entry.tuningSig = tuningSig
                                local cfg = buildPlacedConfig(frame, frame.unit, map, eff, isSquare, nil, defs, mine)
                                placedTune(entry.handle, cfg)
                            end
                            if entry.coSig ~= coSig then
                                local borderSpec = borderOn and buildPlacedBorderSpec(frame, indicator, hideIcon, nil, defs) or nil
                                entry.coSig = coSig
                                entry.handle:ApplyStyle(
                                    buildPlacedStyle(indicator, isSquare, borderSpec, defs),
                                    buildPlacedLayout(eff, defs))
                                -- alpha is part of coSig, so it re-applies here and NOT on the
                                -- steady-state path — this block runs per indicator per tick.
                                applyPlacedAlpha(entry.handle, alpha)
                            end
                        end

                        -- Expiry-alert companion slot (own container, own sigs —
                        -- see the EXPIRY ALERT COMPANION SLOT section).
                        syncAlertCompanion(frame, placed, live, key, map, eff, false, alpha, mine, defs)
                      end
                    end
                end
            end
        end
    end
end

-- ============================================================
-- FILTER-GROUP SYNC  (shared by the spec-keyed groups and otherLayoutGroups)
-- One pass over ONE group array's filter-kind groups, creating / rebuilding /
-- restyling into the SHARED `fg` store and marking `live` keys — the caller
-- runs the single end-of-pass sweep (mirror of syncPlacedPool's contract).
-- keyPrefix — "" (spec-keyed groups) or OTHER_PREFIX (the flat other store);
-- prefixed into the "fgroup:<prefix><id>" key so the two id counters can
-- never collide in the store. Module-level (not a SyncFrame closure) to keep
-- the per-aura-event hot path allocation-free; body otherwise identical to
-- the pre-split A5 loop.
-- ============================================================
-- Collect a layout group's renderable members, in the user's configured ORDER.
-- Returns nil when the group has nothing to draw, so the caller leaves the key
-- un-live and the end-of-pass sweep tears any old container down.
--
-- BARS are excluded on purpose: a bar is not an icon in a flow, it is its own
-- sized widget, and packing it beside icons is meaningless. Grouped bars keep the
-- single-slot path (see the skip in syncPlacedPool).

-- `mine` is the GROUP's pool flag; each member resolves its own from it, because a
-- self-only aura needs the caster filter dropped for its record alone.
local function collectGroupMembers(frame, group, auras, idSpec, defs, mine)
    local recs
    for _, m in ipairs(group.members) do
        local auraCfg = auras and auras[m.auraName]
        local ind
        if type(auraCfg) == "table" and auraCfg.indicators then
            for _, x in ipairs(auraCfg.indicators) do
                if x.id == m.indicatorID then ind = x; break end
            end
        end
        if memberRenderable(ind) then
            -- `ind` so a member of a layout group narrows exactly like a loose placement —
            -- this is the reported case (a Beacon square inside a layout group).
            local ids = DF:BuildADIdentityFilters(idSpec, m.auraName, ind)
            local map = ids and ids.includeSpellIDs
            if map then
                local isSquare = ind.type == "square"
                local borderOn = placedBorderOn(ind, ind.hideIcon)
                recs = recs or {}
                recs[#recs + 1] = {
                    -- Both halves of the member identity: the group key must be
                    -- built from the PAIR, since indicator ids repeat across auras.
                    auraName    = m.auraName,
                    indicatorID = m.indicatorID,
                    indicator   = ind,
                    map         = map,
                    -- ☠ PER MEMBER, not per group. Symbiotic Relationship's copy on
                    -- the druid is credited to the PARTNER, so a group-wide
                    -- "HELPFUL|PLAYER" can never pass it and the member silently
                    -- never renders on the druid's own frame -- the exact bug placed
                    -- indicators were fixed for, reintroduced the moment the spell is
                    -- dragged into a layout group. See resolvePoolMode.
                    mine        = resolvePoolMode(idSpec, m.auraName, frame, mine),
                    isSquare    = isSquare,
                    borderOn    = borderOn,
                    size        = math.max(8, tonumber(defOf(ind, "size", defs, 24)) or 24),
                    borderSpec  = borderOn
                        and buildPlacedBorderSpec(frame, ind, ind.hideIcon, nil, defs) or nil,
                }
            end
        end
    end
    return recs
end

-- ============================================================
-- LAYOUT GROUPS — one container, one group per member
-- ============================================================
-- ⚠ FIRST CUT: EVERYTHING RIDES THE STRUCT SIG, so any change rebuilds the
-- container rather than hot-applying. That is deliberate. The split sigs are an
-- optimisation, and getting one wrong here is not a cosmetic bug — a tuning sig
-- that disagrees with the config rebuilds on EVERY aura event, which in a raid is
-- a frame-rate cliff rather than a visible glitch. Correct first; split once this
-- has been seen working.
local function syncMemberGroupList(frame, mg, live, groups, auras, keyPrefix, idSpec, defs)
    if not groups then return end
    local mine = keyPrefix == ""
    for _, group in ipairs(groups) do
        if type(group) == "table" and group.kind ~= "filter" and group.enabled ~= false
           and type(group.members) == "table" and #group.members > 0 then
            local recs = collectGroupMembers(frame, group, auras, idSpec, defs, mine)
            if recs then
                local key = "mgroup:" .. keyPrefix .. tostring(group.id)
                live[key] = true

                local parts = {
                    groupStyleStructSig(group),
                    adTooltipSig(frame),   -- tooltip toggles are structural; see adTooltipSig
                    "fl=" .. tostring((defs and defs.level) or 40),
                    "f=" .. poolFilter(group, mine),
                    "n=" .. tostring(#recs),
                    -- The group's own arrangement: the flow lays the members INTO this,
                    -- so a growth/wrap/spacing/anchor edit has to reach the container.
                    "gl=" .. tconcat({
                        tostring(group.anchor), groupGrowth(group),
                        tostring(group.iconsPerRow), tostring(group.spacing),
                        tostring(group.iconSize), tostring(group.offsetX), tostring(group.offsetY),
                    }, ","),
                }
                for i, r in ipairs(recs) do
                    -- Order is part of identity: swapping two members changes each one's
                    -- layoutIndex, and the icons must move.
                    -- Full member identity in the sig — the same pair the group key
                    -- uses. With the id alone, rekeying a member (orphan-repair
                    -- rename) could leave the sig unchanged and re-adopt a parked
                    -- container whose groups are keyed by the OLD names.
                    parts[#parts + 1] = "m" .. i .. "=" .. tostring(r.auraName)
                        .. ":" .. tostring(r.indicatorID)
                        .. "|" .. includeSig(r.map)
                        -- The member's RESOLVED pool filter. Without it, a member
                        -- whose self-only resolution changes (the group moved onto
                        -- your own frame) keeps the old filter string until some
                        -- unrelated edit rebuilds the container.
                        .. "|f=" .. poolFilter(group, r.mine)
                        .. "|" .. tostring(r.size)
                        .. "|" .. placedStructSig(r.isSquare, r.indicator.hideIcon,
                                     r.indicator.showStacks, r.indicator.showDuration,
                                     r.borderOn, r.indicator, defs)
                        .. "|" .. placedCoSig(r.indicator, r.isSquare, r.borderOn,
                                     tonumber(r.indicator.alpha) or 1, defs)
                end
                local structSig = tconcat(parts, "|")

                local entry = mg[key]
                if not entry then
                    local handle = DF.AuraContainer:Create(frame,
                        buildMemberGroupConfig(frame, group, recs, mine, defs))
                    if handle then mg[key] = { handle = handle, structSig = structSig } end
                elseif entry.structSig ~= structSig then
                    entry.structSig = structSig
                    entry.handle:Rebuild(buildMemberGroupConfig(frame, group, recs, mine, defs), structSig)
                end
            end
        end
    end
end

local function syncFilterGroupList(frame, fg, live, R, groups, keyPrefix, defs)
    -- Spec-keyed groups (My Buffs) = player-cast only; otherLayoutGroups unchanged.
    local mine = keyPrefix == ""
    if not groups then return end
    for _, group in ipairs(groups) do
        if type(group) == "table" and group.kind == "filter" and group.enabled ~= false then
            -- Version-cached: within one auraLayoutVersion this is a table
            -- lookup; the resolve + full-map sort run once per version.
            local res, selSig = resolveFilterGroup(R, group)
            if res.kind == "include" and res.map and next(res.map) then
                local key = "fgroup:" .. keyPrefix .. tostring(group.id)
                live[key] = true
                -- SPLIT sigs (Wave 1): structural -> Rebuild (recreate), tuning ->
                -- in-place h:ApplyTuning, cosmetic -> ApplyStyle.
                -- ☠ "|fl=" is not decoration. frameLevelOffset is a CREATE-time container
                -- property, so the account-wide Default Frame Level must ride the STRUCT sig
                -- or moving the slider changes the config and rebuilds nothing. Placed
                -- indicators already carry it (placedStructSig's own "|fl="); the group sigs
                -- never did, because the level was a hardcoded 40 until it started tracking
                -- defs.level. Constant at defaults, so this is a no-op unless the user moves it.
                local structSig = groupStyleStructSig(group)  -- region set only (format key is cosmetic now) (group.style)
                    .. "|fl=" .. tostring((defs and defs.level) or 40)
                    .. adTooltipSig(frame)
                local tuningSig = selSig                      -- selection edits: live include-map swap (config-wide candidateFilters)
                    .. "|max=" .. tostring(math.max(1, tonumber(group.maxIcons) or 8))
                    .. groupSortSig(group)                    -- per-group sort (Wave 2): live SetAuraGroupSortMethod
                    -- Filter string joined the tuning half on 2026-08-04 (Others Only).
                    -- A filter group declares ONE group off a plain string filter, so its
                    -- key set is fixed at "df1" and the live swap is safe.
                    .. "|f=" .. poolFilter(group, mine)
                local coSig = filterGroupCoSig(group)

                local entry = fg[key]
                if not entry then
                    local handle = DF.AuraContainer:Create(frame,
                        buildFilterGroupConfig(frame, res.map, group, mine, defs))
                    if handle then
                        fg[key] = { handle = handle, structSig = structSig,
                                    tuningSig = tuningSig, coSig = coSig }
                    end
                elseif entry.structSig ~= structSig then
                    entry.structSig, entry.tuningSig, entry.coSig = structSig, tuningSig, coSig
                    entry.handle:Rebuild(buildFilterGroupConfig(frame, res.map, group, mine, defs), structSig)
                else
                    if entry.tuningSig ~= tuningSig then
                        -- Selection edit / maxIcons / per-group sort with the struct sig
                        -- stable: tune the live container in place (OOC immediate;
                        -- ApplyTuning self-defers in combat). The full trio rides the
                        -- fresh config — max, sort (the Wave-2 per-group mapping; nil at
                        -- the "DEFAULT" family default = Blizzard slot order, matching
                        -- build), candidateFilters =
                        -- the new include map (replace semantics). Swap the map-derived
                        -- testEntries onto the handle config too, so a test-mode rebuild
                        -- previews the NEW selection instead of a stale one.
                        entry.tuningSig = tuningSig
                        local cfg = buildFilterGroupConfig(frame, res.map, group, mine, defs)
                        entry.handle.config.testEntries = cfg.testEntries
                        entry.handle:ApplyTuning(cfg)
                    end
                    if entry.coSig ~= coSig then
                        entry.coSig = coSig
                        entry.handle:ApplyStyle(
                            buildFilterGroupStyle(group, buildGroupBorderSpec(frame, group)),
                            buildFilterGroupLayout(group))
                    end
                end
            elseif res.kind == "exclude" then
                -- Unreachable from the group UI (no Uncategorised option in the
                -- group picker) — guard anyway: an exclude map on a group would
                -- render "everything except", never what a filter group means.
                -- Warn once per group id (this sync runs per aura event).
                if not fgroupExcludeWarned[group] then
                    fgroupExcludeWarned[group] = true
                    DF:DebugWarn(DBG, "Filter group %s resolved to an exclude selection; skipping",
                        tostring(group.id))
                end
            end
            -- res.kind == "all" (empty/no selection): render nothing — the group
            -- stays dormant until a filter is linked (an unfiltered include-all
            -- row is never the intent). Not marked live -> sweep tears down.
        end
    end
end

-- Stand up / restyle one whole-frame border ring on its own DF.AuraContainer, keyed by
-- aura name in the per-type store. Factored out of the border block so BOTH the single
-- Priority-mode winner and every Stacked-mode ring run the identical path -- there is one
-- renderer, and "stacked" is only a statement about how many of them exist.
-- The pandemic ring's spec: a COPY of the resolved base spec with only `color`
-- swapped, so thickness, style, inset and the rest stay in lockstep with the base
-- ring. ☠ Copy, never mutate — `spec` is the base ring's own table and is applied
-- to the base widget on this same pass. Shared by the flat and chained paths.
local function pandemicBorderSpec(spec, cfg)
    if not (spec and wantsPandemicColor(cfg)) then return nil end
    local out = {}
    for k, v in pairs(spec) do out[k] = v end
    local pr, pg, pb, pa = readADColor(cfg.pandemicColor)
    out.color = { r = pr, g = pg, b = pb, a = pa }
    return out
end

local function syncBorderEntry(bd, frame, key, cfg, map, mine)
    local spec = buildBorderSpec(frame, cfg)
    if not spec then return false end          -- resolved disabled -> render nothing

    local filt = poolFilter(cfg, mine)
    local wantMissing = cfg.showWhenMissing and true or false
    local existing = bd[key]
    if existing and (existing.missing and true or false) ~= wantMissing then
        existing.handle:Destroy(); bd[key] = nil
    end

    if wantMissing then
        -- SHOW-WHEN-MISSING: the ring shows while the buff is ABSENT. Window covers the WHOLE
        -- frame (config-sized: fdb.frameWidth/Height, live rect secret); badge = the static
        -- border art with animation STRIPPED (the badge is not a slot in self.buttons, so no
        -- _teardownContainer StopAnimation loop reaches its UIParent driver -> hard-nil, per
        -- the missing-buff badge precedent). NEW USE of the missing mechanism at FRAME size —
        -- the cell push (badge.w + pad) must evacuate the wide window fully on presence
        -- (flag for in-game validation).
        local fdb = (DF.GetFrameDB and DF:GetFrameDB(frame)) or {}
        local mw, mh = tonumber(fdb.frameWidth) or 100, tonumber(fdb.frameHeight) or 20
        local capturedSpec = spec
        local coSig = "miss|" .. borderSpecSig(spec) .. "|" .. tostring(mw) .. "x" .. tostring(mh)
        syncFrameLevelMissing(bd, key, map, frame, frame, frame, mw, mh, 10, coSig,
            function(handle) styleBorderMissingBadge(handle, capturedSpec) end, filt)
        return true
    end

    -- drawAboveFrameBorder rides the STRUCT sig: it resolves to frameLevelOffset in
    -- buildBorderConfig, which only a Rebuild re-reads (ApplyStyle carries the spec only).
    local drawAbove = cfg.drawAboveFrameBorder ~= false
    local pdSpec = pandemicBorderSpec(spec, cfg)
    -- The pandemic ring's PRESENCE joins the struct sig: its holder is created in the
    -- secure init, so enabling it must hand over a fresh button.
    local structSig = "da=" .. tostring(drawAbove) .. (pdSpec and "|pd" or "")
    local tuningSig = placedTuningSig(map, filt)
    local coSig = borderSpecSig(spec) .. (pdSpec and ("|pd=" .. colSig(cfg.pandemicColor)) or "")

    local entry = bd[key]
    if not entry then
        local handle = DF.AuraContainer:Create(frame, buildBorderConfig(frame.unit, map, spec, filt, drawAbove, pdSpec))
        if handle then
            bd[key] = { handle = handle, structSig = structSig,
                        tuningSig = tuningSig, coSig = coSig }
        end
    elseif entry.structSig ~= structSig then
        entry.structSig, entry.tuningSig, entry.coSig = structSig, tuningSig, coSig
        entry.handle:Rebuild(buildBorderConfig(frame.unit, map, spec, filt, drawAbove, pdSpec), structSig)
    else
        if entry.tuningSig ~= tuningSig then
            entry.tuningSig = tuningSig
            entry.handle:ApplyTuning(buildBorderConfig(frame.unit, map, spec, filt, drawAbove, pdSpec))
        end
        if entry.coSig ~= coSig then
            entry.coSig = coSig
            entry.handle:ApplyStyle({ border = { spec = spec, pandemicSpec = pdSpec } })
        end
    end
    return true
end

-- Collect every border indicator opted into Stacked mode, across both pools, resolving
-- identity exactly as pickWinner does. Sorted highest-priority FIRST so the rings are
-- created in a deterministic, priority-driven order rather than pairs() order.
-- ☠ Sort order is the CREATION order, not a frame-level guarantee: every ring lands on the
-- same level for a given Draw Above setting (the +9/+11 border band has no headroom for a
-- ladder — +10 is the missing badge, +11/+12 are the absorb/heal-prediction bands). Rings
-- meant to be seen together must be separated by INSET, which is the point of the mode.
-- Returns a fresh list (nil when there are none, which is the common case: nothing is
-- allocated unless the profile actually uses the mode). Deliberately NOT a reused module
-- scratch table -- SyncFrame runs per frame off config/roster changes, not per tick, so a
-- short-lived list is free here and cannot be clobbered by re-entrancy.
local function collectStackedBorders(spec, specAuras, otherAuras)
    local stackedBorders
    for pool = 1, 2 do
        local auras = (pool == 1) and specAuras or otherAuras
        -- Other-pool identity is spec-INDEPENDENT (see pickWinner).
        local idSpec = (pool == 1) and spec or nil
        if auras then
            for auraName, auraCfg in pairs(auras) do
                local typeCfg = (type(auraCfg) == "table") and auraCfg.border
                if typeCfg and typeCfg.enabled ~= false and typeCfg.ShowBorder ~= false
                   and typeCfg.borderMode == "custom" then
                    local map, mutedEmpty = unionIdentity(idSpec, auraName, typeCfg)
                    -- mutedEmpty = every id unticked in Tracked IDs: a choice, not a data problem.
                    if not map and not mutedEmpty then warnOtherUnresolved(auraName, (pool == 2) and "Other Buffs" or "Spec") end
                    if map then
                        stackedBorders = stackedBorders or {}
                        stackedBorders[#stackedBorders + 1] = {
                            key  = (pool == 2) and (OTHER_PREFIX .. auraName) or auraName,
                            cfg  = typeCfg,
                            map  = map,
                            prio = auraCfg.priority or 5,
                            mine = (pool == 1),
                        }
                    end
                end
            end
        end
    end
    if not stackedBorders then return nil end
    -- Same tiebreak as pickWinner: priority, then pool, then name — so equal-priority rings
    -- keep a stable order instead of shuffling on every roster change.
    table.sort(stackedBorders, function(a, b)
        if a.prio ~= b.prio then return a.prio > b.prio end
        if a.mine ~= b.mine then return a.mine end
        return a.key < b.key
    end)
    return stackedBorders
end

-- ============================================================
-- MULTI-TINT HEALTH BAR / BACKGROUND  (one container per configured tint)
-- These two used to run through pickWinner — ONE static winner per type — which meant a
-- lower-priority buff could never colour the bar even when it was the ONLY buff present
-- (presence is secret; a config-time pick cannot ask what is on the unit). Field report
-- 2026-08-13. Now every configured tint gets its own engine presence-gated container, so
-- whichever buff is actually up colours the frame. When SEVERAL are up at once the
-- arbitration is DRAW ORDER: the family shares one frame level (the healthBar+1 cover
-- band is a single level wide — the attached absorb at +2 is a hard ceiling, bug #1027 —
-- so there is no room for a level ladder), and same-level render order follows frame
-- creation order. The sync loop therefore enforces two rules:
--   * CREATE ASCENDING: collectFrameTints sorts lowest priority FIRST (the exact reverse
--     of pickWinner's winner-first order), so the highest-priority tint is created last
--     and draws on top — an opaque Replace cover fully hides the rest, restoring the v4
--     "highest present priority wins"; translucent Tints compose, top-most last.
--   * REPAIR THE LADDER: a (re)created container takes a fresh global draw index, so a
--     mid-list Create/Rebuild would jump above older higher-priority siblings. The loop
--     recreates every non-chained tint AFTER the first (re)created one, and an
--     order-signature change (a priority edit that crosses another tint, an add/remove)
--     tears the whole family down to recreate in order.
-- ☠ CONDITION-CHAINED tints are exempt from the ladder: their visual container is born
-- when the last gating buff lands (buildConditionChain is lazy by necessity), a runtime
-- the sync loop cannot order. A chained tint's draw position among simultaneous tints is
-- best-effort — accepted; conditions are rare and curate their own visibility.
-- SHOW-WHEN-MISSING stays SINGLE-WINNER (the highest-priority SWM config): "absent" is
-- the resting state of most frames, so several missing badges would sit composed over
-- every idle frame — the one-badge contract is kept deliberately.
-- ============================================================

-- The same candidate set pickWinner scores, as a LIST — both pools, enabled, colour set,
-- identity resolved. Sorted lowest priority first; ties reverse pickWinner's exactly
-- (spec pool and alphabetically-smaller names sort LATER = draw on top), so with a single
-- candidate the rendered result is identical to the old winner's.
local function collectFrameTints(spec, specAuras, otherAuras, typeKey)
    local list
    for pool = 1, 2 do
        local auras = (pool == 1) and specAuras or otherAuras
        -- Other-pool identity is spec-INDEPENDENT (see pickWinner).
        local idSpec = (pool == 1) and spec or nil
        if auras then
            for auraName, auraCfg in pairs(auras) do
                local typeCfg = (type(auraCfg) == "table") and auraCfg[typeKey]
                if typeCfg and typeCfg.enabled ~= false and typeCfg.color then
                    local map, mutedEmpty = unionIdentity(idSpec, auraName, typeCfg)
                    -- mutedEmpty = every id unticked in Tracked IDs: a choice, not a data problem.
                    if not map and not mutedEmpty then warnOtherUnresolved(auraName, (pool == 2) and "Other Buffs" or "Spec") end
                    if map then
                        list = list or {}
                        list[#list + 1] = {
                            key  = (pool == 2) and (OTHER_PREFIX .. auraName) or auraName,
                            cfg  = typeCfg,
                            map  = map,
                            prio = auraCfg.priority or 5,
                            mine = (pool == 1),
                        }
                    end
                end
            end
        end
    end
    if not list then return nil end
    table.sort(list, function(a, b)
        if a.prio ~= b.prio then return a.prio < b.prio end
        if a.mine ~= b.mine then return b.mine end
        return a.key > b.key
    end)
    -- ONE CONTAINER PER CONFIGURED TINT, including one that carries a pandemic colour:
    -- both covers live on the SAME slot button (see the PANDEMIC COVER note in
    -- AuraContainer styleButton_regions), so the second colour costs no container and no
    -- frame level. The first build emitted a separate "#pd" entry here and drew it one
    -- level above its base — correct on the health bar, but it put the feature out of
    -- reach of the background and border bands, which have no spare level.
    for i = 1, #list do list[i].auraKey = list[i].key end
    return list
end

-- Never written; the teardown-all argument for teardownExceptSet on an order change.
local EMPTY_KEEP = {}

-- The shared multi-tint loop: order signature (teardown-all when the priority order of
-- keys changes — creation order IS the z-order), the single missing-winner scan (the
-- highest-priority SWM config without a chain, mirroring each body's own precedence),
-- ascending sync with ladder repair, then the keep-set sweep. `syncOne(key, cfg, map,
-- mine, asMissing) -> kept, created` is the per-family body. Mutates tstore in place.
local function syncTintFamily(tints, tstore, store, orderKey, spec, syncOne)
    local parts = {}
    for i = 1, #tints do parts[i] = tints[i].key end
    local orderSig = tconcat(parts, "\1")
    if store[orderKey] ~= orderSig then
        store[orderKey] = orderSig
        teardownExceptSet(tstore, EMPTY_KEEP)
    end
    -- List is ascending, so the missing winner is the LAST qualifying entry.
    local missingKey
    for i = #tints, 1, -1 do
        local s = tints[i]
        -- A pandemic variant is never the missing badge: an absent buff has no refresh
        -- window, so its own base entry is the only missing candidate for that config.
        if s.cfg.showWhenMissing and not resolveConditions(spec, s.cfg, s.mine) then
            missingKey = s.key
            break
        end
    end
    -- DRAW ORDER KEY. The tints all cover one region at ONE frame level (the band is a
    -- single level wide — the attached absorb sits directly above), and frames at equal
    -- level have NO guaranteed draw order, so creation order cannot arbitrate: field
    -- report 2026-08-14, "the first buff to show stays on top". The draw-layer sublevel
    -- orders them without needing level headroom. The list is ascending, so the LAST
    -- entry (highest priority) takes the top sublevel; when there are more tints than
    -- the 7 available sublevels the TOP of the stack keeps distinct values and the tail
    -- floors together, which is the right way round.
    local n = #tints
    local keep, forceFrom = {}, nil
    for i = 1, #tints do
        local s = tints[i]
        -- ☠ TOPS OUT AT 6, NOT 7, AND THE HEADROOM IS LOAD-BEARING. Each tint's pandemic
        -- twin sits one sublevel above its base (AuraContainer.lua clamps it to
        -- math.min(subLvl + 1, 7)), so a base of 7 handed the twin 7 as well: the highest
        -- tint tied with its OWN second colour at EVERY stack size, and the winner fell
        -- back to creation order -- the undefended tiebreak this ladder exists to remove.
        -- Reserving 7 for the twin leaves 1..6 for the bases, still more distinct steps
        -- than the stack usually has. (Danders's review, PR #236 B4.)
        s.sublevel = math.max(1, 6 - (n - i))
        s.rank = i
        if forceFrom then
            -- Ladder repair: an earlier tint took a fresh draw index this pass, so every
            -- later non-chained tint must be recreated to land back above it.
            local e = tstore[s.key]
            if e and not e.chain then destroyEntry(e); tstore[s.key] = nil end
        end
        local kept, created = syncOne(s.key, s.cfg, s.map, s.mine, s.key == missingKey,
                                      s.sublevel, s.rank, s.auraKey or s.key)
        if kept then keep[s.key] = true end
        if created and not forceFrom then forceFrom = i end
    end
    teardownExceptSet(tstore, keep)
end

-- One health-bar tint consumer (condition chain / missing badge / flat-or-cover) — the
-- old single-winner body, run per configured aura by syncTintFamily. Returns (kept,
-- created): kept = the entry under `key` should survive the keep-set sweep; created = a
-- container was stood up or rebuilt THIS pass (fresh draw index — the ladder-repair
-- signal). Chains always report created=false: they are exempt from the ladder.
local function syncHealthbarTint(hb, frame, healthBar, spec, key, cfg, map, mine, asMissing,
                                 sublevel, rank, auraKey)
    -- ☠ POOL LOOKUPS TAKE auraKey, NOT key. A pandemic variant's store key carries a
    -- "#pd" suffix so it can sit beside its base in the store; resolvePoolMode resolves by
    -- aura NAME, and a suffixed name matches nothing — the caster filter would silently
    -- fall back and an "only mine" effect would start showing other people's buffs.
    local filt = poolFilter(cfg, resolvePoolMode(spec, auraKey or key, frame, mine))
    -- The pandemic colour rides the SAME container: a second cover on the same button,
    -- created only when configured. ☠ Its PRESENCE is creation-frozen (a region can only
    -- be created in the secure init), so it belongs in the STRUCT sig; the colour VALUE
    -- restyles live and belongs in the cosmetic sig.
    local pdColor = wantsPandemicColor(cfg) and cfg.pandemicColor or nil
    local colorCfg = cfg.color
    -- ☠ FRAME LEVEL IS THE ONLY THING THAT ORDERS THESE. Creation order does not (frames
    -- at equal level have no guaranteed order) and neither does the draw-layer sublevel
    -- (it only orders within ONE frame). Both were tried and both failed the same way in
    -- game: whichever buff was CAST FIRST stayed on top, because Blizzard creates each
    -- container's button when its aura lands — a moment no config-time ordering controls.
    --
    -- The headroom is real, contrary to the note that used to sit on
    -- AD_HEALTHBAR_COVER_OFFSET claiming the attached absorb sat at healthBar+2 with no
    -- room above the cover. Measured from the code instead: healthBar is frame+3
    -- (Create.lua) and the attached absorb resolves to frame+8
    -- (DF:ResolveHealAbsorbBarLevel), so covers can occupy healthBar+1..+4 — four levels —
    -- and still stay under the shield (#1027). Rank 1 is the lowest priority and keeps the
    -- original seat, so a single tint renders exactly where it always did.
    -- Beyond four stacked tints the top ones share the ceiling level and fall back to
    -- cast order between themselves; four deep on one region is already unusual.
    local lvlOffset = AD_HEALTHBAR_COVER_OFFSET + math.min((rank or 1) - 1, 3)
    -- ☠ CARRIED IN EVERY ApplyStyle PAYLOAD BELOW, not just at build. ApplyStyle REPLACES
    -- config.style wholesale, so a payload that omits these drops them — and Blizzard
    -- creates buttons in LAZY BATCHES, so the next button to arrive would be styled from
    -- the stripped copy: no sublevel, and (worse) no pandemic bind, silently ungating the
    -- wash. That is why the opts table is threaded through the restyle closures too.
    local tintOpts = { pandemicColor = pdColor, sublevel = sublevel, levelOffset = lvlOffset }
    -- CONDITION CHAIN takes precedence and suppresses missing mode, exactly as in
    -- the border consumer: a conjunction of presence gates does not express "while
    -- all of these are absent".
    local chainHB = resolveConditions(spec, cfg, mine)
    if chainHB then
        local r, g, b, a = readADColor(colorCfg)
        local mode = slower(cfg.mode or "replace")
        local wholeBar = (mode == "tint") and (cfg.tintWholeBar and true or false) or false
        -- Anchor = healthBar (the flat path's own Create parent) and level-neutral
        -- gates, so every chain shape seats the visual exactly where the flat path
        -- does — chained on `frame` this effect rendered at a different z-level
        -- (and, one-link, a different rect) per condition SHAPE. Bug #1027.
        if wholeBar then
            local blend = healthbarBlend(mode, cfg.blend, a)
            syncConditionChain(hb, key, healthBar, frame.unit, chainHB, filt, "flat" .. (pdColor and "|pd" or "") .. "|l" .. tostring(lvlOffset),
                tconcat({ "flat", tostring(r), tostring(g), tostring(b), tostring(blend), tostring(sublevel),
                    pdColor and colSig(pdColor) or "-" }, "|"),
                function(m, f) return buildOverlayTintConfig(frame.unit, m, r, g, b, blend, lvlOffset, f, tintOpts) end,
                function(h) h:ApplyStyle({ overlay = { tintColor = { r, g, b, blend },
                    tintPandemicColor = tintOpts.pandemicColor, sublevel = tintOpts.sublevel } }) end,
                AD_CHAIN_GATE_OFFSET)
        else
            local alpha = (mode == "replace") and 1 or healthbarBlend(mode, cfg.blend, a)
            local fdb = DF.GetFrameDB and DF:GetFrameDB(frame)
            local tex = (fdb and fdb.healthTexture) or "Interface\\TargetingFrame\\UI-StatusBar"
            local clampTo = healthBar.GetStatusBarTexture and healthBar:GetStatusBarTexture() or nil
            syncConditionChain(hb, key, healthBar, frame.unit, chainHB, filt, "cover" .. (pdColor and "|pd" or "") .. "|l" .. tostring(lvlOffset),
                tconcat({ "fill", tostring(r), tostring(g), tostring(b), tostring(alpha), tostring(tex), tostring(clampTo), tostring(sublevel),
                    pdColor and colSig(pdColor) or "-" }, "|"),
                function(m, f) return buildHealthFillConfig(frame.unit, m, r, g, b, alpha, tex, clampTo, f, tintOpts) end,
                function(h) h:ApplyStyle({ overlay = { healthFill = { texture = tex, color = { r, g, b }, alpha = alpha, clampTo = clampTo,
                        pandemicColor = tintOpts.pandemicColor },
                    sublevel = tintOpts.sublevel } }) end,
                AD_CHAIN_GATE_OFFSET)
        end
        return true, false
    end
    dropChainEntry(hb, key)
    local existing = hb[key]
    local wantMissing = cfg.showWhenMissing and true or false
    if existing and (existing.missing and true or false) ~= wantMissing then
        destroyEntry(existing); hb[key] = nil
    end
    if wantMissing then
        -- Missing stays single-winner: a non-winner SWM config renders nothing and its
        -- stale entry (if any) falls to the keep-set sweep.
        if not asMissing then return false, false end
        -- SHOW-WHEN-MISSING: a flat tint over the health-bar region while the buff is ABSENT.
        -- Window/badge sized read-free from the frame's CONFIGURED size (the live rect is
        -- secret on 12.1); single-anchored to the health bar's TOPLEFT so it covers the region
        -- (config-size approximation — precise region + z-order are P4.7 polish). The filled
        -- mirror is a present-only concept, so nil the feed ref while in missing mode.
        local r, g, b, a = readADColor(colorCfg)
        local mode = slower(cfg.mode or "replace")
        local blend = (mode == "replace") and a or healthbarBlend(mode, cfg.blend, a)
        local fdb = (DF.GetFrameDB and DF:GetFrameDB(frame)) or {}
        local mw, mh = tonumber(fdb.frameWidth) or 100, tonumber(fdb.frameHeight) or 20
        local coSig = tconcat({ "miss", tostring(r), tostring(g), tostring(b), tostring(blend), tostring(mw), tostring(mh) }, "|")
        local before = hb[key]
        syncFrameLevelMissing(hb, key, map, frame, healthBar, healthBar, mw, mh, 1, coSig,
            function(handle) styleTintMissingBadge(handle, r, g, b, blend) end, filt)
        -- syncFrameLevelMissing replaces the entry TABLE on create/recreate.
        return true, hb[key] ~= before
    end
    local r, g, b, a = readADColor(colorCfg)
    local mode = slower(cfg.mode or "replace")
    -- Whole-bar flat tint only exists in tint mode (mirror Indicators.lua:1338):
    -- replace mode always uses the fill-matched mirror.
    local wholeBar = (mode == "tint") and (cfg.tintWholeBar and true or false) or false

    -- The tracked map AND the filter string are live-tunable (overlay slots take
    -- SetAuraSlotCandidateFilters / SetAuraSlotFilterString), so both ride the
    -- tuning sig rather than forcing a teardown+recreate. wholeBar STAYS
    -- structural: it picks a different config builder entirely.
    -- The pandemic cover's PRESENCE is structural: a region can only be created in the
    -- secure init, so enabling it must hand over a fresh button, not restyle in place.
    -- lvlOffset joins the sig: frameLevelOffset is read at Create, so a rank change (a
    -- priority edit that reorders the stack) has to hand over a fresh container.
    local structSig = (wholeBar and "flat" or "cover") .. (pdColor and "|pd" or "") .. "|l" .. tostring(lvlOffset)
    local tuningSig = placedTuningSig(map, filt)
    local entry = hb[key]
    local created = false

    if wholeBar then
        -- LEGACY FLAT PATH — whole-bar tint texture, no mirror.
        local blend = healthbarBlend(mode, cfg.blend, a)
        local coSig = tconcat({ "flat", tostring(r), tostring(g), tostring(b), tostring(blend), tostring(sublevel),
                    pdColor and colSig(pdColor) or "-" }, "|")
        if not entry then
            local handle = DF.AuraContainer:Create(healthBar, buildOverlayTintConfig(frame.unit, map, r, g, b, blend, lvlOffset, filt, tintOpts))
            if handle then
                hb[key] = { handle = handle, structSig = structSig,
                            tuningSig = tuningSig, coSig = coSig }
                created = true
            end
        elseif entry.structSig ~= structSig then
            entry.structSig, entry.tuningSig, entry.coSig = structSig, tuningSig, coSig
            entry.handle:Rebuild(buildOverlayTintConfig(frame.unit, map, r, g, b, blend, lvlOffset, filt, tintOpts), structSig)
            created = true
        else
            if entry.tuningSig ~= tuningSig then
                entry.tuningSig = tuningSig
                entry.handle:ApplyTuning(buildOverlayTintConfig(frame.unit, map, r, g, b, blend, lvlOffset, filt, tintOpts))
            end
            if entry.coSig ~= coSig then
                entry.coSig = coSig
                entry.handle:ApplyStyle({ overlay = { tintColor = { r, g, b, blend },
                    tintPandemicColor = tintOpts.pandemicColor, sublevel = tintOpts.sublevel } })
            end
        end
    else
        -- FILLED MIRROR PATH — duplicate StatusBar fed the secret health percent.
        local alpha = (mode == "replace") and 1 or healthbarBlend(mode, cfg.blend, a)
        local fdb = DF.GetFrameDB and DF:GetFrameDB(frame)
        local tex = (fdb and fdb.healthTexture) or DF.STOCK_BAR_TEXTURE
        -- Anchor target: the REAL health bar's fill texture. Its rect is already
        -- driven by the bar's value, so the cover follows health for free --
        -- no feed, no per-tick work, nothing read, nothing written from our
        -- (tainted) update path. Resolved fresh each pass: changing the frame's
        -- health texture from the settings panel replaces this region.
        local clampTo = healthBar.GetStatusBarTexture and healthBar:GetStatusBarTexture() or nil
        local coSig = tconcat({ "fill", tostring(r), tostring(g), tostring(b), tostring(alpha), tostring(tex), tostring(clampTo), tostring(sublevel),
                    pdColor and colSig(pdColor) or "-" }, "|")
        if not entry then
            local handle = DF.AuraContainer:Create(healthBar, buildHealthFillConfig(frame.unit, map, r, g, b, alpha, tex, clampTo, filt, tintOpts))
            if handle then
                hb[key] = { handle = handle, structSig = structSig,
                            tuningSig = tuningSig, coSig = coSig }
                created = true
            end
        elseif entry.structSig ~= structSig then
            entry.structSig, entry.tuningSig, entry.coSig = structSig, tuningSig, coSig
            entry.handle:Rebuild(buildHealthFillConfig(frame.unit, map, r, g, b, alpha, tex, clampTo, filt, tintOpts), structSig)
            created = true
        else
            if entry.tuningSig ~= tuningSig then
                -- A tuning pass keeps the SAME slot and the same cover, so it
                -- only needs the style re-applied, not a rebuild.
                entry.tuningSig = tuningSig
                entry.handle:ApplyTuning(buildHealthFillConfig(frame.unit, map, r, g, b, alpha, tex, clampTo, filt, tintOpts))
            end
            if entry.coSig ~= coSig then
                entry.coSig = coSig
                entry.handle:ApplyStyle({ overlay = { healthFill = { texture = tex, color = { r, g, b }, alpha = alpha, clampTo = clampTo,
                        pandemicColor = tintOpts.pandemicColor },
                    sublevel = tintOpts.sublevel } })
            end
        end
    end
    return true, created
end

-- The background twin — same contract as syncHealthbarTint. `store` is passed for the
-- shared bgAnchor host (frame.background is a TEXTURE and can't parent a container;
-- every background tint parents to the one anchor, so the level assert is idempotent).
local function syncBackgroundTint(bg, store, frame, spec, key, cfg, map, mine, asMissing, sublevel)
    local filt = poolFilter(cfg, resolvePoolMode(spec, key, frame, mine))
    -- Same contract as the health-bar twin, pandemic cover included: both covers ride
    -- ONE button, so the second colour costs no frame level and this band's lack of
    -- headroom no longer rules it out.
    local pdColor = wantsPandemicColor(cfg) and cfg.pandemicColor or nil
    local tintOpts = { pandemicColor = pdColor, sublevel = sublevel }
    -- (No per-rank LEVEL here, unlike the health-bar twin: the background tint's band is
    -- genuinely one level wide — its host parks at frame+0 and the cover lands at frame+2,
    -- directly under the health/missing bars at frame+3. So stacked BACKGROUND tints still
    -- fall back to cast order between themselves. Fixing that needs the bars to move, which
    -- is a frame-wide z-order change and not worth it for the rarer surface.)
    -- CONDITION CHAIN takes precedence and suppresses missing mode, exactly as in
    -- the border consumer: a conjunction of presence gates does not express "while
    -- all of these are absent".
    local chainBG = resolveConditions(spec, cfg, mine)
    if chainBG then
        local r, g, b, a = readADColor(cfg.color)
        local mode = slower(cfg.mode or "tint")
        local blend = healthbarBlend(mode, cfg.blend, a)
        -- Same parked anchor the flat path uses: the tint has to sit at healthBar-3 so
        -- it lands above the background but below every bar.
        local bgHost = store.bgAnchor
        if not bgHost then
            bgHost = CreateFrame("Frame", nil, frame)
            bgHost:SetAllPoints(frame.background)
            store.bgAnchor = bgHost
        end
        local hbLvl = frame.healthBar and frame.healthBar:GetFrameLevel() or 3
        bgHost:SetFrameLevel(math.max(0, hbLvl - 3))
        -- Level-neutral gates: the chain's visual seats at bgHost+2 = healthBar-1,
        -- same as the flat path, whatever the chain length.
        syncConditionChain(bg, key, bgHost, frame.unit, chainBG, filt, "bgtint" .. (pdColor and "|pd" or ""),
            tconcat({ "bg", tostring(r), tostring(g), tostring(b), tostring(blend), tostring(sublevel),
                pdColor and colSig(pdColor) or "-" }, "|"),
            function(m, f) return buildOverlayTintConfig(frame.unit, m, r, g, b, blend, 0, f, tintOpts) end,
            function(h) h:ApplyStyle({ overlay = { tintColor = { r, g, b, blend },
                    tintPandemicColor = tintOpts.pandemicColor, sublevel = tintOpts.sublevel } }) end,
            AD_CHAIN_GATE_OFFSET)
        return true, false
    end
    dropChainEntry(bg, key)
    local existing = bg[key]
    local wantMissing = cfg.showWhenMissing and true or false
    if existing and (existing.missing and true or false) ~= wantMissing then
        destroyEntry(existing); bg[key] = nil
    end
    if wantMissing then
        -- Missing stays single-winner, exactly as in the health-bar twin.
        if not asMissing then return false, false end
        -- SHOW-WHEN-MISSING: flat tint over the background region while the buff is ABSENT.
        -- Sized read-free from config; anchored to frame.background (parents to `frame`, which
        -- must be a Frame). z-order below the bars is a P4.7 polish concern (uses offset 0).
        local r, g, b, a = readADColor(cfg.color)
        local mode = slower(cfg.mode or "tint")
        local blend = healthbarBlend(mode, cfg.blend, a)
        local fdb = (DF.GetFrameDB and DF:GetFrameDB(frame)) or {}
        local mw, mh = tonumber(fdb.frameWidth) or 100, tonumber(fdb.frameHeight) or 20
        local coSig = tconcat({ "miss", tostring(r), tostring(g), tostring(b), tostring(blend), tostring(mw), tostring(mh) }, "|")
        local before = bg[key]
        syncFrameLevelMissing(bg, key, map, frame, frame, frame.background, mw, mh, 0, coSig,
            function(handle) styleTintMissingBadge(handle, r, g, b, blend) end, filt)
        return true, bg[key] ~= before
    end
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

    local r, g, b, a = readADColor(cfg.color)
    local mode = slower(cfg.mode or "tint")   -- background defaults to tint
    local blend = healthbarBlend(mode, cfg.blend, a)

    -- Nothing structural left: this family declares one overlay slot with a
    -- fixed region set, and both the map and the filter string tune live.
    -- Structural for the same reason as the health-bar twin (secure-context bind).
    local structSig = "bgtint" .. (pdColor and "|pd" or "")
    local tuningSig = placedTuningSig(map, filt)
    local coSig = tconcat({ tostring(r), tostring(g), tostring(b), tostring(blend), tostring(sublevel),
        pdColor and colSig(pdColor) or "-" }, "|")

    local entry = bg[key]
    local created = false
    if not entry then
        local handle = DF.AuraContainer:Create(bgAnchor, buildOverlayTintConfig(frame.unit, map, r, g, b, blend, 0, filt, tintOpts))
        if handle then
            bg[key] = { handle = handle, structSig = structSig,
                        tuningSig = tuningSig, coSig = coSig }
            created = true
        end
    elseif entry.structSig ~= structSig then
        entry.structSig, entry.tuningSig, entry.coSig = structSig, tuningSig, coSig
        entry.handle:Rebuild(buildOverlayTintConfig(frame.unit, map, r, g, b, blend, 0, filt, tintOpts), structSig)
        created = true
    else
        if entry.tuningSig ~= tuningSig then
            entry.tuningSig = tuningSig
            entry.handle:ApplyTuning(buildOverlayTintConfig(frame.unit, map, r, g, b, blend, 0, filt, tintOpts))
        end
        if entry.coSig ~= coSig then
            entry.coSig = coSig
            entry.handle:ApplyStyle({ overlay = { tintColor = { r, g, b, blend },
                    tintPandemicColor = tintOpts.pandemicColor, sublevel = tintOpts.sublevel } })
        end
    end
    return true, created
end

-- ============================================================
-- PER-FRAME SYNC  (P4.1 health-bar + P4.2 frame-level family)
-- Reads the CONFIGURED indicators in adDB.auras[spec] (never a live aura list). Types
-- ported here: healthbar, background, border. framealpha / nametext / healthtext
-- RECOVERED via colour-by-cover (see the NAME / HEALTH TEXT block below and the foot
-- notes); framealpha stays a 12.1 casualty (P4.7 overlays its controls).
-- Winner rules per type:
--   * healthbar / background — MULTI-TINT: every configured tint renders on its own
--     presence-gated container; draw order arbitrates simultaneous buffs (see the
--     collectFrameTints block comment). Show-when-missing stays single-winner.
--   * border — single highest-priority winner (one ring per Draw Above seat), EXCEPT
--     an indicator set to Stacked mode, which opts out and gets its own ring.
--   * nametext / healthtext — single highest-priority winner (one cover per element).
-- ============================================================
function Factory:SyncFrame(frame)
    if not frame or not frame.unit then return end
    if not (DF.AuraContainer and DF.AuraContainer.IsSupported()) then return end

    -- MEMORY TEST (enableAuraDesigner): tear the AD containers down ONCE on the
    -- transition, then stay quiet. Merely skipping the sync would leave every
    -- container standing for Blizzard to keep rendering — the flag has to
    -- release them to show up in the memory reading. The latch matters:
    -- ClearFrame ends in SyncSound, which is not free to re-run per update.
    if DF:MemTestDisabled("enableAuraDesigner") then
        if not frame.dfADMemTestCleared then
            frame.dfADMemTestCleared = true
            self:ClearFrame(frame)
        end
        return
    end
    frame.dfADMemTestCleared = nil

    local adDB = DF.ResolveAuraDesigner and DF:ResolveAuraDesigner(frame)
    if not adDB then
        -- ☠ TEAR DOWN, DO NOT JUST LEAVE. This was a bare `return`, sitting three lines
        -- above the `not spec` exit that DOES call ClearFrame -- two "nothing to render"
        -- paths, one of which released its containers and one of which abandoned them.
        -- Skipping the sync does not stop anything rendering: the containers are declared
        -- to the engine and Blizzard keeps drawing them until they are released, so an
        -- unresolvable config left the previous config's indicators on screen, at their
        -- old positions, until a reload.
        -- ☠ LATCHED, exactly like the MemTest branch above and for its stated reason:
        -- "ClearFrame ends in SyncSound, which is not free to re-run per update."
        -- An earlier comment here claimed the repeated case costs nothing because
        -- ClearFrame "returns immediately when there is no store" -- false for exactly
        -- the frames this fix targets: dfADFactory is created once and never nil'd, so
        -- a frame that ever rendered AD re-ran the full clear (teardown walks plus a
        -- SyncSound reconcile) on EVERY sync pass while its config stayed unresolvable.
        -- The flag resets the moment adDB resolves, so a config coming back re-syncs
        -- normally. (PR #237 self-review finding 1.)
        if not frame.dfADNoCfgCleared then
            frame.dfADNoCfgCleared = true
            self:ClearFrame(frame)
        end
        return
    end
    frame.dfADNoCfgCleared = nil

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
    if DF.MigrateAuraDesignerAbsoluteLevelsLazy then DF.MigrateAuraDesignerAbsoluteLevelsLazy(adDB) end
    if DF.MigrateAuraDesignerAbsoluteLevelsV2Lazy then DF.MigrateAuraDesignerAbsoluteLevelsV2Lazy(adDB) end
    -- One-time refresh of the AD global text defaults to the Midnight baseline — must run
    -- on the RENDER-resolved adDB too (not just the editor's GetAuraDesignerDB), or live
    -- frames resolve from the un-migrated defaults while the editor shows the new ones.
    if DF.MigrateAuraDesignerDefaultRefreshLazy then DF.MigrateAuraDesignerDefaultRefreshLazy(adDB) end
    -- Repairs add-by-ID's orphan SpellDB-name keys onto their curated spell. Runs here
    -- as well as in the editor precisely BECAUSE the orphan renders without the editor
    -- ever being opened — a player who never opens settings would otherwise keep the
    -- undeletable indicator forever.
    if DF.MigrateAuraDesignerOrphanAuraKeysLazy then DF.MigrateAuraDesignerOrphanAuraKeysLazy(adDB) end
    -- Clears stranded per-indicator frameStrata (see the migration's header). Runs on the
    -- render-resolved db as well as the editor's, because the stranded indicator renders
    -- buried whether or not the settings panel is ever opened.
    if DF.MigrateAuraDesignerIndicatorStrataLazy then DF.MigrateAuraDesignerIndicatorStrataLazy(adDB) end

    local store = frame.dfADFactory
    if not store then store = {}; frame.dfADFactory = store end

    -- UNIT RETARGET (roster churn): frames are reused across units, but every container's
    -- unit is declared at Create and none of the sigs carry it — so re-point any live handle
    -- whose unit no longer matches the frame (mirror DriveMissingBuffFactory's h:SetUnit pass;
    -- SetUnit self-defers to regen in combat). Cheap per-pass: one config read per handle.
    do
        local u = frame.unit
        for _, storeKey in ipairs({ "healthbar", "background", "border", "placed",
                                    "nametext", "healthtext", "fgroups", "dgroups" }) do
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
    -- OTHER BUFFS pool (B1): spec-INDEPENDENT flat map (auraName -> auraCfg, same record
    -- shape as adDB.auras[spec] entries). Rendered alongside the spec pool: placed
    -- indicators via the same placed store ("other:"-prefixed keys, same live/sweep),
    -- frame-level effects competing in the same winner picks. Identity resolves with a
    -- NIL spec (ad-hoc "#id" -> SpellDB by name; per-spec Config tables never apply).
    local otherAuras = adDB.otherAuras

    -- ☠ THE PROFILE'S GLOBAL DEFAULTS, RESOLVED ONCE FOR THE WHOLE SYNC — and declared HERE,
    -- at function scope, rather than inside any of the do-blocks below.
    --
    -- It used to be declared inside the placed-pool block, then AGAIN inside the filter-group
    -- block when that one was found to be reading a nil global. The third sibling — the debuff
    -- category groups — was never given one, so it kept reading `defs` as a GLOBAL and kept
    -- getting nil, exactly as the first two had. The whole class was a block-scoped local being
    -- reached for from sibling scopes, and fixing it per-site could only ever fix the sites
    -- someone happened to look at. One declaration above all three ends it.
    --
    -- The failure is silent by construction: every consumer reads it as
    -- `(defs and defs.level) or 40`, so a nil `defs` renders at a hardcoded level rather than
    -- throwing. `luac -l -p <file> | grep '_ENV "defs"'` is what proves it — a GETTABUP on
    -- _ENV means the compiler resolved that read as a global, and it must return nothing here.
    --
    -- Resolved once per sync (the pool walk is allocation-free and this path is per-UNIT_AURA
    -- hot), and threaded into every placed/bar/group spec + struct sig, so nil-instance
    -- indicators follow adDB.defaults exactly like the editor's proxy does.
    local defs = resolveDefs(adDB)

    -- ---- HEALTH BAR (child of frame.healthBar, overlay) -----------------------------
    -- MULTI-TINT (see the block comment above collectFrameTints): every configured
    -- Health Bar Color renders on its own presence-gated container; draw order — not a
    -- static pick — arbitrates when several buffs are up at once. Per-tint render paths
    -- are unchanged (see syncHealthbarTint): FILL COVER (replace, or tint without "Tint
    -- Entire Bar") anchored to the real fill region, or the legacy FLAT WHOLE-BAR TINT
    -- (tint + tintWholeBar); flat vs cover is folded into structSig so toggling it
    -- rebuilds the region fresh.
    local healthBar = frame.healthBar
    if healthBar then
        local hb = store.healthbar
        if not hb then hb = {}; store.healthbar = hb end

        local tints = collectFrameTints(spec, specAuras, otherAuras, "healthbar")
        if tints then
            syncTintFamily(tints, hb, store, "healthbarOrder", spec,
                -- ☠ KEEP THIS ARITY IN STEP WITH syncTintFamily's syncOne CALL. Lua fills a
                -- missing parameter with nil and says nothing, so a short closure silently
                -- drops the tail: this one declared seven while nine were passed, eating
                -- auraKey and the pandemic flag. The variant then painted the BASE colour,
                -- ungated — an invisible duplicate of its own base, reported as "the colour
                -- never changes". Neither luac nor the _ENV globals diff can see an arity
                -- mismatch; only the screen shows it.
                function(key, cfg, map, mine, asMissing, sublevel, rank, auraKey)
                    return syncHealthbarTint(hb, frame, healthBar, spec, key, cfg, map, mine,
                                             asMissing, sublevel, rank, auraKey)
                end)
        else
            -- No health-bar tints configured → the mirror bars are gone; drop the refs.
            teardownExcept(hb, nil)
            store.healthbarOrder = nil
        end
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

        local tints = collectFrameTints(spec, specAuras, otherAuras, "background")
        if tints then
            syncTintFamily(tints, bg, store, "backgroundOrder", spec,
                function(key, cfg, map, mine, asMissing, sublevel)
                    return syncBackgroundTint(bg, store, frame, spec, key, cfg, map, mine, asMissing, sublevel)
                end)
            -- ☠ AND RELEASE WHEN THE SYNC SEATED NOTHING. `tints` being non-empty says
            -- only that something was CONFIGURED; syncTintFamily can still keep zero
            -- containers (every tint a non-winner). The release lived in the else-branch
            -- alone, so that case left a shown, empty anchor frame parked over
            -- frame.background for the rest of the session — invisible, but a frame WoW
            -- never frees, per unit, and it is the same emptiness the else-branch cleans.
            if not next(bg) then
                store.backgroundOrder = nil
                releaseBgAnchor(store)
            end
        else
            -- No background tints configured → the containers are gone; drop the anchor too.
            teardownExcept(bg, nil)
            store.backgroundOrder = nil
            releaseBgAnchor(store)
        end
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
        -- so the winner set is identical to a full-spec enabled check. Stacked-mode entries
        -- are excluded here — they opt OUT of the single-ring contest and are stood up below,
        -- so a Stacked ring never suppresses the Priority-mode winner or vice versa.
        local bestName, bestCfg, bestMap, _, bestPool = pickWinner(spec, specAuras, otherAuras, "border",
            function(c) return c.ShowBorder ~= false and c.borderMode ~= "custom" end)

        -- STACKED: each opted-in indicator gets its own ring, highest priority created first.
        local stacked = collectStackedBorders(spec, specAuras, otherAuras)

        -- CONDITION CHAIN for the PRIORITY winner. Returns true when it rendered
        -- something, matching syncBorderEntry's contract so both paths compose.
        --
        -- Chains suppress missing mode: "show while all of these are absent" is not what a
        -- conjunction of presence gates expresses, and rendering the present-mode chain for
        -- a missing-flagged effect would invert the user's intent. The editor greys Show
        -- When Missing once an effect has more than one condition group.
        --
        -- ☠ STACKED RINGS DO NOT HONOUR CONDITIONS. collectStackedBorders resolves identity
        -- through unionIdentity, which returns the OR-union of every condition group —
        -- correct for the winner pick and the tuning signature, wrong as a render gate, so
        -- an ALL-mode condition on a Stacked ring would show when any ONE of its spells is
        -- up. Chaining the stacked loop is mechanical (the store is already keyed) but it is
        -- a product decision, so the priority winner is chained and Stacked is left on the
        -- single-container path until that call is made.
        local function syncPriorityBorder()
            if not bestName then return false end
            local bestSpec = buildBorderSpec(frame, bestCfg)
            if not bestSpec then return false end   -- resolved disabled → render nothing
            local chainLinks = resolveConditions(spec, bestCfg, bestPool == 1)
            if not chainLinks then
                dropChainEntry(bd, bestName)
                return syncBorderEntry(bd, frame, bestName, bestCfg, bestMap,
                    resolvePoolMode(spec, bestName, frame, bestPool == 1))
            end
            local filt = poolFilter(bestCfg, resolvePoolMode(spec, bestName, frame, bestPool == 1))
            local drawAboveBD = bestCfg.drawAboveFrameBorder ~= false
            -- Level-neutral gates: the ring keeps its drawAboveFrameBorder 11/9 seat
            -- relative to `frame` (the flat path's parent) at any chain length.
            local pdChain = pandemicBorderSpec(bestSpec, bestCfg)
            return syncConditionChain(bd, bestName, frame, frame.unit, chainLinks, filt,
                "da=" .. tostring(drawAboveBD) .. (pdChain and "|pd" or ""),
                borderSpecSig(bestSpec) .. (pdChain and ("|pd=" .. colSig(bestCfg.pandemicColor)) or ""),
                function(map, f) return buildBorderConfig(frame.unit, map, bestSpec, f, drawAboveBD, pdChain) end,
                function(h) h:ApplyStyle({ border = { spec = bestSpec, pandemicSpec = pdChain } }) end,
                AD_CHAIN_GATE_OFFSET) and true or false
        end

        if not stacked then
            -- Nothing stacked (the overwhelmingly common case) — the single-winner path,
            -- with no set to build and nothing extra to tear down.
            if not syncPriorityBorder() then
                bestName = nil          -- resolved disabled → tear the old ring down too
            end
            teardownExcept(bd, bestName)
        else
            local keep = {}
            if syncPriorityBorder() then
                keep[bestName] = true
            end
            for i = 1, #stacked do
                local s = stacked[i]
                -- s.mine stays a plain boolean in the entry table (collectStackedBorders
                -- SORTS on it); the self-only relaxation is resolved here instead. s.key is
                -- the bare aura name whenever s.mine is true — the OTHER_PREFIX form only
                -- appears on pool 2, which resolvePoolMode returns untouched.
                if syncBorderEntry(bd, frame, s.key, s.cfg, s.map,
                    resolvePoolMode(spec, s.key, frame, s.mine)) then
                    keep[s.key] = true
                end
            end
            teardownExceptSet(bd, keep)
        end
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

            local bestName, bestCfg, bestMap, _, bestPool = pickWinner(spec, specAuras, otherAuras, typeKey,
                function(c) return c.color and not c.showWhenMissing end)
            if bestName and TDRender then
                local filt = poolFilter(bestCfg, resolvePoolMode(spec, bestName, frame, bestPool == 1))
                local r, g, b, a = readADColor(bestCfg.color)
                local color = { r = r, g = g, b = b, a = a }
                -- CONDITION CHAIN: the LAST link hands its host to the Text Designer, so the
                -- colour covers only exist when every condition holds. The chain's own gates
                -- use the same mirror-host config, which is why this type nests for free --
                -- the visual link is just one more host, handed to a different consumer.
                local chainTX = resolveConditions(spec, bestCfg, bestPool == 1)
                if chainTX then
                    local cat = category
                    syncConditionChain(st, bestName, frame, frame.unit, chainTX, filt,
                        "mirrorhost", colSig(bestCfg.color),
                        function(map, f)
                            return buildMirrorHostConfig(frame.unit, map, function(host)
                                local e = st[bestName]
                                if e then e.host = host end
                                st._lastHost = host
                                TDRender:EnableMirrors(frame, cat, host, color)
                            end, f)
                        end,
                        -- A colour edit re-registers on the stashed host; EnableMirrors is
                        -- idempotent per parent and restamps the colour.
                        function()
                            local e = st[bestName]
                            if e and e.host then TDRender:EnableMirrors(frame, cat, e.host, color) end
                        end,
                        AD_TEXT_CHAIN_GATE_OFFSET)
                else
                -- Nothing structural: one overlay slot whose only region is the mirror
                -- host. Map and filter string both tune live.
                local structSig = "mirrorhost"
                local tuningSig = placedTuningSig(bestMap, filt)
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
                dropChainEntry(st, bestName)
                local entry = st[bestName]
                if not entry then
                    local handle = DF.AuraContainer:Create(frame,
                        buildMirrorHostConfig(frame.unit, bestMap, onHost, filt))
                    if handle then
                        st[bestName] = { handle = handle, structSig = structSig,
                                         tuningSig = tuningSig, coSig = coSig,
                                         host = st._lastHost }
                    end
                elseif entry.structSig ~= structSig then
                    -- ☠ DELIBERATELY NOT PARKED (no structSig passed to Rebuild), for two
                    -- independent reasons. First, structSig here is the CONSTANT
                    -- "mirrorhost", so it identifies nothing -- every container this
                    -- consumer ever built would share one park key. Second, and the
                    -- general rule: this is the ONLY container config that carries a
                    -- CLOSURE (onHost). A container's initializeFrame callbacks are bound
                    -- at AddAuraGroup time, so a re-adopted container would keep invoking
                    -- the STALE closure -- with the colour and category captured when it
                    -- was first built -- for every lazily-created button. Any future
                    -- config that embeds a callback is unparkable on the same grounds
                    -- unless the callback's captured state is folded into the key.
                    -- (This branch is unreachable today: a constant sig never differs.)
                    entry.structSig, entry.tuningSig, entry.coSig = structSig, tuningSig, coSig
                    entry.handle:Rebuild(buildMirrorHostConfig(frame.unit, bestMap, onHost, filt))
                elseif entry.tuningSig ~= tuningSig then
                    -- Selection edit only: swap the include map on the live slot. Kept as a
                    -- branch of this elseif chain (rather than folded into the else) so the
                    -- one-action-per-pass shape the coSig and host-recovery branches below
                    -- already rely on is preserved — the sync runs every tick, so a second
                    -- pending change lands on the next one.
                    -- entry.host is deliberately untouched: the slot survives a tuning pass,
                    -- so onHost does not re-fire and the stashed host stays valid.
                    entry.tuningSig = tuningSig
                    entry.handle:ApplyTuning(buildMirrorHostConfig(frame.unit, bestMap, onHost, filt))
                elseif entry.coSig ~= coSig then
                    entry.coSig = coSig
                    entry.handle:ApplyStyle({ overlay = { mirrorHost = { onHost = onHost } } })
                elseif entry.host and not (frame._tdMirrors and frame._tdMirrors[category]) then
                    -- TD Teardown (mode/profile switch) dropped the mirror registry while
                    -- our container persisted — re-register on the stashed host. Cheap
                    -- nil-check per pass, only fires after a TD teardown.
                    TDRender:EnableMirrors(frame, category, entry.host, color)
                end
                end  -- if chainTX
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

        -- Member layout groups arrange their members' positions (grid computed from
        -- the group's anchor/offset/grow/wrap/spacing — see the arranger section).
        -- Compute this pass's positions once for BOTH pools (spec-keyed groups over
        -- the spec pool, flat otherLayoutGroups over the other pool); each member
        -- indicator below reads its position through the wrapper (position override
        -- only, all else raw record).
        local hasMG, hasOtherMG = arrangeMemberGroups(adDB, spec, specAuras, otherAuras)

        -- (`defs` is the function-scoped one above — see the note there for why it must not
        -- be re-declared inside a block.)
        if specAuras then
            syncPlacedPool(frame, placed, live, hasMG, specAuras, "", spec, defs,
                adDB.layoutGroups and adDB.layoutGroups[spec])
        end
        -- OTHER BUFFS pool: same store, same live/sweep — keys carry OTHER_PREFIX so
        -- the pools can't collide (the arranger's scratch keys carry it too) and NIL
        -- idSpec (spec-independent identity).
        if otherAuras then
            syncPlacedPool(frame, placed, live, hasOtherMG, otherAuras, OTHER_PREFIX, nil, defs,
                adDB.otherLayoutGroups)
        end

        -- Tear down any placed container whose indicator is gone / de-configured —
        -- including expiry-alert companions ("<key>:alert") whose alert switched
        -- OFF or whose indicator died (their key was never marked live this pass).
        for key, entry in pairs(placed) do
            if not live[key] then
                if entry.handle then entry.handle:Destroy() end
                placed[key] = nil
            end
        end
    end

    -- ---- FILTER GROUPS (container-backed, registry-linked rows) — A5 -----------------
    -- One handle per filter group, keyed "fgroup:<keyPrefix><id>" — "" for the
    -- spec-keyed groups, OTHER_PREFIX for the flat spec-independent
    -- adDB.otherLayoutGroups store (the two id counters overlap, the prefix keeps
    -- the keys disjoint). Structural sig = the group filter string + the group.style
    -- region set (groupStyleStructSig) -> Rebuild. Tuning sig = the registry
    -- selection signature (live link: filter edits / preset updates move it) + max
    -- slot count + the per-group sort fields (Wave 2) -> in-place ApplyTuning
    -- (Wave 1). The layout fields and
    -- cosmetic style fields hot-apply via ApplyStyle. Eye-hidden groups (`enabled == false`;
    -- nil/true = shown) are not marked live -> the sweep destroys their handle.
    -- Same for deleted groups and spec switches (different id set; other-pool
    -- groups are spec-independent, so they persist across spec switches like
    -- the other pool's placed indicators do).
    do
        local fg = store.fgroups
        if not fg then fg = {}; store.fgroups = fg end
        local live = {}
        -- ☠ `defs` is the FUNCTION-SCOPED one now. This block used to declare its own,
        -- because the original lived in the placed-pool do-block and was invisible here —
        -- every call below handed out a nil, and had for as long as one had been taken.
        -- It degraded silently rather than erroring: the reads are `(defs and defs.level)
        -- or 40`, so groups were pinned to level 40 whatever the account-wide Default
        -- Frame Level slider said — the "AD output split across two planes, groups
        -- stranded underneath their own indicators" buildFilterGroupConfig describes.
        -- A second block-scoped declaration fixed this block and left the debuff-group
        -- block below with the identical bug, which is why there is now exactly one.
        local R = DF.FilterRegistry
        if R then
            syncFilterGroupList(frame, fg, live, R, adDB.layoutGroups and adDB.layoutGroups[spec], "", defs)
            syncFilterGroupList(frame, fg, live, R, adDB.otherLayoutGroups, OTHER_PREFIX, defs)
        end
        -- MEMBER groups share this store and this sweep: both are one-container-per-group
        -- keyed off group.id, they differ only in what fills them ("mgroup:" vs
        -- "fgroup:", so the key sets cannot collide), and a group that stops being
        -- renderable has to be torn down the same way either way.
        syncMemberGroupList(frame, fg, live, adDB.layoutGroups and adDB.layoutGroups[spec],
            specAuras, "", spec, defs)
        syncMemberGroupList(frame, fg, live, adDB.otherLayoutGroups,
            otherAuras, OTHER_PREFIX, nil, defs)

        -- Tear down groups gone / hidden / emptied / off-spec.
        for key, entry in pairs(fg) do
            if not live[key] then
                if entry.handle then entry.handle:Destroy() end
                fg[key] = nil
            end
        end
    end

    -- ---- DEBUFF CATEGORY GROUPS (container-backed category rows) — C1 -----------------
    -- One handle per enabled group, keyed "dgroup:<id>". Structural sig = the group's
    -- resolved record strings + keys (the row's own struct serializer — a selection
    -- edit that changes the record SET moves it) + the group.style region set
    -- (groupStyleStructSig) -> Rebuild. Tuning sig = the records' candidateFilters
    -- (hideLong / keepImportant / dispel maps) + max slot count + the per-group
    -- sort fields (Wave 2) -> in-place
    -- ApplyTuning with the config.filter pre-swap (Wave 1). The layout fields and
    -- cosmetic style fields hot-apply via ApplyStyle. Eye-hidden groups (`enabled == false`), empty selections
    -- (no records) and deleted groups are not marked live -> the sweep destroys their
    -- handle. adDB.debuffGroups is preset-level and spec-INDEPENDENT (mirror otherAuras),
    -- but rides the same spec gate as the rest of SyncFrame (no spec -> ClearFrame).
    do
        local dg = store.dgroups
        if not dg then dg = {}; store.dgroups = dg end
        local live = {}

        local groups = adDB.debuffGroups
        if groups then
            for _, group in ipairs(groups) do
                if type(group) == "table" and group.enabled ~= false then
                    -- Version-cached: within one auraLayoutVersion this is a table
                    -- lookup; the resolve + record serialization run once per version.
                    local records, recStructSig, recTuningSig = resolveDebuffGroup(group)
                    if records then
                        local key = "dgroup:" .. tostring(group.id)
                        live[key] = true
                        -- SPLIT sigs (Wave 1): structural -> Rebuild (recreate), tuning ->
                        -- in-place h:ApplyTuning, cosmetic -> ApplyStyle.
                        local structSig = recStructSig      -- record strings + keys (the SET defines the groups)
                            .. groupStyleStructSig(group)   -- region set only; format key is cosmetic (group.style)
                            .. "|fl=" .. tostring((defs and defs.level) or 40)   -- see syncFilterGroupList
                            .. adTooltipSig(frame)
                        local tuningSig = recTuningSig      -- per-record candidateFilters (hideLong / keepImportant / dispel maps)
                            .. "|max=" .. tostring(math.max(1, tonumber(group.maxIcons) or 4))
                            .. groupSortSig(group)          -- per-group sort (Wave 2): live SetAuraGroupSortMethod
                        local coSig = filterGroupCoSig(group, 4)

                        local entry = dg[key]
                        if not entry then
                            local handle = DF.AuraContainer:Create(frame,
                                buildDebuffGroupConfig(frame, records, group, defs))
                            if handle then
                                dg[key] = { handle = handle, structSig = structSig,
                                            tuningSig = tuningSig, coSig = coSig }
                            end
                        elseif entry.structSig ~= structSig then
                            entry.structSig, entry.tuningSig, entry.coSig = structSig, tuningSig, coSig
                            entry.handle:Rebuild(buildDebuffGroupConfig(frame, records, group, defs), structSig)
                        else
                            if entry.tuningSig ~= tuningSig then
                                -- Tunables live in the RECORDS' filter strings and
                                -- candidateFilters, both re-derived engine-side from
                                -- config.filter. ApplyTuning now copies that through
                                -- itself, so the explicit pre-swap below is redundant --
                                -- kept because it costs nothing and makes the dependency
                                -- visible at the call site. Legal because the struct sig
                                -- pins every record's KEY (the add-only topology
                                -- constraint); the STRINGS are free to move.
                                -- The full trio rides the fresh config: max,
                                -- the Wave-2 per-group sort (family default "TIME" =
                                -- ExpirationOnly, the old hardcode), candidateFilters =
                                -- nil (dgroups carry no config-wide map).
                                entry.tuningSig = tuningSig
                                local cfg = buildDebuffGroupConfig(frame, records, group, defs)
                                entry.handle.config.filter = cfg.filter
                                entry.handle:ApplyTuning(cfg)
                            end
                            if entry.coSig ~= coSig then
                                entry.coSig = coSig
                                entry.handle:ApplyStyle(
                                    buildFilterGroupStyle(group, buildGroupBorderSpec(frame, group)),
                                    buildFilterGroupLayout(group, 4))
                            end
                        end
                    end
                end
            end
        end

        -- Tear down groups gone / hidden / emptied.
        for key, entry in pairs(dg) do
            if not live[key] then
                if entry.handle then entry.handle:Destroy() end
                dg[key] = nil
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
-- /df debug adgate — AURA DESIGNER gate ground truth
-- ============================================================
-- Companion to /df debug idgate, and it exists because that dump could not answer the
-- question it kept being reached for. idgate walks AuraContainer._handles and
-- _slotHandles, so it sees a placement's HANDLE but never the chain around it, never the
-- DF-owned badge textures, and never that a link opted out of managing its own visibility.
-- An AD indicator rendering while every handle in idgate reports hidden is invisible to
-- it -- which is exactly the state that stalled this (Krathe, 2026-08-18).
--
-- Answers, per placement: chain length, which links are parent-driven (those NEVER hide
-- themselves, see Handle:_applyVisibility), each link's gate verdict, and what each link's
-- frame plus the badge is ACTUALLY showing. A row whose gate says hidden while the frame
-- says shown is the fault, and the column it lands in names the layer to fix.
--
-- ☠ EVERY IsShown IS GUARDED. A container nested in another container's slot inherits a
-- SECRET shown state, and tostring() on a secret makes the whole print VANISH rather than
-- error -- an unguarded read would silently drop the very rows worth seeing.
-- ☠ Keys are pipe-escaped, same as the idgate dump: AD keys use "|" as a field separator
-- and raw pipes blank an EditBox on paste.
local function adGateSafe(v)
    local s = tostring(v)
    return (s:gsub("|", "||"):gsub("[%z\1-\31]", "?"))
end

local function adGateShown(f)
    if not f then return "-" end
    local ok, s = pcall(f.IsShown, f)
    if not ok then return "ERR" end
    if issecretvalue and issecretvalue(s) then return "SECRET" end
    return tostring(s)
end

-- Families in the per-frame store. ⚠ Keep in sync with ClearFrame below: a family added
-- there and not here has its placements silently absent from this dump.
local AD_GATE_FAMILIES = {
    "placed", "fgroups", "dgroups", "border",
    "healthbar", "background", "nametext", "healthtext",
}

function Factory:DebugDumpADGate()
    local o = DF:Out("AD Gate")
    local CAP = 80
    local n, suspects = 0, 0

    local function dumpFrame(frame)
        local store = frame and frame.dfADFactory
        if type(store) ~= "table" then return end
        local unit = frame.unit
        for _, fam in ipairs(AD_GATE_FAMILIES) do
            local tbl = store[fam]
            if type(tbl) == "table" then
                for key, entry in pairs(tbl) do
                    if type(entry) == "table" then
                        n = n + 1
                        if n <= CAP then
                            local h = entry.handle
                            local chain = entry.chain
                            -- ☠ TWO HANDLE KINDS, DIFFERENT FIELDS. A slot-backed placement
                            -- is a SlotHandle: no .frame, no GetBadgeFrame, and its verdict
                            -- lives in _gateHidden -- NOT _idGateHidden, which is the
                            -- Handle's. Reading the Handle fields on a slot printed
                            -- gate=false shown=- badge=- for a slot that /df debug idgate
                            -- simultaneously reported gateHidden=true. A dump that
                            -- contradicts the other dump is worse than no dump.
                            local isSlot = isSlotHandle and isSlotHandle(h) or false
                            local hGate, hShown, bShown, extra
                            local oShown = "-"
                            if isSlot then
                                hGate = (h and h._gateHidden) and true or false
                                -- "shown" for a slot = is a LIVE filter pushed (vs the park
                                -- string). ⚠ Compare against SLOT_PARK_FILTER, not "" --
                                -- the empty-string park is retired, and deriving from ""
                                -- made every correctly-parked slot read shown=true and trip
                                -- the suspect counter while owner=false proved it dark.
                                local pf = h and h._pushedFilter
                                local park = DF.AuraContainer and DF.AuraContainer.SLOT_PARK_FILTER
                                hShown = (pf == nil) and "-"
                                    or ((pf == "" or pf == park) and "false" or "true")
                                -- ★ THE BUTTON IS THE VISIBLE OBJECT. isSlotHandle is
                                -- literally "has GetButton", so every slot can hand us the
                                -- frame the player is looking at. An empty pushed filter
                                -- means the engine binds no aura -- it does NOT by itself
                                -- mean the button is down, and DF paints its own square
                                -- fill / border / icon onto that button. A slot reading
                                -- pushed=[] with btn=true is an indicator whose artwork
                                -- outlived the aura that justified it.
                                local btn = (h and h.GetButton) and h:GetButton() or nil
                                bShown = btn and adGateShown(btn) or "-"
                                -- ★ owner= is the ACTUATION for a gated slot. The engine
                                -- fails open for a distrusted unit and never re-parses, so
                                -- the filter push cannot clear a stale bound aura; the gate
                                -- hides the DF-owned owner ANCHOR instead (see
                                -- SlotHandle:_pushFilter). gate=true with owner=true is the
                                -- fault; owner=false is the gate working.
                                local oAnchor = h and h.owner and h.owner.anchor
                                oShown = oAnchor and adGateShown(oAnchor) or "-"
                                extra = ("SLOT pushed=[%s] pushOK=%s parked=%s btn=%s owner=%s"):format(
                                    adGateSafe(h and h._pushedFilter),
                                    tostring(h and h._pushOK),
                                    tostring((h and h.parked) or false),
                                    bShown, oShown)
                            else
                                hGate = (h and h._idGateHidden) and true or false
                                hShown = adGateShown(h and h.frame)
                                local badge = (h and h.GetBadgeFrame) and h:GetBadgeFrame() or nil
                                bShown = badge and adGateShown(badge) or "-"
                                extra = ("pdv=%s"):format(
                                    tostring((h and h.config and h.config.parentDrivenVisibility) or false))
                            end
                            -- The fault signature: gate believes hidden, something is up.
                            -- For a slot the decisive column is owner= -- btn is SECRET on
                            -- a distrusted unit, but the owner anchor is DF-owned and
                            -- always readable, so gate=true owner=true is a real fault.
                            if hGate and (hShown == "true" or bShown == "true"
                                or oShown == "true") then
                                suspects = suspects + 1
                            end
                            print(("    " .. DF.OUT.SECTION .. "%d|r %s key=%s unit=%s chain=%s gate=%s shown=%s badge=%s %s"):format(
                                n, adGateSafe(fam), adGateSafe(key), adGateSafe(unit),
                                chain and tostring(#chain) or "-",
                                tostring(hGate), hShown, bShown, extra))
                            if type(chain) == "table" then
                                for i = 1, #chain do
                                    local L = chain[i]
                                    if L then
                                        print(("        L%d gate=%s parked=%s shown=%s pdv=%s mode=%s"):format(
                                            i,
                                            tostring((L._idGateHidden) and true or false),
                                            tostring((L._idGateParked) and true or false),
                                            adGateShown(L.frame),
                                            tostring((L.config and L.config.parentDrivenVisibility) or false),
                                            adGateSafe(L.config and L.config.mode or "?")))
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if DF.IterateAllFrames then pcall(function() DF:IterateAllFrames(dumpFrame) end) end
    -- ☠ Pinned frames are NOT in IterateAllFrames -- it has no pinned arm. A pinned display
    -- of the same unit carries its own placements and must be walked separately.
    -- ⚠ DOT, NOT COLON. IteratePinnedFrames is a plain function (see Engine.lua's call);
    -- DF:IteratePinnedFrames would pass DF as the callback and silently walk nothing.
    if DF.IteratePinnedFrames then pcall(function() DF.IteratePinnedFrames(dumpFrame) end) end

    o:Section("Summary")
    o:Line(("placements: %d"):format(n), n > 0 and "GOOD" or "NEUTRAL")
    o:Line(("gated but still shown: %d"):format(suspects), suspects > 0 and "BAD" or "GOOD")
    if n > CAP then o:Line(("… capped at %d rows"):format(CAP), "NEUTRAL") end
    if suspects == 0 then
        o:Line("Nothing is rendering against its gate verdict. If an icon is still visible it is drawn outside the handle/chain/badge set this dump covers.", "NEUTRAL")
    end
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
    -- Multi-tint order signatures: stale sigs are harmless (a fully-empty store always
    -- recreates in list order) but keep the teardown honest.
    store.healthbarOrder, store.backgroundOrder = nil, nil
    teardownExcept(store.border or {}, nil)
    teardownExcept(store.placed or {}, nil)   -- per-indicator icon/square/bar containers
    -- (Expiry-alert COMPANION handles live in store.placed too — covered above.)
    teardownExcept(store.fgroups or {}, nil)  -- filter-group containers (A5)
    teardownExcept(store.dgroups or {}, nil)  -- debuff-group containers (C1)
    teardownExcept(store.nametext or {}, nil)
    teardownExcept(store.healthtext or {}, nil)
    -- Release the Text Designer mirror covers owned by the two text containers above.
    if DF.TextDesigner and DF.TextDesigner.Render then
        DF.TextDesigner.Render:DisableMirrors(frame, "name")
        DF.TextDesigner.Render:DisableMirrors(frame, "health")
    end
    releaseBgAnchor(store)   -- containers gone above; drop the background anchor too
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
--  * framealpha (ref the legacy Indicators:ApplyFrameAlpha; that module is gone) — reduces the WHOLE unit frame's alpha on
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
-- DIAGNOSTICS — /df debug admissing
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
        if not h then print("    " .. tag .. " [" .. key .. "] " .. DF.OUT.BAD .. "handle=nil|r") return end
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
        local o = DF:Out("Aura Designer", "missing markers placed")
        o:Field("markers", n, n > 0 and "GOOD" or "WARN")
        o:Line("magenta = AD, cyan = MB. Watch whether they SLIDE when the aura is applied.", "NEUTRAL")
    end
    function DF:DebugADMissing()
        local o = DF:Out("Aura Designer", "missing-mode probe")
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
                                if not shown then shown = true; o:Section("unit " .. tostring(frame.unit)) end
                                dumpHandle("AD:" .. storeKey, tostring(key), entry.handle)
                            end
                        end
                    end
                end
            end
            -- Control group: the proven Missing Buffs cells on the same frame.
            if frame.missingFactory then
                for key, h in pairs(frame.missingFactory) do
                    if not shown then shown = true; o:Section("unit " .. tostring(frame.unit)) end
                    dumpHandle("MB", tostring(key), h)
                end
            end
        end
        if DF.IteratePartyFrames then DF:IteratePartyFrames(scan) end
        if DF.IterateRaidFrames then DF:IterateRaidFrames(scan) end
        o:Line("Run once with the aura absent and once applied, then compare 'children'.", "NEUTRAL")
        o:Siblings("admissing")
    end
end

-- ☠ (Removed) a file-scope `DF:Debug(DBG, "Factory (native AD bridge) loaded")`. It could
-- never print: DebugConsole:Init binds debugDb from ADDON_LOADED, long after every file
-- has been parsed, so a log call at chunk level is a guaranteed no-op -- it allocated its
-- argument and returned nothing, in every session this addon has ever run. The same trap
-- is documented in Core.lua's migration trace, which buffers until the console exists.
-- Anything that genuinely needs to report at load must use that buffer, not a bare call.
