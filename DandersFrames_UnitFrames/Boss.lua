local addonName, UF = ...

-- ============================================================
-- BOSS FRAMES (spec §1.5, §1.6, §4 UF:Boss, Q8, Q13)
-- One container holding UF.BOSS_COUNT secure unit buttons, boss1..bossN. Every
-- slot is an ordinary unit-frame button (Units:Build): DandersUnitButtonTemplate
-- made standalone on ONE shared settings table (units.boss, Q8), its own unit
-- events while shown, DF's updaters for the paint, the element registry for the
-- cast bar / portrait / icons, and DF's range registry for the fade.
--
--   holder      DandersUnitFrameBossHolder      the unit's Visibility driver
--   container   DandersUnitFrameBossContainer   the mover element "boss"; scaled
--                                               by frameScale, sized for every slot
--   slots       DandersUnitFrameBoss1..N        unit watch: shown while bossN exists
--
-- ★ FIXED SLOTS, UNIT ORDER. bossN always sits in slot N, laid out from the
-- growth corner (Boss Layout page). Nothing moves in combat -- a slot is only
-- shown or hidden by its unit watch -- so there is no secure re-sort snippet. A
-- boss that leaves mid-fight leaves its slot empty until it comes back.
--
-- ENGAGE SETTLE. INSTANCE_ENCOUNTER_ENGAGE_UNIT (any boss token changed) and a
-- slot's own UNIT_TARGETABLE_CHANGED repaint the slot(s) on the next rendered
-- frame, then re-check each slot's identity once more a moment later: the token
-- can be handed to the new NPC a little after the event. ☠ A secret GUID may
-- not be compared, so it counts as changed (a repaint), every time.
--
-- Q13: the count is one constant (v1 = boss1-5). Raising it needs only this
-- number (and the settings sliders, which clamp to it).
-- ============================================================

local DF = DandersFrames
if not DF then return end

local ipairs, pairs, type, pcall = ipairs, pairs, type, pcall
local floor, max, min = math.floor, math.max, math.min
local InCombatLockdown = InCombatLockdown

UF.BOSS_COUNT = 5

local B = { frames = {}, preview = {} }
UF.Boss = B

-- Seconds after an engage / targetable change before the identity re-check.
B.SETTLE = 0.25

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) and true or false
end

-- ============================================================
-- LAYOUT MATHS (pure: settings in, offsets out)
-- Growth direction -> the corner every slot is laid out from, the step along the
-- growth (sx, sy) and where a full row wraps to. Up / Down wrap into a new
-- column on the right; Left / Right wrap into a new row below.
-- ============================================================
B.GROWTH = {
    DOWN  = { corner = "TOPLEFT",    vertical = true,  dir = -1 },
    UP    = { corner = "BOTTOMLEFT", vertical = true,  dir = 1 },
    RIGHT = { corner = "TOPLEFT",    vertical = false, dir = 1 },
    LEFT  = { corner = "TOPRIGHT",   vertical = false, dir = -1 },
}

local function Clamp(v, lo, hi, default)
    v = tonumber(v)
    if not v then return default end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- The settings the layout reads, defaulted and clamped.
function B:Params(db)
    db = db or UF:GetUnitDB("boss")
    local growth = B.GROWTH[db.bossGrowth] and db.bossGrowth or "DOWN"
    return {
        growth  = growth,
        g       = B.GROWTH[growth],
        w       = Clamp(db.frameWidth, 1, 2000, 180),
        h       = Clamp(db.frameHeight, 1, 2000, 40),
        spacing = Clamp(db.bossSpacing, -50, 500, 40),
        rowGap  = Clamp(db.bossRowSpacing, -50, 500, 4),
        perRow  = floor(Clamp(db.bossUnitsPerRow, 1, UF.BOSS_COUNT, UF.BOSS_COUNT)),
    }
end

-- Slot i's corner offset from the container's corner (the growth corner), in
-- the container's own units. x grows right, y grows up (WoW's SetPoint axes).
function B:SlotOffset(i, p)
    p = p or B:Params()
    local idx = i - 1
    local along = idx % p.perRow
    local wrap = floor(idx / p.perRow)
    local x, y
    if p.g.vertical then
        x, y = wrap * (p.w + p.rowGap), p.g.dir * along * (p.h + p.spacing)
    else
        x, y = p.g.dir * along * (p.w + p.spacing), -wrap * (p.h + p.rowGap)
    end
    return x + 0, y + 0      -- + 0: no negative zero
end

