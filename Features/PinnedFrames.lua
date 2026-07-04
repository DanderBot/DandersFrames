local addonName, DF = ...

-- ============================================================
-- PINNED FRAMES - Separate frame sets for selected players
-- Uses SecureGroupHeaderTemplate with nameList for explicit control
-- ============================================================

local format = string.format

local PinnedFrames = {}
DF.PinnedFrames = PinnedFrames

-- Storage for headers and containers
PinnedFrames.containers = {}  -- [setIndex] = container frame
PinnedFrames.headers = {}     -- [setIndex] = SecureGroupHeaderTemplate
PinnedFrames.labels = {}      -- [setIndex] = label fontstring
PinnedFrames.bossFrames = {}  -- [setIndex] = { [1..8] = boss frame }
PinnedFrames.bossHandlers = {}  -- [setIndex] = SecureHandlerStateTemplate frame (drives fixed-slot allocator for boss frames)
PinnedFrames.testFrames = {}    -- [setIndex] = { [1..N] = fake non-secure test frame (player-mode Test Mode)}
PinnedFrames.testContainers = {} -- [setIndex] = non-secure container at the test-mode profile's position for this set
PinnedFrames.initialized = false
PinnedFrames.currentMode = nil  -- Track what mode we initialized for
-- Global unlock state: pinned movers/chrome are shown only while the MAIN frames
-- are unlocked (driven from DF:UnlockFrames / DF:UnlockRaidFrames). Replaces the
-- retired per-set `set.locked`. Default false = locked (no drag handles).
PinnedFrames.moversShown = false

-- Color palette per mode (raid = orange, party = purple-blue)
-- Matches C_RAID / C_ACCENT used across the GUI
local function GetModeColors(isRaid)
    if isRaid then
        return {
            containerBg     = { 0.30, 0.15, 0.05, 0.30 },
            containerBorder = { 0.80, 0.40, 0.15, 0.80 },
            moverBg         = { 0.40, 0.20, 0.05, 0.90 },
            moverBorder     = { 1.00, 0.50, 0.20, 1.00 },
            moverText       = { 1.00, 0.80, 0.50 },
        }
    end
    return {
        containerBg     = { 0.10, 0.10, 0.30, 0.30 },
        containerBorder = { 0.40, 0.40, 0.80, 0.80 },
        moverBg         = { 0.20, 0.20, 0.40, 0.90 },
        moverBorder     = { 0.50, 0.50, 0.90, 1.00 },
        moverText       = { 0.80, 0.80, 1.00 },
    }
end

-- Make a pinned drag handle read as clickable and show which set the position
-- panel is currently driving. All text stays white (addon convention); the
-- selected handle stands out by being solid + bright while the others dim.
-- States (only while the panel is in pinned mode does dimming apply):
--   active   — SOLID full accent fill + white edge (the panel targets this set)
--   hovered  — white edge + lighter fill (the "pointed at" cue)
--   resting  — accent edge + dark fill; DIMMED when another handle is active
-- Colours come from mover.dfColors so the pooled test handle can be re-themed on
-- a party<->raid flip by updating that table and calling restyle.
local function StylePinnedHandle(mover, borderTex, innerTex, textFS, colors)
    mover.dfColors = colors
    mover.dfActive = false
    mover.dfHovered = false

    local DIM = 0.40  -- alpha for non-selected handles while one is selected

    local function restyle()
        local c = mover.dfColors or {}
        local accent = c.moverBorder or { 1, 1, 1, 1 }
        local fill = c.moverBg or { 0, 0, 0, 1 }
        if mover.dfActive then
            -- Selected: solid, full-brightness accent fill, white edge + text.
            if innerTex then innerTex:SetColorTexture(accent[1], accent[2], accent[3], 1) end
            if borderTex then borderTex:SetColorTexture(1, 1, 1, 1) end
            if textFS then textFS:SetTextColor(1, 1, 1, 1) end
        elseif mover.dfHovered then
            if innerTex then innerTex:SetColorTexture(
                math.min(fill[1] + 0.20, 1), math.min(fill[2] + 0.20, 1),
                math.min(fill[3] + 0.20, 1), fill[4] or 1) end
            if borderTex then borderTex:SetColorTexture(1, 1, 1, 1) end
            if textFS then textFS:SetTextColor(1, 1, 1, 1) end
        else
            -- Resting. Dim only when the panel is targeting some OTHER pinned set,
            -- so a fresh unlock (no pinned target) leaves every handle full.
            local d = (DF.positionPanelMode == "pinned") and DIM or 1
            if innerTex then innerTex:SetColorTexture(fill[1], fill[2], fill[3], (fill[4] or 1) * d) end
            if borderTex then borderTex:SetColorTexture(accent[1], accent[2], accent[3], (accent[4] or 1) * d) end
            if textFS then textFS:SetTextColor(1, 1, 1, d) end
        end
    end
    mover.dfRestyle = restyle
    mover.SetActive = function(_, on) mover.dfActive = on and true or false; restyle() end

    -- Auto-size the handle to its label, with generous padding so it reads as a
    -- solid, obvious handle rather than a thin bar.
    mover.dfFitWidth = function()
        local w = ((textFS and textFS:GetStringWidth()) or 0) + 28
        if w < 48 then w = 48 end
        mover:SetWidth(w)
        mover:SetHeight(20)
    end

    mover:HookScript("OnEnter", function(self)
        self.dfHovered = true
        restyle()
        DF.GUI:ShowTooltip(self, {
            anchor = "ANCHOR_TOP",
            title = textFS and textFS:GetText() or DF.L["Pinned"],
            lines = {
                DF.L["Drag to move"],
                DF.L["Click to open the position panel"],
            },
        })
    end)
    mover:HookScript("OnLeave", function(self)
        self.dfHovered = false
        restyle()
        DF.GUI:HideTooltip()
    end)

    restyle()
    mover.dfFitWidth()
end

-- ============================================================
-- UTILITY FUNCTIONS
-- ============================================================

-- Get pinned frames config for actual current mode
-- The mode DB (party/raid) the REAL pinned frames inherit their sizing/colours
-- from. Uses live IsInRaid(): the real pinned frames are live-group entities. The
-- test-mode PREVIEW frames size themselves from an explicit isRaidMode instead
-- (see ApplyPlayerTestLayout), so raid test mode never routes through here.
local function GetPinnedModeDB()
    return IsInRaid() and DF:GetRaidDB() or DF:GetDB()
end

local function GetPinnedDB()
    local db = GetPinnedModeDB()
    return db and db.pinnedFrames
end

-- Maximum pinned sets a profile may hold. Each ACTIVE (enabled) set is a live
-- SecureGroupHeaderTemplate that re-evaluates on every roster event, so this
-- ceiling is perf-bounded, not arbitrary; defined-but-disabled sets are dormant
-- and cheap. Exposed on the module so the editor can gate the "Add set" button.
-- 4 keeps the editor tab strip on one row and the active-header count sane.
PinnedFrames.MAX_SETS = 4

-- Count of sets defined in this mode's pinned config, clamped to MAX_SETS.
local function NumSets(hlDB)
    hlDB = hlDB or GetPinnedDB()
    if not hlDB or not hlDB.sets then return 0 end
    local n = #hlDB.sets
    if n > PinnedFrames.MAX_SETS then n = PinnedFrames.MAX_SETS end
    return n
end

-- Get the current actual mode (not cached)
local function GetActualMode()
    return IsInRaid() and "raid" or "party"
end

-- Party-only "Show when solo" gate. When solo (not in any group) a pinned set
-- stays HIDDEN unless its showInSoloMode is explicitly set — pinned frames
-- highlight other group members, which don't exist solo. Raid is unaffected
-- (being in a raid implies a group, and raid has no solo toggle by design).
-- Test-mode previews always pass — they simulate a group so the frames can be
-- configured. Default (nil) = hidden when solo; the checkbox opts in to showing.
local function PinnedSoloAllowed(set)
    if DF.testMode or DF.raidTestMode then return true end
    if IsInGroup() then return true end
    return set and set.showInSoloMode == true  -- opt-in to show when solo
end

-- Display label for a set's drag handle + position panel: the set's name (or
-- "Pinned N" when unnamed) tagged with the mode it belongs to, e.g. "NPC (Raid)".
local function PinnedSetLabel(set, setIndex, isRaidMode)
    local name = set and set.name
    if not name or name == "" then name = "Pinned " .. (setIndex or 1) end
    return name .. " (" .. (isRaidMode and "Raid" or "Party") .. ")"
end

-- True when instanced PvP has pinned processing disabled (the live default —
-- see ProcessAllSets for the full rationale). Shared by ProcessAllSets
-- (auto-population dormancy) and ComputeHiddenNames: a dormant feature must
-- not keep filtering its (frozen, possibly stale) members out of the main
-- frames either.
local function PinnedPvPDormant(hlDB)
    local inPvP = (DF.IsInArena and DF:IsInArena())
        or (DF.IsInBattleground and DF:IsInBattleground())
    if not inPvP then return false end
    local disableInPvP = hlDB and hlDB.disableInPvP
    if disableInPvP == nil then disableInPvP = true end
    return disableInPvP
end

-- Resolve which mode's main-frame DB a pinned set inherits its baseline look
-- from (size, and later border/background). set.matchMode is "party" / "raid";
-- it defaults to the set's OWN mode (a party set mirrors party frames, a raid
-- set mirrors raid frames), and a set can cross-match the opposite mode. Since a
-- set only ever displays in its own mode, `activeDB` (the caller's resolved mode
-- — active mode for real frames, explicit test-mode DB otherwise) IS the own
-- mode, so an unset/legacy matchMode falls through to it.
local function GetSetBaselineDB(set, activeDB)
    local m = set and set.matchMode
    if m == "party" then return DF:GetDB("party") end
    if m == "raid"  then return DF:GetRaidDB() end
    return activeDB  -- unset/legacy → the set's own (displayed) mode
end

-- Resolve a set's per-button frame width/height. The baseline is the main frames
-- of the set's Match mode (db.frameWidth/Height, via GetSetBaselineDB); a set may
-- override either dimension per-set via set.customWidth / customHeight (nil =
-- inherit the Match value). The per-set `scale` multiplier still applies on top
-- via the container's SetScale, so this is the unscaled base size.
local function GetSetFrameSize(set, db)
    db = GetSetBaselineDB(set, db)
    local w = (set and set.customWidth) or (db and db.frameWidth) or 120
    local h = (set and set.customHeight) or (db and db.frameHeight) or 50
    return w, h
end

-- Grow direction is a pinned-ONLY setting: the main party/raid frames' own
-- growDirection means *group* arrangement (labelled "Rows / Columns"), which is a
-- different concept from how pinned buttons flow — so it is NOT inherited. Plain
-- per-set value, default HORIZONTAL.
local function GetSetGrowDirection(set)
    return (set and set.growDirection) or "HORIZONTAL"
end

-- Scale DOES inherit the Match mode's frameScale (a plain multiplier, same
-- meaning everywhere) unless the set overrides it (set.scale ~= nil).
-- `db` (optional) names the set's displayed-mode db explicitly — pass it from
-- mode-explicit paths (test previews) so a cross-mode preview (raid test while
-- solo/party) doesn't fall back to the LIVE mode's frameScale via
-- GetPinnedModeDB when matchMode is unset.
local function GetSetScale(set, db)
    if set and set.scale then return set.scale end
    local b = GetSetBaselineDB(set, db or GetPinnedModeDB())
    return (b and b.frameScale) or 1.0
end

-- Pinned row/column spacing inherits the Based-on mode's layout spacing when the
-- per-set value is unset (nil), exactly like GetSetScale inherits frameScale.
-- Without this a pinned set sat on a hardcoded default of 2 and drifted out of
-- alignment with a raid whose frameSpacing was e.g. 1.  Grouped party / grouped
-- raid use a single frameSpacing for both axes; flat raid uses
-- raidFlatHorizontalSpacing / raidFlatVerticalSpacing.  A non-nil per-set
-- horizontalSpacing / verticalSpacing override wins.  Returns hSpacing, vSpacing.
local function GetSetSpacing(set, db)
    local b = GetSetBaselineDB(set, db or GetPinnedModeDB())
    local bh, bv
    if b and b.raidUseGroups == false then
        bh, bv = (b.raidFlatHorizontalSpacing or 2), (b.raidFlatVerticalSpacing or 2)
    else
        local s = (b and b.frameSpacing) or 2
        bh, bv = s, s
    end
    local h = set and set.horizontalSpacing
    local v = set and set.verticalSpacing
    return (h ~= nil) and h or bh, (v ~= nil) and v or bv
end

-- Frame-border keys are all "frame…Border…" (frameShowBorder, frameBorderStyle,
-- frameBorderColor, …); pixelPerfect is the one extra frame-level key BuildSpec
-- reads. Used to snapshot a set's Border Override from the Based-on mode.
local function IsFrameBorderKey(key)
    if type(key) ~= "string" then return false end
    if key == "pixelPerfect" then return true end
    return key:find("^frame") ~= nil and key:find("Border") ~= nil
end

-- The DB a set's frame border renders from: the set itself when Border Override
-- is on (a complete snapshot seeded from the Based-on mode, so edits are
-- independent), else the Based-on mode DB (live inherit). `baselineDB` is the
-- resolved Based-on mode DB.
local function GetSetBorderDB(set, baselineDB)
    if set and set.borderOverride then return set end
    return baselineDB
end

-- Per-frame effective DB for the Hide Auras / Hide Status Icons toggles: a thin
-- overlay on the mode `base` that forces showBuffs/showDebuffs off (hideAuras) and
-- every `<name>IconEnabled` flag off (hideIcons), so the existing aura/icon
-- updaters hide via their own paths. Returns nil when neither is set, so
-- GetFrameDB falls through to the normal mode db (zero overhead when unused).
-- Defensive / Missing-Buff are aura *indicators* (named with the IconEnabled
-- suffix) — they belong under Hide Auras, not Hide Status Icons.
local AURA_INDICATOR_ICON_KEYS = {
    defensiveIconEnabled   = true,
    missingBuffIconEnabled = true,
}

-- pairs() can't traverse the raid db proxy (WrapDB returns an EMPTY table whose
-- reads go through __index), so enumerating GetRaidDB() yields ZERO keys and
-- silently no-ops any key-discovery loop. Resolve to the real raid table for
-- ENUMERATION ONLY; individual value reads should still go through the passed
-- db so runtime auto-layout overrides keep resolving.
local function EnumerableDB(db)
    if db ~= nil and db == DF._raidProxy then
        return DF._realRaidDB or db
    end
    return db
end

local function BuildPinnedEffDB(base, hideAuras, hideIcons)
    if not base or not (hideAuras or hideIcons) then return nil end
    local t = setmetatable({}, { __index = base })
    if hideAuras then
        t.showBuffs = false
        t.showDebuffs = false
        t.defensiveIconEnabled = false
        t.missingBuffIconEnabled = false
    end
    if hideIcons then
        for k in pairs(EnumerableDB(base)) do
            if type(k) == "string" and k:find("IconEnabled", 1, true)
               and not AURA_INDICATOR_ICON_KEYS[k] then
                t[k] = false
            end
        end
    end
    return t
end

-- Snapshot the Based-on mode's frame border into a set so its Border Override
-- controls start identical to the inherited look and edits never leak back to the
-- real frames (colour tables are deep-copied). Normally only fills keys the set
-- doesn't already have (so toggling Override off then on preserves prior edits);
-- pass force=true to overwrite every key — used by "Reset Border to Inherited".
function PinnedFrames:SeedSetBorderOverride(set, force)
    if not set then return end
    local baseDB = GetSetBaselineDB(set, GetPinnedModeDB())
    if not baseDB then return end
    -- Enumerate key names from the real table (the raid proxy yields nothing to
    -- pairs); read values through baseDB so runtime overrides still resolve.
    for key in pairs(EnumerableDB(baseDB)) do
        if IsFrameBorderKey(key) and (force or set[key] == nil) then
            local value = baseDB[key]
            if type(value) == "table" then
                set[key] = DF:DeepCopy(value)
            else
                set[key] = value
            end
        end
    end
end

-- Shallow value compare that also handles the flat {r,g,b,a} colour tables the
-- border keys use, so we can tell whether an override actually differs from the
-- inherited value (drives "reset only shows when changed").
local function BorderValEqual(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) == "table" then
        for k, v in pairs(a) do if b[k] ~= v then return false end end
        for k, v in pairs(b) do if a[k] ~= v then return false end end
        return true
    end
    return a == b
end

-- True only when Border Override is on AND at least one border key has been
-- changed from the inherited (Based-on) value.
function PinnedFrames:IsBorderOverrideChanged(set)
    if not set or not set.borderOverride then return false end
    local baseDB = GetSetBaselineDB(set, GetPinnedModeDB())
    if not baseDB then return false end
    for key, val in pairs(set) do
        if IsFrameBorderKey(key) and not BorderValEqual(val, baseDB[key]) then
            return true
        end
    end
    return false
end

-- Get a specific set's config
local function GetSetDB(setIndex)
    local hlDB = GetPinnedDB()
    return hlDB and hlDB.sets and hlDB.sets[setIndex]
end

-- Returns true if the set is configured to show friendly boss NPCs instead of players
local function IsBossSet(set)
    return set and set.frameType == "friendlyBoss"
end

-- Build nameList from player array
-- Uses full names (including realm for cross-realm players) to match WoW's nameList format
local function BuildNameList(players)
    if not players or #players == 0 then
        return ""
    end
    
    -- Just join the names with commas - don't strip realms
    return table.concat(players, ",")
end

-- Get current group roster as a lookup table
-- Returns both the roster lookup AND the actual names from GetRaidRosterInfo
local function GetGroupRoster()
    local roster = {}          -- shortName -> rosterName (for lookup)
    local rosterNames = {}     -- list of actual roster names (for nameList)
    local numMembers = GetNumGroupMembers()
    
    if numMembers == 0 then
        local name = GetUnitName("player", true)  -- Returns "Name-Realm"
        roster[name] = name
        table.insert(rosterNames, name)
        return roster, rosterNames
    end
    
    local isRaid = IsInRaid()
    
    if isRaid then
        -- Use GetRaidRosterInfo which returns exact name format for nameList
        for i = 1, numMembers do
            local name = GetRaidRosterInfo(i)
            if name then
                -- Store both the full name and short name for lookup. Exact names
                -- always win; a short-name ALIAS must never overwrite an existing
                -- entry — a same-realm member's exact name IS their short name, so
                -- a cross-realm namesake's alias would otherwise clobber it
                -- (last-writer-wins) and misresolve lookups (e.g. flag the player
                -- as hidden because a pinned namesake aliased their key).
                roster[name] = name
                local shortName = name:match("([^%-]+)") or name
                if shortName ~= name and roster[shortName] == nil then
                    roster[shortName] = name  -- Map short name to full roster name
                end
                table.insert(rosterNames, name)
            end
        end
    else
        -- Party mode
        local playerName = GetUnitName("player", true)  -- Returns "Name-Realm"
        roster[playerName] = playerName
        table.insert(rosterNames, playerName)

        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) then
                local fullName = GetUnitName(unit, true)  -- Returns "Name-Realm", avoids secret value taint
                if fullName then
                    local name = fullName:match("([^%-]+)") or fullName
                    roster[fullName] = fullName
                    if roster[name] == nil then
                        roster[name] = fullName  -- Short-name alias (never clobbers an exact entry)
                    end
                    table.insert(rosterNames, fullName)
                end
            end
        end
    end
    
    return roster, rosterNames
end

-- Check if player is in current group, returns the roster name if found
local function IsPlayerInGroup(fullName, roster)
    roster = roster or GetGroupRoster()
    
    -- First check if full name (with realm) is in roster
    if roster[fullName] then
        return roster[fullName]  -- Return the actual roster name
    end
    
    -- For same-realm players, also check short name
    local shortName = fullName:match("([^%-]+)") or fullName
    if roster[shortName] then
        return roster[shortName]  -- Return the actual roster name
    end
    
    return nil
end

-- ============================================================
-- AUTO-POPULATION
-- ============================================================

