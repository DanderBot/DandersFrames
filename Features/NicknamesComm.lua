local addonName, DF = ...

-- ============================================================
-- NICKNAMES - SHARING / COMMS  (Phase 4)
-- Self-broadcast model: each player broadcasts THEIR OWN nickname for THEIR
-- current character; receivers map sender ("Name-Realm" from CHAT_MSG_ADDON)
-- -> nickname into DF.Nicknames.received (the separate received cache).
-- Mirrors Features/VersionCheck.lua (channel validation, send chokepoint,
-- dispatch table, composition-key debounce, jittered replies).
--
-- Message types ("TYPE\tPAYLOAD"):
--   N <nick>  : "my nickname is X"  -> receiver AddReceived(sender, X)
--   Q         : "who has a nickname?" -> peers reply with N (jittered)
-- ============================================================

local ipairs = ipairs
local match = string.match
local mrandom = math.random
local tsort, tconcat = table.sort, table.concat

DF.NicknamesComm = DF.NicknamesComm or {}
local C = DF.NicknamesComm

C.PREFIX = "DFNick"          -- <= 16 chars
C.initialized = false
C.playerFullName = nil
C.pendingSync = false
C.lastGroupKey = nil
C.handlers = {}

local function getPlayerFullName()
    local name = UnitName("player")
    -- Use the server-normalised realm so this exactly matches the sender string
    -- the game puts on our own CHAT_MSG_ADDON broadcasts (the self-message guard
    -- compares against it). Space-stripping GetRealmName() can diverge on some
    -- realms (apostrophes/hyphens/locales).
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName())
        or (GetRealmName() or ""):gsub("%s", "")
    return name .. "-" .. realm
end

-- Defensive Midnight comm-restriction check. There's no global
-- IsCommRestricted(); the real restriction state lives under
-- C_RestrictedActions/C_Secrets (API name unconfirmed), so probe behind pcall
-- and default to "allowed" (cosmetic friendly comms are not restricted).
local function isCommRestricted()
    local f = C_RestrictedActions and C_RestrictedActions.IsCommRestricted
    if f then
        local ok, restricted = pcall(f)
        if ok then return restricted and true or false end
    end
    return false
end

local function nkDB()
    return DF.Nicknames and DF.Nicknames:GetDB()
end

-- ============================================================
-- CHANNEL VALIDATION (copied from VersionCheck.lua — proven, avoids
-- ERR_NOT_IN_GROUP spam by funnelling every send through SendMessage).
-- ============================================================

function C:HasPlayerGroupMembers()
    if not IsInGroup(LE_PARTY_CATEGORY_HOME) then return false end
    if IsInRaid(LE_PARTY_CATEGORY_HOME) then
        local n = GetNumGroupMembers()
        for i = 1, n do
            local token = "raid" .. i
            if UnitExists(token) and UnitIsPlayer(token) and not UnitIsUnit(token, "player") then
                return true
            end
        end
        return false
    end
    for i = 1, 4 do
        local token = "party" .. i
        if UnitExists(token) and UnitIsPlayer(token) then return true end
    end
    return false
end

function C:IsChannelValid(channel)
    if channel == "INSTANCE_CHAT" then
        return IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and IsInInstance()
    elseif channel == "RAID" then
        return IsInRaid(LE_PARTY_CATEGORY_HOME) and self:HasPlayerGroupMembers()
    elseif channel == "PARTY" then
        return IsInGroup(LE_PARTY_CATEGORY_HOME)
            and not IsInRaid(LE_PARTY_CATEGORY_HOME)
            and self:HasPlayerGroupMembers()
    elseif channel == "GUILD" then
        return IsInGuild()
    end
    return false
end

