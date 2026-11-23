local addonName, NS = ...

-- ============================================================
-- DANDERSMOVER DEMO: THE EASY API (library MINOR 9)
-- Short registration, secure auto-detection, automatic applying, the watcher and
-- SetAnchor, all used the way a third-party addon would use them: public API only.
--
-- ⚠ With the library present these frames are deliberately NEVER placed by hand,
-- apart from the opted-out "Manual" ones (an addon that says watch = false applies
-- for itself). A frame that shows up in the right place therefore proves the library
-- put it there. With no library, or one older than 9, nothing is registered and the
-- frames are placed from their records so the addon still does something visible.
-- ============================================================

local CreateFrame, InCombatLockdown = CreateFrame, InCombatLockdown
local ipairs, pairs, type, tonumber, pcall, tostring = ipairs, pairs, type, tonumber, pcall, tostring
local format, wipe, abs, floor = string.format, wipe, math.abs, math.floor

local Print = NS.Print

local EASY, MANUAL, STRESS = "DandersMoverDemoEasy", "DandersMoverDemoManual", "DandersMoverDemoStress"
local REQUIRED_MINOR = 9

-- ============================================================
-- FRAME DEFINITIONS
-- Two columns, clear of the six long-form frames in Core.lua.
-- ============================================================
local LEFT, RIGHT = -560, 560

local function frameDef(key, title, x, y, color)
    return { key = key, title = title, w = 190, h = 28, color = color,
             frameName = "DandersMoverDemoEasy_" .. key,
             default = { point = "CENTER", x = x, y = y } }
end

local DEFS = {
    leader         = frameDef("leader", "leader (moves itself)", LEFT, 270, { 0.15, 0.60, 0.60 }),
    follower       = frameDef("follower", "follower (/mdemo link: under leader)", LEFT, 150, { 0.25, 0.70, 0.35 }),
    backup         = frameDef("backup", "backup (follower's fallback)", LEFT, 30, { 0.70, 0.55, 0.15 }),
    easySecure     = frameDef("easySecure", "easySecure (protected, no secure field)", LEFT, -90, { 0.55, 0.35, 0.75 }),
    easyLate       = frameDef("easyLate", "easyLate (registered login + 3s)", LEFT, -150, { 0.35, 0.45, 0.85 }),
    easyLazy       = frameDef("easyLazy", "easyLazy (frame made login + 5s)", LEFT, -210, { 0.75, 0.30, 0.45 }),
    manualLeader   = frameDef("manualLeader", "manualLeader (watch = false)", RIGHT, 270, { 0.45, 0.45, 0.45 }),
    manualFollower = frameDef("manualFollower", "manualFollower (needs a refresh)", RIGHT, 150, { 0.65, 0.65, 0.65 }),
}
DEFS.easySecure.secureTemplate = true

-- ============================================================
-- STATE
-- ============================================================
local Mover                     -- the library, or nil when missing or older than REQUIRED_MINOR
local easyDb                    -- DandersMoverDemoDB.easy
local frames = {}               -- key -> frame
local stress = { frames = {}, db = {}, active = 0 }   -- db is deliberately not saved
local moved, big = false, false -- the /mdemo move and /mdemo size toggles
local selftestRunning = false

-- ============================================================
-- GEOMETRY
-- Everything in UIParent units from the screen centre, the same units as a record.
-- ============================================================
local function rectOf(frame)
    return NS.insetRect(frame, 0)
end

-- Where a record puts a frame's centre. Editor writes can leave a corner point in it.
local function recordCentre(rec, w, h)
    local point, x, y = rec.point or "CENTER", rec.x or 0, rec.y or 0
    if point:find("LEFT", 1, true) then x = x + w / 2 elseif point:find("RIGHT", 1, true) then x = x - w / 2 end
    if point:find("TOP", 1, true) then y = y - h / 2 elseif point:find("BOTTOM", 1, true) then y = y + h / 2 end
    return x, y
end

-- A direct SetPoint, not through the record: an addon moving its own frame.
local function placeDirect(frame, x, y)
    NS.applyPositionFallback(frame, { point = "CENTER", x = x, y = y })
end

local function copyTable(t)
    local out = {}
    for k, v in pairs(t) do
        out[k] = type(v) == "table" and copyTable(v) or v
    end
    return out
end

