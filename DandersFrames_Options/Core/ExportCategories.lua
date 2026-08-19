-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
-- Resident consumers (selective import/export in Core/Profile.lua) load this
-- addon on demand before touching the tables below.
local DF = DandersFrames

-- ============================================================
-- EXPORT/IMPORT CATEGORY DEFINITIONS
-- ============================================================
-- Each setting from PartyDefaults/RaidDefaults is assigned to a category
-- for selective import/export

DF.ExportCategories = {
    -- Frame positions on screen
    position = {
        -- (Removed) "anchorPoint" -- gone from the defaults too. It was never read,
        -- so exporting it only carried a dead value between profiles.
        "anchorX",
        "anchorY",
        "hideDragOverlay",
        "permanentMover",
        "permanentMoverActionLeft",
        "permanentMoverActionRight",
        "permanentMoverActionShiftLeft",
        "permanentMoverActionShiftRight",
        "permanentMoverAnchor",
        "permanentMoverAttachTo",
        "permanentMoverColor",
        "permanentMoverCombatColor",
        "permanentMoverHeight",
        "permanentMoverHideInCombat",
        "permanentMoverOffsetX",
        "permanentMoverOffsetY",
        "permanentMoverPullTimerDuration",
        "permanentMoverShowOnHover",
        "permanentMoverWidth",
        "raidAnchorX",
        "raidAnchorY",
        "raidEnabled",
        "raidLocked",
    },
    -- Size, spacing, growth, sorting
    layout = {
        "frameHeight",
        "framePadding",
        "frameScale",
        "frameSpacing",
        "frameWidth",
        "gridSize",
        "growDirection",
        "growthAnchor",
        "hideDefaultPlayerFrame",
        "hidePlayerFrame",
        "locked",
        "pixelPerfect",
        "raidFlatColumnAnchor",
        "raidFlatFrameAnchor",
        "raidFlatGrowthAnchor",
        "raidFlatHorizontalSpacing",
        "raidFlatPlayerAnchor",
        "raidFlatReverseFillOrder",
        "raidFlatVerticalSpacing",
        "raidGroupAnchor",
        "raidGroupDisplayOrder",
        "raidGroupOrder",
        "raidGroupRowGrowth",
        "raidGroupSpacing",
        "raidGroupVisible",
        "raidGroupsPerRow",
        "raidPlayerAnchor",
        "raidPlayerGroupFirst",
        "raidPlayersPerRow",
        "raidRowColSpacing",
        "raidTestFrameCount",
        "raidUseGroups",
        "restedIndicator",
        "restedIndicatorGlow",
        "restedIndicatorIcon",
        "restedIndicatorOffsetX",
        "restedIndicatorOffsetY",
        "restedIndicatorSize",
        "snapToGrid",
        "soloMode",
        "sortAlphabetical",
        "sortByClass",
        "sortClassOrder",
        "sortEnabled",
        "sortRoleOrder",
        "sortSelfPosition",
        "sortSeparateMeleeRanged",
        "testFrameCount",
        "useFrameSort",
    },
    -- Health, power, absorb and heal-prediction bars
    bars = {
        "absorbBarAnchor",
        "absorbBarAttachedClampMode",
        "absorbBarBackgroundColor",
        "absorbBarBlendMode",
        "absorbBarColor",
        "absorbBarFrameLevel",
        "absorbBarHeight",
        "absorbBarMode",
        "absorbBarOrientation",
        "absorbBarOverlayReverse",
        "absorbBarOvershieldAlpha",
        "absorbBarOvershieldColor",
        "absorbBarOvershieldReverse",
        "absorbBarOvershieldStyle",
        "absorbBarReverse",
        "absorbBarShowOvershield",
        "absorbBarTexture",
        "absorbBarWidth",
        "absorbBarX",
        "absorbBarY",
        "backgroundClassAlpha",
        "backgroundColor",
        "backgroundColorMode",
        "backgroundMode",
        "backgroundTexture",
        "classColorAlpha",
        "frameBorderSize",
        "healAbsorbBarAnchor",
        "healAbsorbBarBackgroundColor",
        "healAbsorbBarBlendMode",
        "healAbsorbBarColor",
        "healAbsorbBarHeight",
        "healAbsorbBarMode",
        "healAbsorbBarOrientation",
        "healAbsorbBarOverlayReverse",
        "healAbsorbBarReverse",
        "healAbsorbBarTexture",
        "healAbsorbBarWidth",
        "healAbsorbBarX",
        "healAbsorbBarY",
        "healPredictionAllColor",
        "healPredictionAnchor",
        "healPredictionBackgroundColor",
        "healPredictionBlendMode",
        "healPredictionEnabled",
        "healPredictionFrameLevel",
        "healPredictionHeight",
        "healPredictionMode",
        "healPredictionMyColor",
        "healPredictionOrientation",
        "healPredictionOthersColor",
        "healPredictionReverse",
        "healPredictionShowMode",
        "healPredictionShowOverheal",
        "healPredictionTexture",
        "healPredictionWidth",
        "healPredictionX",
        "healPredictionY",
        "healthColor",
        "healthColorHigh",
        "healthColorHighUseClass",
        "healthColorHighWeight",
        "healthColorLow",
        "healthColorLowUseClass",
        "healthColorLowWeight",
        "healthColorMedium",
        "healthColorMediumUseClass",
        "healthColorMediumWeight",
        -- ⚠ THE STOP LIST AND THE LEGACY STAGES BOTH TRAVEL, on purpose. The stops are
        -- what the renderer reads; the Low/Medium/High + Weight keys above are what an
        -- older build reads, and what DF:MigrateHealthColorStops converts from. Export
        -- only the stops and a profile sent to someone on the previous build loses its
        -- gradient entirely; export only the stages and the receiving build's migration
        -- would rebuild the list from them, silently discarding any stop the sender had
        -- added beyond the original three.
        "healthColorStops",
        "healthColorMode",
        "healthOrientation",
        "healthTexture",
        "missingHealthClassAlpha",
        "missingHealthColor",
        "missingHealthColorHigh",
        "missingHealthColorHighUseClass",
        "missingHealthColorHighWeight",
        "missingHealthColorLow",
        "missingHealthColorLowUseClass",
        "missingHealthColorLowWeight",
        "missingHealthColorMedium",
        "missingHealthColorMediumUseClass",
        "missingHealthColorMediumWeight",
        "missingHealthColorStops",   -- see the healthColorStops note above
        "missingHealthColorMode",
        "missingHealthGradientAlpha",
        "missingHealthTexture",
        "powerBarHeight",
        "reducedMaxHealthBlendMode",
        "reducedMaxHealthClipHealthBar",
        "reducedMaxHealthColor",
        "reducedMaxHealthEnabled",
        "reducedMaxHealthTexture",
        "resourceBarAnchor",
        "resourceBarBackgroundColor",
        "resourceBarBackgroundEnabled",
        "resourceBarBorderBlendMode",
        "resourceBarBorderColor",
        "resourceBarBorderColorSource",
        "resourceBarBorderEnabled",
        "resourceBarBorderGradientDirection",
        "resourceBarBorderGradientEndColor",
        "resourceBarBorderGradientStartColor",
        "resourceBarBorderInset",
        "resourceBarBorderShadowColor",
        "resourceBarBorderShadowEnabled",
        "resourceBarBorderShadowOffsetX",
        "resourceBarBorderShadowOffsetY",
        "resourceBarBorderShadowSize",
        "resourceBarBorderSize",
        "resourceBarBorderStyle",
        "resourceBarBorderTexture",
        "resourceBarClassColor",
        "resourceBarClassFilter",
        "resourceBarColorMode",
        "resourceBarCustomColor",
        "resourceBarEnabled",
        "resourceBarFrameLevel",
        "resourceBarHeight",
        "resourceBarMatchWidth",
        "resourceBarOrientation",
        "resourceBarReverseFill",
        "resourceBarShowBorder",
        "resourceBarShowDPS",
        "resourceBarShowHealer",
        "resourceBarShowInSoloMode",
        "resourceBarShowTank",
        "resourceBarSmooth",
        "resourceBarTexture",
        "resourceBarWidth",
        "resourceBarX",
        "resourceBarY",
        "showPowerBar",
        "smoothBars",
    },
    -- Buff/debuff icons, filters (blacklist travels with this category)
    auras = {
        "buffAlpha",
        "buffAnchor",
        "buffBorderBlendMode",
        "buffBorderColor",
        "buffBorderGradientDirection",
        "buffBorderGradientEndColor",
        "buffBorderGradientStartColor",
        "buffBorderInset",
        "buffBorderOffsetX",
        "buffBorderOffsetY",
        "buffBorderShadowColor",
        "buffBorderShadowEnabled",
        "buffBorderShadowOffsetX",
        "buffBorderShadowOffsetY",
        "buffBorderShadowSize",
        "buffBorderSize",
        "buffBorderStyle",
        "buffBorderTexture",
        "buffDeduplicateDefensives",
        "buffDurationAnchor",
        "buffDurationBarBGColor",
        "buffDurationBarColor",
        "buffDurationBarEnabled",
        "buffDurationBarGap",
        "buffDurationBarColorMode",
        "buffDurationBarHeight",
        "buffDurationBarPosition",
        "buffDurationBarReverseFill",
        "buffDurationBarTexture",
        "buffDurationColor",
        "buffDurationColorByTime",
        "buffDurationFont",
        "buffDurationFormat",
        "buffDurationHideAboveEnabled",
        "buffDurationHideAboveThreshold",
        "buffDurationHideOnPermanent",
        "buffDurationOutline",
        "buffDurationScale",
        "buffDurationX",
        "buffDurationY",
        "buffMaxDurationEnabled",
        "buffMaxDurationMinutes",
        "buffHidePermanent",
        "buffFilterSelection",
        "buffGrowth",
        "buffHideSwipe",
        "buffMax",
        "buffOffsetX",
        "buffOffsetY",
        "buffPaddingX",
        "buffPaddingY",
        -- Pandemic (refresh-window cue, 12.1 PTR 8)
        "buffPandemicBorderBlendMode",
        "buffPandemicBorderColor",
        "buffPandemicBorderGradientDirection",
        "buffPandemicBorderGradientEndColor",
        "buffPandemicBorderGradientStartColor",
        "buffPandemicBorderInset",
        "buffPandemicBorderOffsetX",
        "buffPandemicBorderOffsetY",
        "buffPandemicBorderShadowColor",
        "buffPandemicBorderShadowEnabled",
        "buffPandemicBorderShadowOffsetX",
        "buffPandemicBorderShadowOffsetY",
        "buffPandemicBorderShadowSize",
        "buffPandemicBorderSize",
        "buffPandemicBorderStyle",
        "buffPandemicBorderTexture",
        "buffPandemicEnabled",
        "buffPandemicFlash",
        "buffPandemicFlashSpeed",
        "buffPandemicMode",
        "buffPandemicShowBorder",
        "buffPandemicTintAlpha",
        "buffPandemicTintColor",
        "buffPandemicTintInset",
        "buffScale",
        "buffShowBorder",
        "buffShowDuration",
        "buffSize",
        "buffStackAnchor",
        "buffStackColor",
        "buffStackFont",
        "buffStackOutline",
        "buffStackScale",
        "buffStackX",
        "buffStackY",
        "buffWrap",
        "debuffAlpha",
        "debuffAnchor",
        "debuffBlacklist",
        "debuffBorderBlendMode",
        "debuffBorderColor",
        "debuffBorderColorBleed",
        "debuffBorderColorByType",
        "debuffBorderColorCurse",
        "debuffBorderColorDisease",
        "debuffBorderColorMagic",
        "debuffBorderColorPoison",
        "debuffBorderGradientDirection",
        "debuffBorderGradientEndColor",
        "debuffBorderGradientStartColor",
        "debuffBorderInset",
        "debuffBorderOffsetX",
        "debuffBorderOffsetY",
        "debuffBorderShadowColor",
        "debuffBorderShadowEnabled",
        "debuffBorderShadowOffsetX",
        "debuffBorderShadowOffsetY",
        "debuffBorderShadowSize",
        "debuffBorderSize",
        "debuffBorderStyle",
        "debuffBorderTexture",
        "debuffDurationAnchor",
        "debuffDurationBarBGColor",
        "debuffDurationBarColor",
        "debuffDurationBarEnabled",
        "debuffDurationBarGap",
        "debuffDurationBarColorMode",
        "debuffDurationBarHeight",
        "debuffDurationBarPosition",
        "debuffDurationBarReverseFill",
        "debuffDurationBarTexture",
        "debuffDurationColorByTime",
        "debuffDurationFont",
        "debuffDeduplicateDesigner",
        "debuffDispelBorderInset",
        "debuffDispelSymbolAnchor",
        "debuffDispelSymbolColor",
        "debuffDispelSymbolEnabled",
        "debuffDispelSymbolFont",
        "debuffDispelSymbolOutline",
        "debuffDispelSymbolScale",
        "debuffDispelSymbolX",
        "debuffDispelSymbolY",
        "debuffDurationFormat",
        "debuffDurationColor",
        "debuffStackColor",
        "debuffDurationHideAboveEnabled",
        "debuffDurationHideAboveThreshold",
        "debuffDurationHideOnPermanent",
        "debuffDurationOutline",
        "debuffDurationScale",
        "debuffDurationX",
        "debuffDurationY",
        "debuffFilterBoss",
        "debuffFilterCrowdControl",
        "debuffFilterDispellable",
        "debuffFilterNonPlayer",
        "debuffFilterPriority",
        "debuffFilterRaid",
        "debuffFilterRole",
        "debuffGrowth",
        "debuffHideSwipe",
        "debuffImportantBadge",
        "debuffImportantBadgeColor",
        "debuffImportantBadgePoint",
        "debuffImportantBadgeSize",
        "debuffImportantBadgeX",
        "debuffImportantBadgeY",
        "debuffImportantHighlight",
        "debuffImportantMarkColor",
        "debuffImportantScale",
        "debuffMax",
        "debuffMaxDurationEnabled",
        "debuffMaxDurationKeepImportant",
        "debuffMaxDurationMinutes",
        "debuffOffsetX",
        "debuffOffsetY",
        "debuffPaddingX",
        "debuffPaddingY",
        "debuffScale",
        "debuffShowBorder",
        "debuffShowDuration",
        "debuffSize",
        "debuffStackAnchor",
        "debuffStackFont",
        "debuffStackOutline",
        "debuffStackScale",
        "debuffStackX",
        "debuffStackY",
        "debuffWrap",
        "defensiveFilterSelection",
        "directBuffOnlyMine",
        "directBuffShowAll",
        "directBuffSortMineFirst",
        "directBuffSortOrder",
        "directBuffSortReverse",
        "directDebuffDispellableMode",
        "directDebuffShowAll",
        "directDebuffSortMineFirst",
        "directDebuffSortOrder",
        "directDebuffSortReverse",
        "fadeDeadAuras",
        "showBuffs",
        "showDebuffs",
    },
    -- Dispel overlay
    dispel = {
        "dispelAnimate",
        "dispelBorderAlpha",
        "dispelBorderInset",
        "dispelBorderSize",
        "dispelGradientAlpha",
        "dispelGradientBlendMode",
        "dispelGradientDarkenAlpha",
        "dispelGradientDarkenEnabled",
        "dispelGradientOnCurrentHealth",
        "dispelOverlayFrameLevel",
        "dispelGradientSize",
        "dispelGradientStyle",
        "dispelIconAlpha",
        "dispelIconOffsetX",
        "dispelIconOffsetY",
        "dispelIconPosition",
        "dispelIconSize",
        "dispelOverlayDispelType",
        "dispelOverlayEnabled",
        "dispelShowBorder",
        "dispelShowGradient",
        "dispelShowIcon",
    },
    -- Missing raid-buff indicator
    missingBuffs = {
        "missingBuffCheckAttackPower",
        "missingBuffCheckBronze",
        "missingBuffCheckIntellect",
        "missingBuffCheckSkyfury",
        "missingBuffCheckStamina",
        "missingBuffCheckVersatility",
        "missingBuffClassDetection",
        "missingBuffHideFromBar",
        "missingBuffIconAnchor",
        "missingBuffIconBorderAnimationColor",
        "missingBuffIconBorderAnimationCornerLength",
        "missingBuffIconBorderAnimationFrequency",
        "missingBuffIconBorderAnimationInset",
        "missingBuffIconBorderAnimationLength",
        "missingBuffIconBorderAnimationMask",
        "missingBuffIconBorderAnimationOffsetX",
        "missingBuffIconBorderAnimationOffsetY",
        "missingBuffIconBorderAnimationParticles",
        "missingBuffIconBorderAnimationProcStart",
        "missingBuffIconBorderAnimationScale",
        "missingBuffIconBorderAnimationSidesAxis",
        "missingBuffIconBorderAnimationThickness",
        "missingBuffIconBorderAnimationType",
        "missingBuffIconBorderBlendMode",
        "missingBuffIconBorderColor",
        "missingBuffIconBorderColorSource",
        "missingBuffIconBorderGradientDirection",
        "missingBuffIconBorderGradientEndColor",
        "missingBuffIconBorderGradientStartColor",
        "missingBuffIconBorderInset",
        "missingBuffIconBorderOffsetX",
        "missingBuffIconBorderOffsetY",
        "missingBuffIconBorderShadowColor",
        "missingBuffIconBorderShadowEnabled",
        "missingBuffIconBorderShadowOffsetX",
        "missingBuffIconBorderShadowOffsetY",
        "missingBuffIconBorderShadowSize",
        "missingBuffIconBorderSize",
        "missingBuffIconBorderStyle",
        "missingBuffIconBorderTexture",
        "missingBuffIconEnabled",
        "missingBuffIconFrameLevel",
        "missingBuffIconScale",
        "missingBuffIconShowBorder",
        "missingBuffIconSize",
        "missingBuffIconX",
        "missingBuffIconY",
    },
    -- Defensive bar + external defensive icon
    defensives = {
        "defensiveBarGrowth",
        "defensiveBarMax",
        "defensiveBarSpacing",
        "defensiveBarWrap",
        -- defensiveBarX / defensiveBarY removed: no such settings exist (only
        -- Growth/Max/Spacing/Wrap do). Harmless at runtime because
        -- ExtractCategorySettings nil-guards, but they made /df debug exportaudit
        -- report two phantoms, so the audit never came back clean.
        "defensiveDurationBarBGColor",
        "defensiveDurationBarColor",
        "defensiveDurationBarEnabled",
        "defensiveDurationBarGap",
        "defensiveDurationBarColorMode",
        "defensiveDurationBarHeight",
        "defensiveDurationBarPosition",
        "defensiveDurationBarReverseFill",
        "defensiveDurationBarTexture",
        "defensiveIconAnchor",
        "defensiveIconBorderAnimationColor",
        "defensiveIconBorderAnimationCornerLength",
        "defensiveIconBorderAnimationFrequency",
        "defensiveIconBorderAnimationInset",
        "defensiveIconBorderAnimationLength",
        "defensiveIconBorderAnimationMask",
        "defensiveIconBorderAnimationOffsetX",
        "defensiveIconBorderAnimationOffsetY",
        "defensiveIconBorderAnimationParticles",
        "defensiveIconBorderAnimationProcStart",
        "defensiveIconBorderAnimationScale",
        "defensiveIconBorderAnimationSidesAxis",
        "defensiveIconBorderAnimationThickness",
        "defensiveIconBorderAnimationType",
        "defensiveIconBorderBlendMode",
        "defensiveIconBorderColor",
        "defensiveIconBorderColorSource",
        "defensiveIconBorderGradientDirection",
        "defensiveIconBorderGradientEnabled",
        "defensiveIconBorderGradientEndColor",
        "defensiveIconBorderGradientStartColor",
        "defensiveIconBorderInset",
        "defensiveIconBorderOffsetX",
        "defensiveIconBorderOffsetY",
        "defensiveIconBorderShadowColor",
        "defensiveIconBorderShadowEnabled",
        "defensiveIconBorderShadowOffsetX",
        "defensiveIconBorderShadowOffsetY",
        "defensiveIconBorderShadowSize",
        "defensiveIconBorderSize",
        "defensiveIconBorderStyle",
        "defensiveIconBorderTexture",
        "defensiveIconDurationColor",
        "defensiveIconDurationColorByTime",
        "defensiveIconDurationFont",
        "defensiveIconDurationHideOnPermanent",
        "defensiveIconDurationOutline",
        "defensiveIconDurationAnchor",
        "defensiveIconDurationScale",
        "defensiveIconDurationFormat",
        "defensiveIconDurationX",
        "defensiveIconDurationY",
        "defensiveIconEnabled",
        "defensiveIconFrameLevel",
        "defensiveIconHideSwipe",
        "defensiveIconScale",
        "defensiveIconShowBorder",
        "defensiveIconShowDuration",
        "defensiveIconSize",
        -- ☠ This list is EXPLICIT, not prefix-matched — a new key that is not named here
        -- silently fails to travel with an exported profile. No Font/Color entries: those
        -- two keys deliberately have no defaults (see Core/Config.lua), but they are still
        -- listed so a user who sets one keeps it.
        "defensiveIconStackAnchor",
        "defensiveIconStackColor",
        "defensiveIconStackFont",
        "defensiveIconStackOutline",
        "defensiveIconStackScale",
        "defensiveIconStackX",
        "defensiveIconStackY",
        "defensiveIconX",
        "defensiveIconY",
        "defensiveSortOrder",
    },
    -- Targeted spells (incl. personal)
    -- ⚰ DEPRECATED-TARGETED-SPELLS — ⚠ this category is MIXED: the
    -- personalTargetedSpell* keys are live and stay, the targetedSpell* ones go
    -- with the on-frame feature. Do not delete the category wholesale; the
    -- personal display would silently stop exporting. See the block comment at
    -- the top of Features\TargetedSpells.lua.
    targetedSpells = {
        "personalTargetedSpellAlpha",
        "personalTargetedSpellBorderAnimationColor",
        "personalTargetedSpellBorderAnimationCornerLength",
        "personalTargetedSpellBorderAnimationFrequency",
        "personalTargetedSpellBorderAnimationInset",
        "personalTargetedSpellBorderAnimationLength",
        "personalTargetedSpellBorderAnimationMask",
        "personalTargetedSpellBorderAnimationOffsetX",
        "personalTargetedSpellBorderAnimationOffsetY",
        "personalTargetedSpellBorderAnimationParticles",
        "personalTargetedSpellBorderAnimationProcStart",
        "personalTargetedSpellBorderAnimationScale",
        "personalTargetedSpellBorderAnimationSidesAxis",
        "personalTargetedSpellBorderAnimationThickness",
        "personalTargetedSpellBorderAnimationType",
        "personalTargetedSpellBorderBlendMode",
        "personalTargetedSpellBorderColor",
        "personalTargetedSpellBorderGradientDirection",
        "personalTargetedSpellBorderGradientEndColor",
        "personalTargetedSpellBorderGradientStartColor",
        "personalTargetedSpellBorderInset",
        "personalTargetedSpellBorderShadowColor",
        "personalTargetedSpellBorderShadowEnabled",
        "personalTargetedSpellBorderShadowOffsetX",
        "personalTargetedSpellBorderShadowOffsetY",
        "personalTargetedSpellBorderShadowSize",
        "personalTargetedSpellBorderSize",
        "personalTargetedSpellBorderStyle",
        "personalTargetedSpellBorderTexture",
        "personalTargetedSpellDurationColor",
        "personalTargetedSpellDurationFont",
        "personalTargetedSpellDurationOutline",
        "personalTargetedSpellDurationScale",
        "personalTargetedSpellDurationX",
        "personalTargetedSpellDurationY",
        "personalTargetedSpellEnabled",
        "personalTargetedSpellGrowth",
        "personalTargetedSpellHighlightImportant",
        "personalTargetedSpellImportantBorderAnimationColor",
        "personalTargetedSpellImportantBorderAnimationCornerLength",
        "personalTargetedSpellImportantBorderAnimationFrequency",
        "personalTargetedSpellImportantBorderAnimationInset",
        "personalTargetedSpellImportantBorderAnimationLength",
        "personalTargetedSpellImportantBorderAnimationMask",
        "personalTargetedSpellImportantBorderAnimationOffsetX",
        "personalTargetedSpellImportantBorderAnimationOffsetY",
        "personalTargetedSpellImportantBorderAnimationParticles",
        "personalTargetedSpellImportantBorderAnimationProcStart",
        "personalTargetedSpellImportantBorderAnimationScale",
        "personalTargetedSpellImportantBorderAnimationSidesAxis",
        "personalTargetedSpellImportantBorderAnimationThickness",
        "personalTargetedSpellImportantBorderAnimationType",
        "personalTargetedSpellImportantBorderBlendMode",
        "personalTargetedSpellImportantBorderColor",
        "personalTargetedSpellImportantBorderGradientDirection",
        "personalTargetedSpellImportantBorderGradientEndColor",
        "personalTargetedSpellImportantBorderGradientStartColor",
        "personalTargetedSpellImportantBorderInset",
        "personalTargetedSpellImportantBorderShadowColor",
        "personalTargetedSpellImportantBorderShadowEnabled",
        "personalTargetedSpellImportantBorderShadowOffsetX",
        "personalTargetedSpellImportantBorderShadowOffsetY",
        "personalTargetedSpellImportantBorderShadowSize",
        "personalTargetedSpellImportantBorderSize",
        "personalTargetedSpellImportantBorderStyle",
        "personalTargetedSpellImportantBorderTexture",
        "personalTargetedSpellImportantOnly",
        "personalTargetedSpellInArena",
        "personalTargetedSpellInBattlegrounds",
        "personalTargetedSpellInDungeons",
        "personalTargetedSpellInOpenWorld",
        "personalTargetedSpellInRaids",
        "personalTargetedSpellInterruptedDuration",
        "personalTargetedSpellInterruptedShowX",
        "personalTargetedSpellInterruptedTintAlpha",
        "personalTargetedSpellInterruptedTintColor",
        "personalTargetedSpellInterruptedXColor",
        "personalTargetedSpellInterruptedXSize",
        "personalTargetedSpellMaxIcons",
        "personalTargetedSpellScale",
        "personalTargetedSpellShowBorder",
        "personalTargetedSpellShowDuration",
        "personalTargetedSpellShowInterrupted",
        "personalTargetedSpellShowSwipe",
        "personalTargetedSpellSize",
        "personalTargetedSpellSpacing",
        "personalTargetedSpellX",
        "personalTargetedSpellY",
    },
    -- Targeted List page
    targetedList = {
        "targetedListBackgroundAlpha",
        "targetedListBorderBlendMode",
        "targetedListBorderColor",
        "targetedListBorderGradientDirection",
        "targetedListBorderGradientEndColor",
        "targetedListBorderGradientStartColor",
        "targetedListBorderInset",
        "targetedListBorderShadowColor",
        "targetedListBorderShadowEnabled",
        "targetedListBorderShadowOffsetX",
        "targetedListBorderShadowOffsetY",
        "targetedListBorderShadowSize",
        "targetedListBorderSize",
        "targetedListBorderStyle",
        "targetedListBorderTexture",
        "targetedListDurationAlign",
        "targetedListDurationAnchor",
        "targetedListDurationFontSize",
        "targetedListDurationX",
        "targetedListDurationY",
        "targetedListEnabled",
        "targetedListFadeOutDuration",
        "targetedListFont",
        "targetedListFontOutline",
        "targetedListFontSize",
        "targetedListGrowth",
        "targetedListHeight",
        "targetedListHideOutOfCombat",
        "targetedListHideOwnCasts",
        "targetedListHighlightColor",
        "targetedListHighlightImportant",
        "targetedListIconPosition",
        "targetedListImportantOnly",
        "targetedListInArena",
        "targetedListInBattlegrounds",
        "targetedListInDungeons",
        "targetedListInOpenWorld",
        "targetedListInRaids",
        "targetedListInterruptTextAlign",
        "targetedListInterruptTextAnchor",
        "targetedListInterruptTextFontSize",
        "targetedListInterruptTextWidth",
        "targetedListInterruptTextX",
        "targetedListInterruptTextY",
        "targetedListInterruptedFlashDuration",
        "targetedListInterruptibleColor",
        "targetedListMaxBars",
        "targetedListSelfTargetColor",
        "targetedListSelfTargetColorEnabled",
        "targetedListShowArrowPrefix",
        "targetedListShowArrowSuffix",
        "targetedListShowBorder",
        "targetedListShowDuration",
        "targetedListShowIcon",
        "targetedListShowSpellName",
        "targetedListShowTargetName",
        "targetedListShowUntargeted",
        "targetedListSortOrder",
        "targetedListSpacing",
        "targetedListSpellNameAlign",
        "targetedListSpellNameAnchor",
        "targetedListSpellNameFontSize",
        "targetedListSpellNameWidth",
        "targetedListSpellNameX",
        "targetedListSpellNameY",
        "targetedListStylePreset",
        "targetedListTargetNameAlign",
        "targetedListTargetNameAnchor",
        "targetedListTargetNameClassColor",
        "targetedListTargetNameFontSize",
        "targetedListTargetNameWidth",
        "targetedListTargetNameX",
        "targetedListTargetNameY",
        "targetedListTexture",
        "targetedListUninterruptibleColor",
        "targetedListWidth",
        "targetedListX",
        "targetedListY",
        "targetedListZoomIcon",
    },
    -- Legacy name/status/health text & fonts
    text = {
        "fontShadowColor",
        "fontShadowOffsetX",
        "fontShadowOffsetY",
        "groupLabelColor",
        "groupLabelEnabled",
        "groupLabelFont",
        "groupLabelFontSize",
        "groupLabelFormat",
        "groupLabelOffsetX",
        "groupLabelOffsetY",
        "groupLabelOutline",
        "groupLabelPosition",
        "healthFont",
        "healthFontSize",
        "healthTextAbbreviate",
        "healthTextAnchor",
        "healthTextColor",
        "healthTextFormat",
        "healthTextHidePercent",
        "healthTextOutline",
        "healthTextUseClassColor",
        "healthTextX",
        "healthTextY",
        "nameColorClass",
        "nameFont",
        "nameFontSize",
        "nameTextAnchor",
        "nameTextColor",
        "nameTextLength",
        "nameTextOutline",
        "nameTextTruncateMode",
        "nameTextUseClassColor",
        "nameTextX",
        "nameTextY",
        "showHealthText",
        "statusTextAnchor",
        "statusTextColor",
        "statusTextEnabled",
        "statusTextFont",
        "statusTextFontSize",
        "statusTextOutline",
        "statusTextX",
        "statusTextY",
    },
    -- Text Designer (preset library travels with this category)
    textDesigner = {
        "textDesigner",
        "textDesignerPreset",
    },
    -- Status icons (role, leader, raid target, AFK, ...)
    icons = {
        "afkIconAlpha",
        "afkIconAnchor",
        "afkIconEnabled",
        "afkIconFrameLevel",
        "afkIconHideInCombat",
        "afkIconScale",
        "afkIconShowText",
        "afkIconShowTimer",
        "afkIconText",
        "afkIconTextColor",
        "afkIconTimerColor",
        "afkIconTimerFont",
        "afkIconTimerFontSize",
        "afkIconTimerOutline",
        "afkIconTimerX",
        "afkIconTimerY",
        "afkIconX",
        "afkIconY",
        "bgCarrierIconAlpha",
        "bgCarrierIconAnchor",
        "bgCarrierIconEnabled",
        "bgCarrierIconFrameLevel",
        "bgCarrierIconScale",
        "bgCarrierIconShowText",
        "bgCarrierIconText",
        "bgCarrierIconTextColor",
        "bgCarrierIconX",
        "bgCarrierIconY",
        "combatIconAlpha",
        "combatIconAnchor",
        "combatIconEnabled",
        "combatIconFrameLevel",
        "combatIconScale",
        "combatIconX",
        "combatIconY",
        "leaderIconAlpha",
        "leaderIconAnchor",
        "leaderIconEnabled",
        "leaderIconFrameLevel",
        "leaderIconHideInCombat",
        "leaderIconScale",
        "leaderIconX",
        "leaderIconY",
        "phasedIconAlpha",
        "phasedIconAnchor",
        "phasedIconEnabled",
        "phasedIconFrameLevel",
        "phasedIconHideInCombat",
        "phasedIconScale",
        "phasedIconShowLFGEye",
        "phasedIconShowText",
        "phasedIconText",
        "phasedIconTextColor",
        "phasedIconX",
        "phasedIconY",
        "raidRoleIconAlpha",
        "raidRoleIconAnchor",
        "raidRoleIconEnabled",
        "raidRoleIconFrameLevel",
        "raidRoleIconHideInCombat",
        "raidRoleIconScale",
        "raidRoleIconShowAssist",
        "raidRoleIconShowTank",
        "raidRoleIconShowText",
        "raidRoleIconTextAssist",
        "raidRoleIconTextColor",
        "raidRoleIconTextTank",
        "raidRoleIconX",
        "raidRoleIconY",
        "raidTargetIconAlpha",
        "raidTargetIconAnchor",
        "raidTargetIconEnabled",
        "raidTargetIconFrameLevel",
        "raidTargetIconHideInCombat",
        "raidTargetIconScale",
        "raidTargetIconX",
        "raidTargetIconY",
        "readyCheckIconAlpha",
        "readyCheckIconAnchor",
        "readyCheckIconEnabled",
        "readyCheckIconFrameLevel",
        "readyCheckIconHideInCombat",
        "readyCheckIconPersist",
        "readyCheckIconScale",
        "readyCheckIconX",
        "readyCheckIconY",
        "resurrectionIconAlpha",
        "resurrectionIconAnchor",
        "resurrectionIconEnabled",
        "resurrectionIconFrameLevel",
        "resurrectionIconScale",
        "resurrectionIconShowText",
        "resurrectionIconTextCasting",
        "resurrectionIconTextColor",
        "resurrectionIconX",
        "resurrectionIconY",
        "roleIconAlpha",
        "roleIconAnchor",
        "roleIconExternalDPS",
        "roleIconExternalHealer",
        "roleIconExternalTank",
        "roleIconFrameLevel",
        "roleIconHideInCombat",
        "roleIconScale",
        "roleIconShowDPS",
        "roleIconShowHealer",
        "roleIconShowTank",
        "roleIconStyle",
        "roleIconX",
        "roleIconY",
        "statusIconFont",
        "statusIconFontOutline",
        "statusIconFontSize",
        "summonIconAlpha",
        "summonIconAnchor",
        "summonIconEnabled",
        "summonIconFrameLevel",
        "summonIconHideInCombat",
        "summonIconScale",
        "summonIconShowText",
        "summonIconTextAccepted",
        "summonIconTextColor",
        "summonIconTextDeclined",
        "summonIconTextPending",
        "summonIconX",
        "summonIconY",
        "vehicleIconAlpha",
        "vehicleIconAnchor",
        "vehicleIconEnabled",
        "vehicleIconFrameLevel",
        "vehicleIconHideInCombat",
        "vehicleIconScale",
        "vehicleIconShowText",
        "vehicleIconText",
        "vehicleIconTextColor",
        "vehicleIconX",
        "vehicleIconY",
    },
    -- Everything else (highlights, tooltips, range, misc)
    other = {
        "aggroColorHighThreat",
        "aggroColorHighestThreat",
        "aggroColorTanking",
        "aggroHideOnTanks",
        "aggroHighlightAlpha",
        "aggroHighlightFrameLevel",
        "aggroHighlightInset",
        "aggroHighlightMode",
        "aggroHighlightThickness",
        "aggroOnlyTanking",
        "aggroUseCustomColors",
        -- colorPickerGlobalOverride / colorPickerOverride are account-wide now, so
        -- they are no longer part of a profile and don't travel with an export.
        "fadeDeadBackground",
        "fadeDeadBackgroundColor",
        "fadeDeadFrames",
        "fadeDeadHealthBar",
        "fadeDeadIcons",
        "fadeDeadName",
        "fadeDeadPowerBar",
        "fadeDeadStatusText",
        "fadeDeadUseCustomColor",
        "frameBorderBlendMode",
        "frameBorderColor",
        "frameBorderColorSource",
        "frameBorderGradientDirection",
        "frameBorderGradientEnabled",
        "frameBorderGradientEndColor",
        "frameBorderGradientStartColor",
        "frameBorderInset",
        "frameBorderOffsetX",
        "frameBorderOffsetY",
        "frameBorderShadowColor",
        "frameBorderShadowEnabled",
        "frameBorderShadowOffsetX",
        "frameBorderShadowOffsetY",
        "frameBorderShadowSize",
        "frameBorderStyle",
        "frameBorderTexture",
        "frameBorderUseClassColor",
        "frameShowBorder",
        "frameFadeAlpha",
        "frameFadeAlphaInCombat",
        "frameFadeAlphaOutOfCombat",
        "frameFadeHoverScope",
        "frameFadeHoverUsesCombat",
        "frameFadeSplitCombat",
        "healthFadeAlpha",
        "healthFadeEnabled",
        "healthFadeThreshold",
        "hfCancelOnDispel",
        "hideBlizzardPartyFrames",
        "hideBlizzardRaidFrames",
        "hoverHighlightAlpha",
        "hoverHighlightFrameLevel",
        "hoverHighlightColor",
        "hoverHighlightInset",
        "hoverHighlightMode",
        "hoverHighlightThickness",
        "oorAbsorbBarAlpha",
        "oorAuraDesignerAlpha",
        "oorAurasAlpha",
        "oorBackgroundAlpha",
        "oorBorderAlpha",
        "oorDefensiveIconAlpha",
        "oorDispelOverlayAlpha",
        "oorEnabled",
        "oorHealthBarAlpha",
        "oorIconsAlpha",
        "oorMissingBuffAlpha",
        "oorMissingHealthAlpha",
        "oorPowerBarAlpha",
        "oorTextAlpha",
        "petAnchor",
        "petBackgroundColor",
        "petBorderBlendMode",
        "petBorderColor",
        "petBorderGradientDirection",
        "petBorderGradientEndColor",
        "petBorderGradientStartColor",
        "petBorderInset",
        "petBorderShadowColor",
        "petBorderShadowEnabled",
        "petBorderShadowOffsetX",
        "petBorderShadowOffsetY",
        "petBorderShadowSize",
        "petBorderSize",
        "petBorderStyle",
        "petBorderTexture",
        "petEnabled",
        "petFrameHeight",
        "petFrameWidth",
        "petGroupAnchor",
        "petGroupGrowth",
        "petGroupLabel",
        "petGroupMode",
        "petGroupOffsetX",
        "petGroupOffsetY",
        "petGroupShowLabel",
        "petGroupSpacing",
        "petHealthAnchor",
        "petHealthBgColor",
        "petHealthColor",
        "petHealthColorMode",
        "petHealthFont",
        "petHealthFontOutline",
        "petHealthFontSize",
        "petHealthTextColor",
        "petHealthX",
        "petHealthY",
        "petMatchOwnerHeight",
        "petMatchOwnerWidth",
        "petNameAnchor",
        "petNameColor",
        "petNameFont",
        "petNameFontOutline",
        "petNameFontSize",
        "petNameMaxLength",
        "petNameX",
        "petNameY",
        "petOffsetX",
        "petOffsetY",
        "petPowerBarHeight",
        "petPowerColor",
        "petPowerColorMode",
        "petShowBorder",
        "petShowHealthText",
        "petShowPowerBar",
        "petTexture",
        "rangeAlpha",
        "rangeCheckSpellID",
        "rangeFadeAlpha",
        "rangeUpdateInterval",
        "selectionHighlightAlpha",
        "selectionHighlightFrameLevel",
        "selectionHighlightColor",
        "selectionHighlightInset",
        "selectionHighlightMode",
        "selectionHighlightThickness",
        "showBlizzardSideMenu",
        "showMinimapButton",
        "testAnimateHealth",
        "testAnimateTargetedList",
        "testBuffCount",
        "testDebuffCount",
        "testDefensiveCount",
        "testPreset",
        "testShowAbsorbs",
        "testShowAggro",
        "testShowAuraDesigner",
        "testShowAuras",
        "testShowDispelGlow",
        "testShowHealPrediction",
        "testShowLabels",
        "testShowMissingBuff",
        "testShowOutOfRange",
        "testShowPersonalTargeted",
        "testShowPets",
        "testShowReducedMaxHealth",
        "testShowSelection",
        "testShowStatusIcons",
        "testShowTargetedList",
        "testShowTextDesigner",
        "tooltipBindingAnchor",
        "tooltipBindingAnchorPos",
        "tooltipBindingDisableInCombat",
        "tooltipBindingEnabled",
        "tooltipBindingX",
        "tooltipBindingY",
        "tooltipBuffAnchor",
        "tooltipBuffAnchorPos",
        "tooltipBuffDisableInCombat",
        "tooltipBuffEnabled",
        "tooltipBuffX",
        "tooltipBuffY",
        "tooltipDebuffAnchor",
        "tooltipDebuffAnchorPos",
        "tooltipDebuffDisableInCombat",
        "tooltipDebuffEnabled",
        "tooltipDebuffX",
        "tooltipDebuffY",
        "tooltipADGroupsEnabled",
        "tooltipADIndicatorsEnabled",
        "tooltipADBarsEnabled",
        "tooltipDefensiveAnchor",
        "tooltipDefensiveAnchorPos",
        "tooltipDefensiveDisableInCombat",
        "tooltipDefensiveEnabled",
        "tooltipDefensiveX",
        "tooltipDefensiveY",
        "tooltipFrameAnchor",
        "tooltipFrameAnchorPos",
        "tooltipFrameDisableInCombat",
        "tooltipFrameEnabled",
        "tooltipFrameX",
        "tooltipFrameY",
        "tooltipResurrectionEnabled",
    },
    -- Pinned frame sets
    pinnedFrames = {
        "pinnedFrames",
        "pinnedHideMover",
        "pinnedSnapToGrid",
    },
    -- Aura Designer config (preset library travels with this category)
    auraDesigner = {
        "auraDesigner",
        "auraDesignerPreset",
    },
    -- Auto layouts (pulls both preset libraries)
    autoLayout = {
        "raidAutoProfiles",
    },
}

