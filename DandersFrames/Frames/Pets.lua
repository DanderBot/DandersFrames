local addonName, DF = ...

-- ============================================================
-- PET FRAMES MODULE
-- Handles creation, positioning, and updates for pet frames
-- ============================================================

-- Storage for pet frames
DF.petFrames = DF.petFrames or {}
DF.partyPetFrames = DF.partyPetFrames or {}
DF.raidPetFrames = DF.raidPetFrames or {}
-- Arena pets are their own set, mirroring the separate arenaHeader. They CANNOT
-- share DF.raidPetFrames: those are anchored to the raid header's children, which
-- is a different (hidden) frame set in arena, and they carry isRaidFrame = true,
-- which would resolve their settings to the RAID config. See UpdateAllRaidPetFrames.
DF.arenaPetFrames = DF.arenaPetFrames or {}

-- Storage for test mode pet frames (non-secure, independent of live frames)
DF.testPetFrames = DF.testPetFrames or {}       -- [0]=player pet, [1-4]=party pets
DF.testRaidPetFrames = DF.testRaidPetFrames or {} -- [1-40]=raid pets

-- ============================================================
-- PET TRACK IDENTITY
-- ============================================================
-- ☠ THE ROOT FIX for pets resurrecting each other. Three live sets exist (party,
-- raid, arena) and exactly one may be drawn, but nothing could reliably say which
-- one owned the display:
--
--   * the unit token cannot say  — raid AND arena both use raidpet<N>
--   * isRaidFrame cannot say     — arena frames are deliberately isRaid = false so
--                                  their settings resolve to the PARTY config
--
-- So after a handover hid one set, that set's own UNIT_HEALTH / UNIT_FLAGS handler
-- re-showed it moments later. Field evidence from the retail lane, where this was
-- found: SetPetFrameVisible counts paired EXACTLY — pet 214 / raidpet1 214,
-- partypet1 161 / raidpet2 161. Four frames drawing two pets.
--
-- Every frame now carries the track it was born into, and every live path asks
-- whether that track is the active one.
local PET_TRACK_PARTY = "party"
local PET_TRACK_RAID  = "raid"
local PET_TRACK_ARENA = "arena"

-- ⚠ Test modes return their OWN pseudo-tracks, which no live frame can ever match.
-- Live pets keep their event registrations while a test runs, and without this they
-- re-show themselves on top of the preview.
local PET_TRACK_TEST_PARTY = "test-party"
local PET_TRACK_TEST_RAID  = "test-raid"

local activePetTrack, activePetTrackFrameTime

-- ☠ CACHED FOR ONE FRAME, and that is not a micro-optimisation. This sits on the
-- first line of the per-frame pet event handler, and the arena test resolves through
-- GetContentType() -> IsInInstance(), sometimes GetInstanceInfo(), PLUS a
-- SavedVariables write on every call. Uncached that is an instance query per unit
-- event per pet frame. GetTime() is constant within a frame, so keying on it needs
-- no invalidation at all.
function DF:ActivePetTrack()
    local now = GetTime()
    if activePetTrackFrameTime == now and activePetTrack then
        return activePetTrack
    end

    local track
    if DF.raidTestMode then
        track = PET_TRACK_TEST_RAID
    elseif DF.testMode then
        track = PET_TRACK_TEST_PARTY
    elseif DF.IsInArena and DF:IsInArena() then
        track = PET_TRACK_ARENA
    elseif IsInRaid() then
        track = PET_TRACK_RAID
    else
        track = PET_TRACK_PARTY
    end

    activePetTrack = track
    activePetTrackFrameTime = now
    return track
end

-- ☠ GATE ON THE TRACK NAME, never on `not partyTrack` or any other negation.
-- With the test pseudo-tracks above there are FIVE tracks, not two, so "not party"
-- is true in party test mode and real pet events start driving live secure frames.
-- For an arena frame it is worse than a stray show: arena frames are isRaid = false,
-- so UpdatePetFrame reads DF.testMode as *their* test flag and will fill a live
-- secure button with fake test health and force it visible.
function DF:PetFrameTrackActive(frame)
    if not frame then return false end
    -- A frame with no track predates this system or is a test frame; treat it as
    -- always-active rather than silently freezing it.
    if not frame.dfPetTrack then return true end
    return frame.dfPetTrack == DF:ActivePetTrack()
end

-- ============================================================
-- PET ANCHOR INVALIDATION
-- ============================================================
-- ☠ HUNG OFF UNIT REASSIGNMENT, NOT OFF SORTING. A pet anchor goes stale for exactly
-- one reason: the header moved its owner's unit to a different button. Hanging the
-- re-anchor off a *sorting entry point* looks equivalent and is not — the combat-end
-- drain deliberately skips DF:ProcessRosterUpdate when FrameSort is active (see
-- Frames/Headers.lua, the IsFrameSortActive check: FrameSort fires its own combat-end
-- sort, and our pass would reset nameList to INDEX and undo it, with non-deterministic
-- handler order between the two addons). Features/FrameSort.lua contains zero pet
-- references, so FrameSort users kept exactly the "pets under the wrong teammate" bug
-- the re-anchor exists to fix.
--
-- Every sorter finishes by moving units between buttons, so hooking the reassignment
-- covers our own arena sorting, FrameSort, Blizzard's default and anything added
-- later, without any of them needing to know pets exist.
local petAnchorFrame = CreateFrame("Frame")
petAnchorFrame:Hide()
petAnchorFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    if DF.UpdateAllPetFramePositions then DF:UpdateAllPetFramePositions() end
end)

-- Coalesced onto the next frame deliberately: a re-sort reassigns many children at
-- once and every one of them lands here, while the repositioning pass already walks
-- every pet frame. Reacting per child would be quadratic for one visible result.
-- Showing an already-shown frame is a no-op, so this dedups for free.
function DF:InvalidatePetAnchors()
    petAnchorFrame:Show()
end

-- ============================================================
-- PET FRAME CREATION
-- ============================================================

function DF:CreatePetFrame(unit, ownerFrame, isRaid, track)
    local db = isRaid and DF:GetRaidDB() or DF:GetDB()
    local parent = ownerFrame or (isRaid and DF.raidContainer or DF.container)

    -- Generate frame name based on unit
    -- ☠ ARENA NEEDS ITS OWN NAMESPACE. Arena pets use the same raidpet<N> tokens as
    -- the raid track, so both resolved to DandersFrames_Pet_raidPet<N> and whichever
    -- CreateFrame ran second silently took the global — two Lua frames, one name, and
    -- anything resolving by name got the wrong one. isRaid cannot disambiguate here
    -- either: arena frames pass isRaid = false on purpose (party config).
    local frameName
    if track == PET_TRACK_ARENA then
        frameName = "DandersFrames_ArenaPet_" .. unit:gsub("pet", "Pet")
    else
        frameName = "DandersFrames_Pet_" .. unit:gsub("pet", "Pet")
    end

    local frame = CreateFrame("Button", frameName, parent, "SecureUnitButtonTemplate,SecureHandlerEnterLeaveTemplate")
    frame:SetSize(db.petFrameWidth or 80, db.petFrameHeight or 20)
    frame.unit = unit
    frame.ownerFrame = ownerFrame
    frame.isPetFrame = true
    frame.isRaidFrame = isRaid
    -- Which of the three live sets this frame belongs to. Set once, at creation, and
    -- never recomputed — that is the whole point: it survives the fact that neither
    -- the unit token nor isRaidFrame can tell raid and arena apart.
    frame.dfPetTrack = track
    frame.dfIsDandersFrame = true  -- Mark as DandersFrames frame for click casting module
    
    -- Register unit attribute
    frame:SetAttribute("unit", unit)
    -- Note: type1/type2 are set by click-casting module (or RestoreBlizzardDefaults when disabled)
    
    -- Background
    frame.background = frame:CreateTexture(nil, "BACKGROUND")
    frame.background:SetAllPoints()
    frame.background:SetColorTexture(0.1, 0.1, 0.1, 0.8)
    
    -- Health bar
    frame.healthBar = CreateFrame("StatusBar", nil, frame)
    frame.healthBar:SetAllPoints()
    frame.healthBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    frame.healthBar:SetMinMaxValues(0, 100)
    frame.healthBar:SetValue(100)
    frame.healthBar:SetStatusBarColor(0, 0.8, 0)
    
    -- Health bar background (for deficit)
    frame.healthBar.bg = frame.healthBar:CreateTexture(nil, "BACKGROUND")
    frame.healthBar.bg:SetAllPoints()
    frame.healthBar.bg:SetColorTexture(0.2, 0.2, 0.2, 0.8)

    -- Power bar (optional). Hidden until enabled; ApplyPetFrameStyle anchors it as a
    -- bottom strip and shrinks the health bar to make room.
    frame.powerBar = CreateFrame("StatusBar", nil, frame)
    frame.powerBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    frame.powerBar:SetMinMaxValues(0, 100)
    frame.powerBar:SetValue(100)
    frame.powerBar:SetStatusBarColor(0.2, 0.4, 0.9)
    frame.powerBar.bg = frame.powerBar:CreateTexture(nil, "BACKGROUND")
    frame.powerBar.bg:SetAllPoints()
    frame.powerBar.bg:SetColorTexture(0.1, 0.1, 0.1, 0.8)
    frame.powerBar:Hide()
    
    -- Border via the unified DF.Border backend (Stage 4.3).
    -- ApplyPetFrameStyle drives BuildSpec + Apply on each update.
    frame.border = DF.Border:New(frame)
    
    -- Name text — do NOT use SetFont() directly; use SetFontObject so that
    -- later SafeSetFont calls with font families can properly override
    frame.nameText = frame.healthBar:CreateFontString(nil, "OVERLAY")
    frame.nameText:SetFontObject(GameFontNormal)
    frame.nameText:SetPoint("CENTER", 0, 0)
    frame.nameText:SetTextColor(1, 1, 1)
    frame.nameText:SetText("")

    -- Health text (optional, can be toggled) — same pattern: no direct SetFont()
    frame.healthText = frame.healthBar:CreateFontString(nil, "OVERLAY")
    frame.healthText:SetFontObject(GameFontNormal)
    frame.healthText:SetPoint("RIGHT", -2, 0)
    frame.healthText:SetTextColor(1, 1, 1)
    frame.healthText:SetText("")
    frame.healthText:Hide()
    
    -- Store owner unit for death checking
    local ownerUnit = unit:gsub("pet", "")
    if ownerUnit == "" then ownerUnit = "player" end
    frame.ownerUnit = ownerUnit
    
    -- Register events for this pet frame
    frame:SetScript("OnEvent", function(self, event, ...)
        DF:OnPetFrameEvent(self, event, ...)
    end)
    
    -- PERFORMANCE FIX 2025-01-20: Use RegisterUnitEvent for C++ level filtering
    -- Pet frames need to listen to both the pet unit AND the owner unit:
    -- - Pet unit: for health, name updates
    -- - Owner unit: for death detection (hide pet when owner dies) and UNIT_PET
    frame:RegisterUnitEvent("UNIT_HEALTH", unit, ownerUnit)  -- Need both pet and owner
    frame:RegisterUnitEvent("UNIT_MAXHEALTH", unit)          -- Pet only
    frame:RegisterUnitEvent("UNIT_NAME_UPDATE", unit)        -- Pet only
    frame:RegisterUnitEvent("UNIT_FLAGS", unit, ownerUnit)   -- Need both (death detection)
    frame:RegisterUnitEvent("UNIT_PET", ownerUnit)           -- Fires on owner when pet changes
    frame:RegisterUnitEvent("UNIT_POWER_UPDATE", unit)       -- Pet power (optional power bar)
    frame:RegisterUnitEvent("UNIT_MAXPOWER", unit)           -- Pet max power
    frame:RegisterUnitEvent("UNIT_DISPLAYPOWER", unit)       -- Pet power type change
    
    
    -- Mouse interaction - use HookScript to not interfere with other handlers
    frame:HookScript("OnEnter", function(self)
        if db.tooltipFrameEnabled then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetUnit(self.unit)
            GameTooltip:Show()
        end
    end)
    
    frame:HookScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)
    
    -- Ping support
    DF:RegisterFrameForPing(frame)
    
    -- Register with external click-casting addons (Clique, Clicked, etc.)
    DF:RegisterFrameWithClickCast(frame)
    
    -- Initial hide - will be shown when pet exists
    frame:Hide()
    
    return frame
