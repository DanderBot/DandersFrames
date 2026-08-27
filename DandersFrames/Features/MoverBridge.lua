local addonName, DF = ...

-- ============================================================
-- MOVERBRIDGE
-- Registers DF's party and raid containers with DandersMover-1.0.
-- ============================================================
-- The lib is OPTIONAL. Nothing past the guard below runs when it is absent, and DF's own
-- apply path (Frames/Position.lua) reads point/x/y from the record and ignores `anchor`,
-- so the lib-absent output is byte-identical to today's.
--
-- DF owns the record; the lib owns the maths. It mutates the record in place and calls
-- onChanged, which funnels the write through DF:SetPositionRecord and then re-runs DF's
-- own Update*ContainerPosition. No SetPoint in this file.

local Mover = LibStub and LibStub("DandersMover-1.0", true)
if not Mover then return end

local L = DF.L
local UIParent, hooksecurefunc = UIParent, hooksecurefunc
local pcall, geterrorhandler, ipairs, wipe = pcall, geterrorhandler, ipairs, wipe
local max, min, format = math.max, math.min, string.format
local IsInRaid, CreateFrame, C_Timer = IsInRaid, CreateFrame, C_Timer
local InCombatLockdown = InCombatLockdown

local ADDON_KEY = "DandersFrames"

-- Forward declaration: the pinned element key for a mode's set at index i. Defined in
-- PINNED SETS below, next to PINNED_KEY, but SessionFilter (above it) needs it too.
local keyForSet

-- PERF instrumentation (debug-gated: /df debug on, category "PERF"). Deltas of
-- debugprofilestop() around the synchronous blocks of the unlock/lock paths, so
-- an in-game hitch can be attributed to the block that actually spent the time.
-- Kept permanently: near-zero cost when debug is off.
local debugprofilestop = debugprofilestop
local function perfStart()
    return DF.DebugActive and DF:DebugActive("PERF") and debugprofilestop() or nil
end
local function perfLog(t0, label)
    if t0 then DF:Debug("PERF", "%s %.1fms", label, debugprofilestop() - t0) end
end

local Bridge = { claimed = {} }
DF.MoverBridge = Bridge

-- Which scope the pending unlock is editing. DF:UnlockFrames / DF:UnlockRaidFrames set
-- this immediately before Mover:Unlock; the Unlocked callback reads it once and clears it.
-- Without it a party unlock also threw the raid test frames on screen (and vice versa).
Bridge.requestedScope = nil

function Bridge:RequestScope(scope)
    self.requestedScope = (scope == "raid") and "raid" or "party"
end

function Bridge:IsAvailable()
    return Mover:IsEnabled(ADDON_KEY) and true or false
end

-- ============================================================
-- RELEVANCE
-- ============================================================
-- Is a scope's frames "the thing on screen" right now? Group type, overridden by the
-- scope DF asked the lib to open (RequestScope, cleared by Unlocked) and then by the
-- scope this session claimed (claimScope, below) -- which is what carries the answer
-- for the rest of the session. Test mode covers the preview case.
function Bridge:IsScopeRelevant(scope)
    scope = (scope == "raid") and "raid" or "party"
    if self.requestedScope == scope then return true end
    if self.claimed[scope] then return true end
    if DF.IsTestModeActive and DF:IsTestModeActive(scope) then return true end
    return (scope == "raid") == (IsInRaid() and true or false)
end

