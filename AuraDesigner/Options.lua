local addonName, DF = ...

-- ============================================================
-- AURA DESIGNER - OPTIONS GUI
-- Custom page layout: left content area + fixed 280px right panel
-- Called from Options/Options.lua via DF.BuildAuraDesignerPage()
-- ============================================================

local pairs, ipairs, type = pairs, ipairs, type
local format = string.format
local wipe = wipe
local tinsert = table.insert
local tremove = table.remove
local max, min, floor = math.max, math.min, math.floor
local strsplit = strsplit
local sort = table.sort
local RAID_CLASS_COLORS = RAID_CLASS_COLORS
local LOCALIZED_CLASS_NAMES_MALE = LOCALIZED_CLASS_NAMES_MALE
local L = DF.L

-- Local references set during BuildAuraDesignerPage
local GUI
local page
local db
local Adapter

-- State
local selectedSpec = nil         -- Current spec key being viewed

-- Reusable color constants: reference the shared GUI palette (same numeric
-- values, zero visual change) so they track any future palette change in
-- lockstep. GUI.lua loads before this file (see .toc), so DF.GUI.Colors is
-- populated at parse time.
local C_BACKGROUND = DF.GUI.Colors.background
-- (C_PANEL removed — unreferenced; reclaimed for the 200-locals ceiling.)
local C_ELEMENT    = DF.GUI.Colors.element
local C_BORDER     = DF.GUI.Colors.border
local C_HOVER      = DF.GUI.Colors.hover
local C_TEXT       = DF.GUI.Colors.text
local C_TEXT_DIM   = DF.GUI.Colors.textDim

-- Indicator type definitions
-- These option/label tables read L["..."]; at file scope that returns the enUS
-- baseline (the languageOverride overlay runs later, at ADDON_LOADED). Build
-- them in a registered refresh fn so Core rebuilds them after the overlay —
-- otherwise these dropdowns stay English. Value-keys (CENTER, RIGHT, …) and
-- the _order arrays are raw identifiers and must NOT be localized.
-- One namespace table instead of one local per option table (the main chunk
-- rides the Lua 5.1 200-locals ceiling; seven locals reclaimed to one).
local OPTS = {}

local function RefreshLocaleStrings()
    OPTS.INDICATOR_TYPES = {
        { key = "icon",       label = L["Icon"],             placed = true  },
        { key = "square",     label = L["Square"],           placed = true  },
        { key = "bar",        label = L["Bar"],              placed = true  },
        { key = "border",     label = L["Border"],           placed = false },
        { key = "healthbar",  label = L["Health Bar Color"], placed = false },
        { key = "background", label = L["Background Color"],  placed = false },
        { key = "nametext",   label = L["Name Text Color"],  placed = false },
        { key = "healthtext", label = L["Health Text Color"], placed = false },
        { key = "framealpha", label = L["Frame Alpha"],      placed = false },
        { key = "sound",      label = L["Sound Alert"],      placed = false },
    }

    OPTS.ANCHOR_OPTIONS = {
        CENTER = L["Center"], TOP = L["Top"], BOTTOM = L["Bottom"], LEFT = L["Left"], RIGHT = L["Right"],
        TOPLEFT = L["Top Left"], TOPRIGHT = L["Top Right"], BOTTOMLEFT = L["Bottom Left"], BOTTOMRIGHT = L["Bottom Right"],
        _order = {"TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT"},
    }

    OPTS.GROWTH_OPTIONS = {
        RIGHT = L["Right"], LEFT = L["Left"], UP = L["Up"], DOWN = L["Down"],
        _order = {"RIGHT", "LEFT", "UP", "DOWN"},
    }

    OPTS.FRAME_STRATA_OPTIONS = {
        INHERIT = L["Inherit (Frame)"], BACKGROUND = L["Background"], LOW = L["Low"], MEDIUM = L["Medium"], HIGH = L["High"],
        _order = {"INHERIT", "BACKGROUND", "LOW", "MEDIUM", "HIGH"},
    }

    OPTS.BORDER_STYLE_OPTIONS = {
        SOLID = L["Solid Border"], ANIMATED = L["Animated Border"], DASHED = L["Dashed Border"],
        GLOW = L["Glow"], CORNERS = L["Corners Only"],
        _order = {"SOLID", "ANIMATED", "DASHED", "GLOW", "CORNERS"},
    }

    OPTS.HEALTHBAR_MODE_OPTIONS = {
        Replace = L["Replace"], Tint = L["Tint"],
        _order = {"Replace", "Tint"},
    }

    OPTS.BAR_ORIENT_OPTIONS = {
        HORIZONTAL = L["Horizontal"], VERTICAL = L["Vertical"],
        _order = {"HORIZONTAL", "VERTICAL"},
    }
end

RefreshLocaleStrings()
DF:RegisterLocaleRefresh(RefreshLocaleStrings)

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
                if type(val) == "table" and (val.priority ~= nil or val.indicators ~= nil) then
                    isFlat = true
                    break
                end
            end
            if isFlat then
                local oldAuras = adDB.auras
                local newAuras = {}
                local auraToSpecs = {}
                local trackable = DF.AuraDesigner and DF.AuraDesigner.TrackableAuras
                if trackable then
                    for specKey, auraList in pairs(trackable) do
                        for _, info in ipairs(auraList) do
                            if not auraToSpecs[info.name] then auraToSpecs[info.name] = {} end
                            tinsert(auraToSpecs[info.name], specKey)
                        end
                    end
                end
                for auraName, auraCfg in pairs(oldAuras) do
                    local specs = auraToSpecs[auraName]
                    if specs then
                        for _, specKey in ipairs(specs) do
                            if not newAuras[specKey] then newAuras[specKey] = {} end
                            newAuras[specKey][auraName] = DF:DeepCopy(auraCfg)
                        end
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
    -- Stage 5.1d.2: legacy expiringPulsate (boolean) → ExpiringAnimationType
    -- (string).  expiringPulsate = true means the user wanted the AD legacy
    -- alpha-fade pulse during expiring; that effect is now first-class as
    -- DF_PULSATE.  False just clears the boolean — the new key defaults to
    -- "NONE" which means no expiring animation override.
    if t.expiringPulsate ~= nil then
        if t.ExpiringAnimationType == nil and t.expiringPulsate == true then
            t.ExpiringAnimationType = "DF_PULSATE"
        end
        t.expiringPulsate = nil
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
            t.BorderStyle = "SOLID"
            if t.BorderSize == nil then t.BorderSize = 0 end
            if t.BorderAnimationType == nil then
                t.BorderAnimationType      = "DF_DASH"
                t.BorderAnimationFrequency = (style == "ANIMATED") and 1 or 0
                t.BorderAnimationThickness = thickness
                t.BorderAnimationColor     = color
                t.BorderAnimationInset     = inset
            end
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

local function GetAuraDesignerDB()
    -- The editor is mode-tabbed: it edits the preset the active mode uses
    -- (party → its assigned preset, etc.). Because edited == used, live
    -- frames stay in sync with the editor automatically.
    -- Base variant: the editor edits your base raid preset, not the active runtime
    -- auto-layout's overlay (it edits the layout only while IN edit-auto-layout).
    local adDB
    if DF.GetModeBaseAuraDesigner then
        local mode = (GUI and GUI.SelectedMode) or "party"
        adDB = DF:GetModeBaseAuraDesigner(mode)
    end
    -- Pre-migration / very-early fallback to the legacy inline config.
    adDB = adDB or (db and db.auraDesigner)
    if adDB and (not adDB._specScopedV1 or not adDB._specScopedV2) then
        MigrateToSpecScoped(adDB)
    end
    MigrateInstancesLazy(adDB)
    MigrateBorderKeysLazy(adDB)
    MigratePrioritiesLazy(adDB)
    return adDB
end

local function GetThemeColor()
    return GUI.GetThemeColor()
end

-- Shared backdrop info reused by every ApplyBackdrop call to avoid
-- per-card table allocation when the AD effects list rebuilds.
local SHARED_BACKDROP_INFO = {
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
}

local function ApplyBackdrop(frame, bgColor, borderColor)
    if not frame.SetBackdrop then Mixin(frame, BackdropTemplateMixin) end

    -- Only call SetBackdrop once per frame — the info table never changes.
    if not frame.dfAD_backdropApplied then
        frame:SetBackdrop(SHARED_BACKDROP_INFO)
        frame.dfAD_backdropApplied = true
    end

    if bgColor then
        local r, g, b = bgColor.r, bgColor.g, bgColor.b
        local a = bgColor.a or 1
        if frame.dfAD_bgR ~= r or frame.dfAD_bgG ~= g or frame.dfAD_bgB ~= b or frame.dfAD_bgA ~= a then
            frame:SetBackdropColor(r, g, b, a)
            frame.dfAD_bgR, frame.dfAD_bgG, frame.dfAD_bgB, frame.dfAD_bgA = r, g, b, a
        end
    end

    if borderColor then
        local r, g, b = borderColor.r, borderColor.g, borderColor.b
        local a = borderColor.a or 1
        if frame.dfAD_borderR ~= r or frame.dfAD_borderG ~= g or frame.dfAD_borderB ~= b or frame.dfAD_borderA ~= a then
            frame:SetBackdropBorderColor(r, g, b, a)
            frame.dfAD_borderR, frame.dfAD_borderG, frame.dfAD_borderB, frame.dfAD_borderA = r, g, b, a
        end
    end
end

-- ============================================================
-- BUFF COEXISTENCE POPUP
-- Shown once when the user enables Aura Designer, asking whether
-- to keep standard buff icons or let AD fully replace them.
-- ============================================================

local buffCoexistPopup

local function ShowBuffCoexistPopup(onConfirm, onCancel)
    if not buffCoexistPopup then
        local f = CreateFrame("Frame", "DFADBuffPopup", UIParent, "BackdropTemplate")
        f:SetSize(420, 130)
        f:SetPoint("CENTER")
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetFrameLevel(250)
        f:EnableMouse(true)
        local tc = GetThemeColor()
        ApplyBackdrop(f, {r = 0.10, g = 0.10, b = 0.10, a = 0.98}, {r = tc.r, g = tc.g, b = tc.b, a = 1})

        -- Thin accent stripe along the top
        local stripe = f:CreateTexture(nil, "OVERLAY")
        stripe:SetColorTexture(tc.r, tc.g, tc.b, 0.8)
        stripe:SetHeight(2)
        stripe:SetPoint("TOPLEFT", 1, -1)
        stripe:SetPoint("TOPRIGHT", -1, -1)
        f._stripe = stripe

        local title = f:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        title:SetPoint("TOP", 0, -12)
        title:SetText(L["Aura Designer"])
        title:SetTextColor(tc.r, tc.g, tc.b)

        local desc = f:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        desc:SetPoint("TOP", title, "BOTTOM", 0, -6)
        desc:SetWidth(390)
        desc:SetText(L["Would you like to keep standard buff icons alongside\nAura Designer, or let it fully replace them?"])
        desc:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        desc:SetJustifyH("CENTER")

        local function MakeButton(parent, text, xOff)
            local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
            btn:SetPoint("BOTTOM", parent, "BOTTOM", xOff, 14)
            DF.GUI:StyleButton(btn, { width = 170, height = 28, text = text })
            btn.text = btn.Text
            return btn
        end

        f.keepBtn = MakeButton(f, L["Keep Buffs"], -95)
        f.replaceBtn = MakeButton(f, L["Replace Buffs"], 95)

        -- Close on Escape
        f:SetScript("OnKeyDown", function(self, key)
            if key == "ESCAPE" then
                self:SetPropagateKeyboardInput(false)
                self:Hide()
                if self._onCancel then self._onCancel() end
            else
                self:SetPropagateKeyboardInput(true)
            end
        end)

        buffCoexistPopup = f
    end

    local f = buffCoexistPopup
    f._onCancel = onCancel

    f.keepBtn:SetScript("OnClick", function()
        f:Hide()
        if onConfirm then onConfirm(true) end
    end)
    f.replaceBtn:SetScript("OnClick", function()
        f:Hide()
        if onConfirm then onConfirm(false) end
    end)

    f:Show()
end

-- Get or resolve the active spec key from settings
local function ResolveSpec()
    local adDB = GetAuraDesignerDB()
    if adDB.spec == "auto" then
        return Adapter:GetPlayerSpec()
    end
    return adDB.spec
end

-- Track which spec aura tables have already been sanitized this session
local sanitizedSpecAuras = {}

-- Returns the spec-scoped auras sub-table, creating it if needed
-- Also sanitizes corrupted entries (non-table values like stray nextIndicatorID)
local function GetSpecAuras(spec)
    local adDB = GetAuraDesignerDB()
    if not adDB then return {} end
    if not adDB.auras then adDB.auras = {} end
    spec = spec or ResolveSpec()
    if not spec then return {} end
    if not adDB.auras[spec] then adDB.auras[spec] = {} end
    local specAuras = adDB.auras[spec]
    -- One-time cleanup: remove non-table entries that ended up at the wrong level
    if not sanitizedSpecAuras[specAuras] then
        local toRemove
        for k, v in pairs(specAuras) do
            if type(v) ~= "table" then
                if not toRemove then toRemove = {} end
                toRemove[#toRemove + 1] = k
            end
        end
        if toRemove then
            for _, k in ipairs(toRemove) do
                specAuras[k] = nil
            end
            DF:DebugWarn("AD", "Cleaned %d corrupted entries from spec auras table", #toRemove)
        end
        sanitizedSpecAuras[specAuras] = true
    end
    return specAuras
end

-- Returns the spec-INDEPENDENT "Other Buffs" pool (B1): a flat map auraName -> auraCfg
-- with the EXACT record shape of adDB.auras[spec] entries (indicators array, frame-level
-- sub-tables, sound, priority, nextIndicatorID), created + sanitized like GetSpecAuras.
-- Deliberately a SIBLING key of adDB.auras (never a pseudo-spec inside it) so every
-- adDB.auras consumer stays spec-scoped; a future per-spec expansion of this pool would
-- land under its own sibling key, so this flat map never needs a migration. Aura names
-- here must be SpellDB names (rec.n / localized) or ad-hoc "#<id>" keys — identity
-- resolves spec-independently via DF:BuildADIdentityFilters(nil, name).
-- (B2 wires the Other Buffs tab/editor to this accessor; the factory reads
-- adDB.otherAuras directly, mirroring how it reads adDB.auras[spec].)
local function GetOtherAuras()
    local adDB = GetAuraDesignerDB()
    if not adDB then return {} end
    if not adDB.otherAuras then adDB.otherAuras = {} end
    local otherAuras = adDB.otherAuras
    -- One-time cleanup, same as GetSpecAuras (registry is keyed by table identity, so
    -- profile/preset switches re-sanitize the new table naturally).
    if not sanitizedSpecAuras[otherAuras] then
        local toRemove
        for k, v in pairs(otherAuras) do
            if type(v) ~= "table" then
                if not toRemove then toRemove = {} end
                toRemove[#toRemove + 1] = k
            end
        end
        if toRemove then
            for _, k in ipairs(toRemove) do
                otherAuras[k] = nil
            end
            DF:DebugWarn("AD", "Cleaned %d corrupted entries from other auras table", #toRemove)
        end
        sanitizedSpecAuras[otherAuras] = true
    end
    return otherAuras
end

-- Returns the preset's DEBUFF CATEGORY GROUPS array (C1): a flat, spec-INDEPENDENT
-- array of group records (mirror of the otherAuras siblings-not-pseudo-spec rule —
-- a future per-spec expansion would land under its own key, so this array never
-- needs a migration). Lazily created on first WRITE access only — merely opening
-- the editor must not create adDB.debuffGroups (mirror GetOtherAuras). Each record:
-- { id, name, enabled, anchor, offsetX, offsetY, growDirection, iconsPerRow,
--   spacing, iconSize, maxIcons, selection = { boss, role, priority, crowdControl,
--   raid, dispellable, dispellableMode, hideLong, hideLongMinutes, keepImportant } }.
-- The factory reads adDB.debuffGroups directly (as it reads otherAuras); the
-- C2 group editor reaches it via CreateDebuffGroup / DebuffGroupsRead.
local function GetDebuffGroups()
    local adDB = GetAuraDesignerDB()
    if not adDB then return {} end
    if not adDB.debuffGroups then adDB.debuffGroups = {} end
    local groups = adDB.debuffGroups
    -- One-time cleanup, same table-identity registry as GetSpecAuras/GetOtherAuras
    -- (profile/preset switches swap the table and re-sanitize naturally).
    if not sanitizedSpecAuras[groups] then
        for i = #groups, 1, -1 do
            if type(groups[i]) ~= "table" then
                tremove(groups, i)
                DF:DebugWarn("AD", "Removed corrupted debuff group entry at index %d", i)
            end
        end
        sanitizedSpecAuras[groups] = true
    end
    return groups
end

-- Create a new debuff category group (C1 data model; C2 wires the UI). Defaults:
-- Boss + Role selected (the classic "important debuffs" baseline), everything
-- else off, Hide Long staged at 5 minutes with Keep Important on. Layout mirrors
-- the filter-group creation defaults (compact 4x4).
local function CreateDebuffGroup(name)
    local adDB = GetAuraDesignerDB()
    if not adDB then return nil end
    local groups = GetDebuffGroups()
    if not adDB.nextDebuffGroupID then adDB.nextDebuffGroupID = 1 end
    local id = adDB.nextDebuffGroupID
    adDB.nextDebuffGroupID = id + 1
    local group = {
        id = id,
        name = name or ("Debuff Group " .. id),
        anchor = "TOPLEFT",
        offsetX = 0,
        offsetY = 0,
        growDirection = "RIGHT_DOWN",
        iconsPerRow = 4,
        spacing = 2,
        iconSize = 24,
        maxIcons = 4,
        selection = {
            boss = true, role = true, priority = false, crowdControl = false,
            raid = false, dispellable = false, dispellableMode = "PLAYER",
            hideLong = false, hideLongMinutes = 5, keepImportant = true,
        },
    }
    tinsert(groups, group)
    return group
end

-- Returns the spec-scoped layout groups array, creating it if needed
local function GetSpecLayoutGroups(spec)
    local adDB = GetAuraDesignerDB()
    if not adDB then return {} end
    if not adDB.layoutGroups then adDB.layoutGroups = {} end
    spec = spec or ResolveSpec()
    if not spec then return {} end
    if not adDB.layoutGroups[spec] then adDB.layoutGroups[spec] = {} end
    return adDB.layoutGroups[spec]
end

-- ============================================================
-- MAIN POOL TABS (B2) — My Buffs / Other Buffs
-- The tab strip above the workspace decides which aura pool the ENTIRE
-- editor operates on: "my" = the spec-scoped adDB.auras[spec] pool,
-- "other" = the spec-INDEPENDENT adDB.otherAuras pool (B1). Every editor
-- read routes through CurrentAuraPool(); spec-only surfaces (layout
-- groups, migrations, the spec dropdown itself) deliberately do not.
-- ============================================================

local activeBuffTab = "my"   -- "my" | "debuffs" | "other"

local function IsOtherTab()
    return activeBuffTab == "other"
end

-- C2: the Debuffs tab hosts debuff CATEGORY groups (spec-independent, no
-- spell pool, no placed indicators). Its Effects sub-tab frosts, the spec
-- dropdown greys, and CurrentAuraPool reads empty.
local function IsDebuffTab()
    return activeBuffTab == "debuffs"
end

-- Read-only placeholder returned while the other pool doesn't exist yet.
-- Merely VISITING the Other Buffs tab must not create adDB.otherAuras —
-- only the first ADD does (via CurrentAuraPoolWrite). Never written.
local EMPTY_POOL = {}

-- READ access to the active tab's pool. Never creates adDB.otherAuras.
-- `spec` is forwarded to GetSpecAuras on the My Buffs tab only.
local function CurrentAuraPool(spec)
    if activeBuffTab == "other" then
        local adDB = GetAuraDesignerDB()
        if adDB and adDB.otherAuras then return GetOtherAuras() end
        return EMPTY_POOL
    end
    -- The Debuffs tab has no aura pool: no placed indicators and no
    -- frame-level effects, so every pool-routed surface (preview passes,
    -- effect list) reads empty. Category groups live in adDB.debuffGroups.
    if activeBuffTab == "debuffs" then return EMPTY_POOL end
    return GetSpecAuras(spec)
end

-- WRITE access: creates the pool table (the other pool is born lazily on
-- the first add — drag-drop, picker click, or add-by-ID).
local function CurrentAuraPoolWrite()
    if activeBuffTab == "other" then return GetOtherAuras() end
    return GetSpecAuras()
end

-- B1 key-prefix contract: wherever an editor key embeds an aura's name,
-- the other-pool record embeds "other:" .. auraName in the name segment
-- (expandedCards "placed:other:<name>#<id>" / "frame:<type>:other:<name>",
-- preview slot keys). The auraName itself never carries the prefix.
local function PoolKeyPrefix()
    return (activeBuffTab == "other") and "other:" or ""
end

-- READ access to the debuff category groups array (C2). Never creates
-- adDB.debuffGroups — merely visiting the Debuffs tab must not write
-- (the EMPTY_POOL rule above); the first "+ Debuff Group" add creates it
-- via CreateDebuffGroup → GetDebuffGroups.
local function DebuffGroupsRead()
    local adDB = GetAuraDesignerDB()
    if adDB and adDB.debuffGroups then return GetDebuffGroups() end
    return EMPTY_POOL
end

-- Other Buffs LAYOUT GROUPS: a flat, spec-INDEPENDENT array of group records
-- over the other pool (sibling of otherAuras/debuffGroups — never a pseudo-spec
-- inside adDB.layoutGroups, so no migration can ever touch it). Records are
-- shape-identical to the spec-keyed layoutGroups entries (member kind with
-- {auraName, indicatorID} members referencing OTHER-pool placed indicators,
-- and filter kind with filterSelection). Own id counter
-- (adDB.nextOtherLayoutGroupID — ids can collide with the spec counter's, so
-- every derived key carries a pool marker). One accessor for both access
-- modes (the file-scope 200-locals ceiling forbids the two-function
-- GetDebuffGroups/DebuffGroupsRead split): `create` follows the lazy-write
-- rule — read access returns EMPTY_POOL while the store doesn't exist
-- (visiting the tab must never create it; the first "+ Create/Filter Group"
-- add passes create=true).
local function GetOtherLayoutGroups(create)
    local adDB = GetAuraDesignerDB()
    if not adDB then return EMPTY_POOL end
    if not adDB.otherLayoutGroups then
        if not create then return EMPTY_POOL end
        adDB.otherLayoutGroups = {}
    end
    local groups = adDB.otherLayoutGroups
    -- One-time cleanup, same table-identity registry as GetDebuffGroups.
    if not sanitizedSpecAuras[groups] then
        for i = #groups, 1, -1 do
            if type(groups[i]) ~= "table" then
                tremove(groups, i)
                DF:DebugWarn("AD", "Removed corrupted other layout group entry at index %d", i)
            end
        end
        sanitizedSpecAuras[groups] = true
    end
    return groups
end

-- Active tab's layout groups (READ — never creates the other store): the
-- flat other store on Other Buffs, the spec-keyed array on My Buffs.
-- (Debuffs never reaches these — its Layout Groups tab builds debuff
-- category groups instead.)
local function CurrentLayoutGroups()
    if activeBuffTab == "other" then return GetOtherLayoutGroups(false) end
    return GetSpecLayoutGroups()
end

-- Display name for an OTHER-pool aura key: ad-hoc "#<id>" resolves live,
-- SpellDB names resolve through GetSpellDisplay (localized), else the raw key.
local function OtherPoolDisplayName(auraName)
    local id = type(auraName) == "string" and auraName:match("^#(%d+)$")
    if id then
        local live = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(tonumber(id))
        return live or auraName
    end
    local R = DF.FilterRegistry
    local rec = R and R.GetSpellByName and R:GetSpellByName(auraName)
    if rec then
        local display = R:GetSpellDisplay(rec)
        if display then return display end
    end
    return auraName
end

-- Union of every spell ID tracked by one pool of an adDB (cross-tab
-- used-affordance). which = "my" walks ALL spec pools (the preset object is
-- one: a spell tracked for ANY spec would double-render for that spec when
-- also in the shared other pool); "other" walks the flat other pool with
-- nil-spec identity. Pure (no editor state) — exposed for the SDD harness.
local function PoolTrackedIDs(adDB, which)
    local out = {}
    if type(adDB) ~= "table" then return out end
    local function addIDs(spec, auraName)
        local f = DF:BuildADIdentityFilters(spec, auraName)
        local map = f and f.includeSpellIDs
        if map then
            for id in pairs(map) do out[id] = true end
        end
    end
    if which == "my" then
        if type(adDB.auras) == "table" then
            for specKey, specAuras in pairs(adDB.auras) do
                if type(specAuras) == "table" then
                    for auraName, cfg in pairs(specAuras) do
                        if type(cfg) == "table" then addIDs(specKey, auraName) end
                    end
                end
            end
        end
    else -- "other"
        if type(adDB.otherAuras) == "table" then
            for auraName, cfg in pairs(adDB.otherAuras) do
                if type(cfg) == "table" then addIDs(nil, auraName) end
            end
        end
    end
    return out
end
DF.ADEditor_PoolTrackedIDs = PoolTrackedIDs

-- IDs tracked by the OPPOSITE pool of the active tab (drives the picker's
-- cross-tab blocked rows and the add-by-ID gate).
local function CrossPoolTrackedIDs()
    return PoolTrackedIDs(GetAuraDesignerDB(), IsOtherTab() and "my" or "other")
end

-- Class-token grouping order for the Other Buffs picker (mirrors the
-- Filter Designer picker's CLASS_ORDER).
local AD_CLASS_ORDER = {
    "DEATHKNIGHT", "DEMONHUNTER", "DRUID", "EVOKER", "HUNTER", "MAGE",
    "MONK", "PALADIN", "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR",
}

-- Ensure an aura config table exists, creating it with defaults if needed.
-- `pool` (optional) pins the target pool — proxies capture their pool at
-- creation so a stale color-picker callback can't write across tabs.
local function EnsureAuraConfig(auraName, pool)
    local auras = pool or CurrentAuraPoolWrite()
    if not auras[auraName] then
        auras[auraName] = {
            priority = 5,
        }
    end
    return auras[auraName]
end

-- Ensure a type sub-table exists within an aura config
local function EnsureTypeConfig(auraName, typeKey, pool)
    local auraCfg = EnsureAuraConfig(auraName, pool)
    if not auraCfg[typeKey] then
        -- Read global defaults so new configs inherit user-configured values
        local adDB = GetAuraDesignerDB()
        local gd = adDB and adDB.defaults or {}

        -- Create default config for each type
        if typeKey == "icon" then
            auraCfg[typeKey] = {
                -- Placement
                anchor = "TOPLEFT", offsetX = 0, offsetY = 0,
                -- Size & appearance (from global defaults)
                size = gd.iconSize or 24, scale = gd.iconScale or 1.0, alpha = 1.0,
                -- Border
                -- Canonical border keys (Stage 5.1b/c). Legacy names were
                -- borderEnabled / borderThickness / borderInset; migrated
                -- via DF:MigrateAuraDesignerIconBorderKeys on ADDON_LOADED.
                -- ShowBorder/BorderSize/BorderInset are stored on the
                -- aura's icon sub-config; everything else (style, colour,
                -- gradient, shadow, offset, blend) reads from TYPE_DEFAULTS
                -- via proxy fall-through until the user overrides it.
                -- Seed Show/Size from the global icon-border defaults so the
                -- "Import Buffs Tab Defaults" border toggle actually carries over.
                ShowBorder = (gd.iconBorderEnabled ~= false), BorderSize = gd.iconBorderThickness or 1, BorderInset = 0,
                hideSwipe = false,
                -- Duration text
                showDuration = gd.showDuration ~= false,
                durationFont = gd.durationFont or "Fonts\\FRIZQT__.TTF",
                durationScale = gd.durationScale or 1.0,
                durationOutline = gd.durationOutline or "OUTLINE",
                durationAnchor = "CENTER", durationX = 0, durationY = 0,
                durationColorByTime = true,
                -- Stack count
                showStacks = gd.showStacks ~= false, stackMinimum = 2,
                stackFont = gd.stackFont or "Fonts\\FRIZQT__.TTF",
                stackScale = gd.stackScale or 1.0,
                stackOutline = gd.stackOutline or "OUTLINE",
                stackAnchor = "BOTTOMRIGHT",
                stackX = 0, stackY = 0,
                -- Expiring
                expiringEnabled = false, expiringThreshold = 30, expiringThresholdMode = "PERCENT",
                expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
                expiringWholeAlphaPulse = false, expiringBounce = false,
            }
        elseif typeKey == "square" then
            auraCfg[typeKey] = {
                -- Placement
                anchor = "TOPLEFT", offsetX = 0, offsetY = 0,
                -- Appearance (from global defaults)
                size = gd.iconSize or 24, scale = gd.iconScale or 1.0, alpha = 1.0,
                color = {r = 1, g = 1, b = 1, a = 1},
                -- Border (canonical keys, Stage 5.2; legacy migrated on load)
                ShowBorder = true, BorderSize = 1, BorderInset = 0,
                hideSwipe = false,
                -- Duration text
                showDuration = gd.showDuration ~= false,
                durationFont = gd.durationFont or "Fonts\\FRIZQT__.TTF",
                durationScale = gd.durationScale or 1.0,
                durationOutline = gd.durationOutline or "OUTLINE",
                durationAnchor = "CENTER", durationX = 0, durationY = 0,
                durationColorByTime = true,
                -- Stack count
                showStacks = gd.showStacks ~= false, stackMinimum = 2,
                stackFont = gd.stackFont or "Fonts\\FRIZQT__.TTF",
                stackScale = gd.stackScale or 1.0,
                stackOutline = gd.stackOutline or "OUTLINE",
                stackAnchor = "BOTTOMRIGHT",
                stackX = 0, stackY = 0,
                -- Expiring
                expiringEnabled = false, expiringThreshold = 30, expiringThresholdMode = "PERCENT",
                expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
                expiringWholeAlphaPulse = false, expiringBounce = false,
            }
        elseif typeKey == "bar" then
            auraCfg[typeKey] = {
                -- Placement
                anchor = "BOTTOM", offsetX = 0, offsetY = 0,
                -- Size & orientation
                orientation = "HORIZONTAL", width = 60, height = 6,
                matchFrameWidth = true, matchFrameHeight = false,
                -- Texture & colors
                texture = "Interface\\TargetingFrame\\UI-StatusBar",
                fillColor = {r = 1, g = 1, b = 1, a = 1},
                bgColor = {r = 0, g = 0, b = 0, a = 0.5},
                -- Border (canonical keys, Stage 5.3; legacy migrated on load)
                ShowBorder = true, BorderSize = 1, BorderInset = 0,
                BorderColor = {r = 0, g = 0, b = 0, a = 1},
                -- Alpha
                alpha = 1.0,
                -- Bar color by time
                barColorByTime = false,
                -- Expiring color
                expiringEnabled = false, expiringThreshold = 30, expiringThresholdMode = "PERCENT",
                expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
                -- Duration text
                showDuration = true,
                durationFont = gd.durationFont or "Fonts\\FRIZQT__.TTF",
                durationScale = gd.durationScale or 1.0,
                durationOutline = gd.durationOutline or "OUTLINE",
                durationAnchor = "CENTER", durationX = 0, durationY = 0,
                durationColorByTime = true,
            }
        elseif typeKey == "border" then
            auraCfg[typeKey] = {
                -- Border (canonical keys, Stage 5.4; legacy style/thickness/
                -- inset/color migrated on load)
                ShowBorder = true, BorderStyle = "SOLID", BorderSize = 2, BorderInset = 0,
                BorderColor = {r = 1, g = 1, b = 1, a = 1},
                drawAboveFrameBorder = true,
                expiringEnabled = false, expiringThreshold = 30, expiringThresholdMode = "PERCENT",
                expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
                expiringPulsate = false,
                showWhenMissing = false,
            }
        elseif typeKey == "healthbar" then
            auraCfg[typeKey] = {
                mode = "Replace", color = {r = 1, g = 1, b = 1, a = 1}, blend = 0.5,
                tintWholeBar = false,
                expiringEnabled = false, expiringThreshold = 30, expiringThresholdMode = "PERCENT",
                expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
                expiringPulsate = false,
                showWhenMissing = false,
            }
        elseif typeKey == "background" then
            auraCfg[typeKey] = {
                mode = "Tint", color = {r = 1, g = 1, b = 1, a = 1}, blend = 0.5,
                expiringEnabled = false, expiringThreshold = 30, expiringThresholdMode = "PERCENT",
                expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
                expiringPulsate = false,
                showWhenMissing = false,
            }
        elseif typeKey == "nametext" then
            auraCfg[typeKey] = {
                color = {r = 1, g = 1, b = 1, a = 1},
                expiringEnabled = false, expiringThreshold = 30, expiringThresholdMode = "PERCENT",
                expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
                showWhenMissing = false,
            }
        elseif typeKey == "healthtext" then
            auraCfg[typeKey] = {
                color = {r = 1, g = 1, b = 1, a = 1},
                expiringEnabled = false, expiringThreshold = 30, expiringThresholdMode = "PERCENT",
                expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
                showWhenMissing = false,
            }
        elseif typeKey == "framealpha" then
            auraCfg[typeKey] = {
                alpha = 0.5,
                expiringEnabled = false, expiringThreshold = 30, expiringThresholdMode = "PERCENT",
                expiringAlpha = 1.0,
                showWhenMissing = false,
            }
        elseif typeKey == "sound" then
            auraCfg[typeKey] = {
                enabled = false,
                soundFile = nil,
                soundLSMKey = nil,
                volume = 0.8,
                missingEnabled = true,
                triggerMode = "ANY_MISSING",
                combatMode = "ALWAYS",
                startDelay = 2,
                loopInterval = 3,
                expireEnabled = false,
                expireThreshold = 5,
                expireThresholdMode = "SECONDS",
                expirePlayOnce = false,
                expireLoopInterval = 3,
            }
        end
    end
    return auraCfg[typeKey]
end

-- Default values per type key, used as fallback when a saved config is missing new keys
local TYPE_DEFAULTS = {
    icon = {
        anchor = "TOPLEFT", offsetX = 0, offsetY = 0,
        size = 24, scale = 1.0, alpha = 1.0,
        -- Canonical border keys (Stage 5.1b/c).  Legacy borderEnabled /
        -- borderThickness / borderInset migrated on ADDON_LOADED via
        -- DF:MigrateAuraDesignerIconBorderKeys.  BorderColor defaults to
        -- the pre-migration hardcoded translucent black so existing users
        -- see no visual change.  Style / Gradient* / Shadow* defaults seed
        -- CreateBorderControls' dropdowns and pickers so they read sensible
        -- values on first open.
        ShowBorder = true, BorderSize = 1, BorderInset = 0,
        BorderColor             = {r = 0, g = 0, b = 0, a = 0.8},
        BorderStyle             = "SOLID",
        BorderBlendMode         = "BLEND",
        BorderOffsetX           = 0,
        BorderOffsetY           = 0,
        BorderGradientStartColor = {r = 0,    g = 0,    b = 0,    a = 1},
        BorderGradientEndColor   = {r = 0.5,  g = 0.5,  b = 0.5,  a = 1},
        BorderGradientDirection  = "HORIZONTAL",
        BorderShadowEnabled      = false,
        BorderShadowColor        = {r = 0, g = 0, b = 0, a = 0.8},
        BorderShadowSize         = 1,
        BorderShadowOffsetX      = 1,
        BorderShadowOffsetY      = -1,
        -- Animation defaults match Frame Border's Stage 3 defaults so the
        -- behaviour of "pick PULSATE" reads the same across the addon.
        -- BorderAnimationType = "NONE" means no continuous animation; the
        -- spec.animation block is omitted by BuildSpec so Apply doesn't
        -- start anything.  Picking a non-NONE type surfaces the relevant
        -- tunables (helper handles hide/show per effect).
        BorderAnimationType         = "NONE",
        BorderAnimationColor        = {r = 0.95, g = 0.95, b = 0.32, a = 1},
        -- 1 Hz default ≈ 1-second cycle, matching the legacy AD Pulsate
        -- Border pulse rate.  Frame Border / Defensive Icon use 0.25 which
        -- reads as a slow gentle pulse at full-frame scale; at icon scale
        -- (24px) the same rate looks like a static dim border because the
        -- transitions are too gradual to perceive.
        BorderAnimationFrequency    = 1,
        BorderAnimationParticles    = 8,
        BorderAnimationLength       = 8,
        BorderAnimationThickness    = 3,
        BorderAnimationScale        = 1,
        BorderAnimationInset        = 0,
        BorderAnimationOffsetX      = 0,
        BorderAnimationOffsetY      = 0,
        BorderAnimationMask         = false,
        BorderAnimationSidesAxis    = "HORIZONTAL",
        BorderAnimationCornerLength = 10,
        hideSwipe = false, hideIcon = false,
        showDuration = true, durationFont = "Friz Quadrata TT",
        durationScale = 1.0, durationOutline = "OUTLINE",
        durationAnchor = "CENTER", durationX = 0, durationY = 0,
        durationColorByTime = true,
        durationColor = {r = 1, g = 1, b = 1, a = 1},
        durationHideAboveEnabled = false, durationHideAboveThreshold = 10,
        showStacks = true, stackMinimum = 2,
        stackFont = "Friz Quadrata TT", stackScale = 1.0,
        stackOutline = "OUTLINE", stackAnchor = "BOTTOMRIGHT",
        stackX = 0, stackY = 0,
        stackColor = {r = 1, g = 1, b = 1, a = 1},
        expiringEnabled = false, expiringThreshold = 30, expiringThresholdMode = "PERCENT",
        expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
        -- Expiring Tint overlay (secret-safe).  Default OFF, red — also feeds the
        -- colour picker's Default button via the proxy's __dfDefaults = TYPE_DEFAULTS.
        expiringTintEnabled = false,
        expiringTintColor = {r = 1, g = 0.2, b = 0.2, a = 0.5},  -- #FF3333 @ 50% (matches expiring border red)
        expiringPulsate = false,  -- legacy; migrated to ExpiringAnimationType
        -- Master enable for the whole Expiring feature.  Default true so
        -- existing configs are unaffected; turning it OFF disables every
        -- expiring override (colour / thickness / alpha / animation / pulse /
        -- bounce) regardless of their individual settings, and hides the rest
        -- of the Expiring panel.
        expiringFeatureEnabled = true,
        -- Stage 5.1d.2 + parity: full Border Animation effect set as the value
        -- the expiring callback swaps into spec.animation when remaining <
        -- threshold.  NONE = no animation override.  The expiring animation
        -- carries its OWN complete tunable set (colour, particles, thickness,
        -- offset, …) independent of the base Border Animation — mirrors the
        -- base defaults so the two panels read identically.
        ExpiringAnimationType         = "NONE",
        ExpiringAnimationColor        = {r = 0.95, g = 0.95, b = 0.32, a = 1},
        ExpiringAnimationFrequency    = 1,
        ExpiringAnimationParticles    = 8,
        ExpiringAnimationLength       = 8,
        ExpiringAnimationThickness    = 3,
        ExpiringAnimationScale        = 1,
        ExpiringAnimationInset        = 0,
        ExpiringAnimationOffsetX      = 0,
        ExpiringAnimationOffsetY      = 0,
        ExpiringAnimationMask         = false,
        ExpiringAnimationSidesAxis    = "HORIZONTAL",
        ExpiringAnimationCornerLength = 10,
        -- Stage 5.1d.3: per-state thickness + alpha overrides.  Default to
        -- 1 / 1 — same thickness as the base (1) and slightly more opaque
        -- than the base alpha (0.8), so out of the box a user enabling
        -- Expiring Color Override sees the border tick to fully opaque red
        -- below threshold (subtle "more solid" feel).  Move the sliders
        -- higher / lower for stronger emphasis.  Only take effect when the
        -- expiring ticker is running (i.e. user has at least one expiring
        -- feature on — colour override, animation, alpha pulse, or bounce).
        ExpiringBorderSize  = 1,
        ExpiringBorderAlpha = 1,
        expiringWholeAlphaPulse = false, expiringBounce = false,
        frameLevel = 30, frameStrata = "INHERIT",
        showWhenMissing = false, missingDesaturate = false,
    },
    square = {
        anchor = "TOPLEFT", offsetX = 0, offsetY = 0,
        size = 24, scale = 1.0, alpha = 1.0,
        color = {r = 1, g = 1, b = 1, a = 1},
        -- Canonical border keys (Stage 5.2).  Legacy showBorder /
        -- borderThickness / borderInset migrated on ADDON_LOADED.  BorderColor
        -- defaults to opaque black, matching the square's pre-migration
        -- hardcoded border so existing users see no change.  The rest seed
        -- CreateBorderControls' dropdowns / pickers on first open.
        ShowBorder = true, BorderSize = 1, BorderInset = 0,
        BorderColor             = {r = 0, g = 0, b = 0, a = 1},
        BorderStyle             = "SOLID",
        BorderBlendMode         = "BLEND",
        BorderOffsetX           = 0,
        BorderOffsetY           = 0,
        BorderGradientStartColor = {r = 0,    g = 0,    b = 0,    a = 1},
        BorderGradientEndColor   = {r = 0.5,  g = 0.5,  b = 0.5,  a = 1},
        BorderGradientDirection  = "HORIZONTAL",
        BorderShadowEnabled      = false,
        BorderShadowColor        = {r = 0, g = 0, b = 0, a = 0.8},
        BorderShadowSize         = 1,
        BorderShadowOffsetX      = 1,
        BorderShadowOffsetY      = -1,
        BorderAnimationType         = "NONE",
        BorderAnimationColor        = {r = 0.95, g = 0.95, b = 0.32, a = 1},
        BorderAnimationFrequency    = 1,
        BorderAnimationParticles    = 8,
        BorderAnimationLength       = 8,
        BorderAnimationThickness    = 3,
        BorderAnimationScale        = 1,
        BorderAnimationInset        = 0,
        BorderAnimationOffsetX      = 0,
        BorderAnimationOffsetY      = 0,
        BorderAnimationMask         = false,
        BorderAnimationSidesAxis    = "HORIZONTAL",
        BorderAnimationCornerLength = 10,
        hideSwipe = false, hideIcon = false,
        showDuration = true, durationFont = "Friz Quadrata TT",
        durationScale = 1.0, durationOutline = "OUTLINE",
        durationAnchor = "CENTER", durationX = 0, durationY = 0,
        durationColorByTime = true,
        durationColor = {r = 1, g = 1, b = 1, a = 1},
        durationHideAboveEnabled = false, durationHideAboveThreshold = 10,
        showStacks = true, stackMinimum = 2,
        stackFont = "Friz Quadrata TT", stackScale = 1.0,
        stackOutline = "OUTLINE", stackAnchor = "BOTTOMRIGHT",
        stackX = 0, stackY = 0,
        stackColor = {r = 1, g = 1, b = 1, a = 1},
        -- Master enable for the whole Expiring feature (Stage 5.2 — mirrors
        -- the icon).  Default true so existing configs are unaffected.
        expiringFeatureEnabled = true,
        expiringEnabled = false, expiringThreshold = 30, expiringThresholdMode = "PERCENT",
        expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
        expiringTintEnabled = false,
        expiringTintColor = {r = 1, g = 0.2, b = 0.2, a = 0.5},  -- #FF3333 @ 50% (matches expiring border red)
        expiringPulsate = false,
        -- Stage 5.2 expiring-border overrides (shared backend with the icon).
        -- ExpiringBorderColor is SEPARATE from the fill's expiringColor — the
        -- fill and border each get their own expiring tint.  Defaults to the
        -- same red so out of the box both "turn red", but they're independent.
        ExpiringBorderColor = {r = 1, g = 0.2, b = 0.2, a = 1},
        ExpiringBorderSize  = 1,
        ExpiringBorderAlpha = 1,
        ExpiringAnimationType         = "NONE",
        ExpiringAnimationColor        = {r = 0.95, g = 0.95, b = 0.32, a = 1},
        ExpiringAnimationFrequency    = 1,
        ExpiringAnimationParticles    = 8,
        ExpiringAnimationLength       = 8,
        ExpiringAnimationThickness    = 3,
        ExpiringAnimationScale        = 1,
        ExpiringAnimationInset        = 0,
        ExpiringAnimationOffsetX      = 0,
        ExpiringAnimationOffsetY      = 0,
        ExpiringAnimationMask         = false,
        ExpiringAnimationSidesAxis    = "HORIZONTAL",
        ExpiringAnimationCornerLength = 10,
        expiringWholeAlphaPulse = false, expiringBounce = false,
        frameLevel = 30, frameStrata = "INHERIT",
        showWhenMissing = false,
    },
    bar = {
        anchor = "BOTTOM", offsetX = 0, offsetY = 0,
        orientation = "HORIZONTAL", width = 60, height = 6,
        matchFrameWidth = true, matchFrameHeight = false,
        texture = "Interface\\TargetingFrame\\UI-StatusBar",
        fillColor = {r = 1, g = 1, b = 1, a = 1},
        bgColor = {r = 0, g = 0, b = 0, a = 0.5},
        -- Canonical border keys (Stage 5.3).  Legacy showBorder /
        -- borderThickness / borderColor migrated on ADDON_LOADED.  BorderInset
        -- defaults to 0 so the ring sits FLUSH outside the bar as before.
        -- BorderColor defaults to opaque black (the bar's pre-migration look).
        ShowBorder = true, BorderSize = 1, BorderInset = 0,
        BorderColor             = {r = 0, g = 0, b = 0, a = 1},
        BorderStyle             = "SOLID",
        BorderBlendMode         = "BLEND",
        BorderGradientStartColor = {r = 0,    g = 0,    b = 0,    a = 1},
        BorderGradientEndColor   = {r = 0.5,  g = 0.5,  b = 0.5,  a = 1},
        BorderGradientDirection  = "HORIZONTAL",
        BorderShadowEnabled      = false,
        BorderShadowColor        = {r = 0, g = 0, b = 0, a = 0.8},
        BorderShadowSize         = 1,
        BorderShadowOffsetX      = 1,
        BorderShadowOffsetY      = -1,
        BorderAnimationType         = "NONE",
        BorderAnimationColor        = {r = 0.95, g = 0.95, b = 0.32, a = 1},
        BorderAnimationFrequency    = 1,
        BorderAnimationParticles    = 8,
        BorderAnimationLength       = 8,
        BorderAnimationThickness    = 3,
        BorderAnimationScale        = 1,
        BorderAnimationInset        = 0,
        BorderAnimationOffsetX      = 0,
        BorderAnimationOffsetY      = 0,
        BorderAnimationMask         = false,
        BorderAnimationSidesAxis    = "HORIZONTAL",
        BorderAnimationCornerLength = 10,
        alpha = 1.0,
        barColorByTime = false,
        expiringEnabled = false, expiringThreshold = 5,
        expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
        expiringTintEnabled = false,
        expiringTintColor = {r = 1, g = 0.2, b = 0.2, a = 0.5},  -- #FF3333 @ 50% (matches expiring border red)
        showDuration = true, durationFont = "Friz Quadrata TT",
        durationScale = 1.0, durationOutline = "OUTLINE",
        durationAnchor = "CENTER", durationX = 0, durationY = 0,
        durationColorByTime = true,
        durationHideAboveEnabled = false, durationHideAboveThreshold = 10,
        frameLevel = 30, frameStrata = "INHERIT",
    },
    -- Frame-level types: mirror the inline literals in EnsureTypeConfig so the
    -- colour-picker Default button (and any other consumer of __dfDefaults) can
    -- resolve a default value for keys like "color" and "expiringColor".
    -- Border-type (Stage 5.4): full canonical DF.Border defaults so
    -- CreateBorderControls' dropdowns / pickers read sensible values.  The
    -- legacy style/thickness/inset/color are migrated on load.
    border = {
        ShowBorder = true, BorderSize = 2, BorderInset = 0,
        BorderColor             = {r = 1, g = 1, b = 1, a = 1},
        BorderStyle             = "SOLID",
        BorderBlendMode         = "BLEND",
        BorderOffsetX           = 0,
        BorderOffsetY           = 0,
        BorderGradientStartColor = {r = 0,    g = 0,    b = 0,    a = 1},
        BorderGradientEndColor   = {r = 0.5,  g = 0.5,  b = 0.5,  a = 1},
        BorderGradientDirection  = "HORIZONTAL",
        BorderShadowEnabled      = false,
        BorderShadowColor        = {r = 0, g = 0, b = 0, a = 0.8},
        BorderShadowSize         = 1,
        BorderShadowOffsetX      = 1,
        BorderShadowOffsetY      = -1,
        BorderAnimationType         = "NONE",
        BorderAnimationColor        = {r = 0.95, g = 0.95, b = 0.32, a = 1},
        BorderAnimationFrequency    = 1,
        BorderAnimationParticles    = 8,
        BorderAnimationLength       = 8,
        BorderAnimationThickness    = 3,
        BorderAnimationScale        = 1,
        BorderAnimationInset        = 0,
        BorderAnimationOffsetX      = 0,
        BorderAnimationOffsetY      = 0,
        BorderAnimationMask         = false,
        BorderAnimationSidesAxis    = "HORIZONTAL",
        BorderAnimationCornerLength = 10,
        -- Draw above the frame's class border (parent+10) / aggro (parent+9).
        drawAboveFrameBorder = true,
        -- Expiring-border overrides (Stage 5.4 parity with icon/square).
        expiringFeatureEnabled = true,
        expiringEnabled = false, expiringThreshold = 30, expiringThresholdMode = "PERCENT",
        expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
        expiringPulsate = false,
        ExpiringBorderSize  = 2,
        ExpiringBorderAlpha = 1,
        ExpiringAnimationType         = "NONE",
        ExpiringAnimationColor        = {r = 0.95, g = 0.95, b = 0.32, a = 1},
        ExpiringAnimationFrequency    = 1,
        ExpiringAnimationParticles    = 8,
        ExpiringAnimationLength       = 8,
        ExpiringAnimationThickness    = 3,
        ExpiringAnimationScale        = 1,
        ExpiringAnimationInset        = 0,
        ExpiringAnimationOffsetX      = 0,
        ExpiringAnimationOffsetY      = 0,
        ExpiringAnimationMask         = false,
        ExpiringAnimationSidesAxis    = "HORIZONTAL",
        ExpiringAnimationCornerLength = 10,
        showWhenMissing = false,
    },
    healthbar = {
        mode = "Replace", color = {r = 1, g = 1, b = 1, a = 1}, blend = 0.5,
        tintWholeBar = false,
        expiringEnabled = false, expiringThreshold = 30, expiringThresholdMode = "PERCENT",
        expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
        expiringPulsate = false,
        showWhenMissing = false,
    },
    background = {
        mode = "Tint", color = {r = 1, g = 1, b = 1, a = 1}, blend = 0.5,
        expiringEnabled = false, expiringThreshold = 30, expiringThresholdMode = "PERCENT",
        expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
        expiringPulsate = false,
        showWhenMissing = false,
    },
    nametext = {
        color = {r = 1, g = 1, b = 1, a = 1},
        expiringEnabled = false, expiringThreshold = 30, expiringThresholdMode = "PERCENT",
        expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
        showWhenMissing = false,
    },
    healthtext = {
        color = {r = 1, g = 1, b = 1, a = 1},
        expiringEnabled = false, expiringThreshold = 30, expiringThresholdMode = "PERCENT",
        expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
        showWhenMissing = false,
    },
    framealpha = {
        alpha = 0.5,
        expiringEnabled = false, expiringThreshold = 30, expiringThresholdMode = "PERCENT",
        expiringAlpha = 1.0,
        showWhenMissing = false,
    },
}

-- ============================================================
-- INSTANCE-BASED INDICATOR HELPERS
-- Placed indicators (icon/square/bar) are stored as instances
-- in auraCfg.indicators[] with stable IDs.
-- ============================================================

-- Create a new indicator instance for an aura, returns the instance table
local function CreateIndicatorInstance(auraName, typeKey)
    local auraCfg = EnsureAuraConfig(auraName)
    if not auraCfg.indicators then
        auraCfg.indicators = {}
    end
    if not auraCfg.nextIndicatorID then
        auraCfg.nextIndicatorID = 1
    end

    -- Only store id, type, and anchor — all other settings fall through
    -- to global defaults then TYPE_DEFAULTS via CreateInstanceProxy
    local defaults = TYPE_DEFAULTS[typeKey]

    -- Create minimal instance: just id + type + anchor placement
    local instance = {
        anchor = defaults and defaults.anchor or "TOPLEFT",
        offsetX = 0,
        offsetY = 0,
    }

    instance.id = auraCfg.nextIndicatorID
    instance.type = typeKey
    auraCfg.nextIndicatorID = auraCfg.nextIndicatorID + 1

    tinsert(auraCfg.indicators, instance)
    return instance
end

-- Find an indicator instance by its stable ID. `pool` (optional) pins the
-- pool; defaults to the active tab's pool.
local function GetIndicatorByID(auraName, indicatorID, pool)
    local auraCfg = (pool or CurrentAuraPool())[auraName]
    if not auraCfg or not auraCfg.indicators then return nil end
    for _, inst in ipairs(auraCfg.indicators) do
        if inst.id == indicatorID then
            return inst
        end
    end
    return nil
end

-- Remove an indicator instance by its stable ID
local CleanupAdHocAura  -- forward decl: defined after FRAME_LEVEL_TYPE_KEYS
local function RemoveIndicatorInstance(auraName, indicatorID)
    local auraCfg = CurrentAuraPool()[auraName]
    if not auraCfg or not auraCfg.indicators then return end
    for i, inst in ipairs(auraCfg.indicators) do
        if inst.id == indicatorID then
            table.remove(auraCfg.indicators, i)
            if CleanupAdHocAura then CleanupAdHocAura(auraName) end
            return
        end
    end
end

-- (ChangeInstanceType removed — uncalled since the tile-strip type switcher
-- left the v4 redesign; reclaimed for the 200-locals ceiling.)

-- Keys to skip when copying appearance between indicators (identity + placement +
-- the eye toggle's hidden state — copying appearance must not hide the destination)
local COPY_SKIP_KEYS = { id = true, type = true, anchor = true, offsetX = true, offsetY = true, enabled = true }

-- Deep-copy a value (handles nested tables like color = {r,g,b,a})
local function DeepCopyValue(val)
    if type(val) == "table" then
        local copy = {}
        for k, v in pairs(val) do
            copy[k] = DeepCopyValue(v)
        end
        return copy
    end
    return val
end

-- Copy appearance settings from one placed indicator to another of the same type.
-- Copies all keys except identity (id, type) and placement (anchor, offsetX, offsetY).
-- Keys present on source are deep-copied; keys absent on source are removed from
-- destination so they fall through to defaults via the proxy chain.
local function CopyIndicatorAppearance(srcAuraName, srcIndicatorID, dstAuraName, dstIndicatorID)
    local src = GetIndicatorByID(srcAuraName, srcIndicatorID)
    local dst = GetIndicatorByID(dstAuraName, dstIndicatorID)
    if not src or not dst then return end
    if src.type ~= dst.type then return end

    -- Collect all non-skip keys from both source and destination
    local allKeys = {}
    for k in pairs(src) do
        if not COPY_SKIP_KEYS[k] then allKeys[k] = true end
    end
    for k in pairs(dst) do
        if not COPY_SKIP_KEYS[k] then allKeys[k] = true end
    end

    -- Sync: copy from src, clear from dst what src doesn't have
    for k in pairs(allKeys) do
        if src[k] ~= nil then
            dst[k] = DeepCopyValue(src[k])
        else
            dst[k] = nil
        end
    end
end

-- Forward declaration: lightweight preview refresh (defined after RefreshPreviewEffects)
-- Called from proxy __newindex so every setting change updates the preview in real-time
local RefreshPreviewLightweight

-- Throttled live-frame refresh: re-syncs the factory containers on all
-- visible AD-enabled frames. Debounced so rapid slider drags only trigger one refresh.
local pendingLiveRefresh = false
local function RefreshLiveFramesThrottled()
    if pendingLiveRefresh then return end
    pendingLiveRefresh = true
    C_Timer.After(0.1, function()
        pendingLiveRefresh = false
        local engine = DF.AuraDesigner and DF.AuraDesigner.Engine
        if engine and engine.ForceRefreshAllFrames then
            engine:ForceRefreshAllFrames()
        end
    end)
end

-- Global-default key mapping: which global default keys apply to placed types
local GLOBAL_DEFAULT_MAP = {
    icon   = {
        size = "iconSize", scale = "iconScale", showDuration = "showDuration", showStacks = "showStacks",
        durationFont = "durationFont", durationScale = "durationScale", durationOutline = "durationOutline",
        durationAnchor = "durationAnchor", durationX = "durationX", durationY = "durationY",
        durationColorByTime = "durationColorByTime", durationColor = "durationColor",
        stackFont = "stackFont", stackScale = "stackScale", stackOutline = "stackOutline",
        stackAnchor = "stackAnchor", stackX = "stackX", stackY = "stackY",
        stackMinimum = "stackMinimum", stackColor = "stackColor",
        hideSwipe = "hideSwipe", hideIcon = "hideIcon",
        frameLevel = "indicatorFrameLevel", frameStrata = "indicatorFrameStrata",
    },
    square = {
        size = "iconSize", scale = "iconScale", showDuration = "showDuration", showStacks = "showStacks",
        durationFont = "durationFont", durationScale = "durationScale", durationOutline = "durationOutline",
        durationAnchor = "durationAnchor", durationX = "durationX", durationY = "durationY",
        durationColorByTime = "durationColorByTime", durationColor = "durationColor",
        stackFont = "stackFont", stackScale = "stackScale", stackOutline = "stackOutline",
        stackAnchor = "stackAnchor", stackX = "stackX", stackY = "stackY",
        stackMinimum = "stackMinimum", stackColor = "stackColor",
        hideSwipe = "hideSwipe", hideIcon = "hideIcon",
        frameLevel = "indicatorFrameLevel", frameStrata = "indicatorFrameStrata",
    },
    bar    = {
        durationFont = "durationFont", durationScale = "durationScale", durationOutline = "durationOutline",
        durationAnchor = "durationAnchor", durationX = "durationX", durationY = "durationY",
        durationColorByTime = "durationColorByTime",
        frameLevel = "indicatorFrameLevel", frameStrata = "indicatorFrameStrata",
    },
}

-- Create a proxy table that maps flat key access to an indicator instance
-- Fallback chain: instance value → global defaults → TYPE_DEFAULTS
local function CreateInstanceProxy(auraName, indicatorID)
    -- Pin the pool at creation (B2): proxies are minted per effect card, and
    -- the card's tab is the record's pool — a callback firing after a tab
    -- switch must keep reading/writing the ORIGINAL pool.
    local otherPool = IsOtherTab()
    local function pool() return otherPool and GetOtherAuras() or GetSpecAuras() end
    -- Resolve current type to expose TYPE_DEFAULTS to GUI:CreateColorPicker's
    -- Default button. Type changes rebuild the panel (RefreshPage) which makes
    -- a fresh proxy, so stashing at construction time is safe.
    local _inst = GetIndicatorByID(auraName, indicatorID, pool())
    local _typeDefaults = _inst and TYPE_DEFAULTS[_inst.type] or nil
    return setmetatable({ _skipOverrideIndicators = true, __dfDefaults = _typeDefaults }, {
        __index = function(_, k)
            local inst = GetIndicatorByID(auraName, indicatorID, pool())
            if inst then
                local val = inst[k]
                if val ~= nil then return val end
            end
            -- Fall back to global defaults for applicable keys
            local fallback
            if inst and inst.type then
                local gdMap = GLOBAL_DEFAULT_MAP[inst.type]
                if gdMap then
                    local gdKey = gdMap[k]
                    if gdKey then
                        local adDB = GetAuraDesignerDB()
                        local gd = adDB and adDB.defaults
                        if gd and gd[gdKey] ~= nil then fallback = gd[gdKey] end
                    end
                end
                -- Then fall back to TYPE_DEFAULTS
                if fallback == nil then
                    local defaults = TYPE_DEFAULTS[inst.type]
                    if defaults then fallback = defaults[k] end
                end
            end
            -- Copy-on-read: if fallback is a table, copy it into the instance
            -- so that sub-key mutations (e.g. proxy.color.r = 1) persist
            if type(fallback) == "table" and inst then
                local copy = {}
                for fk, fv in pairs(fallback) do copy[fk] = fv end
                inst[k] = copy
                return copy
            end
            return fallback
        end,
        __newindex = function(_, k, v)
            local inst = GetIndicatorByID(auraName, indicatorID, pool())
            if not inst then return end
            inst[k] = v
            if RefreshPreviewLightweight then RefreshPreviewLightweight() end
            RefreshLiveFramesThrottled()
        end,
    })
end

-- Create a proxy table that maps flat key access to nested aura config
local function CreateProxy(auraName, typeKey)
    local defaults = TYPE_DEFAULTS[typeKey]
    -- Pin the pool at creation (B2) — see CreateInstanceProxy.
    local otherPool = IsOtherTab()
    local function pool() return otherPool and GetOtherAuras() or GetSpecAuras() end
    -- Expose defaults to GUI:CreateColorPicker so its Default button can resolve
    -- AD-specific keys (color/expiringColor/etc.) that aren't in PartyDefaults.
    return setmetatable({ _skipOverrideIndicators = true, __dfDefaults = defaults }, {
        __index = function(_, k)
            local auraCfg = pool()[auraName]
            if auraCfg and auraCfg[typeKey] then
                local val = auraCfg[typeKey][k]
                if val ~= nil then return val end
            end
            -- Fall back to defaults for missing keys
            local fallback = defaults and defaults[k] or nil
            -- Copy-on-read: if fallback is a table, copy it into the config
            -- so that sub-key mutations (e.g. proxy.color.r = 1) persist
            if type(fallback) == "table" then
                local typeCfg = EnsureTypeConfig(auraName, typeKey, pool())
                local copy = {}
                for fk, fv in pairs(fallback) do copy[fk] = fv end
                typeCfg[k] = copy
                return copy
            end
            return fallback
        end,
        __newindex = function(_, k, v)
            local typeCfg = EnsureTypeConfig(auraName, typeKey, pool())
            typeCfg[k] = v
            if RefreshPreviewLightweight then RefreshPreviewLightweight() end
            RefreshLiveFramesThrottled()
        end,
    })
end

-- Create a proxy for the aura-level config (priority, expiring)
local function CreateAuraProxy(auraName)
    -- Pin the pool at creation (B2) — see CreateInstanceProxy.
    local otherPool = IsOtherTab()
    local function pool() return otherPool and GetOtherAuras() or GetSpecAuras() end
    return setmetatable({ _skipOverrideIndicators = true }, {
        __index = function(_, k)
            local auraCfg = pool()[auraName]
            if auraCfg then return auraCfg[k] end
            return nil
        end,
        __newindex = function(_, k, v)
            local auraCfg = EnsureAuraConfig(auraName, pool())
            auraCfg[k] = v
            if RefreshPreviewLightweight then RefreshPreviewLightweight() end
            RefreshLiveFramesThrottled()
        end,
    })
end

-- ============================================================
-- WARNING BADGE
-- Some auras have underlying API limitations that mean multiple
-- spells collapse into a single indicator. Entries in Config.lua
-- with a `warningKey` get a small yellow triangle overlay on their
-- spell icon and collapsible header, with a tooltip explaining why.
-- ============================================================

local WARNING_TEXTURE = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\warning.tga"

-- Resolve a warningKey to localized tooltip text. Keys are defined
-- here rather than Config.lua so they can go through L[] without
-- load-order concerns.
local function GetWarningText(warningKey)
    if not warningKey then return nil end
    local L = DF.L or setmetatable({}, { __index = function(_, k) return k end })
    if warningKey == "HolyArmamentsMerge" then
        return L["Holy Bulwark and Sacred Weapon share the same aura signature and cannot be tracked separately. Both buffs will trigger this single indicator."]
    end
    return nil
end

-- Look up the warningKey for a given aura name in the current spec.
local function GetAuraWarningKey(specKey, auraName)
    local specList = DF.AuraDesigner.TrackableAuras and DF.AuraDesigner.TrackableAuras[specKey]
    if not specList then return nil end
    for _, entry in ipairs(specList) do
        if entry.name == auraName then return entry.warningKey end
    end
    return nil
end

-- Attach (or refresh) a warning triangle badge on the given region.
-- host:     parent Frame the badge is attached to (must be a Frame).
-- warnKey:  config warning key; nil hides the badge.
-- opts:     optional table with:
--             point         -- default "TOPRIGHT"
--             relativeTo    -- default host
--             relativePoint -- default "TOPRIGHT"
--             offsetX/Y     -- default 3, 3
--             size          -- default 16
--             color         -- { r, g, b } default red { 1.0, 0.25, 0.25 }
local function AttachWarningBadge(host, warnKey, opts)
    if not host then return end
    local badge = host.dfWarningBadge
    if not warnKey then
        if badge then badge:Hide() end
        return
    end
    local tooltipText = GetWarningText(warnKey)
    if not tooltipText then
        if badge then badge:Hide() end
        return
    end

    if not badge then
        badge = CreateFrame("Frame", nil, host)
        badge:SetFrameLevel(host:GetFrameLevel() + 5)
        local tex = badge:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints(badge)
        tex:SetTexture(WARNING_TEXTURE)
        badge.texture = tex
        badge:SetScript("OnEnter", function(self)
            GUI:ShowTooltip(self, { title = self.tooltipText or "" })
        end)
        badge:SetScript("OnLeave", function() GUI:HideTooltip() end)
        host.dfWarningBadge = badge
    end

    opts = opts or {}
    local size = opts.size or 16
    local color = opts.color or { 1.0, 0.25, 0.25 }
    badge:SetSize(size, size)
    badge:ClearAllPoints()
    badge:SetPoint(
        opts.point or "TOPRIGHT",
        opts.relativeTo or host,
        opts.relativePoint or "TOPRIGHT",
        opts.offsetX or 3,
        opts.offsetY or 3
    )
    badge.texture:SetVertexColor(color[1], color[2], color[3])
    badge.tooltipText = tooltipText
    badge:Show()
end

-- Ad-hoc add-by-ID auras (picker "Add" with an ID the SpellDB doesn't know)
-- are stored under the key "#<spellID>" — the name IS the identity, so the
-- record needs no side table and survives reload/profile export for free.
-- Returns the embedded numeric spell ID, or nil for normal aura names.
local function AdHocSpellID(auraName)
    if type(auraName) ~= "string" then return nil end
    local id = auraName:match("^#(%d+)$")
    return id and tonumber(id) or nil
end

-- Configured ad-hoc "#<id>" auras are never in the trackable pool, so pool-driven
-- pickers (layout-group "Add aura", frame-effect "Add Trigger") can't offer them.
-- Returns a NEW list = the given trackable list plus one aura-info-shaped entry per
-- configured ad-hoc aura (live-resolved display name, pool-grey accent), sorted by
-- spell ID for a stable order. Never mutates `list` — GetTrackableAuras caches it.
local AD_HOC_COLOR = { 0.62, 0.62, 0.62 }
local function WithConfiguredAdHocAuras(list, spec)
    local out = {}
    for i, info in ipairs(list) do out[i] = info end
    local adHoc = {}
    -- Pool-routed: the Other tab's group picker offers the OTHER pool's
    -- configured ad-hoc auras (never creates it — read accessor).
    for auraName in pairs(CurrentAuraPool(spec)) do
        local id = AdHocSpellID(auraName)
        if id then tinsert(adHoc, { name = auraName, id = id }) end
    end
    sort(adHoc, function(a, b) return a.id < b.id end)
    for _, e in ipairs(adHoc) do
        local display = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(e.id)
        tinsert(out, {
            name = e.name,
            display = display or e.name,
            color = AD_HOC_COLOR,
            spellID = e.id,
            class = "ALL",  -- picker grid sections by class; ad-hoc ids aren't class spells
        })
    end
    return out
end

-- Get spell icon texture for an aura
-- Uses static texture IDs to avoid C_Spell.GetSpellTexture returning
-- the wrong icon when talent choice nodes replace a spell.
local function GetAuraIcon(specKey, auraName)
    -- Static icon table — always returns the correct icon regardless of talents
    local icons = DF.AuraDesigner.IconTextures
    if icons and icons[auraName] then
        return icons[auraName]
    end
    -- Fallback to dynamic API for any aura not in the static table
    local spellIDs = DF.AuraDesigner.SpellIDs
    local specIDs = spellIDs and specKey and spellIDs[specKey]
    local spellID = specIDs and specIDs[auraName]
    if not spellID or spellID == 0 then
        -- Ad-hoc "#<id>" keys resolve directly to their embedded spell ID
        spellID = AdHocSpellID(auraName)
    end
    if not spellID or spellID == 0 then
        -- SpellDB fallback (all-spec support): auras with no curated Config
        -- entry resolve by name through the FilterRegistry SpellDB
        local R = DF.FilterRegistry
        local rec = R and R.GetSpellByName and R:GetSpellByName(auraName)
        spellID = rec and rec.id
    end
    if not spellID or spellID == 0 then return nil end
    if C_Spell and C_Spell.GetSpellTexture then
        return C_Spell.GetSpellTexture(spellID)
    elseif GetSpellTexture then
        return GetSpellTexture(spellID)
    end
    return nil
end

-- (CountActiveEffects removed — uncalled since the v4 flat-card redesign;
-- reclaimed for the file-scope 200-locals ceiling.)

-- ============================================================
-- MULTI-TRIGGER HELPERS
-- Functions for managing trigger auras on frame-level effects
-- ============================================================

-- Get triggers for a frame effect (returns owning aura name in a table if no explicit triggers)
local function GetFrameEffectTriggers(auraName, typeKey)
    local auraCfg = CurrentAuraPool()[auraName]
    local typeCfg = auraCfg and auraCfg[typeKey]
    if typeCfg and typeCfg.triggers then
        return typeCfg.triggers
    end
    return { auraName }  -- Default: just the owning aura
end

-- Add a trigger aura to a frame effect. `pool` (optional) pins the target
-- pool — the floating trigger picker captures it at OPEN time so a dropdown
-- surviving a tab switch can't write the trigger into the wrong pool.
local function AddFrameEffectTrigger(auraName, typeKey, triggerName, pool)
    local typeCfg = EnsureTypeConfig(auraName, typeKey, pool)
    if not typeCfg.triggers then
        typeCfg.triggers = { auraName }  -- Initialize with owner
    end
    -- Check not already present
    for _, t in ipairs(typeCfg.triggers) do
        if t == triggerName then return end
    end
    tinsert(typeCfg.triggers, triggerName)
end

-- Remove a trigger aura from a frame effect (minimum 1 trigger required)
local function RemoveFrameEffectTrigger(auraName, typeKey, triggerName)
    local auraCfg = CurrentAuraPool()[auraName]
    local typeCfg = auraCfg and auraCfg[typeKey]
    if not typeCfg or not typeCfg.triggers or #typeCfg.triggers <= 1 then return end
    for i, t in ipairs(typeCfg.triggers) do
        if t == triggerName then
            tremove(typeCfg.triggers, i)
            break
        end
    end
end

-- Close the floating trigger picker (parented to UIParent, so it survives
-- card rebuilds). Called on main-tab and spec switches: its rows capture the
-- pool/effect from open time, so a stale open dropdown must not linger.
local function HideTriggerPicker()
    local drop = _G["DFADTriggerPicker"]
    if drop and drop:IsShown() then drop:Hide() end
end

-- ============================================================
-- LAYOUT GROUP HELPERS
-- Functions for managing layout groups
-- ============================================================

-- State for expanded layout group cards
local expandedGroups = {}

-- expandedGroups key for a layout group id on the ACTIVE tab: raw numeric id
-- on My Buffs (legacy keys, kept as-is), "othergroup:<id>" on Other Buffs.
-- The two id counters overlap, so the string prefix keeps expansion state
-- per-pool ("dgroup:<id>" is the Debuffs form in the same table).
local function GroupExpandKey(groupID)
    if IsOtherTab() then return "othergroup:" .. groupID end
    return groupID
end

-- Find which layout group (if any) an indicator belongs to — searched in the
-- ACTIVE tab's group store, so an other-pool indicator only matches other-pool
-- groups (a same-named spec-pool member with a matching indicatorID can never
-- false-match across pools).
local function GetIndicatorLayoutGroup(auraName, indicatorID)
    local groups = CurrentLayoutGroups()
    for _, group in ipairs(groups) do
        if group.members then
            for _, member in ipairs(group.members) do
                if member.auraName == auraName and member.indicatorID == indicatorID then
                    return group
                end
            end
        end
    end
    return nil
end

-- (GetUngroupedIndicators removed — uncalled since the group picker moved to
-- the full spell-picker "group" mode; reclaimed for the 200-locals ceiling.)

-- Create a new layout group. kind: nil/"members" = classic member arranger
-- (legacy records carry no kind); "filter" = a container-backed group linked to
-- registry filters (stable preset keys / custom ids in filterSelection) with
-- uniform per-group styling (iconSize / maxIcons on top of the shared layout).
local function CreateLayoutGroup(name, kind)
    local adDB = GetAuraDesignerDB()
    if not adDB then return nil end
    -- Pool-routed: the Other Buffs tab creates into the flat spec-independent
    -- store (born lazily HERE — the first add) with its own id counter.
    local groups, id
    if IsOtherTab() then
        groups = GetOtherLayoutGroups(true)  -- the first add creates the store
        if not adDB.nextOtherLayoutGroupID then adDB.nextOtherLayoutGroupID = 1 end
        id = adDB.nextOtherLayoutGroupID
        adDB.nextOtherLayoutGroupID = id + 1
    else
        groups = GetSpecLayoutGroups()
        if not adDB.nextLayoutGroupID then adDB.nextLayoutGroupID = 1 end
        id = adDB.nextLayoutGroupID
        adDB.nextLayoutGroupID = id + 1
    end
    local group = {
        id = id,
        name = name or ((kind == "filter") and ("Filter Group " .. id) or ("Group " .. id)),
        anchor = "TOPLEFT",
        offsetX = 0,
        offsetY = 0,
        growDirection = "RIGHT_DOWN",
        iconsPerRow = 8,
        spacing = 2,
    }
    if kind == "filter" then
        group.kind = "filter"
        group.filterSelection = { presets = {}, customs = {} }
        group.iconSize = 24
        -- Filter groups start compact (4×4); member groups keep the shared 8.
        -- Creation-time values only — existing saved groups are untouched.
        group.iconsPerRow = 4
        group.maxIcons = 4
    else
        group.members = {}
    end
    tinsert(groups, group)
    return group
end

-- Delete a layout group by ID (from the ACTIVE tab's store; the member-
-- indicator cascade removes from the active pool via RemoveIndicatorInstance's
-- CurrentAuraPool routing — members always live in their group's pool)
local function DeleteLayoutGroup(groupID)
    local groups = CurrentLayoutGroups()
    for i, group in ipairs(groups) do
        if group.id == groupID then
            -- Delete all member indicators when deleting the group
            if group.members then
                for _, member in ipairs(group.members) do
                    RemoveIndicatorInstance(member.auraName, member.indicatorID)
                end
            end
            tremove(groups, i)
            break
        end
    end
    expandedGroups[GroupExpandKey(groupID)] = nil
end

-- Delete a debuff category group by ID (C2). No member indicators to cascade
-- (category groups own no placed indicators). The caller runs the FULL
-- structural chain afterwards — the group's claimed categories return to the
-- main debuff bar. Card keys are "dgroup:<id>" (see BuildDebuffGroupsTab).
local function DeleteDebuffGroup(groupID)
    local groups = DebuffGroupsRead()
    for i, group in ipairs(groups) do
        if group.id == groupID then
            tremove(groups, i)
            break
        end
    end
    expandedGroups["dgroup:" .. groupID] = nil
end

-- Find a layout group by ID (active tab's store)
local function GetLayoutGroupByID(groupID)
    local groups = CurrentLayoutGroups()
    for _, group in ipairs(groups) do
        if group.id == groupID then return group end
    end
    return nil
end

-- Add a member to a layout group
local function AddGroupMember(groupID, auraName, indicatorID)
    local group = GetLayoutGroupByID(groupID)
    if not group then return end
    if not group.members then group.members = {} end
    -- Check not already in this group
    for _, m in ipairs(group.members) do
        if m.auraName == auraName and m.indicatorID == indicatorID then return end
    end
    tinsert(group.members, { auraName = auraName, indicatorID = indicatorID })
end

-- Remove a member from a layout group
local function RemoveGroupMember(groupID, auraName, indicatorID)
    local group = GetLayoutGroupByID(groupID)
    if not group or not group.members then return end
    for i, m in ipairs(group.members) do
        if m.auraName == auraName and m.indicatorID == indicatorID then
            tremove(group.members, i)
            break
        end
    end
end

-- Swap two members in a layout group (for reordering)
local function SwapGroupMembers(groupID, idx1, idx2)
    local group = GetLayoutGroupByID(groupID)
    if not group or not group.members then return end
    if idx1 < 1 or idx1 > #group.members or idx2 < 1 or idx2 > #group.members then return end
    group.members[idx1], group.members[idx2] = group.members[idx2], group.members[idx1]
end

-- Anchor dot pool (populated during CreateFramePreview, used by drag system)
local anchorDots = {}

-- Anchor point positions relative to the mock frame
local ANCHOR_POSITIONS = {
    TOPLEFT     = { x = 0,   y = 0,    ax = "TOPLEFT",     ay = "TOPLEFT"     },
    TOP         = { x = 0.5, y = 0,    ax = "TOP",         ay = "TOP"         },
    TOPRIGHT    = { x = 1,   y = 0,    ax = "TOPRIGHT",    ay = "TOPRIGHT"    },
    LEFT        = { x = 0,   y = 0.5,  ax = "LEFT",        ay = "LEFT"        },
    CENTER      = { x = 0.5, y = 0.5,  ax = "CENTER",      ay = "CENTER"      },
    RIGHT       = { x = 1,   y = 0.5,  ax = "RIGHT",       ay = "RIGHT"       },
    BOTTOMLEFT  = { x = 0,   y = 1,    ax = "BOTTOMLEFT",  ay = "BOTTOMLEFT"  },
    BOTTOM      = { x = 0.5, y = 1,    ax = "BOTTOM",      ay = "BOTTOM"      },
    BOTTOMRIGHT = { x = 1,   y = 1,    ax = "BOTTOMRIGHT", ay = "BOTTOMRIGHT" },
}

-- ============================================================
-- FRAME REFERENCES (populated during build)
-- Declared early so drag/indicator/effects code can capture them
-- ============================================================
local mainFrame           -- The root frame for the entire page
local leftPanel           -- Left content area (frame preview)
local rightPanel          -- Right settings panel (tabbed)
local enableBanner        -- Enable toggle banner
local framePreview        -- Mock unit frame preview
local dragHintText        -- Dynamic hint text below frame preview

-- Layout anchors — stored during build
local contentRightInset     -- Right inset for left-side panels
local origY_framePreview    -- original yPos of framePreview

-- (The DF_AURA_DESIGNER_RESET_GLOBAL popup was retired with the editing-banner
-- "Reset to Global" button — the preset dropdown's "Inherit (Global)" entry now
-- clears a layout's Aura Designer preset override.)

-- ============================================================
-- UI STATE (v4 redesign — tabbed right panel)
-- ============================================================
local activeTab = "effects"       -- "effects" | "layout" | "global"
local activeFilter = "all"        -- Filter chip state
local expandedCards = {}           -- { ["placed:AuraName#1"] = true, ["frame:border:AuraName"] = true }
local spellPickerActive = false    -- Is spell picker overlay showing
local spellPickerType = nil        -- "icon" | "square" | "bar"

-- Tab system frame references
local tabBar                -- Tab bar frame (Effects | Layout Groups | Global)
local tabButtons = {}       -- { effects = btn, layout = btn, global = btn }
local mainTabButtons = {}   -- { my = btn, other = btn } (B2 main pool tab strip)
local specDropdown          -- shared spec dropdown (lives on the main tab strip)
local specDropdownUpdate    -- rebuilds the spec dropdown options + opener text
local tabContentFrame       -- Scrollable content area below tabs
local tabScrollFrame        -- ScrollFrame wrapping tabContentFrame
local spellPickerView       -- Overlay view for spell picker (replaces tabs when active)
local effectCardPool = {}   -- Reusable card frames

-- ============================================================
-- EFFECTS LIST DATA COLLECTION
-- Gathers all effects across all auras into a flat list for
-- the new Effects tab. Replaces the old per-aura view.
-- ============================================================

local FRAME_LEVEL_TYPE_KEYS = { "border", "healthbar", "background", "nametext", "healthtext", "framealpha", "sound" }

-- Remove an ad-hoc "#<id>" aura's config entry once it holds no effects at
-- all (empty/absent indicators array AND no frame-level type keys). Ad-hoc
-- auras exist ONLY through their effects — they are never in the trackable
-- pool — so an emptied config would linger in the profile forever as a
-- phantom entry (group/trigger pickers, SavedVariables growth). Curated
-- auras deliberately keep today's linger behavior. Forward-declared above
-- RemoveIndicatorInstance, which calls it after every removal.
CleanupAdHocAura = function(auraName)
    if not AdHocSpellID(auraName) then return end
    local auras = CurrentAuraPool()
    local auraCfg = auras and auras[auraName]
    if type(auraCfg) ~= "table" then return end
    if auraCfg.indicators and #auraCfg.indicators > 0 then return end
    for _, typeKey in ipairs(FRAME_LEVEL_TYPE_KEYS) do
        if auraCfg[typeKey] ~= nil then return end
    end
    auras[auraName] = nil
end

-- Effect-type display labels. Same file-scope-vs-overlay timing issue as the
-- option tables near the top of this file: build them in a registered refresh
-- fn so they pick up the active locale.
local FRAME_LEVEL_LABELS = {}
local PLACED_TYPE_LABELS = {}

local function RefreshEffectLabels()
    FRAME_LEVEL_LABELS = {
        border     = L["Border"],
        healthbar  = L["Health Bar"],
        background  = L["Background"],
        nametext   = L["Name Text"],
        healthtext = L["Health Text"],
        framealpha = L["Frame Alpha"],
        sound      = L["Sound Alert"],
    }

    PLACED_TYPE_LABELS = {
        icon   = L["Icon"],
        square = L["Square"],
        bar    = L["Bar"],
    }
end

RefreshEffectLabels()
DF:RegisterLocaleRefresh(RefreshEffectLabels)

local BADGE_COLORS = {
    icon       = { r = 0.36, g = 0.72, b = 0.94 },  -- Blue
    square     = { r = 0.51, g = 0.86, b = 0.51 },  -- Green
    bar        = { r = 0.94, g = 0.71, b = 0.24 },  -- Orange
    border     = { r = 0.80, g = 0.50, b = 0.80 },  -- Purple
    healthbar  = { r = 0.94, g = 0.31, b = 0.31 },  -- Red
    background = { r = 0.40, g = 0.55, b = 0.65 },  -- Slate
    nametext   = { r = 0.72, g = 0.72, b = 0.94 },  -- Light blue
    healthtext = { r = 0.72, g = 0.72, b = 0.94 },  -- Light blue
    framealpha = { r = 0.60, g = 0.60, b = 0.60 },  -- Grey
    sound      = { r = 0.94, g = 0.76, b = 0.24 },  -- Gold/yellow
}

-- Collect all configured effects into a flat, sorted list
-- Returns: { { source="placed"|"frame", auraName, typeKey, ... }, ... }
local function CollectAllEffects()
    local effects = {}

    local spec = ResolveSpec()
    local trackable = spec and Adapter and Adapter:GetTrackableAuras(spec)
    -- Build display name lookup (only auras belonging to current spec)
    local displayNames = {}
    if trackable then
        for _, info in ipairs(trackable) do
            displayNames[info.name] = info.display
        end
    end

    local isOther = IsOtherTab()
    for auraName, auraCfg in pairs(CurrentAuraPool(spec)) do
        -- My Buffs: only show effects for auras belonging to the current spec.
        -- Ad-hoc "#<id>" auras (picker add-by-ID) always belong — they are
        -- never in the trackable pool, so resolve their display name live.
        -- Other Buffs: the pool is spec-independent — every record shows
        -- (names are SpellDB names or ad-hoc keys; resolve display live).
        local adHocID = AdHocSpellID(auraName)
        local displayName
        if isOther then
            displayName = OtherPoolDisplayName(auraName)
        else
            displayName = displayNames[auraName]
            if not displayName and adHocID then
                displayName = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(adHocID) or auraName
            end
        end
        if type(auraCfg) == "table" and displayName then
            -- Placed indicators
            if auraCfg.indicators then
                for _, indicator in ipairs(auraCfg.indicators) do
                    tinsert(effects, {
                        source      = "placed",
                        auraName    = auraName,
                        displayName = displayName,
                        indicatorID = indicator.id,
                        typeKey     = indicator.type,
                        config      = indicator,
                        anchor      = indicator.anchor or "CENTER",
                    })
                end
            end

            -- Frame-level effects (current per-aura model)
            for _, typeKey in ipairs(FRAME_LEVEL_TYPE_KEYS) do
                if auraCfg[typeKey] then
                    tinsert(effects, {
                        source      = "frame",
                        auraName    = auraName,
                        displayName = displayName,
                        typeKey     = typeKey,
                        config      = auraCfg[typeKey],
                    })
                end
            end
        end
    end

    -- Sort: newest first (reverse by insertion order — higher IDs first for placed)
    sort(effects, function(a, b)
        -- Placed before frame-level
        if a.source ~= b.source then
            return a.source == "placed"
        end
        -- Within placed: higher indicatorID first (newest)
        if a.source == "placed" and b.source == "placed" then
            return (a.indicatorID or 0) > (b.indicatorID or 0)
        end
        -- Within frame-level: alphabetical by type
        return a.typeKey < b.typeKey
    end)

    return effects
end

-- Check if a specific aura + type combo already has a placed indicator
local function IsAuraTypePlaced(auraName, typeKey)
    local auraCfg = CurrentAuraPool()[auraName]
    if not auraCfg or not auraCfg.indicators then return false end
    for _, indicator in ipairs(auraCfg.indicators) do
        if indicator.type == typeKey then return true end
    end
    return false
end

-- ============================================================
-- DRAG AND DROP SYSTEM
-- Modeled after DandersCDM's ghost-based drag pattern:
--   Ghost frame (TOOLTIP strata, EnableMouse false) follows cursor
--   Anchor dots act as drop targets via OnEnter/OnLeave
--   OnUpdate frame polls IsMouseButtonDown for drop detection
-- ============================================================

local dragState = {
    isDragging = false,
    auraName = nil,         -- Which aura is being dragged
    auraInfo = nil,         -- Full aura info table
    specKey = nil,          -- Spec key for icon lookup
    dropAnchor = nil,       -- Currently hovered anchor name
    moveIndicatorID = nil,  -- Set when re-dragging an existing placed indicator
    indicatorType = nil,    -- "icon" | "square" | "bar" — type to create on drop
}

local dragGhost = nil
local dragUpdateFrame = nil

local function CreateDragGhost()
    if dragGhost then return dragGhost end

    dragGhost = CreateFrame("Frame", "DFAuraDesignerDragGhost", UIParent, "BackdropTemplate")
    dragGhost:SetSize(36, 36)
    dragGhost:SetFrameStrata("TOOLTIP")
    dragGhost:SetFrameLevel(1000)
    dragGhost:EnableMouse(false)  -- KEY: mouse events pass through to drop targets
    dragGhost:Hide()

    if not dragGhost.SetBackdrop then Mixin(dragGhost, BackdropTemplateMixin) end
    dragGhost:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
    })
    dragGhost:SetBackdropColor(0.05, 0.05, 0.05, 0.9)

    -- Spell icon
    local icon = dragGhost:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 3, -3)
    icon:SetPoint("BOTTOMRIGHT", -3, 3)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    dragGhost.icon = icon

    -- Name label under ghost
    local label = dragGhost:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    label:SetPoint("TOP", dragGhost, "BOTTOM", 0, -2)
    label:SetTextColor(1, 1, 1, 0.8)
    dragGhost.label = label

    return dragGhost
end

local EndDrag  -- forward declaration (defined below StartDrag)

local function StartDrag(auraName, auraInfo, specKey, indicatorType)
    if dragState.isDragging then return end

    dragState.isDragging = true
    dragState.auraName = auraName
    dragState.auraInfo = auraInfo
    dragState.specKey = specKey
    dragState.dropAnchor = nil
    dragState.indicatorType = indicatorType or "icon"

    -- Setup ghost
    local ghost = CreateDragGhost()
    local tc = GetThemeColor()
    ghost:SetBackdropBorderColor(tc.r, tc.g, tc.b, 1)

    -- Set icon
    local iconTex = GetAuraIcon(specKey, auraName)
    if iconTex then
        ghost.icon:SetTexture(iconTex)
    else
        ghost.icon:SetColorTexture(auraInfo.color[1] * 0.4, auraInfo.color[2] * 0.4, auraInfo.color[3] * 0.4, 1)
    end
    ghost.label:SetText(auraInfo.display)
    ghost:Show()

    -- Show drag hint
    if dragHintText then
        local tc = GetThemeColor()
        dragHintText:SetText(format(L["Drop on an anchor point to place %s"], auraInfo.display))
        dragHintText:SetTextColor(tc.r, tc.g, tc.b, 0.9)
    end

    -- Show and enlarge all anchor dots to signal they are drop targets
    local dc = GetThemeColor()
    for _, dotFrame in pairs(anchorDots) do
        dotFrame:Show()
        dotFrame.dot:SetSize(10, 10)
        dotFrame.dot:SetColorTexture(dc.r, dc.g, dc.b, 0.5)
    end

    -- Start cursor following
    if not dragUpdateFrame then
        dragUpdateFrame = CreateFrame("Frame")
    end
    dragUpdateFrame:SetScript("OnUpdate", function()
        if not dragState.isDragging then
            dragUpdateFrame:Hide()
            return
        end

        local x, y = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        local cursorX, cursorY = x / scale, y / scale

        -- Offset ghost below-right of cursor so drop target is visible
        ghost:ClearAllPoints()
        ghost:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cursorX + 10, cursorY - 10)

        -- Detect mouse release
        if not IsMouseButtonDown("LeftButton") then
            EndDrag()
        end
    end)
    dragUpdateFrame:Show()
end

-- Start a move-drag for an existing placed indicator.
-- Reuses the same ghost + cursor-following + anchor-dot system as StartDrag.
local function StartMoveDrag(auraName, indicatorID, specKey)
    if dragState.isDragging then return end

    dragState.isDragging = true
    dragState.auraName = auraName
    dragState.moveIndicatorID = indicatorID
    dragState.specKey = specKey
    dragState.dropAnchor = nil

    -- Build minimal auraInfo for hints
    local adDB = GetAuraDesignerDB()
    local displayName = auraName
    if IsOtherTab() then
        -- Other-pool keys are SpellDB names / ad-hoc ids — resolve display live
        displayName = OtherPoolDisplayName(auraName)
    else
        local auraList = Adapter and Adapter:GetTrackableAuras(ResolveSpec())
        if auraList then
            for _, info in ipairs(auraList) do
                if info.name == auraName then
                    dragState.auraInfo = info
                    displayName = info.display or auraName
                    break
                end
            end
        end
    end

    -- Setup ghost
    local ghost = CreateDragGhost()
    local tc = GetThemeColor()
    ghost:SetBackdropBorderColor(tc.r, tc.g, tc.b, 1)

    local iconTex = GetAuraIcon(specKey, auraName)
    if iconTex then
        ghost.icon:SetTexture(iconTex)
    else
        ghost.icon:SetColorTexture(0.3, 0.3, 0.3, 1)
    end
    ghost.label:SetText(displayName)
    ghost:Show()

    -- Show drag hint
    if dragHintText then
        dragHintText:SetText(format(L["Drop on an anchor point to move %s"], displayName))
        dragHintText:SetTextColor(tc.r, tc.g, tc.b, 0.9)
    end

    -- Show and enlarge all anchor dots
    local dc = GetThemeColor()
    for _, dotFrame in pairs(anchorDots) do
        dotFrame:Show()
        dotFrame.dot:SetSize(10, 10)
        dotFrame.dot:SetColorTexture(dc.r, dc.g, dc.b, 0.5)
    end

    -- Start cursor following
    if not dragUpdateFrame then
        dragUpdateFrame = CreateFrame("Frame")
    end
    dragUpdateFrame:SetScript("OnUpdate", function()
        if not dragState.isDragging then
            dragUpdateFrame:Hide()
            return
        end

        local x, y = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        local cursorX, cursorY = x / scale, y / scale

        ghost:ClearAllPoints()
        ghost:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cursorX + 10, cursorY - 10)

        if not IsMouseButtonDown("LeftButton") then
            EndDrag()
        end
    end)
    dragUpdateFrame:Show()
end

EndDrag = function()
    if not dragState.isDragging then return end

    local auraName = dragState.auraName
    local dropAnchor = dragState.dropAnchor
    local moveID = dragState.moveIndicatorID
    local indicatorType = dragState.indicatorType or "icon"

    -- Clear state
    dragState.isDragging = false
    dragState.auraName = nil
    dragState.auraInfo = nil
    dragState.specKey = nil
    dragState.dropAnchor = nil
    dragState.moveIndicatorID = nil
    dragState.indicatorType = nil

    -- Hide ghost
    if dragGhost then dragGhost:Hide() end

    -- Stop cursor following
    if dragUpdateFrame then
        dragUpdateFrame:Hide()
        dragUpdateFrame:SetScript("OnUpdate", nil)
    end

    -- Clear drag hint
    if dragHintText then
        dragHintText:SetText("")
    end

    -- Hide anchor dots (only visible during drag)
    local dc = GetThemeColor()
    for _, dotFrame in pairs(anchorDots) do
        dotFrame:Hide()
        dotFrame.dot:SetSize(6, 6)
        dotFrame.dot:SetColorTexture(dc.r, dc.g, dc.b, 0.3)
    end

    -- Process the drop
    if auraName and dropAnchor then
        if moveID then
            -- Move existing indicator to the new anchor
            local inst = GetIndicatorByID(auraName, moveID)
            if inst then
                inst.anchor = dropAnchor
                inst.offsetX = 0
                inst.offsetY = 0
            end
        else
            -- Create a new indicator instance at the dropped anchor
            local inst = CreateIndicatorInstance(auraName, indicatorType)
            if inst then
                inst.anchor = dropAnchor
            end
        end

        -- Expand the new indicator card in the Effects tab (pool-prefixed key)
        local auraCfg = CurrentAuraPool()[auraName]
        local lastInst = auraCfg and auraCfg.indicators and auraCfg.indicators[#auraCfg.indicators]
        if lastInst then
            local cardKey = "placed:" .. PoolKeyPrefix() .. auraName .. "#" .. lastInst.id
            expandedCards[cardKey] = true
        end
    end

    -- Refresh everything
    DF:AuraDesigner_RefreshPage()
end

-- ============================================================
-- PLACED INDICATORS ON PREVIEW
-- Small icons/squares/bars rendered at anchor positions
-- ============================================================

local placedIndicators = {}

local function ClearPlacedIndicators()
    for _, ind in ipairs(placedIndicators) do
        ind:Hide()
    end
    wipe(placedIndicators)

    -- Clean up AD indicator maps on the mockFrame
    if framePreview and framePreview.mockFrame then
        local mock = framePreview.mockFrame
        if mock.dfADPreviewSlots then
            for _, rec in pairs(mock.dfADPreviewSlots) do rec.slot:Hide() end
        end
        mock.dfAD = nil
    end
end

-- ============================================================
-- NATIVE PREVIEW SLOTS (12.1)
-- Each placed indicator on the canvas is a PREVIEW SLOT: a plain frame
-- styled + painted by the container engine's own styler with the exact
-- config the live factory builds (Factory:BuildPreviewConfig) — the
-- preview IS the live rendering. Slots are pooled per instanceKey and
-- recreated when the structural sig changes (regions are create-only).
-- ============================================================

local function RenderPreviewIndicator(mockFrame, spec, auraName, info, indicator, effectiveConfig, instanceKey)
    local Factory = DF.AuraDesigner and DF.AuraDesigner.Factory
    local AC = DF.AuraContainer
    if not (Factory and Factory.BuildPreviewConfig and AC and AC.StylePreviewSlot) then return nil end

    -- The aura's real spell ID lives in the spell-pool config (the trackable-
    -- aura info entries don't carry IDs) — this drives the previewed icon and
    -- identity, exactly like the live container's filter map.
    local specIDs = DF.AuraDesigner.SpellIDs and DF.AuraDesigner.SpellIDs[spec]
    local spellID = specIDs and specIDs[auraName]
    if type(spellID) == "table" then spellID = spellID[1] end
    if not spellID then
        -- Ad-hoc "#<id>" keys resolve directly — mirror BuildADIdentityFilters
        spellID = AdHocSpellID(auraName)
    end
    if not spellID then
        -- SpellDB fallback (all-spec support) — mirror BuildADIdentityFilters
        local R = DF.FilterRegistry
        local rec = R and R.GetSpellByName and R:GetSpellByName(auraName)
        spellID = rec and rec.id
    end
    local cfg, sig = Factory:BuildPreviewConfig(mockFrame, effectiveConfig, indicator.type or "icon", spellID)
    if not (cfg.testEntries and cfg.testEntries[1]) then
        -- No resolvable spell ID: synthesize an entry from the configured art so
        -- the paint can never fall back to the generic curated pool.
        cfg.testEntries = { { name = (info and info.display) or auraName } }
    end
    do
        local e = cfg.testEntries[1]
        if not e.icon then e.icon = GetAuraIcon(spec, auraName) end
        e.duration = 15
        e.stacks = (indicator.type ~= "bar") and 3 or 0
    end

    local store = mockFrame.dfADPreviewSlots
    if not store then store = {}; mockFrame.dfADPreviewSlots = store end
    local rec = store[instanceKey]
    if rec and rec.sig ~= sig then
        rec.slot:Hide()
        rec = nil
    end
    if not rec then
        rec = { slot = CreateFrame("Frame", nil, mockFrame), sig = sig }
        store[instanceKey] = rec
    end
    local slot = rec.slot
    AC.StylePreviewSlot(slot, cfg)

    local lay = cfg.layout or {}
    if lay.sizeX then
        slot:SetSize(lay.sizeX, lay.sizeY or lay.sizeX)
    else
        local s = lay.size or 24
        slot:SetSize(s, s)
    end
    slot:SetScale(lay.scale or 1)
    slot:ClearAllPoints()
    slot:SetPoint(lay.anchor or "TOPLEFT", mockFrame, lay.anchor or "TOPLEFT", lay.offsetX or 0, lay.offsetY or 0)
    slot:SetFrameStrata(mockFrame:GetFrameStrata())
    slot:SetFrameLevel(mockFrame:GetFrameLevel() + 8)
    AC.PaintPreviewSlot(slot, cfg, 1)
    slot:Show()
    return slot
end

local function WirePreviewIndicator(slot, capturedAura, capturedID, spec)
    slot:EnableMouse(true)
    if slot.SetMouseClickEnabled then slot:SetMouseClickEnabled(true) end
    slot:SetScript("OnMouseUp", function(_, button)
        if dragState.isDragging then return end
        if button == "RightButton" then
            -- Don't delete grouped indicators (managed by layout group)
            if not GetIndicatorLayoutGroup(capturedAura, capturedID) then
                RemoveIndicatorInstance(capturedAura, capturedID)
                DF:AuraDesigner_RefreshPage()
                -- Structural change: same full refresh as the effect-card ✕ —
                -- the container must rebuild and the buff-row dedup union
                -- shrinks (deleted = no longer tracked).
                DF:InvalidateAuraLayout()
                DF:UpdateAllFrames()
                if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end
            end
        elseif button == "LeftButton" then
            -- Collapse all cards and expand only the clicked one. The preview
            -- renders the ACTIVE tab's pool only, so PoolKeyPrefix() at click
            -- time matches the slot's pool (B1 key scheme).
            local cardKey = "placed:" .. PoolKeyPrefix() .. capturedAura .. "#" .. capturedID
            wipe(expandedCards)
            expandedCards[cardKey] = true
            activeTab = "effects"
            DF:AuraDesigner_RefreshPage()
        end
    end)
    slot:RegisterForDrag("LeftButton")
    slot:SetScript("OnDragStart", function()
        -- Don't drag grouped indicators (position managed by layout group)
        if GetIndicatorLayoutGroup(capturedAura, capturedID) then return end
        StartMoveDrag(capturedAura, capturedID, spec)
    end)
end

-- Representative preview icons per debuff category. Category membership is
-- Blizzard-secret at runtime, so the editor shows iconic stand-ins instead of
-- real members. Entry encoding: NEGATIVE numbers are spell IDs (icon resolved
-- live via C_Spell.GetSpellTexture — all evergreen player abilities, so they
-- stay valid across patches); positive numbers would be literal texture
-- FileDataIDs; strings are texture paths. Never shown as live auras — the
-- placeholder desaturates them (example affordance).
local DEBUFF_CATEGORY_SAMPLES = {
    boss         = { "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8", -348 },   -- skull marker, Immolate
    role         = { -6343, -113746 },        -- Thunder Clap, Mystic Touch
    priority     = { -980, -34914 },          -- Agony, Vampiric Touch
    crowdControl = { -118, -6770, -5782 },    -- Polymorph, Sap, Fear
    raid         = { -589, -1943 },           -- Shadow Word: Pain, Rupture
    dispellable  = { -339, -51514 },          -- Entangling Roots, Hex
    _order = { "boss", "role", "priority", "crowdControl", "raid", "dispellable" },
}

-- Example icons for a container-backed group's placeholder block, or nil when
-- the group has nothing to sample (caller falls back to the outline-only
-- style). maxDefault mirrors the DrawGroupPlaceholderSlot default so both
-- compute the same slot count.
-- * Filter groups: sample REAL spells from the linked filters — resolve the
--   selection (same R:ResolveSelection the factory uses; preview-path only,
--   so no cache needed) and take the first N canonical ids in sorted order
--   (deterministic — the preview is stable across refreshes). An empty or
--   dangling selection resolves to kind "all" / an empty map → nil.
-- * Debuff groups (records carry .selection): cycle the selected categories'
--   representative samples across all N slots in _order.
local function GroupSampleIcons(group, maxDefault)
    local n = max(1, tonumber(group.maxIcons) or maxDefault)
    local icons = {}
    if group.selection then
        -- Debuff category group: round-robin the selected categories
        local cats = {}
        for _, key in ipairs(DEBUFF_CATEGORY_SAMPLES._order) do
            if group.selection[key] then tinsert(cats, DEBUFF_CATEGORY_SAMPLES[key]) end
        end
        if #cats == 0 then return nil end
        for i = 1, n do
            local samples = cats[(i - 1) % #cats + 1]
            local entry = samples[(floor((i - 1) / #cats) % #samples) + 1]
            if type(entry) == "number" and entry < 0 then
                entry = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(-entry)) or 134400
            end
            icons[i] = entry
        end
        return icons
    end
    if group.kind ~= "filter" then return nil end
    local R = DF.FilterRegistry
    if not R then return nil end
    local res = R:ResolveSelection(group.filterSelection, false)
    if res.kind == "all" then return nil end -- empty/dangling selection
    -- Canonical ids: variant/alt ids collapse onto their record's id; raw ids
    -- from custom filters (no registry record) sample as themselves.
    local ids, seen = {}, {}
    if res.kind == "include" then
        for id in pairs(res.map) do
            local rec = R.ByID and R.ByID[id]
            local cid = rec and rec.id or id
            if not seen[cid] then seen[cid] = true; tinsert(ids, cid) end
        end
    else -- "exclude" (Uncategorised): complement of the known registry
        for _, rec in ipairs(R.Spells) do
            if not res.map[rec.id] then tinsert(ids, rec.id) end
        end
    end
    if #ids == 0 then return nil end
    sort(ids)
    for i = 1, min(n, #ids) do
        local rec = R.ByID and R.ByID[ids[i]]
        if rec then
            local _, icon = R:GetSpellDisplay(rec)
            icons[i] = icon
        else
            icons[i] = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(ids[i])) or 134400
        end
    end
    return icons
end

-- Shared labeled-outline placeholder for container-backed groups (filter
-- groups on My Buffs, debuff category groups on Debuffs): their contents are
-- Blizzard-filled at runtime (secret visibility, registry/category-driven),
-- so the editor canvas can't preview real member icons. Draw an outline block
-- at the group's anchor/offset sized to its footprint (iconSize ×
-- min(maxIcons, iconsPerRow) columns, wrapped rows), filled with EXAMPLE
-- icons (`icons` array from GroupSampleIcons; nil/empty = outline only) so
-- size/spacing/grow/per-row edits are visible. Pooled per group id in the
-- caller's pool table (separate pools — the two id counters can collide);
-- returns the slot for the placedIndicators list.
local function DrawGroupPlaceholderSlot(mockFrame, pool, group, wrapDefault, maxDefault, icons)
    local slot = pool[group.id]
    if not slot then
        slot = CreateFrame("Frame", nil, mockFrame, "BackdropTemplate")
        -- The group-name label rides its own high-level child so it stays
        -- legible above the sample FRAMES below (a parent's own regions
        -- would draw underneath child frames regardless of layer).
        slot.labelHost = CreateFrame("Frame", nil, slot)
        slot.labelHost:SetAllPoints(slot)
        slot.label = slot.labelHost:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(slot.label, 8, "OUTLINE")
        slot.label:SetPoint("CENTER", 0, 0)
        pool[group.id] = slot
    end
    local iconSize = max(8, tonumber(group.iconSize) or 24)
    local maxIcons = max(1, tonumber(group.maxIcons) or maxDefault)
    local wrap = max(1, tonumber(group.iconsPerRow) or wrapDefault)
    local spacing = tonumber(group.spacing) or 2
    local cols = min(maxIcons, wrap)
    local rows = floor((maxIcons - 1) / wrap) + 1
    slot:SetSize(max(cols * iconSize + (cols - 1) * spacing, 10),
                 max(rows * iconSize + (rows - 1) * spacing, 10))
    ApplyBackdrop(slot, {r = 0.91, g = 0.66, b = 0.25, a = 0.10},
        {r = 0.91, g = 0.66, b = 0.25, a = 0.8})
    slot.label:SetText(group.name)
    slot.label:SetTextColor(0.91, 0.66, 0.25)
    slot.label:SetWidth(slot:GetWidth() - 4)
    slot.label:SetMaxLines(2)
    -- Pin the block's grow-corner at the group's anchor point so it
    -- extends in the grow direction (mirror the container's flow origin).
    local p, s = strsplit("_", group.growDirection or "RIGHT_DOWN")
    local vert, horiz = "TOP", "LEFT"
    for _, d in ipairs({ p, s }) do
        if d == "UP" then vert = "BOTTOM"
        elseif d == "DOWN" then vert = "TOP"
        elseif d == "LEFT" then horiz = "RIGHT"
        elseif d == "RIGHT" then horiz = "LEFT"
        elseif d == "CENTER" then horiz = "" end
    end
    local selfPoint = (horiz == "") and vert or (vert .. horiz)
    slot:ClearAllPoints()
    slot:SetPoint(selfPoint, mockFrame, group.anchor or "TOPLEFT",
        group.offsetX or 0, group.offsetY or 0)
    slot:SetFrameStrata(mockFrame:GetFrameStrata())
    slot:SetFrameLevel(mockFrame:GetFrameLevel() + 8)
    -- Above the sample frames' text holders (slot+1 base + duration/stack
    -- holder offsets) and border art, so the group name always reads.
    slot.labelHost:SetFrameLevel(slot:GetFrameLevel() + 15)

    -- EXAMPLE ICONS inside the block geometry (nil icons = outline only).
    -- Each sample is a pooled child FRAME styled + painted by the factory's
    -- own preview pipeline (Factory:BuildGroupPreviewConfig from group.style →
    -- AuraContainer.StylePreviewSlot/PaintPreviewSlot — the exact path the
    -- placed indicators' canvas preview uses), so the group's Appearance
    -- settings (border incl. animation, cooldown swipe, duration text with
    -- colour-by-time/hide-above, stack count) render on the samples. Regions
    -- are create-only (the live Rebuild rule): when the structural sig moves
    -- (duration/stacks/border on-off, format key), drop the pool and
    -- re-create — same recreate-on-sig idiom as RenderPreviewIndicator.
    -- Fully rebound both directions: a group whose samples empty out
    -- (filters unlinked, categories deselected) returns to the bare outline
    -- (extras hidden), and vice versa. Icons fill the block's grid from its
    -- pinned grow-corner (centered rows when the primary direction is
    -- CENTER), so grow/wrap edits read directionally. Desaturation is the
    -- "example, not live" affordance; style-less groups render through the
    -- same pipeline with the default style (= today's live rendering).
    local Factory = DF.AuraDesigner and DF.AuraDesigner.Factory
    local AC = DF.AuraContainer
    local cfg, sig
    if icons and Factory and Factory.BuildGroupPreviewConfig and AC and AC.StylePreviewSlot then
        cfg, sig = Factory:BuildGroupPreviewConfig(mockFrame, group)
    end
    local framePool = slot.sampleFrames
    if framePool and slot.sampleSig ~= sig then
        -- Structural style change: abandon the old frames (hidden — the
        -- RenderPreviewIndicator idiom; regions can't be removed in place).
        for i = 1, #framePool do framePool[i]:Hide() end
        framePool = nil
        slot.sampleFrames = nil
    end
    slot.sampleSig = sig
    if not framePool then framePool = {}; slot.sampleFrames = framePool end
    local count = (cfg and icons) and min(#icons, maxIcons) or 0
    if count > 0 then
        -- Curated per-slot entries: the sample's art plus a static duration/
        -- stack sample (the paint staggers the countdown per index and runs
        -- it through the group's own formatter — colour-by-time buckets and
        -- the hide-above blank band mirror live).
        local entries = {}
        for i = 1, count do
            entries[i] = { icon = icons[i], duration = 15, stacks = 3 }
        end
        cfg.testEntries = entries
    end
    local step = iconSize + spacing
    local xSign = (horiz == "RIGHT") and -1 or 1
    local ySign = (vert == "TOP") and -1 or 1
    for i = 1, count do
        local f = framePool[i]
        if not f then
            f = CreateFrame("Frame", nil, slot)
            framePool[i] = f
        end
        AC.StylePreviewSlot(f, cfg)   -- sizes the frame from cfg.layout.size (= iconSize)
        f:ClearAllPoints()
        local col = (i - 1) % wrap
        local row = floor((i - 1) / wrap)
        if horiz == "" then
            -- CENTER primary: rows centered on the block's vert edge
            local lastRow = floor((count - 1) / wrap)
            local iconsInRow = (row == lastRow) and (((count - 1) % wrap) + 1) or wrap
            f:SetPoint(vert, slot, vert,
                (col - (iconsInRow - 1) / 2) * step, ySign * row * step)
        else
            local corner = vert .. horiz
            f:SetPoint(corner, slot, corner, xSign * col * step, ySign * row * step)
        end
        AC.PaintPreviewSlot(f, cfg, i)
        if f.dfIcon then f.dfIcon:SetDesaturated(true) end -- example affordance
        f:Show()
    end
    for i = count + 1, #framePool do framePool[i]:Hide() end

    slot:Show()
    return slot
end

local function RefreshPlacedIndicators()
    ClearPlacedIndicators()
    if not framePreview then return end

    local mockFrame = framePreview.mockFrame
    if not mockFrame then return end

    local adDB = GetAuraDesignerDB()
    local isOther = IsOtherTab()
    local isDebuffs = IsDebuffTab()
    local spec = ResolveSpec()
    -- Other Buffs and the Debuffs tab are spec-independent: render even with
    -- no resolvable spec.
    if not spec and not (isOther or isDebuffs) then return end

    local auraList = (not isOther and not isDebuffs) and spec and Adapter and Adapter:GetTrackableAuras(spec) or nil
    if not auraList and not (isOther or isDebuffs) then return end

    -- Build lookup
    local infoLookup = {}
    if auraList then
        for _, info in ipairs(auraList) do
            infoLookup[info.name] = info
        end
    end


    -- Build layout group position lookup for preview
    -- In preview all indicators are visible, so compute positions for all members.
    -- The preview renders the ACTIVE tab's pool, so the group pass reads the
    -- active tab's group store (spec-keyed on My Buffs, the flat other store on
    -- Other Buffs — read-only, never creates it); Debuffs has neither. Keys carry
    -- the B1 pool prefix so they line up with the instanceKeys built below.
    local keyPrefix = PoolKeyPrefix()
    local groupPositions = {}  -- "<prefix>auraName#indicatorID" → { anchor, offsetX, offsetY }
    local specGroups = isDebuffs and EMPTY_POOL or CurrentLayoutGroups()
    for _, group in ipairs(specGroups) do
        if group.members then
            for memberIdx, member in ipairs(group.members) do
                local key = keyPrefix .. member.auraName .. "#" .. member.indicatorID
                -- Compute position based on group settings
                local activeIdx = memberIdx - 1  -- 0-based
                -- Need to find the indicator's size to compute step (members
                -- live in the same pool as their group — the active pool)
                local memberCfg = CurrentAuraPool(spec)[member.auraName]
                    local indCfg = nil
                    if memberCfg and memberCfg.indicators then
                        for _, ind in ipairs(memberCfg.indicators) do
                            if ind.id == member.indicatorID then
                                indCfg = ind
                                break
                            end
                        end
                    end
                    local size = (indCfg and indCfg.size) or (adDB.defaults and adDB.defaults.iconSize) or 24
                    local scale = (indCfg and indCfg.scale) or (adDB.defaults and adDB.defaults.iconScale) or 1.0
                    local step = (size * scale) + (group.spacing or 2)

                    local growth = group.growDirection or "RIGHT"
                    local primary, secondary = strsplit("_", growth)
                    if not secondary then
                        secondary = (primary == "RIGHT" or primary == "LEFT") and "DOWN" or "RIGHT"
                    end
                    local wrap = group.iconsPerRow or 8
                    if wrap <= 0 then wrap = 1 end
                    local totalCount = #group.members
                    local col = activeIdx % wrap
                    local row = floor(activeIdx / wrap)
                    local function gOff(d, s)
                        if d == "LEFT" then return -s, 0 elseif d == "RIGHT" then return s, 0
                        elseif d == "UP" then return 0, s elseif d == "DOWN" then return 0, -s end
                        return 0, 0
                    end
                    local sX, sY = gOff(secondary, step)
                    local oX, oY
                    if primary == "CENTER" then
                        local iconsInRow = wrap
                        local lastRow = floor((totalCount - 1) / wrap)
                        if row == lastRow then
                            iconsInRow = ((totalCount - 1) % wrap) + 1
                        end
                        local centerOff = -((iconsInRow - 1) * step) / 2
                        if sX ~= 0 then
                            oX = (group.offsetX or 0) + (row * sX)
                            oY = (group.offsetY or 0) + centerOff + (col * step)
                        else
                            oX = (group.offsetX or 0) + centerOff + (col * step)
                            oY = (group.offsetY or 0) + (row * sY)
                        end
                    else
                        local pX, pY = gOff(primary, step)
                        oX = (group.offsetX or 0) + (col * pX) + (row * sX)
                        oY = (group.offsetY or 0) + (col * pY) + (row * sY)
                    end
                    groupPositions[key] = {
                        anchor = group.anchor or "TOPLEFT",
                        offsetX = oX,
                        offsetY = oY,
                    }
                end
            end
        end

    -- FILTER GROUP PLACEHOLDERS (My Buffs / Other Buffs): labeled outline
    -- blocks via the shared helper above. Pooled per group id — SEPARATE pool
    -- table per tab (the two id counters can collide, mirror the dgroup pool);
    -- eye-hidden groups draw nothing. Wrap/max defaults 8 match the classic
    -- member-group layout.
    do
        local fgPoolKey = isOther and "dfADOtherFilterGroupSlots" or "dfADFilterGroupSlots"
        local fgPool = mockFrame[fgPoolKey]
        if not fgPool then fgPool = {}; mockFrame[fgPoolKey] = fgPool end
        for _, group in ipairs(specGroups) do
            if group.kind == "filter" and group.enabled ~= false then
                tinsert(placedIndicators,
                    DrawGroupPlaceholderSlot(mockFrame, fgPool, group, 8, 8,
                        GroupSampleIcons(group, 8)))
            end
        end
    end

    -- DEBUFF GROUP PLACEHOLDERS (C2): Debuffs tab only — the preview renders
    -- the ACTIVE tab's surfaces, so these blocks never mix with the buff
    -- pools' indicators. Separate pool table (dgroup ids come from their own
    -- counter and could collide with filter-group ids). Wrap/max defaults 4
    -- mirror CreateDebuffGroup and the factory's buildFilterGroupLayout(_, 4).
    -- Read-only: visiting the tab must not create adDB.debuffGroups.
    if isDebuffs then
        local dgPool = mockFrame.dfADDebuffGroupSlots
        if not dgPool then dgPool = {}; mockFrame.dfADDebuffGroupSlots = dgPool end
        for _, group in ipairs(DebuffGroupsRead()) do
            if group.enabled ~= false then
                tinsert(placedIndicators,
                    DrawGroupPlaceholderSlot(mockFrame, dgPool, group, 4, 4,
                        GroupSampleIcons(group, 4)))
            end
        end
    end

    -- Iterate all configured auras, find placed indicator instances.
    -- Ad-hoc "#<id>" auras are never in the trackable pool — render them with
    -- info=nil (RenderPreviewIndicator resolves their id/icon by pattern).
    -- Other-pool records render with info=nil + nil identity spec (SpellDB /
    -- ad-hoc resolution, mirroring the factory). Slot keys carry the B1
    -- "other:" prefix so the two pools' slots can't collide in the store.
    -- Hidden indicators (eye toggle, enabled == false) don't render — same as live.
    -- (keyPrefix hoisted above the group-position pass — same value.)
    local idSpec = isOther and nil or spec
    for auraName, auraCfg in pairs(CurrentAuraPool(spec)) do
        local info = infoLookup[auraName]
        if type(auraCfg) == "table" and (isOther or info or AdHocSpellID(auraName)) and auraCfg.indicators then
            for _, indicator in ipairs(auraCfg.indicators) do
              if indicator.enabled ~= false then
                local instanceKey = keyPrefix .. auraName .. "#" .. indicator.id
                local capturedAura = auraName
                local capturedID = indicator.id

                -- Apply layout group position override if applicable
                local effectiveConfig = indicator
                local gPos = groupPositions[instanceKey]
                if gPos then
                    effectiveConfig = setmetatable({
                        anchor = gPos.anchor,
                        offsetX = gPos.offsetX,
                        offsetY = gPos.offsetY,
                    }, { __index = indicator })
                end

                local slot = RenderPreviewIndicator(mockFrame, idSpec, auraName, info, indicator, effectiveConfig, instanceKey)
                if slot then
                    WirePreviewIndicator(slot, capturedAura, capturedID, idSpec)
                    tinsert(placedIndicators, slot)
                end
              end
            end
        end
    end
end

-- ============================================================
-- PREVIEW EFFECTS
-- Apply frame-level effects (border, healthbar, text, alpha)
-- for the currently selected aura on the mock frame
-- ============================================================

local function GetOrCreatePreviewCustomBorder(mockFrame, key)
    if not mockFrame.dfPreviewCustomBorders then
        mockFrame.dfPreviewCustomBorders = {}
    end
    local pool = mockFrame.dfPreviewCustomBorders
    if pool[key] then return pool[key] end
    -- Stage 5.4: preview uses DF.Border (mirrors the runtime), below the
    -- shared preview border (+5).
    pool[key] = DF.Border:New(mockFrame, { frameLevelOffset = 4, layer = "OVERLAY" })
    return pool[key]
end

local function RefreshPreviewEffects()
    if not framePreview then return end
    local mockFrame = framePreview.mockFrame
    if not mockFrame then return end

    -- Reset shared border overlay (Stage 5.4: DF.Border — hide edges + anim)
    if framePreview.borderOverlay then
        DF.Border:Apply(framePreview.borderOverlay, { enabled = false })
    end
    -- Reset custom border overlays
    if mockFrame.dfPreviewCustomBorders then
        for _, ch in pairs(mockFrame.dfPreviewCustomBorders) do
            DF.Border:Apply(ch, { enabled = false })
        end
    end
    if framePreview.healthFill then
        framePreview.healthFill:SetVertexColor(0.18, 0.80, 0.44, 0.85)
    end
    if framePreview.nameText then
        framePreview.nameText:SetTextColor(0.18, 0.80, 0.44, 1)
    end
    if framePreview.hpText then
        framePreview.hpText:SetTextColor(0.87, 0.87, 0.87, 1)
    end
    mockFrame:SetAlpha(1)
    -- Reset the shared single-target elements to their defaults ONCE, before any
    -- aura's effects are applied. Previously the background's reset lived in an
    -- in-loop `elseif`, so a background-less aura could wipe an earlier aura's
    -- background depending on pairs() iteration order — the intermittent
    -- "doesn't show on preview" report for Background / Health Bar Color.
    if framePreview.healthBg then
        framePreview.healthBg:SetColorTexture(0, 0, 0, 0.4)
    end
    if framePreview.missingHealth then
        framePreview.missingHealth:SetColorTexture(0, 0, 0, 0.4)
    end

    -- Frame-level effects all draw onto the SAME single preview elements (one
    -- healthFill / healthBg / nameText / etc.), so when more than one aura
    -- configures the same type they conflict. The runtime resolves this by
    -- priority (higher number wins; first claim per type — see prioritySort and
    -- Indicators:Apply's `if state.X then return end`). Mirror that here so the
    -- preview is deterministic instead of pairs()-order-dependent: iterate auras
    -- in descending-priority order (tiebreak by name) and apply first-wins per type.
    local sortedAuras = {}
    for auraName, auraCfg in pairs(CurrentAuraPool()) do
        if type(auraCfg) == "table" then  -- skip corrupted entries
            sortedAuras[#sortedAuras + 1] = { name = auraName, cfg = auraCfg, priority = auraCfg.priority or 5 }
        end
    end
    sort(sortedAuras, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end  -- higher number = higher priority
        return a.name < b.name
    end)

    local claimed = {}
    for _, entry in ipairs(sortedAuras) do
    local auraName, auraCfg = entry.name, entry.cfg

    -- Border effect (Stage 5.4: rendered via DF.Border, mirroring the runtime).
    -- Shared borders use a single overlay (first/highest-priority claim wins);
    -- custom borders get independent per-aura overlays so multiple can stack.
    -- Every type skips hidden blocks (eye toggle, enabled == false) — same as pickWinner.
    if auraCfg.border and auraCfg.border.enabled ~= false and auraCfg.border.ShowBorder ~= false then
        local spec = DF.Border:BuildSpec(auraCfg.border, "")
        if not spec.color then spec.color = { r = 1, g = 1, b = 1, a = 1 } end
        spec.enabled = true
        if auraCfg.border.borderMode == "custom" then
            DF.Border:Apply(GetOrCreatePreviewCustomBorder(mockFrame, auraName), spec)
        elseif not claimed.border and framePreview.borderOverlay then
            claimed.border = true
            DF.Border:Apply(framePreview.borderOverlay, spec)
        end
    end

    -- Health bar color (first claim wins)
    if not claimed.healthbar and auraCfg.healthbar and auraCfg.healthbar.enabled ~= false and framePreview.healthFill then
        claimed.healthbar = true
        local clr = auraCfg.healthbar.color or {r = 1, g = 1, b = 1, a = 1}
        local blend = auraCfg.healthbar.blend or 0.5
        if auraCfg.healthbar.mode == "Replace" then
            framePreview.healthFill:SetVertexColor(clr.r, clr.g, clr.b, clr.a or 1)
        else
            -- Tint: blend original green with the configured color, scaled by alpha
            -- so dragging the colour picker's alpha visibly weakens the tint
            -- (matches ApplyHealthBar in Indicators.lua: overlay = blend × alpha).
            local effBlend = blend * (clr.a or 1)
            local r = 0.18 * (1 - effBlend) + clr.r * effBlend
            local g = 0.80 * (1 - effBlend) + clr.g * effBlend
            local b = 0.44 * (1 - effBlend) + clr.b * effBlend
            framePreview.healthFill:SetVertexColor(r, g, b, 1)
            -- Tint Entire Bar: paint the same tint hue over the (dark) missing-
            -- health region so the preview shows the colour spanning the full bar.
            if auraCfg.healthbar.tintWholeBar and framePreview.missingHealth then
                framePreview.missingHealth:SetColorTexture(clr.r * effBlend, clr.g * effBlend, clr.b * effBlend, 0.4 + 0.25 * effBlend)
            end
        end
    end

    -- Background color (first claim wins). Recolours the frame background — shows
    -- through the missing-health area, like the runtime overlay behind the bars.
    if not claimed.background and auraCfg.background and auraCfg.background.enabled ~= false and framePreview.healthBg then
        claimed.background = true
        local clr = auraCfg.background.color or {r = 1, g = 1, b = 1, a = 1}
        if auraCfg.background.mode == "Replace" then
            local a = clr.a or 1
            framePreview.healthBg:SetColorTexture(clr.r, clr.g, clr.b, 0.4 + 0.6 * a)
        else
            local blend = (auraCfg.background.blend or 0.5) * (clr.a or 1)
            -- Blend the configured colour over the dark default background.
            framePreview.healthBg:SetColorTexture(clr.r * blend, clr.g * blend, clr.b * blend, 0.4 + 0.4 * blend)
        end
    end

    -- Name text color (first claim wins)
    if not claimed.nametext and auraCfg.nametext and auraCfg.nametext.enabled ~= false and framePreview.nameText then
        claimed.nametext = true
        local clr = auraCfg.nametext.color or {r = 1, g = 1, b = 1, a = 1}
        framePreview.nameText:SetTextColor(clr.r, clr.g, clr.b, clr.a or 1)
    end

    -- Health text color (first claim wins)
    if not claimed.healthtext and auraCfg.healthtext and auraCfg.healthtext.enabled ~= false and framePreview.hpText then
        claimed.healthtext = true
        local clr = auraCfg.healthtext.color or {r = 1, g = 1, b = 1, a = 1}
        framePreview.hpText:SetTextColor(clr.r, clr.g, clr.b, clr.a or 1)
    end

    -- Frame alpha (first claim wins)
    if not claimed.framealpha and auraCfg.framealpha and auraCfg.framealpha.enabled ~= false then
        claimed.framealpha = true
        mockFrame:SetAlpha(auraCfg.framealpha.alpha or 0.5)
    end

    end  -- for _, entry in sortedAuras
end

-- ============================================================
-- LIGHTWEIGHT PREVIEW REFRESH
-- Re-applies indicator settings to existing preview frames without
-- destroying/recreating them. Called from proxy __newindex so every
-- slider drag tick, checkbox toggle, or dropdown change is live.
-- ============================================================

RefreshPreviewLightweight = function()
    if not framePreview or not framePreview.mockFrame then return end
    local mockFrame = framePreview.mockFrame

    local adDB = GetAuraDesignerDB()
    local isOther = IsOtherTab()
    local isDebuffs = IsDebuffTab()
    local spec = ResolveSpec()
    if not spec and not (isOther or isDebuffs) then return end

    -- Build layout group position lookup (same as RefreshPlacedIndicators:
    -- active tab's group store over the active pool, pool-prefixed keys;
    -- Debuffs has no member groups so the pass reads empty there)
    local keyPrefix = PoolKeyPrefix()
    local groupPositions = {}
    local specGroups2 = isDebuffs and EMPTY_POOL or CurrentLayoutGroups()
    for _, group in ipairs(specGroups2) do
        if group.members then
            for memberIdx, member in ipairs(group.members) do
                local key = keyPrefix .. member.auraName .. "#" .. member.indicatorID
                local activeIdx = memberIdx - 1
                local memberCfg = CurrentAuraPool(spec)[member.auraName]
                local indCfg = nil
                if memberCfg and memberCfg.indicators then
                    for _, ind in ipairs(memberCfg.indicators) do
                        if ind.id == member.indicatorID then indCfg = ind; break end
                    end
                end
                local size = (indCfg and indCfg.size) or (adDB.defaults and adDB.defaults.iconSize) or 24
                local scale = (indCfg and indCfg.scale) or (adDB.defaults and adDB.defaults.iconScale) or 1.0
                local step = (size * scale) + (group.spacing or 2)
                -- Grid-aware layout matching RefreshPlacedIndicators / ComputeGroupOffset
                local growth = group.growDirection or "RIGHT"
                local primary, secondary = strsplit("_", growth)
                if not secondary then
                    secondary = (primary == "RIGHT" or primary == "LEFT") and "DOWN" or "RIGHT"
                end
                local wrap = group.iconsPerRow or 8
                if wrap <= 0 then wrap = 1 end
                local totalCount = #group.members
                local col = activeIdx % wrap
                local row = floor(activeIdx / wrap)
                local function gOff(d, s)
                    if d == "LEFT" then return -s, 0 elseif d == "RIGHT" then return s, 0
                    elseif d == "UP" then return 0, s elseif d == "DOWN" then return 0, -s end
                    return 0, 0
                end
                local sX, sY = gOff(secondary, step)
                local oX, oY
                if primary == "CENTER" then
                    local iconsInRow = wrap
                    local lastRow = floor((totalCount - 1) / wrap)
                    if row == lastRow then
                        iconsInRow = ((totalCount - 1) % wrap) + 1
                    end
                    local centerOff = -((iconsInRow - 1) * step) / 2
                    if sX ~= 0 then
                        oX = (group.offsetX or 0) + (row * sX)
                        oY = (group.offsetY or 0) + centerOff + (col * step)
                    else
                        oX = (group.offsetX or 0) + centerOff + (col * step)
                        oY = (group.offsetY or 0) + (row * sY)
                    end
                else
                    local pX, pY = gOff(primary, step)
                    oX = (group.offsetX or 0) + (col * pX) + (row * sX)
                    oY = (group.offsetY or 0) + (col * pY) + (row * sY)
                end
                groupPositions[key] = { anchor = group.anchor or "TOPLEFT", offsetX = oX, offsetY = oY }
            end
        end
    end

    -- Re-apply placed indicator instances using current settings
    -- (hidden indicators skipped — RenderPreviewIndicator would resurrect their
    -- slot; keyPrefix hoisted above the group-position pass — same value)
    local idSpec = isOther and nil or spec
    for auraName, auraCfg in pairs(CurrentAuraPool(spec)) do
        if type(auraCfg) == "table" and auraCfg.indicators then
            for _, indicator in ipairs(auraCfg.indicators) do
              if indicator.enabled ~= false then
                local instanceKey = keyPrefix .. auraName .. "#" .. indicator.id

                -- Apply layout group position override if applicable
                local effectiveConfig = indicator
                local gPos = groupPositions[instanceKey]
                if gPos then
                    effectiveConfig = setmetatable({
                        anchor = gPos.anchor, offsetX = gPos.offsetX, offsetY = gPos.offsetY,
                    }, { __index = indicator })
                end

                -- Restyle/repaint through the shared preview slot (recreated only
                -- when the structural sig changes; cosmetic changes restyle in place).
                local infoLW = nil
                if not isOther and Adapter and Adapter.GetTrackableAuras then
                    for _, ti in ipairs(Adapter:GetTrackableAuras(spec)) do
                        if ti.name == auraName then infoLW = ti; break end
                    end
                end
                local slot = RenderPreviewIndicator(mockFrame, idSpec, auraName, infoLW, indicator, effectiveConfig, instanceKey)
                if slot then
                    WirePreviewIndicator(slot, auraName, indicator.id, idSpec)
                end
              end
            end
        end
    end

    -- Also refresh frame-level preview effects (border, healthbar color, text colors, alpha)
    RefreshPreviewEffects()
end

-- ============================================================
-- INDICATOR TYPE WIDGET BUILDER
-- (Tile strip removed in v4 redesign)
-- ============================================================

-- Build the widget content for a given indicator type
-- optProxy: optional proxy table; if nil, creates one via CreateProxy (frame-level types)
-- yOffset: optional vertical offset to start content below other elements (e.g. trigger tags)
-- Helper: create expiring threshold slider with percent/seconds mode toggle
local function CreateExpiringThresholdRow(parent, proxy, width)
    local isSeconds = proxy.expiringThresholdMode == "SECONDS"
    local container = CreateFrame("Frame", nil, parent)
    container:SetHeight(54)
    container:SetWidth(width or 248)

    -- Slider: range depends on mode
    local label, minV, maxV, step
    if isSeconds then
        label = L["Expiring Threshold (seconds)"]
        minV, maxV, step = 1, 60, 1
        -- Clamp value to seconds range if switching from percent
        local cur = proxy.expiringThreshold
        if cur and cur > 60 then proxy.expiringThreshold = 10 end
    else
        label = L["Expiring Threshold (%)"]
        minV, maxV, step = 5, 100, 5
        -- Clamp value to percent range if switching from seconds
        local cur = proxy.expiringThreshold
        if cur and cur < 5 then proxy.expiringThreshold = 30 end
    end

    local slider = GUI:CreateSlider(container, label, minV, maxV, step, proxy, "expiringThreshold")
    slider:SetPoint("TOPLEFT", 0, 0)
    slider:SetWidth(width or 248)

    -- Mode toggle button (above the slider label, top-right)
    local modeBtn = CreateFrame("Button", nil, container, "BackdropTemplate")
    modeBtn:SetSize(56, 18)
    modeBtn:SetPoint("BOTTOMRIGHT", slider, "TOPRIGHT", -10, 2)

    local modeText = modeBtn:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(modeText, 9, "")
    modeText:SetPoint("CENTER", 0, 0)
    modeText:SetText(isSeconds and L["Seconds"] or L["Percent"])
    modeText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    -- Shared styler (rest + accent-wash hover). It's a two-state toggle whose
    -- label shows the current mode; mark active when on Seconds so the engaged
    -- state reads via the shared accent border (page rebuilds on click).
    GUI:StyleButton(modeBtn)
    modeBtn:SetActive(isSeconds)

    modeBtn:HookScript("OnEnter", function(self)
        GUI:ShowTooltip(self, {
            title = L["Threshold Mode"],
            lines = {
                isSeconds and L["Currently: Seconds. Click for Percent."] or L["Currently: Percent. Click for Seconds."],
            },
        })
    end)
    modeBtn:HookScript("OnLeave", function()
        GUI:HideTooltip()
    end)
    modeBtn:SetScript("OnClick", function()
        if proxy.expiringThresholdMode == "SECONDS" then
            proxy.expiringThresholdMode = "PERCENT"
            proxy.expiringThreshold = 30  -- Reset to sensible default
        else
            proxy.expiringThresholdMode = "SECONDS"
            proxy.expiringThreshold = 10  -- Reset to sensible default
        end
        DF:AuraDesigner_RefreshPage()
    end)

    return container
end

-- Duration priority toggle + secret aura warning for frame-level expiring indicators
-- Only shown when there are 2+ triggers on the effect
local function CreateExpiringDurationPriorityRow(parent, auraName, typeKey, width)
    local auraCfg = CurrentAuraPool()[auraName]
    local typeCfg = auraCfg and auraCfg[typeKey]
    local triggers = typeCfg and typeCfg.triggers
    if not triggers or #triggers < 2 then return nil, 0 end

    local container = CreateFrame("Frame", nil, parent)
    container:SetWidth(width or 248)
    local totalH = 0

    -- Duration priority toggle: Lowest / Highest
    local isHighest = typeCfg.triggerDurationPriority == "HIGHEST"

    local durBtn = CreateFrame("Button", nil, container, "BackdropTemplate")
    durBtn:SetHeight(18)
    durBtn:SetPoint("TOPLEFT", 0, 0)

    local durText = durBtn:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(durText, 9, "")
    durText:SetPoint("CENTER", 0, 0)
    durText:SetText(isHighest and L["Track Highest Duration"] or L["Track Lowest Duration"])
    durText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    local durW = durText:GetStringWidth() + 16
    if durW < 80 then durW = 80 end
    durBtn:SetWidth(durW)
    -- Shared styler (rest + accent-wash hover). Two-state toggle; mark active
    -- when tracking Highest so the engaged state reads via the accent border
    -- (page rebuilds on click).
    GUI:StyleButton(durBtn)
    durBtn:SetActive(isHighest)

    durBtn:HookScript("OnEnter", function(self)
        GUI:ShowTooltip(self, {
            title = isHighest and L["Using highest duration trigger"] or L["Using lowest duration trigger"],
            lines = {
                isHighest and L["Expiring indicator tracks the trigger with the most time remaining."]
                    or L["Expiring indicator tracks the trigger with the least time remaining."],
                { text = L["Click to toggle"], hint = true },
            },
        })
    end)
    durBtn:HookScript("OnLeave", function()
        GUI:HideTooltip()
    end)
    durBtn:SetScript("OnClick", function()
        local cfg = CurrentAuraPool()[auraName]
        local tc = cfg and cfg[typeKey]
        if tc then
            if tc.triggerDurationPriority == "HIGHEST" then
                tc.triggerDurationPriority = nil  -- LOWEST is default
            else
                tc.triggerDurationPriority = "HIGHEST"
            end
            DF:AuraDesigner_RefreshPage()
        end
    end)
    totalH = totalH + 22


    container:SetHeight(totalH)
    return container, totalH
end

-- layoutGroup: optional layout group table; if set, anchor/offset controls are replaced with a note
-- indicatorID: optional indicator ID for placed indicators (used by Copy From)
local function BuildTypeContent(parent, typeKey, auraName, width, optProxy, yOffset, layoutGroup, indicatorID)
    local proxy = optProxy or CreateProxy(auraName, typeKey)
    local contentWidth = width or 248
    -- widgets[] entries are {widget, height} so the reflow path can use
    -- group.calculatedHeight (current after a LayoutChildren) while
    -- non-group widgets fall back to the stored at-build-time height.
    local widgets = {}
    local startY = 10 + (yOffset or 0)  -- top padding + optional offset
    local totalHeight = startY

    -- P4.7 (12.1 GUI status overlays): collected here so the block pass at the
    -- end of BuildTypeContent can frost the effect-settings groups the factory
    -- can't (yet) drive, WITHOUT touching the trigger tags above (built into
    -- `parent` before this function runs — the working "which aura" layer).
    -- expiringGroup / swmCheck / borderCtl / stackMinCtl are captured for the surgical
    -- blocks (Expiring, Show When Missing, gradient border style, min stacks). See block
    -- pass below.
    local builtGroups = {}
    local expiringGroup, swmCheck, borderCtl, wholeBarCheck, swmGroup, durColorByTimeCtl
    local missingTriggerGroup, expireAlertGroup   -- sound casualties (P4.5 limitation blocks)
    local stackMinCtl   -- Min Stacks slider (inert on 12.1 containers — limitation block)

    local function AddWidget(widget, height)
        widget:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -totalHeight)
        if widget.SetWidth then widget:SetWidth(contentWidth - 10) end
        tinsert(widgets, { widget = widget, height = height or 30 })
        totalHeight = totalHeight + (height or 30)
    end

    -- Reflow all widgets in this BuildTypeContent's stack.  When a group's
    -- LayoutChildren updates its own height (e.g. Border's animation
    -- widgets show/hide), the siblings below were anchored at FIXED y
    -- positions based on the old height — they stay put, causing overlap
    -- (group grew) or large gap (group shrank).  Walk the list re-anchor
    -- each widget at the running total height, reading the current
    -- group.calculatedHeight for groups so the new layout flows correctly.
    -- The host container's height is updated too so any parent scroll
    -- range stays accurate.
    parent.dfAD_ReflowWidgets = function()
        local y = startY
        for _, entry in ipairs(widgets) do
            local w = entry.widget
            local h
            if w.calculatedHeight then
                -- SettingsGroup tracks its current height after LayoutChildren.
                h = w.calculatedHeight
            else
                h = entry.height
            end
            w:ClearAllPoints()
            w:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -y)
            y = y + h
        end
        parent:SetHeight(y)
    end

    local function AddGroup(header, buildFn, showSummary)
        local group = GUI:CreateSettingsGroup(parent, contentWidth - 10, {
            collapsible = true,
            showSummary = showSummary or false,
        })
        group.padding = 6
        group:AddWidget(GUI:CreateHeader(parent, header), 25)
        buildFn(group)
        local h = group:LayoutChildren()
        AddWidget(group, h)
        -- P4.7: track every effect-settings group so the 12.1 block pass can
        -- frost them per-type. Tag the Expiring group for its own limitation block.
        builtGroups[#builtGroups + 1] = group
        if header == L["Expiring"] then expiringGroup = group end
        if header == L["Show When Missing"] then swmGroup = group end
        if header == L["Missing Trigger"] then missingTriggerGroup = group end
        if header == L["Expire Alert"] then expireAlertGroup = group end
        return group
    end

    -- Lightweight subheader for inline section dividers inside a
    -- SettingsGroup.  Smaller and dimmer than GUI:CreateHeader (which is
    -- for top-level group headers) — used in the Expiring section to
    -- separate State Overrides from Icon Effects.  Returned as a Frame
    -- so it composes with g:AddWidget like every other widget.
    local function CreateInlineSubheader(text)
        local frame = CreateFrame("Frame", nil, parent)
        frame:SetHeight(18)
        local label = frame:CreateFontString(nil, "OVERLAY")
        if GUI.SetSettingsFont then
            GUI:SetSettingsFont(label, 8, "")
        end
        label:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 2, 1)
        label:SetText(text)
        local c = GetThemeColor()
        label:SetTextColor(c.r, c.g, c.b, 0.75)
        return frame
    end

    -- ── COPY FROM (placed indicators only: icon, square, bar) ──
    if indicatorID and (typeKey == "icon" or typeKey == "square" or typeKey == "bar") then
        local copyContainer = CreateFrame("Frame", nil, parent)
        copyContainer:SetHeight(36)

        local copyLabel = copyContainer:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(copyLabel, 8, "")
        copyLabel:SetPoint("TOPLEFT", 1, -1)
        copyLabel:SetText(L["COPY APPEARANCE FROM"])
        copyLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

        local capturedAuraName = auraName
        local capturedIndicatorID = indicatorID
        local capturedTypeKey = typeKey

        -- Build the list of other placed indicators of the same type as the
        -- dropdown's options (rebuilt on each open via optionsFunc so newly-added
        -- indicators appear). Keyed by a synthetic id -> a captured source table;
        -- picking one copies its appearance. The opener stays "Select indicator..."
        -- (it's an action picker, not a value selector), achieved by a customGet
        -- that always returns that label string (no matching option key).
        local copySources = {}
        local function BuildCopyFromOptions()
            wipe(copySources)
            local isOther = IsOtherTab()
            local spec = (not isOther) and ResolveSpec() or nil
            local trackable = spec and Adapter and Adapter:GetTrackableAuras(spec)
            local displayNames = {}
            if trackable then
                for _, info in ipairs(trackable) do
                    displayNames[info.name] = info.display
                end
            end

            -- Sources come from the SAME pool as the destination card (the
            -- active tab's) — CopyIndicatorAppearance resolves both ends
            -- through the pool-routed GetIndicatorByID.
            local sources = {}
            for srcAura, auraCfg in pairs(CurrentAuraPool(spec)) do
                if type(auraCfg) == "table" and auraCfg.indicators then
                    for _, ind in ipairs(auraCfg.indicators) do
                        if ind.type == capturedTypeKey then
                            -- Skip self
                            if not (srcAura == capturedAuraName and ind.id == capturedIndicatorID) then
                                tinsert(sources, {
                                    auraName = srcAura,
                                    displayName = isOther and OtherPoolDisplayName(srcAura)
                                        or displayNames[srcAura] or srcAura,
                                    indicatorID = ind.id,
                                })
                            end
                        end
                    end
                end
            end
            sort(sources, function(a, b) return a.displayName < b.displayName end)

            local options = { _order = {} }
            for i, src in ipairs(sources) do
                local key = "src" .. i
                copySources[key] = src
                options[key] = { text = src.displayName }
                options._order[i] = key
            end
            return options
        end

        local copyDrop = GUI:CreateDropdown(
            copyContainer, "", BuildCopyFromOptions(),
            nil, nil, nil,
            function() return L["Select indicator..."] end,   -- customGet (static opener)
            function(key)                                      -- customSet (action)
                local src = copySources[key]
                if src then
                    CopyIndicatorAppearance(src.auraName, src.indicatorID, capturedAuraName, capturedIndicatorID)
                    DF:AuraDesigner_RefreshPage()
                end
            end,
            { inline = true, optionsFunc = BuildCopyFromOptions }
        )
        copyDrop:SetPoint("TOPLEFT", 0, -12)
        copyDrop:SetPoint("RIGHT", copyContainer, "RIGHT", 0, 0)
        copyDrop:SetHeight(20)

        AddWidget(copyContainer, 38)
    end

    -- Color picker callback shorthand — refreshes both the AD preview and live frames
    local function RPL() if RefreshPreviewLightweight then RefreshPreviewLightweight() end RefreshLiveFramesThrottled() end

    -- Shared Expiring "State Overrides" panel for the BORDERED placed indicators
    -- (icon / square / bar).  These three blocks were near-identical; this
    -- collapses them to one builder parameterised by the few real differences
    -- (opts): dualColor (square's separate fill+border colours), alphaHandleKey
    -- (which colour's alpha the slider edits), thicknessMax, durationPriority
    -- (bar), and iconEffects {fillPulsate, wholeAlpha, bounce}.  The master
    -- enable, threshold row, State-Overrides rows, and the shared
    -- CreateAnimationControls block are identical across all three.
    -- (healthbar's Expiring is a different, border-less panel — not built here.)
    -- AD's Expiring panel now renders through the SHARED GUI:CreateExpiringControls
    -- (the same helper the standard buff aura icons use) — AD's design IS the
    -- reference, so this is a thin adapter mapping AD's proxy keys + per-type
    -- options (dualColor, alphaHandleKey, thicknessMax, durationPriority,
    -- iconEffects) onto the shared helper.  RPL = repaint; AuraDesigner_RefreshPage
    -- = full rebuild (threshold-mode toggle needs it).
    local function AddExpiringBorderGroup(opts)
        opts = opts or {}
        -- Text-only mode hides the icon texture, so the border-specific expiring
        -- controls are hidden. Scoped to the ICON type only — squares/bars are
        -- unaffected (this border-visibility change is icon-only by design).
        local iconTextOnly = (typeKey == "icon") and proxy.hideIcon
        AddGroup(L["Expiring"], function(g)
            GUI:CreateExpiringControls(g, proxy, {
                parent        = parent,
                width         = contentWidth - 10,
                masterLabel   = L["Enable Expiring"],
                fullUpdate    = RPL,
                lightColors   = RPL,
                lightGeometry = RPL,
                refreshStates = function()
                    g:LayoutChildren()
                    if parent.dfAD_ReflowWidgets then parent.dfAD_ReflowWidgets() end
                end,
                refreshPage   = function() DF:AuraDesigner_RefreshPage() end,
                afterThreshold = opts.durationPriority and function(addGated)
                    local dpRow, dpH = CreateExpiringDurationPriorityRow(parent, auraName, typeKey, contentWidth - 10)
                    if dpRow then addGated(dpRow, dpH) end
                end or nil,
                keys = {
                    master           = "expiringFeatureEnabled",
                    threshold        = "expiringThreshold",
                    thresholdMode    = "expiringThresholdMode",
                    colorOverride    = "expiringEnabled",
                    color            = "expiringColor",
                    borderColor      = "ExpiringBorderColor",
                    alphaHandleColor = opts.alphaHandleKey or "expiringColor",
                    thickness        = "ExpiringBorderSize",
                    animPrefix       = "ExpiringAnimation",
                    fillPulsate      = "expiringPulsate",
                    wholeAlpha       = "expiringWholeAlphaPulse",
                    bounce           = "expiringBounce",
                    tintEnable       = "expiringTintEnabled",
                    tintColor        = "expiringTintColor",
                },
                include = {
                    threshold     = true,
                    -- Border-specific expiring overrides (colour override + its
                    -- border colour/alpha, and thickness) are hidden for a
                    -- text-only ICON, which draws no border. Threshold, animation,
                    -- tint and the whole-frame icon effects still apply. Squares
                    -- and bars are never gated here (iconTextOnly is icon-only),
                    -- so their controls always stay on.
                    colorOverride = not iconTextOnly,
                    dualColor     = opts.dualColor,
                    alpha         = not iconTextOnly,
                    thickness     = not iconTextOnly, thicknessMin = 0, thicknessMax = opts.thicknessMax or 5,
                    -- Animation rides the border, which a text-only icon doesn't
                    -- draw, so hide it there too (no border = nowhere to attach).
                    animation     = not iconTextOnly,
                    iconEffects   = opts.iconEffects,
                    -- secret-safe; works on all auras. Opt out via opts.tint=false
                    -- for indicator types whose render can't apply a tint (e.g. the
                    -- border type draws no fill, so SetupExpiringTint is never called).
                    tint          = (opts.tint ~= false),
                },
                lightTint = RPL,
            })
        end)
    end

    if typeKey == "icon" then
        -- Position
        AddGroup(L["Position"], function(g)
            if layoutGroup then
                local groupNote = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                groupNote:SetTextColor(0.91, 0.66, 0.25, 0.8)
                groupNote:SetText(format(L["Position managed by: %s"], layoutGroup.name or L["Layout Group"]))
                g:AddWidget(groupNote, 18)
            else
                g:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], OPTS.ANCHOR_OPTIONS, proxy, "anchor", function() DF:AuraDesigner_RefreshPage() end), 54)
                g:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, proxy, "offsetX"), 54)
                g:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, proxy, "offsetY"), 54)
            end
        end)
        -- Appearance
        AddGroup(L["Appearance"], function(g)
            g:AddWidget(GUI:CreateSlider(parent, L["Size"], 8, 64, 1, proxy, "size"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Scale"], 0.5, 3.0, 0.05, proxy, "scale"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Alpha"], 0, 1, 0.05, proxy, "alpha"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Frame Level"], -10, 30, 1, proxy, "frameLevel"), 54)
            g:AddWidget(GUI:CreateDropdown(parent, L["Frame Strata"], OPTS.FRAME_STRATA_OPTIONS, proxy, "frameStrata"), 54)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Hide Cooldown Swipe"], proxy, "hideSwipe"), 28)
            -- Text-only mode: the icon TEXTURE is hidden, so a border (static OR
            -- expiring) would frame nothing. Rebuild the page on toggle so the
            -- Border group + the expiring-border thickness control hide/show
            -- (gated on proxy.hideIcon below) — matching the runtime, which
            -- force-disables both borders in this mode.
            g:AddWidget(GUI:CreateCheckbox(parent, L["Hide Icon (Text Only)"], proxy, "hideIcon", function()
                DF:AuraDesigner_RefreshPage()
            end), 28)
        end)
        -- Show When Missing
        AddGroup(L["Show When Missing"], function(g)
            local desatCb
            local function UpdateDesatState()
                if not desatCb then return end
                if proxy.showWhenMissing then
                    desatCb:SetAlpha(1)
                    desatCb:EnableMouse(true)
                else
                    desatCb:SetAlpha(0.4)
                    desatCb:EnableMouse(false)
                end
            end
            g:AddWidget(GUI:CreateCheckbox(parent, L["Show When Missing"], proxy, "showWhenMissing", function()
                UpdateDesatState()
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end), 28)
            desatCb = GUI:CreateCheckbox(parent, L["Desaturate When Missing"], proxy, "missingDesaturate", function()
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end)
            g:AddWidget(desatCb, 28)
            UpdateDesatState()
        end)
        -- Border (Stage 5.1c — unified controls via CreateBorderControls).
        -- Show / Thickness / Inset are the same widgets as before; the helper
        -- adds Style / Texture / Color / Gradient / Shadow / BlendMode /
        -- Offset / Alpha on top.  Animation, classColor, roleColor, and the
        -- colorByTime checkbox are deliberately omitted — animation isn't
        -- wired through AD's expiring system yet, class/role don't fit aura
        -- indicators (the indicator's job is to show aura state, not unit
        -- identity), and AD's Expiring section already covers "colour by
        -- time remaining" implicitly through its own colour curve.
        -- Text-only mode hides the icon texture, so the whole Border group is
        -- hidden (the runtime force-disables the border there too).
        if not proxy.hideIcon then
        AddGroup(L["Border"], function(g)
            GUI:CreateBorderControls(g, proxy, "", {
                parent  = parent,
                include = {
                    inset = true, offset = true, blendMode = true,
                    gradient = true, shadow = true, alpha = true,
                    animate = true,
                },
                -- LCG glows taint on native aura buttons and get stripped by the container's
                -- SAFE_OVERLAY_ANIM allowlist; drop them from the dropdown so a factory-owned
                -- placed indicator can't offer a type that silently won't animate (mirror the
                -- frame-level AD border).
                animExcludeTypes = { PULSATE = true, CHASE = true, FLASH = true, PROC = true },
                -- IMPORTANT: AD's per-aura proxy only triggers
                -- RefreshLiveFramesThrottled + RefreshPreviewLightweight
                -- on direct key assignment (proxy.X = v) via __newindex.
                -- CreateColorPicker and the Border Alpha slider mutate
                -- SUB-TABLE fields (proxy.BorderColor.a = v) which reads
                -- through __index then writes to the returned table — no
                -- __newindex fires, no refresh runs, and both the live
                -- frame AND the AD preview window stay on the pre-edit
                -- colour until /reload.
                --
                -- RPL (defined above in BuildTypeContent) runs both the
                -- preview refresh and the throttled live-frame refresh, so
                -- colour-picker / alpha-slider / size-drag updates land
                -- everywhere consistently within the 100ms debounce.
                fullUpdate    = RPL,
                lightUpdate   = RPL,
                lightColors   = RPL,
                -- refreshStates re-evaluates hideOn on the Border group's
                -- widgets and then reflows the sibling groups below in the
                -- card body so the Expiring / Duration Text / Stack Count
                -- groups slide up or down to track the Border group's new
                -- height.  Without the reflow, the Border group's internal
                -- LayoutChildren updates its own height but the siblings
                -- stay at fixed y positions — animation widgets surface
                -- and overlap Expiring, or hide and leave a gap above
                -- Expiring.  dfAD_ReflowWidgets is set on the BuildTypeContent
                -- parent and walks the whole widget stack.
                refreshStates = function()
                    g:LayoutChildren()
                    if parent.dfAD_ReflowWidgets then
                        parent.dfAD_ReflowWidgets()
                    end
                end,
                sizeMin = 1, sizeMax = 5, sizeStep = 1,
            })
        end)
        end  -- if not proxy.hideIcon (text-only hides the Border group)
        -- Expiring (moved up next to Border — the border's expiring colour and
        -- the per-icon effects all key off the same threshold, so grouping
        -- them adjacent reads more naturally than burying Expiring at the
        -- bottom of the panel.)
        -- Icon: single Expiring Colour, Whole Alpha Pulse + Bounce effects.
        AddExpiringBorderGroup({
            thicknessMax = 5,
            iconEffects = { wholeAlpha = true, bounce = true },
        })
        -- Duration Text
        AddGroup(L["Duration Text"], function(g)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Show Duration"], proxy, "showDuration"), 28)
            g:AddWidget(GUI:CreateFontDropdown(parent, L["Duration Font"], proxy, "durationFont"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Duration Scale"], 0.5, 2.0, 0.1, proxy, "durationScale"), 54)
            g:AddWidget(GUI:CreateOutlineDropdown(parent, L["Outline"], proxy, "durationOutline"), 54)
            g:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], proxy, "durationOutline"), 28)
            g:AddWidget(GUI:CreateDropdown(parent, L["Duration Anchor"], OPTS.ANCHOR_OPTIONS, proxy, "durationAnchor"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, proxy, "durationX"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, proxy, "durationY"), 54)
            durColorByTimeCtl = GUI:CreateCheckbox(parent, L["Color by Time Remaining"], proxy, "durationColorByTime")
            g:AddWidget(durColorByTimeCtl, 28)
            g:AddWidget(GUI:CreateColorPicker(parent, L["Duration Text Color"], proxy, "durationColor", true, RPL, RPL, true), 28)
            local hideAboveSlider
            local function UpdateHideAboveState()
                if not hideAboveSlider then return end
                if proxy.durationHideAboveEnabled then
                    hideAboveSlider:SetAlpha(1)
                    hideAboveSlider:EnableMouse(true)
                else
                    hideAboveSlider:SetAlpha(0.4)
                    hideAboveSlider:EnableMouse(false)
                end
            end
            g:AddWidget(GUI:CreateCheckbox(parent, L["Hide Duration Above Threshold"], proxy, "durationHideAboveEnabled", UpdateHideAboveState), 28)
            hideAboveSlider = GUI:CreateSlider(parent, L["Hide Above (seconds)"], 1, 60, 1, proxy, "durationHideAboveThreshold")
            g:AddWidget(hideAboveSlider, 54)
            UpdateHideAboveState()
        end)
        -- Stack Count
        AddGroup(L["Stack Count"], function(g)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Show Stacks"], proxy, "showStacks"), 28)
            stackMinCtl = GUI:CreateSlider(parent, L["Min Stacks to Show"], 1, 10, 1, proxy, "stackMinimum")
            g:AddWidget(stackMinCtl, 54)
            g:AddWidget(GUI:CreateFontDropdown(parent, L["Stack Font"], proxy, "stackFont"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Stack Scale"], 0.5, 2.0, 0.1, proxy, "stackScale"), 54)
            g:AddWidget(GUI:CreateOutlineDropdown(parent, L["Stack Outline"], proxy, "stackOutline"), 54)
            g:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], proxy, "stackOutline"), 28)
            g:AddWidget(GUI:CreateDropdown(parent, L["Stack Anchor"], OPTS.ANCHOR_OPTIONS, proxy, "stackAnchor"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, proxy, "stackX"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, proxy, "stackY"), 54)
            g:AddWidget(GUI:CreateColorPicker(parent, L["Stack Text Color"], proxy, "stackColor", true, RPL, RPL, true), 28)
        end)

    elseif typeKey == "square" then
        -- Position
        AddGroup(L["Position"], function(g)
            if layoutGroup then
                local groupNote = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                groupNote:SetTextColor(0.91, 0.66, 0.25, 0.8)
                groupNote:SetText(format(L["Position managed by: %s"], layoutGroup.name or L["Layout Group"]))
                g:AddWidget(groupNote, 18)
            else
                g:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], OPTS.ANCHOR_OPTIONS, proxy, "anchor", function() DF:AuraDesigner_RefreshPage() end), 54)
                g:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, proxy, "offsetX"), 54)
                g:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, proxy, "offsetY"), 54)
            end
        end)
        -- Appearance
        AddGroup(L["Appearance"], function(g)
            g:AddWidget(GUI:CreateSlider(parent, L["Size"], 8, 64, 1, proxy, "size"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Scale"], 0.5, 3.0, 0.05, proxy, "scale"), 54)
            g:AddWidget(GUI:CreateColorPicker(parent, L["Color"], proxy, "color", true, RPL, RPL, true), 28)
            g:AddWidget(GUI:CreateSlider(parent, L["Alpha"], 0, 1, 0.05, proxy, "alpha"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Frame Level"], -10, 30, 1, proxy, "frameLevel"), 54)
            g:AddWidget(GUI:CreateDropdown(parent, L["Frame Strata"], OPTS.FRAME_STRATA_OPTIONS, proxy, "frameStrata"), 54)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Hide Cooldown Swipe"], proxy, "hideSwipe"), 28)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Hide Icon (Text Only)"], proxy, "hideIcon"), 28)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Show When Missing"], proxy, "showWhenMissing", function()
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end), 28)
        end)
        -- Border (Stage 5.2 — unified controls via CreateBorderControls).
        -- Same full toolkit as the icon's base border: Style / Texture / Colour
        -- / Gradient / Shadow / Blend / Offset / Alpha + Animation.  The
        -- square's expiring system tints the FILL (not the border), so the
        -- icon's expiring-border overrides are intentionally NOT added here.
        AddGroup(L["Border"], function(g)
            GUI:CreateBorderControls(g, proxy, "", {
                parent  = parent,
                include = {
                    inset = true, offset = true, blendMode = true,
                    gradient = true, shadow = true, alpha = true,
                    animate = true,
                },
                -- LCG glows taint on native aura buttons and get stripped by the container's
                -- SAFE_OVERLAY_ANIM allowlist; drop them from the dropdown (mirror frame-level AD).
                animExcludeTypes = { PULSATE = true, CHASE = true, FLASH = true, PROC = true },
                fullUpdate    = RPL,
                lightUpdate   = RPL,
                lightColors   = RPL,
                refreshStates = function()
                    g:LayoutChildren()
                    if parent.dfAD_ReflowWidgets then
                        parent.dfAD_ReflowWidgets()
                    end
                end,
                sizeMin = 1, sizeMax = 5, sizeStep = 1,
            })
        end)
        -- Expiring (moved up next to Border — matches the icon indicator's
        -- panel ordering. Border colour, fill pulsate, alpha pulse, and bounce
        -- all key off the same threshold; grouping them adjacent to Border
        -- reads more naturally than burying Expiring at the bottom.)
        -- Square: separate fill + border Expiring colours (alpha handle edits the
        -- BORDER colour); Fill Pulsate + Whole Alpha Pulse + Bounce effects.
        AddExpiringBorderGroup({
            thicknessMax = 5,
            dualColor = true,
            alphaHandleKey = "ExpiringBorderColor",
            iconEffects = { fillPulsate = true, wholeAlpha = true, bounce = true },
        })
        -- Duration Text
        AddGroup(L["Duration Text"], function(g)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Show Duration"], proxy, "showDuration"), 28)
            g:AddWidget(GUI:CreateFontDropdown(parent, L["Duration Font"], proxy, "durationFont"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Duration Scale"], 0.5, 2.0, 0.1, proxy, "durationScale"), 54)
            g:AddWidget(GUI:CreateOutlineDropdown(parent, L["Outline"], proxy, "durationOutline"), 54)
            g:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], proxy, "durationOutline"), 28)
            g:AddWidget(GUI:CreateDropdown(parent, L["Duration Anchor"], OPTS.ANCHOR_OPTIONS, proxy, "durationAnchor"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, proxy, "durationX"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, proxy, "durationY"), 54)
            durColorByTimeCtl = GUI:CreateCheckbox(parent, L["Color by Time Remaining"], proxy, "durationColorByTime")
            g:AddWidget(durColorByTimeCtl, 28)
            g:AddWidget(GUI:CreateColorPicker(parent, L["Duration Text Color"], proxy, "durationColor", true, RPL, RPL, true), 28)
            local hideAboveSlider
            local function UpdateHideAboveState()
                if not hideAboveSlider then return end
                if proxy.durationHideAboveEnabled then
                    hideAboveSlider:SetAlpha(1)
                    hideAboveSlider:EnableMouse(true)
                else
                    hideAboveSlider:SetAlpha(0.4)
                    hideAboveSlider:EnableMouse(false)
                end
            end
            g:AddWidget(GUI:CreateCheckbox(parent, L["Hide Duration Above Threshold"], proxy, "durationHideAboveEnabled", UpdateHideAboveState), 28)
            hideAboveSlider = GUI:CreateSlider(parent, L["Hide Above (seconds)"], 1, 60, 1, proxy, "durationHideAboveThreshold")
            g:AddWidget(hideAboveSlider, 54)
            UpdateHideAboveState()
        end)
        -- Stack Count
        AddGroup(L["Stack Count"], function(g)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Show Stacks"], proxy, "showStacks"), 28)
            stackMinCtl = GUI:CreateSlider(parent, L["Min Stacks to Show"], 1, 10, 1, proxy, "stackMinimum")
            g:AddWidget(stackMinCtl, 54)
            g:AddWidget(GUI:CreateFontDropdown(parent, L["Stack Font"], proxy, "stackFont"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Stack Scale"], 0.5, 2.0, 0.1, proxy, "stackScale"), 54)
            g:AddWidget(GUI:CreateOutlineDropdown(parent, L["Stack Outline"], proxy, "stackOutline"), 54)
            g:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], proxy, "stackOutline"), 28)
            g:AddWidget(GUI:CreateDropdown(parent, L["Stack Anchor"], OPTS.ANCHOR_OPTIONS, proxy, "stackAnchor"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, proxy, "stackX"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, proxy, "stackY"), 54)
            g:AddWidget(GUI:CreateColorPicker(parent, L["Stack Text Color"], proxy, "stackColor", true, RPL, RPL, true), 28)
        end)

    elseif typeKey == "bar" then
        -- Position
        AddGroup(L["Position"], function(g)
            if layoutGroup then
                local groupNote = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                groupNote:SetTextColor(0.91, 0.66, 0.25, 0.8)
                groupNote:SetText(format(L["Position managed by: %s"], layoutGroup.name or L["Layout Group"]))
                g:AddWidget(groupNote, 18)
            else
                g:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], OPTS.ANCHOR_OPTIONS, proxy, "anchor", function() DF:AuraDesigner_RefreshPage() end), 54)
                g:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, proxy, "offsetX"), 54)
                g:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, proxy, "offsetY"), 54)
            end
        end)
        -- Size & Orientation
        AddGroup(L["Size & Orientation"], function(g)
            g:AddWidget(GUI:CreateDropdown(parent, L["Orientation"], OPTS.BAR_ORIENT_OPTIONS, proxy, "orientation", function()
                local w = proxy.width
                local h = proxy.height
                proxy.width = h
                proxy.height = w
                local mw = proxy.matchFrameWidth
                local mh = proxy.matchFrameHeight
                proxy.matchFrameWidth = mh
                proxy.matchFrameHeight = mw
                DF:AuraDesigner_RefreshPage()
            end), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Width"], 0, 200, 1, proxy, "width"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Height"], 1, 30, 1, proxy, "height"), 54)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Match Frame Width"], proxy, "matchFrameWidth"), 28)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Match Frame Height"], proxy, "matchFrameHeight"), 28)
        end)
        -- Texture & Colors
        AddGroup(L["Texture & Colors"], function(g)
            g:AddWidget(GUI:CreateTextureDropdown(parent, L["Bar Texture"], proxy, "texture"), 54)
            g:AddWidget(GUI:CreateColorPicker(parent, L["Fill Color"], proxy, "fillColor", true, RPL, RPL, true), 28)
            g:AddWidget(GUI:CreateColorPicker(parent, L["Background Color"], proxy, "bgColor", true, RPL, RPL, true), 28)
            g:AddWidget(GUI:CreateSlider(parent, L["Alpha"], 0, 1, 0.05, proxy, "alpha"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Frame Level"], -10, 30, 1, proxy, "frameLevel"), 54)
            g:AddWidget(GUI:CreateDropdown(parent, L["Frame Strata"], OPTS.FRAME_STRATA_OPTIONS, proxy, "frameStrata"), 54)
        end)
        -- Border (Stage 5.3 — unified controls via CreateBorderControls).
        -- Full toolkit (Style / Texture / Colour / Gradient / Shadow / Blend /
        -- Inset / Alpha + Animation).  No offset (the bar has its own X/Y) and
        -- no class/role (it's an aura bar, not unit identity).  The bar's
        -- expiring tints the FILL via its colour curve, so the icon/square
        -- expiring-border overrides are intentionally not added here.
        AddGroup(L["Border"], function(g)
            GUI:CreateBorderControls(g, proxy, "", {
                parent  = parent,
                include = {
                    inset = true, blendMode = true, gradient = true,
                    shadow = true, alpha = true, animate = true,
                },
                -- LCG glows taint on native aura buttons and get stripped by the container's
                -- SAFE_OVERLAY_ANIM allowlist; drop them from the dropdown (mirror frame-level AD).
                animExcludeTypes = { PULSATE = true, CHASE = true, FLASH = true, PROC = true },
                fullUpdate    = RPL,
                lightUpdate   = RPL,
                lightColors   = RPL,
                refreshStates = function()
                    g:LayoutChildren()
                    if parent.dfAD_ReflowWidgets then
                        parent.dfAD_ReflowWidgets()
                    end
                end,
                sizeMin = 1, sizeMax = 5, sizeStep = 1,
            })
        end)
        -- Expiring
        AddGroup(L["Expiring"], function(g)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Color by Time Remaining"], proxy, "barColorByTime"), 28)
            -- Expiring Color Override gates the Expiring Color picker; grey it when off.
            local expColorPicker
            local function UpdateExpColorGrey()
                if not expColorPicker then return end
                expColorPicker:SetEnabled(proxy.expiringEnabled and true or false)
            end
            g:AddWidget(GUI:CreateCheckbox(parent, L["Expiring Color Override"], proxy, "expiringEnabled", UpdateExpColorGrey), 28)
            g:AddWidget(CreateExpiringThresholdRow(parent, proxy, contentWidth - 10), 54)
            expColorPicker = GUI:CreateColorPicker(parent, L["Expiring Color"], proxy, "expiringColor", true, RPL, RPL, true)
            g:AddWidget(expColorPicker, 28)
            -- Expiring tint overlay: the bar render (ConfigureBar/UpdateBar) is fully
            -- wired for these keys via SetupExpiringTint, but the hand-built bar group
            -- never exposed them. Surface them so the wired feature is reachable.
            -- Show Expiring Tint gates the Tint Color picker; grey it when off.
            local tintColorPicker
            local function UpdateTintColorGrey()
                if not tintColorPicker then return end
                tintColorPicker:SetEnabled(proxy.expiringTintEnabled and true or false)
            end
            g:AddWidget(GUI:CreateCheckbox(parent, L["Show Expiring Tint"], proxy, "expiringTintEnabled", function()
                UpdateTintColorGrey()
                RPL()
            end), 28)
            tintColorPicker = GUI:CreateColorPicker(parent, L["Tint Color"], proxy, "expiringTintColor", true, RPL, RPL, true)
            g:AddWidget(tintColorPicker, 28)
            UpdateExpColorGrey()
            UpdateTintColorGrey()
        end)
        -- Duration Text
        AddGroup(L["Duration Text"], function(g)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Show Duration"], proxy, "showDuration"), 28)
            g:AddWidget(GUI:CreateFontDropdown(parent, L["Duration Font"], proxy, "durationFont"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Duration Scale"], 0.5, 2.0, 0.1, proxy, "durationScale"), 54)
            g:AddWidget(GUI:CreateOutlineDropdown(parent, L["Outline"], proxy, "durationOutline"), 54)
            g:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], proxy, "durationOutline"), 28)
            g:AddWidget(GUI:CreateDropdown(parent, L["Duration Anchor"], OPTS.ANCHOR_OPTIONS, proxy, "durationAnchor"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 1, proxy, "durationX"), 54)
            g:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 1, proxy, "durationY"), 54)
            durColorByTimeCtl = GUI:CreateCheckbox(parent, L["Color by Time Remaining"], proxy, "durationColorByTime")
            g:AddWidget(durColorByTimeCtl, 28)
            local hideAboveSlider
            local function UpdateHideAboveState()
                if not hideAboveSlider then return end
                if proxy.durationHideAboveEnabled then
                    hideAboveSlider:SetAlpha(1)
                    hideAboveSlider:EnableMouse(true)
                else
                    hideAboveSlider:SetAlpha(0.4)
                    hideAboveSlider:EnableMouse(false)
                end
            end
            g:AddWidget(GUI:CreateCheckbox(parent, L["Hide Duration Above Threshold"], proxy, "durationHideAboveEnabled", UpdateHideAboveState), 28)
            hideAboveSlider = GUI:CreateSlider(parent, L["Hide Above (seconds)"], 1, 60, 1, proxy, "durationHideAboveThreshold")
            g:AddWidget(hideAboveSlider, 54)
            UpdateHideAboveState()
        end)

    elseif typeKey == "border" then
        -- Appearance — full DF.Border toolkit (Stage 5.4).  The legacy 5
        -- styles are now combinations: Solid = Style SOLID; Glow = Style
        -- TEXTURE + DF Glow; Dashed/Animated = Border Thickness 0 + DF Dash
        -- (speed 0 / >0); Corners = Border Thickness 0 + Corners Only.
        -- include offset too — this border covers the whole frame, so nudging
        -- it can be useful.  No class/role (it's an aura indicator).
        AddGroup(L["Appearance"], function(g)
            borderCtl = GUI:CreateBorderControls(g, proxy, "", {
                parent  = parent,
                include = {
                    inset = true, offset = true, blendMode = true,
                    gradient = true, shadow = true, alpha = true,
                    animate = true,
                },
                -- The AD border runs on the AuraContainer overlay path, which only
                -- recovers the taint-safe DF-owned animations (SAFE_OVERLAY_ANIM in
                -- AuraContainer.lua). Drop the LCG glows from the dropdown so users
                -- can't pick a type that gets silently stripped.
                animExcludeTypes = { PULSATE = true, CHASE = true, FLASH = true, PROC = true },
                fullUpdate    = RPL,
                lightUpdate   = RPL,
                lightColors   = RPL,
                refreshStates = function()
                    g:LayoutChildren()
                    if parent.dfAD_ReflowWidgets then parent.dfAD_ReflowWidgets() end
                end,
                sizeMin = 0, sizeMax = 8, sizeStep = 1,
            })
            -- Draw order: lift this border above the frame's own class/role
            -- border so it fully covers it (on by default).  Off tucks it back
            -- underneath the frame border (the pre-5.4 stacking).
            g:AddWidget(GUI:CreateCheckbox(parent, L["Draw above frame border"], proxy, "drawAboveFrameBorder", RPL), 28)
            swmCheck = GUI:CreateCheckbox(parent, L["Show When Missing"], proxy, "showWhenMissing", function()
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end)
            g:AddWidget(swmCheck, 28)
        end)
        -- Expiring — full parity with icon/square (Stage 5.4): master enable +
        -- State Overrides (border thickness / colour / alpha / animation swap)
        -- + the existing Pulsate.  The Expiring Animation lets the border swap
        -- effect below threshold (e.g. solid → marching DF Dash).
        -- Bar: single Expiring Colour, thicker max (8), a duration-priority row,
        -- and no Icon-Effects (bars don't pulse/bounce the whole icon).
        -- The border type draws no fill, so the expiring "tint" overlay has nothing
        -- to tint and ApplyBorderToOverlay never calls SetupExpiringTint — hide the
        -- otherwise-dead "Show Expiring Tint" / "Tint Color" controls for this type.
        AddExpiringBorderGroup({
            thicknessMax = 8,
            durationPriority = true,
            tint = false,
        })

    elseif typeKey == "healthbar" then
        -- Appearance
        AddGroup(L["Appearance"], function(g)
            g:AddWidget(GUI:CreateDropdown(parent, L["Mode"], OPTS.HEALTHBAR_MODE_OPTIONS, proxy, "mode", function()
                -- Rebuild so the Blend % slider's hideOn re-evaluates and the
                -- group's height recomputes for the new visible-widget set.
                DF:AuraDesigner_RefreshPage()
            end), 54)
            g:AddWidget(GUI:CreateColorPicker(parent, L["Color"], proxy, "color", true, RPL, RPL, true), 28)
            local blendSlider = GUI:CreateSlider(parent, L["Blend %"], 0, 1, 0.05, proxy, "blend")
            -- hideOn is re-evaluated on every LayoutChildren pass, so the slider
            -- stays correctly hidden in Replace mode across GUI reopens. A manual
            -- :Hide() would be clobbered by LayoutChildren's unconditional :Show().
            blendSlider.hideOn = function() return (proxy.mode or "Replace") == "Replace" end
            g:AddWidget(blendSlider, 54)
            -- Tint-mode only: tint the WHOLE bar (incl. missing health) instead of
            -- just the current-health portion. Hidden in Replace mode (there the bar
            -- IS the indicator, so this would hide health loss). Same hideOn as Blend.
            wholeBarCheck = GUI:CreateCheckbox(parent, L["Tint Entire Bar"], proxy, "tintWholeBar", RPL)
            wholeBarCheck.hideOn = function() return (proxy.mode or "Replace") == "Replace" end
            g:AddWidget(wholeBarCheck, 28)
            swmCheck = GUI:CreateCheckbox(parent, L["Show When Missing"], proxy, "showWhenMissing", function()
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end)
            g:AddWidget(swmCheck, 28)
        end)
        -- Expiring
        AddGroup(L["Expiring"], function(g)
            -- Expiring Color Override gates the Expiring Color picker + Pulsate;
            -- grey them when off.
            local expColorPicker, pulsateCheck
            local function UpdateExpGrey()
                local on = proxy.expiringEnabled and true or false
                if expColorPicker then expColorPicker:SetEnabled(on) end
                if pulsateCheck then pulsateCheck:SetEnabled(on) end
            end
            g:AddWidget(GUI:CreateCheckbox(parent, L["Expiring Color Override"], proxy, "expiringEnabled", UpdateExpGrey), 28)
            g:AddWidget(CreateExpiringThresholdRow(parent, proxy, contentWidth - 10), 54)
            do local dpRow, dpH = CreateExpiringDurationPriorityRow(parent, auraName, typeKey, contentWidth - 10)
            if dpRow then g:AddWidget(dpRow, dpH) end end
            expColorPicker = GUI:CreateColorPicker(parent, L["Expiring Color"], proxy, "expiringColor", true, RPL, RPL, true)
            g:AddWidget(expColorPicker, 28)
            pulsateCheck = GUI:CreateCheckbox(parent, L["Pulsate"], proxy, "expiringPulsate")
            g:AddWidget(pulsateCheck, 24)
            UpdateExpGrey()
        end)

    elseif typeKey == "background" then
        -- Appearance — mirrors Health Bar Color. A colour overlay over the frame
        -- background (visible in the missing-health area). Replace = opaque cover;
        -- Tint = blend × colour alpha so the normal background shows through.
        AddGroup(L["Appearance"], function(g)
            g:AddWidget(GUI:CreateDropdown(parent, L["Mode"], OPTS.HEALTHBAR_MODE_OPTIONS, proxy, "mode", function()
                DF:AuraDesigner_RefreshPage()
            end), 54)
            g:AddWidget(GUI:CreateColorPicker(parent, L["Color"], proxy, "color", true, RPL, RPL, true), 28)
            local blendSlider = GUI:CreateSlider(parent, L["Blend %"], 0, 1, 0.05, proxy, "blend")
            blendSlider.hideOn = function() return (proxy.mode or "Tint") == "Replace" end
            g:AddWidget(blendSlider, 54)
            swmCheck = GUI:CreateCheckbox(parent, L["Show When Missing"], proxy, "showWhenMissing", function()
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end)
            g:AddWidget(swmCheck, 28)
        end)
        -- Expiring
        AddGroup(L["Expiring"], function(g)
            -- Expiring Color Override gates the Expiring Color picker + Pulsate;
            -- grey them when off.
            local expColorPicker, pulsateCheck
            local function UpdateExpGrey()
                local on = proxy.expiringEnabled and true or false
                if expColorPicker then expColorPicker:SetEnabled(on) end
                if pulsateCheck then pulsateCheck:SetEnabled(on) end
            end
            g:AddWidget(GUI:CreateCheckbox(parent, L["Expiring Color Override"], proxy, "expiringEnabled", UpdateExpGrey), 28)
            g:AddWidget(CreateExpiringThresholdRow(parent, proxy, contentWidth - 10), 54)
            do local dpRow, dpH = CreateExpiringDurationPriorityRow(parent, auraName, typeKey, contentWidth - 10)
            if dpRow then g:AddWidget(dpRow, dpH) end end
            expColorPicker = GUI:CreateColorPicker(parent, L["Expiring Color"], proxy, "expiringColor", true, RPL, RPL, true)
            g:AddWidget(expColorPicker, 28)
            pulsateCheck = GUI:CreateCheckbox(parent, L["Pulsate"], proxy, "expiringPulsate")
            g:AddWidget(pulsateCheck, 24)
            UpdateExpGrey()
        end)

    elseif typeKey == "nametext" then
        -- Appearance
        AddGroup(L["Appearance"], function(g)
            g:AddWidget(GUI:CreateColorPicker(parent, L["Color"], proxy, "color", true, RPL, RPL, true), 28)
            swmCheck = GUI:CreateCheckbox(parent, L["Show When Missing"], proxy, "showWhenMissing", function()
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end)
            g:AddWidget(swmCheck, 28)
        end)
        -- Expiring
        AddGroup(L["Expiring"], function(g)
            -- Expiring Color Override gates the Expiring Color picker; grey it when off.
            local expColorPicker
            local function UpdateExpColorGrey()
                if expColorPicker then expColorPicker:SetEnabled(proxy.expiringEnabled and true or false) end
            end
            g:AddWidget(GUI:CreateCheckbox(parent, L["Expiring Color Override"], proxy, "expiringEnabled", UpdateExpColorGrey), 28)
            g:AddWidget(CreateExpiringThresholdRow(parent, proxy, contentWidth - 10), 54)
            do local dpRow, dpH = CreateExpiringDurationPriorityRow(parent, auraName, typeKey, contentWidth - 10)
            if dpRow then g:AddWidget(dpRow, dpH) end end
            expColorPicker = GUI:CreateColorPicker(parent, L["Expiring Color"], proxy, "expiringColor", true, RPL, RPL, true)
            g:AddWidget(expColorPicker, 28)
            UpdateExpColorGrey()
        end)

    elseif typeKey == "healthtext" then
        -- Appearance
        AddGroup(L["Appearance"], function(g)
            g:AddWidget(GUI:CreateColorPicker(parent, L["Color"], proxy, "color", true, RPL, RPL, true), 28)
            swmCheck = GUI:CreateCheckbox(parent, L["Show When Missing"], proxy, "showWhenMissing", function()
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end)
            g:AddWidget(swmCheck, 28)
        end)
        -- Expiring
        AddGroup(L["Expiring"], function(g)
            -- Expiring Color Override gates the Expiring Color picker; grey it when off.
            local expColorPicker
            local function UpdateExpColorGrey()
                if expColorPicker then expColorPicker:SetEnabled(proxy.expiringEnabled and true or false) end
            end
            g:AddWidget(GUI:CreateCheckbox(parent, L["Expiring Color Override"], proxy, "expiringEnabled", UpdateExpColorGrey), 28)
            g:AddWidget(CreateExpiringThresholdRow(parent, proxy, contentWidth - 10), 54)
            do local dpRow, dpH = CreateExpiringDurationPriorityRow(parent, auraName, typeKey, contentWidth - 10)
            if dpRow then g:AddWidget(dpRow, dpH) end end
            expColorPicker = GUI:CreateColorPicker(parent, L["Expiring Color"], proxy, "expiringColor", true, RPL, RPL, true)
            g:AddWidget(expColorPicker, 28)
            UpdateExpColorGrey()
        end)

    elseif typeKey == "framealpha" then
        -- Appearance
        AddGroup(L["Appearance"], function(g)
            g:AddWidget(GUI:CreateSlider(parent, L["Alpha"], 0, 1, 0.05, proxy, "alpha"), 54)
            g:AddWidget(GUI:CreateCheckbox(parent, L["Show When Missing"], proxy, "showWhenMissing", function()
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end), 28)
        end)
        -- Expiring
        AddGroup(L["Expiring"], function(g)
            -- Expiring Alpha Override gates the Expiring Alpha slider; grey it when off.
            local expAlphaSlider
            local function UpdateExpAlphaGrey()
                if expAlphaSlider then expAlphaSlider:SetEnabled(proxy.expiringEnabled and true or false) end
            end
            g:AddWidget(GUI:CreateCheckbox(parent, L["Expiring Alpha Override"], proxy, "expiringEnabled", UpdateExpAlphaGrey), 28)
            g:AddWidget(CreateExpiringThresholdRow(parent, proxy, contentWidth - 10), 54)
            do local dpRow, dpH = CreateExpiringDurationPriorityRow(parent, auraName, typeKey, contentWidth - 10)
            if dpRow then g:AddWidget(dpRow, dpH) end end
            expAlphaSlider = GUI:CreateSlider(parent, L["Expiring Alpha"], 0, 1, 0.05, proxy, "expiringAlpha")
            g:AddWidget(expAlphaSlider, 54)
            UpdateExpAlphaGrey()
        end)

    elseif typeKey == "sound" then
        -- Enable checkbox
        AddGroup(L["Sound Alert"], function(g)
            -- Group-only warning banner
            do
                local topSpacer = CreateFrame("Frame", nil, parent)
                topSpacer:SetHeight(4)
                g:AddWidget(topSpacer, 4)

                local banner = GUI:CreateInfoBanner(parent, {
                    tone = "caution",
                    text = L["Sound alerts only work when you are in a group."],
                })
                banner:SetWidth(contentWidth - 10)
                g:AddWidget(banner, banner.layoutHeight)

                local spacer = CreateFrame("Frame", nil, parent)
                spacer:SetHeight(6)
                g:AddWidget(spacer, 6)
            end

            -- Other Buffs: the on-apply sound path has no caster filter
            -- (AddAuraAppliedSound), so an other-pool alert also fires for the
            -- player's OWN cast — and for a spell that My Buffs also tracked,
            -- both pools' sounds would fire. Surface it (B1 concern 2).
            if IsOtherTab() then
                local obBanner = GUI:CreateInfoBanner(parent, {
                    tone = "info",
                    text = L["Sound alerts play when anyone gains this buff, including your own casts."],
                })
                obBanner:SetWidth(contentWidth - 10)
                g:AddWidget(obBanner, obBanner.layoutHeight)
                local obSpacer = CreateFrame("Frame", nil, parent)
                obSpacer:SetHeight(6)
                g:AddWidget(obSpacer, 6)
            end

            local soundOn = proxy.enabled ~= false
            g:AddWidget(GUI:CreateCheckbox(parent, L["Enable Sound Alert"], proxy, "enabled", function()
                -- Stop sound immediately when disabled
                if not proxy.enabled and DF.AuraDesigner.SoundEngine then
                    DF.AuraDesigner.SoundEngine:StopAura(auraName)
                end
                DF:AuraDesigner_RefreshPage()
            end), 28)

            -- Sound picker (searchable scrollable dropdown)
            local soundDD = GUI:CreateSoundDropdown(parent, L["Sound"], proxy, "soundLSMKey", function()
                -- Update soundFile path when LSM key changes
                local path = DF:GetSoundPath(proxy.soundLSMKey)
                if path then
                    proxy.soundFile = path
                end
            end)
            g:AddWidget(soundDD, 54)

            -- Custom file path (overrides LSM selection)
            local soundPathEB = GUI:CreateEditBox(parent, L["Custom Sound Path"], proxy, "soundFile", nil, 280)
            g:AddWidget(soundPathEB, 44)

            -- Preview button
            local previewBtn = GUI:CreateButton(parent, L["Preview Sound"], 120, 22, function()
                local soundFile = DF:GetSoundPath(proxy.soundLSMKey) or proxy.soundFile
                if not soundFile or soundFile == "" then
                    print("|cffff8033DandersFrames:|r " .. L["No sound file selected. Choose a sound from the dropdown or enter a custom path."])
                    return
                end
                local volume = proxy.volume or 0.8
                if DF.AuraDesigner.SoundEngine then
                    local willPlay = DF.AuraDesigner.SoundEngine:PlayWithVolume(soundFile, volume)
                    if not willPlay then
                        print("|cffff8033DandersFrames:|r " .. format(L["Sound file could not be played: %s"], tostring(soundFile)))
                    end
                end
            end)
            g:AddWidget(previewBtn, 28)

            -- Volume slider
            local volumeSlider = GUI:CreateSlider(parent, L["Volume"], 0, 1, 0.05, proxy, "volume")
            g:AddWidget(volumeSlider, 54)

            -- Grey out sound sub-controls when sound alert is disabled
            if not soundOn then
                soundDD:SetAlpha(0.4)
                soundDD:EnableMouse(false)
                soundPathEB:SetAlpha(0.4)
                soundPathEB:EnableMouse(false)
                previewBtn:SetAlpha(0.4)
                previewBtn:EnableMouse(false)
                volumeSlider:SetAlpha(0.4)
                volumeSlider:EnableMouse(false)
            end
        end)

        -- Missing Trigger
        AddGroup(L["Missing Trigger"], function(g)
            -- Initialise nil for older profiles (nil = enabled by default)
            if proxy.missingEnabled == nil then proxy.missingEnabled = true end
            local missingOn = proxy.missingEnabled ~= false

            g:AddWidget(GUI:CreateCheckbox(parent, L["Enable Missing Trigger"], proxy, "missingEnabled", function()
                if not proxy.missingEnabled and DF.AuraDesigner.SoundEngine then
                    DF.AuraDesigner.SoundEngine:StopAura(auraName)
                end
                DF:AuraDesigner_RefreshPage()
            end), 28)

            local triggerModeOptions = {
                ANY_MISSING = L["Alert if anyone is missing the buff"],
                ALL_MISSING = L["Alert only if nobody has the buff"],
            }
            local triggerModeDD = GUI:CreateDropdown(parent, L["Trigger Mode"], triggerModeOptions, proxy, "triggerMode")
            g:AddWidget(triggerModeDD, 54)

            local combatModeOptions = {
                ALWAYS         = L["Always"],
                IN_COMBAT      = L["In Combat Only"],
                OUT_OF_COMBAT  = L["Out of Combat Only"],
            }
            local combatModeDD = GUI:CreateDropdown(parent, L["Combat Mode"], combatModeOptions, proxy, "combatMode")
            g:AddWidget(combatModeDD, 54)

            local startDelaySlider = GUI:CreateSlider(parent, L["Start Delay (seconds)"], 0, 10, 0.5, proxy, "startDelay")
            g:AddWidget(startDelaySlider, 54)

            local loopIntervalSlider = GUI:CreateSlider(parent, L["Loop Interval (seconds)"], 1, 30, 0.5, proxy, "loopInterval")
            g:AddWidget(loopIntervalSlider, 54)

            -- Grey out trigger/timing controls when missing trigger is disabled
            if not missingOn then
                triggerModeDD:SetAlpha(0.4)
                triggerModeDD:EnableMouse(false)
                combatModeDD:SetAlpha(0.4)
                combatModeDD:EnableMouse(false)
                startDelaySlider:SetAlpha(0.4)
                startDelaySlider:EnableMouse(false)
                loopIntervalSlider:SetAlpha(0.4)
                loopIntervalSlider:EnableMouse(false)
            end
        end)

        -- Expire Alert
        AddGroup(L["Expire Alert"], function(g)
            local expireOn = proxy.expireEnabled ~= false
            g:AddWidget(GUI:CreateCheckbox(parent, L["Enable Alert When Expiring"], proxy, "expireEnabled", function()
                if not proxy.expireEnabled and DF.AuraDesigner.SoundEngine then
                    DF.AuraDesigner.SoundEngine:StopAura(auraName)
                end
                DF:AuraDesigner_RefreshPage()
            end), 28)

            -- Threshold slider + mode toggle (same pattern as CreateExpiringThresholdRow)
            local isSeconds = (proxy.expireThresholdMode or "SECONDS") == "SECONDS"
            local threshContainer = CreateFrame("Frame", nil, parent)
            threshContainer:SetHeight(54)
            threshContainer:SetWidth(contentWidth - 10)

            local thLabel, thMin, thMax, thStep
            if isSeconds then
                thLabel = L["Expiring Threshold (seconds)"]
                thMin, thMax, thStep = 1, 60, 1
                local cur = proxy.expireThreshold
                if cur and cur > 60 then proxy.expireThreshold = 5 end
            else
                thLabel = L["Expiring Threshold (%)"]
                thMin, thMax, thStep = 5, 100, 5
                local cur = proxy.expireThreshold
                if cur and cur < 5 then proxy.expireThreshold = 30 end
            end

            local thSlider = GUI:CreateSlider(threshContainer, thLabel, thMin, thMax, thStep, proxy, "expireThreshold")
            thSlider:SetPoint("TOPLEFT", 0, 0)
            thSlider:SetWidth(contentWidth - 10)

            local thModeBtn = CreateFrame("Button", nil, threshContainer, "BackdropTemplate")
            thModeBtn:SetSize(56, 18)
            thModeBtn:SetPoint("BOTTOMRIGHT", thSlider, "TOPRIGHT", -10, 2)

            local thModeText = thModeBtn:CreateFontString(nil, "OVERLAY")
            GUI:SetSettingsFont(thModeText, 9, "")
            thModeText:SetPoint("CENTER", 0, 0)
            thModeText:SetText(isSeconds and L["Seconds"] or L["Percent"])
            thModeText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            -- Shared styler (rest + accent-wash hover). Two-state mode toggle;
            -- mark active on Seconds (page rebuilds on click).
            GUI:StyleButton(thModeBtn)
            thModeBtn:SetActive(isSeconds)

            thModeBtn:HookScript("OnEnter", function(self)
                GUI:ShowTooltip(self, {
                    title = L["Threshold Mode"],
                    lines = {
                        isSeconds and L["Currently: Seconds. Click for Percent."] or L["Currently: Percent. Click for Seconds."],
                    },
                })
            end)
            thModeBtn:HookScript("OnLeave", function()
                GUI:HideTooltip()
            end)
            thModeBtn:SetScript("OnClick", function()
                if proxy.expireThresholdMode == "SECONDS" then
                    proxy.expireThresholdMode = "PERCENT"
                    proxy.expireThreshold = 30
                else
                    proxy.expireThresholdMode = "SECONDS"
                    proxy.expireThreshold = 5
                end
                DF:AuraDesigner_RefreshPage()
            end)

            g:AddWidget(threshContainer, 54)

            -- Play Once toggle
            local playOnceOn = proxy.expirePlayOnce == true
            local playOnceCB = GUI:CreateCheckbox(parent, L["Play Once"], proxy, "expirePlayOnce", function()
                DF:AuraDesigner_RefreshPage()
            end)
            g:AddWidget(playOnceCB, 28)

            -- Expire loop interval (greyed out when Play Once is enabled)
            if proxy.expireLoopInterval == nil then proxy.expireLoopInterval = 3 end
            local expireLoopSlider = GUI:CreateSlider(parent, L["Loop Interval (seconds)"], 1, 30, 0.5, proxy, "expireLoopInterval")
            g:AddWidget(expireLoopSlider, 54)

            -- Grey out expire sub-controls when expire alert is disabled.
            -- Loop interval is also greyed when Play Once is enabled.
            if not expireOn then
                thSlider:SetAlpha(0.4)
                thSlider:EnableMouse(false)
                thModeBtn:SetAlpha(0.4)
                thModeBtn:EnableMouse(false)
                playOnceCB:SetAlpha(0.4)
                playOnceCB:EnableMouse(false)
                expireLoopSlider:SetAlpha(0.4)
                expireLoopSlider:EnableMouse(false)
            elseif playOnceOn then
                expireLoopSlider:SetAlpha(0.4)
                expireLoopSlider:EnableMouse(false)
            end
        end)
    end

    -- ============================================================
    -- 12.1 AURA-SYSTEM STATUS OVERLAYS (P4.7 GUI pass)
    -- Frost the AD effect-settings the 12.1 Blizzard aura system can't drive.
    -- Every block gates on DF:FactoryOwnsAD(d). Only
    -- the settings GROUPS built above are targeted — the trigger tags (the
    -- working "which aura" layer) live in `parent` above `startY` and are left
    -- alone. "roadmap" = temporary (delete the single call site when the port
    -- lands); "limitation" = permanent (secret-value casualty).
    -- ============================================================
    local ADgate = function(d) return DF:FactoryOwnsAD(d) end

    local function BlockGroups(wording, idBase)
        for _, g in ipairs(builtGroups) do
            GUI:BlockControl12_1(g, wording, { id = idBase, page = L["Aura Designer"], when = ADgate })
        end
    end

    if typeKey == "icon" or typeKey == "square" then
        -- P4.3/P4.5 SHIPPED: icon/square render on the container engine (native icon / solid
        -- fill + cooldown + stacks + border + position), AND Show When Missing now renders via
        -- the read-free missing-mode container (static spell icon / colour square while absent).
        -- The whole-type roadmap and the Show-When-Missing roadmap overlays are gone. Two
        -- surgical blocks remain:
        --   * Expiring — permanent limitation. The whole group (Expiring Colour Override /
        --     colour-swap, pulse / bounce / whole-alpha-pulse, threshold, duration priority)
        --     is remaining-time-driven, which is unreadable on the container path.
        if expiringGroup then
            GUI:BlockControl12_1(expiringGroup, "limitation",
                { id = "ad:" .. typeKey .. ":expiring", page = L["Aura Designer"], when = ADgate })
        end
        --   * Min Stacks to Show — permanent limitation. Stack counts render on the native
        --     no-formatter path (a formatter would receive the SECRET application count and
        --     trap — see Features/Auras.lua's stacks-formatter warning), so a custom minimum
        --     other than the native "shown at >1" is not expressible. Frosted rather than
        --     removed: the stored stackMinimum key stays, in case a future API allows it.
        if stackMinCtl then
            GUI:BlockControl12_1(stackMinCtl, "limitation",
                { id = "ad:" .. typeKey .. ":stackmin", page = L["Aura Designer"], when = ADgate })
        end
        --   * Duration "Colour by Time" — P4.4 SHIPPED: the duration text now colours by
        --     time via the native bucket formatter (C-side |c escapes), so the roadmap
        --     overlay is gone and the control is fully editable under the factory.
    elseif typeKey == "bar" then
        -- P4.4 SHIPPED: the bar renders on the container engine (native SetDurationBar fill
        -- + texture/colour/orientation + border + duration text). The whole-type roadmap
        -- overlay is gone. One surgical block remains:
        --   * Expiring — permanent limitation. The whole group (Bar "Color by Time"/FILL
        --     colour-by-time, Expiring Colour Override, Expiring Tint, threshold) is
        --     remaining-time-driven, which is unreadable on the container path. (The
        --     DURATION-TEXT colour-by-time lives in the separate Duration Text group and
        --     stays editable — it ports via the bucket formatter, same as icon/square.)
        if expiringGroup then
            GUI:BlockControl12_1(expiringGroup, "limitation",
                { id = "ad:bar:expiring", page = L["Aura Designer"], when = ADgate })
        end
    elseif typeKey == "sound" then
        -- P4.5 SHIPPED: the sound indicator plays natively ON APPLY via
        -- C_UnitAuras.AddAuraAppliedSound (read-free, on-apply only). The whole-type roadmap
        -- overlay is gone; the Sound Alert group (sound picker / volume / preview) stays
        -- editable. Two surgical limitation blocks — both need a read the container path can't do:
        --   * Missing Trigger — "alert WHILE the buff is absent" is presence-driven (present-vs-
        --     total count) plus loop/delay timing. The native hook fires only ON GAIN, never on
        --     absence. → permanent limitation.
        --   * Expire Alert — "alert as the buff FADES" is remaining-time-driven; there is no
        --     AuraRemovedSound / on-fade native hook. → permanent limitation.
        -- (Per-play VOLUME is also unexpressible on the native path — it plays at the output
        -- channel's volume — but the slider still drives the Preview button, so it is left live.)
        if missingTriggerGroup then
            GUI:BlockControl12_1(missingTriggerGroup, "limitation",
                { id = "ad:sound:missing", page = L["Aura Designer"], when = ADgate })
        end
        if expireAlertGroup then
            GUI:BlockControl12_1(expireAlertGroup, "limitation",
                { id = "ad:sound:expire", page = L["Aura Designer"], when = ADgate })
        end
    elseif typeKey == "framealpha" then
        -- Permanent: whole-frame alpha needs frame:SetAlpha gated on secret presence
        -- and collides with the range/OOR alpha owners — the whole effect is unavailable.
        BlockGroups("limitation", "ad:framealpha")
    elseif typeKey == "nametext" or typeKey == "healthtext" then
        -- RECOVERED (colour-by-cover): the base Color works — the Text Designer keeps a
        -- glyph-identical coloured cover in sync with the real element (Render mirrors)
        -- and the aura slot's secret visibility shows it on presence. Two surgical blocks:
        --   * Show When Missing — unsupported for text covers (drawing the cover in
        --     present-mode would invert the intent; a text missing-window is future work).
        if swmCheck then
            GUI:BlockControl12_1(swmCheck, "limitation",
                { id = "ad:" .. typeKey .. ":swm", page = L["Aura Designer"], when = ADgate })
        end
        --   * Expiring — permanent limitation (the colour swap near expiry needs
        --     remaining-time, unreadable on the container path).
        if expiringGroup then
            GUI:BlockControl12_1(expiringGroup, "limitation",
                { id = "ad:" .. typeKey .. ":expiring", page = L["Aura Designer"], when = ADgate })
        end
    elseif typeKey == "healthbar" or typeKey == "background" or typeKey == "border" then
        -- Base effect settings (colour / mode / style) work on the container
        -- engine. Two surgical blocks on top:
        --   * Expiring — permanent limitation (near-expiry pulse / colour-swap /
        --     alpha ramp all need remaining-time, impossible read-free).
        if expiringGroup then
            GUI:BlockControl12_1(expiringGroup, "limitation",
                { id = "ad:" .. typeKey .. ":expiring", page = L["Aura Designer"], when = ADgate })
        end
        --   * Show When Missing — P4.5 SHIPPED: the effect now renders via the read-free
        --     missing-mode container (tint / ring shown while the buff is absent), so the
        --     roadmap overlay is gone and the checkbox is fully editable under the factory.
        --   * Tint Entire Bar (healthbar only) — NO LONGER blocked. The filled health-mirror
        --     bar makes the current-health-fill variant (tintWholeBar=false) expressible
        --     read-free, so both settings work under the factory.
        --   * Gradient border style — permanent limitation (degrades to solid on
        --     secret-anchored slots). Blocks only the gradient pickers/direction,
        --     which surface under Border Style = Gradient; Solid/Texture stay usable.
        if typeKey == "border" and borderCtl then
            for _, wKey in ipairs({ "gradientStart", "gradientEnd", "gradientDirection" }) do
                if borderCtl[wKey] then
                    GUI:BlockControl12_1(borderCtl[wKey], "limitation",
                        { id = "ad:border:gradient", page = L["Aura Designer"], when = ADgate })
                end
            end
        end
    end

    totalHeight = totalHeight + 8  -- bottom padding
    parent:SetHeight(totalHeight)
    return widgets, totalHeight
end

-- ============================================================
-- GLOBAL VIEW (used by Global tab)
-- ============================================================

-- Hardcoded fallbacks for global defaults (used when profile is missing new keys)
local GLOBAL_DEFAULTS_FALLBACK = {
    iconSize = 24, iconScale = 1.0,
    showDuration = true, showStacks = true,
    durationFont = "Friz Quadrata TT", durationScale = 1.0,
    durationOutline = "OUTLINE", durationAnchor = "CENTER",
    durationX = 0, durationY = 0, durationColorByTime = false,
    durationColor = {r = 1, g = 1, b = 1, a = 1},
    durationHideAboveEnabled = false, durationHideAboveThreshold = 10,
    stackFont = "Friz Quadrata TT", stackScale = 1.0,
    stackOutline = "OUTLINE", stackAnchor = "BOTTOMRIGHT",
    stackX = 0, stackY = 0,
    stackColor = {r = 1, g = 1, b = 1, a = 1},
    iconBorderEnabled = true, iconBorderThickness = 1,
    stackMinimum = 2,
    hideSwipe = false, hideIcon = false,
}

local function BuildGlobalView(parent)
    local adDB = GetAuraDesignerDB()
    local rawDefaults = adDB.defaults
    -- Proxy so every write triggers a full preview rebuild
    -- (global defaults affect ALL indicators, need full teardown/rebuild)
    -- Falls back to GLOBAL_DEFAULTS_FALLBACK for keys missing from existing profiles.
    -- __dfDefaults exposes the fallback table to GUI:CreateColorPicker's Default button.
    local defaults = setmetatable({ _skipOverrideIndicators = true, __dfDefaults = GLOBAL_DEFAULTS_FALLBACK }, {
        __index = function(_, k)
            local v = rawDefaults[k]
            if v ~= nil then return v end
            return GLOBAL_DEFAULTS_FALLBACK[k]
        end,
        __newindex = function(_, k, v)
            rawDefaults[k] = v
            RefreshPlacedIndicators()
            RefreshPreviewEffects()
            RefreshLiveFramesThrottled()
        end,
    })

    local parentW = parent:GetWidth()
    if parentW < 50 then parentW = 280 end
    local contentWidth = parentW - 16  -- 8px padding each side
    local totalHeight = 8
    local widgets = {}
    local function RPL() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end

    local function AddWidget(widget, height)
        widget:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -totalHeight)
        if widget.SetWidth then widget:SetWidth(contentWidth - 10) end
        tinsert(widgets, widget)
        totalHeight = totalHeight + (height or 30)
    end

    local function AddGroup(header, buildFn)
        local group = GUI:CreateSettingsGroup(parent, contentWidth - 10)
        group.padding = 6
        group:AddWidget(GUI:CreateHeader(parent, header), 25)
        buildFn(group)
        local h = group:LayoutChildren()
        AddWidget(group, h)
    end

    -- ── GENERAL ──
    AddGroup(L["General"], function(g)
        g:AddWidget(GUI:CreateSlider(parent, L["Default Icon Size"], 8, 64, 1, defaults, "iconSize"), 50)
        g:AddWidget(GUI:CreateSlider(parent, L["Default Scale"], 0.5, 3.0, 0.05, defaults, "iconScale"), 50)
        g:AddWidget(GUI:CreateSlider(parent, L["Default Frame Level"], -10, 30, 1, defaults, "indicatorFrameLevel"), 50)
        g:AddWidget(GUI:CreateDropdown(parent, L["Default Frame Strata"], OPTS.FRAME_STRATA_OPTIONS, defaults, "indicatorFrameStrata"), 50)
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
                if not adDB.soundEnabled and DF.AuraDesigner.SoundEngine then
                    DF.AuraDesigner.SoundEngine:StopAll()
                end
            end), 24)
        g:AddWidget(GUI:CreateDropdown(parent, L["Channel"], SOUND_CHANNELS,
            nil, nil, nil,
            function() return (GetAuraDesignerDB().soundChannel) or "Master" end,  -- customGet
            function(key) GetAuraDesignerDB().soundChannel = key end), 50)         -- customSet
    end)

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
                DF:Debug("Aura Designer: Imported Buffs tab defaults")
                importBtn.Text:SetText(L["Imported!"])
                C_Timer.After(1.5, function() importBtn.Text:SetText(L["Import Buffs Tab Defaults"]) end)
                DF:AuraDesigner_RefreshPage()
            end
        end)
        g:AddWidget(importBtn, 32)
    end)

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
        descText:SetText(L["Standard buff visibility is managed on the Aura Filters page."])
        descText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        g:AddWidget(descFrame, 24)

        local filtersBtn = GUI:CreateButton(parent, L["Aura Filters"], 140, 22, function()
            if GUI.SelectTab and GUI.Pages and GUI.Pages["auras_filters"] then
                GUI.SelectTab("auras_filters")
            end
        end)
        if not (GUI.Pages and GUI.Pages["auras_filters"]) then
            filtersBtn:Disable()
            filtersBtn.Text:SetTextColor(0.4, 0.4, 0.4)
        end
        g:AddWidget(filtersBtn, 28)
    end)

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
            -- BASE resolvers: this page edits the user's BASE presets — with a
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
            DF:Debug("Aura Designer: Copied " .. srcMode .. " settings to " .. dstMode)
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
                            DF:Debug("Aura Designer: Reset all aura configurations")
                        end,
                    },
                    { label = L["Cancel"] },
                },
            })
        end)
        g:AddWidget(resetBtn, 32)
    end)

    parent:SetHeight(totalHeight + 10)
end

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
    -- page build; the spec dropdown moved onto the B2 main tab strip). Sound
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

    local adDB = GetAuraDesignerDB()
    cb:SetChecked(adDB and adDB.enabled)

    cb:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        if checked then
            -- Show popup asking about buff coexistence
            ShowBuffCoexistPopup(function(keepBuffs)
                GetAuraDesignerDB().enabled = true
                db.showBuffs = keepBuffs
                DF:AuraDesigner_RefreshPage()
                DF:InvalidateAuraLayout()
                DF:UpdateAllFrames()
                if DF.AuraDesigner and DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end
            end, function()
                -- Cancelled — revert checkbox
                self:SetChecked(false)
            end)
        else
            GetAuraDesignerDB().enabled = false
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

-- ============================================================
-- SPEC DROPDOWN (B2: relocated from the enable banner onto the
-- main tab strip's right end — it only applies to My Buffs; the
-- Other Buffs tab greys it with a "shared across specs" caption)
-- ============================================================

local function CreateSpecDropdown(parent)
    -- Spec selector. Ported to the shared GUI:CreateDropdown (inline mode, so the
    -- container is just the opener button — the "Spec:" label beside it is
    -- hand-placed by the page build). optionsFunc rebuilds the list each open so
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
            -- floating trigger picker — its rows captured the OLD spec's
            -- effect record at open time (same staleness as a tab switch).
            wipe(expandedCards)
            HideTriggerPicker()
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



-- ============================================================
-- FRAME PREVIEW
-- Mock unit frame with health bar, power bar, name, health %,
-- and 9 anchor point dots for indicator placement
-- ============================================================

local function CreateFramePreview(parent, yOffset, rightPanelRef)
    -- Read current frame settings for the preview
    local mode = (GUI and GUI.SelectedMode) or "party"
    local frameDB = DF:GetDB(mode) or DF.PartyDefaults
    local FRAME_W = frameDB.frameWidth or 125
    local FRAME_H = frameDB.frameHeight or 64
    local POWER_H = frameDB.powerBarHeight or 4
    local showPower = frameDB.showPowerBar

    -- Preview scale from AD settings
    local adDB = GetAuraDesignerDB()
    local previewScale = adDB.previewScale or 1.0

    -- Outer container with label
    local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    local INSTR_COUNT = 3  -- number of instruction rows
    local INSTR_ROW_H = 18
    local rightInset = rightPanelRef and (rightPanelRef:GetWidth() + 6) or 0
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    container:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -rightInset, yOffset)
    container:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
    container:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -rightInset, 0)
    -- Dark bg + DIM border (matches Text Designer; no solid white outline).
    ApplyBackdrop(container, {r = 0.10, g = 0.10, b = 0.10, a = 1}, {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5})
    -- Apply the subtle spec class-color hint immediately. CreateFramePreview runs
    -- on every page build — including a party/raid rebuild (page:Refresh always
    -- rebuilds) — so without this the new preview falls back to the dim default
    -- border until the next AuraDesigner_RefreshPage (spec change / tab revisit).
    local cbSpec = ResolveSpec()
    local cbInfo = cbSpec and DF.AuraDesigner.SpecInfo and DF.AuraDesigner.SpecInfo[cbSpec]
    local cbColor = cbInfo and cbInfo.class and RAID_CLASS_COLORS[cbInfo.class]
    if cbColor then
        container:SetBackdropBorderColor(cbColor.r, cbColor.g, cbColor.b, 0.5)
    end

    -- "Frame Preview" label
    local previewLabel = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    previewLabel:SetPoint("TOPLEFT", 8, -4)
    previewLabel:SetText(L["FRAME PREVIEW"])
    previewLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    -- Mock unit frame (centered in container)
    local mockFrame = CreateFrame("Frame", nil, container, "BackdropTemplate")
    mockFrame:SetSize(FRAME_W, FRAME_H)
    mockFrame:SetPoint("CENTER", container, "CENTER", 0, -4)
    mockFrame:SetScale(previewScale)
    ApplyBackdrop(mockFrame, {r = 0.07, g = 0.07, b = 0.07, a = 1}, {r = 0.27, g = 0.27, b = 0.27, a = 1})
    container.mockFrame = mockFrame

    -- Resolve health texture
    local healthTexPath = frameDB.healthTexture or "Interface\\Buttons\\WHITE8x8"

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
                if dragHintText and dragState.auraInfo then
                    dragHintText:SetText(format(L["Place %s at %s"], dragState.auraInfo.display, capturedAnchorName))
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
                if dragHintText and dragState.auraInfo then
                    dragHintText:SetText(format(L["Drop on an anchor point to place %s"], dragState.auraInfo.display))
                    dragHintText:SetTextColor(tc.r, tc.g, tc.b, 0.9)
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

    -- Instructions with keyboard badge styling
    local instrRows = {
        { key = L["Click"],       desc = L["an indicator on the frame to expand its settings"] },
        { key = L["Drag"],        desc = L["a placed indicator to reposition it on the frame"] },
        { key = L["Right-click"], desc = L["a placed indicator to remove it from the frame"] },
    }

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
    local scaleSlider = GUI:CreateSlider(container, L["Preview Scale"], 0.75, 2.5, 0.05, adDB, "previewScale",
        -- callback (on release)
        function()
            local s = adDB.previewScale or 1.0
            mockFrame:SetScale(s)
        end,
        -- lightweightUpdate (during drag)
        function()
            local s = adDB.previewScale or 1.0
            mockFrame:SetScale(s)
        end
    )
    scaleSlider:SetPoint("TOPLEFT", previewLabel, "BOTTOMLEFT", -4, -4)
    scaleSlider:SetSize(220, 30)

    -- Drag-state hint text (shows contextual guidance during drag operations)
    dragHintText = container:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(dragHintText, 9, "OUTLINE")
    dragHintText:SetPoint("TOP", mockFrame, "BOTTOM", 0, -6)
    dragHintText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.8)
    dragHintText:SetText("")

    return container
end


-- ============================================================
-- TAB SYSTEM, SPELL PICKER & EFFECT CARDS (v4 redesign)
-- Functions for the new tabbed right panel, spell picker overlay,
-- and collapsible effect card rendering.
-- ============================================================

-- Forward declarations (mutually referencing functions)
local SwitchTab, ShowSpellPicker, HideSpellPicker
local BuildEffectsTab, BuildGlobalTab, BuildLayoutGroupsTab, BuildDebuffGroupsTab
local PopulateSpellGrid, CreateEffectCard

local spellPickerMode = "placed"   -- "placed" | "frame" | "group"
local spellPickerGroupID = nil     -- target layout group id ("group" mode only)
local spellPickerSearch = ""       -- lowercased name-search query (picker toolbar)
local spellPickerDirty = false     -- add-by-ID landed while the picker stayed open
                                   -- (effects tab behind it is stale; rebuilt on close)
local spellPickerBlockedIDs        -- spell ids tracked by the OPPOSITE pool (B2
                                   -- cross-tab block; rebuilt per PopulateSpellGrid)
local spellPickerBlockCache = {}   -- auraName -> bool memo over spellPickerBlockedIDs
                                   -- (wiped whenever the set is rebuilt) so search
                                   -- keystrokes don't re-resolve identity per card

-- Cross-tab used check for one picker candidate: any of its identity IDs
-- (nil-spec identity on the Other tab — the naming contract's resolver —
-- else the spec identity) already tracked by the opposite pool.
local function IsCandidateCrossBlocked(auraName, spec)
    if not spellPickerBlockedIDs or not next(spellPickerBlockedIDs) then return false end
    local cached = spellPickerBlockCache[auraName]
    if cached ~= nil then return cached end
    local blocked = false
    local f = DF:BuildADIdentityFilters(IsOtherTab() and nil or spec, auraName)
    local map = f and f.includeSpellIDs
    if map then
        for id in pairs(map) do
            if spellPickerBlockedIDs[id] then blocked = true; break end
        end
    end
    spellPickerBlockCache[auraName] = blocked
    return blocked
end

-- Check if a specific aura has a frame-level effect of given type
local function HasFrameEffect(auraName, typeKey)
    local auraCfg = CurrentAuraPool()[auraName]
    return auraCfg and auraCfg[typeKey] ~= nil
end

-- Clear all child frames and regions from the tab content area
local function ClearTabContent()
    if not tabContentFrame then return end
    local children = { tabContentFrame:GetChildren() }
    for _, child in ipairs(children) do
        child:Hide()
        child:ClearAllPoints()
    end
    local regions = { tabContentFrame:GetRegions() }
    for _, region in ipairs(regions) do
        region:Hide()
    end
end

-- ── HIDE SPELL PICKER ──
HideSpellPicker = function()
    if not spellPickerView then return end
    spellPickerActive = false
    spellPickerType = nil
    spellPickerGroupID = nil
    spellPickerBlockedIDs = nil  -- recomputed on next open (memo wiped with it)
    spellPickerView:Hide()
    if tabBar then tabBar:Show() end
    if tabScrollFrame then tabScrollFrame:Show() end
end

-- ── SHOW SPELL PICKER ──
-- typeKey: "icon"|"square"|"bar" (placed) or "border"|"healthbar"|etc. (frame);
--          nil in "group" mode (each card carries its own Icon/Square buttons)
-- mode: "placed" (default), "frame", or "group" (add members to a layout group)
-- groupID: target layout group id ("group" mode only)
ShowSpellPicker = function(typeKey, mode, groupID)
    if not spellPickerView then return end
    spellPickerActive = true
    spellPickerType = typeKey
    spellPickerMode = mode or "placed"
    spellPickerGroupID = groupID

    if tabBar then tabBar:Hide() end
    if tabScrollFrame then tabScrollFrame:Hide() end

    if spellPickerMode == "frame" then
        local effectLabel = FRAME_LEVEL_LABELS[typeKey] or typeKey
        spellPickerView.title:SetText(format(L["Select trigger for %s"], effectLabel))
    else -- "placed" and "group" share the generic title
        spellPickerView.title:SetText(L["Select a spell"])
    end

    if spellPickerMode == "group" then
        -- Badge shows the target group's name in the theme accent
        local grp = groupID and GetLayoutGroupByID(groupID)
        local tc = GetThemeColor()
        spellPickerView.typeBadge:SetText(grp and grp.name or "")
        spellPickerView.typeBadge:SetTextColor(tc.r, tc.g, tc.b)
    else
        local badgeColor = BADGE_COLORS[typeKey] or BADGE_COLORS.icon
        local typeLabel = PLACED_TYPE_LABELS[typeKey] or FRAME_LEVEL_LABELS[typeKey] or typeKey
        spellPickerView.typeBadge:SetText(typeLabel)
        spellPickerView.typeBadge:SetTextColor(badgeColor.r, badgeColor.g, badgeColor.b)
    end

    -- Mode-specific toolbar (group: Icon/Square buttons replace the Add button)
    -- and hint line (group cards add via their buttons, not click/drag)
    if spellPickerView.SetGroupToolbar then
        spellPickerView.SetGroupToolbar(spellPickerMode == "group")
    end
    if spellPickerView.hint then
        spellPickerView.hint:SetText(spellPickerMode == "group"
            and L["Click Icon or Square to add the spell to this group"]
            or L["Click or drag a spell onto the frame to place it"])
    end

    -- Fresh cross-tab block set per open (see PopulateSpellGrid): the memo
    -- over it then persists across search-keystroke repopulates.
    spellPickerBlockedIDs = CrossPoolTrackedIDs()
    wipe(spellPickerBlockCache)

    -- Fresh toolbar state per open: clear search/ID inputs and any echo.
    -- spellPickerSearch is reset BEFORE SetText so the OnTextChanged guard
    -- ("same query → return") skips a redundant PopulateSpellGrid pass.
    spellPickerSearch = ""
    spellPickerDirty = false
    if spellPickerView.searchBox and spellPickerView.searchBox.EditBox:GetText() ~= "" then
        spellPickerView.searchBox.EditBox:SetText("")
    end
    if spellPickerView.addBox then
        spellPickerView.addBox.EditBox:SetText("")
    end
    if spellPickerView.HideEcho then spellPickerView.HideEcho() end

    PopulateSpellGrid()
    spellPickerView:Show()
end

-- ── SWITCH TAB ──
SwitchTab = function(tabKey)
    -- Effects is frosted on the Debuffs tab (C2: category groups have no
    -- placed indicators) — coerce to Layout Groups (belt-and-braces; the
    -- sub-tab button is also frosted).
    if tabKey == "effects" and IsDebuffTab() then
        tabKey = "layout"
    end
    -- Preserve scroll position when refreshing the same tab
    local prevTab = activeTab
    local savedScroll = 0
    if tabKey == prevTab and tabScrollFrame then
        savedScroll = tabScrollFrame:GetVerticalScroll()
    end

    activeTab = tabKey
    if spellPickerActive then
        HideSpellPicker()
    end

    for key, btn in pairs(tabButtons) do
        btn:SetActive(key == tabKey)  -- underline + accent/dim label (tab mode)
    end

    ClearTabContent()

    if tabKey == "effects" then
        BuildEffectsTab()
    elseif tabKey == "layout" then
        -- The Debuffs tab's Layout Groups list shows ONLY debuff category
        -- groups; My Buffs / Other Buffs each build their OWN pool's
        -- member+filter groups (BuildLayoutGroupsTab is pool-routed).
        if IsDebuffTab() then
            BuildDebuffGroupsTab()
        else
            BuildLayoutGroupsTab()
        end
    elseif tabKey == "global" then
        BuildGlobalTab()
    end

    if tabScrollFrame then
        if tabKey == prevTab then
            -- Clamp to new max scroll range (content may have changed height)
            local maxScroll = tabScrollFrame:GetVerticalScrollRange()
            tabScrollFrame:SetVerticalScroll(min(savedScroll, maxScroll))
        else
            tabScrollFrame:SetVerticalScroll(0)
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

-- Grey the spec dropdown + swap its opener text on the Other and Debuffs
-- tabs (both pools are shared across specs); restore the live spec text on
-- My Buffs.
local function UpdateSpecDropdownState()
    if not specDropdown then return end
    if IsOtherTab() or IsDebuffTab() then
        if specDropdown.SetDisplayOverride then
            specDropdown:SetDisplayOverride(L["— (shared across specs)"])
        end
        specDropdown:SetEnabled(false)
    else
        specDropdown:SetEnabled(true)
        if specDropdown.SetDisplayOverride then
            specDropdown:SetDisplayOverride(nil)
        end
        if specDropdownUpdate then specDropdownUpdate() end
    end
end

local function SetMainTab(tabKey)
    if activeBuffTab == tabKey then return end
    activeBuffTab = tabKey
    -- Editor keys are pool-prefixed (B1) so cards can't collide across tabs,
    -- but mirror the spec dropdown's behavior: a pool switch collapses all
    -- expanded cards (wipe, not per-tab preservation).
    wipe(expandedCards)
    if spellPickerActive then HideSpellPicker() end
    -- The floating trigger picker captures its pool/effect at open time —
    -- never let it survive a pool switch.
    HideTriggerPicker()
    for key, btn in pairs(mainTabButtons) do
        btn:SetActive(key == tabKey)
    end
    UpdateSpecDropdownState()
    UpdateLayoutTabState()
    -- Effects is frosted on the Debuffs tab, so land on Layout Groups (the
    -- tab's primary surface). Layout Groups is live on both buff tabs — no
    -- coercion needed when arriving there.
    if activeBuffTab == "debuffs" and activeTab == "effects" then
        activeTab = "layout"
    end
    -- One entry point swaps every surface: RefreshPage → SwitchTab(activeTab)
    -- (list, chips, add menu) + RefreshPlacedIndicators/RefreshPreviewEffects
    -- (preview, drag targets) — all pool-routed through CurrentAuraPool.
    DF:AuraDesigner_RefreshPage()
end

-- ── ADD FROM PICKER (shared path) ──
-- What accepting a spell in the picker DOES: create the placed indicator
-- instance (or the frame-level type config) and pre-expand its effect card.
-- Used by both the spell-card OnClick and the add-by-ID toolbar so the two
-- entry points can never drift apart.
local function AddPickedSpell(auraName, typeKey)
    -- Card keys embed the B1 pool prefix in the name segment
    -- ("placed:other:<name>#<id>" / "frame:<type>:other:<name>").
    if spellPickerMode == "placed" then
        local instance = CreateIndicatorInstance(auraName, typeKey)
        if instance then
            expandedCards["placed:" .. PoolKeyPrefix() .. auraName .. "#" .. instance.id] = true
        end
    else
        EnsureTypeConfig(auraName, typeKey)
        expandedCards["frame:" .. typeKey .. ":" .. PoolKeyPrefix() .. auraName] = true
    end
end

-- ── ADD TO LAYOUT GROUP ("group" picker mode) ──
-- One click on a card's Icon/Square button (or the toolbar's, for add-by-ID):
-- create a NEW placed indicator of that type and enrol it in the target group.
-- The picker stays open for multi-add, and the same spell can be added again —
-- every add mints a fresh indicator id, so AddGroupMember's (auraName,
-- indicatorID) dedup never blocks it. skipEcho lets add-by-ID substitute its
-- own unknown-ID echo. Refresh chain mirrors the group card's member ✕.
local function AddSpellToGroup(auraName, display, typeKey, skipEcho)
    if not spellPickerGroupID then return end
    local instance = CreateIndicatorInstance(auraName, typeKey)
    if not instance then return end
    AddGroupMember(spellPickerGroupID, auraName, instance.id)
    spellPickerDirty = true  -- layout tab behind the picker is stale; rebuilt on back
    if not skipEcho and spellPickerView and spellPickerView.Echo then
        local typeLabel = PLACED_TYPE_LABELS[typeKey] or typeKey
        spellPickerView.Echo(format(L["Added %s."],
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

-- ── SPELL CARD POOL ──
-- The grid repopulates per search keystroke and per add-by-ID, and WoW
-- frames are never GC'd — so cards are POOLED (index-keyed on the grid,
-- FilterRegistry picker-row idiom): acquire-or-create with static handlers
-- reading per-bind fields, rebind content, hide surplus after populate.
local function AcquireSpellCard(grid, i)
    local pool = grid.cardPool
    if not pool then pool = {}; grid.cardPool = pool end
    local card = pool[i]
    if card then
        card:Show()
        return card
    end

    card = CreateFrame("Button", nil, grid, "BackdropTemplate")

    card.icon = card:CreateTexture(nil, "ARTWORK")
    card.icon:SetSize(42, 42)
    card.icon:SetPoint("TOP", 0, -6)

    -- Letter fallback (shown only when the bind has no icon texture)
    card.letter = card:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    card.letter:SetPoint("CENTER", card.icon, "CENTER", 0, 0)

    card.nameText = card:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(card.nameText, 8, "OUTLINE")
    card.nameText:SetPoint("BOTTOM", 0, 4)
    card.nameText:SetMaxLines(2)
    card.nameText:SetWordWrap(true)
    card.nameText:SetJustifyH("CENTER")

    -- "Placed" / "Active" overlay (shown only on used binds)
    card.usedLabel = card:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(card.usedLabel, 9, "OUTLINE")
    card.usedLabel:SetPoint("CENTER", card.icon, "CENTER", 0, 0)
    card.usedLabel:SetTextColor(0.6, 0.6, 0.6)

    -- Static handlers: all bind-varying state lives in card._* fields, so
    -- rebinding never stacks closures.
    card:SetScript("OnEnter", function(self)
        if not self._used then
            local tc = GetThemeColor()
            self:SetBackdropBorderColor(tc.r, tc.g, tc.b, 1)
        end
        if self._spellID and self._spellID > 0 then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetSpellByID(self._spellID)
            GameTooltip:Show()
        end
    end)
    card:SetScript("OnLeave", function(self)
        if not self._used then
            self:SetBackdropBorderColor(0.28, 0.28, 0.28, 1)
        end
        GameTooltip:Hide()
    end)
    card:SetScript("OnClick", function(self)
        if spellPickerMode == "group" then return end  -- group adds go through the type buttons
        if self._used or not self._auraInfo then return end
        AddPickedSpell(self._auraInfo.name, self._type)
        HideSpellPicker()
        SwitchTab("effects")
        RefreshPlacedIndicators()
        RefreshPreviewEffects()
    end)
    -- Placed indicators also support drag-and-drop onto the frame preview
    card:RegisterForDrag("LeftButton")
    card:SetScript("OnDragStart", function(self)
        if self._used or not self._auraInfo or spellPickerMode ~= "placed" then return end
        local spec = ResolveSpec()
        local auraInfo, typeKey = self._auraInfo, self._type
        HideSpellPicker()
        SwitchTab("effects")
        StartDrag(auraInfo.name, auraInfo, spec, typeKey)
    end)

    -- Group-mode action buttons (Icon / Square) at the card's bottom edge —
    -- shown only in "group" mode (BindSpellCard toggles them). Static
    -- handlers: the aura payload lives on the parent card, the type on the
    -- button. Same mini type-button look as the group card's member badges.
    local function MakeTypeButton(typeKey)
        local bc = BADGE_COLORS[typeKey] or BADGE_COLORS.icon
        local btn = CreateFrame("Button", nil, card, "BackdropTemplate")
        btn:SetSize(34, 16)
        ApplyBackdrop(btn,
            {r = bc.r * 0.15, g = bc.g * 0.15, b = bc.b * 0.15, a = 1},
            {r = bc.r * 0.4, g = bc.g * 0.4, b = bc.b * 0.4, a = 0.6})
        local lbl = btn:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(lbl, 7.5, "OUTLINE")
        lbl:SetPoint("CENTER", 0, 0)
        lbl:SetTextColor(bc.r, bc.g, bc.b)
        btn.label = lbl
        btn._typeKey = typeKey
        btn:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(bc.r, bc.g, bc.b, 1)
            lbl:SetTextColor(1, 1, 1)
        end)
        btn:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(bc.r * 0.4, bc.g * 0.4, bc.b * 0.4, 0.6)
            lbl:SetTextColor(bc.r, bc.g, bc.b)
        end)
        btn:SetScript("OnClick", function(self)
            local c = self:GetParent()
            -- _used is normally false in group mode (duplicates allowed), but
            -- the B2 cross-tab block sets it — those adds are blocked too.
            if not c._auraInfo or c._used then return end
            AddSpellToGroup(c._auraInfo.name, c._auraInfo.display, self._typeKey)
        end)
        btn:Hide()
        return btn
    end
    card.groupIconBtn = MakeTypeButton("icon")
    card.groupIconBtn:SetPoint("BOTTOMRIGHT", card, "BOTTOM", -2, 5)
    card.groupSquareBtn = MakeTypeButton("square")
    card.groupSquareBtn:SetPoint("BOTTOMLEFT", card, "BOTTOM", 2, 5)

    pool[i] = card
    return card
end

-- ── BIND SPELL CARD ──
-- Rebinds one pooled card to an aura entry: position, used-state styling,
-- icon/letter, name, warning badge, tooltip spell id, click/drag payload.
local function BindSpellCard(card, auraInfo, spec, x, y, CARD_SIZE, cardH)
    local isGroup = (spellPickerMode == "group")
    local alreadyUsed
    if isGroup then
        -- Duplicates are allowed (each add is its own indicator instance),
        -- so group-mode cards never dim to a used state.
        alreadyUsed = false
    elseif spellPickerMode == "placed" then
        alreadyUsed = IsAuraTypePlaced(auraInfo.name, spellPickerType)
    else
        alreadyUsed = HasFrameEffect(auraInfo.name, spellPickerType)
    end

    -- Cross-tab block (B2): a spell tracked by the OPPOSITE pool renders
    -- dimmed with a caption naming the other tab, and every add path is
    -- blocked (click AND drag ride the same _used flag). Applies in group
    -- mode too — group members are spec-pool indicators.
    local crossBlocked = IsCandidateCrossBlocked(auraInfo.name, spec)
    if crossBlocked then alreadyUsed = true end

    card:SetSize(CARD_SIZE, cardH or CARD_SIZE)
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", x, y)

    -- Group mode: taller card with an Icon/Square button row at the bottom;
    -- the name shifts up to sit above the buttons.
    card.groupIconBtn:SetShown(isGroup)
    card.groupSquareBtn:SetShown(isGroup)
    if isGroup then
        -- Labels re-set per bind so a locale refresh can't strand stale text
        card.groupIconBtn.label:SetText(PLACED_TYPE_LABELS.icon or "Icon")
        card.groupSquareBtn.label:SetText(PLACED_TYPE_LABELS.square or "Square")
    end
    card.nameText:ClearAllPoints()
    card.nameText:SetPoint("BOTTOM", 0, isGroup and 24 or 4)

    if alreadyUsed then
        ApplyBackdrop(card, {r = 0.10, g = 0.10, b = 0.10, a = 0.5}, {r = 0.20, g = 0.20, b = 0.20, a = 0.5})
    else
        ApplyBackdrop(card, {r = 0.14, g = 0.14, b = 0.14, a = 1}, {r = 0.28, g = 0.28, b = 0.28, a = 1})
    end

    -- Spell icon (color swatch + letter when no texture resolves)
    local iconTex = GetAuraIcon(spec, auraInfo.name)
    if iconTex then
        card.icon:SetTexture(iconTex)
        card.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        card.letter:Hide()
    else
        card.icon:SetColorTexture(auraInfo.color[1] * 0.4, auraInfo.color[2] * 0.4, auraInfo.color[3] * 0.4, 1)
        card.letter:SetText(auraInfo.display:sub(1, 1))
        card.letter:SetTextColor(auraInfo.color[1], auraInfo.color[2], auraInfo.color[3])
        card.letter:SetAlpha(alreadyUsed and 0.35 or 1)
        card.letter:Show()
    end
    card.icon:SetAlpha(alreadyUsed and 0.35 or 1)

    -- Warning badge for auras with API-level tracking limitations
    -- (rebind-safe: reuses card.dfWarningBadge, hides on nil warningKey)
    AttachWarningBadge(card, auraInfo.warningKey, {
        relativeTo = card.icon,
        size = 18,
    })

    card.nameText:SetWidth(CARD_SIZE - 6)
    card.nameText:SetText(auraInfo.display)
    card.nameText:SetTextColor(1, 1, 1)
    card.nameText:SetAlpha(alreadyUsed and 0.35 or 1)

    if crossBlocked then
        card.usedLabel:SetText(IsOtherTab() and L["In My Buffs"] or L["In Other Buffs"])
    else
        card.usedLabel:SetText(spellPickerMode == "placed" and L["Placed"] or L["Active"])
    end
    card.usedLabel:SetShown(alreadyUsed)

    -- Tooltip spell id (override table, else the spec whitelist, else the
    -- SpellDB pool entry's canonical id)
    local tooltipOverrides = DF.AuraDesigner.TooltipSpellIDs
    local spellIDs = DF.AuraDesigner.SpellIDs
    card._spellID = tooltipOverrides and tooltipOverrides[auraInfo.name]
        or spellIDs and spellIDs[spec] and spellIDs[spec][auraInfo.name]
        or auraInfo.spellID

    card._auraInfo = auraInfo
    card._type = spellPickerType
    card._used = alreadyUsed

    -- Re-assert the border color RAW: the hover handler tints it directly,
    -- so ApplyBackdrop's change-cache can hold a stale value for a card that
    -- was hovered when the grid repopulated. (Values match the cache, so the
    -- cache stays consistent.)
    if alreadyUsed then
        card:SetBackdropBorderColor(0.20, 0.20, 0.20, 0.5)
    else
        card:SetBackdropBorderColor(0.28, 0.28, 0.28, 1)
    end
end

-- ── SECTION HEADER POOL ──
-- Same index-keyed pooled-fontstring idiom as the card pool.
local function AcquireSectionHeader(grid, i)
    local pool = grid.headerPool
    if not pool then pool = {}; grid.headerPool = pool end
    local fs = pool[i]
    if fs then
        fs:Show()
        return fs
    end
    fs = grid:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    fs:SetJustifyH("LEFT")
    pool[i] = fs
    return fs
end

-- ── POPULATE SPELL GRID ──
PopulateSpellGrid = function()
    if not spellPickerView or not spellPickerView.gridFrame then return end
    local grid = spellPickerView.gridFrame

    -- Pooled widgets: track how many this pass uses, hide the surplus at the
    -- end (no per-populate frame creation past the pools' high-water mark).
    local usedCards, usedHeaders = 0, 0
    local function HideSurplus()
        if grid.cardPool then
            for j = usedCards + 1, #grid.cardPool do grid.cardPool[j]:Hide() end
        end
        if grid.headerPool then
            for j = usedHeaders + 1, #grid.headerPool do grid.headerPool[j]:Hide() end
        end
    end

    if grid.noResultsLabel then grid.noResultsLabel:Hide() end

    -- Cross-tab block set (B2): spells tracked by the OPPOSITE pool. Computed
    -- once per picker OPEN (ShowSpellPicker) — picker edits only mutate the
    -- ACTIVE pool, so the opposite pool can't change while it's open, and the
    -- per-candidate memo stays valid across search-keystroke repopulates.
    -- Lazy fallback for any populate outside the ShowSpellPicker flow.
    if not spellPickerBlockedIDs then
        spellPickerBlockedIDs = CrossPoolTrackedIDs()
        wipe(spellPickerBlockCache)
    end

    local spec = ResolveSpec()
    local isOtherPicker = IsOtherTab()
    local auras
    if isOtherPicker then
        -- Other Buffs picker: the FULL SpellDB pool, every class (grouped by
        -- class below, like the Filter Designer picker). Spec-independent.
        auras = Adapter.GetAllTrackableAuras and Adapter:GetAllTrackableAuras()
    else
        auras = spec and Adapter:GetTrackableAuras(spec)
    end
    if (not isOtherPicker and not spec) or not auras or #auras == 0 then
        HideSurplus()  -- nothing used: hides every pooled card/header
        -- Show unsupported spec message
        if not grid.unsupportedLabel then
            local label = grid:CreateFontString(nil, "OVERLAY", "DFFontNormal")
            label:SetPoint("TOP", grid, "TOP", 0, -40)
            label:SetWidth(grid:GetWidth() - 32)
            label:SetJustifyH("CENTER")
            label:SetTextColor(0.55, 0.55, 0.55, 1)
            label:SetText(L["No trackable spells found for this spec.\n\nYou can select a different spec using the dropdown above."])
            grid.unsupportedLabel = label
        end
        grid.unsupportedLabel:Show()
        return
    end
    -- Hide unsupported message if it was previously shown
    if grid.unsupportedLabel then grid.unsupportedLabel:Hide() end

    -- Group mode also offers configured ad-hoc "#<id>" auras (never in the
    -- trackable pool) — the dropdown this mode replaced did the same.
    if spellPickerMode == "group" then
        auras = WithConfiguredAdHocAuras(auras, spec)
    end

    local CARD_SIZE = 78
    -- Group-mode cards grow to fit the Icon/Square button row
    local CARD_H = (spellPickerMode == "group") and (CARD_SIZE + 20) or CARD_SIZE
    local CARD_GAP = 6
    local PADDING = 8
    local gridWidth = grid:GetWidth()
    if gridWidth < 100 then gridWidth = 260 end
    local cols = max(2, math.floor((gridWidth - PADDING * 2 + CARD_GAP) / (CARD_SIZE + CARD_GAP)))

    -- 12.1: every tracked aura renders through the game's native spell-ID
    -- matching -- the old whitelisted / inferred-tracking split is gone.
    -- My Buffs: two sections — the spec's class spells (curated entries carry
    -- no class field; SpellDB pool entries carry their class token), then the
    -- class="ALL" pool (consumables / trinkets).
    -- Other Buffs: one section PER CLASS (AD_CLASS_ORDER, class-coloured
    -- headers — the Filter Designer picker idiom), then the ALL pool.
    -- The toolbar search filters everything; a section whose every card is
    -- filtered out drops its header too.
    local q = spellPickerSearch
    local classAuras, allAuras = {}, {}
    local classBuckets = isOtherPicker and {} or nil
    for _, auraInfo in ipairs(auras) do
        if q == "" or (auraInfo.display or auraInfo.name):lower():find(q, 1, true) then
            if auraInfo.class == "ALL" or not auraInfo.class then
                allAuras[#allAuras + 1] = auraInfo
            elseif isOtherPicker then
                local bucket = classBuckets[auraInfo.class]
                if not bucket then bucket = {}; classBuckets[auraInfo.class] = bucket end
                bucket[#bucket + 1] = auraInfo
            else
                classAuras[#classAuras + 1] = auraInfo
            end
        end
    end

    local HEADER_H = 20
    local yOffset = 6  -- top pad

    local function RenderHeader(text, color)
        usedHeaders = usedHeaders + 1
        local header = AcquireSectionHeader(grid, usedHeaders)
        header:ClearAllPoints()
        header:SetPoint("TOPLEFT", PADDING, -yOffset)
        header:SetText(text)
        local c = color or C_TEXT
        header:SetTextColor(c.r, c.g, c.b)
        yOffset = yOffset + HEADER_H
    end

    local function RenderSection(list)
        local cardIndex = 0
        for _, auraInfo in ipairs(list) do
            local row = math.floor(cardIndex / cols)
            local col = cardIndex % cols
            local x = PADDING + col * (CARD_SIZE + CARD_GAP)
            local y = -(yOffset + row * (CARD_H + CARD_GAP))
            usedCards = usedCards + 1
            BindSpellCard(AcquireSpellCard(grid, usedCards), auraInfo, spec, x, y, CARD_SIZE, CARD_H)
            cardIndex = cardIndex + 1
        end
        yOffset = yOffset + math.ceil(cardIndex / cols) * (CARD_H + CARD_GAP)
    end

    local renderedAny = false
    if isOtherPicker then
        for _, classToken in ipairs(AD_CLASS_ORDER) do
            local bucket = classBuckets[classToken]
            if bucket and #bucket > 0 then
                if renderedAny then yOffset = yOffset + 8 end  -- section gap
                RenderHeader((LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classToken]) or classToken,
                    RAID_CLASS_COLORS[classToken])
                RenderSection(bucket)
                renderedAny = true
            end
        end
    elseif #classAuras > 0 then
        local info = DF.AuraDesigner.SpecInfo[spec]
        local classToken = info and info.class
        local className = classToken
            and ((LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classToken]) or classToken)
            or spec
        RenderHeader(format(L["Your Class — %s"], className),
            classToken and RAID_CLASS_COLORS[classToken] or nil)
        RenderSection(classAuras)
        renderedAny = true
    end
    if #allAuras > 0 then
        if renderedAny then yOffset = yOffset + 8 end  -- section gap
        RenderHeader(L["All Classes"], nil)
        RenderSection(allAuras)
        renderedAny = true
    end

    -- Active search matching nothing: say so instead of a blank panel
    if not renderedAny then
        if not grid.noResultsLabel then
            local label = grid:CreateFontString(nil, "OVERLAY", "DFFontNormal")
            label:SetPoint("TOP", grid, "TOP", 0, -40)
            label:SetTextColor(0.55, 0.55, 0.55, 1)
            label:SetText(L["No results found"])
            grid.noResultsLabel = label
        end
        grid.noResultsLabel:Show()
        yOffset = yOffset + 60
    end

    HideSurplus()
    grid:SetHeight(yOffset + PADDING)
end

-- ── CREATE EFFECT CARD ──
-- Creates a collapsible card for one effect in the effects list.
-- Returns the new yPos after the card.
CreateEffectCard = function(parent, yPos, effect)
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

    -- Card container
    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    card:SetPoint("TOPLEFT", 8, yPos)
    card:SetPoint("RIGHT", parent, "RIGHT", -8, 0)

    -- ── HEADER ──
    local header = CreateFrame("Button", nil, card, "BackdropTemplate")
    header:SetHeight(30)
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", 0, 0)
    ApplyBackdrop(header, C_ELEMENT, {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5})

    -- Chevron
    local chevron = header:CreateTexture(nil, "OVERLAY")
    chevron:SetSize(12, 12)
    chevron:SetPoint("LEFT", 8, 0)
    if isExpanded then
        chevron:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
    else
        chevron:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
    end
    chevron:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    -- Spell icon (small, before type badge). Other-pool records resolve
    -- icon/identity spec-independently (nil spec → ad-hoc / SpellDB fallback).
    local spec = IsOtherTab() and nil or ResolveSpec()
    local iconTex = GetAuraIcon(spec, effect.auraName)
    local spellIcon = header:CreateTexture(nil, "ARTWORK")
    spellIcon:SetSize(20, 20)
    spellIcon:SetPoint("LEFT", chevron, "RIGHT", 6, 0)
    if iconTex then
        spellIcon:SetTexture(iconTex)
        spellIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
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
        and (PLACED_TYPE_LABELS[effect.typeKey] or effect.typeKey)
        or (FRAME_LEVEL_LABELS[effect.typeKey] or effect.typeKey)

    local badgeBg = CreateFrame("Frame", nil, header, "BackdropTemplate")
    badgeBg:SetHeight(16)
    badgeBg:SetPoint("LEFT", spellIcon, "RIGHT", 4, 0)
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
            local auraCfg = CurrentAuraPool()[effect.auraName]
            local typeCfg = auraCfg and auraCfg[effect.typeKey]
            local opLabel = (typeCfg and typeCfg.triggerOperator == "AND") and (" (" .. L["AND"] .. ")") or ""
            infoStr = infoStr .. "  -  " .. format(L["+%d triggers"], #triggers - 1) .. opLabel
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
                    CleanupAdHocAura(effect.auraName)  -- drop emptied ad-hoc "#<id>" entries
                end
                expandedCards[cardKey] = nil
                SwitchTab("effects")
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
        local eyeBtn = CreateFrame("Button", nil, header)
        eyeBtn:SetSize(18, 18)
        if delBtn then
            eyeBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
        else
            eyeBtn:SetPoint("RIGHT", header, "RIGHT", -6, 0)
        end
        local eyeIcon = eyeBtn:CreateTexture(nil, "OVERLAY")
        eyeIcon:SetAllPoints()
        local function shown() return not cfgTable or cfgTable.enabled ~= false end
        local function updateEyeIcon()
            if shown() then
                eyeIcon:SetTexture(mediaPath .. "visibility")
                eyeIcon:SetVertexColor(0.95, 0.95, 0.95)
            else
                eyeIcon:SetTexture(mediaPath .. "visibility_off")
                eyeIcon:SetVertexColor(0.45, 0.45, 0.45)
            end
        end
        updateEyeIcon()
        eyeBtn:SetScript("OnEnter", function() if shown() then eyeIcon:SetVertexColor(1, 1, 1) end end)
        eyeBtn:SetScript("OnLeave", function() updateEyeIcon() end)
        eyeBtn:RegisterForClicks("LeftButtonUp")
        eyeBtn:SetFrameLevel(header:GetFrameLevel() + 2)
        eyeBtn:SetScript("OnClick", function()
            if not cfgTable then return end
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
            SwitchTab("effects")
            RefreshPlacedIndicators()
            RefreshPreviewEffects()
            DF:InvalidateAuraLayout()
            DF:UpdateAllFrames()
            if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end
        end)

        -- Hidden rows dim (name/icon), like Text Designer's disabled elements
        if not shown() then
            spellIcon:SetAlpha(0.4)
            infoText:SetAlpha(0.5)
        end
    end

    -- Header click → toggle expansion
    header:SetScript("OnClick", function()
        expandedCards[cardKey] = not expandedCards[cardKey]
        SwitchTab("effects")
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
        local bodyWidth = (tabContentFrame and tabContentFrame:GetWidth() or 260) - 24
        if bodyWidth < 100 then bodyWidth = 240 end

        local triggersH = 0

        -- ── TRIGGER TAGS (frame-level effects only) ──
        if not isPlaced then
            local triggers = GetFrameEffectTriggers(effect.auraName, effect.typeKey)
            local trigContainer = CreateFrame("Frame", nil, body)
            trigContainer:SetPoint("TOPLEFT", 8, -12)
            trigContainer:SetPoint("RIGHT", body, "RIGHT", -8, 0)

            local trigLabel = trigContainer:CreateFontString(nil, "OVERLAY")
            GUI:SetSettingsFont(trigLabel, 9, "")
            trigLabel:SetPoint("TOPLEFT", 0, 0)
            trigLabel:SetText(L["TRIGGERED BY"])
            trigLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

            -- AND/OR operator toggle (only shown with 2+ triggers)
            if #triggers > 1 then
                local auraCfgOp = CurrentAuraPool()[effect.auraName]
                local typeCfgOp = auraCfgOp and auraCfgOp[effect.typeKey]
                local isAnd = typeCfgOp and typeCfgOp.triggerOperator == "AND"

                local opBtn = CreateFrame("Button", nil, trigContainer, "BackdropTemplate")
                opBtn:SetHeight(18)
                opBtn:SetPoint("LEFT", trigLabel, "RIGHT", 6, 0)

                local opText = opBtn:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(opText, 9, "")
                opText:SetPoint("CENTER", 0, 0)
                opText:SetText(isAnd and L["ALL (AND)"] or L["ANY (OR)"])
                opText:SetTextColor(isAnd and 0.9 or 0.6, isAnd and 0.7 or 0.8, isAnd and 0.5 or 0.6)

                local opW = opText:GetStringWidth() + 16
                if opW < 52 then opW = 52 end
                opBtn:SetWidth(opW)
                -- Shared styler (rest + accent-wash hover). Two-state operator
                -- toggle; keep the custom AND/OR label colour (set above) and
                -- mark active on AND (row rebuilds on click).
                GUI:StyleButton(opBtn)
                opBtn:SetActive(isAnd)

                opBtn:HookScript("OnEnter", function(self)
                    GUI:ShowTooltip(self, {
                        title = isAnd and L["ALL triggers must be active"] or L["ANY trigger activates the effect"],
                        lines = {
                            { text = L["Click to toggle"], hint = true },
                        },
                    })
                end)
                opBtn:HookScript("OnLeave", function()
                    GUI:HideTooltip()
                end)
                opBtn:SetScript("OnClick", function()
                    local cfg = EnsureTypeConfig(effect.auraName, effect.typeKey)
                    if cfg.triggerOperator == "AND" then
                        cfg.triggerOperator = nil  -- OR is default
                    else
                        cfg.triggerOperator = "AND"
                    end
                    SwitchTab("effects")
                    RefreshPreviewEffects()
                end)

                -- P4.7 (12.1 limitation): the multi-trigger AND operator needs to
                -- evaluate every trigger together, which the 12.1 aura system can't
                -- do read-free for secret-anchored triggers. Frost the toggle (a
                -- hand-rolled button, so block it directly) — the trigger tags
                -- beside it stay editable. Gated on DF:FactoryOwnsAD, so legacy /
                -- 12.0.x is untouched. Permanent.
                GUI:BlockControl12_1(opBtn, "limitation", {
                    id   = "ad:trigger:operator",
                    page = L["Aura Designer"],
                    when = function(d) return DF:FactoryOwnsAD(d) end,
                })

            end

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

            -- Tag flow layout
            local TAG_H = 20
            local TAG_GAP = 4
            local TAG_ROW_GAP = 3
            local tagX, tagY = 0, -(14 + 6)  -- below label
            local canRemove = #triggers > 1

            for ti, trigName in ipairs(triggers) do
                local tagFrame = CreateFrame("Frame", nil, trigContainer, "BackdropTemplate")
                tagFrame:SetHeight(TAG_H)

                local tagText = tagFrame:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(tagText, 9, "")
                tagText:SetPoint("LEFT", 6, 0)
                tagText:SetText(displayNames[trigName] or trigName)
                tagText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

                local tagW = tagText:GetStringWidth() + 12
                if canRemove then tagW = tagW + 16 end  -- room for × button
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
                if canRemove then
                    local capturedTrigName = trigName
                    -- Shared red-at-rest "×" (tone="danger") on each removable tag.
                    local removeBtn = DF.GUI:CreateCloseButton(tagFrame, {
                        size = 14,
                        tone = "danger",
                        onClick = function()
                            RemoveFrameEffectTrigger(effect.auraName, effect.typeKey, capturedTrigName)
                            SwitchTab("effects")
                            RefreshPreviewEffects()
                        end,
                    })
                    removeBtn:SetPoint("RIGHT", -2, 0)
                end

                tagX = tagX + tagW + TAG_GAP
            end

            -- "+ Add Trigger" button
            local addTrigW = 80
            if tagX > 0 and (tagX + addTrigW) > (bodyWidth - 16) then
                tagX = 0
                tagY = tagY - (TAG_H + TAG_ROW_GAP)
            end
            local addTrigBtn = CreateFrame("Button", nil, trigContainer, "BackdropTemplate")
            addTrigBtn:SetPoint("TOPLEFT", trigContainer, "TOPLEFT", tagX, tagY)
            GUI:StyleButton(addTrigBtn, { width = addTrigW, height = TAG_H, primary = true, accent = { r = 0.25, g = 0.40, b = 0.25 }, icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\add", size = 11 }, text = L["Add Trigger"] })
            GUI:SetSettingsFont(addTrigBtn.Text, 9, "")
            addTrigBtn.Text:SetTextColor(0.5, 0.8, 0.5)
            addTrigBtn.Icon:SetVertexColor(0.5, 0.8, 0.5)

            -- Trigger picker dropdown
            addTrigBtn:SetScript("OnClick", function()
                -- Build dropdown with trackable auras not already in triggers
                -- (plus configured ad-hoc "#<id>" auras — never in the pool).
                -- Other Buffs (Phase B scoping): the full SpellDB would be
                -- unusable in this plain dropdown, so triggers are picked from
                -- the auras already CONFIGURED in the Other Buffs pool.
                local auraList
                if IsOtherTab() then
                    auraList = {}
                    for otherName in pairs(CurrentAuraPool()) do
                        tinsert(auraList, { name = otherName, display = OtherPoolDisplayName(otherName) })
                    end
                    sort(auraList, function(a, b) return (a.display or a.name) < (b.display or b.name) end)
                else
                    local spec2 = ResolveSpec()
                    auraList = spec2 and Adapter and Adapter:GetTrackableAuras(spec2)
                    if not auraList then return end
                    auraList = WithConfiguredAdHocAuras(auraList, spec2)
                end

                local currentTriggers = GetFrameEffectTriggers(effect.auraName, effect.typeKey)
                local trigLookup = {}
                for _, t in ipairs(currentTriggers) do trigLookup[t] = true end

                -- Pin the pool at OPEN time: the dropdown is parented to
                -- UIParent, so it can outlive a tab switch — the row OnClick
                -- must keep writing the trigger into the pool this card's
                -- record lives in (the record exists, so the read accessor
                -- returns the real table, never EMPTY_POOL).
                local capturedPool = CurrentAuraPool()

                -- Create or reuse dropdown frame (click-outside overlay + ESC
                -- close — the DFADFilterGroupPicker idiom)
                local dropName = "DFADTriggerPicker"
                local drop = _G[dropName]
                if not drop then
                    drop = CreateFrame("Frame", dropName, UIParent, "BackdropTemplate")
                    drop:SetFrameStrata("FULLSCREEN_DIALOG")
                    drop:SetClampedToScreen(true)
                    local overlay = CreateFrame("Button", nil, UIParent)
                    overlay:SetAllPoints(UIParent)
                    overlay:SetFrameStrata("FULLSCREEN")
                    overlay:Hide()
                    overlay:SetScript("OnClick", function()
                        drop:Hide()
                    end)
                    drop._overlay = overlay
                    drop:EnableKeyboard(true)
                    drop:SetPropagateKeyboardInput(true)
                    drop:SetScript("OnKeyDown", function(self, key)
                        if key == "ESCAPE" then
                            self:SetPropagateKeyboardInput(false)
                            self:Hide()
                        else
                            self:SetPropagateKeyboardInput(true)
                        end
                    end)
                    drop:SetScript("OnHide", function(self)
                        self._ownerBtn = nil
                        if self._overlay then self._overlay:Hide() end
                    end)
                end
                -- Hide if already showing for this button
                if drop:IsShown() and drop._ownerBtn == addTrigBtn then
                    drop:Hide()
                    return
                end
                drop._ownerBtn = addTrigBtn

                -- Clear children
                for _, child in ipairs({drop:GetChildren()}) do child:Hide(); child:SetParent(nil) end
                for _, rgn in ipairs({drop:GetRegions()}) do
                    if rgn:GetObjectType() == "FontString" then rgn:Hide() end
                end

                drop:SetWidth(180)
                ApplyBackdrop(drop, C_BACKGROUND, C_BORDER)

                local dy = -4
                local count = 0
                for _, auraInfo in ipairs(auraList) do
                    local alreadyAdded = trigLookup[auraInfo.name]
                    local btn = CreateFrame("Button", nil, drop)
                    btn:SetHeight(20)
                    btn:SetPoint("TOPLEFT", 4, dy)
                    btn:SetPoint("RIGHT", drop, "RIGHT", -4, 0)

                    local lbl = btn:CreateFontString(nil, "OVERLAY")
                    GUI:SetSettingsFont(lbl, 9, "")
                    lbl:SetPoint("LEFT", 6, 0)
                    lbl:SetText(auraInfo.display or auraInfo.name)
                    if alreadyAdded then
                        lbl:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.5)
                        btn:Disable()
                    else
                        lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
                        hl:SetAllPoints()
                        hl:SetColorTexture(1, 1, 1, 0.05)
                        local capturedName = auraInfo.name
                        btn:SetScript("OnClick", function()
                            AddFrameEffectTrigger(effect.auraName, effect.typeKey, capturedName, capturedPool)
                            drop:Hide()
                            SwitchTab("effects")
                            RefreshPreviewEffects()
                        end)
                    end
                    dy = dy - 20
                    count = count + 1
                end
                drop:SetHeight(-dy + 4)

                -- Position below the add button
                drop:ClearAllPoints()
                drop:SetPoint("TOPLEFT", addTrigBtn, "BOTTOMLEFT", 0, -2)
                drop:Show()
                if drop._overlay then drop._overlay:Show() end
            end)

            triggersH = -(tagY) + TAG_H + 8  -- total height of trigger section
            trigContainer:SetHeight(triggersH)

            -- Border mode toggle (border effects only)
            if effect.typeKey == "border" then
                local auraCfgBM = CurrentAuraPool()[effect.auraName]
                local typeCfgBM = auraCfgBM and auraCfgBM[effect.typeKey]
                local isCustom = typeCfgBM and typeCfgBM.borderMode == "custom"

                local bmContainer = CreateFrame("Frame", nil, body)
                bmContainer:SetPoint("TOPLEFT", body, "TOPLEFT", 8, -(triggersH + 10))
                bmContainer:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                bmContainer:SetHeight(26)

                local bmLabel = bmContainer:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(bmLabel, 9, "")
                bmLabel:SetPoint("LEFT", 0, 0)
                bmLabel:SetText(L["Border Mode:"])
                bmLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

                -- Shared button
                local sharedBtn = CreateFrame("Button", nil, bmContainer, "BackdropTemplate")
                sharedBtn:SetPoint("LEFT", bmLabel, "RIGHT", 6, 0)

                local sharedText = sharedBtn:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(sharedText, 9, "")
                sharedText:SetPoint("CENTER", 0, 0)
                sharedText:SetText(L["Shared"])
                local sharedW = sharedText:GetStringWidth() + 16
                if sharedW < 50 then sharedW = 50 end
                -- Shared styler: rest + accent-wash hover + SetActive selection state.
                -- Keep the manual (small) label; size to the computed text width.
                GUI:StyleButton(sharedBtn, { width = sharedW, height = 20 })

                -- Custom button
                local customBtn = CreateFrame("Button", nil, bmContainer, "BackdropTemplate")
                customBtn:SetPoint("LEFT", sharedBtn, "RIGHT", 4, 0)

                local customText = customBtn:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(customText, 9, "")
                customText:SetPoint("CENTER", 0, 0)
                customText:SetText(L["Custom"])
                local customW = customText:GetStringWidth() + 16
                if customW < 50 then customW = 50 end
                GUI:StyleButton(customBtn, { width = customW, height = 20 })

                -- Drive the selection state via the shared styler's SetActive (active =
                -- toned accent border + subtle accent fill). Keep a bright/dim label cue.
                local function StyleBorderModeButtons(customActive)
                    sharedBtn:SetActive(not customActive)
                    customBtn:SetActive(customActive)
                    if customActive then
                        customText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                        sharedText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                    else
                        sharedText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                        customText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                    end
                end
                StyleBorderModeButtons(isCustom)

                sharedBtn:SetScript("OnClick", function()
                    local cfg = EnsureTypeConfig(effect.auraName, effect.typeKey)
                    cfg.borderMode = nil  -- shared is default
                    SwitchTab("effects")
                    RefreshPreviewEffects()
                end)
                customBtn:SetScript("OnClick", function()
                    local cfg = EnsureTypeConfig(effect.auraName, effect.typeKey)
                    cfg.borderMode = "custom"
                    SwitchTab("effects")
                    RefreshPreviewEffects()
                end)

                -- Tooltips via HookScript so they compose with the styler's hover wash.
                sharedBtn:HookScript("OnEnter", function()
                    GUI:ShowTooltip(sharedBtn, {
                        title = L["Shared Border"],
                        lines = {
                            L["Uses a single border per frame. Highest priority wins."],
                        },
                    })
                end)
                sharedBtn:HookScript("OnLeave", function() GUI:HideTooltip() end)
                customBtn:HookScript("OnEnter", function()
                    GUI:ShowTooltip(customBtn, {
                        title = L["Custom Border"],
                        lines = {
                            L["Gets its own independent border overlay. Multiple custom borders can be visible at the same time."],
                        },
                    })
                end)
                customBtn:HookScript("OnLeave", function() GUI:HideTooltip() end)

                triggersH = triggersH + 36
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
            priSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 8, -(triggersH + 14))
            priSlider:SetWidth(bodyWidth - 16)
            -- Direction note in the standard GUI label style (dim, wrapped) so it
            -- matches every other settings note: HIGHER number = higher priority.
            local priNote = GUI:CreateLabel(body, L["Higher priority wins"], bodyWidth - 16)
            priNote:SetPoint("TOPLEFT", priSlider, "BOTTOMLEFT", 0, -2)
            triggersH = triggersH + 84
        end

        -- ── OTHERS ONLY (Other Buffs tab; placed AND frame-level effects) ──
        -- Not offered for sound: the on-apply sound path has no caster filter
        -- (the sound card carries an explanatory banner instead, see
        -- BuildTypeContent). Writes instance.othersOnly / typeCfg.othersOnly
        -- through the pool-pinned proxy; the filter string ("HELPFUL|!PLAYER")
        -- binds at container build, so toggling is STRUCTURAL (B1 folds it
        -- into every struct sig → the factory Rebuilds).
        if IsOtherTab() and effect.typeKey ~= "sound" then
            local ooCb = GUI:CreateCheckbox(body, L["Others Only"], proxy, "othersOnly", function()
                DF:AuraDesigner_RefreshPage()
                DF:InvalidateAuraLayout()
                DF:UpdateAllFrames()
                if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end
            end)
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
            SwitchTab("effects")
        end)

        local contentH = (bodyH or 50) + triggersH + collapseBarH
        body:SetHeight(contentH)
        totalCardH = totalCardH + contentH
    end

    card:SetHeight(totalCardH)
    return yPos - totalCardH - 5
end

-- ── BUILD EFFECTS TAB ──
BuildEffectsTab = function()
    if not tabContentFrame then return end
    local parent = tabContentFrame
    local yPos = -10
    local tc = GetThemeColor()

    -- "+ Add Indicator" button (prominent, theme-colored border)
    local addBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    addBtn:SetHeight(32)
    addBtn:SetPoint("TOPLEFT", 8, yPos)
    addBtn:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    -- Shared primary CTA: accent fill + white label via the styler (was a bespoke
    -- fontstring, which is why AD's and TD's hero labels didn't match).
    GUI:StyleButton(addBtn, { height = 32, primary = true, icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\add", size = 14 }, text = L["Add Indicator"], font = "DFFontHighlight" })

    -- Dropdown menu for add button
    local menuFrame = CreateFrame("Frame", nil, addBtn, "BackdropTemplate")
    menuFrame:SetPoint("TOPLEFT", addBtn, "BOTTOMLEFT", 0, -2)
    menuFrame:SetPoint("TOPRIGHT", addBtn, "BOTTOMRIGHT", 0, -2)
    menuFrame:SetFrameStrata("DIALOG")
    menuFrame:SetFrameLevel(100)
    ApplyBackdrop(menuFrame, {r = 0.10, g = 0.10, b = 0.10, a = 0.98}, C_BORDER)
    menuFrame:Hide()
    menuFrame:EnableMouse(true)

    local PLACED_ITEMS = {
        { label = L["Icon"],   type = "icon"   },
        { label = L["Square"], type = "square" },
        { label = L["Bar"],    type = "bar"    },
    }
    local FRAME_ITEMS = {
        { label = L["Border"],            type = "border"     },
        { label = L["Health Bar Color"],  type = "healthbar"  },
        { label = L["Background Color"],  type = "background" },
        { label = L["Name Text Color"],   type = "nametext"   },
        { label = L["Health Text Color"], type = "healthtext" },
        { label = L["Frame Alpha"],       type = "framealpha" },
        { label = L["Sound Alert"],       type = "sound"      },
    }

    local my = -4

    -- Section: Placed on Frame
    local placedHeader = menuFrame:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(placedHeader, 9, "")
    placedHeader:SetPoint("TOPLEFT", 10, my)
    placedHeader:SetText(L["PLACED ON FRAME"])
    placedHeader:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    my = my - 14

    for _, item in ipairs(PLACED_ITEMS) do
        local menuBtn = CreateFrame("Button", nil, menuFrame)
        menuBtn:SetHeight(24)
        menuBtn:SetPoint("TOPLEFT", 4, my)
        menuBtn:SetPoint("RIGHT", menuFrame, "RIGHT", -4, 0)
        local bc = BADGE_COLORS[item.type]
        local lbl = menuBtn:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(lbl, 10, "")
        lbl:SetPoint("LEFT", 8, 0)
        lbl:SetText(item.label)
        lbl:SetTextColor(bc.r, bc.g, bc.b)
        local hl = menuBtn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.05)
        local capturedType = item.type
        menuBtn:SetScript("OnClick", function()
            menuFrame:Hide()
            ShowSpellPicker(capturedType, "placed")
        end)
        my = my - 24
    end

    -- Divider
    my = my - 4
    local mdiv = menuFrame:CreateTexture(nil, "ARTWORK")
    mdiv:SetPoint("TOPLEFT", 8, my)
    mdiv:SetPoint("RIGHT", menuFrame, "RIGHT", -8, 0)
    mdiv:SetHeight(1)
    mdiv:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.6)
    my = my - 6

    -- Section: Frame-level Effects
    local frameHeader = menuFrame:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(frameHeader, 9, "")
    frameHeader:SetPoint("TOPLEFT", 10, my)
    frameHeader:SetText(L["FRAME-LEVEL EFFECTS"])
    frameHeader:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    my = my - 14

    for _, item in ipairs(FRAME_ITEMS) do
        local menuBtn = CreateFrame("Button", nil, menuFrame)
        menuBtn:SetHeight(24)
        menuBtn:SetPoint("TOPLEFT", 4, my)
        menuBtn:SetPoint("RIGHT", menuFrame, "RIGHT", -4, 0)
        local bc = BADGE_COLORS[item.type]
        local lbl = menuBtn:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(lbl, 10, "")
        lbl:SetPoint("LEFT", 8, 0)
        lbl:SetText(item.label)
        lbl:SetTextColor(bc.r, bc.g, bc.b)
        local hl = menuBtn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.05)
        local capturedType = item.type
        menuBtn:SetScript("OnClick", function()
            menuFrame:Hide()
            ShowSpellPicker(capturedType, "frame")
        end)
        my = my - 24
    end

    menuFrame:SetHeight(-my + 6)

    addBtn:SetScript("OnClick", function()
        if menuFrame:IsShown() then
            menuFrame:Hide()
        else
            menuFrame:Show()
        end
    end)

    yPos = yPos - 44

    -- ── ACTIVE INDICATORS heading ──
    local activeHeader = parent:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(activeHeader, 9, "")
    activeHeader:SetPoint("TOPLEFT", 8, yPos)  -- align with chips/cards/add button
    activeHeader:SetText(L["ACTIVE INDICATORS"])
    activeHeader:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    yPos = yPos - 16

    -- ── FILTER CHIPS (wrapping layout) ──
    local chipsFrame = CreateFrame("Frame", nil, parent)
    chipsFrame:SetPoint("TOPLEFT", 8, yPos)
    chipsFrame:SetPoint("RIGHT", parent, "RIGHT", -8, 0)

    local FILTER_CHIPS = {
        { key = "all",         label = L["All"]    },
        { key = "icon",        label = L["Icon"]   },
        { key = "square",      label = L["Square"] },
        { key = "bar",         label = L["Bar"]    },
        { key = "border",      label = L["Border"] },
        { key = "healthbar",   label = L["Health"] },
        { key = "nametext",    label = L["Name"]   },
        { key = "healthtext",  label = L["HP"]     },
        { key = "framealpha",  label = L["Alpha"]  },
    }

    local CHIP_H = 22
    local CHIP_GAP = 4
    local CHIP_ROW_GAP = 4
    local chipBtns = {}

    for _, chip in ipairs(FILTER_CHIPS) do
        local chipBtn = CreateFrame("Button", nil, chipsFrame, "BackdropTemplate")
        chipBtn:SetHeight(CHIP_H)

        local chipTxt = chipBtn:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(chipTxt, 10, "OUTLINE")
        chipTxt:SetPoint("CENTER", 0, 0)
        chipTxt:SetText(chip.label)
        chipTxt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

        local tw = chipTxt:GetStringWidth()
        chipBtn:SetWidth(max(tw + 16, 32))

        -- Shared styling: standard hover + an active (selected) state marked by a
        -- prominent accent border. The row rebuilds on click, so set active here.
        GUI:StyleButton(chipBtn)
        chipBtn:SetActive(activeFilter == chip.key)

        local capturedKey = chip.key
        chipBtn:SetScript("OnClick", function()
            activeFilter = capturedKey
            SwitchTab("effects")
        end)

        tinsert(chipBtns, chipBtn)
    end

    -- Flow-layout: position chips with wrapping on parent resize
    local function LayoutChips()
        local maxW = chipsFrame:GetWidth()
        if maxW < 20 then maxW = 260 end
        local cx, cy = 0, 0
        for _, btn in ipairs(chipBtns) do
            local bw = btn:GetWidth()
            if cx > 0 and (cx + bw) > maxW then
                cx = 0
                cy = cy - (CHIP_H + CHIP_ROW_GAP)
            end
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", chipsFrame, "TOPLEFT", cx, cy)
            cx = cx + bw + CHIP_GAP
        end
        chipsFrame:SetHeight(max(-cy + CHIP_H, CHIP_H))
    end
    LayoutChips()
    chipsFrame:SetScript("OnSizeChanged", LayoutChips)

    yPos = yPos - (chipsFrame:GetHeight() + 10)

    -- ── OTHER BUFFS HINT ──
    if IsOtherTab() then
        local obHint = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        obHint:SetPoint("TOPLEFT", 8, yPos)
        obHint:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
        obHint:SetJustifyH("LEFT")
        obHint:SetWordWrap(true)
        obHint:SetText(L["These indicators trigger no matter who casts the buff."])
        obHint:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.8)
        yPos = yPos - (max(obHint:GetStringHeight(), 12) + 10)
    end

    -- ── EFFECTS LIST ──
    local effects = CollectAllEffects()

    -- Apply filter
    local filtered = {}
    for _, effect in ipairs(effects) do
        if activeFilter == "all" or effect.typeKey == activeFilter then
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
        elseif activeFilter == "all" then
            empty:SetText(L["No effects configured yet.\nClick '+ Add Indicator' to get started."])
        else
            empty:SetText(format(L["No %s effects configured."], (PLACED_TYPE_LABELS[activeFilter] or FRAME_LEVEL_LABELS[activeFilter] or activeFilter)))
        end
        empty:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.7)
        empty:SetJustifyH("CENTER")
    else
        for _, effect in ipairs(filtered) do
            yPos = CreateEffectCard(parent, yPos, effect)
        end
    end

    parent:SetHeight(max(-yPos + 20, 200))
end

-- ── BUILD GLOBAL TAB ──
-- Wraps the existing BuildGlobalView into the tab content frame
BuildGlobalTab = function()
    if not tabContentFrame then return end
    BuildGlobalView(tabContentFrame)
end

-- ── BUILD LAYOUT GROUPS TAB ──
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
local function AddGroupAppearanceSection(body, group, bodyWidth, by, cardKey)
    local s = group.style
    if type(s) ~= "table" then s = {}; group.style = s end

    -- Defaults = today's uniform group rendering (Factory buildFilterGroupStyle's
    -- pre-style values) + the icon indicator's Border* seeds so CreateBorderControls
    -- reads sensible values on first open (ShowBorder overridden OFF — a group has
    -- no ring until the user enables one).
    local defaults = {
        hideSwipe = false, showDuration = true, showStacks = true,
        durationFont = "Friz Quadrata TT", durationScale = 1.0, durationOutline = "OUTLINE",
        durationAnchor = "CENTER", durationX = 0, durationY = 0,
        durationColorByTime = false, durationColor = { r = 1, g = 1, b = 1, a = 1 },
        durationHideAboveEnabled = false, durationHideAboveThreshold = 10,
        stackFont = "Friz Quadrata TT", stackScale = 1.0, stackOutline = "OUTLINE",
        stackAnchor = "BOTTOMRIGHT", stackX = 2, stackY = -1,
        stackColor = { r = 1, g = 1, b = 1, a = 1 },
        ShowBorder = false,
    }
    for k, v in pairs(TYPE_DEFAULTS.icon) do
        if k:find("^Border") and defaults[k] == nil then defaults[k] = v end
    end

    -- Defaults proxy (CreateInstanceProxy's idiom, group.style-backed): reads fall
    -- through to the defaults (table fallbacks copy-on-read so colour sub-key edits
    -- persist); writes land in group.style and refresh the live frames. The factory
    -- reads the RAW style table with the same defaults, so UI and render agree.
    local proxy = setmetatable({ _skipOverrideIndicators = true, __dfDefaults = defaults }, {
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

    -- Cosmetic edits hot-apply (coSig -> ApplyStyle); structural toggles move the
    -- struct sig -> Rebuild. Both ride the same throttled factory re-sync. The
    -- canvas placeholder's sample icons render the group style too, so every
    -- appearance edit re-draws them (RefreshPlacedIndicators — the same direct
    -- call the card's layout sliders run per edit/drag).
    local function refresh()
        RefreshPlacedIndicators()
        RefreshLiveFramesThrottled()
    end
    -- Visibility changes inside the section (border style dropdown swapping its
    -- widget set) re-measure heights, so rebuild the tab — the same full-rebuild
    -- the effect cards' dropdown callbacks run (AuraDesigner_RefreshPage).
    local function rebuildTab() SwitchTab("layout") end

    -- One collapsible box PER CATEGORY — the expanded effect card's section
    -- structure (Appearance / Border / Duration Text / Stack Count, same names
    -- and order as the icon card's AddGroup boxes; group-inapplicable sections
    -- — Position, Show When Missing, Expiring — have no group-level analogue).
    -- Collapse persists per card per section ("adGroupStyle:<cardKey>:<section>"),
    -- so each section toggles independently; the toggle rides the widget's
    -- built-in AuraDesigner_RefreshPage rebuild like the effect cards'.
    local function AddSection(header, sectionKey, buildFn)
        local g = GUI:CreateSettingsGroup(body, bodyWidth - 10, {
            collapsible = true,
            collapseKey = "adGroupStyle:" .. tostring(cardKey) .. ":" .. sectionKey,
        })
        g.padding = 6
        g:AddWidget(GUI:CreateHeader(body, header), 25)
        buildFn(g)
        local h = g:LayoutChildren()   -- includes the group's own bottom margin
        g:SetPoint("TOPLEFT", body, "TOPLEFT", 5, by)
        by = by - h
    end

    -- ── APPEARANCE ── (the effect card's Appearance box; of its controls only
    -- the swipe applies at group level — size/scale live in the card's layout
    -- sliders, alpha/level/strata/text-only are per-indicator concepts)
    AddSection(L["Appearance"], "appearance", function(g)
        g:AddWidget(GUI:CreateCheckbox(body, L["Hide Cooldown Swipe"], proxy, "hideSwipe", refresh), 28)
    end)

    -- ── BORDER ── (the placed icon's control set; gradient degrades to solid on
    -- container slots — same known casualty as placed indicators; LCG glow types
    -- are excluded from the animation dropdown, mirror the placed border)
    AddSection(L["Border"], "border", function(g)
        GUI:CreateBorderControls(g, proxy, "", {
            parent  = body,
            include = {
                inset = true, offset = true, blendMode = true,
                gradient = true, shadow = true, alpha = true,
                animate = true,
            },
            animExcludeTypes = { PULSATE = true, CHASE = true, FLASH = true, PROC = true },
            fullUpdate    = refresh,
            lightUpdate   = refresh,
            lightColors   = refresh,
            refreshStates = rebuildTab,
            sizeMin = 1, sizeMax = 5, sizeStep = 1,
        })
    end)

    -- ── DURATION TEXT ── (shared text controls; keys mirror the placed cards')
    AddSection(L["Duration Text"], "duration", function(g)
        g:AddWidget(GUI:CreateCheckbox(body, L["Show Duration"], proxy, "showDuration", refresh), 28)
        GUI:CreateTextControls(g, proxy, "duration", {
            parent = body,
            include = { color = true },
            colorLabel = L["Duration Text Color"],
            colorDisableOn = function() return proxy.durationColorByTime and true or false end,
            onChange = refresh, onDrag = refresh,
        })
        g:AddWidget(GUI:CreateCheckbox(body, L["Color by Time Remaining"], proxy, "durationColorByTime", refresh), 28)
        local hideAboveSlider
        local function UpdateHideAboveState()
            if not hideAboveSlider then return end
            if proxy.durationHideAboveEnabled then
                hideAboveSlider:SetAlpha(1)
                hideAboveSlider:EnableMouse(true)
            else
                hideAboveSlider:SetAlpha(0.4)
                hideAboveSlider:EnableMouse(false)
            end
        end
        g:AddWidget(GUI:CreateCheckbox(body, L["Hide Duration Above Threshold"], proxy, "durationHideAboveEnabled", function()
            UpdateHideAboveState()
            refresh()
        end), 28)
        hideAboveSlider = GUI:CreateSlider(body, L["Hide Above (seconds)"], 1, 60, 1, proxy, "durationHideAboveThreshold", refresh, refresh, true)
        g:AddWidget(hideAboveSlider, 54)
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

    return by
end

BuildLayoutGroupsTab = function()
    if not tabContentFrame then return end
    local parent = tabContentFrame
    local yPos = -10
    local tc = GetThemeColor()

    -- Grow direction options
    local GROW_DIRECTIONS = {
        RIGHT = "Right", LEFT = "Left", UP = "Up", DOWN = "Down",
        _order = { "RIGHT", "LEFT", "UP", "DOWN" },
    }

    -- "+ Create Group" / "+ Filter Group" buttons (prominent, theme-colored).
    -- Left = classic member-arranger group; right = registry-linked filter group.
    local gc = { r = 0.91, g = 0.66, b = 0.25 }  -- Layout Groups tab color
    local addBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    addBtn:SetHeight(32)
    addBtn:SetPoint("TOPLEFT", 8, yPos)
    addBtn:SetPoint("TOPRIGHT", parent, "TOP", -2, yPos)
    GUI:StyleButton(addBtn, { height = 32, primary = true, accent = gc, text = L["+ Create Group"], font = "DFFontHighlight" })
    addBtn:SetScript("OnClick", function()
        local group = CreateLayoutGroup()
        if group then
            expandedGroups[GroupExpandKey(group.id)] = true
            SwitchTab("layout")
            RefreshPlacedIndicators()
        end
    end)

    local addFilterBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    addFilterBtn:SetHeight(32)
    addFilterBtn:SetPoint("TOPLEFT", parent, "TOP", 2, yPos)
    addFilterBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, yPos)
    GUI:StyleButton(addFilterBtn, { height = 32, primary = true, accent = gc, text = L["+ Filter Group"], font = "DFFontHighlight" })
    addFilterBtn:SetScript("OnClick", function()
        local group = CreateLayoutGroup(nil, "filter")
        if group then
            expandedGroups[GroupExpandKey(group.id)] = true
            SwitchTab("layout")
            RefreshPlacedIndicators()
        end
    end)
    yPos = yPos - 42

    -- ── LAYOUT GROUPS heading — mirrors the Effects tab's ACTIVE INDICATORS
    -- caption and the Text Designer's group caption so every list tab has one. ──
    local groupsHeader = parent:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(groupsHeader, 9, "")
    groupsHeader:SetPoint("TOPLEFT", 8, yPos)
    groupsHeader:SetText(L["LAYOUT GROUPS"])
    groupsHeader:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    yPos = yPos - 16

    -- Active tab's groups: the spec-keyed array on My Buffs, the flat
    -- spec-independent store on Other Buffs (read-only — visiting the tab
    -- never creates adDB.otherLayoutGroups; the add buttons do).
    local isOtherGroups = IsOtherTab()
    local groups = CurrentLayoutGroups()

    -- Display name lookup (My Buffs: the spec's trackable pool; Other Buffs:
    -- ad-hoc/SpellDB resolution — other-pool names aren't in a spec pool)
    local spec = ResolveSpec()
    local trackable = not isOtherGroups and spec and Adapter and Adapter:GetTrackableAuras(spec)
    local displayNames = {}
    if trackable then
        for _, info in ipairs(trackable) do
            displayNames[info.name] = info.display
        end
    end
    local function MemberDisplayName(auraName)
        if isOtherGroups then return OtherPoolDisplayName(auraName) end
        return displayNames[auraName] or auraName
    end

    if #groups == 0 then
        -- Empty state
        local empty = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        empty:SetPoint("TOP", parent, "TOP", 0, yPos - 30)
        empty:SetWidth(220)
        empty:SetText(L["No layout groups created yet.\nClick '+ Create Group' to get started."])
        empty:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.7)
        empty:SetJustifyH("CENTER")
    else
        -- Render group cards (expansion keys are pool-scoped — raw id on My
        -- Buffs, "othergroup:<id>" on Other; the id counters overlap)
        for _, group in ipairs(groups) do
            local expandKey = GroupExpandKey(group.id)
            local isExpanded = expandedGroups[expandKey] or false

            -- Card container
            local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
            card:SetPoint("TOPLEFT", 8, yPos)
            card:SetPoint("RIGHT", parent, "RIGHT", -8, 0)

            -- ── HEADER ──
            local header = CreateFrame("Button", nil, card, "BackdropTemplate")
            header:SetHeight(30)
            header:SetPoint("TOPLEFT", 0, 0)
            header:SetPoint("TOPRIGHT", 0, 0)
            ApplyBackdrop(header, C_ELEMENT, {r = gc.r * 0.35, g = gc.g * 0.35, b = gc.b * 0.35, a = 0.5})

            -- Chevron
            local chevron = header:CreateTexture(nil, "OVERLAY")
            chevron:SetSize(12, 12)
            chevron:SetPoint("LEFT", 8, 0)
            if isExpanded then
                chevron:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
            else
                chevron:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
            end
            chevron:SetVertexColor(gc.r, gc.g, gc.b)

            -- Group name
            local nameText = header:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            nameText:SetPoint("LEFT", chevron, "RIGHT", 6, 0)
            nameText:SetPoint("RIGHT", header, "RIGHT", -60, 0)
            nameText:SetMaxLines(1)
            local isFilterGroup = (group.kind == "filter")
            if isFilterGroup then
                local linkCount = 0
                local fsel = group.filterSelection
                if fsel then
                    for _ in pairs(fsel.presets or {}) do linkCount = linkCount + 1 end
                    for _ in pairs(fsel.customs or {}) do linkCount = linkCount + 1 end
                end
                local fgInfo = group.name .. "  -  " .. linkCount .. (linkCount ~= 1 and L[" filters"] or L[" filter"])
                -- Collapsed-state Others Only suffix — mirror the effect-card header
                if isOtherGroups and group.othersOnly then
                    fgInfo = fgInfo .. "  -  " .. L["Others Only"]
                end
                nameText:SetText(fgInfo)
            else
                local memberCount = group.members and #group.members or 0
                nameText:SetText(group.name .. "  -  " .. memberCount .. (memberCount ~= 1 and L[" indicators"] or L[" indicator"]))
            end
            nameText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

            -- Delete button
            local capturedGroupID = group.id
            local delBtn = GUI:CreateCloseButton(header, {
                size = 22,
                onClick = function()
                    DeleteLayoutGroup(capturedGroupID)
                    SwitchTab("layout")
                    RefreshPlacedIndicators()
                    -- Deleting a group deletes its member indicators — same
                    -- structural refresh as the effect-card delete / eye toggle.
                    DF:InvalidateAuraLayout()
                    DF:UpdateAllFrames()
                    if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                    end
                end,
            })
            delBtn:SetPoint("RIGHT", -4, 0)
            delBtn:SetFrameLevel(header:GetFrameLevel() + 2)

            -- Eye icon (visibility toggle) — filter groups only; same asset + toggle
            -- idiom as the effect-card eye (A3). enabled == false is hidden; nil/true
            -- = shown. Toggling is STRUCTURAL: the factory tears down / stands up the
            -- group container and the buff-row dedup union changes.
            if isFilterGroup then
                local mediaPath = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"
                local eyeBtn = CreateFrame("Button", nil, header)
                eyeBtn:SetSize(18, 18)
                eyeBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
                local eyeIcon = eyeBtn:CreateTexture(nil, "OVERLAY")
                eyeIcon:SetAllPoints()
                local function shown() return group.enabled ~= false end
                local function updateEyeIcon()
                    if shown() then
                        eyeIcon:SetTexture(mediaPath .. "visibility")
                        eyeIcon:SetVertexColor(0.95, 0.95, 0.95)
                    else
                        eyeIcon:SetTexture(mediaPath .. "visibility_off")
                        eyeIcon:SetVertexColor(0.45, 0.45, 0.45)
                    end
                end
                updateEyeIcon()
                eyeBtn:SetScript("OnEnter", function() if shown() then eyeIcon:SetVertexColor(1, 1, 1) end end)
                eyeBtn:SetScript("OnLeave", function() updateEyeIcon() end)
                eyeBtn:RegisterForClicks("LeftButtonUp")
                eyeBtn:SetFrameLevel(header:GetFrameLevel() + 2)
                eyeBtn:SetScript("OnClick", function()
                    group.enabled = (group.enabled == false) and true or false
                    updateEyeIcon()
                    SwitchTab("layout")
                    RefreshPlacedIndicators()
                    DF:InvalidateAuraLayout()
                    DF:UpdateAllFrames()
                    if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                    end
                end)
                if not shown() then
                    nameText:SetAlpha(0.5)
                end
            end

            -- Header click → toggle expansion
            header:SetScript("OnClick", function()
                expandedGroups[expandKey] = not expandedGroups[expandKey]
                SwitchTab("layout")
            end)
            header:SetScript("OnEnter", function(self)
                self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
            end)
            header:SetScript("OnLeave", function(self)
                self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
            end)

            local totalCardH = 30

            -- ── BODY (when expanded) ──
            if isExpanded then
                local body = CreateFrame("Frame", nil, card, "BackdropTemplate")
                body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
                body:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
                ApplyBackdrop(body, {r = 0.09, g = 0.09, b = 0.09, a = 1},
                    {r = gc.r * 0.20, g = gc.g * 0.20, b = gc.b * 0.20, a = 0.3})

                local by = -10
                local bodyWidth = (tabContentFrame and tabContentFrame:GetWidth() or 260) - 24
                if bodyWidth < 100 then bodyWidth = 240 end

                -- Group Name (editable)
                local nameLabel = body:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(nameLabel, 8, "")
                nameLabel:SetPoint("TOPLEFT", 8, by)
                nameLabel:SetText(L["GROUP NAME"])
                nameLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 16

                local nameEdit = CreateFrame("EditBox", nil, body, "BackdropTemplate")
                nameEdit:SetHeight(22)
                nameEdit:SetPoint("TOPLEFT", 8, by)
                nameEdit:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                nameEdit:SetAutoFocus(false)
                nameEdit:SetText(group.name)
                nameEdit:SetMaxLetters(30)
                GUI:StyleEditBox(nameEdit, {})
                nameEdit:SetScript("OnEnterPressed", function(self)
                    local val = self:GetText()
                    if val and val ~= "" then
                        group.name = val
                    end
                    self:ClearFocus()
                    SwitchTab("layout")
                end)
                nameEdit:SetScript("OnEscapePressed", function(self)
                    self:SetText(group.name)
                    self:ClearFocus()
                end)
                by = by - 32

                if isFilterGroup then
                -- ── LINKED FILTERS SECTION (filter groups) ──
                -- One collapsed chip per linked registry filter: localized preset name
                -- (or custom filter name) + live spell count, remove ✕. Links are stable
                -- REFERENCES (preset keys / custom ids) — never copies — so filter edits
                -- propagate live. Link/unlink is structural (container rebuild + the
                -- buff-row dedup union moves), so run the full refresh path.
                local R = DF.FilterRegistry
                local fsel = group.filterSelection
                if not fsel then fsel = {}; group.filterSelection = fsel end
                fsel.presets = fsel.presets or {}
                fsel.customs = fsel.customs or {}

                local function StructuralFilterRefresh()
                    SwitchTab("layout")
                    RefreshPlacedIndicators()
                    DF:InvalidateAuraLayout()
                    DF:UpdateAllFrames()
                    if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                    end
                end

                local lfLabel = body:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(lfLabel, 8, "")
                lfLabel:SetPoint("TOPLEFT", 8, by)
                lfLabel:SetText(L["LINKED FILTERS"])
                lfLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 18

                -- Custom-filter spell count (curated spells + raw IDs)
                local function CustomFilterCount(cf)
                    local n = 0
                    if cf then
                        for _ in pairs(cf.spells or {}) do n = n + 1 end
                        for _ in pairs(cf.rawIDs or {}) do n = n + 1 end
                    end
                    return n
                end

                -- Linked list: presets in R.Categories order, then customs name-sorted.
                local linked = {}
                for _, cat in ipairs(R.Categories) do
                    if fsel.presets[cat.key] then
                        local enabled, total = R:PresetCounts(cat.key)
                        tinsert(linked, { kind = "preset", key = cat.key,
                            label = format("%s |cff888888(%d/%d)|r", L[cat.name], enabled, total) })
                    end
                end
                local linkedCustoms = {}
                for cfId in pairs(fsel.customs) do tinsert(linkedCustoms, cfId) end
                sort(linkedCustoms, function(a, b)
                    local fa, fb = R:GetCustomFilter(a), R:GetCustomFilter(b)
                    local na, nb = (fa and fa.name or ""), (fb and fb.name or "")
                    if na ~= nb then return na < nb end
                    return a < b
                end)
                for _, cfId in ipairs(linkedCustoms) do
                    local cf = R:GetCustomFilter(cfId)
                    tinsert(linked, { kind = "custom", key = cfId,
                        label = format("%s |cff888888(%d)|r", (cf and cf.name) or cfId, CustomFilterCount(cf)) })
                end

                if #linked > 0 then
                    for _, link in ipairs(linked) do
                        local chipRow = CreateFrame("Frame", nil, body, "BackdropTemplate")
                        chipRow:SetHeight(24)
                        chipRow:SetPoint("TOPLEFT", 8, by)
                        chipRow:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                        ApplyBackdrop(chipRow,
                            {r = 0.11, g = 0.11, b = 0.11, a = 1},
                            {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.3})

                        -- Remove ✕ (mirror the member-row remove idiom)
                        local remBtn = CreateFrame("Button", nil, chipRow)
                        remBtn:SetSize(18, 18)
                        remBtn:SetPoint("RIGHT", -4, 0)
                        local remIcon = remBtn:CreateTexture(nil, "OVERLAY")
                        remIcon:SetSize(12, 12)
                        remIcon:SetPoint("CENTER", 0, 0)
                        remIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\close")
                        remIcon:SetVertexColor(0.55, 0.30, 0.30, 1)
                        remBtn:SetScript("OnEnter", function() remIcon:SetVertexColor(1, 0.40, 0.40, 1) end)
                        remBtn:SetScript("OnLeave", function() remIcon:SetVertexColor(0.55, 0.30, 0.30, 1) end)
                        local capturedLink = link
                        remBtn:SetScript("OnClick", function()
                            if capturedLink.kind == "preset" then
                                fsel.presets[capturedLink.key] = nil
                            else
                                fsel.customs[capturedLink.key] = nil
                            end
                            StructuralFilterRefresh()
                        end)

                        local chipText = chipRow:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                        chipText:SetPoint("LEFT", 8, 0)
                        chipText:SetPoint("RIGHT", remBtn, "LEFT", -4, 0)
                        chipText:SetMaxLines(1)
                        chipText:SetJustifyH("LEFT")
                        chipText:SetText(link.label)
                        chipText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

                        by = by - 28
                    end
                else
                    local noLinks = body:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                    noLinks:SetPoint("TOPLEFT", 12, by)
                    noLinks:SetText(L["No filters linked yet"])
                    noLinks:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.6)
                    by = by - 20
                end

                -- "+ Add Filter" button → mini-picker of unlinked presets + customs
                by = by - 6
                local addFilterLinkBtn = CreateFrame("Button", nil, body, "BackdropTemplate")
                addFilterLinkBtn:SetHeight(22)
                addFilterLinkBtn:SetPoint("TOPLEFT", 8, by)
                addFilterLinkBtn:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                GUI:StyleButton(addFilterLinkBtn, { height = 22, primary = true, icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\add", size = 11 }, text = L["Add Filter"] })
                GUI:SetSettingsFont(addFilterLinkBtn.Text, 9, "")
                addFilterLinkBtn:SetScript("OnClick", function()
                    -- Build the unlinked candidate list: presets (Categories order,
                    -- live counts), then customs (name-sorted). No Uncategorised
                    -- option by design — a group must resolve to an include map.
                    local candidates = {}
                    for _, cat in ipairs(R.Categories) do
                        if not fsel.presets[cat.key] then
                            local enabled, total = R:PresetCounts(cat.key)
                            tinsert(candidates, { kind = "preset", key = cat.key,
                                label = format("%s |cff888888(%d/%d)|r", L[cat.name], enabled, total) })
                        end
                    end
                    local freeCustoms = {}
                    for cfId in pairs(R:GetStore().customFilters) do
                        if not fsel.customs[cfId] then tinsert(freeCustoms, cfId) end
                    end
                    sort(freeCustoms, function(a, b)
                        local fa, fb = R:GetCustomFilter(a), R:GetCustomFilter(b)
                        local na, nb = (fa and fa.name or ""), (fb and fb.name or "")
                        if na ~= nb then return na < nb end
                        return a < b
                    end)
                    for _, cfId in ipairs(freeCustoms) do
                        local cf = R:GetCustomFilter(cfId)
                        tinsert(candidates, { kind = "custom", key = cfId,
                            label = format("%s |c%s(%s)|r", (cf and cf.name) or cfId, GUI:ToneHex("info"), L["Custom"]) })
                    end

                    -- Create/reuse the picker dropdown (same overlay/ESC/scroll idiom
                    -- as the member picker above)
                    local dropName = "DFADFilterGroupPicker"
                    local drop = _G[dropName]
                    if not drop then
                        drop = CreateFrame("Frame", dropName, UIParent, "BackdropTemplate")
                        drop:SetFrameStrata("FULLSCREEN_DIALOG")
                        drop:SetClampedToScreen(true)
                        local overlay = CreateFrame("Button", nil, UIParent)
                        overlay:SetAllPoints(UIParent)
                        overlay:SetFrameStrata("FULLSCREEN")
                        overlay:Hide()
                        overlay:SetScript("OnClick", function()
                            drop:Hide()
                            overlay:Hide()
                        end)
                        drop._overlay = overlay
                        drop:EnableKeyboard(true)
                        drop:SetPropagateKeyboardInput(true)
                        drop:SetScript("OnKeyDown", function(self, key)
                            if key == "ESCAPE" then
                                self:SetPropagateKeyboardInput(false)
                                self:Hide()
                            else
                                self:SetPropagateKeyboardInput(true)
                            end
                        end)
                        drop:SetScript("OnHide", function(self)
                            self._ownerBtn = nil
                            if self._overlay then self._overlay:Hide() end
                        end)
                    end
                    if drop:IsShown() and drop._ownerBtn == addFilterLinkBtn then
                        drop:Hide()
                        return
                    end
                    drop._ownerBtn = addFilterLinkBtn

                    local DROP_W = 240
                    local MAX_H = 300
                    drop:SetWidth(DROP_W)
                    ApplyBackdrop(drop, C_BACKGROUND, C_BORDER)

                    if not drop._scrollFrame then
                        local sf = CreateFrame("ScrollFrame", nil, drop)
                        sf:SetPoint("TOPLEFT", 0, 0)
                        sf:SetPoint("BOTTOMRIGHT", 0, 0)
                        drop._scrollFrame = sf
                        local sc = CreateFrame("Frame", nil, sf)
                        sc:SetWidth(DROP_W)
                        sf:SetScrollChild(sc)
                        drop._scrollChild = sc
                        sf:SetScript("OnMouseWheel", function(self2, delta2)
                            local cur = self2:GetVerticalScroll()
                            local maxS = max(0, self2:GetVerticalScrollRange())
                            self2:SetVerticalScroll(max(0, min(maxS, cur - (delta2 * 24))))
                        end)
                    end
                    local scrollChild = drop._scrollChild
                    local scrollFrame = drop._scrollFrame
                    scrollChild:SetWidth(DROP_W)
                    for _, child in ipairs({scrollChild:GetChildren()}) do child:Hide(); child:SetParent(nil) end
                    for _, rgn in ipairs({scrollChild:GetRegions()}) do
                        if rgn:GetObjectType() == "FontString" or rgn:GetObjectType() == "Texture" then rgn:Hide() end
                    end
                    scrollFrame:Show()
                    scrollChild:EnableMouseWheel(true)
                    scrollChild:SetScript("OnMouseWheel", function(_, delta2)
                        scrollFrame:GetScript("OnMouseWheel")(scrollFrame, delta2)
                    end)

                    local dy2 = -4
                    if #candidates == 0 then
                        local none = scrollChild:CreateFontString(nil, "OVERLAY")
                        GUI:SetSettingsFont(none, 9, "")
                        none:SetPoint("TOPLEFT", 8, dy2 - 4)
                        none:SetText(L["No filters available"])
                        none:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.7)
                        dy2 = dy2 - 24
                    end
                    for _, cand in ipairs(candidates) do
                        local ROW_H = 24
                        local row = CreateFrame("Button", nil, scrollChild)
                        row:SetHeight(ROW_H)
                        row:SetPoint("TOPLEFT", 4, dy2)
                        row:SetPoint("RIGHT", scrollChild, "RIGHT", -4, 0)

                        local rName = row:CreateFontString(nil, "OVERLAY")
                        GUI:SetSettingsFont(rName, 9, "")
                        rName:SetPoint("LEFT", 8, 0)
                        rName:SetText(cand.label)
                        rName:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

                        local hl = row:CreateTexture(nil, "BACKGROUND")
                        hl:SetAllPoints()
                        hl:SetColorTexture(1, 1, 1, 0)
                        row:SetScript("OnEnter", function() hl:SetColorTexture(1, 1, 1, 0.03) end)
                        row:SetScript("OnLeave", function() hl:SetColorTexture(1, 1, 1, 0) end)

                        local capturedCand = cand
                        row:SetScript("OnClick", function()
                            if capturedCand.kind == "preset" then
                                fsel.presets[capturedCand.key] = true
                            else
                                fsel.customs[capturedCand.key] = true
                            end
                            drop:Hide()
                            StructuralFilterRefresh()
                        end)
                        dy2 = dy2 - ROW_H
                    end
                    local totalH = -dy2 + 4
                    scrollChild:SetHeight(totalH)
                    drop:SetHeight(math.min(totalH, MAX_H))

                    drop:ClearAllPoints()
                    drop:SetPoint("TOPLEFT", addFilterLinkBtn, "BOTTOMLEFT", 0, -2)
                    drop:Show()
                    if drop._overlay then drop._overlay:Show() end
                end)
                by = by - 26

                -- "Create Filter" → jump to the Filter Designer and pulse its
                -- New Filter button, for users who arrive here without a custom
                -- filter to link yet.
                local createFilterBtn = CreateFrame("Button", nil, body, "BackdropTemplate")
                createFilterBtn:SetHeight(22)
                createFilterBtn:SetPoint("TOPLEFT", 8, by)
                createFilterBtn:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                GUI:StyleButton(createFilterBtn, { height = 22, text = L["Create Filter"] })
                GUI:SetSettingsFont(createFilterBtn.Text, 9, "")
                createFilterBtn:SetScript("OnClick", function()
                    if GUI.SelectTab and GUI.Pages and GUI.Pages["auras_filterdesigner"] then
                        GUI.SelectTab("auras_filterdesigner")
                        -- Page content builds on first show (inside SelectTab), so
                        -- the button reference exists by now.
                        local fdPage = GUI.Pages["auras_filterdesigner"]
                        local newFilterBtn = fdPage and fdPage._fdNewFilterBtn
                        if newFilterBtn and DF.HighlightWidget then
                            DF:HighlightWidget(newFilterBtn)
                        end
                    end
                end)
                by = by - 28

                else
                -- ── MEMBERS SECTION ──
                local memLabel = body:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(memLabel, 8, "")
                memLabel:SetPoint("TOPLEFT", 8, by)
                memLabel:SetText(L["MEMBERS"])
                memLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 18

                if group.members and #group.members > 0 then
                    for mi, member in ipairs(group.members) do
                        local memberRow = CreateFrame("Frame", nil, body, "BackdropTemplate")
                        memberRow:SetHeight(34)
                        memberRow:SetPoint("TOPLEFT", 8, by)
                        memberRow:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                        ApplyBackdrop(memberRow,
                            {r = 0.11, g = 0.11, b = 0.11, a = 1},
                            {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.3})

                        -- Up/Down buttons for reordering (stacked vertically on left)
                        local canMoveUp = mi > 1
                        local canMoveDown = mi < #group.members
                        local capturedMi = mi

                        if canMoveUp then
                            local upBtn = CreateFrame("Button", nil, memberRow)
                            upBtn:SetSize(20, 16)
                            upBtn:SetPoint("TOPLEFT", 2, -1)
                            local upIcon = upBtn:CreateTexture(nil, "OVERLAY")
                            upIcon:SetSize(14, 14)
                            upIcon:SetPoint("CENTER", 0, 0)
                            upIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
                            upIcon:SetRotation(math.rad(180))  -- flip to point up
                            upIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                            upBtn:SetScript("OnClick", function()
                                SwapGroupMembers(capturedGroupID, capturedMi, capturedMi - 1)
                                SwitchTab("layout")
                                RefreshPlacedIndicators()
                                -- Positions moved (member index feeds the grid) — re-arrange live frames.
                                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                            end)
                            upBtn:SetScript("OnEnter", function() upIcon:SetVertexColor(1, 1, 1) end)
                            upBtn:SetScript("OnLeave", function() upIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b) end)
                        end
                        if canMoveDown then
                            local downBtn = CreateFrame("Button", nil, memberRow)
                            downBtn:SetSize(20, 16)
                            downBtn:SetPoint("BOTTOMLEFT", 2, 1)
                            local downIcon = downBtn:CreateTexture(nil, "OVERLAY")
                            downIcon:SetSize(14, 14)
                            downIcon:SetPoint("CENTER", 0, 0)
                            downIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
                            downIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                            downBtn:SetScript("OnClick", function()
                                SwapGroupMembers(capturedGroupID, capturedMi, capturedMi + 1)
                                SwitchTab("layout")
                                RefreshPlacedIndicators()
                                -- Positions moved (member index feeds the grid) — re-arrange live frames.
                                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                            end)
                            downBtn:SetScript("OnEnter", function() downIcon:SetVertexColor(1, 1, 1) end)
                            downBtn:SetScript("OnLeave", function() downIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b) end)
                        end

                        -- Spell icon (Other: nil spec — GetAuraIcon degrades to
                        -- ad-hoc "#<id>" / SpellDB-by-name resolution)
                        local memberSpec = not isOtherGroups and ResolveSpec() or nil
                        local memberIconTex = GetAuraIcon(memberSpec, member.auraName)
                        local mSpellIcon = memberRow:CreateTexture(nil, "ARTWORK")
                        mSpellIcon:SetSize(22, 22)
                        mSpellIcon:SetPoint("LEFT", 26, 0)
                        if memberIconTex then
                            mSpellIcon:SetTexture(memberIconTex)
                            mSpellIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                        else
                            -- Color swatch fallback
                            local auraInfo2 = nil
                            local trackable2 = memberSpec and Adapter and Adapter:GetTrackableAuras(memberSpec)
                            if trackable2 then
                                for _, ai in ipairs(trackable2) do
                                    if ai.name == member.auraName then auraInfo2 = ai; break end
                                end
                            end
                            if auraInfo2 then
                                mSpellIcon:SetColorTexture(auraInfo2.color[1] * 0.5, auraInfo2.color[2] * 0.5, auraInfo2.color[3] * 0.5, 1)
                            else
                                mSpellIcon:SetColorTexture(0.25, 0.25, 0.25, 1)
                            end
                        end

                        -- Type badge (members live in the group's pool = the
                        -- active tab's pool)
                        local memberType = nil
                        local memberAuraCfg = CurrentAuraPool()[member.auraName]
                        if memberAuraCfg and memberAuraCfg.indicators then
                            for _, ind in ipairs(memberAuraCfg.indicators) do
                                if ind.id == member.indicatorID then
                                    memberType = ind.type
                                    break
                                end
                            end
                        end
                        local mBadgeColor = BADGE_COLORS[memberType or "icon"] or BADGE_COLORS.icon
                        local mBadgeLabel = PLACED_TYPE_LABELS[memberType or "icon"] or "Icon"

                        local mBadge = CreateFrame("Frame", nil, memberRow, "BackdropTemplate")
                        mBadge:SetHeight(16)
                        mBadge:SetPoint("LEFT", mSpellIcon, "RIGHT", 4, 0)
                        ApplyBackdrop(mBadge,
                            {r = mBadgeColor.r * 0.20, g = mBadgeColor.g * 0.20, b = mBadgeColor.b * 0.20, a = 1},
                            {r = mBadgeColor.r * 0.45, g = mBadgeColor.g * 0.45, b = mBadgeColor.b * 0.45, a = 0.6})
                        local mBadgeText = mBadge:CreateFontString(nil, "OVERLAY")
                        GUI:SetSettingsFont(mBadgeText, 8, "OUTLINE")
                        mBadgeText:SetPoint("CENTER", 0, 0)
                        mBadgeText:SetText(mBadgeLabel)
                        mBadgeText:SetTextColor(1, 1, 1)
                        mBadge:SetWidth(max(mBadgeText:GetStringWidth() + 12, 32))

                        -- Remove button (using close icon)
                        local remBtn = CreateFrame("Button", nil, memberRow)
                        remBtn:SetSize(18, 18)
                        remBtn:SetPoint("RIGHT", -4, 0)
                        local remIcon = remBtn:CreateTexture(nil, "OVERLAY")
                        remIcon:SetSize(12, 12)
                        remIcon:SetPoint("CENTER", 0, 0)
                        remIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\close")
                        remIcon:SetVertexColor(0.55, 0.30, 0.30, 1)
                        remBtn:SetScript("OnEnter", function()
                            remIcon:SetVertexColor(1, 0.40, 0.40, 1)
                        end)
                        remBtn:SetScript("OnLeave", function()
                            remIcon:SetVertexColor(0.55, 0.30, 0.30, 1)
                        end)
                        local capturedMember = member
                        remBtn:SetScript("OnClick", function()
                            RemoveGroupMember(capturedGroupID, capturedMember.auraName, capturedMember.indicatorID)
                            -- Also delete the placed indicator itself
                            RemoveIndicatorInstance(capturedMember.auraName, capturedMember.indicatorID)
                            SwitchTab("layout")
                            RefreshPlacedIndicators()
                            RefreshPreviewEffects()
                            -- Structural change: same full refresh as the
                            -- effect-card ✕ / group delete (indicator removed).
                            DF:InvalidateAuraLayout()
                            DF:UpdateAllFrames()
                            if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                            end
                        end)

                        -- Customise button (navigates to Effects tab for this indicator)
                        -- Accent-tinted action button: persistent accent fill +
                        -- accent border + accent label at rest, accent-wash hover.
                        local custBtn = CreateFrame("Button", nil, memberRow, "BackdropTemplate")
                        custBtn:SetPoint("RIGHT", remBtn, "LEFT", -4, 0)
                        GUI:StyleButton(custBtn, {
                            width = 56, height = 18,
                            text = L["Customise"],
                            tinted = true,
                            accent = GetThemeColor(),
                        })
                        local capturedAuraName = member.auraName
                        local capturedIndID = member.indicatorID
                        custBtn:SetScript("OnClick", function()
                            -- Card keys embed the B1 pool prefix in the name
                            -- segment ("placed:other:<name>#<id>" on Other)
                            local cardKey = "placed:" .. PoolKeyPrefix() .. capturedAuraName .. "#" .. capturedIndID
                            wipe(expandedCards)
                            expandedCards[cardKey] = true
                            activeTab = "effects"
                            DF:AuraDesigner_RefreshPage()
                        end)

                        -- Aura name
                        local mName = memberRow:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                        mName:SetPoint("LEFT", mBadge, "RIGHT", 6, 0)
                        mName:SetPoint("RIGHT", custBtn, "LEFT", -4, 0)
                        mName:SetMaxLines(1)
                        mName:SetText(MemberDisplayName(member.auraName))
                        mName:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

                        by = by - 38
                    end
                else
                    local noMem = body:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                    noMem:SetPoint("TOPLEFT", 12, by)
                    noMem:SetText(L["No members yet"])
                    noMem:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.6)
                    by = by - 20
                end

                -- "+ Add aura" button
                by = by - 6
                local addMemBtn = CreateFrame("Button", nil, body, "BackdropTemplate")
                addMemBtn:SetHeight(22)
                addMemBtn:SetPoint("TOPLEFT", 8, by)
                addMemBtn:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                GUI:StyleButton(addMemBtn, { height = 22, primary = true, icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\add", size = 11 }, text = L["Add aura"] })
                GUI:SetSettingsFont(addMemBtn.Text, 9, "")
                addMemBtn:SetScript("OnClick", function()
                    -- Full spell picker in "group" mode: searchable class-grouped
                    -- grid + add-by-ID, each card carrying Icon/Square buttons
                    -- that create the indicator and enrol it in this group in
                    -- one click (replaces the old ad-hoc dropdown).
                    ShowSpellPicker(nil, "group", capturedGroupID)
                end)
                by = by - 28
                end -- isFilterGroup / members branch

                -- ── PLACEMENT SECTION ──
                by = by - 10
                local placeLabel = body:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(placeLabel, 8, "")
                placeLabel:SetPoint("TOPLEFT", 8, by)
                placeLabel:SetText(L["PLACEMENT"])
                placeLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 18

                -- Use GUI widgets with the group table as the proxy
                local anchorDrop = GUI:CreateDropdown(body, L["Anchor"], OPTS.ANCHOR_OPTIONS, group, "anchor", function()
                    RefreshPlacedIndicators()
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end)
                anchorDrop:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                if anchorDrop.SetWidth then anchorDrop:SetWidth(bodyWidth - 10) end
                by = by - 54

                local oxSlider = GUI:CreateSlider(body, L["Offset X"], -150, 150, 1, group, "offsetX", function()
                    RefreshPlacedIndicators()
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end, function()
                    RefreshPlacedIndicators()
                end)
                oxSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                if oxSlider.SetWidth then oxSlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                local oySlider = GUI:CreateSlider(body, L["Offset Y"], -150, 150, 1, group, "offsetY", function()
                    RefreshPlacedIndicators()
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end, function()
                    RefreshPlacedIndicators()
                end)
                oySlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                if oySlider.SetWidth then oySlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                -- ── GROWTH SECTION ──
                by = by - 10
                local growLabel = body:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(growLabel, 8, "")
                growLabel:SetPoint("TOPLEFT", 8, by)
                growLabel:SetText(L["GROWTH"])
                growLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 18

                -- Auto-migrate legacy single-direction values to new format
                local gd = group.growDirection or "RIGHT"
                if not gd:find("_") then
                    local LEGACY_MAP = { RIGHT = "RIGHT_DOWN", LEFT = "LEFT_DOWN", UP = "UP_RIGHT", DOWN = "DOWN_RIGHT" }
                    group.growDirection = LEGACY_MAP[gd] or "RIGHT_DOWN"
                end

                local growthControl = GUI:CreateGrowthControl(body, group, "growDirection", function()
                    RefreshPlacedIndicators()
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end)
                growthControl:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                if growthControl.SetWidth then growthControl:SetWidth(bodyWidth - 10) end
                by = by - 158

                local iprSlider = GUI:CreateSlider(body, L["Icons Per Row"], 1, 20, 1, group, "iconsPerRow", function()
                    RefreshPlacedIndicators()
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end, function()
                    RefreshPlacedIndicators()
                end)
                iprSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                if iprSlider.SetWidth then iprSlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                local spacingSlider = GUI:CreateSlider(body, L["Spacing"], -5, 20, 1, group, "spacing", function()
                    RefreshPlacedIndicators()
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end, function()
                    RefreshPlacedIndicators()
                end)
                spacingSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                if spacingSlider.SetWidth then spacingSlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                if isFilterGroup then
                    -- Uniform per-group styling: one icon size + slot cap for every
                    -- spell the linked filters match (no per-spell styling by design).
                    local sizeSlider = GUI:CreateSlider(body, L["Icon Size"], 8, 64, 1, group, "iconSize", function()
                        RefreshPlacedIndicators()
                        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                    end, function()
                        RefreshPlacedIndicators()
                    end)
                    sizeSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                    if sizeSlider.SetWidth then sizeSlider:SetWidth(bodyWidth - 10) end
                    by = by - 54

                    -- Max Icons is STRUCTURAL (slot count is declared at container
                    -- build) — the factory Rebuild path handles it (OOC-deferred).
                    local maxSlider = GUI:CreateSlider(body, L["Max Icons"], 1, 20, 1, group, "maxIcons", function()
                        RefreshPlacedIndicators()
                        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                    end, function()
                        RefreshPlacedIndicators()
                    end)
                    maxSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                    if maxSlider.SetWidth then maxSlider:SetWidth(bodyWidth - 10) end
                    by = by - 54

                    -- ── OTHERS ONLY (Other Buffs tab only — flat-store groups) ──
                    -- Same idiom as the effect-card checkbox: the group's filter
                    -- string ("HELPFUL|!PLAYER") binds at container build, so
                    -- toggling is STRUCTURAL (folded into the fgroup struct sig →
                    -- the factory Rebuilds), and the buff-row dedup union moves
                    -- (an othersOnly group's spells keep their row icon).
                    if isOtherGroups then
                        local ooCb = GUI:CreateCheckbox(body, L["Others Only"], group, "othersOnly", function()
                            SwitchTab("layout")
                            RefreshPlacedIndicators()
                            DF:InvalidateAuraLayout()
                            DF:UpdateAllFrames()
                            if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                            end
                        end)
                        ooCb:SetPoint("TOPLEFT", body, "TOPLEFT", 8, -(-by))
                        ooCb:SetWidth(bodyWidth - 16)
                        ooCb.tooltip = L["Only show other players' casts of these buffs."]
                        by = by - 34
                    end

                    -- ── APPEARANCE (collapsible — the effect-card section idiom) ──
                    by = by - 10
                    by = AddGroupAppearanceSection(body, group, bodyWidth, by, expandKey)
                end

                local bodyH = -by + 12
                body:SetHeight(bodyH)
                totalCardH = totalCardH + bodyH
            end

            card:SetHeight(totalCardH)
            yPos = yPos - totalCardH - 5
        end
    end

    parent:SetHeight(max(-yPos + 20, 200))
end

-- ============================================================
-- DEBUFFS TAB — DEBUFF CATEGORY GROUPS (C2)
-- Each card owns a SELECTION of the native 12.1 debuff categories (checkbox
-- picker reusing the Aura Filters debuff column's controls) plus the shared
-- filter-group layout controls. Groups are spec-independent
-- (adDB.debuffGroups; lazily created on the first add — visiting the tab
-- writes nothing). Categories claimed by an enabled group are dropped from
-- the main debuff bar (C1 row-claim dedup), so EVERY selection / eye /
-- delete / add edit runs the FULL structural chain: InvalidateAuraLayout
-- bumps the version the row's claim fold AND the factory's dgroup record
-- cache re-resolve on; UpdateAllFrames + ForceRefreshAllFrames re-drive the
-- live frames and AD containers. Card keys are "dgroup:<id>" in
-- expandedGroups — layout-group cards key by raw numeric id, so the string
-- prefix can never collide with them (the two id counters overlap).
-- ============================================================

BuildDebuffGroupsTab = function()
    if not tabContentFrame then return end
    local parent = tabContentFrame
    local yPos = -10
    local gc = { r = 0.91, g = 0.66, b = 0.25 }  -- Layout Groups tab accent

    -- Category picker rows: the Aura Filters debuff column's exact L keys +
    -- tooltips, mapped onto group.selection's keys. Built per tab build so a
    -- runtime locale overlay is picked up (file-scope L tables freeze enUS).
    local CATEGORY_DEFS = {
        { key = "boss",         label = L["Boss Debuffs"],        tooltip = L["Debuffs applied by dungeon and raid bosses."] },
        { key = "role",         label = L["Role Debuffs"],        tooltip = L["Debuffs Blizzard flags as important for your role."] },
        { key = "priority",     label = L["Priority Debuffs"],    tooltip = L["Debuffs Blizzard flags as high priority."] },
        { key = "crowdControl", label = L["Crowd Control"],       tooltip = L["CC effects like stuns, roots, and incapacitates."] },
        { key = "raid",         label = L["Raid Debuffs"],        tooltip = L["Other debuffs Blizzard flags for raid frames."] },
        { key = "dispellable",  label = L["Dispellable Debuffs"], tooltip = L["Debuffs that can be dispelled. Use the toggle below to choose which dispels count."] },
    }

    -- FULL structural refresh incl. tab rebuild — discrete edits (category
    -- checkboxes, dispel mode, hide-long controls, eye, delete, add): the
    -- claims union moves AND the card summary / grey states must rebuild.
    local function StructuralDebuffGroupRefresh()
        SwitchTab("layout")
        RefreshPlacedIndicators()
        DF:InvalidateAuraLayout()
        DF:UpdateAllFrames()
        if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
            DF.AuraDesigner.Engine:ForceRefreshAllFrames()
        end
    end

    -- Same structural chain WITHOUT the tab rebuild — slider/dropdown-safe
    -- (a SwitchTab from inside a slider callback destroys the widget
    -- mid-interaction). Layout edits don't move the claims union, but the
    -- version bump keeps the factory's version-keyed dgroup record cache
    -- honest and costs one sig-gated re-resolve (offsets → ApplyStyle,
    -- maxIcons → Rebuild).
    local function LayoutDebuffGroupRefresh()
        RefreshPlacedIndicators()
        DF:InvalidateAuraLayout()
        DF:UpdateAllFrames()
        if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
            DF.AuraDesigner.Engine:ForceRefreshAllFrames()
        end
    end

    -- "+ Debuff Group" (prominent, tab accent — mirrors "+ Create Group").
    -- The debuffGroups array is born lazily on this first add.
    local addBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    addBtn:SetHeight(32)
    addBtn:SetPoint("TOPLEFT", 8, yPos)
    addBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, yPos)
    GUI:StyleButton(addBtn, { height = 32, primary = true, accent = gc, text = L["+ Debuff Group"], font = "DFFontHighlight" })
    addBtn:SetScript("OnClick", function()
        local group = CreateDebuffGroup()
        if group then
            expandedGroups["dgroup:" .. group.id] = true
            -- A new group claims Boss + Role by default, so the main debuff
            -- bar drops them immediately: full structural chain, not just a
            -- tab rebuild.
            StructuralDebuffGroupRefresh()
        end
    end)
    yPos = yPos - 42

    -- Dedup explainer (§11.1 mock): how the row-claim handoff behaves.
    local dedupHint = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    dedupHint:SetPoint("TOPLEFT", 8, yPos)
    dedupHint:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    dedupHint:SetJustifyH("LEFT")
    dedupHint:SetWordWrap(true)
    dedupHint:SetText(L["Categories shown here are hidden from the main debuff bar automatically."])
    dedupHint:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    yPos = yPos - 30

    -- ── DEBUFF GROUPS heading — mirrors the Layout Groups tab's caption. ──
    local groupsHeader = parent:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(groupsHeader, 9, "")
    groupsHeader:SetPoint("TOPLEFT", 8, yPos)
    groupsHeader:SetText(L["DEBUFF GROUPS"])
    groupsHeader:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    yPos = yPos - 16

    -- READ path: visiting the tab never creates adDB.debuffGroups.
    local groups = DebuffGroupsRead()

    if #groups == 0 then
        -- Empty state
        local empty = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        empty:SetPoint("TOP", parent, "TOP", 0, yPos - 30)
        empty:SetWidth(220)
        empty:SetText(L["No debuff groups created yet.\nClick '+ Debuff Group' to get started."])
        empty:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.7)
        empty:SetJustifyH("CENTER")
    else
        for _, group in ipairs(groups) do
            local cardKey = "dgroup:" .. group.id
            local isExpanded = expandedGroups[cardKey] or false
            local capturedGroupID = group.id

            -- Card container
            local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
            card:SetPoint("TOPLEFT", 8, yPos)
            card:SetPoint("RIGHT", parent, "RIGHT", -8, 0)

            -- ── HEADER ──
            local header = CreateFrame("Button", nil, card, "BackdropTemplate")
            header:SetHeight(30)
            header:SetPoint("TOPLEFT", 0, 0)
            header:SetPoint("TOPRIGHT", 0, 0)
            ApplyBackdrop(header, C_ELEMENT, {r = gc.r * 0.35, g = gc.g * 0.35, b = gc.b * 0.35, a = 0.5})

            -- Chevron
            local chevron = header:CreateTexture(nil, "OVERLAY")
            chevron:SetSize(12, 12)
            chevron:SetPoint("LEFT", 8, 0)
            if isExpanded then
                chevron:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
            else
                chevron:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
            end
            chevron:SetVertexColor(gc.r, gc.g, gc.b)

            -- Group name + collapsed summary: the selected category names
            -- (the A5 collapsed treatment, categories instead of link count).
            local nameText = header:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            nameText:SetPoint("LEFT", chevron, "RIGHT", 6, 0)
            nameText:SetPoint("RIGHT", header, "RIGHT", -60, 0)
            nameText:SetMaxLines(1)
            local selectedNames = {}
            local selRead = group.selection
            if selRead then
                for _, def in ipairs(CATEGORY_DEFS) do
                    if selRead[def.key] then tinsert(selectedNames, def.label) end
                end
            end
            local summary = (#selectedNames > 0) and table.concat(selectedNames, ", ")
                or L["No categories selected"]
            nameText:SetText(group.name .. "  -  " .. summary)
            nameText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

            -- Delete button — full structural chain: the group's claimed
            -- categories return to the main debuff bar.
            local delBtn = GUI:CreateCloseButton(header, {
                size = 22,
                onClick = function()
                    DeleteDebuffGroup(capturedGroupID)
                    StructuralDebuffGroupRefresh()
                end,
            })
            delBtn:SetPoint("RIGHT", -4, 0)
            delBtn:SetFrameLevel(header:GetFrameLevel() + 2)

            -- Eye icon (visibility toggle) — same asset + idiom as the filter
            -- group eye (A3/A5). Toggling is STRUCTURAL: the factory tears
            -- down / stands up the container and the claims union moves.
            local mediaPath = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"
            local eyeBtn = CreateFrame("Button", nil, header)
            eyeBtn:SetSize(18, 18)
            eyeBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
            local eyeIcon = eyeBtn:CreateTexture(nil, "OVERLAY")
            eyeIcon:SetAllPoints()
            local function shown() return group.enabled ~= false end
            local function updateEyeIcon()
                if shown() then
                    eyeIcon:SetTexture(mediaPath .. "visibility")
                    eyeIcon:SetVertexColor(0.95, 0.95, 0.95)
                else
                    eyeIcon:SetTexture(mediaPath .. "visibility_off")
                    eyeIcon:SetVertexColor(0.45, 0.45, 0.45)
                end
            end
            updateEyeIcon()
            eyeBtn:SetScript("OnEnter", function() if shown() then eyeIcon:SetVertexColor(1, 1, 1) end end)
            eyeBtn:SetScript("OnLeave", function() updateEyeIcon() end)
            eyeBtn:RegisterForClicks("LeftButtonUp")
            eyeBtn:SetFrameLevel(header:GetFrameLevel() + 2)
            eyeBtn:SetScript("OnClick", function()
                group.enabled = (group.enabled == false) and true or false
                updateEyeIcon()
                StructuralDebuffGroupRefresh()
            end)
            if not shown() then
                nameText:SetAlpha(0.5)
            end

            -- Header click → toggle expansion
            header:SetScript("OnClick", function()
                expandedGroups[cardKey] = not expandedGroups[cardKey]
                SwitchTab("layout")
            end)
            header:SetScript("OnEnter", function(self)
                self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
            end)
            header:SetScript("OnLeave", function(self)
                self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
            end)

            local totalCardH = 30

            -- ── BODY (when expanded) ──
            if isExpanded then
                local body = CreateFrame("Frame", nil, card, "BackdropTemplate")
                body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
                body:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
                ApplyBackdrop(body, {r = 0.09, g = 0.09, b = 0.09, a = 1},
                    {r = gc.r * 0.20, g = gc.g * 0.20, b = gc.b * 0.20, a = 0.3})

                local by = -10
                local bodyWidth = (tabContentFrame and tabContentFrame:GetWidth() or 260) - 24
                if bodyWidth < 100 then bodyWidth = 240 end

                -- Repair a missing selection table (hand-edited data). All
                -- categories start FALSE so an unconfigured group renders —
                -- and claims — nothing until the user picks; modifier
                -- defaults mirror CreateDebuffGroup.
                local sel = group.selection
                if not sel then
                    sel = { dispellableMode = "PLAYER", hideLongMinutes = 5, keepImportant = true }
                    group.selection = sel
                end

                -- Group Name (editable)
                local nameLabel = body:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(nameLabel, 8, "")
                nameLabel:SetPoint("TOPLEFT", 8, by)
                nameLabel:SetText(L["GROUP NAME"])
                nameLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 16

                local nameEdit = CreateFrame("EditBox", nil, body, "BackdropTemplate")
                nameEdit:SetHeight(22)
                nameEdit:SetPoint("TOPLEFT", 8, by)
                nameEdit:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                nameEdit:SetAutoFocus(false)
                nameEdit:SetText(group.name)
                nameEdit:SetMaxLetters(30)
                GUI:StyleEditBox(nameEdit, {})
                nameEdit:SetScript("OnEnterPressed", function(self)
                    local val = self:GetText()
                    if val and val ~= "" then
                        group.name = val
                    end
                    self:ClearFocus()
                    -- Name feeds no sig — cosmetic only (header + canvas label).
                    SwitchTab("layout")
                    RefreshPlacedIndicators()
                end)
                nameEdit:SetScript("OnEscapePressed", function(self)
                    self:SetText(group.name)
                    self:ClearFocus()
                end)
                by = by - 32

                -- ── CATEGORIES SECTION ──
                -- Checkbox list writing group.selection.* — every toggle is
                -- structural (records move AND the claims union moves).
                local catLabel = body:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(catLabel, 8, "")
                catLabel:SetPoint("TOPLEFT", 8, by)
                catLabel:SetText(L["CATEGORIES"])
                catLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 18

                for _, def in ipairs(CATEGORY_DEFS) do
                    local cb = GUI:CreateCheckbox(body, def.label, sel, def.key, StructuralDebuffGroupRefresh)
                    cb:SetPoint("TOPLEFT", 8, by)
                    cb.tooltip = def.tooltip
                    by = by - 26

                    if def.key == "dispellable" then
                        -- Mode toggle, indented under Dispellable Debuffs
                        -- (the Aura Filters column's control, group-scoped).
                        local modeToggle = GUI:CreateToggleSwitch(body, L["Dispellable By Me"], L["All Dispellable"],
                            sel, "dispellableMode", "PLAYER", "ALL", StructuralDebuffGroupRefresh)
                        modeToggle:SetPoint("TOPLEFT", 24, by)
                        modeToggle.tooltip = L["Dispellable By Me: only debuffs you can dispel. All Dispellable: any debuff that can be dispelled."]
                        modeToggle:SetEnabled(not not sel.dispellable)
                        by = by - 28
                    end
                end

                by = by - 4
                local hideLongCb = GUI:CreateCheckbox(body, L["Hide Long Debuffs"], sel, "hideLong", StructuralDebuffGroupRefresh)
                hideLongCb:SetPoint("TOPLEFT", 8, by)
                hideLongCb.tooltip = L["Hide debuffs whose total duration is longer than the threshold. Debuffs with no duration (permanent auras) are also hidden while this is on."]
                by = by - 26

                local minSlider = GUI:CreateSlider(body, L["Hide Longer Than (minutes)"], 1, 30, 1,
                    sel, "hideLongMinutes", LayoutDebuffGroupRefresh)
                minSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 8, by)
                if minSlider.SetWidth then minSlider:SetWidth(bodyWidth - 10) end
                minSlider:SetEnabled(not not sel.hideLong)
                by = by - 54

                -- Keep-important, indented under Hide Long (Aura Filters idiom)
                local keepCb = GUI:CreateCheckbox(body, L["Keep important debuffs"], sel, "keepImportant", StructuralDebuffGroupRefresh)
                keepCb:SetPoint("TOPLEFT", 24, by)
                keepCb.tooltip = L["Boss, Role, and Priority debuffs stay visible even when their duration is over the threshold."]
                keepCb:SetEnabled(not not sel.hideLong)
                by = by - 30

                -- ── PLACEMENT SECTION ── (the shared filter-group layout controls)
                by = by - 10
                local placeLabel = body:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(placeLabel, 8, "")
                placeLabel:SetPoint("TOPLEFT", 8, by)
                placeLabel:SetText(L["PLACEMENT"])
                placeLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 18

                local anchorDrop = GUI:CreateDropdown(body, L["Anchor"], OPTS.ANCHOR_OPTIONS, group, "anchor", LayoutDebuffGroupRefresh)
                anchorDrop:SetPoint("TOPLEFT", body, "TOPLEFT", 5, by)
                if anchorDrop.SetWidth then anchorDrop:SetWidth(bodyWidth - 10) end
                by = by - 54

                local oxSlider = GUI:CreateSlider(body, L["Offset X"], -150, 150, 1, group, "offsetX",
                    LayoutDebuffGroupRefresh, RefreshPlacedIndicators)
                oxSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, by)
                if oxSlider.SetWidth then oxSlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                local oySlider = GUI:CreateSlider(body, L["Offset Y"], -150, 150, 1, group, "offsetY",
                    LayoutDebuffGroupRefresh, RefreshPlacedIndicators)
                oySlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, by)
                if oySlider.SetWidth then oySlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                -- ── GROWTH SECTION ──
                by = by - 10
                local growLabel = body:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(growLabel, 8, "")
                growLabel:SetPoint("TOPLEFT", 8, by)
                growLabel:SetText(L["GROWTH"])
                growLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 18

                local growthControl = GUI:CreateGrowthControl(body, group, "growDirection", LayoutDebuffGroupRefresh)
                growthControl:SetPoint("TOPLEFT", body, "TOPLEFT", 5, by)
                if growthControl.SetWidth then growthControl:SetWidth(bodyWidth - 10) end
                by = by - 158

                local iprSlider = GUI:CreateSlider(body, L["Icons Per Row"], 1, 20, 1, group, "iconsPerRow",
                    LayoutDebuffGroupRefresh, RefreshPlacedIndicators)
                iprSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, by)
                if iprSlider.SetWidth then iprSlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                local spacingSlider = GUI:CreateSlider(body, L["Spacing"], -5, 20, 1, group, "spacing",
                    LayoutDebuffGroupRefresh, RefreshPlacedIndicators)
                spacingSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, by)
                if spacingSlider.SetWidth then spacingSlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                -- Uniform per-group styling (filter-group idiom: one icon
                -- size + slot cap for everything the categories match).
                local sizeSlider = GUI:CreateSlider(body, L["Icon Size"], 8, 64, 1, group, "iconSize",
                    LayoutDebuffGroupRefresh, RefreshPlacedIndicators)
                sizeSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, by)
                if sizeSlider.SetWidth then sizeSlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                -- Max Icons is STRUCTURAL (slot count is declared at container
                -- build) — the factory Rebuild path handles it (OOC-deferred).
                local maxSlider = GUI:CreateSlider(body, L["Max Icons"], 1, 20, 1, group, "maxIcons",
                    LayoutDebuffGroupRefresh, RefreshPlacedIndicators)
                maxSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, by)
                if maxSlider.SetWidth then maxSlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                -- ── APPEARANCE (collapsible — the effect-card section idiom) ──
                by = by - 10
                by = AddGroupAppearanceSection(body, group, bodyWidth, by, cardKey)

                local bodyH = -by + 12
                body:SetHeight(bodyH)
                totalCardH = totalCardH + bodyH
            end

            card:SetHeight(totalCardH)
            yPos = yPos - totalCardH - 5
        end
    end

    parent:SetHeight(max(-yPos + 20, 200))
end

-- ============================================================
-- SPELL PICKER VIEW BUILD
-- Extracted from BuildAuraDesignerPage: Lua 5.1 caps every function at
-- 60 upvalues (the page builder was at 65 and failed to load), and this
-- block -- including the DoAddByID closure -- carried ~20 captures used
-- nowhere else in the page build. As a file-scope helper its captures
-- no longer count against the page builder's upvalue budget.
-- ============================================================

local function BuildSpellPickerView()
    -- ── SPELL PICKER VIEW (hidden by default, overlays tabs when active) ──
    spellPickerView = CreateFrame("Frame", nil, rightPanel, "BackdropTemplate")
    spellPickerView:SetPoint("TOPLEFT", 0, 0)
    spellPickerView:SetPoint("BOTTOMRIGHT", 0, 0)
    GUI:CreatePanelBackdrop(spellPickerView, {borderColor = {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5}})
    spellPickerView:Hide()

    -- Spell picker header
    local pickerHeader = CreateFrame("Frame", nil, spellPickerView, "BackdropTemplate")
    pickerHeader:SetHeight(28)
    pickerHeader:SetPoint("TOPLEFT", 0, 0)
    pickerHeader:SetPoint("TOPRIGHT", 0, 0)
    GUI:CreatePanelBackdrop(pickerHeader, {borderColor = {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5}})

    -- Icon-only back chevron. Shared styler supplies the backdrop + accent-wash
    -- hover; the chevron_right glyph is rotated 180° to point left (StyleButton
    -- has no rotation knob, so re-apply it after styling).
    local backBtn = CreateFrame("Button", nil, pickerHeader, "BackdropTemplate")
    backBtn:SetPoint("LEFT", 4, 0)
    GUI:StyleButton(backBtn, {
        width = 24, height = 24,
        icon = {
            texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right",
            size = 14,
            color = C_TEXT_DIM,
        },
    })
    backBtn.Icon:SetRotation(math.rad(180))  -- flip to point left
    backBtn:SetScript("OnClick", function()
        HideSpellPicker()
        -- Add-by-ID lands while the picker stays open, so the effects tab
        -- behind it is stale — rebuild it on the way out (card clicks do the
        -- equivalent SwitchTab("effects") themselves).
        if spellPickerDirty then
            spellPickerDirty = false
            SwitchTab(activeTab or "effects")
        end
    end)

    spellPickerView.title = pickerHeader:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    spellPickerView.title:SetPoint("LEFT", backBtn, "RIGHT", 4, 0)
    spellPickerView.title:SetText(L["Select a spell"])
    spellPickerView.title:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    spellPickerView.typeBadge = pickerHeader:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    spellPickerView.typeBadge:SetPoint("LEFT", spellPickerView.title, "RIGHT", 6, 0)

    -- ── PICKER TOOLBAR (row 2): name search + add-by-ID ──
    -- Same idiom as the FilterRegistry Options header: stretchy search box,
    -- ^%d+$-validated Spell ID box + Add button, transient echo line.
    -- CreateEditBox reserves 15px for its (empty) label, so the widget frames
    -- anchor 15px high (y = 9) to land the box bodies at -6..-30 below the
    -- header, with the 22px Add button centered on the same row (top = -7).
    local addBtnW, addBoxW = 50, 70
    local addBtn  -- created after DoAddByID below
    local addBox = GUI:CreateEditBox(spellPickerView, "", nil, nil, nil, addBoxW, L["Spell ID"])
    addBox:SetPoint("TOPRIGHT", pickerHeader, "BOTTOMRIGHT", -(10 + addBtnW + 6), 9)
    spellPickerView.addBox = addBox

    local searchBox = GUI:CreateEditBox(spellPickerView, "", nil, nil, nil, 150, L["Search..."])
    searchBox:SetPoint("TOPLEFT", pickerHeader, "BOTTOMLEFT", 10, 9)
    searchBox:SetPoint("TOPRIGHT", addBox, "TOPLEFT", -8, 0)
    spellPickerView.searchBox = searchBox

    -- Live name filter: case-insensitive plain find on the display name.
    searchBox.EditBox:HookScript("OnTextChanged", function(eb)
        local q = (eb:GetText() or ""):match("^%s*(.-)%s*$"):lower()
        if q == spellPickerSearch then return end
        spellPickerSearch = q
        PopulateSpellGrid()
    end)

    -- Spell picker hint (echo borrows its line: hint hides while echo shows)
    local pickerHint = spellPickerView:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    pickerHint:SetPoint("TOPLEFT", pickerHeader, "BOTTOMLEFT", 12, -36)
    pickerHint:SetText(L["Click or drag a spell onto the frame to place it"])
    pickerHint:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    spellPickerView.hint = pickerHint  -- ShowSpellPicker swaps the text per mode

    -- Echo line: transient add-by-ID feedback, auto-hides after ~4s
    -- (generation counter so a re-add restarts the window — FilterRegistry idiom)
    local echoText = spellPickerView:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    echoText:SetPoint("TOPLEFT", pickerHeader, "BOTTOMLEFT", 12, -36)
    echoText:SetPoint("TOPRIGHT", pickerHeader, "BOTTOMRIGHT", -10, -36)
    echoText:SetJustifyH("LEFT")
    echoText:SetWordWrap(false)
    echoText:SetTextColor(0.6, 0.6, 0.6)
    echoText:Hide()

    local echoGen = 0
    local function HideEcho()
        echoGen = echoGen + 1
        echoText:Hide()
        pickerHint:Show()
    end
    spellPickerView.HideEcho = HideEcho
    local function Echo(msg)
        echoGen = echoGen + 1
        local gen = echoGen
        echoText:SetText(msg)
        pickerHint:Hide()
        echoText:Show()
        C_Timer.After(4, function()
            if echoGen == gen then HideEcho() end
        end)
    end
    spellPickerView.Echo = Echo  -- AddSpellToGroup confirms group adds through it

    -- Add-by-ID: snap known ids to their pool/curated record (then behave
    -- exactly like clicking that spell's card — same AddPickedSpell path);
    -- unknown ids become an ad-hoc "#<id>" aura whose key IS its identity.
    -- The picker stays open (echo confirms), so several ids can be added in
    -- a row; spellPickerDirty makes the back button rebuild the effects tab.
    -- In "group" mode the toolbar's Icon/Square buttons pass typeKeyArg and
    -- the add routes through AddSpellToGroup (Enter defaults to Icon).
    local function DoAddByID(typeKeyArg)
        local text = (addBox.EditBox:GetText() or ""):match("^%s*(.-)%s*$")
        if text == "" then return end
        -- Integers only: tonumber() also accepts floats/hex, which are never
        -- valid spell ids
        if not text:match("^%d+$") then
            Echo(L["Enter a valid spell ID."])
            return
        end
        -- Normalize + cap: strip leading zeros ("#007" and "#7" must be the same
        -- key), and reject oversized digit strings — real spell IDs are well under
        -- 10 digits, and past ~15 tonumber() loses integer precision, which would
        -- mint broken keys like "#1e+21".
        text = text:match("^0*(%d+)$") or text
        if #text > 10 then
            Echo(L["Enter a valid spell ID."])
            return
        end
        local idNum = tonumber(text)
        local isOther = IsOtherTab()
        local spec = ResolveSpec()
        -- The Other Buffs pool is spec-independent — no spec required there.
        if not spec and not isOther then return end

        -- Snap. My Buffs: the spec's curated tables first (alt ids included),
        -- then the SpellDB (R.ByID indexes canonical + alt ids), else ad-hoc.
        -- Other Buffs: SpellDB ONLY — the B1 naming contract (other-pool keys
        -- are SpellDB rec.n or ad-hoc "#<id>"; curated internal names don't
        -- resolve with a nil spec).
        local auraName
        if not isOther then
            local alts = DF.AuraDesigner.AlternateSpellIDs and DF.AuraDesigner.AlternateSpellIDs[spec]
            if alts and alts[idNum] then auraName = alts[idNum] end
            if not auraName then
                local specIDs = DF.AuraDesigner.SpellIDs and DF.AuraDesigner.SpellIDs[spec]
                if specIDs then
                    for name, id in pairs(specIDs) do
                        if id == idNum then auraName = name; break end
                        if type(id) == "table" then  -- rare multi-id entries
                            for _, sub in ipairs(id) do
                                if sub == idNum then auraName = name; break end
                            end
                            if auraName then break end
                        end
                    end
                end
            end
        end
        if not auraName then
            local R = DF.FilterRegistry
            local rec = R and R.ByID and R.ByID[idNum]
            if rec then auraName = rec.n end
        end

        local isAdHoc = not auraName
        -- Key from the validated TEXT, not tonumber output — number formatting
        -- must never leak into config keys (AdHocSpellID parses "^#(%d+)$").
        if isAdHoc then auraName = "#" .. text end

        -- Cross-tab block (B2): the spell — snapped name's FULL identity set,
        -- or the raw id for ad-hoc — is already tracked by the OPPOSITE pool.
        -- Checked before the group branch so group adds are blocked too.
        local crossBlocked = false
        if spellPickerBlockedIDs and next(spellPickerBlockedIDs) then
            if spellPickerBlockedIDs[idNum] then
                crossBlocked = true
            elseif not isAdHoc then
                crossBlocked = IsCandidateCrossBlocked(auraName, spec)
            end
        end
        if crossBlocked then
            Echo(isOther and L["Already tracked in My Buffs."] or L["Already tracked in Other Buffs."])
            return
        end

        -- Display name: the trackable pool entry when it has one (curated
        -- display or localized SpellDB name), else the raw key.
        local display = auraName
        if not isAdHoc then
            if isOther then
                display = OtherPoolDisplayName(auraName)
            else
                local trackable = Adapter and Adapter:GetTrackableAuras(spec)
                if trackable then
                    for _, info in ipairs(trackable) do
                        if info.name == auraName then display = info.display or auraName; break end
                    end
                end
            end
        end

        -- Group mode: no already-used gate (a spell can hold several
        -- indicators in one group). AddSpellToGroup echoes and refreshes.
        if spellPickerMode == "group" then
            AddSpellToGroup(auraName, display, typeKeyArg or "icon", isAdHoc)
            addBox.EditBox:SetText("")
            if isAdHoc then
                Echo(format(L["Added #%d as an unknown spell ID — name and icon will show if the ID is valid."], idNum))
                PopulateSpellGrid()  -- the new ad-hoc aura gets a card of its own
            end
            return
        end

        local alreadyUsed
        if spellPickerMode == "placed" then
            alreadyUsed = IsAuraTypePlaced(auraName, spellPickerType)
        else
            alreadyUsed = HasFrameEffect(auraName, spellPickerType)
        end
        if alreadyUsed then
            Echo(L["Already added."])
            return
        end

        AddPickedSpell(auraName, spellPickerType)
        spellPickerDirty = true
        addBox.EditBox:SetText("")
        if isAdHoc then
            Echo(format(L["Added #%d as an unknown spell ID — name and icon will show if the ID is valid."], idNum))
        else
            Echo(format(L["Added %s."], display))
        end
        PopulateSpellGrid()          -- card flips to its Placed/Active state
        RefreshPlacedIndicators()    -- live preview updates behind the picker
        RefreshPreviewEffects()
    end

    addBtn = GUI:CreateButton(spellPickerView, L["Add"], addBtnW, 22, function()
        DoAddByID()
    end)
    addBtn:SetPoint("TOPRIGHT", pickerHeader, "BOTTOMRIGHT", -10, -7)
    -- Enter in the box adds too (the helper's own OnEnterPressed only saves
    -- db-backed values — this box has no db binding). Wrapped: the hook passes
    -- the EditBox as arg 1, which must not reach DoAddByID's typeKeyArg.
    addBox.EditBox:HookScript("OnEnterPressed", function() DoAddByID() end)

    -- Group-mode add-by-ID buttons: [Icon] [Square] replace the single Add
    -- button, so the typed ID lands with an explicit indicator type (Enter in
    -- the box defaults to Icon). Hidden outside group mode by SetGroupToolbar.
    local typeBtnW = 44
    local addIconBtn = GUI:CreateButton(spellPickerView, L["Icon"], typeBtnW, 22, function()
        DoAddByID("icon")
    end)
    addIconBtn:SetPoint("TOPRIGHT", pickerHeader, "BOTTOMRIGHT", -(10 + typeBtnW + 4), -7)
    addIconBtn.Text:SetTextColor(BADGE_COLORS.icon.r, BADGE_COLORS.icon.g, BADGE_COLORS.icon.b)
    addIconBtn:Hide()
    local addSquareBtn = GUI:CreateButton(spellPickerView, L["Square"], typeBtnW, 22, function()
        DoAddByID("square")
    end)
    addSquareBtn:SetPoint("TOPRIGHT", pickerHeader, "BOTTOMRIGHT", -10, -7)
    addSquareBtn.Text:SetTextColor(BADGE_COLORS.square.r, BADGE_COLORS.square.g, BADGE_COLORS.square.b)
    addSquareBtn:Hide()

    -- Swap the toolbar between the modes; the ID box slides left to clear
    -- whichever button set is showing (the search box is anchored to it and
    -- follows). Called by ShowSpellPicker on every open.
    spellPickerView.SetGroupToolbar = function(isGroup)
        addBtn:SetShown(not isGroup)
        addIconBtn:SetShown(isGroup)
        addSquareBtn:SetShown(isGroup)
        addBox:ClearAllPoints()
        if isGroup then
            addBox:SetPoint("TOPRIGHT", pickerHeader, "BOTTOMRIGHT", -(10 + typeBtnW * 2 + 4 + 6), 9)
        else
            addBox:SetPoint("TOPRIGHT", pickerHeader, "BOTTOMRIGHT", -(10 + addBtnW + 6), 9)
        end
    end

    -- Spell picker scroll frame for the grid (below toolbar + hint rows)
    local pickerScroll = CreateFrame("ScrollFrame", nil, spellPickerView, "ScrollFrameTemplate")
    pickerScroll:SetPoint("TOPLEFT", pickerHeader, "BOTTOMLEFT", 0, -52)
    pickerScroll:SetPoint("BOTTOMRIGHT", -22, 0)

    spellPickerView.gridFrame = CreateFrame("Frame", nil, pickerScroll)
    spellPickerView.gridFrame:SetWidth(1)
    spellPickerView.gridFrame:SetHeight(400)
    pickerScroll:SetScrollChild(spellPickerView.gridFrame)

    pickerScroll:SetScript("OnSizeChanged", function(self, w, h)
        spellPickerView.gridFrame:SetWidth(w)
    end)

    DF.GUI.StyleScrollBar(pickerScroll)

    spellPickerView.scrollFrame = pickerScroll
end

-- ============================================================
-- MAIN PAGE BUILD
-- ============================================================

function DF.BuildAuraDesignerPage(guiRef, pageRef, dbRef)
    local prevDB = db  -- capture before overwrite to detect mode switch
    GUI = guiRef
    page = pageRef
    db = dbRef
    Adapter = DF.AuraDesigner.Adapter

    local parent = page.child

    -- ========================================
    -- REUSE: If mainFrame already exists, db hasn't changed (same mode) AND the
    -- frame dimensions are unchanged, just re-parent, show, and refresh. A mode
    -- switch (Party↔Raid) changes db; an auto-layout switch keeps the SAME db
    -- reference but changes frameWidth/Height — both must force a full rebuild so
    -- the preview mock resizes to the active layout's frame size.
    -- ========================================
    local _adFDB = (DF.GetDB and DF:GetDB((GUI and GUI.SelectedMode) or "party")) or {}
    local _adW, _adH = _adFDB.frameWidth or 125, _adFDB.frameHeight or 64
    -- Auto-layout identity: two raid layouts share the SAME db proxy and may share
    -- frame dimensions, so neither check below distinguishes them — without this,
    -- switching between same-size raid layouts reuses the stale page.
    local _adLayout = (DF.AutoProfilesUI and (DF.AutoProfilesUI.editingProfile or DF.AutoProfilesUI.activeRuntimeProfile)) or nil
    -- Preset identity: switching the mode's preset keeps the same db/size/layout,
    -- so without this the stale page (bound to the old preset) would be reused.
    local _adPreset = DF.GetModeDesignerPresetName
        and DF:GetModeDesignerPresetName("aura", (GUI and GUI.SelectedMode) or "party")
    -- Editing identity: entering edit of the ACTIVE layout keeps the same table
    -- object (editingProfile == activeRuntimeProfile), so _adLayout alone
    -- misses the transition and the editing-banner offset is never applied.
    local _adEditing = (DF.AutoProfilesUI and DF.AutoProfilesUI.IsEditing and DF.AutoProfilesUI:IsEditing()) or false
    if mainFrame and prevDB == dbRef
       and mainFrame.dfBuiltFrameW == _adW and mainFrame.dfBuiltFrameH == _adH
       and mainFrame.dfBuiltLayout == _adLayout
       and mainFrame.dfBuiltPreset == _adPreset
       and mainFrame.dfBuiltEditing == _adEditing then
        mainFrame:SetParent(parent)
        mainFrame:SetAllPoints()
        mainFrame:Show()
        DF:AuraDesigner_RefreshPage()
        return
    end

    -- Full build (first time, or mode switch)
    if mainFrame then
        mainFrame:Hide()
        mainFrame:SetParent(nil)
    end
    wipe(placedIndicators)
    wipe(expandedCards)
    wipe(effectCardPool)

    activeTab = "effects"
    activeBuffTab = "my"
    activeFilter = "all"
    spellPickerActive = false
    spellPickerType = nil
    spellPickerGroupID = nil

    -- Layout constants
    local BANNER_H = 68
    local BUFFTAB_H = 30    -- main pool tab strip (My Buffs / Other Buffs)
    local SECTION_GAP = 8

    -- ========================================
    -- MAIN FRAME
    -- ========================================
    mainFrame = CreateFrame("Frame", nil, parent)
    mainFrame:SetAllPoints()
    -- Record the frame dims this build was made for, so the reuse-guard above can
    -- detect an auto-layout switch (same db, different frameWidth/Height) and rebuild.
    mainFrame.dfBuiltFrameW = _adW
    mainFrame.dfBuiltFrameH = _adH
    mainFrame.dfBuiltLayout = _adLayout
    mainFrame.dfBuiltPreset = _adPreset
    mainFrame.dfBuiltEditing = _adEditing

    -- Override RefreshStates: Aura Designer uses its own layout system.
    --
    -- This hook gets called by anything that walks the GUI parent chain
    -- looking for a page with RefreshStates+children — including
    -- CreateInfoBanner's TriggerHostRelayout after every measure cycle.
    -- AuraDesigner_RefreshPage is a heavyweight rebuild (destroys +
    -- recreates every effect card on the active tab), so firing it
    -- from a banner's auto-resize cascade meant: each new banner from
    -- BuildEffectsTab triggered SetText → schedule DoRecomputeHeight →
    -- TriggerHostRelayout → page:RefreshStates → AuraDesigner_RefreshPage
    -- → SwitchTab → BuildEffectsTab → create more banners → repeat at
    -- ~9 Hz, locking up the GUI the moment the perf-warning banner
    -- surfaced (because picking an animation triggered the chain).
    --
    -- The fix: only call AuraDesigner_RefreshPage when the page
    -- dimensions actually changed.  GUI window resize cases (the real
    -- reason this hook exists) still rebuild; banner-cascade-as-noop
    -- cases stop the loop.
    page.RefreshStates = function(self)
        local pageH = self:GetHeight()
        self.child:SetHeight(pageH)
        local newW = GUI.contentFrame and (GUI.contentFrame:GetWidth() - 30) or nil
        if self.child and newW then
            self.child:SetWidth(newW)
        end
        -- Keep parent scroll at 0 — only the right panel should scroll
        local parentScroll = self:GetParent()
        if parentScroll and parentScroll.SetVerticalScroll then
            parentScroll:SetVerticalScroll(0)
        end
        -- Skip the heavyweight rebuild when nothing actually changed —
        -- only fire it on genuine size transitions (window resize / tab
        -- switch / first show).
        if self._lastRefreshStatesH == pageH and self._lastRefreshStatesW == newW then
            return
        end
        self._lastRefreshStatesH = pageH
        self._lastRefreshStatesW = newW
        DF:AuraDesigner_RefreshPage()
    end

    local yPos = -8  -- top gap; kept equal to the Text Designer's _tdTopY for a consistent header gap
    -- While editing a raid auto-layout, the AutoProfiles editing banner is a ~50px
    -- overlay anchored to the top of the content frame; this custom AD page lays
    -- its own content out from the top too, so push everything down to clear it
    -- (otherwise the editing banner sits on top of the enable banner / preset bar).
    if DF.AutoProfilesUI and DF.AutoProfilesUI.IsEditing and DF.AutoProfilesUI:IsEditing() then
        yPos = -56
    end

    -- ========================================
    -- ENABLE BANNER (full width)
    -- ========================================
    enableBanner = CreateEnableBanner(mainFrame)
    enableBanner:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, yPos)
    enableBanner:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, yPos)

    if GUI.CreateCopyButton then
        local copyBtn = GUI.CreateCopyButton(enableBanner, {"auraDesigner"}, L["Aura Designer"], "auras_auradesigner", true)
        copyBtn:ClearAllPoints()
        -- Row 1 centre is 16px above banner centre, so y = +16.
        copyBtn:SetPoint("RIGHT", enableBanner, "RIGHT", -5, 16)
    end

    -- ========================================
    -- PRESET BAR (which named preset this mode uses + library management)
    -- Rides row 2 of the enable banner (left side; the spec dropdown holds the
    -- right side). Compact icon buttons keep the row within the page width.
    -- ========================================
    if GUI.CreateDesignerPresetBar then
        local presetBar = GUI:CreateDesignerPresetBar(enableBanner, {
            kind = "aura",
            iconButtons = true,
            getMode = function() return (GUI and GUI.SelectedMode) or "party" end,
            onChange = function()
                -- Re-invoke the build NEXT frame: the dfBuiltPreset guard then
                -- forces a full rebuild so the editor rebinds to the newly chosen
                -- preset. Deferred so we don't tear down the bar from inside its
                -- own click handler.
                if C_Timer and C_Timer.After then
                    C_Timer.After(0, function()
                        if DF.BuildAuraDesignerPage then DF.BuildAuraDesignerPage(GUI, page, db) end
                        DF:InvalidateAuraLayout()
                        DF:UpdateAllFrames()
                        local E = DF.AuraDesigner and DF.AuraDesigner.Engine
                        if E and E.ForceRefreshAllFrames then E:ForceRefreshAllFrames() end
                    end)
                end
            end,
        })
        -- Row 2 reflows (B2): the spec dropdown moved onto the tab strip, so
        -- the preset bar takes the whole row.
        presetBar:SetPoint("LEFT", enableBanner, "LEFT", 10, -18)
        presetBar:SetPoint("RIGHT", enableBanner, "RIGHT", -10, -18)
        enableBanner.presetBar = presetBar
    end

    yPos = yPos - (BANNER_H + SECTION_GAP)

    -- ========================================
    -- MAIN POOL TAB STRIP (B2/C2): My Buffs / Debuffs / Other Buffs, between the header
    -- banner and the workspace. Visually distinct from the right panel's
    -- underline sub-tabs: filled StyleButton pills, slightly larger, with the
    -- relocated spec dropdown on the strip's right end (per the prototype —
    -- the spec only applies to My Buffs).
    -- ========================================
    local buffTabBar = CreateFrame("Frame", nil, mainFrame)
    buffTabBar:SetHeight(BUFFTAB_H)
    buffTabBar:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, yPos)
    buffTabBar:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, yPos)

    local MAIN_TAB_DEFS = {
        { key = "my",      label = L["My Buffs"]    },
        { key = "debuffs", label = L["Debuffs"]     },
        { key = "other",   label = L["Other Buffs"] },
    }
    wipe(mainTabButtons)
    local prevMainBtn
    for _, def in ipairs(MAIN_TAB_DEFS) do
        local btn = CreateFrame("Button", nil, buffTabBar, "BackdropTemplate")
        GUI:StyleButton(btn, { height = BUFFTAB_H - 4, text = def.label, font = "DFFontHighlight" })
        btn.Text:ClearAllPoints()
        btn.Text:SetPoint("CENTER", 0, 0)
        btn:SetWidth(max(btn.Text:GetStringWidth() + 28, 96))
        if prevMainBtn then
            btn:SetPoint("LEFT", prevMainBtn, "RIGHT", 4, 0)
        else
            btn:SetPoint("LEFT", buffTabBar, "LEFT", 0, 0)
        end
        local capturedKey = def.key
        btn:SetScript("OnClick", function() SetMainTab(capturedKey) end)
        btn:SetActive(activeBuffTab == def.key)
        mainTabButtons[def.key] = btn
        prevMainBtn = btn
    end

    -- Relocated spec dropdown (right end of the strip)
    local stripSpecLabel = buffTabBar:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    stripSpecLabel:SetText(L["Spec:"])
    stripSpecLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    specDropdown, specDropdownUpdate = CreateSpecDropdown(buffTabBar)
    specDropdown:SetSize(165, 22)
    specDropdown:SetPoint("RIGHT", buffTabBar, "RIGHT", -5, 0)
    stripSpecLabel:SetPoint("RIGHT", specDropdown, "LEFT", -4, 0)
    UpdateSpecDropdownState()

    yPos = yPos - (BUFFTAB_H + SECTION_GAP)

    -- ========================================
    -- 50/50 SPLIT: LEFT PANEL + RIGHT PANEL
    -- ========================================
    local splitContainer = CreateFrame("Frame", nil, mainFrame)
    splitContainer:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, yPos)
    splitContainer:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, 0)
    mainFrame.splitContainer = splitContainer

    -- ── LEFT PANEL (frame preview) ──
    leftPanel = CreateFrame("Frame", nil, splitContainer, "BackdropTemplate")
    leftPanel:SetPoint("TOPLEFT", 0, 0)
    leftPanel:SetPoint("BOTTOMLEFT", 0, 0)
    leftPanel:SetPoint("RIGHT", splitContainer, "CENTER", -3, 0)
    -- NO border here — the inner preview container (CreateFramePreview) draws the
    -- visible dim border. A border on both stacked to a brighter doubled line.
    GUI:CreatePanelBackdrop(leftPanel, {border = false})

    -- Frame preview (reuses existing CreateFramePreview with adapted anchoring)
    origY_framePreview = 0
    framePreview = CreateFramePreview(leftPanel, 0, nil)
    contentRightInset = 0  -- No right inset needed in new layout

    -- ── RIGHT PANEL (tabbed settings) ──
    rightPanel = CreateFrame("Frame", nil, splitContainer, "BackdropTemplate")
    rightPanel:SetPoint("TOPRIGHT", 0, 0)
    rightPanel:SetPoint("BOTTOMRIGHT", 0, 0)
    rightPanel:SetPoint("LEFT", splitContainer, "CENTER", 3, 0)  -- 6px split gap (matches Text Designer)
    GUI:CreatePanelBackdrop(rightPanel, {borderColor = {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5}})

    -- ── TAB BAR ── (shared underline-tab style, mirroring the Pinned Frames
    -- tabs: a transparent strip with a baseline; each tab is a StyleButton in
    -- `tab` mode — faint cell when inactive, accent fill + underline + accent
    -- label when active. Per-tab accent preserves each section's identity.)
    tabBar = CreateFrame("Frame", nil, rightPanel, "BackdropTemplate")
    tabBar:SetHeight(28)
    -- Inset just inside the panel's border so the tabs don't overlap/overrun it.
    tabBar:SetPoint("TOPLEFT", 4, -4)
    tabBar:SetPoint("TOPRIGHT", -4, -4)

    -- Baseline under the whole strip; the active tab's underline sits on it.
    local tabBaseline = tabBar:CreateTexture(nil, "ARTWORK")
    tabBaseline:SetTexture("Interface\\Buttons\\WHITE8x8")
    tabBaseline:SetHeight(1)
    tabBaseline:SetPoint("BOTTOMLEFT", 0, 0)
    tabBaseline:SetPoint("BOTTOMRIGHT", 0, 0)
    tabBaseline:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)

    local TAB_GAP = 4
    local TAB_DEFS = {
        { key = "effects", label = L["Effects"],       accent = nil },  -- theme-tracking
        { key = "layout",  label = L["Layout Groups"], accent = { r = 0.91, g = 0.66, b = 0.25 } },
        { key = "global",  label = L["Global"],        accent = { r = 0.51, g = 0.86, b = 0.51 } },
    }

    wipe(tabButtons)
    for i, def in ipairs(TAB_DEFS) do
        local btn = CreateFrame("Button", nil, tabBar, "BackdropTemplate")
        btn:SetHeight(28)
        if i == 1 then
            btn:SetPoint("TOPLEFT", 0, 0)
        else
            btn:SetPoint("TOPLEFT", tabButtons[TAB_DEFS[i-1].key], "TOPRIGHT", TAB_GAP, 0)
        end
        local provW = parent:GetWidth()
        if provW < 100 and GUI and GUI.contentFrame then provW = GUI.contentFrame:GetWidth() end
        if provW < 100 then provW = 600 end
        btn:SetWidth(max(60, floor(((provW / 2) - (#TAB_DEFS - 1) * TAB_GAP) / #TAB_DEFS)))

        -- Shared underline-tab styling; SwitchTab drives SetActive. label = btn.Text.
        GUI:StyleButton(btn, { tab = true, text = def.label, accent = def.accent, font = "DFFontHighlight" })
        btn.label = btn.Text

        btn.tabKey = def.key
        btn:SetScript("OnClick", function(self)
            if self.dfDisabled then return end  -- frosted (Effects on Debuffs)
            SwitchTab(self.tabKey)
        end)

        -- Effects is buff-pool-only (C2): frosted on the Debuffs tab —
        -- category groups have no per-spell placed indicators.
        if def.key == "effects" then
            btn:HookScript("OnEnter", function(self)
                if self.dfDisabled then
                    GUI:ShowTooltip(self, {
                        title = L["Effects"],
                        lines = { L["Not available for Debuffs. Use Layout Groups instead."] },
                    })
                end
            end)
            btn:HookScript("OnLeave", function() GUI:HideTooltip() end)
        end

        tabButtons[def.key] = btn
    end
    UpdateLayoutTabState()

    -- Equal-width tabs (accounting for the gaps) on parent resize.
    tabBar:SetScript("OnSizeChanged", function(self, w, h)
        local n = #TAB_DEFS
        local tabW = (w - (n - 1) * TAB_GAP) / n
        for _, def in ipairs(TAB_DEFS) do
            local btn = tabButtons[def.key]
            if btn then btn:SetWidth(tabW) end
        end
    end)

    -- ── TAB CONTENT (scrollable) ──
    tabScrollFrame = CreateFrame("ScrollFrame", nil, rightPanel, "ScrollFrameTemplate")
    tabScrollFrame:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, 0)
    tabScrollFrame:SetPoint("BOTTOMRIGHT", -22, 0)

    tabContentFrame = CreateFrame("Frame", nil, tabScrollFrame)
    -- Pre-compute initial width from parent geometry so SwitchTab() has
    -- accurate dimensions before the first layout pass fires OnSizeChanged.
    local earlyW = parent:GetWidth()
    if earlyW < 100 then earlyW = (GUI.contentFrame and GUI.contentFrame:GetWidth() or 600) - 30 end
    tabContentFrame:SetWidth(max(1, (earlyW / 2) - 2 - 22))
    tabContentFrame:SetHeight(800)
    tabScrollFrame:SetScrollChild(tabContentFrame)
    DF.GUI.StyleScrollBar(tabScrollFrame)

    -- Match scroll child width to scroll frame
    tabScrollFrame:SetScript("OnSizeChanged", function(self, w, h)
        tabContentFrame:SetWidth(w)
    end)

    -- Smooth scroll
    local SCROLL_STEP = 30
    tabScrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local maxScroll = max(0, self:GetVerticalScrollRange())
        local newScroll = max(0, min(maxScroll, current - (delta * SCROLL_STEP)))
        self:SetVerticalScroll(newScroll)
    end)
    tabContentFrame:EnableMouseWheel(true)
    tabContentFrame:SetScript("OnMouseWheel", function(self, delta)
        local p = self:GetParent()
        if p and p:GetScript("OnMouseWheel") then
            p:GetScript("OnMouseWheel")(p, delta)
        end
    end)

    BuildSpellPickerView()  -- spell picker overlay (hidden by default, replaces tabs when active)

    -- ========================================
    -- POPULATE (new UI)
    -- ========================================

    -- Force initial width sync: OnSizeChanged won't fire until the frame renders,
    -- but SwitchTab needs accurate widths now for slider/dropdown sizing.
    -- Compute initial scroll content width from parent geometry.
    -- rightPanel:GetWidth() returns 0 before the first layout pass, so we
    -- calculate from the parent which already has valid geometry on a mode
    -- switch (Party↔Raid).
    local parentW = parent:GetWidth()
    if parentW < 100 and GUI and GUI.contentFrame then parentW = GUI.contentFrame:GetWidth() end
    if parentW < 100 then parentW = UIParent:GetWidth() / 2 end
    local initW = (parentW / 2) - 2 - 22  -- half split minus gap minus scrollbar
    if initW > 50 then
        tabContentFrame:SetWidth(initW)
    end

    SwitchTab("effects")
    C_Timer.After(0, function()
        if tabBar and tabBar:IsVisible() and tabBar:GetWidth() > 10 then
            local tabW = (tabBar:GetWidth() - (#TAB_DEFS - 1) * TAB_GAP) / #TAB_DEFS
            for _, def in ipairs(TAB_DEFS) do
                if tabButtons[def.key] then
                    tabButtons[def.key]:SetWidth(tabW)
                end
            end
        end
    end)
    RefreshPlacedIndicators()
    RefreshPreviewEffects()
end

-- ============================================================
-- REFRESH
-- ============================================================

function DF:AuraDesigner_RefreshPage()
    if not mainFrame then return end

    -- Account for editing banner offset (50px) when editing an auto layout
    local editingOffset = 0
    if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() then
        editingOffset = 50
    end
    mainFrame:ClearAllPoints()
    mainFrame:SetPoint("TOPLEFT", mainFrame:GetParent(), "TOPLEFT", 0, -editingOffset)
    mainFrame:SetPoint("BOTTOMRIGHT", mainFrame:GetParent(), "BOTTOMRIGHT", 0, 0)

    -- Check if spec changed
    local currentSpec = ResolveSpec()
    if currentSpec ~= selectedSpec then
        selectedSpec = currentSpec
    end

    -- Subtle class-color hint on the preview border, dimmed to 0.5 alpha so it
    -- stays as quiet as the Text Designer's neutral border (just tinted to the
    -- spec). Was previously full alpha = the harsh "white line" (white for Priest).
    if framePreview then
        local resolvedSpec = currentSpec or selectedSpec
        local specInfoEntry = resolvedSpec and DF.AuraDesigner.SpecInfo[resolvedSpec]
        local classToken = specInfoEntry and specInfoEntry.class
        local classColor = classToken and RAID_CLASS_COLORS[classToken]
        if classColor then
            framePreview:SetBackdropBorderColor(classColor.r, classColor.g, classColor.b, 0.5)
        else
            framePreview:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
        end
    end

    -- Rebuild the current tab to reflect data changes
    if activeTab and SwitchTab then
        SwitchTab(activeTab)
    end

    -- Refresh frame preview
    RefreshPlacedIndicators()
    RefreshPreviewEffects()

    -- Update enable state
    if enableBanner then
        enableBanner.checkbox:SetChecked(GetAuraDesignerDB().enabled)
    end
    -- Spec dropdown lives on the main tab strip (B2): refresh its text on
    -- My Buffs / keep the greyed "shared across specs" caption on Other Buffs.
    UpdateSpecDropdownState()

    -- Show/hide disabled overlay on the split container
    if mainFrame.splitContainer then
        local adEnabled = GetAuraDesignerDB().enabled
        if not adEnabled then
            if not mainFrame.disabledOverlay then
                local overlay = CreateFrame("Frame", nil, mainFrame.splitContainer)
                overlay:SetAllPoints()
                overlay:SetFrameLevel(mainFrame.splitContainer:GetFrameLevel() + 50)
                overlay:EnableMouse(true)

                local bg = overlay:CreateTexture(nil, "BACKGROUND")
                bg:SetAllPoints()
                bg:SetColorTexture(0.08, 0.08, 0.08, 0.85)

                local label = overlay:CreateFontString(nil, "OVERLAY", "DFFontNormal")
                label:SetPoint("CENTER", 0, 10)
                label:SetText(L["Aura Designer is disabled"])
                label:SetTextColor(0.6, 0.6, 0.6, 1)

                local sublabel = overlay:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                sublabel:SetPoint("TOP", label, "BOTTOM", 0, -4)
                sublabel:SetText(L["Enable the checkbox above to use"])
                sublabel:SetTextColor(0.45, 0.45, 0.45, 1)

                mainFrame.disabledOverlay = overlay
            end
            mainFrame.disabledOverlay:Show()
        else
            if mainFrame.disabledOverlay then
                mainFrame.disabledOverlay:Hide()
            end
        end
    end

    -- Refresh buffs tab banner state if visible
    local buffsPage = GUI and GUI.Pages and GUI.Pages["auras_buffs"]
    if buffsPage and buffsPage.RefreshStates then
        buffsPage:RefreshStates()
    end

    -- 12.1: the native factory buff row DERIVES its Aura-Designer dedup set from the AD
    -- config at build time. Indicator add/remove (and other config mutations) funnel
    -- through this refresh but do NOT otherwise re-drive live frames, so poke the buff
    -- row here — mirror the aura-blacklist page (InvalidateAuraLayout -> RefreshFactoryRows).
    -- DriveBuffFactory rebuilds only when the excluded set actually moved (sig-gated), so a
    -- navigation-only refresh is a cheap no-op. Factory-gated so the pre-12.1 path is untouched.
    if DF.AuraContainer and DF.AuraContainer.IsSupported and DF.AuraContainer.IsSupported()
        and DF.InvalidateAuraLayout then
        DF:InvalidateAuraLayout()
    end
end

-- ============================================================
-- TAB DISABLE STATE
-- Standalone function so it can be called from GUI.lua on open
-- and from RefreshPage when the enable checkbox toggles.
-- ============================================================

-- Disable the My Buff Indicators tab when AD is enabled (never compatible).
-- Buffs tab is always accessible — it can coexist with AD.
function DF:ApplyAuraDesignerTabState()
    local guiRef = DF.GUI
    if not guiRef or not guiRef.Tabs then return end
    if not DF.db then return end

    local mode = (guiRef.SelectedMode) or "party"
    local adCfg = DF.GetModeAuraDesigner and DF:GetModeAuraDesigner(mode)
    local adEnabled = adCfg and adCfg.enabled

    -- My Buff Indicators tab removed — feature deprecated
end
