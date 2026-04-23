local addonName, DF = ...

-- ============================================================
-- BOSS FRAME AURAS (buffs / debuffs)
-- Displays up to N auras on each boss frame, like Blizzard's
-- default boss frames but configurable (size, position, growth
-- direction, harmful vs helpful, stacks & timer).
--
-- Uses C_UnitAuras.GetAuraDataByIndex (modern Retail API) with
-- a fallback to UnitAura for older clients.
-- ============================================================

local pairs, ipairs = pairs, ipairs
local CreateFrame = CreateFrame
local GetTime = GetTime
local format = string.format

local MAX_BOSS = 5

-- ============================================================
-- AURA BUTTON CREATION (pooled per boss frame)
-- ============================================================

local function CreateAuraButton(parent, index)
    local b = CreateFrame("Frame", nil, parent)
    b:SetSize(24, 24)
    b:Hide()

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(b)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.icon = icon

    local border = b:CreateTexture(nil, "OVERLAY", nil, 1)
    border:SetPoint("TOPLEFT",     b, "TOPLEFT",     -1, 1)
    border:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT",  1, -1)
    border:SetColorTexture(0, 0, 0, 0.9)
    border:SetDrawLayer("BACKGROUND")
    b.border = border

    -- Cooldown swipe only — numbers drawn by our own fontstring on top.
    local cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    cd:SetAllPoints(b)
    cd:SetHideCountdownNumbers(true)
    cd:SetDrawEdge(false)
    cd:SetDrawSwipe(true)
    b.cd = cd

    -- Stacks & timer are parented to the cooldown frame so they render ABOVE
    -- the cooldown swipe (otherwise the swipe grey-out masks them). Use the
    -- addon's DF font with outline for readability against busy icons.
    local stackFont = _G["DFFontHighlightSmallOutline"] or _G["DFFontHighlightSmall"] or _G["NumberFontNormalSmall"]
    local timerFont = stackFont

    local stacks = cd:CreateFontString(nil, "OVERLAY", nil)
    stacks:SetFontObject(stackFont)
    stacks:SetTextColor(1, 1, 1)
    stacks:SetDrawLayer("OVERLAY", 7)
    b.stacks = stacks

    local timer = cd:CreateFontString(nil, "OVERLAY", nil)
    timer:SetFontObject(timerFont)
    timer:SetTextColor(1, 0.85, 0.1)
    timer:SetDrawLayer("OVERLAY", 7)
    b.timer = timer

    b.index = index
    return b
end

local function EnsureAuraPool(frame, count)
    frame._auras = frame._auras or {}
    for i = 1, count do
        if not frame._auras[i] then
            frame._auras[i] = CreateAuraButton(frame, i)
        end
    end
    -- Hide any beyond the desired count
    for i = count + 1, #frame._auras do
        frame._auras[i]:Hide()
    end
end

-- ============================================================
-- TIMER FORMATTING
-- ============================================================

local function FormatTime(seconds)
    if seconds <= 0 then return "" end
    if seconds < 10 then return format("%.1f", seconds) end
    if seconds < 60 then return format("%d", seconds) end
    if seconds < 3600 then return format("%dm", seconds / 60) end
    return format("%dh", seconds / 3600)
end

-- ============================================================
-- AURA COLLECTION (UNIT → list of aura data)
-- ============================================================

local auraBuffer = {}

local function auraMatchesSource(data, source)
    if source == "ALL" or not source then return true end

    -- sourceUnit may be a secret string in WoW 12.0+; comparisons and
    -- string methods on it throw. Prefer the non-secret flags on the
    -- aura data and only touch sourceUnit inside pcall.
    local mine = false
    do
        local ok, v = pcall(function()
            if data.isFromPlayerOrPlayerPet ~= nil then
                return data.isFromPlayerOrPlayerPet == true
            end
            local s = data.sourceUnit
            return s == "player" or s == "pet" or s == "vehicle"
        end)
        if ok then mine = v or false end
    end

    if source == "MINE"      then return mine end
    if source == "NOT_MINE"  then return not mine end
    if source == "BOSS_ONLY" then
        local okBoss, isBoss = pcall(function() return data.isBossAura == true end)
        if okBoss and isBoss then return true end
        local okSrc, v = pcall(function()
            local s = data.sourceUnit
            return s and s:match("^boss") and true or false
        end)
        return okSrc and v or false
    end
    return true