-- ===========================================
-- CATEGORY DISPLAY INFO
-- ===========================================
DF.ExportCategoryInfo = {
    position = {
        name = "Position",
        description = "Where frames appear on screen",
        order = 1,
    },
    layout = {
        name = "Frame Layout",
        description = "Size, spacing, growth, sorting",
        order = 2,
    },
    bars = {
        name = "Bars",
        description = "Health, power, absorbs, heal prediction",
        order = 3,
    },
    auras = {
        name = "Auras",
        description = "Buff & debuff icons, filters, blacklist",
        order = 4,
    },
    dispel = {
        name = "Dispel",
        description = "Dispel overlay and indicators",
        order = 5,
    },
    missingBuffs = {
        name = "Missing Buffs",
        description = "Missing raid-buff indicator",
        order = 7,
    },
    defensives = {
        name = "Defensives",
        description = "Defensive bar and external defensive icon",
        order = 8,
    },
    targetedSpells = {
        name = "Targeted Spells",
        description = "Targeted spell alerts (incl. personal)",
        order = 10,
    },
    targetedList = {
        name = "Targeted List",
        description = "Targeted players list",
        order = 11,
    },
    text = {
        name = "Text",
        description = "Name, status, health text & fonts",
        order = 12,
    },
    textDesigner = {
        name = "Text Designer",
        description = "Text Designer config & preset library",
        order = 13,
    },
    icons = {
        name = "Status Icons",
        description = "Role, leader, raid target, AFK, etc.",
        order = 14,
    },
    other = {
        name = "Other",
        description = "Aggro, selection, range, tooltips, pets",
        order = 15,
    },
    pinnedFrames = {
        name = "Pinned Frames",
        description = "Separate frame sets for selected players",
        order = 16,
    },
    auraDesigner = {
        name = "Aura Designer",
        description = "Spec-specific aura indicators and effects",
        order = 17,
    },
    autoLayout = {
        name = "Auto Layouts",
        description = "Raid size auto-layout profiles",
        order = 18,
    },
    -- ☠ NO ENTRY IN DF.ExportCategories, DELIBERATELY. The four colour tables live at
    -- the PROFILE ROOT (classColors / powerColors / roleColors / dispelColors), not in
    -- the party/raid mode tables, so there are no mode keys to list -- and
    -- ExtractCategorySettings walks pairs(DF.ExportCategories), so a category absent
    -- from that table is simply never visited. The payload is attached by hand in
    -- DF:ExportProfile's selective branch, the same way raidAutoProfiles, auraBlacklist
    -- and linkedSections are.
    --
    -- This category exists because the selective export could not carry colours AT ALL:
    -- the full-export branch copied all four, the selective branch had no equivalent,
    -- and no checkbox could request them. Ticking all sixteen boxes still shipped none
    -- of them, so a shared profile arrived with stock class, power, role and dispel
    -- colours and the recipient's frames visibly did not match.
    colors = {
        name = "Colors",
        description = "Class, power, role and dispel colours",
        order = 19,
    },
}

