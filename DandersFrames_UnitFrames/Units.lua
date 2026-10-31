local addonName, UF = ...

-- ============================================================
-- UNITS
-- Spawns the unit buttons and feeds them their events. Pattern: DandersFrames'
-- pinned boss frames (Features/PinnedFrames.lua, CreateBossFrames) -- a
-- DandersUnitButtonTemplate button with a fixed unit attribute, its OWN
-- RegisterUnitEvent registrations, and every event routed into DF's existing
-- updaters on that frame. Nothing here paints anything itself.
--
--   player        always shown (the parent hides it in pet battles); in a
--                 vehicle the button clicks the vehicle (toggleForVehicle) and
--                 displays it too
--   target        RegisterUnitWatch; PLAYER_TARGET_CHANGED repaints it
--   targettarget  RegisterUnitWatch; the client sends no events for this unit,
--                 so a ticker runs while it is shown: values every tick, a full
--                 repaint when the unit's GUID changes (a secret GUID counts as
--                 changed)
--
-- Events are registered only while a frame is shown (OnShow / OnHide), and a
-- frame is repainted in full when it shows, because a hidden frame misses events.
-- ============================================================

local DF = DandersFrames
if not DF then return end

local pairs, ipairs, pcall = pairs, ipairs, pcall
local InCombatLockdown = InCombatLockdown

local Units = {}
UF.Units = Units

-- How often the target-of-target ticker polls, in seconds.
UF.TOT_INTERVAL = 0.25

local FRAME_NAMES = {
    player = "DandersUnitFramePlayer",
    target = "DandersUnitFrameTarget",
    targettarget = "DandersUnitFrameTargetTarget",
}

-- Shown only while the unit exists (secure unit watch).
local WATCHED = { target = true, targettarget = true }
-- No events of their own: polled by the ticker instead.
local POLLED = { targettarget = true }
-- In DF's range tick (fade when out of range).
local RANGED = { target = true, targettarget = true }

local UNIT_EVENTS = {
    "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_MAX_HEALTH_MODIFIERS_CHANGED",
    "UNIT_POWER_UPDATE", "UNIT_MAXPOWER", "UNIT_DISPLAYPOWER",
    "UNIT_AURA", "UNIT_NAME_UPDATE", "UNIT_FACTION", "UNIT_FLAGS",
    "UNIT_LEVEL", "UNIT_CLASSIFICATION_CHANGED", "UNIT_CONNECTION",
    "UNIT_ABSORB_AMOUNT_CHANGED", "UNIT_HEAL_ABSORB_AMOUNT_CHANGED", "UNIT_HEAL_PREDICTION",
    "UNIT_THREAT_SITUATION_UPDATE",
}
local PLAYER_EVENTS = { "UNIT_ENTERED_VEHICLE", "UNIT_EXITED_VEHICLE", "PLAYER_FLAGS_CHANGED" }

