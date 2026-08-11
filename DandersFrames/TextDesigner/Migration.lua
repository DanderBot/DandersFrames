local addonName, DF = ...

-- ============================================================
-- TEXT DESIGNER — LEGACY MIGRATION
-- One-time conversion of the addon's built-in name / health / status
-- text settings into Text Designer elements. Runs once per mode on
-- login (idempotent via a per-mode flag) and can be re-run on demand
-- from the Global tab's "Import Current Text Settings" button.
-- ============================================================

local ipairs, pairs, type = ipairs, pairs, type

-- Deep-copy a color table so migrated elements don't share refs with the
-- legacy db (editing one mustn't mutate the other). Falls back to white.
local function copyColor(c)
    if type(c) ~= "table" then return {r = 1, g = 1, b = 1, a = 1} end
    return {r = c.r or 1, g = c.g or 1, b = c.b or 1, a = c.a or 1}
end

-- The override flags every migrated element carries. Only the keys that
-- resolveAppearance (Render.lua) actually reads are listed — anything else
-- would be inert. With these all true, each element renders exactly the
-- legacy appearance instead of inheriting globalDefaults.
local function appearanceOverrides()
    return {
        font          = true,
        fontSize      = true,
        outline       = true,
        color         = true,
        useClassColor = true,
    }
end

-- ============================================================
-- PER-MODE BUILD
-- ============================================================

-- Build ONE health element from a mode's legacy settings, or nil when the
-- user had health text off. The live legacy renderer is gated by
-- healthTextFormat ALONE ("NONE" = off; anything else renders, Config
-- default CURRENTMAX) — showHealthText was only ever read by test mode,
-- has no GUI control, and defaults to false, so it must NOT gate this:
-- keying on it (4.6.0) silently dropped the health element for every
-- migrating profile. `nextID` is the caller's element-id allocator.
local function buildHealthElement(db, nextID)
    -- Default to the real Config default (CURRENTMAX), NOT "PERCENT" — a nil
    -- format is the unset default, and falling back to PERCENT was what turned
    -- it into a bare "%". Composite formats render as one group FontString that
    -- owns the font/size/outline/color/anchor/offset.
    local healthFormat = db.healthTextFormat or "CURRENTMAX"
    if healthFormat == "NONE" then
        -- The one legacy state that genuinely means "no health text".
        return nil
    end

    -- Color is re-copied per element so a group + its siblings never share
    -- the same color ref.
    local healthCommon = {
        anchor        = db.healthTextAnchor,
        offsetX       = db.healthTextX,
        offsetY       = db.healthTextY,
        useClassColor = db.healthTextUseClassColor,
        outline       = db.healthTextOutline,
        font          = db.healthFont,
        fontSize      = db.healthFontSize,
    }
    local function newHealthElem(extra)
        local e = {
            id            = nextID(),
            enabled       = true,
            label         = "",
            anchor        = healthCommon.anchor,
            offsetX       = healthCommon.offsetX,
            offsetY       = healthCommon.offsetY,
            color         = copyColor(db.healthTextColor),
            useClassColor = healthCommon.useClassColor,
            outline       = healthCommon.outline,
            font          = healthCommon.font,
            fontSize      = healthCommon.fontSize,
            overrides     = appearanceOverrides(),
        }
        for k, v in pairs(extra) do e[k] = v end
        return e
    end

    -- Name the GROUP cards, and only those. A group's card title falls back to the
    -- generic L["Text Group"] (Options/TextDesigner/UI/Options.lua), which says nothing
    -- about what is inside it -- a single-element card falls back to its content type's
    -- own label ("Current Health"), which is already more informative than "Health".
    -- So this is set per-branch rather than in newHealthElem, which seeds every health
    -- element.
    --
    -- ⚠ EDITOR-ONLY. The Resolver never reads `label`; it is the card's display name.
    -- Setting it changes nothing that renders on a frame.
    --
    -- ⚠ Localised at BUILD time, so it is baked in whatever language the profile was
    -- created in. Acceptable because the field is user-editable and this is only a
    -- default -- but it is why this is a plain string in the store and not a key.
    local healthGroupLabel = (DF.L and DF.L["Health"]) or "Health"

    if healthFormat == "PERCENT" then
        return newHealthElem({
            contentType = "hp_percent",
            decimals    = 0,
            hidePercent = db.healthTextHidePercent,
        })
    elseif healthFormat == "CURRENT" then
        return newHealthElem({
            contentType  = "hp_current",
            abbreviate   = db.healthTextAbbreviate,
            hideWhenZero = true,
        })
    elseif healthFormat == "DEFICIT" then
        return newHealthElem({
            contentType  = "hp_deficit",
            abbreviate   = db.healthTextAbbreviate,
            hideWhenZero = true,
        })
    elseif healthFormat == "CURRENT_PERCENT" then
        return newHealthElem({
            contentType    = "group",
            label          = healthGroupLabel,
            groupSeparator = " ",
            groupItems     = {
                { contentType = "hp_current", abbreviate = db.healthTextAbbreviate },
                { contentType = "hp_percent", decimals = 0 },
            },
        })
    else
        -- CURRENTMAX / CURRENT_MAX / unknown → the Config default (current / max).
        return newHealthElem({
            contentType    = "group",
            label          = healthGroupLabel,
            groupSeparator = " / ",
            groupItems     = {
                { contentType = "hp_current", abbreviate = db.healthTextAbbreviate, hideWhenZero = false },
                { contentType = "hp_max",     abbreviate = db.healthTextAbbreviate },
            },
        })
    end
end

-- Builds the elements array for one mode's legacy settings. `tdDB` is the
-- mode's db.textDesigner; the nextElementID counter on it is used + bumped
-- the same way the picker does so future manual adds keep unique ids.
local function buildElements(db, tdDB)
    tdDB.nextElementID = tdDB.nextElementID or 1
    local function nextID()
        local id = tdDB.nextElementID
        tdDB.nextElementID = id + 1
        return id
    end

    local elements = {}

    -- ── NAME ─────────────────────────────────────────────────
    elements[#elements + 1] = {
        id            = nextID(),
        contentType   = "name",
        enabled       = true,
        label         = "",
        anchor        = db.nameTextAnchor,
        offsetX       = db.nameTextX,
        offsetY       = db.nameTextY,
        color         = copyColor(db.nameTextColor),
        useClassColor = db.nameTextUseClassColor,
        outline       = db.nameTextOutline,
        font          = db.nameFont,
        fontSize      = db.nameFontSize,
        nameLength    = db.nameTextLength,
        truncateMode  = db.nameTextTruncateMode,
        overrides     = appearanceOverrides(),
    }

    -- ── HEALTH ───────────────────────────────────────────────
    -- Gated inside buildHealthElement on healthTextFormat ~= "NONE" — the
    -- only off-state the legacy live renderer ever honoured. Status text is
    -- gated on statusTextEnabled below because the live path reads that key.
    local healthElem = buildHealthElement(db, nextID)
    if healthElem then
        elements[#elements + 1] = healthElem
    end

    -- ── STATUS (Dead / Offline / Ghost) ──────────────────────
    if db.statusTextEnabled ~= false then
        elements[#elements + 1] = {
            id            = nextID(),
            contentType   = "status_text",
            enabled       = true,
            label         = "",
            anchor        = db.statusTextAnchor,
            offsetX       = db.statusTextX,
            offsetY       = db.statusTextY,
            color         = copyColor(db.statusTextColor),
            outline       = db.statusTextOutline,
            font          = db.statusTextFont,
            fontSize      = db.statusTextFontSize,
            overrides     = appearanceOverrides(),
        }
    end

    return elements
end

-- ============================================================
-- BASELINE DEFAULT (fresh / reset profiles — NOT a legacy migration)
-- ============================================================
-- The default Text Designer config a fresh or reset profile starts with:
-- name + health (current / max — matching the pre-Text-Designer default) +
-- status elements, built from the mode's Config defaults. This makes the
-- default a real BASELINE the factory carries directly, so fresh and reset
-- profiles no longer depend on MigrateTextDesignerFromLegacy running to build
-- their text — that migration is now only for genuinely-migrating pre-TD
-- profiles. Marked migratedFromLegacy/enabled/hideLegacyText to match exactly
-- what the migration produced, so it's a drop-in default (and the legacy
-- migration's guard treats it as already handled). Party and raid share the
-- same text defaults (RaidDefaults deep-copies PartyDefaults without overriding
-- them), so the mode arg only future-proofs a later divergence.
function DF:BuildDefaultTextDesignerConfig(mode)
    local defaults = (mode == "raid") and DF.RaidDefaults or DF.PartyDefaults
    local tdDB = DF.TextDesigner:EnsureDB({})
    if not defaults then
        -- Config not ready (very early boot) — hand back the empty schema.
        return tdDB
    end
    tdDB.elements = buildElements(defaults, tdDB)
    tdDB.enabled = true
    tdDB.hideLegacyText = true
    tdDB.migratedFromLegacy = true
    return tdDB
end

-- ============================================================
-- PUBLIC ENTRY POINT
-- ============================================================

-- Converts the legacy built-in text settings into Text Designer elements
-- for BOTH modes. When `force` is falsy each mode is skipped if it has
-- already been migrated or already has TD elements (don't clobber a
-- user-built setup). When `force` is true the elements array is rebuilt
-- from the current legacy settings, overwriting whatever was there.
function DF:MigrateTextDesignerFromLegacy(force)
    if not DF.db then
        DF:Debug("TD", "Migrate: DF.db not ready, aborting")
        return
    end

    for _, mode in ipairs({ "party", "raid" }) do
        local db = DF:GetDB(mode)
        if not db then
            DF:Debug("TD", "Migrate: no db for mode=%s", mode)
        else
            -- Build into the mode's TD PRESET (the canonical store after the
            -- Designer Presets migration). The migratedFromLegacy guard then
            -- lives on the preset, so re-runs across profile switches are
            -- no-ops instead of rebuilding a discarded inline table. `db` is
            -- still the source of the legacy name/health/status settings.
            local tdDB = (DF.GetModeTextDesigner and DF:GetModeTextDesigner(mode))
                or DF.TextDesigner:EnsureDB(db)
            DF.TextDesigner:EnsureDB({ textDesigner = tdDB })  -- ensure full schema

            local already = tdDB.migratedFromLegacy == true
                or (tdDB.elements and #tdDB.elements > 0)

            if not force and already then
                DF:Debug("TD", "Migrate: skipping mode=%s (already migrated or has elements)", mode)
            else
                tdDB.elements = buildElements(db, tdDB)

                -- Full switch: turn the system on and hide the built-in widgets
                -- so only the migrated TD elements show.
                tdDB.enabled = true
                tdDB.hideLegacyText = true
                tdDB.migratedFromLegacy = true

                DF:Debug("TD", "Migrate: mode=%s built %d element(s) (force=%s)",
                    mode, #tdDB.elements, tostring(force))
            end
        end
    end

    -- Refresh the preview (if the GUI is open) and every live frame so the
    -- change is visible immediately.
    if DF.TextDesigner.Preview and DF.TextDesigner.Preview.RefreshAll then
        DF.TextDesigner.Preview:RefreshAll()
    end
    if DF.UpdateAllFrames then
        DF:UpdateAllFrames()
    end
end

-- ============================================================
-- CORRECTIVE PASS — remove stray auto-migrated health text
-- ============================================================
-- The original (4.4-era) migration turned healthTextFormat == "NONE" — the only
-- legacy state where the live path showed NO health text — into a percent
-- element (its else-branch), so those users got a stray "%" / "x / y" on the
-- bar. The builder is fixed going forward, but already-migrated profiles keep
-- the artifact and the one-shot migratedFromLegacy guard stops a natural
-- re-run. This removes it, but ONLY when safe:
--   1. the profile was auto-migrated AND had health text off in the one way the
--      live renderer honoured (healthTextFormat == "NONE") — so nobody who
--      actually saw health text is touched. (4.6.0 keyed this on
--      showHealthText == false, which is the DEFAULT — that wrongly deleted
--      wanted health elements; RestoreMigratedHealthText below repairs it.)
--   2. the health element is still byte-identical to what the (buggy) migration
--      produced — so a moved / recoloured / reformatted element (user engaged with
--      it) is left alone.
-- Runs once per TD store via the healthMigrationCorrected flag.

local function deepEqual(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if k ~= "id" and not deepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if k ~= "id" and a[k] == nil then return false end
    end
    return true
end

-- Reproduce the health element EXACTLY as the PRE-FIX migration built it (PERCENT
-- fallback, no gate). Intentionally frozen to the old logic — it must match what
-- affected profiles actually contain, not what the fixed builder now produces.
local function legacyMigratedHealthElement(db)
    local e = {
        enabled       = true,
        label         = "",
        anchor        = db.healthTextAnchor,
        offsetX       = db.healthTextX,
        offsetY       = db.healthTextY,
        color         = copyColor(db.healthTextColor),
        useClassColor = db.healthTextUseClassColor,
        outline       = db.healthTextOutline,
        font          = db.healthFont,
        fontSize      = db.healthFontSize,
        overrides     = appearanceOverrides(),
    }
    local fmt = db.healthTextFormat or "PERCENT"
    if fmt == "CURRENT" then
        e.contentType, e.abbreviate, e.hideWhenZero = "hp_current", db.healthTextAbbreviate, true
    elseif fmt == "DEFICIT" then
        e.contentType, e.abbreviate, e.hideWhenZero = "hp_deficit", db.healthTextAbbreviate, true
    elseif fmt == "CURRENTMAX" or fmt == "CURRENT_MAX" then
        e.contentType    = "group"
        e.groupSeparator = " / "
        e.groupItems     = {
            { contentType = "hp_current", abbreviate = db.healthTextAbbreviate, hideWhenZero = false },
            { contentType = "hp_max",     abbreviate = db.healthTextAbbreviate },
        }
    elseif fmt == "CURRENT_PERCENT" then
        e.contentType    = "group"
        e.groupSeparator = " "
        e.groupItems     = {
            { contentType = "hp_current", abbreviate = db.healthTextAbbreviate },
            { contentType = "hp_percent", decimals = 0 },
        }
    else  -- PERCENT or unknown
        e.contentType, e.decimals, e.hidePercent = "hp_percent", 0, db.healthTextHidePercent
    end
    return e
end

function DF:CorrectStrayMigratedHealthText()
    if not DF.db then return end
    local total = 0
    local tremove = table.remove
    for _, mode in ipairs({ "party", "raid" }) do
        local db = DF:GetDB(mode)
        local tdDB = db and ((DF.GetModeTextDesigner and DF:GetModeTextDesigner(mode))
            or (DF.TextDesigner and DF.TextDesigner.EnsureDB and DF.TextDesigner:EnsureDB(db)))
        if db and tdDB and not tdDB.healthMigrationCorrected then
            -- Eligible only when this profile was auto-migrated AND had health
            -- text off in the way the live renderer honoured (format NONE).
            if tdDB.migratedFromLegacy == true and db.healthTextFormat == "NONE"
                and type(tdDB.elements) == "table" then
                local expected = legacyMigratedHealthElement(db)
                for i = #tdDB.elements, 1, -1 do
                    if deepEqual(expected, tdDB.elements[i]) then
                        tremove(tdDB.elements, i)
                        total = total + 1
                    end
                end
            end
            -- Mark every visited store corrected — including the ineligible paths
            -- (not auto-migrated, or health text was on) — so the scan never re-runs.
            tdDB.healthMigrationCorrected = true
        end
    end
    if total > 0 then
        DF:Debug("TD", "CorrectStrayMigratedHealthText: removed %d stray health element(s)", total)
        if DF.TextDesigner and DF.TextDesigner.Preview and DF.TextDesigner.Preview.RefreshAll then
            DF.TextDesigner.Preview:RefreshAll()
        end
        if DF.UpdateAllFrames then DF:UpdateAllFrames() end
    end

    -- Chained here (rather than separately wired in Core/Profile) so it runs
    -- at both existing call sites — login and profile switch — and always
    -- AFTER the stray-element removal above.
    DF:RestoreMigratedHealthText()
end

-- ============================================================
-- CORRECTIVE PASS 2 — restore health text the 4.6.0 migration dropped
-- ============================================================
-- 4.6.0 gated the migrated health element on showHealthText — a key the live
-- legacy renderer never read (test-mode only, no GUI control, defaults to
-- false). Two damage classes shipped:
--   * fresh 4.6.0 migrations skipped the health element entirely; and
--   * the stray-"%" corrective pass above deleted 4.4/4.5-era migrated health
--     elements from any profile whose (unrelated) showHealthText was false.
-- For auto-migrated stores that ended up with NO health element even though
-- the legacy format says health text was on, rebuild it from the mode's
-- legacy settings. One-shot per store (healthRestoredV2). Known trade-off: a
-- user who deliberately deleted their auto-migrated health element gets it
-- back once (called out in the changelog); the flag stops any repeat.

-- True if any element (or item of a composite group) renders a health value.
local function isHealthContent(contentType)
    return type(contentType) == "string" and contentType:sub(1, 3) == "hp_"
end

local function hasHealthElement(elements)
    for _, e in ipairs(elements) do
        if isHealthContent(e.contentType) then return true end
        if e.contentType == "group" and type(e.groupItems) == "table" then
            for _, item in ipairs(e.groupItems) do
                if isHealthContent(item.contentType) then return true end
            end
        end
    end
    return false
end

function DF:RestoreMigratedHealthText()
    if not DF.db then return end
    local total = 0
    for _, mode in ipairs({ "party", "raid" }) do
        local db = DF:GetDB(mode)
        local tdDB = db and ((DF.GetModeTextDesigner and DF:GetModeTextDesigner(mode))
            or (DF.TextDesigner and DF.TextDesigner.EnsureDB and DF.TextDesigner:EnsureDB(db)))
        if db and tdDB and not tdDB.healthRestoredV2 then
            if tdDB.migratedFromLegacy == true
                and type(tdDB.elements) == "table"
                and (db.healthTextFormat or "CURRENTMAX") ~= "NONE"
                and not hasHealthElement(tdDB.elements) then
                tdDB.nextElementID = tdDB.nextElementID or 1
                local function nextID()
                    local id = tdDB.nextElementID
                    tdDB.nextElementID = id + 1
                    return id
                end
                local elem = buildHealthElement(db, nextID)
                if elem then
                    tdDB.elements[#tdDB.elements + 1] = elem
                    total = total + 1
                end
            end
            -- Mark every visited store — including ineligible ones — so the
            -- scan never re-runs.
            tdDB.healthRestoredV2 = true
        end
    end
    if total > 0 then
        DF:Debug("TD", "RestoreMigratedHealthText: rebuilt %d health element(s) from legacy settings", total)
        if DF.TextDesigner and DF.TextDesigner.Preview and DF.TextDesigner.Preview.RefreshAll then
            DF.TextDesigner.Preview:RefreshAll()
        end
        if DF.UpdateAllFrames then DF:UpdateAllFrames() end
    end
end

DF:Debug("TD", "Migration module loaded (channel=%s)", tostring(DF.RELEASE_CHANNEL))
