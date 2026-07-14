local addonName, DF = ...

-- ============================================================
-- DESIGNER PRESETS
-- Named, profile-level libraries of Aura Designer (AD) and Text
-- Designer (TD) configurations. Consumers (party frames, raid
-- frames, and later each pinned set) store only a preset *name*;
-- the canonical config table lives once in the library.
--
-- Storage (profile root, sibling of db.party / db.raid):
--   DF.db.auraDesignerPresets  = { ["Default"]={…}, ["Party"]={…}, ["Raid"]={…}, … }
--   DF.db.textDesignerPresets  = { ["Default"]={…}, ["Party"]={…}, ["Raid"]={…}, … }
--
-- Consumer references (per mode db):
--   DF.db.party.auraDesignerPreset = "Party"
--   DF.db.raid.auraDesignerPreset  = "Raid"   (+ textDesignerPreset)
--
-- Storing the NAME (a plain string), never a duplicated table, avoids
-- the SavedVariables "shared table reference splits into two copies on
-- reload" trap — there is one canonical table per preset.
-- ============================================================

local pairs, ipairs = pairs, ipairs

DF.DEFAULT_PRESET = "Default"   -- non-deletable ultimate fallback

-- ============================================================
-- FACTORIES — fresh, default-shaped designer configs
-- ============================================================

-- A clean Aura Designer config: a deep copy of the Party defaults
-- template (enabled = false, empty per-spec auras). DeepCopy keeps us
-- in lockstep with Config.lua without duplicating the defaults table.
function DF:NewAuraDesignerConfig()
    local base = DF.PartyDefaults and DF.PartyDefaults.auraDesigner
    local cfg
    if base then
        cfg = DF:DeepCopy(base)
    else
        cfg = { enabled = false, spec = "auto", previewScale = 1.0, soundEnabled = true,
                defaults = {}, auras = {}, layoutGroups = {}, nextLayoutGroupID = 1 }
    end
    -- Force a pristine, disabled config regardless of what the template carried.
    cfg.enabled = false
    cfg.auras = {}
    cfg.layoutGroups = {}
    cfg.nextLayoutGroupID = 1
    -- Born in the new higher-wins priority scale, so the lazy priority migration
    -- never flips a freshly-created config (see MigrateAuraDesignerPrioritiesLazy).
    cfg._priorityHigherWinsV1 = true
    return cfg
end

-- A clean Text Designer config. TD has no Config.lua template — its
-- shape is owned by DF.TextDesigner:EnsureDB, so seed through that.
function DF:NewTextDesignerConfig()
    -- The baseline default a fresh/reset profile starts with: name + health
    -- (current/max) + status elements, carried by this factory rather than
    -- built by the legacy migration on load. See DF:BuildDefaultTextDesignerConfig
    -- (TextDesigner/Migration.lua). Party/raid share text defaults, so a single
    -- baseline is correct for both the Party and Raid presets it seeds.
    if DF.BuildDefaultTextDesignerConfig then
        return DF:BuildDefaultTextDesignerConfig("party")
    end
    if DF.TextDesigner and DF.TextDesigner.EnsureDB then
        return DF.TextDesigner:EnsureDB({})
    end
    return { enabled = false, hideLegacyText = false, nextElementID = 1,
             elements = {}, previewScale = 1.0, globalDefaults = {} }
end

-- ============================================================
-- LIBRARY ACCESSORS
-- Lazily create the library + the non-deletable "Default" entry.
-- Return nil only before the profile DB exists (very early boot).
-- ============================================================

function DF:GetAuraDesignerPresets()
    if not DF.db then return nil end
    local lib = DF.db.auraDesignerPresets
    if not lib then
        lib = {}
        DF.db.auraDesignerPresets = lib
    end
    if not lib[DF.DEFAULT_PRESET] then
        lib[DF.DEFAULT_PRESET] = DF:NewAuraDesignerConfig()
    end
    return lib
end

function DF:GetTextDesignerPresets()
    if not DF.db then return nil end
    local lib = DF.db.textDesignerPresets
    if not lib then
        lib = {}
        DF.db.textDesignerPresets = lib
    end
    if not lib[DF.DEFAULT_PRESET] then
        lib[DF.DEFAULT_PRESET] = DF:NewTextDesignerConfig()
    end
    return lib
