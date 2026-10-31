local NS = ...

-- ============================================================
-- RESET CLICK-CASTING -- ClickCasting/Profiles.lua (CC:ResetActiveProfile)
-- ------------------------------------------------------------
-- The Modules page's Reset on Click-Casting. Bindings are precious, so ONLY the
-- class's active click-cast profile goes back to a new profile (the template):
-- its bindings, custom macros, consumables and options. Its on/off switch
-- (options.enabled, mirrored to CC.db.enabled) stays as it was; the class's
-- other profiles, the loadout assignments and the settings every profile shares
-- are untouched. In place, so CC.profile and the legacy CC.db.* references
-- still point at the live profile; then the bindings are re-applied.
-- ============================================================

local savedDF, savedCopyTable, savedUnitClass = DandersFrames, CopyTable, UnitClass

local function DeepCopy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = DeepCopy(v) end
    return c
end
CopyTable = DeepCopy
UnitClass = function() return "Priest", "PRIEST" end

local CC = {
    DB_VERSION = 3,
    PROFILE_TEMPLATE = {
        _priorityHigherWinsV1 = true,
        bindings = {}, customMacros = {}, consumables = {},
        options = { enabled = true, castOnDown = true, viewLayout = "grid", viewSort = "sectioned",
                    quickBindEnabled = true, smartResurrection = "disabled" },
    },
    GetDefaultProfileName = function() return "Priest" end,
}
local said, errs = {}, {}
local ns = { ClickCast = CC, L = setmetatable({}, { __index = function(_, k) return k end }) }
function ns:Say(msg) said[#said + 1] = msg end
function ns:Err(msg) errs[#errs + 1] = msg end
function ns:Debug() end
DandersFrames = ns

load_df_file_into("ClickCasting/Profiles.lua", ns)
check(type(CC.ResetActiveProfile) == "function", "api: CC:ResetActiveProfile is defined")

local applied, refreshed = 0, 0
function CC:ApplyBindings() applied = applied + 1 end
function CC:RefreshUIIfLoaded() refreshed = refreshed + 1 end

local function Setup(enabled)
    local active = {
        _priorityHigherWinsV1 = true,
        bindings = { { button = "LeftButton", actionType = "spell", spellName = "Flash Heal" },
                     { button = "RightButton", actionType = "spell", spellName = "Renew" } },
        customMacros = { { name = "Mass Dispel" } },
        consumables = { 12345 },
        options = { enabled = enabled, castOnDown = false, viewLayout = "list", viewSort = "alpha",
                    quickBindEnabled = false, smartResurrection = "always" },
    }
    local other = {
        bindings = { { button = "LeftButton", actionType = "spell", spellName = "Smite" } },
        customMacros = {}, consumables = {}, options = { enabled = true, castOnDown = false },
    }
    local loadouts = { [1] = { [101] = "Shadow" } }
    CC.db = {
        classes = { PRIEST = { profiles = { Holy = active, Shadow = other }, activeProfile = "Holy",
                               loadoutAssignments = loadouts } },
        disableWhileMounted = true, targetOnCast = true,
        bindings = active.bindings, customMacros = active.customMacros, options = active.options,
        enabled = enabled,
    }
    CC.profile = active
    applied, refreshed, said, errs = 0, 0, {}, {}
    return active, other, loadouts
end

print("-- Click-casting reset: the active profile becomes a new one")
do
    local active, other, loadouts = Setup(true)
    local ok = CC:ResetActiveProfile()
    check(ok == true, "reset: it ran")
    local now = CC.db.classes.PRIEST.profiles.Holy
    check(now == active, "reset: in place -- the stored profile is the same table")
    eq(#now.bindings, 0, "reset: every binding is gone")
    eq(#now.customMacros, 0, "reset: every custom macro is gone")
    eq(#now.consumables, 0, "reset: the saved consumables are gone")
    eq(now.options.castOnDown, true, "reset: an option is back at its default")
    eq(now.options.viewLayout, "grid", "reset: ...and the view layout")
    eq(now.options.smartResurrection, "disabled", "reset: ...and smart resurrection")
    eq(now._priorityHigherWinsV1, true, "reset: born in the current priority scale (never re-flipped)")
    check(now.bindings ~= CC.PROFILE_TEMPLATE.bindings, "reset: a COPY of the template, never the template itself")

    eq(now.options.enabled, true, "on/off: click-casting stays on")
    eq(CC.db.enabled, true, "on/off: ...and the legacy mirror says so")

    check(CC.profile == now, "refs: CC.profile is the live profile")
    check(CC.db.bindings == now.bindings and CC.db.customMacros == now.customMacros
          and CC.db.options == now.options, "refs: the legacy CC.db references point into it")

    eq(#other.bindings, 1, "other: another click-cast profile keeps its bindings")
    eq(other.bindings[1].spellName, "Smite", "other: ...untouched")
    eq(CC.db.classes.PRIEST.activeProfile, "Holy", "other: the active profile is unchanged")
    check(CC.db.classes.PRIEST.loadoutAssignments == loadouts and loadouts[1][101] == "Shadow",
          "other: loadout assignments are untouched")
    check(CC.db.disableWhileMounted == true and CC.db.targetOnCast == true,
          "other: the settings every profile shares are untouched")

    eq(applied, 1, "apply: the bindings are re-applied once")
    eq(refreshed, 1, "apply: the click-casting panel refreshes if it is loaded")
    check(said[1] and said[1]:find("Holy", 1, true) ~= nil, "apply: the chat line names the click-cast profile")
end

print("-- Click-casting reset: a profile that is off stays off")
do
    Setup(false)
    CC:ResetActiveProfile()
    eq(CC.db.classes.PRIEST.profiles.Holy.options.enabled, false, "on/off: off stays off (template says on)")
    eq(CC.db.enabled, false, "on/off: ...and the legacy mirror says so")
end

print("-- Click-casting reset: refused in combat")
do
    local active = Setup(true)
    IN_COMBAT = true
    eq(CC:ResetActiveProfile(), false, "combat: refused")
    IN_COMBAT = false
    eq(#active.bindings, 2, "combat: nothing changed")
    eq(applied, 0, "combat: nothing re-applied")
    eq(errs[1], "Cannot use this action in combat.", "combat: says why")
end

DandersFrames, CopyTable, UnitClass = savedDF, savedCopyTable, savedUnitClass
CC.db = nil