-- Auto-populate a single pinned set based on its settings
function PinnedFrames:AutoPopulateSet(set, roster)
    if not set then return false end

    local changed = false
    roster = roster or GetGroupRoster()

    -- Ensure player tables exist (defensive against malformed/partial profiles;
    -- the loops below and the auto-add path index set.players directly).
    if not set.manualPlayers then set.manualPlayers = {} end
    if not set.players then set.players = {} end

    local hasAnyAutoFilter = set.autoAddTanks or set.autoAddHealers or set.autoAddDPS

    -- Build lookup of current players in set
    local existingPlayers = {}
    for _, p in ipairs(set.players) do
        local name = p:match("([^%-]+)") or p
        existingPlayers[name] = true
    end

    -- Get group roster with role info
    local numMembers = GetNumGroupMembers()
    if numMembers == 0 then
        -- Solo mode: player role is always DAMAGER (no group role assignment)
        local fullName = GetUnitName("player", true)
        local shortName = fullName and fullName:match("([^%-]+)") or fullName

        -- Auto-add player if DPS filter is on (unless Exclude Self — the solo
        -- player is always self, so excludeSelf means never auto-add here).
        if set.autoAddDPS and not set.excludeSelf and shortName and not existingPlayers[shortName] then
            table.insert(set.players, fullName)
            changed = true
        end

        -- Auto-remove: remove non-manual players whose role (DAMAGER) doesn't match filters
        if hasAnyAutoFilter then
            for i = #set.players, 1, -1 do
                local playerName = set.players[i]
                if not set.manualPlayers[playerName] then
                    -- Solo player is always DAMAGER
                    local pShort = playerName:match("([^%-]+)") or playerName
                    if pShort == shortName then
                        if not set.autoAddDPS or set.excludeSelf then
                            table.remove(set.players, i)
                            changed = true
                        end
                    else
                        -- Not the current player — they left the group
                        -- CleanOfflinePlayers handles this case
                    end
                end
            end
        end

        return changed
    end

    -- Build name → role map for the removal pass
    local rosterRoles = {}  -- shortName -> role
    local isRaid = IsInRaid()

    -- Identify the player for the Exclude Self option (gates auto-add/remove of self).
    local selfFull = GetUnitName("player", true)
    local selfShort = selfFull and selfFull:match("([^%-]+)") or selfFull
    local function IsSelfName(name)
        if not name then return false end
        return name == selfFull or (name:match("([^%-]+)") or name) == selfShort
    end
    for i = 1, numMembers do
        local unit = isRaid and ("raid" .. i) or (i == 1 and "player" or "party" .. (i - 1))
        local fullName = GetUnitName(unit, true)

        if fullName then
            local shortName = fullName:match("([^%-]+)") or fullName
            local role = UnitGroupRolesAssigned(unit)
            if role == "NONE" then role = "DAMAGER" end
            rosterRoles[shortName] = role
            rosterRoles[fullName] = role

            -- Auto-add pass: add players matching enabled role filters
            if not existingPlayers[shortName] then
                local shouldAdd = false
                if set.autoAddTanks and role == "TANK" then
                    shouldAdd = true
                elseif set.autoAddHealers and role == "HEALER" then
                    shouldAdd = true
                elseif set.autoAddDPS and role == "DAMAGER" then
                    shouldAdd = true
                end

                -- Exclude Self: never auto-add the player to this set.
                if shouldAdd and set.excludeSelf and UnitIsUnit(unit, "player") then
                    shouldAdd = false
                end

                if shouldAdd then
                    table.insert(set.players, fullName)
                    existingPlayers[shortName] = true
                    changed = true
                end
            end
        end
    end

    -- Auto-remove pass: remove players whose role no longer matches any filter
    -- Only runs when at least one auto-add filter is active
    if hasAnyAutoFilter then
        for i = #set.players, 1, -1 do
            local playerName = set.players[i]

            -- Never remove manually added players
            if set.manualPlayers[playerName] then
                -- skip
            else
                -- Only evaluate players still in the group
                -- (offline/left players are handled by CleanOfflinePlayers)
                local role = rosterRoles[playerName]
                if role then
                    local matchesFilter = false
                    if set.autoAddTanks and role == "TANK" then
                        matchesFilter = true
                    elseif set.autoAddHealers and role == "HEALER" then
                        matchesFilter = true
                    elseif set.autoAddDPS and role == "DAMAGER" then
                        matchesFilter = true
                    end

                    -- Exclude Self: drop an auto-added self even if the role matches.
                    if set.excludeSelf and IsSelfName(playerName) then matchesFilter = false end

                    if not matchesFilter then
                        table.remove(set.players, i)
                        changed = true
                    end
                end
            end
        end
    end

    return changed
end

-- Clean up offline players from a set
function PinnedFrames:CleanOfflinePlayers(set, roster)
    if not set or set.keepOfflinePlayers then return false end

    -- Fix A — don't prune against a roster that isn't populated yet. On login /
    -- zone-in (raidlogging) the group roster loads asynchronously, so for a brief
    -- window GetNumGroupMembers() is 0 and GetGroupRoster() returns only the player.
    -- Pruning here would wipe every other pinned member before the roster arrives
    -- (the intermittent "I have to re-add them" report). 0 also means genuinely solo
    -- / just-left-the-group — keep the pins for next time rather than wiping them the
    -- instant the group disbands. Real leavers are pruned on the next update once the
    -- roster is non-empty.
    if GetNumGroupMembers() == 0 then return false end

    roster = roster or GetGroupRoster()
    local manual = set.manualPlayers
    local changed = false

    for i = #set.players, 1, -1 do
        local fullName = set.players[i]
        -- Fix B — never prune a manually-added pin. Drag, the +role buttons and
        -- "Add Offline Player" all mark the name in manualPlayers; those are
        -- deliberate picks and must persist. keepOfflinePlayers governs only the
        -- transient AUTO-added members (mirrors the manualPlayers guard the
        -- auto-remove pass in AutoPopulateSet already uses).
        if (not manual or not manual[fullName]) and not IsPlayerInGroup(fullName, roster) then
            table.remove(set.players, i)
            changed = true
        end
    end

    return changed
end

-- Debounced entry point for the recurring event-driven path. In instanced PvP the
-- roster / unit event stream can fire many times per frame; calling ProcessAllSets
-- on each one re-runs the full populate + header rebuild until the per-frame budget
-- is exhausted ("script ran too long"). Coalesce a burst into a single deferred run
-- so that even an opt-in (disableInPvP = false) set stays within budget. One-time /
-- explicit callers (init, reinit, mode change) still call ProcessAllSets directly
-- for immediate effect.
local processAllSetsPending = false
function PinnedFrames:RequestProcessAllSets()
    if processAllSetsPending then return end
    processAllSetsPending = true
    C_Timer.After(0.05, function()
        processAllSetsPending = false
        PinnedFrames:ProcessAllSets()
    end)
end

-- Process all pinned sets for current mode
function PinnedFrames:ProcessAllSets()
    local hlDB = GetPinnedDB()
    if not hlDB or not hlDB.sets then return false end

    -- Arena & battlegrounds: pinned frames are a party/raid feature. In instanced
    -- PvP, GROUP_ROSTER_UPDATE / UNIT_TARGETABLE_CHANGED / UNIT_FACTION fire on
    -- nearly every action, and each re-runs ProcessAllSets -> UpdateAllHeaders ->
    -- ResizeContainer until the watchdog trips ("PinnedFrames.lua:NNNN: script ran
    -- too long"); auto-add also pulls PvP teammates in. OFF by default in PvP: the
    -- set keeps its pre-PvP nameList (members absent -> nothing shows) and
    -- re-populates on leaving. Per-mode `disableInPvP` (nil = default true) gates
    -- it; opting back in is exposed (and throttle-protected) only where that UI
    -- exists, so the live default stays safe.
    if PinnedPvPDormant(hlDB) then
        -- HIDE the pinned frames while dormant, don't just stop processing:
        -- a premade's arena/BG teammates ARE the group, so the frozen
        -- pre-PvP nameList still matches them and the frames kept showing.
        -- Zone-in fires the roster events that reach here before the first
        -- pull, so the out-of-combat guard normally passes; a mid-combat
        -- arrival is picked up by the next out-of-combat call.
        if not self.pvpHidden and not InCombatLockdown() then
            for i = 1, PinnedFrames.MAX_SETS do
                local c = self.containers[i]
                if c then
                    c:Hide()
                    if c.mover then c.mover:Hide() end
                end
                if self.headers[i] then self.headers[i]:Hide() end
                if self.labels[i] then self.labels[i]:Hide() end
            end
            self.pvpHidden = true
        end
        return false
    end

    -- Back out of instanced PvP (or the user opted back in): restore each
    -- set's visibility from its real enabled state (SetEnabled also applies
    -- the solo gate).
    if self.pvpHidden and not InCombatLockdown() then
        self.pvpHidden = nil
        for i = 1, PinnedFrames.MAX_SETS do
            local set = hlDB.sets and hlDB.sets[i]
            if set then self:SetEnabled(i, set.enabled) end
        end
    end

    -- Skip processing if no sets are enabled (avoids unnecessary work)
    local anyEnabled = false
    for i = 1, PinnedFrames.MAX_SETS do
        if hlDB.sets[i] and hlDB.sets[i].enabled then
            anyEnabled = true
            break
        end
    end
    if not anyEnabled then return false end

    local roster = GetGroupRoster()
    local changed = false
    
    for i = 1, PinnedFrames.MAX_SETS do
        local set = hlDB.sets[i]
        if set then
            if self:AutoPopulateSet(set, roster) then
                changed = true
            end
            if self:CleanOfflinePlayers(set, roster) then
                changed = true
            end
        end
    end
    
    if changed then
        -- Membership just changed: drop the hidden-names memo NOW so the
        -- header refresh below (and any main-frame rebuild later this same
        -- frame) filters from post-mutation data.
        self:InvalidateHiddenNames()
        self:UpdateAllHeaders()
    end

    return changed
end

-- Register/unregister boss frames in unitFrameMap based on visibility
function PinnedFrames:UpdateBossFrameMapEntries(setIndex)
    if not DF.unitFrameMap then return end
    local frames = self.bossFrames[setIndex]
    if not frames then return end

    for i = 1, 8 do
        local f = frames[i]
        if f then
            local unit = "boss" .. i
            if f:IsShown() then
                DF.unitFrameMap[unit] = f
                f.dfEventsEnabled = true
            else
                if DF.unitFrameMap[unit] == f then
                    DF.unitFrameMap[unit] = nil
                end
                f.dfEventsEnabled = false
            end
        end
    end
end

-- Called when boss units change (appear, die, change faction)
function PinnedFrames:OnBossFramesChanged()
    if not self.initialized then return end

    for setIndex = 1, PinnedFrames.MAX_SETS do
        local set = GetSetDB(setIndex)
        if set and set.enabled and IsBossSet(set) then
            -- unitFrameMap and frame refresh are safe during combat (purely visual/data)
            self:UpdateBossFrameMapEntries(setIndex)
            self:RefreshChildFrames(setIndex)

            -- Recompact positioning + container resize need out-of-combat
            -- (both call SetPoint/SetSize on secure frames)
            C_Timer.After(0.05, function()
                if not InCombatLockdown() then
                    self:ApplyBossLayout(setIndex)
                    self:ResizeContainer(setIndex)
                end
            end)
        end
    end
end

-- ============================================================
-- ANCHOR CALCULATION
-- ============================================================

-- Get the anchor point for the container based on growth settings
-- This determines which corner the header anchors to AND the container anchors to UIParent
-- Supports START, CENTER, and END for both frameAnchor and columnAnchor
local function GetContainerAnchorPoint(set)
    local horizontal = GetSetGrowDirection(set) == "HORIZONTAL"
    local frameAnchor = set.frameAnchor or "START"
    local columnAnchor = set.columnAnchor or "START"

    -- Map each axis to its WoW anchor component
    local xPart, yPart
    if horizontal then
        -- Horizontal: frameAnchor = left/center/right, columnAnchor = top/center/bottom
        xPart = (frameAnchor == "END") and "RIGHT" or (frameAnchor == "CENTER") and "" or "LEFT"
        yPart = (columnAnchor == "END") and "BOTTOM" or (columnAnchor == "CENTER") and "" or "TOP"
    else
        -- Vertical: frameAnchor = top/center/bottom, columnAnchor = left/center/right
        yPart = (frameAnchor == "END") and "BOTTOM" or (frameAnchor == "CENTER") and "" or "TOP"
        xPart = (columnAnchor == "END") and "RIGHT" or (columnAnchor == "CENTER") and "" or "LEFT"
    end

    local anchor = yPart .. xPart
    if anchor == "" then anchor = "CENTER" end
    return anchor
end

-- A WoW anchor name as fractional offsets from a frame's centre, in frame-size
-- units (LEFT=-0.5, RIGHT=+0.5, TOP=+0.5, BOTTOM=-0.5; centre axes = 0).
local function AnchorFractions(point)
    local fx = (point:find("LEFT") and -0.5) or (point:find("RIGHT") and 0.5) or 0
    local fy = (point:find("TOP") and 0.5) or (point:find("BOTTOM") and -0.5) or 0
    return fx, fy
end

-- pos.anchorTo values that anchor a pinned set to the raid/party FRAMES container
-- (instead of the screen) -> the WoW relative-point corner of that container.
local FRAMES_ANCHOR_POINTS = {
    FRAMES_TOPLEFT     = "TOPLEFT",
    FRAMES_TOP         = "TOP",
    FRAMES_TOPRIGHT    = "TOPRIGHT",
    FRAMES_LEFT        = "LEFT",
    FRAMES_CENTER      = "CENTER",
    FRAMES_RIGHT       = "RIGHT",
    FRAMES_BOTTOMLEFT  = "BOTTOMLEFT",
    FRAMES_BOTTOM      = "BOTTOM",
    FRAMES_BOTTOMRIGHT = "BOTTOMRIGHT",
}

-- The main frames container a pinned set should anchor to: the raid or party
-- container, test variant while test mode is active (the live containers are
-- hidden then). Raid-vs-party is resolved the SAME way GetSetForPosition picks
-- the set (test → DF.raidTestMode, live → IsInRaid) so the anchor target always
-- matches the frames actually on screen. (PositionTargetIsRaid itself is declared
-- later in the file, so its logic is inlined here.) Returns nil if the container
-- doesn't exist yet, so callers fall back to screen anchoring.
local function ResolveFramesAnchorTarget()
    if PinnedFrames.testModeActive then
        local raid = DF.raidTestMode and true or false
        return raid and DF.testRaidContainer or DF.testPartyContainer
    end
    return IsInRaid() and DF.raidContainer or DF.container
end