-- The box n slots fill, in the container's own units.
function B:BoxSize(n, p)
    p = p or B:Params()
    n = max(1, n or UF.BOSS_COUNT)
    local lines = min(n, p.perRow)
    local wraps = floor((n - 1) / p.perRow) + 1
    if p.g.vertical then
        return wraps * p.w + (wraps - 1) * p.rowGap, lines * p.h + (lines - 1) * p.spacing
    end
    return lines * p.w + (lines - 1) * p.spacing, wraps * p.h + (wraps - 1) * p.rowGap
end

-- -1 / 0 / 1 for the horizontal and vertical side a point names.
local function Sides(point)
    point = point or "CENTER"
    local sx = (point:find("LEFT") and -1) or (point:find("RIGHT") and 1) or 0
    local sy = (point:find("TOP") and 1) or (point:find("BOTTOM") and -1) or 0
    return sx, sy
end
B.Sides = Sides

-- Slot i's rect (l, r, b, t) relative to the container's CENTER, in the
-- container's own units, for a container sized for every slot.
function B:SlotRect(i, p)
    p = p or B:Params()
    local W, H = B:BoxSize(UF.BOSS_COUNT, p)
    local sx, sy = Sides(p.g.corner)
    local cx, cy = sx * W / 2, sy * H / 2          -- the corner, from the centre
    local x, y = B:SlotOffset(i, p)
    x, y = cx + x, cy + y
    local l, r, b, t
    if sx < 0 then l, r = x, x + p.w else l, r = x - p.w, x end
    if sy > 0 then t, b = y, y - p.h else b, t = y, y + p.h end
    return l, r, b, t
end

-- ============================================================
-- SPAWNING
-- ============================================================
local function ContainerName() return (UF.Units.FRAME_NAMES.boss or "DandersUnitFrameBoss") .. "Container" end

function B:Spawn()
    if B.container then return B.container end
    local Units = UF.Units
    if not Units then return nil end
    if InCombatLockdown() then
        DF:DebugWarn("UF", "Boss spawn: in combat, cannot create secure frames")
        return nil
    end
    local holder = Units:GetHolder("boss")
    -- Secure like DandersFrames' own party container: it hosts secure buttons.
    local c = CreateFrame("Frame", ContainerName(), holder, "SecureFrameTemplate")
    B.container = c
    for i = 1, UF.BOSS_COUNT do
        local f = Units:Build("boss" .. i, "boss", "boss" .. i, Units.FRAME_NAMES.boss .. i, c, i)
        B.frames[i] = f
    end
    B:ApplyLayout()
    B:ApplyPosition()
    for _, f in ipairs(B.frames) do
        Units:ApplyLayout(f)
    end
    Units:ApplyVisibility(B.frames[1])
    UF.Debug("spawned %d boss frames", UF.BOSS_COUNT)
    return c
end

-- Size, scale and slot positions. Secure: out of combat only (callers queue).
function B:LayoutContainer(c, slots, db)
    if not c then return end
    db = db or UF:GetUnitDB("boss")
    local p = B:Params(db)
    c:SetScale(tonumber(db.frameScale) or 1)
    c:SetSize(B:BoxSize(UF.BOSS_COUNT, p))
    local corner = p.g.corner
    for i, f in pairs(slots) do
        local x, y = B:SlotOffset(i, p)
        f:ClearAllPoints()
        f:SetPoint(corner, c, corner, x, y)
    end
end

function B:ApplyLayout()
    if not B.container or InCombatLockdown() then return end
    B:LayoutContainer(B.container, B.frames)
end

function B:ApplyPosition()
    if not B.container or InCombatLockdown() then return end
    UF.Units:PlaceAt(B.container, UF:GetPositionRecord("boss"))
end

-- ============================================================
-- IDENTITY AND THE ENGAGE SETTLE
-- ============================================================
function B:NoteIdentity(f)
    local guid = UnitGUID and UnitGUID(f.unit)
    f.dfUFLastGUID = (not IsSecret(guid)) and guid or nil
end

-- Repaint a shown slot whose unit is someone else now. Returns true when it did.
function B:CheckIdentity(f)
    if not (f and f:IsVisible()) then return false end
    local guid = UnitGUID and UnitGUID(f.unit)
    local secret = IsSecret(guid)
    if guid == nil or secret or guid ~= f.dfUFLastGUID then
        f.dfUFLastGUID = (not secret) and guid or nil
        UF.Units:FullRefresh(f)
        return true
    end
    return false
end

function B:CheckAll()
    local n = 0
    for _, f in ipairs(B.frames) do
        if B:CheckIdentity(f) then n = n + 1 end
    end
    return n
end

