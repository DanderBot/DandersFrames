local addonName, DF = ...

-- ============================================================
-- MEASURED PANDEMIC-WINDOW STATE, BY SPELL ID
-- ============================================================
-- Which auras actually HAVE a refresh window, measured in game rather than reasoned about.
--
-- ☠ WHY THIS HAS TO BE A TABLE AND CANNOT BE AN API CALL. There is no per-spell query. The
-- window is computed per live aura INSTANCE:
--     carriedOverToNewCast = GetRefreshExtendedDuration(unit, id) - GetAuraBaseDuration(unit, id)
-- and C_UnitAuras.GetRefreshExtendedDuration is flagged `RequiresValidUnitAuraInstance`, so
-- it needs a unit and an auraInstanceID. Nothing in C_Spell answers it either (checked on
-- 12.1.5: only GetSpellChargeDuration / GetSpellCooldownDuration / GetSpellLossOfControl-
-- CooldownDuration exist). The editor is configuring a spell that is not on anyone right
-- now, so the only way to know is to have watched it happen and remembered.
--
-- ★ THE RULE THIS DATA SERVES — and it is what makes an incomplete table safe:
--   * every id behind an aura measured NO  -> grey the Pandemic section, say why
--   * any id YES, or any id NEVER MEASURED -> change nothing
-- So a missing spell can never remove a working feature, and nothing is inferred from not
-- having seen something. Silence is not evidence — the same trap that nearly had Icy Veins
-- proposed as a live spell because its name row still resolved in the build dump.
--
-- ⚠ WHAT THIS SAMPLE IS, STATED PLAINLY. 179 spells across six healer specs plus whatever
-- potions, trinkets, forms and world buffs were up at the time. It is a proof that the
-- method works, collected on the characters available — NOT a survey. 74 entries were taken
-- on both PTR and retail on different builds with zero conflicts, so the measurements
-- themselves are solid; the COVERAGE is not. Do not read the NO list as "the game's
-- non-pandemic auras".
--   ⇒ The gate is near-silent for a DPS tracking their own DoTs, and that is expected
--     rather than broken. Pandemic-worth-tracking auras are heal-over-time effects, so a
--     healer-shaped sample is aimed at the right target; the unmeasured rest matter only if
--     someone goes looking.
--
-- ☠ THE ONE FAILURE DIRECTION THIS OPENS, accepted knowingly: a shipped NO that Blizzard
-- later makes wrong greys a feature that would work, and the user cannot tell that from
-- intended behaviour. That is the argument for eventually letting a LOCALLY measured YES
-- override a shipped NO — never the reverse, or a spell nobody happened to cast this week
-- starts greying itself. Local learning now exists (Pandemic.lua's sampler, riding the
-- container's out-of-combat sweep, stored per game build in DandersFramesDB_v2.pandemicWindows);
-- this table is its seed.
--
-- ⚠ MEASUREMENTS, NOT OPINIONS. Several NOs are counter-intuitive and were re-checked:
-- Prayer of Mending, Earth Shield, Echo of Light, Atonement and Dawnlight all read no.
-- Divine Hymn 64843 has a window and 64844 does not; Mana Tea 115294 has one and 115867
-- does not. Ebon Might has one despite not being a HoT. Do not "correct" a row from memory.
--
-- Source: Maelareth's probe, lab discussion 98ceb448 (2026-08-20/21), design agreed there.
-- Replace this file wholesale when a wider harvest lands; nothing else needs to change.

DF.PandemicWindows = {
    -- ── HAS a refresh window ────────────────────────────────────────────────
    -- Realistically trackable
    [774]     = true,  -- Rejuvenation
    [155777]  = true,  -- Germination
    [8936]    = true,  -- Regrowth
    [33763]   = true,  -- Lifebloom
    [1227806] = true,  -- Lifebloom (second id)
    [48438]   = true,  -- Wild Growth
    [740]     = true,  -- Tranquility
    [119611]  = true,  -- Renewing Mist
    [124682]  = true,  -- Enveloping Mist
    [115175]  = true,  -- Soothing Mist
    [61295]   = true,  -- Riptide
    [355941]  = true,  -- Dream Breath
    [376788]  = true,  -- Dream Breath (second id)
    [366155]  = true,  -- Reversion
    [367364]  = true,  -- Reversion (second id)
    -- Technically windowed, but unlikely anyone tracks pandemic on them. Kept because the
    -- gate reads the MEASUREMENT, not the judgement — these keep a live Pandemic panel.
    [64843]   = true,  -- Divine Hymn        (64844 is the one WITHOUT)
    [115294]  = true,  -- Mana Tea           (115867 is the one WITHOUT)
    [156322]  = true,  -- Eternal Flame
    [382024]  = true,  -- Earthliving Weapon
    [395296]  = true,  -- Ebon Might
    [462568]  = true,  -- Elemental Resistance  (PTR only, never seen again on retail)

    -- ── NO refresh window ───────────────────────────────────────────────────
    [17]      = false, -- Power Word: Shield
    [586]     = false, -- Fade
    [768]     = false, -- Cat Form
    [783]     = false, -- Travel Form
    [1022]    = false, -- Blessing of Protection
    [1044]    = false, -- Blessing of Freedom
    [1126]    = false, -- Mark of the Wild
    [2479]    = false, -- Honorless Target
    [5487]    = false, -- Bear Form
    [10060]   = false, -- Power Infusion
    [16870]   = false, -- Clearcasting
    [19236]   = false, -- Desperate Prayer
    [21562]   = false, -- Power Word: Fortitude
    [25771]   = false, -- Forbearance
    [31821]   = false, -- Aura Mastery
    [31884]   = false, -- Avenging Wrath
    [33206]   = false, -- Pain Suppression
    -- ☠☠ TEMPORARILY REMOVED FOR A LIVE TEST OF THE SAMPLER — RESTORE THIS LINE.
    -- Prayer of Mending is seeded NO and is a priest spell, so removing it leaves a spell
    -- that is UNKNOWN on a fresh install: the Pandemic panel stays live until the 30s sweep
    -- sees it on you out of combat, learns "no refresh mechanic", and greys it with the
    -- note. That is the whole learning path, observable in one cast.
    -- ⚠ Renew was the first candidate for this test and is the wrong one twice over: it is
    -- not in this table at all (nothing to remove), and it HAS a window — our own PTR-8
    -- proof, the ring went green at 4.5s on a 15s base — so learning it would write YES and
    -- nothing visible would change.
    -- ⚠ The learned value lands in DandersFramesDB_v2.pandemicWindows[41635]; clear that
    -- entry to re-run the test, and uncomment below when the test is done.
    -- [41635]   = false, -- Prayer of Mending
    [45242]   = false, -- Focused Will
    [47788]   = false, -- Guardian Spirit
    [53390]   = false, -- Tidal Waves
    [54149]   = false, -- Infusion of Light
    [58984]   = false, -- Shadowmeld
    [64844]   = false, -- Divine Hymn
    [65081]   = false, -- Body and Soul
    [73685]   = false, -- Unleash Life
    [77489]   = false, -- Echo of Light
    [106898]  = false, -- Stampeding Roar
    [114052]  = false, -- Ascendance
    [114108]  = false, -- Soul of the Forest
    [114255]  = false, -- Surge of Light
    [115867]  = false, -- Mana Tea
    [116680]  = false, -- Thunder Focus Tea
    [116849]  = false, -- Life Cocoon
    [121557]  = false, -- Angelic Feather
    [129914]  = false, -- Combat Wisdom
    [166646]  = false, -- Windwalking
    [186403]  = false, -- Sign of Battle
    [193065]  = false, -- Protective Light
    [194384]  = false, -- Atonement
    [197916]  = false, -- Lifecycles
    [198069]  = false, -- Power of the Dark Side
    [200183]  = false, -- Apotheosis
    [202090]  = false, -- Teachings of the Monastery
    [223819]  = false, -- Divine Purpose
    [276111]  = false, -- Divine Steed
    [325174]  = false, -- Spirit Link Totem
    [343818]  = false, -- Invoke Chi-Ji, the Red Crane
    [357170]  = false, -- Time Dilation
    [358267]  = false, -- Hover
    [358733]  = false, -- Glide
    [362877]  = false, -- Temporal Compression
    [363502]  = false, -- Dream Flight
    [363534]  = false, -- Rewind
    [364343]  = false, -- Echo
    [369299]  = false, -- Essence Burst
    [370537]  = false, -- Stasis
    [370553]  = false, -- Tip the Scales
    [370562]  = false, -- Stasis
    [370901]  = false, -- Leaping Flames
    [372014]  = false, -- Visage
    [372470]  = false, -- Scarlet Adaptation
    [373183]  = false, -- Harsh Discipline
    [373267]  = false, -- Lifebind
    [374227]  = false, -- Zephyr
    [375234]  = false, -- Time Spiral
    [377234]  = false, -- Thrill of the Skies
    [378081]  = false, -- Nature's Swiftness
    [381748]  = false, -- Blessing of the Bronze
    [383235]  = false, -- Undercurrent
    [383648]  = false, -- Earth Shield
    [385266]  = false, -- Zenet Hatchling
    [387350]  = false, -- Ouroboros
    [387804]  = false, -- Echoing Protection
    [388367]  = false, -- Ohn'ahra's Gusts
    [388497]  = false, -- Secret Infusion
    [388498]  = false, -- Secret Infusion
    [390148]  = false, -- Flow State
    [390978]  = false, -- Twist of Fate
    [390993]  = false, -- Lightweaver
    [391528]  = false, -- Convoke the Spirits
    [392268]  = false, -- Essence Burst
    [394454]  = false, -- Echoing Freedom
    [400126]  = false, -- Forestwalk
    [400745]  = false, -- Afterimage
    [404184]  = false, -- Ground Skimming
    [404464]  = false, -- Flight Style: Skyriding
    [405963]  = false, -- Divine Image
    [406220]  = false, -- Chi Cocoon
    [409895]  = false, -- Verdant Embrace
    [410089]  = false, -- Prescience
    [414273]  = false, -- Hand of Divinity
    [421453]  = false, -- Ultimate Penitence
    [427296]  = false, -- Healing Elixir
    [428737]  = false, -- Harmony of the Grove
    [430747]  = false, -- Soar
    [431415]  = false, -- Sun Sear
    [431462]  = false, -- Will of the Dawn
    [431522]  = false, -- Dawnlight
    [431654]  = false, -- Primacy
    [431698]  = false, -- Temporal Burst
    [432180]  = false, -- Dance of the Wind
    [439530]  = false, -- Symbiotic Blooms
    [443028]  = false, -- Celestial Conduit
    [443113]  = false, -- Strength of the Black Ox
    [443421]  = false, -- Heart of the Jade Serpent
    [443569]  = false, -- Chi-Ji's Swiftness
    [443572]  = false, -- Crane Stance
    [443574]  = false, -- Ox Stance
    [443575]  = false, -- Tiger Stance
    [443576]  = false, -- Serpent Stance
    [443616]  = false, -- Heart of the Jade Serpent
    [446017]  = false, -- August Phoenix
    [446334]  = false, -- Zen Pulse
    [447988]  = false, -- Light of the Martyr
    [448508]  = false, -- Jade Sanctuary
    [449609]  = false, -- Lighter Than Air
    [449887]  = false, -- Voidheart
    [450193]  = false, -- Entropic Rift
    [450521]  = false, -- Aspect of Harmony
    [450552]  = false, -- Jade Walk
    [450574]  = false, -- Flow of Chi
    [450711]  = false, -- Aspect of Harmony
    [450769]  = false, -- Aspect of Harmony
    [451452]  = false, -- Mantra of Purity
    [451514]  = false, -- Balanced Stratagem
    [453112]  = false, -- Power Surge
    [453406]  = false, -- Whirling Earth
    [453407]  = false, -- Whirling Water
    [453409]  = false, -- Whirling Air
    [453846]  = false, -- Resonant Energy
    [456369]  = false, -- Amplification Core
    [457387]  = false, -- Wind Barrier
    [460127]  = false, -- Courage of the White Tiger
    [462854]  = false, -- Skyfury
    [470077]  = false, -- Coalescing Water
    [472433]  = false, -- Evangelism
    [1215495] = false, -- Cyrce's Circlet
    [1231418] = false, -- Recuperate
    [1232285] = false, -- Efflorescence
    [1242747] = false, -- Inner Flame
    [1242759] = false, -- Twin Echoes
    [1248705] = false, -- Skyfire Heel
    [1253591] = false, -- Master the Darkness
    [1253593] = false, -- Void Shield
    [1256579] = false, -- Merithra's Blessing
    [1259994] = false, -- Hope
    [1260565] = false, -- Spiritfont
    [1261724] = false, -- Tigereye Brew
    [1262766] = false, -- Benediction
    [1267089] = false, -- Stormstream Totem
    [1270990] = false, -- Potential Energy
    [1272710] = false, -- Crimson Blessing
    [1287425] = false, -- Void-Touched Orbs
    [1291636] = false, -- Temporal Barrier
    [1292922] = false, -- Coalescence
    [1293799] = false, -- Trovehunter's Bounty
    [1307888] = false, -- Healing Rain
}
