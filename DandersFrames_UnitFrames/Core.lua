local addonName, UF = ...

-- ============================================================
-- DANDERSFRAMES UNIT FRAMES -- CORE
-- Namespace, the per-unit settings chain, the combat queue and start-up.
--
-- The frames are ordinary DandersFrames frames (DandersUnitButtonTemplate made
-- standalone with DF:InitStandaloneFrame) painted by DF's own updaters. This
-- addon only spawns them, feeds them their unit events and owns what DF has no
-- equivalent for (Blizzard frame hiding per unit, the mover bridge).
-- ============================================================

local DF = DandersFrames
if not DF then return end   -- RequiredDeps guarantees it; a broken install must not error

local pairs, ipairs, type, setmetatable = pairs, ipairs, type, setmetatable
local InCombatLockdown = InCombatLockdown

DF.UnitFrames = UF
UF.DF = DF
UF.ADDON = addonName

-- Every unit the settings table knows. boss1-5 share one "boss" table.
-- focustarget (v1.1): the focus's target, the target-of-target pattern on focus.
UF.UNITS = { "player", "target", "targettarget", "focus", "focustarget", "pet", "boss" }
-- The units this build spawns. "boss" is a container of UF.BOSS_COUNT slots
-- (Boss.lua), whose frames sit in UF.frames as boss1..bossN.
UF.SPAWNED_UNITS = { "player", "target", "targettarget", "focus", "focustarget", "pet", "boss" }

-- Built-in Text Designer presets (preset NAMES are db keys: never localised).
UF.TEXT_PRESET = "Unit Frames"
UF.TEXT_PRESET_SMALL = "Unit Frames (Small)"

-- Spawned frames by key: the unit for most, boss1..bossN for the boss slots.
-- ⚠ The key is not always the settings unit: read f.dfUFUnit for that.
UF.frames = UF.frames or {}

local function Debug(fmt, ...) DF:Debug("UF", fmt, ...) end
UF.Debug = Debug

-- ============================================================
-- SETTINGS: THE PER-UNIT CHAIN
-- The effective table for a unit reads, in order:
--   DF.db.unitframes.units[u]   the user's own values (writes land here)
--   UF.UnitDefaults[u]          this unit's defaults (Defaults.lua)
--   DF.PartyDefaults            every other key DF's reused updaters read
-- The last link is the party DEFAULTS table, never the user's party profile, so
-- party edits never leak into unit frames.
--
-- ⚠ A TABLE value that comes from a defaults link is COPIED into the unit's own
-- table on first read. Handing out the defaults table itself would let any
-- in-place edit (a colour picker writing .r) poison the defaults for every unit
-- and every profile. Scalars are not copied, so the stored table stays sparse.
-- The effective table is a proxy: pairs() over it yields nothing, the same as
-- DF's raid proxy. Iterate UF:GetStoredUnit(u) for the stored keys.
-- One proxy per unit, built once; rebuilt when the profile changes.
-- ============================================================
local effCache = {}

local function Root()
    local db = DF.db
    local t = db and db.unitframes
    return type(t) == "table" and t or nil
end

-- The unit's stored table in the live profile (created when absent), or nil
-- before the profile exists.
function UF:GetStoredUnit(unit)
    local root = Root()
    if not root then return nil end
    if type(root.units) ~= "table" then root.units = {} end
    local t = root.units[unit]
    if type(t) ~= "table" then
        t = {}
        root.units[unit] = t
    end
    return t
end