-- ============================================================
-- CREATION AND REGISTRATION
-- ============================================================
local function placeByHand(frame, def)
    if type(easyDb[def.key]) ~= "table" then
        easyDb[def.key] = { point = def.default.point, x = def.default.x, y = def.default.y }
    end
    NS.applyPositionFallback(frame, easyDb[def.key])
end

local function shortForm(def)
    return { title = def.title, default = def.default, db = easyDb, dbKey = def.key }
end

local function spawn(addon, def)
    local f = NS.build(def, def.secureTemplate)
    frames[def.key] = f
    if Mover then
        local reg = shortForm(def)
        reg.frame = f
        Mover:Register(addon, def.key, reg)
    else
        placeByHand(f, def)
    end
end

function NS.EasyInit()
    DandersMoverDemoDB.easy = DandersMoverDemoDB.easy or {}
    easyDb = DandersMoverDemoDB.easy

    -- ⚠ Not `local lib, minor = LibStub and LibStub(...)`: `and` cuts the call down to
    -- one return value, so minor would always be nil.
    local lib, minor
    if LibStub then
        lib, minor = LibStub("DandersMover-1.0", true)
    end
    if lib and minor and minor >= REQUIRED_MINOR then
        Mover = lib
    elseif lib then
        Print(format("DandersMover minor %s is older than %d: easy API section skipped.", tostring(minor), REQUIRED_MINOR))
    else
        Print("DandersMover not installed: easy API section skipped.")
    end

    if Mover then
        Mover:RegisterAddon(EASY, { title = "Mover Demo: Easy", icon = NS.LOGO })
        Mover:RegisterAddon(MANUAL, { title = "Mover Demo: Manual", icon = NS.LOGO, watch = false })
    end

    spawn(EASY, DEFS.leader)
    spawn(EASY, DEFS.follower)
    spawn(EASY, DEFS.backup)
    spawn(EASY, DEFS.easySecure)
    spawn(MANUAL, DEFS.manualLeader)
    spawn(MANUAL, DEFS.manualFollower)

    -- Registered now, while getFrame still answers nil. The frame arrives at login + 5s.
    if Mover then
        local reg = shortForm(DEFS.easyLazy)
        reg.getFrame = function() return frames.easyLazy end
        Mover:Register(EASY, "easyLazy", reg)
    end
end

local function onLogin()
    -- Opted out of the watcher means opted out of automatic applying too.
    if Mover then
        Mover:Apply(MANUAL, "manualLeader")
        Mover:Apply(MANUAL, "manualFollower")
    end
    C_Timer.After(3, function() spawn(EASY, DEFS.easyLate) end)
    C_Timer.After(5, function()
        local def = DEFS.easyLazy
        frames.easyLazy = NS.build(def)
        if not Mover then placeByHand(frames.easyLazy, def) end
    end)
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
    events:UnregisterEvent("PLAYER_LOGIN")
    onLogin()
end)

-- ============================================================
-- LINKING
-- ============================================================
local function linkAll()
    local easyOk = Mover:SetAnchor(EASY, "follower", {
        target = EASY .. ":leader", edge = "bottom", align = "center", offsetX = 0, offsetY = 0,
        fallback = { target = EASY .. ":backup", edge = "bottom", align = "center" },
    })
    local manualOk = Mover:SetAnchor(MANUAL, "manualFollower", {
        target = MANUAL .. ":manualLeader", edge = "bottom", align = "center", offsetX = 0, offsetY = 0,
    })
    return easyOk, manualOk
end

-- ============================================================
-- SIMPLE COMMANDS
-- ============================================================
local function cmdMove()
    moved = not moved
    local function shift(key, dx, dy)
        local r = rectOf(frames[key])
        if not r then return end
        local x, y = recordCentre(easyDb[key], r.w, r.h)
        if moved then placeDirect(frames[key], x + dx, y + dy) else placeDirect(frames[key], x, y) end
    end
    shift("leader", 140, 60)
    shift("manualLeader", -140, 60)
    Print(moved and "leaders moved by SetPoint; the records did not change." or "leaders back at their records.")
end

local function cmdSize()
    big = not big
    for _, key in ipairs({ "leader", "manualLeader" }) do
        local def = DEFS[key]
        frames[key]:SetSize(big and def.w + 80 or def.w, big and def.h + 30 or def.h)
    end
    Print(big and "leaders are big." or "leaders are normal size.")
