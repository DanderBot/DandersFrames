local NS = ...

-- ============================================================
-- RESET GROUP FRAMES -- Core/Profile.lua (DF:ResetGroupFrames)
-- ------------------------------------------------------------
-- The Modules page's Reset on Group Frames. The current profile's Party and Raid
-- frames go back to what a NEW profile has -- the mode tables, auto layouts, the
-- Party/Raid syncs and the Party/Raid designer presets -- and nothing else does:
-- the on/off switches, the Global tab's settings (root keys AND the ones stored
-- per mode), another module's root table, other designer presets and every other
-- profile stay exactly as they were. Out of combat and outside the auto-layout
-- editor only.
-- The real designer migration (Designer/Presets.lua) runs in the activation, as
-- ActivateProfile runs it, to show the Party / Raid presets come back fresh.
-- ============================================================

local SRC = df_file_source("Core/Profile.lua"):gsub("\r\n", "\n")

local function liftRange(fromPat, fnName)
    local a = SRC:find(fromPat, 1, true)
    local f = SRC:find("\nfunction DF:" .. fnName .. "(", a or 1, true)
    local b = f and SRC:find("\nend\n", f, true)
    check(a ~= nil and b ~= nil, "lift: found " .. fnName)
    return (a and b) and SRC:sub(a + 1, b + 4) or ""
end
local function lift(name)
    local a = SRC:find("\nfunction DF:" .. name .. "(", 1, true)
    local b = a and SRC:find("\nend\n", a, true)
    check(a ~= nil and b ~= nil, "lift: found DF:" .. name)
    return (a and b) and SRC:sub(a + 1, b + 4) or ""
end

local function DeepCopy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = DeepCopy(v) end
    return c
end

local DF = {
    L = setmetatable({}, { __index = function(_, k) return k end }),
    PartyDefaults = {
        frameWidth = 120, locked = true, pinnedFrames = { sets = {} },
        hideBlizzardPartyFrames = true, pixelPerfect = false, fontShadowOffsetX = 1,
        auraDesigner = { enabled = false, auras = {}, fromDefaults = true },
    },
    RaidDefaults = {
        frameWidth = 80, raidLocked = true, pinnedFrames = { sets = {} },
        hideBlizzardPartyFrames = true, pixelPerfect = false, fontShadowOffsetX = 1,
        auraDesigner = { enabled = false, auras = {}, fromDefaults = true },
    },
    RaidAutoProfilesDefaults = { enabled = false, layouts = {} },
}
function DF:DeepCopy(t) return DeepCopy(t) end
function DF:ApplyProfileRootDefaults() end
function DF:StampFreshProfileMigrations(p)
    p._absoluteFrameLevelsV1 = true
    if type(p.party) == "table" then p.party._personalContainerCenterMigrated = true end
