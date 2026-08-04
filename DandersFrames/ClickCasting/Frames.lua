local addonName, DF = ...

-- Get module namespace
local CC = DF.ClickCast

-- Fallback for issecretvalue (may not exist in all WoW versions)
-- If it doesn't exist, create a function that returns false
local issecretvalue = issecretvalue or function(val) return false end

-- Local aliases for shared constants (defined in Constants.lua)
local DB_VERSION = CC.DB_VERSION
local PROFILE_TEMPLATE = CC.PROFILE_TEMPLATE
local GLOBAL_SETTINGS_TEMPLATE = CC.GLOBAL_SETTINGS_TEMPLATE
local DEFAULT_BINDING_COMBAT = CC.DEFAULT_BINDING_COMBAT
local BLIZZARD_FRAMES = CC.BLIZZARD_FRAMES
local BLIZZARD_BOSS_FRAMES = CC.BLIZZARD_BOSS_FRAMES
local BLIZZARD_ARENA_FRAMES = CC.BLIZZARD_ARENA_FRAMES

-- Local aliases for helper functions (defined in Profiles.lua)
local GetPlayerClass = function() return CC.GetPlayerClass() end
local GetDefaultProfileName = function() return CC.GetDefaultProfileName() end

-- INITIALIZATION
-- ============================================================

function CC:Initialize()
    -- Check if we're in combat - secure frames can't be created during combat
    if InCombatLockdown() then
        DF:Say("Click-casting loaded during combat", "it will initialise when combat ends", "WARN")
        -- Still initialize saved variables so settings are accessible
        self:InitializeSavedVariables()
        -- Register for combat end to retry
        local retryFrame = CreateFrame("Frame")
        retryFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        retryFrame:SetScript("OnEvent", function(f)
            f:UnregisterAllEvents()
            -- Retry initialization after combat
            C_Timer.After(0.5, function()
                if not self.secureFramesInitialized then
                    DF:Say("Combat ended - initializing click casting...")
                    self:InitializeSecureFrames()
                end
            end)
        end)
        return
    end
    
    self:InitializeSavedVariables()
    self:InitializeSecureFrames()
end

-- Separate saved variables initialization (safe to call in combat)
function CC:InitializeSavedVariables()
    if self.savedVariablesInitialized then return end
    
    -- Initialize saved variables if needed
    if not DandersFramesClickCastingDB then
        DandersFramesClickCastingDB = {
            dbVersion = DB_VERSION,
            global = CopyTable(GLOBAL_SETTINGS_TEMPLATE),
            classes = {},
        }
    end
    
    self.db = DandersFramesClickCastingDB
    
    -- Ensure global settings exist
    if not self.db.global then
        self.db.global = CopyTable(GLOBAL_SETTINGS_TEMPLATE)
    end
    
    -- Ensure new global options exist (migration for existing users)
    if self.db.global.disableWhileMounted == nil then
        self.db.global.disableWhileMounted = false
    end
    if self.db.global.disableWhileFlying == nil then
        self.db.global.disableWhileFlying = false
    end

    -- Retired: the persisted "re-wipe Blizzard's click-cast profile on every
    -- enable" flag (see the removal note in DisableBlizzardClickCast).
    -- Clearing is a one-time, explicitly confirmed action now.
    self.db.clearBlizzardOnEnable = nil

    -- Ensure classes table exists
    if not self.db.classes then
        self.db.classes = {}
    end
    
    -- ============================================================
    -- MIGRATION: Old flat DB to new profile-based structure
    -- ============================================================
    if not self.db.dbVersion or self.db.dbVersion < DB_VERSION then
        -- Check if we have old-style data to migrate
        if self.db.bindings or self.db.customMacros or self.db.options then
            DF:Say("Migrating to new profile system...")
            
            -- Create a Default profile with the existing data
            local class = GetPlayerClass()
            local defaultName = GetDefaultProfileName()
            if not self.db.classes[class] then
                self.db.classes[class] = {
                    profiles = {},
                    loadoutAssignments = {},
                    activeProfile = defaultName,
                }
            end
            
            -- Move existing data into the Default profile
            local defaultProfile = CopyTable(PROFILE_TEMPLATE)
            
            -- Migrate bindings
            if self.db.bindings then
                defaultProfile.bindings = CopyTable(self.db.bindings)
                -- These legacy bindings predate the higher-wins priority flip. The
                -- template is born flagged, so clear the flag here to let
                -- MigratePrioritiesLazy flip these old-scale values exactly once.
                defaultProfile._priorityHigherWinsV1 = nil
            end
            
            -- Migrate custom macros
            if self.db.customMacros then
                defaultProfile.customMacros = CopyTable(self.db.customMacros)
            end
            
            -- Migrate options
            if self.db.options then
                for k, v in pairs(self.db.options) do
                    if PROFILE_TEMPLATE.options[k] ~= nil or k == "enabled" or k == "castOnDown" or 
                       k == "viewLayout" or k == "viewSort" or k == "quickBindEnabled" or k == "smartResurrection" then
                        defaultProfile.options[k] = v
                    end
                end
            end
            
            -- Migrate enabled state
            if self.db.enabled ~= nil then
                defaultProfile.options.enabled = self.db.enabled
            end
            
            -- Save the migrated profile with class-specific name
            self.db.classes[class].profiles[defaultName] = defaultProfile
            
            -- Clean up old top-level data
            self.db.bindings = nil
            self.db.customMacros = nil
            self.db.options = nil
            self.db.enabled = nil
            
            DF:Say("Migration complete. Your bindings are now in the '" .. defaultName .. "' profile.")
        end
        
        self.db.dbVersion = DB_VERSION
    end
    
    -- ============================================================
    -- MIGRATION: Rename old "Default" profile to class-specific name
    -- ============================================================
    local classData = self:GetClassData()
    local defaultName = GetDefaultProfileName()
    
    -- Check if old "Default" profile exists but new class-specific default doesn't
    if classData.profiles["Default"] and not classData.profiles[defaultName] then
        -- Rename "Default" to class-specific name
        classData.profiles[defaultName] = classData.profiles["Default"]
        classData.profiles["Default"] = nil
        
        -- Update active profile if it was "Default"
        if classData.activeProfile == "Default" then
            classData.activeProfile = defaultName
        end
        
        -- Update loadout assignments
        if classData.loadoutAssignments then
            for specIndex, loadouts in pairs(classData.loadoutAssignments) do
                for loadoutID, assignedProfile in pairs(loadouts) do
                    if assignedProfile == "Default" then
                        loadouts[loadoutID] = defaultName
                    end
                end
            end
        end
        
        DF:Say("Renamed 'Default' profile to '" .. defaultName .. "'")
    end
    
    -- ============================================================
    -- Set up profile references
    -- ============================================================
    
    -- Ensure class-specific default profile exists
    if not classData.profiles[defaultName] then
        classData.profiles[defaultName] = self:CreateEmptyProfile()
    end
    
    -- Ensure active profile is valid
    if not classData.profiles[classData.activeProfile] then
        classData.activeProfile = defaultName
    end
    
    -- Get active profile
    self.profile = classData.profiles[classData.activeProfile]
    -- Flip legacy (pre-4.6) priorities to higher-wins on the active profile at
    -- login, before the legacy references below feed the flipped comparators.
    if self.MigratePrioritiesLazy then self:MigratePrioritiesLazy(self.profile) end

    -- Set up legacy references for compatibility (point to profile data)
    self.db.bindings = self.profile.bindings
    self.db.customMacros = self.profile.customMacros
    self.db.options = self.profile.options
    
    -- Ensure all default options exist in active profile
    if self.profile.options.enabled == nil then self.profile.options.enabled = false end  -- Disabled by default, opt-in
    if self.profile.options.castOnDown == nil then self.profile.options.castOnDown = true end
    if self.profile.options.quickBindEnabled == nil then self.profile.options.quickBindEnabled = true end
    if not self.profile.options.smartResurrection then self.profile.options.smartResurrection = "disabled" end
    if not self.profile.options.viewLayout then self.profile.options.viewLayout = "grid" end
    if not self.profile.options.viewSort then self.profile.options.viewSort = "sectioned" end
    
    -- Sync enabled state to legacy location
    self.db.enabled = self.profile.options.enabled
    
    -- Ensure consumables list exists
    if not self.profile.consumables then
        self.profile.consumables = {}
    end
    
    -- ============================================================
    -- Migrate bindings within the profile (same as before)
    -- ============================================================
    for _, binding in ipairs(self.profile.bindings) do
        -- Migrate old scope to new frames/fallback structure
        if binding.scope and not binding.frames then
            local oldScope = binding.scope
            
            if oldScope == "hovercast" then oldScope = "onhover" end
            if oldScope == "global" then oldScope = "targetcast" end
            
            if oldScope == "unitframes" then
                binding.frames = { dandersFrames = true, otherFrames = false }
                binding.fallback = { mouseover = false, target = false, selfCast = false }
            elseif oldScope == "blizzard" then
                binding.frames = { dandersFrames = true, otherFrames = true }
                binding.fallback = { mouseover = false, target = false, selfCast = false }
            elseif oldScope == "onhover" then
                binding.frames = { dandersFrames = true, otherFrames = true }
                binding.fallback = { mouseover = true, target = false, selfCast = false }
            elseif oldScope == "targetcast" then
                binding.frames = { dandersFrames = false, otherFrames = false }
                binding.fallback = { mouseover = false, target = true, selfCast = false }
            else
                binding.frames = { dandersFrames = true, otherFrames = true }
                binding.fallback = { mouseover = false, target = false, selfCast = false }
            end
            binding.scope = nil
        end
        
        -- Ensure frames and fallback exist
        if not binding.frames then
            binding.frames = { dandersFrames = true, otherFrames = true }
        end
        if not binding.fallback then
            binding.fallback = { mouseover = false, target = false, selfCast = false }
        end
        
        -- Migrate old loadCombat to new combat field
        if binding.loadCombat and not binding.combat then
            if binding.loadCombat == "combat" then
                binding.combat = "incombat"
            elseif binding.loadCombat == "nocombat" then
                binding.combat = "outofcombat"
            else
                binding.combat = "always"
            end
            binding.loadCombat = nil
        end
        
        if not binding.combat then
            binding.combat = DEFAULT_BINDING_COMBAT
        end
    end
    
    -- Add default bindings on first load (if no bindings exist)
    if #self.profile.bindings == 0 then
        table.insert(self.profile.bindings, {
            enabled = true,
            bindType = "mouse",
            button = "LeftButton",
            modifiers = "",
            actionType = "target",
            combat = "always",
            frames = { dandersFrames = true, otherFrames = true },
            fallback = { mouseover = true, target = false, selfCast = false },
        })
        table.insert(self.profile.bindings, {
            enabled = true,
            bindType = "mouse",
            button = "RightButton",
            modifiers = "",
            actionType = "menu",
            combat = "always",
            frames = { dandersFrames = true, otherFrames = true },
            fallback = { mouseover = true, target = false, selfCast = false },
        })
    end
    
    self.savedVariablesInitialized = true
end

