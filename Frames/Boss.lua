local addonName, DF = ...

-- ============================================================
-- BOSS FRAMES (v1 scaffold)
-- Creates up to 5 boss unit frames (boss1..boss5) with:
--   * Portrait (3D / 2D / hidden, left or right)
--   * Health bar with class colour fallback
--   * Power bar
--   * Cast bar (castbar element only — Étape 2 wires full events)
--   * Name + health text
--
-- The Blizzard BossTargetFrameContainer is hidden when enabled.
-- ============================================================

local pairs, ipairs = pairs, ipairs
local format = string.format
local CreateFrame = CreateFrame
local UnitExists = UnitExists
local UnitName = UnitName
local UnitIsConnected = UnitIsConnected
local UnitClass = UnitClass
local UnitHealth = UnitHealth
local UnitHealthMax = UnitHealthMax
local UnitPower = UnitPower
local UnitPowerMax = UnitPowerMax
local UnitPowerType = UnitPowerType
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local SetPortraitTexture = SetPortraitTexture
local InCombatLockdown = InCombatLockdown

local MAX_BOSS = 5

DF.BossFrames = DF.BossFrames or {}
DF.BossContainer = nil

-- Resolve an LSM texture name (e.g. "DF Smooth") to a path. If the value
-- already looks like a path (contains backslash or forward slash), use
-- it as-is. Falls back to DF_Smooth if the name is unknown.
local function ResolveTexture(name)
    if not name or name == "" then
        return "Interface\\AddOns\\DandersFrames\\Media\\DF_Smooth"
    end
    if name:find("\\") or name:find("/") then
        return name
    end
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if LSM then
        local p = LSM:Fetch("statusbar", name)
        if p then return p end
    end
    return "Interface\\AddOns\\DandersFrames\\Media\\DF_Smooth"
end
DF.ResolveBossTexture = ResolveTexture

-- ============================================================
-- BLIZZARD BOSS FRAME HIDING
-- ============================================================

local blizzardHidden = false
local function HideBlizzardBossFrames()
    if blizzardHidden then return end
    blizzardHidden = true

    -- Modern retail (Midnight 12.0): BossTargetFrameContainer with children
    local container = _G["BossTargetFrameContainer"] or _G["BossFrameContainer"]
    if container then
        container:UnregisterAllEvents()
        container:Hide()
        container.Show = function() end
    end

    for i = 1, MAX_BOSS do
        local names = {
            "Boss" .. i .. "TargetFrame",
            "BossTargetFrame" .. i,
        }
        for _, n in ipairs(names) do
            local f = _G[n]
            if f then
                f:UnregisterAllEvents()
                f:Hide()
                f.Show = function() end
            end
        end
    end
end

-- ============================================================
-- COLOR HELPERS
-- ============================================================

local CLASS_COLORS = RAID_CLASS_COLORS or {}

local function GetHealthColor(db, unit)
    local mode = db.healthColorMode or "CLASS_FALLBACK"
    if mode == "STATIC" then
        local c = db.healthStaticColor
        return c.r, c.g, c.b
    elseif mode == "REACTION" then
        -- Blizzard-style: hostile → red, neutral → yellow, friendly → green
        local reaction = UnitReaction and UnitReaction(unit, "player")
        if reaction and FACTION_BAR_COLORS and FACTION_BAR_COLORS[reaction] then
            local c = FACTION_BAR_COLORS[reaction]
            return c.r, c.g, c.b
        end
        return 0.9, 0.15, 0.15
    end
    -- CLASS_FALLBACK
    local _, cls = UnitClass(unit)
    local cc = cls and CLASS_COLORS[cls]
    if cc then return cc.r, cc.g, cc.b end
    return 0.9, 0.15, 0.15
end

local function GetPowerColor(unit)
    local powerType, powerToken = UnitPowerType(unit)
    local info = powerToken and PowerBarColor and PowerBarColor[powerToken]
    if info then return info.r, info.g, info.b end
    return 0.3, 0.4, 0.9
end

-- ============================================================
-- HEALTH / POWER UPDATE (safe against secret values)
-- ============================================================

local function SetHealthValue(frame, unit)
    local hp, hpMax
    if DF.GetSafeHealthPercent then
        local pct = DF.GetSafeHealthPercent(unit)
        frame.healthBar:SetMinMaxValues(0, 100)
        frame.healthBar:SetValue(pct or 0)
        frame._hpPct = pct or 0
    else
        hp, hpMax = UnitHealth(unit), UnitHealthMax(unit)
        if type(hp) ~= "number" or type(hpMax) ~= "number" or hpMax == 0 then
            frame.healthBar:SetMinMaxValues(0, 1)
            frame.healthBar:SetValue(1)
            frame._hpPct = 100
        else
            frame.healthBar:SetMinMaxValues(0, hpMax)
            frame.healthBar:SetValue(hp)
            frame._hpPct = (hp / hpMax) * 100
        end
    end
end

