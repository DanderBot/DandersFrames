local _, DF = ...

-- ============================================================
-- AUTO PROFILES - Raid-only automatic profile switching (ENGINE)
--
-- ☠ RESIDENT ON PURPOSE. Profile switching is live behaviour: it must work
-- whether or not the player has ever opened the settings panel. The panel
-- itself is DandersFrames_Options/GUI/Pages/AutoProfiles.lua, which is
-- load-on-demand and holds only the page, the dialogs and the editing banner.
-- The table below is shared: this file owns the state and the runtime, the
-- companion adds the UI methods on top when it loads.
-- ============================================================

local AutoProfilesUI = {}
DF.AutoProfilesUI = AutoProfilesUI

local L = DF.L
local format = string.format

-- Local references

-- ============================================================
-- OVERRIDE KEY LABELS
-- The override tooltip and /df debug overrides both list which settings a layout has
-- overridden. They used to print the RAW saved key -- "auraDesignerPreset",
-- "buffBorderSize" -- so users were shown internal camelCase identifiers. Noise at
-- best, and actively misleading where a key's wording no longer matches the UI:
-- the designer keys still say "preset" ON PURPOSE (they are exported, so renaming
-- them would cost a saved-profile migration to change a name nobody should have
-- been seeing) while the UI now calls those Templates.
--
-- Derived labels can't be translated -- they come from an identifier, not a string
-- table -- but that is no worse than the raw key they replace, and the cases where
-- the wording actually matters are pinned to real locale keys below.
-- ============================================================

-- Prettifying these would be WRONG, not merely ugly.
local KEY_LABEL_OVERRIDES = {
    auraDesignerPreset = "Aura Designer Template",
    textDesignerPreset = "Text Designer Template",
}

-- Initialisms that must not be title-cased into nonsense ("Oor", "Bg", "Dps").
local KEY_ACRONYMS = {
    oor = "OOR", bg = "BG", pvp = "PvP", ui = "UI", hp = "HP",
    dps = "DPS", afk = "AFK", cc = "CC", ad = "AD", td = "TD",
}

local keyLabelCache = {}

