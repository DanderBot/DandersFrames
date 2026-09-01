local addonName, DF = ...

-- ============================================================
-- TEMPORARY DIAGNOSTIC -- PASSIVE STUCK-CONTAINER RECORDER
--
-- Runs by itself. No command during combat, nothing to remember mid-pull.
-- Arms on login, samples while you are in combat, and writes findings to
-- SavedVariables so they survive a reload. Read it after raid with
--
--     /run DandersFrames:DumpAuraUnitLog()          -- print what it caught
--     /run DandersFrames:DumpAuraUnitLog(true)      -- print, then clear
--
-- WHAT IT WATCHES, and why these four
--
-- Everything here is a plain Lua field DandersFrames wrote itself, so aura
-- secrecy cannot blind it the way it blinded the shown-button count.
--
--   h._pendingOp        A combat-deferred container op (retarget / enable /
--                       rebuild). Legitimate DURING combat -- the drain runs at
--                       regen. Still set AFTER combat means the drain never ran
--                       and that container is frozen on whatever it last showed.
--
--   _pendingOp=="rebuild"  The documented bad case. _queueOp upgrades any two
--                       different lesser ops to "rebuild", and a parent-driven
--                       nested link then skips its rebuild with nothing left to
--                       re-declare the unit -- "the container then keeps driving
--                       the PREVIOUS unit for the rest of the session". Recorded
--                       whenever seen, in combat or not.
--
--   owner.unit ~= frame.unit   The Aura Designer slot owner deliberately keeps
--                       the OLD token while a retarget is deferred, so unlike
--                       Handle:GetUnit (which returns the DESIRED unit and can
--                       therefore never disagree) this really is what is on
--                       screen. pendingUnit set = deferred; not set = stuck.
--
--   dfBuffFactoryHidden and friends   The row hid itself for a deferred retarget.
--                       Cleared only by that row's own drive running again, which
--                       needs a UNIT_AURA on the frame. On a quiet unit after the
--                       pull nothing comes and the row stays hidden -- showing
--                       nothing at all.
--
-- Samples once a second in combat (a few dozen field reads -- nothing you will
-- feel while healing) and once more five seconds after combat ends, which is the
-- sample that matters: by then every legitimate deferral has had its drain.
--
-- DELETE THIS FILE and its TOC line when we are done.
-- ============================================================

local format, date = string.format, date
local MAX_ROWS = 300
local POST_COMBAT_DELAY = 5

local LANES = {
    { field = "buffFactory",      label = "buff",      hidden = "dfBuffFactoryHidden" },
    { field = "debuffFactory",    label = "debuff",    hidden = "dfDebuffFactoryHidden" },
    { field = "defensiveFactory", label = "defensive", hidden = "dfDefFactoryHidden" },
    { field = "dispelFactory",    label = "dispel",    hidden = nil },
}

local currentEncounter

local function store()
    DandersFramesDebugDB = DandersFramesDebugDB or {}
    DandersFramesDebugDB.unitscan = DandersFramesDebugDB.unitscan or {}
    return DandersFramesDebugDB.unitscan
end

-- Deduped: the same fault on the same unit/lane in the same encounter records
-- once with a count, so a 6-minute fight cannot produce 360 identical rows.
local function record(kind, unit, lane, detail)
    local log = store()
    local encName = currentEncounter or (InCombatLockdown() and "(combat)" or "(no encounter)")
    local key = table.concat({ encName, kind, tostring(unit), tostring(lane) }, "|")
    for i = 1, #log do
        if log[i].key == key then
            log[i].n = (log[i].n or 1) + 1
            log[i].last = date("%H:%M:%S")
            return
        end
    end
    if #log >= MAX_ROWS then table.remove(log, 1) end
    log[#log + 1] = {
        key = key, kind = kind, unit = tostring(unit), lane = tostring(lane),
        detail = detail, enc = encName, n = 1,
        first = date("%H:%M:%S"), last = date("%H:%M:%S"),
    }
end

-- postCombat = true means every legitimate deferral has already had its drain,
-- so a pending op or a set hide latch is a genuine stuck state rather than
-- normal in-combat behaviour.
local function sample(postCombat)
    local function visit(frame)
        if not frame or not frame.unit then return end
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
            end
        end

        local owner = frame.dfSlotOwner
        if owner and owner.unit ~= unit then
            if owner.pendingUnit then
                if postCombat then
                    record("STUCK-AD-SLOTS", unit, "AD slots",
                        "owner still on " .. tostring(owner.unit) .. ", pending "
                        .. tostring(owner.pendingUnit) .. " after combat")
                end
            else
                record("WRONG-AD-SLOTS", unit, "AD slots",
                    "owner on " .. tostring(owner.unit) .. " with NO pending retarget")
            end
        end
    end

    if DF.IteratePartyFrames then DF:IteratePartyFrames(visit) end
    if DF.IterateRaidFrames then DF:IterateRaidFrames(visit) end
    if DF.PinnedFrames and DF.PinnedFrames.ForEachActiveFrame then
        DF.PinnedFrames:ForEachActiveFrame(visit)
    end
