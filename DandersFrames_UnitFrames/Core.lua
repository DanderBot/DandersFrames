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
-- Built-in templates for Ring-style frames (UF:EnsureTextPresets, RING PRESETS).
UF.RING_TEXT_PRESET = "Unit Frames Ring"   -- every unit's default in RING style
UF.RING_TEXT_PRESETS = { default = UF.RING_TEXT_PRESET, plate = "Ring: Side Plate",
                         tag = "Ring: Name and Tag", hover = "Ring: Centre on Hover" }

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

-- ============================================================
-- THE FRAME VIEW (Rings.lua)
-- What a unit's FRAMES read (f.dfDB). In BARS style it is the unit's own table,
-- the very same proxy. In RING style it is a view over that table which answers
-- a few keys for the ring (R.FrameValue: the frame is a ringSize square, the bars
-- that rings replace are off) and passes every other read and every write to the
-- unit's table. The settings pages always read UF:GetUnitDB, never this.
-- ============================================================
local viewCache = {}

function UF:FrameDB(unit)
    local eff = UF:GetUnitDB(unit)
    local R = UF.Rings
    if not (R and R.IsRing(eff)) then return eff end
    local cached = viewCache[unit]
    if cached and cached.src == eff then return cached.view end
    local stored = getmetatable(eff) and getmetatable(eff).__realTable
    local view = setmetatable({}, {
        __realTable = stored,
        __index = function(_, key)
            local handled, v = R.FrameValue(eff, key)
            if handled then return v end
            return eff[key]
        end,
        __newindex = function(_, key, value) eff[key] = value end,
    })
    viewCache[unit] = { src = eff, view = view }
    return view
end

-- The unit's position record: the stored table itself (DandersMover mutates it
-- in place), seeded from the unit's default on first read.
function UF:GetPositionRecord(unit)
    return UF:GetUnitDB(unit).position
end

-- Drop every cached proxy (profile switch, import, reset).
function UF:RebuildUnitDBs()
    for k in pairs(effCache) do effCache[k] = nil end
    for k in pairs(viewCache) do viewCache[k] = nil end
    for _, f in pairs(UF.frames) do
        f.dfDB = UF:FrameDB(f.dfUFUnit)
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
    for key, name in pairs(UF.RING_TEXT_PRESETS) do
        if not lib[name] then
            local cfg = UF.BuildRingTextPreset(key)
            if cfg then
                lib[name] = cfg
                Debug("created Text Designer preset %s", name)
            end
        end
    end
    return true
end

-- ============================================================
-- RING PRESETS (Text Designer templates for a Ring-style frame, Rings.lua)
-- Made like the two above: once, when absent, so the user's edits stand.
--   default "Unit Frames Ring"      the default: name over the top of the frame, a
--                                   dark box along the bottom with current || max
--                                   health on it, status in the middle
--   plate  "Ring: Side Plate"       a rounded box tucked BEHIND the ring's right
--                                   side (Background element, layer Behind), name /
--                                   health (abbreviated . percent) / power on
--                                   three lines inside it, clear of the ring
--   tag    "Ring: Name and Tag"     the name above the ring; a pill under it with
--                                   health % | power
--   hover  "Ring: Centre on Hover"  health % large in the middle, exact health under
--                                   it, the name above the ring, all three shown on
--                                   hover. Carries dimPortraitOnHover: picking it on
--                                   a unit's page turns that unit's Dim on Hover on
--                                   (Pages.lua UFO.DesignerTarget), so the text
--                                   reads over the portrait.
-- Anchors are the renderer's ring spots (TextDesigner/Render.lua SPOT ANCHORS):
-- on a Bars frame they fall back to the frame's edges.
-- ============================================================
local function NewRingConfig()
    local TDm = DF.TextDesigner
    local cfg = (TDm and TDm.EnsureDB and TDm:EnsureDB({})) or { elements = {}, nextElementID = 1, globalDefaults = {} }
    cfg.enabled = true
    cfg.hideLegacyText = true
    cfg.elements = {}
    cfg.nextElementID = 1
    return cfg
