local NS = ...

-- ============================================================
-- THE PROFILE-ROOT TABLE REGISTRY -- DandersFrames/Core/Profile.lua
-- ------------------------------------------------------------
-- DF:RegisterProfileRootTable(key, {defaults, migrate, exportable, exportCategory})
-- gives a profile-root table defaults on every profile, a migration hook, a fresh
-- copy in a new (or reset) profile, and a ride in full / selective export and
-- import. A payload with only registered tables is valid; keys nobody registered
-- are ignored. The registry, the export half and the payload check run for real
-- (lifted out of the file); ActivateProfile / ApplyImportedProfile / the login
-- pass are checked for the calls that wire them in.
-- ============================================================

local SRC = df_file_source("Core/Profile.lua"):gsub("\r\n", "\n")

local function region(fromPat, toPat)
    local a = SRC:find(fromPat, 1, true)
    local b = a and SRC:find(toPat, a, true)
    check(a ~= nil and b ~= nil, "lift: found " .. fromPat)
    return (a and b) and SRC:sub(a, b + #toPat - 1) or ""
end
local function lift(name)
    local a = SRC:find("\nfunction DF:" .. name .. "(", 1, true)
    local b = a and SRC:find("\nend\n", a, true)
    check(a ~= nil and b ~= nil, "lift: found DF:" .. name)
    return (a and b) and SRC:sub(a + 1, b + 4) or ""
end

local registry = region("DF.ProfileRootTables = DF.ProfileRootTables or {}",
    "    return spec.exportCategory ~= nil and categorySet[spec.exportCategory] == true\nend\n")
local exportPart = region("local PROFILE_ROOT_SCALARS = {", "    return data, nil\nend\n")

local captured
local DF = { L = setmetatable({}, { __index = function(_, k) return k end }), VERSION = "5.7.0",
             CLIENT_FLAVOR = "retail", ExportCategories = {},
             PartyDefaults = { frameWidth = 120 }, RaidDefaults = { frameWidth = 80 },
             RaidAutoProfilesDefaults = {} }
function DF:DeepCopy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = self:DeepCopy(v) end
    return c
end
local errs = {}
function DF:DebugError(_, fmt, ...) errs[#errs + 1] = string.format(fmt, ...) end
function DF:Err() end
function DF:ExtractCategorySettings(t) return self:DeepCopy(t) end
function DF:StampFreshProfileMigrations() end
local env = setmetatable({
    DF = DF,
    LibStub = function(name)
        if name == "LibSerialize" then
            return { Serialize = function(_, t) captured = t; return "S" end }
        end
        return { CompressDeflate = function(_, s) return s end, EncodeForPrint = function(_, s) return s end }
    end,
    StripInternalKeys = function(t) return t end,
    EmbedCustomFilterData = function() end,
}, { __index = _G })
local chunk, err = loadstring(registry .. exportPart .. lift("NewProfileTable")
    .. "\nreturn ValidatePayloadShape, ImportProfileRootTables", "=registry")
check(chunk ~= nil, "lift: the registry, export and payload check parse (" .. tostring(err) .. ")")
if not chunk then return end
setfenv(chunk, env)
local ValidatePayloadShape, ImportProfileRootTables = chunk()

local savedSV = DandersFramesDB_v2

-- ---- empty registry: nothing changes ----------------------------------
print("-- Empty registry: behaviour as before")
local fresh = DF:NewProfileTable()
local keys = {}
for k in pairs(fresh) do keys[#keys + 1] = k end
table.sort(keys)
eq(table.concat(keys, ","),
   "classColors,linkedSections,party,partyEnabled,powerColors,raid,raidAutoProfiles,raidEnabled,settingsFont,settingsFontOutline",
   "new profile: exactly the old root keys")
local data, why = ValidatePayloadShape({ unknownRoot = { a = 1 } })
eq(data, nil, "payload with no mode and no registered table: rejected")
eq(why, "No profile data found", "...as 'No profile data found', the stable answer")
data = ValidatePayloadShape({ party = {}, fromNewerBuild = { x = 1 }, alsoNewer = "scalar" })
check(data ~= nil, "unknown root keys from a newer build: ignored, payload accepted")

-- ---- registration ------------------------------------------------------
print("-- Registration")
DandersFramesDB_v2 = nil
DF.db = nil
check(not DF:RegisterProfileRootTable("party", {}), "a reserved key is refused")
check(not DF:RegisterProfileRootTable("_private", {}), "an underscore key is refused")
check(not DF:RegisterProfileRootTable("bad", { defaults = 5 }), "non-table defaults refused")
check(not DF:RegisterProfileRootTable("bad", { migrate = "x" }), "non-function migrate refused")
eq(#errs, 4, "each refusal is a debug error")
eq(#DF.ProfileRootTableOrder, 0, "nothing refused was registered")

local migrated = {}
check(DF:RegisterProfileRootTable("extra", {
    defaults = { version = 1, opts = { size = 10 }, flag = true },
    migrate = function(t, profile)
        migrated[#migrated + 1] = t
        if t.oldName ~= nil then t.newName = t.oldName; t.oldName = nil end
    end,
    exportCategory = "extraCat",
}), "a table registers")
check(DF:RegisterProfileRootTable("localOnly", { defaults = { x = 1 }, exportable = false }), "a local-only table registers")
check(DF:RegisterProfileRootTable("extra", {
    defaults = { version = 1, opts = { size = 10 }, flag = true },
    migrate = DF.ProfileRootTables.extra.migrate, exportCategory = "extraCat",
}), "re-registering replaces the spec")
eq(#DF.ProfileRootTableOrder, 2, "...without a second entry")

-- ---- new / reset profile -----------------------------------------------
print("-- New and reset profiles get the defaults")
fresh = DF:NewProfileTable()
check(type(fresh.extra) == "table" and fresh.extra.version == 1 and fresh.extra.opts.size == 10, "new profile: seeded")
check(fresh.extra.opts ~= DF.ProfileRootTables.extra.defaults.opts, "...as a copy, not the defaults table")
eq(fresh.localOnly.x, 1, "new profile: a local-only table is seeded too")
eq(#migrated, 0, "no migrate on a freshly seeded table")
check(lift("ResetFullProfile"):find("DF:NewProfileTable()", 1, true), "reset: through NewProfileTable")

-- ---- backfill / migrate ----------------------------------------------------
print("-- Backfill: migrate first, then fill only absent keys")
local old = { extra = { oldName = "v", flag = false, opts = { size = 3 } } }
DF:ApplyProfileRootDefaults(old)
eq(#migrated, 1, "migrate ran on the existing table")
eq(old.extra.newName, "v", "migrate's rename landed")
eq(old.extra.flag, false, "a stored false is kept")
eq(old.extra.opts.size, 3, "an existing nested table is left alone (one level deep)")
eq(old.extra.version, 1, "an absent key is filled")
eq(old.localOnly.x, 1, "a missing table is seeded")
local corrupt = { extra = "nope" }
DF:ApplyProfileRootDefaults(corrupt)
eq(type(corrupt.extra), "table", "a non-table under the key is replaced by the defaults")
local boom = 0
DF.ProfileRootTables.localOnly.migrate = function() boom = boom + 1; error("x") end
local bp = { localOnly = {} }
DF:ApplyProfileRootDefaults(bp)
eq(boom, 1, "a throwing migrate is contained")
eq(bp.localOnly.x, 1, "...and the fill still runs")
DF.ProfileRootTables.localOnly.migrate = nil

print("-- Late registration seeds every stored profile")
local p1, p2 = { party = {} }, { party = {}, late = { kept = true } }
DandersFramesDB_v2 = { profiles = { A = p1, B = p2 } }
DF.db = p1
DF:RegisterProfileRootTable("late", { defaults = { kept = false, n = 2 } })
check(type(p1.late) == "table" and p1.late.n == 2, "profile A seeded on registration")
check(p2.late.kept == true and p2.late.n == 2, "profile B: kept its value, filled the rest")
DF.ProfileRootTables.late = nil
table.remove(DF.ProfileRootTableOrder)

-- ---- export ----------------------------------------------------------------
print("-- Export")
DandersFramesDB_v2 = { currentProfile = "A" }
DF.db = { party = { frameWidth = 1 }, raid = { frameWidth = 2 },
          extra = { version = 1, mine = true }, localOnly = { x = 5 } }
captured = nil
DF:ExportProfile()
check(captured and type(captured.extra) == "table" and captured.extra.mine == true, "full export carries a registered table")
check(captured and captured.extra ~= DF.db.extra, "...as a copy")
eq(captured and captured.localOnly, nil, "a non-exportable table stays home")
captured = nil
DF:ExportProfile({ "other" })
eq(captured and captured.extra, nil, "selective export without its category: left out")
captured = nil
DF:ExportProfile({ "extraCat" })
check(captured and captured.extra and captured.extra.mine == true, "selective export with its category: carried")
captured = nil
DF:ExportProfile(nil, { party = false, raid = false })
check(captured and captured.extra and captured.party == nil and captured.raid == nil,
      "only registered tables to export: still an export")
DF.db.extra = {}
captured = nil
DF:ExportProfile()
eq(captured and captured.extra, nil, "an empty table is left out, as the palettes are")

-- ---- payload check -------------------------------------------------------
print("-- Payload check")
check(ValidatePayloadShape({ extra = { a = 1 } }) ~= nil, "a payload with only a registered table is accepted")
data, why = ValidatePayloadShape({ party = {}, extra = "corrupt" })
eq(why, "Corrupt data", "a registered key holding a non-table is rejected")
check(ValidatePayloadShape({ party = {}, neverRegistered = "anything" }) ~= nil, "unregistered keys still ignored")
eq(select(2, ValidatePayloadShape({ neverRegistered = {} })), "No profile data found",
   "only unregistered tables: nothing to apply")

-- ---- import ------------------------------------------------------------------
print("-- Import")
DF.db = { extra = { mine = true }, localOnly = { x = 5 } }
ImportProfileRootTables({ extra = { theirs = true }, localOnly = { x = 9 } }, nil)
check(DF.db.extra.theirs == true and DF.db.extra.mine == nil, "full import replaces a registered table")
eq(DF.db.localOnly.x, 5, "a non-exportable table is never imported")
DF.db.extra = { mine = true }
ImportProfileRootTables({ extra = { theirs = true } }, { other = true })
check(DF.db.extra.mine == true and DF.db.extra.theirs == nil, "selective import without its category: untouched")
ImportProfileRootTables({ extra = { theirs = true } }, { extraCat = true })
eq(DF.db.extra.theirs, true, "selective import with its category: replaced")
ImportProfileRootTables({}, nil)
eq(DF.db.extra.theirs, true, "absent from the payload: untouched")

local apply = lift("ApplyImportedProfile")
local _, imports = apply:gsub("ImportProfileRootTables%(importData, ", "")
eq(imports, 2, "ApplyImportedProfile: both the full and the selective branch import registered tables")
check(apply:find("for _, key in ipairs%(DF%.ProfileRootTableOrder%) do\n%s*local cur = DF%.db%[key%]"),
      "new-profile import: registered tables copied from current, like the rest")
check(apply:find("backfillDefaults%(DF%.db and DF%.db%.raid, DF%.RaidDefaults%)\n[^\n]*\n%s*if DF%.db then DF:ApplyProfileRootDefaults"),
      "after the import: migrate + fill, beside the mode backfill")

-- ---- the other consumers ---------------------------------------------------
print("-- Wiring: profile switch and login")
local act = lift("ActivateProfile")
local at, dbAt = act:find("DF:ApplyProfileRootDefaults(p)", 1, true), act:find("DF.db = DandersFramesDB_v2.profiles[name]", 1, true)
check(at and dbAt and at < dbAt, "ActivateProfile: migrate + fill before the profile goes live")
local core = df_file_source("Core.lua"):gsub("\r\n", "\n")
check(core:find("profile%.raid%[key%] = DF:DeepCopy%(value%)\n%s*end\n%s*end\n%s*end\n[^\n]*\n[^\n]*\n%s*DF:ApplyProfileRootDefaults%(profile%)"),
      "login: every stored profile, right after the party/raid backfill")

DandersFramesDB_v2 = savedSV
