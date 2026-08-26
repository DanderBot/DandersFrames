local addonName, DF = ...

-- ============================================================
-- ELEMENT APPEARANCE SYSTEM
-- Centralized color AND alpha management for all frame elements
-- Each element has a single function that determines its full appearance
-- based on all relevant factors (OOR, dead, aggro, settings, etc.)
--
-- This replaces the separate color/alpha functions to prevent flickering
-- and conflicts from multiple functions trying to set appearance.
--
-- Priority Order for determining appearance:
-- 1. Aggro Override (health bar only)
-- 2. Dead/Offline State
-- 3. Health Threshold Fading (above configurable health threshold)
-- 4. Out of Range (OOR) - element-specific or frame-level
-- 5. Normal Settings
--
-- Integration Points:
-- - Range timer (Range.lua) calls UpdateRangeAppearance every 0.2s
--   (which skips per-element updates in standard OOR mode for performance)
-- - ApplyDeadFade/ResetDeadFade (Colors.lua) delegate here
-- - UpdateUnitFrame (Update.lua) calls for unit changes
-- - Settings hooks call for live updates
-- ============================================================

-- Local caching for performance
local pairs, ipairs = pairs, ipairs
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local UnitIsConnected = UnitIsConnected
local UnitIsPlayer = UnitIsPlayer
local UnitExists = UnitExists
local UnitIsUnit = UnitIsUnit
local UnitClass = UnitClass
local UnitAffectingCombat = UnitAffectingCombat
local IsInInstance = IsInInstance
local CreateColor = CreateColor
local issecretvalue = issecretvalue  -- nil pre-Midnight, function in Midnight+

-- ============================================================
-- PERFORMANCE FIX: Reusable ColorMixin objects
-- SetVertexColorFromBoolean needs ColorMixin objects, but creating
-- them every call (5x/sec per frame) causes massive memory allocation.
-- We reuse the same objects and just update their values.
-- ============================================================
local reusableInRangeColor = CreateColor(1, 1, 1, 1)
local reusableOutOfRangeColor = CreateColor(1, 1, 1, 1)

-- ============================================================
-- PERFORMANCE FIX: Default color tables
-- These are used as fallbacks when db values are nil
-- Avoids creating new tables on every call (called 5x/sec per frame)
-- ============================================================
local DEFAULT_COLOR_GRAY = {r = 0.5, g = 0.5, b = 0.5}
local DEFAULT_COLOR_HEALTH = {r = 0.2, g = 0.8, b = 0.2}
local DEFAULT_COLOR_DEAD_BG = {r = 0.3, g = 0, b = 0}
local DEFAULT_COLOR_BACKGROUND = {r = 0.1, g = 0.1, b = 0.1, a = 0.8}
local DEFAULT_COLOR_WHITE = {r = 1, g = 1, b = 1}

-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================

-- Check if frame is a DandersFrames frame (process all our frames)
local function IsDandersFrame(frame)
    return frame and frame.dfIsDandersFrame
end

-- Get the appropriate database for this frame
local function GetDB(frame)
    return DF:GetFrameDB(frame)
end

-- Get current range status for a unit
-- Returns a boolean (may be secret from UnitInRange fallback)
-- Downstream callers must use SetAlphaFromBoolean for secret-safe alpha.
local function GetInRange(frame)
    -- Use cached value from Range.lua if available
    -- May be a secret boolean from UnitInRange (classes without friendly spells)
    local inRange = frame.dfInRange
    if issecretvalue and issecretvalue(inRange) then
        return inRange  -- Secret boolean, pass through for SetAlphaFromBoolean
    end
    if inRange ~= nil then
        return inRange
    end
    
    -- Fallback for frames not yet updated by range timer
    local unit = frame.unit
    if not unit then return true end
    
    if not UnitExists(unit) then
        return true
    elseif UnitIsUnit(unit, "player") then
        return true  -- Player is always in range
    end
    
    -- Default to in-range if no cached value yet
    return true
end

-- ============================================================
-- FRAME FADE (whole-frame base opacity)
-- ============================================================
-- ★ THE ONE PLACE A UNIT FRAME'S BASE OPACITY IS DECIDED. Every writer of a whole
-- frame's alpha -- the range fade below (both modes), the health-fade curve
-- (HealthFade.lua) and the pet fade (Range.lua) -- multiplies its own value by this,
-- so "Global Frame Fade" composes with those fades instead of fighting them:
-- base 0.5 x out-of-range 0.4 = 0.2. Per-element fades (dead, element-specific OOR)
-- are untouched; the frame's alpha cascades over them.
-- Split off = the global slider, one table read. Split on = the in-combat value
-- while the PLAYER is fighting (UnitAffectingCombat, not InCombatLockdown -- lockdown
-- lingers past the fight), the out-of-combat value otherwise. Hover borrows the
-- in-combat value out of combat when asked, so a receded frame is readable while
-- the mouse is on it. Combat edges: the REGEN sweep below; hover edges: the
-- OnEnter/OnLeave hooks in Frames/Create.lua call DF:RefreshFrameFadeForHover.
-- The frame the mouse is on right now (nil when none). One field, not a count: OnLeave
-- can be skipped when a frame hides under the cursor, and a count would drift; a
-- reference self-heals because we re-check its dfIsHovered before trusting it.
DF._frameFadeHoveredFrame = nil

local function AnyFrameHovered()
    local f = DF._frameFadeHoveredFrame
    return f ~= nil and f.dfIsHovered == true
end

function DF:GetFrameBaseAlpha(db, frame)
    if not db then return 1 end
    if db.frameFadeSplitCombat then
        -- "In Instances" holds the in-combat value for the whole dungeon / raid /
        -- arena / BG visit -- the M+ complaint: combat drops between every pack, so
        -- the frames faded out and back on every single pull. IsInInstance is a
        -- cheap C read; instance edges re-apply via the PEW sweep below.
        if UnitAffectingCombat("player")
            or (db.frameFadeInstanceUsesCombat and IsInInstance()) then
            return db.frameFadeAlphaInCombat or 1
        end
        if db.frameFadeHoverUsesCombat then
            -- Scope: "ALL" lifts every frame while any one is hovered, so the whole
            -- group is readable and clickable; "FRAME" lifts only the hovered unit.
            local hovered = (db.frameFadeHoverScope == "FRAME")
                and (frame and frame.dfIsHovered)
                or (db.frameFadeHoverScope ~= "FRAME" and AnyFrameHovered())
            if hovered then return db.frameFadeAlphaInCombat or 1 end
        end
        return db.frameFadeAlphaOutOfCombat or 1
    end
    return db.frameFadeAlpha or 1
end

-- Every unit frame through UpdateFrameAppearance: the combat-edge sweep and the
-- all-frames hover scope share it. Pets are left to the next range tick.
local function SweepFrameFade()
    if DF.IterateAllFrames then
        DF:IterateAllFrames(function(f)
            if f and f.dfIsDandersFrame then DF:UpdateFrameAppearance(f) end
        end)
    end
    -- Pinned through the shared walker (player-set children AND boss sets), never a
    -- hand-rolled header loop -- see IteratePinnedFrames in Frames/Headers.lua.
    if DF.IteratePinnedFrames then
        DF.IteratePinnedFrames(function(child)
            if child and child.dfIsDandersFrame then DF:UpdateFrameAppearance(child) end
        end)
    end
end

-- Hover edge for the "Show In-Combat Fade When Hovering" option. Cheap gate first --
-- OnEnter/OnLeave fire constantly across a raid grid -- and a no-op unless the split
-- and the hover option are both on and the player is out of combat (in combat the
-- frame already shows the in-combat value). Called AFTER the hook has written
-- frame.dfIsHovered, so the flag is the truth here.
-- Scope "ALL": track the hovered frame globally and sweep every frame on the
-- none->some edge immediately; the some->none edge is settled one frame later, so
-- crossing straight from one frame onto its neighbour (leave + enter in the same
-- frame) costs one sweep and never flashes -- the deferred leave finds a new
-- hovered frame and does nothing.
local function SweepIfNothingHovered()
    if DF._frameFadeHoveredFrame == nil and not UnitAffectingCombat("player") then
        SweepFrameFade()
    end
end
function DF:RefreshFrameFadeForHover(frame)
    if not (frame and frame.dfIsDandersFrame) then return end
    local db = DF:GetFrameDB(frame)
    if not (db and db.frameFadeSplitCombat and db.frameFadeHoverUsesCombat) then return end
    if db.frameFadeHoverScope == "FRAME" then
        if UnitAffectingCombat("player") then return end
        if DF.UpdateFrameAppearance then DF:UpdateFrameAppearance(frame) end
        return
    end
    if frame.dfIsHovered then
        local wasNone = DF._frameFadeHoveredFrame == nil
        DF._frameFadeHoveredFrame = frame
        if wasNone and not UnitAffectingCombat("player") then SweepFrameFade() end
    elseif DF._frameFadeHoveredFrame == frame then
        DF._frameFadeHoveredFrame = nil
        C_Timer.After(0, SweepIfNothingHovered)
    end
end

-- Apply OOR alpha to any UI element (Frame, Texture, or FontString)
-- inRange may be a secret boolean from UnitInRange fallback (DK/DH/Hunter/Warrior).
-- SetAlphaFromBoolean handles secret booleans natively (Midnight+ API).
-- ☠ PREFER PLAIN SetAlpha. SetAlphaFromBoolean exists for ONE reason: to consume a SECRET
-- boolean without Lua ever branching on it. This reached for it unconditionally, including
-- when inRange is an ordinary Lua boolean we can resolve ourselves — and that is what broke
-- the AD placed-indicator fade.
--
-- The secret-aware setter is refused on an object that inherits FORBIDDEN ASPECTS from the
-- aura button (the slot alpha host is a child of the button, and forbidden aspects propagate
-- through parent/child — see AuraContainerUtil.ValidateInboundScriptObject, which requires
-- descendancy precisely so they inherit). Plain SetAlpha on that same object is accepted:
-- AuraContainer's own base-alpha write to the host does exactly that and works.
--
-- GetInRange only hands back a secret for the classes that fall through to UnitInRange, so
-- for most specs this now takes the plain path — the fade works everywhere, slot-backed
-- placed indicators included, and the error storm has no source left.
local function ApplyOORAlpha(element, inRange, inAlpha, oorAlpha)
    if not element then return end
    if not (issecretvalue and issecretvalue(inRange)) then
        -- Plain boolean: resolve it here. No secret ever touches a comparison.
        element:SetAlpha(inRange and inAlpha or oorAlpha)
        return
    end
    if element.SetAlphaFromBoolean then
        element:SetAlphaFromBoolean(inRange, inAlpha, oorAlpha)
    else
        -- Secret value and no secret-safe setter (pre-Midnight): branching on it is
        -- exactly the taint trap, so hold the in-range alpha rather than guess.
        element:SetAlpha(inAlpha)
    end
end