-- The event list a unit's frame registers (empty for a polled unit).
function Units:EventsFor(unit)
    if POLLED[unit] then return {} end
    local list = {}
    for _, ev in ipairs(UNIT_EVENTS) do list[#list + 1] = ev end
    if unit == "player" then
        for _, ev in ipairs(PLAYER_EVENTS) do list[#list + 1] = ev end
    end
    return list
end

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) and true or false
end

local function TD(f, hint)
    if DF.UpdateTextDesigner then DF:UpdateTextDesigner(f, hint) end
end

-- ============================================================
-- PAINTING (DF's updaters, nothing of our own)
-- ============================================================
function Units:FullRefresh(f)
    if not f or not f.unit then return end
    if DF.FullFrameRefresh then DF:FullFrameRefresh(f) end
    TD(f, "all")
    if RANGED[f.dfUFUnit] and DF.UpdateRange then DF:UpdateRange(f) end
end

-- One full repaint per frame per rendered frame.
function Units:QueueFullRefresh(f)
    if f.dfUFRefreshQueued then return end
    f.dfUFRefreshQueued = true
    C_Timer.After(0, function()
        f.dfUFRefreshQueued = nil
        if f:IsVisible() then Units:FullRefresh(f) end
    end)
end

-- Values only: what changes between two ticks of the same unit.
function Units:RepaintValues(f)
    if DF.UpdateHealthFast then DF:UpdateHealthFast(f) end
    if DF.UpdatePower then DF:UpdatePower(f) end
    if DF.UpdateHealAbsorb then DF:UpdateHealAbsorb(f) end
    if DF.UpdateHealPrediction then DF:UpdateHealPrediction(f) end
    if DF.UpdateAbsorb then DF:UpdateAbsorb(f) end
    TD(f, "health")
    TD(f, "power")
end

-- Max health moves before the value does, so health is repainted again one
-- rendered frame later.
local function DeferHealth(f)
    if f.dfUFHealthQueued then return end
    f.dfUFHealthQueued = true
    C_Timer.After(0, function()
        f.dfUFHealthQueued = nil
        if not f:IsVisible() then return end
        if DF.UpdateHealthFast then DF:UpdateHealthFast(f) end
        if DF.UpdateHealAbsorb then DF:UpdateHealAbsorb(f) end
        if DF.UpdateHealPrediction then DF:UpdateHealPrediction(f) end
        if DF.UpdateAbsorb then DF:UpdateAbsorb(f) end
        TD(f, "health")
    end)
end

local function Health(f)
    if DF.UpdateHealthFast then DF:UpdateHealthFast(f) end
    TD(f, "health")
end

local function Power(f)
    if DF.UpdatePower then DF:UpdatePower(f) end
    TD(f, "power")
end

local function Identity(f)
    -- Colours (reaction, tapped), dead/offline state and every text element.
    if DF.UpdateUnitFrame then DF:UpdateUnitFrame(f) end
    TD(f, "all")
end

local HANDLERS = {
    UNIT_HEALTH = Health,
    UNIT_MAXHEALTH = function(f) Health(f); DeferHealth(f) end,
    UNIT_MAX_HEALTH_MODIFIERS_CHANGED = function(f)
        Health(f)
        if DF.UpdateReducedMaxHealth then DF:UpdateReducedMaxHealth(f) end
    end,
    UNIT_POWER_UPDATE = Power,
    UNIT_MAXPOWER = Power,
    UNIT_DISPLAYPOWER = function(f)
        if DF.ApplyResourceBarLayout then DF:ApplyResourceBarLayout(f) end
        Power(f)
    end,
    UNIT_AURA = function(f)
        if DF.UpdateAuras then DF:UpdateAuras(f) end
        if DF.UpdateDefensiveBar then DF:UpdateDefensiveBar(f) end
        -- pcall'd for the reason FullFrameRefresh gives: the dispel overlay reaches
        -- into the aura container's slot buttons and is the one most exposed to a
        -- forbidden-object throw.
        if DF.UpdateDispelOverlay then pcall(DF.UpdateDispelOverlay, DF, f) end
    end,
    UNIT_NAME_UPDATE = function(f)
        if DF.UpdateName then DF:UpdateName(f) end
        if DF.UpdateFrameBorderUnitColor then DF:UpdateFrameBorderUnitColor(f) end
        TD(f, "name")
    end,
    UNIT_FACTION = Identity,
    UNIT_FLAGS = Identity,
    UNIT_CONNECTION = Identity,
    PLAYER_FLAGS_CHANGED = function(f) TD(f, "all") end,
    UNIT_LEVEL = function(f) TD(f, "name") end,
    UNIT_CLASSIFICATION_CHANGED = function(f) TD(f, "name") end,
    UNIT_ABSORB_AMOUNT_CHANGED = function(f) if DF.UpdateAbsorb then DF:UpdateAbsorb(f) end end,
    UNIT_HEAL_ABSORB_AMOUNT_CHANGED = function(f) if DF.UpdateHealAbsorb then DF:UpdateHealAbsorb(f) end end,
    UNIT_HEAL_PREDICTION = function(f) if DF.UpdateHealPrediction then DF:UpdateHealPrediction(f) end end,
    UNIT_THREAT_SITUATION_UPDATE = function(f) if DF.UpdateHighlights then DF:UpdateHighlights(f) end end,
}
Units.HANDLERS = HANDLERS

function Units.OnEvent(self, event, unit)
    if not self:IsVisible() then return end
    if event == "UNIT_ENTERED_VEHICLE" or event == "UNIT_EXITED_VEHICLE" then
        if unit == "player" then Units:UpdateVehicle(self) end
        return
    end
    -- The player button listens to both player and vehicle; only the one it
    -- shows counts.
    if unit and unit ~= self.unit then return end
    local h = HANDLERS[event]
    if h then h(self, unit) end
end

-- ============================================================
-- EVENT REGISTRATION (only while shown)
-- ============================================================
function Units:SetEventsEnabled(f, on)
    on = on and true or false
    if f.dfUFEventsOn == on then return end
    f.dfUFEventsOn = on
    local unit = f.dfUFUnit
    if POLLED[unit] then
        if on then Units:StartTicker(f) else Units:StopTicker(f) end
        return
    end
    -- pcall'd: a client without one of these events (the Forever build) refuses
    -- to register it, and that must cost one event, not the rest of the list.
    for _, ev in ipairs(Units:EventsFor(unit)) do
        if on then
            if unit == "player" then
                pcall(f.RegisterUnitEvent, f, ev, "player", "vehicle")
            else
                pcall(f.RegisterUnitEvent, f, ev, unit)
            end
        else
            pcall(f.UnregisterEvent, f, ev)
        end
    end
end

-- ============================================================
-- TARGET OF TARGET TICKER
-- ============================================================
function Units:TickPolled(f)
    if not f:IsVisible() then return end
    local guid = UnitGUID(f.unit)
    -- ☠ A secret GUID may not be compared: it counts as changed, every tick.
    local secret = IsSecret(guid)
    if guid == nil or secret or guid ~= f.dfUFLastGUID then
        f.dfUFLastGUID = (not secret) and guid or nil
        Units:FullRefresh(f)
    else
        Units:RepaintValues(f)
    end
end

function Units:StartTicker(f)
    if f.dfUFTicker then return end
    f.dfUFLastGUID = nil
    Units:TickPolled(f)
    f.dfUFTicker = C_Timer.NewTicker(UF.TOT_INTERVAL, function() Units:TickPolled(f) end)
end

function Units:StopTicker(f)
    if f.dfUFTicker then
        f.dfUFTicker:Cancel()
        f.dfUFTicker = nil
    end
    f.dfUFLastGUID = nil
end

-- ============================================================
-- VEHICLE (player)
-- The button's toggleForVehicle makes CLICKS go to the vehicle; this makes the
-- frame SHOW it as well.
-- ============================================================
function Units:UpdateVehicle(f)
    local want = "player"
    local inVehicle = UnitHasVehicleUI and UnitHasVehicleUI("player")
    if IsSecret(inVehicle) then inVehicle = false end
    -- Sitting on housing furniture reports a vehicle UI with no vehicle unit.
    if inVehicle and UnitExists("vehicle") then want = "vehicle" end
    if f.unit ~= want then
        f.unit = want
        UF.Debug("player frame shows %s", want)
        Units:QueueFullRefresh(f)
    end
end

-- ============================================================
-- LAYOUT AND POSITION (secure: out of combat only -- callers queue)
-- ============================================================
function Units:ApplyLayout(f)
    if not f or InCombatLockdown() then return end
    if DF.ApplyFrameLayout then DF:ApplyFrameLayout(f) end
    local db = f.dfDB
    f:SetScale((db and db.frameScale) or 1)
end

function Units:ApplyPosition(f)
    if not f or InCombatLockdown() then return end
    local pos = UF:GetPositionRecord(f.dfUFUnit)
    if type(pos) ~= "table" then return end
    local Lib = UF.Mover and UF.Mover.lib
    if Lib and Lib.ApplyPosition then
        Lib.ApplyPosition(f, pos)
        return
    end
    -- Without DandersMover: point/x/y are UIParent units from UIParent's centre;
    -- `anchor` is ignored (the same rule DF's own positions follow).
    local ratio = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    if not ratio or ratio == 0 then ratio = 1 end
    f:ClearAllPoints()
    f:SetPoint(pos.point or "CENTER", UIParent, "CENTER", (pos.x or 0) / ratio, (pos.y or 0) / ratio)
end

-- ============================================================
-- SPAWNING
-- ============================================================

-- Every unit frame's parent: hidden in pet battles, otherwise always shown.
function Units:GetParent()
    if Units.parent then return Units.parent end
    local p = CreateFrame("Frame", "DandersUnitFramesParent", UIParent, "SecureHandlerStateTemplate")
    p:SetAllPoints(UIParent)
    RegisterStateDriver(p, "visibility", "[petbattle] hide; show")
    Units.parent = p
    return p
end

local function OnShow(self)
    Units:SetEventsEnabled(self, true)
    if self.dfUFUnit == "player" then Units:UpdateVehicle(self) end
    Units:FullRefresh(self)
end

local function OnHide(self)
    Units:SetEventsEnabled(self, false)
end

function Units:Spawn(unit)
    if UF.frames[unit] then return UF.frames[unit] end
    if not FRAME_NAMES[unit] then
        DF:DebugError("UF", "Spawn: no frame for unit %s", tostring(unit))
        return nil
    end
    if InCombatLockdown() then
        DF:DebugWarn("UF", "Spawn %s: in combat, cannot create a secure frame", unit)
        return nil
    end
    local db = UF:GetUnitDB(unit)
    local f = CreateFrame("Button", FRAME_NAMES[unit], Units:GetParent(),
        "DandersUnitButtonTemplate,SecureUnitButtonTemplate")
    DF:InitStandaloneFrame(f, db)
    f.dfUFUnit = unit
    f.dfTextPresetOverride = db.textDesignerPreset
    if unit == "player" then f:SetAttribute("toggleForVehicle", true) end
    f:SetAttribute("unit", unit)
    f.unit = f.unit or unit
    if WATCHED[unit] then
        -- Hidden until the unit watch says the unit exists, so a target-less login
        -- never paints (or registers events for) a missing unit.
        f:Hide()
        RegisterUnitWatch(f)
    end
    f:HookScript("OnShow", OnShow)
    f:HookScript("OnHide", OnHide)
    f:SetScript("OnEvent", Units.OnEvent)
    if ClickCastFrames then ClickCastFrames[f] = true end
    if RANGED[unit] and DF.RegisterRangeFrame then DF:RegisterRangeFrame(f) end
    UF.frames[unit] = f
    Units:ApplyLayout(f)
    Units:ApplyPosition(f)
    if f:IsVisible() then OnShow(f) end
    UF.Debug("spawned %s", unit)
    return f
end

-- Every unit whose source is ours.
function Units:SpawnAll()
    for _, unit in ipairs(UF.SPAWNED_UNITS) do
        local src = UF:GetUnitDB(unit).source
        if src == nil or src == "DF" then Units:Spawn(unit) end
    end
end

-- ============================================================
-- UNITLESS EVENTS (one shared listener)
-- ============================================================
function Units:OnDriverEvent(event, unit)
    local frames = UF.frames
    if event == "PLAYER_TARGET_CHANGED" then
        local t = frames.target
        if t and t:IsVisible() then Units:FullRefresh(t) end
        local tt = frames.targettarget
        if tt then
            tt.dfUFLastGUID = nil
            if tt:IsVisible() then Units:TickPolled(tt) end
        end
        -- Selection highlight: any of our frames may be the new or old target.
        if DF.UpdateHighlights then
            for _, f in pairs(frames) do
                if f:IsVisible() then DF:UpdateHighlights(f) end
            end
        end
    elseif event == "UNIT_TARGET" then
        -- The target changed ITS target: the target-of-target is someone else now.
        local tt = frames.targettarget
        if tt and unit == "target" then
            tt.dfUFLastGUID = nil
            if tt:IsVisible() then Units:TickPolled(tt) end
        end
    elseif event == "RAID_TARGET_UPDATE" then
        if DF.UpdateRaidTargetIcon then
            for _, f in pairs(frames) do
                if f:IsVisible() then DF:UpdateRaidTargetIcon(f) end
            end
        end
    end
end

if CreateFrame then
    local driver = CreateFrame("Frame")
    driver:RegisterEvent("PLAYER_TARGET_CHANGED")
    driver:RegisterEvent("RAID_TARGET_UPDATE")
    if driver.RegisterUnitEvent then
        driver:RegisterUnitEvent("UNIT_TARGET", "target")
    end
    driver:SetScript("OnEvent", function(_, event, unit) Units:OnDriverEvent(event, unit) end)
    Units.driver = driver
end
