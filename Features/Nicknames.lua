local addonName, DF = ...

-- ============================================================
-- NICKNAMES
-- Replaces the displayed name on party/raid frames based on a
-- prioritised list of rules. The on-screen name flows through the
-- single DF:GetUnitName hook (see Frames/Core.lua + Frames/Bars.lua),
-- so teaching that one function to return a nickname is all it takes
-- to make nicknames appear everywhere the addon draws a name.
--
-- Features: account-wide storage; matching (exact + wildcard +
-- diacritic-normalised); the display hook; conflict/overlap analysis;
-- source pickers (group/guild/friends/B.net); an optional nickname marker;
-- and sharing (broadcast/accept, in Features/NicknamesComm.lua).
-- ============================================================

local pairs, ipairs, type = pairs, ipairs, type
local tinsert, tremove = table.insert, table.remove
local strfind, strsub, strlower, gsub = string.find, string.sub, string.lower, string.gsub
local strmatch = string.match
local wipe = wipe
local UnitName = UnitName
local UnitGUID = UnitGUID
local UNKNOWNOBJECT = UNKNOWNOBJECT
-- A unit's GUID can be a SECRET value in 12.0 (e.g. M+ encounters) and a secret
-- cannot be used as a table key. The resolve cache is keyed by GUID, so guard
-- it: an inaccessible GUID skips the cache (recompute fresh) instead of crashing.
local issecretvalue = issecretvalue or function() return false end

DF.Nicknames = DF.Nicknames or {}
local NK = DF.Nicknames

NK.initialized = false

-- ============================================================
-- DIACRITIC NORMALISATION
-- WoW already enforces title-case for names, so case isn't the
-- concern — accents are. We strip diacritics so a plain-letter
-- pattern (mael*) matches both "Maelareth" and "Maëlareth".
-- Keys are the UTF-8 byte sequences of the accented characters.
-- A user who wants strict accent matching just types the accent
-- into their pattern (it normalises to itself only if absent here,
-- but since we strip on BOTH sides, "maël" still works for them).
-- ============================================================

local DIACRITICS = {
    ["à"]="a",["á"]="a",["â"]="a",["ã"]="a",["ä"]="a",["å"]="a",["æ"]="ae",
    ["ç"]="c",
    ["è"]="e",["é"]="e",["ê"]="e",["ë"]="e",
    ["ì"]="i",["í"]="i",["î"]="i",["ï"]="i",
    ["ñ"]="n",
    ["ò"]="o",["ó"]="o",["ô"]="o",["õ"]="o",["ö"]="o",["ø"]="o",["œ"]="oe",
    ["ù"]="u",["ú"]="u",["û"]="u",["ü"]="u",
    ["ý"]="y",["ÿ"]="y",
    ["ß"]="ss",
    -- Uppercase forms (covered after we lowercase, but kept for safety
    -- if normalisation order ever changes):
    ["À"]="a",["Á"]="a",["Â"]="a",["Ã"]="a",["Ä"]="a",["Å"]="a",["Æ"]="ae",
    ["Ç"]="c",
    ["È"]="e",["É"]="e",["Ê"]="e",["Ë"]="e",
    ["Ì"]="i",["Í"]="i",["Î"]="i",["Ï"]="i",
    ["Ñ"]="n",
    ["Ò"]="o",["Ó"]="o",["Ô"]="o",["Õ"]="o",["Ö"]="o",["Ø"]="o",["Œ"]="oe",
    ["Ù"]="u",["Ú"]="u",["Û"]="u",["Ü"]="u",
    ["Ý"]="y",
}

-- Lowercase + strip accents. Returns "" for nil/empty input.
function NK:Normalize(str)
    if not str or str == "" then return "" end
    str = strlower(str)
    -- Fast path: plain-ASCII names (the common case) have no accents to strip,
    -- so skip the diacritic table entirely. Accented UTF-8 bytes are >= 0x80.
    if not strfind(str, "[\128-\255]") then return str end
    -- Replace each known accented UTF-8 sequence with its base letter.
    for accented, base in pairs(DIACRITICS) do
        str = gsub(str, accented, base)
    end
    return str
end

-- ============================================================
-- STORAGE
-- Account-wide so a nickname follows you across every character
-- and every DandersFrames profile. Lives in the global bucket
-- (DandersFramesDB_v2.global) which is seeded in Core.lua and
-- persists through profile switches.
-- ============================================================