end

-- The default preset name a given mode maps to when it has no explicit
-- assignment yet (party → "Party", raid → "Raid").
local function DefaultPresetNameForMode(mode)
    return mode == "raid" and "Raid" or "Party"
end
DF.DefaultPresetNameForMode = DefaultPresetNameForMode

-- Full-reset helper: rebuild both designer preset libraries with pristine
-- Default/Party/Raid presets. The libraries live at profile level, so the
-- per-mode DF:ResetProfile does NOT touch them — without this, edited Aura/
-- Text Designer presets survive a "Reset Profile to Defaults". User-created
-- presets are intentionally dropped by a full reset. We reseed distinct Party
-- and Raid presets (not just Default) so the two modes stay independent; the
-- mode preset refs are left as DF:ResetProfile set them (nil), and a nil ref
-- resolves to the mode's default-named preset ("Party"/"Raid") which we seed
-- here, so both modes render pristine immediately and refs backfill on the
-- next migration.
function DF:ResetDesignerPresets()
    if not DF.db then return end
    local function reseed(libKey, factory)
        local lib = {}
        lib[DF.DEFAULT_PRESET] = factory()
        for _, mode in ipairs({ "party", "raid" }) do
            lib[DefaultPresetNameForMode(mode)] = factory()
        end
        DF.db[libKey] = lib
    end
    reseed("auraDesignerPresets", function() return DF:NewAuraDesignerConfig() end)
    reseed("textDesignerPresets", function() return DF:NewTextDesignerConfig() end)
end

-- The table the EDITOR / baseline reads should resolve against. For raid this is
-- the REAL raid table (DF._realRaidDB), NOT the merged DF:GetDB("raid") proxy:
-- at runtime the proxy carries the active auto-layout's overlay, which would make
-- the designer editor follow (and edit) the active layout's preset instead of your
-- base raid. The real table is the base when not editing, and is temporarily the
-- layout's while you're IN "edit auto layout" (AutoProfiles applies the layout's
-- overrides to it for preview) — so the editor edits the base normally and the
-- layout only via edit-auto-layout, with no overlay leak. Party has no overlay.
-- NOTE: the live RENDER path (ResolveTextDesigner / ResolvePreset) is frame-based
-- and unchanged, so on-screen frames still reflect the active layout.
local function ModeBaseDB(mode)
    if mode == "raid" then return DF._realRaidDB or DF:GetDB("raid") end
    return DF:GetDB(mode)
end

-- ============================================================
-- RESOLVERS — frame → the designer config it should render with
-- ============================================================

-- Determine which config mode a frame belongs to. Pinned frames will
-- later resolve to their Based-on mode; for now that is handled by the
-- same isRaidFrame flag the rest of the frame system uses.
local function FrameMode(frame)
    if frame and DF.IsRaidFrame and DF:IsRaidFrame(frame) then
        return "raid"
    end
    return "party"
end

local function ResolvePreset(frame, lib, presetKey)
    if not lib then return nil end
    -- Explicit per-frame override stamp (used by the editor preview and,
    -- later, pinned sets) takes precedence over mode resolution.
    local override = frame and frame[presetKey == "auraDesignerPreset"
        and "dfAuraPresetOverride" or "dfTextPresetOverride"]
    if override and lib[override] then return lib[override] end

    local mode = FrameMode(frame)
    local modeDB = DF:GetDB(mode)
    local name = (modeDB and modeDB[presetKey]) or DefaultPresetNameForMode(mode)
    return lib[name] or lib[DF.DEFAULT_PRESET]
end

function DF:ResolveAuraDesigner(frame)
    local lib = DF:GetAuraDesignerPresets()
    if not lib then
        -- Pre-migration / very early: fall back to the legacy inline config.
        local db = DF.GetFrameDB and DF:GetFrameDB(frame)
        return db and db.auraDesigner or nil
    end
    return ResolvePreset(frame, lib, "auraDesignerPreset")
end

function DF:ResolveTextDesigner(frame)
    local lib = DF:GetTextDesignerPresets()
    if not lib then
        local db = DF.GetFrameDB and DF:GetFrameDB(frame)
        return db and db.textDesigner or nil
    end
    return ResolvePreset(frame, lib, "textDesignerPreset")