end

local function CollectAuras(unit, filter, source, maxCount)
    wipe(auraBuffer)
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for i = 1, 40 do
            local data = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)
            if not data then break end
            if auraMatchesSource(data, source) then
                auraBuffer[#auraBuffer + 1] = data
                if #auraBuffer >= maxCount then break end
            end
        end
    else
        for i = 1, 40 do
            local name, icon, count, _, duration, expiration, caster = UnitAura(unit, i, filter)
            if not name then break end
            local data = {
                name = name, icon = icon, applications = count or 0,
                duration = duration or 0, expirationTime = expiration or 0,
                sourceUnit = caster,
            }
            if auraMatchesSource(data, source) then
                auraBuffer[#auraBuffer + 1] = data
                if #auraBuffer >= maxCount then break end
            end
        end
    end
    return auraBuffer
end

-- ============================================================
-- LAYOUT & UPDATE (called from Boss.lua refresh & OnUpdate ticker)
-- ============================================================

function DF.LayoutBossAuras(frame, db)
    if not db.showAuras then
        if frame._auras then
            for _, b in ipairs(frame._auras) do b:Hide() end
        end
        return
    end

    local maxCount = math.min(math.max(db.aurasMaxCount or 3, 1), 8)
    EnsureAuraPool(frame, maxCount)

    local size = db.aurasSize or 24
    local spacing = db.aurasSpacing or 2
    local anchor = db.aurasAnchor or "TOPLEFT"
    local growX = db.aurasGrowX or "RIGHT"
    local growY = db.aurasGrowY or "DOWN"
    local ox, oy = db.aurasX or 0, db.aurasY or 0

    local dx = (growX == "LEFT") and -(size + spacing) or (size + spacing)
    local dy = (growY == "UP")   and  (size + spacing) or -(size + spacing)

    for i = 1, maxCount do
        local b = frame._auras[i]
        b:SetSize(size, size)
        b:ClearAllPoints()
        if i == 1 then
            b:SetPoint(anchor, frame, anchor, ox, oy)
        else
            b:SetPoint(anchor, frame._auras[i - 1], anchor, dx, 0)
        end

        -- Stack text anchor
        if b.stacks then
            b.stacks:ClearAllPoints()
            local sa = db.aurasStackAnchor or "BOTTOMRIGHT"
            b.stacks:SetPoint(sa, b, sa, db.aurasStackX or -1, db.aurasStackY or 1)
        end

        -- Timer text placement
        if b.timer then
            b.timer:ClearAllPoints()
            local place = db.aurasTimerPlacement or "INSIDE"
            local tx = db.aurasTimerX or 0
            local ty = db.aurasTimerY or 0
            if place == "BELOW" then
                b.timer:SetPoint("TOP", b, "BOTTOM", tx, ty - 1)
            elseif place == "ABOVE" then
                b.timer:SetPoint("BOTTOM", b, "TOP", tx, ty + 1)
            else -- INSIDE
                b.timer:SetPoint("CENTER", b, "CENTER", tx, ty)
            end
        end
    end
end

function DF.UpdateBossAuras(frame)
    local db = DF:GetRenderBossDB()
    if not db.showAuras or not frame._auras then
        if frame._auras then for _, b in ipairs(frame._auras) do b:Hide() end end
        return
    end

    local maxCount = math.min(math.max(db.aurasMaxCount or 3, 1), 8)

    -- Test mode: fake auras with cached expirations so timers visibly count down
    if frame._testMode then
        local now = GetTime()
        -- (Re)generate cached test auras if missing or all expired
        if not frame._testAuras or not frame._testAuras[1]
           or frame._testAuras[1].expirationTime < now then
            local durations = { 10, 15, 8, 20, 30 }
            local icons     = { 135812, 136197, 135844, 136048, 136042 }
            frame._testAuras = {}
            frame._testStackStart = now
            for i = 1, 5 do
                frame._testAuras[i] = {
                    icon = icons[i],
                    duration = durations[i],
                    expirationTime = now + durations[i],
                    -- Stacks grow from 1 to 40 over the duration of the aura.
                    stackGrowSpeed = 40 / durations[i],   -- stacks per second
                }
            end
        end

        for i = 1, maxCount do
            local b = frame._auras[i]
            local a = frame._testAuras[i]
            if a then
                b.icon:SetTexture(a.icon)

                -- Animated stack count (1 → 40 across the aura's duration)
                local elapsed = a.duration - (a.expirationTime - now)
                local stacks = math.floor(1 + elapsed * (a.stackGrowSpeed or 0))
                if stacks < 1 then stacks = 1 end
                if stacks > 40 then stacks = 40 end

                if db.aurasShowStacks and stacks > 1 then
                    b.stacks:SetText(stacks)
                else
                    b.stacks:SetText("")
                end

                if db.aurasShowTimer and a.expirationTime and a.expirationTime > 0 then
                    b.timer:SetText(FormatTime(a.expirationTime - now))
                    if b.cd and a.duration > 0 then
                        b.cd:SetCooldown(a.expirationTime - a.duration, a.duration)
                    end
                else
                    b.timer:SetText("")
                end
                b:Show()
            else
                b:Hide()
            end
        end
        return
    end

    local unit = frame.unit
    if not UnitExists(unit) then
        for _, b in ipairs(frame._auras) do b:Hide() end
        return
    end

    local auras = CollectAuras(unit, db.aurasFilter or "HARMFUL", db.aurasSource or "ALL", maxCount)
    for i = 1, maxCount do
        local b = frame._auras[i]
        local a = auras[i]
        if a then
            b.icon:SetTexture(a.icon)
            if db.aurasShowStacks then
                -- applications may be a secret number; guard the compare.
                local ok, showIt = pcall(function() return a.applications and a.applications > 1 end)
                if ok and showIt then
                    pcall(b.stacks.SetText, b.stacks, a.applications)
                else
                    b.stacks:SetText("")
                end
            else
                b.stacks:SetText("")
            end
            if db.aurasShowTimer then
                -- expirationTime / duration may be secret in WoW 12.0+.
                -- Keep the cooldown ring (SetCooldown handles secrets) but
                -- skip our own arithmetic text if it throws.
                local okText, remaining = pcall(function()
                    if a.expirationTime and a.expirationTime > 0 then
                        return a.expirationTime - GetTime()
                    end
                end)
                if okText and remaining then
                    b.timer:SetText(FormatTime(remaining))
                else
                    b.timer:SetText("")
                end
                if b.cd and a.duration and a.expirationTime then
                    -- Wrap in a closure so the arithmetic runs inside pcall.
                    pcall(function()
                        b.cd:SetCooldown(a.expirationTime - a.duration, a.duration)
                    end)
                end
            else
                b.timer:SetText("")
                if b.cd then b.cd:Clear() end
            end
            b:Show()
        else
            b:Hide()
        end
    end
end

-- ============================================================
-- TIMER TICKER (refreshes expiration text every 0.2s)
-- ============================================================

local timerTicker = CreateFrame("Frame")
local _elapsed = 0
timerTicker:SetScript("OnUpdate", function(_, e)
    _elapsed = _elapsed + e
    if _elapsed < 0.2 then return end
    _elapsed = 0
    local db = DF:GetRenderBossDB()
    if not db.showAuras or not db.aurasShowTimer then return end
    local now = GetTime()
    for i = 1, MAX_BOSS do
        local f = DF.BossFrames and DF.BossFrames[i]
        if f and f._auras then
            for _, b in ipairs(f._auras) do
                if b:IsShown() and b.timer then
                    -- Recompute from stored expirationTime only if we have one
                    -- (test mode uses hardcoded values; live mode refreshes from API next UNIT_AURA)
                end
            end
        end
    end
end)

-- ============================================================
-- EVENTS
-- ============================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:SetScript("OnEvent", function(_, event, unit)
    if not unit or not unit:match("^boss%d$") then return end
    local idx = tonumber(unit:sub(5))
    local frame = DF.BossFrames and DF.BossFrames[idx]
    if frame then DF.UpdateBossAuras(frame) end
end)
