local addonName, DF = ...

-- ============================================================
-- AURA FILTERING SYSTEM
-- Hooks into Blizzard's raid frame aura filtering to capture results
-- ============================================================

-- Local caching of frequently used globals and WoW API for performance
local pairs, ipairs, type, pcall, wipe = pairs, ipairs, type, pcall, wipe
local C_UnitAuras = C_UnitAuras

-- Additional cached API for direct aura update (Tier 1 optimization)
local UnitExists = UnitExists
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local UnitIsConnected = UnitIsConnected
local UnitIsPlayer = UnitIsPlayer
local InCombatLockdown = InCombatLockdown
local issecretvalue = issecretvalue
local C_CurveUtil = C_CurveUtil

-- (Removed) the 2025-01-20 aura-entry table pool (tablePool / poolSize) and the
-- cached IsAuraFilteredOutByInstanceID / strfind / tinsert / tremove. All were
-- infrastructure for the old scan-and-cache pipeline; the 12.1 container port made
-- the pool unreachable and left the rest as unused upvalues.

-- Forward declarations: these helpers are defined later in the file but used
-- by code above their definitions (the ClassifyAura defensive/dispel filter
-- pass), computing aura classification via the secret-safe
-- IsAuraFilteredOutByInstanceID API.
local BuildDirectDefensiveFilters

-- ============================================================
-- DIRECT AURA API PROVIDER
-- Queries C_UnitAuras directly with user-configured filter strings
-- Builds the native filter strings the 12.1 container rows consume.
-- ============================================================

-- ☠ RESOLVES LIVE ON EVERY READ. DO NOT turn this back into a plain capture.
--
-- This was `local AuraFilters = AuraUtil and AuraUtil.AuraFilters or {}` — a
-- ONCE-PER-SESSION bind at file load. `AuraUtil` is Blizzard's, and if it had not
-- loaded yet at that instant the local latched an EMPTY table for the whole session
-- with no way to recover: nothing re-read it, so every token below silently became
-- nil until the next /reload happened to win the race.
--
-- What that cost (12.1 launch, roughly 1 user in 10): with no BigDefensive token,
-- BuildDefensiveRowConfig's "all" fallback produced NO filter and NO candidateFilters,
-- normalizeFilters applied its last-ditch `{ f = "HELPFUL" }` default, and the
-- DEFENSIVE ICON row rendered EVERY helpful aura — food buffs, Sign of the Emissary.
-- A /reload "fixed" it permanently because the file re-executed and re-captured.
-- Nothing about a settings toggle can re-bind a file-scope local, which is why
-- toggling filters did not reliably help.
--
-- The proxy keeps every existing `AuraFilters.X` call site working unchanged while
-- reading through to Blizzard each time — so a late `AuraUtil` is picked up on the
-- next access instead of never. `__index` fires for every key because this table is
-- permanently empty. These are config-build paths, not per-frame ones, so the extra
-- hop is irrelevant.
--   ⚠ The literal fallback at the RaidPlayerDispellable site below predates this and
-- is now redundant, but harmless — left alone rather than churn a working line.
local AuraFilters = setmetatable({}, {
    __index = function(_, key)
        local t = AuraUtil and AuraUtil.AuraFilters
        return t and t[key] or nil
    end,
})

-- Cached filter tables per mode (rebuilt only when settings change)
-- Each is nil (show all / unavailable) or a table of individual filter strings
-- e.g. {"HELPFUL|PLAYER", "HELPFUL|RAID", "HELPFUL|BIG_DEFENSIVE"}
local cachedPartyBuffFilters = nil
local cachedRaidBuffFilters = nil
local cachedDefensiveFilters = nil   -- mode-independent

-- Build the filter string for buffs. One native group: category selection is
-- expressed via candidateFilters spell-ID maps (see BuildAuraRowConfig), so the
-- filterString only carries HELPFUL + Only Mine.
--
-- Defensive Bar dedup, HALF ONE — the CATEGORY case. When the defensive bar has
-- no filter selection it falls back to Blizzard's BIG_DEFENSIVE category, whose
-- contents are not spell IDs and cannot be enumerated. The expressible
-- complement is the negated token: the grammar takes a "!" prefix on any
-- AuraFilters component (AuraUtil.AuraFilterNegationPrefix), which is how the
-- debuff row already keeps its groups disjoint. HALF TWO — the exact,
-- spell-ID case — is in BuildAuraRowConfig.
--
-- Gated on the bar actually being ON: excluding the category while nothing else
-- displays it would make those buffs invisible on every bar.
local function BuildDirectBuffFilters(db)
    local f = db.directBuffOnlyMine and "HELPFUL|PLAYER" or "HELPFUL"
    if db.buffDeduplicateDefensives and db.defensiveIconEnabled
        and AuraFilters.BigDefensive and DF.FilterRegistry then
        local res = DF.FilterRegistry:ResolveSelection(db.defensiveFilterSelection, false)
        -- Only the "all" fallback is category-driven; include/exclude modes are
        -- spell-ID driven and handled exactly in HALF TWO.
        if res.kind ~= "include" and res.kind ~= "exclude" then
            f = f .. "|!" .. AuraFilters.BigDefensive
        end
    end
    return { f }
end

-- Blizzard's AuraUtil.DispellableDebuffTypes verbatim — the map form of the
-- Dispellable filter in "ALL" mode. Shared READ-ONLY by reference: Blizzard
-- reads it from candidateFilters, we never mutate it (each record's cf table
-- itself is per-record; only this inner map is shared).
local DISPEL_TYPES = { Magic = true, Curse = true, Disease = true, Poison = true, Bleed = true }

-- Shared with the dispel OVERLAY (Features/Dispel.lua), which needs the identical
-- map for its own "All Dispellable" mode. Exported rather than duplicated: a second
-- copy is exactly the drift hazard that retired DISPEL_ICON_TYPES. Read-only for
-- every consumer -- see the note above.
DF.DispelTypeMap = DISPEL_TYPES

-- ============================================================
-- ☠ THE ENGINE'S DISPEL FLAGS MISS TOTEM-BASED REMOVAL.
-- RAID_PLAYER_DISPELLABLE (and the older RAID flag) are computed from the
-- player's direct dispel SPELLS, and a Shaman's poison answer is Poison
-- Cleansing Totem -- not a targeted dispel, so the engine never counts it.
-- Field report: a Shaman's dispel overlay stayed dark on poisons (Krathe,
-- 2026-08-22). VuhDo and ElvUI both hand-count the totem for exactly this
-- reason (VuhDoDebuffConst SHAMAN Poison = {383013}; LibDispel CheckSpell
-- 383013); Grid2 and Ellesmere trust the flag and share the gap.
--
-- This helper is the ONE place that knowledge lives. Returns the dispel-type
-- map the engine flag misses for the current character, or nil when there is
-- no gap -- consumed by the overlay's by-me slot plan (Features/Dispel.lua)
-- and the debuff row's by-me records (below), each of which pairs it with a
-- "|!RAID_PLAYER_DISPELLABLE" negation so the repair never double-renders
-- what the flag already catches.
--
-- ★ THIS WORKS IN COMBAT, and the reason is worth stating because I twice
-- claimed the opposite. ADDON Lua genuinely cannot read aura data in combat
-- (~450k spells secret against a ~60 entry NeverSecret whitelist -- Krathe,
-- 2026-08-22, and he is right about that). But candidateFilters are NOT
-- evaluated by us: the container hands them to
-- AuraContainerUtil.DoesAuraPassCandidateFilters, and Blizzard_AuraContainer
-- declares `## UseSecureEnvironment: 1`, so that matcher is TRUSTED code
-- reading REAL values. Proof by something already shipping: maxDuration is
-- compared in the very same function, and Hide Long Debuffs works in combat.
-- ☠ "Secret to addons" and "secret to Blizzard's own filter" are different
-- questions -- do not collapse them again.
--
-- ⚠ Real limits, which are narrower: includeSpellIDs / excludeSpellIDs (NOT
-- the dispel-type maps) are the pair gated by CanApplyIdentityCandidateFilters,
-- so a spell-ID filter is refused on a harmful aura on an assistable unit --
-- see [[identity_gate_reference]]. Type maps are outside that gate.
--
-- The peers hold the same knowledge but wire it into their own LEGACY Lua
-- scan paths (VuhDo VUHDO_PLAYER_DISPEL_ABILITIES; ElvUI UF:AuraDispellable),
-- which read aura data in ADDON code and therefore really do go dark in
-- combat. VuhDo's container path narrows RAID_PLAYER_DISPELLABLE by
-- includeDispelTypes -- an intersection, which cannot add back a type the
-- token already dropped.
--
-- ⚠ 2026-08-26, AMENDED: this used to end "so DF's ADDITIVE record is the only
-- shape in the surveyed set that repairs the gap". That was true of the set
-- surveyed at the time and is now INCOMPLETE. EllesmereUI ships a third shape
-- that also works -- SUBSTITUTIVE: it keeps a slot PER DISPEL TYPE, so for the
-- Poison slot it simply drops the token and lets that slot's own
-- includeDispelTypes do the narrowing (EUI_RaidFrames_AuraContainers.lua,
-- DispelSlotFilter). Neither shape is better; each is the only one its own
-- architecture allows. Ours collapsed the overlay to ONE slot, so there is no
-- per-type slot left to relax and the repair has to add. Do not re-derive the
-- "only shape" claim -- it is a statement about DF's topology, not about the
-- API.
-- ★ Where they ARE ahead: they also repair BLEED via the Dwarf racial (see
-- ENGINE_GAP_BLEED below), which we copied. Where we are ahead: they probe with
-- IsPlayerSpell, which on 12.1 lives in Blizzard_DeprecatedSpellBook behind
-- `if not GetCVarBool("loadDeprecationFallbacks") then return end` -- verified in
-- the local dump -- so their repair silently no-ops for anyone with that CVar
-- off. That is the exact trap the note below records us falling into first.
--
-- ⚠ Re-checked on every call, never cached: the totem is a TALENT, so a cached answer
-- would survive exactly the event that changes it.
--
-- ☠ THE RE-DRIVE ROUTE IS NOT WHAT THIS COMMENT USED TO SAY. It claimed talent swaps
-- reach the plans "through the coalesced PLAYER_TALENT_UPDATE -> UpdateAllFrames path".
-- UpdateAllFrames does NOT bump auraLayoutVersion, and the drives are version-gated, so
-- that route on its own leaves the overlay on its fast path and never re-plans. What
-- actually carried it was the AD engine: the same handler calls
-- Engine:ForceRefreshAllFrames, which ends in DF:InvalidateAuraLayout. A dispel feature
-- depending on the Aura Designer's refresh to notice a talent is the kind of link nobody
-- would look for when it breaks, so the talent handler now bumps the version itself
-- (Core.lua) and this no longer rides a sibling feature.
--
-- ☠☠ NOT IsPlayerSpell. The first cut used it, and on a 12.1 client that
-- function EXISTS ONLY IF A CVAR IS ON: it lives in Blizzard_DeprecatedSpellBook
-- behind `if not GetCVarBool("loadDeprecationFallbacks") then return end`, is
-- absent from the 12.1 API documentation entirely, and is slated for removal
-- next expansion. With the CVar off it is nil, the `IsPlayerSpell and ...`
-- guard short-circuits, and the whole repair becomes a SILENT NO-OP with no
-- error and no log -- the silent-capability-skip antipattern, shipped by me.
-- C_SpellBook.IsSpellInSpellBook is the documented call and the one BOTH peers
-- use on current builds (ElvUI LibDispel CheckSpell, VuhDo VUHDO_isSpellKnown),
-- with includeOverrides = true so a talent-granted override still counts.
--
-- ★ THREE OUTCOMES, NOT TWO. nil means "cannot tell" and is logged once --
-- distinct from a confident false. A capability probe that cannot run must say
-- so rather than quietly answering "no".
local ENGINE_GAP_POISON = { Poison = true }
-- ★ THE RACIAL GAP. RAID_PLAYER_DISPELLABLE knows class and spec dispels, and NOTHING a
-- class learns removes a Bleed -- only the Dwarf racial, Stoneform. So without this, "Only
-- Dispellable by You" can never light for a bleed, for anybody, ever.
-- ☠ SELF ONLY, and BLEED only. A racial cleanses its own caster, so it says nothing about
-- anyone else's frame -- hence the selfOnly argument rather than a class-wide answer.
-- Stoneform also clears poison/disease/curse, but any class that dispels those already
-- passes the token, and treating a two-minute racial as a dispel would overlay most of
-- what a dwarf ever catches. Both scoping decisions match EllesmereUI's, which reached
-- them first; the reasoning is theirs and it holds for us.
local ENGINE_GAP_BLEED  = { Bleed = true }
local ENGINE_GAP_BOTH   = { Poison = true, Bleed = true }   -- a dwarf shaman is a real thing
local POISON_CLEANSING_TOTEM = 383013
local warnedNoSpellProbe = false
local function KnowsPoisonCleansingTotem()
    local sb = C_SpellBook
    local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player
    if sb and bank then
        -- ☠☠ IsSpellKnown, NOT IsSpellInSpellBook. THE TWO ANSWER DIFFERENT QUESTIONS and
        -- we shipped the wrong one — Blizzard's own documentation says so outright:
        --   IsSpellInSpellBook — "Returns true if a spell should be found in the spellbook.
        --     This function CAN ALSO RETURN TRUE FOR SPELLS THAT AREN'T KNOWN, such as
        --     override spells granted by an aura linked to CLASS TALENTS."
        --   IsSpellKnown      — "Returns true if a player KNOWS a spell."
        -- Poison Cleansing Totem is precisely a talent-linked entry, so the spellbook probe
        -- answered true for every shaman alive and the poison gap slot was added whether or
        -- not the totem was talented. Field-reported: "it's still showing when they don't
        -- have the totem talent. It's a half fix." (Krathe, 2026-08-26.)
        -- ⚠ A capability probe must ask about the CAPABILITY. "Would this appear in the
        -- spellbook UI" is a rendering question and was never the right one.
        if sb.IsSpellKnown then
            return sb.IsSpellKnown(POISON_CLEANSING_TOTEM, bank) and true or false
        end
        -- ⚠ LAST RESORT, AND IT OVER-REPORTS — see above. Kept only so a build without
        -- IsSpellKnown still repairs the gap for the shamans who DO have the totem, at the
        -- cost of also repairing it for those who do not. Better than the feature being
        -- silently dead, worse than being right.
        if sb.IsSpellInSpellBook then
            return sb.IsSpellInSpellBook(POISON_CLEANSING_TOTEM, bank, true) and true or false
        end
    end
    -- Deprecation shim; present only with loadDeprecationFallbacks on.
    if IsPlayerSpell then
        return IsPlayerSpell(POISON_CLEANSING_TOTEM) and true or false
    end
    if not warnedNoSpellProbe then
        warnedNoSpellProbe = true
        if DF.DebugError then
            DF:DebugError("DISPEL", "no spellbook API available - cannot test for "
                .. "Poison Cleansing Totem; the Shaman dispel-flag repair is inactive")
        end
    end
    return nil
end

-- selfOnly: pass true ONLY for the player's own frame. It adds the racial (Bleed) half,
-- which is meaningless on anyone else's frame. Omit it and the answer is the class-wide
-- one, which is what the debuff row wants — the row builds its records per db, not per
-- frame, so it has no self to distinguish and must not claim one.
function DF:GetEngineDispelFlagGaps(selfOnly)
    local _, class = UnitClass("player")
    -- ⚠ Three outcomes upstream: KnowsPoisonCleansingTotem returns nil for "cannot tell".
    -- Collapsed to false here, as it always was — an unreadable probe must not assert a
    -- capability, and it has already logged itself once.
    local poison = class == "SHAMAN" and KnowsPoisonCleansingTotem() == true
    local bleed = false
    if selfOnly then
        local _, race = UnitRace("player")
        bleed = race == "Dwarf"
    end
    if poison and bleed then return ENGINE_GAP_BOTH end
    if poison then return ENGINE_GAP_POISON end
    if bleed then return ENGINE_GAP_BLEED end
    return nil
end