-- ============================================================
-- DEFAULTS ADAPTERS (spec D9)
-- DandersFrames' modified dots, Changed Settings and override hooks ask
-- DF.Defaults, which only understands the party/raid tables. A unit's effective
-- table and the module-wide table register how they answer: the default is the
-- chain's (UF:GetUnitDefault / UF.GlobalDefaults), "overridden" means the stored
-- table holds a value of its own, and a reset drops that value. Kept by DF in a
-- weak-keyed table, so nothing reaches the saved variables.
-- ⚠ The closures hold the STORED table and the unit, never the proxy they are
-- registered for (a weak-keyed entry whose value holds its key is never freed).
-- ============================================================
local function RegisterUnitAdapter(eff, unit, stored)
    local D = DF.Defaults
    if not (D and D.RegisterAdapter) then return end
    D:RegisterAdapter(eff, {
        getDefault = function(key) return UF:GetUnitDefault(unit, key) end,
        isOverride = function(key) return rawget(stored, key) ~= nil end,
        getStored = function(key) return rawget(stored, key) end,
        resetOverride = function(key) stored[key] = nil end,
    })
end

-- The module-wide table: the spec reads the LIVE profile's (never a captured one),
-- so one spec serves every profile's table.
local function LiveGlobal()
    local root = Root()
    return root and type(root.global) == "table" and root.global or nil
end
local GLOBAL_ADAPTER = {
    getDefault = function(key) return UF.GlobalDefaults and UF.GlobalDefaults[key] end,
    isOverride = function(key) local g = LiveGlobal(); return g ~= nil and rawget(g, key) ~= nil end,
    getStored = function(key) local g = LiveGlobal(); return g and rawget(g, key) end,
    resetOverride = function(key) local g = LiveGlobal(); if g then g[key] = nil end end,
}

local function RegisterGlobalAdapter(g)
    local D = DF.Defaults
    if not (D and D.RegisterAdapter) or D:GetAdapter(g) then return end
    D:RegisterAdapter(g, GLOBAL_ADAPTER)
end

-- The module-wide table (DF.db.unitframes.global), or nil before the profile exists.
function UF:GetGlobalDB()
    local root = Root()
    if not root then return nil end
    if type(root.global) ~= "table" then root.global = {} end
    RegisterGlobalAdapter(root.global)
    return root.global
end

-- A module-wide setting, falling back to UF.GlobalDefaults (the stored table is
-- sparse, like the unit tables).
function UF:GetGlobalSetting(key)
    local g = UF:GetGlobalDB()
    local v = g and g[key]
    if v == nil and UF.GlobalDefaults then v = UF.GlobalDefaults[key] end
    return v
end

-- The units test mode's own settings (its test panel): DF.db.unitframes.global.testMode,
-- kept apart from the party and raid test settings. Missing keys are filled from
-- UF.TestDefaults on every read, so the panel's controls and the preview always
-- see a value (a table default is copied, never shared). nil before the profile
-- exists.
function UF:GetTestDB()
    local g = UF:GetGlobalDB()
    if not g then return nil end
    local t = g.testMode
    if type(t) ~= "table" then
        t = {}
        g.testMode = t
    end
    for k, v in pairs(UF.TestDefaults or {}) do
        if t[k] == nil then t[k] = (type(v) == "table" and DF.DeepCopy) and DF:DeepCopy(v) or v end
    end
    return t
end

-- The default for one key of one unit (unit defaults, then party defaults).
function UF:GetUnitDefault(unit, key)
    local ud = UF.UnitDefaults and UF.UnitDefaults[unit]
    local v = ud and ud[key]
    if v == nil and DF.PartyDefaults then v = DF.PartyDefaults[key] end
    return v
end

local function BuildEffective(unit, stored)
    local unitDefaults = (UF.UnitDefaults and UF.UnitDefaults[unit]) or {}
    return setmetatable({}, {
        __realTable = stored,
        __index = function(_, key)
            local v = stored[key]
            if v ~= nil then return v end
            v = unitDefaults[key]
            if v == nil then
                local pd = DF.PartyDefaults
                v = pd and pd[key]
            end
            if type(v) == "table" then
                v = DF:DeepCopy(v)
                stored[key] = v
            end
            return v
        end,
        __newindex = function(_, key, value)
            stored[key] = value
        end,
    })
end

