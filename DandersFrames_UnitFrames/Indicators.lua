local addonName, UF = ...

-- ============================================================
-- UNIT ICONS (spec §3.3 "Icons: a new Unit group", §4 "Level / classification /
-- PvP / resting")
-- What DandersFrames' own status icons do not cover, as three small icons:
--   Resting       the player, while resting
--   PvP           the player / target / focus while PvP flagged (faction crest,
--                 or the free-for-all flag)
--   Elite / Rare  target / focus / boss: an elite or rare dragon, or the word
--                 ("+", Rare, Rare Elite, Boss) from the Text Designer's own
--                 Classification resolver (the D12 token), so the text matches
--                 a Classification text element exactly
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

local pairs, type, pcall, tonumber = pairs, type, pcall, tonumber

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

IN.ART = {
    resting = { file = "Interface\\CharacterFrame\\UI-StateIcon", coords = { 0, 0.5, 0, 0.421875 } },
    pvp = {
        Horde = { file = "Interface\\TargetingFrame\\UI-PVP-Horde", coords = { 0.08, 0.58, 0.045, 0.545 } },
        Alliance = { file = "Interface\\TargetingFrame\\UI-PVP-Alliance", coords = { 0.07, 0.58, 0.06, 0.57 } },
        FFA = { file = "Interface\\TargetingFrame\\UI-PVP-FFA", coords = { 0.05, 0.605, 0.015, 0.57 } },
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
        if units[unit] then icons[key] = NewIcon(host) end
    end
    f.dfUFIcons = icons
    return icons
end

function IN:Enabled(db, key)
    return db and db[IN.PREFIX[key] .. "Enabled"] and true or false
end

function IN:Layout(f)
    local icons = f and f.dfUFIcons
    if not icons then return end
    local db = K.DB(f)
    if not db then return end
    icons.host:SetFrameLevel(f:GetFrameLevel() + 30)
    for key in pairs(IN.ICONS) do
        local icon = icons[key]
        if icon then
            local pre = IN.PREFIX[key]
            local size = tonumber(db[pre .. "Size"]) or 16
            icon:SetSize(size, size)
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

function IN:PaintResting(icon, on)
    if not on then icon:Hide(); return end
    local a = IN.ART.resting
    icon.text:Hide()
    icon.tex:Show()
    icon.tex:SetTexture(a.file)
    icon.tex:SetTexCoord(a.coords[1], a.coords[2], a.coords[3], a.coords[4])
    icon:Show()
end

function IN:PaintPvP(icon, state)
    local a = state and IN.ART.pvp[state]
    if not a then icon:Hide(); return end
    icon.text:Hide()
    icon.tex:Show()
    icon.tex:SetTexture(a.file)
    icon.tex:SetTexCoord(a.coords[1], a.coords[2], a.coords[3], a.coords[4])
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
        IN:PaintResting(icons.resting, IN:Enabled(db, "resting") and IN:IsResting())
    end
    if icons.pvp then
        IN:PaintPvP(icons.pvp, (IN:Enabled(db, "pvp") and exists) and IN:PvPState(unit) or nil)
    end
    if icons.classification then
        local c = (IN:Enabled(db, "classification") and exists) and IN:Classification(unit) or nil
        IN:PaintClassification(icons.classification, c, db and db.classificationStyle)
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
    local icons = f and f.dfUFIcons
    if not icons then return end
    local db = K.DB(f)
    IN:Layout(f)
    if icons.resting then IN:PaintResting(icons.resting, IN:Enabled(db, "resting")) end
    if icons.pvp then
        local faction = UnitFactionGroup and UnitFactionGroup("player")
        if IsSecret(faction) or (faction ~= "Horde" and faction ~= "Alliance") then faction = "Alliance" end
        IN:PaintPvP(icons.pvp, IN:Enabled(db, "pvp") and faction or nil)
    end
    if icons.classification then
        local data = f.dfTestData
        local c = data and data.classification or "elite"
        IN:PaintClassification(icons.classification, IN:Enabled(db, "classification") and c or nil,
            db and db.classificationStyle)
    end
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
