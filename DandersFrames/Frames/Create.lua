local addonName, DF = ...

-- ============================================================
-- FRAMES CREATE MODULE
-- Contains frame creation functions
-- ============================================================

-- ============================================================
-- BINDING TOOLTIP
-- Separate tooltip showing click-cast bindings on unit frame hover.
-- Spell usability / cooldown shown out of combat only (secret values).
-- ============================================================

local issecretvalue = issecretvalue or function() return false end
local pairs, ipairs = pairs, ipairs
local wipe = wipe
local format = string.format
local tinsert = table.insert
local tsort = table.sort
local GetNumGroupMembers = GetNumGroupMembers
local GetNumSubgroupMembers = GetNumSubgroupMembers
local IsInRaid = IsInRaid
local UnitGUID = UnitGUID
local ceil = math.ceil
local InCombatLockdown = InCombatLockdown
local UnitExists = UnitExists
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local GetTime = GetTime
local IsShiftKeyDown = IsShiftKeyDown
local IsControlKeyDown = IsControlKeyDown
local IsAltKeyDown = IsAltKeyDown
local bindingTooltip = CreateFrame("GameTooltip", "DFBindingTooltip", UIParent, "GameTooltipTemplate")
bindingTooltip:SetFrameStrata("TOOLTIP")
if bindingTooltip.NineSlice then
    for _, piece in pairs({"TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner", "TopEdge", "BottomEdge", "LeftEdge", "RightEdge"}) do
        if bindingTooltip.NineSlice[piece] then bindingTooltip.NineSlice[piece]:SetAlpha(0) end
    end
end
DFBindingTooltipTextLeft1:SetFontObject(GameTooltipText)

-- ============================================================
-- FRAME BORDER WIDGET
-- The frame border is built on the unified DF.Border backend (Frames/Border.lua).
-- frame.border keeps its established shape: top/bottom/left/right edges, a lazy
-- `bd` backdrop child for Texture style, and a :SetBorderColor method that
-- routes to whichever mode is active (used by live colour / aggro / dispel
-- overlays). These thin wrappers translate the frame DB into a border spec.
-- ============================================================