-- Returns the nicknames table { enabled = bool, entries = {...} },
-- creating it on first access. Returns nil only if saved vars aren't
-- loaded yet (shouldn't happen after ADDON_LOADED).
function NK:GetDB()
    if not DandersFramesDB_v2 then return nil end
    DandersFramesDB_v2.global = DandersFramesDB_v2.global or {}
    local g = DandersFramesDB_v2.global
    if not g.nicknames then
        g.nicknames = { enabled = true, entries = {} }
    end
    -- Phase 4 sharing/sync settings (backfilled so older saved-vars upgrade).
    local nk = g.nicknames
    if nk.selfNick   == nil then nk.selfNick   = "" end      -- your broadcast nickname
    if nk.shareVia   == nil then nk.shareVia   = "off" end   -- off | raid | guild | both
    if nk.acceptFrom == nil then nk.acceptFrom = "off" end   -- off | raid | guild | both
    if nk.autoSync   == nil then nk.autoSync   = true end     -- auto-broadcast on group join
    if nk.bracket    == nil then nk.bracket    = "off" end    -- legacy mark-scope (migrated below)
    if nk.markStyle  == nil then nk.markStyle  = "brackets" end -- decoration style
    if nk.markEnabled == nil then nk.markEnabled = (nk.bracket ~= "off") end  -- marker on/off toggle
    if nk.markScope  == nil then nk.markScope = (nk.bracket == "received") and "received" or "all" end  -- all | mine | received
    if nk.rejected   == nil then nk.rejected   = {} end       -- [normName] = true (blocked senders)
    -- Source-picker favourites (pin certain people to the top of the pickers).
    -- chars keyed by normalised "name-realm"; bnet keyed by stable BattleTag.
    if nk.favorites  == nil then nk.favorites  = { chars = {}, bnet = {} } end
    nk.favorites.chars = nk.favorites.chars or {}
    nk.favorites.bnet  = nk.favorites.bnet or {}
    return nk
end

-- ============================================================
-- NICKNAME MARKER DECORATION
-- Wraps a displayed nickname per the chosen style so it's visibly a nickname.
-- ASCII-only (the addon font lacks many fancy glyphs). "||" renders as a
-- single literal "|" in WoW FontStrings.
-- ============================================================
local NK_MARK_STYLES = {
    brackets = { "[", "]" },
    parens   = { "(", ")" },
    angle    = { "<", ">" },
    asterisk = { "",  "*" },
    pipe     = { "",  "||" },
}
local function decorateNick(nick, style)
    local s = NK_MARK_STYLES[style] or NK_MARK_STYLES.brackets
    return s[1] .. nick .. s[2]
end

-- ============================================================
-- MATCHING ENGINE
-- Each entry is one rule. The entries array IS the priority order:
-- index 1 is highest priority, and the first matching rule wins.
-- ============================================================

-- True if `hay` starts with `needle`.
local function startsWith(hay, needle)
    return strsub(hay, 1, #needle) == needle
end

-- True if `hay` ends with `needle`.
local function endsWith(hay, needle)
    return needle == "" or strsub(hay, -#needle) == needle
end

-- Does a single entry match the given (already-normalised) name/realm?
function NK:EntryMatches(entry, normName, normRealm, normFull)
    -- B.net rule: the unit matches if its current character is mapped to this
    -- rule's account in the live map (rebuilt from B.net friend info).
    if entry.kind == "bnet" then
        local map = NK.bnetNameMap
        if not map then return false end
        local tag = (normFull and map[normFull]) or map[normName]
        return tag ~= nil and tag == entry.battleTag
    end

    -- Optional realm gate: if the rule names a realm, it must match.
    if entry.matchRealm and entry.matchRealm ~= "" then
        if normRealm ~= entry.matchRealm then return false end
    end

    local core = entry.matchName or ""
    if entry.kind == "wildcard" then
        if entry.wild == "prefix" then
            return startsWith(normName, core)
        elseif entry.wild == "suffix" then
            return endsWith(normName, core)
        else -- "contains"
            return strfind(normName, core, 1, true) ~= nil
        end
    else -- "exact"
        return normName == core
    end
end

-- Resolve a unit to a nickname string, or nil if no rule matches.
-- This is what the display hook calls.
function NK:Resolve(unit)
    local data = NK:GetDB()
    if not data or not data.enabled then return nil end

    local hasCurated = data.entries and #data.entries > 0
    local hasReceived = NK.received and next(NK.received) ~= nil
    if not hasCurated and not hasReceived then return nil end

    -- Per-GUID resolve cache: skips re-normalising + re-scanning on every name
    -- refresh for a unit we already resolved. Wiped wholesale in
    -- RefreshAllFrames (the funnel for every change), so it can't go stale.
    -- The GUID can be a SECRET value (M+) that can't be used as a table key —
    -- in that case skip the cache entirely (recompute fresh) rather than crash.
    local cache = NK._resolveCache
    if not cache then cache = {}; NK._resolveCache = cache end
    local guid = UnitGUID(unit)
    local cacheKey = (guid and not issecretvalue(guid)) and guid or nil
    if cacheKey then
        local hit = cache[cacheKey]
        if hit ~= nil then return hit or nil end   -- `false` = cached "no match"
    end

    local name, realm = UnitName(unit)
    -- Boss/arena units can return a SECRET name during encounters. It can't be
    -- compared, normalised, or used as a match key — bail (don't cache) rather
    -- than crash on the `==` below, same as the secret-GUID guard above.
    if name and issecretvalue(name) then return nil end
    if not name or name == "" then return nil end  -- transient; don't cache
    -- Name not resolved yet (UNKNOWNOBJECT during zone-in/reload): treat as
    -- transient and DON'T cache, or we'd cache a "no match" that sticks until
    -- the next wholesale wipe and the real nickname would never appear.
    if name == UNKNOWNOBJECT then return nil end
    -- UnitName returns "" / nil realm for same-realm units; fill in the
    -- player's own realm so "Name-MyRealm" rules still match them. A secret
    -- realm (same encounter masking as the name) also can't be compared, so
    -- treat it like an empty realm — issecretvalue short-circuits before `==`.
    if not realm or issecretvalue(realm) or realm == "" then
        realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or ""
    end

    local normName = NK:Normalize(name)
    local normRealm = NK:Normalize(realm)
    local normFull = (realm ~= "") and NK:Normalize(name .. "-" .. realm) or normName

    local marking = data.markEnabled
    local scope = data.markScope or "all"

    local result = nil
    -- Your curated rules win (priority order).
    if hasCurated then
        for _, entry in ipairs(data.entries) do
            if NK:EntryMatches(entry, normName, normRealm, normFull) then
                local nick = entry.nickname
                if marking and (scope == "all" or scope == "mine") then
                    result = decorateNick(nick, data.markStyle)
                else
                    result = nick
                end
                break
            end
        end
    end
    -- Fallback: a nickname someone shared with us (lowest priority).
    if not result and hasReceived then
        local rec = NK:GetReceived(normFull, normName)
        if rec then
            if marking and (scope == "all" or scope == "received") then
                result = decorateNick(rec, data.markStyle)
            else
                result = rec
            end
        end
    end

    if cacheKey then cache[cacheKey] = result or false end
    return result
end

-- ============================================================
-- CONFLICT / OVERLAP ANALYSIS
-- "covers": rule B matches every name rule A matches (B's set superset
--   of A's). If B is higher priority, A can never win -> A is shadowed.
-- "intersects": the two rules can both match at least one common name.
-- Used by the GUI to flag priority conflicts and overlaps.
-- ============================================================

-- Effective kind string for comparisons: "exact" / "prefix" / "suffix" / "contains".
local function effKind(e)
    if e.kind == "wildcard" then return e.wild end
    return "exact"
end

-- Could these two rules ever apply to the same realm?
local function realmCompatible(a, b)
    if a.matchRealm and a.matchRealm ~= "" and b.matchRealm and b.matchRealm ~= "" then
        return a.matchRealm == b.matchRealm
    end
    return true
end

-- Does B's match-set contain A's match-set?  (B superset of A)
local function covers(b, a)
    -- B.net rules match by account, not name — exclude from name-based analysis.
    if a.kind == "bnet" or b.kind == "bnet" then return false end
    -- A realm-restricted B can only cover A if A is restricted to the same
    -- realm (else A also matches other realms that B never will).
    if b.matchRealm and b.matchRealm ~= "" then
        if a.matchRealm ~= b.matchRealm then return false end
    end
    local bk, bc = effKind(b), b.matchName or ""
    local ak, ac = effKind(a), a.matchName or ""

    if bk == "exact" then
        return ak == "exact" and ac == bc
    elseif bk == "prefix" then
        if ak == "exact" or ak == "prefix" then return startsWith(ac, bc) end
        return false
    elseif bk == "suffix" then
        if ak == "exact" or ak == "suffix" then return endsWith(ac, bc) end
        return false
    else -- bk == "contains": every A-match contains bc iff A's core contains bc
        return strfind(ac, bc, 1, true) ~= nil
    end
end

-- Can A and B both match at least one common name?
local function intersects(a, b)
    if a.kind == "bnet" or b.kind == "bnet" then return false end
    if not realmCompatible(a, b) then return false end
    local ak, ac = effKind(a), a.matchName or ""
    local bk, bc = effKind(b), b.matchName or ""

    local function matchOne(kind, core, s)
        if kind == "exact" then return s == core
        elseif kind == "prefix" then return startsWith(s, core)
        elseif kind == "suffix" then return endsWith(s, core)
        else return strfind(s, core, 1, true) ~= nil end
    end

    -- If either is exact, just test that literal against the other rule.
    if ak == "exact" then return matchOne(bk, bc, ac) end
    if bk == "exact" then return matchOne(ak, ac, bc) end

    if ak == "prefix" and bk == "prefix" then
        return startsWith(ac, bc) or startsWith(bc, ac)
    elseif ak == "suffix" and bk == "suffix" then
        return endsWith(ac, bc) or endsWith(bc, ac)
    end
    -- Mixed wildcard types (contains-with-anything, or prefix+suffix): only
    -- flag when one core is contained in the other. A purely "constructible"
    -- overlap -- e.g. mael* and *mer* share only contrived names like
    -- "Maelmer" -- is too noisy to be worth flagging.
    return strfind(ac, bc, 1, true) ~= nil or strfind(bc, ac, 1, true) ~= nil
end

-- Returns an array parallel to entries:
--   out[i] = { shadowedBy = j|nil, overlaps = { idx, ... } }
-- shadowedBy: the first HIGHER-priority rule (j < i) that fully covers i,
--   meaning rule i can never win. overlaps: other rules that intersect i
--   but give a DIFFERENT nickname (same-nickname overlaps are harmless).
function NK:AnalyzeConflicts()
    local data = NK:GetDB()
    local entries = (data and data.entries) or {}
    local n = #entries
    local out = {}
    for i = 1, n do out[i] = { overlaps = {} } end

    for i = 1, n do
        local a = entries[i]
        for j = 1, i - 1 do
            if covers(entries[j], a) then
                out[i].shadowedBy = j
                break
            end
        end
    end

    for i = 1, n do
        for j = i + 1, n do
            local a, b = entries[i], entries[j]
            if a.nickname ~= b.nickname and intersects(a, b) then
                tinsert(out[i].overlaps, j)
                tinsert(out[j].overlaps, i)
            end
        end
    end
    return out
end

-- ============================================================
-- DISPLAY HOOK
-- Wrap DF:GetUnitName so it returns the nickname when a rule
-- matches, falling back to whatever was there before (the default
-- implementation, or an external addon's override). Chaining like
-- this keeps us a good citizen in the addon ecosystem.
-- ============================================================

function NK:InstallHook()
    if NK._hookInstalled then return end
    NK._hookInstalled = true

    local previous = DF.GetUnitName  -- default impl from Frames/Core.lua
    DF.GetUnitName = function(selfDF, unit)
        local nick = NK:Resolve(unit)
        if nick then return nick end
        if previous then return previous(selfDF, unit) end
        return UnitName(unit) or unit
    end
end

-- Force every visible frame to re-read its name. Call after any edit.
-- Names can be drawn by two systems, so we nudge both:
--   * legacy nameText  -> DF:UpdateName
--   * Text Designer    -> DF:UpdateTextDesigner (re-renders via the Live
--     data source, whose GetName() calls our hooked DF:GetUnitName)
-- Whichever one is active on the user's build, the nickname shows.
function NK:RefreshAllFrames()
    -- Invalidate the per-GUID resolve cache: this function is the single funnel
    -- for every rule / roster / received / marker change, so wiping here keeps
    -- the cache from ever going stale.
    if NK._resolveCache then wipe(NK._resolveCache) end
    if DF.IterateCompactFrames then
        DF:IterateCompactFrames(function(frame)
            if DF.UpdateName then DF:UpdateName(frame) end
            if DF.UpdateTextDesigner then DF:UpdateTextDesigner(frame) end
        end)
    end
    -- Notify any UI listener (e.g. the options panel) so it stays in sync no
    -- matter where the change came from (GUI, sharing, ...).
    if NK.onChange then NK.onChange() end
end

-- Coalesce a burst of refreshes (e.g. many incoming nicknames when a group
-- forms) into a single frame redraw shortly after the activity settles.
function NK:ScheduleRefresh()
    NK._refreshToken = (NK._refreshToken or 0) + 1
    local token = NK._refreshToken
    C_Timer.After(0.2, function()
        -- Only the last call in a burst matches the token, so the redraw runs once.
        if NK._refreshToken == token then
            NK:RefreshAllFrames()
        end
    end)
end

-- ============================================================
-- ENTRY HELPERS (used by the GUI add/edit flow)
-- ============================================================

-- Build an exact-name entry table (no insert). `nameInput` may include
-- a realm as "Name-Realm".
local function buildExact(nameInput, nickname, source)
    local namePart, realmPart = strmatch(nameInput, "^([^%-]+)%-(.+)$")
    namePart = namePart or nameInput
    return {
        kind = "exact",
        pattern = nameInput,
        matchName = NK:Normalize(namePart),
        realm = realmPart,
        matchRealm = realmPart and NK:Normalize(realmPart) or nil,
        nickname = nickname,
        source = source or "Manual",
    }
end

-- Build an entry with an EXPLICIT match type (no '*' parsing). Used by the
-- GUI match-type dropdown so intent is unambiguous.
-- matchType: "exact" | "prefix" | "suffix" | "contains".
function NK:BuildTyped(matchType, text, nickname, source)
    if not text or text == "" or not nickname or nickname == "" then return nil end
    if matchType == "exact" or not matchType then
        return buildExact(text, nickname, source)
    end
    local core = gsub(text, "%*", "")  -- ignore any stray asterisks
    if core == "" then return nil end
    return {
        kind = "wildcard",
        wild = matchType,
        pattern = core,
        matchName = NK:Normalize(core),
        nickname = nickname,
        source = source or "Wildcard",
    }
end

function NK:AddTyped(matchType, text, nickname, source)
    local data = NK:GetDB()
    if not data then return nil end
    local entry = NK:BuildTyped(matchType, text, nickname, source)
    if not entry then return nil end
    tinsert(data.entries, entry)
    NK:RefreshAllFrames()
    return entry
end

function NK:SetEntryTyped(index, matchType, text, nickname, source)
    local data = NK:GetDB()
    if not data or not data.entries[index] then return false end
    local entry = NK:BuildTyped(matchType, text, nickname, source or data.entries[index].source)
    if not entry then return false end
    data.entries[index] = entry
    NK:RefreshAllFrames()
    return true
end

function NK:RemoveAt(index)
    local data = NK:GetDB()
    if not data or not data.entries[index] then return false end
    tremove(data.entries, index)
    NK:RefreshAllFrames()
    return true
end

-- Move the rule at `from` to position `to` (reordering = changing priority,
-- since the list IS the priority order). Used by drag-to-reorder.
function NK:MoveEntry(from, to)
    local data = NK:GetDB()
    if not data then return false end
    local n = #data.entries
    if not from or from < 1 or from > n then return false end
    to = math.max(1, math.min(to or n, n))
    if to == from then return false end
    local e = tremove(data.entries, from)
    tinsert(data.entries, to, e)
    NK:RefreshAllFrames()
    return true
end

function NK:Clear()
    local data = NK:GetDB()
    if not data then return end
    wipe(data.entries)
    NK:RefreshAllFrames()
end

-- ============================================================
-- SOURCE ENUMERATORS  (Phase 2 — feed the "Add from..." pickers)
-- Each returns an array of candidates:
--   { name=, realm=, fullName="Name-Realm", class=<token|nil>, online=bool }
-- Pure data; the picker UI lives in Options/NicknamesPicker.lua.
-- These social rosters are out-of-combat APIs, unaffected by Midnight's
-- Secret Values restrictions.
-- ============================================================

local function pushCandidate(out, name, realm, class, online)
    if not name or name == "" then return end
    if not realm or realm == "" then
        realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or ""
    end
    local full = (realm ~= "") and (name .. "-" .. realm) or name
    tinsert(out, { name = name, realm = realm, fullName = full, class = class, online = online })
end

-- Current party/raid (includes the player). Solo returns just the player.
function NK:GetGroupCandidates()
    local out = {}
    local n = GetNumGroupMembers() or 0
    if n == 0 then
        local name, realm = UnitName("player")
        local _, class = UnitClass("player")
        pushCandidate(out, name, realm, class, true)
        return out
    end
    local isRaid = IsInRaid()
    for i = 1, n do
        local unit = isRaid and ("raid" .. i) or (i == 1 and "player" or "party" .. (i - 1))
        local name, realm = UnitName(unit)
        local _, class = UnitClass(unit)
        pushCandidate(out, name, realm, class, UnitIsConnected(unit))
    end
    return out
end

-- Guild roster.
function NK:GetGuildCandidates()
    local out = {}
    if not IsInGuild() then return out end
    -- Ask the server to refresh (async); cached data is usually ready on reopen.
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
    local n = GetNumGuildMembers() or 0
    for i = 1, n do
        local fullName, _, _, _, _, _, _, _, online, _, classToken = GetGuildRosterInfo(i)
        if fullName then
            local name, realm = strsplit("-", fullName)
            pushCandidate(out, name, realm, classToken, online)
        end
    end
    return out
end

-- In-game friends.
function NK:GetFriendCandidates()
    local out = {}
    if not (C_FriendList and C_FriendList.GetNumFriends) then return out end
    if C_FriendList.ShowFriends then C_FriendList.ShowFriends() end
    local n = C_FriendList.GetNumFriends() or 0
    for i = 1, n do
        local info = C_FriendList.GetFriendInfoByIndex(i)
        if info and info.name then
            local name, realm = strsplit("-", info.name)
            -- FriendInfo gives a localised class name, not a token, so class
            -- stays nil (neutral colour) for now.
            pushCandidate(out, name, realm, nil, info.connected)
        end
    end
    return out
end

-- True if an EXACT rule already covers this character (marks a picker
-- candidate as "already added").
function NK:HasRuleFor(name, realm)
    local data = NK:GetDB()
    if not data then return false end
    local nN = NK:Normalize(name)
    local nR = realm and NK:Normalize(realm) or nil
    for _, e in ipairs(data.entries) do
        if e.kind == "exact" and e.matchName == nN then
            if not e.matchRealm or not nR or e.matchRealm == nR then
                return true
            end
        end
    end
    return false
end

-- B.net friends (account-based). Returns:
--   { bnetID=, label=, battleTag=, currentChar="Name-Realm"|nil, online=bool }
-- currentChar is the friend's active WoW character if the API reports it.
function NK:GetBnetCandidates()
    local out = {}
    if not (BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendAccountInfo) then
        return out
    end
    local total = BNGetNumFriends() or 0
    for i = 1, total do
        local acc = C_BattleNet.GetFriendAccountInfo(i)
        if acc and acc.bnetAccountID then
            -- NOTE: acc.accountName is a session-scoped |K...|k Battle.net name
            -- token (it renders as a DIFFERENT friend after a relog), so it must
            -- never be persisted. The BattleTag's name part is stable and reads
            -- the same to the user.
            local label = (acc.battleTag and acc.battleTag:match("^([^#]+)"))
                or acc.battleTag or ("BNet " .. i)
            local currentChar, online
            local ng = (C_BattleNet.GetFriendNumGameAccounts and C_BattleNet.GetFriendNumGameAccounts(i)) or 0
            for g = 1, ng do
                local ga = C_BattleNet.GetFriendGameAccountInfo(i, g)
                if ga and ga.clientProgram == "WoW" and ga.characterName then
                    currentChar = ga.characterName .. (ga.realmName and ("-" .. ga.realmName) or "")
                    online = true
                    break
                end
            end
            tinsert(out, {
                bnetID = acc.bnetAccountID,
                label = label,
                battleTag = acc.battleTag,
                currentChar = currentChar,
                online = online,
            })
        end
    end
    return out
end

-- ============================================================
-- SOURCE-PICKER FAVOURITES
-- Pin chosen people to the top of the "Add from" pickers. Stored account-wide
-- in GetDB().favorites: characters keyed by normalised "name-realm", B.net
-- friends by stable BattleTag. Group/guild/friend candidates may lack a realm
-- (same-realm members), so we backfill the player's realm for a stable key.
-- ============================================================

-- Returns (bucket, key) for a candidate, or nil if it can't be favourited
-- (e.g. a B.net friend with no BattleTag).
function NK:FavoriteKey(c, isBnet)
    local data = NK:GetDB()
    if not data or not c then return nil end
    if isBnet then
        if c.battleTag and c.battleTag ~= "" then return data.favorites.bnet, c.battleTag end
        return nil
    end
    local full = c.fullName
    if not full or full == "" then return nil end
    if not strfind(full, "-", 1, true) then
        local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or ""
        if realm ~= "" then full = full .. "-" .. realm end
    end
    return data.favorites.chars, NK:Normalize(full)
end

function NK:IsFavorite(c, isBnet)
    local bucket, key = NK:FavoriteKey(c, isBnet)
    return (bucket and key and bucket[key]) and true or false
end

-- Toggle a candidate's favourite state. Returns true if it changed.
function NK:ToggleFavorite(c, isBnet)
    local bucket, key = NK:FavoriteKey(c, isBnet)
    if not bucket or not key then return false end
    if bucket[key] then bucket[key] = nil else bucket[key] = true end
    return true
end

-- ============================================================
-- B.NET RULES (account-based; "follows the friend across characters")
-- A rule stores the friend's BattleTag, which is STABLE across sessions. (The
-- older bnetAccountID is documented as session-only and must NOT be persisted.)
-- We keep a live map of each nicknamed friend's CURRENT WoW character name ->
-- their BattleTag, rebuilt whenever B.net/roster info changes; EntryMatches
-- consults it.
-- ============================================================

NK.bnetNameMap = NK.bnetNameMap or {}

function NK:HasBnetRule(battleTag)
    local data = NK:GetDB()
    if not data or not battleTag then return false end
    for _, e in ipairs(data.entries) do
        if e.kind == "bnet" and e.battleTag == battleTag then return true end
    end
    return false
end

-- Add a B.net rule. `battleTag` is the stable key; `label` is a display string.
function NK:AddBnet(battleTag, label, nickname)
    local data = NK:GetDB()
    if not data or not battleTag or battleTag == "" or not nickname or nickname == "" then return nil end
    local entry = {
        kind = "bnet",
        battleTag = battleTag,
        -- Display label MUST be stable across sessions — derive it from the
        -- BattleTag, never from the caller's (possibly tokenised) label.
        pattern = strmatch(battleTag, "^([^#]+)") or battleTag,
        nickname = nickname,
        source = "B.net",
    }
    tinsert(data.entries, entry)
    NK:RebuildBnetMap()
    NK:RefreshAllFrames()
    return entry
end

-- Update only the nickname of the rule at `index` (used when editing a B.net
-- rule, whose "character" isn't an editable field).
function NK:SetNickname(index, nickname)
    local data = NK:GetDB()
    local e = data and data.entries[index]
    if not e or not nickname or nickname == "" then return false end
    e.nickname = nickname
    NK:RebuildBnetMap()
    NK:RefreshAllFrames()
    return true
end

-- Repair B.net rule display labels that were saved as a session-scoped
-- |K...|k account-name token (which renders as a different friend each login).
-- The BattleTag is stable, so re-derive the label from it. Cheap + idempotent.
function NK:RepairBnetLabels()
    local data = NK:GetDB()
    if not data then return end
    for _, e in ipairs(data.entries) do
        if e.kind == "bnet" and e.battleTag then
            if not e.pattern or e.pattern == "" or strfind(e.pattern, "|K", 1, true) then
                e.pattern = strmatch(e.battleTag, "^([^#]+)") or e.battleTag
            end
        end
    end
end

-- One-time migration of legacy B.net rules that stored the session-only
-- bnetAccountID instead of a stable BattleTag. For each such rule we try to
-- recover the BattleTag from the current friend list: first via the still-valid
-- session id (only works if the rule was made this session), then by matching
-- the stored display label against an account name or BattleTag. Anything we
-- cannot resolve is flagged (needsRelink) so the UI can prompt a re-add rather
-- than silently dropping it. Runs only when the friend list is populated.
function NK:MigrateBnetEntries(data, total)
    local byId, byName, byTag = {}, {}, {}
    for i = 1, total do
        local acc = C_BattleNet.GetFriendAccountInfo(i)
        if acc and acc.battleTag then
            if acc.bnetAccountID then byId[acc.bnetAccountID] = acc.battleTag end
            byTag[acc.battleTag] = acc.battleTag
            if acc.accountName and acc.accountName ~= "" then
                -- nil = unseen, a tag = unique match, false = ambiguous (seen 2+)
                if byName[acc.accountName] == nil then
                    byName[acc.accountName] = acc.battleTag
                else
                    byName[acc.accountName] = false
                end
            end
        end
    end

    for _, e in ipairs(data.entries) do
        if e.kind == "bnet" and not e.battleTag then
            local tag
            if e.bnetID and byId[e.bnetID] then
                tag = byId[e.bnetID]
            elseif e.pattern and not strfind(e.pattern, "|K", 1, true) then
                -- A |K...|k token pattern is session-scoped and would mis-match a
                -- different friend, so only match plain BattleTag/account labels.
                if byTag[e.pattern] then
                    tag = e.pattern
                elseif byName[e.pattern] then         -- false (ambiguous) leaves tag nil
                    tag = byName[e.pattern]
                end
            end
            if tag then
                e.battleTag = tag
                e.bnetID = nil
                e.needsRelink = nil
                -- Refresh the display label from the now-stable BattleTag so a
                -- rule migrated mid-session doesn't keep a stale token label
                -- until the next reload (RepairBnetLabels only runs at login).
                e.pattern = strmatch(tag, "^([^#]+)") or tag
            else
                e.needsRelink = true
            end
        end
    end
end

-- Rebuild the live "current character -> BattleTag" map from B.net friends who
-- have a rule. Cheap no-op when there are no B.net rules.
function NK:RebuildBnetMap()
    NK.bnetNameMap = NK.bnetNameMap or {}
    wipe(NK.bnetNameMap)
    local data = NK:GetDB()
    if not data then return end

    local anyBnet = false
    for _, e in ipairs(data.entries) do
        if e.kind == "bnet" then anyBnet = true break end
    end
    if not anyBnet then return end
    if not (BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendAccountInfo) then return end

    local total = BNGetNumFriends() or 0
    -- Recover BattleTags for any legacy rules now that the friend list exists
    -- (only when something actually needs it — normally a no-op).
    if total > 0 then
        for _, e in ipairs(data.entries) do
            if e.kind == "bnet" and not e.battleTag then
                NK:MigrateBnetEntries(data, total)
                break
            end
        end
    end

    local wanted, any = {}, false
    for _, e in ipairs(data.entries) do
        if e.kind == "bnet" and e.battleTag then wanted[e.battleTag] = true; any = true end
    end
    if not any then return end

    for i = 1, total do
        local acc = C_BattleNet.GetFriendAccountInfo(i)
        if acc and acc.battleTag and wanted[acc.battleTag] then
            local ng = (C_BattleNet.GetFriendNumGameAccounts and C_BattleNet.GetFriendNumGameAccounts(i)) or 0
            for g = 1, ng do
                local ga = C_BattleNet.GetFriendGameAccountInfo(i, g)
                if ga and ga.clientProgram == "WoW" and ga.characterName then
                    if ga.realmName and ga.realmName ~= "" then
                        NK.bnetNameMap[NK:Normalize(ga.characterName .. "-" .. ga.realmName)] = acc.battleTag
                    end
                    NK.bnetNameMap[NK:Normalize(ga.characterName)] = acc.battleTag
                end
            end
        end
    end
end

-- Debounced rebuild + frame refresh, fired by B.net / roster events.
function NK:ScheduleBnetRebuild()
    if NK._bnetRebuildPending then return end
    NK._bnetRebuildPending = true
    C_Timer.After(1, function()
        NK._bnetRebuildPending = false
        local data = NK:GetDB()
        local hasBnet = false
        if data then
            for _, e in ipairs(data.entries) do
                if e.kind == "bnet" then hasBnet = true break end
            end
        end
        if not hasBnet then return end
        NK:RebuildBnetMap()
        NK:RefreshAllFrames()
    end)
end

-- ============================================================
-- RECEIVED NICKNAMES (Phase 4 — shared to us by other users)
-- Kept SEPARATE from the curated list (NK.received, session-only) and used
-- only as a LOWEST-priority fallback in Resolve, so your own rules always
-- win. The comm layer (Features/NicknamesComm.lua) fills this from broadcasts.
-- ============================================================

NK.received = NK.received or {}  -- [normFull | normName] = { nick=, sender= }

-- Store a received nickname for a character. `fullName` is "Name-Realm" (the
-- sender reported by the addon message, or an explicit name when simulating).
-- Incoming-nickname sanitiser. Used for received broadcasts AND plain imports.
-- Returns a cleaned nickname, or nil to reject. Blizzard's name/profanity
-- filters are NOT exposed to addons, so we sanitise ourselves. The important
-- guard is stripping UI escape codes (anti-injection); the bad-word list is a
-- small politeness layer (expand over time).
local NK_MAX_NICK_LEN = 32
local NK_BADWORDS = {
    -- compact starter list (lowercase substrings); expand as needed.
    "fuck", "shit", "cunt", "bitch", "nigger", "faggot", "retard",
}
-- Returns (cleanNick) on success, or (nil, reason) on rejection.
-- reason: "empty" | "escape" | "toolong" | "profanity".
function NK:FilterIncoming(nick)
    if type(nick) ~= "string" then return nil, "empty" end
    nick = nick:gsub("^%s+", ""):gsub("%s+$", "")           -- trim
    if nick == "" then return nil, "empty" end
    if strfind(nick, "|", 1, true) then return nil, "escape" end   -- UI escape codes (|c |H |T |r ...)
    if strfind(nick, "[%z\1-\31]") then return nil, "escape" end    -- control bytes / newlines
    local len = (DF.UTF8Len and DF:UTF8Len(nick)) or #nick
    if len > NK_MAX_NICK_LEN then return nil, "toolong" end
    -- Whole-word match only (avoids the "Scunthorpe problem", where a clean
    -- word contains a banned substring). Fold accents via Normalize, then split
    -- on non-letters so "cunt", "you cunt", and "cunt123" are caught, but
    -- "Scunthorpe" / "class" / "Penistone" are not.
    local folded = NK:Normalize(nick)
    for token in folded:gmatch("%a+") do
        for _, w in ipairs(NK_BADWORDS) do
            if token == w then return nil, "profanity" end
        end
    end
    return nick
end

-- Sanitise a raw incoming nickname for SAFE DISPLAY (it may contain the very
-- escape codes we reject): escape pipes so they render literally, drop control
-- bytes, cap length.
local function displaySafe(s)
    s = (type(s) == "string" and s or "?"):gsub("|", "||"):gsub("[%z\1-\31]", "?")
    if #s > 40 then s = s:sub(1, 40) .. "..." end
    return s
end

-- Store a received nickname. Rather than silently dropping a rejected one, we
-- keep it in the Received list FLAGGED as blocked (with a reason) so the user
-- can see what came in and catch false positives. Blocked entries never
-- display on frames (GetReceived skips them).
function NK:AddReceived(fullName, nick, sender)
    if not fullName or fullName == "" then return end
    sender = sender or fullName

    local clean, reason = NK:FilterIncoming(nick)
    local entry
    if clean then
        local data = NK:GetDB()
        local userBlocked = data and data.rejected and data.rejected[NK:Normalize(sender)] or false
        entry = { nick = clean, sender = sender,
                  blocked = userBlocked and true or false,
                  reason = userBlocked and "user" or nil }
    else
        entry = { nick = displaySafe(nick), sender = sender, blocked = true, reason = reason }
    end

    NK.received = NK.received or {}
    local name = strsplit("-", fullName)
    -- The full "name-realm" key is authoritative. The bare-name key is only a
    -- best-effort fallback for units whose realm is unknown; don't let it clobber
    -- a DIFFERENT sender's entry (two cross-realm players can share a first name).
    NK.received[NK:Normalize(fullName)] = entry
    if name and name ~= "" then
        local shortKey = NK:Normalize(name)
        local existing = NK.received[shortKey]
        if not existing or existing.sender == entry.sender then
            NK.received[shortKey] = entry
        end
    end
    -- Debounced: a group forming can deliver many of these at once.
    NK:ScheduleRefresh()
end

-- User block / unblock for a sender (persisted in `rejected`). Filter-blocked
-- entries stay blocked regardless; only user-blocks are reversible here.
function NK:BlockSender(sender)
    local data = NK:GetDB()
    if not data or not sender then return end
    data.rejected = data.rejected or {}
    local key = NK:Normalize(sender)
    data.rejected[key] = true
    for _, e in pairs(NK.received or {}) do
        if e.sender and NK:Normalize(e.sender) == key then
            e.blocked = true
            if not e.reason then e.reason = "user" end
        end
    end
    NK:RefreshAllFrames()
end

function NK:UnblockSender(sender)
    local data = NK:GetDB()
    if not data or not sender then return end
    local key = NK:Normalize(sender)
    if data.rejected then data.rejected[key] = nil end
    for _, e in pairs(NK.received or {}) do
        if e.sender and NK:Normalize(e.sender) == key and e.reason == "user" then
            e.blocked = false
            e.reason = nil
        end
    end
    NK:RefreshAllFrames()
end

function NK:ClearReceived()
    NK.received = {}
    NK:RefreshAllFrames()
end

-- Look up a received nickname by a unit's normalized full/short name.
function NK:GetReceived(normFull, normName)
    local r = NK.received
    if not r then return nil end
    local e = (normFull and r[normFull]) or r[normName]
    if e and not e.blocked then return e.nick end  -- blocked entries never display
    return nil
end

-- De-duplicated list of received entries for the UI: { {sender=, nick=}, ... }
-- (NK.received stores each entry under both full- and short-name keys, so we
-- dedupe by the shared entry table.)
function NK:GetReceivedList()
    local out, seen = {}, {}
    for _, e in pairs(NK.received or {}) do
        if e and not seen[e] then
            seen[e] = true
            tinsert(out, { sender = e.sender, nick = e.nick, blocked = e.blocked, reason = e.reason })
        end
    end
    return out
end

-- Drop all received entries from a given sender.
function NK:RemoveReceived(sender)
    if not NK.received or not sender then return end
    for k, e in pairs(NK.received) do
        if e.sender == sender then NK.received[k] = nil end
    end
    NK:RefreshAllFrames()
end

-- ============================================================
-- INIT  (called from Core.lua after PLAYER_LOGIN)
-- ============================================================

-- ============================================================
-- NSRT PRECEDENCE / CONFLICT PROMPT
-- Northern Sky Raid Tools can also be set to put nicknames on DandersFrames
-- frames; when its "DandersFrames" toggle is on it OVERWRITES DF:GetUnitName,
-- so the two would fight. We detect that, prompt the user once which should
-- win, and store the choice (framePrecedence) which DF:GetFrameName honours.
-- Entirely DF-side: we never modify NSRT, only READ its toggle.
-- The same choice can be changed later in the Nicknames options page.
-- ============================================================

-- True if NSRT is loaded AND configured to manage names on DandersFrames frames.
function NK:NSRTManagingNames()
    return (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("NorthernSkyRaidTools"))
        and NSRT and NSRT.Settings
        and NSRT.Settings["GlobalNickNames"]
        and NSRT.Settings["DandersFrames"]
        and true or false
end

-- Should DandersFrames' own nicknames win on our frames? Yes — unless the user
-- explicitly chose NSRT AND NSRT is actually managing names right now.
function NK:HasPrecedence()
    local data = NK:GetDB()
    if data and data.framePrecedence == "nsrt" and NK:NSRTManagingNames() then
        return false
    end
    return true
end

-- The name to display on our own frames, honouring precedence. When DF wins we
-- resolve our own nickname first; when the user has chosen NSRT we ask NSRT's
-- own resolver DIRECTLY (NSAPI:GetName) so its name shows, bypassing our hook
-- (which would otherwise keep returning the DF nickname).
function NK:GetDisplayName(unit)
    if NK:HasPrecedence() then
        local nick = NK:Resolve(unit)
        if nick then return nick end
        return DF:GetUnitName(unit)
    end
    local raw = UnitName(unit)
    if NSAPI and NSAPI.GetName and raw then
        return NSAPI:GetName(raw, "DandersFrames") or raw
    end
    return raw or unit
end

-- Build + show the one-time conflict popup (DandersFrames' own alert style).
function NK:ShowConflictPopup()
    if NK._conflictPopup then NK._conflictPopup:Show(); return end

    local L = DF.L
    local theme = (DF.GUI and DF.GUI.GetThemeColor and DF.GUI.GetThemeColor())
        or { r = 0.9, g = 0.55, b = 0.15 }

    local popup = CreateFrame("Frame", "DFNicknameConflictPopup", UIParent, "BackdropTemplate")
    popup:SetSize(490, 250)
    popup:SetPoint("CENTER")
    popup:SetFrameStrata("FULLSCREEN_DIALOG")
    popup:SetFrameLevel(200)
    DF.GUI:CreatePanelBackdrop(popup, { bgAlpha = 0.98, borderColor = { theme.r, theme.g, theme.b, 1 } })
    popup:EnableMouse(true)
    popup:SetMovable(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", popup.StartMoving)
    popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
    tinsert(UISpecialFrames, "DFNicknameConflictPopup")  -- Esc closes (re-prompts next login)

    local title = popup:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText(L["Addon nicknames conflict"])
    title:SetTextColor(1, 0.3, 0.3)

    local warnTex = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\warning"
    local lw = popup:CreateTexture(nil, "OVERLAY"); lw:SetSize(18, 18)
    lw:SetPoint("RIGHT", title, "LEFT", -8, 0); lw:SetTexture(warnTex); lw:SetVertexColor(1, 0.3, 0.3)
    local rw = popup:CreateTexture(nil, "OVERLAY"); rw:SetSize(18, 18)
    rw:SetPoint("LEFT", title, "RIGHT", 8, 0); rw:SetTexture(warnTex); rw:SetVertexColor(1, 0.3, 0.3)

    local msg = popup:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
    msg:SetPoint("TOP", title, "BOTTOM", 0, -16)
    msg:SetPoint("LEFT", 28, 0); msg:SetPoint("RIGHT", -28, 0); msg:SetJustifyH("CENTER")
    msg:SetText(L["Both %s and %s are set to show nicknames on your frames.\n\nWhich one should decide the names shown here?"]
        :format("|cffe68c26DandersFrames|r", "|cff6fb1e0Northern Sky Raid Tools|r"))

    local sub = popup:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    sub:SetPoint("TOP", msg, "BOTTOM", 0, -12)
    sub:SetPoint("LEFT", 28, 0); sub:SetPoint("RIGHT", -28, 0); sub:SetJustifyH("CENTER")
    sub:SetText(L["This only changes who controls names on DandersFrames frames - you can change it later in Nicknames settings."])
    sub:SetTextColor(0.7, 0.7, 0.7)

    local function choose(pref)
        local d = NK:GetDB(); if d then d.framePrecedence = pref end
        popup:Hide()
        NK:RefreshAllFrames()
    end

    local function makeButton(text, primary, onClick)
        local b = CreateFrame("Button", nil, popup, "BackdropTemplate")
        -- Word-wrapped label kept manual; StyleButton handles fill/border/hover.
        if primary then
            DF.GUI:StyleButton(b, { width = 225, height = 42, primary = true })
        else
            DF.GUI:StyleButton(b, { width = 225, height = 42 })
        end
        local t = b:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        t:SetPoint("LEFT", 6, 0); t:SetPoint("RIGHT", -6, 0); t:SetJustifyH("CENTER")
        t:SetWordWrap(true); t:SetText(text); t:SetTextColor(1, 1, 1)
        b:SetScript("OnClick", onClick)
        return b
    end

    local dfBtn = makeButton(L["Use %s nicknames"]:format("DandersFrames"), true, function() choose("self") end)
    dfBtn:SetPoint("BOTTOM", -118, 16)
    local nsBtn = makeButton(L["Use %s nicknames"]:format("Northern Sky Raid Tools"), false, function() choose("nsrt") end)
    nsBtn:SetPoint("BOTTOM", 118, 16)

    NK._conflictPopup = popup
    popup:Show()
end

-- Prompt once if there's an unresolved DF/NSRT name conflict. Defers out of combat.
function NK:CheckConflictPrompt()
    local data = NK:GetDB()
    if not data or not data.enabled then return end
    if data.framePrecedence ~= nil then return end   -- already decided
    -- Only prompt users who actually USE DF nicknames (enabled defaults true,
    -- so without this every NSRT user would get the popup with nothing to
    -- choose between). Once they add a first nickname, the conflict is real
    -- and the popup appears at next login (framePrecedence is still nil).
    local hasAny = (data.entries and #data.entries > 0)
        or (NK.received and next(NK.received) ~= nil)
        or (data.selfNick and data.selfNick ~= "")
    if not hasAny then return end
    if not NK:NSRTManagingNames() then return end     -- no conflict
    if InCombatLockdown and InCombatLockdown() then
        if not NK._conflictCombatWatch then
            local f = CreateFrame("Frame")
            f:RegisterEvent("PLAYER_REGEN_ENABLED")
            f:SetScript("OnEvent", function(self)
                self:UnregisterEvent("PLAYER_REGEN_ENABLED")
                NK._conflictCombatWatch = nil
                NK:CheckConflictPrompt()
            end)
            NK._conflictCombatWatch = f
        end
        return
    end
    NK:ShowConflictPopup()
end

function NK:Init()
    if self.initialized then return end
    self.initialized = true

    NK:InstallHook()

    -- Repair any B.net labels saved as a session-scoped name token (older bug),
    -- then build the "follow the account" map and keep it fresh as friends log
    -- in/out or switch characters.
    NK:RepairBnetLabels()
    NK:RebuildBnetMap()
    local bf = CreateFrame("Frame")
    bf:RegisterEvent("BN_FRIEND_INFO_CHANGED")
    bf:RegisterEvent("BN_FRIEND_ACCOUNT_ONLINE")
    bf:RegisterEvent("BN_FRIEND_ACCOUNT_OFFLINE")
    bf:RegisterEvent("GROUP_ROSTER_UPDATE")
    bf:SetScript("OnEvent", function() NK:ScheduleBnetRebuild() end)
    NK._bnetEventFrame = bf

    -- Nickname sharing/comms layer (Phase 4).
    if DF.NicknamesComm then DF.NicknamesComm:Init() end

    -- Make sure any names already on screen pick up existing rules.
    NK:RefreshAllFrames()

    -- If NSRT is also set to manage our frame names, prompt once which wins.
    -- Delayed so NSRT's saved vars / settings are loaded first.
    if C_Timer then C_Timer.After(3, function() NK:CheckConflictPrompt() end) end
end
