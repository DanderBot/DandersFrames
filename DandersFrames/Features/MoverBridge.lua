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
local pcall, geterrorhandler, ipairs = pcall, geterrorhandler, ipairs
local max, min = math.max, math.min
local IsInRaid, CreateFrame, C_Timer = IsInRaid, CreateFrame, C_Timer

local ADDON_KEY = "DandersFrames"

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
        group     = "Frames",
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
        group     = "Frames",
    })

    -- "Whichever group frames are up right now." Saves every other addon from having to
    -- pick party-or-raid itself, and from re-anchoring when the player zones into a raid.
    -- Not movable -- it is an alias for one of the two elements above, and dragging it
    -- would be ambiguous.
    Mover:RegisterAnchorTarget(ADDON_KEY, "group", {
        title    = L["Group Frames"],
        getFrame = function() return IsInRaid() and DF.raidContainer or DF.container end,
        getRect  = function() return IsInRaid() and raidRect() or partyRect() end,
    })
end

-- ============================================================
-- SESSION -> TEST MODE
-- ============================================================
-- One lib session shows both proxies but only ever CLAIMS the scope being edited --
-- claiming both put the other scope's test frames on screen unasked. Owner claims are
-- idempotent (DF._testOwners[scope][owner], TestMode/Shim.lua:117-121) and the claim uses
-- the SAME owner string the legacy path uses ("unlock", Position.lua:2504/2580,
-- Init.lua:992/1084), so a double claim cannot double-count.

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
    -- Test frames live in the load-on-demand companion. `/mover` can open a session
    -- without going through DF:UnlockFrames, so load it here too or the proxies sit over
    -- an empty screen.
    if DF.EnsureOptionsLoaded then DF:EnsureOptionsLoaded() end
    -- ONE scope per session. `/mover` opens a session without going through either
    -- Unlock*Frames, so with no request outstanding pick the one the player is in.
    local scope = Bridge.requestedScope or (IsInRaid() and "raid" or "party")
    Bridge.requestedScope = nil
    if Mover:IsEnabled(ADDON_KEY, scope) then
        claimScope(scope)
    end
    syncLockButtons()
end)

Mover.RegisterCallback(Bridge, "Locked", function()
    releaseScope("party")
    releaseScope("raid")
    syncLockButtons()
end)

-- ============================================================
-- REFRESH HOOKS
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

local function refreshGroup() Mover:RefreshAnchorTarget(ADDON_KEY, "group") end
-- "group" aliases whichever of the two is live, so anything that moves one moves it too.
local function refreshParty() Mover:RefreshAnchorTarget(ADDON_KEY, "party"); refreshGroup() end
local function refreshRaid()  Mover:RefreshAnchorTarget(ADDON_KEY, "raid");  refreshGroup() end
local function applyBoth()
    Mover:Apply(ADDON_KEY, "party")
    Mover:Apply(ADDON_KEY, "raid")
end

local function installHooks()
    -- Our own rect moved -> re-solve everything anchored TO us. RefreshAnchorTarget only
    -- walks descendants; it never re-fires our own onChanged.
    hooksecurefunc(DF, "UpdateContainerPosition",     guarded(refreshParty))
    hooksecurefunc(DF, "UpdateRaidContainerPosition", guarded(refreshRaid))
    -- The raid rect also changes without the position changing: relayout, flat-grid
    -- resize, and the mover/test-container size sync.
    hooksecurefunc(DF, "UpdateRaidLayout",            guarded(refreshRaid))
    hooksecurefunc(DF, "SyncRaidMoverToContainer",    guarded(refreshRaid))
    if DF.FlatRaidFrames then
        hooksecurefunc(DF.FlatRaidFrames, "UpdateContainerSize", guarded(refreshRaid))
    end
    -- The RECORD itself may have changed wholesale (profile switch, import, auto layout),
    -- so re-solve and re-fire our own onChanged, not just the descendants.
    hooksecurefunc(DF, "FullProfileRefresh", guarded(applyBoth))
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
    installHooks()
    -- Resolve saved anchors once at login. The record carries the anchor block, but its
    -- x/y were solved against last session's target rect. Safe when the target is not up
    -- yet: the lib holds the last position rather than snapping to a stale rect.
    guarded(applyBoth)()
    DF:Debug("LAYOUT", "MoverBridge: registered party + raid with DandersMover")
end
