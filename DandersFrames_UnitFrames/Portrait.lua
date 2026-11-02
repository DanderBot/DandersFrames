local addonName, UF = ...

-- ============================================================
-- PORTRAIT (spec §3.4)
-- A portrait beside the frame (Left / Right) or over it (Inside Left / Inside
-- Right). Styles: a 3D model (PlayerModel), Blizzard's 2D portrait
-- (SetPortraitTexture), the class icon, or the spec icon (the player's own; other
-- units fall back to their class icon). "For NPCs Use" picks 3D or 2D for units
-- without a class (Class / Spec Icon have nothing to show for an NPC).
-- Structure ported from DandersUF's Frames/Portrait.lua (the author's own).
--
-- ☠ SECRET VALUES. A unit's class token can be secret: it is checked with
-- issecretvalue and an unreadable class shows the NPC style instead. The dead
-- check (Desaturate When Dead) only desaturates when the answer is readable.
--
-- SHAPES (portraitShape): Square, Circle or Rounded Corners. The two shaped ones
-- mask the background and the picture with one of Blizzard's own mask textures
-- (PO.MASKS) and draw the border as a disc of the same mask, one border wider,
-- behind them, so it follows the shape. ⚠ A 3D model cannot be masked (only
-- textures take a mask), so a shaped 3D portrait fits the model INSIDE the shape
-- instead (PO.MODEL_INSET: the square inscribed in the circle; a little in from
-- rounded corners) over the shaped background. ⚠ The border disc sits behind the
-- background, so a see-through background shows a little of the border colour.
-- ============================================================

local DF = DandersFrames
if not DF then return end

local ipairs, type, pcall, select, tonumber = ipairs, type, pcall, select, tonumber

local PO = { NAME = "Portrait" }
UF.Portrait = PO

local E = UF.Elements
local K = E and E.Kit
if not (E and K) then return end
local IsSecret = K.IsSecret

PO.UNITS = { player = true, target = true, focus = true, pet = true, boss = true }
PO.EVENTS = { "UNIT_PORTRAIT_UPDATE", "UNIT_MODEL_CHANGED" }
PO.MODES = { ["3D"] = true, ["2D"] = true, CLASS = true, SPEC = true }
PO.QUESTION_MODEL = "interface/buttons/talktomequestionmark.m2"
PO.QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- portraitShape -> the mask texture (Square: none). Both are Blizzard's own art:
-- the round mask every Blizzard unit-frame portrait uses, and the rounded-square
-- mask of its item buttons.
PO.MASKS = {
    CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask",
    ROUNDED = "Interface\\Common\\common-iconmask",
}
-- How far in the 3D model sits on each side, as a share of the portrait's size:
-- the square inscribed in the circle ((1 - 1/sqrt 2) / 2), and clear of the
-- rounded corners.
PO.MODEL_INSET = { CIRCLE = (1 - 1 / math.sqrt(2)) / 2, ROUNDED = 0.06 }

-- Class icon fallback when there is no class atlas (texcoords into the old sheet).
PO.CLASS_SHEET = "Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES"
PO.CLASS_TCOORDS = {
    WARRIOR = { 0, 0.25, 0, 0.25 }, MAGE = { 0.25, 0.5, 0, 0.25 }, ROGUE = { 0.5, 0.75, 0, 0.25 },
    DRUID = { 0.75, 1, 0, 0.25 }, HUNTER = { 0, 0.25, 0.25, 0.5 }, SHAMAN = { 0.25, 0.5, 0.25, 0.5 },
    PRIEST = { 0.5, 0.75, 0.25, 0.5 }, WARLOCK = { 0.75, 1, 0.25, 0.5 }, PALADIN = { 0, 0.25, 0.5, 0.75 },
    DEATHKNIGHT = { 0.25, 0.5, 0.5, 0.75 }, MONK = { 0.5, 0.75, 0.5, 0.75 },
    DEMONHUNTER = { 0.75, 1, 0.5, 0.75 }, EVOKER = { 0, 0.25, 0.75, 1 },
}