end

local function cmdScale()
    local scale = frames.leader:GetScale() > 1.01 and 1 or 1.3
    frames.leader:SetScale(scale)
    -- The watcher re-applies a rescaled element, which puts it back at its record.
    moved = false
    Print(format("leader scale %.1f.", scale))
end

local function cmdToggle()
    local show = not frames.leader:IsShown()
    frames.leader:SetShown(show)
    frames.manualLeader:SetShown(show)
    Print(show and "leaders shown." or "leaders hidden.")
end

local function cmdLink()
    local easyOk, manualOk = linkAll()
    Print(format("follower linked: %s, manualFollower linked: %s.", tostring(easyOk), tostring(manualOk)))
end

local function cmdUnlink()
    Mover:Detach(EASY, "follower")
    Mover:Detach(MANUAL, "manualFollower")
    Print("follower and manualFollower detached where they sit.")
end

local function printStats()
    local s = Mover:GetWatcherStats()
    Print(format("watcher: running=%s watched=%d measured=%d ticks=%d lastMs=%.3f maxMs=%.3f",
        tostring(s.running), s.watched, s.measured, s.ticks, s.lastMs, s.maxMs))
end

-- ============================================================
-- STRESS
-- A chain that snakes back and forth from leader's right edge, so a big one stays on
-- screen: the on-screen rescue would otherwise pile the far end into one spot.
-- ============================================================
local STRESS_DEFAULT, STRESS_MAX, STRESS_ROW = 40, 200, 20

local function stressSeat(i)
    if i == 1 then return EASY .. ":leader", "right" end
    local prev = STRESS .. ":s" .. (i - 1)
    if (i - 1) % STRESS_ROW == 0 then return prev, "bottom" end
    return prev, floor((i - 1) / STRESS_ROW) % 2 == 0 and "right" or "left"
end

local function stressOff()
    Mover:UnregisterAddon(STRESS)
    for _, f in ipairs(stress.frames) do f:Hide() end
    wipe(stress.db)
    stress.active = 0
end

local function stressOn(n)
    stressOff()
    Mover:RegisterAddon(STRESS, { title = "Mover Demo: Stress", icon = NS.LOGO })
    local refused = 0
    for i = 1, n do
        local key = "s" .. i
        local f = stress.frames[i]
        if not f then
            f = NS.build({ key = key, title = "", w = 12, h = 12, color = { 0.9, 0.9, 0.2 },
                           frameName = "DandersMoverDemoStress" .. i })
            stress.frames[i] = f
        end
        f:Show()
        Mover:Register(STRESS, key, { title = "Stress " .. i, frame = f, db = stress.db, dbKey = key,
                                      default = { point = "CENTER", x = 0, y = 0 } })
        local target, edge = stressSeat(i)
        if not Mover:SetAnchor(STRESS, key, { target = target, edge = edge, align = "center" }) then
            refused = refused + 1
        end
    end
    stress.active = n
    Print(format("stress: %d frames chained to leader (%d anchors refused). /mdemo stats for the per-tick cost.", n, refused))
end

local function cmdStress(rest)
    if rest == "off" then
        stressOff()
        Print("stress off.")
        return
    end
    local n = rest == "" and STRESS_DEFAULT or tonumber(rest)
    if not n then
        Print("usage: /mdemo stress [n|off]")
        return
    end
    stressOn(math.max(1, math.min(STRESS_MAX, floor(n))))
end

-- ============================================================
-- SELFTEST
-- Each step acts, then a later timer checks, so the watcher gets a couple of ticks in
-- between. A failed check carries on; a thrown error, a refused link, combat or an
-- unlock stops early. Every route out goes through finish, which restores everything.
--
-- ⚠ Restoring is two-phase. Putting leader's scale back counts as a scale change to
-- the watcher, which re-applies it to its record on the next tick; a leader that was
-- off its record through /mdemo move before the test has to be put back after that.
-- ============================================================
local STEP_DELAY, TOLERANCE = 0.5, 1
local MOVE_X, MOVE_Y = 60, 40
local GROW_W, GROW_H = 40, 30

