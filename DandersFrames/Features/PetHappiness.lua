local addonName, DF = ...

-- ============================================================
-- PET HAPPINESS (WoW Forever only)
-- The hunter's own pet: how happy it is, its damage modifier and whether it is
-- gaining or losing loyalty, read from C_PetInfo.GetPetHappiness(). The API
-- takes no unit, so this only ever describes the player's own pet.
--
-- One shared core every consumer reads through:
--   PH:Read()               mood (1 unhappy, 2 content, 3 happy), damage %,
--                           loyalty rate -- or nil (not Forever, not a hunter
--                           pet, no pet, or an unreadable / secret answer)
--   PH:SetArt(tex, mood)    Blizzard's face: the atlas when the client has it,
--                           else the old paper-doll texture cropped to the face
--   PH:TooltipLines(mock)   the hover tooltip's lines (mock: test mode's sample)
--   PH:ShowTooltip(owner, mock) / PH:HideTooltip()
--   PH:SetConsumer(key, on, fn)  a frame that shows it; fn() runs when the
--                           answer changes. Events are registered only while
--                           at least one consumer is on, on Forever, for a hunter.
--
-- ⚠ UNVERIFIED IN GAME: the atlas names, and that the answers stay readable in
-- combat. A secret answer reads as nil (hidden), never guessed.
-- ============================================================

local pairs, ipairs, type, select, tonumber, tostring, next = pairs, ipairs, type, select, tonumber, tostring, next
local format = string.format
local tconcat = table.concat

local PH = {}
DF.PetHappiness = PH

-- mood -> atlas (EllesmereUI's names) and the old texture's crop (Blizzard's
-- PetHappiness.lua) for a client without the atlas.
PH.ATLAS = { [1] = "UI-PetMad", [2] = "UI-PetNeutral", [3] = "UI-PetHappiness" }
PH.FILE = "Interface\\PetPaperDollFrame\\UI-PetHappiness"
PH.COORDS = {
    [3] = { 0, 0.1875, 0, 0.359375 },
    [2] = { 0.1875, 0.375, 0, 0.359375 },
    [1] = { 0.375, 0.5625, 0, 0.359375 },
}
-- The tooltip title's colour per mood.
PH.TITLE_COLORS = {
    [3] = { 0.35, 0.85, 0.35 },
    [2] = { 1, 0.75, 0.2 },
    [1] = { 0.95, 0.3, 0.3 },
}
-- The test-mode sample: a happy pet gaining loyalty.
PH.MOCK = { mood = 3, damage = 125, rate = 1, loyaltyLevel = 6, diet = { "Meat", "Fish" },
            trainingPoints = 120, xp = 1200, nextXP = 4800 }

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) and true or false
end

-- ============================================================
-- READING
-- ============================================================
function PH:IsSupported()
    return (DF.IS_FOREVER and C_PetInfo and C_PetInfo.GetPetHappiness) and true or false
end

function PH:IsHunter()
    if PH.isHunter == nil then
        local class = UnitClass and select(2, UnitClass("player"))
        if class == nil then return false end      -- not known yet at login: ask again later
        PH.isHunter = (class == "HUNTER")
    end
    return PH.isHunter
end

-- mood, damage %, loyalty rate; nil when there is nothing to show.
function PH:Read()
    if not PH:IsSupported() then return nil end
    if HasPetUI then
        local hasUI, isHunterPet = HasPetUI()
        if IsSecret(hasUI) or IsSecret(isHunterPet) or not (hasUI and isHunterPet) then return nil end
    end
    local mood, damage, rate = C_PetInfo.GetPetHappiness()
    if IsSecret(mood) or type(mood) ~= "number" then return nil end
    if mood < 1 or mood > 3 then return nil end
    if IsSecret(damage) or type(damage) ~= "number" then damage = nil end
    if IsSecret(rate) or type(rate) ~= "number" then rate = nil end
    return mood, damage, rate
end

