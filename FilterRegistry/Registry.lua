local addonName, DF = ...

-- ============================================================
-- FILTER REGISTRY — STORAGE, CRUD, OVERRIDES
-- Custom filters: account-wide (DandersFramesDB_v2.global.auraFilters),
-- keyed by stable ids ("cf1", "cf2", ...) that are never reused.
-- Preset overrides: per-profile (DF.db.filterPresetOverrides),
-- storing ONLY diffs from the shipped defaultEnabled flags.
-- ============================================================

local pairs, ipairs, type, next = pairs, ipairs, type, next
local format = string.format

DF.FilterRegistry = DF.FilterRegistry or {}
local R = DF.FilterRegistry

-- ------------------------------------------------------------
-- ACCOUNT-WIDE STORE
-- ------------------------------------------------------------
function R:GetStore()
    local g = DF:GetGlobalDB()
    if not g.auraFilters then
        g.auraFilters = { nextFilterID = 1, customFilters = {} }
    end
    g.auraFilters.customFilters = g.auraFilters.customFilters or {}
    g.auraFilters.nextFilterID = g.auraFilters.nextFilterID or 1
    return g.auraFilters
end

function R:GetCustomFilter(id)
    return self:GetStore().customFilters[id]
end

function R:CreateCustomFilter(name)
    local store = self:GetStore()
    local id = "cf" .. store.nextFilterID
    store.nextFilterID = store.nextFilterID + 1
    store.customFilters[id] = { name = name, spells = {}, rawIDs = {} }
    return id
end

function R:DeleteCustomFilter(id)
    self:GetStore().customFilters[id] = nil
end

function R:RenameCustomFilter(id, name)
    local f = self:GetCustomFilter(id)
    if f then f.name = name end
end

-- srcRef: a preset key (copies its currently-ENABLED spells) or a custom id
function R:DuplicateFilter(srcRef, name)
    local id = self:CreateCustomFilter(name)
    local dst = self:GetCustomFilter(id)
    local src = self:GetCustomFilter(srcRef)
    if src then
        for sid in pairs(src.spells) do dst.spells[sid] = true end
        for rid in pairs(src.rawIDs) do dst.rawIDs[rid] = true end
    elseif R.ByCategory[srcRef] then
        for _, rec in ipairs(R.ByCategory[srcRef]) do
            if self:IsSpellEnabled(srcRef, rec) then dst.spells[rec.id] = true end
        end
    end
    return id
end

-- Returns "spell" (known — snapped to canonical), "raw" (unknown id), or "exists"
function R:AddSpellToCustom(id, spellID)
    local f = self:GetCustomFilter(id)
    if not f then return end
    spellID = tonumber(spellID)
    if not spellID then return end
    local rec = R.ByID[spellID]
    if rec then
        if f.spells[rec.id] then return "exists" end
        f.spells[rec.id] = true
        return "spell"
    end
    if f.rawIDs[spellID] then return "exists" end
    f.rawIDs[spellID] = true
    return "raw"
end

function R:RemoveSpellFromCustom(id, spellID)
    local f = self:GetCustomFilter(id)
    if not f then return end
    f.spells[spellID] = nil
    f.rawIDs[spellID] = nil
end

-- ------------------------------------------------------------
-- IMPORT MERGE (profile import embeds custom filter snapshots)
-- Content = spells + rawIDs; the name is deliberately ignored, so a
-- content-equal local filter is reused even if it was renamed. The
-- content scan covers the WHOLE store (not just the same id) so
-- re-importing a string never duplicates filters: a filter that
-- landed under a fresh id on the first import is found by content
-- on the second. Anything without a content match imports under a
-- fresh id. Returns an oldId -> newId map for remapping the
-- imported selection tables.
-- ------------------------------------------------------------
local function setsEqual(x, y)
    for k in pairs(x) do if not y[k] then return false end end
    for k in pairs(y) do if not x[k] then return false end end
    return true
end

local function sameContent(a, b)
    return setsEqual(a.spells or {}, b.spells or {})
        and setsEqual(a.rawIDs or {}, b.rawIDs or {})
end

function R:ImportCustomFilters(imported)
    local store = self:GetStore()
    local remap = {}
    for cfId, def in pairs(imported) do
        local existing = store.customFilters[cfId]
        if existing and sameContent(existing, def) then
            remap[cfId] = cfId
        else
            local reuse
            for otherId, other in pairs(store.customFilters) do
                if sameContent(other, def) then
                    reuse = otherId
                    break
                end
            end
            if reuse then
                remap[cfId] = reuse
            else
                local newId = self:CreateCustomFilter(def.name or cfId)
                local dst = store.customFilters[newId]
                for sid in pairs(def.spells or {}) do dst.spells[sid] = true end
                for rid in pairs(def.rawIDs or {}) do dst.rawIDs[rid] = true end
                remap[cfId] = newId
            end
        end
    end
    return remap
end

-- ------------------------------------------------------------
-- PER-PROFILE PRESET OVERRIDES (diff-only)
-- ------------------------------------------------------------
function R:GetOverrides()
    DF.db.filterPresetOverrides = DF.db.filterPresetOverrides or {}
    return DF.db.filterPresetOverrides