end

-- One element: `t` over the shared defaults. fontSize sets its own override.
local function Element(cfg, t)
    local e = { id = cfg.nextElementID, enabled = true, label = "", anchor = "CENTER",
                offsetX = 0, offsetY = 0, anchorTo = "FRAME", overrides = {} }
    for k, v in pairs(t) do e[k] = v end
    if t.fontSize then e.overrides.fontSize = true end
    cfg.nextElementID = cfg.nextElementID + 1
    cfg.elements[#cfg.elements + 1] = e
    return e
end

-- "Unit Frames Ring": literal, element by element, ids and all.
local function BuildDefaultRingText(cfg)
    local FONT = "DF Roboto SemiBold"
    local function Text(t)
        t.enabled, t.anchorTo, t.offsetX = true, "FRAME", 0
        t.offsetY = t.offsetY or 0
        t.font, t.outline, t.useClassColor, t.hoverSlide = FONT, "SHADOW", false, t.hoverSlide or 0
        t.label = t.label or ""
        t.color = t.color or { r = 1, g = 1, b = 1, a = 1 }
        t.overrides = t.overrides or { outline = true, font = true, useClassColor = true, fontSize = true, color = true }
        return t
    end
    cfg.elements = {
        Text({ id = 1, contentType = "name", anchor = "TOP", offsetY = 12, fontSize = 13,
               nameLength = 10, truncateMode = "ELLIPSIS" }),
        Text({ id = 2, contentType = "group", label = "Health", anchor = "BOTTOM", offsetY = -4, fontSize = 12,
               groupSeparator = " || ",
               groupItems = { { contentType = "hp_current", abbreviate = true, hideWhenZero = false },
                              { contentType = "hp_max", abbreviate = true } } }),
        Text({ id = 3, contentType = "status_text", anchor = "CENTER", fontSize = 12 }),
        Text({ id = 6, contentType = "backdrop", anchor = "BOTTOM", offsetY = -8, width = 84, height = 21,
               shape = "BOX", layer = "FRONT", color = { r = 0, g = 0, b = 0, a = 0.6 }, fontSize = 16,
               hoverSlide = -3, overrides = { fontSize = true } }),
    }
    cfg.nextElementID = 7
    cfg.previewScale = 1
    cfg.globalDefaults = { font = FONT, fontSize = 10, color = { r = 1, g = 1, b = 1, a = 1 },
                           outline = "SHADOW;NONE", useClassColor = false }
    return cfg
end

function UF.BuildRingTextPreset(key)
    local cfg = NewRingConfig()
    if key == "default" then
        BuildDefaultRingText(cfg)
    elseif key == "plate" then
        -- The plate starts 14px under the ring's right edge (tucked behind it) and
        -- its text starts 4px past that edge.
        local plate = Element(cfg, { contentType = "backdrop", anchorTo = "RING_GAP_RIGHT", anchor = "LEFT",
            offsetX = -14, width = 112, height = 46, shape = "BOX", layer = "BEHIND",
            color = { r = 0.05, g = 0.05, b = 0.05, a = 0.75 } })
        local pid = tostring(plate.id)
        Element(cfg, { contentType = "name", anchorTo = pid, anchor = "TOPLEFT", offsetX = 18, offsetY = -4,
            nameLength = 12, fontSize = 11 })
        Element(cfg, { contentType = "group", anchorTo = pid, anchor = "LEFT", offsetX = 18, offsetY = 0,
            groupSeparator = " · ", fontSize = 10,
            groupItems = { { contentType = "hp_current", abbreviate = true }, { contentType = "hp_percent", decimals = 0 } } })
        Element(cfg, { contentType = "power_current", anchorTo = pid, anchor = "BOTTOMLEFT", offsetX = 18, offsetY = 4,
            abbreviate = true, fontSize = 9 })
    elseif key == "tag" then
        Element(cfg, { contentType = "name", anchorTo = "RING_ABOVE", anchor = "BOTTOM", offsetY = 2,
            nameLength = 14, fontSize = 11 })
        local pill = Element(cfg, { contentType = "backdrop", anchorTo = "RING_BELOW", anchor = "TOP", offsetY = -2,
            width = 78, height = 16, shape = "PILL", layer = "FRONT",
            color = { r = 0, g = 0, b = 0, a = 0.7 } })
        Element(cfg, { contentType = "group", anchorTo = tostring(pill.id), anchor = "CENTER",
            groupSeparator = " | ", fontSize = 10,
            groupItems = { { contentType = "hp_percent", decimals = 0 }, { contentType = "power_current", abbreviate = true } } })
    elseif key == "hover" then
        cfg.dimPortraitOnHover = true
        Element(cfg, { contentType = "hp_percent", anchorTo = "RING_CENTER", anchor = "CENTER", offsetY = 3,
            decimals = 0, fontSize = 16, showOnHover = true })
        Element(cfg, { contentType = "hp_current", anchorTo = "RING_CENTER", anchor = "TOP", offsetY = -6,
            abbreviate = true, fontSize = 9, showOnHover = true })
        Element(cfg, { contentType = "name", anchorTo = "RING_ABOVE", anchor = "BOTTOM", offsetY = 2,
            nameLength = 14, fontSize = 11, showOnHover = true, hoverSlide = 0 })
    else
        return nil
    end
    return cfg
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
        -- Bars or Ring: the frame reads its unit's table or the ring view of it.
        f.dfDB = UF:FrameDB(f.dfUFUnit)
        UF:StampDesigners(f)
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

-- ============================================================
-- LIVE (a settings slider or colour picker mid-drag)
-- One rendered frame's worth of repaint for ONE setting of ONE unit, called by
-- the unit frame pages' sliders and pickers while they are dragged (the kit's
-- lightweight callback, DandersFrames_Options/UnitFrames/Pages.lua UFO.LiveSlider).
-- Only the part the key belongs to is re-applied, on that unit's frames: the live
-- one(s), and the preview while it is up. The full UF:RefreshAll still runs once, on
-- release (the control's own callback).
--   * A key with a painter (LivePaint.lua): that painter. Plain paint: combat-safe.
--   * A unit-frame element (cast bar, class power, portrait, unit icons): its
--     own Layout (+ Preview on a preview frame). Plain frames: combat-safe.
--   * DandersFrames' pieces: DF:ApplyFrameLayout on the one frame (the Frame
--     page: the frame's whole layout, scale and size included). It sizes the
--     unit button, which is SECURE: a live frame is skipped in combat.
--   * Auras: DandersFrames' aura layout version, then the frame's own rows.
--   * Highlights / Fading: their own per-frame updaters.
--   * Boss Layout: the container (secure: skipped in combat) / the preview's.
-- A preview frame is never secure: it is repainted in full (P:Paint, one frame).
-- A linked partner follows: the one key is pushed across (Links:PushKey) and it
-- repaints the same way.
-- ============================================================
UF.LIVE_ELEMENTS = {
    castbar = { "CastBar" },
    -- The portrait's and the attached class power bar's rects are also the
    -- resting glow's (Include Portrait; IN.GlowRects).
    classpower = { "ClassPower", "Indicators" },
    portrait = { "Portrait", "Indicators" }, unitIcons = { "Indicators" },
    -- The ring list: the rings, the portrait inside them, class power in a ring.
    rings = { "Rings", "Portrait", "ClassPower" },
}
-- Single keys an element of ours draws although DandersFrames' page owns them: the
-- combat icon is DF's (the Icons element), its border is Indicators.lua's.
UF.LIVE_KEYS = { combatIconBorderSize = { "Indicators" }, combatIconBorderColor = { "Indicators" } }
UF.LIVE_AURAS = { buffs = true, debuffs = true, defensive = true, dispel = true }

-- What the frame reads its settings through.
local function FrameSettings(f)
    return rawget(f, "dfDB") or UF:FrameDB(f.dfUFUnit)
end

local function InCombat()
    local f = _G.InCombatLockdown
    return f and f() and true or false
end

-- fn(f, isPreview) for every frame drawing `unit`.
function UF:EachFrameOf(unit, fn)
    for _, f in pairs(UF.frames) do
        if f.dfUFUnit == unit then fn(f, false) end
    end
    local P = UF.Preview
    if not (P and P.shown) then return end
    local pf = P.frames and P.frames[unit]
    if pf and pf:IsShown() then fn(pf, true) end
    local B = UF.Boss
    if unit == "boss" and B and B.preview then
        for _, bf in pairs(B.preview) do
            if bf:IsShown() then fn(bf, true) end
        end
    end
end

-- `key` may be nil (a slider with no db key of its own): `kind`, the page's
-- element, answers then.
function UF:LiveApply(unit, key, kind)
    if not (unit and UF.Units) then return end
    UF:LiveApplyUnit(unit, key, kind)
    local Links = UF.Links
    local root = key and Links and Links.PushKey and Links.LiveRoot()
    local partner = root and Links:PushKey(root, unit, key)
    if partner then UF:LiveApplyUnit(partner, key, kind) end
end

-- A preview frame: its element's own Layout + Preview, else repainted in full.
local function LivePreview(f, mods)
    if mods then
        for _, name in ipairs(mods) do
            local m = UF[name]
            if m and m.Layout then m:Layout(f) end
            if m and m.Preview then m:Preview(f) end
        end
    elseif UF.Preview.Paint then
        UF.Preview:Paint(f)
    end
end

-- The frame's size or scale on Boss is the container's too.
UF.LIVE_BOSS_CONTAINER = { frameWidth = true, frameHeight = true, frameScale = true, ringSize = true }

function UF:LiveApplyUnit(unit, key, kind)
    local Links = UF.Links
    local elem = (key and Links and Links.OwnerOf and Links.OwnerOf(key)) or kind
    if elem == "tooltips" then return end
    -- Ring Size is the frame's size in RING style: the whole frame's layout.
    if key == "ringSize" then elem = "frame" end

    local LP = UF.LivePaint
    local painter, shared
    if LP then painter, shared = LP.For(key, kind) end
    if painter then
        local mods = elem and UF.LIVE_ELEMENTS[elem]
        local function paint(f, preview)
            if preview then
                LivePreview(f, mods)
            else
                painter(f, FrameSettings(f))
            end
        end
        if shared then
            for _, u in ipairs(UF.UNITS or {}) do UF:EachFrameOf(u, paint) end
        else
            UF:EachFrameOf(unit, paint)
        end
        return
    end

    if key and unit == "boss" and UF.LIVE_BOSS_CONTAINER[key] and not InCombat() then
        local B = UF.Boss
        if B and B.container and B.LayoutContainer then B:LayoutContainer(B.container, B.frames) end
    end

    if elem == "bosslayout" then
        local B = UF.Boss
        if not B then return end
        if B.container and not InCombat() then B:LayoutContainer(B.container, B.frames) end
        if B.previewShown and B.PreviewRefresh then B:PreviewRefresh() end
        return
    end

    local mods = (key and UF.LIVE_KEYS[key]) or (elem and UF.LIVE_ELEMENTS[elem])
    if mods then
        UF:EachFrameOf(unit, function(f, preview)
            if preview then
                LivePreview(f, mods)
                return
            end
            for _, name in ipairs(mods) do
                local m = UF[name]
                -- LiveLayout: the same, without what must not run per drag frame.
                if m and m.LiveLayout then m:LiveLayout(f) elseif m and m.Layout then m:Layout(f) end
            end
        end)
        return
    end

    if UF.LIVE_AURAS[elem] then
        if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
    end
    local combat = InCombat()
    UF:EachFrameOf(unit, function(f, preview)
        if preview then
            LivePreview(f)
            return
        end
        if elem == "highlights" then
            if DF.UpdateHighlights then DF:UpdateHighlights(f) end
            return
        elseif elem == "fading" then
            if DF.UpdateRange then DF:UpdateRange(f) end
            if DF.UpdateHealthFade then DF:UpdateHealthFade(f) end
            return
        elseif UF.LIVE_AURAS[elem] then
            if DF.DriveFactoryRowsNow then DF.DriveFactoryRowsNow(f) end
            return
        elseif combat then
            return
        elseif elem == "frame" then
            UF.Units:ApplyLayout(f)
        elseif DF.ApplyFrameLayout then
            DF:ApplyFrameLayout(f)
        end
        -- Bar sizes and fills follow the new layout at once.
        if f:IsVisible() and UF.Units.RepaintValues then UF.Units:RepaintValues(f) end
    end)
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
    if lib then
        lib[UF.TEXT_PRESET], lib[UF.TEXT_PRESET_SMALL] = nil, nil
        for _, name in pairs(UF.RING_TEXT_PRESETS) do lib[name] = nil end
    end

    UF:OnProfileChanged()
    -- A detached cast bar's mover element follows its (now default) settings.
    if UF.Mover and UF.Mover.SyncChildren then UF.Mover:SyncChildren() end

    DF:Say(string.format(L["%s reset to defaults in profile %s."], L["Unit Frames"], name))
    return true, DrawState() ~= before
end

-- ============================================================
-- PER-UNIT DESIGNER TEMPLATES (spec 2026-11-01-uf-per-unit-designers.md, phase 1)
-- Every unit names its own Text Designer template, ONE PER FRAME STYLE:
-- textDesignerPreset for Bars (defaults "Unit Frames" / "Unit Frames (Small)") and
-- ringTextDesignerPreset for Ring. The Ring frame view answers textDesignerPreset
-- with the ring key (Rings.lua R.FrameValue), so whatever reads a frame's table
-- follows the style; what reads the UNIT's table asks UF.TextTemplateKey. And an
-- Aura Designer template
-- (auraDesignerPreset). An AURA template left unset follows the Party frames'
-- CURRENT one -- what the page always said -- rather than the template literally
-- named "Party", DandersFrames' fallback for a standalone frame with no name.
-- Both reach the frame as its per-frame stamp (dfTextPresetOverride /
-- dfAuraPresetOverride), which DandersFrames' resolver reads first. The enable
-- stays the unit's own (DF:IsAuraDesignerEnabled asks a standalone frame's table
-- before the stamp).
-- ============================================================
UF.DESIGNER_KINDS = { text = "textDesignerPreset", aura = "auraDesignerPreset" }
UF.RING_TEXT_KEY = "ringTextDesignerPreset"