-- (DF.ExportPresets removed: it was defined here and referenced nowhere. The export
-- page's quick-picks are declared inline at GUI/Pages/Modules.lua, and drifted out of
-- sync with this table long ago -- two sources for one list, one of them unread.)

-- ===========================================
-- HELPER FUNCTIONS
-- ===========================================



-- Extract settings for specific categories from a profile
function DF:ExtractCategorySettings(profile, categories, frameType)
    local result = {}
    local categorySet = {}
    for _, cat in ipairs(categories) do
        categorySet[cat] = true
    end
    
    for category, keys in pairs(self.ExportCategories) do
        if categorySet[category] then
            for _, key in ipairs(keys) do
                if profile[key] ~= nil then
                    result[key] = profile[key]
                end
            end
        end
    end
    
    return result
end

-- Pre-4.6.1 export strings used bundled categories: "icons" also carried the
-- Targeted Spells, Defensives, Missing Buffs and Dispel families, "auras"
-- carried Boss Debuffs, and "text" carried the Text Designer. Selecting one of
-- those names on import must keep meaning what it meant when the string was
-- created, so each old name expands to the categories its keys were re-filed
-- under. The expansion only runs for PRE-SPLIT strings: a string whose stored
-- category list names any post-split category was exported with the new lists,
-- and expanding those would override a deliberately deselected sub-category
-- (the payload carries its keys). Detection: post-split strings that select a
-- parent without its carve-outs have nothing to expand anyway (their payload
-- was trimmed by the new lists), so the stored-name check is the only case
-- that needs the gate.
local LEGACY_CATEGORY_EXPANSION = {
    icons = { "targetedSpells", "defensives", "missingBuffs", "dispel" },
    text  = { "textDesigner" },
}