local function Enabled(db) return db and db.portraitEnabled and true or false end

function PO:Attach(f)
    if not f or f.dfUFPortrait or not PO.UNITS[f.dfUFUnit] then return end
    local p = CreateFrame("Frame", nil, f)
    p:Hide()
    p.owner = f
    -- Element range fade pins the frame at full alpha, so the portrait fades itself.
    f.dfOnElementAppearance = function(owner)
        PO:ApplyAlpha(owner, owner.dfIsHovered or rawget(owner, "_tdForceHover"))
    end
    p.bg = p:CreateTexture(nil, "BACKGROUND")
    p.bg:SetAllPoints(p)
    p.bg:SetTexture(K.WHITE)
    p.tex = p:CreateTexture(nil, "ARTWORK")
    p.tex:SetAllPoints(p)
    f.dfUFPortrait = p
    if not f.dfUFPreview then
        local l = CreateFrame("Frame")
        l:SetScript("OnEvent", function(_, event, unit)
            if unit == f.unit and f:IsVisible() then PO:Update(f) end
        end)
        p.listener = l
    end
    return p
end

-- The model is made on first use: most styles never need one.
function PO:Model(p)
    if p.model then return p.model end
    local m = CreateFrame("PlayerModel", nil, p)
    m:SetFrameLevel(p:GetFrameLevel() + 1)
    p.model = m
    PO:PlaceModel(p)
    return m
end

-- The model over the whole portrait, or inside its shape (p.dfModelInset, px).
function PO:PlaceModel(p)
    local m = p and p.model
    if not m then return end
    local inset = p.dfModelInset or 0
    m:ClearAllPoints()
    if inset > 0 then
        m:SetPoint("TOPLEFT", p, "TOPLEFT", inset, -inset)
        m:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -inset, inset)
    else
        m:SetAllPoints(p)
    end
end

-- The stored shape, or SQUARE.
function PO.Shape(db)
    local s = db and db.portraitShape
    if s and PO.MASKS[s] then return s end
    return "SQUARE"
end

