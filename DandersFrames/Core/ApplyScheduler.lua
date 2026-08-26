local addonName, DF = ...

-- ============================================================
-- APPLY SCHEDULER
-- The single sink every heavy "apply the settings" sweep funnels into.
--
-- WHY: a settings widget used to run its heavy sweep synchronously, once per
-- callback. A slider drag fires its callback on every mouse tick, and one click
-- on a checkbox can chain several sweeps, so a 40-man raid paid the same full
-- pass many times inside one rendered frame. The five publics below are now
-- arm-stubs: they mark a kind dirty and return. A hidden frame's OnUpdate then
-- drains every dirty kind exactly once, at most one rendered frame later.
--
-- THE BEHAVIOUR CONTRACT: no setting changes WHAT it does -- only WHEN the work
-- runs (at most one frame later). Nothing is dropped, nothing is merged away.
-- Code that must see the apply land before its very next statement calls the
-- `_Now` form directly, or DF.Apply:Flush() after a batch. Those seams are
-- listed in the task's caller audit and are the only places that skip the sink.
--
-- ☠ NO SUPERSEDE-DROPPING. An early draft had "all" swallow the other four
-- "because UpdateAll already contains them". It does not:
--   * UpdateAll never calls ApplyHeaderSettings (UpdateAllFrames explicitly
--     refuses to, see the NOTE in Frames/Init.lua),
--   * it does not reach RefreshLiveFrames on the live-party branch,
--   * and it covers frames / raidLayout only on mode-dependent branches.
-- Dropping a kind would drop work, which is a behaviour change. So each kind
-- coalesces with ITSELF only (N requests in one frame = 1 run), and a drain
-- runs every dirty kind at most once. Worst case is five heavies per rendered
-- frame, which is still bounded -- the unbounded repeat is what this removes.
--
-- FIXED DRAIN ORDER
--   headers -> raidLayout -> frames -> visible -> all
-- chosen to preserve the two load-bearing orderings in the settings pages
-- (both in DandersFrames_Options/GUI/Pages/Options.lua, in the local
-- UpdateFrames() built for the Frames page):
--   (a) ~1697-1705: LightweightUpdateFrameSize(true) must run BEFORE
--       ApplyHeaderSettings -- it is the only path that re-anchors the health
--       bar to framePadding, and ApplyHeaderSettings then re-applies frame
--       width/height through the secure header. That pre-work is a direct
--       synchronous call at the site, outside this sink, so no drain order can
--       reorder it; the drain then keeps the rest of that sequence.
--   (b) ~1706-1718: the raid layoutSig cache is invalidated (a plain DB write
--       at the call site) BEFORE ApplyHeaderSettings, and ApplyHeaderSettings
--       must run BEFORE UpdateRaidLayout (PR #134) or ApplyRaidGroupSorting
--       bails and raidGroupRowGrowth never applies. headers before raidLayout
--       in the drain is exactly that constraint.
-- The one source order the fixed drain does invert is "UpdateAllFrames then
-- UpdateRaidLayout" (Frames/Core.lua's UI_SCALE_CHANGED handler and the Global
-- Fonts page). That is safe: the raid positioners compute from DB values, not
-- from live frame geometry -- frame sizing for raid comes from
-- ApplyHeaderSettings (UpdateRaidGroupFrameSizes / UpdateRaidFlatFrameSizes),
-- which the drain still runs first. FullProfileRefresh, which has the same
-- source order and DOES depend on it, calls the `_Now` forms instead.
--
-- COMBAT: the drain re-checks InCombatLockdown() AT FIRE TIME. Every kind is
-- combat-unsafe (they all write secure frame size / attributes), so an in-combat
-- drain runs nothing, keeps the kinds queued and replays them on
-- PLAYER_REGEN_ENABLED -- the same re-queue-don't-drop idiom RefreshFactoryRows
-- uses in Features/Auras.lua. The `_Now` bodies keep their own combat guards
-- (UpdateAll_Now sets DF.needsUpdate, UpdateRaidLayout_Now sets
-- pendingFlatLayoutRefresh / needsUpdate); belt and braces, but the scheduler's
-- regen replay is the prompt one.
--
-- HEADLESS: every WoW API here is optional. With no CreateFrame there is no
-- drain frame and no event wiring -- Request still marks kinds dirty and Flush
-- still drains, which is what Tools/mover-tests/test_apply.lua drives.
-- InCombatLockdown is resolved as a GLOBAL at call time (not cached in an
-- upvalue) so a test can swap it between calls.
--
-- LOAD ORDER: this file loads right after Core.lua, so the `_Now` bodies in
-- Frames/*.lua do not exist yet when the stubs below are defined. That is fine
-- -- both halves are only ever looked up at runtime.
-- ============================================================

local type = type

local CreateFrame = CreateFrame     -- nil in the headless test harness

-- Kind -> the real function's name on DF. The stub for each is at the bottom.
local TARGET = {
    headers    = "ApplyHeaderSettings_Now",
    raidLayout = "UpdateRaidLayout_Now",
    frames     = "UpdateAllFrames_Now",
    visible    = "RefreshAllVisibleFrames_Now",
    all        = "UpdateAll_Now",
}

-- THE DRAIN ORDER. See the block comment above before changing it.
local ORDER = { "headers", "raidLayout", "frames", "visible", "all" }

-- All five write secure frame size/attributes somewhere down their call tree,
-- so none may run in combat. Kept as a table rather than a blanket `if combat
-- then return` so a kind that later becomes combat-safe can say so here.
local COMBAT_UNSAFE = {
    headers = true, raidLayout = true, frames = true, visible = true, all = true,
}

local pending = {}      -- kind -> true while a request is outstanding
local batch = {}        -- reused snapshot buffer, so a drain allocates nothing

local DF_Apply = {}
DF.Apply = DF_Apply

-- ============================================================
-- INTERNALS
-- ============================================================

-- Resolved at CALL time on purpose (see HEADLESS above).
local function InCombat()
    if InCombatLockdown then return InCombatLockdown() and true or false end
    return false
end

local function Debug(fmt, ...)
    if DF.Debug then DF:Debug("APPLY", fmt, ...) end
end

local function DebugError(fmt, ...)
    if DF.DebugError then DF:DebugError("APPLY", fmt, ...) end
end

local function HasPending()
    for i = 1, #ORDER do
        if pending[ORDER[i]] then return true end
    end
    return false
end

local drainFrame
local regenArmed = false

local function Disarm()
    if drainFrame then drainFrame:Hide() end
end

local function ArmRegen()
    if regenArmed or not drainFrame then return end
    regenArmed = true
    drainFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    Debug("held by combat, replaying at PLAYER_REGEN_ENABLED")
end

--- Run every dirty kind once, in ORDER. Combat-held kinds stay queued.
---
--- ⚠ THE SNAPSHOT IS THE RE-ARM SEMANTICS. Dirty kinds are collected and
--- cleared BEFORE any of them runs, so a `_Now` body that calls one of the
--- public stubs (directly, or through some helper it drives) marks that kind
--- dirty for the NEXT drain rather than re-entering this one. Without it a body
--- that re-requests a kind later in ORDER would run twice in one pass, and a
--- body that re-requests its own kind could ping-pong forever.
local function DrainNow()
    Disarm()

    local combat = InCombat()
    local heldByCombat = false
    local n = 0
    for i = 1, #ORDER do
        local kind = ORDER[i]
        if pending[kind] then
            if combat and COMBAT_UNSAFE[kind] then
                heldByCombat = true
            else
                pending[kind] = nil
                n = n + 1
                batch[n] = kind
            end
        end
    end
    for i = n + 1, #batch do batch[i] = nil end

    if heldByCombat then ArmRegen() end
    if n == 0 then return end

    Debug("drain: %d kind(s)", n)
    for i = 1, n do
        local kind = batch[i]
        local fn = DF[TARGET[kind]]
        if type(fn) == "function" then
            fn(DF)
        else
            -- Only reachable if a _Now body went missing (bad TOC / renamed
            -- function). Loud, because the setting would silently never apply.
            DebugError("no %s on DF for kind '%s'", TARGET[kind], kind)
        end
    end
end

if CreateFrame then
    drainFrame = CreateFrame("Frame")
    drainFrame:Hide()
    -- Armed by Show(): a hidden frame gets no OnUpdate, so Show/Hide IS the
    -- armed flag. One tick, then it hides itself again.
    drainFrame:SetScript("OnUpdate", function(self)
        self:Hide()
        DrainNow()
    end)
    drainFrame:SetScript("OnEvent", function(self, event)
        if event ~= "PLAYER_REGEN_ENABLED" then return end
        self:UnregisterEvent("PLAYER_REGEN_ENABLED")
        regenArmed = false
        DrainNow()
    end)
end

-- ============================================================
-- PUBLIC SINK
-- ============================================================

--- Mark `kind` dirty and arm the drain. Any number of requests for the same
--- kind inside one rendered frame collapse into a single run.
function DF_Apply:Request(kind)
    if not TARGET[kind] then
        DebugError("Request: unknown kind '%s'", tostring(kind))
        return
    end
    if not pending[kind] then
        pending[kind] = true
        Debug("request: %s", kind)
    end
    if drainFrame then drainFrame:Show() end
end

--- Run everything outstanding RIGHT NOW, synchronously. The escape hatch for
--- sync seams that batch several requests and then need them all landed.
--- No-op when nothing is pending.
function DF_Apply:Flush()
    if not HasPending() then return end
    DrainNow()
end

--- Is a request for `kind` still outstanding? Read-only; used by the headless
--- tests and handy in the debug console.
function DF_Apply:IsPending(kind)
    return pending[kind] and true or false
end

--- The drain itself, exposed so the tests (and anything that needs to model a
--- rendered frame) can step it without a real OnUpdate. Prefer Flush().
function DF_Apply:Drain()
    DrainNow()
end

-- ============================================================
-- THE ARM-STUBS
-- These five names are what the ~430 call sites across the addon and the
-- options companion already use. They keep their names and their signatures;
-- only the timing moved. The real bodies live where they always did, renamed
-- with a `_Now` suffix:
--   ApplyHeaderSettings_Now      Frames/Headers.lua
--   RefreshAllVisibleFrames_Now  Frames/Headers.lua
--   UpdateRaidLayout_Now         Frames/Init.lua
--   UpdateAllFrames_Now          Frames/Init.lua
--   UpdateAll_Now                Core.lua
-- A caller that genuinely cannot wait a frame calls the `_Now` form instead.
-- ============================================================

function DF:UpdateAll()
    DF_Apply:Request("all")
end

function DF:UpdateAllFrames()
    DF_Apply:Request("frames")
end

function DF:RefreshAllVisibleFrames()
    DF_Apply:Request("visible")
end

function DF:ApplyHeaderSettings()
    DF_Apply:Request("headers")
end

function DF:UpdateRaidLayout()
    DF_Apply:Request("raidLayout")
end
