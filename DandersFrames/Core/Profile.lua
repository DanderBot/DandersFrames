local addonName, DF = ...

local format = string.format

-- ============================================================
-- HELPER: DEEP COPY TABLE
-- ============================================================

-- ☠ CYCLE-GUARDED. `seen` maps an already-copied source table to its copy, so a table
-- that references itself (or any loop) terminates and -- just as importantly -- shared
-- subtables stay shared in the copy instead of being duplicated per reference.
--
-- This was plain unguarded recursion, and Core/API.lua already named "DF:DeepCopy (no
-- cycle guard)" as a live throw source without the fix ever reaching the function.
-- LibSerialize explicitly supports table self-reference, so a crafted or simply unlucky
-- import payload survives ValidatePayloadShape (deliberately shallow) and then stack-
-- overflows here. Both import callers pcall, so it was recoverable -- but a stack
-- overflow inside a pcall is a poor way to reject a payload.
--
-- `seen` is threaded as a second parameter rather than allocated per recursive call, so
-- one table is created per top-level DeepCopy and nothing changes for the common case.
-- ⚠ Callers pass one argument. Do not make `seen` a required parameter.
function DF:DeepCopy(src, seen)
    if type(src) ~= "table" then return src end
    -- Unwrap proxy tables to their real backing store
    local mt = getmetatable(src)
    if mt then
        if mt.__isDBProxy then src = DF._realProfile end
        if mt.__realTable then src = mt.__realTable end
    end
    seen = seen or {}
    if seen[src] then return seen[src] end
    local dest = {}
    seen[src] = dest
    for k, v in pairs(src) do
        dest[k] = DF:DeepCopy(v, seen)
    end
    return dest
end

-- ============================================================
-- SETTINGS-WINDOW STATE (ACCOUNT-WIDE, NOT PROFILE CONTENT)
-- ============================================================
-- Scale, size and position of the settings window are machine state, not
-- settings -- ExportCategories has declared them local-only for as long as
-- exports have existed. They used to be STORED in db.party anyway, which meant
-- a profile carried them: a freshly created profile is born from PartyDefaults,
-- so its guiScale was 1 while the already-open window kept the old scale. The
-- Test Mode and Unlock windows re-read the db on every OnShow, so they snapped
-- to 100% and only the UI Scale slider (the single writer) could put them back
-- in step. Holding the state account-wide is what actually enforces the
-- declared intent -- switching or creating a profile can no longer move,
-- resize or rescale the window out from under the user.
--
-- Fields: scale, width, height, point, relPoint, x, y. All optional; every
-- reader supplies its own fallback.
function DF:GetWindowState()
    if not DandersFramesDB_v2 then DandersFramesDB_v2 = {} end
    local ws = DandersFramesDB_v2.windowState
    if not ws then
        ws = {}
        DandersFramesDB_v2.windowState = ws
    end
    return ws
end

-- ============================================================
-- PROFILE MANAGEMENT
-- ============================================================

-- Resets Party or Raid settings within the CURRENT profile
function DF:ResetProfile(mode)
    local L = DF.L
    if not DF.db or not DF.db[mode] then return end
    local defaults = (mode == "party" and DF.PartyDefaults or DF.RaidDefaults)
    -- ☠ THE UNDO STACK IS FENCED HERE. DF.db[mode] is about to be REPLACED, so
    -- every entry holding a reference to the outgoing table would undo into a
    -- table nothing reads any more -- silently, since the write itself succeeds.
    local SU = DF.SettingsUndo
    if SU then SU:Clear() end
    DF.db[mode] = DF:DeepCopy(defaults)
    DF:FullProfileRefresh()
    local modeLabel = mode == "party" and "Party" or "Raid"
    DF:Say(format(L["%s settings reset to defaults."], modeLabel))
end

-- Full profile reset: both modes PLUS the profile-level designer preset
-- libraries. DF:ResetProfile only replaces DF.db[mode]; the Aura/Text Designer
-- store their configs in the shared, profile-level auraDesignerPresets/
-- textDesignerPresets libraries, which those per-mode resets never touch — so
-- without this, edited AD/TD presets survive a "Reset Profile to Defaults".
-- Used by the GUI "Reset Profile to Defaults" button and /df reset.
function DF:ResetFullProfile()
    -- ★ UNLINK FIRST. Party/Raid sync state lives at the PROFILE ROOT, so neither
    -- per-mode ResetProfile reached it and a "Reset Profile to Defaults" left every
    -- synced page still synced — a state a freshly created profile can never be in
    -- (Profile.lua seeds linkedSections = {}), which is the yardstick for this function.
    -- ⚠ BEFORE the mode resets, not after: each ResetProfile ends in FullProfileRefresh,
    -- which runs DF:SyncLinkedSections. Clearing afterwards would let three refreshes
    -- fire against link state we are about to discard.
    -- `{}` rather than nil to match the fresh-profile shape exactly; readers are
    -- nil-guarded either way.
    DF.db.linkedSections = {}
    -- Fenced HERE as well as inside the two ResetProfile calls below, and not
    -- redundantly: this function also discards profile-ROOT tables the per-mode
    -- resets never reach (the designer preset libraries, the filter overrides),
    -- so the stack is stale from this line onwards rather than from the first
    -- mode reset. Clear is idempotent, so the overlap costs nothing.
    local SU = DF.SettingsUndo
    if SU then SU:Clear() end
    self:ResetProfile("party")
    self:ResetProfile("raid")
    if self.ResetDesignerPresets then self:ResetDesignerPresets() end
    -- Filter Designer per-spell preset overrides live at profile root
    -- (DF.db.filterPresetOverrides), like the AD/TD preset libraries above —
    -- neither per-mode ResetProfile nor ResetDesignerPresets touches them.
    -- filterMutedSpellIDs is its sibling (per-spell-ID narrowing within a record)
    -- and travels with it everywhere: reset, export, payload keys, new-profile
    -- copy, import.
    DF.db.filterPresetOverrides = nil
    DF.db.filterMutedSpellIDs = nil
    -- FullProfileRefresh re-applies the Aura Designer engine to live frames
    -- (Core.lua), so the reset AD presets take effect immediately. It does NOT
    -- touch the Text Designer, so nudge that separately below.
    self:FullProfileRefresh()
    if DF.TextDesigner and DF.TextDesigner.Preview and DF.TextDesigner.Preview.RefreshAll then
        DF.TextDesigner.Preview:RefreshAll()
    end
end

-- Copies Party->Raid or Raid->Party within CURRENT profile
function DF:CopyProfile(srcMode, destMode)
    local L = DF.L
    if not DF.db or not DF.db[srcMode] or not DF.db[destMode] then return end
    DF.db[destMode] = DF:DeepCopy(DF.db[srcMode])
    DF:FullProfileRefresh()
    local s = srcMode == "party" and "Party" or "Raid"
    local d = destMode == "party" and "Party" or "Raid"
    DF:Say(format(L["Copied settings from %s to %s."], s, d))
end

-- ============================================================
-- SECTION KEY OWNERSHIP (longest-match-wins)
-- Shared matcher for section Copy/Reset/Sync. A db key can string-match
-- prefixes registered by several pages (e.g. "debuffFilterBoss" matches the
-- Debuffs layout page's "debuff" AND the Aura Filters page's "debuffFilter").
-- Ownership goes to the page holding the LONGEST matching prefix across the
-- whole SectionRegistry, so overlapping registrations don't copy/reset each
-- other's keys. Two pages registering the IDENTICAL prefix would tie — that's
-- a registration bug; in a tie both pages keep the key (legacy behaviour).
-- ============================================================

-- Returns true if `key` belongs to the section registered with `prefixes`.
function DF:SectionOwnsKey(prefixes, key)
    -- Longest matching prefix within this section
    local own = 0
    for _, prefix in ipairs(prefixes) do
        if #prefix > own and key:sub(1, #prefix) == prefix then
            own = #prefix
        end
    end
    if own == 0 then return false end

    -- Any registered section with a STRICTLY longer matching prefix wins
    -- instead. (Scanning this section's own registry entry is harmless: its
    -- matches can never exceed `own`.)
    for _, otherPrefixes in pairs(DF.SectionRegistry or {}) do
        for _, prefix in ipairs(otherPrefixes) do
            if #prefix > own and key:sub(1, #prefix) == prefix then
                return false
            end
        end
    end
    return true
end

-- Copies matching settings between Party and Raid (no refresh, no print)
-- Used by SyncLinkedSections for automatic background syncing
function DF:CopySectionSettingsRaw(prefixes, srcMode)
    if not DF.db then return end
    srcMode = srcMode or "party"
    local destMode = srcMode == "party" and "raid" or "party"
    if not DF.db[srcMode] or not DF.db[destMode] then return end

    -- Unwrap proxy for iteration (Lua 5.1 has no __pairs)
    local src = DF.db[srcMode]
    local mt = getmetatable(src)
    if mt and mt.__realTable then src = mt.__realTable end

    for key, value in pairs(src) do
        if DF:SectionOwnsKey(prefixes, key) then
            if type(value) == "table" then
                DF.db[destMode][key] = DF:DeepCopy(value)
            else
                DF.db[destMode][key] = value
            end
        end
    end
end

-- Copies a specific section of settings between Party and Raid modes
-- prefixes: table of string prefixes to match, e.g. {"buff", "debuff"}
-- srcMode: optional, the source mode ("party" or "raid"). If not provided, defaults to "party"
-- Returns: srcMode, destMode (for UI feedback)
function DF:CopySectionSettings(prefixes, srcMode)
    if not DF.db then return end
    
    -- Determine current mode and destination
    srcMode = srcMode or "party"
    local destMode = srcMode == "party" and "raid" or "party"
    
    if not DF.db[srcMode] or not DF.db[destMode] then return end

    -- Unwrap proxy for iteration (Lua 5.1 has no __pairs)
    local src = DF.db[srcMode]
    local mt = getmetatable(src)
    if mt and mt.__realTable then src = mt.__realTable end

    local count = 0
    for key, value in pairs(src) do
        if DF:SectionOwnsKey(prefixes, key) then
            -- Deep copy if table, otherwise direct assign
            if type(value) == "table" then
                DF.db[destMode][key] = DF:DeepCopy(value)
            else
                DF.db[destMode][key] = value
            end
            count = count + 1
        end
    end

    -- Full refresh - these buttons aren't used often so a complete refresh is fine
    DF:FullProfileRefresh()

    local L = DF.L
    local s = srcMode == "party" and "Party" or "Raid"
    local d = destMode == "party" and "Party" or "Raid"
    DF:Say(format(L["Copied %d settings from %s to %s."], count, s, d))

    return srcMode, destMode
end