-- Secure frame initialization (must be called out of combat)
function CC:InitializeSecureFrames()
    if self.secureFramesInitialized then return end
    
    if InCombatLockdown() then
        -- Queue for after combat
        local retryFrame = CreateFrame("Frame")
        retryFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        retryFrame:SetScript("OnEvent", function(f)
            f:UnregisterAllEvents()
            C_Timer.After(0.5, function()
                if not self.secureFramesInitialized then
                    self:InitializeSecureFrames()
                end
            end)
        end)
        return
    end
    
    -- Create the secure header frame
    self:CreateClickCastHeader()
    
    -- Create the hovercast button for global bindings (Clique-style)
    self:CreateHovercastButton()
    
    -- Set up frame ref so secure snippets can access the hovercast button
    if self.header and self.header.SetFrameRef and self.hovercastButton then
        self.header:SetFrameRef("hovercastButton", self.hovercastButton)
    end
    
    -- Set up ClickCastFrames global for addon compatibility
    self:SetupClickCastFramesGlobal()
    
    -- Check for conflicting addons
    self:CheckForConflictingAddons()
    
    -- Show conflict popup on load if enabled with conflicts
    if self.db.enabled and self.hasConflictingAddons and self.conflictingAddons then
        -- Delay slightly to ensure UI is ready
        C_Timer.After(1.5, function()
            if CC.db.enabled and CC.hasConflictingAddons then
                -- ☠ Read the opt-out FIRST. The popup lives in the companion and
                -- this fires at login, so loading it here is the cost -- but
                -- ShowClickCastConflictPopup's own first line is this same check
                -- and returns immediately. Without this, a user who ticked "don't
                -- warn me again" pulled the entire settings addon in at every
                -- login to reach a function that does nothing. The flag lives in
                -- DandersFramesClickCastingDB and is fully readable resident.
                if CC.db.ignoreConflictWarning then return end
                -- It is a modal the user must act on, so load rather than skip.
                -- Only users with a conflicting addon installed ever pay.
                if not CC.ShowClickCastConflictPopup then
                    if not (DF.EnsureOptionsLoaded and DF:EnsureOptionsLoaded()) then return end
                end
                CC:ShowClickCastConflictPopup(CC.conflictingAddons, CC.enableCb)
            end
        end)
    end
    
    -- Disable Blizzard's built-in click casting when our click casting is enabled
    self:DisableBlizzardClickCasting()
    
    -- Register for spec change events
    self:RegisterEvents()
    
    -- Set up hooks for dynamic Blizzard frames (boss/arena)
    self:SetupDynamicFrameHooks()

    -- Heal Blizzard click-setup clobbering (guided by Clique's reassert
    -- queue). SecureUnitButton_OnLoad runs on every CompactUnitFrame_SetUnit
    -- (roster shuffles, including during combat) and resets
    -- RegisterForClicks to "AnyUp" plus the *type1/*type2 wildcard actions —
    -- verified in Blizzard_FrameXML/SecureTemplates.lua 12.0.7. Down-click
    -- casting on Blizzard frames silently died on every roster change until
    -- something happened to reapply. Queue exactly the frames that were
    -- touched: out of combat a debounced drain re-applies right away, in
    -- combat OnCombatEnd picks the queue up. Covers third-party frames using
    -- the same template for free. hooksecurefunc post-hooks run insecurely,
    -- so this never taints the secure path.
    --
    -- SCOPE (traced 2026-07-20): this only fires for frames whose unit is set
    -- via CompactUnitFrame_SetUnit — i.e. Blizzard's own raid/party frames.
    -- DandersFrames' own children do NOT go through it: they are
    -- SecureUnitButtonTemplate frames whose clicks are registered once in
    -- InitializeHeaderChild (the template OnLoad, dfInitialized-guarded, runs
    -- once ever), and a roster shuffle only reassigns their `unit` attribute —
    -- RegisterForClicks and the click-cast attributes persist untouched. So DF
    -- frames need no reassert, and correctly get none.
    if not self.reassertHookInstalled then
        self.reassertHookInstalled = true
        hooksecurefunc("SecureUnitButton_OnLoad", function(frame)
            if not CC.registeredFrames or not CC.registeredFrames[frame] then return end
            if not (CC.db and CC.db.enabled) then return end
            CC:Defer("reassert", frame)
            -- Visible so a roster-reset reapply can be seen in the log (was
            -- silent). Guarded because this fires on every CompactUnitFrame_SetUnit
            -- roster shuffle: DF:Debug drops the line itself when debug is off, but
            -- its ARGUMENTS are evaluated first, so the GetName and tostring calls
            -- happened regardless. DebugActive rather than DF.debugEnabled so the
            -- args are also skipped when CLICK specifically is filtered off.
            if DF:DebugActive("CLICK") then
                DF:Debug("CLICK", "Reassert queued for %s (SecureUnitButton_OnLoad, combat=%s)",
                    frame:GetName() or "unnamed", tostring(InCombatLockdown()))
            end
            if not InCombatLockdown() then
                CC:DeferAfter("reassertDrain", 0.2, function()
                    CC:DrainDeferred("reassert")
                end)
            end
        end)
    end

    -- Mark as initialized BEFORE processing pending registrations
    self.secureFramesInitialized = true
    
    -- Process any frame registrations queued before init completed
    -- (reload in combat, or frames that showed up before secureFramesInitialized)
    self:DrainDeferred("register")
    
    -- Apply bindings
    self:ApplyBindings()
    
    -- Register Blizzard frames if any binding needs them (delayed to ensure frames exist)
    C_Timer.After(0.5, function()
        if self:AnyBindingNeedsBlizzardFrames() then
            self:RegisterBlizzardFrames()
        end
        
        -- Check if we should auto-switch profile based on current loadout
        -- (delayed to ensure talent data is available)
        C_Timer.After(0.5, function()
            self:CheckLoadoutProfileSwitch()
        end)
    end)
end

-- ============================================================

-- SECURE HEADER FRAME
-- ============================================================

function CC:CreateClickCastHeader()
    -- The ClickCastHeader is a secure frame that wraps unit frame OnEnter/OnLeave
    -- This is the approach used by Cell and Clique for in-combat keyboard bindings
    
    -- Validate, don't just presence-check. If this field ever holds a frame that
    -- is not a secure handler, the old `if self.header then return end` kept the
    -- impostor for the rest of the session and every hover bind stayed dead
    -- until a /reload. A frame with no WrapScript is not our header, so rebuild.
    if self.header then
        if self.header.WrapScript then return end
        DF:DebugError("CLICK", "CC.header held a non-secure frame (%s) — rebuilding the secure header",
            tostring((self.header.GetName and self.header:GetName()) or "unnamed"))
        self.header = nil
    end

    -- Don't create during combat
    if InCombatLockdown() then
        -- Keep retrying while combat lasts rather than giving up after one
        -- attempt; the header is required for every hover bind.
        CC:DeferAfter("createClickCastHeader", 1, function()
            CC:CreateClickCastHeader()
        end)
        return
    end
    
    -- Create the header frame with SecureHandlerStateTemplate for WrapScript capability
    local header
    
    -- Try creating with the template
    local success = pcall(function()
        header = CreateFrame("Frame", "DandersFramesClickCastHeader", UIParent, "SecureHandlerStateTemplate")
    end)
    
    if not success or not header then
        -- Fallback: try SecureHandlerBaseTemplate
        success = pcall(function()
            header = CreateFrame("Frame", "DandersFramesClickCastHeader", UIParent, "SecureHandlerBaseTemplate")
        end)
    end
    
    if not success or not header then
        -- Last resort: plain frame (keyboard bindings won't work in combat)
        DF:Say("Warning: Could not create secure header, keyboard bindings limited", nil, "WARN")
        header = CreateFrame("Frame", "DandersFramesClickCastHeader", UIParent)
    end
    
    self.header = header
    self.header:SetSize(1, 1)
    self.header:Hide()
    
    -- Set the enabled attribute (checked by OnEnter snippets to allow Clique/Clicked when disabled)
    self.header:SetAttribute("dfClickCastEnabled", self.db and self.db.enabled or false)
    
    -- Initialize secure environment variables
    -- mouseoverbutton tracks the currently hovered frame (handle, used ONLY
    -- for geometry checks in the state driver and identity comparisons).
    -- mouseovername mirrors it as a plain string for diagnostics, so no
    -- snippet ever needs to call a method on a possibly-stale handle.
    -- owner is a permanent handle to this header: ALL hover override bindings
    -- are owned by it (set/cleared through it), so clearing bindings never
    -- has to touch a unit-frame handle that may have gone stale. The header
    -- lives for the whole session, so owner can never dangle.
    if self.header.Execute then
        pcall(function()
            self.header:Execute([[
                owner = self
                mouseoverbutton = nil
                mouseovername = nil
            ]])
        end)
    end
    
    -- === MOUSEOVERSTATE DRIVER ===
    -- Clears bindings when there's no mouseover unit (e.g., a Blizzard panel
    -- opens over the frame, stealing focus without firing WrapScript OnLeave).
    --
    -- Guard uses BOTH IsUnderMouse() and GetMousePosition() — only clears if
    -- both report the cursor is off the frame; a false clear here silently
    -- wipes keyboard click-cast bindings mid-hover.
    --
    -- ⚠ DO NOT gate this clear on HANDLE:GetRect() being non-nil (tried in
    -- 4.7.4, reverted in 4.7.5): GetRect returns nil for ANCHORING-RESTRICTED
    -- frames, and protected unit frames are anchoring-restricted for the
    -- whole of combat — the gate silently disabled this driver in combat,
    -- removing the safety net that releases hover binds after a missed
    -- OnLeave. Stuck binds stole every DF-bound key until reload (the 4.7.4
    -- "keyboard unplugged" reports). IsUnderMouse/GetMousePosition do NOT
    -- perform the anchoring-restricted check, so they keep working in combat.
    -- The rect is still read below purely as a diagnostic.
    self.header:SetAttribute("_onstate-mouseoverstate", [[
        if newstate == "false" and mouseoverbutton then
            local l, b, w, h = mouseoverbutton:GetRect()
            local rectKnown = l and w and h and w > 0 and h > 0
            local underMouse = mouseoverbutton:IsUnderMouse()
            local x, y = mouseoverbutton:GetMousePosition()
            local inBounds = x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1

            -- Store diagnostics from all checks
            mouseoverbutton:SetAttribute("dfStateDriverCount", (mouseoverbutton:GetAttribute("dfStateDriverCount") or 0) + 1)
            mouseoverbutton:SetAttribute("dfStateDriverUnderMouse", tostring(underMouse))
            mouseoverbutton:SetAttribute("dfStateDriverRectKnown", tostring(rectKnown))
            mouseoverbutton:SetAttribute("dfSDMouseX", x)
            mouseoverbutton:SetAttribute("dfSDMouseY", y)

            -- Only clear bindings if BOTH cursor checks agree the cursor is
            -- off the frame (pre-4.7.4 semantics). Binds are owner-owned, so
            -- the header wipe (self here) is the release that matters; the
            -- frame-handle clear stays as defense-in-depth against any
            -- frame-owned stray. This snippet already method-calls
            -- mouseoverbutton for the geometry checks above, so that call
            -- adds no new stale-handle risk class (an abort here is
            -- self-limiting — it cannot poison OnEnter).
            if not underMouse and not inBounds then
                mouseoverbutton:SetAttribute("dfClearedBy", "statedriver")
                mouseoverbutton:ClearBindings()
                self:ClearBindings()
                mouseoverbutton:SetAttribute("dfBindingsActive", nil)
                mouseoverbutton:SetAttribute("dfIsSecureMouseover", nil)
                mouseoverbutton = nil
                mouseovername = nil
            end
        end
    ]])
    RegisterStateDriver(self.header, "mouseoverstate", "[@mouseover, exists] true; false")
    
    -- Track registered frames. Preserve an existing registry: this function is
    -- no longer called only once before anything is registered — the header
    -- validation above and the two recovery paths (SetupSecureHandlers,
    -- RewrapSecureHandlers) can re-enter it mid-session, and blanking the
    -- registry there would silently strip every Blizzard and third-party frame
    -- while leaving frame.dfClickCastRegistered true, so nothing would notice
    -- or re-register them.
    self.registeredFrames = self.registeredFrames or {}
    
    -- Store reference to module in header for secure snippets
    self.header.module = self
end

-- ============================================================

-- ADDON CONFLICT DETECTION
-- ============================================================

function CC:CheckForConflictingAddons()
    local conflicts = {}
    
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        if C_AddOns.IsAddOnLoaded("Clique") then
            table.insert(conflicts, "Clique")
        end
        if C_AddOns.IsAddOnLoaded("Clicked") then
            table.insert(conflicts, "Clicked")
        end
    elseif IsAddOnLoaded then
        if IsAddOnLoaded("Clique") then
            table.insert(conflicts, "Clique")
        end
        if IsAddOnLoaded("Clicked") then
            table.insert(conflicts, "Clicked")
        end
    end
    
    if #conflicts > 0 then
        -- Don't print warning - let the UI popup handle it
        self.hasConflictingAddons = true
        self.conflictingAddons = conflicts
        return true
    end
    
    self.hasConflictingAddons = false
    self.conflictingAddons = nil
    return false
end

-- ============================================================

-- DISABLE BLIZZARD CLICK CASTING
-- ============================================================

function CC:DisableBlizzardClickCasting()
    if not self.db.enabled then return end
    
    -- Blizzard's click casting is set via SetUnitFrameClickCastConfig
    -- and creates overlay frames. We need to clear/hide them.
    -- Only clear from frames that the user has configured bindings for.
    
    -- Hook into Blizzard's click cast system to prevent conflicts
    if not self.blizzardClickCastDisabled then
        -- (Removed) The clearBlizzardOnEnable auto re-wipe. Pressing "Clear
        -- Blizzard Bindings" once used to persist the flag and silently
        -- ResetCurrentProfile() — a PERMANENT wipe of the user's native
        -- click-cast profile — on every future enable. Clearing is now a
        -- one-time action taken only when the button is pressed (with a
        -- permanence warning in the dialog); the stored flag is stripped in
        -- InitializeSavedVariables.

        -- Clear any existing Blizzard click cast config on our frames
        if SetUnitFrameClickCastConfig then
            -- Hook to prevent Blizzard from setting click casts on frames we manage
            hooksecurefunc("SetUnitFrameClickCastConfig", function(frame, ...)
                if CC.db and CC.db.enabled and frame then
                    -- Check if this is a frame we've registered AND if we should clear it
                    if CC.registeredFrames and CC.registeredFrames[frame] then
                        if CC:ShouldClearBlizzardFromFrame(frame) then
                            -- Clear immediately and re-apply our bindings
                            CC:ClearBlizzardClickCastFromFrame(frame)
                            CC:ApplyBindingsToFrameUnified(frame)
                            -- And again on next frame in case Blizzard does something after
                            C_Timer.After(0, function()
                                -- ApplyBindingsToFrameUnified defers itself in
                                -- combat, so this no longer drops the work
                                if not InCombatLockdown() then
                                    CC:ClearBlizzardClickCastFromFrame(frame)
                                end
                                CC:ApplyBindingsToFrameUnified(frame)
                            end)
                        end
                    end
                end
            end)
        end
        
        -- Also hook UnitFrame_OnEnter to catch any click-cast setup on hover
        if UnitFrame_OnEnter then
            hooksecurefunc("UnitFrame_OnEnter", function(frame)
                if CC.db and CC.db.enabled and frame then
                    if CC.registeredFrames and CC.registeredFrames[frame] then
                        if CC:ShouldClearBlizzardFromFrame(frame) then
                            CC:ClearBlizzardClickCastFromFrame(frame)
                            CC:ApplyBindingsToFrameUnified(frame)
                        end
                    end
                end
            end)
        end
        
        -- Hook ClickBindingFrame if it exists (Blizzard's click-cast overlay system)
        if ClickBindingFrame and ClickBindingFrame.RegisterForClicks then
            -- Prevent ClickBindingFrame from registering clicks when over our frames
            hooksecurefunc(ClickBindingFrame, "Show", function(self)
                if CC.db and CC.db.enabled then
                    -- Version-safe: 12.x documents only GetMouseFoci (which is
                    -- topmost-first); GetMouseFocus is legacy. This was the one
                    -- unguarded call site left in the addon, and it sits inside a
                    -- secure hook that runs every time Blizzard's click-cast panel
                    -- opens -- so if the old global goes away it throws in there
                    -- and our own "hide it over our frames" protection never runs.
                    local mouseoverFrame
                    if GetMouseFoci then
                        mouseoverFrame = GetMouseFoci()[1]
                    elseif GetMouseFocus then
                        mouseoverFrame = GetMouseFocus()
                    end
                    if mouseoverFrame and CC.registeredFrames and CC.registeredFrames[mouseoverFrame] then
                        if CC:ShouldClearBlizzardFromFrame(mouseoverFrame) then
                            self:Hide()
                        end
                    end
                end
            end)
        end
        
        self.blizzardClickCastDisabled = true
    end
    
    -- Clear Blizzard click cast from registered frames (only those that need it)
    if self.registeredFrames then
        for frame in pairs(self.registeredFrames) do
            if self:ShouldClearBlizzardFromFrame(frame) then
                self:ClearBlizzardClickCastFromFrame(frame)
            end
        end
    end
    
    -- Re-apply our bindings to ensure they take precedence
    if self.secureFramesInitialized then
        C_Timer.After(0.1, function()
            -- ApplyBindings defers itself in combat, so the refresh is queued
            -- rather than dropped
            CC:ApplyBindings()
        end)
    end
end

-- Clear Blizzard's click cast overlay/settings from a specific frame
-- Record the frame's OWN click behaviour once, before anything of ours touches
-- it, so handing the frame back restores what was actually there instead of
-- assuming Blizzard's target/togglemenu. This matters for third-party unit frames
-- picked up via ClickCastFrames: some deliberately have no left-click target, and
-- hardcoding the default rewrote their behaviour permanently.
--
-- MUST be called unconditionally at registration, not only from
-- ClearBlizzardClickCastFromFrame. That path is gated on
-- ShouldClearBlizzardFromFrame (= AnyBindingNeedsOtherFrames for a
-- non-DandersFrame), so with every binding DandersFrames-scoped the capture never
-- ran, RestoreBlizzardDefaults fell back to the hardcoded defaults, and the bug
-- reproduced at registration -- no unregister cycle needed. Worse, if the user
-- later added an other-frames binding the gate opened and the capture recorded
-- OUR OWN type1="target" as the frame's original, making it permanently wrong
-- rather than merely absent.
--
-- `false` records "capture refused" (secret values) so this neither retries every
-- call nor lets the restore side trust a partial capture.
function CC:CaptureOriginalClickBindings(frame)
    if not frame or frame.dfOriginalClickBindings ~= nil then return end
    if not frame.GetAttribute then return end

    local t1, t2 = frame:GetAttribute("type1"), frame:GetAttribute("type2")
    local s1, s2 = frame:GetAttribute("*type1"), frame:GetAttribute("*type2")
    if issecretvalue(t1) or issecretvalue(t2) or issecretvalue(s1) or issecretvalue(s2) then
        frame.dfOriginalClickBindings = false
    else
        frame.dfOriginalClickBindings = {
            type1 = t1, type2 = t2, starType1 = s1, starType2 = s2,
        }
    end
end

function CC:ClearBlizzardClickCastFromFrame(frame)
    if not frame then return end
    if InCombatLockdown() then return end
    
    self:CaptureOriginalClickBindings(frame)

    -- Clear Blizzard's click-cast attributes
    -- Use empty string "" not nil - SecureUnitButtonTemplate defaults kick in with nil
    -- Setting to "" overrides the template defaults with "do nothing"
    frame:SetAttribute("type1", "")
    frame:SetAttribute("type2", "")
    frame:SetAttribute("unit1", nil)
    frame:SetAttribute("unit2", nil)
    
    -- Also clear common modifiers with empty string. Shared list so
    -- RestoreBlizzardDefaults undoes exactly these -- see the note on
    -- CC.BLIZZARD_SUPPRESSED_MODIFIERS in Constants.lua.
    for _, mod in ipairs(CC.BLIZZARD_SUPPRESSED_MODIFIERS) do
        frame:SetAttribute(mod .. "type1", "")
        frame:SetAttribute(mod .. "type2", "")
    end
    
    -- Aggressively disable click cast overlay frames
    -- These sit on top of unit frames and intercept clicks
    local function DisableOverlayPermanently(overlay)
        if not overlay then return end
        
        overlay:Hide()
        overlay:EnableMouse(false)
        overlay:SetAlpha(0)
        
        -- Hook Show to prevent Blizzard from re-showing
        if not overlay.dfShowHooked then
            overlay.dfShowHooked = true
            hooksecurefunc(overlay, "Show", function(self)
                if CC.db and CC.db.enabled then
                    self:Hide()
                end
            end)
        end
        
        -- Hook EnableMouse to prevent Blizzard from re-enabling
        if not overlay.dfEnableMouseHooked then
            overlay.dfEnableMouseHooked = true
            hooksecurefunc(overlay, "EnableMouse", function(self, enable)
                if CC.db and CC.db.enabled and enable then
                    self:EnableMouse(false)
                end
            end)
        end
    end
    
    -- Disable clickCastFrame overlay
    if frame.clickCastFrame then
        DisableOverlayPermanently(frame.clickCastFrame)
    end
    
    -- Disable ClickCastOverlay
    if frame.ClickCastOverlay then
        DisableOverlayPermanently(frame.ClickCastOverlay)
    end
    
    -- Check child frames for click cast overlays
    local children = {frame:GetChildren()}
    for _, child in ipairs(children) do
        local name = child:GetName()
        if name and (name:find("ClickCast") or name:find("clickcast")) then
            DisableOverlayPermanently(child)
        end
    end
end

-- Refresh Blizzard click-cast clearing based on current binding settings
-- Called when bindings are added/updated/removed to ensure correct frames are cleared
function CC:RefreshBlizzardClickCastClearing()
    if not self.db.enabled then return end
    if InCombatLockdown() then return end
    
    -- Clear Blizzard click cast from registered frames that need it
    if self.registeredFrames then
        for frame in pairs(self.registeredFrames) do
            if self:ShouldClearBlizzardFromFrame(frame) then
                self:ClearBlizzardClickCastFromFrame(frame)
            end
        end
    end
end

-- ============================================================

-- CLICKCASTFRAMES GLOBAL TABLE
-- ============================================================

-- A ClickCastFrames entry is only click-castable if it is an actual unit
-- frame: a Button/Frame carrying a "unit" attribute. Registration rewrites the
-- frame's click attributes to DF's macro/target actions, which BREAKS any
-- non-unit secure button that lands in the global table — a toy/action button
-- has no unit and can't receive unit-targeted casts anyway (bug #988,
-- ToyPicker's button had its type1 replaced). Frames whose unit is assigned
-- late (secure header children) are picked up by the next RegisterAllFrames
-- sweep once the attribute exists.
local function clickCastFrameEligible(frame)
    if type(frame) ~= "table" or not frame.GetObjectType or not frame.GetAttribute then
        return false
    end
    local objType = frame:GetObjectType()
    if objType ~= "Button" and objType ~= "Frame" then return false end
    local unit = frame:GetAttribute("unit")
    if issecretvalue(unit) then return false end
    return unit ~= nil
end

function CC:SetupClickCastFramesGlobal()
    -- If our click casting is disabled, DON'T set up our metatable
    -- This allows Clique/Clicked to set up their own metatable and work normally
    if not self.db or not self.db.enabled then
        -- Just ensure ClickCastFrames exists as a plain table
        if not ClickCastFrames then
            ClickCastFrames = {}
        end
        -- Don't interfere - Clique/Clicked can set up their own metatable
        return
    end
    
    -- Save any existing ClickCastFrames entries BEFORE we replace with metatable
    local existingFrames = {}
    if ClickCastFrames then
        for frame, enabled in pairs(ClickCastFrames) do
            if enabled and type(frame) == "table" then
                existingFrames[frame] = true
            end
        end
    end
    
    -- Create new metatable that auto-registers/unregisters frames
    -- This only runs when our click casting is ENABLED
    ClickCastFrames = setmetatable({}, {
        __newindex = function(t, frame, enabled)
            -- Always store the value in the table
            rawset(t, frame, enabled)
            
            -- Process registration since our click casting is enabled
            if CC.db and CC.db.enabled then
                if enabled == nil or enabled == false then
                    CC:UnregisterFrame(frame)
                elseif clickCastFrameEligible(frame) then
                    CC:RegisterFrame(frame)
                end
            end
        end
    })
    
    -- Re-register any frames that were already in ClickCastFrames
    for frame, enabled in pairs(existingFrames) do
        if enabled then
            rawset(ClickCastFrames, frame, true)
            CC:RegisterFrame(frame)
        end
    end
    
    -- Global reference for addon compatibility (like Clique)
    ClickCastHeader = self.header
    
    -- Schedule delayed scans for third-party frames that might have been created.
    -- This catches frames from addons that loaded before us or used different
    -- registration methods. Keyed separately so the early and late pass both
    -- run, but a second init cannot fork extra chains.
    CC:DeferAfter("thirdPartyScanEarly", 1, function()
        CC:ScanForThirdPartyFrames()
    end)
    CC:DeferAfter("thirdPartyScanLate", 3, function()
        CC:ScanForThirdPartyFrames()
    end)
end

-- Scan for known third-party unit frame addons and register their frames
function CC:ScanForThirdPartyFrames()
    if InCombatLockdown() then
        -- Keyed: previously every blocked call started its own 1s retry chain,
        -- so a long fight could leave several chains running in parallel.
        CC:DeferAfter("thirdPartyScanRetry", 1, function()
            CC:ScanForThirdPartyFrames()
        end)
        return
    end
    
    -- Known frame name patterns from popular unit frame addons
    local knownFramePatterns = {
        -- Unhalted Unit Frames
        "UUF_Player", "UUF_Target", "UUF_TargetTarget", "UUF_Pet", "UUF_Focus",
        "UUF_Boss1", "UUF_Boss2", "UUF_Boss3", "UUF_Boss4", "UUF_Boss5",
        
        -- NephUI (common patterns)
        "NephUI_Player", "NephUI_Target", "NephilemUI_Player", "NephilemUI_Target",
        
        -- SUF (Shadowed Unit Frames)
        "SUFUnitplayer", "SUFUnittarget", "SUFUnitfocus", "SUFUnitpet",
        "SUFUnittargettarget",
        
        -- Pitbull
        "PitBull4_Frames_Player", "PitBull4_Frames_Target",
        
        -- Z-Perl / X-Perl
        "XPerl_Player", "XPerl_Target", "XPerl_Focus",
        
        -- ElvUI (oUF based)
        "ElvUF_Player", "ElvUF_Target", "ElvUF_Focus", "ElvUF_Pet",
        "ElvUF_TargetTarget",
        
        -- Generic oUF patterns
        "oUF_Player", "oUF_Target", "oUF_Focus", "oUF_Pet",
    }
    
    local registered = 0
    for _, frameName in ipairs(knownFramePatterns) do
        local frame = _G[frameName]
        if frame and type(frame) == "table" and frame.GetAttribute then
            -- Check if it's a valid unit frame with a unit attribute
            local unit = frame:GetAttribute("unit")
            if unit and not self.registeredFrames[frame] then
                -- Check if it's a protected secure frame
                local isProtected = frame.IsProtected and frame:IsProtected()
                -- Bail if secret value (can't do boolean operations on it)
                if issecretvalue(isProtected) then
                    -- Skip this frame
                elseif isProtected then
                    self:RegisterFrame(frame)
                    rawset(ClickCastFrames, frame, true)
                    registered = registered + 1
                end
            end
        end
    end
    
    -- Also scan ClickCastFrames in case something was added via rawset
    if ClickCastFrames then
        for frame, enabled in pairs(ClickCastFrames) do
            if enabled and not self.registeredFrames[frame] and clickCastFrameEligible(frame) then
                self:RegisterFrame(frame)
                registered = registered + 1
            end
        end
    end
    
    if registered > 0 then
        DF:Debug("CLICK", "Registered %d third-party frames", registered)
    end
end

-- ============================================================

-- BLIZZARD FRAME REGISTRATION (Global Click-Casting)
-- ============================================================

-- Check if any binding requires Blizzard frames (now "Other Frames")
function CC:AnyBindingNeedsBlizzardFrames()
    for _, binding in ipairs(self.db.bindings) do
        if binding.enabled and self:ShouldBindingLoad(binding) then
            -- Check if binding applies to other frames
            local frames = binding.frames or { dandersFrames = true, otherFrames = true }
            if frames.otherFrames then
                return true
            end
            
            -- Check if binding has any fallback options (needs global keybinds)
            local fallback = binding.fallback or {}
            if fallback.mouseover or fallback.target or fallback.selfCast then
                return true
            end
        end
    end
    return false
end

-- Check if any binding applies to Other Frames (non-DandersFrames)
function CC:AnyBindingNeedsOtherFrames()
    for _, binding in ipairs(self.db.bindings) do
        if binding.enabled and self:ShouldBindingLoad(binding) then
            local frames = binding.frames or { dandersFrames = true, otherFrames = true }
            if frames.otherFrames then
                return true
            end
        end
    end
    return false
end

-- Check if we should clear Blizzard click-casting from a specific frame
-- When click-casting is enabled:
--   - Always clear from DandersFrames (our frames should be controlled by us)
--   - Only clear from Other Frames if user has bindings configured for them
function CC:ShouldClearBlizzardFromFrame(frame)
    if not frame then return false end
    if not self.db or not self.db.enabled then return false end
    
    local isDandersFrame = frame.dfIsDandersFrame == true
    
    if isDandersFrame then
        -- DandersFrames never have Blizzard click-casting applied to them.
        -- Our own ClearBindingsFromFrame (inside ApplyBindingsToFrameUnified)
        -- already handles full cleanup. Clearing type1 here would race with
        -- the batch processing that re-applies it, leaving frames with type1=""
        -- if combat starts before the batch reaches them.
        return false
    else
        -- Only clear from Other frames if user has bindings that apply to them
        return self:AnyBindingNeedsOtherFrames()
    end
end

-- ============================================================
-- BLIZZARD FRAME HEALTH/MANA BAR FIX
-- ============================================================
-- Blizzard frames have child frames (HealthBar, ManaBar) that intercept mouse events.
-- This prevents click-casting from working when hovering over those bars.
-- Solution: Use SetPropagateMouseMotion(true) to pass mouse events to parent frame.

-- Recursively search a frame's table for HealthBar and ManaBar keys
function CC:FindHealthManaBars(obj)
    local checked = {}
    local health = nil
    local mana = nil
    
    local function traverse(current)
        if type(current) ~= "table" then return end
        -- 12.x secret values: a protected frame/unit reference stored on a
        -- Blizzard frame passes the type()=="table" check but throws the moment
        -- it's used as a table key ("cannot be indexed with secret keys"). That
        -- aborted RegisterBlizzardFrames on combat end, so Blizzard frames never
        -- finished click-cast setup and bindings stopped working on them. We
        -- never need to descend into secret subtrees (health/mana bars are plain
        -- child frames), so skip them before `current` is used as a key below.
        if issecretvalue(current) then return end
        if checked[current] then return end

        checked[current] = true
        if not pcall(next, current) then return end
        for key, value in pairs(current) do
            if key == "HealthBar" or key == "healthBar" then
                health = value
            elseif key == "ManaBar" or key == "manaBar" or key == "PowerBar" or key == "powerBar" then
                mana = value
            elseif type(value) == "table" and key ~= "__index" then
                traverse(value)
            end
        end
    end
    
    traverse(obj)
    return health, mana
end

-- Fix a Blizzard frame so clicks on health/mana bars propagate to the parent
function CC:FixBlizzardFrameStatusBars(frame)
    if not frame then return end
    
    local health, mana = self:FindHealthManaBars(frame)
    
    if health then
        if health.SetPropagateMouseMotion then health:SetPropagateMouseMotion(true) end
        if health.SetPropagateMouseClicks then health:SetPropagateMouseClicks(true) end
    end
    if mana then
        if mana.SetPropagateMouseMotion then mana:SetPropagateMouseMotion(true) end
        if mana.SetPropagateMouseClicks then mana:SetPropagateMouseClicks(true) end
    end
    
    -- Also fix any child frames that might intercept mouse events/clicks
    -- This handles cases like PetFrame where anonymous children sit on top and eat clicks
    self:PropagateMouseOnChildren(frame)
end

-- Recursively set mouse propagation on all children of Blizzard unit frames
-- so that clicks pass through child overlays to reach the parent secure button.
-- This is only called on Blizzard unit frames (PlayerFrame, PetFrame, etc.)
-- so we can safely propagate on all non-forbidden children unconditionally —
-- none of the children (health bars, mana bars, portraits, anonymous overlays)
-- need to handle clicks independently.
function CC:PropagateMouseOnChildren(frame)
    if not frame or not frame.GetChildren then return end
    
    local children = {frame:GetChildren()}
    for _, child in ipairs(children) do
        -- Everything here is pcall'd, and anything unreadable counts as "leave it
        -- alone". This walk recurses over EVERY child of every Blizzard frame we
        -- take over, and it runs inside the PLAYER_ENTERING_WORLD settle callback:
        -- RegisterBlizzardFrames -> registerBlizzardFrame ->
        -- FixBlizzardFrameStatusBars -> here. So an error on one child did not
        -- merely skip that child, it aborted the rest of that callback -- taking
        -- ApplyGlobalBindings, RunBindingRepair("zone-in") and
        -- ResolveColdStartProfile down with it. An unguarded call that can kill
        -- our own recovery path is the worst possible place to be optimistic.
        --
        -- Both calls are known to be refusable: some frames stopped accepting
        -- SetPropagateMouseMotion in 12.0.5, and IsForbidden can itself throw or
        -- hand back a secret value on frames the client is protecting. The sibling
        -- walk FindHealthManaBars already guards secret values; this one did not.
        local readable, forbidden = pcall(function()
            return child.IsForbidden and child:IsForbidden()
        end)
        if not readable or issecretvalue(forbidden) or forbidden then
            -- Unreadable or forbidden: skip it, and do not recurse into it.
        else
            if child.SetPropagateMouseMotion then
                pcall(child.SetPropagateMouseMotion, child, true)
            end
            if child.SetPropagateMouseClicks then
                pcall(child.SetPropagateMouseClicks, child, true)
            end

            -- Recurse into children
            self:PropagateMouseOnChildren(child)
        end
    end
end

function CC:RegisterBlizzardFrames()
    if InCombatLockdown() then
        self:Defer("blizzardRegister")
        return
    end
    
    -- Frames skipped because the client returned secret values for the checks
    -- below. Counted so an incomplete pass can be distinguished from a complete
    -- one and retried -- see the end of this function. Re-running is safe:
    -- RegisterFrame early-returns on frames already in registeredFrames.
    local skippedSecret = 0

    -- Helper to validate and register a Blizzard frame
    local function registerBlizzardFrame(frameName)
        local frame = _G[frameName]
        if not frame then return end
        
        -- Never allow forbidden frames
        local forbidden = frame.IsForbidden and frame:IsForbidden()
        if forbidden then return end
        
        -- Validate frame is suitable for click-casting
        local buttonish = frame.RegisterForClicks ~= nil
        local protected = frame.IsProtected and frame:IsProtected()
        local name = frame.GetName and frame:GetName()
        local anchorRestricted = frame.IsAnchoringRestricted and frame:IsAnchoringRestricted()
        
        -- Bail out if any values are secret (can't do boolean operations on them)
        if issecretvalue(protected) or issecretvalue(name) or issecretvalue(anchorRestricted) then
            skippedSecret = skippedSecret + 1
            DF:DebugWarn("CLICK", "Blizzard frame %s skipped — client returned secret values for the suitability checks",
                tostring(frameName))
            return
        end
        
        local nameplateish = name and type(name) == "string" and name:match("^NamePlate")
        
        -- A frame must be a button, and must be protected, and must not be a nameplate or anchor restricted
        local valid = buttonish and protected and (not nameplateish) and (not anchorRestricted)
        
        if not valid then
            return
        end
        
        frame.dfIsBlizzardFrame = true
        -- Fix health/mana bar mouse event propagation
        CC:FixBlizzardFrameStatusBars(frame)
        self:RegisterFrame(frame)
    end
    
    -- Register static frames
    for _, frameName in ipairs(BLIZZARD_FRAMES) do
        registerBlizzardFrame(frameName)
    end
    
    -- Register boss frames (if they exist)
    for _, frameName in ipairs(BLIZZARD_BOSS_FRAMES) do
        registerBlizzardFrame(frameName)
    end
    
    -- Register arena frames (if they exist)
    for _, frameName in ipairs(BLIZZARD_ARENA_FRAMES) do
        registerBlizzardFrame(frameName)
    end
    
    -- Two separate facts, deliberately two separate fields.
    --
    -- blizzardFramesRegistered means "we have registered frames that need
    -- unregistering later". It must latch even on an incomplete pass, because
    -- UpdateBlizzardFrameRegistration's unregister branch is gated on it: if a
    -- partial pass left it unset, a user who later turned Blizzard-frame
    -- bindings off could never unregister the frames that DID register.
    --
    -- blizzardRegistrationPartial means "some frames were skipped, so a retry
    -- has work to do". It is what reopens the register branch, which would
    -- otherwise be closed by the flag above. Frames that are simply absent do
    -- not count -- there is nothing to retry for those.
    self.blizzardFramesRegistered = true
    if skippedSecret > 0 then
        self.blizzardRegistrationPartial = true
        DF:DebugWarn("CLICK", "Blizzard frame registration incomplete (%d skipped on secret values) — will retry",
            skippedSecret)
    else
        self.blizzardRegistrationPartial = nil
    end
end

function CC:UnregisterBlizzardFrames()
    if InCombatLockdown() then
        self:Defer("blizzardUnregister")
        return
    end
    
    -- Unregister static frames
    for _, frameName in ipairs(BLIZZARD_FRAMES) do
        local frame = _G[frameName]
        if frame then
            self:UnregisterFrame(frame)
        end
    end
    
    -- Unregister boss frames
    for _, frameName in ipairs(BLIZZARD_BOSS_FRAMES) do
        local frame = _G[frameName]
        if frame then
            self:UnregisterFrame(frame)
        end
    end
    
    -- Unregister arena frames
    for _, frameName in ipairs(BLIZZARD_ARENA_FRAMES) do
        local frame = _G[frameName]
        if frame then
            self:UnregisterFrame(frame)
        end
    end
    
    self.blizzardFramesRegistered = false
    -- Nothing is registered any more, so there is no partial pass left to retry.
    self.blizzardRegistrationPartial = nil
end

-- Update Blizzard frame registration based on current bindings
function CC:UpdateBlizzardFrameRegistration()
    local needsBlizzard = self:AnyBindingNeedsBlizzardFrames()
    
    -- blizzardRegistrationPartial reopens the register branch after a pass that
    -- skipped frames on secret values, without unsetting blizzardFramesRegistered
    -- (which the unregister branch below depends on).
    if needsBlizzard and (not self.blizzardFramesRegistered or self.blizzardRegistrationPartial) then
        if not InCombatLockdown() then
            self:RegisterBlizzardFrames()
        else
            self:Defer("blizzardRegister")
        end
    elseif not needsBlizzard and self.blizzardFramesRegistered then
        if not InCombatLockdown() then
            self:UnregisterBlizzardFrames()
        else
            self:Defer("blizzardUnregister")
        end
    end
    
    -- (No nameplate pass here: nameplate registration is driven entirely by
    -- NAME_PLATE_UNIT_ADDED/REMOVED. There used to be an `if needsNameplates`
    -- block with two empty branches, reading an undeclared global that nothing
    -- ever assigned -- it advertised a re-registration pass that did not exist.)
end

-- ============================================================

-- DYNAMIC FRAME HOOKS (Boss/Arena frames that appear mid-combat)
-- ============================================================

function CC:SetupDynamicFrameHooks()
    -- Hook boss frame show events
    for _, frameName in ipairs(BLIZZARD_BOSS_FRAMES) do
        local frame = _G[frameName]
        if frame and not frame.dfHooked then
            frame:HookScript("OnShow", function(self)
                if CC.db.options.globalEnabled then
                    if not CC:CombatGuard("register", self) then
                        CC:RegisterFrame(self)
                    end
                end
            end)
            frame.dfHooked = true
        end
    end
    
    -- Hook arena frame show events
    for _, frameName in ipairs(BLIZZARD_ARENA_FRAMES) do
        local frame = _G[frameName]
        if frame and not frame.dfHooked then
            frame:HookScript("OnShow", function(self)
                if CC.db.options.globalEnabled then
                    if not CC:CombatGuard("register", self) then
                        CC:RegisterFrame(self)
                    end
                end
            end)
            frame.dfHooked = true
        end
    end
    
    -- Boss and arena frames are created lazily, so retry while any are still
    -- unhooked. This previously re-armed unconditionally every 2 seconds for
    -- the entire session, and because the timer was not keyed, a second call
    -- to this function forked another chain that also ran forever.
    local pending = false
    for _, list in ipairs({ BLIZZARD_BOSS_FRAMES, BLIZZARD_ARENA_FRAMES }) do
        for _, frameName in ipairs(list) do
            local frame = _G[frameName]
            if not frame or not frame.dfHooked then
                pending = true
                break
            end
        end
        if pending then break end
    end

    if pending then
        CC:DeferAfter("dynamicFrameHooks", 2, function()
            CC:SetupDynamicFrameHooks()
        end)
    end
end

-- Build a virtual button name from binding (like Cell's approach: "shiftQ", "ctrlF1", etc.)
function CC:GetVirtualButtonName(binding)
    local parts = {}
    
    -- Add modifiers in lowercase (Cell's format)
    if binding.modifiers and binding.modifiers ~= "" then
        local mods = binding.modifiers:lower()
        if mods:find("alt") then table.insert(parts, "alt") end
        if mods:find("ctrl") then table.insert(parts, "ctrl") end
        if mods:find("shift") then table.insert(parts, "shift") end
        if mods:find("meta") then table.insert(parts, "meta") end  -- Mac Command key
    end
    
    -- Add the key/button
    local key = ""
    if binding.bindType == "mouse" and binding.button then
        -- Mouse binding - convert to "mouse1", "mouse2", etc.
        local buttonNum
        if binding.button == "LeftButton" then
            buttonNum = "1"
        elseif binding.button == "RightButton" then
            buttonNum = "2"
        elseif binding.button == "MiddleButton" then
            buttonNum = "3"
        else
            buttonNum = binding.button:match("Button(%d+)") or binding.button:match("button(%d+)")
        end
        
        if buttonNum then
            key = "mouse" .. buttonNum
        else
            key = CC:EncodeKeyToken(binding.button)
        end
    elseif binding.bindType == "scroll" then
        key = binding.key == "SCROLLUP" and "scrollup" or "scrolldown"
    else
        -- Keyboard binding - prefix with "key" to avoid conflict with mouse button numbers
        -- e.g., key "5" becomes "key5", key "Q" becomes "keyq". EncodeKeyToken
        -- matches the old :lower() byte-for-byte on alphanumeric keys;
        -- international (æ, ø, å, ...) and punctuation keys get an ASCII-safe
        -- encoding so their raw bytes never enter the virtual button /
        -- attribute names (bug #977).
        key = "key" .. CC:EncodeKeyToken(binding.key)
    end
    table.insert(parts, key)
    
    return table.concat(parts, "")
end

-- ============================================================

-- FRAME REGISTRATION
-- ============================================================

-- Register a unit frame for click-casting
function CC:RegisterFrame(frame)
    if not frame then return end

    -- Don't do anything if our click casting is disabled
    -- This allows Clique/Clicked to fully control the frame
    if not self.db or not self.db.enabled then
        return
    end

    -- Ensure registeredFrames table exists (may be called before full init)
    if not self.registeredFrames then
        self.registeredFrames = {}
    end

    if self.registeredFrames[frame] then return end

    -- Don't register during combat OR if secure frames aren't initialized yet
    -- (init drains the "register" job once secureFramesInitialized flips)
    if InCombatLockdown() or not self.secureFramesInitialized then
        self:Defer("register", frame)
        return
    end
    
    -- Capture the frame's own click behaviour BEFORE anything below touches it --
    -- unconditionally, because every path that follows (the gated Blizzard clear,
    -- SetupSecureHandlers, ApplyBindingsToFrameUnified) can write click attributes.
    -- This is where the old empty `dfOriginalClickBindings = {}` stub sat, and it
    -- was the right place; it just never recorded anything.
    self:CaptureOriginalClickBindings(frame)

    -- Mark as registered
    self.registeredFrames[frame] = true
    frame.dfClickCastRegistered = true
    
    -- Hook OnEnter to hide Blizzard's ClickBindingFrame when hovering our frames
    if not frame.dfClickBindingHooked then
        frame.dfClickBindingHooked = true
        frame:HookScript("OnEnter", function(self)
            if CC.db and CC.db.enabled then
                -- Hide Blizzard's global click-cast overlay
                if ClickBindingFrame and ClickBindingFrame:IsShown() then
                    ClickBindingFrame:Hide()
                end
                -- Also disable it from showing while we're hovered
                if ClickBindingFrame then
                    ClickBindingFrame:EnableMouse(false)
                end
            end
        end)
        frame:HookScript("OnLeave", function(self)
            -- Re-enable ClickBindingFrame when leaving (for other addons/frames)
            if ClickBindingFrame then
                ClickBindingFrame:EnableMouse(true)
            end
        end)
    end
    
    -- Clear any Blizzard click casting on this frame (only non-DandersFrames need this)
    if self:ShouldClearBlizzardFromFrame(frame) then
        self:ClearBlizzardClickCastFromFrame(frame)
    end
    
    -- IMPORTANT: Build macro map FIRST so we have bindings to apply
    if not self.unifiedMacroMap then
        self.unifiedMacroMap = self:BuildUnifiedMacroMap()
    end
    
    -- Set up secure handlers for keyboard bindings using WrapScript
    -- This creates the WrapScript that reads binding attributes at runtime
    self:SetupSecureHandlers(frame)
    
    -- Apply mouse bindings (type1, macrotext1, etc.)
    self:ApplyBindingsToFrameUnified(frame)
    
    -- Apply keyboard binding attributes (dfBind1Key, dfBind1Btn, etc.)
    -- The WrapScript will read these when OnEnter fires
    self:UpdateFrameBindingAttributes(frame)
end

-- ============================================================
-- BINDING STATE WATCHDOG TICKER
-- Polls dfBindingsActive every 200ms while a keyboard-bound frame is hovered.
-- NOT purely diagnostic: as well as logging the moment binds vanish or the
-- mouseoverbutton desyncs, it TRIGGERS RunBindingRepair for both — this is a
-- live self-heal path (the "mouseover-desync" repair fires from here in the
-- field). Do not gate it behind debug mode or remove it as "just logging":
-- the verbose logging no-ops out of debug, but the repair triggers must run
-- for everyone. It makes no protected calls itself (attribute reads only);
-- RequestBindingRepair defers/cooldowns the actual secure work.
-- ============================================================


local DIAG_INTERVAL = 0.2  -- seconds between polls

function CC:StartDiagnosticTicker(frame)
    self:StopDiagnosticTicker()

    local frameName = frame:GetName() or "unnamed"
    self.diagTickerFrame = frame
    self.diagLastBindState = frame:GetAttribute("dfBindingsActive") and true or false
    self.diagTickCount = 0

    self.diagTicker = C_Timer.NewTicker(DIAG_INTERVAL, function()
        -- Stop if frame is no longer hovered
        if CC.currentHoveredFrame ~= frame then
            CC:StopDiagnosticTicker()
            return
        end

        CC.diagTickCount = (CC.diagTickCount or 0) + 1
        local bindingsActive = frame:GetAttribute("dfBindingsActive") and true or false
        local wrapEnterCount = frame:GetAttribute("dfWrapEnterCount") or 0
        local wrapLeaveCount = frame:GetAttribute("dfWrapLeaveCount") or 0

        -- Check if the restricted environment still considers this frame the mouseoverbutton
        -- dfIsSecureMouseover is set to true on WrapScript OnEnter, cleared when another frame enters
        local isSecureMouseover = frame:GetAttribute("dfIsSecureMouseover") and true or false

        -- Detect transition: bindings were active, now they're not.
        --
        -- Only meaningful while this frame is STILL the one the cursor is on. The
        -- ticker polls one frame, and a fast sweep across the raid grid leaves it
        -- polling a frame the cursor has already left -- whose binds the state
        -- driver then legitimately cleared. That is correct behaviour being read as
        -- a fault: it logged BINDINGS VANISHED and requested a repair that
        -- re-wrapped every registered frame, for nothing (field log 2026-07-27,
        -- nine enter/leave pairs inside one second).
        local stillOurs = (CC.currentHoveredFrame == frame) and frame:IsMouseOver()
        if CC.diagLastBindState and not bindingsActive and stillOurs then
            DF:DebugError("CLICK", "BINDINGS VANISHED on %s at tick %d! wrapEnter=%d wrapLeave=%d isSecureMO=%s visible=%s mouseOver=%s combat=%s",
                frameName, CC.diagTickCount, wrapEnterCount, wrapLeaveCount, tostring(isSecureMouseover),
                tostring(frame:IsVisible()), tostring(frame:IsMouseOver()), tostring(InCombatLockdown()))
            CC:RequestBindingRepair("bindings-vanished")
        end

        -- Detect mouseoverbutton desync: we think we're hovering this frame,
        -- but the restricted environment no longer considers it the mouseoverbutton
        -- (some other frame's WrapScript OnEnter fired and took ownership)
        if not isSecureMouseover then
            -- The latch suppresses only the LOG. It used to gate the repair
            -- request too, and it is cleared only when the desync ends -- which
            -- cannot happen while the desync persists -- so if that single
            -- REPORT ONLY -- deliberately no repair request.
            --
            -- This fires when dfIsSecureMouseover is falsy, which since the OnShow
            -- wrap landed is almost always one of two benign things: a non-motion
            -- enter (Blizzard skips the snippet, and OnShow now covers the case a
            -- repair never could), or the state driver having legitimately cleared
            -- a frame the cursor already swept off. A repair cannot fix either, and
            -- asking for one cost a teardown of every registered frame -- which is
            -- how this detector came to CAUSE the outage it was watching for. The
            -- latch keeps it to one line per episode.
            if not CC.diagDesyncReported then
                CC.diagDesyncReported = true
                DF:DebugError("CLICK", "MOUSEOVERBUTTON DESYNC on %s at tick %d! dfIsSecureMouseover=nil wrapEnter=%d wrapLeave=%d kbActive=%s",
                    frameName, CC.diagTickCount, wrapEnterCount, wrapLeaveCount, tostring(bindingsActive))
            end
        else
            CC.diagDesyncReported = nil
        end

        CC.diagLastBindState = bindingsActive
    end)
end

function CC:StopDiagnosticTicker()
    if self.diagTicker then
        self.diagTicker:Cancel()
        self.diagTicker = nil
    end
    self.diagTickerFrame = nil
    self.diagTickCount = nil
    self.diagLastBindState = nil
    self.diagDesyncReported = nil
end

-- Bounded retry for the two ways hover-handler setup can fail without erroring
-- (no secure header, or WrapScript itself refusing). Both used to re-arm every
-- 2s forever with a log line per pass: across 40 raid frames that is ~20 lines a
-- second indefinitely, which buries the very diagnosis the log exists for.
--
-- Retry a few times, then give up ONCE, loudly. Giving up leaves
-- dfKeyboardHandlersSetup unset, so a later organic trigger (zone-in
-- registration, a repair) can still pick the frame up -- this bounds the noise,
-- it does not permanently abandon the frame the way the pre-4.9 code did.
--
-- Returns true when a retry was scheduled, false when the attempt budget is
-- spent (the caller should just return either way).
local WRAP_RETRY_LIMIT = 5
local WRAP_RETRY_DELAY = 2

function CC:ScheduleWrapRetry(frame, frameName, reason)
    frame.dfWrapRetries = (frame.dfWrapRetries or 0) + 1

    if frame.dfWrapRetries > WRAP_RETRY_LIMIT then
        if not frame.dfWrapRetryGaveUp then
            frame.dfWrapRetryGaveUp = true
            DF:DebugError("CLICK", "Hover-bind setup for %s failed %d times (%s) — giving up; no more retries will be logged for this frame",
                frameName, WRAP_RETRY_LIMIT, tostring(reason))
        end
        return false
    end

    DF:DebugWarn("CLICK", "Hover-bind setup for %s failed (%s) — retry %d/%d in %ds",
        frameName, tostring(reason), frame.dfWrapRetries, WRAP_RETRY_LIMIT, WRAP_RETRY_DELAY)
    self:DeferAfter("wrapRetry:" .. frameName, WRAP_RETRY_DELAY, function()
        CC:SetupSecureHandlers(frame)
    end)
    return true
end

-- Set up keyboard binding handlers for a frame using override bindings
-- This uses SetOverrideBindingClick to temporarily bind keyboard keys when hovering
function CC:SetupSecureHandlers(frame)
    if not frame then return end
    if InCombatLockdown() then return end
    
    -- Skip if already set up
    if frame.dfKeyboardHandlersSetup then return end
    
    local frameName = frame:GetName()
    if not frameName then return end
    
    -- === WrapScript Approach ===
    -- With SetPropagateMouseMotion(true) on child elements (auras, defensive icons),
    -- OnLeave only fires when truly leaving to the 3D world, not when hovering children.
    -- This allows us to safely clear bindings on OnLeave.
    
    -- No secure header means no hover binds at all on this frame. This used to
    -- fall straight through to the insecure hooks and still mark the frame as
    -- set up, so the frame reported handlersSetup=true with enterCount=0 forever
    -- (the "HOVER BUT NO KB BINDINGS / OnEnter DID NOT FIRE" signature) and no
    -- retry was ever scheduled, because nothing errored. Treat it like the
    -- WrapScript failure below: say so, and retry -- but bounded (see
    -- WRAP_RETRY_LIMIT), because an unbounded 2s re-arm across 40 raid frames is
    -- a log flood, and the log is how these get diagnosed.
    if not (self.header and self.header.WrapScript) then
        if not self:ScheduleWrapRetry(frame, frameName, "no secure header") then return end
        self:CreateClickCastHeader()
        return
    end

    if self.header and self.header.WrapScript then
        -- WrapScript OnEnter: Set up bindings
        --
        -- OWNERSHIP: hover binds are HEADER-owned, for real this time — the
        -- binding snippet is executed via control:RunFor(self, snippet),
        -- which runs in the header's environment (where `owner` = the header
        -- handle) with self rebound to this frame. 4.7.4 used self:Run(),
        -- which executes in the FRAME's environment, so its "header
        -- ownership" never existed and every release cleared the wrong owner.
        --
        -- HANDLE-SAFETY INVARIANT (restored): this snippet never calls a
        -- method on any handle except `self` (always fresh — the frame just
        -- entered), `owner` (the header, alive all session), and `control`
        -- (the wrapping header). The previous frame's binds need no
        -- cross-frame handle call: they are owner-owned, so the Phase 3
        -- owner wipe releases them without touching a possibly-stale handle
        -- (the pre-4.7.4 bug #976 abort class). Diagnostics read the
        -- mouseovername string mirror rather than the shared handle.
        local onEnterSnippet = [[
            -- Phase 0: Reset tracking for this enter cycle
            -- dfBindingsActive is cleared FIRST so a stale true from the previous
            -- enter can't fool us. It only gets set back to true at the very end.
            self:SetAttribute("dfBindingsActive", nil)
            self:SetAttribute("dfClearedBy", nil)
            self:SetAttribute("dfStateDriverCount", nil)
            self:SetAttribute("dfStateDriverUnderMouse", nil)
            self:SetAttribute("dfStateDriverRectKnown", nil)
            self:SetAttribute("dfSDMouseX", nil)
            self:SetAttribute("dfSDMouseY", nil)
            self:SetAttribute("dfEnterPhase", 0)

            -- Phase 1: increment WrapScript enter counter
            local wrapCount = (self:GetAttribute("dfWrapEnterCount") or 0) + 1
            self:SetAttribute("dfWrapEnterCount", wrapCount)
            self:SetAttribute("dfEnterPhase", 1)

            -- Phase 2: store what was hovered before us (string mirror, so no
            -- method call on the possibly-stale previous handle)
            self:SetAttribute("dfSecurePrevMouseover", mouseovername or "nil")
            self:SetAttribute("dfEnterPhase", 2)

            -- Phase 3: Wipe ALL hover binds owner-side. Binds are owner-owned
            -- (set via control:RunFor in Phase 6), so this single wipe covers
            -- the previous frame's binds too — including a stale frame whose
            -- OnLeave never fired — without any cross-frame handle call.
            owner:ClearBindings()
            self:SetAttribute("dfEnterPhase", 3)

            -- Phase 4: Set mouseoverbutton
            mouseoverbutton = self
            mouseovername = self:GetName() or "unnamed"
            self:SetAttribute("dfIsSecureMouseover", true)
            self:SetAttribute("dfEnterPhase", 4)

            -- Phase 5: Clear any legacy frame-owned bindings (self is always
            -- a fresh handle here, so this cannot dangle)
            self:ClearBindings()
            self:SetAttribute("dfEnterPhase", 5)

            -- Phase 6: Run the binding snippet — via control:RunFor, NOT
            -- self:Run. RunFor executes in the header's environment (where
            -- `owner` is the header handle) with self = this frame; Run
            -- executes in the FRAME's environment, which is how 4.7.4's
            -- ownership silently broke. Binds become owner-owned, targeting
            -- self.
            local snippet = self:GetAttribute("dfBindingSnippet")
            if snippet and snippet ~= "" then
                control:RunFor(self, snippet)
                self:SetAttribute("dfBindingsActive", true)
                self:SetAttribute("dfEnterPhase", 6)
            else
                self:SetAttribute("dfBindingsActive", false)
            end

            -- Phase 7: Post-completion verification
            -- Check that mouseoverbutton still points to self after everything ran
            if mouseoverbutton == self then
                self:SetAttribute("dfPostCheck", "ok")
            elseif mouseoverbutton then
                -- mouseoverbutton changed to a DIFFERENT frame during OnEnter
                self:SetAttribute("dfPostCheck", mouseovername or "other")
            else
                -- mouseoverbutton is nil — something wiped it during OnEnter
                self:SetAttribute("dfPostCheck", "nil")
            end
            self:SetAttribute("dfEnterPhase", 7)
        ]]

        -- WrapScript OnLeave: Clear bindings when leaving frame
        -- With SetPropagateMouseMotion(true) on child elements (auras),
        -- OnLeave only fires when truly leaving to the 3D world
        local onLeaveSnippet = [[
            -- Debug: increment WrapScript leave counter
            local leaveCount = (self:GetAttribute("dfWrapLeaveCount") or 0) + 1
            self:SetAttribute("dfWrapLeaveCount", leaveCount)

            -- Debug: store who mouseoverbutton points to when leave fires
            -- (string mirror — never a method call on the shared handle)
            self:SetAttribute("dfMouseoverOnLeave", mouseovername or "nil")
            -- Store whether the mouseoverbutton==self check will pass
            self:SetAttribute("dfLeaveCheckPassed", mouseoverbutton == self)

            if mouseoverbutton == self then
                self:SetAttribute("dfClearedBy", "onleave")
                -- Binds are owner-owned; owner:ClearBindings() is the release
                -- that matters. self:ClearBindings() stays as defense-in-depth
                -- against any frame-owned stray (self is always fresh here) —
                -- an ownership mismatch must never strand keys again.
                self:ClearBindings()
                owner:ClearBindings()
                self:SetAttribute("dfBindingsActive", nil)
                self:SetAttribute("dfIsSecureMouseover", nil)
                mouseoverbutton = nil
                mouseovername = nil
            end
        ]]
        
        -- WrapScript OnHide: Clear bindings when frame is hidden during combat
        -- This runs in the restricted (secure) environment, so it can call
        -- ClearBindings() even during combat — unlike HookScript OnHide.
        -- Covers the case where a frame is hidden while hovered (e.g., party
        -- member leaves group, pet dies) and OnLeave doesn't fire.
        local onHideSnippet = [[
            if mouseoverbutton == self then
                self:SetAttribute("dfClearedBy", "onhide")
                self:ClearBindings()
                owner:ClearBindings()
                self:SetAttribute("dfBindingsActive", nil)
                self:SetAttribute("dfIsSecureMouseover", nil)
                mouseoverbutton = nil
                mouseovername = nil
            end
        ]]

        -- OnShow: the ONLY combat-legal way to claim a frame that becomes visible
        -- under a resting cursor.
        --
        -- Blizzard's Wrapped_OnEnter runs our snippet only `if (motion)` --
        -- i.e. only when the enter was caused by physical cursor movement
        -- (RestrictedAddOnEnvironment/SecureHandlers.lua). A frame that APPEARS
        -- under a stationary cursor therefore gets no snippet and no hover binds,
        -- while the insecure OnEnter hook still fires -- which is why the log
        -- reads wrapEnter=false(0) with mouseOver=true and wrapApplied=true. It
        -- compounds: Wrapped_OnLeave requires both motion AND the _wrapentered
        -- attribute that only that skipped block sets, so the matching leave is
        -- disarmed too and a previous frame's binds can survive pointing at the
        -- wrong unit.
        --
        -- OnShow/OnHide go through CreateSimpleWrapper instead, which has NO
        -- motion parameter -- they fire unconditionally. So this closes the gap
        -- in one frame, during combat, using only sanctioned secure calls.
        -- Field-measured before this existed: ~1s of dead keys on a pinned boss
        -- frame the moment it spawned (2026-07-27), recovering only when the
        -- cursor moved off and back.
        --
        -- Guarded on IsUnderMouse so a frame merely being shown does not steal
        -- the hover, and on mouseoverbutton ~= self so a show while already
        -- claimed is a no-op. Mirrors OnEnter's phases 3-6 in the same order.
        local onShowSnippet = [[
            if self:IsUnderMouse() and mouseoverbutton ~= self then
                local snippet = self:GetAttribute("dfBindingSnippet")
                if snippet and snippet ~= "" then
                    owner:ClearBindings()
                    mouseoverbutton = self
                    mouseovername = self:GetName() or "unnamed"
                    self:SetAttribute("dfIsSecureMouseover", true)
                    self:SetAttribute("dfClearedBy", nil)
                    self:ClearBindings()
                    control:RunFor(self, snippet)
                    self:SetAttribute("dfBindingsActive", true)
                    self:SetAttribute("dfShowClaimed", (self:GetAttribute("dfShowClaimed") or 0) + 1)
                end
            end
        ]]

        -- Keep the snippets for re-wrapping: a frame's wrap can DIE mid-session
        -- (field-verified 2026-07-20: after a player-housing session, the party
        -- buttons' OnEnter wraps stopped executing entirely — enterCount stayed
        -- 0 while the insecure hooks still fired — so hover keybinds fell
        -- through to the action bars until /reload). RewrapSecureHandlers
        -- reuses these to unwrap + re-wrap; the repair path calls it.
        self.wrapSnippets = {
            enter = onEnterSnippet,
            leave = onLeaveSnippet,
            hide  = onHideSnippet,
            show  = onShowSnippet,
        }

        local wrapSuccess = pcall(function()
            -- Standard WrapScript - our bindings run in pre script (before other handlers)
            -- Note: Previously tried post parameter for Clicked compatibility, but it broke
            -- click casting entirely. Reverted 2025-01-20.
            self.header:WrapScript(frame, "OnEnter", onEnterSnippet)
            self.header:WrapScript(frame, "OnLeave", onLeaveSnippet)
            self.header:WrapScript(frame, "OnHide", onHideSnippet)
            self.header:WrapScript(frame, "OnShow", onShowSnippet)
        end)

        if not wrapSuccess then
            -- WrapScript failed. This used to mark the frame as set up anyway,
            -- which made the failure PERMANENT for the session — the guard at
            -- the top of this function blocked every later attempt. Retry
            -- instead (bounded): leave the flag unset so the retry re-runs the
            -- full setup, hooks included, since we return before installing them.
            self:ScheduleWrapRetry(frame, frameName, "WrapScript failed")
            return
        end
        frame.dfWrapApplied = true
        -- Fresh budget for the NEXT failure episode. Without this the counter is
        -- cumulative for the session: a frame that burned three attempts while the
        -- header was still coming up at login would have two left when its wrap
        -- died mid-session — the player-housing case this branch exists to fix —
        -- and would then latch dfWrapRetryGaveUp permanently. A successful install
        -- means the frame is healthy, so the previous episode is over.
        frame.dfWrapRetries = nil
        frame.dfWrapRetryGaveUp = nil
    end
    
    -- Diagnostic logging for OnHide (insecure side)
    -- Actual binding cleanup is handled by WrapScript OnHide above (secure, works in combat)
    -- Also counts show/hide flips: pinned boss frames carry a per-frame
    -- [@bossN,help] visibility state driver that churns during a fight, unlike
    -- header children which stay shown. dfVisFlips lets the wrap-skip diagnostic
    -- show whether the failing frame was churning — testing the hypothesis that
    -- that churn is what desyncs the secure OnEnter/OnLeave wraps.
    frame:HookScript("OnHide", function(self)
        self.dfVisFlips = (self.dfVisFlips or 0) + 1
        local wasHovered = (CC.currentHoveredFrame == self)
        if wasHovered then
            local clearedBy = self:GetAttribute("dfClearedBy") or "?"
            DF:DebugWarn("CLICK", "OnHide %s while HOVERED — clearedBy=%s combat=%s visFlips=%d",
                self:GetName() or "unnamed", clearedBy, tostring(InCombatLockdown()), self.dfVisFlips)
            CC.currentHoveredFrame = nil
        end
    end)
    frame:HookScript("OnShow", function(self)
        self.dfVisFlips = (self.dfVisFlips or 0) + 1
    end)
    
    -- Set frame type and identity attributes
    frame:SetAttribute("dfIsDandersFrame", frame.dfIsDandersFrame == true)
    frame:SetAttribute("dfIsBlizzardFrame", frame.dfIsBlizzardFrame == true)
    frame:SetAttribute("dfFrameName", frame:GetName() or "unnamed")  -- readable from WrapScript
    
    -- Track current hovered frame for click-casting + diagnostic logging
    frame:HookScript("OnEnter", function(self)
        CC.currentHoveredFrame = self

        -- Debug: verify WrapScript set up bindings and check attribute state
        local bindingsActive = self:GetAttribute("dfBindingsActive")
        local snippet = self:GetAttribute("dfBindingSnippet") or ""
        local hasKeyboardBindings = snippet ~= ""
        local frameName = self:GetName() or "unnamed"
        local unit = self:GetAttribute("unit") or self.unit or "?"
        local type1 = self:GetAttribute("type1")
        local wrapEnterCount = self:GetAttribute("dfWrapEnterCount") or 0
        local wrapLeaveCount = self:GetAttribute("dfWrapLeaveCount") or 0

        -- Store the wrap count we expect; if it didn't increment, WrapScript didn't fire
        local prevWrapEnterCount = self.dfLastWrapEnterCount or 0
        local prevWrapLeaveCount = self.dfLastWrapLeaveCount or 0
        self.dfLastWrapEnterCount = wrapEnterCount
        self.dfLastWrapLeaveCount = wrapLeaveCount

        local wrapEnterFired = wrapEnterCount > prevWrapEnterCount

        -- Same delta treatment for the redundant set path, so we can tell a claim
        -- that SAVED this hover from one that merely duplicated a working OnEnter.
        -- Cumulative counters cannot answer that; only the per-hover delta can.
        local prevShowClaimed = self.dfLastShowClaimed or 0

        local enterPhase = self:GetAttribute("dfEnterPhase") or -99
        local prevMouseover = self:GetAttribute("dfSecurePrevMouseover") or "?"
        local postCheck = self:GetAttribute("dfPostCheck") or "?"

        -- showClaimed: times the secure OnShow wrap had to claim this frame because
        -- OnEnter arrived without motion (the frame appeared under a resting cursor).
        -- reasserted: times ReassertHoverBinds put binds back after a rebuild wiped
        -- them mid-hover. Both read zero on a frame the cursor simply moved onto;
        -- non-zero means a redundant path earned its keep. Surfaced here because a
        -- counter nothing ever reads is not a diagnostic.
        local showClaimed = self:GetAttribute("dfShowClaimed") or 0
        local reasserted = self:GetAttribute("dfReasserted") or 0
        self.dfLastShowClaimed = showClaimed

        -- CAUTION reading phase/prev/postCheck: those attributes are written ONLY by
        -- the wrap snippet, so when wrapEnter is false they are STALE values from the
        -- last successful cycle, not a description of THIS hover. "phase=7 with
        -- wrapEnter=false" means the PREVIOUS enter completed, nothing more.
        DF:Debug("CLICK", "OnEnter %s unit=%s kbActive=%s hasKB=%s type1=%s wrapEnter=%s(%d) wrapLeave=%d phase=%d prev=%s postCheck=%s showClaimed=%d reasserted=%d",
            frameName, tostring(unit), tostring(bindingsActive),
            tostring(hasKeyboardBindings), tostring(type1),
            tostring(wrapEnterFired), wrapEnterCount, wrapLeaveCount,
            enterPhase, prevMouseover, postCheck, showClaimed, reasserted)

        -- THE MEASUREMENT: was a redundant set path load-bearing on THIS hover?
        --
        -- A claim only earned its place if it set the binds when the secure OnEnter
        -- did not. If OnEnter fired as well, the claim merely repeated work that was
        -- already going to happen -- harmless, but not a justification for carrying
        -- the path. Logged at WARN so it stands out in a capture.
        --
        -- This measurement is what retired the state-driver reclaim: over 46 minutes
        -- and five pulls it produced six redundant claims and zero load-bearing
        -- ones, while OnShow produced five load-bearing and none redundant.
        local showClaimedNow = showClaimed > prevShowClaimed
        if showClaimedNow and hasKeyboardBindings then
            local via = "OnShow"
            if not wrapEnterFired and bindingsActive then
                DF:DebugWarn("CLICK", "CLAIM WAS LOAD-BEARING on %s — binds came from the %s, secure OnEnter did NOT fire",
                    frameName, via)
            elseif wrapEnterFired then
                DF:Debug("CLICK", "Claim redundant on %s — the %s ran but secure OnEnter fired too",
                    frameName, via)
            end
        end

        -- Key diagnostic: mouseoverbutton was not self after OnEnter completed
        if wrapEnterFired and postCheck ~= "ok" then
            DF:DebugError("CLICK", "POST-CHECK FAILED on %s! mouseoverbutton=%s after phase 7 — self reference lost during OnEnter",
                frameName, postCheck)
            CC:RequestBindingRepair("post-check-" .. postCheck)
        end

        -- Key diagnostic: WrapScript didn't complete all phases
        if wrapEnterFired and enterPhase < 7 and hasKeyboardBindings then
            DF:DebugError("CLICK", "WRAPSCRIPT INCOMPLETE on %s! phase=%d (expected 7) prev=%s",
                frameName, enterPhase, prevMouseover)
            CC:RequestBindingRepair("wrap-incomplete-phase" .. enterPhase)
        end

        -- Key diagnostic: hover is on but WrapScript didn't activate keyboard bindings
        if hasKeyboardBindings and not bindingsActive then
            DF:DebugWarn("CLICK", "HOVER BUT NO KB BINDINGS on %s! Key presses will go to action bar (phase=%d)", frameName, enterPhase)
            if not wrapEnterFired then
                -- Reported, not repaired. Blizzard runs a wrapped OnEnter snippet
                -- only when the enter came from cursor MOTION, so this is expected
                -- client behaviour rather than a fault, and the OnShow wrap is what
                -- actually covers it. The repair request that used to live here
                -- re-wrapped every registered frame for a condition it could not
                -- affect.
                DF:DebugWarn("CLICK", "  WrapScript OnEnter DID NOT FIRE (enterCount=%d leaveCount=%d)", wrapEnterCount, wrapLeaveCount)
                DF:DebugWarn("CLICK", "  frame visible=%s shown=%s mouseOver=%s combat=%s",
                    tostring(self:IsVisible()), tostring(self:IsShown()),
                    tostring(self:IsMouseOver()), tostring(InCombatLockdown()))
                -- Pinned-boss wrap-skip hypothesis: is this a visibility-driven
                -- pinned frame, and how much has it churned? (The old line here
                -- printed the GLOBAL header's name — which says nothing about
                -- THIS frame — and was mislabelled "headerRef".) wrapApplied /
                -- handlersSetup say whether our wrap is even installed; visFlips
                -- says whether the frame has been show/hide-churning under it.
                local parent = self:GetParent()
                -- showClaimed here is the decisive field: OnEnter arriving without
                -- motion is exactly what the OnShow wrap exists to cover, so a
                -- non-zero value means the gap was already closed before this
                -- warning fired, and a zero means it was not.
                DF:DebugWarn("CLICK", "  parent=%s pinnedBoss=%s pinned=%s visFlips=%d wrapApplied=%s showClaimed=%d",
                    parent and parent:GetName() or "nil",
                    tostring(self.isPinnedBossFrame), tostring(self.isPinnedFrame),
                    self.dfVisFlips or 0, tostring(self.dfWrapApplied),
                    self:GetAttribute("dfShowClaimed") or 0)
            else
                DF:DebugWarn("CLICK", "  WrapScript fired (enterCount=%d phase=%d) but dfBindingsActive=%s snippet=%d chars",
                    wrapEnterCount, enterPhase, tostring(bindingsActive), #snippet)
                if DF:DebugActive("CLICK") then
                    DF:DebugWarn("CLICK", "  snippet preview: %s", snippet:sub(1, 200))
                end
            end
            DF:DebugWarn("CLICK", "  handlersSetup=%s registered=%s",
                tostring(self.dfKeyboardHandlersSetup), tostring(self.dfClickCastRegistered))
        end

        -- Self-heal detection: this frame's snippet is empty but the profile
        -- has keyboard binds — likely wiped by a transient refresh (bug #976).
        -- One-shot per frame: the flag is reset when a rebuild gives the frame
        -- a real snippet again, so legitimately-empty frames don't loop.
        if not hasKeyboardBindings and self.dfIsDandersFrame
            and not self.dfSnippetRepairTried and CC:ProfileHasKeyboardBindings() then
            self.dfSnippetRepairTried = true
            DF:DebugWarn("CLICK", "EMPTY SNIPPET on %s but profile has keyboard binds", frameName)
            CC:RequestBindingRepair("empty-snippet")
        end

        -- Warn if mouse click-cast attributes are missing
        if not type1 or type1 == "" then
            DF:DebugWarn("CLICK", "NO TYPE1 on %s - left-click won't cast!", frameName)
        end

        -- Start diagnostic ticker to monitor binding state while hovering
        if hasKeyboardBindings then
            CC:StartDiagnosticTicker(self)
        end
    end)

    frame:HookScript("OnLeave", function(self)
        local wasTracked = (CC.currentHoveredFrame == self)
        CC.currentHoveredFrame = nil

        -- Stop the diagnostic ticker
        CC:StopDiagnosticTicker()

        local frameName = self:GetName() or "unnamed"
        local wrapLeaveCount = self:GetAttribute("dfWrapLeaveCount") or 0
        local prevWrapLeaveCount = self.dfLastWrapLeaveCount or 0
        local wrapLeaveFired = wrapLeaveCount > prevWrapLeaveCount
        self.dfLastWrapLeaveCount = wrapLeaveCount

        local bindingsActive = self:GetAttribute("dfBindingsActive")

        DF:Debug("CLICK", "OnLeave %s wrapLeave=%s(%d) kbStillActive=%s",
            frameName, tostring(wrapLeaveFired), wrapLeaveCount, tostring(bindingsActive))

        if not wasTracked then
            DF:DebugWarn("CLICK", "OnLeave %s but wasn't tracked as hovered — possible orphan leave", frameName)
        end

        -- Warn if WrapScript OnLeave didn't fire (bindings may not have been cleared)
        if not wrapLeaveFired and wasTracked then
            DF:DebugWarn("CLICK", "WrapScript OnLeave DID NOT FIRE for %s! leaveCount=%d kbActive=%s",
                frameName, wrapLeaveCount, tostring(bindingsActive))
        end

        -- Warn if bindings are still active after leave (WrapScript should have cleared them)
        if bindingsActive then
            -- Read the frame attributes set by WrapScript OnLeave to see what happened
            local mouseoverOnLeave = self:GetAttribute("dfMouseoverOnLeave") or "?"
            local leaveCheckPassed = self:GetAttribute("dfLeaveCheckPassed")
            local isSecureMouseover = self:GetAttribute("dfIsSecureMouseover")
            local postCheck = self:GetAttribute("dfPostCheck") or "?"
            local clearedBy = self:GetAttribute("dfClearedBy") or "nobody"
            local stateDriverCount = self:GetAttribute("dfStateDriverCount") or 0
            local stateDriverUnderMouse = self:GetAttribute("dfStateDriverUnderMouse")
            local stateDriverRectKnown = self:GetAttribute("dfStateDriverRectKnown")
            local sdMouseX = self:GetAttribute("dfSDMouseX")
            local sdMouseY = self:GetAttribute("dfSDMouseY")
            -- showClaimed separates the two ways this frame got its binds, and
            -- the distinction decides whether a release was even POSSIBLE: a
            -- claim made by the OnShow wrap can never be released by the secure
            -- OnLeave, because Wrapped_OnLeave gates on
            -- `motion and self:GetAttribute("_wrapentered")` and only the motion
            -- branch of Wrapped_OnEnter sets that attribute. Restricted code
            -- cannot set it either — HANDLE:SetAttribute rejects any name
            -- matching ^_ (RestrictedFrames.lua:523, Gethe live 4383ced3). A
            -- show-claimed frame therefore depends on OnHide, on the next
            -- frame's claim, on the mouseoverstate driver above, or on the
            -- backstop below. Without this field the log cannot tell a
            -- show-claim from a motion-enter after the fact, and the two have
            -- completely different release paths — a 2026-08-01 user log was
            -- misread for exactly that reason.
            local showClaimed = self:GetAttribute("dfShowClaimed") or 0
            DF:DebugError("CLICK", "BINDINGS STILL ACTIVE after OnLeave %s! wrapLeave=%s mouseoverbutton=%s checkPassed=%s isSecureMO=%s postCheck=%s",
                frameName, tostring(wrapLeaveFired), mouseoverOnLeave, tostring(leaveCheckPassed), tostring(isSecureMouseover), postCheck)
            DF:DebugError("CLICK", "  clearedBy=%s showClaimed=%d stateDriverFired=%d underMouse=%s rectKnown=%s mousePos=%s,%s",
                clearedBy, showClaimed, stateDriverCount, tostring(stateDriverUnderMouse), tostring(stateDriverRectKnown), tostring(sdMouseX), tostring(sdMouseY))

            -- STUCK-BINDS BACKSTOP: the client sometimes skips the secure
            -- OnLeave wrap (and the mouseoverstate driver has a blind spot
            -- when the cursor leaves onto another mouseover unit, so nothing
            -- fires on its transition). When that happens the header-owned
            -- hover binds stay active and every DF-bound key is stolen from
            -- the action bars — dead until something clears them. This hook
            -- has just OBSERVED that exact state, so act on it:
            --   * if the cursor is now over another registered frame, its
            --     secure OnEnter already wiped + rebuilt the binds — do
            --     nothing (wiping here would kill that frame's live binds)
            --   * out of combat: clear the header's override bindings and
            --     reset the secure hover tracking right away
            --   * in combat: insecure clearing is blocked — queue the
            --     self-heal repair, which runs at combat end and clears the
            --     header (keys also self-correct on the next frame hover,
            --     whose secure OnEnter wipes owner-side)
            local overRegisteredFrame = false
            local foci = GetMouseFoci and GetMouseFoci()
            if foci then
                for _, focus in ipairs(foci) do
                    if CC.registeredFrames and CC.registeredFrames[focus] then
                        overRegisteredFrame = true
                        break
                    end
                end
            end

            -- FALSE-POSITIVE GUARD: the cursor may never have left at all.
            -- Pinned boss frames carry a per-frame [@bossN,help] visibility
            -- driver, so as boss units spawn/despawn/phase the frame flicks
            -- hidden and shown under a stationary cursor. That fires the
            -- INSECURE OnLeave while the secure wrap correctly does not, and
            -- GetMouseFoci can omit the frame during the flicker, so the
            -- overRegisteredFrame check above does not catch it.
            --
            -- Field log (mythic pull, 2026-07-27): DandersPinnedBoss1Raid_3
            -- reported "OnLeave DID NOT FIRE" twice with underMouse=true and
            -- mouseoverbutton still itself. Bindings being active there is
            -- CORRECT, and the queued repair then ran at combat end and wiped
            -- the hover binds off whatever frame the cursor was on by then.
            -- Ask the frame directly rather than trusting the insecure leave.
            local stillHovered = (self.IsMouseOver and self:IsMouseOver()) and isSecureMouseover

            if stillHovered then
                DF:Debug("CLICK", "OnLeave %s ignored — cursor is still on the frame and the secure mouseover is intact; the insecure leave was spurious",
                    frameName)
            elseif not overRegisteredFrame then
                if InCombatLockdown() then
                    CC:RequestBindingRepair("stuck-binds-onleave")
                else
                    -- Binds are owner-owned; clear the header (the release
                    -- that matters) and the frame (defense-in-depth).
                    pcall(ClearOverrideBindings, self)
                    pcall(ClearOverrideBindings, CC.header)
                    if CC.header and CC.header.Execute then
                        pcall(function()
                            CC.header:Execute([[ mouseoverbutton = nil mouseovername = nil ]])
                        end)
                    end
                    self:SetAttribute("dfBindingsActive", nil)
                    self:SetAttribute("dfIsSecureMouseover", nil)
                    DF:DebugWarn("CLICK", "Stuck hover binds cleared for %s (secure OnLeave was skipped)", frameName)
                end
            end
        end
    end)

    -- Debug: PreClick hook to log click state and detect binding mismatches
    frame:HookScript("PreClick", function(self, button, down)
        local frameName = self:GetName() or "unnamed"
        local unit = self:GetAttribute("unit") or self.unit or "?"
        local hovered = self.dfIsHovered

        -- Determine which attributes handle this click
        local typeAttr, macroAttr
        if button == "LeftButton" then
            typeAttr = self:GetAttribute("type1")
            macroAttr = self:GetAttribute("macrotext1")
        elseif button == "RightButton" then
            typeAttr = self:GetAttribute("type2")
            macroAttr = self:GetAttribute("macrotext2")
        elseif button == "MiddleButton" then
            typeAttr = self:GetAttribute("type3")
            macroAttr = self:GetAttribute("macrotext3")
        else
            -- Virtual button from keyboard override binding (e.g., "dfbuttonshift1")
            typeAttr = self:GetAttribute("type-" .. button)
            macroAttr = self:GetAttribute("macrotext-" .. button)
        end

        DF:Debug("CLICK", "PreClick %s btn=%s unit=%s hovered=%s type=%s macro=%s",
            frameName, button, tostring(unit), tostring(hovered), tostring(typeAttr),
            macroAttr and macroAttr:sub(1, 50) or "nil")

        -- Warn if click-cast type is missing for this button
        if not typeAttr or typeAttr == "" then
            local bindingsActive = self:GetAttribute("dfBindingsActive")
            local snippet = self:GetAttribute("dfBindingSnippet") or ""
            local wrapEnterCount = self:GetAttribute("dfWrapEnterCount") or 0
            local wrapLeaveCount = self:GetAttribute("dfWrapLeaveCount") or 0
            local isHovered = (CC.currentHoveredFrame == self)

            DF:DebugWarn("CLICK", "MISSING TYPE for btn=%s on %s - click won't cast!", button, frameName)
            DF:DebugWarn("CLICK", "  kbActive=%s snippet=%d chars combat=%s isHovered=%s",
                tostring(bindingsActive), #snippet, tostring(InCombatLockdown()), tostring(isHovered))
            DF:DebugWarn("CLICK", "  wrapEnter=%d wrapLeave=%d visible=%s mouseOver=%s",
                wrapEnterCount, wrapLeaveCount, tostring(self:IsVisible()), tostring(self:IsMouseOver()))
        end
    end)

    frame.dfKeyboardHandlersSetup = true
end

-- Set up WrapScript on child elements (auras, defensive icons) so mouseoverbutton
-- Update the binding attributes stored on a frame
-- Builds a snippet string with SetBindingClick calls (Cell-style approach)
-- The _onenter attribute runs this snippet on every hover
function CC:UpdateFrameBindingAttributes(frame)
    if not frame or InCombatLockdown() then return end
    
    local frameName = frame:GetName()
    if not frameName then return end
    
    -- Build the snippet with SetBindingClick calls
    local snippetLines = {}
    
    if self.unifiedMacroMap then
        for keyString, data in pairs(self.unifiedMacroMap) do
            local binding = data.templateBinding
            local bindType = binding.bindType or "mouse"
            
            -- Check if this is a META mouse binding (Mac Command key)
            -- These need SetBindingClick because frame attributes don't work for meta- on Mac
            local isMetaMouseBinding = (bindType == "mouse") and 
                binding.modifiers and binding.modifiers:lower():find("meta")
            
            -- Process keyboard, scroll, AND meta mouse bindings with SetBindingClick
            -- Regular mouse bindings are handled via frame attributes (type1, spell1, etc.)
            if bindType == "key" or bindType == "scroll" or isMetaMouseBinding then
                -- Check if this binding should apply to this frame
                if self:ShouldBindingApplyToFrame(binding, frame) then
                    local bindKey
                    local virtualBtn = self:GetVirtualButtonName(binding)
                    
                    if isMetaMouseBinding then
                        -- Build binding key for mouse button (e.g., "META-BUTTON1", "ALT-META-BUTTON3")
                        local buttonNum
                        if binding.button == "LeftButton" then
                            buttonNum = "BUTTON1"
                        elseif binding.button == "RightButton" then
                            buttonNum = "BUTTON2"
                        elseif binding.button == "MiddleButton" then
                            buttonNum = "BUTTON3"
                        else
                            local num = binding.button:match("Button(%d+)")
                            buttonNum = num and ("BUTTON" .. num) or binding.button:upper()
                        end
                        bindKey = self:BuildBindingKey(binding.modifiers, buttonNum)
                    else
                        -- Keyboard/scroll binding
                        bindKey = self:BuildBindingKey(binding.modifiers, 
                            bindType == "scroll" and (binding.key == "SCROLLUP" and "MOUSEWHEELUP" or "MOUSEWHEELDOWN") or binding.key)
                    end
                    
                    -- Build SetBindingClick call — the HEADER (owner) owns
                    -- the binding, the click targets the hovered frame (self
                    -- at snippet run time).
                    --
                    -- ⚠ EXECUTION VEHICLE MATTERS (the 4.7.4 lesson): this
                    -- snippet MUST be executed via control:RunFor(frame,
                    -- snippet) from the OnEnter wrap — RunFor runs the body
                    -- in the CALLING control's (header's) environment with
                    -- self rebound to the frame (RestrictedFrames.lua
                    -- HANDLE:RunFor), so `owner` resolves to the header and
                    -- ownership is real. Running it via frame:Run() instead
                    -- executes in the FRAME's managed environment
                    -- (HANDLE:Run → GetManagedEnvironment(frame)) where the
                    -- ownership model silently breaks: 4.7.4 did exactly
                    -- that, sets and clears resolved to different owners,
                    -- every release no-opped, and keys stayed stolen until
                    -- reload.
                    table.insert(snippetLines, string.format(
                        [[owner:SetBindingClick(true, %q, self, %q)]],
                        bindKey, virtualBtn
                    ))
                end
            end
        end
    end
    
    -- Store the snippet - _onenter will run this on every hover
    local snippet = table.concat(snippetLines, "\n")
    frame:SetAttribute("dfBindingSnippet", snippet)

    -- Frame has a real snippet again — allow the empty-snippet self-heal
    -- detection to fire once more if it ever gets wiped (bug #976)
    if snippet ~= "" then
        frame.dfSnippetRepairTried = nil
    end
end

-- Returns true if any enabled binding in the unified macro map needs the
-- hover snippet path (keyboard, scroll, or meta-mouse). Used by the
-- self-heal detection to tell "snippet legitimately empty" apart from
-- "snippet wiped". Cached per macro-map instance so hover hooks stay cheap.
function CC:ProfileHasKeyboardBindings()
    if not self.unifiedMacroMap then return false end
    if self.kbCheckMap == self.unifiedMacroMap then
        return self.kbCheckResult
    end

    local result = false
    for _, data in pairs(self.unifiedMacroMap) do
        local binding = data.templateBinding
        local bindType = binding.bindType or "mouse"
        local isMetaMouse = (bindType == "mouse") and binding.modifiers
            and binding.modifiers:lower():find("meta")
        if bindType == "key" or bindType == "scroll" or isMetaMouse then
            result = true
            break
        end
    end

    self.kbCheckMap = self.unifiedMacroMap
    self.kbCheckResult = result
    return result
end

-- Legacy alias for compatibility
-- Refresh binding attributes on all registered frames
-- Call this when bindings change
function CC:RefreshKeyboardBindings()
    if InCombatLockdown() then 
        self:Defer("keyboardRefresh")
        return 
    end
    
    -- Update binding attributes on all registered frames
    if self.registeredFrames then
        for frame in pairs(self.registeredFrames) do
            if frame.dfKeyboardHandlersSetup then
                self:UpdateFrameBindingAttributes(frame)
            end
        end
    end
    
    -- Also sweep DF's own frames. The loop that used to be here read
    -- `DF.unitFrames`, a table nothing in the addon assigns, so it silently did
    -- nothing; DF:IterateAllFrames is the real accessor. Mostly redundant with
    -- the registeredFrames pass above -- RegisterAllFrames walks the party,
    -- separated-raid, flat-raid and pet headers -- but NOT redundant in arena:
    -- it has no arena-header walk, while IterateAllFrames special-cases arena
    -- (party/raid headers are hidden there). Idempotent and off the hot path,
    -- so the overlap costs one extra pass over <=40 frames when bindings change.
    if DF and DF.IterateAllFrames then
        DF:IterateAllFrames(function(frame)
            if frame and frame.dfKeyboardHandlersSetup then
                self:UpdateFrameBindingAttributes(frame)
            end
        end)
    end
end

-- ============================================================
-- SELF-HEALING BINDING REPAIR (bug #976)
-- Keyboard hover-binds can die mid-session (stale mouseoverbutton in the
-- restricted environment, spurious state-driver clears, wiped snippets)
-- and previously only /reload recovered. The OnEnter/ticker diagnostics
-- already DETECT all of these; this repair path fixes them out of combat:
--   1. reset the restricted env's mouseoverbutton tracking
--   2. clear stray override bindings so keys can't stay stolen
--   3. rebuild the macro map + every frame's binding snippet
-- All repair actions are insecure out-of-combat calls the addon already
-- uses elsewhere — no new taint surface. In combat the repair is queued
-- and OnCombatEnd runs it.
-- ============================================================

local REPAIR_COOLDOWN = 5  -- seconds between repair attempts

-- Re-check interval while waiting for the cursor to leave, and the total wall-clock
-- budget before the repair proceeds anyway. Past the budget a genuine breakage
-- matters more than one frame's live binds. Measured in elapsed time, NOT in
-- number of attempts -- see the note in RunBindingRepair.
local REPAIR_HOVER_WAIT = 1
local REPAIR_HOVER_BUDGET = 10

-- Safe to call from anywhere, including combat and secure-hook callbacks
-- Unwrap + re-wrap a frame's secure OnEnter/OnLeave/OnHide handlers using the
-- snippets kept by SetupSecureHandlers. WrapScript STACKS, so the unwrap must
-- come first or repeated repairs would layer duplicate wraps (guide: Clique
-- does exactly this unwrap-then-wrap dance to stay idempotent). Both
-- directions are pcall'd: unwrapping a frame that lost its wrap, or wrapping
-- one that cannot be wrapped right now, must never abort the repair loop.
-- Returns true when the frame ends up wrapped.
function CC:RewrapSecureHandlers(frame)
    if not frame or InCombatLockdown() then return false end
    -- Without a secure header the whole re-wrap self-heal is a no-op, and it used
    -- to bail silently — the repair would report "re-wrapped 0 frames" and look
    -- like it had nothing to do. Say why, and try to get the header back.
    if not (self.header and self.header.WrapScript) then
        DF:DebugError("CLICK", "RewrapSecureHandlers: no secure header — cannot re-wrap %s",
            tostring(frame.GetName and frame:GetName() or "unnamed"))
        self:CreateClickCastHeader()
        return false
    end
    local snippets = self.wrapSnippets
    if not snippets then return false end

    pcall(function() self.header:UnwrapScript(frame, "OnEnter") end)
    pcall(function() self.header:UnwrapScript(frame, "OnLeave") end)
    pcall(function() self.header:UnwrapScript(frame, "OnHide") end)
    pcall(function() self.header:UnwrapScript(frame, "OnShow") end)

    local ok = pcall(function()
        self.header:WrapScript(frame, "OnEnter", snippets.enter)
        self.header:WrapScript(frame, "OnLeave", snippets.leave)
        self.header:WrapScript(frame, "OnHide", snippets.hide)
        self.header:WrapScript(frame, "OnShow", snippets.show)
    end)
    frame.dfWrapApplied = ok or nil
    if ok then
        -- A successful re-wrap also ends the failure episode, so the retry budget
        -- resets here too (see the matching reset in SetupSecureHandlers). The
        -- repair is the other way a frame gets healthy again.
        frame.dfWrapRetries = nil
        frame.dfWrapRetryGaveUp = nil
    end
    return ok
end

-- Re-establish hover binds on a frame the cursor is currently on, without waiting
-- for a leave/enter cycle.
--
-- ApplyBindings wipes the header's override bindings unconditionally -- it has to,
-- or the outgoing set survives -- and it runs on every talent change, profile
-- switch, UI edit, and as the bindingRefresh drain job at combat end. If the user
-- is hovering someone at that moment, their hover binds die until they move off and
-- back on. At combat end that is exactly when a healer is most likely to be parked
-- on a frame. RunBindingRepair carefully postpones for this reason, and then
-- bindingRefresh ran two slots later in DRAIN_ORDER and undid the courtesy.
--
-- Out of combat only, by necessity: SetFrameRef and Execute are both blocked in
-- lockdown. That is sufficient here, because ApplyBindings itself defers in combat.
function CC:ReassertHoverBinds(frame)
    frame = frame or self.currentHoveredFrame
    if not frame or InCombatLockdown() then return end
    if not (self.header and self.header.Execute and self.header.SetFrameRef) then return end
    if not (frame.IsMouseOver and frame:IsMouseOver()) then return end

    local snippet = frame:GetAttribute("dfBindingSnippet")
    if not snippet or snippet == "" then return end

    -- Mirrors the OnEnter phases. `owner` is assigned explicitly rather than
    -- assumed: the binding snippet calls owner:SetBindingClick, and inside Execute
    -- `self` IS the header, so this makes ownership correct by construction rather
    -- than depending on what the environment happens to hold.
    local ok = pcall(function()
        self.header:SetFrameRef("dfReassert", frame)
        self.header:Execute([[
            local f = self:GetFrameRef("dfReassert")
            if f then
                owner = self
                self:ClearBindings()
                mouseoverbutton = f
                mouseovername = f:GetName() or "unnamed"
                f:SetAttribute("dfIsSecureMouseover", true)
                f:SetAttribute("dfClearedBy", nil)
                f:ClearBindings()
                self:RunFor(f, f:GetAttribute("dfBindingSnippet"))
                f:SetAttribute("dfBindingsActive", true)
                f:SetAttribute("dfReasserted", (f:GetAttribute("dfReasserted") or 0) + 1)
            end
        ]])
    end)

    if ok then
        DF:Debug("CLICK", "Re-asserted hover binds on %s (a rebuild happened while it was hovered)",
            frame:GetName() or "unnamed")
    else
        DF:DebugWarn("CLICK", "Hover re-assert failed for %s — binds return on the next hover",
            frame:GetName() or "unnamed")
    end
end

function CC:RequestBindingRepair(reason)
    if InCombatLockdown() then
        if not (self.deferred and self.deferred.bindingRepair) then
            DF:DebugWarn("CLICK", "Binding repair queued for combat end (%s)", tostring(reason))
        end
        self:Defer("bindingRepair", reason)
        return
    end
    self:RunBindingRepair(reason)
end

function CC:RunBindingRepair(reason, force)
    if self:CombatGuard("bindingRepair", reason) then return end
    if not self.db or not self.db.enabled then return end

    if not force then
        if self.lastBindingRepair and (GetTime() - self.lastBindingRepair) < REPAIR_COOLDOWN then
            -- Say so. A silent return here made a refused repair indistinguishable
            -- from a completed one in the log, right after a detector had reported
            -- the breakage that asked for it.
            DF:Debug("CLICK", "Binding repair (%s) skipped — %0.1fs into the %ds cooldown",
                tostring(reason), GetTime() - self.lastBindingRepair, REPAIR_COOLDOWN)
            return
        end
    end

    -- Do not tear down hover state while the cursor is sitting on a frame.
    -- The repair wipes the header's override bindings, resets the restricted
    -- env's mouseoverbutton, and unwraps/re-wraps the secure handlers on every
    -- registered frame (371 of them in a raid). Doing that mid-hover destroys
    -- the live hover: nothing re-establishes it, so the binds stay dead until
    -- the user moves off and back on.
    --
    -- Field log (mythic pull, 2026-07-27): a repair deferred from a boss-frame
    -- false positive drained at combat end while the cursor was on
    -- DandersRaidGroup3HeaderUnitButton5, and the very next tick reported
    -- BINDINGS VANISHED + MOUSEOVERBUTTON DESYNC on that frame. Combat end is
    -- exactly when a healer is most likely to be hovering someone.
    --
    -- Wait for the cursor to leave, bounded on WALL CLOCK -- not on a count of
    -- calls, which is what this was and why it failed.
    --
    -- It counted one per call against a limit of 10, intended as 10 x
    -- REPAIR_HOVER_WAIT = 10s of tolerated hover. But the diagnostic ticker asks
    -- for a repair every 200ms while dfIsSecureMouseover is falsy, and a
    -- POSTPONED call never stamps lastBindingRepair, so the 5s cooldown did not
    -- gate those either: ten ticks spent the entire budget in ~2s and then tore
    -- down all ~371 frames with the cursor still sitting on one of them. Ordinary
    -- non-motion enters triggered it, and the teardown could not fix them.
    -- Elapsed time makes the budget mean what it claims however often we are asked.
    local hovered = self.currentHoveredFrame
    if hovered and hovered.IsMouseOver and hovered:IsMouseOver() then
        self.repairHoverSince = self.repairHoverSince or GetTime()
        local waited = GetTime() - self.repairHoverSince
        if waited < REPAIR_HOVER_BUDGET then
            DF:Debug("CLICK", "Binding repair (%s) postponed — cursor is on %s (%.1fs of %ds)",
                tostring(reason), hovered:GetName() or "unnamed", waited, REPAIR_HOVER_BUDGET)
            self:DeferAfter("repairHoverWait", REPAIR_HOVER_WAIT, function()
                CC:RunBindingRepair(reason, force)
            end)
            return
        end
        DF:DebugWarn("CLICK", "Binding repair (%s) proceeding with %s still hovered after %.1fs — its hover binds will need a re-hover",
            tostring(reason), hovered:GetName() or "unnamed", waited)
    end
    self.repairHoverSince = nil

    self.lastBindingRepair = GetTime()

    DF:DebugWarn("CLICK", "Running binding repair (%s)", tostring(reason))

    -- 1. Reset restricted-env hover tracking (handle + string mirror).
    --    OnEnter no longer method-calls the shared handle, but the
    --    mouseoverstate driver still reads geometry through it, so a stale
    --    reference can still waste driver runs until something resets it.
    if self.header and self.header.Execute then
        pcall(function()
            self.header:Execute([[ mouseoverbutton = nil mouseovername = nil ]])
        end)
    end

    -- 2. Clear stray override bindings + hover state. After the env reset
    --    the OnLeave wrap can no longer clear these (mouseoverbutton ~= self),
    --    so clear them here or keys would stay stolen from the action bars.
    --    Binds are owner-owned (header), so the header wipe is the main
    --    release; every frame is ALSO cleared unconditionally as
    --    defense-in-depth — the dfBindingsActive flag has been proven able
    --    to read clear while a bind is still live, so it must not gate any
    --    release.
    pcall(ClearOverrideBindings, self.header)
    local function scrub(frame)
        if frame.GetAttribute then
            pcall(ClearOverrideBindings, frame)
            frame:SetAttribute("dfBindingsActive", nil)
            frame:SetAttribute("dfIsSecureMouseover", nil)
        end
    end
    if self.registeredFrames then
        for frame in pairs(self.registeredFrames) do
            scrub(frame)
        end
    end
    -- Same arena gap as in RefreshKeyboardBindings: registeredFrames has no
    -- arena-header walk, so scrub DF's frames through the real accessor too.
    if DF.IterateAllFrames then
        DF:IterateAllFrames(function(frame)
            if frame then scrub(frame) end
        end)
    end

    -- 2b. Re-wrap the secure OnEnter/OnLeave/OnHide handlers on every frame
    --     that has them. A wrap can DIE mid-session while the frame's insecure
    --     hooks keep firing (field case 2026-07-20: after a player-housing
    --     session the party buttons' wraps stopped executing — enterCount
    --     stuck at 0 — so hover keybinds fell through to the action bars, and
    --     the old repair rebuilt snippets but never re-wrapped, so it could
    --     detect this exact state yet not fix it). WrapScript stacks, so
    --     RewrapSecureHandlers unwraps first; both directions are pcall'd.
    local rewrapped = 0
    local rewrapSeen = {}
    local function rewrap(frame)
        if rewrapSeen[frame] then return end
        rewrapSeen[frame] = true
        if frame.dfKeyboardHandlersSetup and self:RewrapSecureHandlers(frame) then
            rewrapped = rewrapped + 1
        end
    end
    if self.registeredFrames then
        for frame in pairs(self.registeredFrames) do
            rewrap(frame)
        end
    end
    if rewrapped > 0 then
        DF:Debug("CLICK", "Repair re-wrapped secure handlers on %d frame(s)", rewrapped)
    end

    -- 3. Rebuild the macro map and every frame's snippet, in case snippets
    --    were wiped by a transient refresh. The next OnEnter re-applies
    --    bindings from the fresh snippet.
    self.unifiedMacroMap = self:BuildUnifiedMacroMap()
    self:RefreshKeyboardBindings()
end

-- Build a WoW binding key string from modifiers and key
function CC:BuildBindingKey(modifiers, key)
    if not modifiers or modifiers == "" then
        return key:upper()
    end
    
    -- Parse modifiers and rebuild in WoW's expected order: ALT-CTRL-SHIFT-META-KEY
    local hasShift = modifiers:lower():find("shift") ~= nil
    local hasCtrl = modifiers:lower():find("ctrl") ~= nil
    local hasAlt = modifiers:lower():find("alt") ~= nil
    local hasMeta = modifiers:lower():find("meta") ~= nil
    
    local parts = {}
    if hasAlt then table.insert(parts, "ALT") end
    if hasCtrl then table.insert(parts, "CTRL") end
    if hasShift then table.insert(parts, "SHIFT") end
    if hasMeta then table.insert(parts, "META") end
    table.insert(parts, key:upper())
    
    return table.concat(parts, "-")
end

-- Unregister a unit frame from click-casting
function CC:UnregisterFrame(frame)
    if not frame then return end
    if not self.registeredFrames then return end
    if not self.registeredFrames[frame] then return end
    
    -- Don't unregister during combat
    if self:CombatGuard("unregister", frame) then return end
    
    -- Restore Blizzard default behavior
    self:RestoreBlizzardDefaults(frame)
    
    -- Mark as unregistered
    self.registeredFrames[frame] = nil
    frame.dfClickCastRegistered = nil
end

-- Register all DandersFrames unit frames
function CC:RegisterAllFrames()
    if InCombatLockdown() then
        self:Defer("fullRegistration")
        return
    end
    
    -- Register party frames (includes player when in party/solo)
    if DF.partyHeader then
        for i = 1, 5 do
            local child = DF.partyHeader:GetAttribute("child" .. i)
            if child then
                self:RegisterFrame(child)
            end
        end
    end
    
    -- Register raid frames from separated headers
    if DF.raidSeparatedHeaders then
        for g = 1, 8 do
            local header = DF.raidSeparatedHeaders[g]
            if header then
                for i = 1, 5 do
                    local child = header:GetAttribute("child" .. i)
                    if child then
                        self:RegisterFrame(child)
                    end
                end
            end
        end
    end
    
    -- Register raid frames from FlatRaidFrames header (flat mode)
    if DF.FlatRaidFrames and DF.FlatRaidFrames.header then
        for i = 1, 40 do
            local child = DF.FlatRaidFrames.header:GetAttribute("child" .. i)
            if child then
                self:RegisterFrame(child)
            end
        end
    end
    
    -- Register pet frames
    if DF.petFrames then
        for _, frame in pairs(DF.petFrames) do
            self:RegisterFrame(frame)
        end
    end
    
    -- Also check ClickCastFrames global (for third-party addon support).
    -- NOTE: the old condition here was `enabled and A or B` — precedence made
    -- it (enabled and Button) or Frame, so entries an addon explicitly
    -- DISABLED (ClickCastFrames[f] = false, the documented unregister method)
    -- were re-registered on every sweep if their object type was "Frame".
    if ClickCastFrames then
        for frame, enabled in pairs(ClickCastFrames) do
            if enabled and clickCastFrameEligible(frame) then
                self:RegisterFrame(frame)
            end
        end
    end
end

-- ============================================================
