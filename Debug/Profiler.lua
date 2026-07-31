local addonName, DF = ...

-- ============================================================
-- DANDERSFRAMES FUNCTION PROFILER
--
-- Zero overhead when disabled: uses function-swapping to wrap
-- DF:Method() calls with debugprofilestop() timing. When stopped,
-- original functions are fully restored — no runtime checks,
-- no wrappers, no cost.
--
-- Two things make the numbers trustworthy rather than merely indicative:
--   * Self time. Profiled functions call other profiled functions, so every
--     Total contains its children. Self strips them back out, and it is what
--     the % column ranks — see the CALL STACK block below.
--   * Overhead subtraction. The wrapper's own in-window cost is measured on
--     the machine at Start and removed from every figure, so a function
--     called 200,000 times is not penalised against one called 200.
-- Both are corrections, not guarantees; the residuals are documented at
-- CalibrateOverhead.
--
-- Usage:
--   /df debug profiler             Toggle the profiler UI
--   /df debug profile [seconds]    Quick run for N seconds (default 10)
-- ============================================================

local debugprofilestop = debugprofilestop
local collectgarbage = collectgarbage
local format = string.format
local sort = table.sort
local floor = math.floor
local max = math.max
local wipe = wipe
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local CreateFrame = CreateFrame

-- Shared tick counter, incremented once per OnUpdate frame.
-- Wrapped functions read this via upvalue to detect "new tick" without
-- needing access to any timer state.
local tickRef = { 0 }

-- ============================================================
-- CALL STACK (for exclusive / "self" time)
-- ----------------------------------------------------------
-- Every wrapper is a stack frame. On the way in it pushes a slot; on the
-- way out it adds its own inclusive time and call count into its PARENT's
-- slot. Self time is then just `elapsed - childMs[myDepth]`.
--
-- Why this matters: wrapped functions call other wrapped functions —
-- UpdateAllAuras -> UpdateAuras_Enhanced, and UpdateTextDesigner ->
-- Render.UpdateFrame -> Resolver.Resolve three deep by design. Every level's
-- `total` contains its children, so summing the rows counted the same
-- microsecond two and three times and the % column was a share of an
-- invented denominator. Self time sums correctly; inclusive time does not.
--
-- Only WRAPPED children are subtracted, which is exactly right: time in an
-- unwrapped local helper genuinely belongs to the function that called it.
--
-- ☠ callDepth must never be allowed to ratchet. A Lua error inside a
-- profiled function unwinds past the decrement, leaving the counter high
-- forever and every subsequent call recorded as somebody's child. The tick
-- driver below resets it every frame, which is safe because nothing here
-- yields: no DF call is ever still on the stack when a new frame starts.
local callDepth = 0
local childMs = {}   -- [depth] = inclusive ms of wrapped children at that depth
local childN  = {}   -- [depth] = count of wrapped calls beneath that depth

-- ============================================================
-- STATE
-- ============================================================

local Profiler = {
    active = false,
    startTime = 0,          -- debugprofilestop() ms when started
    stopTime = 0,           -- debugprofilestop() ms when stopped (for accurate elapsed)
    combatAuto = false,     -- auto start/stop on combat enter/leave
    splitByFrame = false,   -- show per-frame-type breakdown
    viewMode = "functions", -- "functions" | "events"
    overheadMs = 0,         -- measured cost the wrapper adds to each call (ms)
    data = {},              -- [funcName|type] = { calls, total, selfMs, descN, max, mem }
    tickStats = {},         -- [funcName] = { lastTick, calls, maxPerTick }
    originals = {},         -- [funcPath] = { table, key, original }
    eventData = {},         -- [eventName] = { calls, total, max, mem, source }
    eventOriginals = {},    -- [dispatcherKey] = { container, key, original }
    updateData = {},        -- [frameLabel] = { calls, total, max, mem }
    sortColumn = "total",
    sortDesc = true,
}

DF.Profiler = Profiler

-- Forward declarations (referenced by combat handler before defined below)
local profilerFrame = nil
local dataRows = {}
local headerTexts = {}
local UpdateUI  -- assigned later when UI functions are defined

-- Combat auto-profile event frame (created once, persists)
local combatFrame = CreateFrame("Frame")
combatFrame:Hide()

-- Per-tick driver: increments tickRef[1] every OnUpdate frame so wrapped
-- functions can detect "new tick" and aggregate per-tick call counts.
-- Hidden when profiler is stopped (no OnUpdate runs).
local tickFrame = CreateFrame("Frame")
tickFrame:Hide()
tickFrame:SetScript("OnUpdate", function()
    tickRef[1] = tickRef[1] + 1
    -- Self-heal the call-stack depth (see the ☠ note on callDepth). A clean
    -- frame always ends at 0, so this is a no-op except after an error.
    callDepth = 0
end)

-- ============================================================
-- ONUPDATE REGISTRY + SETSCRIPT HOOK
-- ----------------------------------------------------------
-- Tracking OnUpdate handlers requires a different mechanism than
-- function or event wrapping. OnUpdate scripts are bound directly to
-- frames via SetScript, so there's no DF-owned function we can swap.
--
-- Strategy: hook Frame:SetScript at addon load. Whenever a *DF-owned*
-- frame installs/removes an OnUpdate handler, we record the latest
-- handler in a registry. The registry alone has effectively zero
-- overhead — just one table assignment per SetScript call. No wrapping,
-- no instrumentation.
--
-- On Profiler:Start, we walk the registry and replace each recorded
-- handler with a wrapped version that records timing + memory. New
-- OnUpdate handlers installed *after* Start are wrapped on the spot
-- by the same hook. On Stop, all originals are restored.
--
-- The `installingOnUpdate` guard prevents the hook from re-wrapping
-- our own wrapper as we install it (otherwise infinite recursion).
--
-- CRITICAL: we must filter to DF-owned frames only. If we wrap a
-- non-DF frame's OnUpdate (especially Blizzard's CompactRaidFrame
-- secure frames), our wrapper closure runs inside that frame's
-- update cascade and the execution context gets marked as
-- "tainted by DandersFrames". That taint propagates to every
-- UnitIsConnected / UnitHealthMax / etc. secret-value return and
-- every protected Show()/Hide() call downstream — breaking secure
-- Blizzard code and producing ADDON_ACTION_BLOCKED errors. This was
-- the cause of a raid-session bug report on 2026-04-08.
--
-- The filter walks the frame's parent chain looking for any ancestor
-- whose name starts with "Danders" or "DF" — DF's named containers
-- and headers all use these prefixes (DandersPartyHeader,
-- DandersArenaHeader, DandersRaidGroupN, DFTestHeader, etc.). If no
-- ancestor has a DF name, the frame is foreign and must be skipped.
-- ============================================================

local onUpdateRegistry = {}      -- [frame] = handler ref currently bound (or nil)
local onUpdateLabels = {}        -- [frame] = stable label for display
local onUpdateDFCheck = {}       -- [frame] = true/false cached IsDFFrame result
local onUpdateWrapped = {}       -- [frame] = { original, stats } (only while active)
local installingOnUpdate = false -- re-entry guard for the SetScript hook

-- Is this frame owned by DandersFrames? Walks up the parent chain
-- looking for an ancestor whose name starts with "Danders" or "DF".
-- DF's secure headers and containers are all explicitly named with
-- one of these prefixes (see Frames/Headers.lua). Anonymous DF child
-- frames inherit their DF-ness from a named ancestor, so the walk
-- catches them too.
--
-- Results are cached per-frame because this is called from the
-- SetScript hook on every OnUpdate (re)bind and we don't want to
-- re-walk the parent chain every time.
local function IsDFFrame(frame)
    local cached = onUpdateDFCheck[frame]
    if cached ~= nil then return cached end

    local walker = frame
    local depth = 0  -- safety cap against pathological cycles
    while walker and depth < 32 do
        -- pcall because some Blizzard template frames (e.g. RadialWheel
        -- wedge buttons) error on :GetName() with "bad self".
        local ok, name = pcall(walker.GetName, walker)
        if ok and name then
            local p2 = name:sub(1, 2)
            local p7 = name:sub(1, 7)
            if p7 == "Danders" or p2 == "DF" then
                onUpdateDFCheck[frame] = true
                return true
            end
        end
        local ok2, parent = pcall(walker.GetParent, walker)
        walker = (ok2 and parent) or nil
        depth = depth + 1
    end

    onUpdateDFCheck[frame] = false
    return false
end

-- Best-effort label for a frame. Uses GetDebugName() when available
-- (modern WoW gives a parent-chain path), falls back to GetName(),
-- finally a generic "<anon>". Captured once at first sighting so it
-- stays stable across renames.
local function ResolveFrameLabel(frame)
    local existing = onUpdateLabels[frame]
    if existing then return existing end
    local label
    if frame.GetDebugName then
        label = frame:GetDebugName()
    end
    if (not label or label == "") and frame.GetName then
        label = frame:GetName()
    end
    if not label or label == "" then
        label = "<anon:" .. tostring(frame):match("0x[%x]+") .. ">"
    end
    onUpdateLabels[frame] = label
    return label
end

-- Forward declaration so the SetScript hook can call WrapFrameOnUpdate
-- before it's defined further down (it lives inside Profiler:Start's
-- closure scope and needs to share state with this hook).
local WrapFrameOnUpdate

-- ============================================================
-- ONUPDATE TRACKING HOOK
-- ============================================================
-- ☠ SAVEDVARIABLES ARE NOT LOADED WHEN THIS FILE EXECUTES.
-- This used to read DandersFramesDB_v2.profilerOnUpdateHook right here, at file
-- scope, and install the hook only if it was true. The global does not exist
-- yet at that point — it is populated before ADDON_LOADED, which is AFTER every
-- addon file has run — so the read was always nil and the hook was NEVER
-- installed, no matter what the saved file said. Ticking the box, reloading,
-- and finding it still off was that, exactly: the value saved correctly and was
-- then read a frame too early, forever.
-- Every other consumer of this table in the addon reads it inside a function
-- (DF:GetGlobalDB and friends) and so never hit this.
--
-- ⚠ The install CANNOT simply move to ADDON_LOADED either: this file sits at
-- TOC line 68 deliberately (see the "Profiler.lua is loaded earlier" note in
-- the TOC) so the hook is in place before the files that install an OnUpdate at
-- THEIR file scope — five ticker/throttle singletons across Headers, StatusIcons
-- and AutoProfiles, all of which load later. (A sixth lived in Performance.lua,
-- since deleted.) Installing at
-- ADDON_LOADED would miss every one of them.
--
-- So: install unconditionally and record from the first moment, then resolve the
-- user's setting at ADDON_LOADED and drop everything if they had it off. The
-- cost of being wrong for that one window is a table of a few dozen entries;
-- the cost of the hook itself when latched off is the two comparisons below,
-- since scriptType ~= "OnUpdate" rejects almost every SetScript call in the game
-- before anything else happens.
local onUpdateHookEnabled = nil   -- nil = undecided (still loading); resolved below
Profiler.onUpdateHookEnabled = onUpdateHookEnabled

