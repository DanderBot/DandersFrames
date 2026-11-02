local _, UF = ...

-- ============================================================
-- LIVE PAINTERS (a settings slider or colour picker mid-drag)
-- What one drag frame repaints for one setting: the smallest updater that reads the
-- key, on one frame, so a drag never refreshes the whole frame. UF:LiveApply (Core.lua)
-- asks LP.For; a key with no painter keeps LiveApply's element path. The full refresh
-- still runs once, on release.
-- Painters are plain paint (nothing here sizes or moves a secure frame), so they run in
-- combat. They never touch a preview: a preview takes LiveApply's preview path.
--   LP.For(key, kind) -> painter, shared
--   shared: the setting is the profile's, not the unit's (reaction and power colours),
--   so every unit repaints.
-- ============================================================

local DF = DandersFrames
if not DF then return end

local E = UF.Elements
local K = E and E.Kit
if not K then return end

local LP = {}
UF.LivePaint = LP

local function Health(f) DF:UpdateHealthBarAppearance(f) end

local function Tracks(f)
    local R = UF.Rings
    if R and R.PaintTracks then R:PaintTracks(f) end
end

local function Background(f)
    DF:UpdateBackgroundAppearance(f)
    Tracks(f)
end

local function Missing(f)
    if f.missingHealthBar and DF.SetMissingHealthBarValue then
        DF.SetMissingHealthBarValue(f.missingHealthBar, f.unit, f)
    end
end

-- A gradient stop's colour: the curves first, they are built from the stops.
local function GradientStop(f)
    DF:UpdateColorCurve()
    Health(f)
    Background(f)
    Missing(f)
end

local function HealthLayers(f, db)
    local bar = f.healthBar
    if not (bar and DF:BarTextureLayersWanted(bar, db, "health")) then return end
    local o = db.healthOrientation
    DF:ApplyBarTextureLayers(bar, "health", db, {
        span = bar, isVertical = (o == "VERTICAL" or o == "VERTICAL_INV"),
    })
end

local function ReducedMax(f) DF:UpdateReducedMaxHealth(f) end

-- The absorb bars inset by the border, so they follow it.
local function Border(f, db)
    DF:ApplyFrameBorder(f, db)
    DF:UpdateAbsorb(f)
    DF:UpdateHealAbsorb(f)
end

local function FrameAlpha(f) DF:UpdateFrameAppearance(f) end

local function Padding(f, db)
    DF:AnchorHealthBarsToPadding(f, db)
    DF:LayoutResourceBar(f, db)
end

local function Resource(f, db)
    DF:LayoutResourceBar(f, db)
    Tracks(f)
end

local function Power(f)
    DF:UpdatePower(f)
    local R = UF.Rings
    if R and R.FeedPower then R:FeedPower(f) end
end

local function Absorb(f) DF:UpdateAbsorb(f) end
local function HealAbsorb(f) DF:UpdateHealAbsorb(f) end
local function HealPrediction(f) DF:UpdateHealPrediction(f) end

-- Every part's fade: oor*, fadeDead*. Ends in the unit frame's own parts
-- (UF.OnElementAppearance).
local function Fades(f) DF:UpdateAllElementAppearances(f) end

local function HealthFade(f)
    if DF.UpdateHealthFade then DF:UpdateHealthFade(f) end
end

-- RefreshUnhealableFade is the only way to move its settings version on; it walks the
-- group frames, this frame is ours.
local function Unhealable(f)
    DF:RefreshUnhealableFade()
    DF:DriveUnhealableFade(f)
end

local function CastFill(f)
    local cb, CB = f.dfUFCastBar, UF.CastBar
    if cb and CB and cb.active then CB:PaintColor(cb, cb.kickReady) end
end

local function Decorations(f)
    local IN = UF.Indicators
    if IN and IN.Update then IN:Update(f) end
end

-- Nothing to show during a drag: the release's refresh has it.
local function Nothing() end

