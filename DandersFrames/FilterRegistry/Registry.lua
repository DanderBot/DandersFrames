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

-- ☠ SPELL IDS ARE 32-BIT. This is the real ceiling, and it is not a style choice:
-- string.format("%d", n) throws "integer overflow attempting to store <n>" for anything
-- above it, so an id past this point cannot even be DISPLAYED, let alone looked up.
--
-- Both add-by-ID boxes used to cap on DIGIT COUNT (`#text > 10`) instead, and 2147483647
-- is itself ten digits -- so every id from 2147483648 to 9999999999 passed the guard and
-- then blew up when the list tried to render it. That is exactly why #1111111111 was
-- accepted quietly and #2222222222 errored (Aphoex, alpha 15). Cap on VALUE.
R.MAX_SPELL_ID = 2147483647   -- 2^31 - 1

-- Render a spell id for display. Never use "%d" on an id that came from STORAGE: the
-- input cap above cannot protect an id that arrived in an imported filter string or was
-- already saved before the cap existed, and those still have to draw rather than error.
function R:FormatSpellID(id)
    id = tonumber(id)
    if not id then return "?" end
    if id % 1 == 0 and id >= -2147483648 and id <= R.MAX_SPELL_ID then
        return format("%d", id)
    end
    return format("%.0f", id)   -- out of int range: print in full, never in exponent form
end

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
    local f = self:GetStore().customFilters[id]
    if f then
        -- Self-heal the shape: ResolveSelection / DuplicateFilter /
        -- CustomSpellCount assume both subtables exist, but a hand-edited or
        -- older-alpha store can carry a filter without them (sameContent is
        -- the only defensive reader). Persisting the empty tables is harmless.
        f.spells = f.spells or {}
        f.rawIDs = f.rawIDs or {}
    end
    return f
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

-- ref: a custom id (copies its stored sets) or a preset key (FLATTENS the preset
-- to its currently-ENABLED records). Returns two FRESH tables, so callers own
-- them outright and can hand them straight to a filter without aliasing the
-- store. Returns nil for a ref that is neither (e.g. the debuff blacklist, which
-- is a per-mode db set rather than a registry filter).
--
-- Shared by DuplicateFilter and BuildFilterPayload so "what a filter reference
-- resolves to" has exactly one definition — duplicate and export must not drift.
function R:ResolveFilterContent(ref)
    local spells, rawIDs = {}, {}
    local src = self:GetCustomFilter(ref)
    if src then
        for sid in pairs(src.spells) do spells[sid] = true end
        for rid in pairs(src.rawIDs) do rawIDs[rid] = true end
        return spells, rawIDs
    end
    if R.ByCategory[ref] then
        for _, rec in ipairs(R.ByCategory[ref]) do
            if self:IsSpellEnabled(ref, rec) then spells[rec.id] = true end
        end
        return spells, rawIDs
    end
    return nil
end

-- srcRef: a preset key (copies its currently-ENABLED spells) or a custom id
function R:DuplicateFilter(srcRef, name)
    local id = self:CreateCustomFilter(name)
    local dst = self:GetCustomFilter(id)
    local spells, rawIDs = self:ResolveFilterContent(srcRef)
    if spells then
        dst.spells, dst.rawIDs = spells, rawIDs
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

-- Numeric sort for "cfN" ids so the import scan is deterministic — pairs()
-- order otherwise decides which local filter a content-equal import reuses
-- (and which imported name wins on create), and the winner is written into
-- saved selections.
local function cfIdLess(a, b)
    local na = tonumber(tostring(a):match("^cf(%d+)$"))
    local nb = tonumber(tostring(b):match("^cf(%d+)$"))
    if na and nb then return na < nb end
    if na ~= nil or nb ~= nil then return na ~= nil end
    return tostring(a) < tostring(b)
end

