local addonName, DF = ...

-- ============================================================
-- MOVERTARGETS
-- Per-unit and per-group anchor targets for DandersMover-1.0.
-- ============================================================
-- Everything registered here is an ANCHOR TARGET, never a movable element. DF's header
-- owns where each unit frame goes, so none of these are draggable; they exist so other
-- addons -- and DF's own pinned sets -- can say "attach me to MY frame" or "attach me
-- under group 3" instead of only to the whole container.
--
-- Two kinds:
--  * SEMANTIC (party.me / party.first / party.last and the raid three). Registered once
--    in MT:Init and never re-registered: their getFrame re-resolves on every call, so
--    what they point at follows the roster with no registry churn at all.
--  * SLOTS (party.slotN, raid.slotN, raid.groupN, raid.groupN.slotM). These come and go
--    with the roster, so MT:RefreshUnitTargets rebuilds them and registers ONLY the
--    slots that have a frame right now. A key that is not registered is one the anchor
--    picker never offers; a child already anchored to a key that disappears simply HOLDS
--    its last solved position (Registry:IsTargetAvailable), it does not jump.
--
-- Every slot/group target is `snappable = false`: 45 unit slots plus 8 groups would bury
-- the drag overlay in snap zones. They stay pickable in the anchor picker and reachable
-- by link-drag, which is how a per-unit anchor is actually chosen.
--
-- Registration is plain table work in the lib's registry -- no frame is created, shown,
-- sized or re-parented -- so it is safe in combat and deliberately carries no
-- combat-lockdown guard. Position notifies for secure elements defer inside the lib.

local Mover = LibStub and LibStub("DandersMover-1.0", true)
if not Mover then return end

local L = DF.L
local UIParent = UIParent
local ipairs, wipe, tostring = ipairs, wipe, tostring
local max, min, format = math.max, math.min, string.format
local C_Timer, UnitInRaid = C_Timer, UnitInRaid

local ADDON_KEY = "DandersFrames"

local MT = {}
DF.MoverTargets = MT

-- Keys currently registered per scope. Rebuilt wholesale by RefreshUnitTargets; the
-- semantic keys are NOT in here (they are registered once and never unregistered).
MT.registered = { party = {}, raid = {} }

-- The three semantic keys per scope, in picker order.
local SEMANTIC = {
    party = { "party.me", "party.first", "party.last" },
    raid  = { "raid.me",  "raid.first",  "raid.last"  },
}

local Bridge = DF.MoverBridge

-- ============================================================
-- RECT HELPERS
-- ============================================================
-- A private copy of Features\MoverBridge.lua's frameRect/union pair (that file keeps
-- them as file-locals and exports neither). Duplicated rather than exported so the two
-- files stay independent -- MoverBridge must keep working with this file absent.
-- Result is in UIParent units measured from UIParent CENTRE, scale-corrected; nil when
-- the frame is missing, hidden or unsized.

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

-- The lib reads getRect's return as a TABLE (Registry:GetRect does r.x / r.w), so every
-- def goes through this rather than returning frameRect's four values directly.
local function rectOf(f)
    local cx, cy, w, h = frameRect(f)
    if not cx then return nil end
    return { x = cx, y = cy, w = w, h = h }
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

-- ============================================================
-- FRAME RESOLUTION
-- ============================================================
-- Every getFrame below re-resolves from scratch on each call. That is what lets a slot
-- key survive the header handing its frame to a different unit: the KEY means "the third
-- party slot", and the frame behind it is whatever is in that slot right now.
--
-- Test mode previews with a separate NON-SECURE pool (DandersFrames_Options/TestMode/
-- TestFramePool.lua: testPartyFrames[0..4], testRaidFrames[1..40]); the live header is
-- empty while it is up, so the pool has to win. Both accessors are guarded -- the pool
-- only exists once the load-on-demand companion is in.

local function testParty()
    if not (DF.IsTestModeActive and DF:IsTestModeActive("party")) then return nil end
    return DF.testPartyFrames
end

local function testRaid()
    if not (DF.IsTestModeActive and DF:IsTestModeActive("raid")) then return nil end
    return DF.testRaidFrames
end

-- ⚠ The player's frame comes from DF:GetPlayerFrame, never from DF's party-INDEX
-- getter: that one matches unit == "partyN" and so can never return the player's own
-- frame. Features\MoverBridge.lua:113-118 documents the same trap.
local function partyMeFrame()
    local pool = testParty()
    local f = pool and pool[0]
    if f then return f end
    return DF.GetPlayerFrame and DF:GetPlayerFrame() or nil
end

