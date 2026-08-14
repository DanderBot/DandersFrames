local addonName, DF = ...

-- ============================================================
-- STATUS ICONS MODULE
-- Handles creation and updates for all status icons:
-- Summon, Resurrection, Phased, AFK, Vehicle, RaidRole (MT/MA)
-- ============================================================

-- Local caching of frequently used globals
local type = type
local UnitExists = UnitExists
local UnitIsAFK = UnitIsAFK
local UnitHasVehicleUI = UnitHasVehicleUI
local UnitHasIncomingResurrection = UnitHasIncomingResurrection
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local GetPartyAssignment = GetPartyAssignment
local GetRaidRosterInfo = GetRaidRosterInfo
local IsInRaid = IsInRaid
local IsInInstance = IsInInstance
local UnitPvpClassification = UnitPvpClassification
local InCombatLockdown = InCombatLockdown
local CreateFrame = CreateFrame

-- Forward declarations for caches used in closures
local resCache = {}    -- unit -> 1 (casting) or timestamp (pending accept start time)

-- Secret value handling (Midnight-safe)
local issecretvalue = issecretvalue or function() return false end
local canaccessvalue = function(v)
    return v ~= nil and not issecretvalue(v)
end

-- ============================================================
-- ICON CREATION HELPER
-- Creates a standard status icon frame with optional text
-- ============================================================
local function CreateStatusIcon(parent, size)
    local icon = CreateFrame("Frame", nil, parent)
    icon:SetSize(size or 16, size or 16)
    icon:SetFrameLevel(parent:GetFrameLevel() + 5)
    icon:Hide()
    icon:SetIgnoreParentAlpha(true)

    icon.texture = icon:CreateTexture(nil, "OVERLAY")
    icon.texture:SetAllPoints()
    icon.texture:SetDrawLayer("OVERLAY", 6)

    -- Text fontstring for text mode
    icon.text = icon:CreateFontString(nil, "OVERLAY")
    DF:SafeSetFont(icon.text, nil, 10, "OUTLINE")
    icon.text:SetPoint("CENTER")
    icon.text:SetTextColor(1, 1, 1, 1)
    icon.text:Hide()
    
    return icon
end