end

-- ============================================================
-- TEST PET FRAME CREATION
-- Non-secure Button frames for test mode preview
-- ============================================================

function DF:CreateTestPetFrame(unit, ownerTestFrame, isRaid)
    local db = isRaid and DF:GetRaidDB() or DF:GetDB()
    local parent = ownerTestFrame or (isRaid and DF.testRaidContainer or DF.testPartyContainer)

    -- Generate frame name
    local frameName = "DandersFrames_TestPet_" .. unit:gsub("pet", "Pet")

    -- Create as regular Button (NOT SecureUnitButtonTemplate)
    -- This allows show/hide at any time without combat lockdown
    local frame = CreateFrame("Button", frameName, parent)
    frame:SetSize(db.petFrameWidth or 80, db.petFrameHeight or 20)
    frame.unit = unit
    frame.ownerFrame = ownerTestFrame
    frame.isPetFrame = true
    frame.isRaidFrame = isRaid
    frame.dfIsTestFrame = true
    frame.dfIsDandersFrame = true

    -- Store owner unit for consistency with live pet frames
    local ownerUnit = unit:gsub("pet", "")
    if ownerUnit == "" then ownerUnit = "player" end
    frame.ownerUnit = ownerUnit

    -- Background
    frame.background = frame:CreateTexture(nil, "BACKGROUND")
    frame.background:SetAllPoints()
    frame.background:SetColorTexture(0.1, 0.1, 0.1, 0.8)

    -- Health bar
    frame.healthBar = CreateFrame("StatusBar", nil, frame)
    frame.healthBar:SetAllPoints()
    frame.healthBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    frame.healthBar:SetMinMaxValues(0, 100)
    frame.healthBar:SetValue(100)
    frame.healthBar:SetStatusBarColor(0, 0.8, 0)

    -- Health bar background (for deficit)
    frame.healthBar.bg = frame.healthBar:CreateTexture(nil, "BACKGROUND")
    frame.healthBar.bg:SetAllPoints()
    frame.healthBar.bg:SetColorTexture(0.2, 0.2, 0.2, 0.8)

    -- Power bar (optional). Hidden until enabled; ApplyPetFrameStyle anchors it as a
    -- bottom strip and shrinks the health bar to make room.
    frame.powerBar = CreateFrame("StatusBar", nil, frame)
    frame.powerBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    frame.powerBar:SetMinMaxValues(0, 100)
    frame.powerBar:SetValue(100)
    frame.powerBar:SetStatusBarColor(0.2, 0.4, 0.9)
    frame.powerBar.bg = frame.powerBar:CreateTexture(nil, "BACKGROUND")
    frame.powerBar.bg:SetAllPoints()
    frame.powerBar.bg:SetColorTexture(0.1, 0.1, 0.1, 0.8)
    frame.powerBar:Hide()

    -- Border via the unified DF.Border backend (Stage 4.3).
    -- ApplyPetFrameStyle drives BuildSpec + Apply on each update.
    frame.border = DF.Border:New(frame)

    -- Name text — do NOT use SetFont() directly; use SafeSetFont or SetFontObject
    -- so that later SafeSetFont calls with font families can properly override
    frame.nameText = frame.healthBar:CreateFontString(nil, "OVERLAY")
    frame.nameText:SetFontObject(GameFontNormal)
    frame.nameText:SetPoint("CENTER", 0, 0)
    frame.nameText:SetTextColor(1, 1, 1)
    frame.nameText:SetText("")

    -- Health text (optional, can be toggled) — same pattern: no direct SetFont()
    frame.healthText = frame.healthBar:CreateFontString(nil, "OVERLAY")
    frame.healthText:SetFontObject(GameFontNormal)
    frame.healthText:SetPoint("RIGHT", -2, 0)
    frame.healthText:SetTextColor(1, 1, 1)
    frame.healthText:SetText("")
    frame.healthText:Hide()

    -- No events registered - test frames use fake data
    -- No click-casting registration - test frames aren't for real unit targeting

    -- Initial hide
    frame:Hide()

    return frame
end

-- ============================================================
-- TEST PET FRAME INITIALIZATION
-- ============================================================

function DF:InitializeTestPetFrames()
    -- Create test pet frames for each test party frame
    for i = 0, 4 do
        if not DF.testPetFrames[i] and DF.testPartyFrames[i] then
            local unit = i == 0 and "pet" or ("partypet" .. i)
            DF.testPetFrames[i] = DF:CreateTestPetFrame(unit, DF.testPartyFrames[i], false)
        end
    end
end

function DF:InitializeTestRaidPetFrames()
    -- Create test pet frames for each test raid frame
    for i = 1, 40 do
        if not DF.testRaidPetFrames[i] and DF.testRaidFrames[i] then
            DF.testRaidPetFrames[i] = DF:CreateTestPetFrame("raidpet" .. i, DF.testRaidFrames[i], true)
        end
    end
end

-- ============================================================
-- TEST PET FRAME CLEANUP
-- ============================================================

function DF:HideAllTestPetFrames()
    for i = 0, 4 do
        if DF.testPetFrames[i] then DF.testPetFrames[i]:Hide() end
    end
    -- Also hide pet group container if it exists
    DF:HidePetGroupContainer(DF.petGroupContainer)
end

function DF:HideAllTestRaidPetFrames()
    for i = 1, 40 do
        if DF.testRaidPetFrames[i] then DF.testRaidPetFrames[i]:Hide() end
    end
    DF:HidePetGroupContainer(DF.raidPetGroupContainer)
end

-- ============================================================
-- PET FRAME EVENTS
-- ============================================================

function DF:OnPetFrameEvent(frame, event, unit, ...)
    -- ☠ THE GATE. Every branch below can call SetPetFrameVisible(frame, true), and a
    -- frame belonging to a set that is NOT currently on screen doing that is exactly
    -- how the three tracks resurrected each other: a handover hid one set, then its
    -- own UNIT_HEALTH / UNIT_FLAGS arrived a moment later and showed it straight back.
    -- The frames keep their event registrations through a handover by design (so they
    -- are current when their track next becomes active), which is why the gate has to
    -- be here rather than in the registration.
    --
    -- One line, first thing, and no negations -- see PetFrameTrackActive for why
    -- `not partyTrack` is a trap rather than a shortcut.
    if not DF:PetFrameTrackActive(frame) then return end

    -- Handle UNIT_PET event (fires on owner unit when pet changes)
    if event == "UNIT_PET" then
        if unit == frame.ownerUnit then
            -- Owner's pet changed - update visibility
            if UnitExists(frame.unit) and not UnitIsDeadOrGhost(frame.ownerUnit) then
                DF:SetPetFrameVisible(frame, true)
                DF:UpdatePetHealth(frame)
                DF:UpdatePetName(frame)
            else
                DF:SetPetFrameVisible(frame, false)
            end
        end
        return
    end
    
    -- Check for owner unit events (for death detection)
    if unit == frame.ownerUnit then
        if event == "UNIT_HEALTH" or event == "UNIT_FLAGS" then
            -- Check if owner died - hide pet frame
            if UnitIsDeadOrGhost(frame.ownerUnit) then
                DF:SetPetFrameVisible(frame, false)
            else
                -- Owner alive, check if pet exists
                if UnitExists(frame.unit) then
                    DF:SetPetFrameVisible(frame, true)
                    DF:UpdatePetHealth(frame)
                end
            end
        end
        return
    end
    
    -- Handle pet unit events
    if unit ~= frame.unit then return end
    
    if event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        DF:UpdatePetHealth(frame)
    elseif event == "UNIT_POWER_UPDATE" or event == "UNIT_MAXPOWER" or event == "UNIT_DISPLAYPOWER" then
        DF:UpdatePetPower(frame)
    elseif event == "UNIT_NAME_UPDATE" then
        DF:UpdatePetName(frame)
    elseif event == "UNIT_FLAGS" then
        -- Pet may have been dismissed or died
        if not UnitExists(frame.unit) then
            DF:SetPetFrameVisible(frame, false)
        end
    end
end

-- ============================================================
-- PET FRAME UPDATES
-- ============================================================

-- Combat-safe hide for a pet GROUP CONTAINER. In GROUPED mode the secure pet
-- buttons are re-parented onto the container, so a raw :Hide() on it can be a
-- protected action mid-combat (blocked -> error). The child buttons already drop
-- to alpha 0 via SetPetFrameVisible, so skipping the container :Hide() in combat
-- leaves nothing visible; the real hide lands on the next out-of-combat update.
function DF:HidePetGroupContainer(container)
    if container and not InCombatLockdown() then container:Hide() end
end