local RECORDS = {
    { EASY, "leader" }, { EASY, "backup" }, { MANUAL, "manualLeader" },
    { EASY, "follower" }, { MANUAL, "manualFollower" },
}
local FRAME_STATE_KEYS = { "leader", "backup", "manualLeader" }

local function near(a, b)
    return type(a) == "number" and type(b) == "number" and abs(a - b) <= TOLERANCE
end

local function runSelftest()
    local passed, failed = 0, 0
    local function check(ok, msg)
        if ok then
            passed = passed + 1
            Print("|cff40ff40PASS|r " .. msg)
        else
            failed = failed + 1
            Print("|cffff4040FAIL|r " .. msg)
        end
        return ok
    end

    local leader, follower, backup = frames.leader, frames.follower, frames.backup
    local manualLeader, manualFollower = frames.manualLeader, frames.manualFollower

    -- ---- what gets put back ----
    local savedRecords, savedFrames = {}, {}
    for _, entry in ipairs(RECORDS) do
        savedRecords[entry[2]] = copyTable(easyDb[entry[2]])
    end
    for _, key in ipairs(FRAME_STATE_KEYS) do
        local f = frames[key]
        local w, h = f:GetSize()
        local r = rectOf(f)
        savedFrames[key] = { w = w, h = h, scale = f:GetScale(), shown = f:IsShown(), x = r.x, y = r.y }
    end

    local function restoreRecordsAndFrames()
        for _, key in ipairs(FRAME_STATE_KEYS) do
            local s = savedFrames[key]
            frames[key]:SetSize(s.w, s.h)
            frames[key]:SetScale(s.scale)
        end
        for _, entry in ipairs(RECORDS) do
            local rec, saved = easyDb[entry[2]], savedRecords[entry[2]]
            wipe(rec)
            for k, v in pairs(copyTable(saved)) do rec[k] = v end
        end
        -- Not Mover:Apply: that re-solves, and a manualFollower left stale on purpose
        -- before the test has to stay exactly as stale.
        for _, entry in ipairs(RECORDS) do
            Mover.ApplyPosition(frames[entry[2]], easyDb[entry[2]])
        end
    end

    local function restoreFramePlaces()
        for _, key in ipairs(FRAME_STATE_KEYS) do
            local s = savedFrames[key]
            placeDirect(frames[key], s.x, s.y)
            frames[key]:SetShown(s.shown)
        end
        Mover:RefreshAnchorTarget(EASY, "leader")
    end

    local function checkRestored()
        local allGood = true
        for _, entry in ipairs(RECORDS) do
            local rec, saved = easyDb[entry[2]], savedRecords[entry[2]]
            local savedTarget = saved.anchor and saved.anchor.target
            local recTarget = rec.anchor and rec.anchor.target
            if recTarget ~= savedTarget or not (near(rec.x, saved.x) and near(rec.y, saved.y)) then allGood = false end
        end
        for _, key in ipairs(FRAME_STATE_KEYS) do
            local s, f = savedFrames[key], frames[key]
            local w, h = f:GetSize()
            local r = rectOf(f)
            if not (near(w, s.w) and near(h, s.h) and abs(f:GetScale() - s.scale) < 0.01
                and (f:IsShown() and true or false) == (s.shown and true or false)
                and r and near(r.x, s.x) and near(r.y, s.y)) then
                allGood = false
            end
        end
        check(allGood, "everything put back as it was")
    end

    local function finish()
        local ok, err = pcall(restoreRecordsAndFrames)
        if not ok then check(false, "restoring threw: " .. tostring(err)) end
        C_Timer.After(STEP_DELAY, function()
            local ok2, err2 = pcall(function()
                restoreFramePlaces()
                checkRestored()
            end)
            if not ok2 then check(false, "restoring threw: " .. tostring(err2)) end
            selftestRunning = false
            Print(format("selftest: %d passed, %d failed.", passed, failed))
        end)
    end

    -- ---- shared checks ----
    local gap, manualGap, followerX, followerY

    local function sitsAtRecord(key, what)
        local f, rec = frames[key], easyDb[key]
        local r = rectOf(f)
        if not r then return check(false, what .. ": the frame has no position yet") end
        local x, y = recordCentre(rec, r.w, r.h)
        return check(near(r.x, x) and near(r.y, y),
            format("%s: centred on its record (frame %.1f,%.1f record %.1f,%.1f)", what, r.x, r.y, x, y))
    end

    -- A centred bottom-edge seat: x of the parent, and the gap under its bottom edge.
    -- The gap is measured from the first solve rather than assumed.
    local function checkSeat(key, parent, parentGap, what)
        local rec = easyDb[key]
        local c, p = rectOf(frames[key]), rectOf(parent)
        local y = p.y - p.h / 2 - parentGap - c.h / 2
        return check(near(rec.x, p.x) and near(rec.y, y),
            format("%s (record %.1f,%.1f expected %.1f,%.1f)", what, rec.x, rec.y, p.x, y))
    end

    local function measureGap(key, parent)
        local rec = easyDb[key]
        local c, p = rectOf(frames[key]), rectOf(parent)
        return p.y - p.h / 2 - (rec.y + c.h / 2)
    end

    -- ---- the steps ----
    local before, beforeLeader
    local linkedOk, manualLinkedOk

    local steps = {
        {   -- A known starting point. Anchors of the editor's on these three would fight the test.
            act = function()
                Mover:Detach(EASY, "leader")
                Mover:Detach(EASY, "backup")
                Mover:Detach(MANUAL, "manualLeader")
                leader:SetScale(1)
                leader:Show()
                backup:Show()
                manualLeader:Show()
                Mover:Apply(EASY, "leader")
                Mover:Apply(EASY, "backup")
                Mover:Apply(MANUAL, "manualLeader")
            end,
        },
        {
            act = function()
                linkedOk, manualLinkedOk = linkAll()
            end,
            verify = function()
                check(linkedOk, "link: SetAnchor accepts follower with a fallback")
                check(manualLinkedOk, "link: SetAnchor accepts manualFollower")
                if not (linkedOk and manualLinkedOk) then return false end
                gap, manualGap = measureGap("follower", leader), measureGap("manualFollower", manualLeader)
                check(gap >= -TOLERANCE and gap <= 20, format("link: follower seated under leader (gap %.1f)", gap))
                check(near(easyDb.follower.x, rectOf(leader).x), "link: follower centred on leader")
                check(manualGap >= -TOLERANCE and manualGap <= 20,
                    format("link: manualFollower seated under manualLeader (gap %.1f)", manualGap))
                sitsAtRecord("follower", "link: follower")
            end,
        },
        {
            act = function()
                before = { x = easyDb.follower.x, y = easyDb.follower.y }
                beforeLeader = rectOf(leader)
                placeDirect(leader, beforeLeader.x + MOVE_X, beforeLeader.y + MOVE_Y)
            end,
            verify = function()
                local r = rectOf(leader)
                local dx, dy = r.x - beforeLeader.x, r.y - beforeLeader.y
                check(near(dx, MOVE_X) and near(dy, MOVE_Y), format("move: leader's frame moved (%.1f,%.1f)", dx, dy))
                local fx, fy = easyDb.follower.x - before.x, easyDb.follower.y - before.y
                check(near(fx, dx) and near(fy, dy), format("move: follower's record moved the same (%.1f,%.1f)", fx, fy))
                sitsAtRecord("follower", "move: follower")
            end,
        },
        {
            act = function()
                beforeLeader = rectOf(leader)
                local w, h = leader:GetSize()
                leader:SetSize(w + GROW_W, h + GROW_H)
            end,
            verify = function()
                local r = rectOf(leader)
                check(r.h > beforeLeader.h + GROW_H / 2, "resize: leader grew")
                checkSeat("follower", leader, gap, "resize: follower re-solved on the moved edge")
                sitsAtRecord("follower", "resize: follower")
            end,
        },
        {
            act = function()
                followerX, followerY = easyDb.follower.x, easyDb.follower.y
                leader:Hide()
            end,
            verify = function()
                checkSeat("follower", backup, gap, "hide: follower on backup's seat")
                sitsAtRecord("follower", "hide: follower")
            end,
        },
        {
            act = function() leader:Show() end,
            verify = function()
                check(near(easyDb.follower.x, followerX) and near(easyDb.follower.y, followerY),
                    "show: follower back on leader's seat")
            end,
        },
        {
            act = function() leader:SetScale(1.3) end,
            verify = function()
                sitsAtRecord("leader", "scale: leader")
                checkSeat("follower", leader, gap, "scale: follower re-solved on the rescaled leader")
            end,
        },
        {
            act = function()
                before = { x = easyDb.manualFollower.x, y = easyDb.manualFollower.y }
                beforeLeader = rectOf(manualLeader)
                placeDirect(manualLeader, beforeLeader.x + MOVE_X, beforeLeader.y + MOVE_Y)
            end,
            verify = function()
                local r = rectOf(manualLeader)
                check(near(r.x - beforeLeader.x, MOVE_X) and near(r.y - beforeLeader.y, MOVE_Y),
                    "manual: manualLeader's frame moved")
                check(near(easyDb.manualFollower.x, before.x) and near(easyDb.manualFollower.y, before.y),
                    "manual: manualFollower did NOT follow (watch = false)")
            end,
        },
        {
            act = function() Mover:RefreshAnchorTarget(MANUAL, "manualLeader") end,
            verify = function()
                local r = rectOf(manualLeader)
                local fx, fy = easyDb.manualFollower.x - before.x, easyDb.manualFollower.y - before.y
                check(near(fx, r.x - beforeLeader.x) and near(fy, r.y - beforeLeader.y),
                    format("manual: RefreshAnchorTarget moved manualFollower (%.1f,%.1f)", fx, fy))
                checkSeat("manualFollower", manualLeader, manualGap, "manual: manualFollower on its seat")
                sitsAtRecord("manualFollower", "manual: manualFollower")
            end,
        },
        {
            verify = function()
                -- In brackets: IsProtected answers two values.
                check((frames.easySecure:IsProtected()), "secure: easySecure is protected")
                sitsAtRecord("easySecure", "secure: easySecure")
                for _, key in ipairs({ "easyLate", "easyLazy" }) do
                    if frames[key] and rectOf(frames[key]) then
                        sitsAtRecord(key, key)
                    else
                        check(false, key .. ": not there yet, wait a few seconds after login")
                    end
                end
                check(Mover:GetWatcherStats().running, "watcher: running")
                printStats()
            end,
        },
    }

    local function interrupted()
        if InCombatLockdown() then
            check(false, "stopped early: combat started")
            return true
        end
        if Mover:IsUnlocked() then
            check(false, "stopped early: the editor was unlocked; check positions if you keep the session")
            return true
        end
        return false
    end

    local function runStep(i)
        local step = steps[i]
        if not step then return finish() end
        if interrupted() then return finish() end
        if step.act then
            local ok, err = pcall(step.act)
            if not ok then
                check(false, "a step threw: " .. tostring(err))
                return finish()
            end
        end
        C_Timer.After(STEP_DELAY, function()
            if interrupted() then return finish() end
            if step.verify then
                local ok, result = pcall(step.verify)
                if not ok then
                    check(false, "a check threw: " .. tostring(result))
                    return finish()
                end
                if result == false then return finish() end
            end
            runStep(i + 1)
        end)
    end

    selftestRunning = true
    Print("selftest: started, takes about 6 seconds.")
    runStep(1)