end

-- GetMode*Designer / *PresetName: the ACTIVE designer a mode resolves to right
-- now — read through the merged proxy, so a live raid auto-layout overlay IS
-- reflected. Used by LIVE consumers (SoundEngine, migrations) that must match
-- what's on screen. The EDITOR uses the GetModeBase* variants below instead, so
-- it edits your base raid preset rather than following the active layout.
function DF:GetModeAuraDesigner(mode)
    local lib = DF:GetAuraDesignerPresets()
    if not lib then return nil end
    local modeDB = DF:GetDB(mode)
    local name = (modeDB and modeDB.auraDesignerPreset) or DefaultPresetNameForMode(mode)
    return lib[name] or lib[DF.DEFAULT_PRESET], (name or DF.DEFAULT_PRESET)
end

function DF:GetModeTextDesigner(mode)
    local lib = DF:GetTextDesignerPresets()
    if not lib then return nil end
    local modeDB = DF:GetDB(mode)
    local name = (modeDB and modeDB.textDesignerPreset) or DefaultPresetNameForMode(mode)
    return lib[name] or lib[DF.DEFAULT_PRESET], (name or DF.DEFAULT_PRESET)
end

-- BASE variants — what the EDITOR binds to. Read ModeBaseDB (the real raid table,
-- not the merged proxy), so the designer editor references your base raid preset
-- and never follows a live auto-layout overlay. While IN edit-auto-layout the real
-- table is temporarily the layout's, so the editor correctly edits that layout
-- then. The live render path (ResolvePreset) and live consumers keep using the
-- active resolvers above, so on-screen frames still reflect the active layout.
function DF:GetModeBaseAuraDesigner(mode)
    local lib = DF:GetAuraDesignerPresets()
    if not lib then return nil end
    local modeDB = ModeBaseDB(mode)
    local name = (modeDB and modeDB.auraDesignerPreset) or DefaultPresetNameForMode(mode)
    return lib[name] or lib[DF.DEFAULT_PRESET], (name or DF.DEFAULT_PRESET)
end

function DF:GetModeBaseTextDesigner(mode)
    local lib = DF:GetTextDesignerPresets()
    if not lib then return nil end
    local modeDB = ModeBaseDB(mode)
    local name = (modeDB and modeDB.textDesignerPreset) or DefaultPresetNameForMode(mode)
    return lib[name] or lib[DF.DEFAULT_PRESET], (name or DF.DEFAULT_PRESET)
end

-- ============================================================
-- MIGRATION (lossless, all profiles)
-- Moves every inline auraDesigner / textDesigner config into the preset
-- library and points its owner at the preset by NAME:
--   * db.party / db.raid           → "Party" / "Raid" presets
--   * each raid auto-layout's       → a uniquely-named preset, with the
--     overrides.<designer> table       layout's override switched to the
--                                       string key <designer>Preset
-- The inline table is MOVED by reference (not copied) then cleared, so
-- there is exactly one canonical owner — no SavedVariables shared-ref
-- duplication, and the old whole-table-override path goes dormant (the
-- per-layout override is now a plain string the generic overlay handles).
-- Idempotent: guarded so re-runs on already-migrated profiles are no-ops.
-- ============================================================

-- Pick a library-unique preset name from a base label.
local function UniquePresetName(lib, base)
    base = (type(base) == "string" and base ~= "" and base) or "Layout"
    if not lib[base] then return base end
    local i = 2
    while lib[base .. " " .. i] do i = i + 1 end
    return base .. " " .. i
end

-- Invoke fn(overrideHolder) for every raid auto-layout entry that carries an
-- `overrides` table (instanced/openWorld arrays + the single mythic profile).
local function ForEachRaidLayoutOverride(profile, fn)
    local rap = profile.raidAutoProfiles
    if type(rap) ~= "table" then return end
    for _, ctKey in ipairs({ "instanced", "openWorld", "mythic" }) do
        local ct = rap[ctKey]
        if type(ct) == "table" then
            if type(ct.profiles) == "table" then
                for _, layout in pairs(ct.profiles) do
                    if type(layout) == "table" and type(layout.overrides) == "table" then
                        fn(layout)
                    end
                end
            end
            if type(ct.profile) == "table" and type(ct.profile.overrides) == "table" then
                fn(ct.profile)
            end
        end
    end
