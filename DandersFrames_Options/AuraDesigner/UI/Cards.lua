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
-- strong window on, which surface is burst using. One truth, so nothing can drift out of step
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
-- Not a class token, and it cannot collide with one: class files are uppercase letters only.
local PIH_RACIAL_TOKEN = "@racials"
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
local function pihSeedIDs()
    local out = {}
    for _, rec in ipairs(pihSeedRecords()) do out[#out + 1] = rec.id end
    for _, id in ipairs(PIH_RACIAL_IDS) do out[#out + 1] = id end
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
local PIH_SIGNALS = {
    burst   = { surface = "border",     color = { 1.00, 0.82, 0.25 }, list = "cooldowns" },
    strong  = { surface = "healthbar",  color = { 1.00, 0.35, 0.20 }, list = "cooldowns" },
    infused = { surface = "background", color = { 0.55, 0.35, 0.95 }, list = "infused"   },
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
local function pihLabel(key)
    if key == "burst"   then return L["PI Helper — Big cooldown"]    end
    if key == "strong"  then return L["PI Helper — Big cooldown with a trinket or potion"]   end
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
    return id
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
-- THE COOLDOWN-ICON GROUP (a Filter Group carrying the burst signal)
-- ─────────────────────────────────────────────────────────────
-- ☠ A FOURTH WAY TO SHOW THE SAME SIGNAL, NOT A FOURTH SIGNAL. A placed icon pins
-- max = 1 and shows ONE arbitrary cooldown; a Filter Group shows every matching cooldown the
-- unit has running, one icon each -- the richer read of the burst window, and Danders'
-- recommendation ("build it on merit, not as a fallback"). It is also the gate's native
-- shape: the group builds through AuraContainer:Create with a config-wide candidate set, and
-- buildFilterGroupConfig stamps dfGate from the group's own pihSignal mark -- no new gate
-- code anywhere.
--
-- ⚠ BURST ONLY. Conditions are frame-level, so the strong window cannot ride a group,
-- for the same reason it cannot be an Icon or a Square.
--
-- The group is ordinary Layout Groups data marked with pihSignal -- the same doctrine as the
-- effects: the marks ARE the record. Hand-deleting it from the Layout Groups tab reads as
-- the tick going off, and nothing is left holding a contrary opinion.
-- Two groups, found by their mark: "burst" is the shared cooldowns/amplifiers row
-- (others-only), "infused" is its own one-icon group -- SEPARATE because one container has
-- ONE caster rule, and infused needs the opposite rule from everything else (own casts
-- allowed; it IS an own cast). User's design, second group session.
local function pihIconGroup(sig)
    local groups = P.GetOtherLayoutGroups and P.GetOtherLayoutGroups(false)
    for _, g in ipairs(groups or {}) do
        if type(g) == "table" and g.pihSignal == (sig or "burst") then return g end
    end
    return nil
end

local function pihAnyIconGroup()
    local groups = P.GetOtherLayoutGroups and P.GetOtherLayoutGroups(false)
    for _, g in ipairs(groups or {}) do
        if type(g) == "table" and g.pihSignal then return g end
    end
    return nil
end

-- The icon group counts as existing: without this, unticking all three signals while the
-- icons stay on would flip the card back to "Add" and hide the panel -- stranding a running
-- group with no control left that can reach it.
function P.PIH_Exists()
    return next(pihFound()) ~= nil or pihAnyIconGroup() ~= nil
end

-- "On" means "shows somewhere": a colour effect, the icon group, or both. This is what lets
-- the master tick survive "None" -- an icons-only signal is still a signal.
-- ⚠ Strong's icon representation is its AMPLIFIER HALF (icons cannot make the
-- cooldown-AND-amplifier judgement), which is why its tick is labelled by what it shows.
local PIH_ICON_OF = { burst = "cooldowns", strong = "amplifiers", infused = "infused" }
function P.PIH_SignalOn(key)
    if pihFound()[key] ~= nil then return true end
    local which = PIH_ICON_OF[key]
    return (which and P.PIH_IconsShow and P.PIH_IconsShow(which)) or false
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
    -- After the gate, never before: the sound arms against the gate's current state, so doing
    -- it first would arm against the state we are about to leave.
    if P.PIH_ApplySound then P.PIH_ApplySound() end
    -- The watcher's event registrations follow whether a helper exists at all.
    if Engine and Engine.PIH_SyncWatcher then Engine:PIH_SyncWatcher() end
end

-- ─────────────────────────────────────────────────────────────
-- BUILDING AND UNBUILDING ONE SIGNAL
-- ─────────────────────────────────────────────────────────────
local function pihRefresh()
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

-- ☠ THE AMPLIFIER LIST KEEPS ITS ID ACROSS A CHANGE. Strong window's conditions name this
-- list by reference, so deleting and re-creating it would leave those conditions pointing at a
-- list that no longer exists -- a signal that quietly stops firing and reads as a bug in the
-- gate. The contents are rewritten in place instead.
local function pihSyncAmplifierFilter(s)
    local presets = {}
    if s.potions  then presets[#presets + 1] = PIH_SEED.amplifiers.potions  end
    if s.trinkets then presets[#presets + 1] = PIH_SEED.amplifiers.trinkets end
    if #presets == 0 then
        -- ⚠ Wipe in place rather than just declining: the "As icons" ticks may still
        -- point at this list, and an early return left it holding the previous ticks' spells
        -- -- icons for amplifiers the user had switched off.
        local R = DF.FilterRegistry
        local id = pihFilterIdByName(PIH_FILTERS.amplifiers)
        local f = id and R and R.GetCustomFilter and R:GetCustomFilter(id)
        if f then f.spells, f.rawIDs = {}, {} end
        return nil
    end
    return pihEnsureFilter(PIH_FILTERS.amplifiers, presets, nil, true)
end

local function pihCreateSignal(key, surfaceOverride)
    local def = PIH_SIGNALS[key]
    if not def then return false, "no such signal" end
    if pihFound()[key] then return true, "already on" end
    local tgt = surfaceOverride or def.surface

    local s = P.PIH_Settings()

    local cdId = pihEnsureFilter(PIH_FILTERS.cooldowns, nil, pihSeedIDs())
    if not cdId then return false, "could not build the cooldown list" end
    -- ☠ RECORDED FOR THE RESIDENT HALF, WHICH CANNOT SEE THIS FILE. The sound registrations run
    -- in the always-loaded addon and need this list; they used to find it by NAME and were
    -- looking for the scaffolding filter, so they resolved nothing and no sound could ever play.
    -- The id travels in the helper's own settings, which the resident half already reads.
    -- ⚠ An ID rather than a name: a custom filter can be renamed in the Filter Designer.
    s.cooldownFilterID = cdId
    local cdRef = DF:MakeADFilterRef("custom", cdId)
    if not cdRef then return false, "could not name the cooldown list" end

    local ref = cdRef
    if def.list == "infused" then
        local infId = pihEnsureFilter(PIH_FILTERS.infused, nil, { PIH_PI_SPELL_ID })
        if not infId then return false, "could not build the infused list" end
        ref = DF:MakeADFilterRef("custom", infId)
        if not ref then return false, "could not name the infused list" end
    end

    local conditions
    if key == "strong" then
        -- ☠ THE EMPTY-AMPLIFIER TRAP. resolveConditions SKIPS an empty group and then bails on
        -- fewer than two groups -- at which point the effect falls back to a PLAIN UNION and
        -- strong window silently becomes an exact duplicate of burst window: same trigger, same
        -- behaviour, two effects contending for a surface over nothing.
        -- So with no amplifier ticked, strong window is not created at all. That is the honest
        -- state: the signal has nothing left to distinguish, so it should not exist.
        local ampId = pihSyncAmplifierFilter(s)
        if not ampId then return false, "this signal needs a potion or a trinket ticked" end
        local ampRef = DF:MakeADFilterRef("custom", ampId)
        if not ampRef then return false, "could not name the amplifier list" end
        -- A cooldown AND (a potion OR a trinket). One group of each, combined ALL -- the union
        -- inside a group is free: "one group is just a plain union" (Factory.lua:501).
        conditions = { mode = "ALL", groups = { { triggers = { cdRef } }, { triggers = { ampRef } } } }
    end

    -- ☠ A PLACED TARGET MINTS AN INSTANCE, not a frame effect -- different store
    -- (auraCfg.indicators), different creation call, and no sharing concerns: instances are
    -- per-id, so two signals as icons coexist where two frame effects on one key cannot.
    -- Strong never reaches here as placed -- its menu does not offer these (a placed
    -- indicator cannot make the cooldown-AND-amplifier judgement) -- but refuse anyway:
    -- a guard that relies on the menu is a guard that relies on every future menu.
    if tgt == "icon" or tgt == "square" then
        if key == "strong" then return false, "that signal cannot be an icon" end
        local inst = CreateIndicatorInstance and CreateIndicatorInstance(ref, tgt)
        if not inst then return false, "could not create the indicator" end
        inst.pihSignal = key
        -- ⚠ OTHERS ONLY IS PER INSTANCE on the placed path -- poolFilter reads it off
        -- the indicator, not the record. Forgetting it is the My-Buffs-pool trap; but see
        -- pihCreateSignal's frame branch for why INFUSED must be the exception -- with it,
        -- that signal could never fire at all.
        inst.othersOnly = (key ~= "infused") or nil
        -- A square has a colour; an icon shows the aura's own artwork.
        if tgt == "square" then
            inst.color = { r = def.color[1], g = def.color[2], b = def.color[3], a = 1 }
        end
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
    cfg.conditions = conditions   -- nil on purpose for the unchained signals: clears a stale chain
    return true
end

local function pihDeleteSignal(key)
    local hit = pihFound()[key]
    if not hit then return false end
    local pool = pihOtherPoolRead()
    local auraCfg = pool and pool[hit.auraName]
    if hit.indicatorID and auraCfg and type(auraCfg.indicators) == "table" then
        -- A placed representation: remove the instance, not a frame key. Direct removal
        -- rather than RemoveIndicatorInstance for the same reason the prune below bypasses
        -- CleanupAdHocAura -- that helper resolves the pool off the OPEN TAB, and ours is
        -- always the Other pool.
        for i, inst in ipairs(auraCfg.indicators) do
            if inst.id == hit.indicatorID then table.remove(auraCfg.indicators, i) break end
        end
    elseif auraCfg then
        auraCfg[hit.typeKey] = nil
    end
    -- Drops the record once its last effect is gone -- the same prune the generic delete button
    -- runs, so unticking here and deleting the row there leave the profile identical.
    -- ⚠ NOT S.CleanupAdHocAura. It prunes an emptied record out of `CurrentAuraPool()` -- the
    -- pool of whichever tab is open -- and ours are always in the Other Buffs pool, so it would
    -- do nothing whenever the user happened to be on My Buffs. Same rule, same test
    -- (AuraHoldsNoEffects, its own predicate), applied to the pool the record is actually in.
    if pool and type(auraCfg) == "table" and P.AuraHoldsNoEffects
        and P.AuraHoldsNoEffects(auraCfg) then
        pool[hit.auraName] = nil
    end
    return true
end


-- ─────────────────────────────────────────────────────────────
-- WHICH SURFACE A SIGNAL DRAWS ON
-- ─────────────────────────────────────────────────────────────
local PIH_SURFACE_ORDER = { "border", "healthbar", "background", "nametext", "healthtext" }

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

-- Which OTHER helper signal is sitting on this surface, if any.
-- ⚠ ONLY A SIGNAL ON THE *SAME RECORD* BLOCKS A SURFACE, and the first version of this got
-- that wrong -- it refused ANY signal sharing a surface, which quietly forbade a configuration
-- that works perfectly.
--
-- Burst and strong window live on ONE record, because they share one spell list on purpose. A
-- record holds one effect per surface, so those two on the same surface is an overwrite: the
-- second replaces the first and a signal disappears. Genuinely impossible.
--
-- ☠ "Already infused" is a DIFFERENT record, and there the answer flips. Two effects on
-- different records CAN share a health bar or a background -- watched in game 2026-08-23, two
-- tints on one unit rendered both colours mixed, because collectFrameTints is multi. Blocking
-- that was us inventing a limit the engine does not have. On border or either text it is a real
-- contest rather than an impossibility, and a contest is what the clash warning is for.
local function pihSurfaceTakenBy(surface, exceptKey)
    local mine = PIH_SIGNALS[exceptKey]
    if not mine then return nil end
    for key, hit in pairs(pihFound()) do
        local other = PIH_SIGNALS[key]
        if key ~= exceptKey and hit.typeKey == surface and other and other.list == mine.list then
            return key
        end
    end
    return nil
end

-- The same question for the CLASH WARNING, which cares about contention rather than
-- impossibility: another of our signals, on a different record, on a surface that takes a
-- single winner. PIH_ClashOn deliberately skips our own effects when counting the user's --
-- this is what puts the ones that genuinely contend back in.
local function pihSiblingContends(surface, exceptKey)
    if not PIH_CONTENDED[surface] then return nil end
    local mine = PIH_SIGNALS[exceptKey]
    if not mine then return nil end
    for key, hit in pairs(pihFound()) do
        local other = PIH_SIGNALS[key]
        -- Through the real candidacy test: a sibling that opted OUT of the contest
        -- (custom-mode border, disabled) is not a clash, and warning about it would survive
        -- the very fix the warning names.
        if key ~= exceptKey and hit.typeKey == surface and other and other.list ~= mine.list
            and pihContends(surface, hit.cfg) then
            return key
        end
    end
    return nil
end
P.PIH_SiblingContends = pihSiblingContends

-- Does OUR OWN signal actually enter the contest on this surface? The warning has to vanish
-- when the named fix is applied to our effect itself -- a warning that survives its own
-- remedy teaches people to ignore warnings.
function P.PIH_SelfContends(surface, key)
    if not PIH_CONTENDED[surface] then return false end
    local hit = pihFound()[key]
    return (hit and pihContends(surface, hit.cfg)) and true or false
end

function P.PIH_SurfaceOf(key)
    local hit = pihFound()[key]
    if hit then return hit.typeKey end
    -- Icons-only: the signal is on with no colour, and the dropdown says so.
    local which = PIH_ICON_OF[key]
    if which and P.PIH_IconsShow and P.PIH_IconsShow(which) then return "none" end
    return nil
end

-- The dropdown's option set, rebuilt per signal because what is available depends on where the
-- other two are sitting.
-- ⭐ EVERY SURFACE IS LISTED, AND AN OCCUPIED ONE SAYS WHAT PICKING IT DOES.
function P.PIH_SurfaceOptions(key)
    local labels = S.FRAME_LEVEL_LABELS or {}
    local opts = { _order = {} }
    for _, surface in ipairs(PIH_SURFACE_ORDER) do
        -- Naming the swap is what makes a taken row honest. Two earlier answers were worse and
        -- are worth knowing about before anyone changes this back:
        --
        -- ☠ GREYING IT IS NOT AVAILABLE. The dropdown has no disabled-row concept. `header = true`
        -- is the only thing that stops a row being clickable, and it is the GROUP LABEL treatment,
        -- not a disabled state: it uppercases the text, shrinks it to 0.85, draws a separator, and
        -- sets a flag that INDENTS EVERY ROW BELOW IT -- so one unavailable entry turned the rest
        -- of the menu into its children. Asked for as a real `disabled` row; until it exists,
        -- greying here is a misuse of somebody else's mechanism.
        --
        -- ⚠ HIDING IT WAS THE OTHER ANSWER, and the user rejected it for the right reason: a
        -- missing row reads as "that was never possible", when it is possible and simply taken.
        local label   = labels[surface] or surface
        local takenBy = pihSurfaceTakenBy(surface, key)
        opts[surface] = takenBy and format(L["%s (swap with %s)"], label, pihLabel(takenBy)) or label
        opts._order[#opts._order + 1] = surface
    end
    -- "None" makes colour VISIBLY optional -- it is the entry that lets one row enumerate
    -- colour-only / icons-only / both. First in the list (user's call): an opt-out reads as
    -- the baseline you depart from, not a footnote you discover. On every signal, strong
    -- included -- an icons-and-sound-only setup is first-class, and strong's icon half
    -- (the amplifiers) is reachable without forcing a colour. L["None"] is the addon's
    -- existing key, reused.
    opts.none = L["None"]
    table.insert(opts._order, 1, "none")
    -- Placed surfaces, after the colours: one Icon at a spot you choose (the aura's own
    -- artwork), or a Square (a flat colour block -- the quietest signal there is). Gated
    -- and role-excluded like everything else since the slot lane landed. Not on strong: a
    -- placed indicator cannot make its cooldown-AND-amplifier judgement.
    if key ~= "strong" then
        opts.icon   = L["Icon"]
        opts.square = L["Square"]
        opts._order[#opts._order + 1] = "icon"
        opts._order[#opts._order + 1] = "square"
    end
    return opts
end

-- ☠ THE COLOUR TRAVELS; NOTHING ELSE DOES. Decided 2026-08-23 with the user. The five surfaces
-- do not share a settings vocabulary -- a border has a style, a thickness and an inset, a health
-- bar has Replace-vs-Tint and a blend -- so carrying settings across would mean inventing
-- equivalences that do not exist. The colour is the one thing every surface genuinely has, and
-- it is read from the OLD surface's key and written to the NEW one, because a border keeps its
-- colour under a different name (see pihColorKey).
-- What travels when a signal moves: its colour and its condition chain, nothing else. Captured
-- BEFORE anything is deleted, because a swap deletes both effects before rebuilding either.
local function pihCapture(hit)
    return {
        colour     = hit.cfg[pihColorKey(hit.typeKey)],
        conditions = hit.cfg.conditions,
    }
end

local function pihPlace(key, auraName, surface, carried)
    if surface == "icon" or surface == "square" then
        if key == "strong" then return false end
        local inst = CreateIndicatorInstance and CreateIndicatorInstance(auraName, surface)
        if not inst then return false end
        inst.pihSignal  = key
        inst.othersOnly = (key ~= "infused") or nil   -- infused = own cast; see pihCreateSignal
        if surface == "square" then
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
function P.PIH_SetSurface(key, surface)
    if not PIH_SIGNALS[key] then return false, "no such signal" end
    local found = pihFound()
    local hit = found[key]

    -- "No colour": drop the effect and nothing else. With icons on, the signal lives on as
    -- icons-only; with icons off there is nothing left and the signal honestly reads off.
    if surface == "none" then
        if hit then pihDeleteSignal(key); pihRefresh() end
        return true
    end
    -- Coming FROM icons-only: no effect exists to move, so create one where asked. Fresh
    -- default colour -- there was no colour to carry.
    if not hit then
        local ok, why = pihCreateSignal(key, surface)
        pihRefresh()
        return ok, why
    end
    if hit.typeKey == surface then return true end

    -- ☠ A MOVE TOUCHING A PLACED REPRESENTATION takes the simple route: capture,
    -- delete, recreate on the same record. No swap machinery -- instances are per-id and
    -- never contend -- and the frame-swap path below would try to nil a frame key the
    -- instance does not live under.
    if hit.indicatorID or surface == "icon" or surface == "square" then
        local carried = pihCapture(hit)
        pihDeleteSignal(key)
        if not pihPlace(key, hit.auraName, surface, carried) then
            return false, "could not create the effect"
        end
        pihRefresh()
        return true
    end

    local pool = pihOtherPoolRead()
    local auraCfg = pool and pool[hit.auraName]
    if not auraCfg then return false, "the record went missing" end

    local swapKey = pihSurfaceTakenBy(surface, key)
    local swapHit = swapKey and found[swapKey] or nil

    -- Anything else sitting there is not ours to move. Cannot happen on a record identified by a
    -- helper spell list, but refusing beats overwriting something we never read.
    if auraCfg[surface] ~= nil and not swapHit then return false, "that surface is occupied" end

    local mine, theirs = pihCapture(hit), swapHit and pihCapture(swapHit) or nil
    local vacated = hit.typeKey

    auraCfg[vacated] = nil
    if swapHit then auraCfg[swapHit.typeKey] = nil end

    if not pihPlace(key, hit.auraName, surface, mine) then
        return false, "could not create the effect"
    end
    if swapHit then pihPlace(swapKey, swapHit.auraName, vacated, theirs) end

    pihRefresh()
    return true
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
    -- ⚠ RACIALS RIDE LAST, AS A PSEUDO-CLASS. They belong to no class -- every racial record is
    -- tagged "ALL" -- so the loop above can never surface them, and without a row of their own
    -- they would be the one part of the list nothing in this panel could switch off. Last
    -- because it is not a class, and the registry's own spell lists group "All Classes" last too.
    out[#out + 1] = PIH_RACIAL_TOKEN
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
    if classFile == PIH_RACIAL_TOKEN then
        for _, sid in ipairs(PIH_RACIAL_IDS) do
            if f.spells[sid] or f.rawIDs[sid] then return true end
        end
        return false
    end
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
    if classFile == PIH_RACIAL_TOKEN then
        -- The same four the list was seeded from, so ticking it back restores exactly what was
        -- taken away rather than the whole racial category.
        for _, sid in ipairs(PIH_RACIAL_IDS) do
            if on then R:AddSpellToCustom(id, sid) else R:RemoveSpellFromCustom(id, sid) end
        end
        return
    end
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
-- The Layout Groups names are stored data, like the three filter names -- raw, never L[].
local PIH_ICON_GROUP_NAME = "PI Helper — Cooldown icons"
local PIH_INFUSED_GROUP_NAME = "PI Helper — Infused icon"

-- The three lists the icons box can show. State is READ OFF THE GROUP'S OWN SELECTION --
-- one tick per list, no stored copy -- so editing the group by hand on the Layout Groups tab
-- and using these ticks can never disagree.
local PIH_ICON_LIST_NAMES = {
    cooldowns  = PIH_FILTERS.cooldowns,
    amplifiers = PIH_FILTERS.amplifiers,
    infused    = PIH_FILTERS.infused,
}

function P.PIH_IconsShow(which)
    if which == "infused" then return pihIconGroup("infused") ~= nil end
    local g = pihIconGroup("burst")
    if not (g and g.filterSelection and g.filterSelection.customs) then return false end
    local id = pihFilterIdByName(PIH_ICON_LIST_NAMES[which])
    return (id and g.filterSelection.customs[id]) and true or false
end

function P.PIH_SetIconsShow(which, on)
    if not PIH_ICON_LIST_NAMES[which] then return false, "no such list" end

    -- ☠ INFUSED IS ITS OWN GROUP -- one icon, own position, and the OPPOSITE caster
    -- rule from the shared row (own casts allowed: it IS an own cast). Existence is the
    -- state; the last thing to derive is nothing.
    if which == "infused" then
        local ig = pihIconGroup("infused")
        if not on then
            if ig and P.DeleteLayoutGroup then P.DeleteLayoutGroup(ig.id) end
            pihRefresh()
            return true
        end
        if ig then return true end
        local id = pihEnsureFilter(PIH_FILTERS.infused, nil, { PIH_PI_SPELL_ID })
        if not (id and P.CreateLayoutGroup) then return false, "could not build the list" end
        ig = P.CreateLayoutGroup(PIH_INFUSED_GROUP_NAME, "filter")
        if not ig then return false, "could not create the group" end
        ig.pihSignal = "infused"
        -- NO othersOnly here, on purpose -- the whole reason this group exists apart.
        ig.maxIcons = 1
        ig.iconsPerRow = 1
        -- The other corner, so the two icon groups never overlap at their defaults.
        ig.anchor = "TOPRIGHT"
        ig.filterSelection.customs[id] = true
        pihRefresh()
        return true
    end

    local g = pihIconGroup("burst")

    if not on then
        if not g then return true end
        local id = pihFilterIdByName(PIH_ICON_LIST_NAMES[which])
        if id and g.filterSelection and g.filterSelection.customs then
            g.filterSelection.customs[id] = nil
        end
        -- The last list going deletes the group: the marks are the record, and a group
        -- showing nothing is a record of nothing. Through the shared delete, which also
        -- sweeps the expanded-card key -- its tab-routed store is safe here because this
        -- panel only exists on the Other Buffs tab.
        if g.filterSelection and not next(g.filterSelection.customs or {}) then
            if P.DeleteLayoutGroup then P.DeleteLayoutGroup(g.id) end
        end
        pihRefresh()
        return true
    end

    -- ☠ EACH TICK BUILDS ITS OWN LIST IF IT MUST. The box cannot depend on What to
    -- Show -- icons-only is a legitimate setup -- so a list no signal ever created is created
    -- here, the same way the signals create theirs.
    local id
    if which == "cooldowns" then
        local st = P.PIH_Settings()
        id = st and st.cooldownFilterID
        if not id then
            id = pihEnsureFilter(PIH_FILTERS.cooldowns, nil, pihSeedIDs())
            -- Recording the id is what makes the helper EXIST to the resident half (the
            -- gate's watcher keys on it), so an icons-only setup still gets the gate.
            if id and st then st.cooldownFilterID = id end
        end
    elseif which == "amplifiers" then
        local st = P.PIH_Settings()
        -- Same first-click rule as the strong signal: with neither amplifier ticked there is
        -- nothing to show, so the first tick turns both on rather than appearing inert.
        if not (st.potions or st.trinkets) then st.potions, st.trinkets = true, true end
        id = pihSyncAmplifierFilter(st)
    elseif which == "infused" then
        id = pihEnsureFilter(PIH_FILTERS.infused, nil, { PIH_PI_SPELL_ID })
    end
    if not id then return false, "could not build the list" end

    if not g then
        if not P.CreateLayoutGroup then return false, "layout groups unavailable" end
        g = P.CreateLayoutGroup(PIH_ICON_GROUP_NAME, "filter")
        if not g then return false, "could not create the group" end
        -- ☠ THE MARK is ownership, not content: whichever lists are ticked, this is
        -- the one field that puts the icons under "hide while Power Infusion is on cooldown"
        -- and the role exclusions (buildFilterGroupConfig reads it and stamps dfGate).
        g.pihSignal = "burst"
        -- ☠ OTHERS ONLY IS NOT INHERITED FROM ANYTHING. poolFilter reads it off THIS
        -- group; without it the filter is plain HELPFUL -- anyone's casts, including the
        -- priest's own cooldowns lighting icons on their own frame. The exact trap the first
        -- group test found on the effects, closed here at create time.
        g.othersOnly = true
    end
    g.filterSelection.customs[id] = true
    pihRefresh()
    return true
end

function P.PIH_Create()
    local ok, why = pihCreateSignal("burst")
    -- See PIH_SetSignal: a silent refusal is indistinguishable from a dead button.
    if not ok then
        DF:DebugWarn("AURADESIGNER", "PIH: could not add the helper -- %s", tostring(why))
    end
    if ok then
        -- ☠ PUSH THE DEFAULTS NOW. Creating writes the settings table (tanks and
        -- healers excluded, gate on) but writing is not applying -- without this push the
        -- engine ran on its own defaults until a reload or the first tick of any control,
        -- so a freshly added helper marked the tank while the panel said it would not.
        P.PIH_Apply()
        pihRefresh()
    end
    return ok, why
end

function P.PIH_Remove()
    local pool = pihOtherPoolRead()
    local found = pihFound()
    local names, n = {}, 0
    for _, hit in pairs(found) do names[hit.auraName] = true; n = n + 1 end

    -- ☠ THE WHOLE RECORD GOES, not only the marked surfaces. A helper record can carry a
    -- `sound` entry that the generic effects list refuses to show on a filter-owned record
    -- (Groups.lua) -- so it offers no delete button for it, and anything left behind there is
    -- unreachable. Safe to take wholesale: a record here is identified BY a helper spell list,
    -- so nothing of the user's own can be sitting on it.
    if pool then
        for name in pairs(names) do pool[name] = nil end
    end

    -- The lists go too. They exist only to feed these effects, and three "Power Infusion
    -- Helper" entries left in the filter list after the helper is gone are cruft only their
    -- author could explain.
    -- ☠ BUT THE LISTS ARE ACCOUNT-WIDE AND THE HELPER IS PER-PRESET. Deleting them
    -- while another preset still carries helper effects leaves that helper referencing lists
    -- that no longer exist -- signals that silently render nothing, with no missing row to
    -- explain it. So they only go when no helper mark remains in either mode of this profile.
    -- ⚠ Another PROFILE's helper is not scanned: profiles are separate saved-variable
    -- branches with their own preset resolution, and walking them all from here is machinery
    -- out of proportion to the case. A cross-profile remove leaving orphaned references is
    -- accepted and recorded.
    local marksElsewhere = false
    if DF.GetModeBaseAuraDesigner then
        for _, mode in ipairs({ "party", "raid" }) do
            local adDB = DF:GetModeBaseAuraDesigner(mode)
            for _, auraCfg in pairs((adDB and adDB.otherAuras) or {}) do
                if type(auraCfg) == "table" then
                    for _, tCfg in pairs(auraCfg) do
                        if type(tCfg) == "table" and tCfg.pihSignal then
                            marksElsewhere = true
                            break
                        end
                    end
                end
                if marksElsewhere then break end
            end
            -- Icon groups reference the cooldown list by id, so they hold it alive too.
            for _, g in ipairs((adDB and adDB.otherLayoutGroups) or {}) do
                if type(g) == "table" and g.pihSignal then marksElsewhere = true break end
            end
            if marksElsewhere then break end
        end
    end
    if not marksElsewhere then
        local R = DF.FilterRegistry
        for _, name in pairs(PIH_FILTERS) do
            local id = pihFilterIdByName(name)
            if id and R and R.DeleteCustomFilter then R:DeleteCustomFilter(id) end
        end
    end

    -- The icon groups go with the signals: they are the signals in another shape, and a
    -- helper that no longer exists must not leave icons running.
    local ig = pihAnyIconGroup()
    while ig and P.DeleteLayoutGroup do
        P.DeleteLayoutGroup(ig.id)
        ig = pihAnyIconGroup()
    end

    -- ☠ SOUND IS NOT A CONTAINER, so nothing above reaches it. Removing the helper has to
    -- silence it explicitly or the announcements outlive the feature that made them.
    -- The SETTING is left alone: it is behaviour, and behaviour survives a remove.
    local Engine = DF.AuraDesigner and DF.AuraDesigner.Engine
    if Engine and Engine.PIH_SetSound then Engine:PIH_SetSound(nil) end

    -- The recorded list id goes with the list. Leaving it would point the resident half at a
    -- filter that no longer exists -- harmless today, and exactly the kind of stale pointer that
    -- reads as a bug the next time someone adds a helper and it resolves the wrong thing.
    local st = P.PIH_Settings()
    if st then st.cooldownFilterID = nil end

    -- Re-derive the engine from whatever helper remains (another preset's, or none). This
    -- resets roles and the gate, and releases the watcher's registrations when nothing is
    -- left to drive.
    if Engine and Engine.PIH_ApplySaved then Engine:PIH_ApplySaved() end

    pihRefresh()
    return true, ("removed %d signal(s) and their spell lists"):format(n)
end

function P.PIH_SetSignal(key, on)
    local s = P.PIH_Settings()
    if on then
        -- ☠ STRONG WINDOW BRINGS ITS AMPLIFIERS WITH IT. It means "a cooldown AND something
        -- extra"; with no amplifier ticked there is no extra, and the signal would be created
        -- as a duplicate of burst or not at all. Ticking it with neither on turns both on, so
        -- the tick does what it says on the first click rather than appearing to do nothing.
        if key == "strong" and not (s.potions or s.trinkets) then
            s.potions, s.trinkets = true, true
        end
        local ok, why = pihCreateSignal(key)
        -- ⚠ A REFUSAL MUST LEAVE A TRACE. All of these paths return a reason and nothing
        -- read it, so a failure (the registry not ready, a list that would not build) looked
        -- exactly like a dead control: click, nothing, no message anywhere.
        if not ok then DF:DebugWarn("AURADESIGNER", "PIH: signal %s not created -- %s",
            tostring(key), tostring(why)) end
        P.PIH_Apply()   -- see PIH_Create: writing settings is not applying them
    else
        pihDeleteSignal(key)
        -- Off means off everywhere: the signal's own icon list goes with it, or the master
        -- tick would re-read as on from the icons it left behind.
        if PIH_ICON_OF[key] then P.PIH_SetIconsShow(PIH_ICON_OF[key], false) end
        -- ⚠ RE-DERIVE, AS REMOVE DOES. Unticking the LAST signal leaves no helper, and
        -- without this the resident half keeps its event registrations and its sound armed for
        -- a helper with nothing left in it. Remove gets that reset; this path reaches the same
        -- state one tick at a time and got nothing. Caught in Danders' PR review.
        if not P.PIH_Exists() then
            local Engine = DF.AuraDesigner and DF.AuraDesigner.Engine
            if Engine and Engine.PIH_ApplySaved then Engine:PIH_ApplySaved() end
        end
    end
    pihRefresh()
end

function P.PIH_SetRole(role, on)
    local s = P.PIH_Settings()
    -- PIH_Settings hands back a bare table when there is no Aura Designer config to write to,
    -- and indexing a field that table does not have is an error rather than a no-op.
    s.roles = s.roles or {}
    s.roles[role] = on and true or nil
    P.PIH_Apply()
end

-- ☠ UNTICKING THE LAST AMPLIFIER TAKES STRONG WINDOW WITH IT -- see the empty-amplifier trap in
-- pihCreateSignal. This is not a value change; it is the difference between a signal existing
-- and not existing.
function P.PIH_SetAmplifier(which, on)
    local s = P.PIH_Settings()
    s[which] = on and true or false
    if not (s.potions or s.trinkets) then
        -- Both off: the judgement loses its second half AND the icon list empties, so both
        -- representations go -- or the strong row would read "on" while showing nothing.
        pihDeleteSignal("strong")
        P.PIH_SetIconsShow("amplifiers", false)
        pihRefresh()
    elseif P.PIH_SignalOn("strong") then
        pihSyncAmplifierFilter(s)   -- rewritten in place, so the effect keeps pointing at it
        pihRefresh()
    end
end

function P.PIH_SetGateEnabled(on)
    P.PIH_Settings().gateEnabled = on and true or false
    P.PIH_Apply()
end

-- The cooldown list's registry id, for deep-linking straight to it in the Filter Designer.
-- nil before the helper exists, which is also when the button that uses it must be dead.
function P.PIH_CooldownFilterID()
    return pihFilterIdByName(PIH_FILTERS.cooldowns)
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

-- ── SWITCH TAB ──
S.SwitchTab = function(tabKey)
    -- Effects is frosted on the Debuffs tab (C2: category groups have no
    -- placed indicators) — coerce to Layout Groups (belt-and-braces; the
    -- sub-tab button is also frosted).
    if tabKey == "effects" and IsDebuffTab() then
        tabKey = "layout"
    end

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
local function UpdateLayoutTabState()
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
    for key, btn in pairs(mainTabButtons) do
        btn:SetActive(key == tabKey)
    end
    UpdateSpecDropdownState()
    UpdateLayoutTabState()
    -- Effects is frosted on the Debuffs tab, so land on Layout Groups (the
    -- tab's primary surface). Layout Groups is live on both buff tabs — no
    -- coercion needed when arriving there.
    if S.activeBuffTab == "debuffs" and S.activeTab == "effects" then
        S.activeTab = "layout"
    end
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
    local warnKey = GetAuraWarningKey(spec, effect.auraName)
    AttachWarningBadge(header, warnKey, {
        point = "LEFT",
        relativeTo = badgeBg,
        relativePoint = "RIGHT",
        offsetX = 4,
        offsetY = 0,
        size = 16,
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
    if IsOtherTab() and effect.config and effect.config.othersOnly then
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
                if isPlaced then
                    RemoveIndicatorInstance(effect.auraName, effect.indicatorID)
                else
                    local auraCfg = CurrentAuraPool()[effect.auraName]
                    if auraCfg then auraCfg[effect.typeKey] = nil end
                    S.CleanupAdHocAura(effect.auraName)  -- drop emptied ad-hoc "#<id>" entries
                end
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
        if IsOtherTab() and effect.typeKey ~= "sound" then
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

local function PaintEffectOnThumb(pv, typeKey)
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
        ico:SetTexture(DEFAULT_TILE_ICON)
        ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        -- Swapped for the chosen spell's own artwork once section 1 is answered:
        -- "the spell's own artwork" is the whole of what this effect does, so the
        -- picture is only honest when it is that spell's.
        pv.spellIcon = ico

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
S.BuildPIHelperPane = function(parent, opts)
    opts = opts or {}
    local yPos = opts.startY or 0
    local Refresh = opts.Refresh or function() end
    local tc = GetThemeColor()
    local exists = P.PIH_Exists()
    local pihBlock = GUI:CreateChoiceCardGroup(parent, {
        title    = L["POWER INFUSION HELPER"],
        accent   = tc,
        onToggle = function() Refresh() end,
        cards = {
            {
                title = exists and L["Remove the helper"] or L["Add the helper"],
                desc  = exists
                    and L["Deletes its indicators and its spell lists. Nothing else is touched."]
                    or  L["Shows who is worth infusing, and goes dark while your Power Infusion is on cooldown."],
                art   = { kind = "border", color = { 1.00, 0.82, 0.25 } },
                onClick = function()
                    if P.PIH_Exists() then P.PIH_Remove() else P.PIH_Create() end
                    Refresh()
                end,
            },
        },
    })
    pihBlock:SetPoint("TOPLEFT", 8, yPos)
    pihBlock:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    yPos = yPos - (pihBlock.layoutHeight + GUI.Space.section)

    -- ── THE SETTINGS, FOLDED WITH THE CARD ──
    -- ☠ GATED ON pihBlock.expanded, NOT ONLY ON THE HELPER EXISTING. The card group carries
    -- its own collapsing header and publishes whether it is open; without asking, folding
    -- the header away would hide the card and leave its settings stranded below a closed
    -- section, attached to nothing visible. One header, the whole helper.
    --
    -- ☠ SHARED BEHAVIOUR LIVES HERE, NOT ON EACH EFFECT ROW. The mockup put "Never mark",
    -- "Only watch" and the gating cooldown on every effect. It was drawn before the engine
    -- existed, and the engine made them ONE switch for the whole helper. Three copies of
    -- "never on tanks" that can disagree is not flexibility -- it is four states where one
    -- is meaningful and three are bug reports.
    -- Appearance (colour, border style, which surface) stays on the effect rows, because
    -- that genuinely differs per signal and is where the AD already puts appearance.
    if exists and pihBlock.expanded then
        -- ☠ INDENTED, AND THAT IS THE WHOLE POINT OF THE CHANGE. These boxes used to start at
        -- the same left edge as "Add an indicator" and "Active indicators", so a column of
        -- five same-level boxes read as five sections rather than as one section and the
        -- four boxes belonging to it. Nothing said which header owned them. Ten pixels of
        -- indent is what says it -- the hierarchy was always there, it just was not drawn.
        -- ⚠ 20 IS THE ADDON'S INDENT STEP, not a number picked here: the page layout engine
        -- reads `widget.indent` and multiplies by 20 per level. That flag cannot be used
        -- directly -- this column lays itself out by hand rather than going through the page
        -- engine -- so the step is borrowed instead of the mechanism, which at least keeps
        -- one indent width in the addon rather than two.
        local PIH_INDENT = 20
        local function pihGroup(header, buildFn, opts)
            local group = GUI:CreateSettingsGroup(parent,
                (parent:GetWidth() or 320) - (PIH_INDENT + 18), opts)
            group.padding = 10
            group:AddWidget(GUI:CreateHeader(parent, header), GUI.RowHeight.sectionHeader)
            buildFn(group)
            local h = group:LayoutChildren()
            group:SetPoint("TOPLEFT", PIH_INDENT, yPos)
            group:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
            -- The named scale, not a number that looks about right. GUI.Space carries a note
            -- about an audit that found 58 spacers using 9 different values for two intents,
            -- and three files each inventing their own for the same one.
            yPos = yPos - (h + GUI.Space.section)
        end

        -- ☠☠ EVERY NOTE IN THIS COLUMN TAKES AN EXPLICIT HEIGHT, which inverts CreateLabel's
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
        -- measured figure and why it is rounded up are on the constant below.
        -- The byte count makes an em dash worth three, which errs the same way.
        -- Delete all of this the day the column publishes a `dfAD_ReflowWidgets` seam.
        local PIH_NOTE_LINE = 13
        local PIH_NOTE_W = (parent:GetWidth() or 320) - (PIH_INDENT + 18) - 24
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
        local function pihLines(text)
            local cpl = math.max(20, math.floor(PIH_NOTE_W / 6))
            -- ⚠ Colour escapes are not characters anyone can see. Counting them would add
            -- twelve bytes per highlighted word and inflate the box by a line or two of pure
            -- whitespace, which is the fault this estimator exists to avoid.
            local plain = tostring(text):gsub("||r", "")
            return math.max(1, math.ceil(#plain / cpl))
        end
        -- ⭐ GUI:CreateNote, not a hand-coloured CreateLabel. It IS the toned-note widget --
        -- a label with the tone's own accent baked in through ToneHex, so a caution note here
        -- is the same yellow as every caution note in the addon rather than three numbers
        -- typed at this call site. `tone` names come from INFO_BANNER_TONES: info, caution,
        -- danger, success. (The tone adds a colour escape to the string, which the byte count
        -- below then treats as a dozen characters -- harmless, and it errs long.)
        local function pihNote(g, text, tone)
            if not text or text == "" then return end
            local w = tone and GUI:CreateNote(parent, text, { tone = tone })
                or GUI:CreateLabel(parent, text)
            g:AddWidget(w, pihLines(text) * PIH_NOTE_LINE + (GUI.RowHeight.labelPad or 19))
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

        -- Each tick creates or deletes one ordinary effect, which is why the rows below
        -- also appear in Active Indicators: they ARE indicators, and hiding them there
        -- would mean a row you can see the colour of but cannot find.
        local function signalRow(g, key, label)
            g:AddWidget(GUI:CreateCheckbox(parent, label, nil, nil, nil,
                function() return P.PIH_SignalOn(key) end,
                function(v)
                    P.PIH_SetSignal(key, v)
                    Refresh()   -- the dependent groups appear and vanish with it
                end))

            -- ⚠ GREYED, NOT HIDDEN. The signal tick is a FEATURE TOGGLE, and the
            -- house rule is grey-in-place for those; hiding is for mode choices, where a
            -- control genuinely does not apply. A vanished dropdown also loses the one
            -- thing worth seeing while the signal is off: where it WOULD draw.
            -- (The Trinkets and Potions group below stays hidden, deliberately, and says
            -- why -- greying that pair would imply strong window works without them.)
            local surface = P.PIH_SurfaceOf(key)
            local signalOff = (surface == nil)
            if signalOff then surface = "none" end

            -- Inline, so the checkbox above is its label. A second heading saying
            -- "Surface" over every row would triple the words for no added meaning.
            local dd = GUI:CreateDropdown(parent, label, P.PIH_SurfaceOptions(key),
                nil, nil, nil,
                -- ⚠ NEVER nil: this widget survives a profile switch for one frame,
                -- and the shared dropdown's display refresh treats a nil answer as "try
                -- the saved-variable fallback", which was never given -- a Lua error on
                -- every profile switch away from the helper. "none" is a value the menu
                -- owns, so a dying row reads honestly until it is rebuilt away.
                function() return P.PIH_SurfaceOf(key) or "none" end,
                function(v)
                    local ok, why = P.PIH_SetSurface(key, v)
                    if not ok then DF:DebugWarn("AURADESIGNER",
                        "PIH: surface %s refused -- %s", tostring(v), tostring(why)) end
                    Refresh()   -- the other rows' menus re-grey around it
                end,
                -- ⚠ An INLINE dropdown does not own its slot: CreateDropdown only stamps
                -- fixedRowHeight on the standalone form, so this literal is authoritative and
                -- a hand-guessed one gets read. Content is 24 tall; the tight gap is right
                -- because hiding the label makes it a compact row -- its control sits beside
                -- its name (the checkbox above) rather than under it.
                { inline = true })
            if signalOff and dd.SetEnabled then dd:SetEnabled(false) end
            g:AddWidget(dd, 24 + GUI.RowGapTight)

            -- ⚠ THE CLASH WARNING, AND IT IS SCOPED ON PURPOSE. pickWinner decides from
            -- config alone and never asks what is on the unit, so a clash is fully knowable
            -- while someone is setting it up -- no guessing, no "this might happen".
            -- It appears only on the three surfaces that actually take a single winner, and
            -- it names the fix that exists rather than describing the problem.
            -- ⚠ Only while OUR effect is actually in the contest: the named fix
            -- can be applied to our own signal too (custom-mode border), and the warning
            -- must go when it is.
            local selfIn = P.PIH_SelfContends(surface, key)
            local clashes, who = 0, nil
            if selfIn then clashes, who = P.PIH_ClashOn(surface) end
            -- ⚠ OUR OWN SIBLING COUNTS TOO, on a contended surface across records.
            -- PIH_ClashOn skips anything carrying a helper mark, because two signals on one
            -- record are prevented outright rather than warned about. "Already infused" is
            -- on its own record though, so it can genuinely lose a border or a text to one
            -- of the other two -- a real contest that would otherwise go unwarned precisely
            -- because it was ours.
            local sibling = selfIn and P.PIH_SiblingContends
                and P.PIH_SiblingContends(surface, key) or nil
            if sibling then
                clashes = clashes + 1
                who = who or pihLabel(sibling)
            end
            if clashes > 0 then
                who = who or L["Another effect"]
                -- More than one contender: naming only the first would read as "fix this
                -- one and you are done", which would not be true.
                if clashes > 1 then who = format(L["%s and %d more"], who, clashes - 1) end
                -- A CAUTION BOX, the addon's own construct for a warning panel -- the same
                -- one the click-casting dialog and the profiler use. It briefly became gold
                -- text on the belief that the box was what broke the layout; it was not, and
                -- a warning that looks like every other warning is worth the box.
                -- The checkbox's own label key rides as a placeholder so a translator
                -- renders it ONCE -- hardcoding the words here let the sentence and the
                -- control it points at drift apart in any other language.
                pihNote(g, (surface == "border")
                    and format(L["%s already colours the border. Only one can show — tick '%s' on one of them, or move this signal somewhere else."], who, L["Give this aura its own border"])
                    or  format(L["%s already colours this text. Only one can show — raise this signal's priority, or move it somewhere else."], who),
                    "caution")
            end

            -- Icons sit BESIDE the colour dropdown, equal weight: with "None" in the
            -- menu, one row enumerates colour-only / icons-only / both. Every row has
            -- the same flow -- tick, dropdown, icons -- which is what three earlier
            -- shapes kept breaking by parking the trinkets control under the wrong
            -- signal. ⚠ Strong's tick is labelled by what it SHOWS -- its
            -- amplifier half -- because icons cannot make its cooldown-AND-amplifier
            -- judgement; a bare "As icons" there would over-promise. The colour tint
            -- stays the only display that judges.
            local which = PIH_ICON_OF[key]
            local iconLabel = (key == "strong")
                and L["Their trinkets and potions as icons"] or L["As icons"]
            g:AddWidget(GUI:CreateCheckbox(parent, iconLabel, nil, nil, nil,
                function() return P.PIH_IconsShow(which) end,
                function(v)
                    P.PIH_SetIconsShow(which, v)
                    Refresh()
                end))
        end

        pihGroup(L["What to Show"], function(g)
            -- ☠ A LABEL IN THE FIRST BOX, NOT A FREE-FLOATING INFO BANNER. The banner was
            -- built and removed the same day: it measures its own height a frame after it is
            -- drawn, and this column stacks its children at fixed offsets with no reflow
            -- seam -- so the banner grew from its 34px placeholder and landed on top of the
            -- box below it. That failure is documented in GUI:RelayoutHost, which names the
            -- same symptom on the indicator cards ("the Duration Bar header overlapping the
            -- Pandemic section's collapse bar") and fixes it through `dfAD_ReflowWidgets`,
            -- a seam the indicator cards publish and this column does not.
            -- ⚠ Inside a group, a measured label re-flows its host and settles. Outside one
            -- it has nothing to tell. Same converge, different owner.
            pihNote(g,
                L["Tick what makes someone worth infusing. It shows on your group frames."])

            signalRow(g, "burst", L["Big cooldown"])
            signalRow(g, "strong", L["Big cooldown with a trinket or potion"])
            signalRow(g, "infused", L["Already has active Power Infusion"])


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
            g:AddWidget(GUI:CreateCheckbox(parent,
                L["Hide the helper while Power Infusion is on cooldown"], nil, nil, nil,
                function() return P.PIH_Settings().gateEnabled ~= false end,
                function(v) P.PIH_SetGateEnabled(v) end))


            -- ☠☠ TWO ONE-LINE NOTES, AND THE LENGTH IS THE WHOLE POINT.
            -- Seven attempts went into sizing one long paragraph here, and the readout that
            -- finally produced evidence said this: notes of 38-53 characters reserved their
            -- space to within 2px, while the 359-character one was out by 93. Short notes are
            -- exact; long ones drift, whatever constant is used. So the fix is not a better
            -- estimate, it is text that fits on one line -- where ceil() has nothing to round
            -- up and the estimate cannot be wrong.
            --
            -- ⚠ WHAT WAS CUT, AND WHY THESE TWO SURVIVED. The paragraph had four sentences.
            -- The swap rule is already written into the dropdown entry itself ("Health Bar
            -- (swap with Big cooldown)"), and it appears at the moment it matters rather than
            -- in advance. That "Already has active Power Infusion" can share follows from the
            -- two lines below. These two are the only facts nothing else on the panel ever
            -- states, so they are the two that had to stay.
            --
            -- ⚠ No inline highlighting left either: these name display types, not
            -- indicators, and the display-type names are short and already capitalised.
            pihNote(g, L["Health Bar and Background can show several indicators at once."])
            pihNote(g, L["Border and Text colours show only one at a time."])
            -- The one navigational fact text is genuinely needed for. Only while the
            -- icon group exists: position is not a question about icons that are not there.
            if pihAnyIconGroup() then
                pihNote(g, L["Move and size the icons under Layout Groups."])
            end
        end)

        -- ☠ ONLY WHILE STRONG WINDOW IS ON. These two are what the signal MEANS, so on
        -- their own they are a question about nothing. Shown rather than greyed, because a
        -- greyed pair would invite the reading that strong window works without them.
        if P.PIH_SignalOn("strong") then
            pihGroup(L["Trinkets and Potions"], function(g)
                -- ☠ UNTICKING BOTH TAKES THE SIGNAL WITH IT. Strong window is "a cooldown
                -- AND (a potion OR a trinket)". With neither ticked the amplifier group is
                -- empty, resolveConditions skips it, bails on fewer than two groups, and the
                -- effect silently degrades into a duplicate of the burst signal. So the
                -- recipe deletes it instead, and ticking one back brings it into existence.
                g:AddWidget(GUI:CreateCheckbox(parent, L["Combat potions"], nil, nil, nil,
                    function() return P.PIH_Settings().potions == true end,
                    function(v) P.PIH_SetAmplifier("potions", v); Refresh() end))
                g:AddWidget(GUI:CreateCheckbox(parent, L["On-use trinkets"], nil, nil, nil,
                    function() return P.PIH_Settings().trinkets == true end,
                    function(v) P.PIH_SetAmplifier("trinkets", v); Refresh() end))
            end)
        end

        pihGroup(L["Never Show On"], function(g)
            -- ⚠ FAILS OPEN. A group with no assigned roles reads as "no role" for everyone
            -- and nothing is excluded. Marking a tank you did not want is a smaller failure
            -- than silently hiding the signal on the damage dealers you did.
            g:AddWidget(GUI:CreateCheckbox(parent, L["Tanks"], nil, nil, nil,
                function() return (P.PIH_Settings().roles or {}).TANK == true end,
                function(v) P.PIH_SetRole("TANK", v) end))
            g:AddWidget(GUI:CreateCheckbox(parent, L["Healers"], nil, nil, nil,
                function() return (P.PIH_Settings().roles or {}).HEALER == true end,
                function(v) P.PIH_SetRole("HEALER", v) end))
            pihNote(g,
                L["Only applies when the group has roles."])
        end)

        -- ☠ COLLAPSIBLE, AND THIRTEEN ROWS IS WHY. Everything else in this panel is two or
        -- three ticks; a class list is as long as the game has classes, and most people
        -- will never open it. The summary on the header carries the state while it is
        -- folded, so the box does not have to be open to be honest.
        pihGroup(L["Classes to Watch"], function(g)
            -- ☠ ABOVE THE TICKS, NOT BELOW THEM. Fourteen rows is far enough that a line
            -- underneath is a line nobody reads -- it arrives after the reader has already
            -- decided what the box does. The one sentence that explains the box goes where
            -- the reader still needs it.
            pihNote(g, L["Untick a class to ignore its cooldowns."])

            -- ☠ ABOVE THE LIST, NOT UNDER IT. Fourteen ticks is far enough that a button at
            -- the bottom is a button nobody scrolls to -- and this is the escape hatch for
            -- the thing the list cannot do (single spells), so it has to be visible while
            -- someone is still deciding the list is not enough.
            --
            -- ⭐ GUI:OpenFilterInDesigner, NOT a bare SelectTab. It switches the page AND
            -- scrolls to this filter, selects it and pulses it. Its own comment records why:
            -- the hand-written version "landed you on the page with nothing indicated, which
            -- is indistinguishable from a broken link" -- which is exactly what was here.
            pihNote(g,
                L["To add or remove single spells, open the list itself."])
            local cfID = P.PIH_CooldownFilterID and P.PIH_CooldownFilterID()
            local fdBtn = GUI:CreateButton(parent, L["Filter Designer"], 140, 22, function()
                GUI:OpenFilterInDesigner("custom", cfID)
                -- ⚠ TWICE, ONE FRAME APART, AND THAT IS A WORKAROUND. _fdFocusFilter reads
                -- GetVerticalScrollRange to clamp its scroll, and on the page's FIRST build
                -- that range is still 0 -- so the clamp pins the scroll at the top and the
                -- row it selected and pulsed is somewhere below the fold. The second call
                -- runs after layout, when the range is real. The proper fix is a deferred
                -- retry inside _fdFocusFilter itself; that file is Danders' and it is on the
                -- list for him rather than edited from here.
                if C_Timer and C_Timer.After then
                    C_Timer.After(0, function() GUI:OpenFilterInDesigner("custom", cfID) end)
                end
            end)
            if not (cfID and GUI.Pages and GUI.Pages["auras_filterdesigner"]) then
                -- ⚠ THE SHARED TREATMENT, not a hand-written grey. CreateButton routes
                -- through StyleButton, which owns SetDisabled: dim backdrop, faint border, label
                -- alpha, wash suppressed. Disable() plus a literal text colour rendered a NORMAL
                -- backdrop with grey text, visibly unlike every other disabled button in the
                -- addon. Caught in Danders' PR review.
                if fdBtn.SetDisabled then fdBtn:SetDisabled(true)
                else fdBtn:Disable(); fdBtn.Text:SetTextColor(0.4, 0.4, 0.4) end
            end
            g:AddWidget(fdBtn, 28)

            for _, token in ipairs(P.PIH_ClassList()) do
                local classFile = token
                -- Read at call time: SpellPicker.lua loads after this file, so the display
                -- helper does not exist yet at file scope.
                local name = (classFile == "@racials") and L["Racials"]
                    or ((DF.FilterRegistry and DF.FilterRegistry.ClassDisplayName
                        and DF.FilterRegistry.ClassDisplayName(classFile)) or classFile)
                g:AddWidget(GUI:CreateCheckbox(parent, name, nil, nil, nil,
                    function() return P.PIH_ClassOn(classFile) end,
                    function(v) P.PIH_SetClassOn(classFile, v) end))
            end
        -- ⚠ NO showSummary. The collapsed summary concatenates every child label, which for
        -- thirteen classes and a two-line note is a wall of text rather than a summary. The
        -- header alone says what is folded away, which is what a summary was for.
        end, { collapsible = true, collapseKey = "pihelper:onlywatch" })

        pihGroup(L["Sound Alert"], function(g)
            -- ☠ TWO SETTINGS, NOT ONE. The key remembers WHICH sound, the switch remembers
            -- WHETHER -- so turning it off and back on does not make anyone hunt for their
            -- sound a second time. Silent until chosen, either way: a cue nobody asked for
            -- is the fastest route to the whole feature being switched off.
            g:AddWidget(GUI:CreateCheckbox(parent, L["Play a sound when someone becomes worth infusing"],
                nil, nil, nil,
                function() return P.PIH_Settings().soundOn == true end,
                function(v) P.PIH_SetSoundOn(v); Refresh() end))
            if P.PIH_Settings().soundOn then
                g:AddWidget(GUI:CreateSoundDropdown(parent, L["Sound"],
                    P.PIH_Settings(), "soundLSMKey",
                    function() P.PIH_ApplySound() end), GUI.RowHeight.dropdown)
                -- ⚠ Stated rather than discovered in a fight: sound rides the same gate as
                -- the visuals, and it announces new windows only -- a window already open
                -- when the gate re-opens stays silent, because the visuals already carry it.
                pihNote(g,
                    L["Only plays while the helper is showing."])
            end
        end)

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
    local pickerCtx = tostring(IsOtherTab()) .. "|" .. tostring(ResolveSpec())
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

    -- ── NORMAL: three pinned scope cards ──
    if not skipAdd then
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

    -- ── POWER INFUSION HELPER (priest only) ──
    -- The block itself is S.BuildPIHelperPane above -- one definition, two
    -- layouts, the same bargain the add flow's scope cards struck.
    -- ☠ OTHER BUFFS ONLY, AND THAT IS NOT TIDINESS -- IT IS THE ONLY TAB WHERE IT WORKS.
    -- The pool a record lives in decides its caster filter before anything else: My Buffs means
    -- "auras I cast", and poolFilter returns that before it ever consults othersOnly. The helper
    -- watches OTHER people's cooldowns, so My Buffs is the one place it is guaranteed to match
    -- nothing. It was addable there and silently did nothing, which is a lying control.
    --
    -- ⚠ The recipe already writes into the Other Buffs pool wherever it is invoked from, so this
    -- is no longer about correctness -- it is about not offering a button whose result lives
    -- somewhere the user was not looking. Its indicators appear in that tab's list; the card
    -- should be in the same place as the thing it creates.
    -- ⭐ And a side benefit the user named: My Buffs is where most people work, and the helper's
    -- rows would be clutter there for everyone who never uses it.
    -- ☠ AND NOT IN THE ROW LAYOUT'S HEAD AREA. skipAdd is that layout's flag,
    -- and it mounts the SAME builder behind its own "Power Infusion Helper"
    -- popout row (AuraDesigner/UI/Rows.lua) -- drawn here too, the helper
    -- would stand twice on one page.
    if select(2, UnitClass("player")) == "PRIEST" and S.activeBuffTab == "other"
        and not skipAdd then
        yPos = S.BuildPIHelperPane(parent, {
            startY  = yPos,
            -- The split panel's own redraw verb -- exactly what every callback
            -- in the inline block used to run.
            Refresh = function() S.SwitchTab("effects") end,
        })
    end

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
    local obHint
    if IsOtherTab() then
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
    local effects = CollectAllEffects()

    -- Apply filter
    local filtered = {}
    for _, effect in ipairs(effects) do
        if S.activeFilter == "all" or effect.typeKey == S.activeFilter then
            tinsert(filtered, effect)
        end
    end

    if #filtered == 0 then
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

    parent:SetHeight(max(-yPos + 20, 200))
end

-- ── BUILD GLOBAL TAB ──
-- Wraps the existing BuildGlobalView into the tab content frame
S.BuildGlobalTab = function()
    if not S.tabContentFrame then return end
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