-- The key holding the template of a unit's ACTIVE style.
function UF.TextTemplateKey(db)
    if db and db.frameStyle == "RING" then return UF.RING_TEXT_KEY end
    return UF.DESIGNER_KINDS.text
end

-- Template names are library KEYS and travel in exports: never localised.
UF.UNIT_TEMPLATE_NAMES = {
    player = "Player", target = "Target", targettarget = "Target of Target",
    focus = "Focus", focustarget = "Focus Target", pet = "Pet", boss = "Boss",
}

-- How a unit names itself in DandersFrames' "also used by" list of a template.
function UF:CarrierLabel(unit)
    local L = DF.L
    if not L then return nil end
    return string.format(L["%s (%s)"], L[UF.UNIT_TEMPLATE_NAMES[unit] or unit], L["Unit Frames"])
end

-- The Aura Designer template a unit's frames draw with (a name).
function UF:AuraTemplateFor(db)
    local name = db and db.auraDesignerPreset
    if name then return name end
    if DF.GetModeDesignerPresetName then return DF:GetModeDesignerPresetName("aura", "party") end
    return nil
end

-- The template `unit` uses for designer `kind` ("text" | "aura").
function UF:UnitTemplate(unit, kind)
    local db = UF:GetUnitDB(unit)
    if kind == "aura" then return UF:AuraTemplateFor(db) end
    return db and db[UF.TextTemplateKey(db)]