end

-- Deep value-equality for designer configs, IGNORING internal bookkeeping keys
-- (leading underscore, e.g. _specScopedV1/V2). Used to detect a per-layout
-- override that is just a stale full snapshot identical to the mode base — such
-- a redundant override should be dropped (the layout inherits the base) rather
-- than surfaced as a clutter preset.
local function DesignerConfigEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not (type(k) == "string" and k:sub(1, 1) == "_") then
            if not DesignerConfigEqual(v, b[k]) then return false end
        end
    end
    for k in pairs(b) do
        if not (type(k) == "string" and k:sub(1, 1) == "_") then
            if a[k] == nil then return false end
        end
    end
    return true
end

-- The preset a raid auto-layout would inherit if it had no override = whatever
-- the raid mode points at (default "Raid").
local function RaidBasePreset(profile, libKey, refKey)
    local lib = profile[libKey]
    if not lib then return nil end
    local raid = profile.raid
    local name = (raid and raid[refKey]) or "Raid"
    return lib[name]
end

local function MigrateDesigner(profile, libKey, refKey, inlineKey, factory)
    profile[libKey] = profile[libKey] or {}
    local lib = profile[libKey]
    if not lib[DF.DEFAULT_PRESET] then
        lib[DF.DEFAULT_PRESET] = factory()
    end

    -- Real party / raid → "Party" / "Raid" presets (materialised so the two
    -- modes stay independent even when a mode had no inline config, e.g.
    -- lazily-initialised Text Designer). ONLY on the profile's FIRST migration
    -- (_designerPresetsMigratedV1): the ADDON_LOADED defaults backfill re-seeds
    -- the inline default key every login, so an unguarded re-run would
    -- resurrect a "Party"/"Raid" preset the user deliberately renamed or
    -- deleted (ghost preset, returning after every cleanup attempt).
    if not profile._designerPresetsMigratedV1 then
        for _, mode in ipairs({ "party", "raid" }) do
            local modeDb = profile[mode]
            if modeDb then
                local presetName = DefaultPresetNameForMode(mode)
                if not lib[presetName] then
                    if modeDb[inlineKey] then
                        lib[presetName] = modeDb[inlineKey]   -- move existing config in
                        modeDb[inlineKey] = nil
                    else
                        lib[presetName] = factory()           -- materialise empty default
                    end
                elseif modeDb[inlineKey] then
                    modeDb[inlineKey] = nil                    -- preset exists; drop stray inline
                end
                if not modeDb[refKey] then
                    modeDb[refKey] = presetName
                end
            end
        end
    else
        -- Already migrated: just strip stray inline keys (defaults backfill /
        -- leftovers — genuine old-export imports are materialised by
        -- DF:ImportDesignerPresets at import time) and backfill a missing ref.
        for _, mode in ipairs({ "party", "raid" }) do
            local modeDb = profile[mode]
            if modeDb then
                if modeDb[inlineKey] then modeDb[inlineKey] = nil end
                if not modeDb[refKey] then
                    local presetName = DefaultPresetNameForMode(mode)
                    modeDb[refKey] = lib[presetName] and presetName or DF.DEFAULT_PRESET
                end
            end
        end
    end

    -- Raid auto-layout whole-table overrides → presets. A layout override that
    -- merely duplicates the mode base (a stale full snapshot from the old
    -- whole-table-override system) is dropped so the layout inherits the base,
    -- avoiding a clutter preset. Genuinely-different overrides become a
    -- uniquely-named preset the overlay resolves by name.
    local base = RaidBasePreset(profile, libKey, refKey)
    ForEachRaidLayoutOverride(profile, function(layout)
        local ovr = layout.overrides
        if ovr[inlineKey] then
            if base and DesignerConfigEqual(ovr[inlineKey], base) then
                ovr[inlineKey] = nil          -- redundant; inherit the base
            else
                local name = UniquePresetName(lib, layout.name)
                lib[name] = ovr[inlineKey]
                ovr[inlineKey] = nil
                ovr[refKey] = name
            end
        end
    end)
end