-- Category names that only exist post-split: any of these in a string's
-- STORED category list marks it as exported with the new lists.
local POST_SPLIT_CATEGORIES = {
    bossDebuffs = true, dispel = true, missingBuffs = true, defensives = true,
    myBuffs = true, targetedSpells = true, targetedList = true, textDesigner = true,
}

-- Merge imported settings into profile for specific categories.
-- exportedCategories = the category list STORED IN THE STRING (not the user's
-- selection) — used only to decide whether the legacy expansion applies.
function DF:MergeCategorySettings(profile, imported, categories, exportedCategories)
    local isLegacyString = true
    if exportedCategories then
        for _, cat in ipairs(exportedCategories) do
            if POST_SPLIT_CATEGORIES[cat] then
                isLegacyString = false
                break
            end
        end
    end

    local categorySet = {}
    for _, cat in ipairs(categories) do
        categorySet[cat] = true
        local expand = isLegacyString and LEGACY_CATEGORY_EXPANSION[cat]
        if expand then
            for _, sub in ipairs(expand) do categorySet[sub] = true end
        end
    end

    local copied = {}
    for category, keys in pairs(self.ExportCategories) do
        if categorySet[category] then
            for _, key in ipairs(keys) do
                if imported[key] ~= nil then
                    profile[key] = imported[key]
                    copied[key] = true
                end
            end
        end
    end

    -- ☠ A PRE-STOPS GRADIENT MUST BECOME STOPS *HERE*, OR IT NEVER DOES. This merge
    -- copies only keys the payload carries, so an export from before the stop list
    -- brings legacy Low/Medium/High stages and no <prefix>Stops -- and the profile's
    -- own stop list survives the merge and shadows them: the renderer resolves the
    -- list first, so the import "works" and the gradient never changes. Permanently,
    -- because DF:MigrateHealthColorStops is presence-gated on the very list that is
    -- still there. Same import class MigrateOORTextAlpha documents for the v4
    -- oorNameTextAlpha payload. Full imports don't need this: they replace the whole
    -- mode table, the stop list vanishes with it, and the renderer's legacy fallback
    -- covers until the next login converts.
    --
    -- ⚠ Gate on `copied`, not on the payload: the payload can carry stage keys whose
    -- category the user UNTICKED, and rebuilding then would overwrite the profile's
    -- edited stop list from its own stale legacy stages (the editor updates only the
    -- list, so the stages rot the moment a stop is touched).
    for _, prefix in ipairs({ "healthColor", "missingHealthColor" }) do
        if not copied[prefix .. "Stops"] then
            local stageApplied = false
            for _, stage in ipairs({ "Low", "Medium", "High" }) do
                if copied[prefix .. stage] or copied[prefix .. stage .. "Weight"]
                    or copied[prefix .. stage .. "UseClass"] then
                    stageApplied = true
                    break
                end
            end
            if stageApplied and DF.LegacyStopsFor then
                -- From the MERGED table, not the payload: a partial payload merges
                -- into the profile's remaining stages, and that mix is what a
                -- pre-stops build would have rendered after this import.
                local pts = DF:LegacyStopsFor(profile, prefix)
                if pts then profile[prefix .. "Stops"] = pts end
            end
        end
    end