end

local function cmdSelftest()
    if InCombatLockdown() then
        Print("selftest refused: in combat.")
    elseif Mover:IsUnlocked() then
        Print("selftest refused: the editor is unlocked.")
    else
        for _, key in ipairs(FRAME_STATE_KEYS) do
            if not rectOf(frames[key]) then
                Print("selftest refused: the frames are not placed yet, wait a few seconds after login.")
                return
            end
        end
        runSelftest()
    end
end

-- ============================================================
-- SLASH HOOK
-- Called first by Core.lua's handler. False hands the word back to it.
-- ============================================================
local COMMANDS = {
    move = cmdMove, size = cmdSize, scale = cmdScale, toggle = cmdToggle,
    link = cmdLink, unlink = cmdUnlink, stats = printStats, stress = cmdStress,
    selftest = cmdSelftest,
}

function NS.EasyCommand(cmd, rest)
    local fn = COMMANDS[cmd]
    if not fn then return false end
    if not Mover then
        Print(format("/mdemo %s needs DandersMover minor %d or newer.", cmd, REQUIRED_MINOR))
    elseif selftestRunning and cmd ~= "stats" then
        Print("the selftest is running; try again when it has finished.")
    else
        fn(rest)
    end
    return true
end

-- Exposed for /run poking during manual testing only.
NS.easyFrames = frames