local function SetPowerValue(frame, unit)
    if not frame.powerBar or not frame.powerBar:IsShown() then return end
    local okP, p = pcall(UnitPower, unit)
    local okM, pMax = pcall(UnitPowerMax, unit)
    if not okP or not okM then return end

    -- Unit has no power pool (e.g. certain bosses): hide bar + text entirely.
    local okCmp, hasPower = pcall(function() return pMax and pMax > 0 end)
    if not okCmp or not hasPower then
        frame.powerBar:Hide()
        if frame.powerText then frame.powerText:SetText("") end
        return
    end
    frame.powerBar:Show()

    pcall(frame.powerBar.SetMinMaxValues, frame.powerBar, 0, pMax)
    pcall(frame.powerBar.SetValue,       frame.powerBar, p)
    frame.powerBar:SetStatusBarColor(GetPowerColor(unit))

    if not frame.powerText then return end
    local db = DF:GetRenderBossDB()
    if not db.showPowerText then frame.powerText:SetText(""); return end

    -- Visual percent via StatusBar texture width — works even when p/pMax
    -- are secret (GetWidth returns display pixels, not secret values).
    local function visualPct()
        local tex = frame.powerBar:GetStatusBarTexture()
        local barW = frame.powerBar:GetWidth()
        if not tex or not barW or barW <= 0 then return 0 end
        return (tex:GetWidth() or 0) / barW * 100
    end

    local fmt = db.powerTextFormat or "PERCENT"
    if fmt == "PERCENT" then
        frame.powerText:SetFormattedText("%d%%", visualPct())
    elseif fmt == "CURRENT" then
        pcall(frame.powerText.SetText, frame.powerText, AbbreviateLargeNumbers(p))
    elseif fmt == "CURRENT_PERCENT" then
        local okAbbr, pStr = pcall(AbbreviateLargeNumbers, p)
        if okAbbr then
            frame.powerText:SetFormattedText("%s (%d%%)", pStr, visualPct())
        else
            frame.powerText:SetFormattedText("%d%%", visualPct())
        end
    else
        pcall(frame.powerText.SetFormattedText, frame.powerText,
            "%s / %s", AbbreviateLargeNumbers(p), AbbreviateLargeNumbers(pMax))
    end
end

local function FormatHealthText(frame, db, unit)
    if not frame.healthText then return end
    if not db.showHealthText then frame.healthText:SetText(""); return end
    local fmt = db.healthTextFormat or "PERCENT"
    local pct = frame._hpPct or 0  -- may be a secret number; never do arithmetic on it

    if fmt == "PERCENT" then
        -- SetFormattedText accepts secret numbers directly with %d
        pcall(frame.healthText.SetFormattedText, frame.healthText, "%d%%", pct)
    elseif fmt == "CURRENT" then
        if frame._testMode then
            frame.healthText:SetText(AbbreviateLargeNumbers((frame._testHp or 0) * 1e6))
        else
            local ok, hp = pcall(UnitHealth, unit)
            if ok and type(hp) == "number" then
                frame.healthText:SetText(AbbreviateLargeNumbers(hp))
            else
                frame.healthText:SetText("")
            end
        end
    elseif fmt == "CURRENT_PERCENT" then
        if frame._testMode then
            local hp = (frame._testHp or 0) * 1e6
            frame.healthText:SetFormattedText("%s (%d%%)", AbbreviateLargeNumbers(hp), pct)
        else
            local ok, hp = pcall(UnitHealth, unit)
            if ok and type(hp) == "number" then
                pcall(frame.healthText.SetFormattedText, frame.healthText, "%s (%d%%)", AbbreviateLargeNumbers(hp), pct)
            end
        end
    else -- CURRENT_MAX
        if frame._testMode then
            frame.healthText:SetFormattedText("%s / %s",
                AbbreviateLargeNumbers((frame._testHp or 0) * 1e6),
                AbbreviateLargeNumbers(1e8))
        else
            local ok1, hp    = pcall(UnitHealth, unit)
            local ok2, hpMax = pcall(UnitHealthMax, unit)
            if ok1 and ok2 and type(hp) == "number" and type(hpMax) == "number" then
                frame.healthText:SetFormattedText("%s / %s",
                    AbbreviateLargeNumbers(hp), AbbreviateLargeNumbers(hpMax))
            else
                frame.healthText:SetText("")
            end
        end
    end
end

-- ============================================================
-- FRAME UPDATE (all visuals for a single boss frame)
-- ============================================================

