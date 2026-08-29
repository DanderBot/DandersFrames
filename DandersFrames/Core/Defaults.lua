local addonName, DF = ...

-- ============================================================
-- DEFAULTS DIFF ENGINE
-- Answers one question, purely by reading: "does this stored setting differ
-- from the value the addon ships, and what is the shipped value?"
--
-- It exists so the settings UI can mark a control as modified and offer a
-- group reset without every page hand-rolling its own comparison. Nothing here
-- writes, registers an event, creates a frame or caches a result: consumers
-- call it while they repaint, and a repaint is already the moment the answer
-- can change.
--
-- WHAT "MODIFIED" MEANS -- and why the overlay is unwrapped
-- --------------------------------------------------------
-- Modified compares the value STORED IN THE PROFILE against the shipped
-- default. It deliberately does NOT compare what the addon is currently
-- RUNNING on. Those two differ whenever an auto-profile runtime overlay is
-- active: Core.lua's WrapDB replaces DF.db.raid with a read-through proxy that
-- answers from DF.raidOverrides first and keeps the real SavedVariables table
-- at DF._realRaidDB (Core.lua ~3325). Reading the proxy would light up a dot on
-- every key the active layout overrides -- settings the user never touched --
-- and a "reset to default" driven off that would be answering about a value
-- that is not even saved. So the proxy is unwrapped first and the real table
-- is what gets compared.
--
-- THE EPSILON, 1e-6
-- -----------------
-- Slider values are stored as floats and are quantised to the step's decimal
-- factor when they are written (DandersUI Widgets.lua, Quantize), so a value
-- that came back from a slider is exact to the step -- but a value that came
-- from an import, an older profile, or a scale/round trip can sit a hair off.
-- 1e-6 sits well below the precision those steps quantise to, so no genuine
-- one-step change is ever swallowed, while float noise is.
--
-- THE UNKNOWN-TABLE RULE
-- ----------------------
-- Only DF.db.party, DF.db.raid and DF._realRaidDB are understood. Anything
-- else -- a designer proxy, an aura sub-table, a settings-page scratch table,
-- nil -- answers "not modified". A dot that appears on a table the engine
-- cannot reason about would be a lie, and a group reset driven off that lie
-- would write defaults into a table that has none. Unknown means silent.
--
-- ...UNLESS THE TABLE ANSWERS FOR ITSELF
-- --------------------------------------
-- A table may carry its own answers under the raw key __dfDefaultsAdapter, and
-- the engine asks it instead of pattern-matching the table:
--
--     __dfDefaultsAdapter = {
--         GetDefault = function(key) end,  -- what the key falls back to, or nil
--                                          -- when it is not a setting here
--         GetStored  = function(key) end,  -- what the USER set, or nil if unset
--         ClearKey   = function(key) end,  -- optional; unset the key. A reset
--                                          -- uses it in preference to writing
--     }
--
-- It exists for the two designers. Their controls bind to a metatable PROXY over
-- one record (an aura indicator instance, a text element), never to a profile
-- side, so no identity check can recognise them and every verb below dies
-- quietly on the nil -- a modified tick that never lights, a Reset Group that
-- writes nothing, and no error either way.
--
-- Nothing that ships carries the key, so the branch is inert for every page that
-- exists today: rawget on a plain settings table answers nil and the identity
-- checks run exactly as they did.
--
-- The rules above still hold through an adapter. A key it cannot answer for is
-- unmodified, and the comparison is still ValuesEqual -- which is what makes the
-- Aura Designer's copy-on-read harmless: reading a table-valued key COPIES the
-- default onto the instance, so presence is no evidence of an edit, but the copy
-- compares equal to what it was copied from and reports unmodified.
--
-- GetStored MUST READ RAW. A designer proxy's __index answers with the FALLBACK
-- when the record holds no value of its own, so an adapter that read back
-- through its own proxy would find every key set and light the whole panel up.
-- ============================================================

local type, pairs, rawget = type, pairs, rawget
local abs = math.abs

-- Finer than any slider step in the addon. See the header.
local EPSILON = 1e-6

DF.Defaults = DF.Defaults or {}
local Defaults = DF.Defaults

-- ============================================================
-- VALUE EQUALITY
-- ============================================================

-- Deep value equality, used in both directions of "is this still the default".
--   * numbers  -- equal within EPSILON. NaN is equal only to NaN (Lua's == says
--                 a NaN is equal to nothing at all, including itself, which
--                 would report a stored NaN as modified against a NaN default).
--   * tables   -- compared recursively over the UNION of both key sets, so a key
--                 present on one side and absent on the other is a difference.
--                 Colour tables ({r,g,b} vs {r,g,b,a}) are the case that matters.
--   * anything else -- plain ==.
-- A type mismatch is always unequal (numbers only ever compare with numbers).
local function ValuesEqual(a, b)
    if a == b then return true end          -- identical scalars, same table, both nil

    local ta, tb = type(a), type(b)
    if ta ~= tb then return false end

    if ta == "number" then
        if a ~= a or b ~= b then
            return (a ~= a) and (b ~= b)    -- both NaN == equal; one NaN == not
        end
        return abs(a - b) <= EPSILON
    end

    if ta ~= "table" then return false end

    for k, v in pairs(a) do
        if not ValuesEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- ============================================================