-- Party slot 1 is the PLAYER (nameList sorting puts them in the same header), 2..5 are
-- party1..4. The test pool uses the same order one index lower: [0] = player.
local function partySlotFrame(n)
    local pool = testParty()
    local f = pool and pool[n - 1]
    if f then return f end
    local map = DF.unitFrameMap
    if not map then return nil end
    if n == 1 then return map["player"] end
    return map["party" .. (n - 1)]
end

-- First / last SHOWN frame in header order. Test pool first, falling through to the live
-- header when the preview has nothing on screen -- the same precedence
-- DF:GetPartyVisibleRect uses.
local function partyEdgeFrame(wantLast)
    local pool = testParty()
    if pool then
        local found
        for i = 0, 4 do
            local f = pool[i]
            if f and f.IsShown and f:IsShown() then
                if not wantLast then return f end
                found = f
            end
        end
        if found then return found end
    end
    local header = DF.partyHeader
    if not header then return nil end
    local found
    for i = 1, 5 do
        local f = header:GetAttribute("child" .. i)
        if f and f.IsShown and f:IsShown() then
            if not wantLast then return f end
            found = f
        end
    end
    return found
end

local function raidSlotFrame(n)
    local pool = testRaid()
    local f = pool and pool[n]
    if f then return f end
    local map = DF.unitFrameMap
    return map and map["raid" .. n] or nil
end

-- The player's own raid frame. In a raid the player is "raidN", not "player", so the map
-- has no "player" key to read -- UnitInRaid gives the N directly (it is the same index
-- GetRaidRosterInfo takes; see the ☠ note at DandersFrames_Options/GUI/Controls.lua:2919
-- for why there is no +1). The "player" fallback covers a party/solo roster, where the
-- header does key the player's frame that way.
-- In test mode the first raid frame is the stand-in player (TestMode.lua:2726 sets
-- isPlayer = (i == 1)).
local function raidMeFrame()
    local pool = testRaid()
    local f = pool and pool[1]
    if f then return f end
    local map = DF.unitFrameMap
    if not map then return nil end
    local idx = UnitInRaid and UnitInRaid("player")
    if idx then
        local raidFrame = map["raid" .. idx]
        if raidFrame then return raidFrame end
    end
    return map["player"]
end

-- Lowest / highest SHOWN raid index. Scanning unitFrameMap rather than walking
-- raidSeparatedHeaders: the map is one flat lookup per index and it is correct in BOTH
-- layouts, where the separated headers only exist in group layout (and go nil per group
-- while nameList sorting is on).
local function raidEdgeFrame(wantLast)
    local pool = testRaid()
    if pool then
        local found
        for i = 1, 40 do
            local f = pool[i]
            if f and f.IsShown and f:IsShown() then
                if not wantLast then return f end
                found = f
            end
        end
        if found then return found end
    end
    local map = DF.unitFrameMap
    if not map then return nil end
    local found
    for i = 1, 40 do
        local f = map["raid" .. i]
        if f and f.IsShown and f:IsShown() then
            if not wantLast then return f end
            found = f
        end
    end
    return found
end

local function partyRelevant() return DF.MoverBridge and DF.MoverBridge:IsScopeRelevant("party") or false end
local function raidRelevant()  return DF.MoverBridge and DF.MoverBridge:IsScopeRelevant("raid")  or false end

-- ============================================================
-- SEMANTIC TARGETS
-- ============================================================
-- Registered once. getFrame/getRect are dynamic, so these six keys never churn: an
-- addon anchored to "the first party frame" keeps that anchor across every roster
-- change, resort and test-mode flip.

local function registerSemantic()
    Mover:RegisterAnchorTarget(ADDON_KEY, "party.me", {
        title    = L["My Party Frame"],
        group    = L["Party Frames"],
        getFrame = partyMeFrame,
        getRect  = function() return rectOf(partyMeFrame()) end,
        isRelevant = partyRelevant,
    })

    Mover:RegisterAnchorTarget(ADDON_KEY, "party.first", {
        title    = L["First Party Frame"],
        group    = L["Party Frames"],
        getFrame = function() return partyEdgeFrame(false) end,
        getRect  = function() return rectOf(partyEdgeFrame(false)) end,
        isRelevant = partyRelevant,
    })

    Mover:RegisterAnchorTarget(ADDON_KEY, "party.last", {
        title    = L["Last Party Frame"],
        group    = L["Party Frames"],
        getFrame = function() return partyEdgeFrame(true) end,
        getRect  = function() return rectOf(partyEdgeFrame(true)) end,
        isRelevant = partyRelevant,
    })

    Mover:RegisterAnchorTarget(ADDON_KEY, "raid.me", {
        title    = L["My Raid Frame"],
        group    = L["Raid Frames"],
        getFrame = raidMeFrame,
        getRect  = function() return rectOf(raidMeFrame()) end,
        isRelevant = raidRelevant,
    })

    Mover:RegisterAnchorTarget(ADDON_KEY, "raid.first", {
        title    = L["First Raid Frame"],
        group    = L["Raid Frames"],
        getFrame = function() return raidEdgeFrame(false) end,
        getRect  = function() return rectOf(raidEdgeFrame(false)) end,
        isRelevant = raidRelevant,
    })

    Mover:RegisterAnchorTarget(ADDON_KEY, "raid.last", {
        title    = L["Last Raid Frame"],
        group    = L["Raid Frames"],
        getFrame = function() return raidEdgeFrame(true) end,
        getRect  = function() return rectOf(raidEdgeFrame(true)) end,
        isRelevant = raidRelevant,
    })