local function UpdateFrame(frame)
    local unit = frame.unit
    local db = DF:GetRenderBossDB()

    -- Visibility is driven by RegisterStateDriver (boss unit exists → show).
    -- In test mode we override: set driver to always-show; on exit, revert.
    -- Don't early-return here — UpdateFrame should still populate data when
    -- the frame isn't visible (cheap, and avoids stale data on next show).

    -- Name — UnitName / length / sub may all return or operate on secret
    -- values in WoW 12.0+. Wrap everything in pcall.
    if frame.nameText then
        if db.showName then
            local ok, n = pcall(UnitName, unit)
            if not ok or not n then n = frame._testName or ("Boss " .. frame.index) end
            local maxLen = db.nameMaxLength or 0
            if maxLen > 0 then
                pcall(function()
                    if #n > maxLen then n = n:sub(1, maxLen - 1) .. "…" end
                end)
            end
            pcall(frame.nameText.SetText, frame.nameText, n)
        else
            frame.nameText:SetText("")
        end
    end

    -- Portrait (2D Blizzard-style face icon)
    if frame.portrait then
        if db.portraitPosition ~= "HIDDEN" then
            frame.portrait:Show()
            SetPortraitTexture(frame.portrait, frame._testMode and "player" or unit)
        else
            frame.portrait:Hide()
        end
    end

    -- Health
    if frame._testMode then
        frame.healthBar:SetMinMaxValues(0, 100)
        frame.healthBar:SetValue(frame._testHp or 80)
        frame._hpPct = frame._testHp or 80
    else
        SetHealthValue(frame, unit)
    end
    frame.healthBar:SetStatusBarColor(GetHealthColor(db, unit))

    -- Power
    if db.showPowerBar and frame.powerBar then
        frame.powerBar:Show()
        if frame._testMode then
            local p = frame._testPower or 50
            frame.powerBar:SetMinMaxValues(0, 100)
            frame.powerBar:SetValue(p)
            frame.powerBar:SetStatusBarColor(0.3, 0.4, 0.9)
            if frame.powerText then
                if db.showPowerText then
                    frame.powerText:SetFormattedText("%d%%", p + 0.5)
                else
                    frame.powerText:SetText("")
                end
            end
        else
            SetPowerValue(frame, unit)
        end
    elseif frame.powerBar then
        frame.powerBar:Hide()
    end

    -- Health text
    FormatHealthText(frame, db, unit)

    -- Dead overlay
    if UnitIsDeadOrGhost(unit) and not frame._testMode then
        frame:SetAlpha(0.4)
    else
        frame:SetAlpha(1)
    end

    -- Raid target icon visibility
    if db.showRaidTargetIcon and DF.UpdateBossRaidTargetIcon then
        DF.UpdateBossRaidTargetIcon(frame)
    elseif frame.raidTargetIcon then
        frame.raidTargetIcon:Hide()
    end

    -- Auras
    if DF.UpdateBossAuras then DF.UpdateBossAuras(frame) end

end

-- ============================================================
-- LAYOUT
-- ============================================================

