local addonName, UF = ...

-- ============================================================
-- UNIT ICONS (spec §3.3 "Icons: a new Unit group", §4 "Level / classification /
-- PvP / resting")
-- What DandersFrames' own status icons do not cover, as three small icons:
--   Resting       the player, while resting: DandersFrames' own animated
--                 ZZZ (DF:CreateRestedIndicator), optionally still, with an
--                 optional soft glow OUTSIDE the frame's edges (the builder's
--                 OUTER style) tracing the outline of the frame, an attached
--                 class power bar and, with Include Portrait, a portrait beside
--                 it (IN.GlowRects; Portrait.lua PO.OutsideRect)
--   PvP           the player / target / focus while PvP flagged (faction crest,
--                 or the free-for-all flag)
--   Elite / Rare  target / focus / boss: an elite or rare dragon, or the word
--                 ("+", Rare, Rare Elite, Boss) from the Text Designer's own
--                 Classification resolver (the D12 token), so the text matches
--                 a Classification text element exactly
-- Plus three decorations (CLASSIFICATION DRAGON / CLASSIFICATION BORDER / COMBAT
-- ICON BORDER below): a dragon gripping the frame's end on elite / rare / boss
-- units, a border coloured by classification, and a border round DF's combat icon.
-- Everything else on the list rides DandersFrames as-is: leader and raid
-- target icons (Icons page cards), the combat icon (DF:UpdateCombatIcon, kicked
-- here on the combat edges and UNIT_FLAGS, which DF's own group dispatcher never
-- sends to these frames), level and classification as text (Text Designer).
-- Ported from DandersUF's Frames/Indicators.lua logic.
--
-- ☠ SECRET VALUES: every answer (classification, PvP flag, faction) is checked
-- with issecretvalue; a secret answer hides the icon rather than guessing.
-- ⚠ UNVERIFIED IN GAME: the icon art (texture paths / atlas names below).
-- ============================================================

local DF = DandersFrames
if not DF then return end

local pairs, ipairs, type, pcall, tonumber = pairs, ipairs, type, pcall, tonumber

local IN = { NAME = "Indicators" }
UF.Indicators = IN

local E = UF.Elements
local K = E and E.Kit
if not (E and K) then return end
local IsSecret = K.IsSecret

