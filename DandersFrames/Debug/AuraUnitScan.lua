local addonName, DF = ...

-- ============================================================
-- TEMPORARY DIAGNOSTIC -- PASSIVE STALE-CONTAINER RECORDER
--
-- Runs by itself. No command during combat, nothing to remember mid-pull.
-- Arms on login, samples all the time (every second in combat, every two out
-- of it), and writes what it finds to TWO places:
--
--   * the DEBUG LOG (category UNITSCAN) -- one line when a problem STARTS and one
--     when it CLEARS, with how long it lasted. This is the timeline; it sits next
--     to the roster, latch and retarget lines, so a reload is the whole report.
--   * DandersFramesDebugDB.unitscan -- one row per problem per SESSION, with the
--     count and the latest detail. Read it after raid with
--
--     /run DandersFrames:DumpAuraUnitLog()          -- print what it caught
--     /run DandersFrames:DumpAuraUnitLog(true)      -- print, then clear
--
-- ☠ WHY IT WAS REWRITTEN (2026-09-24). Krathe: "the log should find the problem --
-- it's pointless if it keeps missing it." It missed for three reasons:
--   1. It sampled only IN COMBAT. A stale indicator out of combat was invisible.
--   2. Rows were merged by key with NO DATE and the detail was never refreshed, so a
--      repeat in a later session looked like the old row with a bigger count, and new
--      diagnostic fields never appeared on a key that already existed.
--   3. Every check trusted DF's OWN bookkeeping (owner.unit, _pendingOp). A container
--      can be wrong while every DF memo says it is right.
--
-- WHAT IT CHECKS -- the first two ask the ENGINE, not DF, which is the point:
--
--   ENGINE-UNIT   The container's own GetUnit() differs from the frame's unit, on a
--                 visible frame. The container parses auras for the unit it is bound
--                 to, so this frame is showing SOMEONE ELSE'S auras -- durations that
--                 never move, icons that never clear. Covers every lane: aura rows,
--                 dispel, every Aura Designer store, and the AD slot owner.
--   SHOWN-DISABLED  The container's window is shown but the container is disabled.
--                 A disabled container unregisters UNIT_AURA, so whatever it painted
--                 last stays on screen with nothing to update it.
--   STUCK-PENDING-OP / REBUILD-UPGRADE / STUCK-HIDDEN / STUCK-AD-SLOTS / WRONG-AD-SLOTS
--                 The original four hypotheses, kept: they describe the path INTO a
--                 bad state (a deferred op that never drained, a hide that never
--                 lifted), which the engine checks cannot see.
--
-- ⚠ NOT CHECKABLE, and why, so nobody spends time adding it:
--   * Whether a container is still registered for UNIT_AURA. IsEventRegistered is
--     refused on containers by the EventRegistrations forbidden aspect (proven in game,
--     see setContainerProviderDeaf in Frames/AuraContainer.lua). SHOWN-DISABLED is the
--     readable half of that question.
--   * ☠ Whether a button is SHOWING AN AURA THAT HAS GONE -- the stale-icon case itself
--     (a stale Prayer of Mending in raid, 2026-10-01: right unit, container listening,
--     icon stuck with its timer run out). Counting shown buttons against the unit's real
--     auras was proposed, and it cannot be done: Blizzard_CustomAuraButton paints
--     visibility as SetShown(secretwrap(auraData ~= nil)) and AuraContainerUtil sets the
--     icon as SetTexture(secretwrap(icon)) -- ALWAYS wrapped, out of combat too. So
--     IsShown and GetTexture on an aura button are secret, and no OnShow runs in its
--     subtree. A stale icon has no readable trace; the panic button below is the only
--     way to timestamp one.
--
-- ☠ FINDINGS ARE LOGGED AS WARN (2026-10-01). The log evicts oldest INFO first once it is
-- full, and a busy raid fills it inside an hour -- so an INFO start line was gone before
-- anyone read it. A WARN survives until there is no INFO left to evict.
-- ★ AND EACH SESSION LEAVES A HEARTBEAT in DandersFramesDebugDB.unitscanRuns (armed time,
-- samples taken, last sample, findings). "Nothing caught" is only evidence when the
-- heartbeat shows the recorder was sampling at the time; on 2026-10-01 it was not
-- possible to tell, because the "recorder armed" line had been evicted.
--
-- Hidden frames are skipped entirely: a frame nobody can see cannot show a stale
-- aura, and the previous version filled the log with frames whose unit had left.
--
-- DELETE THIS FILE and its TOC line when we are done.
-- ============================================================

