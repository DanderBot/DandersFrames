local addonName, UF = ...

-- ============================================================
-- CAST BAR (spec §3.4, §5)
-- One cast bar per unit frame that has one (player, target, focus, pet; boss
-- uses the same code when the boss frames arrive). A plain frame, never secure:
-- attached it hangs under / over the unit button, detached it lives in the
-- unit's holder at its own position record and is a DandersMover element of
-- its own (`<unit>.castbar`, Mover.lua) only while detached.
--
-- ☠ SECRET VALUES (12.x). For anyone but the player, the cast's start / end
-- times, its spell ID, its icon, its name and its not-interruptible flag can be
-- SECRET in combat. Nothing here compares them, does arithmetic on them, or
-- formats them in Lua:
--   * the FILL is the client's: StatusBar:SetTimerDuration(duration object from
--     UnitCastingDuration / UnitChannelDuration / UnitEmpoweredChannelDuration),
--     channels draining (RemainingTime). DandersUF froze at 50% because it did
--     maths on secret times; there is no maths here to freeze.
--   * the TIMER TEXT is the client's too: a DurationTextBinding with a numeric
--     rule formatter (C-side formatting of the duration's own values). Without
--     that API it falls back to Lua formatting ONLY when the value is not secret,
--     and shows nothing otherwise.
--   * NOT INTERRUPTIBLE: the shield is a FRAME alpha'd by SetAlphaFromBoolean
--     (texture-level alpha from a secret renders 0 on Midnight, per research), and
--     the bar colour is picked per channel by C_CurveUtil.EvaluateColorValueFromBoolean
--     and handed to SetStatusBarColor (which takes secret colour values).
--   * the spell name goes through SetFormattedText("%s", ...) only.
--   * KICK TICK: two invisible bars. The positioner mirrors the cast (min/max
--     0..total, value = elapsed -- both secret, both legal sinks); the kick bar is
--     anchored to the positioner's leading edge, min/max 0..total, value = the
--     interrupt's remaining cooldown. Its leading edge is where in the cast the
--     interrupt comes off cooldown, and the tick sits there. Its alpha comes from
--     the cooldown's IsZero() (a boolean the client evaluates). No Lua maths.
--
-- ★ PLAYER-ONLY MATHS live in ONE section below (PLAYER ONLY): latency, empower
-- stage marks and the no-timer-API fallback fill. The player's own cast times are
-- not secret, and every one of those functions also checks issecretvalue before
-- touching a number. tests/test_uf_castbar.lua checks the rest of this file for
-- arithmetic on cast times and for decimal format strings.
--
-- ⚠ UNVERIFIED IN GAME (12.x API names this file assumes): StatusBar:SetTimerDuration,
-- UnitCastingDuration, UnitChannelDuration, UnitEmpoweredChannelDuration,
-- UnitEmpoweredStagePercentages, C_DurationUtil.CreateDuration / CreateDurationTextBinding,
-- C_StringUtil.CreateNumericRuleFormatter, C_CurveUtil.EvaluateColorValueFromBoolean,
-- Frame:SetAlphaFromBoolean, C_Spell.GetSpellCooldownDuration, C_Spell.IsSpellImportant,
-- UnitSpellTargetName, Enum.StatusBarTimerDirection, Enum.DurationTextBindingProperty.
-- Every one is looked up at call time and a missing one degrades, never errors.
-- ============================================================

local DF = DandersFrames
if not DF then return end

local ipairs, pairs, type, pcall, select = ipairs, pairs, type, pcall, select
local tonumber, tostring = tonumber, tostring
local format = string.format

local CB = { NAME = "CastBar" }
-- Frame level over its unit frame: above the classification dragon (+16) and
-- border (+15), under the power bar (+20) and the text overlay (+25). Its own
-- shield and text sit +5 / +6 above this, still under the overlay.
CB.LEVEL = 18
UF.CastBar = CB

local E = UF.Elements
local K = E and E.Kit
if not (E and K) then return end
local IsSecret = K.IsSecret

-- Units whose frames get a cast bar (target of target never does).
CB.UNITS = { player = true, target = true, focus = true, pet = true, boss = true }
-- Units whose cast bar may show the kick-ready tick (enemy frames).
CB.KICK_UNITS = { target = true, focus = true, boss = true }

CB.EVENTS = {
    "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_DELAYED",
    "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_UPDATE", "UNIT_SPELLCAST_CHANNEL_STOP",
    "UNIT_SPELLCAST_EMPOWER_START", "UNIT_SPELLCAST_EMPOWER_UPDATE", "UNIT_SPELLCAST_EMPOWER_STOP",
    "UNIT_SPELLCAST_INTERRUPTIBLE", "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
}

-- How long an interrupted / failed cast stays on screen, in seconds.
CB.HOLD = 0.6
-- Cast data can lag the START event by a frame or two (DandersFrames' targeted
-- spells hit this too): retry the read this many times, this far apart.
CB.RETRIES, CB.RETRY_DELAY = 4, 0.05
-- Kick cooldown re-read cadence while a cast is up (the tick itself moves every frame).
CB.KICK_INTERVAL = 0.1
-- Fallback timer text cadence (only used without a DurationTextBinding).
CB.TEXT_INTERVAL = 0.1

-- ============================================================
-- INTERRUPTS: the player's own, per class (first one known wins; unknown -> no tick)
-- Re-picked after a spec or spellbook change.
-- ============================================================
CB.INTERRUPTS = {
    WARRIOR     = { 6552 },             -- Pummel
    PALADIN     = { 96231 },            -- Rebuke
    HUNTER      = { 147362, 187707 },   -- Counter Shot, Muzzle
    ROGUE       = { 1766 },             -- Kick
    PRIEST      = { 15487 },            -- Silence
    DEATHKNIGHT = { 47528 },            -- Mind Freeze
    SHAMAN      = { 57994 },            -- Wind Shear
    MAGE        = { 2139 },             -- Counterspell
    WARLOCK     = { 19647, 119910, 132409 }, -- Spell Lock (pet / command / sacrifice)
    MONK        = { 116705 },           -- Spear Hand Strike
    DRUID       = { 106839, 78675 },    -- Skull Bash, Solar Beam
    DEMONHUNTER = { 183752 },           -- Disrupt
    EVOKER      = { 351338 },           -- Quell
}

local function Known(id)
    local SB = C_SpellBook
    if SB and SB.IsSpellKnownOrInSpellBook then
        local ok, known = pcall(SB.IsSpellKnownOrInSpellBook, id)
        if ok and known then return true end
        if Enum and Enum.SpellBookSpellBank then
            ok, known = pcall(SB.IsSpellKnownOrInSpellBook, id, Enum.SpellBookSpellBank.Pet)
            if ok and known then return true end
        end
        return false
    end
    if IsPlayerSpell then
        local ok, known = pcall(IsPlayerSpell, id)
        return ok and known and true or false
    end
    return false
end

function CB:PickInterrupt()
    if CB.interruptPicked then return CB.interruptID end
    CB.interruptPicked = true
    CB.interruptID = nil
    local class = UnitClass and select(2, UnitClass("player"))
    if type(class) ~= "string" or IsSecret(class) then return nil end
    for _, id in ipairs(CB.INTERRUPTS[class] or {}) do
        if Known(id) then
            CB.interruptID = id
            break
        end
    end
    return CB.interruptID
end

function CB:ForgetInterrupt()
    CB.interruptPicked, CB.interruptID = nil, nil
end

-- ============================================================
-- SMALL HELPERS
-- ============================================================
local function Enabled(db) return db and db.castbarEnabled and true or false end

local function Dir(channel)
    local D = Enum and Enum.StatusBarTimerDirection
    if not D then return nil end
    return channel and D.RemainingTime or D.ElapsedTime
end

local function Interp()
    local I = Enum and Enum.StatusBarInterpolation
    return I and I.Immediate or nil
end

-- A finished duration: SetTimerDuration on it leaves the bar full (the flash).
local function FullDuration()
    local DU = C_DurationUtil
    if not (DU and DU.CreateDuration) then return nil end
    local ok, d = pcall(function()
        local x = DU.CreateDuration()
        x:SetTimeFromStart(GetTime() - 1, 1)
        return x
    end)
    return ok and d or nil
end

-- A non-secret sample duration starting `elapsed` seconds ago (previews).
local function SampleDuration(total, elapsed)
    local DU = C_DurationUtil
    if not (DU and DU.CreateDuration) then return nil end
    local ok, d = pcall(function()
        local x = DU.CreateDuration()
        x:SetTimeFromStart(GetTime() - elapsed, total)
        return x
    end)
    return ok and d or nil
end

-- Run the bar off a duration object. Returns true when the client owns the fill.
function CB.ApplyTimer(bar, dur, channel)
    if not (bar and dur and bar.SetTimerDuration) then return false end
    local ok = pcall(bar.SetTimerDuration, bar, dur, Interp(), Dir(channel))
    return ok and true or false
end

-- Secret-safe pickers: the shared kit's (Elements.lua).
local Pick, AlphaFrom, IsNil = K.Pick, K.AlphaFrom, K.IsNil
CB.Pick, CB.AlphaFrom, CB.IsNil = Pick, AlphaFrom, IsNil

-- ============================================================
-- BUILD (once per unit frame, live or preview)
-- ============================================================
function CB:Attach(f)
    if not f or f.dfUFCastBar or not CB.UNITS[f.dfUFUnit] then return end
    local cb = CreateFrame("Frame", nil, f)
    cb:Hide()
    cb.owner = f
    cb.unit = f.dfUFUnit
    f.dfUFCastBar = cb

    cb.bg = cb:CreateTexture(nil, "BACKGROUND")

    -- The fill. Its own frame so the bar area can be laid out beside the icon.
    local bar = CreateFrame("StatusBar", nil, cb)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    cb.bar = bar
    cb.bg:SetAllPoints(bar)

    cb.spark = bar:CreateTexture(nil, "OVERLAY")
    cb.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    cb.spark:SetBlendMode("ADD")
    cb.spark:SetWidth(10)

    -- Player only: latency at the end of the bar, empower stage marks.
    cb.latency = bar:CreateTexture(nil, "ARTWORK", nil, 2)
    cb.latency:SetTexture(K.WHITE)
    cb.latency:SetVertexColor(1, 0, 0, 0.45)
    cb.latency:Hide()
    cb.stages = {}

    -- Kick tick: a clip frame over the bar holds the two invisible bars, so a
    -- kick-ready point past the end of the cast is cut off rather than drawn
    -- outside the bar.
    local clip = CreateFrame("Frame", nil, bar)
    clip:SetAllPoints(bar)
    if clip.SetClipsChildren then clip:SetClipsChildren(true) end
    cb.clip = clip
    local pos = CreateFrame("StatusBar", nil, clip)
    pos:SetStatusBarTexture(K.WHITE)
    pos:SetStatusBarColor(0, 0, 0, 0)
    pos:SetMinMaxValues(0, 1)
    pos:SetValue(0)
    pos:SetAllPoints(bar)
    cb.positioner = pos
    local kick = CreateFrame("StatusBar", nil, clip)
    kick:SetStatusBarTexture(K.WHITE)
    kick:SetStatusBarColor(0, 0, 0, 0)
    kick:SetMinMaxValues(0, 1)
    kick:SetValue(0)
    cb.kickBar = kick
    cb.kickTick = kick:CreateTexture(nil, "OVERLAY", nil, 7)
    cb.kickTick:SetTexture(K.WHITE)
    cb.kickTick:SetVertexColor(1, 1, 1, 1)
    cb.kickTick:SetWidth(2)
    -- The tick's own frame carries its alpha (frame-level SetAlphaFromBoolean).
    cb.kickHost = kick
    kick:SetAlpha(0)

    -- Icon (with the not-interruptible shield over it).
    local iconFrame = CreateFrame("Frame", nil, cb)
    cb.iconFrame = iconFrame
    cb.icon = iconFrame:CreateTexture(nil, "ARTWORK")
    cb.icon:SetAllPoints(iconFrame)
    cb.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- ★ A FRAME, alpha'd from the (possibly secret) not-interruptible flag.
    local shield = CreateFrame("Frame", nil, cb)
    shield:SetFrameLevel(bar:GetFrameLevel() + 5)
    cb.shield = shield
    cb.shieldTex = shield:CreateTexture(nil, "OVERLAY")
    cb.shieldTex:SetTexture("Interface\\CastingBar\\UI-CastingBar-Small-Shield")
    cb.shieldTex:SetAllPoints(shield)
    shield:SetAlpha(0)

    -- Important-spell glow: an outline frame, alpha'd from IsSpellImportant.
    local glow = CreateFrame("Frame", nil, cb)
    glow:SetPoint("TOPLEFT", cb, "TOPLEFT", -2, 2)
    glow:SetPoint("BOTTOMRIGHT", cb, "BOTTOMRIGHT", 2, -2)
    glow:SetAlpha(0)
    cb.glow = glow

    -- Text sits above the fill and the tick.
    local textHost = CreateFrame("Frame", nil, cb)
    textHost:SetAllPoints(bar)
    textHost:SetFrameLevel(bar:GetFrameLevel() + 6)
    cb.textHost = textHost
    cb.text = textHost:CreateFontString(nil, "OVERLAY")
    cb.timer = textHost:CreateFontString(nil, "OVERLAY")

    if not f.dfUFPreview then
        local listener = CreateFrame("Frame")
        listener:SetScript("OnEvent", function(_, event, unit, ...) CB:OnEvent(cb, event, unit, ...) end)
        cb.listener = listener
    end
    cb:SetScript("OnUpdate", function(self, elapsed) CB:OnUpdate(self, elapsed) end)
    return cb
end

-- ============================================================
-- LAYOUT (settings -> look and position; legal in combat)
-- ============================================================
local function PlaceText(fs, cb, anchor, x, y)
    fs:ClearAllPoints()
    local p = K.Point(anchor, "LEFT")
    fs:SetPoint(p, cb.bar, p, x or 0, y or 0)
    if p:find("LEFT") then fs:SetJustifyH("LEFT")
    elseif p:find("RIGHT") then fs:SetJustifyH("RIGHT")
    else fs:SetJustifyH("CENTER") end
end

-- ⚠ A boss slot's cast bar never detaches: five bars and one shared record would
-- stack on one spot. Its Detach control is hidden on the Boss page.
function CB:IsDetached(f, db)
    if f and f.dfUFSlot then return false end
    db = db or K.DB(f)
    return db and db.castbarDetached and true or false
end

-- ============================================================
-- AURA ROW RESERVE
-- A cast bar attached UNDER the frame owns the band below it, so an aura row
-- anchored to the frame's bottom edge (BOTTOMLEFT / BOTTOM / BOTTOMRIGHT) is pushed
-- down past that band: the cast bar's gap, height and border, less any lift of its
-- own Y. Worked out from the SETTINGS, never the bar's shown state, so it is a
-- standing reserve that does not jump when a cast starts or stops, and a change of
-- height, gap, border, enable or attach moves the rows at their next drive.
-- Rows anchored to the top or a side are never pushed; nor is anything on a frame
-- whose cast bar is off, detached (Player's default) or attached on top.
-- A detached resource bar hung from the frame's bottom (K.PowerBarBelow) comes
-- first: the attached cast bar goes under it, and its band counts here too.
-- Reaches the rows through DandersFrames' per-frame row placement
-- (frame.dfAuraRowPlacement, Features/Auras.lua; UF.AuraRowPlacement, Elements.lua).
-- ============================================================
function CB.BottomReserve(f, db)
    db = db or K.DB(f)
    if not db or not Enabled(db) or CB:IsDetached(f, db) or db.castbarSide == "TOP" then return 0 end
    local h = tonumber(db.castbarHeight) or 18
    local gap = tonumber(db.castbarGap) or 2
    local y = tonumber(db.castbarY) or 0
    -- K.Border draws OUTSIDE the bar, at least 1px, on every side.
    local border = 0
    if db.castbarBorderEnabled ~= false then
        border = tonumber(db.castbarBorderSize) or 1
        if border < 1 then border = 1 end
    end
    local r = K.PowerBarBelow(f, db) + gap - y + h + border
    if r < 0 then r = 0 end
    return r
end

function CB:Layout(f)
    local cb = f and f.dfUFCastBar
    if not cb then return end
    local db = K.DB(f)
    if not db then return end
    if not Enabled(db) then
        CB:Halt(cb)
        cb:Hide()
        if UF.Mover and UF.Mover.SyncChild then UF.Mover:SyncChild(f.dfUFUnit, "castbar") end
        return
    end

    local w = db.castbarMatchWidth ~= false and K.FrameWidth(f, db) or (tonumber(db.castbarWidth) or 220)
    local h = tonumber(db.castbarHeight) or 18
    cb:SetSize(w, h)
    cb:SetScale(1)

    -- Icon: a square at one end, inside the bar's width.
    local showIcon = db.castbarShowIcon ~= false
    local iconSize = tonumber(db.castbarIconSize) or 0
    if iconSize <= 0 then iconSize = h end
    cb.iconFrame:ClearAllPoints()
    cb.bar:ClearAllPoints()
    local iconRight = db.castbarIconSide == "RIGHT"
    if showIcon then
        cb.iconFrame:SetSize(iconSize, iconSize)
        if iconRight then
            cb.iconFrame:SetPoint("RIGHT", cb, "RIGHT", 0, 0)
            cb.bar:SetPoint("TOPLEFT", cb, "TOPLEFT", 0, 0)
            cb.bar:SetPoint("BOTTOMRIGHT", cb, "BOTTOMRIGHT", -iconSize, 0)
        else
            cb.iconFrame:SetPoint("LEFT", cb, "LEFT", 0, 0)
            cb.bar:SetPoint("TOPLEFT", cb, "TOPLEFT", iconSize, 0)
            cb.bar:SetPoint("BOTTOMRIGHT", cb, "BOTTOMRIGHT", 0, 0)
        end
        cb.iconFrame:Show()
    else
        cb.iconFrame:Hide()
        cb.bar:SetAllPoints(cb)
    end
    cb.barWidth = showIcon and (w - iconSize) or w
    cb.shield:ClearAllPoints()
    if showIcon then
        cb.shield:SetAllPoints(cb.iconFrame)
    else
        cb.shield:SetSize(h, h)
        cb.shield:SetPoint("CENTER", cb.bar, iconRight and "RIGHT" or "LEFT", 0, 0)
    end

    -- Look.
    cb.bar:SetStatusBarTexture(db.castbarTexture or K.BAR)
    cb.bar:SetReverseFill(db.castbarReverse and true or false)
    cb.bg:SetTexture(db.castbarBgTexture or K.BAR)
    cb.bg:SetVertexColor(K.RGBA(db.castbarBgColor, 0, 0, 0, 0.6))
    local tex = cb.bar:GetStatusBarTexture()
    cb.spark:ClearAllPoints()
    if tex then
        local edge = db.castbarReverse and "LEFT" or "RIGHT"
        cb.spark:SetPoint("CENTER", tex, edge, 0, 0)
    end
    cb.spark:SetHeight(h * 2)
    cb.showSpark = db.castbarSpark ~= false
    K.Border(cb, db.castbarBorderEnabled ~= false, db.castbarBorderSize, db.castbarBorderColor)
    K.Border(cb.glow, true, 2, db.castbarPriorityHighlightColor)
    cb.kickTick:SetHeight(h)

    -- Text.
    K.Font(cb.text, db.castbarSpellFont, db.castbarSpellFontSize, db.castbarSpellOutline, db.castbarSpellColor)
    PlaceText(cb.text, cb, db.castbarSpellAnchor or "LEFT", db.castbarSpellX, db.castbarSpellY)
    cb.text:SetShown(db.castbarShowSpell ~= false)
    K.Font(cb.timer, db.castbarTimerFont, db.castbarTimerFontSize, db.castbarTimerOutline, db.castbarTimerColor)
    PlaceText(cb.timer, cb, db.castbarTimerAnchor or "RIGHT", db.castbarTimerX, db.castbarTimerY)
    cb.timer:SetShown(db.castbarShowTimer ~= false)
    -- The timer format may have changed: the SAME binding is re-configured on the
    -- next cast. (Dropping it would leave the old one enabled on this fontstring,
    -- and two bindings would fight over one text.)
    cb.bindingKey = nil

    -- Position.
    cb:ClearAllPoints()
    if CB:IsDetached(f, db) then
        cb:SetParent(K.DetachedParent(f))
        cb:SetScale(tonumber(db.frameScale) or 1)
        K.PlaceDetached(cb, f, db.castbarPosition)
    else
        cb:SetParent(f)
        local gap = tonumber(db.castbarGap) or 2
        local x, y = tonumber(db.castbarX) or 0, tonumber(db.castbarY) or 0
        if db.castbarSide == "TOP" then
            cb:SetPoint("BOTTOM", f, "TOP", x, gap + y)
        else
            -- Under a detached resource bar hung from the frame's bottom (K.PowerBarBelow).
            cb:SetPoint("TOP", f, "BOTTOM", x, -(K.PowerBarBelow(f, db) + gap) + y)
        end
    end
    -- Above the classification dragon (Indicators.lua IN.DRAGON_LEVEL), so a
    -- cast bar is never hidden by a dragon perched on this or a neighbouring
    -- frame (unit frames share one base level).
    cb:SetFrameLevel(f:GetFrameLevel() + CB.LEVEL)
    if UF.Mover and UF.Mover.SyncChild then UF.Mover:SyncChild(f.dfUFUnit, "castbar") end

    -- Idle: shown empty, or hidden.
    if not cb.active and not cb.holding then CB:ShowIdle(cb) end
end

-- ============================================================
-- EVENTS (only while the frame is shown and its cast bar is on)
-- ============================================================
local VEHICLE_PAIR = { player = { "player", "vehicle" }, pet = { "pet", "player" } }

function CB:SetActive(f, on)
    local cb = f and f.dfUFCastBar
    if not cb or not cb.listener then return end
    local db = K.DB(f)
    on = on and Enabled(db) or false
    if cb.eventsOn == on then
        if not on then CB:Halt(cb); cb:Hide() end
        return
    end
    cb.eventsOn = on
    local unit = f.dfUFUnit
    for _, ev in ipairs(CB.EVENTS) do
        if on then
            local pair = VEHICLE_PAIR[unit]
            if pair then
                pcall(cb.listener.RegisterUnitEvent, cb.listener, ev, pair[1], pair[2])
            else
                -- The frame's own token (boss3), not the settings unit (boss).
                pcall(cb.listener.RegisterUnitEvent, cb.listener, ev, f.unit or unit)
            end
        else
            pcall(cb.listener.UnregisterEvent, cb.listener, ev)
        end
    end
    if not on then
        CB:Halt(cb)
        cb:Hide()
    end
end

-- The settings changed (cast bar switched on or off): events follow.
function CB:Resync(f)
    local cb = f and f.dfUFCastBar
    if not cb or not cb.listener then return end
    local want = Enabled(K.DB(f)) and f:IsVisible() or false
    if (cb.eventsOn or false) ~= want then CB:SetActive(f, want) end
end

function CB:OnEvent(cb, event, unit, ...)
    local f = cb.owner
    if not f or not f:IsVisible() then return end
    if unit and unit ~= f.unit then return end
    if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START"
        or event == "UNIT_SPELLCAST_EMPOWER_START" then
        CB:Start(cb)
    elseif event == "UNIT_SPELLCAST_DELAYED" or event == "UNIT_SPELLCAST_CHANNEL_UPDATE"
        or event == "UNIT_SPELLCAST_EMPOWER_UPDATE" then
        if cb.active then CB:Start(cb, true) end
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        CB:Flash(cb, "interrupted")
    elseif event == "UNIT_SPELLCAST_FAILED" then
        -- A failed cast the unit is no longer showing (a queued spell that never
        -- started) has nothing to flash.
        if cb.active and not cb.channel then CB:Flash(cb, "failed") end
    elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP"
        or event == "UNIT_SPELLCAST_EMPOWER_STOP" then
        if cb.holding then return end
        -- A stop that arrives after the next cast already started must not end it.
        if CB:QueryCast(f.unit) then CB:Start(cb) else CB:Finish(cb) end
    elseif event == "UNIT_SPELLCAST_INTERRUPTIBLE" then
        CB:SetInterruptible(cb, false)
    elseif event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
        CB:SetInterruptible(cb, true)
    end
end

-- Element hooks from Units.lua.
function CB:Refresh(f)
    local cb = f and f.dfUFCastBar
    if not cb or f.dfUFPreview then return end
    CB:Resync(f)
    if not cb.eventsOn then return end
    if CB:QueryCast(f.unit) then CB:Start(cb) else CB:Halt(cb); CB:ShowIdle(cb) end
end

function CB:OnUnitChanged(f) CB:Refresh(f) end

-- ============================================================
-- READING A CAST
-- Returns kind ("cast" / "channel" / "empower"), name, texture, notInterruptible,
-- spellID, duration -- or nil when the unit is not casting. Every value but
-- `kind` may be secret.
-- ============================================================
function CB:QueryCast(unit)
    if not unit then return nil end
    if UnitCastingInfo then
        local name, _, texture, _, _, _, _, ni, spellID = UnitCastingInfo(unit)
        if name then
            local dur = UnitCastingDuration and UnitCastingDuration(unit)
            return "cast", name, texture, ni, spellID, dur
        end
    end
    if UnitChannelInfo then
        local name, _, texture, _, _, _, ni, spellID, isEmpowered = UnitChannelInfo(unit)
        if name then
            -- A secret "is empowered" is read as a plain channel.
            local emp = (not IsSecret(isEmpowered)) and isEmpowered and true or false
            local dur
            if emp and UnitEmpoweredChannelDuration then
                dur = UnitEmpoweredChannelDuration(unit, true)
            elseif UnitChannelDuration then
                dur = UnitChannelDuration(unit)
            end
            return emp and "empower" or "channel", name, texture, ni, spellID, dur
        end
    end
    return nil
end

-- ============================================================
-- START / STOP
-- ============================================================
local function BaseColor(cb, db)
    if cb.channel then return K.RGBA(db.castbarChannelColor, 0.3, 0.7, 1) end
    if db.castbarClassColor and cb.unit == "player" and UnitClass then
        local class = select(2, UnitClass("player"))
        local c = (not IsSecret(class)) and class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
        if c then return c.r, c.g, c.b end
    end
    return K.RGBA(db.castbarColor, 1, 0.7, 0)
end

-- Paint the fill colour: the base colour, swapped for "kick not ready" while the
-- interrupt is on cooldown (a client-evaluated boolean), then for the
-- not-interruptible colour (another). Each channel is picked separately.
function CB:PaintColor(cb, kickReady)
    local db = K.DB(cb.owner)
    if not db then return end
    local r, g, b = BaseColor(cb, db)
    if kickReady ~= nil then
        local kr, kg, kb = K.RGBA(db.castbarKickNotReadyColor, 0.9, 0.4, 0.1)
        r, g, b = Pick(kickReady, r, kr), Pick(kickReady, g, kg), Pick(kickReady, b, kb)
    end
    local nr, ng, nb = K.RGBA(db.castbarNonInterruptibleColor, 0.6, 0.6, 0.6)
    local ni = cb.ni
    cb.bar:SetStatusBarColor(Pick(ni, nr, r), Pick(ni, ng, g), Pick(ni, nb, b))
end

function CB:SetInterruptible(cb, notInterruptible)
    cb.ni = notInterruptible
    AlphaFrom(cb.shield, notInterruptible, 1, 0)
    if cb.kickOn then AlphaFrom(cb.clip, notInterruptible, 0, 1) end
    if cb.active then CB:PaintColor(cb, cb.kickReady) end
end

function CB:Start(cb, isUpdate)
    local f = cb.owner
    local db = K.DB(f)
    if not Enabled(db) then return end
    local kind, name, texture, ni, spellID, dur = CB:QueryCast(f.unit)
    if not kind then CB:Finish(cb); return end
    if IsNil(dur) then
        -- The duration can lag the event: try again shortly.
        cb.retries = (cb.retries or 0) + 1
        if cb.retries <= CB.RETRIES and C_Timer then
            C_Timer.After(CB.RETRY_DELAY, function() if cb.owner:IsVisible() then CB:Start(cb, isUpdate) end end)
        end
        if cb.unit ~= "player" then return end
    end
    cb.retries = 0
    cb.active, cb.holding = true, false
    cb.kind = kind
    cb.channel = (kind == "channel")
    cb.dur = dur
    cb.spellID = spellID
    cb.token = (cb.token or 0) + 1
    if IsNil(ni) then cb.ni = false else cb.ni = ni end

    -- The fill.
    local owned = dur and CB.ApplyTimer(cb.bar, dur, cb.channel)
    cb.fallback = nil
    if not owned then
        -- PLAYER ONLY (the section below): plain times, plain maths.
        if cb.unit == "player" then cb.fallback = CB.PlayerFallbackStart(cb) end
        if not cb.fallback then
            cb.bar:SetMinMaxValues(0, 1)
            cb.bar:SetValue(0)
        end
    end

    -- Icon, name, target.
    if not IsNil(texture) then cb.icon:SetTexture(texture) end
    CB:PaintName(cb, name, db)
    CB:SetInterruptible(cb, cb.ni)
    CB:PaintImportant(cb, db)
    CB:SetupKick(cb, db)
    CB:PaintColor(cb, cb.kickReady)
    CB:StartTimerText(cb, db)

    -- Player only: latency, empower stages.
    if cb.unit == "player" then
        CB.PlayerLatency(cb, db)
        CB.PlayerStages(cb, db)
    else
        cb.latency:Hide()
        CB.HideStages(cb)
    end

    cb.spark:SetShown(cb.showSpark and true or false)
    CB.ShowFill(cb, true)
    CB:ApplyRange(f)
    cb:Show()
end

function CB:ApplyRange(f)
    local db = K.DB(f)
    K.RangeAlpha(f, f and f.dfUFCastBar, 1, tonumber(db and db.oorCastBarAlpha) or 0.5)
end

function CB:PaintName(cb, name, db)
    if db.castbarShowSpell == false then cb.text:SetText(""); return end
    if db.castbarShowTarget and UnitSpellTargetName then
        local ok, target = pcall(UnitSpellTargetName, cb.owner.unit)
        if ok and not IsNil(target) then
            cb.text:SetFormattedText("%s%s%s", name, db.castbarTargetSep or " > ", target)
            return
        end
    end
    cb.text:SetFormattedText("%s", name)
end

function CB:PaintImportant(cb, db)
    if not (db.castbarPriorityHighlight and not IsNil(cb.spellID) and C_Spell and C_Spell.IsSpellImportant) then
        cb.glow:SetAlpha(0)
        return
    end
    local ok, important = pcall(C_Spell.IsSpellImportant, cb.spellID)
    if ok then AlphaFrom(cb.glow, important, 1, 0) else cb.glow:SetAlpha(0) end
end

-- Stop listening to the cast without showing anything (frame hid, unit changed).
function CB:Halt(cb)
    cb.active, cb.holding, cb.dur, cb.fallback = false, false, nil, nil
    cb.kickReady, cb.kickOn = nil, nil
    cb.token = (cb.token or 0) + 1
    if cb.binding then pcall(cb.binding.SetEnabled, cb.binding, false) end
    cb.timer:SetText("")
    cb.kickHost:SetAlpha(0)
    cb.glow:SetAlpha(0)
    cb.shield:SetAlpha(0)
    cb.latency:Hide()
    CB.HideStages(cb)
end

-- The fill texture's own alpha. An idle bar hides its fill rather than writing
-- SetValue(0): a bar last driven by SetTimerDuration (a finished flash) has no
-- "clear the timer" call, and a plain SetValue may not win against it.
function CB.ShowFill(cb, on)
    local tex = cb.bar:GetStatusBarTexture()
    if tex then tex:SetAlpha(on and 1 or 0) end
end

-- Idle look: hidden, or an empty bar when Hide When Not Casting is off.
function CB:ShowIdle(cb)
    local db = K.DB(cb.owner)
    if not Enabled(db) or db.castbarHideIdle ~= false or not cb.owner:IsVisible() then
        cb:Hide()
        return
    end
    CB.ShowFill(cb, false)
    cb.bar:SetMinMaxValues(0, 1)
    cb.bar:SetValue(0)
    cb.text:SetText("")
    cb.timer:SetText("")
    cb.spark:Hide()
    cb:SetAlpha(1)
    cb:Show()
end

-- The cast ended normally.
function CB:Finish(cb)
    CB:Halt(cb)
    CB:ShowIdle(cb)
end

-- Interrupted / failed: a full bar in the failed colour with the word on it,
-- held for a moment.
function CB:Flash(cb, reason)
    local f = cb.owner
    local db = K.DB(f)
    if not Enabled(db) then return end
    CB:Halt(cb)
    cb.holding = true
    local token = cb.token
    local full = FullDuration()
    if not (full and CB.ApplyTimer(cb.bar, full, false)) then
        cb.bar:SetMinMaxValues(0, 1)
        cb.bar:SetValue(1)
    end
    CB.ShowFill(cb, true)
    cb.bar:SetStatusBarColor(K.RGBA(db.castbarFailedColor, 0.9, 0.2, 0.2))
    local L = DF.L or {}
    if db.castbarShowSpell ~= false then
        cb.text:SetText(reason == "interrupted" and (L["Interrupted"] or "Interrupted") or (L["Failed"] or "Failed"))
    end
    cb.spark:Hide()
    cb:SetAlpha(1)
    cb:Show()
    if C_Timer then
        C_Timer.After(CB.HOLD, function()
            if cb.token ~= token then return end    -- a new cast took over
            cb.holding = false
            CB:ShowIdle(cb)
        end)
    end
end

-- ============================================================
-- TIMER TEXT
-- Preferred: a DurationTextBinding (the client formats the duration's own
-- values, secret or not, and updates the text itself). Fallback: OnUpdate,
-- formatting in Lua only a value that is NOT secret.
-- ============================================================

local function Decimals(db)
    local d = tonumber(db.castbarTimerDecimals) or 1
    if d < 0 then d = 0 elseif d > 2 then d = 2 end
    return math.floor(d)
end

-- "%.<d>f", built from the decimals setting (C-side format for the binding,
-- Lua-side only for a non-secret value in the fallback).
function CB.NumberFormat(db)
    return "%." .. Decimals(db) .. "f"
end

function CB:BuildBinding(cb, db)
    local DU, SU = C_DurationUtil, C_StringUtil
    local P = Enum and Enum.DurationTextBindingProperty
    if not (DU and DU.CreateDurationTextBinding and SU and SU.CreateNumericRuleFormatter and P) then
        return nil
    end
    local fmtKey = (db.castbarTimerFormat or "REMAINING") .. ":" .. Decimals(db)
    if cb.binding and cb.bindingKey == fmtKey then return cb.binding end
    local ok, b = pcall(function()
        local step = ({ [0] = 1, 0.1, 0.01 })[Decimals(db)]
        local nf = SU.CreateNumericRuleFormatter()
        nf:SetBreakpoints({ { threshold = 0, step = step, format = CB.NumberFormat(db) } })
        local binding = cb.binding or DU.CreateDurationTextBinding()
        binding:SetFontString(cb.timer)
        local mode = db.castbarTimerFormat or "REMAINING"
        if mode == "REMAINING_TOTAL" then
            binding:SetTextFormat("{} / {}", {
                { property = P.RemainingDuration, formatter = nf },
                { property = P.TotalDuration, formatter = nf },
            })
        elseif mode == "ELAPSED" then
            binding:SetTextFormat("{}", { { property = P.ElapsedDuration, formatter = nf } })
        else
            binding:SetTextFormat("{}", { { property = P.RemainingDuration, formatter = nf } })
        end
        if binding.SetUpdateInterval then binding:SetUpdateInterval(0.05) end
        return binding
    end)
    if not ok then
        DF:DebugWarn("UF", "cast bar timer binding unavailable: %s", tostring(b))
        CB.noBinding = true
        return nil
    end
    cb.binding, cb.bindingKey = b, fmtKey
    return b
end

function CB:StartTimerText(cb, db)
    cb.textElapsed = 0
    cb.textFallback = nil
    if db.castbarShowTimer == false then cb.timer:SetText(""); return end
    local b = (not CB.noBinding) and cb.dur and CB:BuildBinding(cb, db)
    if b then
        local ok = pcall(function()
            b:SetDuration(cb.dur)
            b:SetEnabled(true)
        end)
        if ok then return end
    end
    cb.textFallback = true
    cb.timer:SetText("")
end

-- Fallback: never formats a secret.
function CB:FallbackText(cb)
    local db = K.DB(cb.owner)
    local dur = cb.dur
    if not (db and dur) then cb.timer:SetText(""); return end
    local mode = db.castbarTimerFormat or "REMAINING"
    local ok, v, total = pcall(function()
        if mode == "ELAPSED" then return dur:GetElapsedDuration() end
        if mode == "REMAINING_TOTAL" then return dur:GetRemainingDuration(), dur:GetTotalDuration() end
        return dur:GetRemainingDuration()
    end)
    if not ok or IsSecret(v) or IsSecret(total) or v == nil then
        cb.timer:SetText("")
        return
    end
    local nf = CB.NumberFormat(db)
    if total ~= nil then
        cb.timer:SetText(format(nf .. " / " .. nf, v, total))
    else
        cb.timer:SetText(format(nf, v))
    end
end

-- ============================================================
-- KICK TICK (see the header). Target / focus / boss only.
-- ============================================================
function CB:SetupKick(cb, db)
    cb.kickReady, cb.kickOn = nil, false
    cb.kickHost:SetAlpha(0)
    if not (CB.KICK_UNITS[cb.unit] and db.castbarKickTick ~= false and cb.dur) then return end
    if not (C_Spell and C_Spell.GetSpellCooldownDuration) then return end
    if not CB:PickInterrupt() then return end
    local ok = pcall(function()
        local total = cb.dur:GetTotalDuration()
        local w = cb.barWidth or cb.bar:GetWidth()
        local rev = (cb.channel and true or false) ~= (db.castbarReverse and true or false)
        local pos, kick = cb.positioner, cb.kickBar
        pos:SetMinMaxValues(0, total)
        pos:SetReverseFill(rev)
        pos:SetValue(0)
        kick:SetMinMaxValues(0, total)
        kick:SetReverseFill(rev)
        kick:ClearAllPoints()
        kick:SetWidth(w)
        kick:SetPoint("TOP", cb.bar, "TOP")
        kick:SetPoint("BOTTOM", cb.bar, "BOTTOM")
        cb.kickTick:ClearAllPoints()
        local ptex, ktex = pos:GetStatusBarTexture(), kick:GetStatusBarTexture()
        if rev then
            kick:SetPoint("RIGHT", ptex, "LEFT")
            cb.kickTick:SetPoint("CENTER", ktex, "LEFT")
        else
            kick:SetPoint("LEFT", ptex, "RIGHT")
            cb.kickTick:SetPoint("CENTER", ktex, "RIGHT")
        end
    end)
    if not ok then return end
    cb.kickOn = true
    cb.kickElapsed = CB.KICK_INTERVAL   -- read the cooldown on the first update
    CB:UpdateKick(cb)
end

-- The interrupt's cooldown: the kick bar's value, the tick's alpha, the colour.
function CB:UpdateKick(cb)
    if not cb.kickOn then return end
    local id = CB.interruptID
    local ok, cd = pcall(C_Spell.GetSpellCooldownDuration, id, true)
    if not ok or IsNil(cd) then
        cb.kickHost:SetAlpha(0)
        return
    end
    local ok2, ready = pcall(cd.IsZero, cd)
    if not ok2 then cb.kickHost:SetAlpha(0); return end
    pcall(function() cb.kickBar:SetValue(cd:GetRemainingDuration()) end)
    -- Visible while the kick is NOT ready, and never on a cast it cannot interrupt.
    -- ☠ TWO BOOLEANS, TWO FRAMES. Picking one alpha from the other flag
    -- (Pick(cb.ni, 0, 1)) makes a possibly SECRET NUMBER, which must never reach
    -- SetAlpha. So the clip frame carries "not interruptible" and the kick bar
    -- "ready", each straight from its boolean; the alphas multiply.
    AlphaFrom(cb.clip, cb.ni, 0, 1)
    AlphaFrom(cb.kickHost, ready, 0, 1)
    cb.kickReady = ready
    CB:PaintColor(cb, ready)
end

-- ============================================================
-- PER FRAME (only while something moves)
-- ============================================================
function CB:OnUpdate(cb, elapsed)
    if not cb.active then return end
    if cb.kickOn and cb.dur then
        -- The positioner follows the cast every frame (a secret into a sink).
        pcall(function() cb.positioner:SetValue(cb.dur:GetElapsedDuration()) end)
        cb.kickElapsed = (cb.kickElapsed or 0) + elapsed
        if cb.kickElapsed >= CB.KICK_INTERVAL then
            cb.kickElapsed = 0
            CB:UpdateKick(cb)
        end
    end
    if cb.textFallback then
        cb.textElapsed = (cb.textElapsed or 0) + elapsed
        if cb.textElapsed >= CB.TEXT_INTERVAL then
            cb.textElapsed = 0
            CB:FallbackText(cb)
        end
    end
    if cb.fallback then CB.PlayerFallbackTick(cb) end
end

-- ============================================================
-- PLAYER ONLY
-- ☠ The ONLY place in this file that does arithmetic on cast times. The player's
-- own cast times are not secret; every function still checks issecretvalue and
-- does nothing with a secret. Never call these for another unit.
-- ============================================================
local function PlayerTimes(cb)
    if cb.unit ~= "player" then return nil end
    local unit = cb.owner.unit
    local s, e
    if cb.channel or cb.kind == "empower" then
        s, e = select(4, UnitChannelInfo(unit))
    else
        s, e = select(4, UnitCastingInfo(unit))
    end
    if type(s) ~= "number" or type(e) ~= "number" or IsSecret(s) or IsSecret(e) or e <= s then return nil end
    return s, e
end

-- No SetTimerDuration on this client: drive the fill from the plain times.
function CB.PlayerFallbackStart(cb)
    local s, e = PlayerTimes(cb)
    if not s then return nil end
    cb.bar:SetMinMaxValues(s, e)
    return { s = s, e = e }
end

function CB.PlayerFallbackTick(cb)
    local fb = cb.fallback
    if not fb then return end
    local now = GetTime() * 1000
    if cb.channel then
        cb.bar:SetValue(fb.e - (now - fb.s))
    else
        cb.bar:SetValue(now)
    end
end

-- Latency: the tail of the bar the server has not answered yet.
function CB.PlayerLatency(cb, db)
    cb.latency:Hide()
    if cb.unit ~= "player" or not db.castbarLatency or cb.channel or not GetNetStats then return end
    local s, e = PlayerTimes(cb)
    if not s then return end
    local lat = select(4, GetNetStats())
    if type(lat) ~= "number" or IsSecret(lat) or lat <= 0 then return end
    local frac = lat / (e - s)
    if frac > 1 then frac = 1 end
    local w = (cb.barWidth or 0) * frac
    if w < 1 then return end
    cb.latency:ClearAllPoints()
    local edge = db.castbarReverse and "LEFT" or "RIGHT"
    cb.latency:SetPoint("TOP" .. edge, cb.bar, "TOP" .. edge, 0, 0)
    cb.latency:SetPoint("BOTTOM" .. edge, cb.bar, "BOTTOM" .. edge, 0, 0)
    cb.latency:SetWidth(w)
    cb.latency:Show()
end

function CB.HideStages(cb)
    for _, t in ipairs(cb.stages) do t:Hide() end
end

-- Empower stage marks at the cumulative stage percentages.
function CB.PlayerStages(cb, db)
    CB.HideStages(cb)
    if cb.unit ~= "player" or cb.kind ~= "empower" or db.castbarEmpower == false then return end
    if not UnitEmpoweredStagePercentages then return end
    local ok, pcts = pcall(UnitEmpoweredStagePercentages, cb.owner.unit, true)
    if not ok or type(pcts) ~= "table" then return end
    local w = cb.barWidth or 0
    -- Percentages may come as 0..1 or 0..100: one pass to tell, before any mark.
    local scale = 1
    for i = 1, #pcts do
        local p = pcts[i]
        if type(p) ~= "number" or IsSecret(p) then return end
        if p > 1 then scale = 100 end
    end
    local sum = 0
    -- The last entry is the hold-at-max time: no mark after it.
    for i = 1, #pcts - 1 do
        sum = sum + pcts[i] / scale
        local t = cb.stages[i]
        if not t then
            t = cb.bar:CreateTexture(nil, "OVERLAY", nil, 3)
            t:SetTexture(K.WHITE)
            t:SetVertexColor(1, 1, 1, 0.8)
            t:SetWidth(1)
            cb.stages[i] = t
        end
        local x = sum * w
        t:ClearAllPoints()
        t:SetPoint("TOP", cb.bar, "TOPLEFT", x, 0)
        t:SetPoint("BOTTOM", cb.bar, "BOTTOMLEFT", x, 0)
        t:Show()
    end
end

-- ============================================================
-- PREVIEW: a fake cast, mid-way, looping while the preview is up.
-- Built from a NON-secret sample duration, so it runs the same fill and text
-- paths a live cast does.
-- ============================================================
CB.PREVIEW_TOTAL, CB.PREVIEW_ELAPSED = 2.5, 1.2

function CB:Preview(f)
    local cb = f and f.dfUFCastBar
    if not cb then return end
    local db = K.DB(f)
    CB:Layout(f)
    if not Enabled(db) then cb:Hide(); return end
    CB:Halt(cb)
    -- A preview frame marked idle (every sample boss but the first) shows no cast,
    -- and neither does any while the units test panel's Cast Bar switch is off.
    local P = UF.Preview
    if f.dfUFPreviewIdle or (P and P.TestOn and not P:TestOn("showCastBars")) then
        CB:ShowIdle(cb)
        return
    end
    local dur = SampleDuration(CB.PREVIEW_TOTAL, CB.PREVIEW_ELAPSED)
    cb.active, cb.channel, cb.kind, cb.dur, cb.ni = true, false, "cast", dur, false
    if not (dur and CB.ApplyTimer(cb.bar, dur, false)) then
        cb.bar:SetMinMaxValues(0, 1)
        cb.bar:SetValue(CB.PREVIEW_ELAPSED / CB.PREVIEW_TOTAL)
    end
    local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(116)) or "Frostbolt"
    local icon = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(116)) or 135846
    cb.icon:SetTexture(icon)
    CB:PaintName(cb, name, { castbarShowSpell = db.castbarShowSpell })
    CB:SetInterruptible(cb, false)
    CB:PaintColor(cb, nil)
    CB:StartTimerText(cb, db)
    cb.spark:SetShown(cb.showSpark and true or false)
    CB.ShowFill(cb, true)
    cb:SetAlpha(1)
    cb:Show()
    if C_Timer and not cb.previewLoop then
        cb.previewLoop = true
        C_Timer.After(CB.PREVIEW_TOTAL - CB.PREVIEW_ELAPSED + 0.5, function()
            cb.previewLoop = nil
            if f:IsVisible() then CB:Preview(f) end
        end)
    end
end

-- ============================================================
-- SHARED LISTENER: the interrupt is re-picked after a spec / spellbook change.
-- ============================================================
if CreateFrame then
    local driver = CreateFrame("Frame")
    for _, ev in ipairs({ "PLAYER_SPECIALIZATION_CHANGED", "SPELLS_CHANGED", "PLAYER_TALENT_UPDATE",
                          "TRAIT_CONFIG_UPDATED", "PLAYER_ENTERING_WORLD" }) do
        pcall(driver.RegisterEvent, driver, ev)
    end
    driver:SetScript("OnEvent", function() CB:ForgetInterrupt() end)
    CB.driver = driver
end

E:Register(CB)