-- Position a pinned container so its FIRST FRAME lands at a screen spot that is
-- INDEPENDENT of the container's size (frame count). Frames grow from the
-- container's GROWTH corner (GetContainerAnchorPoint), so we anchor THAT corner
-- to the screen — not the container's saved-point corner. The saved `point`
-- stays the screen reference (so coords keep their meaning; nothing jumps), and a
-- half-frame offset reproduces where a point-anchored single frame sits — so a
-- default set doesn't move, yet test (sized to testCount) and live (sized to the
-- visible count) now place the first frame identically. Dragged sets, whose point
-- already equals the growth corner, get a zero offset and render unchanged.
-- frameW/frameH are the set's per-frame size in container-local units.
--
-- When pos.anchorTo is a FRAMES_* value the set is glued to the raid/party
-- container instead of the screen: its growth corner anchors to the chosen
-- container corner with x/y as a fine offset, so the set tracks the frames as
-- they move/resize (incl. in combat — it's a static anchor, no reposition) and
-- pinned/raid alignment stays locked. Falls back to screen if the target
-- container doesn't exist yet.
local function PositionPinnedContainer(container, set, pos, frameW, frameH)
    if not container then return end
    local growth = GetContainerAnchorPoint(set)
    local s = container:GetScale() or 1

    local relPoint = FRAMES_ANCHOR_POINTS[pos and pos.anchorTo or ""]
    if relPoint then
        local target = ResolveFramesAnchorTarget()
        if target and target ~= container then
            -- x/y are screen-space → container units. No half-frame offset: the
            -- growth corner is already size-invariant, and the chosen container
            -- corner is the reference the user picked.
            local x = ((pos and pos.x) or 0) / s
            local y = ((pos and pos.y) or 0) / s
            container:ClearAllPoints()
            container:SetPoint(growth, target, relPoint, x, y)
            return
        end
    end

    local ref = (pos and pos.point) or growth
    local gfx, gfy = AnchorFractions(growth)
    local rfx, rfy = AnchorFractions(ref)
    -- pos.x/y are screen-space (÷scale → container units); the frame offset is
    -- already in container-local units, so it is NOT divided by scale.
    local x = ((pos and pos.x) or 0) / s + (gfx - rfx) * (frameW or 0)
    local y = ((pos and pos.y) or 0) / s + (gfy - rfy) * (frameH or 0)
    container:ClearAllPoints()
    container:SetPoint(growth, UIParent, ref, x, y)
end

-- ============================================================
-- FRAME CREATION
-- ============================================================

-- Create a SecureHandlerStateTemplate handler for this set's boss frames.
-- The handler owns three allocator snippets (onBossShow, onBossHide,
-- resetAllocState) plus a 0.25s GUID-swap poll. Each boss frame has its own
-- SecureHandlerShowHideTemplate helper child; when the per-frame
-- [@bossN,help]show;hide visibility driver flips, the helper's _onshow/_onhide
-- run onBossShow/onBossHide on this handler via RunFor, passing bossIndex.
-- Allocation + SetPoint happens inside the restricted environment, so in-combat
-- repositioning is legal — unlike Lua-side SetPoint on SecureUnitButtonTemplate.
-- Allocator state is stored as persistent frame attributes (slotTaken<N> on
-- the handler, assignedSlot on each boss frame) rather than snippet globals,
-- because restricted snippets get a fresh env per invocation.
function PinnedFrames:CreateBossSecureHandler(setIndex, container, bossFrames)
    if self.bossHandlers[setIndex] then return self.bossHandlers[setIndex] end
    if InCombatLockdown() then return nil end

    -- Handler is parented to the container and anchored to fill it, so
    -- positions computed relative to the handler equal positions relative
    -- to the container. The restricted environment only accepts SecureHandler*
    -- frames as SetPoint targets, so we can't anchor to the plain container
    -- directly — we anchor to the handler instead.
    local handler = CreateFrame("Frame",
        "DandersBossPositionHandler" .. setIndex,
        container,
        "SecureHandlerStateTemplate")
    handler:SetAllPoints(container)
    handler:Hide()

    -- Frame refs for snippets: each boss frame addressable via
    -- self:GetFrameRef("bossN"). Container ref isn't needed now that we
    -- anchor to the handler.
    for i = 1, 8 do
        local f = bossFrames[i]
        if f then
            SecureHandlerSetFrameRef(handler, "boss" .. i, f)
        end
    end

    -- Allocator state lives in persistent attributes because restricted-env
    -- snippets get a fresh environment per invocation, so snippet-scoped
    -- globals don't survive RunAttribute calls. We use:
    --   handler attr "slotTaken<N>" (boolean) — which slots are in use
    --   frame attr   "assignedSlot" (number)  — which slot this frame holds
    -- Both auto-nil on first read, which correctly means "untaken/unassigned".

    -- Pin the bossN frame to the lowest-numbered free slot. Re-uses existing
    -- assignment if already set. Called from each boss frame's helper _onshow.
    handler:SetAttribute("onBossShow", [[
        local bossIndex = ...
        local f = self:GetFrameRef("boss" .. bossIndex)
        if not f then return end

        local slot = tonumber(f:GetAttribute("assignedSlot"))
        if not slot then
            for i = 1, 8 do
                if not self:GetAttribute("slotTaken" .. i) then
                    slot = i
                    break
                end
            end
            if not slot then return end
            self:SetAttribute("slotTaken" .. slot, true)
            f:SetAttribute("assignedSlot", slot)
        end

        local anchor = self:GetAttribute("anchor") or "TOPLEFT"
        local x = tonumber(self:GetAttribute("slot" .. slot .. "x")) or 0
        local y = tonumber(self:GetAttribute("slot" .. slot .. "y")) or 0
        f:ClearAllPoints()
        f:SetPoint(anchor, self, anchor, x, y)
    ]])

    -- Release the slot on hide so future shows can reuse it. Other frames
    -- keep their slot assignments (no compaction — matches Targeted List rules).
    handler:SetAttribute("onBossHide", [[
        local bossIndex = ...
        local f = self:GetFrameRef("boss" .. bossIndex)
        if not f then return end

        local slot = tonumber(f:GetAttribute("assignedSlot"))
        if slot then
            self:SetAttribute("slotTaken" .. slot, false)
            f:SetAttribute("assignedSlot", nil)
        end
    ]])

    -- Invoked from Lua at combat end to wipe all slot assignments. Next
    -- onBossShow cycle starts fresh from slot 1.
    handler:SetAttribute("resetAllocState", [[
        for i = 1, 8 do
            self:SetAttribute("slotTaken" .. i, false)
            local f = self:GetFrameRef("boss" .. i)
            if f then f:SetAttribute("assignedSlot", nil) end
        end
    ]])

    -- GUID-swap poll. Midnight 12.0 can silently reassign bossN to a new NPC
    -- without firing UNIT_TARGETABLE_CHANGED / UNIT_FACTION (especially for
    -- boss6-8). Poll every 0.25s and refresh any shown frame whose unit GUID
    -- no longer matches what we cached at OnShow time. Matches Cell's pattern.
    handler.dfBossGuidElapsed = 0
    handler:SetScript("OnUpdate", function(self, elapsed)
        self.dfBossGuidElapsed = (self.dfBossGuidElapsed or 0) + elapsed
        if self.dfBossGuidElapsed < 0.25 then return end
        self.dfBossGuidElapsed = 0

        local frames = PinnedFrames.bossFrames[setIndex]
        if not frames then return end
        for i = 1, 8 do
            local f = frames[i]
            if f and f:IsShown() and f.unit then
                local guid = UnitGUID(f.unit)
                if guid and guid ~= f.dfLastBossGUID then
                    f.dfLastBossGUID = guid
                    if DF.ScanUnitFull then DF:ScanUnitFull(f.unit) end
                    if DF.FullFrameRefresh then DF:FullFrameRefresh(f) end
                end
            end
        end
    end)

    self.bossHandlers[setIndex] = handler

    DF:Debug("PINNED", "Set %d created secure position handler", setIndex)

    return handler
end

-- Push current layout settings into the secure handler's attributes.
-- Must run out of combat (SetAttribute is restricted on secure frames in combat).
function PinnedFrames:UpdateBossHandlerConfig(setIndex)
    local handler = self.bossHandlers[setIndex]
    local set = GetSetDB(setIndex)
    if not handler or not set then return end
    if InCombatLockdown() then return end

    local db = GetPinnedModeDB()
    if not db then return end

    local frameWidth, frameHeight = GetSetFrameSize(set, db)
    local hSpacing, vSpacing = GetSetSpacing(set, db)
    local unitsPerRow   = set.unitsPerRow or 5
    local horizontal    = (GetSetGrowDirection(set) == "HORIZONTAL")
    local frameAnchor   = set.frameAnchor or "START"
    local columnAnchor  = set.columnAnchor or "START"
    local anchor        = GetContainerAnchorPoint(set)

    handler:SetAttribute("anchor", anchor)

    -- Size each boss frame to the current mode. SetSize on secure frames is
    -- combat-restricted; we already bailed above on InCombatLockdown.
    local borderDB = GetSetBorderDB(set, GetSetBaselineDB(set, db))
    local effDB = BuildPinnedEffDB(db, set.hideAuras, set.hideIcons)
    local frames = self.bossFrames[setIndex]
    if frames then
        for i = 1, 8 do
            local f = frames[i]
            if f then
                f.dfPinnedWidth, f.dfPinnedHeight = frameWidth, frameHeight
                f.dfPinnedBorderDB = borderDB
                f.dfPinnedEffDB = effDB
                f.dfPinnedHideAuras = set.hideAuras
                -- Per-set Aura/Text Designer preset (nil = inherit the mode's preset;
                -- the resolver falls back to FrameMode when the stamp is nil).
                f.dfAuraPresetOverride = set.auraDesignerPreset
                f.dfTextPresetOverride = set.textDesignerPreset
                f:SetSize(frameWidth, frameHeight)
                f.isRaidFrame = IsInRaid()
            end
        end
    end

    -- Precompute (x, y) for each of the 8 slots. Slot 1 lives at the
    -- container anchor; subsequent slots offset row-major by (xStep, yStep)
    -- whose direction is dictated by frameAnchor/columnAnchor.
    local xStep = frameWidth + hSpacing
    local yStep = frameHeight + vSpacing

    for slot = 1, 8 do
        local slotIndex = slot - 1
        local row = math.floor(slotIndex / unitsPerRow)
        local col = slotIndex - row * unitsPerRow

        local xOff, yOff
        if horizontal then
            if frameAnchor  == "END" then xOff = -col * xStep else xOff =  col * xStep end
            if columnAnchor == "END" then yOff =  row * yStep else yOff = -row * yStep end
        else
            if frameAnchor  == "END" then yOff =  col * yStep else yOff = -col * yStep end
            if columnAnchor == "END" then xOff = -row * xStep else xOff =  row * xStep end
        end

        handler:SetAttribute("slot" .. slot .. "x", xOff)
        handler:SetAttribute("slot" .. slot .. "y", yOff)
    end
end


-- Create 8 standalone SecureUnitButtonTemplate frames for a boss-mode set
-- Parented to the container; unit attributes are hardcoded to boss1..boss8
function PinnedFrames:CreateBossFrames(setIndex, container)
    if self.bossFrames[setIndex] then return end
    if InCombatLockdown() then
        DF:DebugWarn("PINNED", "CreateBossFrames: in combat, cannot create frames")
        return
    end

    local modeSuffix = IsInRaid() and "Raid" or "Party"
    local frames = {}

    for i = 1, 8 do
        local name = "DandersPinnedBoss" .. setIndex .. modeSuffix .. "_" .. i
        local frame = CreateFrame(
            "Button",
            name,
            container,
            "DandersUnitButtonTemplate,SecureUnitButtonTemplate"
        )
        frame:SetAttribute("unit", "boss" .. i)
        frame.unit = "boss" .. i
        frame.isPinnedFrame = true
        frame.isPinnedBossFrame = true
        frame.bossIndex = i

        if DF.InitializeHeaderChild then
            DF:InitializeHeaderChild(frame)
        end

        -- Per-frame visibility state driver: shows the frame when bossN
        -- exists AND is friendly. A SecureHandlerShowHideTemplate helper
        -- child (created below) invokes the shared handler's
        -- onBossShow/onBossHide snippets whenever this flips.
        RegisterStateDriver(frame, "visibility", "[@boss" .. i .. ",help]show;hide")

        -- Self-sufficient event system (ElvUI/oUF-style).
        -- Register all unit-specific events directly on the frame with
        -- `RegisterUnitEvent` so they're filtered at the C level — the handler
        -- only fires when the event is for this frame's boss unit. No dispatcher
        -- lookup needed. Each event routes to the appropriate DF update
        -- function on `self`. This avoids "dispatcher forgot boss frames"
        -- bugs because each frame listens for what it needs directly.
        local bossUnit = "boss" .. i
        frame:RegisterUnitEvent("UNIT_HEALTH", bossUnit)
        frame:RegisterUnitEvent("UNIT_MAXHEALTH", bossUnit)
        frame:RegisterUnitEvent("UNIT_MAX_HEALTH_MODIFIERS_CHANGED", bossUnit)
        frame:RegisterUnitEvent("UNIT_POWER_UPDATE", bossUnit)
        frame:RegisterUnitEvent("UNIT_MAXPOWER", bossUnit)
        frame:RegisterUnitEvent("UNIT_DISPLAYPOWER", bossUnit)
        frame:RegisterUnitEvent("UNIT_AURA", bossUnit)
        frame:RegisterUnitEvent("UNIT_NAME_UPDATE", bossUnit)
        frame:RegisterUnitEvent("UNIT_FACTION", bossUnit)
        frame:RegisterUnitEvent("UNIT_ABSORB_AMOUNT_CHANGED", bossUnit)
        frame:RegisterUnitEvent("UNIT_HEAL_ABSORB_AMOUNT_CHANGED", bossUnit)
        frame:RegisterUnitEvent("UNIT_HEAL_PREDICTION", bossUnit)

        frame:SetScript("OnEvent", function(self, event, unit, updateInfo)
            -- Skip work if hidden. IsVisible (not IsShown): a DISABLED boss
            -- set's container is hidden but the state driver still flips each
            -- frame's own shown flag during encounters — IsShown would pass and
            -- burn full aura scans on every boss UNIT_AURA for a feature the
            -- user turned off.
            if not self:IsVisible() then return end

            if event == "UNIT_HEALTH"
                    or event == "UNIT_MAXHEALTH"
                    or event == "UNIT_MAX_HEALTH_MODIFIERS_CHANGED" then
                if DF.UpdateHealthFast then DF:UpdateHealthFast(self) end
                if event == "UNIT_MAX_HEALTH_MODIFIERS_CHANGED" and DF.UpdateReducedMaxHealth then
                    DF:UpdateReducedMaxHealth(self)
                    -- TD: hp_max_reduction refresh for pinned frames. Only on this
                    -- event — the central dispatcher already covers pinned frames
                    -- for UNIT_HEALTH/MAXHEALTH, but it doesn't handle this one.
                    if DF.UpdateTextDesigner then DF:UpdateTextDesigner(self, "health") end
                end

            elseif event == "UNIT_POWER_UPDATE"
                    or event == "UNIT_MAXPOWER"
                    or event == "UNIT_DISPLAYPOWER" then
                if DF.UpdatePower then DF:UpdatePower(self) end

            elseif event == "UNIT_AURA" then
                -- Populate aura cache (same logic as directModeSubscriber)
                local cache = DF.AuraCache and DF.AuraCache[unit]
                local needsFull = not updateInfo or updateInfo.isFullUpdate
                    or not cache or not cache.hasFullScan
                if needsFull then
                    if DF.ScanUnitFull then DF:ScanUnitFull(unit) end
                else
                    if DF.ApplyAuraDelta and not DF:ApplyAuraDelta(unit, updateInfo) then
                        if DF.ScanUnitFull then DF:ScanUnitFull(unit) end
                    end
                end
                -- Trigger the full filtered aura update pipeline (same path as
                -- party/raid frames — applies filters, limits, dedup, etc.)
                if DF.TriggerAuraUpdateForUnit then
                    DF:TriggerAuraUpdateForUnit(unit)
                end

            elseif event == "UNIT_NAME_UPDATE" then
                if DF.UpdateName then DF:UpdateName(self) end

            elseif event == "UNIT_FACTION" then
                -- Faction change can flip friendly→hostile — full refresh
                -- (state driver will then hide the frame if no longer friendly)
                if DF.FullFrameRefresh then DF:FullFrameRefresh(self) end

            elseif event == "UNIT_ABSORB_AMOUNT_CHANGED" then
                if DF.UpdateAbsorb then DF:UpdateAbsorb(self) end

            elseif event == "UNIT_HEAL_ABSORB_AMOUNT_CHANGED" then
                if DF.UpdateHealAbsorb then DF:UpdateHealAbsorb(self) end

            elseif event == "UNIT_HEAL_PREDICTION" then
                if DF.UpdateHealPrediction then DF:UpdateHealPrediction(self) end
            end
        end)

        -- OnShow hook: when state driver makes this frame visible, register in
        -- unitFrameMap synchronously so UNIT_HEALTH/UNIT_AURA/etc. events route
        -- here immediately (otherwise the health bar won't update until
        -- OnBossFramesChanged's deferred registration fires).
        frame:HookScript("OnShow", function(self)
            if DF.unitFrameMap and self.unit then
                DF.unitFrameMap[self.unit] = self
                self.dfEventsEnabled = true
                self.dfLastBossGUID = UnitGUID(self.unit)
            end
            C_Timer.After(0.1, function()
                if self and self.unit and self:IsVisible() then
                    -- Populate aura cache for this unit if not yet done
                    if DF.ScanUnitFull then DF:ScanUnitFull(self.unit) end
                    -- Full refresh ensures Aura Designer BeginFrame/EnsureFrameState runs
                    if DF.FullFrameRefresh then DF:FullFrameRefresh(self) end
                    self.dfLastBossGUID = UnitGUID(self.unit)
                end
            end)
        end)

        -- OnHide hook: clear Aura Designer state so the next OnShow reinitializes
        -- from scratch. Without this, when a boss slot is reassigned to a new NPC,
        -- the stale dfAD_* pools cause AD indicators to not apply on first render.
        -- Also remove from unitFrameMap so events don't route to a hidden frame.
        frame:HookScript("OnHide", function(self)
            if DF.unitFrameMap and self.unit and DF.unitFrameMap[self.unit] == self then
                DF.unitFrameMap[self.unit] = nil
            end
            self.dfEventsEnabled = false

            -- Hide all AD indicator widgets before releasing the pool tables.
            -- Without this, icons/squares/bars stay parented to the frame with
            -- IsShown() == true, and reappear from the previous NPC when the
            -- boss slot re-fills with a new unit.
            if DF.AuraDesigner and DF.AuraDesigner.Indicators then
                DF.AuraDesigner.Indicators:HideAll(self)
            end

            self.dfAD = nil
            self.dfAD_icons = nil
            self.dfAD_squares = nil
            self.dfAD_bars = nil
            self.dfAD_configVersion = nil
            self.dfAD_activeInstanceIDs = nil
            self.dfLastBossGUID = nil
        end)

        -- Secure helper that fires _onshow/_onhide inside the restricted
        -- environment whenever this boss frame's visibility state driver
        -- flips. Lets us run slot-allocator/reposition work (which calls
        -- SetPoint on SecureUnitButtonTemplate frames) safely in combat.
        local helper = CreateFrame("Frame", nil, frame, "SecureHandlerShowHideTemplate")
        helper:SetAttribute("bossIndex", i)
        helper:SetAttribute("_onshow", [[
            local h = self:GetFrameRef("bossHandler")
            if h then
                self:RunFor(h, h:GetAttribute("onBossShow"),
                    self:GetAttribute("bossIndex"))
            end
        ]])
        helper:SetAttribute("_onhide", [[
            local h = self:GetFrameRef("bossHandler")
            if h then
                self:RunFor(h, h:GetAttribute("onBossHide"),
                    self:GetAttribute("bossIndex"))
            end
        ]])
        frame.bossHelper = helper

        -- Register with click-casting system
        if ClickCastFrames then
            ClickCastFrames[frame] = true
        end

        frame:Hide()
        frames[i] = frame
    end

    self.bossFrames[setIndex] = frames

    -- Secure handler that repositions these frames compactly, even in combat
    self:CreateBossSecureHandler(setIndex, container, frames)

    -- Wire each helper's bossHandler frame ref now that the handler exists.
    local handler = self.bossHandlers[setIndex]
    if handler then
        for i = 1, 8 do
            local f = frames[i]
            if f and f.bossHelper then
                SecureHandlerSetFrameRef(f.bossHelper, "bossHandler", handler)
            end
        end
    end

    DF:Debug("PINNED", "Set %d created 8 boss frames", setIndex)
end

function PinnedFrames:CreateSetFrames(setIndex)
    if self.containers[setIndex] then return end
    
    -- CRITICAL: Cannot create frames during combat
    if InCombatLockdown() then
        DF:DebugWarn("PINNED", "CreateSetFrames: in combat, cannot create frames")
        return
    end
    
    local set = GetSetDB(setIndex)
    if not set then return end

    local modeSuffix = IsInRaid() and "Raid" or "Party"
    
    -- Create container (movable anchor frame)
    local container = CreateFrame("Frame", "DandersPinned" .. setIndex .. modeSuffix .. "Container", UIParent)
    container:SetSize(200, 100)  -- Will be resized based on content
    container:SetFrameStrata("MEDIUM")
    container:SetClampedToScreen(true)
    
    -- Position from saved settings, pinning the growth corner so size never shifts
    -- the first frame (see PositionPinnedContainer).
    local containerAnchor = GetContainerAnchorPoint(set)
    local pos = set.position or { point = containerAnchor, x = 0, y = 200 * (setIndex == 1 and 1 or -1) }
    local initScale = GetSetScale(set)
    container:SetScale(initScale)
    local initW, initH = GetSetFrameSize(set, GetPinnedModeDB())
    PositionPinnedContainer(container, set, pos, initW, initH)
    
    -- Make draggable when unlocked
    container:SetMovable(true)
    container:EnableMouse(false)  -- Don't capture mouse on container - mover handles dragging

    -- Mode-aware colors: raid = orange, party = purple-blue
    local colors = GetModeColors(IsInRaid())

    -- Visual background when unlocked (for visibility)
    container.bg = container:CreateTexture(nil, "BACKGROUND")
    container.bg:SetAllPoints()
    container.bg:SetColorTexture(unpack(colors.containerBg))
    container.bg:SetShown(self.moversShown)

    -- Border when unlocked
    container.border = CreateFrame("Frame", nil, container, "BackdropTemplate")
    container.border:SetAllPoints()
    container.border:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    container.border:SetBackdropBorderColor(unpack(colors.containerBorder))
    container.border:SetShown(self.moversShown)

    -- Mover frame (parented to UIParent for scale independence)
    local mover = CreateFrame("Frame", "DandersPinned" .. setIndex .. "Mover", UIParent)
    mover:SetSize(140, 16)
    mover:SetFrameStrata("HIGH")
    mover:SetPoint("BOTTOM", container, "TOP", 0, 2)

    -- Mover background
    mover.bg = mover:CreateTexture(nil, "BACKGROUND")
    mover.bg:SetAllPoints()
    mover.bg:SetColorTexture(unpack(colors.moverBg))

    -- Mover border (1px)
    mover.border = mover:CreateTexture(nil, "BORDER")
    mover.border:SetAllPoints()
    mover.border:SetColorTexture(unpack(colors.moverBorder))
    local moverInner = mover:CreateTexture(nil, "ARTWORK")
    moverInner:SetPoint("TOPLEFT", 1, -1)
    moverInner:SetPoint("BOTTOMRIGHT", -1, 1)
    moverInner:SetColorTexture(unpack(colors.moverBg))

    -- Mover text
    mover.text = mover:CreateFontString(nil, "OVERLAY")
    DF.GUI:SetSettingsFont(mover.text, 10, "")
    mover.text:SetPoint("CENTER")
    mover.text:SetText(PinnedSetLabel(set, setIndex, IsInRaid()))
    mover.text:SetTextColor(unpack(colors.moverText))

    -- Hover highlight + tooltip + active-state styling (reads as clickable).
    StylePinnedHandle(mover, mover.border, moverInner, mover.text, colors)

    -- Mover is the drag handle
    mover:EnableMouse(true)
    mover:RegisterForDrag("LeftButton")

    -- Clicking (or finishing a drag on) this set's mover points the shared
    -- position panel at this set, so the X/Y nudge controls drive it.
    mover:HookScript("OnMouseUp", function(_, button)
        if button == "LeftButton" and DF.SetPositionPanelMode then
            DF.positionPanelPinnedSet = setIndex
            DF:SetPositionPanelMode("pinned")
        end
    end)

    -- Track starting mouse and container position (+ the drag's anchor reference
    -- and frame size, captured once so OnUpdate/OnDragStop stay consistent).
    local startMouseX, startMouseY, startPosX, startPosY, dragRef, dragW, dragH, dragAnchorTo

    mover:SetScript("OnDragStart", function(self)
        -- Re-resolve the set EVERY drag: the closure's `set` upvalue is bound at
        -- CreateSetFrames time, but a profile switch swaps the underlying table
        -- without recreating the frames — stale lock state would gate the drag
        -- and (worse) OnDragStop would save the position into the DEAD profile.
        local liveSet = GetSetDB(setIndex)
        -- Drag is only valid while globally unlocked and out of combat (the
        -- container can be a secure header parent — repositioning it taints).
        if not liveSet or not PinnedFrames.moversShown or InCombatLockdown() then return end

        -- Point the position panel at this set so it tracks the drag live.
        if DF.SetPositionPanelMode then
            DF.positionPanelPinnedSet = setIndex
            DF:SetPositionPanelMode("pinned")
        end

        -- Keep the set's existing anchor reference (pos.point) so coords stay in
        -- the same space; PositionPinnedContainer pins the growth corner from it.
        dragRef = (liveSet.position and liveSet.position.point) or GetContainerAnchorPoint(liveSet)
        -- Preserve the frames-anchor mode across the drag (rebuilt fresh below).
        dragAnchorTo = liveSet.position and liveSet.position.anchorTo
        dragW, dragH = GetSetFrameSize(liveSet, GetPinnedModeDB())

        -- Get starting mouse position in screen coordinates
        local uiScale = UIParent:GetEffectiveScale()
        startMouseX, startMouseY = GetCursorPosition()
        startMouseX = startMouseX / uiScale
        startMouseY = startMouseY / uiScale

        -- Get current container position
        local pos = liveSet.position or { x = 0, y = 0 }
        startPosX = pos.x or 0
        startPosY = pos.y or 0

        self:SetScript("OnUpdate", function()
            local mx, my = GetCursorPosition()
            local ps = UIParent:GetEffectiveScale()
            mx = mx / ps
            my = my / ps

            -- Delta in UIParent space — add directly to logical start position
            local deltaX = mx - startMouseX
            local deltaY = my - startMouseY
            local newX = startPosX + deltaX
            local newY = startPosY + deltaY

            -- Snap to grid when pinned snap is enabled (its own flag, default off).
            local sdb = DF.GetDB and DF:GetDB()
            if sdb and sdb.pinnedSnapToGrid and DF.SnapToGrid then
                newX, newY = DF:SnapToGrid(newX, newY)
            end

            -- Track the live drag in the DB + panel so the X/Y readouts update.
            liveSet.position = { point = dragRef, x = newX, y = newY, anchorTo = dragAnchorTo }
            PositionPinnedContainer(container, liveSet, liveSet.position, dragW, dragH)
            if DF.UpdatePositionPanel then DF:UpdatePositionPanel() end
        end)
    end)

    mover:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        if not startMouseX then return end

        -- Re-resolve (see OnDragStart): write the position into the LIVE set.
        local liveSet = GetSetDB(setIndex)
        if not liveSet then return end

        -- Keep the captured anchor reference (pos.point) from drag start.
        local anchor = dragRef or GetContainerAnchorPoint(liveSet)

        -- Get final position from mouse delta
        local uiScale = UIParent:GetEffectiveScale()
        local mx, my = GetCursorPosition()
        mx = mx / uiScale
        my = my / uiScale

        local deltaX = mx - startMouseX
        local deltaY = my - startMouseY
        local finalX = startPosX + deltaX
        local finalY = startPosY + deltaY

        -- Snap to grid when pinned snap is enabled (its own flag, default off).
        local sdb = DF.GetDB and DF:GetDB()
        if sdb and sdb.pinnedSnapToGrid and DF.SnapToGrid then
            finalX, finalY = DF:SnapToGrid(finalX, finalY)
        end

        -- Save logical position (unscaled)
        liveSet.position = { point = anchor, x = finalX, y = finalY, anchorTo = dragAnchorTo }

        -- RAID ONLY: when an auto layout is active, GetSetDB() returns a deep copy
        -- of _realRaidDB.pinnedFrames, so the write above goes to that throwaway copy
        -- — mirror through to the real raid DB so it survives overlay rebuilds. Party
        -- sets ARE the real table (liveSet), and _realRaidDB.sets[setIndex] is the
        -- RAID set, so mirroring in party mode would corrupt the raid set's position.
        if IsInRaid() then
            local realSet = DF._realRaidDB
                and DF._realRaidDB.pinnedFrames
                and DF._realRaidDB.pinnedFrames.sets
                and DF._realRaidDB.pinnedFrames.sets[setIndex]
            if realSet then
                realSet.position = { point = anchor, x = finalX, y = finalY, anchorTo = dragAnchorTo }
            end
        end

        PositionPinnedContainer(container, liveSet, liveSet.position, dragW, dragH)

        if DF.UpdatePositionPanel then DF:UpdatePositionPanel() end

        -- If Test Mode is active, re-sync test container(s) to the new position.
        -- The drag updated the current mode's set.position; the test container
        -- may or may not be using this mode's config, but refreshing is cheap
        -- and ensures alignment either way.
        if PinnedFrames.testModeActive and PinnedFrames.ExitTestMode then
            PinnedFrames:ExitTestMode()
            PinnedFrames:EnterTestMode()
        end
    end)
    
    -- Mover shows when globally unlocked AND the set is enabled
    mover:SetShown(set.enabled and self.moversShown)
    container.mover = mover
    
    -- Label (parented to UIParent for scale independence)
    local label = UIParent:CreateFontString("DandersPinned" .. setIndex .. "Label", "OVERLAY")
    DF.GUI:SetSettingsFont(label, 12, "")
    label:SetPoint("BOTTOM", container, "TOP", 0, 2)
    local labelText = set.name
    if not labelText or labelText == "" then
        labelText = "Pinned " .. setIndex
    end
    label:SetText(labelText)
    label:SetTextColor(0.8, 0.8, 1.0)
    -- Only show label if set is enabled AND showLabel is true
    label:SetShown(set.enabled and set.showLabel)
    
    self.containers[setIndex] = container
    self.labels[setIndex] = label

    if IsBossSet(set) then
        -- BOSS MODE: create 8 standalone boss frames instead of a header
        self:CreateBossFrames(setIndex, container)
        self:ApplyBossLayout(setIndex)

        -- Honor enabled state
        if set.enabled then
            container:Show()
            if label then label:SetShown(set.showLabel) end
            if container.mover then container.mover:SetShown(self.moversShown) end
        else
            container:Hide()
            if label then label:Hide() end
            if container.mover then container.mover:Hide() end
        end
        return
    end

    -- Create SecureGroupHeaderTemplate
    local header = CreateFrame("Frame", "DandersPinned" .. setIndex .. modeSuffix .. "Header", container, "SecureGroupHeaderTemplate")
    
    -- Show all unit types - nameList controls which are visible
    header:SetAttribute("showPlayer", true)
    header:SetAttribute("showParty", true)
    header:SetAttribute("showRaid", true)
    header:SetAttribute("showSolo", true)
    
    -- Use same template as main frames
    header:SetAttribute("template", "DandersUnitButtonTemplate")
    
    -- Initial layout
    self:ApplyLayoutSettings(setIndex)
    
    -- Anchor header to container
    header:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    
    self.headers[setIndex] = header
    
    -- STARTINGINDEX TRICK - Force create frames upfront
    -- Must happen BEFORE setting nameList/sortMethod
    -- Use groupFilter temporarily to force frame creation
    header:SetAttribute("groupFilter", "1,2,3,4,5,6,7,8")  -- All groups
    header:SetAttribute("startingIndex", -39)  -- Creates up to 40 frames
    header:Show()
    header:SetAttribute("startingIndex", 1)    -- Reset to normal operation
    
    -- Now switch to nameList mode
    header:SetAttribute("sortMethod", "NAMELIST")
    header:SetAttribute("groupFilter", nil)  -- Clear groupFilter, nameList takes over
    
    -- Initial nameList (may be empty, that's ok now - frames are created)
    self:UpdateHeaderNameList(setIndex)
    
    -- Count created children for debug log (fast — 40 attribute lookups)
    local childCount = 0
    for i = 1, 40 do
        if header:GetAttribute("child" .. i) then childCount = childCount + 1 end
    end
    DF:Debug("PINNED", "Set %d created %d child frames", setIndex, childCount)
    
    -- Show/hide based on enabled state
    if set.enabled then
        container:Show()
        header:Show()
        -- Label and mover visibility based on their settings
        if label then
            label:SetShown(set.showLabel)
        end
        if container.mover then
            container.mover:SetShown(self.moversShown)
        end
    else
        container:Hide()
        header:Hide()
        -- Hide label and mover when disabled
        if label then
            label:Hide()
        end
        if container.mover then
            container.mover:Hide()
        end
        -- Unregister events from child frames (synchronous - no delays for combat safety)
        if DF.SetHeaderChildrenEventsEnabled then
            DF:SetHeaderChildrenEventsEnabled(header, false)
        end
    end
end

-- ============================================================
-- HEADER UPDATES
-- ============================================================

-- Update the nameList for a header
function PinnedFrames:UpdateHeaderNameList(setIndex)
    local header = self.headers[setIndex]
    local set = GetSetDB(setIndex)
    
    if not header or not set then return end
    
    -- Get roster (maps stored names to actual GetRaidRosterInfo names)
    local roster = GetGroupRoster()
    local validRosterNames = {}
    
    -- For each player in set, find their actual roster name
    for _, storedName in ipairs(set.players) do
        local rosterName = IsPlayerInGroup(storedName, roster)
        if rosterName then
            -- Use the actual roster name (what GetRaidRosterInfo returns)
            table.insert(validRosterNames, rosterName)
        end
    end
    
    local nameList = BuildNameList(validRosterNames)
    
    DF:Debug("PINNED", "Set %d updating nameList (%d players in set, %d valid, list=%s)",
        setIndex, #set.players, #validRosterNames,
        nameList ~= "" and nameList or "(empty)")
    
    -- Only update if not in combat
    if InCombatLockdown() then
        self.pendingNameListUpdate = self.pendingNameListUpdate or {}
        self.pendingNameListUpdate[setIndex] = true
        return
    end
    
    -- Clear ALL filtering/grouping attributes - nameList acts as the filter
    -- (Same approach as flat raid mode in Headers.lua)
    header:SetAttribute("groupBy", nil)
    header:SetAttribute("groupingOrder", nil)
    header:SetAttribute("groupFilter", nil)  -- MUST clear this for nameList to work!
    header:SetAttribute("roleFilter", nil)
    header:SetAttribute("strictFiltering", nil)
    
    -- Set nameList and sortMethod
    header:SetAttribute("nameList", nameList)
    header:SetAttribute("sortMethod", "NAMELIST")
    
    -- Force header to re-layout by toggling visibility
    if set.enabled then
        header:Hide()
        header:Show()
    end
    
    -- Resize container after layout change
    self:ResizeContainer(setIndex)
    
    -- Force visual refresh on all visible children after nameList change
    -- OnAttributeChanged handles unit reassignment, but a small delay ensures
    -- the header has finished re-laying out children before we refresh visuals
    C_Timer.After(0.1, function()
        if header and set.enabled then
            PinnedFrames:RefreshChildFrames(setIndex)
        end
    end)

    -- #78: members of a "Hide from Main Frames" set must also be dropped from the
    -- MAIN party/raid headers — rebuild them so they pick up / release the name.
    -- (We're already past the combat early-return above.) Auto-add coincides with
    -- GROUP_ROSTER_UPDATE which rebuilds main anyway; this covers manual add/remove.
    if set.hideFromMainFrames and DF.RefreshMainFrameSorting then
        self:InvalidateHiddenNames()  -- membership may have just changed
        DF:RefreshMainFrameSorting()
    end
end

-- #78: the set of (realm-qualified) roster names that belong to a pinned set with
-- "Hide from Main Frames" on, in the CURRENT mode. The main party/raid nameList
-- build (DF:BuildSortedNameList) filters these out so a pinned member doesn't also
-- show in the main frames. Resolves stored names → actual roster names exactly like
-- UpdateHeaderNameList, so the keys match the main members' names directly. Returns
-- nil when nothing is hidden (cheap no-op for the common case).
local function ComputeHiddenNames()
    if PinnedFrames.testModeActive then return nil end  -- never hide real units in test
    local hlDB = GetPinnedDB()
    if not hlDB or not hlDB.sets then return nil end
    -- Pinned processing is dormant in instanced PvP by default — its (frozen)
    -- members must not keep filtering the main frames there.
    if PinnedPvPDormant(hlDB) then return nil end
    local result, roster
    for i = 1, PinnedFrames.MAX_SETS do
        local set = hlDB.sets[i]
        -- PinnedSoloAllowed: a set whose container is hidden by the solo gate
        -- must not filter either — otherwise a solo player pinned into a hiding
        -- set (e.g. auto-add DPS) loses their MAIN frame while the pinned copy
        -- is hidden too, leaving no frame at all.
        if set and set.enabled and set.hideFromMainFrames and not IsBossSet(set)
           and PinnedSoloAllowed(set)
           and set.players and #set.players > 0 then
            roster = roster or GetGroupRoster()
            for _, storedName in ipairs(set.players) do
                local rosterName = IsPlayerInGroup(storedName, roster)
                if rosterName then
                    result = result or {}
                    result[rosterName] = true
                end
            end
        end
    end
    -- The player IS hideable when pinned into a hiding set. Flag them explicitly
    -- via the roster rather than a name match — the main PARTY builder names the
    -- player UnitName("player") (no realm) while the pinned roster uses
    -- GetUnitName("player", true), so a plain name-key lookup can miss them.
    if result then
        roster = roster or GetGroupRoster()
        local selfRoster = IsPlayerInGroup(GetUnitName("player", true), roster)
        if selfRoster and result[selfRoster] then
            result.__hidePlayer = true
        end
    end
    return result
end

-- Per-frame memo. A single raid sort asks for this once per group (1 + up to 8
-- calls via BuildSortedNameList) and the party/flat paths ask twice; each compute
-- rebuilds the whole roster (GetGroupRoster) + an IsPlayerInGroup pass. The result
-- is stable within a frame (roster + pinned config don't change mid-frame, and
-- pinned-set mutations run debounced in a later frame), so cache it and clear on
-- the next tick — collapsing the per-group rescans into one without threading the
-- result through the sort signatures.
local hiddenNamesCache
local hiddenNamesValid = false
function DF:GetPinnedHiddenNames()
    if hiddenNamesValid then return hiddenNamesCache end
    local result = ComputeHiddenNames()
    hiddenNamesCache = result
    hiddenNamesValid = true
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function() hiddenNamesValid = false; hiddenNamesCache = nil end)
    end
    return result
end

-- Explicit invalidation for set mutations. The next-frame expiry above is only
-- a backstop: at low FPS the roster-throttle sort (which primes the cache) and
-- the debounced ProcessAllSets (which mutates set.players) can land in the SAME
-- frame, so a mutation must drop the memo immediately or the following
-- main-frame rebuild filters from pre-mutation data.
function PinnedFrames:InvalidateHiddenNames()
    hiddenNamesValid = false
    hiddenNamesCache = nil
end

-- Apply layout settings to a header
function PinnedFrames:ApplyLayoutSettings(setIndex)
    local set = GetSetDB(setIndex)
    if not set then return end
    -- Layout changes touch secure header attributes (point/xOffset/size/anchor),
    -- which are combat-restricted. Defer to PLAYER_REGEN_ENABLED instead of silently
    -- dropping the change — otherwise a Direction/spacing/size tweak made mid-combat
    -- (e.g. between pulls in a follower dungeon) never reaches the live header until
    -- the next settings poke or a /reload. Mirrors FlatRaidFrames.pendingLayoutUpdate.
    if InCombatLockdown() then
        self.pendingLayoutUpdate = self.pendingLayoutUpdate or {}
        self.pendingLayoutUpdate[setIndex] = true
        return
    end

    -- Refresh Test Mode frames regardless of frame type. Cheapest correct
    -- approach: full Exit+Enter cycle, same as the test count slider uses.
    -- Settings panel slider drags fire at keyboard-repeat rate, but Exit+Enter
    -- is lightweight (just shows/hides non-secure frames and re-applies
    -- layout math — no allocations beyond first use).
    if self.testModeActive then
        self:ExitTestMode()
        self:EnterTestMode()
    end

    if IsBossSet(set) then
        self:ApplyBossLayout(setIndex)
        self:ResizeContainer(setIndex)
        return
    end

    local header = self.headers[setIndex]
    if not header then return end
    
    local db = GetPinnedModeDB()
    if not db then
        DF:DebugError("PINNED", "ApplyLayoutSettings: db is nil")
        return
    end
    
    local frameWidth, frameHeight = GetSetFrameSize(set, db)
    -- Border DB this set renders from: its own snapshot when Border Override is on,
    -- else the Based-on mode (live inherit). Stamped onto each child so
    -- DF:ApplyFrameBorder uses it instead of the shared per-mode db.
    local borderDB = GetSetBorderDB(set, GetSetBaselineDB(set, db))
    -- Effective DB + AD flag for Hide Auras / Hide Status Icons (nil when neither).
    local effDB = BuildPinnedEffDB(db, set.hideAuras, set.hideIcons)

    -- CRITICAL: Resize all child frames to match current raid/party settings
    -- This ensures frames use the correct size when switching between raid and party
    for i = 1, 40 do
        local child = header:GetAttribute("child" .. i)
        if child then
            -- Stamp the resolved pinned size so DF:ApplyFrameLayout (which otherwise
            -- sizes from the shared per-mode db) keeps this set's Match/Custom size.
            child.dfPinnedWidth, child.dfPinnedHeight = frameWidth, frameHeight
            child.dfPinnedBorderDB = borderDB
            child.dfPinnedEffDB = effDB
            child.dfPinnedHideAuras = set.hideAuras
            -- Per-set Aura/Text Designer preset (nil = inherit the mode's preset).
            child.dfAuraPresetOverride = set.auraDesignerPreset
            child.dfTextPresetOverride = set.textDesignerPreset
            child:SetSize(frameWidth, frameHeight)
            -- Also update the isRaidFrame flag for proper DB selection in other functions
            child.isRaidFrame = IsInRaid()
            -- Re-render the border now so border edits apply live (the per-frame
            -- ApplyFrameLayout also picks up dfPinnedBorderDB on its next tick).
            if DF.ApplyFrameBorder then DF:ApplyFrameBorder(child, borderDB) end
        end
    end
    
    local horizontal = GetSetGrowDirection(set) == "HORIZONTAL"
    local hSpacing, vSpacing = GetSetSpacing(set, db)
    local unitsPerRow = set.unitsPerRow or 5
    local columnAnchor = set.columnAnchor or "START"
    local frameAnchor = set.frameAnchor or "START"
    
    -- Frame anchor point determines where first frame is placed and growth direction
    -- HORIZONTAL: START=LEFT (grow right), CENTER=LEFT (grow right, expand from center), END=RIGHT (grow left)
    -- VERTICAL: START=TOP (grow down), CENTER=TOP (grow down, expand from center), END=BOTTOM (grow up)
    -- CENTER uses same internal layout as START — the "center" effect comes from the container anchor
    local point, xOff, yOff
    if horizontal then
        if frameAnchor == "END" then
            point = "RIGHT"
            xOff = -hSpacing  -- Negative to grow left
        else
            point = "LEFT"
            xOff = hSpacing   -- Positive to grow right
        end
        yOff = 0
    else
        if frameAnchor == "END" then
            point = "BOTTOM"
            yOff = vSpacing   -- Positive to grow up
        else
            point = "TOP"
            yOff = -vSpacing  -- Negative to grow down
        end
        xOff = 0
    end

    -- CRITICAL: clear every child's anchor points BEFORE we change the layout
    -- attributes below. Each SetAttribute("point"/"columnAnchorPoint"/…) fires
    -- SecureGroupHeader_OnAttributeChanged, which (while the header is visible)
    -- synchronously runs SecureGroupHeader_Update — and that function re-anchors
    -- displayed children with SetPoint WITHOUT ClearAllPoints-ing them first
    -- (confirmed in Blizzard_RestrictedAddOnEnvironment/SecureGroupHeaders.lua).
    -- So when the growth point flips (Horizontal LEFT -> Vertical TOP) each child
    -- keeps its stale anchor AND gains the new one, cascading diagonally (the
    -- "staircase"); a /reload only hides it by rebuilding the frames. Clearing the
    -- points first means every re-layout SetPoint lands on a clean child. Mirrors
    -- DF:UpdateRaidHeaderLayoutAttributes (Frames/Headers.lua).
    for i = 1, 40 do
        local child = header:GetAttribute("child" .. i)
        if child then child:ClearAllPoints() end
    end

    header:SetAttribute("point", point)
    header:SetAttribute("xOffset", xOff)
    header:SetAttribute("yOffset", yOff)

    -- Column anchor point determines where new columns/rows appear
    -- CENTER uses same internal layout as START — container anchor handles the centering
    local colAnchorPoint, colSpacing
    if horizontal then
        colSpacing = vSpacing
        colAnchorPoint = (columnAnchor == "END") and "BOTTOM" or "TOP"
    else
        colSpacing = hSpacing
        colAnchorPoint = (columnAnchor == "END") and "RIGHT" or "LEFT"
    end
    header:SetAttribute("columnSpacing", colSpacing)
    header:SetAttribute("columnAnchorPoint", colAnchorPoint)
    
    header:SetAttribute("maxColumns", math.ceil(40 / unitsPerRow))
    header:SetAttribute("unitsPerColumn", unitsPerRow)
    
    -- Store frame dimensions for the template
    header:SetAttribute("frameWidth", frameWidth)
    header:SetAttribute("frameHeight", frameHeight)
    
    -- Get the anchor point based on growth settings
    local containerAnchorPoint = GetContainerAnchorPoint(set)
    
    -- Apply scale FIRST (before any position work)
    local container = self.containers[setIndex]
    if container then
        container:SetScale(GetSetScale(set))
    end
    
    -- Anchor the header to the correct corner of container
    if container then
        header:ClearAllPoints()
        header:SetPoint(containerAnchorPoint, container, containerAnchorPoint, 0, 0)

        -- Restore saved position via the shared helper: it pins the GROWTH corner
        -- (so the grid size never shifts the first frame — live and test agree)
        -- while keeping pos.point as the screen reference (so coords keep their
        -- meaning and a default set doesn't jump). Mirrors EnsureTestContainer.
        local pos = set.position
        if pos then
            PositionPinnedContainer(container, set, pos, frameWidth, frameHeight)
        end
    end
    
    DF:Debug("PINNED", "ApplyLayoutSettings set=%d horizontal=%s frameAnchor=%s columnAnchor=%s containerAnchor=%s size=%dx%d spacing=%d,%d",
        setIndex, tostring(horizontal), tostring(frameAnchor), tostring(columnAnchor),
        tostring(containerAnchorPoint), frameWidth, frameHeight, hSpacing, vSpacing)
    
    -- ============================================================
    -- CRITICAL: 4-step refresh to force repositioning
    -- Without this, changing layout settings won't reposition frames
    -- ============================================================
    if set.enabled and header:IsShown() then
        local currentNameList = header:GetAttribute("nameList")
        
        -- Step 1: Clear nameList to remove unit assignments
        header:SetAttribute("nameList", "")
        
        -- Step 2: Clear all child positions
        for i = 1, 40 do
            local child = header:GetAttribute("child" .. i)
            if child then
                child:ClearAllPoints()
            end
        end
        
        -- Step 3: Force header to process by hiding and showing
        header:Hide()
        header:Show()
        
        -- Step 4: Restore nameList - this reassigns units with new layout
        if currentNameList and currentNameList ~= "" then
            header:SetAttribute("nameList", currentNameList)
        end
    end
    
    -- Resize container after layout change
    self:ResizeContainer(setIndex)
end

-- Manually position boss frames in a grid matching the set's layout settings
-- Called when layout settings change or boss visibility changes
function PinnedFrames:ApplyBossLayout(setIndex)
    local set = GetSetDB(setIndex)
    local container = self.containers[setIndex]
    if not set or not container then return end
    if InCombatLockdown() then return end

    -- Container scale + saved position handling.
    container:SetScale(GetSetScale(set))

    -- Pin the growth corner (size-invariant) with pos.point as the screen
    -- reference — same as ApplyLayoutSettings (see PositionPinnedContainer).
    local pos = set.position
    if pos then
        local bw, bh = GetSetFrameSize(set, GetPinnedModeDB())
        PositionPinnedContainer(container, set, pos, bw, bh)
    end

    -- Push slot coords + sizes to the secure handler. The allocator snippet
    -- reads these whenever a boss frame becomes visible.
    self:UpdateBossHandlerConfig(setIndex)

    -- Re-anchor any already-visible frames to their current slot coords so
    -- live layout changes (spacing, size, anchor) take effect immediately
    -- without waiting for the next Show event.
    local handler = self.bossHandlers[setIndex]
    if handler then
        handler:Execute([[
            local anchor = self:GetAttribute("anchor") or "TOPLEFT"
            for i = 1, 8 do
                local f = self:GetFrameRef("boss" .. i)
                if f then
                    local slot = tonumber(f:GetAttribute("assignedSlot"))
                    if slot then
                        local x = tonumber(self:GetAttribute("slot" .. slot .. "x")) or 0
                        local y = tonumber(self:GetAttribute("slot" .. slot .. "y")) or 0
                        f:ClearAllPoints()
                        f:SetPoint(anchor, self, anchor, x, y)
                    end
                end
            end
        ]])
    end
end

-- Resize container to fit content
function PinnedFrames:ResizeContainer(setIndex)
    -- Can't resize secure frames during combat
    if InCombatLockdown() then return end
    
    local container = self.containers[setIndex]
    local header = self.headers[setIndex]
    local set = GetSetDB(setIndex)
    
    if not container or not set then return end
    if not IsBossSet(set) and not header then return end
    -- Disabled sets are hidden — nothing to size, and this is a hot path under
    -- arena/roster event churn, so skip the child-count loop entirely.
    if not set.enabled then return end

    local db = GetPinnedModeDB()
    local frameWidth, frameHeight = GetSetFrameSize(set, db)

    if IsBossSet(set) then
        local frames = self.bossFrames[setIndex]
        if not frames then return end

        local visibleCount = 0
        for i = 1, 8 do
            if frames[i] and frames[i]:IsShown() then
                visibleCount = visibleCount + 1
            end
        end

        if visibleCount == 0 then
            container:SetSize(frameWidth, frameHeight)
            return
        end

        local horizontal = GetSetGrowDirection(set) == "HORIZONTAL"
        local hSp, vSp = GetSetSpacing(set, db)
        local spacing = horizontal and hSp or vSp
        local unitsPerRow = set.unitsPerRow or 5

        local rows = math.ceil(visibleCount / unitsPerRow)
        local cols = math.min(visibleCount, unitsPerRow)

        local width, height
        if horizontal then
            width = cols * frameWidth + (cols - 1) * spacing
            height = rows * frameHeight + (rows - 1) * vSp
        else
            width = rows * frameWidth + (rows - 1) * hSp
            height = cols * frameHeight + (cols - 1) * spacing
        end

        container:SetSize(math.max(width, 50), math.max(height, 30))
        return
    end

    -- Count visible children
    local visibleCount = 0
    for i = 1, 40 do
        local child = header:GetAttribute("child" .. i)
        if child and child:IsShown() then
            visibleCount = visibleCount + 1
        end
    end
    
    if visibleCount == 0 then
        container:SetSize(frameWidth, frameHeight)
        return
    end
    
    local horizontal = GetSetGrowDirection(set) == "HORIZONTAL"
    local hSp, vSp = GetSetSpacing(set, db)
    local spacing = horizontal and hSp or vSp
    local unitsPerRow = set.unitsPerRow or 5
    
    local rows = math.ceil(visibleCount / unitsPerRow)
    local cols = math.min(visibleCount, unitsPerRow)
    
    local width, height
    if horizontal then
        width = cols * frameWidth + (cols - 1) * spacing
        height = rows * frameHeight + (rows - 1) * vSp
    else
        width = rows * frameWidth + (rows - 1) * hSp
        height = cols * frameHeight + (cols - 1) * spacing
    end
    
    container:SetSize(math.max(width, 50), math.max(height, 30))
end

-- Update all headers
function PinnedFrames:UpdateAllHeaders()
    for i = 1, PinnedFrames.MAX_SETS do
        self:UpdateHeaderNameList(i)
    end
end

-- ============================================================
-- ENABLE/DISABLE/LOCK
-- ============================================================

-- Iterate through header children and manage their events
local function SetChildFrameEvents(header, enabled)
    if DF.SetHeaderChildrenEventsEnabled then
        DF:SetHeaderChildrenEventsEnabled(header, enabled)
    end
end

-- Toggle enabled state for a set
-- Refresh all child frames for a set (called after enabling for combat reload support)
-- Uses FullFrameRefresh which uses Blizzard aura cache ONLY - no fallback
function PinnedFrames:RefreshChildFrames(setIndex)
    local set = GetSetDB(setIndex)
    if not set then return end

    if IsBossSet(set) then
        local frames = self.bossFrames[setIndex]
        if not frames then return end
        for i = 1, 8 do
            local f = frames[i]
            if f and f.unit and f:IsVisible() then
                if DF.FullFrameRefresh then
                    DF:FullFrameRefresh(f)
                end
            end
        end
        return
    end

    local header = self.headers[setIndex]
    if not header then return end

    for i = 1, 40 do
        local child = header:GetAttribute("child" .. i)
        if child and child.unit and child:IsVisible() then
            if DF.FullFrameRefresh then
                DF:FullFrameRefresh(child)
            end
        end
    end

    DF:Debug("PINNED", "Set %d refreshed all child frames", setIndex)
end

function PinnedFrames:SetEnabled(setIndex, enabled)
    local set = GetSetDB(setIndex)
    if not set then return end

    set.enabled = enabled

    -- Effective visibility = configured enabled AND the party solo gate. The
    -- stored config (set.enabled) is unchanged; only show/hide reads `visible`,
    -- so a solo-hidden set re-appears automatically when you join a group (the
    -- roster handler re-runs SetEnabled on the solo↔group transition).
    local visible = enabled and PinnedSoloAllowed(set)

    local container = self.containers[setIndex]
    local header = self.headers[setIndex]
    local isBoss = IsBossSet(set)

    if not container or (not isBoss and not header) then
        if visible then
            self:CreateSetFrames(setIndex)
        end
        return
    end

    if InCombatLockdown() then
        self.pendingVisibilityUpdate = self.pendingVisibilityUpdate or {}
        self.pendingVisibilityUpdate[setIndex] = enabled
        return
    end

    -- Player mode: toggle header child events
    if not isBoss and header then
        SetChildFrameEvents(header, visible)
    end

    local label = self.labels[setIndex]

    if visible then
        -- During test mode the live frames are deliberately hidden (the preview
        -- owns the screen). Update layout data but DON'T show live chrome, or the
        -- real frame leaks under the preview; ExitTestMode shows it on the way out.
        local inTest = self.testModeActive

        if not inTest then
            container:Show()
            if header then header:Show() end
        end

        if isBoss then
            self:ApplyBossLayout(setIndex)
            self:ResizeContainer(setIndex)
        else
            self:UpdateHeaderNameList(setIndex)
            self:ApplyLayoutSettings(setIndex)
        end

        self:UpdateLabel(setIndex)
        if not inTest then
            if label then label:SetShown(set.showLabel) end
            -- A set that becomes visible while globally unlocked gets its drag chrome.
            if self.moversShown then
                if container.mover then container.mover:SetShown(true) end
                if container.bg then container.bg:SetShown(true) end
                if container.border then container.border:SetShown(true) end
            end
            -- Re-assert Hide-Mover alpha + active highlight on the freshly-shown handle.
            self:ApplyMoverOverlayAlpha()
            self:RefreshMoverActiveStates()
        end

        self:RefreshChildFrames(setIndex)
    else
        container:Hide()
        if header then header:Hide() end
        if label then label:Hide() end
        if container.mover then container.mover:Hide() end
        if container.bg then container.bg:Hide() end
        if container.border then container.border:Hide() end

        -- #78: a set that was hiding members from the main frames must RELEASE
        -- them when it turns off — ComputeHiddenNames now skips this set, but
        -- nothing else rebuilds the main headers until the next roster change,
        -- leaving the members in neither pinned nor main frames. (Combat-safe:
        -- RefreshMainFrameSorting defers itself via pendingSortingUpdate.)
        if not isBoss and set.hideFromMainFrames and DF.RefreshMainFrameSorting then
            self:InvalidateHiddenNames()
            DF:RefreshMainFrameSorting()
        end
    end
end

-- Re-sync every set's show/hide state against the CURRENT profile + mode
-- config. SetEnabled handles create/show/hide plus the party solo gate, reading
-- each set's freshly-resolved config. Called after a profile switch
-- (FullProfileRefresh): without it a set that was shown under the previous
-- profile lingers on screen when the new profile has that set disabled.
function PinnedFrames:RefreshEnabledState()
    if not self.initialized then return end
    for i = 1, PinnedFrames.MAX_SETS do
        local set = GetSetDB(i)
        if set then self:SetEnabled(i, set.enabled) end
    end
end

-- Show or hide the pinned drag chrome (mover + bg + border) for every set in the
-- current mode. Driven by the MAIN frames lock: DF:UnlockFrames / UnlockRaidFrames
-- → true; LockFrames / LockRaidFrames → false. Replaces the retired per-set lock,
-- so the pinned frames now lock/unlock together with everything else.
function PinnedFrames:SetMoversShown(shown)
    -- Showing handles only makes sense out of combat (the drag reposition path is
    -- combat-guarded). The main Unlock paths already block in combat, so this is
    -- just defence in depth — defer an unlock that somehow arrives mid-combat.
    if shown and InCombatLockdown() then
        self.pendingMoversShown = true
        return
    end

    -- An explicit lock cancels any combat-deferred/remembered unlock intent, so a
    -- post-combat restore can't re-show handles the user just locked. (LockAllForCombat
    -- re-sets moversShownBeforeCombat AFTER calling this, so its own hide is unaffected.)
    if not shown then
        self.pendingMoversShown = nil
        self.moversShownBeforeCombat = nil
    end

    self.moversShown = shown and true or false

    if not self.initialized then return end

    -- During test mode the live containers are hidden and the TEST containers
    -- (each with its own testMover) are the preview — drive those handles instead.
    if self.testModeActive then
        for i = 1, PinnedFrames.MAX_SETS do
            local tc = self.testContainers[i]
            if tc and tc.testMover then tc.testMover:SetShown(self.moversShown) end
        end
        self:RefreshMoverActiveStates()
        self:ApplyMoverOverlayAlpha()
        return
    end

    for i = 1, PinnedFrames.MAX_SETS do
        local set = GetSetDB(i)
        local container = self.containers[i]
        if set and container then
            -- Effective visibility includes the party solo gate — chrome is
            -- parented to UIParent, so showing it for a solo-hidden set would
            -- float a "Drag to Move" handle over an invisible container.
            local visible = self.moversShown and set.enabled and PinnedSoloAllowed(set)
            if container.bg then container.bg:SetShown(visible) end
            if container.border then container.border:SetShown(visible) end
            if container.mover then container.mover:SetShown(visible) end
        end
    end
    self:RefreshMoverActiveStates()
    self:ApplyMoverOverlayAlpha()
end

-- Hide pinned chrome on combat start, remembering the unlock intent so it can be
-- restored afterwards. Only non-secure overlay frames are touched (combat-safe).
function PinnedFrames:LockAllForCombat()
    if not self.initialized then return end

    local was = self.moversShown
    if was then
        -- SetMoversShown(false) hides every set's chrome (safe in combat) and clears
        -- the restore intent; we set it AFTER so the post-combat restore can fire.
        self:SetMoversShown(false)
        DF:Debug("PINNED", "Pinned movers hidden for combat")
    end
    self.moversShownBeforeCombat = was
end

-- Restore the pre-combat unlock state (or apply an unlock requested during combat).
function PinnedFrames:RestoreUnlockedAfterCombat()
    if self.moversShownBeforeCombat or self.pendingMoversShown then
        self.moversShownBeforeCombat = nil
        self.pendingMoversShown = nil
        self:SetMoversShown(true)
    end
end

-- Forward declaration: GetSetDBForMode is defined further down (near the test-mode
-- helpers) but is needed here by GetSetForPosition. Declaring the local up front
-- lets the later `function GetSetDBForMode` assign to this same upvalue.
local GetSetDBForMode

-- True when the position panel should target the RAID set: either raid test mode
-- is previewing, or (not in test) the player is actually in a raid. Party sets
-- live in the party db with no auto-layout overlays; raid sets need the mirror.
local function PositionTargetIsRaid(self)
    if self.testModeActive then return DF.raidTestMode and true or false end
    return IsInRaid()
end

-- Resolve the set table the shared position panel targets. In test mode this is
-- the set for the mode being PREVIEWED (raid test while solo edits the raid set),
-- matching the test mover + the frames actually on screen; otherwise the live
-- current-mode set. Overlay-aware (same table the runtime + drag handler use).
function PinnedFrames:GetSetForPosition(setIndex)
    if self.testModeActive then
        return GetSetDBForMode(setIndex, PositionTargetIsRaid(self))
    end
    return GetSetDB(setIndex)
end

-- True when the position panel currently targets a RAID set (raid accent + label).
function PinnedFrames:IsPositionTargetRaid()
    return PositionTargetIsRaid(self)
end

-- "NPC (Raid)" style label for the position panel, matching the drag handle.
function PinnedFrames:GetPositionPanelLabel(setIndex)
    return PinnedSetLabel(self:GetSetForPosition(setIndex), setIndex, PositionTargetIsRaid(self))
end

-- Apply the pinned "Hide Mover" preference to every pinned handle — both live and
-- test. Its own flag (db.pinnedHideMover), independent of the main-frame drag
-- overlay. alpha 0 keeps handles draggable but invisible. Called from the panel
-- toggle and whenever handles are (re)shown so the pref sticks.
function PinnedFrames:ApplyMoverOverlayAlpha()
    local db = DF.GetDB and DF:GetDB()
    local a = (db and db.pinnedHideMover) and 0 or 1
    for i = 1, PinnedFrames.MAX_SETS do
        local lc = self.containers[i]
        if lc and lc.mover then lc.mover:SetAlpha(a) end
        local tc = self.testContainers[i]
        if tc and tc.testMover then tc.testMover:SetAlpha(a) end
    end
end

-- Highlight the drag handle of the set the position panel is currently driving
-- (and clear the others). Called whenever the panel target changes so the
-- handle<->panel link is visible. Covers both live and test handles.
function PinnedFrames:RefreshMoverActiveStates()
    local activeIndex = (DF.positionPanelMode == "pinned") and (DF.positionPanelPinnedSet or 1) or nil
    for i = 1, PinnedFrames.MAX_SETS do
        local lc = self.containers[i]
        if lc and lc.mover and lc.mover.SetActive then lc.mover:SetActive(i == activeIndex) end
        local tc = self.testContainers[i]
        if tc and tc.testMover and tc.testMover.SetActive then tc.testMover:SetActive(i == activeIndex) end
    end
end

-- Reposition a pinned set's container from its saved set.position (the nudge
-- position panel's apply). Mirrors the drag handler: pin by the saved anchor
-- (pos.point) and write the position through to the persistent DB so it survives
-- auto-layout overlay rebuilds (position is never auto-layout-overridable).
function PinnedFrames:ApplySetPosition(setIndex)
    if InCombatLockdown() then return end  -- moving a secure-header parent taints
    local set = self:GetSetForPosition(setIndex)
    if not set then return end

    local pos = set.position
    if not pos then return end

    local raid = PositionTargetIsRaid(self)
    local db = raid and DF:GetRaidDB() or DF:GetDB()
    local w, h = GetSetFrameSize(set, db)

    -- Move the container the user currently sees: the TEST container in test mode
    -- (live containers are hidden then), otherwise the LIVE container. The mover +
    -- label are anchored to the container, so they follow. PositionPinnedContainer
    -- pins the growth corner (size-invariant) using pos.point as the screen ref.
    local container = self.testModeActive and self.testContainers[setIndex]
        or self.containers[setIndex]
    PositionPinnedContainer(container, set, pos, w, h)

    -- Mirror RAID-set positions to _realRaidDB so they survive auto-layout overlay
    -- rebuilds. Party sets have no overlays (GetSetDB returns the real table).
    if raid then
        local realSet = DF._realRaidDB and DF._realRaidDB.pinnedFrames
            and DF._realRaidDB.pinnedFrames.sets and DF._realRaidDB.pinnedFrames.sets[setIndex]
        if realSet then
            realSet.position = realSet.position or {}
            realSet.position.point = pos.point or GetContainerAnchorPoint(set)
            realSet.position.x = pos.x
            realSet.position.y = pos.y
            realSet.position.anchorTo = pos.anchorTo
        end
    end
end

-- Toggle label visibility
function PinnedFrames:SetShowLabel(setIndex, show)
    local set = GetSetDB(setIndex)
    local label = self.labels[setIndex]
    
    if not set or not label then return end
    
    set.showLabel = show
    label:SetShown(show)
end

-- Update label text
function PinnedFrames:UpdateLabel(setIndex)
    local set = GetSetDB(setIndex)
    local label = self.labels[setIndex]
    
    if not set or not label then return end
    
    local labelText = set.name
    if not labelText or labelText == "" then
        labelText = "Pinned " .. setIndex
    end
    label:SetText(labelText)
end

-- Backwards-compat stubs for the old preview-container system (removed in
-- favour of Test Mode, which does the same job with fake frames). These
-- no-ops keep external callers (Options.lua) working until their calls are
-- cleaned up; safe to remove once all callsites are updated.
function PinnedFrames:ShowPreview(_) end
function PinnedFrames:HidePreview() end
function PinnedFrames:UpdatePreviewSet(_) end

-- ============================================================
-- INITIALIZATION
-- ============================================================

function PinnedFrames:Initialize()
    if self.initialized then return end
    
    -- CRITICAL: Cannot create frames during combat
    if InCombatLockdown() then
        DF:DebugWarn("PINNED", "Initialize: in combat, deferring")
        self.pendingInitialize = true
        return
    end

    -- Check if DB is ready - if not during ADDON_LOADED, defer to pending
    if not DF.db then
        DF:DebugWarn("PINNED", "Initialize: DF.db not ready, deferring")
        self.pendingInitialize = true
        return
    end

    -- Track what mode we're initializing for
    self.currentMode = GetActualMode()

    -- Check if pinnedFrames config exists
    local hlDB = GetPinnedDB()
    if not hlDB then
        DF:DebugError("PINNED", "Initialize: no pinnedFrames config found")
        return
    end

    DF:Debug("PINNED", "Initializing pinned frames (mode=%s)", tostring(self.currentMode))
    
    -- Create frames for every defined set (CreateSetFrames no-ops past the last
    -- defined set, so iterating the cap is safe and also rebuilds correctly when
    -- the set count changed).
    for i = 1, PinnedFrames.MAX_SETS do
        self:CreateSetFrames(i)
    end
    
    self.initialized = true
    
    -- Apply layout settings immediately (no delays for combat safety)
    -- Note: ApplyLayoutSettings is also called in CreateSetFrames, but we do it
    -- again here to ensure all settings are applied after headers are fully set up
    for i = 1, PinnedFrames.MAX_SETS do
        local header = self.headers[i]
        local set = GetSetDB(i)
        if set and set.enabled and (header or IsBossSet(set)) then
            self:ApplyLayoutSettings(i)
        end
    end

    -- Apply the party "Show when solo" gate: CreateSetFrames above shows based on
    -- raw enabled, so re-run SetEnabled to hide solo sets that haven't opted in.
    -- Record the initial group state for solo<->group transition detection.
    self.wasInGroup = IsInGroup()
    for i = 1, PinnedFrames.MAX_SETS do
        local set = GetSetDB(i)
        if set then self:SetEnabled(i, set.enabled) end
    end

    DF:Debug("PINNED", "Initialized pinned frames")
end

-- Reinitialize for mode change (party <-> raid)
function PinnedFrames:Reinitialize()
    -- Cannot reinitialize during combat
    if InCombatLockdown() then
        DF:DebugWarn("PINNED", "Reinitialize: in combat, deferring")
        self.pendingReinitialize = true
        return
    end
    
    -- Clean up old frames
    for i = 1, PinnedFrames.MAX_SETS do
        if self.bossHandlers[i] then
            self.bossHandlers[i]:Hide()
            self.bossHandlers[i] = nil
        end
        -- Destroy player-mode test frame pool (non-secure, safe to hide+nil)
        if self.testFrames[i] then
            for _, f in ipairs(self.testFrames[i]) do
                if f then f:Hide() end
            end
            self.testFrames[i] = nil
        end
        if self.testContainers[i] then
            if self.testContainers[i].testMover then
                self.testContainers[i].testMover:Hide()
            end
            if self.testContainers[i].testLabel then
                self.testContainers[i].testLabel:Hide()
            end
            self.testContainers[i]:Hide()
            self.testContainers[i] = nil
        end
        if self.bossFrames[i] then
            for j = 1, 8 do
                local f = self.bossFrames[i][j]
                if f then
                    UnregisterStateDriver(f, "visibility")
                    f:UnregisterAllEvents()
                    f:Hide()
                end
            end
            self.bossFrames[i] = nil
        end
        if self.containers[i] then
            if self.containers[i].mover then
                self.containers[i].mover:Hide()
            end
            self.containers[i]:Hide()
            self.containers[i] = nil
        end
        if self.headers[i] then
            self.headers[i]:Hide()
            self.headers[i] = nil
        end
        if self.labels[i] then
            self.labels[i]:Hide()
        end
        self.labels[i] = nil
    end
    
    self.initialized = false
    self:Initialize()

    -- If Test Mode was active before Reinitialize (e.g. user changed
    -- frame type in the settings panel while test mode was on), re-enter
    -- it so fresh test frames are rendered for the new frame type.
    if self.testModeActive then
        self.testModeActive = false  -- ExitTestMode is a no-op in this state
        self:EnterTestMode()
    end
end

-- ============================================================
-- DYNAMIC SETS — add / remove beyond the default two
-- ============================================================

-- A fresh set, mirroring Config's per-set defaults. Disabled by default so a
-- newly-added set is dormant (no secure-header churn) until the user enables it.
-- Position is staggered by index so new sets don't all land on the same spot.
local function MakeDefaultSet(index)
    return {
        enabled = false,
        frameType = "player",
        testCount = 3,
        name = "Pinned " .. index,
        players = {},
        growDirection = "HORIZONTAL",
        unitsPerRow = 5,
        -- horizontalSpacing / verticalSpacing left unset (nil) so a new set
        -- INHERITS its Based-on mode's frameSpacing via GetSetSpacing; set a
        -- value only to override (keeps pinned aligned with the frames it mirrors).
        position = { point = "CENTER", x = 0, y = 250 - (index - 1) * 130 },
        showLabel = false,
        columnAnchor = "START",
        frameAnchor = "START",
        autoAddTanks = false,
        autoAddHealers = false,
        autoAddDPS = false,
        keepOfflinePlayers = false,
        manualPlayers = {},
    }
end

-- Resolve a mode's pinnedFrames DB via the same accessor the editor and runtime
-- use, so writes land on the table they read from (works for the inactive mode).
local function ModePinnedDB(mode)
    local md = DF.GetDB and DF:GetDB(mode)
    return md and md.pinnedFrames
end

-- Add a new pinned set to ONE mode. Party and raid are INDEPENDENT — you can run,
-- say, 4 raid sets and 1 party set. `mode` defaults to the active mode; the editor
-- passes its selected mode, so adding to the inactive mode is a pure DB change that
-- materialises on the next mode switch (Reinitialize). Returns the new index, or
-- nil at the cap. Secure frames build out of combat (deferred otherwise).
function PinnedFrames:AddSet(mode)
    mode = mode or GetActualMode()
    local pf = ModePinnedDB(mode)
    if not pf or not pf.sets then return nil end
    if #pf.sets >= self.MAX_SETS then return nil end
    local newIndex = #pf.sets + 1
    pf.sets[newIndex] = MakeDefaultSet(newIndex)
    -- Only (re)build live frames when editing the ACTIVE mode; the inactive mode's
    -- frames are rebuilt by Reinitialize the next time you enter that mode.
    if mode ~= GetActualMode() then return newIndex end
    if InCombatLockdown() then
        self.pendingReinitialize = true
        return newIndex
    end
    self:CreateSetFrames(newIndex)
    self:ApplyLayoutSettings(newIndex)
    local set = GetSetDB(newIndex)
    self:SetEnabled(newIndex, set and set.enabled)
    return newIndex
end

-- Remove a pinned set from ONE mode. Refuses the last set. `table.remove` compacts
-- the array (nested config + designer-preset refs travel with it). For the active
-- mode, Reinitialize rebuilds runtime frames from the compacted DB; for the
-- inactive mode it's a pure DB change. Combat-safe (hide now, rebuild after).
function PinnedFrames:RemoveSet(setIndex, mode)
    mode = mode or GetActualMode()
    local pf = ModePinnedDB(mode)
    if not pf or not pf.sets then return false end
    if #pf.sets <= 1 then return false end
    if setIndex < 1 or setIndex > #pf.sets then return false end

    table.remove(pf.sets, setIndex)

    -- The raid position mirror writes to DF._realRaidDB.pinnedFrames.sets[i] BY
    -- INDEX; with an active auto-layout overlay, pf.sets is a separate deep copy,
    -- so compact the real raid array too or the later sets' mirrored positions
    -- desync after a remove. (When no overlay is active rsets == pf.sets and it's
    -- already compacted — the identity guard avoids a double-remove.)
    if mode == "raid" then
        local rsets = DF._realRaidDB and DF._realRaidDB.pinnedFrames and DF._realRaidDB.pinnedFrames.sets
        if rsets and rsets ~= pf.sets and rsets[setIndex] then
            table.remove(rsets, setIndex)
        end
    end

    if mode ~= GetActualMode() then return true end  -- inactive mode: DB only
    if InCombatLockdown() then
        local c = self.containers[setIndex]
        if c then
            if c.mover then c.mover:Hide() end
            c:Hide()
        end
        if self.headers[setIndex] then self.headers[setIndex]:Hide() end
        if self.labels[setIndex] then self.labels[setIndex]:Hide() end
        self.pendingReinitialize = true
        return true
    end

    self:Reinitialize()
    return true
end

-- Refresh all child frames (calls FullFrameRefresh on each)
function PinnedFrames:RefreshAllChildFrames()
    for setIndex = 1, PinnedFrames.MAX_SETS do
        local set = GetSetDB(setIndex)
        if set then
            if IsBossSet(set) then
                local frames = self.bossFrames[setIndex]
                if frames then
                    for i = 1, 8 do
                        local f = frames[i]
                        if f and f:IsShown() and f.unit then
                            if DF.FullFrameRefresh then
                                DF:FullFrameRefresh(f)
                            end
                        end
                    end
                end
            else
                local header = self.headers[setIndex]
                if header then
                    for i = 1, 40 do
                        local child = header:GetAttribute("child" .. i)
                        if child and child:IsShown() and child.unit then
                            if DF.FullFrameRefresh then
                                DF:FullFrameRefresh(child)
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Re-render Text Designer text on every shown pinned frame, live OR test.
-- TD-only (UpdateTextDesigner, not the heavier FullFrameRefresh / UpdateTestFrame)
-- so it stays cheap on the Text Designer editor's throttled live-edit path (e.g.
-- colour-picker drag). Boss sets live in bossFrames[setIndex]; player sets live
-- as secure-header children. While test mode is active the live frames are hidden
-- (the non-secure test pool owns the screen), so the test branch picks those up —
-- pinned test frames carry a fake .unit + dfIsTestFrame, so UpdateTextDesigner
-- self-sources Test data. Called from the TD editor's live refresh, which
-- otherwise only reached boss sets (live) and the main test pools (never pinned).
function PinnedFrames:RefreshTextDesigner()
    if not DF.UpdateTextDesigner then return end

    -- Test mode: refresh the non-secure pinned test pool (live frames are hidden).
    if self.testModeActive then
        for setIndex = 1, PinnedFrames.MAX_SETS do
            local pool = self.testFrames[setIndex]
            if pool then
                for i = 1, #pool do
                    local f = pool[i]
                    if f and f:IsShown() and f.unit then
                        DF:UpdateTextDesigner(f, "all")
                    end
                end
            end
        end
        return
    end

    -- Live frames (out of test mode).
    for setIndex = 1, PinnedFrames.MAX_SETS do
        local set = GetSetDB(setIndex)
        if set then
            if IsBossSet(set) then
                local frames = self.bossFrames[setIndex]
                if frames then
                    for i = 1, 8 do
                        local f = frames[i]
                        if f and f:IsShown() and f.unit then
                            DF:UpdateTextDesigner(f, "all")
                        end
                    end
                end
            else
                local header = self.headers[setIndex]
                if header then
                    for i = 1, 40 do
                        local child = header:GetAttribute("child" .. i)
                        if child and child:IsShown() and child.unit then
                            DF:UpdateTextDesigner(child, "all")
                        end
                    end
                end
            end
        end
    end
end

-- Re-apply name/health/status fonts on every shown pinned frame (live OR test),
-- so a global font / shadow change repaints them. The main RefreshAllFonts
-- iterators don't reach the pinned pool — and pinned test frames live in their
-- own non-secure pool, not the secure headers. Mirrors RefreshTextDesigner's
-- traversal. Each call is guarded (GetFrameDB may be nil; RefreshFrameFonts
-- bails on a nil db) so it can't error on a half-built frame during login.
function PinnedFrames:RefreshFonts()
    if not DF.RefreshFrameFonts then return end
    local function refont(f)
        if f and f:IsShown() then
            DF.RefreshFrameFonts(f, DF:GetFrameDB(f))
        end
    end

    if self.testModeActive then
        for setIndex = 1, PinnedFrames.MAX_SETS do
            local pool = self.testFrames[setIndex]
            if pool then
                for i = 1, #pool do refont(pool[i]) end
            end
        end
        return
    end

    for setIndex = 1, PinnedFrames.MAX_SETS do
        local set = GetSetDB(setIndex)
        if set then
            if IsBossSet(set) then
                local frames = self.bossFrames[setIndex]
                if frames then
                    for i = 1, 8 do refont(frames[i]) end
                end
            else
                local header = self.headers[setIndex]
                if header then
                    for i = 1, 40 do refont(header:GetAttribute("child" .. i)) end
                end
            end
        end
    end
end

DF.RefreshPinnedFonts = function() PinnedFrames:RefreshFonts() end

-- ============================================================
-- EVENT HANDLING
-- All initialization must happen synchronously during ADDON_LOADED
-- No C_Timer.After delays - they can fire during combat lockdown
-- ============================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("ROLE_CHANGED_INFORM")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
eventFrame:RegisterEvent("UNIT_TARGETABLE_CHANGED")
eventFrame:RegisterEvent("UNIT_FACTION")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

eventFrame:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "ADDON_LOADED" then
        if arg1 == "DandersFrames" then
            -- Initialize immediately during ADDON_LOADED
            -- During /reload, this fires BEFORE combat lockdown is re-established
            -- so we can safely create frames here without deferring
            if DF.db then
                PinnedFrames:Initialize()
                
                -- Populate the nameList - always update headers on load
                if PinnedFrames.initialized then
                    PinnedFrames:ProcessAllSets()
                    PinnedFrames:UpdateAllHeaders()  -- Force update even if no changes
                    
                    -- Force visual refresh on all child frames immediately
                    PinnedFrames:RefreshAllChildFrames()
                end
            end
        end
        return
    end
    
    if not DF.db then return end
    
    if event == "PLAYER_REGEN_DISABLED" then
        -- Auto-lock all unlocked pinned sets on combat start
        if PinnedFrames.initialized then
            PinnedFrames:LockAllForCombat()
        end
        return
    end
    
    if event == "PLAYER_REGEN_ENABLED" then
        -- Replay an ExitTestMode that was blocked by combat — the global test
        -- flags are already off by then, so without this testModeActive would
        -- stick true forever (killing Hide-from-Main + the solo gate).
        if PinnedFrames.pendingExitTestMode then
            PinnedFrames:ExitTestMode()
        end

        -- Restore unlock state for sets that were unlocked before combat
        if PinnedFrames.initialized then
            PinnedFrames:RestoreUnlockedAfterCombat()
        end

        -- Process pending reinitialization after combat
        if PinnedFrames.pendingReinitialize then
            PinnedFrames.pendingReinitialize = nil
            PinnedFrames:Reinitialize()
            PinnedFrames:ProcessAllSets()
            return  -- Reinitialize handles everything
        end
        
        -- Process pending initialization after combat
        if PinnedFrames.pendingInitialize then
            PinnedFrames.pendingInitialize = nil
            PinnedFrames:Initialize()
            PinnedFrames:ProcessAllSets()
        end
        
        -- Process pending updates after combat
        if PinnedFrames.pendingNameListUpdate then
            for setIndex, _ in pairs(PinnedFrames.pendingNameListUpdate) do
                PinnedFrames:UpdateHeaderNameList(setIndex)
            end
            PinnedFrames.pendingNameListUpdate = nil
        end
        
        if PinnedFrames.pendingVisibilityUpdate then
            for setIndex, enabled in pairs(PinnedFrames.pendingVisibilityUpdate) do
                PinnedFrames:SetEnabled(setIndex, enabled)
            end
            PinnedFrames.pendingVisibilityUpdate = nil
        end

        -- Replay layout changes (Direction/spacing/size/anchor) that were attempted
        -- in combat. Skipped harmlessly when pendingReinitialize already ran above
        -- (it returns early and re-applies every set's layout via ProcessAllSets).
        if PinnedFrames.pendingLayoutUpdate then
            for idx in pairs(PinnedFrames.pendingLayoutUpdate) do
                PinnedFrames:ApplyLayoutSettings(idx)
            end
            PinnedFrames.pendingLayoutUpdate = nil
        end

        -- Reset slot allocator + reapply layout now that we're out of combat.
        -- Fresh pull starts with all slots free; any frames still visible
        -- (rare — e.g. we left combat mid-add) re-enter via onBossShow.
        if PinnedFrames.initialized then
            for setIndex = 1, PinnedFrames.MAX_SETS do
                local set = GetSetDB(setIndex)
                if set and set.enabled and IsBossSet(set) then
                    local handler = PinnedFrames.bossHandlers[setIndex]
                    if handler then
                        handler:Execute([[ self:RunAttribute("resetAllocState") ]])
                    end
                    PinnedFrames:ApplyBossLayout(setIndex)
                    PinnedFrames:ResizeContainer(setIndex)

                    -- Re-claim slots for any frames still visible post-reset.
                    -- Single Execute call runs a loop inside the restricted env
                    -- rather than 8 separate interpolated snippets.
                    if handler then
                        handler:Execute([[
                            for i = 1, 8 do
                                local f = self:GetFrameRef("boss" .. i)
                                if f and f:IsShown() then
                                    self:RunAttribute("onBossShow", i)
                                end
                            end
                        ]])
                    end
                end
            end
        end
        return
    end
    
    if event == "PLAYER_ENTERING_WORLD" then
        -- Re-apply pinned visibility on zone-in. The roster events that normally
        -- drive the show path (SetEnabled) fire as you're added to the BG / arena
        -- raid — often BEFORE the instance, its frames and roster names are ready,
        -- and frequently in combat (where Reinitialize defers). Nothing re-drove
        -- them once the instance settled, so pinned sets stayed hidden until a
        -- manual disable/enable. PLAYER_ENTERING_WORLD is the "instance loaded"
        -- trigger that was missing.
        if PinnedFrames.initialized then
            if InCombatLockdown() then
                -- Drained on PLAYER_REGEN_ENABLED above (Reinitialize + ProcessAllSets).
                PinnedFrames.pendingReinitialize = true
            else
                local actualMode = GetActualMode()
                if PinnedFrames.currentMode and actualMode ~= PinnedFrames.currentMode then
                    PinnedFrames:Reinitialize()
                    PinnedFrames:ProcessAllSets()
                else
                    -- Re-assert each set's visibility (the show path) + re-populate
                    -- now that the instance has settled. Debounced, combat-safe.
                    for i = 1, PinnedFrames.MAX_SETS do
                        local set = GetSetDB(i)
                        if set then PinnedFrames:SetEnabled(i, set.enabled) end
                    end
                    PinnedFrames:RequestProcessAllSets()
                end
            end
        end
        return
    end

    if event == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" then
        if PinnedFrames.initialized then
            PinnedFrames:OnBossFramesChanged()
        end
        return
    end

    if event == "UNIT_TARGETABLE_CHANGED" then
        if type(arg1) == "string" and arg1:match("^boss%d$") then
            if PinnedFrames.initialized then
                PinnedFrames:OnBossFramesChanged()
            end
        end
        return
    end

    if event == "UNIT_FACTION" then
        if type(arg1) == "string" and arg1:match("^boss%d$") then
            if PinnedFrames.initialized then
                PinnedFrames:OnBossFramesChanged()
            end
        end
        return
    end

    -- GROUP_ROSTER_UPDATE or ROLE_CHANGED_INFORM
    if PinnedFrames.initialized then
        -- Check if mode changed (party <-> raid)
        local actualMode = GetActualMode()
        if PinnedFrames.currentMode and actualMode ~= PinnedFrames.currentMode then
            DF:Debug("PINNED", "Mode changed from %s to %s — reinitializing",
                tostring(PinnedFrames.currentMode), tostring(actualMode))
            PinnedFrames:Reinitialize()
            return
        end

        -- Solo <-> group transition: re-apply each set's visibility so the party
        -- "Show when solo" gate takes effect (SetEnabled reads PinnedSoloAllowed).
        -- Only on the actual transition — not every roster change inside a group.
        local inGroup = IsInGroup()
        if PinnedFrames.wasInGroup == nil then PinnedFrames.wasInGroup = inGroup end
        if inGroup ~= PinnedFrames.wasInGroup then
            PinnedFrames.wasInGroup = inGroup
            for i = 1, PinnedFrames.MAX_SETS do
                local set = GetSetDB(i)
                if set then PinnedFrames:SetEnabled(i, set.enabled) end
            end
        end

        -- Debounced: roster events can storm (especially in instanced PvP), so
        -- coalesce them into one deferred ProcessAllSets to stay within budget.
        PinnedFrames:RequestProcessAllSets()
    end
end)

-- ============================================================
-- DEBUG
-- ============================================================

function PinnedFrames:DebugPrint()
    print("|cFF00FFFF[DF Pinned]|r === Debug Info ===")
    print("  Initialized:", tostring(self.initialized))
    print("  Current mode:", self.currentMode or "unknown")
    print("  Actual mode:", GetActualMode())
    print("  DF.db exists:", tostring(DF.db ~= nil))
    
    local hlDB = GetPinnedDB()
    print("  pinnedFrames DB exists:", tostring(hlDB ~= nil))
    
    -- Show current group roster
    local roster = GetGroupRoster()
    local rosterCount = 0
    for _ in pairs(roster) do rosterCount = rosterCount + 1 end
    print("  Group roster count:", rosterCount)
    for name, _ in pairs(roster) do
        print("    -", name)
    end
    
    for i = 1, PinnedFrames.MAX_SETS do
        local set = GetSetDB(i)
        print(" ")
        print("  === Set " .. i .. " ===")
        if set then
            print("    Enabled:", tostring(set.enabled))
            print("    ShowLabel:", tostring(set.showLabel))
            print("    Name:", set.name or "(nil)")
            print("    Players in set:", #set.players)
            for j, p in ipairs(set.players) do
                local inGroup = IsPlayerInGroup(p, roster)
                print("      [" .. j .. "]", p, inGroup and "(IN GROUP)" or "(not in group)")
            end
            
            local container = self.containers[i]
            local header = self.headers[i]
            local label = self.labels[i]
            
            print("    Container exists:", tostring(container ~= nil))
            if container then
                print("      Shown:", tostring(container:IsShown()))
                print("      Size:", container:GetWidth(), "x", container:GetHeight())
            end
            
            print("    Header exists:", tostring(header ~= nil))
            if header then
                print("      Shown:", tostring(header:IsShown()))
                local nameListAttr = header:GetAttribute("nameList") or "(nil)"
                print("      nameList attr:", nameListAttr)
                print("      sortMethod:", header:GetAttribute("sortMethod") or "(nil)")
                print("      template:", header:GetAttribute("template") or "(nil)")
                
                -- Count children
                local childCount = 0
                local shownChildren = 0
                for j = 1, 40 do
                    local child = header:GetAttribute("child" .. j)
                    if child then
                        childCount = childCount + 1
                        if child:IsShown() then
                            shownChildren = shownChildren + 1
                        end
                    end
                end
                print("      Children (total):", childCount)
                print("      Children (shown):", shownChildren)
                
                -- List first few children
                for j = 1, math.min(5, childCount) do
                    local child = header:GetAttribute("child" .. j)
                    if child then
                        local unit = child:GetAttribute("unit") or "none"
                        print("        child" .. j .. ":", child:GetName() or "unnamed", "unit=" .. unit, child:IsShown() and "SHOWN" or "hidden")
                    end
                end
            end
            
            print("    Label exists:", tostring(label ~= nil))
            if label then
                print("      Shown:", tostring(label:IsShown()))
                print("      Text:", label:GetText() or "(nil)")
            end
        else
            print("    (set config is nil)")
        end
    end
end

-- Test function - adds player to set 1 and enables it
function PinnedFrames:Test()
    local set = GetSetDB(1)
    if not set then
        print("|cFF00FFFF[DF Pinned]|r Test: No set 1 config found!")
        return
    end
    
    local fullName = GetUnitName("player", true)  -- Returns "Name-Realm"
    
    -- Add player if not already in list
    local found = false
    for _, p in ipairs(set.players) do
        if p == fullName then
            found = true
            break
        end
    end
    
    if not found then
        table.insert(set.players, fullName)
        print("|cFF00FFFF[DF Pinned]|r Test: Added", fullName, "to set 1")
    else
        print("|cFF00FFFF[DF Pinned]|r Test:", fullName, "already in set 1")
    end
    
    -- Enable set 1
    set.enabled = true
    self:SetEnabled(1, true)
    
    -- Update nameList
    self:UpdateHeaderNameList(1)
    
    print("|cFF00FFFF[DF Pinned]|r Test: Set 1 enabled with player")
    print("|cFF00FFFF[DF Pinned]|r Run /dfpinned info to see details")
end

-- ============================================================
-- TEST MODE INTEGRATION
-- Hooks called by TestMode/TestMode.lua when the main Test Mode
-- button is toggled. Populates ENABLED pinned sets with fake data:
--   Boss-mode sets: the real secure boss frames get dfIsTestFrame + fake NPC data
--   Player-mode sets: non-secure test Buttons are created per set container
--                      with fake roster data (names/classes/health)
-- Disabled sets are never touched.
-- ============================================================

-- Returns true if any pinned set is currently in test mode
function PinnedFrames:IsTestModeActive()
    return self.testModeActive == true
end

-- Returns the pinnedFrames sub-table for a specific mode ("raid" or "party").
-- Allows test-mode code to read the raid profile's pinned config while the
-- actual group state is solo/party, and vice versa.
local function GetPinnedDBForMode(isRaidMode)
    local db = isRaidMode and DF:GetRaidDB() or DF:GetDB()
    return db and db.pinnedFrames
end

-- Returns a set's config from the specified mode's profile.
-- (Local forward-declared above so GetSetForPosition can call it.)
function GetSetDBForMode(setIndex, isRaidMode)
    local hlDB = GetPinnedDBForMode(isRaidMode)
    return hlDB and hlDB.sets and hlDB.sets[setIndex]
end

-- Create a single non-secure player-mode test frame parented to a pinned
-- set's test container. Mirrors the pattern used in TestMode/TestFramePool.lua
-- CreateTestFrame so the frame renders identically to live frames.
-- Create a single non-secure "mock" test frame for a pinned set, parented to
-- the set's test container. Handles both player-mode and boss-mode sets —
-- when isBossSet is true, the `isPinnedBossFrame` marker causes
-- DF:UpdateTestFrame to route to boss test data (NPC names via
-- GetTestUnitData(i, isRaid, true)).
local function CreatePlayerTestFrame(setIndex, index, container, isRaidMode, isBossSet)
    local db = isRaidMode and DF:GetRaidDB() or DF:GetDB()
    local frame = CreateFrame(
        "Button",
        "DandersPinnedTest" .. setIndex .. "_" .. index,
        container
    )
    frame:SetSize(db.frameWidth or 120, db.frameHeight or 50)

    frame.index = index
    frame.dfTestIndex = index
    frame.isRaidFrame = isRaidMode
    frame.dfIsTestFrame = true
    frame.dfIsDandersFrame = true
    frame.dfIsPinnedTestFrame = true  -- distinguish from testPartyFrames/testRaidFrames
    frame.isPinnedBossFrame = isBossSet or false
    frame.pinnedSetIndex = setIndex

    -- Fake unit token. For boss-mode test frames we use boss1..boss8 for
    -- consistency; for player mode we use party/raid tokens. UpdateHealthFast
    -- early-returns on dfIsTestFrame so the fake token is never actually
    -- queried via UnitExists/UnitHealth.
    if isBossSet then
        frame.unit = "boss" .. index
    else
        frame.unit = isRaidMode and ("raid" .. index) or (index == 1 and "player" or ("party" .. (index - 1)))
    end

    frame:EnableMouse(true)
    frame:RegisterForClicks("AnyUp")

    if DF.CreateFrameElements then
        DF:CreateFrameElements(frame, isRaidMode)
    end
    if DF.ApplyFrameStyle then
        DF:ApplyFrameStyle(frame)
    end
    if DF.ApplyAuraLayout then
        DF:ApplyAuraLayout(frame, "BUFF")
        DF:ApplyAuraLayout(frame, "DEBUFF")
    end

    frame:Hide()
    return frame
end

-- Attach a drag mover to the test container. Lets the user reposition test
-- frames live during test mode by dragging this handle — updates the
-- TEST MODE'S profile set.position (raid profile when raid test is on).
-- Themed with GetModeColors so raid test uses orange, party test uses blue.
local function AttachTestMover(container, set, isRaidMode, setIndex)
    -- The test drag handle obeys the global unlock, exactly like the live pinned
    -- movers and the main frames: test mode shows the preview frames, but you must
    -- UNLOCK to drag them. SetMoversShown re-syncs these when the lock toggles.
    local shouldShow = PinnedFrames.moversShown == true

    if container.testMover then
        -- Refresh refs + theme colors in case mode flipped
        local tm = container.testMover
        tm.dfSet = set
        tm.dfIsRaidMode = isRaidMode
        tm.dfSetIndex = setIndex
        local colors = GetModeColors(isRaidMode)
        tm.bg:SetColorTexture(unpack(colors.moverBg))
        tm.text:SetText(PinnedSetLabel(set, setIndex, isRaidMode))
        -- Re-theme through the styler so hover/active states pick up the new
        -- mode's accent; restyle re-applies border/inner/text for the current state.
        tm.dfColors = colors
        if tm.dfRestyle then tm.dfRestyle() end
        if tm.dfFitWidth then tm.dfFitWidth() end  -- label width may have changed
        tm:SetShown(shouldShow)
        return
    end

    local colors = GetModeColors(isRaidMode)
    local mover = CreateFrame("Frame", nil, UIParent)
    mover:SetSize(140, 16)
    mover:SetFrameStrata("HIGH")
    mover:SetPoint("BOTTOM", container, "TOP", 0, 2)
    mover.dfSet = set
    mover.dfIsRaidMode = isRaidMode

    mover.bg = mover:CreateTexture(nil, "BACKGROUND")
    mover.bg:SetAllPoints()
    mover.bg:SetColorTexture(unpack(colors.moverBg))

    mover.borderTex = mover:CreateTexture(nil, "BORDER")
    mover.borderTex:SetAllPoints()
    mover.borderTex:SetColorTexture(unpack(colors.moverBorder))
    mover.inner = mover:CreateTexture(nil, "ARTWORK")
    mover.inner:SetPoint("TOPLEFT", 1, -1)
    mover.inner:SetPoint("BOTTOMRIGHT", -1, 1)
    mover.inner:SetColorTexture(unpack(colors.moverBg))

    mover.text = mover:CreateFontString(nil, "OVERLAY")
    DF.GUI:SetSettingsFont(mover.text, 10, "")
    mover.text:SetPoint("CENTER")
    mover.text:SetText(PinnedSetLabel(set, setIndex, isRaidMode))
    mover.text:SetTextColor(unpack(colors.moverText))

    -- Hover highlight + tooltip + active-state styling (reads as clickable).
    StylePinnedHandle(mover, mover.borderTex, mover.inner, mover.text, colors)

    mover:EnableMouse(true)
    mover:RegisterForDrag("LeftButton")
    mover.dfSetIndex = setIndex

    -- Clicking (or finishing a drag on) the test handle points the shared position
    -- panel at this set, matching the live mover.
    mover:HookScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and DF.SetPositionPanelMode and self.dfSetIndex then
            DF.positionPanelPinnedSet = self.dfSetIndex
            DF:SetPositionPanelMode("pinned")
        end
    end)

    local startMouseX, startMouseY, startPosX, startPosY, dragRef, dragW, dragH, dragAnchorTo

    mover:SetScript("OnDragStart", function(self)
        local currentSet = self.dfSet
        if not currentSet then return end
        -- Point the position panel at this set so it tracks the drag live.
        if DF.SetPositionPanelMode and self.dfSetIndex then
            DF.positionPanelPinnedSet = self.dfSetIndex
            DF:SetPositionPanelMode("pinned")
        end
        -- Keep the set's existing anchor reference + capture frame size, so the
        -- helper pins the growth corner consistently (matches the live mover).
        dragRef = (currentSet.position and currentSet.position.point) or GetContainerAnchorPoint(currentSet)
        dragAnchorTo = currentSet.position and currentSet.position.anchorTo
        local ddb = self.dfIsRaidMode and DF:GetRaidDB() or DF:GetDB()
        dragW, dragH = GetSetFrameSize(currentSet, ddb)
        local uiScale = UIParent:GetEffectiveScale()
        startMouseX, startMouseY = GetCursorPosition()
        startMouseX = startMouseX / uiScale
        startMouseY = startMouseY / uiScale
        local p = currentSet.position or { x = 0, y = 0 }
        startPosX = p.x or 0
        startPosY = p.y or 0
        self:SetScript("OnUpdate", function()
            local mx, my = GetCursorPosition()
            local ps = UIParent:GetEffectiveScale()
            mx = mx / ps
            my = my / ps
            local newX = startPosX + (mx - startMouseX)
            local newY = startPosY + (my - startMouseY)
            -- Snap to grid when pinned snap is enabled (its own flag, default off).
            local sdb = DF.GetDB and DF:GetDB()
            if sdb and sdb.pinnedSnapToGrid and DF.SnapToGrid then
                newX, newY = DF:SnapToGrid(newX, newY)
            end
            -- Track the live drag in the DB + panel so the X/Y readouts update.
            currentSet.position = { point = dragRef, x = newX, y = newY, anchorTo = dragAnchorTo }
            PositionPinnedContainer(container, currentSet, currentSet.position, dragW, dragH)
            if DF.UpdatePositionPanel then DF:UpdatePositionPanel() end
        end)
    end)

    mover:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        if not startMouseX then return end
        local currentSet = self.dfSet
        if not currentSet then return end
        local anchor = dragRef or GetContainerAnchorPoint(currentSet)
        local uiScale = UIParent:GetEffectiveScale()
        local mx, my = GetCursorPosition()
        mx = mx / uiScale
        my = my / uiScale
        local finalX = startPosX + (mx - startMouseX)
        local finalY = startPosY + (my - startMouseY)
        -- Snap to grid when pinned snap is enabled (its own flag, default off).
        local sdb = DF.GetDB and DF:GetDB()
        if sdb and sdb.pinnedSnapToGrid and DF.SnapToGrid then
            finalX, finalY = DF:SnapToGrid(finalX, finalY)
        end
        currentSet.position = { point = anchor, x = finalX, y = finalY, anchorTo = dragAnchorTo }
        PositionPinnedContainer(container, currentSet, currentSet.position, dragW, dragH)

        -- Persist raid-set drags through to _realRaidDB (survives overlay rebuilds;
        -- position is never overlay-overridable). Party sets need no mirror.
        if self.dfIsRaidMode then
            local realSet = DF._realRaidDB and DF._realRaidDB.pinnedFrames
                and DF._realRaidDB.pinnedFrames.sets and DF._realRaidDB.pinnedFrames.sets[self.dfSetIndex]
            if realSet then
                realSet.position = { point = anchor, x = finalX, y = finalY, anchorTo = dragAnchorTo }
            end
        end

        if DF.UpdatePositionPanel then DF:UpdatePositionPanel() end
    end)

    mover:SetShown(shouldShow)
    container.testMover = mover
end

-- Ensure the test container for a set exists and is positioned using the
-- specified mode's profile config for that set (so raid test mode while solo
-- anchors at the raid-profile's configured pinned position, not at the
-- party-profile's position). Non-secure frame; can be created in combat.
-- Also attaches a drag mover so the user can reposition test frames live.
function PinnedFrames:EnsureTestContainer(setIndex, set, isRaidMode)
    local container = self.testContainers[setIndex]
    if not container then
        container = CreateFrame(
            "Frame",
            "DandersPinnedTestContainer" .. setIndex,
            UIParent
        )
        container:SetFrameStrata("MEDIUM")
        self.testContainers[setIndex] = container
    end

    local db = isRaidMode and DF:GetRaidDB() or DF:GetDB()
    local frameWidth, frameHeight = GetSetFrameSize(set, db)
    container:SetSize(frameWidth, frameHeight)

    -- Position identically to the live path (PositionPinnedContainer): pin the
    -- growth corner so the testCount-sized preview lands where the real (visible-
    -- count-sized) frames will, with pos.point as the screen reference.
    local pos = set.position or {}
    local scale = GetSetScale(set, db)  -- mode-explicit: cross-mode test previews
    container:SetScale(scale)
    PositionPinnedContainer(container, set, pos, frameWidth, frameHeight)
    container:Show()

    AttachTestMover(container, set, isRaidMode, setIndex)

    -- Dedicated test label (parented to UIParent for scale independence).
    -- Anchored to the test container so it follows the test mover when
    -- dragged. Uses the test-mode profile's set name so it always reflects
    -- what's on screen (even in cross-mode like "raid test while in party").
    local testLabel = container.testLabel
    if not testLabel then
        testLabel = UIParent:CreateFontString(
            "DandersPinnedTest" .. setIndex .. "Label",
            "OVERLAY"
        )
        DF.GUI:SetSettingsFont(testLabel, 12, "")
        testLabel:SetTextColor(0.8, 0.8, 1.0)
        container.testLabel = testLabel
    end
    testLabel:ClearAllPoints()
    testLabel:SetPoint("BOTTOM", container, "TOP", 0, 2)
    local labelText = set.name
    if not labelText or labelText == "" then
        labelText = "Pinned " .. setIndex
    end
    testLabel:SetText(labelText)
    testLabel:SetShown(set.showLabel)

    return container
end

-- Make sure the player-mode test frame pool for a set exists and is at least
-- `count` frames large. Frames are created lazily on demand, parented to the
-- set's test container (which lives at the test-mode profile's position).
function PinnedFrames:EnsurePlayerTestFramePool(setIndex, count, isRaidMode, isBossSet)
    local container = self.testContainers[setIndex]
    if not container then return end
    if count < 1 then count = 1 end
    -- Boss mode caps at 8 (WoW API limit); raid player sets at 40 (max raid);
    -- party player sets at 5 (a party can't exceed 5).
    local cap = isBossSet and 8 or (isRaidMode and 40 or 5)
    if count > cap then count = cap end

    self.testFrames[setIndex] = self.testFrames[setIndex] or {}
    local pool = self.testFrames[setIndex]

    for i = 1, count do
        if not pool[i] then
            pool[i] = CreatePlayerTestFrame(setIndex, i, container, isRaidMode, isBossSet)
        else
            -- Reparent + re-apply state in case test mode or set frameType
            -- flipped since last Enter.
            pool[i]:SetParent(container)
            local db = isRaidMode and DF:GetRaidDB() or DF:GetDB()
            local setDB = GetSetDBForMode(setIndex, isRaidMode)
            local fw, fh = GetSetFrameSize(setDB, db)
            pool[i].dfPinnedWidth, pool[i].dfPinnedHeight = fw, fh
            pool[i].dfPinnedBorderDB = GetSetBorderDB(setDB, GetSetBaselineDB(setDB, db))
            pool[i].dfPinnedEffDB = setDB and BuildPinnedEffDB(db, setDB.hideAuras, setDB.hideIcons) or nil
            pool[i].dfPinnedHideAuras = setDB and setDB.hideAuras
            pool[i].dfAuraPresetOverride = setDB and setDB.auraDesignerPreset
            pool[i].dfTextPresetOverride = setDB and setDB.textDesignerPreset
            pool[i]:SetSize(fw, fh)
            pool[i].isRaidFrame = isRaidMode
            pool[i].isPinnedBossFrame = isBossSet or false
        end
    end
end

-- Position the N player-mode test frames for a set using layout math from
-- the test-mode profile's set config.
function PinnedFrames:ApplyPlayerTestLayout(setIndex, set, isRaidMode)
    local container = self.testContainers[setIndex]
    local pool = self.testFrames[setIndex]
    if not set or not container or not pool then return end

    local db = isRaidMode and DF:GetRaidDB() or DF:GetDB()
    local frameWidth, frameHeight = GetSetFrameSize(set, db)
    local borderDB = GetSetBorderDB(set, GetSetBaselineDB(set, db))
    local effDB = BuildPinnedEffDB(db, set.hideAuras, set.hideIcons)

    local hSpacing, vSpacing = GetSetSpacing(set, db)
    local unitsPerRow = set.unitsPerRow or 5
    local frameAnchor = set.frameAnchor or "START"
    local columnAnchor = set.columnAnchor or "START"
    local horizontal = GetSetGrowDirection(set) == "HORIZONTAL"
    local anchor = GetContainerAnchorPoint(set)

    local n = set.testCount or 3
    -- Boss: 8 (WoW limit); raid player: 40 (max raid); party player: 5 (party max).
    local maxN = IsBossSet(set) and 8 or (isRaidMode and 40 or 5)
    if n < 1 then n = 1 end
    if n > maxN then n = maxN end

    -- Size container to fit N frames in the set's layout (mirrors
    -- ResizeContainer for real pinned sets). Frames anchor inside at the
    -- computed `anchor` corner, so the container needs to be the full grid
    -- dimension — otherwise the anchor corner sits in the wrong screen spot.
    local rows = math.ceil(n / unitsPerRow)
    local cols = math.min(n, unitsPerRow)
    local containerWidth, containerHeight
    if horizontal then
        containerWidth = cols * frameWidth + math.max(0, cols - 1) * hSpacing
        containerHeight = rows * frameHeight + math.max(0, rows - 1) * vSpacing
    else
        containerWidth = rows * frameWidth + math.max(0, rows - 1) * hSpacing
        containerHeight = cols * frameHeight + math.max(0, cols - 1) * vSpacing
    end
    container:SetSize(math.max(containerWidth, 50), math.max(containerHeight, 30))

    for i = 1, 40 do
        local f = pool[i]
        if f then
            if i <= n then
                f.dfPinnedWidth, f.dfPinnedHeight = frameWidth, frameHeight
                f.dfPinnedBorderDB = borderDB
                f.dfPinnedEffDB = effDB
                f.dfPinnedHideAuras = set.hideAuras
                f.dfAuraPresetOverride = set.auraDesignerPreset
                f.dfTextPresetOverride = set.textDesignerPreset
                f:SetSize(frameWidth, frameHeight)
                f.isRaidFrame = isRaidMode

                local slotIndex = i - 1
                local row = math.floor(slotIndex / unitsPerRow)
                local col = slotIndex - row * unitsPerRow

                local xStep = frameWidth + hSpacing
                local yStep = frameHeight + vSpacing
                local xOff, yOff
                if horizontal then
                    if frameAnchor == "END" then xOff = -col * xStep else xOff = col * xStep end
                    if columnAnchor == "END" then yOff = row * yStep else yOff = -row * yStep end
                else
                    if frameAnchor == "END" then yOff = col * yStep else yOff = -col * yStep end
                    if columnAnchor == "END" then xOff = -row * xStep else xOff = row * xStep end
                end

                f:ClearAllPoints()
                f:SetPoint(anchor, container, anchor, xOff, yOff)
                f:Show()
            else
                f:Hide()
            end
        end
    end