function UF:GetUnitDB(unit)
    local eff = effCache[unit]
    local stored = UF:GetStoredUnit(unit)
    -- ⚠ A cached proxy is only good while it still sits on the live profile's table.
    -- A profile switch replaces that table, and the settings pages can ask for the
    -- unit's table before OnProfileChanged has dropped the cache -- a proxy over the
    -- old table would write the user's changes into the profile they just left.
    if eff then
        local mt = getmetatable(eff)
        if stored == nil or (mt and mt.__realTable == stored) then return eff end
        effCache[unit] = nil
    end
    if not stored then
        -- Before the profile exists: defaults only, and nothing written is kept.
        return BuildEffective(unit, {})
    end
    eff = BuildEffective(unit, stored)
    effCache[unit] = eff
    RegisterUnitAdapter(eff, unit, stored)
    return eff
end

-- The unit's position record: the stored table itself (DandersMover mutates it
-- in place), seeded from the unit's default on first read.
function UF:GetPositionRecord(unit)
    return UF:GetUnitDB(unit).position
end

-- Drop every cached proxy (profile switch, import, reset).
function UF:RebuildUnitDBs()
    for k in pairs(effCache) do effCache[k] = nil end
    for _, f in pairs(UF.frames) do
        f.dfDB = UF:GetUnitDB(f.dfUFUnit)
    end
end

-- ============================================================
-- COMBAT QUEUE
-- Secure work (spawning, sizing, positioning, reparenting Blizzard frames) waits
-- for PLAYER_REGEN_ENABLED. Keyed, so a repeat request replaces the earlier one.
-- ============================================================
local combatQueue, combatOrder = {}, {}