-- Something changed which boss a token names: repaint now (next rendered frame),
-- then the identity re-check after the settle. `f` = one slot, nil = every slot.
function B:Settle(f)
    local list = f and { f } or B.frames
    for _, s in ipairs(list) do
        if s:IsVisible() then UF.Units:QueueFullRefresh(s) end
    end
    if B.settleQueued then return end
    B.settleQueued = true
    C_Timer.After(B.SETTLE, function()
        B.settleQueued = nil
        B:CheckAll()
    end)
end

function B:OnEvent(event)
    if event == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" then
        B:Settle(nil)
    end
end

-- ============================================================
-- PREVIEW (spec §1.8): N sample bosses in a non-secure copy of the container.
-- N = Preview Frames (clamped to the slot count). The "Show Placeholder Frames
-- in Test Mode" tick (also the Boss switch on the units test panel) only gates
-- the units test mode: a mover session always shows them, or there is nothing
-- to drag.
-- ============================================================
function B:PreviewCount(db)
    db = db or UF:GetUnitDB("boss")
    return floor(Clamp(db.bossPreviewNum, 1, UF.BOSS_COUNT, UF.BOSS_COUNT))
end

function B:PreviewWanted()
    local P = UF.Preview
    if not (P and P.shown) then return false end
    if not B.container then return false end      -- source is not ours
    if P:IsOwnedBy("unlock") then return true end
    return UF:GetUnitDB("boss").bossPreviewCount ~= false
end

function B:PreviewContainer()
    if B.previewContainer then return B.previewContainer end
    local P = UF.Preview
    local c = CreateFrame("Frame", ContainerName() .. "Preview", P:GetParent())
    B.previewContainer = c
    return c
end

function B:AcquirePreview(i)
    local f = B.preview[i]
    if f then return f end
    local P = UF.Preview
    f = P:Build("boss", UF.Units.FRAME_NAMES.boss .. i .. "Preview", B:PreviewContainer(), i)
    -- One sample boss is mid-cast; the rest sit idle (CastBar.lua Preview).
    f.dfUFPreviewIdle = (i ~= 1)
    B.preview[i] = f
    return f
end

function B:PreviewApplyPosition()
    local c = B.previewContainer
    if c then UF.Units:PlaceAt(c, UF:GetPositionRecord("boss")) end
end

function B:PreviewRefresh()
    local P = UF.Preview
    if not B:PreviewWanted() then
        B:PreviewHide()
        return
    end
    local c = B:PreviewContainer()
    local n = B:PreviewCount()
    for i = 1, UF.BOSS_COUNT do
        if i <= n then B:AcquirePreview(i) end
    end
    B:LayoutContainer(c, B.preview)
    B:PreviewApplyPosition()
    c:Show()
    for i, f in pairs(B.preview) do
        if i <= n then
            if not f:IsShown() then f:Show() end
            P:Paint(f)
        else
            f:Hide()
        end
    end
    B.previewShown = true
end

function B:PreviewHide()
    for _, f in pairs(B.preview) do f:Hide() end
    if B.previewContainer then B.previewContainer:Hide() end
    B.previewShown = false
end