-- Check if unit is dead or offline
-- ★★ STAMPS FIRST, UNIT APIS SECOND. The three helpers below are the ONLY reason
-- this file's Update*Appearance functions cannot simply run on a test frame, so each
-- prefers a frame-stamped value and falls back to the unit API.
--
-- ☠ AND THE STAMP IS NOT MERELY A CONVENIENCE. Test frames carry REAL unit tokens --
-- TestFramePool assigns "raid1".."raidN" and "player" -- so in an actual group these
-- resolve to REAL units and UnitIsDeadOrGhost / UnitClass answer about whoever is
-- standing next to you, not about the preview's scenario. That is what the
-- `if DF.testMode then return end` guards throughout this file are really defending
-- against; it is NOT a fabricated-token problem. Stamping is what makes removing
-- those guards safe, so do not remove one before its inputs are stamped.
-- (Audit, 2026-08-07.)
local function IsDeadOrOffline(frame)
    if frame.dfIsDead ~= nil then return frame.dfIsDead end
    local unit = frame.unit
    if not unit or not UnitExists(unit) then return false end
    -- ☠ "Offline" is for PLAYERS only — an NPC has no connection, so the
    -- unguarded term read pinned NPCs (Lura's crystals) as offline and painted
    -- them grey instead of their health gradient (#989). Same gate as the
    -- offline branches in Frames/Update.lua (the #1042 fix this completes).
    return UnitIsDeadOrGhost(unit)
        or (UnitIsPlayer(unit) and not UnitIsConnected(unit))
end

-- ★★ THE FADE MULTIPLIER FOR THE EIGHT STATUS ICONS, shared by live and the preview.
--
-- ☠ THESE ICONS COULD NOT FADE LIVE AT ALL. CreateStatusIcon sets
-- SetIgnoreParentAlpha(true), so the whole-frame cascade cannot reach them, and this
-- file has never referenced summon/resurrection/phased/afk/vehicle/raidRole/
-- bgCarrier/combat — so neither route existed. Only the PREVIEW dimmed them, off its
-- own hand-written alpha table. That is the rare case where the preview was showing
-- something live was structurally incapable of (audit, 2026-08-07).
--
-- Keeping SetIgnoreParentAlpha is deliberate: we now set the alpha explicitly, and
-- ignoring the parent is what stops the simple-mode cascade multiplying it a second
-- time. One application, both modes.
--
-- ★ SUMMON AND RESURRECTION DO NOT DIM OUT OF RANGE. Krathe's rule: an icon that
-- exists because someone is casting something AT this unit is most useful precisely
-- when they are far away — you summon people who are elsewhere. Dimming it would
-- fight what the icon is for. They still dim for dead/offline. If resurrection turns
-- out to be the wrong call, this table is the only thing to change.
local STATUS_ICON_NO_OOR_FADE = {
    summonIcon        = true,
    resurrectionIcon  = true,
}

-- The eight status icons, by config prefix. The frame field is the same name
-- (frame.summonIcon <-> "summonIcon"), which is what lets the refresh below stay a
-- plain list rather than a mapping.
local STATUS_ICON_PREFIXES = {
    "summonIcon", "resurrectionIcon", "phasedIcon", "afkIcon",
    "vehicleIcon", "raidRoleIcon", "bgCarrierIcon", "combatIcon",
    "pingIcon",
}

function DF:GetStatusIconFadeAlpha(frame, prefix)
    if not frame then return 1.0 end
    local db = GetDB(frame)
    if not db then return 1.0 end

    local alpha = 1.0
    -- Dead/offline first: applies to every icon, summon included.
    local dead = IsDeadOrOffline(frame)   -- stamp-aware; see the helper
    if dead and db.fadeDeadFrames then
        alpha = alpha * (db.fadeDeadIcons or 1.0)
    end

    if not STATUS_ICON_NO_OOR_FADE[prefix] then
        local inRange = GetInRange(frame)
        -- issecretvalue-safe: a secret boolean cannot drive a Lua multiply, so treat
        -- an unresolvable range as in-range rather than guessing dim.
        if not (issecretvalue and issecretvalue(inRange)) and inRange == false then
            -- ⚠ BOTH range-fade modes, unlike every other element. Elsewhere simple
            -- mode leans on the whole-frame SetAlpha cascade and only element mode
            -- needs a per-element value — but these icons set
            -- SetIgnoreParentAlpha(true), so the cascade never reaches them and an
            -- explicit multiply is the only route either way.
            alpha = alpha * (db.oorEnabled and (db.oorIconsAlpha or 0.5)
                or (db.rangeFadeAlpha or db.rangeAlpha or 0.4))
        end
    end
    return alpha
end

-- ☠ RE-APPLY THE STATUS-ICON FADE ON A RANGE CHANGE.
--
-- GetStatusIconFadeAlpha above is correct, and ApplyIconSettings (Frames/StatusIcons.lua)
-- multiplies by it -- but ApplyIconSettings only runs from each icon's own Update*Icon
-- path. NOTHING re-ran it when range changed: UpdateAllElementAppearances drove 22
-- appearance functions and named none of the eight icons, and UpdateAllStatusIcons is
-- reachable only from the full-frame refresh in Headers.lua. CreateStatusIcon also sets
-- SetIgnoreParentAlpha(true), so the whole-frame cascade cannot reach them either.
--
-- Net effect: an icon only faded when it happened to re-render for its own reason. AFK
-- and BG-carrier self-heal off their own tickers; summon, resurrection, phased, vehicle,
-- raid-role and combat did not -- so a unit walking out of range kept a bright icon on an
-- otherwise dimmed frame, and walking back in left a dim one. The changelog says this was
-- fixed; only half of it was.
--
-- ⚠ This is deliberately ALPHA ONLY and reuses ApplyIconSettings' exact expression.
-- StatusIcons.lua calls itself "THE ONE PLACE THESE ICONS' ALPHA IS SET, so the fade
-- belongs here rather than in a second pass that would fight it" -- the hazard it names is
-- a second pass computing something DIFFERENT. This computes the same product, so the two
-- always agree; it just makes the range path able to trigger it. Do not grow this into a
-- general icon-settings pass.
function DF:UpdateStatusIconsAppearance(frame)
    if not IsDandersFrame(frame) then return end
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end

    local db = GetDB(frame)
    if not db then return end

    for i = 1, #STATUS_ICON_PREFIXES do
        local prefix = STATUS_ICON_PREFIXES[i]
        local icon = frame[prefix]
        -- Hidden icons cost nothing to skip and will be re-alpha'd by
        -- ApplyIconSettings when their own path shows them.
        if icon and icon.IsShown and icon:IsShown() then
            icon:SetAlpha((db[prefix .. "Alpha"] or 1) * DF:GetStatusIconFadeAlpha(frame, prefix))
        end
    end
end

-- Check if unit is specifically offline (not just dead)
local function IsOffline(frame)
    if frame.dfIsOffline ~= nil then return frame.dfIsOffline end
    local unit = frame.unit
    if not unit or not UnitExists(unit) then return false end
    -- Players only — see IsDeadOrOffline above.
    return UnitIsPlayer(unit) and not UnitIsConnected(unit)
end

-- Check if health threshold fade is enabled
local function IsHealthFadeEnabled(db)
    return db and db.healthFadeEnabled
end

-- Get class color for a unit
local function GetClassColor(frame)
    local class = frame.dfClassToken
    if not class then
        local unit = frame.unit
        if not unit or not UnitExists(unit) then
            return DEFAULT_COLOR_GRAY
        end
        local _
        _, class = UnitClass(unit)
    end
    return DF:GetClassColor(class)
end

-- ============================================================
-- HEALTH BAR APPEARANCE
-- Handles: color mode, dead/offline, aggro, OOR alpha
-- We apply color via the texture's SetVertexColor to avoid secret value issues
-- ============================================================

function DF:UpdateHealthBarAppearance(frame)
    if not IsDandersFrame(frame) then return end
    if not frame.healthBar then return end
    
    local db = GetDB(frame)
    if not db then return end
    
    -- Skip during test mode (test mode handles its own appearance)
    -- ★ Test frames pass through. The curve-driven colour below takes the stamped
    -- health fraction instead of UnitHealthPercent -- a DATA fork; the rendering,
    -- the colour stops and the mode branching are all shared.
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end

    local unit = frame.unit
    local deadOrOffline = IsDeadOrOffline(frame)
    local offline = IsOffline(frame)
    local inRange = GetInRange(frame)
    local aggroActive = frame.dfAggroActive and frame.dfAggroColor

    -- Get the texture - this is what we apply colors to
    local tex = frame.healthBar:GetStatusBarTexture()
    if not tex then return end

    -- ========================================
    -- DETERMINE ALPHA
    -- ========================================
    local colorMode = db.healthColorMode or "CLASS"
    local alpha
    if colorMode == "CUSTOM" then
        local c = db.healthColor
        alpha = (c and c.a) or 1.0
    else
        alpha = db.classColorAlpha or 1.0
    end

    if deadOrOffline and db.fadeDeadFrames then
        alpha = db.fadeDeadHealthBar or 1
    end

    -- ========================================
    -- APPLY COLOR
    -- Skip when Aura Designer health bar color indicator is active.
    -- AD owns the bar color while its indicator is applied; normal
    -- color updates (UNIT_HEALTH, form shifts, etc.) must not
    -- overwrite it.  Alpha is still applied below so OOR/dead fade
    -- continues to work.
    -- ========================================
    -- In replace mode AD owns the bar colour entirely — skip normal colour updates.
    -- In tint mode the underlying bar shows through the overlay, so normal colour
    -- logic (class / percent / custom) must still run.
    local adHealthBarActive = frame.dfAD and frame.dfAD.healthbar
    local adHealthBarMode   = adHealthBarActive and frame.dfAD.healthbarMode

    if adHealthBarMode == "replace" then
        -- AD owns the color — don't touch it
    elseif aggroActive then
        -- Priority 1: Aggro override
        local c = frame.dfAggroColor
        tex:SetVertexColor(c.r, c.g, c.b)
    elseif deadOrOffline then
        -- Priority 2: Dead/Offline gray
        if offline then
            tex:SetVertexColor(0.5, 0.5, 0.5)
        else
            tex:SetVertexColor(0.3, 0.3, 0.3)
        end
    else
        -- Priority 3: Normal color based on mode
        if colorMode == "PERCENT" then
            -- PERCENT mode: Use UnitHealthPercent with curve - returns ColorMixin.
            -- ☠ TEST FRAMES TAKE DF:GetHealthGradientColor INSTEAD -- the same stops,
            -- interpolated in Lua. Live cannot do that (the health value is secret and
            -- may never be compared), and test cannot use the curve (it needs a real
            -- unit). Verified equivalent point-for-point during the 2026-08-07 audit:
            -- same positions, same weight flooring, same percent == 1 boundary.
            local testPct = frame.dfHealthPct
            if testPct and DF.GetHealthGradientColor then
                local c = DF:GetHealthGradientColor(testPct, db, frame.dfClassToken, "healthColor")
                if c then
                    tex:SetVertexColor(c.r, c.g, c.b)
                    return
                end
            end
            local curve = DF:GetCurveForUnit(unit, db)
            if curve and unit and UnitHealthPercent then
                local color = UnitHealthPercent(unit, true, curve)
                if color then
                    tex:SetVertexColor(color:GetRGB())
                else
                    -- Fallback to class color
                    local classColor = GetClassColor(frame)
                    tex:SetVertexColor(classColor.r, classColor.g, classColor.b)
                end
            else
                -- Fallback to class color
                local classColor = GetClassColor(frame)
                tex:SetVertexColor(classColor.r, classColor.g, classColor.b)
            end
        elseif colorMode == "CLASS" then
            local classColor = GetClassColor(frame)
            tex:SetVertexColor(classColor.r, classColor.g, classColor.b)
        elseif colorMode == "CUSTOM" then
            local c = db.healthColor or DEFAULT_COLOR_HEALTH
            tex:SetVertexColor(c.r, c.g, c.b)
        else
            -- Default fallback
            tex:SetVertexColor(0, 0.8, 0)
        end
    end

    -- ========================================
    -- APPLY ALPHA
    -- ========================================
    if adHealthBarMode == "replace" then
        -- AD replace mode owns the underlying bar's opacity. Apply it through the
        -- texture's FRAME alpha here (re-asserted on every health event) — the
        -- companion SetVertexColor in ApplyHealthBar leaves vertex alpha at 1 so
        -- StatusBar:SetValue can't flicker it to full. The AD effective blend already
        -- encodes the OOR fade (kept in lockstep with the overlay by
        -- UpdateAuraDesignerAppearance), so apply it directly and skip the normal OOR
        -- path to avoid double-fading.
        local ad = frame.dfAD
        local adAlpha = ad.healthbarEffectiveBlend or ad.healthbarBlend or alpha
        -- While the expiring pulse is running, the shared pulse ticker owns the
        -- texture's frame alpha (base × factor). Re-asserting adAlpha here on every
        -- UNIT_HEALTH would stamp the full-cycle value for one frame and stutter the
        -- pulse under sustained damage — so defer to the ticker while it's active.
        if not ad.healthbarPulseOn then
            tex:SetAlpha(adAlpha)
        end
    elseif db.oorEnabled then
        -- Element-specific OOR mode
        local oorAlpha = db.oorHealthBarAlpha or 0.2
        ApplyOORAlpha(tex, inRange, alpha, oorAlpha)
    else
        -- Frame-level OOR mode - just apply alpha
        tex:SetAlpha(alpha)
    end
end

-- ============================================================
-- MISSING HEALTH BAR APPEARANCE
-- Handles: dead/offline custom color override
-- ============================================================

function DF:UpdateMissingHealthBarAppearance(frame)
    if not IsDandersFrame(frame) then return end
    if not frame.missingHealthBar then return end

    -- ★ TEST FRAMES PASS THROUGH. The fade is pure db + GetInRange and the preview had
    -- NO counterpart for oorMissingHealthAlpha, so the bar never dimmed out of range
    -- there. SetMissingHealthBarValue is stamp-aware now (it takes the fraction, the
    -- dead state and the class from the frame when they are stamped), so the VALUE write
    -- is shared too -- it no longer resolves a test frame's REAL token to whoever is
    -- standing next to you. (Audit, 2026-08-07.)
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end

    local unit = frame.unit
    if not unit then return end

    -- OOR alpha for element-specific mode
    local db = GetDB(frame)
    if db and db.oorEnabled then
        local inRange = GetInRange(frame)
        local oorAlpha = db.oorMissingHealthAlpha or 0.2
        ApplyOORAlpha(frame.missingHealthBar, inRange, 1.0, oorAlpha)
    end

    -- SetMissingHealthBarValue handles the dead color override internally
    DF.SetMissingHealthBarValue(frame.missingHealthBar, unit, frame)
end

-- ============================================================
-- BACKGROUND APPEARANCE
-- Handles: color mode, textured vs solid, dead/offline, OOR alpha
-- ============================================================

function DF:UpdateBackgroundAppearance(frame)
    if not IsDandersFrame(frame) then return end
    if not frame.background then return end
    
    local db = GetDB(frame)
    if not db then return end
    
    -- Skip during test mode
    -- ★ Test frames pass through. The curve-driven colour below takes the stamped
    -- health fraction instead of UnitHealthPercent -- a DATA fork; the rendering,
    -- the colour stops and the mode branching are all shared.
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end
    
    -- Skip if actively adjusting background color in options (prevents flicker)
    if DF.isAdjustingBackgroundColor then return end
    
    -- Handle backgroundMode visibility
    local backgroundMode = db.backgroundMode or "BACKGROUND"
    if backgroundMode == "MISSING_HEALTH" then
        -- Only missing health bar visible, hide solid background
        frame.background:SetAlpha(0)
        return
    end
    -- For "BACKGROUND" or "BOTH", continue with normal background rendering
    
    local unit = frame.unit
    local deadOrOffline = IsDeadOrOffline(frame)
    local inRange = GetInRange(frame)
    
    -- Check if using textured background
    local bgTexture = db.backgroundTexture or "Solid"
    local isTexturedBg = bgTexture ~= "Solid" and bgTexture ~= ""
    
    -- ========================================
    -- DETERMINE COLOR
    -- ========================================
    local r, g, b = 0.1, 0.1, 0.1  -- Default dark
    local baseAlpha = 0.8
    
    local bgMode = db.backgroundColorMode or "CUSTOM"
    
    -- Check for dead custom color override (COLOR only, alpha handled separately)
    local useDeadColor = deadOrOffline and db.fadeDeadFrames and db.fadeDeadUseCustomColor
    
    if useDeadColor then
        -- Use custom dead COLOR (alpha is handled in next section)
        local c = db.fadeDeadBackgroundColor or DEFAULT_COLOR_DEAD_BG
        r, g, b = c.r, c.g, c.b
        baseAlpha = 0.8
    -- ⚠ The gate must accept the STAMP, because the body already does. GetClassColor
    -- reads frame.dfClassToken first and only falls back to UnitClass -- but a raw
    -- `unit and UnitExists(unit)` gate rejected test frames before it could. Test
    -- frames carry REAL tokens ("raid1"), so solo the token does not exist, this branch
    -- was skipped and the background fell through to db.backgroundColor; inside a real
    -- raid the token resolves and it worked, which is why it read as intermittent.
    -- Same shape as Frames/Core.lua:230, which had it right.
    elseif bgMode == "CLASS"
        and ((frame and frame.dfClassToken) or (unit and UnitExists(unit))) then
        local classColor = GetClassColor(frame)
        r, g, b = classColor.r, classColor.g, classColor.b
        baseAlpha = db.backgroundClassAlpha or 0.3
    elseif bgMode == "CUSTOM" then
        local c = db.backgroundColor or DEFAULT_COLOR_BACKGROUND
        r, g, b = c.r, c.g, c.b
        baseAlpha = c.a or 0.8
    else
        -- Fallback - use default background color (BLIZZARD/BLACK migrated to CUSTOM in v3.2.x)
        local c = db.backgroundColor or DEFAULT_COLOR_BACKGROUND
        r, g, b = c.r, c.g, c.b
        baseAlpha = c.a or 0.8
    end
    
    -- ========================================
    -- DETERMINE ALPHA
    -- ========================================
    local finalAlpha = baseAlpha
    
    if deadOrOffline and db.fadeDeadFrames then
        finalAlpha = db.fadeDeadBackground or 1
    end
    
    -- ========================================
    -- APPLY APPEARANCE
    -- ========================================
    if db.oorEnabled then
        -- Element-specific OOR mode
        local oorBgAlpha = db.oorBackgroundAlpha or 0.1
        
        if isTexturedBg then
            -- Textured background: use SetVertexColor for color+alpha
            frame.background:SetAlpha(1.0)  -- Keep frame alpha at 1
            if frame.background.SetVertexColorFromBoolean then
                -- PERF: Reuse color objects instead of creating new ones
                reusableInRangeColor:SetRGBA(r, g, b, finalAlpha)
                reusableOutOfRangeColor:SetRGBA(r, g, b, oorBgAlpha)
                frame.background:SetVertexColorFromBoolean(inRange, reusableInRangeColor, reusableOutOfRangeColor)
            else
                local effectiveAlpha = inRange and finalAlpha or oorBgAlpha
                frame.background:SetVertexColor(r, g, b, effectiveAlpha)
            end
        else
            -- Solid background: use SetColorTexture + ApplyOORAlpha
            frame.background:SetColorTexture(r, g, b, 1.0)
            ApplyOORAlpha(frame.background, inRange, finalAlpha, oorBgAlpha)
        end
    else
        -- Frame-level OOR mode
        if isTexturedBg then
            frame.background:SetAlpha(1.0)
            frame.background:SetVertexColor(r, g, b, finalAlpha)
        else
            frame.background:SetColorTexture(r, g, b, 1.0)
            frame.background:SetAlpha(finalAlpha)
        end
    end
end

-- ============================================================
-- NAME TEXT APPEARANCE
-- Handles: color (class or custom), dead/offline, OOR alpha
-- ============================================================

function DF:UpdateNameTextAppearance(frame)
    if not IsDandersFrame(frame) then return end
    if not frame.nameText then return end

    -- Skip test frames - they handle their own appearance in TestMode.lua
    -- ★ Test frames pass through. This guarded on dfIsTestFrame rather than on
    -- DF.testMode like its neighbours -- an inconsistency that predates the audit --
    -- and its only unit read is GetClassColor, which is stamp-aware now.

    local db = GetDB(frame)
    if not db then return end

    local deadOrOffline = IsDeadOrOffline(frame)
    local inRange = GetInRange(frame)

    -- ========================================
    -- DETERMINE COLOR
    -- ========================================
    local r, g, b = 1, 1, 1  -- Default white
    local baseAlpha = 1.0     -- From color picker

    if db.nameTextUseClassColor then
        -- Class color always applies, even when dead/offline
        local classColor = GetClassColor(frame)
        r, g, b = classColor.r, classColor.g, classColor.b
    elseif deadOrOffline then
        -- Gray for dead/offline (only when not using class color)
        r, g, b = 0.5, 0.5, 0.5
    else
        local c = db.nameTextColor or DEFAULT_COLOR_WHITE
        r, g, b = c.r, c.g, c.b
        baseAlpha = c.a or 1.0
    end

    -- ========================================
    -- DETERMINE ALPHA
    -- All alpha goes through SetAlpha/SetAlphaFromBoolean,
    -- never through SetTextColor's alpha channel.
    -- ========================================
    local alpha = baseAlpha

    if deadOrOffline and db.fadeDeadFrames then
        alpha = db.fadeDeadName or 1.0
    end

    -- ========================================
    -- APPLY APPEARANCE
    -- Color always uses alpha=1.0; opacity is controlled
    -- solely via SetAlpha so it works with SetAlphaFromBoolean.
    -- ========================================
    frame.nameText:SetTextColor(r, g, b, 1.0)

    if db.oorEnabled then
        local oorAlpha = db.oorTextAlpha or 0.55
        ApplyOORAlpha(frame.nameText, inRange, alpha, oorAlpha)
    else
        frame.nameText:SetAlpha(alpha)
    end
end

-- ============================================================
-- HEALTH TEXT APPEARANCE
-- ============================================================

function DF:UpdateHealthTextAppearance(frame)
    if not IsDandersFrame(frame) then return end
    if not frame.healthText then return end

    local db = GetDB(frame)
    if not db then return end

    -- ★ Test frames pass through: every unit read here goes via the stamp-aware
    -- helpers (GetInRange / IsDeadOrOffline / GetClassColor).
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end

    local deadOrOffline = IsDeadOrOffline(frame)
    local inRange = GetInRange(frame)

    -- ========================================
    -- DETERMINE COLOR
    -- ========================================
    local r, g, b = 1, 1, 1  -- Default white
    local baseAlpha = 1.0     -- From color picker

    if db.healthTextUseClassColor then
        local classColor = GetClassColor(frame)
        r, g, b = classColor.r, classColor.g, classColor.b
    else
        local c = db.healthTextColor or DEFAULT_COLOR_WHITE
        r, g, b = c.r, c.g, c.b
        baseAlpha = c.a or 1.0
    end

    -- ========================================
    -- DETERMINE ALPHA
    -- All alpha goes through SetAlpha/SetAlphaFromBoolean.
    -- ========================================
    local alpha = baseAlpha

    if deadOrOffline and db.fadeDeadFrames then
        alpha = db.fadeDeadHealthBar or 1  -- Health text follows health bar alpha
    end

    -- ========================================
    -- APPLY APPEARANCE
    -- Color always uses alpha=1.0; opacity is controlled
    -- solely via SetAlpha so it works with SetAlphaFromBoolean.
    -- ========================================
    frame.healthText:SetTextColor(r, g, b, 1.0)

    if db.oorEnabled then
        local oorAlpha = db.oorTextAlpha or 0.55
        ApplyOORAlpha(frame.healthText, inRange, alpha, oorAlpha)
    else
        frame.healthText:SetAlpha(alpha)
    end
end

-- ============================================================
-- STATUS TEXT APPEARANCE
-- ============================================================

function DF:UpdateStatusTextAppearance(frame)
    if not IsDandersFrame(frame) then return end
    if not frame.statusText then return end

    local db = GetDB(frame)
    if not db then return end

    -- ★ Test frames pass through: every unit read here goes via the stamp-aware
    -- helpers (GetInRange / IsDeadOrOffline / GetClassColor).
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end

    local deadOrOffline = IsDeadOrOffline(frame)

    -- Status text color (usually white)
    local c = db.statusTextColor or DEFAULT_COLOR_WHITE
    local r, g, b = c.r, c.g, c.b
    local baseAlpha = c.a or 1.0

    local alpha = baseAlpha
    if deadOrOffline and db.fadeDeadFrames then
        alpha = db.fadeDeadStatusText or 1.0
    end

    -- Color always uses alpha=1.0; opacity via SetAlpha
    frame.statusText:SetTextColor(r, g, b, 1.0)
    frame.statusText:SetAlpha(alpha)
end

-- ============================================================
-- POWER BAR APPEARANCE
-- ============================================================

function DF:UpdatePowerBarAppearance(frame)
    if not IsDandersFrame(frame) then return end
    if not frame.dfPowerBar then return end
    
    local db = GetDB(frame)
    if not db then return end
    
    -- ★ Test frames pass through: every unit read here goes via the stamp-aware
    -- helpers (GetInRange / IsDeadOrOffline / GetClassColor).
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end
    
    local deadOrOffline = IsDeadOrOffline(frame)
    local inRange = GetInRange(frame)
    
    -- Power bar color is typically set by UpdateUnitFrame based on power type
    -- Here we just handle alpha
    
    local alpha = 1.0
    
    if deadOrOffline and db.fadeDeadFrames then
        alpha = db.fadeDeadPowerBar or 0
    end
    
    if db.oorEnabled then
        local oorAlpha = db.oorPowerBarAlpha or 0.2
        ApplyOORAlpha(frame.dfPowerBar, inRange, alpha, oorAlpha)
    else
        frame.dfPowerBar:SetAlpha(alpha)
    end
end

-- ============================================================
-- BORDER APPEARANCE
-- In whole-frame OOR mode the border fades via the frame's alpha cascade.
-- In element-specific mode the frame is pinned at 1.0, so the border needs its
-- own alpha here — otherwise it stays full while every other element fades.
-- ============================================================

function DF:UpdateBorderAppearance(frame)
    if not IsDandersFrame(frame) then return end
    if not frame.border then return end

    local db = GetDB(frame)
    if not db then return end

    -- ★ Test frames pass through: every unit read here goes via the stamp-aware
    -- helpers (GetInRange / IsDeadOrOffline / GetClassColor).
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end

    local inRange = GetInRange(frame)
    local alpha = 1.0

    if db.oorEnabled then
        local oorAlpha = db.oorBorderAlpha or 0.2
        ApplyOORAlpha(frame.border, inRange, alpha, oorAlpha)
        -- ☠ HAND THE ANIMATION DRIVER WHAT IT NEEDS TO RESPECT THIS.
        -- DF_PULSATE drives the border's OWN alpha every frame, so it overwrites the
        -- SetAlpha above and an out-of-range border keeps pulsing at full strength. Its
        -- tick tried to compensate by multiplying by `dfRangeAlpha` -- but nothing has
        -- ever written that field (two hits addon-wide, both inside that one expression),
        -- so the multiplier was permanently 1 and the comment claiming this pass sets it
        -- was false.
        --
        -- It cannot be a plain number: `inRange` may be a SECRET boolean, so the tick
        -- cannot compute `pulse * (inRange and 1 or oor)` in Lua at all. Stamp the secret
        -- itself PLUS a plain companion flag, and let the tick push the choice into
        -- SetAlphaFromBoolean -- the same move ApplyOORAlpha makes. The plain flag is what
        -- the tick is allowed to test; the secret is only ever forwarded to the setter.
        frame.border.dfOORActive  = true
        frame.border.dfOORInRange = inRange
        frame.border.dfOORAlpha   = oorAlpha
    else
        -- Whole-frame mode: reset to full so a stale element-specific fade
        -- doesn't linger; the frame's alpha cascade handles the OOR dim.
        frame.border:SetAlpha(alpha)
        frame.border.dfOORActive = false
    end
end

-- ============================================================
-- BUFF ICONS APPEARANCE
-- ============================================================

function DF:UpdateBuffIconsAppearance(frame)
    if not IsDandersFrame(frame) then return end

    -- 12.1: the buff row is a container; the whole row fades as one (alpha on
    -- the row's plain anchor frame is ours — secret geometry only drives layout).
    local row = frame.buffFactory and frame.buffFactory:GetFrame()
    if not row then return end

    local db = GetDB(frame)
    if not db then return end

    -- ★ Test frames pass through: the only unit reads are IsDeadOrOffline and
    -- GetInRange, both stamp-aware.
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end

    local deadOrOffline = IsDeadOrOffline(frame)
    local inRange = GetInRange(frame)

    -- ☠ THE ROW'S OWN OPACITY MUST BE THE BASE, NOT AN AFTERTHOUGHT.
    -- DriveBuffFactory sets this same frame's alpha to db.buffAlpha and caches it in
    -- frame.dfBuffFactoryAlpha; this function then OVERWROTE it with a fade value
    -- that did not include it -- so the row opacity slider was silently reset to 1
    -- by the next range/appearance pass, and the cache meant the drive never put
    -- it back. LIVE-ONLY: the preview always multiplied the two, so it was right
    -- and live was wrong. (Audit, 2026-08-07.)
    local base = db.buffAlpha or 1
    local alpha = base
    if deadOrOffline and db.fadeDeadFrames then
        alpha = alpha * (db.fadeDeadAuras or 1.0)
    end

    if db.oorEnabled then
        ApplyOORAlpha(row, inRange, alpha, base * (db.oorAurasAlpha or 0.2))
    else
        row:SetAlpha(alpha)
    end
end

-- ============================================================
-- DEBUFF ICONS APPEARANCE
-- ============================================================

function DF:UpdateDebuffIconsAppearance(frame)
    if not IsDandersFrame(frame) then return end

    local row = frame.debuffFactory and frame.debuffFactory:GetFrame()
    if not row then return end

    local db = GetDB(frame)
    if not db then return end

    -- ★ Test frames pass through: the only unit reads are IsDeadOrOffline and
    -- GetInRange, both stamp-aware.
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end

    local deadOrOffline = IsDeadOrOffline(frame)
    local inRange = GetInRange(frame)

    -- ☠ THE ROW'S OWN OPACITY MUST BE THE BASE, NOT AN AFTERTHOUGHT.
    -- DriveDebuffFactory sets this same frame's alpha to db.debuffAlpha and caches it in
    -- frame.dfDebuffFactoryAlpha; this function then OVERWROTE it with a fade value
    -- that did not include it -- so the row opacity slider was silently reset to 1
    -- by the next range/appearance pass, and the cache meant the drive never put
    -- it back. LIVE-ONLY: the preview always multiplied the two, so it was right
    -- and live was wrong. (Audit, 2026-08-07.)
    local base = db.debuffAlpha or 1
    local alpha = base
    if deadOrOffline and db.fadeDeadFrames then
        alpha = alpha * (db.fadeDeadAuras or 1.0)
    end

    if db.oorEnabled then
        ApplyOORAlpha(row, inRange, alpha, base * (db.oorAurasAlpha or 0.2))
    else
        row:SetAlpha(alpha)
    end
end

-- ============================================================
-- ICON APPEARANCE (Role, Leader, Raid Target, Ready Check, Center Status)
-- These icons don't change color, just alpha
-- ============================================================

function DF:UpdateRoleIconAppearance(frame)
    if not IsDandersFrame(frame) then return end
    if not frame.roleIcon then return end

    local db = GetDB(frame)
    if not db then return end

    local deadOrOffline = IsDeadOrOffline(frame)
    local inRange = GetInRange(frame)
    
    local alpha = db.roleIconAlpha or 1.0
    if deadOrOffline and db.fadeDeadFrames then
        alpha = (db.fadeDeadIcons or 1.0) * (db.roleIconAlpha or 1.0)
    end

    if db.oorEnabled then
        local oorAlpha = db.oorIconsAlpha or 0.5
        ApplyOORAlpha(frame.roleIcon, inRange, alpha, oorAlpha)
    else
        frame.roleIcon:SetAlpha(alpha)
    end
end

function DF:UpdateLeaderIconAppearance(frame)
    if not IsDandersFrame(frame) then return end
    if not frame.leaderIcon then return end
    
    local db = GetDB(frame)
    if not db then return end
    
    -- ★ Test frames pass through: unit reads go via the stamp-aware helpers.
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end
    
    local deadOrOffline = IsDeadOrOffline(frame)
    local inRange = GetInRange(frame)
    
    local alpha = db.leaderIconAlpha or 1.0
    if deadOrOffline and db.fadeDeadFrames then
        alpha = (db.fadeDeadIcons or 1.0) * (db.leaderIconAlpha or 1.0)
    end

    if db.oorEnabled then
        local oorAlpha = db.oorIconsAlpha or 0.5
        ApplyOORAlpha(frame.leaderIcon, inRange, alpha, oorAlpha)
    else
        frame.leaderIcon:SetAlpha(alpha)
    end
end

function DF:UpdateRaidTargetIconAppearance(frame)
    if not IsDandersFrame(frame) then return end
    if not frame.raidTargetIcon then return end
    
    local db = GetDB(frame)
    if not db then return end
    
    -- ★ Test frames pass through: unit reads go via the stamp-aware helpers.
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end
    
    local deadOrOffline = IsDeadOrOffline(frame)
    local inRange = GetInRange(frame)
    
    local alpha = db.raidTargetIconAlpha or 1.0
    if deadOrOffline and db.fadeDeadFrames then
        alpha = (db.fadeDeadIcons or 1.0) * (db.raidTargetIconAlpha or 1.0)
    end

    if db.oorEnabled then
        local oorAlpha = db.oorIconsAlpha or 0.5
        ApplyOORAlpha(frame.raidTargetIcon, inRange, alpha, oorAlpha)
    else
        frame.raidTargetIcon:SetAlpha(alpha)
    end
end

function DF:UpdateReadyCheckIconAppearance(frame)
    if not IsDandersFrame(frame) then return end
    if not frame.readyCheckIcon then return end
    
    local db = GetDB(frame)
    if not db then return end
    
    -- ★ Test frames pass through: unit reads go via the stamp-aware helpers.
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end
    
    local deadOrOffline = IsDeadOrOffline(frame)
    local inRange = GetInRange(frame)
    
    local alpha = db.readyCheckIconAlpha or 1.0
    if deadOrOffline and db.fadeDeadFrames then
        alpha = (db.fadeDeadIcons or 1.0) * (db.readyCheckIconAlpha or 1.0)
    end

    if db.oorEnabled then
        local oorAlpha = db.oorIconsAlpha or 0.5
        ApplyOORAlpha(frame.readyCheckIcon, inRange, alpha, oorAlpha)
    else
        frame.readyCheckIcon:SetAlpha(alpha)
    end
end

-- ============================================================
-- DISPEL OVERLAY APPEARANCE
-- ============================================================

function DF:UpdateDispelOverlayAppearance(frame)
    if not IsDandersFrame(frame) then return end

    local db = GetDB(frame)
    if not db then return end

    -- ★ Test frames pass through: unit reads go via the stamp-aware helpers.
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end

    -- 12.1 factory path: one alpha on the handle's plain anchor WINDOW (ours) —
    -- the whole subtree rides it (every slot button, the slot-hosted widgets, the
    -- game-mode icon slots) and it MULTIPLIES with the pulse animation's widget
    -- alpha. ⚠ NEVER write alpha on the slot BUTTONS themselves: PTR-5 made
    -- AuraButtons blanket-forbidden while auras are secret, so ANY method call on
    -- them (SetAlpha included) from addon code errors in restricted content —
    -- the old per-button loop error-spammed every range tick in raid combat
    -- (live-caught). Same channel the buff/defensive row fades already use.
    local h = frame.dispelFactory
    if h and h.GetFrame then
        local w = h:GetFrame()
        if w then
            local fDeadAlpha = 1.0
            if IsDeadOrOffline(frame) and db.fadeDeadFrames then
                fDeadAlpha = db.fadeDeadBackground or 1
            end
            if db.oorEnabled then
                local fInRange = GetInRange(frame)
                local fOorAlpha = db.oorDispelOverlayAlpha or 0.2
                ApplyOORAlpha(w, fInRange, fDeadAlpha, fDeadAlpha * fOorAlpha)
            else
                w:SetAlpha(fDeadAlpha)
            end
        end
    end

    if not frame.dfDispelOverlay then return end

    local deadOrOffline = IsDeadOrOffline(frame)
    local inRange = GetInRange(frame)
    local overlay = frame.dfDispelOverlay

    -- Dead/offline fade multiplier (1.0 when alive)
    local deadAlpha = 1.0
    if deadOrOffline and db.fadeDeadFrames then
        deadAlpha = db.fadeDeadBackground or 1
    end

    -- ★ ONE CHANNEL PER VALUE. The paint (StyleOverlayRegions) owns the CONFIGURED
    -- opacity and puts it on the gradient texture's VERTEX alpha and the ring's vertex;
    -- this sweep owns only the dead/out-of-range FADES, on the FRAME alpha. The two
    -- channels multiply at render, so putting the configured value in both — which is
    -- what the line below used to do, via the resolver — rendered it SQUARED whenever
    -- both had run: dragging the opacity slider showed the test preview at alpha²
    -- while release showed alpha ("about half", exactly half at 0.5 — field-caught,
    -- Krathe 2026-08-13).
    -- ☠ The old comment here justified the resolver read with an OOR snap-back from an
    -- era when the FRAME alpha was the configured value's carrier. It is not any more;
    -- vertex holds the config through every fade transition, so base 1 cannot snap
    -- anything bright.
    -- ICONS are the one element whose config lives on the FRAME alpha (the paint sets
    -- icon:SetAlpha(dispelIconAlpha) — vertex there is the bleed-colour tint), so this
    -- sweep must COMPOSE the config in rather than overwrite it: the old hardcoded 1.0
    -- clobbered Symbol Opacity back to full on every range tick.
    local gradAlpha = 1.0 * deadAlpha
    local brdAlpha  = 1.0 * deadAlpha
    local icnAlpha  = (db.dispelIconAlpha or 1) * deadAlpha

    if db.oorEnabled then
        local oorAlpha = db.oorDispelOverlayAlpha or 0.2
        ApplyOORAlpha(overlay.gradient,     inRange, gradAlpha, gradAlpha * oorAlpha)
        -- One ring host now, not four strips (see BuildDispelOverlayWidget).
        ApplyOORAlpha(overlay.borderRingHost, inRange, brdAlpha, brdAlpha * oorAlpha)
        if overlay.icons then
            for _, icon in pairs(overlay.icons) do
                ApplyOORAlpha(icon, inRange, icnAlpha, icnAlpha * oorAlpha)
            end
        end
        if DF.ApplyDispelOverlayAppearance then
            DF:ApplyDispelOverlayAppearance(frame)
        end
    else
        if overlay.gradient     then overlay.gradient:SetAlpha(gradAlpha) end
        if overlay.borderRingHost then overlay.borderRingHost:SetAlpha(brdAlpha) end
        if overlay.icons then
            for _, icon in pairs(overlay.icons) do
                icon:SetAlpha(icnAlpha)
            end
        end
    end
end

-- ============================================================
-- MISSING BUFF ICON APPEARANCE
-- ============================================================

function DF:UpdateMissingBuffAppearance(frame)
    if not IsDandersFrame(frame) then return end

    -- 12.1 factory strip (Auras.lua bridge): the whole strip fades as one — the
    -- badges are plain DF frames (alpha is ours; the secret geometry only drives
    -- position).
    local strip = frame.missingBuffStrip
    -- ☠ DELIBERATELY NOT GATED ON :IsShown(). The strip is HIDDEN while the unit is out of
    -- range (DriveMissingBuffFactory, Features/Auras.lua) — so a pass that writes the
    -- out-of-range alpha just before the driver hides it leaves the strip carrying that
    -- faded value, and the pass that would restore it skips, because at the moment it ran
    -- the strip was hidden. Nothing recomputes until the next range edge, so it comes back
    -- dim and stays dim.
    -- Alpha on a hidden frame costs nothing and is correct the instant it is shown. A
    -- visibility guard on an alpha updater buys nothing but a stale value.
    -- ⚠ The three bars below (absorb / heal-absorb / heal prediction) carry the SAME guard
    -- and the same latent staleness — hidden when the effect expires, re-shown later at
    -- whatever alpha they last took, which UpdateAbsorbBarAppearance's own comment already
    -- describes for the overflow bar. NOT changed here: those do more than set alpha (the
    -- overflow path re-drives visibilityHelpers), so they want their own pass and their own
    -- test rather than riding along with a missing-buff fix.
    if not strip then return end

    local db = GetDB(frame)
    if not db then return end

    -- ★ TEST FRAMES PASS THROUGH. Every unit read this function makes now goes via
    -- GetInRange / IsDeadOrOffline, both stamp-aware, so it renders a preview frame
    -- correctly. LIVE frames still bail while test mode is on -- they are hidden
    -- behind the preview and repainting them is wasted work. (Audit, 2026-08-07.)
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end

    local deadOrOffline = IsDeadOrOffline(frame)
    local inRange = GetInRange(frame)

    local alpha = 1.0
    if deadOrOffline and db.fadeDeadFrames then
        alpha = db.fadeDeadIcons or 1.0
    end

    if db.oorEnabled then
        ApplyOORAlpha(strip, inRange, alpha, db.oorMissingBuffAlpha or 0.5)
    else
        strip:SetAlpha(alpha)
    end
end

-- ============================================================
-- ABSORB BAR APPEARANCE
-- ============================================================

function DF:UpdateAbsorbBarAppearance(frame)
    if not IsDandersFrame(frame) then return end
    if not frame.dfAbsorbBar then return end

    -- ☠ NOT gated on :IsShown() — same reasoning as UpdateMissingBuffAppearance above,
    -- which flagged these three as carrying the same guard. VERIFIED, not assumed: the
    -- ONLY caller of this function is UpdateAllElementAppearance (the range-tick sweep),
    -- and nothing re-runs it when the bar is shown. So a pass that lands while the bar is
    -- hidden is skipped, the bar keeps whatever alpha it last got, and it comes back at a
    -- stale value until the next range edge. Alpha on a hidden frame costs nothing and is
    -- correct the instant it is shown; a visibility guard on an alpha updater buys nothing
    -- but a stale value. (The old comment called this "PERF".)

    local db = GetDB(frame)
    if not db then return end

    -- ★ TEST FRAMES PASS THROUGH -- this function's only unit read is GetInRange,
    -- which already prefers frame.dfInRange. The preview had NO counterpart for
    -- this key at all, so the bar simply never faded out of range there.
    -- (Audit, 2026-08-07.)
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end
    if not db.oorEnabled then return end

    local inRange = GetInRange(frame)
    local oorAlpha = db.oorAbsorbBarAlpha or 0.5
    local mode = db.absorbBarMode or "OVERLAY"

    if mode == "ATTACHED_OVERFLOW" then
        -- The overflow bar's alpha is only written by UpdateAbsorb (Bars.lua) on
        -- UNIT_ABSORB events; without intervention here, it stays at the last
        -- alpha UpdateAbsorb gave it across range transitions, so it can be stuck
        -- at full opacity OOR until the next absorb event refreshes things.
        --
        -- Delegate to Bars.lua: it recomputes isClamped via the cached absorb
        -- calculator and re-drives the existing visibilityHelpers — the proven
        -- secret-safe pattern. We CANNOT do the composition here by reading
        -- helper alphas back as numbers and multiplying: a number that came
        -- through SetAlphaFromBoolean(secretBool, ...) is itself a secret number
        -- and arithmetic on it taints execution.
        if DF.RefreshAbsorbBarVisibility then
            DF:RefreshAbsorbBarVisibility(frame)
        else
            ApplyOORAlpha(frame.dfAbsorbBar, inRange, 1.0, oorAlpha)
        end
    else
        -- OVERLAY / FLOATING / ATTACHED: a single visible bar, fade it directly.
        ApplyOORAlpha(frame.dfAbsorbBar, inRange, 1.0, oorAlpha)
    end
end

-- ============================================================
-- HEAL ABSORB BAR APPEARANCE
-- ============================================================

function DF:UpdateHealAbsorbBarAppearance(frame)
    if not IsDandersFrame(frame) then return end
    if not frame.dfHealAbsorbBar then return end

    -- ☠ NOT gated on :IsShown() — see UpdateAbsorbBarAppearance above for the verified
    -- reasoning (one caller, the range-tick sweep; nothing re-runs it on show).

    local db = GetDB(frame)
    if not db then return end
    
    -- ★ TEST FRAMES PASS THROUGH -- this function's only unit read is GetInRange,
    -- which already prefers frame.dfInRange. The preview had NO counterpart for
    -- this key at all, so the bar simply never faded out of range there.
    -- (Audit, 2026-08-07.)
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end
    
    local inRange = GetInRange(frame)
    
    if db.oorEnabled then
        local oorAlpha = db.oorAbsorbBarAlpha or 0.5
        ApplyOORAlpha(frame.dfHealAbsorbBar, inRange, 1.0, oorAlpha)
    end
end

-- ============================================================
-- HEAL PREDICTION BAR APPEARANCE
-- ============================================================

function DF:UpdateHealPredictionBarAppearance(frame)
    if not IsDandersFrame(frame) then return end
    if not frame.dfHealPredictionBar then return end

    -- ☠ NOT gated on :IsShown() — see UpdateAbsorbBarAppearance above for the verified
    -- reasoning (one caller, the range-tick sweep; nothing re-runs it on show).

    local db = GetDB(frame)
    if not db then return end
    
    -- ★ TEST FRAMES PASS THROUGH -- this function's only unit read is GetInRange,
    -- which already prefers frame.dfInRange. The preview had NO counterpart for
    -- this key at all, so the bar simply never faded out of range there.
    -- (Audit, 2026-08-07.)
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end
    
    local inRange = GetInRange(frame)
    
    if db.oorEnabled then
        local oorAlpha = db.oorAbsorbBarAlpha or 0.5
        ApplyOORAlpha(frame.dfHealPredictionBar, inRange, 1.0, oorAlpha)
        -- Second segment (others' heals in SPLIT mode) fades to match. Nil-checked, not
        -- shown-checked: the segment only exists in SPLIT mode, but a hidden one still
        -- needs the current alpha for when it comes back (same rule as the bar itself).
        if frame.dfHealPredictionBar2 then
            ApplyOORAlpha(frame.dfHealPredictionBar2, inRange, 1.0, oorAlpha)
        end
    end
end

-- ============================================================
-- DEFENSIVE ICON APPEARANCE
-- ============================================================

function DF:UpdateDefensiveIconAppearance(frame)
    if not IsDandersFrame(frame) then return end

    local row = frame.defensiveFactory and frame.defensiveFactory:GetFrame()
    if not row then return end

    local db = GetDB(frame)
    if not db then return end

    -- ★ TEST FRAMES PASS THROUGH. Every unit read this function makes now goes via
    -- GetInRange / IsDeadOrOffline, both stamp-aware, so it renders a preview frame
    -- correctly. LIVE frames still bail while test mode is on -- they are hidden
    -- behind the preview and repainting them is wasted work. (Audit, 2026-08-07.)
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end

    local inRange = GetInRange(frame)

    if db.oorEnabled then
        ApplyOORAlpha(row, inRange, 1.0, db.oorDefensiveIconAlpha or 0.5)
    else
        row:SetAlpha(1.0)
    end
end

-- (Removed) TARGETED SPELL CONTAINER APPEARANCE — DF:UpdateTargetedSpellAppearance
-- and its DF.UpdateTargetedSpellAlpha alias. It faded frame.targetedSpellContainer,
-- which no longer exists; this was the GROUP container only, and Personal Targeted
-- never came through here.

-- ============================================================
-- AURA DESIGNER INDICATORS APPEARANCE
-- Handles OOR alpha for placed AD indicators (icons, squares, bars)
-- ============================================================

-- Walk every Aura Designer indicator on a frame, handing the caller the region to
-- set alpha on plus that indicator's own base alpha.
--
-- ★ SHARED WITH TEST MODE ON PURPOSE. The preview cannot just call
-- UpdateAuraDesignerAppearance: it computes its own per-element alphas because it has
-- no whole-frame SetAlpha cascade to fall back on in simple range-fade mode. Copying
-- the walk over there is exactly how the missing-buff strip and defensive row
-- silently stopped fading in the preview. One walk, two alpha policies.
--
-- ☠ ASK FOR THE ALPHA HOST, NEVER GetFrame(). This used to fade h:GetFrame(), which
-- for a per-indicator container is DF's own anchor frame -- fine. A collapsed slot's
-- GetFrame() is the aura BUTTON, which carries DenyTaintedAccessWhenAurasAreSecret:
-- this walk runs from the range update, which is tainted, so every call threw the
-- moment auras went secret (43 errors, "forbidden object", reported 2026-08-06).
-- GetAlphaHost answers with the DF-owned frame that every one of that indicator's
-- regions hangs off — its own anchor frame for a container, dfLevelHost for a
-- collapsed slot — so fading it fades the indicator whole. Nil only if host creation
-- failed, hence the guard. See SlotHandle:GetAlphaHost.
local AD_STORE_KEYS = { "healthbar", "background", "border", "placed",
                        "nametext", "healthtext" }

-- ☠ THE WRITE IS PROTECTED, AND A DENIED HOST IS REMEMBERED.
-- GetAlphaHost is supposed to answer with a DF-owned frame, so in principle a tainted
-- alpha write to it is always legal. In practice it is not guaranteed: the host is a CHILD
-- of the aura button, and the button carries DenyTaintedAccessWhenAurasAreSecret. DF's
-- design rests on access restrictions NOT descending to children (see SlotHandle:GetAlphaHost)
-- — a Blizzard-side implementation detail, not a contract, and one that has already bitten
-- once (43 errors) and again on a later build (75 errors from this exact call):
--     calling 'SetAlphaFromBoolean' on bad self (Attempt to access forbidden object
--     from code tainted by an AddOn)
--
-- Two things were wrong with letting it throw:
--   1. It errors PER HOST PER RANGE UPDATE. Range runs on a timer over every frame, so one
--      denied host is not one error, it is a permanent storm — the 75x is the loop, not 75
--      separate faults.
--   2. It aborts the whole walk. Everything after the first denied host in that pass — the
--      other indicators, the other store keys — silently stops being faded at all.
--
-- So: pcall the callback, and latch the failure on the handle so a host that is denied once
-- is skipped from then on rather than retried every tick. The indicator keeps its base alpha
-- (no out-of-range fade) instead of taking the frame down, which is the same degrade the
-- nil-host path already takes. AuraContainer's own base-alpha write to this very host is
-- already pcall'd for the same reason (`pcall(host.SetAlpha, host, ...)`); this closes the
-- gap on the OOR side, and covers every consumer of the walker rather than just that one.
--
-- ⚠ The latch is per HANDLE, so it clears naturally when the slot is rebuilt or re-acquired.
-- If a build makes the restriction descend permanently, the visible symptom is AD indicators
-- that no longer fade out of range — not an error storm, and not a dead range pass.
-- `retryDenied` re-arms the refusal latch for ONE pass. See the note on the latch below
-- and the range-edge call in UpdateAuraDesignerAppearance.
function DF:ForEachAuraDesignerAlphaHost(frame, fn, retryDenied)
    local store = frame and frame.dfADFactory
    if not (store and fn) then return end
    for _, storeKey in ipairs(AD_STORE_KEYS) do
        local t = store[storeKey]
        if t then
            for _, entry in pairs(t) do
                local h = entry and entry.handle
                -- ⚠ The skip is scoped to the CURRENT layout version, not forever. A flat
                -- boolean latch turned a possibly-transient refusal into a permanent one:
                -- the button batch is built lazily and the engine now defers
                -- AddAccessRestrictions to PLAYER_ENTERING_WORLD, so a host can be
                -- momentarily unwritable during login and perfectly writable a second
                -- later. Keying the skip to DF.auraLayoutVersion means any settings change
                -- or rebuild re-arms it instead of leaving that indicator dark for the
                -- session — and it still costs one failed call per version, not per tick.
                -- ☠ AND THE LAYOUT VERSION IS NOT ENOUGH EITHER. A refusal is usually
                -- TRANSIENT, but the layout version only moves on a settings change or a
                -- rebuild — so a host that was faded out of range and then refused one
                -- write stayed faded until the user happened to change a setting. Krathe
                -- hit this repeatedly: "I can let the buff drop, put it back up and it's
                -- still faded", and changing any AD setting cleared it instantly, which is
                -- what proved the refusal transient rather than the host unwritable
                -- (2026-08-13).
                -- ⇒ `retryDenied` re-arms for one pass on a RANGE EDGE, which is exactly
                -- when a stale alpha becomes visible and exactly when the value we want to
                -- write has changed. Cost stays bounded: one failed call per transition,
                -- not per tick — the thing the latch was protecting.
                local ver = DF.auraLayoutVersion or 0
                local denied = h and h._dfAlphaHostDeniedVer == ver and not retryDenied
                if retryDenied and h then h._dfAlphaHostDeniedVer = nil end
                local f = (h and not denied and h.GetAlphaHost) and h:GetAlphaHost() or nil
                if f then
                    local ok, err = pcall(fn, f, h._dfADBaseAlpha or 1.0, h)
                    if not ok then
                        -- ☠ A REFUSAL IS NOT EVIDENCE THE HOST IS UNWRITABLE, and latching
                        -- on it alone is what froze indicators at the FADE value.
                        -- The refused call is almost always SetAlphaFromBoolean, which
                        -- ApplyOORAlpha is forced to use when the range answer arrives
                        -- SECRET — IsSpellInRange returns nil for a tick and Range.lua falls
                        -- back to UnitInRange, which is secret on Midnight. These hosts sit
                        -- under DenyTaintedAccessWhenAurasAreSecret and refuse that setter
                        -- specifically, while accepting a PLAIN SetAlpha perfectly well.
                        -- So: retry plain, and latch only if THAT fails too. A host that
                        -- merely dislikes the secret-aware setter gets restored to base and
                        -- is never blacklisted.
                        -- ⚠ The cost is a one-tick cosmetic miss: through the secret window
                        -- the indicator shows base alpha instead of the fade. Showing an
                        -- indicator too brightly for one tick beats freezing it dim for the
                        -- session. Fail toward visible.
                        -- ★ Independently reached by Danders's agent from a separate report
                        -- (an Evoker healer whose icons stayed transparent until /reload) —
                        -- their Option A. The probe below already existed here and was doing
                        -- this exact call FOR LOGGING ONLY, once per session behind the
                        -- warning gate, so the answer was being computed and thrown away.
                        local okPlain = pcall(f.SetAlpha, f, h._dfADBaseAlpha or 1.0)
                        if not okPlain then
                            h._dfAlphaHostDeniedVer = ver
                            -- ★ RESTRICTION-LIFT RE-QUEUE (EllesmereUI's shape). A host that
                            -- refuses even a plain write is restricted RIGHT NOW — for a
                            -- slot host that means auras are secret, i.e. combat — and the
                            -- range-edge retry can be consumed while that holds (edge fires
                            -- mid-fight, write refused, re-latched, and no second edge comes
                            -- after combat because the unit is already in range; field report
                            -- 2026-08-14, "enter combat while someone is out of range").
                            -- So remember the FRAME and retry its walk when combat drops,
                            -- which is exactly when writability returns. The regen handler
                            -- below clears the entry before retrying; a still-refused host
                            -- lands back here and re-queues itself.
                            DF._adDeniedHostFrames = DF._adDeniedHostFrames or {}
                            DF._adDeniedHostFrames[frame] = true
                        end
                        -- Name the method that was refused, not just the error: whether
                        -- PLAIN SetAlpha is rejected or only the secret-aware setter is the
                        -- difference between "wrong setter" and "the host is unwritable at
                        -- all", and those have completely different fixes.
                        if not DF._warnedADAlphaHost then
                            DF._warnedADAlphaHost = true
                            -- ☠ EVERY probe of a refused object must itself be pcall'd.
                            -- This block previously called f:GetDebugName() bare while
                            -- building the log arguments — inside the very handler that
                            -- exists because calls to this object throw. It threw, before
                            -- DebugWarn ever ran, so the fault it was meant to describe was
                            -- replaced by a fresh error and nothing was logged at all.
                            -- GetDebugName is a pure READ and it is still refused: the host
                            -- is forbidden to tainted code for ALL access, not just setters.
                            -- (The plain-write probe moved ABOVE this block: its result now
                            -- decides whether to latch, instead of only being logged once.)
                            local okName, name = pcall(f.GetDebugName, f)
                            DF:DebugWarn("AURACONTAINER",
                                "AD alpha host refused a tainted write. plainSetAlphaOK=%s readableName=%s host=%s err=%s",
                                tostring(okPlain), tostring(okName),
                                okName and tostring(name) or "<refused>",
                                tostring(err))
                        end
                    end
                end
            end
        end
    end
end

function DF:UpdateAuraDesignerAppearance(frame, forceRetryDenied)
    if not IsDandersFrame(frame) then return end

    -- 12.1: AD indicators are factory containers; fade each container's plain
    -- anchor frame (base config alpha times the OOR fade — alpha is ours even
    -- though the slot geometry is secret).
    if not frame.dfADFactory then return end

    local db = GetDB(frame)
    if not db then return end

    -- ★ TEST FRAMES PASS THROUGH. Every unit read this function makes now goes via
    -- GetInRange / IsDeadOrOffline, both stamp-aware, so it renders a preview frame
    -- correctly. LIVE frames still bail while test mode is on -- they are hidden
    -- behind the preview and repainting them is wasted work. (Audit, 2026-08-07.)
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end

    local inRange = GetInRange(frame)
    local oorOn = db.oorEnabled
    local oorAlpha = db.oorAuraDesignerAlpha or 0.2

    -- ★ RANGE EDGE ⇒ retry any host whose write was refused. A refusal parks the host at
    -- whatever alpha it last took, and out of range that is the FADED value — so a single
    -- transient refusal left the indicator dark until a settings change happened to bump
    -- the layout version. The edge is the right trigger twice over: it is when the stale
    -- alpha becomes wrong, and it is when the value we want to write has changed.
    -- ⚠ Only stamped for a PLAIN boolean. GetInRange passes a secret through for classes
    -- with no friendly spells, and comparing those is not ours to do — a secret range just
    -- keeps the existing latch behaviour rather than forcing a retry every pass.
    -- `forceRetryDenied` is the restriction-lift re-queue's handle on the same machinery:
    -- combat end is a WRITABILITY edge, not a range edge, so it arrives via parameter.
    local rangeEdge = false
    if not (issecretvalue and issecretvalue(inRange)) then
        local now = inRange and true or false
        rangeEdge = (frame._dfADLastInRange ~= nil) and (frame._dfADLastInRange ~= now)
        frame._dfADLastInRange = now
    end

    DF:ForEachAuraDesignerAlphaHost(frame, function(f, base, h)
        -- ☠ SLOT-BACKED HOSTS TAKE BASE ONLY, NEVER THE FADE. Their range fade is the
        -- slot OWNER host's job (below) — the walk writing fades here too meant the two
        -- multiplied (0.2 × 0.2 = the "super faded" field report), and a fade written
        -- out of combat could strand when combat made the host unwritable. The header
        -- above the slot-owner block claims walk writes on these are "refused" — that
        -- is only true IN COMBAT; out of combat they land, which is how the fade got in.
        -- EllesmereUI reached the same rule from the same bug: never write fades into
        -- a Blizzard button's subtree; fade the DF-owned ancestor and let it cascade.
        -- Base still applies (it is per-indicator and the cascade cannot carry it),
        -- and an unconditional base write self-repairs any fade stranded before this fix.
        if h and h.button then
            f:SetAlpha(base)
        elseif oorOn then
            ApplyOORAlpha(f, inRange, base, oorAlpha)
        else
            f:SetAlpha(base)
        end
    end, rangeEdge or forceRetryDenied)

    -- ★ SLOT-BACKED INDICATORS FADE HERE, not in the walk above — and now BY CHOICE,
    -- not by refusal. This header used to claim every walk write on a per-slot host is
    -- refused; that is only true in combat, and the out-of-combat writes that DID land
    -- are how fades ended up on both layers at once (multiplied) and stranded across
    -- combat. The walk now writes slot hosts base-only; range fade lives here alone.
    -- The slot owner's DF-created anchor frame sits ABOVE the container, is ours, and
    -- multiplies its alpha down over every slot — one legal write covers all of them.
    -- Frame-wide is the correct grain for range anyway.
    -- No-op on frames that never took a shared slot (accessor returns nil).
    local slotHost = DF.AuraContainer and DF.AuraContainer.GetSlotOwnerAlphaHost
        and DF.AuraContainer:GetSlotOwnerAlphaHost(frame)
    if slotHost then
        -- ☠ PROTECTED, like every other write in this block. This was the ONE alpha
        -- write in the AD pass outside a pcall; a refusal here (the anchor is ours,
        -- but the engine's restriction surface has moved twice this year) threw out
        -- of UpdateAllElementAppearances and stranded every element after it — the
        -- buff and debuff rows included — at their pre-transition alpha. Refused ⇒
        -- queue the frame for the restriction-lift retry, same as a denied host.
        local okSlot
        if oorOn then
            okSlot = pcall(ApplyOORAlpha, slotHost, inRange, 1.0, oorAlpha)
        else
            okSlot = pcall(slotHost.SetAlpha, slotHost, 1.0)
        end
        if not okSlot then
            DF._adDeniedHostFrames = DF._adDeniedHostFrames or {}
            DF._adDeniedHostFrames[frame] = true
        end
    end
end

-- ============================================================
-- AD ALPHA HOST PROBE  (/df debug adalpha [unit])
-- ============================================================
-- ☠ ANSWERS ONE QUESTION: has the aura button's access restriction started DESCENDING
-- TO ITS CHILDREN?
--
-- The whole AD fade design rests on it not doing so. The note above
-- ForEachAuraDesignerAlphaHost says it outright: the host is a CHILD of the aura button,
-- the button carries DenyTaintedAccessWhenAurasAreSecret, and DF assumes restrictions do
-- not descend — "a Blizzard-side implementation detail, not a contract". It even names
-- the symptom to expect if that assumption breaks: *AD indicators that no longer fade out
-- of range — not an error storm, and not a dead range pass.* Which is the field report
-- this probe exists to settle (Krathe, 2026-08-26, with `AD alpha host refused a tainted
-- write ... plainSetAlphaOK=false` in the log).
--
-- ☠☠ IT NEVER CALLS A METHOD ON A HOST TO IDENTIFY IT. The refused object rejects READS
-- too — `readableName=false` in that log line is GetDebugName being refused — so probing
-- it for identity is how you replace the fault with a fresh error and learn nothing (the
-- exact mistake recorded at the warning site). Identity comes from `rawequal` against
-- frames we already hold, which cannot dispatch into the object, and everything that does
-- touch a host is pcall'd and writes only the base alpha the walk writes anyway.
--
-- Read the output as a PATTERN, not per row: a child refused while its DF-owned ancestor
-- accepts is the descent, and the cure is to fade the ancestor and let it cascade — which
-- is what the slot-owner block already does, and what EllesmereUI does throughout.
function DF:DebugADAlphaHosts(unit)
    unit = (unit and unit ~= "" and unit) or "player"
    local o = DF:Out("AD Alpha Hosts", "unit " .. unit)

    local frame
    if DF.IterateAllFrames then
        DF:IterateAllFrames(function(f) if not frame and f.unit == unit then frame = f end end)
    end
    if not frame then
        o:Line("No DF party/raid/arena frame is currently driving that unit.", "WARN")
        return
    end

    -- Baseline: frames we KNOW are ours. If either of these is refused the client has
    -- moved the ground under the whole addon and nothing below means what it looks like.
    local function probe(f)
        if not f then return "absent" end
        local okW = pcall(f.SetAlpha, f, f.dfProbeBase or 1.0)
        local okR = pcall(f.GetDebugName, f)
        return (okW and "write OK" or "WRITE REFUSED") .. " / " .. (okR and "name OK" or "name refused")
    end

    o:Section("Baseline (DF-owned)")
    o:Field("unit frame", probe(frame), "NEUTRAL")
    o:Field("contentOverlay", probe(frame.contentOverlay), "NEUTRAL")
    local slotHost = DF.AuraContainer and DF.AuraContainer.GetSlotOwnerAlphaHost
        and DF.AuraContainer:GetSlotOwnerAlphaHost(frame)
    o:Field("slot-owner anchor", probe(slotHost), "NEUTRAL")

    -- ★ WHAT THE ALPHAS ACTUALLY ARE, not merely whether a write is permitted. The
    -- writability half answered "everything fine" while the fade was plainly broken, and I
    -- then produced three contradictory theories from reading code instead of measuring.
    -- ☠ THE TWO MODES TAKE DIFFERENT ROUTES, which is why one of them works:
    --   whole-frame (oorEnabled off) -- the FRAME is faded and the alpha CASCADES to the
    --     indicator. Nothing needs to write to an AD host at all. Field: works.
    --   element (oorEnabled on) -- the frame is deliberately PINNED at base so each element
    --     owns its own look, and the ONLY thing that fades AD is one write to the
    --     slot-owner anchor. Field: does not work.
    -- So the question was never "can we write". It is "what value did that one write leave,
    -- and does it reach the icon" -- both readable, on DF-owned frames, for free.
    local pdb = GetDB(frame)
    o:Section("Alpha readings")
    o:Line(string.format("mode: %s", (pdb and pdb.oorEnabled)
        and "ELEMENT (per-element fades)" or "WHOLE-FRAME (cascade)"))
    o:Line(string.format("configured AD out-of-range alpha: %s",
        tostring((pdb and pdb.oorAuraDesignerAlpha) or 0.2)))
    local function alphaOf(f, label)
        if not f then o:Field(label, "absent", "NEUTRAL") return end
        local okA, a = pcall(f.GetAlpha, f)
        local okE, e = pcall(f.GetEffectiveAlpha, f)
        o:Field(label, string.format("alpha=%s effective=%s",
            okA and string.format("%.2f", a or 0) or "unreadable",
            okE and string.format("%.2f", e or 0) or "n/a"), "NEUTRAL")
    end
    alphaOf(frame, "unit frame")
    alphaOf(slotHost, "slot-owner anchor")
    local astore = frame.dfADFactory
    if astore then
        for _, storeKey in ipairs(AD_STORE_KEYS) do
            local t = astore[storeKey]
            if t then
                for entryKey, entry in pairs(t) do
                    local h = entry and entry.handle
                    local f = (h and h.GetAlphaHost) and h:GetAlphaHost() or nil
                    if f then alphaOf(f, storeKey .. "/" .. tostring(entryKey)) end
                end
            end
        end
    end
    o:Line("⚠ Compare the effective alphas against the configured value above. Anchor faded "
        .. "but an indicator not = the cascade breaks between them. Anchor itself unfaded = "
        .. "the one write that should have faded it never landed.", "NEUTRAL")

    local store = frame.dfADFactory
    if not store then
        o:Line("This frame has no Aura Designer factory store — nothing to probe.", "WARN")
        return
    end

    local ver = DF.auraLayoutVersion or 0
    local total, refused, slotBacked = 0, 0, 0
    for _, storeKey in ipairs(AD_STORE_KEYS) do
        local t = store[storeKey]
        if t then
            local shown = false
            for entryKey, entry in pairs(t) do
                local h = entry and entry.handle
                local f = (h and h.GetAlphaHost) and h:GetAlphaHost() or nil
                if f then
                    if not shown then o:Section(storeKey); shown = true end
                    total = total + 1
                    -- Slot-backed hosts sit UNDER a Blizzard aura button; standalone ones
                    -- are DF frames of our own. That split is the whole diagnosis, and it
                    -- is read off our handle, never off the host.
                    local kind = h.button and "slot-backed (child of an aura button)"
                                           or "standalone (DF-created)"
                    if h.button then slotBacked = slotBacked + 1 end
                    local okW = pcall(f.SetAlpha, f, h._dfADBaseAlpha or 1.0)
                    if not okW then refused = refused + 1 end
                    local okR = pcall(f.GetDebugName, f)
                    local latched = (h._dfAlphaHostDeniedVer == ver) and " LATCHED-DENIED" or ""
                    o:Line(string.format("%s: %s | write %s, name %s | isHandleFrame=%s%s",
                        tostring(entryKey), kind,
                        okW and "OK" or "REFUSED", okR and "OK" or "refused",
                        tostring(rawequal(f, h.frame)), latched),
                        okW and nil or "BAD")
                end
            end
        end
    end

    o:Section("Verdict")
    o:Line(string.format("%d host%s probed, %d slot-backed, %d refused",
        total, total == 1 and "" or "s", slotBacked, refused))
    if refused == 0 then
        o:Line("Every host accepts a plain write — the restriction is NOT descending right "
            .. "now. A fade stuck on screen is then a TRIGGER problem, not a writability "
            .. "one: check the range edge, not this.", "GOOD")
    elseif slotBacked > 0 and refused >= slotBacked then
        o:Line("Slot-backed hosts are refusing while DF-owned frames above them accept. "
            .. "That is the access restriction DESCENDING TO CHILDREN — the case the walk's "
            .. "header warns about, and the fade has to move to the DF-owned ancestor.", "BAD")
    else
        o:Line("Mixed result: some hosts refuse and the split does not follow slot-backing. "
            .. "Capture this alongside combat state — the restriction is aura-secrecy "
            .. "scoped, so in and out of combat can differ.", "WARN")
    end
    o:Line("⚠ Run this BOTH in and out of combat on the same unit: the restriction is tied "
        .. "to aura secrecy, so an out-of-combat run alone can read clean while the fade is "
        .. "broken in a fight.", "NEUTRAL")
end

-- ============================================================
-- RESTRICTION-LIFT RETRY
-- Combat end is a writability edge for slot-backed alpha hosts
-- ============================================================

-- ★ THE OTHER EDGE THE LATCH NEEDS. The range-edge retry in
-- UpdateAuraDesignerAppearance fires when the VALUE we want changes; this fires when
-- the HOST becomes writable again. A denied host queued itself in _adDeniedHostFrames
-- (see the walk's failure handler); combat dropping is when the secret-aura
-- restriction lifts, so retry exactly those frames' walks then. Entries are cleared
-- BEFORE the retry — a still-refused host re-queues itself from the failure handler,
-- so a persistent restriction keeps costing one failed call per combat, not per tick.
-- ⚠ A frame in test mode skips its retry (UpdateAuraDesignerAppearance's own guard);
-- leaving test mode drives a full refresh anyway, so nothing is lost.
--
-- ★ EVERY LIFT EDGE, NOT JUST COMBAT END — and only when the restriction has actually
-- lifted. Aura secrecy is instance-gated: it can hold through a regen inside an
-- encounter and drop on ENCOUNTER_END or a zone change instead, so a queue drained
-- on PLAYER_REGEN_ENABLED alone could retry while still restricted, fail, re-queue,
-- and then wait for a combat that never comes (the unit is already in range, so no
-- range edge arrives either). EllesmereUI's AuraKit converged on the same watcher
-- shape from the same bug: regen + PEW + zone + encounter end, gated on
-- C_Secrets.ShouldAurasBeSecret(). If the probe says still secret, keep the queue
-- and wait for the next edge -- a retry now would only re-fail.
local function AurasStillSecret()
    return C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() or false
end

local adRegenFrame = CreateFrame("Frame")
adRegenFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
adRegenFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
adRegenFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
adRegenFrame:RegisterEvent("ENCOUNTER_END")
adRegenFrame:SetScript("OnEvent", function()
    local queued = DF._adDeniedHostFrames
    if not queued or not next(queued) then return end
    if AurasStillSecret() then return end
    DF._adDeniedHostFrames = nil
    for frame in pairs(queued) do
        if frame.dfIsDandersFrame then
            DF:UpdateAuraDesignerAppearance(frame, true)
        end
    end
end)

-- ============================================================
-- FRAME-LEVEL APPEARANCE (for non-oorEnabled mode)
-- ============================================================

function DF:UpdateFrameAppearance(frame)
    if not IsDandersFrame(frame) then return end
    
    local db = GetDB(frame)
    if not db then return end
    
    -- ★ Test frames pass through. The curve-driven colour below takes the stamped
    -- health fraction instead of UnitHealthPercent -- a DATA fork; the rendering,
    -- the colour stops and the mode branching are all shared.
    if (DF.testMode or DF.raidTestMode) and not frame.dfIsTestFrame then return end
    
    -- The frame's base opacity (Frame Fade). Multiplied into every branch below;
    -- the health-fade curve reads it itself (HealthFade.lua).
    local base = DF:GetFrameBaseAlpha(db, frame)
    if db.oorEnabled then
        -- Element mode pins the frame so per-element fades own the look; the pin IS
        -- the base now, not a hardcoded 1.0.
        ApplyOORAlpha(frame, true, base, base)
    else
        local inRange = GetInRange(frame)
        -- Frame-level: health fade via curve (re-evaluate for range changes)
        if IsHealthFadeEnabled(db) and frame.dfHealthFadeActive and DF.ApplyHealthFadeAlpha and DF:ApplyHealthFadeAlpha(frame) then
            -- Curve applied alpha directly, includes OOR state and the base
        else
            local outOfRangeAlpha = db.rangeFadeAlpha or 0.4
            ApplyOORAlpha(frame, inRange, base, outOfRangeAlpha * base)
        end
    end
end

-- ★ COMBAT EDGE SWEEP for the Frame Fade split. Range.lua flushes its cache on both
-- REGEN events, so most frames re-apply on the next 0.5s tick anyway -- but the
-- player's own frame never re-runs from the range path (always in range) and the
-- pets only re-run when their cached range answer moves, and "the frames snap back
-- when the pull starts" wants to be instant, not eventually. Every unit frame goes
-- through UpdateFrameAppearance here; pets follow on the next range tick (their fade
-- and health-fade writers both read the base). Skipped entirely unless a mode has
-- the split on, so a stock profile pays one boolean per combat edge.
local frameFadeCombatFrame = CreateFrame("Frame")
frameFadeCombatFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
frameFadeCombatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
-- Instance edges for "Use In-Combat Fade In Instances" -- entering or leaving the
-- dungeon changes the resolver's answer without any combat event.
frameFadeCombatFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
frameFadeCombatFrame:SetScript("OnEvent", function()
    local partyDB = DF.GetDB and DF:GetDB()
    local raidDB = DF.GetRaidDB and DF:GetRaidDB()
    if not ((partyDB and partyDB.frameFadeSplitCombat) or (raidDB and raidDB.frameFadeSplitCombat)) then
        return
    end
    SweepFrameFade()
end)

-- ============================================================
-- RANGE-ONLY APPEARANCE UPDATE (Performance optimization)
-- Called by Range.lua instead of UpdateAllElementAppearances.
-- In standard OOR mode (oorEnabled=false), only the parent frame's
-- alpha needs updating — WoW's frame hierarchy cascades it to all
-- children automatically. This reduces 18 function calls to 1.
-- In element-specific OOR mode (oorEnabled=true), each element has
-- its own alpha, so we fall through to the full update path.
-- ============================================================

function DF:UpdateRangeAppearance(frame)
    if not IsDandersFrame(frame) then return end
    
    local db = GetDB(frame)
    if not db then return end
    
    if db.oorEnabled then
        -- Element-specific OOR mode: each element has its own alpha
        -- Must update all elements individually
        DF:UpdateAllElementAppearances(frame)
    else
        -- Standard mode: single SetAlpha on the parent frame cascades to all children.
        -- Element alphas (dead state, base alpha, etc.) are already set by other
        -- update paths (death events, settings changes, full refreshes).
        -- We only need to update the frame-level OOR alpha here.
        DF:UpdateFrameAppearance(frame)
    end

    -- TD live rendering: range_text refresh. This is the single choke point
    -- every UpdateRange path (and the range ticker) funnels through, so it
    -- catches the fast-path cache-hit cases a hook on UpdateRange's tail would
    -- miss. Hint-filtered, so it's a no-op unless a range_text element exists.
    if DF.UpdateTextDesigner then DF:UpdateTextDesigner(frame, "range") end

    -- ☠ THE MISSING-BUFF GATE READS dfInRange, SO IT NEEDS THE SAME CHOKE POINT.
    -- RefreshMissingBuffVisibility hides the strip when frame.dfInRange is false and
    -- latches the result in frame.dfMissingStripShown. Its callers were the dead and
    -- offline edges in Update.lua plus the alive path in UpdateUnitFrame -- none of
    -- which a RANGE transition produces. So the hide landed (any full update while the
    -- unit was away) and the re-show had no trigger at all: walking back into range
    -- wrote dfInRange = true, drove the appearance, and left the strip hidden until a
    -- roster event, a combat transition or an aura change re-entered the drive. Field
    -- report: "it never comes back unless you buff + they remove or reload."
    --
    -- Same reasoning as the TD call above, and the same reason it belongs HERE rather
    -- than on UpdateRange's tail: this is the one function every range path funnels
    -- through, including the cache-HIT branch that only touches this frame.
    -- Combat-safe by construction -- non-secret reads plus one SetShown on a DF-owned
    -- strip -- and a no-op both when the state is unchanged and when the frame never
    -- built the feature (it returns on a nil missingBuffStrip).
    if DF.RefreshMissingBuffVisibility then DF:RefreshMissingBuffVisibility(frame) end
end

-- ============================================================
-- UPDATE ALL ELEMENT APPEARANCES
-- Master function to update all elements at once
-- ============================================================

-- ☠ EVERY STEP IS PROTECTED, AND A FAILED PASS RE-ARMS THE RANGE TICK.
-- Range applies appearance ONCE PER TRANSITION (Range.lua's cache only re-drives this
-- when dfInRange changes), so the chain below is the one shot each element gets. It
-- ran unprotected in a fixed order, AD first and the buff/debuff rows near the end: a
-- single throw anywhere ahead of a step (a secret comparison, a forbidden object, a
-- nil during a rebuild) left every later element at its PRE-transition alpha until
-- the next transition -- which for a unit that walked in and stayed is never. That is
-- "auras faded on a member standing next to me, and touching any setting clears it",
-- and it is invisible unless the user has Lua errors on.
-- So: each step under pcall, the first failure per session named on the RANGE debug
-- channel, and dfInRange cleared so the next range tick sees a change and re-drives
-- the whole chain rather than treating the broken pass as applied.
-- Method names, not closures: no allocation on a path that can run per tick while a
-- range answer is secret.
local ELEMENT_APPEARANCE_STEPS = {
    -- Frame-level first, then AD: it writes healthbarEffectiveBlend (the OOR-aware bar
    -- alpha) that UpdateHealthBarAppearance reads next. Running it later left a
    -- one-tick lag where, on first going out of range, the underlying replace-mode
    -- bar texture kept its in-range (full) alpha for a frame while the border had
    -- already faded — so the AD colour briefly bled through the border.
    "UpdateFrameAppearance",
    "UpdateAuraDesignerAppearance",
    "UpdateHealthBarAppearance",
    "UpdateMissingHealthBarAppearance",
    "UpdateBackgroundAppearance",
    "UpdateBorderAppearance",
    "UpdateNameTextAppearance",
    "UpdateHealthTextAppearance",
    "UpdateStatusTextAppearance",
    "UpdatePowerBarAppearance",
    "UpdateBuffIconsAppearance",
    "UpdateDebuffIconsAppearance",
    "UpdateRoleIconAppearance",
    "UpdateLeaderIconAppearance",
    "UpdateRaidTargetIconAppearance",
    "UpdateReadyCheckIconAppearance",
    "UpdateDispelOverlayAppearance",
    "UpdateMissingBuffAppearance",
    "UpdateAbsorbBarAppearance",
    "UpdateHealAbsorbBarAppearance",
    "UpdateHealPredictionBarAppearance",
    "UpdateDefensiveIconAppearance",
    -- The eight status icons. They were absent from this list entirely, which is why
    -- their range/dead fade never fired on a range change -- see
    -- DF:UpdateStatusIconsAppearance for the full reasoning.
    "UpdateStatusIconsAppearance",
}

function DF:UpdateAllElementAppearances(frame)
    if not IsDandersFrame(frame) then return end

    local failed = false
    for i = 1, #ELEMENT_APPEARANCE_STEPS do
        local name = ELEMENT_APPEARANCE_STEPS[i]
        local fn = DF[name]
        if fn then
            local ok, err = pcall(fn, DF, frame)
            if not ok then
                failed = true
                if not DF._warnedElementAppearance then
                    DF._warnedElementAppearance = true
                    if DF.DebugWarn then
                        DF:DebugWarn("RANGE", "%s threw during the appearance pass on %s: %s",
                            name, tostring(frame.unit), tostring(err))
                    end
                end
            end
        end
    end
    -- A broken pass must not be remembered as applied. Clearing the range stamp makes
    -- the next UpdateRange see a change and re-run everything; until then GetInRange
    -- reads "in range", which only matters to a pass that isn't going to run.
    if failed then frame.dfInRange = nil end
end

-- ============================================================
-- HELPER: Update all DandersFrames frames
-- ============================================================

function DF:UpdateAllFrameAppearances()
    local function updateFrame(frame)
        if frame and frame.dfIsDandersFrame then
            DF:UpdateAllElementAppearances(frame)
        end
    end
    
    -- All frames (party/raid/arena) via iterator
    if DF.IterateAllFrames then
        DF:IterateAllFrames(updateFrame)
    end
    
    -- Pinned frames.
    -- ☠ THROUGH THE SHARED WALKER, NOT A HAND-ROLLED HEADER LOOP — this one walked
    -- PinnedFrames.headers only, so pinned BOSS frames got no colour or alpha refresh at
    -- all, including from FullProfileRefresh on a profile switch. (Audit 2026-08-17.)
    if DF.IteratePinnedFrames then
        DF.IteratePinnedFrames(updateFrame)
    end
end

-- (Removed) the 18-name DF.Update*Alpha back-compat alias block. It dated from the
-- alpha-only -> full-appearance rename and redirected every old name at the new function
-- "in case any code calls these directly". Nothing did: all 18, plus UpdateAllElementAlphas
-- and UpdateAllSecureFrameAlphas, had exactly one hit each across BOTH addons — their own
-- definition. They were never part of the published DandersFrames_* API surface either.
