local addonName, DF = ...

-- ============================================================
-- STALE-CONTAINER RECORDER (temporary diagnostic)
-- Runs only while the debug console is on with UNITSCAN logged; for everyone else the
-- ticker is a no-op and nothing is written to SavedVariables.
-- Samples every visible frame (1s in combat, 2s out) for containers showing the wrong
-- unit or no longer listening. Findings go to the debug log under UNITSCAN as START and
-- CLEAR lines with durations -- logged as WARN, because the log evicts INFO first -- and
-- to DandersFramesDebugDB.unitscan as one row per problem per session. Each session also
-- writes a heartbeat to DandersFramesDebugDB.unitscanRuns, so an empty result can be told
-- apart from a recorder that never ran.
--     /run DandersFrames:DumpAuraUnitLog()        -- print; pass true to clear afterwards
--
-- Checks:
--   ENGINE-UNIT     the container's own GetUnit() differs from the frame's unit, so it
--                   shows another player's auras
--   SHOWN-DISABLED  window shown but container disabled, so UNIT_AURA is unregistered
--   STUCK-PENDING-OP / REBUILD-UPGRADE / STUCK-HIDDEN / STUCK-AD-SLOTS / WRONG-AD-SLOTS
--                   DF-side states that lead into a stale container
-- Not checkable:
--   * UNIT_AURA registration: IsEventRegistered is forbidden on containers.
--   * A button still showing an aura that has gone: aura buttons secret-wrap their
--     visibility and icon, out of combat too, so IsShown and GetTexture are secret.
--     MarkAuraFault is the only way to timestamp one.
-- Hidden frames are skipped: they cannot show a stale aura.
--
-- Delete this file and its TOC line when done.
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
    { field = "dispelIconRow",    label = "dispelicons", hidden = nil },
}

-- AD stores holding container-backed handles. "placed" holds SlotHandles, which are
-- checked through the frame's slot owner instead.
local AD_STORES = { "healthbar", "background", "border", "nametext", "healthtext",
                    "fgroups", "dgroups" }
local AD_LANES = {}
for i = 1, #AD_STORES do AD_LANES[i] = "AD " .. AD_STORES[i] end

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

-- Problems seen on the previous sample (kind|unit|lane -> start). A key that is gone
-- from the current sample has cleared.
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

-- Log the episodes that ended since the last sample, with their duration.
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

-- The unit the container is actually bound to, and whether it is enabled. pcall'd: a
-- torn-down container can be half gone.
local function engineState(c)
    if not c then return nil end
    local okU, u = pcall(c.GetUnit, c)
    local okE, en = pcall(c.IsEnabled, c)
    if okU and issecretvalue and issecretvalue(u) then okU = false end
    if okE and issecretvalue and issecretvalue(en) then okE = false end
    -- Explicit ifs: `okE and en or nil` would turn a disabled container's false into nil.
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

-- Age of the frame's last Factory:SyncFrame, formatted only when a row is written.
local function syncAge(frame)
    local t = frame.dfADLastSyncAt
    if type(t) ~= "number" then return "never" end
    return format("%.1fs ago", GetTime() - t)
end

-- The two engine checks, for one Handle (a real per-consumer container).
-- laneKey, when given, is appended to the lane label only if a finding is recorded,
-- so a clean sample builds no strings.
local function checkHandle(h, unit, lane, frame, hiddenFlag, laneKey)
    if not h or h._destroyed then return end
    local c = h.backend and h.backend.container
    if not c then return end
    local bound, enabled = engineState(c)
    local shown = windowShown(h)
    -- A row that hid itself for a deferred retarget legitimately shows the old binding
    -- until regen; it shows NOTHING meanwhile, so it cannot be stale. Skip it.
    local selfHidden = hiddenFlag and frame[hiddenFlag]
    local stale = bound and bound ~= unit and shown ~= false and not selfHidden
    local disabled = shown == true and enabled == false
    if not (stale or disabled) then return end
    if laneKey ~= nil then lane = lane .. ":" .. tostring(laneKey) end
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
                            checkHandle(h, unit, AD_LANES[s], frame, nil, key)
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
                    tostring(enabled), syncAge(frame)))
            end
            if owner.unit ~= unit then
                if owner.pendingUnit then
                    if postCombat then
                        record("STUCK-AD-SLOTS", unit, "AD slots",
                            "owner still on " .. tostring(owner.unit) .. ", pending "
                            .. tostring(owner.pendingUnit) .. " after combat")
                    end
                else
                    -- Nothing pending: record the conditions the Factory's retarget walk
                    -- needs, so the log shows which one failed.
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
                            tostring(UnitExists(unit)), syncAge(frame)))
                end
            end
        end
    end

    if DF.IteratePartyFrames then DF:IteratePartyFrames(visit) end
    if DF.IterateRaidFrames then DF:IterateRaidFrames(visit) end
    if DF.IteratePinnedFrames then DF.IteratePinnedFrames(visit) end
    closeEpisodes()
end

-- ============================================================
-- PANIC BUTTON
-- ============================================================
-- Snapshots every visible frame's container state (engine binding included) when pressed,
-- for faults none of the checks above describe. Bind it to a key:
--     /run DandersFrames:MarkAuraFault()
-- Also records the mouseover unit, if any.
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
                tostring(owner.pendingUnit), syncAge(frame))
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

-- ============================================================
-- ARMING
-- ============================================================
-- 1s ticker in combat, 2s out of it, gated per tick on the debug console so it can be
-- switched on mid-session without a reload. Off, each tick is one predicate call.

local function recorderActive()
    return DF.DebugActive and DF:DebugActive("UNITSCAN") or false
end

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
        if DF.testMode or DF.raidTestMode or not recorderActive() then return end
        pcall(sample, false)
    end)
end

driver:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "PLAYER_LOGIN" then
        if recorderActive() then heartbeat() end
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
        C_Timer.After(POST_COMBAT_DELAY, function()
            if recorderActive() then pcall(sample, true) end
        end)
    end
end)