-- The Unlock filter for DF:UnlockFrames ("party") / DF:UnlockRaidFrames ("raid"): only
-- these keys get proxies, and they are forced relevant so raid frames can be edited
-- solo. The list is what the LEGACY unlock showed handles for: the container plus
-- every EXISTING, ENABLED pinned set of that mode, and for party the two
-- targeted displays when their feature is on. A disabled set or feature has nothing
-- on screen to frame, so it is not listed.
--
-- The user's per-element toggles in /mover config then PRUNE that list -- including the
-- container key, which is just one element among the rest. The lib prunes disabled keys
-- itself (Registry:IsInSession, "toggle wins"), so this is not what keeps them off
-- screen; it is what lets the callers see when NOTHING is left to edit, which is the
-- only case an unlock should refuse.
function Bridge:SessionFilter(scope)
    scope = (scope == "raid") and "raid" or "party"
    local candidates = { scope }
    local pf = DF.PinnedFrames
    if pf and pf.GetSetForMode then
        for i = 1, (pf.MAX_SETS or 0) do
            local set = pf:GetSetForMode(i, scope == "raid")
            if set and set.enabled then
                -- Keyed by uid (keyForSet), not by index -- see PINNED SETS below.
                local key = keyForSet(scope, i)
                if key then candidates[#candidates + 1] = key end
            end
        end
    end
    if scope == "party" then
        local db = DF.GetPersonalTargetedDB and DF:GetPersonalTargetedDB() or DF:GetDB()
        if db and db.personalTargetedSpellEnabled then candidates[#candidates + 1] = "personalTargeted" end
        local pdb = DF:GetDB("party")
        if pdb and pdb.targetedListEnabled then candidates[#candidates + 1] = "targetedList" end
    end
    local keys = {}
    for _, key in ipairs(candidates) do
        if Mover:IsEnabled(ADDON_KEY, key) then keys[#keys + 1] = key end
    end
    return { addon = ADDON_KEY, keys = keys }
end

-- ============================================================
-- PARTY VISIBLE RECT
-- ============================================================
-- DF.container is created 500x200 (Frames/Init.lua:76) and then RESIZED from four
-- different places (Position.lua, Init.lua, Headers.lua, Core.lua), so its own size is
-- sometimes right and sometimes a stale creation value. The proxy has to frame what the
-- user actually sees, so union the shown party frames instead.
--
-- ⚠ Iterates the header's child1..child5 attributes rather than DF:GetPartyFrame(i):
-- GetPartyFrame (Headers.lua:4732) matches unit == "partyN" and so NEVER returns the
-- PLAYER's frame, which would leave the box short by one frame in every party.
-- When test mode is previewing (which a mover session always is -- see the Unlocked
-- callback), the live header is empty and the visible frames are the separate
-- non-secure pool in DF.testPartyFrames (DandersFrames_Options/TestMode/TestFramePool.lua).

local function frameRect(f)
    if not f or not f.IsShown or not f:IsShown() then return nil end
    local cx, cy = f:GetCenter()
    if not cx then return nil end
    local w, h = f:GetSize()
    if not w or w <= 0 or h <= 0 then return nil end
    local ratio = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local ux, uy = UIParent:GetCenter()
    return cx * ratio - ux, cy * ratio - uy, w * ratio, h * ratio
end

local function union(acc, f)
    local cx, cy, w, h = frameRect(f)
    if not cx then return acc end
    local l, r, b, t = cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2
    if not acc then return { l = l, r = r, b = b, t = t } end
    acc.l, acc.r = min(acc.l, l), max(acc.r, r)
    acc.b, acc.t = min(acc.b, b), max(acc.t, t)
    return acc
end

-- The visible extent of the party frames in UIParent units from UIParent CENTER.
-- nil when no party frame is on screen (neither test frames nor live header children):
-- the lib then treats the party frames as an unavailable anchor target and holds any
-- children anchored to them, and falls through to the def's getSize for the proxy.
function DF:GetPartyVisibleRect()
    local acc
    if DF.IsTestModeActive and DF:IsTestModeActive("party") and DF.testPartyFrames then
        for i = 0, 4 do acc = union(acc, DF.testPartyFrames[i]) end
    end
    if not acc and DF.partyHeader then
        for i = 1, 5 do acc = union(acc, DF.partyHeader:GetAttribute("child" .. i)) end
    end
    if not acc then return nil end
    return { x = (acc.l + acc.r) / 2, y = (acc.b + acc.t) / 2,
             w = acc.r - acc.l,       h = acc.t - acc.b }
end

-- ============================================================
-- RECT HELPERS
-- ============================================================
-- Shared by the movable element and by the "group" anchor target below, so the thing
-- other addons anchor to is measured exactly like the thing the user drags.

local function partyRect()
    return DF:GetPartyVisibleRect()
end

-- nil when the raid frames are not meaningfully on screen. That is the lib's "not
-- available" signal: nobody may snap to the raid frames while they are not up, and a
-- frame already anchored to them holds its last position instead of jumping to a stale
-- rect (DandersMover Registry:IsTargetAvailable).
local function raidRect()
    local r = DF.raidContainer
    if not r then return nil end
    local db = DF:GetRaidDB()
    local s = db.frameScale or 1

    -- Test mode previews the raid frames in a separate non-secure container
    -- (DandersFrames_Options/TestMode/TestFramePool.lua:46). The live container is empty
    -- then, so measure what the user can actually see. Guarded: that container only
    -- exists once the load-on-demand companion is in.
    local test = DF.testRaidContainer
    if DF.IsTestModeActive and DF:IsTestModeActive("raid") and test and test:IsShown() then
        local cx, cy, w, h = frameRect(test)
        if not cx then return nil end
        return { x = cx, y = cy, w = w, h = h }
    end

    if not r:IsShown() then return nil end

    -- anchor + ComputeRaidMainGroupAnchorOffset is EXACTLY what the container, the
    -- mover and the test container already apply (Position.lua:2313-2359), so the
    -- proxy frames the main group with no change to DF's apply logic. The lib applies
    -- a drag as a DELTA to the record (Session.lua DragDelta), so the constant offset
    -- can never accumulate.
    local ax, ay = 0, 0
    if DF.ComputeRaidMainGroupAnchorOffset then
        ax, ay = DF:ComputeRaidMainGroupAnchorOffset()
    end
    local rec = DF:GetPositionRecord("raid")
    local w, h = r:GetSize()
    if not w or w <= 0 then return nil end
    return { x = (rec.x or 0) + ax, y = (rec.y or 0) + ay, w = w * s, h = h * s }
end

-- ============================================================
-- RE-ENTRANCY GUARD
-- ============================================================
-- Post-hooks, so DF has already moved/resized before we tell the lib. Re-entrancy
-- guarded: onChanged -> Update*ContainerPosition -> hook -> Apply -> onChanged would
-- otherwise loop.

local refreshing = false

local function guarded(fn)
    return function()
        if refreshing then return end
        refreshing = true
        local ok, err = pcall(fn)
        refreshing = false
        if not ok then geterrorhandler()(err) end
    end
end

-- ============================================================
-- OPEN SETTINGS (the mover panel's Configure button)
-- ============================================================
-- Each element's def gets an openSettings that lands the user on that
-- element's own options page, in that element's mode:
--  * DF:EnsureOptionsLoaded() pulls in the LoD companion (GUI/LoadOptions.lua:38).
--  * DF:ToggleGUI() (DandersFrames_Options/GUI/Controls.lua:3616) builds and
--    shows the window when it is not already up.
--  * GUI.PartyButton / GUI.RaidButton :Click() is how the codebase itself
--    switches GUI.SelectedMode programmatically (buttons published at
--    DandersFrames_Options/GUI/Panel.lua:689/694; precedent at Panel.lua:315).
--    Safe during an open mover session: the departing mode's lock/test
--    cleanup in those handlers only touches the mode being LEFT, which is
--    never the one the session claimed.
--  * GUI.SelectTab(pageId) (DandersFrames_Options/GUI/Panel.lua:1710) opens
--    the page.
local function openOptionsPage(mode, pageId)
    local tTotal = perfStart()
    if not (DF.EnsureOptionsLoaded and DF:EnsureOptionsLoaded()) then return end
    perfLog(tTotal, "openOptionsPage: EnsureOptionsLoaded")
    if not (DF.GUIFrame and DF.GUIFrame:IsShown()) then
        local t = perfStart()
        DF:ToggleGUI()
        perfLog(t, "openOptionsPage: ToggleGUI (window build/show + page refresh)")
    end
    local GUI = DF.GUI
    if not (GUI and DF.GUIFrame and DF.GUIFrame:IsShown()) then return end
    -- Skipped when the window already shows the right mode; ToggleGUI's open
    -- half auto-detects from the live group though, so a raid-mode session
    -- reopened while solo lands on party and does need the click (which runs a
    -- full page rebuild in the new mode -- see the PERF line).
    if mode and GUI.SelectedMode ~= mode then
        local btn = (mode == "raid") and GUI.RaidButton or GUI.PartyButton
        if btn and btn.Click then
            local t = perfStart()
            btn:Click()
            perfLog(t, "openOptionsPage: mode button Click (page rebuild)")
        end
    end
    if GUI.SelectTab then
        local t = perfStart()
        GUI.SelectTab(pageId)
        perfLog(t, "openOptionsPage: SelectTab")
    end
    perfLog(tTotal, "openOptionsPage total")
end

-- ============================================================
-- REGISTRATION
-- ============================================================
local function registerElements()
    Mover:RegisterAddon(ADDON_KEY, {
        title = "DandersFrames",
        icon  = "Interface\\AddOns\\DandersFrames\\Media\\DF_Icon",
    })

    Mover:Register(ADDON_KEY, "party", {
        title     = L["Party Frames"],
        getFrame  = function() return DF.container end,
        getPos    = function() return DF:GetPositionRecord("party") end,
        onChanged = function(pos)
            DF:SetPositionRecord("party", pos)
            DF:UpdateContainerPosition()
        end,
        default   = { point = "CENTER", x = 0, y = -325 },
        -- Hosts DF.partyContainer and DF.partyHeader (SecureFrameTemplate /
        -- SecureGroupHeaderTemplate, Headers.lua:1075/1118), so moving it in combat is
        -- protected -- the lib defers onChanged until PLAYER_REGEN_ENABLED.
        secure    = true,
        -- ⚠ Dead while getRect is present: Registry:GetSize returns getRect's w/h and
        -- never reaches getSize. Kept as the spec wrote it so the def stays correct if
        -- getRect is ever dropped.

        -- Used when getRect reports no visible frames: the proxy keeps the container's size.
        getSize   = function()
            local w, h = DF.container:GetSize()
            local s = (DF:GetDB().frameScale or 1)
            return w * s, h * s
        end,
        getRect   = partyRect,
        group     = L["Party"],
        isRelevant = function() return Bridge:IsScopeRelevant("party") end,
        openSettings = function() openOptionsPage("party", "general_frame") end,
        twin      = ADDON_KEY .. ":raid",
    })

    Mover:Register(ADDON_KEY, "raid", {
        title     = L["Raid Frames"],
        getFrame  = function() return DF.raidContainer end,
        getPos    = function() return DF:GetPositionRecord("raid") end,
        onChanged = function(pos)
            DF:SetPositionRecord("raid", pos)
            DF:UpdateRaidContainerPosition()
        end,
        default   = { point = "CENTER", x = -6.666610717773438, y = -25 },
        secure    = true,
        getRect   = raidRect,
        group     = L["Raid"],
        isRelevant = function() return Bridge:IsScopeRelevant("raid") end,
        openSettings = function() openOptionsPage("raid", "general_frame") end,
        twin      = ADDON_KEY .. ":party",
    })

    -- "Whichever group frames are up right now." Saves every other addon from having to
    -- pick party-or-raid itself, and from re-anchoring when the player zones into a raid.
    -- Not movable -- it is an alias for one of the two elements above, and dragging it
    -- would be ambiguous.
    Mover:RegisterAnchorTarget(ADDON_KEY, "group", {
        title    = L["Group Frames"],
        group    = L["Party"],
        getFrame = function() return IsInRaid() and DF.raidContainer or DF.container end,
        getRect  = function() return IsInRaid() and raidRect() or partyRect() end,
    })

    -- The personal targeted-spells block and the targeted list: plain non-secure
    -- frames (TargetedSpells.lua; the list's secure template was deliberately removed),
    -- dynamic sizes, so getRect is required. Both containers are file-locals there, so
    -- the rect/size accessors live in that file. The personal record lives in the db
    -- that DRIVES the block (raid in a raid) -- RECORD_SPECS.personal resolves it.
    Mover:Register(ADDON_KEY, "personalTargeted", {
        title     = L["Personal Targeted"],
        group     = L["Targeted Spells"],
        getFrame  = function() return _G.DandersFramesPersonalTargetedSpells end,
        getPos    = function() return DF:GetPositionRecord("personal") end,
        onChanged = function(pos)
            DF:SetPositionRecord("personal", pos, "DandersMover")
            if DF.UpdatePersonalTargetedSpellsPosition then DF:UpdatePersonalTargetedSpellsPosition() end
        end,
        default   = { point = "CENTER", x = 0, y = -150 },
        getSize   = function() if DF.GetPersonalTargetedSize then return DF:GetPersonalTargetedSize() end end,
        getRect   = function() if DF.GetPersonalTargetedRect then return DF:GetPersonalTargetedRect() end end,
        isRelevant = function()
            local db = DF.GetPersonalTargetedDB and DF:GetPersonalTargetedDB() or DF:GetDB()
            return db and db.personalTargetedSpellEnabled and true or false
        end,
        openSettings = function() openOptionsPage("party", "indicators_personal_targeted") end,
    })

    Mover:Register(ADDON_KEY, "targetedList", {
        title     = L["Targeted List"],
        group     = L["Targeted Spells"],
        getFrame  = function() return _G.DandersFramesTargetedListContainer end,
        getPos    = function() return DF:GetPositionRecord("targetedList") end,
        onChanged = function(pos)
            DF:SetPositionRecord("targetedList", pos, "DandersMover")
            if DF.UpdateTargetedListLayout then DF:UpdateTargetedListLayout() end
        end,
        default   = { point = "CENTER", x = 0, y = -10 },
        getSize   = function() if DF.GetTargetedListSize then return DF:GetTargetedListSize() end end,
        getRect   = function() if DF.GetTargetedListRect then return DF:GetTargetedListRect() end end,
        isRelevant = function()
            local db = DF:GetDB("party")
            return Bridge:IsScopeRelevant("party") and db and db.targetedListEnabled and true or false
        end,
        openSettings = function() openOptionsPage("party", "indicators_targetedlist") end,
    })
end

-- ============================================================
-- PINNED SETS
-- ============================================================
-- One element per EXISTING set per mode: party.pinned.<uid> / raid.pinned.<uid>.
-- MAX_SETS is 4 but only 2 are defaulted and RemoveSet COMPACTS indices, so a fixed
-- 1..4 list would show phantom sets -- the list is rebuilt on add/remove and on a
-- profile refresh (RefreshPinnedElements).
--
-- ☠ THE KEY IS THE UID, NOT THE INDEX (Phase D). Compaction used to silently re-point a
-- saved anchor.target = "DandersFrames:raid.pinned3" at whatever set slid into slot 3,
-- and moved the user's /mover config toggle with it. The uid does not move, so a child
-- anchored to a DELETED set now simply holds (an unresolvable target), which is the
-- correct answer. Everything else here stays INDEX-based -- PinnedFrames owns nothing
-- keyed by uid, so every accessor below is still called with (mode, i).
--
-- Containers are plain frames hosting a SecureGroupHeaderTemplate (or secure boss
-- buttons) -> secure = true. `point` is the growth corner, derived -> pointLocked.
-- PinnedFrames.lua owns every accessor (the record, the on-screen container for a
-- mode, its rect, the commit funnel) so nothing here reaches into its internals.

local PINNED_KEY = { party = "party.pinned.", raid = "raid.pinned." }

-- The element key for a mode's set at INDEX i, or nil when there is no such set.
-- EnsureSetUid is stamp-on-read, so a set seeded by Config's defaults or written by the
-- options page after the login migration ran still gets its uid here.
function keyForSet(mode, i)
    local pf = DF.PinnedFrames
    local uid = pf and pf.EnsureSetUid and pf:EnsureSetUid(i, mode)
    return uid and (PINNED_KEY[mode] .. uid) or nil
end

local function pinnedDefault(mode, i)
    local defaults = (mode == "raid") and DF.RaidDefaults or DF.PartyDefaults
    local set = defaults and defaults.pinnedFrames and defaults.pinnedFrames.sets and defaults.pinnedFrames.sets[i]
    if set and set.position then
        return { point = set.position.point or "CENTER", x = set.position.x or 0, y = set.position.y or 0 }
    end
    -- PinnedFrames.MakeDefaultSet's stagger for sets beyond the defaulted two.
    return { point = "CENTER", x = 0, y = 250 - (i - 1) * 130 }
end

-- "Party Pinned 1" / "Raid Pinned 1" -- the mode has to be in the TITLE, not only in
-- the group heading: the same index exists in both modes and a bare "Pinned 1" is
-- ambiguous everywhere the title travels alone (the anchor picker, the proxy tooltip).
-- A set the user has RENAMED is tagged with its name; the auto-generated "Pinned N"
-- placeholder (Config.lua's defaults / PinnedFrames.MakeDefaultSet) is not, since
-- appending it would just repeat the index.
-- ⚠ Baked at registration time, so a rename shows on the next RefreshPinnedElements
-- (add/remove a set, or a profile refresh), not the instant it is typed.
local function pinnedTitle(mode, i)
    local isRaid = (mode == "raid")
    local title = format(isRaid and L["Raid Pinned %d"] or L["Party Pinned %d"], i)
    local pf = DF.PinnedFrames
    local set = pf and pf.GetSetForMode and pf:GetSetForMode(i, isRaid)
    local name = set and set.name
    if name and name ~= "" and name ~= ("Pinned " .. i) and name ~= format(L["Pinned %d"], i) then
        return title .. " — " .. name
    end
    return title
end

local function pinnedDef(mode, i)
    local isRaid = (mode == "raid")
    -- The SAME INDEX in the other mode, keyed by THAT set's uid. nil when the opposite
    -- mode has no set at this index (the modes are independent) -- the panel only offers
    -- the copy while the twin is registered, so a missing one is fine.
    local otherMode = isRaid and "party" or "raid"
    local pf = DF.PinnedFrames
    local twinKey = (pf and pf.GetSetForMode and pf:GetSetForMode(i, not isRaid))
        and keyForSet(otherMode, i) or nil
    return {
        title     = pinnedTitle(mode, i),
        group     = isRaid and L["Raid"] or L["Party"],
        getFrame  = function()
            local pf = DF.PinnedFrames
            return pf and pf.GetContainerForMode and pf:GetContainerForMode(i, isRaid) or nil
        end,
        getRect   = function()
            local pf = DF.PinnedFrames
            return pf and pf.GetContainerRect and pf:GetContainerRect(i, isRaid) or nil
        end,
        getPos    = function()
            local pf = DF.PinnedFrames
            local rec = pf and pf.GetPositionRecord and pf:GetPositionRecord(i, isRaid)
            -- getPos must return a table; a set that vanished between RemoveSet and the
            -- refresh gets a throwaway that is never persisted.
            return rec or { point = "CENTER", x = 0, y = 0 }
        end,
        onChanged = function(pos, reason)
            local pf = DF.PinnedFrames
            if pf and pf.CommitSetPosition then pf:CommitSetPosition(i, isRaid, pos, reason) end
        end,
        default   = pinnedDefault(mode, i),
        secure    = true,
        pointLocked = true,
        isRelevant = function()
            if not Bridge:IsScopeRelevant(mode) then return false end
            local pf = DF.PinnedFrames
            local set = pf and pf.GetSetForMode and pf:GetSetForMode(i, isRaid)
            return (set and set.enabled) and true or false
        end,
        openSettings = function() openOptionsPage(mode, "general_pinnedframes") end,
        twin      = twinKey and (ADDON_KEY .. ":" .. twinKey) or nil,
    }
end

-- The keys this bridge currently has registered, per mode. ☠ TRACKED, NOT DERIVED: the
-- keys are uids now, so "every possible key for the mode" is no longer a 1..MAX_SETS
-- list -- after a remove there is nothing left in the DB that names the uid that just
-- went away, and an untracked unregister would leave its proxy on screen forever.
Bridge.pinnedKeys = { party = {}, raid = {} }

-- Unregister what we registered last time, then register one element per EXISTING set.
-- Safe mid-session: Lib:Unregister drops the proxy; a new set gets its proxy on the
-- next rebuild.
function Bridge:RefreshPinnedElements(mode)
    mode = (mode == "raid") and "raid" or "party"
    local tracked = self.pinnedKeys[mode]
    for _, key in ipairs(tracked) do Mover:Unregister(ADDON_KEY, key) end
    wipe(tracked)
    local pf = DF.PinnedFrames
    if not (pf and pf.GetSetForMode) then return end
    for i = 1, (pf.MAX_SETS or 4) do
        if pf:GetSetForMode(i, mode == "raid") then
            local key = keyForSet(mode, i)
            if key then
                Mover:Register(ADDON_KEY, key, pinnedDef(mode, i))
                tracked[#tracked + 1] = key
            end
        end
    end
end

local function refreshAllPinned()
    Bridge:RefreshPinnedElements("party")
    Bridge:RefreshPinnedElements("raid")
end

-- Re-solve the pinned anchors of a scope once its preview has a rect. A saved anchor
-- was solved against last session's target; at login the party frames may not even be
-- on screen (solo), so Init's Apply HELD. Without this, a Detach before the first
-- resolve would drop the set at the stale x/y instead of in place.
-- Iterates the TRACKED keys rather than re-deriving them: these are exactly the
-- elements registered for the scope, so nothing here can hand Apply a key for a set
-- that was removed, and nothing stamps a uid as a side effect of an apply.
local function applyPinned(scope)
    for _, key in ipairs(Bridge.pinnedKeys[(scope == "raid") and "raid" or "party"]) do
        Mover:Apply(ADDON_KEY, key)
    end
end

-- ============================================================
-- SESSION -> TEST MODE
-- ============================================================
-- One lib session shows both proxies but only ever CLAIMS the scope being edited --
-- claiming both put the other scope's test frames on screen unasked. Owner claims are
-- idempotent (DF._testOwners[scope][owner], TestMode/Shim.lua:117-121), and since
-- Phase C retired the legacy unlock paths this bridge is the only writer of the
-- "unlock" owner string.

local SCOPE_LOCK_KEY = { party = "locked", raid = "raidLocked" }

local function scopeDB(scope)
    return (scope == "raid") and DF:GetRaidDB() or DF:GetDB()
end

local function claimScope(scope)
    local db = scopeDB(scope)
    if not db then return end
    local key = SCOPE_LOCK_KEY[scope]
    -- Short-circuit: the legacy overlay is already up for this scope and owns the claim.
    if db[key] == false then return end
    db[key] = false
    Bridge.claimed[scope] = true
    if DF.SetTestModeOwner then
        DF:SetTestModeOwner(scope, "unlock", true, true)   -- silent: the session announces itself
    end
end

local function releaseScope(scope)
    if not Bridge.claimed[scope] then return end
    Bridge.claimed[scope] = nil
    local db = scopeDB(scope)
    if db then db[SCOPE_LOCK_KEY[scope]] = true end
    if DF.SetTestModeOwner then
        DF:SetTestModeOwner(scope, "unlock", false, true)
    end
end

local function syncLockButtons()
    if not DF.GUI then return end
    if DF.GUI.UpdateLockButtonState then DF.GUI.UpdateLockButtonState() end
    if DF.GUI.UpdateTestButtonState then DF.GUI.UpdateTestButtonState() end
end

Mover.RegisterCallback(Bridge, "Unlocked", function()
    local tTotal = perfStart()
    -- An open DF options window would sit over the session. Remember which
    -- page/mode it showed and close it -- the window is DF.GUIFrame (built in
    -- DandersFrames_Options/GUI/Panel.lua CreateGUI), closed with the same
    -- plain :Hide() its own close button uses (Panel.lua:155). Locked puts it
    -- back on the same page in the same mode, so unlocking from the settings
    -- and locking again returns the user where they were rather than to an
    -- empty screen. The mover panel's Configure button (openOptionsPage above)
    -- is the other way back in, on the selected element's own page.
    if DF.GUIFrame and DF.GUIFrame:IsShown() then
        Bridge.closedGUIPage = DF.GUI and DF.GUI.CurrentPageName or nil
        Bridge.closedGUIMode = DF.GUI and DF.GUI.SelectedMode or nil
        DF.GUIFrame:Hide()
    end
    -- Test frames live in the load-on-demand companion. `/mover` can open a session
    -- without going through DF:UnlockFrames, so load it here too or the proxies sit over
    -- an empty screen.
    if DF.EnsureOptionsLoaded then
        local t = perfStart()
        DF:EnsureOptionsLoaded()
        perfLog(t, "Unlocked: EnsureOptionsLoaded")
    end
    -- ONE scope per session. `/mover` opens a session without going through either
    -- Unlock*Frames, so with no request outstanding pick the one the player is in.
    local scope = Bridge.requestedScope or (IsInRaid() and "raid" or "party")
    Bridge.requestedScope = nil
    -- Claim on the scope's whole key list, not on the CONTAINER element's toggle: a
    -- session that is only editing pinned sets still needs the test frames those sets
    -- attach to, and the container being switched off in /mover config says nothing
    -- about them. Nothing left in the list means nothing to preview.
    if #Bridge:SessionFilter(scope).keys > 0 then
        -- claimScope -> SetTestModeOwner -> ReconcileTestMode -> Show*TestFrames ->
        -- PinnedFrames:EnterTestMode (TestMode.lua:1962/2427): the pinned test
        -- containers are on screen after this line.
        local t = perfStart()
        claimScope(scope)
        perfLog(t, "Unlocked: claimScope (test frames up)")
    end
    syncLockButtons()
    -- The claim above flipped the scope's lock flag; the permanent handle keys its
    -- visibility off that flag and nothing else re-evaluates it on the lib path.
    -- SetMovable inside is a protected action -- skip in combat; Core.lua's
    -- PLAYER_REGEN handler re-evaluates the handle after combat anyway.
    if DF.UpdatePermanentMoverVisibility and not InCombatLockdown() then
        DF:UpdatePermanentMoverVisibility()
    end
    -- Same next-frame re-measure the lib does for its proxies (Session:Unlock).
    C_Timer.After(0, function()
        if Mover:IsUnlocked() then guarded(function() applyPinned(scope) end)() end
        -- claimScope swapped the live frames for the test pool, so every per-unit slot
        -- now points at a different frame. Rebuild off the pool.
        if Bridge.RequestUnitTargetRefresh then Bridge:RequestUnitTargetRefresh() end
    end)
    perfLog(tTotal, "Unlocked callback total")
end)

Mover.RegisterCallback(Bridge, "Locked", function()
    local tTotal = perfStart()
    -- Only the scope the session claimed does any work here (releaseScope
    -- early-returns on the other), so there is exactly one ReconcileTestMode
    -- per lock, not two.
    local t = perfStart()
    releaseScope("party")
    releaseScope("raid")
    perfLog(t, "Locked: releaseScope both (test frames down)")
    syncLockButtons()
    -- The test pool just went away; the per-unit slots have to go back to the live
    -- header's children. Same guard as the unlock side.
    if Bridge.RequestUnitTargetRefresh then Bridge:RequestUnitTargetRefresh() end
    -- The release above flipped the scope's lock flag; the permanent handle keys its
    -- visibility off that flag and nothing else re-evaluates it on the lib path.
    -- SetMovable inside is a protected action -- skip in combat; Core.lua's
    -- PLAYER_REGEN handler re-evaluates the handle after combat anyway.
    if DF.UpdatePermanentMoverVisibility and not InCombatLockdown() then
        DF:UpdatePermanentMoverVisibility()
    end
    -- Put the options window back the way the session found it -- same page,
    -- same mode -- on EVERY finish, save or discard alike. Unlocked stores the
    -- pair only when the window was actually open, so nothing stored means the
    -- user was not in the settings when they unlocked and nothing should
    -- appear now. Cleared before the reopen either way, so a later lock cannot
    -- resurrect a window from a session two ago.
    local page, mode = Bridge.closedGUIPage, Bridge.closedGUIMode
    Bridge.closedGUIPage, Bridge.closedGUIMode = nil, nil
    if not page then return end
    -- openOptionsPage switches mode by clicking the mode button, and that
    -- handler runs the departing mode's lock/test cleanup -- secure work. A
    -- lock that lands in combat must wait for the lockdown to END: After(0)
    -- fires next frame, still in combat, so the deferral is a real
    -- PLAYER_REGEN_ENABLED wait.
    if InCombatLockdown() then
        local waiter = CreateFrame("Frame")
        waiter:RegisterEvent("PLAYER_REGEN_ENABLED")
        waiter:SetScript("OnEvent", function(self)
            self:UnregisterAllEvents()
            openOptionsPage(mode, page)
        end)
    else
        -- One frame later, NOT inline (mover-hitch fix, 2026-08-24): the reopen is a
        -- full options-window show -- ToggleGUI's open half rebuilds the current page,
        -- a mode switch rebuilds it again in the other mode -- and it used to share
        -- the lock frame's budget with the whole test-mode teardown above plus the
        -- proxy fade. Same visual result (the window appears as the fade starts),
        -- hitch split across two frames instead of stacked on one.
        C_Timer.After(0, function()
            -- The user can unlock again before this fires; a reopen would drop the
            -- window on top of the fresh session (whose Unlocked closed it -- or
            -- would have, had it existed yet). The new session's own lock restores it.
            if Mover:IsUnlocked() then return end
            openOptionsPage(mode, page)
        end)
    end
    perfLog(tTotal, "Locked callback total")
end)

-- ============================================================
-- REFRESH HOOKS
-- ============================================================
local function refreshGroup() Mover:RefreshAnchorTarget(ADDON_KEY, "group") end
-- "group" aliases whichever of the two is live, so anything that moves one moves it too.
-- The per-unit / per-group targets (Features\MoverTargets.lua) sit INSIDE these rects,
-- so anything moving a container moves every one of them too. One batched call rather
-- than one per key. Guarded on SubTargetKeys: MoverTargets is an optional sibling and
-- this file has to keep working without it.
local function refreshSubTargets(scope)
    if Bridge.SubTargetKeys then Mover:RefreshAnchorTargets(ADDON_KEY, Bridge:SubTargetKeys(scope)) end
end
local function refreshParty()
    Mover:RefreshAnchorTarget(ADDON_KEY, "party"); refreshGroup(); refreshSubTargets("party")
end
local function refreshRaid()
    Mover:RefreshAnchorTarget(ADDON_KEY, "raid");  refreshGroup(); refreshSubTargets("raid")
end
local function applyBoth()
    Mover:Apply(ADDON_KEY, "party")
    Mover:Apply(ADDON_KEY, "raid")
    Mover:Apply(ADDON_KEY, "personalTargeted")
    Mover:Apply(ADDON_KEY, "targetedList")
end

-- ============================================================
-- LAYOUT -> ANCHOR RE-SOLVE
-- ============================================================
-- ☠ A SIZE CHANGE IS NOT A POSITION CHANGE, and only the position half ever
-- announced itself. Every hook above is on a function that MOVES something. Frame
-- Width, Frame Height, spacing, padding move nothing -- they resize the frames
-- INSIDE the container, which changes the rect other elements are anchored to
-- without any of those functions running. So a buff row snapped to the party
-- frames' right edge sat at the x/y it was solved to at the OLD width until
-- something unrelated happened to re-solve it. Reported in game as "when
-- adjusting widths of frames, anchor locations don't update at all".
--
-- The apply scheduler is the main seam. Every settings sweep that can resize a
-- frame funnels into it, and the end of its drain is the first moment the new
-- geometry is on screen and measurable. A slider DRAG gets there too: the drag
-- pump runs the lightweight preview once per rendered frame and the live-frames
-- branch of that preview asks the scheduler for `headers` / `raidLayout`
-- (Core.lua's LightweightUpdateFrameSize), so a held slider produces a drain, and
-- therefore a pass, every frame.
--
-- ☠ THE TEST-MODE PREVIEW SKIPS THE SCHEDULER ENTIRELY, and that is the case that
-- matters most: a mover session forces test mode on, and GetPartyVisibleRect
-- measures the TEST frames while it is. LightweightUpdateFrameSize's test branch
-- returns before it ever reaches ApplyHeaderSettings, re-laying the preview out
-- by hand instead, so nothing arms a drain and the drag would only settle on
-- mouse-up. Those three preview entry points are hooked below.
--
-- COALESCED TO ONE PASS PER RENDERED FRAME. Several of those triggers fire inside
-- one frame (a preview re-layout calls the positioner it is hooked alongside), and
-- the pass measures every DF target, so running it per trigger would be the
-- expensive way to get the same answer. C_Timer.After(0) also puts it after
-- everything else that frame has done, which is exactly where it wants to be.
--
-- COMBAT needs nothing here. The drain runs no combat-unsafe kind while locked
-- down, so the pass does not even fire from that door; when it does, the lib
-- defers a secure element's onChanged to PLAYER_REGEN_ENABLED itself
-- (DandersMover NS:Notify) and replays it on the way out.
--
-- NO LOOP. Two independent brakes: `guarded` (the pass cannot re-enter itself,
-- and collapses the Update*ContainerPosition hooks that its own re-solves fire),
-- and Mover:RefreshMovedTargets, which measures first and does nothing at all
-- unless a rect moved by more than half a pixel.

local layoutKeys = {}

local function appendKeys(src)
    if not src then return end
    for _, key in ipairs(src) do layoutKeys[#layoutKeys + 1] = key end
end

-- Every DF target whose RECT a frame-layout sweep can move: the two containers,
-- the "whichever group is up" alias, each registered pinned set (their containers
-- hold unit frames and resize with them), and the per-unit / per-group slot
-- targets -- which are the ones users most often anchor to, and which move with
-- the frames themselves rather than with the container.
-- Rebuilt per pass: the pinned list and the slot list both change at runtime.
-- The two targeted displays are NOT here -- they resize only with their own
-- settings, and their own apply functions are already hooked above.
local function collectLayoutKeys()
    wipe(layoutKeys)
    layoutKeys[1], layoutKeys[2], layoutKeys[3] = "party", "raid", "group"
    appendKeys(Bridge.pinnedKeys.party)
    appendKeys(Bridge.pinnedKeys.raid)
    if Bridge.SubTargetKeys then
        appendKeys(Bridge:SubTargetKeys("party"))
        appendKeys(Bridge:SubTargetKeys("raid"))
    end
    return layoutKeys
end

local function resolveAfterLayout()
    -- The count is MOVED TARGETS, not re-solved elements: with nothing anchored to
    -- DF at all this still reports the containers changing size, and re-solves
    -- nothing. At rest it is 0 and this line is silent -- which is the check for
    -- "is something looping", so keep the wording honest about what it counts.
    local moved = Mover:RefreshMovedTargets(ADDON_KEY, collectLayoutKeys())
    if moved > 0 then
        DF:Debug("LAYOUT", "MoverBridge: %d anchor target(s) changed size/position after a layout apply", moved)
    end
end

-- Hoisted, not built per call: these are the hot path during a slider drag, and
-- C_Timer.After keeps the SAME function object every frame this way.
local guardedResolve = guarded(resolveAfterLayout)
local resolvePending = false

local function onResolveTick()
    resolvePending = false
    guardedResolve()
end

local function requestResolve()
    if resolvePending then return end
    resolvePending = true
    C_Timer.After(0, onResolveTick)
end

-- Door 2: the test-mode preview, which re-lays the visible frames out by hand and
-- never touches the apply scheduler. All three live in the load-on-demand options
-- companion, so they are not here when Init runs -- the ADDON_LOADED waiter below
-- is what gets them. RefreshTestFramesWithLayout is the width/height path and the
-- two positioners are the spacing/sorting path (RefreshTestFramesWithLayout ends
-- by calling them, which is what the per-frame coalescing is for).
local OPTIONS_ADDON = "DandersFrames_Options"
local PREVIEW_HOOKS = {
    "RefreshTestFramesWithLayout",
    "LightweightPositionPartyTestFrames",
    "LightweightPositionRaidTestFrames",
}

-- true once the hooks are on (or already were), false while the companion is
-- still out -- that is what tells the caller whether it needs the waiter.
local function installPreviewHooks()
    if Bridge.previewHooked then return true end
    -- All three ship in the same file, so one being present means all are; keyed
    -- off the first so a partial install can never latch the flag.
    if not DF[PREVIEW_HOOKS[1]] then return false end
    Bridge.previewHooked = true
    for _, name in ipairs(PREVIEW_HOOKS) do
        if DF[name] then hooksecurefunc(DF, name, requestResolve) end
    end
    return true
end

local function installHooks()
    -- Sizes, not positions -- see LAYOUT -> ANCHOR RE-SOLVE above. Gated on the
    -- lib version: DandersMover is an OptionalDep the user installs separately, so
    -- the copy in front of us can predate the RefreshMovedTargets that landed in
    -- MINOR 2. Without it anchors simply keep the pre-fix behaviour; nothing else
    -- in this file depends on the pass.
    if Mover.RefreshMovedTargets then
        -- Door 1: the apply scheduler, for every settings sweep that runs a real
        -- layout pass. Guarded on the method too -- the scheduler is core, but this
        -- file has to keep loading if it ever is not.
        if DF.Apply and DF.Apply.AddPostDrain then
            DF.Apply:AddPostDrain(requestResolve)
        end
        -- Door 2 is in the companion. Init runs on DandersFrames' own
        -- ADDON_LOADED, long before anything pulls that in, so nearly every
        -- login takes the waiter -- it is the normal path, not the fallback.
        if not installPreviewHooks() then
            local waiter = CreateFrame("Frame")
            waiter:RegisterEvent("ADDON_LOADED")
            waiter:SetScript("OnEvent", function(self, _, name)
                if name ~= OPTIONS_ADDON then return end
                self:UnregisterAllEvents()
                installPreviewHooks()
            end)
        end
    end
    -- Our own rect moved -> re-solve everything anchored TO us. RefreshAnchorTarget only
    -- walks descendants; it never re-fires our own onChanged.
    hooksecurefunc(DF, "UpdateContainerPosition",     guarded(refreshParty))
    hooksecurefunc(DF, "UpdateRaidContainerPosition", guarded(refreshRaid))
    -- The raid rect also changes without the position changing: relayout, flat-grid
    -- resize, and the mover/test-container size sync.
    -- ⚠ HOOK THE BODY, NOT THE STUB. DF:UpdateRaidLayout is now an arm-stub that
    -- only marks the layout dirty (Core\ApplyScheduler.lua), so a post-hook on it
    -- would fire BEFORE the layout runs and re-solve against the old rect. The
    -- `_Now` body is where the rect actually moves.
    hooksecurefunc(DF, "UpdateRaidLayout_Now",        guarded(refreshRaid))
    hooksecurefunc(DF, "SyncRaidMoverToContainer",    guarded(refreshRaid))
    if DF.FlatRaidFrames then
        hooksecurefunc(DF.FlatRaidFrames, "UpdateContainerSize", guarded(refreshRaid))
    end
    -- The RECORD itself may have changed wholesale (profile switch, import, auto layout),
    -- so re-solve and re-fire our own onChanged, not just the descendants.
    hooksecurefunc(DF, "FullProfileRefresh", guarded(function()
        -- The set COUNT can change with the profile; re-register before re-applying.
        refreshAllPinned()
        applyBoth()
    end))
    -- Pinned sets come and go; RemoveSet compacts indices (PinnedFrames:RemoveSet).
    -- ⚠ ORDERING, load-bearing during an open mover session. These are POST-hooks, so
    -- refreshAllPinned runs synchronously the moment the set list changes, and its
    -- Unregister/Register calls each fire the lib's RegistryChanged. The lib's session
    -- listener DEBOUNCES that to the end of the frame, so the whole burst lands first
    -- and the proxies are rebuilt once, off the compacted list. Make either side
    -- immediate and a proxy would be rebuilt against a half-updated registry, pointing
    -- at an index that no longer means what it did.
    if DF.PinnedFrames then
        hooksecurefunc(DF.PinnedFrames, "AddSet",    guarded(refreshAllPinned))
        hooksecurefunc(DF.PinnedFrames, "RemoveSet", guarded(refreshAllPinned))
    end
    -- The two targeted displays resize with their settings (max icons / max bars);
    -- their own apply functions are the one place that knows. Descendants only.
    if DF.UpdatePersonalTargetedSpellsPosition then
        hooksecurefunc(DF, "UpdatePersonalTargetedSpellsPosition",
            guarded(function() Mover:RefreshAnchorTarget(ADDON_KEY, "personalTargeted") end))
    end
    if DF.UpdateTargetedListLayout then
        hooksecurefunc(DF, "UpdateTargetedListLayout",
            guarded(function() Mover:RefreshAnchorTarget(ADDON_KEY, "targetedList") end))
    end
    if DF.AutoProfilesUI then
        -- Redundant with FullProfileRefresh (ApplyRuntimeProfile calls it, and so does
        -- DeactivateRuntimeProfile) but harmless: Apply is idempotent and the re-entrancy
        -- guard collapses the inner call. Kept because the spec names it, so a future
        -- refactor that stops calling FullProfileRefresh does not silently lose the hook.
        hooksecurefunc(DF.AutoProfilesUI, "ApplyRuntimeProfile", guarded(applyBoth))
    end
    -- Roster changes already reach UpdateRaidContainerPosition through DF's own
    -- GROUP_ROSTER_UPDATE handling, and the Frame Scale slider already calls both
    -- Update*ContainerPosition -- both are covered by the hooks above.
    --
    -- "group" is the exception: it swaps which container it reports the moment IsInRaid()
    -- flips, which can happen with neither container's position changing. Debounced,
    -- because a raid join fires GROUP_ROSTER_UPDATE several times in a row.
    local rosterPending = false
    local roster = CreateFrame("Frame")
    roster:RegisterEvent("GROUP_ROSTER_UPDATE")
    roster:SetScript("OnEvent", function()
        if rosterPending then return end
        rosterPending = true
        C_Timer.After(0.1, function()
            rosterPending = false
            guarded(refreshGroup)()
            -- The per-unit and per-group slot targets are a function of the roster, so
            -- they are rebuilt off the same event. Their own debounce collapses the
            -- burst; guarded on the method so this file never hard-depends on
            -- Features\MoverTargets.lua.
            if Bridge.RequestUnitTargetRefresh then Bridge:RequestUnitTargetRefresh() end
        end)
    end)
end

-- ============================================================
-- INIT
-- Called from Core.lua's ADDON_LOADED, right after DF:InitializeFrames().
-- Registry:Register queues before the lib's own SV load (Registry.lua:65-72), so the
-- order between the two addons' ADDON_LOADED does not matter.
-- ============================================================
function Bridge:Init()
    if self.initialised then return end
    self.initialised = true
    registerElements()
    refreshAllPinned()
    -- Per-unit and per-group anchor targets. Optional sibling file, and it registers
    -- targets only -- nothing above depends on it.
    if DF.MoverTargets then DF.MoverTargets:Init() end
    installHooks()
    -- Resolve saved anchors once at login. The record carries the anchor block, but its
    -- x/y were solved against last session's target rect. Safe when the target is not up
    -- yet: the lib holds the last position rather than snapping to a stale rect.
    guarded(applyBoth)()
    DF:Debug("LAYOUT", "MoverBridge: registered party + raid + pinned + targeted with DandersMover")
end
