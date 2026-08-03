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
    -- Unit-filtered to "player". This event carries a unit and fires for every
    -- party/raid member, and the handler runs CheckLoadoutProfileSwitch plus a
    -- full ApplyBindings -- the ~500-frame batched sweep. Unfiltered, every
    -- raid member respeccing cost a full sweep and the hover-bind window that
    -- comes with it, for a profile decision that only ever concerns us.
    eventFrame:RegisterUnitEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
    -- Roster churn is when frames are created and retired; see the handler.
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
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
                        CC:RefreshUIIfLoaded()
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
                    CC:RefreshUIIfLoaded()
                end)
            else
                CC:Defer("bindingRefresh")
            end
        elseif event == "PLAYER_EQUIPMENT_CHANGED" then
            -- Equipment changed - refresh items tab if visible. activeTab is only
            -- ever set by the companion, but guard the method explicitly rather
            -- than lean on that invariant.
            if CC.activeTab == "items" and CC.RefreshSpellGrid then
                CC:RefreshSpellGrid()
            end
        elseif event == "PLAYER_ENTERING_WORLD" then
            CC:ScheduleZoneSettle()
        elseif event == "GROUP_ROSTER_UPDATE" then
            -- Roster churn creates and retires frames -- including third-party
            -- ones, whose only route in is the ClickCastFrames table that cannot
            -- report a retry (see ReconcileClickCastFrames). This module used to
            -- register no roster event at all and relied entirely on the
            -- SecureUnitButton_OnLoad hook plus a login-only scan, which is how a
            -- party->raid change could leave frames dead until a /reload.
            if InCombatLockdown() then
                CC:Defer("bindingRefresh")
            else
                -- Keyed and delayed, NOT immediate. ApplyBindings cancels any
                -- in-flight batch walker and re-wipes the header's override
                -- bindings before restarting from batch 0. Calling it once per
                -- roster event means a burst -- a raid forming, mass join/leave,
                -- role assignment, zone-in -- can restart the sweep faster than
                -- it completes, and every restart kills the live hover binds
                -- again. That is the same dead-key class this whole change set
                -- exists to close, reached through a new trigger.
                --
                -- Nothing is lost by waiting: frames created during the roster
                -- event register through EnsureRegistered and the ClickCastFrames
                -- metatable, not through ApplyBindings, which only refreshes
                -- bindings on frames already registered. Same keyed-DeferAfter
                -- shape as zoneSettle, so a burst coalesces into one pass.
                CC:DeferAfter("rosterSettle", 0.5, function()
                    CC:ReconcileClickCastFrames()
                    CC:ApplyBindings()
                end)
            end
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

    -- Our own PLAYER_ENTERING_WORLD registration happens INSIDE the dispatch of
    -- that very event (Initialize is driven from a PEW handler elsewhere, which
    -- calls InitializeSecureFrames -> RegisterEvents), so this frame never
    -- receives the login PEW. Everything in the settle pass was therefore absent
    -- at login and first ran on the next loading screen: nameplate registration,
    -- the zone-in binding repair, and the cold-start profile resolve that exists
    -- specifically for "none of my binds work in my first arena of the day".
    -- Kick it once here; the key makes it idempotent against a real PEW landing
    -- immediately after.
    self:ScheduleZoneSettle()
end