-- Build the debuff filter records (native 12.1 category filters).
-- Returns nil (show all) or an array of records { filter, key, candidateFilters }
-- — the record form normalizeFilters accepts; each record becomes one container
-- group behind the single visual debuff row.
--
-- Dedup at build time (token ownership order: dispel > cc > raid): a group's
-- filterString appends "|!TOKEN" for every enabled token-backed filter with
-- higher priority than itself; the boolean-backed groups (bossrole, priority)
-- negate ALL enabled token filters. Dispellable "ALL" and "ANY" modes are BOTH
-- token-backed (DISPELLABLE) and dedup via "|!DISPELLABLE" negations -- ALL
-- moved off the includeDispelTypes map because one canonical filter component
-- beats a five-entry copy of Blizzard's own type list (NOT for the secrecy
-- reason the introducing commit gave -- see the dispelTypeToken note in
-- BuildDirectDebuffFilters). Only a token-less client degrades to the map
-- form, includes and excludes together, which is equivalent. A record never
-- negates its own token. Priority×Boss/Role overlap is accepted (bools can't
-- be negated).
--
-- `claimed` (C1 row-claim dedup, ROW path only — nil on the AD facade path):
-- the set of categories owned by enabled Aura Designer debuff groups
-- (DF:GetClaimedDebuffCategories — keys boss/role/priority/crowdControl/raid/
-- dispellable). A claimed category's RECORD is dropped from the row, but its
-- negation / exclude-dispel contributions to the OTHER records are KEPT — the
-- AD group displays those auras, so the row must keep excluding them
-- everywhere. Dispellable claims are mode-agnostic (a group claiming
-- dispellable in either mode drops the row's dispel record whatever the row's
-- own mode is — simplest rule). Boss/role narrow independently: claiming only
-- boss while the row shows boss+role narrows the record to isRoleAura.
-- (A narrowed record keeps the accepted Priority×Boss/Role bool overlap above —
-- narrowing only shrinks the record's own flag, it never adds new negations.)
-- Show All short-circuits BEFORE claims — an ALL-mode row never consults them.
-- When claims empty a NON-empty selection the return is an EMPTY array (render
-- nothing) — distinct from nil (show all); normalizeFilters would map {} back
-- to show-all, so DriveDebuffFactory intercepts the empty list and parks the
-- row instead of building a container from it.
local function BuildDirectDebuffFilters(db, claimed)
    -- One toggle owns EVERY claim path — the record-drop below AND the ALL-mode
    -- subtraction. Pre-5.0 the claim was silent and unconditional, which meant
    -- nobody could see why a category had vanished from their bar, and nobody
    -- could keep the duplicate if they wanted it.
    if db.debuffDeduplicateDesigner == false then claimed = nil end

    -- IMPORTANT HIGHLIGHT: the per-record button style handed to whichever records
    -- hold boss/role and priority auras. Declared HERE, above the Show All branch,
    -- because both modes need it — the first cut declared it further down and was
    -- therefore out of scope in Show All, which is the DEFAULT, so the feature did
    -- nothing at all on an untouched profile.
    --
    -- ★ Why this is expressible under 12.1: we never ask a button what it holds
    -- (spellId / dispelName / presence are secret). Blizzard filters the group, so
    -- membership IS the predicate and every button in it can be styled blind.
    --
    -- Nil for the Aura Designer facade — that caller builds a synthetic db with no
    -- debuffImportant* keys, so AD groups keep their own styling (row-only).
    local importantStyle
    if db.debuffImportantHighlight then
        local sc = tonumber(db.debuffImportantScale) or 1
        importantStyle = {
            scale = (sc > 0) and sc or 1,
            badge = db.debuffImportantBadge ~= false and {
                size = tonumber(db.debuffImportantBadgeSize) or 12,
                point = db.debuffImportantBadgePoint or "TOPRIGHT",
                offsetX = tonumber(db.debuffImportantBadgeX) or 0,
                offsetY = tonumber(db.debuffImportantBadgeY) or 0,
                color = db.debuffImportantBadgeColor,
                markColor = db.debuffImportantMarkColor,
            } or nil,
        }
    end

    if db.directDebuffShowAll then
        -- ALL mode: no category filtering, but Hide Long Debuffs still applies as
        -- one native maxDuration record. Keep Important CANNOT be honoured here:
        -- exempting boss/role/priority needs a second un-capped record, and the
        -- ALL record can't negate those boolean flags — importants would render
        -- twice. The GUI hides the toggle in ALL mode.
        local allMaxDur = db.debuffMaxDurationEnabled and (db.debuffMaxDurationMinutes or 0) > 0
            and (db.debuffMaxDurationMinutes or 0) * 60 or nil

        -- Claims SUBTRACT here rather than dropping a record: ALL mode is one
        -- blanket HARMFUL group, so there is no per-category record to remove.
        -- Boolean-backed categories invert through candidateFilters (false =
        -- "not this"; the group ANDs them, so several falses read as "none of
        -- these"). Token-backed ones negate in the filter string, exactly as the
        -- category-mode records already do.
        -- ⚠ This is what the old "Show All short-circuits BEFORE claims" note
        -- described: an AD group showing boss/role/priority rendered those
        -- debuffs a second time on the bar. Show All is the DEFAULT, so that hit
        -- most setups, not just category-mode ones.
        local cf, filterStr = nil, "HARMFUL"
        if claimed then
            local function need() cf = cf or {}; return cf end
            if claimed.boss and claimed.role then need().isBossOrRoleAura = false
            elseif claimed.boss then need().isBossAura = false
            elseif claimed.role then need().isRoleAura = false end
            if claimed.priority then need().isPriorityAura = false end
            if claimed.crowdControl and AuraFilters.CrowdControl then
                filterStr = filterStr .. "|!" .. AuraFilters.CrowdControl
            end
            if claimed.raid then filterStr = filterStr .. "|!RAID" end
            if claimed.dispellable then
                -- Mirrors the category-mode split: the token when the build has
                -- it, else the dispel-type map (same semantics, no token).
                if AuraFilters.Dispellable then
                    filterStr = filterStr .. "|!" .. AuraFilters.Dispellable
                else
                    need().excludeDispelTypes = DISPEL_TYPES
                end
            end
        end
        if allMaxDur then cf = cf or {}; cf.maxDuration = allMaxDur end

        -- IMPORTANT HIGHLIGHT in ALL mode. Show All is normally ONE blanket HARMFUL
        -- record, which is why the highlight did nothing here: there is no boss/role
        -- or priority record to style. Split into three MUTUALLY EXCLUSIVE records so
        -- the important ones can be styled and still lead the row (groups render in
        -- declaration order). Exclusive by construction, because groups do NOT dedupe
        -- against each other — overlapping filters would show an aura twice:
        --   1 boss-or-role                                  -> styled
        --   2 priority, NOT boss-or-role                    -> styled
        --   3 neither                                       -> normal
        -- Each inherits the claim/maxDuration cf built above, so Hide Long Debuffs and
        -- Aura Designer claims keep working. A claimed category drops its record
        -- entirely rather than being filtered out of it.
        --
        -- ⚠ ONLY when the highlight is on. With it off this stays exactly one record —
        -- Show All is the default for everyone, and splitting it unconditionally would
        -- change every existing user's row for a feature they never enabled.
        if importantStyle then
            local function withCf(extra)
                local t = {}
                if cf then for k, v in pairs(cf) do t[k] = v end end
                for k, v in pairs(extra) do t[k] = v end
                return t
            end
            local out = {}
            -- claimed.boss AND claimed.role = the whole boss-or-role pool is the AD's;
            -- a partial claim leaves the rest, and the claim cf above already excludes
            -- the claimed half (isBossAura/isRoleAura = false ANDs with the flag here).
            if not (claimed and claimed.boss and claimed.role) then
                out[#out + 1] = { filter = filterStr, key = "allboss", style = importantStyle,
                                  candidateFilters = withCf({ isBossOrRoleAura = true }) }
            end
            if not (claimed and claimed.priority) then
                out[#out + 1] = { filter = filterStr, key = "allprio", style = importantStyle,
                                  candidateFilters = withCf({ isBossOrRoleAura = false, isPriorityAura = true }) }
            end
            out[#out + 1] = { filter = filterStr, key = "all",
                              candidateFilters = withCf({ isBossOrRoleAura = false, isPriorityAura = false }) }
            return out
        end

        if cf or filterStr ~= "HARMFUL" then
            return { { filter = filterStr, key = "all", candidateFilters = cf } }
        end
        return nil
    end
    local dispelOn = db.debuffFilterDispellable
    local dispelMode = db.directDebuffDispellableMode
    -- ★ BOTH non-player modes ride the DISPELLABLE token, not just ANY. ALL mode
    -- used to build the Lua map form (includeDispelTypes = DISPEL_TYPES); the token
    -- says the same thing in Blizzard's own words -- "Include only auras that are
    -- dispellable, regardless of whether the player's raid can dispel them"
    -- (Blizzard_FrameXMLUtil/AuraUtil.lua) -- in one filter component, with no
    -- five-entry table to keep in step with Blizzard's own list. That is the whole
    -- justification: it is simpler and canonical.
    --
    -- ☠☠ IT IS **NOT** A SECRECY FIX, whatever the commit that introduced it said.
    -- I claimed the map was secrecy-blind (dispelName secret => raw index never
    -- matches) and that this is why "All Dispellable" showed nothing. That is
    -- FALSE: the matcher lives in Blizzard_AuraContainer, which is
    -- `## UseSecureEnvironment: 1`, so it reads real values -- and maxDuration,
    -- compared in the same function, demonstrably works in combat (Hide Long
    -- Debuffs). ⚠ SO THE ORIGINAL REPORT IS STILL UNDIAGNOSED: dispellable debuffs
    -- missing from the row while the overlay showed them (Krathe, 2026-08-22).
    -- Do not treat it as closed, and do not re-derive the secrecy theory --
    -- see DF:GetEngineDispelFlagGaps below for the evidence chain.
    --
    -- Defensive read like CrowdControl: on a client without the token this stays
    -- nil and both modes fall back to the map form below, which is equivalent.
    -- ⚠ "ANY" is a RETIRED stored value, not a live mode: its dropdown row was
    -- collapsed into ALL (2026-08-22) once both rode this token and became one
    -- query. It stays accepted here because an imported profile or shared
    -- template can carry it forever; Core.lua rewrites it in profiles and the
    -- editors self-heal group copies, but the engine must never depend on that.
    local dispelTypeToken = dispelOn and (dispelMode == "ALL" or dispelMode == "ANY")
        and AuraFilters.Dispellable or nil
    local playerMode = dispelOn and dispelMode ~= "ALL" and dispelMode ~= "ANY"
    -- Engine-flag gap (Shaman poison via totem): resolved once per build, consumed
    -- by the by-me repair record below AND the non-player record's dedup exclude.
    -- Deliberately NOT gated on the claim: a claimed dispellable category renders
    -- in its AD group (whose facade builds its own repair record), and the row's
    -- other records must keep excluding what the group displays -- same rule as
    -- every other claim-kept negation in this function.
    local dispelGap = dispelOn and playerMode
        and DF.GetEngineDispelFlagGaps and DF:GetEngineDispelFlagGaps() or nil
    -- CC needs its Blizzard token; skip the group entirely if unavailable
    local ccToken = db.debuffFilterCrowdControl and AuraFilters.CrowdControl or nil
    local raidOn = db.debuffFilterRaid
    local dispelToken = AuraFilters.RaidPlayerDispellable or "RAID_PLAYER_DISPELLABLE"
    local maxDur = db.debuffMaxDurationEnabled and (db.debuffMaxDurationMinutes or 0) > 0 and (db.debuffMaxDurationMinutes or 0) * 60 or nil
    local keepImportant = db.debuffMaxDurationKeepImportant

    -- Negation suffix for a group, given which higher-priority token filters
    -- apply to it. ALL-mode dispel dedups via excludeDispelTypes (see cfFor).
    -- Token precedence among the NON-important records is dispel > CC > raid >
    -- non-player, so each record excludes the ones above it.
    -- ☠ THE RAID EXCLUSION IS NOT OPTIONAL ANY MORE, and the comment that used to sit
    -- here said it was ("raid is the last token record, so nothing needs to exclude
    -- it"). That was true when it was written and stopped being true the moment the
    -- NON-PLAYER record was added below it — see that record's own note. Every
    -- exclusion is keyed on the CONFIG flag, not on the record existing: a category
    -- claimed by an Aura Designer group is shown there instead, so subtracting it
    -- here is the dedup working, not a leak.
    local function neg(excludeDispel, excludeCC, excludeRaid)
        local s = ""
        if excludeDispel then
            if playerMode then s = s .. "|!" .. dispelToken
            elseif dispelTypeToken then s = s .. "|!" .. dispelTypeToken end
        end
        if excludeCC and ccToken then s = s .. "|!" .. ccToken end
        -- "RAID" is negatable (only INCLUDE_NAME_PLATE_ONLY and MAW are not —
        -- AuraUtil.AuraFilters / IsValidFilterString).
        --
        -- ⚠ 2026-08-26: this line briefly dropped the negation while the player was dead
        -- (c46e4771, reverted here). Blizzard's comment on the token is "harmful auras THE
        -- PLAYER CAN DISPEL", and the guess was that a dead player therefore matches
        -- nothing, so the records deduping against it had to stop at the same moment.
        -- ☠ THE GUESS WAS UNVERIFIED AND MAY BE BACKWARDS. The token is evaluated
        -- engine-side (C_UnitAuras.IsAuraFilteredOutByInstanceID) and is not readable from
        -- the Lua dump, so "empties" and "fails open" are equally consistent with the
        -- source — and only ONE of this row's records negates RAID for a typical config
        -- (nonplayer), which makes the empties case a straight TRANSFER that cannot add
        -- icons. The field report is that dying ADDS them. Do not re-apply either
        -- direction without a capture: /df debug AURAROW now logs the per-group counts
        -- (raid=N nonplayer=N) alive and dead, which distinguishes the two outright.
        if excludeRaid and raidOn then s = s .. "|!RAID" end
        return s
    end
    -- candidateFilters for one record. Hands each record its OWN table (extra
    -- is per-record); important groups (bossrole/priority) are exempt from
    -- maxDuration when Keep Important is on.
    local function cfFor(important, extra)
        local cf = extra or {}
        -- Map-form dedup, paired with the map-form include record: both are used
        -- only on a token-less client, and they are exact complements there.
        if dispelOn and not playerMode and not dispelTypeToken then cf.excludeDispelTypes = DISPEL_TYPES end
        if maxDur and not (important and keepImportant) then cf.maxDuration = maxDur end
        if next(cf) == nil then return nil end
        return cf
    end

    -- CATEGORY mode: the boss/role and priority records below already exist and are
    -- already declared FIRST, so "important debuffs lead the row" needs no sort work —
    -- importantStyle (declared at the top of this function) only styles them.
    local filters = {}
    local boss, role = db.debuffFilterBoss, db.debuffFilterRole
    -- Claim-effective category flags (claimed nil = all pass; the negation/exclude
    -- machinery above deliberately keeps reading the RAW enabled flags).
    local effBoss = boss and not (claimed and claimed.boss)
    local effRole = role and not (claimed and claimed.role)
    -- IMPORTANT-FIRST PRECEDENCE. These records used to carry neg(true, true, true),
    -- i.e. boss/role and priority EXCLUDED anything dispellable, CC or raid-flagged.
    -- That made the important categories the LOWEST precedence: a priority debuff that
    -- also carried the RAID token was pushed out of this styled record and into the
    -- unstyled "raid" one below, so the Important Debuffs highlight silently did nothing
    -- for it. Most boss/priority debuffs in group content DO carry RAID, so with the
    -- Blizzard category filters enabled the highlight looked broken for about half the
    -- auras it should have covered (field-reported; Show All mode was unaffected).
    --
    -- Exclusivity now runs the same direction Show All mode has always used (see the
    -- ALL-mode block near the top of this file): the important records claim their auras
    -- FIRST with no negation, and the token records below subtract them via
    -- candidateFilter flags. Same no-double-render guarantee, correct precedence, and
    -- important debuffs now genuinely lead the row rather than only sometimes.
    local importantFlag   -- boss/role flag actually declared; nil if there is no such record
    local priorityDeclared = false
    if effBoss or effRole then
        importantFlag = (effBoss and effRole) and "isBossOrRoleAura" or (effBoss and "isBossAura" or "isRoleAura")
        filters[#filters + 1] = { filter = "HARMFUL", key = "bossrole",
                                  candidateFilters = cfFor(true, { [importantFlag] = true }),
                                  style = importantStyle }
    end
    if db.debuffFilterPriority and not (claimed and claimed.priority) then
        priorityDeclared = true
        local extra = { isPriorityAura = true }
        -- Only subtract boss/role when that record actually exists, and subtract the
        -- SAME flag it was declared with (isBossOrRoleAura / isBossAura / isRoleAura).
        if importantFlag then extra[importantFlag] = false end
        filters[#filters + 1] = { filter = "HARMFUL", key = "priority",
                                  candidateFilters = cfFor(true, extra),
                                  style = importantStyle }
    end
    -- Subtract whichever important records were declared. Returns a FRESH table each
    -- call because cfFor mutates and returns the table it is handed.
    local function notImportant(extra)
        extra = extra or {}
        if importantFlag then extra[importantFlag] = false end
        if priorityDeclared then extra.isPriorityAura = false end
        return extra
    end
    if ccToken and not (claimed and claimed.crowdControl) then
        filters[#filters + 1] = { filter = "HARMFUL|" .. ccToken .. neg(true, false),
                                  key = "cc", candidateFilters = cfFor(false, notImportant()) }
    end
    if raidOn and not (claimed and claimed.raid) then
        filters[#filters + 1] = { filter = "HARMFUL|RAID" .. neg(true, true),
                                  key = "raid", candidateFilters = cfFor(false, notImportant()) }
    end
    if dispelOn and not (claimed and claimed.dispellable) then
        if playerMode then
            filters[#filters + 1] = { filter = "HARMFUL|" .. dispelToken,
                                      key = "dispel", candidateFilters = cfFor(false, notImportant()) }
            -- ★ ENGINE-FLAG GAP REPAIR (Shaman poison via totem -- see
            -- DF:GetEngineDispelFlagGaps above for the whole story). A sibling
            -- record for the types the flag misses: negates the flag token so it
            -- never doubles what the flag already catches, and negates the CC and
            -- RAID tokens per the standard precedence (dispel owns its overlap).
            -- The NON-PLAYER overlap is handled on that record instead (it
            -- excludes these types while a gap is active), so the include here
            -- and the exclude there are exact complements.
            if dispelGap then
                filters[#filters + 1] = { filter = "HARMFUL|!" .. dispelToken .. neg(false, true, true),
                                          key = "dispelgap",
                                          candidateFilters = cfFor(false, notImportant({ includeDispelTypes = dispelGap })) }
            end
        elseif dispelTypeToken then
            filters[#filters + 1] = { filter = "HARMFUL|" .. dispelTypeToken,
                                      key = "dispel", candidateFilters = cfFor(false, notImportant()) }
        else
            -- ⚠ TOKEN-LESS FALLBACK ONLY -- never the primary path on a live client.
            -- The map form works: the matcher (DoesAuraPassCandidateFilters, in
            -- Blizzard_AuraContainerUtil.lua INSIDE the Blizzard_AuraContainer addon,
            -- whose TOC declares UseSecureEnvironment) reads real values, not secrets
            -- -- see the evidence chain on DF:GetEngineDispelFlagGaps. An earlier
            -- version of this comment claimed the map "matches NOTHING once dispel
            -- names go secret"; that secrecy theory was falsified (lab discussion
            -- 08ac7310, 2026-08-25). The token is preferred only because it is
            -- Blizzard's own canonical filter component, with no local copy of the
            -- type list to keep in step.
            local cf = notImportant({ includeDispelTypes = DISPEL_TYPES })
            if maxDur then cf.maxDuration = maxDur end
            filters[#filters + 1] = { filter = "HARMFUL", key = "dispel", candidateFilters = cf }
        end
    end
    -- ★ NON-PLAYER: everything the engine says no player or player pet applied.
    -- ☠ THIS CANNOT BE A TOKEN. `!PLAYER` negates only YOUR OWN casts, so every other
    -- player's Sated / Exhaustion / Forbearance still comes through — which is precisely
    -- the noise this category exists to remove. The candidate boolean is engine-evaluated
    -- against the real caster, so isFromPlayerOrPlayerPet = false is the only way to say
    -- "applied by nobody in the group".
    -- ⚠ The field name reads like "the player" and means "A player" — it matches ANY
    -- player's casts, not just yours. Hence false = "no player at all" rather than "not
    -- me", and hence it is not interchangeable with the PLAYER token.
    -- ⚠ No claim key yet: an Aura Designer group cannot claim this category, so the
    -- record always builds when the option is on. Add one beside the others if a group
    -- ever needs to take it over.
    -- ☠☠ IT MUST NEGATE THE TOKEN RECORDS ABOVE IT, and for its first months it did not.
    -- Every other record in this function subtracts its higher-precedence siblings;
    -- this one shipped as a bare "HARMFUL" plus one candidate boolean, so ANY mob-cast
    -- debuff that was also dispellable / crowd-control / raid-flagged rendered TWICE —
    -- once here and once in that record. There is NO cross-group dedup in the engine
    -- (each AddAuraGroup parses the whole pool independently), so overlapping filters
    -- are the only thing standing between a config and double-rendered icons.
    -- Field shape: trash packs applying poison and disease (both dispellable, both
    -- mob-cast) filled the row with pairs of identical icons and blew past the row's
    -- Max Debuffs, because that cap is PER GROUP — 4 categories x 3 = up to 12
    -- (Beans, 5.2.0-alpha.1, Vaults of Atal'Ulek and delves).
    -- ⚠ In ALL-mode dispel the exclusion rides cfFor's excludeDispelTypes instead, so
    -- neg's dispel half is correctly inert there — the two paths must not double up.
    if db.debuffFilterNonPlayer then
        local npCf = notImportant({ isFromPlayerOrPlayerPet = false })
        -- Gap-repair dedup, the other half (see the dispelgap record above): while
        -- the by-me repair is active, the types it covers are ITS overlap to own,
        -- so this record excludes them -- the exact complement of that include.
        if dispelGap then npCf.excludeDispelTypes = dispelGap end
        filters[#filters + 1] = { filter = "HARMFUL" .. neg(true, true, true), key = "nonplayer",
                                  candidateFilters = cfFor(false, npCf) }
    end
    if #filters == 0 then
        -- Claims emptied a NON-empty selection: EMPTY array = render nothing
        -- (DriveDebuffFactory intercepts — see the header comment).
        if claimed and (boss or role or db.debuffFilterPriority or ccToken or raidOn or dispelOn
                        or db.debuffFilterNonPlayer) then
            return filters
        end
        return nil  -- nothing selected: safe fallback = show all
    end
    return filters
end

-- Public facade over BuildDirectDebuffFilters for the Aura Designer's debuff
-- category groups (C1). The AD factory builds a facade db table from a group's
-- selection (directDebuffShowAll=false + the flat debuffFilter*/debuffMaxDuration*
-- keys) and calls this — the records come out byte-identical to a row configured
-- the same way. The AD path must NEVER pass `claimed` (claims derive FROM the AD
-- groups; feeding them back would be circular — row → claims → AD groups → this
-- facade, claim-free, is the whole chain). `claimed` exists for the ROW call
-- sites in DriveDebuffFactory only.
function DF:BuildDebuffFilterRecords(dbLike, claimed)
    return BuildDirectDebuffFilters(dbLike, claimed)
end

-- Build defensive filter table (BIG_DEFENSIVE + EXTERNAL_DEFENSIVE, nil if unavailable)
-- Assigned to the forward-declared local at the top of the file so it is
-- visible to code defined above this point.
function BuildDirectDefensiveFilters()
    if cachedDefensiveFilters then return cachedDefensiveFilters end
    local filters = {}
    if AuraFilters.BigDefensive then filters[#filters + 1] = "HELPFUL|" .. AuraFilters.BigDefensive end
    if AuraFilters.ExternalDefensive then filters[#filters + 1] = "HELPFUL|" .. AuraFilters.ExternalDefensive end
    if #filters == 0 then return nil end
    cachedDefensiveFilters = filters
    return cachedDefensiveFilters
end

-- Rebuild cached filter tables from current settings (per mode)
-- (Debuff filters are not cached — the debuff driver builds them fresh.)
function DF:RebuildDirectFilterStrings()
    local partyDb = DF:GetDB("party")
    local raidDb = DF:GetDB("raid")
    if partyDb then
        cachedPartyBuffFilters = BuildDirectBuffFilters(partyDb)
    end
    if raidDb then
        cachedRaidBuffFilters = BuildDirectBuffFilters(raidDb)
    end
    -- Defensive and dispel are mode-independent, clear to rebuild on next use
    cachedDefensiveFilters = nil

end

-- ============================================================
-- HOOK BLIZZARD'S COMPACT RAID FRAMES
-- ============================================================

-- ============================================================
-- EVENT FRAME FOR PROACTIVE UPDATES
-- ============================================================

-- (Removed) ApplyBlizzardFrameSettings — the login/roster stamp of Blizzard's
-- raidFramesDispelIndicatorType CVar from _blizzDispelIndicator. No GUI has
-- written that key since v4.3.4 (the dropdown writes dispelOverlayDispelType,
-- consumed only by DF's own overlay), so the stamp just re-imposed a frozen
-- value on Blizzard's frames every login. The key is stripped in Core.lua's
-- v5 legacy-aura cleanup.
-- DELIBERATE: this frame survives the removal above solely to feed the roster
-- diagnostics counter (/dfroster) — it tallies how many GROUP_ROSTER_UPDATE
-- handlers fire per roster change across the addon. No render work happens here.
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "GROUP_ROSTER_UPDATE" then
        if DF.RosterDebugEvent then DF:RosterDebugEvent("Auras.lua(blizz):GROUP_ROSTER_UPDATE") end
    end
end)

-- ============================================================
-- BUFF FACTORY BRIDGE
-- Routes the buff ROW through DF.AuraContainer (WoW 12.1 native aura widgets).
-- The container renders and self-updates; the drive below only keeps its
-- config current (build-once, sig-gated).
-- ============================================================

-- Is the factory buff path active for this frame right now? Excludes test mode:
-- the test drives (TestMode.lua) call DriveBuffFactory themselves with the test
-- provider, so the live update path must not double-drive.
function DF:UseFactoryForBuffs(frame, db)
    return DF.AuraContainer and DF.AuraContainer.IsSupported()
        and not (DF.testMode or DF.raidTestMode)
        and not DF:MemTestDisabled("enableAuras")
end

-- GUI-facing predicate: does the factory own the buff row for this mode's db? Unlike
-- UseFactoryForBuffs (the render gate, which also excludes test mode), this must NOT flip in
-- test mode — else "blocked" overlays would wrongly lift while previewing. Used by GUI when().
function DF:FactoryOwnsBuffRow(db)
    return (DF.AuraContainer and DF.AuraContainer.IsSupported()) or false
end

-- Curated atlas glyphs for the Aura Designer Expiry Alert.
-- Dropdowns display L[name] and store the KEY (never the label); the formatter
-- resolves key -> atlas at build time. Order = dropdown order; entry 1 is the
-- default. ⚠ EVERY atlas name here is UNVERIFIED against the live client — vet
-- each one in the atlas browser (Debug/AtlasBrowser.lua) before shipping.
DF.ExpiryAlertGlyphs = {
    { key = "WARNING",      atlas = "services-icon-warning",      name = "Warning Sign" },
    { key = "PING_WARNING", atlas = "Ping_Marker_Icon_Warning",   name = "Warning Ping" },
    { key = "PING_ATTACK",  atlas = "Ping_Marker_Icon_Attack",    name = "Attack Ping" },
    { key = "RED_X",        atlas = "UI-LFG-DeclineMark",         name = "Red X" },
    { key = "EXCLAMATION",  atlas = "QuestNormal",                name = "Exclamation Mark" },
    { key = "CLOCK",        atlas = "auctionhouse-icon-clock",    name = "Clock" },
    { key = "STAR",         atlas = "auctionhouse-icon-favorite", name = "Star" },
}

-- Expiry BORDER mode art: white-mask frame TGAs, revealed below the alert threshold via a |T
-- band and vertex-tinted (0-255) so one asset serves any colour. A scaled bitmap can't vary
-- its line weight, so THICKNESS is three separate arts (same 64px sheet, different band px).
-- NOT a glyph — Border is its own alert mode (own size/inset/colour/thickness controls).
local EXPIRE_BORDER_TEXSIZE = 64
local EXPIRE_BORDER_TEXTURES = {
    THIN   = "Interface\\AddOns\\DandersFrames\\Media\\DF_ExpireBorder_Thin",
    MEDIUM = "Interface\\AddOns\\DandersFrames\\Media\\DF_ExpireBorder",
    THICK  = "Interface\\AddOns\\DandersFrames\\Media\\DF_ExpireBorder_Thick",
    -- FILL = a solid 50%-alpha wash (not a frame) — same |T reveal, so the expiring
    -- overlay becomes a TINT over the icon instead of an outline. The whole pipeline is
    -- texture-agnostic, so this is just another "style" of the border overlay.
    FILL   = "Interface\\AddOns\\DandersFrames\\Media\\DF_ExpireBorder_Fill",
}
local function borderTexture(thickness) return EXPIRE_BORDER_TEXTURES[thickness] or EXPIRE_BORDER_TEXTURES.MEDIUM end

-- Resolve a glyph key -> its entry (atlas OR texture). Unknown/missing keys fall back to
-- entry 1 so a stale profile value still renders SOMETHING rather than a broken escape.
function DF:GetExpiryAlertGlyph(key)
    local list = DF.ExpiryAlertGlyphs
    for i = 1, #list do
        if list[i].key == key then return list[i] end
    end
    return list[1]
end

-- Cache-key token for a glyph: its atlas name (uniquely identifies the art). Used only to
-- key the formatter cache.
function DF:GetExpiryAlertAtlas(key)
    return DF:GetExpiryAlertGlyph(key).atlas
end

-- SINGLE source for the inline glyph escape, shared by the live alert band (element + inline
-- prefix) and the editor dropdown/preview so none can drift. `size` bakes into the escape —
-- the caller treats an alert change as structural.
function DF:GetExpiryAlertGlyphEscape(key, size)
    local gl = DF:GetExpiryAlertGlyph(key)
    local s = math.floor(tonumber(size) or 16)
    if s < 1 then s = 1 end
    return "|A:" .. tostring(gl.atlas) .. ":" .. s .. ":" .. s .. "|a"
end

-- Sanitize user alert text for use as a NumericRuleFormatter band format string.
-- Rule: '%' doubles to '%%' (the band format is printf-style — a bare % corrupts
-- it), control characters strip, '|' passes through UNTOUCHED (colour |c and
-- texture |T / |A escapes are legitimate user input here), no length cap.
local function SanitizeAlertText(text)
    if type(text) ~= "string" then return "" end
    return (text:gsub("%%", "%%%%"):gsub("[%z\1-\31\127]", ""))
end

-- Alert part of a duration formatKey. The native formatter is bind-frozen
-- (SetDurationText binds once per slot), so EVERY alert change is STRUCTURAL and
-- must move the slot signature -> Rebuild. Used by the Aura Designer factory
-- (its expiry-alert struct sigs append this).
function DF:GetExpiryAlertFmtKey(mode, threshold, text, glyphKey)
    if mode ~= "TEXT" and mode ~= "GLYPH" and mode ~= "BORDER" and mode ~= "TINT" then return "" end
    -- BORDER/TINT identity (colour mode / colour / inset / size / thickness) rides the struct
    -- key in DF.Expiration:StructSig, so the base key here is just mode + threshold.
    local tail = (mode == "GLYPH" and tostring(glyphKey or ""))
        or (mode == "TEXT" and tostring(text or "")) or ""
    return ":X" .. mode .. ":" .. tostring(tonumber(threshold) or 5) .. ":" .. tail
end

-- Display payload for one Expiry Alert band/preview: the sized |A atlas escape
-- (GLYPH) or the sanitized custom text, red-wrapped unless the user's own |c
-- escape already colours it (TEXT; empty text = ""). Shared by the alert-element
-- formatter below and the AD editor's canvas preview so the two can never drift.
function DF:GetExpiryAlertPayload(mode, text, glyphKey, size)
    if mode == "GLYPH" then
        return DF:GetExpiryAlertGlyphEscape(glyphKey, tonumber(size) or 14)
    end
    local txt = SanitizeAlertText(text)
    if txt ~= "" and not txt:find("|c", 1, true) then txt = "|cffff0000" .. txt .. "|r" end
    return txt
end

-- Duration-text formatters for the factory row, by format key:
--   NUMBER -> bare seconds (45), then "2m"/"1h"   (NumericRuleFormatter)
--   SHORT  -> "45s" / "2m" / "1h"                 (SecondsFormatter, OneLetter)
--   FULL   -> "45 Seconds" / "2 Minutes"          (SecondsFormatter, None = full word)
-- Blizzard's own default is SHORT-like; DF's legacy rows showed NUMBER. Built once per
-- format and cached (Blizzard securecopies the options table, so one object per format is fine).
-- {r,g,b} (0-1) -> "rrggbb" hex for the |cff escape.
local function colorToHex(c)
    local function b255(x) return math.max(0, math.min(255, math.floor((tonumber(x) or 1) * 255 + 0.5))) end
    return string.format("%02x%02x%02x", b255(c.r or c[1]), b255(c.g or c[2]), b255(c.b or c[3]))
end

-- Expiry BORDER/TINT escape: the full |T inline-texture form tinting the white-mask TGA to
-- (r,g,b from `hex`) at `width` x `height` px. |T wants HEIGHT then WIDTH:
-- path:h:w:offX:offY:texW:texH:l:r:t:b:R:G:B — trailing vertex-colour args (0-255) do the tint,
-- texW/texH + full texel range from the texture size. The art is a 64x64 square: h==w gives an
-- even frame/wash (icons); h~=w stretches it — a solid TINT fills any rectangle cleanly, a
-- frame would distort, so only TINT is ever fed a non-square rect. [LIVE 2026-07-20] Defined
-- after colorToHex so the public wrapper below can reach it (a local isn't in scope earlier).
local function borderEscapeHex(width, height, hex, texture)
    local ts = EXPIRE_BORDER_TEXSIZE
    local r = tonumber(hex:sub(1, 2), 16) or 255
    local g = tonumber(hex:sub(3, 4), 16) or 255
    local b = tonumber(hex:sub(5, 6), 16) or 255
    return "|T" .. texture .. ":" .. height .. ":" .. width .. ":0:0:" .. ts .. ":" .. ts
        .. ":0:" .. ts .. ":0:" .. ts .. ":" .. r .. ":" .. g .. ":" .. b .. "|t"
end


-- Account-wide colour-by-time breakpoints (editable on the Colours page). Resolve to a
-- threshold-DESCENDING list of { threshold, hex } so the first match (highest threshold <=
-- remaining) wins. Falls back to the shipped low ladder if unset/malformed, and always ends
-- in a threshold-0 base band.
-- Vivid traffic-light (keep in sync with Config.lua durationColorByTimeBreakpoints).
-- Both defaults draw the SAME bar — even quarters: 9/6/3 on the seconds strip's 12s
-- preview domain == 75/50/25 in percent, so flipping the Colours-page tabs shows one
-- identical default ramp.
local DEFAULT_DURATION_BREAKPOINTS = {
    { threshold = 9, hex = "5fe05f" }, { threshold = 6, hex = "ffd23d" },
    { threshold = 3, hex = "ff9838" }, { threshold = 0, hex = "f75555" },
}
-- PERCENT scale (keep in sync with Config.lua durationColorByPercentBreakpoints).
local DEFAULT_PERCENT_BREAKPOINTS = {
    { threshold = 75, hex = "5fe05f" }, { threshold = 50, hex = "ffd23d" },
    { threshold = 25, hex = "ff9838" }, { threshold = 0,  hex = "f75555" },
}
-- TWO account-wide ramps, ONE PER UNIT — seconds remaining and percent of duration —
-- shared by EVERY colour-by-time consumer: the duration text AND the expiry border/tint
-- reveal. "Time is running out" is one idea, so it gets one set of colours; a consumer
-- keeps only an on/off, and which ramp it reads follows from its unit.
--   * Duration TEXT has no threshold, so its unit is account-wide (durationTextColorScale)
--     and it also carries the blend dial (only text can blend — |T escapes ignore the
--     vertex colour a curve writes).
--   * The expiry reveal's unit is PER INDICATOR (expiryAlertThresholdUnit): its bands and
--     its Alert Below threshold are ONE formatter sampled against ONE property, so they
--     must share a unit — but nothing makes two different indicators share one. Both ramps
--     are therefore live at once: a seconds reveal reads the seconds ramp, a percent
--     reveal the percent one.
local COLOR_SCALES = {
    TEXT_SECONDS   = { key = "durationColorByTimeBreakpoints",            fallback = DEFAULT_DURATION_BREAKPOINTS },
    TEXT_PERCENT   = { key = "durationColorByPercentBreakpoints",         fallback = DEFAULT_PERCENT_BREAKPOINTS  },
}
-- The ramp for a unit ("SECONDS" | "PERCENT"). One resolver so every consumer, cache key
-- and struct sig maps a unit to a ramp the same way.
function DF:GetDurationRampKey(unit)
    return (unit == "PERCENT") and "TEXT_PERCENT" or "TEXT_SECONDS"
end
-- Account-wide reading of each ramp. Text carries both dials; the border/tint is stepped
-- by construction (its |T escapes ignore the vertex colour a curve writes) and so carries
-- only a scale.
function DF:GetDurationTextColorScale()
    local g = DF.GetGlobalDB and DF:GetGlobalDB()
    return (g and g.durationTextColorScale == "SECONDS") and "SECONDS" or "PERCENT"
end
function DF:IsDurationTextColorSmooth()
    local g = DF.GetGlobalDB and DF:GetGlobalDB()
    return not (g and g.durationTextColorSmooth == false)
end
-- (Removed 2026-07-24: DF:GetDurationBorderColorScale / GetDurationBorderScaleKey and the
-- account-wide durationBorderColorScale behind them. The expiry reveal's unit is now a
-- PER-INDICATOR setting — DF.Expiration:Unit(cfg) — so one global could not express it:
-- a glyph revealing at 5 seconds and a border revealing at 30% are both legitimate at the
-- same time. Use DF:GetDurationRampKey(DF.Expiration:Unit(cfg)) to reach its ramp.)
-- ☠ MEMOISED PER SCALE, AND THE RETURNED LIST IS SHARED — do not mutate it.
-- Every call rebuilt the whole ladder: one table for the list, one table per
-- breakpoint, and a colorToHex string per breakpoint — from account-wide config
-- that only changes on a Colours-page edit. It runs per aura per tick and was
-- 6.6% of all trash-fight allocation.
--
-- Verified before sharing: all five call sites only READ (ipairs, indexed reads,
-- breakpointsSig) — none writes into the list or into an entry. A future caller
-- that needs to mutate must copy first.
--
-- Keyed on the resolved DEF TABLE rather than the scale string, so an unrecognised
-- scale (which falls back to TEXT_SECONDS) shares that entry instead of growing a
-- duplicate under its own name.
--
-- Invalidation is the one that already exists: DF:InvalidateDurationFormatters
-- wipes this next to the formatter and curve caches, and its own comment already
-- makes it the required call for anything mutating these stops. Nothing new to
-- remember, and the PERCENT scale now gets cached too — GetDurationBreakpointsSig
-- only ever memoised TEXT_SECONDS.
local durationBreakpointsCache = {}
local function GetDurationColorBreakpoints(scale)
    local def = COLOR_SCALES[scale] or COLOR_SCALES.TEXT_SECONDS
    local cached = durationBreakpointsCache[def]
    if cached then return cached end
    local g = DF.GetGlobalDB and DF:GetGlobalDB()
    local raw = g and g[def.key]
    local out = {}
    if type(raw) == "table" then
        for _, bp in ipairs(raw) do
            local t = tonumber(bp and bp.threshold)
            if t and type(bp.color) == "table" then
                out[#out + 1] = { threshold = math.max(0, t), hex = colorToHex(bp.color), color = bp.color }
            end
        end
    end
    if #out == 0 then
        durationBreakpointsCache[def] = def.fallback
        return def.fallback
    end
    table.sort(out, function(a, b) return a.threshold > b.threshold end)  -- descending
    if out[#out].threshold ~= 0 then out[#out + 1] = { threshold = 0, hex = out[#out].hex, color = out[#out].color } end
    durationBreakpointsCache[def] = out
    return out
end

-- Colour hex for an absolute remaining threshold: the highest breakpoint whose threshold <= t.
local function colorHexAt(bps, t)
    for _, bp in ipairs(bps) do if t >= bp.threshold then return bp.hex end end
    return bps[#bps].hex
end

-- Stable cache signature for a breakpoints list (so an edit builds a fresh formatter).
local function breakpointsSig(bps)
    local p = {}
    for _, bp in ipairs(bps) do p[#p + 1] = bp.threshold .. ":" .. bp.hex end
    return table.concat(p, ",")
end

-- Expiry Alert (alertMode "TEXT"/"GLYPH" + alertThreshold seconds + alertText/alertAtlas):
-- extra breakpoint bands below the threshold — evaluated C-side against the SECRET
-- remaining time like everything else here; no Lua time read, works in combat.
-- ALERT-ELEMENT variant (alertElem = true, AD Expiry Alert element): the formatter IS
-- the whole output — payload band below the threshold, EMPTY band above (no countdown,
-- no colour-by-time, no hide-above; the indicator's own duration text is untouched and
-- keeps its own formatter). format/hideAboveT/colorByTime are ignored in this variant.
-- ★ BLIZZARD'S PROMOTE POINTS, and they are not the round numbers you would guess.
-- DefaultAuraDurationFormatter (Blizzard_AuraContainerShared.lua) keeps a duration in
-- each interval for 1.5x its normal range, so 90 seconds still renders as seconds and a
-- 62-minute buff still renders as minutes. Their comment explains the +1: "Curve points
-- promote on exact matches, so each point is offset by one to keep the upper whole-second
-- value in its current band."
--
-- ☠ NUMBER USED TO PROMOTE AT 60 AND 3600, i.e. 31 seconds and 30 minutes earlier than
-- the game's own frames sitting next to it. That is the whole of the "it says Number but
-- shows me minutes" report — at 61s the game says "61s" and DF said "1m". Both paths
-- below now key off these, so the plain and banded builders cannot drift apart either.
local PROMOTE_MIN  = 1 + 1.5 * SECONDS_PER_MIN    -- 91
local PROMOTE_HOUR = 1 + 1.5 * SECONDS_PER_HOUR   -- 5401

local function BuildDurationFormatter(format, hideAboveT, colorByTime, alertMode, alertThreshold, alertText, alertAtlas, alertElem, alertElemSize, alertGlyphKey)
    format = format or "NUMBER"
    local alertT
    if alertMode == "TEXT" or alertMode == "GLYPH" then
        alertT = tonumber(alertThreshold) or 5
        if alertT < 1 then alertT = 1 end
    else
        alertMode = nil
    end
    if alertElem then
        if not alertT then return nil end
        if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter and Enum and Enum.NumericRuleFormatRounding) then return nil end
        -- Payload composed by the shared helper for BOTH modes (GLYPH resolves
        -- key->atlas inside it), so the live band string and the editor-canvas
        -- preview (buildAlertPreview) can never drift.
        local payload = DF:GetExpiryAlertPayload(alertMode, alertText, alertGlyphKey, alertElemSize)
        local ok, f = pcall(function()
            local down = Enum.NumericRuleFormatRounding.Down
            local fmt = C_StringUtil.CreateNumericRuleFormatter()
            -- Two bands, emitted ascending: [0, alertT) = the payload (constant string,
            -- no numeric directive), [alertT, inf) = empty. Evaluated C-side against the
            -- SECRET remaining time — zero Lua time reads, works in combat.
            fmt:AddBreakpoint({ threshold = 0, step = 1, rounding = down, min = 1, format = payload })
            fmt:AddBreakpoint({ threshold = alertT, step = 1, rounding = down, format = "" })
            return fmt
        end)
        return ok and f or nil
    end
    -- Hide-above-threshold and/or COLOUR-BY-TIME buckets: both need per-band format
    -- strings, which only the NumericRuleFormatter has (SecondsFormatter carries none) —
    -- so SHORT/FULL are emulated with the matching unit suffix (the pre-existing
    -- hide-above tradeoff: English unit text, not locale-aware).
    --
    -- Colour-by-time: the smooth curve is NOT addon-reachable on 12.1 (see the
    -- GetDurationColorCurve tombstone below). Instead each band's format string EMBEDS a
    -- |cffRRGGBB escape; the C-side DurationTextBinding evaluates the SECRET remaining
    -- time against the breakpoints and renders the pre-coloured string — no aura read,
    -- no addon ticker, secret-safe (the DF_AuraLab-proven formatter trick). Bands are
    -- the legacy curve's colours discretised on ABSOLUTE remaining time:
    --   <5s red · 5-15s orange · 15-60s yellow · 60s+ green (fresh).
    -- (The legacy path coloured by PERCENT of total duration; a static formatter can't
    -- know the total, so absolute-seconds bands are the 12.1 equivalent.)
    if hideAboveT or colorByTime or alertT then
        if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter and Enum and Enum.NumericRuleFormatRounding) then return nil end
        -- %d throughout, matching the plain path: %.0f rounds to NEAREST, so 152s
        -- rendered "3m" and 3599s rendered "60m" one tick before flipping to "1h".
        -- (Rounding itself rides the breakpoint/component fields, not the directive.)
        local secFmt = (format == "SHORT" and "%ds") or (format == "FULL" and "%d Seconds")
                        or (format == "TIMER" and "%d") or "%d"
        local minFmt = (format == "FULL") and "%d Minutes" or "%dm"
        local hrFmt  = (format == "FULL") and "%d Hours"   or "%dh"
        local bps = colorByTime and GetDurationColorBreakpoints() or nil
        -- Blank-band start: hide-above unchanged, EXCEPT the alert region [0, alertT)
        -- always renders — an explicit alert outranks blanking, so when the user sets
        -- the alert threshold above the hide threshold the blank starts at alertT.
        local blankAt = hideAboveT
        if blankAt and alertT and alertT > blankAt then blankAt = alertT end
        local ok, f = pcall(function()
            local down = Enum.NumericRuleFormatRounding.Down
            -- ⚠ Needed by bandShape below. Without it `up` would resolve to a nil GLOBAL
            -- and the field would silently fall back to the default rounding — legal Lua
            -- that parses clean and quietly renders the wrong number.
            local up   = Enum.NumericRuleFormatRounding.Up
            local fmt = C_StringUtil.CreateNumericRuleFormatter()
            -- GLYPH alert: fixed 16px atlas escape prepended to every band that starts
            -- inside the alert region. Fixed size: the formatter is CACHED + bind-frozen
            -- while font size changes ride the LIGHTWEIGHT text update, so a font-derived
            -- size would go stale on a scale drag.
            local glyphPfx = (alertMode == "GLYPH") and (DF:GetExpiryAlertGlyphEscape(alertGlyphKey, 16) .. " ") or nil
            local cuts = {}    -- thresholds already holding a band
            local bands = {}   -- buffered: emitted ASCENDING below (the resume band
                               -- can be composed out of order; the pre-alert code
                               -- always emitted ascending, so keep that guarantee)
            -- Highest threshold <= remaining seconds wins.
            -- ☠ Seconds-shaped bands (no components) round UP — a countdown's digit
            -- means "at most this many seconds remain", so ceil gives each digit
            -- exactly one second and the text ends "3, 2, 1, gone". The old floor +
            -- min=1 pair clamped the sub-1s floor of 0 back to 1, so "1" rendered
            -- for TWO seconds (field report). Component bands keep floor at the
            -- breakpoint: their quotient rounding lives on the component itself.
            local function add(threshold, fstr, hex, components)
                if colorByTime and hex then fstr = "|cff" .. hex .. fstr .. "|r" end
                if glyphPfx and threshold < alertT then fstr = glyphPfx .. fstr end
                cuts[threshold] = true
                bands[#bands + 1] = { threshold = threshold, step = 1,
                                      rounding = components and down or up,
                                      min = 1, format = fstr, components = components }
            end
            if alertMode == "TEXT" then
                -- The whole sub-threshold region shows the custom text (countdown
                -- replaced). Red unless the user's own |c escape already colours it.
                -- Empty text = literal: a blank sub-threshold band.
                local txt = SanitizeAlertText(alertText)
                if txt ~= "" and not txt:find("|c", 1, true) then txt = "|cffff0000" .. txt .. "|r" end
                cuts[0] = true
                bands[#bands + 1] = { threshold = 0, step = 1, rounding = down, min = 1, format = txt }
            end
            -- Cut points = the configured colour thresholds (when colouring) UNION the format
            -- transitions (60s -> minutes, 3600s -> hours) UNION the base band at 0 UNION the
            -- alert resume threshold. Each band takes the colour of the highest breakpoint <=
            -- it and the number format of its range, so a colour band spanning a format
            -- boundary is split (same colour, m/h format). The blank band (hide-above, pushed
            -- up to alertT by an overlapping alert) drops every cut at/above its start — they
            -- would shadow it. TEXT alert: no cuts inside [0, alertT) — the custom text band
            -- (already buffered above) owns that whole region outright.
            local wanted = { [0] = true }
            if colorByTime then for _, bp in ipairs(bps) do wanted[bp.threshold] = true end end
            if not blankAt then wanted[60] = true; wanted[3600] = true end
            -- Resume band AT the alert threshold: above it the normal (un-alerted) format
            -- takes over. At 60+ the minute band IS the resume band.
            if alertT and alertT < 60 then wanted[alertT] = true end
            local sorted = {}
            for t in pairs(wanted) do
                if not (blankAt and t >= blankAt)
                    and not (alertMode == "TEXT" and t < alertT)
                    and not cuts[t] then
                    sorted[#sorted + 1] = t
                end
            end
            table.sort(sorted)   -- ascending
            -- ☠ EVERY FORMAT NEEDS A SHAPE HERE, not just the ones that had one. This
            -- branch owns hide-above and colour-by-time, so a format missing from it does
            -- not fail loudly — it silently renders as NUMBER the moment either is
            -- switched on, which reads as "the format setting stopped working".
            -- ⚠ The thresholds are PROMOTE_MIN / PROMOTE_HOUR, not 60 / 3600, so a band
            -- straddling 61-90s still prints seconds exactly as the plain path does.
            -- Using the round numbers here was how the two builders disagreed.
            local function bandShape(t)
                if format == "TIMER" then
                    if t >= PROMOTE_HOUR then return "%dh", { { div = 3600 } } end
                    if t >= PROMOTE_MIN  then return "%d:%02d", { { div = 60 }, { mod = 60 } } end
                    return secFmt, nil
                end
                -- Quotient rounds UP here too, matching the plain path and the game (see
                -- the NUMBER branch). TIMER above is deliberately excluded: its minute
                -- component is the left half of "2:32" and must truncate, or 2m32s would
                -- render "3:32".
                if t >= PROMOTE_HOUR then return hrFmt,  { { div = 3600, rounding = up } } end
                if t >= PROMOTE_MIN  then return minFmt, { { div = 60,   rounding = up } } end
                return secFmt, nil
            end
            for _, t in ipairs(sorted) do
                local hex = colorByTime and colorHexAt(bps, t) or nil
                local f, comps = bandShape(t)
                add(t, f, hex, comps)
            end
            if blankAt then
                bands[#bands + 1] = { threshold = blankAt, step = 1, rounding = down, format = "" }
            end
            table.sort(bands, function(a, b) return a.threshold < b.threshold end)
            for i = 1, #bands do fmt:AddBreakpoint(bands[i]) end
            return fmt
        end)
        return ok and f or nil
    end
    -- TIMER — "5:32". The only format needing a SECOND component: `div` yields the
    -- minutes, `mod` the leftover seconds. Nothing in DF used `mod` before this, and no
    -- other format here can express a clock without it.
    -- ☠ ABOVE AN HOUR IT STOPS BEING A CLOCK. An h:mm reading of "1:02" is
    -- indistinguishable from 1m02s, which is worse than useless on a frame showing both,
    -- so past the hour it hands off to "1h" — the same shape the SecondsFormatter path
    -- uses, and the same call the one 12.1 addon shipping this format makes.
    if format == "TIMER" then
        if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter and Enum and Enum.NumericRuleFormatRounding) then return nil end
        local ok, f = pcall(function()
            local down = Enum.NumericRuleFormatRounding.Down
            local up   = Enum.NumericRuleFormatRounding.Up
            local fmt = C_StringUtil.CreateNumericRuleFormatter()
            -- Seconds band CEILS (see the NUMBER branch): the countdown must end
            -- "3, 2, 1, gone", and floor + min=1 held the "1" for two seconds.
            fmt:AddBreakpoint({ threshold = 0,    step = 1, rounding = up, min = 1, format = "%d" })
            fmt:AddBreakpoint({ threshold = PROMOTE_MIN, step = 1, rounding = down, format = "%d:%02d",
                                components = { { div = 60 }, { mod = 60 } } })
            fmt:AddBreakpoint({ threshold = PROMOTE_HOUR, step = 1, rounding = down, format = "%dh",
                                components = { { div = 3600 } } })
            return fmt
        end)
        return ok and f or nil
    end
    -- NUMBER — "45" -> "2m" -> "1h". Blizzard's DefaultAuraDurationFormatter WITHOUT the
    -- unit letter, which is the only reason it cannot simply BE that formatter: the
    -- SecondsFormatterAbbreviation enum has no suffix-less mode (None spells the word
    -- out, OneLetter gives "45s"), so a rule formatter is the only way to get a bare
    -- number. Everything else about it now matches Blizzard — see PROMOTE_MIN.
    if format == "NUMBER" then
        if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter and Enum and Enum.NumericRuleFormatRounding) then return nil end
        local ok, f = pcall(function()
            local down = Enum.NumericRuleFormatRounding.Down
            local up   = Enum.NumericRuleFormatRounding.Up
            local fmt = C_StringUtil.CreateNumericRuleFormatter()
            -- ☠ Seconds band CEILS, deliberately (field report: "3, 2, 1, 1, gone").
            -- A countdown digit means "at most this many seconds remain": ceil shows
            -- each digit for exactly one second and the text vanishes AT expiry. The
            -- old floor ("45.6 is 45, like the game") + min=1 clamp made the sub-1s
            -- floor of 0 render as a SECOND "1" — the lingering last second. min=1
            -- stays as a guard against an exact-0.0 sample flashing "0".
            fmt:AddBreakpoint({ threshold = 0, step = 1, rounding = up, min = 1, format = "%d" })
            -- ☠ THE QUOTIENT ROUNDS UP, and that is Blizzard's behaviour, not a preference.
            -- Their formatter sets SetCanRoundUpLastUnit(true), so 2m32s reads "3m" and
            -- 1h03m reads "63m" -- odd-looking, but it is what the game's own frames show,
            -- and Units (a real SecondsFormatter) already did it. Standard truncated, so
            -- the two disagreed at every duration with a fractional minute: "2m" against
            -- "3m" on the same buff, which is the inconsistency this closes.
            -- ⚠ Rounding on the COMPONENT is the only place that can affect the quotient --
            -- breakpoint-level rounding applies to the input SECONDS, before the divide.
            -- Whether the validator honours it is unproven (the one shipping 12.1 addon
            -- using this API puts step/rounding only at breakpoint level), so it has a
            -- visible tell: if the Duration Format example still reads "2m · 62m" against
            -- Units' "3m · 63m", it was ignored and this needs another approach.
            fmt:AddBreakpoint({ threshold = PROMOTE_MIN,  step = 1, rounding = down, min = 1, format = "%dm",
                                components = { { div = 60, rounding = up } } })
            fmt:AddBreakpoint({ threshold = PROMOTE_HOUR, step = 1, rounding = down, min = 1, format = "%dh",
                                components = { { div = 3600, rounding = up } } })
            return fmt
        end)
        return ok and f or nil
    end
    -- SHORT / FULL: Blizzard's SecondsFormatter, differing only in the abbreviation.
    if not (C_StringUtil and C_StringUtil.CreateSecondsFormatter and C_CurveUtil and Enum) then return nil end
    local abbrev = (format == "FULL") and Enum.SecondsFormatterAbbreviation.None
                    or Enum.SecondsFormatterAbbreviation.OneLetter
    local ok, f = pcall(function()
        local fmt = C_StringUtil.CreateSecondsFormatter()
        local mult = 1.5
        local curve = C_CurveUtil.CreateCurve()
        curve:AddPoint(1 + mult * SECONDS_PER_MIN,  Enum.SecondsFormatterInterval.Minutes)
        curve:AddPoint(1 + mult * SECONDS_PER_HOUR, Enum.SecondsFormatterInterval.Hours)
        curve:AddPoint(1 + mult * SECONDS_PER_DAY,  Enum.SecondsFormatterInterval.Days)
        fmt:SetDefaultAbbreviation(abbrev)
        -- ☠ Rounding is RoundUp, a DELIBERATE break from Blizzard's aura formatter
        -- (theirs sets Truncate; an earlier cut copied that for parity, so 44.6s read
        -- "44s" like the game). Reversed with the countdown fix: every DF seconds
        -- display now ceils — a digit means "at most this many seconds remain", each
        -- digit holds exactly one second and the text ends "3s, 2s, 1s, gone" instead
        -- of Truncate's lingering last digit. This also keeps SHORT/FULL agreeing
        -- with NUMBER at every instant (mixed formats on one frame never differ by 1).
        -- Guarded: the setters are newer than the type.
        if fmt.SetRounding and Enum.SecondsFormatterRounding then
            fmt:SetRounding(Enum.SecondsFormatterRounding.RoundUp)
        end
        if fmt.SetCanRoundUpLastUnit then fmt:SetCanRoundUpLastUnit(true) end
        fmt:SetMinInterval(Enum.SecondsFormatterInterval.Seconds)
        fmt:SetMaxIntervalCurve(curve)
        fmt:SetDesiredUnitCount(1)
        -- SHORT: strip the space between number and unit ("45 s" -> "45s"; the default
        -- Preserve mode is why Short looked MORE spaced out than Number). Locale-aware:
        -- deDE/ruRU keep their space by design. FULL keeps the space ("45 Seconds").
        if format == "SHORT" and fmt.SetStripIntervalWhitespace
            and Enum.SecondsFormatterIntervalWhitespace then
            fmt:SetStripIntervalWhitespace(Enum.SecondsFormatterIntervalWhitespace.Strip)
        end
        return fmt
    end)
    return ok and f or nil
end

local durationFormatterCache = {}
local durationBreakpointsSigCache   -- memoized DF:GetDurationBreakpointsSig() string
-- Drop cached coloured formatters after a Colours-page breakpoint edit. The new formatters
-- rebind on the InvalidateAuraLayout re-drive the edit already triggers. (Uncoloured entries
-- are unaffected but wiping all is simplest and cheap — they rebuild on next demand.)
-- Anything that mutates durationColorByTimeBreakpoints MUST call this, or the memoized
-- signature below keeps the old formatter/row signatures alive.
function DF:InvalidateDurationFormatters()
    wipe(durationFormatterCache)
    durationBreakpointsSigCache = nil
    -- The resolved ladders themselves are cached now (see GetDurationColorBreakpoints);
    -- without this the memoized signature would rebuild from stale stops and every
    -- consumer would keep painting the old ramp.
    wipe(durationBreakpointsCache)
    -- Colour curves are built from the same stops (DF:GetDurationColorSpec) — a stop edit
    -- must drop them too or the cached curve keeps painting the old ramp.
    if DF._wipeDurationCurves then DF:_wipeDurationCurves() end
end
local function GetDurationFormatter(format, hideAboveT, colorByTime, alertMode, alertThreshold, alertText, alertGlyphKey)
    format = format or "NUMBER"
    local key = format .. "|" .. tostring(hideAboveT or "") .. (colorByTime and "|C" or "")
    if colorByTime then key = key .. "|" .. DF:GetDurationBreakpointsSig() end
    local alertAtlas
    if alertMode == "TEXT" or alertMode == "GLYPH" then
        if alertMode == "GLYPH" then alertAtlas = DF:GetExpiryAlertAtlas(alertGlyphKey) end
        -- Distinct alert configs -> distinct cached formatters (text/atlas are part
        -- of the band strings, so they must key the cache too).
        key = key .. "|X" .. alertMode .. ":" .. tostring(tonumber(alertThreshold) or 5) .. ":"
                  .. (alertAtlas or tostring(alertText or ""))
    end
    if durationFormatterCache[key] == nil then
        durationFormatterCache[key] = BuildDurationFormatter(format, hideAboveT, colorByTime, alertMode, alertThreshold, alertText, alertAtlas) or false
    end
    return durationFormatterCache[key] or nil
end

-- ★ WHAT EACH FORMAT PRINTS — shown under the Duration Format dropdown.
--
-- Three samples, straddling BOTH promote points (45s · 2m32s · 1h02m), because a single
-- value cannot show a roll-up and the roll-up is the part people get wrong: "Standard
-- (45)" would have explained nothing about the report that started this.
--
-- ☠ HAND-MAINTAINED, AND DELIBERATELY IN THIS FILE. NumericRuleFormatter exposes no
-- Format method — only Add/Set/GetBreakpoints — so NUMBER, TIMER and PERCENT can only be
-- evaluated by the C-side duration binding, never from Lua. Their strings therefore
-- cannot be generated and can only be kept true by hand, so they live against the
-- breakpoints they describe rather than in the options pages. Change a breakpoint above,
-- change these.
-- These three are safe to hardcode in English: their unit suffixes come from DF's own
-- format strings ("%dm"/"%dh"), which are not locale-aware in any locale.
local DURATION_FORMAT_EXAMPLES = {
    NUMBER          = "45 · 2m · 62m",
    TIMER           = "45 · 2:32 · 62:05",
    PERCENT         = "75%",
    SECONDS_PERCENT = "45s (75%)",
    -- Fallbacks only — SHORT/FULL are generated live below, and FULL takes a single
    -- sample so its spelled-out unit fits beside the caption on the narrow bar card.
    SHORT           = "45s · 3m · 63m",
    FULL            = "45 Seconds",
}

-- ⚠ SHORT and FULL are NOT hardcoded. They render through a SecondsFormatter, whose
-- output IS locale-aware (deDE keeps its space, FULL spells the unit out in the client
-- language), so an English constant would be wrong for most users. SecondsFormatter has
-- a Format method — the rule formatters do not — so theirs comes from the REAL formatter
-- and can neither drift from the code nor be wrong in a locale.
local EXAMPLE_SAMPLES = { 45, 152, 3725 }
-- ⚠ FULL SPELLS THE UNIT OUT, and it is offered ONLY on the Aura Designer bar card —
-- the narrowest surface carrying this control. Three samples clipped there ("45 Seconds ·
-- 3 Minutes · 6…"); two measure close enough to the caption that they would probably clip
-- too, so it gets one. That is not a real loss: Full's only difference from Units is that
-- it spells the unit out, which one sample shows, and Units sits directly above it in the
-- same dropdown already demonstrating the roll-up.
local EXAMPLE_SAMPLES_VERBOSE = { 45 }

function DF:GetDurationFormatExample(format)
    format = format or "NUMBER"
    if format == "SHORT" or format == "FULL" then
        local f = GetDurationFormatter(format, nil, false)
        if f and f.Format then
            local samples = (format == "FULL") and EXAMPLE_SAMPLES_VERBOSE or EXAMPLE_SAMPLES
            local parts, ok = {}, true
            for i = 1, #samples do
                local got, s = pcall(f.Format, f, samples[i])
                if not (got and type(s) == "string" and s ~= "") then ok = false break end
                parts[i] = s
            end
            if ok then return table.concat(parts, " · ") end
        end
    end
    return DURATION_FORMAT_EXAMPLES[format]
end

-- The account-wide colour-by-time breakpoints signature. Folded into the STRUCTURAL
-- duration format keys (dur.formatKey here + the AD durationFmtKey) so a breakpoint edit
-- changes the row signature and forces a Rebuild — SetDurationText binds the formatter
-- ONCE per slot, so ApplyStyle alone can't swap in the recoloured formatter.
-- MEMOIZED: the AD struct sigs call this per indicator per UNIT_AURA inside syncPlacedPool,
-- a walk that is deliberately allocation-free — recomputing (GetGlobalDB scan + sort +
-- concat) there would churn garbage every aura event. The cache clears on
-- InvalidateDurationFormatters, which every breakpoint edit already fires.
function DF:GetDurationBreakpointsSig(scale)
    scale = scale or "TEXT_SECONDS"
    if scale ~= "TEXT_SECONDS" then return breakpointsSig(GetDurationColorBreakpoints(scale)) end
    if not durationBreakpointsSigCache then
        durationBreakpointsSigCache = breakpointsSig(GetDurationColorBreakpoints("TEXT_SECONDS"))
    end
    return durationBreakpointsSigCache
end

-- ============================================================
-- COLOUR-BY-TIME MODES (12.1 colour curve, build 68914+)
-- ============================================================
-- 68914 restored options.textColor on SetDurationText — it now forwards
-- SetTextColorCurve(curve, PROPERTY); the 68569 wrapper dropped the property arg, which
-- is the whole reason the curve was dead and colour shipped as |c escapes baked into the
-- formatter's bands. With the curve reachable, duration TEXT gets two independent dials:
--
--   INTERPOLATION  Linear = blends between stops · Step = snaps to the stop at or below
--   SCALE          seconds remaining · percent of total remaining
--
-- Probe-verified on 68914 (/al smoothcolor, readback in the lab log):
--   * Linear interpolates linearly in RGB and CLAMPS at both ends (below the first stop
--     and above the last) — it never falls to zero/black outside the authored range.
--   * Step FLOORS: x=2.5 yields the x=0 colour, x=7.5 the x=5 colour. That is exactly
--     DF's own "highest threshold <= remaining wins" rule, so STEP_SECONDS reproduces the
--     legacy bucket look with no compensation (no doubled points at band ends).
--   * RemainingPercent is expressed 0-100 (probe row G), matching the stops as stored.
--   * The curve writes the FONTSTRING's vertex colour, which inline |T textures IGNORE
--     (they keep their own baked vertex args). The expiry border/tint reveal is a |T
--     escape, so it can never blend — it stays stepped, and seconds-only because a static
--     formatter cannot know an aura's total duration. That asymmetry is a hard engine
--     ceiling, not a policy choice.
--   * |c escapes still beat the curve, so the legacy bucket path and a curve must never
--     both be armed on one fontstring (see the mutual exclusion in the row builders).
local DURATION_COLOR_MODES = {
    OFF            = { },
    SMOOTH_PERCENT = { scale = "TEXT_PERCENT", interp = "Linear" },
    SMOOTH_SECONDS = { scale = "TEXT_SECONDS", interp = "Linear" },
    STEP_PERCENT   = { scale = "TEXT_PERCENT", interp = "Step"   },
    STEP_SECONDS   = { scale = "TEXT_SECONDS", interp = "Step"   },
}
-- Curves need C_CurveUtil + the property enum; without them (pre-68914) every non-OFF
-- mode degrades to the legacy seconds BUCKETS, which is the only colour the old
-- SetDurationText could express.
local function curvesAvailable()
    return (C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor
        and Enum and Enum.DurationTextBindingProperty and Enum.LuaCurveType) and true or false
end

-- A consumer's stored value is a plain ON/OFF; the MODE it resolves to is composed from
-- the account-wide dials, so every text consumer reads the ramp the same way and the
-- Colours page is the single place that decides how. (A stored mode STRING is still
-- honoured: an in-development profile may hold one, and "OFF" must keep meaning off.)
function DF:ResolveDurationColorMode(raw)
    if raw == false or raw == nil then return "OFF" end
    -- A stored MODE STRING means only "on". It is never honoured as a mode: the dials are
    -- account-wide by design, and a per-consumer mode would silently opt that consumer out
    -- of them. Strings exist because a development build briefly stored the mode here, and
    -- an Aura Designer indicator that picked up "STEP_SECONDS" that way rendered stepped
    -- seconds no matter what the Colours page said. Treating them as plain ON self-heals
    -- those profiles without touching stored data.
    if type(raw) == "string" and (raw == "OFF" or not DURATION_COLOR_MODES[raw]) then
        return "OFF"
    end
    local scale = (DF:GetDurationTextColorScale() == "SECONDS") and "SECONDS" or "PERCENT"
    return (DF:IsDurationTextColorSmooth() and "SMOOTH_" or "STEP_") .. scale
end

-- Colour spec for a mode: { curve, property } to hand to SetDurationText's textColor, or
-- `buckets = true` for the legacy |c-escape formatter path. Cached per mode (the curve is
-- a userdata we must keep alive anyway) and invalidated with the formatters, so a
-- Colours-page stop edit rebuilds it.
local durationCurveCache = {}
local function hexToColor(hex)
    return CreateColor((tonumber(hex:sub(1, 2), 16) or 255) / 255,
                       (tonumber(hex:sub(3, 4), 16) or 255) / 255,
                       (tonumber(hex:sub(5, 6), 16) or 255) / 255, 1)
end
function DF:GetDurationColorSpec(rawOrMode)
    local mode = DF:ResolveDurationColorMode(rawOrMode)
    if mode == "OFF" then return nil end
    local cached = durationCurveCache[mode]
    if cached ~= nil then return cached or nil end
    local def = DURATION_COLOR_MODES[mode]
    -- Pre-68914: no curve -> the legacy seconds buckets are the only expressible colour.
    if not curvesAvailable() then
        durationCurveCache[mode] = { buckets = true }
        return durationCurveCache[mode]
    end
    local ok, spec = pcall(function()
        local curve = C_CurveUtil.CreateColorCurve()
        curve:SetType(Enum.LuaCurveType[def.interp])
        -- Stops are stored DESCENDING; the curve wants ascending x. Threshold 0 is always
        -- present (GetDurationColorBreakpoints guarantees the base band), so the curve
        -- always spans from 0 and both Linear and Step clamp below it.
        local bps = GetDurationColorBreakpoints(def.scale)
        for i = #bps, 1, -1 do
            curve:AddPoint(bps[i].threshold, hexToColor(bps[i].hex))
        end
        return {
            curve    = curve,
            -- ★ Compare the FULL scale key. This briefly read `== "PERCENT"` after the
            -- scales were renamed TEXT_*/BORDER_*, which silently bound RemainingDuration
            -- (seconds) for EVERY mode — percent stops evaluated against remaining
            -- seconds, red-for-life on short auras. Field-diagnosed twice 2026-07-24
            -- (the first pass misblamed the curve domain; percent IS 0-100, matching
            -- the stops as stored).
            property = (def.scale == "TEXT_PERCENT") and Enum.DurationTextBindingProperty.RemainingPercent
                                                      or Enum.DurationTextBindingProperty.RemainingDuration,
        }
    end)
    durationCurveCache[mode] = (ok and spec) or { buckets = true }
    return durationCurveCache[mode]
end

-- Structural signature contribution for a colour mode. The curve binds ONCE per slot
-- (SetDurationText), so a mode change or a stop edit must move the row/indicator struct
-- sig and force a Rebuild — exactly like the formatter's own breakpoints sig.
function DF:GetDurationColorSig(rawOrMode)
    local mode = DF:ResolveDurationColorMode(rawOrMode)
    if mode == "OFF" then return "" end
    local def = DURATION_COLOR_MODES[mode]
    return ":C" .. mode .. ":" .. DF:GetDurationBreakpointsSig(def.scale)
end

-- True when this mode paints via the legacy |c-escape BUCKET formatter rather than a
-- curve — the formatter must then bake colour into its bands (and the two must never
-- both be armed, since escapes beat the curve).
function DF:DurationColorUsesBuckets(rawOrMode)
    local spec = DF:GetDurationColorSpec(rawOrMode)
    return (spec and spec.buckets) and true or false
end

-- Declared as a method so InvalidateDurationFormatters (defined ABOVE the cache) can
-- reach the upvalue without forward-declaring it.
function DF:_wipeDurationCurves()
    wipe(durationCurveCache)
end

-- /df debug cbt — colour-by-time ground truth. Reports what the engine ACTUALLY resolved
-- rather than what the Colours page shows: whether the curve APIs are reachable at all
-- (if not, every mode silently degrades to the legacy seconds buckets = stepped seconds
-- no matter what the dials say), the account-wide dials, the mode a plain enabled
-- consumer composes, and whether that mode produced a real curve or the bucket fallback.
function DF:DebugDumpColorByTime(threshold)
    local o = DF:Out("Colour by Time")
    -- Strips ONE level of the call sites' hand-indent so o:Line supplies the base
    -- indent while their relative nesting survives.
    local function say(fmt, ...) o:Line((string.format(fmt, ...):gsub("^  ", ""))) end
    say("  curve APIs reachable: %s", tostring(curvesAvailable()))
    say("    C_CurveUtil.CreateColorCurve=%s CreateColor=%s DurationTextBindingProperty=%s LuaCurveType=%s",
        tostring(C_CurveUtil and C_CurveUtil.CreateColorCurve ~= nil), tostring(CreateColor ~= nil),
        tostring(Enum and Enum.DurationTextBindingProperty ~= nil), tostring(Enum and Enum.LuaCurveType ~= nil))
    local g = DF.GetGlobalDB and DF:GetGlobalDB()
    say("  stored dials: smooth=%s scale=%s", tostring(g and g.durationTextColorSmooth),
        tostring(g and g.durationTextColorScale))
    say("  resolved dials: smooth=%s scale=%s", tostring(DF:IsDurationTextColorSmooth()),
        tostring(DF:GetDurationTextColorScale()))
    local mode = DF:ResolveDurationColorMode(true)
    local spec = DF:GetDurationColorSpec(mode)
    say("  enabled consumer -> mode=%s  curve=%s  buckets=%s", tostring(mode),
        tostring(spec and spec.curve ~= nil), tostring(spec and spec.buckets == true))
    say("  sig=%s", tostring(DF:GetDurationColorSig(mode)))
    -- The TWO shared ramps. Duration text reads the one its scale names; each expiry
    -- reveal reads the one matching its OWN unit, so both can be live at once.
    for _, s in ipairs({ "TEXT_SECONDS", "TEXT_PERCENT" }) do
        local bps = GetDurationColorBreakpoints(s)
        local parts = {}
        for _, bp in ipairs(bps) do parts[#parts + 1] = bp.threshold .. "=" .. tostring(bp.hex) end
        say("  %s: %s", s, table.concat(parts, " "))
    end

    -- EXPIRY REVEALS, per indicator. Bands and the Alert Below threshold are ONE formatter
    -- sampled against ONE property, so each indicator's unit governs both — and only stops
    -- BELOW its threshold ever render, which is the usual "why is my top colour missing".
    o:Section("Expiry reveals", "unit, threshold and ramp are PER INDICATOR")
    local Engine = DF.AuraDesigner and DF.AuraDesigner.Engine
    local seen, found = {}, 0
    for _, adMode in ipairs({ "party", "raid" }) do
        local adDB = DF.GetModeAuraDesigner and DF:GetModeAuraDesigner(adMode)
        if adDB and not seen[adDB] then
            seen[adDB] = true
            local spec = Engine and Engine.ResolveSpec and Engine:ResolveSpec(adDB)
            local pools = {}
            if spec and adDB.auras and adDB.auras[spec] then pools[#pools + 1] = adDB.auras[spec] end
            if adDB.otherAuras then pools[#pools + 1] = adDB.otherAuras end
            for _, pool in ipairs(pools) do
                for auraName, auraCfg in pairs(pool) do
                    local inds = type(auraCfg) == "table" and auraCfg.indicators
                    if type(inds) == "table" then
                        for _, ind in ipairs(inds) do
                            if ind.expiryAlertEnabled and DF.Expiration then
                                found = found + 1
                                local unit  = DF.Expiration:Unit(ind)
                                local ipct  = (unit == "PERCENT")
                                local liveT = DF.Expiration:Threshold(ind)
                                say("  [%s] %s %s: %s  below %s%s  ramp=%s  -> a 12s aura reveals at %.1fs",
                                    adMode, tostring(auraName), tostring(ind.type or "?"),
                                    tostring(ind.expiryAlertMode or "BORDER"),
                                    tostring(liveT), ipct and "%" or "s",
                                    DF:GetDurationRampKey(unit),
                                    ipct and (12 * liveT / 100) or math.min(12, liveT))
                                -- Only a BYTIME reveal reads the ramp; a static one is one colour.
                                if ind.expiryAlertBorderColorMode == "BYTIME" then
                                    local parts, hidden = {}, {}
                                    for _, bp in ipairs(GetDurationColorBreakpoints(DF:GetDurationRampKey(unit))) do
                                        local at = tonumber(bp.threshold) or 0
                                        local into = (at < liveT) and parts or hidden
                                        into[#into + 1] = ("%s%s=%s"):format(tostring(at), ipct and "%" or "s", tostring(bp.hex))
                                    end
                                    say("      bands: %s", (#parts > 0) and table.concat(parts, "  ") or "none")
                                    if #hidden > 0 then
                                        -- Stops above the threshold are the usual
                                        -- "why is my top colour missing", so WARN.
                                        o:Line(("    above the threshold (never render): %s")
                                            :format(table.concat(hidden, "  ")), "WARN")
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if found == 0 then say("  no alerted AD indicators found") end
end

-- Account-wide duration-text update rate (Wave 5a) -> the native binding's
-- `updateInterval` (minimum seconds between automatic text refreshes; 0 = every
-- game tick). Creation-frozen: SetDurationText forwards options.updateInterval
-- to the binding once per slot (Blizzard_CustomAuraButton.lua:164), so the value
-- rides every duration spec + struct sig (rows: rowStructSig; AD: durationFmtKey).
-- NORMAL — the default — returns NIL: the spec omits the key and the binding
-- keeps Blizzard's own default cadence. The C-side default is not documented
-- anywhere addon-readable, so the default option must not guess a number —
-- shipping is behavior-neutral by construction. MEMOIZED like the breakpoints
-- sig above (the builders/sigs run per drive); the Options dropdown fires the
-- invalidator on change.
local AURA_DURATION_UPDATE_INTERVALS = { SMOOTH = 0.1, PERFORMANCE = 1.0 }
local durationUpdateIntervalCache   -- resolved seconds, or false = NORMAL/native default
function DF:InvalidateAuraDurationUpdateInterval()
    durationUpdateIntervalCache = nil
end
function DF:GetAuraDurationUpdateInterval()
    local c = durationUpdateIntervalCache
    if c == nil then
        local g = DF.GetGlobalDB and DF:GetGlobalDB()
        c = (g and AURA_DURATION_UPDATE_INTERVALS[g.auraDurationUpdateInterval]) or false
        durationUpdateIntervalCache = c
    end
    return c or nil
end


-- Percent renderer for the percent-family duration formats ("45%"): one band,
-- rounding down, min 1 so a dying aura reads "1%" until it drops (mirrors the
-- seconds bands' min). ONLY meaningful sampled against RemainingPercent via
-- SetTextFormat — a plain SetFormatter would feed it seconds. No colour or
-- threshold inputs -> memoised for the session; a Colours-page edit never
-- touches it (the colour curve tints the whole fontstring on top).
local percentFormatterMemo
local function GetPercentFormatter()
    if percentFormatterMemo ~= nil then return percentFormatterMemo or nil end
    percentFormatterMemo = false
    if C_StringUtil and C_StringUtil.CreateNumericRuleFormatter and Enum and Enum.NumericRuleFormatRounding then
        local ok, f = pcall(function()
            local fmt = C_StringUtil.CreateNumericRuleFormatter()
            fmt:AddBreakpoint({ threshold = 0, step = 1, rounding = Enum.NumericRuleFormatRounding.Down,
                                min = 1, format = "%.0f%%" })
            return fmt
        end)
        if ok and f then percentFormatterMemo = f end
    end
    return percentFormatterMemo or nil
end

-- Resolve a Duration Format VALUE into the spec's (formatter, textFormat) pair —
-- the ONE resolver every duration-text surface uses (buff/debuff/defensive rows +
-- the AD factory), so a new format lands everywhere at once.
--   NUMBER/SHORT/FULL      -> plain seconds-sampled formatter (textFormat nil).
--   PERCENT                -> "45%": one SetTextFormat component sampling
--                             RemainingPercent (68914 multi-component API).
--   SECONDS_PERCENT        -> "12s (45%)": SHORT seconds + percent, two
--                             components each sampling its OWN property.
-- hideAboveT deliberately does NOT apply to the percent family: its threshold is
-- seconds banded into a seconds-sampled formatter — a percent component can't
-- blank on a seconds cut, and blanking only the seconds half would leave a
-- floating "(45%)". The GUI greys Hide Above when a percent format is picked.
-- colorByTime (the pre-68914 |c bucket fallback) only ever reaches the classic
-- formats: a client old enough to bucket lacks SetTextFormat, so the percent
-- family falls back to plain NUMBER there rather than render wrong bands.
function DF:GetDurationFormatFields(format, hideAboveT, colorByTime)
    if format == "PERCENT" or format == "SECONDS_PERCENT" then
        local pct = GetPercentFormatter()
        local prop = Enum and Enum.DurationTextBindingProperty
        if pct and prop then
            if format == "PERCENT" then
                return nil, { formatString = "{}", components = {
                    { property = prop.RemainingPercent, formatter = pct },
                } }
            end
            local secs = GetDurationFormatter("SHORT", nil, colorByTime)
            if secs then
                return nil, { formatString = "{} ({})", components = {
                    { property = prop.RemainingDuration, formatter = secs },
                    { property = prop.RemainingPercent,  formatter = pct },
                } }
            end
        end
        return GetDurationFormatter("NUMBER", hideAboveT, colorByTime), nil
    end
    return GetDurationFormatter(format, hideAboveT, colorByTime), nil
end

-- Percent-family membership — the GUI greys Hide Above off this (see
-- GetDurationFormatFields for why the two can't compose).
function DF:IsPercentDurationFormat(format)
    return format == "PERCENT" or format == "SECONDS_PERCENT"
end

-- Expiry Alert ELEMENT formatter (AD placed indicators): the alert-element variant
-- of BuildDurationFormatter — payload below the threshold, EMPTY above; no countdown,
-- no colour-by-time (the indicator's duration text keeps its own formatter). Cached in
-- the shared duration cache under a distinct "XEL|" key prefix (duration-text keys
-- always start with the format name, so the two variants can never collide). `size`
-- keys the cache too: the GLYPH |A escape bakes it into the band string, and the
-- factory treats every alert change as STRUCTURAL (Rebuild re-binds the formatter).
function DF:GetExpiryAlertElementFormatter(mode, threshold, text, glyphKey, size)
    if mode ~= "TEXT" and mode ~= "GLYPH" then return nil end
    local alertAtlas
    if mode == "GLYPH" then alertAtlas = DF:GetExpiryAlertAtlas(glyphKey) end
    local key = "XEL|" .. mode .. ":" .. tostring(tonumber(threshold) or 5)
        .. ":" .. tostring(math.floor(tonumber(size) or 14))
        .. ":" .. (alertAtlas or tostring(text or ""))
    if durationFormatterCache[key] == nil then
        durationFormatterCache[key] = BuildDurationFormatter(nil, nil, nil,
            mode, threshold, text, alertAtlas, true, size, glyphKey) or false
    end
    return durationFormatterCache[key] or nil
end

-- Expiry BORDER element formatter (AD placed indicators): the |T frame TGA revealed below
-- the alert threshold, empty above. Two colour modes, both secret-safe (Blizzard picks the
-- band from the SECRET remaining time):
--   STATIC  -> one band, |T tinted to `staticColor`.
--   BYTIME  -> one band per BORDER-ramp step below the threshold, each |T tinted to that
--              breakpoint's colour. Breakpoints sig keys the cache (and the factory struct
--              key) so a Colours-page edit rebuilds the bind-frozen formatter.
-- The reveal reads the SAME account-wide ramp as the duration text, picked by `unit`
-- ("SECONDS" | "PERCENT" — the indicator's own expiryAlertThresholdUnit). One set of
-- colours for "time is running out"; the reveal simply cannot BLEND between them (the |T
-- escapes ignore the fontstring vertex colour a colour curve writes), so it steps where
-- text may blend.
-- UNIT: these bands and the reveal threshold are ONE formatter sampled against ONE
-- property, so `unit` governs both — which ramp is read AND the unit `threshold` arrives
-- in. On PERCENT the caller must bind this formatter to RemainingPercent
-- (Features/Expiration.lua feeds it through textFormat); binding it the default way
-- would judge percent bands against remaining seconds.
-- Cached under an "XBEL|" prefix (duration-text keys start with the format name, never "X").
function DF:GetExpiryBorderElementFormatter(threshold, width, height, colorMode, staticColor, thickness, unit)
    if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter and Enum and Enum.NumericRuleFormatRounding) then return nil end
    local alertT = tonumber(threshold) or 5
    if alertT < 1 then alertT = 1 end
    local w = math.max(1, math.floor(tonumber(width) or 18))
    local h = math.max(1, math.floor(tonumber(height) or tonumber(width) or 18))
    local tex = borderTexture(thickness)
    local byTime = (colorMode == "BYTIME")
    local scaleKey = DF:GetDurationRampKey(unit)   -- picks the ramp AND the sampled property
    local key = "XBEL|" .. tostring(alertT) .. ":" .. tostring(w) .. "x" .. tostring(h) .. ":" .. tostring(thickness or "MEDIUM") .. ":" .. scaleKey .. ":"
        .. (byTime and ("T:" .. DF:GetDurationBreakpointsSig(scaleKey)) or ("S:" .. colorToHex(staticColor or { r = 1, g = 0.2, b = 0.2 })))
    if durationFormatterCache[key] == nil then
        local ok, f = pcall(function()
            local down = Enum.NumericRuleFormatRounding.Down
            local fmt = C_StringUtil.CreateNumericRuleFormatter()
            if byTime then
                -- One coloured band per stop, in the ramp's own unit (seconds remaining or
                -- percent of duration — whichever `unit` selected), each holding its colour
                -- up to the next-higher band. Mirrors colorHexAt, and IS the duration-text
                -- ramp: same list, same numbers, same meaning.
                -- A stop AT OR ABOVE the reveal threshold simply never renders — the reveal
                -- does not exist up there. That is the same "a stop past the aura's duration
                -- never shows" the text ramp has always had, so the two behave alike.
                for _, bp in ipairs(GetDurationColorBreakpoints(scaleKey)) do
                    if (tonumber(bp.threshold) or 0) < alertT then
                        fmt:AddBreakpoint({ threshold = bp.threshold, step = 1, rounding = down, min = 1,
                            format = borderEscapeHex(w, h, bp.hex, tex) })
                    end
                end
            else
                fmt:AddBreakpoint({ threshold = 0, step = 1, rounding = down, min = 1,
                    format = borderEscapeHex(w, h, colorToHex(staticColor or { r = 1, g = 0.2, b = 0.2 }), tex) })
            end
            fmt:AddBreakpoint({ threshold = alertT, step = 1, rounding = down, format = "" })   -- empty above threshold
            return fmt
        end)
        durationFormatterCache[key] = (ok and f) or false
    end
    return durationFormatterCache[key] or nil
end

-- ⚠ STACKS FORMATTERS ARE FORBIDDEN on container rows — do not re-add one.
-- (Removed 2026-07-09; was the alpha.2 in-combat container freeze.) Blizzard's
-- ApplyApplicationCount calls formatter:FormatNumber(applications) in LUA with the
-- stack count, which is SECRET in combat; formatter userdata cannot hold secrets, so
-- the call throws inside the container's dirty pass → the dirty-flag latch bricks the
-- container for the session. Bind-time validation can't catch it (AssertValidFormatter
-- test-drives with a non-secret value). The native no-formatter path (shows counts > 1,
-- rendered secure-side via secretwrap) is the only secret-safe option — `stackMinimum`
-- other than 2 is therefore not expressible on 12.1 container rows. Duration-text
-- formatters are NOT affected (C-side DurationTextBinding handles secrets).

-- (Removed 2026-07-09: GetDurationColorCurve. The smooth duration-text colour curve is
-- NOT addon-reachable on 68569 — SetDurationText{textColorCurve} drops the required
-- `property` arg, and the button's DurationTextBinding is PRIVATE, so "apply it on the
-- binding" cannot work; poking Blizzard-owned binding state on a live button is also the
-- exact touch class behind the combat dirty-latch freeze. durationColorByTime ships as
-- discrete colour BUCKETS via the duration formatter (|cRRGGBB escapes in AddBreakpoint
-- format strings — C-side, secret-safe, the NSRT-proven path): BuildDurationFormatter above.)

-- (Removed 2026-07-13: BuildBuffExcludeMap / the manual aura blacklist. The filter
-- registry supersedes it — per-spell control lives in Filter Designer presets and
-- per-row filter selections. The stored data (DF.db.auraBlacklist) is kept but no
-- longer enforced; the Aura Blacklist page is a retirement notice.)

-- Stable signature of an excludeSpellIDs map (sorted IDs) — exclude-set changes
-- (AD-dedup, missing-buff hide) are TUNING (Wave 1: SetAuraGroupCandidateFilters is a
-- live mutator), so the row TUNING signature must move when the set does — the row
-- re-applies the maps in place via ApplyTuning instead of a teardown+recreate.
local function excludeSig(cf)
    local m = cf and cf.excludeSpellIDs
    if not m then return "" end
    local ids = {}
    for id in pairs(m) do ids[#ids + 1] = id end
    table.sort(ids)
    return table.concat(ids, ",")
end

-- Include-map counterpart (filter-registry selection resolved to includeSpellIDs) —
-- same tuning rule: the row TUNING signature must move when the set does. Presence-marked
-- ("I:" prefix) so an EMPTY-but-present include map (include-nothing, e.g. the only
-- selected custom filter has zero spells) still differs from no map at all — the
-- all -> include-nothing transition must re-apply.
local function includeSig(cf)
    local m = cf and cf.includeSpellIDs
    if not m then return "" end
    local ids = {}
    for id in pairs(m) do ids[#ids + 1] = id end
    table.sort(ids)
    return "I:" .. table.concat(ids, ",")
end

-- Sort Order dropdown ("DEFAULT"/"TIME"/"NAME") + Mine First / Reverse checkboxes
-- -> config.sort (AuraContainerSortMethod/SortDirection member NAMES). Rides the
-- TUNING sig (rows: rowTuningSig serializes method + direction; AD groups fold
-- the raw fields into their tuning sig), so changes apply in place via
-- ApplyTuning. nil = no sort declared = Blizzard's inbound default (mine-first
-- slot order) — today's DEFAULT behaviour, kept byte-identical.
-- SHARED (Wave 2): exposed on DF so the AD group families (filter / other-buff /
-- debuff groups, AuraDesigner/Factory.lua) map their per-group sort fields
-- through the SAME function as the rows — callers feed their own storage.
-- Sort orders whose native method has NO mine-first variant, so "My Auras First" is
-- inert while one is selected and the GUI greys it (same treatment DEFAULT already gets).
-- APPLIED is the only one: Blizzard ships AuraInstanceIDOnly with no plain AuraInstanceID.
local SORT_ORDERS_WITHOUT_MINE_FIRST = { DEFAULT = true, APPLIED = true }
function DF:SortOrderSupportsMineFirst(order)
    return not SORT_ORDERS_WITHOUT_MINE_FIRST[order or "DEFAULT"]
end

function DF:BuildAuraSort(order, mineFirst, reverse)
    local method
    if order == "TIME" then
        method = mineFirst and "Expiration" or "ExpirationOnly"
    elseif order == "NAME" then
        method = mineFirst and "Name" or "NameOnly"
    elseif order == "APPLIED" then
        -- Chronological, never-reshuffling order: auraInstanceIDs are handed out in
        -- application order and the comparator is a plain `a.auraInstanceID <
        -- b.auraInstanceID` (Blizzard_FrameXMLUtil/AuraUtil.lua), so an aura keeps its
        -- place when it refreshes instead of jumping as its remaining time changes.
        -- Mine-first cannot ride this one — there is no non-"Only" variant of it.
        method = "AuraInstanceIDOnly"
    elseif reverse then
        -- DEFAULT + Reverse: the direction needs an explicit method to ride on.
        method = "Default"
    end
    if not method then return nil end
    return { method = method, direction = reverse and "Reverse" or nil }
end

-- Colour-mode ramps. A StatusBar CROPS its fill texture to the filled fraction, so a
-- baked colour RAMP as the texture makes the visible tip colour walk the ramp as the
-- native fill drains: colour-by-remaining with ZERO reads, which is the only way to do
-- it in 12.1 (remaining time is secret). Two hard constraints, both probe-confirmed
-- 2026-07-20 (see the 12.1 lockdown notes + DF_AuraLab "Duration bar" verdicts):
--   * it keys off FRACTION remaining, never seconds — so it CANNOT mirror the
--     seconds-based durationColorByTimeBreakpoints thresholds, only their palette;
--   * the ramps are baked images and deliberately NOT driven by the colour pickers.
--     The fill crop clips only the statusbar's own texture (children are untouched),
--     and GetValue() returns a SECRET number, so neither a segmented ramp nor a
--     self-tinted one is possible. Don't re-litigate this without a new probe.
-- One orientation per curve. The ramp is painted for the DRAIN case: red at the left
-- end, green at the right, so the tip walks green -> red as the bar empties. That is
-- the only case there is - the bar always drains (see `direction` below), and Reverse
-- Fill needs NO mirrored art [confirmed in-game 2026-07-20]: the StatusBar flips the
-- texture along with the fill, so the ramp's relationship to the tip already survives.
-- VERTICAL bars need no second file either: SetRotatesTexture turns the same art.
-- Because they key off fraction, the two DF ramps are baked from the PERCENT scale's
-- DEFAULTS (DEFAULT_PERCENT_BREAKPOINTS above): f75555 at 0%, ff9838 at 25%, ffd23d at
-- 50%, 5fe05f at 75%, flat green above. The smooth ramp blends between those stops; the
-- stepped one floors to them, so the bar shows the same four hard bands the stepped
-- duration text does. Both are generated by Tools/generate_curves.py — re-run it if the
-- percent defaults ever move. The art carries the DEFAULTS, not the user's edited stops,
-- since a baked image cannot follow the pickers. Stored keys are frozen: DF has always
-- meant the smooth ramp, so existing profiles keep exactly the look they had.
-- The files are named *_Curve on purpose. Bare DF_* names belong to the LibSharedMedia
-- STATUSBAR textures registered in Config.lua — DF_Smooth is one of them, a bar texture
-- a user can pick — so a ramp must never be given one of those file names.
local CURVE_TEXTURES = {
    DF       = "Interface\\AddOns\\DandersFrames\\Media\\DF_Curve_Smooth",
    DFSTOPS  = "Interface\\AddOns\\DandersFrames\\Media\\DF_Curve_Stops",
    CLASSIC  = "Interface\\AddOns\\DandersFrames\\Media\\Classic_Curve",
}

-- The Color Mode dropdown's option set, SHARED by every consumer: the buff / debuff /
-- defensive Bar Style groups (Options/Options.lua) and both Aura Designer cards (group
-- + placed indicator). Inlining it per call site is how the four copies drifted — three
-- carried no _order, so CreateDropdown fell back to sorting by LABEL and listed them in
-- a different order than the one copy that did. Keep STATIC first (it is the default);
-- the ramps follow in the order they escalate.
local COLOR_MODE_ORDER = { "STATIC", "DF", "DFSTOPS", "CLASSIC" }
function DF:GetDurationBarColorModes()
    local L = DF.L
    return {
        STATIC  = L["Static"],
        DF      = L["DF Smooth"],
        DFSTOPS = L["DF Stops"],
        CLASSIC = L["Classic"],
        _order  = COLOR_MODE_ORDER,
    }
end

-- Shared predicate: does this colour mode swap the fill texture for a ramp? The GUI
-- uses it to dim Texture / Bar Color, both of which a curve mode overrides. One source
-- of truth: add a ramp to CURVE_TEXTURES above and every consumer follows.
function DF:IsDurationBarCurveMode(mode) return CURVE_TEXTURES[mode] ~= nil end
-- The ramp texture for a curve colour mode (nil for STATIC / unknown). Lets a consumer
-- outside this file (the AD bar factory) opt a StatusBar's fill into the same green->red
-- ramp the duration-bar strips use.
function DF:GetDurationBarCurveTexture(mode) return CURVE_TEXTURES[mode] end

-- Duration bar (Wave 3, #205): prefixed key block -> the engine's style.bar
-- STRIP spec (fill = false; the fill shape is AD-only). Returns nil when the
-- Enabled key is off/absent, so disabled configs stay byte-identical to
-- pre-Wave-3 output (no style.bar key at all). The tonumber clamps are
-- load-bearing: they guarantee styling (styleBarShared / strip geometry) and
-- the layout reservation (stripReservation) see the SAME number for height/gap
-- even if a profile carries garbage — both engine defaults are 4/1.
-- SHARED: rows pass (db, "buffDurationBar"/"debuffDurationBar"/
-- "defensiveDurationBar"); the AD group families pass (group.style,
-- "durationBar") — one builder, callers feed their own storage.
function DF:BuildDurationBarSpec(store, keyPrefix)
    if not store or store[keyPrefix .. "Enabled"] ~= true then return nil end
    local curve = CURVE_TEXTURES[store[keyPrefix .. "ColorMode"]]
    return {
        show        = true,
        fill        = false,   -- strip shape (out-of-rect; the engine reserves wrap space)
        position    = (store[keyPrefix .. "Position"] == "TOP") and "TOP" or "BOTTOM",
        height      = tonumber(store[keyPrefix .. "Height"]) or 4,
        gap         = tonumber(store[keyPrefix .. "Gap"]) or 1,
        -- Curve mode overrides the configured texture; `curve` tells styleBarShared to
        -- force a white tint, since any colour would multiply the ramp and muddy it.
        texture     = curve or store[keyPrefix .. "Texture"],
        curve       = curve and true or nil,
        color       = store[keyPrefix .. "Color"],
        bgColor     = store[keyPrefix .. "BGColor"],
        reverseFill = store[keyPrefix .. "ReverseFill"] and true or false,
        -- Enum.StatusBarTimerDirection MEMBER NAME, and deliberately NOT a setting.
        -- RemainingTime = the bar DRAINS; ElapsedTime (Blizzard's default, hence the
        -- explicit pass) fills from empty as the aura runs, which contradicts what a
        -- "duration bar" means and runs the colour curve backwards. Nobody wants that,
        -- so we don't expose it. Reverse Fill still flips which END it drains toward.
        direction   = "RemainingTime",
    }
end

-- Tooltips page -> native aura-button tooltip placement (68914+). The button's
-- SetTooltipAnchorPoint/SetHideTooltipInCombat are plain mixin state read at hover
-- time (SetOwner anchor + the ShouldShowTooltip combat gate), so this spec rides
-- style.* and hot-applies through the cosmetic ApplyStyle pass — no rebuild.
-- key = "Buff"/"Debuff"/"Defensive" (the Tooltips page's per-row blocks).
-- Model mapping (mirrors the legacy frame-tooltip semantics in Create.lua):
--   DEFAULT -> ANCHOR_BOTTOMLEFT 0,0 (the template's own default — explicit so a
--              hot-apply can always overwrite a previous mode)
--   CURSOR  -> cursor-follow anchor, side picked from AnchorPos (offsets unused,
--              matching the page greying them out)
--   FRAME   -> "ANCHOR_"..AnchorPos on the hovered icon + the X/Y offsets.
--              CENTER has no native anchor name -> falls back to DEFAULT
--              (SetTooltipAnchorPoint asserts on anything off its list).
local NATIVE_TOOLTIP_POINTS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}
local function buildTooltipSpec(db, key)
    local mode = db["tooltip" .. key .. "Anchor"] or "DEFAULT"
    local pos  = db["tooltip" .. key .. "AnchorPos"]
    local point, x, y = "ANCHOR_BOTTOMLEFT", 0, 0
    if mode == "CURSOR" then
        if pos == "LEFT" or pos == "TOPLEFT" or pos == "BOTTOMLEFT" then
            point = "ANCHOR_CURSOR_RIGHT"
        elseif pos == "RIGHT" or pos == "TOPRIGHT" or pos == "BOTTOMRIGHT" then
            point = "ANCHOR_CURSOR_LEFT"
        else
            point = "ANCHOR_CURSOR"
        end
    elseif mode == "FRAME" and NATIVE_TOOLTIP_POINTS[pos] then
        point = "ANCHOR_" .. pos
        x = db["tooltip" .. key .. "X"] or 0
        y = db["tooltip" .. key .. "Y"] or 0
    end
    return {
        point = point, x = x, y = y,
        hideInCombat = db["tooltip" .. key .. "DisableInCombat"] == true,
    }
end

-- Map a prefixed aura-row setting block (buff*/debuff*) -> DF.AuraContainer config.
-- prefix = "buff" (debuff reuses this later). opts.filterList is the PRE-BUILT native
-- filter list (buffs: BuildDirectBuffFilters); opts.unit is the initial unit token.
-- Scale note: layoutRow SetScale(layout.scale)'s each button, so fonts / border / spacing
-- all inherit the row scale — pass BASE (unscaled) sizes here, exactly as the db stores them.
function DF:BuildAuraRowConfig(db, prefix, opts)
    opts = opts or {}
    prefix = prefix or "buff"
    local function g(suffix) return db[prefix .. suffix] end
    local filter = opts.filterList
    if filter == nil then filter = (prefix == "debuff") and "HARMFUL" or "HELPFUL" end

    local iconSize = g("Size") or 20
    local dur
    if g("ShowDuration") ~= false then
        local durFormat = g("DurationFormat") or "NUMBER"
        -- Colour-by-time: the stored value is a MODE (legacy profiles hold a boolean —
        -- ResolveDurationColorMode maps true to STEP_SECONDS so they keep today's look).
        -- On 68914+ every mode paints through the native colour CURVE; only the pre-68914
        -- fallback bakes |c escapes into the formatter's bands, and the two are mutually
        -- exclusive because escapes beat the curve.
        local colorMode = DF:ResolveDurationColorMode(g("DurationColorByTime"))
        local colorSpec = DF:GetDurationColorSpec(colorMode)
        local colorByTime = DF:DurationColorUsesBuckets(colorMode)
        local hideAboveT = (g("DurationHideAboveEnabled") and g("DurationHideAboveThreshold")) or nil
        -- Hide Above can't compose with the percent-family formats (seconds-banded
        -- vs percent-sampled — see GetDurationFormatFields); zeroed here so the
        -- formatKey below stays truthful too. The GUI greys the controls to match.
        if DF:IsPercentDurationFormat(durFormat) then hideAboveT = nil end
        -- Text styling (font/scale/outline/anchor/offsets/justify/colour) is a shared
        -- DF.TextStyle spec; the factory applies it via TextStyle:Apply. The justify box
        -- is the icon rect. Feature fields (show/formatter/formatKey) ride on top.
        dur = DF.TextStyle:BuildSpec(db, prefix .. "Duration", {
            baseSize = 10, defaultAnchor = "CENTER", boxW = iconSize, boxH = iconSize,
        })
        dur.show = true
        dur.stableCenter = true   -- centred countdown: stable box, no shift, no wobble
        dur.formatter, dur.textFormat = DF:GetDurationFormatFields(durFormat, hideAboveT, colorByTime)
        -- Either colour path (curve or legacy buckets) owns the text colour outright, so
        -- the static colour must not stomp it. formatKey carries the mode + its scale's
        -- stops so a change moves the rebuild signature — BOTH the formatter and the
        -- curve are creation-frozen on the native bind.
        if colorSpec then dur.color = nil end
        dur.colorCurve, dur.colorProperty = (colorSpec and colorSpec.curve), (colorSpec and colorSpec.property)
        dur.formatKey = durFormat .. DF:GetDurationColorSig(colorMode) .. (hideAboveT and (":H" .. tostring(hideAboveT)) or "")
        -- Hide duration text on permanent auras (Wave 4, default ON): zeroText = ""
        -- flows to the native binding's zeroDurationText — Blizzard renders NO text
        -- on zero-duration/unconfigured durations. Absent key (pre-migration db)
        -- = ON; explicit false = the pre-Wave-4 spec shape (no zeroText at all).
        -- Creation-frozen (SetDurationText binds once) -> rides rowStructSig.
        if g("DurationHideOnPermanent") ~= false then dur.zeroText = "" end
        -- Duration-text update rate (Wave 5a, account-wide): nil at the NORMAL
        -- default (key absent -> the binding keeps Blizzard's default cadence,
        -- byte-identical to the pre-setting spec). Creation-frozen -> rowStructSig.
        dur.updateInterval = DF:GetAuraDurationUpdateInterval()
    end

    -- Buff rows get native spell-ID exclude maps (AD-dedup + missing-buff hide below).
    -- Debuff rows get NO spell-ID filters — harmful spell-ID maps are inert on
    -- friendly frames (the assist/attack gate).
    local candidateFilters
    if prefix == "buff" then
        -- Native max-TOTAL-duration filter (candidateFilters.maxDuration, seconds).
        -- Blizzard-side semantics: auras with duration > max OR duration == 0 are
        -- filtered — i.e. permanent auras are IMPLICITLY always hidden while this
        -- is on (documented in the GUI tooltip). Tuning: re-applied in place
        -- (SetAuraGroupCandidateFilters is a live mutator — rides the tuning sig).
        if db.buffMaxDurationEnabled and (db.buffMaxDurationMinutes or 0) > 0 then
            candidateFilters = candidateFilters or {}
            candidateFilters.maxDuration = (db.buffMaxDurationMinutes or 0) * 60
        elseif db.buffHidePermanent then
            -- Hide Permanent Auras alone: a max-FINITE cap. maxDuration rejects
            -- duration == 0 and no finite duration exceeds 2^31-1, so this hides
            -- ONLY permanents. Skipped when Hide Long Buffs already set a finite
            -- cap above — that cap rejects permanents by itself. Same tuning ride.
            candidateFilters = candidateFilters or {}
            candidateFilters.maxDuration = 2147483647
        end
        -- Missing Buff "Hide From Buff Bar": union every raid-buff ID (all ranks/
        -- variants) into the exclude map. Legacy did this with an icon-texture match
        -- in the scan, OUT of combat only (reads); the native filter holds in combat
        -- too — a strict upgrade. Tuning (rides excludeSig in the row tuning signature).
        if db.missingBuffHideFromBar and DF.RaidBuffs then
            candidateFilters = candidateFilters or {}
            local map = candidateFilters.excludeSpellIDs or {}
            candidateFilters.excludeSpellIDs = map
            for i = 1, #DF.RaidBuffs do
                local ids = DF.RaidBuffs[i][1]
                if type(ids) == "table" then
                    for j = 1, #ids do map[ids[j]] = true end
                else
                    map[ids] = true
                end
            end
        end
        -- Aura Designer dedup (derived, read-free). When the legacy "Hide Duplicate Buffs"
        -- toggle is on AND the native factory owns AD for this frame, hide every aura
        -- tracked by ANY Aura Designer indicator from the buff bar so it doesn't render
        -- twice. The set is RECOMPUTED from the AD config every time the row rebuilds
        -- (GetADTrackedSpellIDs) — no stored write, no refcount — so it is
        -- automatically correct across indicator add/remove, aura delete, profile
        -- switch and spec change. UNIONED into (never replacing) the exclude
        -- map above, and folded into the row tuning signature via excludeSig, so a
        -- change in the tracked set re-applies the buff row's candidate filters in
        -- place (see rowTuningSig / ApplyTuning).
        if db.buffDeduplicateDefensives and opts.frame and DF.GetADTrackedSpellIDs then
            local adIDs = DF:GetADTrackedSpellIDs(opts.frame, db)
            if adIDs then
                candidateFilters = candidateFilters or {}
                local map = candidateFilters.excludeSpellIDs or {}
                candidateFilters.excludeSpellIDs = map
                for id in pairs(adIDs) do map[id] = true end
            end
        end
        -- Defensive Bar dedup, HALF TWO — the EXACT case. The defensive row runs
        -- the SAME FilterRegistry resolution (DriveDefensiveFactory), so in
        -- include-mode its contents already ARE a spell-ID map: union it and the
        -- two bars agree exactly, with no category approximation. HALF ONE (the
        -- "all" fallback, negated category) is in BuildDirectBuffFilters.
        --
        -- Exclude-mode is deliberately uncovered: the bar then shows "everything
        -- helpful EXCEPT this map", an unbounded set with no expressible
        -- complement here. Approximating it with !BIG_DEFENSIVE would hide the
        -- whole Blizzard category from the buff bar while the defensive bar was
        -- only showing part of it — buffs would vanish from both.
        --
        -- Gated on the bar being ON for the same reason.
        if db.buffDeduplicateDefensives and db.defensiveIconEnabled and DF.FilterRegistry then
            local dres = DF.FilterRegistry:ResolveSelection(db.defensiveFilterSelection, false)
            if dres.kind == "include" and dres.map then
                candidateFilters = candidateFilters or {}
                local map = candidateFilters.excludeSpellIDs or {}
                candidateFilters.excludeSpellIDs = map
                for id in pairs(dres.map) do map[id] = true end
            end
        end
        -- FILTER REGISTRY: fold the category selection into this group's spec.
        -- include-mode (categories selected) subtracts the exclude union above so
        -- AD-dedup / missing-buff still win inside one map; exclude-mode
        -- (Uncategorised on) unions the known-but-unselected set into it. "all"
        -- (Show All / empty selection) leaves the exclude union untouched — the
        -- pre-registry behavior, byte-for-byte.
        local res = DF.FilterRegistry:ResolveSelection(db.buffFilterSelection, db.directBuffShowAll)
        if res.kind == "include" then
            local inc = {}
            local excl = candidateFilters and candidateFilters.excludeSpellIDs
            for id in pairs(res.map) do
                if not (excl and excl[id]) then inc[id] = true end
            end
            candidateFilters = candidateFilters or {}
            candidateFilters.includeSpellIDs = inc
            candidateFilters.excludeSpellIDs = nil  -- redundant after subtraction
        elseif res.kind == "exclude" then
            candidateFilters = candidateFilters or {}
            local excl = candidateFilters.excludeSpellIDs or {}
            for id in pairs(res.map) do excl[id] = true end
            candidateFilters.excludeSpellIDs = excl
        end
    end

    -- Native sort: the legacy Sort Order dropdown (directBuffSortOrder) mapped onto
    -- AuraContainerSortMethod member NAMES, refined by the Wave-2 checkboxes.
    -- Mine First picks the composite comparators (Expiration/Name = own auras
    -- first, then the dimension); off keeps the *Only pure single-dimension
    -- sorts (the pre-Wave-2 behaviour, byte-identical with both boxes off).
    -- DEFAULT ignores Mine First (Blizzard's slot order is already mine-first;
    -- the GUI greys the box) and passes nothing — unless Reverse is on, which
    -- needs an explicit method ("Default") to hang the direction on. Reverse
    -- maps to sort.direction = "Reverse"; omitted = the engine's "Normal".
    -- The backend resolves member names against the securecopy'd global enums.
    local sort
    if prefix == "buff" then
        sort = DF:BuildAuraSort(db.directBuffSortOrder, db.directBuffSortMineFirst, db.directBuffSortReverse)
    elseif prefix == "debuff" then
        sort = DF:BuildAuraSort(db.directDebuffSortOrder, db.directDebuffSortMineFirst, db.directDebuffSortReverse)
    end

    -- Debuff rows: NATIVE dispel border when Color-by-Dispel-Type is on. The colour is
    -- applied PRIVATE-side (the dispel type is secret) — the slot bind in
    -- Frames/AuraContainer.lua passes customDispelColorMap + customDispelColorCurve built
    -- from the shared account palette (DF.db.dispelColors, Colors page) for the "Color"
    -- style, so DF's per-type colours ARE expressible; clients without the curve API fall
    -- back to the map, and Atlas keeps Blizzard's palette. Shows only on
    -- dispellable debuffs; the static DF.Border below renders always, so
    -- non-dispellable keeps the base border.
    -- Wave 5b: the spec also hosts the NATIVE dispel-type SYMBOL (colourblind letter,
    -- SetAuraSymbol) — DECOUPLED from the colour ring so either ships alone. Both are
    -- engine-written (zero aura reads); the symbol additionally renders in-game only
    -- while the colorblindMode CVar is on (test mode previews it regardless).
    local dispel
    if prefix == "debuff" then
        local colorByType = db.debuffBorderColorByType
        local showSymbol = db.debuffDispelSymbolEnabled == true
        if colorByType or showSymbol then
            dispel = { showWhenHarmful = true }
            if colorByType then
                -- thickness: match the icon's own DF border so the dispel ring reads as
                -- "the border took the dispel colour" (flat square line at the same
                -- weight; inset 0 lands exactly on it, negative insets halo outward).
                local ringSize = db.debuffBorderSize or 2
                if db.pixelPerfect and DF.PixelPerfect then ringSize = DF:PixelPerfect(ringSize) end
                dispel.nativeBorder = true
                dispel.style = "Color"
                dispel.inset = db.debuffDispelBorderInset or -2
                dispel.thickness = ringSize
            end
            if showSymbol then
                dispel.nativeSymbol = true
                -- Symbol styling is a shared TextStyle spec (the FontString is OURS;
                -- the engine only writes its text) — restyles in place via ApplyStyle.
                dispel.symbol = DF.TextStyle:BuildSpec(db, "debuffDispelSymbol", {
                    baseSize = 10, defaultAnchor = "CENTER", boxW = iconSize, boxH = iconSize,
                })
            end
        end
    end

    return {
        sort     = sort,
        unit     = opts.unit,
        mode     = "row",
        filter   = filter,
        max      = g("Max") or 5,
        -- ☠ EXPLICIT 32, not ApplyZOrder's `or 40` default. The buff/debuff rows and the
        -- AURA DESIGNER indicators were both landing on 40 — identical anchor, container
        -- and button levels — so which drew on top was decided by creation order, i.e. by
        -- nothing. An AD indicator placed over the aura row is meant to annotate it and
        -- must win; at equal levels it sometimes did not.
        -- 32 puts the rows in their own band: above the status icons at 30 (single frames,
        -- no children of their own) and clear below the AD band at 40. The rows have no
        -- user-facing level slider, so this moves nothing a user configured — which is why
        -- the fix goes here rather than shifting the AD default and forcing a migration.
        -- Span: 32..39 (container +1, button +2, border +4, holders +3..+7).
        -- (Z-order review, 2026-08-07.)
        frameLevelOffset = 32,
        -- Test-mode preview cap: the test panel's Buffs/Debuffs count sliders
        -- (hot-applied via Handle:SetTestMax from the test drive seam).
        testMax  = (prefix == "buff" and (db.testBuffCount or 2))
                or (prefix == "debuff" and (db.testDebuffCount or 2))
                or nil,
        enabled  = true,
        candidateFilters = candidateFilters,
        -- Native hover tooltips: governed by the Tooltips page's per-row Enable.
        -- (The old Integrations "click-through" toggle also suppressed them, but
        -- that's gone on 12.1 — the container icons are always click-through by
        -- design — so tooltips key off the Tooltips page alone now.)
        tooltips = db["tooltip" .. (prefix == "debuff" and "Debuff" or "Buff") .. "Enabled"] ~= false,
        layout = {
            size     = g("Size") or 20,
            scale    = g("Scale") or 1,
            spacingX = g("PaddingX") or 2,
            spacingY = g("PaddingY") or 2,
            anchor   = g("Anchor") or "BOTTOMRIGHT",
            growth   = g("Growth") or "LEFT_UP",
            wrap     = g("Wrap") or 3,
            offsetX  = g("OffsetX") or 0,
            offsetY  = g("OffsetY") or 0,
        },
        style = {
            icon   = { show = true, zoom = true, inset = 0 },
            border = g("ShowBorder") and { db = db, prefix = prefix } or nil,
            cooldown = { show = not g("HideSwipe"), reverse = true, edge = false, numbers = false },
            duration = dur,
            dispel   = dispel,
            -- Tooltip placement + combat-hide (Tooltips page): live mixin state,
            -- restyles in place — deliberately in NEITHER row sig.
            tooltip  = buildTooltipSpec(db, (prefix == "debuff") and "Debuff" or "Buff"),
            -- Duration bar strip (nil when disabled — byte-neutral). Presence +
            -- geometry are structural (rowStructSig's s.bar entry, Wave 3.1);
            -- texture/colours restyle in place.
            bar      = DF:BuildDurationBarSpec(db, prefix .. "DurationBar"),
            -- Pandemic cue (PTR 8): the game's own refresh window, rendered on each
            -- button by AddPandemicRegion. Keys are prefixed (buffPandemic*) because the
            -- row's settings live in the FLAT profile table, unlike the Aura Designer's
            -- per-indicator records — the engine owns that split so neither surface knows
            -- the other's key shape. Presence + mode + flash are structural
            -- (rowStructSig); everything else rides the unconditional ApplyStyle below.
            --
            -- ☠ BUFF ROW ONLY, deliberately. The debuff row shows harmful auras on a
            -- FRIENDLY unit — things cast on your party by something else. You cannot
            -- refresh those, so they have no refresh window and GetRefreshExtendedDuration
            -- returns nil for every one of them. A Pandemic section on Debuffs would be a
            -- panel of live controls wired to a cue that can never light: the
            -- silent-capability-skip antipattern, with the impossibility coming from the
            -- game's rules rather than the client build. (Krathe, 2026-08-05.) If DF ever
            -- grows an enemy-target DoT row, that surface is where this belongs.
            --
            -- ctx is DF.Border's build context: the unit for class/role colour sources,
            -- and iconMode so the border sizes like an icon ring rather than a frame edge.
            pandemic = (prefix == "buff") and DF.Pandemic
                and DF.Pandemic:BuildSpec(db, prefix, { unit = opts.unit, iconMode = true })
                or nil,
            -- Shared TextStyle spec (font/scale/outline/anchor/offsets/justify/colour).
            -- No formatter: forbidden on container rows (secret trap — see the
            -- GetStacksFormatter tombstone above). Native default = counts > 1.
            stacks = (function()
                local st = DF.TextStyle:BuildSpec(db, prefix .. "Stack", {
                    baseSize = 10, defaultAnchor = "BOTTOMRIGHT",
                    defaultOffsetX = 2, defaultOffsetY = -1,
                    boxW = iconSize, boxH = iconSize,
                })
                st.show = true
                return st
            end)(),
        },
    }
end

-- Canonical signature of one record's candidateFilters: boolean flags by name,
-- maxDuration, and sorted includeDispelTypes/excludeDispelTypes keys. Sorted
-- throughout so table-insertion order never moves the signature.
local function cfSig(cf)
    if not cf then return "" end
    local parts = {}
    for k, v in pairs(cf) do
        if type(v) == "boolean" then parts[#parts + 1] = k .. "=" .. tostring(v) end
    end
    table.sort(parts)
    if cf.maxDuration then parts[#parts + 1] = "max=" .. tostring(cf.maxDuration) end
    local function mapKeys(m)
        local keys = {}
        for k in pairs(m) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        return table.concat(keys, ",")
    end
    if cf.includeDispelTypes then parts[#parts + 1] = "incDispel=" .. mapKeys(cf.includeDispelTypes) end
    if cf.excludeDispelTypes then parts[#parts + 1] = "excDispel=" .. mapKeys(cf.excludeDispelTypes) end
    if cf.excludeSpellIDs then parts[#parts + 1] = "excSpell=" .. mapKeys(cf.excludeSpellIDs) end
    return table.concat(parts, "&")
end

-- ☠ CORRECTED 2026-08-04. This used to say "a group's filterString can't be changed
-- live" and that claim is what put filter strings in the struct sig in the first place.
-- SetAuraGroupFilterString / SetAuraSlotFilterString have always existed and destroy
-- nothing — proven in game via the DF_AuraLab /alfilter A/B probe. What AddAuraGroup
-- really freezes is the record SET: the topology is add-only, so a record appearing or
-- disappearing needs a new container. Only the KEYS (and per-record style) are
-- structural now; strings and candidateFilters are both live-tunable (filterTuningSig).
-- A record's per-button STYLE (important-debuff highlight). STRUCTURAL, not tuning:
-- it decides whether the group gets its own initializeFrame closure, whether the badge
-- regions exist at all, and the group's layout cell size — none of which ApplyStyle can
-- change in place. Serialized here so toggling the highlight actually rebuilds; without
-- this the setting writes to the DB and nothing on screen moves.
local function recStyleSig(s)
    if type(s) ~= "table" then return "" end
    local b = s.badge
    return "@" .. tostring(s.scale) .. "/" .. (b and (tostring(b.size) .. ","
        .. tostring(b.point) .. "," .. tostring(b.offsetX) .. "," .. tostring(b.offsetY) .. ","
        .. tostring(b.color and b.color.r) .. "," .. tostring(b.color and b.color.g) .. ","
        .. tostring(b.color and b.color.b) .. ","
        .. tostring(b.markColor and b.markColor.r) .. "," .. tostring(b.markColor and b.markColor.g) .. ","
        .. tostring(b.markColor and b.markColor.b)) or "-")
end

-- STRUCT half of a filter list: the KEY SET and the per-record style, NOT the filter
-- strings.
--
-- ☠ WHY THE KEY SET AND NOT THE STRING (2026-08-04). AddAuraGroup/AddAuraSlot are
-- add-only — there is no remove — so a record APPEARING or DISAPPEARING genuinely needs
-- a new container. A record keeping its key while its filter string changes does not:
-- SetAuraGroup/SlotFilterString mutate that live and destroy nothing, and the engine
-- pushes it from applyGroupTuning. The string therefore moved to filterTuningSig.
-- Per-record style STAYS here: it is applied in initializeFrame, which a tuning pass
-- does not re-run (measured — a filter-string swap leaves initializeFrame counts flat).
--
-- Plain-string entries contribute "" rather than the string itself, so a bare
-- HELPFUL <-> HARMFUL swap is a tuning delta. The ";" separators still encode the
-- record COUNT, which is the part that has to stay structural.
local function filterStructSig(f)
    if type(f) ~= "table" then return "" end
    local parts = {}
    for i = 1, #f do
        local entry = f[i]
        if type(entry) == "table" then
            parts[i] = tostring(entry.key) .. recStyleSig(entry.style)
        else
            parts[i] = ""
        end
    end
    return table.concat(parts, ";")
end

-- TUNING half of a filter list: each record's FILTER STRING plus its candidateFilters
-- (boolean flags, maxDuration, dispel-type maps via cfSig; spell-ID maps via
-- include/excludeSig — records carry none today, but the serializer must not go blind
-- if they appear). Positional, so it stays aligned with filterStructSig's record order.
-- Grammar note: the four "&"-joined components stay disambiguable because the filter
-- string is "F:"-prefixed, cfSig parts always contain "=", includeSig is "I:"-prefixed,
-- and excludeSig is bare digits — any new token must keep its component recognisable
-- within that grammar.
-- The filter string joined this half on 2026-08-04; see filterStructSig for why that is
-- safe while the key set stays structural.
local function filterTuningSig(f)
    if type(f) ~= "table" then return "" end
    local parts = {}
    for i = 1, #f do
        local entry = f[i]
        if type(entry) == "table" then
            local cf = entry.candidateFilters
            parts[i] = "F:" .. tostring(entry.filter)
                .. "&" .. cfSig(cf) .. "&" .. includeSig(cf) .. "&" .. excludeSig(cf)
        else
            parts[i] = "F:" .. tostring(entry)
        end
    end
    return table.concat(parts, ";")
end

-- Public split halves for the AD debuff-group containers (AuraDesigner/Factory.lua,
-- Wave 1) — the record shape is the same one the row folds into its own signatures,
-- so the groups reuse the exact serializers. Struct half = record KEYS + per-record
-- style (a selection edit that changes the record SET Rebuilds); tuning half = each
-- record's filter string + candidateFilters (applies in place via ApplyTuning).
-- The combined DF:DebuffFilterRecordsSig above stays as the canonical whole-record
-- serializer (harness equivalence oracle).
function DF:DebuffFilterRecordsStructSig(records)
    return filterStructSig(records)
end

function DF:DebuffFilterRecordsTuningSig(records)
    return filterTuningSig(records)
end

-- Row signatures, SPLIT (Wave 1). The old combined buffFactorySig forced a
-- teardown+recreate for every delta; now:
--   rowStructSig  — changes need a Rebuild (new container): the record KEY SET
--     (add-only topology — no RemoveAuraGroup) and per-record style, region-presence
--     toggles (ApplyStyle can't CREATE or REMOVE a region), creation-frozen formatKeys
--     + zeroText (SetDurationText binds both once per slot), tooltips, the native
--     dispel region.
--   rowTuningSig  — changes with the struct sig stable apply IN PLACE via
--     h:ApplyTuning (OOC immediate, combat defers to regen): max, native sort,
--     every candidateFilters facet — config-wide include/exclude spell maps,
--     maxDuration, per-record flags/dispel maps — and, since 2026-08-04, each
--     record's FILTER STRING. That last one is what makes buff-row "Only Mine"
--     (HELPFUL <-> HELPFUL|PLAYER) and the dispel row's All/By-Me token swap free:
--     same key, different string, no container recreated.
-- Everything in neither sig is a plain in-place ApplyStyle (cosmetics).
local function rowStructSig(cfg)
    local s = cfg.style
    return table.concat({
        filterStructSig(cfg.filter), tostring(cfg.tooltips),
        -- Duration text PRESENCE only. The region is create-once, so whether it exists
        -- stays structural.
        -- ☠ formatKey / zeroText / updateInterval used to sit here on the claim that
        -- "SetDurationText forwards them to the binding once per slot". That is FALSE
        -- against Blizzard's source: the setter is reset-then-apply and explicitly
        -- re-callable — OnLoad_Intrinsic says "Retain the duration text binding across
        -- reconfiguration". The freeze was our own _boundDur flag, now replaced by a
        -- spec-identity re-bind in bindNative that runs from ApplyStyle on both handle
        -- kinds. A format edit is a restyle.
        -- ★ formatKey was the costliest entry in the file: it folds in
        -- DF:GetAuraDurationUpdateInterval(), so ONE account-wide setting tore down and
        -- recreated every container on every frame.
        tostring(s.duration ~= nil),
        -- ☠ s.stacks.formatKey used to sit here and was DEAD. Nothing in the addon ever
        -- assigns it (only dur.formatKey is written anywhere), so it serialised to the
        -- constant "nil" and could never move the signature. It could not have mattered
        -- either: bindNative deliberately passes {} to SetApplicationCount and never
        -- forwards a stacks formatter at all, because a Lua formatter running on a
        -- secret stack count throws inside the engine's dirty pass.
        tostring(s.border ~= nil), tostring(s.cooldown and s.cooldown.show ~= false),
        tostring(s.dispel ~= nil),          -- native dispel border (region is create-once -> Rebuild)
        -- Wave 5b: the dispel spec hosts TWO independent create-once regions (colour
        -- ring + colourblind symbol) — presence of EACH is structural on its own
        -- (ApplyStyle can't create/remove either; the symbol bind is also bind-once).
        tostring(s.dispel and s.dispel.nativeBorder), tostring(s.dispel and s.dispel.nativeSymbol),
        -- Duration bar: the region is create-once, so PRESENCE is structural. So is the
        -- fill<->strip flip, which changes which construction is built.
        -- ☠ position/height/gap were structural on the theory that the strip's layout
        -- reservation could not re-derive live. It already does, on the live path:
        -- ApplyStyle -> backend:applyLayout -> buildGroupLayout -> stripReservation ->
        -- SetAuraGroupLayout, with applyContainerLayout re-deriving the start-side inset
        -- from the same call (and _dfPadApplied existing precisely to clear a stale inset
        -- "if a live restyle flips the strip to the far side"). styleButton_regions
        -- re-anchors the strip every pass for the same reason. They are cosmetics.
        tostring(s.bar ~= nil), tostring(s.bar and tostring(s.bar.fill)),
        -- Pandemic: the holder frame, its contents (a DF.Border vs a tint texture), the
        -- AddPandemicRegion bind and the flash animation are ALL create-once, so mode and
        -- flash are structural. Read off the built spec rather than the db, so an
        -- unsupported client (no spec) sigs identically to the feature being off.
        tostring(s.pandemic and s.pandemic.mode),
        tostring(s.pandemic and s.pandemic.flash),
    }, "|")
end

local function rowTuningSig(cfg)
    local cf = cfg.candidateFilters
    return table.concat({
        tostring(cfg.max),
        tostring(cfg.sort and cfg.sort.method),      -- live: SetAuraGroupSortMethod
        tostring(cfg.sort and cfg.sort.direction),
        includeSig(cf), excludeSig(cf), cfSig(cf),   -- config-wide candidateFilters (cfSig carries maxDuration)
        filterTuningSig(cfg.filter),                 -- per-record candidateFilters (debuff row)
    }, "|")
end

-- Drive the factory buff row for one frame. Creates the container lazily, hides the legacy
-- icons (no double row), keeps it on the frame's unit, and applies setting changes. The
-- container self-updates from UNIT_AURA, so there is no per-tick render here.
function DF:DriveBuffFactory(frame, db)
    local h = frame.buffFactory
    if not h then
        h = DF.AuraContainer:Create(frame, DF:BuildAuraRowConfig(db, "buff", {
            unit = frame.unit,
            frame = frame,   -- for the derived Aura Designer buff-bar dedup union
            filterList = BuildDirectBuffFilters(db),
        }))
        frame.buffFactory = h
        frame.dfBuffFactoryVersion = DF.auraLayoutVersion or 0
        if h then
            frame.buffFactoryStructSig = rowStructSig(h.config)
            frame.buffFactoryTuningSig = rowTuningSig(h.config)
        end
    end

    if not h then return end

    -- Row-level opacity (legacy per-icon buffAlpha; container-frame children multiply it).
    -- BUILD-ONCE-LEAVE-IT: the standing container's frame tree is written ONLY on actual
    -- change, never per-event — the combat-proven DF_AuraLab pattern builds once and lets
    -- Blizzard drive; DriveBuffFactory runs per UNIT_AURA/range tick, so unconditional
    -- writes here would re-touch the live tree many times a second in combat.
    local rowAlpha = db.buffAlpha or 1
    if frame.dfBuffFactoryAlpha ~= rowAlpha then
        frame.dfBuffFactoryAlpha = rowAlpha
        h:GetFrame():SetAlpha(rowAlpha)
    end

    -- Keep the container on the frame's current unit. OOC retargets immediately; in combat
    -- the factory defers the retarget, so hide the row until regen rather than show the
    -- previous unit's buffs. Hide via the PLAIN anchor frame (GetFrame():SetShown), NOT
    -- h:SetShown -- the latter also queues an 'enable' op which, paired with the queued
    -- 'retarget', would upgrade to a full rebuild (frame leak). The container's own
    -- OnShow/OnHide drive event (de)registration. (SetUnit combat-legality is queued for Krathe.)
    if h:GetUnit() ~= frame.unit then
        DF:Debug("AURAROW", "buff: retarget %s -> %s%s",
            tostring(h:GetUnit()), tostring(frame.unit),
            InCombatLockdown() and " (in combat: row hidden until regen)" or "")
        h:SetUnit(frame.unit)
        frame.dfBuffFactoryHidden = InCombatLockdown() or nil
    elseif frame.dfBuffFactoryHidden and not InCombatLockdown() then
        DF:Debug("AURAROW", "buff: regen, unhiding row after deferred retarget")
        frame.dfBuffFactoryHidden = nil
    end
    -- Show/hide only on state change (no per-event SetShown churn on the live tree).
    -- Through SetIntentShown, not the raw frame: intent must be recorded on the
    -- handle or the identity-gate sweep resurrects a hidden row (no enable op, so
    -- the queued-retarget frame leak SetShown carries does not apply).
    local rowShown = not frame.dfBuffFactoryHidden
    if frame.dfBuffFactoryShown ~= rowShown then
        frame.dfBuffFactoryShown = rowShown
        h:SetIntentShown(rowShown)
    end

    -- Apply setting changes only when the layout version actually bumped — and only OUT
    -- of combat. In combat the standing container is left completely alone (the lab's
    -- proven pattern: existing containers keep running in combat; every addon-side
    -- re-touch — restyle, rebuild, SetFrameLevel, formatter churn — is a divergence).
    -- The version stays stale so the first OOC drive catches up.
    local ver = DF.auraLayoutVersion or 0
    if frame.dfBuffFactoryVersion ~= ver and not InCombatLockdown() then
        frame.dfBuffFactoryVersion = ver
        local cfg = DF:BuildAuraRowConfig(db, "buff", {
            unit = frame.unit,
            frame = frame,   -- for the derived Aura Designer buff-bar dedup union
            filterList = BuildDirectBuffFilters(db),
        })
        -- Re-apply the z-order via the engine (buffs default to +40 = legacy parity). Frame Level
        -- is deliberately NOT in the sig, so a level-only change never reaches _build.
        h:ApplyZOrder(cfg)
        local structSig, tuningSig = rowStructSig(cfg), rowTuningSig(cfg)
        if frame.buffFactoryStructSig ~= structSig then
            -- "I changed a setting and nothing happened" is always answered by WHICH
            -- SIG MOVED. Both are already computed, and this only runs when the
            -- layout version bumped, so it is free at steady state.
            DF:Debug("AURAROW", "buff: REBUILD - struct sig %s -> %s",
                tostring(frame.buffFactoryStructSig), tostring(structSig))
            local prevStruct, prevTuning = frame.buffFactoryStructSig, frame.buffFactoryTuningSig
            frame.buffFactoryStructSig = structSig
            frame.buffFactoryTuningSig = tuningSig
            -- structSig doubles as the container PARKING key: its definition is exactly
            -- "changing this needs a new container", which is precisely the condition
            -- for safely re-adopting a parked one. A/B/A (profile swap, preset toggle,
            -- AutoProfiles zone transition) now reuses instead of stranding.
            -- ☠ SIGS RESTORED ON ERROR. An error mid-rebuild (e.g. a forbidden write
            -- during PvP prep) used to leave the NEW sig recorded against an OLD
            -- container — the edit silently stranded for the whole session, because
            -- every later drive compared equal and took the no-op branch. A restored
            -- sig makes the next drive simply retry.
            local okRB, errRB = pcall(h.Rebuild, h, cfg, structSig)   -- structural (filter set/regions/tooltips) — discrete, leak-safe
            if not okRB then
                frame.buffFactoryStructSig, frame.buffFactoryTuningSig = prevStruct, prevTuning
                DF:DebugWarn("AURAROW", "buff: rebuild failed (sig restored for retry): %s", tostring(errRB))
            end
        else
            if frame.buffFactoryTuningSig ~= tuningSig then
                DF:Debug("AURAROW", "buff: TUNING - tuning sig %s -> %s (struct unchanged)",
                    tostring(frame.buffFactoryTuningSig), tostring(tuningSig))
                frame.buffFactoryTuningSig = tuningSig
                -- Per-record filter STRINGS and candidateFilters both ride cfg.filter;
                -- the struct sig pins every record's KEY, so the fresh list is
                -- group-identical and applyGroupTuning re-derives both from it (keys
                -- line up with the declared groups). This is what makes "Only Mine"
                -- (HELPFUL <-> HELPFUL|PLAYER) a tune rather than a rebuild.
                h.config.filter = cfg.filter
                h:ApplyTuning(cfg)              -- max/sort/candidateFilters — in place, no leak
            end
            h:ApplyStyle(cfg.style, cfg.layout) -- cosmetics — in place, no leak
        end
    end
end

-- ============================================================
-- DEBUFF FACTORY BRIDGE (P3) — mirror of the buff bridge with debuff keys.
-- Filter list = the native direct-debuff filters; dispel colouring binds through
-- AddDispelTypeTexture (68914's replacement for the deprecated SetAuraBorder alias)
-- in the Color style, carrying customDispelColorMap — so custom per-type colours ARE
-- expressible and the account-wide Colors-page palette drives this row. (This comment
-- previously said the opposite and named the pickers as frosted; both were true on
-- 68824 and were fixed by the dispel round — the palette ships and the pickers are
-- live.) Debuff rows get NO spell-ID candidate filters: harmful spell-ID maps do
-- nothing on friendly frames (Meorawr gate).
-- ============================================================

-- Render gate (excludes test mode, which paints legacy icons directly).
function DF:UseFactoryForDebuffs(frame, db)
    return DF.AuraContainer and DF.AuraContainer.IsSupported()
        and not (DF.testMode or DF.raidTestMode)
        and not DF:MemTestDisabled("enableAuras")
end

-- GUI-facing predicate (does NOT exclude test mode — see FactoryOwnsBuffRow).
function DF:FactoryOwnsDebuffRow(db)
    return (DF.AuraContainer and DF.AuraContainer.IsSupported()) or false
end

-- Drive the factory debuff row for one frame. Structure identical to DriveBuffFactory
-- (see its comments for the build-once / combat-defer / version-gate reasoning).
--
-- Row-claim dedup (C1): the filter records are built with the Aura Designer's
-- claimed-category set (DF:GetClaimedDebuffCategories — nil when AD is off /
-- doesn't own AD / has no debuff groups), so categories an enabled AD debuff
-- group displays are dropped from the row. Claims fold into the row signature
-- for free — they change the RECORDS, and filterStructSig serializes the records
-- — so a claim/unclaim (which rides an auraLayoutVersion bump from the AD GUI's
-- structural refresh) re-enters the version gate below and rebuilds.
--
-- EMPTY-LIST PARK: claims can empty a non-empty selection (every selected
-- category claimed). normalizeFilters maps an EMPTY filter list back to
-- "HELPFUL" (show all), so an emptied row must never reach the container —
-- park instead: hide the plain anchor frame (combat-safe, no backend op) and
-- stamp dfDebuffFactoryEmptyVer so steady-state drives return without
-- rebuilding records. The next version bump re-evaluates the claims.
-- Merge the debuff blacklist (db.debuffBlacklist) into the debuff row's filter
-- records as excludeSpellIDs. ROW-ONLY (never the AD debuff-group facade). A nil
-- filterList (show-all) becomes one HARMFUL record carrying just the exclude; an
-- empty array (fully claimed) is left parked. Called in DriveDebuffFactory BEFORE
-- the row signature is taken, so a blacklist toggle moves cfSig and re-tunes the
-- row (cfSig now serializes excludeSpellIDs). No-op when nothing is blacklisted.
local function applyDebuffBlacklist(filterList, db)
    local blMap = DF.AuraBlacklist and DF.AuraBlacklist.BuildExcludeMap
        and DF.AuraBlacklist.BuildExcludeMap(db.debuffBlacklist)
    if not blMap then return filterList end
    if filterList == nil then
        return { { filter = "HARMFUL", key = "bl", candidateFilters = { excludeSpellIDs = blMap } } }
    end
    if #filterList == 0 then return filterList end   -- fully claimed: nothing to exclude from
    for i = 1, #filterList do
        local rec = filterList[i]
        local cf = rec.candidateFilters or {}
        cf.excludeSpellIDs = blMap
        rec.candidateFilters = cf
    end
    return filterList
end

function DF:DriveDebuffFactory(frame, db)
    local ver = DF.auraLayoutVersion or 0
    if frame.dfDebuffFactoryEmptyVer then
        if frame.dfDebuffFactoryEmptyVer == ver or InCombatLockdown() then return end
        frame.dfDebuffFactoryEmptyVer = nil   -- version moved: fall through and re-evaluate
    end

    -- ★ PER-FRAME IMPORTANT-HIGHLIGHT OPT-OUT (preview only; nothing sets this stamp on a
    -- live frame). The enlarged + badged treatment is right for a real row but wrong on
    -- EVERY preview frame at once: it swamped the raid grid, and on the party tank it sat
    -- over the AFK countdown (Krathe, 2026-08-08).
    --
    -- ⚠ Done by SHADOWING ONE KEY, not by threading a flag through the resolver, because
    -- the resolver already gates on exactly this key and the Aura Designer facade already
    -- suppresses the treatment the same way (a db carrying no debuffImportant* keys).
    -- That facade is also the proof this is safe: it is a FLAT scratch table, so
    -- BuildDirectDebuffFilters reads plain scalar keys synchronously and never pairs()
    -- the db -- an __index proxy is indistinguishable to it.
    --
    -- Cached per frame and re-made only when the source db identity changes (profile or
    -- mode switch), so this costs one table for the life of the frame rather than one per
    -- update. ⚠ Tri-state: nil means "use the normal rule", only an explicit false opts out.
    if frame.dfTestShowImportantDebuff == false then
        if frame.dfNoImportantSrcDb ~= db then
            frame.dfNoImportantDb = setmetatable({ debuffImportantHighlight = false },
                                                 { __index = db })
            frame.dfNoImportantSrcDb = db
        end
        db = frame.dfNoImportantDb
    end

    local h = frame.debuffFactory
    if not h then
        local filterList = BuildDirectDebuffFilters(db,
            DF.GetClaimedDebuffCategories and DF:GetClaimedDebuffCategories(frame, db))
        filterList = applyDebuffBlacklist(filterList, db)
        if filterList and #filterList == 0 then
            frame.dfDebuffFactoryEmptyVer = ver   -- fully claimed: no container at all
            return
        end
        h = DF.AuraContainer:Create(frame, DF:BuildAuraRowConfig(db, "debuff", {
            unit = frame.unit,
            filterList = filterList,
        }))
        frame.debuffFactory = h
        frame.dfDebuffFactoryVersion = ver
        if h then
            frame.debuffFactoryStructSig = rowStructSig(h.config)
            frame.debuffFactoryTuningSig = rowTuningSig(h.config)
        end
    end

    if not h then return end

    local rowAlpha = db.debuffAlpha or 1
    if frame.dfDebuffFactoryAlpha ~= rowAlpha then
        frame.dfDebuffFactoryAlpha = rowAlpha
        h:GetFrame():SetAlpha(rowAlpha)
    end

    if h:GetUnit() ~= frame.unit then
        DF:Debug("AURAROW", "debuff: retarget %s -> %s%s",
            tostring(h:GetUnit()), tostring(frame.unit),
            InCombatLockdown() and " (in combat: row hidden until regen)" or "")
        h:SetUnit(frame.unit)
        frame.dfDebuffFactoryHidden = InCombatLockdown() or nil
    elseif frame.dfDebuffFactoryHidden and not InCombatLockdown() then
        DF:Debug("AURAROW", "debuff: regen, unhiding row after deferred retarget")
        frame.dfDebuffFactoryHidden = nil
    end
    local rowShown = not frame.dfDebuffFactoryHidden
    if frame.dfDebuffFactoryShown ~= rowShown then
        frame.dfDebuffFactoryShown = rowShown
        h:SetIntentShown(rowShown)   -- intent-recorded hide; see the buff drive
    end

    if frame.dfDebuffFactoryVersion ~= ver and not InCombatLockdown() then
        frame.dfDebuffFactoryVersion = ver
        local filterList = BuildDirectDebuffFilters(db,
            DF.GetClaimedDebuffCategories and DF:GetClaimedDebuffCategories(frame, db))
        filterList = applyDebuffBlacklist(filterList, db)
        if filterList and #filterList == 0 then
            -- Fully claimed while a container stands: park it hidden (intent-recorded,
            -- combat-safe) until a version bump changes the claim set.
            h:SetIntentShown(false)
            frame.dfDebuffFactoryShown = false
            frame.dfDebuffFactoryEmptyVer = ver
            return
        end
        local cfg = DF:BuildAuraRowConfig(db, "debuff", {
            unit = frame.unit,
            filterList = filterList,
        })
        -- Re-apply the z-order via the engine. Frame Level is deliberately NOT in the sig,
        -- so a level-only change never reaches _build.
        h:ApplyZOrder(cfg)
        local structSig, tuningSig = rowStructSig(cfg), rowTuningSig(cfg)
        if frame.debuffFactoryStructSig ~= structSig then
            -- "I changed a setting and nothing happened" is always answered by WHICH
            -- SIG MOVED. Both are already computed, and this only runs when the
            -- layout version bumped, so it is free at steady state.
            DF:Debug("AURAROW", "debuff: REBUILD - struct sig %s -> %s",
                tostring(frame.debuffFactoryStructSig), tostring(structSig))
            local prevStruct, prevTuning = frame.debuffFactoryStructSig, frame.debuffFactoryTuningSig
            frame.debuffFactoryStructSig = structSig
            frame.debuffFactoryTuningSig = tuningSig
            -- Sigs restored on error — see the buff drive above.
            local okRB, errRB = pcall(h.Rebuild, h, cfg, structSig)   -- structural — REPLACES the config wholesale (structSig = park key)
            if not okRB then
                frame.debuffFactoryStructSig, frame.debuffFactoryTuningSig = prevStruct, prevTuning
                DF:DebugWarn("AURAROW", "debuff: rebuild failed (sig restored for retry): %s", tostring(errRB))
            end
        else
            if frame.debuffFactoryTuningSig ~= tuningSig then
                DF:Debug("AURAROW", "debuff: TUNING - tuning sig %s -> %s (struct unchanged)",
                    tostring(frame.debuffFactoryTuningSig), tostring(tuningSig))
                frame.debuffFactoryTuningSig = tuningSig
                -- hideLong minutes / Keep Important within a stable category set
                -- live in the RECORDS' candidateFilters — swap the (group-identical)
                -- list so applyGroupTuning re-derives them (see the buff driver).
                h.config.filter = cfg.filter
                h:ApplyTuning(cfg)              -- max/sort/candidateFilters — in place, no leak
            end
            h:ApplyStyle(cfg.style, cfg.layout) -- cosmetics — in place, no leak
        end
    end
end

-- ============================================================
-- PLAYER DEAD STATE (tracked, diagnostic)
-- ============================================================
-- Written ONLY by PLAYER_DEAD / PLAYER_ALIVE / PLAYER_UNGHOST and seeded at
-- PLAYER_ENTERING_WORLD (Core.lua) — the DF.playerInCombat convention, and never a raw
-- UnitIsDeadOrGhost read at the point of use, which would be right only on whichever pass
-- happened to follow the transition.
--
-- ⚠ NOTHING ACTS ON THIS TODAY, ON PURPOSE. The filter change that did (c46e4771) rested
-- on an unverified reading of the RAID token and was reverted — see neg() in
-- BuildDirectDebuffFilters. The state stays because the AURAROW overflow watch stamps it
-- on every line, and "did this row break on the death edge" is the question a capture has
-- to answer. Give it a consumer again only once a log says which way the token moves.
function DF:SetPlayerDeadState(dead)
    dead = dead and true or false
    if DF.playerIsDead == dead then return end
    DF.playerIsDead = dead
    DF:Debug("AURAROW", "player dead state -> %s", tostring(dead))
end

-- ============================================================
-- DEFENSIVE-ICON FACTORY BRIDGE (pilot — first non-buff consumer)
-- Routes the defensive row through DF.AuraContainer on 12.1 using the native
-- BIG_DEFENSIVE / EXTERNAL_DEFENSIVE filters. Reuses the buff bridge's config SHAPE
-- + rowStructSig/rowTuningSig (the element-agnostic row signatures). Defensive settings have a
-- different key layout (defensiveIcon* + defensiveBar*), so they get a dedicated
-- mapper rather than the prefix builder. Native-only on 12.1 (requires
-- on) + IsSupported → no effect on live 12.0.x.
-- Known v1 gaps (native filters can't exclude specific instances until PTR-4):
-- no AD/buff dedup, no range fade, CENTER growth falls back to RIGHT.
-- ============================================================

-- Render gate (excludes test mode, which paints legacy icons directly).
function DF:UseFactoryForDefensive(frame, db)
    return DF.AuraContainer and DF.AuraContainer.IsSupported()
        and BuildDirectDefensiveFilters() ~= nil
        and not (DF.testMode or DF.raidTestMode)
        and not DF:MemTestDisabled("enableDefensive")
end

-- GUI-facing predicate (does NOT exclude test mode, so a "blocked" overlay doesn't
-- flicker while previewing). Mirrors DF:FactoryOwnsBuffRow.
function DF:FactoryOwnsDefensiveRow(db)
    return (DF.AuraContainer and DF.AuraContainer.IsSupported()
        and BuildDirectDefensiveFilters() ~= nil) or false
end

-- Map the defensive settings -> the AuraContainer config SHAPE. Filter = the native
-- defensive list the legacy classifier already uses; a row of up to defensiveBarMax
-- icons. Stacks use the legacy min-2 display. rowStructSig/rowTuningSig treat this cfg
-- the same as a buff cfg (they read derived fields, not db keys).
function DF:BuildDefensiveRowConfig(db, unit)
    local iconSize = db.defensiveIconSize or 24
    local dur
    if db.defensiveIconShowDuration ~= false then
        -- Colour-by-time mode + curve (see the buff/debuff row builder for the mechanism).
        local colorMode = DF:ResolveDurationColorMode(db.defensiveIconDurationColorByTime)
        local colorSpec = DF:GetDurationColorSpec(colorMode)
        local colorByTime = DF:DurationColorUsesBuckets(colorMode)
        -- Shared TextStyle spec (picks up defensiveIconDurationFont/Scale/Outline/X/Y/
        -- JustifyH/JustifyV/Color); feature fields ride on top.
        dur = DF.TextStyle:BuildSpec(db, "defensiveIconDuration", {
            baseSize = 10, defaultAnchor = "CENTER", boxW = iconSize, boxH = iconSize,
        })
        dur.show = true
        dur.stableCenter = true   -- centred countdown: stable box, no shift, no wobble
        local defFormat = db.defensiveIconDurationFormat or "NUMBER"
        dur.formatter, dur.textFormat = DF:GetDurationFormatFields(defFormat, nil, colorByTime)
        if colorSpec then dur.color = nil end
        dur.colorCurve, dur.colorProperty = (colorSpec and colorSpec.curve), (colorSpec and colorSpec.property)
        dur.formatKey = defFormat .. DF:GetDurationColorSig(colorMode)
        -- Hide duration text on permanent auras (Wave 4, default ON — see the
        -- buff/debuff row builder for the mechanism notes).
        if db.defensiveIconDurationHideOnPermanent ~= false then dur.zeroText = "" end
        -- Duration-text update rate (Wave 5a, account-wide; nil at the NORMAL default).
        dur.updateInterval = DF:GetAuraDurationUpdateInterval()
    end

    -- FILTER REGISTRY: the category selection drives the row as ONE plain HELPFUL
    -- group + a spell-ID map (include = selected presets/customs; exclude =
    -- Uncategorised complement). "all" (empty/absent selection) keeps the legacy
    -- token fallback below — the pre-registry behavior, byte-for-byte.
    -- SINGLE group (12.1): overlapping groups render DUPLICATE buttons — the container
    -- has no cross-group dedup and addon-side dedup is impossible (button contents are
    -- secret). Guardian Spirit proved BIG ∩ EXTERNAL ≠ ∅; externals are classified as
    -- big defensives (Blizzard's BigDefensive comparator expects them in ONE list), so
    -- one BIG_DEFENSIVE group covers the row with no dupes. Legacy/test mode keeps the
    -- two-filter scan + Lua dedup (BuildDirectDefensiveFilters) — different pipeline.
    -- IN-GAME CHECK: if an external-only defensive (e.g. PS/Ironbark on someone) stops
    -- showing, external ⊄ big on this build — revert to BuildDirectDefensiveFilters().
    local factoryFilter, defensiveCandidates
    local res = DF.FilterRegistry:ResolveSelection(db.defensiveFilterSelection, false)
    if res.kind == "include" then
        factoryFilter = { "HELPFUL" }
        defensiveCandidates = { includeSpellIDs = res.map }
    elseif res.kind == "exclude" then
        factoryFilter = { "HELPFUL" }
        defensiveCandidates = { excludeSpellIDs = res.map }
    else -- "all": legacy token fallback (empty selection safety net)
        if AuraFilters.BigDefensive then factoryFilter = { "HELPFUL|" .. AuraFilters.BigDefensive }
        elseif AuraFilters.ExternalDefensive then factoryFilter = { "HELPFUL|" .. AuraFilters.ExternalDefensive }
        else
            -- ☠ NEVER FALL THROUGH TO "NO FILTER". Reaching here means neither the
            -- registry NOR the Blizzard tokens could answer, and leaving both
            -- factoryFilter and defensiveCandidates nil hands normalizeFilters a
            -- nil list -- whose last-ditch default is a bare `{ f = "HELPFUL" }`.
            -- That renders EVERY helpful aura in the defensive slot, which is what
            -- the 12.1-launch reports were (see the AuraFilters note at the top of
            -- this file). Failing OPEN on a filter is the worst possible direction.
            --
            -- ⚠ But an EMPTY row is nearly as bad for someone who enabled the
            -- feature, so resolve the SHIPPED DEFAULT selection first: that gives a
            -- working defensive row from the curated presets rather than a dead one.
            -- Only if that also comes back empty do we render nothing -- which at
            -- that point means the spell DB itself is unavailable and there is
            -- genuinely nothing correct to show.
            --   ⚠ PartyDefaults deliberately: defensiveFilterSelection is not among
            -- the raid overrides, so RaidDefaults' copy is identical. If a raid-
            -- specific default is ever added, this needs the mode-correct table.
            factoryFilter = { "HELPFUL" }
            local dflt = DF.PartyDefaults and DF.PartyDefaults.defensiveFilterSelection
            local dres = dflt and DF.FilterRegistry:ResolveSelection(dflt, false)
            if dres and dres.kind == "include" and next(dres.map) then
                defensiveCandidates = { includeSpellIDs = dres.map }
                -- Count behind DebugActive: arguments evaluate before DebugWarn can
                -- short-circuit, and this builder runs per frame.
                if DF.DebugActive and DF:DebugActive("AURAROW") then
                    local n = 0
                    for _ in pairs(dres.map) do n = n + 1 end
                    DF:DebugWarn("AURAROW", "defensive: no registry selection and no Blizzard tokens -- fell back to the shipped default preset set (%d ids)", n)
                end
            else
                -- Render NOTHING rather than everything. Loud, because this means
                -- the filter registry answered nothing for the shipped defaults.
                defensiveCandidates = { includeSpellIDs = {} }
                DF:DebugWarn("AURAROW", "defensive: no selection, no tokens, and the default preset set resolved EMPTY -- rendering nothing (check the FilterRegistry spell DB)")
            end
        end
    end

    return {
        unit     = unit,
        mode     = "row",
        adBorderAnim = true,   -- opt into DF-owned border animations (see buildPlacedConfig)
        filter   = factoryFilter or BuildDirectDefensiveFilters(),
        candidateFilters = defensiveCandidates,
        max      = db.defensiveBarMax or 4,
        enabled  = true,
        -- Native sort per the Sort Order dropdown (tuning-only — the filter string
        -- never moves with it). EXTERNALS (the default) = the shipped BigDefensive
        -- order: longest-duration external first, own defensives last
        -- (AuraUtil.BigDefensiveAuraCompare) — "show me the save someone else put
        -- on this player". TIME = soonest-to-expire first (ExpirationOnly).
        -- DEFAULT = nil = Blizzard's inbound slot order.
        sort     = (function()
            local o = db.defensiveSortOrder
            if o == "DEFAULT" then return nil end
            if o == "TIME" then return { method = "ExpirationOnly" } end
            return { method = "BigDefensive" }
        end)(),
        -- P5 preview: HELPFUL category alone would page the buff pool — show
        -- curated defensives instead.
        testPool = "defensives",
        -- ☠ The line above used to end "(TestMode drives testMax per role)". It did
        -- NOT — nothing ever set testMax here, so the preview fell through to the row's
        -- full `max` and declared one AuraGroup per icon, each eagerly allocating ten
        -- buttons, for a curated pool of FOUR defensives. Another comment asserting a
        -- behaviour no code implemented.
        -- ⚠ It was then capped at `testBuffCount` on the reasoning "this is a HELPFUL
        -- row, so the Buffs count is the one the user set for it". That is wrong from
        -- the user's side: nothing on the panel says the Buffs slider governs the
        -- defensive icon, so the row silently drew 2 while its own Max Icons read 5.
        -- It has its own count now (default 1). ☠ Keep this in step with the
        -- SetTestMax in TestMode.lua's defensive drive — two writers, one value.
        testMax = db.testDefensiveCount or 0,
        tooltips = db.tooltipDefensiveEnabled ~= false,
        -- Z-order: an ABSOLUTE offset from the unit frame. Highest of the aura surfaces, so a
        -- defensive cue is never buried. Applied via h:ApplyZOrder(cfg) at Create + re-apply.
        --
        -- ★ 65, NOT the legacy 51 (fixed 2026-07-25 from a /df debug zorder dump). A row is not one
        -- level thick: the anchor sits at +offset, Blizzard's container at +1, its buttons at
        -- +2, and DF's own slot art stacks ON the button — border +10, duration text +13,
        -- stack text +14. So ONE row occupies ~16 levels. At 51 the buff/debuff rows (40)
        -- reached 60 while the defensive BUTTON sat at 57, so debuff borders and text drew
        -- OVER the defensive icon wherever the rows overlapped. Any new row baseline must
        -- clear the one below it by at least ~17.
        frameLevelOffset = db.defensiveIconFrameLevel or 65,
        layout = {
            size     = db.defensiveIconSize or 24,
            scale    = db.defensiveIconScale or 1,
            spacingX = db.defensiveBarSpacing or 2,
            spacingY = db.defensiveBarSpacing or 2,
            anchor   = db.defensiveIconAnchor or "CENTER",
            growth   = db.defensiveBarGrowth or "RIGHT_DOWN",
            wrap     = db.defensiveBarWrap or 5,
            offsetX  = db.defensiveIconX or 0,
            offsetY  = db.defensiveIconY or 0,
            preScaledStep = false,   -- legacy defensive spacing (unscaled size term; no double-scale)
        },
        style = {
            icon   = { show = true, zoom = true, inset = 0 },
            border = (db.defensiveIconShowBorder ~= false) and { db = db, prefix = "defensiveIcon" } or nil,
            cooldown = { show = not db.defensiveIconHideSwipe, reverse = true, edge = false, numbers = false },
            duration = dur,
            -- Tooltip placement + combat-hide (Tooltips page) — see the buff row.
            tooltip  = buildTooltipSpec(db, "Defensive"),
            -- Duration bar strip (nil when disabled — byte-neutral; see the buff row).
            bar      = DF:BuildDurationBarSpec(db, "defensiveDurationBar"),
            -- Shared TextStyle spec, same as the buff and debuff rows. This was a
            -- hardcoded table whose own comment read "defensive stacks have no db keys —
            -- legacy fixed look", which is precisely what a user ran into: 12.1 pushed
            -- some stack counts to three digits and only the DURATION text could be
            -- resized.
            -- ☠ THE DEFAULTS RENDER IDENTICALLY TO THAT TABLE: baseSize 14 × Scale 1 =
            -- 14, same anchor and offsets, Outline defaulted to "OUTLINE" in Config.
            -- Color gets NO default on purpose — an absent key reads nil and TextStyle
            -- leaves the colour alone, exactly as the old table did by omission.
            -- ⚠ Font DOES have a Config default now ("DF Roboto SemiBold", 2026-08-22).
            -- This comment used to claim a nil font meant "DF default font"; it did not
            -- — SafeSetFont resolves nil to FRIZQT__ (the Blizzard fallback), so unset
            -- profiles were rendering the stack count in a different font from every
            -- other DF text element. The seed makes the house font explicit, and the
            -- deliberate restyle is the point (Krathe), not an accident to avoid.
            -- No formatter: forbidden on container rows (secret trap — see the
            -- GetStacksFormatter tombstone above). Native default = counts > 1.
            stacks = (function()
                local st = DF.TextStyle:BuildSpec(db, "defensiveIconStack", {
                    baseSize = 14, defaultAnchor = "BOTTOMRIGHT",
                    defaultOffsetX = 2, defaultOffsetY = -1,
                    boxW = db.defensiveIconSize or 24, boxH = db.defensiveIconSize or 24,
                })
                st.show = true
                return st
            end)(),
        },
    }
end

-- Drive the factory defensive row for one frame. Mirrors DriveBuffFactory: lazy create,
-- hide the legacy defensive pool (no double render), keep on the frame's unit, re-apply
-- on a layout-version bump. The container self-updates from UNIT_AURA (no per-tick render).
function DF:DriveDefensiveFactory(frame, db)
    local h = frame.defensiveFactory
    if not h then
        h = DF.AuraContainer:Create(frame, DF:BuildDefensiveRowConfig(db, frame.unit))
        frame.defensiveFactory = h
        frame.dfDefFactoryVersion = DF.auraLayoutVersion or 0
        if h then
            frame.defensiveFactoryStructSig = rowStructSig(h.config)
            frame.defensiveFactoryTuningSig = rowTuningSig(h.config)
        end
    end

    if not h then return end

    -- Keep on the frame's unit; defer a wrong-unit show until regen in combat. Hide via
    -- h:SetIntentShown, NOT h:SetShown -- the latter queues an enable op that would
    -- upgrade a queued retarget into a full rebuild (frame leak). SetIntentShown is the
    -- op-free variant that still records intent, so the gate sweep can't resurrect it.
    if h:GetUnit() ~= frame.unit then
        DF:Debug("AURAROW", "defensive: retarget %s -> %s%s",
            tostring(h:GetUnit()), tostring(frame.unit),
            InCombatLockdown() and " (in combat: row hidden until regen)" or "")
        h:SetUnit(frame.unit)
        frame.dfDefFactoryHidden = InCombatLockdown() or nil
    elseif frame.dfDefFactoryHidden and not InCombatLockdown() then
        DF:Debug("AURAROW", "defensive: regen, unhiding row after deferred retarget")
        frame.dfDefFactoryHidden = nil
    end
    -- Show/hide only on state change (no per-event SetShown churn on the live tree —
    -- build-once-leave-it, mirrors DriveBuffFactory).
    local rowShown = not frame.dfDefFactoryHidden
    if frame.dfDefFactoryShown ~= rowShown then
        frame.dfDefFactoryShown = rowShown
        h:SetIntentShown(rowShown)
    end

    -- Re-apply settings only on a layout-version bump (defensive option changes bump it
    -- via UpdateAllDefensiveBars -> InvalidateAuraLayout) — and only OUT of combat: the
    -- standing container is never re-touched in lockdown (lab parity); the stale version
    -- catches up on the first OOC drive.
    local ver = DF.auraLayoutVersion or 0
    if frame.dfDefFactoryVersion ~= ver and not InCombatLockdown() then
        frame.dfDefFactoryVersion = ver
        local cfg = DF:BuildDefensiveRowConfig(db, frame.unit)
        -- Re-apply the z-order via the engine (honors runtime defensiveIconFrameLevel changes).
        -- Frame Level is deliberately NOT in the sig, so a level-only change never reaches _build.
        h:ApplyZOrder(cfg)
        local structSig, tuningSig = rowStructSig(cfg), rowTuningSig(cfg)
        if frame.defensiveFactoryStructSig ~= structSig then
            -- "I changed a setting and nothing happened" is always answered by WHICH
            -- SIG MOVED. Both are already computed, and this only runs when the
            -- layout version bumped, so it is free at steady state.
            DF:Debug("AURAROW", "defensive: REBUILD - struct sig %s -> %s",
                tostring(frame.defensiveFactoryStructSig), tostring(structSig))
            local prevStruct, prevTuning = frame.defensiveFactoryStructSig, frame.defensiveFactoryTuningSig
            frame.defensiveFactoryStructSig = structSig
            frame.defensiveFactoryTuningSig = tuningSig
            -- Sigs restored on error — see the buff drive above.
            local okRB, errRB = pcall(h.Rebuild, h, cfg, structSig)   -- structural (filter set/regions/tooltips); structSig = park key
            if not okRB then
                frame.defensiveFactoryStructSig, frame.defensiveFactoryTuningSig = prevStruct, prevTuning
                DF:DebugWarn("AURAROW", "defensive: rebuild failed (sig restored for retry): %s", tostring(errRB))
            end
        else
            if frame.defensiveFactoryTuningSig ~= tuningSig then
                DF:Debug("AURAROW", "defensive: TUNING - tuning sig %s -> %s (struct unchanged)",
                    tostring(frame.defensiveFactoryTuningSig), tostring(tuningSig))
                frame.defensiveFactoryTuningSig = tuningSig
                h.config.filter = cfg.filter    -- group-identical records (see the buff driver)
                h:ApplyTuning(cfg)              -- max/sort/candidateFilters — in place, no leak
            end
            h:ApplyStyle(cfg.style, cfg.layout) -- cosmetics — in place, no leak
        end
    end
end

-- ============================================================
-- MISSING-BUFF FACTORY BRIDGE — read-free layout-push inversion (probe 32,
-- live-confirmed 2026-07-10). One "missing"-mode handle per tracked raid buff:
-- an empty spellID-filtered group parks the badge inside a clip window; the
-- buff's (blank) button pushes it out. ZERO aura reads — works in combat on
-- every assistable unit, independent of the transitional whitelist. Replaces
-- the legacy UnitHasBuff 4-method scan on 12.1.
-- Behaviour change vs legacy (flagged in the port plan §2.5): manual multi-buff
-- mode shows EVERY tracked-and-missing buff as a strip of badges — the old
-- "first missing only" priority pick was a cross-aura read, which is dead.
-- Class-detection mode (one buff) is identical to legacy.
-- ============================================================

local MISSING_BADGE_SIZE = 24   -- fallback when missingBuffIconSize is unset; missingBuffIconScale scales the strip
local MISSING_BADGE_GAP  = 2

-- Render gate (excludes test mode; the test drive calls the factory itself).
function DF:UseFactoryForMissingBuff(frame, db)
    return DF.AuraContainer and DF.AuraContainer.IsSupported()
        and not (DF.testMode or DF.raidTestMode)
        and not DF:MemTestDisabled("enableMissingBuff")
end

-- GUI-facing predicate (does NOT exclude test mode — see FactoryOwnsBuffRow).
function DF:FactoryOwnsMissingBuff(db)
    return (DF.AuraContainer and DF.AuraContainer.IsSupported()) or false
end

-- Tracked raid buffs per settings: class-detection = only YOUR class's buff;
-- manual = every enabled missingBuffCheck* key. Returns DF.RaidBuffs entries
-- ({spellIDOrTable, configKey, name, class}) in DF.RaidBuffs order.
local function missingTrackedBuffs(db)
    local list = {}
    local playerKey
    if db.missingBuffClassDetection then
        playerKey = DF.ClassToRaidBuff and DF.ClassToRaidBuff[select(2, UnitClass("player"))]
        if not playerKey then return list end   -- class has no raid buff -> nothing to track
    end
    for i = 1, #DF.RaidBuffs do
        local info = DF.RaidBuffs[i]
        if (playerKey and info[2] == playerKey) or (not playerKey and db[info[2]]) then
            list[#list + 1] = info
        end
    end
    return list
end

-- Structural signature: the tracked set (cell handles are created per entry).
local function missingFactorySig(tracked)
    local keys = {}
    for i = 1, #tracked do keys[i] = tracked[i][2] end
    return table.concat(keys, ",")
end

-- Per-cell container config: HELPFUL + includeSpellIDs (any rank/variant ID of
-- the tracked buff matches). Helpful spell-ID maps apply on assistable units —
-- exactly the frames this feature targets (the badge is guard-hidden elsewhere).
local function buildMissingCellConfig(info, unit, size)
    local ids = type(info[1]) == "table" and info[1] or { info[1] }
    local map = {}
    for i = 1, #ids do map[ids[i]] = true end
    return {
        unit = unit,
        mode = "missing",
        filter = "HELPFUL",
        candidateFilters = { includeSpellIDs = map },
        badge = { w = size, h = size },
        -- ☠ MUST BE EXPLICIT, AND MUST BE 0. ApplyZOrder does
        -- `parent:GetFrameLevel() + (frameLevelOffset or 40)`, and this is the ONE
        -- Create site whose parent is not the unit frame but an already-offset
        -- child of it: the strip, which layoutMissingStrip puts at
        -- frame + missingBuffIconFrameLevel. Omitting the key therefore stacked a
        -- SECOND +40 on top — at the default 35 the badges rendered at frame+75 and
        -- drew over the defensive row at 65, and the Frame Level slider was off by
        -- 40 at every setting (Krathe, 2026-08-07). 0 puts the cells on the strip's
        -- own level, which is what the setting says. Every other Create with a
        -- non-frame parent already passes an explicit offset — swept 2026-08-07.
        frameLevelOffset = 0,
        enabled = true,
    }
end

-- Outward reach (px) of the missing-buff border animation — how far it extends BEYOND
-- the icon. The clip window keeps this much transparent margin around the badge so the
-- animation shows outside the icon when the buff is missing, and the layout-push grows to
-- match so it does NOT leak onto buffed units (the badge + its spill both clear the window
-- when the buff is present). Returns 0 when there's no border animation, so a non-animated
-- badge keeps the exact icon-sized window as before. Conservative — over-estimating is
-- harmless (the extra margin is transparent, and a bigger push still just clips off-window):
--   negative inset pushes the art out · offset shifts it · the effect's own glow/particles
--   reach ~half the icon at scale 1.
local function missingAnimSpill(db, badgeSize)
    if db.missingBuffIconShowBorder == false then return 0 end
    local t = db.missingBuffIconBorderAnimationType
    if not t or t == "NONE" then return 0 end
    local inset = db.missingBuffIconBorderAnimationInset or 0
    local offX  = math.abs(db.missingBuffIconBorderAnimationOffsetX or 0)
    local offY  = math.abs(db.missingBuffIconBorderAnimationOffsetY or 0)
    local scale = math.max(1, db.missingBuffIconBorderAnimationScale or 1)
    -- The anim rect (host) is the icon inset-adjusted by the animation inset (negative =
    -- larger). Some effects flare well past their steady state during the one-shot INTRO —
    -- Proc's contracting burst (PROC_BURST_SCALE 150/42 of the host) and Flash's opening
    -- outer glow (2F, F = host*1.4) — so size the window to the intro, not the loop, else
    -- the intro clips at the window edge. Others hug the border ~half the icon.
    local host = badgeSize - 2 * inset
    local artOut
    if t == "DF_PROC" then
        artOut = (host * (150 / 42) - badgeSize) / 2
    elseif t == "DF_FLASH" then
        artOut = (host * 2 * 1.4 - badgeSize) / 2
    else
        artOut = math.max(0, -inset) + badgeSize * 0.5 * scale
    end
    local out = math.max(0, artOut) + math.max(offX, offY)
    out = math.min(badgeSize * 5, math.max(0, math.ceil(out)))
    -- pp: the spill enters the badge's anchor offsets and the window size — a
    -- fractional-pixel spill shifts the badge off the grid (uneven border). Snap
    -- it in the strip's scaled space like the badge size/pitch.
    if out > 0 and db.pixelPerfect and DF.PixelPerfect then
        local ss = db.missingBuffIconScale or 1.5
        out = DF:PixelPerfect(out * ss) / ss
    end
    return out
end

-- Paint one cell's badge: spell icon + unified DF.Border (missingBuffIcon* keys).
-- The badge frame's POSITION derives from the container's secret size (§20c):
-- never pixel-snap it or read its rect; secretRect borders render anchor-only.
-- Animation is stripped like the container rows (expiry-triggered anim is dead
-- and the badge should match the aura buttons' treatment).
local function styleMissingBadge(h, db, frame, info)
    local badge = h.GetBadgeFrame and h:GetBadgeFrame()
    if not badge then return end
    local firstID = type(info[1]) == "table" and info[1][1] or info[1]
    if not badge.dfIcon then
        badge.dfIcon = badge:CreateTexture(nil, "ARTWORK")
        badge.dfIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    local iconTex
    if C_Spell and C_Spell.GetSpellTexture then iconTex = C_Spell.GetSpellTexture(firstID)
    elseif GetSpellTexture then iconTex = GetSpellTexture(firstID) end
    badge.dfIcon:SetTexture(iconTex)

    local showBorder = db.missingBuffIconShowBorder ~= false
    -- pp: no manual pre-snap here — the badge renders inside the strip's SetScale
    -- (layoutMissingStrip), so Border:Apply snaps via spec.renderScale below and the
    -- art inset goes through the same SnapThickness so both land identically.
    local borderSize = db.missingBuffIconBorderSize or 2
    if not badge.dfBorder then
        badge.dfBorder = DF.Border:New(badge, { frameLevelOffset = 0, secretRect = true })
    end
    local spec = DF.Border:BuildSpec(db, "missingBuffIcon", { unit = frame.unit, frame = frame, iconMode = true })
    spec.enabled = showBorder
    spec.size = borderSize
    spec.renderScale = db.missingBuffIconScale or 1.5   -- the strip's SetScale (layoutMissingStrip)
    -- DF_DASH sizes its dash layout from the border's frame width/height; the badge's
    -- rect is SECRET (secretRect on the container button subtree, reading it taints), so
    -- feed the configured badge size for the dash math to use instead.
    spec.knownWidth = db.missingBuffIconSize or MISSING_BADGE_SIZE
    spec.knownHeight = spec.knownWidth
    -- Animate only via the DF-owned (taint-safe) types — the LCG glows SetParent
    -- their pooled frames onto the secretRect badge, which is forbidden on the native
    -- button subtree. Continuous animation is safe now: the shared anim driver hosts on
    -- UIParent and the badge's border is torn down in _teardownContainer's StopAnimation
    -- pass (the GUI already hides the LCG types; this guards stale/imported profiles).
    local safeAnim = DF.AuraContainer and DF.AuraContainer.SAFE_BORDER_ANIM
    if spec.animation and not (safeAnim and safeAnim[spec.animation.type]) then
        spec.animation = nil
    end
    DF.Border:Apply(badge.dfBorder, spec)

    local artInset = showBorder
        and DF.Border:SnapThickness(borderSize, db.pixelPerfect, spec.renderScale) or 0
    badge.dfIcon:ClearAllPoints()
    badge.dfIcon:SetPoint("TOPLEFT", artInset, -artInset)
    badge.dfIcon:SetPoint("BOTTOMRIGHT", -artInset, artInset)
end

-- pp: the badge subtree renders under the strip's SetScale — quantize the badge
-- size in that scaled space so every cell window / badge edge lands on whole
-- physical pixels. Field-caught (/df debug ppdump): a raw size rendered the cell at
-- 28.13 physical px — the right/top edges straddled the grid and the badge
-- border drew visibly thicker on one side.
local function missingBadgeSizeFor(db)
    local size = db.missingBuffIconSize or MISSING_BADGE_SIZE
    if db.pixelPerfect and DF.PixelPerfect then
        local ss = db.missingBuffIconScale or 1.5
        size = DF:PixelPerfect(size * ss) / ss
    end
    return size
end

-- Whole-pixel cell pitch (badge size + gap) in strip space — cells 2+ otherwise
-- accumulate fractional offsets (size must already be quantized by the caller).
local function missingPitchFor(db, size)
    local gap = MISSING_BADGE_GAP
    if db.pixelPerfect and DF.PixelPerfect then
        local ss = db.missingBuffIconScale or 1.5
        gap = DF:PixelPerfect(gap * ss) / ss
    end
    return size + gap
end

-- Position/scale/level the strip (the OUR-side outer frame all cells live in) —
-- mirrors the missingBuffIcon* position keys, applied to the strip. The strip
-- is a plain DF frame (non-secret rect): pixel-snap is fine HERE.
local function layoutMissingStrip(frame, db, strip, cellCount)
    local size = missingBadgeSizeFor(db)
    local w = cellCount * size + math.max(0, cellCount - 1) * MISSING_BADGE_GAP
    strip:SetSize(math.max(w, 1), size)
    strip:SetScale(db.missingBuffIconScale or 1.5)
    local anchor = db.missingBuffIconAnchor or "CENTER"
    strip:ClearAllPoints()
    strip:SetPoint(anchor, frame, anchor, db.missingBuffIconX or 0, db.missingBuffIconY or 0)
    DF:SnapPointToPixelGrid(strip, db.pixelPerfect)
    -- ☠ FALLBACK 60, NOT 35. 35 was the PRE-MIGRATION default and it survived here after
    -- the key moved to 60 (_missingBuffBaselineV3) — so a db missing the key put the strip
    -- at frame+35, INSIDE the aura band (40) instead of above it, and the badges rendered
    -- under the very icons they exist to sit over. Same drifted-fallback shape as the
    -- oor*Alpha constants: invisible while Config seeds the key, wrong the moment it does
    -- not (an old import, a hand-edited SavedVariables). Keep equal to Config's
    -- missingBuffIconFrameLevel. (Z-order review, 2026-08-07.)
    strip:SetFrameLevel(math.max(0, frame:GetFrameLevel() + (db.missingBuffIconFrameLevel or 60)))
end

-- Drive the missing-buff strip for one frame. Mirrors the row drives: lazy create,
-- hide the legacy icon (no double render), guard visibility on the NON-aura state
-- (dead/offline/range/UnitCanAssist — the read-free mechanism only answers aura
-- presence), keep cells on the frame's unit, re-apply on a layout-version bump.
-- Non-aura visibility for the missing-buff strip: the badge must never claim
-- "missing" on a corpse / offline / out-of-range / unassistable unit. All
-- non-secret reads; range mirrors the legacy issecretvalue guard. DELIBERATE
-- change vs legacy: no UnitIsPlayer on GROUP frames — legacy excluded NPC group
-- members because its aura SCAN couldn't check them, but raid buffs are castable on
-- follower-dungeon NPCs (Krathe-verified) and the read-free widget works on any
-- assistable unit. Pets stay excluded (pet frames don't run this feature).
--
-- ☠☠ THE PLAYERS-ONLY TERM IS SCOPED TO PINNED FRAMES, AND MUST STAY THAT WAY.
-- It arrived unscoped and killed the feature outright in follower dungeons: every
-- party member there is an NPC, so the strip hid on all of them and showed only on
-- your own frame -- reported by Aur0r4 on 5.1.3 with a fresh profile, confirmed by
-- Krathe in a follower dungeon. The bug it was fixing is real but NARROWER than the
-- code it shipped as: a story-mode companion on a PINNED frame nagging about class
-- raid buffs nobody can give it, which is exactly how the changelog scoped it
-- ("(Pinned Frames) Story-mode NPC companions ..."). The paragraph above is the
-- older claim and it was the correct one; the unscoped term was added beneath it
-- without reconciling the two, so for a build the file argued with itself.
-- ⚠ Residual, accepted: a story companion occupying a real PARTY slot rather than a
-- pinned frame can still nag. A useless icon is cosmetic; a dead feature in every
-- follower dungeon is not.
--
-- ☠ SPLIT OUT of DriveMissingBuffFactory on purpose. The drive only runs from
-- RefreshFactoryRows, which fires on an aura-LAYOUT bump (a settings change) and
-- additionally bails in combat. Death is neither, so a companion dying mid-pull
-- left the badge asserting "missing Fortitude" on a corpse until the next
-- settings change or combat end — field-reported in a follower dungeon,
-- confirmed via /dfdead (UnitIsDeadOrGhost was already true; nothing re-asked).
-- Unit-state changes call THIS instead: non-secret reads plus one SetShown on a
-- DF-owned strip, so it is combat-safe and a no-op when nothing changed.
function DF:RefreshMissingBuffVisibility(frame)
    if not frame then return end
    local strip = frame.missingBuffStrip
    if not strip then return end   -- feature never built on this frame

    local unit = frame.unit
    local visible
    if DF.AuraContainer and DF.AuraContainer._testMode then
        -- P5 preview: fabricated test units fail every unit API — visibility is
        -- the test panel's toggle (UpdateTestMissingBuff gates on it before
        -- calling). The badges show because missing containers stay DISABLED
        -- for the test session (the provider bounce skips them), so every
        -- group is empty and every badge sits parked in its window.
        visible = true
    else
        -- ☠ PLAYERS ONLY ON PINNED FRAMES (#1046/S7) — see the header. A story-mode
        -- companion passes every other term here (assistable, alive — and
        -- UnitIsConnected can read secret-truthy on such units, sailing through the
        -- `and` chain), so pinned NPCs nagged about buffs nobody can give them.
        -- ☠ DO NOT DROP THE isPinnedFrame SCOPE. Unscoped, this term hides the strip
        -- on every follower-dungeon party member, because they are all NPCs.
        visible = unit and UnitExists(unit)
            and (not frame.isPinnedFrame or UnitIsPlayer(unit))
            and not UnitIsDeadOrGhost(unit) and UnitIsConnected(unit)
            and not frame.isPetFrame and UnitCanAssist("player", unit)
        if visible then
            local inRange = frame.dfInRange
            if issecretvalue and issecretvalue(inRange) then
                visible = false
            elseif inRange == false then
                visible = false
            end
        end
    end
    visible = visible and true or false
    if frame.dfMissingStripShown ~= visible then
        frame.dfMissingStripShown = visible
        strip:SetShown(visible)
    end
end

function DF:DriveMissingBuffFactory(frame, db)

    local strip = frame.missingBuffStrip
    local cells = frame.missingFactory

    -- Feature off -> hide the strip (keep the cells; cheap re-show on re-enable).
    if not db.missingBuffIconEnabled then
        if strip and frame.dfMissingStripShown ~= false then
            strip:Hide()
            frame.dfMissingStripShown = false
        end
        return
    end

    -- Lazy strip + cells; recreate the cells when the tracked set changes (rare:
    -- settings toggle / class-detection flip). Handle creation is combat-guarded
    -- inside the factory (defers the container build to regen).
    local tracked = missingTrackedBuffs(db)
    if #tracked == 0 then
        -- Nothing to track (no manual buffs checked / class has no raid buff):
        -- drop any stale cells and keep the strip hidden.
        if cells then
            for _, h in pairs(cells) do h:Destroy() end
            frame.missingFactory = nil
            frame.missingFactorySig = nil
        end
        if strip and frame.dfMissingStripShown ~= false then
            strip:Hide()
            frame.dfMissingStripShown = false
        end
        return
    end
    -- Badge size is NOT in the signature: it hot-applies through h:SetBadgeSize
    -- (live group-layout mutator + our frames) in the version-gated block below —
    -- a size slider drag must never recreate containers (per-tick churn).
    local badgeSize = missingBadgeSizeFor(db)
    local sig = missingFactorySig(tracked)
    if not strip then
        strip = CreateFrame("Frame", nil, frame.contentOverlay or frame)
        frame.missingBuffStrip = strip
        frame.dfMissingStripShown = nil
    end
    if not cells or frame.missingFactorySig ~= sig then
        -- The one destructive edge in this row: every cell is destroyed and the set
        -- rebuilt. Worth seeing, and it only fires when the tracked-buff set moves.
        DF:Debug("AURAROW", "missing buff: REBUILD cells - sig %s -> %s (%s)",
            tostring(frame.missingFactorySig), tostring(sig),
            cells and "replacing existing" or "first build")
        if cells then
            for _, h in pairs(cells) do h:Destroy() end
        end
        cells = {}
        frame.missingFactory = cells
        frame.missingFactorySig = sig
        frame.dfMissingFactoryVersion = DF.auraLayoutVersion or 0
        local spill = missingAnimSpill(db, badgeSize)
        -- pp: whole-pixel cell pitch in the STRIP's scaled space (the strip carries
        -- missingBuffIconScale), else cells 2+ accumulate fractional offsets and
        -- their badge borders render uneven while cell 1's are clean.
        local pitch = missingPitchFor(db, badgeSize)
        for i = 1, #tracked do
            local info = tracked[i]
            local cellCfg = buildMissingCellConfig(info, frame.unit, badgeSize)
            cellCfg.badge.spill = spill   -- transparent room for the border animation to spill outside the icon
            local h = DF.AuraContainer:Create(strip, cellCfg)
            if h then
                h:ClearAllPoints()
                -- Shift the (spill-enlarged) window left by the spill so the CENTRED badge
                -- still lands on the badge-pitch grid — icon position unchanged, window grows.
                h:SetPoint("LEFT", strip, "LEFT", (i - 1) * pitch - spill, 0)
                styleMissingBadge(h, db, frame, info)
                cells[info[2]] = h
            end
        end
        layoutMissingStrip(frame, db, strip, #tracked)
    end

    -- Non-aura visibility (corpse / offline / out-of-range / unassistable).
    -- Owned by RefreshMissingBuffVisibility so unit-state changes can re-apply
    -- it without coming through this drive — see the note on that function.
    DF:RefreshMissingBuffVisibility(frame)

    local unit = frame.unit

    -- Keep cells on the frame's unit (roster churn); refresh the border spec with
    -- the new unit's class/role colour. Combat: SetUnit self-defers in the factory.
    local trackedByKey
    for key, h in pairs(cells) do
        if h:GetUnit() ~= unit then
            h:SetUnit(unit)
            if not trackedByKey then
                trackedByKey = {}
                for i = 1, #tracked do trackedByKey[tracked[i][2]] = tracked[i] end
            end
            if trackedByKey[key] then styleMissingBadge(h, db, frame, trackedByKey[key]) end
        end
    end

    -- Re-apply settings on a layout-version bump only, out of combat (build-once-
    -- leave-it: the badges/strip are ours, but the cadence mirrors the row drives).
    -- Size hot-applies per cell (window/badge/cell mutators) + cells re-space.
    local ver = DF.auraLayoutVersion or 0
    if frame.dfMissingFactoryVersion ~= ver and not InCombatLockdown() then
        frame.dfMissingFactoryVersion = ver
        layoutMissingStrip(frame, db, strip, #tracked)
        local spill = missingAnimSpill(db, badgeSize)
        for i = 1, #tracked do
            local info = tracked[i]
            local h = cells[info[2]]
            if h then
                if h.SetBadgeSize then h:SetBadgeSize(badgeSize, badgeSize) end
                -- Live-apply the animation spill (grows window/push, re-centres badge) with
                -- no teardown, so a slider drag re-flows the spill without restarting the anim.
                if h.SetBadgeSpill then h:SetBadgeSpill(spill) end
                h:ClearAllPoints()
                h:SetPoint("LEFT", strip, "LEFT", (i - 1) * missingPitchFor(db, badgeSize) - spill, 0)
                styleMissingBadge(h, db, frame, info)
            end
        end
    end
end

-- Immediately re-drive the factory rows on every active frame (out of combat).
-- The drives normally run inside the aura update cycle, so a GUI layout change —
-- which only bumps auraLayoutVersion — would otherwise apply "one aura event late"
-- (the live slider lag). Called from DF:InvalidateAuraLayout right after the bump.
-- Cheap when nothing changed: each drive is version-gated and its ApplyStyle path
-- uses the container's live layout mutators (no rebuild). Pinned-set frames catch
-- up on their next aura event (they share the same version check).
local function driveFactoryRowsNow(frame)
    if not frame or not frame.unit then return end
    local db = DF:GetFrameDB(frame)
    if not db then return end
    if db.showBuffs and DF:UseFactoryForBuffs(frame, db) then
        DF:DriveBuffFactory(frame, db)
    end
    if db.showDebuffs and DF:UseFactoryForDebuffs(frame, db) then
        DF:DriveDebuffFactory(frame, db)
    end
    if db.defensiveIconEnabled and DF:UseFactoryForDefensive(frame, db) then
        DF:DriveDefensiveFactory(frame, db)
    end
    if db.missingBuffIconEnabled and DF:UseFactoryForMissingBuff(frame, db) then
        DF:DriveMissingBuffFactory(frame, db)
    end
    -- Un-gated on the enable setting: the drive tears its container down when the
    -- overlay is off, so a GUI disable applies on this pass rather than one late.
    if DF.UseFactoryForDispelOverlay and DF:UseFactoryForDispelOverlay(frame, db) then
        DF:DriveDispelOverlayFactory(frame, db)
    end
    -- Aura Designer factory sync: AD otherwise re-syncs on the next aura event only,
    -- so a Filter Designer edit (which bumps auraLayoutVersion) would leave filter-
    -- group containers one event stale. The sync is cheap when nothing changed
    -- (sig-compare walk) — same gating as UpdateAuras_Enhanced.
    if DF.IsAuraDesignerEnabled and DF:IsAuraDesignerEnabled(frame)
        and DF.AuraDesigner and DF.AuraDesigner.Factory
        and DF.UseFactoryForAD and DF:UseFactoryForAD(frame, db) then
        DF.AuraDesigner.Factory:SyncFrame(frame)
    end
end

-- DEBOUNCED to one pass per frame-render: GUI callbacks often bump the version
-- several times in one click (Invalidate + UpdateAllFrames chains), and slider
-- drags fire per tick — coalescing keeps a 40-man raid drag at one drive pass
-- per rendered frame instead of one per callback. The 0-delay timer re-checks
-- combat when it fires (timers can land after lockdown re-engages).
local factoryRefreshQueued = false
local factoryRefreshRegen   -- one-shot regen listener, created on the first combat drop
function DF:RefreshFactoryRows()
    if factoryRefreshQueued then return end
    if not (DF.AuraContainer and DF.AuraContainer.IsSupported and DF.AuraContainer.IsSupported()) then return end
    factoryRefreshQueued = true
    C_Timer.After(0, function()
        factoryRefreshQueued = false
        if InCombatLockdown() then
            -- ⚠ RE-QUEUE AT REGEN, DON'T DROP. This used to return outright ("version
            -- catches up at next drive") — true per frame, since the version IS bumped,
            -- but the next drive is the next UNIT_AURA on that frame, which after
            -- combat may be arbitrarily far away on a quiet frame. A mid-combat GUI
            -- change then looked half-applied until some aura event wandered by:
            -- disabling Defensive Icons hid the row at once (UpdateDefensiveBar's
            -- combat-safe hide) while the buff row kept CLAIMING the deduplicated
            -- defensives until its next drive — auras missing from both displays.
            -- The restyle itself must stay out of combat (native buttons are
            -- combat-forbidden); regen is the earliest it can legally run.
            if not factoryRefreshRegen then
                factoryRefreshRegen = CreateFrame("Frame")
                factoryRefreshRegen:SetScript("OnEvent", function(self)
                    self:UnregisterEvent("PLAYER_REGEN_ENABLED")
                    DF:RefreshFactoryRows()
                end)
            end
            factoryRefreshRegen:RegisterEvent("PLAYER_REGEN_ENABLED")
            return
        end
        if DF.IteratePartyFrames then DF:IteratePartyFrames(driveFactoryRowsNow) end
        if DF.IterateRaidFrames then DF:IterateRaidFrames(driveFactoryRowsNow) end
        -- Pinned frames were skipped here and "caught up on their next aura
        -- event" — which for a quiet unit is minutes away, so GUI edits looked
        -- inert on pinned sets until something else moved (#1046). Same drive,
        -- same version gates; cheap when nothing changed.
        if DF.PinnedFrames and DF.PinnedFrames.ForEachActiveFrame then
            DF.PinnedFrames:ForEachActiveFrame(driveFactoryRowsNow)
        end
    end)
end

function DF:UpdateAuras_Enhanced(frame)
    if not frame or not frame.unit then return end

    -- ☠ PERF TEST: the enableAuras flag is folded into UseFactoryForBuffs /
    -- UseFactoryForDebuffs, NOT early-returned here. On 12.1 the container is
    -- Blizzard-driven: once built it renders and self-updates from the sealed
    -- side, so skipping THIS function stops our decisions but not the auras.
    -- Turning the flag off has to reach the "factory inactive -> hide the
    -- container" path below, which is what actually takes them off the frame.
    -- (This early-returned for the whole of v4/v5-alpha, which is why the
    -- checkbox looked inert and freed no memory.)

    -- Use raid DB for raid frames, party DB for party frames
    local db = DF:GetFrameDB(frame)

    -- Factory buff row (experimental). Compute once. If a container was built but the factory
    -- path is no longer active (dev toggle off, test mode, or showBuffs off),
    -- hide it via its plain anchor frame (combat-safe, queues no backend op) so the legacy
    -- render can't double up. DriveBuffFactory re-shows it when it drives.
    -- ☠ SetIntentShown, never GetFrame():Hide(). The raw hide left the handle's
    -- intent reading "wants shown", and the identity-gate sweep (target change,
    -- roster, loading screens) re-showed the disabled row with live auras in it —
    -- the "buff bar comes back while disabled" reports. Intent survives sweeps.
    local buffFactoryActive = db.showBuffs and DF:UseFactoryForBuffs(frame, db)
    if frame.buffFactory and not buffFactoryActive then
        frame.buffFactory:SetIntentShown(false)
        frame.dfBuffFactoryShown = false   -- keep DriveBuffFactory's shown-cache coherent
    end
    local debuffFactoryActive = db.showDebuffs and DF:UseFactoryForDebuffs(frame, db)
    if frame.debuffFactory and not debuffFactoryActive then
        frame.debuffFactory:SetIntentShown(false)
        frame.dfDebuffFactoryShown = false
    end
    -- Missing-buff strip mirror: hide it when the factory path goes inactive (test
    -- mode enter / feature off) so the legacy/test render can't double up.
    local missingFactoryActive = db.missingBuffIconEnabled and DF:UseFactoryForMissingBuff(frame, db)
    if frame.missingBuffStrip and not missingFactoryActive and frame.dfMissingStripShown then
        frame.missingBuffStrip:Hide()
        frame.dfMissingStripShown = false
    end

    -- Aura Designer runs when enabled; standard buffs can coexist if showBuffs is on.
    local adEnabled = DF:IsAuraDesignerEnabled(frame)
    if adEnabled then
        -- Run AD engine (indicators, frame effects, etc.). On 12.1 the native factory
        -- bridge (DF.AuraDesigner.Factory) owns AD when DF:UseFactoryForAD is true; the
        -- legacy read-path engine stays byte-for-byte reachable when the gate is false
        -- (pre-12.1 clients, test mode, or adUseFactory=false).
        if DF.AuraDesigner and DF.AuraDesigner.Factory and DF:UseFactoryForAD(frame, db) then
            DF.AuraDesigner.Factory:SyncFrame(frame)
        end

    end


    -- Buff display: the native container renders the row (Blizzard-driven).
    -- Shown when: AD is off, OR AD is on with showBuffs enabled (coexistence)
    if (not adEnabled or db.showBuffs) and buffFactoryActive then
        DF:DriveBuffFactory(frame, db)
    end

    -- Debuff display (always runs — AD doesn't manage debuffs)
    if debuffFactoryActive then
        DF:DriveDebuffFactory(frame, db)
    end
end

-- ============================================================
-- INITIALIZATION
-- ============================================================

local OriginalUpdateAuras = nil
local enhancedAurasInitialized = false

local function InitializeEnhancedAuras()
    if enhancedAurasInitialized then return end

    -- Replace UpdateAuras with enhanced version
    if DF.UpdateAuras and not OriginalUpdateAuras then
        OriginalUpdateAuras = DF.UpdateAuras
        DF.UpdateAuras = DF.UpdateAuras_Enhanced
    elseif not DF.UpdateAuras then
        -- DF.UpdateAuras doesn't exist yet - define it directly
        DF.UpdateAuras = DF.UpdateAuras_Enhanced
    end

    enhancedAurasInitialized = true

end

-- ============================================================
-- CRITICAL: Initialize synchronously, not with delay!
-- During combat reload, delayed initialization would fire AFTER combat
-- lockdown re-establishes, causing UpdateAuras to use the old (non-cached)
-- version instead of the Blizzard-cache-based enhanced version.
-- ============================================================
InitializeEnhancedAuras()

-- ============================================================
-- SAFEGUARD: Ensure enhanced version is used even if Icons.lua
-- loads after Auras.lua (shouldn't happen, but be defensive)
-- ============================================================
local auraInitFrame = CreateFrame("Frame")
auraInitFrame:RegisterEvent("ADDON_LOADED")
auraInitFrame:SetScript("OnEvent", function(self, event, arg1)
    if arg1 == "DandersFrames" then
        -- Double-check that enhanced version is active
        if DF.UpdateAuras ~= DF.UpdateAuras_Enhanced then
            if DF.UpdateAuras then
                OriginalUpdateAuras = DF.UpdateAuras
            end
            DF.UpdateAuras = DF.UpdateAuras_Enhanced
        end
        self:UnregisterEvent("ADDON_LOADED")
    end
end)

-- ============================================================
-- HIDE/SHOW BLIZZARD RAID FRAMES
-- Blizzard mode: hide containers, strip events but keep UNIT_AURA
-- Direct mode: fully disable frames (unregister ALL events,
--   reparent party frames to hidden parent — Grid2 pattern)
-- ============================================================

-- Track if we've installed hooks (only do once)
local blizzardHooksInstalled = false

-- Track which frames have been stripped so we can restore them
local strippedFrames = {}

-- Track frames that have been reparented to the hidden frame
local reparentedFrames = {}

-- Hidden parent frame for fully disabling Blizzard frames (Grid2 pattern)
local blizzardHiddenParent = CreateFrame("Frame")
blizzardHiddenParent:Hide()

-- ☠ (Removed) DF.blizzardFramesFullyDisabled, "track if Direct-mode full disable is
-- active". Assigned here and recomputed once further down, read NOWHERE in either
-- addon -- a flag named like a live gate that gated nothing. The expression feeding
-- it was vestigial too: both directMode locals were hardcoded true ("direct is the
-- only aura source (4.6.1)"), so it reduced to hidePartyFrames or hideRaidFrames.

-- Function to strip events from a Blizzard unit frame
-- fullDisable=true: unregister ALL events (Direct mode, no Blizzard aura data needed)
-- fullDisable=false: keep UNIT_AURA + combat events (Blizzard mode, need aura cache)
local function StripUnitFrameEvents(frame, fullDisable)
    if not frame then return end
    local unit = frame.unit
    if unit then
        pcall(function()
            frame:UnregisterAllEvents()
            if not fullDisable then
                -- Re-register UNIT_AURA so Blizzard's aura cache keeps updating
                frame:RegisterUnitEvent("UNIT_AURA", unit)
                -- Keep combat events for proper updates
                frame:RegisterEvent("PLAYER_REGEN_ENABLED")
                frame:RegisterEvent("PLAYER_REGEN_DISABLED")
            end
        end)
        strippedFrames[frame] = true
    end
end

-- Reparent a frame to the hidden parent (fully removes it from the visual tree)
local function ReparentToHidden(frame)
    if not frame then return end
    if InCombatLockdown() then return end
    pcall(function()
        if frame.GetParent then
            reparentedFrames[frame] = frame:GetParent()
        end
        frame:SetParent(blizzardHiddenParent)
        frame:Hide()
    end)
end

-- Restore a reparented frame back to its original parent
local function RestoreParent(frame)
    if not frame then return end
    if InCombatLockdown() then return end
    local originalParent = reparentedFrames[frame]
    if originalParent then
        pcall(function()
            frame:SetParent(originalParent)
        end)
        reparentedFrames[frame] = nil
    end
end

-- Function to restore all events on a frame (call Blizzard's setup function)
local function RestoreUnitFrameEvents(frame)
    if not frame then return end
    if not strippedFrames[frame] then return end

    -- Restore parent first if it was reparented
    RestoreParent(frame)

    pcall(function()
        -- Call Blizzard's function to restore all events
        if CompactUnitFrame_UpdateUnitEvents then
            CompactUnitFrame_UpdateUnitEvents(frame)
        end
    end)
    strippedFrames[frame] = nil
end

-- Install hooks once to intercept Blizzard's event registration
local function InstallBlizzardHooks()
    if blizzardHooksInstalled then return end
    
    -- Hook CompactUnitFrame_UpdateUnitEvents to strip events but keep UNIT_AURA
    if CompactUnitFrame_UpdateUnitEvents then
        hooksecurefunc("CompactUnitFrame_UpdateUnitEvents", function(frame)
            -- Only strip events if we're hiding Blizzard frames
            local raidDb = DF:GetRaidDB()
            local partyDb = DF:GetDB()
            local shouldStrip = false
            
            if frame.unit then
                if frame.unit:match("^raid") and raidDb.hideBlizzardRaidFrames then
                    shouldStrip = true
                elseif frame.unit:match("^party") and partyDb.hideBlizzardPartyFrames then
                    shouldStrip = true
                elseif frame.unit == "player" and partyDb.hideBlizzardPartyFrames then
                    shouldStrip = true
                end
            end
            
            if shouldStrip then
                -- In Direct mode, fully disable (no events at all)
                local isDirectMode = false
                if frame.unit then
                    if frame.unit:match("^raid") then
                        isDirectMode = true
                    else
                        isDirectMode = true
                    end
                end
                StripUnitFrameEvents(frame, isDirectMode)
            end
        end)
    end

    -- Hook side menu frames to forcibly re-hide when Blizzard re-shows them
    -- SetAlpha(0) alone is insufficient — Blizzard code resets alpha on various events
    local function ShouldHideSideMenu()
        -- Always hide side menu when solo — it's a party/raid UI element
        if not IsInGroup() and not IsInRaid() then return true end
        local raidDb = DF:GetRaidDB()
        local partyDb = DF:GetDB()
        if not raidDb or not partyDb then return false end
        if IsInRaid() then
            return raidDb.hideBlizzardRaidFrames and not raidDb.showBlizzardSideMenu
        else
            return partyDb.hideBlizzardPartyFrames and not partyDb.showBlizzardSideMenu
        end
    end

    local function ForceHideSideMenuFrame(frame)
        if not frame then return end
        pcall(function()
            if not InCombatLockdown() then
                frame:Hide()
            else
                frame:SetAlpha(0)
            end
        end)
    end

    if CompactRaidFrameManager then
        hooksecurefunc(CompactRaidFrameManager, "Show", function()
            if ShouldHideSideMenu() then
                ForceHideSideMenuFrame(CompactRaidFrameManager)
            end
        end)
        if CompactRaidFrameManager.displayFrame then
            hooksecurefunc(CompactRaidFrameManager.displayFrame, "Show", function()
                if ShouldHideSideMenu() then
                    ForceHideSideMenuFrame(CompactRaidFrameManager.displayFrame)
                end
            end)
        end
    end

    blizzardHooksInstalled = true
end

function DF:UpdateBlizzardFrameVisibility()
    local partyDb = DF:GetDB()
    local raidDb = DF:GetRaidDB()

    -- Separate settings for party and raid frames
    local hidePartyFrames = partyDb.hideBlizzardPartyFrames
    local hideRaidFrames = raidDb.hideBlizzardRaidFrames

    -- ⚠ THESE TWO LOCALS STAY. They look like leftovers -- both hardcoded true, and
    -- the DF.blizzardFramesFullyDisabled line that used to combine them here is gone
    -- (see the note at its declaration) -- but they are read five more times further
    -- down this same function: two `hidePartyFrames and partyDirectMode` guards and
    -- three StripUnitFrameEvents(frame, ...) calls, where the value is the
    -- `fullDisable` argument. Delete them and those resolve as nil GLOBALS: the
    -- guards silently go false and the strip calls flip to fullDisable = false,
    -- leaving UNIT_AURA registered on frames that should be fully disabled.
    local partyDirectMode = true -- direct is the only aura source (4.6.1)
    local raidDirectMode = true

    -- Side menu visibility - hide when solo, respect setting when grouped
    local showSideMenu
    if not IsInGroup() and not IsInRaid() then
        showSideMenu = false
    elseif IsInRaid() then
        showSideMenu = raidDb.showBlizzardSideMenu
    else
        showSideMenu = partyDb.showBlizzardSideMenu
    end
    
    -- Install hooks if we're hiding frames
    if hidePartyFrames or hideRaidFrames then
        InstallBlizzardHooks()
    end
    
    -- Function to safely apply visibility using SetAlpha only
    local function SafeHideFrame(frame, hide)
        if not frame then return end
        pcall(function()
            if hide then
                frame:SetAlpha(0)
            else
                frame:SetAlpha(1)
            end
        end)
    end
    
    -- Function to safely scale container frames
    local function SafeScaleContainer(frame, hide)
        if not frame then return end
        if InCombatLockdown() then return end
        pcall(function()
            if hide then
                frame:SetAlpha(0)
                frame:SetScale(0.001)
            else
                frame:SetAlpha(1)
                frame:SetScale(1)
            end
        end)
    end
    
    -- Function to safely apply just alpha
    local function SafeSetAlpha(frame, alpha)
        if frame and frame.SetAlpha then
            pcall(function() frame:SetAlpha(alpha) end)
        end
    end
    
    -- Function to hide selection highlights
    local function HideSelectionHighlights(frame)
        if not frame then return end
        pcall(function()
            if frame.selectionHighlight and frame.selectionHighlight.SetShown then
                frame.selectionHighlight:SetShown(false)
            end
            if frame.selectionIndicator and frame.selectionIndicator.SetShown then
                frame.selectionIndicator:SetShown(false)
            end
        end)
    end
    
    -- Hide/show the main container frames (raid-style)
    SafeScaleContainer(CompactRaidFrameContainer, hideRaidFrames)
    
    -- Handle CompactPartyFrame (raid-style party frames)
    if CompactPartyFrame then
        SafeSetAlpha(CompactPartyFrame, hidePartyFrames and 0 or 1)
        SafeSetAlpha(CompactPartyFrame.title, hidePartyFrames and 0 or 1)
        SafeSetAlpha(CompactPartyFrame.borderFrame, hidePartyFrames and 0 or 1)
        if hidePartyFrames then
            HideSelectionHighlights(CompactPartyFrame)
        end
    end
    
    -- Handle traditional portrait-style party frames
    if hidePartyFrames and partyDirectMode then
        -- Direct mode: fully disable (reparent to hidden frame)
        ReparentToHidden(PartyFrame)
    else
        RestoreParent(PartyFrame)
        SafeScaleContainer(PartyFrame, hidePartyFrames)
    end

    -- Handle individual traditional party member frames (PartyMemberFrame1-4)
    for i = 1, 4 do
        local frame = _G["PartyMemberFrame" .. i]
        if frame then
            if hidePartyFrames and partyDirectMode then
                ReparentToHidden(frame)
            else
                RestoreParent(frame)
                SafeHideFrame(frame, hidePartyFrames)
                local petFrame = _G["PartyMemberFrame" .. i .. "PetFrame"]
                SafeSetAlpha(petFrame, hidePartyFrames and 0 or 1)
                local buffFrame = _G["PartyMemberFrame" .. i .. "BuffFrame"]
                SafeSetAlpha(buffFrame, hidePartyFrames and 0 or 1)
                local debuffFrame = _G["PartyMemberFrame" .. i .. "DebuffFrame"]
                SafeSetAlpha(debuffFrame, hidePartyFrames and 0 or 1)
            end
        end
    end

    -- Handle individual compact party member frames
    for i = 1, 5 do
        local frame = _G["CompactPartyFrameMember" .. i]
        if frame then
            if hidePartyFrames then
                SafeHideFrame(frame, true)
                HideSelectionHighlights(frame)
                StripUnitFrameEvents(frame, partyDirectMode)
            else
                -- Restore events when showing
                RestoreUnitFrameEvents(frame)
            end
        end
    end
    
    -- Handle raid frames
    for i = 1, 40 do
        local frame = _G["CompactRaidFrame" .. i]
        if frame then
            SafeHideFrame(frame, hideRaidFrames)
            if hideRaidFrames then
                HideSelectionHighlights(frame)
                StripUnitFrameEvents(frame, raidDirectMode)
            else
                -- Restore events when showing
                RestoreUnitFrameEvents(frame)
            end
        end
    end

    for group = 1, 8 do
        for member = 1, 5 do
            local frame = _G["CompactRaidGroup" .. group .. "Member" .. member]
            if frame then
                SafeHideFrame(frame, hideRaidFrames)
                if hideRaidFrames then
                    HideSelectionHighlights(frame)
                    StripUnitFrameEvents(frame, raidDirectMode)
                else
                    -- Restore events when showing
                    RestoreUnitFrameEvents(frame)
                end
            end
        end
        -- Also hide group headers
        local groupFrame = _G["CompactRaidGroup" .. group]
        SafeHideFrame(groupFrame, hideRaidFrames)
    end
    
    -- Force hide/show a frame using actual Hide()/Show() outside combat,
    -- falling back to SetAlpha inside combat to avoid taint.
    -- The hooks on Show() only re-hide when ShouldHideSideMenu() is true,
    -- so calling Show() here is safe — if we're showing, the setting is on
    -- and the hook will be a no-op.
    local function ForceHideShow(frame, hide)
        if not frame then return end
        pcall(function()
            if InCombatLockdown() then
                frame:SetAlpha(hide and 0 or 1)
            else
                if hide then
                    frame:Hide()
                else
                    frame:SetAlpha(1)
                    frame:Show()
                end
            end
        end)
    end

    -- Handle raid frame manager
    if CompactRaidFrameManager then
        local sideMenuVisible = showSideMenu or not hideRaidFrames

        SafeHideFrame(CompactRaidFrameManager.container, hideRaidFrames)
        SafeHideFrame(CompactRaidFrameManager.toggleButton, hideRaidFrames)

        -- Handle the display frame (side panel with settings/pings) separately
        -- Use actual Hide() to prevent Blizzard from re-showing via alpha resets
        ForceHideShow(CompactRaidFrameManager.displayFrame, not sideMenuVisible)

        -- The main manager frame itself
        ForceHideShow(CompactRaidFrameManager, not sideMenuVisible)
    end

    -- Handle the side menu elements for party frames
    local partySideMenuVisible = showSideMenu or not hidePartyFrames

    if CompactPartyFrame then
        -- Only adjust title if we want to show/hide the side menu differently
        if not partySideMenuVisible then
            SafeSetAlpha(CompactPartyFrame.title, 0)
        else
            SafeSetAlpha(CompactPartyFrame.title, 1)
        end
        ForceHideShow(CompactPartyFrame.dropdown, not partySideMenuVisible)
        ForceHideShow(CompactPartyFrame.menuButton, not partySideMenuVisible)
    end

    if PartyFrame then
        ForceHideShow(PartyFrame.DropdownButton, not partySideMenuVisible)
        SafeSetAlpha(PartyFrame.PartyMemberFrameDropDown, partySideMenuVisible and 1 or 0)
    end

    if EditModeManagerFrame and EditModeManagerFrame.PartyFramesSidePanel then
        ForceHideShow(EditModeManagerFrame.PartyFramesSidePanel, not sideMenuVisible)
    end
end

-- One-shot HARD disable of Blizzard's compact raid/party system (mirrors ElvUI's
-- UF:DisableBlizzard). UpdateBlizzardFrameVisibility above only alpha-hides the
-- frames and strips per-frame events reactively — the CompactRaidFrameManager
-- (Raid Utility) keeps running its roster/layout work and the container keeps its
-- own events. This kills all of that once, at load, out of combat:
--   * UIParent's GROUP_ROSTER_UPDATE (drives UpdateRaidAndPartyFrames)
--   * CompactRaidFrameContainer / CompactPartyFrame event registration
--   * the CompactRaidFrameManager itself (unregister + reparent to a hidden frame
--     + tell Blizzard's own setting it should not show)
-- It is IRREVERSIBLE without a /reload, which is why the toggles now prompt for
-- one. Skipped entirely when the user keeps the Blizzard side menu (Raid Utility),
-- since that IS the manager — that case keeps the lighter alpha-hide behaviour.
-- Runs once (DF.blizzardHardDisabled); combat defers it to the next call (the
-- event handler below fires it again on PLAYER_REGEN_ENABLED).
function DF:HardDisableBlizzardFrames()
    if DF.blizzardHardDisabled then return true end
    if InCombatLockdown() then return false end

    local partyDb = DF.GetDB and DF:GetDB()
    local raidDb  = DF.GetRaidDB and DF:GetRaidDB()
    if not (partyDb and raidDb) then return false end

    local hideParty = partyDb.hideBlizzardPartyFrames
    local hideRaid  = raidDb.hideBlizzardRaidFrames
    -- Nothing to disable, or the user wants the Blizzard side menu (the manager) —
    -- either way, don't hard-disable. Mark done so we stop re-checking.
    if not (hideParty or hideRaid)
        or raidDb.showBlizzardSideMenu or partyDb.showBlizzardSideMenu then
        DF.blizzardHardDisabled = true
        return true
    end

    pcall(function()
        -- Stops Blizzard's UIParent from running UpdateRaidAndPartyFrames. That
        -- handler drives BOTH the party and raid default frames, so only drop it
        -- when both are disabled — otherwise a party-only disable would break the
        -- Blizzard raid frames the user still wants (and vice versa).
        if hideParty and hideRaid then
            UIParent:UnregisterEvent("GROUP_ROSTER_UPDATE")
        end

        if hideRaid then
            -- The ping mirror (Features/PingMirror.lua) reads pings off Blizzard's
            -- hidden compact frames, and in a raid those frames only get units while
            -- CompactRaidFrameContainer still hears roster events. Its TryUpdate has
            -- no visibility gate, so leaving the events on is enough, at the cost of
            -- Blizzard laying out its hidden raid frames in the background.
            local keepContainer = partyDb.pingIconEnabled or raidDb.pingIconEnabled
            if CompactRaidFrameContainer and not keepContainer then
                CompactRaidFrameContainer:UnregisterAllEvents()
                -- Irreversible this session; enabling the ping icon later prompts a reload.
                DF.blizzardContainerKilled = true
            end
            if CompactRaidFrameManager then
                CompactRaidFrameManager:UnregisterAllEvents()
                CompactRaidFrameManager:SetParent(blizzardHiddenParent)
            end
            if CompactRaidFrameManager_SetSetting then
                CompactRaidFrameManager_SetSetting("IsShown", "0")
            end
        end

        if hideParty and CompactPartyFrame then
            CompactPartyFrame:UnregisterAllEvents()
        end
    end)

    DF.blizzardHardDisabled = true
    return true
end

-- Apply visibility on load and when group changes
local blizzFrameEventHandler = CreateFrame("Frame")
blizzFrameEventHandler:RegisterEvent("PLAYER_ENTERING_WORLD")
blizzFrameEventHandler:RegisterEvent("GROUP_ROSTER_UPDATE")
blizzFrameEventHandler:RegisterEvent("PLAYER_REGEN_ENABLED")
blizzFrameEventHandler:RegisterEvent("PLAYER_TARGET_CHANGED")
blizzFrameEventHandler:RegisterEvent("RAID_ROSTER_UPDATE")
blizzFrameEventHandler:RegisterEvent("PARTY_MEMBER_ENABLE")
blizzFrameEventHandler:RegisterEvent("PARTY_MEMBER_DISABLE")

-- Coalesce rapid-fire events into a single deferred update to prevent
-- the multiple timer callbacks from fighting each other and causing flicker
local blizzVisibilityPending = false

blizzFrameEventHandler:SetScript("OnEvent", function(self, event)
    -- One-shot hard disable of the Blizzard compact system (self-guarded; a no-op
    -- once done). Deferred by combat, so PLAYER_REGEN_ENABLED retries it here. The
    -- reactive visibility pass below still runs to hide the actual frames.
    if DF.HardDisableBlizzardFrames then DF:HardDisableBlizzardFrames() end

    if event == "GROUP_ROSTER_UPDATE" then
        if DF.RosterDebugEvent then DF:RosterDebugEvent("Auras.lua(visibility):GROUP_ROSTER_UPDATE") end
    end
    -- Debounced update — first event arms the timer, subsequent events within
    -- the window are ignored; the single callback fires once Blizzard has settled
    if not blizzVisibilityPending then
        blizzVisibilityPending = true
        C_Timer.After(0.3, function()
            blizzVisibilityPending = false
            if DF.UpdateBlizzardFrameVisibility then
                DF:UpdateBlizzardFrameVisibility()
            end
        end)
    end
    
    -- For target changes, also do an immediate check to hide selection highlights
    if event == "PLAYER_TARGET_CHANGED" then
        local db = DF.GetDB and DF:GetDB()
        local raidDb = DF.GetRaidDB and DF:GetRaidDB()
        local hideParty = db and db.hideBlizzardPartyFrames
        local hideRaid = raidDb and raidDb.hideBlizzardRaidFrames
        
        if hideParty or hideRaid then
            -- Hide selection highlights on all Blizzard frames
            local function HideSelectionHighlight(frame)
                if frame then
                    if frame.selectionHighlight and frame.selectionHighlight.SetShown then
                        frame.selectionHighlight:SetShown(false)
                    end
                    if frame.selectionIndicator and frame.selectionIndicator.SetShown then
                        frame.selectionIndicator:SetShown(false)
                    end
                end
            end
            
            if hideParty then
                for i = 1, 5 do
                    HideSelectionHighlight(_G["CompactPartyFrameMember" .. i])
                end
            end
            if hideRaid then
                for i = 1, 40 do
                    HideSelectionHighlight(_G["CompactRaidFrame" .. i])
                end
                for group = 1, 8 do
                    for member = 1, 5 do
                        HideSelectionHighlight(_G["CompactRaidGroup" .. group .. "Member" .. member])
                    end
                end
            end
        end
    end
end)

-- Hook Blizzard's selection highlight function to hide it when our option is enabled
if CompactUnitFrame_UpdateSelectionHighlight then
    hooksecurefunc("CompactUnitFrame_UpdateSelectionHighlight", function(frame)
        local db = DF.GetDB and DF:GetDB()
        local raidDb = DF.GetRaidDB and DF:GetRaidDB()
        
        -- Only affect party/raid frames, not nameplates
        local unit = frame.unit or frame.displayedUnit
        if unit then
            local isParty = unit:match("^party") or unit == "player"
            local isRaid = unit:match("^raid")
            
            local shouldHide = false
            if isParty and db and db.hideBlizzardPartyFrames then
                shouldHide = true
            elseif isRaid and raidDb and raidDb.hideBlizzardRaidFrames then
                shouldHide = true
            end
            
            if shouldHide and frame.selectionHighlight and frame.selectionHighlight.SetShown then
                frame.selectionHighlight:SetShown(false)
            end
        end
    end)
end

-- ============================================================
-- /dfauras — the aura pipeline dump
--
-- This is the command we ask a user to paste back when auras render wrong, so
-- it is deliberately NON-DEV: a dump nobody can run on a release build is worth
-- nothing. It reports what we actually handed the container, not what the GUI
-- says, because the gap between those two is where aura bugs live.
--
-- It replaces a command that shared only the name: /dfauras used to toggle
-- Blizzard frame visibility and list side-menu frames. Those toggles are fully
-- exposed on the Visibility page, and frame-hunting is better served by
-- /df debug attached and /df debug mousefoci.
-- ============================================================

-- Every AuraUtil.AuraFilters member DF can consult, and where (if anywhere) it
-- is reachable from the GUI. The point of the "unexposed" column: the debuff row
-- surfaces six category filters as toggles, the buff row surfaces NONE — its
-- filter string is only ever HELPFUL or HELPFUL|PLAYER.
local FILTER_CATALOGUE = {
    { key = "Raid",              where = "debuff row (Raid toggle)" },
    { key = "RaidInCombat",      where = "unexposed" },
    { key = "Cancelable",        where = "unexposed" },
    { key = "BigDefensive",      where = "defensive bar + buff dedup" },
    { key = "ExternalDefensive", where = "unexposed" },
    { key = "Important",         where = "unexposed" },
    { key = "CrowdControl",      where = "debuff row (Crowd Control toggle)" },
    { key = "Dispellable",       where = "debuff row (Dispellable, ANY mode)" },
}

-- Takes the CALLER'S writer rather than opening its own, so one command still
-- prints one header. Same shape as DF:DumpFlatLayoutState(o).
local function pr(o, fmt, ...)
    o:Line(select("#", ...) > 0 and format(fmt, ...) or fmt)
end

-- Render one container handle's live config. `h.config.filter` is the same
-- value normalizeFilters() consumes, so this prints the groups Blizzard is
-- actually being asked to build.
-- How many frames a group is CURRENTLY using, straight from the engine
-- (CustomAuraContainerSharedMixin:GetAuraGroupFrameCount -> the group's frame provider).
-- ★ This is the number the eye sees, and it is the one thing no amount of reading the
-- config can tell you: config.max is what each group is ALLOWED, this is what it TOOK.
-- Blizzard models a non-existent group as an empty one, so an unknown key answers 0
-- rather than throwing — safe to ask for every record including slot-mode ones.
-- ⚠ pcall'd and secrecy-checked anyway: a count derived from a secret aura set could
-- become secret, and tostring on a secret makes the whole output line VANISH.
local function groupFrameCount(h, key)
    local c = h.backend and h.backend.container
    if not c or not c.GetAuraGroupFrameCount then return nil end
    local ok, n = pcall(c.GetAuraGroupFrameCount, c, key)
    if not ok then return nil end
    if issecretvalue and issecretvalue(n) then return "secret" end
    return n
end

local function dumpRow(o, label, h)
    if not h then
        o:Section(label)
        o:Line("not built", "NEUTRAL")
        return
    end
    -- Report an unexpected shape instead of erroring on it. Not defensive
    -- padding: frame.missingFactory looks like the other three by name but is a
    -- MAP of handles, and calling GetUnit on it threw. A dump that dies halfway
    -- is worse than useless — it hides the rows it had not reached yet.
    if type(h) ~= "table" or type(h.GetUnit) ~= "function" then
        o:Section(label)
        -- A handle of the wrong shape IS a fault: something built the row wrong.
        o:Line(format("present but not a container handle (%s)", type(h)), "BAD")
        return
    end
    local cfg = h.config or {}
    -- config.sort is { method = <enum member NAME>, direction? } — names, not
    -- enum values, so this prints what we asked for even if the build renamed it.
    local sort = cfg.sort
    o:Section(label)
    o:Line(format("unit=%s shown=%s max=%s sort=%s/%s",
        tostring(h:GetUnit()),
        tostring(h:GetFrame() and h:GetFrame():IsShown()),
        tostring(cfg.max),
        tostring(sort and sort.method or "default"),
        tostring(sort and sort.direction or "Normal")))
    -- ☠ max IS PER GROUP, NOT PER ROW. Blizzard caps at AddAuraGroup/
    -- SetAuraGroupMaxFrameCount, so a row built from N filter records can render up to
    -- N x max. The per-group counts below plus the TOTAL are the only way to see that
    -- happening — and the only way to tell "one group overfilled" apart from "the same
    -- aura landed in two groups", which look identical on screen.
    -- The player's own dead state rides along because it changes what the ENGINE
    -- matches: "RAID" means "harmful auras the player can dispel", and the identity gate
    -- flips which candidate filters are applicable on harmful auras
    -- (isHarmful and UnitCanAssist -> filters NOT applied). Run this alive and dead on
    -- the same unit and diff the two dumps; that pair is the whole diagnosis.
    o:Line(format("player: dead=%s  (RAID token and harmful spell-ID filters both move with this)",
        tostring(DF.playerIsDead)))

    local filter = cfg.filter
    if type(filter) == "string" then
        local n = groupFrameCount(h, "df1")
        pr(o, "group 1: %s   showing=%s", filter, tostring(n))
        return
    elseif type(filter) ~= "table" then
        pr(o, "filter: %s (unexpected type)", tostring(filter))
        return
    end

    local total, counted = 0, true
    for i, f in ipairs(filter) do
        local str, key, cf
        if type(f) == "string" then str = f
        elseif type(f) == "table" then str, key, cf = f.filter, f.key, f.candidateFilters end
        -- Mirror the build's own key derivation (`rec.key or "df"..i`), or the count
        -- would be asked for a key the container never registered and answer 0.
        -- `shown`, not `n`: the candidateFilters block below declares its own `n` for map
        -- sizes, and two counts one nested inside the other is exactly how a dump starts
        -- reporting the wrong number.
        local shown = groupFrameCount(h, key or ("df" .. i))
        if type(shown) == "number" then total = total + shown else counted = false end
        pr(o, "group %d%s: %s   showing=%s", i, key and (" [" .. tostring(key) .. "]") or "",
            tostring(str), tostring(shown))
        if cf then
            for _, ck in ipairs({ "isBossAura", "isRoleAura", "isBossOrRoleAura", "isPriorityAura",
                                  "isStealable", "canApplyAura", "isFromPlayerOrPlayerPet", "maxDuration" }) do
                if cf[ck] ~= nil then pr(o, "    %s = %s", ck, tostring(cf[ck])) end
            end
            for _, mk in ipairs({ "includeSpellIDs", "excludeSpellIDs", "includeDispelTypes", "excludeDispelTypes" }) do
                local m = cf[mk]
                if m then
                    local n = 0
                    for _ in pairs(m) do n = n + 1 end
                    pr(o, "    %s = %d entr%s", mk, n, n == 1 and "y" or "ies")
                end
            end
        end
    end

    -- THE LINE THIS WHOLE DUMP EXISTS FOR: what the row is allowed vs what it drew.
    -- Flagged BAD when the total exceeds the setting, because that is the user-visible
    -- claim ("Max Debuffs 3") being false — not a curiosity.
    if counted then
        local cap = tonumber(cfg.max)
        local overCap = cap and total > cap
        o:Line(format("TOTAL showing=%d across %d group%s (max=%s per GROUP%s)",
            total, #filter, #filter == 1 and "" or "s", tostring(cfg.max),
            cap and format(", so up to %d for this row", cap * #filter) or ""),
            overCap and "BAD" or nil)
    else
        o:Line("TOTAL showing: unavailable (a group count could not be read)", "WARN")
    end
end

DF:RegisterDebugSlash("DFAURAS", "Aura pipeline dump — filters, groups, dedup (add a unit token)", false, "/dfauras")
-- ============================================================
-- AURA ROW OVERFLOW WATCH (debug console, AURAROW category)
-- ============================================================
-- ☠ `max` IS PER GROUP, NOT PER ROW — Blizzard caps at AddAuraGroup /
-- SetAuraGroupMaxFrameCount — so a row built from N filter records can draw up to N x max
-- and nothing on screen tells you which number you are looking at.
--
-- ★ WHY A WATCH AND NOT A COMMAND. /dfauras answers for ONE unit, and the failure shows up
-- mid-pull on a raider you cannot identify in advance — by the time you have picked a unit
-- and typed the token, the moment is gone. Krathe's point exactly. So the console watches
-- every frame and records the anomaly when it happens; the log is read afterwards.
--
-- Costs nothing unless the AURAROW category is on. DF:DebugActive is the documented
-- predicate for this shape: DF:Debug short-circuits, but its ARGUMENTS are evaluated by
-- the caller first, so an unguarded table walk is paid whether logging is on or off.
local WATCH_INTERVAL = 1
local WATCH_ROWS = {
    { "debuff",    "debuffFactory"    },
    { "buff",      "buffFactory"      },
    { "defensive", "defensiveFactory" },
}
-- unit/row -> the total last logged, so a steady overflow reports ONCE rather than once
-- per tick, and a recovery reports too (the clear is as diagnostic as the break).
local overflowState = {}

-- Totals for one row: what it drew, what each group is allowed, and the per-group
-- breakdown. Returns nil if any group's count is unreadable — a partial total would be a
-- worse answer than no answer, because it reads as "under the cap".
local function rowTotals(h)
    local cfg = h.config
    local filter = cfg and cfg.filter
    if type(filter) ~= "table" then return nil end
    local total, parts = 0, {}
    for i, f in ipairs(filter) do
        local key = (type(f) == "table" and f.key) or ("df" .. i)
        local n = groupFrameCount(h, key)
        if type(n) ~= "number" then return nil end
        total = total + n
        if n > 0 then parts[#parts + 1] = key .. "=" .. n end
    end
    return total, tonumber(cfg.max), #filter, (#parts > 0) and table.concat(parts, " ") or "none"
end

-- File-local, not a closure built per tick: this runs once per frame per row per second
-- while the category is on, and a fresh closure each pass is garbage for nothing.
local function checkFrameOverflow(frame)
    if not frame or not frame.unit then return end
    for i = 1, #WATCH_ROWS do
        local label, field = WATCH_ROWS[i][1], WATCH_ROWS[i][2]
        local h = frame[field]
        if type(h) == "table" and type(h.GetUnit) == "function" and h.config then
            local total, cap, groups, parts = rowTotals(h)
            if total and cap and cap > 0 then
                local stateKey = tostring(frame.unit) .. "/" .. label
                local prev = overflowState[stateKey]
                if total > cap then
                    -- Re-log when the total MOVES, so a row climbing 4 -> 5 -> 6 is visible
                    -- as a progression rather than collapsing into one line.
                    if prev ~= total then
                        overflowState[stateKey] = total
                        -- The per-group breakdown is the whole diagnosis: it separates "one
                        -- group overfilled" from "the same aura landed in two groups", which
                        -- are indistinguishable on screen and have different causes.
                        -- ★ THE PER-UNIT TERMS, because the report is "only SOME people".
                        -- Whatever is different about the affected raiders has to be a
                        -- per-unit value, and these are the ones the aura path actually
                        -- reads. canAssist above all: it is the sole input to Blizzard's
                        -- identity gate (isHarmful and UnitCanAssist -> spell-ID candidate
                        -- filters are NOT applied), it is evaluated PER TARGET, and DF has
                        -- already field-confirmed it goes false for everyone while you are
                        -- a ghost (Update.lua's note on the observer-side case).
                        -- pcall'd and secrecy-checked: dfInRange can hold a secret boolean
                        -- from the UnitInRange fallback, and tostring on a secret makes the
                        -- whole line vanish rather than erroring.
                        local okA, canAssist = pcall(UnitCanAssist, "player", frame.unit)
                        if not okA or (issecretvalue and issecretvalue(canAssist)) then canAssist = "?" end
                        local inRange = frame.dfInRange
                        if issecretvalue and issecretvalue(inRange) then inRange = "secret" end
                        DF:DebugWarn("AURAROW",
                            "OVERFLOW %s %s row: showing %d vs max %d per group over %d groups [%s]"
                            .. " | playerDead=%s combat=%s | unitDead=%s canAssist=%s inRange=%s",
                            tostring(frame.unit), label, total, cap, groups, parts,
                            tostring(DF.playerIsDead), tostring(DF.playerInCombat),
                            tostring(UnitIsDeadOrGhost(frame.unit)), tostring(canAssist),
                            tostring(inRange))
                    end
                elseif prev then
                    overflowState[stateKey] = nil
                    DF:Debug("AURAROW",
                        "overflow cleared %s %s row: showing %d vs max %d [%s] dead=%s",
                        tostring(frame.unit), label, total, cap, parts, tostring(DF.playerIsDead))
                end
            end
        end
    end
end

-- ☠ IterateAllFrames has NO pinned arm — a pinned frame has rows like any other.
function DF:ScanAuraRowOverflow()
    if DF.IterateAllFrames then DF:IterateAllFrames(checkFrameOverflow) end
    if DF.IteratePinnedFrames then DF.IteratePinnedFrames(checkFrameOverflow) end
end

-- One ticker for the life of the session. The body is a single boolean test until the
-- category is switched on, which is cheaper than arming and disarming it from every event
-- that could change the answer (and cannot go stale the way that would).
C_Timer.NewTicker(WATCH_INTERVAL, function()
    if not DF.DebugActive or not DF:DebugActive("AURAROW") then return end
    -- ☠ NOT IN TEST MODE. The preview deliberately fills every group from the curated
    -- sample pool — Handle:_slotCount returns testSlotCount there, NOT config.max — so a
    -- six-record debuff row reports 60 against a max of 3 and every frame in the raid
    -- fires at once. That is the preview working, not a fault, and one toggle buried the
    -- real findings under 50 false lines (field log, 2026-08-26 11:49:35).
    if DF.AuraContainer and DF.AuraContainer._testMode then return end
    if DF.testMode or DF.raidTestMode then return end
    DF:ScanAuraRowOverflow()
end)

SlashCmdList["DFAURAS"] = function(msg)
    local unit = (msg or ""):lower():trim()
    if unit == "" then unit = "player" end

    -- DF:Out, not DF:Say. Say deliberately prints no separator rule because it is
    -- for one-liners; a multi-section dump wearing a one-liner header is the
    -- failure this whole sweep is meant to remove.
    local o = DF:Out("Aura Pipeline", "unit " .. unit)

    -- Capability gate first: on a build without the container widgets every row
    -- below is legitimately absent, and that is the answer, not a symptom.
    local AC = DF.AuraContainer
    o:Section("Container")
    o:Line(format("supported=%s spellFilter=%s sort=%s  (toc %s)",
        tostring(AC and AC.IsSupported and AC.IsSupported()),
        tostring(AC and AC.HasSpellFilter and AC.HasSpellFilter()),
        tostring(AC and AC.HasSort and AC.HasSort()),
        tostring(select(4, GetBuildInfo()))))

    -- Find the frame driving this unit.
    local target
    if DF.IterateAllFrames then
        DF:IterateAllFrames(function(f)
            if not target and f.unit == unit then target = f end
        end)
    end
    if not target then
        -- Reuse the writer opened above; a second DF:Out here printed the
        -- separator rule and the title twice on the not-found path.
        -- IterateAllFrames covers party/raid/arena, not pets or pinned sets.
        o:Line("No DF party/raid/arena frame is currently driving that unit.", "WARN")
        o:Line("Try player, party1..4 or raid1..40, and make sure the frames are shown.", "NEUTRAL")
        o:Siblings("auras")
        return
    end

    -- GetFrameDB resolves raid vs party AND the pinned effective-DB override, so
    -- this is the same table the drive functions read — not a mode guess.
    local db = DF:GetFrameDB(target)
    dumpRow(o, "Buff row",      target.buffFactory)
    dumpRow(o, "Debuff row",    target.debuffFactory)
    dumpRow(o, "Defensive bar", target.defensiveFactory)
    -- Missing buff is NOT one container. frame.missingFactory is a map of
    -- spell key -> handle, one cell per tracked buff (see DriveMissingBuffFactory),
    -- so it gets its own walk rather than being treated as a single row.
    local cells = target.missingFactory
    if type(cells) ~= "table" then
        o:Section("Missing buff")
        o:Line("not built", "NEUTRAL")
    else
        -- Keep the ORIGINAL keys for the lookup — they can be numeric spell IDs,
        -- and a tostring'd copy would index the map to nil.
        local keys = {}
        for k in pairs(cells) do keys[#keys + 1] = k end
        if #keys == 0 then
            o:Section("Missing buff")
            o:Line("built, no cells", "NEUTRAL")
        else
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            o:Section("Missing buff", #keys .. " cell(s)")
            for _, k in ipairs(keys) do
                dumpRow(o, "cell " .. tostring(k), cells[k])
            end
        end
    end

    -- Dedup state: which categories the Aura Designer has claimed, and whether
    -- the row is honouring the claim. "Show All + claims" is the common report.
    o:Section("Dedup")
    pr(o, "buff  -> defensive bar: %s", tostring(db and db.buffDeduplicateDefensives))
    pr(o, "debuff -> AD groups:    %s", tostring(db and db.debuffDeduplicateDesigner ~= false))
    if DF.GetClaimedDebuffCategories and db then
        local claimed = DF:GetClaimedDebuffCategories(target, db)
        if claimed and next(claimed) then
            local keys = {}
            for k, v in pairs(claimed) do if v then keys[#keys + 1] = k end end
            table.sort(keys)
            pr(o, "AD claims: %s", table.concat(keys, ", "))
        else
            pr(o, "AD claims: none")
        end
    end
    pr(o, "debuff mode: %s", (db and db.directDebuffShowAll) and "SHOW ALL" or "categories")

    -- Blizzard's category filters on this build, and what we do with them.
    o:Section("Blizzard filter catalogue")
    for _, e in ipairs(FILTER_CATALOGUE) do
        local tok = AuraFilters and AuraFilters[e.key]
        pr(o, "%-18s %s  %s", e.key, tok and "present" or "ABSENT ", e.where)
    end
    pr(o, "(the buff row exposes none of these — its string is only HELPFUL or HELPFUL|PLAYER)")

    o:Siblings("auras")
end