end

-- ============================================================
-- EXPORT COMPLETENESS AUDIT (drift guard)
-- ============================================================
-- The category lists above are hand-maintained and historically drifted
-- against Config defaults: pre-4.6.1, 188 live settings (the whole Targeted
-- List page, the buff/debuff border families, permanent movers, My Buff
-- Indicators, ...) were in no category, so selective export silently dropped
-- them. `/df debug exportaudit` recomputes that drift on demand: every Party/Raid
-- default key must be either assigned to a category or EXPLICITLY declared
-- local-only below. Run it whenever defaults or categories change.

-- Keys that deliberately do NOT travel in exports (machine/window state and
-- internal escape hatches, not profile content). Underscore-prefixed
-- migration flags are excluded by rule and don't need listing.
DF.ExportLocalOnly = {
    minimapIcon = true,                                 -- minimap button state
    useSecureHeaders = true,                            -- internal escape hatch (no GUI)

    -- (Removed) five dead-legacy declarations: frameBorderAlpha, auraSourceMode,
    -- defensiveIconShowSwipe, highlightFrames, resurrectionIconHideInCombat. They
    -- hedged against cleanup PRs that had not landed yet — "still present in Config
    -- defaults on this branch but no longer read anywhere". Those PRs have landed:
    -- none of the five is a Config key any more, and only frameBorderAlpha still
    -- exists as a name anywhere (as a signature FIELD derived from
    -- frameBorderColor.a in Frames/Bars.lua — an unrelated symbol). With no default
    -- to suppress, the entries suppressed nothing.
}