-- Resets a section of settings to their built-in defaults for a single mode.
-- prefixes: same key-prefix array used by Copy/Sync, e.g. {"healthColor", ...}
-- mode: "party" or "raid". Only the given mode is touched unless this section
-- is currently Synced (linkedSections), in which case the other mode is mirrored
-- so they stay in sync.
function DF:ResetSectionSettings(prefixes, mode)
    if not DF.db then return end
    mode = mode or "party"
    if not DF.db[mode] then return end

    local defaults = (mode == "party") and DF.PartyDefaults or DF.RaidDefaults
    if not defaults then return end

    -- Unwrap proxy for iteration (Lua 5.1 has no __pairs)
    local src = DF.db[mode]
    local mt = getmetatable(src)
    if mt and mt.__realTable then src = mt.__realTable end

    local count = 0
    -- Snapshot keys first — mutating during iteration with prefixes-not-in-defaults
    -- would otherwise be unsafe.
    local keys = {}
    for key in pairs(src) do keys[#keys + 1] = key end

    for _, key in ipairs(keys) do
        if DF:SectionOwnsKey(prefixes, key) then
            local defaultVal = defaults[key]
            if defaultVal == nil then
                -- Key has no default; clear it so the migration system can
                -- backfill cleanly on next load.
                DF.db[mode][key] = nil
            elseif type(defaultVal) == "table" then
                DF.db[mode][key] = DF:DeepCopy(defaultVal)
            else
                DF.db[mode][key] = defaultVal
            end
            count = count + 1
        end
    end

    -- If this section is currently Synced, mirror the reset to the other mode.
    if DF.db.linkedSections then
        for pageId, prefixesForPage in pairs(DF.SectionRegistry or {}) do
            if DF.db.linkedSections[pageId] and prefixesForPage == prefixes then
                DF:CopySectionSettingsRaw(prefixes, mode)
                break
            end
        end
    end

    DF:FullProfileRefresh()

    local L = DF.L
    local m = (mode == "party") and "Party" or "Raid"
    DF:Say(format(L["Reset %d %s settings to defaults."], count, m))

    return count
end

-- ============================================================
-- PROFILE LIST MANAGEMENT
-- ============================================================

-- Get list of all profile names
function DF:GetProfiles()
    local profiles = {"Default"}
    if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
        for name, _ in pairs(DandersFramesDB_v2.profiles) do
            if name ~= "Default" then
                table.insert(profiles, name)
            end
        end
    end
    table.sort(profiles, function(a, b)
        if a == "Default" then return true end
        if b == "Default" then return false end
        return a < b
    end)
    return profiles
end

-- Get current profile name
function DF:GetCurrentProfile()
    return DandersFramesDB_v2 and DandersFramesDB_v2.currentProfile or "Default"
end

-- Save the current profile to the profiles table.
-- DeepCopy unwraps the overlay proxy, so saved data is always clean.
function DF:SaveCurrentProfile()
    if not DF.db then return end
    local currentName = DandersFramesDB_v2 and DandersFramesDB_v2.currentProfile or "Default"
    if not DandersFramesDB_v2 or not DandersFramesDB_v2.profiles then return end

    DandersFramesDB_v2.profiles[currentName] = DF:DeepCopy(DF.db)
end

-- Set/create a profile
function DF:SetProfile(name)
    local L = DF.L
    if not name or name == "" then return end

    -- Initialize profiles table if needed
    if not DandersFramesDB_v2 then DandersFramesDB_v2 = {} end
    if not DandersFramesDB_v2.profiles then DandersFramesDB_v2.profiles = {} end

    -- Save current profile before switching (strips runtime overrides)
    DF:SaveCurrentProfile()

    -- Clear auto-profile runtime state and overlay BEFORE switching profiles
    -- so FullProfileRefresh reads the clean new profile with no stale overlay
    if DF.AutoProfilesUI then
        DF.AutoProfilesUI.activeRuntimeProfile = nil
        DF.AutoProfilesUI.activeRuntimeContentKey = nil
        DF.AutoProfilesUI.pendingAutoProfileEval = false
    end
    DF.raidOverrides = nil
    -- ...and the undo stack with them. Every entry names a table inside the
    -- profile being left behind, so an undo pressed after the switch would write
    -- a value into settings the user is no longer looking at.
    local SU = DF.SettingsUndo
    if SU then SU:Clear() end
    -- Clear the Global Fonts temp selection so the page re-initialises from
    -- the new profile's font settings rather than showing the old profile's
    -- last-used font until the next /reload.
    DF.GlobalFontTemp = nil
    DF:Debug("PROFILE", "SetProfile: cleared runtime state before switching to " .. name)

    -- Create new profile if doesn't exist
    if not DandersFramesDB_v2.profiles[name] then
        DandersFramesDB_v2.profiles[name] = {
            party = DF:DeepCopy(DF.PartyDefaults),
            raid = DF:DeepCopy(DF.RaidDefaults),
            raidAutoProfiles = DF:DeepCopy(DF.RaidAutoProfilesDefaults),
            classColors = {},
            powerColors = {},
            linkedSections = {},
            partyEnabled = true,
            raidEnabled = true,
            -- Must match the CURRENT default (and the nil-backfill just below).
            -- Seeding the pre-Roboto face here meant a freshly created profile kept
            -- Friz -- the backfill skips a non-nil value -- until the
            -- _settingsFontRobotoDefaultV1 migration flipped it on the next reload,
            -- so the settings font appeared to change by itself.
            settingsFont = "DF Roboto SemiBold",
            settingsFontOutline = "NONE",
        }
        -- Born from current defaults => every one-time migration is already done.
        -- Without this, the unconditional frame-level / container-position shifts
        -- fired on the new profile and moved values that were already correct.
        DF:StampFreshProfileMigrations(DandersFramesDB_v2.profiles[name])
        DF:Say(format(L["Created new profile: %s"], name))
    end

    -- Backfill defaults on older profiles
    local p = DandersFramesDB_v2.profiles[name]
    if p.partyEnabled        == nil then p.partyEnabled        = true end
    if p.raidEnabled         == nil then p.raidEnabled         = true end
    if p.settingsFont        == nil then p.settingsFont        = "DF Roboto SemiBold" end
    if p.settingsFontOutline == nil or p.settingsFontOutline == "" then p.settingsFontOutline = "NONE" end

    -- Switch to the profile (update both account-wide and per-character)
    DandersFramesDB_v2.currentProfile = name
    if DandersFramesCharDB then
        DandersFramesCharDB.currentProfile = name
    end
    DF.db = DandersFramesDB_v2.profiles[name]
    DF:WrapDB()

    -- Run the one-time legacy → Text Designer migration for this profile.
    -- Login only migrates the login-active profile, so any other profile must
    -- be migrated when it's first activated — otherwise its TD elements stay
    -- empty and enabling TD renders nothing. Per-profile guard makes this a
    -- no-op for already-migrated / user-built profiles. Runs before the refresh
    -- so the migrated elements render immediately.
    -- Designer Presets: migrate this profile's inline auraDesigner/textDesigner
    -- (party/raid + raid auto-layout overrides) into the named preset library.
    -- Per-profile guard makes this a no-op for already-migrated profiles. Runs
    -- BEFORE the TD-legacy migration so that migration builds its elements into
    -- the presets (its guard flag then persists, avoiding a rebuild-then-discard
    -- on later profile switches).
    if DF.MigrateDesignerPresets then
        DF:MigrateDesignerPresets()
    end

    if DF.MigrateTargetedSpellImportantBorder then
        DF:MigrateTargetedSpellImportantBorder()
    end

    if DF.MigrateTextDesignerFromLegacy then
        DF:MigrateTextDesignerFromLegacy()
    end
    -- One-time cleanup of stray health text the pre-fix migration injected onto
    -- profiles that had health text off (idempotent, self-guarded).
    if DF.CorrectStrayMigratedHealthText then
        DF:CorrectStrayMigratedHealthText()
    end

    -- Strip orphaned legacy text overrides from raid auto-layouts now that TD
    -- owns the built-in text (gated on migratedFromLegacy inside).
    if DF.CleanupLegacyTextLayoutOverrides then
        DF:CleanupLegacyTextLayoutOverrides()
    end

    -- Appearance-preserving border migration (per-profile guarded, no-op once run).
    if DF.MigrateBorderInsetFold then
        DF:MigrateBorderInsetFold()
    end
    if DF.MigrateOORTextAlpha then
        DF:MigrateOORTextAlpha()
    end
    if DF.MigrateHealthColorStops then
        DF:MigrateHealthColorStops()
    end
    if DF.MigrateHealPredictionBelowAbsorb then
        DF:MigrateHealPredictionBelowAbsorb()
    end
    if DF.MigrateRaidCenterMode then
        DF:MigrateRaidCenterMode()
    end

    -- ☠ The dispel palette is a PROCESS-LIFETIME cache, so it does not follow DF.db.
    -- DF.debuffBorderCurve and DF.dispelColorMap are built once and reused; without this
    -- the new profile renders the OLD profile's dispel colours, and because the generation
    -- never moves, no carrier is ever re-bound to correct it -- wrong colours until a
    -- reload. Worse when the incoming profile's dispelColors is partial or absent: the
    -- curve rebuilds from a different source than the one the map was cached from, so the
    -- two disagree. Must run BEFORE the refresh so the rebuild reads the new profile.
    if DF.InvalidateDispelColorCurve then DF:InvalidateDispelColorCurve() end

    -- Apply the profile — runtime state is already clear so the proxy reads
    -- the new profile directly with no stale overlay
    DF:FullProfileRefresh()

    -- ★ THE COMPLETION MARKER. PROFILE logged the START of a switch and nothing else, with
    -- eleven one-time migrations and a full refresh running in between -- so a log showing
    -- "cleared runtime state before switching" and then nothing was indistinguishable from
    -- a switch that half-applied and threw. That is precisely the failure worth catching
    -- here, and it was the one state the category could not describe.
    DF:Debug("PROFILE", "SetProfile: switch to %s complete", tostring(name))

    DF:Say(format(L["Switched to profile: %s"], name))

    -- If the new profile has a different enable-flag state, prompt to reload
    -- so headers can be (re)created. Frames cannot be added/removed at runtime.
    if DF.PromptReloadIfEnableFlagsChanged then
        DF:PromptReloadIfEnableFlagsChanged()
    end

    -- Re-evaluate auto-profiles for the new profile after a short delay
    -- to allow secure frame operations to settle
    C_Timer.After(0.1, function()
        if DF.AutoProfilesUI then
            DF.AutoProfilesUI:EvaluateAndApply()
        end
    end)
end

-- Delete a profile
function DF:DeleteProfile(name)
    local L = DF.L
    if name == "Default" then
        DF:Err(L["Cannot delete Default profile."])
        return
    end

    if DandersFramesDB_v2 and DandersFramesDB_v2.profiles and DandersFramesDB_v2.profiles[name] then
        DandersFramesDB_v2.profiles[name] = nil
        DF:Say(format(L["Deleted profile: %s"], name))
    end
end

-- Duplicate current profile to a new name
function DF:DuplicateProfile(newName)
    local L = DF.L
    if not newName or newName == "" then
        DF:Err(L["Please enter a profile name."])
        return false
    end

    local currentName = DandersFramesDB_v2 and DandersFramesDB_v2.currentProfile or "Default"

    -- Initialize profiles table if needed
    if not DandersFramesDB_v2 then DandersFramesDB_v2 = {} end
    if not DandersFramesDB_v2.profiles then DandersFramesDB_v2.profiles = {} end

    -- Check if profile already exists
    if DandersFramesDB_v2.profiles[newName] then
        DF:Err(format(L["Profile '%s' already exists."], newName))
        return false
    end
    
    -- Save current profile before switching
    DF:SaveCurrentProfile()

    -- Create new profile as a clean copy of current (DeepCopy unwraps proxies)
    DandersFramesDB_v2.profiles[newName] = DF:DeepCopy(DF.db)

    -- Switch to the new profile
    DandersFramesDB_v2.currentProfile = newName
    if DandersFramesCharDB then
        DandersFramesCharDB.currentProfile = newName
    end
    DF.db = DandersFramesDB_v2.profiles[newName]
    DF:WrapDB()

    -- Apply the profile with full refresh
    DF:FullProfileRefresh()
    
    DF:Say(format(L["Duplicated profile '%s' to '%s'."], currentName, newName))
    return true
end

-- ============================================================
-- BASE64 ENCODING/DECODING
-- ============================================================

local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

function DF:Base64Decode(data)
    data = string.gsub(data, '[^'..b64chars..'=]', '')
    return (data:gsub('.', function(x)
        if (x == '=') then return '' end
        local r,f='', (b64chars:find(x)-1)
        for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
        return r;
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if (#x ~= 8) then return '' end
        local c=0
        for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
        return string.char(c)
    end))
end

-- ============================================================
-- SERIALIZATION
-- ============================================================

function DF:Serialize(val)
    local t = type(val)
    if t == "number" or t == "boolean" then
        return tostring(val)
    elseif t == "string" then
        return string.format("%q", val)
    elseif t == "table" then
        local str = "{"
        for k, v in pairs(val) do
            str = str .. "[" .. DF:Serialize(k) .. "]=" .. DF:Serialize(v) .. ","
        end
        return str .. "}"
    else
        return "nil"
    end
end

-- ============================================================
-- IMPORT / EXPORT (Using LibSerialize + LibDeflate like modern addons)
-- ============================================================

-- Export profile with optional category filtering
-- Strip GUI-internal flags from an already-deep-copied table before
-- serialization. ONLY the known UI wart (_skipOverrideIndicators, set on
-- bound designer tables by the editor) — other underscore keys are migration
-- markers (_specScopedV1, …) the receiver must keep or it would re-migrate.
local function StripInternalKeys(t)
    if type(t) ~= "table" then return t end
    t._skipOverrideIndicators = nil
    for _, v in pairs(t) do
        if type(v) == "table" then
            StripInternalKeys(v)
        end
    end
    return t
end

-- Embed the aura filter registry payload: the profile's preset overrides
-- (profile-root diffs) plus a snapshot of the account-wide custom filters
-- the exported payload actually references — from the mode selection tables
-- AND from Aura Designer filter groups inside the exported preset libraries.
-- Must run AFTER exportData.auraDesignerPresets is attached (when it rides).
-- includeOverrides: the overrides table only travels with the auras category
-- (its import-side replace semantics are auras-gated too).
local function EmbedCustomFilterData(exportData, includeOverrides)
    -- The overrides table is ALWAYS embedded when the auras category is in
    -- the export — even when empty. Import uses replace semantics
    -- (matching the aura blacklist), so an exporter on stock presets must
    -- carry an explicit {} for the importer to clear its local preset tweaks;
    -- omitting the key would keep them and render the rows differently than
    -- on the exporter's screen.
    if includeOverrides then
        exportData.filterPresetOverrides = DF:DeepCopy(DF.db.filterPresetOverrides or {})
        -- Same replace semantics, same reason: an exporter who has narrowed no
        -- records must carry an explicit {} so the importer's own narrowing is
        -- cleared and the bar renders what the exporter saw.
        exportData.filterMutedSpellIDs = DF:DeepCopy(DF.db.filterMutedSpellIDs or {})
    end
    local refs = {}
    local function collectSel(sel)
        if type(sel) == "table" and type(sel.customs) == "table" then
            for cfId in pairs(sel.customs) do refs[cfId] = true end
        end
    end
    local function collectRefs(mode)
        if type(mode) ~= "table" then return end
        collectSel(mode.buffFilterSelection)
        collectSel(mode.defensiveFilterSelection)
    end
    collectRefs(exportData.party)
    collectRefs(exportData.raid)
    -- Raid auto-layout overrides carry whole-table copies of the mode
    -- selection tables (including .customs) — a filter referenced ONLY by a
    -- layout override must still ride the export, or the receiver's layout
    -- points at a filter that never arrives and its row renders nothing.
    -- Runs on exportData.raidAutoProfiles, which is attached before this
    -- embed in both the full and selective export paths.
    local function collectLayout(layout)
        local ov = type(layout) == "table" and layout.overrides
        if type(ov) == "table" then
            collectSel(ov.buffFilterSelection)
            collectSel(ov.defensiveFilterSelection)
        end
    end
    if type(exportData.raidAutoProfiles) == "table" then
        for _, ct in pairs(exportData.raidAutoProfiles) do
            if type(ct) == "table" then
                if type(ct.profiles) == "table" then
                    for _, layout in pairs(ct.profiles) do collectLayout(layout) end
                end
                collectLayout(ct.profile)   -- mythic carries a single layout
            end
        end
    end
    -- Aura Designer filter groups link custom filters via
    -- group.filterSelection.customs. layoutGroups is spec-keyed post-V2
    -- ({ [specKey] = {groups} }) but old preset data may still carry the
    -- legacy flat array — walk both shapes (same dispatch as the
    -- FilterRegistry delete scrub).
    local function collectGroupArray(groups)
        for _, g in ipairs(groups) do
            if type(g) == "table" then collectSel(g.filterSelection) end
        end
    end
    if type(exportData.auraDesignerPresets) == "table" then
        for _, preset in pairs(exportData.auraDesignerPresets) do
            local lg = type(preset) == "table" and preset.layoutGroups
            if type(lg) == "table" then
                if lg[1] ~= nil then collectGroupArray(lg) end
                for k, v in pairs(lg) do
                    if type(k) == "string" and type(v) == "table" then
                        collectGroupArray(v)
                    end
                end
            end
            -- Other Buffs layout groups: flat array only (spec-independent
            -- store — no dual-shape dispatch needed).
            local olg = type(preset) == "table" and preset.otherLayoutGroups
            if type(olg) == "table" then collectGroupArray(olg) end
            -- Aura Designer effects reference custom filters TWO more ways: a
            -- filter-owned effect is stored under the "@custom:<id>" aura key, and any
            -- effect can list one as a TRIGGER. Both are plain strings rather than a
            -- selection table, so collectSel never sees them — miss these and the
            -- filter doesn't ride the export, and the receiver's effect silently binds
            -- to whatever filter happens to hold that id.
            local function collectAuraRefs(auraName, auraCfg)
                local kind, key = DF:ParseADFilterRef(auraName)
                if kind == "custom" then refs[key] = true end
                if type(auraCfg) ~= "table" then return end
                for _, typeCfg in pairs(auraCfg) do
                    if type(typeCfg) == "table" then
                        if type(typeCfg.triggers) == "table" then
                            for _, t in ipairs(typeCfg.triggers) do
                                local tk, tkey = DF:ParseADFilterRef(t)
                                if tk == "custom" then refs[tkey] = true end
                            end
                        end
                        -- ☠ CONDITION-GROUP TRIGGERS ARE A THIRD STORE. An effect's
                        -- conditions live at typeCfg.conditions.groups[i].triggers -- the
                        -- editor writes them, the Factory reads them, and this walk saw
                        -- neither. A filter used only as a second condition group's
                        -- trigger did not ride the export, and on import its id was never
                        -- remapped, so the receiver's condition bound to whatever local
                        -- filter happened to hold that id.
                        local conds = typeCfg.conditions
                        if type(conds) == "table" and type(conds.groups) == "table" then
                            for _, grp in pairs(conds.groups) do
                                if type(grp) == "table" and type(grp.triggers) == "table" then
                                    for _, t in ipairs(grp.triggers) do
                                        local tk, tkey = DF:ParseADFilterRef(t)
                                        if tk == "custom" then refs[tkey] = true end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            local function collectAuraStore(store)
                if type(store) ~= "table" then return end
                for k, v in pairs(store) do collectAuraRefs(k, v) end
            end
            if type(preset) == "table" then
                -- ☠ DISPATCH ON SHAPE, do not assume it. `auras` is spec-keyed post-V2
                -- ({ [specKey] = { [name] = cfg } }) but the spec-scope migration runs
                -- LAZILY per adDB, so a preset in the library that has never been rendered
                -- on this build still holds the legacy FLAT store ({ [name] = cfg }).
                -- Walking that as spec-keyed skips the aura-name level entirely, which
                -- makes every @custom: owner key and trigger inside it invisible.
                -- layoutGroups above already dispatches this way (`lg[1] ~= nil`); auras
                -- asserted its shape in a comment and never tested it.
                --
                -- The probe: a spec bucket's values are aura CONFIG tables keyed by name,
                -- so a flat store's values are configs too -- distinguish by whether the
                -- value looks like a config (has any of the config-level keys) rather than
                -- a bucket of configs.
                local function looksLikeAuraConfig(v)
                    if type(v) ~= "table" then return false end
                    return v.priority ~= nil or v.indicators ~= nil or v.border ~= nil
                end
                if type(preset.auras) == "table" then
                    local flat = false
                    for _, v in pairs(preset.auras) do
                        if looksLikeAuraConfig(v) then flat = true end
                        break
                    end
                    if flat then
                        collectAuraStore(preset.auras)
                    else
                        for _, specAuras in pairs(preset.auras) do collectAuraStore(specAuras) end
                    end
                end
                collectAuraStore(preset.otherAuras)
            end
        end
    end
    if next(refs) and DF.FilterRegistry then
        -- ReadStore: exporting is a question, not a change. GetStore materialises the
        -- account-wide table, and DandersFrames_Export is a public API that a third-party
        -- addon can call on a user who has never created a custom filter.
        local store = (DF.FilterRegistry.ReadStore and DF.FilterRegistry:ReadStore())
            or DF.FilterRegistry:GetStore()
        for cfId in pairs(refs) do
            if store.customFilters[cfId] then
                exportData.customAuraFilters = exportData.customAuraFilters or {}
                exportData.customAuraFilters[cfId] = DF:DeepCopy(store.customFilters[cfId])
            end
        end
    end
end

-- ☠ PROFILE-ROOT SCALARS -- the same blind spot as the colour tables, one level up.
-- These are per-profile and user-visible, but they live at the DB ROOT rather than inside
-- party/raid, so ExtractCategorySettings never sees them and DF:AuditExportCategories is
-- structurally blind to them (it walks PartyDefaults/RaidDefaults only). Before this list
-- they travelled in NEITHER direction: a shared profile arrived carrying the sender's
-- layout but the RECIPIENT's module toggles and settings font.
--
-- ⚠ COPY AND APPLY BY PRESENCE, NEVER BY TRUTHINESS. partyEnabled/raidEnabled are booleans
-- where FALSE is the meaningful value and ABSENT means enabled (see DF.db.partyEnabled
-- ~= false everywhere), so a `if DF.db[k] then` copy would silently drop exactly the
-- setting worth carrying. Same reason fontSlug is `~= nil` below.
--
-- Anything added at the profile root has to be wired in here by hand.
local PROFILE_ROOT_SCALARS = {
    "partyEnabled", "raidEnabled",
    "settingsFont", "settingsFontOutline", "fontSlug",
}

local function CopyProfileRootScalars(exportData)
    if not DF.db then return end
    for _, key in ipairs(PROFILE_ROOT_SCALARS) do
        if DF.db[key] ~= nil then exportData[key] = DF.db[key] end
    end
end

-- ⚠ Declared HERE, beside the export half, and NOT next to its caller further down --
-- a local declared after the function that references it resolves as a nil GLOBAL,
-- which parses clean and only errors when the import actually runs.
--
-- Types are already checked by ValidatePayloadShape; this only decides presence.
-- Changing partyEnabled/raidEnabled needs a reload to create or destroy the headers,
-- and ApplyImportedProfile already ends with DF:PromptReloadIfEnableFlagsChanged().
local function ApplyProfileRootScalars(importData)
    if not DF.db then return end
    for _, key in ipairs(PROFILE_ROOT_SCALARS) do
        if importData[key] ~= nil then DF.db[key] = importData[key] end
    end
end

function DF:ExportProfile(categories, frameTypes, profileName)
    local L = DF.L
    -- Selective export reads the category tables, which live in the companion
    -- (~85 KB only import/export ever touches). Export is a deliberate user
    -- action, so load them; a FULL export (categories == nil, the shape the
    -- external DandersFrames_Export API uses) never needs them -- don't make
    -- Wago pack exports pay for the panel.
    if categories and not DF.ExportCategories and DF.EnsureOptionsLoaded then
        if not DF:EnsureOptionsLoaded() then return nil end
    end
    local LibSerialize = LibStub and LibStub("LibSerialize", true)
    local LibDeflate = LibStub and LibStub("LibDeflate", true)

    if not LibSerialize or not LibDeflate then
        DF:Err("Missing required libraries")
        return nil
    end
    
    frameTypes = frameTypes or {party = true, raid = true}
    
    -- Get profile name
    local exportProfileName = profileName
    if not exportProfileName then
        if DandersFramesDB_v2 and DandersFramesDB_v2.currentProfile then
            exportProfileName = DandersFramesDB_v2.currentProfile
        else
            exportProfileName = "Exported Profile"
        end
    end
    
    -- Build export data
    -- ☠ No exportTime / exportedBy. Both were written on every export and parsed back
    -- into GetImportInfo, and NOTHING ever read either one -- so exportedBy only ever
    -- stamped the exporter's character name into a string built to be shared publicly.
    local exportData = {
        version = DF.VERSION,
        profileName = exportProfileName,
    }
    
    if not DF.db then
        DF:Err("No database")
        return nil
    end
    
    -- If no categories specified, export everything
    if not categories or #categories == 0 then
        if frameTypes.party and DF.db.party then
            exportData.party = DF:DeepCopy(DF.db.party)
        end
        if frameTypes.raid and DF.db.raid then
            exportData.raid = DF:DeepCopy(DF.db.raid)
        end
        -- Include class color overrides
        if DF.db.classColors and next(DF.db.classColors) then
            exportData.classColors = DF:DeepCopy(DF.db.classColors)
        end
        -- Include power color overrides
        if DF.db.powerColors and next(DF.db.powerColors) then
            exportData.powerColors = DF:DeepCopy(DF.db.powerColors)
        end
        -- Include role colours (profile-root since MigrateRoleBorderColors;
        -- without this the Colors page's role set never travelled)
        if DF.db.roleColors and next(DF.db.roleColors) then
            exportData.roleColors = DF:DeepCopy(DF.db.roleColors)
        end
        -- Include dispel colours — same story as roleColors above. This is the
        -- Colors page's dispel palette and the single source of truth for BOTH the
        -- debuff-icon border and the dispel overlay, but it lives at the profile
        -- root, so /df debug exportaudit (which only walks party/raid) could never see it
        -- was missing: a shared profile arrived with stock dispel colours.
        if DF.db.dispelColors and next(DF.db.dispelColors) then
            exportData.dispelColors = DF:DeepCopy(DF.db.dispelColors)
        end
        -- Include auto layout profiles
        if DF.db.raidAutoProfiles then
            exportData.raidAutoProfiles = DF:DeepCopy(DF.db.raidAutoProfiles)
        end
        -- Include aura blacklist
        if DF.db.auraBlacklist then
            exportData.auraBlacklist = DF:DeepCopy(DF.db.auraBlacklist)
        end
        -- Include the designer preset LIBRARIES (profile-root). Post-migration
        -- the mode tables only carry preset NAME strings — without the
        -- libraries the receiver's refs dangle and all AD/TD content is lost.
        if DF.db.auraDesignerPresets then
            exportData.auraDesignerPresets = StripInternalKeys(DF:DeepCopy(DF.db.auraDesignerPresets))
        end
        if DF.db.textDesignerPresets then
            exportData.textDesignerPresets = StripInternalKeys(DF:DeepCopy(DF.db.textDesignerPresets))
        end
        -- Include filter preset overrides + referenced custom filters. AFTER
        -- the preset libraries so AD filter-group links are collected too.
        EmbedCustomFilterData(exportData, true)
        -- Party/raid section-sync flags (profile-root, page-keyed)
        if DF.db.linkedSections and next(DF.db.linkedSections) then
            exportData.linkedSections = DF:DeepCopy(DF.db.linkedSections)
        end
        CopyProfileRootScalars(exportData)
        exportData.categories = nil
    else
        -- Selective category export
        exportData.categories = categories
        if frameTypes.party and DF.db.party then
            exportData.party = self:ExtractCategorySettings(DF.db.party, categories)
        end
        if frameTypes.raid and DF.db.raid then
            exportData.raid = self:ExtractCategorySettings(DF.db.raid, categories)
        end
        -- Auto layouts: top-level key, needs special handling
        local categorySet = {}
        for _, cat in ipairs(categories) do categorySet[cat] = true end
        if categorySet.autoLayout and DF.db.raidAutoProfiles then
            exportData.raidAutoProfiles = DF:DeepCopy(DF.db.raidAutoProfiles)
        end
        -- Aura blacklist: top-level key, include with auras category
        if categorySet.auras and DF.db.auraBlacklist then
            exportData.auraBlacklist = DF:DeepCopy(DF.db.auraBlacklist)
        end
        -- Designer preset libraries: travel with their own categories (the
        -- mode tables only carry preset NAME refs). autoLayout AND pinnedFrames
        -- also pull both in — their overrides/sets reference presets by name.
        if (categorySet.auraDesigner or categorySet.autoLayout or categorySet.pinnedFrames) and DF.db.auraDesignerPresets then
            exportData.auraDesignerPresets = StripInternalKeys(DF:DeepCopy(DF.db.auraDesignerPresets))
        end
        if (categorySet.textDesigner or categorySet.text or categorySet.autoLayout or categorySet.pinnedFrames) and DF.db.textDesignerPresets then
            exportData.textDesignerPresets = StripInternalKeys(DF:DeepCopy(DF.db.textDesignerPresets))
        end
        -- Filter preset overrides + referenced custom filters: top-level keys.
        -- Overrides travel with the auras category only (the selection tables
        -- that reference them are in the auras key list); custom-filter
        -- snapshots also travel whenever the AD preset library rode the export
        -- — its filter groups can link customs regardless of the auras
        -- category. AFTER the preset attach above so those links are seen.
        if categorySet.auras or exportData.auraDesignerPresets then
            EmbedCustomFilterData(exportData, categorySet.auras)
        end
        -- Party/raid section-sync flags: behaviour preference, travels with Other
        if categorySet.other and DF.db.linkedSections and next(DF.db.linkedSections) then
            exportData.linkedSections = DF:DeepCopy(DF.db.linkedSections)
        end
        -- Module toggles and the settings font are behaviour/appearance preferences,
        -- so they ride the same category as linkedSections above.
        if categorySet.other then CopyProfileRootScalars(exportData) end
        -- ☠ COLOURS ARE PROFILE-ROOT, so they need a special case here exactly like the
        -- blocks above -- ExtractCategorySettings only ever walks the MODE tables. The
        -- full-export branch has copied all four since the roleColors/dispelColors move;
        -- this branch had no equivalent and no category could request them, so a user who
        -- ticked ALL SIXTEEN boxes still shipped none of their colours. The recipient's
        -- frames visibly did not match, and the dispel palette is the single source of
        -- truth for both the debuff-icon border and the dispel overlay.
        --
        -- ⚠ DF:AuditExportCategories cannot catch this class: it walks PartyDefaults and
        -- RaidDefaults only, so it is structurally blind to profile-root keys. Anything
        -- added at the root has to be wired here by hand.
        if categorySet.colors then
            if DF.db.classColors  and next(DF.db.classColors)  then exportData.classColors  = DF:DeepCopy(DF.db.classColors)  end
            if DF.db.powerColors  and next(DF.db.powerColors)  then exportData.powerColors  = DF:DeepCopy(DF.db.powerColors)  end
            if DF.db.roleColors   and next(DF.db.roleColors)   then exportData.roleColors   = DF:DeepCopy(DF.db.roleColors)   end
            if DF.db.dispelColors and next(DF.db.dispelColors) then exportData.dispelColors = DF:DeepCopy(DF.db.dispelColors) end
        end
    end

    if not exportData.party and not exportData.raid then
        DF:Err(L["No data to export"])
        return nil
    end
    
    -- (No exportData.frameTypes: it was written as exactly "party if exportData.party,
    -- raid if exportData.raid", which is what hasParty/hasRaid already derive on import.)

    -- Serialize -> Compress -> Encode (same as WeakAuras, Cell, etc.)
    local serialized = LibSerialize:Serialize(exportData)
    local compressed = LibDeflate:CompressDeflate(serialized)
    local encoded = LibDeflate:EncodeForPrint(compressed)
    
    return "!DFP1!" .. encoded  -- DFP1 = DandersFrames Profile v1
end

-- ☠ SHAPE-CHECK THE PAYLOAD, NOT JUST ITS PRESENCE.
--
-- Validation used to be `type(data) == "table" and (data.party or data.raid)` -- a
-- TRUTHINESS test. `party = "x"` passed, merged nothing, and still reported "Profile
-- imported successfully!"; `party = 5` passed and threw halfway through the apply,
-- AFTER the profile had been created and switched to. An import string is untrusted
-- input from Discord or a whisper, and DF:ApplyImportedProfile assigns these straight
-- into the saved variables.
--
-- Every key below is assigned to DF.db.<key> by the apply, so each must be a table if
-- present. Absent is always fine -- a selective export legitimately carries only some.
--
-- R:DecodeFilterString (FilterRegistry/Registry.lua) is the model this follows: check
-- the type, then interpret. Deliberately shallow -- deep validation of every setting
-- would reject payloads from a NEWER build, which must stay forward-compatible.
local PAYLOAD_TABLE_KEYS = {
    "party", "raid", "raidAutoProfiles", "auraBlacklist", "linkedSections",
    "classColors", "powerColors", "roleColors", "dispelColors",
    "filterPresetOverrides", "filterMutedSpellIDs", "customAuraFilters",
    "auraDesignerPresets", "textDesignerPresets",
}

local function ValidatePayloadShape(data)
    if type(data) ~= "table" then return nil, "Corrupt data" end
    for _, key in ipairs(PAYLOAD_TABLE_KEYS) do
        local v = data[key]
        if v ~= nil and type(v) ~= "table" then
            return nil, "Corrupt data"
        end
    end
    -- The profile-root scalars are assigned straight to DF.db.<key>, so a table or
    -- function arriving under one of those names has to be rejected here -- the apply
    -- has no type check of its own, and settingsFont in particular is handed to
    -- SetFont downstream.
    for _, key in ipairs(PROFILE_ROOT_SCALARS) do
        local t = type(data[key])
        if data[key] ~= nil and t ~= "string" and t ~= "boolean" and t ~= "number" then
            return nil, "Corrupt data"
        end
    end
    if type(data.party) ~= "table" and type(data.raid) ~= "table" then
        return nil, "No profile data found"
    end

    -- ☠ CYCLE CHECK. LibSerialize explicitly supports table self-reference, so a payload
    -- can legitimately decode into a structure containing a loop -- and DF:DeepCopy used
    -- to recurse into it forever. DeepCopy is cycle-guarded now, but a payload that
    -- CONTAINS a cycle is malformed for our purposes regardless: nothing in a profile is
    -- supposed to be self-referential, and letting one into SavedVariables risks the same
    -- unbounded walk in any future consumer that is not guarded. Reject it here, where
    -- there is a message to show, rather than surviving on the copier's guard.
    local seen = {}
    local function hasCycle(t, depth)
        if type(t) ~= "table" then return false end
        if seen[t] then return true end
        if depth > 32 then return true end   -- absurdly deep is malformed too
        seen[t] = true
        for _, v in pairs(t) do
            if hasCycle(v, depth + 1) then return true end
        end
        seen[t] = nil
        return false
    end
    if hasCycle(data, 0) then
        return nil, "Corrupt data"
    end

    -- ⚠ NO VERSION GATE, DELIBERATELY -- but say so, because its absence looks like an
    -- oversight. `version` is written by every exporter and read only for the display
    -- label. Forward compatibility is the stated intent (see the header above): a payload
    -- from a NEWER build must still import, because its extra keys are simply unknown to
    -- us and the shallow shape check above is what keeps that safe. The filter-string path
    -- DOES gate (`v > FILTER_VERSION` -> "newer") because a v2 filter payload can change
    -- what a filter MEANS; a profile payload carries no such semantics.
    return data, nil
end

-- Validate an import string and return the parsed data if valid
function DF:ValidateImportString(str)
    local LibSerialize = LibStub and LibStub("LibSerialize", true)
    local LibDeflate = LibStub and LibStub("LibDeflate", true)
    
    if not str or str == "" then 
        return nil, "Empty string"
    end
    
    -- Check for our format (starts with !DFP1!)
    if string.sub(str, 1, 6) == "!DFP1!" then
        if not LibSerialize or not LibDeflate then
            return nil, "Missing required libraries"
        end
        
        local encoded = string.sub(str, 7)
        
        -- Decode -> Decompress -> Deserialize
        local compressed = LibDeflate:DecodeForPrint(encoded)
        if not compressed then
            return nil, "Invalid encoding"
        end
        
        local serialized = LibDeflate:DecompressDeflate(compressed)
        if not serialized then
            return nil, "Decompression failed"
        end
        
        local success, data = LibSerialize:Deserialize(serialized)
        if not success then
            return nil, "Deserialization failed"
        end
        
        return ValidatePayloadShape(data)
    end
    
    -- Legacy format support (!DF1! - old LibDeflate with DF:Serialize)
    if string.sub(str, 1, 5) == "!DF1!" then
        if not LibDeflate then
            return nil, "Missing LibDeflate"
        end
        
        local encoded = string.sub(str, 6)
        local compressed = LibDeflate:DecodeForPrint(encoded)
        if not compressed then
            return nil, "Invalid encoding"
        end
        
        local decoded = LibDeflate:DecompressDeflate(compressed)
        if not decoded then
            return nil, "Decompression failed"
        end
        
        -- Old format used loadstring
        local func, err = loadstring("return " .. decoded)
        if not func then
            return nil, "Invalid format"
        end

        -- ☠ SANDBOX BEFORE CALLING. An import string is UNTRUSTED INPUT -- it arrives from
        -- Discord, a forum post, a whisper. `loadstring` compiles arbitrary Lua, and
        -- `return <expr>` is enough to RUN it: `return (function() ... end)()` executes
        -- inside the pcall, and pcall only catches the error AFTERWARDS -- too late. Without
        -- this, Parse String is remote code execution, reached before the confirm popup and
        -- before any category is ticked.
        --
        -- An empty environment leaves table constructors working (which is all a genuine
        -- payload is) while every global -- the whole WoW API included -- resolves nil, so a
        -- hostile chunk errors instead of running. CC:DeserializeStringLegacy
        -- (ClickCasting/Profiles.lua) has always done this; the profile path had not.
        -- Guarded on setfenv existing, matching that sibling exactly.
        if setfenv then
            pcall(setfenv, func, {})
        end

        local success, data = pcall(func)
        if not success or type(data) ~= "table" then
            return nil, "Corrupt data"
        end
        
        return ValidatePayloadShape(data)
    end
    
    -- Other legacy formats
    if string.sub(str, 1, 5) == "!DF2!" or string.sub(str, 1, 5) == "!DF3!" or string.sub(str, 1, 5) == "DF02:" then
        return nil, "Legacy format - please re-export"
    end
    
    -- Try legacy base64
    --
    -- ⚠ THE WIDEST ENTRY POINT IN THE ADDON: no prefix is required to reach it, so ANY
    -- string that happens to Base64-decode lands on loadstring. Every DF build that has
    -- ever shipped exports with a `!DFP1!` prefix (4.x included), so nothing this branch
    -- accepts can have come from us. It is kept only in case some very old third-party
    -- string exists; the sandbox below is what makes keeping it safe. Worth deleting
    -- outright if we ever confirm nothing depends on it.
    local decoded = DF:Base64Decode(str)
    if decoded and decoded ~= "" then
        local func = loadstring("return " .. decoded)
        if func then
            -- Sandbox before calling -- see the !DF1! branch above for the full reasoning.
            if setfenv then
                pcall(setfenv, func, {})
            end
            local success, data = pcall(func)
            if success then
                local ok = ValidatePayloadShape(data)
                if ok then return ok, nil end
            end
        end
    end
    
    return nil, "Invalid format"
end

-- ★ ONE LINE FOR TWELVE SILENT REJECTIONS. ValidateImportString bails with a distinct
-- reason in twelve places -- Invalid encoding, Decompression failed, Deserialization
-- failed, Missing required libraries, Legacy format, Corrupt data and the rest -- and
-- logged none of them. "My import string doesn't work" therefore produced a completely
-- empty log, while the function had the exact reason in hand and handed it only to the UI.
--
-- Wrapped rather than edited at each return: twelve separate edits to add the same line is
-- twelve chances to drift, and a future thirteenth return would miss it. The wrapper cannot
-- be bypassed and needs no maintenance.
--
-- Length is included because the common causes are a truncated paste and a string mangled
-- by a chat client, and both show up as a plausible-looking prefix with the wrong size.
local ValidateImportStringInner = DF.ValidateImportString
function DF:ValidateImportString(str)
    local data, err = ValidateImportStringInner(self, str)
    if not data then
        DF:DebugWarn("PROFILE", "import rejected: %s (length=%s)",
            tostring(err), type(str) == "string" and #str or "not a string")
    end
    return data, err
end

-- Get version info from validated import data
function DF:GetImportVersion(importData)
    if importData and importData.version then
        return importData.version
    end
    return "Unknown (legacy format)"
end

-- Get info about what's in the import data
function DF:GetImportInfo(importData)
    if not importData then return nil end

    local info = {
        version = self:GetImportVersion(importData),
        hasParty = importData.party ~= nil,
        hasRaid = importData.raid ~= nil,
        isFullExport = importData.categories == nil,
        categories = importData.categories or {},
        profileName = importData.profileName or "Imported Profile",
    }
    
    -- Detect categories if not explicitly stored (legacy imports)
    if info.isFullExport then
        -- ☠ The guard belongs HERE, not at the top of the function. The category
        -- registry is companion-owned and only this branch reads it; a selective
        -- payload carries its own category list. Guarding the whole function made
        -- every import load the companion -- including the full-profile Wago path
        -- that the comment below the caller explicitly says must not pay for it.
        if not DF.ExportCategories and DF.EnsureOptionsLoaded then
            if not DF:EnsureOptionsLoaded() then return nil end
        end
        -- Full export contains all categories — derive the list from the
        -- category registry (single source of truth) rather than keeping a
        -- hand-maintained copy here that drifts when categories change.
        info.detectedCategories = {}
        for cat in pairs(DF.ExportCategories) do
            table.insert(info.detectedCategories, cat)
        end
        table.sort(info.detectedCategories, function(a, b)
            local ia = DF.ExportCategoryInfo[a] and DF.ExportCategoryInfo[a].order or 99
            local ib = DF.ExportCategoryInfo[b] and DF.ExportCategoryInfo[b].order or 99
            return ia < ib
        end)
    else
        info.detectedCategories = importData.categories
    end
    
    return info
end

-- Old / pre-fix exports carry the LEGACY name/health/status text keys but no
-- textDesigner table (the Text category exported only the legacy keys until
-- the category list gained "textDesigner"). The legacy keys merge in fine,
-- but nothing ever converts them: the TD migration only runs at login /
-- profile switch and skips any mode already migrated — which every live
-- profile is. With the legacy text widgets retired, the imported text would
-- never render (blank frame text). For each mode whose imported payload was
-- legacy-only, reset that mode's TD so an unforced
-- MigrateTextDesignerFromLegacy rebuilds it from the just-imported legacy
-- settings; modes whose payload carried a textDesigner table (materialised
-- by ImportDesignerPresets) keep their TD untouched. Resets the SAME table
-- the migration rebuilds (GetModeTextDesigner — the mode's preset).
-- Returns true if any mode was reset.
local function ResetTDForLegacyImport(payloads)
    local any = false
    for mode, payload in pairs(payloads) do
        -- A payload is LEGACY only if it carries neither the inline TD table
        -- (pre-library exports) NOR a preset-name ref (post-library exports).
        -- The old check looked only at the inline table — but the preset
        -- migration deletes the inline table from mode DBs, so EVERY modern
        -- export has textDesigner == nil while legacy keys (nameFont etc.)
        -- are still present for pets. That misfired this reset on every
        -- modern import and wiped the just-imported Text Designer elements.
        if type(payload) == "table" and payload.textDesigner == nil
            and payload.textDesignerPreset == nil
            and (payload.nameFont ~= nil or payload.nameFontSize ~= nil
                or payload.showHealthText ~= nil or payload.statusTextEnabled ~= nil) then
            local tdDB = DF.GetModeTextDesigner and DF:GetModeTextDesigner(mode)
            if not tdDB and DF.TextDesigner and DF.TextDesigner.EnsureDB then
                local db = DF:GetDB(mode)
                tdDB = db and DF.TextDesigner:EnsureDB(db)
            end
            if tdDB then
                tdDB.elements = {}
                tdDB.migratedFromLegacy = nil
                any = true
            end
        end
    end
    return any
end

-- Apply imported data with optional category/frame type filtering
-- selectedCategories: table of category names to import, or nil for all in the data
-- selectedFrameTypes: table like {party = true, raid = true}, or nil for all in the data
-- newProfileName: name for the new profile to create (if nil, uses name from import data)
-- createNewProfile: if true, creates a new profile instead of overwriting current
-- allowOverwrite: if true, allow overwriting an existing profile with the same name (used by Wago API)
function DF:ApplyImportedProfile(importData, selectedCategories, selectedFrameTypes, newProfileName, createNewProfile, allowOverwrite)
    local L = DF.L
    if not importData then return false end

    -- ☠ TAKE OUR OWN COPY OF THE PAYLOAD BEFORE ANYTHING TOUCHES IT.
    --
    -- A dozen sites below do `DF.db.<key> = importData.<key>` -- storing the payload's
    -- tables BY REFERENCE into the saved variables. Two consequences, both real:
    --
    --   * The GUI never clears self.parsedImportData, so parse once, import as "A",
    --     rename, import as "B" left BOTH profiles sharing the same party/raid/preset
    --     tables. Editing one silently edited the other until logout flattened them.
    --   * Anything the caller still holds a reference to could mutate a live profile.
    --
    -- Only filterPresetOverrides was being copied. Copying the whole payload once here
    -- fixes every site at a stroke and, more importantly, keeps fixing them: a new
    -- `DF.db.x = importData.x` added later is safe without anyone remembering this.
    -- One deep copy per import is nothing -- this is a deliberate user action, not a
    -- hot path.
    importData = DF:DeepCopy(importData)

    -- A SELECTIVE payload (importData.categories set) merges through the
    -- category tables in the companion. Import is a deliberate user action --
    -- and an external caller (Wago pack) could hand us a selective string with
    -- the panel closed -- so load rather than nil-index. Full imports skip this.
    if importData.categories and not DF.ExportCategories and DF.EnsureOptionsLoaded then
        if not DF:EnsureOptionsLoaded() then return false end
    end

    local importInfo = self:GetImportInfo(importData)

    -- Default to all available frame types
    selectedFrameTypes = selectedFrameTypes or {
        party = importInfo.hasParty,
        raid = importInfo.hasRaid,
    }

    -- Handle profile creation
    if createNewProfile then
        local profileName = newProfileName or importInfo.profileName or "Imported Profile"

        -- Ensure unique name unless overwrite is explicitly allowed (e.g. Wago API imports)
        if not allowOverwrite then
            local baseName = profileName
            local counter = 1
            while DandersFramesDB_v2 and DandersFramesDB_v2.profiles and DandersFramesDB_v2.profiles[profileName] do
                counter = counter + 1
                profileName = baseName .. " " .. counter
            end
        end
        
        -- Initialize profiles table if needed
        if not DandersFramesDB_v2 then DandersFramesDB_v2 = {} end
        if not DandersFramesDB_v2.profiles then DandersFramesDB_v2.profiles = {} end
        
        -- Save current profile before switching
        DF:SaveCurrentProfile()

        -- Create new profile as a COPY of current profile (not defaults)
        -- This way, any categories NOT selected for import will keep the user's current settings
        -- DeepCopy unwraps proxies automatically
        DandersFramesDB_v2.profiles[profileName] = {
            party = DF:DeepCopy(DF.db.party or DF.PartyDefaults),
            raid = DF:DeepCopy(DF.db.raid or DF.RaidDefaults),
            raidAutoProfiles = DF:DeepCopy(DF.db.raidAutoProfiles or DF.RaidAutoProfilesDefaults),
            classColors = DF:DeepCopy(DF.db.classColors or {}),
            powerColors = DF:DeepCopy(DF.db.powerColors or {}),
            roleColors = DF:DeepCopy(DF.db.roleColors or {}),
            dispelColors = DF:DeepCopy(DF.db.dispelColors or {}),
            auraBlacklist = DF:DeepCopy(DF.db.auraBlacklist or { buffs = {}, debuffs = {} }),
            filterPresetOverrides = DF:DeepCopy(DF.db.filterPresetOverrides or {}),
            filterMutedSpellIDs = DF:DeepCopy(DF.db.filterMutedSpellIDs or {}),
            -- Designer preset LIBRARIES (profile-root): the copied mode tables
            -- carry preset NAME refs, so omitting these would leave the new
            -- profile with dangling refs → empty Default → all AD/TD gone.
            auraDesignerPresets = DF:DeepCopy(DF.db.auraDesignerPresets or {}),
            textDesignerPresets = DF:DeepCopy(DF.db.textDesignerPresets or {}),
            -- Copy of current, like everything else here — the import then
            -- overwrites it when the payload carries linkedSections.
            linkedSections = DF:DeepCopy(DF.db.linkedSections or {}),
            partyEnabled = DF.db.partyEnabled ~= false,
            raidEnabled  = DF.db.raidEnabled  ~= false,
            -- Profile-root scalars, copied from current like everything else here so an
            -- unticked category leaves them alone. Without these the new profile was born
            -- without a settings font and silently fell back to the default on backfill,
            -- so importing anything reset the options window's own typeface.
            settingsFont        = DF.db.settingsFont,
            settingsFontOutline = DF.db.settingsFontOutline,
            fontSlug            = DF.db.fontSlug,
        }

        -- ☠ CARRY THE MIGRATION FLAGS. Everything above is copied from the CURRENT
        -- profile, so the new profile holds ALREADY-MIGRATED data -- but the enumeration
        -- lists no `_…V1` flag, so it was born claiming to need every root migration it
        -- has already had. On the next reload CleanupRedundantLayoutPresets re-ran and
        -- pruned layout presets the user had deliberately made identical to their base,
        -- which is the exact thing that guard exists to prevent.
        --
        -- Copied by CONVENTION (every profile-root migration flag is `_`-prefixed) rather
        -- than from a fixed list, so a future migration is carried without anyone
        -- remembering to come back here. DF:StampFreshProfileMigrations is deliberately
        -- NOT used: it stamps the three flags a profile born from DEFAULTS needs, and this
        -- profile is not born from defaults -- it would miss _designerLayoutCleanupV1 and
        -- _designerPresetsMigratedV1, the two that actually bite.
        --
        -- Read through _realProfile: DF.db is proxied, and pairs() on the proxy does not
        -- reliably enumerate the real table. DF:DuplicateProfile gets this for free via
        -- DeepCopy(DF.db); only this hand-enumerated branch had to be told.
        local srcProfile = DF._realProfile or DF.db
        local newProfile = DandersFramesDB_v2.profiles[profileName]
        if type(srcProfile) == "table" then
            for k, v in pairs(srcProfile) do
                if type(k) == "string" and k:sub(1, 1) == "_" and newProfile[k] == nil then
                    newProfile[k] = v
                end
            end
        end

        -- Switch to the new profile
        DandersFramesDB_v2.currentProfile = profileName
        if DandersFramesCharDB then
            DandersFramesCharDB.currentProfile = profileName
        end
        DF.db = DandersFramesDB_v2.profiles[profileName]
        DF:WrapDB()
        
        DF:Say(format(L["Created new profile: %s"], profileName))
    end

    -- Aura filter registry payload. Runs BEFORE the mode tables are applied:
    -- imported custom filters merge into the account-wide store first, and the
    -- oldId -> newId remap is applied to the IMPORTED selection tables — the
    -- apply below then carries the fixed selections into DF.db by plain
    -- assignment. Remapping the payload (never DF.db directly) can't disturb
    -- selections in a mode or profile the import doesn't touch. Gated like the
    -- aura blacklist: only when the auras category is being imported.
    local aurasImported = importInfo.isFullExport and not selectedCategories
    if not aurasImported then
        for _, cat in ipairs(selectedCategories or importInfo.detectedCategories or {}) do
            if cat == "auras" then
                aurasImported = true
                break
            end
        end
    end
    -- AD preset libraries import under their own gates (mirror
    -- ImportDesignerPresets' importAura: auraDesigner/autoLayout/pinnedFrames).
    -- Their filter groups can link custom filters, so the embedded filter
    -- snapshot must import (and the payload remap must run) for these
    -- categories too — otherwise the imported groups' refs dangle.
    local adPresetsImported = importInfo.isFullExport and not selectedCategories
    if not adPresetsImported then
        for _, cat in ipairs(selectedCategories or importInfo.detectedCategories or {}) do
            if cat == "auraDesigner" or cat == "autoLayout" or cat == "pinnedFrames" then
                adPresetsImported = true
                break
            end
        end
    end
    if aurasImported then
        -- Replace semantics (aura blacklist precedent): the embedded overrides
        -- table fully replaces the local one — INCLUDING an embedded empty
        -- table, which resets local preset tweaks to stock so the rows render
        -- as they did on the exporter's screen. Back-compat: strings exported
        -- before overrides were always embedded lack the key entirely when the
        -- exporter had none — an absent key must leave local overrides alone.
        if importData.filterPresetOverrides then
            DF.db.filterPresetOverrides = DF:DeepCopy(importData.filterPresetOverrides)
        end
        -- Per-spell-ID narrowing, same replace-with-absent-key-exemption rule.
        if importData.filterMutedSpellIDs then
            DF.db.filterMutedSpellIDs = DF:DeepCopy(importData.filterMutedSpellIDs)
        end
    end
    -- The AD gate only counts when the payload actually carries preset
    -- libraries — otherwise an autoLayout-only import of an auras-category
    -- string would add filters nothing references.
    if adPresetsImported and not importData.auraDesignerPresets then
        adPresetsImported = false
    end
    if (aurasImported or adPresetsImported) and importData.customAuraFilters and DF.FilterRegistry then
        local remap = DF.FilterRegistry:ImportCustomFilters(importData.customAuraFilters)
        local function remapCustoms(sel)
            if type(sel) == "table" and type(sel.customs) == "table" then
                local fixed = {}
                for cfId in pairs(sel.customs) do
                    fixed[remap[cfId] or cfId] = true
                end
                sel.customs = fixed
            end
        end
        local function remapSel(mode)
            if type(mode) ~= "table" then return end
            remapCustoms(mode.buffFilterSelection)
            remapCustoms(mode.defensiveFilterSelection)
        end
        remapSel(importData.party)
        remapSel(importData.raid)
        -- Raid auto-layout overrides in the payload carry whole-table copies
        -- of the selection tables — remap their customs ids too, or every
        -- applied layout resolves against the RECEIVER's unrelated cf ids
        -- (ids are "cf1", "cf2", … on every account, so a stale ref silently
        -- shows the wrong auras). Payload-side, before the apply below.
        local function remapLayout(layout)
            local ov = type(layout) == "table" and layout.overrides
            if type(ov) == "table" then
                remapCustoms(ov.buffFilterSelection)
                remapCustoms(ov.defensiveFilterSelection)
            end
        end
        if type(importData.raidAutoProfiles) == "table" then
            for _, ct in pairs(importData.raidAutoProfiles) do
                if type(ct) == "table" then
                    if type(ct.profiles) == "table" then
                        for _, layout in pairs(ct.profiles) do remapLayout(layout) end
                    end
                    remapLayout(ct.profile)   -- mythic carries a single layout
                end
            end
        end
        -- AD filter-group links in the payload's preset libraries: remap
        -- payload-side, BEFORE ImportDesignerPresets applies them (same
        -- rationale as the mode selections above — never touch DF.db refs
        -- the import doesn't carry). layoutGroups is spec-keyed post-V2 but
        -- old exports may carry the legacy flat array — walk both shapes.
        local function remapGroupArray(groups)
            for _, g in ipairs(groups) do
                if type(g) == "table" then remapCustoms(g.filterSelection) end
            end
        end
        if type(importData.auraDesignerPresets) == "table" then
            for _, preset in pairs(importData.auraDesignerPresets) do
                local lg = type(preset) == "table" and preset.layoutGroups
                if type(lg) == "table" then
                    if lg[1] ~= nil then remapGroupArray(lg) end
                    for k, v in pairs(lg) do
                        if type(k) == "string" and type(v) == "table" then
                            remapGroupArray(v)
                        end
                    end
                end
                -- Other Buffs layout groups: flat array only (spec-independent
                -- store — no dual-shape dispatch needed).
                local olg = type(preset) == "table" and preset.otherLayoutGroups
                if type(olg) == "table" then remapGroupArray(olg) end
                -- AD effect references to custom filters: the "@custom:<id>" aura KEY of
                -- a filter-owned effect, and any "@custom:<id>" in a trigger list. Both
                -- are strings, so remapCustoms can't reach them — without this they keep
                -- the exporter's cf id and bind to an unrelated filter on the receiver.
                local function remapRef(name)
                    local kind, key = DF:ParseADFilterRef(name)
                    if kind ~= "custom" then return name end
                    local newKey = remap[key]
                    if not newKey or newKey == key then return name end
                    return DF:MakeADFilterRef("custom", newKey) or name
                end
                local function remapAuraStore(store)
                    if type(store) ~= "table" then return end
                    -- Rekey filter-owned records first, collecting into a fresh table so a
                    -- remapped key can't collide with one still to be visited.
                    local rekeyed, changed = {}, false
                    for auraName, auraCfg in pairs(store) do
                        if type(auraCfg) == "table" then
                            for _, typeCfg in pairs(auraCfg) do
                                if type(typeCfg) == "table" then
                                    if type(typeCfg.triggers) == "table" then
                                        for i, t in ipairs(typeCfg.triggers) do
                                            typeCfg.triggers[i] = remapRef(t)
                                        end
                                    end
                                    -- ☠ Condition-group triggers, the third store. Mirrors
                                    -- the export walk -- miss these and the id is never
                                    -- remapped, so the condition binds to whatever local
                                    -- filter happens to hold the exporter's cf number.
                                    local conds = typeCfg.conditions
                                    if type(conds) == "table" and type(conds.groups) == "table" then
                                        for _, grp in pairs(conds.groups) do
                                            if type(grp) == "table" and type(grp.triggers) == "table" then
                                                for i, t in ipairs(grp.triggers) do
                                                    grp.triggers[i] = remapRef(t)
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                        local newName = remapRef(auraName)
                        if newName ~= auraName then changed = true end
                        rekeyed[newName] = auraCfg
                    end
                    if changed then
                        wipe(store)
                        for k, v in pairs(rekeyed) do store[k] = v end
                    end
                end
                if type(preset) == "table" then
                    -- ☠ Same shape dispatch as the export walk: `auras` is spec-keyed only
                    -- AFTER the lazy spec-scope migration has touched that adDB, so a
                    -- never-rendered preset still holds the flat store. Treating it as
                    -- spec-keyed skips the aura-name level and leaves every id unremapped.
                    local function looksLikeAuraConfig(v)
                        if type(v) ~= "table" then return false end
                        return v.priority ~= nil or v.indicators ~= nil or v.border ~= nil
                    end
                    if type(preset.auras) == "table" then
                        local flat = false
                        for _, v in pairs(preset.auras) do
                            if looksLikeAuraConfig(v) then flat = true end
                            break
                        end
                        if flat then
                            remapAuraStore(preset.auras)
                        else
                            for _, specAuras in pairs(preset.auras) do remapAuraStore(specAuras) end
                        end
                    end
                    remapAuraStore(preset.otherAuras)
                end
            end
        end
    end

    -- ☠ DESIGNER PRESET NAME CLASHES, resolved payload-side like the filter refs above.
    --
    -- ImportDesignerPresets merges imported-wins, which silently replaced a same-named
    -- preset the user had built. Only a clobber when we are importing INTO the current
    -- profile: the createNewProfile branch made the new profile a COPY moments ago, so
    -- its library is a duplicate and the originals are safe in the source profile.
    --
    -- ⚠ MUST run here, BEFORE the mode tables are applied. Presets are referenced by
    -- NAME, and once the payload's refs have been copied into DF.db they are
    -- indistinguishable from the user's own -- repointing then would move local refs the
    -- import never carried. Same reason the filter-ref remap above is payload-side.
    if not createNewProfile and DF.UniquifyImportedDesignerPresets then
        local presetCats = selectedCategories
        if not presetCats and not importInfo.isFullExport then
            presetCats = importInfo.detectedCategories
        end
        local renamed = DF:UniquifyImportedDesignerPresets(importData, presetCats)
        if renamed and DF.Debug then
            for kind, map in pairs(renamed) do
                for old, new in pairs(map) do
                    DF:Debug("PROFILE", "import: %s preset name clash, %s -> %s", kind, old, new)
                end
            end
        end
    end

    -- ☠ SHARED BY BOTH IMPORT PATHS. This lived inside the full-export branch only, so a
    -- SELECTIVE import -- a v4 selective-export string, or a full v4 string with
    -- categories ticked in the UI -- landed nothing, and RunV5LegacyMigrations further
    -- down then stripped the v4 overlay keys it would have been rebuilt from. Silent
    -- colour loss on the very path the fix claimed to cover. Reads importData (the
    -- payload) rather than DF.db, so it is unaffected by the category merge dropping the
    -- legacy keys, and it must stay AHEAD of RunV5LegacyMigrations.
    local function importDispelColors()
        local wrote = false
        if importData.dispelColors then
            DF.db.dispelColors = importData.dispelColors
            wrote = true
        elseif DF.BuildDispelColorsFromLegacy then
            local legacy = DF:BuildDispelColorsFromLegacy(importData.party, importData.raid)
            if legacy then DF.db.dispelColors = legacy wrote = true end
        end
        -- ☠ Same process-lifetime cache as the profile switch: writing dispelColors does
        -- not invalidate the built curve or map, so an imported palette would not reach
        -- any live carrier and the generation would never move to force a re-bind.
        -- An imported table is also only shape-checked, never key-checked, so it can be
        -- partial -- which is exactly the input the curve's per-key fallback exists for.
        if wrote and DF.InvalidateDispelColorCurve then DF:InvalidateDispelColorCurve() end
    end

    -- If it's a full export (legacy or "all categories"), use direct replacement
    if importInfo.isFullExport and not selectedCategories then
        -- Legacy behavior: replace entire profile sections
        if importData.party and selectedFrameTypes.party then 
            DF.db.party = importData.party 
        end
        if importData.raid and selectedFrameTypes.raid then 
            DF.db.raid = importData.raid 
        end
        -- Import class color overrides if present
        if importData.classColors then
            DF.db.classColors = importData.classColors
        end
        -- Import power color overrides if present
        if importData.powerColors then
            DF.db.powerColors = importData.powerColors
        end
        -- Import role colours if present
        if importData.roleColors then
            DF.db.roleColors = importData.roleColors
        end
        -- Import dispel colours if present (profile-root, like roleColors).
        -- ☠ A v4 STRING HAS NO dispelColors. v4 kept two separate per-mode families
        -- (debuffBorderColor* for the icon border, dispel<Type>Color for the overlay),
        -- both of which ride v4's export; v5 merged them onto this one account-wide
        -- table. Without the else-branch the import silently landed nothing and the
        -- user's dispel colours were gone -- and the login migration could not save
        -- them either, because it only fires when dispelColors is absent and it reads
        -- the mode tables, which by then have had the overlay half stripped.
        -- Same resolver as the login migration, so both paths agree exactly.
        importDispelColors()
        -- Import auto layout profiles if present
        if importData.raidAutoProfiles then
            DF.db.raidAutoProfiles = importData.raidAutoProfiles
        end
        -- Import aura blacklist if present
        if importData.auraBlacklist then
            DF.db.auraBlacklist = importData.auraBlacklist
        end
        -- Import party/raid section-sync flags if present
        if importData.linkedSections then
            DF.db.linkedSections = importData.linkedSections
        end
        ApplyProfileRootScalars(importData)
    else
        -- Selective import: merge only selected categories
        local categoriesToImport = selectedCategories or importInfo.detectedCategories
        
        if importData.party and selectedFrameTypes.party then
            self:MergeCategorySettings(DF.db.party, importData.party, categoriesToImport, importData.categories)
        end
        if importData.raid and selectedFrameTypes.raid then
            self:MergeCategorySettings(DF.db.raid, importData.raid, categoriesToImport, importData.categories)
        end
        -- Auto layouts: top-level key, needs special handling
        local importCategorySet = {}
        for _, cat in ipairs(categoriesToImport) do importCategorySet[cat] = true end
        if importCategorySet.autoLayout and importData.raidAutoProfiles then
            DF.db.raidAutoProfiles = importData.raidAutoProfiles
        end
        -- Aura blacklist: top-level key, import with auras category
        if importCategorySet.auras and importData.auraBlacklist then
            DF.db.auraBlacklist = importData.auraBlacklist
        end
        -- Section-sync flags: top-level key, travel with the Other category
        if importCategorySet.other and importData.linkedSections then
            DF.db.linkedSections = importData.linkedSections
        end
        -- Module toggles and settings font: same category as the flags above.
        if importCategorySet.other then ApplyProfileRootScalars(importData) end
        -- ☠ THE COLOURS CATEGORY WAS EXPORT-ONLY. The export block above packs all four
        -- palettes when `colors` is ticked, but nothing here consumed them and the only
        -- code that applies classColors/powerColors/roleColors sits in the FULL-import
        -- branch -- which selecting any category skips. So ticking Colors, exporting,
        -- and importing with Colors ticked silently discarded three of the four tables:
        -- data loss on the one feature whose entire purpose is moving colours between
        -- accounts. These are profile-root keys, so they need naming here by hand;
        -- MergeCategorySettings only ever walks the MODE tables.
        --
        -- ☠ AND THAT FIX WAS ITSELF INERT UNTIL 2026-08-10. It gated on
        -- `importCategorySet.colors`, a condition that can NEVER be true: `colors` has no
        -- entry in DF.ExportCategories (deliberately -- see the note at the top of that
        -- file), and the import GUI derives every checkbox from `pairs(DF.ExportCategories)`.
        -- So the category could not be offered, could not be ticked, and this block never
        -- ran. The bug it was written to fix survived the fix.
        --
        -- Gate on PRESENCE instead, which is sound because of an asymmetry in the exporter:
        -- the FULL export packs all four palettes unconditionally, while the SELECTIVE
        -- export packs them only `if categorySet.colors` -- equally unreachable. So a
        -- payload carrying these keys is necessarily a full export, i.e. the user asked
        -- for everything. Presence therefore IS the authorisation, and no reachable path
        -- can deliver these keys without that intent.
        --
        -- ⚠ If `colors` is ever given a real category entry, revisit BOTH ends together --
        -- at that point presence stops implying a full export.
        if importData.classColors then DF.db.classColors = importData.classColors end
        if importData.powerColors then DF.db.powerColors = importData.powerColors end
        if importData.roleColors  then DF.db.roleColors  = importData.roleColors  end
        -- Dispel palette: top-level key, and the fourth member of that set -- so `colors`
        -- must request it too. Also gated on `dispel` and `auras` because the two v4
        -- families it is rebuilt from ride different ones -- the overlay's
        -- dispel<Type>Color under `dispel`, the icon border's debuffBorderColor* under
        -- `auras` -- so ticking any of the three is a request for these colours.
        if importCategorySet.dispel or importCategorySet.auras or importCategorySet.colors then
            importDispelColors()
        end
    end

    -- Designer preset libraries + legacy inline designer tables. Must run
    -- AFTER the mode tables are applied (it materialises inline AD/TD from
    -- old exports into the library the imported refs point at).
    if DF.ImportDesignerPresets then
        -- Explicit user selection gates; a full export imports everything;
        -- otherwise fall back to the payload's own category list.
        local presetCategories = selectedCategories
        if not presetCategories and not importInfo.isFullExport then
            presetCategories = importInfo.detectedCategories
        end
        DF:ImportDesignerPresets(importData, presetCategories)
    end

    -- Legacy-text payloads → Text Designer (see ResetTDForLegacyImport).
    -- AFTER ImportDesignerPresets (which materialises inline TD tables — those
    -- payloads skip the rebuild). Only when the text category was actually
    -- imported, and only for the imported frame types — rebuilding from
    -- legacy keys that didn't merge would convert the RECEIVER's stale
    -- legacy values instead.
    local textImported = importInfo.isFullExport and not selectedCategories
    if not textImported then
        for _, cat in ipairs(selectedCategories or importInfo.detectedCategories or {}) do
            if cat == "text" then
                textImported = true
                break
            end
        end
    end
    if textImported and DF.MigrateTextDesignerFromLegacy then
        local payloads = {}
        if selectedFrameTypes.party then payloads.party = importData.party end
        if selectedFrameTypes.raid then payloads.raid = importData.raid end
        if ResetTDForLegacyImport(payloads) then
            DF:MigrateTextDesignerFromLegacy()
        end
    end

    -- Fold/zero border insets on the just-imported configs (pre-rework look).
    if DF.MigrateBorderInsetFold then
        if DF.db then
            -- Step 1 (Aura Designer icon/square fold) IS value-idempotent: FoldAuraDesignerConfig
            -- early-returns on inset == 0, and `seen` stops a shared preset folding twice. Free
            -- to re-arm on every import.
            DF.db._borderInsetFoldV1 = nil

            -- ☠ STEP 2 IS NOT IDEMPOTENT, despite what MigrateBorderInsetFold's header says.
            -- ZeroBuffDebuffBorderInset writes buffBorderInset = 0 / debuffBorderInset = 0
            -- UNCONDITIONALLY on BOTH modes and strips those keys out of every raid
            -- auto-layout override. It cannot tell a leftover legacy inset from a value the
            -- user deliberately set AFTER the migration ran -- nothing marks the difference.
            --
            -- So re-arming it on every import silently destroyed those settings across the
            -- WHOLE profile, including presets and layouts the import never touched. Importing
            -- a friend's colour scheme, or a text-only selective import, was enough.
            --
            -- Re-arm only when the PAYLOAD actually carries something to fold, and only for a
            -- mode this import is applying. A v5 export always has these at 0 (the migration
            -- ran on the sender), so this is a no-op for the normal case while still repairing
            -- a genuine 4.x payload.
            local function payloadNeedsInsetZero(mode)
                if type(mode) ~= "table" then return false end
                return (tonumber(mode.buffBorderInset) or 0) ~= 0
                    or (tonumber(mode.debuffBorderInset) or 0) ~= 0
            end
            if (selectedFrameTypes.party and payloadNeedsInsetZero(importData.party))
                or (selectedFrameTypes.raid and payloadNeedsInsetZero(importData.raid)) then
                DF.db._buffDebuffInsetZeroV1 = nil
            end
        end
        DF:MigrateBorderInsetFold()
    end

    -- v5 legacy passes (dispel-enable fold, legacy-aura key strip, retired
    -- animation remap, alpha dispel-custom cleanup): otherwise these only
    -- re-run at ADDON_LOADED, leaving a just-imported v4 payload rendering a
    -- wrong dispel state and dead animation values until the next reload.
    -- Flag-gated / value-idempotent — a no-op for v5 payloads and untouched
    -- profiles.
    if DF.RunV5LegacyMigrations then
        DF:RunV5LegacyMigrations()
    end

    -- ☠ THE MIGRATIONS A PROFILE SWITCH RUNS, WHICH IMPORT DID NOT.
    --
    -- DF:SetProfile runs seven passes over the newly-active profile; this path ran three,
    -- one of them overlapping. The five below were simply never reached by imported data,
    -- even though an imported payload is the LEAST migrated data the addon ever sees -- a
    -- v4 export is by definition pre-migration.
    --
    -- MigrateOORTextAlpha is the sharpest case: its own comment (Core.lua) reasons in
    -- detail about "a v4 export imported over an already-migrated profile" reintroducing
    -- oorNameTextAlpha, and explains that it is presence-gated rather than flag-gated for
    -- exactly that reason -- and nothing on this path ever called it. The code was written
    -- for a scenario its wiring excluded.
    --
    -- ⚠ ORDER MATTERS and mirrors SetProfile: designer presets first (later passes read
    -- the resolved library), then the targeted-spell border fold, then the two text
    -- clean-ups, then the OOR alpha fold. MigrateBorderInsetFold and the TD legacy rebuild
    -- already ran above and are deliberately not repeated -- the fold is NOT idempotent
    -- (see the note at its call site).
    --
    -- ⚠ Each is guarded because they live in the resident addon and this file is reached
    -- from the options companion.
    -- ☠ BACKFILL DEFAULTS INTO THE IMPORTED MODE TABLES.
    --
    -- A full import replaces DF.db.party / DF.db.raid WHOLESALE from the payload, and the
    -- only defaults backfill in the addon lives inside the ADDON_LOADED handler -- neither
    -- this path nor SetProfile re-runs it. So every key added to the defaults SINCE the
    -- payload was exported read nil for the rest of the session: import a v4 export and
    -- debuffImportantHighlight (default true) is absent, `if db.debuffImportantHighlight`
    -- reads nil, Important Debuffs is off -- while the settings page shows it ON, because
    -- the checkbox falls back to the default. Only a /reload corrected it.
    --
    -- Same shape as the login pass (Core.lua): fill only ABSENT keys, so nothing the
    -- payload actually carried is touched.
    -- ☠ THIS RUNS BEFORE THE BACKFILL, and it has to.
    --
    -- One line further down the defaults seed raidGroupCenterMode = "ALL", after which a
    -- pre-Center-Mode payload is indistinguishable from a payload that deliberately chose
    -- Default. Right now the absence still means something, so capture it: an old payload
    -- gets its flag dropped and is put through the migration below (which then decides on
    -- its own terms whether the payload qualifies), while a payload that carried the key
    -- is left exactly as it was sent.
    --
    -- The flag itself rides across from the SOURCE profile on the new-profile branch (the
    -- `_`-prefixed copy convention), which is why it needs clearing at all -- otherwise a
    -- migrated importer would veto the migration of the un-migrated data that just
    -- replaced their own. Same failure the three flags below were cleared for.
    if type(DF.db) == "table" and type(DF.db.raid) == "table"
        and DF.db.raid.raidGroupCenterMode == nil then
        DF.db._raidCenterModeV1 = nil
    end

    local function backfillDefaults(modeTable, defaults)
        if type(modeTable) ~= "table" or type(defaults) ~= "table" then return end
        for key, value in pairs(defaults) do
            if modeTable[key] == nil then
                modeTable[key] = DF:DeepCopy(value)
            end
        end
    end
    -- ☠ ALSO BEFORE THE BACKFILL, for the same reason as _raidCenterModeV1 above.
    -- `position` has a shipped default, so once the backfill stamps it a pre-record
    -- payload's anchorX/anchorY (the only position it carries) can never be folded into
    -- the record again -- the frames would land on the default, not where the export
    -- put them. The flag rode across from the source profile (or is simply this
    -- profile's own), so clear it when either mode arrived without a record and let the
    -- login migration's presence gate do the seeding.
    if DF.MigrateContainerPositionRecords and type(DF.db) == "table" then
        local p, r = DF.db.party, DF.db.raid
        if (type(p) == "table" and p.position == nil) or (type(r) == "table" and r.position == nil) then
            DF.db._moverPositionRecordsV1 = nil
        end
        -- Phase B records, same reason: a pre-record payload carries only the scalars.
        if (type(p) == "table" and (p.personalTargetedPosition == nil or p.targetedListPosition == nil))
            or (type(r) == "table" and r.personalTargetedPosition == nil) then
            DF.db._moverPositionRecordsV2 = nil
        end
        -- Phase C: an old export can carry the five deleted grid prefs (or a
        -- RESET_POSITION quick action). Re-open the sweep so the call below cleans
        -- the imported payload; a payload without them costs one idle pass.
        local function carriesLegacyMoverPrefs(m)
            if type(m) ~= "table" then return false end
            return m.gridSize ~= nil or m.snapToGrid ~= nil or m.pinnedSnapToGrid ~= nil
                or m.pinnedHideMover ~= nil or m.hideDragOverlay ~= nil
                or m.permanentMoverActionLeft == "RESET_POSITION"
                or m.permanentMoverActionRight == "RESET_POSITION"
                or m.permanentMoverActionShiftLeft == "RESET_POSITION"
                or m.permanentMoverActionShiftRight == "RESET_POSITION"
        end
        if carriesLegacyMoverPrefs(p) or carriesLegacyMoverPrefs(r) then
            DF.db._moverLegacyPrefsRemovedV1 = nil
        end
        -- Always run: the two blocks above are flag-gated per profile and the pinned
        -- walk is self-gated (an imported pinnedFrames table lacks its positionsV2
        -- marker), so an import that changed nothing costs one idle pass.
        DF:MigrateContainerPositionRecords()
    end

    backfillDefaults(DF.db and DF.db.party, DF.PartyDefaults)
    backfillDefaults(DF.db and DF.db.raid, DF.RaidDefaults)

    -- ☠ CLEAR THE GATE FLAGS FIRST, or the passes below are no-ops on imported data.
    --
    -- The new-profile branch copies every `_`-prefixed flag off the SOURCE profile by
    -- convention, so a migration flag describing the user's own already-migrated data
    -- rides across and then vetoes the migration of the payload that just REPLACED that
    -- data. `_personalTsImportantBorderV1` is the proven case: a v4 payload carrying
    -- personalTargetedSpellHighlight* arrived with the flag pre-set, the pass skipped it
    -- here and at every future login, and the customisation was silently lost.
    --
    -- A flag asserts "this PROFILE's data has been folded". The payload's data has not, so
    -- for these the flags are false by definition at this moment.
    --
    -- ⚠ THREE, not five. _oorTextAlphaV1 used to be cleared here as a fourth and was
    -- never a gate -- MigrateOORTextAlpha is presence-gated on m.oorNameTextAlpha, so
    -- clearing the flag did nothing. And MigrateDesignerPresets, called just below,
    -- has no flag at all: if you give it one, add it here in the same change.
    local p = DF.db
    if type(p) == "table" then
        p._personalTsImportantBorderV1 = nil
        p._legacyTextOverrideCleanupV1 = nil
        p._designerLayoutCleanupV1 = nil
    end

    if DF.MigrateDesignerPresets then DF:MigrateDesignerPresets() end
    if DF.MigrateTargetedSpellImportantBorder then DF:MigrateTargetedSpellImportantBorder() end
    if DF.CorrectStrayMigratedHealthText then DF:CorrectStrayMigratedHealthText() end
    if DF.CleanupLegacyTextLayoutOverrides then DF:CleanupLegacyTextLayoutOverrides() end
    if DF.MigrateOORTextAlpha then DF:MigrateOORTextAlpha() end
    -- An imported profile carries the old +12 too, so it needs the same drop.
    if DF.MigrateHealPredictionBelowAbsorb then DF:MigrateHealPredictionBelowAbsorb() end
    -- No-op unless the pre-backfill check above dropped the flag, i.e. the payload
    -- predates Center Mode. A payload that carried the key keeps whatever it chose.
    if DF.MigrateRaidCenterMode then DF:MigrateRaidCenterMode() end
    -- ⚠ An imported profile can carry the OLD three-stage keys and no stop list, so the
    -- conversion has to run on the import path too -- otherwise the import renders from
    -- the legacy fallback until some later login happens to convert it.
    if DF.MigrateHealthColorStops then DF:MigrateHealthColorStops() end

    -- The import has landed, so anything the undo stack still holds describes
    -- values the payload has just overwritten -- or tables it replaced outright.
    -- Fenced after the apply rather than before it: the import can bail out at a
    -- dozen points above, and a stack cleared by an import that never happened is
    -- work the user loses for nothing.
    local SU = DF.SettingsUndo
    if SU then SU:Clear() end

    DF:FullProfileRefresh()
    DF:Say(L["Profile imported successfully!"])

    -- If the imported state changed which frame modes are enabled, prompt
    -- the user to reload so headers can be (re)created.
    if DF.PromptReloadIfEnableFlagsChanged then
        DF:PromptReloadIfEnableFlagsChanged()
    end

    return true
end

-- DF:ImportProfile(str) used to live here — a dead wholesale-replacement
-- import with zero callers that bypassed the custom-filter/remap machinery.
-- The real import path is DF:ApplyImportedProfile (above), which the GUI
-- and API.lua both use.

-- ============================================================
-- SPEC AUTO-SWITCH (per-character settings)
-- ============================================================

function DF:CheckProfileAutoSwitch()
    -- Use per-character saved variable (DandersFramesCharDB)
    if not DandersFramesCharDB then return end
    if not DandersFramesCharDB.enableSpecSwitch then return end
    
    local specIndex = GetSpecialization and GetSpecialization()
    if not specIndex then return end
    
    local profileName = DandersFramesCharDB.specProfiles and DandersFramesCharDB.specProfiles[specIndex]
    
    -- If a profile is assigned and it is NOT the current profile
    if profileName and profileName ~= "" and profileName ~= DF:GetCurrentProfile() then
        -- Verify profile exists
        local profiles = DF:GetProfiles()
        local exists = false
        for _, p in ipairs(profiles) do 
            if p == profileName then 
                exists = true 
                break 
            end 
        end
        
        if exists then
            local L = DF.L
            DF:SetProfile(profileName)
            DF:Say(format(L["Auto-switched to profile: %s"], profileName))
            -- Note: SetProfile now calls FullProfileRefresh which handles GUI refresh
        end
    end
end
