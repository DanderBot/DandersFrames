local addonName, DF = ...

-- ############################################################
-- ⚰ DEPRECATED-TARGETED-SPELLS — GROUP HALF REMOVED FROM THIS FILE 2026-07-29
-- ############################################################
-- Grep DEPRECATED-TARGETED-SPELLS to find every site. THIS comment is the
-- canonical one; the others are signposts back to here.
--
-- ☠ THREE THINGS THIS CHECKLIST GOT WRONG — it was written as a plan and never
-- checked against the code. Following it literally breaks LIVE features:
--   1. `activeCasters` is NOT group state. It is the shared "which enemies are
--      casting" registry: HandleTargetChange gates the PERSONAL display on it,
--      and the history interrupt marking reads its startTime. It STAYS.
--   2. `RegisterTargetedSpellEvents` is NOT group code — it registers the event
--      frame that Personal AND the Targeted List both run on. It STAYS.
--   3. `DF:UpdateTargetedSpellEventRegistration` is shared infrastructure, called
--      by the personal toggle, the list toggle and InitTargetedSpells. It STAYS.
-- The general trap: a function whose body names no personal/list symbol can still
-- be infrastructure both depend on. Symbol counting cannot see that — read the
-- callers. Everything else below held up.
--
-- DONE in this file: the icons, pool, layout, PositionIcons, Show/Hide/HideAll,
-- ShowInterruptedVisual, the whole roster-fingerprint resolver, GetFrameForUnit,
-- ShouldShow(Raid)TargetedSpells, Enable/Disable/ToggleTargetedSpells, the
-- write-only DF.targetedSpellsEnabled flag, and the group branches inside
-- ProcessCastInternal / HandleCastStop / OnEvent / NeedsCastEvents.
--
-- WHAT WENT: the GROUP-FRAME (on-frame) targeted-spell icons — the Indicators >
-- Targeted Spells page, and the icon pool / cast tracking / roster-fingerprint
-- machinery that fed them. Saved `targetedSpell*` keys were deliberately left on
-- existing profiles (see the note at the end of this block).
--
-- WHAT IS NOT: the PERSONAL display (`personalTargetedSpell*`, Indicators >
-- Personal Targeted) and the Targeted List. Both are live, both are supported,
-- and BOTH SHARE THIS FILE — the personal path compares against "player", which
-- is in UnitIsUnit's always-allowed list, so Blizzard's change never touched it.
-- ⚠ Do not delete this file. Deleting the feature means deleting the group half
-- OUT of it.
--
-- WHY: Blizzard's 2026-04-07 UnitIsUnit hotfix (detailed in the API
-- COMPATIBILITY block below) removed the only way to answer "is this enemy
-- casting at THIS group member". The feature has been force-disabled
-- unconditionally at load ever since — every setting on its page configured
-- something that could not render.
--
-- STATUS: the page was pulled from the sidebar 2026-07-27, and the group code was
-- DELETED 2026-07-29/30. This is no longer reversible by flipping a flag — the API
-- never came back across the remaining PTR builds. Restoring the feature means
-- restoring it from history, and it would still need an answer to UnitIsUnit.
--
-- The checklist below is kept as a RECORD, not a plan: it is what the removal
-- worked from, and the four places it was wrong are listed at the top of this
-- block. Read those before trusting any similar list.
--
-- DELETION CHECKLIST — what the removal covered:
--   Features\TargetedSpells.lua   the group half of this file: activeCasters,
--                                 the icon pool, PositionIcons,
--                                 Show/HideTargetedSpellIcon, the roster
--                                 fingerprint resolver, the cast/roster event
--                                 handlers, the setup wizard.
--                                 ⚠ NOT a contiguous block — the personal
--                                 helpers (ShouldShowPersonalTargetedSpells,
--                                 GetPersonalDB, the Show/Hide/Update Personal*
--                                 functions) are interleaved with them, and the
--                                 unit/content-type helpers near the top are
--                                 shared by both. Cut by function, not by range.
--   Options\Options.lua           the Indicators > Targeted Spells page,
--                                 GUI.RefreshTargetedSpellsOverlay, the
--                                 apiBlockedOverlay
--   Config.lua                    the targetedSpell* defaults (party + raid)
--   ExportCategories.lua          the targetedSpell export category
--   TestMode\TestMode.lua         the on-frame test painter + its panel checkbox
--                                 (⚠ shared with Personal Targeted — check
--                                 UpdateAllTestTargetedSpell before cutting)
--   Core.lua                      migrations + the wizard auto-fire (already out)
--   Features\ElementAppearance.lua, Frames\Position.lua (mover),
--   Frames\Headers.lua, Options\AutoProfiles.lua (override→page map),
--   Profile.lua, Debug\Profiler.lua, Debug\MemoryTest.lua
--   Locales\enUS.lua              the page's strings, once nothing else uses them
--   DandersFrames.toc             only if the file itself ever goes, which it
--                                 does not — Personal Targeted lives here
--
-- ⚠ Saved profiles keep their targetedSpell* keys either way. Stripping them is
-- a separate call (see the change-the-baseline rule) — do NOT fold it in.
-- ############################################################

-- ============================================================
-- TARGETED SPELLS SYSTEM
-- Shows incoming spell casts targeting party/raid members
-- 
-- When an enemy casts a spell targeting a party member, this
-- displays an icon with cast bar on that member's frame to
-- warn healers of incoming damage.
--
-- Supports multiple simultaneous incoming spells with stacking.
-- Features:
--   - Highlight important spells (C_Spell.IsSpellImportant)
--   - Sort by cast time (newest/oldest first)
--   - Max icons limit
--   - Interrupted visual feedback
--   - Off-screen nameplate support
-- ============================================================

local pairs, ipairs, wipe = pairs, ipairs, wipe
local GetTime = GetTime
local UnitExists = UnitExists
local UnitIsUnit = UnitIsUnit
local UnitGUID = UnitGUID
local UnitCastingInfo = UnitCastingInfo
local UnitChannelInfo = UnitChannelInfo
local UnitCastingDuration = UnitCastingDuration
local UnitChannelDuration = UnitChannelDuration
local UnitCanAttack = UnitCanAttack
local C_Spell = C_Spell
local C_CVar = C_CVar

-- Track all enemy casters we're monitoring
-- Structure: activeCasters[casterUnit] = { startTime = time, spellID = id, isChannel = bool }
-- Using unit token (e.g. "nameplate7") as key instead of GUID because GUIDs are secret values
local activeCasters = {}

-- ============================================================
-- API COMPATIBILITY: Group-frame targeted spells (PERMANENTLY DISABLED)
-- ------------------------------------------------------------
-- Blizzard hotfixed UnitIsUnit on 2026-04-07 so that comparing a
-- compound token like "nameplateXtarget" against a party/raid
-- token now returns nil. That kills our per-frame "is this enemy
-- targeting THIS party member" detection.
--
-- There is no in-addon workaround:
--   * UnitGUID/UnitName on nameplate units become secret in
--     instance combat, so we can't compare those either.
--   * The new PlayerIsSpellTarget API only answers for the player,
--     not for arbitrary group members.
--
-- The change is now live on retail. Group-frame Targeted Spells is
-- force-disabled unconditionally at addon load. The personal-display
-- path (compares against "player") still works and is unaffected,
-- since "player" is in the always-allowed list of UnitIsUnit args.
--
-- A "Targeted List" feature is being designed as a replacement for
-- the per-frame icon use case (see _Reference/targeted-list-mockup.html).
-- ============================================================

-- (Removed) DF.GroupTargetedSpellsAPIBlocked and
-- DF.GroupTargetedSpellsAPIBlockedParty. Both were write-only: their last reader
-- was the Options page that went with the group display.
--
-- (Removed) ForceDisableGroupTargetedSpellSettings, which wrote
-- DF.db.raid.targetedSpellEnabled = false on every Init so "the GUI reflects the
-- disabled state". There is no GUI left to reflect it and the key has ZERO readers
-- addon-wide, so this was worse than dead: it CREATED a key nothing reads in every
-- raid profile, on every login. Removing a write is not covered by the
-- change-the-baseline rule — that rule preserves user data, and this manufactured
-- data no user set.

-- Personal display variables (declared early for HandleTargetChange access)
local personalContainer = nil
local personalIcons = {}
local personalActiveSpells = {}

-- Cast history for learning/review (test feature)
-- Stores recent enemy casts with targeting info
local castHistory = {}
local MAX_HISTORY = 50

-- Event frame for tracking casts
local eventFrame = CreateFrame("Frame")
eventFrame:Hide()




-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================

-- (Removed) GetGroupUnits — enumerated the player plus every party/raid member so the
-- group display could ask "is this cast aimed at any of them". Its callers were the
-- on-frame group loop and the roster resolver. Personal only ever looks at "player",
-- and the Targeted List walks the party itself, so it has no callers left.

-- Get current content type
-- Returns: "openworld", "dungeon", "raid", "arena", "battleground"
local function GetContentType()
    local inInstance, instanceType = IsInInstance()
    
    if not inInstance then
        return "openworld"
    end
    
    if instanceType == "party" then
        return "dungeon"
    elseif instanceType == "raid" then
        return "raid"
    elseif instanceType == "arena" then
        return "arena"
    elseif instanceType == "pvp" then
        return "battleground"
    elseif instanceType == "scenario" then
        return "dungeon"  -- Treat scenarios as dungeons
    end
    
    return "openworld"
end

-- Check if personal targeted spells should be shown based on content type
-- Returns ok, reason. The reason feeds the PERSONALTARGET trace so a missing personal
-- icon is diagnosable; existing callers use it as a plain boolean and ignore it.
local function ShouldShowPersonalTargetedSpells(db)
    if not db.personalTargetedSpellEnabled then
        return false, "Personal Targeted Spells is off in settings"
    end

    local contentType = GetContentType()

    local allowed, key
    if contentType == "openworld" then
        allowed, key = db.personalTargetedSpellInOpenWorld ~= false, "Open World"
    elseif contentType == "dungeon" then
        allowed, key = db.personalTargetedSpellInDungeons ~= false, "Dungeons"
    elseif contentType == "raid" then
        allowed, key = db.personalTargetedSpellInRaids ~= false, "Raids"
    elseif contentType == "arena" then
        allowed, key = db.personalTargetedSpellInArena ~= false, "Arena"
    elseif contentType == "battleground" then
        allowed, key = db.personalTargetedSpellInBattlegrounds ~= false, "Battlegrounds"
    else
        return true  -- unknown content type → default to showing
    end
    if not allowed then
        return false, "content-type checkbox for " .. key .. " is off"
    end
    return true
end

-- Personal Targeted Spells is a player-screen overlay with per-mode settings, so
-- resolve the ACTIVE mode's DB (raid while in a raid, else party). Without this the
-- whole personal path read DF:GetDB() (party) and ignored the raid toggle/size/pos.
-- The group-frame and Targeted List paths stay party-resolved by design.
-- raidTestMode counts as raid: a raid PREVIEW is not a real raid, so IsInRaid() is
-- false there and the preview would otherwise resolve the PARTY profile and render
-- with its enable/size/position/style — exactly the bug this resolver exists to
-- prevent, just in test mode instead of live.
local function GetPersonalDB()
    return (IsInRaid() or DF.raidTestMode) and DF:GetRaidDB() or DF:GetDB()
end

-- Check if a unit is valid for targeted spell tracking.
-- We ONLY track nameplate units: the same caster also fires on target/softenemy/
-- boss/arena, and dedup is keyed on the unit-token STRING, so accepting those
-- would put the same cast in the list twice.
--
-- ⚠ That reasoning assumes every caster we care about HAS a nameplate, which is
-- only true while the nameplateShowOffscreen CVar is on. With it off, an enemy
-- outside your view gets no nameplate — so a mob you have targeted and can watch
-- casting arrives here as "target" only, and is rejected. Confirmed in game
-- 2026-07-30. Hence the checkbox on the Targeted List / Personal Targeted pages;
-- see DF:SetNameplateOffscreen. Accepting target/softenemy as a fallback would
-- need GUID-based dedup instead of token-string dedup, which is a bigger change.
local function IsValidCasterUnit(unit)
    if not unit then return false end
    
    -- Only nameplate units
    if string.find(unit, "nameplate") then
        return true
    end
    
    return false
end

-- Get enemy units that might be casting at us
-- Note: We only track nameplates - boss/arena units have nameplates too
local function GetEnemyUnits()
    local units = {}
    
    -- Nameplates only (boss/arena/target/focus all have nameplates)
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) then
            table.insert(units, unit)
        end
    end
    
    return units
end

-- ============================================================
-- (Removed) THE GROUP-FRAME TARGETED-SPELL DISPLAY
-- ============================================================
-- The on-frame icons, their pool and layout, and the roster-fingerprint
-- machinery that resolved which party member an enemy was casting at.
-- Blizzard's 2026-04-07 UnitIsUnit hotfix removed the only way to answer that
-- question, and the feature had been force-disabled at load ever since.
--
-- Personal Targeted Spells and the Targeted List are UNAFFECTED and live: both
-- share this file, and the personal path compares against "player", which the
-- hotfix left alone. GetFrameForUnit went too - its only caller was in here.
-- ============================================================
-- ============================================================
-- CAST EVENT HANDLING
-- ============================================================

-- Actually process and show the cast
local function ProcessCastInternal(casterUnit, isChannel)
    if not casterUnit or not UnitExists(casterUnit) then return end
    
    -- Only process valid unit types (nameplate, boss, arena)
    -- This prevents duplicates from "target"/"focus" which reference other units
    if not IsValidCasterUnit(casterUnit) then return end
    
    -- Only show casts from enemies
    if not UnitCanAttack("player", casterUnit) then return end
    
    -- Get cast info
    local name, displayName, texture, startTimeMS, endTimeMS, isTradeSkill, castID, notInterruptible, spellID
    local durationObject
    
    if isChannel then
        name, displayName, texture, startTimeMS, endTimeMS, isTradeSkill, notInterruptible, spellID = UnitChannelInfo(casterUnit)
        durationObject = UnitChannelDuration(casterUnit)
    else
        name, displayName, texture, startTimeMS, endTimeMS, isTradeSkill, castID, notInterruptible, spellID = UnitCastingInfo(casterUnit)
        durationObject = UnitCastingDuration(casterUnit)
    end
    
    -- No active cast
    if not name or not durationObject then return end
    
    -- Use GetTime() for start time - we can't do arithmetic on secret values from UnitCastingInfo
    local startTime = GetTime()
    
    -- A re-entry for a caster already in the table just overwrites it below. The
    -- group-icon cleanup that used to run here (hide every on-frame icon, bump
    -- resolveGen, clear casterShownFrame) went with the on-frame feature.
    
    -- Track this caster by unit token (not GUID - GUIDs are secret values)
    activeCasters[casterUnit] = {
        startTime = startTime,
        spellID = spellID,
        isChannel = isChannel
    }
    
    -- (Removed) the on-frame path: the group-unit loop, the party/raid content-type
    -- checks, and the party fingerprint resolution that fed them. The locals they
    -- needed (groupUnits, db, raidDb) went with it — the personal display resolves
    -- its own DB below, and the cast-history block needs none of them.

    -- Create personal display icon (always, for every cast - use SetAlphaFromBoolean for visibility)
    --
    -- Only casterUnit and the channel flag are clean enough to log here; spellID,
    -- texture and durationObject are secret-tainted on nameplates (see the gotcha #0
    -- note in the Targeted List section) and must never reach a format string.
    local personalOk, personalWhy = ShouldShowPersonalTargetedSpells(GetPersonalDB())
    if personalOk then
        if DF.DebugActive and DF:DebugActive("PERSONALTARGET") then
            DF:Debug("PERSONALTARGET", "pickup %s (channel=%s)", casterUnit, isChannel and "y" or "n")
        end
        -- Always show icon, let SetAlphaFromBoolean control visibility based on targeting
        DF:ShowPersonalTargetedSpellIcon(casterUnit, casterUnit, spellID, texture, durationObject, isChannel, startTime)
    elseif DF.DebugActive and DF:DebugActive("PERSONALTARGET") then
        DF:Debug("PERSONALTARGET", "skip %s: %s", casterUnit, personalWhy)
    end
    
    -- Log cast to history for review
    -- Store secrets in separate table to avoid contaminating UI calculations
    
    local entryID = tostring(GetTime()) .. "_" .. tostring(casterUnit or "unknown") .. "_" .. tostring(math.random(10000))
    
    -- Store secrets in separate isolated table
    if not DF.castHistorySecrets then
        DF.castHistorySecrets = {}
    end
    
    local secrets = {
        targets = {},
        isImportant = nil,
    }
    
    -- Store player targeting (raw secret value). The "player" comparison
    -- is still permitted under the new UnitIsUnit rules.
    secrets.targets["player"] = UnitIsUnit(casterUnit .. "target", "player")

    -- Per-party-member targeting is no longer recoverable after Blizzard's
    -- 2026-04-07 UnitIsUnit hotfix — UnitIsUnit returns nil for
    -- nameplateXtarget vs partyN. We deliberately don't store nil here
    -- because the cast history UI feeds these values to SetAlphaFromBoolean,
    -- which errors on nil. The history will simply show "N/A" for party
    -- member targeting columns.
    
    -- Store isImportant secret
    if C_Spell and C_Spell.IsSpellImportant and spellID then
        secrets.isImportant = C_Spell.IsSpellImportant(spellID)
    end
    
    DF.castHistorySecrets[entryID] = secrets
    
    -- Store only regular values in the history entry (no secrets!)
    local targetNames = {}
    targetNames["player"] = UnitName("player")
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) then
            targetNames[unit] = UnitName(unit)
        end
    end
    
    local historyEntry = {
        entryID = entryID,  -- Link to secrets table
        spellID = spellID,
        name = name,
        texture = texture,
        timestamp = GetTime(),
        isChannel = isChannel,
        casterUnit = casterUnit,
        casterName = UnitName(casterUnit),
        targetNames = targetNames,  -- Just names, no secrets
        interrupted = false,  -- Regular boolean
    }
    
    table.insert(castHistory, 1, historyEntry)  -- Insert at beginning (newest first)
    
    -- Trim to max size
    while #castHistory > MAX_HISTORY do
        local removed = table.remove(castHistory)
        if removed and removed.entryID then
            DF.castHistorySecrets[removed.entryID] = nil  -- Clean up secrets
        end
    end
end

-- Schedule cast processing after a short delay
-- The 0.2s delay ensures the caster's target info (nameplateXtarget) has
-- settled before we read it. Without this, we can read stale target data
-- from the previous frame, causing icons to appear on the wrong party member.
-- After the delay, we validate the cast is still active to avoid phantom
-- icon flashes from very fast casts that ended during the delay.
local CAST_PROCESS_DELAY = 0.2

local function ProcessCast(casterUnit, isChannel)
    if not casterUnit then return end
    if not IsValidCasterUnit(casterUnit) then return end
    
    C_Timer.After(CAST_PROCESS_DELAY, function()
        -- Validate the cast is still active after the delay
        -- If it finished/was interrupted during the delay, don't show anything.
        -- ⚠ This silently eats any cast shorter than CAST_PROCESS_DELAY (0.2s). Traced
        -- so "fast casts never show" is visible rather than guessed at. Instants are a
        -- separate matter: they never fire UNIT_SPELLCAST_START at all.
        local function endedEarly()
            if DF.DebugActive and DF:DebugActive("PERSONALTARGET") then
                DF:Debug("PERSONALTARGET", "drop %s: cast ended inside the 0.2s pickup delay", casterUnit)
            end
        end
        if isChannel then
            if not UnitChannelInfo(casterUnit) then endedEarly() return end
        else
            if not UnitCastingInfo(casterUnit) then endedEarly() return end
        end

        ProcessCastInternal(casterUnit, isChannel)
    end)
end

-- Handle target change (enemy switched targets mid-cast)
local function HandleTargetChange(casterUnit)
    if not casterUnit or not UnitExists(casterUnit) then return end
    if not IsValidCasterUnit(casterUnit) then return end
    if not UnitCanAttack("player", casterUnit) then return end
    
    -- Check if this caster has an active cast we're tracking (by unit token)
    if not activeCasters[casterUnit] then return end
    
    local db = GetPersonalDB()

    -- Group-frame visibility update removed: see ProcessCastInternal note.
    -- We only update the personal display now (which uses "player" comparisons,
    -- still permitted by the new UnitIsUnit rules).

    -- Update personal display visibility using SetAlphaFromBoolean
    if db.personalTargetedSpellEnabled then
        local iconIndex = personalActiveSpells[casterUnit]
        if iconIndex then
            local icon = personalIcons[iconIndex]
            if icon and icon.isActive and not icon.isInterrupted then
                local isTargetingPlayer = UnitIsUnit(casterUnit .. "target", "player")
                icon:SetAlphaFromBoolean(isTargetingPlayer, 1, 0)
            end
        end
    end
end

-- Handle cast ending (including interrupts)
local function HandleCastStop(casterUnit, wasInterrupted)
    if not casterUnit then return end
    if not IsValidCasterUnit(casterUnit) then return end
    
    -- Mark history entry as interrupted if applicable
    -- Can't compare spellID (it's a secret), so just mark the most recent entry for this caster
    if wasInterrupted then
        local casterInfo = activeCasters[casterUnit]
        if casterInfo then
            -- Find the most recent history entry for this caster (by timestamp match)
            for _, entry in ipairs(castHistory) do
                if entry.casterUnit == casterUnit and entry.timestamp == casterInfo.startTime and not entry.interrupted then
                    entry.interrupted = true
                    break  -- Only mark the most recent one
                end
            end
        end
    end
    
    -- Remove from active casters (using unit token, not GUID).
    -- ⚠ The REGISTRY ITSELF STAYS. HandleTargetChange gates the PERSONAL display
    -- on activeCasters[casterUnit], and the history interrupt marking just above
    -- reads its startTime — so this is shared infrastructure, not group state,
    -- despite what the deletion checklist at the top of this file used to say.
    -- Only the group's own resolveGen / casterShownFrame bookkeeping went.
    activeCasters[casterUnit] = nil

    -- (Removed) the on-frame teardown: the ProcessFrame closure, the
    -- IterateAllFrames walk it drove, the interrupted visual, and the local db
    -- they needed. The personal hide below resolves its own DB.

    -- Also hide personal targeted spell icon for this caster
    if GetPersonalDB().personalTargetedSpellEnabled then
        if wasInterrupted and GetPersonalDB().personalTargetedSpellShowInterrupted then
            -- Will show interrupted animation then hide
            DF:HidePersonalTargetedSpellIcon(casterUnit, false)
        else
            DF:HidePersonalTargetedSpellIcon(casterUnit, true)
        end
    end
end

-- ============================================================
-- SCANNING FUNCTIONS
-- ============================================================

-- Scan all enemy units for casts
local function ScanAllEnemyCasts()
    local enemyUnits = GetEnemyUnits()
    
    for _, unit in ipairs(enemyUnits) do
        if UnitExists(unit) then
            -- Check for casting
            local castName = UnitCastingInfo(unit)
            if castName then
                ProcessCast(unit, false)
            else
                -- Check for channeling
                local channelName = UnitChannelInfo(unit)
                if channelName then
                    ProcessCast(unit, true)
                end
            end
        end
    end
end

-- ============================================================
-- EVENT HANDLING
-- ============================================================