-- A status icon's own updater, by key prefix. Each returns at once while the icon has
-- nothing to show.
LP.ICONS = {
    role = "UpdateRoleIcon", leader = "UpdateLeaderIcon", raidRole = "UpdateRaidRoleIcon",
    raidTarget = "UpdateRaidTargetIcon", ping = "UpdatePingIcon", readyCheck = "UpdateReadyCheckIcon",
    summon = "UpdateSummonIcon", resurrection = "UpdateResurrectionIcon", afk = "UpdateAFKIcon",
    vehicle = "UpdateVehicleIcon", combat = "UpdateCombatIcon", bgCarrier = "UpdateBGCarrierIcon",
}
-- These have a separate alpha updater.
LP.ICON_ALPHA = {
    roleIconAlpha = "UpdateRoleIconAppearance", leaderIconAlpha = "UpdateLeaderIconAppearance",
    raidTargetIconAlpha = "UpdateRaidTargetIconAppearance", readyCheckIconAlpha = "UpdateReadyCheckIconAppearance",
}

local function Method(name)
    return function(f)
        local fn = DF[name]
        if fn then fn(DF, f) end
    end
end

LP.KEYS = {
    classColorAlpha = Health, healthColor = Health, oorHealthBarAlpha = Health,
    backgroundColor = Background, backgroundClassAlpha = Background, fadeDeadBackgroundColor = Background,
    framePadding = Padding,
    resourceBarCustomColor = Power,
    rangeFadeAlpha = Fades,
    rangeUpdateInterval = Nothing, readyCheckIconPersist = Nothing, castbarFailedColor = Nothing,
    statusIconFontSize = Method("UpdateAllStatusIcons"),
    castbarColor = CastFill, castbarNonInterruptibleColor = CastFill, castbarChannelColor = CastFill,
    castbarKickNotReadyColor = CastFill,
    classDragonEliteColor = Decorations, classDragonRareColor = Decorations,
    classDragonRareEliteColor = Decorations, classDragonBossColor = Decorations,
    -- A gradient chip writes a stop's own table.
    color = GradientStop,
}
for key, name in pairs(LP.ICON_ALPHA) do LP.KEYS[key] = Method(name) end

-- Longest first where one prefix starts another.
LP.PREFIXES = {
    { "reducedMaxHealth", ReducedMax },
    { "missingHealth", Missing },
    { "healthLayer", HealthLayers },
    { "healthFade", HealthFade },
    { "frameBorder", Border },
    { "frameFade", FrameAlpha },
    { "resourceBar", Resource },
    { "healAbsorbBar", HealAbsorb },
    { "absorbBar", Absorb },
    { "healPrediction", HealPrediction },
    { "fadeUnhealable", Unhealable },
    { "fadeDead", Fades },
    { "oor", Fades },
}

-- The profile's own colour tables: DF.db.reactionColors and DF.db.powerColors.
LP.REACTIONS = { hostile = true, neutral = true, friendly = true, tapped = true }

-- A slider with no db key of its own (Border Alpha) goes by its page.
LP.KINDS = { frame = Border, resource = Resource }

local cache = {}

local function Resolve(key, kind)
    if LP.REACTIONS[key] then return Health, true end
    -- A power type's swatch: its key is the token (MANA, RUNIC_POWER).
    if kind == "resource" and key:find("^%u[%u_]*$") then return Power, true end
    local p = LP.KEYS[key]
    if p then return p end
    for _, row in ipairs(LP.PREFIXES) do
        if key:sub(1, #row[1]) == row[1] then return row[2] end
    end
    local name = key:match("^(%l%a-)Icon%u")
    if name and LP.ICONS[name] and not key:find("^combatIconBorder") then return Method(LP.ICONS[name]) end
    return nil
end

function LP.For(key, kind)
    if not key then return LP.KINDS[kind] end
    local id = tostring(kind) .. ":" .. key
    local hit = cache[id]
    if hit == nil then
        local p, shared = Resolve(key, kind)
        hit = p and { p, shared } or false
        cache[id] = hit
    end
    if hit then return hit[1], hit[2] end
    return nil
end