end

function R:IsSpellEnabled(presetKey, rec)
    local o = self:GetOverrides()[presetKey]
    if o and o[rec.id] ~= nil then return o[rec.id] end
    return not rec.off
end

function R:SetSpellEnabled(presetKey, rec, enabled)
    local overrides = self:GetOverrides()
    local o = overrides[presetKey]
    local default = not rec.off
    if enabled == default then
        if o then
            o[rec.id] = nil
            if not next(o) then overrides[presetKey] = nil end
        end
    else
        if not o then o = {}; overrides[presetKey] = o end
        o[rec.id] = enabled
    end
end

function R:ResetPreset(presetKey)
    self:GetOverrides()[presetKey] = nil
end

function R:IsPresetModified(presetKey)
    local o = self:GetOverrides()[presetKey]
    return o ~= nil and next(o) ~= nil
end

function R:PresetCounts(presetKey)
    local recs = R.ByCategory[presetKey]
    if not recs then return 0, 0 end
    local enabled = 0
    for _, rec in ipairs(recs) do
        if self:IsSpellEnabled(presetKey, rec) then enabled = enabled + 1 end
    end
    return enabled, #recs
end

-- ------------------------------------------------------------
-- DISPLAY (runtime name/icon with shipped fallback)
-- ------------------------------------------------------------
local FALLBACK_ICON = 134400 -- question mark
function R:GetSpellDisplay(rec)
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(rec.id)
    local icon = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(rec.id)
    if type(name) ~= "string" or name == "" then name = rec.n end
    if type(icon) ~= "number" then icon = FALLBACK_ICON end
    return name, icon
end

-- ------------------------------------------------------------
-- RESOLVER
-- Selection -> exactly one candidateFilters spell-ID map.
-- include: union of all variant IDs of every effectively-enabled
--   selected spell. exclude (Uncategorised on): union of all variant
--   IDs of every KNOWN spell that is NOT selected — complement math
--   keeps it one container group.
-- ------------------------------------------------------------
local function addRecordIDs(map, rec)
    map[rec.id] = true
    if rec.alts then
        for _, alt in ipairs(rec.alts) do map[alt] = true end
    end
end

-- Is this record effectively selected by the selection?
local function recordSelected(self, rec, selection)
    if selection.presets then
        for catKey in pairs(rec.cats) do
            if selection.presets[catKey] and self:IsSpellEnabled(catKey, rec) then
                return true
            end
        end
    end
    if selection.customs then
        for cfId in pairs(selection.customs) do
            local f = self:GetCustomFilter(cfId)
            if f and f.spells[rec.id] then return true end
        end
    end
    return false
end

function R:ResolveSelection(selection, showAll)
    if showAll or not selection then return { kind = "all" } end
    local anySel = (selection.presets and next(selection.presets))
        or (selection.customs and next(selection.customs))
    if not anySel and not selection.uncategorised then
        return { kind = "all" } -- nothing selected: safe fallback
    end

    if selection.uncategorised then
        local map = {}
        for _, rec in ipairs(R.Spells) do
            if not recordSelected(self, rec, selection) then
                addRecordIDs(map, rec)
            end
        end
        -- Raw IDs from UNSELECTED custom filters are known-but-unselected too
        for cfId, f in pairs(self:GetStore().customFilters) do
            if not (selection.customs and selection.customs[cfId]) then
                for rid in pairs(f.rawIDs) do map[rid] = true end
            end
        end
        -- ...but never exclude a raw ID that a SELECTED custom also carries
        if selection.customs then
            for cfId in pairs(selection.customs) do
                local f = self:GetCustomFilter(cfId)
                if f then for rid in pairs(f.rawIDs) do map[rid] = nil end end
            end
        end
        return { kind = "exclude", map = map }
    end

    local map = {}
    if selection.presets then
        for catKey in pairs(selection.presets) do
            local recs = R.ByCategory[catKey]
            if recs then
                for _, rec in ipairs(recs) do
                    if self:IsSpellEnabled(catKey, rec) then addRecordIDs(map, rec) end
                end
            end
        end
    end
    if selection.customs then
        for cfId in pairs(selection.customs) do
            local f = self:GetCustomFilter(cfId)
            if f then
                for sid in pairs(f.spells) do
                    local rec = R.ByID[sid]
                    if rec then addRecordIDs(map, rec) else map[sid] = true end
                end
                for rid in pairs(f.rawIDs) do map[rid] = true end
            end
        end
    end
    return { kind = "include", map = map }
end

-- Stable signature: kind + sorted ids. Structural rebuilds key off this.
local sigIDs = {}
function R:SelectionSignature(selection, showAll)
    local res = self:ResolveSelection(selection, showAll)
    if res.kind == "all" then return "all" end
    local n = 0
    for id in pairs(res.map) do n = n + 1; sigIDs[n] = id end
    for i = #sigIDs, n + 1, -1 do sigIDs[i] = nil end
    table.sort(sigIDs)
    return res.kind .. ":" .. table.concat(sigIDs, ",")
end
