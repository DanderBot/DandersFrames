local addonName, UF = ...

-- ============================================================
-- CLASS POWER (the player frame only; spec §3.4, §5)
-- The player's class resource for the current class / spec / form:
--   combo points (Rogue; Druid in Cat Form), holy power (Paladin), chi
--   (Windwalker), soul shards (Warlock; Destruction shows the fragments
--   between shards), arcane charges (Arcane), essence (Evoker), runes (Death
--   Knight, each with its own recharge), stagger (Brewmaster, a bar).
-- Nothing for a class / spec without one (the element hides). Attached it sits
-- over / under the player frame; detached it is DandersMover element
-- `player.classpower` (Mover.lua) at its own record.
--
-- ☠ SECRET VALUES. The current power can be secret in combat. DandersUF showed
-- 0 because it read the number in Lua. Here each pip is a tiny StatusBar with
-- min/max (i-1, i) -- (i-1)*10, i*10 for Destruction's fragments -- and EVERY pip
-- is fed the SAME raw value: pip i is empty below i-1, full at i and above, and
-- the client does the comparing. The value is never read, compared or formatted
-- in Lua. "Hide When Empty" only applies when the value is not secret.
-- Stagger has no safe display while secret (its colour bands need a ratio), so
-- the bar hides while it is.
-- Runes: GetRuneCooldown is the player's own and not secret; each recharging
-- rune runs off a duration object (SetTimerDuration) when the client has one,
-- and is checked with issecretvalue before any number is used.
--
-- ⚠ UNVERIFIED IN GAME: Enum.PowerType names, GetUnitChargedPowerPoints,
-- UnitPower(..., true) as fragments for Destruction, GetShapeshiftFormID() == 1
-- for Cat Form, C_DurationUtil + SetTimerDuration on the rune pips.
-- ============================================================

local DF = DandersFrames
if not DF then return end

local ipairs, pairs, type, pcall, select = ipairs, pairs, type, pcall, select
local tonumber, math_floor, math_ceil = tonumber, math.floor, math.ceil

local CP = { NAME = "ClassPower" }
UF.ClassPower = CP

local E = UF.Elements
local K = E and E.Kit
if not (E and K) then return end
local IsSecret, Pick = K.IsSecret, K.Pick

CP.UNITS = { player = true }

-- Cat Form's shapeshift id.
CP.CAT_FORM = 1
-- Stagger re-read cadence while it is shown.
CP.STAGGER_INTERVAL = 0.1
-- Stagger colour bands (share of max health).
CP.STAGGER_BANDS = { { 0.3, 0.52, 1.0, 0.52 }, { 0.6, 1.0, 0.98, 0.72 }, { math.huge, 1.0, 0.42, 0.42 } }

-- ============================================================
-- THE RESOURCE MAP
-- by class, then (where it differs) by spec id. Power types are Enum.PowerType
-- names, resolved at call time. `token` is the PowerBarColor key.
-- ============================================================
CP.CLASSES = {
    ROGUE       = { pips = "ComboPoints", token = "COMBO_POINTS", max = 5 },
    DRUID       = { pips = "ComboPoints", token = "COMBO_POINTS", max = 5, catOnly = true },
    PALADIN     = { pips = "HolyPower", token = "HOLY_POWER", max = 5 },
    WARLOCK     = { pips = "SoulShards", token = "SOUL_SHARDS", max = 5, fragmentsSpec = 267 },
    EVOKER      = { pips = "Essence", token = "ESSENCE", max = 5 },
    DEATHKNIGHT = { runes = true, max = 6 },
    MONK        = { specs = { [269] = { pips = "Chi", token = "CHI", max = 5 },
                              [268] = { stagger = true } } },
    MAGE        = { specs = { [62] = { pips = "ArcaneCharges", token = "ARCANE_CHARGES", max = 4 } } },
}

local function PlayerClass()
    local class = UnitClass and select(2, UnitClass("player"))
    if type(class) ~= "string" or IsSecret(class) then return nil end
    return class
end

local function PlayerSpec()
    if not (GetSpecialization and GetSpecializationInfo) then return nil end
    local idx = GetSpecialization()
    if not idx or IsSecret(idx) then return nil end
    local id = GetSpecializationInfo(idx)
    if IsSecret(id) then return nil end
    return id
end