-- Helper to set pet frame visibility (uses SetAlpha to work in combat)
-- Note: When showing, we don't set alpha to 1 because range fading may need a different alpha
function DF:SetPetFrameVisible(frame, visible)
    if not frame then return end

    -- Never show a pet when the feature is disabled for this mode. Pet/owner
    -- UNIT_HEALTH events route through here and would otherwise re-show a pet
    -- that was just toggled off, until a /reload.
    if visible then
        local db = DF:GetFrameDB(frame)
        if not (db and db.petEnabled) then
            visible = false
        end
    end

    if visible then
        -- Mark as visible - range system will set appropriate alpha
        frame.dfPetHidden = false
        -- Set to 1 so range system can take over (don't compare current alpha - it may be secret)
        frame:SetAlpha(1)
        -- Also try to show if not in combat (for proper click targeting)
        if not InCombatLockdown() then
            frame:Show()
        else
            DF:Debug("PET", "SetPetFrameVisible: %s wants SHOW but InCombatLockdown - using alpha only", frame.unit or "?")
        end
    else
        -- Mark as hidden and set alpha to 0
        frame.dfPetHidden = true
        frame:SetAlpha(0)
        -- Also try to hide if not in combat
        if not InCombatLockdown() then
            frame:Hide()
        end
    end

    -- ☠ Under lockdown only the alpha above actually took, so the Shown state is now
    -- wrong in BOTH directions: a pet that died mid-fight is left as an invisible but
    -- still CLICKABLE button, and one summoned mid-fight is left Hidden with alpha 1
    -- (so it stays invisible even once combat ends). Neither self-corrects — nothing
    -- re-runs this until the next roster or pet event, which may never come.
    --
    -- Arena had a deferral for its own pass; this covers every track, per frame.
    if InCombatLockdown() then
        DF.pendingPetVisibilityUpdate = true
    end
end

function DF:UpdatePetHealth(frame)
    if not frame or not frame.unit then return end
    
    local unit = frame.unit
    local db = DF:GetFrameDB(frame)
    
    -- Check if pet exists
    if not UnitExists(unit) then 
        DF:SetPetFrameVisible(frame, false)
        return 
    end
    
    -- Check if owner is dead - hide pet frame if so
    local ownerUnit = unit:gsub("pet", "")
    if ownerUnit == "" then ownerUnit = "player" end
    if UnitIsDeadOrGhost(ownerUnit) then
        DF:SetPetFrameVisible(frame, false)
        return
    end
    
    -- Pet exists and owner is alive - show frame
    DF:SetPetFrameVisible(frame, true)
    
    -- Use the safe SetHealthBarValue function which handles secrets properly
    DF.SetHealthBarValue(frame.healthBar, unit, frame)
    
    -- Update health text if shown
    -- Pass secret value directly to SetFormattedText - it handles secrets internally
    -- TD legacy-text suppression: when ON, force pet health text hidden.
    local hideLegacyText = DF:IsLegacyTextHidden(frame)
    if db.petShowHealthText and frame.healthText and not hideLegacyText then
        local success = pcall(function()
            local pct = DF.GetSafeHealthPercent(unit)
            frame.healthText:SetFormattedText("%.0f%%", pct)
        end)
        if not success then
            frame.healthText:SetText("")
        end
        frame.healthText:Show()
    elseif frame.healthText then
        frame.healthText:Hide()
    end

    if DF.UpdateTextDesigner then DF:UpdateTextDesigner(frame, "health") end

    -- Color health bar based on settings
    if db.petHealthColorMode == "CLASS" then
        -- Try to get pet owner's class color
        local _, class = UnitClass(ownerUnit)
        if class then
            local color = DF:GetClassColor(class)
            if color then
                frame.healthBar:SetStatusBarColor(color.r, color.g, color.b)
                return
            end
        end
    elseif db.petHealthColorMode == "HEALTH" then
        -- Use gradient curve to get color based on health percentage
        -- UnitHealthPercent with a color curve returns the color directly
        local curve = DF:GetPetHealthGradientCurve()
        if curve then
            local success = pcall(function()
                local color = UnitHealthPercent(unit, true, curve)
                if color and color.GetRGB then
                    local tex = frame.healthBar:GetStatusBarTexture()
                    if tex then
                        tex:SetVertexColor(color:GetRGB())
                    end
                end
            end)
            if success then
                return
            end
        end
        -- Fallback if curve not available or failed - just use green
        frame.healthBar:SetStatusBarColor(0, 0.8, 0)
        return
    elseif db.petHealthColorMode == "CUSTOM" then
        local c = db.petHealthColor or {r = 0, g = 0.8, b = 0}
        frame.healthBar:SetStatusBarColor(c.r, c.g, c.b)
        return
    end
    
    -- Default green
    frame.healthBar:SetStatusBarColor(0, 0.8, 0)
end

-- Get or create a health gradient curve for pet frames
function DF:GetPetHealthGradientCurve()
    if not DF.petHealthCurve then
        -- Create a simple red-yellow-green gradient curve using C_CurveUtil
        if C_CurveUtil and C_CurveUtil.CreateColorCurve then
            local curve = C_CurveUtil.CreateColorCurve()
            curve:SetType(Enum.LuaCurveType.Linear)
            
            -- Add color points: red at 0%, yellow at 50%, green at 100%
            local red = CreateColor(1, 0, 0, 1)
            local yellow = CreateColor(1, 0.8, 0, 1)
            local green = CreateColor(0, 0.8, 0, 1)
            
            curve:AddPoint(0, red)
            curve:AddPoint(0.5, yellow)
            curve:AddPoint(1, green)
            
            DF.petHealthCurve = curve
        end
    end
    return DF.petHealthCurve
end

-- Resolve the pet power bar colour: by the pet's power type (default) or a custom colour.
function DF:GetPetPowerColor(unit, db)
    if db.petPowerColorMode == "CUSTOM" then
        local c = db.petPowerColor or {r = 0.2, g = 0.4, b = 0.9}
        return c.r, c.g, c.b
    end
    -- POWER: colour by the pet's current power type (mana blue / energy yellow / etc.)
    local _, token = UnitPowerType(unit)
    local c = token and PowerBarColor and PowerBarColor[token]
    if c then return c.r, c.g, c.b end
    return 0.2, 0.4, 0.9  -- fallback when the power type has no defined colour
end

-- Update the pet power bar value + colour. Mirrors the main frame's UpdatePower:
-- guards against secret values (instanced content) by hiding rather than erroring.
function DF:UpdatePetPower(frame)
    if not frame or not frame.unit or not frame.powerBar then return end

    local db = DF:GetFrameDB(frame)
    if not db.petShowPowerBar then
        frame.powerBar:Hide()
        return
    end

    local unit = frame.unit
    if not UnitExists(unit) then
        frame.powerBar:Hide()
        return
    end

    local power = UnitPower(unit)
    local maxPower = UnitPowerMax(unit)

    -- Secret-value guard: UnitPower/UnitPowerMax return secret numbers in instanced
    -- content. NEVER compare or do arithmetic on them in Lua (that taints) — pass them
    -- straight to the StatusBar, which accepts secret values. type() is safe and still
    -- catches genuine non-numbers (e.g. nil when the unit briefly doesn't exist).
    if type(power) ~= "number" or type(maxPower) ~= "number" then
        frame.powerBar:Hide()
        return
    end

    frame.powerBar:SetMinMaxValues(0, maxPower)
    frame.powerBar:SetValue(power)

    local r, g, b = DF:GetPetPowerColor(unit, db)
    frame.powerBar:SetStatusBarColor(r, g, b, 1)
    frame.powerBar:Show()
end

-- Apply visual styling to pet frame
function DF:ApplyPetFrameStyle(frame)
    if not frame then return end
    if InCombatLockdown() then return end

    local db = DF:GetFrameDB(frame)

    -- Calculate size - optionally match owner's dimensions (only in ATTACHED mode)
    local width = db.petFrameWidth or 80
    local height = db.petFrameHeight or 20
    
    -- Match Owner Width/Height only applies in ATTACHED mode, not GROUPED mode
    local isGroupedMode = db.petGroupMode == "GROUPED"
    
    if not isGroupedMode and frame.ownerFrame then
        if db.petMatchOwnerWidth then
            width = frame.ownerFrame:GetWidth()
        end
        if db.petMatchOwnerHeight then
            height = frame.ownerFrame:GetHeight()
        end
    end
    
    frame:SetSize(width, height)
    
    -- Update health bar texture - use path directly (dropdown saves paths)
    local texture = db.petTexture or "Interface\\TargetingFrame\\UI-StatusBar"
    DF:SafeSetStatusBarTexture(frame.healthBar, texture)
    DF:SafeSetTexture(frame.healthBar.bg, texture)
    
    -- Background color
    local bgColor = db.petBackgroundColor or {r = 0.1, g = 0.1, b = 0.1, a = 0.8}
    frame.background:SetColorTexture(bgColor.r, bgColor.g, bgColor.b, bgColor.a or 0.8)
    
    -- Health bar background color
    local healthBgColor = db.petHealthBgColor or {r = 0.2, g = 0.2, b = 0.2, a = 0.8}
    frame.healthBar.bg:SetVertexColor(healthBgColor.r, healthBgColor.g, healthBgColor.b, healthBgColor.a or 0.8)

    -- Power bar layout: when enabled, reserve a bottom strip for it and shrink the
    -- health bar to match; otherwise the health bar fills the frame and power is hidden.
    if frame.powerBar then
        frame.healthBar:ClearAllPoints()
        if db.petShowPowerBar then
            local powerHeight = db.petPowerBarHeight or 4
            frame.healthBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
            frame.healthBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, powerHeight)
            frame.powerBar:ClearAllPoints()
            frame.powerBar:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, powerHeight)
            frame.powerBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
            DF:SafeSetStatusBarTexture(frame.powerBar, texture)
            DF:SafeSetTexture(frame.powerBar.bg, texture)
            frame.powerBar:Show()
        else
            frame.healthBar:SetAllPoints(frame)
            frame.powerBar:Hide()
        end
    end

    -- Border via unified DF.Border backend (Stage 4.3). No ctx — Class /
    -- Role colour deliberately not exposed on Pet Frame: UnitClass("pet")
    -- returns the pet family (Beast / Felguard / etc.), not a class token
    -- that maps to RAID_CLASS_COLORS, so the resolver wouldn't produce a
    -- useful colour. Re-visit only if a per-class-of-owner feature
    -- becomes worth its own resolver.
    if frame.border then
        DF.Border:Apply(frame.border, DF.Border:BuildSpec(db, "pet"))
    end
    
    -- Name text styling - use SafeSetFont like main frames
    local nameFont = db.petNameFont or "Fonts\\FRIZQT__.TTF"
    local nameFontSize = db.petNameFontSize or 9
    local nameFontOutline = db.petNameFontOutline or "OUTLINE"
    DF:SafeSetFont(frame.nameText, nameFont, nameFontSize, nameFontOutline)

    -- Name text position
    frame.nameText:ClearAllPoints()
    local nameAnchor = db.petNameAnchor or "CENTER"
    local nameX = db.petNameX or 0
    local nameY = db.petNameY or 0
    frame.nameText:SetPoint(nameAnchor, frame.healthBar, nameAnchor, nameX, nameY)
    
    -- Name text color
    local nameColor = db.petNameColor or {r = 1, g = 1, b = 1}
    frame.nameText:SetTextColor(nameColor.r, nameColor.g, nameColor.b)
    
    -- Health text styling
    if frame.healthText then
        local healthFont = db.petHealthFont or "Fonts\\ARIALN.TTF"
        local healthFontSize = db.petHealthFontSize or 8
        local healthFontOutline = db.petHealthFontOutline or "OUTLINE"
        DF:SafeSetFont(frame.healthText, healthFont, healthFontSize, healthFontOutline)
        
        -- Health text position
        frame.healthText:ClearAllPoints()
        local healthAnchor = db.petHealthAnchor or "RIGHT"
        local healthX = db.petHealthX or -2
        local healthY = db.petHealthY or 0
        frame.healthText:SetPoint(healthAnchor, frame.healthBar, healthAnchor, healthX, healthY)
        
        -- Health text color
        local healthColor = db.petHealthTextColor or {r = 1, g = 1, b = 1}
        frame.healthText:SetTextColor(healthColor.r, healthColor.g, healthColor.b)
    end