-- Which units get which icon (the inventory's per-unit cards).
IN.ICONS = {
    resting = { player = true },
    pvp = { player = true, target = true, focus = true },
    classification = { target = true, focus = true, boss = true },
}
-- db key prefix per icon.
IN.PREFIX = { resting = "restingIcon", pvp = "pvpIcon", classification = "classification" }
-- restingIconSize that draws the ZZZ at the party player frame's scale.
IN.RESTING_BASE_SIZE = 16

IN.ART = {
    pvp = {
        Horde = { atlas = "UI-HUD-UnitFrame-Player-PVP-HordeIcon", file = "Interface\\TargetingFrame\\UI-PVP-Horde", coords = { 0.08, 0.58, 0.045, 0.545 } },
        Alliance = { atlas = "UI-HUD-UnitFrame-Player-PVP-AllianceIcon", file = "Interface\\TargetingFrame\\UI-PVP-Alliance", coords = { 0.07, 0.58, 0.06, 0.57 } },
        FFA = { atlas = "UI-HUD-UnitFrame-Player-PVP-FFAIcon", file = "Interface\\TargetingFrame\\UI-PVP-FFA", coords = { 0.05, 0.605, 0.015, 0.57 } },
    },
    elite = "nameplates-icon-elite-gold",
    rare = "nameplates-icon-elite-silver",
}

local function NewIcon(host)
    local icon = CreateFrame("Frame", nil, host)
    icon:SetSize(16, 16)
    icon.tex = icon:CreateTexture(nil, "OVERLAY")
    icon.tex:SetAllPoints(icon)
    icon.text = icon:CreateFontString(nil, "OVERLAY")
    icon.text:SetPoint("CENTER", icon, "CENTER", 0, 0)
    icon:Hide()
    return icon
end

function IN:Attach(f)
    if not f or f.dfUFIcons then return end
    local unit = f.dfUFUnit
    local any = false
    for _, units in pairs(IN.ICONS) do if units[unit] then any = true end end
    if not any then return end
    local host = CreateFrame("Frame", nil, f)
    host:SetAllPoints(f)
    local icons = { host = host }
    for key, units in pairs(IN.ICONS) do
        if units[unit] then
            if key == "resting" then
                local ind = DF:CreateRestedIndicator(host, f, { glowStyle = "OUTER" })
                icons[key] = ind
                -- The outline is laid out in the frame's units, so a frame
                -- resize (the Frame page's sliders mid-drag) re-traces it.
                -- The glow frame spans the unit button; it is not secure.
                if ind.glow and ind.SetGlowRects then
                    ind.glow:SetScript("OnSizeChanged", function()
                        local db = K.DB(f)
                        if db then ind:SetGlowRects(IN.GlowRects(f, db)) end
                    end)
                end
            else
                icons[key] = NewIcon(host)
            end
        end
    end
    if IN.ICONS.classification[unit] then
        icons.dragon = IN.NewDragon(f)
        icons.classBorder = IN.NewClassBorder(f)
    end
    f.dfUFIcons = icons
    return icons
end

function IN:Enabled(db, key)
    return db and db[IN.PREFIX[key] .. "Enabled"] and true or false
end

-- An attached class power bar's rect, border included, in the frame's units
-- from its TOPLEFT (x right, y DOWN): left, top, right, bottom. From the
-- settings ClassPower.lua's Layout places it by: matching the frame's width,
-- its outer edge (border included) IS the frame's width; a set width is that
-- plus the border each side. nil when off, detached, or on a unit without one.
function IN.ClassPowerRect(f, db)
    local CP = UF.ClassPower
    if not (db and db.classPowerEnabled and CP) or (CP.IsDetached and CP:IsDetached(f, db)) then
        return nil
    end
    if not (f and f.dfUFClassPower) then return nil end
    local fw, fh = K.FrameWidth(f, db), K.FrameHeight(f, db)
    local border = 0
    if db.classPowerBorderEnabled ~= false then
        border = tonumber(db.classPowerBorderSize) or 1
        if border < 1 then border = 1 end
    end
    local ow = fw
    if db.classPowerMatchWidth == false then ow = (tonumber(db.classPowerWidth) or 220) + 2 * border end
    local h = tonumber(db.classPowerHeight) or 6
    local x, y = tonumber(db.classPowerX) or 0, tonumber(db.classPowerY) or 0
    local l = (fw - ow) / 2 + x
    if db.classPowerPosition == "BOTTOM" then
        return l, fh + y - border, l + ow, fh + y + h + border
    end
    return l, -(y + h + border), l + ow, -(y - border)
end

-- How far an attached class power bar reaches past the frame's edges: left,
-- right, top, bottom (0 for an edge it stays inside). 0s without one.
function IN.ClassPowerBox(f, db)
    local l, t, r, b = IN.ClassPowerRect(f, db)
    if not l then return 0, 0, 0, 0 end
    local fw, fh = K.FrameWidth(f, db), K.FrameHeight(f, db)
    local function pos(v) return (v > 0) and v or 0 end
    return pos(-l), pos(r - fw), pos(-t), pos(b - fh)
end

-- The rects the resting glow traces the outline of: the frame, an attached
-- class power bar, and an outside portrait while Include Portrait is on. One
-- outline round their union (an L or a step), never an empty glowing corner.
function IN.GlowRects(f, db)
    local rects = { { 0, 0, K.FrameWidth(f, db), K.FrameHeight(f, db) } }
    local l, t, r, b = IN.ClassPowerRect(f, db)
    if l then rects[#rects + 1] = { l, t, r, b } end
    local PO = UF.Portrait
    if db and db.restingIconGlowPortrait ~= false and PO and PO.OutsideRect then
        l, t, r, b = PO.OutsideRect(f, db)
        if l then rects[#rects + 1] = { l, t, r, b } end
    end
    return rects
end

function IN:Layout(f)
    if not f then return end
    local db = K.DB(f)
    if not db then return end
    IN.PaintCombatBorder(f, db)
    local icons = f.dfUFIcons
    if not icons then return end
    icons.host:SetFrameLevel(f:GetFrameLevel() + 30)
    if icons.dragon then IN.LayoutDragon(f, icons.dragon, db) end
    if icons.classBorder then IN.LayoutClassBorder(f, icons.classBorder, db) end
    for key in pairs(IN.ICONS) do
        local icon = icons[key]
        if icon then
            local pre = IN.PREFIX[key]
            local size = tonumber(db[pre .. "Size"]) or 16
            if key == "resting" then
                -- The ZZZ group at size 16 = the party player frame's (8/11/14).
                icon:SetZScale(size / IN.RESTING_BASE_SIZE)
                icon:SetFrameLevel(icons.host:GetFrameLevel() + 5)
                icon:SetAnimated(db[pre .. "Animate"] ~= false)
                if icon.SetGlowRects then icon:SetGlowRects(IN.GlowRects(f, db)) end
            else
                icon:SetSize(size, size)
            end
            icon:ClearAllPoints()
            local point = K.Point(db[pre .. "Anchor"], "TOPRIGHT")
            icon:SetPoint(point, f, point, tonumber(db[pre .. "X"]) or 0, tonumber(db[pre .. "Y"]) or 0)
            if key == "classification" then
                K.Font(icon.text, db.statusIconFont, size, "OUTLINE", { r = 1, g = 0.82, b = 0 })
            end
        end
    end
    if not f.dfUFPreview then IN:Update(f) end
end

-- ---- the three answers -----------------------------------------------------

function IN:IsResting()
    if not IsResting then return false end
    local r = IsResting()
    return (not IsSecret(r)) and r and true or false
end

-- "FFA" / "Horde" / "Alliance" / nil.
function IN:PvPState(unit)
    if not unit then return nil end
    if UnitIsPVPFreeForAll then
        local ffa = UnitIsPVPFreeForAll(unit)
        if IsSecret(ffa) then return nil end
        if ffa then return "FFA" end
    end
    if not UnitIsPVP then return nil end
    local pvp = UnitIsPVP(unit)
    if IsSecret(pvp) or not pvp then return nil end
    local faction = UnitFactionGroup and UnitFactionGroup(unit)
    if IsSecret(faction) then return nil end
    if faction == "Horde" or faction == "Alliance" then return faction end
    return nil
end

-- The classification, or nil (ordinary, or secret).
function IN:Classification(unit)
    if not (unit and UnitClassification) then return nil end
    local c = UnitClassification(unit)
    if IsSecret(c) or type(c) ~= "string" then return nil end
    if c == "elite" or c == "worldboss" or c == "rare" or c == "rareelite" then return c end
    return nil
end

-- The Classification text, through the Text Designer's own resolver (the D12
-- token) so the two can never disagree.
function IN.ClassificationText(c)
    local TD = DF.TextDesigner
    local R = TD and TD.Resolver and TD.Resolver._RESOLVERS
    local fn = R and R.classification
    if fn then
        local ok, text = pcall(fn, nil, { GetClassification = function() return c end })
        if ok and type(text) == "string" then return text end
    end
    if c == "elite" then return "+" end
    return ""
end

-- ---- painting --------------------------------------------------------------

-- `icon` is the DF:CreateRestedIndicator frame; its glow rides with it.
function IN:PaintResting(icon, on, glow)
    local g = icon.glow
    if not on then
        icon:Hide()
        if g then g:Hide() end
        return
    end
    icon:Show()
    if g then
        if glow then g:Show() else g:Hide() end
    end
end

function IN:PaintPvP(icon, state)
    local a = state and IN.ART.pvp[state]
    if not a then icon:Hide(); return end
    icon.text:Hide()
    icon.tex:Show()
    -- The modern crest atlas when the client has it, else the legacy file's crop.
    local info = C_Texture and C_Texture.GetAtlasInfo
    if a.atlas and info and info(a.atlas) then
        icon.tex:SetTexCoord(0, 1, 0, 1)    -- SetAtlas keeps an earlier crop
        icon.tex:SetAtlas(a.atlas)
    else
        icon.tex:SetTexture(a.file)
        icon.tex:SetTexCoord(a.coords[1], a.coords[2], a.coords[3], a.coords[4])
    end
    icon:Show()
end

function IN:PaintClassification(icon, c, style)
    if not c then icon:Hide(); return end
    if style == "TEXT" then
        icon.tex:Hide()
        icon.text:SetText(IN.ClassificationText(c))
        icon.text:Show()
    else
        icon.text:Hide()
        local atlas = (c == "rare" or c == "rareelite") and IN.ART.rare or IN.ART.elite
        icon.tex:SetTexCoord(0, 1, 0, 1)
        icon.tex:SetAtlas(atlas)
        icon.tex:Show()
    end
    icon:Show()
end

function IN:Update(f)
    local icons = f and f.dfUFIcons
    if not icons or f.dfUFPreview then return end
    local db = K.DB(f)
    local unit = f.unit
    local exists = unit and UnitExists and UnitExists(unit)
    if IsSecret(exists) then exists = true end
    if icons.resting then
        IN:PaintResting(icons.resting, IN:Enabled(db, "resting") and IN:IsResting(),
            db and db.restingIconGlow)
    end
    if icons.pvp then
        IN:PaintPvP(icons.pvp, (IN:Enabled(db, "pvp") and exists) and IN:PvPState(unit) or nil)
    end
    if icons.classification then
        local c = (IN:Enabled(db, "classification") and exists) and IN:Classification(unit) or nil
        IN:PaintClassification(icons.classification, c, db and db.classificationStyle)
    end
    if icons.dragon or icons.classBorder then
        local c = exists and IN:Classification(unit) or nil
        IN.PaintDecorations(icons, db, c)
    end
end

function IN:Refresh(f)
    IN:Update(f)
    IN:UpdateCombat(f)
end

function IN:OnUnitChanged(f) IN:Update(f) end

-- The combat icon is DandersFrames' own; only the trigger is ours.
function IN:UpdateCombat(f)
    if f and not f.dfUFPreview and DF.UpdateCombatIcon then DF:UpdateCombatIcon(f) end
end

IN.UPDATE_ON = { UNIT_FACTION = true, UNIT_CLASSIFICATION_CHANGED = true, PLAYER_FLAGS_CHANGED = true }
IN.COMBAT_ON = { UNIT_FLAGS = true, PLAYER_REGEN_ENABLED = true, PLAYER_REGEN_DISABLED = true }

function IN:OnUnitEvent(f, event)
    if IN.UPDATE_ON[event] then IN:Update(f) end
    if IN.COMBAT_ON[event] then IN:UpdateCombat(f) end
end

-- ============================================================
-- PREVIEW: each icon that is switched on, with sample answers.
-- ============================================================
function IN:Preview(f)
    if not f then return end
    IN:Layout(f)
    local icons = f.dfUFIcons
    if not icons then return end
    local db = K.DB(f)
    if icons.resting then IN:PaintResting(icons.resting, IN:Enabled(db, "resting"), db and db.restingIconGlow) end
    if icons.pvp then
        local faction = UnitFactionGroup and UnitFactionGroup("player")
        if IsSecret(faction) or (faction ~= "Horde" and faction ~= "Alliance") then faction = "Alliance" end
        IN:PaintPvP(icons.pvp, IN:Enabled(db, "pvp") and faction or nil)
    end
    if icons.classification then
        -- The sample unit's own answer: the test panel's "Normal" is nil here and
        -- draws no icon (no sample data at all: the elite sample).
        local data = f.dfTestData
        local c = "elite"
        if data then c = data.classification end
        IN:PaintClassification(icons.classification, IN:Enabled(db, "classification") and c or nil,
            db and db.classificationStyle)
    end
    if icons.dragon or icons.classBorder then
        -- The sample unit's own answer: the test panel's "normal" is nil here and
        -- draws no dragon (no sample data at all: the elite sample).
        local data = f.dfTestData
        local c = "elite"
        if data then c = data.classification end
        IN.PaintDecorations(icons, db, c)
    end
end

-- ============================================================
-- CLASSIFICATION DRAGON
-- Two pieces of art (Media/EliteDragonTop / Bottom: 256x128 canvases, the art
-- in their TOP-LEFT corner, grey silver with alpha, tinted per classification
-- with SetVertexColor) gripping one END of the frame:
--   top     its bottom edge on the frame's TOP edge, its right edge (the wing
--           tip) on the frame's RIGHT edge; the head faces left, the claws
--           grip the top edge
--   bottom  its top edge on the frame's BOTTOM edge, its right edge
--           DRAGON.TAIL_INSET px INSIDE the frame's right edge (a tail hanging
--           past the frame's edge was rejected); the tail tip points left
-- The pieces never scale with the frame's height: the frame itself hides the
-- gap between them, so the dragon works on any frame height. Size 100% = the
-- art at 46/136.35 (the source's placeholder bar was 136.35 art-px tall for a
-- 46 px frame): the top piece ~66x21, the bottom ~59x14.
-- LEFT end: both pieces flipped by texcoord (the head then faces right, in
-- over the frame) and their anchors mirrored. BOTH draws the two ends; OUTER
-- (the default) the outside portrait's side, else the right end.
-- ANCHOR TO (classDragonAnchor): PORTRAIT (the default) grips an outside
-- portrait's rect, border included, exactly as it grips the frame -- so the
-- dragon never meets the auras or cast bars round the frame; FRAME, or no
-- outside portrait (off, or inside the frame), grips the frame.
-- Offsets are SCREEN x/y (positive = right / up), so a mirrored link (which
-- negates every ...X and swaps LEFT/RIGHT, Links.Mirror) lands the follower on
-- the exact mirror image. With BOTH the left end is the right end's mirror
-- image, so its x offsets are negated.
-- LAYERING: the pieces sit outside the frame's rect except the claws, which
-- overlap its top edge by ~1px. Their frame is one level above DandersFrames'
-- frame border (frame + 14, Frames/Create.lua) and the class border below, so
-- the claws are never cut by either; it stays below the power bar (+20), the
-- text / icon overlay (+25) and these unit icons (+30).
-- ============================================================
local MEDIA = "Interface\\AddOns\\DandersFrames_UnitFrames\\Media\\"
IN.DRAGON = {
    TOP = { file = MEDIA .. "EliteDragonTop", w = 197, h = 61 },
    BOTTOM = { file = MEDIA .. "EliteDragonBottom", w = 176, h = 41 },
    CANVAS_W = 256, CANVAS_H = 128,
    REF_SCALE = 46 / 136.35,
    TAIL_INSET = 2,
    MIN_SIZE = 50, MAX_SIZE = 200,
}
-- Frame levels over the unit button (DF's frame border is +14).
IN.CLASS_BORDER_LEVEL = 15
IN.DRAGON_LEVEL = 16

-- classification -> the suffix of its toggle / colour keys. A world boss is a boss.
IN.CLASS_SUFFIX = { elite = "Elite", rare = "Rare", rareelite = "RareElite", worldboss = "Boss", boss = "Boss" }
-- Fallback tints (= the defaults, Defaults.lua): gold, silver, blue, red.
IN.CLASS_COLORS = {
    Elite = { r = 1, g = 0.80, b = 0.32 },
    Rare = { r = 0.88, g = 0.90, b = 0.94 },
    RareElite = { r = 0.45, g = 0.70, b = 1 },
    Boss = { r = 0.95, g = 0.43, b = 0.28 },
}

-- Does classification `c` get the dragon / border, and its tint. false for an
-- ordinary (nil) or unknown classification, or one whose toggle is off.
function IN.ClassStyle(db, c)
    local suffix = (type(c) == "string") and IN.CLASS_SUFFIX[c]
    if not (suffix and db) then return false end
    if db["classDragon" .. suffix] == false then return false end
    local d = IN.CLASS_COLORS[suffix]
    local r, g, b = K.RGBA(db["classDragon" .. suffix .. "Color"], d.r, d.g, d.b)
    return true, r, g, b
end

function IN.DragonScale(db)
    local D = IN.DRAGON
    local pct = tonumber(db and db.classDragonSize) or 100
    if pct < D.MIN_SIZE then pct = D.MIN_SIZE elseif pct > D.MAX_SIZE then pct = D.MAX_SIZE end
    return pct / 100 * D.REF_SCALE
end

-- What the dragon grips, from the settings (spec: Anchor To). nil, or
--   { kind = "FRAME" | "PORTRAIT", outer = "LEFT" | "RIGHT" | nil,
--     rect = { l, t, r, b }, fw = frame width }        (rect / fw: PORTRAIT only)
-- `outer` is the side an OUTSIDE portrait sits on (nil without one), whichever
-- anchor is chosen: Side "Outer" resolves to it. The portrait anchor needs an
-- outside portrait (PO.OutsideRect: its rect, border included, in the frame's
-- units from its TOPLEFT, y down); off or inside the frame, it silently falls back
-- to the frame.
function IN.DragonAnchor(f, db)
    local PO = UF.Portrait
    local l, t, r, b
    if PO and PO.OutsideRect and db then l, t, r, b = PO.OutsideRect(f, db) end
    if not l then return { kind = "FRAME" } end
    local outer = (db.portraitSide == "RIGHT") and "RIGHT" or "LEFT"
    if db.classDragonAnchor == "FRAME" then return { kind = "FRAME", outer = outer } end
    return { kind = "PORTRAIT", outer = outer, rect = { l, t, r, b }, fw = K.FrameWidth(f, db) }
end

-- The ends the dragon is drawn on. OUTER (the default): the outside portrait's
-- side -- on the portrait, its edge away from the frame; on the frame, the
-- frame's end beside the portrait -- or RIGHT without an outside portrait.
function IN.DragonSides(db, anchor)
    local side = db and db.classDragonSide
    if side == "LEFT" then return { "LEFT" } end
    if side == "BOTH" then return { "RIGHT", "LEFT" } end
    if side == "RIGHT" then return { "RIGHT" } end
    return { (anchor and anchor.outer) or "RIGHT" }
end

-- Where each piece goes, pure (no frames): a list of
--   { side, piece = "TOP"|"BOTTOM", w, h, point, relPoint, x, y, coords = {l,r,t,b} }
-- the piece's `point` on the frame's `relPoint`. `anchor` (IN.DragonAnchor; nil =
-- the frame): on the PORTRAIT the pieces take the portrait's rect for the frame's,
-- placed from the frame's corner on the portrait's side (TOPRIGHT for a portrait
-- on the right, TOPLEFT on the left) so they track the frame's real edge:
--   top     its bottom edge on the portrait's top edge
--   bottom  its top edge on the portrait's bottom edge
-- and the same left / right rules as the frame's ends. The art is wider than a
-- square portrait, so on the OUTER edge the overhang falls INWARD, over the gap
-- and the frame -- never out past the portrait's outer edge.
function IN.DragonLayout(db, anchor)
    local D = IN.DRAGON
    local s = IN.DragonScale(db)
    local ox, oy = tonumber(db and db.classDragonX) or 0, tonumber(db and db.classDragonY) or 0
    local tx = tonumber(db and db.classDragonTailX) or 0
    local sides = IN.DragonSides(db, anchor)
    local rect = anchor and anchor.kind == "PORTRAIT" and anchor.rect
    local corner, base = nil, 0
    if rect then
        -- The frame corner the portrait's offsets are measured from.
        corner = (anchor.outer == "RIGHT") and "TOPRIGHT" or "TOPLEFT"
        if corner == "TOPRIGHT" then base = -(tonumber(anchor.fw) or 0) end
    end
    local out = {}
    for _, side in ipairs(sides) do
        -- BOTH: the left end is the right end's mirror image.
        local x, t = ox, tx
        if side == "LEFT" and #sides == 2 then x, t = -ox, -tx end
        for _, piece in ipairs({ "TOP", "BOTTOM" }) do
            local a = D[piece]
            local u, v = a.w / D.CANVAS_W, a.h / D.CANVAS_H
            local e = { side = side, piece = piece, w = a.w * s, h = a.h * s, y = oy }
            local vert = (piece == "TOP") and "BOTTOM" or "TOP"
            local rel = (piece == "TOP") and "TOP" or "BOTTOM"
            if side == "RIGHT" then
                e.point, e.relPoint = vert .. "RIGHT", rel .. "RIGHT"
                e.coords = { 0, u, 0, v }
                e.x = (piece == "TOP") and x or (x + t - D.TAIL_INSET)
            else
                e.point, e.relPoint = vert .. "LEFT", rel .. "LEFT"
                e.coords = { u, 0, 0, v }     -- left > right: flipped
                e.x = (piece == "TOP") and x or (x + t + D.TAIL_INSET)
            end
            if rect then
                -- The portrait's edge for the frame's: x from its left / right
                -- edge, y from its top / bottom edge (screen y is up).
                e.relPoint = corner
                e.x = e.x + base + ((side == "RIGHT") and rect[3] or rect[1])
                e.y = e.y - ((piece == "TOP") and rect[2] or rect[4])
            end
            out[#out + 1] = e
        end
    end
    return out
end

function IN.NewDragon(f)
    local d = CreateFrame("Frame", nil, f)
    d:SetAllPoints(f)
    d.tex = {}
    for _, side in ipairs({ "RIGHT", "LEFT" }) do
        d.tex[side] = {}
        for _, piece in ipairs({ "TOP", "BOTTOM" }) do
            local t = d:CreateTexture(nil, "ARTWORK")
            t:SetTexture(IN.DRAGON[piece].file)
            t:Hide()
            d.tex[side][piece] = t
        end
    end
    d:Hide()
    return d
end

function IN.LayoutDragon(f, d, db)
    d:SetFrameLevel(f:GetFrameLevel() + IN.DRAGON_LEVEL)
    local used = {}
    for _, e in ipairs(IN.DragonLayout(db, IN.DragonAnchor(f, db))) do
        local t = d.tex[e.side][e.piece]
        t:SetSize(e.w, e.h)
        t:ClearAllPoints()
        t:SetPoint(e.point, f, e.relPoint, e.x, e.y)
        t:SetTexCoord(e.coords[1], e.coords[2], e.coords[3], e.coords[4])
        t:Show()
        used[t] = true
    end
    for _, pieces in pairs(d.tex) do
        for _, t in pairs(pieces) do
            if not used[t] then t:Hide() end
        end
    end
end

-- ============================================================
-- CLASSIFICATION BORDER
-- An OVERLAY on the frame's own border band, not a recolour of it: DandersFrames
-- repaints frame.border from several independent paths (ApplyFrameBorder, the
-- unit-colour pass on roster and unit changes, the out-of-range alpha, the
-- settings' lightweight colour pass, the test painter), so a recolour would be
-- painted over the next time any of them ran, and could not show while the
-- frame's normal border is hidden. Four solid edges INSIDE the frame's rect
-- (where DF draws its border), one level above it (frame + 14).
-- ============================================================
function IN.NewClassBorder(f)
    local b = CreateFrame("Frame", nil, f)
    b:SetAllPoints(f)
    b.edges = {}
    for _, side in ipairs({ "top", "bottom", "left", "right" }) do
        local t = b:CreateTexture(nil, "OVERLAY", nil, 7)
        t:SetTexture(K.WHITE)
        b.edges[side] = t
    end
    b:Hide()
    return b
end

function IN.LayoutClassBorder(f, b, db)
    b:SetFrameLevel(f:GetFrameLevel() + IN.CLASS_BORDER_LEVEL)
    local size = tonumber(db.classBorderSize) or 1
    if size < 1 then size = 1 end
    local e = b.edges
    e.top:ClearAllPoints()
    e.top:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
    e.top:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, 0)
    e.top:SetHeight(size)
    e.bottom:ClearAllPoints()
    e.bottom:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
    e.bottom:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
    e.bottom:SetHeight(size)
    e.left:ClearAllPoints()
    e.left:SetPoint("TOPLEFT", b, "TOPLEFT", 0, -size)
    e.left:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, size)
    e.left:SetWidth(size)
    e.right:ClearAllPoints()
    e.right:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, -size)
    e.right:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, size)
    e.right:SetWidth(size)
end

-- Show and tint the dragon and the class border for classification `c` (nil:
-- ordinary, secret or no unit -- both hidden).
function IN.PaintDecorations(icons, db, c)
    local on, r, g, b = IN.ClassStyle(db, c)
    local d = icons.dragon
    if d then
        if on and db.classDragonEnabled then
            for _, pieces in pairs(d.tex) do
                for _, t in pairs(pieces) do t:SetVertexColor(r, g, b, 1) end
            end
            d:Show()
        else
            d:Hide()
        end
    end
    local cb = icons.classBorder
    if cb then
        if on and db.classBorderEnabled then
            for _, t in pairs(cb.edges) do t:SetVertexColor(r, g, b, 1) end
            cb:Show()
        else
            cb:Hide()
        end
    end
end

-- ============================================================
-- COMBAT ICON BORDER
-- DandersFrames' own combat icon (frame.combatIcon, Frames/StatusIcons.lua) on a
-- unit frame gets an optional solid border, drawn OUTSIDE the icon by the kit's
-- K.Border. Only unit frames call this, so party / raid icons are untouched.
-- The edges are the icon's own textures: they show, hide and scale with it.
-- ============================================================
function IN.PaintCombatBorder(f, db)
    local icon = f and f.combatIcon
    if not (icon and icon.CreateTexture) then return end
    local on = db and db.combatIconBorderEnabled and true or false
    -- Never build edges for an icon that has never had a border.
    if not on and not icon.dfUFBorder then return end
    K.Border(icon, on, db and db.combatIconBorderSize, db and db.combatIconBorderColor)
end

-- Resting has no unit event: one shared listener for the player frame.
if CreateFrame then
    local driver = CreateFrame("Frame")
    pcall(driver.RegisterEvent, driver, "PLAYER_UPDATE_RESTING")
    driver:SetScript("OnEvent", function()
        local f = UF.frames and UF.frames.player
        if f and f:IsVisible() then IN:Update(f) end
    end)
    IN.driver = driver
end

E:Register(IN)