local frameMeta = getmetatable(CreateFrame("Frame")).__index
hooksecurefunc(frameMeta, "SetScript", function(frame, scriptType, handler)
    if onUpdateHookEnabled == false then return end   -- latched off at ADDON_LOADED
    if installingOnUpdate then return end
    if scriptType ~= "OnUpdate" then return end
    if not IsDFFrame(frame) then return end  -- skip non-DF frames (taint safety)

    if handler then
        onUpdateRegistry[frame] = handler
        ResolveFrameLabel(frame)
        -- If profiler is currently recording, wrap the new handler
        -- right now so this newly added OnUpdate is visible from its
        -- first frame. ⚠ Except our own window: opening the profiler UI
        -- mid-recording installs its refresh handler through this hook, and
        -- Profiler:Start's exclusion list only covers frames that already
        -- existed. Both doors need the same guard.
        if Profiler.active and WrapFrameOnUpdate
            and frame ~= tickFrame and frame ~= profilerFrame then
            WrapFrameOnUpdate(frame, handler)
        end
    else
        -- nil handler = OnUpdate removed; drop bookkeeping.
        onUpdateRegistry[frame] = nil
        if onUpdateWrapped[frame] then
            onUpdateWrapped[frame] = nil
        end
    end
end)

-- Resolve the setting at the first moment SavedVariables actually exist.
local hookSettingFrame = CreateFrame("Frame")
hookSettingFrame:RegisterEvent("ADDON_LOADED")
hookSettingFrame:SetScript("OnEvent", function(self, _, loadedAddon)
    if loadedAddon ~= addonName then return end
    self:UnregisterEvent("ADDON_LOADED")
    onUpdateHookEnabled = (DandersFramesDB_v2
        and DandersFramesDB_v2.profilerOnUpdateHook == true) or false
    Profiler.onUpdateHookEnabled = onUpdateHookEnabled
    if not onUpdateHookEnabled then
        -- Opted out: throw away what the load window collected and latch the
        -- hook off. Nothing else in the profiler reads these while disabled.
        wipe(onUpdateRegistry)
        wipe(onUpdateLabels)
        wipe(onUpdateDFCheck)
    end
end)

combatFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_DISABLED" then
        -- Entering combat
        if not Profiler.active then
            Profiler:Start()
            if profilerFrame and profilerFrame:IsShown() and UpdateUI then
                UpdateUI()
            end
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Leaving combat
        if Profiler.active then
            Profiler:Stop()
            Profiler:PrintResults()
            if profilerFrame and profilerFrame:IsShown() and UpdateUI then
                UpdateUI()
            end
        end
    end
end)

function Profiler:SetCombatAuto(enabled)
    self.combatAuto = enabled
    if enabled then
        combatFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
        combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        DF:Say("Combat auto-profile |cff00ff00ON|r — will start on combat, stop + print on combat end.")
    else
        combatFrame:UnregisterEvent("PLAYER_REGEN_DISABLED")
        combatFrame:UnregisterEvent("PLAYER_REGEN_ENABLED")
        DF:Say("Combat auto-profile |cffff4444OFF|r")
    end
end

-- ============================================================
-- PROFILED FUNCTIONS
-- Each entry is a path string. Plain "Name" resolves to DF[Name].
-- Dotted "Mod.Sub.Name" resolves to DF.Mod.Sub.Name. Missing entries
-- are silently skipped, so it's safe to list optional features here.
-- ============================================================

local PROFILED_FUNCTIONS = {
    -- ----------------------------------------------------------
    -- Core per-unit updates (event hot path)
    -- ----------------------------------------------------------
    "UpdateUnitFrame",
    "UpdateHealthFast",        -- Lean UNIT_HEALTH hot path
    "UpdateHealth",
    "UpdatePower",
    "UpdateName",
    "UpdateFrame",
    "UpdateResourceBar",

    -- ----------------------------------------------------------
    -- Aura pipeline (12.1 factory: per-event cost is the sig-compare
    -- walk in the Drive* functions; Blizzard renders the icons)
    -- ----------------------------------------------------------
    "UpdateAuras_Enhanced",
    "RebuildDirectFilterStrings",
    "DriveBuffFactory",
    "DriveDebuffFactory",
    "DriveDefensiveFactory",
    "DriveMissingBuffFactory",
    "RefreshFactoryRows",
    "BuildAuraRowConfig",
    "BuildDebuffFilterRecords",
    "FilterRegistry.ResolveSelection",
    "FilterRegistry.SelectionSignature",

    -- ----------------------------------------------------------
    -- Dispel
    -- ----------------------------------------------------------
    "UpdateDispelOverlay",
    "UpdateDispelGradientHealth",
    "UpdateAllDispelOverlays",

    -- ----------------------------------------------------------
    -- Absorb / Heal Prediction
    -- ----------------------------------------------------------
    "UpdateAbsorb",
    "UpdateHealAbsorb",
    "UpdateHealPrediction",

    -- ----------------------------------------------------------
    -- Range
    -- ----------------------------------------------------------
    "UpdateRange",
    "UpdatePetRange",
    "RefreshRangeSpell",

    -- ----------------------------------------------------------
    -- Visual / Highlights / Health Fade
    -- ----------------------------------------------------------
    "UpdateHighlights",
    "UpdateAnimatedBorder",
    "ApplyDeadFade",
    "ApplyHealthColors",
    "ApplyBarOrientation",
    "ApplyHealthFadeAlpha",
    "UpdateHealthFade",
    "UpdatePetHealthFade",

    -- ----------------------------------------------------------
    -- Status icons (per-unit)
    -- ----------------------------------------------------------
    "UpdateRoleIcon",
    "UpdateLeaderIcon",
    "UpdateRaidTargetIcon",
    "UpdateReadyCheckIcon",
    "UpdateCenterStatusIcon",
    "UpdateSummonIcon",
    "UpdateResurrectionIcon",
    "UpdatePhasedIcon",
    "UpdateAFKIcon",
    "UpdateVehicleIcon",
    "UpdateRaidRoleIcon",
    "UpdateAllStatusIcons",         -- per-frame sweep of all icons
    "UpdateRestedIndicator",

    -- ----------------------------------------------------------
    -- Defensive / external def icons + missing-buff
    -- ----------------------------------------------------------
    "UpdateMissingBuffIcon",
    "UpdateExternalDefIcon",
    "UpdateDefensiveBar",

    -- ----------------------------------------------------------
    -- Aura Designer (per-frame)
    -- ----------------------------------------------------------
    "GetADTrackedSpellIDs",
    "GetClaimedDebuffCategories",
    "BuildADIdentityFilters",
    "AuraDesigner.Factory.SyncFrame",
    "AuraDesigner.Factory.ClearFrame",

    -- ----------------------------------------------------------
    -- Text Designer
    -- Driven from the central header dispatcher (tdRefresh, Frames/Headers.lua)
    -- once per event per frame — plus the pinned mirror — and "health" is one of
    -- the hints. On 12.1 the aura rows render game-side, so this is plausibly
    -- the largest per-frame consumer LEFT IN LUA. It was absent from this table
    -- entirely, which made the system most worth measuring invisible.
    --
    -- Three levels on purpose: the DF: entry gives the total, UpdateFrame is the
    -- per-frame worker, and Resolve is per ELEMENT — the multiplier that turns a
    -- cheap frame into an expensive one.
    --
    -- ⚠ Resolve is the highest-CALL-COUNT target in this table (elements ×
    -- frames × ticks), which is exactly the shape the overhead correction
    -- exists for: a per-call tax lands hardest on the row with the most calls.
    -- Its figure is now overhead-corrected rather than an upper bound. (The
    -- two collectgarbage("count") calls the wrapper makes never inflated it —
    -- they sit outside the timed window. They cost the GAME time while
    -- profiling, but they were never charged to the function.)
    --
    -- ⚠ Resolve lands in the UNCLASSIFIED ("?") bucket, and that is correct, not
    -- a bug: the bucket is picked from the first argument's .unit, and Resolve
    -- takes (elem, source) — an element config, not a frame. The other two are
    -- frame-first and split party/raid/pinned normally.
    -- ----------------------------------------------------------
    "UpdateTextDesigner",
    "TextDesigner.Render.UpdateFrame",
    "TextDesigner.Resolver.Resolve",

    -- (Removed) the Targeted Spells entry "UpdateTargetedSpellLayout" — that function
    -- went with the group-frame display. Not a silent stale entry: Profiler:Start
    -- reports targets it cannot resolve, so this printed an unresolved-target line on
    -- every profiler start.

    -- ----------------------------------------------------------
    -- Pets
    -- ----------------------------------------------------------
    "UpdatePetFrame",
    "UpdatePetHealth",
    "UpdatePetName",
    "ApplyPetFrameStyle",

    -- ----------------------------------------------------------
    -- Layout / Style (called per-frame on layout changes)
    -- ----------------------------------------------------------
    "ApplyFrameLayout",
    "ApplyFrameStyle",
    "FullFrameRefresh",

    -- ----------------------------------------------------------
    -- Bulk sweeps (called on roster / settings events)
    -- ----------------------------------------------------------
    "UpdateAllFrames",
    "UpdateAllPetFrames",
    "UpdateAllRaidPetFrames",
    "UpdateAllPetFramePositions",
    "UpdateAllAuras",
    "UpdateAllMissingBuffIcons",
    "UpdateAllFramesStatusIcons",
    "UpdateAllRoleIcons",
    "UpdateAllDefensiveBars",
    "UpdateAllExternalDefIcons",
    "UpdateAllElementAppearances",
    "UpdateAllFrameAppearances",
    "RefreshLiveFrames",
    "RefreshAllVisibleFrames",
    "RefreshRaidGroupFrames",
    "RefreshPartyFrames",
    "RefreshAllHeaderChildFrames",
    "RefreshRaidFlatFrames",
    "UpdateLiveRaidFrames",

    -- ----------------------------------------------------------
    -- Roster handling (called on GROUP_ROSTER_UPDATE)
    -- ----------------------------------------------------------
    "ProcessRosterUpdate",
    "ProcessRoleUpdate",
    "RebuildUnitFrameMap",
    "UpdateHeaderFrameCount",
    "UpdateRaidGroupOrderAttributes",
    "ApplyRaidGroupSorting",
    "ApplyPartyGroupSorting",

    -- ----------------------------------------------------------
    -- Power event registration (changes when role/spec/group changes)
    -- ----------------------------------------------------------
    "UpdatePowerEventRegistration",
    "UpdateAllPowerEventRegistration",

    -- ----------------------------------------------------------
    -- Blizzard integration
    -- ----------------------------------------------------------
    "UpdateBlizzardFrameVisibility",
}