end

-- ============================================================
-- DYNAMIC SLOT TARGETS
-- ============================================================

local function track(scope, key)
    local t = MT.registered[scope]
    t[#t + 1] = key
end

local function registerPartySlots()
    for n = 1, 5 do
        -- Present-slots-only: a slot with no frame right now is not registered at all.
        if partySlotFrame(n) then
            local key = "party.slot" .. n
            Mover:RegisterAnchorTarget(ADDON_KEY, key, {
                title    = format(L["Party Slot %d"], n),
                group    = L["Party Frames"],
                getFrame = function() return partySlotFrame(n) end,
                getRect  = function() return rectOf(partySlotFrame(n)) end,
                isRelevant = partyRelevant,
                snappable = false,
            })
            track("party", key)
        end
    end
end

local function registerRaidSlots()
    for n = 1, 40 do
        if raidSlotFrame(n) then
            local key = "raid.slot" .. n
            Mover:RegisterAnchorTarget(ADDON_KEY, key, {
                title    = format(L["Raid Slot %d"], n),
                group    = L["Raid Frames"],
                getFrame = function() return raidSlotFrame(n) end,
                getRect  = function() return rectOf(raidSlotFrame(n)) end,
                isRelevant = raidRelevant,
                snappable = false,
            })
            track("raid", key)
        end
    end
end

-- Per-group targets: the separated group headers and their five child slots.
--
-- LIVE ONLY. Raid test mode previews with the non-secure testRaidFrames pool parented to
-- DF.testRaidContainer and never touches raidSeparatedHeaders, so while it is up the
-- headers are empty and a group target could only report "unavailable". The plain
-- raid.slotN keys above cover the preview.
--
-- ⚠ RELABEL RULE. A separated header normally filters to its own subgroup, but nameList
-- sorting NILS groupFilter -- the header then holds whatever units the name list gave it,
-- which is very often not group N at all. Rather than hide the target (a saved anchor
-- would break every time sorting is switched on) the title says so: "Raid Group 3" when
-- the header is honestly group 3, "Raid Group 3 (header)" when it is just the third
-- header. ⚠ Baked at registration time, so it follows a sorting change on the next
-- rebuild rather than the instant the setting is flipped.
local function registerRaidGroups()
    if testRaid() then return end
    local headers = DF.raidSeparatedHeaders
    if not headers then return end
    for N = 1, 8 do
        local header = headers[N]
        if header then
            local honest = header:GetAttribute("groupFilter") == tostring(N)
            -- The picker bucket is the group either way -- only the TITLE carries the
            -- caveat, so the eight groups stay eight groups in the list.
            local bucket = format(L["Raid Group %d"], N)
            local key = "raid.group" .. N
            Mover:RegisterAnchorTarget(ADDON_KEY, key, {
                title    = honest and bucket or format(L["Raid Group %d (header)"], N),
                group    = bucket,
                getFrame = function()
                    local h = DF.raidSeparatedHeaders
                    return h and h[N] or nil
                end,
                -- The header frame itself is sized by the secure template and is not what
                -- the user sees, so measure the union of its SHOWN children -- exactly how
                -- MoverBridge measures the party container. nil when none are shown.
                getRect  = function()
                    local h = DF.raidSeparatedHeaders
                    h = h and h[N]
                    if not h then return nil end
                    local acc
                    for i = 1, 5 do acc = union(acc, h:GetAttribute("child" .. i)) end
                    if not acc then return nil end
                    return { x = (acc.l + acc.r) / 2, y = (acc.b + acc.t) / 2,
                             w = acc.r - acc.l,       h = acc.t - acc.b }
                end,
                isRelevant = raidRelevant,
                snappable = false,
            })
            track("raid", key)

            for M = 1, 5 do
                if header:GetAttribute("child" .. M) then
                    local slotKey = key .. ".slot" .. M
                    local function slotFrame()
                        local h = DF.raidSeparatedHeaders
                        h = h and h[N]
                        return h and h:GetAttribute("child" .. M) or nil
                    end
                    Mover:RegisterAnchorTarget(ADDON_KEY, slotKey, {
                        title    = honest and format(L["Group %d Slot %d"], N, M)
                                          or  format(L["Group %d Slot %d (header)"], N, M),
                        group    = bucket,
                        getFrame = slotFrame,
                        getRect  = function() return rectOf(slotFrame()) end,
                        isRelevant = raidRelevant,
                        snappable = false,
                    })
                    track("raid", slotKey)
                end
            end
        end
    end
end

-- ============================================================
-- REBUILD + FAN-OUT
-- ============================================================

-- Tracked slot keys plus the scope's three semantic keys. The returned table is REUSED
-- per scope: this runs on every container move as well as on every rebuild, and
-- Mover:RefreshAnchorTargets copies the keys into its own id list before doing any work,
-- so the reuse is never visible to the lib. Do not hold on to the result.
local keyScratch = { party = {}, raid = {} }

function MT:SubTargetKeys(scope)
    scope = (scope == "raid") and "raid" or "party"
    local out = keyScratch[scope]
    wipe(out)
    for _, key in ipairs(self.registered[scope]) do out[#out + 1] = key end
    for _, key in ipairs(SEMANTIC[scope]) do out[#out + 1] = key end
    return out
end

-- Unregister everything this scope had, then register what is present now. Whole-list
-- rebuild rather than a diff: the frame behind a slot changes far more often than the
-- slot COUNT does, and every getFrame is a closure that re-resolves anyway, so a diff
-- would save nothing but the registry writes.
function MT:RefreshUnitTargets(scope)
    scope = (scope == "raid") and "raid" or "party"
    local tracked = self.registered[scope]
    for _, key in ipairs(tracked) do Mover:Unregister(ADDON_KEY, key) end
    wipe(tracked)

    if scope == "party" then
        registerPartySlots()
    else
        registerRaidSlots()
        registerRaidGroups()
    end

    -- One batched re-solve for the scope's slots AND its semantic keys, so everything
    -- anchored to any of them settles in a single pass instead of one pass per key.
    Mover:RefreshAnchorTargets(ADDON_KEY, self:SubTargetKeys(scope))
    DF:Debug("LAYOUT", "MoverTargets: rebuilt %s targets (%d registered)", scope, #tracked)
end

-- Shared debounce. A raid join fires GROUP_ROSTER_UPDATE several times in a row and a
-- group-wide reshuffle fires OnFramesSorted for both scopes, so every trigger funnels
-- through here and BOTH scopes are rebuilt once at the end.
function MT:RequestUnitTargetRefresh()
    if self.pending then return end
    self.pending = true
    C_Timer.After(0.1, function()
        MT.pending = false
        MT:RefreshUnitTargets("party")
        MT:RefreshUnitTargets("raid")
    end)
end

-- Published on the bridge so Features\MoverBridge.lua -- which loads FIRST and must keep
-- working with this file absent -- can call them behind a plain nil check.
if Bridge then
    function Bridge:RefreshUnitTargets(scope) return MT:RefreshUnitTargets(scope) end
    function Bridge:RequestUnitTargetRefresh() return MT:RequestUnitTargetRefresh() end
    function Bridge:SubTargetKeys(scope) return MT:SubTargetKeys(scope) end
end

-- ============================================================
-- INIT
-- Called from Bridge:Init, itself called from Core.lua's ADDON_LOADED.
-- ============================================================
function MT:Init()
    if self.initialised then return end
    self.initialised = true
    registerSemantic()
    -- DF's own external API event: fires one frame after any unit frame has its `unit`
    -- attribute reassigned, which is exactly when a slot's frame stops meaning what it
    -- did (Core/API.lua:849). CallbackHandler is embedded on DF, which IS the
    -- DandersFrames global, and Core\API.lua loads after this file -- fine, because Init
    -- runs on ADDON_LOADED, long after every file is in.
    if DF.RegisterCallback then
        DF.RegisterCallback(MT, "OnFramesSorted", function() MT:RequestUnitTargetRefresh() end)
    end
    self:RefreshUnitTargets("party")
    self:RefreshUnitTargets("raid")
    DF:Debug("LAYOUT", "MoverTargets: per-unit and per-group anchor targets registered")
end