end

-- ---- panic button --------------------------------------------------------
--
-- The four detectors above are HYPOTHESES read out of the source; none of them
-- is confirmed to be the fault you are seeing. This one assumes nothing: it
-- snapshots every frame's whole container state at the moment you press it, so
-- even if the fault is somewhere I have not thought of, the evidence survives.
--
-- Bind it. One keypress is doable mid-heal; typing a command is not:
--     /run DandersFrames:MarkAuraFault()
--
-- If you can get the mouse over the offending frame first, it records which
-- unit that was -- but do not chase it, the snapshot is worth having regardless.
local MAX_SNAPS = 20

function DF:MarkAuraFault(note)
    DandersFramesDebugDB = DandersFramesDebugDB or {}
    DandersFramesDebugDB.unitsnaps = DandersFramesDebugDB.unitsnaps or {}
    local snaps = DandersFramesDebugDB.unitsnaps

    local flagged
    if UnitExists("mouseover") then
        flagged = (UnitName("mouseover")) or "mouseover"
    end

    local rows = {}
    local function visit(frame)
        if not frame or not frame.unit then return end
        local parts = { frame.unit }
        for i = 1, #LANES do
            local lane = LANES[i]
            local h = frame[lane.field]
            if h then
                local cfgUnit = h.config and h.config.unit
                parts[#parts + 1] = format("%s(cfg=%s,op=%s%s)", lane.label,
                    tostring(cfgUnit), tostring(h._pendingOp),
                    (lane.hidden and frame[lane.hidden]) and ",HIDDEN" or "")
            end
        end
        local owner = frame.dfSlotOwner
        if owner then
            parts[#parts + 1] = format("ADslots(owner=%s,pending=%s)",
                tostring(owner.unit), tostring(owner.pendingUnit))
        end
        rows[#rows + 1] = table.concat(parts, " ")
    end

    if DF.IteratePartyFrames then DF:IteratePartyFrames(visit) end
    if DF.IterateRaidFrames then DF:IterateRaidFrames(visit) end
    if DF.PinnedFrames and DF.PinnedFrames.ForEachActiveFrame then
        DF.PinnedFrames:ForEachActiveFrame(visit)
    end

    if #snaps >= MAX_SNAPS then table.remove(snaps, 1) end
    snaps[#snaps + 1] = {
        at = date("%H:%M:%S"),
        enc = currentEncounter or "(no encounter)",
        combat = InCombatLockdown() and true or false,
        flagged = flagged,
        note = note,
        rows = rows,
    }
    DEFAULT_CHAT_FRAME:AddMessage(format(
        "|cff33ff99DF unitscan|r |cffffcc00snapshot %d taken|r (%d frames%s)",
        #snaps, #rows, flagged and (", flagged " .. flagged) or ""))
end

function DF:DumpAuraUnitLog(clear)
    local log = store()
    local out = DEFAULT_CHAT_FRAME
    out:AddMessage("|cff33ff99DF unitscan|r " .. #log .. " finding(s)")
    if #log == 0 then
        out:AddMessage("  |cff40ff40nothing caught -- no stuck containers seen this session|r")
        out:AddMessage("  (the file is armed automatically; just raid and check back)")
    end
    for i = 1, #log do
        local r = log[i]
        out:AddMessage(format("  |cffff4040%s|r [%s] %s x%d  %s-%s  %s",
            r.kind, r.enc, r.unit .. " " .. r.lane, r.n or 1,
            tostring(r.first), tostring(r.last), tostring(r.detail)))
    end
    local snaps = (DandersFramesDebugDB and DandersFramesDebugDB.unitsnaps) or {}
    if #snaps > 0 then
        out:AddMessage("|cff33ff99DF unitscan|r " .. #snaps .. " manual snapshot(s)")
        for i = 1, #snaps do
            local s = snaps[i]
            out:AddMessage(format("  |cffffcc00#%d|r %s [%s] combat=%s%s%s",
                i, tostring(s.at), tostring(s.enc), tostring(s.combat),
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

local driver = CreateFrame("Frame")
driver:RegisterEvent("PLAYER_REGEN_DISABLED")
driver:RegisterEvent("PLAYER_REGEN_ENABLED")
driver:RegisterEvent("ENCOUNTER_START")
driver:RegisterEvent("ENCOUNTER_END")

local ticker

driver:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ENCOUNTER_START" then
        currentEncounter = tostring(arg2 or arg1 or "?")
    elseif event == "ENCOUNTER_END" then
        -- Kept until the post-combat sample has run, so its findings are still
        -- tagged with the boss they came from.
        local finished = currentEncounter
        C_Timer.After(POST_COMBAT_DELAY + 1, function()
            if currentEncounter == finished then currentEncounter = nil end
        end)
    elseif event == "PLAYER_REGEN_DISABLED" then
        if not ticker then
            ticker = C_Timer.NewTicker(1, function() sample(false) end)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if ticker then ticker:Cancel(); ticker = nil end
        C_Timer.After(POST_COMBAT_DELAY, function() sample(true) end)
    end
end)
