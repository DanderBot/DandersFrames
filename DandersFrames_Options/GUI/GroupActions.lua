-- ☠ Companion addon: `...` yields THIS addon's private table, not the parent's,
-- so every DF.* read here would be nil. Take the parent's table from the global
-- it publishes at DandersFrames/Core.lua:9 (`_G[addonName] = DF`).
local DF = DandersFrames

-- ============================================================
-- GROUP ACTIONS
-- The write half of the popout footer: "put every setting behind this row back
-- to what the addon ships", and the press-and-hold preview that shows the user
-- what that would look like before they commit to it.
--
-- It lives in its own file, away from the page that calls it, for one reason:
-- these are the only lines in the feature that WRITE, and a write against a
-- bracketed settings table has three rules that are easy to get quietly wrong.
-- Alone in a module they are testable head-on (Tools/mover-tests) rather than
-- inferred from what a settings page looked like afterwards.
--
-- THE THREE RULES
-- ---------------
-- 1. EVERY WRITE GOES THROUGH THE BRACKET. `interceptWrite` first: a true answer
--    means an auto layout redirected the write to the stored baseline and the
--    live table did NOT change, so the plain write must not happen and neither
--    must the notification. A false answer means the write is ours, and
--    `onSettingWritten` after it is what records the change as a layout override
--    edit while a layout is being edited. Skipping either half is how a reset
--    ends up half-recorded, and a half-recorded layout is worse than an
--    unrecorded one.
-- 2. TABLE DEFAULTS ARE COPIED BEFORE THEY ARE WRITTEN. DF.Defaults:GetDefault
--    hands back the LIVE reference out of DF.PartyDefaults / DF.RaidDefaults
--    (it says so). Writing that reference into a profile makes the profile and
--    the shipped default the same table -- and the next edit to the setting then
--    rewrites the default for the rest of the session, so every later "is this
--    modified" answer silently agrees with the damage.
-- 3. A KEY ALREADY AT ITS DEFAULT IS NOT WRITTEN AT ALL. Not an optimisation: a
--    write is an EVENT here (the auto-layout recorder is listening), and
--    recording an edit that changed nothing would put a key into a layout's
--    override set that the user never touched.
--
-- No state, no events, no frames. Every function takes what it needs and hands
-- back a plain table; nothing is remembered between calls.
-- ============================================================

local type, pairs, ipairs = type, pairs, ipairs

DF.GroupActions = DF.GroupActions or {}
local GroupActions = DF.GroupActions

-- ============================================================
-- HELPERS
-- ============================================================

-- DF:DeepCopy is resident and this file is in the companion, so it is always
-- there in game -- but a headless load of this module alone is not, and neither
-- is a hypothetical load order that puts the panel in front of Profile.lua. The
-- local fallback is the same shape without the proxy unwrap, which nothing here
-- needs: the values being copied are defaults and stored settings, never a db
-- proxy.
local function DeepCopy(v)
    if type(v) ~= "table" then return v end
    if DF.DeepCopy then return DF:DeepCopy(v) end
    local t = {}
    for k, x in pairs(v) do t[k] = DeepCopy(x) end
    return t
end

-- ONE write, bracketed. Rule 1 above, in the one place every caller here goes
-- through so it cannot be spelled two ways.
--
-- `host` is the widget host (GUI) whose hooks carry the bracket. Returns true
-- when the value actually landed in the table, false when a runtime layout
-- redirected it -- which is the answer a caller needs if it is deciding whether
-- a live refresh is worth doing.
local function BracketedWrite(host, db, key, value)
    if host and host.Call and host:Call("interceptWrite", db, key, value) then
        return false                       -- redirected to the baseline; db is unchanged
    end
    db[key] = value
    if host and host.Call then host:Call("onSettingWritten", db, key, value) end
    return true
end

