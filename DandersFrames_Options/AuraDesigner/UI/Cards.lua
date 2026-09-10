-- Part 4 of the Aura Designer editor, split from Options.lua.
-- Aliases of objects the first part created; they add no state.
-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames
local L = DF.L
local GUI = DF.GUI
local Adapter = DF.AuraDesigner.Adapter
local S = DF.AuraDesigner._uiState
local P = DF.AuraDesigner._priv
local C_ELEMENT = GUI.Colors.element
local C_BORDER = GUI.Colors.border
local C_HOVER = GUI.Colors.hover
local C_TEXT = GUI.Colors.text
local C_TEXT_DIM = GUI.Colors.textDim
-- The editor's "configured, but this will not render" amber (GUI.Colors.notice).
local C_NOTICE = GUI.Colors.notice
local OPTS = P.OPTS
local GetAuraDesignerDB = P.GetAuraDesignerDB
local GetThemeColor = P.GetThemeColor

local ApplyBackdrop = P.ApplyBackdrop
local CreateCardShell = P.CreateCardShell
local ShowBuffCoexistPopup = P.ShowBuffCoexistPopup
local ResolveSpec = P.ResolveSpec
local IsOtherTab = P.IsOtherTab
local IsPIHelperTab = P.IsPIHelperTab
local ShowsOthersOnly = P.ShowsOthersOnly
local IsDebuffTab = P.IsDebuffTab
local CurrentAuraPool = P.CurrentAuraPool
local PoolKeyPrefix = P.PoolKeyPrefix
local OtherPoolDisplayName = P.OtherPoolDisplayName
local CrossPoolTrackedIDs = P.CrossPoolTrackedIDs
local EnsureTypeConfig = P.EnsureTypeConfig
local TYPE_DEFAULTS = P.TYPE_DEFAULTS
local CreateIndicatorInstance = P.CreateIndicatorInstance
local RemoveIndicatorInstance = P.RemoveIndicatorInstance
local RefreshLiveFramesThrottled = P.RefreshLiveFramesThrottled
local AddDurationColorsLink = P.AddDurationColorsLink
local CreateInstanceProxy = P.CreateInstanceProxy
local CreateProxy = P.CreateProxy
local OpenFilterPicker = P.OpenFilterPicker
local CreateAuraProxy = P.CreateAuraProxy
local GetAuraWarningKey = P.GetAuraWarningKey
local AttachWarningBadge = P.AttachWarningBadge
local WithConfiguredAdHocAuras = P.WithConfiguredAdHocAuras
local GetAuraIcon = P.GetAuraIcon
local GetFrameEffectTriggers = P.GetFrameEffectTriggers
local GetEffectConditionGroups = P.GetEffectConditionGroups
local GetEffectConditionMode = P.GetEffectConditionMode
local SetEffectConditionMode = P.SetEffectConditionMode
local AddEffectConditionGroup = P.AddEffectConditionGroup
local RemoveEffectConditionGroup = P.RemoveEffectConditionGroup
local AddEffectTriggerToGroup = P.AddEffectTriggerToGroup
local RemoveEffectTriggerFromGroup = P.RemoveEffectTriggerFromGroup
local EffectChainLinkCount = P.EffectChainLinkCount
local CloseADPicker = P.CloseADPicker
local GetIndicatorLayoutGroup = P.GetIndicatorLayoutGroup
local GetLayoutGroupByID = P.GetLayoutGroupByID
local AddGroupMember = P.AddGroupMember
local anchorDots = P.anchorDots
local ANCHOR_POSITIONS = P.ANCHOR_POSITIONS
local expandedCards = P.expandedCards
local tabButtons = P.tabButtons
local mainTabButtons = P.mainTabButtons
local BADGE_COLORS = P.BADGE_COLORS
local CollectAllEffects = P.CollectAllEffects
local IsAuraTypePlaced = P.IsAuraTypePlaced
local dragState = P.dragState
local RefreshPlacedIndicators = P.RefreshPlacedIndicators
local RefreshPreviewEffects = P.RefreshPreviewEffects
local BuildTypeContent = P.BuildTypeContent

-- ============================================================
-- POWER INFUSION HELPER -- THE RECIPE (slice 3a)
-- ============================================================
-- One click adds the helper with ONE signal running -- the burst window. The other two are
-- ticked on afterwards if the user wants them. One click removes the lot.
--
-- ☠ THE EFFECTS ARE THE RECORD. There is no second copy of "which signals are on" kept in
-- settings and reconciled against what is on screen. Each effect carries a mark saying which
-- signal it is, and every question is answered by looking for the mark: is a helper added, is
-- a signal on, which surface is it using. One truth, so nothing can drift out of step
-- with it -- and deleting a helper row by hand from Active Indicators simply unticks that
-- signal, because nothing is left holding a contrary opinion.
--
-- ⚠ WHICH IS WHY REMOVING FORGETS THE COLOURS, and that is the house rule rather than a gap.
-- The Aura Designer keeps a record's settings when its last effect is deleted ONLY for a spell
-- the user picked into the pool themselves; records the addon built for them -- ad-hoc ones,
-- and anything driven by a spell list, which is what the helper uses -- are pruned on the spot.
-- S.CleanupAdHocAura says why: an entry holding nothing is cruft in the profile. Remembering
-- would be an exception carved out of a rule written for exactly this category.
-- Behaviour settings (never-mark, the amplifiers, the gate) are NOT effects, live where every
-- other setting in the addon lives, and persist as they always did. Appearance dies with the
-- effect it belongs to. That line is drawn once and holds in both directions.
--
-- It writes nothing new in kind: ordinary custom filters, ordinary frame-level effects with
-- ordinary condition groups -- the shapes the From a Filter picker produces by hand.
--
-- ☠ THE MARK IS NOT OPTIONAL. `cfg.pihSignal` on each effect is what reaches the
-- engine as `config.dfGate` and makes the effect OURS to the gate -- without it, nothing the
-- recipe creates is gated. (This used to be a synthetic spell id seeded into the filter; see
-- pihEnsureFilter for why that was replaced.)
-- ============================================================

local PIH_FILTERS = {
    cooldowns  = "Power Infusion Helper",
    amplifiers = "Power Infusion Helper (amplifiers)",
    infused    = "Power Infusion Helper (infused)",
    -- ★ RACIALS BECAME A LIST (2026-09-10). It was four spell IDs written out below, which
    -- made it the one Trigger source with no way in: Krathe, "racial show 4 and no edit
    -- pencil?" The four are now the SEED of a curated list of ours, so the row gets the
    -- pencil, a count that moves as you tick, and Reset to Default -- the same treatment the
    -- cooldown list already has. PIH_RACIAL_IDS stays as the seed and the reset target.
    racials    = "Power Infusion Helper (racials)",
}

local PIH_PI_SPELL_ID = 10060   -- Power Infusion, for the "already infused" mark

-- Seeded from the curated sets, confirmed present in SpellDB:
--   offensiveCooldowns (45)  racials (13)  consumables (6, the potions)  trinketsItems (41)
-- ☠ FOUR RACIALS BY NAME, NOT THE WHOLE CATEGORY. The plan seeded all thirteen with the note
-- "Fireblood et al are ordinary burst". That was wrong: `racials` is not "offensive racials", it
-- is every racial ability, and nine of the thirteen are nothing of the kind -- Shadowmeld,
-- Darkflight, Spatial Rift, Stoneform, Gift of the Naaru, Regeneratin', Bull Rush, Thorn Bloom
-- and Hyper Organic Light Originator. The helper would have lit up when someone stealthed or ran
-- away, which is the opposite of worth infusing.
--
-- ⚠ AND THE DATA CANNOT TELL THEM APART. Every racial record carries `cats = { racials = true }`
-- and nothing else -- checked, not assumed -- so there is no category to intersect with and an
-- explicit list is the only honest option. The cost is maintenance: a new racial in a future
-- patch will not appear here on its own. Accepted, because the failure mode of the alternative
-- is a helper that fires on Shadowmeld and the failure mode of this one is a helper that misses
-- a racial nobody has had time to notice yet.
local PIH_RACIAL_IDS = {
    273104,  -- Fireblood       (Dark Iron Dwarf) -- primary stat
    274739,  -- Ancestral Call  (Mag'har Orc)     -- secondary stat
    20572,   -- Blood Fury      (Orc)             -- attack / spell power
    26297,   -- Berserking      (Troll)           -- haste
}

local PIH_SEED = {
    cooldowns  = { "offensiveCooldowns" },
    amplifiers = { potions = "consumables", trinkets = "trinketsItems" },
}

-- ☠ OUR CURATION, NOT THE DATABASE'S. The category is Danders' and serves his buff bar and his
-- defensive icon too, so a spell that is wrong FOR US gets dropped here rather than recategorised
-- there. Anything in this list is a judgement about the Power Infusion helper only.
-- ⚠ Two of these are arguably miscategorised at source as well. That is a separate, low-priority
-- report to him and NOT a reason to edit shared data.
local PIH_EXCLUDE = {
    -- Augmentation's raid cooldown. It buffs ALLIES rather than the Evoker, so it is not a
    -- "this player is bursting" signal at all -- the Evoker casting it is enabling everyone
    -- else. Belongs with the power externals. (User's call, 2026-08-24.)
    [442204] = true,   -- Breath of Eons
    -- Brewmaster only. A reasonable entry in a general offensive list and a poor Power Infusion
    -- trigger: a tank pressing it is not who you are looking for.
    [325153] = true,   -- Exploding Keg
    -- Leaves no visible buff on the paladin -- it shows in logs and nowhere the game can match.
    -- Replaced below by Avenging Wrath, which does.
    [1234189] = true,  -- Execution Sentence

    -- ⚠ THE TEST FOR ALL THREE BELOW: does the spell leave a buff ON THE CASTER? The helper
    -- matches auras on a unit, so a beam aimed at the ground and an ability that only damages
    -- the target have nothing for it to find -- they would sit in the list doing nothing for as
    -- long as it exists. Same reason Execution Sentence went.
    -- ⚠ Cut deliberately narrowly. Leaving a spell that never fires costs nothing but clutter;
    -- cutting one that WOULD have fired costs a real infusion window, silently. So only the
    -- clear cases go, and four newer entries nobody could speak to with confidence stayed in.
    [202770] = true,   -- Fury of Elune  (Balance druid, a beam on the target area)
    [357210] = true,   -- Deep Breath    (Evoker movement plus damage, not a burst window)
    [204066] = true,   -- Lunar Beam     (Guardian druid -- the tank spec -- and a ground effect)
}

-- ⚠ SPELLS THE CATEGORY MISSES. Avenging Wrath is filed under raidDefensives, which is fair for
-- Protection and wrong for Retribution -- it is that spec's burst window and the paladin entry
-- the helper actually wants. Added by id so the shared categorisation stays untouched.
local PIH_EXTRA_IDS = {
    31884,   -- Avenging Wrath (alts 454351 ride along with the record)
}

-- ⭐ ONE DEFINITION OF WHAT THE HELPER WATCHES. The seeder, the class list and the class ticks
-- all read this. Four places used to walk the category independently, which is three chances for
-- a curation change to land in some of them and not the others -- and the class tick reading a
-- different set from the seeder is exactly the kind of drift nobody notices until a tick stops
-- clearing itself.
local function pihSeedRecords()
    local R = DF.FilterRegistry
    local out, seen = {}, {}
    for _, catKey in ipairs(PIH_SEED.cooldowns) do
        for _, rec in ipairs((R and R.ByCategory and R.ByCategory[catKey]) or {}) do
            if rec.id and not PIH_EXCLUDE[rec.id] and not seen[rec.id] then
                seen[rec.id] = true
                out[#out + 1] = rec
            end
        end
    end
    for _, id in ipairs(PIH_EXTRA_IDS) do
        local rec = R and R.ByID and R.ByID[id]
        if rec and rec.id and not seen[rec.id] then
            seen[rec.id] = true
            out[#out + 1] = rec
        end
    end
    return out
end

-- The same set as flat ids, plus the racials, which is what the seeder wants.
-- ☠ RACIALS ARE NOT SEEDED HERE ANY MORE. They were, and it made the cooldown list mean
-- two things at once: "this player is bursting" and "this player pressed something that makes the
-- burst bigger". A racial alone is not a burst window -- Berserking with nothing behind it is not
-- worth infusing -- so racials moved to the AMPLIFIER list beside trinkets and potions, where the
-- question is how HARD the burst lands rather than whether one is happening at all.
local function pihSeedIDs()
    local out = {}
    for _, rec in ipairs(pihSeedRecords()) do out[#out + 1] = rec.id end
    return out
end

-- The three signals, in the order they read on the panel.
--
-- ⚠ `surface` is the DEFAULT ONLY. The surface a signal actually occupies is wherever its
-- mark is found, so moving one (3b's dropdowns) needs no stored field and no conversion of
-- anyone's saved settings -- the effect moves and the mark moves with it.
--
-- ☠ BURST AND STRONG SHARE ONE RECORD, because they share one spell list on purpose: trimming
-- a spell should trim it for both. A record holds one effect per surface, so those two cannot
-- merely CLASH on a surface -- the second would overwrite the first and a signal would vanish.
-- pihCreateSignal refuses that rather than letting it happen quietly, and the surface
-- dropdown resolves it by SWAPPING the two signals (see P.PIH_SetSurface).
-- ☠ TWO SIGNALS, AND THE THIRD WAS RETIRED ON PURPOSE. "Big cooldown with a trinket or
-- potion" was the only signal that judged two things at once, which made it the only one that
-- could not be an icon, the only one carrying a condition chain, and the only one that could
-- delete itself when its amplifiers were unticked. The question it answered -- how HARD is this
-- burst -- is now answered by the amplifier icons beside the cooldown ones, which say WHICH
-- extras were pressed rather than merely that some were. One less signal, one less shape, and
-- every panel row reads the same way.
--
-- INFUSED DEFAULTS TO AN ICON. It used to default to a background tint and separately offer its
-- own one-icon layout group -- two mechanisms for one job. The Icon surface does it with the
-- aura's own artwork, positioned where the user drags it, so the group went and the default moved.
local PIH_SIGNALS = {
    burst   = { surface = "border", color = { 1.00, 0.82, 0.25 }, list = "cooldowns" },
    infused = { surface = "icon",   color = { 0.55, 0.35, 0.95 }, list = "infused"   },
}

-- ☠ THE BORDER KEEPS ITS COLOUR UNDER A DIFFERENT NAME. DF.Border:BuildSpec reads
-- `BorderColor`; every other frame-level surface reads plain `color`. Writing `color` on a
-- border is neither an error nor a warning -- the field sits there unread while the ring paints
-- the white it was created with. The first pass of this recipe did exactly that and shipped a
-- burst window that was white instead of gold; found by reading BuildSpec, not by looking at
-- it, because a white border still looks like a border that works.
-- ⚠ Derived from the SURFACE rather than stored per signal, so moving a signal to another
-- surface carries its colour across instead of leaving it behind under a name nothing reads.
local function pihColorKey(surface)
    return (surface == "border") and "BorderColor" or "color"
end

-- Localised at call time, not at file scope: the same locale-timing rule the effect-label
-- tables in Groups.lua follow.
--
-- ☠ RESOLVED AT RENDER, NEVER STORED. An earlier version wrote this string onto the
-- effect config as `cfg.label` -- which lives in the PROFILE, so a translated string became
-- saved data. Build the helper on an English client and switch to German: the stored row name
-- stays English forever while the surface dropdown resolves live and shows German, two names
-- for one signal disagreeing on screen. The addon's own rule ("never store L[...] as a db
-- value") says it plainly; caught in Danders' PR review, and it blocked the merge because bad
-- data outlives the fix. `pihSignal` is the stored truth and the label is derived from it.
-- ☠ IT NAMES THE FEATURE, NOT THE TRIGGER. The rows read "PI Helper — Big cooldown - Center -
-- Others Only", and Krathe asked the right question of it: "why? It should just say PI Helper
-- - Icon/Border/Square etc". "Big cooldown" is the TRIGGER, which every helper effect shares
-- and which the Triggers tab is entirely about -- so on an effect row it is a constant
-- printed on every line, taking the space where the row's own identity should be.
-- ⚠ THE TYPE IS ALREADY THERE, AS THE BADGE. Every effect row draws a coloured type badge to
-- the left of its name (Icon, Border, Square...), which is how the designer distinguishes two
-- effects on the same spell. Repeating it in the text would be the same word twice on one row.
-- ⚠ THE SECOND SIGNAL KEEPS ITS OWN NAME, because it is genuinely a different thing and the
-- badge cannot say so. Nothing creates one any more (see pihBuildAddTiles), but existing ones
-- still list and delete, and a row that cannot be told apart from its neighbour is a row
-- somebody deletes the wrong one of.
local function pihLabel(key)
    if key == "burst"   then return L["PI Helper"] end
    if key == "infused" then return L["PI Helper — Already has active Power Infusion"] end
end

-- The effects list (Groups.lua) resolves helper rows through this: same derivation, one
-- definition, so the list and the panel can never disagree about what a signal is called.
P.PIH_SignalLabel = pihLabel

local function pihFilterIdByName(name)
    local R = DF.FilterRegistry
    if not (R and R.ReadStore) then return nil end
    local store = R:ReadStore()
    for id, f in pairs((store and store.customFilters) or {}) do
        if f and f.name == name then return id end
    end
    return nil
end

-- Create-or-find, then seed. Idempotent: AddSpellToCustom answers "exists" for a duplicate,
-- so re-running the recipe repairs rather than doubles.
-- `wipeFirst` empties the list before re-seeding, which is how the amplifier list is rewritten
-- in place -- see pihSyncAmplifierFilter for why it must keep its id.
-- Ownership is NOT in this list. It used to be -- a synthetic id seeded alongside the real
-- spells, which the gate read back out of the resolved map. That worked and was still wrong: a
-- fake id in real data travels with an exported profile and is unexplainable a year later. The
-- mark now lives on the effect (`cfg.pihSignal`) and reaches the engine as `config.dfGate`.
local function pihEnsureFilter(name, presetKeys, extraIDs, wipeFirst)
    local R = DF.FilterRegistry
    if not (R and R.CreateCustomFilter) then return nil end
    local existing = pihFilterIdByName(name)
    local id = existing or R:CreateCustomFilter(name)
    if not id then return nil end
    if wipeFirst then
        local f = R:GetCustomFilter(id)
        if f then f.spells, f.rawIDs = {}, {} end
    end
    -- ☠ SEED ONLY WHAT WE JUST BUILT. Re-seeding an existing list on every create would undo
    -- both kinds of trimming the user is entitled to: the class ticks, and any hand edit made
    -- on the Filters page. A list that quietly refills itself is not a list anyone can own.
    -- (The amplifier list passes wipeFirst and so is always rebuilt -- correctly, because its
    -- contents ARE the two amplifier ticks and nothing else.)
    if (not existing) or wipeFirst then
        for _, catKey in ipairs(presetKeys or {}) do
            local recs = R.ByCategory and R.ByCategory[catKey]
            for _, rec in ipairs(recs or {}) do R:AddSpellToCustom(id, rec.id) end
        end
        for _, sid in ipairs(extraIDs or {}) do R:AddSpellToCustom(id, sid) end
    end
    -- ★ RECORD WHAT "DEFAULT" MEANS, every time -- not only on the create branch.
    -- ☠ THE MARK IS WHAT MAKES THE LIST BEHAVE LIKE OURS: with dfDefaults set, the Filter
    -- Designer gives its rows the on/off tick instead of the destructive ✕ and offers Reset
    -- to Default (R:IsCuratedFilter). Krathe, 2026-09-09: "it's a pre created list by us that
    -- should toggle on off and be able to reset to default if someone ticks something off."
    -- ⚠ OUTSIDE THE SEED BRANCH ON PURPOSE. An EXISTING list is not re-seeded (the note above
    -- says why: a list that quietly refills itself is not a list anyone can own) -- but a
    -- profile made before the mark existed still needs it, and re-stamping the same values on
    -- every call is free and idempotent.
    -- ⚠ THE DEFAULT IS THE RECIPE'S SET, not the list's current contents. Anything the user
    -- has added since is theirs and is deliberately not part of what a reset restores.
    do
        local defaults = {}
        for _, catKey in ipairs(presetKeys or {}) do
            for _, rec in ipairs((R.ByCategory and R.ByCategory[catKey]) or {}) do
                defaults[#defaults + 1] = rec.id
            end
        end
        for _, sid in ipairs(extraIDs or {}) do defaults[#defaults + 1] = sid end
        if R.SetCuratedDefaults then R:SetCuratedDefaults(id, defaults) end
    end
    return id
end

-- ── THE RACIALS LIST ──
-- ★ CREATED WITH THE HELPER, NOT WITH THE TICK. The Racials row on Triggers shows a count and
-- a pencil whether or not the tick is on -- the same as Trinkets and Potions, whose lists are
-- Danders' presets and therefore always exist. A list conjured by the tick would mean the row
-- had no count and a dead pencil until you switched it on, which is the "lying control" this
-- panel keeps being cleaned of. So it is seeded wherever the cooldown list is.
-- ⚠ AND NEVER FROM A TICK. pihSyncTriggerExtras must not call this, for the reason its own
-- note gives: a tick must not conjure the helper into existence.
local function pihEnsureRacialFilter()
    return pihEnsureFilter(PIH_FILTERS.racials, nil, PIH_RACIAL_IDS)
end

-- Every id in a curated list of ours, in ONE place because three callers need it and each
-- would otherwise walk both buckets itself.
-- ⚠ BOTH BUCKETS. AddSpellToCustom files a known id under `spells` and an unknown one under
-- `rawIDs`, and which bucket a racial lands in depends on whether SpellDB knew it when it was
-- added -- so a reader that consults one is right until the database is regenerated.
-- ⚠ `everything` IGNORES THE TICKS, and the two callers want opposite things: the WANT set
-- honours them (an unticked racial must stop firing) and the REMOVAL UNIVERSE must not (an
-- unticked racial is exactly what has to be taken back out of the cooldown list).
local function pihCustomFilterIDs(cfId, everything)
    local R = DF.FilterRegistry
    local f = cfId and R and R.GetCustomFilter and R:GetCustomFilter(cfId)
    if not f then return nil end
    local out = {}
    for _, bucket in ipairs({ f.spells, f.rawIDs }) do
        for sid in pairs(bucket or {}) do
            if everything or not R.IsCustomSpellEnabled or R:IsCustomSpellEnabled(cfId, sid) then
                out[#out + 1] = sid
            end
        end
    end
    return out
end

-- ─────────────────────────────────────────────────────────────
-- WHAT EXISTS -- read off the marks, never off a stored list
-- ─────────────────────────────────────────────────────────────
-- Scans the WHOLE pool rather than the helper's own records. If a spell list is renamed or
-- deleted underneath us, our effects must still be findable -- otherwise they become orphans
-- ☠☠ THE HELPER LIVES IN THE *OTHER BUFFS* POOL, ALWAYS, AND THE POOL IS NOT A PREFERENCE.
-- It decides the caster filter before anything else gets a say -- poolFilter returns
-- "HELPFUL|PLAYER" for a My Buffs record and never reaches the othersOnly branch at all. So a
-- helper built there asks for "cooldowns cast by ME", and a group member's own cooldown is cast
-- by THEM. It can never match. The Others Only flag we set on every signal was being overruled
-- by the pool it happened to be created in.
--
-- ⚠ FIELD-FOUND 2026-08-24, AND NOTHING SOLO COULD HAVE CAUGHT IT: with only your own frame on
-- screen, your own casts DO satisfy "cast by me", and the editor preview draws from config
-- without applying a pool filter at all -- which is why the border looked right in every solo
-- pass. It took a Demon Hunter pressing Metamorphosis: sound fired (it registers per unit and
-- spell, with no pool and no caster filter) while nothing drew.
--
-- ⚠ READS take adDB.otherAuras directly and never GetOtherAuras, which CREATES the table --
-- merely looking at a panel must not write to the profile. WRITES go through the accessor,
-- which is where lazy creation belongs.
local function pihOtherPoolRead()
    local adDB = GetAuraDesignerDB()
    local pool = adDB and adDB.otherAuras
    return (type(pool) == "table") and pool or nil
end

local function pihOtherPoolWrite()
    return P.GetOtherAuras and P.GetOtherAuras() or nil
end

-- ★★★ A SIGNAL CAN HOLD SEVERAL SURFACES AT ONCE (2026-09-08).
-- ☠ THE STORE ALREADY ALLOWED IT; ONLY THIS LOOKUP AND ONE GATE SAID OTHERWISE. A pool
-- record can carry many frame-level effects and many placed instances, so "border AND health
-- bar AND a square" was always expressible -- pihFound simply wrote each hit over the last
-- into out[signal], and pihCreateSignal refused a second add with "already on". Krathe wants
-- what the designer does: add several, like the AD tiles.
-- ⇒ pihFoundAll returns EVERY hit per signal; pihFound keeps its old one-per-signal shape
-- over the top, so the dozen existing consumers are untouched by this change.
-- ⚠ ORDERED BY SURFACE, not by pairs(). The pool walk is hash order, so "the first hit" was
-- previously whichever the iterator happened to reach last -- harmless when a signal had one,
-- and a source of flicker the moment it has three.
-- ☠ ITS OWN TABLE RATHER THAN PIH_SURFACE_ORDER, and not for tidiness: that local is declared
-- ~400 lines BELOW here, so naming it would compile as a nil GLOBAL read -- the exact
-- "declared below its first caller" trap UnitExemptFromHelpfulGate documents in this file.
-- Kept in the same order as the menu, and it only has to be self-consistent: this decides
-- which hit is called primary, not what anything renders.
local PIH_RANK = {
    border = 1, healthbar = 2, background = 3, nametext = 4, healthtext = 5,
    icon = 6, square = 7, bar = 8,
}
local function pihSurfaceRank(typeKey) return PIH_RANK[typeKey] or 99 end

local function pihFoundAll()
    local out = {}
    local pool = pihOtherPoolRead()
    if type(pool) ~= "table" then return out end
    local keys = P.FRAME_LEVEL_TYPE_KEYS or {}
    for auraName, auraCfg in pairs(pool) do
        if type(auraCfg) == "table" then
            for _, typeKey in ipairs(keys) do
                local cfg = auraCfg[typeKey]
                if type(cfg) == "table" and cfg.pihSignal then
                    local l = out[cfg.pihSignal] or {}
                    l[#l + 1] = { auraName = auraName, typeKey = typeKey, cfg = cfg }
                    out[cfg.pihSignal] = l
                end
            end
            for _, inst in ipairs(auraCfg.indicators or {}) do
                if type(inst) == "table" and inst.pihSignal then
                    local l = out[inst.pihSignal] or {}
                    l[#l + 1] = { auraName = auraName, typeKey = inst.type,
                                  cfg = inst, indicatorID = inst.id }
                    out[inst.pihSignal] = l
                end
            end
        end
    end
    for _, l in pairs(out) do
        table.sort(l, function(a, b) return pihSurfaceRank(a.typeKey) < pihSurfaceRank(b.typeKey) end)
    end
    return out
end
-- ⚠ P.PIH_FoundAll was exported here and never read anywhere. The LOCAL is live -- the create
-- gate, PIH_SurfacesOf and pihPurgeStrayMarks all use it; only the export went.

local function pihFound()
    local out = {}
    local pool = pihOtherPoolRead()
    if type(pool) ~= "table" then return out end
    local keys = P.FRAME_LEVEL_TYPE_KEYS or {}
    for auraName, auraCfg in pairs(pool) do
        if type(auraCfg) == "table" then
            for _, typeKey in ipairs(keys) do
                local cfg = auraCfg[typeKey]
                if type(cfg) == "table" and cfg.pihSignal then
                    out[cfg.pihSignal] = { auraName = auraName, typeKey = typeKey, cfg = cfg }
                end
            end
            -- Placed instances carry the mark too (Icon / Square surfaces). The hit's
            -- typeKey is the instance's type, and indicatorID is what tells every consumer
            -- this representation is an instance rather than a frame effect.
            for _, inst in ipairs(auraCfg.indicators or {}) do
                if type(inst) == "table" and inst.pihSignal then
                    out[inst.pihSignal] = { auraName = auraName, typeKey = inst.type,
                                            cfg = inst, indicatorID = inst.id }
                end
            end
        end
    end
    return out
end

-- ─────────────────────────────────────────────────────────────
-- THE COOLDOWN-ICON GROUP -- RETIRED (schema 5, 2026-09-09)
-- ─────────────────────────────────────────────────────────────
-- ☠☠ IT SHIPPED, IT GOT STUCK, AND THE TWO FINDERS BELOW ARE ALL THAT IS LEFT OF IT.
-- The helper used to be able to draw a Filter Group of live cooldown icons, ticked on from
-- a row buried under "Classes and Cooldowns". Krathe, 2026-09-09: "I have stuck PI Helper
-- Cooldown - Icons on my AD despite that not even being an option now for PI helper."
-- ⚠ AND HE WAS RIGHT ABOUT THE SCOPE, WHICH IS WHY IT IS NOT COMING BACK. The helper's
-- question is "is this player worth infusing", not "which cooldown did they press" -- a
-- board of per-spell icons answers the second question at the price of the first. The
-- effects a user adds now are the AD's own: border, health bar, background, name/health
-- text, square, bar, and an Icon that shows POWER INFUSION's artwork rather than the
-- trigger's.
-- ⚠ THE FINDERS SURVIVE THE FEATURE ON PURPOSE. pihSweep deletes any group a shipped
-- build left behind, and PIH_Remove sweeps again as a belt-and-braces -- both need to be
-- able to FIND one, and a profile that has never been swept still has one to find.
--
-- The original design note, kept because it is the argument that has to be re-made if
-- anyone proposes this again:
-- ☠ A FOURTH WAY TO SHOW THE SAME SIGNAL, NOT A FOURTH SIGNAL. A placed icon pins
-- max = 1 and shows ONE arbitrary cooldown; a Filter Group shows every matching cooldown the
-- unit has running, one icon each -- the richer read of the burst window, and Danders'
-- recommendation ("build it on merit, not as a fallback"). It is also the gate's native
-- shape: the group builds through AuraContainer:Create with a config-wide candidate set, and
-- buildFilterGroupConfig stamps dfGate from the group's own pihSignal mark -- no new gate
-- code anywhere.
--
-- ⚠ THE COOLDOWN SIGNAL ONLY. Infused draws as a placed Icon rather than a group of
-- its own: one signal, one representation. The amplifier list rides into THIS group through
-- the ticks nested under its icons row.
--
-- The group is ordinary Layout Groups data marked with pihSignal -- the same doctrine as the
-- effects: the marks ARE the record. Hand-deleting it from the Layout Groups tab reads as
-- the tick going off, and nothing is left holding a contrary opinion.
-- Two groups, found by their mark: "burst" is the shared cooldowns/amplifiers row
-- (others-only), "infused" is its own one-icon group -- SEPARATE because one container has
-- ONE caster rule, and infused needs the opposite rule from everything else (own casts
-- allowed; it IS an own cast). User's design, second group session.
-- ☠☠☠ AND THE HELPER'S OWN DATA IS NOT ALWAYS IN THE HELPER'S OWN STORE. READ THIS BEFORE
-- WRITING ANOTHER FINDER.
-- Every PIH_* question in this file reads adDB.otherAuras / adDB.otherLayoutGroups, because
-- that is where the helper's records BELONG -- the pool decides a record's caster filter and
-- the helper watches other people's cooldowns, so Any Buff is the only pool where one can
-- match anything. That is a statement about where they belong. It is not a statement about
-- where they ARE.
--
-- ☠ KRATHE'S PROFILE, READ OUT OF SAVEDVARIABLES 2026-09-09 after he reported the same stuck
-- group for the third time:
--     layoutGroups/HolyPriest       -> EIGHT "PI Helper — Cooldown icons" groups
--     auras/HolyPriest/@custom:cf9  -> one marked icon indicator
--     otherAuras/@custom:cf12       -> one marked icon indicator   (the only one in the
--                                      store every finder in this file looks in)
-- The old icon tick called P.CreateLayoutGroup, which is POOL-ROUTED off S.activeBuffTab, and
-- the panel it lived on was mounted in S.BuildEffectsHeadArea -- drawn on EVERY pool's
-- Effects tab, not only Any Buff, whatever the comment beside it claimed. So ticking it on My
-- Buffs created a group in the SPEC store; the finder then could not see it, reported the
-- icons as off, and the next tick made another one. Eight times.
--
-- ⇒ NOTHING COULD REACH THEM. Not the helper (wrong store), not the Layout Groups tab
-- (VisibleLayoutGroups hides marked groups from every pool that is not the helper's), and not
-- the sweep. A record that no control can see is a record no control can turn off, which is
-- exactly what Krathe was looking at.
--
-- ⇒ SO THE SWEEP HUNTS BY MARK, ACROSS EVERY STORE, and these two walkers are how. The
-- ordinary finders stay narrow on purpose -- they answer "what is the helper showing", and
-- the answer must not include records that cannot work -- but anything CLEANING UP has to
-- look where the data actually went. See [[ad-storage-map]] for the store list itself.
local function pihAllGroupStores(adDB)
    local out = {}
    if type(adDB.otherLayoutGroups) == "table" then out[#out + 1] = adDB.otherLayoutGroups end
    local lg = adDB.layoutGroups
    if type(lg) == "table" then
        -- ⚠ SPEC-KEYED SINCE V2, WITH A LEGACY FLAT ARRAY STILL POSSIBLE. An entry carrying
        -- `.id` is a group record, which means THIS table is the store; otherwise its values
        -- are the per-spec arrays. Same test [[ad-storage-map]] records for the font walkers.
        if type(lg[1]) == "table" and lg[1].id then
            out[#out + 1] = lg
        else
            for _, arr in pairs(lg) do
                if type(arr) == "table" then out[#out + 1] = arr end
            end
        end
    end
    return out
end

local function pihAllAuraPools(adDB)
    local out = {}
    if type(adDB.otherAuras) == "table" then out[#out + 1] = adDB.otherAuras end
    if type(adDB.auras) == "table" then
        -- adDB.auras is SPEC-KEYED: its values are the pools, not the records.
        for _, poolT in pairs(adDB.auras) do
            if type(poolT) == "table" then out[#out + 1] = poolT end
        end
    end
    return out
end

-- ⚠ pihAnyIconGroup AND pihIconGroup ARE GONE WITH THE LAST THING THAT USED THEM. Both
-- searched adDB.otherLayoutGroups for a mark and handed the id to a store-routed delete --
-- one store, one id -- which is the shape that failed three times. pihPurgeStrayMarks hunts
-- by mark across every store instead, so there is nothing left for a single-store finder to
-- answer that is not a wrong answer waiting to happen.

-- ★ THE PREVIEW'S POOL — the helper's records and nothing else (2026-09-08).
-- ☠ THE SHARED POOL IS NOT THE HELPER'S POOL. Its records live in Any Buff alongside
-- whatever the user has built there themselves, so handing the preview painter
-- CurrentAuraPool() on the helper's own page would render their unrelated indicators on a
-- canvas that claims to be about Power Infusion. Wrong in the one direction a preview must
-- never be wrong: it would show something the page does not control.
-- ⚠ THE SAME TABLES, NOT COPIES. RefreshPreviewEffects paints from the cfg tables it is
-- given, so sharing them is what keeps this canvas identical to the designer's rather than
-- a second renderer that can drift. It also means a colour picked on a signal row is on the
-- preview the moment the page redraws, with nothing to keep in step.
function S.PIH_PreviewPool()
    local out = {}
    local pool = pihOtherPoolRead()
    if type(pool) ~= "table" then return out end
    local keys = P.FRAME_LEVEL_TYPE_KEYS or {}
    for auraName, auraCfg in pairs(pool) do
        if type(auraCfg) == "table" then
            local mine = false
            for _, typeKey in ipairs(keys) do
                local cfg = auraCfg[typeKey]
                if type(cfg) == "table" and cfg.pihSignal then mine = true break end
            end
            if not mine then
                for _, inst in ipairs(auraCfg.indicators or {}) do
                    if type(inst) == "table" and inst.pihSignal then mine = true break end
                end
            end
            if mine then out[auraName] = auraCfg end
        end
    end
    return out
end

-- ☠ THE ICON GROUP NO LONGER COUNTS, BECAUSE IT NO LONGER EXISTS (schema 5, 2026-09-09).
-- It used to: an icons-only helper had no marked effect, so without the second test the
-- enable tick read off while a group was still drawing. The group is gone -- see the
-- cooldown-icon block below -- so the marks are once again the whole answer.
function P.PIH_Exists()
    return next(pihFound()) ~= nil
end

-- ─────────────────────────────────────────────────────────────
-- SHARED SETTINGS
-- ─────────────────────────────────────────────────────────────
-- ☠ ONE COPY, ON THE HELPER, NOT ON EACH EFFECT. Stored on the Aura Designer config so it
-- follows the preset, like everything else the helper writes. The engine already treats role
-- exclusion and the gate as a single switch for the whole helper, so per-effect storage would
-- have been a second source of truth that could disagree with the thing doing the work.
function P.PIH_Settings()
    local adDB = GetAuraDesignerDB()
    if not adDB then return {} end
    -- ⚠ TANKS AND HEALERS EXCLUDED BY DEFAULT. You infuse damage dealers; marking the healer
    -- is noise on every pull. The user can untick either.
    -- gateEnabled: the whole point of the helper, so it defaults ON.
    adDB.pihelper = adDB.pihelper or
        { roles = { TANK = true, HEALER = true }, gateEnabled = true }
    adDB.pihelper.roles = adDB.pihelper.roles or {}
    return adDB.pihelper
end

-- Push the shared settings into the running engine. Config alone changes nothing: the gate
-- reads its own state, so a saved setting that was never pushed is a setting that does not
-- apply until something else happens to re-derive it.
-- ★★★ THE FEATURE SWITCH -- ONE STORED BOOLEAN, LIKE THE DESIGNER'S OWN (2026-09-09).
--
-- ☠ IT USED TO BE DERIVED FROM WHETHER RECORDS EXIST, which is why "off" had to DELETE them.
-- Krathe: "it should function like the rest of AD" -- and AD writes modeDB.auraDesignerEnabled
-- and deletes nothing. See the engine's pihEnabled for the render half.
--
-- ⚠ NOT IN PIH_Settings' DEFAULT TABLE, deliberately. Seeding `enabled` there would make the
-- backfill below unreachable -- the exact "a defaults entry seeds the key so the presence-
-- gated migration never fires" trap this addon has hit three times. The default lives HERE,
-- where it can still tell "never set" from "set to false".
-- ⚠ ABSENT MEANS ON IFF RECORDS EXIST. A profile from before the flag with helper records had
-- a working helper, so it must come back on; one with no records was showing nothing, so it
-- comes back off and the tick reads honestly. Written once, so this is a real backfill rather
-- than a recomputation that could flip later.
-- ⚠ THE ENGINE DEFAULTS TRUE for the same absent case (`s.enabled ~= false`) and does NOT
-- consult the records -- it cannot, cheaply, from the always-loaded half. That is safe
-- because a profile with no records draws nothing whatever the flag says.
function P.PIH_IsEnabled()
    local s = P.PIH_Settings()
    if s.enabled == nil then s.enabled = P.PIH_Exists() end
    return s.enabled and true or false
end

function P.PIH_Apply()
    local s = P.PIH_Settings()
    if DF.AuraContainer and DF.AuraContainer.SetHelperExcludedRoles then
        local any = false
        for _ in pairs(s.roles or {}) do any = true break end
        DF.AuraContainer.SetHelperExcludedRoles(any and s.roles or nil)
    end
    -- Gate off means "never hide": force the gate open and leave it there.
    local Engine = DF.AuraDesigner and DF.AuraDesigner.Engine
    if Engine and Engine.PIH_SetGateEnabled then Engine:PIH_SetGateEnabled(s.gateEnabled ~= false) end
    -- ...then the FEATURE switch, which outranks it. Order matters: turning the helper back on
    -- resumes from the gate's setting, so that setting has to be in place first. The engine
    -- says the same thing from its own side (Engine:PIH_SetEnabled).
    if Engine and Engine.PIH_SetEnabled then Engine:PIH_SetEnabled(P.PIH_IsEnabled()) end
    -- After the gate, never before: the sound arms against the gate's current state, so doing
    -- it first would arm against the state we are about to leave.
    if P.PIH_ApplySound then P.PIH_ApplySound() end
    -- The watcher's event registrations follow whether a helper exists at all.
    if Engine and Engine.PIH_SyncWatcher then Engine:PIH_SyncWatcher() end
end

-- ☠☠ THE RETAINED-CUSTOMISATION STASH IS GONE (2026-09-09), AND SO IS THE REASON FOR IT.
-- pihStashHits / pihKeptCfg / pihKeptSurfaces / pihRestoreInto / PIH_RECIPE_OWNED existed to
-- survive the enable tick's round trip, back when "off" DELETED every helper record. It does
-- not: the tick writes adDB.pihelper.enabled and the records stay exactly where they are, so
-- there is nothing to remember and nothing to lay back over a rebuild.
-- ⚠ THE BUG THAT KILLED THE MODEL, for anyone tempted to bring it back: the stash held ONE
-- surface per signal (written when a signal WAS one effect), while a signal can hold several.
-- Border + icon + square went in, one was stashed, all three were deleted, and re-enabling
-- rebuilt the one. Krathe: "when I disable the PI tracker, it seems to remove my border
-- effect I added." A switch that has to remember what it destroyed will keep finding new
-- things it forgot; a switch that destroys nothing cannot.
-- ⚠ adDB.pihelper.retainedCfg survives in old profiles. Inert, a few bytes, and deliberately
-- not swept: a migration that deletes data to tidy up is a worse trade than the bytes.

-- ─────────────────────────────────────────────────────────────
-- BUILDING AND UNBUILDING ONE SIGNAL
-- ─────────────────────────────────────────────────────────────
local function pihRefresh()
    -- ☠ RE-DERIVE WHEN THE LAST THING GOES, AND DO IT HERE. Danders' review found the
    -- resident half left armed -- events registered, sound armed -- for a helper with nothing
    -- in it, because only Remove reset it and the signal ticks reached the same state one
    -- click at a time. That fix lived on the tick's own off-branch; the ticks are gone now,
    -- and the same state is reachable through the surface menu's "None" and the icons tick.
    -- ⚠ So it belongs at the chokepoint rather than on any one door: every mutation
    -- ends here, and PIH_Exists is derived, so this cannot disagree with what is on screen.
    -- Cheap: one scan of the pool, only on a settings change, never in a frame update.
    if not P.PIH_Exists() then
        local E2 = DF.AuraDesigner and DF.AuraDesigner.Engine
        if E2 and E2.PIH_ApplySaved then E2:PIH_ApplySaved() end
    end
    if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
    if DF.UpdateAllFrames then DF:UpdateAllFrames() end
    local Engine = DF.AuraDesigner and DF.AuraDesigner.Engine
    if Engine and Engine.ForceRefreshAllFrames then Engine:ForceRefreshAllFrames() end
    -- The editor's own surfaces, same pair the picker's paths always call: without these a
    -- deleted square or layout group stays PAINTED on the preview canvas until a reload --
    -- field-found as "changing surface doesn't remove the square", when the data was right
    -- and only the picture was stale.
    if RefreshPlacedIndicators then RefreshPlacedIndicators() end
    if RefreshPreviewEffects then RefreshPreviewEffects() end
end

-- ★★★ TRINKETS / POTIONS / RACIALS ARE TRIGGERS NOW, NOT A SECOND LIST (schema 5, 2026-09-09).
-- ☠ THEY USED TO FEED A SEPARATE "amplifiers" FILTER WHOSE ONLY CONSUMER WAS THE COOLDOWN-ICON
-- GROUP. Retire the group and those three ticks write to nothing -- three controls that look
-- live and change the world not at all, which is the exact class of lying control this panel
-- keeps being cleaned of.
-- ⇒ They join the ONE list the helper actually matches on. Krathe's own words for what a
-- trigger is: "people pick WHAT will show the effect -- i.e this CD/trinket being used and PI
-- is not on CD and role/class etc match." A trinket proc IS that, so it belongs in the list
-- that answers it.
--
-- ⚠ ADD AND REMOVE, AGAINST A FIXED UNIVERSE. Unticking has to take the spells back out, and
-- "take out whatever is not ticked" needs to know what the ticks could ever have put in --
-- otherwise an untick would either do nothing or strip the user's own hand-added spells. The
-- universe is the same three sources read with every tick on, so this touches those ids and
-- nothing else: anything a user adds in the Filter Designer is untouched in both directions.
-- ☠ RACIALS ARRIVE AS IDS, NOT AS A PRESET. Every racial record carries only
-- `cats = { racials = true }`, so there is no offensive-racial category to intersect -- the
-- four worth marking are listed by hand in PIH_RACIAL_IDS.
-- ⚠ `everything` IGNORES THE PRESET TICKS, and the two callers need opposite answers.
-- The WANT set is what should be in our list, so it honours them. The REMOVAL UNIVERSE is
-- everything these ticks could ever have put there, so it must not -- filter it and a spell
-- the user has just unticked in the preset drops out of the universe, is never visited by
-- the removal loop, and stays in our list forever. The narrowing that makes preset edits
-- REACH the helper would have made one direction of them unreachable.
local function pihAmplifierIDs(s, everything)
    local R = DF.FilterRegistry
    local out = {}
    -- ★ THE PRESET'S OWN TICKS ARE HONOURED, which is what makes editing one REACH the
    -- helper. This walked every record in the category, so unticking a trinket in the
    -- Filter Designer changed nothing here -- the panel offered a route to a list whose
    -- edits went nowhere, and no wording could make that read as anything but broken.
    -- ⚠ Paired with the re-sync on the Triggers build (S.BuildPIHelperCard): reading the
    -- ticks is only half of it if nobody reads them again after they change.
    local function addCat(catKey)
        for _, rec in ipairs((R and R.ByCategory and R.ByCategory[catKey]) or {}) do
            if rec.id and (everything or not R.IsSpellEnabled
                or R:IsSpellEnabled(catKey, rec)) then
                out[#out + 1] = rec.id
            end
        end
    end
    if s.potions  then addCat(PIH_SEED.amplifiers.potions)  end
    if s.trinkets then addCat(PIH_SEED.amplifiers.trinkets) end
    if s.racials  then
        -- ★ THE LIST IF THERE IS ONE, THE SEED IF THERE IS NOT. Racials is a curated list of
        -- ours now, so its ticks are honoured exactly as a preset's are -- but the list only
        -- exists once the helper does, and pihSyncTriggerExtras may reach this before then.
        -- The literal is what the list will be seeded WITH, so the fallback is not a
        -- different answer, only an earlier one.
        local rids = pihCustomFilterIDs(pihFilterIdByName(PIH_FILTERS.racials), everything)
        for _, id in ipairs(rids or PIH_RACIAL_IDS) do out[#out + 1] = id end
    end
    return out
end

local PIH_ALL_AMPLIFIERS = { potions = true, trinkets = true, racials = true }

-- ★★★ THE ICON'S TWO CHOICES (2026-09-09) -- what picture, and what it is allowed to show.
--
-- ☠ THE PICTURE IS staticSpellID's PRESENCE, and there is no second field recording the
-- choice. Pinned = Power Infusion, absent = the engine binds and paints whatever matched.
-- One truth: the field that DOES the thing is the field the control reads.
--
-- ⚠ "ONE OF THEM, IF SEVERAL ARE UP" IS THE HONEST CAVEAT, and it is why the second control
-- exists at all. A placed icon renders ONE slot; when a player has a class cooldown and a
-- trinket proc and a racial running together, which one the engine hands us is not ours to
-- choose and can change between parses. That is exactly the case the "Also count" ticks make
-- COMMON rather than rare -- racials and trinkets are things people press ALONGSIDE a
-- cooldown, which is what made them "amplifiers" in the first place.
--
-- ⭐ SO THE NARROWING RIDES mutedSpellIDs -- the SAME store the Tracked IDs ticks write, not a
-- parallel one. That is the whole reason this needs no new render concept: the resolver
-- already narrows a placement by its mutes (narrowByPlacementMutes), already handles
-- "everything muted = matches nothing", and the fine-grained per-ID ticks are simply the same
-- setting at maximum resolution. A coarse control and a fine control over one store.
-- ⚠ AND THE TICK IS DERIVED, NEVER STORED. It reads "are ALL the currently-ticked amplifier
-- ids muted on this record", so ticking Racials ON in Triggers later makes it read FALSE by
-- itself -- the new ids are not muted, and the icon really can show them. Storing a boolean
-- would leave the box claiming "ignored" while racials appeared. Same doctrine as the class
-- ticks: the tick reads the list, the click edits the list, nothing in between can disagree.
P.PIH_PI_SPELL_ID = PIH_PI_SPELL_ID

function P.PIH_AmplifierIDs()
    return pihAmplifierIDs(P.PIH_Settings())
end

function P.PIH_IgnoresAmplifiers(rec)
    local ids = P.PIH_AmplifierIDs()
    -- Nothing ticked = nothing to ignore. Reads false so the box is not claiming to suppress
    -- an empty set, which would tick itself the moment the user turned one on.
    if not ids[1] then return false end
    local m = type(rec) == "table" and rec.mutedSpellIDs
    if type(m) ~= "table" then return false end
    for _, id in ipairs(ids) do
        if not m[id] then return false end
    end
    return true
end

function P.PIH_SetIgnoreAmplifiers(rec, on)
    if type(rec) ~= "table" then return end
    local ids = P.PIH_AmplifierIDs()
    if on then
        rec.mutedSpellIDs = rec.mutedSpellIDs or {}
        for _, id in ipairs(ids) do rec.mutedSpellIDs[id] = true end
    elseif type(rec.mutedSpellIDs) == "table" then
        -- ⚠ ONLY OUR IDS COME BACK OUT. A per-ID tick the user set by hand on some other
        -- cooldown is theirs and is not ours to clear.
        for _, id in ipairs(ids) do rec.mutedSpellIDs[id] = nil end
        if not next(rec.mutedSpellIDs) then rec.mutedSpellIDs = nil end
    end
    pihRefresh()
end

-- The picture. `on` = show the cooldown's own artwork; off = pin Power Infusion.
-- ⚠ STRUCTURAL: placedStructSig carries the pinned-vs-dynamic flag (bindNative's SetIcon bind
-- is once per slot), so the container must rebuild rather than restyle. pihRefresh's
-- InvalidateAuraLayout + ForceRefreshAllFrames is that rebuild.
function P.PIH_SetIconShowsAura(rec, on)
    if type(rec) ~= "table" then return end
    rec.staticSpellID = on and nil or PIH_PI_SPELL_ID
    pihRefresh()
end

-- ★★★ THE THREE AMPLIFIER TICKS WRITE A REFERENCE, NOT A COPY (2026-09-10).
--
-- ☠ WHAT THIS FUNCTION USED TO DO, AND WHY IT WAS WRONG. It copied every spell id out of the
-- Trinkets, Potions and Racials lists into our cooldown list, so ticking all three took it
-- from 40 spells to 91 and the same ids existed in two places at once. Krathe: "despite the
-- fact those additional filters link to our actual filters, ticking them on actually just adds
-- those to the PI helper filter, so they are now twice on? this is very confusing."
-- ⇒ Each row has a PENCIL that opens the real list. That promises a reference; the tick made a
-- copy. The row was writing a cheque the mechanism did not cash, and no wording fixes that.
--
-- ★ WHAT REPLACES IT: `f.includes`, read by R:ResolveSelection (see foldIncludes there for why
-- the fold lives in the registry and not in the Aura Designer). Our list stays the 40 class
-- cooldowns -- which is what "Edit Cooldowns" has always claimed to open -- and names the
-- other three rather than swallowing them.
--
-- ⭐ AND A WHOLE HAZARD CLASS GOES WITH THE COPY. Gone: the removal universe, the `everything`
-- parameter's second reader, and yesterday's guard against an amplifier tick deleting a class
-- cooldown that happened to be in one of those lists. None of them were defending against
-- anything real -- they were defending against the copy.
-- ⚠ ALSO GONE: hand-rolling "honour the preset's own ticks". ResolveSelection has always done
-- that for a selected preset (recordSelected calls IsSpellEnabled), so a trinket switched off
-- in the Filter Designer now stops firing here for free rather than by our re-derivation.
--
-- ⚠ NEVER pihEnsureFilter HERE. This runs from a tick, and a tick must not conjure the
-- helper's cooldown list into existence -- that is the enable switch's job.
-- ⚠ WHOLESALE, NOT INCREMENTAL. The whole `includes` table is rebuilt from the three ticks
-- every call, so it cannot drift from them and there is nothing to take back out.
-- ⭐ AND THAT IS WHAT SURVIVES AN IMPORT. R:ImportCustomFilters copies `spells` and `rawIDs`
-- and nothing else, so an imported helper list arrives with no includes at all -- while the
-- three ticks travel in adDB.pihelper with the rest of the profile. The next Triggers build
-- re-derives from them and the references are back, because the ticks are the truth and this
-- table is only ever their shadow.
local function pihSyncTriggerExtras(s)
    local R = DF.FilterRegistry
    if not R then return end
    local id = pihFilterIdByName(PIH_FILTERS.cooldowns)
    local f = id and R.GetCustomFilter and R:GetCustomFilter(id)
    if not f then return end
    local presets, customs = {}, {}
    if s.trinkets then presets[PIH_SEED.amplifiers.trinkets] = true end
    if s.potions  then presets[PIH_SEED.amplifiers.potions]  = true end
    if s.racials  then
        local rid = pihFilterIdByName(PIH_FILTERS.racials)
        -- ⚠ NO FALLBACK TO THE SEED IDs HERE. Without the list there is nothing to point at,
        -- and quietly copying the four in would be the exact behaviour this change removes.
        -- The list is seeded wherever the cooldown list is, so this is a first-run ordering
        -- window and not a state anyone stays in.
        if rid then customs[rid] = true end
    end
    -- nil rather than an empty table: `includes` absent is the shape every other filter has,
    -- and foldIncludes short-circuits on it.
    f.includes = (next(presets) or next(customs)) and { presets = presets, customs = customs } or nil
end

local function pihCreateSignal(key, surfaceOverride, showsAura)
    local def = PIH_SIGNALS[key]
    if not def then return false, "no such signal" end
    -- ☠ THE GATE IS PER SURFACE NOW, NOT PER SIGNAL (2026-09-08). It used to refuse any
    -- second add outright -- "already on" -- which is what made a signal one-surface-only.
    -- The STORE never required that: a pool record holds many frame effects and many placed
    -- instances. Krathe wants the designer's behaviour, several at once.
    -- ⚠ STILL REFUSES A DUPLICATE OF THE SAME SURFACE, and that part is not optional: two
    -- border effects on one record cannot both exist (one key, one value) and two identical
    -- squares would be an invisible double that only the store can see.
    -- ★★ ...EXCEPT THAT TWO ICONS ARE NOT NECESSARILY A DUPLICATE (2026-09-10). Krathe: "we
    -- can't add Power Infusion and Their CD at the same time, we should allow this if we can?"
    -- We can, and the store always could -- pihPlace's own note says so: a placed target mints
    -- an INSTANCE, instances are per-id, and "two signals as icons coexist where two frame
    -- effects on one key cannot". The blanket refusal was the guard being coarser than the
    -- reason for it.
    -- ⚠ THE PAIR IS THE POINT: one icon pinned to Power Infusion ("infuse this person") beside
    -- one showing the buff they actually pressed ("here is why"). Two icons in the SAME art
    -- mode are still the invisible double the guard exists to stop, so that is what it tests
    -- now -- the art, not merely the surface.
    -- ⚠ ONLY ICONS. A square carries no such distinction, so two of them remain a duplicate.
    -- ⚠ Only checked when the caller NAMES a surface. Without an override the target is
    -- resolved below from the stash or the signal's default, so the test would be against the
    -- wrong thing -- and that path is the plain "turn this signal on", which wants its
    -- default surface exactly once.
    local existing = pihFoundAll()[key]
    if surfaceOverride then
        for _, hit in ipairs(existing or {}) do
            if hit.typeKey == surfaceOverride then
                if surfaceOverride ~= "icon" then return true, "already on" end
                -- staticSpellID's PRESENCE is the art choice -- there is no second field
                -- recording it, deliberately (see P.PIH_SetIconShowsAura).
                local pinned = (type(hit.cfg) == "table") and hit.cfg.staticSpellID ~= nil
                if pinned == (not showsAura) then return true, "already on" end
            end
        end
    elseif existing and existing[1] then
        return true, "already on"
    end

    local s = P.PIH_Settings()
    -- ⭐ A RE-ADDED SIGNAL COMES BACK WHERE THE USER LEFT IT. The surface is derived
    -- from where the mark is found, so after a remove nothing else remembers it --
    -- the stash is the only memory. A named surface still outranks it.
    -- ⚠ THE STASH'S FIRST SURFACE, not "the" surface: a signal can hold several and
    -- pihKeptSurfaces returns them in menu order. PIH_Create names each one explicitly, so
    -- this fallback only decides where a BARE create lands.
    -- ⚠ NO STASH TO CONSULT ANY MORE. This used to prefer the surface the signal was
    -- last removed from, because the enable tick DELETED and rebuilt. It does not delete,
    -- so a re-enable finds its records where it left them and nothing is ever rebuilt from
    -- memory -- a bare create is only ever a FIRST create, and its home is the default.
    local tgt = surfaceOverride or def.surface

    local cdId = pihEnsureFilter(PIH_FILTERS.cooldowns, nil, pihSeedIDs())
    if not cdId then return false, "could not build the cooldown list" end
    -- Seeded alongside, so the Racials row has a list to count and to open from the moment
    -- the helper exists -- see pihEnsureRacialFilter. Not fatal if it fails: pihAmplifierIDs
    -- falls back to the seed, so the trigger still works, only the pencil is dead.
    pihEnsureRacialFilter()
    -- ☠ RECORDED FOR THE RESIDENT HALF, WHICH CANNOT SEE THIS FILE. The sound registrations run
    -- in the always-loaded addon and need this list; they used to find it by NAME and were
    -- looking for the scaffolding filter, so they resolved nothing and no sound could ever play.
    -- The id travels in the helper's own settings, which the resident half already reads.
    -- ⚠ An ID rather than a name: a custom filter can be renamed in the Filter Designer.
    s.cooldownFilterID = cdId
    -- ☠ THE EXTRA TRIGGER TICKS ARE REPLAYED THE MOMENT THE LIST EXISTS, and without this
    -- they are silently dropped on exactly the path people take. pihSyncTriggerExtras declines
    -- when there is no list to write into -- a tick must not conjure the helper into being --
    -- so trinkets ticked while the helper was OFF wrote a setting and nothing else. Enabling
    -- then seeded the list from the class cooldowns alone and the tick read on with no spells
    -- behind it: the lying control again, one layer down.
    pihSyncTriggerExtras(s)
    local cdRef = DF:MakeADFilterRef("custom", cdId)
    if not cdRef then return false, "could not name the cooldown list" end

    local ref = cdRef
    if def.list == "infused" then
        local infId = pihEnsureFilter(PIH_FILTERS.infused, nil, { PIH_PI_SPELL_ID })
        if not infId then return false, "could not build the infused list" end
        ref = DF:MakeADFilterRef("custom", infId)
        if not ref then return false, "could not name the infused list" end
    end

    -- ☠ A PLACED TARGET MINTS AN INSTANCE, not a frame effect -- different store
    -- (auraCfg.indicators), different creation call, and no sharing concerns: instances are
    -- per-id, so two signals as icons coexist where two frame effects on one key cannot.
    -- Strong never reaches here as placed -- its menu does not offer these (a placed
    -- indicator cannot make the cooldown-AND-amplifier judgement) -- but refuse anyway:
    -- a guard that relies on the menu is a guard that relies on every future menu.
    -- ⚠ BAR JOINED THE PLACED BRANCH, AND ITS ABSENCE WAS A REAL BUG rather than a missing
    -- feature. `bar` is a PLACED type (AddFlowEffects says mode = "placed"), so it lives in
    -- auraCfg.indicators like an icon and a square -- but the test below named only two of
    -- the three, so a bar fell through to the frame branch and EnsureTypeConfig wrote a
    -- frame-level key called "bar" that nothing in the Factory ever reads. It could never
    -- have drawn. Unreachable while the menu offered no bar; reachable the moment the add
    -- tiles did.
    if tgt == "icon" or tgt == "square" or tgt == "bar" then
        -- ⚠ COUNTED BEFORE THE CREATE, because CreateIndicatorInstance appends to the very
        -- list this measures. Used by the nudge below.
        local siblings = 0
        if tgt == "icon" then
            for _, hit in ipairs(pihFoundAll()[key] or {}) do
                if hit.typeKey == "icon" then siblings = siblings + 1 end
            end
        end
        local inst = CreateIndicatorInstance and CreateIndicatorInstance(ref, tgt)
        if not inst then return false, "could not create the indicator" end
        inst.pihSignal = key
        -- ⚠ OTHERS ONLY IS PER INSTANCE on the placed path -- poolFilter reads it off
        -- the indicator, not the record. Forgetting it is the My-Buffs-pool trap; but see
        -- pihCreateSignal's frame branch for why INFUSED must be the exception -- with it,
        -- that signal could never fire at all.
        inst.othersOnly = (key ~= "infused") or nil
        -- A square and a bar both carry a colour; an icon carries artwork instead.
        if tgt == "square" or tgt == "bar" then
            inst.color = { r = def.color[1], g = def.color[2], b = def.color[3], a = 1 }
        end
        -- ★★★ THE ICON SHOWS POWER INFUSION, NOT THE COOLDOWN THAT TRIGGERED IT.
        -- ☠ AND THAT IS THE WHOLE REASON ICON WAS CUT ONCE ALREADY. Schema 4 retired it
        -- because an icon shows a SPECIFIC BUFF'S artwork, which promised per-buff tracking
        -- the helper does not do. Krathe, 2026-09-09: "if possible an icon option that shows
        -- the PI icon despite the trigger being one of the CD's" -- which dissolves the
        -- objection rather than overruling it. The trigger stays the cooldown list; the
        -- PICTURE is fixed, so the icon says "infuse this player" and never claims to be
        -- reporting which cooldown they pressed.
        -- ⚠ staticSpellID is the container's OWN per-indicator override (AuraContainer's
        -- iconSpec.staticSpellID), not a field invented here -- the test path already
        -- honoured it, and the live path now skips Blizzard's SetIcon bind when it is set so
        -- the engine cannot repaint our art with the matched aura's.
        -- ★ THE ART IS DECIDED HERE NOW (2026-09-10), not pinned unconditionally and unpinned
        -- afterwards. P.PIH_AddSurface used to do the second half by walking EVERY icon the
        -- signal held and clearing staticSpellID on all of them -- harmless while a signal
        -- could hold only one icon, and a bug the moment it can hold two: adding "Their
        -- cooldown" would have stripped the Power Infusion pin off the icon already there.
        if tgt == "icon" then
            inst.staticSpellID = (not showsAura) and PIH_PI_SPELL_ID or nil
        end
        -- ★ A SECOND ICON DOES NOT LAND ON TOP OF THE FIRST. Both take the type's default
        -- corner, so without this the pair arrives perfectly stacked and reads as one icon
        -- that ignored the click. One icon-width plus a gap, away from whichever edge the
        -- anchor names, so the new one moves ONTO the frame rather than off it.
        -- ⚠ A STARTING POSITION, NOT A LAYOUT. The effect card's own Placement controls own it
        -- from here; this only has to make both visible on arrival.
        if siblings > 0 then
            local step = ((TYPE_DEFAULTS and TYPE_DEFAULTS.icon and TYPE_DEFAULTS.icon.size)
                or 24) + 2
            local a = inst.anchor or ""
            inst.offsetX = (inst.offsetX or 0)
                + (a:find("RIGHT") and -step or step) * siblings
        end
        -- ☠ NO STACK COUNT. showStacks DEFAULTS TRUE for icons and squares, so every helper
        -- marker was drawing one -- a number read off whichever cooldown matched, printed on
        -- an icon whose art is pinned to Power Infusion. Krathe, 2026-09-09: "PI does not have
        -- stacks, you only get 1 charge."
        -- ⚠ STORED false, not merely hidden in the panel, so the record says what the frame
        -- draws. The Stack Count group is skipped on these effects too -- see pihNoStacks in
        -- AuraDesigner/UI/Indicators.lua for why that one is hidden rather than greyed.
        inst.showStacks = false
        -- ⚠ A COLOUR HAS NO POSITION; AN ICON DOES. Infused defaults to an icon now, and
        -- the generic default drops it top-left, over the name text. The top-right corner is
        -- where its retired layout group sat, so this default is unchanged from what anyone was
        -- already looking at.
        -- ☠ ASSIGNED, NOT DEFAULTED. This was `inst.anchor or "TOPRIGHT"`, which could
        -- never fire: CreateIndicatorInstance always stamps an anchor (TYPE_DEFAULTS, else
        -- TOPLEFT), so the field is never nil by the time we see it and the line read as a
        -- default while doing nothing. Watched top-left in game. A guard that cannot fire is
        -- worse than no guard -- it says the case is handled.
        if key == "infused" then inst.anchor = "TOPRIGHT" end
        return true
    end

    -- ⚠ REFUSE A SURFACE ANOTHER SIGNAL IS SITTING ON. Two effects cannot share one surface on
    -- one record: the second simply replaces the first. Unreachable on the defaults; the guard
    -- is here for 3b, where the user can move a signal.
    local pool = pihOtherPoolRead()
    local occupant = pool and pool[ref] and pool[ref][tgt]
    if type(occupant) == "table" and occupant.pihSignal and occupant.pihSignal ~= key then
        return false, "that surface is already taken by another signal"
    end

    local cfg = EnsureTypeConfig(ref, tgt, pihOtherPoolWrite())
    if not cfg then return false, "could not create the effect" end
    -- ☠ THE MARK. This one field is what makes every question above answerable.
    cfg.pihSignal = key
    cfg[pihColorKey(tgt)] = { r = def.color[1], g = def.color[2], b = def.color[3], a = 1 }
    -- ☠ TINT, NOT REPLACE. A health-bar effect's generic default is Replace, which
    -- repaints the whole bar and covers every other tint -- the exact collision the panel's
    -- own note says cannot happen. Tint is the mode that stacks. Only healthbar has a mode.
    if tgt == "healthbar" then cfg.mode = "Tint" end
    -- ⚠ OTHERS ONLY -- EXCEPT FOR INFUSED, AND THE EXCEPTION IS THE SIGNAL. For the
    -- cooldown signals, "cast by someone else" is what makes them about OTHER PLAYERS (and
    -- keeps Twins of the Sun Priestess from lighting our own frame after every cast). But
    -- Power Infusion on a teammate is ALWAYS the priest's own cast -- an others-only infused
    -- mark filters out the one thing it exists to show. Field-found in the second group
    -- session: the violet had never rendered anywhere, since the day it was built. Twins
    -- copying PI onto the priest now lights their own frame violet, which is simply true.
    cfg.othersOnly = (key ~= "infused") or nil
    cfg.enabled = true
    -- Always nil now: no signal judges two things at once since strong window was retired.
    -- Written explicitly because it CLEARS a chain left behind by an older build.
    cfg.conditions = nil
    return true
end

-- ★★★ THE STORE-WIDE PURGE — every mark that is somewhere no control can reach it.
--
-- Two kinds, and the difference is what "stray" means for each:
--   GROUPS  — ALL of them, in every store. The cooldown-icon group is retired outright
--             (schema 5), so a marked group is stray wherever it sits.
--   EFFECTS — only those OUTSIDE adDB.otherAuras. The other pool is the helper's real home
--             and its records are live; a marked effect in a SPEC pool is a different animal.
--
-- ☠ A SPEC-POOL HELPER EFFECT CANNOT WORK AND CANNOT BE REMOVED, which is why deleting one is
-- not the loss it looks like. poolFilter answers "HELPFUL|PLAYER" for a My Buffs record before
-- it ever consults othersOnly, so an effect there is asking for "other people's cooldowns,
-- cast by me" -- a condition nobody can satisfy. And no list shows it: pihFound and
-- S.PIH_PreviewPool read the other pool only, while CollectAllEffects hides marked rows from
-- every pool that is not the helper's. It renders nothing, lists nowhere, deletes never.
--
-- Returns the two counts so the caller can say what it did rather than guessing.
local function pihPurgeStrayMarks()
    local adDB = GetAuraDesignerDB()
    if type(adDB) ~= "table" then return 0, 0 end
    local groups, effects = 0, 0

    -- ☠☠ THE ONE MARKED GROUP THAT IS NOT STRAY, AND THIS FUNCTION PREDATES IT EXISTING.
    -- "Remove EVERY pihSignal group, not the one named burst" was correct when a marked group
    -- could only ever be the retired one -- there was no legitimate home for such a group at
    -- all. There is now: P.PIH_AddIconGroup puts the Cooldown Icons group in otherLayoutGroups
    -- on purpose, and the user adds it from the Effects tab's own grid.
    -- ⇒ Without this line the NEXT schema bump -- any schema bump, for any unrelated reason --
    -- silently deletes it on the next Aura Designer build. It has not bitten yet only because
    -- the group and schema 8 shipped together, so no profile carrying one has re-run this.
    -- ⚠ ONE, NOT "ANYTHING IN THAT STORE". P.PIH_IconGroup returns the FIRST marked group
    -- there, which is the one every reader resolves to; a second would be two containers
    -- competing for the same corner, and purging it is the right answer.
    -- ⚠ THE SAME SHAPE AS THE EFFECT HALF BELOW, which has always exempted its own home
    -- (`poolT ~= home`). The group half simply had no home to exempt.
    local keepGroup = P.PIH_IconGroup and P.PIH_IconGroup() or nil
    for _, store in ipairs(pihAllGroupStores(adDB)) do
        for i = #store, 1, -1 do
            local g = store[i]
            if type(g) == "table" and g.pihSignal and g ~= keepGroup then
                table.remove(store, i)
                -- The fold state is keyed by id and outlives the record; Groups.lua owns the
                -- table, so it owns the forgetting.
                if P.ForgetGroupExpandState and g.id then P.ForgetGroupExpandState(g.id) end
                groups = groups + 1
            end
        end
    end

    local home = adDB.otherAuras
    for _, poolT in ipairs(pihAllAuraPools(adDB)) do
        if poolT ~= home then
            for auraName, auraCfg in pairs(poolT) do
                if type(auraCfg) == "table" then
                    for _, typeKey in ipairs(P.FRAME_LEVEL_TYPE_KEYS or {}) do
                        local cfg = auraCfg[typeKey]
                        if type(cfg) == "table" and cfg.pihSignal then
                            auraCfg[typeKey] = nil
                            effects = effects + 1
                        end
                    end
                    for i = #(auraCfg.indicators or {}), 1, -1 do
                        local inst = auraCfg.indicators[i]
                        if type(inst) == "table" and inst.pihSignal then
                            table.remove(auraCfg.indicators, i)
                            effects = effects + 1
                        end
                    end
                    -- ⚠ THE EMPTIED RECORD GOES TOO, and NOT through S.CleanupAdHocAura --
                    -- that helper prunes from CurrentAuraPool(), the pool of whichever tab is
                    -- open, and this walk is deliberately not asking the open tab anything.
                    if P.AuraHoldsNoEffects and P.AuraHoldsNoEffects(auraCfg) then
                        poolT[auraName] = nil
                    end
                end
            end
        end
    end

    return groups, effects
end

-- ⚠ pihDeleteSignal WENT WITH ITS LAST CALLER (2026-09-09). It removed ONE of a signal's
-- surfaces and stashed the doomed cfg on the way out; both of its callers were the retired
-- surface API (PIH_SetSurface's move, PIH_RemoveSurface's per-row ✕).
-- ⚠ NOTHING WAS LOST WITH IT. Removing one effect is the designer's own ✕ now, and that
-- is deliberate rather than a round trip -- there is nothing to stash. The stash still
-- runs where it is meant to: P.PIH_Remove, which is the ENABLE TICK going off, and which
-- is the one path whose whole promise is that your customisations come back.

-- ─────────────────────────────────────────────────────────────
-- ⚠⚠ THE CLASH WARNING — INTACT, AND CURRENTLY UNREACHED. FLAGGED FOR KRATHE 2026-09-09.
-- ─────────────────────────────────────────────────────────────
-- ☠ THE HAZARD IT WARNS ABOUT IS STILL REAL. Border, name text and health text take a SINGLE
-- winner (pickWinner resolves one candidate per surface from config alone), so a helper border
-- and one of the user's own borders on the same unit means one of them silently does not draw.
-- Health bar and background are MULTI and cannot clash -- see PIH_CONTENDED below.
-- ☠ WHAT WENT IS THE PLACE IT WAS SHOWN, not the machinery. The warning was rendered on the
-- old per-signal rows, and those rows were replaced by the designer's own effect cards, which
-- know nothing about it. So P.PIH_ClashOn / PIH_SiblingContends / PIH_SelfContends and the
-- three helpers under them (pihPools, pihEffectName, pihContends) have NO CALLERS today.
-- ⇒ KEPT RATHER THAN DELETED, deliberately and pending Krathe's call: deleting a safety
-- warning is not a cleanup, and re-deriving this from scratch later costs far more than the
-- lines do. If the answer is "we do not want it", this whole block goes in one cut.
-- ⚠ Do not let it rot silently: it is dead code that LOOKS live, which is the one thing this
-- file keeps auditing itself for.
-- ⚠ PIH_SURFACE_ORDER went with the dropdown that walked it (see the note further down).
-- ─────────────────────────────────────────────────────────────
-- ☠ ONLY THREE OF THE FIVE CONTEND, and the difference is watched in game, not read.
-- Border, name text and health text resolve through `pickWinner`, which takes ONE winner per
-- surface from config alone and tears every other candidate down. Health bar and background
-- tints are MULTI -- `collectFrameTints` renders each on its own presence-gated container,
-- because a static pick cannot ask what is actually on a unit when presence is secret.
-- So a clash warning on those two would be a lie, and a warning that cannot be true is worse
-- than no warning at all.
local PIH_CONTENDED = { border = true, nametext = true, healthtext = true }

-- The exact candidacy test each contended surface applies, copied from the call sites rather
-- than approximated -- a warning that fires when the user has ALREADY applied the fix is worse
-- than one that never fires.
--   border     : ShowBorder ~= false and borderMode ~= "custom"   (Factory.lua:5682)
--                ⭐ "Give this aura its own border" opts an effect OUT of the contest entirely
--                (collectStackedBorders), so it must not count as a clash.
--   name/health: c.color and not c.showWhenMissing                (the TEXT_MIRROR_TYPES pick)
local function pihContends(surface, cfg)
    if type(cfg) ~= "table" or cfg.enabled == false then return false end
    if surface == "border" then
        return cfg.ShowBorder ~= false and cfg.borderMode ~= "custom"
    end
    return cfg.color ~= nil and not cfg.showWhenMissing
end

-- Both aura pools, READ-ONLY.
-- ☠ NEVER THROUGH GetOtherAuras: that accessor CREATES adDB.otherAuras, and merely looking at
-- a settings panel must not write to the profile. The same rule CurrentAuraPool follows.
local function pihPools()
    local out = {}
    local adDB = GetAuraDesignerDB()
    if not adDB then return out end
    local spec = ResolveSpec and ResolveSpec()
    local mine = spec and adDB.auras and adDB.auras[spec]
    if type(mine) == "table" then out[#out + 1] = mine end
    if type(adDB.otherAuras) == "table" then out[#out + 1] = adDB.otherAuras end
    return out
end

-- What an effect calls itself, in the same order the effects list resolves it: its own label
-- first (only helper effects carry one today), then the registry's name for a filter-owned
-- record, then the pool key -- which for an ordinary record IS the aura's name.
local function pihEffectName(auraName, cfg)
    -- Derived from the mark; see pihLabel for why nothing is stored.
    if type(cfg) == "table" and cfg.pihSignal then return pihLabel(cfg.pihSignal) end
    local named = DF.ADFilterRefDisplayName and DF:ADFilterRefDisplayName(auraName)
    return named or auraName
end

-- How many of the USER'S OWN effects would fight this signal for the surface, and what the
-- first one is called. Ours are skipped: two helper signals on one contended surface are
-- prevented outright by the menu, so counting them here would report the same fact twice in
-- two different voices.
-- Scans BOTH pools, because pickWinner does -- a clash living on the other tab is still a clash.
-- ⚠ NAMING THE OFFENDER IS THE POINT. "Something else colours the border" sends someone hunting
-- through their own effects list; naming it turns the warning into an instruction. When several
-- contend, the count says so rather than pretending the named one is the only problem.
function P.PIH_ClashOn(surface)
    if not PIH_CONTENDED[surface] then return 0, nil end
    local n, name = 0, nil
    for _, pool in ipairs(pihPools()) do
        for auraName, auraCfg in pairs(pool) do
            if type(auraCfg) == "table" then
                local cfg = auraCfg[surface]
                if type(cfg) == "table" and not cfg.pihSignal and pihContends(surface, cfg) then
                    n = n + 1
                    if not name then name = pihEffectName(auraName, cfg) end
                end
            end
        end
    end
    return n, name
end

-- ⚠ pihSurfaceTakenBy, pihSiblingContends AND P.PIH_SelfContends WENT WITH THE DROPDOWN AND
-- THE PER-SIGNAL ROWS (2026-09-09). All three asked their question through pihFound(), which
-- returns ONE hit per signal -- fine when a signal had exactly one surface, and wrong the day
-- it could hold several: "does our border contend" was answered about whichever surface the
-- hash order happened to land on, which might be the square.
-- ⇒ P.PIH_ClashText below asks about THE EFFECT IN FRONT OF IT instead -- the card hands over
-- its own config -- so the answer is about the row the badge is on. The sibling term went too:
-- only one signal is creatable now, and one record holds one effect per surface, so "another
-- of OUR signals contends here" is unreachable rather than merely unlikely.

-- ★★★ THE CLASH WARNING, RESTORED TO THE EFFECT CARD (2026-09-09).
--
-- ☠ THE HAZARD IS REAL AND SILENT. Border, name text and health text resolve through
-- pickWinner, which takes ONE winner per surface from config alone and tears every other
-- candidate down -- so a helper border plus one of the user's own borders means one of them
-- simply does not draw, with nothing on screen to say which or why. Health bar and background
-- are MULTI (collectFrameTints renders each on its own container) and cannot clash, which is
-- what PIH_CONTENDED encodes.
--
-- ★ AND ON BORDER THERE IS A WAY TO HAVE BOTH, which is Krathe's own observation
-- (2026-09-09): "with border they can just offset and be able to show two borders like you can
-- with AD anyway?" -- exactly right, and the string has always named it. Ticking "Give this
-- aura its own border" opts that effect OUT of the contest (collectStackedBorders draws it
-- alongside, sorted by priority), so both rings show. The text surfaces have no equivalent
-- opt-out; there the remedy is the Priority slider, which is what their string names.
-- ⚠ SO THE WARNING NAMES A REMEDY THAT STILL EXISTS in both cases -- checked, not assumed:
-- the "own border" checkbox and the Priority slider are both live on the effect card.
--
-- ⚠ IT VANISHES WHEN THE REMEDY IS APPLIED. pihContends runs the REAL candidacy test on our
-- own cfg first, so ticking "own border" on this effect removes the warning from it -- a
-- warning that survives its own fix teaches people to ignore warnings.
-- ⚠ `cfg` IS THE ROW'S OWN CONFIG, not a lookup. See the note above for why that matters.
function P.PIH_ClashText(cfg, surface)
    if not PIH_CONTENDED[surface] then return nil end
    if not pihContends(surface, cfg) then return nil end
    local n, name = P.PIH_ClashOn(surface)
    if n == 0 then return nil end
    local who = name or L["Another effect"]
    if n > 1 then who = format(L["%s and %d more"], who, n - 1) end
    if surface == "border" then
        return format(
            L["%s already colours the border. Only one can show — tick '%s' on one of them, or move this signal somewhere else."],
            who, L["Give this aura its own border"])
    end
    return format(
        L["%s already colours this text. Only one can show — raise this signal's priority, or move it somewhere else."],
        who)
end

-- ☠☠ THE SURFACE DROPDOWN'S WHOLE API LIVED HERE AND IS GONE (2026-09-09).
-- P.PIH_SurfaceOf / P.PIH_SurfaceOptions / P.PIH_SetSurface, plus pihCapture and
-- pihSurfaceTakenBy and the PIH_SURFACE_ORDER list they walked. They answered ONE question --
-- "which single surface is this signal on" -- which is why picking an occupied row had to
-- SWAP two signals: there was nowhere for both to live.
-- ⇒ A signal holds SEVERAL surfaces now and they are added and removed one at a time
-- through the designer's own tiles and effect cards, so "which one" has no answer to give and
-- swapping is not a concept. Every caller went with the dropdown.
-- ⚠ pihPlace SURVIVES: pihSweep's step 4 still uses it to migrate an old Icon to a Square.
-- It is the only reader left, and it passes its own carry table inline.

local function pihPlace(key, auraName, surface, carried)
    -- Bar rides with icon and square for the reason pihCreateSignal spells out: all three are
    -- PLACED types and belong in auraCfg.indicators.
    if surface == "icon" or surface == "square" or surface == "bar" then
        local inst = CreateIndicatorInstance and CreateIndicatorInstance(auraName, surface)
        if not inst then return false end
        inst.pihSignal  = key
        inst.othersOnly = (key ~= "infused") or nil   -- infused = own cast; see pihCreateSignal
        -- Same corner a fresh infused icon gets; see pihCreateSignal for why it is assigned
        -- rather than defaulted.
        if key == "infused" then inst.anchor = "TOPRIGHT" end
        if surface == "icon" then inst.staticSpellID = PIH_PI_SPELL_ID end
        if surface == "square" or surface == "bar" then
            -- Colourless carry falls back to the signal's default, same as the frame branch
            -- below -- the store's default square is white.
            local c = carried and carried.colour
            if not c then
                local d = PIH_SIGNALS[key] and PIH_SIGNALS[key].color
                c = d and { r = d[1], g = d[2], b = d[3], a = 1 } or nil
            end
            if c then inst.color = { r = c.r, g = c.g, b = c.b, a = c.a or 1 } end
        end
        return true
    end
    local cfg = EnsureTypeConfig(auraName, surface, pihOtherPoolWrite())
    if not cfg then return false end
    cfg.pihSignal  = key
    cfg.othersOnly = (key ~= "infused") or nil   -- infused = own cast; see pihCreateSignal
    cfg.enabled    = true
    cfg.conditions = carried and carried.conditions or nil
    -- No colour to carry (an Icon has none) falls back to the signal's OWN default, exactly
    -- like fresh creation -- the alternative was the store's default, which is WHITE:
    -- field-found as "the border didn't appear", because a thin white ring on a path where
    -- every border had been gold is a border nobody can see.
    local c = carried and carried.colour
    if not c then
        local d = PIH_SIGNALS[key] and PIH_SIGNALS[key].color
        c = d and { r = d[1], g = d[2], b = d[3], a = 1 } or nil
    end
    if c then cfg[pihColorKey(surface)] = { r = c.r, g = c.g, b = c.b, a = c.a or 1 } end
    if surface == "healthbar" then cfg.mode = "Tint" end   -- same reason as pihCreateSignal
    return true
end

-- ☠ PICKING AN OCCUPIED SURFACE SWAPS THE TWO SIGNALS. Decided with the user 2026-08-24, after
-- the alternatives were tried and rejected in turn: greying the row misuses the dropdown's group
-- heading and mangles the menu; hiding it makes a possible thing look impossible and reads as
-- "you could never have had that"; refusing on click is a control that looks like it works.
-- Swapping is the only version where every row in the list is a real option and none of them
-- lies -- and it is almost certainly what someone meant, since they wanted that surface for the
-- other signal in the first place.
--
-- Only ever fires between signals on the SAME record, which is the only case that cannot simply
-- coexist; see pihSurfaceTakenBy.
-- ★★★ THE MULTI-SURFACE API (2026-09-08) — add and remove ONE surface at a time.
-- ☠ THESE REPLACE THE DROPDOWN'S "MOVE THE SIGNAL THERE" MODEL. PIH_SetSurface answers
-- "which single surface is this signal on", which is why picking an occupied one had to SWAP
-- two signals -- there was nowhere for both to live. With several surfaces per signal the
-- question changes to "is this surface among the ones it uses", and swapping stops being a
-- concept: two signals wanting a border still contend, but that is the CLASH warning's job
-- and it already says so at the moment it applies.
-- ⚠ BOTH END AT PIH_Apply + pihRefresh, the chokepoint every other helper mutation uses.
-- Writing the record alone leaves the frames on the previous set until something unrelated
-- repaints them -- the same trap the colour picker had.
-- ⚠ `showsAura` IS THE ICON'S ART, ASKED AT ADD TIME. The add flow now picks the picture
-- with a tile rather than leaving it to a tick on the card afterwards, so the create has to
-- be able to carry the answer. nil / false keeps the recipe's pin (Power Infusion).
function P.PIH_AddSurface(key, surface, showsAura)
    if not PIH_SIGNALS[key] then return false, "no such signal" end
    if not surface or surface == "none" then return false, "no surface" end
    -- ☠ showsAura GOES IN, IT IS NOT APPLIED AFTERWARDS. This used to call the create and then
    -- walk every icon the signal held clearing staticSpellID -- correct while one icon was the
    -- most a signal could have, and destructive now that two are allowed: it would have
    -- unpinned the Power Infusion icon already on the frame. The create knows which instance
    -- it just made; nothing else does, which is exactly why the fix-up loop had to guess.
    -- ⚠ AND THE GUARD NEEDS IT TOO -- two icons are only a duplicate when they show the same
    -- art. See pihCreateSignal.
    local ok, why = pihCreateSignal(key, surface, showsAura)
    if ok then P.PIH_Apply() end
    pihRefresh()
    return ok, why
end

-- ⚠ P.PIH_RemoveSurface WENT WITH THE PER-SIGNAL ROWS (2026-09-09). Removing one of a
-- signal's surfaces is the designer's ✕ on the effect card now, which deletes the record
-- the same way it deletes any other. What that button did NOT do is re-derive the engine
-- when the last helper effect goes -- see P.PIH_ReDerive below, which is the half worth
-- keeping from this function.

-- ★★★ THE RE-DERIVE, FOR DELETES THAT DID NOT COME THROUGH THE HELPER (2026-09-09).
--
-- ☠☠ THE CHOKEPOINT STOPPED BEING A CHOKEPOINT WHEN THE EFFECTS TAB BECAME THE DESIGNER'S.
-- pihRefresh's own note records why it exists: "Danders' review found the resident half left
-- armed -- events registered, sound armed -- for a helper with nothing in it". Every helper
-- mutation used to end there, so the re-derive could not be missed.
-- ⇒ Helper effects are now deleted by the DESIGNER'S OWN card, whose ✕ removes the record and
-- runs the AD refresh path -- and knows nothing about the helper. So deleting your last PI
-- effect leaves PIH_Exists() false while the watcher and the sound stay registered for a
-- feature that no longer has anything in it. Exactly the state that review caught, reachable
-- again by a different door.
-- ⚠ IDEMPOTENT AND CHEAP: one pool scan, only on a delete, never in a frame update. Safe to
-- call when the deleted effect was not ours -- it early-outs on PIH_Exists.
-- ⚠ IT DOES NOT REFRESH THE UI. The caller is mid-delete and already runs the designer's own
-- redraw; this is only the ENGINE half, which is the half the designer cannot know about.
function P.PIH_ReDerive()
    if P.PIH_Exists() then return end
    local E = DF.AuraDesigner and DF.AuraDesigner.Engine
    if E and E.PIH_ApplySaved then E:PIH_ApplySaved() end
end

-- ★★★ THE COOLDOWN-ICON GROUP, BACK ON PURPOSE THIS TIME (2026-09-09).
--
-- ☠☠ READ THE RETIREMENT NOTE ABOVE BEFORE TOUCHING THIS. A version of this group shipped,
-- got stuck on Krathe's frames and took three attempts to delete. Every one of those failures
-- was PLUMBING, not the idea: it was created through the pool-routed CreateLayoutGroup from
-- whatever tab happened to be open (so it landed in the SPEC store, where no finder looked),
-- it was switched on by a tick captioned "Icons" buried under Classes and Cooldowns, and the
-- helper had no Layout Groups tab, so nothing could see or configure it.
-- ⇒ WHAT IS DIFFERENT, point by point, because "we fixed it" is not an argument:
--   · CREATED DIRECTLY INTO adDB.otherLayoutGroups. Not through CreateLayoutGroup, whose
--     store depends on the open tab -- the one line that caused the whole mess.
--   · ADDED BY A TILE in the helper's own add grid, beside the surfaces, so it is a visible
--     choice rather than a side effect of a tick.
--   · CONFIGURABLE: the helper's pool has its Layout Groups sub-tab back, and
--     VisibleLayoutGroups already shows exactly the marked groups there. It can be moved,
--     sized and deleted like any other group.
--   · pihPurgeStrayMarks still exists and still finds a marked group in ANY store, so the
--     recovery path that eventually cleaned up the old one is unchanged.
--
-- ⭐ WHY IT EARNS ITS PLACE: a placed icon is ONE slot and shows one arbitrary match. This
-- shows every cooldown the unit actually has up, one icon each -- which is the answer to
-- "allow it to show multiple icons if they have them up" and was Danders' own recommendation
-- for the feature ("build it on merit, not as a fallback").
-- ⚠ THE NAME IS STORED DATA, raw and never L[] -- the same rule the three filter names
-- follow. A translated string in the profile is a name that changes when the client does.
-- ★ "Icons", NOT "Cooldowns" (2026-09-10). Krathe: "maybe it should be called PI Helper -
-- Icons not cooldowns as it can be trinkets etc too?" -- right, and more so since the group
-- gained its own SHOW block: it can be set to trinkets only, in which case a name saying
-- Cooldowns is not merely vague but wrong. PIH_ICON_GROUP_OLD_NAME is what the rename
-- migration recognises; see sweep step 12 for why it matches on the exact old string.
-- ☠ ONE LOCAL, NOT TWO. This file is at Lua's 200-local ceiling in its main chunk, so the
-- old name a migration has to recognise lives inline in sweep step 12 rather than beside
-- this one -- which is also where it is explained. luac refuses the second local outright.
local PIH_ICON_GROUP_NAME = "PI Helper — Icons"

function P.PIH_IconGroup()
    for _, g in ipairs((P.GetOtherLayoutGroups and P.GetOtherLayoutGroups(false)) or {}) do
        if type(g) == "table" and g.pihSignal then return g end
    end
    return nil
end

-- ★★ THE SOURCES SECTION ON THE GROUP'S CARD (2026-09-10), which is what stands where the
-- generic LINKED FILTERS block was dropped. That block offered a filter picker over the
-- helper's own plumbing; this offers the four sources the feature actually has, by name.
-- ⚠ THE SECTION SHAPE IS CollectLayoutGroupSections', because the card and the row layout
-- both run these through their own placer -- see RunCardSections and PaneEnv. `place` sizes
-- and anchors; the builder only says which controls and in what order.
function P.PIH_GroupSourceSection(group)
    return {
        header  = L["Show"],
        caption = L["SHOW"],
        build   = function(env)
            local place, host = env.place, env.host
            local defs = {
                { key = "cooldowns", label = L["Class cooldowns"] },
                { key = "trinkets",  label = L["Trinkets"] },
                { key = "potions",   label = L["Potions"] },
                { key = "racials",   label = L["Racials"] },
            }
            for _, d in ipairs(defs) do
                local key = d.key
                local cb = GUI:CreateCheckbox(host, d.label, nil, nil, nil,
                    function() return P.PIH_GroupSources(group)[key] end,
                    function(v)
                        P.PIH_SetGroupSource(group, key, v)
                        -- ⚠ Rebuild: the footer below says whether this group is following
                        -- Triggers, and the first tick is what stops it doing so.
                        env.Rebuild()
                    end)
                place(cb, 26, { indent = 8 })
            end
            -- ⚠ THE FOOTER IS A STATE READOUT, not a caption. Four ticks that happen to match
            -- the Triggers tab look identical whether they are INHERITING it or were set by
            -- hand to the same thing -- and the difference is whether a later change over
            -- there still reaches this group. So the line says which, and offers the way back.
            if P.PIH_GroupFollowsTriggers(group) then
                local note = GUI:CreateNote(host, L["Following the Triggers tab. Changing one of these stops that."])
                note.fullRow = true
                place(note, 34, { indent = 8, stretch = true })
            else
                local btn = GUI:CreateButton(host, L["Follow Triggers"], 120, 20, function()
                    P.PIH_ResetGroupSources(group)
                    env.Rebuild()
                end)
                place(btn, 28, { indent = 8, width = false })
            end
        end,
    }
end

-- ★★ WHAT IT WATCHES, ON ITS OWN CARD (2026-09-10). Every other group's header carries a
-- filter count, and this one's card deliberately has no Linked Filters block: its list is the
-- cooldown list, which the Triggers tab owns end to end. That left a card saying nothing at
-- all about its contents -- Krathe: "cooldown icons allows for trinkets + the other filters?
-- don't see the option."
-- ⇒ THE ANSWER IS YES, AUTOMATICALLY, and that is the thing to say. The cooldown list NAMES
-- the trinket, potion and racial lists (pihSyncTriggerExtras writes `includes`), so a tick on
-- Triggers reaches these icons with no second control and no way for the two to disagree.
-- ⚠ P.PIH_WatchedCount, not this list's own size -- since the amplifiers stopped being copied
-- in, our list is 40 and the number a user is looking for is the whole watched set.
-- ⚠ COUNTED OVER THE GROUP'S OWN SOURCES, and the wording follows: a group that has been
-- given its own set is no longer reporting "from your Triggers", and a header that said so
-- while the SHOW block underneath disagreed would be the panel contradicting itself one row
-- apart. Following => the Triggers phrasing; overridden => the count alone.
function P.PIH_IconGroupSummary(group)
    local n = P.PIH_WatchedCount and P.PIH_WatchedCount(P.PIH_GroupSources(group)) or 0
    if P.PIH_GroupFollowsTriggers(group) then
        return format(L["%d spells, from your Triggers"], n)
    end
    return format(L["%d spells"], n)
end

-- ★★★ THE COOLDOWN-ICON GROUP PICKS ITS OWN SOURCES (2026-09-10).
--
-- ⭐ WHY IT IS NOT SIMPLY THE TRIGGERS SET. Krathe: "we should let people toggle cooldowns and
-- the sub filters on/off so they can pick from any of the 4... it might be the case they want
-- to trigger from a trinket but only show a CD etc." Triggers answers WHEN the helper fires;
-- this answers WHAT the row of icons then shows, and those are genuinely different questions
-- once you have both a marker and a row.
--
-- ⚠ ABSENT MEANS FOLLOW, and that is the whole compatibility story. `g.pihSources` unset =>
-- the group links the cooldown list and nothing else, whose own `includes` bring in whatever
-- Triggers has ticked -- exactly what it did before this existed, with no migration.
-- ⚠ SET MEANS SPELT OUT. The moment the user touches one tick the group stops inheriting and
-- names all four itself, with selection.noIncludes so the cooldown list is taken literally
-- rather than dragging its own includes in behind it (see foldIncludes in Registry.lua).
-- Materialised from the EFFECTIVE set, so the first click changes exactly the one thing
-- clicked and the other three keep whatever they were showing a moment earlier.
--
-- ☠ NO FILE-SCOPE TABLE FOR THE FOUR KEYS, and that is not a style choice: this file sits
-- at Lua's 200-local ceiling in its main chunk (see the GetUngroupedIndicators removal, which
-- reclaimed one). A `local PIH_SOURCE_ORDER = {...}` here is a COMPILE ERROR, not a smell --
-- luac says "too many local variables". The order lives in the section builder below, which
-- is its only reader anyway.
--
-- The four as they resolve RIGHT NOW: the stored override, or Triggers' own answer.
-- ⚠ COOLDOWNS IS ALWAYS ON WHEN FOLLOWING. It is the baseline the helper is built around --
-- the class list narrows it, nothing switches it off -- so the inherited answer is `true`,
-- and only an explicit override can drop it.
function P.PIH_GroupSources(g)
    local st = P.PIH_Settings()
    local src = type(g) == "table" and g.pihSources or nil
    if type(src) == "table" then
        return {
            cooldowns = src.cooldowns ~= false,
            trinkets  = src.trinkets  == true,
            potions   = src.potions   == true,
            racials   = src.racials   == true,
        }
    end
    return {
        cooldowns = true,
        trinkets  = st.trinkets == true,
        potions   = st.potions  == true,
        racials   = st.racials  == true,
    }
end

function P.PIH_GroupFollowsTriggers(g)
    return not (type(g) == "table" and type(g.pihSources) == "table")
end

-- Rebuild filterSelection from the group's effective sources. The ONE place that shape is
-- written, so "what does this group watch" has a single answer.
local function pihApplyGroupSelection(g)
    if type(g) ~= "table" then return end
    local cdId = pihFilterIdByName(PIH_FILTERS.cooldowns)
    if P.PIH_GroupFollowsTriggers(g) then
        -- Inherit: link the cooldown list and let its includes do the rest.
        g.filterSelection = { presets = {}, customs = cdId and { [cdId] = true } or {} }
        return
    end
    local s = P.PIH_GroupSources(g)
    local presets, customs = {}, {}
    if s.cooldowns and cdId then customs[cdId] = true end
    if s.trinkets then presets[PIH_SEED.amplifiers.trinkets] = true end
    if s.potions  then presets[PIH_SEED.amplifiers.potions]  = true end
    if s.racials then
        local rid = pihFilterIdByName(PIH_FILTERS.racials)
        if rid then customs[rid] = true end
    end
    -- ☠ noIncludes, or "cooldowns only" is unsayable: the cooldown list NAMES the other three
    -- and selecting it would bring them along. See foldIncludes.
    g.filterSelection = { presets = presets, customs = customs, noIncludes = true }
end
P.PIH_ApplyGroupSelection = pihApplyGroupSelection

function P.PIH_SetGroupSource(g, key, on)
    if type(g) ~= "table" then return end
    -- Materialised from what is on screen, so the first click is not also a silent reset of
    -- the other three to some other default.
    local s = P.PIH_GroupSources(g)
    s[key] = on and true or false
    g.pihSources = s
    pihApplyGroupSelection(g)
    pihRefresh()
end

-- Back to inheriting. ⚠ The KEY GOES, rather than being written to match Triggers today:
-- "follow" has to keep following, so a later change on the Triggers tab still reaches it.
function P.PIH_ResetGroupSources(g)
    if type(g) ~= "table" then return end
    g.pihSources = nil
    pihApplyGroupSelection(g)
    pihRefresh()
end

function P.PIH_AddIconGroup()
    if P.PIH_IconGroup() then return true end
    local adDB = GetAuraDesignerDB()
    if not adDB then return false, "no config" end
    local cdId = pihEnsureFilter(PIH_FILTERS.cooldowns, nil, pihSeedIDs())
    if not cdId then return false, "could not build the cooldown list" end
    -- Seeded alongside, so the Racials row has a list to count and to open from the moment
    -- the helper exists -- see pihEnsureRacialFilter. Not fatal if it fails: pihAmplifierIDs
    -- falls back to the seed, so the trigger still works, only the pencil is dead.
    pihEnsureRacialFilter()
    -- ☠ THE OTHER STORE, NAMED. See the note above for what routing this through the
    -- pool-aware creator cost last time.
    local groups = P.GetOtherLayoutGroups and P.GetOtherLayoutGroups(true)
    if not groups then return false, "layout groups unavailable" end
    if not adDB.nextOtherLayoutGroupID then adDB.nextOtherLayoutGroupID = 1 end
    local id = adDB.nextOtherLayoutGroupID
    adDB.nextOtherLayoutGroupID = id + 1
    -- ☠☠ THE SHARED RECORD, AND WRITING IT BY HAND HERE ONCE SHIPPED A BROKEN GROUP. This was
    -- a table literal listing the fields it thought a filter group had, and it did not think of
    -- `iconSize` or `maxIcons` -- both of which CreateLayoutGroup has always set. The sliders
    -- bind those fields directly, so both drew BLANK, and the factory's own fallback for a
    -- filter group's max is 8: "Max icons should default to 4 it's showing blank but seems to
    -- look like 8? Icon size is also showing blank on the slider" (Krathe, 2026-09-10).
    -- ⇒ P.NewLayoutGroupRecord is that list now, and this function overrides only what it
    -- genuinely means differently. What stays hand-rolled is the STORE, which is the whole
    -- reason this does not call CreateLayoutGroup -- see the note above.
    local g = P.NewLayoutGroupRecord(id, PIH_ICON_GROUP_NAME, "filter")
    -- ☠ THE MARK. buildFilterGroupConfig stamps dfGate from it, which is what puts these
    -- icons under the cooldown gate and the role exclusions with everything else.
    g.pihSignal = "burst"
    -- ☠ OTHERS ONLY IS NOT INHERITED. poolFilter reads it off THIS group; without it the
    -- filter is plain HELPFUL and the priest's own cooldowns light their own frame. The
    -- exact trap the first group test found on the effects.
    g.othersOnly = true
    -- ⚠ THROUGH THE SHARED BUILDER, so a new group and an edited one cannot disagree about
    -- the shape. With no pihSources yet this writes exactly what the literal did -- link the
    -- cooldown list, inherit its includes -- which is what "follow Triggers" means.
    pihApplyGroupSelection(g)
    -- Top-right growing left, so a row of cooldown icons runs away from the unit's own name
    -- and health text rather than across them. The shared record's TOPLEFT/RIGHT_DOWN is the
    -- designer's default for a group the user places themselves.
    g.anchor = "TOPRIGHT"
    g.growDirection = "LEFT_DOWN"
    groups[#groups + 1] = g
    pihRefresh()
    return true
end

-- ★ WHICH OF THE TWO ICON ARTS A SIGNAL ALREADY HOLDS (2026-09-10). Returns two booleans:
-- pinned (the Power Infusion picture) and dynamic (the buff they actually pressed).
-- ⚠ THE SURFACE IS NO LONGER THE WHOLE ANSWER. P.PIH_SurfacesOf says "an icon exists", which
-- was enough to grey the add tiles while a signal could hold one; it can hold both now, so the
-- grid has to ask which, or one legitimate half of the pair would arrive greyed out.
-- ⚠ READ OFF staticSpellID's PRESENCE, the field that DOES the thing -- there is no second
-- field recording the choice, deliberately (see P.PIH_SetIconShowsAura).
function P.PIH_IconArtHeld(key)
    local pinned, dynamic = false, false
    for _, hit in ipairs(pihFoundAll()[key] or {}) do
        if hit.typeKey == "icon" and type(hit.cfg) == "table" then
            if hit.cfg.staticSpellID ~= nil then pinned = true else dynamic = true end
        end
    end
    return pinned, dynamic
end

-- The surfaces a signal currently holds, in menu order (pihFoundAll sorts them).
-- ⚠ A LIST, NOT A SET: the Effects tab draws one row per entry, in this order, and a set
-- would hand it hash order -- three effects reshuffling themselves on every redraw.
function P.PIH_SurfacesOf(key)
    local out = {}
    for _, hit in ipairs(pihFoundAll()[key] or {}) do out[#out + 1] = hit.typeKey end
    return out
end

-- ─────────────────────────────────────────────────────────────
-- SOUND
-- ─────────────────────────────────────────────────────────────
-- ☠ THE HELPER OWNS THIS ENTRY END TO END. The generic effects list refuses to show `sound` on
-- a filter-owned record -- the native path registers per spell ID, so one big filter would mean
-- one registration per spell in it -- which means it offers no row and no delete button for it
-- either. So the control lives here, and PIH_Remove clears it, because nothing else can.
-- ⚠ Two settings, not one: the key remembers WHICH sound, the switch remembers WHETHER. Turning
-- it off and on again should not make someone hunt for their sound a second time.
function P.PIH_ApplySound()
    local s = P.PIH_Settings()
    local Engine = DF.AuraDesigner and DF.AuraDesigner.Engine
    if Engine and Engine.PIH_SetSound then
        Engine:PIH_SetSound(s.soundOn and s.soundLSMKey or nil)
    end
end

function P.PIH_SetSoundOn(on)
    P.PIH_Settings().soundOn = on and true or nil
    P.PIH_ApplySound()
end

-- ─────────────────────────────────────────────────────────────
-- ONLY WATCH -- whose cooldowns count
-- ─────────────────────────────────────────────────────────────
-- ⚠ CLASSES, NOT SPECS, AND THAT IS THE DATA RATHER THAN A CHOICE. Every record in the spell
-- database carries a class and nothing finer -- there is no spec field in it anywhere. Offering
-- "only watch Fire Mages" would mean hand-authoring which spec each of forty-five cooldowns
-- belongs to and re-authoring it every patch: a dataset to maintain, not a control to build.
-- ⚠ RACIALS ARE TAGGED "ALL" and belong to everyone, so no class tick ever removes one.
local function pihClassList()
    local R = DF.FilterRegistry
    local present = {}
    for _, rec in ipairs(pihSeedRecords()) do
        if rec.class and rec.class ~= "ALL" then present[rec.class] = true end
    end
    local out = {}
    -- The registry's own canonical order, read at call time because SpellPicker.lua loads AFTER
    -- this file. Borrowed rather than restated so the helper's list reads in the same order as
    -- the spell picker's instead of in a second order of our own invention.
    for _, token in ipairs((R and R.PickerClassOrder) or {}) do
        if present[token] then out[#out + 1] = token end
    end
    -- ☠ NO RACIAL PSEUDO-CLASS ANY MORE. Racials used to be seeded into the cooldown
    -- list, and because they belong to no class this loop could never surface them -- so they
    -- rode here as a fake fourteenth "class" purely to have something that could switch them
    -- off. They are amplifiers now, with a tick of their own beside trinkets and potions, and
    -- the special case went with them.
    return out
end
P.PIH_ClassList = pihClassList

-- ☠ READ OFF THE LIST, NOT OFF A SETTING. A tick is on when the list still holds at least one
-- of that class's cooldowns -- so the box and the Filter Designer are two views of one thing
-- rather than two records that can disagree. Remove Avatar and the rest by hand over there and
-- Warrior unticks itself here; add one back and it re-ticks. The same reason the signals
-- themselves are read off the effects: a second copy of the truth only ever drifts.
function P.PIH_ClassOn(classFile)
    local R = DF.FilterRegistry
    local id = pihFilterIdByName(PIH_FILTERS.cooldowns)
    local f = id and R and R.GetCustomFilter and R:GetCustomFilter(id)
    -- No list yet means nothing has been taken away yet.
    if not f then return true end
    for _, rec in ipairs(pihSeedRecords()) do
        if rec.class == classFile and (f.spells[rec.id] or f.rawIDs[rec.id]) then
            return true
        end
    end
    return false
end

-- Adds or removes exactly one class's cooldowns from the helper's list. Surgical on purpose:
-- a wipe-and-refill would also undo every hand edit made on the Filters page, and hand editing
-- is the finer control this one deliberately does not try to replace.
local function pihApplyClass(classFile, on)
    local R = DF.FilterRegistry
    local id = pihFilterIdByName(PIH_FILTERS.cooldowns)
    if not (id and R) then return end
    for _, rec in ipairs(pihSeedRecords()) do
        if rec.class == classFile then
            if on then R:AddSpellToCustom(id, rec.id)
            else R:RemoveSpellFromCustom(id, rec.id) end
        end
    end
end

-- ⚠ NOTHING IS STORED. An earlier pass kept an "excluded classes" table beside the list and
-- re-applied it whenever the list was rebuilt. That was a second copy of the truth, and it went
-- out of step the moment anyone edited the list in the Filter Designer: the box would still
-- show Warrior unticked while the spells were back, or the reverse. The tick reads the list, the
-- click edits the list, and there is nothing in between for the two to disagree about.
function P.PIH_SetClassOn(classFile, on)
    pihApplyClass(classFile, on)
    pihRefresh()
end

-- ─────────────────────────────────────────────────────────────
-- ADD / REMOVE / TICK
-- ─────────────────────────────────────────────────────────────
-- ⚠ ADDING TURNS ON ONE SIGNAL. Not everything it could build: a click that produces three
-- indicators the user did not choose is a click that has decided for them, and two of the three
-- are situational. Burst window is the one that is always worth having.
--
-- ☠☠ P.PIH_IconsShow / P.PIH_SetIconsShow LIVED HERE AND ARE GONE (schema 5, 2026-09-09),
-- along with the group name and the two-list table they keyed. They were the cooldown-icon
-- group's whole API: a tick that created a Filter Group of live cooldown icons and a reader
-- that answered off the group's own selection. The group is retired -- see the block near
-- pihIconGroup for why -- so an API that can only create one would be a door back to it.
-- ⚠ WHAT REPLACED THE THREE TICKS THAT RODE UNDER IT: pihSyncTriggerExtras, which writes
-- trinkets / potions / racials into the ONE list the helper matches on. The reader is the
-- stored setting itself now, because there is no group left to read the truth off.

-- ⚠ IT LIVES HERE, NOT BESIDE PIH_IsEnabled, BECAUSE OF ONE UPVALUE. It calls
-- pihCreateSignal, a `local function` declared further up the file than the settings
-- accessors -- referencing it from up there compiles as a nil GLOBAL read, which luac -p
-- is blind to and only the _ENV globals diff catches. Same trap as the one
-- UnitExemptFromHelpfulGate documents.
-- ⚠ TURNING IT ON WITH NOTHING THERE SEEDS THE DEFAULT EFFECT, and that is the one place this
-- differs from AD's switch. AD is enabled and then you add indicators; the helper is a recipe,
-- and a first-ever enable that lit up an empty Effects tab would be a switch with nothing on
-- the other side of it. Only when the pool holds NOTHING of ours -- a re-enable finds its
-- records where it left them and adds nothing.
function P.PIH_SetEnabled(on)
    local s = P.PIH_Settings()
    s.enabled = on and true or false
    if s.enabled and not P.PIH_Exists() then
        local ok, why = pihCreateSignal("burst")
        if not ok then
            DF:DebugWarn("AURADESIGNER", "PIH: could not seed the helper -- %s", tostring(why))
        end
    end
    P.PIH_Apply()
    pihRefresh()
    return s.enabled
end

-- ☠☠ P.PIH_Create AND P.PIH_Remove ARE GONE, AND SO IS EVERYTHING THAT SERVED THEM
-- (2026-09-09). They were the delete-and-rebuild model of the enable tick: Remove deleted
-- every marked record and stashed copies, Create rebuilt from the stash. The tick writes a
-- stored flag now (P.PIH_SetEnabled) and the records are never touched, so both verbs -- and
-- pihStashHits, pihKeptCfg, pihKeptSurfaces, pihRestoreInto and PIH_RECIPE_OWNED with them --
-- answer a question nobody asks.
--
-- ⚠ WHAT WENT WITH THEM, SAID OUT LOUD SO NOBODY REDISCOVERS IT AS A BUG:
--   · THE SPELL LISTS ARE NO LONGER AUTO-DELETED. PIH_Remove used to delete the three
--     "Power Infusion Helper" custom filters once no mark remained in either mode. Nothing
--     removes them now -- correct, because the records that reference them are no longer
--     removed either. They are ordinary custom filters, visible and deletable in the Filter
--     Designer, which is where a user would look for them. A lingering list is cruft; a
--     silently deleted one that an effect still points at is a broken effect.
--   · THE RETAINED-CUSTOMISATION STASH IS UNNECESSARY, not lost. It existed only to survive
--     a round trip that no longer destroys anything. adDB.pihelper.retainedCfg may still sit
--     in old profiles; it is inert and costs a few bytes.

function P.PIH_SetRole(role, on)
    local s = P.PIH_Settings()
    -- PIH_Settings hands back a bare table when there is no Aura Designer config to write to,
    -- and indexing a field that table does not have is an error rather than a no-op.
    s.roles = s.roles or {}
    s.roles[role] = on and true or nil
    P.PIH_Apply()
end

-- The three extra trigger ticks -- trinkets, potions, racials -- all write here. They are one
-- category with three sources: things somebody presses that are worth infusing behind, as
-- against the class cooldowns, which are the same question asked of a spellbook.
--
-- ⚠ ONE WRITE, NOT TWO. It used to write the setting, rebuild a separate amplifier filter,
-- and then link or unlink that filter on the cooldown-icon group -- three facts that could
-- disagree. Now the setting is the choice and pihSyncTriggerExtras is the consequence.
-- ★ HOW MANY CLASS COOLDOWNS ARE ACTUALLY LIVE, for the "Classes and Cooldowns" header.
--
-- ☠ THE COOLDOWNS *TICK* THAT WAS HERE IS GONE, AND IT WAS REDUNDANT AND HARMFUL. Redundant
-- because unticking all thirteen classes IS turning class cooldowns off -- the classes are the
-- control. Harmful because both it and the class ticks READ OFF THE LIST (no stored booleans,
-- deliberately, so nothing can drift): unticking the source removed all forty cooldowns, which
-- made every class tick read off, and ticking it back re-added all forty -- silently undoing
-- whichever classes the user had turned off. A switch that quietly reverts your other choices
-- is worse than no switch, and the alternative -- remembering the class states -- is the stored
-- copy of a derived truth that the class ticks exist to avoid.
--
-- ⚠ THE SEED SET, NOT THE WHOLE LIST. The list also holds trinkets, potions and racials once
-- those are ticked, and counting them under a "Classes and Cooldowns" header would be a number
-- describing something else. Enabled, too: a spell ticked off in the Filter Designer is in the
-- list and not firing, so it is not live.
function P.PIH_CooldownCounts()
    local R = DF.FilterRegistry
    local id = pihFilterIdByName(PIH_FILTERS.cooldowns)
    local f = id and R and R.GetCustomFilter and R:GetCustomFilter(id)
    local ids = pihSeedIDs()
    if not f then return 0, #ids end
    local on = 0
    for _, sid in ipairs(ids) do
        if (f.spells[sid] or f.rawIDs[sid])
            and (not R.IsCustomSpellEnabled or R:IsCustomSpellEnabled(id, sid)) then
            on = on + 1
        end
    end
    return on, #ids
end

function P.PIH_SetAmplifier(which, on)
    local s = P.PIH_Settings()
    s[which] = on and true or false
    pihSyncTriggerExtras(s)
    pihRefresh()
end

function P.PIH_SetGateEnabled(on)
    P.PIH_Settings().gateEnabled = on and true or false
    P.PIH_Apply()
end

-- ★★ THE NAMED-PLAYER ALLOWLIST (2026-09-10). Krathe: "in guild groups it would be useful to
-- only have the PI alert for the DPS you know who should be getting PI instead of every DPS in
-- the raid who uses a CD."
-- ⚠ AN ARRAY OF "Name-Realm", the picker's own order of entry, and the same key the pinned
-- frames list writes -- so a name means the same thing in both and could be pasted between
-- them. The ENGINE turns it into a map (see Engine:PIH_ApplySaved); the panel keeps the array
-- because a list you edit has an order and a set does not.
-- ⚠ EMPTY IS ABSENT. Removing the last name has to leave the helper exactly as it was before
-- the first was added, so the key goes rather than becoming an empty table -- the engine reads
-- a present list as "these players and nobody else".
function P.PIH_Players()
    return P.PIH_Settings().players or {}
end

function P.PIH_SetPlayers(list)
    local s = P.PIH_Settings()
    local out
    for _, fullName in ipairs(list or {}) do
        if type(fullName) == "string" and fullName ~= "" then
            out = out or {}
            out[#out + 1] = fullName
        end
    end
    s.players = out
    P.PIH_Apply()
end

-- The cooldown list's registry id, for deep-linking straight to it in the Filter Designer.
-- nil before the helper exists, which is also when the button that uses it must be dead.
function P.PIH_CooldownFilterID()
    return pihFilterIdByName(PIH_FILTERS.cooldowns)
end

-- ...and the racials list's, for the pencil on its row. Same contract: nil until the helper
-- exists, which is when that pencil must not be drawn.
function P.PIH_RacialFilterID()
    return pihFilterIdByName(PIH_FILTERS.racials)
end

-- How many of a preset category are ON, and how many it holds.
-- ⚠ ENABLED / TOTAL, NOT #recs. A spell ticked off in the Filter Designer stops being
-- selected by ResolveSelection (recordSelected calls IsSpellEnabled), so a row reporting the
-- raw size claims a number the engine does not act on -- the fault Krathe caught on the
-- cooldown count, "the number does not change as I tick them on/off".
function P.PIH_PresetCounts(catKey)
    local R = DF.FilterRegistry
    local recs = (R and R.ByCategory and R.ByCategory[catKey]) or {}
    local on = 0
    for _, rec in ipairs(recs) do
        if not R.IsSpellEnabled or R:IsSpellEnabled(catKey, rec) then on = on + 1 end
    end
    return on, #recs
end

-- ★ EVERYTHING A SET OF SOURCES WATCHES, COUNTED THE WAY THE PANEL COUNTS IT: each ticked
-- source contributing its own ENABLED total.
-- ☠ NOT THE RESOLVED MAP. R:ResolveSelection returns spell IDs with every variant expanded,
-- which for this set is several hundred -- a true number of a thing nobody is counting. The
-- rows on the Triggers tab say 40, 41, 6 and 4; this has to be their sum or the two screens
-- disagree about the same feature.
-- ⚠ `sources` IS AN ARGUMENT, defaulting to the Triggers ticks. Krathe, 2026-09-10: "the
-- number of spells tracked does not seem to update on the show toggles but only on the
-- triggers" -- because this read P.PIH_Settings() outright, so the Cooldown Icons header
-- reported what the HELPER fires on while the card under it listed what the GROUP shows. Two
-- numbers for two different questions, and only one of them was being asked.
-- ⚠ COOLDOWNS IS A SOURCE HERE TOO, not an always-on baseline: the group can switch it off,
-- and a count that added the class list regardless would over-report by forty.
function P.PIH_WatchedCount(sources)
    local R = DF.FilterRegistry
    local s = sources
    if not s then
        local st = P.PIH_Settings()
        s = { cooldowns = true, trinkets = st.trinkets == true,
              potions = st.potions == true, racials = st.racials == true }
    end
    local total = 0
    local id = pihFilterIdByName(PIH_FILTERS.cooldowns)
    if s.cooldowns and id and R and R.CustomFilterCounts then
        total = R:CustomFilterCounts(id)
    end
    if s.trinkets then total = total + P.PIH_PresetCounts(PIH_SEED.amplifiers.trinkets) end
    if s.potions  then total = total + P.PIH_PresetCounts(PIH_SEED.amplifiers.potions)  end
    if s.racials  then total = total + P.PIH_RacialCounts() end
    return total
end

-- How many racials are ON, and how many are in the list. Falls back to the seed's size before
-- the list exists, so the row reads 4 rather than 0 on a helper that has not been created --
-- which is the number that will be true the moment it is.
function P.PIH_RacialCounts()
    local R = DF.FilterRegistry
    local id = pihFilterIdByName(PIH_FILTERS.racials)
    if id and R and R.CustomFilterCounts then
        local on, total = R:CustomFilterCounts(id)
        if total > 0 then return on, total end
    end
    return #PIH_RACIAL_IDS, #PIH_RACIAL_IDS
end

-- ============================================================
-- GLOBAL VIEW (used by Global tab)
-- ============================================================

-- Hardcoded fallbacks for global defaults (used when profile is missing new keys)
local GLOBAL_DEFAULTS_FALLBACK = {
    iconSize = 24, iconScale = 1.0,
    showDuration = true, showStacks = true,
    durationFont = "DF Roboto SemiBold", durationScale = 1.2,
    durationOutline = "SHADOW;OUTLINE", durationAnchor = "CENTER",
    durationX = 0, durationY = 0, durationColorByTime = true,
    durationColor = {r = 1, g = 1, b = 1, a = 1},
    durationHideAboveEnabled = false, durationHideAboveThreshold = 10,
    stackFont = "DF Roboto SemiBold", stackScale = 1.0,
    stackOutline = "SHADOW;OUTLINE", stackAnchor = "BOTTOMRIGHT",
    stackX = 2, stackY = -2,
    stackColor = {r = 1, g = 1, b = 1, a = 1},
    iconBorderEnabled = true, iconBorderThickness = 1,
    hideSwipe = false, hideIcon = false,
    -- ⚠ THE FRAME LEVEL HAD NO ENTRY HERE, and the General group has bound a
    -- slider to it since it was wired. Every other control in that group resolves
    -- through this table; this one fell through to nil on any profile whose
    -- auraDesigner block predates the setting. It survived because a shipped
    -- profile IS seeded with it (Config.lua's auraDesigner.defaults) -- but the
    -- diff engine reads "no default" as "not a setting in this record", so the
    -- General row's modified tick could not have answered for the key and Reset
    -- Group would have skipped it.
    --
    -- ☠ 40, NOT 0. The stored number is an ABSOLUTE offset from the unit frame and
    -- the render uses it as-is; 40 is the no-op. Config.lua says so at length.
    -- ⚠ EVERY VALUE IN THIS TABLE MUST AGREE WITH Config.lua's
    -- auraDesigner.defaults for the keys both name -- this one is what the tick
    -- measures against and that one is what a profile is seeded with, so a
    -- disagreement is a control that reports modified the day it is created.
    indicatorFrameLevel = 40,
}
P.GLOBAL_DEFAULTS_FALLBACK = GLOBAL_DEFAULTS_FALLBACK

-- ============================================================
-- THE GLOBAL TAB'S RECORD
-- ------------------------------------------------------------
-- One proxy over `adDB.defaults`, so every write triggers the full preview
-- rebuild (a global default affects ALL indicators) and every read falls back to
-- GLOBAL_DEFAULTS_FALLBACK for keys an older profile is missing.
--
-- ☠ AND IT CARRIES THE DEFAULTS ADAPTER, which is what a popout row on this tab
-- needs before it can say anything true. The diff engine recognises DF.db.party /
-- DF.db.raid BY IDENTITY and answers nil for everything else, so a row handed
-- this proxy without an adapter would have a permanently dark modified tick and a
-- Reset Group that wrote nothing while saying it had -- silently, with no error on
-- either. See DandersFrames/Core/Defaults.lua's header for the contract.
--
-- ☠ GetStored IS A rawget ON THE STORED BLOCK, never a read through this proxy:
-- __index answers with the fallback for an unset key, so an adapter reading back
-- through itself would find every key set and light the whole tab up. Same rule
-- CreateInstanceProxy documents at length (AuraDesigner/UI/Groups.lua).
--
-- ClearKey UNSETS rather than writing the fallback in, because the proxy resolves
-- through GLOBAL_DEFAULTS_FALLBACK anyway -- so a reset leaves the profile
-- FOLLOWING the shipped value instead of pinning it at today's copy of it. The
-- Text Designer's Global tab cannot do this (its widgets bind the stored block
-- directly and would be handed a nil); this one can, because nothing reads the
-- block except through here and the factory's own defaults resolution.
--
-- ⚠ THE BLOCK IS RE-RESOLVED PER ACCESS, not captured once at build. The card
-- layout captured `adDB.defaults` in a local, which was correct only because the
-- page is rebuilt on every mode and preset switch; a row's footer verbs run long
-- after the build that made them.
-- ============================================================
local function CreateGlobalDefaultsProxy()
    local function stored()
        local adDB = GetAuraDesignerDB()
        return adDB and adDB.defaults
    end
    local function refresh()
        RefreshPlacedIndicators()
        RefreshPreviewEffects()
        RefreshLiveFramesThrottled()
    end
    local adapter = {
        GetDefault = function(k) return GLOBAL_DEFAULTS_FALLBACK[k] end,
        GetStored  = function(k)
            local t = stored()
            if not t then return nil end
            return rawget(t, k)
        end,
        ClearKey = function(k)
            local t = stored()
            if not t then return end
            t[k] = nil
            refresh()
        end,
    }
    -- __dfDefaults exposes the fallback table to GUI:CreateColorPicker's Default button.
    return setmetatable({ _skipOverrideIndicators = true,
                          __dfDefaults = GLOBAL_DEFAULTS_FALLBACK,
                          __dfDefaultsAdapter = adapter }, {
        __index = function(_, k)
            local t = stored()
            local v = t and t[k]
            if v ~= nil then return v end
            return GLOBAL_DEFAULTS_FALLBACK[k]
        end,
        __newindex = function(_, k, v)
            local t = stored()
            if not t then return end
            t[k] = v
            refresh()
        end,
    })
end
P.CreateGlobalDefaultsProxy = CreateGlobalDefaultsProxy

-- ============================================================
-- THE GLOBAL TAB'S SOUND BLOCK
-- ------------------------------------------------------------
-- soundEnabled and soundChannel are the two settings on this tab that do NOT
-- live in `adDB.defaults` -- they sit on the Aura Designer block itself, and the
-- two controls bound to them use custom get/set rather than a db table and key.
-- That is fine for the controls and useless to a row, which needs SOMETHING that
-- can answer "is either of these not the shipped value".
--
-- So the row takes this record and names the two keys through ClaimKeys' `extra`
-- door, which exists for exactly this shape. Absent means enabled and Master, so
-- ClearKey unsets and the pair goes back to following the shipped answer.
-- ============================================================
local SOUND_DEFAULTS = { soundEnabled = true, soundChannel = "Master" }
P.SOUND_DEFAULTS = SOUND_DEFAULTS

local function CreateSoundSettingsProxy()
    local adapter = {
        GetDefault = function(k) return SOUND_DEFAULTS[k] end,
        GetStored  = function(k)
            local adDB = GetAuraDesignerDB()
            if not adDB then return nil end
            return rawget(adDB, k)
        end,
        ClearKey = function(k)
            local adDB = GetAuraDesignerDB()
            if not adDB then return end
            adDB[k] = nil
        end,
    }
    return setmetatable({ _skipOverrideIndicators = true,
                          __dfDefaults = SOUND_DEFAULTS,
                          __dfDefaultsAdapter = adapter }, {
        __index = function(_, k)
            local adDB = GetAuraDesignerDB()
            local v = adDB and adDB[k]
            if v ~= nil then return v end
            return SOUND_DEFAULTS[k]
        end,
        __newindex = function(_, k, v)
            local adDB = GetAuraDesignerDB()
            if adDB then adDB[k] = v end
        end,
    })
end
P.CreateSoundSettingsProxy = CreateSoundSettingsProxy

-- `collect`: COLLECT MODE, the same seam BuildTypeContent carries
-- (AuraDesigner/UI/Indicators.lua). With a table here nothing is built: each
-- AddGroup records its header and its body, unrun, for the row layout to mount
-- one per popout pane. Without one this is the split panel's own column, byte for
-- byte what it always drew.
local function BuildGlobalView(parent, collect)
    local defaults = CreateGlobalDefaultsProxy()

    local parentW = parent:GetWidth()
    if parentW < 50 then parentW = 280 end
    local contentWidth = parentW - 16  -- 8px padding each side
    local totalHeight = 8
    local widgets = {}
    local function RPL() if S.RefreshPreviewLightweight then S.RefreshPreviewLightweight() end end

    local function AddWidget(widget, height)
        widget:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -totalHeight)
        if widget.SetWidth then widget:SetWidth(contentWidth - 10) end
        tinsert(widgets, widget)
        totalHeight = totalHeight + (height or 30)
    end

    -- `rowDB` and `extraKeys` are the ROW layout's business and the card ignores
    -- them: which record a group's popout row measures itself against, and any
    -- key bound through a custom get/set that ClaimKeys' walk therefore cannot
    -- see. `rowDB == false` says the group holds ACTIONS rather than settings --
    -- no modified tick, no Reset Group, because there would be nothing for either
    -- to be about and a footer that reset nothing would be a footer that lied.
    local function AddGroup(header, buildFn, rowDB, extraKeys)
        if collect then
            collect[#collect + 1] = {
                header = header,
                db = (rowDB == nil) and defaults or rowDB,
                extra = extraKeys,
                -- ☠ `parent` IS RE-POINTED AND RESTORED. It is this function's own
                -- local, so re-pointing it re-points every widget the body creates
                -- -- and NOT restoring it would leave the next body building onto
                -- the previous pane's holder. Verbatim from BuildTypeContent's
                -- collect seam, for the same reason.
                --
                -- NO HEADER WIDGET in a pane: the row's own label is this group's
                -- name, and a header inside the panel would say it twice.
                build = function(g, paneParent)
                    local savedParent = parent
                    parent = paneParent
                    buildFn(g)
                    parent = savedParent
                end,
            }
            return
        end
        local group = GUI:CreateSettingsGroup(parent, contentWidth - 10)
        group.padding = 10   -- match the main Options groups' inner padding (airier scale)
        group:AddWidget(GUI:CreateHeader(parent, header), GUI.RowHeight.sectionHeader)
        buildFn(group)
        local h = group:LayoutChildren()
        AddWidget(group, h)
    end

    -- ── GENERAL ──
    AddGroup(L["General"], function(g)
        g:AddWidget(GUI:CreateSlider(parent, L["Default Icon Size"], 8, 64, 1, defaults, "iconSize"), 50)
        g:AddWidget(GUI:CreateSlider(parent, L["Default Scale"], 0.5, 3.0, 0.05, defaults, "iconScale"), 50)
        -- Both LIVE on the container path: Factory.ResolveDefaults bundles them into the
        -- per-pass `defs` table, resolveLevel/resolveStrata walk instance -> global default
        -- (the same chain GLOBAL_DEFAULT_MAP gives the editor proxy, so the two agree), and
        -- AuraContainer's _applyZOrder sets level and strata from the resolved config.
        -- Both ship as no-ops -- level 0, strata INHERIT -- so an untouched profile renders
        -- exactly where it did before they were wired.
        g:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(parent, L["Default Frame Level"], 0, 100, 1, defaults, "indicatorFrameLevel")), 50)
        g:AddWidget(GUI:CreateCheckbox(parent, L["Show Duration"], defaults, "showDuration"), 24)
        g:AddWidget(GUI:CreateCheckbox(parent, L["Show Stacks"], defaults, "showStacks"), 24)
        g:AddWidget(GUI:CreateCheckbox(parent, L["Hide Cooldown Swipe"], defaults, "hideSwipe"), 24)
        g:AddWidget(GUI:CreateCheckbox(parent, L["Hide Icon (Text Only)"], defaults, "hideIcon"), 24)
    end)

    -- ── SOUND ALERTS ──
    -- Set-once settings, relocated here from the enable banner (§11.6 redesign).
    -- Storage keys unchanged: soundEnabled (nil/true = on, false = muted) and
    -- soundChannel (Master default: alerts should stay audible when the player
    -- mutes Sound Effects/Music to cut combat noise).
    AddGroup(L["Sound Alerts"], function(g)
        local SOUND_CHANNELS = {
            Master   = L["Master"],
            SFX      = L["Sound Effects"],
            Music    = L["Music"],
            Ambience = L["Ambience"],
            Dialog   = L["Dialog"],
            _order   = { "Master", "SFX", "Music", "Ambience", "Dialog" },
        }
        g:AddWidget(GUI:CreateCheckbox(parent, L["Enabled"], nil, nil, nil,
            function() return GetAuraDesignerDB().soundEnabled ~= false end,   -- customGet
            function(v)                                                        -- customSet
                local adDB = GetAuraDesignerDB()
                adDB.soundEnabled = v and true or false
                -- ☠ RE-RECONCILE, don't just write the flag. reconcileSoundNow honours
                -- soundEnabled, but nothing here asked it to run -- so a mute would not take
                -- effect until the next UNIT_AURA happened to re-sync each frame, which in a
                -- quiet moment is never. SyncSound registers/unregisters the native handles,
                -- which is exactly what muting has to do.
                if DF.AuraDesigner.SoundEngine and not adDB.soundEnabled then
                    DF.AuraDesigner.SoundEngine:StopAll()
                end
                local SoundFactory = DF.AuraDesigner and DF.AuraDesigner.Factory
                if SoundFactory and SoundFactory.SyncSound and DF.IterateAllFrames then
                    DF:IterateAllFrames(function(frame)
                        if frame and frame.dfADFactory then SoundFactory:SyncSound(frame) end
                    end)
                end
            end), 24)
        g:AddWidget(GUI:CreateDropdown(parent, L["Channel"], SOUND_CHANNELS,
            nil, nil, nil,
            function() return (GetAuraDesignerDB().soundChannel) or "Master" end,  -- customGet
            function(key) GetAuraDesignerDB().soundChannel = key end), 50)         -- customSet
    end, CreateSoundSettingsProxy(), { "soundEnabled", "soundChannel" })

    -- ── DURATION TEXT ──
    AddGroup(L["Duration Text"], function(g)
        g:AddWidget(GUI:CreateFontDropdown(parent, L["Font"], defaults, "durationFont"), 50)
        g:AddWidget(GUI:CreateSlider(parent, L["Scale"], 0.5, 2.0, 0.1, defaults, "durationScale"), 50)
        g:AddWidget(GUI:CreateOutlineDropdown(parent, L["Outline"], defaults, "durationOutline"), 54)
        g:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], defaults, "durationOutline"), 28)
        g:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], OPTS.ANCHOR_OPTIONS, defaults, "durationAnchor"), 54)
        g:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, defaults, "durationX"), 50)
        g:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, defaults, "durationY"), 50)
        g:AddWidget(GUI:CreateCheckbox(parent, L["Color by Time Remaining"], defaults, "durationColorByTime"), 24)
        AddDurationColorsLink(g, parent)
        g:AddWidget(GUI:CreateColorPicker(parent, L["Duration Text Color"], defaults, "durationColor", true, RPL, RPL, true), 32)
        local hideAboveSlider
        local function UpdateHideAboveState()
            if not hideAboveSlider then return end
            if defaults.durationHideAboveEnabled then
                hideAboveSlider:SetAlpha(1)
                hideAboveSlider:EnableMouse(true)
            else
                hideAboveSlider:SetAlpha(0.4)
                hideAboveSlider:EnableMouse(false)
            end
        end
        g:AddWidget(GUI:CreateCheckbox(parent, L["Hide Duration Above Threshold"], defaults, "durationHideAboveEnabled", UpdateHideAboveState), 24)
        hideAboveSlider = GUI:CreateSlider(parent, L["Hide Above (seconds)"], 1, 60, 1, defaults, "durationHideAboveThreshold")
        g:AddWidget(hideAboveSlider, 50)
        UpdateHideAboveState()
    end)

    -- ── STACK TEXT ──
    AddGroup(L["Stack Text"], function(g)
        g:AddWidget(GUI:CreateFontDropdown(parent, L["Font"], defaults, "stackFont"), 50)
        g:AddWidget(GUI:CreateSlider(parent, L["Scale"], 0.5, 2.0, 0.1, defaults, "stackScale"), 50)
        g:AddWidget(GUI:CreateOutlineDropdown(parent, L["Outline"], defaults, "stackOutline"), 54)
        g:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], defaults, "stackOutline"), 28)
        g:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], OPTS.ANCHOR_OPTIONS, defaults, "stackAnchor"), 54)
        g:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, defaults, "stackX"), 50)
        g:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, defaults, "stackY"), 50)
        g:AddWidget(GUI:CreateColorPicker(parent, L["Stack Text Color"], defaults, "stackColor", true, RPL, RPL, true), 32)
    end)

    -- ── IMPORT FROM BUFFS TAB ──
    AddGroup(L["Import from Buffs Tab"], function(g)
        local descFrame = CreateFrame("Frame", nil, parent)
        descFrame:SetHeight(36)
        local descText = descFrame:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        descText:SetPoint("TOPLEFT", 0, 0)
        descText:SetPoint("RIGHT", descFrame, "RIGHT", 0, 0)
        descText:SetJustifyH("LEFT")
        descText:SetWordWrap(true)
        descText:SetText(L["Import your existing Buffs tab settings as defaults for all auras. Compatible settings will be applied automatically."])
        descText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        g:AddWidget(descFrame, 36)

        -- Compatibility list
        local compatItems = {
            {true,  L["Icon size, scale & border"]},
            {true,  L["Duration & stack display"]},
            {true,  L["Font Settings"]},
            {false, L["Position & anchors"]},
            {false, L["Per-aura overrides"]},
        }
        for _, item in ipairs(compatItems) do
            local isCompat = item[1]
            local row = CreateFrame("Frame", nil, parent)
            row:SetHeight(16)
            local lbl = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            lbl:SetPoint("TOPLEFT", 8, 0)
            if isCompat then
                lbl:SetText("|TInterface\\AddOns\\DandersFrames\\Media\\Icons\\check:12:12|t  " .. item[2])
            else
                lbl:SetText("|TInterface\\AddOns\\DandersFrames\\Media\\Icons\\close:12:12|t  " .. item[2])
            end
            lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            g:AddWidget(row, 16)
        end

        -- Import button
        local importBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        DF.GUI:StyleButton(importBtn, { height = 26, text = L["Import Buffs Tab Defaults"] })
        importBtn:SetScript("OnClick", function()
            local mode = (GUI and GUI.SelectedMode) or "party"
            local buffsDB = DF:GetDB(mode)
            if buffsDB and defaults then
                if buffsDB.buffSize then defaults.iconSize = buffsDB.buffSize end
                if buffsDB.buffScale then defaults.iconScale = buffsDB.buffScale end
                if buffsDB.buffShowDuration ~= nil then defaults.showDuration = buffsDB.buffShowDuration end
                if buffsDB.buffShowStacks ~= nil then defaults.showStacks = buffsDB.buffShowStacks end
                if buffsDB.buffBorder ~= nil then defaults.iconBorderEnabled = buffsDB.buffBorder end
                if buffsDB.buffDurationFont then defaults.durationFont = buffsDB.buffDurationFont end
                if buffsDB.buffDurationScale then defaults.durationScale = buffsDB.buffDurationScale end
                if buffsDB.buffDurationOutline then defaults.durationOutline = buffsDB.buffDurationOutline end
                if buffsDB.buffStackFont then defaults.stackFont = buffsDB.buffStackFont end
                if buffsDB.buffStackScale then defaults.stackScale = buffsDB.buffStackScale end
                if buffsDB.buffStackOutline then defaults.stackOutline = buffsDB.buffStackOutline end
                DF:Debug("AD", "Imported Buffs tab defaults")
                importBtn.Text:SetText(L["Imported!"])
                C_Timer.After(1.5, function() importBtn.Text:SetText(L["Import Buffs Tab Defaults"]) end)
                DF:AuraDesigner_RefreshPage()
            end
        end)
        g:AddWidget(importBtn, 32)
    end, false)

    -- ── STANDARD BUFFS ──
    -- Replaces the old coexistence banner's "Disable Buffs" shortcut: standard
    -- buff visibility is Aura Filters' job now, so this just links there.
    AddGroup(L["Standard Buffs"], function(g)
        local descFrame = CreateFrame("Frame", nil, parent)
        descFrame:SetHeight(24)
        local descText = descFrame:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        descText:SetPoint("TOPLEFT", 0, 0)
        descText:SetPoint("RIGHT", descFrame, "RIGHT", 0, 0)
        descText:SetJustifyH("LEFT")
        descText:SetWordWrap(true)
        descText:SetText(L["Standard buff visibility is managed on the Buff Bar page."])
        descText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        g:AddWidget(descFrame, 24)

        local filtersBtn = GUI:CreateButton(parent, L["Filter Designer"], 140, 22, function()
            if GUI.SelectTab and GUI.Pages and GUI.Pages["auras_filterdesigner"] then
                GUI.SelectTab("auras_filterdesigner")
            end
        end)
        if not (GUI.Pages and GUI.Pages["auras_filterdesigner"]) then
            filtersBtn:Disable()
            filtersBtn.Text:SetTextColor(0.4, 0.4, 0.4)
        end
        g:AddWidget(filtersBtn, 28)
    end, false)

    -- ── ACTIONS ──
    AddGroup(L["Actions"], function(g)
        -- Copy Settings to Other Mode button
        local currentMode = (GUI and GUI.SelectedMode) or "party"
        local targetMode = (currentMode == "party") and "raid" or "party"
        local targetLabel = (targetMode == "raid") and L["Raid"] or L["Party"]

        local copyBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        DF.GUI:StyleButton(copyBtn, { height = 26, text = format(L["Copy Settings to %s"], targetLabel) })
        copyBtn:SetScript("OnClick", function()
            local srcMode = (GUI and GUI.SelectedMode) or "party"
            local dstMode = (srcMode == "party") and "raid" or "party"
            -- Copy at the preset level: the source mode's preset content is
            -- copied INTO the dest mode's preset, in place, so the dest preset
            -- object identity (and every consumer bound to it) is preserved.
            -- BASE resolvers: this S.page edits the user's BASE presets — with a
            -- runtime auto-layout active, the ACTIVE resolver would copy
            -- from/into the layout's preset instead.
            local source = (DF.GetModeBaseAuraDesigner and DF:GetModeBaseAuraDesigner(srcMode))
                or (DF.GetModeAuraDesigner and DF:GetModeAuraDesigner(srcMode))
                or (DF:GetDB(srcMode) and DF:GetDB(srcMode).auraDesigner)
            local dest = (DF.GetModeBaseAuraDesigner and DF:GetModeBaseAuraDesigner(dstMode))
                or (DF.GetModeAuraDesigner and DF:GetModeAuraDesigner(dstMode))
                or (DF:GetDB(dstMode) and DF:GetDB(dstMode).auraDesigner)
            if source and dest and source ~= dest then
                local function DeepCopy(src)
                    if type(src) ~= "table" then return src end
                    local copy = {}
                    for k, v in pairs(src) do copy[k] = DeepCopy(v) end
                    return copy
                end
                -- Clear stale dest keys the source no longer has, then overwrite.
                for k in pairs(dest) do dest[k] = nil end
                for k, v in pairs(source) do dest[k] = DeepCopy(v) end
            end
            DF:Debug("AD", "Copied %s settings to %s", tostring(srcMode), tostring(dstMode))
        end)
        g:AddWidget(copyBtn, 32)

        -- Reset All button
        local resetBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        resetBtn:SetHeight(26)
        -- Persistent-red destructive button via the shared styler, now gated by a
        -- confirmation (was a one-click wipe).
        DF.GUI:StyleButton(resetBtn, { height = 26, primary = true, accent = { r = 0.8, g = 0.25, b = 0.25 }, text = L["Reset All Aura Configs"] })
        resetBtn:SetScript("OnClick", function()
            DF:ShowPopupAlert({
                title = L["Reset All Aura Configs"],
                message = L["Reset ALL aura configurations to defaults?\n\nThis cannot be undone."],
                buttons = {
                    {
                        label = L["Reset"],
                        onClick = function()
                            wipe(GetAuraDesignerDB().auras)
                            -- "Reset ALL" covers the Other Buffs pool too (B2)
                            if GetAuraDesignerDB().otherAuras then
                                wipe(GetAuraDesignerDB().otherAuras)
                            end
                            DF:AuraDesigner_RefreshPage()
                            RefreshLiveFramesThrottled()
                            DF:Debug("AD", "Reset all aura configurations")
                        end,
                    },
                    { label = L["Cancel"] },
                },
            })
        end)
        g:AddWidget(resetBtn, 32)
    end, false)

    -- Collect mode builds nothing and sizes nothing: the section list is the
    -- whole return, and the host it was handed is untouched.
    if collect then return collect end

    parent:SetHeight(totalHeight + 10)
end
P.BuildGlobalView = BuildGlobalView

-- BuildPerAuraView + RefreshRightPanel removed in v4 redesign
-- Per-aura configuration is now done via flat effect cards in the Effects tab
-- (their dummy stubs were unreferenced — reclaimed for the 200-locals ceiling)

-- ============================================================
-- ENABLE BANNER
-- ============================================================

local function CreateEnableBanner(parent)
    local banner = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    -- Two-row layout: row 1 (36px) has Enable toggle (left) + Sync/Copy buttons
    -- (right); row 2 (32px) is the preset bar (anchored into the banner by the
    -- S.page build; the spec dropdown moved onto the B2 main tab strip). Sound
    -- Alerts live on the Global tab (set-once settings).
    banner:SetHeight(68)
    banner:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    banner:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    GUI:CreatePanelBackdrop(banner, {borderColor = {r = 0.30, g = 0.30, b = 0.30, a = 0.5}})

    -- Subtle divider between the two rows
    local rowDivider = banner:CreateTexture(nil, "BACKGROUND")
    rowDivider:SetHeight(1)
    rowDivider:SetPoint("TOPLEFT", banner, "TOPLEFT", 0, -36)
    rowDivider:SetPoint("TOPRIGHT", banner, "TOPRIGHT", 0, -36)
    rowDivider:SetColorTexture(0.25, 0.25, 0.25, 1)

    -- Themed checkbox (matches GUI:CreateCheckbox style)
    -- Row 1 centre = 18px from top. Banner centre = 34px from top.
    -- Offset from banner centre to row 1 centre = +16.
    local cb = CreateFrame("CheckButton", nil, banner, "BackdropTemplate")
    cb:SetPoint("LEFT", banner, "LEFT", 10, 16)
    DF.GUI:StyleCheckButton(cb)

    -- ☠ THE ENABLE IS PER-MODE NOW, not a field on the shared template. Reading it off
    -- the preset made this box show -- and set -- the OTHER mode's value whenever both
    -- modes pointed at the same template. See DF:IsAuraDesignerEnabledForMode.
    local adDB = GetAuraDesignerDB()
    cb:SetChecked(DF.IsAuraDesignerEnabledForMode and DF:IsAuraDesignerEnabledForMode(((GUI and GUI.SelectedMode) or "party")))

    cb:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        -- ⚠ STILL NIL-GUARDED, THOUGH IT NO LONGER CARRIES THE ENABLE. GetAuraDesignerDB
        -- can answer nil before the profile DB exists, and a click with no config behind it
        -- cannot mean anything: the toggle writes through the MODE db now, but the designer
        -- being switched on still has to exist.
        -- (This used to say the build above "guards its own read (`adDB and adDB.enabled`)
        -- and this has to match". That stopped being true when the enable moved to the mode
        -- -- the build reads DF:IsAuraDesignerEnabledForMode, and this guard is about the
        -- CONFIG existing, not about its enable field.)
        local clickDB = GetAuraDesignerDB()
        if not clickDB then
            self:SetChecked(false)
            return
        end
        if checked then
            -- ☠ NEVER RE-RUN THE ENABLE FLOW ON AN ALREADY-ENABLED DESIGNER. The popup's
            -- answer WRITES db.showBuffs, so every spurious trip through here silently
            -- flipped the Buff Bar's own Show Buffs behind the user's back -- reported as
            -- "enabling an already 'enabled' Aura Designer can corrupt other settings and
            -- cascade", and as buffs being on with the Buff Bar option off (Aphoex,
            -- 2026-08-14). A checkbox that is already checked has nothing to ask and
            -- nothing to write; re-sync it and stop.
            if DF:IsAuraDesignerEnabledForMode(((GUI and GUI.SelectedMode) or "party")) then
                self:SetChecked(true)
                return
            end
            -- ⚠ CAPTURE THE MODE NOW, at the click, not when the answer arrives. The
            -- popup is modeless: the user can change the mode tab while it is open, and
            -- S.db is rebound by the page build — reading it in the callback would land
            -- BOTH writes (the enable and Show Buffs) on whichever mode they happened
            -- to switch to. targetMode is the same capture the targetDB line has always
            -- been; the first cut of the per-mode enable read GUI.SelectedMode inside
            -- the callback, which was this comment's warning re-instantiated.
            local targetDB = S.db
            local targetMode = (GUI and GUI.SelectedMode) or "party"
            -- Show popup asking about buff coexistence
            ShowBuffCoexistPopup(function(keepBuffs)
                -- targetMode/targetDB, captured above and for the same reason: the
                -- answer must land on the mode the click was made against.
                DF:SetAuraDesignerEnabledForMode(targetMode, true)
                -- This is a real edit to another page's setting, so SAY so. It is the
                -- whole point of the question, but the page that owns the key is two
                -- clicks away and the user has no other way to know it moved.
                local buffsChanged = false
                if targetDB.showBuffs ~= keepBuffs then
                    targetDB.showBuffs = keepBuffs
                    buffsChanged = true
                    DF:Say(keepBuffs and L["Buffs kept alongside Aura Designer."]
                        or L["Buffs turned off — Aura Designer is replacing them."])
                end
                DF:AuraDesigner_RefreshPage()
                DF:InvalidateAuraLayout()
                DF:UpdateAllFrames()
                -- ☠ UpdateAllFrames IS LAYOUT-ONLY, and this popup WRITES showBuffs. The
                -- buff row's show/hide gate lives in the UNIT_AURA-driven UpdateAuras
                -- path, so a layout pass leaves already-shown buff icons on screen until
                -- the next aura event on that unit -- the row stayed up after answering
                -- "replace my buffs" until Show Buffs was toggled by hand or the UI
                -- reloaded (Krathe, 2026-08-19). The Show Buffs checkbox itself carries
                -- exactly this call, with this reasoning written next to it; the popup
                -- that writes the same key never got it.
                -- ⚠ Gated on an actual change: this re-scans auras on every visible frame
                -- and is not free, and the popup can be answered with the value unchanged.
                if buffsChanged and DF.RefreshAllVisibleFrames then
                    DF:RefreshAllVisibleFrames()
                end
                if DF.AuraDesigner and DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end
            end, function()
                -- Cancelled — revert checkbox
                self:SetChecked(false)
            end)
        else
            -- Mirror of the guard above: an already-disabled designer has nothing to turn
            -- off, and the teardown below is not free (ForceRefreshAllFrames).
            if not DF:IsAuraDesignerEnabledForMode(((GUI and GUI.SelectedMode) or "party")) then
                self:SetChecked(false)
                return
            end
            DF:SetAuraDesignerEnabledForMode(((GUI and GUI.SelectedMode) or "party"), false)
            DF:AuraDesigner_RefreshPage()
            DF:InvalidateAuraLayout()
            DF:UpdateAllFrames()
            -- Sync AD indicators to the now-disabled state — clears the leftover
            -- indicators instead of leaving them frozen on screen until /reload.
            if DF.AuraDesigner and DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end
        end
    end)

    local cbLabel = banner:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    cbLabel:SetPoint("LEFT", cb, "RIGHT", 8, 0)
    cbLabel:SetText(L["Enable Aura Designer"])
    cbLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    banner.checkbox = cb
    return banner
end
P.CreateEnableBanner = CreateEnableBanner

-- ============================================================
-- SPEC DROPDOWN (B2: relocated from the enable banner onto the
-- main tab strip's right end — it only applies to My Buffs; the
-- Other Buffs tab greys it with a "shared across specs" caption)
-- ============================================================

local function CreateSpecDropdown(parent)
    -- Spec selector. Ported to the shared GUI:CreateDropdown (inline mode, so the
    -- container is just the opener button — the "Spec:" label beside it is
    -- hand-placed by the S.page build). optionsFunc rebuilds the list each open so
    -- the "Auto (Spec Name)" text always reflects the live detected spec.
    -- The shared dropdown supports per-option colour (the `color` field), so the
    -- class-coloured menu entries are preserved. (The OPENER text stays standard
    -- colour — the shared opener isn't per-value colourable.)
    local SPEC_ORDER = {
        "auto",
        -- Grouped by class (class order), specs in spec-index order
        "ArmsWarrior", "FuryWarrior", "ProtectionWarrior",
        "HolyPaladin", "ProtectionPaladin", "RetributionPaladin",
        "BeastMasteryHunter", "MarksmanshipHunter", "SurvivalHunter",
        "AssassinationRogue", "OutlawRogue", "SubtletyRogue",
        "DisciplinePriest", "HolyPriest", "ShadowPriest",
        "BloodDeathKnight", "FrostDeathKnight", "UnholyDeathKnight",
        "ElementalShaman", "EnhancementShaman", "RestorationShaman",
        "ArcaneMage", "FireMage", "FrostMage",
        "AfflictionWarlock", "DemonologyWarlock", "DestructionWarlock",
        "BrewmasterMonk", "MistweaverMonk", "WindwalkerMonk",
        "BalanceDruid", "FeralDruid", "GuardianDruid", "RestorationDruid",
        "HavocDemonHunter", "VengeanceDemonHunter", "DevourerDemonHunter",
        "DevastationEvoker", "PreservationEvoker", "AugmentationEvoker",
    }
    local function SpecOptionText(specKey)
        if specKey == "auto" then
            local autoSpec = Adapter:GetPlayerSpec()
            if autoSpec then
                return format(L["Auto (%s)"], Adapter:GetSpecDisplayName(autoSpec))
            end
            return L["Auto (detect spec)"]
        end
        return Adapter:GetSpecDisplayName(specKey)
    end
    local function SpecOptionColor(specKey)
        local resolved = specKey
        if specKey == "auto" then resolved = Adapter:GetPlayerSpec() end
        local info = resolved and DF.AuraDesigner.SpecInfo and DF.AuraDesigner.SpecInfo[resolved]
        local cc = info and info.class and RAID_CLASS_COLORS[info.class]
        if cc then return { r = cc.r, g = cc.g, b = cc.b } end
        return nil
    end
    -- All-spec menu: "Auto (<detected>)" pinned first, then every spec grouped
    -- under a class-coloured header row, with the shared dropdown's inline
    -- search (opts.searchable) so 41 entries stay navigable.
    local function BuildSpecOptions()
        local order = {}
        local options = { _order = order }
        tinsert(order, "auto")
        options.auto = {
            value = "auto",
            text = SpecOptionText("auto"),
            color = SpecOptionColor("auto"),
        }
        local lastClass
        for _, specKey in ipairs(SPEC_ORDER) do
            if specKey ~= "auto" then
                local info = DF.AuraDesigner.SpecInfo and DF.AuraDesigner.SpecInfo[specKey]
                local classToken = info and info.class
                if classToken and classToken ~= lastClass then
                    lastClass = classToken
                    local hdrKey = "__hdr_" .. classToken
                    local cc = RAID_CLASS_COLORS[classToken]
                    tinsert(order, hdrKey)
                    options[hdrKey] = {
                        header = true,
                        text = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classToken]) or classToken,
                        color = cc and { r = cc.r, g = cc.g, b = cc.b } or nil,
                    }
                end
                tinsert(order, specKey)
                options[specKey] = {
                    value = specKey,
                    text = SpecOptionText(specKey),
                    color = SpecOptionColor(specKey),
                }
            end
        end
        return options
    end

    local specDrop = GUI:CreateDropdown(
        parent, "", BuildSpecOptions(),
        nil, nil, nil,
        function() return GetAuraDesignerDB().spec or "auto" end,   -- customGet
        function(key)                                                -- customSet
            GetAuraDesignerDB().spec = key
            -- Clear expanded cards (auras change with spec), and close the
            -- shared spell picker — its records/handlers captured the OLD
            -- spec's state at open time (same staleness as a tab switch).
            wipe(expandedCards)
            CloseADPicker()
            DF:AuraDesigner_RefreshPage()
        end,
        -- menuAlign RIGHT: the opener sits near the strip's right side and the
        -- menu is wider than it, so surplus width grows leftward (menu TOPRIGHT
        -- pinned to the opener's BOTTOMRIGHT) instead of spilling off the edge.
        { inline = true, optionsFunc = BuildSpecOptions, searchable = true, menuAlign = "RIGHT" }
    )

    local function UpdateSpecText()
        if specDrop.RebuildOptions then specDrop:RebuildOptions(BuildSpecOptions()) end
        if specDrop.UpdateText then specDrop:UpdateText() end
    end

    return specDrop, UpdateSpecText
end
P.CreateSpecDropdown = CreateSpecDropdown

-- ============================================================
-- FRAME PREVIEW
-- Mock unit frame with health bar, power bar, name, health %,
-- and 9 anchor point dots for indicator placement
-- ============================================================

-- opts.compact -- the BAND form of this canvas, for the popout layout's single
-- column. The anatomy, the nine anchor dots, the drag targets and RefreshGeometry
-- are all identical; two pieces of standing furniture are not:
--   * the three instruction rows along the bottom become the canvas's TOOLTIP.
--     They are 54px of secondary text, and the band the artifact specified is
--     132px tall: label strip 28 + scale slider 30 + those rows 59 leaves 15px
--     for a 64px-tall mock frame, so the mock would be drawn straight over them.
--   * RefreshGeometry's vertical fit accounts for the label+slider strip, which
--     the split-panel form could ignore because it had 400px of height to spend.
-- Omit opts entirely and this is byte-for-byte the canvas the split panel built.
--
-- ☠ AND THREE KNOBS THAT MAKE IT HOST-AGNOSTIC (designer rework phase 4, when the
-- Text Designer replaced its own inferior copy of this canvas with this one). Every
-- one DEFAULTS to what the Aura Designer has always built, so no AD call site moves:
--   opts.scaleDB    the table the Preview Scale slider's value lives on. AD keeps it
--                   on the designer config; the Text Designer has its own key on its
--                   own preset, and a canvas that wrote AD's would be one designer
--                   silently editing the other's setting.
--   opts.placement  the nine anchor dots, the drag hint and the three drag
--                   instructions -- the machinery for PLACING something on the frame.
--                   ☠ IT WRITES SHARED STATE: P.anchorDots is ONE module-level table
--                   and S.dragHintText ONE state field, so a second canvas building
--                   them re-points AD's own drop targets at the other page's mock.
--                   The settings search builds its registry by re-running EVERY
--                   page's builder, so that is not hypothetical. A host with nothing
--                   to place passes false.
--   opts.unitText   the mock's own name and health strings. A host that draws its
--                   OWN text onto the mock (TextDesigner/Preview.lua) would
--                   otherwise get both, overlapping.
--
-- ☠ AND A FOURTH: opts.thumb, THE ADD PANEL'S PICTURE CARDS. The approved add
-- panel draws each effect choice as a PICTURE of the result, and the only honest
-- picture of "what this does to your frame" is this canvas -- the same green
-- fill, the same missing-health remainder, the same power bar, the same name and
-- health strings, read from the same frameDB. A hand-drawn thumbnail was tried
-- and the verdict was "this looks nothing like one of our frames".
--   opts.thumb   { w = <px>, h = <px> } -- an EXPLICIT box instead of the
--                four-sided anchor the band form uses, for two reasons:
--                  * a frame anchored on four sides has no resolved width until
--                    the layout pass, so RefreshGeometry's fit would run against
--                    a zero and take the early exit -- and a thumbnail has no
--                    OnSizeChanged to rescue it, because the box never changes;
--                  * the panel is a fixed 260px popout, so the box IS a constant.
--                The user's Preview Scale is IGNORED here: a thumbnail is sized
--                to its tile, not to a slider on another page. Everything else
--                (the label strip, the anchor dots, the container chrome) is off
--                -- the tile draws its own frame around this.
-- THE COMPACT CANVAS'S GEOMETRY, in screen pixels, named once because the height
-- verb and the canvas itself must agree exactly -- they are two halves of one
-- sum, and a literal in each is how the frame ends up cut off at the bottom.
--   FURNITURE  the label strip along the top -- the title, and at its far end the
--              scale glyph, both inside one 22px band. It was 52 while the Preview
--              Scale slider stood under the title; the slider is behind the glyph
--              now, so 30px of it came back to the frame
--   PAD        breathing room under the mock
--   DY         how far below the container's centre the mock is nudged, so the
--              free space under the furniture is what it is centred in. 6 rather
--              than 20 for the same reason: there is 30px less to clear
--
-- ☠ THESE THREE ARE THE ONLY PLACE THE NUMBERS LIVE. P.CanvasWantedHeight is
-- built out of them, so changing one here changes the band height that goes with
-- it -- do not re-derive that sum anywhere else.
local CANVAS_FURNITURE, CANVAS_PAD, CANVAS_DY = 22, 10, 6

-- ☠ THE SCALE PANEL IS POOLED BY KEY, so its `build` runs ONCE per key and
-- whatever table it captured is what it writes forever. The preview-scale table
-- is NOT stable: it is the current preset's config, and a preset switch, a mode
-- switch or any page rebuild mints a different one. So the slider inside the
-- panel binds to a stable INDIRECTION and whichever canvas is live registers
-- itself against the key -- the same move, for the same reason, as the designers'
-- own record views. Without it, opening the panel after switching template would
-- silently edit the template you had just left.
local scaleHosts   = {}
local scaleProxies = {}
local function ScaleProxy(key)
    local proxy = scaleProxies[key]
    if not proxy then
        proxy = setmetatable({}, {
            __index = function(_, k)
                local h = scaleHosts[key]
                return h and h.db and h.db[k] or nil
            end,
            __newindex = function(_, k, v)
                local h = scaleHosts[key]
                if h and h.db then h.db[k] = v end
            end,
        })
        scaleProxies[key] = proxy
    end
    return proxy
end

-- ── NOTHING DECORATIVE MAY TAKE THE MOUSE ──
-- ☠ ANYTHING DRAWN OVER A CONTROL TAKES ITS CLICKS. A picture inside a tile and
-- an accent outline over a section are both pure decoration, and both cover
-- things the user has to be able to click; one mouse-enabled frame anywhere
-- under them swallows the press across everything they cover -- and the control
-- never even lights, because the hover never reaches it. Reported twice in game
-- for the tiles alone (spec section 27).
--
-- ⚠ A WALK, NOT A LIST. The first fix chased ONE taker (the canvas's scale
-- slider) and the tiles stayed dead, because a preview builds a backdrop, a
-- mock, a border overlay and whatever the effect paints on top -- any of which
-- may enable the mouse now or later. Naming them is a list that rots; walking
-- the subtree cannot.
--
-- ⚠ AND IT COVERS ONLY WHAT EXISTS WHEN IT RUNS. Anything parented in later is
-- not stripped, which is why the tile calls it AFTER its own Paint.
--
-- ONE walk, two consumers: the shared canvas's thumbnail arm below, and the add
-- panel's section outlines (spec section 28).
local function MakeMouseInert(f)
    if not f then return end
    if f.EnableMouse then f:EnableMouse(false) end
    if f.EnableMouseMotion then f:EnableMouseMotion(false) end
    -- Retail splits click from motion; older shims have neither.
    if f.SetMouseClickEnabled then f:SetMouseClickEnabled(false) end
    if f.SetMouseMotionEnabled then f:SetMouseMotionEnabled(false) end
    if f.GetChildren then
        for i = 1, select("#", f:GetChildren()) do
            MakeMouseInert((select(i, f:GetChildren())))
        end
    end
end
P.MakeMouseInert = MakeMouseInert

-- The thumbnail box's own padding, so the mock never touches the tile's edge.
local THUMB_PAD = 4

local function CreateFramePreview(parent, yOffset, rightPanelRef, opts)
    local compact = opts and opts.compact or false
    -- See the header: each defaults to the Aura Designer's own canvas.
    local placement = not (opts and opts.placement == false)
    local unitText  = not (opts and opts.unitText == false)
    local thumb     = opts and opts.thumb or nil
    -- Read current frame settings for the preview
    local mode = (GUI and GUI.SelectedMode) or "party"
    local frameDB = DF:GetDB(mode) or DF.PartyDefaults
    local FRAME_W = frameDB.frameWidth or 125
    local FRAME_H = frameDB.frameHeight or 64
    local POWER_H = frameDB.powerBarHeight or 4
    local showPower = frameDB.showPowerBar

    -- Preview scale, from whichever designer's config this canvas belongs to.
    local adDB = GetAuraDesignerDB()
    local scaleDB = (opts and opts.scaleDB) or adDB
    local previewScale = scaleDB.previewScale or 1.0

    -- Outer container with label
    local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    if thumb then
        -- ☠ AN EXPLICIT BOX, NOT FOUR ANCHORS. See opts.thumb in the header: the
        -- fit below has to be computable NOW, and a four-sided anchor answers 0
        -- until the layout pass. It also means a thumbnail cannot repeat the
        -- zero-height anchor bug (spec section 24) -- both numbers are set here.
        container:SetSize(thumb.w or 76, thumb.h or 44)
        container:SetPoint("TOPLEFT", parent, "TOPLEFT", thumb.x or 0, yOffset)
    else
    local rightInset = rightPanelRef and (rightPanelRef:GetWidth() + 6) or 0
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    container:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -rightInset, yOffset)
    container:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
    container:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -rightInset, 0)
    -- Dark bg + DIM border (matches Text Designer; no solid white outline).
    ApplyBackdrop(container, {r = 0.10, g = 0.10, b = 0.10, a = 1}, {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5})
    -- Apply the subtle spec class-color hint immediately. CreateFramePreview runs
    -- on every S.page build — including a party/raid rebuild (S.page:Refresh always
    -- rebuilds) — so without this the new preview falls back to the dim default
    -- border until the next AuraDesigner_RefreshPage (spec change / tab revisit).
    local cbSpec = ResolveSpec()
    local cbInfo = cbSpec and DF.AuraDesigner.SpecInfo and DF.AuraDesigner.SpecInfo[cbSpec]
    local cbColor = cbInfo and cbInfo.class and RAID_CLASS_COLORS[cbInfo.class]
    if cbColor then
        container:SetBackdropBorderColor(cbColor.r, cbColor.g, cbColor.b, 0.5)
    end
    end

    -- ☠ THE CANVAS MASKS ITS OWN CONTENTS. The mock is scaled by the user and
    -- carries placed indicators anchored OUTSIDE it (a TOP icon sits above the
    -- frame edge), so there is always some scale at which something inside this
    -- box wants to draw beyond it -- and in the band layout what is beyond it is
    -- the pool strip and the tabs, not empty panel. Growing the band (below) is
    -- the answer for the FRAME; this is the answer for everything else.
    container:SetClipsChildren(true)

    -- "Frame Preview" label
    local previewLabel = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    previewLabel:SetPoint("TOPLEFT", 8, -4)
    previewLabel:SetText(L["FRAME PREVIEW"])
    previewLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    -- ☠ opts.hideLabel: THE BAND'S FOLD HEADER ALREADY SAYS THIS. A canvas under
    -- a collapsible FRAME PREVIEW header would print the same two words twice, six
    -- pixels apart. The strip itself STAYS -- the scale glyph lives in it, which is
    -- why CANVAS_FURNITURE does not move -- only the second copy of the title goes.
    if thumb or (opts and opts.hideLabel) then previewLabel:Hide() end

    -- Mock unit frame (centered in container)
    local mockFrame = CreateFrame("Frame", nil, container, "BackdropTemplate")
    mockFrame:SetSize(FRAME_W, FRAME_H)
    -- -20 in the compact form: with the instruction rows gone the free space runs
    -- from under the scale slider to the bottom edge, so the box's own centre is
    -- 20-odd pixels above the centre of what is actually free.
    -- A thumbnail's box holds nothing but the mock, so it is centred dead centre;
    -- the two band forms nudge down to clear the label strip above them.
    mockFrame:SetPoint("CENTER", container, "CENTER", 0,
                       thumb and 0 or (compact and -CANVAS_DY or -4))
    mockFrame:SetScale(previewScale)
    ApplyBackdrop(mockFrame, {r = 0.07, g = 0.07, b = 0.07, a = 1}, {r = 0.27, g = 0.27, b = 0.27, a = 1})
    container.mockFrame = mockFrame

    -- Live geometry. Frame width/height and Preview Scale were read ONCE, above, so
    -- the preview only caught up when something else forced a full page rebuild —
    -- resizing the window, or leaving and returning (Aphoex, 2026-08-12). Re-read
    -- them from AuraDesigner_RefreshPage instead, which is where every other surface
    -- on this page already refreshes.
    --
    -- ☠ CLAMP BOTH AXES. The container is anchored to its panel on all four sides,
    -- and the mock is centred inside at the configured size times the user's scale.
    -- Nothing bounded the vertical, so a tall frame or a high Preview Scale spilled
    -- the mock out through the top and bottom of its box while the width stayed
    -- inside. Fitting to the smaller of the two ratios keeps the preview honest
    -- about proportions — it shrinks, it does not letterbox.
    container.RefreshGeometry = function()
        local fdb = DF:GetDB((GUI and GUI.SelectedMode) or "party") or DF.PartyDefaults
        local w = fdb.frameWidth or 125
        local h = fdb.frameHeight or 64
        mockFrame:SetSize(w, h)

        local want = (scaleDB or {}).previewScale or 1.0

        -- ☠ THE ANCHOR IS PART OF THE SCALE, so both exits set both. A SetPoint
        -- offset on a scaled frame is in that frame's OWN units, so the nudge has
        -- to be divided by the scale to stay a constant number of SCREEN pixels
        -- (see the note below). The early exit used to set the scale and leave the
        -- anchor at its construction value -- and the early exit is the one a
        -- RELOAD takes, so the preview came back 20*(scale-1) pixels too low and
        -- stayed there until the slider was touched.
        local function place(scale)
            mockFrame:SetScale(scale)
            if compact then
                mockFrame:ClearAllPoints()
                mockFrame:SetPoint("CENTER", container, "CENTER", 0, -CANVAS_DY / scale)
            end
        end

        local cw, ch = container:GetWidth() or 0, container:GetHeight() or 0

        -- ☠ A THUMBNAIL FITS ITS BOX AND NOTHING ELSE. `want` is the Preview
        -- Scale slider on the designer page, which is about the CANVAS; obeying
        -- it here would blow a 76px tile up to 2.5x the user's frame width and
        -- clip everything but the middle. The box is an explicit size set at
        -- construction, so this is exact on the first pass -- no early exit and
        -- no OnSizeChanged rescue is needed, which is the point of the explicit
        -- box.
        if thumb then
            if cw < 2 or ch < 2 then place(0.5) return end
            place(math.max(0.1, math.min((cw - THUMB_PAD * 2) / w,
                                         (ch - THUMB_PAD * 2) / h)))
            return
        end

        -- Before the first layout pass the container has no size yet; honour the
        -- user's scale rather than clamping against a zero and collapsing the mock.
        -- OnSizeChanged below re-runs this the moment it has one.
        if cw < 2 or ch < 2 then
            place(want)
            return
        end
        -- 16 = the container's own left/right padding; 28 = that plus the
        -- "FRAME PREVIEW" label strip along the top.
        -- ⚠ THE BAND FORM CLAMPS ON WIDTH ONLY. Horizontal space is the page's
        -- and cannot be negotiated; vertical space CAN, because the band grows to
        -- fit (WantedHeight below). Clamping height here is what made the slider
        -- lie -- it read 1.6 while the mock stayed at whatever fitted 132px.
        local fit = compact and ((cw - 16) / w)
                            or math.min((cw - 16) / w, (ch - 28) / h)
        -- ☠ A SETPOINT OFFSET ON A SCALED FRAME IS IN THAT FRAME'S OWN UNITS.
        -- The mock is nudged CANVAS_DY below the container's centre to sit clear of
        -- the label and slider -- but under SetScale(2.5) that 20 became 50 on
        -- screen, dropping the mock 30px further than the band height allowed for
        -- and cutting it off along the bottom edge. Dividing by the scale keeps the
        -- nudge a constant number of SCREEN pixels, which is what
        -- P.CanvasWantedHeight's arithmetic assumes. See `place` above.
        place(math.max(0.2, math.min(want, fit)))
    end

    -- ⚠ RE-RUN WHEN THE BAND IS FINALLY SIZED. Every other caller of
    -- RefreshGeometry is an EVENT -- the slider moved, the page was shown -- and
    -- on a fresh build all of them can fire before the layout pass has given the
    -- container a width, which sends every one of them down the early exit. This
    -- is the only hook that fires BECAUSE the size arrived.
    --
    -- No loop: the mock is a child, so scaling it and re-anchoring it cannot
    -- resize the container, which takes its height from the band.
    -- ☠ A THUMBNAIL IS DECORATION INSIDE A BUTTON, SO NOTHING IN IT MAY TAKE
    -- THE MOUSE. A tile is a Button and this preview is its child; any descendant
    -- that is mouse-enabled swallows the press over the very picture the button
    -- exists to offer -- and the button never even lights, because the hover
    -- never reaches it. Reported twice: "none of the images are clickable, i have
    -- to click somewhere outside the image", then "dont even get a hover highlight".
    --
    -- ⚠ A WALK, NOT A LIST -- see MakeMouseInert above, which is the walk. This
    -- is only the container's own handle on it, kept because the tile has to be
    -- able to say "strip THIS preview" without knowing what is in it.
    --
    -- ⚠ CALLED BY THE TILE AFTER ITS Paint, NOT HERE: the effect art is added
    -- once this builder has returned, so a walk run here would miss exactly the
    -- frames drawn over the picture.
    function container.DisableMouseTree()
        MakeMouseInert(container)
    end

    container:SetScript("OnSizeChanged", function() container.RefreshGeometry() end)

    -- ⚠ A THUMBNAIL HAS NO SIZE EVENT TO WAIT FOR. Its box was set at the top of
    -- this function, BEFORE the hook above existed, and it never changes again --
    -- so nothing would ever run the fit, and the mock would keep the construction
    -- scale (the user's Preview Scale, which for a thumbnail is simply wrong).
    -- The band forms are left alone: theirs arrives with the layout pass.
    if thumb then container.RefreshGeometry() end

    -- What the host band must be for the mock to clear the furniture above it and
    -- the padding below. Derived from the mock's own anchor: it is centred at
    -- CENTER,0,-20, so the gap from the container's top to the mock's top is
    -- H/2 + 20 - (h*scale)/2, and that must cover the 52px label-plus-slider
    -- strip. Rearranged: H >= 64 + h*scale. The floor is the artifact's 132.
    --
    -- Indicators anchored outside the frame are deliberately NOT in this sum --
    -- they are what SetClipsChildren is for. Sizing the band to the widest
    -- possible indicator overhang would make an empty frame reserve space for
    -- icons that may never be placed.
    container.WantedHeight = function() return P.CanvasWantedHeight(compact, scaleDB) end

    -- Resolve health texture
    local healthTexPath = frameDB.healthTexture or DF.STOCK_BAR_TEXTURE

    -- Health bar background
    local healthBg = mockFrame:CreateTexture(nil, "BACKGROUND")
    healthBg:SetPoint("TOPLEFT", 1, -1)
    if showPower then
        healthBg:SetPoint("BOTTOMRIGHT", mockFrame, "BOTTOMRIGHT", -1, POWER_H + 1)
    else
        healthBg:SetPoint("BOTTOMRIGHT", mockFrame, "BOTTOMRIGHT", -1, 1)
    end
    healthBg:SetColorTexture(0, 0, 0, 0.4)
    -- Exposed so the preview can tint the background when an AD Background Color
    -- effect is configured.
    container.healthBg = healthBg

    -- Health bar fill (72% health)
    local healthFill = mockFrame:CreateTexture(nil, "ARTWORK")
    healthFill:SetPoint("TOPLEFT", 1, -1)
    if showPower then
        healthFill:SetPoint("BOTTOMLEFT", mockFrame, "BOTTOMLEFT", 1, POWER_H + 1)
    else
        healthFill:SetPoint("BOTTOMLEFT", mockFrame, "BOTTOMLEFT", 1, 1)
    end
    healthFill:SetWidth(FRAME_W * 0.72)
    healthFill:SetTexture(healthTexPath)
    healthFill:SetVertexColor(0.18, 0.80, 0.44, 0.85)
    container.healthFill = healthFill

    -- Missing health region
    local missingHealth = mockFrame:CreateTexture(nil, "ARTWORK")
    missingHealth:SetPoint("TOPRIGHT", mockFrame, "TOPRIGHT", -1, -1)
    if showPower then
        missingHealth:SetPoint("BOTTOMRIGHT", mockFrame, "BOTTOMRIGHT", -1, POWER_H + 1)
    else
        missingHealth:SetPoint("BOTTOMRIGHT", mockFrame, "BOTTOMRIGHT", -1, 1)
    end
    missingHealth:SetWidth(FRAME_W * 0.28)
    missingHealth:SetColorTexture(0, 0, 0, 0.4)
    -- Exposed so the preview can tint the missing-health region when the
    -- health-bar indicator is in Tint mode with "Tint Entire Bar" enabled.
    container.missingHealth = missingHealth

    -- Power bar (only if enabled in settings)
    if showPower then
        local powerBg = mockFrame:CreateTexture(nil, "ARTWORK")
        powerBg:SetPoint("BOTTOMLEFT", 1, 1)
        powerBg:SetPoint("BOTTOMRIGHT", mockFrame, "BOTTOMRIGHT", -1, 0)
        powerBg:SetHeight(POWER_H)
        powerBg:SetColorTexture(0.07, 0.07, 0.07, 1)

        local powerFill = mockFrame:CreateTexture(nil, "ARTWORK", nil, 1)
        powerFill:SetPoint("BOTTOMLEFT", 1, 1)
        powerFill:SetHeight(POWER_H)
        powerFill:SetWidth(FRAME_W * 0.85)
        powerFill:SetColorTexture(0.27, 0.53, 1, 0.9)

        -- Power bar top border
        local powerBorder = mockFrame:CreateTexture(nil, "ARTWORK", nil, 2)
        powerBorder:SetPoint("BOTTOMLEFT", mockFrame, "BOTTOMLEFT", 1, POWER_H)
        powerBorder:SetPoint("BOTTOMRIGHT", mockFrame, "BOTTOMRIGHT", -1, POWER_H)
        powerBorder:SetHeight(1)
        powerBorder:SetColorTexture(0.2, 0.2, 0.2, 1)
    end

    -- The mock's OWN name and health strings. A host that draws its own text
    -- onto the mock turns them off -- see opts.unitText in the header.
    if unitText then
    -- Resolve fonts from settings
    local nameFontPath = DF:GetFontPath(frameDB.nameFont) or "Fonts\\FRIZQT__.TTF"
    local nameFontSize = frameDB.nameFontSize or 11
    local healthFontPath = DF:GetFontPath(frameDB.healthFont) or "Fonts\\FRIZQT__.TTF"
    local healthFontSize = frameDB.healthFontSize or 10

    -- Name text (uses user's font + anchor settings)
    local nameAnchor = frameDB.nameTextAnchor or "TOP"
    local nameOffX = frameDB.nameTextX or 0
    local nameOffY = frameDB.nameTextY or -10

    local nameText = mockFrame:CreateFontString(nil, "OVERLAY")
    nameText:SetFont(nameFontPath, nameFontSize, "OUTLINE")
    nameText:SetPoint(nameAnchor, mockFrame, nameAnchor, nameOffX, nameOffY)
    nameText:SetText("Danders")
    nameText:SetTextColor(0.18, 0.80, 0.44, 1)
    container.nameText = nameText

    -- Health percentage (uses user's font + anchor settings)
    local healthAnchor = frameDB.healthTextAnchor or "CENTER"
    local healthOffX = frameDB.healthTextX or 0
    local healthOffY = frameDB.healthTextY or 4

    if frameDB.showHealthText ~= false then
        local hpText = mockFrame:CreateFontString(nil, "OVERLAY")
        hpText:SetFont(healthFontPath, healthFontSize, "OUTLINE")
        hpText:SetPoint(healthAnchor, mockFrame, healthAnchor, healthOffX, healthOffY)
        hpText:SetText("72%")
        hpText:SetTextColor(0.87, 0.87, 0.87, 1)
        container.hpText = hpText
    end
    end  -- unitText

    -- Border overlay (used when border effect is active) — Stage 5.4: a
    -- DF.Border widget covering the mock frame, mirroring the runtime.
    container.borderOverlay = DF.Border:New(mockFrame, { frameLevelOffset = 5, layer = "OVERLAY" })

    -- Click background — no-op in new UI (was used to deselect aura in old tile view)
    local bgClick = CreateFrame("Button", nil, mockFrame)
    bgClick:SetAllPoints()
    bgClick:SetFrameLevel(mockFrame:GetFrameLevel() + 1)  -- Below dots and indicators
    bgClick:RegisterForClicks("LeftButtonUp")

    -- ========================================
    -- 9 ANCHOR POINT DOTS
    -- ========================================
    -- ☠ anchorDots IS ONE MODULE-LEVEL TABLE, shared by every canvas ever built.
    -- A host with nothing to place must not wipe it -- see opts.placement.
    if placement then
    wipe(anchorDots)
    for anchorName, pos in pairs(ANCHOR_POSITIONS) do
        local dotFrame = CreateFrame("Frame", nil, mockFrame)
        dotFrame:SetSize(20, 20)
        dotFrame:SetFrameLevel(mockFrame:GetFrameLevel() + 10)

        -- Position the dot zone
        dotFrame:SetPoint(pos.ax, mockFrame, pos.ay, 0, 0)

        -- The visible dot
        local dc = GetThemeColor()
        local dot = dotFrame:CreateTexture(nil, "OVERLAY")
        dot:SetSize(6, 6)
        dot:SetPoint("CENTER", 0, 0)
        dot:SetColorTexture(dc.r, dc.g, dc.b, 0.3)
        dotFrame.dot = dot

        -- Hover zone (invisible button) -- also acts as drop target during drag
        local hoverBtn = CreateFrame("Button", nil, dotFrame)
        hoverBtn:SetAllPoints()
        local capturedAnchorName = anchorName
        hoverBtn:SetScript("OnEnter", function()
            if dragState.isDragging then
                -- Drag hover: enlarge and accent-color the dot
                local tc = GetThemeColor()
                dot:SetSize(14, 14)
                dot:SetColorTexture(tc.r, tc.g, tc.b, 0.9)
                dragState.dropAnchor = capturedAnchorName
                -- Update hint to show target anchor
                if S.dragHintText and dragState.auraInfo then
                    S.dragHintText:SetText(format(L["Place %s at %s"], dragState.auraInfo.display, capturedAnchorName))
                end
            else
                local tc = GetThemeColor()
                dot:SetSize(10, 10)
                dot:SetColorTexture(tc.r, tc.g, tc.b, 0.7)
            end
        end)
        hoverBtn:SetScript("OnLeave", function()
            if dragState.isDragging then
                -- Revert to drag-active state (not default)
                local tc = GetThemeColor()
                dot:SetSize(10, 10)
                dot:SetColorTexture(tc.r, tc.g, tc.b, 0.5)
                dragState.dropAnchor = nil
                -- Revert hint to generic drag message
                if S.dragHintText and dragState.auraInfo then
                    S.dragHintText:SetText(format(L["Drop on an anchor point to place %s"], dragState.auraInfo.display))
                    S.dragHintText:SetTextColor(tc.r, tc.g, tc.b, 0.9)
                end
            else
                local tc = GetThemeColor()
                dot:SetSize(6, 6)
                dot:SetColorTexture(tc.r, tc.g, tc.b, 0.3)
            end
        end)

        dotFrame.anchorName = anchorName
        dotFrame:Hide()  -- Only visible during active drags
        anchorDots[anchorName] = dotFrame
    end
    end  -- placement

    -- Instructions with keyboard badge styling
    local instrRows = {
        { key = L["Click"],       desc = L["an indicator on the frame to expand its settings"] },
        { key = L["Drag"],        desc = L["a placed indicator to reposition it on the frame"] },
        { key = L["Right-click"], desc = L["a placed indicator to remove it from the frame"] },
    }

    -- ...and a host with nothing to place has no drag instructions to give.
    if not placement then instrRows = {} end

    -- Compact: the same three sentences, on hover instead of underfoot. They are
    -- guidance read once, and the band has no 54px to spend saying it permanently.
    if compact and placement then
        local lines = {}
        for _, row in ipairs(instrRows) do
            lines[#lines + 1] = row.key .. " " .. row.desc
        end
        container:EnableMouse(true)
        container:SetScript("OnEnter", function(self)
            GUI:ShowTooltip(self, { title = L["FRAME PREVIEW"], lines = lines })
        end)
        container:SetScript("OnLeave", function() GUI:HideTooltip() end)
        instrRows = {}
    end

    local instrCount = #instrRows
    for i, row in ipairs(instrRows) do
        local rowBottomOffset = 10 + (instrCount - i) * 18

        -- Key badge background
        local badge = CreateFrame("Frame", nil, container, "BackdropTemplate")
        badge:SetHeight(13)
        badge:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 8, rowBottomOffset)
        ApplyBackdrop(badge, C_ELEMENT, C_BORDER)

        local keyText = badge:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        keyText:SetPoint("CENTER", 0, 0)
        keyText:SetText(row.key)
        keyText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        local keyWidth = keyText:GetStringWidth()
        badge:SetWidth(max(keyWidth + 10, 20))

        -- Description text (word-wrapped within container bounds)
        local descText = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        descText:SetPoint("LEFT", badge, "RIGHT", 5, 0)
        descText:SetPoint("RIGHT", container, "RIGHT", -8, 0)
        descText:SetWordWrap(true)
        descText:SetJustifyH("LEFT")
        descText:SetText(row.desc)
        descText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.8)
    end

    -- ========================================
    -- PREVIEW SCALE SLIDER
    -- ========================================
    -- ⚠ BOTH callbacks go through RefreshGeometry, never SetScale directly. They used
    -- to set the scale raw, which is how the slider could push the mock straight out
    -- through the top and bottom of its box: the container bounds the width, nothing
    -- bounded the height, and 2.5x on a tall frame does not fit either way.
    local function ApplyPreviewScale()
        if container.RefreshGeometry then container.RefreshGeometry() end
        -- The host decides what to do about a new wanted height -- the split panel
        -- has a fixed left half and ignores this; the band layout regrows. Called
        -- on BOTH slider callbacks: during a drag the mock is already at the new
        -- scale and is being masked at the band's current height, so a host that
        -- regrows live keeps the two in step instead of snapping on release.
        if container.onWantHeight then container.onWantHeight(container.WantedHeight()) end
    end
    if compact then
        -- ☠ IN THE BAND, THE SLIDER IS BEHIND A GLYPH. A 220x30 slider with a
        -- typed value box beside it is the loudest object on a page whose whole
        -- problem is noise, and it is a control touched once and then not again --
        -- the same bargain the settings window's own UI-scale slider struck when it
        -- moved behind the header's glyph. It costs 20px in the corner of the label
        -- strip instead of a 30px row across the canvas, and that 30px goes
        -- straight into CANVAS_FURNITURE and back to the frame.
        local popKey = (opts and opts.scaleKey) or "df.previewscale.aura"
        -- Registered BEFORE the panel can be built: the slider reads its value out
        -- of the proxy, and an unregistered key answers nil to every read.
        scaleHosts[popKey] = { db = scaleDB, apply = ApplyPreviewScale }

        local scaleBtn = GUI:CreateGlyphButton(container, {
            size = 20, iconSize = 13,
            texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\open_in_full",
            tooltip = { title = L["Preview Scale"],
                        lines = { L["How large the mock frame is drawn here. Changes nothing in game."] } },
        })
        scaleBtn:SetPoint("TOPRIGHT", container, "TOPRIGHT", -6, -2)
        container.scaleButton = scaleBtn

        local pop
        scaleBtn:SetScript("OnClick", function(self)
            -- Second click on the glyph shuts it, like any toggle.
            if pop and not pop.closed and pop:IsShown() then
                pop:Close("api")
                return
            end
            pop = GUI:CreatePopout({
                key   = popKey,
                title = L["Preview Scale"],
                icon  = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\open_in_full",
                width = 190,
                build = function(po, content)
                    local sl = GUI:CreateSlider(content, L["Preview Scale"], 0.75, 2.5, 0.05,
                        ScaleProxy(popKey), "previewScale",
                        function() local h = scaleHosts[popKey]; if h and h.apply then h.apply() end end,
                        function() local h = scaleHosts[popKey]; if h and h.apply then h.apply() end end)
                    sl:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
                    sl:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
                    sl:SetHeight(30)
                    po.dfScaleSlider = sl
                    -- The shell derives the panel's height from what build mounted
                    -- (Popout:_Resize), so the content strip states its own.
                    content:SetHeight(30)
                end,
            })
            -- ⚠ AND RE-READ THE VALUE ON EVERY OPEN. The panel is POOLED, so its
            -- second open is an ADOPT rather than a build -- the thumb would still
            -- be showing whatever scale the previous template had.
            if pop.dfScaleSlider and pop.dfScaleSlider.RefreshValue then
                pop.dfScaleSlider:RefreshValue()
            end
            pop:Follow(self, { outsideOf = DF.GUIFrame })
            container.scalePopout = pop
        end)

        -- ☠ THE PANEL IS ABOUT THIS CANVAS, so it goes when this canvas does --
        -- the page rebuilding, the user folding the FRAME PREVIEW header over it,
        -- or the window closing. Left up it would be a slider docked to a frame
        -- that is no longer on screen.
        container:HookScript("OnHide", function()
            if pop and not pop.closed then pop:Close("source") end
        end)
    elseif not thumb then
        -- ☠ NOT ON A THUMBNAIL, AND THIS ARM IS WHY THE TILES BROKE TWICE OVER.
        -- A thumbnail is not `compact` -- it is its own form -- so it fell through
        -- to here and every 82px tile in the add panel built a 220x30 Preview
        -- Scale slider. The LABEL it anchors to is hidden for a thumbnail; the
        -- slider is not, so "Preview Scale" was written across every tile.
        --
        -- ☠ AND IT ATE THE CLICKS. A 220x30 frame laid over a 76x44 picture takes
        -- the mouse across the whole image, so the tiles could only be clicked in
        -- the margin AROUND the art -- reported as "none of the images are
        -- clickable, i have to click somewhere outside the image". One arm, both
        -- symptoms.
        --
        -- ⚠ A thumbnail HAS no scale control by design: it is sized to its box on
        -- both axes and ignores the user's Preview Scale, which is about the canvas.
        local scaleSlider = GUI:CreateSlider(container, L["Preview Scale"], 0.75, 2.5, 0.05, scaleDB, "previewScale",
            ApplyPreviewScale,   -- on release
            ApplyPreviewScale    -- during drag
        )
        scaleSlider:SetPoint("TOPLEFT", previewLabel, "BOTTOMLEFT", -4, -4)
        scaleSlider:SetSize(220, 30)
    end

    -- Drag-state hint text (shows contextual guidance during drag operations).
    -- ☠ S.dragHintText IS ONE STATE FIELD -- same reason the dots are gated.
    if placement then
    S.dragHintText = container:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(S.dragHintText, 9, "OUTLINE")
    S.dragHintText:SetPoint("TOP", mockFrame, "BOTTOM", 0, -6)
    S.dragHintText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.8)
    S.dragHintText:SetText("")
    end  -- placement

    return container
end
-- The band height the compact canvas needs at the CURRENT preview scale. Split
-- out of the canvas because the host must size the band BEFORE calling the
-- builder that creates it -- see GUI:BuildDesignerShell's canvasHeight.
function P.CanvasWantedHeight(compact, scaleDB)
    if not compact then return 132 end
    local fdb  = (DF.GetDB and DF:GetDB((GUI and GUI.SelectedMode) or "party")) or DF.PartyDefaults or {}
    local fh   = fdb.frameHeight or 64
    -- The SAME table the canvas's slider writes -- the host passes it, defaulting
    -- to the Aura Designer's config for every caller that names none.
    local want = ((scaleDB or GetAuraDesignerDB()) or {}).previewScale or 1.0

    -- The mock is centred at (0, -CANVAS_DY) in SCREEN pixels -- RefreshGeometry
    -- divides the offset by the scale to keep it so. Its top edge therefore sits
    -- H/2 + CANVAS_DY - (fh*scale)/2 below the container's top, and that has to
    -- clear the furniture; its bottom edge has to leave CANVAS_PAD. Both
    -- rearranged for H, and the larger wins:
    --
    --   top     H >= 2*CANVAS_FURNITURE - 2*CANVAS_DY + fh*scale
    --   bottom  H >= 2*CANVAS_PAD       + 2*CANVAS_DY + fh*scale
    --
    -- Taken as a max rather than assuming which binds, because CANVAS_DY moves
    -- the frame TOWARDS one of them: raise it and the bottom binds, lower it and
    -- the top does.
    local top    = 2 * CANVAS_FURNITURE - 2 * CANVAS_DY + fh * want
    local bottom = 2 * CANVAS_PAD       + 2 * CANVAS_DY + fh * want
    return math.max(132, math.ceil(math.max(top, bottom)))
end

P.CreateFramePreview = CreateFramePreview

-- ============================================================
-- TAB SYSTEM, SPELL PICKER & EFFECT CARDS (v4 redesign)
-- Functions for the new tabbed right panel, spell picker overlay,
-- and collapsible effect card rendering.
-- ============================================================

-- Forward declarations (mutually referencing functions)
-- (S.SwitchTab declared on the state table)
-- (S.BuildEffectsTab, S.BuildGlobalTab, S.BuildLayoutGroupsTab, S.BuildDebuffGroupsTab declared on the state table)
-- (S.CreateEffectCard declared on the state table)

-- (S.spellPickerBlockedIDs declared on the state table)
                                   -- cross-tab block; rebuilt per picker open)
local spellPickerBlockCache = {}   -- auraName -> bool memo over S.spellPickerBlockedIDs
                                   -- (wiped whenever the set is rebuilt) so blocked
                                   -- checks don't re-resolve identity per row bind

-- Cross-tab used check for one picker candidate: any of its identity IDs
-- (nil-spec identity on the Other tab — the naming contract's resolver —
-- else the spec identity) already tracked by the opposite pool.
local function IsCandidateCrossBlocked(auraName, spec)
    if not S.spellPickerBlockedIDs or not next(S.spellPickerBlockedIDs) then return false end
    -- ☠ THE SPEC IS AN INPUT TO THE ANSWER, SO IT BELONGS IN THE KEY. This memoised on
    -- auraName alone while the value came from BuildADIdentityFilters(spec, ...), and the
    -- memo is wiped only when the picker OPENS -- but the spec dropdown lives on a bar the
    -- picker does not hide, so the spec can change under an open picker and a candidate
    -- resolved beforehand kept the previous spec's verdict.
    local effSpec = (not IsOtherTab()) and spec or nil
    local key = tostring(effSpec) .. "\0" .. tostring(auraName)
    local cached = spellPickerBlockCache[key]
    if cached ~= nil then return cached end
    local blocked = false
    -- ☠ NO per-placement mutes here, deliberately. This asks "would adding this spell
    -- collide with something already tracked", and the honest answer is about the AURA, not
    -- about one indicator's narrowing: an aura can carry several indicators and only some of
    -- them may have muted an id. Narrowing on one of them would let a real duplicate through,
    -- which is a worse failure than the cautious answer. A properly narrowed version has to
    -- union each indicator's own set — worth doing, but it is a different question from
    -- "which ids does this placement render".
    local f = DF:BuildADIdentityFilters(effSpec, auraName)
    local map = f and f.includeSpellIDs
    if map then
        for id in pairs(map) do
            if S.spellPickerBlockedIDs[id] then blocked = true; break end
        end
    end
    spellPickerBlockCache[key] = blocked
    return blocked
end

-- Check if a specific aura has a frame-level effect of given type
local function HasFrameEffect(auraName, typeKey)
    local auraCfg = CurrentAuraPool()[auraName]
    return auraCfg and auraCfg[typeKey] ~= nil
end

-- Clear all child frames and regions from the tab content area
local function ClearTabContent()
    if not S.tabContentFrame then return end
    local children = { S.tabContentFrame:GetChildren() }
    for _, child in ipairs(children) do
        child:Hide()
        child:ClearAllPoints()
    end
    local regions = { S.tabContentFrame:GetRegions() }
    for _, region in ipairs(regions) do
        region:Hide()
    end
end

-- ── SHARED PICKER PLUMBING ──
-- Restore hook for the shared picker: fires on ANY close (back/ESC/
-- programmatic/ancestor hide). Brings the tab surfaces back and rebuilds
-- the active tab when an add landed while the picker stayed open.
local function ADPickerClosed()
    S.spellPickerBlockedIDs = nil -- recomputed on next open (memo wiped with it)
    -- ...and every open panel goes back to outlining its own row: the surface
    -- they were all pointing at while the picker covered it is gone. Restores
    -- whatever each one had, which the kit stashed on the way in.
    GUI:ClearPopoutTetherOverride()
    if S.tabBar then S.tabBar:Show() end
    if S.tabScrollFrame then S.tabScrollFrame:Show() end
    if S.adPickerDirty then
        S.adPickerDirty = false
        S.SwitchTab(S.activeTab or "effects")
    end
end

-- Open prelude shared by the three AD contexts: fresh cross-tab block set
-- (the memo over it persists across row rebinds while the picker is up),
-- hide the tab surfaces the overlay replaces, and open the shared picker
-- over the right panel.
local function OpenADPicker(opts)
    S.spellPickerBlockedIDs = CrossPoolTrackedIDs()
    wipe(spellPickerBlockCache)
    S.adPickerDirty = false
    if S.tabBar then S.tabBar:Hide() end
    if S.tabScrollFrame then S.tabScrollFrame:Hide() end
    -- ☠ THE PICKER TAKES A HOST TO COVER, AND THE POPOUT LAYOUT HAS NO RIGHT
    -- PANEL. OpenSpellPicker anchors to this frame and reads its frame level, so a
    -- nil here is an error rather than a degraded picker. In the row layout the
    -- surface it should cover is the settings content area, which is what the
    -- split panel's right half was a half of.
    opts.parent = S.rightPanel or (GUI and GUI.contentFrame)
    opts.onClose = ADPickerClosed
    -- Row tooltips list the ID set the PLACEMENT will track, which on My Buffs
    -- is the curated set and not just what the row's canonical id implies —
    -- HolyArmaments deliberately fuses two spells the database keeps apart. The
    -- row's own `id` is a TOOLTIP id (Config's TooltipSpellIDs sends Ebon Might
    -- to its buff 395296), so without this the only ID a user could see was one
    -- that named a different spell to the one the picker was about to place.
    opts.rowSpellIDs = function(rec)
        local spec = (not IsOtherTab()) and ResolveSpec() or nil
        if not (spec and rec and rec.auraName and Adapter and Adapter.GetAuraSpellIDs) then
            return nil
        end
        return Adapter:GetAuraSpellIDs(spec, rec.auraName)
    end
    -- Empty record list on My Buffs = unsupported/undetected spec: keep
    -- the old picker's guidance instead of a bare "No results found".
    -- (Other Buffs records are the full SpellDB — never empty.)
    if not IsOtherTab() then
        opts.emptyText = L["No trackable spells found for this spec.\n\nYou can select a different spec using the dropdown above."]
    end
    S.adPickerHandle = DF.FilterRegistry:OpenSpellPicker(opts)
    -- ☠ THE PICKER COVERS THE SURFACE EVERY OPEN PANEL IS TETHERED TO. It fills
    -- opts.parent edge to edge, so a panel still outlining the row it was opened
    -- from draws an accent ring around whichever spell rows happen to sit in that
    -- slot -- which reads as "these two rows are selected" and means nothing.
    -- Point them at the covered surface instead, so the outline says "this is the
    -- focus now". AFTER the open, so a picker that failed to open leaves nothing
    -- to restore. Undone by ADPickerClosed, which fires on ANY close.
    GUI:SetPopoutTetherOverride(opts.parent)
end

-- ...and the same prelude for the OTHER way of answering "which aura?". The
-- filter list is a sibling overlay in the same shell over the same host
-- (FilterRegistry/UI/SpellPicker.lua), so it hides the same tab surfaces,
-- retargets the same outlines and restores through the same close hook.
--
-- ☠ IT SHARES S.adPickerHandle DELIBERATELY. CloseADPicker is called on every
-- pool, sub-tab and spec switch precisely because a picker's handlers capture
-- the context they were opened in; a second handle would be a second thing to
-- remember to close, and the one nobody remembered would be the one that leaked.
-- Only one of the two overlays can be up at a time -- both cover the whole host.
local function OpenADFilterPicker(opts)
    S.adPickerDirty = false
    if S.tabBar then S.tabBar:Hide() end
    if S.tabScrollFrame then S.tabScrollFrame:Hide() end
    opts.parent = S.rightPanel or (GUI and GUI.contentFrame)
    opts.onClose = ADPickerClosed
    S.adPickerHandle = DF.FilterRegistry:OpenFilterPicker(opts)
    GUI:SetPopoutTetherOverride(opts.parent)
end

-- ── PICKER RECORDS ──
-- Shared-picker record list for the ACTIVE tab. My Buffs adapts the spec's
-- merged trackable list (curated Config entries + the SpellDB class pool +
-- class="ALL"); Other Buffs adapts the full SpellDB pool. includeAdHoc adds
-- configured "#<id>" auras (group + trigger pickers — never in the
-- trackable pool). Records carry the SpellDB-compatible shape the shared
-- picker renders (id / class / cats plus display and icon overrides — the
-- icon override keeps the static IconTextures talent-guard) plus
-- `auraName`, the stable AD config key the row handlers write.
local function BuildADPickerRecords(includeAdHoc)
    local isOther = IsOtherTab()
    local spec = (not isOther) and ResolveSpec() or nil
    local auras
    if isOther then
        auras = Adapter and Adapter.GetAllTrackableAuras and Adapter:GetAllTrackableAuras()
    else
        auras = spec and Adapter and Adapter:GetTrackableAuras(spec)
    end
    if not auras then return {} end
    if includeAdHoc then
        auras = WithConfiguredAdHocAuras(auras, spec)
    end
    local specInfo = spec and DF.AuraDesigner.SpecInfo[spec]
    local lockClass = specInfo and specInfo.class
    local R = DF.FilterRegistry
    local tooltipOverrides = DF.AuraDesigner.TooltipSpellIDs
    local specIDs = spec and DF.AuraDesigner.SpellIDs and DF.AuraDesigner.SpellIDs[spec]
    local out = {}
    for _, ai in ipairs(auras) do
        -- Tooltip/canonical id: override table, else the spec whitelist,
        -- else the pool entry's canonical id (same chain as the old cards)
        local id = (tooltipOverrides and tooltipOverrides[ai.name])
            or (specIDs and specIDs[ai.name]) or ai.spellID
        if type(id) == "table" then id = id[1] end -- rare multi-id entries
        local rec = R and R.ByID and id and R.ByID[id]
        out[#out + 1] = {
            id = id or 0,
            class = ai.class or lockClass or "ALL",
            cats = rec and rec.cats or nil,
            display = ai.display or ai.name,
            icon = GetAuraIcon(spec, ai.name),
            -- Letter/colour-swatch fallback for auras whose icon texture
            -- doesn't resolve (the old card fallback)
            iconColor = type(ai.color) == "table" and ai.color or nil,
            auraName = ai.name,
        }
    end
    return out
end

-- Cross-tab block caption for one picker record (B2): a spell tracked by
-- the OPPOSITE pool renders dimmed, captioned with the tab it lives in,
-- and every add path is blocked.
local function ADCrossBlockText(rec)
    if IsCandidateCrossBlocked(rec.auraName, ResolveSpec()) then
        return IsOtherTab() and L["In My Buffs"] or L["In Any Buff"]
    end
    return nil
end

-- ============================================================
-- THE SUB-TAB STRIP, PER POOL
-- ------------------------------------------------------------
-- ★★★ ONE DEFINITION FOR BOTH LAYOUTS (2026-09-09). The split panel builds three buttons in
-- S.mainFrame and the popout page hands its list to GUI:BuildDesignerShell -- two strips, and
-- until now two hardcoded copies of the same three entries.
--
-- ⚠ THE HELPER'S POOL SHOWS TWO, IN THE OTHER ORDER. Krathe, 2026-09-09: "'global' should be
-- Triggers and the first option and Effects should be 2nd with no Layout groups for the PI
-- helper section."
--   · TRIGGERS FIRST, because you cannot sensibly choose how to be told about something you
--     have not yet said you care about.
--   · "Global" IS "Triggers", relabelled -- not a new tab. Every pool's Global tab holds what
--     applies to the whole POOL rather than to one effect, and the helper's roles, classes and
--     cooldown gate are exactly that. Keeping the KEY means SwitchTab, the scroll memory and
--     sixty call sites saying S.SwitchTab("global") need no special case.
--   · NO LAYOUT GROUPS. A layout group is a container of live aura icons; the helper has no
--     per-spell display to arrange, and the one group it used to own is what got stuck on
--     Krathe's frames (see pihSweep step 5). An empty tab that can only be filled with
--     something the feature does not do is a door to the bug that was just closed.
--
-- ⚠ A VERB, NOT A TABLE. Every label is an L[...] lookup -- a table built at load freezes the
-- locale that was live then -- and the list genuinely differs per pool, which is the second
-- reason it cannot be computed once.
local function SubTabDefs()
    if IsPIHelperTab() then
        -- ☠ TWO, AND NEVER A THIRD. The Cooldown Icons group briefly grew one -- a Layout
        -- Groups tab that appeared the moment you added the group -- and Krathe met it twice:
        -- "why is layout groups back showing on PI helper?", then "It's confusing when you add
        -- Cooldown Icons from effects and it appears as a layout group, it should just show as
        -- a normal effect for PI helper."
        -- ⇒ The group is now a card in ACTIVE INDICATORS on the Effects tab, drawn by the
        -- designer's own S.CreateLayoutGroupCard (see S.BuildEffectsTab). It is added there and
        -- it lives there; a tab that grows and shrinks under the user is gone with it.
        return {
            { key = "global",  label = L["Triggers"], accent = { r = 0.51, g = 0.86, b = 0.51 } },
            { key = "effects", label = L["Effects"],  accent = nil },
        }
    end
    return {
        { key = "effects", label = L["Effects"],       accent = nil },   -- theme-tracking
        { key = "layout",  label = L["Layout Groups"], accent = { r = 0.91, g = 0.66, b = 0.25 } },
        { key = "global",  label = L["Global"],        accent = { r = 0.51, g = 0.86, b = 0.51 } },
    }
end
P.SubTabDefs = SubTabDefs

-- Which sub-tab a pool can legally be showing. Called wherever the pool changes under a tab
-- that was chosen for the previous one -- the same shape as the Debuffs coercion below, and
-- for the same reason: a strip that no longer draws a button must not leave it selected.
-- ⚠ Answers for EVERY pool, so a caller never has to know which one it is on.
local function CoerceTabForPool(tabKey)
    if IsPIHelperTab() then
        -- ⚠ "layout" LANDS ON EFFECTS, not on Triggers. The helper has no Layout Groups tab,
        -- and the one thing that would have sent someone here asking for it -- the Cooldown
        -- Icons group -- is a card in the Effects list now, so Effects is where they meant to
        -- go. (Krathe hit the old landing twice; see SubTabDefs.)
        if tabKey == "effects" or tabKey == "layout" then return "effects" end
        return "global"
    end
    if tabKey == "effects" and IsDebuffTab() then return "layout" end
    return tabKey
end
P.CoerceTabForPool = CoerceTabForPool

-- ── SWITCH TAB ──
S.SwitchTab = function(tabKey)
    -- Every pool's coercion in one call: Effects is frosted on Debuffs (category groups have
    -- no placed indicators) and Layout Groups is not drawn at all on the helper's pool. Both
    -- are belt-and-braces here -- the strip does not offer the button either way -- but a
    -- SwitchTab reached from a stale call site must land somewhere that exists.
    tabKey = CoerceTabForPool(tabKey)

    -- ☠ IN THE POPOUT LAYOUT THERE IS NO TAB PANEL TO REBUILD. The row page
    -- (AuraDesigner/UI/Rows.lua) has no S.tabBar, no S.tabScrollFrame and no
    -- S.tabContentFrame -- its tabs are bands in the page's own column, so the
    -- rebuild verb is the page harness's. Branching HERE rather than at the
    -- ~60 call sites: every one of them means "the data moved, redraw the tab",
    -- and that sentence is true in both layouts -- only the machinery differs.
    if S.rowsMode then
        S.activeTab = tabKey
        S.adPickerDirty = false
        CloseADPicker()
        if GUI then GUI:CloseAllMenus() end
        if S.page and S.page.Refresh then S.page:Refresh() end
        return
    end

    -- Preserve scroll position when refreshing the same tab
    local prevTab = S.activeTab
    local savedScroll = 0
    if tabKey == prevTab and S.tabScrollFrame then
        savedScroll = S.tabScrollFrame:GetVerticalScroll()
    end

    S.activeTab = tabKey
    -- This switch rebuilds the tab anyway — skip the close hook's own
    -- dirty rebuild so the tab isn't built twice.
    S.adPickerDirty = false
    CloseADPicker()
    if GUI then GUI:CloseAllMenus() end   -- an open dropdown (e.g. spec) must not outlive the tab

    for key, btn in pairs(tabButtons) do
        btn:SetActive(key == tabKey)  -- underline + accent/dim label (tab mode)
    end

    ClearTabContent()

    if tabKey == "effects" then
        S.BuildEffectsTab()
    elseif tabKey == "layout" then
        -- The Debuffs tab's Layout Groups list shows ONLY debuff category
        -- groups; My Buffs / Other Buffs each build their OWN pool's
        -- member+filter groups (S.BuildLayoutGroupsTab is pool-routed).
        if IsDebuffTab() then
            S.BuildDebuffGroupsTab()
        else
            S.BuildLayoutGroupsTab()
        end
    elseif tabKey == "global" then
        S.BuildGlobalTab()
    end

    if S.tabScrollFrame then
        if tabKey == prevTab then
            -- Clamp to new max scroll range (content may have changed height)
            local maxScroll = S.tabScrollFrame:GetVerticalScrollRange()
            S.tabScrollFrame:SetVerticalScroll(min(savedScroll, maxScroll))
        else
            S.tabScrollFrame:SetVerticalScroll(0)
        end
    end
end

-- ── MAIN POOL TAB SWITCH (B2/C2: My Buffs / Debuffs / Other Buffs) ──

-- Grey/restore the sub-tabs: frosted (SetDisabled — stays mouse-enabled so
-- the tooltip can explain why; OnClick early-outs on dfDisabled). Effects
-- frosts on the Debuffs tab (category groups have no placed indicators).
-- Layout Groups is live on BOTH buff tabs (the Other tab hosts the flat
-- other-pool group store) — it never frosts anymore.
-- ★★ ...AND RE-LAY THE STRIP, because on the helper's pool it is a DIFFERENT STRIP: two
-- buttons, in the other order, one of them relabelled (see SubTabDefs).
-- ☠ RE-ANCHORED RATHER THAN REBUILT, and the split panel is why. Its three buttons are
-- created once inside S.mainFrame and the pool switch does NOT rebuild that frame -- it calls
-- AuraDesigner_RefreshPage, which redraws the tab CONTENT and leaves the strip alone. So the
-- buttons that exist are the buttons there will be, and the pool decides which of them are
-- shown, in what order, under what label. (The popout layout rebuilds its whole page on a
-- pool switch, so it simply reads SubTabDefs afresh and never comes here.)
-- ⚠ THE GAP MATCHES Editor.lua's TAB_GAP. Two copies of a 4, which is one too many -- but the
-- alternative is exporting a layout constant from a builder into a state module, and the
-- number is checked by eye every time this runs against a strip built with the other one.
local SUBTAB_GAP = 4
local function ApplySubTabStrip()
    if not (tabButtons and S.tabBar) then return end
    local defs = SubTabDefs()
    local wanted, prev = {}, nil
    for _, def in ipairs(defs) do
        local btn = tabButtons[def.key]
        if btn then
            wanted[def.key] = true
            btn:ClearAllPoints()
            if prev then
                btn:SetPoint("TOPLEFT", prev, "TOPRIGHT", SUBTAB_GAP, 0)
            else
                btn:SetPoint("TOPLEFT", S.tabBar, "TOPLEFT", 0, 0)
            end
            -- ⚠ THE LABEL IS SET EVERY PASS, not only when it changes. "Global" and
            -- "Triggers" are the same button, and a button that kept the label it was built
            -- with would read Global on the helper and Triggers everywhere else depending on
            -- which pool happened to be open when the panel was created.
            if btn.Text then btn.Text:SetText(def.label) end
            btn:Show()
            prev = btn
        end
    end
    -- ☠ AND THE ONES THIS POOL DOES NOT HAVE ARE UNANCHORED, NOT JUST HIDDEN. A hidden frame
    -- still anchors whatever is pointed at it, and the chain above re-points buttons at each
    -- other every pass -- leaving a stale link would drag a visible tab off to where a hidden
    -- one used to be.
    for key, btn in pairs(tabButtons) do
        if not wanted[key] then
            btn:ClearAllPoints()
            btn:Hide()
        end
    end
    local w = S.tabBar:GetWidth() or 0
    local n = #defs
    if w > 10 and n > 0 then
        local tabW = (w - (n - 1) * SUBTAB_GAP) / n
        for _, def in ipairs(defs) do
            if tabButtons[def.key] then tabButtons[def.key]:SetWidth(tabW) end
        end
    end
end
P.ApplySubTabStrip = ApplySubTabStrip

-- Which POOL tab reads as selected. Lifted out of SetMainTab because the REUSE path needs it
-- too: a page revisit that changes the pool without rebuilding the panel (the Power Infusion
-- Helper's nav row does exactly that) left the strip lit on the pool the panel was BUILT for.
-- Krathe, 2026-09-09: "it takes you to the enable PI page but ... is not highlighting Power
-- Infusion Helper tab up top."
local function SyncPoolTabs()
    for key, btn in pairs(mainTabButtons) do
        if btn.SetActive then btn:SetActive(key == S.activeBuffTab) end
    end
end
P.SyncPoolTabs = SyncPoolTabs

local function UpdateLayoutTabState()
    ApplySubTabStrip()
    local layoutBtn = tabButtons and tabButtons.layout
    if layoutBtn and layoutBtn.SetDisabled then
        layoutBtn:SetDisabled(false)
    end
    local effectsBtn = tabButtons and tabButtons.effects
    if effectsBtn and effectsBtn.SetDisabled then
        effectsBtn:SetDisabled(IsDebuffTab())
    end
end
P.UpdateLayoutTabState = UpdateLayoutTabState

-- Grey the spec dropdown + swap its opener text on the Other and Debuffs
-- tabs (both pools are shared across specs); restore the live spec text on
-- My Buffs.
local function UpdateSpecDropdownState()
    if not S.specDropdown then return end
    if IsOtherTab() or IsDebuffTab() then
        if S.specDropdown.SetDisplayOverride then
            S.specDropdown:SetDisplayOverride(L["— (shared across specs)"])
        end
        S.specDropdown:SetEnabled(false)
    else
        S.specDropdown:SetEnabled(true)
        if S.specDropdown.SetDisplayOverride then
            S.specDropdown:SetDisplayOverride(nil)
        end
        if S.specDropdownUpdate then S.specDropdownUpdate() end
    end
end
P.UpdateSpecDropdownState = UpdateSpecDropdownState

local function SetMainTab(tabKey)
    if S.activeBuffTab == tabKey then return end
    S.activeBuffTab = tabKey
    -- Editor keys are pool-prefixed (B1) so cards can't collide across tabs,
    -- but mirror the spec dropdown's behavior: a pool switch collapses all
    -- expanded cards (wipe, not per-tab preservation).
    wipe(expandedCards)
    -- The shared picker captures its pool/effect at open time — never let
    -- it survive a pool switch.
    CloseADPicker()
    if GUI then GUI:CloseAllMenus() end   -- an open dropdown (e.g. spec) must not outlive the tab
    SyncPoolTabs()
    UpdateSpecDropdownState()
    UpdateLayoutTabState()
    -- ☠ THE TAB YOU WERE ON MAY NOT EXIST ON THE POOL YOU JUST PICKED. Effects is frosted on
    -- Debuffs, and Layout Groups is not drawn at all on the helper's pool -- arriving there
    -- from Layout Groups used to leave the strip with nothing selected and the content pane
    -- built for a tab that had no button. CoerceTabForPool answers for every pool at once.
    S.activeTab = CoerceTabForPool(S.activeTab)
    -- One entry point swaps every surface: RefreshPage → S.SwitchTab(S.activeTab)
    -- (list, chips, add menu) + RefreshPlacedIndicators/RefreshPreviewEffects
    -- (preview, drag targets) — all pool-routed through CurrentAuraPool.
    DF:AuraDesigner_RefreshPage()
end
P.SetMainTab = SetMainTab

-- ── ADD FROM PICKER (shared path) ──
-- What accepting a spell in the picker DOES: create the placed indicator
-- instance (or the frame-level type config, mode = "frame") and pre-expand
-- its effect card. Used by both the row handler and add-by-ID so the two
-- entry points can never drift apart.
-- ⚠ `anchor` IS OPTIONAL AND ADDITIVE. The add panel asks WHERE before it
-- commits (its section 3), so the one caller that has an answer passes it; every
-- other caller omits it and the instance keeps the type's own default, exactly as
-- before. It writes the field CreateIndicatorInstance already seeds -- no new
-- shape, nothing to migrate.
local function AddPickedSpell(auraName, typeKey, mode, anchor)
    -- Card keys embed the B1 pool prefix in the name segment
    -- ("placed:other:<name>#<id>" / "frame:<type>:other:<name>").
    if mode == "placed" then
        local instance = CreateIndicatorInstance(auraName, typeKey)
        if instance then
            if anchor and ANCHOR_POSITIONS[anchor] then instance.anchor = anchor end
            expandedCards["placed:" .. PoolKeyPrefix() .. auraName .. "#" .. instance.id] = true
        end
    else
        EnsureTypeConfig(auraName, typeKey)
        expandedCards["frame:" .. typeKey .. ":" .. PoolKeyPrefix() .. auraName] = true
    end
    -- Structural change: drive the LIVE frames, not just the editor. The callers only run
    -- RefreshPlacedIndicators / RefreshPreviewEffects (editor chips + preview canvas), so
    -- without this a freshly added indicator never builds its live container until some other
    -- action (move / eye toggle / reload) fires ForceRefreshAllFrames. Mirrors AddSpellToGroup.
    DF:InvalidateAuraLayout()
    DF:UpdateAllFrames()
    if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
    end
end

-- ── ADD TO LAYOUT GROUP ("group" picker context) ──
-- One click on a row's Icon/Square button (or the ID row's, for add-by-ID):
-- create a NEW placed indicator of that type and enrol it in the target group.
-- The picker stays open for multi-add, and the same spell can be added again —
-- every add mints a fresh indicator id, so AddGroupMember's (auraName,
-- indicatorID) dedup never blocks it. skipEcho lets add-by-ID substitute its
-- own unknown-ID echo. Refresh chain mirrors the group card's member ✕.
local function AddSpellToGroup(groupID, auraName, display, typeKey, skipEcho, picker)
    if not groupID then return end
    local instance = CreateIndicatorInstance(auraName, typeKey)
    if not instance then return end
    AddGroupMember(groupID, auraName, instance.id)
    S.adPickerDirty = true  -- layout tab behind the picker is stale; rebuilt on close
    if not skipEcho and picker then
        local typeLabel = S.PLACED_TYPE_LABELS[typeKey] or typeKey
        picker:Echo(format(L["Added %s."],
            format("%s (%s)", display or auraName, typeLabel)))
    end
    RefreshPlacedIndicators()
    -- Structural change: same full refresh as the member ✕
    -- (new indicator container + group positions + buff-row dedup).
    DF:InvalidateAuraLayout()
    DF:UpdateAllFrames()
    if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
    end
end

-- The trackable-pool entry for a name, or nil when the name is not in this
-- spec's pool at all. Doubles as the pool-MEMBERSHIP test below: a config key
-- outside the pool is a key no editor surface can name.
local function TrackableInfo(spec, auraName)
    local list = spec and Adapter and Adapter:GetTrackableAuras(spec)
    if not list then return nil end
    for _, info in ipairs(list) do
        if info.name == auraName then return info end
    end
    return nil
end

-- The curated aura that owns a SpellDB record, by any ID the record carries.
-- GetTrackableAuras dedups a record OUT of the pool when its ids overlap a
-- curated entry's, so "record exists but its name isn't in the pool" always
-- means some curated entry already speaks for it — this finds which.
local function CuratedOwnerForRecord(spec, rec)
    if not (spec and rec and Adapter and Adapter.GetAuraNameForSpellID) then return nil end
    local owner = Adapter:GetAuraNameForSpellID(spec, rec.id)
    if owner then return owner end
    if rec.alts then
        for _, altID in ipairs(rec.alts) do
            owner = Adapter:GetAuraNameForSpellID(spec, altID)
            if owner then return owner end
        end
    end
    return nil
end

-- ── ADD BY ID (shared picker ID row) ──
-- Snap known ids to their pool/curated record (then behave exactly like
-- clicking that spell's row — same AddPickedSpell / AddSpellToGroup paths);
-- unknown ids become an ad-hoc "#<id>" aura whose key IS its identity
-- (S.CleanupAdHocAura drops the config again once its last effect is
-- removed). The picker stays open (echo confirms), so several ids can be
-- added in a row. The shared picker has already validated the digits and
-- normalized leading zeros; idText is that validated digit STRING. Returns
-- truthy when the add landed (the picker clears its ID box on that).
-- ☠ THE NAMING AND BLOCKING HALF, ON ITS OWN. Everything below the split is
-- about a TYPE and a MODE -- which indicator to make, in which pool -- and the
-- spell-first add flow (S.BuildAddIndicatorPane) has neither when the user types
-- an ID: it is still asking WHICH SPELL. So the half that answers "what is
-- #12345 called here, and may I use it in this pool at all" became a verb of its
-- own, and ADAddByID is what was left.
--
-- Returns auraName, display, isAdHoc, blockedMessage. A blocked message means the
-- caller must stop and echo it; nothing else in the tuple is usable.
local function ADResolveByID(idNum, idText)
    local isOther = IsOtherTab()
    local spec = ResolveSpec()
    -- The Other Buffs pool is spec-independent — no spec required there.
    if not spec and not isOther then return nil end

    -- Snap. My Buffs: the spec's curated identity index first, then the SpellDB
    -- (R.ByID indexes canonical + alt ids), else ad-hoc. Other Buffs: SpellDB
    -- ONLY — the B1 naming contract (other-pool keys are SpellDB rec.n or ad-hoc
    -- "#<id>"; curated internal names don't resolve with a nil spec).
    local auraName
    if not isOther and Adapter and Adapter.GetAuraNameForSpellID then
        -- The SHARED identity index — primaries, curated alternates and the
        -- alternates inherited from the SpellDB, i.e. exactly the ID set
        -- DF:BuildADIdentityFilters will make the placement track. Typing any ID
        -- an indicator responds to therefore lands on that indicator's spell,
        -- which matters because our own AD tooltip hands the user the BUFF id
        -- (Config's TooltipSpellIDs), not the curated primary.
        auraName = Adapter:GetAuraNameForSpellID(spec, idNum)
    end
    if not auraName then
        local R = DF.FilterRegistry
        local rec = R and R.ByID and R.ByID[idNum]
        if rec then
            auraName = rec.n
            -- ☠ MY BUFFS ONLY STORES POOL NAMES. `rec.n` is a SpellDB name
            -- ("Ebon Might"); curated keys are internal ("EbonMight"). When a
            -- curated entry has deduped this record out of the spec pool, storing
            -- rec.n mints a config key nothing can name — and CollectAllEffects
            -- DROPS records it cannot name, so the indicator renders on the frame
            -- while being invisible in the editor and impossible to delete. That
            -- was the reported bug. Snap to the curated owner instead; if there
            -- somehow isn't one, degrade to an ad-hoc "#<id>" key, which is always
            -- nameable (resolved live) and always deletable.
            if not isOther and not TrackableInfo(spec, auraName) then
                auraName = CuratedOwnerForRecord(spec, rec)
            end
        end
    end

    local isAdHoc = not auraName
    -- Key from the validated TEXT, not tonumber output — number formatting
    -- must never leak into config keys (AdHocSpellID parses "^#(%d+)$").
    if isAdHoc then auraName = "#" .. idText end

    -- Cross-tab block (B2): the spell — snapped name's FULL identity set,
    -- or the raw id for ad-hoc — is already tracked by the OPPOSITE pool.
    -- Checked before the group branch so group adds are blocked too.
    local crossBlocked = false
    if S.spellPickerBlockedIDs and next(S.spellPickerBlockedIDs) then
        if S.spellPickerBlockedIDs[idNum] then
            crossBlocked = true
        elseif not isAdHoc then
            crossBlocked = IsCandidateCrossBlocked(auraName, spec)
        end
    end
    if crossBlocked then
        return nil, nil, nil,
            (isOther and L["Already tracked in My Buffs."] or L["Already tracked in Any Buff."])
    end

    -- Display name: the trackable pool entry when it has one (curated
    -- display or localized SpellDB name), else the raw key.
    local display = auraName
    if not isAdHoc then
        if isOther then
            display = OtherPoolDisplayName(auraName)
        else
            local info = TrackableInfo(spec, auraName)
            if info then display = info.display or auraName end
        end
    end
    return auraName, display, isAdHoc, nil
end
P.ADResolveByID = ADResolveByID

local function ADAddByID(idNum, idText, picker, mode, typeKey, groupID)
    local auraName, display, isAdHoc, blocked = ADResolveByID(idNum, idText)
    if blocked then
        picker:Echo(blocked)
        return
    end
    if not auraName then return end

    -- Group context: no already-used gate (a spell can hold several
    -- indicators in one group). AddSpellToGroup echoes and refreshes.
    if mode == "group" then
        AddSpellToGroup(groupID, auraName, display, typeKey or "icon", isAdHoc, picker)
        if isAdHoc then
            picker:Echo(format(L["Added #%d as an unknown spell ID — name and icon will show if the ID is valid."], idNum))
            picker:RefreshRecords()  -- the new ad-hoc aura gets a row of its own
        end
        return true
    end

    local alreadyUsed
    if mode == "placed" then
        alreadyUsed = IsAuraTypePlaced(auraName, typeKey)
    else
        alreadyUsed = HasFrameEffect(auraName, typeKey)
    end
    if alreadyUsed then
        picker:Echo(L["Already added."])
        return
    end

    AddPickedSpell(auraName, typeKey, mode)
    S.adPickerDirty = true
    if isAdHoc then
        picker:Echo(format(L["Added #%d as an unknown spell ID — name and icon will show if the ID is valid."], idNum))
    else
        picker:Echo(format(L["Added %s."], display))
    end
    picker:Refresh()             -- the row flips to its blocked state
    RefreshPlacedIndicators()    -- live preview updates behind the picker
    RefreshPreviewEffects()
    return true
end

-- ── OPEN: ADD INDICATOR (placed + frame contexts) ──
-- typeKey: "icon"|"square"|"bar" (placed) or "border"|"healthbar"|etc.
-- (frame); mode: "placed" or "frame". Single-pick — choosing a spell
-- creates the indicator (or frame-level type config), closes the picker
-- and lands on its expanded effect card. My Buffs locks the picker to the
-- resolved spec's class (class dropdown hidden, records limited to the
-- class + "ALL"); Other Buffs offers the full database with both filters.
local function OpenIndicatorPicker(typeKey, mode)
    local isOther = IsOtherTab()
    local spec = (not isOther) and ResolveSpec() or nil
    local specInfo = spec and DF.AuraDesigner.SpecInfo[spec]
    local badgeColor = BADGE_COLORS[typeKey] or BADGE_COLORS.icon
    local title
    if mode == "frame" then
        title = format(L["Select trigger for %s"], S.FRAME_LEVEL_LABELS[typeKey] or typeKey)
    else
        title = L["Select a spell"]
    end
    OpenADPicker({
        title = title,
        subtitle = S.PLACED_TYPE_LABELS[typeKey] or S.FRAME_LEVEL_LABELS[typeKey] or typeKey,
        subtitleColor = badgeColor,
        records = function() return BuildADPickerRecords(false) end,
        classLock = (not isOther) and specInfo and specInfo.class or nil,
        isBlocked = function(rec)
            local cross = ADCrossBlockText(rec)
            if cross then return cross end
            if mode == "placed" then
                if IsAuraTypePlaced(rec.auraName, typeKey) then return L["Placed"] end
            elseif HasFrameEffect(rec.auraName, typeKey) then
                return L["Active"]
            end
            return nil
        end,
        rowActions = {
            {
                label = L["Add"], -- labels the ID-row button; rows are click-to-add
                handler = function(rec, _, picker)
                    AddPickedSpell(rec.auraName, typeKey, mode)
                    picker:Close()
                    S.SwitchTab("effects")
                    RefreshPlacedIndicators()
                    RefreshPreviewEffects()
                end,
            },
        },
        allowAddByID = true,
        onAddByID = function(idNum, _, picker, idText)
            return ADAddByID(idNum, idText, picker, mode, typeKey, nil)
        end,
    })
end

-- ── OPEN: ADD TO LAYOUT GROUP ──
-- Every row carries Icon / Square buttons that create the indicator and
-- enrol it in the target group in one click (the picker stays open for
-- adding several in a row); the ID row gets the same two buttons, Enter
-- defaulting to Icon. Records include the pool's configured ad-hoc
-- "#<id>" auras — the old picker offered them too.
local function OpenGroupSpellPicker(groupID)
    local isOther = IsOtherTab()
    local spec = (not isOther) and ResolveSpec() or nil
    local specInfo = spec and DF.AuraDesigner.SpecInfo[spec]
    local grp = groupID and GetLayoutGroupByID(groupID)
    OpenADPicker({
        title = L["Select a spell"],
        subtitle = grp and grp.name or "",
        subtitleColor = GetThemeColor(),
        records = function() return BuildADPickerRecords(true) end,
        classLock = (not isOther) and specInfo and specInfo.class or nil,
        -- Duplicates are allowed (each add is its own indicator instance),
        -- so only the cross-tab block dims a row.
        isBlocked = ADCrossBlockText,
        rowActions = {
            {
                label = S.PLACED_TYPE_LABELS.icon or "Icon",
                color = BADGE_COLORS.icon,
                typeKey = "icon",
                handler = function(rec, _, picker)
                    AddSpellToGroup(groupID, rec.auraName, rec.display, "icon", false, picker)
                end,
            },
            {
                label = S.PLACED_TYPE_LABELS.square or "Square",
                color = BADGE_COLORS.square,
                typeKey = "square",
                handler = function(rec, _, picker)
                    AddSpellToGroup(groupID, rec.auraName, rec.display, "square", false, picker)
                end,
            },
        },
        allowAddByID = true,
        onAddByID = function(idNum, action, picker, idText)
            return ADAddByID(idNum, idText, picker, "group", (action and action.typeKey) or "icon", groupID)
        end,
    })
end
P.OpenGroupSpellPicker = OpenGroupSpellPicker

-- ── CREATE EFFECT CARD ──
-- Creates a collapsible card for one effect in the effects list.
-- Returns the new yPos after the card.
-- ============================================================
-- A FRAME-LEVEL EFFECT'S OWN TWO BLOCKS
-- ------------------------------------------------------------
-- Triggered By, and Priority with the border effect's Own Border opt-out beside
-- it. Extracted from S.CreateEffectCard so the popout layout's row page can
-- mount the SAME two inside popout panes: the card stacks them at running y
-- offsets down one body, a pane hosts one each at the top of its own.
--
-- ☠ EXTRACTED, NOT COPIED. These are the only two blocks on an effect that are
-- not sections of BuildTypeContent, so they are the only two the collect seam
-- there cannot reach -- and 500 lines of trigger tags said twice is 500 lines
-- that would drift.
--
-- `baseH` is where the block starts inside its host -- the card's running total,
-- or 0 in a pane. Each returns the height it took, which is what the card
-- advances by; the pane uses it to size its one widget.
-- ============================================================

S.BuildEffectTriggersBlock = function(body, effect, bodyWidth, baseH)
    baseH = baseH or 0
    local triggersH = 0
        -- Normalised view: one group for a plain effect, N for a conditional one.
        local condGroups = GetEffectConditionGroups(effect.auraName, effect.typeKey)
        local condMode   = GetEffectConditionMode(effect.auraName, effect.typeKey)
        local multiCond  = #condGroups > 1
        -- ☠ WITHIN a group the operator is the OPPOSITE of the one BETWEEN groups, and
        -- that is not arbitrary: ALL means every group must match, so a group is a bag
        -- of alternatives (OR); ANY means one group must match, so its members have to
        -- hold together (AND). An ungrouped effect is a single OR group -- the legacy
        -- behaviour, unchanged. Drawn between the tags because pressing the mode button
        -- otherwise reverses what every existing trigger means with no visual change.
        local innerOp = (multiCond and condMode == "ANY") and L["AND"] or L["OR"]
        local trigContainer = CreateFrame("Frame", nil, body)
        trigContainer:SetPoint("TOPLEFT", 8, -(baseH + 12))
        trigContainer:SetPoint("RIGHT", body, "RIGHT", -8, 0)

        local trigLabel = trigContainer:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(trigLabel, 9, "")
        trigLabel:SetPoint("TOPLEFT", 0, 0)
        trigLabel:SetText(L["TRIGGERED BY"])
        trigLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

        -- AND/OR operator toggle (only shown with 2+ triggers)
        -- (No multi-trigger ALL/ANY operator button: evaluating every trigger together
        --  needs a read the 12.1 aura system cannot do for secret-anchored triggers, so
        --  it was permanently frosted. Removed 2026-07-25 -- triggerOperator was never
        --  read by the render path either, only by this editor's own label, so the
        --  toggle changed nothing. Triggers combine as ANY/OR. The tags stay editable.)

        -- Build display name lookup for tags. Other-pool trigger names are
        -- SpellDB names / ad-hoc keys — resolved live per tag below.
        local isOtherCard = IsOtherTab()
        local spec = (not isOtherCard) and ResolveSpec() or nil
        local trackable = spec and Adapter and Adapter:GetTrackableAuras(spec)
        local displayNames = {}
        if trackable then
            for _, info in ipairs(trackable) do
                displayNames[info.name] = info.display
            end
        end
        if isOtherCard then
            setmetatable(displayNames, { __index = function(_, name)
                return OtherPoolDisplayName(name)
            end })
        end

        -- ☠ EVERY trigger edit below must drive the LIVE frames, not just the editor.
        -- A trigger change moves the effect's resolved spell map, which rides the
        -- TUNING signature — so it only lands when SyncFrame next runs and compares
        -- sigs. S.SwitchTab rebuilds this tab and RefreshPreviewEffects repaints the
        -- mock frame; neither touches a real unit frame. Without the throttled live
        -- refresh the edit sat in the DB doing nothing until some unrelated action
        -- (or a reload) happened to fire ForceRefreshAllFrames — reported from the
        -- field as "removed a trigger and the border kept showing until I reloaded".
        -- Same class of bug AddPickedSpell's own comment already warns about.

        -- Tag flow layout
        local TAG_H = 20
        local TAG_GAP = 4
        local TAG_ROW_GAP = 3
        local tagX, tagY = 0, -(14 + 6)  -- below label

        for gi = 1, #condGroups do
        local triggers = condGroups[gi].triggers or {}
        -- A grouped effect may empty a group out (the card warns); an ungrouped one
        -- keeps the legacy minimum of one trigger.
        local canRemove = multiCond or #triggers > 1

        -- Operator caption BETWEEN groups, so the card reads downward as
        -- "these ... AND ... these". Only present once the effect is conditional.
        if multiCond and gi > 1 then
            tagY = tagY - 6
            -- A RULE across the card, not a floating word: the previous layout put the
            -- operator and a bare X into the same wrapping flow as the tags, so nothing
            -- said where one group ended and the next began, or which X removed what.
            local sep = trigContainer:CreateFontString(nil, "OVERLAY")
            GUI:SetSettingsFont(sep, 9, "OUTLINE")
            sep:SetPoint("TOPLEFT", trigContainer, "TOPLEFT", 0, tagY)
            sep:SetText(condMode == "ALL" and L["AND"] or L["OR"])
            sep:SetTextColor(C_NOTICE.r, C_NOTICE.g, C_NOTICE.b)

            -- Removal belongs to the group BELOW the rule, and sits at the far right so
            -- it can never be mistaken for a tag's own X.
            local delG = DF.GUI:CreateCloseButton(trigContainer, {
                size = 14, tone = "danger",
                onClick = function()
                    RemoveEffectConditionGroup(effect.auraName, effect.typeKey, gi)
                    S.SwitchTab("effects")
                    RefreshPreviewEffects()
                    RefreshLiveFramesThrottled()
                end,
            })
            delG:SetPoint("TOPRIGHT", trigContainer, "TOPRIGHT", 0, tagY - 1)
            delG.tooltip = L["Remove this condition group."]

            -- ☠ The rule spans the GAP between the caption and the remove button, rather
            -- than running the full width behind them. Masking the line under the text
            -- needed the card's exact background colour and still clipped at whatever
            -- width the translated word happened to be; anchoring between the two makes
            -- overlap impossible in any language and at any font size.
            local rule = trigContainer:CreateTexture(nil, "ARTWORK")
            rule:SetPoint("LEFT", sep, "RIGHT", 8, 0)
            rule:SetPoint("RIGHT", delG, "LEFT", -8, 0)
            rule:SetHeight(1)
            rule:SetColorTexture(C_NOTICE.r, C_NOTICE.g, C_NOTICE.b, 0.22)
            tagY = tagY - 22
            tagX = 0
        end

        for ti, trigName in ipairs(triggers) do
            local tagFrame = CreateFrame("Frame", nil, trigContainer, "BackdropTemplate")
            tagFrame:SetHeight(TAG_H)

            local tagText = tagFrame:CreateFontString(nil, "OVERLAY")
            GUI:SetSettingsFont(tagText, 9, "")
            tagText:SetPoint("LEFT", 6, 0)
            -- Filter triggers name themselves from the registry; a raw
            -- "@preset:raidBuffs" on the tag would be meaningless.
            tagText:SetText((DF.ADFilterRefDisplayName and DF:ADFilterRefDisplayName(trigName))
                or displayNames[trigName] or trigName)
            tagText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

            -- A tag naming a FILTER gets a route to that filter. A tag naming a
            -- spell does not -- there is nothing to open -- so this is per-tag,
            -- not per-row: in "Healing OR Tank Cooldowns" only the second one
            -- earns a pencil.
            --
            -- ⚠ Guarded, like every other call to it from this addon: the parser
            -- is resident and this file is the options companion, so the symbol
            -- is not guaranteed present at load. The neighbouring
            -- DF.ADFilterRefDisplayName guard above does NOT cover this -- a
            -- guard on one function tells you nothing about another.
            local trigFKind, trigFKey
            if DF.ParseADFilterRef then
                trigFKind, trigFKey = DF:ParseADFilterRef(trigName)
            end

            local tagW = tagText:GetStringWidth() + 12
            if canRemove then tagW = tagW + 16 end  -- room for × button
            if trigFKind then tagW = tagW + 16 end  -- room for the edit pencil
            tagW = max(tagW, 40)

            -- Wrap to next row if needed
            local containerW = trigContainer:GetWidth()
            if containerW < 50 then containerW = bodyWidth - 16 end
            if tagX > 0 and (tagX + tagW) > containerW then
                tagX = 0
                tagY = tagY - (TAG_H + TAG_ROW_GAP)
            end

            tagFrame:SetPoint("TOPLEFT", trigContainer, "TOPLEFT", tagX, tagY)
            tagFrame:SetWidth(tagW)
            ApplyBackdrop(tagFrame,
                {r = 0.14, g = 0.14, b = 0.17, a = 1},
                {r = 0.30, g = 0.30, b = 0.35, a = 0.8})

            -- Remove × button on each tag (unless it's the last one)
            -- ☠ DECLARED OUTSIDE the branch: the edit pencil below anchors to it,
            -- and a `local` inside the `if` is invisible out here. Read from there
            -- it was a nil GLOBAL, and SetPoint treats a nil relativeTo as the
            -- PARENT -- so the pencil anchored to the tag's own left edge and drew
            -- off the frame instead of erroring. Visible with one trigger (where
            -- canRemove is false and the else branch runs) and silently gone with
            -- two, which is exactly how it was reported.
            local removeBtn
            if canRemove then
                local capturedTrigName = trigName
                -- Shared red-at-rest "×" (tone="danger") on each removable tag.
                removeBtn = DF.GUI:CreateCloseButton(tagFrame, {
                    size = 14,
                    tone = "danger",
                    onClick = function()
                        RemoveEffectTriggerFromGroup(effect.auraName, effect.typeKey, gi, capturedTrigName)
                        S.SwitchTab("effects")
                        RefreshPreviewEffects()
                        RefreshLiveFramesThrottled()   -- see the trigger-edit note above
                    end,
                })
                removeBtn:SetPoint("RIGHT", -2, 0)
            end

            -- The pencil sits INSIDE the ×, i.e. further left, so the destructive
            -- control keeps the corner it has always had. Moving × to make room
            -- would retrain the muscle memory of every existing tag on the page.
            if trigFKind then
                local editBtn = CreateFrame("Button", nil, tagFrame)
                editBtn:SetSize(14, 14)
                if canRemove then
                    editBtn:SetPoint("RIGHT", removeBtn, "LEFT", -1, 0)
                else
                    editBtn:SetPoint("RIGHT", -2, 0)
                end
                local ei = editBtn:CreateTexture(nil, "OVERLAY")
                ei:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\edit")
                ei:SetSize(11, 11)
                ei:SetPoint("CENTER")
                ei:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                editBtn:SetScript("OnEnter", function(self)
                    ei:SetVertexColor(1, 1, 1)
                    GUI:ShowTooltip(self, {
                        title = L["Edit this filter"],
                        lines = { L["Opens it in the Filter Designer, where you can change which auras it holds."] },
                    })
                end)
                editBtn:SetScript("OnLeave", function()
                    ei:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                    GUI:HideTooltip()
                end)
                local ek, eq = trigFKind, trigFKey
                editBtn:SetScript("OnClick", function()
                    if GUI.OpenFilterInDesigner then GUI:OpenFilterInDesigner(ek, eq) end
                end)
            end

            tagX = tagX + tagW + TAG_GAP

            if ti < #triggers then
                local OP_W = 24
                if tagX > 0 and (tagX + OP_W) > containerW then
                    tagX = 0
                    tagY = tagY - (TAG_H + TAG_ROW_GAP)
                end
                local opTxt = trigContainer:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(opTxt, 8, "")
                opTxt:SetPoint("TOPLEFT", trigContainer, "TOPLEFT", tagX + 2, tagY - 5)
                opTxt:SetText(innerOp)
                opTxt:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                tagX = tagX + OP_W
            end
        end

        -- "+ Add Trigger" button
        -- ☠ ALWAYS a fresh row. Sharing the tag flow made the add buttons wrap into the
        -- middle of a spell list, so which group they belonged to was pure guesswork.
        local addTrigW = 80
        tagX = 0
        tagY = tagY - (TAG_H + TAG_ROW_GAP)
        local addTrigBtn = CreateFrame("Button", nil, trigContainer, "BackdropTemplate")
        addTrigBtn:SetPoint("TOPLEFT", trigContainer, "TOPLEFT", tagX, tagY)
        GUI:StyleButton(addTrigBtn, { width = addTrigW, height = TAG_H, primary = true, accent = { r = 0.25, g = 0.40, b = 0.25 }, icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\add", size = 11 }, text = L["Add Trigger"] })
        GUI:SetSettingsFont(addTrigBtn.Text, 9, "")
        addTrigBtn.Text:SetTextColor(0.5, 0.8, 0.5)
        addTrigBtn.Icon:SetVertexColor(0.5, 0.8, 0.5)

        -- Trigger picker: the shared spell database picker, single-pick.
        -- My Buffs locks it to the resolved spec's class; Other Buffs
        -- offers the full database (the old plain dropdown restricted
        -- Other-tab triggers to already-configured auras only because
        -- the full DB was unusable without search/filters — the shared
        -- picker has both, so the restriction is lifted). Records also
        -- include the pool's configured ad-hoc "#<id>" auras. Rows
        -- already in the effect's trigger list render with the dimmed
        -- check ("already added").
        addTrigBtn:SetScript("OnClick", function()
            -- Pin the pool at OPEN time (pool pinning carried over from
            -- the old floating dropdown): a pick must keep writing the
            -- trigger into the pool this card's record lives in, no
            -- matter how the surrounding UI state moves while the
            -- picker is up (the record exists, so the read accessor
            -- returns the real table, never EMPTY_POOL).
            local capturedPool = CurrentAuraPool()
            local isOtherTrig = IsOtherTab()
            local trigSpec = (not isOtherTrig) and ResolveSpec() or nil
            local trigSpecInfo = trigSpec and DF.AuraDesigner.SpecInfo[trigSpec]

            -- ☠ THIS GROUP's triggers, not the flat list. GetFrameEffectTriggers returns
            -- group 1 for a grouped effect, so a spell already in group 1 was blocked
            -- everywhere -- which made (A and B) or (A and C) impossible to build, the
            -- exact shape ANY mode exists for. A spell may legitimately appear in several
            -- groups; only a duplicate WITHIN one group is meaningless.
            local trigLookup = {}
            for _, t in ipairs(condGroups[gi].triggers or {}) do trigLookup[t] = true end

            OpenADPicker({
                title = format(L["Select trigger for %s"], S.FRAME_LEVEL_LABELS[effect.typeKey] or effect.typeKey),
                subtitle = effect.displayName,
                records = function() return BuildADPickerRecords(true) end,
                classLock = (not isOtherTrig) and trigSpecInfo and trigSpecInfo.class or nil,
                isBlocked = function(rec)
                    return trigLookup[rec.auraName] and true or nil
                end,
                rowActions = {
                    {
                        handler = function(rec, _, picker)
                            AddEffectTriggerToGroup(effect.auraName, effect.typeKey, gi, rec.auraName, capturedPool)
                            picker:Close()
                            S.SwitchTab("effects")
                            RefreshPreviewEffects()
                            RefreshLiveFramesThrottled()   -- see the trigger-edit note above
                        end,
                    },
                },
            })
        end)

        -- "+ Filter" — the same trigger list, but the entry is a whole registry
        -- filter rather than one spell. It rides the identical code path:
        -- DF:BuildADIdentityFilters resolves an "@preset:"/"@custom:" entry exactly
        -- as it resolves a spell name, so the effect fires on anything the filter
        -- matches. Its own button rather than a mode on the one above, because a
        -- hidden modifier is not a discoverable way to reach half a feature.
        tagX = tagX + addTrigW + TAG_GAP
        local addFilterW = 66
        local addTrigFilterBtn = CreateFrame("Button", nil, trigContainer, "BackdropTemplate")
        addTrigFilterBtn:SetPoint("TOPLEFT", trigContainer, "TOPLEFT", tagX, tagY)
        GUI:StyleButton(addTrigFilterBtn, { width = addFilterW, height = TAG_H, primary = true,
            accent = { r = 0.25, g = 0.40, b = 0.25 },
            -- ☠ ".png" IS MANDATORY in the path. A .tga or .blp resolves without
            -- its extension; a PNG does not, and a missing one fails SILENTLY --
            -- no error, just no texture.
            icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\filter_list.png", size = 11 },
            text = L["Filter"] })
        GUI:SetSettingsFont(addTrigFilterBtn.Text, 9, "")
        addTrigFilterBtn.Text:SetTextColor(0.5, 0.8, 0.5)
        addTrigFilterBtn.Icon:SetVertexColor(0.5, 0.8, 0.5)
        addTrigFilterBtn:SetScript("OnClick", function()
            -- Pool pinned at open time, same reason as the spell picker above.
            local capturedPool = CurrentAuraPool()
            local existing = {}
            for _, t in ipairs(condGroups[gi].triggers or {}) do
                existing[t] = true
            end
            OpenFilterPicker({
                anchor = addTrigFilterBtn,
                isLinked = function(kind, key)
                    local ref = DF:MakeADFilterRef(kind, key)
                    return ref ~= nil and existing[ref] or false
                end,
                onPick = function(kind, key)
                    local ref = DF:MakeADFilterRef(kind, key)
                    if not ref then return end
                    AddEffectTriggerToGroup(effect.auraName, effect.typeKey, gi, ref, capturedPool)
                    S.SwitchTab("effects")
                    RefreshPreviewEffects()
                    RefreshLiveFramesThrottled()   -- see the trigger-edit note above
                end,
            })
        end)

        tagX = 0
        tagY = tagY - (TAG_H + TAG_ROW_GAP + 4)
        end  -- for gi

        -- CONDITION CONTROLS. The operator flips the whole expression's shape, which
        -- is why it is ONE switch rather than per-group: ALL means the groups are ORs
        -- ANDed together, ANY means they are ANDs ORed together. Between them that is
        -- every two-level expression, and the factory renders both (ANY is distributed
        -- into ALL form so it still draws through a single chain, one visual).
        -- The column these two lay out in: what the caller said the body is, less
        -- the container's own two 8px insets. Named because BOTH the mode button
        -- and the Add Condition button below have to fit inside it, and at 150 +
        -- 4 + 110 they do not fit a popout pane's 244 -- which the 850px island
        -- never made them share.
        local trigColW = max((bodyWidth or 260) - 16, 60)
        if multiCond then
            local modeBtn = CreateFrame("Button", nil, trigContainer, "BackdropTemplate")
            modeBtn:SetPoint("TOPLEFT", trigContainer, "TOPLEFT", 0, tagY)
            GUI:StyleButton(modeBtn, { width = 150, height = TAG_H, primary = true,
                accent = { r = 0.91, g = 0.66, b = 0.25 },
                text = condMode == "ALL" and L["Match ALL groups"] or L["Match ANY group"] })
            GUI:SetSettingsFont(modeBtn.Text, 9, "")
            modeBtn:SetScript("OnClick", function()
                SetEffectConditionMode(effect.auraName, effect.typeKey,
                    condMode == "ALL" and "ANY" or "ALL", CurrentAuraPool())
                S.SwitchTab("effects")
                RefreshPreviewEffects()
                RefreshLiveFramesThrottled()
            end)
            tagX = 154
        end

        if #condGroups < 5 then
            -- ⚠ WRAPS RATHER THAN OVERHANGING. Beside a 150px mode button this is
            -- 264px of row, and the pane it now lives in is 244 -- so when the two
            -- do not share a line, this takes the next one. Same rule the tags
            -- above already flow by.
            if tagX > 0 and (tagX + 110) > trigColW then
                tagX = 0
                tagY = tagY - (TAG_H + TAG_ROW_GAP)
            end
            local addGroupBtn = CreateFrame("Button", nil, trigContainer, "BackdropTemplate")
            addGroupBtn:SetPoint("TOPLEFT", trigContainer, "TOPLEFT", tagX, tagY)
            GUI:StyleButton(addGroupBtn, { width = 110, height = TAG_H, primary = true,
                accent = { r = 0.25, g = 0.40, b = 0.25 },
                icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\add", size = 11 },
                text = L["Condition"] })
            GUI:SetSettingsFont(addGroupBtn.Text, 9, "")
            addGroupBtn.Text:SetTextColor(0.5, 0.8, 0.5)
            addGroupBtn.Icon:SetVertexColor(0.5, 0.8, 0.5)
            addGroupBtn:SetScript("OnClick", function()
                AddEffectConditionGroup(effect.auraName, effect.typeKey, CurrentAuraPool())
                S.SwitchTab("effects")
                RefreshPreviewEffects()
                RefreshLiveFramesThrottled()
            end)
        end
        tagY = tagY - (TAG_H + TAG_ROW_GAP)

        -- The factory REFUSES to render an empty group or an over-cap expansion rather
        -- than draw a truncated conjunction, so the card has to say why nothing shows.
        if multiCond then
            local links = EffectChainLinkCount(effect.auraName, effect.typeKey)
            local emptyG = false
            for _, g in ipairs(condGroups) do
                if #(g.triggers or {}) == 0 then emptyG = true break end
            end
            if emptyG or links > 9 then
                local warn = trigContainer:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(warn, 9, "")
                warn:SetPoint("TOPLEFT", trigContainer, "TOPLEFT", 0, tagY)
                -- ☠ AN EXPLICIT WIDTH, NOT A RIGHT ANCHOR, because the line below
                -- has to MEASURE this. A wrap width that comes from an anchor is
                -- not resolved until the layout pass; set here it is the number
                -- the caller already told us the body is.
                warn:SetWidth(trigColW)
                warn:SetJustifyH("LEFT")
                warn:SetWordWrap(true)
                warn:SetText(emptyG and L["A condition group is empty and is being ignored."]
                    or format(L["Too many combinations (%d). Simplify the conditions."], links))
                warn:SetTextColor(0.95, 0.45, 0.35)
                -- 26 was one line plus its gap, which is all this sentence needed
                -- across an 850px card. In a 244px pane it is two.
                tagY = tagY - (max(warn:GetStringHeight() or 0, 14) + 12)
            end
        end

        triggersH = -(tagY) + TAG_H + 8  -- total height of trigger section
        trigContainer:SetHeight(triggersH)
    return triggersH
end

S.BuildEffectPriorityBlock = function(body, effect, proxy, bodyWidth, baseH)
    baseH = baseH or 0
    local h = 0
        -- "Own border" opt-out (border effects only). BELOW Priority on purpose: this
        -- is a border-specific override sitting next to the Border appearance controls
        -- it belongs with.
        --
        -- ☠ A MEMBERSHIP choice, not a mode. It was a Priority/Stacked button PAIR,
        -- which read as a per-aura policy and raised the obvious question: what if one
        -- indicator says Priority and another says Stacked? (They coexist fine -- the
        -- stacked one opts out of the contest and the priority one takes the shared
        -- ring.) Unticked = share the frame's one border, resolve by Priority; ticked =
        -- draw your own alongside.
        -- ☠ THE STORED VALUE IS UNCHANGED -- nil / "custom" -- so no migration and old
        -- profiles keep working. Do not "tidy" it to a boolean without one.
        -- ☠ HOISTED ON PURPOSE. SyncPriorityNote (border block below) writes to
        -- priNote, but the label isn't built until after that block. Declaring both
        -- here makes them shared upvalues -- a `local` further down never back-fills
        -- a closure that was already compiled, which is exactly what made this card
        -- error out and abort the whole Effects tab build.
        local priNote, SyncPriorityNote

        if effect.typeKey == "border" then
            local function OwnBorderOn()
                local a = CurrentAuraPool()[effect.auraName]
                local t = a and a[effect.typeKey]
                return (t and t.borderMode == "custom") and true or false
            end

            -- ☠ RE-WORD THE PRIORITY NOTE, DO NOT DISABLE THE SLIDER. "Higher priority
            -- wins" is false once this aura opts out of the contest, but the slider is
            -- still live: priority is per-AURA, so it still resolves this aura's health
            -- bar / background / text effects, and collectStackedBorders sorts by it so
            -- it orders the stacked rings too.
            SyncPriorityNote = function()
                priNote:SetText(OwnBorderOn()
                    and L["This aura's border always shows. Priority still applies to its other effects."]
                    or L["Higher priority wins"])
            end

            -- customGet/customSet rather than a db key: the stored value is nil /
            -- "custom", not a boolean, and the checkbox maps ticked -> "custom".
            local ownBorderCb = GUI:CreateCheckbox(body, L["Give this aura its own border"],
                nil, nil,
                function()
                    SyncPriorityNote()
                    S.SwitchTab("effects")
                    RefreshPreviewEffects()
                    -- Live frames too: borderMode picks which container renders the
                    -- ring, so the editor repaint alone left real frames on the old
                    -- mode until a reload.
                    RefreshLiveFramesThrottled()
                end,
                OwnBorderOn,
                function(val)
                    local cfg = EnsureTypeConfig(effect.auraName, effect.typeKey)
                    cfg.borderMode = val and "custom" or nil
                end)
            ownBorderCb:SetPoint("TOPLEFT", body, "TOPLEFT", 8, -(baseH + h + 10))
            ownBorderCb:SetWidth(bodyWidth - 16)
            ownBorderCb.tooltip = {
                title = L["Give this aura its own border"],
                lines = {
                    L["Off: this aura shares the frame's single border. If two auras both want it, the higher Priority one shows."],
                    L["On: it draws its own border alongside the others. Give them different Insets so they nest instead of covering each other."],
                },
            }
            h = h + 36
        end

        -- Priority slider (frame-level effects only — resolves conflicts when
        -- multiple auras set the same frame effect, e.g. two health bar colors)
        local auraProxy = CreateAuraProxy(effect.auraName)
        local priSlider = GUI:CreateSlider(body, L["Priority"], 1, 10, 1, auraProxy, "priority")
        -- Extra gap above (was +4) so the slider isn't squished against the
        -- triggers / Add Trigger row, plus a little breathing room below before
        -- the effect's Appearance group (increment 54 → 68 → 84 with the note).
        -- x=8 matches the "TRIGGERED BY" section above (Options.lua trigContainer)
        -- so the Priority slider + note line up with the card's other elements.
        priSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 8, -(baseH + h + 14))
        priSlider:SetWidth(bodyWidth - 16)
        -- Direction note in the standard GUI label style (dim, wrapped) so it
        -- matches every other settings note: HIGHER number = higher priority.
        priNote = GUI:CreateLabel(body, L["Higher priority wins"], bodyWidth - 16)
        priNote:SetPoint("TOPLEFT", priSlider, "BOTTOMLEFT", 0, -2)
        -- Only now does the label exist, so this is where the border-aware wording
        -- gets applied. Non-border effects never assign SyncPriorityNote and keep the
        -- default text the label was built with.
        if SyncPriorityNote then SyncPriorityNote() end
        h = h + 84
    return h
end

-- What toggling Others Only costs, in one place: the card draws it as a checkbox
-- in the body, the row page as a control row of its own, and the two must not
-- drift on the four things a caster-filter change has to drive. `redraw` is the
-- layout's own repaint -- the card rebuilds the page (its default), a control row
-- hands in the page's state pass instead, because a rebuild there would retire the
-- row being clicked.
S.EffectOthersOnlyChanged = function(redraw)
    if type(redraw) == "function" then redraw() else DF:AuraDesigner_RefreshPage() end
    DF:InvalidateAuraLayout()
    DF:UpdateAllFrames()
    if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
    end
end

S.CreateEffectCard = function(parent, yPos, effect)
    local isPlaced = (effect.source == "placed")
    -- B1 key scheme: the pool prefix rides the NAME segment, so the two
    -- pools' expandedCards entries can never collide.
    local keyPrefix = PoolKeyPrefix()
    local cardKey
    if isPlaced then
        cardKey = "placed:" .. keyPrefix .. effect.auraName .. "#" .. effect.indicatorID
    else
        cardKey = "frame:" .. effect.typeKey .. ":" .. keyPrefix .. effect.auraName
    end

    local isExpanded = expandedCards[cardKey] or false

    -- ── CARD + HEADER ──
    local card, header, chevron = CreateCardShell(parent, {
        yPos        = yPos,
        expanded    = isExpanded,
        borderColor = {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5},
    })

    -- Spell icon (small, before type badge). Other-pool records resolve
    -- icon/identity spec-independently (nil spec → ad-hoc / SpellDB fallback).
    local spec = IsOtherTab() and nil or ResolveSpec()
    local iconTex = GetAuraIcon(spec, effect.auraName)
    -- ⚠ A filter-owned record shows our GLYPH here, not a spell icon, and the two
    -- need different treatment. The 0.08/0.92 crop below exists to trim the border
    -- baked into Blizzard's spell art; applied to a clean glyph it just zooms in,
    -- which is why the filter mark read as far too heavy beside the type badge. So:
    -- no crop, and smaller, since a glyph carries no border to lose.
    local isGlyphIcon = (DF.ParseADFilterRef and DF:ParseADFilterRef(effect.auraName)) and true or false

    -- ☠ A FIXED 20px SLOT, and the badge anchors to the SLOT, not to the art. The
    -- badge used to hang off the icon's own right edge, so the moment the glyph was
    -- drawn at 13 the badge -- and the name, the eye and the ✕ behind it -- slid 4px
    -- left, and a filter row no longer lined up with the Square and Icon rows above
    -- it. Every row now reserves the same width whatever it draws inside.
    local iconSlot = CreateFrame("Frame", nil, header)
    iconSlot:SetSize(20, 20)
    iconSlot:SetPoint("LEFT", chevron, "RIGHT", 6, 0)

    local spellIcon = iconSlot:CreateTexture(nil, "ARTWORK")
    spellIcon:SetSize(isGlyphIcon and 13 or 20, isGlyphIcon and 13 or 20)
    spellIcon:SetPoint("CENTER")
    if iconTex then
        spellIcon:SetTexture(iconTex)
        if not isGlyphIcon then
            spellIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
    else
        -- Color swatch fallback using aura color
        local trackable3 = spec and Adapter and Adapter:GetTrackableAuras(spec)
        local auraColor = nil
        if trackable3 then
            for _, ai in ipairs(trackable3) do
                if ai.name == effect.auraName then auraColor = ai.color; break end
            end
        end
        if auraColor then
            spellIcon:SetColorTexture(auraColor[1] * 0.5, auraColor[2] * 0.5, auraColor[3] * 0.5, 1)
        else
            spellIcon:SetColorTexture(0.25, 0.25, 0.25, 1)
        end
    end

    -- Type badge
    local badgeColor = BADGE_COLORS[effect.typeKey] or BADGE_COLORS.icon
    local typeLabel = isPlaced
        and (S.PLACED_TYPE_LABELS[effect.typeKey] or effect.typeKey)
        or (S.FRAME_LEVEL_LABELS[effect.typeKey] or effect.typeKey)

    local badgeBg = CreateFrame("Frame", nil, header, "BackdropTemplate")
    badgeBg:SetHeight(16)
    badgeBg:SetPoint("LEFT", iconSlot, "RIGHT", 4, 0)
    ApplyBackdrop(badgeBg,
        {r = badgeColor.r * 0.20, g = badgeColor.g * 0.20, b = badgeColor.b * 0.20, a = 1},
        {r = badgeColor.r * 0.45, g = badgeColor.g * 0.45, b = badgeColor.b * 0.45, a = 0.8})

    local badgeText = badgeBg:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(badgeText, 8, "OUTLINE")
    badgeText:SetPoint("CENTER", 0, 0)
    badgeText:SetText(typeLabel)
    badgeText:SetTextColor(1, 1, 1)
    badgeBg:SetWidth(max(badgeText:GetStringWidth() + 12, 32))

    -- Warning badge for auras with API-level tracking limitations
    -- (positioned to the right of the type badge)
    -- ★ ...AND THE HELPER'S CLASH WARNING, on the same badge. A helper border sitting under one
    -- of the user's own borders draws nothing and says nothing; this is where it says it. See
    -- P.PIH_ClashText: it asks about THIS row's own config, names the offender, and names a
    -- remedy that still exists (tick "Give this aura its own border" and BOTH rings show, or
    -- raise Priority on a text surface).
    local warnKey = GetAuraWarningKey(spec, effect.auraName)
    local clashText = (effect.config and effect.config.pihSignal and P.PIH_ClashText)
        and P.PIH_ClashText(effect.config, effect.typeKey) or nil
    AttachWarningBadge(header, warnKey, {
        point = "LEFT",
        relativeTo = badgeBg,
        relativePoint = "RIGHT",
        offsetX = 4,
        offsetY = 0,
        size = 16,
        text = clashText,
    })

    -- Aura name + anchor/trigger/group info
    local infoStr = effect.displayName
    local indicatorGroup = nil  -- layout group this indicator belongs to
    if isPlaced then
        indicatorGroup = GetIndicatorLayoutGroup(effect.auraName, effect.indicatorID)
        if indicatorGroup then
            infoStr = infoStr .. "  -  " .. indicatorGroup.name
        elseif effect.anchor then
            infoStr = infoStr .. "  -  " .. (OPTS.ANCHOR_OPTIONS[effect.anchor] or effect.anchor)
        end
    else
        -- Show trigger count for frame-level effects
        local triggers = GetFrameEffectTriggers(effect.auraName, effect.typeKey)
        if #triggers > 1 then
            -- No "(AND)" suffix: the operator toggle is gone (12.1 cannot evaluate
            -- triggers together read-free), so multiple triggers always mean ANY/OR.
            infoStr = infoStr .. "  -  " .. format(L["+%d triggers"], #triggers - 1)
        end
    end
    -- Other Buffs: surface the per-effect Others Only state on the collapsed
    -- header (prototype's "Others only" chip, as a text suffix).
    -- ⚠ NOT ON THE HELPER'S POOL, where it is a constant rather than a state -- see
    -- P.ShowsOthersOnly for the whole argument.
    if ShowsOthersOnly() and effect.config and effect.config.othersOnly then
        infoStr = infoStr .. "  -  " .. L["Others Only"]
    end
    local infoText = header:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    if warnKey and header.dfWarningBadge and header.dfWarningBadge:IsShown() then
        infoText:SetPoint("LEFT", header.dfWarningBadge, "RIGHT", 6, 0)
    else
        infoText:SetPoint("LEFT", badgeBg, "RIGHT", 6, 0)
    end
    -- Right inset clears the action icons: eye only (grouped) or eye + ✕.
    infoText:SetPoint("RIGHT", header, "RIGHT", indicatorGroup and -30 or -52, 0)
    infoText:SetMaxLines(1)
    infoText:SetText(infoStr)
    if indicatorGroup then
        -- Use dimmed text for grouped indicators — they're managed by the group
        infoText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    else
        infoText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    end

    -- Delete button — hidden for grouped indicators (managed by layout group)
    local delBtn
    if not indicatorGroup then
        delBtn = GUI:CreateCloseButton(header, {
            size = 22,
            onClick = function()
                -- ⚠ ASKED BEFORE THE REMOVAL, because after it there is no config left to
                -- ask. See P.PIH_ReDerive: the helper's engine half is not the designer's
                -- business, and deleting its last effect through this button would otherwise
                -- leave the watcher and the sound armed for a feature with nothing in it.
                local wasPIH = effect.config and effect.config.pihSignal
                if isPlaced then
                    RemoveIndicatorInstance(effect.auraName, effect.indicatorID)
                else
                    local auraCfg = CurrentAuraPool()[effect.auraName]
                    if auraCfg then auraCfg[effect.typeKey] = nil end
                    S.CleanupAdHocAura(effect.auraName)  -- drop emptied ad-hoc "#<id>" entries
                end
                if wasPIH and P.PIH_ReDerive then P.PIH_ReDerive() end
                expandedCards[cardKey] = nil
                S.SwitchTab("effects")
                RefreshPlacedIndicators()
                RefreshPreviewEffects()
                -- Structural change: the container must rebuild AND the buff-row
                -- dedup union shrinks (deleted = no longer tracked), so run the
                -- full refresh path (mirror the eye toggle) — without this the
                -- deleted indicator's buff-row icon stays suppressed until an
                -- unrelated rebuild.
                DF:InvalidateAuraLayout()
                DF:UpdateAllFrames()
                if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end
            end,
        })
        delBtn:SetPoint("RIGHT", -4, 0)
        delBtn:SetFrameLevel(header:GetFrameLevel() + 2)
    end

    -- Eye icon (visibility toggle) — left of the ✕; grouped indicators keep it
    -- even though their ✕ is hidden. Asset + toggle idiom mirror Text Designer's
    -- eye (TextDesigner/Options.lua): visibility / visibility_off from
    -- Media/Icons, bright when shown, dim when hidden, hover brighten.
    -- State lives on the raw config table: enabled == false is hidden;
    -- nil/true (legacy records) is shown.
    do
        local cfgTable = effect.config
        local mediaPath = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"
        local eyeBtn = DF.GUI:CreateGlyphButton(header, { size = 18 })
        if delBtn then
            eyeBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
        else
            eyeBtn:SetPoint("RIGHT", header, "RIGHT", -6, 0)
        end
        local function shown() return not cfgTable or cfgTable.enabled ~= false end
        -- ★ TRACKS NOTHING = GREYED, WITHOUT TOUCHING THE STORED VALUE.
        -- With every spell id unticked the indicator cannot render, so the eye shows the
        -- inactive glyph whatever `enabled` says. It is a DERIVED look, not a write: tick
        -- an id back on and the eye simply resumes reflecting what the user set — on if
        -- they had it on, still off if they had it off. Nothing "forces the eye on",
        -- because nothing ever writes it but the click below.
        -- Dimmer than the ordinary hidden state so the two read apart: hidden-by-choice is
        -- 0.45, cannot-show is 0.3.
        local function tracksNothing()
            return DF.ADPlacementTracksNothing
                and DF:ADPlacementTracksNothing((not IsOtherTab()) and ResolveSpec() or nil,
                        effect.auraName, cfgTable) or false
        end
        -- SetGlyph makes the state colour the new REST colour, so OnLeave
        -- restores the state; hover is suppressed while hidden.
        local function updateEyeIcon()
            local dead = tracksNothing()
            if dead then
                eyeBtn:SetGlyph(mediaPath .. "visibility_off", { 0.3, 0.3, 0.3 })
            elseif shown() then
                eyeBtn:SetGlyph(mediaPath .. "visibility", { 0.95, 0.95, 0.95 })
            else
                eyeBtn:SetGlyph(mediaPath .. "visibility_off", { 0.45, 0.45, 0.45 })
            end
            eyeBtn:SetGlyphHover(shown() and not dead)
            -- Only in the dead state: a tooltip on a working eye would explain a problem
            -- it does not have.
            eyeBtn.tooltip = dead and L["Nothing ticked — this indicator will not show."] or nil
        end
        updateEyeIcon()
        eyeBtn:RegisterForClicks("LeftButtonUp")
        eyeBtn:SetFrameLevel(header:GetFrameLevel() + 2)
        -- ☠ INERT WHEN IT TRACKS NOTHING, AND IT HAS TO SAY WHY. The glyph already goes
        -- dead-grey and drops its hover for this state, but the click still fired: it
        -- flipped `enabled`, ran the whole refresh path, and changed nothing on screen,
        -- because tracksNothing() wins in updateEyeIcon regardless of the flag. A control
        -- that responds to a click by doing nothing visible reads as broken. Refusing it
        -- is only half the fix — a refusal with no reason reads as broken too, so the
        -- tooltip names the actual cause (set in updateEyeIcon), which is fixable one card
        -- down: tick an effect in Tracked IDs.
        eyeBtn:SetScript("OnClick", function()
            if not cfgTable then return end
            if tracksNothing() then return end
            cfgTable.enabled = (cfgTable.enabled == false) and true or false
            updateEyeIcon()
            -- Sound rides the same flag as its "Enable Sound Alert" checkbox —
            -- stop a playing alert immediately when hidden (mirror that checkbox).
            if effect.typeKey == "sound" and cfgTable.enabled == false
                and DF.AuraDesigner.SoundEngine then
                DF.AuraDesigner.SoundEngine:StopAura(effect.auraName)
            end
            -- Structural change: the factory must tear down / stand up the
            -- container and the buff-row dedup union changes (hidden = not
            -- tracked), so run the full refresh path (mirror the enable toggle).
            S.SwitchTab("effects")
            RefreshPlacedIndicators()
            RefreshPreviewEffects()
            DF:InvalidateAuraLayout()
            DF:UpdateAllFrames()
            if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end
        end)

        -- Hidden rows dim (name/icon), like Text Designer's disabled elements.
        -- ☠ The SAME condition the eye uses, or the row half-greys: the eye went inactive
        -- for a placement tracking nothing while the name and icon beside it stayed bright,
        -- which reads as the eye being wrong rather than the row being inert. Both states
        -- mean "this is not going to render", so both dim the row.
        if not shown() or tracksNothing() then
            spellIcon:SetAlpha(0.4)
            infoText:SetAlpha(0.5)
        end
    end

    -- Header click → toggle expansion
    header:SetScript("OnClick", function()
        expandedCards[cardKey] = not expandedCards[cardKey]
        S.SwitchTab("effects")
    end)
    header:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
    end)
    header:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    end)

    local totalCardH = 30

    -- ── BODY (only when expanded) ──
    if isExpanded then
        local body = CreateFrame("Frame", nil, card, "BackdropTemplate")
        body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
        body:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
        ApplyBackdrop(body, {r = 0.09, g = 0.09, b = 0.09, a = 1},
            {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.3})

        -- Create the appropriate proxy
        local proxy
        if isPlaced then
            proxy = CreateInstanceProxy(effect.auraName, effect.indicatorID)
        else
            proxy = CreateProxy(effect.auraName, effect.typeKey)
        end

        -- Build type-specific widgets (derive width from parent scroll frame)
        local bodyWidth = (S.tabContentFrame and S.tabContentFrame:GetWidth() or 260) - 24
        if bodyWidth < 100 then bodyWidth = 240 end

        local triggersH = 0

        -- ── TRIGGER TAGS + PRIORITY (frame-level effects only) ──
        if not isPlaced then
            triggersH = S.BuildEffectTriggersBlock(body, effect, bodyWidth, 0)
            triggersH = triggersH + S.BuildEffectPriorityBlock(body, effect, proxy, bodyWidth, triggersH)
        end

        -- ── OTHERS ONLY (Other Buffs tab; placed AND frame-level effects) ──
        -- Not offered for sound: the on-apply sound path has no caster filter
        -- (the sound card carries an explanatory banner instead, see
        -- BuildTypeContent). Writes instance.othersOnly / typeCfg.othersOnly
        -- through the pool-pinned proxy; the filter string ("HELPFUL|!PLAYER")
        -- binds at container build, so toggling is STRUCTURAL (B1 folds it
        -- into every struct sig → the factory Rebuilds).
        -- ⚠ ...AND NOT ON THE HELPER'S POOL: there the caster rule is stamped by the recipe
        -- and is not the user's to change. P.ShowsOthersOnly carries the reasoning.
        if ShowsOthersOnly() and effect.typeKey ~= "sound" then
            local ooCb = GUI:CreateCheckbox(body, L["Others Only"], proxy, "othersOnly",
                                            S.EffectOthersOnlyChanged)
            ooCb:SetPoint("TOPLEFT", body, "TOPLEFT", 8, -(triggersH + 12))
            ooCb:SetWidth(bodyWidth - 16)
            ooCb.tooltip = L["Only show this effect for other players' casts of the buff."]
            triggersH = triggersH + 34
        end

        local _, bodyH = BuildTypeContent(body, effect.typeKey, effect.auraName, bodyWidth, proxy, triggersH, indicatorGroup, effect.indicatorID)

        -- Bottom collapse bar for the indicator card
        local collapseBarH = 14
        local collapseBar = CreateFrame("Button", nil, body)
        collapseBar:SetHeight(collapseBarH)
        collapseBar:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 1, 1)
        collapseBar:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -1, 1)

        local barBg = collapseBar:CreateTexture(nil, "BACKGROUND")
        barBg:SetAllPoints()
        barBg:SetColorTexture(1, 1, 1, 0.03)

        local barIcon = collapseBar:CreateTexture(nil, "OVERLAY")
        barIcon:SetSize(8, 8)
        barIcon:SetPoint("CENTER", 0, 0)
        barIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
        barIcon:SetVertexColor(1, 1, 1, 0.3)

        collapseBar:SetScript("OnEnter", function()
            barBg:SetColorTexture(1, 1, 1, 0.06)
            barIcon:SetVertexColor(1, 1, 1, 0.6)
        end)
        collapseBar:SetScript("OnLeave", function()
            barBg:SetColorTexture(1, 1, 1, 0.03)
            barIcon:SetVertexColor(1, 1, 1, 0.3)
        end)
        collapseBar:SetScript("OnClick", function()
            expandedCards[cardKey] = false
            S.SwitchTab("effects")
        end)

        local contentH = (bodyH or 50) + triggersH + collapseBarH
        body:SetHeight(contentH)
        totalCardH = totalCardH + contentH
    end

    card:SetHeight(totalCardH)
    return yPos - totalCardH - 5
end

-- ── BUILD EFFECTS TAB ──
-- ── THE EFFECTS TAB'S HEAD AREA ──
-- The add block (or, while one is open, the scope picker that takes the whole
-- column over), the ACTIVE INDICATORS heading, the type chips and the Other
-- Buffs hint. Everything above the list of effects, and nothing of the list.
--
-- ============================================================
-- THE ADD FLOW  (designer rework, section 26)
-- ------------------------------------------------------------
-- ☠ ONE PANEL, THREE NUMBERED SECTIONS, ALL VISIBLE AT ONCE. This shipped once
-- as a three-step WIZARD -- spell, then a scope (Placed on Frame / Frame-Level /
-- From a Filter), then a type -- and the scope step is precisely what the
-- approved design removes. The taxonomy was the problem, not a list length: with
-- it gone the effects are nine tiles on one surface, and a person can see the
-- whole task before starting it instead of discovering step 3 by finishing
-- step 2.
--
-- ☠ AND THE CHOICES ARE PICTURES, NOT LABELS WITH ART BLOBS. Each tile draws one
-- of the player's OWN frames in miniature -- CreateFramePreview's `thumb` arm,
-- so the same green fill, missing-health remainder, power bar and name/health
-- strings, read from the same frameDB -- with the effect applied to it. An
-- earlier synthetic thumbnail drew a generic unit frame and the verdict was
-- "this looks nothing like one of our frames".
--
-- ⚠ SECTIONS 2 AND 3 START DIMMED, NOT HIDDEN. Showing the shape of the whole
-- task is the point; a section that appears only once you have answered the one
-- above it is a wizard with the seams painted over.
--
-- ⚠ WHY "FROM A FILTER" IS IN SECTION 1 AND NOT A SCOPE. A filter cannot be
-- reached spell-first -- its effect hangs off a whole filter, so a spell picked
-- first would be discarded -- but that is an argument for where the CHOICE OF
-- SOURCE lives, not for restoring a step. Section 1 asks "which aura?", and a
-- filter is a saved answer to exactly that question: one section, one question,
-- two ways to answer it. Choosing a filter dims the tiles a filter cannot drive
-- (the three placed types, and Sound -- the native sound path registers per
-- spell id, so a 600-spell filter would mean 600 registrations).
--
-- ☠ EVERY TILE IS BUILT ONCE. The popout kit builds a pane's contents once and
-- frames cannot be garbage-collected in this client, so nothing here rebuilds on
-- a click: what changes is each tile's STATE. What it costs is nine miniature
-- frames per page build, which is the price of the pictures and is paid
-- deliberately -- the fourteen choice cards this replaces were memoised at up to
-- eleven per panel for the same reason.
--
-- ☠ AND A POOLED PANEL CANNOT READ LIVE STATE IN ITS BUILDER. "Already added" is
-- true or false per tile and changes underneath a panel that is merely closed,
-- so it is re-derived by a `Sync` verb the opener calls -- the same shape as
-- S.BuildFilterChips's SyncActive, and the same bug both designer panels shipped
-- with before it (spec section 23).
-- ============================================================

-- The three scopes and the type lists behind them. A VERB rather than a file-scope
-- table because every label in here is an L[...] lookup, and a table built at file
-- scope freezes on whatever locale was loaded when the file parsed.
--
-- ⚠ STILL LIVE, FOR THE SPLIT PANEL ONLY. The island layout keeps its three
-- pinned scope cards and the picker column they open, in its own head area at
-- the foot of this file; the popout layout's panel is flat and does not read it.
local function AddFlowScopes()
    local PLACED_ITEMS = {
        { label = L["Icon"],   type = "icon",   desc = L["The spell's own artwork"]          },
        { label = L["Square"], type = "square", desc = L["A small coloured square"]          },
        { label = L["Bar"],    type = "bar",    desc = L["A bar that drains as it expires"]  },
    }
    -- Sound is absent from the filter list by design: the native sound path
    -- registers per spell ID, so a 600-spell filter would mean 600 registrations.
    local FRAME_ITEMS = {
        { label = L["Border"],            type = "border",     desc = L["Outlines the whole frame"]        },
        { label = L["Health Bar Color"],  type = "healthbar",  desc = L["Recolours the health bar"]        },
        { label = L["Background Color"],  type = "background", desc = L["Recolours the frame background"]  },
        { label = L["Name Text Color"],   type = "nametext",   desc = L["Recolours the player's name"]     },
        { label = L["Health Text Color"], type = "healthtext", desc = L["Recolours the health numbers"]    },
        { label = L["Sound Alert"],       type = "sound",      desc = L["Plays a sound. Nothing changes on the frame."] },
    }
    local FRAME_FILTER_ITEMS = {
        { label = L["Border"],            type = "border",     desc = L["Outlines the whole frame"]        },
        { label = L["Health Bar Color"],  type = "healthbar",  desc = L["Recolours the health bar"]        },
        { label = L["Background Color"],  type = "background", desc = L["Recolours the frame background"]  },
        { label = L["Name Text Color"],   type = "nametext",   desc = L["Recolours the player's name"]     },
        { label = L["Health Text Color"], type = "healthtext", desc = L["Recolours the health numbers"]    },
    }
    return {
        placed = { items = PLACED_ITEMS,       title = L["Placed on the Frame"],
                   desc = L["An icon, square or bar, wherever you put it"] },
        frame  = { items = FRAME_ITEMS,        title = L["Frame-Level Effect"],
                   desc = L["Recolours the frame itself"] },
        filter = { items = FRAME_FILTER_ITEMS, title = L["From a Filter"],
                   desc = L["The same frame changes, driven by a whole filter"] },
    }
end
P.AddFlowScopes = AddFlowScopes

-- ── THE FLAT EFFECT LIST ──
-- ☠ ONE LIST, NO CLASSIFICATION. The same nine effects the three scopes above
-- hold between them, with the taxonomy taken off: `mode` is still what the store
-- needs (a placed indicator instance, or a frame-level type config) but it is
-- carried BY the choice rather than asked before it.
--
-- ⚠ NINE, NOT THE DESIGN'S SIX. The drawing lists "Icon | Square | Bar |
-- Recolour | Border | Sound", and "Recolour" is one word standing for FOUR
-- distinct effects with four distinct records -- health bar, background, name
-- text, health text. Collapsing them would either drop three of them or ask a
-- second question, which is the step this panel exists to remove; and a card
-- that is a PICTURE of the result is exactly what makes four of them cheap to
-- tell apart, where four words would not be. Flat is the principle; six was the
-- sketch's shorthand.
--
-- A VERB, not a file-scope table: every label is an L[...] lookup and a table
-- built at load freezes on the locale that was live then.
local function AddFlowEffects()
    return {
        { type = "icon",       mode = "placed", label = L["Icon"],
          desc = L["The spell's own artwork"],          filterable = false },
        { type = "square",     mode = "placed", label = L["Square"],
          desc = L["A small coloured square"],          filterable = false },
        { type = "bar",        mode = "placed", label = L["Bar"],
          desc = L["A bar that drains as it expires"],  filterable = false },
        { type = "border",     mode = "frame",  label = L["Border"],
          desc = L["Outlines the whole frame"],         filterable = true  },
        { type = "healthbar",  mode = "frame",  label = L["Health Bar Color"],
          desc = L["Recolours the health bar"],         filterable = true  },
        { type = "background", mode = "frame",  label = L["Background Color"],
          desc = L["Recolours the frame background"],   filterable = true  },
        { type = "nametext",   mode = "frame",  label = L["Name Text Color"],
          desc = L["Recolours the player's name"],      filterable = true  },
        { type = "healthtext", mode = "frame",  label = L["Health Text Color"],
          desc = L["Recolours the health numbers"],     filterable = true  },
        -- Sound is not filterable: see AddFlowScopes above for why.
        { type = "sound",      mode = "frame",  label = L["Sound Alert"],
          desc = L["Plays a sound. Nothing changes on the frame."], filterable = false },
    }
end
P.AddFlowEffects = AddFlowEffects

-- ── THE EFFECT, PAINTED ONTO A MINIATURE FRAME ──
-- What each tile's picture actually IS. Everything is drawn in the mock's OWN
-- units -- a 24px icon on a 125x64 frame -- and the whole mock is then scaled to
-- the tile, so the proportions are the player's real ones rather than a guess.
-- The sizes and anchors come from TYPE_DEFAULTS, which is what a fresh indicator
-- of that type is actually created with.
local DEFAULT_TILE_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- ⚠ `staticSpellID` PAINTS THE TILE WITH ONE SPELL'S ART AND FREEZES IT THERE. The question
-- mark is the DESIGNER's honest placeholder: its add flow asks for a type first and a spell
-- second, so at tile-paint time there is genuinely no artwork to show and the picture is
-- swapped in later through pv.spellIcon.
-- ☠ ON THE POWER INFUSION HELPER'S POOL THAT NEVER HAPPENS. There is no spell step -- the
-- cooldown list IS the spell -- so nothing ever came back to swap the placeholder, and the
-- one tile whose whole subject is a fixed picture was the one showing a question mark.
-- Krathe, 2026-09-09: "on the example for icon it has a ? instead of the PI icon (on the GUI,
-- works fine to actually show PI when their CD was active)" -- the live half was already
-- right, which is what narrowed this to the tile.
local function PaintEffectOnThumb(pv, typeKey, staticSpellID)
    local mock = pv.mockFrame
    if not mock then return end
    local c = BADGE_COLORS[typeKey] or GetThemeColor()
    local defs = TYPE_DEFAULTS and TYPE_DEFAULTS[typeKey] or nil
    local anchorName = (defs and defs.anchor) or "TOPLEFT"
    local pos = ANCHOR_POSITIONS[anchorName] or ANCHOR_POSITIONS.TOPLEFT

    if typeKey == "icon" then
        local size = (defs and defs.size) or 24
        local ring = mock:CreateTexture(nil, "OVERLAY", nil, 1)
        ring:SetColorTexture(0, 0, 0, 0.85)
        ring:SetSize(size + 2, size + 2)
        ring:SetPoint(pos.ax, mock, pos.ay, 0, 0)
        local ico = mock:CreateTexture(nil, "OVERLAY", nil, 2)
        ico:SetSize(size, size)
        ico:SetPoint("CENTER", ring, "CENTER", 0, 0)
        local pinned = staticSpellID and C_Spell and C_Spell.GetSpellTexture
            and C_Spell.GetSpellTexture(staticSpellID) or nil
        ico:SetTexture(pinned or DEFAULT_TILE_ICON)
        ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        -- Swapped for the chosen spell's own artwork once section 1 is answered:
        -- "the spell's own artwork" is the whole of what this effect does, so the
        -- picture is only honest when it is that spell's.
        -- ☠ ...AND NOT PUBLISHED AT ALL WHEN THE ART IS PINNED. pv.spellIcon is the handle
        -- the add pane swaps through; leaving it set on a pinned tile would let the pane
        -- repaint Power Infusion with whatever spell was picked, which is the one thing the
        -- pinned art exists to prevent.
        if not pinned then pv.spellIcon = ico end

    elseif typeKey == "square" then
        local size = (defs and defs.size) or 24
        local ring = mock:CreateTexture(nil, "OVERLAY", nil, 1)
        ring:SetColorTexture(0, 0, 0, 1)
        ring:SetSize(size + 2, size + 2)
        ring:SetPoint(pos.ax, mock, pos.ay, 0, 0)
        local sq = mock:CreateTexture(nil, "OVERLAY", nil, 2)
        sq:SetColorTexture(c.r, c.g, c.b, 1)
        sq:SetSize(size, size)
        sq:SetPoint("CENTER", ring, "CENTER", 0, 0)

    elseif typeKey == "bar" then
        -- matchFrameWidth is on by default, so a fresh bar spans the frame.
        local barH = (defs and defs.height) or 6
        local bg = mock:CreateTexture(nil, "OVERLAY", nil, 1)
        bg:SetColorTexture(0, 0, 0, 0.5)
        bg:SetHeight(barH)
        bg:SetPoint("BOTTOMLEFT", mock, "BOTTOMLEFT", 1, 1)
        bg:SetPoint("BOTTOMRIGHT", mock, "BOTTOMRIGHT", -1, 1)
        local fill = mock:CreateTexture(nil, "OVERLAY", nil, 2)
        fill:SetColorTexture(c.r, c.g, c.b, 1)
        fill:SetHeight(barH)
        fill:SetPoint("BOTTOMLEFT", bg, "BOTTOMLEFT", 0, 0)
        fill:SetPoint("TOPLEFT", bg, "TOPLEFT", 0, 0)
        -- Two thirds drained, so it reads as a bar that empties rather than a
        -- second health bar.
        fill:SetWidth(((mock:GetWidth() or 125) - 2) * 0.66)

    elseif typeKey == "border" then
        -- Four edges rather than a backdrop swap: the mock already HAS a border,
        -- and this has to read as sitting on top of it.
        local T = 2
        for _, e in ipairs({ { "TOPLEFT", "TOPRIGHT", nil, T }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, T },
                             { "TOPLEFT", "BOTTOMLEFT", T, nil }, { "TOPRIGHT", "BOTTOMRIGHT", T, nil } }) do
            local t = mock:CreateTexture(nil, "OVERLAY", nil, 3)
            t:SetColorTexture(c.r, c.g, c.b, 1)
            t:SetPoint(e[1], mock, e[1], 0, 0)
            t:SetPoint(e[2], mock, e[2], 0, 0)
            if e[3] then t:SetWidth(e[3]) end
            if e[4] then t:SetHeight(e[4]) end
        end

    elseif typeKey == "healthbar" then
        -- The recolour IS the picture: the same fill the canvas draws, in the
        -- effect's colour instead of the health green.
        if pv.healthFill then pv.healthFill:SetVertexColor(c.r, c.g, c.b, 1) end

    elseif typeKey == "background" then
        -- The canvas tints healthBg and nothing else for this effect
        -- (AuraDesigner/UI/Groups.lua's RefreshPreviewEffects); the picture says
        -- the same thing the live preview would.
        if pv.healthBg then pv.healthBg:SetColorTexture(c.r, c.g, c.b, 0.85) end

    elseif typeKey == "nametext" then
        if pv.nameText then pv.nameText:SetTextColor(c.r, c.g, c.b, 1) end

    elseif typeKey == "healthtext" then
        if pv.hpText then pv.hpText:SetTextColor(c.r, c.g, c.b, 1) end

    elseif typeKey == "sound" then
        -- ☠ THE FRAME STAYS UNTOUCHED, AND THAT IS THE PROBLEM THIS SOLVES. A
        -- sound alert changes nothing about the frame, so an untouched frame is
        -- the honest picture of it -- but an untouched frame is ALSO exactly what
        -- "nothing chosen" looks like, and in a grid of eight tiles that all show
        -- a change, the one that shows none reads as empty rather than as silent
        -- (spec section 27.1). The note is laid OVER the mock rather than
        -- altering it, so the picture stays honest and gains the one word it was
        -- missing.
        --
        -- ⚠ TEXTURES, NOT A WIDGET. Anything on a tile that can take the mouse
        -- takes it across the whole picture -- a 220x30 slider over a 76x44
        -- thumbnail is what made every tile unclickable except in its margin. A
        -- texture has no mouse to take.
        local size = 26
        -- The plate is what makes it legible over the health fill; the same
        -- trick the icon and square arms use behind their own artwork.
        local plate = mock:CreateTexture(nil, "OVERLAY", nil, 1)
        plate:SetColorTexture(0, 0, 0, 0.55)
        plate:SetSize(size + 6, size + 6)
        plate:SetPoint("CENTER", mock, "CENTER", 0, 0)
        local note = mock:CreateTexture(nil, "OVERLAY", nil, 2)
        note:SetSize(size, size)
        note:SetPoint("CENTER", plate, "CENTER", 0, 0)
        note:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\music_note")
        note:SetVertexColor(c.r, c.g, c.b, 1)

    end
end

-- ── ONE PICTURE TILE ──
-- A compact choice drawn as a miniature frame with the result on it, a one-line
-- label under it, and three states: normal, selected, and dimmed.
--
-- ☠ IT SETS BOTH OF ITS OWN DIMENSIONS. Everything inside is anchored to this
-- frame, and a frame given a width and no height is what made this panel draw
-- nothing at all for two days (spec section 24) -- RIGHT is (right edge,
-- vertical MIDDLE), and the middle of a zero-height frame is its top.
--
--   opts.width      the tile's width
--   opts.picHeight  the picture box's height
--   opts.label      one short line under the picture (wraps to two)
--   opts.accent     selection colour
--   opts.tooltip    a GUI:ShowTooltip spec
--   opts.Paint(pv)  paints the picture onto the CreateFramePreview thumbnail
--   opts.onClick
local TILE_PAD, TILE_PIC_H, TILE_LABEL_H = 3, 44, 22

local function CreateFrameTile(parent, opts)
    opts = opts or {}
    local W = opts.width or 82
    local picH = opts.picHeight or TILE_PIC_H
    local accent = opts.accent or GetThemeColor()

    local tile = CreateFrame("Button", nil, parent, "BackdropTemplate")
    tile:SetSize(W, TILE_PAD * 2 + picH + TILE_LABEL_H)
    GUI:StyleButton(tile, { accent = accent })
    -- Read back rather than assumed: StyleButton lands a button's height on an
    -- even number of device pixels, so the number the caller must lay out
    -- against is the one the button ended up with.
    tile.layoutHeight = tile:GetHeight()

    local pv = CreateFramePreview(tile, -TILE_PAD, nil, {
        thumb     = { w = W - TILE_PAD * 2, h = picH, x = TILE_PAD },
        placement = false,
        hideLabel = true,
    })
    tile.preview = pv
    if opts.Paint then opts.Paint(pv) end
    -- AFTER Paint, for the reason DisableMouseTree's own note gives: the effect
    -- art lands last, and it is the art sitting over the picture.
    if pv.DisableMouseTree then pv.DisableMouseTree() end

    local lbl = tile:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(lbl, 10, "")
    lbl:SetPoint("TOPLEFT", TILE_PAD, -(TILE_PAD + picH))
    lbl:SetPoint("TOPRIGHT", -TILE_PAD, -(TILE_PAD + picH))
    lbl:SetHeight(TILE_LABEL_H)
    lbl:SetJustifyH("CENTER")
    lbl:SetJustifyV("TOP")
    lbl:SetWordWrap(true)
    lbl:SetText(opts.label or "")
    lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    tile.label = lbl

    -- ☠ ORDER MATTERS BETWEEN THE TWO KIT VERBS. SetDisabled paints the dim rest
    -- backdrop and SetActive paints the accent one, each unconditionally -- so
    -- whichever runs LAST wins the fill. Disabled has to be the last word, and
    -- an enabled tile has to leave disabled first or the accent is painted over.
    tile.SetTileState = function(self, state)
        self.dfTileState = state
        if state == "disabled" then
            self:SetActive(false)
            self:SetDisabled(true)
        else
            self:SetDisabled(false)
            self:SetActive(state == "selected")
        end
        local a = (state == "disabled") and 0.35 or 1
        if pv then pv:SetAlpha(a) end
        lbl:SetAlpha(a)
    end
    tile:SetTileState("normal")

    tile:SetScript("OnClick", function(self)
        if self.dfDisabled then return end
        if opts.onClick then opts.onClick(self) end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)

    -- Hooked, not set: StyleButton owns OnEnter/OnLeave for the hover wash.
    tile.dfTooltip = opts.tooltip
    tile:HookScript("OnEnter", function(self)
        local t = self.dfTooltip
        if type(t) == "table" then GUI:ShowTooltip(self, t) end
    end)
    tile:HookScript("OnLeave", function() GUI:HideTooltip() end)

    return tile
end
P.CreateFrameTile = CreateFrameTile

-- ── THE 9-POINT ANCHOR PICKER ──
-- Which corner of the frame a placed indicator starts at. Pre-picked to the
-- type's own default, so the panel always has an answer and the section is a
-- confirmation rather than a demand.
local ANCHOR_GRID_ROWS = {
    { "TOPLEFT",    "TOP",    "TOPRIGHT"    },
    { "LEFT",       "CENTER", "RIGHT"       },
    { "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT" },
}
local ANCHOR_CELL, ANCHOR_GUTTER = 18, 2

local function CreateAnchorPicker(parent, opts)
    opts = opts or {}
    local grid = CreateFrame("Frame", nil, parent)
    local span = ANCHOR_CELL * 3 + ANCHOR_GUTTER * 2
    -- Both dimensions, for the reason CreateFrameTile spells out.
    grid:SetSize(span, span)

    local btns, current = {}, nil
    local function Paint()
        for point, b in pairs(btns) do
            b:SetActive(point == current)
        end
    end

    for row = 1, 3 do
        for col = 1, 3 do
            local point = ANCHOR_GRID_ROWS[row][col]
            local b = CreateFrame("Button", nil, grid, "BackdropTemplate")
            b:SetPoint("TOPLEFT", grid, "TOPLEFT",
                       (col - 1) * (ANCHOR_CELL + ANCHOR_GUTTER),
                       -((row - 1) * (ANCHOR_CELL + ANCHOR_GUTTER)))
            GUI:StyleButton(b, { width = ANCHOR_CELL, height = ANCHOR_CELL })
            btns[point] = b
            b:SetScript("OnClick", function(self)
                if self.dfDisabled then return end
                current = point
                Paint()
                if opts.onChanged then opts.onChanged(point) end
                PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            end)
            b:HookScript("OnEnter", function(self)
                GUI:ShowTooltip(self, { title = (OPTS.ANCHOR_OPTIONS or {})[point] or point })
            end)
            b:HookScript("OnLeave", function() GUI:HideTooltip() end)
        end
    end

    grid.Get = function() return current end
    grid.Set = function(_, point)
        current = point
        Paint()
    end
    grid.SetGridEnabled = function(_, enabled)
        for _, b in pairs(btns) do b:SetDisabled(not enabled) end
        -- SetDisabled repaints the rest backdrop, so the selection has to be
        -- re-asserted after it or re-enabling loses which cell was chosen.
        if enabled then Paint() end
    end
    grid.buttons = btns
    return grid
end

-- ── ONE NUMBERED SECTION HEADING ──
-- ⚠ A FRAME WITH THE STRINGS INSIDE IT, never bare FontStrings on the pane:
-- PopoutContent builds into a HIDDEN holder and moves FRAMES into the group, so
-- a region left on the parent stays behind and is never drawn (spec section 16).
local SECTION_HEAD_H = 16
-- Section 1's answer line: what the two source buttons above it chose.
local SOURCE_LINE_H = 18

-- ── THE FOUR THINGS A NUMBERED SECTION CAN BE, AND WHY DIM IS NOT TWO OF THEM ──
-- ☠ THIS IS NOT THE GREY-WHEN-DISABLED CONVENTION, and it must not be read as
-- it. That convention is for a CONTROL that is switched off and could be
-- switched on: grey means "turn something on to reach this". A section that
-- does not apply to the choice just made will NEVER apply to it, and dimming it
-- to illegibility hides a fact the reader needs -- it needs "this does not
-- apply, and here is why" (spec section 28).
--
-- The panel shipped with only NORMAL and DIM, and dim was carrying both "not
-- yet" and "not needed" while saying neither. "Not needed" is the COMMON case,
-- not an edge one: of the nine effects, SIX are frame-level, so for two thirds
-- of choices section 3 is moot -- and it just sat there grey, looking broken.
--
--   TODO      not yet. Answer the section above and this wakes. The ONLY state
--             that dims, because it is the only one where dim is honest.
--   ACTIVE    the section awaiting you, and the one place to look. Bright
--             caption, and the builder draws an accent outline round it.
--   ANSWERED  normal weight, no outline. It shows what you chose.
--   NA        legible, NOT dimmed to nothing: full alpha, a bright caption and
--             a quiet tag saying it is not needed. The REASON goes beside it,
--             in whatever the section keeps for that.
local SEC_TODO     = "todo"
local SEC_ACTIVE   = "active"
local SEC_ANSWERED = "answered"
local SEC_NA       = "na"
P.SectionStates = { TODO = SEC_TODO, ACTIVE = SEC_ACTIVE,
                    ANSWERED = SEC_ANSWERED, NA = SEC_NA }

-- `x` is the caller's own left gutter and defaults to none. The Add Indicator
-- panel insets every section by PANE_GUTTER so its outline has somewhere to be
-- drawn (see THE GUTTER below); the Layout Groups panels have no outline and
-- keep the pane's own left edge.
local function CreateNumberedHeading(parent, number, caption, y, width, x)
    local head = CreateFrame("Frame", nil, parent)
    head:SetSize(width, SECTION_HEAD_H)
    head:SetPoint("TOPLEFT", x or 0, y)

    local num = head:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(num, 9, "")
    num:SetPoint("LEFT", 0, 0)
    num:SetText(tostring(number))
    local tc = GetThemeColor()
    num:SetTextColor(tc.r, tc.g, tc.b)

    -- ⚠ THE TAG IS ANCHORED FIRST AND THE CAPTION IS BOUNDED BY IT. Two strings
    -- growing toward each other from opposite edges of one row is spec section
    -- 17's class 3, and a caption with a free right edge would push a long
    -- translation's tag off the row. The tag is EMPTY in every state but NA, and
    -- an empty string is zero wide, so the caption keeps effectively the whole
    -- row the rest of the time.
    local tag = head:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(tag, 9, "")
    tag:SetPoint("RIGHT", head, "RIGHT", 0, 0)
    tag:SetJustifyH("RIGHT")
    tag:SetWordWrap(false)
    tag:SetText("")
    tag:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    local cap = head:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(cap, 9, "")
    cap:SetPoint("LEFT", num, "RIGHT", 6, 0)
    cap:SetPoint("RIGHT", tag, "LEFT", -6, 0)
    cap:SetJustifyH("LEFT")
    cap:SetWordWrap(false)
    cap:SetText(caption)
    cap:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    head.caption = cap
    head.tag = tag
    -- ☠ ONE STATE VERB, NOT AN ENABLED FLAG. A boolean can only ever draw two of
    -- the four states above, and the two it collapses -- "not yet" and "not
    -- needed" -- are precisely the pair the reader has to be able to tell apart.
    head.SetHeadState = function(self, state, tagText)
        state = state or SEC_TODO
        -- Alpha is the ONE thing reserved for "not yet". Everything else stays
        -- at full opacity and says what it is with colour and words instead.
        local a = (state == SEC_TODO) and 0.4 or 1
        num:SetAlpha(a)
        cap:SetAlpha(a)
        tag:SetAlpha(a)
        -- Bright for the section you are meant to read RIGHT NOW -- the one
        -- awaiting you, and the one that has just told you it is not needed.
        if state == SEC_ACTIVE or state == SEC_NA then
            cap:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            cap:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
        -- ...and the tag is QUIETER than the caption it sits beside, not louder:
        -- "keep the heading readable" is the instruction, and a bright tag beside
        -- a dim heading inverts it.
        tag:SetText((state == SEC_NA) and (tagText or "") or "")
        self.dfHeadState = state
    end
    -- ⚠ ANSWERED IS THE CONSTRUCTION DEFAULT, and deliberately so: it is exactly
    -- what this heading has always looked like, so the Layout Groups panels
    -- (Editor.lua), which ask ONE question and never drive a state, are untouched
    -- by this verb existing. Only the add panel's Sync moves them off it.
    head:SetHeadState(SEC_ANSWERED)
    return head
end
P.CreateNumberedHeading = CreateNumberedHeading

-- ── THE ACTIVE SECTION'S OUTLINE ──
-- A ring traced round the section awaiting an answer, so "where do I look now"
-- is answerable at a glance. The DRAWING is the kit's -- CreateRoundedSurface
-- with `fill = false` is documented as exactly this, "an outline traced over
-- something that has to stay visible under it" -- so nothing new goes into
-- DandersUI. What is local is the three decisions below, and all three are about
-- THIS pane.
--
-- ☠ 1. IT TAKES NO MOUSE. A slider laid over a tile made the whole picture
-- unclickable, twice (spec section 27), and this frame covers nine tiles, two
-- buttons and a nine-cell grid at once. MakeMouseInert walks it AFTER the
-- surface exists, so anything the surface added is covered too.
--
-- ☠ 2. IT IS RAISED ABOVE THE CONTENT. A texture can never draw over a SIBLING
-- frame whose level is not lower -- draw layer loses to frame level -- and the
-- gutter (see 3) only guarantees the ring clears the controls THIS panel holds
-- today. A tenth tile, a wider button or a rounded corner reaching a pixel
-- further would put a run back under a sibling, and the failure mode is a ring
-- that silently loses a side. Re-asserted in Sync rather than only at build: a
-- popout's frame level is its slot in the stack, and anything levelled once at
-- construction falls behind the first time a second panel opens (spec section
-- 15's standing lesson).
--
-- ☠ 3. IT NEVER OVERHANGS THE PANE. Horizontally it is the pane's own width,
-- flush, and that is not a taste: PopoutRow wraps a pane taller than 60% of the
-- screen in a ScrollFrame of exactly the pane's width, which CLIPS -- and this
-- panel is over that cap already. A ring drawn 4px proud would be whole on a
-- tall screen and shaved on a short one.
--
-- ⚠ SO THE SPACE COMES FROM THE CONTENT, NOT FROM THE RING. The ring cannot
-- grow outwards, so the panel steps inwards: THE GUTTER below insets every
-- control by PANE_GUTTER, and the ring keeps the pane's full width and lands in
-- the space that frees. It shipped flush because there was no gutter to inset
-- into, and its left and right runs sat on the outer tiles' own 1px edges -- "too
-- cramped and too close to the content" (spec section 29).

-- ── THE GUTTER ──
-- ONE number, used four ways: the left inset, the right inset, and the ring's
-- pad above and below. Three sections insetting by different amounts is how a
-- page stops having one left edge, and a ring 6px clear at the sides but 3px
-- clear top and bottom is the same failure turned ninety degrees.
--
-- ⚠ AND 6 IS ARITHMETIC, NOT TASTE. The three tile columns divide the content
-- width exactly only on a MULTIPLE OF 3 (260 - 2G - 2*7 ≡ 0 mod 3 needs G ≡ 0),
-- and 6 is the smallest such inset that is actually a gutter: 3 is what the ring
-- already had above and below and is the amount that was judged cramped, and 0 is
-- what shipped. At 6 the tiles are 78 wide and 3*78 + 14 lands exactly on the
-- right gutter; at 5 they are still 78 and the row stops 2px short of it.
local PANE_GUTTER = 6
local SECTION_RING_PAD = PANE_GUTTER
-- The drop between one section's last control and the next one's heading. It has
-- to EXCEED the ring's pad, or a shown ring would reach over the heading below
-- it; PANE_GUTTER + 2 is that, derived rather than a literal tuned by hand.
--
-- ⚠ IT IS NOT "SO ADJACENT RINGS CLEAR EACH OTHER", which is what section 28
-- raised it for. Exactly one ring is ever drawn (Sync outlines the section
-- awaiting an answer and no other), so two rings overlapping is unobservable;
-- what the eye can catch is a ring crossing the NEXT SECTION'S CONTENT, and that
-- is what this number is sized against.
local SECTION_GAP = PANE_GUTTER + 2
local SECTION_RING_LIFT = 6

local function CreateSectionOutline(parent, width)
    local ring = CreateFrame("Frame", nil, parent)
    ring:SetWidth(width)
    -- Both dimensions, always. A frame with a width and no height puts its own
    -- vertical middle on its top edge, which is what drew this panel empty for
    -- two days (spec section 24).
    ring:SetHeight(1)
    local tc = GetThemeColor()
    -- ⚠ THE CURVE AND THE RING WEIGHT COME FROM THE KIT'S ONE SURFACE TOKEN, and
    -- from the same two fields a settings group's own box takes them from -- this
    -- is an inner surface inside a panel, exactly as a group box is. A hardcoded
    -- radius here is the site left behind when the token is retuned, which is the
    -- failure Theme.lua's SurfaceStyle exists to prevent.
    local style = GUI.GetSurfaceStyle and GUI:GetSurfaceStyle() or nil
    GUI:CreateRoundedSurface(ring, {
        radius      = style and style.radius or 6,
        borderWidth = style and (style.rowBorderWidth or style.borderWidth) or 1,
        fill        = false,
        border      = { tc.r, tc.g, tc.b, 1 },
    })
    MakeMouseInert(ring)
    ring:Hide()
    -- topY/bottomY are the builder's own running offsets, both negative-down from
    -- the pane's top -- so the span is the difference and the pad grows it both
    -- ways. Clamped at the pane's top for the same reason the width is: section
    -- 1 starts there, and 3px above it is 3px outside the scroll frame.
    ring.SetSpan = function(self, topY, bottomY)
        local top = min(topY + SECTION_RING_PAD, 0)
        local h = max((top - bottomY) + SECTION_RING_PAD, 1)
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", 0, top)
        self:SetHeight(h)
    end
    ring.Lift = function(self)
        local p = self:GetParent()
        local lvl = (p and p.GetFrameLevel and p:GetFrameLevel()) or 0
        self:SetFrameLevel(lvl + SECTION_RING_LIFT)
    end
    return ring
end
P.CreateSectionOutline = CreateSectionOutline

-- ⚠ A NAMED HELPER RATHER THAN A LOOP OVER A LITERAL. Sync runs on every open
-- and every tile click, and a `{ {ring, state}, ... }` written inline would
-- allocate a table and three more on each of them.
local function SetOutlineActive(ring, active)
    if active then
        -- Re-levelled on every pass, not only at build: a popout's frame level is
        -- its slot in the stack, so anything levelled once at construction falls
        -- behind the first time a second panel opens (spec section 15).
        ring:Lift()
        ring:Show()
    else
        ring:Hide()
    end
end

-- One "+ Add Indicator" panel, start to finish.
--   host        the container frame the popout row's pane holds, ALREADY sized to
--               the pane's width by the caller
--   opts.width  that width. Fixed (GUI.PopoutContentWidth), which is why the
--               wrapped note below can be measured at build: inside a pane there
--               is no later width for it to re-wrap against. It is also why this
--               panel is unaffected by the window's 520px minimum -- a popout is
--               a fixed-width panel docked OUTSIDE the window
--   opts.SetHeight(h)  report the pane's height, normally GUI:RelayoutHost
--   opts.Close()       shut the panel once something has been added
--
-- Returns the panel's own verbs: Sync (call on every open -- see the header),
-- and the four state transitions, which are the real entry points its own
-- controls use.
S.BuildAddIndicatorPane = function(host, opts)
    opts = opts or {}
    local W = opts.width or 260
    -- ☠ TWO WIDTHS, AND EVERY CONTROL BELOW USES THE SECOND ONE. G is the left
    -- edge of everything the user can see or click; CW is what is left for it.
    -- The RINGS are the one exception -- they keep W and start at 0, because the
    -- gutter is the space they are drawn IN.
    local G = PANE_GUTTER
    local CW = W - G * 2
    local tc = GetThemeColor()
    local EFFECTS = AddFlowEffects()
    local EFFECT_BY_TYPE = {}
    for _, e in ipairs(EFFECTS) do EFFECT_BY_TYPE[e.type] = e end

    -- What section 1 was answered with: { kind = "spell", auraName, display }
    -- or { kind = "filter", ref, display }. nil until it is answered.
    local source
    -- What section 2 was answered with: an effect type key.
    local selected
    -- What section 3 was answered with. Seeded from the chosen type's own
    -- default every time the type changes, so it is never empty.
    local anchor
    local Sync   -- every control asks for a re-state, so this is forward-declared

    local tiles = {}
    local sec1Head, sec2Head, sec3Head, grid, gridNote, addBtn, spellBtn, filterBtn, sourceText
    -- One outline per section and one pointer at the foot -- see THE ACTIVE
    -- SECTION'S OUTLINE and THE COMPLETION POINTER below.
    local sec1Ring, sec2Ring, sec3Ring, pointer
    -- Where each section's band starts and ends, in the same running `y` the
    -- layout below is written in. Filled as the layout walks past, so the rings
    -- cannot drift from the content: nothing here is a second copy of a number.
    local secTop, secEnd = {}, {}

    -- ── WHAT A FINISHED ADD COSTS ──
    -- The same three verbs every other add path runs.
    local function Finish()
        if opts.Close then opts.Close() end
        S.SwitchTab("effects")
        RefreshPlacedIndicators()
        RefreshPreviewEffects()
    end

    -- Is this effect already on the chosen source? Asked per tile, which is the
    -- whole reason the spell picker cannot answer it: it is a question about a
    -- TYPE, and with the flat list every type is on screen at once.
    local function AlreadyHas(typeKey)
        if not source then return false end
        if source.kind == "filter" then
            return HasFrameEffect(source.ref, typeKey)
        end
        local eff = EFFECT_BY_TYPE[typeKey]
        if eff and eff.mode == "placed" then
            return IsAuraTypePlaced(source.auraName, typeKey)
        end
        return HasFrameEffect(source.auraName, typeKey)
    end

    -- Can this effect be driven by the source at all? A filter drives the
    -- frame-level recolours and the border and nothing else.
    local function Available(typeKey)
        if not source then return false end
        if source.kind ~= "filter" then return true end
        local eff = EFFECT_BY_TYPE[typeKey]
        return (eff and eff.filterable) or false
    end

    -- ⚠ IT REFUSES UP FRONT RATHER THAN ACCEPTING AND THEN DROPPING. Sync clears
    -- a selection the source cannot carry, so a SelectType that set it anyway
    -- would report success for a choice that never survived the next line -- and
    -- the "already added" case would go silent, which is the state spell-first
    -- created and the one the old flow said out loud (spec section 19).
    local function SelectType(typeKey)
        if not EFFECT_BY_TYPE[typeKey] then return false end
        if not source then return false end
        if not Available(typeKey) then return false end
        if AlreadyHas(typeKey) then
            DF:Say(L["Already added."])
            return false
        end
        selected = typeKey
        local defs = TYPE_DEFAULTS and TYPE_DEFAULTS[typeKey] or nil
        anchor = (defs and defs.anchor) or "TOPLEFT"
        Sync()
        return true
    end

    local function PickSpell(auraName, display)
        if not auraName then return false end
        source = { kind = "spell", auraName = auraName, display = display or auraName }
        -- A type chosen against the previous source may be unavailable or
        -- already present on this one; Sync decides, and clears it if so.
        Sync()
        return true
    end

    local function PickFilter(kind, key)
        local ref = DF:MakeADFilterRef(kind, key)
        if not ref then return false end
        source = { kind = "filter", ref = ref,
                   display = DF:ADFilterRefDisplayName(ref) or ref }
        Sync()
        return true
    end

    local function Commit()
        if not (source and selected) then return false end
        if not Available(selected) then return false end
        if AlreadyHas(selected) then
            -- ⚠ SAID, NOT SILENTLY SWALLOWED. The tile is dimmed for this, so
            -- reaching here means the world moved under an open panel -- which is
            -- exactly what Sync exists for, and this is the belt to its braces.
            DF:Say(L["Already added."])
            Sync()
            return false
        end
        local eff = EFFECT_BY_TYPE[selected]
        if source.kind == "filter" then
            AddPickedSpell(source.ref, selected, "frame")
        else
            AddPickedSpell(source.auraName, selected, eff.mode,
                           (eff.mode == "placed") and anchor or nil)
        end
        Finish()
        return true
    end

    -- ⚠ A TOP MARGIN, AND IT IS LOAD-BEARING RATHER THAN COSMETIC. Section 1's
    -- outline is drawn SECTION_RING_PAD above its heading, and the ring may not
    -- leave the pane (see CreateSectionOutline's point 3) -- so the heading has
    -- to start that far down or the clamp would give section 1 a tighter box
    -- than its two siblings. It is the gutter turned through ninety degrees, and
    -- the ONLY vertical the gutter costs.
    local y = -SECTION_RING_PAD

    -- ── 1 · WHICH AURA? ──
    secTop[1] = y
    sec1Head = CreateNumberedHeading(host, 1, L["WHICH AURA?"], y, CW, G)
    y = y - (SECTION_HEAD_H + 4)

    local function OpenSpellStep()
        local isOther = IsOtherTab()
        local spec = (not isOther) and ResolveSpec() or nil
        local specInfo = spec and DF.AuraDesigner.SpecInfo[spec]
        OpenADPicker({
            title = L["Select a spell"],
            subtitle = L["Add Indicator"],
            subtitleColor = tc,
            records = function() return BuildADPickerRecords(false) end,
            classLock = (not isOther) and specInfo and specInfo.class or nil,
            -- ⚠ ONLY THE CROSS-POOL BLOCK CAN BE ANSWERED HERE. "Already added"
            -- is a question about a TYPE, and every type is a tile on the panel
            -- behind this picker -- so it is answered there, where it can be true
            -- of one tile and false of the eight beside it.
            isBlocked = ADCrossBlockText,
            rowActions = {
                {
                    label = L["Select"],
                    handler = function(rec, _, picker)
                        PickSpell(rec.auraName, rec.display or rec.auraName)
                        picker:Close()
                    end,
                },
            },
            allowAddByID = true,
            onAddByID = function(idNum, _, picker, idText)
                local auraName, display, _, blocked = ADResolveByID(idNum, idText)
                if blocked then picker:Echo(blocked) return end
                if not auraName then return end
                PickSpell(auraName, display or auraName)
                picker:Close()
                return true
            end,
        })
    end

    -- ...and the other way to answer the SAME question. See the header for why
    -- this is a second source rather than a scope.
    --
    -- ☠ IT OPENS THE FILTER LIST IN THE FULL OVERLAY, NOT A DROPDOWN. Same shell
    -- as the spell database, over the same host, and inside it a filter's own
    -- spells expand in place so you can read one before committing to it (spec
    -- section 27.2/27.3). Safe from inside a panel: the overlay covers the
    -- settings content area while the panel docks OUTSIDE the window, so the
    -- panel stays open, and an open panel's outline retargets to the overlay
    -- while it is up.
    local function OpenFilterStep()
        OpenADFilterPicker({
            title = L["Filters"],
            subtitle = L["Add Indicator"],
            subtitleColor = tc,
            -- No isLinked: every filter is offerable here. Which EFFECTS one
            -- already carries is a question about a TYPE, and the nine tiles
            -- below answer it one at a time.
            actionLabel = L["Select"],
            onPick = function(kind, key) PickFilter(kind, key) end,
        })
    end

    -- ☠ TWO PEERS, NOT A BUTTON AND A FOOTNOTE (spec section 27.2). The filter
    -- route was a 20px ghost line under a 30px primary button, which is the
    -- drawing for "and also, if you must" -- and the user read it exactly that
    -- way: "it almost looks like an afterthought". Section 1 asks ONE question
    -- and there are TWO ways to answer it, so the two answers are the same size,
    -- the same weight and on the same line. Neither is the default.
    --
    -- ⚠ AND THE ANSWER MOVES OFF THE BUTTON. The spell button used to double as
    -- the display for whatever had been chosen, which is what forced it
    -- full-width; at half a pane it would truncate the very name it exists to
    -- confirm. It goes on its own line below, where both routes can write to it.
    --
    -- ☠ fitText = false ON BOTH, AND THIS IS THE HALF THAT IS NOT COSMETIC. A
    -- declared width is a MINIMUM to StyleButton: it measures the rendered label
    -- and GROWS the button rather than let a long translation clip. That is the
    -- right default for a button standing on its own, and exactly wrong for two
    -- pinned side by side -- the German label would push the left one under the
    -- right one, and the right one is pinned by offset so it would not move. The
    -- kit documents this opt-out for precisely this case: where equal widths are
    -- the point, clipping one is better than moving both.
    local SRC_GAP = 7
    local SRC_W = floor((CW - SRC_GAP) / 2)

    spellBtn = CreateFrame("Button", nil, host, "BackdropTemplate")
    spellBtn:SetPoint("TOPLEFT", G, y)
    GUI:StyleButton(spellBtn, {
        width = SRC_W, height = 30, primary = true, align = "left", fitText = false,
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\search", size = 14 },
        text = L["Select a spell"], font = "DFFontHighlight",
    })
    spellBtn:SetScript("OnClick", OpenSpellStep)

    filterBtn = CreateFrame("Button", nil, host, "BackdropTemplate")
    filterBtn:SetPoint("TOPLEFT", G + SRC_W + SRC_GAP, y)
    GUI:StyleButton(filterBtn, {
        width = CW - SRC_W - SRC_GAP, height = 30, primary = true, align = "left",
        fitText = false,
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\filter_list", size = 14 },
        text = L["Select a filter"], font = "DFFontHighlight",
    })
    filterBtn:SetScript("OnClick", OpenFilterStep)
    y = y - 34

    -- ⚠ INSIDE A FRAME, not a bare FontString on the pane. PopoutContent builds
    -- into a hidden holder and moves FRAMES; a region left on the parent stays
    -- behind and is never drawn (spec section 16).
    local srcBox = CreateFrame("Frame", nil, host)
    srcBox:SetSize(CW, SOURCE_LINE_H)
    srcBox:SetPoint("TOPLEFT", G, y)
    sourceText = srcBox:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(sourceText, 10, "")
    sourceText:SetPoint("LEFT", 0, 0)
    sourceText:SetPoint("RIGHT", 0, 0)
    sourceText:SetJustifyH("LEFT")
    sourceText:SetWordWrap(false)
    secEnd[1] = y - SOURCE_LINE_H
    y = y - (SOURCE_LINE_H + SECTION_GAP)

    -- ── 2 · HOW SHOULD IT SHOW? ──
    secTop[2] = y
    sec2Head = CreateNumberedHeading(host, 2, L["HOW SHOULD IT SHOW?"], y, CW, G)
    y = y - (SECTION_HEAD_H + 4)

    local TILE_COLS, TILE_GAP = 3, 7
    local TILE_W = floor((CW - TILE_GAP * (TILE_COLS - 1)) / TILE_COLS)
    local rowTop, rowH = y, 0
    for i, eff in ipairs(EFFECTS) do
        local col = (i - 1) % TILE_COLS
        local capturedType = eff.type
        local tile = CreateFrameTile(host, {
            width = TILE_W,
            label = eff.label,
            accent = BADGE_COLORS[eff.type] or tc,
            tooltip = { title = eff.label, lines = { eff.desc } },
            Paint = function(pv) PaintEffectOnThumb(pv, capturedType) end,
            onClick = function() SelectType(capturedType) end,
        })
        tile:SetPoint("TOPLEFT", G + col * (TILE_W + TILE_GAP), rowTop)
        rowH = max(rowH, tile.layoutHeight or 72)
        tiles[eff.type] = tile
        if col == TILE_COLS - 1 or i == #EFFECTS then
            rowTop = rowTop - (rowH + TILE_GAP)
            rowH = 0
        end
    end
    -- The last row's trailing gap is not spent.
    secEnd[2] = rowTop + TILE_GAP
    -- ⚠ THE SAME DROP AS SECTION 1'S, not the 10 it used to be. Two different
    -- gaps between three sections is the same defect as two different left edges.
    y = rowTop + TILE_GAP - SECTION_GAP

    -- ── 3 · WHERE? ──
    secTop[3] = y
    sec3Head = CreateNumberedHeading(host, 3, L["WHERE?"], y, CW, G)
    y = y - (SECTION_HEAD_H + 4)

    -- ☠ THE PICKER'S ANSWER IS TAKEN, NOT JUST NOTED. Sync re-asserts the
    -- grid's selection from `anchor` on every pass, so a handler that dropped
    -- the point would put the cell straight back where it was and the user
    -- would watch their click undo itself.
    grid = CreateAnchorPicker(host, { onChanged = function(point)
        anchor = point
        Sync()
    end })
    grid:SetPoint("TOPLEFT", G, y)

    -- ⚠ INSIDE A FRAME, not a bare FontString on the pane -- see
    -- CreateNumberedHeading. It also has to be hideable with its own state.
    local noteBox = CreateFrame("Frame", nil, host)
    noteBox:SetSize(CW - (ANCHOR_CELL * 3 + ANCHOR_GUTTER * 2) - 10,
                    ANCHOR_CELL * 3 + ANCHOR_GUTTER * 2)
    noteBox:SetPoint("TOPLEFT", G + ANCHOR_CELL * 3 + ANCHOR_GUTTER * 2 + 10, y)
    gridNote = noteBox:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(gridNote, 10, "")
    gridNote:SetPoint("TOPLEFT", 0, 0)
    gridNote:SetPoint("TOPRIGHT", 0, 0)
    gridNote:SetJustifyH("LEFT")
    gridNote:SetWordWrap(true)
    gridNote:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    secEnd[3] = y - (ANCHOR_CELL * 3 + ANCHOR_GUTTER * 2)
    -- The pointer below is not a section, but section 3's ring still has to clear
    -- it, so it is dropped by the same amount for the same reason.
    y = y - (ANCHOR_CELL * 3 + ANCHOR_GUTTER * 2 + SECTION_GAP)

    -- ── THE COMPLETION POINTER ──
    -- ☠ IT IS NOT THE "NOT NEEDED" CASE'S DECORATION. Section 28 asks for an
    -- arrow toward the commit wherever the form is ANSWERABLE -- and a placed
    -- effect whose anchor arrived pre-picked is just as finished as a recolour
    -- that never had one. So this is driven by "is there anything left to
    -- answer", not by whether section 3 applies.
    --
    -- ⚠ A RESERVED SLOT, SHOWN AND HIDDEN RATHER THAN GROWN. The pane is pooled
    -- and reports its height ONCE; a pointer that added its own height would
    -- have to re-report through a chain the builder has already finished with.
    -- Spent whether or not it is drawn -- which is why it is sized to the one
    -- 10pt line it holds rather than to the 16 it was, part of paying for the
    -- gutter's own vertical (spec section 29).
    local POINTER_H = 14
    pointer = CreateFrame("Frame", nil, host)
    pointer:SetSize(CW, POINTER_H)
    pointer:SetPoint("TOPLEFT", G, y)
    local ptrText = pointer:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(ptrText, 10, "")
    ptrText:SetPoint("CENTER", pointer, "CENTER", -9, 0)
    ptrText:SetJustifyH("CENTER")
    ptrText:SetWordWrap(false)
    ptrText:SetText(L["Ready to add"])
    ptrText:SetTextColor(tc.r, tc.g, tc.b)
    -- The arrow itself, pointing DOWN at the button on the next line. A texture,
    -- not a glyph button: nothing here is clickable, and the button below is what
    -- the whole row exists to send you to.
    local ptrArrow = pointer:CreateTexture(nil, "OVERLAY")
    ptrArrow:SetSize(12, 12)
    ptrArrow:SetPoint("LEFT", ptrText, "RIGHT", 4, 0)
    ptrArrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
    ptrArrow:SetVertexColor(tc.r, tc.g, tc.b, 1)
    MakeMouseInert(pointer)
    pointer:Hide()
    y = y - (POINTER_H + 2)

    -- ── ONE PRIMARY BUTTON ──
    addBtn = CreateFrame("Button", nil, host, "BackdropTemplate")
    addBtn:SetPoint("TOPLEFT", G, y)
    addBtn:SetPoint("TOPRIGHT", -G, y)
    GUI:StyleButton(addBtn, {
        height = 30, primary = true,
        text = L["Add to my frames"], font = "DFFontHighlight",
    })
    addBtn:SetScript("OnClick", function(self)
        if self.dfDisabled then return end
        Commit()
    end)
    y = y - 32

    -- ── THE OUTLINES, BUILT LAST ──
    -- ⚠ AFTER EVERY CONTROL, and nothing is anchored TO them. They are pure
    -- decoration laid over the sections, so building them last means they are
    -- created after the frames they cover -- and their span is read from the
    -- offsets the layout above recorded as it went, never re-derived.
    --
    -- ☠ W AND NOT CW, and that is the whole point of the gutter. The ring takes
    -- the pane's full width -- the most it can have without being clipped -- while
    -- every control above stopped G short of both edges, so the G between them is
    -- the space the ring was missing.
    sec1Ring = CreateSectionOutline(host, W)
    sec1Ring:SetSpan(secTop[1], secEnd[1])
    sec2Ring = CreateSectionOutline(host, W)
    sec2Ring:SetSpan(secTop[2], secEnd[2])
    sec3Ring = CreateSectionOutline(host, W)
    sec3Ring:SetSpan(secTop[3], secEnd[3])

    local paneH = max(-y + 2, 1)

    -- ── THE ONE RE-STATE ──
    -- ☠ EVERY LIVE READ IN THIS PANEL HAPPENS HERE, not in the builder. The panel
    -- is pooled and its build runs once, so "already added", the pool, the spec
    -- and the source's own display name are all things that can move underneath
    -- an open panel. Called by every transition above AND by the opener on every
    -- open (AuraDesigner/UI/Rows.lua).
    Sync = function()
        -- A type that the current source cannot drive, or already has, is not a
        -- selection any more.
        if selected and (not Available(selected) or AlreadyHas(selected)) then
            selected = nil
        end

        -- ☠ THE ANSWER, AND WHICH ROUTE GAVE IT. The two buttons keep their own
        -- labels -- they are the question, and a question that renames itself to
        -- its own answer stops being offerable -- so the chosen source is written
        -- on the line below them, and the route that produced it carries the
        -- selection. Neither is dimmed: picking a filter must not make the spell
        -- route look unavailable, because changing your mind is one click.
        if source then
            sourceText:SetText(source.display or "")
            sourceText:SetTextColor(tc.r, tc.g, tc.b)
        else
            sourceText:SetText(L["Choose an aura first."])
            sourceText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
        spellBtn:SetActive(source ~= nil and source.kind == "spell")
        filterBtn:SetActive(source ~= nil and source.kind == "filter")
        -- The spell's own artwork, on the tile that is about the spell's own
        -- artwork. Filters have no single icon; the shared filter glyph stands in.
        local iconTile = tiles.icon
        local iconTex = iconTile and iconTile.preview and iconTile.preview.spellIcon
        if iconTex then
            if source and source.kind == "spell" then
                iconTex:SetTexture(GetAuraIcon(ResolveSpec(), source.auraName)
                                   or DEFAULT_TILE_ICON)
            else
                iconTex:SetTexture(DEFAULT_TILE_ICON)
            end
        end

        for _, eff in ipairs(EFFECTS) do
            local tile = tiles[eff.type]
            if tile then
                local state = "normal"
                if not source or not Available(eff.type) or AlreadyHas(eff.type) then
                    state = "disabled"
                elseif selected == eff.type then
                    state = "selected"
                end
                tile:SetTileState(state)
                -- ☠ THE TOOLTIP IS WHERE A DIM TILE EXPLAINS ITSELF. A greyed
                -- control with no reason given is the one people read as broken.
                local lines = { eff.desc }
                if not source then
                    lines = { eff.desc, L["Choose an aura first."] }
                elseif not Available(eff.type) then
                    lines = { eff.desc, L["A filter cannot drive this effect."] }
                elseif AlreadyHas(eff.type) then
                    lines = { eff.desc, L["Already added."] }
                end
                tile.dfTooltip = { title = eff.label, lines = lines }
            end
        end

        local pick = selected and EFFECT_BY_TYPE[selected] or nil
        local placedPick = (pick and pick.mode == "placed") and true or false

        -- ── THE THREE STATES, DERIVED IN ONE PLACE ──
        -- ☠ SECTION 3 IS "NOT APPLICABLE", NOT "NOT YET", THE MOMENT A
        -- FRAME-LEVEL EFFECT IS CHOSEN -- and six of the nine effects are
        -- frame-level, so this is the ordinary case rather than a corner of it.
        -- A recolour has no position and never will have one; dimming section 3
        -- to illegibility for it hides that fact instead of stating it.
        local sec3NA = (pick ~= nil) and not placedPick
        -- ⚠ SECTION 3 IS NEVER ACTIVE, and that is deliberate rather than an
        -- oversight. `anchor` is seeded from TYPE_DEFAULTS every time the type
        -- changes and CreateAnchorPicker cannot clear it, so a placed effect
        -- reaches section 3 ALREADY ANSWERED -- outlining it merely because it
        -- is last would send the reader to a question nobody asked.
        local s1 = source and SEC_ANSWERED or SEC_ACTIVE
        local s2 = (not source) and SEC_TODO
                   or (selected and SEC_ANSWERED or SEC_ACTIVE)
        local s3 = sec3NA and SEC_NA
                   or (placedPick and SEC_ANSWERED or SEC_TODO)
        sec1Head:SetHeadState(s1)
        sec2Head:SetHeadState(s2)
        sec3Head:SetHeadState(s3, L["Not needed"])

        -- Exactly one outline at a time, and only ever on the section awaiting an
        -- answer.
        SetOutlineActive(sec1Ring, s1 == SEC_ACTIVE)
        SetOutlineActive(sec2Ring, s2 == SEC_ACTIVE)
        SetOutlineActive(sec3Ring, s3 == SEC_ACTIVE)

        -- ☠ SELECTION FIRST, THEN THE GATE. Both kit verbs repaint the rest
        -- backdrop unconditionally, so whichever runs last wins: greying and then
        -- re-asserting the selection would paint the accent back over the dim.
        grid:Set(placedPick and anchor or nil)
        grid:SetGridEnabled(placedPick and true or false)
        if placedPick then
            gridNote:SetText((OPTS.ANCHOR_OPTIONS or {})[anchor] or anchor or "")
        else
            gridNote:SetText(selected and L["This effect changes the whole frame."]
                                       or L["Pick a look above."])
        end
        -- ...and the REASON is the one line that must stay readable when the
        -- section does not apply. Full text colour there, the usual secondary
        -- grey everywhere else.
        if sec3NA then
            gridNote:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            gridNote:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end

        local ready = (source and selected) and true or false
        addBtn:SetDisabled(not ready)
        -- The panel saying the form is finished. Shown for a pre-picked placed
        -- effect exactly as for a recolour -- both are answerable.
        if ready then pointer:Show() else pointer:Hide() end
    end

    Sync()
    host:SetHeight(paneH)
    if opts.SetHeight then opts.SetHeight(paneH) end

    return {
        Sync = Sync, PickSpell = PickSpell, PickFilter = PickFilter,
        SelectType = SelectType, Commit = Commit,
    }
end

-- ============================================================
-- THE FILTER CHIPS -- WHICH EFFECT TYPE THE LIST IS SHOWING
-- ------------------------------------------------------------
-- ONE definition, two hosts: a wrapping row inside the split panel's column,
-- and the pane behind the popout layout's `Showing` row (AuraDesigner/UI/Rows.lua).
-- The chips predate the all-rows rule they break -- a setting with more than one
-- option goes in a popout -- and in a panel they also stop being a flow with
-- nothing to flow against: the pane's width is the popout's own content width,
-- known before a single chip is placed.
--
-- ⚠ A FUNCTION, NOT A FILE-SCOPE TABLE. Every label is an L[...] lookup, and a
-- table built at load freezes whatever locale was live then -- the trap
-- DF:RegisterLocaleRefresh exists for. Rebuilt per call, which is once per build
-- of the surface that shows them.
local function FilterChips()
    return {
        { key = "all",         label = L["All"]    },
        { key = "icon",        label = L["Icon"]   },
        { key = "square",      label = L["Square"] },
        { key = "bar",         label = L["Bar"]    },
        { key = "border",      label = L["Border"] },
        { key = "healthbar",   label = L["Health"] },
        { key = "nametext",    label = L["Name"]   },
        { key = "healthtext",  label = L["HP"]     },
    }
end
P.FilterChips = FilterChips

-- What the filter glyph writes beside itself when a filter is on. Read off the
-- SAME list the chips are built from, so a chip added there cannot summarise as
-- its own raw key here.
local function ActiveFilterLabel()
    local active = S.activeFilter or "all"
    for _, chip in ipairs(FilterChips()) do
        if chip.key == active then return chip.label end
    end
    return L["All"]
end
P.ActiveFilterLabel = ActiveFilterLabel

local CHIP_H, CHIP_GAP, CHIP_ROW_GAP = 22, 4, 4

-- Flow the chips into `host` and size it to what they took. `width` is the
-- column they wrap against, passed IN rather than measured off the host: at
-- build time the host's own width is a number the layout pass has not reached
-- yet, and reading it is what made the chips flow at a hardcoded 260.
--
-- Returns the re-flow verb, for a host whose width can still move -- the split
-- panel's column does, a pane's does not.
S.BuildFilterChips = function(host, width)
    local chipBtns = {}
    for _, chip in ipairs(FilterChips()) do
        local chipBtn = CreateFrame("Button", nil, host, "BackdropTemplate")
        chipBtn:SetHeight(CHIP_H)

        local chipTxt = chipBtn:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(chipTxt, 10, "OUTLINE")
        chipTxt:SetPoint("CENTER", 0, 0)
        chipTxt:SetText(chip.label)
        chipTxt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

        local tw = chipTxt:GetStringWidth()
        chipBtn:SetWidth(max(tw + 16, 32))

        -- Shared styling: standard hover + an active (selected) state marked by a
        -- prominent accent border. The surface rebuilds on click, so set active here.
        GUI:StyleButton(chipBtn)
        chipBtn.dfChipKey = chip.key
        chipBtn:SetActive((S.activeFilter or "all") == chip.key)

        local capturedKey = chip.key
        chipBtn:SetScript("OnClick", function()
            S.activeFilter = capturedKey
            -- ⚠ THE FULL REDRAW, NOT ADStructuralRedraw, even from inside an open
            -- pane. Which effects are listed is what just changed, and that is the
            -- PAGE's business rather than the pane's -- so the panel falling shut
            -- behind the answer is the right shape here, the same way a dropdown
            -- closes on the option you picked.
            S.SwitchTab("effects")
        end)

        tinsert(chipBtns, chipBtn)
    end

    local function LayoutChips(w)
        local maxW = tonumber(w) or host:GetWidth() or 0
        if maxW < 20 then maxW = width or 260 end
        local cx, cy = 0, 0
        for _, btn in ipairs(chipBtns) do
            local bw = btn:GetWidth()
            if cx > 0 and (cx + bw) > maxW then
                cx = 0
                cy = cy - (CHIP_H + CHIP_ROW_GAP)
            end
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", host, "TOPLEFT", cx, cy)
            cx = cx + bw + CHIP_GAP
        end
        host:SetHeight(max(-cy + CHIP_H, CHIP_H))
    end
    LayoutChips(width)
    -- ☠ A SECOND RETURN: RE-SYNC, BECAUSE THE PANEL IS POOLED AND THIS RUNS ONCE.
    -- The filter popout is created with a key, so reopening REUSES it and never
    -- re-runs this builder -- the chips kept whatever was active the FIRST time it
    -- was opened, which read as "All is always selected" however the list was
    -- actually filtered. The opener calls this on every open.
    --
    -- ⚠ SECOND, not instead: the card layout's caller wants LayoutChips (it
    -- re-flows the row on resize) and must keep getting it as the first value.
    local function SyncActive()
        local active = S.activeFilter or "all"
        for k = 1, #chipBtns do
            local b = chipBtns[k]
            if b and b.SetActive then b:SetActive(b.dfChipKey == active) end
        end
    end
    return LayoutChips, SyncActive
end

-- ── THE FILTER GLYPH'S PANEL ──
-- ☠ A FREE-STANDING POPOUT, NOT A ROW'S PANE. The eight chips were a `Showing`
-- popout row for one release and that is 50px of page (a 44px plate plus its 6px
-- gap) spent on ONE filter -- more than the 22px chip row it replaced, which is
-- where the honest chrome total went UP rather than down. Behind a glyph on the
-- caption the page pays nothing for it at all.
--
-- Built exactly the way the canvas's Preview Scale glyph builds its panel
-- (CreateFramePreview's `compact` arm): GUI:CreatePopout keyed once so the panel
-- is POOLED, then Follow'd to the button. The kit owns the stacking, so nothing
-- here has to know about _ApplyStackLevel.
local FILTER_POPOUT_KEY = "df.filter.auradesigner"
local FILTER_ICON = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\filter_list"

local function OpenFilterPopout(btn)
    -- Second click on the glyph shuts it, like any toggle.
    local open = S.filterPopout
    if open and not open.closed and open:IsShown() then
        open:Close("api")
        return
    end
    local width = GUI.PopoutContentWidth or 260
    local pop = GUI:CreatePopout({
        key   = FILTER_POPOUT_KEY,
        title = L["Showing"],
        icon  = FILTER_ICON,
        width = width,
        build = function(po, content)
            local pane = CreateFrame("Frame", nil, content)
            pane:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
            pane:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
            -- ⚠ THE FLOW IS TOLD ITS WIDTH, not asked for it. Two horizontal
            -- anchors own the pane's width, and at build time that number has not
            -- resolved -- reading it off the pane is the mistake that made the
            -- chips wrap at a hardcoded 260 on the page.
            local _, SyncActive = S.BuildFilterChips(pane, width)
            po.dfSyncChips = SyncActive
            -- The shell derives the panel's height from what build mounted
            -- (Popout:_Resize), so the content strip states its own.
            content:SetHeight(max(pane:GetHeight() or CHIP_H, CHIP_H))
        end,
    })
    pop:Follow(btn, { outsideOf = DF.GUIFrame })
    -- After Follow, and on EVERY open: a pooled panel builds once, so this is
    -- the only thing that makes the ticked chip match the live filter.
    if pop.dfSyncChips then pop.dfSyncChips() end
    S.filterPopout = pop
end
P.OpenFilterPopout = OpenFilterPopout

-- ============================================================
-- POWER INFUSION HELPER -- THE SHARED PANEL (priest only)
-- ------------------------------------------------------------
-- Extracted from the classic Effects head area below so the popout row page can
-- mount the SAME panel inside a popout pane (AuraDesigner/UI/Rows.lua) --
-- the S.BuildAddIndicatorPane pattern. Everything below writes through the
-- layout-agnostic P.PIH_* verbs and asks for a redraw through opts.Refresh,
-- which each layout supplies: the split panel rebuilds its Effects tab, the
-- row page rebuilds itself. Nothing in here may name a tab panel directly.
--   opts.startY  -- the y cursor to build from (negative, parent-relative)
--   opts.Refresh -- "the data moved, redraw this layout's Effects surface"
-- Returns the final y cursor, so the classic arm carries on below the panel
-- and the pane arm sizes its pane from it.
--
-- ⚠ A SEPARATE BLOCK, not a fourth card in the one above. Those three answer "what shape
-- of indicator do you want" and then ask which spell; this one asks nothing and builds a
-- whole configured feature. Putting it beside them would imply it belongs to the same
-- question, and a card that behaves differently from its neighbours is a lying control.
--
-- ☠ The card becomes REMOVE once a helper exists on this preset, so there is one place to
-- look for both. Create and remove are the same feature seen from either side.
-- ⚠ SPLIT INTO PARTS 2026-09-01, ONE DEFINITION STILL. It was split because the popout
-- layout's pane outgrew its page and needed the bodies one row at a time, so the builder
-- became: the CARD on its own (S.BuildPIHelperCard), a shared section toolkit
-- (pihMakeTools), and one body function per section.
-- ⚠ THAT SECOND CONSUMER IS GONE (2026-09-08) -- the helper has its own page and the row
-- band went with the move, taking S.PIHelperSections with it. The split is KEPT anyway: one
-- body per section is what lets the page compose them in a different ORDER (Triggers before
-- Indicators) without touching a single control.
-- ── THE ONE-TIME SWEEP ──────────────────────────────────────────────────────────────
-- The two-signal shape retired "Big cooldown with a trinket or potion" and moved racials
-- out of the cooldown list. Neither change reaches a helper that already exists: its
-- effects and its spell lists are the user's data, written once and never re-seeded.
--
-- ☠ WHAT GOES WRONG WITHOUT THIS is not a crash but a set of LYING CONTROLS. A
-- retired signal's effect keeps rendering with no row that can turn it off; racials keep
-- lighting the border while the new "Include racials" tick reads as off, because the tick
-- reads the amplifier list and the racials are in the other one; and the infused icon group
-- keeps drawing with no tick left to represent it.
--
-- ⚠ STAMPED, NOT INFERRED. There is no way to tell "already swept" from "the user
-- deliberately put a racial back", so a version stamp decides rather than a heuristic --
-- otherwise the sweep would undo a hand edit on every login.
-- 3: Square retired, migrated to Border. RETRACTED the same afternoon and never shipped --
--    see the note on step 4. The number is burned rather than reused, so a client that ran
--    it is not told it is on a schema it never saw.
-- 4: Icon retired as a helper surface, migrated to Square (step 4 in pihSweep).
-- 5: The cooldown-icon GROUP retired outright, and the amplifier list folded into the one
--    cooldown list the helper matches on (steps 5 and 6). Icon comes BACK as a surface at the
--    same time -- pinned to Power Infusion's own artwork, which is what schema 4's objection
--    was actually about -- but nothing needs migrating for that: schema 4 already turned every
--    existing Icon into a Square, and a square is a perfectly good marker to leave someone on.
-- 6: ☠ SCHEMA 5 STAMPED ITSELF AND DELETED NOTHING. Its group delete searched one store by
--    id; Krathe's eight groups are in another (see pihPurgeStrayMarks). So the stamp says
--    "swept" on profiles that were not, and the version has to move for the fixed step to get
--    a second chance at them. A number is cheap; a stamp that lies is not.
-- 7: Stack Count retired on helper markers. showStacks defaults TRUE for icons and
--    squares, so every helper marker ever created is drawing a count read off whichever
--    cooldown matched -- on an icon whose art is pinned to Power Infusion. New ones are
--    stamped false at creation; step 7 does the ones already out there.
-- 8: ☠ THE CURATED MARK NEVER LANDED ON AN EXISTING PROFILE. dfDefaults is what makes
--    the Filter Designer give our list the on/off tick and the Reset button, and it is
--    stamped by pihEnsureFilter -- which only RUNS when the helper creates or repairs a
--    signal. A helper that already exists and is not being edited never calls it, so
--    Krathe's list still showed the destructive ✕ and no Reset. Shipped and reported in
--    one round: "the seeded list does not have the same toggle on/off as other filters
--    and it does not have a reset option?"
--    ⚠ THE LESSON: a mark written by a CREATE path reaches nobody who already has the
--    thing. Stamping in the sweep is what reaches them, and the sweep is the one place
--    that runs for a helper nobody is touching.
local PIH_SCHEMA = 12

local function pihSweep()
    local s = P.PIH_Settings()
    if not s then return end
    -- ☠☠ THE STEPS ARE GATED ON WHERE THE PROFILE IS COMING FROM, NOT ONLY ON WHETHER IT HAS
    -- ARRIVED. Every step used to run whenever the stamp differed, which was harmless while
    -- the stamp only ever moved forward by one -- and became destructive the moment it moved
    -- for a reason unrelated to a given step.
    -- ⚠ THE CONCRETE HAZARD, AND IT WOULD HAVE HIT KRATHE FIRST: step 4 migrates every marked
    -- Icon to a Square. Icon is a legitimate surface again in schema 5, so re-running step 4
    -- on the way to 6 would convert an icon the user had just added through the new tiles --
    -- silently, on the next page build, as a side effect of a migration about something else.
    -- ⇒ `from` is the version the profile is actually on, and each step names the version it
    -- was written for. [[feedback-migration-before-defaults-backfill]] is the sibling trap.
    local from = tonumber(s.schema) or 0
    if from == PIH_SCHEMA then return end

    -- ☠☠ THE POOL IS PINNED FOR THE WHOLE SWEEP, AND SKIPPING THIS SHIPPED A BROKEN SWEEP.
    -- Several editor helpers this function reaches resolve their STORE from S.activeBuffTab:
    -- EnsureAuraConfig (step 4's Icon -> Square migration writes through it) and the shared
    -- layout-group delete both do. That was invisible while the only caller was the helper's
    -- own panel, which by definition ran on an other-routed tab -- and became wrong the moment
    -- the sweep moved to page-build time, where the pool is still whatever the last session
    -- left, usually My Buffs. Step 5's delete then searched the SPEC store for a group that
    -- lives in the OTHER one, removed nothing, and said nothing about it.
    -- ⚠ THIS IS NOT A LIE TOLD TO A SHARED HELPER. The helper's records genuinely live in the
    -- Any Buff pool -- that is the constraint the whole feature is built around -- so pointing
    -- the pool accessor at it while we work on them is telling it the truth.
    -- ⚠ RESTORED UNCONDITIONALLY. Nothing between here and the restore can error out (no
    -- pcall, no early return below this line), and a sweep that left the pool moved would hand
    -- the page it was called from somebody else's records.
    local prevPool = S.activeBuffTab
    S.activeBuffTab = "other"

    local R = DF.FilterRegistry
    local pool = pihOtherPoolRead()

    -- ── STEPS 1-4: ONLY FOR A PROFILE COMING FROM BEFORE SCHEMA 4 ──
    -- ⚠ STEP 4 IS THE ONE THAT MAKES THIS MANDATORY: it turns every marked Icon into a
    -- Square, and Icon is a supported surface again as of schema 5. Re-running it on the way
    -- to 6 would convert an icon the user had just added through the new tiles, silently, on
    -- the next page build, as a side effect of a migration about something else entirely.
    if from < 4 then
    -- 1. The retired signal, in both its representations.
    if type(pool) == "table" then
        for auraName, auraCfg in pairs(pool) do
            if type(auraCfg) == "table" then
                for _, typeKey in ipairs(P.FRAME_LEVEL_TYPE_KEYS or {}) do
                    local cfg = auraCfg[typeKey]
                    if type(cfg) == "table" and cfg.pihSignal == "strong" then
                        auraCfg[typeKey] = nil
                    end
                end
                for i = #(auraCfg.indicators or {}), 1, -1 do
                    local inst = auraCfg.indicators[i]
                    if type(inst) == "table" and inst.pihSignal == "strong" then
                        table.remove(auraCfg.indicators, i)
                    end
                end
            end
            -- Unused now; the pool key would otherwise sit there empty.
            if type(auraCfg) == "table" and not next(auraCfg) then pool[auraName] = nil end
        end
    end

    -- 2. Racials become an amplifier. Taken out of the cooldown list either way -- they are
    -- not a burst window on their own any more -- and put into the amplifier list only if
    -- the user still had them, so an explicit untick is not silently reversed.
    if R then
        local cdId = pihFilterIdByName(PIH_FILTERS.cooldowns)
        local f = cdId and R.GetCustomFilter and R:GetCustomFilter(cdId)
        local had = false
        if f then
            for _, sid in ipairs(PIH_RACIAL_IDS) do
                if f.spells[sid] or f.rawIDs[sid] then had = true end
                if R.RemoveSpellFromCustom then R:RemoveSpellFromCustom(cdId, sid) end
            end
        end
        -- ⚠ THE SETTING ONLY. Step 6 below is what puts the ids back where they belong now,
        -- and it runs for every ticked amplifier rather than for racials alone -- so doing it
        -- here as well would be two writers of one fact in the same function.
        if had then s.racials = true end
    end

    -- 3. ☠ THE INFUSED ICON GROUP'S OWN STEP IS GONE, FOLDED INTO STEP 5. It read
    -- pihIconGroup("infused") and handed the id to the store-routed delete -- one store, one
    -- id, the exact shape that failed three times on the cooldown group. Step 5 takes every
    -- marked group in every store, which is a superset of what this did and cannot miss for
    -- the reason this did.

    -- 4. ICON IS RETIRED AS A HELPER SURFACE (schema 4, 2026-09-08).
    -- ☠ THE REASON IS SCOPE, NOT SHAPE. An icon shows a SPECIFIC BUFF'S artwork, so
    -- offering one implies the helper tracks which cooldown each player popped. It does
    -- not, and does not need to -- Krathe: "we don't need to track each buff just the fact
    -- someone has popped a CD and we highlight in some form." A control that promises
    -- per-buff detail the feature never delivers is a control that lies about its scope.
    --
    -- ⚠☠ SCHEMA 3 WENT THE OTHER WAY AND IS DELIBERATELY NOT PRESERVED. It retired SQUARE
    -- and migrated it to Border, on the argument that a block at a coordinate is a
    -- placement and placement is the designer's job. That was shape reasoning; this is
    -- scope reasoning, and scope won. Schema 3 shipped nowhere -- it existed for part of one
    -- afternoon on one developer's client -- so nothing in the wild ran it, and reviving its
    -- inverse would mean tracking which of two contradictory migrations a profile had seen.
    -- A profile that DID run it has borders where it had squares; that is a colour on a
    -- different surface, not lost work, and it is not worth a third migration to undo.
    --
    -- ⚠ MIGRATED, NOT DELETED. Someone running an Icon helper would otherwise open the
    -- panel to a signal reading "None" with no explanation -- indistinguishable from their
    -- settings having been lost. Square is the nearest honest equivalent: it marks the same
    -- unit in the same place, and it is what the surface list offers now.
    if type(pool) == "table" then
        for auraName, auraCfg in pairs(pool) do
            if type(auraCfg) == "table" then
                for i = #(auraCfg.indicators or {}), 1, -1 do
                    local inst = auraCfg.indicators[i]
                    if type(inst) == "table" and inst.pihSignal and inst.type == "icon" then
                        local sig = inst.pihSignal
                        -- Captured BEFORE the removal, the same order pihSwap works in:
                        -- placing reads the carry and the instance is gone by then.
                        -- An Icon carries no colour of its own, so the square falls back to
                        -- the signal's default -- which is what pihPlace does with nil.
                        local carried = { conditions = inst.conditions }
                        table.remove(auraCfg.indicators, i)
                        pihPlace(sig, auraName, "square", carried)
                    end
                end
            end
        end
    end

    -- 5. ☠☠ THE COOLDOWN-ICON GROUP GOES, AND THIS IS THE STEP KRATHE REPORTED.
    -- "I have stuck PI Helper Cooldown - Icons on my AD despite that not even being an option
    -- now for PI helper" (2026-09-09) -- a Filter Group of live cooldown icons, drawn on every
    -- frame and on the designer's own preview, whose only control was a tick that has since
    -- been moved, renamed and finally removed. A control that is gone cannot turn its own
    -- output off, so the output has to be taken away with it.
    -- ⚠ EVERY pihSignal GROUP, not the one named "burst". A shipped build could leave an
    -- "infused" one behind too (step 3 only ever ran for a profile that reached schema 4),
    -- and the point of this step is that nothing marked as ours survives it.
    -- ⚠ THROUGH DeleteLayoutGroup, which also sweeps the expanded-card key -- a raw table
    -- remove would leave the editor holding a fold state for a group that no longer exists.
    -- ⚠ AND THE STASH GOES. pihRestoreGroup would otherwise lay a deleted group's position
    -- and appearance back over the next one created -- and after this step there is no next
    -- one, so the stash is a copy of something with nowhere left to go.
    end   -- from < 4

    -- ── STEPS 5-6: EVERY PROFILE THAT IS NOT ALREADY ON THE CURRENT SCHEMA ──
    -- Both are safe to re-run: one removes records that should not exist, the other writes a
    -- set of ids that is derived from the ticks rather than added to them.

    -- ⚠ BY MARK, ACROSS EVERY STORE -- not by id through a store-routed delete. Two earlier
    -- attempts failed here and both failed the same way: they searched the ONE store the
    -- helper's records are supposed to be in, and Krathe's eight groups are in the spec store.
    -- pihPurgeStrayMarks has the full account.
    do
        local nGroups, nEffects = pihPurgeStrayMarks()
        -- ⚠ IN THE LOG, NOT BEHIND A COMMAND. A migration that deletes stored records must
        -- say what it deleted, and the debug log is where a report can quote it from.
        if (nGroups + nEffects) > 0 then
            DF:Debug("AURADESIGNER",
                "PIH sweep: removed %d retired icon group(s) and %d unreachable effect(s)",
                nGroups, nEffects)
        end
        if s.retainedCfg then s.retainedCfg.iconGroups = nil end
    end

    -- 6. The amplifier list folds into the cooldown list. Whatever the user had ticked keeps
    -- meaning what it meant -- "count trinkets too" -- but it now reaches the effects instead
    -- of a group that is no longer there.
    -- ⚠ THE TICKS ARE READ, NOT RE-DERIVED. s.potions / s.trinkets / s.racials are the
    -- user's stored choices and they are what step 6 replays; the old list's CONTENTS are not
    -- consulted, because a hand edit made in the Filter Designer to a list that is about to be
    -- deleted is not a preference anyone can be held to.
    pihSyncTriggerExtras(s)
    if R then
        local ampId = pihFilterIdByName(PIH_FILTERS.amplifiers)
        if ampId and R.DeleteCustomFilter then R:DeleteCustomFilter(ampId) end
    end

    -- 7. NO STACK COUNT ON A HELPER MARKER. Placed only -- a frame-level effect has no
    -- stacks to begin with -- and set rather than cleared, because the FIELD being absent
    -- means "inherit", and the inherited default is true.
    -- ⚠ EVERY STORE, like step 5: an old marker can be sitting in a spec pool (see
    -- pihPurgeStrayMarks for how it got there). Cheap -- the pools are small and this runs
    -- once per profile.
    do
        local adDB7 = GetAuraDesignerDB()
        for _, poolT in ipairs(adDB7 and pihAllAuraPools(adDB7) or {}) do
            for _, auraCfg in pairs(poolT) do
                if type(auraCfg) == "table" then
                    for _, inst in ipairs(auraCfg.indicators or {}) do
                        if type(inst) == "table" and inst.pihSignal then
                            inst.showStacks = false
                        end
                    end
                end
            end
        end
    end

    -- 8. STAMP THE CURATED DEFAULTS ON A LIST THAT ALREADY EXISTS.
    -- ⚠ THE SAME VALUES pihEnsureFilter WOULD HAVE WRITTEN, from the same seed functions --
    -- not the list's CURRENT contents. Default means what the recipe seeds, so anything the
    -- user has added since is theirs and is deliberately not part of what a reset restores.
    -- ⚠ Only when the mark is missing: re-stamping would be harmless but re-deriving the
    -- seed set on every sweep is work for nothing.
    if R and R.SetCuratedDefaults and R.IsCuratedFilter then
        local cdId = pihFilterIdByName(PIH_FILTERS.cooldowns)
        if cdId and not R:IsCuratedFilter(cdId) then
            R:SetCuratedDefaults(cdId, pihSeedIDs())
        end
        local infId = pihFilterIdByName(PIH_FILTERS.infused)
        if infId and not R:IsCuratedFilter(infId) then
            R:SetCuratedDefaults(infId, { PIH_PI_SPELL_ID })
        end
    end

    -- 9. THE RACIALS LIST, FOR A HELPER THAT PREDATES IT. Four ids written out in this file
    -- became a curated list so the row could have a pencil, a moving count and a reset --
    -- Krathe, 2026-09-10: "racial show 4 and no edit pencil?"
    -- ☠ ONLY WHERE THE HELPER ALREADY EXISTS. This sweep runs on every Aura Designer build
    -- for a priest, helper or no helper, so an unconditional create would put a filter nobody
    -- asked for into the Filter Designer of every priest who has never opened the feature.
    -- The cooldown list is the helper's own footprint, so its presence is the condition.
    -- ⚠ NO RE-SYNC NEEDED AFTER IT. Step 6 above ran pihSyncTriggerExtras while the list did
    -- not exist yet, and pihAmplifierIDs falls back to the same four ids the list is seeded
    -- with -- so the set it wrote is the set it would write now, not an earlier guess at it.
    if pihFilterIdByName(PIH_FILTERS.cooldowns) then pihEnsureRacialFilter() end

    -- 10. ☠☠ THE COPIED AMPLIFIER SPELLS COME BACK OUT OF THE COOLDOWN LIST.
    -- Until now the three amplifier ticks COPIED their lists in, so a helper with all three on
    -- carries 91 spells where it should carry 40 -- Krathe's "so they are now twice on? this is
    -- very confusing". The ticks write `includes` now (see pihSyncTriggerExtras); this takes
    -- back what the old ones left behind, or the list would keep watching those spells twice
    -- over and reading 91 forever.
    -- ⚠ dfDefaults IS THE FENCE. Anything in the seed stays, whatever else it is also in --
    -- an offensive cooldown that happens to sit in the trinket list is OURS by seed and is not
    -- what this step is hunting. Step 8 above guarantees the mark is there to read.
    -- ⚠ A HAND-ADDED TRINKET GOES TOO, and that is accepted rather than overlooked: a copied id
    -- and one the user typed in are indistinguishable in the store, and the include brings it
    -- straight back for anyone who has that source ticked. The alternative is leaving 51
    -- unexplainable rows behind to be safe about one hypothetical.
    -- ⚠ THE PER-SPELL TICK GOES WITH THE SPELL. A `disabled` entry for an id that is no longer
    -- a member is invisible dead weight that would spring back if the id ever returned.
    do
        local cdId = pihFilterIdByName(PIH_FILTERS.cooldowns)
        local f = cdId and R and R.GetCustomFilter and R:GetCustomFilter(cdId)
        if f and R.RemoveSpellFromCustom then
            local seeded = f.dfDefaults or {}
            local n = 0
            for _, sid in ipairs(pihAmplifierIDs(PIH_ALL_AMPLIFIERS, true)) do
                if not seeded[sid] and (f.spells[sid] or f.rawIDs[sid]) then
                    R:RemoveSpellFromCustom(cdId, sid)
                    if f.disabled then f.disabled[sid] = nil end
                    n = n + 1
                end
            end
            if f.disabled and not next(f.disabled) then f.disabled = nil end
            if n > 0 then
                DF:Debug("AURADESIGNER",
                    "PIH sweep: removed %d amplifier spell(s) copied into the cooldown list; "
                    .. "they are referenced now", n)
            end
        end
    end
    -- ...and the references go in, in the same pass. Step 6's own call ran before the racials
    -- list was guaranteed to exist (step 9), so the racials arm could have written nothing.
    pihSyncTriggerExtras(s)

    -- 11. THE ICON GROUP GETS THE FIELDS ITS HAND-WRITTEN RECORD OMITTED.
    -- P.PIH_AddIconGroup built its record as a table literal and forgot `iconSize` and
    -- `maxIcons`; both sliders bind the field directly, so both drew blank, and the factory
    -- falls back to 8 for a filter group's max. Krathe: "Max icons should default to 4 it's
    -- showing blank but seems to look like 8? Icon size is also showing blank on the slider."
    -- ⚠ NIL ONLY. A group somebody has already sized is theirs; this fills the gaps a bad
    -- create left, it does not restore defaults.
    -- ⚠ READ OFF P.NewLayoutGroupRecord rather than typed here, so this step cannot disagree
    -- with what a fresh group is made of -- which is the fault it exists to repair.
    -- ⚠ ANCHOR AND GROW ARE NOT IN THE LIST. The helper's group means TOPRIGHT/LEFT_DOWN and
    -- the shared record means TOPLEFT/RIGHT_DOWN, so filling those from it would move an
    -- existing group. They are set on every create and cannot be nil.
    do
        local g = P.PIH_IconGroup and P.PIH_IconGroup()
        if g and P.NewLayoutGroupRecord then
            local def = P.NewLayoutGroupRecord(g.id, g.name, "filter")
            for _, k in ipairs({ "iconSize", "maxIcons", "iconsPerRow", "spacing",
                                 "offsetX", "offsetY" }) do
                if g[k] == nil then g[k] = def[k] end
            end
        end
    end

    -- 12. THE GROUP IS CALLED "Icons", NOT "Cooldowns". Krathe, 2026-09-10: "maybe it should
    -- be called PI Helper - Icons not cooldowns as it can be trinkets etc too?" -- and more so
    -- since it gained a SHOW block that can set it to trinkets ONLY, where the old name is not
    -- vague but wrong.
    -- ⚠ ONLY IF IT STILL HOLDS THE EXACT OLD STRING. The card has an editable Group Name
    -- field, so anything else is a name the USER typed -- renaming that would be this addon
    -- overwriting their words to satisfy its own tidiness.
    -- ☠ THE OLD NAME IS A LITERAL, NOT A CONSTANT, and only because this file is at Lua's
    -- 200-local ceiling -- see the note on PIH_ICON_GROUP_NAME. It is written once, here, in
    -- the one place that needs to recognise it.
    -- ⚠ THE NAME IS STORED DATA, never L[]: a translated string in the profile is a name that
    -- changes when the client's language does. Same rule the three filter names follow.
    do
        local g = P.PIH_IconGroup and P.PIH_IconGroup()
        if g and g.name == "PI Helper — Cooldowns" then
            g.name = PIH_ICON_GROUP_NAME
        end
    end

    s.schema = PIH_SCHEMA
    S.activeBuffTab = prevPool
    if P.RefreshPlacedIndicators then P.RefreshPlacedIndicators() end
end
-- ☠ EXPORTED, AND THE REASON IS WHO NEVER OPENS THIS PANEL. The sweep used to run only from
-- S.BuildPIHelperCard -- so a stuck cooldown-icon group was deleted when, and only when, the
-- user visited the helper's Triggers tab. That is fine for the person who came to complain
-- about it and no use at all to the person who does not know where it came from: the group
-- draws on every frame and on the designer's own preview, and there is no longer any control
-- anywhere that can turn it off. So both designer builders run it for a priest, which makes
-- "open the Aura Designer at all" the condition rather than "find the right tab".
-- ⚠ CHEAP TO CALL ANYWHERE. It early-outs on the schema stamp after the first run.
P.PIH_Sweep = pihSweep

S.BuildPIHelperCard = function(parent, opts)
    opts = opts or {}
    -- Before anything reads the pool: the panel is the first place an un-swept helper would
    -- show a control that does not match what is on screen.
    pihSweep()
    -- ⚠ RE-STAMP THE REFERENCES, and this is a REPAIR now rather than a re-sync. The ticks
    -- write `includes` on the cooldown list, and that list travels: a profile import copies
    -- `spells` and `rawIDs` and nothing else, so an imported helper arrives with its ticks
    -- intact and its references missing. Running it here means the first visit puts them back.
    -- ☠ IT USED TO BE LOAD-BEARING. The ticks COPIED each preset's spells into our list, so
    -- this was how an edit made in the Filter Designer since the last visit reached the helper
    -- at all -- and a pencil that opened a list whose edits went nowhere is precisely what
    -- made the copy indefensible. References need no such visit; see pihSyncTriggerExtras.
    -- ⚠ CHEAP AND IDEMPOTENT: three ticks read, one small table written.
    pihSyncTriggerExtras(P.PIH_Settings())
    local yPos = opts.startY or 0
    local Refresh = opts.Refresh or function() end
    -- ⚠ THE STORED FLAG, NOT THE RECORDS. "Is the helper on" and "does it hold any
    -- effects" are two different questions since the switch stopped deleting -- a
    -- disabled helper keeps every record it had. P.PIH_IsEnabled backfills the flag once
    -- for a profile that predates it.
    local enabled = P.PIH_IsEnabled()

    -- ── AN ENABLE TICK, NOT AN ADD/REMOVE CARD (2026-09-08) ──
    -- ☠ "ADD" AND "REMOVE" WERE THE IMPLEMENTATION TALKING. They were literally true --
    -- the helper creates and deletes Aura Designer records -- but that is plumbing the user
    -- was never meant to know about, and on a page whose whole subject IS the helper a card
    -- offering to add the thing you came here for is a step with nothing on the other side
    -- of it. Krathe, 2026-09-08: "the add/remove helper is a pointless option now and
    -- should just be an enable/disable setting like the AD enable/disable."
    -- ⚠ SO IT READS LIKE THE DESIGNER'S OWN ENABLE, deliberately: the same banner, the same
    -- styled check button, the same left-aligned label. Two features that turn on the same
    -- way should look like they turn on the same way.
    -- ⚠ AND YOUR SETTINGS SURVIVE THE ROUND TRIP. Unticking still routes to PIH_Remove,
    -- which STASHES every customisation (pihStash), and PIH_Create lays the stash back over
    -- the fresh defaults (pihRestoreGroup) -- so this behaves like an enable even though
    -- records really are created and deleted underneath. That was already true of the old
    -- card; the tick just stops making the user think it is a destructive act.
    local banner = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    -- ⚠ ONE ROW, NOT TWO. The explaining sentence was a second line under the tick; it is a
    -- tooltip now (Krathe, 2026-09-08). It earns a hover and not a permanent row: it is read
    -- once, by someone deciding whether to turn the feature on, and after that it is a
    -- sentence in the way of the settings every visit -- on a page whose own nav entry
    -- already says Power Infusion Helper.
    banner:SetHeight(32)
    banner:SetPoint("TOPLEFT", 8, yPos)
    banner:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    GUI:CreatePanelBackdrop(banner, { borderColor = { r = 0.30, g = 0.30, b = 0.30, a = 0.5 } })

    local cb = CreateFrame("CheckButton", nil, banner, "BackdropTemplate")
    cb:SetPoint("TOPLEFT", banner, "TOPLEFT", 10, -10)
    DF.GUI:StyleCheckButton(cb)
    cb:SetChecked(enabled)
    cb:SetScript("OnClick", function(self)
        -- ⚠ READ THE STORED FLAG, NOT THE BOX. The tick's own state is what the user just
        -- did; the flag is what the profile says. A double click, a profile switch landing
        -- mid-build or a stale page would otherwise write the wrong direction.
        -- ☠ AND IT NO LONGER DELETES ANYTHING. This used to be
        -- `if P.PIH_Exists() then P.PIH_Remove() else P.PIH_Create() end` -- off meant
        -- destroying every helper record and stashing a copy to fake reversibility, which is
        -- how Krathe's border went missing. The flag is the switch now; the records stay.
        P.PIH_SetEnabled(not P.PIH_IsEnabled())
        self:SetChecked(P.PIH_IsEnabled())
        Refresh()
    end)

    local cbLabel = banner:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    cbLabel:SetPoint("LEFT", cb, "RIGHT", 8, 0)
    cbLabel:SetText(L["Enable Power Infusion Helper"])
    cbLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    -- ⚠ THE HIT AREA IS THE WHOLE BANNER, not just the 16px box. A tooltip on a checkbox the
    -- size of a full-stop is a tooltip nobody finds; the row is what the eye is on.
    banner:EnableMouse(true)
    banner:SetScript("OnEnter", function(self)
        GUI:ShowTooltip(self, {
            title = L["Power Infusion Helper"],
            lines = { L["Shows who is worth infusing, and goes dark while your Power Infusion is on cooldown."] },
        })
    end)
    banner:SetScript("OnLeave", function() GUI:HideTooltip() end)

    banner.checkbox = cb
    yPos = yPos - (banner:GetHeight() + GUI.Space.section)
    -- ☠ THE SECOND RETURN GATES THE SECTIONS, on the SWITCH now rather than on whether
    -- records exist. The old card group carried its own collapsing header and published
    -- whether it was open, so the sections had to respect a fold that no longer exists --
    -- a banner does not fold.
    return yPos, enabled
end

-- ── THE SECTION TOOLKIT ──
-- ☠ SHARED BEHAVIOUR LIVES IN THESE SECTIONS, NOT ON EACH EFFECT ROW. The mockup put
-- "Never mark", "Only watch" and the gating cooldown on every effect. It was drawn
-- before the engine existed, and the engine made them ONE switch for the whole
-- helper. Three copies of "never on tanks" that can disagree is not flexibility --
-- it is four states where one is meaningful and three are bug reports.
-- Appearance (colour, border style, which surface) stays on the effect rows, because
-- that genuinely differs per signal and is where the AD already puts appearance.
--
-- ☠ INDENTED IN THE CLASSIC TAB, AND THAT IS THE WHOLE POINT OF THE INDENT. These
-- boxes used to start at the same left edge as "Add an indicator" and "Active
-- indicators", so a column of five same-level boxes read as five sections rather
-- than as one section and the four boxes belonging to it. Nothing said which header
-- owned them. Ten pixels of indent is what says it -- the hierarchy was always
-- there, it just was not drawn.
-- ⚠ 20 IS THE ADDON'S INDENT STEP, not a number picked here: the page layout engine
-- reads `widget.indent` and multiplies by 20 per level. That flag cannot be used
-- directly -- this column lays itself out by hand rather than going through the page
-- engine -- so the step is borrowed instead of the mechanism, which at least keeps
-- one indent width in the addon rather than two.
-- ⚠ The ROW PAGE passes opts.indent = 8 instead: inside a popout pane each section
-- IS the surface, there is no owning header to indent under, and 8 is the pane's
-- own content inset.
local PIH_INDENT = 20
-- ...and the note metrics the estimator below leans on. Their full story is on
-- pihMakeTools; they sit at file scope so both layouts read the same numbers.
local PIH_NOTE_LINE = 13
local PIH_CB_TEXT = 24   -- the 16px box plus the 8px label gap

-- One toolkit per BUILD, not per file: everything in here derives from the parent's
-- width and the caller's Refresh, which differ per layout and per open. The bodies
-- below take (group, tools) and never touch a layout global.
local function pihMakeTools(parent, opts)
    opts = opts or {}
    local t = {}
    t.Refresh = opts.Refresh or function() end
    t.indent  = opts.indent or PIH_INDENT
    t.groupW  = (parent:GetWidth() or 320) - (t.indent + 18)
    t.parent  = parent

    -- Builds ONE settings group at startY and returns the y below it.
    function t.group(header, buildFn, startY, gopts)
        local group = GUI:CreateSettingsGroup(parent, t.groupW, gopts)
        group.padding = 10
        if header then
            group:AddWidget(GUI:CreateHeader(parent, header), GUI.RowHeight.sectionHeader)
        end
        buildFn(group, t)
        local h = group:LayoutChildren()
        group:SetPoint("TOPLEFT", t.indent, startY)
        group:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
        -- The named scale, not a number that looks about right. GUI.Space carries a note
        -- about an audit that found 58 spacers using 9 different values for two intents,
        -- and three files each inventing their own for the same one.
        return startY - (h + GUI.Space.section)
    end

    -- ☠☠ EVERY NOTE IN THESE SECTIONS TAKES AN EXPLICIT HEIGHT, which inverts CreateLabel's
    -- usual advice on purpose -- and getting that inversion wrong cost three rounds of
    -- the user's time, so here is the whole mechanism.
    --
    -- A label builds itself 380px wide, measures, and gets a ONE-LINE answer. The group
    -- then narrows it to the real width and the text wraps to three or four lines. The
    -- label notices and fires a correction -- but only when the call site left the height
    -- alone, and that correction re-flows the GROUP, then asks the COLUMN, which stacks
    -- its children at fixed offsets and does nothing. So the group keeps the one-line
    -- height, the label spills out of its bottom edge, and the next box is drawn on top
    -- of it. That is how the note went "missing" and the boxes overlapped in the same
    -- breath: the same fault, seen from two ends.
    --
    -- ⭐ CreateLabel's own comment names the escape hatch without calling it one: labels
    -- "with a call-site height are exactly the ones nothing else ever touches again". A
    -- pinned height is the ONLY safe kind of note here, because pinning is what stops the
    -- converge that this column cannot absorb.
    --
    -- ⚠ AND MEASURING INSTEAD IS NOT AVAILABLE. CreateLabel's own note records the
    -- attempt: "Do NOT try to Reflow()+Remeasure() synchronously here to get a correct
    -- height at creation. Tried 2026-08-05 and it does not work: nothing has been drawn
    -- yet at card build time, so GetStringHeight still returns 0". So the height has to
    -- be predicted, and the only question is how well.
    --
    -- ⚠ DERIVED FROM THE REAL WIDTH, not a constant. The first version used a flat 38
    -- characters per line "to be safe"; the truth at this panel's width is nearer 68, so
    -- every note claimed twice the lines it needed and left visible gaps above the first
    -- tick and below the last note -- field-reported with a screenshot 2026-08-24.
    -- The per-character width is deliberately a shade wider than the font renders, so the
    -- count errs toward MORE lines, which is the safe direction; and because it reads the
    -- panel width it stays right when the panel is resized, not only at one size. The
    -- measured figure and why it is rounded up are on PIH_NOTE_LINE above.
    -- The byte count makes an em dash worth three, which errs the same way.
    -- Delete all of this the day the column publishes a `dfAD_ReflowWidgets` seam.
    t.noteW = t.groupW - 24
    -- ⭐ 6 PIXELS PER CHARACTER, AND THAT NUMBER WAS MEASURED, NOT PICKED.
    -- It was 8, which is where seven rounds of gaps came from: at a note width of 400 the
    -- panel fits ~74 characters on a line, so 400/74 is about 5.4 -- and reserving for 50
    -- meant every long note claimed half again as many lines as it needed. The big one
    -- asked for 8 lines to hold 5.
    -- ⚠ 6 rather than 5.4 on purpose: it still errs long, by roughly a line on a
    -- paragraph, and that line is the margin a longer translation gets to grow into.
    -- ☠ Do NOT try to verify this from the widget. A probe that dumped every note's
    -- measured height reported 30 for all of them whatever the text, because a pinned
    -- label's frame never grows -- the FontString simply draws past it. The slot IS the
    -- layout here; the frame height is not evidence of anything.
    -- Parameterised on the wrap width, because the checkbox helper below
    -- estimates against a NARROWER column than the notes (its text starts
    -- past the box). t.lines keeps its one argument -- the note call sites
    -- are many and their width is one number.
    function t.linesAt(text, w)
        local cpl = math.max(20, math.floor(w / 6))
        -- ⚠ Colour escapes are not characters anyone can see. Counting them would add
        -- twelve bytes per highlighted word and inflate the box by a line or two of pure
        -- whitespace, which is the fault this estimator exists to avoid.
        local plain = tostring(text):gsub("||r", "")
        return math.max(1, math.ceil(#plain / cpl))
    end
    function t.lines(text) return t.linesAt(text, t.noteW) end
    -- ⭐ GUI:CreateNote, not a hand-coloured CreateLabel. It IS the toned-note widget --
    -- a label with the tone's own accent baked in through ToneHex, so a caution note here
    -- is the same yellow as every caution note in the addon rather than three numbers
    -- typed at this call site. `tone` names come from INFO_BANNER_TONES: info, caution,
    -- danger, success. (The tone adds a colour escape to the string, which the byte count
    -- below then treats as a dozen characters -- harmless, and it errs long.)
    -- Notes are prose: fullRow, so the Classes section's two-track grid never
    -- narrows one (a no-op everywhere else -- a one-track group is all full rows).
    function t.note(g, text, tone)
        if not text or text == "" then return end
        -- ⚠ ALWAYS THROUGH CreateNote, toned or not: it resolves an untoned note to
        -- CreateLabel itself, so branching here made this a second opinion about what a note
        -- is -- and the tone vocabulary (and any future note chrome) would reach only half
        -- of ours.
        local w = GUI:CreateNote(parent, text, { tone = tone })
        w.fullRow = true
        g:AddWidget(w, t.lines(text) * PIH_NOTE_LINE + (GUI.RowHeight.labelPad or 19))
        return w
    end

    -- ☠ CHECKBOX LABELS ARE SINGLE-LINE AND UNBOUNDED. CreateCheckbox
    -- anchors its label LEFT-only off the box, so a long label simply runs
    -- right at its natural width -- invisible in the classic tab's column,
    -- where the longest fits, and straight off the edge of the 260px popout
    -- pane ("text runs off the edge"). So every tick in these sections goes
    -- through here: the label gets a right edge on its own row, wraps, and
    -- the SLOT grows by the same estimator the notes use (measuring is not
    -- available at build time -- see the note above). At the classic width
    -- every label estimates one line and nothing moves.
    -- ⚠ Checkboxes are fixedRowHeight widgets: ResolveRowHeight ignores a
    -- call-site number for them, so the taller slot goes through
    -- preferredHeight instead. The container grows by the same lines so the
    -- box and the centred label keep tracking each other.
    -- wrapW is the Classes grid's narrower track; everything else omits it.
    function t.check(g, label, get, set, wrapW)
        local w = GUI:CreateCheckbox(parent, label, nil, nil, nil, get, set)
        w.label:SetPoint("RIGHT", w, "RIGHT", 0, 0)
        w.label:SetJustifyH("LEFT")
        w.label:SetWordWrap(true)
        local lines = t.linesAt(label, (wrapW or t.noteW) - PIH_CB_TEXT)
        if lines > 1 then
            w:SetHeight(24 + (lines - 1) * PIH_NOTE_LINE)
            w.preferredHeight = (GUI.RowHeight.checkbox or 35)
                + (lines - 1) * PIH_NOTE_LINE
        end
        g:AddWidget(w)
        return w
    end

    -- A NESTED tick, through the addon's own convention rather than a hand-rolled offset:
    -- the column layout multiplies `widget.indent` by 20 when it places the row. The wrap
    -- width narrows to match, or a long label would measure its height against a width it
    -- does not get.
    -- A sub-heading inside a group, through the shared header widget rather than a
    -- dim label pretending to be one: the ticks under it are a set, and a set wants a
    -- name with a heading's weight.
    -- ☠ A SETTING LABEL, NOT A SECTION HEADER. This was CreateHeader, and it was the
    -- only mid-box header in the addon: every other CreateHeader in either addon is the FIRST
    -- widget in its group -- the box's own title -- and one call site says so outright ("a
    -- header names the SECTION"). One accent heading floating between two plain setting labels
    -- read as a different kind of thing, which it was.
    -- ⚠ THE WEIGHT COMES FOR FREE. A dropdown draws its own label in DFFontHighlightSmall
    -- at C_TEXT, and the shared label helper defaults to that same font -- overriding only the
    -- colour to dim. Passing C_TEXT back gives an exact match with "Big cooldown" above it,
    -- with no new widget and no fork of a helper.
    function t.settingLabel(g, text)
        local w = GUI:CreateLabel(parent, text, nil, C_TEXT)
        w.fullRow = true
        g:AddWidget(w, t.lines(text) * PIH_NOTE_LINE + (GUI.RowHeight.labelPad or 19))
        return w
    end

    function t.subCheck(g, label, get, set)
        local w = t.check(g, label, get, set, (t.noteW or 0) - PIH_INDENT)
        w.indent = true
        return w
    end

    -- ☠☠ NOT A BANNER, AND THE REASON IS A RACE RATHER THAN A SIZE.
    -- Six shapes were tried and the symptom alternated between an overlap and a large
    -- gap FROM THE SAME BUILD -- "half the time it's overlap, the other half it's a huge
    -- gap". That is not a wrong constant; a wrong constant is wrong the same way every
    -- time. It is a timing race, and no number can win one.
    --
    -- ⭐ Verified, and the asymmetry is the whole story: AddWidget stamps
    -- `_slotHeightExplicit` when a call site pins a height (Sections.lua:125).
    -- CreateLabel CHECKS it (Sections.lua:479) and skips its re-measure entirely, so a
    -- pinned label is fixed at build and never corrects itself. CreateInfoBanner never
    -- checks it -- its DoRecomputeHeight and TriggerHostRelayout run whatever you passed.
    -- So the box's final height depends on when the panel happened to be built relative
    -- to the banner's TWO measure passes: before it settles, the column reserved too
    -- little and the next group is overlapped; after, the group shrinks under a
    -- reservation already spent and the space becomes a gap.
    --
    -- ⚠ A box therefore cannot be made deterministic from this side. Getting one back
    -- means CreateInfoBanner honouring `_slotHeightExplicit` the way CreateLabel does --
    -- Danders' file, a real request with a checked premise, and NOT the reflow seam we
    -- nearly asked for and withdrew.

    -- Each tick creates or deletes one ordinary effect, which is why the signal rows
    -- also appear in Active Indicators: they ARE indicators, and hiding them there
    -- would mean a row you can see the colour of but cannot find.
    -- ── t.signalRow: REMOVED, 2026-09-08 ──
    -- ☠ It was the whole per-signal control: a surface dropdown, a clash warning, a colour
    -- swatch and the icon lists. The Effects tab is the DESIGNER's add flow and effect
    -- cards now (pihBuildEffectsTab), so the first three are drawn by the designer's own
    -- widgets and cannot drift from them -- which is the whole point of the change.
    -- ⚠ THE ICON LISTS SURVIVED THE REMOVAL, deliberately: they moved to pihAddIconLists and
    -- are drawn under Triggers, where they belong -- each tick decides which category of buff
    -- COUNTS, not how anything is drawn. Deleting this function without lifting them would
    -- have quietly removed four of Maelareth's settings (#263) as a side effect of a
    -- layout change.

    return t
end

-- ── THE SECTION BODIES ──
-- Each takes (group, tools) and adds its widgets; which GROUP it lands in is the
-- composition's business -- classic folds several into one box, the row page gives
-- each its own pane.

-- ☠ (Removed) pihAddIntro. Its one sentence -- "choose how the helper shows on your
-- group frames" -- described what two labelled dropdowns and a set of ticks underneath were
-- already saying. The banner-versus-label lesson it carried is not lost: pihAddGateAndNotes
-- below states it, and GUI:RelayoutHost documents the underlying reflow seam.

local function pihAddGateAndNotes(g, t)
    -- ☠ A LABEL, NOT AN INFO BANNER, AND THIS IS THE SECOND TIME THE SAME TRAP HAS
    -- CAUGHT US. A banner starts life 34px tall and measures its real height a frame
    -- after it draws, then asks its host to re-flow. Inside a settings group the
    -- GROUP does re-flow -- which is why putting it in one looked like the fix -- but
    -- the group then asks the COLUMN, and this column publishes no
    -- `dfAD_ReflowWidgets` seam, so every box below it stays where the old height
    -- put it. Four lines of prose starting from a 34px estimate is a big enough jump
    -- to land on the next box: "Trinkets and Potions is being overlapped by What to
    -- Show", field-reported 2026-08-24.
    --
    -- ⚠ THE DIFFERENCE IS THE SIZE OF THE LIE, not the widget. CreateLabel measures
    -- itself too, but it starts at 40px, which already covers the two-line notes
    -- these boxes use -- so its correction is small or zero and nothing visibly
    -- moves. A banner's is not. Until the column grows a reflow seam (raised with
    -- Danders), prose here has to be short enough that its first guess is right.
    --
    -- ⚠ AND THE TEXT SHRANK FOR THE SAME REASON IT COULD AFFORD TO: two of the three
    -- facts it carried are already on screen where they matter. The swap is written
    -- into the dropdown entry itself ("Health Bar (swap with Big cooldown)"), and
    -- the single-winner warning appears, naming the offender, exactly when it
    -- applies. Only the stacking rule had nowhere else to live.
    -- ☠ A TOGGLE, NOT A SPELL PICKER. An earlier pass let the user choose which
    -- cooldown gates the helper. The machinery is not priest-specific so it was
    -- easy -- but nobody asked for it, and "which spell hides this" is a question
    -- about plumbing rather than about the feature. The helper exists to say who is
    -- worth infusing; it hides when you cannot infuse. One idea, one switch.
    -- (The capability stays underneath for testing.)
    --
    -- ⚠ IT SITS HERE RATHER THAN IN A BOX OF ITS OWN. A whole titled group around a
    -- single checkbox is more chrome than the setting is worth, and this label says
    -- what it does without a header to lean on -- which is the test for whether a
    -- control can live under a heading that does not quite describe it.
    -- ⚠ THAT TEST IS STILL MET BY A SHORTER LABEL. "Show even if your Power Infusion is on
    -- cooldown" spelled the whole rule out on the row and wrapped doing it; Krathe, 2026-09-10:
    -- "less verbose with tooltip and more clear." The rule moved to the tooltip; what stays on
    -- the row is which cooldown is meant.
    -- ⚠ KRATHE'S OWN WORDING, VERBATIM. My draft was "Show when I can't infuse" -- shorter, and
    -- it identified the cooldown only by implication. Naming Power Infusion says it outright,
    -- which matters in a box otherwise full of OTHER people's cooldowns: a label that does not
    -- say which spell reads as the tracked one. (That is also why "Show while on cooldown",
    -- shorter still, was never an option.)
    -- ★ ASKED THE OTHER WAY ROUND (2026-09-08), for the same reason the roles were: every
    -- other tick on this panel turns something ON when ticked, and this one turned a
    -- SUPPRESSION on -- so the whole box read as a list of things you enable except for the
    -- one that hid things. Krathe: "Hide the helper while on CD should be 'show even if PI is
    -- on CD' off by default."
    -- ⚠ THE STORE IS UNCHANGED AND THE DEFAULT ALREADY MATCHES. gateEnabled ships true, so
    -- `not gateEnabled` reads as UNTICKED -- which is the off-by-default he asked for -- and
    -- nobody's saved choice changes meaning. Inversion in the UI only, exactly like the roles.
    local gateCb = t.check(g, L["Show when Power Infusion is on Cooldown"],
        function() return P.PIH_Settings().gateEnabled == false end,
        function(v) P.PIH_SetGateEnabled(not v) end)
    -- ⚠ NO TITLE, WHICH MEANS THE LABEL. ResolveTooltipSpec fills a missing title from the
    -- widget's label, and this label names its own setting -- unlike the sound tick, which
    -- passes a title because "Enable" heads nothing.
    -- ⚠ TWO LINES, ONE STATE EACH, and each one a plain sentence. What was here read
    -- "markers appear only while your Power Infusion is ready, so you are never pointed at
    -- someone you cannot infuse" -- a clause explaining a consequence of a rule it had not
    -- finished stating, in a vocabulary this panel does not use. Krathe, 2026-09-10:
    -- "markers? it should be effects and the wording itself is not very clear."
    -- ⚠ "EFFECTS" IS THE PANEL'S OWN WORD -- what the Effects tab lists and what ACTIVE
    -- INDICATORS holds. "Marker" belongs to the raid target icon and the dispel corner mark,
    -- which are other features entirely.
    -- ⚠ OFF FIRST. Off is the default, so the reader's first line is the behaviour they have.
    -- ⚠ "off cooldown" / "on cooldown" ECHOES THE LABEL rather than reaching for a synonym:
    -- the tick says on Cooldown, so the explanation says the same words back.
    if gateCb then
        gateCb.tooltip = { lines = {
            L["Off: the helper's effects only appear while your Power Infusion is off cooldown."],
            L["On: they appear even while it is on cooldown."],
        } }
    end


    -- ☠ THE CONTENTION NOTES ARE GONE, AND THE ARGUMENT THAT KEPT THEM WAS THE
    -- ARGUMENT AGAINST THEM. They survived an earlier cut because they were "the only
    -- facts nothing else on the panel ever states" -- but the clash warning states the
    -- same fact at the moment it applies, on the row it applies to, naming the effect in
    -- the way and the remedy. A general rule taught in advance to everyone, to spare the
    -- few who will meet the specific warning, is instruction text earning nothing.
    -- ⚠ The sizing lesson below them still holds and is worth keeping in view: notes
    -- of 38-53 characters reserved their space to within 2px, a 359-character one was out
    -- by 93. Short notes are exact; long ones drift, whatever constant is used. Any note
    -- added to this panel has to fit on one line.
    -- The one navigational fact text is genuinely needed for. Only while the
    -- icon group exists: position is not a question about icons that are not there.
end

-- ★★ ASKED POSITIVELY: "WATCH THESE ROLES", NOT "NEVER SHOW ON THESE" (2026-09-08).
-- ☠ THE STORE IS STILL AN EXCLUSION SET AND THAT IS DELIBERATE. helperExcludedRoles is what
-- the container gate reads, and it fails open on a missing entry -- a group with no assigned
-- roles reads "no role" for everyone and nothing is hidden, which is the safe direction.
-- Rewriting the store to a positive set would flip that: an empty table would mean "watch
-- nobody" and the whole feature would go dark on a group without role assignments.
-- ⇒ THE INVERSION IS IN THE UI ONLY. Ticked means watched, which is `not excluded`.
-- ⚠ AND THE OLD DEFAULTS ALREADY ARE THE NEW ONES: the store ships { TANK, HEALER }
-- excluded, which reads through this inversion as DPS on, Tanks and Healers off -- exactly
-- what Krathe asked for. No migration, and nobody's saved choice changes meaning.
-- ⚠ DAMAGER is a real UnitGroupRolesAssigned token (Core.lua's GetUnitRole passes it
-- through), so unticking DPS excludes it the same way the other two do. It was simply never
-- offered before, which made "watch DPS" an invisible always-on rather than a choice.
local function pihAddRoles(g, t)
    local function roleCheck(label, token)
        t.check(g, label,
            function() return (P.PIH_Settings().roles or {})[token] ~= true end,
            function(v) P.PIH_SetRole(token, not v) end)
    end
    roleCheck(L["DPS"],     "DAMAGER")
    roleCheck(L["Tanks"],   "TANK")
    roleCheck(L["Healers"], "HEALER")
    t.note(g,
        L["Groups without assigned roles show everyone."])
end

-- ☠ TWO NAMED HALVES IN ONE BOX. The section used to be "Classes to Watch" with a
-- button for single spells bolted on top, which is two different questions -- WHOSE cooldowns,
-- and WHICH cooldowns -- under one name that only answered the first. Each half now carries a
-- label at setting weight, and the box is named for both.
-- ⚠ DECLARED ABOVE ITS CALLERS, and it has two now: the source rows' pencils and the
-- Edit Cooldowns button inside pihAddClasses. Moving the button into that function put a
-- caller ABOVE this definition, which compiles as a nil GLOBAL read -- invisible to
-- luac -p and caught only by the _ENV globals diff.
-- ⭐ GUI:OpenFilterInDesigner, NOT a bare SelectTab. It switches the page AND scrolls to
-- the list, selects it and pulses it -- Krathe's "flash link". Its own comment records why
-- the difference matters: a hand-written jump "landed you on the page with nothing
-- indicated, which is indistinguishable from a broken link".
-- ⚠ TWICE, ONE FRAME APART, and that is a workaround rather than belt-and-braces:
-- _fdFocusFilter clamps its scroll against GetVerticalScrollRange, which is still 0 on the
-- target page's FIRST build -- so the row it selected sits below the fold. The second call
-- runs after layout. The proper fix is a deferred retry inside _fdFocusFilter; that file is
-- Danders' and it is on the list for him rather than edited from here.
local function pihOpenFilter(kind, key)
    if not (key and GUI.OpenFilterInDesigner and GUI.Pages and GUI.Pages["auras_filterdesigner"]) then
        return
    end
    GUI:OpenFilterInDesigner(kind, key)
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function() GUI:OpenFilterInDesigner(kind, key) end)
    end
end

local function pihAddClasses(g, t)
    local parent = t.parent
    t.settingLabel(g, L["Classes"])

    -- ⚠ THE POPOUT PANE FLOWS THESE ACROSS TWO TRACKS (t.classColumns; the classes
    -- section's own build passes innerColumns = 2 to the group). Fourteen 35px rows
    -- single-file is a 490px column -- taller than the whole page the pane must fit
    -- -- and class names are the shortest labels this panel has, so they are the one
    -- list that can afford the narrower track. The wrap estimate is told the track's
    -- width for the same reason the notes are told theirs.
    local wrapW
    if t.classColumns and t.classColumns > 1 then
        -- The group's content width less the grid gutter, split per track --
        -- the same arithmetic LayoutChildren runs (Sections.lua's colWidth).
        wrapW = ((t.groupW - 20) - (GUI.SettingsBox and GUI.SettingsBox.innerGap or 10)
            * (t.classColumns - 1)) / t.classColumns
    end
    for _, token in ipairs(P.PIH_ClassList()) do
        local classFile = token
        -- Read at call time: SpellPicker.lua loads after this file, so the display
        -- helper does not exist yet at file scope.
        local name = (DF.FilterRegistry and DF.FilterRegistry.ClassDisplayName
            and DF.FilterRegistry.ClassDisplayName(classFile)) or classFile
        local w = t.check(g, name,
            function() return P.PIH_ClassOn(classFile) end,
            -- ⚠ t.Refresh AS WELL AS THE WRITE, because this tick changes the BOX HEADER.
            -- The count beside "Classes and Cooldowns" is read at build time, and
            -- P.PIH_SetClassOn ends at pihRefresh -- which redraws the FRAMES and the
            -- preview, not the panel. So the number sat stale until the page was rebuilt
            -- by something else: "the number does not update unless you go back to the
            -- page as you tick off classes" (Krathe, 2026-09-09).
            -- ⚠ THE ONLY TICK IN THIS BOX THAT NEEDS IT. The amplifier ticks show category
            -- sizes, which are constants, and they add to the list rather than to the seed
            -- set the header counts -- so nothing on screen moves when they change.
            function(v) P.PIH_SetClassOn(classFile, v); t.Refresh() end,
            wrapW)
        -- ☠ CLASS-COLOURED, THROUGH THE SHARED HELPER. Thirteen identical grey rows is
        -- the one list on this panel nobody can scan -- and the addon already answers that
        -- everywhere else it prints a class name: the Filter Designer's headers, the spell
        -- picker's rows, the spec dropdown's groupings. R.ApplyClassNameColor is that styling,
        -- so this extends the convention rather than forking a second one.
        -- ⚠ IDENTITY, NOT STATE. The colour says WHICH class; the tick still says whether
        -- it is watched, and an unticked row keeps its colour so the eye can find it again.
        local R2 = DF.FilterRegistry
        if w and w.label and R2 and R2.ApplyClassNameColor then
            R2.ApplyClassNameColor(w.label, classFile)
        end
    end
    t.note(g, L["Untick a class to stop watching its cooldowns."])

    -- ★ THE BUTTON IS BACK, IN THE BOX THAT OWNS THE LIST. Krathe, 2026-09-10: "Cooldowns
    -- should be in with the Classes and maybe should still be a button Edit Cooldowns".
    -- ☠ WHAT WENT WRONG BEFORE WAS NEVER THE BUTTON. It was a button captioned for one of four
    -- lists standing in a box that held all four, with a NOTE underneath apologising that the
    -- other three were not really editable. The three have their own rows and their own pencils
    -- now, so this one is unambiguous: it belongs to the list the ticks above it narrow, and it
    -- says which list that is.
    -- ⚠ A BUTTON RATHER THAN A PENCIL, deliberately: the pencils sit on ROWS, beside the tick
    -- that includes that source. This box has no source row -- the thirteen class ticks are the
    -- control -- so there is nothing for a glyph to sit on, and a full-width button reads as
    -- belonging to the box rather than to whichever row it happened to be nearest.
    local cdID = P.PIH_CooldownFilterID and P.PIH_CooldownFilterID()
    local cdBtn = GUI:CreateButton(parent, L["Edit Cooldowns"], 140, 22, function()
        pihOpenFilter("custom", cdID)
    end)
    if not (cdID and GUI.Pages and GUI.Pages["auras_filterdesigner"]) then
        -- ⚠ THE SHARED TREATMENT, not a hand-written grey. CreateButton routes through
        -- StyleButton, which owns SetDisabled: dim backdrop, faint border, label alpha, wash
        -- suppressed. Disable() plus a literal text colour rendered a NORMAL backdrop with grey
        -- text, visibly unlike every other disabled button in the addon. Caught in review.
        if cdBtn.SetDisabled then cdBtn:SetDisabled(true)
        else cdBtn:Disable(); cdBtn.Text:SetTextColor(0.4, 0.4, 0.4) end
    end
    -- Prose-width like the notes: only the class TICKS flow the popout's two tracks.
    cdBtn.fullRow = true
    g:AddWidget(cdBtn, 28)


end


local function pihAddSound(g, t)
    local parent, Refresh = t.parent, t.Refresh
    -- ☠ TWO SETTINGS, NOT ONE. The key remembers WHICH sound, the switch remembers
    -- WHETHER -- so turning it off and back on does not make anyone hunt for their
    -- sound a second time. Silent until chosen, either way: a cue nobody asked for
    -- is the fastest route to the whole feature being switched off.
    -- ⚠ "Enable", NOT A SENTENCE. The box is already captioned Sound Alert, so a label
    -- restating the whole feature says it twice and wraps to two lines doing it -- Krathe,
    -- 2026-09-10: "too verbose, make it Enable with a tooltip explaining what it does in
    -- better english". The explanation goes where an explanation goes.
    -- ⚠ A TABLE SPEC, so the tooltip keeps the BOX's title. ResolveTooltipSpec defaults a
    -- bare string's title to the LABEL, and "Enable" heading its own tooltip tells nobody
    -- which setting they are reading about.
    local soundCb = t.check(g, L["Enable"],
        function() return P.PIH_Settings().soundOn == true end,
        function(v) P.PIH_SetSoundOn(v); Refresh() end)
    if soundCb then
        soundCb.tooltip = {
            title = L["Sound Alert"],
            lines = { L["Plays your chosen sound when a group member's cooldown makes them worth infusing."] },
        }
    end
    if P.PIH_Settings().soundOn then
        g:AddWidget(GUI:CreateSoundDropdown(parent, L["Sound"],
            P.PIH_Settings(), "soundLSMKey",
            function() P.PIH_ApplySound() end), GUI.RowHeight.dropdown)
        -- ⚠ Stated rather than discovered in a fight: sound rides the same gate as
        -- the visuals, and it announces new windows only -- a window already open
        -- when the gate re-opens stays silent, because the visuals already carry it.
        t.note(g,
            L["Only plays while the helper is showing."])
    end
end

-- ── THE ROW PAGE'S SECTION LIST: REMOVED, 2026-09-08 ──
-- ☠ It described a layout that no longer exists. S.PIHelperSections existed so the popout
-- page could mount each section behind its own row, and that band went when the helper got
-- its own page -- leaving a table nothing read and a paragraph of reasoning about pane
-- widths and row counts that would have gone on looking maintained.
-- ⚠ The BODIES it wrapped are all still here (pihAddRoles / pihAddClasses / pihAddSound /
-- pihAddGateAndNotes) and S.BuildPIHelperBody composes them per tab. Only the row-page
-- adapter went. If a second layout ever needs them again, wrap them again -- do not read
-- this comment as a reason not to.

-- ★★ TWO TABS, THE SAME SHAPE THE DESIGNER'S RIGHT PANEL USES (2026-09-08).
-- ☠ THE SPLIT IS THE FEATURE'S OWN TWO QUESTIONS, and they are answered at different
-- times. TRIGGERS is "what counts as worth infusing" -- roles, the cooldown gate, which
-- classes and which spells -- and is set up once, carefully, probably while reading a spell
-- list. EFFECTS is "how do I want to be told" -- surface, colour, sound -- and gets fiddled
-- with. One column holding both meant scrolling past the long class list every time you
-- wanted to nudge a colour. Krathe: "we should also split on the right side Triggers and
-- Effects."
-- ⚠ THE KEYS ARE THE TAB IDS, and they are what the page's tab bar drives. Order matters:
-- triggers first, because you cannot sensibly choose how to be told about something you
-- have not yet said you care about.
    -- ★★★ FOUR SOURCES, FOUR ROWS, EACH WITH THE WAY IN TO ITS OWN LIST (2026-09-09).
    --
    -- ☠ WHAT THIS REPLACES, AND WHY PROSE COULD NOT SAVE IT. The box had one button captioned
    -- for one of the four lists and a NOTE underneath explaining that the other three were not
    -- really lists you could edit -- an implementation detail (the ticks COPY a preset's spells
    -- rather than referencing it) leaking into the panel and being apologised for. Krathe:
    -- "the note below the link to edit the cooldown list is silly, the additional filters can
    -- also be edited, this really is an unclear mess."
    -- ⇒ He is right that they can be edited. The bug was that editing them did nothing, so the
    -- panel had to talk you out of trying.
    -- ★ AND THE REAL FIX CAME TWO ROUNDS LATER (2026-09-10). The first attempt kept the copy
    -- and made it honour each preset's ticks, re-taking it on every visit -- which made edits
    -- reach the helper, and left the list reading 91 spells with the same ids in two places:
    -- "so they are now twice on? this is very confusing." A copy that tracks its source is
    -- still a copy, and the pencil still promises something the tick does not do.
    -- ⇒ The ticks write `includes` now and nothing is copied at all (pihSyncTriggerExtras).
    -- Each row links to the list it names, and that list is the one being read.
    -- ⚠ NO NOTE. Four rows that each do the obvious thing need no paragraph underneath; a note
    -- explaining why a control does not behave as it looks is a bug report in prose.
    --
    -- ⚠ THE FIRST ROW HAS NO TICK, and that is not an oversight. The thirteen class ticks ARE
    -- that source's switch -- unticking them all is turning class cooldowns off -- and a tick
    -- here as well was removed for causing real harm: both read off the list, so toggling it
    -- wiped and restored all forty cooldowns and silently undid whichever classes the user had
    -- turned off. See P.PIH_CooldownCounts.
    -- ⚠ A LABEL WITH THE NUMBER IN IT, rather than a second right-aligned region. The row
    -- widget is a checkbox and the toolkit sizes it; a count anchored into it would be the one
    -- hand-placed element in a column that lays itself out. Numbers need no translating.
    -- ⚠ ONE NUMBER WHEN NOTHING IS TICKED OFF, TWO WHEN SOMETHING IS. "41/41" spends a
    -- fraction on the fact that nothing has been changed; "38/41" is the whole point of
    -- showing a fraction at all. Same rule the Classes and Cooldowns header follows, so the
    -- two boxes read the same way.
    local function pihCountLabel(text, a, b)
        if b and b ~= a then return text .. "   " .. a .. "/" .. b end
        return text .. "   " .. (b or a)
    end

    local function pihSourceRow(g, t, label, on, total, get, set, link)
        local w
        if set then
            w = t.subCheck(g, pihCountLabel(label, on, total), get, set)
        else
            w = t.settingLabel(g, pihCountLabel(label, on, total))
        end
        -- ⚠ ANCHORED TO THE ROW, not placed at a y of its own. The group owns the layout and
        -- these rows flow with it; a glyph positioned against the panel would be correct until
        -- the first time a label wrapped.
        if w and link and GUI.CreateGlyphButton then
            local glyph = GUI:CreateGlyphButton(w, {
                -- ☠☠ A BOX BIGGER THAN THE ART, AND THE LABEL'S TOOLTIP HIT IS WHY (2026-09-10).
                -- Krathe: "trying to click the edit pencils is very hard like the hit detection
                -- is wrong on them."
                -- ⇒ GUI:CreateCheckbox ends with GUI:AttachTooltip(container, label, txt),
                -- which builds a motion-only hit frame over the LABEL's rect at the container's
                -- level + 5 -- and t.check re-anchors that label to the container's RIGHT edge
                -- so it wraps. So the label's hover rect covers this whole row INCLUDING this
                -- button: the pencil never got an OnEnter, never brightened, never showed its
                -- own tooltip, and hovering it raised the ROW's tooltip instead. The clicks did
                -- land (AttachTooltip's hit takes motion and explicitly not clicks -- see its
                -- own note), but a control that gives no sign it is under the cursor is a
                -- control you are guessing at, which is exactly what "hit detection is wrong"
                -- feels like from the other side.
                -- ⇒ Three parts, and all three are needed: a forgiving 26x22 box around a
                -- 14px pencil, a frame level above that hit (below), and the hit itself pulled
                -- back off the button (below) so the pencil owns its own corner of the row.
                width = 26, height = 22, iconSize = 14,
                -- ⚠ THE EDIT PENCIL, NOT THE FILTER GLYPH. The filter icon means "narrow
                -- what is listed" everywhere else in this addon -- it is what the ACTIVE
                -- INDICATORS caption uses to pick which kinds to show -- and this button
                -- opens a list for editing. Two verbs, one picture, and the wrong one:
                -- "you did not use the edit pencil you used a filter icon instead"
                -- (Krathe, 2026-09-10). Media/Icons/edit is the pencil every other
                -- edit-this affordance in the addon uses (Rename, the nickname rows).
                -- ☠ DOUBLE BACKSLASHES -- Lua 5.1 passes an unrecognised escape through as
                -- the bare character, so a single-backslash path draws nothing at all.
                texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\edit",
                color   = C_TEXT_DIM,
                tooltip = { title = L["Edit this list"], lines = { L["Open it in the Filter Designer."] } },
                onClick = link,
            })
            glyph:SetPoint("RIGHT", w, "RIGHT", -2, 0)

            -- ☠ ABOVE THE LABEL'S HIT, AND MEASURED RATHER THAN GUESSED. The hit frame's
            -- level is the container's + 5 AS IT WAS WHEN THE CHECKBOX WAS BUILT, and
            -- g:AddWidget has run since -- so "+6" from here is arithmetic on a number that
            -- may have moved. Reading both and adding one cannot be wrong.
            local base = w:GetFrameLevel() or 0
            local hit = w.dfTooltipHit
            if hit then base = max(base, hit:GetFrameLevel() or 0) end
            glyph:SetFrameLevel(base + 1)

            -- ...and the hit stops before the button. Level alone gives the pencil the hover
            -- back, but the label's rect would still be a hole the row's own tooltip fires
            -- from on the way in and out. `dfTooltipHit` is exposed for exactly this -- see
            -- UI:AttachTooltip, "a caller that needs to re-anchor it" -- and the two corners
            -- below are its own, with the right edge pulled in by the button's width plus its
            -- gap. Still anchored to the LABEL, so it keeps tracking a re-set or re-fonted one.
            if hit and w.label then
                hit:ClearAllPoints()
                hit:SetPoint("TOPLEFT", w.label, "TOPLEFT", 0, 2)
                hit:SetPoint("BOTTOMRIGHT", w.label, "BOTTOMRIGHT", -30, -2)
            end
        end
        return w
    end

    local function pihAddTriggerSources(g, t)
        local st = P.PIH_Settings()

        -- ⚠ CLASS COOLDOWNS IS NOT A ROW HERE. It lives with the class ticks that narrow
        -- it, under its own header and its own button -- Krathe, 2026-09-10: "Cooldowns
        -- should be in with the Classes and maybe should still be a button Edit Cooldowns".
        -- That box is the BASELINE (always watched, narrowed by class); these three are
        -- additions you opt into, which is what makes them a box of their own.
        -- ⚠ ENABLED / TOTAL, NOT THE CATEGORY'S SIZE, and shared with the count on the
        -- Cooldown Icons card (P.PIH_WatchedCount) so the two screens cannot report the same
        -- feature differently. See P.PIH_PresetCounts for why the raw size was wrong.
        local trink, potion = PIH_SEED.amplifiers.trinkets, PIH_SEED.amplifiers.potions
        local trinkOn, trinkAll = P.PIH_PresetCounts(trink)
        pihSourceRow(g, t, L["Trinkets"], trinkOn, trinkAll,
            function() return st.trinkets == true end,
            function(v) P.PIH_SetAmplifier("trinkets", v) end,
            function() pihOpenFilter("preset", trink) end)
        local potOn, potAll = P.PIH_PresetCounts(potion)
        pihSourceRow(g, t, L["Potions"], potOn, potAll,
            function() return st.potions == true end,
            function(v) P.PIH_SetAmplifier("potions", v) end,
            function() pihOpenFilter("preset", potion) end)
        -- ★ FOUR, NOT THIRTEEN -- AND NOW A LIST YOU CAN OPEN. `racials` is every racial
        -- ability and nine of its thirteen (Shadowmeld, Darkflight, Stoneform) are the
        -- opposite of worth infusing behind, so this row can never be that category. It used
        -- to be four ids written out in this file instead, which left it the only source with
        -- no pencil -- "racial show 4 and no edit pencil?" (Krathe, 2026-09-10). The four are
        -- the SEED of a curated list of ours now, so the row links to something that is
        -- genuinely what it means, and a racial we missed can be added to it.
        local racOn, racAll = P.PIH_RacialCounts()
        local racID = P.PIH_RacialFilterID and P.PIH_RacialFilterID()
        pihSourceRow(g, t, L["Racials"], racOn, racAll,
            function() return st.racials == true end,
            function(v) P.PIH_SetAmplifier("racials", v) end,
            racID and function() pihOpenFilter("custom", racID) end or nil)
    end

    -- ★★ THE PLAYER PICKER, MOUNTED (2026-09-10).
    -- ⚠ THE NOTE COMES FIRST, and it is the one sentence that makes an empty list readable: a
    -- picker with nothing in it looks like a filter that has been switched off, when it is
    -- actually the default and means the opposite. Everything else on this tab narrows by
    -- ticking things ON; this one narrows by having anything in it at all.
    -- ⚠ GUI:CreateCompactRosterWidget, not the pinned-frames widget. That one is 460 wide with
    -- two 224px panes and this column is ~230 -- one of its columns alone is the whole
    -- surface. The compact one is the same rows, the same role icons and class colours and the
    -- same Add-by-name field, in one list whose button toggles both ways. Krathe: "it can just
    -- be based around it... as long as it looks and functions in the same way, but is adjusted
    -- for the more narrow width".
    -- ⚠ SIZED FROM THE GROUP, NOT FROM THE PANEL. g.padding is 10 and AddWidget insets, so the
    -- widget asks the group for its own width rather than deriving one from t.noteW and being
    -- wrong the first time either number moves.
    local function pihAddPlayers(g, t)
        t.note(g, L["Empty means everyone. Add players here to watch only them."])
        if not GUI.CreateCompactRosterWidget then return end
        local w = GUI:CreateCompactRosterWidget(t.parent, {
            width = (t.noteW or 230),
            rows = 6,
            getPlayers = function() return P.PIH_Players() end,
            setPlayers = function(list) P.PIH_SetPlayers(list) end,
            -- ⚠ REBUILDS THE TAB, because the header carries the count. The widget refreshes
            -- itself for the list; this is for the number above it.
            onChange = function() t.Refresh() end,
        })
        w.fullRow = true
        -- The widget knows its own height (list + the add row); AddWidget wants it up front.
        g:AddWidget(w, (w:GetHeight() or 160) + 6)
    end

-- ★ THE ICON ASKS WHICH PICTURE, WITH PICTURES (2026-09-09).
-- ⚠ IT WAS A TICK ON THE CARD, AFTER THE FACT. Krathe: "when you add an icon it should then
-- have a graphic like we do for the other types to then pick the type i.e an actual icon or a
-- PI icon?" -- right, because those two are as different from each other as an icon is from a
-- square, and every other such choice on this grid is made by looking at it.
-- ⚠ A SECOND STEP RATHER THAN THREE ICON TILES ON THE MAIN GRID, because a signal holds one
-- effect per surface: two of them would both be "icon" and the second could never be added.
-- The choice is about one effect, so it is asked once that effect has been chosen.
-- ⚠ The tick on the effect card stays -- it is how you change your mind later without
-- deleting and re-adding.
--
-- ★★ ...AND COOLDOWN ICONS IS THE THIRD ANSWER, NOT A FOURTH TILE (2026-09-10). It stood on
-- the main grid beside Border and Square, which put a CONTAINER among a row of EFFECTS -- and
-- that mismatch is the whole of what Krathe kept hitting: it disappeared from the list it was
-- added from, it turned up under a tab that grew a moment earlier, and the tile itself
-- vanished once one existed. "I think for icon it would be best to have a sub menu so you
-- click Icon then it has PI Icon, Cooldown Icons, and the other icon choices?"
-- ⇒ Three icon answers on two axes -- HOW MANY (one effect, or one per cooldown up) and WHAT
-- PICTURE (always Power Infusion, or the buff they used). The fourth cell is nonsense: four
-- identical Power Infusion icons in a row. So: three tiles, behind Icon, and the difference
-- between a container and an effect stops being the user's problem.
local pihAddPick = nil   -- nil = the surface grid, "icon" = the art choice

-- ── EXAMPLE ART FOR THE TWO TILES WHOSE PICTURE IS NOT KNOWN IN ADVANCE ──
-- ★ REAL COOLDOWNS, NOT QUESTION MARKS (2026-09-10). Krathe: "can we get the preview card
-- here to actually show some example icons instead of ??"
-- ☠ AND THE PLACEHOLDER WAS DEFENSIBLE RIGHT UP TO THE POINT IT WAS LOOKED AT. The designer's
-- add flow asks for a TYPE first and a SPELL second, so its tiles genuinely have no artwork to
-- show yet and the `?` is honest there -- I argued the same for these, since the helper's
-- picture really is unknown until a cooldown matches. But a tile is a picture of what the
-- thing LOOKS like, and three question marks in a row is a picture of an error. The unknown
-- is WHICH cooldown, never WHETHER there is art.
-- ⚠ FROM THE SEED, NOT FROM THE LIVE LIST, and sorted. The user's list moves with the class
-- ticks, so sampling it would make these tiles change picture when someone unticked Warrior --
-- a tile is not a live readout. Sorting makes the choice the same on every client and every
-- build rather than whatever pairs() said first.
-- ⚠ ONLY IDS THE CLIENT CAN DRAW. GetSpellTexture returns nil for a spell whose data is not
-- cached, and one `?` standing among two real icons reads worse than three of them.
local function pihExampleSpellIDs(n)
    local ids = pihSeedIDs()
    table.sort(ids)
    local out = {}
    for _, sid in ipairs(ids) do
        if C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(sid) then
            out[#out + 1] = sid
            if #out >= n then break end
        end
    end
    return out
end

-- ── A ROW OF ICONS, AS THE GROUP ACTUALLY DRAWS ONE ──
-- ☠ THE "HOW MANY" AXIS IS THE ONE PROSE KEEPS FAILING AT, which is why it is drawn. The
-- Cooldown Icons tile used to paint the single-icon thumbnail, so the tile that means "one per
-- cooldown" was a picture of one icon -- the two answers it had to be told apart from looked
-- identical to it.
-- ⚠ THE GROUP'S OWN GEOMETRY, not a decorative row: TOPRIGHT, growing LEFT, at the spacing
-- P.PIH_AddIconGroup creates it with. If those defaults change, this picture is wrong and
-- should be changed with them.
-- ⚠ `ids` IS A LIST OF EXAMPLE SPELLS (pihExampleSpellIDs), one per slot. Short or empty is
-- fine -- a slot with no id falls back to the designer's placeholder, which is what a client
-- that has not cached those spells yet will show, and it is still a row of the right length.
local function PaintIconRowOnThumb(pv, ids, n)
    local mock = pv.mockFrame
    if not mock then return end
    local size = (TYPE_DEFAULTS and TYPE_DEFAULTS.icon and TYPE_DEFAULTS.icon.size) or 24
    local SPACING = 2
    for i = 1, (n or 3) do
        local x = -((i - 1) * (size + SPACING))
        local ring = mock:CreateTexture(nil, "OVERLAY", nil, 1)
        ring:SetColorTexture(0, 0, 0, 0.85)
        ring:SetSize(size + 2, size + 2)
        ring:SetPoint("TOPRIGHT", mock, "TOPRIGHT", x, 0)
        local ico = mock:CreateTexture(nil, "OVERLAY", nil, 2)
        ico:SetSize(size, size)
        ico:SetPoint("CENTER", ring, "CENTER", 0, 0)
        local sid = ids and ids[i]
        local tex = sid and C_Spell and C_Spell.GetSpellTexture
            and C_Spell.GetSpellTexture(sid) or nil
        ico:SetTexture(tex or DEFAULT_TILE_ICON)
        ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    -- ⚠ pv.spellIcon IS DELIBERATELY NOT PUBLISHED. It is the handle the designer's add pane
    -- swaps a chosen spell's art through, and this tile has no single spell to swap in -- the
    -- point of it is that the pictures are whatever they each turn out to be.
end

local function pihBuildAddTiles(parent, yPos, Refresh)
    local tc = GetThemeColor()
    local CW = (parent:GetWidth() or 320) - 16
    local TILE_COLS, TILE_GAP = 3, 7
    local TILE_W = math.floor((CW - TILE_GAP * (TILE_COLS - 1)) / TILE_COLS)

    -- ── THE HEADING, AND ON STEP 2 THE WAY BACK OUT ──
    -- ☠ AN ✕ ON THE HEADING ROW, NOT A "Back" BUTTON UNDER THE GRID. Krathe, 2026-09-10:
    -- "no back use X like we do on the other AD effects." The designer's OWN picker is
    -- directly above this function (S.BuildEffectsHeadArea's S.effectsPicker arm): a head
    -- frame with the question on the left and GUI:CreateCloseButton on the right, captioned
    -- there as "the only way out that does not commit to anything". This is the same
    -- question in the same place, so it is the same control -- and a Back button was a
    -- second vocabulary for leaving invented for one grid.
    -- ⚠ TWO SHAPES, ONE PER STEP. Step 1 is a section CAPTION -- small-caps, dim, no way out
    -- because there is nothing to leave -- and step 2 is a PICKER HEAD, in the picker's own
    -- font and colour. Sharing one fontstring made step 2 quietly the wrong kind of object.
    if pihAddPick then
        local head = CreateFrame("Frame", nil, parent)
        head:SetHeight(22)
        head:SetPoint("TOPLEFT", 8, yPos)
        head:SetPoint("RIGHT", parent, "RIGHT", -8, 0)

        local headText = head:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        headText:SetPoint("LEFT", 0, 0)
        headText:SetText(L["Which icon?"])
        headText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

        local close = GUI:CreateCloseButton(head, { size = 18, iconSize = 11 })
        close:SetPoint("RIGHT", 0, 0)
        close:SetScript("OnClick", function()
            pihAddPick = nil
            if Refresh then Refresh() end
        end)
        yPos = yPos - 26
    else
        local head = parent:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(head, 9, "")
        head:SetPoint("TOPLEFT", 8, yPos)
        head:SetText(L["ADD AN INDICATOR"])
        head:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        yPos = yPos - 18
    end

    -- ⚠ ONE LAYOUT FOR BOTH STEPS. The grid is the same shape whichever question is being
    -- asked, so it is written once and fed a list -- the alternative is two flow blocks that
    -- drift apart in tile size and spacing.
    local function grid(items, y)
        local rowTop, rowH = y, 0
        for i, it in ipairs(items) do
            local col = (i - 1) % TILE_COLS
            local tile = CreateFrameTile(parent, {
                width   = TILE_W,
                label   = it.label,
                accent  = it.accent or tc,
                -- ⚠ THE REASON IT IS OFF GOES IN THE TOOLTIP, second line, so the tile still
                -- answers the question a greyed control always raises. See `taken` below.
                tooltip = { title = it.label, lines = { it.desc, it.taken } },
                Paint   = it.Paint,
                onClick = it.onClick,
            })
            -- ☠ GREYED, NOT REMOVED, and the Cooldown Icons tile is why. It used to be
            -- dropped from the grid the moment one existed, so adding it made the thing you
            -- had just clicked disappear -- half of "it's confusing when you add Cooldown
            -- Icons from effects". A tile that stays put and says why it is off tells you
            -- where your thing went; a tile that vanishes tells you nothing.
            if it.taken then tile:SetTileState("disabled") end
            tile:SetPoint("TOPLEFT", 8 + col * (TILE_W + TILE_GAP), rowTop)
            rowH = math.max(rowH, tile.layoutHeight or 72)
            if col == TILE_COLS - 1 or i == #items then
                rowTop = rowTop - (rowH + TILE_GAP)
                rowH = 0
            end
        end
        return rowTop - 4
    end

    -- What the helper is already wearing. Read once and used by both steps: step 1 needs it to
    -- decide whether Icon has anything left to offer, step 2 to grey the answers it has.
    local held = {}
    for _, s in ipairs(P.PIH_SurfacesOf("burst")) do held[s] = true end
    local hasGroup = (P.PIH_IconGroup and P.PIH_IconGroup()) and true or false

    -- ── STEP 2: WHICH ICON ──
    -- Three answers, and the two axes they differ on are in this function's header note.
    if pihAddPick == "icon" then
        local function add(showsAura)
            local ok, why = P.PIH_AddSurface("burst", "icon", showsAura)
            if not ok then DF:DebugWarn("AURADESIGNER",
                "PIH: could not add the icon -- %s", tostring(why)) end
            pihAddPick = nil
            if Refresh then Refresh() end
        end
        local accent = BADGE_COLORS.icon or tc
        -- Sampled ONCE for both tiles, so the single icon is the first of the row rather than
        -- an unrelated fourth spell -- the tiles differ in HOW MANY, and picking different art
        -- for each would put a second difference in the picture that means nothing.
        local egIDs = pihExampleSpellIDs(3)
        -- ★ ONE `taken` EACH, BECAUSE THEY ARE TWO EFFECTS NOW (2026-09-10). They used to share
        -- one: the icon surface held a single record and which picture it wore was a tick on
        -- its card, so adding either spent both. Krathe: "we can't add Power Infusion and Their
        -- CD at the same time, we should allow this if we can?" We can -- placed instances are
        -- per-id -- so each tile greys only when ITS OWN art is already on the frame.
        -- ⚠ The tick on the effect card stays and still switches one icon's picture. It is how
        -- you change your mind about an icon you have; these tiles are how you get a second.
        local pinnedHeld, dynamicHeld = P.PIH_IconArtHeld("burst")
        local alreadyAdded = L["Already added. Remove it from the list below to change it."]
        yPos = grid({
            { label = L["Power Infusion"], accent = accent,
              taken = pinnedHeld and alreadyAdded or nil,
              desc  = L["The same picture on everyone worth infusing."],
              Paint = function(pv) PaintEffectOnThumb(pv, "icon", PIH_PI_SPELL_ID) end,
              onClick = function() add(false) end },
            -- ⚠ AN EXAMPLE COOLDOWN, NOT A PINNED ONE. It goes through the same staticSpellID
            -- parameter the tile above uses, and means something different: there the art IS
            -- what you will get, here it is one of the things you might. The label and the
            -- description carry that; a question mark carried nothing. See pihExampleSpellIDs.
            { label = L["Their cooldown"], accent = accent,
              taken = dynamicHeld and alreadyAdded or nil,
              desc  = L["The buff they actually used — one of them, if several are up at once."],
              Paint = function(pv) PaintEffectOnThumb(pv, "icon", egIDs[1]) end,
              onClick = function() add(true) end },
            -- ★ THE CONTAINER, AS THE THIRD ANSWER TO "WHICH ICON". It can stand beside the
            -- other two here in a way it never could on the main grid: there the question was
            -- "which kind of indicator", and a group is not one.
            { label = L["Cooldown Icons"], accent = accent,
              taken = hasGroup and L["Already added. Remove it from the list below to change it."] or nil,
              desc  = L["One icon per cooldown they have up, each showing its own."],
              Paint = function(pv) PaintIconRowOnThumb(pv, egIDs, 3) end,
              onClick = function()
                  local ok, why = P.PIH_AddIconGroup()
                  if not ok then DF:DebugWarn("AURADESIGNER",
                      "PIH: could not add the cooldown icons -- %s", tostring(why)) end
                  pihAddPick = nil
                  if Refresh then Refresh() end
              end },
        }, yPos)
        -- ⚠ NOTHING UNDER THE GRID. The way out is the ✕ on the heading above -- see the
        -- note there for why this stopped being a Back button.
        return yPos
    end

    -- ── STEP 1: WHICH KIND OF INDICATOR ──
    -- ⚠ FILTERED TO WHAT THE HELPER CAN DO. Sound is left out -- it is not a surface and has
    -- its own box below -- and so is a type the signal already holds: an add button that
    -- cannot add is the lying control this panel keeps being cleaned of.
    local items = {}
    for _, eff in ipairs(P.AddFlowEffects and P.AddFlowEffects() or {}) do
        local isIcon = eff.type == "icon"
        -- ☠ ICON SURVIVES ITS OWN SURFACE BEING TAKEN, and no other type does. Behind it are
        -- THREE answers -- two arts and the group -- so hiding the tile the moment ONE icon
        -- exists would hide the door to the other two. It goes when all three are spent, and
        -- not before.
        local exhausted
        if isIcon then
            local pinnedHeld, dynamicHeld = P.PIH_IconArtHeld("burst")
            exhausted = pinnedHeld and dynamicHeld and hasGroup
        else
            exhausted = held[eff.type]
        end
        if eff.type ~= "sound" and not exhausted then
            local capturedType = eff.type
            items[#items + 1] = {
                label  = eff.label,
                accent = BADGE_COLORS[eff.type] or tc,
                -- The Icon tile opens a choice now rather than describing one behaviour.
                desc   = isIcon and L["Power Infusion, their cooldown, or one per cooldown they have up."] or eff.desc,
                Paint  = function(pv)
                    PaintEffectOnThumb(pv, capturedType, isIcon and PIH_PI_SPELL_ID or nil)
                end,
                onClick = function()
                    if isIcon then
                        pihAddPick = "icon"
                        if Refresh then Refresh() end
                        return
                    end
                    local ok, why = P.PIH_AddSurface("burst", capturedType)
                    if not ok then DF:DebugWarn("AURADESIGNER",
                        "PIH: could not add %s -- %s", tostring(capturedType), tostring(why)) end
                    if Refresh then Refresh() end
                end,
            }
        end
    end

    if #items == 0 then
        -- Everything is in use. Not an error and not empty: say so rather than drawing a
        -- caption over nothing.
        local none = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        none:SetPoint("TOPLEFT", 8, yPos)
        none:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
        none:SetJustifyH("LEFT")
        none:SetText(L["Every indicator is already in use. Remove one below to add it again."])
        none:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.8)
        return yPos - (max(none:GetStringHeight(), 12) + 10)
    end

    return grid(items, yPos)
end

-- ── SOUND, WHICH IS NOT A SURFACE ──
-- ☠ IT HAS NO TILE AND NO EFFECT CARD, AND THAT IS NOT AN OVERSIGHT. The generic effects
-- list refuses to show `sound` on a filter-owned record -- the native path registers per
-- spell id, so one big filter would mean one registration per spell in it -- which means it
-- offers no row and no delete button for it either. So the helper owns the control outright.
-- ⚠ IT WAS UNREACHABLE FOR A DAY. It lived at the foot of pihBuildEffectsTab, and that
-- function stopped being called when the helper became a pool tab -- a setting removed from
-- the UI as a side effect of a layout change, with nothing saying so. Same fault the icon
-- ticks had, found the same way: by asking what USED to call the thing being deleted.
local function pihBuildSoundBox(parent, yPos, Refresh)
    local t = pihMakeTools(parent, { Refresh = Refresh, indent = 8 })
    return t.group(L["Sound Alert"], pihAddSound, yPos)
end

-- The two halves the designer's Effects tab mounts, in the order it mounts them.
-- One entry point rather than two exports, because the caller (S.BuildEffectsHeadArea) has
-- one place to put them and no business knowing the helper has two pieces.
S.BuildPIHelperAddArea = function(parent, yPos, Refresh)
    yPos = pihBuildAddTiles(parent, yPos, Refresh)
    return pihBuildSoundBox(parent, yPos, Refresh)
end

-- ── THE TRIGGERS TAB ──
-- ☠ S.PIH_TABS LIVED HERE AND IS GONE. It named the helper's own two tabs back when the
-- helper had a tab bar of its own; the designer's sub-tab strip is that bar now -- Triggers
-- and Effects ARE its Global and Effects tabs, relabelled and reordered on this pool (see
-- P.SubTabDefs). A second list of the same two tabs could only ever drift from the strip
-- actually on screen.
-- ⚠ AND SO IS THE `tab` ARGUMENT. This function had an else-branch that built a private
-- copy of the Effects tab (pihBuildEffectsTab); the designer's own Effects tab does that job
-- now and the helper contributes S.BuildPIHelperAddArea to it. What is left here is one tab's
-- worth of settings -- the Triggers -- so it no longer has to be told which one.
-- ⚠ THE CARD IS NOT HERE EITHER. The enable banner turns the whole feature on, so it cannot
-- sit inside one of the things it governs; S.BuildPIHelperCard draws it above.
-- ⚠ Returns the running y, exactly as before, so the caller keeps owning the layout.
S.BuildPIHelperBody = function(parent, opts)
    opts = opts or {}
    local yPos = opts.startY or 0
    local t = pihMakeTools(parent, opts)

    do
        -- ⚠ THE GATE LIVES HERE, not with the effects. "Hide the helper while your own Power
        -- Infusion is on cooldown" is not a display choice -- it is a condition on whether
        -- the helper has anything to say at all, which is what a trigger is.
        -- ⚠ "Roles", NOT "Triggers" (Krathe, 2026-09-09). The box was named after the TAB it
        -- sits on, so the Triggers tab opened with a box captioned Triggers -- a heading that
        -- repeats its own parent tells you nothing, and the one thing it could have told you
        -- (that this box is the ROLE filter) was the thing it left out.
        -- ⚠ THE COOLDOWN GATE STAYS IN IT, and that was already argued: see the long note in
        -- pihAddGateAndNotes -- a whole titled group around a single checkbox is more chrome
        -- than the setting is worth, and "Show when Power Infusion is on Cooldown" says what
        -- it does without a header to lean on. That note names this exact case as the test for
        -- a control living under a heading that does not quite describe it, and records why
        -- the label names the spell rather than implying it.
        yPos = t.group(L["Roles"], function(g)
            pihAddRoles(g, t)
            pihAddGateAndNotes(g, t)
        end, yPos)

        -- ☠ COLLAPSIBLE, AND THIRTEEN ROWS IS WHY. Everything else in this panel is
        -- two or three ticks; a class list is as long as the game has classes, and
        -- most people will never open it.
        -- ⚠ NO showSummary. The collapsed summary concatenates every child label,
        -- which for thirteen classes and a two-line note is a wall of text rather
        -- than a summary. The header alone says what is folded away, which is what
        -- a summary was for.
        -- ☠ NO SECOND FILTER LINK ANYWHERE. There is exactly one, at the foot of the second
        -- box, and it uses GUI:OpenFilterInDesigner -- which switches the page AND scrolls to,
        -- selects and pulses the filter. A bare SelectTab beside it once gave the page two
        -- buttons to the same place, one of them the worse version: a hand-written jump "landed
        -- you on the page with nothing indicated, which is indistinguishable from a broken
        -- link". Krathe, 2026-09-08: "We seem to have two links to it? and confusing messaging."

        -- ★★ THE BASELINE FIRST, THEN WHAT YOU ADD TO IT.
        -- ☠ THESE WERE ONE BOX AND THE ORDER SAID THE OPPOSITE OF THE TRUTH: thirteen class
        -- ticks, then a list of four sources, when the classes reach only ONE of them -- trinkets
        -- and potions are items with no class, and racials are tagged class = "ALL". Krathe read
        -- the layout and asked exactly that: "the classes, they only effect the Cooldowns
        -- correct?"
        -- ⚠ SO THE CLASS COOLDOWNS LIVE WITH THEIR CLASSES. The box is the whole of that
        -- source: the ticks that narrow it, the note, and the button that edits it. The three
        -- sources nothing narrows are additions, in a box that says so.
        -- ⚠ THE COUNT IS ON THIS HEADER because the source has no row of its own -- see
        -- P.PIH_CooldownCounts for why a tick here was redundant AND harmful. Shown as a
        -- fraction only when some are switched off, the same rule the Filter Designer follows.
        -- ⚠ COLLAPSIBLE: thirteen rows is the one list on this panel nobody can scan, and most
        -- people will never open it.
        local cdOn, cdTotal = P.PIH_CooldownCounts()
        local cdHead = L["Classes and Cooldowns"] .. "   "
            .. ((cdOn == cdTotal) and tostring(cdTotal) or (cdOn .. "/" .. cdTotal))
        yPos = t.group(cdHead, function(g)
            pihAddClasses(g, t)
        end, yPos, { collapsible = true, collapseKey = "pihelper:onlywatch" })

        yPos = t.group(L["Additional Filters"], function(g)
            pihAddTriggerSources(g, t)
        end, yPos)

        -- ★★ NAMED PLAYERS, LAST, AND COLLAPSED (2026-09-10). Krathe: "in guild groups it
        -- would be useful to only have the PI alert for the DPS you know who should be getting
        -- PI instead of every DPS in the raid who uses a CD."
        -- ⚠ LAST, BECAUSE IT IS THE NARROWEST THING ON THE TAB. Every box above answers "what
        -- makes this fire"; this one answers "and for whom", which only means anything once
        -- the rest is settled. It is also the only one most people will never touch.
        -- ⚠ COLLAPSIBLE, like the class list and for the same reason: a roster is as long as
        -- the raid, and an empty allowlist is the default.
        -- ⚠ THE COUNT IS ON THE HEADER, so the box says whether it is doing anything while
        -- shut -- which is the whole question about a folded filter. No count means no list
        -- means everyone, and the note inside says so in words.
        local pn = #P.PIH_Players()
        local pHead = L["Players"] .. (pn > 0 and ("   " .. pn) or "")
        yPos = t.group(pHead, function(g)
            pihAddPlayers(g, t)
        end, yPos, { collapsible = true, collapseKey = "pihelper:players" })
    end

    return yPos
end

-- ☠ EXTRACTED, NOT COPIED. The popout layout's row page (AuraDesigner/UI/Rows.lua)
-- mounts exactly this furniture above its band of effect rows. The add flow is a
-- later phase of the designer rework, and a second copy of it here would be a
-- second place to change when that phase lands -- which is how the three
-- duplicated FRAME_ITEMS lists below came about in the first place.
--
-- Returns the y the caller should continue at, and `true` when the picker has
-- taken the column over, in which case the caller must add nothing below it.
S.BuildEffectsHeadArea = function(parent, yPos, opts)
    local tc = GetThemeColor()
    -- ☠ opts.skipAddBlock: THE ROW LAYOUT HAS NO ADD BLOCK ON THE PAGE. Phase 5
    -- moved the three scope cards and the picker column they open into the panel
    -- behind one "+ Add Indicator" row (S.BuildAddIndicatorPane above). The split
    -- panel still draws the block: it is the one surface with 230px to spend on
    -- standing furniture.
    local skipAdd = opts and opts.skipAddBlock or false
    -- ☠ opts.skipChips: THE ROW LAYOUT'S FILTER IS NOT A CHIP FLOW. The eight
    -- chips live in a popout there, so in that layout this function draws only the
    -- ACTIVE INDICATORS caption and the Any Buff hint -- and, with the one flowing
    -- element gone, it reports a height that cannot be wrong. See
    -- S.BuildFilterChips above for the chips themselves.
    local skipChips = opts and opts.skipChips or false
    -- ⚠ opts.filterGlyph: ...AND THE WAY IN TO THEM RIDES THE CAPTION. A row of
    -- its own cost 50px for a single filter; a glyph on a caption the page already
    -- pays for costs nothing. Opt-in, so the split panel keeps its chips.
    local filterGlyph = opts and opts.filterGlyph or false

    -- ☠ THE WIDTH THIS AREA LAYS OUT AGAINST, DERIVED RATHER THAN MEASURED. Every
    -- object below is anchored 8px inside the host on both sides, so the column
    -- they share is the host's own width less 16 -- and the host was given an
    -- explicit width by the caller a line before this ran. Reading it off a CHILD
    -- instead (the chip row's own GetWidth) asks a frame the layout pass has not
    -- reached yet, which is what made the chips flow at a hardcoded 260 and the
    -- head area report a height for a shape it was never going to have.
    local hostW = parent:GetWidth() or 0
    local COL_W = (hostW > 40) and (hostW - 16) or nil

    -- ══ ADDING AN INDICATOR ══════════════════════════════════════════════
    -- Was a "+ Add Indicator" button opening a 14-row dropdown across three
    -- headed sections. Two problems that a flat card list would have made
    -- WORSE, not better: fourteen entries is a long column at card height, and
    -- the "from a filter" section repeats five labels from the section above it
    -- word for word -- only the heading told them apart.
    --
    -- So the choice is split in two. Three pinned scope cards say what KIND of
    -- change you want; picking one takes the column over with just that scope's
    -- options, each with room for a description. No duplicate labels can appear,
    -- because a scope is settled before any type is shown.
    -- ONE definition, two layouts: the panel above and this block build their
    -- cards from the same three lists, so a type added to one appears in both.
    local SCOPES = AddFlowScopes()

    -- The picker is a transient mode, so it must not outlive the thing it was
    -- opened against. Anything that changes which pool or spec is on screen
    -- rebuilds this tab, and the context check below drops a stale picker on
    -- that rebuild rather than leaving the player staring at options for a pool
    -- they have already left.
    -- ⚠ THE POOL KEY, NOT IsOtherTab(). That predicate answers true for BOTH the Any Buff and
    -- the Power Infusion Helper pools, so a picker opened on one survived a switch to the
    -- other -- the designer's spell-picker column drawn over a pool that has no spell to pick.
    -- The context has to change whenever the thing it was opened against changes, and the pool
    -- key is that thing.
    local pickerCtx = tostring(S.activeBuffTab) .. "|" .. tostring(ResolveSpec())
    if S.effectsPicker and S.effectsPickerCtx ~= pickerCtx then
        S.effectsPicker = nil
    end

    local function StartType(itemType, scope, anchor)
        S.effectsPicker = nil
        if scope == "filter" then
            -- The effect hangs off the FILTER: its record is stored under the
            -- "@preset:"/"@custom:" key, which DF:BuildADIdentityFilters resolves
            -- to the filter's whole spell set. Nothing downstream changes.
            OpenFilterPicker({
                anchor = anchor,
                isLinked = function(kind, key)
                    local ref = DF:MakeADFilterRef(kind, key)
                    return ref ~= nil and HasFrameEffect(ref, itemType) or false
                end,
                onPick = function(kind, key)
                    local ref = DF:MakeADFilterRef(kind, key)
                    if not ref then return end
                    AddPickedSpell(ref, itemType, "frame")
                    S.SwitchTab("effects")
                    RefreshPlacedIndicators()
                    RefreshPreviewEffects()
                end,
            })
            return
        end
        OpenIndicatorPicker(itemType, scope)
    end

    -- ── PICKER MODE: the column belongs to one scope's options ──
    -- ...and the row layout never enters it. Its scope cards live in a panel, so
    -- nothing on that page can set S.effectsPicker; the guard is belt and braces
    -- against the flag being left set by a visit to the split panel.
    if S.effectsPicker and not skipAdd then
        local scope = SCOPES[S.effectsPicker]
        local scopeKey = S.effectsPicker

        local head = CreateFrame("Frame", nil, parent)
        head:SetHeight(22)
        head:SetPoint("TOPLEFT", 8, yPos)
        head:SetPoint("RIGHT", parent, "RIGHT", -8, 0)

        local headText = head:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        headText:SetPoint("LEFT", 0, 0)
        headText:SetText(scope.title)
        headText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

        -- The only way out that does not commit to anything.
        local close = GUI:CreateCloseButton(head, { size = 18, iconSize = 11 })
        close:SetPoint("RIGHT", 0, 0)
        close:SetScript("OnClick", function()
            S.effectsPicker = nil
            S.SwitchTab("effects")
        end)
        yPos = yPos - 26

        for _, item in ipairs(scope.items) do
            local bc = BADGE_COLORS[item.type]
            local capturedType = item.type
            -- Sound changes nothing on the frame, so it gets the untouched mock
            -- frame -- which is the honest picture of what it does.
            local art = (item.type ~= "sound")
                and { kind = item.type, color = { bc.r, bc.g, bc.b } } or nil
            local card = GUI:CreateChoiceCard(parent, {
                title = item.label, desc = item.desc, art = art, accent = bc,
                width = COL_W,
                onClick = function(self) StartType(capturedType, scopeKey, self) end,
            })
            card:SetPoint("TOPLEFT", 8, yPos)
            card:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
            yPos = yPos - (card.layoutHeight + 6)
        end

        parent:SetHeight(max(-yPos + 20, 200))
        return yPos, true
    end

    -- ── THE HELPER'S POOL: TILES, NOT SCOPE CARDS ──
    -- ☠ THE THREE SCOPE CARDS ANSWER A QUESTION THIS POOL HAS ALREADY ANSWERED. Placed /
    -- Frame-Level / From a Filter all end in "now pick a spell", and the helper's spell is the
    -- cooldown list its Triggers tab owns. Offering the picker here would let someone hang a
    -- helper effect off a spell of their own, which is not a helper effect at all -- it is an
    -- Any Buff effect that happens to have been created from the wrong tab.
    -- ⚠ EVERYTHING BELOW THIS BRANCH IS SHARED, and that is the point. The ACTIVE INDICATORS
    -- caption, the type filter and the effect cards under it are the designer's own, so the
    -- helper's list looks and behaves exactly like the designer's list -- which is what Krathe
    -- asked for three times: "It should BE AD not a copy of it."
    if not skipAdd and IsPIHelperTab() and S.BuildPIHelperAddArea then
        yPos = S.BuildPIHelperAddArea(parent, yPos, function() S.SwitchTab("effects") end)
        yPos = yPos - 4
    elseif not skipAdd then

    -- ── NORMAL: three pinned scope cards ──
    local addBlock = GUI:CreateChoiceCardGroup(parent, {
        title    = L["ADD AN INDICATOR"],
        accent   = tc,
        width    = COL_W,
        onToggle = function() S.SwitchTab("effects") end,
        cards = {
            {
                title = SCOPES.placed.title, desc = SCOPES.placed.desc,
                art   = { kind = "icon", color = { tc.r, tc.g, tc.b } },
                onClick = function()
                    S.effectsPicker, S.effectsPickerCtx = "placed", pickerCtx
                    S.SwitchTab("effects")
                end,
            },
            {
                title = SCOPES.frame.title, desc = SCOPES.frame.desc,
                art   = { kind = "border", color = { tc.r, tc.g, tc.b } },
                onClick = function()
                    S.effectsPicker, S.effectsPickerCtx = "frame", pickerCtx
                    S.SwitchTab("effects")
                end,
            },
            {
                -- Filter green, the colour Aura Filters owns everywhere else: the
                -- effects are identical to the card above, only the source differs.
                title = SCOPES.filter.title, desc = SCOPES.filter.desc,
                art   = { kind = "border", color = { 0.51, 0.86, 0.51 } },
                onClick = function()
                    S.effectsPicker, S.effectsPickerCtx = "filter", pickerCtx
                    S.SwitchTab("effects")
                end,
                -- The ONLY card in this block about filters, which is why the route
                -- to the library is here and not on the block header.
                --
                -- ⚠ The filter glyph, not the edit pencil, and no filter argument.
                -- Nothing is chosen yet on this card -- it creates an effect and then
                -- asks which filter -- so there is no "this filter" to open. The
                -- pencils elsewhere target one named filter; this opens the library.
                -- Same distinction the tooltip draws.
                action = {
                    -- ☠ Extension included: CreateChoiceCard concatenates this onto
                    -- the Icons path verbatim, and a PNG needs it.
                    icon    = "filter_list.png",
                    tooltip = {
                        title = L["Manage Filters"],
                        lines = { L["Build and edit your buff filters in the Filter Designer."] },
                    },
                    onClick = function()
                        if GUI.OpenFilterInDesigner then GUI:OpenFilterInDesigner() end
                    end,
                },
            },
        },
    })
    addBlock:SetPoint("TOPLEFT", 8, yPos)
    addBlock:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    yPos = yPos - (addBlock.layoutHeight + 10)
    end

    -- ── POWER INFUSION HELPER: MOVED OUT, 2026-09-08 ──
    -- ☠ DO NOT MOUNT IT HERE AGAIN. The helper now has its own page beside the designer
    -- (Auras > Power Infusion Helper -- see AuraDesigner/UI/PIHelperPage.lua and the
    -- CreateSubTab in GUI/Pages/Auras.lua). Krathe's call, 2026-09-08: the settings were
    -- "not very clear how to use it or even how to find it", and the behaviour panel and
    -- the appearance of the records it creates were on opposite ends of one page.
    --
    -- ⚠ WHAT DID NOT CHANGE, so nobody re-derives it from an empty space: the helper's
    -- records still live in THIS pool. The pool a record lives in decides its caster filter
    -- before anything else -- My Buffs means "auras I cast", and poolFilter returns that
    -- before it ever consults othersOnly -- and the helper watches OTHER people's
    -- cooldowns, so Any Buff remains the only pool where it can match anything. That is
    -- plumbing now; the user is never asked to know it.
    -- ⚠ The builders are still HERE (S.BuildPIHelperCard / S.BuildPIHelperBody and the
    -- section bodies, above). Only the MOUNT moved. The page composes them.

    -- ── ACTIVE INDICATORS heading ──
    local activeHeader = parent:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(activeHeader, 9, "")
    activeHeader:SetPoint("TOPLEFT", 8, yPos)  -- align with chips/cards/add button
    activeHeader:SetText(L["ACTIVE INDICATORS"])
    activeHeader:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    -- ── THE FILTER GLYPH, ON THAT CAPTION ──
    if filterGlyph then
        -- ☠ A FILTER THAT LOOKS THE SAME WHETHER IT IS ON OR OFF IS HOW PEOPLE
        -- LOSE THEIR WORK. Showing only Borders hides seven kinds of indicator,
        -- and a glyph identical to the one that means "showing everything" reads
        -- as "they have been deleted". So the ACTIVE state is said TWICE: the
        -- glyph goes accent, and the filter's own name is written beside it.
        -- Neither alone survives a glance.
        local active = (S.activeFilter or "all") ~= "all"
        local glyph = GUI:CreateGlyphButton(parent, {
            size = 18, iconSize = 14,
            -- ☠ DOUBLE BACKSLASHES. Lua 5.1 passes an unrecognised escape through
            -- as the bare character, so the single-backslash form is a path to
            -- nothing and the client draws an empty square. It does not error,
            -- which is why it shipped once; run.py bans it now.
            texture = FILTER_ICON,
            color   = active and tc or C_TEXT_DIM,
            tooltip = {
                title = L["Showing"],
                lines = {
                    L["Which kinds of indicator are listed below."],
                    active and format(L["Showing: %s"], ActiveFilterLabel()) or nil,
                },
            },
            onClick = OpenFilterPopout,
        })
        -- The 18px button centred on an ~11px caption line: yPos is the caption's
        -- TOP, so lifting the button by half the difference lands the two centres
        -- together. It still sits inside the 16px the caption spends below.
        glyph:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, yPos + 4)
        -- ☠ THE PANEL IS DOCKED TO THIS BUTTON, so it goes when this button does.
        -- Picking a chip rewrites the list, which rebuilds the page and retires
        -- the glyph underneath it -- and a panel left up would be following a
        -- frame that is no longer on screen. Same bargain the Preview Scale glyph
        -- strikes with its canvas.
        glyph:HookScript("OnHide", function()
            local pop = S.filterPopout
            if pop and not pop.closed then pop:Close("source") end
        end)

        local name
        if active then
            name = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            name:SetPoint("RIGHT", glyph, "LEFT", -4, 0)
            name:SetText(ActiveFilterLabel())
            name:SetTextColor(tc.r, tc.g, tc.b)
        end

        -- ⚠ GREY WITH THE REST OF THE PAGE. The `Showing` row this replaces
        -- carried a disableOn and went dim with every other row when the designer
        -- is off; a glyph that stayed lit would be the one live control on a page
        -- of dead ones. The kit's SetGlyphEnabled does all three halves of it --
        -- clicks off, hover off, the 0.4 dim -- and the name beside it follows.
        if opts and opts.filterGlyphEnabled == false then
            glyph:SetGlyphEnabled(false)
            if name then name:SetAlpha(0.4) end
        end
    end
    yPos = yPos - 16

    -- ── FILTER CHIPS (wrapping layout, split panel only) ──
    -- ☠ AND THE HEIGHT COMPENSATION IS GONE WITH THEM, NOT MOVED. Section 17's
    -- Class 1 -- a height measured before layout and then spent -- had two halves
    -- here: flow against a width DERIVED from the host, and re-report through the
    -- band host's own height verb when it changed anyway. Only the BAND layout
    -- ever carried that verb, and the band layout no longer builds chips, so the
    -- re-report had no host left to reach. The split panel scrolls a fixed-width
    -- column and never had the problem: it re-flows, and nothing below it moves.
    local chipsFrame
    if not skipChips then
        chipsFrame = CreateFrame("Frame", nil, parent)
        chipsFrame:SetPoint("TOPLEFT", 8, yPos)
        chipsFrame:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
        local Relayout = S.BuildFilterChips(chipsFrame, COL_W)
        chipsFrame:SetScript("OnSizeChanged", function(_, w) Relayout(w) end)
        yPos = yPos - (chipsFrame:GetHeight() + 10)
    end

    -- ── OTHER BUFFS HINT ──
    -- ⚠ ANCHORED UNDER THE CHIP ROW where there is one, not at a y the chips'
    -- first pass happened to produce. It is the one thing below a wrapping element
    -- in this area, so it is also the one thing a re-wrap would otherwise strand.
    -- ⚠ NOT ON THE HELPER'S POOL. "These indicators trigger no matter who casts the buff" is
    -- a true statement about the STORE and a misleading one about this tab: the helper's
    -- caster rule is Others Only, set per effect by the recipe, and its Triggers tab is where
    -- the user is told what makes it fire. A sentence about a rule the user did not choose
    -- and cannot see reads as a rule they are being warned about.
    local obHint
    if IsOtherTab() and not IsPIHelperTab() then
        obHint = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        if chipsFrame then
            obHint:SetPoint("TOPLEFT", chipsFrame, "BOTTOMLEFT", 0, -10)
        else
            obHint:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, yPos)
        end
        obHint:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
        obHint:SetJustifyH("LEFT")
        obHint:SetWordWrap(true)
        obHint:SetText(L["These indicators trigger no matter who casts the buff."])
        obHint:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.8)
        yPos = yPos - (max(obHint:GetStringHeight(), 12) + 10)
    end

    return yPos, false
end

S.BuildEffectsTab = function()
    if not S.tabContentFrame then return end
    local parent = S.tabContentFrame
    local yPos, pickerOpen = S.BuildEffectsHeadArea(parent, -10)
    -- The picker sized the column itself and owns the whole of it.
    if pickerOpen then return end

    -- ── EFFECTS LIST ──
    -- ☠ includePIH ON THE HELPER'S POOL, AND WITHOUT IT THE TAB WAS EMPTY. CollectAllEffects
    -- hides pihSignal-marked rows from the designer by default -- correct on My Buffs and Any
    -- Buff, where a helper effect is somebody else's business -- but on the helper's own pool
    -- they are the ONLY business, so the default filtered out every row the tab exists to
    -- show. Krathe, 2026-09-09: "the trigger/effects are not showing."
    -- ⚠ NO SECOND FILTER NEEDED. CurrentAuraPool is already S.PIH_PreviewPool on this tab --
    -- the helper's records and nothing else -- so "include ours" and "show only ours" are the
    -- same instruction here.
    local effects = CollectAllEffects({ includePIH = IsPIHelperTab() })

    -- Apply filter
    local filtered = {}
    for _, effect in ipairs(effects) do
        if S.activeFilter == "all" or effect.typeKey == S.activeFilter then
            tinsert(filtered, effect)
        end
    end

    -- ★★ THE COOLDOWN-ICON GROUP IS A ROW IN THIS LIST (2026-09-10). Krathe: "It's confusing
    -- when you add Cooldown Icons from effects and it appears as a layout group, it should
    -- just show as a normal effect for PI helper." It is offered by a tile in THIS tab's add
    -- grid, so this tab is where it has to come back -- a thing that vanishes from where you
    -- made it and reappears behind a tab that grew a moment ago is two surprises, not one.
    -- ⚠ THE DESIGNER'S OWN GROUP CARD (S.CreateLayoutGroupCard), told to rebuild "effects"
    -- rather than "layout" and to drop its filter picker: what these icons watch is the
    -- cooldown list on Triggers, and offering a second way to say it here would let the two
    -- disagree. Everything else -- name, eye, delete, placement, growth, appearance -- is the
    -- card every other group gets.
    -- ⚠ IT OBEYS THE TYPE FILTER. The group draws icons, so "Showing: Icons" must keep it and
    -- "Showing: Borders" must not: a row that ignores the filter reads as one the filter
    -- failed to remove.
    local pihGroup = nil
    if IsPIHelperTab() and P.PIH_IconGroup and S.CreateLayoutGroupCard then
        local af = S.activeFilter or "all"
        if af == "all" or af == "icon" then pihGroup = P.PIH_IconGroup() end
    end

    if #filtered == 0 and not pihGroup then
        local empty = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        empty:SetPoint("TOP", parent, "TOP", 0, yPos - 30)
        empty:SetWidth(220)
        local spec = ResolveSpec()
        local specAuras = spec and Adapter:GetTrackableAuras(spec)
        -- The Other Buffs pool is spec-independent — never show the
        -- unsupported-spec message there.
        if not IsOtherTab() and (not spec or not specAuras or #specAuras == 0) then
            empty:SetText(L["No trackable spells found for this spec.\n\nYou can select a different spec using the dropdown above."])
        elseif S.activeFilter == "all" then
            empty:SetText(L["No effects configured yet.\nPick a style above to get started."])
        else
            empty:SetText(format(L["No %s effects configured."], (S.PLACED_TYPE_LABELS[S.activeFilter] or S.FRAME_LEVEL_LABELS[S.activeFilter] or S.activeFilter)))
        end
        empty:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.7)
        empty:SetJustifyH("CENTER")
    else
        for _, effect in ipairs(filtered) do
            yPos = S.CreateEffectCard(parent, yPos, effect)
        end
    end

    if pihGroup then
        -- ⚠ ITS OWN STACK, and one card in it is not a waste. The appearance sections inside
        -- an expanded group card re-flow in place and call stack:Reflow(); without a stack
        -- that call has nothing to reach and the card keeps the height it was built at, with
        -- its own controls hanging out of the bottom. Nothing is drawn below it, so a stack
        -- holding only this card re-anchors everything that can move.
        local stack = P.CreateCardStack and P.CreateCardStack(parent, yPos)
        yPos = S.CreateLayoutGroupCard(parent, yPos, pihGroup, stack,
            { refreshTab = "effects", asEffect = true,
              filtersSection = P.PIH_GroupSourceSection(pihGroup),
              Summary = P.PIH_IconGroupSummary })
    end

    parent:SetHeight(max(-yPos + 20, 200))
end

-- ── BUILD GLOBAL TAB ──
-- Wraps the existing BuildGlobalView into the tab content frame
S.BuildGlobalTab = function()
    if not S.tabContentFrame then return end
    -- ★★ ON THE HELPER'S POOL, "GLOBAL" IS ITS TRIGGERS. Every other pool's Global tab holds
    -- the settings that apply to the whole POOL rather than to one effect -- which is exactly
    -- what the helper's roles, class list, icon lists and cooldown gate are. Krathe's split:
    -- "Triggers where people pick WHAT will show the effect... Then HOW it shows the
    -- effects". WHAT lives here; HOW is the Effects tab, which is the designer's own and
    -- needs nothing added to it at all.
    -- ⚠ THE ENABLE TICK LEADS IT, because on this pool it governs everything below -- and it
    -- has to be reachable when the helper is OFF, which is the state a new priest arrives in.
    if P.IsPIHelperTab and P.IsPIHelperTab() and S.BuildPIHelperCard then
        local parent = S.tabContentFrame
        local Refresh = function() if S.SwitchTab then S.SwitchTab("global") end end
        local yPos, open = S.BuildPIHelperCard(parent, { startY = -10, Refresh = Refresh })
        if open and S.BuildPIHelperBody then
            S.BuildPIHelperBody(parent, { startY = yPos, Refresh = Refresh })
        end
        return
    end
    BuildGlobalView(S.tabContentFrame)
end

-- ============================================================
-- ONE GROUP'S STYLE RECORD
-- ------------------------------------------------------------
-- The uniform per-group styling a filter or debuff group renders with, over
-- group.style. Minted here rather than inline in AddGroupAppearanceSection for
-- the reason the Global tab's record is: it is a RECORD, testable on its own,
-- and the section builder around it cannot be run without a frame.
-- ============================================================
local function CreateGroupStyleProxy(group)
    local s = group.style
    if type(s) ~= "table" then s = {}; group.style = s end

    -- Defaults = today's uniform group rendering (Factory buildFilterGroupStyle's
    -- pre-style values) + the icon indicator's Border* seeds so CreateBorderControls
    -- reads sensible values on first open (ShowBorder overridden OFF — a group has
    -- no ring until the user enables one).
    local defaults = {
        -- "icon" is what every group shipped as, so an untouched group reads the same
        -- value it always rendered with and its struct sig does not move on upgrade.
        shape = "icon", color = { r = 1, g = 1, b = 1, a = 1 },
        hideSwipe = false, showDuration = true, showStacks = true,
        durationFormat = "NUMBER",
        durationFont = "DF Roboto SemiBold", durationScale = 1.0, durationOutline = "SHADOW;OUTLINE",
        durationAnchor = "CENTER", durationX = 0, durationY = 0,
        durationColorByTime = false, durationColor = { r = 1, g = 1, b = 1, a = 1 },
        durationHideAboveEnabled = false, durationHideAboveThreshold = 10,
        durationHideOnPermanent = true,   -- Wave 4: absent key = ON (style-less identity)
        stackFont = "DF Roboto SemiBold", stackScale = 1.0, stackOutline = "SHADOW;OUTLINE",
        stackAnchor = "BOTTOMRIGHT", stackX = 2, stackY = -1,
        stackColor = { r = 1, g = 1, b = 1, a = 1 },
        ShowBorder = false,
        -- Duration bar strip (Wave 3) — mirrors the row pages' defaults
        -- (Config.lua buffDurationBar*). OFF until the user enables it.
        durationBarEnabled = false, durationBarPosition = "BOTTOM",
        durationBarHeight = 4, durationBarGap = 1, durationBarColorMode = "STATIC",
        durationBarTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist",
        durationBarColor = { r = 0.2, g = 0.9, b = 0.3, a = 1 },
        durationBarBGColor = { r = 0, g = 0, b = 0, a = 0.8 },
        durationBarReverseFill = false,
    }
    for k, v in pairs(TYPE_DEFAULTS.icon) do
        if k:find("^Border") and defaults[k] == nil then defaults[k] = v end
    end

    -- Defaults proxy (CreateInstanceProxy's idiom, group.style-backed): reads fall
    -- through to the defaults (table fallbacks copy-on-read so colour sub-key edits
    -- persist); writes land in group.style and refresh the live frames. The factory
    -- reads the RAW style table with the same defaults, so UI and render agree.
    --
    -- ☠ AND THE DEFAULTS ADAPTER, which is what a popout row on this section needs
    -- before its modified tick or its Reset Group can say anything true -- see the
    -- Global tab's record above, and Core/Defaults.lua's header, for the contract.
    -- GetStored is a rawget on group.style for the reason it always is here: this
    -- proxy COPIES a table-valued default onto the style on the way past, so a read
    -- taken to answer "is this modified" would itself be what made the key present.
    -- Value equality is what makes that copy harmless.
    local styleAdapter = {
        GetDefault = function(k) return defaults[k] end,
        GetStored  = function(k) return rawget(s, k) end,
        -- Unset, never write the default in: a style-less group renders
        -- byte-identically to one pinned at every default, and unsetting is what
        -- keeps it that way if a default ever moves.
        ClearKey   = function(k)
            s[k] = nil
            RefreshPlacedIndicators()
            RefreshLiveFramesThrottled()
        end,
    }
    local proxy = setmetatable({ _skipOverrideIndicators = true, __dfDefaults = defaults,
                                 __dfDefaultsAdapter = styleAdapter }, {
        __index = function(_, k)
            local val = s[k]
            if val ~= nil then return val end
            local fallback = defaults[k]
            if type(fallback) == "table" then
                local copy = {}
                for fk, fv in pairs(fallback) do copy[fk] = fv end
                s[k] = copy
                return copy
            end
            return fallback
        end,
        __newindex = function(_, k, v)
            s[k] = v
            RefreshPlacedIndicators()
            RefreshLiveFramesThrottled()
        end,
    })
    return proxy
end
P.CreateGroupStyleProxy = CreateGroupStyleProxy

-- ============================================================
-- GROUP APPEARANCE SECTION (filter-group + debuff-group cards)
-- Collapsible "Appearance" SettingsGroup (the effect-card section idiom)
-- holding the per-group icon styling the container genuinely supports:
-- cooldown swipe, border (full CreateBorderControls set incl. the DF-owned
-- animations), duration text (show / font / scale / outline / anchor /
-- offsets / colour-by-time / colour / hide-above) and stack count (show +
-- text styling). Controls bind to group.style via a defaults proxy
-- (CreateInstanceProxy's idiom): nil keys read the pre-style defaults, so
-- an untouched section changes nothing — the factory renders a style-less
-- (or all-default) group byte-identically to before. Omitted vs the placed
-- effect card, by capability: Min Stacks (no formatter on the native stack
-- path — secret trap), Hide Icon / size / scale / alpha / frame level
-- (group-level layout already owns size; the rest are per-indicator
-- concepts), Expiring / Show When Missing (remaining-time / presence reads).
-- Structural fields (show toggles, colour-by-time, hide-above, border
-- on/off) move the group struct sig -> the factory Rebuilds; everything
-- else hot-applies via the cosmetic sig. Collapse state persists PER CARD
-- under "adGroupStyle:<cardKey>" — cardKey is the caller's expand-key form
-- (raw id / "othergroup:<id>" / "dgroup:<id>"), so the three stores' keys
-- stay disjoint from each other and from the effect cards' header keys.
--
-- `collect`: COLLECT MODE, the same seam BuildTypeContent and BuildGlobalView
-- carry. With a table here nothing is built and nothing is anchored: each
-- AddSection records its header and its body, unrun, and the row layout mounts
-- one popout row per entry. Without one this is the card's own section stack,
-- byte for byte what it always drew.
local function AddGroupAppearanceSection(body, group, bodyWidth, by, cardKey, collect)
    local proxy = CreateGroupStyleProxy(group)

    -- Cosmetic edits hot-apply (coSig -> ApplyStyle); structural toggles move the
    -- struct sig -> Rebuild. Both ride the same throttled factory re-sync. The
    -- canvas placeholder's sample icons render the group style too, so every
    -- appearance edit re-draws them (RefreshPlacedIndicators — the same direct
    -- call the card's layout sliders run per edit/drag).
    local function refresh()
        RefreshPlacedIndicators()
        RefreshLiveFramesThrottled()
    end

    -- ── SECTION REFLOW ──
    -- Visibility changes inside a section (the border style dropdown swapping its
    -- widget set) change that section's height. AddSection pins each section at a
    -- FIXED y computed at build time, so without a re-anchor pass the sections
    -- below either overlap it (grew) or leave a gap (shrank) — which is why this
    -- used to answer with S.SwitchTab("layout"), a full tab rebuild.
    --
    -- Same shape as BuildTypeContent's reflow (Indicators.lua): walk the stack
    -- re-anchoring at the running total, reading each section's CURRENT
    -- calculatedHeight (LayoutChildren keeps it up to date) and falling back to
    -- the at-build-time height for anything that doesn't track one.
    --
    -- ☠ The final y IS the caller's `by` — this section is the LAST thing placed
    -- in the card body at both call sites, so dfAD_ReflowCard can size the body
    -- from it. Anything added to the body BELOW this section must be folded into
    -- that hook too, or the body will size short.
    local sections = {}
    local sectionsStartBy = by
    -- The pane's own reflow while a collected body runs, so the border toolkit's
    -- refreshStates re-flows the PANEL it is inside instead of a card stack that
    -- does not exist there. Set by the collect wrapper below; nil on the card.
    local curReflow

    local function ReflowSections()
        local y = sectionsStartBy
        for _, entry in ipairs(sections) do
            local g = entry.widget
            g:ClearAllPoints()
            g:SetPoint("TOPLEFT", body, "TOPLEFT", 5, y)
            y = y - (g.calculatedHeight or entry.height)
        end
        if body.dfAD_ReflowCard then body.dfAD_ReflowCard(y) end
    end
    -- Published under the name the toolkit looks for: SettingsWidgets' measured-label
    -- converge walks up from a resized widget for exactly this key, so a wrapped note
    -- inside one of these sections now re-flows the card instead of walking past it.
    -- Not in collect mode: there is no stack to walk, and stamping this would put a
    -- card's reflow onto whatever host the collector happened to hand in.
    if not collect then body.dfAD_ReflowWidgets = ReflowSections end

    -- One collapsible box PER CATEGORY — the expanded effect card's section
    -- structure (Appearance / Border / Duration Text / Stack Count, same names
    -- and order as the icon card's AddGroup boxes; group-inapplicable sections
    -- — Position, Show When Missing, Expiring — have no group-level analogue).
    -- Collapse persists per card per section ("adGroupStyle:<cardKey>:<section>"),
    -- so each section toggles independently; the toggle rides the widget's
    -- built-in AuraDesigner_RefreshPage rebuild like the effect cards'.
    local function AddSection(header, sectionKey, buildFn)
        if collect then
            collect[#collect + 1] = {
                header = header,
                -- ☠ `body` IS RE-POINTED AND RESTORED, for the reason BuildTypeContent's
                -- seam re-points `parent`: it is this function's own local, so every
                -- widget the body creates follows it, and not restoring it would leave
                -- the next body building onto the previous pane's holder.
                build = function(g, paneParent, reflow)
                    local savedBody, savedReflow = body, curReflow
                    body, curReflow = paneParent, reflow
                    if reflow then
                        paneParent.dfAD_ReflowWidgets = reflow
                        paneParent.dfAD_ReflowInPane = reflow
                    end
                    buildFn(g)
                    body, curReflow = savedBody, savedReflow
                end,
            }
            return
        end
        local g = GUI:CreateSettingsGroup(body, bodyWidth - 10, {
            collapsible = true,
            collapseKey = "adGroupStyle:" .. tostring(cardKey) .. ":" .. sectionKey,
        })
        g.padding = 10   -- match the main Options groups' inner padding (airier scale)
        g:AddWidget(GUI:CreateHeader(body, header), GUI.RowHeight.sectionHeader)
        buildFn(g)
        local h = g:LayoutChildren()   -- includes the group's own bottom margin
        g:SetPoint("TOPLEFT", body, "TOPLEFT", 5, by)
        tinsert(sections, { widget = g, height = h })
        by = by - h
    end

    -- ── APPEARANCE ── (the effect card's Appearance box; of its controls only
    -- the swipe applies at group level — size/scale live in the card's layout
    -- sliders, alpha/level/strata/text-only are per-indicator concepts)
    AddSection(L["Appearance"], "appearance", function(g)
        -- SHAPE. A group used to be spell icons and nothing else, so a filter could only
        -- ever be shown as icons — the reason someone with a filtered set of Beacons could
        -- not render them as squares the way a placed indicator can. Icon and square only:
        -- a bar is its own sized widget with its own layout reservation, not a cell the
        -- group flow lays out, so offering it here would promise something the row cannot do.
        --
        -- ☠ Both controls are ALWAYS shown rather than hiding the colour on icon groups.
        -- AddSection pins each section at a fixed y and greys imperatively — it never runs
        -- hideOn/disableOn (the same limitation that kept pandemic controls off this card),
        -- so a conditionally-present widget would leave a gap or an overlap. The label says
        -- what the colour is for instead.
        g:AddWidget(GUI:CreateDropdown(body, L["Shape"], {
            icon   = L["Spell Icon"],
            square = L["Solid Square"],
            _order = { "icon", "square" },
        }, proxy, "shape", refresh), 54)
        -- ⚠ Held in a local BEFORE AddWidget: nothing else in this file reads AddWidget's
        -- return, so it is not a contract to lean on.
        local sqColor = GUI:CreateColorPicker(body, L["Square Color"], proxy, "color", true, refresh, refresh, true)
        g:AddWidget(sqColor, 32)
        -- ⚠ ALWAYS PRESENT, BUT GREYED OFF-SHAPE. The note above is right that this card
        -- cannot HIDE a widget — AddSection pins each one at a fixed y, so a conditional
        -- widget leaves a gap. It can still GREY one, which is what the duration-bar block
        -- further down does by hand, and a live-but-inert picker was the remaining half of
        -- the problem: on an icon group the colour changed nothing and said nothing. The
        -- Shape dropdown's callback is `refresh`, so the card rebuilds on every change and
        -- this is evaluated fresh each time.
        if sqColor and (proxy.shape or "icon") ~= "square" then
            if sqColor.SetEnabled then sqColor:SetEnabled(false)
            else
                sqColor:SetAlpha(0.4)
                if sqColor.EnableMouse then sqColor:EnableMouse(false) end
            end
        end
        g:AddWidget(GUI:CreateCheckbox(body, L["Hide Cooldown Swipe"], proxy, "hideSwipe", refresh), 28)
    end)

    -- ── BORDER ── (the placed icon's control set; gradient degrades to solid on
    -- container slots — same known casualty as placed indicators. Animation
    -- restored 2026-08-29 with the button-mode reopening: the group's style
    -- table carries the BorderAnimation* keys, buildGroupBorderSpec feeds them
    -- through the same builder as the placed indicators, and a key edit
    -- rebuilds the group container — groupStyleStructSig folds
    -- rawBorderAnimStructTok.)
    AddSection(L["Border"], "border", function(g)
        GUI:CreateBorderControls(g, proxy, "", {
            parent  = body,
            include = {
                inset = true, offset = true, blendMode = true,
                gradient = true, shadow = true, alpha = true,
                animate = true,
            },
            animIntroInert = true,   -- pooled buttons never see the intro burst
            fullUpdate    = refresh,
            lightUpdate   = refresh,
            lightColors   = refresh,
            -- Re-evaluate this section's own hideOn, then slide the sections
            -- below it (and the sibling cards) to the new height. No
            -- RefreshChildStates: this section never applies disableOn at build
            -- either, so adding it here would grey on toggle and un-grey on the
            -- next rebuild. Matches the placed icon card's border exactly.
            refreshStates = function()
                g:LayoutChildren()
                -- In a pane the stack below this section is a stack of ROWS the
                -- panel knows nothing about, so the panel re-flows itself instead.
                if curReflow then curReflow() else ReflowSections() end
            end,
            sizeMin = 1, sizeMax = 5, sizeStep = 1,
        })
    end)

    -- ── DURATION TEXT ── (shared text controls; keys mirror the placed cards')
    AddSection(L["Duration Text"], "duration", function(g)
        g:AddWidget(GUI:CreateCheckbox(body, L["Show Duration"], proxy, "showDuration", refresh), 28)
        -- Icon-sized formats only — a group renders icon rows (see the placed icon
        -- card's Duration Format note). Structural: the proxy write's refresh moves
        -- durationFmtKey -> the factory Rebuilds. Forward-declared
        -- UpdateHideAboveState (assigned below): re-greys Hide Above, which can't
        -- compose with the percent-family formats.
        local UpdateHideAboveState
        GUI:CreateDurationFormatControls(body, g, {
            -- Icon surfaces: FULL and the percent composite stay bar-only (width), so
            -- this list is the three time formats plus Percent.
            NUMBER = L["Standard"], SHORT = L["Units"], TIMER = L["Timer"], PERCENT = L["Percent"],
            _order = { "NUMBER", "SHORT", "TIMER", "PERCENT" },
        }, proxy, "durationFormat", function() if UpdateHideAboveState then UpdateHideAboveState() end end)
        GUI:CreateTextControls(g, proxy, "duration", {
            parent = body,
            include = { color = true },
            colorLabel = L["Duration Text Color"],
            colorDisableOn = function() return proxy.durationColorByTime and true or false end,
            onChange = refresh, onDrag = refresh,
        })
        g:AddWidget(GUI:CreateCheckbox(body, L["Color by Time Remaining"], proxy, "durationColorByTime", refresh), 28)
        AddDurationColorsLink(g, body)
        local hideAboveSlider, hideAboveCheck
        UpdateHideAboveState = function()
            if not hideAboveSlider then return end
            local pctFmt = DF.IsPercentDurationFormat and DF:IsPercentDurationFormat(proxy.durationFormat)
            if hideAboveCheck and hideAboveCheck.SetEnabled then hideAboveCheck:SetEnabled(not pctFmt) end
            if not pctFmt and proxy.durationHideAboveEnabled then
                hideAboveSlider:SetAlpha(1)
                hideAboveSlider:EnableMouse(true)
            else
                hideAboveSlider:SetAlpha(0.4)
                hideAboveSlider:EnableMouse(false)
            end
        end
        hideAboveCheck = GUI:CreateCheckbox(body, L["Hide Duration Above Threshold"], proxy, "durationHideAboveEnabled", function()
            UpdateHideAboveState()
            refresh()
        end)
        g:AddWidget(hideAboveCheck, 28)
        hideAboveSlider = GUI:CreateSlider(body, L["Hide Above (seconds)"], 1, 60, 1, proxy, "durationHideAboveThreshold", refresh, refresh, true)
        g:AddWidget(hideAboveSlider, 54)
        g:AddWidget(GUI:CreateCheckbox(body, L["Hide Duration on Permanent Auras"], proxy, "durationHideOnPermanent", refresh), 28)
        UpdateHideAboveState()
    end)

    -- ── STACK COUNT ── (no Min Stacks — not expressible on the native no-formatter
    -- stack path, see Features/Auras.lua's stacks-formatter warning)
    AddSection(L["Stack Count"], "stacks", function(g)
        g:AddWidget(GUI:CreateCheckbox(body, L["Show Stacks"], proxy, "showStacks", refresh), 28)
        GUI:CreateTextControls(g, proxy, "stack", {
            parent = body,
            include = { color = true },
            colorLabel = L["Stack Text Color"],
            onChange = refresh, onDrag = refresh,
        })
    end)

    -- ── DURATION BAR ── (Wave 3: strip below/above each icon, drained by the
    -- native SetDurationBar fill — render-side, works on secret auras. The keys
    -- mirror the row pages' buffDurationBar* block; enable/position/height/gap
    -- are structural (group struct sig -> Rebuild), texture/colours hot-apply.)
    AddSection(L["Duration Bar"], "durationbar", function(g)
        -- Greys IMPERATIVELY, not via widget.disableOn: this is an AD editor card, which
        -- has no disableOn/RefreshStates loop (that seam only runs on the SettingsGroup
        -- row pages). The enable gate AND the curve-mode dimming of Texture/Bar Color are
        -- driven by hand from the Enable + Color Mode callbacks. curveGated flags the two
        -- controls a curve mode overrides.
        local dbWidgets, curveGated = {}, {}
        local function UpdateBarGrey()
            local on = proxy.durationBarEnabled and true or false
            local curve = DF:IsDurationBarCurveMode(proxy.durationBarColorMode)
            for i = 1, #dbWidgets do
                local w = dbWidgets[i]
                local enable = on and not (curveGated[w] and curve)
                if w.SetEnabled then w:SetEnabled(enable)
                else
                    w:SetAlpha(enable and 1 or 0.4)
                    if w.EnableMouse then w:EnableMouse(enable) end
                end
            end
        end
        g:AddWidget(GUI:CreateCheckbox(body, L["Enable Duration Bar"], proxy, "durationBarEnabled", function()
            UpdateBarGrey()
            refresh()
        end), 28)
        local function barChild(widget, h)
            g:AddWidget(widget, h)
            dbWidgets[#dbWidgets + 1] = widget
            return widget
        end
        barChild(GUI:CreateDropdown(body, L["Position"], { BOTTOM = L["Bottom"], TOP = L["Top"] }, proxy, "durationBarPosition", refresh), 54)
        barChild(GUI:CreateSlider(body, L["Height"], 1, 12, 1, proxy, "durationBarHeight", refresh, refresh, true), 54)
        barChild(GUI:CreateSlider(body, L["Gap"], 0, 10, 1, proxy, "durationBarGap", refresh, refresh, true), 54)
        barChild(GUI:CreateDropdown(body, L["Color Mode"],
            DF:GetDurationBarColorModes(),
            proxy, "durationBarColorMode", function() UpdateBarGrey(); refresh() end), 54)
        -- A curve mode brings its own ramp texture and forces a white tint, so these two
        -- do nothing while it is selected - dim them (curveGated) rather than leave dead
        -- controls live.
        local adBarTex = barChild(GUI:CreateTextureDropdown(body, L["Bar Texture"], proxy, "durationBarTexture", refresh), 54)
        local adBarCol = barChild(GUI:CreateColorPicker(body, L["Bar Color"], proxy, "durationBarColor", true, refresh, refresh, true), 28)
        curveGated[adBarTex] = true; curveGated[adBarCol] = true
        barChild(GUI:CreateColorPicker(body, L["Background Color"], proxy, "durationBarBGColor", true, refresh, refresh, true), 28)
        barChild(GUI:CreateCheckbox(body, L["Reverse Fill"], proxy, "durationBarReverseFill", refresh), 28)
        UpdateBarGrey()
    end)

    -- Collect mode anchored nothing, so there is no cursor to hand back: the
    -- section list IS the return -- carrying the style proxy, which is the record
    -- every one of these rows binds and therefore the one its modified tick and
    -- its Reset Group have to be measured against.
    if collect then
        collect.proxy = proxy
        return collect
    end

    return by
end

-- ☠ Published HERE, in the part that DEFINES it -- see the note in Options.lua.
P.AddGroupAppearanceSection = AddGroupAppearanceSection