-- The post-loading-screen settle pass, factored out so it can also be kicked
-- once at init (see the note at the end of RegisterEvents). Keyed: back-to-back
-- loading screens reuse one pending pass rather than stacking several.
function CC:ScheduleZoneSettle()
    CC:DeferAfter("zoneSettle", 0.5, function()
                -- NOTE (12.1 lane): the retail original also called
                -- CC:MigrateBindingsToRootSpells() here. That one-time rewrite was
                -- REMOVED on this lane (ClickCasting/Bindings.lua:300), so the call
                -- is deliberately dropped rather than ported -- it would be a nil
                -- call on every zone-in.
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
                --
                -- Distinct timer key from the TRAIT_CONFIG_UPDATED settle above:
                -- that callback also runs ApplyBindings and a UI refresh, so
                -- sharing a key let a loading screen cancel a pending talent
                -- reapply and strand every frame on the old loadout's macros.
                CC:DeferAfter("zoneLoadoutCheck", 1, function()
                    CC:CheckLoadoutProfileSwitch()
                end)
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
    -- First: the OnEnter snippet reads dfClickCastEnabled to decide whether to
    -- run at all, so a stale value makes everything below it pointless.
    "headerEnabled",
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

-- Per-frame bodies for the set jobs below. File-locals rather than closures
-- built per drain: the drain runs on every combat end, and a set can hold the
-- whole roster.
local function jobRegister(self, frame)
    self:RegisterFrame(frame)
end

local function jobUnregister(self, frame)
    self:UnregisterFrame(frame)
end

local function jobReassert(self, frame)
    if self.registeredFrames and self.registeredFrames[frame] then
        self:ApplyBindingsToFrameUnified(frame)
    end
end

-- Run a set job one frame at a time, isolating a failure to the frame that
-- caused it.
--
-- DrainDeferred pcalls the job as a whole, which stops one bad job killing the
-- jobs after it -- but inside a set that granularity is too coarse: the loop
-- aborts at the first error and every frame it had not reached yet is silently
-- dropped. The payload is cleared BEFORE run (see DrainDeferred), so those
-- frames are not retried at the next drain either; they are simply unregistered
-- for the session, which is the exact shape of the dead-bind bugs this whole
-- subsystem exists to prevent.
--
-- One frame erroring is survivable. Losing the rest of the roster because of it
-- is not.
local function forEachFrameSafe(self, frames, label, fn)
    for frame in pairs(frames) do
        local ok, err = pcall(fn, self, frame)
        if not ok then
            DF:DebugError("CLICK", "Deferred '%s' errored on one frame (the rest of the set still ran): %s",
                label, tostring(err))
        end
    end
end

local DEFERRED_JOBS = {
    -- Carries the enabled state SetEnabled could not write during lockdown.
    -- "last" wins: if the user toggled twice in one fight, the final state is
    -- the one they meant. Stored as a string because Defer treats a nil payload
    -- as "nothing queued", which would silently drop a toggle to OFF.
    headerEnabled = {
        kind = "value", policy = "last",
        run = function(self, state)
            if self.header then
                self.header:SetAttribute("dfClickCastEnabled", state == "on")
            end
        end,
    },
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
            forEachFrameSafe(self, frames, "register", jobRegister)
        end,
    },
    unregister = {
        kind = "set",
        run = function(self, frames)
            forEachFrameSafe(self, frames, "unregister", jobUnregister)
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
            forEachFrameSafe(self, frames, "reassert", jobReassert)
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
        -- forced: CombatGuard cannot carry RunBindingRepair's `force` argument
        -- into the queue, so a repair that was explicitly unconditional (the
        -- zone-in self-heal passes force=true) came back through the drain as a
        -- cooldown-gated one and could be dropped by any repair that happened to
        -- run in the 5s before combat ended. This job runs at most once per
        -- drain, so the cooldown buys nothing here and only loses repairs.
        run = function(self, reason) self:RunBindingRepair(reason, true) end,
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
-- Returns true when the job was queued. CombatGuard relies on that: a typo'd
-- job name must not read as "queued", or the caller aborts and the work is lost
-- with only an INFO line to show for it -- and INFO is exactly what the log's
-- eviction policy discards first.
-- Jobs that mean the opposite of each other. Queueing one must CANCEL the other
-- for that payload, because the queue is otherwise order-blind: both entries
-- survive, and DRAIN_ORDER alone decides the outcome -- so the later intent
-- loses whenever it happens to sit earlier in the order.
--
-- The case that bites is nameplates. Blizzard recycles a fixed pool of plate
-- frames, so within one fight the SAME frame object is legitimately removed and
-- re-added for different units. Both sets end up holding it, `register` drains
-- at slot 3 and `unregister` at slot 4, and the drain tears down a plate that is
-- on screen showing a live unit. The Blizzard-frame pair has the same shape from
-- a user toggling the option twice in combat: whatever they picked last, off
-- wins.
local OPPOSED_JOBS = {
    register          = "unregister",
    unregister        = "register",
    blizzardRegister  = "blizzardUnregister",
    blizzardUnregister = "blizzardRegister",
}

function CC:Defer(job, payload)
    local def = DEFERRED_JOBS[job]
    if not def then
        DF:DebugError("CLICK", "Defer: unknown job '%s' — work dropped", tostring(job))
        return false
    end

    self.deferred = self.deferred or {}

    -- Latest intent wins: drop the contradicting entry rather than letting
    -- DRAIN_ORDER arbitrate between two things the caller never asked for both of.
    local opposite = OPPOSED_JOBS[job]
    if opposite and self.deferred[opposite] ~= nil then
        local other = self.deferred[opposite]
        if type(other) == "table" then
            if payload ~= nil and other[payload] then
                other[payload] = nil
                DF:Debug("CLICK", "Defer: '%s' cancels queued '%s' for the same frame", job, opposite)
            end
        else
            self.deferred[opposite] = nil
            DF:Debug("CLICK", "Defer: '%s' cancels queued '%s'", job, opposite)
        end
    end

    if def.kind == "set" then
        local set = self.deferred[job]
        if type(set) ~= "table" then
            set = {}
            self.deferred[job] = set
        end
        if payload ~= nil then set[payload] = true end
    elseif def.kind == "value" then
        if def.policy == "first" and self.deferred[job] ~= nil then
            return true  -- keep the earliest value; still queued
        end
        self.deferred[job] = payload
    else
        self.deferred[job] = true
    end

    return true
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
                -- pcall'd: the payload is already gone, so an error inside one
                -- job must not (a) abandon it silently -- the old flag drains
                -- cleared AFTER the work, so a failure retried next combat end
                -- -- or (b) skip every job after it in DRAIN_ORDER. Report it
                -- and carry on; the queue keeps draining.
                local ok, wantsRefresh = pcall(DEFERRED_JOBS[job].run, self, payload)
                if not ok then
                    DF:DebugError("CLICK", "Deferred job '%s' errored during drain: %s",
                        job, tostring(wantsRefresh))
                elseif wantsRefresh then
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
            CC:RefreshUIIfLoaded()
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

-- ☠ The click-casting UI lives in the load-on-demand companion; this file is
-- resident. Every "refresh the panel" reaction to a talent/spec/level event
-- must go through this guard: with the panel never opened the method is nil,
-- and DeferAfter runs its callback raw inside a C_Timer, so an unguarded call
-- is a Lua error on every talent swap. A refresh with no UI is correctly a
-- no-op -- the panel builds itself from current state when it loads.
function CC:RefreshUIIfLoaded()
    if self.RefreshClickCastingUI then
        self:RefreshClickCastingUI()
    end
end

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
    -- Always abort in combat, even if Defer rejected the job name. "Fail loudly"
    -- on a bad name would mean letting the caller go on to touch secure state
    -- during lockdown, which errors -- strictly worse than dropping the work.
    -- Defer already logs an unknown job as an error, so it is not silent.
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
            CC:RefreshUIIfLoaded()
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
    
    if DF:DebugActive("CLICK") then
        DF:Debug("CLICK", "Nameplate: added for %s (%s)", tostring(UnitName(unitToken) or "Unknown"), tostring(unitToken))
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
            
            if DF:DebugActive("CLICK") then
                DF:Debug("CLICK", "Nameplate: registered frame: %s", tostring(clickableFrame:GetName() or "unnamed"))
            end
        else
            -- Queue for after combat
            self:Defer("register", clickableFrame)
        end
    else
        DF:DebugWarn("CLICK", "Nameplate: could not find clickable frame for %s", tostring(unitToken))
    end
end

-- Called when a nameplate is removed
function CC:OnNamePlateRemoved(unitToken)
    local frame = self.registeredNameplates[unitToken]
    
    if frame then
        DF:Debug("CLICK", "Nameplate: removed for %s", tostring(unitToken))
        
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
        if frame and DF:DebugActive("CLICK") then
            DF:Debug("CLICK", "Nameplate probe [%s] %s (%s) isButton=%s hasRegister=%s unit=%s",
                tostring(label), tostring(frame:GetName() or "unnamed"), tostring(frame:GetObjectType()),
                tostring(frame:IsObjectType("Button")), tostring(frame.RegisterForClicks ~= nil),
                tostring(frame:GetAttribute("unit") or frame.unit))
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
    
    DF:Debug("CLICK", "Nameplate: no suitable clickable frame found")
    
    return nil
end

-- ============================================================
-- BOOTSTRAP
-- ============================================================
-- ☠ This must stay resident. It used to live in ClickCasting/UI/BindingEditor,
-- which is now in the load-on-demand companion -- and the trigger below only
-- fires on the login/reload PLAYER_ENTERING_WORLD. A companion loaded on demand
-- has already missed it, and the zone-change firings are filtered out by the
-- flags, so click-casting would never have initialised at all.
--
-- CC:Initialize itself is in ClickCasting/Frames.lua and is resident too.
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
initFrame:SetScript("OnEvent", function(self, event, isInitialLogin, isReloadingUi)
    -- Only initialize on first load or reload, not zone changes
    if isInitialLogin or isReloadingUi then
        CC:Initialize()
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    end
end)

-- Register all currently visible nameplates
function CC:RegisterAllNameplates()
    if not self.db or not self.db.enabled then return end
    if not self.db.options.globalEnabled then return end
    
    -- Get all visible nameplates
    local nameplates = C_NamePlate.GetNamePlates()
    
    DF:Debug("CLICK", "Nameplate: registering %d visible nameplates", #nameplates)
    
    for _, nameplate in ipairs(nameplates) do
        local unitToken = nameplate.namePlateUnitToken
        if unitToken then
            self:OnNamePlateAdded(unitToken)
        end
    end
end

-- ============================================================