local function OnEvent(self, event, unit, ...)
    -- ============================================================
    -- Personal / group-frame Targeted Spells branch (existing)
    -- ============================================================
    if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_EMPOWER_START" then
        ProcessCast(unit, false)
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        ProcessCast(unit, true)
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        HandleCastStop(unit, true)  -- Was interrupted
    elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_FAILED" or
           event == "UNIT_SPELLCAST_FAILED_QUIET" or
           event == "UNIT_SPELLCAST_SUCCEEDED" or
           event == "UNIT_SPELLCAST_CHANNEL_STOP" or event == "UNIT_SPELLCAST_EMPOWER_STOP" then
        HandleCastStop(unit, false)  -- Normal end
    elseif event == "UNIT_TARGET" then
        -- Enemy changed target mid-cast. Updates the PERSONAL display; the
        -- group-frame fingerprint re-resolve that also ran here went with the
        -- on-frame feature.
        HandleTargetChange(unit)
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        -- New nameplate, check if casting
        local castName = UnitCastingInfo(unit)
        if castName then
            ProcessCast(unit, false)
        else
            local channelName = UnitChannelInfo(unit)
            if channelName then
                ProcessCast(unit, true)
            end
        end
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        HandleCastStop(unit, false)
    elseif event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_FOCUS_CHANGED" then
        ScanAllEnemyCasts()
    end
    -- (Removed) the GROUP_ROSTER_UPDATE / PLAYER_ROLES_ASSIGNED branch: it existed
    -- only to rebuild the group-frame roster fingerprints. Both events stay
    -- registered — the Targeted List branch below and other consumers still want
    -- the rest of the stream.

    -- ============================================================
    -- Targeted List branch (alpha/beta only, stubs until commit #4)
    -- ============================================================
    -- Routing through DF._TargetedList* shims so the handlers defined
    -- in the Targeted List section at the bottom of this file don't
    -- need to be forward-declared. Each handler is gated internally —
    -- calls are effectively free on stable builds.
    --
    -- The full event-to-handler wiring (castId unpacking, empower
    -- spellId offset, varargs forwarding, mob-death guards) is
    -- implemented in commit #4. This scaffold only needs to invoke
    -- the stubs so the file loads and the gating plumbing is exercised.
    if event == "UNIT_SPELLCAST_START"
       or event == "UNIT_SPELLCAST_CHANNEL_START"
       or event == "UNIT_SPELLCAST_EMPOWER_START" then
        if DF._TargetedListProcessCastStart then
            DF._TargetedListProcessCastStart(unit, event, ...)
        end
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        -- A nameplate can appear while its owner is ALREADY casting — walking into
        -- range, turning the camera, a mob streaming into a pull. The *_START events
        -- above already fired (or never will for us), so without this the bar only
        -- shows on that mob's NEXT cast. The Personal branch above has always done
        -- this; the list did not. Confirmed missing in game 2026-07-30.
        if DF._TargetedListPickupInProgressCast then
            DF._TargetedListPickupInProgressCast(unit)
        end
    elseif event == "UNIT_SPELLCAST_STOP"
           or event == "UNIT_SPELLCAST_FAILED"
           or event == "UNIT_SPELLCAST_FAILED_QUIET"
           or event == "UNIT_SPELLCAST_SUCCEEDED"
           or event == "UNIT_SPELLCAST_INTERRUPTED"
           or event == "UNIT_SPELLCAST_CHANNEL_STOP"
           or event == "UNIT_SPELLCAST_EMPOWER_STOP"
           or event == "NAME_PLATE_UNIT_REMOVED" then
        if DF._TargetedListOnCastStop then
            DF._TargetedListOnCastStop(unit, event, ...)
        end
    elseif event == "UNIT_SPELLCAST_DELAYED"
           or event == "UNIT_SPELLCAST_CHANNEL_UPDATE"
           or event == "UNIT_SPELLCAST_EMPOWER_UPDATE" then
        -- Mid-cast update: the cast duration or progress changed
        -- (pushback, channel extension, empower stage). Re-read
        -- the duration object and re-apply bar content so the fill
        -- and countdown stay in sync with the actual cast.
        if DF._TargetedListOnCastUpdate then
            DF._TargetedListOnCastUpdate(unit, event, ...)
        end
    elseif event == "UNIT_SPELLCAST_INTERRUPTIBLE" then
        if DF._TargetedListOnInterruptibilityChange then
            DF._TargetedListOnInterruptibilityChange(unit, true)
        end
    elseif event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
        if DF._TargetedListOnInterruptibilityChange then
            DF._TargetedListOnInterruptibilityChange(unit, false)
        end
    elseif event == "UNIT_TARGET" then
        -- Enemy changed target mid-cast. If we're tracking this
        -- caster, verify the new target is still a party member.
        -- If not, drop the bar. We can't pick up NEW casts from
        -- UNIT_TARGET (no spellId in payload), but we can drop
        -- existing ones that are no longer relevant.
        if DF._TargetedListOnTargetChange then
            DF._TargetedListOnTargetChange(unit)
        end
    elseif event == "LOADING_SCREEN_DISABLED"
           or event == "ZONE_CHANGED_NEW_AREA"
           or event == "UPDATE_INSTANCE_INFO" then
        -- Zone transition or loading screen: validate all tracked
        -- bars and remove any that are stale.
        if DF._TargetedListValidateAll then
            DF._TargetedListValidateAll()
        end
    elseif event == "CVAR_UPDATE" then
        -- If enemy nameplates are disabled, all bars should go.
        local cvar = ...
        if cvar == "nameplateShowEnemies" then
            local val = C_CVar and C_CVar.GetCVar and C_CVar.GetCVar("nameplateShowEnemies")
            if val == "0" then
                if DF._TargetedListReleaseAllBars then
                    DF._TargetedListReleaseAllBars()
                end
            end
        end
    end
end

eventFrame:SetScript("OnEvent", OnEvent)

-- ============================================================
-- NAMEPLATE OFFSCREEN CVAR
-- ============================================================

-- nameplateShowOffscreen is a GAME setting, not a DF profile setting: it is
-- account-wide and affects every nameplate, not just ours. So the CVar itself is
-- the source of truth — there is deliberately no saved key mirroring it. The
-- Targeted List / Personal Targeted checkboxes read and write it directly via
-- these two, and re-read on OnShow so a change made in the game menu shows up.
--
-- Why the features care (confirmed in game 2026-07-30, on 12.1): with this OFF,
-- an enemy outside your view gets NO nameplate at all, so there is no
-- nameplateN unit token — and IsValidCasterUnit accepts nameplate tokens only.
-- A mob casting behind you is invisible to both features until you turn to face
-- it, even when you have it targeted and can see the cast on its frame.
-- Not combat-protected, so the write is safe mid-fight.
function DF:SetNameplateOffscreen(enabled)
    if C_CVar and C_CVar.SetCVar then
        C_CVar.SetCVar("nameplateShowOffscreen", enabled and "1" or "0")
    end
end

function DF:GetNameplateOffscreen()
    if C_CVar and C_CVar.GetCVarBool then
        return C_CVar.GetCVarBool("nameplateShowOffscreen")
    end
    return false
end

-- ============================================================
-- ENABLE/DISABLE
-- ============================================================

-- Internal: register the cast-tracking events on eventFrame.
-- Used by both the group-frame Enable path and the personal-only path
-- (when group is API-blocked but personal display is on).
local function RegisterTargetedSpellEvents()
    eventFrame:RegisterEvent("UNIT_SPELLCAST_START")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_STOP")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_FAILED")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_FAILED_QUIET")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_EMPOWER_START")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_EMPOWER_STOP")
    -- Mid-cast update events: pushback, channel duration change, empower
    -- stage progression. Without these the bar desynchs from the actual
    -- cast when the enemy gets interrupted-but-not-stopped, pushed back,
    -- or an empower stage changes.
    eventFrame:RegisterEvent("UNIT_SPELLCAST_DELAYED")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_UPDATE")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_EMPOWER_UPDATE")
    -- Interruptibility toggles mid-cast (M+ phase changes).
    eventFrame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTIBLE")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_NOT_INTERRUPTIBLE")
    eventFrame:RegisterEvent("UNIT_TARGET")
    eventFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    eventFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
    eventFrame:RegisterEvent("PLAYER_FOCUS_CHANGED")
    -- Cleanup + zone transition events.
    eventFrame:RegisterEvent("LOADING_SCREEN_DISABLED")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    eventFrame:RegisterEvent("UPDATE_INSTANCE_INFO")
    -- CVAR changes that affect nameplate visibility.
    eventFrame:RegisterEvent("CVAR_UPDATE")
    -- (Removed) GROUP_ROSTER_UPDATE and PLAYER_ROLES_ASSIGNED. They were registered
    -- to "rebuild the fingerprint cache", which went with the group display — OnEvent
    -- has no branch for either, so both woke the handler and fell through every
    -- chain. Neither Personal nor the Targeted List asks about roster composition.
    eventFrame:Show()
end

-- Returns true if any consumer of the shared cast-event stream needs it
-- registered right now. Consumers are now the Personal Targeted Spells display
-- and the Targeted List; the group-frame display was removed, so its API-blocked
-- checks went with it. Checks both party and raid mode profiles because the addon
-- may switch modes based on group composition without us re-running this check.
local function NeedsCastEvents()
    if not DF.db then return false end
    local function modeNeeds(modeDb)
        if not modeDb then return false end
        return modeDb.personalTargetedSpellEnabled and true or false
    end
    if modeNeeds(DF.db.party) or modeNeeds(DF.db.raid) then return true end
    -- Targeted List is party-only
    if DF.TargetedListNeedsCastEvents and DF:TargetedListNeedsCastEvents() then
        return true
    end
    return false
end

-- Public: re-evaluate whether eventFrame should be registered. Call this
-- whenever any of the gating settings change (group toggle, personal toggle,
-- API block trip).
-- ⚠ THIS IS ONLY RE-EVALUATED FROM THREE PLACES: DF:InitTargetedSpells (once, from
-- Frames/Headers.lua) and the two feature toggles. It is NOT re-run on
-- PLAYER_ENTERING_WORLD or on a profile switch.
--
-- That matters because NeedsCastEvents() returns false when DF.db is not resolved
-- yet, and a false result UNREGISTERS EVERYTHING. So if Init ever wins the race
-- against profile load, both Personal Targeted and the Targeted List are silently
-- dead for the whole session until the user toggles a setting or reloads — which is
-- exactly what "it worked better after a /reload" looks like. Traced so that
-- condition is visible at login instead of being invisible.
function DF:UpdateTargetedSpellEventRegistration()
    local needed = NeedsCastEvents()
    if DF.DebugActive and DF:DebugActive("PERSONALTARGET") then
        DF:Debug("PERSONALTARGET", "cast events %s (db=%s, personal party=%s raid=%s, list=%s)",
            needed and "REGISTERED" or "unregistered",
            DF.db and "y" or "NO",
            (DF.db and DF.db.party and DF.db.party.personalTargetedSpellEnabled) and "y" or "n",
            (DF.db and DF.db.raid and DF.db.raid.personalTargetedSpellEnabled) and "y" or "n",
            (DF.db and DF.db.party and DF.db.party.targetedListEnabled) and "y" or "n")
    end
    if needed then
        RegisterTargetedSpellEvents()
    else
        eventFrame:UnregisterAllEvents()
        eventFrame:Hide()
        wipe(activeCasters)
    end
end

-- (Removed) DF:EnableTargetedSpells / DisableTargetedSpells / ToggleTargetedSpells
-- and the DF.targetedSpellsEnabled flag they maintained — the flag was written in
-- two places and read in none. These were the group feature's public API; the only
-- external caller was the Indicators > Targeted Spells page, removed with it.
--
-- ⚠ Deleting them does NOT orphan event registration, which was the risk worth
-- checking: DF:UpdateTargetedSpellEventRegistration is still called by the personal
-- toggle, the Targeted List toggle, and DF:InitTargetedSpells.

-- (Removed) DF:ScanAllEnemyCasts — a one-line export "for unified roster handler".
-- That handler was the GROUP_ROSTER_UPDATE branch cut from OnEvent, so the wrapper
-- has no callers.
--
-- ⚠ The file-local ScanAllEnemyCasts of the same name is LIVE — OnEvent's
-- PLAYER_TARGET_CHANGED / PLAYER_FOCUS_CHANGED branch calls it. Only the DF: export
-- is gone.

-- (Removed) SETUP WIZARD — DF:ShowTargetedSpellSetupWizard. It existed to opt the
-- user in to the group-frame display, which is gone. This was also the ONLY caller
-- of the DF:ShowPopupWizard runtime in Popup.lua, so that runtime is now dead too.

-- ============================================================
-- PERSONAL TARGETED SPELLS DISPLAY
-- Shows incoming spells targeting the player in center of screen
-- ============================================================

-- personalContainer, personalIcons, personalActiveSpells declared at top of file

-- Calculate mover size based on settings
local function GetPersonalMoverSize()
    local db = GetPersonalDB()
    local iconSize = db.personalTargetedSpellSize or 40
    local scale = db.personalTargetedSpellScale or 1.0
    local maxIcons = db.personalTargetedSpellMaxIcons or 5
    local spacing = db.personalTargetedSpellSpacing or 4
    local growthDirection = db.personalTargetedSpellGrowth or "RIGHT"
    
    local scaledSize = iconSize * scale
    local scaledSpacing = spacing * scale
    
    local width, height
    if growthDirection == "LEFT" or growthDirection == "RIGHT" or growthDirection == "CENTER_H" then
        width = maxIcons * scaledSize + (maxIcons - 1) * scaledSpacing
        height = scaledSize
    else
        width = scaledSize
        height = maxIcons * scaledSize + (maxIcons - 1) * scaledSpacing
    end
    
    return math.max(width, 50), math.max(height, 50)
end

-- Compute the container CENTER offset from the saved icon-block centre (x, y).
-- The saved position represents the visual midpoint of the icon block.  The
-- container is shifted opposite to the growth direction so that icon 1 (which
-- anchors to the container's CENTER) ends up in the right place, with the full
-- block symmetrically centred on the saved (x, y).
local function GetPersonalContainerPoint(x, y)
    local db = GetPersonalDB()
    local iconSize = db.personalTargetedSpellSize or 40
    local scale = db.personalTargetedSpellScale or 1.0
    local maxIcons = db.personalTargetedSpellMaxIcons or 5
    local spacing = db.personalTargetedSpellSpacing or 4
    local growthDirection = db.personalTargetedSpellGrowth or "RIGHT"

    local scaledSize = iconSize * scale
    local scaledSpacing = spacing * scale
    local halfBlock = (maxIcons - 1) / 2 * (scaledSize + scaledSpacing)

    local cx, cy = x, y
    if growthDirection == "RIGHT" then
        cx = x - halfBlock
    elseif growthDirection == "LEFT" then
        cx = x + halfBlock
    elseif growthDirection == "UP" then
        cy = y - halfBlock
    elseif growthDirection == "DOWN" then
        cy = y + halfBlock
    -- CENTER_H / CENTER_V: already symmetric, no adjustment needed
    end
    return cx, cy
end

-- Create the personal targeted spells container
local function CreatePersonalContainer()
    if personalContainer then return personalContainer end

    local db = GetPersonalDB()
    local x = db.personalTargetedSpellX or 0
    local y = db.personalTargetedSpellY or -150

    local container = CreateFrame("Frame", "DandersFramesPersonalTargetedSpells", UIParent)
    local w, h = GetPersonalMoverSize()
    container:SetSize(w, h)
    local cx, cy = GetPersonalContainerPoint(x, y)
    container:SetPoint("CENTER", UIParent, "CENTER", cx, cy)
    container:SetFrameStrata("HIGH")
    container:Hide()
    container:EnableMouse(false)
    container:SetHitRectInsets(10000, 10000, 10000, 10000)
    
    personalContainer = container
    DF.personalTargetedSpellsContainer = container
    
    return container
end

-- Create icon for personal display (similar to unit frame icons)
local function CreatePersonalIcon(index)
    CreatePersonalContainer()
    
    local icon = CreateFrame("Frame", nil, personalContainer)
    icon:SetSize(40, 40)
    icon:Hide()
    icon.index = index
    icon:EnableMouse(false)
    icon:SetHitRectInsets(10000, 10000, 10000, 10000)
    
    -- Importance filter frame - nested inside icon
    local importanceFilterFrame = CreateFrame("Frame", nil, icon)
    importanceFilterFrame:SetAllPoints()
    importanceFilterFrame:EnableMouse(false)
    importanceFilterFrame:SetHitRectInsets(10000, 10000, 10000, 10000)
    icon.importanceFilterFrame = importanceFilterFrame
    
    -- Main icon frame with border
    local iconFrame = CreateFrame("Frame", nil, importanceFilterFrame)
    iconFrame:SetAllPoints()
    iconFrame:EnableMouse(false)
    iconFrame:SetHitRectInsets(10000, 10000, 10000, 10000)
    icon.iconFrame = iconFrame
    
    -- Border via the unified DF.Border backend (Stage 4.4).
    -- ApplyPersonalIconSettings drives BuildSpec + Apply on each update.
    icon.border = DF.Border:New(iconFrame)
    
    -- Important spell highlight frame - set frame level ABOVE iconFrame so it renders on top
    local highlightFrame = CreateFrame("Frame", nil, iconFrame)
    highlightFrame:SetPoint("TOPLEFT", -5, 5)
    highlightFrame:SetPoint("BOTTOMRIGHT", 5, -5)
    highlightFrame:SetFrameLevel(iconFrame:GetFrameLevel() + 5)
    highlightFrame:Hide()
    highlightFrame:EnableMouse(false)
    highlightFrame:SetHitRectInsets(10000, 10000, 10000, 10000)
    icon.highlightFrame = highlightFrame
    -- DF.Border overlay for the important-spell highlight (Stage 2).
    icon.highlightBorder = DF.Border:New(highlightFrame)

    -- Icon texture - positioned with default 2px inset so it lines up
    -- with the border at creation time. ApplyPersonalIconSettings
    -- recomputes the inset from the db's BorderSize on every render
    -- (via the shared artInset path), so this value only matters for
    -- the brief moment between creation and first Apply.
    local defBorderSize = 2
    local texture = iconFrame:CreateTexture(nil, "ARTWORK")
    texture:SetPoint("TOPLEFT", defBorderSize, -defBorderSize)
    texture:SetPoint("BOTTOMRIGHT", -defBorderSize, defBorderSize)
    texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon.texture = texture
    icon.icon = texture
    
    -- Cooldown - attached to icon texture
    local cooldown = CreateFrame("Cooldown", nil, iconFrame, "CooldownFrameTemplate")
    cooldown:SetPoint("TOPLEFT", texture, "TOPLEFT", 0, 0)
    cooldown:SetPoint("BOTTOMRIGHT", texture, "BOTTOMRIGHT", 0, 0)
    cooldown:SetDrawEdge(false)
    cooldown:SetDrawBling(false)
    cooldown:SetDrawSwipe(true)
    cooldown:SetReverse(true)
    cooldown:SetHideCountdownNumbers(true)
    cooldown:EnableMouse(false)
    cooldown:SetHitRectInsets(10000, 10000, 10000, 10000)
    icon.cooldown = cooldown
    
    -- Text overlay (above cooldown)
    local textOverlay = CreateFrame("Frame", nil, iconFrame)
    textOverlay:SetAllPoints()
    textOverlay:SetFrameLevel(cooldown:GetFrameLevel() + 5)
    textOverlay:EnableMouse(false)
    textOverlay:SetHitRectInsets(10000, 10000, 10000, 10000)
    icon.textOverlay = textOverlay
    
    -- Duration text
    local durationText = textOverlay:CreateFontString(nil, "OVERLAY")
    DF.GUI:SetSettingsFont(durationText, 12, "OUTLINE")
    durationText:SetPoint("CENTER", iconFrame, "CENTER", 0, 0)
    durationText:SetTextColor(1, 1, 1, 1)
    icon.durationText = durationText
    
    -- Interrupted overlay
    local interruptOverlay = CreateFrame("Frame", nil, iconFrame)
    interruptOverlay:SetAllPoints()
    interruptOverlay:SetFrameLevel(cooldown:GetFrameLevel() + 10)
    interruptOverlay:Hide()
    interruptOverlay:EnableMouse(false)
    interruptOverlay:SetHitRectInsets(10000, 10000, 10000, 10000)
    icon.interruptOverlay = interruptOverlay
    
    local interruptTint = interruptOverlay:CreateTexture(nil, "OVERLAY")
    interruptTint:SetAllPoints()
    interruptTint:SetColorTexture(1, 0, 0, 0.5)
    icon.interruptTint = interruptTint
    
    local interruptX = interruptOverlay:CreateFontString(nil, "OVERLAY")
    DF.GUI:SetSettingsFont(interruptX, 20, "OUTLINE")
    interruptX:SetPoint("CENTER", iconFrame, "CENTER", 0, 0)
    interruptX:SetText("X")
    interruptX:SetTextColor(1, 0, 0, 1)
    icon.interruptX = interruptX
    
    -- OnUpdate for duration and cleanup
    local durationThrottle = 0
    icon:SetScript("OnUpdate", function(self, elapsed)
        if not self.isActive then return end
        
        -- Skip cleanup check for test mode icons
        if self.isTestIcon then
            -- Throttle test mode duration updates too
            durationThrottle = durationThrottle + elapsed
            if durationThrottle < 0.1 then return end
            durationThrottle = 0
            
            -- Only update duration text for test icons
            if self.testTimeRemaining and self.durationText and self.durationText:IsShown() then
                self.testTimeRemaining = self.testTimeRemaining - elapsed * 10  -- Compensate for throttle
                if self.testTimeRemaining < 0 then self.testTimeRemaining = 3.0 end  -- Loop
                self.durationText:SetFormattedText("%.1f", self.testTimeRemaining)
            end
            return
        end
        
        -- Handle interrupted animation (needs to run every frame for smooth animation)
        if self.isInterrupted then
            self.interruptTimer = (self.interruptTimer or 0) + elapsed
            local db = GetPersonalDB()
            local duration = db.personalTargetedSpellInterruptedDuration or 0.5
            
            if self.interruptTimer >= duration then
                DF:HidePersonalTargetedSpellIcon(self.casterKey, true, true)  -- fromTimer=true
            end
            return
        end
        
        -- Throttle duration text updates to ~10 FPS for performance
        durationThrottle = durationThrottle + elapsed
        if durationThrottle < 0.1 then return end
        durationThrottle = 0
        
        -- Update duration text from duration object
        -- TODO: Can use durationObject:EvaluateRemainingPercent(colorCurve) for dynamic color-by-time
        if self.durationObject and self.durationText and self.durationText:IsShown() then
            local ok, remaining = pcall(self.durationObject.GetRemainingDuration, self.durationObject)
            if ok and remaining then
                self.durationText:SetFormattedText("%.1f", remaining)
                if self.durationColor then
                    self.durationText:SetTextColor(self.durationColor.r, self.durationColor.g, self.durationColor.b, 1)
                end
            end
        end
        
        -- Note: Target change detection is handled by UNIT_TARGET event + HandleTargetChange
        -- which uses SetAlphaFromBoolean. We can't do boolean checks on secret values here.
    end)
    
    return icon
end

-- Get or create personal icon
local function GetPersonalIcon(index)
    if not personalIcons[index] then
        personalIcons[index] = CreatePersonalIcon(index)
    end
    return personalIcons[index]
end

-- Apply settings to a personal icon
local function ApplyPersonalIconSettings(icon, db, spellID)
    -- No borderColor read here: the colour comes from DF.Border:BuildSpec via the
    -- canonical personalTargetedSpell* keys, so a second local read went unused.
    local borderSize = db.personalTargetedSpellBorderSize or 2
    local showBorder = db.personalTargetedSpellShowBorder ~= false
    local showSwipe = db.personalTargetedSpellShowSwipe ~= false
    local showDuration = db.personalTargetedSpellShowDuration ~= false
    local durationFont = db.personalTargetedSpellDurationFont or "Fonts\\FRIZQT__.TTF"
    local durationScale = db.personalTargetedSpellDurationScale or 1.2
    local durationOutline = db.personalTargetedSpellDurationOutline or "OUTLINE"
    local durationX = db.personalTargetedSpellDurationX or 0
    local durationY = db.personalTargetedSpellDurationY or 0
    local durationColor = db.personalTargetedSpellDurationColor or {r = 1, g = 1, b = 1}
    local highlightImportant = db.personalTargetedSpellHighlightImportant ~= false
    -- Important-spell highlight reads the personalTargetedSpellImportant* border keys
    -- directly via BuildSpec (see the highlight block below); the old
    -- personalTargetedSpellHighlightStyle/Color/Size/Inset locals are retired here.
    local importantOnly = db.personalTargetedSpellImportantOnly
    
    if durationOutline == "NONE" then durationOutline = "" end
    
    -- Apply pixel perfect to border size
    if db.pixelPerfect then
        borderSize = DF:PixelPerfect(borderSize)
    end
    
    icon.durationColor = durationColor
    
    -- Important spell filter
    if icon.importanceFilterFrame then
        if importantOnly and spellID then
            local isImportant = C_Spell.IsSpellImportant(spellID)
            icon.importanceFilterFrame:SetAlphaFromBoolean(isImportant)
        else
            icon.importanceFilterFrame:SetAlpha(1)
        end
    end
    
    -- Important Spell Border: a second DF.Border (full toolkit via BuildSpec),
    -- shown on important spells, gated by the Highlight-Important toggle + the
    -- secret-safe isImportant alpha. Frame offset is inset-INDEPENDENT — the
    -- engine's spec.inset owns the inset symmetrically (keeps it centred).
    if icon.highlightFrame then
        local hlSize  = db.personalTargetedSpellImportantBorderSize or 3
        local offset  = borderSize + hlSize
        icon.highlightFrame:ClearAllPoints()
        icon.highlightFrame:SetPoint("TOPLEFT", icon.iconFrame, "TOPLEFT", -offset, offset)
        icon.highlightFrame:SetPoint("BOTTOMRIGHT", icon.iconFrame, "BOTTOMRIGHT", offset, -offset)
        if highlightImportant and spellID and icon.highlightBorder then
            local isImportant = C_Spell.IsSpellImportant(spellID)
            local spec = DF.Border:BuildSpec(db, "personalTargetedSpellImportant", { iconMode = true })
            spec.enabled = true
            DF.Border:Apply(icon.highlightBorder, spec)
            icon.highlightFrame:Show()
            icon.highlightFrame:SetAlphaFromBoolean(isImportant)
        else
            if icon.highlightBorder then DF.Border:Apply(icon.highlightBorder, { enabled = false }) end
            icon.highlightFrame:Hide()
        end
    end
    
    -- Border via unified DF.Border backend (Stage 4.4). BuildSpec reads
    -- canonical personalTargetedSpell* keys; we override size with the
    -- locally pixel-perfected value. Icon + cooldown inset by visible
    -- border thickness so artwork doesn't overlap the border edges (or
    -- sits flush with the icon frame when the border is off).
    if icon.border then
        local spec = DF.Border:BuildSpec(db, "personalTargetedSpell", { iconMode = true })
        spec.enabled = showBorder
        spec.size    = borderSize
        DF.Border:Apply(icon.border, spec)
    end

    local artInset = showBorder and borderSize or 0
    if icon.icon then
        icon.icon:ClearAllPoints()
        icon.icon:SetPoint("TOPLEFT", icon.iconFrame, "TOPLEFT", artInset, -artInset)
        icon.icon:SetPoint("BOTTOMRIGHT", icon.iconFrame, "BOTTOMRIGHT", -artInset, artInset)
    end
    if icon.cooldown then
        icon.cooldown:ClearAllPoints()
        icon.cooldown:SetPoint("TOPLEFT", icon.iconFrame, "TOPLEFT", artInset, -artInset)
        icon.cooldown:SetPoint("BOTTOMRIGHT", icon.iconFrame, "BOTTOMRIGHT", -artInset, artInset)
    end
    
    -- Cooldown swipe
    if icon.cooldown then
        icon.cooldown:SetDrawSwipe(showSwipe)
        icon.cooldown:SetHideCountdownNumbers(true)
    end
    
    -- Duration text
    if icon.durationText then
        if showDuration then
            icon.durationText:Show()
            local fontSize = 10 * durationScale
            DF:SafeSetFont(icon.durationText, durationFont, fontSize, durationOutline)
            icon.durationText:ClearAllPoints()
            icon.durationText:SetPoint("CENTER", icon.iconFrame, "CENTER", durationX, durationY)
            icon.durationText:SetTextColor(durationColor.r, durationColor.g, durationColor.b, 1)
        else
            icon.durationText:Hide()
        end
    end
    
    -- Interrupt visual settings
    local interruptTintColor = db.personalTargetedSpellInterruptedTintColor or {r = 1, g = 0, b = 0}
    local interruptTintAlpha = db.personalTargetedSpellInterruptedTintAlpha or 0.5
    local interruptShowX = db.personalTargetedSpellInterruptedShowX ~= false
    local interruptXColor = db.personalTargetedSpellInterruptedXColor or {r = 1, g = 0, b = 0}
    local interruptXSize = db.personalTargetedSpellInterruptedXSize or 20
    
    -- Apply interrupt tint settings
    if icon.interruptTint then
        icon.interruptTint:SetColorTexture(interruptTintColor.r, interruptTintColor.g, interruptTintColor.b, interruptTintAlpha)
    end
    
    -- Apply interrupt X mark settings
    if icon.interruptX then
        if interruptShowX then
            icon.interruptX:Show()
            icon.interruptX:SetTextColor(interruptXColor.r, interruptXColor.g, interruptXColor.b, 1)
            DF.GUI:SetSettingsFont(icon.interruptX, interruptXSize, "OUTLINE")
        else
            icon.interruptX:Hide()
        end
    end