local _pendingLayout = false
local function ApplyLayout()
    local db = DF:GetRenderBossDB()
    local container = DF.BossContainer
    if not container then return end

    -- Secure-frame modifications are forbidden in combat. Defer until
    -- PLAYER_REGEN_ENABLED to avoid "action blocked" + taint cascade.
    if InCombatLockdown() then
        _pendingLayout = true
        return
    end

    container:SetScale(db.frameScale or 1)
    container:SetFrameStrata(db.frameStrata or "MEDIUM")

    -- Re-anchor the container (honours Offset X/Y sliders changes)
    local anchor = db.anchor or "RIGHT"
    container:ClearAllPoints()
    container:SetPoint(anchor, UIParent, anchor, db.anchorX or 0, db.anchorY or 0)

    local hpTex  = ResolveTexture(db.healthTexture)
    local pwTex  = ResolveTexture(db.powerTexture)

    -- 9-point anchor validation shared across all per-frame anchor math below
    local VALID_ANCHOR9 = {
        TOPLEFT = true, TOP = true, TOPRIGHT = true,
        LEFT = true, CENTER = true, RIGHT = true,
        BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
    }
    local function justifyOf(anchor)
        if anchor:find("LEFT") then return "LEFT"
        elseif anchor:find("RIGHT") then return "RIGHT"
        else return "CENTER" end
    end

    for i = 1, MAX_BOSS do
        local f = DF.BossFrames[i]
        if not f then break end

        f:SetSize(db.frameWidth, db.frameHeight)

        -- Textures
        if f.healthBar then
            f.healthBar:SetStatusBarTexture(hpTex)
            if f.healthBar.bg then
                f.healthBar.bg:SetColorTexture(0.1, 0.1, 0.1, db.healthBackgroundAlpha or 0.35)
            end
        end
        if f.powerBar then
            f.powerBar:SetStatusBarTexture(pwTex)
            if f.powerBar.bg then
                f.powerBar.bg:SetColorTexture(0, 0, 0, db.powerBackgroundAlpha or 0.7)
            end
        end
        f:ClearAllPoints()

        if i == 1 then
            f:SetPoint("TOP", container, "TOP", 0, 0)
        else
            local prev = DF.BossFrames[i - 1]
            local spacing = db.frameSpacing
            if db.growDirection == "UP" then
                f:SetPoint("BOTTOM", prev, "TOP", 0, spacing)
            else
                f:SetPoint("TOP", prev, "BOTTOM", 0, -spacing)
            end
        end

        if f.portrait then
            local size = db.portraitSize
            f.portrait:SetSize(size, size)
            f.portrait:ClearAllPoints()
            if db.portraitPosition == "LEFT" then
                f.portrait:SetPoint("RIGHT", f, "LEFT", -2, 0)
            elseif db.portraitPosition == "RIGHT" then
                f.portrait:SetPoint("LEFT", f, "RIGHT", 2, 0)
            end
            -- Border (1px black rect behind the portrait)
            if f.portraitBorder then
                f.portraitBorder:ClearAllPoints()
                if db.portraitPosition == "HIDDEN" then
                    f.portraitBorder:Hide()
                else
                    f.portraitBorder:Show()
                    f.portraitBorder:SetPoint("TOPLEFT", f.portrait, "TOPLEFT", -1, 1)
                    f.portraitBorder:SetPoint("BOTTOMRIGHT", f.portrait, "BOTTOMRIGHT", 1, -1)
                end
            end
        end

        -- Layout order from bottom to top: cast (if integrated) → power → health
        local castH  = (db.showCastBar and not db.castBarDetached) and (db.castBarHeight + 1) or 0
        local powerH = db.showPowerBar and (db.powerBarHeight + 1) or 0

        -- Power bar sits above the cast bar area
        if f.powerBar then
            f.powerBar:ClearAllPoints()
            f.powerBar:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",  0, castH)
            f.powerBar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, castH)
            f.powerBar:SetHeight(db.powerBarHeight)
        end

        -- Health bar fills the top, above the power bar
        f.healthBar:ClearAllPoints()
        f.healthBar:SetPoint("TOPLEFT",     f, "TOPLEFT",     0, 0)
        f.healthBar:SetPoint("TOPRIGHT",    f, "TOPRIGHT",    0, 0)
        f.healthBar:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",  0, castH + powerH)
        f.healthBar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, castH + powerH)

        -- Power text anchor (inside the power bar)
        if f.powerText then
            f.powerText:ClearAllPoints()
            local a = db.powerTextAnchor
            if not VALID_ANCHOR9[a] then a = "RIGHT"; db.powerTextAnchor = a end
            f.powerText:SetPoint(a, f.powerBar, a, db.powerTextX or 0, db.powerTextY or 0)
            f.powerText:SetJustifyH(justifyOf(a))
            if db.showPowerText and db.showPowerBar then
                f.powerText:Show()
            else
                f.powerText:Hide()
            end
        end

        -- Text alignment (9-point) — sanitise in case SV holds bad values
        if f.nameText then
            f.nameText:ClearAllPoints()
            local a = db.nameAnchor
            if not VALID_ANCHOR9[a] then a = "LEFT"; db.nameAnchor = a end
            local ox = db.nameX or 0
            local oy = db.nameY or 0
            f.nameText:SetPoint(a, f.healthBar, a, ox, oy)
            f.nameText:SetJustifyH(justifyOf(a))
        end
        if f.healthText then
            f.healthText:ClearAllPoints()
            local a = db.healthTextAnchor
            if not VALID_ANCHOR9[a] then a = "RIGHT"; db.healthTextAnchor = a end
            local ox = db.healthTextX or 0
            local oy = db.healthTextY or 0
            f.healthText:SetPoint(a, f.healthBar, a, ox, oy)
            f.healthText:SetJustifyH(justifyOf(a))
        end

        -- Raid target icon layout
        if f.raidTargetIcon then
            if db.showRaidTargetIcon then
                local a = db.raidTargetAnchor
                if not VALID_ANCHOR9[a] then a = "CENTER"; db.raidTargetAnchor = a end
                f.raidTargetIcon:SetSize(db.raidTargetSize or 28, db.raidTargetSize or 28)
                f.raidTargetIcon:ClearAllPoints()
                f.raidTargetIcon:SetPoint(a, f, a, db.raidTargetX or 0, db.raidTargetY or 0)
                f.raidTargetIcon:SetAlpha(db.raidTargetAlpha or 0.9)
                -- Ensure texture atlas is set (in case SV-loaded frames lost it)
                if not f.raidTargetIcon:GetTexture() then
                    f.raidTargetIcon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
                end
            else
                f.raidTargetIcon:Hide()
            end
        end

        -- Sanitise healthTextFormat
        local VALID_FMT = { PERCENT = true, CURRENT = true, CURRENT_PERCENT = true, CURRENT_MAX = true }
        if not VALID_FMT[db.healthTextFormat] then db.healthTextFormat = "PERCENT" end

        -- Cast bar layout (if module present)
        if DF.LayoutBossCastBar then DF.LayoutBossCastBar(f, db) end

        -- Auras layout
        if DF.LayoutBossAuras then DF.LayoutBossAuras(f, db) end
    end
end

DF.ApplyBossLayout = ApplyLayout

