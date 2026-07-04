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
    -- Only migrate health text if the user actually had it ENABLED. showHealthText
    -- defaults to false, so without this gate the migration injected a health
    -- element onto frames for everyone who never turned health text on — showing a
    -- stray "%" (PERCENT / nil format) or "x / y" on the health bar. Status text
    -- is gated the same way (statusTextEnabled) below; health was the gap.
    if db.showHealthText ~= false then
        -- Default to the real Config default (CURRENTMAX), NOT "PERCENT" — a nil
        -- format is the unset default, and falling back to PERCENT was what turned
        -- it into a bare "%". Composite formats render as one group FontString that
        -- owns the font/size/outline/color/anchor/offset.
        local healthFormat = db.healthTextFormat or "CURRENTMAX"
        -- Color is re-copied per element (in newHealthElem) so a group + its
        -- siblings never share the same color ref.
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

        if healthFormat == "PERCENT" then
            elements[#elements + 1] = newHealthElem({
                contentType = "hp_percent",
                decimals    = 0,
                hidePercent = db.healthTextHidePercent,
            })
        elseif healthFormat == "CURRENT" then
            elements[#elements + 1] = newHealthElem({
                contentType  = "hp_current",
                abbreviate   = db.healthTextAbbreviate,
                hideWhenZero = true,
            })
        elseif healthFormat == "DEFICIT" then
            elements[#elements + 1] = newHealthElem({
                contentType  = "hp_deficit",
                abbreviate   = db.healthTextAbbreviate,
                hideWhenZero = true,
            })
        elseif healthFormat == "CURRENT_PERCENT" then
            elements[#elements + 1] = newHealthElem({
                contentType    = "group",
                groupSeparator = " ",
                groupItems     = {
                    { contentType = "hp_current", abbreviate = db.healthTextAbbreviate },
                    { contentType = "hp_percent", decimals = 0 },
                },
            })
        else
            -- CURRENTMAX / CURRENT_MAX / unknown → the Config default (current / max).
            elements[#elements + 1] = newHealthElem({
                contentType    = "group",
                groupSeparator = " / ",
                groupItems     = {
                    { contentType = "hp_current", abbreviate = db.healthTextAbbreviate, hideWhenZero = false },
                    { contentType = "hp_max",     abbreviate = db.healthTextAbbreviate },
                },
            })
        end
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
-- The pre-fix migration ignored showHealthText, so profiles that had health text
-- OFF still got an auto-built health element (a stray "%" / "x / y" on the bar).
-- The builder is fixed going forward, but already-migrated profiles keep the
-- artifact and the one-shot migratedFromLegacy guard stops a natural re-run. This
-- removes it, but ONLY when safe:
--   1. the profile was auto-migrated AND had health text OFF (showHealthText ==
--      false) — so nobody who actually wanted health text is touched; and
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
            -- Eligible only when this profile was auto-migrated AND had health text off.
            if tdDB.migratedFromLegacy == true and db.showHealthText == false
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
end

DF:Debug("TD", "Migration module loaded (channel=%s)", tostring(DF.RELEASE_CHANNEL))