end

-- Position personal icons
local function PositionPersonalIcons()
    local db = GetPersonalDB()
    if not personalContainer then return end
    
    local iconSize = db.personalTargetedSpellSize or 40
    local scale = db.personalTargetedSpellScale or 1.0
    local growthDirection = db.personalTargetedSpellGrowth or "RIGHT"
    local spacing = db.personalTargetedSpellSpacing or 4
    local maxIcons = db.personalTargetedSpellMaxIcons or 5
    
    -- Apply pixel perfect
    if db.pixelPerfect then
        iconSize = DF:PixelPerfect(iconSize)
        spacing = DF:PixelPerfect(spacing)
    end
    
    local scaledSize = iconSize * scale
    local scaledSpacing = spacing * scale
    
    -- Collect active spells
    local casterData = {}
    for casterKey, iconIndex in pairs(personalActiveSpells) do
        local icon = personalIcons[iconIndex]
        if icon and icon.isActive then
            table.insert(casterData, {
                casterKey = casterKey,
                iconIndex = iconIndex,
                startTime = icon.startTime or 0
            })
        end
    end
    
    -- Sort for consistent order
    table.sort(casterData, function(a, b)
        return a.casterKey < b.casterKey
    end)
    
    local numIcons = math.min(#casterData, maxIcons)
    
    for i = 1, #casterData do
        local data = casterData[i]
        local icon = personalIcons[data.iconIndex]
        
        if icon then
            if i <= maxIcons then
                local offsetX, offsetY = 0, 0
                local index = i - 1
                
                if growthDirection == "UP" then
                    offsetY = index * (scaledSize + scaledSpacing)
                elseif growthDirection == "DOWN" then
                    offsetY = -index * (scaledSize + scaledSpacing)
                elseif growthDirection == "LEFT" then
                    offsetX = -index * (scaledSize + scaledSpacing)
                elseif growthDirection == "RIGHT" then
                    offsetX = index * (scaledSize + scaledSpacing)
                elseif growthDirection == "CENTER_H" then
                    local centerOffset = (numIcons - 1) * (scaledSize + scaledSpacing) / 2
                    offsetX = index * (scaledSize + scaledSpacing) - centerOffset
                elseif growthDirection == "CENTER_V" then
                    local centerOffset = (numIcons - 1) * (scaledSize + scaledSpacing) / 2
                    offsetY = index * (scaledSize + scaledSpacing) - centerOffset
                end
                
                icon:ClearAllPoints()
                icon:SetPoint("CENTER", personalContainer, "CENTER", offsetX, offsetY)
                DF:SnapPointToPixelGrid(icon, db.pixelPerfect)
                icon:SetSize(scaledSize, scaledSize)
                icon.iconFrame:SetAllPoints(icon)
                
                icon:Show()
            else
                icon:Hide()
            end
        end
    end
end

-- Show a personal targeted spell icon
function DF:ShowPersonalTargetedSpellIcon(casterUnit, casterKey, spellID, texture, durationObject, isChannel, startTime)
    local db = GetPersonalDB()
    if not db.personalTargetedSpellEnabled then return end
    
    CreatePersonalContainer()
    
    -- Check if already tracking this caster
    if personalActiveSpells[casterKey] then
        return
    end
    
    -- Find available icon
    local iconIndex = nil
    for i = 1, db.personalTargetedSpellMaxIcons or 5 do
        local icon = GetPersonalIcon(i)
        if not icon.isActive then
            iconIndex = i
            break
        end
    end
    
    if not iconIndex then
        iconIndex = #personalIcons + 1
        GetPersonalIcon(iconIndex)
    end
    
    local icon = personalIcons[iconIndex]
    personalActiveSpells[casterKey] = iconIndex
    
    -- Setup icon
    icon.casterUnit = casterUnit
    icon.casterKey = casterKey
    icon.spellID = spellID
    icon.isChannel = isChannel
    icon.durationObject = durationObject
    icon.startTime = startTime or GetTime()
    icon.isActive = true
    icon.isInterrupted = false
    icon.interruptTimer = 0
    icon.isTestIcon = false
    
    -- Hide interrupt overlay
    if icon.interruptOverlay then
        icon.interruptOverlay:Hide()
    end
    
    -- Set icon texture
    if texture and icon.icon then
        icon.icon:SetTexture(texture)
        icon.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon.icon:SetDesaturated(false)
    end
    
    -- Apply settings
    ApplyPersonalIconSettings(icon, db, spellID)
    
    -- Set up cooldown from duration object
    if icon.cooldown and durationObject then
        icon.cooldown:SetCooldownFromDurationObject(durationObject)
    end
    
    -- Use SetAlphaFromBoolean to control visibility based on targeting
    local isTargetingPlayer = UnitIsUnit(casterUnit .. "target", "player")
    icon:SetAlphaFromBoolean(isTargetingPlayer, 1, 0)
    
    -- Show container
    personalContainer:Show()
    
    PositionPersonalIcons()
end

-- Hide a personal targeted spell icon
function DF:HidePersonalTargetedSpellIcon(casterKey, immediate, fromTimer)
    local iconIndex = personalActiveSpells[casterKey]
    if not iconIndex then return end
    
    local icon = personalIcons[iconIndex]
    if not icon then return end
    
    local db = GetPersonalDB()
    
    -- If already showing interrupt animation, only hide if timer completed (fromTimer=true)
    -- This prevents UNIT_SPELLCAST_STOP from hiding the icon during interrupt animation
    if icon.isInterrupted and not icon.isTestIcon and not fromTimer then
        return
    end
    
    -- Show interrupted animation if not immediate and enabled
    if not immediate and db.personalTargetedSpellShowInterrupted and not icon.isInterrupted and not icon.isTestIcon then
        icon.isInterrupted = true
        icon.interruptTimer = 0
        icon.interruptOverlay:Show()
        icon.durationText:Hide()
        if icon.icon then
            icon.icon:SetDesaturated(true)
        end
        return
    end
    
    -- Fully hide the icon
    icon.isActive = false
    icon.isInterrupted = false
    icon:Hide()
    if icon.highlightFrame then
        icon.highlightFrame:Hide()
        if icon.highlightBorder then DF.Border:Apply(icon.highlightBorder, { enabled = false }) end
    end
    icon.interruptOverlay:Hide()
    if icon.icon then
        icon.icon:SetDesaturated(false)
    end
    
    personalActiveSpells[casterKey] = nil
    
    PositionPersonalIcons()
    
    -- Hide container if no active spells
    local hasActive = false
    for _ in pairs(personalActiveSpells) do
        hasActive = true
        break
    end
    if not hasActive and personalContainer then
        personalContainer:Hide()
    end
end

-- Hide all personal targeted spell icons
function DF:HideAllPersonalTargetedSpells()
    for casterKey, iconIndex in pairs(personalActiveSpells) do
        local icon = personalIcons[iconIndex]
        if icon then
            icon.isActive = false
            icon.isInterrupted = false
            icon:Hide()
            if icon.highlightFrame then
                icon.highlightFrame:Hide()
                if icon.highlightBorder then DF.Border:Apply(icon.highlightBorder, { enabled = false }) end
            end
            icon.interruptOverlay:Hide()
            if icon.icon then
                icon.icon:SetDesaturated(false)
            end
        end
    end
    wipe(personalActiveSpells)
    
    if personalContainer then
        personalContainer:Hide()
    end
end

-- Update personal display position from settings
function DF:UpdatePersonalTargetedSpellsPosition()
    local db = GetPersonalDB()
    local x = db.personalTargetedSpellX or 0
    local y = db.personalTargetedSpellY or -150
    local iconAlpha = db.personalTargetedSpellAlpha or 1.0
    
    if personalContainer then
        personalContainer:ClearAllPoints()
        local cx, cy = GetPersonalContainerPoint(x, y)
        personalContainer:SetPoint("CENTER", UIParent, "CENTER", cx, cy)
        local w, h = GetPersonalMoverSize()
        personalContainer:SetSize(w, h)
        personalContainer:SetAlpha(iconAlpha)
    end
    
    -- Re-apply settings to active icons
    for casterKey, iconIndex in pairs(personalActiveSpells) do
        local icon = personalIcons[iconIndex]
        if icon and icon.isActive then
            ApplyPersonalIconSettings(icon, db, icon.spellID)
            icon:SetAlpha(iconAlpha)
        end
    end
    
    PositionPersonalIcons()
end

-- Update mover size to match settings
local function UpdateMoverSize()
    if not DF.personalTargetedSpellsMover then return end
    local w, h = GetPersonalMoverSize()
    DF.personalTargetedSpellsMover:SetSize(w, h)
end

-- Create mover for personal targeted spells
function DF:CreatePersonalTargetedSpellsMover()
    if DF.personalTargetedSpellsMover then return end
    
    CreatePersonalContainer()
    
    local w, h = GetPersonalMoverSize()
    
    local mover = CreateFrame("Frame", "DandersFramesPersonalTargetedSpellsMover", UIParent, "BackdropTemplate")
    mover:SetSize(w, h)
    mover:SetFrameStrata("DIALOG")
    -- No mode of its own (this display is not party- or raid-specific), so the
    -- mover follows whichever mode the options window is showing.
    DF.GUI:CreateMoverBackdrop(mover)
    mover:EnableMouse(true)
    mover:SetMovable(true)
    mover:RegisterForDrag("LeftButton")
    mover:Hide()
    
    local label = mover:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    label:SetPoint("CENTER")
    label:SetText("Personal\nTargeted Spells")
    label:SetTextColor(1, 1, 1, 1)
    mover.label = label

    -- Left-click switches the shared position panel to our mode.
    mover:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and DF.SetPositionPanelMode then
            DF:SetPositionPanelMode("personal")
        end
    end)

    mover:SetScript("OnDragStart", function(self)
        -- Switch the position panel to personal mode so nudge
        -- buttons affect us, not the party container.
        if DF.SetPositionPanelMode then
            DF:SetPositionPanelMode("personal")
        end
        self:StartMoving()

        local db = GetPersonalDB()
        self:SetScript("OnUpdate", function()
            -- Update icons to follow mover during drag
            local screenWidth, screenHeight = GetScreenWidth(), GetScreenHeight()
            local centerX, centerY = self:GetCenter()
            local x = centerX - screenWidth / 2
            local y = centerY - screenHeight / 2
            
            -- Update container position live
            if personalContainer then
                personalContainer:ClearAllPoints()
                local cx, cy = GetPersonalContainerPoint(x, y)
                personalContainer:SetPoint("CENTER", UIParent, "CENTER", cx, cy)
            end
            
            -- Snap preview
            if db.snapToGrid and DF.gridFrame and DF.gridFrame:IsShown() then
                DF:UpdateSnapPreview(self)
            end
        end)
    end)
    
    mover:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self:SetScript("OnUpdate", nil)
        DF:HideSnapPreview()
        
        local screenWidth, screenHeight = GetScreenWidth(), GetScreenHeight()
        local centerX, centerY = self:GetCenter()
        local x = centerX - screenWidth / 2
        local y = centerY - screenHeight / 2
        
        local db = GetPersonalDB()
        if db.snapToGrid and DF.gridFrame and DF.gridFrame:IsShown() then
            x, y = DF:SnapToGrid(x, y)
        end
        
        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "CENTER", x, y)
        
        -- Save to DB
        db.personalTargetedSpellX = x
        db.personalTargetedSpellY = y
        
        -- Update actual container
        DF:UpdatePersonalTargetedSpellsPosition()
    end)
    
    mover:SetScript("OnMouseDown", function(self, button)
        if button == "RightButton" then
            DF:LockFrames()
        end
    end)
    
    DF.personalTargetedSpellsMover = mover
end

-- Show/hide the personal targeted spells mover
function DF:ShowPersonalTargetedSpellsMover()
    if not DF.personalTargetedSpellsMover then
        DF:CreatePersonalTargetedSpellsMover()
    end
    
    local db = GetPersonalDB()
    local x = db.personalTargetedSpellX or 0
    local y = db.personalTargetedSpellY or -150
    
    UpdateMoverSize()
    DF.personalTargetedSpellsMover:ClearAllPoints()
    DF.personalTargetedSpellsMover:SetPoint("CENTER", UIParent, "CENTER", x, y)
    DF.personalTargetedSpellsMover:Show()
    
    -- Show test icons
    DF:ShowTestPersonalTargetedSpells()
end

function DF:HidePersonalTargetedSpellsMover()
    if DF.personalTargetedSpellsMover then
        DF.personalTargetedSpellsMover:Hide()
    end
    -- Hide test icons
    DF:HideTestPersonalTargetedSpells()
end

-- Test mode support for personal targeted spells
function DF:ShowTestPersonalTargetedSpells()
    local db = GetPersonalDB()
    if not db.personalTargetedSpellEnabled then return end
    
    CreatePersonalContainer()
    
    -- Clear any existing test icons
    DF:HideAllPersonalTargetedSpells()
    
    local maxIcons = db.personalTargetedSpellMaxIcons or 5
    local numTestIcons = math.min(3, maxIcons)  -- Show up to 3 test icons
    local iconAlpha = db.personalTargetedSpellAlpha or 1.0
    local importantOnly = db.personalTargetedSpellImportantOnly
    
    -- Test spells - include one interrupted if settings allow
    local testSpells = {
        {id = 686, texture = "Interface\\Icons\\Spell_Shadow_ShadowBolt", isImportant = true, isInterrupted = false},
        {id = 348, texture = "Interface\\Icons\\Spell_Fire_Immolation", isImportant = false, isInterrupted = false},
        {id = 172, texture = "Interface\\Icons\\Spell_Shadow_AbominationExplosion", isImportant = true, isInterrupted = db.personalTargetedSpellShowInterrupted},
    }
    
    for i = 1, numTestIcons do
        local testData = testSpells[i]
        
        -- Skip non-important spells if importantOnly is enabled
        if importantOnly and not testData.isImportant then
            -- Skip this icon but continue loop
        else
            local testKey = "test-personal-" .. i
            
            local icon = GetPersonalIcon(i)
            personalActiveSpells[testKey] = i
            
            -- Setup icon
            icon.casterUnit = nil
            icon.casterKey = testKey
            icon.spellID = testData.id
            icon.isChannel = false
            icon.durationObject = nil
            icon.startTime = GetTime()
            icon.isActive = true
            icon.isInterrupted = false
            icon.interruptTimer = 0
            icon.isTestIcon = true
            icon.testTimeRemaining = 2.0 + i * 0.5  -- Varying durations
            
            -- Set icon texture
            if icon.icon then
                icon.icon:SetTexture(testData.texture)
                icon.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                icon.icon:SetDesaturated(testData.isInterrupted)
            end
            
            -- Apply settings (use real spellID for importance check in test)
            ApplyPersonalIconSettings(icon, db, testData.isImportant and testData.id or nil)
            
            -- For test mode, manually set highlight visibility based on test data
            if icon.highlightFrame then
                if db.personalTargetedSpellHighlightImportant and testData.isImportant and not testData.isInterrupted then
                    icon.highlightFrame:Show()
                    icon.highlightFrame:SetAlpha(1)
                else
                    icon.highlightFrame:Hide()
                end
            end
            
            -- Show interrupt overlay for the test interrupted icon
            if icon.interruptOverlay then
                if testData.isInterrupted then
                    icon.interruptOverlay:Show()
                    icon.durationText:Hide()
                else
                    icon.interruptOverlay:Hide()
                end
            end
            
            -- Set up fake cooldown for test (3 second duration)
            if icon.cooldown then
                if testData.isInterrupted then
                    -- Interrupted icons show partial cooldown
                    icon.cooldown:SetCooldown(GetTime() - 1.5, 3)
                else
                    icon.cooldown:SetCooldown(GetTime(), 3)
                end
            end
            
            -- Apply alpha setting
            icon:SetAlpha(iconAlpha)
            
            icon:Show()
        end
    end
    
    -- Apply alpha to container as well
    if personalContainer then
        personalContainer:SetAlpha(iconAlpha)
    end
    
    -- Show container
    personalContainer:Show()
    
    PositionPersonalIcons()
end

function DF:HideTestPersonalTargetedSpells()
    DF:HideAllPersonalTargetedSpells()
end

-- Update test personal targeted spells (called when settings change)
function DF:UpdateTestPersonalTargetedSpells()
    -- Update if mover is shown OR if in test mode with personal enabled
    local db = GetPersonalDB()
    local moverShown = DF.personalTargetedSpellsMover and DF.personalTargetedSpellsMover:IsShown()
    -- Show personal targeted spells in test mode whenever personal is enabled. This
    -- deliberately does NOT consult a test-panel toggle: the group feature's
    -- testShowTargetedSpell key is gone, and Personal's own testShowPersonalTargeted
    -- is checked by DF:UpdateAllTestTargetedSpell before it reaches here.
    local inTestMode = (DF.testMode or DF.raidTestMode) and db.personalTargetedSpellEnabled
    
    if moverShown or inTestMode then
        UpdateMoverSize()
        DF:ShowTestPersonalTargetedSpells()
    end
end

-- Toggle personal targeted spells
function DF:TogglePersonalTargetedSpells(enabled)
    if enabled then
        CreatePersonalContainer()
        DF:CreatePersonalTargetedSpellsMover()
    else
        DF:HideAllPersonalTargetedSpells()
    end
    -- Re-evaluate event registration: personal display can keep events alive
    -- even when the group-frame side is off or API-blocked.
    DF:UpdateTargetedSpellEventRegistration()
end

-- ============================================================
-- CAST HISTORY (TEST FEATURE)
-- ============================================================

-- Clear cast history
function DF:ClearCastHistory()
    wipe(castHistory)
    -- Also clear the secrets table
    if DF.castHistorySecrets then
        wipe(DF.castHistorySecrets)
    end
    DF:Say("Cast history cleared")
    -- Refresh UI if open
    if DF.castHistoryFrame and DF.castHistoryFrame:IsShown() then
        DF:RefreshCastHistoryUI()
    end
end

-- Cast history UI frame
local castHistoryFrame = nil
local castHistoryRows = {}
local HISTORY_ROW_HEIGHT = 28
local ROWS_PER_PAGE = 10
local currentPage = 1

