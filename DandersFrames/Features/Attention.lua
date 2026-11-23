local addonName, DF = ...

local ipairs, pairs, type, pcall, select, tostring = ipairs, pairs, type, pcall, select, tostring
local format = string.format
local sort, concat, unpack = table.sort, table.concat, unpack

-- Core.lua has loaded, so DF.L exists; the language overlay later writes into
-- this same table, and every lookup below runs at evaluation time.
local L = DF.L

-- ============================================================
-- NEEDS ATTENTION -- THE REGISTRY
-- Things DF already knows are wrong or left on (Blizzard frames still showing,
-- a reload pending, frames unlocked, ...). The settings window's Home page
-- renders them (DandersFrames_Options/GUI/Pages/Home.lua) and the Home rail
-- item badges the count; nothing here draws anything.
--
-- ☠ RESIDENT ON PURPOSE: the checks must answer with the settings panel never
-- opened (the rail badge, a possible future login nudge), so the registry is
-- here and the companion only renders it.
--
-- ⚠ CHEAP BY CONTRACT. Nothing runs at load beyond defining the checks; they
-- are evaluated only when asked (the window opening, Home showing), never on a
-- timer and never in combat -- in combat GetActive hands back the last list.
-- A check is plain reads. One that errors is skipped, not fatal.
--
-- Register{
--   id       = "blizzardFrames",          unique
--   severity = 1 | 2 | 3,                 1 conflict, 2 setup, 3 info
--   check    = function() return active, arg1, arg2, ... end,
--   title    = string | function(arg1, ...) -> string,   localised at evaluation
--   detail   = string | function(arg1, ...) -> string,
--   fix      = { label = string|function, run = function() end, combatSafe = bool }
--            | { label = ..., page = "profiles_auto" }
--            | function(arg1, ...) -> one of those, or nil
--   dismiss  = "session" | "version" | "forever" | nil (not dismissable),
--   dismissKey = function(arg1, ...) -> string   (optional, "version" only: the
--              version a dismissal is good for; default DF.VERSION, so it comes
--              back after the next update)
-- }
--
-- GetActive() returns, sorted by severity then registration order, minus
-- dismissed items:
--   { id, severity, title, detail, fix = { label, run | page, combatSafe }, dismiss }
-- ============================================================

local Attention = {}
DF.Attention = Attention

local defs = {}          -- in registration order
local byId = {}
local sessionDismissed = {}
local lastList           -- the last evaluation (what combat hands back)

local function Resolve(v, ...)
    if type(v) == "function" then return v(...) end
    return v
end