end

-- Hide all player-mode test frames and the test container for a set
function PinnedFrames:HidePlayerTestFrames(setIndex)
    local pool = self.testFrames[setIndex]
    if pool then
        for i = 1, #pool do
            if pool[i] then pool[i]:Hide() end
        end
    end
    local container = self.testContainers[setIndex]
    if container then
        if container.testMover then container.testMover:Hide() end
        if container.testLabel then container.testLabel:Hide() end
        container:Hide()
    end
end

-- Called when Test Mode is toggled ON. Renders fake non-secure test frames
-- for every enabled pinned set in the TEST MODE's profile. Works uniformly
-- for player-mode and boss-mode sets — the only difference is the fake
-- name source (roster names vs NPC names) and the max frame count. Real
-- secure frames (pinned headers, boss frames) are NEVER touched — they stay
-- at their live positions, unaffected.
function PinnedFrames:EnterTestMode()
    if not self.initialized then return end
    if InCombatLockdown() then return end

    -- Pick the active test mode for sizing/data. Raid wins if both are on.
    -- IMPORTANT: testModeActive is only set AFTER this validation — setting it
    -- before the neither-mode early-return could leave it stuck true (e.g. an
    -- ApplyLayoutSettings Exit+Enter cycle after the global flags went off),
    -- which permanently disables Hide-from-Main and the solo gate (both treat
    -- testModeActive as "previewing").
    local isRaidMode
    if DF.raidTestMode then
        isRaidMode = true
    elseif DF.testMode then
        isRaidMode = false
    else
        return
    end

    self.testModeActive = true
    local actualModeMatches = (isRaidMode == IsInRaid())

    -- Hide ALL real (live-mode) pinned frames while any test mode is active — the
    -- test frames ARE the preview, so the real party/raid pinned must not leak
    -- through. Without this an enabled party set's real frame shows during raid
    -- test mode (its set index isn't in the raid test loop below, so the per-set
    -- hide never reaches it). ExitTestMode restores them per live enabled state.
    for setIndex = 1, PinnedFrames.MAX_SETS do
        if self.headers[setIndex] then self.headers[setIndex]:Hide() end
        local rc = self.containers[setIndex]
        if rc then
            if rc.mover then rc.mover:Hide() end
            if rc.bg then rc.bg:Hide() end
            if rc.border then rc.border:Hide() end
        end
        if self.labels[setIndex] then self.labels[setIndex]:Hide() end
    end

    for setIndex = 1, PinnedFrames.MAX_SETS do
        local set = GetSetDBForMode(setIndex, isRaidMode)
        if set and set.enabled then
            local isBossSet = IsBossSet(set)
            local n = set.testCount or 3
            local cap = isBossSet and 8 or (isRaidMode and 40 or 5)
            if n < 1 then n = 1 end
            if n > cap then n = cap end

            -- When the test mode matches the actual group mode, hide the
            -- real pinned header (if any) so it doesn't render alongside
            -- fake frames. Header stays untouched in cross-mode (it's
            -- already at a different position / already hidden).
            if actualModeMatches and self.headers[setIndex] and not isBossSet then
                self.headers[setIndex]:Hide()
            end
            -- Hide the REAL pinned container visuals (mover, bg, border,
            -- label) when test mode matches — otherwise the user sees stale
            -- chrome (blue box + label) anchored at the real container's
            -- position while dragging the test mover. The test container
            -- has its own dedicated mover + label that follow the test
            -- frames. In cross-mode we don't touch the real visuals (they
            -- may be in use by real frames at a different position).
            if actualModeMatches then
                local realContainer = self.containers[setIndex]
                if realContainer then
                    if realContainer.mover then
                        realContainer.mover:Hide()
                    end
                    if realContainer.bg then
                        realContainer.bg:Hide()
                    end
                    if realContainer.border then
                        realContainer.border:Hide()
                    end
                end
                local realLabel = self.labels[setIndex]
                if realLabel then
                    realLabel:Hide()
                end
            end

            self:EnsureTestContainer(setIndex, set, isRaidMode)

            self:EnsurePlayerTestFramePool(setIndex, n, isRaidMode, isBossSet)
            self:ApplyPlayerTestLayout(setIndex, set, isRaidMode)

            local pool = self.testFrames[setIndex]
            if pool then
                for i = 1, n do
                    if pool[i] and DF.UpdateTestFrame then
                        DF:UpdateTestFrame(pool[i], i, true)
                    end
                end
            end
        end
    end