end

function DF:UpdatePetName(frame)
    if not frame or not frame.unit then return end
    if not UnitExists(frame.unit) then return end

    -- TD legacy-text suppression: when ON, hide pet name and skip.
    if DF:IsLegacyTextHidden(frame) then
        if frame.nameText then frame.nameText:Hide() end
        return
    elseif frame.nameText and not frame.nameText:IsShown() then
        frame.nameText:Show()
    end

    local name = GetUnitName(frame.unit, true)
    if name then
        -- Truncate long names. Use secret-value-safe UTF-8 helpers — GetUnitName
        -- can return a secret string in instanced content (delves, encounters).
        -- DF:UTF8Len returns 0 for secret values so the truncation branch
        -- no-ops, and SetText receives the secret string directly (FontStrings
        -- accept secret values; only Lua string ops on them cause errors).
        local db = DF:GetFrameDB(frame)
        local maxLen = db.petNameMaxLength or 12
        if maxLen > 0 and DF:UTF8Len(name) > maxLen then
            name = DF:UTF8Sub(name, 1, maxLen) .. "..."
        end
        frame.nameText:SetText(name)
    end

    if DF.UpdateTextDesigner then DF:UpdateTextDesigner(frame, "name") end
end

function DF:UpdatePetFrame(frame)
    if not frame then return end

    local db = DF:GetFrameDB(frame)

    -- Check if owner is dead - hide pet frame if so
    local ownerUnit = frame.unit:gsub("pet", "")
    if ownerUnit == "" then ownerUnit = "player" end

    -- Test mode handling
    local isInTestMode = (frame.isRaidFrame and DF.raidTestMode) or (not frame.isRaidFrame and DF.testMode)

    if isInTestMode then
        -- Check if pets should be shown in test mode
        if db.testShowPets == false then
            DF:Debug("PET", "UpdatePetFrame: %s HIDDEN (testShowPets=false)", frame.unit)
            DF:SetPetFrameVisible(frame, false)
            return
        end
        -- In test mode, show pet frames with fake data
        DF:ApplyPetFrameStyle(frame)
        DF:UpdatePetFrameTestMode(frame)
        DF:SetPetFrameVisible(frame, true)
        return
    end

    -- Update visibility and data
    local unitExists = UnitExists(frame.unit)
    local ownerDead = UnitIsDeadOrGhost(ownerUnit)
    local shouldShow = unitExists and not ownerDead
    if shouldShow then
        -- Apply visual styling
        DF:ApplyPetFrameStyle(frame)
        -- Update health and name
        DF:UpdatePetHealth(frame)
        DF:UpdatePetName(frame)
        DF:UpdatePetPower(frame)
        DF:SetPetFrameVisible(frame, true)
    else
        DF:SetPetFrameVisible(frame, false)
    end

    -- Edge-triggered: both arms used to log unconditionally, so every pet frame
    -- reported its visibility on every roster/pet event whether or not it moved.
    if frame.dfLastPetVisible ~= shouldShow then
        frame.dfLastPetVisible = shouldShow
        DF:Debug("PET", "UpdatePetFrame: %s %s (unitExists=%s ownerDead=%s)",
            tostring(frame.unit), shouldShow and "VISIBLE" or "HIDDEN",
            tostring(unitExists), tostring(ownerDead))
    end
end