-- ============================================================
-- PROFILED EVENT DISPATCHERS
-- Each entry points at a function on DF that the addon's event frames
-- call through. Wrapping these gives us per-event timing for everything
-- those frames receive — without touching individual modules.
-- ============================================================

local PROFILED_EVENT_DISPATCHERS = {
    -- Roster UNIT_* events: every UNIT_AURA / UNIT_HEALTH / UNIT_POWER
    -- for every roster member flows through this single trampoline.
    { container = DF, key = "_RouteRosterEvent",   source = "Roster" },
    -- Main eventFrame: ADDON_LOADED, GROUP_ROSTER_UPDATE,
    -- PLAYER_REGEN_*, PLAYER_SPECIALIZATION_CHANGED, etc.
    { container = DF, key = "_MainEventDispatcher", source = "Main" },
}

-- ============================================================
-- FORMAT HELPERS
-- ============================================================

local function CommaNumber(n)
    local s = tostring(floor(n))
    return s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

local function FormatMs(ms)
    if ms >= 1000 then
        return format("%.1fs", ms / 1000)
    elseif ms >= 0.1 then
        return format("%.1f", ms)
    else
        return format("%.2f", ms)
    end
end

local function FormatUs(ms)
    local us = ms * 1000
    if us >= 100 then return format("%.0f", us)
    elseif us >= 10 then return format("%.1f", us)
    else return format("%.2f", us) end
end

-- Bytes per call: small numbers as raw bytes, larger as KB.
-- "0" -> "·" so the row reads cleanly when there's no allocation.
local function FormatBytes(b)
    if b <= 0 then return "·" end
    if b >= 1024 * 10 then
        return format("%.0fk", b / 1024)
    elseif b >= 1024 then
        return format("%.1fk", b / 1024)
    elseif b >= 100 then
        return format("%.0f", b)
    else
        return format("%.0f", b)
    end
end

local function FormatPeak(n)
    if n <= 0 then return "·" end
    if n >= 1000 then return format("%.1fk", n / 1000) end
    return tostring(n)
end

local function FormatElapsed(seconds)
    if seconds >= 60 then
        return format("%dm %ds", floor(seconds / 60), floor(seconds % 60))
    else
        return format("%.1fs", seconds)
    end
end

-- ============================================================
-- OVERHEAD CALIBRATION
-- ============================================================
-- The wrapper cannot measure a function without also measuring a little of
-- itself. What lands INSIDE the timed window is the tail of the opening
-- debugprofilestop, the vararg pack and 5-return dispatch into the original,
-- and the head of the closing debugprofilestop. Small — but it is charged
-- once per call, so it scales with call COUNT, not with cost. Left
-- uncorrected it quietly taxes the hot-and-cheap functions (Resolver.Resolve
-- runs elements x frames x ticks) and barely touches the cold-and-expensive
-- ones, which is precisely backwards from what you want when ranking.
--
-- So measure it: run the identical pattern around a function that does
-- nothing, and whatever it reports IS the overhead.
--
-- ⚠ THE ESTIMATOR IS THE MINIMUM OF BATCH MEANS, and the batches are kept
-- SHORT on purpose. Averaging within a batch is what defeats timer
-- quantisation — individual samples of a do-nothing call frequently read 0,
-- so a minimum over raw samples would report ~0 and under-subtract, which is
-- worse than not correcting at all. Taking the minimum ACROSS batches is what
-- discards contamination: a batch that caught a GC step reads high, and only
-- the cleanest batch is kept. Long batches break that, because with enough
-- iterations every batch catches a GC step and the "clean" floor is a floor
-- of dirty numbers. Hence many short batches rather than a few long ones.
--
-- ⚠ KEEP THIS LOOP SHAPED LIKE THE REAL WRAPPER. It mimics the call form
-- deliberately: two args plus varargs in, five returns captured out. Change
-- the wrappers' call form and this stops measuring the same thing, and the
-- correction silently becomes wrong rather than absent.
--
-- What this does NOT remove: the rest of the wrapper (the two
-- collectgarbage("count") calls, the bucket writes, the stack push/pop) sits
-- outside the window and so never enters this row's own numbers — but for a
-- NESTED call it does land inside its parent's window, where nothing can
-- separate it from real work. Deeply-nested rows therefore keep a small
-- residual. It is bounded by (wrapped calls beneath) x (a fraction of a
-- microsecond) and is the reason the legend says "corrected", not "exact".
-- 25 x 80 = the same 2000 samples as the original 5 x 500, redistributed so a
-- GC-free batch is likely to exist. See the estimator note above before changing
-- these: raising ITERS while lowering BATCHES quietly re-breaks the correction.
local CAL_BATCHES = 25
local CAL_ITERS = 80

local function CalibrateOverhead()
    local noop = function() end
    local dummy = {}

    -- One wrapper-shaped measurement. Returns what the wrapper would have
    -- recorded for a call that costs nothing.
    local function measureOnce(selfArg, a1, ...)
        local t0 = debugprofilestop()
        local r1, r2, r3, r4, r5 = noop(selfArg, a1, ...)
        return debugprofilestop() - t0
    end

    -- Warm-up: first calls through a fresh closure are not representative.
    for _ = 1, CAL_ITERS do measureOnce(dummy, 1) end

    local best
    for _ = 1, CAL_BATCHES do
        local sum = 0
        for _ = 1, CAL_ITERS do
            sum = sum + measureOnce(dummy, 1)
        end
        local mean = sum / CAL_ITERS
        if not best or mean < best then best = mean end
    end

    return best or 0
end

-- Strip the instrumentation's own cost out of one row.
--   ownCalls  invocations of this row itself
--   deepCalls wrapped invocations nested beneath it — their in-window
--             overhead is sitting inside this row's INCLUSIVE total, so it
--             comes off the total but not off self time.
-- Clamped: a function genuinely cheaper than the wrapper reads as 0 rather
-- than negative, and self can never exceed the corrected inclusive total.
local function Corrected(totalMs, selfMs, ownCalls, deepCalls)
    local oh = Profiler.overheadMs
    if oh <= 0 then return totalMs, selfMs end
    local t = totalMs - oh * (ownCalls + (deepCalls or 0))
    local s = selfMs - oh * ownCalls
    if t < 0 then t = 0 end
    if s < 0 then s = 0 end
    if s > t then s = t end
    return t, s
end

-- (Removed) SumCorrected. It walked the raw buckets and corrected each one, while
-- GetSortedResults aggregates a function's per-frame-type buckets FIRST and corrects
-- the total once. Those are not the same number: Corrected clamps at zero, so
-- correcting five buckets independently and adding them loses the negative headroom
-- that a single combined correction keeps. The status line and the % denominator
-- could therefore disagree. GetGrandTotalMs now asks GetSortedResults instead, so
-- there is one aggregation and they cannot drift apart.

-- ============================================================
-- CORE PROFILING
-- ============================================================

-- Resolve a dotted path like "Mod.Sub.Name" against the DF table.
-- Returns: container_table, leaf_key, current_value (or nil if anything is missing).
local function ResolveFunctionPath(path)
    local container = DF
    local lastDot = 1
    while true do
        local dot = path:find(".", lastDot, true)
        if not dot then
            local key = path:sub(lastDot)
            return container, key, container[key]
        end
        local segment = path:sub(lastDot, dot - 1)
        container = container[segment]
        if type(container) ~= "table" then return nil end
        lastDot = dot + 1
    end
end

-- Wrap a single frame's OnUpdate handler. Idempotent: a second call on
-- the same frame is a no-op so prospective wrapping from the SetScript
-- hook can't double-instrument. Stats are keyed by the frame's label,
-- which means multiple frames sharing a name (rare, e.g. pooled frames)
-- aggregate into one row — usually what you want.
WrapFrameOnUpdate = function(frame, original)
    if onUpdateWrapped[frame] then return end

    local label = ResolveFrameLabel(frame)
    local stats = Profiler.updateData[label]
    if not stats then
        stats = { calls = 0, total = 0, selfMs = 0, descN = 0, max = 0, mem = 0 }
        Profiler.updateData[label] = stats
    end

    local wrapped = function(self, elapsed, ...)
        -- OnUpdate handlers are stack ROOTS in practice (the C layer calls
        -- them sequentially, never nested) but they call plenty of wrapped DF
        -- methods, so they push a frame like everything else — that is what
        -- keeps "time in the handler itself" separate from "time in the
        -- functions it drove".
        local d = callDepth + 1
        callDepth = d
        childMs[d] = 0
        childN[d] = 0

        local m0 = collectgarbage("count")
        local t0 = debugprofilestop()
        original(self, elapsed, ...)
        local elapsedMs = debugprofilestop() - t0
        local mDelta = collectgarbage("count") - m0
        if mDelta < 0 then mDelta = 0 end

        local ct, cn = childMs[d], childN[d]
        callDepth = d - 1
        if d > 1 then
            childMs[d - 1] = childMs[d - 1] + elapsedMs
            childN[d - 1] = childN[d - 1] + cn + 1
        end
        local selfDelta = elapsedMs - ct
        if selfDelta < 0 then selfDelta = 0 end

        stats.calls = stats.calls + 1
        stats.total = stats.total + elapsedMs
        stats.selfMs = stats.selfMs + selfDelta
        stats.descN = stats.descN + cn
        stats.mem = stats.mem + mDelta
        if elapsedMs > stats.max then stats.max = elapsedMs end
    end

    onUpdateWrapped[frame] = { original = original, wrapped = wrapped }

    installingOnUpdate = true
    frame:SetScript("OnUpdate", wrapped)
    installingOnUpdate = false
end