-- Update a single frame's raid target icon (skull/cross/star/etc.)
function DF.UpdateBossRaidTargetIcon(frame)
    if not frame.raidTargetIcon then return end
    local unit = frame.unit
    local idx
    if frame._testMode then
        idx = frame.index  -- 1..5 in test
    else
        local ok, v = pcall(GetRaidTargetIndex, unit)
        if ok then idx = v end
    end
    -- idx may be a secret number in WoW 12.0+; can't compare directly.
    -- Pass it straight to SetRaidTargetIconTexCoord (Blizzard's fn accepts
    -- secrets). Guard the whole call.
    if not idx then
        frame.raidTargetIcon:Hide()
        return
    end
    local applied
    local ok = pcall(function()
        if SetRaidTargetIconTexCoord then
            SetRaidTargetIconTexCoord(frame.raidTargetIcon, idx)
        elseif SetRaidTargetIconTexture then
            SetRaidTargetIconTexture(frame.raidTargetIcon, idx)
        end
        applied = true
    end)
    -- Decide visibility: if idx was 0 (no marker), texcoord is 0,0,0,0 → show
    -- would be a black square. Use pcall to compare with zero.
    local okZero, isZero = pcall(function() return idx == 0 end)
    if ok and applied and not (okZero and isZero) then
        frame.raidTargetIcon:Show()
    else
        frame.raidTargetIcon:Hide()
    end
end

-- ============================================================
-- FRAME CREATION
-- ============================================================