function DF:CreateFrameBorder(frame, db)
    -- ☠ MUST be explicit. DF.Border defaults to parent+2, which is sized for a leaf
    -- parent; this one stacks child FRAMES over its own rect. Take the default and the
    -- health bar (SetAllPoints, framePadding 0) buries the border completely at full
    -- health -- which is what alpha 15 did -- so this must clear the WHOLE bar band.
    --
    -- ☠☠ RE-CHECK THIS WHENEVER THE BAND GROWS. ONCE IT WAS NOT. This was +10, chosen
    -- when the band ended at absorb +7 / heal-absorb +8. The 2026-08-13 z-order
    -- convergence raised absorb to +11 and heal prediction to +12 and left this at +10,
    -- so both drew OVER the frame border -- reported in game 2026-08-14 ("the heal
    -- prediction overlay is sitting above the frame border"). The comment here went on
    -- reciting the old +7 and asserting "+10 is the free band above every bar" long
    -- after that stopped being true; see [[feedback-verify-dont-assume]].
    --
    -- Measured by /df debug zorder on a live frame 2026-08-14, frame-relative:
    --   health +3 · heal-absorb +8 · absorb +11 · overflow +11 · heal prediction +12
    --   >> FRAME BORDER +13 <<  power +20 · contentOverlay +25
    -- +13 is the free slot: above every bar, below the resource bar and the text/icon
    -- layer -- and both of those already drew above the border at +10, so that pairing
    -- is unchanged.
    -- ⚠ absorbBarFrameLevel / healPredictionFrameLevel are USER SLIDERS (0-100). This
    -- clears their DEFAULTS; a user who raises one past 13 is deliberately putting that
    -- bar over the border, which is the slider doing its job.
    frame.border = DF.Border:New(frame, { frameLevelOffset = 13 })
    DF:ApplyFrameBorder(frame, db)
    return frame.border
end

function DF:ApplyFrameBorder(frame, db)
    if not frame or not frame.border then return end
    -- Pinned frames carry their own border DB (a Border Override snapshot, or the
    -- Based-on mode when inheriting) so they don't render the active mode's border.
    if frame.dfPinnedBorderDB then db = frame.dfPinnedBorderDB end
    db = db or (DF.GetFrameDB and DF:GetFrameDB(frame))
    if not db then return end

    -- ctx lets BuildSpec resolve class / role colours via Border:Resolve*
    -- helpers when the source is CLASS or ROLE. Resolvers fall through to
    -- the static frameBorderColor picker when ctx is missing.
    -- ctx.frame is required for test-mode preview: test frames have no
    -- real unit, but they carry dfIsTestFrame + index + isRaidFrame so
    -- the resolvers can pull class/role from GetTestUnitData (Stage 4.0
    -- wired this for Defensive Icon; Frame Border was missed at the time).
    DF.Border:Apply(frame.border, DF.Border:BuildSpec(db, "frame", {
        unit  = frame.unit,
        frame = frame,
    }))
end

local BINDING_SHORT_NAMES = {
    LeftButton = "Left", RightButton = "Right", MiddleButton = "Middle",
}
local BINDING_SORT_ORDER = {
    LeftButton = 1, MiddleButton = 2, RightButton = 3,
    Button4 = 4, Button5 = 5, Button6 = 6, Button7 = 7, Button8 = 8,
    Button9 = 9, Button10 = 10, Button11 = 11, Button12 = 12,
    Button13 = 13, Button14 = 14, Button15 = 15, Button16 = 16,
}

-- Pre-allocated table for tooltip lines (wiped each call)
local lines = {}

local function getActiveModifier()
    local mods = ""
    if IsShiftKeyDown() then mods = mods .. "shift-" end
    if IsControlKeyDown() then mods = mods .. "ctrl-" end
    if IsAltKeyDown() then mods = mods .. "alt-" end
    if IsMetaKeyDown and IsMetaKeyDown() then mods = mods .. "meta-" end
    return mods
end

local function bindingMatchesMod(binding, activeMod)
    local mods = binding.modifiers or ""
    return mods == activeMod
end

-- Position the binding tooltip based on settings (mirrors PositionFrameTooltip pattern)
local function positionBindingTooltip(anchorFrame, db)
    local anchor = db.tooltipBindingAnchor or "FRAME"
    local anchorPos = db.tooltipBindingAnchorPos or "TOPRIGHT"
    local offsetX = db.tooltipBindingX or 4
    local offsetY = db.tooltipBindingY or 0

    bindingTooltip:ClearAllPoints()
    if anchor == "CURSOR" then
        -- Approximate cursor-follow by anchoring to cursor position
        local cursorX, cursorY = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        bindingTooltip:SetOwner(anchorFrame, "ANCHOR_NONE")
        bindingTooltip:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", cursorX / scale + offsetX, cursorY / scale + offsetY)
    elseif anchor == "FRAME" then
        bindingTooltip:SetOwner(anchorFrame, "ANCHOR_NONE")
        -- Use opposite anchor so tooltip appears on the correct side
        local opposites = {
            TOPLEFT = "BOTTOMRIGHT", TOP = "BOTTOM", TOPRIGHT = "BOTTOMLEFT",
            LEFT = "RIGHT", CENTER = "CENTER", RIGHT = "LEFT",
            BOTTOMLEFT = "TOPRIGHT", BOTTOM = "TOP", BOTTOMRIGHT = "TOPLEFT",
        }
        local tooltipAnchor = opposites[anchorPos] or "BOTTOMLEFT"
        bindingTooltip:SetPoint(tooltipAnchor, anchorFrame, anchorPos, offsetX, offsetY)
    else
        -- DEFAULT — anchor to top-right of frame
        bindingTooltip:SetOwner(anchorFrame, "ANCHOR_NONE")
        bindingTooltip:SetPoint("TOPLEFT", anchorFrame, "TOPRIGHT", 4, 0)
    end
end

function DF:ShowBindingTooltip(anchorFrame)
    local CC = DF.ClickCast
    if not CC or not CC.db or not CC.db.bindings then return end

    -- Read settings from frame db (party/raid independent)
    local db = DF:GetFrameDB(anchorFrame)
    if not db.tooltipBindingEnabled then return end

    local inCombat = InCombatLockdown()
    if db.tooltipBindingDisableInCombat and inCombat then
        bindingTooltip:Hide()
        bindingTooltip.anchorFrame = nil
        return
    end

    local activeMod = getActiveModifier()
    bindingTooltip:ClearLines()
    positionBindingTooltip(anchorFrame, db)
    wipe(lines)
    local unit = anchorFrame.unit
    local isDead = false
    if anchorFrame.dfIsTestFrame then
        local testData = DF.GetTestUnitData and DF:GetTestUnitData(anchorFrame.index, anchorFrame.isRaidFrame)
        isDead = testData and testData.status == "Dead"
    elseif unit and UnitExists(unit) then
        isDead = UnitIsDeadOrGhost(unit)
        if issecretvalue(isDead) then isDead = false end
    end
    local smartResMode = CC.db.options and CC.db.options.smartResurrection or "disabled"
    local resSpells = smartResMode ~= "disabled" and CC.GetPlayerResurrectionSpells and CC:GetPlayerResurrectionSpells() or nil
    for _, binding in ipairs(CC.db.bindings) do
        if binding.enabled ~= false and bindingMatchesMod(binding, activeMod) then
            local keyName
            local sortKey = 99
            if binding.bindType == "mouse" then
                keyName = BINDING_SHORT_NAMES[binding.button] or (binding.button and binding.button:match("Button(%d+)") and "Mouse " .. binding.button:match("Button(%d+)")) or binding.button
                sortKey = BINDING_SORT_ORDER[binding.button] or 99
            else
                keyName = binding.key or "?"
            end
            local action = binding.spellName or binding.actionType or "?"
            local r, g, b = 1, 1, 1
            local suffix = ""
            -- Smart Res: override action when target is dead
            local smartResApplied = false
            if isDead and resSpells and not CC:IsResurrectionSpell(binding.spellName) and binding.targetType ~= "hostile" then
                if inCombat and smartResMode == "normal+combat" and resSpells.combat then
                    action = resSpells.combat
                    smartResApplied = true
                elseif not inCombat then
                    action = resSpells.mass or resSpells.normal or action
                    smartResApplied = true
                end
            end
            -- Resolve override spell name (safe in combat)
            local spellRef = binding.spellId
            if not smartResApplied then
                if spellRef and C_Spell.GetOverrideSpell then
                    spellRef = C_Spell.GetOverrideSpell(spellRef) or spellRef
                end
                local ref = spellRef or binding.spellName
                if ref and C_Spell.GetSpellName then
                    action = C_Spell.GetSpellName(ref) or action
                end
            end
            if not inCombat and not smartResApplied then
                spellRef = spellRef or binding.spellName
                if spellRef and C_Spell.IsSpellUsable then
                    local usable = C_Spell.IsSpellUsable(spellRef)
                    if issecretvalue(usable) then usable = nil end
                    local cdLeft = 0
                    local hasSecretCD = false
                    if usable and C_Spell.GetSpellCharges then
                        local charges = C_Spell.GetSpellCharges(spellRef)
                        if charges then
                            if issecretvalue(charges.currentCharges) then
                                hasSecretCD = true
                            elseif charges.currentCharges == 0 then
                                usable = false
                                if not issecretvalue(charges.cooldownStartTime) then
                                    cdLeft = charges.cooldownStartTime + charges.cooldownDuration - GetTime()
                                end
                            end
                        end
                    end
                    if usable and C_Spell.GetSpellCooldown then
                        local cd = C_Spell.GetSpellCooldown(spellRef)
                        if cd and cd.duration then
                            if issecretvalue(cd.duration) then
                                hasSecretCD = true
                            elseif cd.duration > 1.5 then
                                usable = false
                                if not issecretvalue(cd.startTime) then
                                    cdLeft = cd.startTime + cd.duration - GetTime()
                                end
                            end
                        end
                    end
                    if usable ~= nil and not hasSecretCD then
                        r, g, b = usable and 0 or 1, usable and 1 or 0, 0
                    end
                    if cdLeft > 0 then
                        suffix = " (" .. ceil(cdLeft) .. "s)"
                    end
                end
            end
            -- OOR check (works in and out of combat)
            if unit and binding.spellId and C_Spell.IsSpellInRange then
                local inRange = C_Spell.IsSpellInRange(binding.spellId, unit)
                if not issecretvalue(inRange) and inRange == false then r, g, b = 1, 0, 0; suffix = " (OOR)" end
            end
            -- Dead check (works in and out of combat, skip if Smart Res overrode)
            if isDead and not smartResApplied then r, g, b = 1, 0, 0; suffix = " (DEAD)" end
            local hex = format("|cff%02x%02x%02x", r * 255, g * 255, b * 255)
            tinsert(lines, {text = keyName .. ": " .. hex .. action .. suffix .. "|r", sort = sortKey, smartRes = smartResApplied})
        end
    end
    tsort(lines, function(a, b) return a.sort < b.sort end)
    local smartResShown = false
    for _, line in ipairs(lines) do
        if line.smartRes and smartResShown then
            -- skip duplicate Smart Res lines
        else
            if line.smartRes then smartResShown = true end
            bindingTooltip:AddLine(line.text, 0.7, 0.7, 0.7)
        end
    end
    if #lines > 0 then bindingTooltip:Show() else bindingTooltip:Hide() end
    bindingTooltip.anchorFrame = anchorFrame
end

bindingTooltip:RegisterEvent("MODIFIER_STATE_CHANGED")
bindingTooltip:RegisterEvent("SPELL_UPDATE_COOLDOWN")
bindingTooltip:SetScript("OnEvent", function(self)
    if self.anchorFrame then DF:ShowBindingTooltip(self.anchorFrame) end
end)

-- ============================================================
-- TOOLTIP REFRESH TICKER
-- Re-fires GameTooltip:SetUnit() every 0.25s while hovering a unit frame.
-- Allows addons like RaiderIO that check IsModifierKeyDown() inside
-- TooltipDataProcessor to respond to modifier key state changes.
-- ============================================================
local tooltipRefreshTicker = nil
local tooltipRefreshFrame = nil
local tooltipRefreshModState = 0

local function GetModifierState()
    local s = 0
    if IsShiftKeyDown() then s = s + 1 end
    if IsControlKeyDown() then s = s + 2 end
    if IsAltKeyDown() then s = s + 4 end
    return s
end

local function StartTooltipRefresh(frame)
    tooltipRefreshFrame = frame
    -- Tooltip was just freshly set by the caller, so the current modifier
    -- state is our baseline — only refresh if it changes from this.
    tooltipRefreshModState = GetModifierState()
    if tooltipRefreshTicker then return end  -- already running
    tooltipRefreshTicker = C_Timer.NewTicker(0.25, function()
        local f = tooltipRefreshFrame
        if not f or not f.dfIsHovered or not GameTooltip:IsShown() then
            tooltipRefreshTicker:Cancel()
            tooltipRefreshTicker = nil
            tooltipRefreshFrame = nil
            return
        end
        -- Only re-call SetUnit when modifier state changes, so addons like
        -- RaiderIO can respond to modifier presses without us repeatedly
        -- overwriting aura tooltips when the cursor lands on a buff/debuff.
        local mod = GetModifierState()
        if mod == tooltipRefreshModState then return end
        tooltipRefreshModState = mod
        GameTooltip:SetUnit(f.unit)
        local _, ttUnit = GameTooltip:GetUnit()
        if (not ttUnit or issecretvalue(ttUnit)) and _G.RaiderIO and _G.RaiderIO.ShowProfile then
            _G.RaiderIO.ShowProfile(GameTooltip, f.unit)
        end
    end)
end

local function StopTooltipRefresh()
    tooltipRefreshFrame = nil
    if tooltipRefreshTicker then
        tooltipRefreshTicker:Cancel()
        tooltipRefreshTicker = nil
    end
end

-- Expose for Headers.lua (loads before Create.lua frame hooks)
function DF:StartTooltipRefresh(frame) StartTooltipRefresh(frame) end
function DF:StopTooltipRefresh() StopTooltipRefresh() end

-- One-shot report of which duration APIs this build exposes.
function DF:TestDurationDebug()
    local o = DF:Out("Aura Duration API")

    -- A missing entry point here is genuinely BAD: it means this build cannot do
    -- something DF relies on, which is the whole reason to run this command.
    o:Section("C_UnitAuras", C_UnitAuras and "present" or "MISSING")
    if C_UnitAuras then
        local fns = {
            "GetAuraDurationRemainingPercent", "GetAuraDurationRemaining",
            "GetAuraDataByIndex", "DoesAuraHaveExpirationTime",
        }
        for _, fn in ipairs(fns) do
            o:Field(fn, C_UnitAuras[fn] ~= nil, C_UnitAuras[fn] and "GOOD" or "BAD")
        end
    end

    o:Section("C_CurveUtil", C_CurveUtil and "present" or "MISSING")
    if C_CurveUtil then
        o:Field("CreateColorCurve", C_CurveUtil.CreateColorCurve ~= nil,
            C_CurveUtil.CreateColorCurve and "GOOD" or "BAD")
    end
    -- (Removed) a "durationAPIMode: old/new" line. DF.durationAPIMode was declared
    -- nil with a "set once on first use" comment and then never assigned by any
    -- code path, so this always reported "not set yet" — a dump that looked like a
    -- measurement but only ever printed its own placeholder.

    o:Section("Sample aura")
    local auraData = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
        and C_UnitAuras.GetAuraDataByIndex("player", 1, "HELPFUL")
    if not auraData then
        o:Line("No buff in player slot 1 — buff yourself and re-run.", "NEUTRAL")
    else
        local auraName = "(protected)"
        pcall(function() auraName = auraData.name or "?" end)
        o:Field("name", auraName, "NEUTRAL")
        local dt = type(auraData.duration)
        o:Field("duration", tostring(auraData.duration) .. " (" .. dt .. ")", "NEUTRAL")
        o:Field("expirationTime", tostring(auraData.expirationTime), "NEUTRAL")
        if dt == "table" then
            local keys = {}
            for k, v in pairs(auraData.duration) do keys[#keys + 1] = "." .. tostring(k) .. " = " .. type(v) end
            table.sort(keys)
            o:Line("duration is a TABLE — fields:", "WARN")
            o:More(keys, 8)
        end
    end
end

-- One-shot dump of which duration APIs this build exposes. The old on/off
-- subcommands set DF.debugDurationAPI, which nothing ever read — the "continuous
-- debug" they advertised did not exist. Only the dump was ever real.
-- Dev-gated: it reports which C_UnitAuras / C_CurveUtil entry points exist on this
-- build, which means nothing to someone who does not maintain the code. The earlier
-- reasoning for opening it up — "let a PTR tester paste it back" — was wrong on its
-- own terms: testers run alpha builds, so the dev gate does not hide it from them.
DF:RegisterDebugSlash("DFDURATIONDEBUG", "Aura duration API availability dump", true, "/dfduration")
SlashCmdList["DFDURATIONDEBUG"] = function(msg)
    DF:TestDurationDebug()
end

-- Local caching of frequently used globals for performance
local pairs, ipairs, type, wipe = pairs, ipairs, type, wipe
local CreateFrame = CreateFrame
local UnitExists = UnitExists
local InCombatLockdown = InCombatLockdown
local RegisterUnitWatch = RegisterUnitWatch

-- ============================================================
-- SAFE UNIT WATCH REGISTRATION (combat lockdown protection)
-- ============================================================

-- Queue of frames waiting for unit watch registration after combat
DF.pendingUnitWatchFrames = DF.pendingUnitWatchFrames or {}
-- Queue of frames waiting for unit watch UNregistration after combat
DF.pendingUnitUnwatchFrames = DF.pendingUnitUnwatchFrames or {}

-- Manual visibility update for frames pending registration (combat fallback)
local function UpdatePendingFrameVisibility()
    for frame in pairs(DF.pendingUnitWatchFrames) do
        if frame and frame.unit then
            if UnitExists(frame.unit) then
                frame:Show()
            else
                frame:Hide()
            end
        end
    end
end

-- Safe wrapper for RegisterUnitWatch that handles combat lockdown
function DF:SafeRegisterUnitWatch(frame)
    if not frame then return end
    
    -- If this frame is pending unregistration, cancel that
    DF.pendingUnitUnwatchFrames[frame] = nil
    
    if InCombatLockdown() then
        -- Queue for later registration
        DF.pendingUnitWatchFrames[frame] = true
        
        -- Manual visibility fallback - show/hide based on UnitExists right now
        if frame.unit then
            if UnitExists(frame.unit) then
                frame:Show()
            else
                frame:Hide()
            end
        end
        
        -- Start combat roster watcher if not already running
        if not DF.combatRosterWatcher then
            DF.combatRosterWatcher = CreateFrame("Frame")
            DF.combatRosterWatcher:RegisterEvent("GROUP_ROSTER_UPDATE")
            DF.combatRosterWatcher:SetScript("OnEvent", function()
                if InCombatLockdown() and next(DF.pendingUnitWatchFrames) then
                    UpdatePendingFrameVisibility()
                end
            end)
        end
    else
        RegisterUnitWatch(frame)
    end
end

-- Safe wrapper for UnregisterUnitWatch that handles combat lockdown
function DF:SafeUnregisterUnitWatch(frame)
    if not frame then return end
    
    -- If this frame is pending registration, cancel that
    DF.pendingUnitWatchFrames[frame] = nil
    
    if InCombatLockdown() then
        -- Queue for later unregistration
        DF.pendingUnitUnwatchFrames[frame] = true
        -- Hide the frame immediately (this is safe during combat)
        frame:Hide()
    else
        UnregisterUnitWatch(frame)
        frame:Hide()
    end
end

-- Process queued unit watch registrations/unregistrations after combat ends
function DF:ProcessPendingUnitWatch()
    if InCombatLockdown() then return end
    
    -- Process unregistrations first
    for frame in pairs(DF.pendingUnitUnwatchFrames) do
        if frame and frame.GetName then
            UnregisterUnitWatch(frame)
            frame:Hide()
        end
    end
    wipe(DF.pendingUnitUnwatchFrames)
    
    -- Then process registrations
    for frame in pairs(DF.pendingUnitWatchFrames) do
        if frame and frame.GetName then
            RegisterUnitWatch(frame)
        end
    end
    wipe(DF.pendingUnitWatchFrames)
end

-- ============================================================
-- UNIT EVENT REGISTRATION (performance optimization)
-- ============================================================
-- Using RegisterUnitEvent instead of RegisterEvent filters events
-- at the C++ level, preventing Lua from receiving events for units
-- we don't care about. This is critical for performance in cities
-- where many players/NPCs generate UNIT_* events constantly.
--
-- Added: 2025-01-20 for performance optimization

-- List of events that should use RegisterUnitEvent (have unit as first arg)
-- Events registered per-frame via RegisterUnitEvent (C++-level filtering).
-- Must be true unit events — i.e. events that deliver a unit token as the
-- first OnEvent arg. Non-unit events like INCOMING_SUMMON_CHANGED and
-- INCOMING_RESURRECT_CHANGED do NOT belong here; RegisterUnitEvent silently
-- fails on them. They're handled globally on headerChildEventFrame in
-- Headers.lua instead.
local UNIT_EVENTS_TO_FILTER = {
    "UNIT_HEALTH",
    "UNIT_MAXHEALTH",
    "UNIT_NAME_UPDATE",
    "UNIT_AURA",
    "UNIT_ABSORB_AMOUNT_CHANGED",
    "UNIT_HEAL_ABSORB_AMOUNT_CHANGED",
    "UNIT_HEAL_PREDICTION",
    "UNIT_CONNECTION",
}

-- Register unit-specific events for a frame
-- This filters events at the C++ level so we only receive events for our unit
function DF:RegisterUnitEventsForFrame(frame, unit)
    if not frame or not unit then return end
    
    -- Unregister old unit events if unit changed
    if frame.dfRegisteredUnit and frame.dfRegisteredUnit ~= unit then
        for _, event in ipairs(UNIT_EVENTS_TO_FILTER) do
            frame:UnregisterEvent(event)
        end
    end
    
    -- Register for new unit using RegisterUnitEvent (C++ level filtering)
    for _, event in ipairs(UNIT_EVENTS_TO_FILTER) do
        frame:RegisterUnitEvent(event, unit)
    end
    
    frame.dfRegisteredUnit = unit
end

-- ============================================================
-- CONDITIONAL POWER EVENT REGISTRATION (performance optimization)
-- ============================================================
-- UNIT_POWER_UPDATE fires very frequently, so we only register
-- these events when the power bar is actually enabled.

function DF:UpdatePowerEventRegistration(frame)
    if not frame then return end
    
    local db = DF:GetFrameDB(frame)
    local shouldRegister = db and db.resourceBarEnabled
    
    -- Track registration state to avoid redundant calls
    if frame.dfPowerEventsRegistered == shouldRegister then return end
    
    if shouldRegister then
        -- PERFORMANCE FIX 2025-01-20: Use RegisterUnitEvent for C++ level filtering
        -- This prevents receiving power events for all units in the game world
        local unit = frame.unit
        if unit then
            frame:RegisterUnitEvent("UNIT_POWER_UPDATE", unit)
            frame:RegisterUnitEvent("UNIT_MAXPOWER", unit)
            frame:RegisterUnitEvent("UNIT_DISPLAYPOWER", unit)
        else
            -- Fallback to global registration if unit not set yet
            frame:RegisterEvent("UNIT_POWER_UPDATE")
            frame:RegisterEvent("UNIT_MAXPOWER")
            frame:RegisterEvent("UNIT_DISPLAYPOWER")
        end
        frame.dfPowerEventsRegistered = true
    else
        frame:UnregisterEvent("UNIT_POWER_UPDATE")
        frame:UnregisterEvent("UNIT_MAXPOWER")
        frame:UnregisterEvent("UNIT_DISPLAYPOWER")
        frame.dfPowerEventsRegistered = false
    end
end

-- Update power event registration for all frames (call when setting changes)
-- NOTE: Header children don't have individual event handlers so we skip them
function DF:UpdateAllPowerEventRegistration()
    -- Party frames - use iterators if available (handles both legacy and header modes)
    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(function(frame)
            -- Only update legacy frames (header children don't use per-frame events)
            if frame and not frame.dfIsHeaderChild and frame.RegisterEvent then
                DF:UpdatePowerEventRegistration(frame)
            end
        end)
    end
    
    -- Raid frames - use iterators if available
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(function(frame)
            if frame and not frame.dfIsHeaderChild and frame.RegisterEvent then
                DF:UpdatePowerEventRegistration(frame)
            end
        end)
    end
end

-- ============================================================
-- UNIFIED FRAME CREATION AND UPDATE SYSTEM
-- ============================================================

-- Unified frame creation for both party and raid frames
-- ============================================================
-- CREATE FRAME ELEMENTS
-- Creates all visual elements on a frame (health bar, text, etc.)
-- Used by both legacy CreateUnitFrame and new header system
-- ============================================================

function DF:CreateFrameElements(frame, isRaid)
    if not frame then return end
    if frame.dfElementsCreated then return end  -- Don't create twice
    
    -- Determine if raid based on frame property or parameter
    if isRaid == nil then
        isRaid = frame.isRaidFrame
    end
    
    local db = isRaid and DF:GetRaidDB() or DF:GetDB()
    
    -- Store reference for DB lookups
    frame.isRaidFrame = isRaid
    
    -- ========================================
    -- BACKGROUND
    -- ========================================
    frame.background = frame:CreateTexture(nil, "BACKGROUND")
    frame.background:SetAllPoints()
    frame.background:SetColorTexture(0, 0, 0, 0.8)
    
    -- ========================================
    -- MISSING HEALTH BAR (shows where health is missing)
    -- ========================================
    frame.missingHealthBar = CreateFrame("StatusBar", nil, frame)
    local padding = db.framePadding or 0
    frame.missingHealthBar:SetPoint("TOPLEFT", padding, -padding)
    frame.missingHealthBar:SetPoint("BOTTOMRIGHT", -padding, padding)
    DF:SafeSetStatusBarTexture(frame.missingHealthBar, db.healthTexture or DF.STOCK_BAR_TEXTURE)
    frame.missingHealthBar:SetMinMaxValues(0, 1)
    frame.missingHealthBar:SetValue(0)
    frame.missingHealthBar:SetReverseFill(true)
    -- Match the health bar (frame+3) so the AD background tint (frame+2) sits below both.
    frame.missingHealthBar:SetFrameLevel(frame:GetFrameLevel() + 3)
    local missingColor = db.missingHealthColor or {r = 0.5, g = 0, b = 0, a = 0.8}
    frame.missingHealthBar:SetStatusBarColor(missingColor.r, missingColor.g, missingColor.b, missingColor.a or 0.8)
    frame.missingHealthBar:Hide()
    
    -- ========================================
    -- HEALTH BAR
    -- ========================================
    frame.healthBar = CreateFrame("StatusBar", nil, frame)
    frame.healthBar:SetPoint("TOPLEFT", padding, -padding)
    frame.healthBar:SetPoint("BOTTOMRIGHT", -padding, padding)
    DF:SafeSetStatusBarTexture(frame.healthBar, db.healthTexture or DF.STOCK_BAR_TEXTURE)
    frame.healthBar:SetMinMaxValues(0, 1)
    frame.healthBar:SetValue(1)
    -- Lift the health bar THREE levels above the frame's own level (N) so the Aura
    -- Designer background tint stays BELOW it. That tint lives on a DF.AuraContainer
    -- overlay slot whose host anchor is parked at N; the container nests anchor -> native
    -- AuraContainer -> AuraSlot button, each a default +1 child, so the tint texture lands
    -- at N+2 (NOT N — that was the earlier +1 fix's wrong assumption; a plain child frame
    -- defaults to parent+1, so the bar was already at N+1 and +1 was a no-op). The bar
    -- stack must clear N+2, hence N+3. Bars derived from healthBar:GetFrameLevel() (power,
    -- absorb, reduced-max, etc.) and the missing-health bar (raised to match, below) shift
    -- up with it, so their order among themselves is unchanged.
    frame.healthBar:SetFrameLevel(frame:GetFrameLevel() + 3)

    -- ========================================
    -- CONTENT OVERLAY (for text and icons above bars)
    -- ========================================
    frame.contentOverlay = CreateFrame("Frame", nil, frame)
    frame.contentOverlay:SetAllPoints()
    frame.contentOverlay:SetFrameLevel(frame:GetFrameLevel() + 25)
    frame.contentOverlay:EnableMouse(false)
    
    -- ========================================
    -- NAME TEXT
    -- ========================================
    frame.nameText = frame.contentOverlay:CreateFontString(nil, "OVERLAY")
    local nameOutline = db.nameTextOutline or "OUTLINE"
    if nameOutline == "NONE" then nameOutline = "" end
    DF:SafeSetFont(frame.nameText, db.nameFont or "Fonts\\FRIZQT__.TTF", db.nameFontSize or 11, nameOutline)
    local nameAnchor = db.nameTextAnchor or "TOP"
    frame.nameText:SetPoint(nameAnchor, frame, nameAnchor, db.nameTextX or 0, db.nameTextY or -2)
    frame.nameText:SetTextColor(1, 1, 1, 1)
    frame.nameText:SetDrawLayer("OVERLAY", 7)
    
    -- ========================================
    -- HEALTH TEXT
    -- ========================================
    frame.healthText = frame.contentOverlay:CreateFontString(nil, "OVERLAY")
    local healthOutline = db.healthTextOutline or "OUTLINE"
    if healthOutline == "NONE" then healthOutline = "" end
    DF:SafeSetFont(frame.healthText, db.healthFont or "Fonts\\FRIZQT__.TTF", db.healthFontSize or 10, healthOutline)
    local healthAnchor = db.healthTextAnchor or "CENTER"
    frame.healthText:SetPoint(healthAnchor, frame, healthAnchor, db.healthTextX or 0, db.healthTextY or 0)
    frame.healthText:SetTextColor(1, 1, 1, 1)
    frame.healthText:SetDrawLayer("OVERLAY", 7)
    
    -- ========================================
    -- STATUS TEXT (Dead, Offline, AFK)
    -- ========================================
    frame.statusText = frame.contentOverlay:CreateFontString(nil, "OVERLAY")
    local statusOutline = db.statusTextOutline or "OUTLINE"
    if statusOutline == "NONE" then statusOutline = "" end
    DF:SafeSetFont(frame.statusText, db.statusTextFont or "Fonts\\FRIZQT__.TTF", db.statusTextFontSize or 10, statusOutline)
    local statusAnchor = db.statusTextAnchor or "CENTER"
    frame.statusText:SetPoint(statusAnchor, frame, statusAnchor, db.statusTextX or 0, db.statusTextY or 0)
    local statusColor = db.statusTextColor or {r = 1, g = 1, b = 1}
    frame.statusText:SetTextColor(statusColor.r, statusColor.g, statusColor.b, 1)
    frame.statusText:SetDrawLayer("OVERLAY", 7)
    frame.statusText:Hide()
    
    -- Continue with the rest of the elements...
    -- (Border, icons, power bar, auras, absorbs, etc.)
    -- These are created by calling the internal element creation
    DF:CreateFrameElementsExtended(frame, db)
    
    -- Mark as created
    frame.dfElementsCreated = true
end

-- Extended element creation (called from CreateFrameElements)
-- Creates all visual elements needed for a full unit frame
function DF:CreateFrameElementsExtended(frame, db)
    if not frame or not db then return end
    
    -- ========================================
    -- BORDER
    -- ========================================
    DF:CreateFrameBorder(frame, db)
    
    -- ========================================
    -- ROLE ICON
    -- ========================================
    frame.roleIcon = CreateFrame("Frame", nil, frame.contentOverlay)
    frame.roleIcon:SetSize(18, 18)
    frame.roleIcon:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
    frame.roleIcon:SetFrameLevel(frame.contentOverlay:GetFrameLevel() + 5)
    frame.roleIcon:Hide()
    
    frame.roleIcon.texture = frame.roleIcon:CreateTexture(nil, "OVERLAY")
    frame.roleIcon.texture:SetAllPoints()
    frame.roleIcon.texture:SetDrawLayer("OVERLAY", 7)
    
    -- ========================================
    -- LEADER ICON
    -- ========================================
    frame.leaderIcon = CreateFrame("Frame", nil, frame.contentOverlay)
    frame.leaderIcon:SetSize(12, 12)
    frame.leaderIcon:SetPoint("TOPLEFT", frame, "TOPLEFT", -2, 2)
    frame.leaderIcon:SetFrameLevel(frame.contentOverlay:GetFrameLevel() + 5)
    frame.leaderIcon:Hide()
    
    frame.leaderIcon.texture = frame.leaderIcon:CreateTexture(nil, "OVERLAY")
    frame.leaderIcon.texture:SetAllPoints()
    frame.leaderIcon.texture:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
    frame.leaderIcon.texture:SetDrawLayer("OVERLAY", 7)
    
    -- ========================================
    -- RAID TARGET ICON
    -- ========================================
    frame.raidTargetIcon = CreateFrame("Frame", nil, frame.contentOverlay)
    frame.raidTargetIcon:SetSize(16, 16)
    frame.raidTargetIcon:SetPoint("TOP", frame, "TOP", 0, 2)
    frame.raidTargetIcon:SetFrameLevel(frame.contentOverlay:GetFrameLevel() + 5)
    frame.raidTargetIcon:Hide()
    
    frame.raidTargetIcon.texture = frame.raidTargetIcon:CreateTexture(nil, "OVERLAY")
    frame.raidTargetIcon.texture:SetAllPoints()
    frame.raidTargetIcon.texture:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    frame.raidTargetIcon.texture:SetDrawLayer("OVERLAY", 6)
    
    -- ========================================
    -- READY CHECK ICON
    -- ========================================
    frame.readyCheckIcon = CreateFrame("Frame", nil, frame.contentOverlay)
    frame.readyCheckIcon:SetSize(16, 16)
    frame.readyCheckIcon:SetPoint("CENTER", frame, "CENTER", 0, 0)
    frame.readyCheckIcon:SetFrameLevel(frame.contentOverlay:GetFrameLevel() + 5)
    frame.readyCheckIcon:Hide()
    
    frame.readyCheckIcon.texture = frame.readyCheckIcon:CreateTexture(nil, "OVERLAY")
    frame.readyCheckIcon.texture:SetAllPoints()
    frame.readyCheckIcon.texture:SetDrawLayer("OVERLAY", 7)
    
    -- ========================================
    -- STATUS ICONS (Summon, Res, Phased, AFK, Vehicle, RaidRole)
    -- ========================================
    DF:CreateStatusIcons(frame)
    
    -- ========================================
    -- RESTED INDICATOR (solo mode) - Custom animated ZZZ with glow
    -- ========================================
    frame.restedIndicator = CreateFrame("Frame", nil, frame.contentOverlay)
    frame.restedIndicator:SetSize(24, 18)
    frame.restedIndicator:SetPoint("BOTTOMLEFT", frame, "TOPRIGHT", -18, -14)
    frame.restedIndicator:SetFrameLevel(frame.contentOverlay:GetFrameLevel() + 5)
    frame.restedIndicator:Hide()
    
    -- Create 3 Z FontStrings with increasing sizes
    local zSizes = {8, 11, 14}
    local zOffsets = {0, 5, 12}
    local zYOffsets = {0, 3, 7}
    
    frame.restedIndicator.zTexts = {}
    for i = 1, 3 do
        local z = frame.restedIndicator:CreateFontString(nil, "OVERLAY")
        DF:SafeSetFont(z, nil, zSizes[i], "OUTLINE")
        z:SetText("Z")
        z:SetTextColor(1, 0.82, 0, 1)
        z:SetPoint("BOTTOMLEFT", frame.restedIndicator, "BOTTOMLEFT", zOffsets[i], zYOffsets[i])
        z:SetAlpha(0)
        z.baseSize = zSizes[i]
        frame.restedIndicator.zTexts[i] = z
    end

    -- Create glow texture
    frame.restedGlow = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    frame.restedGlow:SetPoint("TOPLEFT", frame, "TOPLEFT", -4, 4)
    frame.restedGlow:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 4, -4)
    frame.restedGlow:SetTexture("Interface\\Buttons\\WHITE8x8")
    frame.restedGlow:SetVertexColor(1, 0.82, 0, 0.3)
    frame.restedGlow:SetBlendMode("ADD")
    frame.restedGlow:Hide()
    
    -- Animation state
    frame.restedIndicator.animTime = 0
    frame.restedIndicator.cycleDuration = 2.0
    
    -- OnUpdate script for custom animation
    frame.restedIndicator:SetScript("OnUpdate", function(self, elapsed)
        self.animTime = self.animTime + elapsed
        local cycle = self.animTime % self.cycleDuration
        local progress = cycle / self.cycleDuration
        
        for i, z in ipairs(self.zTexts) do
            local zDelay = (i - 1) * 0.15
            local zProgress = (progress - zDelay) % 1
            
            local alpha, scale
            if zProgress < 0.4 then
                local t = zProgress / 0.4
                alpha = t
                scale = 0.5 + (t * 0.5)
            elseif zProgress < 0.7 then
                alpha = 1
                scale = 1
            else
                local t = (zProgress - 0.7) / 0.3
                alpha = 1 - t
                scale = 1
            end
            
            z:SetAlpha(alpha)
            local baseSize = z.baseSize
            DF:SafeSetFont(z, nil, baseSize * scale, "OUTLINE")
        end
        
        local glowAlpha = 0.2 + (math.sin(self.animTime * 3) * 0.15 + 0.1)
        if frame.restedGlow and frame.restedGlow:IsShown() then
            frame.restedGlow:SetAlpha(glowAlpha)
        end
    end)
    
    frame.restedIndicator:SetScript("OnShow", function(self)
        self.animTime = 0
        for _, z in ipairs(self.zTexts) do
            z:Show()
        end
    end)
    
    frame.restedIndicator:SetScript("OnHide", function(self)
        for _, z in ipairs(self.zTexts) do
            z:Hide()
        end
    end)
    
    
    -- ========================================
    -- POWER BAR
    -- ========================================
    frame.dfPowerBar = CreateFrame("StatusBar", nil, frame)
    frame.dfPowerBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    frame.dfPowerBar:SetMinMaxValues(0, 1)
    frame.dfPowerBar:SetValue(1)
    frame.dfPowerBar:SetAlpha(1)
    -- ☠ SAME BAND AS ApplyResourceBarLayout, and READ FROM THE SAME KEY -- not
    -- healthBar+2 (frame+5), and not a hardcoded 20 either. The layout normally
    -- supersedes this before the bar is ever shown (it is created hidden), but the two
    -- values disagreed by fifteen levels, which started the bar UNDER the dispel wash's
    -- full-frame band at frame+17. Same creation-vs-layout split that left
    -- DF:ResolveAbsorbBarLevel as dead code.
    -- ⚠ A hardcoded 20 is only correct on a default profile: the key is user-facing
    -- and a lowered value is normal (Krathe's own runs 10 -- /df debug zorder). Reading
    -- the key is what keeps the two writers agreeing for everyone; a constant that
    -- happens to match the default just hides the split again.
    local powerDB = DF.GetFrameDB and DF:GetFrameDB(frame)
    frame.dfPowerBar:SetFrameLevel(frame:GetFrameLevel()
        + ((powerDB and powerDB.resourceBarFrameLevel) or 20))
    frame.dfPowerBar:Hide()
    
    local powerBg = frame.dfPowerBar:CreateTexture(nil, "BACKGROUND")
    powerBg:SetAllPoints()
    powerBg:SetColorTexture(0, 0, 0, 0.8)
    frame.dfPowerBar.bg = powerBg
    
    -- Power / Resource bar border via the unified DF.Border backend
    -- (Stage 4.2). ApplyResourceBarLayout in Frames/Bars.lua drives
    -- BuildSpec + Apply on each update; border anchorTo defaults to the
    -- bar itself so it surrounds the resource bar's bounds.
    frame.dfPowerBar.border = DF.Border:New(frame.dfPowerBar)
    
    -- ========================================
    -- ABSORB BAR
    -- ========================================
    -- Parent to healthBar (not frame) so frame level tracks alongside the dispel
    -- gradient (also parented to healthBar). This prevents the gradient from
    -- drifting above the absorb bars when SecureGroupHeaderTemplate adjusts
    -- healthBar's frame level after creation. Levels bumped to stay above
    -- the gradient which sits at healthBar+2.
    frame.dfAbsorbBar = CreateFrame("StatusBar", nil, frame.healthBar)
    frame.dfAbsorbBar:SetStatusBarTexture("Interface\\RaidFrame\\Shield-Fill")
    frame.dfAbsorbBar:SetMinMaxValues(0, 1)
    frame.dfAbsorbBar:SetValue(0)
    -- ⚠ SEED ONLY. UpdateAbsorb (Bars.lua) and the settings callback (Core.lua) both
    -- re-level this to frame + absorbBarFrameLevel (11) the first time they run, so
    -- healthBar+4 is what it looks like for a fraction of a second and never after.
    -- Kept so the bar is ordered before the first update rather than defaulting to
    -- parent+1, but do NOT reason from it: the dispel wash used to derive its own
    -- level from "absorb is at healthBar+4" and ended up tied with the real one.
    -- (Z-order review, 2026-08-07.)
    frame.dfAbsorbBar:SetFrameLevel(frame.healthBar:GetFrameLevel() + 4)
    frame.dfAbsorbBar:Hide()

    local absorbBg = frame.dfAbsorbBar:CreateTexture(nil, "BACKGROUND")
    absorbBg:SetAllPoints()
    absorbBg:SetColorTexture(0, 0, 0, 0)
    frame.dfAbsorbBar.bg = absorbBg

    local absorbBorder = CreateFrame("Frame", nil, frame.dfAbsorbBar, "BackdropTemplate")
    absorbBorder:SetPoint("TOPLEFT", -1, 1)
    absorbBorder:SetPoint("BOTTOMRIGHT", 1, -1)
    absorbBorder:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    absorbBorder:SetBackdropBorderColor(0, 0, 0, 1)
    absorbBorder:Hide()
    frame.dfAbsorbBar.border = absorbBorder

    -- ========================================
    -- HEAL ABSORB BAR
    -- ========================================
    frame.dfHealAbsorbBar = CreateFrame("StatusBar", nil, frame.healthBar)
    frame.dfHealAbsorbBar:SetStatusBarTexture("Interface\\RaidFrame\\Shield-Fill")
    frame.dfHealAbsorbBar:SetMinMaxValues(0, 1)
    frame.dfHealAbsorbBar:SetValue(0)
    frame.dfHealAbsorbBar:SetFrameLevel(frame.healthBar:GetFrameLevel() + 5)
    frame.dfHealAbsorbBar:Hide()

    local healAbsorbBg = frame.dfHealAbsorbBar:CreateTexture(nil, "BACKGROUND")
    healAbsorbBg:SetAllPoints()
    healAbsorbBg:SetColorTexture(0, 0, 0, 0)
    frame.dfHealAbsorbBar.bg = healAbsorbBg

    local healAbsorbBorder = CreateFrame("Frame", nil, frame.dfHealAbsorbBar, "BackdropTemplate")
    healAbsorbBorder:SetPoint("TOPLEFT", -1, 1)
    healAbsorbBorder:SetPoint("BOTTOMRIGHT", 1, -1)
    healAbsorbBorder:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    healAbsorbBorder:SetBackdropBorderColor(0, 0, 0, 1)
    healAbsorbBorder:Hide()
    frame.dfHealAbsorbBar.border = healAbsorbBorder

    -- ========================================
    -- REDUCED MAX HEALTH BAR
    -- ========================================
    if DF.CreateReducedMaxHealthBar then
        DF:CreateReducedMaxHealthBar(frame, db)
    end

    -- ========================================
    -- AURA CONTAINER AND ICONS
    -- ========================================
end

function DF:CreateUnitFrame(unit, index, isRaid)
    local db = isRaid and DF:GetRaidDB() or DF:GetDB()
    local parent = isRaid and DF.raidContainer or DF.container
    
    -- Generate frame name
    local frameName
    if isRaid then
        frameName = "DandersRaidFrame" .. index
    else
        frameName = "DandersFrames_" .. (unit == "player" and "Player" or "Party" .. index)
    end
    
    local frame = CreateFrame("Button", frameName, parent, "SecureUnitButtonTemplate,SecureHandlerEnterLeaveTemplate")
    frame:SetSize(db.frameWidth or 120, db.frameHeight or 50)
    frame.unit = unit
    frame.index = index
    frame.isRaidFrame = isRaid  -- Key flag for determining DB source
    frame.dfIsDandersFrame = true  -- Mark as DandersFrames frame for click casting module
    
    -- Register unit attribute
    frame:SetAttribute("unit", unit)
    -- Note: type1/type2 are set by click-casting module (or RestoreBlizzardDefaults when disabled)
    
    -- Register unit watch (managed externally for party frames)
    if isRaid then
        DF:SafeRegisterUnitWatch(frame)
    end
    
    -- Enable mouse
    frame:RegisterForClicks("AnyUp")
    
    -- ========================================
    -- BACKGROUND
    -- ========================================
    frame.background = frame:CreateTexture(nil, "BACKGROUND")
    frame.background:SetAllPoints()
    frame.background:SetColorTexture(0, 0, 0, 0.8)
    
    -- ========================================
    -- MISSING HEALTH BAR (shows where health is missing)
    -- ========================================
    frame.missingHealthBar = CreateFrame("StatusBar", nil, frame)
    local padding = db.framePadding or 0
    frame.missingHealthBar:SetPoint("TOPLEFT", padding, -padding)
    frame.missingHealthBar:SetPoint("BOTTOMRIGHT", -padding, padding)
    DF:SafeSetStatusBarTexture(frame.missingHealthBar, db.healthTexture or DF.STOCK_BAR_TEXTURE)
    frame.missingHealthBar:SetMinMaxValues(0, 1)  -- Will be updated dynamically with UnitHealthMax
    frame.missingHealthBar:SetValue(0)
    frame.missingHealthBar:SetReverseFill(true)  -- Fill from right side (where health is missing)
    -- Match the health bar (frame+3) so the AD background tint (frame+2) sits below both.
    frame.missingHealthBar:SetFrameLevel(frame:GetFrameLevel() + 3)  -- Above background + AD bg tint, level with health bar
    local missingColor = db.missingHealthColor or {r = 0.5, g = 0, b = 0, a = 0.8}
    frame.missingHealthBar:SetStatusBarColor(missingColor.r, missingColor.g, missingColor.b, missingColor.a or 0.8)
    -- Initially hidden, visibility controlled by backgroundMode setting
    frame.missingHealthBar:Hide()
    
    -- ========================================
    -- HEALTH BAR
    -- ========================================
    frame.healthBar = CreateFrame("StatusBar", nil, frame)
    frame.healthBar:SetPoint("TOPLEFT", padding, -padding)
    frame.healthBar:SetPoint("BOTTOMRIGHT", -padding, padding)
    DF:SafeSetStatusBarTexture(frame.healthBar, db.healthTexture or DF.STOCK_BAR_TEXTURE)
    frame.healthBar:SetMinMaxValues(0, 1)
    frame.healthBar:SetValue(1)
    -- Lift the health bar THREE levels above the frame's own level (N) so the Aura
    -- Designer background tint stays BELOW it. That tint lives on a DF.AuraContainer
    -- overlay slot whose host anchor is parked at N; the container nests anchor -> native
    -- AuraContainer -> AuraSlot button, each a default +1 child, so the tint texture lands
    -- at N+2 (NOT N — that was the earlier +1 fix's wrong assumption; a plain child frame
    -- defaults to parent+1, so the bar was already at N+1 and +1 was a no-op). The bar
    -- stack must clear N+2, hence N+3. Bars derived from healthBar:GetFrameLevel() (power,
    -- absorb, reduced-max, etc.) and the missing-health bar (raised to match, below) shift
    -- up with it, so their order among themselves is unchanged.
    frame.healthBar:SetFrameLevel(frame:GetFrameLevel() + 3)

    -- ========================================
    -- CONTENT OVERLAY (for text and icons above bars)
    -- ========================================
    frame.contentOverlay = CreateFrame("Frame", nil, frame)
    frame.contentOverlay:SetAllPoints()
    frame.contentOverlay:SetFrameLevel(frame:GetFrameLevel() + 25)
    frame.contentOverlay:EnableMouse(false)  -- Don't intercept mouse - let clicks pass to unit frame
    
    -- ========================================
    -- NAME TEXT
    -- ========================================
    frame.nameText = frame.contentOverlay:CreateFontString(nil, "OVERLAY")
    local nameOutline = db.nameTextOutline or "OUTLINE"
    if nameOutline == "NONE" then nameOutline = "" end
    DF:SafeSetFont(frame.nameText, db.nameFont or "Fonts\\FRIZQT__.TTF", db.nameFontSize or 11, nameOutline)
    local nameAnchor = db.nameTextAnchor or "TOP"
    frame.nameText:SetPoint(nameAnchor, frame, nameAnchor, db.nameTextX or 0, db.nameTextY or -2)
    frame.nameText:SetTextColor(1, 1, 1, 1)
    frame.nameText:SetDrawLayer("OVERLAY", 7)
    
    -- ========================================
    -- HEALTH TEXT
    -- ========================================
    frame.healthText = frame.contentOverlay:CreateFontString(nil, "OVERLAY")
    local healthOutline = db.healthTextOutline or "OUTLINE"
    if healthOutline == "NONE" then healthOutline = "" end
    DF:SafeSetFont(frame.healthText, db.healthFont or "Fonts\\FRIZQT__.TTF", db.healthFontSize or 10, healthOutline)
    local healthAnchor = db.healthTextAnchor or "CENTER"
    frame.healthText:SetPoint(healthAnchor, frame, healthAnchor, db.healthTextX or 0, db.healthTextY or 0)
    frame.healthText:SetTextColor(1, 1, 1, 1)
    frame.healthText:SetDrawLayer("OVERLAY", 7)
    
    -- ========================================
    -- STATUS TEXT (Dead, Offline, AFK)
    -- ========================================
    frame.statusText = frame.contentOverlay:CreateFontString(nil, "OVERLAY")
    local statusOutline = db.statusTextOutline or "OUTLINE"
    if statusOutline == "NONE" then statusOutline = "" end
    DF:SafeSetFont(frame.statusText, db.statusTextFont or "Fonts\\FRIZQT__.TTF", db.statusTextFontSize or 10, statusOutline)
    local statusAnchor = db.statusTextAnchor or "CENTER"
    frame.statusText:SetPoint(statusAnchor, frame, statusAnchor, db.statusTextX or 0, db.statusTextY or 0)
    local statusColor = db.statusTextColor or {r = 1, g = 1, b = 1}
    frame.statusText:SetTextColor(statusColor.r, statusColor.g, statusColor.b, 1)
    frame.statusText:SetDrawLayer("OVERLAY", 7)
    frame.statusText:Hide()
    
    -- ========================================
    -- BORDER
    -- ========================================
    DF:CreateFrameBorder(frame, db)
    
    -- ========================================
    -- ROLE ICON
    -- ========================================
    frame.roleIcon = CreateFrame("Frame", nil, frame.contentOverlay)
    frame.roleIcon:SetSize(18, 18)
    frame.roleIcon:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
    frame.roleIcon:SetFrameLevel(frame.contentOverlay:GetFrameLevel() + 5)
    frame.roleIcon:Hide()
    
    frame.roleIcon.texture = frame.roleIcon:CreateTexture(nil, "OVERLAY")
    frame.roleIcon.texture:SetAllPoints()
    frame.roleIcon.texture:SetDrawLayer("OVERLAY", 7)
    
    -- ========================================
    -- LEADER ICON
    -- ========================================
    frame.leaderIcon = CreateFrame("Frame", nil, frame.contentOverlay)
    frame.leaderIcon:SetSize(12, 12)
    frame.leaderIcon:SetPoint("TOPLEFT", frame, "TOPLEFT", -2, 2)
    frame.leaderIcon:SetFrameLevel(frame.contentOverlay:GetFrameLevel() + 5)
    frame.leaderIcon:Hide()
    
    frame.leaderIcon.texture = frame.leaderIcon:CreateTexture(nil, "OVERLAY")
    frame.leaderIcon.texture:SetAllPoints()
    frame.leaderIcon.texture:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
    frame.leaderIcon.texture:SetDrawLayer("OVERLAY", 7)
    
    -- ========================================
    -- RAID TARGET ICON
    -- ========================================
    frame.raidTargetIcon = CreateFrame("Frame", nil, frame.contentOverlay)
    frame.raidTargetIcon:SetSize(16, 16)
    frame.raidTargetIcon:SetPoint("TOP", frame, "TOP", 0, 2)
    frame.raidTargetIcon:SetFrameLevel(frame.contentOverlay:GetFrameLevel() + 5)
    frame.raidTargetIcon:Hide()
    
    frame.raidTargetIcon.texture = frame.raidTargetIcon:CreateTexture(nil, "OVERLAY")
    frame.raidTargetIcon.texture:SetAllPoints()
    frame.raidTargetIcon.texture:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    frame.raidTargetIcon.texture:SetDrawLayer("OVERLAY", 6)
    
    -- ========================================
    -- READY CHECK ICON
    -- ========================================
    frame.readyCheckIcon = CreateFrame("Frame", nil, frame.contentOverlay)
    frame.readyCheckIcon:SetSize(16, 16)
    frame.readyCheckIcon:SetPoint("CENTER", frame, "CENTER", 0, 0)
    frame.readyCheckIcon:SetFrameLevel(frame.contentOverlay:GetFrameLevel() + 5)
    frame.readyCheckIcon:Hide()
    
    frame.readyCheckIcon.texture = frame.readyCheckIcon:CreateTexture(nil, "OVERLAY")
    frame.readyCheckIcon.texture:SetAllPoints()
    frame.readyCheckIcon.texture:SetDrawLayer("OVERLAY", 7)
    
    -- ========================================
    -- STATUS ICONS (Summon, Res, Phased, AFK, Vehicle, RaidRole)
    -- ========================================
    DF:CreateStatusIcons(frame)
    
    -- ========================================
    -- RESTED INDICATOR (solo mode) - Custom animated ZZZ with glow
    -- ========================================
    frame.restedIndicator = CreateFrame("Frame", nil, frame.contentOverlay)
    frame.restedIndicator:SetSize(24, 18)
    frame.restedIndicator:SetPoint("BOTTOMLEFT", frame, "TOPRIGHT", -18, -14)  -- Half on, half off corner
    frame.restedIndicator:SetFrameLevel(frame.contentOverlay:GetFrameLevel() + 5)
    frame.restedIndicator:Hide()
    
    -- Create 3 Z FontStrings with increasing sizes, going UP and to the right
    -- Tighter spacing with some overlap
    local zSizes = {8, 11, 14}  -- Smallest to largest (left to right)
    local zOffsets = {0, 5, 12}  -- X positions (tighter, overlapping)
    local zYOffsets = {0, 3, 7}  -- Y offsets going UP
    
    frame.restedIndicator.zTexts = {}
    for i = 1, 3 do
        local z = frame.restedIndicator:CreateFontString(nil, "OVERLAY")
        DF:SafeSetFont(z, nil, zSizes[i], "OUTLINE")
        z:SetText("Z")
        z:SetTextColor(1, 0.82, 0, 1)  -- Yellow/gold color
        z:SetPoint("BOTTOMLEFT", frame.restedIndicator, "BOTTOMLEFT", zOffsets[i], zYOffsets[i])
        z:SetAlpha(0)
        z.baseSize = zSizes[i]  -- PERFORMANCE FIX: Store base size to avoid table allocation in OnUpdate
        frame.restedIndicator.zTexts[i] = z
    end
    
    -- Create glow texture around the frame (more visible)
    frame.restedGlow = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    frame.restedGlow:SetPoint("TOPLEFT", frame, "TOPLEFT", -4, 4)
    frame.restedGlow:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 4, -4)
    frame.restedGlow:SetTexture("Interface\\Buttons\\WHITE8x8")
    frame.restedGlow:SetVertexColor(1, 0.82, 0, 0.3)  -- Yellow glow, more visible
    frame.restedGlow:SetBlendMode("ADD")
    frame.restedGlow:Hide()
    
    -- Animation state
    frame.restedIndicator.animTime = 0
    frame.restedIndicator.cycleDuration = 2.0  -- Full cycle duration
    
    -- OnUpdate script for custom animation
    frame.restedIndicator:SetScript("OnUpdate", function(self, elapsed)
        self.animTime = self.animTime + elapsed
        local cycle = self.animTime % self.cycleDuration
        local progress = cycle / self.cycleDuration
        
        -- Animate each Z with staggered timing
        for i, z in ipairs(self.zTexts) do
            -- Each Z starts at different times in the cycle (0, 0.15, 0.30)
            local zDelay = (i - 1) * 0.15
            local zProgress = (progress - zDelay) % 1
            
            -- Z fades in, scales up, then fades out
            local alpha, scale
            if zProgress < 0.4 then
                -- Fade in and scale up (0 to 0.4)
                local t = zProgress / 0.4
                alpha = t
                scale = 0.5 + (t * 0.5)  -- Scale from 50% to 100%
            elseif zProgress < 0.7 then
                -- Hold (0.4 to 0.7)
                alpha = 1
                scale = 1
            else
                -- Fade out (0.7 to 1.0)
                local t = (zProgress - 0.7) / 0.3
                alpha = 1 - t
                scale = 1
            end
            
            z:SetAlpha(alpha)
            -- Scale effect by adjusting font size
            -- PERFORMANCE FIX: Use stored baseSize instead of creating table every frame
            local baseSize = z.baseSize
            DF:SafeSetFont(z, nil, baseSize * scale, "OUTLINE")
        end
        
        -- Animate glow pulsing (stronger pulse)
        local glowAlpha = 0.2 + (math.sin(self.animTime * 3) * 0.15 + 0.1)
        if frame.restedGlow and frame.restedGlow:IsShown() then
            frame.restedGlow:SetAlpha(glowAlpha)
        end
    end)
    
    -- Start/stop animation
    frame.restedIndicator:SetScript("OnShow", function(self)
        self.animTime = 0
        for _, z in ipairs(self.zTexts) do
            z:Show()
        end
    end)
    
    frame.restedIndicator:SetScript("OnHide", function(self)
        for _, z in ipairs(self.zTexts) do
            z:Hide()
        end
    end)
    
    
    -- ========================================
    -- POWER BAR
    -- ========================================
    frame.dfPowerBar = CreateFrame("StatusBar", nil, frame)
    frame.dfPowerBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    frame.dfPowerBar:SetMinMaxValues(0, 1)
    frame.dfPowerBar:SetValue(1)
    frame.dfPowerBar:SetAlpha(1)
    -- ☠ SAME BAND AS ApplyResourceBarLayout, and READ FROM THE SAME KEY -- not
    -- healthBar+2 (frame+5), and not a hardcoded 20 either. The layout normally
    -- supersedes this before the bar is ever shown (it is created hidden), but the two
    -- values disagreed by fifteen levels, which started the bar UNDER the dispel wash's
    -- full-frame band at frame+17. Same creation-vs-layout split that left
    -- DF:ResolveAbsorbBarLevel as dead code.
    -- ⚠ A hardcoded 20 is only correct on a default profile: the key is user-facing
    -- and a lowered value is normal (Krathe's own runs 10 -- /df debug zorder). Reading
    -- the key is what keeps the two writers agreeing for everyone; a constant that
    -- happens to match the default just hides the split again.
    local powerDB = DF.GetFrameDB and DF:GetFrameDB(frame)
    frame.dfPowerBar:SetFrameLevel(frame:GetFrameLevel()
        + ((powerDB and powerDB.resourceBarFrameLevel) or 20))
    frame.dfPowerBar:Hide()
    
    local powerBg = frame.dfPowerBar:CreateTexture(nil, "BACKGROUND")
    powerBg:SetAllPoints()
    powerBg:SetColorTexture(0, 0, 0, 0.8)
    frame.dfPowerBar.bg = powerBg
    
    -- Power / Resource bar border via the unified DF.Border backend
    -- (Stage 4.2). ApplyResourceBarLayout in Frames/Bars.lua drives
    -- BuildSpec + Apply on each update; border anchorTo defaults to the
    -- bar itself so it surrounds the resource bar's bounds.
    frame.dfPowerBar.border = DF.Border:New(frame.dfPowerBar)
    
    -- ========================================
    -- ABSORB BAR
    -- ========================================
    -- Parent to healthBar (not frame) so frame level tracks alongside the dispel
    -- gradient (also parented to healthBar). This prevents the gradient from
    -- drifting above the absorb bars when SecureGroupHeaderTemplate adjusts
    -- healthBar's frame level after creation. Levels bumped to stay above
    -- the gradient which sits at healthBar+2.
    frame.dfAbsorbBar = CreateFrame("StatusBar", nil, frame.healthBar)
    frame.dfAbsorbBar:SetStatusBarTexture("Interface\\RaidFrame\\Shield-Fill")
    frame.dfAbsorbBar:SetMinMaxValues(0, 1)
    frame.dfAbsorbBar:SetValue(0)
    -- ⚠ SEED ONLY. UpdateAbsorb (Bars.lua) and the settings callback (Core.lua) both
    -- re-level this to frame + absorbBarFrameLevel (11) the first time they run, so
    -- healthBar+4 is what it looks like for a fraction of a second and never after.
    -- Kept so the bar is ordered before the first update rather than defaulting to
    -- parent+1, but do NOT reason from it: the dispel wash used to derive its own
    -- level from "absorb is at healthBar+4" and ended up tied with the real one.
    -- (Z-order review, 2026-08-07.)
    frame.dfAbsorbBar:SetFrameLevel(frame.healthBar:GetFrameLevel() + 4)
    frame.dfAbsorbBar:Hide()

    local absorbBg = frame.dfAbsorbBar:CreateTexture(nil, "BACKGROUND")
    absorbBg:SetAllPoints()
    absorbBg:SetColorTexture(0, 0, 0, 0)
    frame.dfAbsorbBar.bg = absorbBg

    -- Border for absorb bar
    local absorbBorder = CreateFrame("Frame", nil, frame.dfAbsorbBar, "BackdropTemplate")
    absorbBorder:SetPoint("TOPLEFT", -1, 1)
    absorbBorder:SetPoint("BOTTOMRIGHT", 1, -1)
    absorbBorder:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    absorbBorder:SetBackdropBorderColor(0, 0, 0, 1)
    absorbBorder:Hide()
    frame.dfAbsorbBar.border = absorbBorder

    -- ========================================
    -- HEAL ABSORB BAR
    -- ========================================
    frame.dfHealAbsorbBar = CreateFrame("StatusBar", nil, frame.healthBar)
    frame.dfHealAbsorbBar:SetStatusBarTexture("Interface\\RaidFrame\\Shield-Fill")
    frame.dfHealAbsorbBar:SetMinMaxValues(0, 1)
    frame.dfHealAbsorbBar:SetValue(0)
    frame.dfHealAbsorbBar:SetFrameLevel(frame.healthBar:GetFrameLevel() + 5)
    frame.dfHealAbsorbBar:Hide()

    local healAbsorbBg = frame.dfHealAbsorbBar:CreateTexture(nil, "BACKGROUND")
    healAbsorbBg:SetAllPoints()
    healAbsorbBg:SetColorTexture(0, 0, 0, 0)
    frame.dfHealAbsorbBar.bg = healAbsorbBg

    -- Border for heal absorb bar
    local healAbsorbBorder = CreateFrame("Frame", nil, frame.dfHealAbsorbBar, "BackdropTemplate")
    healAbsorbBorder:SetPoint("TOPLEFT", -1, 1)
    healAbsorbBorder:SetPoint("BOTTOMRIGHT", 1, -1)
    healAbsorbBorder:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    healAbsorbBorder:SetBackdropBorderColor(0, 0, 0, 1)
    healAbsorbBorder:Hide()
    frame.dfHealAbsorbBar.border = healAbsorbBorder

    -- ========================================
    -- REDUCED MAX HEALTH BAR
    -- ========================================
    if DF.CreateReducedMaxHealthBar then
        DF:CreateReducedMaxHealthBar(frame, db)
    end

    -- ========================================
    -- AURA CONTAINER AND ICONS
    -- ========================================
    
    -- ========================================
    -- EVENTS
    -- ========================================
    
    -- PERFORMANCE FIX 2025-01-20: Use RegisterUnitEvent for unit-specific events
    -- This filters events at the C++ level, preventing us from receiving events
    -- for units we don't care about (massive performance gain in cities)
    DF:RegisterUnitEventsForFrame(frame, unit)
    
    -- NOTE: Global events (RAID_TARGET_UPDATE, READY_CHECK, PARTY_LEADER_CHANGED, PLAYER_ROLES_ASSIGNED)
    -- are all handled centrally by headerChildEventFrame in Headers.lua
    -- Do NOT register them per-frame or we'll get double processing!
    
    
    -- Conditionally register power events based on setting (optimization)
    -- UNIT_POWER_UPDATE fires very frequently, so skip if power bar disabled
    DF:UpdatePowerEventRegistration(frame)
    
    -- ========================================
    -- EVENT HANDLER
    -- ========================================
    frame:SetScript("OnEvent", function(self, event, eventUnit)
        -- Wait until addon is fully initialized
        if not DF.initialized then return end
        
        -- MEMORY TEST: Nuclear option - disable ALL event handling
        if DF:MemTestDisabled("enableAllEvents") then return end
        
        -- PERFORMANCE NOTE 2025-01-20: With RegisterUnitEvent, unit events are now filtered
        -- at the C++ level, so this check should rarely/never trigger for unit events.
        -- Keeping it as a safety measure in case of edge cases or fallback paths.
        if eventUnit and eventUnit ~= self.unit then return end
        
        -- Route events to appropriate update functions
        if event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
            if not DF:MemTestDisabled("enableHealthUpdates") then
                if DF.UpdateHealthFast then
                    DF:UpdateHealthFast(self)
                else
                    DF:UpdateUnitFrame(self, "UNIT_HEALTH")
                end
            end
        elseif event == "UNIT_NAME_UPDATE" then
            if not DF:MemTestDisabled("enableNameUpdates") then
                DF:UpdateName(self)
            end
        elseif event == "UNIT_AURA" then
            -- UpdateAuras, UpdateMissingBuffIcon, and UpdateDispelOverlay driven by hooksecurefunc (Auras.lua), not here
            if DF.UpdateExternalDefIcon then
                DF:UpdateExternalDefIcon(self)
            end
        elseif event == "UNIT_POWER_UPDATE" or event == "UNIT_MAXPOWER" or event == "UNIT_DISPLAYPOWER" then
            if not DF:MemTestDisabled("enablePowerBar") then
                if DF.UpdatePower then
                    DF:UpdatePower(self)
                else
                    DF:UpdateUnitFrame(self, "UNIT_POWER")
                end
            end
        elseif event == "UNIT_ABSORB_AMOUNT_CHANGED" then
            -- Skip in test mode - test mode handles its own absorb display
            if not DF.testMode and not DF.raidTestMode then
                DF:UpdateAbsorb(self)
            end
        elseif event == "UNIT_HEAL_ABSORB_AMOUNT_CHANGED" then
            -- Skip in test mode - test mode handles its own heal absorb display
            if not DF.testMode and not DF.raidTestMode then
                DF:UpdateHealAbsorb(self)
            end
        elseif event == "UNIT_HEAL_PREDICTION" then
            -- Skip in test mode - test mode handles its own heal prediction display
            if not DF.testMode and not DF.raidTestMode then
                DF:UpdateHealPrediction(self)
            end
        elseif event == "UNIT_CONNECTION" then
            if not DF:MemTestDisabled("enableConnectionStatus") then
                DF:UpdateUnitFrame(self)
            end
        elseif event == "READY_CHECK_CONFIRM" then
            if not DF:MemTestDisabled("enableStatusIcons") then
                DF:UpdateReadyCheckIcon(self)
            end
        elseif event == "INCOMING_SUMMON_CHANGED" or event == "INCOMING_RESURRECT_CHANGED" then
            if not DF:MemTestDisabled("enableStatusIcons") then
                DF:UpdateCenterStatusIcon(self)
            end
        end
    end)
    
    -- ========================================
    -- ON SHOW HANDLER
    -- ========================================
    frame:SetScript("OnShow", function(self)
        if not DF.initialized then return end
        DF:UpdateUnitFrame(self)
    end)
    
    -- ========================================
    -- TOOLTIP HANDLERS
    -- ========================================
    
    -- Helper to get opposite anchor point for tooltip positioning
    local function GetOppositeAnchor(anchor)
        local opposites = {
            TOPLEFT = "BOTTOMRIGHT",
            TOP = "BOTTOM",
            TOPRIGHT = "BOTTOMLEFT",
            LEFT = "RIGHT",
            CENTER = "CENTER",
            RIGHT = "LEFT",
            BOTTOMLEFT = "TOPRIGHT",
            BOTTOM = "TOP",
            BOTTOMRIGHT = "TOPLEFT",
        }
        return opposites[anchor] or "BOTTOMLEFT"
    end
    
    -- Helper to map anchor position to WoW cursor anchor type
    local function GetCursorAnchorType(anchorPos)
        -- Map anchor positions to WoW cursor anchor types
        -- These anchors make the tooltip follow the cursor
        if anchorPos == "LEFT" or anchorPos == "TOPLEFT" or anchorPos == "BOTTOMLEFT" then
            return "ANCHOR_CURSOR_RIGHT"  -- Tooltip to left of cursor
        elseif anchorPos == "RIGHT" or anchorPos == "TOPRIGHT" or anchorPos == "BOTTOMRIGHT" then
            return "ANCHOR_CURSOR_LEFT"   -- Tooltip to right of cursor
        elseif anchorPos == "TOP" then
            return "ANCHOR_CURSOR"        -- Tooltip above cursor
        elseif anchorPos == "BOTTOM" then
            return "ANCHOR_CURSOR"        -- No native below option, use default
        else
            return "ANCHOR_CURSOR"        -- Default: tooltip above-right of cursor
        end
    end
    
    -- Helper function to position tooltip based on settings
    local function PositionFrameTooltip(anchorFrame)
        local db = DF:GetFrameDB(anchorFrame)
        local anchor = db.tooltipFrameAnchor or "DEFAULT"
        local anchorPos = db.tooltipFrameAnchorPos or "BOTTOMRIGHT"
        local offsetX = db.tooltipFrameX or 0
        local offsetY = db.tooltipFrameY or 0
        
        if anchor == "CURSOR" then
            -- Use WoW's built-in cursor anchors that follow the cursor
            local cursorAnchor = GetCursorAnchorType(anchorPos)
            GameTooltip:SetOwner(anchorFrame, cursorAnchor)
        elseif anchor == "FRAME" then
            GameTooltip:SetOwner(anchorFrame, "ANCHOR_NONE")
            GameTooltip:ClearAllPoints()
            local tooltipAnchor = GetOppositeAnchor(anchorPos)
            GameTooltip:SetPoint(tooltipAnchor, anchorFrame, anchorPos, offsetX, offsetY)
        else
            -- DEFAULT - use game's default anchor
            GameTooltip_SetDefaultAnchor(GameTooltip, anchorFrame)
        end
    end
    
    -- ========================================
    -- TOOLTIP HELPERS (parent-driven, Grid2 style)
    -- ========================================

    -- Walk the parent chain to check if a frame is a descendant of a unit frame.
    -- Used to detect Blizzard-rendered private aura icons and other children.
    local function IsChildOfUnitFrame(focus, unitFrame)
        local parent = focus.GetParent and focus:GetParent()
        for _ = 1, 10 do
            if not parent then return false end
            if parent == unitFrame then return true end
            parent = parent.GetParent and parent:GetParent()
        end
        return false
    end

    -- Resolve a clean (untainted) unit token for tooltip use.
    -- Midnight 12.0 taints unit tokens from secure frame attributes, which causes
    -- GameTooltip:GetUnit() to return a secret value. Third-party tooltip hooks
    -- (e.g. RaiderIO) bail out on secret values via issecretvalue(). This function
    -- matches the frame's GUID against clean literal tokens to find an untainted match.
    local function GetCleanUnitForTooltip(frame)
        local guid = frame.unit and UnitGUID(frame.unit)
        if not guid or issecretvalue(guid) then return nil end

        if UnitGUID("player") == guid then return "player" end

        if IsInRaid() then
            for i = 1, GetNumGroupMembers() do
                local token = "raid" .. i
                if UnitGUID(token) == guid then return token end
            end
        else
            for i = 1, GetNumSubgroupMembers() do
                local token = "party" .. i
                if UnitGUID(token) == guid then return token end
            end
        end
        return nil
    end

    -- Use HookScript (not SetScript) to preserve SecureHandlerEnterLeaveTemplate's _onenter/_onleave
    -- SetScript would override the template's handler and break click-casting keyboard bindings
    frame:HookScript("OnEnter", function(self)
        local db = DF:GetFrameDB(self)

        -- Always: set hover state and update highlights
        self.dfIsHovered = true
        if DF.UpdateHighlights then
            DF:UpdateHighlights(self)
        end

        -- Check if we're actually hovering a child element with SetPropagateMouseMotion
        local focus = GetMouseFocus and GetMouseFocus() or GetMouseFoci and GetMouseFoci()[1]
        if focus and focus ~= self then
            -- Any other child (private aura icons, etc.) → don't override native tooltip
            if IsChildOfUnitFrame(focus, self) then
                return
            end
        end

        -- Unit frame itself → show unit tooltip
        if not db.tooltipFrameEnabled then return end
        if db.tooltipFrameDisableInCombat and InCombatLockdown() then return end

        -- Check for test mode (party or raid)
        local inTestMode = (self.isRaidFrame and DF.raidTestMode) or (not self.isRaidFrame and DF.testMode)

        if inTestMode then
            local testData = DF:GetTestUnitData(self.unit == "player" and 0 or tonumber(self.unit:match("%d+")))
            if testData then
                PositionFrameTooltip(self)
                GameTooltip:AddLine(testData.name, 1, 1, 1)
                GameTooltip:AddLine("Level 80 " .. (testData.class or "Unknown"), 0.8, 0.8, 0.8)
                GameTooltip:AddLine(testData.role or "DPS", 0.5, 0.5, 1)
                GameTooltip:AddLine(string.format("Health: %.0f%%", (testData.healthPercent or 1) * 100), 0, 1, 0)
                if testData.status then
                    GameTooltip:AddLine(testData.status, 1, 0, 0)
                end
                GameTooltip:Show()
            end
        else
            PositionFrameTooltip(self)
            local unit = GetCleanUnitForTooltip(self) or self.unit
            GameTooltip:SetUnit(unit)
            local _, ttUnit = GameTooltip:GetUnit()
            if (not ttUnit or issecretvalue(ttUnit)) and _G.RaiderIO and _G.RaiderIO.ShowProfile then
                _G.RaiderIO.ShowProfile(GameTooltip, unit)
            end
            StartTooltipRefresh(self)
        end
        DF:ShowBindingTooltip(self)
    end)
    
    frame:HookScript("OnLeave", function(self)
        -- Always: clear hover state and update highlights
        self.dfIsHovered = false
        if DF.UpdateHighlights then
            DF:UpdateHighlights(self)
        end

        -- Don't hide tooltip if we're moving to a child (our icon or private aura)
        local focus = GetMouseFocus and GetMouseFocus() or GetMouseFoci and GetMouseFoci()[1]
        if focus then
            if focus.unitFrame == self then return end           -- still over our icon
            if IsChildOfUnitFrame(focus, self) then return end   -- still over a child (e.g. private aura)
        end
        StopTooltipRefresh()
        GameTooltip:Hide()
        if DFBindingTooltip then DFBindingTooltip:Hide(); DFBindingTooltip.anchorFrame = nil end
    end)

    -- ========================================
    -- CLICK-CAST REGISTRATION
    -- ========================================
    DF:RegisterFrameWithClickCast(frame)
    
    -- ========================================
    -- PING SUPPORT
    -- ========================================
    DF:RegisterFrameForPing(frame)
    
    return frame
end

-- ============================================================
-- PING SYSTEM SUPPORT
-- Makes frames pingable by using the PingableType_UnitFrameMixin
-- ============================================================

-- Function to register ping support on a frame (makes it pingable)
function DF:RegisterFrameForPing(frame)
    if not frame then return end
    
    -- Check if PingableType_UnitFrameMixin exists (retail/midnight)
    if PingableType_UnitFrameMixin then
        -- Mixin the pingable functionality
        Mixin(frame, PingableType_UnitFrameMixin)
        -- Set the ping-receiver attribute
        frame:SetAttribute("ping-receiver", true)
        
    end
end

-- ============================================================