-- ============================================================
-- ART
-- ============================================================
function PH:SetArt(tex, mood)
    if not (tex and PH.COORDS[mood]) then return false end
    local atlas = PH.ATLAS[mood]
    local info = C_Texture and C_Texture.GetAtlasInfo
    if atlas and info and tex.SetAtlas and info(atlas) then
        tex:SetTexCoord(0, 1, 0, 1)     -- SetAtlas keeps an earlier crop
        tex:SetAtlas(atlas)
        return true
    end
    local c = PH.COORDS[mood]
    tex:SetTexture(PH.FILE)
    tex:SetTexCoord(c[1], c[2], c[3], c[4])
    return true
end

-- ============================================================
-- TOOLTIP
-- Every line is read when the tooltip opens; a line whose API answers nothing
-- is left out. Blizzard's own global strings first, so the text is localised
-- for free, with our fallback when a build lacks one.
-- ============================================================
local function G(name, fallback)
    local v = _G[name]
    if type(v) == "string" and v ~= "" then return v end
    return DF.L[fallback]
end

-- format() for a template that may not carry the placeholders on every build
-- (a global without its %d would drop the number): then "Template value".
local function Fmt(template, ...)
    if template:find("%", 1, true) then
        local ok, s = pcall(format, template, ...)
        if ok then return s end
    end
    local parts = { template }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    return tconcat(parts, " ")
end

local function Plain(v)
    if v == nil or IsSecret(v) then return nil end
    return v
end

-- What the tooltip shows, as a table of named fields (nil = leave the line out).
function PH:TooltipData(mock)
    if mock then
        local m = PH.MOCK
        return { mood = m.mood, damage = m.damage, rate = m.rate,
                 loyalty = format(DF.L["Loyalty Level %d"], m.loyaltyLevel),
                 diet = { DF.L["Meat"], DF.L["Fish"] },
                 trainingPoints = m.trainingPoints, xp = m.xp, nextXP = m.nextXP }
    end
    local d = {}
    d.mood, d.damage, d.rate = PH:Read()
    if not d.mood then return nil end
    local P = C_PetInfo
    if P.GetPetLoyalty then
        local s = Plain(P.GetPetLoyalty())
        if type(s) == "string" and s ~= "" then d.loyalty = s end
    end
    if P.GetPetFoodTypes then
        local foods = Plain(P.GetPetFoodTypes())
        if type(foods) == "table" and next(foods) then d.diet = foods end
    end
    if P.GetPetTrainingPoints then
        local total, used = P.GetPetTrainingPoints()
        total, used = tonumber(Plain(total)), tonumber(Plain(used)) or 0
        if total then d.trainingPoints = total - used end
    end
    if GetPetExperience then
        local cur, nxt = GetPetExperience()
        cur, nxt = tonumber(Plain(cur)), tonumber(Plain(nxt))
        if cur and nxt and nxt > 0 then d.xp, d.nextXP = cur, nxt end
    end
    return d
end