function Profiler:Start()
    if self.active then
        DF:Say("Already recording.")
        return
    end

    -- Measure the wrapper's own in-window cost before anything is wrapped, so
    -- the correction reflects THIS machine under THESE conditions rather than
    -- a constant baked in at authoring time. Taken before startTime so the
    -- calibration loop itself never lands inside the profiled window.
    self.overheadMs = CalibrateOverhead()

    self.active = true
    self.startTime = debugprofilestop()
    self.stopTime = 0
    self:_SnapshotContainerStats()
    self.containerDelta = nil
    wipe(self.data)
    wipe(self.tickStats)
    wipe(self.originals)
    wipe(self.eventData)
    wipe(self.eventOriginals)
    wipe(self.updateData)
    tickRef[1] = 0
    callDepth = 0

    local wrapped = 0
    -- ☠ An unresolved target used to vanish without a trace: the branch below
    -- just skips it, and the "N functions instrumented" line gives no clue that
    -- N is short. Rename or delete a profiled function and it silently stops
    -- being measured — you read a clean profile and conclude the system is
    -- cheap. Collect the misses and name them.
    local missing = {}
    local typeCheck = type  -- cache as upvalue

    for _, path in ipairs(PROFILED_FUNCTIONS) do
        local container, key, original = ResolveFunctionPath(path)
        local resolved = container and type(original) == "function"
        if not resolved then missing[#missing + 1] = path end
        if resolved then
            -- Save originals so Stop() can fully restore.
            self.originals[path] = { container = container, key = key, original = original }

            -- Per-frame-type buckets. Each entry tracks: calls, total
            -- (inclusive) ms, selfMs (exclusive of wrapped children), descN
            -- (wrapped calls beneath, for the overhead correction), max
            -- single-call ms, and total memory delta (KB).
            local dP  = { calls = 0, total = 0, selfMs = 0, descN = 0, max = 0, mem = 0 }
            local dR  = { calls = 0, total = 0, selfMs = 0, descN = 0, max = 0, mem = 0 }
            local dHP = { calls = 0, total = 0, selfMs = 0, descN = 0, max = 0, mem = 0 }
            local dHR = { calls = 0, total = 0, selfMs = 0, descN = 0, max = 0, mem = 0 }
            local dU  = { calls = 0, total = 0, selfMs = 0, descN = 0, max = 0, mem = 0 }

            self.data[path .. "|P"]  = dP
            self.data[path .. "|R"]  = dR
            self.data[path .. "|HP"] = dHP
            self.data[path .. "|HR"] = dHR
            self.data[path .. "|?"]  = dU

            -- Per-function tick stats: how many times has this function been
            -- called within the current frame tick? Tracks the worst tick.
            local ts = { lastTick = -1, calls = 0, maxPerTick = 0 }
            self.tickStats[path] = ts

            local orig = original
            local tref = tickRef  -- upvalue cache

            container[key] = function(selfArg, a1, ...)
                -- Tick spike accounting (cheap: 1 table read + 2 compares)
                local cur = tref[1]
                if ts.lastTick ~= cur then
                    ts.lastTick = cur
                    ts.calls = 0
                end
                ts.calls = ts.calls + 1
                if ts.calls > ts.maxPerTick then
                    ts.maxPerTick = ts.calls
                end

                -- Push a call-stack frame. Deliberately OUTSIDE the timed
                -- window below: this bookkeeping is instrumentation, not the
                -- function's cost, and charging it here would defeat the
                -- correction it exists to enable.
                local d = callDepth + 1
                callDepth = d
                childMs[d] = 0
                childN[d] = 0

                -- Time + memory delta around the call.
                -- collectgarbage("count") returns kilobytes; deltas are exact
                -- between calls, but a GC cycle running mid-call shows as
                -- negative — we clamp to 0 to avoid skew.
                local m0 = collectgarbage("count")
                local t0 = debugprofilestop()
                local r1, r2, r3, r4, r5 = orig(selfArg, a1, ...)
                local elapsed = debugprofilestop() - t0
                local mDelta = collectgarbage("count") - m0
                if mDelta < 0 then mDelta = 0 end

                -- Pop: hand our inclusive time and call count up to whoever
                -- called us, so THEIR self time excludes us.
                local ct, cn = childMs[d], childN[d]
                callDepth = d - 1
                if d > 1 then
                    childMs[d - 1] = childMs[d - 1] + elapsed
                    childN[d - 1] = childN[d - 1] + cn + 1
                end
                local selfDelta = elapsed - ct
                if selfDelta < 0 then selfDelta = 0 end

                -- Classify: 2-3 field lookups on the first argument
                local bucket
                if typeCheck(a1) == "table" and a1.unit then
                    if a1.isPinnedFrame then
                        bucket = a1.isRaidFrame and dHR or dHP
                    else
                        bucket = a1.isRaidFrame and dR or dP
                    end
                else
                    bucket = dU
                end
                bucket.calls = bucket.calls + 1
                bucket.total = bucket.total + elapsed
                bucket.selfMs = bucket.selfMs + selfDelta
                bucket.descN = bucket.descN + cn
                bucket.mem = bucket.mem + mDelta
                if elapsed > bucket.max then bucket.max = elapsed end

                return r1, r2, r3, r4, r5
            end

            wrapped = wrapped + 1
        end
    end

    -- ----------------------------------------------------------
    -- Wrap event dispatchers. Each wrapped dispatcher records into
    -- self.eventData[eventName], indexed by the event name (the second
    -- argument the dispatcher receives). One dispatcher feeds many
    -- event names, so the bucket is created lazily on first occurrence.
    -- ----------------------------------------------------------
    local eventData = self.eventData
    local eventsWrapped = 0
    for _, dispatcher in ipairs(PROFILED_EVENT_DISPATCHERS) do
        local container = dispatcher.container
        local key = dispatcher.key
        local original = container[key]
        if type(original) == "function" then
            self.eventOriginals[key] = { container = container, key = key, original = original }
            local orig = original
            local source = dispatcher.source

            container[key] = function(selfArg, event, ...)
                -- Dispatchers sit at the root of nearly every call chain DF
                -- runs, so their self time — the dispatch and routing work,
                -- with the profiled methods they drive taken back out — is
                -- the number that says whether routing itself is expensive.
                local d = callDepth + 1
                callDepth = d
                childMs[d] = 0
                childN[d] = 0

                local m0 = collectgarbage("count")
                local t0 = debugprofilestop()
                local r1, r2, r3, r4, r5 = orig(selfArg, event, ...)
                local elapsed = debugprofilestop() - t0
                local mDelta = collectgarbage("count") - m0
                if mDelta < 0 then mDelta = 0 end

                local ct, cn = childMs[d], childN[d]
                callDepth = d - 1
                if d > 1 then
                    childMs[d - 1] = childMs[d - 1] + elapsed
                    childN[d - 1] = childN[d - 1] + cn + 1
                end
                local selfDelta = elapsed - ct
                if selfDelta < 0 then selfDelta = 0 end

                local bucket = eventData[event]
                if not bucket then
                    bucket = { calls = 0, total = 0, selfMs = 0, descN = 0,
                               max = 0, mem = 0, source = source }
                    eventData[event] = bucket
                end
                bucket.calls = bucket.calls + 1
                bucket.total = bucket.total + elapsed
                bucket.selfMs = bucket.selfMs + selfDelta
                bucket.descN = bucket.descN + cn
                bucket.mem = bucket.mem + mDelta
                if elapsed > bucket.max then bucket.max = elapsed end

                return r1, r2, r3, r4, r5
            end
            eventsWrapped = eventsWrapped + 1
        end
    end

    -- ----------------------------------------------------------
    -- Wrap all currently-known DF OnUpdate handlers. The SetScript
    -- hook has been recording these since addon load, so this catches
    -- every handler installed before the profiler started. Handlers
    -- added AFTER this point are wrapped on the spot by the same hook.
    --
    -- Defense in depth: re-run IsDFFrame on each registry entry here.
    -- The filter was added partway through the profiler's life, so the
    -- registry may contain stale non-DF frames recorded before the
    -- filter existed. Scrub them out instead of wrapping them, which
    -- would cause taint errors in Blizzard's secure frame updates.
    -- ----------------------------------------------------------
    local updatesWrapped = 0
    local toRemove
    for frame, handler in pairs(onUpdateRegistry) do
        if frame == tickFrame or frame == profilerFrame then
            -- Don't profile our own machinery. tickFrame drives the spike counter;
            -- profilerFrame is this window's own half-second refresh, and it is named
            -- "DFProfilerFrame" so IsDFFrame matches it like any other DF frame. Left
            -- in, the profiler's own UI showed up in its own OnUpdate table — and it
            -- got busier the longer you watched, because the table it renders grows.
        elseif not IsDFFrame(frame) then
            -- Stale non-DF entry (recorded pre-filter). Drop it.
            toRemove = toRemove or {}
            toRemove[#toRemove + 1] = frame
        else
            WrapFrameOnUpdate(frame, handler)
            updatesWrapped = updatesWrapped + 1
        end
    end
    if toRemove then
        for i = 1, #toRemove do
            onUpdateRegistry[toRemove[i]] = nil
        end
    end

    -- Start the per-tick OnUpdate that drives spike detection.
    tickFrame:Show()

    DF:Say(format("Recording — %d/%d functions, %d events, %d OnUpdate handlers instrumented (wrapper overhead %sus/call, subtracted)",
        wrapped, #PROFILED_FUNCTIONS, eventsWrapped, updatesWrapped, FormatUs(self.overheadMs)))
    -- Naming them matters more than counting them: "91/94" tells you something
    -- broke, the list tells you WHAT. A target goes missing when the function is
    -- renamed or deleted and this table is not updated with it.
    if #missing > 0 then
        DF:Say("Profiler targets that did NOT resolve (not measured)", tostring(#missing), "BAD")
        for _, path in ipairs(missing) do
            print("    " .. DF.OUT.BAD .. path .. "|r")
        end
    end
end

function Profiler:Stop()
    if not self.active then return end
    self.stopTime = debugprofilestop()
    self.active = false
    self.containerDelta = self:_ContainerStatsDelta()

    -- Restore originals on their actual container tables (supports dotted paths)
    for _, entry in pairs(self.originals) do
        entry.container[entry.key] = entry.original
    end
    for _, entry in pairs(self.eventOriginals) do
        entry.container[entry.key] = entry.original
    end

    -- Restore OnUpdate handlers. The installingOnUpdate guard suppresses
    -- the SetScript hook so it doesn't immediately re-wrap them.
    for frame, entry in pairs(onUpdateWrapped) do
        installingOnUpdate = true
        frame:SetScript("OnUpdate", entry.original)
        installingOnUpdate = false
    end
    wipe(onUpdateWrapped)

    -- Stop the per-tick OnUpdate so profiler has zero idle cost when stopped.
    -- That also stops the per-frame callDepth reset, so clear it here — the
    -- next Start would otherwise inherit whatever an error left behind.
    tickFrame:Hide()
    callDepth = 0

    DF:Say("Profiler stopped", FormatElapsed(self:GetElapsedSeconds()), "NEUTRAL")
end

function Profiler:Reset()
    for _, d in pairs(self.data) do
        d.calls = 0
        d.total = 0
        d.selfMs = 0
        d.descN = 0
        d.max = 0
        d.mem = 0
    end
    for _, ts in pairs(self.tickStats) do
        ts.lastTick = -1
        ts.calls = 0
        ts.maxPerTick = 0
    end
    -- Event + update buckets are created lazily so just wipe them.
    wipe(self.eventData)
    for _, d in pairs(self.updateData) do
        d.calls = 0
        d.total = 0
        d.selfMs = 0
        d.descN = 0
        d.max = 0
        d.mem = 0
    end
    callDepth = 0
    if self.active then
        self.startTime = debugprofilestop()
        self:_SnapshotContainerStats()
        self.containerDelta = nil
    end
end

-- ============================================================
-- CONTAINER LIFECYCLE COUNTERS
-- DF.AuraContainer.stats counts builds / teardowns / combat-deferred
-- rebuilds for the whole session. The profiler snapshots it on Start and
-- reports the delta: on 12.1 the per-update aura cost lives game-side, so
-- the number that matters is how often we RECREATE containers. Nonzero
-- builds during steady-state combat = a structural-signature bug
-- (rebuild storm), not normal operation.
-- ============================================================

function Profiler:_SnapshotContainerStats()
    local s = DF.AuraContainer and DF.AuraContainer.stats
    if s then
        self.containerStats0 = { builds = s.builds, teardowns = s.teardowns, defers = s.defers }
    else
        self.containerStats0 = nil
    end
end

function Profiler:_ContainerStatsDelta()
    local s = DF.AuraContainer and DF.AuraContainer.stats
    local s0 = self.containerStats0
    if not (s and s0) then return nil end
    return {
        builds    = s.builds - s0.builds,
        teardowns = s.teardowns - s0.teardowns,
        defers    = s.defers - s0.defers,
    }
end

-- Delta for the current window: live while recording, frozen at Stop.
function Profiler:GetContainerDelta()
    if self.active then return self:_ContainerStatsDelta() end
    return self.containerDelta
end

function Profiler:Toggle()
    if self.active then self:Stop() else self:Start() end
end

function Profiler:GetElapsedSeconds()
    if self.startTime == 0 then return 0 end
    local endTime = self.active and debugprofilestop() or self.stopTime
    return (endTime - self.startTime) / 1000
end

local function GetActiveSource(self)
    if self.viewMode == "events" then return self.eventData end
    if self.viewMode == "updates" then return self.updateData end
    return self.data
end

function Profiler:GetTotalCalls()
    local total = 0
    for _, d in pairs(GetActiveSource(self)) do total = total + d.calls end
    return total
end

-- ============================================================
-- WHICH TOTAL IS A LEGITIMATE SUM
-- ----------------------------------------------------------
-- ☠ Functions view: these rows NEST inside each other by design, so adding
-- their inclusive times counts the same microsecond once per level. It is not
-- a total of anything. Self time is the only honest sum here, and it is what
-- the % column is a share of.
--
-- Events / OnUpdate views: those rows do not nest — one event dispatch never
-- runs inside another, and the C layer calls OnUpdate handlers one after the
-- other rather than within each other. Inclusive is both a valid sum and the
-- more useful reading there ("what did this event cost me, all in"), so those
-- two views keep it.
local function ViewUsesSelf(mode)
    return mode == "functions"
end

-- ⚠ Deliberately delegates rather than summing the buckets itself. A second
-- aggregation is a second chance to disagree with the table the user is reading,
-- and the two DID disagree. The extra sort costs nothing worth counting: this is a
-- debug window refreshing twice a second, and UpdateUI calls GetSortedResults anyway.
function Profiler:GetGrandTotalMs()
    local _, grand = self:GetSortedResults()
    return grand or 0
end

-- Display name suffixes for frame types
local TYPE_LABELS = {
    ["|P"]  = "  [Party]",
    ["|R"]  = "  [Raid]",
    ["|HP"] = "  [HL-P]",
    ["|HR"] = "  [HL-R]",
    ["|?"]  = "",  -- no suffix for "other" (functions that don't take a frame)
}

function Profiler:GetSortedResults()
    if self.viewMode == "events" then
        return self:GetSortedEventResults()
    end
    if self.viewMode == "updates" then
        return self:GetSortedUpdateResults()
    end

    local results = {}
    local grandSelf = 0
    local tickStats = self.tickStats
    local oh = self.overheadMs

    -- Max is a single-call inclusive figure, so exactly one wrapper's worth of
    -- overhead is in it. Children nested under that one call carry theirs too
    -- and cannot be separated out — this corrects what is knowable.
    local function CorrectedMax(m)
        local v = m - oh
        return v > 0 and v or 0
    end

    if self.splitByFrame then
        -- Split mode: one row per function+type combination (only those with calls)
        for key, d in pairs(self.data) do
            if d.calls > 0 then
                local total, selfMs = Corrected(d.total, d.selfMs, d.calls, d.descN)
                grandSelf = grandSelf + selfMs
                -- Parse "funcName|type" into base name + suffix
                local baseName, suffix = key:match("^(.+)(|.+)$")
                if not baseName then
                    baseName = key
                    suffix = ""
                end
                local displayName = baseName .. (TYPE_LABELS[suffix] or suffix)
                local ts = tickStats[baseName]
                results[#results + 1] = {
                    name = displayName,
                    calls = d.calls,
                    total = total,
                    selfMs = selfMs,
                    avg = total / d.calls,
                    max = CorrectedMax(d.max),
                    -- Memory: bytes per call (KB delta * 1024 / calls)
                    mem = d.calls > 0 and (d.mem * 1024 / d.calls) or 0,
                    -- Peak/tick is per-function, not per-bucket; show the same
                    -- value on every split row for that function.
                    peak = ts and ts.maxPerTick or 0,
                }
            end
        end
    else
        -- Aggregate mode: combine all frame types into one row per function.
        -- ⚠ Sum the RAW fields and correct once at the end. Correcting each
        -- bucket first and then adding would clamp each partial at zero
        -- independently, so a function that is cheap in party and expensive in
        -- raid would lose the party rows' negative headroom and read high.
        local aggregated = {}
        local aggOrder = {}  -- preserve insertion order for deterministic iteration
        for key, d in pairs(self.data) do
            if d.calls > 0 then
                local baseName = key:match("^(.+)|") or key
                if not aggregated[baseName] then
                    aggregated[baseName] = { calls = 0, total = 0, selfMs = 0, descN = 0, max = 0, mem = 0 }
                    aggOrder[#aggOrder + 1] = baseName
                end
                local agg = aggregated[baseName]
                agg.calls = agg.calls + d.calls
                agg.total = agg.total + d.total
                agg.selfMs = agg.selfMs + d.selfMs
                agg.descN = agg.descN + d.descN
                agg.mem = agg.mem + d.mem
                if d.max > agg.max then agg.max = d.max end
            end
        end

        for _, baseName in ipairs(aggOrder) do
            local agg = aggregated[baseName]
            local total, selfMs = Corrected(agg.total, agg.selfMs, agg.calls, agg.descN)
            grandSelf = grandSelf + selfMs
            local ts = tickStats[baseName]
            results[#results + 1] = {
                name = baseName,
                calls = agg.calls,
                total = total,
                selfMs = selfMs,
                avg = total / agg.calls,
                max = CorrectedMax(agg.max),
                mem = agg.calls > 0 and (agg.mem * 1024 / agg.calls) or 0,
                peak = ts and ts.maxPerTick or 0,
            }
        end
    end

    -- Share of SELF time, not of the inclusive sum — see the ViewUsesSelf note.
    -- These add up to 100%; the old inclusive shares did not add up to anything.
    for _, r in ipairs(results) do
        r.pct = grandSelf > 0 and (r.selfMs / grandSelf * 100) or 0
    end
    local grandTotal = grandSelf

    local col = self.sortColumn
    local desc = self.sortDesc
    sort(results, function(a, b)
        if col == "name" then
            if desc then return a.name > b.name else return a.name < b.name end
        end
        if desc then return a[col] > b[col] else return a[col] < b[col] end
    end)

    return results, grandTotal
end

-- Build sorted rows from OnUpdate handler data. Same shape as the
-- function/event variants. Frame label is shortened to avoid blowing
-- out the name column when GetDebugName returns a long parent chain.
function Profiler:GetSortedUpdateResults()
    local results = {}
    local grandTotal = 0

    local oh = self.overheadMs

    for label, d in pairs(self.updateData) do
        if d.calls > 0 then
            local total, selfMs = Corrected(d.total, d.selfMs, d.calls, d.descN)
            grandTotal = grandTotal + total
            -- Trim very long parent-chain labels: keep the last segment.
            local short = label
            if #label > 36 then
                local tail = label:match("([^%.]+)$")
                short = tail and ("…" .. tail) or label:sub(-36)
            end
            local mx = d.max - oh
            results[#results + 1] = {
                name = short,
                calls = d.calls,
                total = total,
                selfMs = selfMs,
                avg = total / d.calls,
                max = mx > 0 and mx or 0,
                mem = d.calls > 0 and (d.mem * 1024 / d.calls) or 0,
                peak = 0,
            }
        end
    end

    for _, r in ipairs(results) do
        r.pct = grandTotal > 0 and (r.total / grandTotal * 100) or 0
    end

    local col = self.sortColumn
    local desc = self.sortDesc
    sort(results, function(a, b)
        if col == "name" then
            if desc then return a.name > b.name else return a.name < b.name end
        end
        if desc then return a[col] > b[col] else return a[col] < b[col] end
    end)

    return results, grandTotal
end

-- Build sorted rows from event dispatcher data. The shape matches the
-- function results so the existing UI code can render either without a
-- branch, except that the "peak" column is unused (always 0) for events
-- and the "name" carries the event name plus a small source tag.
function Profiler:GetSortedEventResults()
    local results = {}
    local grandTotal = 0

    local oh = self.overheadMs

    for eventName, d in pairs(self.eventData) do
        if d.calls > 0 then
            local total, selfMs = Corrected(d.total, d.selfMs, d.calls, d.descN)
            grandTotal = grandTotal + total
            local mx = d.max - oh
            results[#results + 1] = {
                name = eventName .. (d.source and ("  [" .. d.source .. "]") or ""),
                calls = d.calls,
                total = total,
                -- Self here = dispatch and routing only, with the profiled DF
                -- methods this event drove subtracted back out. A big Total
                -- next to a tiny Self means the event is expensive because of
                -- what it triggers, not because routing it costs anything.
                selfMs = selfMs,
                avg = total / d.calls,
                max = mx > 0 and mx or 0,
                mem = d.calls > 0 and (d.mem * 1024 / d.calls) or 0,
                peak = 0,
            }
        end
    end

    for _, r in ipairs(results) do
        r.pct = grandTotal > 0 and (r.total / grandTotal * 100) or 0
    end

    local col = self.sortColumn
    local desc = self.sortDesc
    sort(results, function(a, b)
        if col == "name" then
            if desc then return a.name > b.name else return a.name < b.name end
        end
        if desc then return a[col] > b[col] else return a[col] < b[col] end
    end)

    return results, grandTotal
end

-- ============================================================
-- QUICK PROFILE (timed auto-run, prints to chat)
-- ============================================================

function Profiler:QuickProfile(duration)
    duration = duration or 10
    if self.active then self:Stop() end

    self:Start()
    DF:Say("Profiler auto-stopping", duration .. "s", "NEUTRAL")

    C_Timer.After(duration, function()
        if self.active then
            self:Stop()
            self:PrintResults()
            if profilerFrame and profilerFrame:IsShown() then
                UpdateUI()
            end
        end
    end)
end

-- ============================================================
-- PRINT TO CHAT
-- ============================================================

function Profiler:PrintResults()
    local results, grandTotal = self:GetSortedResults()
    local elapsed = self:GetElapsedSeconds()
    local totalCalls = self:GetTotalCalls()

    if #results == 0 then
        DF:Say("No data collected.")
        return
    end

    print(" ")
    -- Name the denominator. In the functions view it is the sum of SELF times
    -- (the only sum that doesn't count nested calls twice); in the other two,
    -- where rows don't nest, it is the inclusive sum.
    DF:Say(format("[%s] %s | %s calls | %sms %s CPU",
        self.viewMode, FormatElapsed(elapsed), CommaNumber(totalCalls), FormatMs(grandTotal),
        ViewUsesSelf(self.viewMode) and "self" or "inclusive"))
    local cd = self:GetContainerDelta()
    if cd then
        -- Builds during steady-state combat = rebuild storm; see counter block above.
        local warn = (cd.builds > 0) and "|cffffff88" or "|cff88ff88"
        print(format("  %sAura containers: %d built, %d torn down, %d rebuilds deferred to combat end|r",
            warn, cd.builds, cd.teardowns, cd.defers))
    end
    print("  " .. DF.OUT.NEUTRAL .. ("—"):rep(14) .. "|r")

    for i, r in ipairs(results) do
        local color
        if r.pct >= 25 then color = "|cffff6666"
        elseif r.pct >= 10 then color = "|cffffff88"
        else color = "|cff88ff88" end

        print(format("  %s%2d. %-36s|r  %s calls  %sms  %sms self  %sus avg  %sus max  pk %s  %sB  %s%5.1f%%|r",
            color, i, r.name,
            CommaNumber(r.calls),
            FormatMs(r.total),
            FormatMs(r.selfMs or 0),
            FormatUs(r.avg),
            FormatUs(r.max),
            FormatPeak(r.peak),
            FormatBytes(r.mem),
            color, r.pct
        ))
    end

    print("  " .. DF.OUT.NEUTRAL .. ("—"):rep(14) .. "|r")
    print(" ")
end

-- ============================================================
-- SUMMARY (top-N across all three categories)
-- ============================================================

-- Helper: temporarily switch viewMode, run GetSortedResults, restore.
-- Used by PrintSummary so it can collect results from each category
-- without permanently flipping the user's UI view.
local function TopN(self, mode, n)
    local prev = self.viewMode
    self.viewMode = mode
    local results, grand = self:GetSortedResults()
    self.viewMode = prev
    local out = {}
    for i = 1, math.min(n, #results) do
        out[i] = results[i]
    end
    return out, grand
end

function Profiler:PrintSummary()
    local elapsed = self:GetElapsedSeconds()
    if elapsed <= 0 then
        DF:Say("No data collected.")
        return
    end

    -- Aggregate totals across all three sources independently. Note
    -- these will overlap (events drive functions which drive OnUpdate
    -- ticks) — they're shown as separate lenses, not sums.
    local _,  funcGrand = TopN(self, "functions", 0)
    local _,  evtGrand  = TopN(self, "events", 0)
    local _,  updGrand  = TopN(self, "updates", 0)

    print(" ")
    print(format("|cff00ff00DF Profiler Summary:|r %s elapsed", FormatElapsed(elapsed)))
    print(format("  Functions: %sms SELF CPU across wrapped DF methods (nested calls counted once)", FormatMs(funcGrand)))
    print(format("  Events:    %sms inclusive CPU across event handlers", FormatMs(evtGrand)))
    print(format("  OnUpdate:  %sms inclusive CPU across every-frame handlers", FormatMs(updGrand)))
    print("  " .. DF.OUT.NEUTRAL .. ("—"):rep(14) .. "|r")

    local function dump(label, mode)
        local rows = TopN(self, mode, 5)
        if #rows == 0 then
            print(format("  |cffaaaaaaTop 5 %s:|r (none)", label))
            return
        end
        print(format("  |cffffd700Top 5 %s:|r", label))
        for i, r in ipairs(rows) do
            print(format("    %d. %-34s  %s calls  %sms  %sms self  %sus avg  %s%%",
                i, r.name,
                CommaNumber(r.calls),
                FormatMs(r.total),
                FormatMs(r.selfMs or 0),
                FormatUs(r.avg),
                format("%.1f", r.pct)))
        end
    end
    dump("Functions (by total ms)", "functions")
    dump("Events (by total ms)",    "events")
    dump("OnUpdate (by total ms)",  "updates")

    print("  " .. DF.OUT.NEUTRAL .. ("—"):rep(14) .. "|r")
    print(" ")
end

-- ============================================================
-- UI
-- ============================================================

local ROW_HEIGHT = 18
local MAX_ROWS = 30
local FRAME_WIDTH = 786   -- +66 over the pre-Self-column width
local CONTENT_LEFT = 10
local CONTENT_RIGHT = -10
local HEADER_Y = -66
local DATA_START_Y = -86

-- Column layout
local COLUMNS = {
    { key = "name",  label = "Function",  width = 210, align = "LEFT" },
    { key = "calls", label = "Calls",     width = 54,  align = "RIGHT" },
    { key = "total", label = "Total ms",  width = 60,  align = "RIGHT" },
    -- Self = Total minus the time spent inside OTHER profiled functions this
    -- one called. Sort by this to find where the work actually happens; sort
    -- by Total to find which entry point owns a whole subtree.
    { key = "selfMs", label = "Self ms",  width = 62,  align = "RIGHT" },
    { key = "avg",   label = "Avg us",    width = 52,  align = "RIGHT" },
    { key = "max",   label = "Max us",    width = 52,  align = "RIGHT" },
    { key = "peak",  label = "Peak/tk",   width = 52,  align = "RIGHT" },
    { key = "mem",   label = "Bytes",     width = 56,  align = "RIGHT" },
    { key = "pct",   label = "%",         width = 46,  align = "RIGHT" },
}

local CONTENT_WIDTH = 0
for _, col in ipairs(COLUMNS) do
    CONTENT_WIDTH = CONTENT_WIDTH + col.width + 4
end

local function UpdateColumnHeaders()
    for _, col in ipairs(COLUMNS) do
        local label = col.label
        if Profiler.sortColumn == col.key then
            label = label .. (Profiler.sortDesc and " v" or " ^")
        end
        if headerTexts[col.key] then
            headerTexts[col.key]:SetText(label)
        end
    end
end

local function CreateRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("LEFT", parent, "LEFT", CONTENT_LEFT, 0)
    row:SetPoint("RIGHT", parent, "RIGHT", CONTENT_RIGHT, 0)

    -- Alternating background
    row.bg = row:CreateTexture(nil, "BACKGROUND", nil, 0)
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(index % 2 == 0 and 0.13 or 0.08, index % 2 == 0 and 0.13 or 0.08, index % 2 == 0 and 0.13 or 0.08, 1)

    -- Percentage bar (visual indicator behind text)
    row.pctBar = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.pctBar:SetPoint("LEFT")
    row.pctBar:SetHeight(ROW_HEIGHT)
    row.pctBar:SetWidth(1)
    row.pctBar:Hide()

    -- Column font strings
    row.cols = {}
    local xOffset = 2
    for _, col in ipairs(COLUMNS) do
        local fs = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        fs:SetJustifyH(col.align)
        fs:SetPoint("LEFT", row, "LEFT", xOffset, 0)
        fs:SetWidth(col.width)
        row.cols[col.key] = fs
        xOffset = xOffset + col.width + 4
    end

    row:Hide()
    return row
end

-- Assign to the forward-declared upvalue so the combat handler can call it
UpdateUI = function()
    if not profilerFrame or not profilerFrame:IsShown() then return end

    local elapsed = Profiler:GetElapsedSeconds()
    local totalCalls = Profiler:GetTotalCalls()
    local grandTotal = Profiler:GetGrandTotalMs()

    -- Status line
    if Profiler.active then
        profilerFrame.statusText:SetText(format(
            "|cff00ff00Recording|r  %s  |  %s calls  |  %sms CPU",
            FormatElapsed(elapsed), CommaNumber(totalCalls), FormatMs(grandTotal)
        ))
        profilerFrame.toggleBtn:SetText("Stop")
    else
        if totalCalls > 0 then
            local combatTag = Profiler.combatAuto and "  |  |cff00ff00Combat Armed|r" or ""
            profilerFrame.statusText:SetText(format(
                "|cffff4444Stopped|r  %s  |  %s calls  |  %sms CPU%s",
                FormatElapsed(elapsed), CommaNumber(totalCalls), FormatMs(grandTotal), combatTag
            ))
        else
            local combatTag = Profiler.combatAuto and "|cff00ff00Combat Armed|r  Waiting for combat..." or "|cff888888Ready|r  Press Start to begin profiling"
            profilerFrame.statusText:SetText(combatTag)
        end
        profilerFrame.toggleBtn:SetText("Start")
    end

    -- Data rows
    local results = Profiler:GetSortedResults()

    for i = 1, MAX_ROWS do
        local row = dataRows[i]
        if not row then break end

        local r = results[i]
        if r then
            -- Color based on cost share
            local cr, cg, cb
            local barR, barG, barB
            if r.pct >= 25 then
                cr, cg, cb = 1, 0.5, 0.5
                barR, barG, barB = 0.5, 0.15, 0.15
            elseif r.pct >= 10 then
                cr, cg, cb = 1, 1, 0.6
                barR, barG, barB = 0.4, 0.4, 0.1
            else
                cr, cg, cb = 0.7, 0.9, 0.7
                barR, barG, barB = 0.15, 0.35, 0.15
            end

            -- Percentage bar width
            local barWidth = max(1, (CONTENT_WIDTH - 4) * (r.pct / 100))
            row.pctBar:SetWidth(barWidth)
            row.pctBar:SetColorTexture(barR, barG, barB, 0.35)
            row.pctBar:Show()

            row.cols.name:SetText(r.name)
            row.cols.name:SetTextColor(cr, cg, cb)

            row.cols.calls:SetText(CommaNumber(r.calls))
            row.cols.calls:SetTextColor(0.8, 0.8, 0.8)

            row.cols.total:SetText(FormatMs(r.total))
            row.cols.total:SetTextColor(0.8, 0.8, 0.8)

            -- Self is the ranked figure, so it reads brighter than Total.
            row.cols.selfMs:SetText(FormatMs(r.selfMs or 0))
            row.cols.selfMs:SetTextColor(0.95, 0.95, 0.8)

            row.cols.avg:SetText(FormatUs(r.avg))
            row.cols.avg:SetTextColor(0.7, 0.7, 0.7)

            row.cols.max:SetText(FormatUs(r.max))
            row.cols.max:SetTextColor(0.7, 0.7, 0.7)

            row.cols.peak:SetText(FormatPeak(r.peak))
            -- Tint Peak/tick yellow when it's high (>=20 calls in one frame)
            -- — that's the cascade signal we're hunting.
            if r.peak >= 20 then
                row.cols.peak:SetTextColor(1, 0.85, 0.4)
            else
                row.cols.peak:SetTextColor(0.7, 0.7, 0.7)
            end

            row.cols.mem:SetText(FormatBytes(r.mem))
            -- Tint Mem yellow when bytes/call >= 256, red when >= 1024
            if r.mem >= 1024 then
                row.cols.mem:SetTextColor(1, 0.5, 0.5)
            elseif r.mem >= 256 then
                row.cols.mem:SetTextColor(1, 0.85, 0.4)
            else
                row.cols.mem:SetTextColor(0.7, 0.7, 0.7)
            end

            row.cols.pct:SetText(format("%.1f%%", r.pct))
            row.cols.pct:SetTextColor(cr, cg, cb)

            row:Show()
        else
            row:Hide()
        end
    end

    -- Keep combat button text in sync
    if profilerFrame.combatBtn then
        if Profiler.combatAuto then
            profilerFrame.combatBtn:SetText("|cff00ff00Combat|r")
        else
            profilerFrame.combatBtn:SetText("Combat")
        end
    end

    -- Keep split button text in sync
    if profilerFrame.splitBtn then
        if Profiler.splitByFrame then
            profilerFrame.splitBtn:SetText("|cff00ff00Split|r")
        else
            profilerFrame.splitBtn:SetText("Split")
        end
    end

    -- Keep view button text in sync
    if profilerFrame.viewBtn then
        if Profiler.viewMode == "events" then
            profilerFrame.viewBtn:SetText("|cff00ff00Events|r")
        elseif Profiler.viewMode == "updates" then
            profilerFrame.viewBtn:SetText("|cff00ff00OnUpdate|r")
        else
            profilerFrame.viewBtn:SetText("Functions")
        end
    end
end

function Profiler:CreateUI()
    if profilerFrame then
        profilerFrame:Show()
        return
    end

    -- Main frame
    local f = CreateFrame("Frame", "DFProfilerFrame", UIParent, "BackdropTemplate")
    -- Bottom slack has to clear TWO stacked things, not one:
    --   6  banner offset from the frame bottom
    --  34  the banner's minimum height
    --   6  gap
    --  24  the column legend that sits above it (TWO lines since Self landed)
    --  10  breathing room before the last data row
    -- The old value was 30, which did not even clear the 28px strip that used to
    -- live there — a full 30-row table clipped its last row behind it, and the
    -- legend was underneath the strip entirely.
    f:SetSize(FRAME_WIDTH, DATA_START_Y * -1 + MAX_ROWS * ROW_HEIGHT + 80)
    f:SetPoint("CENTER", 0, 50)
    -- Panel chrome, same as every other DF window. Was a bespoke plate from three
    -- hand-mixed literals, which is the other half of why this window read as
    -- foreign next to the settings frame.
    DF.GUI:CreatePanelBackdrop(f)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    profilerFrame = f

    -- Title. The "DF" used to be hardcoded bright green, which matched nothing
    -- else in the addon; the theme accent is what every section header uses and
    -- it follows the party/raid pole like the rest of the GUI.
    local title = f:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("Profiler")
    do
        local tc = DF.GUI.GetThemeColor and DF.GUI.GetThemeColor()
        if tc then title:SetTextColor(tc.r, tc.g, tc.b) end
    end

    -- Close button. Was Blizzard's raw UI-Panel-MinimizeButton textures, which is
    -- why this window's X had chrome no other DF surface has.
    local closeBtn = DF.GUI:CreateCloseButton(f, {
        onClick = function() f:Hide() end,
        tooltip = "Close",
    })
    closeBtn:SetPoint("TOPRIGHT", -6, -6)

    -- Status line
    f.statusText = f:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    f.statusText:SetPoint("TOPLEFT", 12, -32)
    f.statusText:SetJustifyH("LEFT")
    f.statusText:SetText("|cff888888Ready|r  Press Start to begin profiling")

    -- Buttons
    local btnY = -46
    local btnH = 20
    local btnW = 68

    f.toggleBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    DF.GUI:StyleButton(f.toggleBtn, { width = btnW, height = btnH, text = "Start" })
    f.toggleBtn:SetPoint("TOPLEFT", 10, btnY)
    f.toggleBtn:SetScript("OnClick", function()
        Profiler:Toggle()
        UpdateUI()
        UpdateColumnHeaders()
    end)

    local resetBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    DF.GUI:StyleButton(resetBtn, { width = btnW, height = btnH, text = "Reset" })
    resetBtn:SetPoint("LEFT", f.toggleBtn, "RIGHT", 4, 0)
    resetBtn:SetScript("OnClick", function()
        Profiler:Reset()
        UpdateUI()
    end)

    local printBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    DF.GUI:StyleButton(printBtn, { width = 88, height = btnH, text = "Print to Chat" })
    printBtn:SetPoint("LEFT", resetBtn, "RIGHT", 4, 0)
    printBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    printBtn:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            Profiler:PrintSummary()
        else
            Profiler:PrintResults()
        end
    end)
    printBtn:SetScript("OnEnter", function(self)
        DF.GUI:ShowTooltip(self, {
            title = "Print to Chat",
            lines = {
                "Left-click: dump the current view (functions/events/onupdate)",
                "Right-click: print Top 5 across all categories (summary)",
            },
        })
    end)
    printBtn:SetScript("OnLeave", function() DF.GUI:HideTooltip() end)

    -- Custom duration input box
    local durationInput = CreateFrame("EditBox", nil, f, "BackdropTemplate")
    durationInput:SetSize(36, btnH)
    durationInput:SetPoint("LEFT", printBtn, "RIGHT", 12, 0)
    DF.GUI:CreateElementBackdrop(durationInput, {
        bgColor     = { 0.1, 0.1, 0.1, 1 },
        borderColor = { 0.4, 0.4, 0.4, 1 },
    })
    durationInput:SetFontObject(DFFontHighlightSmall)
    durationInput:SetJustifyH("CENTER")
    durationInput:SetAutoFocus(false)
    durationInput:SetNumeric(true)
    durationInput:SetMaxLetters(4)
    durationInput:SetText("30")
    -- Allow clicking away to clear focus
    durationInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    durationInput:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        local dur = tonumber(self:GetText()) or 30
        if dur < 1 then dur = 1 end
        Profiler:QuickProfile(dur)
        UpdateUI()
        UpdateColumnHeaders()
    end)

    -- "s Run" button (triggers timed profile with input value)
    local runBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    DF.GUI:StyleButton(runBtn, { width = 48, height = btnH, text = "s Run" })
    runBtn:SetPoint("LEFT", durationInput, "RIGHT", 2, 0)
    runBtn:SetScript("OnClick", function()
        durationInput:ClearFocus()
        local dur = tonumber(durationInput:GetText()) or 30
        if dur < 1 then dur = 1 end
        Profiler:QuickProfile(dur)
        UpdateUI()
        UpdateColumnHeaders()
    end)

    -- Combat Auto toggle button
    f.combatBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    -- text = "" so StyleButton creates AND registers its fontstring; the
    -- label itself is set by the Update*BtnText below, which needs it to exist.
    DF.GUI:StyleButton(f.combatBtn, { width = 78, height = btnH, text = "" })
    f.combatBtn:SetPoint("LEFT", runBtn, "RIGHT", 8, 0)
    local function UpdateCombatBtnText()
        if Profiler.combatAuto then
            f.combatBtn:SetText("|cff00ff00Combat|r")
        else
            f.combatBtn:SetText("Combat")
        end
    end
    f.combatBtn:SetScript("OnClick", function()
        Profiler:SetCombatAuto(not Profiler.combatAuto)
        UpdateCombatBtnText()
        UpdateUI()
    end)
    f.combatBtn:SetScript("OnEnter", function(self)
        DF.GUI:ShowTooltip(self, {
            title = "Combat Auto-Profile",
            lines = { Profiler.combatAuto
                and { text = "ON: Profiling starts on combat, stops + prints on combat end.",
                      color = { 0, 1, 0 } }
                or  "OFF: Click to enable automatic combat profiling." },
        })
    end)
    f.combatBtn:SetScript("OnLeave", function() DF.GUI:HideTooltip() end)
    UpdateCombatBtnText()

    -- View cycle button (Functions / Events / OnUpdate). Top-right, left of Split.
    f.viewBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    -- text = "" so StyleButton creates AND registers its fontstring; the
    -- label itself is set by the Update*BtnText below, which needs it to exist.
    DF.GUI:StyleButton(f.viewBtn, { width = 82, height = btnH, text = "" })
    f.viewBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -84, btnY)
    local VIEW_LABELS = {
        functions = "Functions",
        events    = "|cff00ff00Events|r",
        updates   = "|cff00ff00OnUpdate|r",
    }
    local VIEW_NEXT = {
        functions = "events",
        events    = "updates",
        updates   = "functions",
    }
    local function UpdateViewBtnText()
        f.viewBtn:SetText(VIEW_LABELS[Profiler.viewMode] or "Functions")
    end
    f.viewBtn:SetScript("OnClick", function()
        Profiler.viewMode = VIEW_NEXT[Profiler.viewMode] or "functions"
        UpdateViewBtnText()
        UpdateUI()
        UpdateColumnHeaders()
    end)
    f.viewBtn:SetScript("OnEnter", function(self)
        DF.GUI:ShowTooltip(self, {
            title = "View Mode",
            lines = {
                "Click to cycle: Functions → Events → OnUpdate.",
                "Functions: time per DF method",
                "Events: time per WoW event (UNIT_AURA, etc.)",
                "OnUpdate: time per OnUpdate handler (every-frame ticks)",
            },
        })
    end)
    f.viewBtn:SetScript("OnLeave", function() DF.GUI:HideTooltip() end)
    UpdateViewBtnText()

    -- Split by Frame Type toggle button
    f.splitBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    -- text = "" so StyleButton creates AND registers its fontstring; the
    -- label itself is set by the Update*BtnText below, which needs it to exist.
    DF.GUI:StyleButton(f.splitBtn, { width = 50, height = btnH, text = "" })
    f.splitBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -28, btnY)
    local function UpdateSplitBtnText()
        if Profiler.splitByFrame then
            f.splitBtn:SetText("|cff00ff00Split|r")
        else
            f.splitBtn:SetText("Split")
        end
    end
    f.splitBtn:SetScript("OnClick", function()
        Profiler.splitByFrame = not Profiler.splitByFrame
        UpdateSplitBtnText()
        UpdateUI()
    end)
    f.splitBtn:SetScript("OnEnter", function(self)
        DF.GUI:ShowTooltip(self, {
            title = "Split by Frame Type",
            lines = { Profiler.splitByFrame
                and { text = "ON: Showing per-type breakdown (Party, Raid, HL-Party, HL-Raid).",
                      color = { 0, 1, 0 } }
                or  "OFF: Click to split results by frame type." },
        })
    end)
    f.splitBtn:SetScript("OnLeave", function() DF.GUI:HideTooltip() end)
    UpdateSplitBtnText()

    -- ============================================================
    -- ONUPDATE TRACKING STRIP  (bottom of the window, above the rows)
    -- ============================================================
    -- What the toggle actually controls: a hooksecurefunc on the Frame
    -- metatable's SetScript (see the top of this file), which registers every
    -- OnUpdate handler a DF frame installs. That registry IS the OnUpdate tab —
    -- with the hook off, the tab has no data source and is simply empty.
    --
    -- ☠ It can only be installed at FILE-LOAD time: the hook has to be in place
    -- before frames install their handlers, or everything set up during login is
    -- invisible. Hence /rl, and hence the setting living in DandersFramesDB_v2
    -- (account SavedVariables) rather than a profile — it must be readable
    -- before profiles initialise.
    --
    -- ⚠ FORWARD-DECLARED. The checkbox's OnClick closure below calls this, and
    -- the closure is built BEFORE the definition. Without this line the name
    -- resolves as a global at closure-creation time, reads nil, and clicking the
    -- box back to its current state throws "attempt to call a nil value" — the
    -- same out-of-scope-local trap that left 8 dead branches in ColorPicker.
    local UpdateHookBanner

    -- The real banner system, not a lookalike. This was a hand-built frame with
    -- two hand-mixed colour literals approximating the "caution" tone; SetTone
    -- gives the exact palette plus the matching icon, and cannot drift from the
    -- banners on the settings pages.
    --
    -- CreateInfoBanner self-measures its height and calls GUI:RelayoutHost. That
    -- is a no-op here — RelayoutHost only does work for a widget inside a
    -- settingsGroup, and walks the parent chain looking for a RefreshStates host
    -- it will never find on a floating window — so the banner simply sizes
    -- itself against the two anchors below.
    local hookBanner = DF.GUI:CreateInfoBanner(f, { tone = "caution" })
    hookBanner:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 6)
    hookBanner:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 6)
    f.hookBanner = hookBanner

    local hookCheckbox = CreateFrame("CheckButton", nil, hookBanner, "BackdropTemplate")
    hookCheckbox:SetPoint("RIGHT", -6, 0)
    DF.GUI:StyleCheckButton(hookCheckbox)
    hookCheckbox:SetChecked(self.onUpdateHookEnabled)
    hookCheckbox:SetScript("OnClick", function(cb)
        if not DandersFramesDB_v2 then DandersFramesDB_v2 = {} end
        local newState = cb:GetChecked()
        DandersFramesDB_v2.profilerOnUpdateHook = newState
        if newState == self.onUpdateHookEnabled then
            -- Toggled back to what is already live — no reload needed.
            UpdateHookBanner()
        else
            hookBanner:SetTone("caution")
            hookBanner:SetText(newState
                and "OnUpdate tracking will be ON after /rl."
                or  "OnUpdate tracking will be OFF after /rl.")
        end
    end)
    hookCheckbox:SetScript("OnEnter", function(cb)
        DF.GUI:ShowTooltip(cb, {
            title = "Track OnUpdate handlers",
            lines = {
                "Hooks SetScript so the profiler can see every OnUpdate a DF frame installs. This is the data source for the OnUpdate tab — with it off, that tab is empty.",
                "Applies at load only, so a /rl is required either way.",
            },
        })
    end)
    hookCheckbox:SetScript("OnLeave", function() DF.GUI:HideTooltip() end)

    local hookLabel = hookBanner:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    hookLabel:SetPoint("RIGHT", hookCheckbox, "LEFT", -2, 0)
    hookLabel:SetText("Track OnUpdate")

    -- Keep the banner's body clear of the toggle. The factory anchors the body
    -- TOPLEFT-of-icon and RIGHT-of-banner; re-issue BOTH points rather than just
    -- the right one, so there is no question of a stale anchor surviving.
    hookBanner.body:ClearAllPoints()
    hookBanner.body:SetPoint("TOPLEFT", hookBanner.icon, "TOPRIGHT", 8, -5)
    hookBanner.body:SetPoint("RIGHT", hookLabel, "LEFT", -10, 0)

    -- ☠ The strip stays VISIBLE in both states. It used to Hide() itself once
    -- the hook was on — and the checkbox lives inside it, so the only way to
    -- turn tracking back off was the /df debug profiler hook command. A toggle
    -- you can reach in one direction only is not a toggle.
    function UpdateHookBanner()
        if self.onUpdateHookEnabled then
            hookBanner:SetTone("info")
            hookBanner:SetText("OnUpdate tracking is on.")
        else
            hookBanner:SetTone("caution")
            hookBanner:SetText("OnUpdate tracking is off — the OnUpdate tab will be empty.")
        end
        hookCheckbox:SetChecked(DandersFramesDB_v2 and DandersFramesDB_v2.profilerOnUpdateHook or false)
        hookBanner:Show()
    end
    UpdateHookBanner()

    -- Column headers
    local xOffset = CONTENT_LEFT + 2
    for _, col in ipairs(COLUMNS) do
        local hdr = CreateFrame("Button", nil, f)
        hdr:SetHeight(18)
        hdr:SetPoint("TOPLEFT", f, "TOPLEFT", xOffset, HEADER_Y)
        hdr:SetWidth(col.width)

        local text = hdr:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        text:SetAllPoints()
        text:SetJustifyH(col.align)
        text:SetTextColor(0.5, 0.75, 1.0)

        local label = col.label
        if Profiler.sortColumn == col.key then
            label = label .. (Profiler.sortDesc and " v" or " ^")
        end
        text:SetText(label)
        headerTexts[col.key] = text

        -- Click to sort
        local colKey = col.key
        hdr:SetScript("OnClick", function()
            if Profiler.sortColumn == colKey then
                Profiler.sortDesc = not Profiler.sortDesc
            else
                Profiler.sortColumn = colKey
                Profiler.sortDesc = true
            end
            UpdateColumnHeaders()
            UpdateUI()
        end)
        hdr:SetScript("OnEnter", function() text:SetTextColor(0.8, 1.0, 1.0) end)
        hdr:SetScript("OnLeave", function() text:SetTextColor(0.5, 0.75, 1.0) end)

        xOffset = xOffset + col.width + 4
    end

    -- Header divider
    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.3, 0.3, 0.3, 0.6)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", f, "TOPLEFT", CONTENT_LEFT, HEADER_Y - 18)
    divider:SetPoint("TOPRIGHT", f, "TOPRIGHT", CONTENT_RIGHT, HEADER_Y - 18)

    -- Data rows
    for i = 1, MAX_ROWS do
        local row = CreateRow(f, i)
        row:SetPoint("TOP", f, "TOP", 0, DATA_START_Y - (i - 1) * ROW_HEIGHT)
        dataRows[i] = row
    end

    -- Column legend, stacked ABOVE the hook banner.
    -- ☠ It used to be anchored to the frame's own bottom at y=8 — which is inside
    -- the banner's rect. That was survivable only while the banner HID itself
    -- whenever tracking was on; now that the banner is always visible (so the
    -- toggle is reachable in both directions) the legend sat behind it
    -- permanently, bleeding through as ghost text. Anchor to the banner instead
    -- of to the frame, so it also tracks the banner if its text ever wraps.
    local infoLabel = f:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    infoLabel:SetPoint("BOTTOMLEFT", f.hookBanner, "TOPLEFT", 2, 6)
    infoLabel:SetTextColor(0.4, 0.4, 0.4)
    infoLabel:SetJustifyH("LEFT")
    -- Two lines. The first says what the numbers ARE, which matters because
    -- Total and Self answer different questions and only one of them adds up.
    infoLabel:SetText(
        "Total = inclusive (counts nested profiled calls)  |  Self = excludes them — this is what % ranks, and % sums to 100\n" ..
        "Peak/tk = max calls in one frame  |  Bytes = avg alloc per call  |  wrapper overhead subtracted; a row cheaper than it reads 0.00, not below zero")

    -- Live refresh via OnUpdate
    f.elapsed = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + elapsed
        if self.elapsed < 0.5 then return end
        self.elapsed = 0
        UpdateUI()
    end)

    UpdateUI()
end

function Profiler:ToggleUI()
    if profilerFrame and profilerFrame:IsShown() then
        profilerFrame:Hide()
    else
        self:CreateUI()
    end
end