local function InCatForm()
    if not GetShapeshiftFormID then return false end
    local id = GetShapeshiftFormID()
    if IsSecret(id) then return false end
    return id == CP.CAT_FORM
end

-- What the player shows right now: { kind = "pips"|"runes"|"stagger", ... } or nil.
-- class / spec / cat can be passed in (tests, previews); live calls read them.
function CP:Resolve(class, spec, cat, db)
    class = class or PlayerClass()
    local c = class and CP.CLASSES[class]
    if not c then return nil end
    if c.specs then
        spec = spec or PlayerSpec()
        c = spec and c.specs[spec]
        if not c then return nil end
    end
    if c.catOnly then
        if cat == nil then cat = InCatForm() end
        if not cat then return nil end
    end
    if c.runes then
        if db and db.classPowerRunes == false then return nil end
        return { kind = "runes", max = c.max, token = "RUNES" }
    end
    if c.stagger then
        if db and db.classPowerStagger == false then return nil end
        return { kind = "stagger", token = "STAGGER" }
    end
    local fragments = false
    if c.fragmentsSpec then
        spec = spec or PlayerSpec()
        fragments = (spec == c.fragmentsSpec)
    end
    return { kind = "pips", power = c.pips, token = c.token, max = c.max, fragments = fragments }
end

local function PowerType(name)
    local PT = Enum and Enum.PowerType
    return PT and PT[name] or nil
end

-- The pip count: the client's max when it is a plain number, else the map's.
function CP:MaxPips(res)
    if res.kind == "runes" then return res.max or 6 end
    if res.kind == "stagger" then return 1 end
    local pt = PowerType(res.power)
    if pt and UnitPowerMax then
        local ok, m = pcall(UnitPowerMax, "player", pt)
        if ok and type(m) == "number" and not IsSecret(m) and m > 0 then return m end
    end
    return res.max or 5
end

-- ============================================================
-- BUILD
-- ============================================================
local function NewPip(cp)
    local pip = CreateFrame("StatusBar", nil, cp)
    pip:SetMinMaxValues(0, 1)
    pip:SetValue(0)
    pip.bg = pip:CreateTexture(nil, "BACKGROUND")
    pip.bg:SetAllPoints(pip)
    pip.bg:SetTexture(K.WHITE)
    return pip
end

function CP:Attach(f)
    if not f or f.dfUFClassPower or not CP.UNITS[f.dfUFUnit] then return end
    local cp = CreateFrame("Frame", nil, f)
    cp:Hide()
    cp.owner = f
    cp.pips = {}
    cp.bg = cp:CreateTexture(nil, "BACKGROUND")
    cp.bg:SetAllPoints(cp)
    cp.bg:SetTexture(K.WHITE)
    cp.single = NewPip(cp)
    cp.single:Hide()
    cp.active, cp.activeSingle = cp.pips, cp.single
    f.dfUFClassPower = cp
    if not f.dfUFPreview then
        local listener = CreateFrame("Frame")
        listener:SetScript("OnEvent", function(_, event, ...) CP:OnEvent(cp, event, ...) end)
        cp.listener = listener
    end
    cp:SetScript("OnUpdate", function(self, elapsed) CP:OnUpdate(self, elapsed) end)
    return cp
end

local function Enabled(db) return db and db.classPowerEnabled and true or false end

function CP:IsDetached(f, db)
    db = db or K.DB(f)
    return db and db.classPowerDetached and true or false
end

-- The fill colour for this resource.
function CP:Color(db, res)
    local mode = db.classPowerColorMode or "CLASS"
    if mode == "CUSTOM" then return K.RGBA(db.classPowerColor, 1, 0.82, 0) end
    if mode == "POWER" and res and PowerBarColor then
        local c = PowerBarColor[res.token]
        if c then return c.r or 1, c.g or 1, c.b or 1 end
    end
    local class = PlayerClass()
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 1, 0.82, 0
end