function Attention:Register(def)
    if type(def) ~= "table" or type(def.id) ~= "string" or type(def.check) ~= "function" then
        if DF.DebugWarn then DF:DebugWarn("ATTENTION", "Register: bad definition") end
        return
    end
    if byId[def.id] then
        -- Re-registering replaces in place (keeps its order).
        for i, d in ipairs(defs) do
            if d.id == def.id then defs[i] = def end
        end
    else
        defs[#defs + 1] = def
    end
    def.severity = def.severity or 3
    byId[def.id] = def
end

-- ---- dismissals -------------------------------------------------------
local function DismissStore(create)
    if type(DandersFramesDB_v2) ~= "table" then return nil end
    local t = DandersFramesDB_v2.attentionDismissed
    if t == nil and create then
        t = {}
        DandersFramesDB_v2.attentionDismissed = t
    end
    return type(t) == "table" and t or nil
end

-- pcall'd check: ok, active, args ({ n = count, ... } of the extra returns).
local function Pack(...) return { n = select("#", ...), ... } end

local function RunCheck(def)
    local r = Pack(pcall(def.check))
    if not r[1] then return false, false, { n = 0 }, r[2] end
    local args = { n = math.max(0, r.n - 2) }
    for i = 1, args.n do args[i] = r[i + 2] end
    return true, r[2] and true or false, args
end

local function VersionKey(def, args)
    if def.dismissKey then
        local ok, key = pcall(def.dismissKey, unpack(args, 1, args.n))
        if ok and key ~= nil then return tostring(key) end
    end
    return tostring(DF.VERSION or "")
end

local function IsDismissed(def, args)
    local mode = def.dismiss
    if not mode then return false end
    if sessionDismissed[def.id] then return true end
    local store = DismissStore(false)
    local v = store and store[def.id]
    if v == nil then return false end
    if mode == "forever" then return v == true end
    if mode == "version" then return v == VersionKey(def, args) end
    return false
end

-- Session dismissals live in memory; "version" ones are stored against the
-- version they were dismissed on, "forever" ones as true.
function Attention:Dismiss(id)
    local def = byId[id]
    if not def or not def.dismiss then return false end
    if def.dismiss == "session" then
        sessionDismissed[id] = true
    else
        local store = DismissStore(true)
        if not store then
            sessionDismissed[id] = true
        elseif def.dismiss == "forever" then
            store[id] = true
        else
            -- Stored against the key the item was showing for.
            local _, _, args = RunCheck(def)
            store[id] = VersionKey(def, args)
        end
    end
    -- Drop it from the cached list too, so combat (and the badge) agree.
    if lastList then
        for i = #lastList, 1, -1 do
            if lastList[i].id == id then table.remove(lastList, i) end
        end
    end
    return true
end

-- Testing / support: forget every dismissal.
function Attention:ResetDismissals()
    for k in pairs(sessionDismissed) do sessionDismissed[k] = nil end
    if type(DandersFramesDB_v2) == "table" then DandersFramesDB_v2.attentionDismissed = nil end
end

-- ---- evaluation -------------------------------------------------------
local function Evaluate(def)
    local ok0, active, args, err = RunCheck(def)
    if not ok0 then
        if DF.DebugWarn then DF:DebugWarn("ATTENTION", "check '%s' failed: %s", def.id, tostring(err)) end
        return nil
    end
    if not active then return nil end
    if IsDismissed(def, args) then return nil end

    local ok, item = pcall(function()
        local a = args
        local fix = Resolve(def.fix, unpack(a, 1, a.n))
        local outFix
        if type(fix) == "table" then
            outFix = {
                label = Resolve(fix.label, unpack(a, 1, a.n)),
                run = fix.run,
                page = fix.page,
                combatSafe = fix.combatSafe and true or false,
            }
        end
        return {
            id = def.id,
            severity = def.severity,
            title = Resolve(def.title, unpack(a, 1, a.n)),
            detail = Resolve(def.detail, unpack(a, 1, a.n)),
            fix = outFix,
            dismiss = def.dismiss,
        }
    end)
    if not ok then
        if DF.DebugWarn then DF:DebugWarn("ATTENTION", "item '%s' failed: %s", def.id, tostring(item)) end
        return nil
    end
    return item
end

-- useCache: hand back the last evaluation when there is one (a re-layout
-- that changes no state). Combat always does.
function Attention:GetActive(useCache)
    if lastList and (useCache or (InCombatLockdown and InCombatLockdown())) then
        return lastList
    end
    if InCombatLockdown and InCombatLockdown() then return {} end
    local list, order = {}, {}
    for i, def in ipairs(defs) do
        local item = Evaluate(def)
        if item then
            list[#list + 1] = item
            order[item] = i
        end
    end
    sort(list, function(a, b)
        if a.severity ~= b.severity then return a.severity < b.severity end
        return order[a] < order[b]
    end)
    lastList = list
    return list
end

-- How many items are active, optionally only those at maxSeverity or more
-- urgent (the rail badge counts 1-2). cachedOnly: never evaluate (0 before the
-- first evaluation).
function Attention:Count(maxSeverity, cachedOnly)
    local list = cachedOnly and (lastList or {}) or self:GetActive()
    if not maxSeverity then return #list end
    local n = 0
    for _, item in ipairs(list) do
        if item.severity <= maxSeverity then n = n + 1 end
    end
    return n
end

-- ============================================================
-- LOAD-TIME SNAPSHOTS -- what the session was built with
-- Some settings only apply on a reload. Core.lua calls SnapshotLoaded at the
-- same point it records DF.loadedPartyEnabled; click-casting initialises at
-- the first PLAYER_ENTERING_WORLD, so its flag is taken one frame after that.
-- ============================================================
local loaded = {}
Attention._loaded = loaded

local function LangKey(v)
    if v == nil or v == "AUTO" then return "AUTO" end
    return v
end

function Attention:SnapshotLoaded()
    local db = DF.db
    if db then
        loaded.hideParty = (db.party and db.party.hideBlizzardPartyFrames) and true or false
        loaded.hideRaid = (db.raid and db.raid.hideBlizzardRaidFrames) and true or false
    end
    loaded.language = LangKey(DandersFramesCharDB and DandersFramesCharDB.languageOverride)
    loaded.taken = true
end

function Attention:SnapshotClickCast()
    local CC = DF.ClickCast
    if CC and CC.db then loaded.clickCast = CC.db.enabled and true or false end
end

if CreateFrame then
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:SetScript("OnEvent", function(self, _, isInitialLogin, isReloadingUi)
        if not (isInitialLogin or isReloadingUi) then return end
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function() Attention:SnapshotClickCast() end)
        else
            Attention:SnapshotClickCast()
        end
    end)
end

-- What differs from the loaded state (a list of reasons; empty = nothing).
function Attention:ReloadReasons()
    local out = {}
    if DF.EnableFlagsDifferFromLoaded and DF:EnableFlagsDifferFromLoaded() then out[#out + 1] = "enable" end
    local db = DF.db
    if loaded.taken and db then
        local hp = (db.party and db.party.hideBlizzardPartyFrames) and true or false
        local hr = (db.raid and db.raid.hideBlizzardRaidFrames) and true or false
        if hp ~= loaded.hideParty or hr ~= loaded.hideRaid then out[#out + 1] = "blizzard" end
        if LangKey(DandersFramesCharDB and DandersFramesCharDB.languageOverride) ~= loaded.language then
            out[#out + 1] = "language"
        end
    end
    local CC = DF.ClickCast
    if loaded.clickCast ~= nil and CC and CC.db and ((CC.db.enabled and true or false) ~= loaded.clickCast) then
        out[#out + 1] = "clickcast"
    end
    return out
end

-- ============================================================
-- THE v1 CHECKS
-- ⚠ Every optional system is guarded: the companion, DandersMover, click-cast
-- and the profiler may each be absent.
-- ============================================================
local function Reload() if ReloadUI then ReloadUI() end end

-- 1. Blizzard party/raid frames not hidden. The same condition as the reload
-- prompt the Party/Raid enable switches show (PromptReloadAfterModeToggle).
local function BlizzardShowing()
    local db = DF.db
    if not db then return false end
    local party = db.partyEnabled ~= false and not (db.party and db.party.hideBlizzardPartyFrames)
    local raid = db.raidEnabled ~= false and not (db.raid and db.raid.hideBlizzardRaidFrames)
    return party or raid, party, raid
end
Attention.BlizzardShowing = BlizzardShowing

Attention:Register{
    id = "blizzardFrames", severity = 1, dismiss = "forever",
    check = BlizzardShowing,
    title = function(party, raid)
        if party and raid then return L["Blizzard party and raid frames are still showing"] end
        if party then return L["Blizzard party frames are still showing"] end
        return L["Blizzard raid frames are still showing"]
    end,
    detail = function() return L["They show alongside DandersFrames. Hiding them takes a UI reload."] end,
    fix = {
        label = function() return L["Hide and Reload"] end,
        run = function()
            local db = DF.db
            if not db then return end
            local _, party, raid = BlizzardShowing()
            -- Both modes, as the existing prompt writes them.
            for _, mode in ipairs({ "party", "raid" }) do
                if db[mode] then
                    if party then db[mode].hideBlizzardPartyFrames = true end
                    if raid then db[mode].hideBlizzardRaidFrames = true end
                end
            end
            Reload()
        end,
    },
}

-- 2. Reload needed.
Attention:Register{
    id = "reloadNeeded", severity = 2,
    check = function()
        local reasons = Attention:ReloadReasons()
        return #reasons > 0, concat(reasons, ",")
    end,
    title = function() return L["A UI reload is needed"] end,
    detail = function() return L["Some changes only take effect after a reload."] end,
    fix = { label = function() return L["Reload Now"] end, run = Reload },
}

-- 3. Click-cast conflict (Clique / Clicked loaded while ours is on). A user
-- who ticked "don't warn me again" chose to run both; not raised for them.
Attention:Register{
    id = "clickCastConflict", severity = 1, dismiss = "session",
    check = function()
        local CC = DF.ClickCast
        if not (CC and CC.db and CC.db.enabled and CC.hasConflictingAddons) then return false end
        if CC.db.ignoreConflictWarning then return false end
        local names = type(CC.conflictingAddons) == "table" and concat(CC.conflictingAddons, ", ") or ""
        return true, names
    end,
    title = function(names)
        if names and names ~= "" then return format(L["Click-casting conflicts with %s"], names) end
        return L["Click-casting conflicts with another addon"]
    end,
    detail = function() return L["Two click-casting addons on the same frames fight over every click."] end,
    fix = {
        label = function() return L["Resolve"] end,
        run = function()
            local CC = DF.ClickCast
            if not CC then return end
            if not CC.ShowClickCastConflictPopup and DF.EnsureOptionsLoaded then DF:EnsureOptionsLoaded() end
            if CC.ShowClickCastConflictPopup then
                CC:ShowClickCastConflictPopup(CC.conflictingAddons, CC.enableCb)
            end
        end,
    },
}

-- 4. Frames unlocked (a mover session open, or a lock flag left off).
local function UnlockedScopes()
    local B = DF.MoverBridge
    local session = B and B.IsSessionActive and B:IsSessionActive() or false
    local db = DF.db
    local party = db and db.party and db.party.locked == false or false
    local raid = db and db.raid and db.raid.raidLocked == false or false
    return session, party, raid
end
Attention.UnlockedScopes = UnlockedScopes

Attention:Register{
    id = "framesUnlocked", severity = 2, dismiss = "session",
    check = function()
        local session, party, raid = UnlockedScopes()
        return session or party or raid
    end,
    title = function() return L["Frames are unlocked"] end,
    detail = function() return L["Lock them so they can't be dragged by accident."] end,
    fix = {
        label = function() return L["Lock"] end,
        run = function()
            local session, party, raid = UnlockedScopes()
            -- A session is one lock (it restores both flags itself).
            if session or party then
                if DF.LockFrames then DF:LockFrames() end
            end
            if raid and not session and DF.LockRaidFrames then DF:LockRaidFrames() end
        end,
    },
}

-- 5. Test mode left on (the USER's claim -- unlock holds its own).
local function TestScopes()
    if not DF.IsTestModeOwnedBy then return false, false end
    return DF:IsTestModeOwnedBy("party", "user"), DF:IsTestModeOwnedBy("raid", "user")
end

Attention:Register{
    id = "testModeOn", severity = 2, dismiss = "session",
    check = function()
        local party, raid = TestScopes()
        return party or raid
    end,
    title = function() return L["Test mode is on"] end,
    detail = function() return L["The preview frames are still showing."] end,
    fix = {
        label = function() return L["Turn Off"] end,
        run = function()
            local party, raid = TestScopes()
            if not DF.SetTestModeOwner then return end
            if party then DF:SetTestModeOwner("party", "user", false) end
            if raid then DF:SetTestModeOwner("raid", "user", false) end
        end,
    },
}

-- 6. Auto Layout overriding settings. Info only.
Attention:Register{
    id = "autoLayoutActive", severity = 3, dismiss = "session",
    check = function()
        local AP = DF.AutoProfilesUI
        local profile = AP and AP.activeRuntimeProfile
        if not profile then return false end
        local count = AP._priv and AP._priv.CountDisplayedOverrides
        local n = count and count(profile.overrides) or 0
        if not n or n <= 0 then return false end
        return true, profile.name or "", n
    end,
    title = function(name) return format(L["Auto Layout \"%s\" is active"], tostring(name or "")) end,
    detail = function(_, n) return format(L["It is changing %d settings on your raid frames."], n or 0) end,
    fix = { label = function() return L["Open"] end, page = "profiles_auto" },
}

-- 7. Newer version seen (Features/VersionCheck.lua records VC.newestSeen).
-- Respects the "notify when outdated" setting, as the chat line does.
Attention:Register{
    id = "newerVersion", severity = 3, dismiss = "version",
    check = function()
        local VC = DF.VersionCheck
        local seen = VC and VC.newestSeen
        if not (seen and seen.version) then return false end
        local g = DF.GetGlobalDB and DF:GetGlobalDB()
        if g and g.notifyOutdated == false then return false end
        return true, seen.version
    end,
    dismissKey = function(version) return version end,
    title = function() return L["Update available"] end,
    detail = function(version) return format(L["A newer version is available (%s). Get it on CurseForge."], tostring(version)) end,
}

-- 8. Debug logging left on. Only the LOG: the profiler hook is its own item
-- (8b) -- one title for both read "logging is on" while the log was off.
Attention:Register{
    id = "debugLogging", severity = 3, dismiss = "session",
    check = function()
        local sv = DandersFramesDB_v2
        return type(sv) == "table" and type(sv.debug) == "table" and sv.debug.enabled == true
    end,
    title = function() return L["Debug logging is on"] end,
    detail = function() return L["It records extra data every session. Turn it off unless you are reporting a bug."] end,
    fix = {
        label = function() return L["Turn Off"] end,
        combatSafe = true,
        run = function()
            local sv = DandersFramesDB_v2
            if DF.DebugConsole and DF.DebugConsole.SetEnabled then
                DF.DebugConsole:SetEnabled(false)
            elseif type(sv) == "table" and type(sv.debug) == "table" then
                sv.debug.enabled = false
            end
        end,
    },
}

-- 8b. The profiler's OnUpdate hook left on.
Attention:Register{
    id = "profilerHook", severity = 3, dismiss = "session",
    check = function()
        local sv = DandersFramesDB_v2
        return type(sv) == "table" and sv.profilerOnUpdateHook == true
    end,
    title = function() return L["The profiler hook is on"] end,
    detail = function() return L["It times every frame update. Turn it off unless you are measuring performance. Takes effect after a reload."] end,
    fix = {
        label = function() return L["Turn Off"] end,
        combatSafe = true,
        run = function()
            local sv = DandersFramesDB_v2
            -- The hook is latched at load; this takes effect on the next reload.
            if type(sv) == "table" then sv.profilerOnUpdateHook = nil end
        end,
    },
}

-- 9. DandersMover missing -- only once the user has tried to unlock without
-- it this session (Frames/Position.lua and Frames/Init.lua set the flag).
Attention:Register{
    id = "moverMissing", severity = 3, dismiss = "session",
    check = function()
        if not DF.unlockWithoutMover then return false end
        return not (LibStub and LibStub("DandersMover-1.0", true))
    end,
    title = function() return L["DandersMover is disabled"] end,
    detail = function() return L["Moving frames needs it. Enable DandersMover in the AddOns list, then reload."] end,
}

-- 10. Missing textures (Core.lua's safe texture setters, via DF:GetMissingTextures).
Attention:Register{
    id = "missingTextures", severity = 3, dismiss = "session",
    check = function()
        local list = DF.GetMissingTextures and DF:GetMissingTextures()
        if not (list and #list > 0) then return false end
        return true, #list
    end,
    title = function() return L["Missing textures"] end,
    detail = function(n)
        return format(L["%d texture files couldn't be found, so a stock texture is shown instead. Reinstall or re-enable the addon that provides them."], n or 0)
    end,
}