local function CreateBossFrame(index)
    local name = "DFBossFrame" .. index
    local unit = "boss" .. index

    local f = CreateFrame("Button", name, DF.BossContainer, "SecureUnitButtonTemplate")
    f:SetAttribute("unit", unit)
    f:SetAttribute("*type1", "target")
    f:SetAttribute("*type2", "togglemenu")
    f:RegisterForClicks("AnyDown")
    f.unit = unit
    f.index = index

    -- Visibility via secure state driver — works in combat without Show/Hide
    -- calls on this SecureUnitButton. The frame shows whenever its boss unit
    -- exists; test mode overrides with a unit-less "show" macro condition.
    RegisterStateDriver(f, "visibility", "[@" .. unit .. ",exists]show;hide")

    -- Background behind everything
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetColorTexture(0, 0, 0, 0.6)
    f.bg = bg

    -- Health bar
    local hp = CreateFrame("StatusBar", nil, f)
    hp:SetStatusBarTexture("Interface\\AddOns\\DandersFrames\\Media\\DF_Smooth")
    hp:SetMinMaxValues(0, 100)
    hp:SetValue(100)
    f.healthBar = hp

    local hpBg = hp:CreateTexture(nil, "BACKGROUND")
    hpBg:SetAllPoints(hp)
    hpBg:SetColorTexture(0.1, 0.1, 0.1, 0.5)
    hp.bg = hpBg

    -- Power bar
    local pw = CreateFrame("StatusBar", nil, f)
    pw:SetStatusBarTexture("Interface\\AddOns\\DandersFrames\\Media\\DF_Smooth")
    pw:SetMinMaxValues(0, 100)
    pw:SetValue(0)
    f.powerBar = pw

    local pwBg = pw:CreateTexture(nil, "BACKGROUND")
    pwBg:SetAllPoints(pw)
    pwBg:SetColorTexture(0, 0, 0, 0.7)
    pw.bg = pwBg

    -- Power text (mana %/value)
    local pwText = pw:CreateFontString(nil, "OVERLAY", nil)
    pwText:SetFontObject(_G["DFFontHighlightSmallOutline"] or _G["NumberFontNormalSmall"])
    pwText:SetTextColor(1, 1, 1)
    pwText:SetPoint("RIGHT", pw, "RIGHT", -2, 0)
    pwText:SetJustifyH("RIGHT")
    f.powerText = pwText

    -- Portrait — 2D only (Blizzard-style face icon via SetPortraitTexture)
    local portrait = f:CreateTexture(nil, "ARTWORK")
    portrait:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    portrait:Hide()
    f.portrait = portrait

    -- Thin border around the portrait: a slightly larger black rectangle
    -- behind the model creates a 1px "frame" look.
    local pb = f:CreateTexture(nil, "BACKGROUND", nil, 2)
    pb:SetColorTexture(0, 0, 0, 0.9)
    f.portraitBorder = pb

    -- Name text
    local nameText = hp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameText:SetPoint("LEFT", hp, "LEFT", 4, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetTextColor(1, 1, 1)
    f.nameText = nameText

    -- Health text
    local hpText = hp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hpText:SetPoint("RIGHT", hp, "RIGHT", -4, 0)
    hpText:SetJustifyH("RIGHT")
    hpText:SetTextColor(1, 1, 1)
    f.healthText = hpText

    -- Hover highlight
    local highlight = f:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints(f)
    highlight:SetColorTexture(1, 1, 1, 0.1)


    -- Raid target icon (skull/cross/star/etc.) — parent to healthBar on its
    -- OVERLAY sublayer so it draws ABOVE the bar's artwork texture.
    local rti = hp:CreateTexture(nil, "OVERLAY", nil, 7)
    rti:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    rti:SetSize(28, 28)
    rti:SetPoint("CENTER", f, "CENTER", 0, 0)
    rti:Hide()
    f.raidTargetIcon = rti

    -- Event handler
    f:RegisterEvent("UNIT_HEALTH")
    f:RegisterEvent("UNIT_MAXHEALTH")
    f:RegisterEvent("UNIT_POWER_UPDATE")
    f:RegisterEvent("UNIT_MAXPOWER")
    f:RegisterEvent("UNIT_DISPLAYPOWER")
    f:RegisterEvent("UNIT_NAME_UPDATE")
    f:RegisterEvent("UNIT_PORTRAIT_UPDATE")
    f:RegisterEvent("UNIT_TARGETABLE_CHANGED")
    f:RegisterEvent("RAID_TARGET_UPDATE")
    f:RegisterUnitEvent("UNIT_HEALTH", unit)
    f:SetScript("OnEvent", function(self, event, eUnit)
        if event == "RAID_TARGET_UPDATE" then
            DF.UpdateBossRaidTargetIcon(self)
            return
        end
        if event == "UNIT_TARGETABLE_CHANGED" and eUnit == unit then
            UpdateFrame(self)
            return
        end
        if eUnit ~= unit then return end
        UpdateFrame(self)
    end)

    return f
end

-- ============================================================
-- INIT
-- ============================================================

local function EnsureCreated()
    if DF.BossContainer then return end

    local db = DF:GetRenderBossDB()
    if not db.enabled then return end

    local container = CreateFrame("Frame", "DFBossContainer", UIParent)
    container:SetSize(db.frameWidth, (db.frameHeight + db.frameSpacing) * MAX_BOSS)
    container:ClearAllPoints()
    container:SetPoint(db.anchor or "RIGHT", UIParent, db.anchor or "RIGHT", db.anchorX or 0, db.anchorY or 0)
    container:SetFrameStrata(db.frameStrata or "MEDIUM")
    container:SetMovable(true)
    DF.BossContainer = container

    for i = 1, MAX_BOSS do
        DF.BossFrames[i] = CreateBossFrame(i)
    end

    ApplyLayout()

    if db.hideBlizzard then
        HideBlizzardBossFrames()
    end
end

DF.EnsureBossFramesCreated = EnsureCreated

local function RefreshAll()
    if not DF.BossContainer then return end
    ApplyLayout()
    for i = 1, MAX_BOSS do
        local f = DF.BossFrames[i]
        if f then UpdateFrame(f) end
    end
end

DF.RefreshBossFrames = RefreshAll

-- ============================================================
-- EVENTS (engage / disengage bosses)
-- ============================================================

local bossEventFrame = CreateFrame("Frame")
bossEventFrame:RegisterEvent("PLAYER_LOGIN")
bossEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
bossEventFrame:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
bossEventFrame:RegisterEvent("ENCOUNTER_START")
bossEventFrame:RegisterEvent("ENCOUNTER_END")
bossEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

local hooksInstalled = false
local function InstallGlobalHooks()
    if hooksInstalled then return end
    hooksInstalled = true

    -- Tie boss test mode to the global Test Mode toggle, respecting the
    -- "Show Boss Frames" checkbox and count slider in the test panel.
    if DF.ToggleTestMode then
        hooksecurefunc(DF, "ToggleTestMode", function()
            local anyTest = DF.testMode or DF.raidTestMode
            local currentBossTest
            for i = 1, MAX_BOSS do
                if DF.BossFrames[i] and DF.BossFrames[i]._testMode then
                    currentBossTest = true; break
                end
            end
            local isRaidMode = DF.GUI and DF.GUI.SelectedMode == "raid"
            local db = isRaidMode and DF:GetRaidDB() or DF:GetDB()
            -- Default to showing boss test when user has never touched the
            -- checkbox (nil) — keeps previous behaviour for new users.
            local wantBoss = anyTest and (db.testShowBoss == nil or db.testShowBoss)
            local count = tonumber(db.testBossCount) or 3
            if wantBoss and not currentBossTest then
                DF:SetBossTestMode(count)
            elseif (not wantBoss) and currentBossTest then
                DF:SetBossTestMode(0)
            end
        end)
    end

    -- Tie boss mover to the global Unlock / Lock buttons.
    local function sync(desiredUnlocked)
        if not DF.BossContainer then EnsureCreated() end
        if not DF.BossContainer then return end
        local curUnlocked = DF.BossContainer._movingEnabled and true or false
        if curUnlocked ~= desiredUnlocked then
            DF:ToggleBossMover()
        end
    end
    if DF.UnlockFrames     then hooksecurefunc(DF, "UnlockFrames",     function() sync(true)  end) end
    if DF.LockFrames       then hooksecurefunc(DF, "LockFrames",       function() sync(false) end) end
    if DF.UnlockRaidFrames then hooksecurefunc(DF, "UnlockRaidFrames", function() sync(true)  end) end
    if DF.LockRaidFrames   then hooksecurefunc(DF, "LockRaidFrames",   function() sync(false) end) end

    -- Re-apply boss frames when the user switches PARTY <-> RAID in the
    -- options panel. RefreshCurrentPage is built lazily when /df opens for
    -- the first time — poll until it exists, then install the hook.
    local refreshHookInstalled = false
    local function tryInstallRefreshHook()
        if refreshHookInstalled then return end
        if not (DF.GUI and DF.GUI.RefreshCurrentPage) then return end
        refreshHookInstalled = true

        local lastMode = DF.GUI.SelectedMode or "party"
        hooksecurefunc(DF.GUI, "RefreshCurrentPage", function()
            local cur = DF.GUI.SelectedMode or "party"
            if cur ~= lastMode then
                lastMode = cur
                C_Timer.After(0, function() RefreshAll() end)
            end
        end)
    end
    tryInstallRefreshHook()
    if not refreshHookInstalled then
        -- Poll every 0.5s until the GUI is built (user opens /df).
        local poll = CreateFrame("Frame")
        local _acc = 0
        poll:SetScript("OnUpdate", function(self, elapsed)
            _acc = _acc + elapsed
            if _acc < 0.5 then return end
            _acc = 0
            tryInstallRefreshHook()
            if refreshHookInstalled then self:SetScript("OnUpdate", nil) end
        end)
    end

    -- Also re-apply on real group-state change (joining/leaving a raid).
    local groupWatcher = CreateFrame("Frame")
    groupWatcher:RegisterEvent("GROUP_ROSTER_UPDATE")
    groupWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
    local wasInRaid = IsInRaid()
    groupWatcher:SetScript("OnEvent", function()
        local nowRaid = IsInRaid()
        if nowRaid ~= wasInRaid then
            wasInRaid = nowRaid
            RefreshAll()
        end
    end)
end

bossEventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" and _pendingLayout then
        _pendingLayout = false
        EnsureCreated()
        RefreshAll()
        return
    end
    EnsureCreated()
    RefreshAll()
    if event == "PLAYER_LOGIN" then
        InstallGlobalHooks()
    end
end)

