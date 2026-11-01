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
--   focus         as target; PLAYER_FOCUS_CHANGED repaints it
--   focustarget   the focus's target: target of target's pattern on focus (unit
--                 watch + ticker; PLAYER_FOCUS_CHANGED and the focus's UNIT_TARGET
--                 re-poll it at once)
--   pet           RegisterUnitWatch on "pet" (in a vehicle the vehicle holds the
--                 pet slot, so the watch shows it then too). Blizzard's convention,
--                 shared with player: in a vehicle the player frame shows the
--                 vehicle and the pet frame shows the player; toggleForVehicle
--                 makes clicks follow the same swap
--   boss1..N      Boss.lua: one container of slots, each built here (Units:Build)
--                 on the shared "boss" table; RegisterUnitWatch per slot
--
-- Each button sits in a holder of its own: the holder carries the unit's
-- Visibility state driver (Units:VisibilityMacro), so the unit watch on the
-- button and the visibility rule never fight over one frame's shown state.
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
    focus = "DandersUnitFrameFocus",
    focustarget = "DandersUnitFrameFocusTarget",
    pet = "DandersUnitFramePet",
    -- Boss.lua: the holder / container prefix; slot N is DandersUnitFrameBossN.
    boss = "DandersUnitFrameBoss",
}
Units.FRAME_NAMES = FRAME_NAMES

-- Shown only while the unit exists (secure unit watch).
local WATCHED = { target = true, targettarget = true, focus = true, focustarget = true, pet = true, boss = true }
-- No events of their own: polled by the ticker instead.
local POLLED = { targettarget = true, focustarget = true }
-- In DF's range tick (fade when out of range).
local RANGED = { target = true, targettarget = true, focus = true, focustarget = true, pet = true, boss = true }
-- Take part in the vehicle swap (toggleForVehicle on the button).
local VEHICLE = { player = true, pet = true }
Units.WATCHED, Units.RANGED, Units.VEHICLE = WATCHED, RANGED, VEHICLE

local UNIT_EVENTS = {
    "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_MAX_HEALTH_MODIFIERS_CHANGED",
    "UNIT_POWER_UPDATE", "UNIT_MAXPOWER", "UNIT_DISPLAYPOWER",
    "UNIT_AURA", "UNIT_NAME_UPDATE", "UNIT_FACTION", "UNIT_FLAGS",
    "UNIT_LEVEL", "UNIT_CLASSIFICATION_CHANGED", "UNIT_CONNECTION",
    "UNIT_ABSORB_AMOUNT_CHANGED", "UNIT_HEAL_ABSORB_AMOUNT_CHANGED", "UNIT_HEAL_PREDICTION",
    "UNIT_THREAT_SITUATION_UPDATE",
}
local PLAYER_EVENTS = { "UNIT_ENTERED_VEHICLE", "UNIT_EXITED_VEHICLE", "PLAYER_FLAGS_CHANGED" }
-- UNIT_PET arrives for the OWNER ("player") when the pet is summoned or swapped.
local PET_EVENTS = { "UNIT_ENTERED_VEHICLE", "UNIT_EXITED_VEHICLE", "UNIT_PET" }
-- A boss token can turn untargetable (phase) and back: the engage settle (Boss.lua).
local BOSS_EVENTS = { "UNIT_TARGETABLE_CHANGED" }

