local addonName, DF = ...

-- Get module namespace
local CC = DF.ClickCast

-- EVENT HANDLING
-- ============================================================

function CC:RegisterEvents()
    local eventFrame = CreateFrame("Frame")
    self.eventFrame = eventFrame
    
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("PLAYER_LEVEL_UP")
    eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    
    -- Talent/Loadout events for profile auto-switching
    eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
    eventFrame:RegisterEvent("TRAIT_CONFIG_CREATED")
    eventFrame:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
    eventFrame:RegisterEvent("ACTIVE_COMBAT_CONFIG_CHANGED")  -- Fires when loadout is switched
    -- Events for dynamic frames (boss/arena)
    eventFrame:RegisterEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")
    eventFrame:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
    
    -- Nameplate events for click-casting on nameplates
    eventFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    eventFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")

    -- Spell data arrival — one of the triggers that re-runs a cold-start
    -- profile check (see CC:ResolveColdStartProfile)
    eventFrame:RegisterEvent("SPELLS_CHANGED")

    -- Player housing can invalidate secure wraps on unit frames
    -- (field case 2026-07-20: hover keybinds dead after a housing session,
    -- wraps no longer executing). The repair re-wraps, so run it on every
    -- editor-mode change. pcall'd: the event only exists on clients with
    -- housing.
    pcall(function() eventFrame:RegisterEvent("HOUSE_EDITOR_MODE_CHANGED") end)
    
    eventFrame:SetScript("OnEvent", function(_, event, ...)
        if event == "PLAYER_REGEN_ENABLED" then
            -- Out of combat - process pending operations
            CC:OnCombatEnd()
        elseif event == "PLAYER_REGEN_DISABLED" then
            -- Entered combat (no action needed)
        elseif event == "PLAYER_SPECIALIZATION_CHANGED" or event == "ACTIVE_PLAYER_SPECIALIZATION_CHANGED" then
            -- Spec changed - check for profile switch
            CC:OnSpecChanged()
            -- Cold-start resolve: a loadout check that ran before
            -- GetSpecialization() resolved could not pick a profile — run it now
            CC:ResolveColdStartProfile("spec-resolved")
        elseif event == "SPELLS_CHANGED" then
            -- Spell data arrived/changed — no-op unless a check is outstanding
            CC:ResolveColdStartProfile("spells-changed")
        elseif event == "TRAIT_CONFIG_UPDATED" or event == "TRAIT_CONFIG_CREATED" or event == "ACTIVE_COMBAT_CONFIG_CHANGED" then
            -- Loadout/talent changed - check for profile switch and reapply bindings (with debounce)
            if not InCombatLockdown() then
                -- Debounce: wait before checking to ensure API data is ready
                CC:DeferAfter("loadoutCheck", 0.5, function()
                    CC:CheckLoadoutProfileSwitch()
                    -- Reapply bindings to pick up spell overrides from talent changes
                    CC:ApplyBindings()
                    -- Also refresh UI in case talents changed
                    CC:DeferAfter("uiRefresh", 0.3, function()
                        CC:RefreshClickCastingUI()
                    end)
                end)
            else
                CC:Defer("loadoutCheck")
                CC:Defer("bindingRefresh")
            end
        elseif event == "PLAYER_LEVEL_UP" then
            -- Level up - may have learned new spells, reapply bindings
            if not InCombatLockdown() then
                CC:ApplyBindings()
                CC:DeferAfter("uiRefresh", 0.2, function()
                    CC:RefreshClickCastingUI()
                end)
            else
                CC:Defer("bindingRefresh")
            end
        elseif event == "PLAYER_EQUIPMENT_CHANGED" then
            -- Equipment changed - refresh items tab if visible
            if CC.activeTab == "items" then
                CC:RefreshSpellGrid()
            end
        elseif event == "PLAYER_ENTERING_WORLD" then
            -- Initial load or reload. Keyed: back-to-back loading screens
            -- would otherwise stack several settle passes over each other.
            CC:DeferAfter("zoneSettle", 0.5, function()
                -- Run one-time migration to convert bindings to root spells
                CC:MigrateBindingsToRootSpells()
                
                CC:RegisterAllFrames()
                -- Register Blizzard frames if any binding needs them
                if CC:AnyBindingNeedsBlizzardFrames() then
                    CC:RegisterBlizzardFrames()
                end
                -- Register all currently visible nameplates
                CC:RegisterAllNameplates()
                -- Apply hovercast bindings
                CC:ApplyGlobalBindings()

                -- Self-heal (bug #976): reset restricted-env hover tracking and
                -- rebuild keyboard binding snippets after every loading screen,
                -- so a broken hover-bind state never survives a zone change
                CC:RunBindingRepair("zone-in", true)

                -- Cold-start resolve: if the login check ran before spec data
                -- was available, no profile could be picked — re-run it on the
                -- first loading screen so the right profile is active BEFORE
                -- the first arena/dungeon of the session, not only after a
                -- /reload
                CC:ResolveColdStartProfile("zone-in")

                -- Check for loadout-based profile on initial load. Keyed so
                -- back-to-back loading screens reuse one pending pass, and
                -- called unconditionally: CheckLoadoutProfileSwitch defers
                -- itself onto the "loadoutCheck" queue job in lockdown, so a
                -- guard here would only duplicate that one decision point.
                -- (The original call-site guard DROPPED the check outright
                -- when zone-in+1s landed in combat — the arena-load race.)
                CC:DeferAfter("loadoutCheck", 1, function()
                    CC:CheckLoadoutProfileSwitch()
                end)
            end)
        elseif event == "ARENA_PREP_OPPONENT_SPECIALIZATIONS" then
            -- Arena frames should now exist
            -- Belt: never enter an arena on an unresolved cold-start profile
            CC:ResolveColdStartProfile("arena-prep")
            CC:OnArenaPrep()
        elseif event == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" then
            -- Boss frames should now exist
            CC:OnBossEngage()
        elseif event == "NAME_PLATE_UNIT_ADDED" then
            -- A nameplate was added
            local unitToken = ...
            CC:OnNamePlateAdded(unitToken)
        elseif event == "NAME_PLATE_UNIT_REMOVED" then
            -- A nameplate was removed
            local unitToken = ...
            CC:OnNamePlateRemoved(unitToken)
        elseif event == "HOUSE_EDITOR_MODE_CHANGED" then
            -- Housing mode transitions can kill secure wraps; the repair
            -- re-wraps every frame (self-defers in combat, cooldown-limited)
            CC:RequestBindingRepair("housing-mode")
        end
    end)
end

-- ============================================================
-- DEFERRED WORK QUEUE
-- ============================================================
-- Click casting cannot touch secure state in combat, so work blocked by
-- combat lockdown has to be replayed afterwards. This used to be ten
-- separate self.needsX / self.pendingX flags, each with its own set-site and
-- its own hand-written drain line in OnCombatEnd. Adding a deferral meant
-- remembering to add a matching drain; forgetting silently dropped the work
-- for the rest of the session (that is how the arena cold-start bug and the
-- keyboard-refresh drop both happened).
--
-- Now there is one queue. Register the job here, call CC:Defer("job"), and
-- the drain is automatic and ordered. Three job kinds:
--   flag  - "do this thing later", no payload, dedupes to a single run
--   value - carries one value (a profile name, a repair reason); policy
--           "first" keeps the earliest, "last" keeps the most recent
--   set   - accumulates a set of items (frames) and runs once over all
--
-- A job's run() returns true to request a UI refresh once the drain settles.
-- DRAIN_ORDER is load-bearing: it reproduces the exact sequence the old
-- OnCombatEnd used. Do not reorder without checking that dependency chain
-- (profile switch must precede binding work; registration must precede the
-- binding refresh that walks registered frames).

local DRAIN_ORDER = {
    "profileSwitch",
    "loadoutCheck",
    "register",
    "unregister",
    "fullRegistration",
    "reassert",
    "bindingRepair",
    "bindingRefresh",
    "blizzardRegister",
    "blizzardUnregister",
    "keyboardRefresh",
}

local DEFERRED_JOBS = {
    profileSwitch = {
        kind = "value", policy = "last",
        run = function(self, profileName)
            if self:SetActiveProfile(profileName) then
                self:ApplyBindings()
                return true
            end
        end,
    },
    loadoutCheck = {
        kind = "flag",
        run = function(self)
            self:CheckLoadoutProfileSwitch()
            return true
        end,
    },
    register = {
        kind = "set",
        run = function(self, frames)
            for frame in pairs(frames) do
                self:RegisterFrame(frame)
            end
        end,
    },
    unregister = {
        kind = "set",
        run = function(self, frames)
            for frame in pairs(frames) do
                self:UnregisterFrame(frame)
            end
        end,
    },
    reassert = {
        -- Blizzard's SecureUnitButton_OnLoad reset these frames' click
        -- registration (see the hook in InitializeSecureFrames) — it runs on
        -- every CompactUnitFrame_SetUnit roster shuffle and stomps
        -- RegisterForClicks back to AnyUp plus the wildcard click actions.
        -- Re-apply our bindings on exactly the frames that were touched.
        kind = "set",
        run = function(self, frames)
            for frame in pairs(frames) do
                if self.registeredFrames and self.registeredFrames[frame] then
                    self:ApplyBindingsToFrameUnified(frame)
                end
            end
        end,
    },
    fullRegistration = {
        kind = "flag",
        run = function(self) self:RegisterAllFrames() end,
    },
    bindingRepair = {
        -- first-write-wins: the earliest reason is the one that diagnosed the
        -- breakage; later requeues during the same combat are the same repair
        kind = "value", policy = "first",
        run = function(self, reason) self:RunBindingRepair(reason) end,
    },
    bindingRefresh = {
        kind = "flag",
        run = function(self)
            self:ApplyBindings()
            return true
        end,
    },
    blizzardRegister = {
        kind = "flag",
        run = function(self) self:RegisterBlizzardFrames() end,
    },
    blizzardUnregister = {
        kind = "flag",
        run = function(self) self:UnregisterBlizzardFrames() end,
    },
    keyboardRefresh = {
        kind = "flag",
        run = function(self) self:RefreshKeyboardBindings() end,
    },
}

-- Queue work for the next time we are out of combat.
-- Safe to call repeatedly: flags dedupe, values follow their policy, sets accumulate.
function CC:Defer(job, payload)
    local def = DEFERRED_JOBS[job]
    if not def then
        DF:Debug("CLICK", "Defer: unknown job '%s'", tostring(job))
        return
    end

    self.deferred = self.deferred or {}

    if def.kind == "set" then
        local set = self.deferred[job]
        if type(set) ~= "table" then
            set = {}
            self.deferred[job] = set
        end
        if payload ~= nil then set[payload] = true end
    elseif def.kind == "value" then
        if def.policy == "first" and self.deferred[job] ~= nil then
            return  -- keep the earliest value
        end
        self.deferred[job] = payload
    else
        self.deferred[job] = true
    end
end

-- Run queued work. Pass a job name to drain only that job (used at init, where
-- only frame registration is safe to replay); omit it to drain everything.
function CC:DrainDeferred(onlyJob)
    if InCombatLockdown() then return end

    local queue = self.deferred
    if not queue then return end

    local needsUIRefresh = false
    local ran  -- diagnostic: which jobs actually ran this drain

    for _, job in ipairs(DRAIN_ORDER) do
        if not onlyJob or onlyJob == job then
            local payload = queue[job]
            if payload ~= nil then
                -- clear before running: a job that re-defers itself (a repair
                -- that finds more work) must queue for the NEXT drain, not be
                -- wiped by this one
                queue[job] = nil
                ran = ran and (ran .. "," .. job) or job
                if DEFERRED_JOBS[job].run(self, payload) then
                    needsUIRefresh = true
                end
            end
        end
    end

    -- Surface what recovered at combat end / init. Previously silent, so a log
    -- showed "queued for combat end" with no confirmation the work ever ran.
    if ran then
        DF:Debug("CLICK", "DrainDeferred ran: %s", ran)
    end

    if next(queue) == nil then
        self.deferred = nil
    end

    -- Refresh UI if needed (after a short delay for everything to settle)
    if needsUIRefresh then
        self:DeferAfter("uiRefresh", 0.2, function()
            CC:RefreshClickCastingUI()
        end)
    end
end

-- ============================================================
-- KEYED SETTLE TIMERS
-- ============================================================
-- Click casting settles state after events (loading screens, spec changes,
-- arena prep) using short timers. Several of those events fire in bursts, and
-- with bare C_Timer.After each burst stacked another timer -- so a callback
-- could run with state captured before the previous one had finished, and
-- retry chains could fork into several concurrent chains.
--
-- DeferAfter keys each timer: scheduling the same key again cancels the
-- pending one, so there is always at most one run in flight per key.

function CC:DeferAfter(key, delay, fn)
    self.timers = self.timers or {}
    local existing = self.timers[key]
    if existing then existing:Cancel() end
    self.timers[key] = C_Timer.NewTimer(delay, function()
        if CC.timers then CC.timers[key] = nil end
        fn()
    end)
end

-- Guard for functions that must not touch secure state in combat.
-- Returns true if the caller should abort; the work is queued as `job` so it
-- cannot be silently lost. Defer at the point of blocking rather than trusting
-- a caller further up the stack to have set a flag.
function CC:CombatGuard(job, payload)
    if not InCombatLockdown() then return false end
    self:Defer(job, payload)
    return true
end

function CC:OnCombatEnd()
    self:DrainDeferred()
end

function CC:OnSpecChanged()
    -- Spec changed - check for profile switch based on new spec/loadout
    if not InCombatLockdown() then
        self:CheckLoadoutProfileSwitch()
        self:ApplyBindings()
        -- Refresh UI after a short delay to ensure spell data is ready
        self:DeferAfter("uiRefresh", 0.3, function()
            CC:RefreshClickCastingUI()
        end)
    else
        self:Defer("loadoutCheck")
        self:Defer("bindingRefresh")
    end
end

function CC:OnArenaPrep()
    if self.db.options.globalEnabled then
        -- Arena frames should now exist, try to register.
        -- Keyed: ARENA_PREP fires once per opponent, so this would otherwise
        -- schedule several identical registration passes.
        self:DeferAfter("dynamicFrameRegister", 0.1, function()
            if not CC:CombatGuard("blizzardRegister") then
                CC:RegisterBlizzardFrames()
            end
        end)
    end
end

function CC:OnBossEngage()
    if self.db.options.globalEnabled then
        -- Boss frames should now exist.
        -- Keyed: INSTANCE_ENCOUNTER_ENGAGE_UNIT fires repeatedly during an
        -- encounter, so this would otherwise stack a timer per fire.
        self:DeferAfter("dynamicFrameRegister", 0.1, function()
            if not CC:CombatGuard("blizzardRegister") then
                CC:RegisterBlizzardFrames()
            end
        end)
    end
end

-- ============================================================

-- NAMEPLATE HANDLING
-- ============================================================

-- Track registered nameplates
CC.registeredNameplates = CC.registeredNameplates or {}

-- Called when a nameplate is added
function CC:OnNamePlateAdded(unitToken)
    if not self.db or not self.db.enabled then return end
    if not self.db.options.globalEnabled then return end
    
    -- Get the nameplate frame
    local nameplate = C_NamePlate.GetNamePlateForUnit(unitToken)
    if not nameplate then return end
    
    -- Debug output
    if self.db.options.debugBindings then
        local name = UnitName(unitToken) or "Unknown"
        print("|cff33cc66DF Nameplate:|r Added for " .. name .. " (" .. unitToken .. ")")
    end
    
    -- Get the actual clickable button from the nameplate
    -- Different nameplate addons structure this differently
    local clickableFrame = self:GetNameplateClickableFrame(nameplate, unitToken)
    
    if clickableFrame then
        -- Mark as a nameplate frame
        clickableFrame.dfIsNameplate = true
        clickableFrame.dfNameplateUnit = unitToken
        
        -- Track it
        self.registeredNameplates[unitToken] = clickableFrame
        
        -- Register for click-casting
        if not InCombatLockdown() then
            self:RegisterFrame(clickableFrame)
            
            if self.db.options.debugBindings then
                local frameName = clickableFrame:GetName() or "unnamed"
                print("|cff33cc66DF Nameplate:|r Registered frame: " .. frameName)
            end
        else
            -- Queue for after combat
            self:Defer("register", clickableFrame)
        end
    else
        if self.db.options.debugBindings then
            print("|cffff6666DF Nameplate:|r Could not find clickable frame for " .. unitToken)
        end
    end
end

-- Called when a nameplate is removed
function CC:OnNamePlateRemoved(unitToken)
    local frame = self.registeredNameplates[unitToken]
    
    if frame then
        if self.db.options.debugBindings then
            print("|cff33cc66DF Nameplate:|r Removed for " .. unitToken)
        end
        
        -- Unregister from click-casting
        if not InCombatLockdown() then
            self:UnregisterFrame(frame)
        else
            -- Queue for after combat
            self:Defer("unregister", frame)
        end
        
        self.registeredNameplates[unitToken] = nil
    end
end

-- Get the clickable frame from a nameplate
-- This handles different nameplate addon structures
function CC:GetNameplateClickableFrame(nameplate, unitToken)
    if not nameplate then return nil end
    
    -- Debug helper
    local function debugFrame(label, frame)
        if self.db.options.debugBindings and frame then
            local name = frame:GetName() or "unnamed"
            local objType = frame:GetObjectType()
            local isButton = frame:IsObjectType("Button")
            local hasRegister = frame.RegisterForClicks ~= nil
            local unit = frame:GetAttribute("unit") or frame.unit
            print("  [Debug " .. label .. "] " .. name .. " (" .. objType .. ") isButton=" .. tostring(isButton) .. " hasRegister=" .. tostring(hasRegister) .. " unit=" .. tostring(unit))
        end
    end
    
    -- Try to find the UnitFrame child (Blizzard default structure)
    local unitFrame = nameplate.UnitFrame
    if unitFrame then
        debugFrame("UnitFrame", unitFrame)
        -- Check if it's a Button or has RegisterForClicks
        if unitFrame:IsObjectType("Button") or unitFrame.RegisterForClicks then
            local unit = unitFrame:GetAttribute("unit") or unitFrame.unit
            if unit then
                return unitFrame
            end
        end
    end
    
    -- Try the nameplate itself
    debugFrame("nameplate", nameplate)
    if nameplate:IsObjectType("Button") or nameplate.RegisterForClicks then
        local unit = nameplate:GetAttribute("unit")
        if unit then
            return nameplate
        end
    end
    
    -- Try common nameplate addon patterns
    -- Plater
    if nameplate.unitFrame then
        debugFrame("Plater unitFrame", nameplate.unitFrame)
        if nameplate.unitFrame:IsObjectType("Button") or nameplate.unitFrame.RegisterForClicks then
            return nameplate.unitFrame
        end
    end
    
    -- Plater alternate structure
    if nameplate.PlaterFrame then
        debugFrame("PlaterFrame", nameplate.PlaterFrame)
        return nameplate.PlaterFrame
    end
    
    -- KuiNameplates
    if nameplate.kui then
        local kuiFrame = nameplate.kui
        debugFrame("KuiFrame", kuiFrame)
        if kuiFrame.HealthBar then
            return kuiFrame
        end
    end
    
    -- TidyPlates / ThreatPlates
    if nameplate.TPFrame then
        debugFrame("TPFrame", nameplate.TPFrame)
        return nameplate.TPFrame
    end
    
    -- NeatPlates
    if nameplate.carrier then
        debugFrame("NeatPlates carrier", nameplate.carrier)
        return nameplate.carrier
    end
    
    -- Fallback: search all children for a Button with unit attribute
    for _, child in ipairs({nameplate:GetChildren()}) do
        if child:IsObjectType("Button") then
            debugFrame("Child Button", child)
            local childUnit = child:GetAttribute("unit") or child.unit
            if childUnit then
                return child
            end
        end
    end
    
    -- Last resort: search for any frame with RegisterForClicks
    for _, child in ipairs({nameplate:GetChildren()}) do
        if child.RegisterForClicks then
            debugFrame("Child with RegisterForClicks", child)
            local childUnit = child:GetAttribute("unit") or child.unit
            if childUnit or not InCombatLockdown() then
                -- Set unit if missing
                if not child:GetAttribute("unit") and not InCombatLockdown() then
                    child:SetAttribute("unit", unitToken)
                end
                return child
            end
        end
    end
    
    -- Very last resort: if the nameplate's UnitFrame exists but isn't a Button,
    -- we can still try to use it with SecureActionButton behavior
    if unitFrame and not InCombatLockdown() then
        debugFrame("Fallback UnitFrame", unitFrame)
        -- Try to set it up for click-casting
        if not unitFrame:GetAttribute("unit") then
            unitFrame:SetAttribute("unit", unitToken)
        end
        return unitFrame
    end
    
    if self.db.options.debugBindings then
        print("  [Debug] No suitable clickable frame found for nameplate")
    end
    
    return nil
end

-- Register all currently visible nameplates
function CC:RegisterAllNameplates()
    if not self.db or not self.db.enabled then return end
    if not self.db.options.globalEnabled then return end
    
    -- Get all visible nameplates
    local nameplates = C_NamePlate.GetNamePlates()
    
    if self.db.options.debugBindings then
        print("|cff33cc66DF Nameplate:|r Registering " .. #nameplates .. " visible nameplates")
    end
    
    for _, nameplate in ipairs(nameplates) do
        local unitToken = nameplate.namePlateUnitToken
        if unitToken then
            self:OnNamePlateAdded(unitToken)
        end
    end
end

-- ============================================================
