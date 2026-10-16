local NS = ...

-- ============================================================
-- SPEC INSPECT QUEUE vs THE USER'S OWN INSPECT
-- DandersFrames/Features/SecureSort.lua  InspectUIBusy / ProcessInspectQueue / OnInspectReady
-- ------------------------------------------------------------
-- The client holds ONE inspect target. Blizzard's InspectFrame_Show sets .unit and calls
-- NotifyInspect at once but only SHOWS on INSPECT_READY, so an IsShown() test let DF's
-- queue re-target and clear mid-load and the window opened empty (v5.3.3 report). The
-- real functions are lifted by name and run against stubs.
-- ============================================================

print("-- Spec inspect queue: never steals or clears the user's inspect")

local src = df_file_source("Features/SecureSort.lua"):gsub("\r\n", "\n")
local function cut(startPlain, endPlain)
    local a = src:find(startPlain, 1, true)
    local b = a and src:find(endPlain, a, true)
    check(a ~= nil and b ~= nil, "source: " .. startPlain:sub(1, 40) .. " is locatable")
    return (a and b) and src:sub(a, b + #endPlain - 1) or ""
end
local helper = cut("local function InspectUIBusy()", "\nlocal INSPECT_MAX_ATTEMPTS = 3\n")
local queue  = cut("function SecureSort:QueueInspect(unit)", "\n-- Debounce party-sort re-runs") .. "\n"
local ready  = cut("function SecureSort:OnInspectReady(guid)", "\n-- Scan current group and queue inspections")

local W   -- the world each scenario builds
local prelude = [==[
local W = ...
local SecureSort = { specCache = {}, inspectQueue = {}, inspectInProgress = false, inspectAttempts = {} }
local DF = {}
local function canaccessvalue(v) return v ~= nil end
local function GetCacheableName(unit) return W.names[unit] end
local function UnitExists(u) return W.guids[u] ~= nil end
local function UnitIsPlayer(u) return true end
local function UnitIsUnit(a, b) return a == b end
local function UnitGUID(u) return W.guids[u] end
local function InCombatLockdown() return false end
local function IsInRaid() return true end
local function NotifyInspect(u) W.log[#W.log + 1] = "NI " .. u end
local function ClearInspectPlayer() W.log[#W.log + 1] = "CIP" end
local function GetInspectSpecialization(u) return W.spec[u] or 0 end
local C_SpecializationInfo = {}
local C_Timer = { After = function(t, fn) W.timers[#W.timers + 1] = { t = t, fn = fn } end }
local InspectFrame = W.inspectFrame
local PlayerSpellsFrame = W.spellsFrame
function SecureSort:CacheUnitSpec(unit, specID) self.specCache[W.names[unit]] = specID end
]==]

local function World()
    local w = {
        guids = { raid16 = "G16", target = "GT", raid2 = "G2" },
        names = { raid16 = "Sixteen", target = "Target", raid2 = "Two" },
        spec = { raid16 = 105, raid2 = 264 },
        log = {}, timers = {},
        inspectFrame = { unit = nil, shown = false },
        spellsFrame = { inspecting = false },
    }
    w.inspectFrame.IsShown = function(self) return self.shown end
    w.spellsFrame.IsInspecting = function(self) return self.inspecting end
    local env = assert(loadstring(prelude .. helper .. queue .. ready .. "\nreturn SecureSort"))
    w.SS = env(w)
    return w
end
local function runTimers(w, maxT)
    local list = w.timers
    w.timers = {}
    for _, t in ipairs(list) do
        if not maxT or t.t <= maxT then t.fn() else w.timers[#w.timers + 1] = t end
    end
end
local function has(log, entry)
    for _, e in ipairs(log) do if e == entry then return true end end
    return false
end

-- ---- the report: the user inspects while Blizzard's window is still LOADING -------
do
    W = World()
    W.inspectFrame.unit = "target"          -- InspectFrame_Show ran; window not shown yet
    W.SS:QueueInspect("raid16")
    check(not has(W.log, "NI raid16"), "loading: DF does not switch the target while the window loads")
    eq(W.SS.inspectQueue.G16, "raid16", "loading: ...and keeps the unit queued for later")
end

-- ---- our answer arrives while the user's inspect owns the target -------------------
do
    W = World()
    W.SS:QueueInspect("raid16")
    check(has(W.log, "NI raid16"), "ours: the queue asks when nothing else is inspecting")
    W.inspectFrame.unit = "raid16"         -- the user inspects the same raider meanwhile
    W.log = {}
    W.SS:OnInspectReady("G16")
    check(not has(W.log, "CIP"), "busy: the answer never clears the user's inspect")
    eq(W.SS.specCache.Sixteen, 105, "busy: ...but the spec it carried is kept")
    eq(W.SS.inspectQueue.G16, nil, "busy: ...so the unit leaves the queue")
end

-- ---- busy and no spec read: stay queued --------------------------------------------
do
    W = World()
    W.spec.raid16 = 0
    W.SS:QueueInspect("raid16")
    W.inspectFrame.unit = "target"
    W.SS:OnInspectReady("G16")
    eq(W.SS.inspectQueue.G16, "raid16", "busy, nothing read: the unit stays queued to ask again")
end

-- ---- the talent frame's inspect mode counts too ------------------------------------
do
    W = World()
    W.spellsFrame.inspecting = true
    W.SS:QueueInspect("raid16")
    check(not has(W.log, "NI raid16"), "talents: DF waits while the talent frame is inspecting")
end

-- ---- nothing busy: the normal path still clears and moves on -----------------------
do
    W = World()
    W.SS:QueueInspect("raid16")
    W.SS:OnInspectReady("G16")
    check(has(W.log, "CIP"), "idle: our own inspect is cleared as before")
    eq(W.SS.specCache.Sixteen, 105, "idle: ...with the spec cached")
end

-- ---- a lost answer no longer stalls the queue --------------------------------------
do
    W = World()
    W.SS:QueueInspect("raid16")
    W.SS:QueueInspect("raid2")
    local first = W.log[#W.log]
    W.log = {}
    runTimers(W, 5)                         -- the 5s timeout fires with no INSPECT_READY
    check(#W.log == 1 and W.log[1]:sub(1, 3) == "NI ", "timeout: an unanswered request moves the queue on")
    -- an answer that arrives late spends the token: the old timeout must not fire again
    local unit = W.log[1]:sub(4)
    W.SS:OnInspectReady(W.guids[unit])
    local before = #W.log
    runTimers(W, 5)
    local extra = 0
    for i = before + 1, #W.log do if W.log[i]:sub(1, 3) == "NI " then extra = extra + 1 end end
    check(extra <= 1, "timeout: an answered request's timeout stands down")
    check(first ~= nil, "timeout: (first request was sent)")
end

-- ---- a unit that never answers is dropped after a few tries ------------------------
do
    W = World()
    W.guids = { raid16 = "G16" }
    W.SS:QueueInspect("raid16")
    for _ = 1, 6 do runTimers(W) end
    eq(W.SS.inspectQueue.G16, nil, "attempts: a unit that never answers leaves the queue")
    local asks = 0
    for _, e in ipairs(W.log) do if e == "NI raid16" then asks = asks + 1 end end
    eq(asks, 3, "attempts: ...after three requests")
end