-- ============================================================
-- MOVER (spec §1.5)
-- Element "boss": the container. Its rect is the union of the slots on screen
-- (the preview's while it is up), the DF partyRect pattern; visibleOffset tells
-- the lib where that union sits relative to the record, so a drop puts the
-- frames -- not the empty slots -- where they were dropped. Not pointLocked:
-- DandersFrames' party container leaves the point to the user too.
-- Anchor targets boss.slot1..N: one per slot, partOf the element, no snap zones.
-- ============================================================

-- The container and slots that stand for the element right now.
function B:Active()
    if B.previewShown and B.previewContainer then return B.previewContainer, B.preview end
    return B.container, B.frames
end

-- Which slots are on screen right now (a set of indexes).
function B:VisibleSlots()
    local c, slots = B:Active()
    local set, any = {}, false
    if not c then return set, false end
    for i, f in pairs(slots) do
        if f:IsVisible() then set[i] = true; any = true end
    end
    return set, any
end

local function FrameRect(f)
    if not (f and f:IsVisible()) then return nil end
    local cx, cy = f:GetCenter()
    if not cx then return nil end
    local w, h = f:GetSize()
    if not w or w <= 0 or h <= 0 then return nil end
    local ratio = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local ux, uy = UIParent:GetCenter()
    return cx * ratio - ux, cy * ratio - uy, w * ratio, h * ratio
end
B.FrameRect = FrameRect

-- Union of the shown slots, UIParent units from UIParent's centre; nil when none.
function B:Rect()
    local _, slots = B:Active()
    local l, r, b, t
    for _, f in pairs(slots or {}) do
        local cx, cy, w, h = FrameRect(f)
        if cx then
            local cl, cr, cb, ct = cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2
            if l then
                l, r, b, t = min(l, cl), max(r, cr), min(b, cb), max(t, ct)
            else
                l, r, b, t = cl, cr, cb, ct
            end
        end
    end
    if not l then return nil end
    return { x = (l + r) / 2, y = (b + t) / 2, w = r - l, h = t - b }
end

function B:SlotFrame(i)
    local _, slots = B:Active()
    return slots and slots[i] or nil
end

function B:SlotTargetRect(i)
    local cx, cy, w, h = FrameRect(B:SlotFrame(i))
    if not cx then return nil end
    return { x = cx, y = cy, w = w, h = h }
end

-- The container's size in UIParent units.
function B:ContainerSize()
    local c = B:Active()
    local p = B:Params()
    local W, H = B:BoxSize(UF.BOSS_COUNT, p)
    local ratio = 1
    if c and UIParent then ratio = c:GetEffectiveScale() / UIParent:GetEffectiveScale() end
    if not ratio or ratio == 0 then ratio = 1 end
    return W * ratio, H * ratio, ratio
end

-- pos -> dx, dy: the shown slots' union centre relative to (pos.x, pos.y), in
-- UIParent units. Computed from the layout, never measured (a measured rect is
-- the OLD position mid-solve). nil when no slot is shown (the lib's plain write).
function B:VisibleOffset(pos, visible)
    if type(pos) ~= "table" then return nil end
    visible = visible or B:VisibleSlots()
    local p = B:Params()
    local W, H, ratio = B:ContainerSize()
    local px, py = Sides(pos.point)
    -- The container's centre, from the record's point.
    local ccx, ccy = -px * W / 2, -py * H / 2
    local l, r, b, t
    for i in pairs(visible) do
        local sl, sr, sb, st = B:SlotRect(i, p)
        sl, sr, sb, st = sl * ratio, sr * ratio, sb * ratio, st * ratio
        if l then
            l, r, b, t = min(l, sl), max(r, sr), min(b, sb), max(t, st)
        else
            l, r, b, t = sl, sr, sb, st
        end
    end
    if not l then return nil end
    return ccx + (l + r) / 2, ccy + (b + t) / 2
end

function B:MoverDef()
    local L = DF.L or {}
    local defaults = UF.UnitDefaults and UF.UnitDefaults.boss
    return {
        title     = L["Boss"] or "Boss",
        group     = L["Boss"] or "Boss",
        getFrame  = function() return (B:Active()) end,
        getRect   = function() return B:Rect() end,
        visibleOffset = function(pos) return B:VisibleOffset(pos) end,
        getPos    = function() return UF:GetPositionRecord("boss") end,
        onChanged = function()
            UF:RunOutOfCombat("position:boss", function() B:ApplyPosition() end)
            -- The preview container is not secure: it follows at once, in combat too.
            B:PreviewApplyPosition()
        end,
        default   = defaults and defaults.position and DF:DeepCopy(defaults.position) or nil,
        secure    = true,
        getSize   = function()
            local w, h = B:ContainerSize()
            return w, h
        end,
    }
end

function B:SlotTargetDef(i, elementId)
    local L = DF.L or {}
    return {
        title     = string.format(L["Boss %d"] or "Boss %d", i),
        group     = L["Boss"] or "Boss",
        getFrame  = function() return B:SlotFrame(i) end,
        getRect   = function() return B:SlotTargetRect(i) end,
        partOf    = elementId,
        snappable = false,
    }
end

-- Register the element and its slot targets with the lib. Called from Mover:Init.
function B:RegisterMover(Lib, addonKey)
    if not (Lib and B.container) then return false end
    Lib:Register(addonKey, "boss", B:MoverDef())
    if Lib.RegisterAnchorTarget then
        for i = 1, UF.BOSS_COUNT do
            Lib:RegisterAnchorTarget(addonKey, "boss.slot" .. i, B:SlotTargetDef(i, addonKey .. ":boss"))
        end
    end
    return true
end

-- ============================================================
-- UNITLESS EVENTS
-- ============================================================
if CreateFrame then
    local driver = CreateFrame("Frame")
    pcall(driver.RegisterEvent, driver, "INSTANCE_ENCOUNTER_ENGAGE_UNIT")
    driver:SetScript("OnEvent", function(_, event) B:OnEvent(event) end)
    B.driver = driver
end