-- { text, r, g, b } per line, in order.
function PH:TooltipLines(mock)
    local d = PH:TooltipData(mock)
    if not d then return {} end
    local lines = {}
    local function add(text, r, g, b)
        lines[#lines + 1] = { text = text, r = r or 1, g = g or 1, b = b or 1 }
    end
    local c = PH.TITLE_COLORS[d.mood]
    add(G("PET_HAPPINESS" .. d.mood, PH.MOOD_FALLBACK[d.mood]), c[1], c[2], c[3])
    if d.damage then
        add(Fmt(G("PET_DAMAGE_PERCENTAGE", "Pet is doing %d%% damage"), d.damage))
    end
    if d.rate and d.rate < 0 then
        add(G("LOSING_LOYALTY", "Losing loyalty"), 0.95, 0.3, 0.3)
    elseif d.rate and d.rate > 0 then
        add(G("GAINING_LOYALTY", "Gaining loyalty"))
    end
    if d.loyalty then add(d.loyalty) end
    if d.diet then
        local foods = {}
        for i = 1, #d.diet do
            if type(d.diet[i]) == "string" then foods[#foods + 1] = d.diet[i] end
        end
        if #foods > 0 then
            local delim = _G.PET_FOOD_DELIMIT
            if type(delim) ~= "string" or delim == "" then delim = ", " end
            add(Fmt(G("PET_DIET_TEMPLATE", "Diet: %s"), tconcat(foods, delim)))
        end
    end
    if d.trainingPoints then
        add(Fmt(G("TRAINING_POINTS", "Training Points: %d"), d.trainingPoints))
    end
    if d.xp then
        add(Fmt(G("XP_STATUS_BAR_TEXT", "XP: %s / %s"), PH.Number(d.xp), PH.Number(d.nextXP)))
    end
    return lines
end

-- The fallback locale keys for the three moods (Blizzard's PET_HAPPINESS1..3).
PH.MOOD_FALLBACK = { [1] = "Unhappy", [2] = "Content", [3] = "Happy" }

-- XP numbers with thousands separators, as Blizzard's XP bar shows them.
function PH.Number(n)
    if BreakUpLargeNumbers then return BreakUpLargeNumbers(n) end
    return tostring(n)
end

function PH:ShowTooltip(owner, mock)
    if not (owner and GameTooltip) then return end
    local lines = PH:TooltipLines(mock)
    if #lines == 0 then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    for _, l in ipairs(lines) do GameTooltip:AddLine(l.text, l.r, l.g, l.b) end
    GameTooltip:Show()
end

function PH:HideTooltip()
    if GameTooltip then GameTooltip:Hide() end
end

-- ============================================================
-- EVENTS
-- One listener for everyone who shows it. Registered only while a consumer
-- is on, on Forever, for a hunter; otherwise every event is unregistered.
-- A consumer is told only when the answer changes (the mood, the damage or
-- the loyalty trend), or once after a new pet / a loading screen.
-- ============================================================
PH.consumers = {}
PH.EVENTS = { "UNIT_HAPPINESS", "UNIT_PET", "PLAYER_ENTERING_WORLD" }

local function Sign(rate)
    if not rate then return 0 end
    return (rate > 0 and 1) or (rate < 0 and -1) or 0
end

function PH:StateKey()
    local mood, damage, rate = PH:Read()
    if not mood then return "none" end
    return mood .. ":" .. tostring(damage) .. ":" .. Sign(rate)
end

function PH:Notify(force)
    local key = PH:StateKey()
    if not force and key == PH.lastKey then return end
    PH.lastKey = key
    for _, fn in pairs(PH.consumers) do fn() end
end

function PH:Wanted()
    return PH:IsSupported() and PH:IsHunter() and next(PH.consumers) ~= nil
end

function PH:UpdateRegistration()
    local want = PH:Wanted()
    local f = PH.driver
    if not want then
        if f and PH.registered then
            f:UnregisterAllEvents()
            PH.registered = false
            PH.lastKey = nil
            DF:Debug("PET", "Pet Happiness: events off")
        end
        return
    end
    if PH.registered then return end
    if not f then
        if not CreateFrame then return end
        f = CreateFrame("Frame")
        f:SetScript("OnEvent", function(_, event) PH:OnEvent(event) end)
        PH.driver = f
    end
    -- pcall'd: a client without one of these refuses it; that costs one event.
    if f.RegisterUnitEvent then
        pcall(f.RegisterUnitEvent, f, "UNIT_HAPPINESS", "pet")
        pcall(f.RegisterUnitEvent, f, "UNIT_PET", "player")
    else
        pcall(f.RegisterEvent, f, "UNIT_HAPPINESS")
        pcall(f.RegisterEvent, f, "UNIT_PET")
    end
    pcall(f.RegisterEvent, f, "PLAYER_ENTERING_WORLD")
    PH.registered = true
    DF:Debug("PET", "Pet Happiness: events on")
end

function PH:OnEvent(event)
    if event == "PLAYER_ENTERING_WORLD" then
        -- The pet's state may not read yet straight after a loading screen.
        if C_Timer and C_Timer.After then
            C_Timer.After(0.5, function() PH:Notify(true) end)
        else
            PH:Notify(true)
        end
    elseif event == "UNIT_PET" then
        PH:Notify(true)
    else
        PH:Notify(false)
    end
end

-- on: whether this consumer shows the icon right now; fn: its repaint.
function PH:SetConsumer(key, on, fn)
    if on and type(fn) == "function" then
        PH.consumers[key] = fn
    else
        PH.consumers[key] = nil
    end
    PH:UpdateRegistration()
end

-- ============================================================
-- PLACEMENT (shared by the unit frames pet icon and the group pet frames)
-- One of the nine points inside the frame, or OUTSIDE_<side>: the icon's facing
-- edge on the frame's <side> edge, centred along it.
-- ============================================================
PH.OUTSIDE = {
    OUTSIDE_RIGHT = { "LEFT", "RIGHT" },
    OUTSIDE_LEFT = { "RIGHT", "LEFT" },
    OUTSIDE_TOP = { "BOTTOM", "TOP" },
    OUTSIDE_BOTTOM = { "TOP", "BOTTOM" },
}
PH.INSIDE = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true,
              BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true }

function PH:Place(icon, rel, anchor, x, y)
    x, y = tonumber(x) or 0, tonumber(y) or 0
    local out = PH.OUTSIDE[anchor]
    if out then
        icon:SetPoint(out[1], rel, out[2], x, y)
    else
        local point = PH.INSIDE[anchor] and anchor or "RIGHT"
        icon:SetPoint(point, rel, point, x, y)
    end
end

-- Hover reaches the icon (for the tooltip) while `on`; clicks never stop at it,
-- so a click on the icon is a click on whatever is under it.
function PH.SetMouse(icon, on)
    on = on and true or false
    if icon.dfMouseOn == on then return end
    if InCombatLockdown and InCombatLockdown() then return end
    icon.dfMouseOn = on
    if icon.EnableMouseMotion then
        icon:EnableMouseMotion(on)
    elseif icon.SetMouseMotionEnabled then
        icon:SetMouseMotionEnabled(on)
    end
    if icon.SetMouseClickEnabled then icon:SetMouseClickEnabled(false) end
end

-- ============================================================
-- GROUP PET FRAMES (Frames/Pets.lua)
-- The face goes on the ONE group pet frame that shows your own pet: "pet" in a
-- party, the raidpet<N> that is your pet in a raid or an arena. The API only
-- describes your own pet, so other people's pets never get one. Settings are
-- the petHappinessIcon* keys of the frame's mode table (party, generated raid).
-- In test mode the player's slot (party "pet", raid "raidpet1") shows the
-- sample, whatever your class, so it can be set up without a pet.
-- ⚠ The icon is a plain child frame: it never takes clicks and is never
-- protected, so it is laid out and painted in combat too.
-- ============================================================
local GROUP_KEY = "group_pet"

-- Is this group pet frame showing the player's own pet?
function PH.IsOwnPetFrame(frame)
    local unit = frame and frame.unit
    if type(unit) ~= "string" then return false end
    if frame.dfIsTestFrame then
        return unit == "pet" or (frame.isRaidFrame and unit == "raidpet1") or false
    end
    if unit == "pet" then return true end
    if not unit:find("^raidpet%d+$") then return false end   -- partypet<N>: never yours
    local same = DF.UnitIsUnit and DF.UnitIsUnit(unit, "pet")
    if same == nil and not DF.UnitIsUnit and UnitIsUnit then
        same = UnitIsUnit(unit, "pet")
        if IsSecret(same) then same = nil end
    end
    return same == true
end

local function GroupIconOnEnter(self)
    local frame = self.dfPetFrame
    local db = frame and DF:GetFrameDB(frame)
    if not db or db.petHappinessIconTooltip == false then return end
    PH:ShowTooltip(self, frame.dfIsTestFrame and true or false)
end

local function GroupIconOnLeave()
    PH:HideTooltip()
end

function PH.NewGroupIcon(frame)
    local icon = CreateFrame("Frame", nil, frame)
    icon.dfPetFrame = frame
    icon.tex = icon:CreateTexture(nil, "OVERLAY")
    icon.tex:SetAllPoints()
    icon:SetScript("OnEnter", GroupIconOnEnter)
    icon:SetScript("OnLeave", GroupIconOnLeave)
    icon:Hide()
    frame.dfHappinessIcon = icon
    return icon
end

-- Paints only on a change of mood; nil hides.
function PH.PaintGroupIcon(icon, mood)
    if not mood then
        icon.dfMood = nil
        icon:Hide()
        return
    end
    if icon.dfMood ~= mood then
        if not PH:SetArt(icon.tex, mood) then icon.dfMood = nil; icon:Hide(); return end
        icon.dfMood = mood
    end
    icon:Show()
end

function PH.LayoutGroupIcon(icon, frame, db)
    local size = tonumber(db.petHappinessIconSize) or 14
    icon:SetSize(size, size)
    -- Above the pet frame's own layers (its border sits at +14).
    if frame.GetFrameLevel and icon.SetFrameLevel then
        icon:SetFrameLevel((frame:GetFrameLevel() or 0) + 16)
    end
    icon:ClearAllPoints()
    PH:Place(icon, frame, db.petHappinessIconAnchor or "OUTSIDE_RIGHT", db.petHappinessIconX, db.petHappinessIconY)
    PH.SetMouse(icon, db.petHappinessIconTooltip ~= false)
end

-- Lay out and paint one group pet frame's face (Pets.lua calls this when the
-- frame is styled or updated). Forever only.
function PH:UpdateGroupFrame(frame)
    if not (DF.IS_FOREVER and frame) then return end
    local db = DF:GetFrameDB(frame)
    local test = frame.dfIsTestFrame
    local icon = frame.dfHappinessIcon
    if not test then PH:WatchGroup() end
    if not (db and db.petHappinessIconEnabled and PH.IsOwnPetFrame(frame)) then
        if icon then PH.PaintGroupIcon(icon, nil) end
        return
    end
    icon = icon or PH.NewGroupIcon(frame)
    PH.LayoutGroupIcon(icon, frame, db)
    local mood
    if test then
        local data = frame.ownerFrame and DF.GetTestDataForFrame and DF:GetTestDataForFrame(frame.ownerFrame)
        mood = (data and data.petHappiness) or PH.MOCK.mood
    else
        mood = (PH:Read())
    end
    PH.PaintGroupIcon(icon, mood)
end

-- The live group pet frames that could be yours, repainted when the answer
-- changes (the shared event driver calls this).
local function GroupFramesChanged()
    if DF.petFrames and DF.petFrames.player then PH:UpdateGroupFrame(DF.petFrames.player) end
    local sets = { DF.raidPetFrames, DF.arenaPetFrames }
    for n = 1, 2 do
        local set = sets[n]
        if set then
            for i = 1, 40 do
                local f = set[i]
                -- A frame that had the face (to repaint or drop it), or the one that is yours now.
                if f and (f.dfHappinessIcon or PH.IsOwnPetFrame(f)) then PH:UpdateGroupFrame(f) end
            end
        end
    end
end
PH.GroupFramesChanged = GroupFramesChanged

-- Asks for the events while either group mode (party, raid) shows the face.
function PH:WantsGroup()
    if not DF.IS_FOREVER then return false end
    for _, get in ipairs({ "GetDB", "GetRaidDB" }) do
        local db = DF[get] and DF[get](DF)
        if db and db.petEnabled and db.petHappinessIconEnabled then return true end
    end
    return false
end

function PH:WatchGroup()
    local on = PH:WantsGroup()
    -- Asked again while on but unregistered: the class may not have been known yet.
    if on == PH.groupOn and not (on and not PH.registered) then return end
    PH.groupOn = on
    PH:SetConsumer(GROUP_KEY, on, GroupFramesChanged)
end