local format, date = string.format, date
local MAX_ROWS = 300
local POST_COMBAT_DELAY = 5
local COMBAT_INTERVAL, IDLE_INTERVAL = 1, 2

-- One id per login/reload. Part of every row key, so sessions never merge.
local SESSION = date("%Y-%m-%d %H:%M:%S")

local LANES = {
    { field = "buffFactory",      label = "buff",      hidden = "dfBuffFactoryHidden" },
    { field = "debuffFactory",    label = "debuff",    hidden = "dfDebuffFactoryHidden" },
    { field = "defensiveFactory", label = "defensive", hidden = "dfDefFactoryHidden" },
    { field = "dispelFactory",    label = "dispel",    hidden = nil },
}

-- Every Aura Designer store that holds container-backed handles (see ad_storage_map;
-- "placed" holds SlotHandles, which are checked through the frame's slot owner instead).
local AD_STORES = { "healthbar", "background", "border", "nametext", "healthtext",
                    "fgroups", "dgroups" }

local currentEncounter

local function store()
    DandersFramesDebugDB = DandersFramesDebugDB or {}
    DandersFramesDebugDB.unitscan = DandersFramesDebugDB.unitscan or {}
    return DandersFramesDebugDB.unitscan
end

-- This session's heartbeat row: proof the recorder ran, and how much it looked.
local MAX_RUNS = 20
local run
local function heartbeat()
    if run then return run end
    DandersFramesDebugDB = DandersFramesDebugDB or {}
    DandersFramesDebugDB.unitscanRuns = DandersFramesDebugDB.unitscanRuns or {}
    local runs = DandersFramesDebugDB.unitscanRuns
    if #runs >= MAX_RUNS then table.remove(runs, 1) end
    run = { session = SESSION, armed = date("%H:%M:%S"), samples = 0, combatSamples = 0,
            findings = 0, last = nil }
    runs[#runs + 1] = run
    return run
end

-- Problems seen on the PREVIOUS sample, keyed kind|unit|lane -> { since = GetTime() }.
-- A key present last sample and absent now has CLEARED; that edge is what tells us a
-- stale indicator was "brief" and for how long.
local active = {}
local seenNow = {}

local function inCombat()
    if DF.playerInCombat ~= nil then return DF.playerInCombat and true or false end
    return InCombatLockdown() and true or false
end

-- One finding. Logs to the debug console on the START of an episode, and keeps one
-- saved row per kind/unit/lane per session with the latest detail.
local function record(kind, unit, lane, detail)
    local ep = kind .. "|" .. tostring(unit) .. "|" .. tostring(lane)
    seenNow[ep] = true
    if not active[ep] then
        active[ep] = { since = GetTime(), at = date("%H:%M:%S") }
        local hb = heartbeat()
        hb.findings = hb.findings + 1
        DF:DebugWarn("UNITSCAN", "START %s %s [%s] combat=%s enc=%s | %s", kind, tostring(unit),
            tostring(lane), tostring(inCombat()), tostring(currentEncounter or "-"), tostring(detail))
    end

    local log = store()
    local key = SESSION .. "|" .. ep
    local now = date("%H:%M:%S")
    for i = 1, #log do
        local r = log[i]
        if r.key == key then
            r.n = (r.n or 1) + 1
            r.last = now
            r.detail = detail   -- ALWAYS the latest; a frozen first detail hid the new fields
            return
        end
    end
    if #log >= MAX_ROWS then table.remove(log, 1) end
    log[#log + 1] = {
        key = key, session = SESSION, kind = kind, unit = tostring(unit), lane = tostring(lane),
        detail = detail, enc = currentEncounter or (inCombat() and "(combat)" or "(no encounter)"),
        n = 1, first = now, last = now,
    }
end

-- Episodes present last sample but not this one have ended. Logged with duration, which
-- is the number that separates "a frame late" from "stuck until something else fixed it".
local function closeEpisodes()
    local t = GetTime()
    for ep, info in pairs(active) do
        if not seenNow[ep] then
            DF:DebugWarn("UNITSCAN", "CLEAR %s after %.1fs (started %s)", ep, t - info.since, info.at)
            active[ep] = nil
        end
    end
    wipe(seenNow)
end

-- Engine truth for one container: the unit it is actually bound to, and whether it is
-- enabled. Plain Lua fields on a container we created -- readable, never secret -- but
-- pcall'd anyway because a torn-down container can be half gone.
local function engineState(c)
    if not c then return nil end
    local okU, u = pcall(c.GetUnit, c)
    local okE, en = pcall(c.IsEnabled, c)
    if okU and issecretvalue and issecretvalue(u) then okU = false end
    if okE and issecretvalue and issecretvalue(en) then okE = false end
    -- ☠ Explicit ifs, NOT `okE and en or nil`: en is FALSE exactly when the container is
    -- disabled, and the and/or idiom turns that false into nil -- which made SHOWN-DISABLED
    -- impossible to fire. Caught by the mock test before it shipped.
    local bound, enabled = nil, nil
    if okU then bound = u end
    if okE then enabled = (en == true) end
    return bound, enabled
end

local function windowShown(h)
    local f = h and h.frame
    if not f then return nil end
    local ok, shown = pcall(f.IsShown, f)
    if not ok or (issecretvalue and issecretvalue(shown)) then return nil end
    return shown and true or false
end

-- The two engine checks, for one Handle (a real per-consumer container).
local function checkHandle(h, unit, lane, frame, hiddenFlag)
    if not h or h._destroyed then return end
    local c = h.backend and h.backend.container
    if not c then return end
    local bound, enabled = engineState(c)
    local shown = windowShown(h)
    -- A row that hid itself for a deferred retarget legitimately shows the old binding
    -- until regen; it shows NOTHING meanwhile, so it cannot be stale. Skip it.
    local selfHidden = hiddenFlag and frame[hiddenFlag]
    if bound and bound ~= unit and shown ~= false and not selfHidden then
        record("ENGINE-UNIT", unit, lane, format(
            "container bound to %s, frame is %s | cfgUnit=%s pendingOp=%s shown=%s enabled=%s gen=%s",
            tostring(bound), tostring(unit), tostring(h.config and h.config.unit),
            tostring(h._pendingOp), tostring(shown), tostring(enabled), tostring(h._gen)))
    end
    if shown == true and enabled == false then
        record("SHOWN-DISABLED", unit, lane, format(
            "window shown, container disabled (not listening for UNIT_AURA) | bound=%s pendingOp=%s gen=%s",
            tostring(bound), tostring(h._pendingOp), tostring(h._gen)))
    end
end

local function sample(postCombat)
    local hb = heartbeat()
    hb.samples = hb.samples + 1
    if inCombat() then hb.combatSamples = hb.combatSamples + 1 end
    hb.last = date("%H:%M:%S")

    local function visit(frame)
        if not frame or not frame.unit then return end
        local okV, vis = pcall(frame.IsVisible, frame)
        if not okV or not vis or (issecretvalue and issecretvalue(vis)) then return end
        local unit = frame.unit

        for i = 1, #LANES do
            local lane = LANES[i]
            local h = frame[lane.field]
            if h then
                local op = h._pendingOp
                if op then
                    -- The upgrade case is worth recording whenever it appears,
                    -- because it is the one that can outlive the fight entirely.
                    if op == "rebuild" then
                        record("REBUILD-UPGRADE", unit, lane.label,
                            "pendingOp upgraded to rebuild -- can strand the container on the old unit")
                    end
                    if postCombat then
                        record("STUCK-PENDING-OP", unit, lane.label,
                            "pendingOp=" .. tostring(op) .. " still set after combat -- drain never ran")
                    end
                end
                if postCombat and lane.hidden and frame[lane.hidden] then
                    record("STUCK-HIDDEN", unit, lane.label,
                        "row hidden for a deferred retarget, still hidden after combat")
                end
                checkHandle(h, unit, lane.label, frame, lane.hidden)
            end
        end

        -- Aura Designer container stores (layout groups, frame effects, text).
        local adStore = frame.dfADFactory
        if adStore then
            for s = 1, #AD_STORES do
                local t = adStore[AD_STORES[s]]
                if t then
                    for key, entry in pairs(t) do
                        local h = entry and entry.handle
                        if h and h.backend then
                            checkHandle(h, unit, "AD " .. AD_STORES[s] .. ":" .. tostring(key), frame)
                        end
                    end
                end
            end
        end

        -- Aura Designer placed indicators: one shared slot owner per frame.
        local owner = frame.dfSlotOwner
        if owner then
            local bound, enabled = engineState(owner.container)
            if bound and bound ~= unit then
                record("ENGINE-UNIT", unit, "AD slots", format(
                    "slot owner container bound to %s, frame is %s | owner.unit=%s pending=%s enabled=%s lastSync=%s",
                    tostring(bound), tostring(unit), tostring(owner.unit), tostring(owner.pendingUnit),
                    tostring(enabled), tostring(frame.dfADLastSyncAt)))
            end
            if owner.unit ~= unit then
                if owner.pendingUnit then
                    if postCombat then
                        record("STUCK-AD-SLOTS", unit, "AD slots",
                            "owner still on " .. tostring(owner.unit) .. ", pending "
                            .. tostring(owner.pendingUnit) .. " after combat")
                    end
                else
                    -- ★ WHY was nothing pending? Record the conditions the Factory's
                    -- retarget walk needs, so the log names the gate it fell at.
                    local placed = adStore and adStore.placed
                    local nPlaced, nMine, nParked = 0, 0, 0
                    if placed then
                        for _, entry in pairs(placed) do
                            local h = entry and entry.handle
                            if h then
                                nPlaced = nPlaced + 1
                                if h.owner == owner then nMine = nMine + 1 end
                                if h.parked then nParked = nParked + 1 end
                            end
                        end
                    end
                    local db = DF.GetFrameDB and DF:GetFrameDB(frame)
                    local adOn = DF.IsAuraDesignerEnabled and DF:IsAuraDesignerEnabled(frame)
                    local fac = db and DF.UseFactoryForAD and DF:UseFactoryForAD(frame, db)
                    record("WRONG-AD-SLOTS", unit, "AD slots",
                        format("owner on %s with NO pending retarget | engine=%s placed=%d ownedByThisOwner=%d"
                            .. " parked=%d adEnabled=%s factory=%s exists=%s lastSync=%s",
                            tostring(owner.unit), tostring(bound), nPlaced, nMine, nParked,
                            tostring(adOn and true or false), tostring(fac and true or false),
                            tostring(UnitExists(unit)), tostring(frame.dfADLastSyncAt)))
                end
            end
        end
    end

    if DF.IteratePartyFrames then DF:IteratePartyFrames(visit) end
    if DF.IterateRaidFrames then DF:IterateRaidFrames(visit) end
    if DF.IteratePinnedFrames then DF.IteratePinnedFrames(visit) end
    closeEpisodes()
end

-- ---- panic button --------------------------------------------------------
--
-- The detectors above are still guesses about WHERE staleness comes from. This one
-- assumes nothing: it snapshots every visible frame's container state at the moment you
-- press it, engine truth included, so even a fault nobody has thought of leaves evidence.
--
-- Bind it. One keypress is doable mid-heal; typing a command is not:
--     /run DandersFrames:MarkAuraFault()
--
-- If you can get the mouse over the offending frame first, it records which unit that
-- was -- but do not chase it, the snapshot is worth having regardless.
local MAX_SNAPS = 20

function DF:MarkAuraFault(note)
    DandersFramesDebugDB = DandersFramesDebugDB or {}
    DandersFramesDebugDB.unitsnaps = DandersFramesDebugDB.unitsnaps or {}
    local snaps = DandersFramesDebugDB.unitsnaps

    local flagged
    if UnitExists("mouseover") then
        flagged = (UnitName("mouseover")) or "mouseover"
        if issecretvalue and issecretvalue(flagged) then flagged = "mouseover(secret name)" end
    end

    local rows = {}
    local function visit(frame)
        if not frame or not frame.unit then return end
        local parts = { frame.unit }
        for i = 1, #LANES do
            local lane = LANES[i]
            local h = frame[lane.field]
            if h then
                local bound, enabled = engineState(h.backend and h.backend.container)
                parts[#parts + 1] = format("%s(cfg=%s,engine=%s,en=%s,op=%s%s)", lane.label,
                    tostring(h.config and h.config.unit), tostring(bound), tostring(enabled),
                    tostring(h._pendingOp), (lane.hidden and frame[lane.hidden]) and ",HIDDEN" or "")
            end
        end
        local owner = frame.dfSlotOwner
        if owner then
            local bound, enabled = engineState(owner.container)
            parts[#parts + 1] = format("ADslots(owner=%s,engine=%s,en=%s,pending=%s,sync=%s)",
                tostring(owner.unit), tostring(bound), tostring(enabled),
                tostring(owner.pendingUnit), tostring(frame.dfADLastSyncAt))
        end
        rows[#rows + 1] = table.concat(parts, " ")
    end

    if DF.IteratePartyFrames then DF:IteratePartyFrames(visit) end
    if DF.IterateRaidFrames then DF:IterateRaidFrames(visit) end
    if DF.IteratePinnedFrames then DF.IteratePinnedFrames(visit) end

    if #snaps >= MAX_SNAPS then table.remove(snaps, 1) end
    snaps[#snaps + 1] = {
        session = SESSION,
        at = date("%H:%M:%S"),
        enc = currentEncounter or "(no encounter)",
        combat = inCombat(),
        flagged = flagged,
        note = note,
        rows = rows,
    }
    DF:DebugWarn("UNITSCAN", "SNAPSHOT %d taken (%d frames%s) -- rows in DandersFramesDebugDB.unitsnaps",
        #snaps, #rows, flagged and (", flagged " .. flagged) or "")
    DEFAULT_CHAT_FRAME:AddMessage(format(
        "|cff33ff99DF unitscan|r |cffffcc00snapshot %d taken|r (%d frames%s)",
        #snaps, #rows, flagged and (", flagged " .. flagged) or ""))
end

function DF:DumpAuraUnitLog(clear)
    local log = store()
    local out = DEFAULT_CHAT_FRAME
    local runs = (DandersFramesDebugDB and DandersFramesDebugDB.unitscanRuns) or {}
    for i = math.max(1, #runs - 4), #runs do
        local r = runs[i]
        out:AddMessage(format("|cff33ff99DF unitscan|r session %s: armed %s, %d samples (%d in combat),"
            .. " last %s, %d finding(s)", tostring(r.session), tostring(r.armed), r.samples or 0,
            r.combatSamples or 0, tostring(r.last), r.findings or 0))
    end
    out:AddMessage("|cff33ff99DF unitscan|r " .. #log .. " finding(s)")
    if #log == 0 then
        out:AddMessage("  |cff40ff40nothing caught|r (the recorder is armed automatically)")
    end
    for i = 1, #log do
        local r = log[i]
        out:AddMessage(format("  |cffff4040%s|r {%s} [%s] %s x%d  %s-%s  %s",
            r.kind, tostring(r.session), r.enc, r.unit .. " " .. r.lane, r.n or 1,
            tostring(r.first), tostring(r.last), tostring(r.detail)))
    end
    local snaps = (DandersFramesDebugDB and DandersFramesDebugDB.unitsnaps) or {}
    if #snaps > 0 then
        out:AddMessage("|cff33ff99DF unitscan|r " .. #snaps .. " manual snapshot(s)")
        for i = 1, #snaps do
            local s = snaps[i]
            out:AddMessage(format("  |cffffcc00#%d|r {%s} %s [%s] combat=%s%s%s",
                i, tostring(s.session), tostring(s.at), tostring(s.enc), tostring(s.combat),
                s.flagged and (" flagged=" .. tostring(s.flagged)) or "",
                s.note and (" note=" .. tostring(s.note)) or ""))
            for j = 1, #s.rows do
                out:AddMessage("      " .. s.rows[j])
            end
        end
    end

    if clear then
        DandersFramesDebugDB.unitscan = {}
        DandersFramesDebugDB.unitsnaps = {}
        out:AddMessage("  |cffffcc00log and snapshots cleared|r")
    end
end

-- ---- arming --------------------------------------------------------------
--
-- Always on: a fast ticker in combat, a slower one out of it. Out of combat was the gap
-- the stale indicator on 2026-09-24 fell through. The cost is a few field reads and two
-- plain getters per container per sample.

local driver = CreateFrame("Frame")
driver:RegisterEvent("PLAYER_LOGIN")
driver:RegisterEvent("PLAYER_REGEN_DISABLED")
driver:RegisterEvent("PLAYER_REGEN_ENABLED")
driver:RegisterEvent("ENCOUNTER_START")
driver:RegisterEvent("ENCOUNTER_END")

local ticker, tickerInterval

local function armTicker(interval)
    if ticker and tickerInterval == interval then return end
    if ticker then ticker:Cancel() end
    tickerInterval = interval
    ticker = C_Timer.NewTicker(interval, function()
        if DF.testMode or DF.raidTestMode then return end
        pcall(sample, false)
    end)
end

driver:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "PLAYER_LOGIN" then
        heartbeat()
        DF:Debug("UNITSCAN", "recorder armed, session %s", SESSION)
        armTicker(IDLE_INTERVAL)
    elseif event == "ENCOUNTER_START" then
        currentEncounter = tostring(arg2 or arg1 or "?")
    elseif event == "ENCOUNTER_END" then
        -- Kept until the post-combat sample has run, so its findings are still
        -- tagged with the boss they came from.
        local finished = currentEncounter
        C_Timer.After(POST_COMBAT_DELAY + 1, function()
            if currentEncounter == finished then currentEncounter = nil end
        end)
    elseif event == "PLAYER_REGEN_DISABLED" then
        armTicker(COMBAT_INTERVAL)
    elseif event == "PLAYER_REGEN_ENABLED" then
        armTicker(IDLE_INTERVAL)
        C_Timer.After(POST_COMBAT_DELAY, function() pcall(sample, true) end)
    end
end)