-- Is preset `name` still referenced by any consumer in this profile (party/raid
-- mode or a raid auto-layout override)? Used before pruning a redundant preset.
local function PresetReferenced(profile, refKey, name)
    if profile.party and profile.party[refKey] == name then return true end
    if profile.raid and profile.raid[refKey] == name then return true end
    -- Pinned sets carry per-set refs too (mirror ForEachDesignerRef) — without
    -- this the redundancy cleanup could prune a preset a pinned set still uses.
    for _, mode in ipairs({ "party", "raid" }) do
        local modeDb = profile[mode]
        local pf = modeDb and modeDb.pinnedFrames
        if pf and pf.sets then
            for _, set in pairs(pf.sets) do
                if type(set) == "table" and set[refKey] == name then return true end
            end
        end
    end
    local found = false
    ForEachRaidLayoutOverride(profile, function(layout)
        if layout.overrides[refKey] == name then found = true end
    end)
    return found
end

-- One-time cleanup for profiles migrated BEFORE the redundancy check existed:
-- a layout pointing at a layout-derived preset that deep-equals the mode base is
-- a stale snapshot — clear the override (inherit the base) and prune the preset
-- if nothing else references it. Genuinely-different layout presets are kept.
local function CleanupRedundantLayoutPresets(profile, libKey, refKey)
    local lib = profile[libKey]
    local base = RaidBasePreset(profile, libKey, refKey)
    if not lib or not base then return end
    local cleared = {}
    ForEachRaidLayoutOverride(profile, function(layout)
        local ovr = layout.overrides
        local name = ovr[refKey]
        if name and name ~= DF.DEFAULT_PRESET and name ~= "Party" and name ~= "Raid"
            and lib[name] and DesignerConfigEqual(lib[name], base) then
            ovr[refKey] = nil          -- inherit the mode base
            cleared[name] = true
        end
    end)
    for name in pairs(cleared) do
        if not PresetReferenced(profile, refKey, name) then
            lib[name] = nil            -- prune the now-orphaned redundant preset
        end
    end
end

function DF:MigrateDesignerPresets()
    if not DandersFramesDB_v2 or not DandersFramesDB_v2.profiles then return end
    for _, profile in pairs(DandersFramesDB_v2.profiles) do
        if type(profile) == "table" then
            MigrateDesigner(profile, "auraDesignerPresets", "auraDesignerPreset",
                "auraDesigner", function() return DF:NewAuraDesignerConfig() end)
            MigrateDesigner(profile, "textDesignerPresets", "textDesignerPreset",
                "textDesigner", function() return DF:NewTextDesignerConfig() end)
            -- Run the redundant-layout-preset cleanup ONCE per profile (so it
            -- tidies migration artifacts without later fighting a user who
            -- deliberately makes a layout preset identical to the base).
            if not profile._designerLayoutCleanupV1 then
                CleanupRedundantLayoutPresets(profile, "auraDesignerPresets", "auraDesignerPreset")
                CleanupRedundantLayoutPresets(profile, "textDesignerPresets", "textDesignerPreset")
                profile._designerLayoutCleanupV1 = true
            end
            -- Mark the profile migrated AFTER both designers ran, so the
            -- mode-materialisation block above never re-runs (ghost-preset
            -- guard) while the layout-override materialisation stays active
            -- for late-arriving inline overrides (old raidAutoProfiles imports).
            if not profile._designerPresetsMigratedV1 then
                profile._designerPresetsMigratedV1 = true
            end
        end
    end
end

-- ============================================================
-- IMPORT (profile export/import payloads)
-- The libraries live at PROFILE ROOT — the mode tables only carry preset
-- NAME strings post-migration — so an import that ignores them strands the
-- refs on the receiver's (or an empty) library and ALL AD/TD content is
-- silently lost. Called by Profile.lua after the mode tables are applied.
-- ============================================================

