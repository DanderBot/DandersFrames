local addonName, DF = ...

-- ============================================================
-- AURA DESIGNER MIGRATIONS -- always loaded
-- ============================================================
-- These rewrite SAVED DATA, so they are data layer, not UI. They lived in
-- AuraDesigner/UI/Options.lua for historical reasons, which becomes a bug the
-- moment the editor is load-on-demand:
--
--   Core.lua runs them on ADDON_LOADED over every saved profile, and its own
--   comment says "load order guarantees that file has registered ... by here".
--   AuraDesigner/Factory.lua runs five of them on the render path.
--   Both call sites are nil-GUARDED -- so with the editor unloaded they would
--   not error, they would SILENTLY SKIP. A player who never opens the settings
--   panel would keep unmigrated saved data while live frames render from it.
--
-- A crash would have been kinder. Keeping these resident removes the question.
-- ☠ New AD migrations belong HERE, and must be added to BOTH GetAuraDesignerDB
-- (the editor's resolver) and the Factory render runner -- see the note above
-- MigrateAbsoluteLevelsLazy about what a mismatch does.

local pairs, ipairs, type = pairs, ipairs, type
local tinsert = table.insert
local floor = math.floor
-- Load-time constant: AuraAdapter.lua loads before this file (see the .toc).
local Adapter = DF.AuraDesigner.Adapter

-- ============================================================
-- HELPERS
-- ============================================================

local function MigrateToSpecScoped(adDB)
    if not adDB then return end

    -- V1: migrate flat adDB.auras → spec-keyed adDB.auras
    if not adDB._specScopedV1 then
        if adDB.auras then
            local isFlat = false
            for _, val in pairs(adDB.auras) do
                -- `border` counts too: an entry that only ever had its border
                -- customised carries neither priority nor indicators, and reading it
                -- as already-spec-scoped stamped _specScopedV1 without migrating —
                -- those auras then rendered nothing, permanently. Core.lua's
                -- equivalent probe has always included it; this copy had drifted.
                if type(val) == "table"
                    and (val.priority ~= nil or val.indicators ~= nil or val.border ~= nil) then
                    isFlat = true
                    break
                end
            end
            if isFlat then
                local oldAuras = adDB.auras
                local newAuras = {}
                local auraToSpecs = {}
                -- Build the name→specs map from the FULL trackable set, not the
                -- curated TrackableAuras table alone: the real set is curated PLUS
                -- the SpellDB class pool (Adapter:GetTrackableAuras). Using only the
                -- curated half meant every pool-sourced aura the user had configured
                -- matched nothing — and the wholesale `adDB.auras = newAuras` below
                -- then deleted it, with no read-back and no log.
                local AD = DF.AuraDesigner
                local adapter = AD and AD.Adapter
                if adapter and adapter.GetTrackableAuras and AD.SpecInfo then
                    for specKey in pairs(AD.SpecInfo) do
                        local ok, list = pcall(adapter.GetTrackableAuras, adapter, specKey)
                        if ok and type(list) == "table" then
                            for _, info in ipairs(list) do
                                if info.name then
                                    if not auraToSpecs[info.name] then auraToSpecs[info.name] = {} end
                                    tinsert(auraToSpecs[info.name], specKey)
                                end
                            end
                        end
                    end
                end
                -- Curated table as a fallback/supplement (also covers the case where
                -- the adapter or the registry is not available at migration time).
                local trackable = AD and AD.TrackableAuras
                if trackable then
                    for specKey, auraList in pairs(trackable) do
                        for _, info in ipairs(auraList) do
                            local seen = auraToSpecs[info.name]
                            if not seen then
                                auraToSpecs[info.name] = { specKey }
                            else
                                local dup = false
                                for _, s in ipairs(seen) do
                                    if s == specKey then dup = true; break end
                                end
                                if not dup then tinsert(seen, specKey) end
                            end
                        end
                    end
                end

                local orphans, orphanCount = nil, 0
                for auraName, auraCfg in pairs(oldAuras) do
                    local specs = auraToSpecs[auraName]
                    if specs then
                        for _, specKey in ipairs(specs) do
                            if not newAuras[specKey] then newAuras[specKey] = {} end
                            newAuras[specKey][auraName] = DF:DeepCopy(auraCfg)
                        end
                    else
                        -- NEVER drop it. Park unmatched configs where they can be
                        -- recovered rather than replacing the table out from under
                        -- them (a SpellDB regen that renames a spell would otherwise
                        -- destroy that aura's config on the next load).
                        orphans = orphans or {}
                        orphans[auraName] = DF:DeepCopy(auraCfg)
                        orphanCount = orphanCount + 1
                    end
                end
                if orphans then
                    adDB._unscopedAuras = orphans
                    if DF.DebugWarn then
                        DF:DebugWarn("AD",
                            "spec-scope migration: %d aura config(s) matched no spec; parked in _unscopedAuras",
                            orphanCount)
                    end
                end
                adDB.auras = newAuras
            end
        end
        adDB._specScopedV1 = true
    end

    -- V2: migrate flat adDB.layoutGroups array → spec-keyed
    if not adDB._specScopedV2 then
        if adDB.layoutGroups then
            -- Detect flat array: first entry has numeric key and .id field
            local isFlat = false
            for k, v in pairs(adDB.layoutGroups) do
                if type(k) == "number" and type(v) == "table" and v.id ~= nil then
                    isFlat = true
                    break
                end
            end
            if isFlat then
                local oldGroups = adDB.layoutGroups
                local newGroups = {}
                -- For each group, find which specs its member auras belong to
                local auraToSpecs = {}
                if adDB.auras then
                    for specKey, specAuras in pairs(adDB.auras) do
                        if type(specAuras) == "table" then
                            for auraName in pairs(specAuras) do
                                if not auraToSpecs[auraName] then auraToSpecs[auraName] = {} end
                                auraToSpecs[auraName][specKey] = true
                            end
                        end
                    end
                end
                for _, group in ipairs(oldGroups) do
                    -- Determine which specs this group's members belong to
                    local targetSpecs = {}
                    if group.members then
                        for _, member in ipairs(group.members) do
                            local specs = auraToSpecs[member.auraName]
                            if specs then
                                for specKey in pairs(specs) do
                                    targetSpecs[specKey] = true
                                end
                            end
                        end
                    end
                    -- Copy group to each relevant spec, filtering members
                    for specKey in pairs(targetSpecs) do
                        if not newGroups[specKey] then newGroups[specKey] = {} end
                        local groupCopy = DF:DeepCopy(group)
                        -- Filter members to only those that exist in this spec
                        if groupCopy.members then
                            local filtered = {}
                            for _, member in ipairs(groupCopy.members) do
                                local specs = auraToSpecs[member.auraName]
                                if specs and specs[specKey] then
                                    tinsert(filtered, member)
                                end
                            end
                            groupCopy.members = filtered
                        end
                        tinsert(newGroups[specKey], groupCopy)
                    end
                end
                adDB.layoutGroups = newGroups
            end
        end
        -- Migrate nextLayoutGroupID to per-spec too (just keep global as fallback)
        adDB._specScopedV2 = true
    end
end

-- Expose for Engine.lua and post-import use
DF.MigrateAuraDesignerSpecScope = MigrateToSpecScoped

-- ============================================================
-- STAGE 5.1b — ICON BORDER KEY MIGRATION
-- Renames the legacy per-aura icon border keys to the canonical
-- CreateBorderControls naming (matches every other unified-border
-- consumer in the addon):
--   borderEnabled   → ShowBorder
--   borderThickness → BorderSize
--   borderInset     → BorderInset  (case-only rename)
--
-- Walks every aura × every storage shape (typeKey-keyed sub-config
-- and the newer indicators[] array) for every spec.  Idempotent —
-- only renames when the new key is nil, so a partially-migrated
-- config is safe.
--
-- Scope: icon (Stage 5.1) + square (Stage 5.2).  Bar (Stage 5.3) still
-- reuses some of the same legacy key names (borderThickness, borderInset),
-- so we stay type-scoped — only rename an instance's keys once that
-- indicator type has migrated to the unified backend.  The icon and square
-- differ only in the enable key: icon used `borderEnabled`, square used
-- `showBorder`; both fold to canonical `ShowBorder`.
-- ============================================================

-- Backfill canonical ONLY when absent, but ALWAYS strip the legacy key — even
-- when the canonical key already exists.  A block edited in the new GUI writes
-- canonical keys but leaves the legacy ones behind; the old "swap-and-nil only
-- if canonical == nil" form then skipped the strip, leaving the legacy key to
-- linger forever (the half-migrated state).  Mirrors renameBorderTypeKeys.
local function renameIconBorderKeys(t)
    if type(t) ~= "table" then return end
    if t.borderEnabled ~= nil then
        if t.ShowBorder == nil then t.ShowBorder = t.borderEnabled end
        t.borderEnabled = nil
    end
    if t.borderThickness ~= nil then
        if t.BorderSize == nil then t.BorderSize = t.borderThickness end
        t.borderThickness = nil
    end
    if t.borderInset ~= nil then
        if t.BorderInset == nil then t.BorderInset = t.borderInset end
        t.borderInset = nil
    end
end

-- Square (Stage 5.2): border-key renames ONLY.  The square's enable key is
-- `showBorder` (vs the icon's `borderEnabled`).  Deliberately does NOT touch
-- `expiringPulsate` — on the square that's the FILL pulse, a different effect
-- from the icon's border DF_PULSATE, so it stays a boolean.
local function renameSquareBorderKeys(t)
    if type(t) ~= "table" then return end
    -- Always strip legacy (see renameIconBorderKeys); backfill canonical if absent.
    if t.showBorder ~= nil then
        if t.ShowBorder == nil then t.ShowBorder = t.showBorder end
        t.showBorder = nil
    end
    if t.borderThickness ~= nil then
        if t.BorderSize == nil then t.BorderSize = t.borderThickness end
        t.borderThickness = nil
    end
    if t.borderInset ~= nil then
        if t.BorderInset == nil then t.BorderInset = t.borderInset end
        t.borderInset = nil
    end
end

-- Bar (Stage 5.3): border-key renames.  Enable key is `showBorder` (like the
-- square); the bar also carries a static `borderColor` table → canonical
-- `BorderColor`.  The bar has no legacy inset key.
local function renameBarBorderKeys(t)
    if type(t) ~= "table" then return end
    -- Always strip legacy (see renameIconBorderKeys); backfill canonical if absent.
    if t.showBorder ~= nil then
        if t.ShowBorder == nil then t.ShowBorder = t.showBorder end
        t.showBorder = nil
    end
    if t.borderThickness ~= nil then
        if t.BorderSize == nil then t.BorderSize = t.borderThickness end
        t.borderThickness = nil
    end
    if t.borderColor ~= nil then
        if t.BorderColor == nil then t.BorderColor = t.borderColor end
        t.borderColor = nil
    end
end

-- Border-type indicator (Stage 5.4): its legacy `style` enum maps onto a
-- DF.Border style + animation combo.  One-way, lossy (the 5 styles become
-- canonical Style/Animation combinations).  Gated on `style` being present so
-- it runs once.
local function renameBorderTypeKeys(t)
    if type(t) ~= "table" then return end
    -- The legacy `style` key is what forces the old render path (Indicators.lua's
    -- `config.style and BuildBorderTypeSpec(...)`), so its presence is what we key
    -- on.  Crucially we run EVEN WHEN BorderStyle already exists: a block edited in
    -- the new GUI writes canonical keys but leaves `style` behind, so it must still
    -- get stripped or it keeps rendering via the legacy builder (the half-migrated
    -- bug — legacy color/thickness shadowing the GUI's BorderColor/BorderSize).
    if t.style == nil then return end
    local thickness = t.thickness or 2
    local inset     = t.inset or 0
    local color     = t.color or { r = 0, g = 0, b = 0, a = 1 }
    local legacy    = { Solid = "SOLID", Glow = "GLOW", Pulse = "SOLID" }
    local style     = legacy[t.style] or t.style or "SOLID"
    -- Fold legacy → canonical ONLY where the canonical key is absent, so we never
    -- overwrite edits the user already made in the new GUI (BorderColor/BorderSize).
    if t.ShowBorder  == nil then t.ShowBorder  = true  end
    if t.BorderInset == nil then t.BorderInset = inset end
    if t.BorderColor == nil then t.BorderColor = color end
    if t.BorderStyle == nil then
        if style == "GLOW" then
            t.BorderStyle = "TEXTURE"
            if t.BorderTexture == nil then t.BorderTexture = "DF Glow" end
            if t.BorderSize    == nil then t.BorderSize    = thickness end
        elseif style == "DASHED" or style == "ANIMATED" then
            -- The legacy dashed/animated styles drew a size-0 border made visible
            -- ONLY by a container border animation, which 12.1 retired (aura buttons
            -- go forbidden while auras are secret). Fold them to a visible static
            -- border so an upgraded config renders something rather than nothing.
            t.BorderStyle = "SOLID"
            if t.BorderSize == nil then t.BorderSize = thickness end
        elseif style == "CORNERS" then
            t.BorderStyle = "SOLID"
            if t.BorderSize == nil then t.BorderSize = 0 end
            if t.BorderAnimationType == nil then
                t.BorderAnimationType      = "CORNERS_ONLY"
                t.BorderAnimationThickness = thickness
                t.BorderAnimationColor     = color
            end
        else  -- SOLID (and anything unknown)
            t.BorderStyle = "SOLID"
            if t.BorderSize == nil then t.BorderSize = thickness end
        end
    elseif t.BorderSize == nil then
        -- BorderStyle already set (by the GUI); just backfill size from legacy.
        t.BorderSize = thickness
    end
    -- Strip legacy keys so rendering routes through DF.Border:BuildSpec.
    t.style = nil; t.thickness = nil; t.inset = nil; t.color = nil
end

local function MigrateIconBorderKeysOnAuras(specAuras)
    if type(specAuras) ~= "table" then return end
    for _, auraCfg in pairs(specAuras) do
        if type(auraCfg) == "table" then
            -- Old shape: auraCfg.<type> sub-config.
            if auraCfg.icon then renameIconBorderKeys(auraCfg.icon) end
            if auraCfg.square then renameSquareBorderKeys(auraCfg.square) end
            if auraCfg.bar then renameBarBorderKeys(auraCfg.bar) end
            if auraCfg.border then renameBorderTypeKeys(auraCfg.border) end
            -- New shape: auraCfg.indicators[i] — each instance carries its
            -- own border keys when the user has overridden defaults.
            if auraCfg.indicators then
                for _, ind in ipairs(auraCfg.indicators) do
                    if ind.type == "icon" then
                        renameIconBorderKeys(ind)
                    elseif ind.type == "square" then
                        renameSquareBorderKeys(ind)
                    elseif ind.type == "bar" then
                        renameBarBorderKeys(ind)
                    elseif ind.type == "border" then
                        renameBorderTypeKeys(ind)
                    end
                end
            end
        end
    end
end

-- Run the icon/square/bar/border key renames over one `.auras` table, handling
-- both the flat ({ auraName → auraCfg }) and spec-scoped
-- ({ specKey → { auraName → auraCfg } }) shapes.  Mirrors
-- MigrateAuraDesignerToInstances' shape detection so we stay correct whether the
-- spec-scope migration ran before us or not.
local function MigrateBorderKeysOnAurasTable(auras)
    if type(auras) ~= "table" then return end
    for _, val in pairs(auras) do
        if type(val) == "table" then
            if val.priority ~= nil or val.indicators ~= nil or val.icon ~= nil then
                MigrateIconBorderKeysOnAuras(auras)             -- flat
            else
                for _, specAuras in pairs(auras) do             -- spec-scoped
                    MigrateIconBorderKeysOnAuras(specAuras)
                end
            end
        end
        break  -- Only check first entry for shape detection
    end
end

local function MigrateAuraDesignerIconBorderKeys(modeDb)
    local adDB = modeDb and modeDb.auraDesigner
    if adDB and adDB.auras then
        MigrateBorderKeysOnAurasTable(adDB.auras)
    end
end

-- The Designer Presets rework relocated AD aura configs into
-- profile.auraDesignerPresets[name].auras.  MigrateAuraDesignerIconBorderKeys
-- only walks the legacy per-mode modeDb.auraDesigner location, so preset-nested
-- border blocks were never folded — they kept their legacy `style` (rendering via
-- the old builder) while the GUI wrote canonical keys onto them (the half-migrated
-- state).  Walk every preset's auras so those blocks get folded + `style` stripped.
local function MigrateAuraDesignerPresetBorderKeys(profile)
    local presets = profile and profile.auraDesignerPresets
    if type(presets) ~= "table" then return end
    for _, preset in pairs(presets) do
        if type(preset) == "table" then
            MigrateBorderKeysOnAurasTable(preset.auras)
        end
    end
end

DF.MigrateAuraDesignerIconBorderKeys   = MigrateAuraDesignerIconBorderKeys
DF.MigrateAuraDesignerPresetBorderKeys = MigrateAuraDesignerPresetBorderKeys

-- Lazy, flag-gated border-key fold.  This is the one that actually matters for
-- live frames: the ADDON_LOADED passes above clean the STORED tables (modeDb
-- auraDesigner + presets), but render resolves its config through
-- DF:ResolveAuraDesigner / GetModeBaseAuraDesigner, which can hand back a
-- resolved / auto-layout-overlay table the load-time passes never touched.
-- Mirroring MigrateToSpecScoped's lazy-on-access pattern, we fold the border keys
-- on the EXACT adDB about to be rendered/edited, gated by `_borderKeysFoldedV1`
-- so it runs once per table.  (Idempotent if the table is rebuilt each access.)
local function MigrateBorderKeysLazy(adDB)
    if type(adDB) ~= "table" or adDB._borderKeysFoldedV1 then return end
    if adDB.auras then MigrateBorderKeysOnAurasTable(adDB.auras) end
    adDB._borderKeysFoldedV1 = true
end
DF.MigrateAuraDesignerBorderKeysLazy = MigrateBorderKeysLazy

-- Same lazy-on-access pattern for the type-keyed → instances[] migration.  It
-- only ran at ADDON_LOADED on modeDb.auraDesigner, so an imported preset still in
-- the legacy type-keyed shape (icon/square/bar sub-tables, no `indicators`) would
-- render NOTHING — the engine reads `auraCfg.indicators`.  Reuses the existing,
-- idempotent DF.MigrateAuraDesignerToInstances (guarded per-aura by `not
-- auraCfg.indicators`) via a thin modeDb wrapper, so there's no duplicated
-- conversion logic.  The resolved adDB IS the preset by reference, so folding it
-- also cleans the stored data.  Runs before the border fold to match load order.
local function MigrateInstancesLazy(adDB)
    if type(adDB) ~= "table" or adDB._instancesFoldedV1 then return end
    if DF.MigrateAuraDesignerToInstances and adDB.auras then
        DF.MigrateAuraDesignerToInstances({ auraDesigner = adDB })
    end
    adDB._instancesFoldedV1 = true
end
DF.MigrateAuraDesignerInstancesLazy = MigrateInstancesLazy

-- Lazy, flag-gated Priority-scale flip (old lower-wins → new higher-wins). Same
-- resolve-time, once-per-table pattern as the border-key fold above: it runs on
-- the EXACT adDB about to be rendered/edited, so auto-layout overlays, presets,
-- and the legacy inline config are all covered AT POINT OF USE, gated by
-- `_priorityHigherWinsV1`. Fresh configs are born flagged (NewAuraDesignerConfig)
-- and exports/imports carry the flag on the copied table, so only genuine pre-4.6
-- data is ever flipped — and exactly once. Replaces the old one-shot ADDON_LOADED
-- walker, which misclassified flat auras with no indicators and double-flipped
-- newly-created / imported profiles into corruption.
local function FlipAuraPriority(auraCfg)
    if type(auraCfg) == "table" and type(auraCfg.priority) == "number" then
        local p = math.floor(auraCfg.priority + 0.5)
        if p < 1 then p = 1 elseif p > 10 then p = 10 end
        auraCfg.priority = 11 - p
    end
end
local function MigratePrioritiesLazy(adDB)
    if type(adDB) ~= "table" or adDB._priorityHigherWinsV1 then return end
    local auras = adDB.auras
    if type(auras) == "table" then
        -- Shape detection off the first entry only, matching MigrateBorderKeysOnAurasTable.
        for _, val in pairs(auras) do
            if type(val) == "table" then
                if val.priority ~= nil or val.indicators ~= nil or val.icon ~= nil then
                    for _, auraCfg in pairs(auras) do FlipAuraPriority(auraCfg) end            -- flat: auras[name]
                else
                    for _, specAuras in pairs(auras) do                                         -- spec: auras[spec][name]
                        if type(specAuras) == "table" then
                            for _, auraCfg in pairs(specAuras) do FlipAuraPriority(auraCfg) end
                        end
                    end
                end
            end
            break
        end
    end
    adDB._priorityHigherWinsV1 = true
end
DF.MigrateAuraDesignerPrioritiesLazy = MigratePrioritiesLazy

-- Per-indicator Frame Level became an ABSOLUTE offset from the unit frame (the render used
-- to add 40 to whatever was stored). Shifts every stored value by that same 40 so no
-- indicator moves. Runs on the RESOLVED adDB -- presets, auto-layout overlays and the legacy
-- inline config are all covered at point of use -- mirroring MigratePrioritiesLazy.
local function ShiftIndicatorLevels(auraCfg)
    if type(auraCfg) ~= "table" then return end
    local inds = auraCfg.indicators
    if type(inds) ~= "table" then return end
    for _, ind in pairs(inds) do
        if type(ind) == "table" and tonumber(ind.frameLevel) then
            ind.frameLevel = tonumber(ind.frameLevel) + 40
        end
    end
end
local function MigrateAbsoluteLevelsLazy(adDB)
    if type(adDB) ~= "table" or adDB._absoluteFrameLevelV1 then return end
    local auras = adDB.auras
    if type(auras) == "table" then
        -- Shape detection off the first entry only, matching MigratePrioritiesLazy.
        for _, val in pairs(auras) do
            if type(val) == "table" then
                if val.priority ~= nil or val.indicators ~= nil or val.icon ~= nil then
                    for _, auraCfg in pairs(auras) do ShiftIndicatorLevels(auraCfg) end
                else
                    for _, specAuras in pairs(auras) do
                        if type(specAuras) == "table" then
                            for _, auraCfg in pairs(specAuras) do ShiftIndicatorLevels(auraCfg) end
                        end
                    end
                end
            end
            break
        end
    end
    adDB._absoluteFrameLevelV1 = true
end

-- V2 — undo the two places V1 got AD's level wrong. Read this before touching either.
--
-- AD's real level has always been 40 (the buff-icon band). Commit 47075137 then added
-- `indicatorFrameLevel = 30` as a Config default while the render still computed
-- `40 + stored`, so 30 was written into a field that meant a NUDGE — it reads like the
-- status-icon convention (30) copied into the wrong units. Effect: 40 + 30 = 70.
--
-- V1 above then made levels absolute and added the base back, so a spurious nudge of 30
-- became a stored 70. Correct logic, bad input: it preserved the mistake permanently, and
-- 70 sits ABOVE the defensive icon (65) — which is meant to be the top layer.
--
-- V1 also only walked auraCfg.indicators. It never shifted adDB.defaults.indicatorFrameLevel,
-- so that key was left holding the pre-absolute 30 while every per-indicator value moved to
-- the absolute scale. The two numbers have been in different units ever since, which is why
-- the Default Frame Level slider reads 30 on a profile whose indicators all render at 70.
--
-- So V2 restores the baseline:
--   defaults.indicatorFrameLevel == 30  -> 40
--   per-indicator frameLevel     == 70  -> 40
--
-- ⚠ Both rewrites are value-targeted, not blanket. 30 and 70 are the exact fingerprints of
-- the bad seed. A deliberate absolute 30 is not a thing anyone would choose (it puts AD
-- UNDER the buff/debuff rows at 40), and 70 is only reachable from the seeded nudge. The
-- accepted cost: someone who genuinely nudged +30 for a reason loses it and lands at the
-- baseline. That is judged the right trade while 12.1 is unshipped and the alpha population
-- is small — an untouched profile drawing AD over the defensive icon is the worse default.
-- Any OTHER stored level is left exactly as it is; those are real user choices.
local function ResetSeededIndicatorLevels(auraCfg)
    if type(auraCfg) ~= "table" then return end
    local inds = auraCfg.indicators
    if type(inds) ~= "table" then return end
    for _, ind in pairs(inds) do
        if type(ind) == "table" and tonumber(ind.frameLevel) == 70 then
            ind.frameLevel = 40
        end
    end
end
local function MigrateAbsoluteLevelsV2Lazy(adDB)
    if type(adDB) ~= "table" or adDB._absoluteFrameLevelV2 then return end

    local defs = adDB.defaults
    if type(defs) == "table" and tonumber(defs.indicatorFrameLevel) == 30 then
        defs.indicatorFrameLevel = 40
    end

    local auras = adDB.auras
    if type(auras) == "table" then
        -- Same shape detection as V1 (flat auraCfg vs spec-scoped), for the same reason.
        for _, val in pairs(auras) do
            if type(val) == "table" then
                if val.priority ~= nil or val.indicators ~= nil or val.icon ~= nil then
                    for _, auraCfg in pairs(auras) do ResetSeededIndicatorLevels(auraCfg) end
                else
                    for _, specAuras in pairs(auras) do
                        if type(specAuras) == "table" then
                            for _, auraCfg in pairs(specAuras) do ResetSeededIndicatorLevels(auraCfg) end
                        end
                    end
                end
            end
            break
        end
    end

    adDB._absoluteFrameLevelV2 = true
end

DF.MigrateAuraDesignerAbsoluteLevelsLazy = MigrateAbsoluteLevelsLazy
DF.MigrateAuraDesignerAbsoluteLevelsV2Lazy = MigrateAbsoluteLevelsV2Lazy

-- ☠ STRAND: a per-indicator frameStrata of BACKGROUND buries the indicator where NO frame
-- level can reach it, and there is no longer any control that can clear it.
--
-- The per-indicator Frame Strata picker was removed from the editor (only the GLOBAL
-- default survives, and it ships "INHERIT"). The stored values were never migrated, and
-- resolveStrata still honours them — so a profile carrying a legacy "BACKGROUND" pins that
-- indicator below every MEDIUM frame on the unit button, health bar included. Strata
-- outranks level absolutely, which is why raising Frame Level to 100 changed nothing.
--
-- Field-proven by a /df debug zorder dump (2026-08-19): on one frame, three indicators read
-- strata=BACKGROUND at levels 51/67/106 while their siblings on MEDIUM at level 46 rendered
-- correctly. The user's reported symptom was exactly "bar indicators are below the health
-- bar … I can't seem to get it to change even though the square indicators do rest on top" —
-- the squares happened to be the MEDIUM ones.
--
-- The baseline is: nobody carries a per-indicator strata, everything inherits the unit
-- frame's, and FRAME LEVEL makes every ordering decision. That is what the levels being
-- absolute (V1/V2 above) was for; the strata half was simply never done.
--
-- ☠☠ VALUE-TARGETED: ONLY the burying strata. A blanket clear is WRONG here, and the first
-- cut of this migration got it wrong — resolveStrata documents that a stored literal
-- "INHERIT" is an explicit CHOICE that STOPS the fallback chain, while a genuinely unset key
-- falls through to the global default. Nil-ing an "INHERIT" therefore does not preserve
-- behaviour: it re-opens that indicator to a global default it was deliberately opted out of.
-- The real profile that produced this report carries 18 "INHERIT" and 10 "MEDIUM" values;
-- a blanket clear would have silently rewired all 28 to fix the zero BACKGROUND ones.
-- MEDIUM and HIGH are equally left alone: they order against the frame's band, not beneath it.
-- ⚠ Clears the legacy per-type sub-tables too (icon/square/bar), which pre-date the
-- instances migration and are the shape old profiles still carry — see the AD storage map.
local BURYING_STRATA = { BACKGROUND = true, LOW = true }

local function ClearIndicatorStrata(auraCfg, counter)
    if type(auraCfg) ~= "table" then return end
    local inds = auraCfg.indicators
    if type(inds) == "table" then
        for _, ind in pairs(inds) do
            if type(ind) == "table" and BURYING_STRATA[ind.frameStrata] then
                ind.frameStrata = nil
                counter.n = counter.n + 1
            end
        end
    end
    for _, k in ipairs({ "icon", "square", "bar" }) do
        local t = auraCfg[k]
        if type(t) == "table" and BURYING_STRATA[t.frameStrata] then
            t.frameStrata = nil
            counter.n = counter.n + 1
        end
    end
end

local function MigrateIndicatorStrataLazy(adDB)
    if type(adDB) ~= "table" or adDB._indicatorStrataV1 then return end
    local counter = { n = 0 }

    -- auras: SPEC-KEYED since MigrateToSpecScoped, but a pre-migration flat shape can still
    -- arrive here (this runs on the resolved db, and the spec migration is lazy too). Same
    -- first-entry shape detection MigrateAbsoluteLevelsLazy uses, for the same reason.
    local auras = adDB.auras
    if type(auras) == "table" then
        for _, val in pairs(auras) do
            if type(val) == "table" then
                if val.priority ~= nil or val.indicators ~= nil or val.icon ~= nil then
                    for _, auraCfg in pairs(auras) do ClearIndicatorStrata(auraCfg, counter) end
                else
                    for _, specAuras in pairs(auras) do
                        if type(specAuras) == "table" then
                            for _, auraCfg in pairs(specAuras) do ClearIndicatorStrata(auraCfg, counter) end
                        end
                    end
                end
            end
            break
        end
    end
    -- ☠ otherAuras TOO. The levels migration above walks only adDB.auras, so an Other Buffs
    -- record kept its pre-absolute level — do not inherit that gap here. Flat, same shape.
    if type(adDB.otherAuras) == "table" then
        for _, auraCfg in pairs(adDB.otherAuras) do ClearIndicatorStrata(auraCfg, counter) end
    end

    -- The global default is the same trap one level up: a stored BACKGROUND there buries
    -- every indicator that has no per-instance value. INHERIT is the shipped baseline.
    local defs = adDB.defaults
    if type(defs) == "table" then
        if BURYING_STRATA[defs.indicatorFrameStrata] then
            defs.indicatorFrameStrata = "INHERIT"
            counter.n = counter.n + 1
        end
    end

    if counter.n > 0 and DF.Debug then
        DF:Debug("AD", "indicator strata: cleared %d stranded value(s) onto the frame's own strata", counter.n)
    end
    adDB._indicatorStrataV1 = true
end

DF.MigrateAuraDesignerIndicatorStrataLazy = MigrateIndicatorStrataLazy


-- Lazy, flag-gated ONE-TIME refresh of the AD global text defaults to the Midnight
-- baseline: DF Roboto SemiBold + drop shadow, 1.2 duration scale, stack count seated
-- bottom-right (2,-2). Pre-12.1 the AD shipped Friz Quadrata / plain OUTLINE / 1.0 /
-- centred stacks — WoW-generic values nobody picks deliberately (same reasoning as the
-- settings-panel font flip, Core.lua's _settingsFontRobotoDefaultV1). Runs on the
-- RESOLVED adDB (presets, auto-layout overlays, and the legacy inline config all
-- covered at point of use), flipping ONLY where the value is still the EXACT old
-- default — so any explicit choice sticks, and placed indicators that already store
-- their own values are untouched.
-- durationColorByTime is DELIBERATELY not flipped: existing profiles keep their
-- duration colours (a stored OFF is as likely a choice as a leftover). New / reset
-- profiles pick up the new ON default via the Config factory, newly PLACED
-- indicators always stamp ON (EnsureTypeConfig, v4 parity), and the Factory render
-- resolves nil-instance indicators through adDB.defaults (resolveDefCBT) so the
-- stored value actually governs.
-- MUST be wired into BOTH this editor accessor AND the Factory render runner
-- (Factory.lua ~2270), or the editor shows the new values while live frames render the
-- old ones until a manual re-entry forces a rebuild.
local function MigrateDefaultRefreshLazy(adDB)
    if type(adDB) ~= "table" or adDB._adDefaultRefreshV1 then return end
    local d = adDB.defaults
    if type(d) == "table" then
        if d.durationFont == "Friz Quadrata TT" then d.durationFont = "DF Roboto SemiBold" end
        if d.stackFont    == "Friz Quadrata TT" then d.stackFont    = "DF Roboto SemiBold" end
        if d.durationOutline == "OUTLINE" then d.durationOutline = "SHADOW;OUTLINE" end
        if d.stackOutline    == "OUTLINE" then d.stackOutline    = "SHADOW;OUTLINE" end
        if d.durationScale == 1 then d.durationScale = 1.2 end          -- 1.0 == 1 in Lua
        if d.stackX == 0 then d.stackX = 2 end
        if d.stackY == 0 then d.stackY = -2 end
    end
    adDB._adDefaultRefreshV1 = true
end

-- ============================================================
-- ORPHAN AURA KEYS (repair)
-- ============================================================
-- The picker's add-by-ID stored the SpellDB's spell NAME (`rec.n`, e.g.
-- "Ebon Might") for any id the curated tables didn't list -- including ids that
-- belong to a curated spell but were never recorded as alternates. On the My
-- Buffs pool that key names nothing: curated keys are internal ("EbonMight"),
-- so the editor's effect list -- which drops every record it cannot name --
-- skipped it, while the factory happily resolved it through the SpellDB and
-- rendered it. Result: an indicator on the frame with no card, no delete button
-- and no escape short of a new profile. Reported live on 5.0.0.
--
-- The creation path is fixed (add-by-ID now snaps through the shared identity
-- index), so this only has to repair what is already saved: rekey the orphan
-- onto the curated entry that owns its spell, merging if that entry is also
-- configured. Layout-group members carry (auraName, indicatorID) pairs, so they
-- are rewritten with the same remap -- missing that would strip a repaired
-- indicator out of its group.
--
-- Deliberately additive: nothing is deleted. A merge appends the orphan's
-- indicators rather than guessing which duplicate the user meant to keep --
-- both become visible, and the user removes the one they don't want.
--
-- ☠ Runs on the RESOLVED adDB, so it MUST be wired into BOTH GetAuraDesignerDB
-- (the editor's resolver) and the Factory render runner -- see the file header.
-- ☠ Must run AFTER MigrateToSpecScoped: it assumes adDB.auras is spec-keyed.

-- Fold `src` into `dst`, returning { [oldIndicatorID] = newIndicatorID }.
local function MergeAuraConfig(dst, src)
    local remap = {}
    if type(src.indicators) == "table" then
        if type(dst.indicators) ~= "table" then dst.indicators = {} end
        -- Derive the next id from the ids actually present, not from the stored
        -- counter alone: a stale counter would collide and two indicators
        -- sharing an id break every (auraName, indicatorID) lookup.
        local nextID = dst.nextIndicatorID or 1
        for _, inst in ipairs(dst.indicators) do
            if type(inst.id) == "number" and inst.id >= nextID then nextID = inst.id + 1 end
        end
        for _, inst in ipairs(src.indicators) do
            local oldID = inst.id
            inst.id = nextID
            if oldID ~= nil then remap[oldID] = nextID end
            nextID = nextID + 1
            tinsert(dst.indicators, inst)
        end
        dst.nextIndicatorID = nextID
    end
    -- Everything else (frame-level effect tables, priority, border, sound) fills
    -- GAPS only -- the entry the user can already see and edit keeps its own
    -- settings.
    for k, v in pairs(src) do
        if k ~= "indicators" and k ~= "nextIndicatorID" and dst[k] == nil then
            dst[k] = v
        end
    end
    return remap
end

local function MigrateOrphanAuraKeysLazy(adDB)
    if type(adDB) ~= "table" or adDB._adOrphanAuraKeysV1 then return end
    local auras = adDB.auras
    if type(auras) ~= "table" then
        adDB._adOrphanAuraKeysV1 = true
        return
    end
    local R = DF.FilterRegistry
    if not (R and R.GetSpellByName and Adapter and Adapter.GetSpecIdentity) then
        -- The registry loads after this file; if it somehow isn't up yet, leave
        -- the flag UNSET so the next run repairs rather than stamping a no-op.
        return
    end

    local repaired = 0
    for spec, pool in pairs(auras) do
        local ident = type(pool) == "table" and Adapter:GetSpecIdentity(spec)
        if ident then
            -- Collect first: rekeying inserts new keys, which `pairs` forbids
            -- mid-traversal.
            local moves
            for key, cfg in pairs(pool) do
                if type(key) == "string" and type(cfg) == "table"
                    and not ident.byName[key]                 -- not a curated key
                    and not key:find("^#") and not key:find("^@") then  -- not ad-hoc / filter ref
                    local rec = R:GetSpellByName(key)
                    if rec then
                        local owner = ident.byID[rec.id]
                        if not owner and rec.alts then
                            for _, altID in ipairs(rec.alts) do
                                owner = ident.byID[altID]
                                if owner then break end
                            end
                        end
                        if owner and owner ~= key then
                            moves = moves or {}
                            moves[#moves + 1] = { from = key, to = owner }
                        end
                    end
                end
            end

            for _, mv in ipairs(moves or {}) do
                local src = pool[mv.from]
                local remap
                if pool[mv.to] then
                    remap = MergeAuraConfig(pool[mv.to], src)
                else
                    pool[mv.to] = src
                end
                pool[mv.from] = nil
                repaired = repaired + 1

                -- Follow the rename into this spec's layout groups.
                local groups = adDB.layoutGroups and adDB.layoutGroups[spec]
                if type(groups) == "table" then
                    for _, group in pairs(groups) do
                        if type(group) == "table" and type(group.members) == "table" then
                            for _, m in ipairs(group.members) do
                                if m.auraName == mv.from then
                                    m.auraName = mv.to
                                    if remap and remap[m.indicatorID] then
                                        m.indicatorID = remap[m.indicatorID]
                                    end
                                end
                            end
                        end
                    end
                end

                if DF.DebugWarn then
                    DF:DebugWarn("AD", "orphan aura key repaired: %s[%q] -> %q",
                        tostring(spec), mv.from, mv.to)
                end
            end
        end
    end

    if repaired > 0 and DF.Debug then
        DF:Debug("AD", "orphan aura keys: %d config(s) rekeyed onto their curated spell", repaired)
    end
    adDB._adOrphanAuraKeysV1 = true
end
DF.MigrateAuraDesignerDefaultRefreshLazy = MigrateDefaultRefreshLazy
DF.MigrateAuraDesignerOrphanAuraKeysLazy = MigrateOrphanAuraKeysLazy