end

-- Called when Test Mode is toggled OFF. Hide all pinned test frames and
-- their containers, and show the real player-mode header again (whose
-- visibility is driven by actual group membership). No secure frame
-- manipulation needed — Test Mode never touched them.
function PinnedFrames:ExitTestMode()
    if InCombatLockdown() then
        -- The global test flags may already be off (HideTestFrames runs in
        -- combat) — if we just drop this, testModeActive sticks true and
        -- Hide-from-Main + the solo gate stay disabled until /reload. Queue a
        -- re-run for PLAYER_REGEN_ENABLED instead.
        self.pendingExitTestMode = true
        return
    end
    self.pendingExitTestMode = nil
    self.testModeActive = false

    -- Hide all test frames + test containers (both mode profiles)
    for setIndex = 1, PinnedFrames.MAX_SETS do
        self:HidePlayerTestFrames(setIndex)
    end

    -- Restore real headers for player-mode sets in the current mode (we may
    -- have hidden them when entering test mode in the same mode).
    for setIndex = 1, PinnedFrames.MAX_SETS do
        local set = GetSetDB(setIndex)
        -- Effective visibility includes the party solo gate (mirror SetEnabled):
        -- the mover/label are parented to UIParent, so restoring them for a
        -- solo-hidden set would float chrome over an invisible container.
        local visible = set and set.enabled and PinnedSoloAllowed(set)
        if set and not IsBossSet(set) and visible and self.headers[setIndex] then
            self.headers[setIndex]:Show()
        end
        -- Restore real pinned container visuals (mover, bg, border, label)
        -- based on current set state. Mover/bg/border follow the unlocked
        -- state; label follows showLabel. Disabled sets stay hidden.
        if set then
            local realContainer = self.containers[setIndex]
            if realContainer then
                -- Re-apply the saved position: it may have changed during test mode
                -- (e.g. the user dragged the test frame). The live container was last
                -- placed at create/layout time, so without this it keeps the stale
                -- spot until a /reload re-creates it.
                if set.position then
                    local cw, ch = GetSetFrameSize(set, GetPinnedModeDB())
                    PositionPinnedContainer(realContainer, set, set.position, cw, ch)
                end
                if realContainer.mover then
                    realContainer.mover:SetShown(visible and self.moversShown)
                end
                if realContainer.bg then
                    realContainer.bg:SetShown(visible and self.moversShown)
                end
                if realContainer.border then
                    realContainer.border:SetShown(visible and self.moversShown)
                end
            end
            local realLabel = self.labels[setIndex]
            if realLabel then
                realLabel:SetShown(visible and set.showLabel)
            end
        end
    end

    -- Legacy: no-op in the new design, but other code paths may still have
    -- cleared flags on real boss frames. Defensively clear to avoid stale
    -- dfIsTestFrame leaking from an older-session toggle.
    C_Timer.After(0.15, function()
        for setIndex = 1, PinnedFrames.MAX_SETS do
            local frames = self.bossFrames[setIndex]
            if frames then
                for i = 1, 8 do
                    local f = frames[i]
                    if f and f:IsShown() and f.unit and DF.FullFrameRefresh then
                        DF:FullFrameRefresh(f)
                    end
                end
            end
        end
    end)