-- Apply the designer-preset parts of an imported payload to the CURRENT
-- profile. `categories` (optional array) gates by selected import category:
-- nil = import everything present. Handles both payload shapes:
--   * new exports: auraDesignerPresets/textDesignerPresets libraries travel —
--     MERGE into the current library (imported presets win on name clash, so
--     the imported refs resolve to the imported content);
--   * old pre-preset exports: inline auraDesigner/textDesigner tables inside
--     the imported mode tables — materialise each as the content of the
--     preset that mode points at (the login migration would otherwise DISCARD
--     them, because the "Party"/"Raid" presets already exist).
function DF:ImportDesignerPresets(importData, categories)
    if type(importData) ~= "table" then return end
    -- Operate on the REAL profile table — DF.db is a proxy whose .raid is the
    -- (non-enumerable) raid overlay proxy.
    local prof = DF._realProfile or DF.db
    if not prof then return end

    local wanted = nil
    if type(categories) == "table" then
        wanted = {}
        for _, cat in ipairs(categories) do wanted[cat] = true end
    end
    -- Pinned sets reference designer presets too, so a pinnedFrames-only import/
    -- export must carry the libraries or a set ends up pointing at a missing preset.
    -- ("text" kept alongside "textDesigner" for pre-restructure export strings,
    -- whose category list bundled the Text Designer under Text.)
    local importAura = (not wanted) or wanted.auraDesigner or wanted.autoLayout or wanted.pinnedFrames
    local importText = (not wanted) or wanted.textDesigner or wanted.text or wanted.autoLayout or wanted.pinnedFrames

    local function mergeLib(libKey, src)
        if type(src) ~= "table" then return end
        prof[libKey] = prof[libKey] or {}
        local lib = prof[libKey]
        for name, preset in pairs(src) do
            if type(name) == "string" and type(preset) == "table" then
                lib[name] = preset
            end
        end
    end
    if importAura then mergeLib("auraDesignerPresets", importData.auraDesignerPresets) end
    if importText then mergeLib("textDesignerPresets", importData.textDesignerPresets) end

    -- Old-export inline designer tables → the mode's preset content.
    local function materialize(libKey, refKey, inlineKey)
        for _, mode in ipairs({ "party", "raid" }) do
            local modeDb = prof[mode]
            local inline = modeDb and modeDb[inlineKey]
            if type(inline) == "table" then
                prof[libKey] = prof[libKey] or {}
                local name = modeDb[refKey] or DefaultPresetNameForMode(mode)
                if name == DF.DEFAULT_PRESET then
                    -- Never overwrite the protected empty Default — give the
                    -- imported content the mode's conventional name instead.
                    name = DefaultPresetNameForMode(mode)
                end
                prof[libKey][name] = inline   -- imported content wins
                modeDb[refKey] = name
                modeDb[inlineKey] = nil
            end
        end
    end
    if importAura then materialize("auraDesignerPresets", "auraDesignerPreset", "auraDesigner") end
    if importText then materialize("textDesignerPresets", "textDesignerPreset", "textDesigner") end
end

-- ============================================================
-- PRESET MANAGEMENT API (editor preset bar — Phase 2)
-- Library is per-profile (DF.db.<lib>); references are per-mode strings the
-- editor / consumers resolve by name. Operations update the current profile's
-- references only (party / raid / raid auto-layout overrides — pinned sets join
-- later). "Default" is non-deletable and non-renamable.
-- ============================================================

local DESIGNER_KINDS = {
    aura = { lib = "auraDesignerPresets", ref = "auraDesignerPreset" },
    text = { lib = "textDesignerPresets", ref = "textDesignerPreset" },
}

local function GetKindLib(kind)
    if kind == "aura" then return DF:GetAuraDesignerPresets() end
    return DF:GetTextDesignerPresets()
end

local function NewKindConfig(kind)
    if kind == "aura" then return DF:NewAuraDesignerConfig() end
    return DF:NewTextDesignerConfig()
end

