local NS = ...

-- ============================================================
-- RESET PROFILE TO DEFAULTS, AND THE PANEL FONT -- Core/Profile.lua
-- ------------------------------------------------------------
-- A full reset makes the current profile exactly what a NEW profile is: one
-- constructor (NewProfileTable) for both, then the same activation a switch
-- runs, WITHOUT saving the old profile over the new one first. The panel font
-- lives at the profile root, and FullProfileRefresh's SyncSettingsFont re-skins
-- the window -- once, and only when the font or outline actually moved.
-- ============================================================

local SRC = df_file_source("Core/Profile.lua"):gsub("\r\n", "\n")

local function lift(name)
    local a = SRC:find("\nfunction DF:" .. name .. "%(")
    local b = a and SRC:find("\nend\n", a, true)
    check(a ~= nil and b ~= nil, "lift: found DF:" .. name)
    return (a and b) and SRC:sub(a + 1, b + 4) or ""
end

local DF = {
    L = setmetatable({}, { __index = function(_, k) return k end }),
    PartyDefaults = { frameWidth = 120 },
    RaidDefaults = { frameWidth = 80 },
    RaidAutoProfilesDefaults = { layouts = {} },
}
local refreshes = 0
local chunk = lift("SyncSettingsFont") .. lift("ResetFullProfile") .. lift("NewProfileTable")
local f, err = loadstring(chunk, "=profile reset")
check(f ~= nil, "lift: the functions parse (" .. tostring(err) .. ")")
if f then
    -- Profile.lua's own file-scope local.
    setfenv(f, setmetatable({ DF = DF, format = string.format }, { __index = _G }))
    f()
end

function DF:DeepCopy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = self:DeepCopy(v) end
    return c
end
function DF:StampFreshProfileMigrations(p) p._stamped = true end
function DF:GetCurrentProfile() return DandersFramesDB_v2.currentProfile end
DF.GUI = { RefreshSettingsFont = function() refreshes = refreshes + 1 end }
local activated
function DF:ActivateProfile(name, message)
    activated = { name = name, message = message }
    DF.db = DandersFramesDB_v2.profiles[name]
    DF:SyncSettingsFont()   -- what its FullProfileRefresh does
end
function DF:SaveCurrentProfile() error("a reset must not save the old profile over the new one") end

local prevDB = DandersFramesDB_v2

print("-- Profile font: SyncSettingsFont re-skins only when the pair moves")
do
    DF.db = { settingsFont = "MoK", settingsFontOutline = "NONE" }
    DF:SyncSettingsFont()
    eq(refreshes, 1, "sync: the first call applies the font")
    DF:SyncSettingsFont()
    eq(refreshes, 1, "sync: ...and an unchanged pair costs nothing (auto layouts refresh often)")
    DF.db.settingsFontOutline = "OUTLINE"
    DF:SyncSettingsFont()
    eq(refreshes, 2, "sync: an outline change alone re-skins")
end

print("-- Reset: the current profile becomes a new one, everything included")
do
    local old = {
        party = { frameWidth = 300 }, raid = { frameWidth = 300 },
        raidAutoProfiles = { layouts = { mine = true } },
        classColors = { MAGE = { r = 1 } }, powerColors = { MANA = { b = 1 } },
        linkedSections = { bars = true }, partyEnabled = false, raidEnabled = true,
        settingsFont = "MoK", settingsFontOutline = "OUTLINE",
        filterPresetOverrides = { x = 1 }, auraDesignerPresets = { Mine = {} },
    }
    local other = { party = { frameWidth = 999 } }
    DandersFramesDB_v2 = { currentProfile = "Healer", profiles = { Healer = old, Tank = other } }
    DF.db = old
    DF:SyncSettingsFont()
    local before = refreshes

    DF:ResetFullProfile()
    local p = DandersFramesDB_v2.profiles.Healer
    check(p ~= old, "reset: the profile is a NEW table, not the old one edited")
    eq(p.party.frameWidth, 120, "reset: party is at its defaults")
    eq(p.raid.frameWidth, 80, "reset: ...and raid")
    eq(next(p.raidAutoProfiles.layouts), nil, "reset: auto layouts are back to the defaults")
    eq(next(p.classColors), nil, "reset: class colours are cleared")
    eq(next(p.powerColors), nil, "reset: ...and power colours")
    eq(next(p.linkedSections), nil, "reset: no page is synced")
    eq(p.partyEnabled, true, "reset: party frames are switched back on")
    eq(p.settingsFont, "DF Roboto SemiBold", "reset: the settings font is the default")
    eq(p.settingsFontOutline, "NONE", "reset: ...and its outline")
    eq(p.filterPresetOverrides, nil, "reset: filter overrides are gone")
    eq(p.auraDesignerPresets, nil, "reset: the old designer library is gone (activation rebuilds it)")
    eq(p._stamped, true, "reset: one-time migrations are marked done, as on a new profile")
    eq(DandersFramesDB_v2.profiles.Tank, other, "reset: other profiles are untouched")
    eq(activated and activated.name, "Healer", "reset: the profile is re-activated under the same name")
    eq(activated and activated.message, "Profile reset to defaults: Healer", "reset: ...with its own message")
    eq(refreshes, before + 1, "reset: the window is re-skinned once")
end

DandersFramesDB_v2 = prevDB