end
function DF:GetCurrentProfile() return DandersFramesDB_v2.currentProfile end
local errs = {}
function DF:Err(msg) errs[#errs + 1] = msg end
local activated
function DF:ActivateProfile(name, message)
    activated = { name = name, message = message }
    DF.db = DandersFramesDB_v2.profiles[name]
    -- What the real one runs before its refresh (Designer/Presets.lua).
    DF:MigrateDesignerPresets()
end
-- Designer/Presets.lua's factories read these.
DF.TextDesigner = nil

local chunk = lift("NewProfileTable") .. liftRange("\nlocal GROUP_FRAMES_ROOT_KEYS", "ResetGroupFrames")
local f, err = loadstring(chunk, "=group frames reset")
check(f ~= nil, "lift: the functions parse (" .. tostring(err) .. ")")
if f then
    setfenv(f, setmetatable({ DF = DF, format = string.format }, { __index = _G }))
    f()
end
check(type(DF.ResetGroupFrames) == "function", "api: DF:ResetGroupFrames is defined")
check(type(DF.GroupFramesResetKeepKeys) == "table", "api: the kept per-mode keys are published")

load_df_file_into("Designer/Presets.lua", DF)
check(type(DF.MigrateDesignerPresets) == "function", "setup: the real designer migration is loaded")

local prevDB = DandersFramesDB_v2

local function Profile()
    return {
        party = {
            frameWidth = 300, locked = false, pinnedFrames = { sets = { { name = "Tanks" } } },
            anchorX = 400, auraDesignerPreset = "Party", auraDesignerEnabled = true,
            hideBlizzardPartyFrames = false, hideDefaultPlayerFrame = true, pixelPerfect = true,
            showBlizzardSideMenu = true, showMinimapButton = false, minimapIcon = { hide = true },
            fontShadowOffsetX = 3, fontShadowColor = { r = 1, g = 0, b = 0 },
        },
        raid = {
            frameWidth = 250, raidLocked = false, auraDesignerPreset = "Raid",
            hideBlizzardPartyFrames = false, pixelPerfect = true, fontShadowOffsetX = 3,
        },
        raidAutoProfiles = { enabled = true, layouts = { mythic = { frameWidth = 90 } } },
        linkedSections = { bars = true },
        partyEnabled = false, raidEnabled = true,
        _groupFramesRestore = { party = true, raid = true },
        classColors = { MAGE = { r = 1 } }, dispelColors = { Magic = { b = 1 } },
        settingsFont = "MoK", settingsFontOutline = "OUTLINE",
        filterPresetOverrides = { x = 1 }, customAuraFilters = { mine = {} },
        unitframes = { units = { player = { frameWidth = 222 } } },
        auraDesignerPresets = {
            Default = { enabled = false, tag = "default" },
            Party = { enabled = true, auras = { HOT = true } },
            Raid = { enabled = true, auras = { HOT = true } },
            Mine = { enabled = true, tag = "kept" },
        },
        textDesignerPresets = {
            Default = { tag = "default" },
            Party = { elements = { "custom" } },
            Raid = { elements = { "custom" } },
            ["Unit Frames"] = { tag = "uf" },
        },
        _designerPresetsMigratedV1 = true,
        _designerLayoutCleanupV1 = true,
        _someOldFlagV1 = true,
    }
end

print("-- Group Frames reset: the mode tables go back to a new profile's")
do
    local current = Profile()
    local other = Profile()
    DandersFramesDB_v2 = { currentProfile = "Main", profiles = { Main = current, Alt = other } }
    DF.db = current
    IN_COMBAT = false
    errs, activated = {}, nil

    local ok = DF:ResetGroupFrames()
    check(ok == true, "reset: it ran")
    local p = DandersFramesDB_v2.profiles.Main
    check(p == current, "reset: in place -- the stored profile is the same table")
    eq(p.party.frameWidth, 120, "reset: a Party setting is back at its default")
    eq(p.raid.frameWidth, 80, "reset: a Raid setting is back at its default")
    eq(p.party.locked, true, "reset: Party is locked again, as a new profile is")
    eq(p.party.anchorX, nil, "reset: the Party position is gone (back to the default anchor)")
    eq(#p.party.pinnedFrames.sets, 0, "reset: pinned frames are gone")
    eq(p.party.auraDesignerEnabled, nil, "reset: the Aura Designer's mode enable is back to unset")
    check(p.raidAutoProfiles.enabled == false and next(p.raidAutoProfiles.layouts) == nil,
          "reset: auto layouts are back to the defaults")
    eq(next(p.linkedSections), nil, "reset: no section is synced any more")
    eq(p.party._personalContainerCenterMigrated, true, "reset: the fresh Party table is born migrated")
    eq(p._absoluteFrameLevelsV1, true, "reset: the fresh-profile migration flags are stamped")
    eq(p._someOldFlagV1, true, "reset: ...and a flag a migration already set stays set")
end

print("-- Group Frames reset: the on/off state and the Global tab are kept")
do
    local p = DandersFramesDB_v2.profiles.Main
    eq(p.partyEnabled, false, "kept: Party stays off")
    eq(p.raidEnabled, true, "kept: Raid stays on")
    check(type(p._groupFramesRestore) == "table" and p._groupFramesRestore.party == true,
          "kept: the master switch's stash")
    for _, mode in ipairs({ "party", "raid" }) do
        eq(p[mode].hideBlizzardPartyFrames, false, "kept (" .. mode .. "): Disable Blizzard Party Frames")
        eq(p[mode].pixelPerfect, true, "kept (" .. mode .. "): Pixel-Perfect Scaling")
        eq(p[mode].fontShadowOffsetX, 3, "kept (" .. mode .. "): the Global Fonts text shadow")
    end
    eq(p.party.hideDefaultPlayerFrame, true, "kept: Hide Default Player Frame")
    eq(p.party.showBlizzardSideMenu, true, "kept: the Blizzard side menu")
    eq(p.party.showMinimapButton, false, "kept: the minimap button")
    check(p.party.minimapIcon and p.party.minimapIcon.hide == true, "kept: the minimap icon state")
    check(p.party.fontShadowColor and p.party.fontShadowColor.r == 1, "kept: the shadow colour")
    eq(p.raid.hideDefaultPlayerFrame, nil, "kept: a key the mode never had is not invented")
    check(p.classColors.MAGE and p.dispelColors.Magic, "kept: the Colors page's palettes")
    eq(p.settingsFont, "MoK", "kept: the settings font")
    check(p.filterPresetOverrides.x == 1 and p.customAuraFilters.mine, "kept: the Filter Designer's filters")
    eq(p.unitframes.units.player.frameWidth, 222, "kept: another module's profile-root table")
end

print("-- Group Frames reset: the designer presets")
do
    local p = DandersFramesDB_v2.profiles.Main
    local ad, td = p.auraDesignerPresets, p.textDesignerPresets
    check(ad.Party and ad.Party.fromDefaults == true and ad.Party.enabled == false,
          "designer: the Party Aura Designer preset is rebuilt from the fresh Party table")
    check(ad.Raid and ad.Raid.fromDefaults == true, "designer: ...and the Raid one from the fresh Raid table")
    eq(p.party.auraDesignerPreset, "Party", "designer: Party points at its preset again")
    eq(p.raid.auraDesignerPreset, "Raid", "designer: Raid points at its preset again")
    check(ad.Party ~= ad.Raid, "designer: ...two presets, never one shared table")
    eq(p.party.auraDesigner, nil, "designer: the inline config moved into the preset")
    check(td.Party and td.Party.elements and td.Party.elements[1] ~= "custom",
          "designer: the Party Text Designer preset is a fresh one")
    eq(ad.Mine and ad.Mine.tag, "kept", "designer: a preset under another name is kept")
    eq(td["Unit Frames"] and td["Unit Frames"].tag, "uf", "designer: ...including one another module uses")
    eq(ad.Default.tag, "default", "designer: the Default preset is left alone")
    eq(p._designerPresetsMigratedV1, true, "designer: the migration marked the profile done again")
end

print("-- Group Frames reset: other profiles, activation and the message")
do
    local other = DandersFramesDB_v2.profiles.Alt
    eq(other.party.frameWidth, 300, "other: another profile's Party settings are untouched")
    check(other.raidAutoProfiles.layouts.mythic, "other: ...and its auto layouts")
    eq(other.auraDesignerPresets.Party.enabled, true, "other: ...and its designer presets")
    check(activated and activated.name == "Main", "activate: the current profile is re-activated")
    check(activated and activated.message:find("Main", 1, true) ~= nil,
          "activate: the chat line names the profile")
    eq(#errs, 0, "activate: nothing was refused")
end

print("-- Group Frames reset: refused in combat and under the auto-layout editor")
do
    local p = Profile()
    DandersFramesDB_v2 = { currentProfile = "Main", profiles = { Main = p } }
    errs, activated = {}, nil
    IN_COMBAT = true
    eq(DF:ResetGroupFrames(), false, "combat: refused")
    IN_COMBAT = false
    eq(p.party.frameWidth, 300, "combat: nothing changed")
    eq(activated, nil, "combat: no activation")
    eq(errs[1], "Cannot use this action in combat.", "combat: says why")

    errs = {}
    DF.AutoProfilesUI = { IsEditing = function() return true end }
    eq(DF:ResetGroupFrames(), false, "editing: refused while an auto layout is edited")
    eq(p.raid.frameWidth, 250, "editing: nothing changed")
    eq(errs[1], "Finish editing the auto layout first.", "editing: says why")
    DF.AutoProfilesUI = nil
end

DandersFramesDB_v2 = prevDB
IN_COMBAT = false