-- {GUILD?, INSTANCE_CHAT|RAID|PARTY?} currently available.
function C:GetAvailableChannels()
    local out = {}
    if self:IsChannelValid("GUILD") then out[#out+1] = "GUILD" end
    if self:IsChannelValid("INSTANCE_CHAT") then
        out[#out+1] = "INSTANCE_CHAT"
    elseif self:IsChannelValid("RAID") then
        out[#out+1] = "RAID"
    elseif self:IsChannelValid("PARTY") then
        out[#out+1] = "PARTY"
    end
    return out
end

-- Does a setting mode ("off"/"raid"/"guild"/"both") permit this channel?
-- Group channels (PARTY/RAID/INSTANCE_CHAT) count as "raid"; GUILD as "guild".
local function modePermits(mode, channel)
    if mode == "off" or not mode then return false end
    if mode == "both" then return true end
    local isGuild = (channel == "GUILD")
    if mode == "guild" then return isGuild end
    if mode == "raid" then return not isGuild end
    return false
end

-- Final send chokepoint: re-validate channel, then send.
function C:SendMessage(msgType, payload, channel)
    if not self:IsChannelValid(channel) then return end
    local body = payload and (msgType .. "\t" .. payload) or msgType
    C_ChatInfo.SendAddonMessage(self.PREFIX, body, channel)
end

-- ============================================================
-- BROADCAST / REQUEST
-- ============================================================

-- Broadcast our own nickname on every channel our shareVia setting permits.
function C:BroadcastSelfNick()
    if isCommRestricted() then return end
    local data = nkDB()
    if not data then return end
    local nick = data.selfNick
    if not nick or nick == "" then return end
    local mode = data.shareVia or "off"
    if mode == "off" then return end
    for _, ch in ipairs(self:GetAvailableChannels()) do
        if modePermits(mode, ch) then
            self:SendMessage("N", nick, ch)
        end
    end
end

-- Ask peers to send us their nicknames (they reply with N), on channels we
-- accept from.
function C:RequestFromGroup()
    if isCommRestricted() then return end
    local data = nkDB()
    if not data then return end
    local mode = data.acceptFrom or "off"
    if mode == "off" then return end
    for _, ch in ipairs(self:GetAvailableChannels()) do
        if modePermits(mode, ch) then
            self:SendMessage("Q", nil, ch)
        end
    end
end

-- ============================================================
-- RECEIVE
-- ============================================================

C.handlers["N"] = function(self, sender, payload, channel)
    local data = nkDB()
    if not data then return end
    if not modePermits(data.acceptFrom or "off", channel) then return end  -- accept gating
    if not payload or payload == "" then return end
    -- per-sender block list (persisted)
    local rej = data.rejected
    if rej and DF.Nicknames and rej[DF.Nicknames:Normalize(sender)] then return end
    -- AddReceived runs FilterIncoming (length / escape codes / profanity).
    DF.Nicknames:AddReceived(sender, payload, sender)
end

C.handlers["Q"] = function(self, sender, _, channel)
    local data = nkDB()
    if not data then return end
    local mode = data.shareVia or "off"
    if mode == "off" or not data.selfNick or data.selfNick == "" then return end
    if not modePermits(mode, channel) then return end
    -- Reply with our nickname after small jitter (avoid response storms).
    local delay = 1 + mrandom() * 2
    C_Timer.After(delay, function()
        if modePermits(data.shareVia or "off", channel) and data.selfNick ~= "" then
            self:SendMessage("N", data.selfNick, channel)
        end
    end)
end

function C:Dispatch(msgType, sender, payload, channel)
    if sender == self.playerFullName then return end  -- ignore self
    local h = self.handlers[msgType]
    if h then h(self, sender, payload, channel) end
end

function C:OnAddonMessage(prefix, message, channel, sender)
    if prefix ~= self.PREFIX then return end
    local msgType, payload = match(message, "^([^\t]+)\t?(.*)$")
    if not msgType then return end
    self:Dispatch(msgType, sender, payload, channel)
end

-- ============================================================
-- AUTO-SYNC ON ROSTER JOIN (debounced; composition-key gated)
-- ============================================================

function C:GroupCompositionKey()
    if not IsInGroup() then return "solo" end
    local parts = {}
    local n = GetNumGroupMembers()
    local unit = IsInRaid() and "raid" or "party"
    for i = 1, n do
        local token = (unit == "party" and i == n) and "player" or (unit .. i)
        local fullName = GetUnitName(token, true)
        if fullName then parts[#parts+1] = fullName end
    end
    tsort(parts)
    return tconcat(parts, ",")
end

function C:DoSync()
    local data = nkDB()
    if not data or not data.autoSync then return end
    self:BroadcastSelfNick()
    self:RequestFromGroup()
end

function C:ScheduleSync(delay)
    if self.pendingSync then return end
    self.pendingSync = true
    C_Timer.After(delay, function()
        self.pendingSync = false
        self:DoSync()
    end)
end

-- ============================================================
-- INIT  (called from DF.Nicknames:Init)
-- ============================================================

function C:Init()
    if self.initialized then return end
    self.initialized = true
    self.playerFullName = getPlayerFullName()

    C_ChatInfo.RegisterAddonMessagePrefix(self.PREFIX)

    local f = CreateFrame("Frame")
    f:RegisterEvent("CHAT_MSG_ADDON")
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:SetScript("OnEvent", function(_, event, ...)
        if event == "CHAT_MSG_ADDON" then
            C:OnAddonMessage(...)
        elseif event == "GROUP_ROSTER_UPDATE" then
            local key = C:GroupCompositionKey()
            if key ~= C.lastGroupKey then
                C.lastGroupKey = key
                C:ScheduleSync(3)
            end
        end
    end)
    self.eventFrame = f
    self.lastGroupKey = self:GroupCompositionKey()

    -- Initial sync shortly after login (if enabled + in a group/guild).
    C_Timer.After(3, function() C:DoSync() end)
end