-- Create the cast history UI with PAGINATION (no scroll frame to avoid secret contamination)
function DF:CreateCastHistoryUI()
    if castHistoryFrame then return castHistoryFrame end
    
    -- Theme colors (matching GUI.lua)
    local C_BACKGROUND = {r = 0.08, g = 0.08, b = 0.08, a = 0.95}
    local C_PANEL      = {r = 0.12, g = 0.12, b = 0.12, a = 1}
    local C_ELEMENT    = {r = 0.18, g = 0.18, b = 0.18, a = 1}
    local C_BORDER     = {r = 0.25, g = 0.25, b = 0.25, a = 1}
    local C_ACCENT     = {r = 0.45, g = 0.45, b = 0.95, a = 1}
    local C_TEXT       = {r = 0.9, g = 0.9, b = 0.9, a = 1}
    local C_TEXT_DIM   = {r = 0.6, g = 0.6, b = 0.6, a = 1}
    
    -- Main frame
    local frame = CreateFrame("Frame", "DFCastHistoryFrame", UIParent, "BackdropTemplate")
    frame:SetSize(590, 404)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    frame:Hide()
    
    -- Backdrop - dark charcoal like main options
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(C_BACKGROUND.r, C_BACKGROUND.g, C_BACKGROUND.b, C_BACKGROUND.a)
    frame:SetBackdropBorderColor(0, 0, 0, 1)
    
    -- Title bar with accent color
    local titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    titleBar:SetHeight(32)
    titleBar:SetPoint("TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", 0, 0)
    titleBar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    titleBar:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 1)
    titleBar:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    
    local title = titleBar:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    title:SetPoint("LEFT", 10, 4)
    title:SetText("Cast History")
    title:SetTextColor(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b)
    
    -- Subtitle note
    local subtitle = titleBar:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, 0)
    subtitle:SetText("Persists through load screens, resets on /reload")
    subtitle:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.7)
    
    -- Close button (styled X)
    local closeBtn = CreateFrame("Button", nil, titleBar, "BackdropTemplate")
    closeBtn:SetSize(20, 20)
    closeBtn:SetPoint("RIGHT", -4, 0)
    closeBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    closeBtn:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    closeBtn:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    local closeIcon = closeBtn:CreateTexture(nil, "OVERLAY")
    closeIcon:SetPoint("CENTER", 0, 0)
    closeIcon:SetSize(12, 12)
    closeIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\close")
    closeIcon:SetVertexColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    closeBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.4, 0.15, 0.15, 1)
        closeIcon:SetVertexColor(1, 0.3, 0.3)
    end)
    closeBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        closeIcon:SetVertexColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    end)
    closeBtn:SetScript("OnClick", function() frame:Hide() end)
    
    -- Clear button (themed)
    local clearBtn = CreateFrame("Button", nil, titleBar, "BackdropTemplate")
    clearBtn:SetSize(50, 20)
    clearBtn:SetPoint("RIGHT", closeBtn, "LEFT", -5, 0)
    clearBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    clearBtn:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    clearBtn:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    local clearTxt = clearBtn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    clearTxt:SetPoint("CENTER")
    clearTxt:SetText("Clear")
    clearTxt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    clearBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.25, 0.25, 0.25, 1)
    end)
    clearBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    end)
    clearBtn:SetScript("OnClick", function()
        DF:ClearCastHistory()
    end)
    
    -- Column headers
    local headerFrame = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    headerFrame:SetHeight(22)
    headerFrame:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, -2)
    headerFrame:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", 0, -2)
    headerFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    headerFrame:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 1)
    headerFrame:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.3)
    
    local headerTime = headerFrame:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    headerTime:SetPoint("LEFT", 5, 0)
    headerTime:SetWidth(30)
    headerTime:SetText("Time")
    headerTime:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    local headerSpell = headerFrame:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    headerSpell:SetPoint("LEFT", 40, 0)
    headerSpell:SetWidth(100)
    headerSpell:SetText("Spell")
    headerSpell:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    local headerCaster = headerFrame:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    headerCaster:SetPoint("LEFT", 165, 0)
    headerCaster:SetWidth(70)
    headerCaster:SetText("Caster")
    headerCaster:SetTextColor(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b)
    
    -- Player name headers (will be updated dynamically)
    frame.playerHeaders = {}
    for i = 1, 5 do
        local header = headerFrame:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        header:SetPoint("LEFT", 240 + (i-1) * 65, 0)
        header:SetWidth(60)
        header:SetJustifyH("CENTER")
        header:SetTextColor(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b)
        header:Hide()
        frame.playerHeaders[i] = header
    end
    
    -- Content area (no scroll frame!)
    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", headerFrame, "BOTTOMLEFT", 0, -2)
    content:SetPoint("TOPRIGHT", headerFrame, "BOTTOMRIGHT", 0, -2)
    content:SetHeight(ROWS_PER_PAGE * HISTORY_ROW_HEIGHT)
    frame.content = content
    
    -- Store theme colors for row access
    frame.themeColors = {
        C_BACKGROUND = C_BACKGROUND,
        C_PANEL = C_PANEL,
        C_ELEMENT = C_ELEMENT,
        C_BORDER = C_BORDER,
        C_ACCENT = C_ACCENT,
        C_TEXT = C_TEXT,
        C_TEXT_DIM = C_TEXT_DIM,
    }
    
    -- Create row pool for current page only
    for i = 1, ROWS_PER_PAGE do
        local row = CreateFrame("Frame", nil, content, "BackdropTemplate")
        row:SetHeight(HISTORY_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i-1) * HISTORY_ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -(i-1) * HISTORY_ROW_HEIGHT)
        row:EnableMouse(true)
        row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
        row:SetBackdropColor(C_BACKGROUND.r, C_BACKGROUND.g, C_BACKGROUND.b, 0)
        row.rowIndex = i  -- Store for alternating colors
        
        -- Time text
        local timeText = row:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        timeText:SetPoint("LEFT", 5, 0)
        timeText:SetWidth(30)
        timeText:SetJustifyH("LEFT")
        timeText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        row.timeText = timeText
        
        -- Icon frame with border
        local iconFrame = CreateFrame("Frame", nil, row, "BackdropTemplate")
        iconFrame:SetSize(22, 22)
        iconFrame:SetPoint("LEFT", 35, 0)
        iconFrame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        iconFrame:SetBackdropColor(0, 0, 0, 0.5)
        iconFrame:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 1)
        
        local icon = iconFrame:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 1, -1)
        icon:SetPoint("BOTTOMRIGHT", -1, 1)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.icon = icon
        row.iconFrame = iconFrame
        
        -- Interrupted X overlay
        local interruptedX = iconFrame:CreateTexture(nil, "OVERLAY")
        interruptedX:SetAllPoints()
        interruptedX:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
        interruptedX:SetVertexColor(1, 0.3, 0.3, 0.9)
        interruptedX:Hide()
        row.interruptedX = interruptedX
        
        -- Important spell border (controlled by SetAlphaFromBoolean)
        local importantBorder = CreateFrame("Frame", nil, row, "BackdropTemplate")
        importantBorder:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", -2, 2)
        importantBorder:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", 2, -2)
        importantBorder:SetBackdrop({
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 2,
        })
        importantBorder:SetBackdropBorderColor(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 1)  -- Accent color
        importantBorder:SetAlpha(0)
        row.importantBorder = importantBorder
        
        -- Spell name
        local nameText = row:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        nameText:SetPoint("LEFT", iconFrame, "RIGHT", 4, 0)
        nameText:SetWidth(100)
        nameText:SetJustifyH("LEFT")
        nameText:SetWordWrap(false)
        nameText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        row.nameText = nameText
        
        -- Caster name
        local casterText = row:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        casterText:SetPoint("LEFT", 165, 0)
        casterText:SetWidth(70)
        casterText:SetJustifyH("LEFT")
        casterText:SetWordWrap(false)
        casterText:SetTextColor(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b)
        row.casterText = casterText
        
        -- Target indicators (5 columns for party members)
        row.targetIndicators = {}
        for j = 1, 5 do
            local container = CreateFrame("Frame", nil, row)
            container:SetSize(60, 20)
            container:SetPoint("LEFT", 240 + (j-1) * 65, 0)
            
            -- YES frame (shown when targeted)
            local yesFrame = CreateFrame("Frame", nil, container)
            yesFrame:SetAllPoints()
            local yesText = yesFrame:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
            yesText:SetAllPoints()
            yesText:SetText("|cffff6666YES|r")
            yesText:SetJustifyH("CENTER")
            container.yesFrame = yesFrame
            
            -- No frame (shown when not targeted)
            local noFrame = CreateFrame("Frame", nil, container)
            noFrame:SetAllPoints()
            local noText = noFrame:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
            noText:SetAllPoints()
            noText:SetText("|cff444444-|r")
            noText:SetJustifyH("CENTER")
            container.noFrame = noFrame
            
            -- N/A text
            local naText = container:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
            naText:SetAllPoints()
            naText:SetText("|cff222222--|r")
            naText:SetJustifyH("CENTER")
            naText:Hide()
            container.naText = naText
            
            container:Hide()
            row.targetIndicators[j] = container
        end
        
        -- Tooltip on hover with themed highlight
        row:SetScript("OnEnter", function(self)
            self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 0.8)
            -- Only show spell tooltips out of combat (some spells are "secret" in combat)
            if self.spellID and not InCombatLockdown() then
                GameTooltip:SetOwner(self.iconFrame, "ANCHOR_RIGHT")
                -- Still wrap in pcall as a safety net
                local success = pcall(function()
                    GameTooltip:SetSpellByID(self.spellID)
                end)
                if success then
                    GameTooltip:Show()
                else
                    GameTooltip:Hide()
                end
            end
        end)
        row:SetScript("OnLeave", function(self)
            -- Restore alternating background
            if self.rowIndex % 2 == 0 then
                self:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.5)
            else
                self:SetBackdropColor(C_BACKGROUND.r, C_BACKGROUND.g, C_BACKGROUND.b, 0)
            end
            GameTooltip:Hide()
        end)
        
        row:Hide()
        castHistoryRows[i] = row
    end
    
    -- Pagination controls at bottom (themed)
    local pageFrame = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    pageFrame:SetHeight(32)
    pageFrame:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    pageFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    pageFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    pageFrame:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 1)
    pageFrame:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.3)
    
    -- Helper to create themed button
    local function CreateThemedButton(parent, text)
        local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        btn:SetSize(60, 22)
        btn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        btn:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        btn:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
        
        local btnText = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        btnText:SetPoint("CENTER")
        btnText:SetText(text)
        btnText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        btn.text = btnText
        btn.isEnabled = true
        
        btn:SetScript("OnEnter", function(self)
            if self.isEnabled then
                self:SetBackdropColor(C_ACCENT.r * 0.5, C_ACCENT.g * 0.5, C_ACCENT.b * 0.5, 1)
            end
        end)
        btn:SetScript("OnLeave", function(self)
            if self.isEnabled then
                self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
            end
        end)
        
        -- Custom SetEnabled for themed button
        btn.SetEnabled = function(self, enabled)
            self.isEnabled = enabled
            if enabled then
                self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
                self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
                self.text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                self:EnableMouse(true)
            else
                self:SetBackdropColor(0.1, 0.1, 0.1, 0.5)
                self:SetBackdropBorderColor(0.15, 0.15, 0.15, 0.3)
                self.text:SetTextColor(0.4, 0.4, 0.4)
                self:EnableMouse(false)
            end
        end
        
        return btn
    end
    
    local prevBtn = CreateThemedButton(pageFrame, "< Prev")
    prevBtn:SetPoint("LEFT", 10, 0)
    prevBtn:SetScript("OnClick", function()
        if currentPage > 1 then
            currentPage = currentPage - 1
            DF:RefreshCastHistoryUI()
        end
    end)
    frame.prevBtn = prevBtn
    
    local nextBtn = CreateThemedButton(pageFrame, "Next >")
    nextBtn:SetPoint("RIGHT", -10, 0)
    nextBtn:SetScript("OnClick", function()
        local maxPage = math.ceil(#castHistory / ROWS_PER_PAGE)
        if currentPage < maxPage then
            currentPage = currentPage + 1
            DF:RefreshCastHistoryUI()
        end
    end)
    frame.nextBtn = nextBtn
    
    local pageText = pageFrame:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    pageText:SetPoint("CENTER", 0, 0)
    pageText:SetText("Page 1 / 1")
    pageText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    frame.pageText = pageText
    
    castHistoryFrame = frame
    DF.castHistoryFrame = frame
    
    return frame
end

-- Update player headers
local function UpdatePlayerHeaders()
    if not castHistoryFrame then return end
    
    local headers = castHistoryFrame.playerHeaders
    local sortOrder = {"player", "party1", "party2", "party3", "party4"}
    
    local idx = 1
    for _, unit in ipairs(sortOrder) do
        if unit == "player" or UnitExists(unit) then
            local name = UnitName(unit) or unit
            if #name > 7 then
                name = name:sub(1, 6) .. ".."
            end
            headers[idx]:SetText(name)
            headers[idx]:Show()
            idx = idx + 1
        end
    end
    
    for i = idx, 5 do
        headers[i]:Hide()
    end
end

-- Refresh the cast history UI with pagination
function DF:RefreshCastHistoryUI()
    if not castHistoryFrame then return end
    
    UpdatePlayerHeaders()
    
    local currentTime = GetTime()
    local totalEntries = #castHistory
    local maxPage = math.max(1, math.ceil(totalEntries / ROWS_PER_PAGE))
    
    -- Clamp current page
    if currentPage > maxPage then currentPage = maxPage end
    if currentPage < 1 then currentPage = 1 end
    
    -- Update page text
    castHistoryFrame.pageText:SetText(string.format("Page %d / %d  (%d casts)", currentPage, maxPage, totalEntries))
    
    -- Enable/disable pagination buttons
    castHistoryFrame.prevBtn:SetEnabled(currentPage > 1)
    castHistoryFrame.nextBtn:SetEnabled(currentPage < maxPage)
    
    -- Build current group order
    local sortOrder = {"player", "party1", "party2", "party3", "party4"}
    local activeUnits = {}
    for _, unit in ipairs(sortOrder) do
        if unit == "player" or UnitExists(unit) then
            table.insert(activeUnits, unit)
        end
    end
    
    -- Calculate which entries to show
    local startIdx = (currentPage - 1) * ROWS_PER_PAGE + 1
    
    -- Update rows
    for i, row in ipairs(castHistoryRows) do
        local entryIdx = startIdx + i - 1
        local entry = castHistory[entryIdx]
        
        if entry then
            -- Time
            local timeAgo = currentTime - entry.timestamp
            local timeStr
            if timeAgo < 60 then
                timeStr = string.format("%.0fs", timeAgo)
            elseif timeAgo < 3600 then
                timeStr = string.format("%.0fm", timeAgo / 60)
            else
                timeStr = string.format("%.0fh", timeAgo / 3600)
            end
            row.timeText:SetText(timeStr)
            
            -- Icon - just pass directly, let WoW handle it
            row.icon:SetTexture(entry.texture)
            row.spellID = entry.spellID
            
            -- Get secrets from separate table
            local secrets = DF.castHistorySecrets and DF.castHistorySecrets[entry.entryID]
            
            -- Important spell border - use SetAlphaFromBoolean directly (can't test secrets)
            -- If secrets exist, pass the isImportant secret; otherwise hide the border
            if secrets then
                row.importantBorder:SetAlphaFromBoolean(secrets.isImportant, 1, 0)
            else
                row.importantBorder:SetAlpha(0)
            end
            
            -- Alternating background (themed)
            if i % 2 == 0 then
                row:SetBackdropColor(0.12, 0.12, 0.12, 0.5)  -- C_PANEL
            else
                row:SetBackdropColor(0.08, 0.08, 0.08, 0)    -- C_BACKGROUND
            end
            
            -- Interrupted visual
            if entry.interrupted then
                row.interruptedX:Show()
                row.icon:SetDesaturated(true)
                row.icon:SetVertexColor(0.6, 0.6, 0.6)
            else
                row.interruptedX:Hide()
                row.icon:SetDesaturated(false)
                row.icon:SetVertexColor(1, 1, 1)
            end
            
            -- Name - just pass directly, let WoW handle secrets
            row.nameText:SetText(entry.name)
            
            -- Caster name - just pass directly
            row.casterText:SetText(entry.casterName)
            
            -- Hide all target indicators first
            for _, indicator in ipairs(row.targetIndicators) do
                indicator:Hide()
            end
            
            -- Show target indicators
            if entry.targetNames and secrets and secrets.targets then
                for idx, unit in ipairs(activeUnits) do
                    local hasName = entry.targetNames[unit]
                    local targetSecret = secrets.targets[unit]
                    local indicator = row.targetIndicators[idx]

                    -- We can compare to nil (type check, doesn't propagate secret
                    -- taint). After Blizzard's 2026-04-07 UnitIsUnit hotfix the
                    -- per-party-member targeting result is nil, so anything other
                    -- than the player will fall through to the N/A branch.
                    if hasName and indicator and targetSecret ~= nil then
                        -- Use SetAlphaFromBoolean for secret display
                        indicator.yesFrame:SetAlphaFromBoolean(targetSecret, 1, 0)
                        indicator.noFrame:SetAlphaFromBoolean(targetSecret, 0, 1)
                        indicator.naText:Hide()
                        indicator:Show()
                    elseif indicator then
                        indicator.yesFrame:SetAlpha(0)
                        indicator.noFrame:SetAlpha(0)
                        indicator.naText:Show()
                        indicator:Show()
                    end
                end
            end
            
            row:Show()
        else
            row:Hide()
        end
    end
end

-- Show cast history UI
function DF:ShowCastHistoryUI()
    local frame = DF:CreateCastHistoryUI()
    currentPage = 1  -- Reset to first page
    DF:RefreshCastHistoryUI()
    frame:Show()
    
    -- Set up periodic refresh while open
    if not frame.refreshTicker then
        frame.refreshTicker = C_Timer.NewTicker(1, function()
            if frame:IsShown() then
                DF:RefreshCastHistoryUI()
            end
        end)
    end
end

-- Legacy chat output (keep for quick debug)
function DF:ShowCastHistory()
    DF:ShowCastHistoryUI()
end

-- ============================================================
-- TARGETED LIST
-- ============================================================
-- Stacked cast-bar display showing enemy casts targeting party
-- members. Anchored to the party frame container. Replaces the
-- group-frame Targeted Spells icons that Blizzard's 2026-04-07
-- UnitIsUnit hotfix permanently broke.
--
-- Party-mode only by design. We will not add raid support.
--
-- Implementation is split across commits:
--   * commit #3 (this one): scaffold — state tables, frame pool,
--     roster name cache, event hookup, empty lifecycle stubs
--   * commit #4: cast lifecycle (0.2s delay + all 13 gotchas from
--     the TS3 cross-reference in _Reference/targeted-spells-findings.md)
--   * commit #5: render pipeline + layout (bar build, LayoutBars,
--     Dispel-style skip-rebuild in the apply path)
--   * commit #6: settings sub-tab in Options.lua
--
-- The user-facing name "Targeted List" is intentionally decoupled
-- from the internal `targetedList*` db prefix. Renaming the feature
-- is a locale-only change; no code touches the string.
-- ============================================================

-- File-scope cached APIs (project convention, commit 1a5603d).
-- These are used by the cast lifecycle and render pipeline in later
-- commits; caching them here keeps the hot path zero-lookup.
local TL_UnitSpellTargetName = UnitSpellTargetName
local TL_UnitSpellTargetClass = UnitSpellTargetClass
local TL_UnitCastingInfo = UnitCastingInfo
local TL_UnitChannelInfo = UnitChannelInfo
local TL_UnitCastingDuration = UnitCastingDuration
local TL_UnitChannelDuration = UnitChannelDuration
local TL_UnitNameFromGUID = UnitNameFromGUID
local TL_UnitClassFromGUID = UnitClassFromGUID
local TL_UnitInParty = UnitInParty
local TL_UnitCanAttack = UnitCanAttack
local TL_UnitExists = UnitExists
-- (Removed) TL_UnitName / TL_UnitClass upvalue caches — unused. The list resolves
-- both through TL_UnitNameFromGUID / TL_UnitClassFromGUID, which is what made these
-- two look used to a substring search.
local TL_IsInGroup = IsInGroup
local TL_IsInRaid = IsInRaid
local TL_GetTime = GetTime
local TL_C_Timer_After = C_Timer and C_Timer.After

-- ------------------------------------------------------------
-- State
-- ------------------------------------------------------------

-- activeTargetedListCasts[casterUnit] = {
--     spellId         = number,       -- clean (from event payload)
--     isChannel       = bool,         -- clean
--     startTime       = number,       -- clean local GetTime() approximation
--     duration        = TimerDuration, -- opaque object, fed to SetTimerDuration
--     uninterruptible = secret-bool,  -- only fed to SetVertexColorFromBoolean
--     casterUnit      = string,       -- clean (we generated it)
-- }
local activeTargetedListCasts = {}

-- Container frame that anchors the bar list in screen space. Created
-- on first enable. All children use the mover-driven position; there
-- is no party-frame anchor mode.
local targetedListContainer = nil

-- Frame pool + active bar array are declared further down in the
-- render pipeline section, close to the functions that use them.

-- Forward declaration: TargetedList_OnCastStop (below) calls
-- TargetedList_StartFadeTicker to kick off the fade-out re-render
-- ticker. The actual assignment happens in the render section far
-- below, because the ticker needs to call TargetedList_Render which
-- isn't defined until then. The file-local binding is hoisted here
-- so OnCastStop's reference resolves to the eventual assignment
-- rather than creating a stray global.
local TargetedList_StartFadeTicker

-- ------------------------------------------------------------
-- Runtime gate
-- ------------------------------------------------------------

-- Single source of truth for "is this feature allowed to run at all".
-- Every public entry point calls this; any time it returns false, the
-- caller must be a no-op.
local function TargetedList_IsGateOpen()
    return true
end

-- Map the current content type (from the shared GetContentType
-- helper above in this file) to the corresponding db toggle key.
local TARGETEDLIST_CONTENT_TYPE_KEY = {
    openworld   = "targetedListInOpenWorld",
    dungeon     = "targetedListInDungeons",
    raid        = "targetedListInRaids",
    arena       = "targetedListInArena",
    battleground = "targetedListInBattlegrounds",
}

-- Returns true if the user has enabled the feature for the current
-- content type. Gates the lifecycle so we don't pick up casts in
-- zones the user doesn't care about (e.g. disabling in open world).
local function TargetedList_ContentTypeAllowed(party)
    if not party then return false end
    local contentType = GetContentType()
    local key = TARGETEDLIST_CONTENT_TYPE_KEY[contentType]
    if not key then return true end  -- unknown → allow
    return party[key] ~= false
end

-- Secondary check: is the feature currently enabled by the user AND
-- are we in a party (not raid, not solo)? Used by the cast lifecycle
-- to decide whether to process incoming cast events.
--
-- NOTE: the content-type filter is deliberately NOT checked here.
-- It's checked separately at pickup time only (TargetedList_ShouldPickup)
-- so that stop events still clear tracked state even if the user
-- toggles content-type checkboxes mid-cast. Otherwise stale bars
-- would get stuck on screen until the next reload.
-- Returns ok, reason. The reason is a plain literal for the TARGETEDLIST log — every
-- caller uses `if not TargetedList_IsActive() then`, so the extra return is inert
-- for them. Reasons exist because a missing bar used to be completely silent: the
-- pickup path logged only successes, so there was no way to tell which gate ate a
-- cast. Never put a secret value in one of these strings.
local function TargetedList_IsActive()
    if not TargetedList_IsGateOpen() then return false, "dev gate closed (release build)" end
    if not DF.db then return false, "no profile loaded yet" end
    local party = DF.db.party
    if not party or not party.targetedListEnabled then return false, "Targeted List is off in settings" end
    if not TL_IsInGroup() then return false, "not in a group (party-only feature)" end
    if TL_IsInRaid() then return false, "in a raid (party-only feature)" end
    return true
end

-- Pickup-time gate: IsActive + content-type filter. Only applied
-- when deciding whether to START tracking a new cast. Cast-stop and
-- interruptibility-change handlers use IsActive alone so they can
-- clean up existing state regardless of content-type settings.
local function TargetedList_ShouldPickup()
    local ok, why = TargetedList_IsActive()
    if not ok then return false, why end
    local party = DF.db.party
    if not TargetedList_ContentTypeAllowed(party) then
        return false, "content-type filter excludes this instance type"
    end
    return true
end

-- Exposed for NeedsCastEvents below, so the shared event frame stays
-- registered when the Targeted List is the only active consumer.
function DF:TargetedListNeedsCastEvents()
    if not TargetedList_IsGateOpen() then return false end
    if not DF.db then return false end
    -- Party-only feature, but the raid profile may also toggle it on
    -- even though it won't actually render. Still register events so
    -- the user can see the toggle behave consistently in both modes.
    local p = DF.db.party
    return p and p.targetedListEnabled == true
end

-- ------------------------------------------------------------
-- Cast-targeting filter
-- ------------------------------------------------------------