-- Keys that legitimately appear in category lists WITHOUT a Config default
-- (GUI-write-only keys where nil is meaningful — plus top-level/legacy
-- carriers). roleBorderColor* left this set with the profile-root roleColors
-- move (the legacy per-mode keys no longer export; roleColors rides the
-- full-export payload like classColors).
local EXPORT_KEYS_WITHOUT_DEFAULTS = {
    afkIconTimerFont = true, afkIconTimerOutline = true,
    auraDesignerPreset = true, textDesignerPreset = true,
    textDesigner = true,                                -- legacy inline table
    -- (Removed) auraDesigner, defensiveIconBorderColorSource and
    -- missingBuffIconBorderColorSource. All three now HAVE Config defaults, so the
    -- allowlist no longer suppressed anything for them — they resolve as normal
    -- exported keys with defaults. textDesigner stays: it genuinely has none.
    raidPlayerGroupFirst = true,
    raidAutoProfiles = true,                            -- top-level key, special-cased in Profile.lua
    -- Config.lua lists this as `= nil` (documentation only — a nil assignment
    -- creates NO table key), so at runtime it has no default: nil means
    -- "inherit absorbBarColor". Set via the Glow Color picker.
    absorbBarOvershieldColor = true,
}

-- Dev tool behind /df debug exportaudit. Returns true when clean.
function DF:AuditExportCategories()
    local assigned = {}
    for _, keys in pairs(DF.ExportCategories) do
        for _, k in ipairs(keys) do assigned[k] = true end
    end

    local defaults = {}
    for k in pairs(DF.PartyDefaults or {}) do defaults[k] = true end
    for k in pairs(DF.RaidDefaults or {}) do defaults[k] = true end

    local missing, phantoms = {}, {}
    for k in pairs(defaults) do
        if not assigned[k] and not DF.ExportLocalOnly[k] and k:sub(1, 1) ~= "_" then
            missing[#missing + 1] = k
        end
    end
    for k in pairs(assigned) do
        if not defaults[k] and not EXPORT_KEYS_WITHOUT_DEFAULTS[k] then
            phantoms[#phantoms + 1] = k
        end
    end
    table.sort(missing)
    table.sort(phantoms)

    if #missing == 0 and #phantoms == 0 then
        DF:Say("Export audit clean", "every default key is categorised or declared local-only")
        return true
    end

    -- ONE block, two sections. Both branches can fire in the same run, so opening
    -- a DF:Out in each made a single audit render as two separate outputs.
    local o = DF:Out("Export Audit")
    if #missing > 0 then
        o:Section(("%d default key(s) in NO export category"):format(#missing))
        o:Line("Selective export will drop these.", "BAD")
        o:More(missing, 12)
    end
    if #phantoms > 0 then
        o:Section(("%d category key(s) with no Config default"):format(#phantoms))
        o:Line("Typo, or needs adding to the allowlist.", "WARN")
        o:More(phantoms, 12)
    end
    return false
end