-- ============================================================
-- LAYOUT: size, pips, look, position. `res` may be passed (preview).
-- ============================================================
function CP:Layout(f, res)
    local cp = f and f.dfUFClassPower
    if not cp then return end
    local db = K.DB(f)
    if not db or not Enabled(db) then
        cp:Hide()
        cp.res = nil
        if UF.Mover and UF.Mover.SyncChild then UF.Mover:SyncChild(f.dfUFUnit, "classpower") end
        return
    end
    res = res or (not f.dfUFPreview and CP:Resolve(nil, nil, nil, db)) or cp.previewRes
    cp.res = res
    -- RING style with a class power section: the pips go into the ring.
    local R = UF.Rings
    local ring, sec = nil, nil
    if R then ring, sec = R.ClassPowerArc(db) end
    if ring then
        CP:LayoutRing(f, cp, db, res, ring, sec)
        if UF.Mover and UF.Mover.SyncChild then UF.Mover:SyncChild(f.dfUFUnit, "classpower") end
        if not f.dfUFPreview then CP:Update(f) end
        return
    end
    CP.HideRing(cp)
    local showBorder = db.classPowerBorderEnabled ~= false
    local w
    if db.classPowerMatchWidth ~= false then
        -- K.Border draws OUTSIDE each pip, so the bar is narrowed by the border
        -- on each side: its outer edge then lines up with the frame's.
        w = K.FrameWidth(f, db)
        if showBorder then
            local bs = tonumber(db.classPowerBorderSize) or 1
            if bs < 1 then bs = 1 end
            w = w - 2 * bs
        end
    else
        w = tonumber(db.classPowerWidth) or 220
    end
    local h = tonumber(db.classPowerHeight) or 6
    local gap = tonumber(db.classPowerGap) or 2
    cp:SetSize(w, h)
    cp.bg:SetVertexColor(K.RGBA(db.classPowerBg, 0, 0, 0, 0.6))
    cp.bg:SetShown(false)

    local tex = db.classPowerTexture or K.BAR
    local r, g, b = CP:Color(db, res)
    local er, eg, eb, ea = K.RGBA(db.classPowerEmptyColor, 0.15, 0.15, 0.15, 0.6)
    local single = res and (res.kind == "stagger" or db.classPowerMode == "BAR")
    local n = (res and not single) and CP:MaxPips(res) or 0
    cp.count = n

    for i, pip in ipairs(cp.pips) do
        if i > n then pip:Hide() end
    end
    local pipW = n > 0 and (w - gap * (n - 1)) / n or w
    for i = 1, n do
        local pip = cp.pips[i]
        if not pip then
            pip = NewPip(cp)
            cp.pips[i] = pip
        end
        pip:ClearAllPoints()
        pip:SetSize(pipW, h)
        pip:SetPoint("LEFT", cp, "LEFT", (i - 1) * (pipW + gap), 0)
        pip:SetStatusBarTexture(tex)
        pip:SetStatusBarColor(r, g, b)
        pip.bg:SetVertexColor(er, eg, eb, ea)
        if res and res.fragments then
            pip:SetMinMaxValues((i - 1) * 10, i * 10)
        elseif res and res.kind == "pips" then
            pip:SetMinMaxValues(i - 1, i)
        end
        K.Border(pip, showBorder, db.classPowerBorderSize, db.classPowerBorderColor)
        pip:Show()
    end
    local s = cp.single
    if single then
        s:ClearAllPoints()
        s:SetAllPoints(cp)
        s:SetStatusBarTexture(tex)
        s:SetStatusBarColor(r, g, b)
        s.bg:SetVertexColor(er, eg, eb, ea)
        K.Border(s, showBorder, db.classPowerBorderSize, db.classPowerBorderColor)
        s:Show()
    else
        s:Hide()
    end
    cp.isSingle = single and true or false
    -- What Update / Preview write to: the linear pips (a ring has its own, below).
    cp.active, cp.activeSingle = cp.pips, s

    -- Position.
    cp:ClearAllPoints()
    if CP:IsDetached(f, db) then
        cp:SetParent(K.DetachedParent(f))
        cp:SetScale(tonumber(db.frameScale) or 1)
        K.PlaceDetached(cp, f, db.classPowerPositionRecord)
    else
        cp:SetParent(f)
        cp:SetScale(1)
        local x, y = tonumber(db.classPowerX) or 0, tonumber(db.classPowerY) or 0
        if db.classPowerPosition == "BOTTOM" then
            cp:SetPoint("TOP", f, "BOTTOM", x, -y)
        else
            cp:SetPoint("BOTTOM", f, "TOP", x, y)
        end
    end
    cp:SetFrameLevel(f:GetFrameLevel() + 8)
    if UF.Mover and UF.Mover.SyncChild then UF.Mover:SyncChild(f.dfUFUnit, "classpower") end
    if not f.dfUFPreview then CP:Update(f) end