end

-- Stamp a frame with its unit's templates (build, refresh, preview paint).
function UF:StampDesigners(f, db)
    db = db or f.dfDB
    f.dfTextPresetOverride = db and db.textDesignerPreset or nil
    f.dfAuraPresetOverride = UF:AuraTemplateFor(db)
end

-- A template of the unit's own: a copy of the one it uses now, named for the
-- unit ("Target", "Target 2", ...), and the unit pointed at it. Returns the name.
function UF:MakeOwnTemplate(unit, kind)
    local key = UF.DESIGNER_KINDS[kind]
    if not (key and DF.DuplicateDesignerPreset and DF.CreateDesignerPreset) then return nil end
    if kind == "text" then key = UF.TextTemplateKey(UF:GetUnitDB(unit)) end
    local from = UF:UnitTemplate(unit, kind)
    local base = UF.UNIT_TEMPLATE_NAMES[unit] or tostring(unit)
    local name = from and DF:DuplicateDesignerPreset(kind, from, base) or nil
    if not name then name = DF:CreateDesignerPreset(kind, base) end
    if not name then return nil end
    UF:GetUnitDB(unit)[key] = name
    return name
end

-- DandersFrames' rename / delete / import / "also used by" walks reach the unit
-- tables (DF:RegisterDesignerRefCarrier). The LIVE profile's units are walked
-- through their effective tables, so a unit on its default template counts as a
-- user of it and a rename stores the new name; one following Party's Aura template
-- is listed as a user of it (`uses`) but keeps following through a rename or a
-- delete. Any other profile (an import payload) is walked raw.
-- ★ THE RING TEMPLATE IS WALKED AS A SECOND CARRIER: DandersFrames' walks only know
-- the one ref key per kind, so RingTextCarrier shows them ringTextDesignerPreset
-- under the name textDesignerPreset. Rename, delete, pruning and import then repoint
-- it like any other ref. It carries no label: the "also used by" list names a unit
-- once, for the template of its ACTIVE style (`uses` above).
local function RingTextCarrier(tbl)
    local textKey = UF.DESIGNER_KINDS.text
    return setmetatable({}, {
        __index = function(_, k) if k == textKey then return tbl[UF.RING_TEXT_KEY] end end,
        __newindex = function(_, k, v) if k == textKey then tbl[UF.RING_TEXT_KEY] = v end end,
    })
end

function UF.DesignerRefWalker(profile, fn)
    local root = type(profile) == "table" and profile.unitframes
    if type(root) ~= "table" or type(root.units) ~= "table" then return end
    local live = (root == Root())
    local L = DF.L
    for _, unit in ipairs(UF.UNITS) do
        local stored = root.units[unit]
        if type(stored) == "table" then
            local label = L and UF:CarrierLabel(unit) or nil
            if live then
                local eff = UF:GetUnitDB(unit)
                -- What it draws with: an unset Aura template follows Party's.
                local function uses(refKey)
                    if refKey == UF.DESIGNER_KINDS.aura then return UF:AuraTemplateFor(eff) end
                    if refKey == UF.DESIGNER_KINDS.text then return eff[UF.TextTemplateKey(eff)] end
                    return eff[refKey]
                end
                fn(eff, "unit", label, uses)
                fn(RingTextCarrier(eff), "unit")
            else
                fn(stored, "unit", label)
                fn(RingTextCarrier(stored), "unit")
            end
        end
    end
end
if DF.RegisterDesignerRefCarrier then DF:RegisterDesignerRefCarrier(UF.DesignerRefWalker) end

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