-- The event list a unit's frame registers (empty for a polled unit).
function Units:EventsFor(unit)
    if POLLED[unit] then return {} end
    local list = {}
    for _, ev in ipairs(UNIT_EVENTS) do list[#list + 1] = ev end
    local extra = (unit == "player" and PLAYER_EVENTS) or (unit == "pet" and PET_EVENTS)
        or (unit == "boss" and BOSS_EVENTS) or nil
    for _, ev in ipairs(extra or {}) do list[#list + 1] = ev end
    return list
end

-- The two unit tokens a vehicle-swapping frame listens to (it shows one of them).
local VEHICLE_PAIR = { player = { "player", "vehicle" }, pet = { "pet", "player" } }

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) and true or false
end

local function TD(f, hint)
    if DF.UpdateTextDesigner then DF:UpdateTextDesigner(f, hint) end
end

-- The unit-frame-only pieces (Elements.lua: cast bar, class power, portrait,
-- unit icons). Absent in a build without them.
local function Elements(method, f, ...)
    local E = UF.Elements
    if E then E:Call(method, f, ...) end
end
Units.CallElements = Elements

-- ============================================================
-- PAINTING (DF's updaters, nothing of our own)
-- ============================================================
function Units:FullRefresh(f)
    if not f or not f.unit then return end
    if DF.FullFrameRefresh then DF:FullFrameRefresh(f) end
    TD(f, "all")
    if RANGED[f.dfUFUnit] and DF.UpdateRange then DF:UpdateRange(f) end
    Elements("Refresh", f)
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
    UNIT_TARGETABLE_CHANGED = function(f) if UF.Boss then UF.Boss:Settle(f) end end,
}
Units.HANDLERS = HANDLERS

function Units.OnEvent(self, event, unit)
    if not self:IsVisible() then return end
    if event == "UNIT_ENTERED_VEHICLE" or event == "UNIT_EXITED_VEHICLE" then
        if unit == "player" then Units:UpdateVehicle(self) end
        return
    end
    if event == "UNIT_PET" then
        -- A new pet (or none): the frame shows someone else now.
        if unit == "player" then Units:QueueFullRefresh(self) end
        return
    end
    -- The player and pet buttons listen to both units of their vehicle pair;
    -- only the one they show counts.
    if unit and unit ~= self.unit then return end
    local h = HANDLERS[event]
    if h then h(self, unit) end
    Elements("OnUnitEvent", self, event, unit)
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
    -- The token is the frame's own (boss3), not the settings unit (boss).
    local token = f.unit or unit
    for _, ev in ipairs(Units:EventsFor(unit)) do
        if on then
            local pair = VEHICLE_PAIR[unit]
            if pair then
                pcall(f.RegisterUnitEvent, f, ev, pair[1], pair[2])
            else
                pcall(f.RegisterUnitEvent, f, ev, token)
            end
        else
            pcall(f.UnregisterEvent, f, ev)
        end
    end
end

-- ============================================================
-- TARGET OF TARGET TICKER
-- ============================================================
-- What a tick may repaint when it cannot tell whether the unit changed (secret
-- GUID): everything read off the unit -- health, power, name, colours, the Text
-- Designer -- but NOT the portrait model or the auras.
function Units:RepaintIdentityLight(f)
    if DF.UpdateUnitFrame then DF:UpdateUnitFrame(f, "PolledSecretGUID") end
    TD(f, "all")
end

-- ☠ THE SECRET-GUID RULE. A secret GUID cannot be compared, so a tick cannot tell
-- "same unit" from "someone else". Treating it as "changed" (as this once did)
-- meant a full repaint 4x a second -- the 3D portrait's ClearModel/SetUnit and an
-- aura rebuild every tick, for as long as it stayed secret. So a tick with a
-- secret GUID repaints only the cheap, read-off-the-unit parts (RepaintIdentityLight);
-- the full repaint (portrait, auras) happens only on a NON-secret signal that the
-- unit changed: a readable GUID that differs, or `force` -- the ticker start and
-- RepollPolled, which UNIT_TARGET, PLAYER_TARGET_CHANGED and PLAYER_FOCUS_CHANGED
-- drive.
function Units:TickPolled(f, force)
    if not f:IsVisible() then return end
    local guid = UnitGUID(f.unit)
    local secret = IsSecret(guid)
    if force then
        f.dfUFLastGUID = (not secret) and guid or nil
        Units:FullRefresh(f)
    elseif secret then
        f.dfUFLastGUID = nil
        Units:RepaintIdentityLight(f)
    elseif guid == nil or guid ~= f.dfUFLastGUID then
        f.dfUFLastGUID = guid
        Units:FullRefresh(f)
    else
        Units:RepaintValues(f)
    end
end

-- A polled frame's unit is someone else now: forget the GUID and repaint in full.
function Units:RepollPolled(f)
    if not f then return end
    f.dfUFLastGUID = nil
    if f:IsVisible() then Units:TickPolled(f, true) end
end

function Units:StartTicker(f)
    if f.dfUFTicker then return end
    f.dfUFLastGUID = nil
    Units:TickPolled(f, true)
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
-- VEHICLE (player and pet)
-- The buttons' toggleForVehicle makes CLICKS follow the swap; this makes the
-- frames SHOW it as well (Blizzard's convention): in a vehicle the player frame
-- shows the vehicle and the pet frame shows the player.
-- ============================================================
function Units:InVehicle()
    local inVehicle = UnitHasVehicleUI and UnitHasVehicleUI("player")
    if IsSecret(inVehicle) then inVehicle = false end
    -- Sitting on housing furniture reports a vehicle UI with no vehicle unit.
    return (inVehicle and UnitExists("vehicle")) and true or false
end

-- The unit a frame shows for its base unit right now.
function Units:DisplayUnit(base)
    if not VEHICLE[base] or not Units:InVehicle() then return base end
    if base == "player" then return "vehicle" end
    return "player"
end

function Units:UpdateVehicle(f)
    local want = Units:DisplayUnit(f.dfUFUnit or "player")
    if f.unit ~= want then
        f.unit = want
        UF.Debug("%s frame shows %s", tostring(f.dfUFUnit), want)
        Elements("OnUnitChanged", f)
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
    -- A boss slot's scale is its container's (Boss.lua), so the slot offsets and
    -- the container's size stay in one set of units.
    if f.dfUFSlot then f:SetScale(1) else f:SetScale((db and db.frameScale) or 1) end
    Elements("Layout", f)
end

function Units:ApplyPosition(f)
    if not f or InCombatLockdown() then return end
    -- A boss slot is placed by its container; the container is what has a record.
    if f.dfUFSlot then
        if UF.Boss then UF.Boss:ApplyPosition() end
        return
    end
    Units:PlaceAt(f, UF:GetPositionRecord(f.dfUFUnit))
end

-- Put a frame at a position record. No combat check: the caller decides (the
-- preview frames are not secure and may move any time).
function Units:PlaceAt(f, pos)
    if not f or type(pos) ~= "table" then return end
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

-- Every unit frame's top parent. Always shown: each unit's Visibility rule
-- (pet battles included) lives on its own holder below.
function Units:GetParent()
    if Units.parent then return Units.parent end
    local p = CreateFrame("Frame", "DandersUnitFramesParent", UIParent, "SecureHandlerStateTemplate")
    p:SetAllPoints(UIParent)
    Units.parent = p
    return p
end

-- One holder per unit, carrying that unit's visibility state driver.
Units.holders = Units.holders or {}
function Units:GetHolder(unit)
    local h = Units.holders[unit]
    if h then return h end
    h = CreateFrame("Frame", FRAME_NAMES[unit] .. "Holder", Units:GetParent(), "SecureHandlerStateTemplate")
    h:SetAllPoints(Units:GetParent())
    Units.holders[unit] = h
    return h
end

-- ============================================================
-- VISIBILITY (the unit's Visibility page)
-- A macro-condition string for the holder's "visibility" state driver: the Hide
-- When rules first (any match hides), then Always, or the Show When conditions
-- (any match shows) and "hide" for everything else. Being in an instance has no
-- macro condition, so it is resolved here and the string is rebuilt on every
-- zone change. Secure: the driver is (re)registered out of combat only.
-- ⚠ [bonusbar:5] as the skyriding bar is unverified in game on 12.x.
-- ============================================================
function Units:VisibilityMacro(unit)
    local db = UF:GetUnitDB(unit)
    local parts = {}
    local function add(s) parts[#parts + 1] = s end
    if db.visHidePetBattle ~= false then add("[petbattle] hide") end
    if unit == "player" and db.visHideVehicle then add("[vehicleui] hide") end
    if db.visHideMounted then add("[mounted] hide") end
    if db.visHideSkyriding then add("[bonusbar:5] hide") end
    if db.visAlways ~= false then
        add("show")
    else
        if db.visCombat then add("[combat] show") end
        if db.visNoCombat then add("[nocombat] show") end
        if db.visGroup then add("[group] show") end
        if db.visSolo then add("[nogroup] show") end
        if unit == "player" then
            if db.visHasTarget then add("[@target,exists] show") end
            if db.visHasEnemyTarget then add("[@target,harm] show") end
        end
        local inInstance = db.visInstance and IsInInstance and IsInInstance()
        if inInstance and not IsSecret(inInstance) then add("show") else add("hide") end
    end
    return table.concat(parts, "; ")
end

function Units:ApplyVisibility(f)
    if not f then return end
    local unit = f.dfUFUnit
    local h = Units.holders[unit]
    if not h then return end
    local macro = Units:VisibilityMacro(unit)
    if h.dfUFVisMacro == macro then return end
    UF:RunOutOfCombat("visibility:" .. unit, function()
        RegisterStateDriver(h, "visibility", macro)
        h.dfUFVisMacro = macro
        UF.Debug("%s visibility: %s", unit, macro)
    end)
end

local function OnShow(self)
    -- A polled unit's ticker start repaints in full (TickPolled, force): a second
    -- FullRefresh here would paint everything twice on every show.
    local hadTicker = self.dfUFTicker
    Units:SetEventsEnabled(self, true)
    if VEHICLE[self.dfUFUnit] then Units:UpdateVehicle(self) end
    if self.dfUFSlot and UF.Boss then UF.Boss:NoteIdentity(self) end
    Elements("SetActive", self, true)
    if not (POLLED[self.dfUFUnit] and self.dfUFTicker and not hadTicker) then
        Units:FullRefresh(self)
    end
end

local function OnHide(self)
    Units:SetEventsEnabled(self, false)
    Elements("SetActive", self, false)
    self.dfUFLastGUID = nil
end

-- Build one unit button. `key` is its UF.frames key, `unit` the settings unit
-- (the table it reads), `token` the unit it shows, `slot` its boss slot (nil for
-- every other unit). Layout, position and visibility are the caller's.
function Units:Build(key, unit, token, name, parent, slot)
    local db = UF:GetUnitDB(unit)
    local f = CreateFrame("Button", name, parent,
        "DandersUnitButtonTemplate,SecureUnitButtonTemplate")
    DF:InitStandaloneFrame(f, db)
    f.dfUFUnit = unit
    f.dfUFKey = key
    f.dfUFSlot = slot
    -- Where its aura rows sit: their own corner and the cast bar reserve (Elements.lua).
    f.dfAuraRowPlacement = UF.AuraRowPlacement
    -- Its highlights trace the frame with its portrait and class power bar (Indicators.lua).
    f.dfHighlightShape = UF.Indicators and UF.Indicators.HighlightShape or nil
    UF:StampDesigners(f, db)
    f.dfMirrorText = UF.IsTextMirrored and UF:IsTextMirrored(unit) or false
    if VEHICLE[unit] then f:SetAttribute("toggleForVehicle", true) end
    f:SetAttribute("unit", token)
    f.unit = f.unit or token
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
    UF.frames[key] = f
    Elements("Attach", f)
    return f
end

function Units:Spawn(unit)
    -- Boss is a container of slots (Boss.lua); it answers with the container.
    if unit == "boss" then return UF.Boss and UF.Boss:Spawn() or nil end
    if UF.frames[unit] then return UF.frames[unit] end
    if not FRAME_NAMES[unit] then
        DF:DebugError("UF", "Spawn: no frame for unit %s", tostring(unit))
        return nil
    end
    if InCombatLockdown() then
        DF:DebugWarn("UF", "Spawn %s: in combat, cannot create a secure frame", unit)
        return nil
    end
    local f = Units:Build(unit, unit, unit, FRAME_NAMES[unit], Units:GetHolder(unit))
    Units:ApplyLayout(f)
    Units:ApplyPosition(f)
    Units:ApplyVisibility(f)
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
        Units:RepollPolled(frames.targettarget)
        -- Selection highlight: any of our frames may be the new or old target.
        if DF.UpdateHighlights then
            for _, f in pairs(frames) do
                if f:IsVisible() then DF:UpdateHighlights(f) end
            end
        end
    elseif event == "PLAYER_FOCUS_CHANGED" then
        local fc = frames.focus
        if fc and fc:IsVisible() then Units:FullRefresh(fc) end
        Units:RepollPolled(frames.focustarget)
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        -- "In an Instance" has no macro condition: rebuild the visibility rules.
        for _, f in pairs(frames) do Units:ApplyVisibility(f) end
        Units:SweepFrameFade()
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        Units:SweepFrameFade()
        for _, f in pairs(frames) do
            if f:IsVisible() then Elements("OnUnitEvent", f, event, nil) end
        end
    elseif event == "UNIT_TARGET" then
        -- The target (or focus) changed ITS target: the polled frame shows someone
        -- else now.
        if unit == "target" then Units:RepollPolled(frames.targettarget) end
        if unit == "focus" then Units:RepollPolled(frames.focustarget) end
    elseif event == "RAID_TARGET_UPDATE" then
        if DF.UpdateRaidTargetIcon then
            for _, f in pairs(frames) do
                if f:IsVisible() then DF:UpdateRaidTargetIcon(f) end
            end
        end
    end
end

-- ============================================================
-- FRAME FADE (DandersFrames' Frame Fade card, these frames' own keys)
-- DF's combat-edge sweep walks only the group frames, so the in-combat /
-- out-of-combat split is applied here on the same edges. Alpha only: legal in
-- combat. Nothing to do unless a frame has the split on.
-- ============================================================
function Units:SweepFrameFade()
    if not DF.UpdateFrameAppearance then return end
    for _, f in pairs(UF.frames) do
        local db = f.dfDB
        if db and db.frameFadeSplitCombat and f:IsVisible() then DF:UpdateFrameAppearance(f) end
    end
end

if CreateFrame then
    local driver = CreateFrame("Frame")
    -- pcall'd one by one: a client without one of these events (the Forever
    -- build) refuses to register it, and that must cost one event, not the rest.
    for _, ev in ipairs({ "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "PLAYER_ENTERING_WORLD",
                          "ZONE_CHANGED_NEW_AREA", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
                          "RAID_TARGET_UPDATE" }) do
        pcall(driver.RegisterEvent, driver, ev)
    end
    if driver.RegisterUnitEvent then
        pcall(driver.RegisterUnitEvent, driver, "UNIT_TARGET", "target", "focus")
    end
    driver:SetScript("OnEvent", function(_, event, unit) Units:OnDriverEvent(event, unit) end)
    Units.driver = driver
end