end

-- Apply fake test data to all currently-shown pinned test frames. Called
-- by the Test Mode animation ticker so health bars stay in sync with
-- DF.TestData.animationPhase when testAnimateHealth is on.
function PinnedFrames:UpdateTestFrames()
    if not self.testModeActive then return end

    for setIndex = 1, PinnedFrames.MAX_SETS do
        local pool = self.testFrames[setIndex]
        if pool then
            for i = 1, #pool do
                local f = pool[i]
                if f and f:IsShown() and f.dfTestIndex then
                    if DF.UpdateTestFrame then
                        DF:UpdateTestFrame(f, f.dfTestIndex)
                    end
                end
            end
        end
    end
end

-- ============================================================
-- TIMED BOSS SPAWN TEST
-- Schedules show/hide of individual boss slots over time, for
-- verifying slot-allocator behaviour without being in an encounter.
-- Does NOT populate unit data — bossN units still don't exist, so
-- health/aura rendering stays empty. Purely a layout testbed.
-- ============================================================

-- Predefined sequence used by `/dfpinned bossspawn demo`.
-- Format: { { bossIndex, "+"|"-", secondsFromStart }, ... }
local BOSS_SPAWN_DEMO = {
    { 1, "+",  0.5 },
    { 2, "+",  2.0 },
    { 3, "+",  4.0 },
    { 2, "-",  6.0 },
    { 4, "+",  7.5 },
    { 1, "-",  9.5 },
    { 5, "+", 11.0 },
    { 3, "-", 13.0 },
    { 6, "+", 14.5 },
    { 4, "-", 16.5 },
    { 5, "-", 18.5 },
    { 6, "-", 20.0 },
}

