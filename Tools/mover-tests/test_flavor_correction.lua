-- ============================================================
-- FLAVOR CORRECTION (DandersFrames/Core/FlavorCorrection.lua)
-- Profiles moving between retail and WoW Forever: Aura Designer data is parked
-- on arrival and restored on the way back; imports from the other version reset
-- it. Loaded REAL into a stub namespace per flavor.
-- ============================================================

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local AD_DEFAULT = { enabled = false, auras = {} }

local function loadFC(flavor)
    local ns = {
        CLIENT_FLAVOR = flavor,
        IS_FOREVER = flavor == "forever",
        PartyDefaults = { auraDesigner = deepcopy(AD_DEFAULT) },
        RaidDefaults  = { auraDesigner = deepcopy(AD_DEFAULT) },
    }
    function ns:DeepCopy(t) return deepcopy(t) end
    -- The module builds its login-notice / logout-stamp frame at load; nothing here
    -- fires events, so an inert frame is all it needs.
    local prevCF = CreateFrame
    CreateFrame = function()
        return { RegisterEvent = function() end, SetScript = function() end }
    end
    load_df_file_into("Core/FlavorCorrection.lua", ns)
    CreateFrame = prevCF
    return ns.FlavorCorrection, ns
end

-- A profile as retail left it: its own AD library, per-mode AD, and other settings.
local function retailProfile()
    return {
        auraDesignerPresets = { Default = { auras = { Rejuvenation = { color = 1 } } }, Healer = { auras = { Echo = {} } } },
        party = { auraDesigner = { enabled = true, auras = { Lifebloom = {} } }, auraDesignerPreset = "Healer", frameWidth = 120 },
        raid  = { auraDesigner = { enabled = true, auras = {} }, auraDesignerPreset = "Default", frameWidth = 80 },
        debuffBlacklist = { [57724] = true },
        filterMutedSpellIDs = { [774] = true },
    }
end

local FCf = loadFC("forever")
local FCr = loadFC("retail")

do  -- an unstamped profile is retail's: on Forever it crosses
    local p = retailProfile()
    local orig = deepcopy(p)
    eq(FCf.CrossProfile(p), true, "unstamped profile crosses on Forever")
    eq(p._flavor, "forever", "stamped with the new version")
    check(p.auraDesignerPresets == nil, "live preset library is cleared (lazily recreated as Default)")
    check(same(p.party.auraDesigner, AD_DEFAULT) and same(p.raid.auraDesigner, AD_DEFAULT), "per-mode AD reset to the shipped default")
    check(p.party.auraDesignerPreset == nil and p.raid.auraDesignerPreset == nil, "mode preset names cleared")
    local slot = p._parkedAD and p._parkedAD.retail
    check(slot and same(slot.presets, orig.auraDesignerPresets), "retail library parked intact")
    check(slot and same(slot.modes.party.auraDesigner, orig.party.auraDesigner), "retail party AD parked intact")
    eq(slot and slot.modes.party.auraDesignerPreset, "Healer", "retail party preset name parked")
    eq(p.party.frameWidth, 120, "non-AD settings untouched")
    check(same(p.debuffBlacklist, orig.debuffBlacklist) and same(p.filterMutedSpellIDs, orig.filterMutedSpellIDs), "other spell data is left in place")

    eq(FCf.CrossProfile(p), false, "a second run is a no-op")
    check(p._parkedAD and p._parkedAD.retail ~= nil, "...and doesn't disturb the parked slot")
end

do  -- round trip: retail -> Forever -> retail gives the original back
    local p = retailProfile()
    local orig = deepcopy(p)
    FCf.CrossProfile(p)
    p.auraDesignerPresets = { Default = { auras = { ForeverSpell = {} } } }   -- built on Forever
    p.party.auraDesignerPreset = "Default"
    local foreverLib = deepcopy(p.auraDesignerPresets)
    eq(FCr.CrossProfile(p), true, "back on retail it crosses again")
    eq(p._flavor, "retail", "stamped retail")
    check(same(p.auraDesignerPresets, orig.auraDesignerPresets), "retail AD library restored exactly")
    check(same(p.party.auraDesigner, orig.party.auraDesigner), "retail party AD restored exactly")
    eq(p.party.auraDesignerPreset, "Healer", "retail party preset name restored")
    check(p._parkedAD and p._parkedAD.forever and same(p._parkedAD.forever.presets, foreverLib), "the Forever setup is parked in turn")
    check(p._parkedAD and p._parkedAD.retail == nil, "the used retail slot is gone")

    eq(FCf.CrossProfile(p), true, "and to Forever once more")
    check(same(p.auraDesignerPresets, foreverLib), "the Forever setup comes back")
end

do  -- a profile already stamped for this version is left alone
    local p = retailProfile(); p._flavor = "forever"
    local orig = deepcopy(p)
    eq(FCf.CrossProfile(p), false, "stamped Forever profile on Forever: no crossing")
    check(same(p, orig), "...and nothing changes")
end

do  -- retail's first login with this code: stamps, never parks
    local p = retailProfile()
    eq(FCr.CrossProfile(p), false, "unstamped profile on retail doesn't cross")
    eq(p._flavor, "retail", "...it just gets stamped")
    check(p._parkedAD == nil and p.auraDesignerPresets ~= nil, "...and keeps its AD live")
end

do  -- the login pass walks every profile and counts
    local sv = { profiles = { A = retailProfile(), B = retailProfile(), C = { _flavor = "forever", party = {}, raid = {} } } }
    eq(FCf.RunLoginPass(sv), 2, "login pass crosses the two retail profiles")
    eq(FCf.RunLoginPass(sv), 0, "second login: nothing crosses")
end

do  -- logout stamps profiles made during the session
    local sv = { profiles = { New = { party = {}, raid = {} }, Old = { _flavor = "retail" } } }
    FCf.StampUnstamped(sv)
    eq(sv.profiles.New._flavor, "forever", "a session-made profile is stamped with this version")
    eq(sv.profiles.Old._flavor, "retail", "an existing stamp is not overwritten")
end

do  -- string import from the other version: reset, not parked (the string is the copy)
    local p = retailProfile()
    eq(FCf.AfterImport(p, { version = "x" }, true), true, "a pre-flavor (retail) string with AD, on Forever: reset")
    check(p.auraDesignerPresets == nil and same(p.party.auraDesigner, AD_DEFAULT), "imported AD is cleared")
    check(p._parkedAD == nil, "nothing is parked for an import")
    eq(p._flavor, "forever", "import stamps this version")

    local q = retailProfile()
    eq(FCf.AfterImport(q, { sourceFlavor = "forever" }, true), false, "a Forever string on Forever: kept")
    check(q.auraDesignerPresets ~= nil, "...its AD survives")

    local r = retailProfile()
    eq(FCf.AfterImport(r, { sourceFlavor = "retail" }, false), false, "no AD in the import: nothing reset")
    check(r.auraDesignerPresets ~= nil, "...the profile's own AD survives")

    local s = retailProfile()
    eq(FCr.AfterImport(s, { sourceFlavor = "forever" }, true), true, "a Forever string on retail: reset")
end