end

-- ============================================================
-- IN A RING (Rings.lua; frameStyle RING with a CLASSPOWER section)
-- The same pips, drawn as slices of the section's arc (R.PipArcs): each a radial
-- bar with its own track, ranged and fed exactly as the linear pips are, so
-- Update / runes / charged points / the preview run unchanged on cp.active.
-- Stagger and Bar mode: one slice, the whole arc. Reversed: pip 1 at the arc's
-- far end and every slice fills the other way. The bar's own size, position,
-- border and texture do not apply; the empty colour is the section's track colour
-- (else Empty Color).
-- ============================================================
function CP.HideRing(cp)
    if not cp.inRing then return end
    cp.inRing = false
    for _, p in ipairs(cp.ringPips or {}) do
        p.fill:Hide()
        p.track:Hide()
    end
end

function CP:LayoutRing(f, cp, db, res, ring, sec)
    local R = UF.Rings
    for _, pip in ipairs(cp.pips) do pip:Hide() end
    cp.single:Hide()
    cp.bg:Hide()
    cp.inRing = true
    local r, g, b = CP:Color(db, res)
    local er, eg, eb, ea = R.TrackColor(db, sec)
    local single = res and (res.kind == "stagger" or db.classPowerMode == "BAR")
    local n = (res and not single) and CP:MaxPips(res) or 0
    cp.count = n
    local a, len = R.Arc(sec)
    local arcs = (n > 0) and R.PipArcs(a, len, n) or { { start = a, len = len } }
    if not res then arcs = {} end

    cp:SetParent(f)
    cp:SetScale(1)
    cp:ClearAllPoints()
    cp:SetPoint("CENTER", f, "CENTER", 0, 0)
    cp:SetSize(ring.outer, ring.outer)
    -- Over the rings' arcs, under the text.
    cp:SetFrameLevel(f:GetFrameLevel() + (R.LEVEL_CLASSPOWER or 6))

    cp.ringPips = cp.ringPips or {}
    cp.active = {}
    for i = 1, #arcs do
        local p = cp.ringPips[i]
        if not p then
            p = { track = R.NewArcBar(cp), fill = R.NewArcBar(cp) }
            cp.ringPips[i] = p
        end
        local arc = sec.reverse and arcs[#arcs - i + 1] or arcs[i]
        R.SetArcTexture(p.fill, R.FillTexture(db, sec))
        R.ShapeArcBar(p.track, cp, ring.outer, ring.inner, arc.start, arc.len, false, 0)
        R.ShapeArcBar(p.fill, cp, ring.outer, ring.inner, arc.start, arc.len, sec.reverse, sec.feather)
        p.fill:SetFrameLevel(p.track:GetFrameLevel() + 1)
        p.track:SetMinMaxValues(0, 1)
        p.track:SetValue(1)
        p.track:SetStatusBarColor(er, eg, eb, ea)
        p.fill:SetStatusBarColor(r, g, b)
        if res and res.fragments and not single then
            p.fill:SetMinMaxValues((i - 1) * 10, i * 10)
        elseif res and res.kind == "pips" and not single then
            p.fill:SetMinMaxValues(i - 1, i)
        end
        p.track:Show()
        p.fill:Show()
        cp.active[i] = p.fill
    end
    for i = #arcs + 1, #cp.ringPips do
        cp.ringPips[i].track:Hide()
        cp.ringPips[i].fill:Hide()
    end
    cp.isSingle = single and true or false
    cp.activeSingle = (single and cp.ringPips[1]) and cp.ringPips[1].fill or cp.single
end

-- ============================================================
-- VALUES
-- ============================================================
function CP:Update(f)
    local cp = f and f.dfUFClassPower
    if not cp or f.dfUFPreview then return end
    local db = K.DB(f)
    local res = cp.res
    if not (db and Enabled(db) and res) or not f:IsVisible() or CP:InVehicle() then
        cp:Hide()
        return
    end
    -- UnitAffectingCombat, not InCombatLockdown: on PLAYER_REGEN_DISABLED lockdown
    -- is not active yet, so the bar stayed hidden through the pull.
    if db.classPowerHideOOC and not UnitAffectingCombat("player") then
        cp:Hide()
        return
    end
    if res.kind == "runes" then
        CP:UpdateRunes(cp, db)
    elseif res.kind == "stagger" then
        if not CP:UpdateStagger(cp, db) then cp:Hide(); return end
    else
        local pt = PowerType(res.power)
        if not pt or not UnitPower then cp:Hide(); return end
        local ok, v = pcall(UnitPower, "player", pt, res.fragments or nil)
        if not ok then cp:Hide(); return end
        -- ★ The same raw value into every pip; never read here.
        if cp.isSingle then
            local maxV = CP:MaxPips(res) * (res.fragments and 10 or 1)
            cp.activeSingle:SetMinMaxValues(0, maxV)
            cp.activeSingle:SetValue(v)
        else
            for i = 1, cp.count do cp.active[i]:SetValue(v) end
            CP:PaintCharged(cp, db)
        end
        if db.classPowerHideEmpty and not IsSecret(v) and v == 0 then
            cp:Hide()
            return
        end
    end
    cp:Show()
end

-- Charged combo points (Echoing Reprimand / Supercharger) in their own colour.
function CP:PaintCharged(cp, db)
    local res = cp.res
    if not (res and res.power == "ComboPoints" and GetUnitChargedPowerPoints) then return end
    local r, g, b = CP:Color(db, res)
    local cr, cg, cb = K.RGBA(db.classPowerChargedColor, 0.4, 0.8, 1)
    local charged = {}
    local ok, list = pcall(GetUnitChargedPowerPoints, "player")
    if ok and type(list) == "table" then
        for _, idx in ipairs(list) do
            if type(idx) == "number" and not IsSecret(idx) then charged[idx] = true end
        end
    end
    for i = 1, cp.count do
        if charged[i] then cp.active[i]:SetStatusBarColor(cr, cg, cb)
        else cp.active[i]:SetStatusBarColor(r, g, b) end
    end
end

function CP:UpdateRunes(cp, db)
    if not GetRuneCooldown then return end
    for i = 1, cp.count do
        local pip = cp.active[i]
        local start, duration, ready = GetRuneCooldown(i)
        if IsSecret(ready) then
            pip:SetMinMaxValues(0, 1)
            pip:SetValue(Pick(ready, 1, 0))
        elseif ready or IsSecret(start) or IsSecret(duration)
            or type(start) ~= "number" or type(duration) ~= "number" or duration <= 0 then
            pip:SetMinMaxValues(0, 1)
            pip:SetValue(ready and 1 or 0)
            pip.dfRune = nil
        else
            local armed = false
            local DU = C_DurationUtil
            if DU and DU.CreateDuration and pip.SetTimerDuration then
                armed = pcall(function()
                    local d = pip.dfRuneDur or DU.CreateDuration()
                    pip.dfRuneDur = d
                    d:SetTimeFromStart(start, duration)
                    local D, I = Enum and Enum.StatusBarTimerDirection, Enum and Enum.StatusBarInterpolation
                    pip:SetTimerDuration(d, I and I.Immediate or nil, D and D.ElapsedTime or nil)
                end)
            end
            if armed then
                pip.dfRune = nil
            else
                -- Plain numbers (checked above): a min/max over the recharge window,
                -- moved on by OnUpdate.
                pip:SetMinMaxValues(start, start + duration)
                pip:SetValue(GetTime())
                pip.dfRune = true
            end
        end
    end
end

-- Returns false when stagger cannot be shown (secret, or no max health).
function CP:UpdateStagger(cp, db)
    if not (UnitStagger and UnitHealthMax) then return false end
    local st, mx = UnitStagger("player"), UnitHealthMax("player")
    if IsSecret(st) or IsSecret(mx) or type(st) ~= "number" or type(mx) ~= "number" or mx <= 0 then
        return false
    end
    local s = cp.activeSingle
    s:SetMinMaxValues(0, mx)
    s:SetValue(st)
    local ratio = st / mx
    for _, band in ipairs(CP.STAGGER_BANDS) do
        if ratio < band[1] then
            s:SetStatusBarColor(band[2], band[3], band[4])
            break
        end
    end
    if db.classPowerHideEmpty and st == 0 then return false end
    return true
end

function CP:InVehicle()
    local U = UF.Units
    return U and U.InVehicle and U:InVehicle() or false
end

function CP:OnUpdate(cp, elapsed)
    if not cp:IsShown() or not cp.res then return end
    if cp.res.kind == "stagger" then
        cp.staggerElapsed = (cp.staggerElapsed or 0) + elapsed
        if cp.staggerElapsed >= CP.STAGGER_INTERVAL then
            cp.staggerElapsed = 0
            if cp.owner and not cp.owner.dfUFPreview then CP:Update(cp.owner) end
        end
    elseif cp.res.kind == "runes" then
        local now = GetTime()
        for i = 1, cp.count or 0 do
            local pip = cp.active[i]
            if pip.dfRune then pip:SetValue(now) end
        end
    end
end

-- ============================================================
-- EVENTS (only while the player frame is shown and class power is on)
-- ============================================================
CP.UNIT_EVENTS = { "UNIT_POWER_FREQUENT", "UNIT_MAXPOWER", "UNIT_DISPLAYPOWER",
                   "UNIT_POWER_POINT_CHARGE", "PLAYER_SPECIALIZATION_CHANGED" }
CP.EVENTS = { "RUNE_POWER_UPDATE", "UPDATE_SHAPESHIFT_FORM", "TRAIT_CONFIG_UPDATED",
              "PLAYER_TALENT_UPDATE", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED" }
-- Events after which the resource itself may be a different one.
CP.RESOLVE = { UPDATE_SHAPESHIFT_FORM = true, PLAYER_SPECIALIZATION_CHANGED = true,
               TRAIT_CONFIG_UPDATED = true, PLAYER_TALENT_UPDATE = true, UNIT_MAXPOWER = true,
               UNIT_DISPLAYPOWER = true }

function CP:SetActive(f, on)
    local cp = f and f.dfUFClassPower
    if not cp or not cp.listener then return end
    on = on and Enabled(K.DB(f)) or false
    if cp.eventsOn == on then
        if not on then cp:Hide() end
        return
    end
    cp.eventsOn = on
    local l = cp.listener
    for _, ev in ipairs(CP.UNIT_EVENTS) do
        if on then pcall(l.RegisterUnitEvent, l, ev, "player") else pcall(l.UnregisterEvent, l, ev) end
    end
    for _, ev in ipairs(CP.EVENTS) do
        if on then pcall(l.RegisterEvent, l, ev) else pcall(l.UnregisterEvent, l, ev) end
    end
    if not on then cp:Hide() end
end

function CP:OnEvent(cp, event)
    local f = cp.owner
    if not f or not f:IsVisible() then return end
    if CP.RESOLVE[event] then
        CP:Layout(f)        -- re-resolves, rebuilds the pips, then updates
    else
        CP:Update(f)
    end
end

function CP:Refresh(f)
    local cp = f and f.dfUFClassPower
    if not cp or f.dfUFPreview then return end
    local want = Enabled(K.DB(f)) and f:IsVisible() or false
    if (cp.eventsOn or false) ~= want then CP:SetActive(f, want) end
    if want then CP:Layout(f) else cp:Hide() end
end

function CP:OnUnitChanged(f) CP:Update(f) end

-- ============================================================
-- PREVIEW: the player's own resource (or five combo points), half full.
-- ============================================================
function CP:Preview(f)
    local cp = f and f.dfUFClassPower
    if not cp then return end
    local db = K.DB(f)
    if not Enabled(db) then cp:Hide(); return end
    -- The units test panel's Class Power switch.
    local P = UF.Preview
    if P and P.TestOn and not P:TestOn("showClassPower") then cp:Hide(); return end
    local res = CP:Resolve(nil, nil, true, db) or { kind = "pips", power = "ComboPoints", token = "COMBO_POINTS", max = 5 }
    if res.kind == "stagger" then res = { kind = "pips", power = "Chi", token = "CHI", max = 5 } end
    if res.kind == "runes" then res = { kind = "pips", power = "Runes", token = "RUNES", max = 6 } end
    cp.previewRes = res
    CP:Layout(f, res)
    local n = res.max or 5
    local v = math_ceil(n / 2)
    if cp.isSingle then
        cp.activeSingle:SetMinMaxValues(0, n)
        cp.activeSingle:SetValue(v)
    else
        for i = 1, cp.count do
            local pip = cp.active[i]
            pip:SetMinMaxValues(i - 1, i)
            pip:SetValue(v)
        end
    end
    cp:Show()
end

E:Register(CP)