-- Shape the portrait: mask the background and the picture, draw the border as a
-- disc of the same mask (Square: the plain border), fit the model inside.
function PO:ApplyShape(p, db, size)
    local path = PO.MASKS[PO.Shape(db)]
    local borderOn = db.portraitBorderEnabled ~= false
    if path and not p.mask and p.CreateMaskTexture then
        p.mask = p:CreateMaskTexture()
        if p.mask then p.mask:SetAllPoints(p) end
    end
    if not (path and p.mask) then
        -- Square (or a client without masks): unmasked, the plain border.
        if p.masked then
            p.bg:RemoveMaskTexture(p.mask)
            p.tex:RemoveMaskTexture(p.mask)
            p.masked = false
        end
        if p.ring then p.ring:Hide() end
        K.Border(p, borderOn, db.portraitBorderSize, db.portraitBorderColor)
        p.dfModelInset = 0
        PO:PlaceModel(p)
        return
    end
    p.mask:SetTexture(path, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    if not p.masked then
        p.bg:AddMaskTexture(p.mask)
        p.tex:AddMaskTexture(p.mask)
        p.masked = true
    end
    K.Border(p, false, db.portraitBorderSize, db.portraitBorderColor)
    if borderOn then
        if not p.ring then
            p.ring = p:CreateTexture(nil, "BACKGROUND", nil, -8)
            p.ring:SetTexture(K.WHITE)
            p.ringMask = p:CreateMaskTexture()
            p.ringMask:SetAllPoints(p.ring)
            p.ring:AddMaskTexture(p.ringMask)
        end
        local b = tonumber(db.portraitBorderSize) or 1
        if b < 1 then b = 1 end    -- as K.Border: at least 1px
        p.ring:ClearAllPoints()
        p.ring:SetPoint("TOPLEFT", p, "TOPLEFT", -b, b)
        p.ring:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", b, -b)
        p.ringMask:SetTexture(path, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        p.ring:SetVertexColor(K.RGBA(db.portraitBorderColor, 0, 0, 0, 1))
        p.ring:Show()
    elseif p.ring then
        p.ring:Hide()
    end
    p.dfModelInset = math.floor((tonumber(size) or 0) * (PO.MODEL_INSET[PO.Shape(db)] or 0) + 0.5)
    PO:PlaceModel(p)
end

-- The portrait's own size (border excluded) and its border width. Size is set
-- RELATIVE to the frame's height: 0 = the portrait, border included, exactly as
-- tall as the frame; -10 = 10 smaller, 20 = 20 bigger. K.Border draws OUTSIDE
-- the portrait, so the border comes off the size, never on top of it.
function PO.Size(f, db)
    local border = 0
    if db.portraitBorderEnabled ~= false then
        border = tonumber(db.portraitBorderSize) or 1
        if border < 1 then border = 1 end    -- K.Border draws at least 1px
    end
    local size = K.FrameHeight(f, db) + (tonumber(db.portraitSize) or 0) - 2 * border
    if size < 4 then size = 4 end
    return size, border
end

-- RING style (Rings.lua): the portrait sits in the middle of the rings, round (the
-- frame view answers portraitShape), as big as the hole inside the innermost ring
-- with its border inside that too. Side, size and offsets do not apply.
function PO.RingSize(db)
    local R = UF.Rings
    if not (R and R.IsRing(db)) then return nil end
    local border = 0
    if db.portraitBorderEnabled ~= false then
        border = tonumber(db.portraitBorderSize) or 1
        if border < 1 then border = 1 end
    end
    local size = R.Geometry(db).hole - 2 * border
    if size < 4 then size = 4 end
    return size, border
end

function PO:Layout(f)
    local p = f and f.dfUFPortrait
    if not p then return end
    local db = K.DB(f)
    if not Enabled(db) then p:Hide(); return end
    local ringSize = PO.RingSize(db)
    local size = ringSize or PO.Size(f, db)
    p:SetSize(size, size)
    p:ClearAllPoints()
    local x, y = tonumber(db.portraitX) or 0, tonumber(db.portraitY) or 0
    local side = db.portraitSide or "LEFT"
    if ringSize then
        p:SetPoint("CENTER", f, "CENTER", 0, 0)
    elseif side == "RIGHT" then
        p:SetPoint("LEFT", f, "RIGHT", 2 + x, y)
    elseif side == "INSIDE_LEFT" then
        p:SetPoint("LEFT", f, "LEFT", x, y)
    elseif side == "INSIDE_RIGHT" then
        p:SetPoint("RIGHT", f, "RIGHT", x, y)
    else
        p:SetPoint("RIGHT", f, "LEFT", -2 + x, y)
    end
    -- Inside the frame it sits over the bars and under the text; in a ring, under
    -- the rings (Rings.lua R.LEVEL_PORTRAIT).
    if ringSize then
        p:SetFrameLevel(f:GetFrameLevel() + (UF.Rings.LEVEL_PORTRAIT or 2))
    else
        p:SetFrameLevel(f:GetFrameLevel() + ((side == "INSIDE_LEFT" or side == "INSIDE_RIGHT") and 4 or 1))
    end
    -- Hovered right now (or the designer's Show Hover State): dimmed.
    PO:ApplyAlpha(f, f.dfIsHovered or rawget(f, "_tdForceHover"))
    p.bg:SetVertexColor(K.RGBA(db.portraitBgColor, 0, 0, 0, 0.8))
    PO:ApplyShape(p, db, size)
    -- RING 3D: COVER fills the circle's square (no inset) and covers the corners
    -- when a model draws (PO:Paint); FIT keeps the shape's inset.
    p.dfRingCover = (PO.Ring3DMode(db) == "COVER") or nil
    if p.dfRingCover then
        p.dfModelInset = 0
        PO:PlaceModel(p)
    end
    if not f.dfUFPreview then PO:Update(f) end
end

-- How far a portrait OUTSIDE the frame (side Left / Right) reaches past the frame's
-- left and right edges, border included, in the frame's units: left, right. Inside
-- portraits and a portrait that is off reach nothing. From the settings, the same
-- numbers Layout places it by -- read by the frame's outer rect (Mover.lua).
function PO.OutsideExtent(f, db)
    db = db or K.DB(f)
    if not Enabled(db) or PO.RingSize(db) then return 0, 0 end
    local side = db.portraitSide or "LEFT"
    if side ~= "LEFT" and side ~= "RIGHT" then return 0, 0 end
    local size, border = PO.Size(f, db)
    local x = tonumber(db.portraitX) or 0
    if side == "RIGHT" then
        local r = 2 + x + size + border
        return 0, (r > 0) and r or 0
    end
    local l = 2 - x + size + border
    return (l > 0) and l or 0, 0
end

-- An outside portrait's own rect, border included, in the frame's units from
-- its TOPLEFT (x right, y DOWN; the frame itself = 0, 0, width, height): left,
-- top, right, bottom. nil without an outside portrait (off, inside, or moved
-- back over the frame). Read by the resting glow (Indicators.lua) to trace the
-- frame and its portrait as one outline.
function PO.OutsideRect(f, db)
    db = db or K.DB(f)
    local left, right = PO.OutsideExtent(f, db)
    if left == 0 and right == 0 then return nil end
    local fw, fh = K.FrameWidth(f, db), K.FrameHeight(f, db)
    local size, border = PO.Size(f, db)
    local x, y = tonumber(db.portraitX) or 0, tonumber(db.portraitY) or 0
    local cy = fh / 2 - y
    local half = size / 2 + border
    local l
    if (db.portraitSide or "LEFT") == "RIGHT" then
        l = fw + 2 + x - border
    else
        l = -2 + x - size - border
    end
    return l, cy - half, l + size + 2 * border, cy + half
end

-- The unit's class token, or nil (an NPC, or a secret answer).
local function UnitClassToken(unit)
    if not (UnitIsPlayer and UnitClass) then return nil end
    local isPlayer = UnitIsPlayer(unit)
    if IsSecret(isPlayer) or not isPlayer then return nil end
    local class = select(2, UnitClass(unit))
    if type(class) ~= "string" or IsSecret(class) then return nil end
    return class
end

function PO:SetClassIcon(p, class, mirror)
    local atlas = GetClassAtlas and GetClassAtlas(class)
    if atlas then
        p.tex:SetAtlas(atlas)
        if mirror then p.tex:SetTexCoord(1, 0, 0, 1) else p.tex:SetTexCoord(0, 1, 0, 1) end
        return
    end
    p.tex:SetTexture(PO.CLASS_SHEET)
    local c = PO.CLASS_TCOORDS[class]
    if c then
        if mirror then p.tex:SetTexCoord(c[2], c[1], c[3], c[4]) else p.tex:SetTexCoord(c[1], c[2], c[3], c[4]) end
    end
end

function PO:PlayerSpecIcon()
    if not (GetSpecialization and GetSpecializationInfo) then return nil end
    local idx = GetSpecialization()
    if not idx or IsSecret(idx) then return nil end
    local icon = select(4, GetSpecializationInfo(idx))
    if IsSecret(icon) then return nil end
    return icon
end

-- What to draw for `unit` with these settings: "3D" | "2D" | "CLASS" | "SPEC".
-- ============================================================
-- RING 3D (ringPortrait3D, Rings.lua A 3D PORTRAIT IN THE MIDDLE). A model cannot
-- take a mask, so a 3D portrait in a ring is one of:
--   FIT    the model as the square inside the circle (MODEL_INSET, as the shapes
--          do on a Bars frame) over the round background
--   COVER  the model filling the circle's square, with a CORNER COVER over it: a
--          texture in the background colour cut by Media/RingInnerMask (opaque
--          outside the disc, clear inside) at the circle's size, hiding the four
--          corners. The portrait sits under the rings (R.LEVEL_*), and COVER needs
--          ring 1's Gap at 0, so the ring hides what is left of the corners.
--   2D     drawn as Blizzard's 2D portrait (StyleFor), cut round
-- ============================================================
function PO.Ring3DMode(db)
    local R = UF.Rings
    if not (R and R.IsRing(db)) then return nil end
    return R.Portrait3D(db)
end

function PO:ShowCover(p, on, db)
    if not on then
        if p.cover then p.cover:Hide() end
        return
    end
    if not p.cover then
        local c = CreateFrame("Frame", nil, p)
        c:SetAllPoints(p)
        c.tex = c:CreateTexture(nil, "ARTWORK")
        c.tex:SetAllPoints(c)
        c.tex:SetTexture(K.WHITE)
        c.mask = c:CreateMaskTexture()
        c.mask:SetTexture(UF.Rings.HOLE, "CLAMPTOWHITE", "CLAMPTOWHITE")
        c.mask:SetAllPoints(c)
        c.tex:AddMaskTexture(c.mask)
        p.cover = c
    end
    local r, g, b = K.RGBA(db.portraitBgColor, 0, 0, 0, 1)
    p.cover.tex:SetVertexColor(r, g, b, 1)
    -- Over the model (a child of the portrait, a level above it).
    p.cover:SetFrameLevel(p:GetFrameLevel() + 2)
    p.cover:Show()
end

function PO:StyleFor(db, unit, class)
    local mode = PO.MODES[db.portraitMode] and db.portraitMode or "3D"
    if (mode == "CLASS" or mode == "SPEC") and not class then
        mode = (db.portraitNpcMode == "2D") and "2D" or "3D"
    elseif mode == "SPEC" and unit ~= "player" then
        mode = "CLASS"
    end
    if mode == "3D" and PO.Ring3DMode(db) == "2D" then return "2D" end
    return mode
end

function PO:Update(f)
    local p = f and f.dfUFPortrait
    if not p or f.dfUFPreview then return end
    local db = K.DB(f)
    local unit = f.unit
    if not Enabled(db) or not unit or not (UnitExists and UnitExists(unit)) then
        p:Hide()
        return
    end
    local class = UnitClassToken(unit)
    local style = PO:StyleFor(db, unit, class)
    PO:Paint(p, db, style, unit, class)
    PO:UpdateDead(f)
    p:Show()
end

-- Desaturate When Dead (the 2D styles), only on a readable answer.
function PO:UpdateDead(f)
    local p = f and f.dfUFPortrait
    if not p or not p.tex.SetDesaturated then return end
    local db = K.DB(f)
    local dead = false
    if db and db.portraitDesatDead ~= false and UnitIsDeadOrGhost and f.unit then
        local d = UnitIsDeadOrGhost(f.unit)
        if not IsSecret(d) and d then dead = true end
    end
    p.tex:SetDesaturated(dead)
end

function PO:Paint(p, db, style, unit, class)
    local mirror = db.portraitMirror and true or false
    PO:ShowCover(p, style == "3D" and p.dfRingCover, db)
    if style == "3D" then
        p.tex:Hide()
        local m = PO:Model(p)
        m:Show()
        local visible = UnitIsVisible and UnitIsVisible(unit)
        if IsSecret(visible) then visible = true end
        pcall(m.ClearModel, m)
        if unit and visible then
            pcall(m.SetUnit, m, unit)
            pcall(m.SetPortraitZoom, m, tonumber(db.portrait3DZoom) or 1)
            local rot = math.rad(tonumber(db.portrait3DRotation) or 0)
            if mirror then rot = -rot end
            pcall(m.SetFacing, m, rot)
        else
            pcall(m.SetModel, m, PO.QUESTION_MODEL)
        end
        return
    end
    if p.model then p.model:Hide() end
    p.tex:Show()
    if style == "2D" then
        if unit and SetPortraitTexture then SetPortraitTexture(p.tex, unit) end
        if mirror then p.tex:SetTexCoord(0.92, 0.08, 0.08, 0.92) else p.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
    elseif style == "SPEC" then
        local icon = PO:PlayerSpecIcon()
        if icon then
            p.tex:SetTexture(icon)
            if mirror then p.tex:SetTexCoord(0.92, 0.08, 0.08, 0.92) else p.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
        elseif class then
            PO:SetClassIcon(p, class, mirror)
        end
    elseif style == "CLASS" then
        PO:SetClassIcon(p, class, mirror)
    end
end

-- ============================================================
-- EVENTS (only while the frame is shown and the portrait is on)
-- ============================================================
function PO:SetActive(f, on)
    local p = f and f.dfUFPortrait
    if not p or not p.listener then return end
    on = on and Enabled(K.DB(f)) or false
    if p.eventsOn == on then
        if not on then p:Hide() end
        return
    end
    p.eventsOn = on
    local unit = f.dfUFUnit
    local pair = (unit == "player") and { "player", "vehicle" } or (unit == "pet") and { "pet", "player" } or nil
    for _, ev in ipairs(PO.EVENTS) do
        if on then
            if pair then pcall(p.listener.RegisterUnitEvent, p.listener, ev, pair[1], pair[2])
            else pcall(p.listener.RegisterUnitEvent, p.listener, ev, f.unit or unit) end   -- the frame's own token (boss3)
        else
            pcall(p.listener.UnregisterEvent, p.listener, ev)
        end
    end
    if not on then p:Hide() end
end

function PO:Refresh(f)
    local p = f and f.dfUFPortrait
    if not p or f.dfUFPreview then return end
    local want = Enabled(K.DB(f)) and f:IsVisible() or false
    if (p.eventsOn or false) ~= want then PO:SetActive(f, want) end
    if want then PO:Update(f) else p:Hide() end
end

function PO:OnUnitChanged(f) PO:Update(f) end

-- ============================================================
-- DIM ON HOVER (portraitDimHover): the portrait fades to PO.DIM of its alpha while
-- the frame is hovered (UF.OnHover), so text shown on hover over it reads. Frame
-- alpha only: the portrait is a plain frame, safe in combat.
-- ============================================================
PO.DIM = 0.35

-- The portrait's one alpha write: its own alpha, the hover dim, then the element
-- range fade (oorEnabled; in frame mode the frame's alpha cascades over it instead).
-- dfInRange can be secret: it is never compared, only handed to the engine.
function PO:ApplyAlpha(f, hovered)
    local p = f and f.dfUFPortrait
    if not p then return end
    local db = K.DB(f)
    local base = tonumber(db and db.portraitAlpha) or 1
    if hovered and db and db.portraitDimHover then base = base * PO.DIM end
    if not (db and db.oorEnabled) then
        p:SetAlpha(base)
        return
    end
    local oor = base * (tonumber(db.oorPortraitAlpha) or 0.2)
    local inRange = f.dfInRange
    if issecretvalue and issecretvalue(inRange) then
        if p.SetAlphaFromBoolean then p:SetAlphaFromBoolean(inRange, base, oor) else p:SetAlpha(base) end
    elseif inRange == false then
        p:SetAlpha(oor)
    else
        p:SetAlpha(base)
    end
end

function PO:SetHover(f, on)
    PO:ApplyAlpha(f, on)
end

-- Dead / alive changes the desaturation only (a model repaint per health tick
-- would flicker).
function PO:OnUnitEvent(f, event)
    if event == "UNIT_HEALTH" or event == "UNIT_FLAGS" or event == "UNIT_CONNECTION" then
        local p = f.dfUFPortrait
        if p and p:IsShown() then PO:UpdateDead(f) end
    end
end

-- ============================================================
-- PREVIEW: the player's own portrait on the player preview, a question mark on
-- the others (their sample units do not exist).
-- ============================================================
function PO:Preview(f)
    local p = f and f.dfUFPortrait
    if not p then return end
    local db = K.DB(f)
    PO:Layout(f)
    if not Enabled(db) then p:Hide(); return end
    if f.dfUFUnit == "player" then
        local class = UnitClassToken("player")
        PO:Paint(p, db, PO:StyleFor(db, "player", class), "player", class)
    else
        if p.model then p.model:Hide() end
        PO:ShowCover(p, false)
        p.tex:Show()
        p.tex:SetTexture(PO.QUESTION_ICON)
        p.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    p:Show()
end

E:Register(PO)
