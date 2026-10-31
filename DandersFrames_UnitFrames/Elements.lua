local addonName, UF = ...

-- ============================================================
-- ELEMENTS
-- The pieces unit frames draw that DandersFrames has no equivalent for (cast
-- bar, class power, portrait, unit icons). Each is a module that registers
-- itself here and is driven by the frame's lifecycle in Units.lua:
--
--   Attach(f)               once, when the frame (live or preview) is built
--   Layout(f)               size / look / position from the unit's settings
--   SetActive(f, on)        the frame showed (register events) or hid
--   Refresh(f)              repaint from the live unit (target changed, OnShow)
--   OnUnitEvent(f, ev, u)   one of the frame's own unit events arrived
--   Preview(f)              paint fake data on a preview frame
--
-- Every method is optional. None of them is secure: these are plain frames
-- parented to the unit button (or, detached, to the unit's holder), so they
-- may be shown, hidden, moved and re-laid out in combat.
--
-- Also the small shared kit those modules draw with: a solid border, fonts,
-- colours, anchor points and the detached-element position records.
-- ============================================================

local DF = DandersFrames
if not DF then return end

local ipairs, pairs, type, pcall = ipairs, pairs, type, pcall

local E = { list = {} }
UF.Elements = E

function E:Register(mod)
    for _, m in ipairs(E.list) do
        if m == mod then return end
    end
    E.list[#E.list + 1] = mod
end

-- Call `method` on every element that has it. Each call is pcall'd: one
-- element's error must never cost the frame the rest of its repaint.
function E:Call(method, f, ...)
    for _, m in ipairs(E.list) do
        local fn = m[method]
        if fn then
            local ok, err = pcall(fn, m, f, ...)
            if not ok then
                DF:DebugError("UF", "%s.%s failed: %s", tostring(m.NAME), method, tostring(err))
            end
        end
    end
end

-- ============================================================
-- SHARED KIT
-- ============================================================
local K = {}
E.Kit = K

K.BAR = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist"
K.WHITE = "Interface\\Buttons\\WHITE8x8"

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) and true or false
end
K.IsSecret = IsSecret

-- nil, without comparing a secret (a secret is never nil).
-- ⚠ issecretvalue FIRST, everywhere: even `v == nil` is a comparison, and a
-- secret may not be compared.
function K.IsNil(v)
    if IsSecret(v) then return false end
    return v == nil
end

-- One colour channel (or alpha) picked by a possibly secret boolean. The client
-- evaluates a secret one (C_CurveUtil.EvaluateColorValueFromBoolean); Lua only
-- ever sees the two plain numbers it picks from.
function K.Pick(flag, ifTrue, ifFalse)
    if IsSecret(flag) then
        local CU = C_CurveUtil
        if CU and CU.EvaluateColorValueFromBoolean then
            return CU.EvaluateColorValueFromBoolean(flag, ifTrue, ifFalse)
        end
        return ifFalse
    end
    if flag then return ifTrue end
    return ifFalse
end

-- A FRAME's alpha from a possibly secret boolean (Frame:SetAlphaFromBoolean;
-- a texture-level alpha from a secret renders 0 on Midnight, per research).
function K.AlphaFrom(frame, flag, ifTrue, ifFalse)
    if not frame then return end
    if IsSecret(flag) then
        if frame.SetAlphaFromBoolean then
            frame:SetAlphaFromBoolean(flag, ifTrue, ifFalse)
        else
            frame:SetAlpha(ifFalse)
        end
        return
    end
    if flag then frame:SetAlpha(ifTrue) else frame:SetAlpha(ifFalse) end
end

-- r, g, b, a of a stored colour table (defaults when missing or malformed).
function K.RGBA(c, dr, dg, db, da)
    if type(c) ~= "table" then return dr or 1, dg or 1, db or 1, da or 1 end
    return c.r or dr or 1, c.g or dg or 1, c.b or db or 1, c.a or da or 1
end

-- A four-edge solid border on `owner` (created once, then repainted).
function K.Border(owner, show, size, color)
    local b = owner.dfUFBorder
    if not b then
        b = {}
        for _, side in ipairs({ "top", "bottom", "left", "right" }) do
            local t = owner:CreateTexture(nil, "OVERLAY", nil, 7)
            t:SetTexture(K.WHITE)
            b[side] = t
        end
        owner.dfUFBorder = b
    end
    size = tonumber(size) or 1
    if size < 1 then size = 1 end
    local r, g, bl, a = K.RGBA(color, 0, 0, 0, 1)
    b.top:ClearAllPoints()
    b.top:SetPoint("TOPLEFT", owner, "TOPLEFT", -size, size)
    b.top:SetPoint("TOPRIGHT", owner, "TOPRIGHT", size, size)
    b.top:SetHeight(size)
    b.bottom:ClearAllPoints()
    b.bottom:SetPoint("BOTTOMLEFT", owner, "BOTTOMLEFT", -size, -size)
    b.bottom:SetPoint("BOTTOMRIGHT", owner, "BOTTOMRIGHT", size, -size)
    b.bottom:SetHeight(size)
    b.left:ClearAllPoints()
    b.left:SetPoint("TOPLEFT", owner, "TOPLEFT", -size, 0)
    b.left:SetPoint("BOTTOMLEFT", owner, "BOTTOMLEFT", -size, 0)
    b.left:SetWidth(size)
    b.right:ClearAllPoints()
    b.right:SetPoint("TOPRIGHT", owner, "TOPRIGHT", size, 0)
    b.right:SetPoint("BOTTOMRIGHT", owner, "BOTTOMRIGHT", size, 0)
    b.right:SetWidth(size)
    for _, t in pairs(b) do
        t:SetVertexColor(r, g, bl, a)
        if show then t:Show() else t:Hide() end
    end