-- Content-based reuse needs actual content: setsEqual({}, {}) is true and ids
-- are "cf1", "cf2", ... on every account, so without the hasContent guard any
-- imported EMPTY filter silently became any local empty filter — and spells
-- added to "it" later changed the other selection's meaning. Empty filters only
-- reuse an empty filter with the SAME name.
--
-- nil-safe on `other` so callers can pass a possibly-absent store entry.
local function contentMatches(other, def, hasContent)
    if not other then return false end
    if not sameContent(other, def) then return false end
    if hasContent then return true end
    return (other.name or "") == (def.name or "")
end

local function defHasContent(def)
    return next(def.spells or {}) ~= nil or next(def.rawIDs or {}) ~= nil
end

-- The id of a content-equal local filter, or nil. Single-filter import uses this
-- to DETECT a collision and ask the user, rather than silently reusing the way
-- profile import does — see ImportFilterPayload.
function R:FindContentMatch(def)
    local store = self:GetStore()
    local hasContent = defHasContent(def)
    local ids = {}
    for cfId in pairs(store.customFilters) do ids[#ids + 1] = cfId end
    table.sort(ids, cfIdLess)
    for _, otherId in ipairs(ids) do
        if contentMatches(store.customFilters[otherId], def, hasContent) then
            return otherId
        end
    end
    return nil
end

function R:ImportCustomFilters(imported)
    local store = self:GetStore()
    local remap = {}
    local importIds, storeIds = {}, {}
    for cfId in pairs(imported) do importIds[#importIds + 1] = cfId end
    for otherId in pairs(store.customFilters) do storeIds[#storeIds + 1] = otherId end
    table.sort(importIds, cfIdLess)
    table.sort(storeIds, cfIdLess)

    for _, cfId in ipairs(importIds) do
        local def = imported[cfId]
        local hasContent = defHasContent(def)
        if contentMatches(store.customFilters[cfId], def, hasContent) then
            remap[cfId] = cfId
        else
            local reuse
            for _, otherId in ipairs(storeIds) do
                if contentMatches(store.customFilters[otherId], def, hasContent) then
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
                -- Later payload entries with the same content collapse onto
                -- this one (pre-sort behaviour, now deterministic).
                storeIds[#storeIds + 1] = newId
            end
        end
    end
    return remap
end

-- ------------------------------------------------------------
-- SINGLE-FILTER EXPORT / IMPORT
-- Shares ONE filter as a string, without dragging a whole profile along.
-- Same encode chain as the profile and click-casting exports:
--   LibSerialize -> CompressDeflate -> EncodeForPrint, behind a prefix.
--
-- Payload v1: { v, name, spells = {[id]=true}, rawIDs = {[id]=true} }
-- ------------------------------------------------------------
local FILTER_PREFIX  = "!DFF1!"          -- DandersFrames Filter v1
local FILTER_VERSION = 1
local MAX_IMPORT_IDS = 2000              -- sanity bound on a pasted payload
local MAX_NAME_LEN   = 40                -- matches GUI:PromptName's maxLetters

-- A string carrying one of these is a valid export of the WRONG kind. Worth
-- naming precisely — "that isn't a filter string" sends someone hunting for a
-- corruption that isn't there when they simply pasted into the wrong box.
local FOREIGN_PREFIXES = {
    ["!DFP1!"] = "profile",
    ["!DF1!"]  = "profile",
    ["!DF2!"]  = "profile",
    ["!DF3!"]  = "profile",
    ["!DFC1!"] = "clickcasting",
    ["!DFW1!"] = "wizard",
}

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- An imported name is untrusted text that lands in a list row. Strip colour
-- escapes and control characters so it can't inject formatting, then clamp to
-- the same length the rename prompt enforces.
local function sanitizeName(name)
    name = tostring(name or "")
    name = name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("||", ""):gsub("|", "")
    name = name:gsub("%c", "")
    name = trim(name)
    if #name > MAX_NAME_LEN then name = name:sub(1, MAX_NAME_LEN) end
    return name
end

local function getLibs()
    local LibSerialize = LibStub and LibStub("LibSerialize", true)
    local LibDeflate = LibStub and LibStub("LibDeflate", true)
    if not LibSerialize or not LibDeflate then return nil end
    return LibSerialize, LibDeflate
end

-- Re-derive the spells/rawIDs split against THIS client's spell database.
--
-- The split is relative to whoever exported: AddSpellToCustom files an id under
-- spells when R.ByID resolves it and under rawIDs when it doesn't, so two users
-- on different addon versions bucket the same id differently. Trusting the
-- sender's split would leave an id we DO know sitting in rawIDs, skipping the
-- canonical-id snap (rec.id) — the filter would quietly match differently for
-- the receiver than it did for the sender. Profile import doesn't need this
-- (same account, same build); cross-user sharing does.
function R:BucketIDs(ids)
    local spells, rawIDs = {}, {}
    for id in pairs(ids) do
        local rec = R.ByID[id]
        if rec then spells[rec.id] = true else rawIDs[id] = true end
    end
    return spells, rawIDs
end

-- ref: a custom id or a preset key. name: the display name to travel with the
-- payload (the caller owns localisation — presets are named by locale key).
function R:BuildFilterPayload(ref, name)
    local spells, rawIDs = self:ResolveFilterContent(ref)
    if not spells then return nil end
    return { v = FILTER_VERSION, name = sanitizeName(name), spells = spells, rawIDs = rawIDs }
end

-- Returns the export string, or nil + an error key.
function R:ExportFilter(ref, name)
    local payload = self:BuildFilterPayload(ref, name)
    if not payload then return nil, "noSelection" end
    local LibSerialize, LibDeflate = getLibs()
    if not LibSerialize then return nil, "libs" end
    local ok, serialized = pcall(LibSerialize.Serialize, LibSerialize, payload)
    if not ok or not serialized then return nil, "encode" end
    local compressed = LibDeflate:CompressDeflate(serialized)
    if not compressed then return nil, "encode" end
    local encoded = LibDeflate:EncodeForPrint(compressed)
    if not encoded then return nil, "encode" end
    return FILTER_PREFIX .. encoded
end

-- Returns a def ({name, spells, rawIDs}) already re-bucketed for THIS client,
-- or nil + an error key. Everything here is untrusted: the string was pasted
-- from Discord.
function R:DecodeFilterString(str)
    if type(str) ~= "string" then return nil, "notFilter" end
    str = trim(str)
    if str == "" then return nil, "notFilter" end

    if str:sub(1, #FILTER_PREFIX) ~= FILTER_PREFIX then
        for prefix, kind in pairs(FOREIGN_PREFIXES) do
            if str:sub(1, #prefix) == prefix then return nil, kind end
        end
        return nil, "notFilter"
    end

    local LibSerialize, LibDeflate = getLibs()
    if not LibSerialize then return nil, "libs" end

    local compressed = LibDeflate:DecodeForPrint(str:sub(#FILTER_PREFIX + 1))
    if not compressed then return nil, "corrupt" end
    local serialized = LibDeflate:DecompressDeflate(compressed)
    if not serialized then return nil, "corrupt" end
    local ok, payload = LibSerialize:Deserialize(serialized)
    if not ok or type(payload) ~= "table" then return nil, "corrupt" end

    -- Forward compat: a v2 payload may carry fields that change what the filter
    -- MEANS, so importing it as v1 would silently build the wrong filter.
    local v = tonumber(payload.v) or 1
    if v > FILTER_VERSION then return nil, "newer" end

    if payload.spells ~= nil and type(payload.spells) ~= "table" then return nil, "corrupt" end
    if payload.rawIDs ~= nil and type(payload.rawIDs) ~= "table" then return nil, "corrupt" end

    -- Flatten both buckets into one id set — the sender's split is discarded
    -- (see BucketIDs). Non-numeric keys are skipped rather than fatal: one bad
    -- key shouldn't cost the user the other 40 spells.
    local ids, count = {}, 0
    local function collect(t)
        if type(t) ~= "table" then return true end
        for k in pairs(t) do
            local n = tonumber(k)
            if n and not ids[n] then
                count = count + 1
                if count > MAX_IMPORT_IDS then return false end
                ids[n] = true
            end
        end
        return true
    end
    if not collect(payload.spells) then return nil, "tooLarge" end
    if not collect(payload.rawIDs) then return nil, "tooLarge" end

    local name = sanitizeName(payload.name)
    if name == "" then return nil, "corrupt" end

    local spells, rawIDs = self:BucketIDs(ids)
    return { name = name, spells = spells, rawIDs = rawIDs }
end

-- ------------------------------------------------------------
-- NAME COLLISIONS
-- ------------------------------------------------------------
-- Filter names are NOT unique, and deliberately stay that way: New, Rename and
-- Duplicate all let you pick whatever you like, and people have deliberately
-- similar names saved. What matters is that you SEE the name before it is
-- committed. Duplicate does — it pre-fills "<name> copy" and prompts. Import did
-- not, so a shared string could silently add a second row indistinguishable from
-- one you already had; field-reported, and worst through "Import as Copy", the
-- option whose whole promise is a copy you can tell apart.
--
-- These exist so the import path can ask ONLY when it needs to, leaving a clean
-- import (no clash) with no extra step.
function R:IsCustomFilterNameTaken(name, exceptID)
    if not name or name == "" then return false end
    for id, f in pairs(self:GetStore().customFilters or {}) do
        if id ~= exceptID and f.name == name then return true end
    end
    return false
end

-- "X" -> "X copy" -> "X copy 2" ... reusing Duplicate's suffix so both paths
-- produce names in the same shape. Bounded rather than while-true: a pathological
-- store should degrade to a duplicate name, not hang the client.
function R:SuggestUniqueFilterName(name)
    if not self:IsCustomFilterNameTaken(name) then return name end
    local base = name .. " copy"
    if not self:IsCustomFilterNameTaken(base) then return base end
    for n = 2, 99 do
        local candidate = base .. " " .. n
        if not self:IsCustomFilterNameTaken(candidate) then return candidate end
    end
    return base
end

-- ALWAYS creates. Collision handling is the caller's call — a deliberate share
-- should surface "you already have this" and let the user choose, where profile
-- import silently reuses (ImportCustomFilters).
function R:ImportFilterPayload(def)
    local id = self:CreateCustomFilter(def.name)
    local dst = self:GetCustomFilter(id)
    for sid in pairs(def.spells or {}) do dst.spells[sid] = true end
    for rid in pairs(def.rawIDs or {}) do dst.rawIDs[rid] = true end
    return id
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
-- NAME LOOKUP (lazy)
-- name -> record, indexing BOTH the shipped English `n` and the
-- runtime localized C_Spell name of every record. Built once on
-- first use (GUI-time callers, so C_Spell names are available).
-- Used by the Aura Designer's SpellDB identity fallback and the
-- all-spec trackable-aura pool. First record wins on collisions
-- (deterministic: R.Spells array order).
-- ------------------------------------------------------------
local byName
function R:GetSpellByName(name)
    if type(name) ~= "string" or name == "" then return nil end
    if not byName then
        byName = {}
        for _, rec in ipairs(R.Spells) do
            if byName[rec.n] == nil then byName[rec.n] = rec end
            local loc = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(rec.id)
            if type(loc) == "string" and loc ~= "" and byName[loc] == nil then
                byName[loc] = rec
            end
        end
    end
    return byName[name]
end

-- ------------------------------------------------------------
-- SPELL DATA AUDIT (dev diagnostic, /df debug auditspells)
-- Walks every id in the shipped DB (canonical + alts) and flags:
--   INVALID — C_Spell.GetSpellInfo returns nothing even after a
--     load request (id unknown to this client; stale DB entry).
--   NO-DESC — valid spell but an empty description (often a
--     server-side scripted aura, or a cast mis-harvested as a
--     buff). Candidates for review, not automatically wrong.
-- Load strategy: fire C_Spell.RequestLoadSpellData for every id
-- up front, then classify after a fixed 1.5s C_Timer.After delay.
-- Chosen over a ContinueOnSpellLoad completion counter because the
-- mixin never calls back for INVALID ids — the counter would stall
-- exactly when the audit matters most; a fixed delay always runs.
-- Developer output: plain print() by project convention.
-- ------------------------------------------------------------
function R:AuditSpellData()
    local ids = {} -- array of { id, rec, isAlt }
    for _, rec in ipairs(R.Spells) do
        ids[#ids + 1] = { id = rec.id, rec = rec }
        if rec.alts then
            for _, alt in ipairs(rec.alts) do
                ids[#ids + 1] = { id = alt, rec = rec, isAlt = true }
            end
        end
    end

    for _, e in ipairs(ids) do
        -- pcall: RequestLoadSpellData errors on ids the client considers
        -- invalid — exactly the entries this audit exists to find.
        pcall(C_Spell.RequestLoadSpellData, e.id)
    end

    DF:Say(format("Spell data audit — %d ids (%d spells + alts), results in ~1.5s...",
        #ids, #R.Spells))

    C_Timer.After(1.5, function()
        local function cats(rec)
            local keys = {}
            for k in pairs(rec.cats or {}) do keys[#keys + 1] = k end
            table.sort(keys)
            return table.concat(keys, ", ")
        end
        local function describe(e)
            local suffix = e.isAlt and format(" (alt of %d)", e.rec.id) or ""
            return format("  %d %s%s [%s]", e.id, e.rec.n or "?", suffix, cats(e.rec))
        end

        local invalid, nodesc = {}, {}
        for _, e in ipairs(ids) do
            local ok, info = pcall(C_Spell.GetSpellInfo, e.id)
            if not ok or not info then
                invalid[#invalid + 1] = e
            else
                local ok2, desc = pcall(C_Spell.GetSpellDescription, e.id)
                if not ok2 or type(desc) ~= "string" or desc == "" then
                    nodesc[#nodesc + 1] = e
                end
            end
        end

        local o = DF:Out("Spell Audit", format("%d ids checked", #ids))
        -- An id with no client data is STALE (a real defect in our data); one with
        -- no description is only a review candidate, so it warns rather than fails.
        o:Field("invalid", #invalid, #invalid > 0 and "BAD" or "GOOD")
        o:Field("no description", #nodesc, #nodesc > 0 and "WARN" or "GOOD")
        if #invalid > 0 then
            o:Section("Invalid - no client data, stale or wrong id", #invalid)
            for _, e in ipairs(invalid) do o:Line(describe(e), "BAD") end
        end
        if #nodesc > 0 then
            o:Section("No description - server-side aura or suspect", #nodesc)
            for _, e in ipairs(nodesc) do o:Line(describe(e), "WARN") end
        end
        if #invalid == 0 and #nodesc == 0 then
            o:Line("All spell DB ids have client data and descriptions.", "GOOD")
        end
    end)
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
-- `resolved` (optional) is a pre-computed ResolveSelection result for the SAME
-- selection/showAll pair — pass it when the caller already resolved, so no
-- path ever resolves the selection twice (A5 hot-path review).
local sigIDs = {}
function R:SelectionSignature(selection, showAll, resolved)
    local res = resolved or self:ResolveSelection(selection, showAll)
    if res.kind == "all" then return "all" end
    local n = 0
    for id in pairs(res.map) do n = n + 1; sigIDs[n] = id end
    for i = #sigIDs, n + 1, -1 do sigIDs[i] = nil end
    table.sort(sigIDs)
    return res.kind .. ":" .. table.concat(sigIDs, ",")
end
