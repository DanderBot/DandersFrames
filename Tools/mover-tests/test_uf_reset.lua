local NS = ...

-- ============================================================
-- UNIT FRAMES -- RESET TO DEFAULTS
-- DandersFrames_UnitFrames/Core.lua (UF:ResetProfile)
-- ------------------------------------------------------------
-- The Modules page's Reset on Unit Frames. The current profile's
-- DF.db.unitframes becomes what a new profile is seeded with (the real
-- profile-root registry, cut out of Core/Profile.lua), the default Player /
-- Target link is made again (the real Links:Ensure), the built-in text templates
-- are rebuilt, and what a profile change runs follows. The module's on/off switch
-- (the addon list's, not the profile's), every other profile and the rest of the
-- current one are untouched. It answers whether the reset changed who draws a
-- unit -- the one thing only a reload puts back.
-- Real defaults (Core/Config.lua), real prefixes and ownership, as test_uf_links.
-- ============================================================

local saved = {
    DandersFrames = DandersFrames, CreateFrame = CreateFrame, GetLocale = GetLocale,
    C_Timer = C_Timer, DB = DandersFramesDB_v2,
}

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

local function cut(src, marker, closer)
    src = src:gsub("\r\n", "\n")
    local s = src:find(marker, 1, true)
    assert(s, "marker not found: " .. marker)
    local e = src:find("\n" .. closer .. "\n", s, true)
    assert(e, "closer not found after: " .. marker)
    return src:sub(s, e + #closer)
end

-- ---- DandersFrames: real defaults, prefixes, ownership, root-table registry --
local DF = {}
CreateFrame = function() return FakeUIFrame() end
GetLocale = function() return "enUS" end
load_df_file_into("Core/Config.lua", DF)
DandersFrames = DF
DF.L = setmetatable({}, { __index = function(_, k) return k end })
function DF:Debug() end
function DF:DebugWarn() end
local errors = {}
function DF:DebugError(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
function DF:DeepCopy(t) return deepcopy(t) end
DF.RegisterCallback = function() end
local said, errs = {}, {}
function DF:Say(msg) said[#said + 1] = msg end
function DF:Err(msg) errs[#errs + 1] = msg end
function DF:GetCurrentProfile() return DandersFramesDB_v2.currentProfile end

local gui = df_file_source("GUI/GUI.lua")
assert(loadstring("local DF = ...\n" .. cut(gui, "DF.SECTION_PREFIXES = {", "}")))(DF)
DF.SectionRegistry = {}
for id, p in pairs(DF.SECTION_PREFIXES) do DF.SectionRegistry[id] = p end
local profileSrc = df_file_source("Core/Profile.lua")
assert(loadstring("local DF = ...\n" .. cut(profileSrc, "function DF:SectionOwnsKey(prefixes, key)", "end")))(DF)
-- The profile-root registry, whole: from its tables to RegisterProfileRootTable.
local reg = profileSrc:gsub("\r\n", "\n")
local ra = reg:find("DF.ProfileRootTables = DF.ProfileRootTables or {}", 1, true)
local rf = reg:find("\nfunction DF:RegisterProfileRootTable(", ra or 1, true)
local rb = rf and reg:find("\nend\n", rf, true)
check(ra and rb, "registry: cut out of Core/Profile.lua")
assert(loadstring("local DF = ...\n" .. reg:sub(ra, rb + 4)))(DF)
check(type(DF.ApplyProfileRootTable) == "function", "registry: the real ApplyProfileRootTable")

-- The shared Text Designer library, as DandersFrames' accessors present it.
local function TDConfig()
    return { elements = { { contentType = "name" }, { contentType = "health_text" },
                          { contentType = "status_text" } } }
end
DF.NewTextDesignerConfig = function() return TDConfig() end
DF.GetTextDesignerPresets = function()
    DF.db.textDesignerPresets = DF.db.textDesignerPresets or {}
    return DF.db.textDesignerPresets
end

-- ---- the companion ------------------------------------------------------------
CreateFrame = nil
C_Timer = { After = function(_, fn) fn() end }
local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Links.lua", UF)
load_uf_file_into("Defaults.lua", UF)
load_uf_file_into("Elements.lua", UF)
local Links = UF.Links
check(type(UF.ResetProfile) == "function", "api: UF:ResetProfile")
check(DF.ProfileRootTables.unitframes ~= nil, "setup: unit frames registered its profile-root table")

local moverCalls = {}
UF.Mover = {
    ApplyAll = function() moverCalls[#moverCalls + 1] = "apply" end,
    SyncChildren = function() moverCalls[#moverCalls + 1] = "children" end,
}
UF.frames = {}

-- A profile the user has worked on: sizes, a moved frame, the module settings,
-- the default link removed, Target handed to Blizzard, the text template edited.
local function WorkedOn()
    local t = deepcopy(UF.ProfileDefaults)
    Links:Ensure(t)
    t.units.player.frameWidth = 999
    t.units.player.position = { point = "TOPLEFT", x = 5, y = -5 }
    t.units.focus.frameScale = 1.5
    t.global.testMode = { showPet = false }
    Links:Unlink(t, "target")
    return t
end

local function Setup(targetSource)
    local main = {
        party = { frameWidth = 321 }, partyEnabled = true,
        unitframes = WorkedOn(),
        textDesignerPresets = {
            [UF.TEXT_PRESET] = { edited = true }, [UF.TEXT_PRESET_SMALL] = { edited = true },
            Mine = { tag = "kept" },
        },
    }
    main.unitframes.units.target.source = targetSource
    local alt = { unitframes = WorkedOn() }
    DandersFramesDB_v2 = { currentProfile = "Main", profiles = { Main = main, Alt = alt } }
    DF.db = main
    UF:RebuildUnitDBs()
    said, errs, moverCalls = {}, {}, {}
    return main, alt
end

print("-- Unit frames reset: the module goes back to a new profile's")
do
    local main, alt = Setup("Blizzard")
    local old = main.unitframes
    check(Links:LinkOf(old, "target") == nil, "setup: the user removed the default link")
    eq(UF:GetUnitDB("player").frameWidth, 999, "setup: the player frame was resized")

    local ok, needsReload = UF:ResetProfile()
    check(ok == true, "reset: it ran")
    local root = main.unitframes
    check(root ~= old, "reset: a new table, not the old one wiped key by key")
    eq(root.units.player.frameWidth, nil, "reset: the stored unit tables are empty again (sparse)")
    eq(UF:GetUnitDB("player").frameWidth, UF.UnitDefaults.player.frameWidth,
       "reset: the player frame reads its default size")
    eq(UF:GetUnitDB("focus").frameScale, 1.0, "reset: ...and focus its default scale")
    eq(UF:GetUnitDB("target").source, "DF", "reset: Target is drawn by DandersFrames again")
    local pos = UF:GetPositionRecord("player")
    local dpos = UF.UnitDefaults.player.position
    check(type(pos) == "table" and pos.x == dpos.x and pos.y == dpos.y, "reset: the player frame is back at its default place")
    eq(UF:GetTestDB().showPet, true, "reset: the units test settings are back at their defaults")
    local link, follower, leader = Links:LinkOf(root, "target")
    check(link ~= nil and follower == "target" and leader == "player",
          "reset: the default Player / Target link is made again")
    eq(root.version, UF.DB_VERSION, "reset: at the current version")

    local lib = main.textDesignerPresets
    check(lib[UF.TEXT_PRESET] and not lib[UF.TEXT_PRESET].edited and lib[UF.TEXT_PRESET].elements,
          "templates: \"Unit Frames\" is rebuilt fresh")
    check(lib[UF.TEXT_PRESET_SMALL] and not lib[UF.TEXT_PRESET_SMALL].edited,
          "templates: ...and \"Unit Frames (Small)\"")
    eq(lib.Mine and lib.Mine.tag, "kept", "templates: a preset under another name is kept")

    eq(main.party.frameWidth, 321, "kept: the rest of the profile (group frames) is untouched")
    eq(main.partyEnabled, true, "kept: ...and its switches")
    eq(alt.unitframes.units.player.frameWidth, 999, "kept: another profile's unit frames are untouched")
    check(Links:LinkOf(alt.unitframes, "target") == nil, "kept: ...links included")

    eq(needsReload, true, "reload: Target changed hands, so a reload is asked for")
    local saw = {}
    for _, c in ipairs(moverCalls) do saw[c] = true end
    check(saw.apply and saw.children, "refresh: the mover re-solves its elements and children")
    check(said[1] and said[1]:find("Main", 1, true), "chat: names the profile")
    eq(#errors, 0, "no errors (" .. tostring(errors[1]) .. ")")
end

print("-- Unit frames reset: no reload when nobody's frame changed hands")
do
    Setup(nil)
    local ok, needsReload = UF:ResetProfile()
    check(ok == true, "reset: it ran")
    eq(needsReload, false, "reload: not asked for")
end

print("-- Unit frames reset: refused in combat")
do
    local main = Setup("Blizzard")
    local old = main.unitframes
    IN_COMBAT = true
    local ok = UF:ResetProfile()
    IN_COMBAT = false
    eq(ok, false, "combat: refused")
    check(main.unitframes == old and old.units.player.frameWidth == 999, "combat: nothing changed")
    eq(errs[1], "Cannot use this action in combat.", "combat: says why")
    eq(#moverCalls, 0, "combat: nothing refreshed")
end

DandersFrames, CreateFrame, GetLocale, C_Timer = saved.DandersFrames, saved.CreateFrame, saved.GetLocale, saved.C_Timer
DandersFramesDB_v2 = saved.DB
IN_COMBAT = false