-- Helper to show icon as text or texture
-- ★ EXPOSED. The preview kept its own ShowTestIconAsText, which additionally
-- re-applied the font and the text colour -- work ApplyIconSettings already does,
-- and re-applying it AFTER meant any per-state tint (the AFK icon's DND red) was
-- silently overwritten in the preview but not live. (Audit, 2026-08-07.)
local function ShowIconAsText(icon, text, showText)
    if showText then
        icon.texture:Hide()
        icon.text:SetText(text)
        icon.text:Show()
    else
        icon.text:Hide()
        icon.texture:Show()
    end
end

-- ============================================================
-- CREATE ALL STATUS ICONS FOR A FRAME
-- Called from CreateFrameElementsExtended and CreateUnitFrame
-- ============================================================
function DF:CreateStatusIcons(frame)
    if not frame or not frame.contentOverlay then return end
    
    local overlay = frame.contentOverlay
    
    -- ========================================
    -- SUMMON ICON (incoming summon status)
    -- ========================================
    frame.summonIcon = CreateStatusIcon(overlay, 16)
    frame.summonIcon:SetPoint("CENTER", frame, "CENTER", 0, 0)
    DF:SetUpgradedStatusIcon(frame.summonIcon.texture, "Interface\\RaidFrame\\Raid-Icon-SummonPending")
    frame.summonIcon.text:SetTextColor(0.6, 0.2, 1, 1)  -- Purple for summon
    
    -- ========================================
    -- RESURRECTION ICON (incoming res status)
    -- ========================================
    frame.resurrectionIcon = CreateStatusIcon(overlay, 16)
    frame.resurrectionIcon:SetPoint("CENTER", frame, "CENTER", 0, 10)
    DF:SetUpgradedStatusIcon(frame.resurrectionIcon.texture, "Interface\\RaidFrame\\Raid-Icon-Rez")
    frame.resurrectionIcon.text:SetTextColor(0.2, 1, 0.2, 1)  -- Green for res
    frame.resurrectionIcon.unitFrame = frame
    frame.resurrectionIcon:EnableMouse(true)
    -- BOTH propagation setters are protected on 12.1 (ADDON_ACTION_BLOCKED under
    -- combat lockdown — Motion proven by the #1029 field log, not just Clicks);
    -- skip both in combat — a res icon can be (re)built on a roster change
    -- mid-combat, and it still functions without propagation until the next
    -- out-of-combat rebuild re-applies it.
    if not InCombatLockdown() then
        if frame.resurrectionIcon.SetPropagateMouseMotion then
            frame.resurrectionIcon:SetPropagateMouseMotion(true)
        end
        if frame.resurrectionIcon.SetPropagateMouseClicks then
            frame.resurrectionIcon:SetPropagateMouseClicks(true)
        end
    end
    if frame.resurrectionIcon.SetMouseClickEnabled then
        frame.resurrectionIcon:SetMouseClickEnabled(false)
    end
    frame.resurrectionIcon:SetScript("OnEnter", function(self)
        local db = DF:GetFrameDB(self.unitFrame)
        if not db or not db.tooltipResurrectionEnabled then return end
        local unit = self.unitFrame and self.unitFrame.unit
        local state = unit and resCache[unit]
        -- Resolved here, not at file scope: the locale table is populated by the
        -- Locales/*.lua files and this handler runs long after load. Same idiom as
        -- the other consumer further down this file.
        local L = DF.L
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        GameTooltip:ClearLines()
        if state == 1 then
            GameTooltip:AddLine(L["Resurrection Incoming"], 0.2, 1, 0.2)
            GameTooltip:AddLine(L["A resurrection is being cast on this player."], 0.8, 0.8, 0.8, true)
        elseif type(state) == "number" then
            GameTooltip:AddLine(L["Resurrection Pending"], 1, 1, 0)
            GameTooltip:AddLine(L["Waiting for this player to accept the resurrection."], 0.8, 0.8, 0.8, true)
        else
            GameTooltip:AddLine(L["Resurrection"], 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    frame.resurrectionIcon:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)

    -- ========================================
    -- PHASED ICON (unit is phased/different instance)
    -- ========================================
    frame.phasedIcon = CreateStatusIcon(overlay, 16)
    frame.phasedIcon:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
    DF:SetUpgradedStatusIcon(frame.phasedIcon.texture, "Interface\\TargetingFrame\\UI-PhasingIcon")
    frame.phasedIcon.text:SetTextColor(0.5, 0.5, 1, 1)  -- Blue-ish for phased
    
    -- ========================================
    -- AFK ICON (unit is away from keyboard)
    -- ========================================
    frame.afkIcon = CreateStatusIcon(overlay, 32)
    frame.afkIcon:SetPoint("CENTER", frame, "CENTER", 0, 0)
    DF:SetUpgradedStatusIcon(frame.afkIcon.texture, "Interface\\FriendsFrame\\StatusIcon-Away")
    DF:SafeSetFont(frame.afkIcon.text, nil, 12, "OUTLINE")
    frame.afkIcon.text:SetTextColor(1, 0.5, 0, 1)  -- Orange for AFK
    -- Timer text (separate from main text, shown below/after)
    frame.afkIcon.timerText = frame.afkIcon:CreateFontString(nil, "OVERLAY")
    DF:SafeSetFont(frame.afkIcon.timerText, nil, 10, "OUTLINE")
    frame.afkIcon.timerText:SetPoint("TOP", frame.afkIcon.text, "BOTTOM", 0, -1)
    frame.afkIcon.timerText:SetTextColor(1, 0.5, 0, 1)
    frame.afkIcon.timerText:Hide()
    
    -- ========================================
    -- VEHICLE ICON (unit in vehicle)
    -- ========================================
    frame.vehicleIcon = CreateStatusIcon(overlay, 16)
    frame.vehicleIcon:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    DF:SetUpgradedStatusIcon(frame.vehicleIcon.texture, "Interface\\Vehicles\\UI-Vehicles-Raid-Icon")
    frame.vehicleIcon.text:SetTextColor(0.4, 0.8, 1, 1)  -- Light blue for vehicle
    
    -- ========================================
    -- RAID ROLE ICON (Main Tank / Main Assist)
    -- ========================================
    frame.raidRoleIcon = CreateStatusIcon(overlay, 12)
    frame.raidRoleIcon:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 2, 2)
    frame.raidRoleIcon.text:SetTextColor(1, 1, 0, 1)  -- Yellow for raid role
    -- Texture set dynamically based on role

    -- ========================================
    -- BG OBJECTIVE CARRIER ICON (flag / orb carrier)
    -- ========================================
    frame.bgCarrierIcon = CreateStatusIcon(overlay, 18)
    -- Seed only — ApplyIconSettings ClearAllPoints/SetPoints this from the db on every
    -- update. Kept in step with Config's default (TOPRIGHT -2,-2) by convention, so
    -- reading this line does not imply a placement the addon no longer uses.
    frame.bgCarrierIcon:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
    DF:SetUpgradedStatusIcon(frame.bgCarrierIcon.texture, "Interface\\Icons\\inv_bannerpvp_03")
    frame.bgCarrierIcon.text:SetTextColor(1, 0.82, 0, 1)  -- Gold for objective carrier

    -- ========================================
    -- COMBAT ICON (unit is in combat)
    -- ========================================
    frame.combatIcon = CreateStatusIcon(overlay, 16)
    frame.combatIcon:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)  -- free corner (avoids the CENTER cluster + BG-carrier)
    -- Classic crossed-swords combat glyph. UI-StateIcon is a sheet (swords +
    -- resting); crop to the swords quadrant. Set directly (NOT SetUpgradedStatusIcon,
    -- which would reset the texcoord to the full sheet). ApplyIconSettings leaves
    -- texcoord alone, so this crop persists.
    frame.combatIcon.texture:SetTexture("Interface\\CharacterFrame\\UI-StateIcon")
    frame.combatIcon.texture:SetTexCoord(0.5, 1.0, 0, 0.49)
end

-- ============================================================
-- HELPER: Apply the AFK-style timer text settings (font, size, outline,
-- colour, position). Dedicated <prefix>Timer* keys take precedence, falling
-- back to the global status-icon font so existing profiles keep their look.
-- Shared by the live render (ApplyIconSettings) and Test Mode.
-- ============================================================
function DF:ApplyTimerTextSettings(icon, db, prefix)
    local t = icon and icon.timerText
    if not t or not db or not prefix then return end

    local font    = db[prefix .. "TimerFont"]     or db.statusIconFont or "Fonts\\FRIZQT__.TTF"
    local size    = db[prefix .. "TimerFontSize"] or ((db.statusIconFontSize or 12) - 2)
    local outline = db[prefix .. "TimerOutline"]  or db.statusIconFontOutline or "OUTLINE"
    -- Font + shadow via SafeSetFont (font-family path). Fontstring-level
    -- SetShadowColor/Offset is a silent no-op on 12.0.7, so the shadow must ride
    -- the font object. SetFontObject resets vertex colour — capture + restore it.
    local cr, cg, cb, ca = t:GetTextColor()
    DF:SafeSetFont(t, font, size, outline)

    local c = db[prefix .. "TimerColor"] or db[prefix .. "TextColor"]
    if c then
        t:SetTextColor(c.r or 1, c.g or 1, c.b or 1, c.a or 1)
    else
        t:SetTextColor(cr, cg, cb, ca)
    end

    -- LEFT-justify the timer instead of centring it. CENTRE justify — even inside
    -- a fixed-width box — re-measures the text's INK box each tick, and a narrow
    -- "1" shrinks that ink box, so a centred string nudges left/right every second.
    -- The seconds change each tick, so pin the LEFT edge and let the digits sit at
    -- fixed offsets to the right. The time is also zero-padded to MM:SS (constant
    -- char count, see FormatAFKTime), so the string width never changes either —
    -- it stays put across the 9:59 -> 10:00 boundary too. Anchor the left edge
    -- ~half a typical MM:SS left of centre so it reads centred under the icon.
    t:SetJustifyH("LEFT")
    -- Centre the timer under the icon. SafeSetFont's font-family path renders via
    -- SetTextScale, which pivots about the fontstring BOX's centre — so size the box
    -- to the rendered text width and anchor its centre under the icon: the text then
    -- scales about its own centre and stays put, LEFT-justified so the changing
    -- seconds never re-centre (no wobble).
    --
    -- Measure a fixed sample ("00:00", or "00:00:00" past an hour), NOT the live
    -- string (which may be empty when this runs). Re-measure EVERY call rather than
    -- caching: GetStringWidth taken before the font/scale was ready returned the
    -- unscaled (BASE_FONT_SIZE) width, and caching that stuck a too-narrow box that
    -- truncated; measured fresh once the font is live it already reflects the
    -- rendered width, so no scale factor is needed. The sample is constant, so the
    -- width never changes tick-to-tick.
    local cur = t:GetText() or ""
    local sample = (#cur >= 8) and "00:00:00" or "00:00"
    t:SetText(sample)
    local w = t:GetStringWidth() or 0
    t:SetText(cur)
    if w <= 0 then w = size * 2.4 end
    -- Box is 1px wider than the text so the last glyph never clips, but anchor on
    -- half the TEXT width (not the padded box) so the digits sit dead centre.
    t:SetWidth(w + 1)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", icon, "BOTTOM", (db[prefix .. "TimerX"] or 0) - w / 2, db[prefix .. "TimerY"] or -1)
end

-- ============================================================
-- HELPER: Stable anchor for status text that updates rapidly (the AFK
-- "show as text" line, which bakes the ticking timer into the string).
-- CENTRE auto-measures the ink box every tick, so the changing timer nudges the
-- whole string left/right. LEFT-justify instead: pin the left edge (the constant
-- label) and let the changing timer dangle off the right. Cache the centring
-- nudge keyed by string LENGTH, so a constant-length string (the time is
-- zero-padded to MM:SS) only re-measures when the structure actually changes,
-- never per tick — which is what keeps it from wobbling.
-- ============================================================
function DF:ApplyStableTextAnchor(fs, icon)
    if not fs or not icon then return end
    fs:SetJustifyH("LEFT")
    local text = fs:GetText() or ""
    if fs._dfStableLen ~= #text then
        local w = fs:GetStringWidth()
        if w and w > 0 then
            fs._dfStableLen = #text
            fs._dfStableNudge = w / 2
        end
    end
    fs:ClearAllPoints()
    fs:SetPoint("LEFT", icon, "CENTER", -(fs._dfStableNudge or 0), 0)
end

-- ============================================================
-- HELPER: Apply icon positioning from settings
-- ============================================================
-- ★ EXPOSED so the preview uses this exact geometry rather than restating it.
-- UpdateTestStatusIcons hand-rolled scale / anchor / x / y / alpha / frameLevel for
-- all eight icons -- pure db maths with no unit reads, i.e. no reason to fork.
-- (Audit, 2026-08-07.)
local function ApplyIconSettings(icon, db, prefix)
    if not icon or not db then return end
    
    local scale = db[prefix .. "Scale"] or 1
    local anchor = db[prefix .. "Anchor"] or "CENTER"
    local x = db[prefix .. "X"] or 0
    local y = db[prefix .. "Y"] or 0
    local alpha = db[prefix .. "Alpha"] or 1
    local frameLevel = db[prefix .. "FrameLevel"] or 30
    
    icon:SetScale(scale)
    icon:ClearAllPoints()
    -- icon -> contentOverlay -> unit frame.
    local frame = icon:GetParent() and icon:GetParent():GetParent()
    icon:SetPoint(anchor, frame, anchor, x, y)
    -- ★ THE ONE PLACE THESE ICONS' ALPHA IS SET, so the out-of-range / dead fade
    -- belongs here rather than in a second pass that would fight it.
    -- ☠ Before this they could not fade LIVE at all: CreateStatusIcon sets
    -- SetIgnoreParentAlpha(true) so the whole-frame cascade cannot reach them, and
    -- ElementAppearance never named any of the eight. Only the preview dimmed them,
    -- off its own hand-written table -- the preview showing something live was
    -- structurally incapable of. Summon and resurrection are exempt from the RANGE
    -- half (not the dead half); DF:GetStatusIconFadeAlpha holds the reasoning.
    if DF.GetStatusIconFadeAlpha then
        alpha = alpha * DF:GetStatusIconFadeAlpha(frame, prefix)
    end
    icon:SetAlpha(alpha)

    icon:SetFrameLevel(frame:GetFrameLevel() + frameLevel)
    
    -- Apply status icon font settings to text. Route through SafeSetFont so the
    -- shadow lands on the font-family's per-alphabet font objects — 12.0.7 no
    -- longer renders fontstring-level SetShadowColor/Offset (it's a silent no-op).
    if icon.text then
        local font = db.statusIconFont or "Fonts\\FRIZQT__.TTF"
        local fontSize = db.statusIconFontSize or 12
        local outline = db.statusIconFontOutline or "OUTLINE"

        -- SafeSetFont swaps the font object, which resets vertex colour to white;
        -- capture the current colour so non-overridden icons keep their tint.
        local cr, cg, cb, ca = icon.text:GetTextColor()
        DF:SafeSetFont(icon.text, font, fontSize, outline)

        -- Apply text color from settings (falls back to the captured colour).
        local textColor = db[prefix .. "TextColor"]
        if textColor then
            icon.text:SetTextColor(textColor.r or 1, textColor.g or 1, textColor.b or 1, 1)
        else
            icon.text:SetTextColor(cr, cg, cb, ca)
        end
    end
    
    -- Also apply to timer text if it exists (AFK icon) — dedicated controls.
    if icon.timerText then
        DF:ApplyTimerTextSettings(icon, db, prefix)
    end
end

-- ⚠ A METHOD, not a bare alias. The eight preview call sites use `DF:` (colon), so a
-- plain `DF.ApplyStatusIconSettings = ApplyIconSettings` shifted every argument by one
-- and blew up on `prefix .. "Scale"` with prefix = the db table. Live keeps calling the
-- local directly.
function DF:ApplyStatusIconSettings(icon, db, prefix)
    ApplyIconSettings(icon, db, prefix)
end
function DF:ShowStatusIconAsText(icon, text, showText)
    ShowIconAsText(icon, text, showText)
end

-- ============================================================
-- UPDATE SUMMON ICON
-- Shows pending/accepted/declined summon status
-- ============================================================
function DF:UpdateSummonIcon(frame)
    if not frame or not frame.unit or not frame.summonIcon then return end
    
    local db = DF:GetFrameDB(frame)
    
    -- Check if enabled
    if not db.summonIconEnabled then
        frame.summonIcon:Hide()
        return
    end
    
    -- Hide in combat check
    if db.summonIconHideInCombat and DF.playerInCombat then
        frame.summonIcon:Hide()
        return
    end
    
    local unit = frame.unit
    local showIcon = false
    local texture = nil
    local statusText = nil

    -- If the unit no longer exists (player left group), clear the icon immediately
    if not UnitExists(unit) then
        frame.summonIcon:Hide()
        return
    end

    -- Solo players cannot be summoned; incoming-summon API may return stale data
    if not IsInGroup() then
        frame.summonIcon:Hide()
        return
    end

    -- Check for incoming summon (secret-safe)
    if C_IncomingSummon and C_IncomingSummon.HasIncomingSummon then
        local hasSummon = nil
        pcall(function()
            hasSummon = C_IncomingSummon.HasIncomingSummon(unit)
        end)
        
        if canaccessvalue(hasSummon) and hasSummon then
            local summonStatus = nil
            pcall(function()
                summonStatus = C_IncomingSummon.IncomingSummonStatus(unit)
            end)
            
            if canaccessvalue(summonStatus) then
                if summonStatus == Enum.SummonStatus.Pending then
                    texture = "Interface\\RaidFrame\\Raid-Icon-SummonPending"
                    statusText = db.summonIconTextPending or "Summon"
                    showIcon = true
                elseif summonStatus == Enum.SummonStatus.Accepted then
                    texture = "Interface\\RaidFrame\\Raid-Icon-SummonAccepted"
                    statusText = db.summonIconTextAccepted or "Accepted"
                    showIcon = true
                elseif summonStatus == Enum.SummonStatus.Declined then
                    texture = "Interface\\RaidFrame\\Raid-Icon-SummonDeclined"
                    statusText = db.summonIconTextDeclined or "Declined"
                    showIcon = true
                end
            end
        end
    end
    
    if showIcon then
        DF:SetUpgradedStatusIcon(frame.summonIcon.texture, texture)
        ApplyIconSettings(frame.summonIcon, db, "summonIcon")
        
        -- Show as text or icon based on setting
        ShowIconAsText(frame.summonIcon, statusText, db.summonIconShowText)
        frame.summonIcon:Show()
    else
        frame.summonIcon:Hide()
    end
end

-- ============================================================
-- UPDATE RESURRECTION ICON
-- Res icon states: green during cast, yellow
-- when cast finishes and unit still dead (pending accept).
-- Timer cleans up stale entries (unit alive, left group, or
-- pending accept expired after 60s - the WoW accept window).
-- ============================================================

local resTimer

local RES_ACCEPT_TIMEOUT = 60  -- WoW's res accept window is 60 seconds

local function ResTimerCleanup()
    local hasEntries = false
    local now = GetTime()
    for unit, value in next, resCache do
        if not (UnitExists(unit) and UnitIsDeadOrGhost(unit)) then
            -- Unit alive or gone, clear
            resCache[unit] = nil
            local frame = DF.unitFrameMap and DF.unitFrameMap[unit]
            if frame and frame.resurrectionIcon then
                frame.resurrectionIcon:Hide()
            end
        elseif value ~= 1 and (now - value) > RES_ACCEPT_TIMEOUT then
            -- Pending accept expired (cancelled cast or they didn't accept in time)
            resCache[unit] = nil
            local frame = DF.unitFrameMap and DF.unitFrameMap[unit]
            if frame and frame.resurrectionIcon then
                frame.resurrectionIcon:Hide()
            end
        else
            hasEntries = true
        end
    end
    if not hasEntries and resTimer then
        resTimer:Cancel()
        resTimer = nil
    end
end

function DF:UpdateResurrectionIcon(frame)
    if not frame or not frame.unit or not frame.resurrectionIcon then return end
    
    local db = DF:GetFrameDB(frame)
    
    if not db.resurrectionIconEnabled then
        frame.resurrectionIcon:Hide()
        return
    end
    
    local unit = frame.unit
    
    -- Only process if unit is dead/ghost
    if UnitIsDeadOrGhost(unit) then
        if UnitHasIncomingResurrection(unit) then
            -- Cast in progress → green
            if resCache[unit] ~= 1 then
                resCache[unit] = 1
                resTimer = resTimer or C_Timer.NewTicker(0.25, ResTimerCleanup)
            end
            DF:SetUpgradedStatusIcon(frame.resurrectionIcon.texture, "Interface\\RaidFrame\\Raid-Icon-Rez")
            frame.resurrectionIcon.texture:SetVertexColor(0, 1, 0, 1)
            ApplyIconSettings(frame.resurrectionIcon, db, "resurrectionIcon")
            -- ☠ THIS CALL WAS MISSING LIVE. Every other status icon routes its show
            -- through ShowIconAsText; the resurrection icon did not, so Show Text and
            -- Casting Text were inert here and the fontstring kept whatever visibility
            -- it was last left with. The preview did honour them, which is how the
            -- divergence surfaced. (Audit, 2026-08-07.)
            ShowIconAsText(frame.resurrectionIcon, db.resurrectionIconTextCasting or "Res...", db.resurrectionIconShowText)
            frame.resurrectionIcon:Show()
            return
        elseif resCache[unit] == 1 then
            -- Was casting, now stopped → pending accept (yellow)
            -- Store timestamp so we can expire after 60s
            resCache[unit] = GetTime()
            DF:SetUpgradedStatusIcon(frame.resurrectionIcon.texture, "Interface\\RaidFrame\\Raid-Icon-Rez")
            frame.resurrectionIcon.texture:SetVertexColor(1, 1, 0, 0.75)
            ApplyIconSettings(frame.resurrectionIcon, db, "resurrectionIcon")
            -- See the note on the casting branch above.
            ShowIconAsText(frame.resurrectionIcon, db.resurrectionIconTextCasting or "Res...", db.resurrectionIconShowText)
            frame.resurrectionIcon:Show()
            return
        elseif resCache[unit] and resCache[unit] ~= 1 then
            -- Still showing pending accept (check not expired)
            if (GetTime() - resCache[unit]) <= RES_ACCEPT_TIMEOUT then
                DF:SetUpgradedStatusIcon(frame.resurrectionIcon.texture, "Interface\\RaidFrame\\Raid-Icon-Rez")
                frame.resurrectionIcon.texture:SetVertexColor(1, 1, 0, 0.75)
                ApplyIconSettings(frame.resurrectionIcon, db, "resurrectionIcon")
                -- See the note on the casting branch above.
                ShowIconAsText(frame.resurrectionIcon, db.resurrectionIconTextCasting or "Res...", db.resurrectionIconShowText)
                frame.resurrectionIcon:Show()
                return
            else
                resCache[unit] = nil
            end
        end
    else
        -- Unit is alive, clear any cache
        resCache[unit] = nil
    end
    
    frame.resurrectionIcon:Hide()
end

function DF:HasPendingResurrection(unit)
    return resCache[unit] ~= nil
end

-- ============================================================
-- PHASED ICON (Grid2-style cached polling + event-driven)
-- ============================================================
-- UnitPhaseReason() only returns reliable results within ~250 yards.
-- Beyond that it returns nil, which looks like "not phased".
-- Grid2 solves this with:
--   1. A per-unit cache (avoids redundant indicator updates)
--   2. A 1-second polling timer with UnitDistanceSquared gating
--   3. Events (UNIT_PHASE etc.) for instant updates when they fire
-- We follow the same approach, with one difference:
-- Grid2 stops the timer inside instances; we keep it running but skip
-- distance gating, so UnitInOtherParty and UnitPhaseReason still poll.
-- CheckUnitPhase checks UnitInOtherParty first (returns -1 for LFG),
-- then UnitPhaseReason/UnitInPhase for actual phasing.
-- ============================================================

local UnitDistanceSquared = UnitDistanceSquared
local UnitInOtherParty = UnitInOtherParty
local UnitPhaseReason = UnitPhaseReason
local UnitInPhase = UnitInPhase
local IsInInstance = IsInInstance

-- Cache tables (keyed by unit token, e.g. "raid1", "party2")
-- phasedCache[unit] = phaseReason number (phased), -1 (LFG), false (checked, not phased), or nil (not yet checked)
-- phasedRange[unit] = true if within 250yd, false/nil otherwise
local phasedCache = {}
local phasedRange = {}
local phasedTicker = nil
local phasedTimerRunning = false

-- Clear cache for a specific unit (call when unit leaves group or frame changes unit)
function DF:ResetPhasedCache(unit)
    if unit then
        phasedCache[unit] = nil  -- nil = not yet checked, will be re-evaluated
        phasedRange[unit] = nil
    end
end

-- Clear all phased caches (call on zone change, group change, etc.)
function DF:WipePhasedCache()
    wipe(phasedCache)
    wipe(phasedRange)
end

-- Check phase status for a single unit and update cache.
-- Checks UnitInOtherParty (LFG/-1), then UnitPhaseReason/UnitInPhase.
-- Returns true if the cached value changed.
local function CheckUnitPhase(unit)
    local phased = false  -- false = checked, not phased (distinct from nil = not yet checked)
    
    -- Check LFG/other party first (unit in different instance group)
    -- This covers the case where UnitPhaseReason returns nil because the unit
    -- is in a completely different instance, not just a different "phase"
    if UnitInOtherParty then
        local ok, inOther = pcall(UnitInOtherParty, unit)
        if ok and canaccessvalue(inOther) and inOther then
            phased = -1
        end
    end
    
    -- If not in other party, check phase status
    if phased == false then
        if UnitPhaseReason then
            local ok, result = pcall(UnitPhaseReason, unit)
            if ok and canaccessvalue(result) and result then
                phased = result
            end
        elseif UnitInPhase then
            local ok, result = pcall(UnitInPhase, unit)
            if ok and canaccessvalue(result) and not result then
                phased = true  -- UnitInPhase returns false when phased
            end
        end
    end
    
    -- phased is false if not phased, or a truthy value if phased
    if phased ~= phasedCache[unit] then
        phasedCache[unit] = phased
        return true
    end
    return false
end

-- Event-driven update for a single unit (called from UNIT_PHASE, UNIT_FLAGS,
-- UNIT_OTHER_PARTY_CHANGED). Updates cache and refreshes the icon if changed.
function DF:UpdatePhasedCacheForUnit(unit)
    if not unit then return end
    if CheckUnitPhase(unit) then
        -- Cache changed — find and update the frame
        local frame = DF.unitFrameMap and DF.unitFrameMap[unit]
        if frame and frame.phasedIcon and frame.dfEventsEnabled ~= false then
            DF:UpdatePhasedIcon(frame)
        end
    end
end

-- Polling timer callback — iterates all grouped units (Grid2 style).
-- In the open world, uses UnitDistanceSquared gating for UnitPhaseReason reliability.
-- Inside instances, still polls (without distance gating) so UnitInOtherParty is caught.
local function PhasedTimerUpdate()
    if not DF.IterateAllFrames then return end
    
    local inInstance = IsInInstance()
    
    DF:IterateAllFrames(function(frame)
        if not frame or not frame:IsShown() or not frame.unit or not frame.phasedIcon then return end
        local unit = frame.unit
        
        if inInstance then
            -- Inside instances: UnitDistanceSquared returns nil, skip distance gating.
            -- Still check phase status directly — catches UnitInOtherParty and
            -- UnitPhaseReason for units that may be in different phases/instances.
            if CheckUnitPhase(unit) then
                DF:UpdatePhasedIcon(frame)
            end
        else
            -- Open world: use distance gating for UnitPhaseReason reliability
            -- (UnitPhaseReason only works within ~250 yards)
            -- pcall(fn, arg), not pcall(closure): this runs per unit on a 1s
            -- ticker in the open world, and the closure form allocated one each
            -- time. Same form as the UnitInOtherParty call earlier in this file.
            local ok, distSq, valid = pcall(UnitDistanceSquared, unit)
            if ok and valid and canaccessvalue(distSq) then
                local inrange = distSq < 62500  -- 250*250
                if inrange ~= phasedRange[unit] then
                    phasedRange[unit] = inrange
                    -- Range changed — re-evaluate phase
                    if CheckUnitPhase(unit) then
                        DF:UpdatePhasedIcon(frame)
                    end
                end
            else
                -- UnitDistanceSquared not valid (too far, not in group, cross-realm)
                -- Fall back to direct phase check without distance gating
                if CheckUnitPhase(unit) then
                    DF:UpdatePhasedIcon(frame)
                end
            end
        end
    end)
end

-- Start the phased polling timer
function DF:StartPhasedTimer()
    if phasedTimerRunning then return end
    phasedTicker = C_Timer.NewTicker(1, PhasedTimerUpdate)
    phasedTimerRunning = true
end

-- Auto-start when addon is ready (called from PLAYER_LOGIN or first group join)
-- We start it once and let it run — the callback is cheap when solo/not in group.
local phasedTimerStartFrame = CreateFrame("Frame")
phasedTimerStartFrame:RegisterEvent("PLAYER_LOGIN")
phasedTimerStartFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
phasedTimerStartFrame:SetScript("OnEvent", function(self, event)
    if not phasedTimerRunning and DF.StartPhasedTimer then
        DF:StartPhasedTimer()
        -- Timer is running, no need to listen for more events
        self:UnregisterAllEvents()
    end
end)

-- ============================================================
-- UPDATE PHASED ICON (reads from cache, updates visuals)
-- Called from: event handlers, polling timer, FullFrameRefresh
-- ============================================================
function DF:UpdatePhasedIcon(frame)
    if not frame or not frame.unit or not frame.phasedIcon then return end
    
    local db = DF:GetFrameDB(frame)
    
    -- Check if enabled
    if not db.phasedIconEnabled then
        frame.phasedIcon:Hide()
        return
    end
    
    -- Hide in combat check
    if db.phasedIconHideInCombat and DF.playerInCombat then
        frame.phasedIcon:Hide()
        return
    end
    
    local unit = frame.unit
    
    -- Populate cache on first access for this unit (e.g., from FullFrameRefresh).
    -- Without this, the cache is empty until the polling timer runs (up to 1 second)
    -- and the icon would never show on initial frame creation.
    if phasedCache[unit] == nil and UnitExists(unit) then
        CheckUnitPhase(unit)
    end
    
    local cached = phasedCache[unit]
    
    if cached then
        -- cached == -1 means LFG (other party), anything else means phased
        local isLFG = (cached == -1)
        if isLFG and db.phasedIconShowLFGEye then
            DF:SetUpgradedStatusIcon(frame.phasedIcon.texture, "Interface\\LFGFrame\\LFG-Eye")
        else
            DF:SetUpgradedStatusIcon(frame.phasedIcon.texture, "Interface\\TargetingFrame\\UI-PhasingIcon")
        end
        ApplyIconSettings(frame.phasedIcon, db, "phasedIcon")
        ShowIconAsText(frame.phasedIcon, db.phasedIconText or "Phased", db.phasedIconShowText)
        frame.phasedIcon:Show()
    else
        frame.phasedIcon:Hide()
    end
end

-- ============================================================
-- UPDATE AFK ICON
-- Shows when unit is AFK with optional timer
-- ============================================================

-- Cache for AFK start times (GUID -> timestamp)
local afkStartTimes = {}

-- Cache for last confirmed AFK state (GUID -> "AFK"/false/nil)
local afkStateCache = {}

local function GetAFKKey(unit)
    -- A unit's GUID can be a SECRET value in 12.0, and a secret cannot be used as a
    -- table key — doing so throws "cannot be indexed with secret keys" (this was
    -- crashing UpdateAFKIcon / ClearAFKCache on live). Check accessibility BEFORE
    -- any truthiness test on the GUID, and fall back to the unit token (a plain
    -- string, never secret) for those units.
    local guid = UnitGUID(unit)
    if canaccessvalue(guid) and guid then return guid end
    return unit
end

-- Format seconds as M:SS or H:MM:SS
-- ⚠ Published as DF:FormatAFKTime below. The preview cannot call a file-local, so it
-- kept a byte-identical copy of this and the two were free to drift -- same shape as
-- ApplyIconSettings, which is published for exactly the same reason.
local function FormatAFKTime(seconds)
    if seconds < 3600 then
        return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
    else
        local hours = math.floor(seconds / 3600)
        local mins = math.floor((seconds % 3600) / 60)
        local secs = seconds % 60
        return string.format("%02d:%02d:%02d", hours, mins, secs)
    end
end

-- A METHOD, not a bare alias: the preview calls it with `DF:` (colon), so assigning the
-- local directly would shift every argument by one — the same trap the note on
-- DF:ApplyStatusIconSettings records. Live keeps calling the local.
function DF:FormatAFKTime(seconds)
    return FormatAFKTime(seconds)
end

-- ★ isAFKOverride lets the PREVIEW drive this without a real unit. Everything else --
-- the enabled gate, the combat gate, ApplyIconSettings, the timer/text mode split and
-- the stable text anchor -- is shared, so the preview cannot drift from live.
--
-- ☠ Do not reinstate a copy of this in TestMode. The one that was there restated ~45
-- lines of this function, comments included, and had already lost the
-- afkIconHideInCombat gate: the preview kept the icon up in combat while live hid it,
-- so that setting was not previewable. The timer keying needs nothing special either --
-- GetAFKKey falls back to the unit token when there is no accessible GUID, which is
-- exactly what a test frame has.
function DF:UpdateAFKIcon(frame, isAFKOverride)
    if not frame or not frame.unit or not frame.afkIcon then return end
    
    local db = DF:GetFrameDB(frame)
    
    -- Check if enabled
    if not db.afkIconEnabled then
        frame.afkIcon:Hide()
        if frame.afkIcon.timerText then frame.afkIcon.timerText:Hide() end
        return
    end
    
    -- Hide in combat check
    if db.afkIconHideInCombat and DF.playerInCombat then
        frame.afkIcon:Hide()
        if frame.afkIcon.timerText then frame.afkIcon.timerText:Hide() end
        return
    end
    
    local unit = frame.unit
    local showIcon = false

    -- ⚠ AFK ONLY. UnitIsDND was consulted here and rendered on this same widget; it was
    -- dropped deliberately (Krathe, 2026-08-08 — "somewhat useless info on a raid frame").
    -- A DND unit now shows nothing. Re-adding it means a second cache state AND its own
    -- art: sharing the clock is what made DND indistinguishable from AFK in the first place.
    -- Check AFK status (secret-safe), keyed by GUID so the timer survives transient nil
    -- returns (cross-realm latency, instance loading).
    -- ☠ TEST FRAMES GET THEIR OWN CACHE LANE. Pooled test frames carry REAL unit
    -- tokens ("player", "party1", "raid1"...), so GetAFKKey resolves REAL GUIDs for
    -- them -- and the preview's forced isAFK stamped genuine group members' keys
    -- into afkStateCache/afkStartTimes, restarting their live AFK clocks. (An
    -- earlier claim that GetAFKKey "falls back to the unit token" for test frames
    -- was wrong: it only falls back when the GUID is secret or inaccessible, which
    -- a real token's is not.) Same pathway, different KEY -- the preview still runs
    -- this live renderer, per the previews-run-live rule.
    local afkKey = frame.dfIsTestFrame and ("test:" .. unit) or GetAFKKey(unit)
    local isAFK = nil
    if isAFKOverride ~= nil then
        -- Preview: the caller supplies the state. Still goes through the cache below,
        -- so the elapsed-timer bookkeeping is the same code in both paths.
        isAFK = isAFKOverride and true or false
    else
        pcall(function() isAFK = UnitIsAFK(unit) end)
    end
    if canaccessvalue(isAFK) then
        afkStateCache[afkKey] = isAFK and "AFK" or false
    end

    if afkStateCache[afkKey] == "AFK" then
        if not afkStartTimes[afkKey] then
            afkStartTimes[afkKey] = GetTime()
        end
        showIcon = true
    else
        afkStartTimes[afkKey] = nil
    end

    if showIcon then
        ApplyIconSettings(frame.afkIcon, db, "afkIcon")

        local statusText = db.afkIconText or "AFK"
        -- Text colour comes from afkIconTextColor, applied by ApplyIconSettings above.
        do
            local showTimer = db.afkIconShowTimer ~= false

            -- Calculate timer if enabled
            if showTimer and afkStartTimes[afkKey] then
                local elapsed = math.floor(GetTime() - afkStartTimes[afkKey])
                local timerStr = FormatAFKTime(elapsed)

                if db.afkIconShowText then
                    -- Text mode: show "AFK 1:23"
                    statusText = statusText .. " " .. timerStr
                    if frame.afkIcon.timerText then frame.afkIcon.timerText:Hide() end
                else
                    -- Icon mode: show timer below icon
                    if frame.afkIcon.timerText then
                        frame.afkIcon.timerText:SetText(timerStr)
                        frame.afkIcon.timerText:Show()
                    end
                end
            else
                if frame.afkIcon.timerText then frame.afkIcon.timerText:Hide() end
            end
        end

        ShowIconAsText(frame.afkIcon, statusText, db.afkIconShowText)
        if db.afkIconShowText and frame.afkIcon.text then
            DF:ApplyStableTextAnchor(frame.afkIcon.text, frame.afkIcon)
        end
        frame.afkIcon:Show()
    else
        frame.afkIcon:Hide()
        if frame.afkIcon.timerText then frame.afkIcon.timerText:Hide() end
    end
end


-- ============================================================
-- UPDATE VEHICLE ICON
-- Shows when unit is in a vehicle
-- ============================================================
function DF:UpdateVehicleIcon(frame)
    if not frame or not frame.unit or not frame.vehicleIcon then return end
    
    local db = DF:GetFrameDB(frame)
    
    -- Check if enabled
    if not db.vehicleIconEnabled then
        frame.vehicleIcon:Hide()
        return
    end
    
    -- Hide in combat check
    if db.vehicleIconHideInCombat and DF.playerInCombat then
        frame.vehicleIcon:Hide()
        return
    end
    
    local unit = frame.unit
    local showIcon = false
    
    -- Check vehicle status (secret-safe)
    local hasVehicle = nil
    pcall(function()
        hasVehicle = UnitHasVehicleUI(unit)
    end)
    
    if canaccessvalue(hasVehicle) and hasVehicle then
        showIcon = true
    end
    
    if showIcon then
        ApplyIconSettings(frame.vehicleIcon, db, "vehicleIcon")
        ShowIconAsText(frame.vehicleIcon, db.vehicleIconText or "Vehicle", db.vehicleIconShowText)
        frame.vehicleIcon:Show()
    else
        frame.vehicleIcon:Hide()
    end
end

-- ============================================================
-- UPDATE RAID ROLE ICON
-- Shows Main Tank / Main Assist assignment
-- ============================================================

function DF:UpdateRaidRoleIcon(frame)
    if not frame or not frame.unit or not frame.raidRoleIcon then return end
    
    local db = DF:GetFrameDB(frame)
    
    -- Check if enabled
    if not db.raidRoleIconEnabled then
        frame.raidRoleIcon:Hide()
        return
    end
    
    -- Hide in combat check
    -- ☠ DF.playerInCombat, NOT InCombatLockdown() — see the note on the leader icon
    -- in Bars.lua (DF:UpdateLeaderIcon). Secure-frame lockdown is a different question
    -- from player combat state, and this icon was one of the two reported as never
    -- hiding. Every "Hide in Combat" gate in the addon reads the tracked flag now.
    if db.raidRoleIconHideInCombat and DF.playerInCombat then
        frame.raidRoleIcon:Hide()
        return
    end
    
    local unit = frame.unit
    local showIcon = false
    local role = nil
    
    -- Check raid role assignment
    if IsInRaid() then
        -- Get raid index for unit
        for i = 1, 40 do
            local raidUnit = "raid" .. i
            if UnitExists(raidUnit) then
                local isSameUnit = nil
                pcall(function()
                    -- Use string comparison to avoid secret value issues
                    isSameUnit = (raidUnit == unit)
                end)
                
                if isSameUnit then
                    local _, _, _, _, _, _, _, _, _, raidRole = GetRaidRosterInfo(i)
                    if raidRole == "MAINTANK" and db.raidRoleIconShowTank then
                        role = "MAINTANK"
                        showIcon = true
                    elseif raidRole == "MAINASSIST" and db.raidRoleIconShowAssist then
                        role = "MAINASSIST"
                        showIcon = true
                    end
                    break
                end
            end
        end
    else
        -- Party - check with GetPartyAssignment
        if GetPartyAssignment then
            local isTank = nil
            local isAssist = nil
            pcall(function()
                isTank = GetPartyAssignment("MAINTANK", unit)
                isAssist = GetPartyAssignment("MAINASSIST", unit)
            end)
            
            if canaccessvalue(isTank) and isTank and db.raidRoleIconShowTank then
                role = "MAINTANK"
                showIcon = true
            elseif canaccessvalue(isAssist) and isAssist and db.raidRoleIconShowAssist then
                role = "MAINASSIST"
                showIcon = true
            end
        end
    end
    
    if showIcon and role then
        local statusText = nil
        if role == "MAINTANK" then
            DF:SetUpgradedStatusIcon(frame.raidRoleIcon.texture, "Interface\\GroupFrame\\UI-Group-MainTankIcon")
            statusText = db.raidRoleIconTextTank or "MT"
        else
            DF:SetUpgradedStatusIcon(frame.raidRoleIcon.texture, "Interface\\GroupFrame\\UI-Group-MainAssistIcon")
            statusText = db.raidRoleIconTextAssist or "MA"
        end
        ApplyIconSettings(frame.raidRoleIcon, db, "raidRoleIcon")
        ShowIconAsText(frame.raidRoleIcon, statusText, db.raidRoleIconShowText)
        frame.raidRoleIcon:Show()
    else
        frame.raidRoleIcon:Hide()
    end
end

-- ============================================================
-- BG OBJECTIVE CARRIER ICON
-- Lights up when the unit is carrying a battleground objective
-- (WSG/TP flag, Kotmogu orb, etc.). Detection uses
-- UnitPvpClassification — an official, non-secret API — so it does
-- NOT depend on Blizzard's compact raid frames being enabled, and
-- only ever queries the frame's own (friendly, in-group) unit.
-- UnitPvpClassification returns an Enum.PvPUnitClassification value
-- (or -1 outside objective PvP); we only render flags + orbs.
-- ============================================================
-- ★ Exposed: the preview used to hardcode inv_bannerpvp_02, so the per-classification
-- art (Horde/Alliance/Neutral flags, the four orbs) was unpreviewable.
DF.PVP_CARRIER_TEXTURES = {
    [0]  = "Interface\\Icons\\inv_bannerpvp_01",  -- FlagCarrierHorde
    [1]  = "Interface\\Icons\\inv_bannerpvp_02",  -- FlagCarrierAlliance
    [2]  = "Interface\\Icons\\inv_bannerpvp_03",  -- FlagCarrierNeutral
    [7]  = 1119885,                               -- OrbCarrierBlue
    [8]  = 1119886,                               -- OrbCarrierGreen
    [9]  = 1119887,                               -- OrbCarrierOrange
    [10] = 1119887,                               -- OrbCarrierPurple (reuse orb art)
}

function DF:UpdateBGCarrierIcon(frame)
    if not frame or not frame.unit or not frame.bgCarrierIcon then return end

    local db = DF:GetFrameDB(frame)
    if not db or not db.bgCarrierIconEnabled then
        frame.bgCarrierIcon:Hide()
        return
    end

    local unit = frame.unit
    if not UnitExists(unit) or not UnitPvpClassification then
        frame.bgCarrierIcon:Hide()
        return
    end

    local classification
    pcall(function() classification = UnitPvpClassification(unit) end)

    -- Outside objective PvP this is -1 / nil. Guard secret values too.
    if not canaccessvalue(classification) or type(classification) ~= "number" then
        frame.bgCarrierIcon:Hide()
        return
    end

    local texture = DF.PVP_CARRIER_TEXTURES[classification]
    if not texture then
        frame.bgCarrierIcon:Hide()
        return
    end

    DF:SetUpgradedStatusIcon(frame.bgCarrierIcon.texture, texture)
    ApplyIconSettings(frame.bgCarrierIcon, db, "bgCarrierIcon")
    ShowIconAsText(frame.bgCarrierIcon, db.bgCarrierIconText or "FC", db.bgCarrierIconShowText)
    frame.bgCarrierIcon:Show()
end

-- Combat icon — shows the crossed-swords glyph while the unit is in combat.
-- Detection is UnitAffectingCombat(unit); event-driven via UNIT_FLAGS (see
-- Headers.lua) plus the normal status-icon refresh. Secret-guarded for Midnight.
function DF:UpdateCombatIcon(frame)
    if not frame or not frame.unit or not frame.combatIcon then return end

    local db = DF:GetFrameDB(frame)
    if not db or not db.combatIconEnabled then
        frame.combatIcon:Hide()
        return
    end

    local unit = frame.unit
    if not UnitExists(unit) or not UnitAffectingCombat then
        frame.combatIcon:Hide()
        return
    end

    local inCombat
    pcall(function() inCombat = UnitAffectingCombat(unit) end)

    -- Hide unless we can read the value AND it's truthy (secret-safe).
    if not canaccessvalue(inCombat) or not inCombat then
        frame.combatIcon:Hide()
        return
    end

    ApplyIconSettings(frame.combatIcon, db, "combatIcon")
    frame.combatIcon:Show()
end

-- ============================================================
-- UPDATE ALL STATUS ICONS FOR A FRAME
-- Convenience function to update all icons at once
-- ============================================================
function DF:UpdateAllStatusIcons(frame)
    if not frame then return end

    DF:UpdateSummonIcon(frame)
    DF:UpdateResurrectionIcon(frame)
    DF:UpdatePhasedIcon(frame)
    DF:UpdateAFKIcon(frame)
    DF:UpdateVehicleIcon(frame)
    DF:UpdateRaidRoleIcon(frame)
    DF:UpdateBGCarrierIcon(frame)
    DF:UpdateCombatIcon(frame)
end

-- ============================================================
-- UPDATE STATUS ICONS ON ALL FRAMES
-- Called when text mode settings change
-- ============================================================
function DF:UpdateAllFramesStatusIcons()
    -- Update all live frames via the proper iterator. GetChildren() on the secure
    -- group headers returns template internals, NOT the unit buttons, so the old
    -- GetChildren() loops here never reached live frames — status-icon font / size /
    -- colour changes only applied after a /reload. IterateAllFrames uses
    -- GetAttribute("child"..i), the same path the AFK ticker uses.
    if DF.IterateAllFrames then
        DF:IterateAllFrames(function(frame)
            if frame.unit then
                DF:UpdateAllStatusIcons(frame)
            end
        end)
    end

    -- Also refresh test frames if in test mode
    if DF.testMode or DF.raidTestMode then
        DF:RefreshTestFrames()
    end
end

-- ============================================================
-- COMBAT-GATED ICONS
-- ============================================================
-- Every icon carrying a "Hide in Combat" option, refreshed in ONE pass on a combat
-- transition. ☠ A GATE IS ONLY AS GOOD AS THE REFRESH THAT RE-EVALUATES IT. Entering
-- combat is covered by RefreshAllVisibleFrames -> FullFrameRefresh (PLAYER_REGEN_DISABLED),
-- but LEAVING combat only ever refreshed the role and leader icons via UpdateAllRoleIcons
-- -- so MT/MA, AFK, phased, vehicle, summon, raid target and ready check would hide on the
-- way in and stay hidden until some unrelated event happened to repaint the frame.
-- ⇒ ADD ANY NEW `<icon>HideInCombat` UPDATER HERE. The option is not finished without it.
function DF:UpdateAllCombatGatedIcons()
    if not DF.IterateAllFrames then return end
    DF:IterateAllFrames(function(frame)
        if not frame or not frame.unit then return end
        if DF.UpdateRoleIcon then DF:UpdateRoleIcon(frame, "CombatTransition") end
        if DF.UpdateLeaderIcon then DF:UpdateLeaderIcon(frame) end
        if DF.UpdateRaidTargetIcon then DF:UpdateRaidTargetIcon(frame) end
        if DF.UpdateReadyCheckIcon then DF:UpdateReadyCheckIcon(frame) end
        -- Covers summon / resurrection / phased / AFK / vehicle / MT-MA / BG carrier / combat.
        if DF.UpdateAllStatusIcons then DF:UpdateAllStatusIcons(frame) end
    end)
end

-- ============================================================
-- AFK TIMER TICKER
-- Updates AFK icons periodically to show elapsed time
-- ============================================================
local afkTickerFrame = CreateFrame("Frame")
local afkTickerInterval = 1.0  -- Update every second
local afkTickerElapsed = 0

afkTickerFrame:SetScript("OnUpdate", function(self, elapsed)
    afkTickerElapsed = afkTickerElapsed + elapsed
    if afkTickerElapsed < afkTickerInterval then return end
    afkTickerElapsed = 0
    
    -- Only update if AFK timer is enabled somewhere
    local partyDb = DF:GetDB()
    local raidDb = DF:GetRaidDB()
    
    -- ☠ Both guarded. DF:GetDB()/GetRaidDB() return DF.db[mode], which is nil whenever
    -- DF.db exists but the mode key does not -- and Core/Profile.lua REASSIGNS DF.db[mode]
    -- wholesale on a profile switch, so there is a window where this is nil. This is a
    -- bare OnUpdate on an always-shown frame, so an unguarded index fired once a second
    -- forever. The same function guards its other db read further down, and the
    -- BG-carrier ticker below guards explicitly -- this was the one that did not.
    local partyTimerEnabled = partyDb and partyDb.afkIconEnabled and partyDb.afkIconShowTimer ~= false
    local raidTimerEnabled = raidDb and raidDb.afkIconEnabled and raidDb.afkIconShowTimer ~= false
    
    if not partyTimerEnabled and not raidTimerEnabled then return end
    
    -- Update all live frames via the proper iterator.
    -- GetChildren() on SecureGroupHeaderTemplate returns secure-template internals,
    -- not the unit buttons — IterateAllFrames uses GetAttribute("child"..i) instead.
    -- skipHidden=true for the big party/raid/arena pass: only tick already-shown
    -- countdowns (avoid per-frame work for the many hidden frames). For the few
    -- pinned frames skipHidden=false, so the ticker also SHOWS a newly-AFK pinned
    -- icon within 1s as a safety net if its event-driven show was missed.
    local function tickAFK(frame, skipHidden)
        if not frame.unit or not frame.afkIcon then return end
        if skipHidden and not frame.afkIcon:IsShown() then return end
        local db = DF:GetFrameDB(frame)
        if not db then return end
        local isParty = not frame.isRaidFrame
        if (isParty and partyTimerEnabled) or (not isParty and raidTimerEnabled) then
            DF:UpdateAFKIcon(frame)
        end
    end

    if DF.IterateAllFrames then
        DF:IterateAllFrames(function(f) tickAFK(f, true) end)
    end

    -- Pinned frames are separate headers that IterateAllFrames does not cover.
    if DF.IteratePinnedFrames then
        DF.IteratePinnedFrames(function(f) tickAFK(f, false) end)
    end

    -- Update test frames if in test mode
    if DF.testMode then
        for i = 0, 4 do
            local frame = DF.testPartyFrames and DF.testPartyFrames[i]
            if frame and frame.afkIcon and frame.afkIcon:IsShown() then
                local testData = DF:GetTestUnitData(i)
                if testData and testData.isAFK then
                    DF:UpdateTestStatusIcons(frame, testData)
                end
            end
        end
    end
    
    if DF.raidTestMode then
        for i = 1, 40 do
            local frame = DF.testRaidFrames and DF.testRaidFrames[i]
            if frame and frame.afkIcon and frame.afkIcon:IsShown() then
                local testData = DF:GetTestUnitData(i, true)  -- true = raid; without it this pulled PARTY data so raid AFK frames (3 & 15) read isAFK=false and never ticked
                if testData and testData.isAFK then
                    DF:UpdateTestStatusIcons(frame, testData)
                end
            end
        end
    end

    -- Pinned test frames live in their own per-set pools (not testPartyFrames/
    -- testRaidFrames), so the loops above never reach them — without this their AFK
    -- countdown freezes while the main party/raid test frames tick. Mirror the same
    -- pass: index by the frame's own dfTestIndex + mode, render via UpdateTestStatusIcons.
    if DF.PinnedFrames and DF.PinnedFrames.IsTestModeActive and DF.PinnedFrames:IsTestModeActive() then
        local pools = DF.PinnedFrames.testFrames
        if pools then
            for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
                local pool = pools[setIndex]
                if pool then
                    for i = 1, #pool do
                        local frame = pool[i]
                        if frame and frame.dfTestIndex and frame.afkIcon and frame.afkIcon:IsShown() then
                            local testData = DF:GetTestUnitData(frame.dfTestIndex, frame.isRaidFrame, frame.isPinnedBossFrame)
                            if testData and testData.isAFK then
                                DF:UpdateTestStatusIcons(frame, testData)
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- ============================================================
-- BG CARRIER TICKER
-- UnitPvpClassification has no change event, so poll while in a
-- PvP instance and the icon is enabled. Cheap: only runs inside
-- battlegrounds / arenas, and only when enabled in party or raid.
-- ============================================================
local bgCarrierTickerFrame = CreateFrame("Frame")
local bgCarrierInterval = 0.5
local bgCarrierElapsed = 0

bgCarrierTickerFrame:SetScript("OnUpdate", function(self, elapsed)
    bgCarrierElapsed = bgCarrierElapsed + elapsed
    if bgCarrierElapsed < bgCarrierInterval then return end
    bgCarrierElapsed = 0

    -- Only relevant inside a PvP instance (battleground / arena / Blitz).
    local inInstance, instanceType = IsInInstance()
    if not inInstance or (instanceType ~= "pvp" and instanceType ~= "arena") then return end

    local partyDb = DF:GetDB()
    local raidDb = DF:GetRaidDB()
    local partyEnabled = partyDb and partyDb.bgCarrierIconEnabled
    local raidEnabled = raidDb and raidDb.bgCarrierIconEnabled
    if not partyEnabled and not raidEnabled then return end

    if DF.IterateAllFrames then
        DF:IterateAllFrames(function(frame)
            if not frame.unit or not frame.bgCarrierIcon then return end
            local isParty = not frame.isRaidFrame
            if (isParty and partyEnabled) or (not isParty and raidEnabled) then
                DF:UpdateBGCarrierIcon(frame)
            end
        end)
    end
end)