local function KeyLabel(key)
    if type(key) ~= "string" then return tostring(key) end
    local cached = keyLabelCache[key]
    if cached then return cached end

    local out
    local override = KEY_LABEL_OVERRIDES[key]
    if override then
        out = L[override] or override
    else
        -- camelCase -> spaced, digits split off, then title-case each word.
        local spaced = key:gsub("(%l)(%u)", "%1 %2"):gsub("(%a)(%d)", "%1 %2")
        local words = {}
        for w in spaced:gmatch("%S+") do
            words[#words + 1] = KEY_ACRONYMS[w:lower()] or (w:sub(1, 1):upper() .. w:sub(2))
        end
        out = table.concat(words, " ")
    end

    keyLabelCache[key] = out
    return out
end

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

-- ☠ Rebuilds IN PLACE. It used to reassign CONTENT_TYPES, which was harmless
-- while everything lived in one file. It is not now: the settings page reads
-- this table from _priv, and a locale refresh reassigning the engine's local
-- would leave the page holding the previous table forever -- stale labels, no
-- error. Keeping the table's identity stable makes any reference safe.
local function RefreshContentTypes()
    local rebuilt = {
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
    wipe(CONTENT_TYPES)
    for i = 1, #rebuilt do
        CONTENT_TYPES[i] = rebuilt[i]
    end
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
    -- colorPicker* are account-wide now, so an auto profile can't override them.
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
    {"missingBuff",         "auras_missingbuffs",   L["Missing Buffs"]},
    {"defensiveIcon",       "auras_defensiveicon",  L["Defensive Icon"]},
    {"debuff",              "auras_debuffs",        L["Debuffs"]},
    {"buff",                "auras_buffs",          L["Buffs"]},
    {"dispel",              "auras_dispel",         L["Dispel Overlay"]},
    {"auraDesigner",        "auras_auradesigner",   L["Aura Designer"]},
    -- Indicators (specific before generic)
    {"personalTargeted",    "indicators_personal_targeted", L["Personal Targeted"]},
    {"targetedList",        "indicators_targetedlist", L["Targeted List"]},
    -- ⚰ DEPRECATED-TARGETED-SPELLS — kept on purpose for now: this row is what
    -- labels an existing profile's stale targetedSpell* overrides. Dropping it
    -- would leave those overrides unattributed rather than making them go away.
    -- It goes when the keys do. See Features\TargetedSpells.lua.
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
-- /df debug overrides so all three agree.
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
            DF:Debug("AUTOPROFILE", "FindMatchingProfile: matched \"%s\" for %s (size %d, range %d-%d)", profile.name or "?", contentKey, raidSize, profile.min, profile.max)
            return profile
        end
    end

    DF:Debug("AUTOPROFILE", "FindMatchingProfile: no match for %s (size %d, %d profiles checked)", contentKey, raidSize, #ct.profiles)
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

    -- ☠ BACKFILL THE CONTENT-TYPE SUB-TABLES TOO. The guard above is presence-only, so a
    -- table that EXISTS but is missing a sub-table sails past it -- and a full profile
    -- import replaces raidAutoProfiles wholesale from the payload, validated only by a
    -- shallow `type(...) == "table"` check. Import a payload without `mythic` and the Auto
    -- Layouts page threw "attempt to index field 'mythic' (a nil value)" the moment it
    -- opened, then again on the next branch.
    --
    -- Runtime was already safe (GetActiveProfile and FindMatchingProfile both guard); this
    -- presented purely as a settings page that could not be opened, with no way back
    -- except re-importing something else.
    local ap = DF.db.raidAutoProfiles
    if type(ap.instanced) ~= "table" then ap.instanced = { profiles = {} } end
    if type(ap.openWorld) ~= "table" then ap.openWorld = { profiles = {} } end
    if type(ap.mythic) ~= "table" then ap.mythic = {} end
    if type(ap.instanced.profiles) ~= "table" then ap.instanced.profiles = {} end
    if type(ap.openWorld.profiles) ~= "table" then ap.openWorld.profiles = {} end

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
    DF:Debug("AUTOPROFILE", "CreateProfile: contentKey=%s name=\"%s\" min=%s max=%s", contentKey, name or "?", tostring(min), tostring(max))

    if contentKey == "mythic" then
        DF.db.raidAutoProfiles.mythic.profile = {
            name = name or "Mythic Setup",
            overrides = {}
        }
        DF:Debug("AUTOPROFILE", "CreateProfile: mythic layout created")
        return true
    end

    -- Check for name conflict
    local profiles = DF.db.raidAutoProfiles[contentKey].profiles
    for _, p in ipairs(profiles) do
        if p.name:lower() == name:lower() then
            DF:DebugWarn("AUTOPROFILE", "CreateProfile: name conflict with \"%s\"", name)
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
            DF:DebugWarn("AUTOPROFILE", "DeleteProfile: index %s not found in %s", tostring(index), contentKey)
            return false
        end
    end

    DF:Debug("AUTOPROFILE", "DeleteProfile: removed \"%s\" from %s", deletedProfile and deletedProfile.name or "?", contentKey)

    -- If the deleted profile was the active runtime profile, deactivate it
    if deletedProfile and self.activeRuntimeProfile == deletedProfile then
        DF:Debug("AUTOPROFILE", "DeleteProfile: deleted layout was active, deactivating overlay")
        DF.raidOverrides = nil
        self.activeRuntimeProfile = nil
        self.activeRuntimeContentKey = nil
        if DF.FullProfileRefresh then
            DF:FullProfileRefresh()
        end
        DF:Say(L["Auto-profile deactivated (profile deleted)"])
    end

    return true
end

-- Update profile range
function AutoProfilesUI:UpdateProfileRange(contentKey, index, newMin, newMax)
    self:InitDefaults()
    DF:Debug("AUTOPROFILE", "UpdateProfileRange: %s index=%s newMin=%d newMax=%d", contentKey, tostring(index), newMin, newMax)

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
        DF:DebugWarn("AUTOPROFILE", "UpdateProfileRange: overlap with \"%s\" (%d-%d)", overlap.name, overlap.min, overlap.max)
        return false, format(L["Overlaps with \"%s\""], overlap.name)
    end

    local oldMin, oldMax = profiles[index].min, profiles[index].max
    profiles[index].min = newMin
    profiles[index].max = newMax
    DF:Debug("AUTOPROFILE", "UpdateProfileRange: \"%s\" range %d-%d -> %d-%d", profiles[index].name or "?", oldMin, oldMax, newMin, newMax)

    -- Re-sort
    table.sort(profiles, function(a, b) return a.min < b.min end)

    return true
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
    DF:Debug("AUTOPROFILE", "EnterEditing: contentType=%s profileIndex=%s", contentType, tostring(profileIndex))

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
            DF:DebugWarn("AUTOPROFILE", "EnterEditing: refused — only the active layout is editable in a raid group")
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
            DF:Say((msg or ""))
            local GUI = DF.GUI
            if GUI and GUI.RefreshCurrentPage then GUI:RefreshCurrentPage() end
            return false, "Blocked: live raid frames"
        end
    end

    -- Clear overlay so snapshot captures true globals (no RemoveRuntimeProfile
    -- needed — real table was never mutated)
    if self.activeRuntimeProfile then
        DF:Debug("AUTOPROFILE", "EnterEditing: clearing active runtime overlay before snapshot")
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
            DF:DebugWarn("AUTOPROFILE", "EnterEditing: profile not found at index %s", tostring(profileIndex))
            return false, "Profile not found"
        end
    end
    
    self.editingContentType = contentType
    DF:Debug("AUTOPROFILE", "EnterEditing: editing \"%s\" (%s)", self.editingProfile.name or "?", contentType)

    -- Snapshot ALL true global values before anything gets modified
    -- This lets controls freely write to DF._realRaidDB for live preview while
    -- SetProfileSetting/GetGlobalValue always know the original globals
    self.globalSnapshot = {}
    for key, value in pairs(DF._realRaidDB) do
        self.globalSnapshot[key] = DeepCopyValue(value)
    end
    -- ☠ REMEMBER WHOSE DATA THIS SNAPSHOT IS. ExitEditing reads DF._realRaidDB at CALL
    -- time, and DF:SetProfile re-points that global -- so a profile switch mid-edit (spec
    -- change -> CheckProfileAutoSwitch -> SetProfile) left the exit diff comparing the NEW
    -- profile's table against the OLD profile's snapshot: the orphan sweep nils every key
    -- the old profile lacked, and the restore loop stamps old values over the new profile.
    -- SetProfile clears the runtime overlay but never calls ExitEditing, and ExitEditing's
    -- own guard is only `if self.editingProfile and self.globalSnapshot`.
    self.globalSnapshotOwner = DandersFramesDB_v2 and DandersFramesDB_v2.currentProfile or "Default"

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
    
    -- ☠ PERSIST THE VALUES, NOT JUST THE KEY NAMES.
    --
    -- EnterEditing writes every stored override straight into the REAL serialized raid
    -- table (SetRaidValue -> DF._realRaidDB, which IS
    -- DandersFramesDB_v2.profiles[current].raid). The user's true globals live only in
    -- the in-memory self.globalSnapshot. There is NO PLAYER_LOGOUT handler anywhere in
    -- either addon -- verified, zero hits -- so a /reload or a crash mid-edit saves the
    -- PREVIEW as the user's real settings.
    --
    -- This used to persist only the key NAMES, so the recovery pass on next login could
    -- do nothing better than DF.db.raid[key] = DF.RaidDefaults[key]: a user whose raid
    -- frameWidth was 150, editing a layout that overrides it to 110, got the FACTORY 125
    -- back and a message saying settings were recovered. Persisting the values makes the
    -- recovery exact.
    --
    -- Snapshot values are already deep-copied by DeepCopyValue above, so this is a plain
    -- reference to data we own; it is dropped in ExitEditing along with the flag.
    local recoveryKeys, recoveryValues = {}, {}
    for key, value in pairs(self.globalSnapshot) do
        recoveryKeys[#recoveryKeys + 1] = key
        recoveryValues[key] = value
    end
    DF.db.raidAutoEditingRecovery = {
        contentType = contentType,
        profileIndex = profileIndex,
        snapshotKeys = recoveryKeys,
        -- Keys whose true global value was nil are absent here (Lua cannot store a nil
        -- value), which is why snapshotKeys is still the authoritative list to walk.
        snapshotValues = recoveryValues,
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
                DF:DebugWarn("AUTOPROFILE", "EnterEditing: skipping stale pinnedFrames direct override key")
            elseif not IsKeyOverridable(key) then
                -- transient/never-override key (e.g. a stale raidLocked) — don't
                -- apply it to the live preview (ExitEditing self-heals it away).
                DF:DebugWarn("AUTOPROFILE", "EnterEditing: skipping non-overridable override \"%s\"", key)
            else
                SetRaidValue(key, DeepCopyValue(value))
                overrideCount = overrideCount + 1
            end
        end
    end
    DF:Debug("AUTOPROFILE", "EnterEditing: applied %d overrides for live preview", overrideCount)

    -- ☠☠ THE OVERRIDES JUST BYPASSED EVERY GUI CALLBACK, SO NOTHING BUMPED THE AURA
    -- LAYOUT VERSION. The row drives are version-gated (dfBuffFactoryVersion /
    -- dfDebuffFactoryVersion / dfDefFactoryVersion / dfMissingFactoryVersion vs
    -- DF.auraLayoutVersion) and re-apply sizing, spacing and counts ONLY on a bump --
    -- normally supplied by the settings control that changed the value. These writes
    -- come straight from the stored overrides, so the drives saw an unchanged version
    -- and skipped: an auto layout carrying a smaller debuffSize opened with the GLOBAL
    -- icon size still on the preview frames, and only nudging that slider in the editor
    -- (LightweightUpdateAuraPosition -> InvalidateAuraLayout) made it take
    -- (Krathe, 2026-08-25).
    --
    -- ⚠ EXITING was never affected, which is why this looked one-way: ExitEditing calls
    -- DF:UpdateAll, which invalidates. Only the entry lacked it.
    -- InvalidateAuraLayout also runs the test-mode passes itself, so the preview picks
    -- the new values up here rather than waiting for RefreshTestFramesWithLayout below;
    -- it is combat-safe (RefreshFactoryRows re-queues at regen) and cheap when nothing
    -- moved (every drive is signature-gated under the version gate).
    if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end

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
    DF:Debug("AUTOPROFILE", "ExitEditing: profile=\"%s\" skipUIUpdates=%s", self.editingProfile and self.editingProfile.name or "?", tostring(skipUIUpdates))

    -- Diff safety net: before restoring globals, scan live values vs snapshot
    -- to catch any overrides that weren't explicitly tracked by controls
    -- ☠ ONLY DIFF AGAINST THE PROFILE THE SNAPSHOT CAME FROM. DF._realRaidDB is read
    -- fresh below, and DF:SetProfile re-points it -- so if the profile changed while this
    -- layout was being edited (a spec change routes through CheckProfileAutoSwitch ->
    -- SetProfile), the sweep would nil every key of the NEW profile that the OLD one
    -- lacked, and the restore loop would stamp the old profile's values over it. Data loss
    -- on a profile the user never opened.
    --
    -- The edit itself is abandoned in that case: its snapshot describes data no longer
    -- loaded, so there is nothing safe to diff or restore. Say so rather than skipping
    -- quietly -- an abandoned edit looks identical to a saved one from the outside.
    local snapOwner = self.globalSnapshotOwner
    local liveOwner = DandersFramesDB_v2 and DandersFramesDB_v2.currentProfile or "Default"
    if self.globalSnapshot and snapOwner and snapOwner ~= liveOwner then
        DF:DebugWarn("AUTOPROFILE", "ExitEditing: profile changed during editing (%s -> %s); abandoning the diff rather than writing one profile's values into another", tostring(snapOwner), tostring(liveOwner))
        -- Drop ONLY the diff/restore inputs, then FALL THROUGH to the shared exit
        -- tail: every block below is nil-guarded on globalSnapshot, so nothing from
        -- the stale edit can be written -- but the editing-state clears, the
        -- crash-recovery flag, the sidebar hint, the override stars and
        -- EvaluateAndApply still run. An early return here skipped them all,
        -- leaving the GUI wearing editing chrome for an edit that no longer existed.
        -- ⚠ Restoring the snapshot into the SOURCE profile by name is possible (it
        -- still exists in DandersFramesDB_v2.profiles) and deliberately NOT done:
        -- a cross-profile write is the exact hazard this guard exists to stop, and
        -- doing it safely against the raw table is its own change.
        self.editingProfile = nil
        self.globalSnapshot = nil
        self.globalSnapshotOwner = nil
    end

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
                    DF:DebugWarn("AUTOPROFILE", "ExitEditing: removed stale pinnedFrames direct override key")
                end
            elseif not IsKeyOverridable(key) then
                -- Transient/never-override key (e.g. raidLocked) — never store it,
                -- and self-heal any override an earlier build captured.
                if overrides[key] ~= nil then
                    overrides[key] = nil
                    autoCleaned = autoCleaned + 1
                    DF:DebugWarn("AUTOPROFILE", "ExitEditing: removed non-overridable override \"%s\"", key)
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
                        DF:DebugWarn("AUTOPROFILE", "ExitEditing: removed redundant whole-table override \"%s\" (tracked via flat keys)", key)
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
        DF:Debug("AUTOPROFILE", "ExitEditing: diff scan — autoStored=%d autoCleaned=%d orphansRemoved=%d totalOverrides=%d", autoStored, autoCleaned, orphansRemoved, totalOverrides)
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
    -- Cleared with its snapshot: a stale owner would make the NEXT edit session compare
    -- against the wrong profile name if EnterEditing ever failed to set it.
    self.globalSnapshotOwner = nil

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
-- OVERRIDE SYSTEM FUNCTIONS
-- ============================================================

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
    -- ☠ THE FALLBACK BELOW READS BACK THE CONTROL'S OWN WRITE. Every control writes
    -- dbTable[dbKey] BEFORE calling this (Controls.lua), so for a key absent from the
    -- snapshot -- one that was nil on the profile when editing began -- GetRaidValue
    -- returns the value we are being asked to compare, valuesMatch is trivially true, and
    -- the override is DELETED. The change could never be recorded, and ExitEditing's
    -- orphan sweep then stripped it from the profile too: the setting vanished from both.
    --
    -- Absent from the snapshot means "no global value to match", so nothing can equal it.
    -- Treat it as a genuine difference and let the override be stored.
    local globalValue, found = GetSnapshotValue(self.globalSnapshot, key)
    if not found then
        local newValue = value
        if newValue ~= nil then
            self.editingProfile.overrides[key] = DeepCopyValue(newValue)
            DF:Debug("AUTOPROFILE", "SetProfileSetting: %s absent from snapshot -- stored as an override (no global to compare against)", key)
            return true
        end
        globalValue = GetRaidValue(key)
    end

    -- Compare values (recursive deep compare handles nested tables like colors)
    local valuesMatch = DeepCompare(value, globalValue)

    if valuesMatch then
        -- Same as global, remove override
        self.editingProfile.overrides[key] = nil
        DF:Debug("AUTOPROFILE", "SetProfileSetting: %s matches global, override removed", key)
    else
        -- Different from global, store override (deep copy to avoid reference issues)
        self.editingProfile.overrides[key] = DeepCopyValue(value)
        DF:Debug("AUTOPROFILE", "SetProfileSetting: %s overridden (value=%s)", key, tostring(value))
    end

    -- Refresh tab stars so they update live as settings change
    self:RefreshTabOverrideStars()

    return true
end

-- Reset a setting to global (remove override)
function AutoProfilesUI:ResetProfileSetting(key)
    if not self.editingProfile then return false end
    DF:Debug("AUTOPROFILE", "ResetProfileSetting: %s — restoring to global", key)

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
        DF:Debug("AUTOPROFILE", "GetActiveProfile: disabled or no autoDb")
        return nil
    end

    -- Must be in a raid group for auto-profiles to apply
    if not IsInRaid() then
        DF:Debug("AUTOPROFILE", "GetActiveProfile: not in raid")
        return nil
    end

    -- Use the existing content type detection from Core.lua
    local contentType = DF:GetContentType()
    if not contentType then
        DF:Debug("AUTOPROFILE", "GetActiveProfile: no content type detected")
        return nil
    end

    local raidSize = GetNumGroupMembers()
    DF:Debug("AUTOPROFILE", "GetActiveProfile: contentType=%s raidSize=%d", contentType, raidSize)

    -- Mythic: single profile, no range check needed
    if contentType == "mythic" then
        local mythicProfile = autoDb.mythic and autoDb.mythic.profile
        if mythicProfile then
            DF:Debug("AUTOPROFILE", "GetActiveProfile: matched mythic layout \"%s\"", mythicProfile.name or "?")
            return mythicProfile, "mythic"
        end
        DF:Debug("AUTOPROFILE", "GetActiveProfile: mythic content but no layout configured")
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
        DF:Debug("AUTOPROFILE", "GetActiveProfile: unmapped content type \"%s\", no layout", contentType)
        return nil
    end

    -- Find matching profile by raid size within the content type
    local profile = FindMatchingProfile(profileKey, raidSize)
    if profile then
        return profile, profileKey
    end

    DF:Debug("AUTOPROFILE", "GetActiveProfile: no matching range for %s (size %d)", profileKey, raidSize)
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
    DF:Debug("AUTOPROFILE", "ApplyRuntimeProfile: \"%s\" (%s)", profile.name or "?", contentKey)

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

    -- Table keys: a LIVE VIEW of the real parent, not a deep copy — the same
    -- treatment the pinned block below already got, and for the same reason.
    --
    -- ☠ THE DEEP COPY FROZE THE SIBLINGS. An override is per INDEX
    -- ("raidGroupVisible_1"), but the copy snapshotted the whole parent table at
    -- activation. So with group 1 overridden, groups 2-8 were served from a stale
    -- snapshot for as long as the layout stayed active: untick group 3 on the Options
    -- page and the write reached the real table, but every read still came off the
    -- copy, so the checkbox sprang back and the frames never changed until the layout
    -- switched. Only the OVERRIDDEN indices should be frozen; the rest must read live.
    --
    -- Overridden indices are rawset on the view, so they shadow __index — and
    -- __newindex never fires for them, exactly as with pinned `enabled`: their value
    -- stays view-local while HandleRuntimeWrite persists edits to the global.
    -- Everything else falls through to the real table for reads AND writes.
    --
    -- ⚠ `rawget(view, index) ~= nil` is now THE test for "is this index overridden",
    -- used by both HandleRuntimeWrite and IsOverriddenByRuntime. Those two used to ask
    -- `DF.raidOverrides[tableName] ~= nil`, which answered for the whole table and so
    -- reported all eight groups overridden whenever any one of them was.
    --
    -- ⚠ pairs() on the view enumerates only the overridden indices. Safe here because
    -- every consumer indexes numerically (BuildGroupFilter's `for i = 1, 8`, the header
    -- and test-mode group loops) and export reads _realProfile, never the overlay.
    for tableName, indices in pairs(tableGroups) do
        local realParent = DF._realRaidDB[tableName]
        local view = {}
        for index, value in pairs(indices) do
            view[index] = DeepCopyValue(value)
        end
        if type(realParent) == "table" then
            overlay[tableName] = setmetatable(view, {
                __index = realParent,
                __newindex = function(_, key, value)
                    realParent[key] = value
                end,
            })
        else
            -- Nothing to read through to; the overrides are the whole table.
            overlay[tableName] = view
        end
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
    DF:Debug("AUTOPROFILE", "ApplyRuntimeProfile: overlay active — %d overrides, %d overlay keys", totalOverrides, overlayCount)

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
    DF:Say(format(L["Auto-profile \"%s\" activated (%s, %d players)"], profile.name or L["Unnamed"], contentName, raidSize))

    -- Update tab override stars
    self:RefreshTabOverrideStars()

    -- A layout going active greys the toolbar Unlock (it gates on IsLayoutActive);
    -- refresh it if the GUI is open so the button state isn't stale.
    if DF.GUI and DF.GUI.UpdateLockButtonState then DF.GUI.UpdateLockButtonState() end
end

-- Remove the active runtime profile overlay
function AutoProfilesUI:RemoveRuntimeProfile()
    if not self.activeRuntimeProfile then return end
    DF:Debug("AUTOPROFILE", "RemoveRuntimeProfile: deactivating \"%s\" (%s)", self.activeRuntimeProfile.name or "?", self.activeRuntimeContentKey or "?")

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

    DF:Say(L["Auto-profile deactivated, using global settings"])
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
        -- Same correction as the table-key branch below: the write at :1825 is inside
        -- `if pf and pf.sets and pf.sets[setIndex]`, so claiming it unconditionally
        -- misreported the exact case worth seeing -- a pinned set that is not there.
        DF:Debug("AUTOPROFILE", "HandleRuntimeWrite: pinned key %s — overridden=%s, wrote=%s",
            key, tostring(isOverridden),
            tostring(pf ~= nil and pf.sets ~= nil and pf.sets[setIndex] ~= nil))
        return isOverridden
    end

    local tableName, index = ParseTableKey(key)
    if tableName and index then
        local tbl = DF._realRaidDB[tableName]
        if type(tbl) == "table" then
            tbl[index] = value
        end
        -- ☠ PER INDEX, not per table. This asked `DF.raidOverrides[tableName] ~= nil`,
        -- which is true when ANY index of the table is overridden -- so overriding
        -- group 1 made edits to groups 2-8 return true as well, and the caller then
        -- treated a perfectly ordinary edit as override-blocked: value written to the
        -- global only, live overlay untouched, override indicator shown on a control
        -- that carries no override. Overridden indices are the ones rawset on the
        -- overlay view (see ApplyRuntimeProfile); everything else reads through.
        local overlayTbl = DF.raidOverrides[tableName]
        local isOverridden = type(overlayTbl) == "table" and rawget(overlayTbl, index) ~= nil
        -- ☠ REPORT THE WRITE, DO NOT ASSERT IT. This said "wrote to real table"
        -- unconditionally, while the write above sits inside `if type(tbl) == "table"` --
        -- so on the one path worth debugging, the table being absent, the log claimed a
        -- write that never happened. A line that lies about its failure case is worse
        -- than no line: it sends the reader straight past the fault.
        DF:Debug("AUTOPROFILE", "HandleRuntimeWrite: table key %s — overridden=%s, wrote=%s",
            key, tostring(isOverridden), tostring(type(tbl) == "table"))
        return isOverridden
    end

    -- Simple key: write to real table so user changes persist in the global profile
    if DF.raidOverrides[key] ~= nil then
        DF._realRaidDB[key] = value
        DF:Debug("AUTOPROFILE", "HandleRuntimeWrite: %s — overridden, wrote value=%s to global", key, tostring(value))
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
        -- Per index, matching HandleRuntimeWrite — see the note there. Table-presence
        -- lit the override indicator on every sibling control.
        local overlayTbl = DF.raidOverrides[tableName]
        return type(overlayTbl) == "table" and rawget(overlayTbl, index) ~= nil
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
-- ☠ PER PROFILE, NOT PER SESSION. This was gated by a file-scope
-- `local dfAutoProfilesMigrated`, so the FIRST EvaluateAndApply after login migrated the
-- login profile and every later call -- including the one after each DF:SetProfile --
-- returned immediately. Any other profile's stale overrides.pinnedFrames keys were never
-- stripped, in that session or in any future one where that profile was not the login
-- profile: a migration that could only ever reach one profile per install.
--
-- The flag now lives on the raidAutoProfiles table it cleans, which is per-profile.
-- Every sibling migration in this file is already per-profile
-- (prof._legacyTextOverrideCleanupV1, ap.nonOverridableCleanupDone); this one never got
-- the same treatment.
local function MigrateAutoProfileOverrides()
    local autoDb = DF.db and DF.db.raidAutoProfiles
    if not autoDb then return end
    if autoDb._overrideCleanupV1 then return end
    autoDb._overrideCleanupV1 = true

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
        DF:Debug("AUTOPROFILE", "MigrateAutoProfileOverrides: removed stale pinnedFrames key from %d profile(s)", cleaned)
    end
end

-- Evaluate current content/raid state and apply/remove profiles as needed
function AutoProfilesUI:EvaluateAndApply()
    if not DF.initialized then return end
    if self:IsEditing() then
        DF:Debug("AUTOPROFILE", "EvaluateAndApply: skipped (editing mode)")
        return
    end

    MigrateAutoProfileOverrides()

    -- Cannot modify secure frames during combat — queue for later
    if InCombatLockdown() then
        DF:Debug("AUTOPROFILE", "EvaluateAndApply: in combat, queued for PLAYER_REGEN_ENABLED")
        self.pendingAutoProfileEval = true
        return
    end

    -- Determine what profile should be active
    local newProfile, contentKey = self:GetActiveProfile()
    local oldName = self.activeRuntimeProfile and self.activeRuntimeProfile.name or "none"
    local newName = newProfile and newProfile.name or "none"

    -- No change — same profile (or both nil)
    if newProfile == self.activeRuntimeProfile then
        DF:Debug("AUTOPROFILE", "EvaluateAndApply: no change (active=\"%s\")", oldName)
        return
    end
    if newProfile == nil and self.activeRuntimeProfile == nil then return end

    DF:Debug("AUTOPROFILE", "EvaluateAndApply: switching \"%s\" -> \"%s\"", oldName, newName)
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
            DF:Debug("AUTOPROFILE", "Event: %s — processing queued evaluation", event)
            AutoProfilesUI.pendingAutoProfileEval = false
            QueueAutoProfileEval()
        end
        return
    end

    DF:Debug("AUTOPROFILE", "Event: %s — queuing evaluation", event)
    QueueAutoProfileEval()
end)

-- ============================================================
-- PRINT OVERRIDES: /df debug overrides
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
        DF:Say(L["No auto-profile is currently active or being edited."])
        return
    end

    if not profile.overrides or not next(profile.overrides) then
        DF:Say(format(L["Profile \"%s\" has no overrides."], profile.name or L["Unnamed"]))
        return
    end

    -- Group by tab (also drives the total, so it matches the deduped display).
    local groups, unknownKeys = GroupOverridesByTab(profile.overrides)

    -- Count total: everything shown (mapped groups + "Other"), deduped.
    local total = CountDisplayedOverrides(profile.overrides)

    local o = DF:Out(L["Auto-Profile Overrides"])
    o:Field(L["Profile:"], "\"" .. (profile.name or L["Unnamed"]) .. "\" (" .. source .. ")")
    o:Field(L["Total:"], format(total > 1 and L["%d overrides"] or L["%d override"], total))

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
    -- Chat is the DIAGNOSTIC surface -- people paste it for support -- so it shows
    -- the readable label AND the raw saved key, unlike the tooltip which shows the
    -- label alone.
    local function chatKey(key)
        local label = KeyLabel(key)
        if label == key then return key end
        return label .. " |cff808080(" .. key .. ")|r"
    end
    local function printKey(key, indentBase)
        local value = profile.overrides[key]
        if type(value) == "table" and not (value.r and value.g and value.b) then
            print(indentBase .. chatKey(key) .. ":")
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
            print(indentBase .. chatKey(key) .. " = " .. displayValue)
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
-- resolution as /df debug overrides.
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
        DF:Say(L["No auto-profile is currently active or being edited."])
        return
    end

    if not arg or arg == "" then
        DF:Say(L["Usage: /df clearoverride <key|prefix|all>  (see /df debug overrides for keys)"])
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
        DF:Say(format(L["No override matching \"%s\" on layout \"%s\"."], arg, profile.name or L["Unnamed"]))
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

    local o = DF:Out("Auto Profiles", format(L["Cleared %d override(s) from layout \"%s\":"], #toClear, profile.name or L["Unnamed"]))
    o:More(toClear, 10)

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
-- Usage: /df debug autotest - Print current detection results
-- ⚠ NOT /dfautotest. RegisterDebugSlash does not create a SLASH_* global for a
-- /df-prefixed alias, so that spelling is not typeable. Same correction /dfarena
-- already carries in Core.lua.
-- ============================================================

DF:RegisterDebugSlash("DFAUTOTEST", "Auto profiles test harness", true, "/dfautotest")
SlashCmdList["DFAUTOTEST"] = function()
    local autoDb = DF.db and DF.db.raidAutoProfiles
    local enabled = autoDb and autoDb.enabled
    local inRaid = IsInRaid()
    local contentType = DF.GetContentType and DF:GetContentType() or "N/A"
    local raidSize = GetNumGroupMembers()
    
    local o = DF:Out("Auto Profiles", "detection")
    -- "Not in a raid" is the normal state outside one, so it reads NEUTRAL. Only
    -- the feature being switched off is worth flagging, and only as a warning.
    o:Field("Enabled", enabled and "yes" or "no", enabled and "good" or "warn")
    o:Field("In raid", inRaid and "yes" or "no", inRaid and "good" or "neutral")
    o:Field("Content type", contentType)
    o:Field("Raid size", raidSize)

    local profile, profileKey = AutoProfilesUI:GetActiveProfile()
    o:Section("Active profile")
    if profile then
        local overrideCount = 0
        if profile.overrides then
            for _ in pairs(profile.overrides) do
                overrideCount = overrideCount + 1
            end
        end
        o:Field("Name", profile.name or "Unnamed", "good")
        o:Field("Matched key", profileKey)
        if profile.min and profile.max then
            o:Field("Range", profile.min .. "-" .. profile.max .. " players")
        end
        o:Field("Overrides", overrideCount)
    else
        o:Line("none - using global settings", "neutral")
    end

    o:Section("Runtime state")
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
        o:Field("Runtime profile", (rtProfile.name or "Unnamed")
            .. " (" .. tostring(AutoProfilesUI.activeRuntimeContentKey) .. ")", "good")
        o:Field("Applied overrides", rtOverrides)
        o:Field("Overlay keys", overlayKeys)
    else
        o:Field("Runtime profile", "none", "neutral")
    end
    -- A deferred evaluation is a WARN: settings the user expects are not applied yet.
    o:Field("Pending combat eval", AutoProfilesUI.pendingAutoProfileEval and "yes" or "no",
        AutoProfilesUI.pendingAutoProfileEval and "warn" or "neutral")
    o:Field("Editing mode", AutoProfilesUI:IsEditing() and "yes" or "no",
        AutoProfilesUI:IsEditing() and "warn" or "neutral")

    -- Also list all configured profiles for context
    if autoDb then
        local configured = {}
        for _, ctDef in ipairs(CONTENT_TYPES) do
            local key = ctDef.key
            if key == "mythic" then
                local mp = autoDb.mythic and autoDb.mythic.profile
                if mp then
                    configured[#configured + 1] = { "Mythic", (mp.name or "Unnamed") .. " (20 fixed)" }
                end
            else
                local profiles = autoDb[key] and autoDb[key].profiles or {}
                for _, p in ipairs(profiles) do
                    configured[#configured + 1] = { ctDef.title, p.name .. " (" .. p.min .. "-" .. p.max .. ")" }
                end
            end
        end
        o:Section("Configured profiles", #configured)
        for _, row in ipairs(configured) do
            o:Item(row[1], row[2])
        end
    end
end

-- ============================================================
-- SETTINGS-PAGE HOOKS
-- ============================================================
-- These four repaint parts of the settings panel. The engine calls them on
-- every override change and every runtime profile switch -- both of which
-- happen with the panel unloaded, and none of the 11 call sites is guarded.
-- Defining them as no-ops here is what lets those call sites stay untouched;
-- the companion overwrites all four with the real versions when it loads.
--
-- Written out one by one rather than generated in a loop so that grep and
-- lod_gate_check.py can both see them, same as TestMode/Shim.lua.
function AutoProfilesUI:RefreshEditingUI() end
function AutoProfilesUI:RefreshTabOverrideStars() end
function AutoProfilesUI:ShowSidebarHint() end
function AutoProfilesUI:HideSidebarHint() end

-- ============================================================
-- SHARED WITH THE SETTINGS PAGE
-- ============================================================
-- The page is a separate addon and cannot see this file's locals. Publish the
-- seven it needs. All are read-only from here on -- CONTENT_TYPES is rebuilt
-- in place precisely so this reference stays valid across a locale refresh.
local P = {}
AutoProfilesUI._priv = P
P.CONTENT_TYPES = CONTENT_TYPES
P.CountDisplayedOverrides = CountDisplayedOverrides
P.DeepCopyValue = DeepCopyValue
P.GetOverrideTabId = GetOverrideTabId
P.GroupOverridesByTab = GroupOverridesByTab
P.KeyLabel = KeyLabel
P.WalkOverrideDiff = WalkOverrideDiff