-- TABLE RESOLUTION
-- ============================================================

-- db -> (stored table, defaults table), or (nil, nil, adapter) for a table that
-- answers for itself, or nil for anything not understood.
--
-- ⚠ THE ADAPTER IS ASKED FIRST, and by rawget. A designer proxy's __index
-- resolves a fallback chain for every key, so a plain read of the hook would
-- come back with a fallback rather than the hook -- and the identity checks
-- below can never match a proxy anyway, so nothing that would otherwise have
-- answered is short-circuited.
--
-- ☠ THE OVERLAY UNWRAP COMES FIRST of the rest. When a runtime auto profile is
-- active, DF.db.raid is the proxy VIEW, not storage. Test it before the plain
-- identity checks so the real table is what comes back; only when no overlay is
-- installed is DF.db.raid itself the stored table.
local function Resolve(db)
    if type(db) ~= "table" then return nil end

    local adapter = rawget(db, "__dfDefaultsAdapter")
    if type(adapter) == "table" then return nil, nil, adapter end

    local root = DF.db
    local real = DF._realRaidDB

    if real ~= nil and root ~= nil and db == root.raid then
        return real, DF.RaidDefaults               -- overlay view -> real raid storage
    end
    if root ~= nil then
        if db == root.party then return db, DF.PartyDefaults end
        if db == root.raid  then return db, DF.RaidDefaults  end
    end
    if real ~= nil and db == real then
        return db, DF.RaidDefaults                 -- handed the real table directly
    end

    return nil
end

-- What one key resolves to on either path: (stored value, shipped default).
-- Split out so the comparison and the ledger DiffKeys builds read the pair the
-- same way -- two spellings of the adapter branch is one drift away from a tick
-- that disagrees with the value beside it.
local function KeyValues(stored, defaults, adapter, key)
    if adapter then
        local getStored, getDefault = adapter.GetStored, adapter.GetDefault
        local cur = getStored and getStored(key)
        local def = getDefault and getDefault(key)
        return cur, def
    end
    return stored[key], defaults[key]
end

-- One key, already resolved. Split out so Count can reuse it without building
-- the value tables DiffKeys returns.
local function IsKeyModified(stored, defaults, adapter, key)
    local cur, def = KeyValues(stored, defaults, adapter, key)
    if def == nil then return false end            -- not a shipped setting in this mode
    if cur == nil then return false end            -- unset; the migration normally prevents this
    return not ValuesEqual(cur, def)
end

-- ============================================================
-- PUBLIC API
-- ============================================================

-- The shipped default for a key in a mode ("party" / "raid"), or nil when the
-- mode has no such key (the Targeted List family is party-only).
--
-- ⚠ THE RETURN IS THE LIVE REFERENCE, not a copy -- table-valued defaults
-- (position, the aura designer block) come back as the very table
-- DF.PartyDefaults / DF.RaidDefaults holds. Callers MUST NOT mutate it: one
-- stray write rewrites the shipped default for the rest of the session and
-- every later comparison silently agrees with the damage. Copy before writing
-- (DF:DeepCopy) if the value is going anywhere near a profile.
function Defaults:GetDefault(mode, key)
    local t = (mode == "raid") and DF.RaidDefaults or DF.PartyDefaults
    if not t then return nil end
    return t[key]
end

-- True when db's STORED value for key differs from the shipped default.
-- False for anything the engine cannot answer honestly: an unknown table, a key
-- the mode does not ship, a value that is not stored at all.
function Defaults:IsModified(db, key)
    local stored, defaults, adapter = Resolve(db)
    if not adapter and (not stored or not defaults) then return false end
    return IsKeyModified(stored, defaults, adapter, key)
end

-- { [key] = { current = <stored>, default = <shipped> } } for the MODIFIED keys
-- of the array only. Empty table when nothing is modified or db is unknown.
-- Values are live references on both sides -- same no-mutation rule as GetDefault.
function Defaults:DiffKeys(db, keys)
    local out = {}
    local stored, defaults, adapter = Resolve(db)
    if not adapter and (not stored or not defaults) then return out end
    if type(keys) ~= "table" then return out end

    for i = 1, #keys do
        local key = keys[i]
        if IsKeyModified(stored, defaults, adapter, key) then
            local cur, def = KeyValues(stored, defaults, adapter, key)
            out[key] = { current = cur, default = def }
        end
    end
    return out
end

-- How many of the array's keys are modified. Counts directly rather than
-- measuring DiffKeys: this is the one that runs per section header on every
-- repaint, and it should not allocate a result table to throw away.
function Defaults:Count(db, keys)
    local stored, defaults, adapter = Resolve(db)
    if not adapter and (not stored or not defaults) then return 0 end
    if type(keys) ~= "table" then return 0 end

    local n = 0
    for i = 1, #keys do
        if IsKeyModified(stored, defaults, adapter, keys[i]) then n = n + 1 end
    end
    return n
end