-- Parse "1+:0,3+:2,1-:5,4+:7" into { { idx, sign, t }, ... }.
-- Returns nil, errorString on parse error.
local function ParseBossSpawnScript(script)
    if type(script) ~= "string" or script == "" then
        return nil, "empty script"
    end
    local steps = {}
    for chunk in string.gmatch(script, "[^,]+") do
        local chunkTrim = chunk:match("^%s*(.-)%s*$")
        local idx, sign, t = chunkTrim:match("^(%d+)([%+%-]):(%-?%d+%.?%d*)$")
        if not idx then
            return nil, "bad step '" .. chunkTrim .. "' (expected form '1+:0')"
        end
        idx = tonumber(idx)
        t = tonumber(t)
        if not idx or idx < 1 or idx > 8 then
            return nil, "boss index " .. tostring(idx) .. " out of range 1..8"
        end
        if not t or t < 0 then
            return nil, "negative or invalid time in '" .. chunkTrim .. "'"
        end
        table.insert(steps, { idx, sign, t })
    end
    table.sort(steps, function(a, b) return a[3] < b[3] end)
    return steps
end

-- Generation counter lets StopBossSpawn cancel pending timers without
-- actually cancelling them (C_Timer doesn't expose cancellation); stale
-- callbacks compare their captured gen to the current one and no-op.
PinnedFrames.bossSpawnGeneration = 0

-- Flip a frame's visibility state driver to a literal show/hide value.
-- Literal values are NOT combat-restricted; only macro-conditional strings are.
local function ForceBossFrameVisible(setIndex, bossIndex, show)
    -- RegisterStateDriver is a protected attribute write; the spawn script's
    -- C_Timer steps can land mid-combat -> ADDON_ACTION_BLOCKED. Debug-only
    -- path, so just drop the step (the script is for out-of-combat preview).
    if InCombatLockdown() then return end
    local frames = PinnedFrames.bossFrames[setIndex]
    if not frames then return end
    local f = frames[bossIndex]
    if not f then return end
    RegisterStateDriver(f, "visibility", show and "show" or "hide")
end

-- Restore real `[@bossN,help]show;hide` drivers on all boss-mode sets.
local function RestoreBossFrameDrivers()
    for setIndex = 1, PinnedFrames.MAX_SETS do
        local set = GetSetDB(setIndex)
        if set and set.enabled and IsBossSet(set) then
            local frames = PinnedFrames.bossFrames[setIndex]
            if frames then
                for i = 1, 8 do
                    local f = frames[i]
                    if f then
                        RegisterStateDriver(f, "visibility",
                            "[@boss" .. i .. ",help]show;hide")
                    end
                end
            end
        end
    end
end

-- Schedule each step via C_Timer.After, keyed to a captured generation.
function PinnedFrames:RunBossSpawnScript(steps)
    self.bossSpawnGeneration = self.bossSpawnGeneration + 1
    local myGen = self.bossSpawnGeneration

    -- Start from a clean slate so the script's sequence is deterministic.
    for setIndex = 1, PinnedFrames.MAX_SETS do
        local set = GetSetDB(setIndex)
        if set and set.enabled and IsBossSet(set) then
            for i = 1, 8 do
                ForceBossFrameVisible(setIndex, i, false)
            end
        end
    end

    local maxT = 0
    for _, step in ipairs(steps) do
        local bossIndex, sign, t = step[1], step[2], step[3]
        if t > maxT then maxT = t end
        C_Timer.After(t, function()
            if PinnedFrames.bossSpawnGeneration ~= myGen then return end
            for setIndex = 1, PinnedFrames.MAX_SETS do
                local set = GetSetDB(setIndex)
                if set and set.enabled and IsBossSet(set) then
                    ForceBossFrameVisible(setIndex, bossIndex, sign == "+")
                end
            end
        end)
    end

    -- Auto-exit 2s after the last step so drivers restore themselves.
    C_Timer.After(maxT + 2, function()
        if PinnedFrames.bossSpawnGeneration ~= myGen then return end
        PinnedFrames:StopBossSpawn(true)
    end)
end

-- Cancel any pending scripted step and restore real drivers.
function PinnedFrames:StopBossSpawn(auto)
    self.bossSpawnGeneration = self.bossSpawnGeneration + 1
    RestoreBossFrameDrivers()
    if auto then
        print("|cFF00FFFF[DF Pinned]|r bossspawn script finished; real drivers restored")
    else
        print("|cFF00FFFF[DF Pinned]|r bossspawn OFF; real drivers restored")
    end
end

-- Public entry point.
--   nil | "" | "off"      → cancel any running script
--   "demo"                → run the built-in 20s sequence
--   custom script string  → parse and run
function PinnedFrames:SetBossSpawnTest(arg)
    if not arg or arg == "" or arg == "off" then
        self:StopBossSpawn(false)
        return
    end

    local anyBossSet = false
    for setIndex = 1, PinnedFrames.MAX_SETS do
        local set = GetSetDB(setIndex)
        if set and set.enabled and IsBossSet(set) then
            anyBossSet = true
            break
        end
    end
    if not anyBossSet then
        print("|cFF00FFFF[DF Pinned]|r No enabled boss-mode sets found. Enable a pinned set and set Frame Type to 'Friendly Boss NPCs' first.")
        return
    end

    local steps
    if arg == "demo" then
        steps = BOSS_SPAWN_DEMO
    else
        local parsed, err = ParseBossSpawnScript(arg)
        if not parsed then
            print("|cFF00FFFF[DF Pinned]|r bossspawn parse error: " .. err)
            print("|cFF00FFFF[DF Pinned]|r expected: '1+:0,3+:2,1-:5' (idx <+|->:<seconds>)")
            return
        end
        steps = parsed
    end

    print(format("|cFF00FFFF[DF Pinned]|r bossspawn running %d steps", #steps))
    self:RunBossSpawnScript(steps)
end

-- Test mode for boss frames: force N boss frames visible so the secure
-- positioning can be verified without being in an encounter. Runs out of
-- combat only (needs to unregister/re-register state drivers). Passing
-- nil/0/"off" exits test mode and restores the normal `[@bossN,help]` drivers.
-- Pass visibleCount 1..8 for fixed count, or the string "dyn" for
-- modifier-driven test (boss1 always, boss2-3 with shift, boss4-5 with
-- ctrl, boss6-8 with alt — lets you toggle frames in/out of combat to
-- verify the secure reposition snippet runs correctly).
function PinnedFrames:SetBossTestMode(visibleCount)
    if InCombatLockdown() then
        print("|cFF00FFFF[DF Pinned]|r Boss test mode cannot toggle during combat")
        return
    end

    local isDyn = (visibleCount == "dyn")
    if not isDyn then
        visibleCount = tonumber(visibleCount) or 0
        if visibleCount < 0 then visibleCount = 0 end
        if visibleCount > 8 then visibleCount = 8 end
    end

    self.bossTestMode = isDyn or (visibleCount > 0)
    self.bossTestCount = visibleCount

    local anyToggled = false
    for setIndex = 1, PinnedFrames.MAX_SETS do
        local set = GetSetDB(setIndex)
        if set and set.enabled and IsBossSet(set) then
            local frames = self.bossFrames[setIndex]
            if frames then
                if isDyn then
                    -- Modifier-driven dynamic test: lets you add/remove frames
                    -- with modifier keys, IN OR OUT OF COMBAT. State drivers
                    -- (including mod: conditions) evaluate continuously; when
                    -- they change, the handler's reposition snippet runs.
                    --   boss1:       always visible
                    --   boss2, boss3: visible while holding SHIFT
                    --   boss4, boss5: visible while holding CTRL
                    --   boss6, boss7, boss8: visible while holding ALT
                    local conditions = {
                        [1] = "show",
                        [2] = "[mod:shift]show;hide",
                        [3] = "[mod:shift]show;hide",
                        [4] = "[mod:ctrl]show;hide",
                        [5] = "[mod:ctrl]show;hide",
                        [6] = "[mod:alt]show;hide",
                        [7] = "[mod:alt]show;hide",
                        [8] = "[mod:alt]show;hide",
                    }
                    for i = 1, 8 do
                        local f = frames[i]
                        if f then
                            RegisterStateDriver(f, "visibility", conditions[i])
                        end
                    end
                elseif visibleCount > 0 then
                    -- Fixed-count test: literal state values, no macro eval.
                    -- State driver strings that don't start with `[` are used
                    -- as the literal state value.
                    for i = 1, 8 do
                        local f = frames[i]
                        if i <= visibleCount then
                            RegisterStateDriver(f, "visibility", "show")
                        else
                            RegisterStateDriver(f, "visibility", "hide")
                        end
                    end
                else
                    -- Test mode off: restore real conditions on the visibility driver
                    for i = 1, 8 do
                        local f = frames[i]
                        if f then
                            RegisterStateDriver(f, "visibility", "[@boss" .. i .. ",help]show;hide")
                        end
                    end
                end
                anyToggled = true
            end
        end
    end

    if not anyToggled then
        print("|cFF00FFFF[DF Pinned]|r No enabled boss-mode sets found. Enable a pinned set and set Frame Type to 'Friendly Boss NPCs' first.")
    elseif isDyn then
        print("|cFF00FFFF[DF Pinned]|r Boss test mode ON (dynamic): boss1 always; +2,3 with SHIFT; +4,5 with CTRL; +6,7,8 with ALT. Works in combat. Run '/dfpinned bosstest off' to exit.")
    elseif visibleCount > 0 then
        print(format("|cFF00FFFF[DF Pinned]|r Boss test mode ON: showing %d boss frames. Run '/dfpinned bosstest off' to exit.", visibleCount))
    else
        print("|cFF00FFFF[DF Pinned]|r Boss test mode OFF: restored real state drivers")
    end
end

-- Slash command for debug
SLASH_DFPINNED1 = "/dfpinned"
SlashCmdList["DFPINNED"] = function(msg)
    if msg == "info" then
        PinnedFrames:DebugPrint()
    elseif msg == "reinit" then
        PinnedFrames:Reinitialize()
        print("|cFF00FFFF[DF Pinned]|r Reinitialized")
    elseif msg == "test" then
        PinnedFrames:Test()
    elseif msg and msg:match("^bosstest") then
        -- "/dfpinned bosstest 3" | "/dfpinned bosstest dyn" | "/dfpinned bosstest off"
        local arg = msg:match("^bosstest%s+(%S+)")
        if arg == "off" or arg == "0" or arg == nil then
            PinnedFrames:SetBossTestMode(0)
        elseif arg == "dyn" then
            PinnedFrames:SetBossTestMode("dyn")
        else
            PinnedFrames:SetBossTestMode(tonumber(arg) or 0)
        end
    elseif msg and msg:match("^bossspawn") then
        local arg = msg:match("^bossspawn%s+(.+)$")
        PinnedFrames:SetBossSpawnTest(arg)
    else
        print("|cFF00FFFF[DF Pinned]|r Commands:")
        print("  info - Show detailed debug info (one-shot; pinned frame state dump)")
        print("  test - Add player to set 1 and enable")
        print("  bosstest <N> - Show N boss frames to test secure positioning (1-8, 'off' to exit)")
        print("  bosstest dyn - Modifier-driven test: boss1 always, +2,3 SHIFT, +4,5 CTRL, +6,7,8 ALT (works in combat)")
        print("  bossspawn demo - Run a 20s simulated spawn/despawn sequence for layout testing")
        print("  bossspawn <script> - Custom timed script, e.g. '1+:0,3+:2,1-:5'")
        print("  bossspawn off - Cancel any running bossspawn script")
        print("  reinit - Reinitialize frames")
        print("  (Continuous debug output is routed through the Debug Console under the 'PINNED' category — use /df console)")
    end
end