-- Returns true if the caster's current cast target is a party member.
--
-- Why this shape: the "name-matching" approach the findings doc
-- originally proposed is dead because UnitSpellTargetName returns a
-- secret-tainted string on nameplates — it can't be used as a table
-- key or compared to anything. Instead we use TS3's filter
-- (Driver.lua:317): UnitInParty("nameplateXtarget"). This is a
-- compound-vs-party-token comparison that the findings doc warned
-- might be blocked by the 2026-04-07 hotfix. Empirically (and per
-- TS3's working implementation) it is NOT blocked — it returns a
-- usable boolean for this specific shape.
--
-- We don't return WHICH party member is targeted — we don't need to.
-- The render pipeline (commit #5) will fetch the target name via
-- UnitSpellTargetName and feed it directly into a FontString:SetText
-- secret-safe sink, which doesn't require comparing or indexing.
-- Returns ok, reason (see TargetedList_IsActive for why).
--
-- ⚠ The last check is the one to distrust if bars go missing in a group. The comment
-- block above claims UnitInParty on a compound token is "empirically NOT blocked" by
-- the 2026-04-07 hotfix. That is an ASSERTION, not something we have measured on this
-- build. If 12.1 did seal it, this returns false for every real party target and the
-- only bars you'd ever see are untargeted casts — which looks exactly like "the list
-- misses a lot". The trace below distinguishes the two cases.
local function TargetedList_CastTargetIsPartyMember(casterUnit)
    local target = casterUnit .. "target"
    if not TL_UnitExists(target) then return false, "cast has no target" end
    -- Reject mob-targeting-mob casts (we'd never care about those)
    if TL_UnitCanAttack("player", target) then return false, "target is an enemy (mob vs mob)" end
    -- The actual filter: is the targeted unit a party member?
    -- TS3 uses this exact compound-vs-party check post-hotfix.
    if TL_IsInGroup() and not TL_UnitInParty(target) then
        return false, "UnitInParty(<caster>target) false — not a party member, OR the API is sealed"
    end
    return true
end

-- ------------------------------------------------------------
-- Cast lifecycle
-- ------------------------------------------------------------
-- Implements the 13 correctness gotchas captured in
-- _Reference/targeted-spells-findings.md §"Implementation gotchas".
-- Each gotcha is tagged inline as (gotcha #N).

-- Delay before we read cast data after UNIT_SPELLCAST_START. At the
-- instant the event fires, UnitSpellTargetName / UnitCastingDuration /
-- UnitChannelDuration all return nil — the engine populates them a
-- few frames later. TS3 uses 0.2s; match that. (gotcha #1)
local TARGETEDLIST_PICKUP_DELAY = 0.2

-- Is this unit a nameplate we're willing to look at? Filters out
-- friendly nameplates, party-member nameplates (wargames/mercenary),
-- and anything that isn't a valid enemy unit token.
-- Returns ok, reason (see TargetedList_IsActive for why).
--
-- ⚠ THE NAMEPLATE REQUIREMENT IS THE FEATURE'S HARD CEILING. Only `nameplateN`
-- tokens are accepted, so an enemy with no nameplate is invisible to this feature no
-- matter what it casts. That makes the list sensitive to the nameplate CVars —
-- nameplateShowEnemies (off = nothing at all), nameplateShowOffscreen (off = casters
-- behind you or off-screen never appear), nameplateMaxDistance — and to WoW's own
-- cap on simultaneous nameplates.
local function TargetedList_IsRelevantCaster(casterUnit)
    if type(casterUnit) ~= "string" then return false, "not a unit token" end
    if string.sub(casterUnit, 1, 9) ~= "nameplate" then return false, "not a nameplate unit" end
    if not TL_UnitExists(casterUnit) then return false, "nameplate gone (died / out of range)" end
    if not TL_UnitCanAttack("player", casterUnit) then return false, "caster not attackable" end
    -- Exclude own party members that have nameplates (rare but real)
    if TL_UnitInParty(casterUnit) then return false, "caster is a party member" end
    return true
end

-- File-scope cached APIs
local TL_UnitAffectingCombat = UnitAffectingCombat
local TL_UnitCastingDuration_API = UnitCastingDuration
local TL_UnitChannelDuration_API = UnitChannelDuration
local TL_C_Spell_GetSpellName = C_Spell and C_Spell.GetSpellName
local TL_C_Spell_GetSpellTexture = C_Spell and C_Spell.GetSpellTexture
local TL_C_Spell_IsSpellImportant = C_Spell and C_Spell.IsSpellImportant

-- IMPORTANT — secret-taint workaround (gotcha #0).
--
-- On nameplate units in instance combat, UnitCastingInfo and
-- UnitChannelInfo return SECRET-TAINTED values for the time fields
-- (startMS, endMS). Lua refuses arithmetic on secret values, so any
-- code that does (endMS - startMS) / 1000 raises:
--   "attempt to perform arithmetic on a secret number value"
--
-- The mitigation here mirrors TS3's approach (Driver.lua lines
-- 391-407):
--   * Don't extract time fields from Unit{Casting,Channel}Info — only
--     pull spellId (and castID for casts) via positional discard.
--   * Get spellId from the EVENT payload when possible — it's clean.
--   * Use UnitCastingDuration / UnitChannelDuration for duration.
--     The return value may itself be secret-tainted; treat it as
--     opaque and only feed it to secret-safe sinks at render time.
--   * GetTime() at pickup as a clean local approximation of start.
--   * C_Spell.GetSpellName / GetSpellTexture for clean metadata.

-- Delayed pickup: called 0.2s after START via C_Timer. Verifies the
-- cast is still active and targeting a party member, then records
-- minimal state. Cast-ID matching has been REMOVED (gotcha #0):
-- equality compare on a secret-tainted castID errors. We accept rare
-- flicker on rapid same-spell restart in exchange for not crashing.
local function TargetedList_DelayedPickup(casterUnit, isChannel, eventSpellId)
    -- One local so the whole gate chain below can report why it dropped a cast.
    -- Every reason is a literal; nothing secret is ever formatted here (see the
    -- gotcha #0 note further down — casterUnit and the channel flag are the only
    -- clean values available at this point).
    local trace = DF.DebugActive and DF:DebugActive("TARGETEDLIST")
    local function drop(why)
        if trace then DF:Debug("TARGETEDLIST", "drop %s at pickup: %s", casterUnit, why) end
    end

    local pickupOk, pickupWhy = TargetedList_ShouldPickup()
    if not pickupOk then drop(pickupWhy) return end

    -- Re-checked after the 0.2s delay: a caster can die or leave nameplate range
    -- inside the window. Worth tracing here (unlike at START) because it passed once.
    local relevantOk, relevantWhy = TargetedList_IsRelevantCaster(casterUnit)
    if not relevantOk then drop(relevantWhy .. " (during the 0.2s pickup delay)") return end

    -- Targeting filter: check if the cast targets a party member.
    -- If "Show Untargeted" is on, also accept casts that have no
    -- target at all (ground AoEs, self-buffs, untargeted channels).
    --
    -- This runs BEFORE the combat filter on purpose — see the note there.
    local party = DF.db and DF.db.party
    local showUntargeted = party and party.targetedListShowUntargeted
    local target = casterUnit .. "target"
    local hasTarget = TL_UnitExists(target)
    local targetsPartyMember = false

    if hasTarget then
        -- Has a target — check if it's a party member
        local targetOk, targetWhy = TargetedList_CastTargetIsPartyMember(casterUnit)
        if not targetOk then
            drop(targetWhy)
            return
        end
        targetsPartyMember = true
    elseif not showUntargeted then
        -- No target and untargeted display is off — skip
        drop("cast has no target and Show Untargeted is off")
        return
    end
    -- If hasTarget is false and showUntargeted is true, we fall through
    -- and show the bar with no target name.

    -- Combat filter: suppress ambient casts from idle NPCs standing around.
    --
    -- ⚠ ONLY applies to casts with no party-member target. This used to run before
    -- the targeting filter and gate EVERY cast on the caster's combat flag, which
    -- silently ate the pull-opener: a mob whose opening move is a cast is not
    -- flagged in combat yet, so the one cast you most want to see was dropped —
    -- and targetedListHideOutOfCombat DEFAULTS TO TRUE, so it happened out of the
    -- box. (Measured: 10 such drops in one 19-minute session.)
    --
    -- Ordering it after the target check makes the two cases separable, because
    -- they genuinely look different:
    --   * pull-opener   — out of combat, but aimed AT a party member -> keep
    --   * ambient noise — out of combat, aimed at nothing            -> drop
    -- Casts aimed at another NPC or a non-party unit never reach here at all;
    -- TargetedList_CastTargetIsPartyMember already rejected them above.
    if not targetsPartyMember and party and party.targetedListHideOutOfCombat then
        if not TL_UnitAffectingCombat(casterUnit) then
            drop("untargeted cast from a caster not in combat (Hide Out of Combat is on)")
            return
        end
    end

    -- IMPORTANT — gotcha #0 update: spellId from the event payload is
    -- ALSO secret-tainted on nameplates. We can pass it through
    -- secret-safe sinks (SetText after C_Spell.GetSpellName, SetTexture
    -- after C_Spell.GetSpellTexture, SetShownFromBoolean after
    -- C_Spell.IsSpellImportant) but we cannot truth-test, compare,
    -- string.format, or otherwise inspect it in Lua.
    --
    -- Practical consequences:
    --   * Important-spells filter is DROPPED here. The render pipeline
    --     in commit #5 will implement it via SetShownFromBoolean using
    --     the secret-tainted IsSpellImportant return.
    --   * Spell name / texture are NOT read here. The render pipeline
    --     will fetch them at render time and feed them straight into
    --     SetText / SetTexture sinks.
    --   * The debug log can only print clean values (casterUnit, the
    --     channel flag, the event name). No spell name.
    local spellId = eventSpellId
    if spellId == nil then
        drop("no spellId in the event payload")
        return
    end

    -- Re-detect cast vs channel at pickup time. The 0.2s delay means
    -- a cast may have transitioned to a channel since the START event.
    -- Check casting first, fall back to channel.
    local notInterruptible
    if TL_UnitCastingInfo(casterUnit) ~= nil then
        isChannel = false
        notInterruptible = select(8, TL_UnitCastingInfo(casterUnit))
    elseif TL_UnitChannelInfo(casterUnit) ~= nil then
        isChannel = true
        notInterruptible = select(7, TL_UnitChannelInfo(casterUnit))
    else
        -- Cast vanished during the 0.2s delay (CC, mob death, etc.)
        return
    end

    -- Duration: try both APIs regardless of isChannel flag. A cast that
    -- transitions to a channel may report via either API during the
    -- brief overlap.
    local duration = (TL_UnitCastingDuration_API and TL_UnitCastingDuration_API(casterUnit))
        or (TL_UnitChannelDuration_API and TL_UnitChannelDuration_API(casterUnit))

    activeTargetedListCasts[casterUnit] = {
        spellId         = spellId,           -- secret; only feed to C_Spell.* + sinks
        isChannel       = isChannel,         -- clean
        startTime       = TL_GetTime(),      -- clean local approximation
        duration        = duration,          -- opaque TimerDuration object
        uninterruptible = notInterruptible,  -- secret; SetVertexColorFromBoolean only
        casterUnit      = casterUnit,        -- clean (we generated it)
        -- spellName / spellTexture / targetName / targetClass / targetUnit
        -- intentionally NOT stored. All fetched at render time via the
        -- secret-tainted APIs and piped directly into secret-safe sinks
        -- (SetText, SetTexture, SetTextColor via C_ClassColor).
    }

    -- Safety timer: if the cast stop event never fires (CC, LOS,
    -- mob death, etc.), force-remove the record after a generous
    -- timeout. TS3 uses OnCooldownDone for this but that requires a
    -- Cooldown frame per bar — our simpler approach uses C_Timer.
    -- 15 seconds covers the longest enemy casts in WoW.
    -- Safety timer: force-remove the record if no stop event fires
    -- within 15 seconds. Uses DF._TargetedListRender to trigger a
    -- render pass which handles the cleanup (bar release + slot free)
    -- through the normal expiry path by marking as fading with 0 dur.
    -- Safety timer: periodically check if the unit is still casting.
    -- If not, force-remove the record. This catches cases where the
    -- cast stop event doesn't fire (CC, LOS, mob death, etc.).
    -- Unlike the previous fixed-timeout approach, this reschedules
    -- as long as the unit is still casting — so long channels (20s+)
    -- aren't prematurely removed.
    local SAFETY_CHECK_INTERVAL = 5
    if TL_C_Timer_After then
        local function safetyCheck()
            local rec = activeTargetedListCasts[casterUnit]
            if not rec or rec.fadingStartedAt or rec.isTestCast then
                return  -- already handled or test record
            end
            -- Check if the unit is still actually casting/channeling
            local stillCasting = TL_UnitExists(casterUnit)
                and (TL_UnitCastingInfo(casterUnit) ~= nil
                     or TL_UnitChannelInfo(casterUnit) ~= nil)
            if stillCasting then
                -- Still casting — reschedule another check
                TL_C_Timer_After(SAFETY_CHECK_INTERVAL, safetyCheck)
            else
                -- Not casting anymore — force-remove
                rec.fadingStartedAt = TL_GetTime()
                rec.fadingDuration = 0
                if DF._TargetedListRender then
                    DF._TargetedListRender()
                end
            end
        end
        TL_C_Timer_After(SAFETY_CHECK_INTERVAL, safetyCheck)
    end

    -- Debug log: only clean values. spellId / spellName / texture are
    -- all secret-tainted and can't be formatted.
    if DF.Debug then
        DF:Debug("TARGETEDLIST", "+cast %s%s",
            casterUnit,
            isChannel and " [channel]" or "")
    end
end

-- Called for UNIT_SPELLCAST_START / CHANNEL_START / EMPOWER_START.
-- Schedules the 0.2s delayed pickup — cast data isn't available yet
-- when the START event fires (gotcha #1).
--
-- Note: NAME_PLATE_UNIT_ADDED and UNIT_TARGET re-pickup paths are
-- intentionally NOT routed here. They don't carry spellId in their
-- event payloads, so we'd have to read it from the API — but the
-- secret-taint workaround (gotcha #0) makes that path fragile. The
-- visible cost is missing a bar when a nameplate enters range while
-- the mob is mid-cast (gap bounded by the cast remaining duration).
local function TargetedList_ProcessCastStart(casterUnit, event, ...)
    -- Structural check FIRST, and MOSTLY silent: it fires for every cast event in the
    -- game — the player's, party members' — and tracing all of that would bury the
    -- useful lines.
    --
    -- The one case worth surfacing is an ENEMY casting under a token that is not a
    -- nameplate ("target", "focus", "boss1", "arena2"...). Blizzard registers nameplate
    -- castbars per-unit (Blizzard_UnitFrame/UnitFrame.lua:97 RegisterUnitEvent with the
    -- nameplate token), so nameplateN should receive these events — but this feature is
    -- nameplate-ONLY, so if events ever arrive under a different token for the same mob
    -- the cast is dropped here with no other symptom. Low volume (enemies only, once
    -- per cast) and it directly answers "I watched it cast and got nothing".
    local relevant, relevantWhy = TargetedList_IsRelevantCaster(casterUnit)
    if not relevant then
        if relevantWhy == "not a nameplate unit"
           and type(casterUnit) == "string"
           and TL_UnitExists(casterUnit)
           and TL_UnitCanAttack("player", casterUnit)
           and DF.DebugActive and DF:DebugActive("TARGETEDLIST") then
            DF:Debug("TARGETEDLIST", "ignored %s: enemy cast arrived on a non-nameplate token", casterUnit)
        end
        return
    end

    local pickupOk, pickupWhy = TargetedList_ShouldPickup()
    if not pickupOk then
        if DF.DebugActive and DF:DebugActive("TARGETEDLIST") then
            DF:Debug("TARGETEDLIST", "skip %s at START: %s", casterUnit, pickupWhy)
        end
        return
    end
    if not TL_C_Timer_After then return end

    local isChannel
    if event == "UNIT_SPELLCAST_CHANNEL_START" then
        isChannel = true
    else  -- UNIT_SPELLCAST_START / UNIT_SPELLCAST_EMPOWER_START
        isChannel = false
    end

    -- Cast-to-channel transition: if CHANNEL_START fires and we already
    -- have a cast record for this unit, update the record immediately
    -- instead of waiting 0.2s. The channel duration is available now.
    -- We must re-apply bar content directly because the render loop
    -- only calls ApplyBarContent for newly assigned bars, not existing ones.
    -- Uses DF._TargetedListTransitionToChannel (defined later, after
    -- casterToBar and ApplyBarContent are in scope).
    if isChannel then
        local existing = activeTargetedListCasts[casterUnit]
        if existing and not existing.fadingStartedAt and not existing.isChannel then
            local channelDuration = TL_UnitChannelDuration_API
                and TL_UnitChannelDuration_API(casterUnit)
            if channelDuration then
                existing.duration = channelDuration
                existing.isChannel = true
                existing.uninterruptible = select(7, TL_UnitChannelInfo(casterUnit))
                if DF._TargetedListTransitionToChannel then
                    DF._TargetedListTransitionToChannel(casterUnit, existing)
                end
                return
            end
        end
    end

    -- Event payload (after `unit` consumed by OnEvent): (castGuid, spellId).
    -- We only need spellId — castGuid was used for cast-ID matching, which
    -- we've removed because secret-string equality compare errors.
    local _, eventSpellId = ...

    TL_C_Timer_After(TARGETEDLIST_PICKUP_DELAY, function()
        TargetedList_DelayedPickup(casterUnit, isChannel, eventSpellId)
    end)
end

-- Pick up a cast that was ALREADY IN PROGRESS when its nameplate appeared.
--
-- Why this exists: everything above is driven by UNIT_SPELLCAST_*_START, so the
-- nameplate has to already exist at the moment the cast begins. Walk into range, turn
-- the camera, or have a mob stream into a pull mid-cast and the bar never appears for
-- that cast at all — it only shows up on the mob's NEXT cast. The Personal Targeted
-- branch has always handled this (OnEvent's NAME_PLATE_UNIT_ADDED case); the Targeted
-- List never did. Confirmed in game 2026-07-30.
--
-- There is no event payload here, so spellId comes from the unit APIs by positional
-- discard. Positions verified against Blizzard_APIDocumentationGenerated/
-- UnitDocumentation.lua, not memory:
--   UnitCastingInfo  -> name, displayName, textureID, startTimeMs, endTimeMs,
--                       isTradeskill, castID, notInterruptible, castingSpellID  (9th)
--   UnitChannelInfo  -> name, displayName, textureID, startTimeMs, endTimeMs,
--                       isTradeskill, notInterruptible, spellID                 (8th)
-- Deliberately NOT touching startTimeMs / endTimeMs — those are the secret-tainted
-- fields that gotcha #0 is about. Duration comes from Unit*Duration inside
-- DelayedPickup as usual.
--
-- No 0.2s delay: that delay exists because target/duration data is not populated at
-- the instant START fires. A cast already in flight has long since settled, so we go
-- straight to the shared pickup, which re-derives cast-vs-channel and re-runs every
-- gate itself.
local function TargetedList_PickupInProgressCast(casterUnit)
    -- Cheap structural gate first; the shared pickup re-checks everything anyway.
    if not TargetedList_IsRelevantCaster(casterUnit) then return end

    -- Already tracked: a nameplate can be removed and re-added while one cast runs
    -- (range flicker, LOS). Re-picking up would reset startTime and visibly restart
    -- the bar mid-cast, so leave a live record alone.
    local existing = activeTargetedListCasts[casterUnit]
    if existing and not existing.fadingStartedAt then return end

    local spellId, isChannel
    if TL_UnitCastingInfo(casterUnit) ~= nil then
        isChannel = false
        spellId = select(9, TL_UnitCastingInfo(casterUnit))
    elseif TL_UnitChannelInfo(casterUnit) ~= nil then
        isChannel = true
        spellId = select(8, TL_UnitChannelInfo(casterUnit))
    else
        return  -- not casting; nothing to recover
    end
    if spellId == nil then return end

    if DF.DebugActive and DF:DebugActive("TARGETEDLIST") then
        DF:Debug("TARGETEDLIST", "recover %s: nameplate appeared mid-cast (channel=%s)",
            casterUnit, isChannel and "y" or "n")
    end
    TargetedList_DelayedPickup(casterUnit, isChannel, spellId)
end

-- Called for every "cast stopped" shaped event. Handles cast-ID
-- matching, SUCCEEDED-during-channel suppression, mob-death guards,
-- and interrupter lookup.
local function TargetedList_OnCastStop(casterUnit, event, ...)
    if not TargetedList_IsActive() then return end

    local active = activeTargetedListCasts[casterUnit]
    if not active then return end

    -- Gotcha #3: some channel spells (pulse DoTs, ground-effect zones)
    -- emit SUCCEEDED once per tick while still channeling. Also covers
    -- cast-to-channel transitions — the channel data may not be ready
    -- yet at SUCCEEDED time, so we just skip the fade and let
    -- CHANNEL_START handle the transition.
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if TL_UnitChannelInfo(casterUnit) ~= nil then return end
    end

    -- INTERRUPTED fires before STOP. If the record is already fading
    -- as interrupted, don't let STOP overwrite with the short fade.
    if active.wasInterrupted and active.fadingStartedAt then return end

    -- Gotcha #2 (cast-ID matching) has been REMOVED — see gotcha #0 in
    -- the findings doc. Equality compare on a secret-tainted castID
    -- errors. Without the match, rapid same-spell restarts may briefly
    -- show stale state. Acceptable for v1.

    local wasInterrupted = (event == "UNIT_SPELLCAST_INTERRUPTED")
    local active = activeTargetedListCasts[casterUnit]
    if not active then return end

    -- Store interrupter GUID for display. The GUID is secret-tainted
    -- on nameplates but UnitNameFromGUID → SetText is a secret-safe
    -- sink chain — we never inspect the value in Lua. For non-
    -- interrupt events this is harmlessly nil.
    local interrupterGuid = select(3, ...)

    local party = DF.db and DF.db.party
    local fadeDuration
    if wasInterrupted then
        fadeDuration = (party and party.targetedListInterruptedFlashDuration) or 1.0
    else
        fadeDuration = (party and party.targetedListFadeOutDuration) or 0.25
    end

    if fadeDuration and fadeDuration > 0 then
        active.fadingStartedAt = TL_GetTime()
        active.fadingDuration  = fadeDuration
        active.wasInterrupted  = wasInterrupted
        active.interrupterGuid = wasInterrupted and interrupterGuid or nil
        if TargetedList_StartFadeTicker then
            TargetedList_StartFadeTicker()
        end
    else
        activeTargetedListCasts[casterUnit] = nil
    end

    if DF.Debug then
        DF:Debug("TARGETEDLIST", "-cast %s: %s%s",
            casterUnit, event,
            wasInterrupted and " [interrupted]" or "")
    end
end

-- Gotcha #9: mob interruptibility toggles mid-cast. The clean boolean
-- from the event replaces the (possibly secret-tainted) value from
-- UnitCastingInfo so future bar redraws can branch on it cleanly.
local function TargetedList_OnInterruptibilityChange(casterUnit, isInterruptible)
    if not TargetedList_IsActive() then return end
    local active = activeTargetedListCasts[casterUnit]
    if not active then return end
    -- The stored field is "uninterruptible" (matches the WoW API name).
    -- Clean booleans are always safe to feed into SetVertexColorFromBoolean.
    active.uninterruptible = not isInterruptible
    if DF.Debug then
        DF:Debug("TARGETEDLIST", "~cast %s: interruptible=%s",
            casterUnit, tostring(isInterruptible))
    end
    -- Commit #5: apply to the bar via SetVertexColorFromBoolean.
end

-- Mid-cast update handler: UNIT_SPELLCAST_DELAYED, CHANNEL_UPDATE,
-- EMPOWER_UPDATE. The cast duration may have changed (pushback,
-- channel extension, empower stage). Re-read the duration object and
-- re-apply content so the bar fill stays in sync.
local function TargetedList_OnCastUpdate(casterUnit, event, ...)
    if not TargetedList_IsActive() then return end
    local rec = activeTargetedListCasts[casterUnit]
    if not rec or rec.fadingStartedAt then return end

    -- Re-read the duration object (may have changed).
    local isChannel = rec.isChannel
    local newDuration
    if isChannel then
        newDuration = TL_UnitChannelDuration and TL_UnitChannelDuration(casterUnit)
    else
        newDuration = TL_UnitCastingDuration and TL_UnitCastingDuration(casterUnit)
    end
    if newDuration then
        rec.duration = newDuration
    end

    -- Re-read notInterruptible (may have changed with pushback).
    if isChannel then
        rec.uninterruptible = select(7, TL_UnitChannelInfo(casterUnit))
    else
        rec.uninterruptible = select(8, TL_UnitCastingInfo(casterUnit))
    end

    -- Re-apply content to the existing bar to update fill + countdown.
    local bar = casterToBar and casterToBar[casterUnit]
    if bar then
        TargetedList_ApplyBarContent(bar, rec)
    end
end

-- Mid-cast target change handler: the enemy swapped target while
-- casting. If we're already tracking this caster, verify the new
-- target is still a party member. If not, drop the bar. We can't
-- pick up NEW casts from UNIT_TARGET (no spellId in the payload)
-- but we CAN drop existing bars that are no longer relevant.
local function TargetedList_OnTargetChange(casterUnit)
    if not TargetedList_IsActive() then return end
    local rec = activeTargetedListCasts[casterUnit]
    if not rec or rec.fadingStartedAt or rec.isTestCast then return end

    -- Check if the caster's new target is still a party member
    -- (or no target at all, which we might want to keep if
    -- showUntargeted is on).
    local target = casterUnit .. "target"
    local hasTarget = TL_UnitExists(target)
    local party = DF.db and DF.db.party

    if hasTarget then
        if not TargetedList_CastTargetIsPartyMember(casterUnit) then
            -- New target isn't a party member — drop the bar
            activeTargetedListCasts[casterUnit] = nil
        end
        -- Always re-render when the caster retargets (bar kept or dropped)
        -- so the self-target overlay reflects the new target immediately.
        if DF._TargetedListRender then DF._TargetedListRender() end
    elseif not (party and party.targetedListShowUntargeted) then
        -- No target and untargeted display is off — drop
        activeTargetedListCasts[casterUnit] = nil
        if DF._TargetedListRender then DF._TargetedListRender() end
    end
end

-- Stale-bar validation: iterate all tracked bars and verify each
-- one is still valid (nameplate exists, unit is casting/channeling).
-- Remove any that are stale. Called on zone transitions and loading
-- screen exit to catch bars that weren't cleaned up by normal events
-- (e.g. missed NAME_PLATE_UNIT_REMOVED during heavy nameplate
-- recycling, or zone changes that don't fire proper stop events).
local function TargetedList_ValidateTrackedBars()
    if not TargetedList_IsGateOpen() then return end
    local anyRemoved = false
    for unit, rec in pairs(activeTargetedListCasts) do
        if not rec.isTestCast and not rec.fadingStartedAt then
            -- Check: does the nameplate still exist?
            if not TL_UnitExists(unit) then
                activeTargetedListCasts[unit] = nil
                anyRemoved = true
            -- Check: is the unit still casting/channeling?
            elseif TL_UnitCastingInfo(unit) == nil
               and TL_UnitChannelInfo(unit) == nil then
                activeTargetedListCasts[unit] = nil
                anyRemoved = true
            end
        end
    end
    if anyRemoved and DF._TargetedListRender then
        DF._TargetedListRender()
    end
end

-- Gotcha #11: nameplate removal events don't reliably fire on zone
-- transitions. Also used on feature disable and on explicit cleanup.
local function TargetedList_ReleaseAllBars()
    if not TargetedList_IsGateOpen() then return end
    wipe(activeTargetedListCasts)
    -- Commit #5: release every pooled bar back to the framepool.
    if DF.Debug then
        DF:Debug("TARGETEDLIST", "release all bars")
    end
end

-- Expose internal hooks for the shared OnEvent dispatcher above.
DF._TargetedListProcessCastStart = TargetedList_ProcessCastStart
DF._TargetedListPickupInProgressCast = TargetedList_PickupInProgressCast
DF._TargetedListOnCastStop = TargetedList_OnCastStop
DF._TargetedListOnCastUpdate = TargetedList_OnCastUpdate
DF._TargetedListOnInterruptibilityChange = TargetedList_OnInterruptibilityChange
DF._TargetedListOnTargetChange = TargetedList_OnTargetChange
DF._TargetedListValidateAll = TargetedList_ValidateTrackedBars
DF._TargetedListReleaseAllBars = TargetedList_ReleaseAllBars

-- ------------------------------------------------------------
-- Public entry points
-- ------------------------------------------------------------

-- ------------------------------------------------------------
-- Render pipeline
-- ------------------------------------------------------------
-- All user-facing rendering flows through secret-safe sinks so that
-- values from UnitCastingInfo / UnitSpellTargetName / etc. — which
-- are secret-tainted on nameplates — can be displayed without ever
-- being inspected in Lua.
--
-- Safe sinks used below:
--   FontString:SetText(secretString)
--   Texture:SetTexture(secretTextureId)
--   StatusBar:SetTimerDuration(secretDurationObj, interp, direction)
--   Texture:SetVertexColorFromBoolean(secretBool, cA, cB)
--   Frame:SetShownFromBoolean(secretBool, true, false)
--   Frame:SetAlphaFromBoolean(secretBool, aOn, aOff)
--   C_ClassColor.GetClassColor(secretClassString) -> secret-safe color
--
-- Unsafe operations (never applied to secret values):
--   arithmetic, concatenation, equality compare with non-nil, truth
--   tests, table keys, string.format, tostring, print.

local TL_C_ClassColor = C_ClassColor

-- Lazy-created render state. All nil until the feature is first
-- enabled. On stable releases these stay nil forever (gate blocks).
-- (The bar pool itself is declared later, next to its helpers.)
local activeBars = {}  -- ordered list of currently-displayed bars

-- Per-caster bar map: casterToBar[casterUnit] = bar frame.
-- This is the incremental tracking table — bars persist until their
-- cast record is removed, avoiding the teardown-all/rebuild-all
-- pattern that caused performance issues.
local casterToBar = {}

-- Slot tracking for STATIC sort order. Each record gets a fixed slot
-- index at acquisition time. The slot persists until the record is
-- removed. When a record is removed its slot becomes available for
-- the next new record.
local casterToSlot = {}   -- [casterUnit] = slotIndex
local nextFreeSlot = 1    -- next slot to assign

-- Active test mode — when true, the container is populated from
-- synthetic data instead of live casts.
local targetedListTestActive = false

-- Layout version stamp, used for the Dispel-style skip-rebuild guard.
-- Incremented whenever a layout-affecting setting changes.
local targetedListLayoutVersion = 0

-- ------------------------------------------------------------
-- Container + bar creation
-- ------------------------------------------------------------

-- Compute the maximum container footprint: barWidth x
-- (barHeight*maxBars + spacing*(maxBars-1))
local function TargetedList_ComputeContainerSize(db)
    local w = db.targetedListWidth or 240
    local h = db.targetedListHeight or 22
    local spacing = db.targetedListSpacing or 2
    local max = db.targetedListMaxBars or 6
    if max < 1 then max = 1 end
    local height = (h * max) + (spacing * (max - 1))
    return w, height
end

local function TargetedList_EnsureContainer()
    if targetedListContainer then return targetedListContainer end
    local c = CreateFrame("Frame", "DandersFramesTargetedListContainer", UIParent)
    c:SetFrameStrata("MEDIUM")
    c:Hide()
    targetedListContainer = c
    return c
end

-- Build a single bar frame from scratch. Called by the pool's
-- acquire path on a cold fetch.
--
-- IMPORTANT: bars are plain Frames, NOT Buttons with
-- SecureActionButtonTemplate. A previous version used the secure
-- template so click-to-target could set a "unit" attribute, but the
-- container then became "parent of a secure child" and :Hide() on
-- it was protected during combat — triggering ADDON_ACTION_BLOCKED
-- every time the last active cast stopped mid-pull. Click-to-target
-- is deferred until we have a combat-safe mechanism for it.
--
-- Structure:
--   Frame
--     Background texture
--     Border
--     Icon texture (left-aligned by default)
--     StatusBar (progress fill)
--       Spell name FontString
--       Target name FontString
local function TargetedList_BuildBar(parent)
    local bar = CreateFrame("Frame", nil, parent)
    bar:Hide()
    bar:SetFrameStrata("MEDIUM")

    -- Background (solid color behind everything). Color + alpha
    -- applied by TargetedList_ApplyBarAppearance on every render.
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(bar)
    bg:SetColorTexture(0, 0, 0, 0.6)
    bar.bg = bg

    -- Border via the unified DF.Border backend (Stage 4.5).
    -- TargetedList_ApplyBarAppearance drives BuildSpec + Apply per render.
    bar.border = DF.Border:New(bar)

    -- Icon — anchored dynamically by ApplyBarAppearance so its
    -- position (LEFT/RIGHT) and zoom state can change at runtime.
    local icon = bar:CreateTexture(nil, "ARTWORK")
    bar.icon = icon

    -- Progress StatusBar. Anchors are set by ApplyBarAppearance to
    -- leave room for the icon depending on its position.
    local progress = CreateFrame("StatusBar", nil, bar)
    progress:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    progress:SetMinMaxValues(0, 1)
    progress:SetValue(0)
    bar.progress = progress

    -- Self-target color overlay. Parented to bar (plain Frame) rather
    -- than progress (StatusBar) to avoid StatusBar child rendering quirks
    -- in Midnight 12.0. Anchored to progress so it tracks its bounds.
    -- Starts at alpha 0 (invisible); SetAlphaFromBoolean controls
    -- visibility so we avoid the Show/Hide + secret-taint interaction.
    local selfFrame = CreateFrame("Frame", nil, bar)
    selfFrame:SetAllPoints(progress)
    selfFrame:SetFrameLevel(bar:GetFrameLevel() + 3)
    selfFrame:SetAlpha(0)
    local selfTex = selfFrame:CreateTexture(nil, "OVERLAY")
    selfTex:SetAllPoints()
    bar.selfTargetFrame = selfFrame
    bar.selfTargetTex = selfTex

    -- Text container frame above the self-target overlay so text is
    -- never obscured by it. Also parented to bar and anchored to progress.
    local textFrame = CreateFrame("Frame", nil, bar)
    textFrame:SetAllPoints(progress)
    textFrame:SetFrameLevel(selfFrame:GetFrameLevel() + 1)

    -- Text overlays on the progress bar. Anchor / offset / font are
    -- applied by ApplyBarAppearance and ApplyTextLayout per render.
    local spellName = textFrame:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    spellName:SetJustifyV("MIDDLE")
    spellName:SetWordWrap(false)
    bar.spellName = spellName

    local targetName = textFrame:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    targetName:SetJustifyV("MIDDLE")
    targetName:SetWordWrap(false)
    bar.targetName = targetName

    -- Duration countdown text. We use a custom FontString updated via
    -- OnUpdate instead of Blizzard's native Cooldown countdown, so that
    -- custom fonts can be applied. The remaining time is read from the
    -- duration object stored on the bar via GetRemainingDuration().
    local durationText = textFrame:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    durationText:SetJustifyV("MIDDLE")
    durationText:SetWordWrap(false)
    bar.duration = durationText

    -- OnUpdate: refresh duration countdown text every ~100ms.
    -- Read duration from the StatusBar via GetTimerDuration() each tick,
    -- call GetRemainingDuration(), feed
    -- directly to SetFormattedText (a secret-safe sink). Use explicit
    -- == nil checks (not truthiness) to avoid secret-taint errors.
    bar._durationElapsed = 0
    bar:SetScript("OnUpdate", function(self, elapsed)
        self._durationElapsed = self._durationElapsed + elapsed
        if self._durationElapsed < 0.1 then return end
        self._durationElapsed = self._durationElapsed - 0.1
        if not self.duration:IsShown() then return end
        if self._testDuration then
            -- Test bar: compute from startTime + totalDuration (clean values)
            local td = self._testDuration
            local remaining = td.totalDuration - (TL_GetTime() - td.startTime)
            if remaining > 0 then
                self.duration:SetFormattedText("%.1f", remaining)
            else
                self.duration:SetText("")
            end
        else
            -- Live bar: read duration fresh from the StatusBar each tick
            local durationObj = self.progress:GetTimerDuration()
            if durationObj == nil then return end
            self.duration:SetFormattedText("%.1f", durationObj:GetRemainingDuration())
        end
    end)

    -- Interrupter name FontString — shown during interrupted-flash
    -- fade with the name of who kicked the cast. Overlays spell name
    -- and target name (which are hidden during the flash).
    local interruptText = textFrame:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    interruptText:SetPoint("CENTER", progress, "CENTER", 0, 0)
    interruptText:SetJustifyH("CENTER")
    interruptText:SetJustifyV("MIDDLE")
    interruptText:SetWordWrap(false)
    interruptText:Hide()
    bar.interruptText = interruptText

    -- Highlight frame for important-spell glow. Reuses the existing
    -- InitGlowBorder / UpdateGlowBorder infrastructure from the
    -- personal targeted spells icon system. Shown only for important
    -- spells via SetAlphaFromBoolean (secret-safe).
    local highlight = CreateFrame("Frame", nil, bar)
    highlight:SetAllPoints(bar)
    highlight:SetFrameLevel(bar:GetFrameLevel() + 5)
    highlight:Hide()
    bar.highlightFrame = highlight

    return bar
end

-- Helper: resolve an anchor-name string to a WoW SetPoint argument.
local function TargetedList_ResolveAnchorPoint(anchorName)
    if anchorName == "CENTER" then return "CENTER" end
    if anchorName == "RIGHT" then return "RIGHT" end
    return "LEFT"
end

-- Apply anchor/offset/alignment settings to a bar's text elements.
-- Anchor controls WHERE the element is placed on the bar. Alignment
-- controls how text WITHIN the element is justified — independently
-- of anchor, so users can e.g. anchor target name to RIGHT but
-- left-justify the text within it.
local function TargetedList_ApplyTextLayout(bar, db)
    if not bar or not db then return end

    -- Default text element width derived from the bar width setting.
    -- We don't call bar.progress:GetWidth() because it returns a
    -- secret-tainted number on nameplate-parented bars, and the
    -- comparison (< 10) would error. The db value is always clean.
    local barW = db.targetedListWidth or 240
    local barH = db.targetedListHeight or 22
    local showIcon = db.targetedListShowIcon ~= false
    local progressW = showIcon and (barW - barH) or (barW - 2)

    local function applyTextElement(fs, anchorKey, alignKey, widthKey, xKey, yKey, defaultAnchor, defaultAlign)
        if not fs then return end
        local point = TargetedList_ResolveAnchorPoint(db[anchorKey] or defaultAnchor)
        local align = db[alignKey] or defaultAlign or point
        local w = (widthKey and db[widthKey] or 0) or 0
        if w <= 0 then w = progressW end
        fs:ClearAllPoints()
        fs:SetPoint(point, bar.progress, point,
            db[xKey] or 0, db[yKey] or 0)
        fs:SetWidth(w)
        fs:SetJustifyH(align)
    end

    applyTextElement(bar.spellName,
        "targetedListSpellNameAnchor", "targetedListSpellNameAlign",
        "targetedListSpellNameWidth",
        "targetedListSpellNameX", "targetedListSpellNameY", "LEFT", "LEFT")
    applyTextElement(bar.targetName,
        "targetedListTargetNameAnchor", "targetedListTargetNameAlign",
        "targetedListTargetNameWidth",
        "targetedListTargetNameX", "targetedListTargetNameY", "RIGHT", "RIGHT")

    -- Interrupt text — normally hidden, shown during interrupted flash
    applyTextElement(bar.interruptText,
        "targetedListInterruptTextAnchor", "targetedListInterruptTextAlign",
        "targetedListInterruptTextWidth",
        "targetedListInterruptTextX", "targetedListInterruptTextY", "CENTER", "CENTER")

    -- Duration: now a FontString like the others, positioned via applyTextElement.
    applyTextElement(bar.duration,
        "targetedListDurationAnchor", "targetedListDurationAlign",
        nil,  -- no width key; duration text is short
        "targetedListDurationX", "targetedListDurationY", "RIGHT", "RIGHT")
end

-- Apply static appearance settings to a bar. "Static" here means the
-- configuration doesn't depend on the active cast — it's settings
-- that come straight from db: icon position/zoom/show, border color
-- and visibility, background alpha, statusbar texture, font, show/
-- hide toggles for all text elements.
--
-- Called per bar during render (both real and test paths), and again
-- from UpdateTargetedListLayout when settings change. The function
-- runs at drag-tick rate during slider interaction so keep it cheap.
-- Everything this function writes derives from `db` alone -- never from the spell, the
-- bar's state or the clock -- so it is pure config and does not belong on the render
-- path. TargetedList_LayoutBars called it for every active bar on EVERY render, which
-- made it 86% of all Border:Apply allocation in a combat trace (BuildSpec + Apply +
-- three or four SafeSetFont calls, per bar, per tick).
--
-- Gated on targetedListLayoutVersion, which already existed at the top of this file and
-- was incremented by DF:UpdateTargetedListLayout but never read by anything. That hook
-- is the single funnel for every settings change: the Options pages call it, preset
-- application calls it, and a profile switch reaches it via Position.lua. So a bumped
-- version is exactly "the config changed", which is exactly when this work is needed.
--
-- ☠ TargetedList_ResetBar clears the stamp on release, next to the _lastTexturePath it
-- already cleared for the same reason. Without that, a recycled bar would skip this
-- function entirely and lose the SetStatusBarTexture that clearing _lastTexturePath
-- exists to force.
local function TargetedList_ApplyBarAppearance(bar, db)
    if not bar or not db then return end
    if bar._appearanceVersion == targetedListLayoutVersion then return end
    bar._appearanceVersion = targetedListLayoutVersion
    local barH = db.targetedListHeight or 22
    local showIcon = db.targetedListShowIcon ~= false
    local iconPos = db.targetedListIconPosition or "LEFT"

    -- ----- Icon: show/hide, position, zoom -----
    bar.icon:ClearAllPoints()
    if showIcon then
        bar.icon:Show()
        bar.icon:SetHeight(barH - 2)
        bar.icon:SetWidth(barH - 2)
        if iconPos == "RIGHT" then
            bar.icon:SetPoint("TOPRIGHT", bar, "TOPRIGHT", -1, -1)
            bar.icon:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -1, 1)
        else
            bar.icon:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
            bar.icon:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 1, 1)
        end
        if db.targetedListZoomIcon ~= false then
            bar.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        else
            bar.icon:SetTexCoord(0, 1, 0, 1)
        end
    else
        bar.icon:Hide()
    end

    -- ----- Progress StatusBar: anchors leave room for the icon -----
    bar.progress:ClearAllPoints()
    if showIcon and iconPos == "RIGHT" then
        bar.progress:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
        bar.progress:SetPoint("BOTTOMRIGHT", bar.icon, "BOTTOMLEFT", -1, 0)
    elseif showIcon then
        bar.progress:SetPoint("TOPLEFT", bar.icon, "TOPRIGHT", 1, 0)
        bar.progress:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -1, 1)
    else
        bar.progress:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
        bar.progress:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -1, 1)
    end

    -- ----- StatusBar texture -----
    -- Only call SetStatusBarTexture if the path changed — calling it
    -- unconditionally resets the StatusBar's internal value/fill state,
    -- which clobbers the progress fill set by ApplyBarContent.
    local texturePath = db.targetedListTexture or "Interface\\TargetingFrame\\UI-StatusBar"
    if bar._lastTexturePath ~= texturePath then
        DF:SafeSetStatusBarTexture(bar.progress, texturePath)
        bar._lastTexturePath = texturePath
    end

    -- ----- Background alpha -----
    local bgAlpha = db.targetedListBackgroundAlpha or 0.6
    bar.bg:SetColorTexture(0, 0, 0, bgAlpha)

    -- Border via unified DF.Border backend (Stage 4.5). BuildSpec reads
    -- canonical targetedList* keys; consumer doesn't override anything
    -- (no pixel-perfect on Targeted List bars — bars are positioned by
    -- screen-anchored container, not by the frame-pixel grid).
    if bar.border then
        DF.Border:Apply(bar.border, DF.Border:BuildSpec(db, "targetedList"))
    end

    -- ----- Font (all text elements share one font + outline setting) -----
    local fontName = db.targetedListFont or "Friz Quadrata TT"
    local fontSize = db.targetedListFontSize or 12
    local outline = db.targetedListFontOutline or ""

    -- Per-element font sizes fall back to the global targetedListFontSize.
    -- 0 means "use global" (the default for per-element overrides).
    local spellNameFontSize = db.targetedListSpellNameFontSize
    if not spellNameFontSize or spellNameFontSize == 0 then spellNameFontSize = fontSize end
    local targetNameFontSize = db.targetedListTargetNameFontSize
    if not targetNameFontSize or targetNameFontSize == 0 then targetNameFontSize = fontSize end

    DF:SafeSetFont(bar.spellName, fontName, spellNameFontSize, outline)
    DF:SafeSetFont(bar.targetName, fontName, targetNameFontSize, outline)
    if bar.interruptText then
        local intFontSize = db.targetedListInterruptTextFontSize
        if not intFontSize or intFontSize == 0 then intFontSize = fontSize end
        DF:SafeSetFont(bar.interruptText, fontName, intFontSize, outline)
    end
    if bar.duration then
        local durFontSize = db.targetedListDurationFontSize
        if not durFontSize or durFontSize == 0 then durFontSize = fontSize end
        DF:SafeSetFont(bar.duration, fontName, durFontSize, outline)
    end

    -- ----- Per-element show/hide toggles -----
    -- NOTE: spell name and target name visibility is handled in
    -- ApplyBarContent because it depends on the fading/interrupt
    -- state (hidden during interrupted flash to make room for the
    -- interrupter name). Only duration is toggled here.
    bar.duration:SetShown(db.targetedListShowDuration ~= false)
end

-- Release callback for the pool.
local function TargetedList_ResetBar(pool, bar)
    bar:Hide()
    bar:SetAlpha(1)
    bar:ClearAllPoints()
    bar.casterUnit = nil
    bar.spellId = nil
    bar.isChannel = nil
    bar.testAnim = nil
    bar.progress:SetValue(0)
    bar.progress:SetStatusBarColor(1, 0.2, 0.2, 1)
    bar.spellName:SetText("")
    bar.targetName:SetText("")
    if bar.duration then
        bar.duration:SetText("")
    end
    bar._testDuration = nil
    bar.icon:SetTexture(nil)
    bar._lastTexturePath = nil
    -- Same reason as _lastTexturePath above: drop the cached appearance stamp so a
    -- recycled bar re-runs TargetedList_ApplyBarAppearance on acquire. Without this the
    -- version gate would skip it and the bar would never get its status-bar texture back.
    bar._appearanceVersion = nil
    if bar.highlightFrame then
        bar.highlightFrame:Hide()
    end
    if bar.selfTargetFrame then
        bar.selfTargetFrame:SetAlpha(0)
    end
    if bar.interruptText then
        bar.interruptText:SetText("")
        bar.interruptText:Hide()
    end
end

-- Manual pool — CreateFramePool requires an XML template, which we
-- don't have (bars are built programmatically). Simple array of
-- available bars + array of currently-used bars. Acquire pops from
-- available (or builds a new one); Release wipes and pushes back.
local targetedListBarPoolAvailable = {}

local function TargetedList_AcquireBar()
    local parent = TargetedList_EnsureContainer()
    local bar = table.remove(targetedListBarPoolAvailable)
    if not bar then
        bar = TargetedList_BuildBar(parent)
    end
    -- Apply appearance immediately so bars never show with template fonts
    local db = DF.db and DF.db.party
    if db then TargetedList_ApplyBarAppearance(bar, db) end
    return bar
end

local function TargetedList_ReleaseBar(bar)
    TargetedList_ResetBar(nil, bar)
    table.insert(targetedListBarPoolAvailable, bar)
end

-- Legacy shim so existing call sites using targetedListBarPool still
-- function. The pool object exposes Acquire() and Release(bar).
local targetedListBarPool = {
    Acquire = function(self) return TargetedList_AcquireBar() end,
    Release = function(self, bar) return TargetedList_ReleaseBar(bar) end,
}

-- ☠ The ONLY way a Targeted List bar may be made visible.
--
-- "Important Spells Only" is driven by a SECRET boolean: C_Spell.IsSpellImportant on a
-- secret spellId returns a secret, which Lua may never read, so the verdict can only be
-- piped into SetShownFromBoolean and consumed inside the engine. That means a plain
-- bar:Show() elsewhere silently OVERRIDES the filter -- and three of them did (the
-- layout pass and both sort branches), which is why the filter has never worked for
-- anyone who enabled it.
--
-- Every show must therefore re-assert the secret verdict rather than force-showing.
-- With the filter off this is just bar:Show().
local function TargetedList_ShowBar(bar, db)
    if not bar then return end
    if db and db.targetedListImportantOnly
       and TL_C_Spell_IsSpellImportant
       and bar.SetShownFromBoolean
       and bar.spellId ~= nil then
        bar:SetShownFromBoolean(TL_C_Spell_IsSpellImportant(bar.spellId), true, false)
    else
        bar:Show()
    end
end

local function TargetedList_EnsureBarPool()
    TargetedList_EnsureContainer()
    return targetedListBarPool
end

-- ------------------------------------------------------------
-- Self-target overlay refresh
-- ------------------------------------------------------------
-- Extracted into a standalone helper so it can be re-evaluated on
-- every render pass (not just at initial bar assignment). This is
-- important because a caster can change targets mid-cast, which
-- would otherwise leave the overlay stale until the bar is released.
-- Called from both ApplyBarContent (initial assignment) and from the
-- render loop (refresh for all active bars).
local function TargetedList_ApplySelfTargetOverlay(bar, rec, party)
    if not bar.selfTargetFrame then return end
    -- Only called for non-fading bars. Fading bars are excluded by the
    -- Step 3.5 loop guard and fade the overlay via bar:SetAlpha naturally.
    if party and party.targetedListSelfTargetColorEnabled then
        local sc = party.targetedListSelfTargetColor or {r = 1, g = 0.85, b = 0.1, a = 0.4}
        bar.selfTargetTex:SetColorTexture(sc.r, sc.g, sc.b, sc.a or 0.4)
        if rec.isTestCast then
            bar.selfTargetFrame:SetAlpha(rec.testIsTargetingPlayer and 1 or 0)
        elseif bar.selfTargetFrame.SetAlphaFromBoolean then
            -- Live bars: UnitIsUnit returns a secret-tainted boolean;
            -- pipe through SetAlphaFromBoolean (secret-safe sink).
            local isTargetingPlayer = UnitIsUnit(rec.casterUnit .. "target", "player")
            bar.selfTargetFrame:SetAlphaFromBoolean(isTargetingPlayer, 1, 0)
        else
            bar.selfTargetFrame:SetAlpha(0)
        end
    else
        bar.selfTargetFrame:SetAlpha(0)
    end
end

-- ------------------------------------------------------------
-- Bar content application (the secret-safe sink boundary)
-- ------------------------------------------------------------
--
-- This is the ONE function that touches secret-tainted values. It
-- reads them fresh from the API and pipes them directly into
-- Blizzard widget sinks. No values are stored, compared, formatted,
-- or inspected in Lua. If you need to add a new rendered field, do
-- it here and make sure every call goes through a sink.

local function TargetedList_ApplyBarContent(bar, activeRec)
    local casterUnit = activeRec.casterUnit
    local spellId = activeRec.spellId
    local isTest = activeRec.isTestCast

    -- Store casterUnit on the bar for lightweight progress lookups
    -- (the test ticker reads this to find the matching record).
    bar.casterUnit = casterUnit
    -- And the spellId, so TargetedList_ShowBar can re-assert the secret
    -- important-only verdict on every later show. The release path already
    -- cleared this field; nothing had ever assigned it.
    bar.spellId = spellId

    -- Spell name: test records store a clean string; live records
    -- pipe the (possibly secret) result through SetText.
    if isTest and activeRec.testSpellName then
        bar.spellName:SetText(activeRec.testSpellName)
    elseif TL_C_Spell_GetSpellName then
        bar.spellName:SetText(TL_C_Spell_GetSpellName(spellId) or "")
    end

    -- Spell texture: same pattern.
    if isTest and activeRec.testSpellTexture then
        bar.icon:SetTexture(activeRec.testSpellTexture)
    elseif TL_C_Spell_GetSpellTexture then
        bar.icon:SetTexture(TL_C_Spell_GetSpellTexture(spellId))
    end

    -- Target name: test records store a clean string; live records
    -- use UnitSpellTargetName (secret-tainted, fed to SetText sink).
    local party = DF.db and DF.db.party
    local arrowPrefix = (party and party.targetedListShowArrowPrefix) and "> " or ""
    local arrowSuffix = (party and party.targetedListShowArrowSuffix) and " <" or ""
    if isTest and activeRec.testTargetName then
        bar.targetName:SetText(arrowPrefix .. activeRec.testTargetName .. arrowSuffix)
    else
        local targetName = TL_UnitSpellTargetName(casterUnit)
        if targetName then
            if arrowPrefix ~= "" or arrowSuffix ~= "" then
                bar.targetName:SetFormattedText("%s%s%s", arrowPrefix, targetName, arrowSuffix)
            else
                bar.targetName:SetText(targetName)
            end
        else
            bar.targetName:SetText("")
        end
    end

    -- Class color: test records store a clean class string; live
    -- records use UnitSpellTargetClass (secret, through Blizzard sink).
    local useClassColor = party and party.targetedListTargetNameClassColor
    if useClassColor and TL_C_ClassColor and TL_C_ClassColor.GetClassColor then
        local targetClass
        if isTest then
            targetClass = activeRec.testTargetClass
        else
            targetClass = TL_UnitSpellTargetClass(casterUnit)
        end
        if targetClass then
            local color = TL_C_ClassColor.GetClassColor(targetClass)
            if color then
                bar.targetName:SetTextColor(color.r, color.g, color.b, 1)
            end
        else
            bar.targetName:SetTextColor(1, 1, 1, 1)
        end
    else
        bar.targetName:SetTextColor(1, 1, 1, 1)
    end

    -- Progress fill + countdown text:
    -- testFrozenFill provides a direct fill value for static test bars.
    -- Fading records skip fill updates (stays where cast stopped).
    if activeRec.testFrozenFill then
        bar.progress:SetMinMaxValues(0, 1)
        bar.progress:SetValue(activeRec.testFrozenFill)
        bar._testDuration = nil
    elseif activeRec.fadingStartedAt then
        -- Don't update progress. The fill stays where it was.
        bar._testDuration = nil
    elseif isTest and activeRec.testCastDuration then
        local cutoff = activeRec.testInterruptAt or activeRec.testCastDuration
        local elapsed = TL_GetTime() - activeRec.startTime
        local pct = math.min(1, math.max(0, elapsed / cutoff))
        bar.progress:SetMinMaxValues(0, 1)
        bar.progress:SetValue(pct)
        -- Store test timing for OnUpdate duration text
        bar._testDuration = { startTime = activeRec.startTime, totalDuration = cutoff }
    elseif activeRec.duration and bar.progress.SetTimerDuration then
        local direction = (activeRec.isChannel)
            and Enum.StatusBarTimerDirection.RemainingTime
            or Enum.StatusBarTimerDirection.ElapsedTime
        bar.progress:SetTimerDuration(activeRec.duration,
            Enum.StatusBarInterpolation.Immediate, direction)
        bar._testDuration = nil
    end

    -- Interruptible color: test records have a clean bool so we can
    -- use plain SetStatusBarColor. Live records have a secret-tainted
    -- bool → SetVertexColorFromBoolean.
    local interruptibleColor = party and party.targetedListInterruptibleColor
        or {r=1, g=0.2, b=0.2, a=1}
    local uninterruptibleColor = party and party.targetedListUninterruptibleColor
        or {r=0.5, g=0.5, b=0.5, a=1}
    if isTest then
        local c = activeRec.uninterruptible and uninterruptibleColor or interruptibleColor
        bar.progress:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
    elseif activeRec.uninterruptible ~= nil and bar.progress.GetStatusBarTexture then
        local tex = bar.progress:GetStatusBarTexture()
        if tex and tex.SetVertexColorFromBoolean then
            tex:SetVertexColorFromBoolean(activeRec.uninterruptible,
                uninterruptibleColor, interruptibleColor)
        else
            bar.progress:SetStatusBarColor(
                interruptibleColor.r, interruptibleColor.g,
                interruptibleColor.b, interruptibleColor.a)
        end
    else
        bar.progress:SetStatusBarColor(
            interruptibleColor.r, interruptibleColor.g,
            interruptibleColor.b, interruptibleColor.a)
    end

    -- Important-spells filter at render time. C_Spell.IsSpellImportant
    -- returns a secret-tainted boolean when given a secret spellId,
    -- so we pipe it through SetShownFromBoolean — the secret-safe
    -- sink that accepts a secret bool and toggles shown state.
    -- When the filter is off we just make sure the bar is shown.
    if party and party.targetedListImportantOnly
       and TL_C_Spell_IsSpellImportant
       and bar.SetShownFromBoolean then
        -- ⚠ THE LOG CANNOT TELL YOU WHETHER THIS BAR ENDED UP VISIBLE. isImportant is
        -- a SECRET value: SetShownFromBoolean consumes it inside the engine and Lua may
        -- never inspect it. So with this filter on, a cast logs a normal "+cast" and
        -- then silently renders invisible if the spell is not flagged important.
        --
        -- That combination — accepted in the log, absent on screen, no drop reason
        -- anywhere — is exactly what made "the Targeted List misses casts" hard to
        -- pin down. Trace the fact that the filter is deciding, since we cannot trace
        -- its verdict.
        if DF.DebugActive and DF:DebugActive("TARGETEDLIST") then
            DF:Debug("TARGETEDLIST", "  ^ important-only filter is ON: visibility set from a secret value we cannot read")
        end
        local isImportant = TL_C_Spell_IsSpellImportant(spellId)
        bar:SetShownFromBoolean(isImportant, true, false)
    else
        if bar.SetShownFromBoolean then
            bar:SetShownFromBoolean(true, true, false)
        end
    end

    -- Important-spell glow: reuses the existing InitGlowBorder /
    -- UpdateGlowBorder infrastructure. For test bars we use a stored
    -- testIsImportant flag (since our test spell IDs aren't actually
    -- flagged as important by Blizzard). For live bars we use
    -- SetAlphaFromBoolean with the secret-tainted IsSpellImportant result.
    if bar.highlightFrame then
        if party and party.targetedListHighlightImportant then
            local hc = party.targetedListHighlightColor or {r=1, g=0.8, b=0}
            bar.highlightBorder = bar.highlightBorder or DF.Border:New(bar.highlightFrame)
            -- Static solid highlight border (no animation): the Targeted List
            -- highlight has only an enable toggle + colour, and historically was
            -- a calm glow — a flashing PROC here reads as broken.
            DF.Border:Apply(bar.highlightBorder, {
                enabled = true, size = 2, inset = 0, style = "SOLID",
                color = { r = hc.r, g = hc.g, b = hc.b, a = hc.a or 1 },
            })
            bar.highlightFrame:Show()
            if isTest and activeRec.testIsImportant ~= nil then
                -- Clean bool — use SetShown directly
                bar.highlightFrame:SetShown(activeRec.testIsImportant)
            elseif TL_C_Spell_IsSpellImportant then
                local isImportant = TL_C_Spell_IsSpellImportant(spellId)
                bar.highlightFrame:SetAlphaFromBoolean(isImportant)
            else
                bar.highlightFrame:Hide()
            end
        else
            bar.highlightFrame:Hide()
        end
    end

    -- Text visibility (normal, non-fading state). Fading bars have
    -- their text managed by Step 3 of the incremental Render.
    if not activeRec.fadingStartedAt then
        if bar.interruptText then bar.interruptText:Hide() end
        bar.spellName:SetShown(party and party.targetedListShowSpellName ~= false)
        bar.targetName:SetShown(party and party.targetedListShowTargetName ~= false)
    end

    -- Hide-own-casts filter (non-fading path only).
    if not activeRec.fadingStartedAt then
        if party and party.targetedListHideOwnCasts
           and bar.SetAlphaFromBoolean then
            local isTargetingPlayer = UnitIsUnit(casterUnit .. "target", "player")
            bar:SetAlphaFromBoolean(isTargetingPlayer, 0, 1)
        else
            bar:SetAlpha(1)
        end
    end

    -- Self-target color overlay — delegate to the shared helper so the
    -- same evaluation logic runs here (initial assignment) and on every
    -- subsequent render pass (to catch mid-cast target changes).
    TargetedList_ApplySelfTargetOverlay(bar, activeRec, party)
end

-- ------------------------------------------------------------
-- Layout
-- ------------------------------------------------------------

-- Applies the container size, bar dimensions, and stack positioning.
-- Called on every render pass (cheap; just a few SetSize/SetPoint calls).
local function TargetedList_LayoutBars()
    if not targetedListContainer then return end
    local db = DF.db and DF.db.party
    if not db then return end

    local cw, ch = TargetedList_ComputeContainerSize(db)
    local x = db.targetedListX or 0
    local y = db.targetedListY or -10
    targetedListContainer:ClearAllPoints()
    targetedListContainer:SetPoint("CENTER", UIParent, "CENTER", x, y)
    targetedListContainer:SetSize(cw, ch)

    local barW = db.targetedListWidth or 240
    local barH = db.targetedListHeight or 22
    local spacing = db.targetedListSpacing or 2
    local growth = db.targetedListGrowth or "DOWN"

    -- Position each active bar by index. For STATIC sort mode,
    -- activeBars may have nil gaps (released slots) — we use a
    -- numeric for loop and skip nils so bars stay at their
    -- assigned position. The slot index IS the position index.
    local maxBarsLocal = db.targetedListMaxBars or 6
    local maxSlot = #activeBars
    -- For STATIC, the highest slot might exceed #activeBars since
    -- Lua's # operator stops at the first nil. Scan for the real max.
    for i = maxBarsLocal, 1, -1 do
        if activeBars[i] then maxSlot = i; break end
    end

    for i = 1, maxSlot do
        local bar = activeBars[i]
        if bar then
            bar:SetSize(barW, barH)
            bar:ClearAllPoints()
            if growth == "UP" then
                bar:SetPoint("BOTTOM", targetedListContainer, "BOTTOM",
                    0, (i - 1) * (barH + spacing))
            else
                bar:SetPoint("TOP", targetedListContainer, "TOP",
                    0, -(i - 1) * (barH + spacing))
            end
            TargetedList_ApplyBarAppearance(bar, db)
            TargetedList_ApplyTextLayout(bar, db)
            TargetedList_ShowBar(bar, db)
        end
    end
end

-- ------------------------------------------------------------
-- Render pass
-- ------------------------------------------------------------
--
-- Walks activeTargetedListCasts, acquires a pooled bar for each,
-- applies content via the secret-safe sink function, and lays out.
-- Called from the cast lifecycle after any change to the active set,
-- from UpdateTargetedListLayout when settings change, and from
-- test mode when rebuilding demo bars.

local function TargetedList_ReleaseAllActiveBars()
    for i = #activeBars, 1, -1 do
        local bar = activeBars[i]
        if bar then targetedListBarPool:Release(bar) end
        activeBars[i] = nil
    end
    wipe(casterToBar)
    wipe(casterToSlot)
    nextFreeSlot = 1
end

-- ------------------------------------------------------------
-- Bar style presets
-- ------------------------------------------------------------
-- Each preset is a bundle of individual settings. Picking a preset
-- from the dropdown writes the entire bundle to db and triggers a
-- layout refresh. Individual settings remain user-editable after
-- the bundle is applied — the preset is a one-shot "start from this
-- configuration" action, not a continuous override.

local TARGETEDLIST_STYLE_PRESETS = {
    DEFAULT = {
        targetedListWidth = 240,
        targetedListHeight = 22,
        targetedListSpacing = 2,
        targetedListShowIcon = true,
        targetedListIconPosition = "LEFT",
        targetedListZoomIcon = true,
        targetedListShowSpellName = true,
        targetedListShowTargetName = true,
        targetedListShowDuration = true,
        targetedListShowBorder = true,
        targetedListBackgroundAlpha = 0.6,
        targetedListFontSize = 12,
    },
    COMPACT = {
        targetedListWidth = 200,
        targetedListHeight = 16,
        targetedListSpacing = 1,
        targetedListShowIcon = true,
        targetedListIconPosition = "LEFT",
        targetedListZoomIcon = true,
        targetedListShowSpellName = true,
        targetedListShowTargetName = true,
        targetedListShowDuration = true,
        targetedListShowBorder = true,
        targetedListBackgroundAlpha = 0.6,
        targetedListFontSize = 10,
    },
    DETAILED = {
        targetedListWidth = 280,
        targetedListHeight = 30,
        targetedListSpacing = 3,
        targetedListShowIcon = true,
        targetedListIconPosition = "LEFT",
        targetedListZoomIcon = true,
        targetedListShowSpellName = true,
        targetedListShowTargetName = true,
        targetedListShowDuration = true,
        targetedListShowBorder = true,
        targetedListBackgroundAlpha = 0.7,
        targetedListFontSize = 14,
    },
    MINIMAL = {
        targetedListWidth = 180,
        targetedListHeight = 14,
        targetedListSpacing = 1,
        targetedListShowIcon = false,
        targetedListIconPosition = "LEFT",
        targetedListZoomIcon = true,
        targetedListShowSpellName = true,
        targetedListShowTargetName = true,
        targetedListShowDuration = false,
        targetedListShowBorder = false,
        targetedListBackgroundAlpha = 0.4,
        targetedListFontSize = 10,
    },
}

function DF:ApplyTargetedListPreset(presetName)
    if not TargetedList_IsGateOpen() then return end
    local preset = TARGETEDLIST_STYLE_PRESETS[presetName]
    if not preset then return end
    local party = DF.db and DF.db.party
    if not party then return end

    for k, v in pairs(preset) do
        party[k] = v
    end
    party.targetedListStylePreset = presetName

    DF:UpdateTargetedListLayout()
end

-- ------------------------------------------------------------
-- Fade-out / interrupted-flash ticker
-- ------------------------------------------------------------
-- When a cast stops, its record is marked with fadingStartedAt +
-- fadingDuration instead of being removed immediately. The ticker
-- below re-renders every ~50ms so the bar's alpha/tint can animate.
-- When a fading record's timer expires, the render pass removes it
-- from activeTargetedListCasts. The ticker self-cancels when no
-- fading records remain.

local targetedListFadeTicker = nil

local function TargetedList_HasAnyFadingRecord()
    for _, rec in pairs(activeTargetedListCasts) do
        if rec.fadingStartedAt then return true end
    end
    return false
end

-- Assign to the forward-declared file-local (see State section
-- above). This avoids creating a global and lets OnCastStop's
-- reference resolve to this function via upvalue lookup.
TargetedList_StartFadeTicker = function()
    if targetedListFadeTicker then return end
    if not C_Timer or not C_Timer.NewTicker then return end
    targetedListFadeTicker = C_Timer.NewTicker(0.05, function()
        if not TargetedList_HasAnyFadingRecord() then
            if targetedListFadeTicker then
                targetedListFadeTicker:Cancel()
                targetedListFadeTicker = nil
            end
            return
        end
        if DF._TargetedListRender then
            DF._TargetedListRender()
        end
    end)
end

-- Scratch array reused across renders to avoid per-render allocations.
local targetedListSortBuf = {}

-- Sort comparators. Only NEWEST and OLDEST are currently implemented —
-- other candidates (SHORTEST_REMAINING, INTERRUPTIBLE_FIRST, TARGET_ORDER)
-- would need to inspect secret-tainted values (duration objects,
-- uninterruptible flag, target-name-to-unit resolution) which errors
-- in Lua. startTime is the only clean numeric sort key we have.
local function TargetedList_SortNewestFirst(a, b)
    return (a.startTime or 0) > (b.startTime or 0)
end
local function TargetedList_SortOldestFirst(a, b)
    return (a.startTime or 0) < (b.startTime or 0)
end

-- ============================================================
-- INCREMENTAL RENDER (TS3-style)
-- ============================================================
-- Instead of tearing down and rebuilding ALL bars every state
-- change, bars persist in casterToBar[unit]. Render:
--   1. Expires completed fades (release that one bar)
--   2. Ensures every live record has a bar (acquire if missing)
--   3. Updates fading bars' alpha/color in-place
--   4. Sorts and repositions — no pool churn
--
-- Content (ApplyBarContent) runs ONCE at acquisition. Subsequent
-- renders only touch alpha/color for fading bars and re-anchor
-- positions via LayoutBars.

local function TargetedList_Render()
    if not TargetedList_IsGateOpen() then return end
    TargetedList_EnsureBarPool()

    local db = DF.db and DF.db.party
    local maxBars = (db and db.targetedListMaxBars) or 6
    local now = TL_GetTime()

    -- Step 1: expire fading records whose window elapsed.
    -- Free their bar and slot.
    for unit, rec in pairs(activeTargetedListCasts) do
        if rec.fadingStartedAt
           and (now - rec.fadingStartedAt) >= (rec.fadingDuration or 0) then
            activeTargetedListCasts[unit] = nil
            local bar = casterToBar[unit]
            if bar then
                targetedListBarPool:Release(bar)
                casterToBar[unit] = nil
            end
            casterToSlot[unit] = nil
        end
    end

    -- Step 1b: release orphaned bars. A bar is orphaned when its
    -- record was removed directly (e.g. fadeDuration == 0 in OnCastStop)
    -- rather than through the fading path. Without this, the bar stays
    -- visible in casterToBar with no record to drive its removal.
    for unit, bar in pairs(casterToBar) do
        if not activeTargetedListCasts[unit] then
            targetedListBarPool:Release(bar)
            casterToBar[unit] = nil
            casterToSlot[unit] = nil
        end
    end

    -- Step 2: ensure every live record has a bar. Assign a slot index
    -- for STATIC sort order — the slot persists for the record's
    -- lifetime so its bar never changes position.
    for unit, rec in pairs(activeTargetedListCasts) do
        if not casterToBar[unit] then
            local bar = targetedListBarPool:Acquire()
            casterToBar[unit] = bar

            -- Find the lowest available slot for STATIC mode.
            -- For non-STATIC modes the slot is unused but harmless.
            if not casterToSlot[unit] then
                -- Find lowest unused slot
                local slot = 1
                local usedSlots = {}
                for _, s in pairs(casterToSlot) do usedSlots[s] = true end
                while usedSlots[slot] do slot = slot + 1 end
                casterToSlot[unit] = slot
            end

            TargetedList_ApplyBarContent(bar, rec)
        end
    end

    -- Step 3: update fading bars' visual state (alpha + color + text).
    for unit, rec in pairs(activeTargetedListCasts) do
        if rec.fadingStartedAt then
            local bar = casterToBar[unit]
            if bar then
                -- selfTargetFrame is a child of bar, so bar:SetAlpha(pct)
                -- below fades the overlay naturally — no explicit alpha
                -- reset needed here.
                local elapsed = now - rec.fadingStartedAt
                local dur = rec.fadingDuration or 0.25
                local pct = 1 - math.min(1, math.max(0, elapsed / dur))
                bar:SetAlpha(pct)
                if rec.wasInterrupted then
                    -- Snap fill to full. SetTimerDuration hands the fill
                    -- animation to the StatusBar engine, which keeps ticking
                    -- after the cast stops. SetValue overrides the timer and
                    -- freezes the bar at the interrupted-flash position.
                    bar.progress:SetMinMaxValues(0, 1)
                    bar.progress:SetValue(1)
                    bar.progress:SetStatusBarColor(1, 0.95, 0.2, 1)
                    if bar.interruptText then
                        bar.spellName:Hide()
                        bar.targetName:Hide()
                        if bar.duration then bar.duration:Hide() end
                        if rec.isTestCast and rec.testInterrupterName then
                            bar.interruptText:SetFormattedText(DF.L["Interrupted: %s"],
                                rec.testInterrupterName)
                            -- Class-color the test interrupter name
                            if rec.testInterrupterClass and TL_C_ClassColor
                               and TL_C_ClassColor.GetClassColor then
                                local col = TL_C_ClassColor.GetClassColor(rec.testInterrupterClass)
                                if col then
                                    bar.interruptText:SetTextColor(col.r, col.g, col.b, 1)
                                end
                            end
                        elseif rec.interrupterGuid and TL_UnitNameFromGUID then
                            -- UnitNameFromGUID returns a secret-tainted string,
                            -- piped through SetFormattedText (secret-safe sink)
                            bar.interruptText:SetFormattedText(DF.L["Interrupted: %s"],
                                TL_UnitNameFromGUID(rec.interrupterGuid) or "")
                            if TL_UnitClassFromGUID and TL_C_ClassColor
                               and TL_C_ClassColor.GetClassColor then
                                local _, iClass = TL_UnitClassFromGUID(
                                    rec.interrupterGuid)
                                if iClass then
                                    local col = TL_C_ClassColor.GetClassColor(iClass)
                                    if col then
                                        bar.interruptText:SetTextColor(
                                            col.r, col.g, col.b, 1)
                                    end
                                end
                            end
                        end
                        bar.interruptText:Show()
                    end
                end
            end
        end
    end

    -- Step 3.5: refresh self-target overlay for all non-fading bars.
    -- Re-evaluating every render pass ensures the overlay reflects the
    -- caster's CURRENT target, not just who they were targeting when
    -- the bar was first assigned (casters can retarget mid-cast).
    for unit, rec in pairs(activeTargetedListCasts) do
        if not rec.fadingStartedAt then
            local bar = casterToBar[unit]
            if bar then
                TargetedList_ApplySelfTargetOverlay(bar, rec, db)
            end
        end
    end

    -- Step 4: sort and build the ordered activeBars list.
    local sortOrder = (db and db.targetedListSortOrder) or "NEWEST"

    wipe(activeBars)
    local count = 0

    if sortOrder == "STATIC" then
        -- Slot-based positioning: each bar has a fixed slot index
        -- assigned at acquisition. Bars never shift. Gaps are left
        -- when a bar is removed.
        for unit, rec in pairs(activeTargetedListCasts) do
            local slot = casterToSlot[unit]
            local bar = casterToBar[unit]
            if bar and slot and slot <= maxBars then
                activeBars[slot] = bar
                TargetedList_ShowBar(bar, db)
                if slot > count then count = slot end
            elseif bar then
                bar:Hide()
            end
        end
    else
        -- Sort-based positioning: gather, sort, assign sequentially.
        wipe(targetedListSortBuf)
        for unit, rec in pairs(activeTargetedListCasts) do
            targetedListSortBuf[#targetedListSortBuf + 1] = rec
        end

        if sortOrder == "OLDEST" then
            table.sort(targetedListSortBuf, TargetedList_SortOldestFirst)
        else
            table.sort(targetedListSortBuf, TargetedList_SortNewestFirst)
        end

        for i = 1, #targetedListSortBuf do
            local rec = targetedListSortBuf[i]
            local bar = casterToBar[rec.casterUnit]
            if bar then
                count = count + 1
                if count <= maxBars then
                    activeBars[count] = bar
                    TargetedList_ShowBar(bar, db)
                else
                    bar:Hide()
                end
            end
        end
        wipe(targetedListSortBuf)
    end

    -- Step 5: position and show container.
    if targetedListContainer then
        if count > 0 then
            targetedListContainer:Show()
        else
            targetedListContainer:Hide()
        end
    end

    TargetedList_LayoutBars()
end

-- Re-export so the cast lifecycle can trigger a render after
-- modifying activeTargetedListCasts.
DF._TargetedListRender = TargetedList_Render

-- Cast-to-channel transition: re-apply bar content so SetTimerDuration
-- picks up the new channel duration. Called from ProcessCastStart which
-- runs before casterToBar and ApplyBarContent are defined.
DF._TargetedListTransitionToChannel = function(casterUnit, rec)
    local bar = casterToBar[casterUnit]
    if bar then
        TargetedList_ApplyBarContent(bar, rec)
    end
end

-- ------------------------------------------------------------
-- Mover
-- ------------------------------------------------------------

local targetedListMover = nil

local function TargetedList_CreateMover()
    if targetedListMover then return targetedListMover end
    TargetedList_EnsureContainer()

    local mover = CreateFrame("Frame", "DandersFramesTargetedListMover", UIParent, "BackdropTemplate")
    mover:SetFrameStrata("DIALOG")
    -- No mode of its own (this display is not party- or raid-specific), so the
    -- mover follows whichever mode the options window is showing.
    DF.GUI:CreateMoverBackdrop(mover)
    mover:EnableMouse(true)
    mover:SetMovable(true)
    mover:RegisterForDrag("LeftButton")
    mover:Hide()

    local label = mover:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    label:SetPoint("CENTER")
    label:SetText("Targeted List")
    label:SetTextColor(1, 1, 1, 1)
    mover.label = label

    -- Left-click switches the shared position panel to our mode.
    mover:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and DF.SetPositionPanelMode then
            DF:SetPositionPanelMode("targetedList")
        end
    end)

    mover:SetScript("OnDragStart", function(self)
        -- Also switch mode on drag start so the panel reflects our
        -- position live as the user nudges.
        if DF.SetPositionPanelMode then
            DF:SetPositionPanelMode("targetedList")
        end
        self:StartMoving()
        local db = DF:GetDB()
        self:SetScript("OnUpdate", function()
            local sw, sh = GetScreenWidth(), GetScreenHeight()
            local cx, cy = self:GetCenter()
            if cx and cy then
                local x, y = cx - sw / 2, cy - sh / 2
                -- Live-follow: keep container glued to mover while dragging
                if targetedListContainer then
                    targetedListContainer:ClearAllPoints()
                    targetedListContainer:SetPoint("CENTER", UIParent, "CENTER", x, y)
                end
                -- Snap preview (matches personal mover behavior)
                if db.snapToGrid and DF.gridFrame and DF.gridFrame:IsShown()
                   and DF.UpdateSnapPreview then
                    DF:UpdateSnapPreview(self)
                end
            end
        end)
    end)

    mover:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self:SetScript("OnUpdate", nil)
        if DF.HideSnapPreview then DF:HideSnapPreview() end

        local sw, sh = GetScreenWidth(), GetScreenHeight()
        local cx, cy = self:GetCenter()
        if not cx or not cy then return end
        local x, y = cx - sw / 2, cy - sh / 2

        -- Snap to grid if enabled, mirroring the personal mover.
        local db = DF:GetDB()
        if db.snapToGrid and DF.gridFrame and DF.gridFrame:IsShown()
           and DF.SnapToGrid then
            x, y = DF:SnapToGrid(x, y)
        end

        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "CENTER", x, y)
        if DF.db and DF.db.party then
            DF.db.party.targetedListX = x
            DF.db.party.targetedListY = y
        end
        DF:UpdateTargetedListLayout()
    end)

    -- Right-click anywhere on the mover locks everything (same as
    -- the personal targeted spells mover and the main mover frame).
    mover:SetScript("OnMouseDown", function(self, button)
        if button == "RightButton" and DF.LockFrames then
            DF:LockFrames()
        end
    end)

    targetedListMover = mover
    DF.targetedListMoverFrame = mover  -- exposed for position panel apply()
    return mover
end

function DF:ShowTargetedListMover()
    if not TargetedList_IsGateOpen() then return end
    TargetedList_CreateMover()
    local db = DF.db and DF.db.party
    if not db then return end
    local w, h = TargetedList_ComputeContainerSize(db)
    targetedListMover:SetSize(w, h)
    targetedListMover:ClearAllPoints()
    targetedListMover:SetPoint("CENTER", UIParent, "CENTER",
        db.targetedListX or 0, db.targetedListY or -10)
    targetedListMover:Show()
    -- Show test bars alongside the mover so users can see the
    -- actual bar layout while positioning.
    DF:ShowTestTargetedList()
end

function DF:HideTargetedListMover()
    if targetedListMover then
        targetedListMover:Hide()
    end
    DF:HideTestTargetedList()
end

-- ------------------------------------------------------------
-- Test mode
-- ------------------------------------------------------------
--
-- Synthetic bars driven from DF.TestData.units (the 5 test party
-- names) and a fixed list of real spell IDs. Bypasses the live-cast
-- lifecycle entirely — test mode just acquires pooled bars, fills
-- them with clean test data, and lays them out.
--
-- Unlike live casts, test spellIds are CLEAN (they're literals in
-- our code, not coming from UnitCastingInfo), so we can use them
-- freely for formatting if needed.

local TARGETED_LIST_TEST_SPELLS = {
    -- {spellId, isChannel, isImportant (always true for demo), uninterruptible}
    {spellId = 196408, isChannel = false, uninterruptible = false},  -- Focused Assault
    {spellId = 260189, isChannel = true,  uninterruptible = false},  -- Grasping Tendrils
    {spellId = 204242, isChannel = false, uninterruptible = true},   -- Solar Beam
    {spellId = 207982, isChannel = false, uninterruptible = false},  -- Mortal Strike
    {spellId = 205708, isChannel = true,  uninterruptible = false},  -- Chilled
    {spellId = 229714, isChannel = false, uninterruptible = true},   -- Death Bolt
}

local function TargetedList_GetTestTargetName(index)
    local units = DF.TestData and DF.TestData.units
    if not units or #units == 0 then return "Target" end
    local u = units[((index - 1) % #units) + 1]
    return u and u.name or "Target"
end

local function TargetedList_GetTestTargetClass(index)
    local units = DF.TestData and DF.TestData.units
    if not units or #units == 0 then return nil end
    local u = units[((index - 1) % #units) + 1]
    return u and u.class or nil
end

-- ============================================================
-- Test mode: fake event generator
-- ============================================================
-- Instead of pre-allocating bars and animating them in-place,
-- test mode periodically spawns fake cast records into
-- activeTargetedListCasts. The normal render pipeline handles
-- everything — sorting, layout, bar acquisition, content, fade.
-- This means test mode looks exactly like live play: bars appear,
-- shift, sort, fade out, and flash on interrupt.

local targetedListTestTicker = nil
local targetedListTestNextId = 1  -- incrementing key for test records

-- Spawn a new fake cast record. Called periodically by the ticker.
local function TargetedList_SpawnTestCast()
    local db = DF.db and DF.db.party
    if not db then return end

    -- Pick a test spell and target
    local idx = ((targetedListTestNextId - 1) % #TARGETED_LIST_TEST_SPELLS) + 1
    local spec = TARGETED_LIST_TEST_SPELLS[idx]
    local tIdx = ((targetedListTestNextId - 1) % 5) + 1
    local targetName = TargetedList_GetTestTargetName(tIdx)
    local targetClass = TargetedList_GetTestTargetClass(tIdx)

    -- Clean spell metadata
    local spellName = TL_C_Spell_GetSpellName and TL_C_Spell_GetSpellName(spec.spellId) or "Test Spell"
    local spellTexture = TL_C_Spell_GetSpellTexture and TL_C_Spell_GetSpellTexture(spec.spellId)

    local castDuration = 2 + (targetedListTestNextId % 5) * 1.0  -- 2-6s
    local willInterrupt = (targetedListTestNextId % 3 == 0)
    local key = "test-" .. targetedListTestNextId
    targetedListTestNextId = targetedListTestNextId + 1

    -- Interrupted casts trigger at 40-80% of their duration so they
    -- look like real mid-cast interrupts, not completed-then-interrupted.
    local interruptAt = nil
    if willInterrupt then
        interruptAt = castDuration * (0.4 + (targetedListTestNextId % 5) * 0.1)
    end

    activeTargetedListCasts[key] = {
        isTestCast       = true,
        spellId          = spec.spellId,
        isChannel        = spec.isChannel or false,
        startTime        = TL_GetTime(),
        casterUnit       = key,  -- fake unit token
        uninterruptible  = spec.uninterruptible or false,
        -- Test-specific clean fields (bypasses secret-value APIs)
        testSpellName    = spellName,
        testSpellTexture = spellTexture,
        testTargetName   = targetName,
        testTargetClass  = targetClass,
        testCastDuration = castDuration,
        testWillInterrupt = willInterrupt,
        testInterruptAt  = interruptAt,
        -- Fake interrupter name + class for display during interrupted flash
        testInterrupterName = willInterrupt and targetName or nil,
        testInterrupterClass = willInterrupt and targetClass or nil,
        -- Alternate importance: odd-numbered casts are "important"
        testIsImportant = (targetedListTestNextId % 2 == 0),
        -- Alternate self-targeting: every 3rd cast targets the player
        testIsTargetingPlayer = (targetedListTestNextId % 3 == 1),
    }

    -- NOTE: caller is responsible for calling TargetedList_Render()
    -- after all spawns/modifications are done. This avoids premature
    -- bar acquisition before static-mode record modifications.
end

-- Lightweight progress update for test bars. Only touches SetValue
-- on existing bars — no bar rebuild, no pool churn. This is what
-- runs every tick for smooth fill animation.
local function TargetedList_UpdateTestProgress()
    -- Iterate all tracked bars via casterToBar (not activeBars which
    -- may have nil gaps in STATIC mode that ipairs would skip).
    local now = TL_GetTime()
    for unit, bar in pairs(casterToBar) do
        local rec = activeTargetedListCasts[unit]
        if rec and rec.isTestCast and rec.testCastDuration
           and not rec.fadingStartedAt and not rec.testFrozenFill then
            local cutoff = rec.testInterruptAt or rec.testCastDuration
            local elapsed = now - rec.startTime
            local pct = math.min(1, math.max(0, elapsed / cutoff))
            bar.progress:SetMinMaxValues(0, 1)
            bar.progress:SetValue(pct)
        end
    end
end

-- Check test casts and transition them to fading when their cast
-- duration elapses. Called by the test ticker. Only triggers a full
-- Render on state transitions (cast finished → fading), not every tick.
local function TargetedList_UpdateTestCasts()
    local db = DF.db and DF.db.party
    if not db then return end
    local now = TL_GetTime()
    local fadeDuration = db.targetedListFadeOutDuration or 0.25
    local flashDuration = db.targetedListInterruptedFlashDuration or 1.0
    local needsRender = false

    for key, rec in pairs(activeTargetedListCasts) do
        if rec.isTestCast and not rec.fadingStartedAt then
            local elapsed = now - rec.startTime
            local cutoff = rec.testInterruptAt or rec.testCastDuration or 3
            if elapsed >= cutoff then
                local wasInt = rec.testWillInterrupt
                rec.fadingStartedAt = now
                rec.fadingDuration = wasInt and flashDuration or fadeDuration
                rec.wasInterrupted = wasInt
                needsRender = true
                TargetedList_StartFadeTicker()
            end
        end
    end

    -- Only re-render if a cast actually transitioned to fading.
    -- The fade ticker handles continuous alpha updates separately.
    if needsRender then
        TargetedList_Render()
    end
end

function DF:ShowTestTargetedList()
    if not TargetedList_IsGateOpen() then return end

    -- FIRST: cancel any running ticker from a previous mode. This
    -- prevents animated-mode tickers from interfering with static mode.
    if targetedListTestTicker then
        targetedListTestTicker:Cancel()
        targetedListTestTicker = nil
    end
    -- Also cancel the fade ticker to prevent stale fade renders
    if targetedListFadeTicker then
        targetedListFadeTicker:Cancel()
        targetedListFadeTicker = nil
    end

    targetedListTestActive = true
    TargetedList_EnsureContainer()
    TargetedList_EnsureBarPool()

    -- Clear ALL existing test records AND their bars from casterToBar
    for key in pairs(activeTargetedListCasts) do
        if type(key) == "string" and key:sub(1, 5) == "test-" then
            activeTargetedListCasts[key] = nil
            local bar = casterToBar[key]
            if bar then
                targetedListBarPool:Release(bar)
                casterToBar[key] = nil
            end
        end
    end
    wipe(activeBars)
    targetedListTestNextId = 1

    local db = DF.db and DF.db.party
    local maxBars = (db and db.targetedListMaxBars) or 6
    local animate = db and db.testAnimateTargetedList

    if animate then
        -- Animated mode: spawn initial batch staggered, ticker manages lifecycle
        local initialCount = math.min(maxBars, 4)
        for i = 1, initialCount do
            TargetedList_SpawnTestCast()
        end
        TargetedList_Render()

        -- Ticker spawns new casts and manages lifecycle.
        if not targetedListTestTicker and C_Timer and C_Timer.NewTicker then
            local spawnInterval = 2.0
            local spawnTimer = 0
            targetedListTestTicker = C_Timer.NewTicker(0.05, function()
                if not targetedListTestActive then
                    if targetedListTestTicker then
                        targetedListTestTicker:Cancel()
                        targetedListTestTicker = nil
                    end
                    return
                end

                -- Check for cast completions / interrupts
                TargetedList_UpdateTestCasts()

                -- Lightweight progress fill update (no bar rebuild)
                TargetedList_UpdateTestProgress()

                -- Periodically spawn new casts
                spawnTimer = spawnTimer + 0.05
                if spawnTimer >= spawnInterval then
                    spawnTimer = 0
                    local count = 0
                    for _, rec in pairs(activeTargetedListCasts) do
                        if rec.isTestCast and not rec.fadingStartedAt then
                            count = count + 1
                        end
                    end
                    if count < ((DF.db and DF.db.party and DF.db.party.targetedListMaxBars) or 6) then
                        TargetedList_SpawnTestCast()
                        TargetedList_Render()
                    end
                end
            end)
        end
    else
        -- Static mode: showcase all visual states for customisation.
        -- Bars show a mix of: normal casting (interruptible +
        -- uninterruptible), interrupted (with interrupter name), and
        -- important glow. Each bar is frozen at a varied fill point.
        for i = 1, maxBars do
            TargetedList_SpawnTestCast()
            local key = "test-" .. (targetedListTestNextId - 1)
            local rec = activeTargetedListCasts[key]
            if rec then
                -- Freeze the bar at a varied fill point. We store this
                -- directly rather than using time math (which broke when
                -- testCastDuration was set to 99999 making elapsed/dur ≈ 0).
                rec.testFrozenFill = 0.2 + ((i - 1) * 0.12) % 0.6
                rec.testCastDuration = 99999
                rec.testInterruptAt = nil
                rec.testWillInterrupt = false

                -- Distribute visual states across the bars:
                -- Bar 3 (if maxBars >= 3) or last bar: show as interrupted
                if maxBars >= 3 and i == 3 then
                    rec.fadingStartedAt = TL_GetTime()
                    rec.fadingDuration = 99999  -- never expires in static
                    rec.wasInterrupted = true
                    rec.testFrozenFill = 0.55   -- partial fill on interrupt
                    rec.testInterrupterName = TargetedList_GetTestTargetName(
                        ((i + 1) % 5) + 1)
                    rec.testInterrupterClass = TargetedList_GetTestTargetClass(
                        ((i + 1) % 5) + 1)
                elseif i == maxBars and maxBars ~= 3 then
                    rec.fadingStartedAt = TL_GetTime()
                    rec.fadingDuration = 99999
                    rec.wasInterrupted = true
                    rec.testFrozenFill = 0.7
                    rec.testInterrupterName = TargetedList_GetTestTargetName(
                        ((i + 2) % 5) + 1)
                    rec.testInterrupterClass = TargetedList_GetTestTargetClass(
                        ((i + 2) % 5) + 1)
                end
            end
        end
        TargetedList_Render()
    end
end

function DF:HideTestTargetedList()
    targetedListTestActive = false
    -- Cancel the test ticker
    if targetedListTestTicker then
        targetedListTestTicker:Cancel()
        targetedListTestTicker = nil
    end
    -- Remove test records and release their bars + slots individually
    for key in pairs(activeTargetedListCasts) do
        if type(key) == "string" and key:sub(1, 5) == "test-" then
            activeTargetedListCasts[key] = nil
            local bar = casterToBar[key]
            if bar then
                targetedListBarPool:Release(bar)
                casterToBar[key] = nil
            end
            casterToSlot[key] = nil
        end
    end
    -- Rebuild activeBars from remaining live records
    wipe(activeBars)
    local count = 0
    for unit, bar in pairs(casterToBar) do
        count = count + 1
        activeBars[count] = bar
    end
    if targetedListContainer then
        if count > 0 then
            TargetedList_LayoutBars()
        else
            targetedListContainer:Hide()
        end
    end
end

-- Called from ReleaseAllBars (the lifecycle path) so it also tears
-- down the visible bars including any test records.
local _TargetedList_ReleaseAllBars_Prev = TargetedList_ReleaseAllBars
TargetedList_ReleaseAllBars = function()
    if not TargetedList_IsGateOpen() then return end
    _TargetedList_ReleaseAllBars_Prev()
    TargetedList_ReleaseAllActiveBars()
    if targetedListContainer then
        targetedListContainer:Hide()
    end
end
DF._TargetedListReleaseAllBars = TargetedList_ReleaseAllBars

-- ------------------------------------------------------------
-- Hook the cast lifecycle to trigger renders
-- ------------------------------------------------------------
--
-- DelayedPickup and OnCastStop already modify activeTargetedListCasts.
-- We re-wrap them with a post-modification render trigger. Test mode
-- and live casts both share the same render pipeline, so no guards.

local _TargetedList_DelayedPickup_Prev = TargetedList_DelayedPickup
TargetedList_DelayedPickup = function(...)
    _TargetedList_DelayedPickup_Prev(...)
    TargetedList_Render()
end

local _TargetedList_OnCastStop_Prev = TargetedList_OnCastStop
TargetedList_OnCastStop = function(...)
    _TargetedList_OnCastStop_Prev(...)
    TargetedList_Render()
end

local _TargetedList_OnInterruptibility_Prev = TargetedList_OnInterruptibilityChange
TargetedList_OnInterruptibilityChange = function(...)
    _TargetedList_OnInterruptibility_Prev(...)
    TargetedList_Render()
end

DF._TargetedListProcessCastStart = TargetedList_ProcessCastStart
DF._TargetedListPickupInProgressCast = TargetedList_PickupInProgressCast
DF._TargetedListOnCastStop = TargetedList_OnCastStop
DF._TargetedListOnCastUpdate = TargetedList_OnCastUpdate
DF._TargetedListOnInterruptibilityChange = TargetedList_OnInterruptibilityChange
DF._TargetedListOnTargetChange = TargetedList_OnTargetChange
DF._TargetedListValidateAll = TargetedList_ValidateTrackedBars

-- ------------------------------------------------------------
-- Public entry points
-- ------------------------------------------------------------

-- Called from DF:InitTargetedSpells() at addon init and from the
-- settings toggle callback. Safe to call on stable (no-op via gate).
function DF:InitTargetedList()
    if not TargetedList_IsGateOpen() then return end
    -- Create the container early so the mover / test mode have
    -- something to anchor to. Bar pool stays lazy.
    TargetedList_EnsureContainer()
end

-- Called from the settings-apply path. Bumps the layout version and
-- triggers a re-layout. Safe to call on every callback.
function DF:UpdateTargetedListLayout()
    if not TargetedList_IsGateOpen() then return end
    targetedListLayoutVersion = targetedListLayoutVersion + 1
    -- Re-apply appearance + content to all existing bars so settings
    -- changes (font, texture, border, etc.) take effect on bars that
    -- are already acquired (the incremental render only applies
    -- content at acquisition time, not on every render tick).
    local db = DF.db and DF.db.party
    for unit, bar in pairs(casterToBar) do
        local rec = activeTargetedListCasts[unit]
        if rec then
            TargetedList_ApplyBarContent(bar, rec)
        end
    end
    TargetedList_Render()
    -- Also resize the mover if it's visible
    if targetedListMover and targetedListMover:IsShown() then
        local db = DF.db and DF.db.party
        if db then
            local w, h = TargetedList_ComputeContainerSize(db)
            targetedListMover:SetSize(w, h)
        end
    end
end

-- Lightweight updates for color picker drag. These only touch the
-- specific visual property on existing bars — no layout rebuild, no
-- pool churn, no content re-application. Designed to run at color-
-- picker drag-tick rate without lag.

function DF:LightweightUpdateTargetedListBarColor()
    if not TargetedList_IsGateOpen() then return end
    local db = DF.db and DF.db.party
    if not db then return end
    local interColor = db.targetedListInterruptibleColor or {r=1, g=0.2, b=0.2, a=1}
    local uninterColor = db.targetedListUninterruptibleColor or {r=0.5, g=0.5, b=0.5, a=1}
    for unit, bar in pairs(casterToBar) do
        local rec = activeTargetedListCasts[unit]
        if rec and not rec.fadingStartedAt then
            if rec.isTestCast then
                local c = rec.uninterruptible and uninterColor or interColor
                bar.progress:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
            elseif rec.uninterruptible ~= nil then
                local tex = bar.progress:GetStatusBarTexture()
                if tex and tex.SetVertexColorFromBoolean then
                    tex:SetVertexColorFromBoolean(rec.uninterruptible,
                        uninterColor, interColor)
                end
            end
        end
    end
end

function DF:LightweightUpdateTargetedListBorderColor()
    if not TargetedList_IsGateOpen() then return end
    local db = DF.db and DF.db.party
    if not db then return end
    -- Route through BuildSpec + Apply (Stage 4.5) so the live drag-update
    -- path renders identically to TargetedList_ApplyBarAppearance.
    for _, bar in pairs(casterToBar) do
        if bar.border then
            DF.Border:Apply(bar.border, DF.Border:BuildSpec(db, "targetedList"))
        end
    end
end

function DF:LightweightUpdateTargetedListHighlightColor()
    if not TargetedList_IsGateOpen() then return end
    local db = DF.db and DF.db.party
    if not db then return end
    local hc = db.targetedListHighlightColor or {r=1, g=0.8, b=0}
    for _, bar in pairs(casterToBar) do
        if bar.highlightFrame and bar.highlightFrame:IsShown() and bar.highlightBorder then
            -- Static solid highlight border (no animation): the Targeted List
            -- highlight has only an enable toggle + colour, and historically was
            -- a calm glow — a flashing PROC here reads as broken.
            DF.Border:Apply(bar.highlightBorder, {
                enabled = true, size = 2, inset = 0, style = "SOLID",
                color = { r = hc.r, g = hc.g, b = hc.b, a = hc.a or 1 },
            })
        end
    end
end

-- Called from the settings-apply path when the enable checkbox flips.
function DF:ToggleTargetedList(enabled)
    if not TargetedList_IsGateOpen() then return end
    if enabled then
        DF:InitTargetedList()
        TargetedList_Render()
    else
        TargetedList_ReleaseAllBars()
    end
    -- Re-evaluate shared event registration — the cast event frame
    -- may need to turn on/off depending on other consumers.
    DF:UpdateTargetedSpellEventRegistration()
end

-- ============================================================
-- INITIALIZATION
-- ============================================================

function DF:InitTargetedSpells()
    -- Cast events register for whatever is live (party fingerprint group
    -- display, personal display, and/or the Targeted List), handled by
    -- UpdateTargetedSpellEventRegistration below.

    -- No nameplateShowOffscreen write here. This used to force the CVar ON at
    -- every login from a saved key that no surviving control could clear, so a
    -- user who ticked it once in the old Targeted Spells page had it forced on
    -- forever with no way off. The CVar is now owned outright by the checkboxes
    -- on the Targeted List / Personal Targeted pages (DF:GetNameplateOffscreen /
    -- DF:SetNameplateOffscreen) and the targetedSpellNameplateOffscreen key is
    -- retired — stale copies in saved profiles are simply never read.

    -- Initialize personal targeted spells. Note: TogglePersonalTargetedSpells
    -- only manages the container/icons; the events that drive cast tracking
    -- are registered separately so personal display can run even when the
    -- group-frame feature is off or API-blocked.
    if GetPersonalDB().personalTargetedSpellEnabled then
        DF:TogglePersonalTargetedSpells(true)
    end

    -- Initialize the Targeted List. Safe to call unconditionally — the
    -- function is gated internally on the user's targetedListEnabled setting.
    if DF.InitTargetedList then
        DF:InitTargetedList()
    end

    DF:UpdateTargetedSpellEventRegistration()
end