-- Which defaults table `db` is a side of. The caller normally KNOWS (the
-- settings page has GUI.SelectedMode in hand at the moment it builds the
-- action), and passing it is what keeps the two halves of a reset -- "what is
-- the default" and "is the stored value still it" -- measured against the same
-- table. The fallback is here so a caller that does not know cannot silently
-- reset raid keys with party numbers: an unrecognised table answers "party",
-- and the engine refuses to call anything modified in a table it does not
-- recognise, so nothing is written at all.
local function ResolveMode(db, mode)
    if mode == "party" or mode == "raid" then return mode end
    local root = DF.db
    if root and (db == root.raid or db == DF._realRaidDB) then return "raid" end
    return "party"
end

-- The shipped default for a key, already safe to write. nil when the mode does
-- not ship the key at all (the Targeted List family is party-only) -- those keys
-- are skipped rather than written as nil, which would delete a setting.
local function DefaultFor(mode, key)
    local D = DF.Defaults
    if not D then return nil end
    local def = D:GetDefault(mode, key)
    if def == nil then return nil end
    return DeepCopy(def)                   -- rule 2: never the live reference
end

-- ============================================================
-- PUBLIC API
-- ============================================================

-- Put every key in `keys` back to its shipped default.
--
-- Returns { [key] = { old = <what was there>, new = <the default> } } for the
-- keys that actually CHANGED -- the shape an undo toast wants, handed back
-- rather than acted on: nothing here shows anything, and a caller that ignores
-- the return has still done a correct reset.
--
-- `mode` is "party" / "raid", i.e. which defaults table `db` is a profile side
-- of. Passed in rather than derived: the caller is the settings page and it
-- already knows (GUI.SelectedMode), and asking the engine to work it back out
-- from the table would mean re-deriving a fact at the one moment it is certain.
function GroupActions:ResetKeys(host, db, keys, mode)
    local changes = {}
    if type(db) ~= "table" or type(keys) ~= "table" then return changes end

    mode = ResolveMode(db, mode)
    local D = DF.Defaults
    for _, key in ipairs(keys) do
        local def = DefaultFor(mode, key)
        if def ~= nil then
            -- Rule 3. The engine's own comparison, not `==`: a colour table at
            -- its default is a DIFFERENT table with the same numbers, and a
            -- slider value can sit a float hair off the default it was stored
            -- from -- both of which `==` calls a change.
            local modified = D and D:IsModified(db, key)
            if modified then
                local old = db[key]
                if BracketedWrite(host, db, key, def) then
                    changes[key] = { old = old, new = def }
                end
            end
        end
    end
    return changes
end

-- Take the group to its defaults and hand back what was there, for EndHold to
-- put back. The preview half of press-and-hold.
--
-- ⚠ EVERY key in `keys` that the mode ships is snapshotted, including the ones
-- already at their default -- the snapshot is "what the user had", and a key
-- left out of it is a key EndHold cannot restore. The WRITE still skips them
-- (rule 3), so an unmodified key is recorded and never touched.
function GroupActions:BeginHold(host, db, keys, mode)
    local snapshot = {}
    if type(db) ~= "table" or type(keys) ~= "table" then return snapshot end

    mode = ResolveMode(db, mode)
    local D = DF.Defaults
    for _, key in ipairs(keys) do
        local def = DefaultFor(mode, key)
        if def ~= nil then
            -- Copied, not referenced: the stored value may be a table, and the
            -- write below replaces db[key] outright -- but a caller mutating the
            -- live table between the two halves would otherwise change what
            -- "restore" means.
            snapshot[key] = DeepCopy(db[key])
            if D and D:IsModified(db, key) then
                BracketedWrite(host, db, key, def)
            end
        end
    end
    return snapshot
end

-- ...and back again. Writes the snapshot through the same bracket, so a restore
-- is recorded exactly as the user's own edit would be.
--
-- Written unconditionally rather than only where the value differs: after
-- BeginHold the live table holds defaults, and the one comparison worth making
-- -- "is this what the user had" -- is the thing being restored. A key whose
-- stored value was already the default is written back as the default, which is
-- a no-op in value terms and keeps the two halves symmetric.
function GroupActions:EndHold(host, db, keys, snapshot)
    if type(db) ~= "table" or type(keys) ~= "table" or type(snapshot) ~= "table" then return end

    for _, key in ipairs(keys) do
        local old = snapshot[key]
        if old ~= nil then
            BracketedWrite(host, db, key, old)
        end
    end
end