function UF:RunOutOfCombat(key, fn)
    if not InCombatLockdown() then
        fn()
        return true
    end
    if combatQueue[key] == nil then combatOrder[#combatOrder + 1] = key end
    combatQueue[key] = fn
    Debug("queued for combat end: %s", tostring(key))
    return false
end

function UF:FlushCombatQueue()
    if InCombatLockdown() then return end
    local order = combatOrder
    combatOrder = {}
    for _, key in ipairs(order) do
        local fn = combatQueue[key]
        combatQueue[key] = nil
        if fn then
            local ok, err = pcall(fn)
            if not ok then DF:DebugError("UF", "combat-queue %s failed: %s", tostring(key), tostring(err)) end
        end
    end
end

function UF:IsQueued(key) return combatQueue[key] ~= nil end

-- ============================================================
-- TEXT DESIGNER PRESETS
-- Two built-in presets in the profile's Text Designer library, created only when
-- absent so the user's own edits to them are never overwritten:
--   "Unit Frames"         name left, health right, status centre
--   "Unit Frames (Small)" name only, centred (target of target, pet)
-- ============================================================
function UF:EnsureTextPresets()
    local lib = DF.GetTextDesignerPresets and DF:GetTextDesignerPresets()
    if not lib or not DF.NewTextDesignerConfig then return false end
    if not lib[UF.TEXT_PRESET] then
        local cfg = DF:NewTextDesignerConfig()
        for _, e in ipairs(cfg.elements or {}) do
            if e.contentType == "name" then
                e.anchor, e.offsetX, e.offsetY = "LEFT", 6, 0
            elseif e.contentType == "status_text" then
                e.anchor, e.offsetX, e.offsetY = "CENTER", 0, 0
            else
                e.anchor, e.offsetX, e.offsetY = "RIGHT", -6, 0
            end
        end
        lib[UF.TEXT_PRESET] = cfg
        Debug("created Text Designer preset %s", UF.TEXT_PRESET)
    end
    if not lib[UF.TEXT_PRESET_SMALL] then
        local cfg = DF:NewTextDesignerConfig()
        local keep = {}
        for _, e in ipairs(cfg.elements or {}) do
            if e.contentType == "name" then
                e.anchor, e.offsetX, e.offsetY = "CENTER", 0, 0
                e.fontSize = 10
                keep[#keep + 1] = e
            end
        end
        cfg.elements = keep
        lib[UF.TEXT_PRESET_SMALL] = cfg
        Debug("created Text Designer preset %s", UF.TEXT_PRESET_SMALL)
    end
    return true
end

-- ============================================================
-- REFRESH
-- Settings reach the frames after every DF apply drain (one pass per sweep) and
-- through UF:RequestRefresh, which the settings pages call after a write.
-- Layout (size, scale) is secure, so it waits out combat; paint does not.
-- ============================================================
function UF:RefreshAll()
    if not UF.Units then return end
    for _, f in pairs(UF.frames) do
        f.dfTextPresetOverride = f.dfDB and f.dfDB.textDesignerPreset or nil
        -- The follower of a mirrored Text link draws the shared template mirrored.
        f.dfMirrorText = UF.IsTextMirrored and UF:IsTextMirrored(f.dfUFUnit) or false
        UF:RunOutOfCombat("layout:" .. tostring(f.dfUFKey or f.dfUFUnit), function() UF.Units:ApplyLayout(f) end)
        -- The unit-frame-only pieces are plain frames: their layout follows at once,
        -- in combat too (ApplyLayout repeats it with the frame's own, later).
        if UF.Elements then UF.Elements:Call("Layout", f) end
        if UF.Units.ApplyVisibility then UF.Units:ApplyVisibility(f) end
        -- A hidden frame (no target) has nothing to paint; it repaints when it shows.
        if f:IsVisible() then UF.Units:FullRefresh(f) end
    end
    -- The boss container: slot positions, size and scale (secure).
    if UF.Boss and UF.Boss.container then
        UF:RunOutOfCombat("layout:bosscontainer", function() UF.Boss:ApplyLayout() end)
    end
    if UF.Preview and UF.Preview.Refresh then UF.Preview:Refresh() end
    -- A portrait or frame-size change re-sizes an outer rect without moving its
    -- frame: re-solve whatever is anchored to one (Mover.lua, OUTER RECTS).
    if UF.Mover and UF.Mover.RefreshOuter then UF.Mover:RefreshOuter() end
end

local refreshQueued = false
function UF:RequestRefresh()
    if refreshQueued then return end
    refreshQueued = true
    local function run()
        refreshQueued = false
        UF:RefreshAll()
    end
    if C_Timer and C_Timer.After then C_Timer.After(0, run) else run() end
end

-- A profile switch, reset or import: new tables underneath every frame.
function UF:OnProfileChanged()
    if UF.Links then UF.Links:Ensure(Root()) end
    UF:RebuildUnitDBs()
    UF:EnsureTextPresets()
    for _, f in pairs(UF.frames) do
        local unit = f.dfUFUnit
        UF:RunOutOfCombat("position:" .. tostring(unit), function() UF.Units:ApplyPosition(f) end)
    end
    if UF.Mover and UF.Mover.ApplyAll then UF.Mover:ApplyAll() end
    UF:RefreshAll()
    Debug("profile changed: unit frames rebuilt")
end

-- ============================================================
-- RESET (the Modules page's Reset on Unit Frames)
-- The current profile's DF.db.unitframes becomes a new profile's -- every unit's
-- settings and position, the links, the module-wide settings -- and the two
-- built-in Text Designer templates ("Unit Frames", "Unit Frames (Small)") are
-- dropped so EnsureTextPresets makes them fresh. Then what a profile change runs
-- (OnProfileChanged): the default Player/Target link made again (Links:Ensure,
-- which only seeds a table with no unitLinks), the proxies dropped, positions,
-- the mover, live and preview frames.
-- KEPT: the module's on/off switch (the addon list's own, not in the profile),
-- every other profile, and Text Designer presets under any other name (the
-- library is shared with group frames).
-- Returns ok, needsReload: who draws a unit (its `source`) and the hiding of
-- Blizzard's player cast bar only come back with a reload (BlizzardHide.lua).
-- ⚠ Out of combat only: positions, sizes and the mover are secure.
-- ============================================================
local function DrawState()
    local out = {}
    for _, unit in ipairs(UF.SPAWNED_UNITS) do
        local db = UF:GetUnitDB(unit)
        out[#out + 1] = unit .. "=" .. tostring(db and db.source)
    end
    local BH = UF.BlizzardHide
    if BH and BH.ShouldHideCastBar then
        out[#out + 1] = "castbar=" .. tostring(BH:ShouldHideCastBar() and true or false)
    end
    return table.concat(out, ";")
end

function UF:ResetProfile()
    local L = DF.L
    if InCombatLockdown() then
        DF:Err(L["Cannot use this action in combat."])
        return false
    end
    local name = DF.GetCurrentProfile and DF:GetCurrentProfile()
    local profiles = DandersFramesDB_v2 and DandersFramesDB_v2.profiles
    -- The STORED profile, never DF.db (a proxy over it).
    local p = name and type(profiles) == "table" and profiles[name]
    if type(p) ~= "table" then return false end
    local before = DrawState()

    -- What a new profile is seeded with (the profile-root registry), then the
    -- registry's migrate pass, which a fresh seed never gets.
    p.unitframes = nil
    if DF.ApplyProfileRootTable then DF:ApplyProfileRootTable(p, "unitframes") end
    if type(p.unitframes) ~= "table" then p.unitframes = DF:DeepCopy(UF.ProfileDefaults or {}) end
    if UF.MigrateProfileTable then UF.MigrateProfileTable(p.unitframes) end

    local lib = DF.GetTextDesignerPresets and DF:GetTextDesignerPresets()
    if lib then lib[UF.TEXT_PRESET], lib[UF.TEXT_PRESET_SMALL] = nil, nil end

    UF:OnProfileChanged()
    -- A detached cast bar's mover element follows its (now default) settings.
    if UF.Mover and UF.Mover.SyncChildren then UF.Mover:SyncChildren() end

    DF:Say(string.format(L["%s reset to defaults in profile %s."], L["Unit Frames"], name))
    return true, DrawState() ~= before
end

-- ============================================================
-- START-UP
-- Spawns at our own ADDON_LOADED (DandersFrames, a RequiredDep, has already
-- loaded its profile by then). Secure frames cannot be made in combat, so a
-- /reload mid-fight waits for the fight to end.
-- ============================================================
function UF:Init()
    if UF.initialised then return true end
    if not DF.db then return false end
    UF.initialised = true
    -- A profile made after login (none of the registry's migrate passes saw it)
    -- gets its links here: the default one, or the old sync migrated.
    if UF.Links then UF.Links:Ensure(Root()) end
    UF:EnsureTextPresets()
    UF:RunOutOfCombat("init", function()
        if UF.Units then UF.Units:SpawnAll() end
        if UF.BlizzardHide then UF.BlizzardHide:ApplyAll() end
        if UF.Mover then UF.Mover:Init() end
    end)
    if UF.Preview and UF.Preview.Init then UF.Preview:Init() end
    -- Settings writes reach the frames after DF's apply drain.
    if DF.Apply and DF.Apply.AddPostDrain then
        DF.Apply:AddPostDrain(function() UF:RefreshAll() end)
    end
    if DF.RegisterCallback then
        DF.RegisterCallback(UF, "OnProfileChanged", function() UF:OnProfileChanged() end)
    end
    Debug("initialised")
    return true
end

function UF:OnEvent(event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == addonName then UF:Init() end
    elseif event == "PLAYER_LOGIN" then
        UF:Init()
        if UF.Mover and UF.Mover.ApplyAll then UF.Mover:ApplyAll() end
    elseif event == "PLAYER_ENTERING_WORLD" then
        UF:RefreshAll()
    elseif event == "PLAYER_REGEN_ENABLED" then
        UF:FlushCombatQueue()
    end
end

if CreateFrame then
    local loader = CreateFrame("Frame")
    loader:RegisterEvent("ADDON_LOADED")
    loader:RegisterEvent("PLAYER_LOGIN")
    loader:RegisterEvent("PLAYER_ENTERING_WORLD")
    loader:RegisterEvent("PLAYER_REGEN_ENABLED")
    loader:SetScript("OnEvent", function(_, event, arg1) UF:OnEvent(event, arg1) end)
    UF.loader = loader
end
