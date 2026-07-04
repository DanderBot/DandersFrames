local addonName, DF = ...

-- ============================================================
-- AUTO PROFILES UI - Raid-only automatic profile switching
-- ============================================================

local AutoProfilesUI = {}
DF.AutoProfilesUI = AutoProfilesUI

local L = DF.L
local format = string.format

-- Local references
local C_RAID = {r = 1.0, g = 0.5, b = 0.2, a = 1}
local C_WARNING = {r = 1.0, g = 0.67, b = 0.0, a = 1}

-- Deep-copy a value (recursive for nested tables)
local function DeepCopyValue(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do
        copy[k] = DeepCopyValue(v)
    end
    return copy
end

-- Content type definitions
-- title/description read L["..."]; at file scope that returns the enUS baseline
-- (the languageOverride overlay runs later, at ADDON_LOADED). Build them in a
-- registered refresh fn so Core rebuilds them after the overlay.
local CONTENT_TYPES = {}

local function RefreshContentTypes()
    CONTENT_TYPES = {
        {
            key = "instanced",
            title = L["Instanced / PvP"],
            description = L["Raids, battlegrounds (1-40)"],
            minRange = 1,
            maxRange = 40,
            isFixed = false,
        },
        {
            key = "mythic",
            title = L["Mythic"],
            description = L["20 players (fixed)"],
            minRange = 20,
            maxRange = 20,
            isFixed = true,
        },
        {
            key = "openWorld",
            title = L["Open World"],
            description = L["World bosses, outdoor raids (1-40)"],
            minRange = 1,
            maxRange = 40,
            isFixed = false,
        },
    }
end

RefreshContentTypes()
DF:RegisterLocaleRefresh(RefreshContentTypes)

-- ============================================================
-- LOCAL HELPERS for db.raid access and snapshot lookups
-- Defined here so all functions in this file can reference them
-- ============================================================

-- Parse table-based keys (e.g., "raidGroupVisible_1" -> "raidGroupVisible", 1)
local function ParseTableKey(key)
    local tableName, index = key:match("^(.+)_(%d+)$")
    if tableName and index then
        return tableName, tonumber(index)
    end
    return nil, nil
end

-- Parse pinned frame keys (e.g., "pinned.1.scale" -> 1, "scale")
local function ParsePinnedKey(key)
    local setIndex, setting = key:match("^pinned%.(%d+)%.(.+)$")
    if setIndex and setting then
        return tonumber(setIndex), setting
    end
    return nil, nil
end

-- Settings that can be overridden per pinned frame set.
-- Decoupled from auto layouts (2026-06-07): pinned frames are a global,
-- per-mode modular highlight. The ONLY thing a raid auto layout overrides is
-- whether each set is shown (enabled) for that layout — everything else is
-- global and edited on the Pinned Frames page. This keeps pinned settings out
-- of the layout-override store entirely (no more stale pinned.N.* data).
local PINNED_OVERRIDABLE = {
    enabled = true,
}

-- Transient / UI-state keys that must NEVER become a layout override — they're
-- not per-layout settings, so capturing them poisons the layout. raidLocked is the
-- culprit: the per-layout Unlock button unlocks frames DURING an edit session, so
-- raidLocked goes false; if editing exits while still unlocked, the diff-scan
-- stored raidLocked=false and the layout then forced the frames unlocked whenever
-- it activated (the Lock/Unlock button read backwards). `locked` is the party
-- equivalent, listed for symmetry.
local NON_OVERRIDABLE_KEYS = {
    raidLocked = true,
    locked = true,
}

-- True unless `key` is non-overridable: a pinned key (pinned.N.setting) whose
-- setting isn't overridable, or a transient UI-state key. The single gate that
-- keeps such keys out of the layout override store — used by SetProfileSetting /
-- IsSettingOverridden / the ExitEditing diff-scan / ApplyRuntimeProfile.
local function IsKeyOverridable(key)
    local _, setting = ParsePinnedKey(key)
    if setting then
        return PINNED_OVERRIDABLE[setting] == true
    end
    if NON_OVERRIDABLE_KEYS[key] then return false end
    return true
end

-- ============================================================
-- OVERRIDE KEY → TAB MAPPING
-- Maps override key prefixes to sidebar tab IDs for display.
-- Ordered most-specific first to avoid false matches
-- (e.g. "healthText" before "health", "defensiveIcon" before "debuff").
-- ============================================================
-- The 3rd element of each row reads L["..."]; at file scope that returns the
-- enUS baseline (the languageOverride overlay runs later, at ADDON_LOADED).
-- Build the map in a registered refresh fn so the tab labels follow the locale.
local OVERRIDE_TAB_MAP = {}

local function RefreshOverrideTabMap()
    OVERRIDE_TAB_MAP = {
    -- Display
    {"soloMode",            "display_visibility",   L["Visibility"]},
    {"showMinimapButton",   "display_visibility",   L["Visibility"]},
    {"restedIndicator",     "display_visibility",   L["Visibility"]},
    {"hidePlayerFrame",     "display_visibility",   L["Visibility"]},
    {"hideDefaultPlayerFrame", "display_visibility", L["Visibility"]},
    {"hideBlizzardPartyFrames", "display_visibility", L["Visibility"]},
    {"hideBlizzardRaidFrames", "display_visibility", L["Visibility"]},
    {"showBlizzardSideMenu", "display_visibility",  L["Visibility"]},
    {"tooltip",             "display_tooltips",     L["Tooltips"]},
    {"rangeFade",           "display_fading",       L["Fading"]},
    {"oor",                 "display_fading",       L["Fading"]},
    {"dead",                "display_fading",       L["Fading"]},
    {"offline",             "display_fading",       L["Fading"]},
    {"pet",                 "display_pets",         L["Pet Frames"]},
    -- General (specific before generic)
    {"fontShadow",          "general_fonts",        L["Global Fonts"]},
    {"groupLabel",          "general_labels",       L["Group Labels"]},
    {"raidTestFrameCount",  "general_frame",        L["Frame"]},
    {"raidUseGroups",       "general_frame",        L["Frame"]},
    {"raidGroupVisible",    "general_frame",        L["Frame"]},
    {"raidPlayerPerRow",    "general_frame",        L["Frame"]},
    {"raidFlat",            "general_frame",        L["Frame"]},
    {"frame",               "general_frame",        L["Frame"]},
    {"background",          "general_frame",        L["Frame"]},
    {"missingHealth",       "general_frame",        L["Frame"]},
    {"border",              "general_frame",        L["Frame"]},
    {"anchor",              "general_frame",        L["Frame"]},
    {"sort",                "general_sorting",      L["Sorting"]},
    {"selfPosition",        "general_sorting",      L["Sorting"]},
    {"rolePriority",        "general_sorting",      L["Sorting"]},
    {"classPriority",       "general_sorting",      L["Sorting"]},
    {"colorPickerOverride", "general_integrations", L["Integrations"]},
    {"colorPickerGlobalOverride", "general_integrations", L["Integrations"]},
    {"masqueBorderControl", "general_integrations", L["Integrations"]},
    {"buffDisableMouse",    "general_integrations", L["Integrations"]},
    {"debuffDisableMouse",  "general_integrations", L["Integrations"]},
    {"defensiveIconDisableMouse", "general_integrations", L["Integrations"]},
    {"targetedSpellDisableMouse", "general_integrations", L["Integrations"]},
    -- Bars (specific text keys before generic "health" prefix).
    -- healthTexture MUST precede healthText: it's the health BAR texture, but
    -- a bare prefix match classifies it as health TEXT (and the legacy-text
    -- cleanup would then delete a live override).
    {"healthTexture",       "bars_health",          L["Health Bar"]},
    {"healthText",          "text_health",          L["Health Text"]},
    {"healthFont",          "text_health",          L["Health Text"]},
    {"health",              "bars_health",          L["Health Bar"]},
    {"classColor",          "bars_health",          L["Health Bar"]},
    {"smoothBars",          "bars_health",          L["Health Bar"]},
    {"resourceBar",         "bars_resource",        L["Resource Bar"]},
    {"absorbBar",           "bars_absorb",          L["Absorbs"]},
    {"healAbsorb",          "bars_absorb",          L["Absorbs"]},
    {"healPrediction",      "bars_healpred",        L["Heal Prediction"]},
    -- Text
    {"statusText",          "text_status",          L["Status Text"]},
    {"textDesigner",        "text_designer",        L["Text Designer"]},
    {"name",                "text_name",            L["Name Text"]},
    -- Auras (specific before generic)
    -- myBuffIndicator removed — feature deprecated and hidden from UI
    {"bossDebuff",          "auras_bossdebuffs",    L["Boss Debuffs"]},
    {"missingBuff",         "auras_missingbuffs",   L["Missing Buffs"]},
    {"defensiveIcon",       "auras_defensiveicon",  L["Defensive Icon"]},
    {"debuff",              "auras_debuffs",        L["Debuffs"]},
    {"buff",                "auras_buffs",          L["Buffs"]},
    {"dispel",              "auras_dispel",         L["Dispel Overlay"]},
    {"auraDesigner",        "auras_auradesigner",   L["Aura Designer"]},
    -- Indicators (specific before generic)
    {"personalTargeted",    "indicators_personal_targeted", L["Personal Targeted"]},
    {"targetedList",        "indicators_targetedlist", L["Targeted List"]},
    {"targetedSpell",       "indicators_targetedspells", L["Targeted Spells"]},
    {"roleIcon",            "indicators_icons",     L["Icons"]},
    {"leaderIcon",          "indicators_icons",     L["Icons"]},
    {"raidTargetIcon",      "indicators_icons",     L["Icons"]},
    {"readyCheckIcon",      "indicators_icons",     L["Icons"]},
    {"summonIcon",          "indicators_icons",     L["Icons"]},
    {"resurrectionIcon",    "indicators_icons",     L["Icons"]},
    {"phasedIcon",          "indicators_icons",     L["Icons"]},
    {"afkIcon",             "indicators_icons",     L["Icons"]},
    {"vehicleIcon",         "indicators_icons",     L["Icons"]},
    {"raidRoleIcon",        "indicators_icons",     L["Icons"]},
    {"statusIconFont",      "indicators_icons",     L["Icons"]},
    {"selectionHighlight",  "indicators_highlights", L["Highlights"]},
    {"hoverHighlight",      "indicators_highlights", L["Highlights"]},
    {"aggroHighlight",      "indicators_highlights", L["Highlights"]},
    {"aggro",               "indicators_highlights", L["Highlights"]},
    -- Pinned frames (prefix match for "pinned.N.setting" format)
    {"pinned.",             "general_pinnedframes", L["Pinned Frames"]},
    }
end

RefreshOverrideTabMap()
DF:RegisterLocaleRefresh(RefreshOverrideTabMap)

-- Returns tabId, tabLabel for a given override key
local function GetOverrideTabId(key)
    -- Strip table-based suffix (e.g. "raidGroupVisible_1" → "raidGroupVisible")
    local baseKey = key:match("^(.+)_%d+$") or key
    for _, entry in ipairs(OVERRIDE_TAB_MAP) do
        local prefix = entry[1]
        if baseKey:sub(1, #prefix) == prefix then
            return entry[2], entry[3]
        end
    end
    return nil, "Unknown"
end

-- ============================================================
-- Cleanup: orphaned legacy built-in text overrides in auto-layouts
-- The Text Designer migration took over the built-in Name / Health / Status
-- text. A raid auto-layout edited BEFORE that migration can still carry those
-- legacy text keys (nameFontSize, healthFontSize, statusText*, …) as overrides —
-- now inert (IsLegacyTextHidden hides the legacy FontStrings), so they only
-- clutter the override list beside the layout's textDesignerPreset. Strip them.
--
-- SAFETY: only runs once the raid TD has ACTUALLY migrated the legacy settings
-- (migratedFromLegacy) — the values are preserved in Text Designer first, and we
-- never strip while the legacy text is still live. Stripping is visually inert
-- (TD ignores these keys); it only declutters. Auto-layouts are raid-only, so we
-- gate on the raid text config. Per-profile guard, idempotent.
-- ============================================================
-- The DESTRUCTIVE strip decision uses its own boundary-checked matcher, NOT
-- the display-oriented GetOverrideTabId prefix map: a bare prefix grab
-- classifies healthTexture (the health BAR texture) as healthText — deleting a
-- real, live override. A prefix only counts as a legacy text key when the key
-- continues with an uppercase letter or digit (camelCase boundary) or ends
-- exactly there; two legacy oddballs that don't share the prefixes are listed
-- explicitly.
local LEGACY_TEXT_KEY_PREFIXES = {
    "nameText", "nameFont",
    "healthText", "healthFont",
    "statusText",
}
local LEGACY_TEXT_EXACT_KEYS = {
    showHealthText = true,
    nameColorClass = true,
}
local function IsLegacyTextOverrideKey(key)
    if type(key) ~= "string" then return false end
    -- Strip table-based suffix ("foo_3" → "foo"), mirroring GetOverrideTabId.
    local baseKey = key:match("^(.+)_%d+$") or key
    if LEGACY_TEXT_EXACT_KEYS[baseKey] then return true end
    for _, prefix in ipairs(LEGACY_TEXT_KEY_PREFIXES) do
        local n = #prefix
        if baseKey:sub(1, n) == prefix then
            local nextChar = baseKey:sub(n + 1, n + 1)
            if nextChar == "" or nextChar:match("^[%u%d]") then
                return true
            end
        end
    end
    return false
end

local function RaidTextMigrated()
    -- The TD legacy migration flags migratedFromLegacy on whatever owns raid text.
    -- Preset build: the current raid preset, OR the canonical "Raid" preset the
    -- migration always materialises (covers a raid mode repointed elsewhere).
    -- Pre-preset build (alpha.6): inline db.raid.textDesigner.
    if DF.GetTextDesignerPresets then
        if DF.GetModeTextDesigner then
            local td = DF:GetModeTextDesigner("raid")
            if type(td) == "table" and td.migratedFromLegacy == true then return true end
        end
        local lib = DF:GetTextDesignerPresets()
        local raidPreset = lib and lib["Raid"]
        return type(raidPreset) == "table" and raidPreset.migratedFromLegacy == true
    end
    local rdb = DF.GetRaidDB and DF:GetRaidDB()
    local td = rdb and rdb.textDesigner
    return type(td) == "table" and td.migratedFromLegacy == true
end

function DF:CleanupLegacyTextLayoutOverrides()
    local prof = DF._realProfile or DF.db
    if not prof or prof._legacyTextOverrideCleanupV1 then return end
    local autoDb = prof.raidAutoProfiles
    if type(autoDb) ~= "table" then return end
    -- Don't strip — or set the guard — until the legacy text is safely in TD; an
    -- unmigrated profile is retried on its next login / profile switch.
    if not RaidTextMigrated() then return end

    local function stripLayout(layout)
        local ov = layout and layout.overrides
        if type(ov) ~= "table" then return end
        local toStrip
        for key in pairs(ov) do
            if IsLegacyTextOverrideKey(key) then
                toStrip = toStrip or {}
                toStrip[#toStrip + 1] = key
            end
        end
        if toStrip then for _, key in ipairs(toStrip) do ov[key] = nil end end
    end

    for _, ctKey in ipairs({ "instanced", "openWorld" }) do
        local ct = autoDb[ctKey]
        if type(ct) == "table" and type(ct.profiles) == "table" then
            for _, layout in pairs(ct.profiles) do stripLayout(layout) end
        end
    end
    if type(autoDb.mythic) == "table" then stripLayout(autoDb.mythic.profile) end

    prof._legacyTextOverrideCleanupV1 = true
end

-- Groups override keys by tab, returns { [tabId] = { tabLabel, keys = {} } }, unknownKeys
local function GroupOverridesByTab(overrides)
    -- A table-valued override (e.g. "raidGroupVisible") and its flat indexed
    -- siblings ("raidGroupVisible_5".."_8") can both be stored — the per-control
    -- path writes the flat keys, while ExitEditing's diff safety-net writes the
    -- whole table. They're the same setting, so when the whole-table form exists
    -- we hide the redundant flat siblings (the grouped form reads cleaner).
    local wholeTableKeys = {}
    for key, val in pairs(overrides) do
        if type(val) == "table" then wholeTableKeys[key] = true end
    end
    local groups = {}
    local unknownKeys = {}
    for key, _ in pairs(overrides) do
        local base = key:match("^(.+)_%d+$")
        if base and wholeTableKeys[base] then
            -- redundant flat sibling of a whole-table override — skip
        else
            local tabId, tabLabel = GetOverrideTabId(key)
            if tabId then
                if not groups[tabId] then
                    groups[tabId] = { tabLabel = tabLabel, keys = {} }
                end
                tinsert(groups[tabId].keys, key)
            else
                tinsert(unknownKeys, key)
            end
        end
    end
    return groups, unknownKeys
end

-- Canonical override count for display: everything that actually gets shown
-- (mapped groups + "Other"), deduped so redundant flat siblings of a whole-table
-- override aren't counted. Used by the row badge, the editing status line, and
-- /df overrides so all three agree.
local function CountDisplayedOverrides(overrides)
    if not overrides then return 0 end
    local groups, unknownKeys = GroupOverridesByTab(overrides)
    local n = #unknownKeys
    for _, group in pairs(groups) do n = n + #group.keys end
    return n
end

-- Deep value equality (used to skip leaves of a table override that match global).
local function OverrideDeepEqual(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not OverrideDeepEqual(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

-- Walk a table-valued override against its global counterpart and emit ONLY the
-- entries that differ. To keep a deep config (Aura Designer) readable we COLLAPSE
-- boring single-child wrapper levels into one breadcrumb header
-- (auras > HolyPriest > GuardianSpirit) and then list the actual changed leaves
-- indented beneath it — instead of repeating that long path on every leaf.
--   emit(indent, label, valueStr)  -- valueStr == nil → a header/breadcrumb line
-- ovr = override table; glob = the global value (DF._realRaidDB[key]) and may be
-- nil/non-table (then everything in ovr differs). budget = {n=number}
-- (nil n = unlimited); maxDepth collapses deeper tables to "{…}".
local function WalkOverrideDiff(ovr, glob, prefix, indent, depth, maxDepth, budget, emit)
    -- Friendly display key: TD elements show their name, not the array index.
    local function disp(k)
        local ov = ovr[k]
        if type(ov) == "table" and ov.contentType and DF.TextDesigner and DF.TextDesigner.ElementDisplayName then
            return DF.TextDesigner.ElementDisplayName(ov) or tostring(k)
        end
        return tostring(k)
    end

    -- Collect only the children that differ from global.
    local diff = {}
    for k in pairs(ovr) do
        local gv = (type(glob) == "table") and glob[k] or nil
        if not OverrideDeepEqual(ovr[k], gv) then diff[#diff + 1] = k end
    end
    table.sort(diff, function(a, b) return tostring(a) < tostring(b) end)

    -- Single differing child that is itself a (non-colour) table → fold this level
    -- into the breadcrumb and recurse, so wrapper levels don't each cost a line.
    if #diff == 1 and depth < maxDepth then
        local k = diff[1]
        local ov = ovr[k]
        if type(ov) == "table" and not (ov.r and ov.g and ov.b) then
            local newPrefix = (prefix == "") and disp(k) or (prefix .. " > " .. disp(k))
            local gv = (type(glob) == "table") and glob[k] or nil
            return WalkOverrideDiff(ov, gv, newPrefix, indent, depth + 1, maxDepth, budget, emit)
        end
    end

    -- Print the accumulated breadcrumb once as a header, then list children deeper.
    if prefix ~= "" then
        emit(indent, prefix, nil)
        indent = indent .. "  "
    end
    for _, k in ipairs(diff) do
        if budget.n and budget.n <= 0 then emit(indent, "…", nil) return end
        local ov = ovr[k]
        local gv = (type(glob) == "table") and glob[k] or nil
        if type(ov) == "table" and not (ov.r and ov.g and ov.b) then
            if depth >= maxDepth then
                emit(indent, disp(k), "{…}")
                if budget.n then budget.n = budget.n - 1 end
            else
                -- This child becomes its own (possibly collapsed) sub-section.
                WalkOverrideDiff(ov, gv, disp(k), indent, depth + 1, maxDepth, budget, emit)
            end
        else
            local dv
            if type(ov) == "table" then dv = string.format("(%.2f, %.2f, %.2f)", ov.r, ov.g, ov.b)
            elseif type(ov) == "boolean" then dv = ov and "true" or "false"
            else dv = tostring(ov) end
            emit(indent, disp(k), dv)
            if budget.n then budget.n = budget.n - 1 end
        end
    end
end

-- Get a value from the real raid database, handling raid keys, table keys, and pinned keys.
-- Always reads the real table (DF._realRaidDB) — never the overlay proxy.
local function GetRaidValue(key)
    local realRaid = DF._realRaidDB or (DF.db and DF.db.raid)
    if not realRaid then return nil end

    -- Pinned frame key (stored at raid.pinnedFrames)
    local setIndex, setting = ParsePinnedKey(key)
    if setIndex and setting then
        local pf = realRaid.pinnedFrames
        local sets = pf and pf.sets
        if sets and sets[setIndex] then
            return sets[setIndex][setting]
        end
        return nil
    end

    -- Table-based raid key
    local tableName, index = ParseTableKey(key)
    if tableName and index then
        local tbl = realRaid[tableName]
        if type(tbl) == "table" then
            return tbl[index]
        end
        return nil
    end

    -- Direct raid key
    return realRaid[key]
end

-- Make `dst` deeply equal `src` while PRESERVING the identity of dst and of every
-- nested table whose key/index aligns. Applying/restoring a whole-table override this
-- way keeps references captured elsewhere valid — the Text Designer page binds cards
-- and offset sliders straight to element objects (CreateSlider(..., elem, "offsetX")),
-- and the Preview binds to db.textDesigner. A plain `realRaid.textDesigner = newTable`
-- swaps that table (and its .elements array) out from under those bindings, so edits
-- land in the orphaned old table while the test frames read the new one — the TD
-- "test mode stops updating after a layout switch" freeze.
local function DeepReplaceInPlace(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            DeepReplaceInPlace(dst[k], v)
        else
            dst[k] = v
        end
    end
    for k in pairs(dst) do
        if src[k] == nil then dst[k] = nil end
    end
end

-- Set a value in the real raid database, handling raid keys, table keys, and pinned keys.
-- Always writes to the real table (DF._realRaidDB) — never the overlay proxy.
local function SetRaidValue(key, value)
    local realRaid = DF._realRaidDB or (DF.db and DF.db.raid)
    if not realRaid then return end

    -- Pinned frame key (stored at raid.pinnedFrames)
    local setIndex, setting = ParsePinnedKey(key)
    if setIndex and setting then
        local pf = realRaid.pinnedFrames
        local sets = pf and pf.sets
        if sets and sets[setIndex] then
            sets[setIndex][setting] = value
        end
        return
    end

    -- Table-based raid key
    local tableName, index = ParseTableKey(key)
    if tableName and index then
        local tbl = realRaid[tableName]
        if type(tbl) == "table" then
            tbl[index] = value
        end
    else
        -- Whole-table override (textDesigner, auraDesigner, …): update CONTENTS in
        -- place (deep) so the table object's identity is preserved and designer
        -- bindings to it / its elements survive a layout switch.
        local existing = realRaid[key]
        if type(existing) == "table" and type(value) == "table" then
            DeepReplaceInPlace(existing, value)
        else
            realRaid[key] = value
        end
    end
end

-- Get a value from the global snapshot, handling all key types
-- Pinned keys are stored directly in the snapshot as "pinned.1.scale" etc
local function GetSnapshotValue(snapshot, key)
    if not snapshot then return nil, false end
    
    -- Direct key match (works for pinned keys and direct raid keys)
    if snapshot[key] ~= nil then
        return snapshot[key], true
    end
    
    -- Table-based key (e.g., "raidGroupVisible_1" -> snapshot["raidGroupVisible"][1])
    local tableName, index = ParseTableKey(key)
    if tableName and index and type(snapshot[tableName]) == "table" then
        return snapshot[tableName][index], true
    end
    
    return nil, false
end

-- Find a matching profile within a content type by raid size
-- Returns the first profile whose min-max range includes raidSize, or nil
local function FindMatchingProfile(contentKey, raidSize)
    local autoDb = DF.db and DF.db.raidAutoProfiles
    if not autoDb then return nil end

    local ct = autoDb[contentKey]
    if not ct or not ct.profiles then return nil end

    for _, profile in ipairs(ct.profiles) do
        if raidSize >= profile.min and raidSize <= profile.max then
            DF:Debug("LAYOUT", "FindMatchingProfile: matched \"%s\" for %s (size %d, range %d-%d)", profile.name or "?", contentKey, raidSize, profile.min, profile.max)
            return profile
        end
    end

    DF:Debug("LAYOUT", "FindMatchingProfile: no match for %s (size %d, %d profiles checked)", contentKey, raidSize, #ct.profiles)
    return nil
end

-- Initialize database defaults
function AutoProfilesUI:InitDefaults()
    if not DF.db.raidAutoProfiles then
        DF.db.raidAutoProfiles = {
            enabled = false,
            howItWorksCollapsed = false,
            instanced = { profiles = {} },
            mythic = { profile = nil },
            openWorld = { profiles = {} }
        }
    end
    -- Migration: add howItWorksCollapsed if missing from existing db
    if DF.db.raidAutoProfiles.howItWorksCollapsed == nil then
        DF.db.raidAutoProfiles.howItWorksCollapsed = false
    end

    -- One-time cleanup: strip transient/never-override keys (raidLocked etc.) that
    -- an earlier build's diff-scan may have captured into layout overrides. Such a
    -- key forced the frames locked/unlocked whenever its layout activated (the
    -- Lock/Unlock button read backwards). Runtime/edit paths now skip these keys,
    -- but scrub the stored data so override counts are accurate too.
    local ap = DF.db.raidAutoProfiles
    if not ap.nonOverridableCleanupDone then
        local function cleanOverrides(profile)
            if profile and profile.overrides then
                for key in pairs(NON_OVERRIDABLE_KEYS) do
                    profile.overrides[key] = nil
                end
            end
        end
        if ap.mythic then cleanOverrides(ap.mythic.profile) end
        for _, ct in ipairs({ "instanced", "openWorld" }) do
            if ap[ct] and ap[ct].profiles then
                for _, p in ipairs(ap[ct].profiles) do cleanOverrides(p) end
            end
        end
        ap.nonOverridableCleanupDone = true
    end
end

-- Get profiles for a content type
function AutoProfilesUI:GetProfiles(contentKey)
    self:InitDefaults()
    if contentKey == "mythic" then
        local profile = DF.db.raidAutoProfiles.mythic.profile
        return profile and {profile} or {}
    else
        return DF.db.raidAutoProfiles[contentKey].profiles or {}
    end
end

-- Check for range overlap within a content type
function AutoProfilesUI:CheckRangeOverlap(contentKey, min, max, excludeIndex)
    local profiles = self:GetProfiles(contentKey)
    for i, p in ipairs(profiles) do
        if i ~= excludeIndex then
            if min <= p.max and max >= p.min then
                return p  -- Returns the overlapping profile
            end
        end
    end
    return nil
end

-- Create a profile
function AutoProfilesUI:CreateProfile(contentKey, name, min, max)
    self:InitDefaults()
    DF:Debug("LAYOUT", "CreateProfile: contentKey=%s name=\"%s\" min=%s max=%s", contentKey, name or "?", tostring(min), tostring(max))

    if contentKey == "mythic" then
        DF.db.raidAutoProfiles.mythic.profile = {
            name = name or "Mythic Setup",
            overrides = {}
        }
        DF:Debug("LAYOUT", "CreateProfile: mythic layout created")
        return true
    end

    -- Check for name conflict
    local profiles = DF.db.raidAutoProfiles[contentKey].profiles
    for _, p in ipairs(profiles) do
        if p.name:lower() == name:lower() then
            DF:DebugWarn("LAYOUT", "CreateProfile: name conflict with \"%s\"", name)
            return false, L["Name already exists"]
        end
    end

    -- Check for range overlap
    local overlap = self:CheckRangeOverlap(contentKey, min, max)
    if overlap then
        return false, format(L["Overlaps with \"%s\""], overlap.name)
    end
    
    -- Create the profile
    table.insert(profiles, {
        name = name,
        min = min,
        max = max,
        overrides = {}
    })
    
    -- Sort by min range
    table.sort(profiles, function(a, b) return a.min < b.min end)
    
    return true
end

-- Delete a profile
function AutoProfilesUI:DeleteProfile(contentKey, index)
    self:InitDefaults()

    -- Capture a reference before deletion to check if it was the active runtime profile
    local deletedProfile
    if contentKey == "mythic" then
        deletedProfile = DF.db.raidAutoProfiles.mythic.profile
        DF.db.raidAutoProfiles.mythic.profile = nil
    else
        local profiles = DF.db.raidAutoProfiles[contentKey].profiles
        if profiles[index] then
            deletedProfile = profiles[index]
            table.remove(profiles, index)
        else
            DF:DebugWarn("LAYOUT", "DeleteProfile: index %s not found in %s", tostring(index), contentKey)
            return false
        end
    end

    DF:Debug("LAYOUT", "DeleteProfile: removed \"%s\" from %s", deletedProfile and deletedProfile.name or "?", contentKey)

    -- If the deleted profile was the active runtime profile, deactivate it
    if deletedProfile and self.activeRuntimeProfile == deletedProfile then
        DF:Debug("LAYOUT", "DeleteProfile: deleted layout was active, deactivating overlay")
        DF.raidOverrides = nil
        self.activeRuntimeProfile = nil
        self.activeRuntimeContentKey = nil
        if DF.FullProfileRefresh then
            DF:FullProfileRefresh()
        end
        print("|cff00ff00DandersFrames:|r " .. L["Auto-profile deactivated (profile deleted)"])
    end

    return true
end

-- Update profile range
function AutoProfilesUI:UpdateProfileRange(contentKey, index, newMin, newMax)
    self:InitDefaults()
    DF:Debug("LAYOUT", "UpdateProfileRange: %s index=%s newMin=%d newMax=%d", contentKey, tostring(index), newMin, newMax)

    if contentKey == "mythic" then
        return false, L["Mythic has fixed range"]
    end

    local profiles = DF.db.raidAutoProfiles[contentKey].profiles
    if not profiles[index] then
        return false, L["Profile not found"]
    end

    -- Check for overlap (excluding current profile)
    local overlap = self:CheckRangeOverlap(contentKey, newMin, newMax, index)
    if overlap then
        DF:DebugWarn("LAYOUT", "UpdateProfileRange: overlap with \"%s\" (%d-%d)", overlap.name, overlap.min, overlap.max)
        return false, format(L["Overlaps with \"%s\""], overlap.name)
    end

    local oldMin, oldMax = profiles[index].min, profiles[index].max
    profiles[index].min = newMin
    profiles[index].max = newMax
    DF:Debug("LAYOUT", "UpdateProfileRange: \"%s\" range %d-%d -> %d-%d", profiles[index].name or "?", oldMin, oldMax, newMin, newMax)

    -- Re-sort
    table.sort(profiles, function(a, b) return a.min < b.min end)

    return true
end

-- ============================================================
-- UI BUILDING
-- ============================================================

-- Build the Auto Profiles page content
function AutoProfilesUI:BuildPage(GUI, pageFrame, db, Add, AddSpace)
    local self = AutoProfilesUI
    self:InitDefaults()
    
    local autoDb = DF.db.raidAutoProfiles
    
    -- Only show for Raid mode
    if GUI.SelectedMode ~= "raid" then
        Add(GUI:CreateHeader(pageFrame.child, L["Raid Auto Layouts"]), 40, "both")
        Add(GUI:CreateLabel(pageFrame.child,
            L["Auto Layouts is a Raid-only feature. Switch to Raid mode to configure automatic layout switching based on content type and group size."],
            500, {r = 0.6, g = 0.6, b = 0.6}), 60, "both")
        return
    end

    -- =============================================
    -- Enable Checkbox
    -- =============================================
    local enableCheck = GUI:CreateCheckbox(pageFrame.child, L["Enable Raid Auto-Switching Layouts"],
        nil, nil,  -- dbTable, dbKey (not used)
        function() pageFrame:Refresh() end,  -- callback
        function() return autoDb.enabled end,  -- customGet
        function(val)                           -- customSet
            autoDb.enabled = val
            if not val then
                AutoProfilesUI:RemoveRuntimeProfile()
            else
                AutoProfilesUI:EvaluateAndApply()
            end
        end
    )
    Add(enableCheck, 30, "both")

    AddSpace(5, "both")

    -- Grey-when-disabled. When "Enable Raid Auto-Switching Layouts" is OFF, the
    -- page stays VISIBLE but dependent content greys in place. The toggle's
    -- callback runs pageFrame:Refresh() (a full rebuild), so reading autoDb.enabled
    -- at build time is self-refreshing — no disableOn/RefreshStates wiring needed
    -- for these raw frames (they have no SetEnabled, so the page gate loop skips
    -- them anyway).
    --
    -- CONFIGURE-WHILE-OFF: the layout MANAGEMENT controls (the content-type
    -- sections: add / edit / delete / rename / copy / range layouts) stay fully
    -- interactive while off — users routinely build their layouts before switching
    -- auto-switching on. Only the runtime auto-switch *behaviour* indicator (the
    -- Current Status box) is greyed; the header and the "How it works"
    -- documentation also stay full-colour/readable so the page is still usable.
    local autoOff = not autoDb.enabled

    -- =============================================
    -- Current Status Box
    -- =============================================
    local statusContainer = CreateFrame("Frame", nil, pageFrame.child)
    statusContainer:SetSize(500, 55)
    DF.GUI:CreateElementBackdrop(statusContainer, {
        bgColor = { 0.1, 0.1, 0.1, 0.8 },
        borderColor = { 0.25, 0.25, 0.25, 1 },
    })
    
    local statusTitle = statusContainer:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    statusTitle:SetPoint("TOPLEFT", 10, -8)
    statusTitle:SetText(L["CURRENT STATUS"])
    statusTitle:SetTextColor(0.5, 0.5, 0.5)
    
    local statusLine1 = statusContainer:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    statusLine1:SetPoint("TOPLEFT", 10, -24)
    
    local statusLine2 = statusContainer:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    statusLine2:SetPoint("TOPLEFT", 10, -38)
    
    -- Update status display
    if not autoDb.enabled then
        statusLine1:SetText("|cff666666" .. L["Auto-switching disabled"] .. "|r")
        statusLine2:SetText("")
    elseif not IsInRaid() then
        statusLine1:SetText("|cff999999" .. L["Not in a raid group"] .. "|r")
        statusLine2:SetText("")
    else
        -- Live detection
        local contentType = DF:GetContentType()
        local raidSize = GetNumGroupMembers()

        -- Map content type to display name
        local contentNames = {
            mythic = L["Mythic"],
            instanced = L["Instanced / PvP"],
            battleground = L["Instanced / PvP"],
            openWorld = L["Open World"],
            arena = L["Arena"],
        }
        local contentDisplay = contentNames[contentType] or L["Unknown"]

        -- Get instance name if available
        local instanceName = select(1, GetInstanceInfo())
        local difficultyName = select(4, GetInstanceInfo())
        local contentDetail = ""
        if instanceName and instanceName ~= "" and contentType ~= "openWorld" then
            contentDetail = " |cff666666— " .. instanceName
            if difficultyName and difficultyName ~= "" then
                contentDetail = contentDetail .. " (" .. difficultyName .. ")"
            end
            contentDetail = contentDetail .. "|r"
        end

        statusLine1:SetText("|cff66ff66" .. L["Content:"] .. "|r |cffffffff" .. contentDisplay .. "|r" .. contentDetail .. "  |cff666666(" .. format(L["%d players"], raidSize) .. ")|r")

        -- Show active profile
        local profile, profileKey = self:GetActiveProfile()
        if profile then
            local rangeText = ""
            if profileKey == "mythic" then
                rangeText = L["20 (Fixed)"]
            elseif profile.min and profile.max then
                rangeText = profile.min .. "-" .. profile.max
            end
            local overrideCount = CountDisplayedOverrides(profile.overrides)
            statusLine2:SetText("|cff66ff66" .. L["Layout:"] .. "|r |cffffffff\"" .. (profile.name or L["Unnamed"]) .. "\"|r |cff666666— " .. rangeText .. " · " .. format(overrideCount ~= 1 and L["%d overrides"] or L["%d override"], overrideCount) .. "|r")
        else
            statusLine2:SetText("|cff66ff66" .. L["Layout:"] .. "|r |cff999999" .. L["None active (using global settings)"] .. "|r")
        end
    end
    
    -- Grey the runtime status indicator in place when auto-switching is off; it
    -- reports the auto-switch behaviour (which is inert when disabled). Stays
    -- visible, just dimmed.
    statusContainer:SetAlpha(autoOff and 0.4 or 1)

    Add(statusContainer, 60, "both")

    AddSpace(5, "both")
    
    -- =============================================
    -- How It Works Section (collapsible, persisted)
    -- =============================================
    local infoHeaderHeight = 28
    local infoBodyHeight = 206
    local infoCollapsed = autoDb.howItWorksCollapsed
    
    local infoContainer = CreateFrame("Frame", nil, pageFrame.child, "BackdropTemplate")
    infoContainer:SetSize(500, infoHeaderHeight + (infoCollapsed and 0 or infoBodyHeight))
    infoContainer:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    infoContainer:SetBackdropColor(0.15, 0.1, 0.05, 0.5)
    infoContainer:SetBackdropBorderColor(0.4, 0.25, 0.1, 0.5)
    
    -- Clickable header
    local infoHeader = CreateFrame("Button", nil, infoContainer)
    infoHeader:SetPoint("TOPLEFT", 0, 0)
    infoHeader:SetPoint("TOPRIGHT", 0, 0)
    infoHeader:SetHeight(infoHeaderHeight)
    
    local infoArrow = infoHeader:CreateTexture(nil, "OVERLAY")
    infoArrow:SetPoint("LEFT", 10, 0)
    infoArrow:SetSize(12, 12)
    infoArrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\" .. (infoCollapsed and "chevron_right" or "expand_more"))
    infoArrow:SetVertexColor(0.6, 0.6, 0.6)
    
    local howTitle = infoHeader:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    howTitle:SetPoint("LEFT", 28, 0)
    howTitle:SetText(L["How it works"])
    howTitle:SetTextColor(1, 1, 1)
    
    infoHeader:SetScript("OnEnter", function() infoArrow:SetVertexColor(1, 0.8, 0.2) end)
    infoHeader:SetScript("OnLeave", function() infoArrow:SetVertexColor(0.6, 0.6, 0.6) end)
    
    -- Body
    local infoBody = CreateFrame("Frame", nil, infoContainer)
    infoBody:SetPoint("TOPLEFT", 0, -infoHeaderHeight)
    infoBody:SetPoint("TOPRIGHT", 0, -infoHeaderHeight)
    infoBody:SetHeight(infoBodyHeight)
    if infoCollapsed then infoBody:Hide() end
    
    -- Toggle
    infoHeader:SetScript("OnClick", function()
        autoDb.howItWorksCollapsed = not autoDb.howItWorksCollapsed
        if autoDb.howItWorksCollapsed then
            infoArrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
            infoBody:Hide()
        else
            infoArrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
            infoBody:Show()
        end
        -- Refresh page to recalculate layout
        if pageFrame.Refresh then pageFrame:Refresh() end
    end)
    
    local yOff = -4
    
    -- Step 1
    local step1 = infoBody:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    step1:SetPoint("TOPLEFT", 10, yOff)
    step1:SetPoint("RIGHT", infoBody, "RIGHT", -10, 0)
    step1:SetJustifyH("LEFT")
    step1:SetText("|cffff8020" .. "1.|r " .. format(L["Create layouts below for different player ranges within each content type. Layouts only store settings that %sdiffer%s from your global settings — everything else is inherited automatically."], "|cffffffff", "|r"))
    step1:SetTextColor(0.65, 0.65, 0.65)
    yOff = yOff - 30
    
    -- Step 2
    local step2 = infoBody:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    step2:SetPoint("TOPLEFT", 10, yOff)
    step2:SetPoint("RIGHT", infoBody, "RIGHT", -10, 0)
    step2:SetJustifyH("LEFT")
    step2:SetText("|cffff8020" .. "2.|r " .. format(L["Click %sEdit Settings%s on a profile to customise it. This takes you to the settings tabs with an editing banner at the top. While editing, any setting you change is stored as an override for that profile only."], "|cffffffff", "|r"))
    step2:SetTextColor(0.65, 0.65, 0.65)
    yOff = yOff - 30
    
    -- Step 3 - visual indicators
    local step3 = infoBody:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    step3:SetPoint("TOPLEFT", 10, yOff)
    step3:SetPoint("RIGHT", infoBody, "RIGHT", -10, 0)
    step3:SetJustifyH("LEFT")
    step3:SetText("|cffff8020" .. "3.|r " .. L["While editing, each setting shows its override status:"])
    step3:SetTextColor(0.65, 0.65, 0.65)
    yOff = yOff - 16
    
    -- Visual example row 1: Matching global (green check)
    local exRow1 = CreateFrame("Frame", nil, infoBody)
    exRow1:SetPoint("TOPLEFT", 24, yOff)
    exRow1:SetSize(460, 16)
    
    local ex1Check = exRow1:CreateTexture(nil, "OVERLAY")
    ex1Check:SetPoint("LEFT", 0, 0)
    ex1Check:SetSize(10, 10)
    ex1Check:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\check")
    ex1Check:SetVertexColor(0.3, 0.7, 0.3)
    
    local ex1Text = exRow1:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    ex1Text:SetPoint("LEFT", ex1Check, "RIGHT", 4, 0)
    ex1Text:SetText(format(L["%sGlobal: 80%s %s— Setting matches global, no override stored%s"], "|cff4db84d", "|r", "|cff666666", "|r"))
    yOff = yOff - 18
    
    -- Visual example row 2: Overridden (star + reset)
    local exRow2 = CreateFrame("Frame", nil, infoBody)
    exRow2:SetPoint("TOPLEFT", 24, yOff)
    exRow2:SetSize(460, 16)
    
    local ex2Star = exRow2:CreateTexture(nil, "OVERLAY")
    ex2Star:SetPoint("LEFT", 0, 0)
    ex2Star:SetSize(12, 12)
    ex2Star:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\star")
    ex2Star:SetVertexColor(1, 0.8, 0.2)
    
    local ex2ResetBg = exRow2:CreateTexture(nil, "ARTWORK")
    ex2ResetBg:SetPoint("LEFT", ex2Star, "RIGHT", 4, 0)
    ex2ResetBg:SetSize(14, 14)
    ex2ResetBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)
    
    local ex2Reset = exRow2:CreateTexture(nil, "OVERLAY")
    ex2Reset:SetPoint("CENTER", ex2ResetBg, "CENTER", 0, 0)
    ex2Reset:SetSize(10, 10)
    ex2Reset:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\refresh")
    ex2Reset:SetVertexColor(0.6, 0.6, 0.6)
    
    local ex2Text = exRow2:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    ex2Text:SetPoint("LEFT", ex2ResetBg, "RIGHT", 6, 0)
    ex2Text:SetText(format(L["%sModified%s %s— Setting differs from global. Click%s %sreset%s %sto revert.%s"], "|cffe6cc80", "|r", "|cff666666", "|r", "|cffffffff", "|r", "|cff666666", "|r"))
    yOff = yOff - 22
    
    -- Step 4
    local step4 = infoBody:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    step4:SetPoint("TOPLEFT", 10, yOff)
    step4:SetPoint("RIGHT", infoBody, "RIGHT", -10, 0)
    step4:SetJustifyH("LEFT")
    step4:SetText("|cffff8020" .. "4.|r " .. format(L["Click %sExit Editing%s when done. Your overrides are saved to the profile. If you change a setting back to match global, the override is automatically removed."], "|cffffffff", "|r"))
    step4:SetTextColor(0.65, 0.65, 0.65)
    yOff = yOff - 30
    
    -- Step 5
    local step5 = infoBody:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    step5:SetPoint("TOPLEFT", 10, yOff)
    step5:SetPoint("RIGHT", infoBody, "RIGHT", -10, 0)
    step5:SetJustifyH("LEFT")
    step5:SetText("|cffff8020" .. "5.|r " .. L["When you enter matching content, the layout's overrides are applied on top of your global settings. If no layout matches, global settings are used as-is."])
    step5:SetTextColor(0.65, 0.65, 0.65)
    
    Add(infoContainer, infoHeaderHeight + (infoCollapsed and 0 or infoBodyHeight), "both")
    
    AddSpace(10, "both")
    
    -- =============================================
    -- Content Type Sections (dynamic height via layoutHeight)
    -- =============================================
    for _, ct in ipairs(CONTENT_TYPES) do
        local section = self:CreateContentTypeSection(GUI, pageFrame, ct)
        -- Add section with its current height
        Add(section, section.totalHeight, "both")
        AddSpace(8, "both")
    end
end

-- Create a content type section (collapsible)
function AutoProfilesUI:CreateContentTypeSection(GUI, pageFrame, contentType)
    local self = AutoProfilesUI
    local autoDb = DF.db.raidAutoProfiles
    
    local profiles = self:GetProfiles(contentType.key)
    local numProfiles = #profiles
    
    -- Calculate heights
    local headerHeight = 32
    local rowHeight = 32
    local addButtonHeight = 32  -- Always include add button height
    local bodyPadding = 10
    local bodyHeight = (numProfiles * rowHeight) + addButtonHeight + bodyPadding
    
    -- If no layouts and is mythic, need extra space for "no layout set" text
    if contentType.key == "mythic" and numProfiles == 0 then
        bodyHeight = 60  -- Empty text + add button + padding
    elseif contentType.isFixed and numProfiles > 0 then
        -- Mythic with profile - no add button needed
        bodyHeight = (numProfiles * rowHeight) + bodyPadding
    end
    
    local section = CreateFrame("Frame", nil, pageFrame.child, "BackdropTemplate")
    section:SetSize(500, headerHeight)
    section:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    section:SetBackdropColor(0.12, 0.12, 0.12, 1)
    section:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
    section.expanded = true
    section.contentKey = contentType.key
    section.totalHeight = headerHeight + (section.expanded and bodyHeight or 0)
    
    -- Header button
    local header = CreateFrame("Button", nil, section)
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", 0, 0)
    header:SetHeight(headerHeight)
    
    -- Arrow
    section.arrow = header:CreateTexture(nil, "OVERLAY")
    section.arrow:SetPoint("LEFT", 10, 0)
    section.arrow:SetSize(12, 12)
    section.arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
    section.arrow:SetVertexColor(0.6, 0.6, 0.6)
    
    -- Title
    local titleText = header:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    titleText:SetPoint("LEFT", 28, 0)
    titleText:SetText(contentType.title)
    titleText:SetTextColor(1, 0.5, 0.2)  -- Raid orange
    
    -- Description
    local descText = header:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    descText:SetPoint("RIGHT", -10, 0)
    descText:SetText(contentType.description)
    descText:SetTextColor(0.5, 0.5, 0.5)
    
    -- Body container
    section.body = CreateFrame("Frame", nil, section)
    section.body:SetPoint("TOPLEFT", 0, -headerHeight)
    section.body:SetPoint("TOPRIGHT", 0, -headerHeight)
    section.body:SetHeight(bodyHeight)
    
    -- Toggle
    header:SetScript("OnClick", function()
        section.expanded = not section.expanded
        if section.expanded then
            section.arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
            section.body:Show()
            section.totalHeight = headerHeight + bodyHeight
        else
            section.arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
            section.body:Hide()
            section.totalHeight = headerHeight
        end
        -- Update layoutHeight for the page layout system
        section.layoutHeight = section.totalHeight
        section:SetHeight(section.totalHeight)
        -- Call the page's RefreshStates to reposition all elements
        if pageFrame.RefreshStates then pageFrame:RefreshStates() end
    end)
    
    -- Hover effect
    header:SetScript("OnEnter", function()
        section:SetBackdropColor(0.16, 0.16, 0.16, 1)
    end)
    header:SetScript("OnLeave", function()
        section:SetBackdropColor(0.12, 0.12, 0.12, 1)
    end)
    
    -- Render profile rows
    local y = -5
    for i, profile in ipairs(profiles) do
        local row = self:CreateProfileRow(GUI, pageFrame, section.body, contentType, profile, i)
        row:SetPoint("TOPLEFT", 10, y)
        row:SetPoint("TOPRIGHT", -10, y)
        y = y - rowHeight
    end
    
    -- Empty state for mythic
    if contentType.key == "mythic" and numProfiles == 0 then
        local emptyText = section.body:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        emptyText:SetPoint("TOP", 0, -10)
        emptyText:SetText("|cff666666" .. L["No layout set. Using global settings."] .. "|r")
        
        -- Add button for mythic (centered, full width)
        local addBtn = self:CreateAddButton(GUI, pageFrame, section.body, contentType)
        addBtn:SetPoint("TOPLEFT", 10, -32)
        addBtn:SetPoint("TOPRIGHT", -10, -32)
    elseif not contentType.isFixed then
        -- Add Layout button (full width)
        local addBtn = self:CreateAddButton(GUI, pageFrame, section.body, contentType)
        addBtn:SetPoint("TOPLEFT", 10, y - 5)
        addBtn:SetPoint("TOPRIGHT", -10, y - 5)
    end
    
    section:SetHeight(section.totalHeight)
    return section
end

-- Create a profile row
function AutoProfilesUI:CreateProfileRow(GUI, pageFrame, parent, contentType, profile, index)
    local self = AutoProfilesUI
    
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetHeight(28)
    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    row:SetBackdropColor(0.08, 0.08, 0.08, 1)
    
    -- Profile name
    local nameText = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    nameText:SetPoint("LEFT", 10, 0)
    nameText:SetText(profile.name or L["Unnamed"])
    nameText:SetWidth(100)
    nameText:SetJustifyH("LEFT")
    
    -- Range badge
    local rangeBadge = CreateFrame("Button", nil, row, "BackdropTemplate")
    rangeBadge:SetSize(65, 18)
    rangeBadge:SetPoint("LEFT", 115, 0)
    rangeBadge:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    rangeBadge:SetBackdropColor(0.18, 0.18, 0.18, 1)
    rangeBadge:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    
    local rangeText = rangeBadge:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    rangeText:SetPoint("CENTER")
    
    if contentType.isFixed then
        rangeText:SetText(L["20 (Fixed)"])
        rangeText:SetTextColor(0.5, 0.5, 0.5)
    else
        rangeText:SetText((profile.min or 1) .. " - " .. (profile.max or 40))
        rangeText:SetTextColor(0.7, 0.7, 0.7)
        
        -- Make clickable for editing range
        rangeBadge:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(1, 0.5, 0.2, 1)
            rangeText:SetTextColor(1, 1, 1)
            GUI:ShowTooltip(self, { title = L["Click to edit range"] })
        end)
        rangeBadge:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
            rangeText:SetTextColor(0.7, 0.7, 0.7)
            GUI:HideTooltip()
        end)
        rangeBadge:SetScript("OnClick", function()
            -- Show edit range dialog
            AutoProfilesUI:ShowProfileDialog(contentType, profile, index, pageFrame)
        end)
    end
    
    -- Override count: everything displayed (mapped groups + "Other"), deduped — same
    -- helper the editing status line and /df overrides use, so all three agree.
    local overrideCount = CountDisplayedOverrides(profile.overrides)
    
    local overrideText = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    overrideText:SetPoint("LEFT", 190, 0)
    if overrideCount > 0 then
        overrideText:SetText("|cffffaa00*|r " .. format(overrideCount > 1 and L["%d overrides"] or L["%d override"], overrideCount))
        overrideText:SetTextColor(1, 0.67, 0)
    else
        overrideText:SetText("")
    end
    overrideText:SetWidth(80)
    overrideText:SetJustifyH("LEFT")

    -- Hoverable overlay on override count to show tooltip with details
    if overrideCount > 0 then
        local overrideBtn = CreateFrame("Button", nil, row)
        overrideBtn:SetPoint("LEFT", overrideText, "LEFT", -4, 0)
        overrideBtn:SetSize(88, 22)

        overrideBtn:SetScript("OnEnter", function(self)
            overrideText:SetTextColor(1, 0.8, 0.2)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(L["Override Details"], 1, 0.67, 0)
            GameTooltip:AddLine(" ")

            local groups, unknownKeys = GroupOverridesByTab(profile.overrides)
            local tabOrder = {}
            for tabId in pairs(groups) do tinsert(tabOrder, tabId) end
            table.sort(tabOrder)

            -- Global (un-overridden) raid values, to diff table overrides against so
            -- we show ONLY what the layout changed — not the whole stored config.
            -- While editing, live previews are written into DF._realRaidDB, so the
            -- TRUE global lives in globalSnapshot (diffing against _realRaidDB then
            -- would hide every change).
            local realRaid = (AutoProfilesUI:IsEditing() and AutoProfilesUI.globalSnapshot) or DF._realRaidDB or (DF.db and DF.db.raid)
            -- Hard cap on tooltip body lines so a large layout can't overflow the
            -- screen. Every emitted line (group headers, scalars, walk leaves, Other)
            -- counts; once the cap is hit we stop and flag truncation. The footer
            -- pointing at /df overrides (the complete dump) always shows.
            local MAX_LINES = 40
            local shown, truncated = 0, false
            local function canEmit()
                if shown >= MAX_LINES then truncated = true return false end
                shown = shown + 1
                return true
            end
            local budget = { n = nil }  -- the line cap governs length, not this
            -- Breadcrumb headers (val == nil) print as a grey line; leaves print
            -- the value INLINE next to the key (not a right-floating column) so a
            -- wide breadcrumb header doesn't push every value to the screen edge.
            local function emitTT(indent, label, val)
                if not canEmit() then return end
                if val == nil then
                    GameTooltip:AddLine(indent .. label, 0.6, 0.6, 0.6)
                else
                    GameTooltip:AddLine(indent .. label .. "  |cffffffff" .. val .. "|r", 0.8, 0.8, 0.8)
                end
            end
            -- Render one override key: scalars shown directly; a table-valued override
            -- is diffed against its global so only the changed leaves appear.
            local function renderKey(key, lr, lg, lb)
                local value = profile.overrides[key]
                if type(value) == "table" and not (value.r and value.g and value.b) then
                    if not canEmit() then return end
                    GameTooltip:AddLine("  " .. key .. ":", lr, lg, lb)
                    WalkOverrideDiff(value, realRaid and realRaid[key], "", "    ", 1, 8, budget, emitTT)
                else
                    if not canEmit() then return end
                    local displayVal
                    if type(value) == "boolean" then
                        displayVal = value and "true" or "false"
                    elseif type(value) == "table" then
                        displayVal = string.format("(%.1f, %.1f, %.1f)", value.r, value.g, value.b)
                    else
                        displayVal = tostring(value)
                    end
                    GameTooltip:AddDoubleLine("  " .. key, displayVal, lr, lg, lb, 1, 1, 1)
                end
            end

            for _, tabId in ipairs(tabOrder) do
                if not canEmit() then break end
                local group = groups[tabId]
                GameTooltip:AddLine(group.tabLabel .. " (" .. #group.keys .. ")", 1, 0.67, 0)
                table.sort(group.keys)
                for _, key in ipairs(group.keys) do
                    renderKey(key, 0.8, 0.8, 0.8)
                    if truncated then break end
                end
                if truncated then break end
            end

            if #unknownKeys > 0 and not truncated and canEmit() then
                GameTooltip:AddLine(format(L["Other (%d)"], #unknownKeys), 0.5, 0.5, 0.5)
                table.sort(unknownKeys)
                for _, key in ipairs(unknownKeys) do
                    renderKey(key, 0.5, 0.5, 0.5)
                    if truncated then break end
                end
            end

            GameTooltip:AddLine(" ")
            if truncated then
                GameTooltip:AddLine(L["Too many to show here."], 1, 0.6, 0.2)
            end
            -- /df overrides reports on the active layout (or one being edited), not
            -- whichever row is hovered — so note that inactive layouts need Edit first.
            GameTooltip:AddLine(L["Use /df overrides for the full list — active layout, or Edit one to inspect it."], 0.4, 0.4, 0.4)
            GameTooltip:Show()
        end)

        overrideBtn:SetScript("OnLeave", function()
            overrideText:SetTextColor(1, 0.67, 0)
            GameTooltip:Hide()
        end)
    end

    -- Copy To button — normal styling with a white label. It's a raid-only
    -- feature and the page is already saturated with raid orange, so this
    -- secondary action doesn't need its own orange text.
    local copyBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
    copyBtn:SetPoint("RIGHT", -120, 0)
    GUI:StyleButton(copyBtn, { width = 55, height = 20, text = L["Copy To"] })

    copyBtn:SetScript("OnClick", function()
        AutoProfilesUI:ShowCopyDialog(contentType, profile, index, pageFrame)
    end)

    -- Unlock button — ACTIVE layout only. Mirrors the main toolbar Lock/Unlock
    -- toggle (icon + text) but scoped to this layout: clicking it edits THIS
    -- (active) layout with the raid frames unlocked, so dragging saves the position
    -- into the layout instead of the base. The main toolbar Unlock is disabled
    -- while a layout is active (steering position edits here), same convention as
    -- Edit Settings being active-layout-only.
    if AutoProfilesUI.activeRuntimeProfile == profile then
        local unlockBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
        unlockBtn:SetSize(80, 20)
        unlockBtn:SetPoint("RIGHT", copyBtn, "LEFT", -6, 0)
        -- Toggle on the shared styler (orange identity); SetActive while unlocked.
        GUI:StyleButton(unlockBtn, { accent = { r = 1, g = 0.5, b = 0.2 } })

        local unlockIcon = unlockBtn:CreateTexture(nil, "OVERLAY")
        unlockIcon:SetSize(12, 12)
        unlockBtn.Icon = unlockIcon

        local unlockText = unlockBtn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        unlockText:SetPoint("CENTER", unlockBtn, "CENTER", 8, 0)
        unlockIcon:SetPoint("RIGHT", unlockText, "LEFT", -4, 0)
        unlockText:SetTextColor(0.9, 0.9, 0.9)
        unlockBtn.Text = unlockText

        local function RefreshUnlockBtn()
            local locked = DF:GetRaidDB().raidLocked
            unlockText:SetText(locked and L["Unlock"] or L["Lock"])
            unlockIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\" .. (locked and "lock" or "lock_open"))
            unlockIcon:SetVertexColor(0.9, 0.9, 0.9)
            unlockBtn:SetActive(not locked)  -- accent fill/border while unlocked (editing)
        end
        RefreshUnlockBtn()

        unlockBtn:HookScript("OnEnter", function(self)
            GUI:ShowTooltip(self, {
                title = L["Unlock to Move"],
                tone = "warning",
                lines = {
                    L["Unlock this layout's frames to drag them. Changes save to this layout."],
                },
            })
        end)
        unlockBtn:HookScript("OnLeave", function()
            GUI:HideTooltip()
        end)
        unlockBtn:SetScript("OnClick", function()
            local locked = DF:GetRaidDB().raidLocked
            if locked then
                if InCombatLockdown() then
                    print("|cffff0000DandersFrames:|r Cannot unlock during combat.")
                    return
                end
                -- Edit THIS layout (already the active one) so drag-writes land on
                -- it, then unlock for world dragging. Skip re-entering if Edit
                -- Settings already opened this layout (don't steal that session).
                local alreadyEditingThis = AutoProfilesUI:IsEditing()
                    and AutoProfilesUI.editingProfile == profile
                if not alreadyEditingThis then
                    -- Refused (shouldn't happen for the active layout) → don't fall
                    -- through to unlocking the BASE, which is the bug we're fixing.
                    if AutoProfilesUI:EnterEditing(contentType.key, index) == false then return end
                    DF.raidLayoutEditUnlock = true
                end
                if DF.UnlockRaidFrames then DF:UnlockRaidFrames() end
            else
                if DF.LockRaidFrames then DF:LockRaidFrames() end
            end
            RefreshUnlockBtn()
        end)
    end

    -- Edit Settings button — AutoProfiles orange identity; greys out via
    -- SetDisabled when this layout can't be edited (blockEdit below).
    local editBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
    editBtn:SetSize(75, 20)
    editBtn:SetPoint("RIGHT", -40, 0)
    GUI:StyleButton(editBtn, {
        text = L["Edit Settings"],
        accent = { r = 1, g = 0.5, b = 0.2 },
    })
    editBtn:SetScript("OnClick", function(self)
        if self.dfDisabled then return end
        AutoProfilesUI:EnterEditing(contentType.key, index)
    end)

    -- Grey out the edit button when editing this layout would disturb the live
    -- raid frames. Entering edit writes the layout's settings into the live raid
    -- db for preview, so the real raid frames only stay correct when the layout
    -- being edited is the one actually driving them. Block when:
    --   * a DIFFERENT layout is running — only the active layout is editable; OR
    --   * you're in a raid group with NO layout running — any layout you edit
    --     wouldn't match what's on screen and would shove the live frames to its
    --     geometry, so nothing is editable here (leave the raid to edit others).
    -- Outside a raid group there are no real raid frames to disturb, so editing
    -- any layout is fine.
    local blockEdit = (self.activeRuntimeProfile ~= profile)
        and (self.activeRuntimeProfile ~= nil or IsInRaid())
    if blockEdit then
        local tipLine
        if self.activeRuntimeProfile then
            tipLine = L["Only the active layout can be edited\nwhile auto layouts are running."]
        else
            tipLine = L["While in a raid group you can only edit the active layout. Leave the raid group to edit other layouts."]
        end
        editBtn:SetDisabled(true)
        editBtn:HookScript("OnEnter", function(btn)
            GUI:ShowTooltip(btn, {
                title = L["Cannot Edit"],
                tone = "danger",
                lines = { tipLine },
            })
        end)
        editBtn:HookScript("OnLeave", function()
            GUI:HideTooltip()
        end)
    end

    -- Delete button (destructive — red hover wash via the shared styler)
    local deleteBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
    deleteBtn:SetSize(22, 20)
    deleteBtn:SetPoint("RIGHT", -10, 0)
    GUI:StyleButton(deleteBtn, {
        accent = { r = 0.8, g = 0.2, b = 0.2 },
        icon = {
            texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\delete",
            size = 12,
            color = { r = 0.6, g = 0.6, b = 0.6 },
        },
    })

    deleteBtn:HookScript("OnEnter", function(self)
        self.Icon:SetVertexColor(1, 0.3, 0.3)
        GUI:ShowTooltip(self, { title = L["Delete Layout"] })
    end)
    deleteBtn:HookScript("OnLeave", function(self)
        self.Icon:SetVertexColor(0.6, 0.6, 0.6)
        GUI:HideTooltip()
    end)
    deleteBtn:SetScript("OnClick", function()
        -- Confirm deletion
        StaticPopupDialogs["DANDERSFRAMES_DELETE_AUTOPROFILE"] = {
            text = format(L["Delete layout \"%s\"?"], profile.name),
            button1 = L["Delete"],
            button2 = L["Cancel"],
            OnAccept = function()
                AutoProfilesUI:DeleteProfile(contentType.key, index)
                if pageFrame.Refresh then pageFrame:Refresh() end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
        }
        StaticPopup_Show("DANDERSFRAMES_DELETE_AUTOPROFILE")
    end)
    
    return row
end

-- Create Add Layout button
function AutoProfilesUI:CreateAddButton(GUI, pageFrame, parent, contentType)
    local self = AutoProfilesUI
    
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetHeight(24)

    GUI:StyleButton(btn, { height = 24, icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\add", size = 14 }, text = L["Add Layout"] })

    btn:SetScript("OnClick", function()
        if contentType.key == "mythic" then
            -- Just create the mythic profile directly
            AutoProfilesUI:CreateProfile("mythic", "Mythic Setup")
            if pageFrame.Refresh then pageFrame:Refresh() end
        else
            -- Show add layout dialog
            AutoProfilesUI:ShowProfileDialog(contentType, nil, nil, pageFrame)
        end
    end)
    
    return btn
end

-- ============================================================
-- PROFILE DIALOG (Add/Edit)
-- Anchored to main GUI frame center, no overlay
-- ============================================================

local profileDialog = nil

function AutoProfilesUI:CreateProfileDialog()
    if profileDialog then return profileDialog end
    
    -- Dialog frame - parented to UIParent like click casting does
    local dialog = CreateFrame("Frame", "DandersAutoProfileDialog", UIParent, "BackdropTemplate")
    dialog:SetSize(360, 240)
    dialog:SetPoint("CENTER", DF.GUIFrame or UIParent, "CENTER", 0, 0)
    DF.GUI:CreatePanelBackdrop(dialog, { bgAlpha = 0.98, borderColor = { 0, 0, 0, 1 } })
    dialog:SetFrameStrata("FULLSCREEN_DIALOG")
    dialog:SetFrameLevel(100)
    dialog:EnableMouse(true)
    dialog:SetMovable(true)
    dialog:RegisterForDrag("LeftButton")
    dialog:SetScript("OnDragStart", dialog.StartMoving)
    dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
    dialog:Hide()

    -- Title
    local title = dialog:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetTextColor(0.9, 0.9, 0.9)
    dialog.title = title

    -- Close button
    local closeBtn = DF.GUI:CreateCloseButton(dialog, { onClick = function() dialog:Hide() end })
    closeBtn:SetPoint("TOPRIGHT", -6, -6)
    
    -- =============================================
    -- Profile Name Section
    -- =============================================
    local nameLabel = dialog:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    nameLabel:SetPoint("TOPLEFT", 12, -40)
    nameLabel:SetText(L["Layout Name"])
    nameLabel:SetTextColor(0.6, 0.6, 0.6)
    dialog.nameLabel = nameLabel

    local nameInput = CreateFrame("EditBox", nil, dialog, "BackdropTemplate")
    nameInput:SetSize(336, 26)
    nameInput:SetPoint("TOPLEFT", 12, -56)
    DF.GUI:StyleEditBox(nameInput, {})
    nameInput:SetAutoFocus(false)
    nameInput:SetMaxLetters(30)
    nameInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    nameInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    nameInput:SetScript("OnTextChanged", function(self)
        AutoProfilesUI:ValidateDialog()
    end)
    dialog.nameInput = nameInput
    
    -- =============================================
    -- Range Section with Dual-Handle Slider
    -- =============================================
    local rangeLabel = dialog:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    rangeLabel:SetPoint("TOPLEFT", 12, -92)
    rangeLabel:SetText(L["Player Range"])
    rangeLabel:SetTextColor(0.6, 0.6, 0.6)
    dialog.rangeLabel = rangeLabel

    -- Range display
    local rangeDisplay = dialog:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
    rangeDisplay:SetPoint("TOPRIGHT", -12, -92)
    rangeDisplay:SetTextColor(1, 0.5, 0.2)
    dialog.rangeDisplay = rangeDisplay
    
    -- Dual-handle range slider (shared helper). Preserves the orange accent and
    -- the original 1..40 scale labels; drag/track-click/dragging-state are all
    -- handled internally by the helper.
    local slider = DF.GUI:CreateRangeSlider(dialog, {
        width = 336,
        accent = { r = 1, g = 0.5, b = 0.2 },
        minRange = 1, maxRange = 40,
        lo = dialog.currentMin or 1, hi = dialog.currentMax or 40,
        scaleLabels = {1, 10, 20, 30, 40}, scaleMin = 1, scaleMax = 40,
        display = rangeDisplay,
        formatOne   = function(v) return format(L["%d players"], v) end,
        formatRange = function(lo, hi) return format(L["%d - %d players"], lo, hi) end,
        onChange = function(lo, hi)
            dialog.currentMin, dialog.currentMax = lo, hi
            AutoProfilesUI:ValidateDialog()
        end,
    })
    slider:SetPoint("TOPLEFT", 12, -112)
    dialog.sliderTrack = slider

    dialog.UpdateSliderVisuals = function()
        local ct = dialog.contentType
        if not ct then return end
        slider:SetRange(ct.minRange, ct.maxRange)
        slider:SetValues(dialog.currentMin or ct.minRange, dialog.currentMax or ct.maxRange)
        AutoProfilesUI:ValidateDialog()
    end
    
    -- =============================================
    -- Validation Message
    -- =============================================
    local validationIcon = dialog:CreateTexture(nil, "OVERLAY")
    validationIcon:SetSize(14, 14)
    validationIcon:SetPoint("TOPLEFT", 12, -152)
    dialog.validationIcon = validationIcon
    
    local validationMsg = dialog:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    validationMsg:SetPoint("LEFT", validationIcon, "RIGHT", 6, 0)
    validationMsg:SetWidth(310)
    validationMsg:SetJustifyH("LEFT")
    dialog.validationMsg = validationMsg
    
    -- =============================================
    -- Buttons
    -- =============================================
    local cancelBtn = CreateFrame("Button", nil, dialog, "BackdropTemplate")
    cancelBtn:SetPoint("BOTTOMLEFT", 12, 12)
    DF.GUI:StyleButton(cancelBtn, { width = 80, height = 26, text = L["Cancel"] })
    cancelBtn:SetScript("OnClick", function()
        dialog:Hide()
    end)

    local createBtn = CreateFrame("Button", nil, dialog, "BackdropTemplate")
    createBtn:SetPoint("BOTTOMRIGHT", -12, 12)
    -- Primary CTA in the AutoProfiles orange identity; ValidateDialog drives its
    -- greyed (disabled) state via SetDisabled below.
    DF.GUI:StyleButton(createBtn, {
        width = 100, height = 26, text = L["Create Layout"],
        primary = true, accent = { r = 1, g = 0.5, b = 0.2 },
    })
    dialog.createBtnText = createBtn.Text

    createBtn:SetScript("OnClick", function(self)
        if self.dfDisabled then return end
        AutoProfilesUI:SubmitDialog()
    end)
    dialog.createBtn = createBtn

    profileDialog = dialog
    return dialog
end

function AutoProfilesUI:ShowProfileDialog(contentType, profile, profileIndex, pageFrame)
    local dialog = self:CreateProfileDialog()
    
    -- Re-anchor to GUI frame if it exists now
    if DF.GUIFrame then
        dialog:ClearAllPoints()
        dialog:SetPoint("CENTER", DF.GUIFrame, "CENTER", 0, 0)
    end
    
    -- Store context
    dialog.contentType = contentType
    dialog.profile = profile
    dialog.profileIndex = profileIndex
    dialog.pageFrame = pageFrame
    dialog.isEditMode = (profile ~= nil)
    
    -- Set title
    if dialog.isEditMode then
        dialog.title:SetText(L["Edit Layout Range"])
        dialog.createBtnText:SetText(L["Save Changes"])
        dialog.nameLabel:Hide()
        dialog.nameInput:Hide()
        -- Shift elements up (52px offset from hidden name section)
        dialog.rangeLabel:ClearAllPoints()
        dialog.rangeLabel:SetPoint("TOPLEFT", 12, -40)
        dialog.sliderTrack:ClearAllPoints()
        dialog.sliderTrack:SetPoint("TOPLEFT", 12, -60)
        dialog.validationIcon:ClearAllPoints()
        dialog.validationIcon:SetPoint("TOPLEFT", 12, -100)
        dialog:SetHeight(175)
    else
        dialog.title:SetText(L["Add Layout"])
        dialog.createBtnText:SetText(L["Create Layout"])
        dialog.nameLabel:Show()
        dialog.nameInput:Show()
        -- Reset positions to default
        dialog.rangeLabel:ClearAllPoints()
        dialog.rangeLabel:SetPoint("TOPLEFT", 12, -92)
        dialog.sliderTrack:ClearAllPoints()
        dialog.sliderTrack:SetPoint("TOPLEFT", 12, -112)
        dialog.validationIcon:ClearAllPoints()
        dialog.validationIcon:SetPoint("TOPLEFT", 12, -152)
        dialog:SetHeight(220)
    end
    
    -- Set initial values
    if dialog.isEditMode then
        dialog.nameInput:SetText(profile.name or "")
        dialog.currentMin = profile.min or contentType.minRange
        dialog.currentMax = profile.max or contentType.maxRange
    else
        dialog.nameInput:SetText("")
        local existingProfiles = self:GetProfiles(contentType.key)
        dialog.currentMin, dialog.currentMax = self:SuggestRange(contentType, existingProfiles)
    end
    
    -- Update visuals and show
    dialog.UpdateSliderVisuals()
    self:ValidateDialog()
    dialog:Show()
    
    if not dialog.isEditMode then
        dialog.nameInput:SetFocus()
    end
end

function AutoProfilesUI:SuggestRange(contentType, existingProfiles)
    if #existingProfiles == 0 then
        return 1, 20
    end
    
    local sorted = {}
    for _, p in ipairs(existingProfiles) do
        table.insert(sorted, {min = p.min, max = p.max})
    end
    table.sort(sorted, function(a, b) return a.min < b.min end)
    
    if sorted[1].min > contentType.minRange then
        return contentType.minRange, sorted[1].min - 1
    end
    
    for i = 1, #sorted - 1 do
        if sorted[i].max + 1 < sorted[i + 1].min then
            return sorted[i].max + 1, sorted[i + 1].min - 1
        end
    end
    
    if sorted[#sorted].max < contentType.maxRange then
        return sorted[#sorted].max + 1, contentType.maxRange
    end
    
    return contentType.minRange, contentType.maxRange
end

function AutoProfilesUI:ValidateDialog()
    local dialog = profileDialog
    if not dialog or not dialog:IsShown() then return false end
    
    local contentType = dialog.contentType
    local isValid = true
    local errorMsg = nil
    
    local name = strtrim(dialog.nameInput:GetText() or "")
    local minVal = dialog.currentMin or 1
    local maxVal = dialog.currentMax or 40
    
    -- Validate name (only for new profiles)
    if not dialog.isEditMode then
        if name == "" then
            isValid = false
            errorMsg = L["Enter a profile name"]
        else
            local profiles = self:GetProfiles(contentType.key)
            for _, p in ipairs(profiles) do
                if p.name:lower() == name:lower() then
                    isValid = false
                    errorMsg = L["A profile with this name already exists"]
                    break
                end
            end
        end
    end

    -- Validate range
    if isValid then
        local excludeIndex = dialog.isEditMode and dialog.profileIndex or nil
        local overlap = self:CheckRangeOverlap(contentType.key, minVal, maxVal, excludeIndex)
        if overlap then
            isValid = false
            errorMsg = format(L["Overlaps with \"%s\" (%d-%d)"], overlap.name, overlap.min, overlap.max)
        end
    end

    -- Update validation display
    if isValid then
        dialog.validationIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\check")
        dialog.validationIcon:SetVertexColor(0.3, 0.85, 0.3)
        dialog.validationMsg:SetText(L["Valid range"])
        dialog.validationMsg:SetTextColor(0.3, 0.85, 0.3)
    elseif errorMsg then
        dialog.validationIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\close")
        dialog.validationIcon:SetVertexColor(0.85, 0.3, 0.3)
        dialog.validationMsg:SetText(errorMsg)
        dialog.validationMsg:SetTextColor(0.85, 0.3, 0.3)
    else
        dialog.validationIcon:SetTexture(nil)
        dialog.validationMsg:SetText("")
    end
    
    -- Greyed (disabled) while the input is invalid; SetDisabled handles the
    -- dimmed backdrop + faded label.
    dialog.createBtn:SetDisabled(not isValid)

    return isValid
end

function AutoProfilesUI:SubmitDialog()
    local dialog = profileDialog
    if not dialog then return end
    
    local name = strtrim(dialog.nameInput:GetText() or "")
    local minVal = dialog.currentMin
    local maxVal = dialog.currentMax
    local contentType = dialog.contentType
    
    local success, err
    if dialog.isEditMode then
        success, err = self:UpdateProfileRange(contentType.key, dialog.profileIndex, minVal, maxVal)
    else
        success, err = self:CreateProfile(contentType.key, name, minVal, maxVal)
    end
    
    if success then
        dialog:Hide()
        if dialog.pageFrame and dialog.pageFrame.Refresh then
            dialog.pageFrame:Refresh()
        end
        -- Re-evaluate which profile should be active after range change
        self:EvaluateAndApply()
    else
        dialog.validationIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\close")
        dialog.validationIcon:SetVertexColor(0.85, 0.3, 0.3)
        dialog.validationMsg:SetText(err or L["Unknown error"])
        dialog.validationMsg:SetTextColor(0.85, 0.3, 0.3)
    end
end

-- ============================================================
-- COPY TO DIALOG
-- ============================================================

local copyDialog = nil

function AutoProfilesUI:CreateCopyDialog()
    if copyDialog then return copyDialog end

    local dialog = CreateFrame("Frame", "DandersAutoProfileCopyDialog", UIParent, "BackdropTemplate")
    dialog:SetSize(360, 280)
    dialog:SetPoint("CENTER", DF.GUIFrame or UIParent, "CENTER", 0, 0)
    DF.GUI:CreatePanelBackdrop(dialog, { bgAlpha = 0.98, borderColor = { 0, 0, 0, 1 } })
    dialog:SetFrameStrata("FULLSCREEN_DIALOG")
    dialog:SetFrameLevel(100)
    dialog:EnableMouse(true)
    dialog:SetMovable(true)
    dialog:RegisterForDrag("LeftButton")
    dialog:SetScript("OnDragStart", dialog.StartMoving)
    dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
    dialog:Hide()

    -- Title
    local title = dialog:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetText(L["Copy Layout"])
    title:SetTextColor(0.9, 0.9, 0.9)
    dialog.title = title

    -- Close button
    local closeBtn = DF.GUI:CreateCloseButton(dialog, { onClick = function() dialog:Hide() end })
    closeBtn:SetPoint("TOPRIGHT", -6, -6)

    -- =============================================
    -- Layout Name Section
    -- =============================================
    local nameLabel = dialog:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    nameLabel:SetPoint("TOPLEFT", 12, -40)
    nameLabel:SetText(L["Layout Name"])
    nameLabel:SetTextColor(0.6, 0.6, 0.6)

    local nameInput = CreateFrame("EditBox", nil, dialog, "BackdropTemplate")
    nameInput:SetSize(336, 26)
    nameInput:SetPoint("TOPLEFT", 12, -56)
    DF.GUI:StyleEditBox(nameInput, {})
    nameInput:SetAutoFocus(false)
    nameInput:SetMaxLetters(30)
    nameInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    nameInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    nameInput:SetScript("OnTextChanged", function()
        AutoProfilesUI:ValidateCopyDialog()
    end)
    dialog.nameInput = nameInput

    -- =============================================
    -- Destination Selector (radio-style buttons)
    -- =============================================
    local destLabel = dialog:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    destLabel:SetPoint("TOPLEFT", 12, -92)
    destLabel:SetText(L["Copy To"])
    destLabel:SetTextColor(0.6, 0.6, 0.6)

    local destButtons = {}
    local buttonWidth = 106
    local buttonSpacing = 6
    local startX = 12

    for i, ct in ipairs(CONTENT_TYPES) do
        local btn = CreateFrame("Button", nil, dialog, "BackdropTemplate")
        -- Shared styler (rest + accent-wash hover; SetActive drives selection).
        -- OMIT text: keep the custom label so its colour can track selection.
        DF.GUI:StyleButton(btn, { width = buttonWidth, height = 24 })
        btn:SetPoint("TOPLEFT", startX + (i - 1) * (buttonWidth + buttonSpacing), -108)

        local btnText = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        btnText:SetPoint("CENTER")
        btnText:SetText(ct.title)
        btnText:SetTextColor(0.6, 0.6, 0.6)

        btn.contentType = ct
        btn.label = btnText

        btn:SetScript("OnClick", function(self)
            dialog.selectedDest = self.contentType.key
            AutoProfilesUI:UpdateCopyDestButtons()
            AutoProfilesUI:UpdateCopyRangeVisibility()
            AutoProfilesUI:ValidateCopyDialog()
        end)

        -- Mythic-overwrite warning tooltip: hooked so it rides alongside the
        -- styler's own hover scripts instead of clobbering them.
        btn:HookScript("OnEnter", function(self)
            if self.contentType.key == "mythic" then
                local mythicProfile = DF.db.raidAutoProfiles.mythic.profile
                if mythicProfile then
                    DF.GUI:ShowTooltip(self, {
                        title = L["Will replace existing Mythic layout"],
                        tone = "warning",
                        lines = {
                            format(L["\"%s\" will be overwritten."], mythicProfile.name),
                        },
                    })
                end
            end
        end)

        btn:HookScript("OnLeave", function(self)
            DF.GUI:HideTooltip()
        end)

        destButtons[i] = btn
    end
    dialog.destButtons = destButtons

    -- =============================================
    -- Range Section (dual-handle slider, same as profile dialog)
    -- =============================================
    local rangeLabel = dialog:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    rangeLabel:SetPoint("TOPLEFT", 12, -144)
    rangeLabel:SetText(L["Player Range"])
    rangeLabel:SetTextColor(0.6, 0.6, 0.6)
    dialog.rangeLabel = rangeLabel

    local rangeDisplay = dialog:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
    rangeDisplay:SetPoint("TOPRIGHT", -12, -144)
    rangeDisplay:SetTextColor(1, 0.5, 0.2)
    dialog.rangeDisplay = rangeDisplay

    -- Dual-handle range slider (shared helper). Copy dialog uses fixed 1..40
    -- bounds (no contentType). Preserves the orange accent + scale labels.
    local slider = DF.GUI:CreateRangeSlider(dialog, {
        width = 336,
        accent = { r = 1, g = 0.5, b = 0.2 },
        minRange = 1, maxRange = 40,
        lo = dialog.currentMin or 1, hi = dialog.currentMax or 40,
        scaleLabels = {1, 10, 20, 30, 40}, scaleMin = 1, scaleMax = 40,
        display = rangeDisplay,
        formatOne   = function(v) return format(L["%d players"], v) end,
        formatRange = function(lo, hi) return format(L["%d - %d players"], lo, hi) end,
        onChange = function(lo, hi)
            dialog.currentMin, dialog.currentMax = lo, hi
            AutoProfilesUI:ValidateCopyDialog()
        end,
    })
    slider:SetPoint("TOPLEFT", 12, -164)
    dialog.sliderTrack = slider

    dialog.UpdateSliderVisuals = function()
        slider:SetRange(1, 40)
        slider:SetValues(dialog.currentMin or 1, dialog.currentMax or 40)
        AutoProfilesUI:ValidateCopyDialog()
    end

    -- Mythic fixed label (shown when mythic is selected destination)
    local mythicFixedLabel = dialog:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    mythicFixedLabel:SetPoint("TOPLEFT", 12, -155)
    mythicFixedLabel:SetText(L["Fixed at 20 players (Mythic)"])
    mythicFixedLabel:SetTextColor(0.5, 0.5, 0.5)
    mythicFixedLabel:Hide()
    dialog.mythicFixedLabel = mythicFixedLabel

    -- =============================================
    -- Validation Message
    -- =============================================
    local validationIcon = dialog:CreateTexture(nil, "OVERLAY")
    validationIcon:SetSize(14, 14)
    validationIcon:SetPoint("TOPLEFT", 12, -200)
    dialog.validationIcon = validationIcon

    local validationMsg = dialog:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    validationMsg:SetPoint("LEFT", validationIcon, "RIGHT", 6, 0)
    validationMsg:SetWidth(310)
    validationMsg:SetJustifyH("LEFT")
    dialog.validationMsg = validationMsg

    -- =============================================
    -- Buttons
    -- =============================================
    local cancelBtn = CreateFrame("Button", nil, dialog, "BackdropTemplate")
    cancelBtn:SetPoint("BOTTOMLEFT", 12, 12)
    DF.GUI:StyleButton(cancelBtn, { width = 80, height = 26, text = L["Cancel"] })
    cancelBtn:SetScript("OnClick", function()
        dialog:Hide()
    end)

    local createBtn = CreateFrame("Button", nil, dialog, "BackdropTemplate")
    createBtn:SetPoint("BOTTOMRIGHT", -12, 12)
    -- Primary CTA in the AutoProfiles orange identity; ValidateCopyDialog drives
    -- its greyed (disabled) state via SetDisabled below.
    DF.GUI:StyleButton(createBtn, {
        width = 100, height = 26, text = L["Copy Layout"],
        primary = true, accent = { r = 1, g = 0.5, b = 0.2 },
    })
    dialog.createBtnText = createBtn.Text

    createBtn:SetScript("OnClick", function(self)
        if self.dfDisabled then return end
        AutoProfilesUI:SubmitCopyDialog()
    end)
    dialog.createBtn = createBtn

    copyDialog = dialog
    return dialog
end

function AutoProfilesUI:UpdateCopyDestButtons()
    local dialog = copyDialog
    if not dialog then return end

    for _, btn in ipairs(dialog.destButtons) do
        local isSelected = btn.contentType.key == dialog.selectedDest
        -- Backdrop selection state via the shared styler.
        btn:SetActive(isSelected)
        -- Custom label colour still tracks selection (styler leaves it alone).
        if isSelected then
            local a = (DF.GUI.GetThemeColor and DF.GUI.GetThemeColor()) or { r = 1, g = 0.5, b = 0.2 }
            btn.label:SetTextColor(a.r, a.g, a.b)
        else
            btn.label:SetTextColor(0.6, 0.6, 0.6)
        end
    end
end

function AutoProfilesUI:UpdateCopyRangeVisibility()
    local dialog = copyDialog
    if not dialog then return end

    local isMythic = dialog.selectedDest == "mythic"

    if isMythic then
        dialog.rangeLabel:Hide()
        dialog.rangeDisplay:Hide()
        dialog.sliderTrack:Hide()
        dialog.mythicFixedLabel:Show()
        -- Adjust validation and dialog height
        dialog.validationIcon:ClearAllPoints()
        dialog.validationIcon:SetPoint("TOPLEFT", 12, -175)
        dialog:SetHeight(250)
    else
        dialog.rangeLabel:Show()
        dialog.rangeDisplay:Show()
        dialog.sliderTrack:Show()
        dialog.mythicFixedLabel:Hide()
        dialog.validationIcon:ClearAllPoints()
        dialog.validationIcon:SetPoint("TOPLEFT", 12, -200)
        dialog:SetHeight(280)
    end
end

function AutoProfilesUI:ShowCopyDialog(contentType, profile, index, pageFrame)
    local dialog = self:CreateCopyDialog()

    -- Re-anchor to GUI frame if it exists now
    if DF.GUIFrame then
        dialog:ClearAllPoints()
        dialog:SetPoint("CENTER", DF.GUIFrame, "CENTER", 0, 0)
    end

    -- Store context
    dialog.sourceContentType = contentType.key
    dialog.sourceProfile = profile
    dialog.pageFrame = pageFrame

    -- Pre-fill name
    dialog.nameInput:SetText(format(L["%s (Copy)"], profile.name or L["Unnamed"]))

    -- Default destination to the same content type (same-section copy is common)
    dialog.selectedDest = contentType.key

    -- Set initial range from source profile
    if contentType.isFixed then
        dialog.currentMin = 1
        dialog.currentMax = 40
    else
        dialog.currentMin = profile.min or 1
        dialog.currentMax = profile.max or 40
    end

    -- Update UI
    self:UpdateCopyDestButtons()
    self:UpdateCopyRangeVisibility()
    dialog.UpdateSliderVisuals()
    self:ValidateCopyDialog()
    dialog:Show()
    dialog.nameInput:SetFocus()
end

function AutoProfilesUI:ValidateCopyDialog()
    local dialog = copyDialog
    if not dialog or not dialog:IsShown() then return false end

    local isValid = true
    local errorMsg = nil
    local name = strtrim(dialog.nameInput:GetText() or "")
    local destKey = dialog.selectedDest

    if not destKey then
        isValid = false
        errorMsg = L["Select a destination"]
    elseif name == "" then
        isValid = false
        errorMsg = L["Enter a layout name"]
    else
        -- Check name conflict in destination
        local profiles = self:GetProfiles(destKey)
        for _, p in ipairs(profiles) do
            if p.name:lower() == name:lower() then
                if destKey == "mythic" then
                    -- Mythic replaces, so name conflict is a warning not a block
                    break
                end
                isValid = false
                errorMsg = format(L["A layout with this name already exists in %s"], destKey)
                break
            end
        end

        -- Check range overlap (only for non-mythic destinations)
        if isValid and destKey ~= "mythic" then
            local minVal = dialog.currentMin or 1
            local maxVal = dialog.currentMax or 40
            local overlap = self:CheckRangeOverlap(destKey, minVal, maxVal)
            if overlap then
                isValid = false
                errorMsg = format(L["Overlaps with \"%s\" (%d-%d)"], overlap.name, overlap.min, overlap.max)
            end
        end
    end

    -- Update validation display
    if isValid then
        dialog.validationIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\check")
        dialog.validationIcon:SetVertexColor(0.3, 0.85, 0.3)
        if destKey == "mythic" and DF.db.raidAutoProfiles.mythic.profile then
            dialog.validationMsg:SetText(L["Will replace existing Mythic layout"])
            dialog.validationMsg:SetTextColor(1, 0.67, 0)
        else
            dialog.validationMsg:SetText(L["Ready to copy"])
            dialog.validationMsg:SetTextColor(0.3, 0.85, 0.3)
        end
    elseif errorMsg then
        dialog.validationIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\close")
        dialog.validationIcon:SetVertexColor(0.85, 0.3, 0.3)
        dialog.validationMsg:SetText(errorMsg)
        dialog.validationMsg:SetTextColor(0.85, 0.3, 0.3)
    else
        dialog.validationIcon:SetTexture(nil)
        dialog.validationMsg:SetText("")
    end

    -- Greyed (disabled) while the input is invalid; SetDisabled handles the
    -- dimmed backdrop + faded label.
    dialog.createBtn:SetDisabled(not isValid)

    return isValid
end

function AutoProfilesUI:SubmitCopyDialog()
    local dialog = copyDialog
    if not dialog then return end

    local name = strtrim(dialog.nameInput:GetText() or "")
    local destKey = dialog.selectedDest
    local sourceProfile = dialog.sourceProfile

    -- Deep-copy the overrides from the source
    local copiedOverrides = {}
    if sourceProfile.overrides then
        for k, v in pairs(sourceProfile.overrides) do
            copiedOverrides[k] = DeepCopyValue(v)
        end
    end

    if destKey == "mythic" then
        -- Mythic: single profile, just replace
        self:InitDefaults()
        DF.db.raidAutoProfiles.mythic.profile = {
            name = name,
            overrides = copiedOverrides,
        }
    else
        -- Instanced / Open World: use CreateProfile then inject overrides
        local minVal = dialog.currentMin or 1
        local maxVal = dialog.currentMax or 40
        local success, err = self:CreateProfile(destKey, name, minVal, maxVal)
        if not success then
            dialog.validationIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\close")
            dialog.validationIcon:SetVertexColor(0.85, 0.3, 0.3)
            dialog.validationMsg:SetText(err or L["Unknown error"])
            dialog.validationMsg:SetTextColor(0.85, 0.3, 0.3)
            return
        end

        -- Find the newly created profile and inject overrides
        local profiles = DF.db.raidAutoProfiles[destKey].profiles
        for _, p in ipairs(profiles) do
            if p.name == name then
                p.overrides = copiedOverrides
                break
            end
        end
    end

    dialog:Hide()
    if dialog.pageFrame and dialog.pageFrame.Refresh then
        dialog.pageFrame:Refresh()
    end
    self:EvaluateAndApply()
end

-- ============================================================
-- EDIT MODE STATE & FUNCTIONS
-- ============================================================

-- Runtime state (not persisted)
AutoProfilesUI.editingProfile = nil
AutoProfilesUI.editingContentType = nil
AutoProfilesUI.editingProfileIndex = nil
AutoProfilesUI.globalSnapshot = nil  -- Snapshot of true global values during editing

-- Runtime auto-profile state (not persisted — rebuilt on login/reload via events)
AutoProfilesUI.activeRuntimeProfile = nil     -- Currently applied profile reference
AutoProfilesUI.activeRuntimeContentKey = nil  -- "mythic"/"instanced"/"openWorld"
AutoProfilesUI.pendingAutoProfileEval = false -- Queued evaluation during combat

function AutoProfilesUI:IsEditing()
    return self.editingProfile ~= nil
end

-- True when an auto layout is currently driving the live raid frames. Used to
-- steer base-position edits (the toolbar Unlock + /df raidunlock) toward the
-- active layout's own Unlock button so users don't move the base by accident.
function AutoProfilesUI:IsLayoutActive()
    return self.activeRuntimeProfile ~= nil
end

function AutoProfilesUI:GetActiveLayoutName()
    return self.activeRuntimeProfile and self.activeRuntimeProfile.name or nil
end

function AutoProfilesUI:EnterEditing(contentType, profileIndex)
    DF:Debug("LAYOUT", "EnterEditing: contentType=%s profileIndex=%s", contentType, tostring(profileIndex))

    -- Enforcement guard (mirror of the row's blockEdit greying in CreateProfileRow).
    -- Editing writes the layout's settings into the live raid db for preview, so
    -- the real raid frames only stay correct when the layout being edited is the
    -- one actually driving them. Refuse when editing would disturb live frames:
    -- a different layout is running, OR you're in a raid group with no layout
    -- running. Done here (not just on the button) because the button's disabled
    -- state is computed at page-draw time and can go stale if raid state changes.
    -- Resolved BEFORE the overlay clear below nils activeRuntimeProfile.
    do
        local apDb = DF.db.raidAutoProfiles
        local requested
        if contentType == "mythic" then
            requested = apDb.mythic and apDb.mythic.profile
        else
            local profiles = apDb[contentType] and apDb[contentType].profiles
            requested = profiles and profiles[profileIndex]
        end
        if requested and self.activeRuntimeProfile ~= requested
            and (self.activeRuntimeProfile ~= nil or IsInRaid()) then
            DF:DebugWarn("LAYOUT", "EnterEditing: refused — only the active layout is editable in a raid group")
            -- The row's Edit button greys out with a tooltip, but its disabled
            -- state is drawn at page-build time and can be STALE (e.g. you
            -- joined a raid with the window open). A silent refusal on a
            -- clickable-looking button reads as "broken" — say why in chat and
            -- redraw the page so the button greys correctly.
            local msg
            if self.activeRuntimeProfile then
                msg = (L["Only the active layout can be edited\nwhile auto layouts are running."] or ""):gsub("\n", " ")
            else
                msg = L["While in a raid group you can only edit the active layout. Leave the raid group to edit other layouts."]
            end
            print("|cffff9900DandersFrames:|r " .. (msg or ""))
            local GUI = DF.GUI
            if GUI and GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
            return false, "Blocked: live raid frames"
        end
    end

    -- Clear overlay so snapshot captures true globals (no RemoveRuntimeProfile
    -- needed — real table was never mutated)
    if self.activeRuntimeProfile then
        DF:Debug("LAYOUT", "EnterEditing: clearing active runtime overlay before snapshot")
        DF.raidOverrides = nil
        self.activeRuntimeProfile = nil
        self.activeRuntimeContentKey = nil
    end

    local autoDb = DF.db.raidAutoProfiles

    if contentType == "mythic" then
        self.editingProfile = autoDb.mythic.profile
        self.editingProfileIndex = nil
    else
        local profiles = autoDb[contentType] and autoDb[contentType].profiles
        if profiles and profiles[profileIndex] then
            self.editingProfile = profiles[profileIndex]
            self.editingProfileIndex = profileIndex
        else
            DF:DebugWarn("LAYOUT", "EnterEditing: profile not found at index %s", tostring(profileIndex))
            return false, "Profile not found"
        end
    end
    
    self.editingContentType = contentType
    DF:Debug("LAYOUT", "EnterEditing: editing \"%s\" (%s)", self.editingProfile.name or "?", contentType)

    -- Snapshot ALL true global values before anything gets modified
    -- This lets controls freely write to DF._realRaidDB for live preview while
    -- SetProfileSetting/GetGlobalValue always know the original globals
    self.globalSnapshot = {}
    for key, value in pairs(DF._realRaidDB) do
        self.globalSnapshot[key] = DeepCopyValue(value)
    end

    -- Snapshot pinned frames overridable settings (stored as "pinned.N.setting" keys)
    -- Pinned frames live at raid.pinnedFrames
    -- IMPORTANT: Iterate PINNED_OVERRIDABLE keys rather than set keys to ensure
    -- we capture ALL overridable settings, even ones that are nil due to missing migration.
    -- If a key is nil, backfill a default so both the snapshot and set are consistent.
    -- Only `enabled` is overridable (PINNED_OVERRIDABLE = {enabled}), and the loop
    -- below reads PINNED_DEFAULTS only for the keys it iterates — so this table needs
    -- just `enabled`. (It previously listed ~13 dead keys, incl. a keepOfflinePlayers
    -- default that contradicted the real Config/Options default.)
    local PINNED_DEFAULTS = {
        enabled = false,
    }
    local pinnedFrames = DF._realRaidDB and DF._realRaidDB.pinnedFrames
    if pinnedFrames and pinnedFrames.sets then
        for setIdx, set in pairs(pinnedFrames.sets) do
            for setting, _ in pairs(PINNED_OVERRIDABLE) do
                local value = set[setting]
                -- Backfill nil values with defaults so snapshot always has a baseline
                if value == nil then
                    value = PINNED_DEFAULTS[setting]
                    set[setting] = DeepCopyValue(value)
                    value = set[setting]
                end
                local snapKey = "pinned." .. setIdx .. "." .. setting
                self.globalSnapshot[snapKey] = DeepCopyValue(value)
            end
        end
    end
    
    -- Persist a lightweight recovery flag so a crash/disconnect during editing
    -- can be detected on next login and contaminated values reset to defaults
    local recoveryKeys = {}
    for key in pairs(self.globalSnapshot) do
        recoveryKeys[#recoveryKeys + 1] = key
    end
    DF.db.raidAutoEditingRecovery = {
        contentType = contentType,
        profileIndex = profileIndex,
        snapshotKeys = recoveryKeys,
    }

    -- Apply existing overrides to db.raid for live preview.
    -- Skip "pinnedFrames" as a direct key — it is a stale artifact from an older
    -- bug where dragging a pinned frame during editing caused the entire pinnedFrames
    -- table (including position) to be saved as a profile override. Pinned frame
    -- settings are managed via "pinned.N.setting" keys; applying the raw table would
    -- overwrite _realRaidDB.pinnedFrames and move the frame to the stored position.
    local overrideCount = 0
    if self.editingProfile.overrides then
        for key, value in pairs(self.editingProfile.overrides) do
            if key == "pinnedFrames" then
                DF:DebugWarn("LAYOUT", "EnterEditing: skipping stale pinnedFrames direct override key")
            elseif not IsKeyOverridable(key) then
                -- transient/never-override key (e.g. a stale raidLocked) — don't
                -- apply it to the live preview (ExitEditing self-heals it away).
                DF:DebugWarn("LAYOUT", "EnterEditing: skipping non-overridable override \"%s\"", key)
            else
                SetRaidValue(key, DeepCopyValue(value))
                overrideCount = overrideCount + 1
            end
        end
    end
    DF:Debug("LAYOUT", "EnterEditing: applied %d overrides for live preview", overrideCount)
    
    -- Refresh pinned frames to show overridden settings in live preview.
    --   * In an actual raid: re-apply each set's enabled + layout to the LIVE
    --     pinned frames (their methods key off live IsInRaid()).
    --   * In raid TEST mode: the live frames stay party-mode and must not be
    --     touched (that would apply the raid layout to the party set / leak the
    --     party header). Instead just re-run the raid test-mode pinned frames so
    --     they re-size to the layout's overridden frame width via their own
    --     mode-explicit path (ApplyPlayerTestLayout reads the raid DB).
    if DF.PinnedFrames and IsInRaid() then
        local pf = DF.db.raid and DF.db.raid.pinnedFrames
        for i = 1, DF.PinnedFrames.MAX_SETS do
            local setEnabled = pf and pf.sets and pf.sets[i] and pf.sets[i].enabled
            DF.PinnedFrames:SetEnabled(i, setEnabled or false)
            DF.PinnedFrames:ApplyLayoutSettings(i)
            DF.PinnedFrames:ResizeContainer(i)
            DF.PinnedFrames:UpdateHeaderNameList(i)
        end
    elseif DF.PinnedFrames and DF.raidTestMode then
        DF.PinnedFrames:ExitTestMode()
        DF.PinnedFrames:EnterTestMode()
    end

    -- Refresh test mode frames so they display override values.
    -- PositionTestRaidContainer MUST run before RefreshTestFramesWithLayout:
    -- the overrides written above may include a raidAnchorX/Y for this profile,
    -- and frames are positioned relative to testRaidContainer's BOTTOMLEFT.
    -- If the container isn't moved first, frames land at the wrong screen position.
    -- (#906)
    if DF.raidTestMode then
        if DF.PositionTestRaidContainer then
            DF:PositionTestRaidContainer()
        end
        -- If the mover is visible (frames unlocked), sync its position and scale
        -- to match the freshly-positioned test container. The profile overrides
        -- applied above may include a different raidAnchorX/Y or frameScale, so
        -- the mover needs to follow the container or it will appear offset.
        if DF.raidMoverFrame and DF.raidMoverFrame:IsShown() then
            local moverDb = DF:GetRaidDB()
            local moverScale = moverDb.frameScale or 1.0
            DF.raidMoverFrame:SetScale(moverScale)
            DF.raidMoverFrame:ClearAllPoints()
            DF.raidMoverFrame:SetPoint("CENTER", UIParent, "CENTER", (moverDb.raidAnchorX or 0) / moverScale, (moverDb.raidAnchorY or 0) / moverScale)
        end
        -- Refresh position panel inputs to reflect the newly-applied override anchor/scale
        if DF.positionPanel and DF.positionPanel:IsShown() and DF.UpdatePositionPanel then
            DF:UpdatePositionPanel()
        end
        if DF.RefreshTestFramesWithLayout then
            DF:RefreshTestFramesWithLayout()
        end
    end

    -- Refresh the GUI to show editing banner and disable Auto Profiles tab
    self:RefreshEditingUI()
    
    -- Switch to a settings tab (e.g., Layout/Frame)
    -- Suppress sidebar hint dismissal for this initial SelectTab call
    self.suppressHintDismiss = true
    local GUI = DF.GUI
    -- The page build cache is keyed on mode only, not the active layout, so other
    -- tabs (Aura Designer / Text Designer frame previews especially) would re-show
    -- the previous layout's geometry. Invalidate every page so each rebuilds for
    -- this layout's frame size on next view.
    if GUI and GUI.InvalidateAllPages then GUI:InvalidateAllPages() end
    if GUI and GUI.SelectTab then
        GUI.SelectTab("general_frame")
    end
    self.suppressHintDismiss = false

    -- Show sidebar onboarding hint (dismissed on first user tab click)
    self:ShowSidebarHint()

    -- Show override stars on tabs that have overridden settings
    self:RefreshTabOverrideStars()

    return true
end

-- Deep-compare two values (recursive for nested tables)
local function DeepCompare(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if not DeepCompare(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

function AutoProfilesUI:ExitEditing(skipUIUpdates)
    DF:Debug("LAYOUT", "ExitEditing: profile=\"%s\" skipUIUpdates=%s", self.editingProfile and self.editingProfile.name or "?", tostring(skipUIUpdates))

    -- Diff safety net: before restoring globals, scan live values vs snapshot
    -- to catch any overrides that weren't explicitly tracked by controls
    if self.editingProfile and self.globalSnapshot then
        if not self.editingProfile.overrides then
            self.editingProfile.overrides = {}
        end
        local overrides = self.editingProfile.overrides
        local autoStored, autoCleaned = 0, 0

        for key, snapshotVal in pairs(self.globalSnapshot) do
            -- Skip "pinnedFrames" as a direct key. Pinned frame settings are tracked
            -- via "pinned.N.setting" keys (PINNED_OVERRIDABLE). Comparing the whole
            -- pinnedFrames table would cause position changes (from dragging during
            -- editing) to be stored as a top-level profile override, which then
            -- overwrites _realRaidDB.pinnedFrames and moves the frame on next activation.
            if key == "pinnedFrames" then
                -- Clean up any stale pinnedFrames override that may already exist
                if overrides[key] ~= nil then
                    overrides[key] = nil
                    autoCleaned = autoCleaned + 1
                    DF:DebugWarn("LAYOUT", "ExitEditing: removed stale pinnedFrames direct override key")
                end
            elseif not IsKeyOverridable(key) then
                -- Transient/never-override key (e.g. raidLocked) — never store it,
                -- and self-heal any override an earlier build captured.
                if overrides[key] ~= nil then
                    overrides[key] = nil
                    autoCleaned = autoCleaned + 1
                    DF:DebugWarn("LAYOUT", "ExitEditing: removed non-overridable override \"%s\"", key)
                end
            else
                local currentVal = GetRaidValue(key)
                local matches = DeepCompare(snapshotVal, currentVal)

                -- If this table-valued setting is already tracked via flat indexed
                -- sub-overrides ("key_5".."key_8", e.g. raidGroupVisible written by the
                -- group-visibility checkboxes), don't ALSO store the whole table here —
                -- that double-stores the same setting and collides in
                -- ApplyRuntimeProfile. The flat sub-keys are canonical.
                local hasFlatSiblings = false
                if type(currentVal) == "table" then
                    for ok in pairs(overrides) do
                        if ok:match("^(.+)_%d+$") == key then hasFlatSiblings = true break end
                    end
                end

                if hasFlatSiblings then
                    -- Drop any stale whole-table override (older saves stored it) so
                    -- existing dirty profiles self-heal on next exit-editing.
                    if overrides[key] ~= nil then
                        overrides[key] = nil
                        autoCleaned = autoCleaned + 1
                        DF:DebugWarn("LAYOUT", "ExitEditing: removed redundant whole-table override \"%s\" (tracked via flat keys)", key)
                    end
                elseif not matches then
                    -- Only deep-copy when override is new or has actually changed
                    if overrides[key] == nil or not DeepCompare(overrides[key], currentVal) then
                        overrides[key] = DeepCopyValue(currentVal)
                        autoStored = autoStored + 1
                    end
                elseif matches and overrides[key] ~= nil
                    and key ~= "textDesignerPreset" and key ~= "auraDesignerPreset" then
                    -- Designer preset refs are exempt from the equal→remove
                    -- cleanup: SetModeDesignerPreset deliberately stamps the
                    -- override even when the chosen name EQUALS the global's
                    -- (explicit pin vs Inherit is presence-based). Removing it
                    -- here silently reverted the layout to "Inherit (Global)"
                    -- on exit.
                    overrides[key] = nil
                    autoCleaned = autoCleaned + 1
                end
            end
        end

        -- Remove orphan keys created during editing that aren't tracked overrides
        local orphansRemoved = 0
        for key in pairs(DF._realRaidDB) do
            if self.globalSnapshot[key] == nil and not overrides[key] then
                DF._realRaidDB[key] = nil
                orphansRemoved = orphansRemoved + 1
            end
        end

        local totalOverrides = 0
        for _ in pairs(overrides) do totalOverrides = totalOverrides + 1 end
        DF:Debug("LAYOUT", "ExitEditing: diff scan — autoStored=%d autoCleaned=%d orphansRemoved=%d totalOverrides=%d", autoStored, autoCleaned, orphansRemoved, totalOverrides)
    end
    
    -- Restore all modified values back to their true globals
    -- SetRaidValue handles raid keys, table keys, and pinned keys
    if self.globalSnapshot then
        for key, originalValue in pairs(self.globalSnapshot) do
            SetRaidValue(key, DeepCopyValue(originalValue))
        end
    end
    
    self.editingProfile = nil
    self.editingContentType = nil
    self.editingProfileIndex = nil
    self.globalSnapshot = nil

    -- Clear crash recovery flag — editing exited cleanly
    if DF.db then
        DF.db.raidAutoEditingRecovery = nil
    end

    -- Hide sidebar hint if still showing
    self:HideSidebarHint()

    -- Clear override stars (they'll refresh after EvaluateAndApply if a runtime profile re-applies)
    self:RefreshTabOverrideStars()

    -- Skip UI updates when GUI is closing (UI will reset on next open anyway)
    if skipUIUpdates then return end

    -- Re-evaluate auto-profiles BEFORE UpdateAll so any re-applied overlay is in
    -- place when frames read settings — otherwise UpdateAll would read globals,
    -- then the delayed evaluator would re-apply the overlay causing a flicker.
    -- EvaluateAndApply internally checks InCombatLockdown so this is combat-safe.
    AutoProfilesUI:EvaluateAndApply()

    -- Refresh frames to show global settings again
    if DF.UpdateAll then DF:UpdateAll() end

    -- Test mode needs a full layout refresh so frames re-read restored global values
    -- UpdateAll() only calls UpdateRaidTestFrames() which skips ApplyTestFrameLayout(),
    -- so frame sizes, textures, fonts etc. would remain stuck on overridden values.
    -- PositionTestRaidContainer MUST run before RefreshTestFramesWithLayout so the
    -- container is at the restored base anchor before frames are positioned against it.
    -- (#906)
    if DF.raidTestMode then
        if DF.PositionTestRaidContainer then
            DF:PositionTestRaidContainer()
        end
        -- Sync mover position/scale to match the restored base anchor.
        -- EvaluateAndApply above may have re-applied a runtime overlay, so
        -- DF:GetRaidDB() here reflects whichever values are now authoritative.
        if DF.raidMoverFrame and DF.raidMoverFrame:IsShown() then
            local moverDb = DF:GetRaidDB()
            local moverScale = moverDb.frameScale or 1.0
            DF.raidMoverFrame:SetScale(moverScale)
            DF.raidMoverFrame:ClearAllPoints()
            DF.raidMoverFrame:SetPoint("CENTER", UIParent, "CENTER", (moverDb.raidAnchorX or 0) / moverScale, (moverDb.raidAnchorY or 0) / moverScale)
        end
        -- Refresh position panel inputs to reflect the restored anchor/scale values.
        -- EvaluateAndApply above may have re-applied a runtime overlay, so
        -- DF:GetRaidDB() is already authoritative at this point.
        if DF.positionPanel and DF.positionPanel:IsShown() and DF.UpdatePositionPanel then
            DF:UpdatePositionPanel()
        end
        if DF.RefreshTestFramesWithLayout then
            DF:RefreshTestFramesWithLayout()
        end
    elseif DF.testMode and DF.RefreshTestFramesWithLayout then
        DF:RefreshTestFramesWithLayout()
    end
    
    -- Refresh pinned frames to show global settings again (mirror of EnterEditing):
    -- live raid re-applies to the real frames; raid test mode just re-runs the test
    -- frames so they re-size back to the global frame width.
    if DF.PinnedFrames and IsInRaid() then
        local pf = DF.db.raid and DF.db.raid.pinnedFrames
        for i = 1, DF.PinnedFrames.MAX_SETS do
            -- Restore enabled state first (hides containers if globally disabled)
            local setEnabled = pf and pf.sets and pf.sets[i] and pf.sets[i].enabled
            DF.PinnedFrames:SetEnabled(i, setEnabled or false)
            DF.PinnedFrames:ApplyLayoutSettings(i)
            DF.PinnedFrames:ResizeContainer(i)
            DF.PinnedFrames:UpdateHeaderNameList(i)
        end
    elseif DF.PinnedFrames and DF.raidTestMode then
        DF.PinnedFrames:ExitTestMode()
        DF.PinnedFrames:EnterTestMode()
    end
    
    -- Refresh UI to hide banner and re-enable Auto Profiles tab
    self:RefreshEditingUI()
    
    -- Switch back to Auto Profiles tab
    local GUI = DF.GUI
    -- Active layout reverted to global — invalidate page caches so tabs (and their
    -- frame previews) rebuild at the global frame size on next view.
    if GUI and GUI.InvalidateAllPages then GUI:InvalidateAllPages() end
    if GUI and GUI.SelectTab then
        GUI.SelectTab("profiles_auto")
    end
end

function AutoProfilesUI:GetEditingInfo()
    if not self:IsEditing() then return nil end
    
    local profile = self.editingProfile
    local contentType = self.editingContentType
    
    -- Get content type display name
    local contentName = "Unknown"
    for _, ct in ipairs(CONTENT_TYPES) do
        if ct.key == contentType then
            contentName = ct.title
            break
        end
    end
    
    -- Get range display
    local rangeText
    if contentType == "mythic" then
        rangeText = L["20 players (fixed)"]
    else
        rangeText = format(L["%d-%d players"], profile.min, profile.max)
    end
    
    -- Count overrides
    local overrideCount = 0
    if profile.overrides then
        for _ in pairs(profile.overrides) do
            overrideCount = overrideCount + 1
        end
    end
    
    return {
        name = profile.name or L["Unnamed"],
        contentType = contentType,
        contentName = contentName,
        rangeText = rangeText,
        overrideCount = overrideCount,
    }
end

-- ============================================================
-- EDITING BANNER
-- ============================================================

local editingBanner = nil

function AutoProfilesUI:CreateEditingBanner(parent)
    if editingBanner then return editingBanner end
    
    local banner = CreateFrame("Frame", "DandersAutoProfilesEditingBanner", parent, "BackdropTemplate")
    banner:SetHeight(50)
    banner:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    banner:SetBackdropColor(0.15, 0.08, 0.03, 1)
    banner:SetBackdropBorderColor(1, 0.5, 0.2, 1)
    banner:SetFrameLevel(parent:GetFrameLevel() + 50)  -- Ensure banner is above page content
    banner:Hide()
    
    -- Settings icon
    local icon = banner:CreateTexture(nil, "OVERLAY")
    icon:SetPoint("LEFT", 12, 0)
    icon:SetSize(20, 20)
    icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\settings")
    icon:SetVertexColor(1, 0.5, 0.2)
    
    -- "Editing:" label
    local editLabel = banner:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    editLabel:SetPoint("LEFT", icon, "RIGHT", 8, 6)
    editLabel:SetText(L["Editing:"])
    editLabel:SetTextColor(0.7, 0.7, 0.7)
    
    -- Profile name and content type
    local profileText = banner:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    profileText:SetPoint("LEFT", editLabel, "RIGHT", 6, 0)
    profileText:SetTextColor(1, 0.5, 0.2)
    banner.profileText = profileText
    
    -- Range info line
    local infoText = banner:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    infoText:SetPoint("LEFT", icon, "RIGHT", 8, -10)
    infoText:SetTextColor(0.5, 0.5, 0.5)
    banner.infoText = infoText
    
    -- Exit Editing button
    local exitBtn = CreateFrame("Button", nil, banner, "BackdropTemplate")
    exitBtn:SetPoint("RIGHT", -12, 0)
    -- Fixed orange accent (raid-only feature identity) so the hover wash doesn't
    -- track the party theme like an unscoped StyleButton would.
    DF.GUI:StyleButton(exitBtn, { width = 90, height = 26, text = L["Exit Editing"], accent = { r = 1, g = 0.5, b = 0.2 } })
    exitBtn:SetScript("OnClick", function()
        AutoProfilesUI:ExitEditing()
    end)

    -- (The per-layout "Reset to Global" Aura Designer button was retired when the
    -- preset dropdown gained an "Inherit (Global)" entry that does the same job.)

    editingBanner = banner
    return banner
end

function AutoProfilesUI:UpdateEditingBanner()
    if not editingBanner then return end

    local info = self:GetEditingInfo()
    if info then
        -- Use "»" (Latin-1) not "→" (U+2192): the bundled font lacks the arrow
        -- glyph and renders it as a "?" / missing-glyph box.
        editingBanner.profileText:SetText(info.contentName .. " » \"" .. info.name .. "\"")

        -- Show contextual info text based on the current page. Aura/Text Designer
        -- are chosen via the preset dropdown on their pages (with an "Inherit
        -- (Global)" entry), so point there; other pages keep the generic message.
        local GUI = DF.GUI
        local pageName = GUI and GUI.CurrentPageName
        if pageName == "auras_auradesigner" then
            editingBanner.infoText:SetText(info.rangeText .. " · |cffffcc66" .. L["Pick an Aura Designer preset below for this layout. 'Inherit (Global)' follows your global one."] .. "|r")
        elseif pageName == "text_designer" then
            editingBanner.infoText:SetText(info.rangeText .. " · |cffffcc66" .. L["Pick a Text Designer preset below for this layout. 'Inherit (Global)' follows your global one."] .. "|r")
        else
            editingBanner.infoText:SetText(info.rangeText .. " · " .. L["Only changed settings will be saved"])
        end

        editingBanner:Show()
    else
        editingBanner:Hide()
    end
end

function AutoProfilesUI:RefreshEditingUI()
    local GUI = DF.GUI
    if not GUI then return end
    
    -- Update the editing banner
    self:UpdateEditingBanner()
    
    -- Disable profile-related tabs when editing
    local tabsToDisable = {"profiles_auto", "profiles_manage", "profiles_importexport"}
    for _, tabName in ipairs(tabsToDisable) do
        local tab = GUI.Tabs and GUI.Tabs[tabName]
        if tab then
            if self:IsEditing() then
                -- Mark tab as disabled (GUI.lua will also respect this)
                tab.disabled = true
                tab:EnableMouse(false)
                tab.Text:SetTextColor(0.2, 0.2, 0.2)  -- Very dark grey
                tab.Text:SetAlpha(0.8)  -- Also reduce alpha
                if tab.accent then tab.accent:Hide() end
                tab.isActive = false
                tab:SetBackdropColor(0, 0, 0, 0)
            else
                -- Re-enable the tab
                tab.disabled = false
                tab:EnableMouse(true)
                tab.Text:SetTextColor(0.9, 0.9, 0.9)
                tab.Text:SetAlpha(1)  -- Restore alpha
            end
        end
    end
    
    -- Disable Party button and Binds button when editing (must stay in Raid mode)
    local buttonsToDisable = {GUI.PartyButton, GUI.ClicksButton}
    for _, btn in ipairs(buttonsToDisable) do
        if btn then
            if self:IsEditing() then
                btn.disabled = true
                btn:EnableMouse(false)
                btn.Text:SetTextColor(0.2, 0.2, 0.2)
                btn.Text:SetAlpha(0.8)
                btn:SetBackdropColor(0.1, 0.1, 0.1, 0.5)
                btn:SetBackdropBorderColor(0.2, 0.2, 0.2, 0.5)
            else
                btn.disabled = false
                btn:EnableMouse(true)
                btn.Text:SetAlpha(1)
                -- Colors will be restored by UpdateThemeColors below
            end
        end
    end
    
    -- Restore proper button colors when not editing
    if not self:IsEditing() and GUI.UpdateThemeColors then
        GUI.UpdateThemeColors()
    end
    
    -- Update page offset for current page
    self:UpdatePageOffset()
    
    -- Refresh all override indicators
    if GUI.RefreshAllOverrideIndicators then
        GUI.RefreshAllOverrideIndicators()
    end
end

function AutoProfilesUI:UpdatePageOffset()
    local GUI = DF.GUI
    if not GUI or not GUI.CurrentPageName then return end
    
    -- The layout code in GUI.lua now checks IsEditing() and adds offset
    -- We just need to trigger a refresh of the current page
    local page = GUI.Pages[GUI.CurrentPageName]
    if page and page.RefreshStates then
        page:RefreshStates()
    end
end

-- ============================================================
-- INTEGRATE BANNER INTO GUI
-- ============================================================

function AutoProfilesUI:SetupEditingBanner()
    local GUI = DF.GUI
    if not GUI or not GUI.contentFrame then return end

    -- Create the banner parented to the main content frame
    local banner = self:CreateEditingBanner(GUI.contentFrame)
    banner:SetPoint("TOPLEFT", GUI.contentFrame, "TOPLEFT", 0, 0)
    banner:SetPoint("TOPRIGHT", GUI.contentFrame, "TOPRIGHT", 0, 0)

    -- =============================================
    -- SIDEBAR ONBOARDING HINT
    -- Subtle orange border + text on the sidebar when editing starts.
    -- Dismissed on the first user tab click.
    -- =============================================
    local sidebarHint = CreateFrame("Frame", nil, GUI.tabFrame, "BackdropTemplate")
    sidebarHint:SetAllPoints(GUI.tabFrame)
    sidebarHint:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    sidebarHint:SetBackdropBorderColor(1, 0.5, 0.2, 0.8)
    sidebarHint:SetFrameLevel(GUI.tabFrame:GetFrameLevel() + 10)
    sidebarHint:EnableMouse(false)  -- Don't block clicks on tabs underneath
    sidebarHint:Hide()

    -- Hint label at the top of the sidebar with a background
    local hintBg = CreateFrame("Frame", nil, sidebarHint, "BackdropTemplate")
    hintBg:SetPoint("TOPLEFT", sidebarHint, "TOPLEFT", 1, -1)
    hintBg:SetPoint("TOPRIGHT", sidebarHint, "TOPRIGHT", -1, -1)
    hintBg:SetHeight(32)
    hintBg:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    hintBg:SetBackdropColor(0.12, 0.06, 0.02, 0.95)
    hintBg:EnableMouse(false)

    local hintText = hintBg:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    hintText:SetPoint("CENTER", hintBg, "CENTER", 0, 0)
    hintText:SetWidth(140)
    hintText:SetJustifyH("CENTER")
    hintText:SetText("|cffff8020" .. L["Select any tab"] .. "|r " .. L["to customise\nthis profile's settings"])
    hintText:SetTextColor(0.75, 0.75, 0.75)

    -- Subtle pulse animation on the border
    local pulseAlpha = 0.4
    local pulseDir = 1
    sidebarHint:SetScript("OnUpdate", function(self, elapsed)
        pulseAlpha = pulseAlpha + elapsed * pulseDir * 0.6
        if pulseAlpha >= 0.8 then
            pulseAlpha = 0.8
            pulseDir = -1
        elseif pulseAlpha <= 0.3 then
            pulseAlpha = 0.3
            pulseDir = 1
        end
        self:SetBackdropBorderColor(1, 0.5, 0.2, pulseAlpha)
    end)

    self.sidebarHint = sidebarHint
    self.sidebarHintDismissed = false

    -- =============================================
    -- OVERRIDE STAR INDICATORS ON TABS
    -- Small orange star on tabs that have overridden settings
    -- =============================================
    for tabName, tab in pairs(GUI.Tabs) do
        if not tab.overrideStar then
            local star = tab:CreateTexture(nil, "OVERLAY")
            star:SetSize(10, 10)
            star:SetPoint("LEFT", 12, 0)
            star:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\star")
            star:SetVertexColor(1, 0.67, 0)
            star:Hide()
            tab.overrideStar = star
        end
    end

    -- Stars on category headers (visible when category is collapsed)
    for catName, cat in pairs(GUI.Categories) do
        if not cat.overrideStar then
            local star = cat:CreateTexture(nil, "OVERLAY")
            star:SetSize(8, 8)
            star:SetPoint("RIGHT", -6, 0)
            star:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\star")
            star:SetVertexColor(1, 0.67, 0)
            star:Hide()
            cat.overrideStar = star
        end
    end

    -- Hook tab button clicks to dismiss sidebar hint and update banner
    -- Tab OnClick calls the local SelectTab (not GUI.SelectTab), so we must
    -- hook each button directly to detect user tab clicks
    for _, btn in pairs(GUI.Tabs) do
        btn:HookScript("OnClick", function()
            if AutoProfilesUI:IsEditing() then
                if not AutoProfilesUI.sidebarHintDismissed
                   and not AutoProfilesUI.suppressHintDismiss then
                    AutoProfilesUI:HideSidebarHint()
                end
                -- Update banner for page-specific elements (e.g. Aura Designer reset button)
                AutoProfilesUI:UpdateEditingBanner()
            end
        end)
    end

    -- Hook into page display to adjust offset when banner is shown
    local originalSelectTab = GUI.SelectTab
    GUI.SelectTab = function(name)
        originalSelectTab(name)

        -- After selecting tab, update banner and page offset
        AutoProfilesUI:UpdateEditingBanner()
        AutoProfilesUI:UpdatePageOffset()

        -- Re-apply disabled tab styling (SelectTab/UpdateThemeColors may have reset colors)
        if AutoProfilesUI:IsEditing() then
            local tabsToDisable = {"profiles_auto", "profiles_manage", "profiles_importexport"}
            for _, tabName in ipairs(tabsToDisable) do
                local tab = GUI.Tabs and GUI.Tabs[tabName]
                if tab then
                    tab.disabled = true
                    tab:EnableMouse(false)
                    tab.Text:SetTextColor(0.2, 0.2, 0.2)  -- Very dark grey
                    tab.Text:SetAlpha(0.8)  -- Also reduce alpha
                    if tab.accent then tab.accent:Hide() end
                    tab.isActive = false
                    tab:SetBackdropColor(0, 0, 0, 0)
                end
            end
        end
    end

    -- Also hook RefreshCurrentPage
    local originalRefresh = GUI.RefreshCurrentPage
    GUI.RefreshCurrentPage = function()
        originalRefresh()
        AutoProfilesUI:UpdateEditingBanner()
        AutoProfilesUI:UpdatePageOffset()
    end
end

function AutoProfilesUI:ShowSidebarHint()
    if self.sidebarHint then
        self.sidebarHintDismissed = false
        self.sidebarHint:Show()
    end
end

function AutoProfilesUI:HideSidebarHint()
    if self.sidebarHint then
        self.sidebarHintDismissed = true
        self.sidebarHint:Hide()
    end
end

-- Refresh orange star indicators on sidebar tabs/categories
-- Shows stars on tabs that contain overridden settings
function AutoProfilesUI:RefreshTabOverrideStars()
    local GUI = DF.GUI
    if not GUI or not GUI.Tabs then return end

    -- Determine which profile's overrides to display
    local profile
    if self:IsEditing() then
        profile = self.editingProfile
    elseif self.activeRuntimeProfile and GUI.SelectedMode == "raid" then
        profile = self.activeRuntimeProfile
    end

    -- Build set of tabIds with overrides
    local tabsWithOverrides = {}
    if profile and profile.overrides then
        for key in pairs(profile.overrides) do
            local tabId = GetOverrideTabId(key)
            if tabId then
                tabsWithOverrides[tabId] = true
            end
        end
    end

    -- Update tab stars
    for tabName, tab in pairs(GUI.Tabs) do
        if tab.overrideStar then
            if tabsWithOverrides[tabName] then
                tab.overrideStar:Show()
            else
                tab.overrideStar:Hide()
            end
        end
    end

    -- Update category stars (show if ANY child tab has overrides)
    if GUI.Categories then
        for catName, cat in pairs(GUI.Categories) do
            if cat.overrideStar then
                local hasOverride = false
                if cat.children then
                    for _, childBtn in ipairs(cat.children) do
                        if childBtn.tabName and tabsWithOverrides[childBtn.tabName] then
                            hasOverride = true
                            break
                        end
                    end
                end
                if hasOverride then
                    cat.overrideStar:Show()
                else
                    cat.overrideStar:Hide()
                end
            end
        end
    end
end

-- ============================================================
-- OVERRIDE SYSTEM FUNCTIONS
-- ============================================================

-- Get a raid setting value, checking profile overrides first
-- Returns: value, isOverridden
function AutoProfilesUI:GetRaidSetting(key)
    local globalValue = DF.db.raid[key]
    
    -- If editing a profile, check that profile's overrides
    if self.editingProfile then
        local overrides = self.editingProfile.overrides
        if overrides and overrides[key] ~= nil then
            return overrides[key], true  -- value, isOverridden
        end
        return globalValue, false
    end
    
    -- If auto-profiles enabled and not editing, check active profile
    if DF.db.raidAutoProfiles and DF.db.raidAutoProfiles.enabled then
        local activeProfile = self:GetActiveProfile()
        if activeProfile and activeProfile.overrides and activeProfile.overrides[key] ~= nil then
            return activeProfile.overrides[key], true
        end
    end
    
    return globalValue, false
end

function AutoProfilesUI:SetProfileSetting(key, value)
    if not self.editingProfile then return false end

    -- Non-overridable pinned setting (everything except `enabled` post-decouple):
    -- never store it as a layout override. Strip any existing one and bail so the
    -- control's plain global write is the only effect.
    if not IsKeyOverridable(key) then
        if self.editingProfile.overrides then
            self.editingProfile.overrides[key] = nil
        end
        return false
    end

    -- Ensure overrides table exists
    if not self.editingProfile.overrides then
        self.editingProfile.overrides = {}
    end

    -- Get the true global from snapshot (db.raid has been modified by the control already)
    local globalValue, found = GetSnapshotValue(self.globalSnapshot, key)
    if not found then
        globalValue = GetRaidValue(key)
    end

    -- Compare values (recursive deep compare handles nested tables like colors)
    local valuesMatch = DeepCompare(value, globalValue)

    if valuesMatch then
        -- Same as global, remove override
        self.editingProfile.overrides[key] = nil
        DF:Debug("LAYOUT", "SetProfileSetting: %s matches global, override removed", key)
    else
        -- Different from global, store override (deep copy to avoid reference issues)
        self.editingProfile.overrides[key] = DeepCopyValue(value)
        DF:Debug("LAYOUT", "SetProfileSetting: %s overridden (value=%s)", key, tostring(value))
    end

    -- Refresh tab stars so they update live as settings change
    self:RefreshTabOverrideStars()

    return true
end

-- Reset a setting to global (remove override)
function AutoProfilesUI:ResetProfileSetting(key)
    if not self.editingProfile then return false end
    DF:Debug("LAYOUT", "ResetProfileSetting: %s — restoring to global", key)

    if self.editingProfile.overrides then
        self.editingProfile.overrides[key] = nil
    end
    
    -- Restore the actual db value to the true global (from snapshot)
    local globalValue, found = GetSnapshotValue(self.globalSnapshot, key)
    if not found then
        globalValue = GetRaidValue(key)
    end
    
    -- Deep copy to avoid mutating the snapshot
    SetRaidValue(key, DeepCopyValue(globalValue))

    -- Refresh tab stars so they update live as overrides are removed
    self:RefreshTabOverrideStars()

    return true
end

-- Get the global value for a setting (for display purposes)
-- Returns a deep copy to prevent callers from mutating the snapshot
function AutoProfilesUI:GetGlobalValue(key)
    -- When editing, return the true global from snapshot (db.raid may have overridden values)
    local snapshotVal, found = GetSnapshotValue(self.globalSnapshot, key)
    if found then
        return DeepCopyValue(snapshotVal)
    end
    return GetRaidValue(key)
end

-- Check if a setting is currently overridden
function AutoProfilesUI:IsSettingOverridden(key)
    if not IsKeyOverridable(key) then return false end
    if not self.editingProfile or not self.editingProfile.overrides then
        return false
    end
    return self.editingProfile.overrides[key] ~= nil
end

-- Is a pinned-frame SETTING (bare name, e.g. "enabled" / "scale") overridable
-- per auto layout? Post-decouple only `enabled` is. The pinned options page uses
-- this to decide whether to show any override UI (star / reset / Global: text)
-- for a control — non-overridable controls show none, making it clear they're
-- global/independent of auto layouts.
function AutoProfilesUI:IsPinnedSettingOverridable(setting)
    return PINNED_OVERRIDABLE[setting] == true
end

-- Get active profile based on current content/raid size (for runtime, not editing)
-- Returns: profile, contentKey (or nil, nil if no match)
function AutoProfilesUI:GetActiveProfile()
    local autoDb = DF.db.raidAutoProfiles
    if not autoDb or not autoDb.enabled then
        DF:Debug("LAYOUT", "GetActiveProfile: disabled or no autoDb")
        return nil
    end

    -- Must be in a raid group for auto-profiles to apply
    if not IsInRaid() then
        DF:Debug("LAYOUT", "GetActiveProfile: not in raid")
        return nil
    end

    -- Use the existing content type detection from Core.lua
    local contentType = DF:GetContentType()
    if not contentType then
        DF:Debug("LAYOUT", "GetActiveProfile: no content type detected")
        return nil
    end

    local raidSize = GetNumGroupMembers()
    DF:Debug("LAYOUT", "GetActiveProfile: contentType=%s raidSize=%d", contentType, raidSize)

    -- Mythic: single profile, no range check needed
    if contentType == "mythic" then
        local mythicProfile = autoDb.mythic and autoDb.mythic.profile
        if mythicProfile then
            DF:Debug("LAYOUT", "GetActiveProfile: matched mythic layout \"%s\"", mythicProfile.name or "?")
            return mythicProfile, "mythic"
        end
        DF:Debug("LAYOUT", "GetActiveProfile: mythic content but no layout configured")
        return nil
    end
    
    -- Map content type to auto-profile key
    -- "battleground" falls under "instanced" (the "Instanced / PvP" category)
    local profileKey
    if contentType == "instanced" or contentType == "battleground" then
        profileKey = "instanced"
    elseif contentType == "openWorld" then
        profileKey = "openWorld"
    else
        DF:Debug("LAYOUT", "GetActiveProfile: unmapped content type \"%s\", no layout", contentType)
        return nil
    end

    -- Find matching profile by raid size within the content type
    local profile = FindMatchingProfile(profileKey, raidSize)
    if profile then
        return profile, profileKey
    end

    DF:Debug("LAYOUT", "GetActiveProfile: no matching range for %s (size %d)", profileKey, raidSize)
    return nil
end

-- ============================================================
-- RUNTIME PROFILE APPLICATION
-- Applies/removes auto-profile overrides at runtime based on
-- content type and raid size changes
-- ============================================================

-- Get a display name for a content key
local function GetContentDisplayName(contentKey)
    if contentKey == "mythic" then return L["Mythic"]
    elseif contentKey == "instanced" then return L["Instanced/PvP"]
    elseif contentKey == "openWorld" then return L["Open World"]
    end
    return contentKey or L["Unknown"]
end

-- Apply a profile's overrides as a read-through overlay (does NOT mutate the real raid table)
function AutoProfilesUI:ApplyRuntimeProfile(profile, contentKey)
    if not profile or not profile.overrides then return end
    DF:Debug("LAYOUT", "ApplyRuntimeProfile: \"%s\" (%s)", profile.name or "?", contentKey)

    -- Group nested overrides by parent table so multiple overrides on the same
    -- parent (e.g. raidGroupVisible_1 and raidGroupVisible_3) share one copy
    local tableGroups = {}   -- { [parentTable] = { [index] = value, ... } }
    local pinnedGroups = {}  -- { [setIndex] = { [setting] = value, ... } }
    local simpleKeys = {}    -- { [key] = value }

    for key, value in pairs(profile.overrides) do
        -- Defensive: never apply a transient/never-override key (e.g. a raidLocked
        -- captured by an earlier build) to the live overlay, or the layout would
        -- force the frames locked/unlocked whenever it activates.
        if not IsKeyOverridable(key) then
            -- skip
        else
            local setIndex, setting = ParsePinnedKey(key)
            if setIndex and setting then
                if not pinnedGroups[setIndex] then pinnedGroups[setIndex] = {} end
                pinnedGroups[setIndex][setting] = value
            else
                local tableName, index = ParseTableKey(key)
                if tableName and index then
                    if not tableGroups[tableName] then tableGroups[tableName] = {} end
                    tableGroups[tableName][index] = value
                else
                    simpleKeys[key] = value
                end
            end
        end
    end

    -- Build the overlay table
    local overlay = {}

    -- Simple keys: direct copy
    for key, value in pairs(simpleKeys) do
        overlay[key] = DeepCopyValue(value)
    end

    -- Table keys: deep-copy parent from real table, apply overrides
    for tableName, indices in pairs(tableGroups) do
        local parent = DeepCopyValue(DF._realRaidDB[tableName])
        if type(parent) ~= "table" then parent = {} end
        for index, value in pairs(indices) do
            parent[index] = DeepCopyValue(value)
        end
        overlay[tableName] = parent
    end

    -- Pinned keys: build a LIVE VIEW of the real pinnedFrames, not a deep copy.
    -- Post-decouple the only pinned override is per-set `enabled`, so every other
    -- pinned setting must read through to the live global (edits reflect
    -- immediately, and there's nothing to go stale). Each set that has an
    -- `enabled` override becomes a thin proxy that returns the overridden enabled
    -- but reads every other field live from the real set; sets with no override
    -- are the real table by reference. The whole pinnedFrames table is itself a
    -- live view (top-level fields read through to real).
    if next(pinnedGroups) then
        local realPF = DF._realRaidDB.pinnedFrames or {}
        local realSets = type(realPF.sets) == "table" and realPF.sets or {}
        local viewSets = {}
        for setIdx, realSet in pairs(realSets) do
            local ov = pinnedGroups[setIdx]
            if ov and ov.enabled ~= nil then
                -- __newindex: WRITES must reach the real set, or every direct
                -- field write from the Options page (width/height overrides,
                -- preset refs, border seeding, label, roster, position…)
                -- rawsets onto this throwaway view and silently reverts on the
                -- next layout switch / reload. `enabled` itself is exempt by
                -- construction: it is rawset on the view, so __newindex never
                -- fires for it — the runtime override value stays view-local
                -- while HandleRuntimeWrite persists it to override/global.
                viewSets[setIdx] = setmetatable(
                    { enabled = ov.enabled and true or false },
                    {
                        __index = realSet,
                        __newindex = function(_, key, value)
                            realSet[key] = value
                        end,
                    })
            else
                viewSets[setIdx] = realSet  -- live reference
            end
        end
        -- Top-level fields (disableInPvP, …) must equally write through to the
        -- real pinnedFrames table; `sets` is rawset above so __newindex never
        -- fires for it.
        overlay.pinnedFrames = setmetatable({ sets = viewSets }, {
            __index = realPF,
            __newindex = function(_, key, value)
                realPF[key] = value
            end,
        })
    end

    -- Activate the overlay (proxy reads this automatically)
    DF.raidOverrides = overlay

    -- Count overlay keys for debug
    local overlayCount = 0
    for _ in pairs(overlay) do overlayCount = overlayCount + 1 end
    local totalOverrides = 0
    for _ in pairs(profile.overrides) do totalOverrides = totalOverrides + 1 end
    DF:Debug("LAYOUT", "ApplyRuntimeProfile: overlay active — %d overrides, %d overlay keys", totalOverrides, overlayCount)

    -- Store active state
    self.activeRuntimeProfile = profile
    self.activeRuntimeContentKey = contentKey

    -- Refresh all frames to reflect new settings
    if DF.FullProfileRefresh then
        DF:FullProfileRefresh()
    end

    -- Chat notification
    local raidSize = GetNumGroupMembers()
    local contentName = GetContentDisplayName(contentKey)
    print("|cff00ff00DandersFrames:|r " .. format(L["Auto-profile \"%s\" activated (%s, %d players)"], profile.name or L["Unnamed"], contentName, raidSize))

    -- Update tab override stars
    self:RefreshTabOverrideStars()

    -- A layout going active greys the toolbar Unlock (it gates on IsLayoutActive);
    -- refresh it if the GUI is open so the button state isn't stale.
    if DF.GUI and DF.GUI.UpdateLockButtonState then DF.GUI.UpdateLockButtonState() end
end

-- Remove the active runtime profile overlay
function AutoProfilesUI:RemoveRuntimeProfile()
    if not self.activeRuntimeProfile then return end
    DF:Debug("LAYOUT", "RemoveRuntimeProfile: deactivating \"%s\" (%s)", self.activeRuntimeProfile.name or "?", self.activeRuntimeContentKey or "?")

    -- Clear overlay FIRST so any subsequent refresh reads global settings
    DF.raidOverrides = nil

    -- Clear runtime state
    self.activeRuntimeProfile = nil
    self.activeRuntimeContentKey = nil

    -- Snap frames to base settings immediately so they are never in a
    -- partially-configured state between overlay clear and the caller's refresh
    if not InCombatLockdown() and DF.FullProfileRefresh then
        DF:FullProfileRefresh()
    end

    print("|cff00ff00DandersFrames:|r " .. L["Auto-profile deactivated, using global settings"])
    self:RefreshTabOverrideStars()

    -- A layout deactivating must re-enable the toolbar Unlock — otherwise it stays
    -- greyed and its click wrongly steers to the Auto Layouts page (stuck state).
    if DF.GUI and DF.GUI.UpdateLockButtonState then DF.GUI.UpdateLockButtonState() end
end

-- Write a raid position straight into the ACTIVE layout's override + live overlay,
-- for direct world drags (the permanent mover) that shouldn't open the full editing
-- GUI. Returns true when it handled the write (a layout is active and not being
-- edited) so the caller skips the base write; false otherwise (no layout / editing
-- — the caller writes base, or the editing-preview path captures it on lock).
-- Mirrors what the toolbar Unlock flow persists, minus the snapshot/diff machinery
-- (a single scalar position key needs none — ApplyRuntimeProfile rebuilds the
-- overlay from profile.overrides on the next layout re-eval).
function AutoProfilesUI:SetActiveLayoutRaidPosition(x, y)
    if self:IsEditing() then return false end
    local p = self.activeRuntimeProfile
    if not p then return false end
    p.overrides = p.overrides or {}
    p.overrides.raidAnchorX = x
    p.overrides.raidAnchorY = y
    -- Reflect immediately so GetRaidDB() (overlay view) returns the new value.
    if DF.raidOverrides then
        DF.raidOverrides.raidAnchorX = x
        DF.raidOverrides.raidAnchorY = y
    end
    if DF.UpdateRaidContainerPosition then DF:UpdateRaidContainerPosition() end
    return true
end

-- ============================================================
-- RUNTIME WRITE INTERCEPTION
-- When a user changes a global setting via GUI while an auto-profile
-- overlay is active, the proxy __newindex already writes to the real
-- table. This function tells the caller whether the key is overridden
-- so the GUI can suppress visual refresh (the overlay value stays visible).
-- ============================================================

-- Intercept a GUI control write for an overridden key.
-- The proxy __newindex already wrote the user's value to the real table.
-- For nested keys we also need to update the real sub-table manually.
-- Returns true if the key is overridden (caller should skip frame refresh).
function AutoProfilesUI:HandleRuntimeWrite(key, value)
    if not key then return false end
    -- While EDITING a layout, the write must flow to the normal setter +
    -- SetProfileSetting so it persists into the layout's override (and previews
    -- live). Runtime protection is only for non-editing runtime changes —
    -- otherwise it steals the edit and it's lost on reload (e.g. My Group First).
    -- Mirrors the WrapDB __newindex guard, which also bows out when IsEditing().
    if self:IsEditing() then return false end
    if not self.activeRuntimeProfile or not DF.raidOverrides then return false end

    -- Check if this key (or its parent) is covered by the overlay
    local setIndex, setting = ParsePinnedKey(key)
    if setIndex and setting then
        local pf = DF._realRaidDB.pinnedFrames
        if pf and pf.sets and pf.sets[setIndex] then
            pf.sets[setIndex][setting] = value
        end
        -- Post-decouple, `enabled` is the ONLY layout-overridable pinned key
        -- (PINNED_OVERRIDABLE). Every other pinned setting reads through the
        -- overlay view to the real table, so the value just written IS the live
        -- effective value — the caller must apply/refresh it normally. Treating
        -- the whole pinnedFrames overlay as "overridden" suppressed callbacks
        -- for ALL pinned edits whenever any set had an Enable override.
        local isOverridden = false
        if setting == "enabled" then
            local overlayPF = DF.raidOverrides.pinnedFrames
            local overlaySet = overlayPF and overlayPF.sets and overlayPF.sets[setIndex]
            -- Only sets carrying an enabled override become view PROXIES (with
            -- a metatable); sets without one are the real table by reference.
            isOverridden = overlaySet ~= nil and getmetatable(overlaySet) ~= nil
        end
        DF:Debug("LAYOUT", "HandleRuntimeWrite: pinned key %s — overridden=%s, wrote to real table", key, tostring(isOverridden))
        return isOverridden
    end

    local tableName, index = ParseTableKey(key)
    if tableName and index then
        local tbl = DF._realRaidDB[tableName]
        if type(tbl) == "table" then
            tbl[index] = value
        end
        local isOverridden = DF.raidOverrides[tableName] ~= nil
        DF:Debug("LAYOUT", "HandleRuntimeWrite: table key %s — overridden=%s, wrote to real table", key, tostring(isOverridden))
        return isOverridden
    end

    -- Simple key: write to real table so user changes persist in the global profile
    if DF.raidOverrides[key] ~= nil then
        DF._realRaidDB[key] = value
        DF:Debug("LAYOUT", "HandleRuntimeWrite: %s — overridden, wrote value=%s to global", key, tostring(value))
        return true
    end
    return false
end

-- Check if a setting key is currently overridden by an active runtime profile.
-- Used by the GUI to show visual indicators on overridden controls.
function AutoProfilesUI:IsOverriddenByRuntime(key)
    if not self.activeRuntimeProfile or not DF.raidOverrides then return false end

    local setIndex, setting = ParsePinnedKey(key)
    if setIndex and setting then
        -- Compare the specific setting value in the overlay against _realRaidDB.
        -- The overlay always has a pinnedFrames copy when any layout is active;
        -- only per-setting differences indicate an actual override.
        local overlayPF = DF.raidOverrides.pinnedFrames
        local realPF = DF._realRaidDB and DF._realRaidDB.pinnedFrames
        if not overlayPF or not realPF then return false end
        local overlaySet = overlayPF.sets and overlayPF.sets[setIndex]
        local realSet = realPF.sets and realPF.sets[setIndex]
        if not overlaySet or not realSet then return false end
        return not DeepCompare(overlaySet[setting], realSet[setting])
    end

    local tableName, index = ParseTableKey(key)
    if tableName and index then
        return DF.raidOverrides[tableName] ~= nil
    end

    return DF.raidOverrides[key] ~= nil
end

-- Get the global (baseline) value of an overridden key for display in indicators.
-- With the overlay proxy the real table is always clean, so just read from it.
function AutoProfilesUI:GetRuntimeGlobalValue(key)
    local setIndex, setting = ParsePinnedKey(key)
    if setIndex and setting then
        local pf = DF._realRaidDB and DF._realRaidDB.pinnedFrames
        local sets = pf and pf.sets
        if sets and sets[setIndex] then
            return sets[setIndex][setting]
        end
        return nil
    end

    local tableName, index = ParseTableKey(key)
    if tableName and index then
        local tbl = DF._realRaidDB[tableName]
        if type(tbl) == "table" then
            return tbl[index]
        end
        return nil
    end

    return DF._realRaidDB[key]
end

-- One-shot migration: strip stale "pinnedFrames" direct keys from all profile overrides.
-- These were incorrectly written by the ExitEditing diff scan when a pinned frame was
-- dragged during editing. The key causes the entire pinnedFrames table (including
-- position) to overwrite _realRaidDB on the next EnterEditing, moving the frame.
local dfAutoProfilesMigrated = false
local function MigrateAutoProfileOverrides()
    if dfAutoProfilesMigrated then return end
    dfAutoProfilesMigrated = true

    local autoDb = DF.db and DF.db.raidAutoProfiles
    if not autoDb then return end

    local cleaned = 0
    local contentTypes = { "mythic", "instanced", "openWorld" }
    for _, ct in ipairs(contentTypes) do
        local profiles = autoDb[ct] and autoDb[ct].profiles
        if profiles then
            for _, profile in ipairs(profiles) do
                if profile.overrides and profile.overrides.pinnedFrames ~= nil then
                    profile.overrides.pinnedFrames = nil
                    cleaned = cleaned + 1
                end
            end
        end
        -- Also check single-profile (mythic uses .profile not .profiles)
        local single = autoDb[ct] and autoDb[ct].profile
        if single and single.overrides and single.overrides.pinnedFrames ~= nil then
            single.overrides.pinnedFrames = nil
            cleaned = cleaned + 1
        end
    end

    if cleaned > 0 then
        DF:Debug("LAYOUT", "MigrateAutoProfileOverrides: removed stale pinnedFrames key from %d profile(s)", cleaned)
    end
end

-- Evaluate current content/raid state and apply/remove profiles as needed
function AutoProfilesUI:EvaluateAndApply()
    if not DF.initialized then return end
    if self:IsEditing() then
        DF:Debug("LAYOUT", "EvaluateAndApply: skipped (editing mode)")
        return
    end

    MigrateAutoProfileOverrides()

    -- Cannot modify secure frames during combat — queue for later
    if InCombatLockdown() then
        DF:Debug("LAYOUT", "EvaluateAndApply: in combat, queued for PLAYER_REGEN_ENABLED")
        self.pendingAutoProfileEval = true
        return
    end

    -- Determine what profile should be active
    local newProfile, contentKey = self:GetActiveProfile()
    local oldName = self.activeRuntimeProfile and self.activeRuntimeProfile.name or "none"
    local newName = newProfile and newProfile.name or "none"

    -- No change — same profile (or both nil)
    if newProfile == self.activeRuntimeProfile then
        DF:Debug("LAYOUT", "EvaluateAndApply: no change (active=\"%s\")", oldName)
        return
    end
    if newProfile == nil and self.activeRuntimeProfile == nil then return end

    DF:Debug("LAYOUT", "EvaluateAndApply: switching \"%s\" -> \"%s\"", oldName, newName)
    DF:Debug("RAIDPOS", "AutoProfile SWITCH: \"%s\" -> \"%s\" (raid size=%d)", oldName, newName, GetNumGroupMembers())

    -- Capture whether an old profile was active before clearing state
    local oldWasActive = (self.activeRuntimeProfile ~= nil)

    -- Remove old profile if one was active (clears overlay and state only)
    if self.activeRuntimeProfile then
        self:RemoveRuntimeProfile()
    end

    -- Apply new profile if one matches (sets overlay then calls FullProfileRefresh: 1 refresh)
    if newProfile then
        self:ApplyRuntimeProfile(newProfile, contentKey)
    elseif oldWasActive then
        -- Profile deactivated (profile→none): refresh once with clean global settings
        DF:FullProfileRefresh()
    end
end

-- ============================================================
-- EVENT FRAME & THROTTLE
-- Listens for content/roster changes and triggers evaluation
-- ============================================================

local autoProfileEventFrame = CreateFrame("Frame")
autoProfileEventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
autoProfileEventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
autoProfileEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
autoProfileEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

-- Frame-based throttle: multiple events in the same frame collapse into one evaluation
local autoProfileThrottleFrame = CreateFrame("Frame")
autoProfileThrottleFrame:Hide()
autoProfileThrottleFrame:SetScript("OnUpdate", function(self)
    self:Hide()

    -- Suppress any pending roster update — we process it after overlay is settled
    local rosterPending = DF._rosterThrottleFrame and DF._rosterThrottleFrame:IsShown()
    if rosterPending then
        DF._rosterThrottleFrame:Hide()
    end

    DF:Debug("RAIDPOS", "AutoProfile throttle FIRE: rosterPending=%s combat=%s", tostring(rosterPending), tostring(InCombatLockdown()))

    AutoProfilesUI:EvaluateAndApply()

    -- Now process roster with correct overlay state
    if rosterPending then
        DF:Debug("RAIDPOS", "AutoProfile throttle: running deferred ProcessRosterUpdate after EvaluateAndApply")
        if not InCombatLockdown() then
            DF:ProcessRosterUpdate()
        else
            local raidDb = DF:GetRaidDB()
            if IsInRaid() and not raidDb.raidUseGroups then
                DF.pendingFlatLayoutRefresh = true
            else
                DF.pendingHeaderSettingsApply = true
            end
        end
    end
end)

local function QueueAutoProfileEval()
    autoProfileThrottleFrame:Show()
end

autoProfileEventFrame:SetScript("OnEvent", function(self, event)
    if not DF.initialized then return end
    if event == "PLAYER_REGEN_ENABLED" then
        if AutoProfilesUI.pendingAutoProfileEval then
            DF:Debug("LAYOUT", "Event: %s — processing queued evaluation", event)
            AutoProfilesUI.pendingAutoProfileEval = false
            QueueAutoProfileEval()
        end
        return
    end

    DF:Debug("LAYOUT", "Event: %s — queuing evaluation", event)
    QueueAutoProfileEval()
end)

-- ============================================================
-- PRINT OVERRIDES: /df overrides
-- Shows which settings are overridden, grouped by tab
-- ============================================================

function AutoProfilesUI:PrintOverrides()
    -- Determine which profile to report on
    local profile, source
    if self:IsEditing() then
        profile = self.editingProfile
        source = L["Editing"]
    elseif self.activeRuntimeProfile then
        profile = self.activeRuntimeProfile
        source = L["Runtime"]
    else
        local activeProfile = self:GetActiveProfile()
        if activeProfile then
            profile = activeProfile
            source = L["Matched (not applied)"]
        end
    end

    if not profile then
        print("|cffff8020DandersFrames:|r " .. L["No auto-profile is currently active or being edited."])
        return
    end

    if not profile.overrides or not next(profile.overrides) then
        print("|cffff8020DandersFrames:|r " .. format(L["Profile \"%s\" has no overrides."], profile.name or L["Unnamed"]))
        return
    end

    -- Group by tab (also drives the total, so it matches the deduped display).
    local groups, unknownKeys = GroupOverridesByTab(profile.overrides)

    -- Count total: everything shown (mapped groups + "Other"), deduped.
    local total = CountDisplayedOverrides(profile.overrides)

    print("|cffff8020" .. L["DandersFrames Auto-Profile Overrides:"] .. "|r")
    print("  " .. L["Profile:"] .. " |cffffffff\"" .. (profile.name or L["Unnamed"]) .. "\"|r (" .. source .. ")")
    print("  " .. L["Total:"] .. " |cffffffff" .. format(total > 1 and L["%d overrides"] or L["%d override"], total) .. "|r")

    -- Sort tab IDs for consistent output
    local tabOrder = {}
    for tabId in pairs(groups) do
        tinsert(tabOrder, tabId)
    end
    table.sort(tabOrder)

    -- Global (un-overridden) raid values, to diff table overrides against so only
    -- the changed leaves print — not the whole stored config. While editing, the
    -- live controls write previews into DF._realRaidDB, so the TRUE global lives in
    -- globalSnapshot; diffing against _realRaidDB there would show nothing changed.
    local realRaid = (self:IsEditing() and self.globalSnapshot) or DF._realRaidDB or (DF.db and DF.db.raid)
    local budget = { n = nil }  -- chat scrolls: no line cap (depth-capped only)
    -- Breadcrumb headers (val == nil) print bare; leaves print "key = value".
    local function emitChat(indent, label, val)
        if val == nil then
            print(indent .. label)
        else
            print(indent .. label .. " = |cffffffff" .. val .. "|r")
        end
    end
    local function printKey(key, indentBase)
        local value = profile.overrides[key]
        if type(value) == "table" and not (value.r and value.g and value.b) then
            print(indentBase .. key .. ":")
            WalkOverrideDiff(value, realRaid and realRaid[key], "", indentBase .. "  ", 1, 8, budget, emitChat)
        else
            local displayValue
            if type(value) == "table" then
                displayValue = string.format("|cffffffff(%.2f, %.2f, %.2f)|r", value.r, value.g, value.b)
            elseif type(value) == "boolean" then
                displayValue = value and "|cff00ff00true|r" or "|cffff4444false|r"
            else
                displayValue = "|cffffffff" .. tostring(value) .. "|r"
            end
            print(indentBase .. key .. " = " .. displayValue)
        end
    end

    for _, tabId in ipairs(tabOrder) do
        local group = groups[tabId]
        print("  |cffffaa00" .. group.tabLabel .. "|r (" .. #group.keys .. "):")
        table.sort(group.keys)
        for _, key in ipairs(group.keys) do
            printKey(key, "    ")
        end
    end

    if #unknownKeys > 0 then
        print("  |cff999999" .. L["Other"] .. "|r (" .. #unknownKeys .. "):")
        table.sort(unknownKeys)
        for _, key in ipairs(unknownKeys) do
            printKey(key, "    ")
        end
    end
end

-- ============================================================
-- CLEAR OVERRIDE: /df clearoverride <key|prefix|all>
-- Escape hatch to remove a stuck auto-layout override directly, for cases the
-- normal settings UI can't reach (e.g. a pinned-players override when not in a
-- raid). Targets the layout being edited, else the active/matched one — same
-- resolution as /df overrides.
-- ============================================================
function AutoProfilesUI:ClearOverrideCommand(arg)
    local profile, editing
    if self:IsEditing() then
        profile, editing = self.editingProfile, true
    elseif self.activeRuntimeProfile then
        profile = self.activeRuntimeProfile
    else
        profile = self:GetActiveProfile()
    end

    if not profile or not profile.overrides or not next(profile.overrides) then
        print("|cffff8020DandersFrames:|r " .. L["No auto-profile is currently active or being edited."])
        return
    end

    if not arg or arg == "" then
        print("|cffff8020DandersFrames:|r " .. L["Usage: /df clearoverride <key|prefix|all>  (see /df overrides for keys)"])
        return
    end

    -- Build the list of keys to clear: "all", an exact key, or a prefix match
    -- (case-insensitive). Prefix lets you clear e.g. all "pinned.1." overrides at once.
    local argLower = arg:lower()
    local toClear = {}
    if argLower == "all" then
        for k in pairs(profile.overrides) do toClear[#toClear + 1] = k end
    else
        for k in pairs(profile.overrides) do
            local kl = k:lower()
            if kl == argLower or kl:sub(1, #argLower) == argLower then
                toClear[#toClear + 1] = k
            end
        end
    end

    if #toClear == 0 then
        print("|cffff8020DandersFrames:|r " .. format(L["No override matching \"%s\" on layout \"%s\"."], arg, profile.name or L["Unnamed"]))
        return
    end

    table.sort(toClear)
    for _, k in ipairs(toClear) do
        if editing then
            -- Removes the override AND restores the live preview value to global,
            -- so ExitEditing's diff won't re-store it.
            self:ResetProfileSetting(k)
        else
            profile.overrides[k] = nil
        end
    end

    print("|cff00ff00DandersFrames:|r " .. format(L["Cleared %d override(s) from layout \"%s\":"], #toClear, profile.name or L["Unnamed"]))
    for _, k in ipairs(toClear) do print("    |cffffffff" .. k .. "|r") end

    -- Reflect the change live.
    if editing then
        self:RefreshTabOverrideStars()
        local GUI = DF.GUI
        if GUI and GUI.InvalidateAllPages then GUI:InvalidateAllPages() end
        if GUI and GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
    elseif self.EvaluateAndApply then
        self:EvaluateAndApply()
    end
end

-- ============================================================
-- DEBUG: Auto Profile Detection Test
-- Usage: /dfautotest - Print current detection results
-- ============================================================

SLASH_DFAUTOTEST1 = "/dfautotest"
SlashCmdList["DFAUTOTEST"] = function()
    local autoDb = DF.db and DF.db.raidAutoProfiles
    local enabled = autoDb and autoDb.enabled
    local inRaid = IsInRaid()
    local contentType = DF.GetContentType and DF:GetContentType() or "N/A"
    local raidSize = GetNumGroupMembers()
    
    print("|cffff8020DandersFrames Auto Profile Detection:|r")
    print("  Enabled: " .. (enabled and "|cff00ff00YES|r" or "|cffff4444NO|r"))
    print("  In Raid: " .. (inRaid and "|cff00ff00YES|r" or "|cffff4444NO|r"))
    print("  Content Type: |cffffffff" .. tostring(contentType) .. "|r")
    print("  Raid Size: |cffffffff" .. raidSize .. "|r")
    
    local profile, profileKey = AutoProfilesUI:GetActiveProfile()
    if profile then
        local overrideCount = 0
        if profile.overrides then
            for _ in pairs(profile.overrides) do
                overrideCount = overrideCount + 1
            end
        end
        print("  Active Profile: |cff00ff00\"" .. (profile.name or "Unnamed") .. "\"|r")
        print("  Matched Key: |cffffffff" .. tostring(profileKey) .. "|r")
        if profile.min and profile.max then
            print("  Range: |cffffffff" .. profile.min .. "-" .. profile.max .. " players|r")
        end
        print("  Overrides: |cffffffff" .. overrideCount .. "|r")
    else
        print("  Active Profile: |cff999999None (using global settings)|r")
    end

    -- Runtime state
    print("  --- Runtime State ---")
    local rtProfile = AutoProfilesUI.activeRuntimeProfile
    if rtProfile then
        local rtOverrides = 0
        if rtProfile.overrides then
            for _ in pairs(rtProfile.overrides) do rtOverrides = rtOverrides + 1 end
        end
        local overlayKeys = 0
        if DF.raidOverrides then
            for _ in pairs(DF.raidOverrides) do overlayKeys = overlayKeys + 1 end
        end
        print("  Runtime Profile: |cff00ff00\"" .. (rtProfile.name or "Unnamed") .. "\"|r ("
            .. tostring(AutoProfilesUI.activeRuntimeContentKey) .. ")")
        print("  Applied Overrides: |cffffffff" .. rtOverrides .. "|r, Overlay Keys: |cffffffff" .. overlayKeys .. "|r")
    else
        print("  Runtime Profile: |cff999999None|r")
    end
    print("  Pending Combat Eval: " .. (AutoProfilesUI.pendingAutoProfileEval and "|cffff8020YES|r" or "|cff999999No|r"))
    print("  Editing Mode: " .. (AutoProfilesUI:IsEditing() and "|cffff8020YES|r" or "|cff999999No|r"))

    -- Also list all configured profiles for context
    if autoDb then
        print("  --- Configured Profiles ---")
        for _, ctDef in ipairs(CONTENT_TYPES) do
            local key = ctDef.key
            if key == "mythic" then
                local mp = autoDb.mythic and autoDb.mythic.profile
                if mp then
                    print("  [Mythic] \"" .. (mp.name or "Unnamed") .. "\" (20 fixed)")
                end
            else
                local profiles = autoDb[key] and autoDb[key].profiles or {}
                for _, p in ipairs(profiles) do
                    print("  [" .. ctDef.title .. "] \"" .. p.name .. "\" (" .. p.min .. "-" .. p.max .. ")")
                end
            end
        end
    end
end