-- Update pet frame with test mode fake data
function DF:UpdatePetFrameTestMode(frame)
    if not frame then return end

    -- TD legacy-text suppression for pet test frames.
    local hideLegacyText = DF:IsLegacyTextHidden(frame)

    -- Set fake name
    local petNames = {"Wolf", "Cat", "Bear", "Imp", "Voidwalker", "Felguard", "Water Elemental", "Ghoul", "Treant", "Earth Elemental"}
    local index = 1
    if frame.unit:match("partypet(%d+)") then
        index = tonumber(frame.unit:match("partypet(%d+)")) or 1
    elseif frame.unit:match("raidpet(%d+)") then
        index = tonumber(frame.unit:match("raidpet(%d+)")) or 1
    end
    local name = petNames[((index - 1) % #petNames) + 1]
    if frame.nameText then
        if hideLegacyText then
            frame.nameText:Hide()
        else
            frame.nameText:SetText(name)
            frame.nameText:Show()
        end
    end

    -- Set fake health (random between 60-100%)
    local healthPercent = 0.6 + (math.random() * 0.4)
    frame.healthBar:SetMinMaxValues(0, 1)
    frame.healthBar:SetValue(healthPercent)

    -- Set health bar color (green)
    frame.healthBar:SetStatusBarColor(0.2, 0.8, 0.2)

    -- Fake power bar (geometry/visibility already set by ApplyPetFrameStyle)
    if frame.powerBar then
        local db = DF:GetFrameDB(frame)
        if db.petShowPowerBar then
            local powerPercent = 0.4 + (math.random() * 0.6)
            frame.powerBar:SetMinMaxValues(0, 1)
            frame.powerBar:SetValue(powerPercent)
            local r, g, b = DF:GetPetPowerColor(frame.unit, db)
            frame.powerBar:SetStatusBarColor(r, g, b)
            frame.powerBar:Show()
        else
            frame.powerBar:Hide()
        end
    end

    -- Update health text if shown
    if frame.healthText then
        local db = DF:GetFrameDB(frame)
        if db.petShowHealthText and not hideLegacyText then
            -- (Removed) a hardcoded `maxHealth = 50000` and the currentHealth it fed.
            -- Nothing consumed either — pet health text is a percentage.
            frame.healthText:SetText(string.format("%d%%", math.floor(healthPercent * 100)))
            frame.healthText:Show()
        else
            frame.healthText:Hide()
        end
    end
end

-- Lightweight update for live slider preview (no full rebuild)
function DF:LightweightUpdatePetFrames()
    -- Test mode: update test pet frames
    if DF.testMode then
        for i = 0, 4 do
            if DF.testPetFrames[i] then
                DF:ApplyPetFrameStyle(DF.testPetFrames[i])
                DF:PositionPetFrame(DF.testPetFrames[i])
            end
        end
    elseif DF:ActivePetTrack() == PET_TRACK_PARTY then
        -- ☠ ONLY WHEN PARTY IS THE ACTIVE TRACK. PositionPetFrame re-resolves the owner
        -- through GetFrameForUnit, which is arena-aware, so restyling the party set
        -- while an arena is on screen re-parents it onto the arena header. This is the
        -- slider path — every pet option change comes through here — which is why
        -- touching any pet slider in an arena used to drag the party pets into it.
        if DF.petFrames.player then
            DF:ApplyPetFrameStyle(DF.petFrames.player)
            DF:PositionPetFrame(DF.petFrames.player)
        end
        for i = 1, 4 do
            if DF.partyPetFrames[i] then
                DF:ApplyPetFrameStyle(DF.partyPetFrames[i])
                DF:PositionPetFrame(DF.partyPetFrames[i])
            end
        end
    end

    -- Raid test mode: update test raid pet frames
    if DF.raidTestMode then
        for i = 1, 40 do
            if DF.testRaidPetFrames[i] then
                DF:ApplyPetFrameStyle(DF.testRaidPetFrames[i])
                DF:PositionPetFrame(DF.testRaidPetFrames[i])
            end
        end
    else
        -- ☠ ONE TRACK AT A TIME. This used to walk raidPetFrames AND arenaPetFrames
        -- unconditionally, which meant that in an arena the hidden raid set was
        -- restyled and repositioned too -- and PositionPetFrame re-resolves the owner
        -- through the arena-aware GetFrameForUnit, so it did not just waste work, it
        -- re-parented the raid pets onto the arena header. That is the whole "dragging
        -- a pet slider in an arena dragged the raid pets onto the arena frames" bug.
        local track = DF:ActivePetTrack()

        -- Live mode: update real raid pet frames
        if track == PET_TRACK_RAID then
            for i = 1, 40 do
                if DF.raidPetFrames[i] then
                    DF:ApplyPetFrameStyle(DF.raidPetFrames[i])
                    DF:PositionPetFrame(DF.raidPetFrames[i])
                end
            end
        end

        -- Arena pets are a separate set (see UpdateAllRaidPetFrames); without this
        -- they would keep their creation-time look and ignore every settings change.
        if track == PET_TRACK_ARENA then
            for i = 1, 5 do
                if DF.arenaPetFrames[i] then
                    DF:ApplyPetFrameStyle(DF.arenaPetFrames[i])
                    DF:PositionPetFrame(DF.arenaPetFrames[i])
                end
            end
        end
    end
end

-- ============================================================
-- PET FRAME POSITIONING
-- ============================================================

function DF:PositionPetFrame(frame)
    if not frame then return end

    -- ☠ GUARDED AT THE FUNCTION, not at each caller. This does ClearAllPoints /
    -- SetParent / SetPoint on a SecureUnitButtonTemplate, all blocked under lockdown,
    -- and it is reachable mid-fight from at least three directions: the secure-sort
    -- completion callback (SecureSort -> NotifySortComplete -> UpdateAllPetFramePositions),
    -- the Options sliders, which are usable in combat, and UNIT_PET. Guarding the
    -- callers instead leaves the next new caller to rediscover this.
    --
    -- ⚠ Test frames are NOT secure and must keep positioning normally -- test mode is
    -- routinely entered and left with the lockdown up.
    if not frame.dfIsTestFrame and InCombatLockdown() then
        DF.pendingPetPositionUpdate = true
        return
    end

    local db = DF:GetFrameDB(frame)

    -- Check if we're using grouped mode
    if db.petGroupMode == "GROUPED" then
        -- In grouped mode, positioning is handled by UpdatePetGroupLayout
        return
    end
    
    -- ATTACHED mode - position relative to owner.
    -- Re-resolve the current owner frame: custom sorting reassigns unit tokens
    -- to different buttons, so the frame captured at pet creation can be stale.
    -- Anchor to whichever frame currently shows the owner unit. (Test mode keeps
    -- its dedicated test owner frame.)
    if not (DF.testMode or DF.raidTestMode) and frame.ownerUnit and DF.GetFrameForUnit then
        frame.ownerFrame = DF:GetFrameForUnit(frame.ownerUnit) or frame.ownerFrame
    end
    if not frame.ownerFrame then return end

    local anchor = db.petAnchor or "BOTTOM"
    local offsetX = db.petOffsetX or 0
    local offsetY = db.petOffsetY or -2
    
    frame:ClearAllPoints()
    frame:SetParent(frame.ownerFrame:GetParent())
    
    if anchor == "BOTTOM" then
        frame:SetPoint("TOP", frame.ownerFrame, "BOTTOM", offsetX, offsetY)
    elseif anchor == "TOP" then
        frame:SetPoint("BOTTOM", frame.ownerFrame, "TOP", offsetX, -offsetY)
    elseif anchor == "LEFT" then
        frame:SetPoint("RIGHT", frame.ownerFrame, "LEFT", offsetX, offsetY)
    elseif anchor == "RIGHT" then
        frame:SetPoint("LEFT", frame.ownerFrame, "RIGHT", offsetX, offsetY)
    end
end

-- ============================================================
-- PET GROUP CONTAINER (Party Mode)
-- ============================================================

function DF:CreatePetGroupContainer()
    if DF.petGroupContainer then return DF.petGroupContainer end
    
    local container = CreateFrame("Frame", "DandersFrames_PetGroupContainer", UIParent)
    container:SetSize(200, 50)
    container:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
    container:Hide()
    
    DF.petGroupContainer = container
    return container
end

function DF:UpdatePetGroupLayout()
    local db = DF:GetDB()
    local isTestMode = DF.testMode

    -- Only use group layout if in GROUPED mode and pets are enabled/shown
    local petsEnabled = isTestMode and (db.petEnabled and db.testShowPets ~= false) or (not isTestMode and db.petEnabled)
    if db.petGroupMode ~= "GROUPED" or not petsEnabled then
        DF:HidePetGroupContainer(DF.petGroupContainer)
        return
    end

    -- ☠ GUARDS ITSELF. PositionPetFrame's guard provably cannot cover this path: it
    -- returns early for GROUPED by design, so grouped layout is the one arrangement
    -- whose SetParent / SetPoint calls never pass through it. Test frames are not
    -- secure, so only the live pass needs holding back.
    if not isTestMode and InCombatLockdown() then
        DF.pendingPetPositionUpdate = true
        return
    end

    -- Create container if needed
    if not DF.petGroupContainer then
        DF:CreatePetGroupContainer()
    end

    local container = DF.petGroupContainer

    -- In live mode, need a party container reference
    if not isTestMode and not DF.container then return end

    -- Collect visible pet frames
    local petFrames = {}
    local testFrameCount = db.testFrameCount or 5

    if isTestMode then
        -- Test mode: use test pet frames
        if testFrameCount >= 1 and DF.testPetFrames[0] then
            table.insert(petFrames, DF.testPetFrames[0])
        end
        for i = 1, 4 do
            if (i + 1) <= testFrameCount and DF.testPetFrames[i] then
                table.insert(petFrames, DF.testPetFrames[i])
            end
        end
    elseif DF.IsInArena and DF:IsInArena() then
        -- Arena: the team is raid-kind, so the pets are raidpet* on the arena
        -- header's frames — partypet* does not exist here and collecting it would
        -- leave the group empty. The container itself is fine: the arena header is
        -- parented to DF.partyContainer, which this layout already anchors against.
        -- (Grouped arena pets read the party config for the same reason the
        -- attached ones do — see UpdateArenaPetFrames.)
        for i = 1, 5 do
            if DF.arenaPetFrames[i] and UnitExists("raidpet" .. i) then
                table.insert(petFrames, DF.arenaPetFrames[i])
            end
        end
    else
        -- Normal mode - check which pets actually exist
        if DF.petFrames.player and UnitExists("pet") then
            table.insert(petFrames, DF.petFrames.player)
        end
        for i = 1, 4 do
            if DF.partyPetFrames[i] and UnitExists("partypet" .. i) then
                table.insert(petFrames, DF.partyPetFrames[i])
            end
        end
    end

    if #petFrames == 0 then
        DF:HidePetGroupContainer(container)
        return
    end

    -- Get settings
    local growth = db.petGroupGrowth or "HORIZONTAL"
    local spacing = db.petGroupSpacing or 2
    local anchor = db.petGroupAnchor or "BOTTOM"
    local offsetX = db.petGroupOffsetX or 0
    local offsetY = db.petGroupOffsetY or -5

    -- Calculate container size using pet frame dimensions
    local petWidth = db.petFrameWidth or 80
    local petHeight = db.petFrameHeight or 18

    local containerWidth, containerHeight

    if growth == "HORIZONTAL" then
        containerWidth = (#petFrames * petWidth) + ((#petFrames - 1) * spacing)
        containerHeight = petHeight
    else
        containerWidth = petWidth
        containerHeight = (#petFrames * petHeight) + ((#petFrames - 1) * spacing)
    end

    container:SetSize(containerWidth, containerHeight)

    -- Calculate the actual center of visible party frames
    local visibleFrames = {}

    if isTestMode then
        -- Test mode: iterate test party frames directly
        for i = 0, 4 do
            local frame = DF.testPartyFrames[i]
            if frame and frame:IsShown() and (i < testFrameCount) then
                table.insert(visibleFrames, frame)
            end
        end
    elseif DF.IteratePartyFrames then
        -- Live mode: use the iterator
        DF:IteratePartyFrames(function(frame)
            if frame and frame:IsShown() then
                table.insert(visibleFrames, frame)
            end
        end)
    end
    
    -- Position container relative to party frames
    container:ClearAllPoints()
    
    if #visibleFrames > 0 then
        local partyGrowth = db.growDirection or "HORIZONTAL"
        
        -- Find the actual bounds of all visible party frames using GetRect
        -- This handles frame sorting correctly - find actual leftmost/rightmost frames
        local minX, maxX, minY, maxY
        local leftmostFrame, rightmostFrame, topmostFrame, bottommostFrame
        
        for _, frame in ipairs(visibleFrames) do
            local left, bottom, width, height = frame:GetRect()
            if left and bottom and width and height then
                local right = left + width
                local top = bottom + height
                
                if not minX or left < minX then 
                    minX = left 
                    leftmostFrame = frame
                end
                if not maxX or right > maxX then 
                    maxX = right 
                    rightmostFrame = frame
                end
                if not minY or bottom < minY then 
                    minY = bottom 
                    bottommostFrame = frame
                end
                if not maxY or top > maxY then 
                    maxY = top 
                    topmostFrame = frame
                end
            end
        end
        
        if minX and maxX and minY and maxY and leftmostFrame then
            local totalPartyWidth = maxX - minX
            local totalPartyHeight = maxY - minY
            
            -- Calculate centering offset
            local centerOffsetX = (totalPartyWidth - containerWidth) / 2
            local centerOffsetY = (totalPartyHeight - containerHeight) / 2
            
            -- Position based on anchor - use the appropriate edge frame
            if anchor == "BOTTOM" then
                if partyGrowth == "HORIZONTAL" then
                    container:SetPoint("TOPLEFT", leftmostFrame, "BOTTOMLEFT", centerOffsetX + offsetX, offsetY)
                else
                    container:SetPoint("TOP", bottommostFrame, "BOTTOM", offsetX, offsetY)
                end
            elseif anchor == "TOP" then
                if partyGrowth == "HORIZONTAL" then
                    container:SetPoint("BOTTOMLEFT", leftmostFrame, "TOPLEFT", centerOffsetX + offsetX, -offsetY)
                else
                    container:SetPoint("BOTTOM", topmostFrame, "TOP", offsetX, -offsetY)
                end
            elseif anchor == "LEFT" then
                if partyGrowth == "HORIZONTAL" then
                    container:SetPoint("RIGHT", leftmostFrame, "LEFT", offsetX, offsetY)
                else
                    container:SetPoint("TOPRIGHT", topmostFrame, "TOPLEFT", offsetX, -centerOffsetY + offsetY)
                end
            elseif anchor == "RIGHT" then
                if partyGrowth == "HORIZONTAL" then
                    container:SetPoint("LEFT", rightmostFrame, "RIGHT", offsetX, offsetY)
                else
                    container:SetPoint("TOPLEFT", topmostFrame, "TOPRIGHT", offsetX, -centerOffsetY + offsetY)
                end
            end
            
            container:Show()
            
            -- Position pet frames within container
            for i, frame in ipairs(petFrames) do
                frame:ClearAllPoints()
                frame:SetParent(container)
                
                if i == 1 then
                    if growth == "HORIZONTAL" then
                        frame:SetPoint("LEFT", container, "LEFT", 0, 0)
                    else
                        frame:SetPoint("TOP", container, "TOP", 0, 0)
                    end
                else
                    local prevFrame = petFrames[i - 1]
                    if growth == "HORIZONTAL" then
                        frame:SetPoint("LEFT", prevFrame, "RIGHT", spacing, 0)
                    else
                        frame:SetPoint("TOP", prevFrame, "BOTTOM", 0, -spacing)
                    end
                end
            end
            return
        end
    end
    
    -- Fallback: use party container directly.
    -- ☠ This was a bare `partyContainer` -- an undefined GLOBAL, never declared anywhere
    -- in this file, so it resolved to nil and every SetPoint below anchored to the
    -- container's PARENT instead of the party frames. Parse-clean, silent, and reachable
    -- whenever grouped pets are on with no visible party frame (solo with a pet, arena).
    -- The raid twin further down has always carried the `local raidContainer = ...` line
    -- this branch was missing -- mirror it exactly, including the nil bail.
    -- Guard the ANCHOR only, not the whole tail: the pet-frame positioning loop below
    -- still has to run. (The broken version reached it, so returning early here would
    -- trade a mis-anchored container for unpositioned pets.)
    local partyContainer = isTestMode and DF.testPartyContainer or DF.partyContainer
    if partyContainer then
        if anchor == "BOTTOM" then
            container:SetPoint("TOP", partyContainer, "BOTTOM", offsetX, offsetY)
        elseif anchor == "TOP" then
            container:SetPoint("BOTTOM", partyContainer, "TOP", offsetX, -offsetY)
        elseif anchor == "LEFT" then
            container:SetPoint("RIGHT", partyContainer, "LEFT", offsetX, offsetY)
        elseif anchor == "RIGHT" then
            container:SetPoint("LEFT", partyContainer, "RIGHT", -offsetX, offsetY)
        end
    end
    
    -- Position pet frames within container (fallback path)
    for i, frame in ipairs(petFrames) do
        frame:ClearAllPoints()
        frame:SetParent(container)
        
        if i == 1 then
            if growth == "HORIZONTAL" then
                frame:SetPoint("LEFT", container, "LEFT", 0, 0)
            else
                frame:SetPoint("TOP", container, "TOP", 0, 0)
            end
        else
            local prevFrame = petFrames[i - 1]
            if growth == "HORIZONTAL" then
                frame:SetPoint("LEFT", prevFrame, "RIGHT", spacing, 0)
            else
                frame:SetPoint("TOP", prevFrame, "BOTTOM", 0, -spacing)
            end
        end
    end
    
    container:Show()
end

-- ============================================================
-- RAID PET GROUP
-- ============================================================

function DF:CreateRaidPetGroupContainer()
    if DF.raidPetGroupContainer then return DF.raidPetGroupContainer end
    
    local container = CreateFrame("Frame", "DandersFrames_RaidPetGroupContainer", DF.raidContainer or UIParent)
    container:SetSize(200, 100)
    container:Hide()
    
    -- Create group label
    container.label = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    container.label:SetPoint("BOTTOM", container, "TOP", 0, 2)
    container.label:SetText("Pets")
    
    DF.raidPetGroupContainer = container
    return container
end

function DF:UpdateRaidPetGroupLayout()
    local db = DF:GetRaidDB()
    local isTestMode = DF.raidTestMode

    -- Only use group layout if in GROUPED mode and pets are enabled/shown
    local petsEnabled = isTestMode and (db.petEnabled and db.testShowPets ~= false) or (not isTestMode and db.petEnabled)
    if db.petGroupMode ~= "GROUPED" or not petsEnabled then
        DF:HidePetGroupContainer(DF.raidPetGroupContainer)
        return
    end

    -- ☠ Guards itself, for the same reason as the party layout above — PositionPetFrame
    -- returns early for GROUPED, so its guard cannot cover this path.
    if not isTestMode and InCombatLockdown() then
        DF.pendingPetPositionUpdate = true
        return
    end

    -- Create container if needed
    if not DF.raidPetGroupContainer then
        DF:CreateRaidPetGroupContainer()
    end

    local container = DF.raidPetGroupContainer

    -- In live mode, need a raid container reference
    if not isTestMode and not DF.raidContainer then return end
    local raidContainer = isTestMode and DF.testRaidContainer or DF.raidContainer

    -- Collect visible pet frames (cap at 10 for test mode)
    local petFrames = {}
    local maxPets = 10

    if isTestMode then
        -- Test mode: use test raid pet frames
        local testFrameCount = math.min(db.raidTestFrameCount or 10, maxPets)
        for i = 1, testFrameCount do
            if DF.testRaidPetFrames[i] then
                table.insert(petFrames, DF.testRaidPetFrames[i])
            end
        end
    else
        for i = 1, 40 do
            if DF.raidPetFrames[i] and UnitExists("raidpet" .. i) then
                table.insert(petFrames, DF.raidPetFrames[i])
            end
        end
    end

    if #petFrames == 0 then
        DF:HidePetGroupContainer(container)
        return
    end

    -- Get pet group settings
    local petFrameWidth = db.petFrameWidth or 72
    local petFrameHeight = db.petFrameHeight or 18
    local petSpacing = db.petGroupSpacing or 2
    local petGrowth = db.petGroupGrowth or "VERTICAL"
    local petAnchor = db.petGroupAnchor or "RIGHT"
    local offsetX = db.petGroupOffsetX or 5
    local offsetY = db.petGroupOffsetY or 0

    -- Size container based on pet frame dimensions and growth direction
    local containerWidth, containerHeight
    if petGrowth == "HORIZONTAL" then
        containerWidth = (#petFrames * petFrameWidth) + ((#petFrames - 1) * petSpacing)
        containerHeight = petFrameHeight
    else
        containerWidth = petFrameWidth
        containerHeight = (#petFrames * petFrameHeight) + ((#petFrames - 1) * petSpacing)
    end
    container:SetSize(containerWidth, containerHeight)

    -- Find actual bounds and edge frames of visible raid frames
    local minX, maxX, minY, maxY
    local leftmostFrame, rightmostFrame, topmostFrame, bottommostFrame

    -- Helper to process frame bounds
    local function processFrameBounds(frame)
        if frame and frame:IsShown() then
            local left, bottom, width, height = frame:GetRect()
            if left and bottom and width and height then
                local right = left + width
                local top = bottom + height

                if not minX or left < minX then
                    minX = left
                    leftmostFrame = frame
                end
                if not maxX or right > maxX then
                    maxX = right
                    rightmostFrame = frame
                end
                if not minY or bottom < minY then
                    minY = bottom
                    bottommostFrame = frame
                end
                if not maxY or top > maxY then
                    maxY = top
                    topmostFrame = frame
                end
            end
        end
    end

    if isTestMode then
        -- Test mode: iterate test raid frames directly
        local testFrameCount = db.raidTestFrameCount or 10
        for i = 1, testFrameCount do
            processFrameBounds(DF.testRaidFrames[i])
        end
    elseif DF.IterateRaidFrames then
        DF:IterateRaidFrames(function(frame)
            processFrameBounds(frame)
        end)
    end
    
    -- Position container relative to raid frames by anchoring to edge frames
    container:ClearAllPoints()
    container:SetParent(raidContainer)
    
    if minX and maxX and minY and maxY and leftmostFrame and rightmostFrame and topmostFrame and bottommostFrame then
        local raidWidth = maxX - minX
        local raidHeight = maxY - minY
        
        -- Calculate centering offsets
        local centerOffsetX = (raidWidth - containerWidth) / 2
        local centerOffsetY = (raidHeight - containerHeight) / 2
        
        if petAnchor == "RIGHT" then
            -- Right of raid frames, vertically centered
            -- Anchor to rightmostFrame, but need to offset Y since rightmostFrame might not be at top
            local rmLeft, rmBottom, rmWidth, rmHeight = rightmostFrame:GetRect()
            local rmTop = rmBottom + rmHeight
            local yAdjust = maxY - rmTop  -- How far down from the raid's top is this frame's top
            container:SetPoint("TOPLEFT", rightmostFrame, "TOPRIGHT", offsetX, yAdjust - centerOffsetY + offsetY)
            
        elseif petAnchor == "LEFT" then
            -- Left of raid frames, vertically centered
            -- Anchor to leftmostFrame, but need to offset Y since leftmostFrame might not be at top
            local lmLeft, lmBottom, lmWidth, lmHeight = leftmostFrame:GetRect()
            local lmTop = lmBottom + lmHeight
            local yAdjust = maxY - lmTop  -- How far down from the raid's top is this frame's top
            container:SetPoint("TOPRIGHT", leftmostFrame, "TOPLEFT", -offsetX, yAdjust - centerOffsetY + offsetY)
            
        elseif petAnchor == "BOTTOM" then
            -- Below raid frames, horizontally centered
            -- Anchor to bottommostFrame, but need to offset X since bottommostFrame might not be at left
            local bmLeft = select(1, bottommostFrame:GetRect())
            local xAdjust = bmLeft - minX  -- How far right from the raid's left is this frame
            container:SetPoint("TOPLEFT", bottommostFrame, "BOTTOMLEFT", -xAdjust + centerOffsetX + offsetX, -offsetY)
            
        elseif petAnchor == "TOP" then
            -- Above raid frames, horizontally centered
            -- Anchor to topmostFrame, but need to offset X since topmostFrame might not be at left
            local tmLeft = select(1, topmostFrame:GetRect())
            local xAdjust = tmLeft - minX  -- How far right from the raid's left is this frame
            container:SetPoint("BOTTOMLEFT", topmostFrame, "TOPLEFT", -xAdjust + centerOffsetX + offsetX, offsetY)
        end
    else
        -- Fallback: anchor to raid container directly
        container:SetPoint("TOPLEFT", raidContainer, "TOPRIGHT", offsetX, offsetY)
    end
    
    -- Update label
    if db.petGroupShowLabel ~= false then
        container.label:SetText(db.petGroupLabel or "Pets")
        container.label:Show()
        
        -- Apply group label styling from raid settings
        local labelFont = db.groupLabelFont or "Fonts\\FRIZQT__.TTF"
        local labelSize = db.groupLabelFontSize or 12
        local labelOutline = db.groupLabelOutline or "OUTLINE"
        DF:SafeSetFont(container.label, labelFont, labelSize, labelOutline)
        
        local labelColor = db.groupLabelColor or {r = 1, g = 1, b = 1}
        container.label:SetTextColor(labelColor.r, labelColor.g, labelColor.b)
    else
        container.label:Hide()
    end
    
    -- Position pet frames within container
    for i, frame in ipairs(petFrames) do
        frame:ClearAllPoints()
        frame:SetParent(container)
        
        if i == 1 then
            if petGrowth == "HORIZONTAL" then
                frame:SetPoint("LEFT", container, "LEFT", 0, 0)
            else
                frame:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
            end
        else
            local prevFrame = petFrames[i - 1]
            if petGrowth == "HORIZONTAL" then
                frame:SetPoint("LEFT", prevFrame, "RIGHT", petSpacing, 0)
            else
                frame:SetPoint("TOP", prevFrame, "BOTTOM", 0, -petSpacing)
            end
        end
    end
    
    container:Show()
end

-- ============================================================
-- PET FRAME INITIALIZATION
-- ============================================================

function DF:InitializePetFrames()
    local db = DF:GetDB()

    DF:Debug("PET", "InitializePetFrames called. petEnabled=%s petFramesInitialized=%s", tostring(db.petEnabled), tostring(DF.petFramesInitialized))

    -- Don't create if pets are disabled
    if not db.petEnabled then
        DF:Debug("PET", "InitializePetFrames: SKIPPED - pets disabled")
        return
    end

    -- ☠ CreatePetFrame does SetSize / SetAttribute / Hide on a secure button, so this
    -- whole function is a protected path. It is not login-only: HandleUnitPetEvent
    -- lazily initialises here for anyone who had pets switched off at login, so the
    -- first pet summoned mid-boss lands right here with the lockdown up.
    if InCombatLockdown() then
        DF:DebugWarn("PET", "InitializePetFrames: in combat, deferring")
        DF.pendingPetVisibilityUpdate = true
        return
    end

    -- Create player pet frame
    local playerFrame = DF:GetPlayerFrame()
    if not DF.petFrames.player and playerFrame then
        DF.petFrames.player = DF:CreatePetFrame("pet", playerFrame, false, PET_TRACK_PARTY)
        DF:Debug("PET", "InitializePetFrames: created player pet frame")
    end
    DF:Debug("PET", "InitializePetFrames: playerFrame=%s petFrames.player=%s", tostring(playerFrame ~= nil), tostring(DF.petFrames.player ~= nil))

    -- Create party pet frames
    local partyCount = 0
    for i = 1, 4 do
        local partyFrame = DF:GetPartyFrame(i)
        if not DF.partyPetFrames[i] and partyFrame then
            DF.partyPetFrames[i] = DF:CreatePetFrame("partypet" .. i, partyFrame, false, PET_TRACK_PARTY)
            partyCount = partyCount + 1
        end
    end
    DF:Debug("PET", "InitializePetFrames: created %d new party pet frames", partyCount)

    -- Only mark as initialized if at least one frame was actually created
    -- This allows retry when headers become available (e.g., joining a group)
    if DF.petFrames.player or next(DF.partyPetFrames) then
        DF.petFramesInitialized = true
        DF:Debug("PET", "InitializePetFrames: marked as initialized, positioning frames")
        -- Position all pet frames
        DF:UpdateAllPetFramePositions()
    else
        DF:Debug("PET", "InitializePetFrames: NO frames created - will retry later")
    end
end

-- ============================================================
-- UPDATE ALL PET FRAMES
-- ============================================================

local lastPetUpdateTime = 0

function DF:UpdateAllPetFrames(force)
    -- Throttle: skip if already ran this frame (multiple callers during startup/updates)
    local now = GetTime()
    if not force and now == lastPetUpdateTime then return end
    lastPetUpdateTime = now

    local db = DF:GetDB()

    DF:Debug("PET", "UpdateAllPetFrames called. testMode=%s raidTestMode=%s petEnabled=%s testShowPets=%s",
        tostring(DF.testMode), tostring(DF.raidTestMode), tostring(db.petEnabled), tostring(db.testShowPets))

    -- Hide party pet group container if in raid test mode
    if DF.raidTestMode then
        DF:Debug("PET", "UpdateAllPetFrames: hiding party pets (raid test mode active)")
        if DF.petFrames.player then DF:SetPetFrameVisible(DF.petFrames.player, false) end
        for i = 1, 4 do
            if DF.partyPetFrames[i] then DF:SetPetFrameVisible(DF.partyPetFrames[i], false) end
        end
        DF:HideAllTestPetFrames()
        return
    end

    -- Hide party pet frames when physically in a live raid (the raid pet track handles pets there).
    -- Mirrors the raid-test-mode guard above, for real raids. Without this the party pet frames can
    -- linger as an orphaned overlay over the raid frames, since the party frames they anchor to are
    -- hidden once raid frames take over.
    -- ⚠ ARENA lands here too — IsInRaid() is true and the units are raid-kind. Handing over is
    -- still right (partypet* does not exist in arena), but the receiver is the ARENA track in
    -- UpdateAllRaidPetFrames, not the raid one; the raid header is hidden in arena. Before that
    -- existed, this early return was half of why pets never appeared in 2v2 / 3v3 / shuffle.
    if not DF.testMode and IsInRaid() then
        DF:Debug("PET", "UpdateAllPetFrames: hiding party pets (live raid active)")
        if DF.petFrames.player then DF:SetPetFrameVisible(DF.petFrames.player, false) end
        for i = 1, 4 do
            if DF.partyPetFrames[i] then DF:SetPetFrameVisible(DF.partyPetFrames[i], false) end
        end
        -- ☠ NOT IN AN ARENA. DF.petGroupContainer is the container GROUPED *arena*
        -- pets are laid out into — deliberately, because arena reads the party config
        -- and so uses the party layout. Hiding it as part of the party handover blanked
        -- the entire arena pet block, and recovery depended on UpdateAllRaidPetFrames
        -- happening to run in the same tick; several callers invoke UpdateAllPetFrames
        -- on its own, and those left the arena pets invisible until something else
        -- redrew them.
        if not (DF.IsInArena and DF:IsInArena()) then
            DF:HidePetGroupContainer(DF.petGroupContainer)
        end
        return
    end

    -- In test mode, show pets if enabled AND testShowPets is on; outside test mode, check petEnabled
    local shouldShowPets
    if DF.testMode then
        shouldShowPets = db.petEnabled and (db.testShowPets ~= false)
    else
        shouldShowPets = db.petEnabled
    end

    DF:Debug("PET", "UpdateAllPetFrames: shouldShowPets=%s", tostring(shouldShowPets))

    if not shouldShowPets then
        -- Hide all pet frames if disabled
        if DF.testMode then
            DF:HideAllTestPetFrames()
        else
            if DF.petFrames.player then DF:SetPetFrameVisible(DF.petFrames.player, false) end
            for i = 1, 4 do
                if DF.partyPetFrames[i] then DF:SetPetFrameVisible(DF.partyPetFrames[i], false) end
            end
            DF:HidePetGroupContainer(DF.petGroupContainer)
        end
        return
    end

    -- Test mode: use test pet frames
    if DF.testMode then
        -- Initialize test pet frames if needed
        DF:InitializeTestPetFrames()

        local testFrameCount = db.testFrameCount or 5

        -- Update test pet frames
        for i = 0, 4 do
            if DF.testPetFrames[i] then
                if i < testFrameCount then
                    DF:UpdatePetFrame(DF.testPetFrames[i])
                    DF:PositionPetFrame(DF.testPetFrames[i])
                else
                    DF.testPetFrames[i]:Hide()
                end
            end
        end

        -- Update group layout if in grouped mode
        if db.petGroupMode == "GROUPED" then
            DF:UpdatePetGroupLayout()
        end
        return
    end

    -- Live mode: use real pet frames
    -- Initialize if needed
    DF:Debug("PET", "UpdateAllPetFrames: LIVE MODE - calling InitializePetFrames")
    DF:InitializePetFrames()

    DF:Debug("PET", "UpdateAllPetFrames: LIVE MODE - playerPet=%s partyPets=%d",
        tostring(DF.petFrames.player ~= nil),
        (DF.partyPetFrames[1] and 1 or 0) + (DF.partyPetFrames[2] and 1 or 0) + (DF.partyPetFrames[3] and 1 or 0) + (DF.partyPetFrames[4] and 1 or 0))

    -- Update player pet
    if DF.petFrames.player then
        DF:UpdatePetFrame(DF.petFrames.player)
        DF:PositionPetFrame(DF.petFrames.player)
    end

    -- Update party pets
    for i = 1, 4 do
        if DF.partyPetFrames[i] then
            DF:UpdatePetFrame(DF.partyPetFrames[i])
            DF:PositionPetFrame(DF.partyPetFrames[i])
        end
    end

    -- Update group layout if in grouped mode
    if db.petGroupMode == "GROUPED" then
        DF:UpdatePetGroupLayout()
    end
end

local lastRaidPetUpdateTime = 0

-- Hide every arena pet (leaving arena, or pets switched off).
local function HideArenaPetFrames()
    for i = 1, 5 do
        if DF.arenaPetFrames[i] then DF:SetPetFrameVisible(DF.arenaPetFrames[i], false) end
    end
end

-- ARENA PETS. Arena is the odd one out: the group is RAID-kind (IsInRaid() is true,
-- units are raid1-5), so the party pet track hides itself and hands over to the raid
-- track — but the raid track walks the raid header, which is hidden in arena, while
-- DF shows its own arenaHeader. Nothing walked the arena header, so pets simply never
-- appeared in 2v2 / 3v3 / shuffle, with no error to show for it.
--
-- Settings come from the PARTY config even though the units are raidpet*: an arena
-- team reads as a party to a player, and that is where they will have configured it.
-- That is why the frames are created with isRaid = false — every downstream path
-- resolves through DF:GetFrameDB(frame), which keys off frame.isRaidFrame, so this
-- one flag routes size, layout and petEnabled to the party settings for free.
local function UpdateArenaPetFrames()
    local db = DF:GetDB()   -- party config, deliberately (see above)

    if not db.petEnabled then
        HideArenaPetFrames()
        -- The PARTY container, not the raid one: grouped arena pets are laid out by
        -- UpdatePetGroupLayout, which owns DF.petGroupContainer and re-parents the
        -- pet buttons onto it. Hiding raidPetGroupContainer left the real container
        -- shown.
        DF:HidePetGroupContainer(DF.petGroupContainer)
        return
    end

    -- Everything below this point touches protected state: CreatePetFrame builds a
    -- SecureUnitButtonTemplate and calls SetSize/SetAttribute, and PositionPetFrame
    -- does ClearAllPoints/SetParent/SetPoint. Arena reaches it constantly: a pet
    -- summoned or resurrected mid-match, a Solo Shuffle round transition, or Core's
    -- PLAYER_REGEN_DISABLED handler ending test mode all land here with the lockdown up.
    --
    -- ☠ This comment used to claim the raid track "gets away without a guard because
    -- you only reach it forming a group, out of combat". That was FALSE — the Options
    -- sliders are usable in combat and reach it. The guard now lives on
    -- PositionPetFrame and InitializePetFrames themselves, covering every track; this
    -- one stays because deferring the whole arena pass is cheaper than deferring each
    -- frame within it.
    --
    -- Defer rather than drop, so the pets appear the moment combat ends instead of
    -- waiting for whatever roster event happens to come next.
    if InCombatLockdown() then
        DF.pendingArenaPetUpdate = true
        return
    end
    DF.pendingArenaPetUpdate = nil

    -- Deferred creation, same shape as the raid track. The arena header's children
    -- are the owners; raidpet<N> matches its raid<N> unit tokens.
    local idx = 0
    if DF.IterateArenaFrames then
        DF:IterateArenaFrames(function(frame)
            idx = idx + 1
            if frame and not DF.arenaPetFrames[idx] then
                -- isRaid = false routes settings to the party config (see the block
                -- comment above); the track is what says "arena", since raidpet<N> and
                -- isRaidFrame both read identically to the raid set.
                DF.arenaPetFrames[idx] = DF:CreatePetFrame("raidpet" .. idx, frame, false, PET_TRACK_ARENA)
            end
        end)
    end

    for i = 1, 5 do
        if DF.arenaPetFrames[i] then
            DF:UpdatePetFrame(DF.arenaPetFrames[i])
            DF:PositionPetFrame(DF.arenaPetFrames[i])
        end
    end

    -- GROUPED mode positions from the layout pass, not per-frame (PositionPetFrame
    -- returns early for it). The party layout is the right one — same config — and
    -- it collects arenaPetFrames when in arena.
    if db.petGroupMode == "GROUPED" then
        DF:UpdatePetGroupLayout()
    end
end

function DF:UpdateAllRaidPetFrames(force)
    -- Throttle: skip if already ran this frame (multiple callers during startup/updates)
    local now = GetTime()
    if not force and now == lastRaidPetUpdateTime then return end
    lastRaidPetUpdateTime = now

    -- Arena runs its own track (party settings, arena header) and never the raid one:
    -- the raid header is hidden here, so its pets would anchor to invisible frames.
    if not (DF.testMode or DF.raidTestMode) and DF.IsInArena and DF:IsInArena() then
        for i = 1, 40 do
            if DF.raidPetFrames[i] then DF:SetPetFrameVisible(DF.raidPetFrames[i], false) end
        end
        UpdateArenaPetFrames()
        return
    end
    -- Left arena (or never in one): make sure no arena pet is left hanging over the
    -- party/raid frames. Cheap — the table is empty until arena has been entered once.
    HideArenaPetFrames()

    local db = DF:GetRaidDB()

    -- Hide raid pet frames if in party test mode (not raid test mode)
    if DF.testMode and not DF.raidTestMode then
        for i = 1, 40 do
            if DF.raidPetFrames[i] then DF:SetPetFrameVisible(DF.raidPetFrames[i], false) end
        end
        DF:HideAllTestRaidPetFrames()
        return
    end

    -- In test mode, show pets if enabled AND testShowPets is on; outside test mode, check petEnabled
    local shouldShowPets
    if DF.raidTestMode then
        shouldShowPets = db.petEnabled and (db.testShowPets ~= false)
    else
        shouldShowPets = db.petEnabled
    end

    if not shouldShowPets then
        if DF.raidTestMode then
            DF:HideAllTestRaidPetFrames()
        else
            for i = 1, 40 do
                if DF.raidPetFrames[i] then DF:SetPetFrameVisible(DF.raidPetFrames[i], false) end
            end
            DF:HidePetGroupContainer(DF.raidPetGroupContainer)
        end
        return
    end

    -- Raid test mode: use test pet frames
    if DF.raidTestMode then
        DF:InitializeTestRaidPetFrames()

        local testFrameCount = db.raidTestFrameCount or 10

        for i = 1, 40 do
            if DF.testRaidPetFrames[i] then
                if i <= testFrameCount then
                    DF:UpdatePetFrame(DF.testRaidPetFrames[i])
                    DF:PositionPetFrame(DF.testRaidPetFrames[i])
                else
                    DF.testRaidPetFrames[i]:Hide()
                end
            end
        end

        if db.petGroupMode == "GROUPED" then
            DF:UpdateRaidPetGroupLayout()
        end
        return
    end

    -- Live mode: use real raid pet frames
    -- Initialize if needed (deferred creation)
    local frameIdx = 0
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(function(frame)
            frameIdx = frameIdx + 1
            if frame and not DF.raidPetFrames[frameIdx] then
                DF.raidPetFrames[frameIdx] = DF:CreatePetFrame("raidpet" .. frameIdx, frame, true, PET_TRACK_RAID)
            end
        end)
    end

    -- Update all raid pets
    for i = 1, 40 do
        if DF.raidPetFrames[i] then
            DF:UpdatePetFrame(DF.raidPetFrames[i])
            DF:PositionPetFrame(DF.raidPetFrames[i])
        end
    end

    -- Update group layout if in grouped mode
    if db.petGroupMode == "GROUPED" then
        DF:UpdateRaidPetGroupLayout()
    end
end

function DF:UpdateAllPetFramePositions()
    -- ☠ ONLY THE ACTIVE TRACK. Walking all three is not merely wasted work:
    -- PositionPetFrame re-resolves the owner through GetFrameForUnit, which is
    -- arena-aware, so repositioning a non-owning set RE-PARENTS it onto whichever
    -- header is currently visible. That is why dragging any pet slider in an arena
    -- dragged the hidden raid pets onto the arena frames.
    local track = DF:ActivePetTrack()

    -- Update party pet positions
    if track == PET_TRACK_PARTY then
        if DF.petFrames.player then
            DF:PositionPetFrame(DF.petFrames.player)
        end

        for i = 1, 4 do
            if DF.partyPetFrames[i] then
                DF:PositionPetFrame(DF.partyPetFrames[i])
            end
        end
    end

    -- Update raid pet positions
    if track == PET_TRACK_RAID then
        for i = 1, 40 do
            if DF.raidPetFrames[i] then
                DF:PositionPetFrame(DF.raidPetFrames[i])
            end
        end
    end

    -- ☠ ARENA WAS OMITTED ENTIRELY, so Anchor / Offset X / Offset Y did nothing at
    -- all in an arena — the sliders wrote to the DB and no arena pet ever moved.
    if track == PET_TRACK_ARENA then
        for i = 1, 5 do
            if DF.arenaPetFrames[i] then
                DF:PositionPetFrame(DF.arenaPetFrames[i])
            end
        end
    end
end

-- ============================================================
-- PET EVENT HANDLING
-- ============================================================

-- raid<N> / raidpet<N> tokens are used by BOTH the raid frames and the arena team,
-- so the token alone does not say which pet set owns the index. A pet summoned or
-- resurrected mid-match fires these; without the arena case the event would look up
-- the raid set, find nothing, and the frame would sit stale until the next full pass.
local function PetSetForRaidIndex()
    if DF.IsInArena and DF:IsInArena() then return DF.arenaPetFrames end
    return DF.raidPetFrames
end

-- Update AND reposition. Every branch below used to call UpdatePetFrame alone, so a
-- pet arriving through UNIT_PET -- a warlock resummoning mid-arena is the everyday
-- case -- was SHOWN at whatever anchor it last held. That is the "right pet under the
-- wrong teammate" symptom for anything that arrives here rather than through a track
-- pass. Owner death and rez arrive as UNIT_HEALTH / UNIT_FLAGS and never reach here.
local function RefreshPetFrame(frame)
    if not frame then return end
    DF:UpdatePetFrame(frame)
    -- ⚠ NO combat early-return here, deliberately. PositionPetFrame owns the guard AND
    -- raises pendingPetPositionUpdate itself; short-circuiting on InCombatLockdown
    -- here means nothing ever gets flagged, so the anchor stays stale past the end of
    -- the fight instead of being replayed by the drain. Let the choke point own it.
    DF:PositionPetFrame(frame)
end

function DF:OnPetChanged(unit)
    -- ☠ GATE BY TRACK. UNIT_PET fires for BOTH "player" and "raidN" in an arena --
    -- one pet reached through two tokens -- so acting on the player branch as well as
    -- the raid branch re-shows the party-side frame the handover just hid, on every
    -- pet event for the rest of the match. That is precisely the duplicate-frame bug
    -- the track system exists to kill, and the retail field capture shows it as counts
    -- pairing in lockstep (pet 214 / raidpet1 214, partypet1 161 / raidpet2 161). The
    -- raid branches below already cover the arena case. The same applies to the party
    -- branches in a live raid.
    --
    -- ⚠ Written as explicit track-name comparisons, NOT as `not partySide`. With five
    -- tracks in play, "not party" is TRUE in party test mode, and real pet events would
    -- start driving live secure frames -- worse for arena frames, which are
    -- isRaid = false, so UpdatePetFrame reads DF.testMode as *their* test flag and
    -- fills a live secure button with fake test health and forces it visible.
    local track = DF:ActivePetTrack()
    local partySide = (track == PET_TRACK_PARTY)
    local raidSide  = (track == PET_TRACK_RAID) or (track == PET_TRACK_ARENA)

    -- Determine which pet frame to update based on unit
    if unit == "player" or unit == "pet" then
        if partySide and DF.petFrames.player then
            RefreshPetFrame(DF.petFrames.player)
        end
    elseif unit:match("^party%d$") then
        local index = tonumber(unit:match("party(%d)"))
        if partySide and index then
            RefreshPetFrame(DF.partyPetFrames[index])
        end
    elseif unit:match("^partypet%d$") then
        local index = tonumber(unit:match("partypet(%d)"))
        if partySide and index then
            RefreshPetFrame(DF.partyPetFrames[index])
        end
    elseif unit:match("^raid%d+$") then
        local index = tonumber(unit:match("raid(%d+)"))
        if raidSide and index then
            RefreshPetFrame(PetSetForRaidIndex()[index])
        end
    elseif unit:match("^raidpet%d+$") then
        local index = tonumber(unit:match("raidpet(%d+)"))
        if raidSide and index then
            RefreshPetFrame(PetSetForRaidIndex()[index])
        end
    end
end

-- Register for UNIT_PET event in main addon
-- This will be called from the main event handler
function DF:HandleUnitPetEvent(unit)
    local db = DF:GetDB()

    DF:Debug("PET", "HandleUnitPetEvent: unit=%s petEnabled=%s petFramesInitialized=%s", tostring(unit), tostring(db.petEnabled), tostring(DF.petFramesInitialized))

    -- Lazy-load pet frames on first pet event (if pets are enabled)
    -- InitializePetFrames sets the flag internally only when frames are created
    if db.petEnabled and not DF.petFramesInitialized then
        DF:Debug("PET", "HandleUnitPetEvent: lazy-loading pet frames")
        DF:InitializePetFrames()
    end

    DF:OnPetChanged(unit)
end

-- ============================================================
-- APPLY PET SETTINGS (called when settings change)
-- ============================================================

function DF:ApplyPetSettings()
    local db = DF:GetDB()
    local raidDb = DF:GetRaidDB()

    DF:Debug("PET", "ApplyPetSettings called. testMode=%s raidTestMode=%s petEnabled=%s raidPetEnabled=%s",
        tostring(DF.testMode), tostring(DF.raidTestMode), tostring(db.petEnabled), tostring(raidDb.petEnabled))

    -- Update party/solo pet frames
    local partyPetsEnabled = DF.testMode and (db.petEnabled and db.testShowPets ~= false) or (not DF.testMode and db.petEnabled)
    if partyPetsEnabled then
        if DF.testMode then
            DF:InitializeTestPetFrames()
        else
            DF:InitializePetFrames()
        end
        DF:UpdateAllPetFrames(true)  -- force: explicit settings change
    else
        -- Hide all party pet frames (both live and test). Route through
        -- SetPetFrameVisible so a disable toggled IN COMBAT falls back to alpha-0
        -- — a direct :Hide() on the secure pet button is protected (taint/blocked).
        if DF.petFrames.player then DF:SetPetFrameVisible(DF.petFrames.player, false) end
        for i = 1, 4 do
            if DF.partyPetFrames[i] then DF:SetPetFrameVisible(DF.partyPetFrames[i], false) end
        end
        DF:HideAllTestPetFrames()
    end

    -- Update raid pet frames
    local raidPetsEnabled = DF.raidTestMode and (raidDb.petEnabled and raidDb.testShowPets ~= false) or (not DF.raidTestMode and raidDb.petEnabled)
    if raidPetsEnabled then
        if DF.raidTestMode then
            DF:InitializeTestRaidPetFrames()
        end
        DF:UpdateAllRaidPetFrames(true)  -- force: explicit settings change
    else
        for i = 1, 40 do
            if DF.raidPetFrames[i] then DF:SetPetFrameVisible(DF.raidPetFrames[i], false) end
        end
        DF:HideAllTestRaidPetFrames()
    end

    -- ☠ ARENA IS ITS OWN TRACK, and neither branch above covers it. It was gated on
    -- the RAID config while actually READING the party one, and arenaPetFrames was
    -- never touched at all — so every pet option was inert in an arena, and turning
    -- pets off mid-match left them on screen until a zone change.
    --
    -- ⚠ TEST MODES EXCLUDED. Without that, raid test mode entered inside an arena
    -- takes the enabled branch here and leaves all 40 live raid pet frames shown on
    -- top of the preview.
    if not (DF.testMode or DF.raidTestMode) and DF.IsInArena and DF:IsInArena() then
        if db.petEnabled then
            -- Routes to UpdateArenaPetFrames via the arena branch at the top of it.
            DF:UpdateAllRaidPetFrames(true)
        else
            for i = 1, 5 do
                if DF.arenaPetFrames[i] then DF:SetPetFrameVisible(DF.arenaPetFrames[i], false) end
            end
            -- The PARTY container: GROUPED arena pets are laid out by
            -- UpdatePetGroupLayout, which owns DF.petGroupContainer.
            DF:HidePetGroupContainer(DF.petGroupContainer)
        end
    end
end