-- ============================================================
-- MOVER (simple — unlock by dragging)
-- ============================================================

-- Overlay drag frame: sits on top of the secure buttons and steals
-- mouse input while the mover is unlocked. Drags the container.
local function EnsureDragOverlay()
    local c = DF.BossContainer
    if not c then return end
    if c._dragOverlay then return c._dragOverlay end

    local o = CreateFrame("Frame", nil, c)
    o:SetFrameStrata("DIALOG")
    o:SetAllPoints(c)
    o:EnableMouse(true)
    o:RegisterForDrag("LeftButton")

    local tex = o:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints(o)
    tex:SetColorTexture(0, 1, 0, 0.18)
    o.tex = tex

    local label = o:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    label:SetPoint("CENTER", o, "CENTER", 0, 0)
    label:SetText("DF Boss Frames — drag to move")
    label:SetTextColor(1, 1, 1)
    o.label = label

    o:SetScript("OnDragStart", function() c:StartMoving() end)
    o:SetScript("OnDragStop", function()
        c:StopMovingOrSizing()
        local db = DF:GetRenderBossDB()
        local point, _, _, x, y = c:GetPoint()
        db.anchor = point
        db.anchorX = x
        db.anchorY = y
        -- Re-anchor cleanly to UIParent to avoid relative-to-self drift
        c:ClearAllPoints()
        c:SetPoint(point, UIParent, point, x, y)
        -- Refresh the currently open options page so the sliders/dropdowns
        -- reflect the new drag-updated values.
        if DF.GUI and DF.GUI.RefreshCurrentPage then DF.GUI.RefreshCurrentPage() end
    end)

    o:Hide()
    c._dragOverlay = o
    return o
end

function DF:ToggleBossMover()
    EnsureCreated()
    local c = DF.BossContainer
    if not c then return end

    -- Detect whether any frame is currently shown BEFORE we toggle, so we
    -- only auto-enable test when unlocking onto empty frames.
    local anyVisible = false
    for i = 1, MAX_BOSS do
        if DF.BossFrames[i] and DF.BossFrames[i]:IsShown() then anyVisible = true; break end
    end

    local overlay = EnsureDragOverlay()

    if c._movingEnabled then
        overlay:Hide()
        c:SetMovable(true)
        c._movingEnabled = false
        -- If we auto-activated test mode on unlock, turn it back off on lock.
        if c._autoTestActivated then
            c._autoTestActivated = false
            DF:SetBossTestMode(0)
        end
        print("|cffeda55fDandersFrames:|r boss mover |cffff6666locked|r")
    else
        c:SetMovable(true)
        overlay:Show()
        c._movingEnabled = true
        if not anyVisible then
            DF:SetBossTestMode(3)
            c._autoTestActivated = true
            print("|cffeda55fDandersFrames:|r (auto-activated test mode so you can see the frames — disabled on lock)")
        end
        print("|cffeda55fDandersFrames:|r boss mover |cff66ff66unlocked|r — drag the green overlay to move")
    end