end

function K.Font(fs, font, size, outline, color)
    if not fs then return end
    if DF.SafeSetFont then
        DF:SafeSetFont(fs, font, size, outline)
    end
    local r, g, b = K.RGBA(color)
    fs:SetTextColor(r, g, b, 1)
end

-- Stored anchor values are the nine WoW points ("TOPLEFT", "CENTER", ...).
K.POINTS = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
             RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true }
function K.Point(v, default)
    if type(v) == "string" then
        local up = v:upper():gsub(" ", "")
        if K.POINTS[up] then return up end
    end
    return default or "CENTER"
end

-- The frame's settings table (the unit's own, via DF's standalone stamp).
function K.DB(f)
    if f and f.dfDB then return f.dfDB end
    return f and f.dfUFUnit and UF:GetUnitDB(f.dfUFUnit) or nil
end

-- Width of the frame from its settings (never measured: a measured width can be
-- 0 before the first layout pass).
function K.FrameWidth(f, db)
    db = db or K.DB(f)
    local w = db and tonumber(db.frameWidth)
    if w and w > 0 then return w end
    return (f and f.GetWidth and f:GetWidth()) or 100
end

function K.FrameHeight(f, db)
    db = db or K.DB(f)
    local h = db and tonumber(db.frameHeight)
    if h and h > 0 then return h end
    return (f and f.GetHeight and f:GetHeight()) or 30
end

-- Where a DETACHED element lives: the unit's holder for a live frame (so the
-- unit's Visibility rule hides it too), the preview parent for a preview frame.
function K.DetachedParent(f)
    if f.dfUFPreview then
        return (UF.Preview and UF.Preview.GetParent and UF.Preview:GetParent()) or f:GetParent()
    end
    local holders = UF.Units and UF.Units.holders
    return (holders and holders[f.dfUFUnit]) or f:GetParent()
end

-- Put a detached element at its record (point/x/y; DandersMover applies the
-- anchor solve when it is installed). The element takes its owner's scale.
function K.PlaceDetached(el, f, record)
    if type(record) ~= "table" then return end
    if UF.Units and UF.Units.PlaceAt then UF.Units:PlaceAt(el, record) end
end

-- ============================================================
-- AURA ROW PLACEMENT (DandersFrames' frame.dfAuraRowPlacement, Features/Auras.lua)
-- Set on every unit frame, live and preview (Units:Build, Preview:Build). Two parts:
--   * the ROW'S OWN CORNER (K.RowPoint): a row that grows AWAY from the edge it is
--     anchored to hangs outside that edge, so it is pinned by its corner nearest
--     the frame. Icons line up on that corner's edges, so a bigger icon (an
--     important debuff) grows away from the frame instead of back into it: a row
--     under the frame lines its icons up by their tops, a row above it by their
--     bottoms, a row beside it by the side nearest the frame (and its top). The
--     row's offset then measures from that corner, so the gap to the frame does
--     not depend on the icon size. Derived from the row's own anchor and growth
--     every time, so a row the user moves keeps lining up the right way. A row
--     inside the frame (growing back over it) keeps its anchor, as DF always did.
--   * the CAST BAR RESERVE (CastBar.lua): a row anchored to the bottom edge goes
--     below an attached cast bar.
-- ============================================================
function K.RowPoint(anchor, growth)
    if type(anchor) ~= "string" or type(growth) ~= "string" then return nil end
    local p, s = growth:match("^(%a+)_?(%a*)$")
    if not p or p == "CENTER" then return nil end
    local v = ((p == "UP" or p == "DOWN") and p) or ((s == "UP" or s == "DOWN") and s) or nil
    local h = ((p == "LEFT" or p == "RIGHT") and p) or ((s == "LEFT" or s == "RIGHT") and s) or nil
    local av = (anchor:find("TOP", 1, true) and "TOP") or (anchor:find("BOTTOM", 1, true) and "BOTTOM") or nil
    local ah = (anchor:find("LEFT", 1, true) and "LEFT") or (anchor:find("RIGHT", 1, true) and "RIGHT") or nil
    -- Corners only (DF's rowPoint is a corner): an edge midpoint or the centre keeps
    -- the anchor.
    if not (av and ah) then return nil end
    if av == "BOTTOM" and v == "DOWN" then av = "TOP"
    elseif av == "TOP" and v == "UP" then av = "BOTTOM" end
    if ah == "LEFT" and h == "LEFT" then ah = "RIGHT"
    elseif ah == "RIGHT" and h == "RIGHT" then ah = "LEFT" end
    local point = av .. ah
    if point == anchor then return nil end
    return point
end

function UF.AuraRowPlacement(f, db, prefix, anchor, growth)
    local dy = 0
    if type(anchor) == "string" and anchor:find("BOTTOM", 1, true) then
        local CB = UF.CastBar
        local r = CB and CB.BottomReserve and CB.BottomReserve(f, db) or 0
        if r > 0 then dy = -r end
    end
    return 0, dy, K.RowPoint(anchor, growth)
end