-- Invoke fn(tbl) for every table in the CURRENT profile that holds a designer
-- preset reference under refKey: party, raid (real), and each raid auto-layout
-- override. (Pinned-set references will be added with the pinned integration.)
-- fn(tbl, holder) — holder names what kind of ref carrier tbl is:
--   "mode"     = a party/raid mode db (must always point at SOME preset)
--   "pinned"   = a pinned set (nil ref = inherit the mode's preset)
--   "layout"   = a raid auto-layout override table (nil ref = inherit base)
--   "snapshot" = the edit-auto-layout globalSnapshot (restored verbatim on exit)
local function ForEachDesignerRef(fn)
    local prof = DF._realProfile or DF.db
    if not prof then return end
    -- Each mode DB owns a ref (modeDB.<kind>Preset) AND every pinned set can carry
    -- its own per-set ref (set.<kind>Preset) — visit both so rename/delete repoint
    -- pinned selections too.
    local function withPinned(modeDB)
        if not modeDB then return end
        fn(modeDB, "mode")
        local pf = modeDB.pinnedFrames
        if pf and pf.sets then
            for _, set in pairs(pf.sets) do
                if type(set) == "table" then fn(set, "pinned") end
            end
        end
    end
    withPinned(prof.party)
    withPinned(DF._realRaidDB or prof.raid)
    ForEachRaidLayoutOverride(prof, function(layout) fn(layout.overrides, "layout") end)
    -- During edit-auto-layout the TRUE base ref lives in the editing snapshot
    -- (ExitEditing restores every snapshot key into _realRaidDB) — repoint it
    -- too, or exiting re-installs a renamed/deleted name as the raid base.
    local apu = DF.AutoProfilesUI
    if apu and apu.globalSnapshot then fn(apu.globalSnapshot, "snapshot") end
end

-- Pinned frames stamp their per-frame preset overrides (dfAuraPresetOverride/
-- dfTextPresetOverride) at apply time — after a rename/delete repoints the set
-- tables, re-apply so the stamps don't go stale until the next roster apply.
-- Also invalidate the GUI page caches: cached pages (notably the Pinned Frames
-- page's per-set preset dropdowns) display the OLD name until rebuilt.
local function RestampPinnedPresets()
    local pf = DF.PinnedFrames
    if pf and pf.initialized then
        for i = 1, (pf.MAX_SETS or 4) do
            if pf.ApplyLayoutSettings then pf:ApplyLayoutSettings(i) end
        end
    end
    if DF.GUI and DF.GUI.InvalidateAllPages then
        DF.GUI:InvalidateAllPages()
    end
end

-- Sorted preset-name list for a dropdown ("Default" pinned first).
function DF:ListDesignerPresets(kind)
    local names = {}
    local lib = GetKindLib(kind)
    if lib then
        for name in pairs(lib) do
            if name ~= DF.DEFAULT_PRESET then names[#names + 1] = name end
        end
        table.sort(names)
        table.insert(names, 1, DF.DEFAULT_PRESET)
    end
    return names
end

-- Create a fresh (default) preset under a library-unique name. Returns the name.
function DF:CreateDesignerPreset(kind, name)
    local lib = GetKindLib(kind)
    if not lib then return nil end
    -- Empty string from the name popup → sensible base (UniquePresetName's own
    -- fallback is the migration label "Layout", which reads wrong here).
    if type(name) ~= "string" or name == "" then name = "Preset" end
    name = UniquePresetName(lib, name)
    lib[name] = NewKindConfig(kind)
    return name
end

-- Deep-copy an existing preset under a new unique name. Returns the new name.
function DF:DuplicateDesignerPreset(kind, srcName, newName)
    local lib = GetKindLib(kind)
    if not lib or not lib[srcName] then return nil end
    newName = UniquePresetName(lib, newName or (srcName .. " copy"))
    lib[newName] = DF:DeepCopy(lib[srcName])
    return newName
end

-- Rename a preset and re-point every reference to it. Returns the final name,
-- or false if the rename can't proceed (Default / missing). The name is
-- uniquified, so the result may differ from newName.
function DF:RenameDesignerPreset(kind, oldName, newName)
    if oldName == DF.DEFAULT_PRESET then return false end
    local lib = GetKindLib(kind)
    if not lib or not lib[oldName] then return false end
    -- Empty string from the name popup → keep the old name (no-op rename).
    if type(newName) ~= "string" or newName == "" then newName = oldName end
    -- Uniquify against the library WITHOUT counting the entry being renamed.
    local saved = lib[oldName]
    lib[oldName] = nil
    newName = UniquePresetName(lib, newName)
    lib[newName] = saved
    if newName ~= oldName then
        local refKey = DESIGNER_KINDS[kind].ref
        ForEachDesignerRef(function(t)
            if t[refKey] == oldName then t[refKey] = newName end
        end)
        RestampPinnedPresets()
    end
    return newName
end

-- Delete a preset. Mode dbs (which must always point somewhere) fall back to
-- "Default"; layout overrides and pinned sets have their ref CLEARED instead —
-- their natural deleted-semantics is "revert to inherit", not a hard override
-- onto the empty Default (which would render no designer content even though
-- the base preset is fine). Returns true on success (false Default / missing).
function DF:DeleteDesignerPreset(kind, name)
    if name == DF.DEFAULT_PRESET then return false end
    local lib = GetKindLib(kind)
    if not lib or not lib[name] then return false end
    lib[name] = nil
    local refKey = DESIGNER_KINDS[kind].ref
    ForEachDesignerRef(function(t, holder)
        if t[refKey] == name then
            if holder == "mode" or holder == "snapshot" then
                t[refKey] = DF.DEFAULT_PRESET
            else
                t[refKey] = nil   -- layout / pinned: inherit again
            end
        end
    end)
    RestampPinnedPresets()
    return true
end

-- The preset NAME a mode's EDITOR currently resolves to. Reads ModeBaseDB (the
-- real raid table, not the merged proxy) so an active runtime auto-layout overlay
-- doesn't masquerade as the base — the editor references your base raid preset
-- unless you're IN "edit auto layout" (where the real table is the layout's).
function DF:GetModeDesignerPresetName(kind, mode)
    local refKey = DESIGNER_KINDS[kind] and DESIGNER_KINDS[kind].ref
    if not refKey then return DF.DEFAULT_PRESET end
    local modeDB = ModeBaseDB(mode)
    return (modeDB and modeDB[refKey]) or DefaultPresetNameForMode(mode)
end

-- Point a mode at a preset by name. Raid writes go to the real raid table so
-- that, while a raid auto-layout is being edited, the AutoProfiles save-diff
-- captures it as a per-layout override of the preset NAME.
function DF:SetModeDesignerPreset(kind, mode, name)
    local refKey = DESIGNER_KINDS[kind].ref
    if mode == "raid" then
        local raid = DF._realRaidDB or (DF.db and DF.db.raid)
        if raid then raid[refKey] = name end
        -- While editing a raid auto-layout, also record an explicit override so
        -- the dropdown reflects the chosen preset (not "Inherit") even when its
        -- name happens to equal the global preset's. Inherit detection is based
        -- on this override's presence, not on name equality.
        local apu = DF.AutoProfilesUI
        if apu and apu.IsEditing and apu:IsEditing() and apu.editingProfile then
            apu.editingProfile.overrides = apu.editingProfile.overrides or {}
            apu.editingProfile.overrides[refKey] = name
        end
    else
        local prof = DF._realProfile or DF.db
        if prof and prof[mode] then prof[mode][refKey] = name end
    end
end

-- While editing a raid auto-layout: is the layout currently INHERITING the
-- global designer preset? True when the layout has NO stored preset override —
-- based on override presence, NOT name equality, so explicitly picking a preset
-- whose name equals the global still reads as an override (shows its name).
function DF:IsLayoutDesignerInheriting(kind)
    local apu = DF.AutoProfilesUI
    if not (apu and apu.IsEditing and apu:IsEditing()) then return false end
    local refKey = DESIGNER_KINDS[kind] and DESIGNER_KINDS[kind].ref
    if not refKey then return false end
    local ovr = apu.editingProfile and apu.editingProfile.overrides
    return not (ovr and ovr[refKey] ~= nil)
end

-- While editing a raid auto-layout: clear the layout's designer-preset override
-- so the layout follows the global preset (the "Inherit (Global)" action; mirrors
-- the old Reset-to-Global). Drops any stored override and sets the live raid
-- value back to the snapshot global, so the save-diff records no override.
function DF:InheritLayoutDesignerPreset(kind)
    local apu = DF.AutoProfilesUI
    if not (apu and apu.IsEditing and apu:IsEditing()) then return end
    local refKey = DESIGNER_KINDS[kind] and DESIGNER_KINDS[kind].ref
    if not refKey then return end
    if apu.editingProfile and apu.editingProfile.overrides then
        apu.editingProfile.overrides[refKey] = nil
    end
    local glob = apu.globalSnapshot and apu.globalSnapshot[refKey]
    if DF._realRaidDB then DF._realRaidDB[refKey] = glob end
end