end

-- ============================================================
-- TEST MODE (Étape 1 version — inline until full TestMode module)
-- ============================================================

-- ============================================================
-- TEST MODE ANIMATION TICKER
-- Slowly drains HP, fluctuates power, and triggers fake casts.
-- ============================================================

local testTicker = CreateFrame("Frame")
testTicker:Hide()
local _testNextCast = {}
local _testLastUpdate = 0

testTicker:SetScript("OnUpdate", function(self, elapsed)
    _testLastUpdate = _testLastUpdate + elapsed
    if _testLastUpdate < 0.1 then return end
    _testLastUpdate = 0

    local now = GetTime()
    local anyActive = false
    for i = 1, MAX_BOSS do
        local f = DF.BossFrames[i]
        if f and f._testMode then
            anyActive = true
            -- HP drain + regen (bouncing)
            f._testHpDir = f._testHpDir or -1
            f._testHp = (f._testHp or 80) + f._testHpDir * (0.3 + i * 0.1)
            if f._testHp <= 10 then f._testHpDir = 1
            elseif f._testHp >= 100 then f._testHpDir = -1 end

            -- Fake power
            f._testPower = ((f._testPower or 50) + (math.random() * 4 - 2)) % 100

            -- Trigger a fake cast periodically
            if not _testNextCast[i] or now >= _testNextCast[i] then
                if DF.SimulateBossCast then
                    DF.SimulateBossCast(f, math.random() < 0.25)
                end
                _testNextCast[i] = now + 3 + math.random() * 4
            end

            UpdateFrame(f)
        end
    end

    if not anyActive then self:Hide() end
end)

local _lastTestCount
function DF:SetBossTestMode(count)
    EnsureCreated()
    count = tonumber(count) or 0
    if count < 0 then count = 0 end
    if count > MAX_BOSS then count = MAX_BOSS end
    -- Skip entirely if nothing changed (slider drag spams this).
    if count == _lastTestCount then return end
    _lastTestCount = count

    local testNames = { "Archavon", "Onyxia", "Ragnaros", "Nefarian", "Deathwing" }
    local testHp    = { 95, 72, 48, 30, 12 }

    for i = 1, MAX_BOSS do
        local f = DF.BossFrames[i]
        if f then
            if i <= count then
                f._testMode = true
                f._testName = testNames[i]
                f._testHp   = testHp[i]
                f._testHpDir = -1
                f._testPower = 50
                -- Override visibility driver to always-show in test
                if not InCombatLockdown() then
                    RegisterStateDriver(f, "visibility", "show")
                end
                UpdateFrame(f)
            else
                f._testMode = false
                f._testName = nil
                f._testHp = nil
                f._testHpDir = nil
                f._testPower = nil
                f._testModelSet = nil
                f._testAuras = nil
                _testNextCast[i] = nil
                if f.castBar then f.castBar:Hide() end
                -- Restore normal visibility driver
                if not InCombatLockdown() then
                    RegisterStateDriver(f, "visibility", "[@" .. f.unit .. ",exists]show;hide")
                end
            end
        end
    end

    if count > 0 then
        testTicker:Show()
        print(format("|cffeda55fDandersFrames:|r boss test mode — simulating %d boss%s (HP drain + fake casts)", count, count == 1 and "" or "es"))
    else
        testTicker:Hide()
        print("|cffeda55fDandersFrames:|r boss test mode |cffff6666off|r")
    end
end

-- ============================================================
-- SLASH COMMANDS (standalone for Étape 1)
--   /dfbf            → toggle mover
--   /dfbf test N     → simulate N bosses (0-5)
--   /dfbf refresh    → force refresh
-- ============================================================

SLASH_DFBF1 = "/dfbf"
SlashCmdList["DFBF"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "" then
        DF:ToggleBossMover()
        return
    end
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")
    if cmd == "test" then
        DF:SetBossTestMode(tonumber(arg) or 5)
    elseif cmd == "refresh" then
        RefreshAll()
        print("|cffeda55fDandersFrames:|r boss frames refreshed")
    elseif cmd == "config" or cmd == "options" then
        if DF.ToggleBossOptions then DF:ToggleBossOptions() end
    elseif cmd == "help" then
        print("|cffeda55fDandersFrames boss commands:|r")
        print("  /dfbf           - toggle mover lock")
        print("  /dfbf config    - open options panel")
        print("  /dfbf test N    - simulate N bosses (0-5)")
        print("  /dfbf refresh   - force refresh")
    else
        print("|cffeda55fDandersFrames:|r unknown command. Try /dfbf help")
    end
end
