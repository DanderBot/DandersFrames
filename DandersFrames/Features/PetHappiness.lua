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
--   PH.Resolve(...)         what one icon shows: the face (or nil: hidden while
--                           happy) and the trend badge's arrow
--   PH.PaintBadge(icon, dir, size)  the loyalty arrow on the icon's corner
--   PH:SetConsumer(key, on, fn)  a frame that shows it; fn() runs when the
--                           answer changes. Events are registered only while
--                           at least one consumer is on, on Forever, for a hunter.
--   PH.Tint(mood, onlyUnhappy)  the colour a frame is tinted by happiness (or nil)
--   PH.SetTints(frame, side, health, border, name)  stamp + repaint what changed
--   PH:Loyalty / :Diet / :TrainingPoints / :Experience (mock)  the other answers
--                           (tooltip and Text Designer tokens); PH.MoodText(mood)
--   PH:WatchTokens(frame, on)  a unit frames pet frame shows a pet token: the XP
--                           and training point events are registered only then
--
-- ⚠ UNVERIFIED IN GAME: the atlas names, and that the answers stay readable in
-- combat. A secret answer reads as nil (hidden), never guessed.
-- ============================================================

local pairs, ipairs, type, select, tonumber, tostring, next = pairs, ipairs, type, select, tonumber, tostring, next
local format = string.format
local floor, max = math.floor, math.max
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
-- The test-mode sample: an unhappy pet losing loyalty, the state the face and
-- the trend badge exist to warn about, so test mode shows both whatever the
-- badge's mode (Losing Only / Both) and whether Hide While Happy is on.
PH.MOCK = { mood = 1, damage = 75, rate = -1, loyaltyLevel = 6, diet = { "Meat", "Fish" },
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

-- Forever, and the player has a hunter pet out (a warlock's demon is not one).
function PH:HasHunterPet()
    if not PH:IsSupported() then return false end
    if HasPetUI then
        local hasUI, isHunterPet = HasPetUI()
        if IsSecret(hasUI) or IsSecret(isHunterPet) or not (hasUI and isHunterPet) then return false end
    end
    return true
end

-- mood, damage %, loyalty rate; nil when there is nothing to show.
function PH:Read()
    if not PH:HasHunterPet() then return nil end
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

-- ------------------------------------------------------------
-- The pet's other answers, read by the tooltip and the Text Designer's pet
-- tokens (one place that calls each API). nil = nothing to show: no hunter pet,
-- an empty or secret answer. `mock`: test mode's sample (PH.MOCK) instead.
-- ------------------------------------------------------------
function PH:Loyalty(mock)
    if mock then return format(DF.L["Loyalty Level %d"], PH.MOCK.loyaltyLevel) end
    if not (PH:HasHunterPet() and C_PetInfo.GetPetLoyalty) then return nil end
    local s = Plain(C_PetInfo.GetPetLoyalty())
    if type(s) == "string" and s ~= "" then return s end
    return nil
end

-- The foods the pet eats, as the API's list (localised by the client).
function PH:Diet(mock)
    if mock then return { DF.L["Meat"], DF.L["Fish"] } end
    if not (PH:HasHunterPet() and C_PetInfo.GetPetFoodTypes) then return nil end
    local foods = Plain(C_PetInfo.GetPetFoodTypes())
    if type(foods) == "table" and next(foods) then return foods end
    return nil
end

-- The diet list joined with Blizzard's delimiter ("Meat, Fish"); nil when empty.
function PH.DietText(foods)
    if type(foods) ~= "table" then return nil end
    local delim = _G.PET_FOOD_DELIMIT
    if type(delim) ~= "string" or delim == "" then delim = ", " end
    local out
    for i = 1, #foods do
        local f = foods[i]
        if type(f) == "string" and not IsSecret(f) then out = out and (out .. delim .. f) or f end
    end
    return out
end

-- Training points available to spend (total - used).
function PH:TrainingPoints(mock)
    if mock then return PH.MOCK.trainingPoints end
    if not (PH:HasHunterPet() and C_PetInfo.GetPetTrainingPoints) then return nil end
    local total, used = C_PetInfo.GetPetTrainingPoints()
    total, used = tonumber(Plain(total)), tonumber(Plain(used)) or 0
    if not total then return nil end
    return total - used
end

-- Current XP and XP to the next level; nil at the level cap (Blizzard's XP bar
-- hides there too: nextXP is 0).
function PH:Experience(mock)
    if mock then return PH.MOCK.xp, PH.MOCK.nextXP end
    if not (PH:HasHunterPet() and GetPetExperience) then return nil end
    local cur, nxt = GetPetExperience()
    cur, nxt = tonumber(Plain(cur)), tonumber(Plain(nxt))
    if cur and nxt and nxt > 0 then return cur, nxt end
    return nil
end

-- Happy / Content / Unhappy: Blizzard's own words, ours if a build lacks one.
function PH.MoodText(mood)
    if not PH.COLOR_KEYS[mood] then return nil end
    return G("PET_HAPPINESS" .. mood, PH.MOOD_FALLBACK[mood])
end

-- What the tooltip shows, as a table of named fields (nil = leave the line out).
function PH:TooltipData(mock)
    local d = {}
    if mock then
        local m = PH.MOCK
        d.mood, d.damage, d.rate = m.mood, m.damage, m.rate
    else
        d.mood, d.damage, d.rate = PH:Read()
        if not d.mood then return nil end
    end
    d.loyalty = PH:Loyalty(mock)
    d.diet = PH:Diet(mock)
    d.trainingPoints = PH:TrainingPoints(mock)
    d.xp, d.nextXP = PH:Experience(mock)
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
    add(PH.MoodText(d.mood), c[1], c[2], c[3])
    if d.damage then
        add(Fmt(G("PET_DAMAGE_PERCENTAGE", "Pet is doing %d%% damage"), d.damage))
    end
    if d.rate and d.rate < 0 then
        add(G("LOSING_LOYALTY", "Losing loyalty"), 0.95, 0.3, 0.3)
    elseif d.rate and d.rate > 0 then
        add(G("GAINING_LOYALTY", "Gaining loyalty"))
    end
    if d.loyalty then add(d.loyalty) end
    local diet = PH.DietText(d.diet)
    if diet then add(Fmt(G("PET_DIET_TEMPLATE", "Diet: %s"), diet)) end
    if d.trainingPoints then
        add(Fmt(G("TRAINING_POINTS", "Training Points: %d"), d.trainingPoints))
    end
    if d.xp then
        -- Our own string, not Blizzard's XP_STATUS_BAR_TEXT: on WoW Forever that
        -- template does not take (current, max) and printed "20/0" for 20 / 3225.
        add(format(DF.L["XP: %s / %s"], PH.Number(d.xp), PH.Number(d.nextXP)))
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
-- Consumers of the pet's other answers too (the Text Designer's pet tokens):
-- told on every pet-data event, since loyalty level, XP and training points have
-- no part in the change key below.
PH.dataConsumers = {}
PH.EVENTS = { "UNIT_HAPPINESS", "UNIT_PET", "PLAYER_ENTERING_WORLD" }
-- Registered on top of PH.EVENTS only while a data consumer is on.
PH.DATA_EVENTS = { "UNIT_PET_EXPERIENCE", "UNIT_PET_TRAINING_POINTS" }

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

function PH:NotifyData()
    for _, fn in pairs(PH.dataConsumers) do fn() end
end

function PH:Wanted()
    return PH:IsSupported() and PH:IsHunter() and (next(PH.consumers) ~= nil or next(PH.dataConsumers) ~= nil)
end

-- The XP / training point events, on or off with the data consumers.
local function SetDataEvents(f, on)
    if on then
        -- UNIT_PET_EXPERIENCE fires for the OWNER (Blizzard's paper doll filters on
        -- "player"); UNIT_PET_TRAINING_POINTS' unit is unconfirmed, so it is not
        -- filtered (it fires only when points are spent or earned).
        if f.RegisterUnitEvent then
            pcall(f.RegisterUnitEvent, f, "UNIT_PET_EXPERIENCE", "player")
        else
            pcall(f.RegisterEvent, f, "UNIT_PET_EXPERIENCE")
        end
        pcall(f.RegisterEvent, f, "UNIT_PET_TRAINING_POINTS")
    elseif f.UnregisterEvent then
        for _, ev in ipairs(PH.DATA_EVENTS) do pcall(f.UnregisterEvent, f, ev) end
    end
end

function PH:UpdateRegistration()
    local want = PH:Wanted()
    local f = PH.driver
    if not want then
        if f and PH.registered then
            f:UnregisterAllEvents()
            PH.registered = false
            PH.dataRegistered = false
            PH.lastKey = nil
            DF:Debug("PET", "Pet Happiness: events off")
        end
        return
    end
    if not PH.registered then
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
        PH.dataRegistered = false
        DF:Debug("PET", "Pet Happiness: events on")
    end
    local wantData = next(PH.dataConsumers) ~= nil
    if wantData ~= PH.dataRegistered then
        SetDataEvents(f, wantData)
        PH.dataRegistered = wantData
        DF:Debug("PET", "Pet Happiness: XP / training point events %s", wantData and "on" or "off")
    end
end

function PH:OnEvent(event)
    if event == "PLAYER_ENTERING_WORLD" then
        -- The pet's state may not read yet straight after a loading screen.
        if C_Timer and C_Timer.After then
            C_Timer.After(0.5, function() PH:Notify(true); PH:NotifyData() end)
        else
            PH:Notify(true)
            PH:NotifyData()
        end
    elseif event == "UNIT_PET" then
        PH:Notify(true)
        PH:NotifyData()
    elseif event == "UNIT_HAPPINESS" then
        PH:Notify(false)
        -- Loyalty level has no event of its own: it is read again here as well.
        PH:NotifyData()
    else
        PH:NotifyData()       -- UNIT_PET_EXPERIENCE / UNIT_PET_TRAINING_POINTS
    end
end

-- on: whether this consumer shows the icon right now; fn: its repaint.
-- data: it also shows the pet's XP / training points / loyalty level / diet
-- (fn then runs on every pet-data event, not only on a change of mood).
function PH:SetConsumer(key, on, fn, data)
    local list = data and PH.dataConsumers or PH.consumers
    if on and type(fn) == "function" then
        list[key] = fn
    else
        list[key] = nil
    end
    PH:UpdateRegistration()
end

-- ------------------------------------------------------------
-- TEXT DESIGNER TOKENS (the unit frames pet frame)
-- Render.lua tells the core, on each full render of a live unit frames pet
-- frame, whether its template shows a pet token. While any does, one data
-- consumer refreshes those frames' "pet" elements on every pet-data event.
-- ------------------------------------------------------------
PH.tokenFrames = {}
local TOKEN_KEY = "td_tokens"

local function TokensChanged()
    for f in pairs(PH.tokenFrames) do
        if f.IsVisible and f:IsVisible() and DF.UpdateTextDesigner then DF:UpdateTextDesigner(f, "pet") end
    end
end

function PH:WatchTokens(frame, on)
    if not frame then return end
    on = (on and DF.IS_FOREVER) and true or nil
    if PH.tokenFrames[frame] == on and not (on and not PH.registered) then return end
    PH.tokenFrames[frame] = on
    PH:SetConsumer(TOKEN_KEY, next(PH.tokenFrames) ~= nil, TokensChanged, true)
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
-- TREND BADGE AND HIDE WHILE HAPPY (shared by both sides)
-- A small arrow on the face's bottom-right corner: down while the pet is losing
-- loyalty, up while gaining (mode BOTH only; a happy pet gains nearly all the
-- time, so an up arrow would show nearly always). The badge is a texture on the
-- icon, so it hides with it: Hide While Happy hides both.
-- Art: DandersFrames' own chevrons (shipped with the addon, so present on every
-- client), Blizzard's old arrow buttons if a build refuses the file, tinted red
-- (losing) / green (gaining) with a dark copy behind for contrast.
-- ⚠ UNVERIFIED IN GAME on Forever: the look at 16px / 14px.
-- ============================================================
PH.TREND_MODES = { "LOSING", "BOTH", "OFF" }
PH.TREND_DEFAULT = "LOSING"
PH.BADGE_SCALE = 0.45            -- of the face's size
PH.BADGE_ART = {
    [-1] = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more.png",
    [1] = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_less.png",
}
PH.BADGE_FALLBACK = { [-1] = "Interface\\Buttons\\Arrow-Down-Up", [1] = "Interface\\Buttons\\Arrow-Up-Up" }

-- The Loyalty Arrow dropdown: raw keys stored, labels localised here.
function PH.TrendOptions()
    local L = DF.L
    return { LOSING = L["Losing Only"], BOTH = L["Both"], OFF = L["Off"], _order = { "LOSING", "BOTH", "OFF" } }
end

-- The arrow for a loyalty rate under a mode: -1 down, 1 up, nil none.
-- An unknown / missing mode reads as the default (Losing Only).
function PH.TrendArrow(rate, mode)
    if mode == "OFF" or type(rate) ~= "number" then return nil end
    if rate < 0 then return -1 end
    if rate > 0 and mode == "BOTH" then return 1 end
    return nil
end

-- What one icon shows: the face's mood (nil = hidden) and the badge's arrow.
-- Hide While Happy hides a happy face, badge and all; never in test mode
-- (`preview`), so the icon can still be set up.
function PH.Resolve(mood, rate, hideHappy, mode, preview)
    if not mood then return nil, nil end
    if hideHappy and mood == 3 and not preview then return nil, nil end
    return mood, PH.TrendArrow(rate, mode)
end

local function SetBadgeFile(tex, dir)
    local ok = tex:SetTexture(PH.BADGE_ART[dir])
    if ok == false then ok = tex:SetTexture(PH.BADGE_FALLBACK[dir]) end
    return ok ~= false
end

function PH.NewBadge(icon)
    if icon.dfTrend then return icon.dfTrend end
    local shadow = icon:CreateTexture(nil, "OVERLAY", nil, 6)
    local b = icon:CreateTexture(nil, "OVERLAY", nil, 7)
    b.shadow = shadow
    shadow:Hide()
    b:Hide()
    icon.dfTrend = b
    return b
end

-- Sized from the face; its centre a quarter in from the bottom-right corner,
-- so it overhangs the face a little.
function PH.LayoutBadge(b, icon, size)
    size = tonumber(size) or 16
    if b.dfSize == size then return end
    b.dfSize = size
    local s = max(6, floor(size * PH.BADGE_SCALE + 0.5))
    local inset = floor(s / 4 + 0.5)
    b:SetSize(s, s)
    b:ClearAllPoints()
    b:SetPoint("CENTER", icon, "BOTTOMRIGHT", -inset, inset)
    b.shadow:SetSize(s, s)
    b.shadow:ClearAllPoints()
    b.shadow:SetPoint("CENTER", b, "CENTER", 1, -1)
end

-- dir: -1 / 1 / nil (hidden). Repaints the art only when the arrow changes.
function PH.PaintBadge(icon, dir, size)
    local b = icon.dfTrend
    if not dir then
        if b then
            b.dfDir = nil
            b:Hide()
            b.shadow:Hide()
        end
        return
    end
    b = b or PH.NewBadge(icon)
    PH.LayoutBadge(b, icon, size)
    if b.dfDir ~= dir then
        if not (SetBadgeFile(b, dir) and SetBadgeFile(b.shadow, dir)) then
            b.dfDir = nil
            b:Hide()
            b.shadow:Hide()
            return
        end
        local c = PH.TITLE_COLORS[dir < 0 and 1 or 3]
        b:SetVertexColor(c[1], c[2], c[3], 1)
        b.shadow:SetVertexColor(0, 0, 0, 0.9)
        b.dfDir = dir
    end
    b.shadow:Show()
    b:Show()
end

-- ============================================================
-- COLOUR BY HAPPINESS (shared by both sides)
-- The pet frame's border, name and health bar in the mood's colour. One set of
-- three colours per profile (DF.db.petHappinessColors, edited on the Colors
-- page), so it rides export / import with the other colours. Each target has
-- its own switch on each side; Only When Not Happy (on by default) leaves a
-- happy pet in its normal colours, so a colour change means something.
--
-- STAMPS, NOT READS. A side works out the three tints when the answer changes
-- (the consumer path) and stamps them on the frame: dfHappinessHealth,
-- dfHappinessBorder, dfHappinessName, each a colour or nil. The painters that
-- already exist read the stamp -- nil on every other frame, and on every frame
-- off Forever -- so no health tick reads the API and nothing is allocated.
-- ============================================================
PH.COLOR_KEYS = { [1] = "unhappy", [2] = "content", [3] = "happy" }
PH.COLOR_DEFAULTS = {
    happy   = { r = 0.35, g = 0.85, b = 0.35 },
    content = { r = 1,    g = 0.75, b = 0.2 },
    unhappy = { r = 0.95, g = 0.3,  b = 0.3 },
}
-- The Colors page's pickers, in order.
PH.COLOR_ORDER = { "happy", "content", "unhappy" }

if DF.IS_FOREVER and DF.RegisterProfileRootTable then
    DF:RegisterProfileRootTable("petHappinessColors", {
        defaults = PH.COLOR_DEFAULTS,
        exportCategory = "colors",
    })
end

-- The profile's colour for a mood (1..3); the default when the profile's is unusable.
function PH.Color(mood)
    local key = PH.COLOR_KEYS[mood]
    if not key then return nil end
    local t = DF.db and DF.db.petHappinessColors
    local c = type(t) == "table" and t[key]
    if type(c) ~= "table" or type(c.r) ~= "number" or type(c.g) ~= "number" or type(c.b) ~= "number" then
        c = PH.COLOR_DEFAULTS[key]
    end
    return c
end

-- The tint for a mood, or nil (paint normally): no pet, or happy while Only
-- When Not Happy is on (nil counts as on, the default).
function PH.Tint(mood, onlyUnhappy)
    if not PH.COLOR_KEYS[mood] then return nil end
    if mood == 3 and onlyUnhappy ~= false then return nil end
    return PH.Color(mood)
end

-- Every frame that has ever been tinted (weak), for a colour edit to reach.
PH.tinted = setmetatable({}, { __mode = "k" })

-- Has this frame a stamp to keep or to take back? (false: marked for a repaint)
function PH.HasTints(frame)
    return frame.dfHappinessHealth ~= nil or frame.dfHappinessBorder ~= nil or frame.dfHappinessName ~= nil
end

-- Stamp one frame's three tints and repaint only the targets whose tint moved.
-- `side` holds how that side paints each target, reading the stamp:
--   side.health(frame)      repaint the health bar
--   side.border(frame, c)   the tint, or nil: put the normal border back
--   side.name(frame, c)     the same for the name
--   side.refresh(frame)     work the tints out again (a colour edit)
-- ⚠ A frame with nothing stamped and nothing to stamp is left alone: its normal
-- painters already drew it, and nothing here may touch an untinted frame.
function PH.SetTints(frame, side, health, border, name)
    if not (health or border or name or PH.HasTints(frame)) then return end
    PH.tinted[frame] = true
    frame.dfHappinessSide = side
    if frame.dfHappinessHealth ~= health then
        frame.dfHappinessHealth = health
        side.health(frame)
    end
    if frame.dfHappinessBorder ~= border then
        frame.dfHappinessBorder = border
        side.border(frame, border)
    end
    if frame.dfHappinessName ~= name then
        frame.dfHappinessName = name
        side.name(frame, name)
    end
end

-- The border in a tint: colour only (the border's own SetColor), with the alpha
-- of the frame's own border colour. Called by both sides, and again by each
-- side's border painter after it repaints the normal border.
function PH.PaintBorder(border, c, base)
    if not (border and border.SetColor and c) then return end
    local a = type(base) == "table" and tonumber(base.a or base[4]) or 1
    border:SetColor(c.r, c.g, c.b, a)
end

-- Does any tint target ask for the answer? (health: the mode's own key value)
function PH.WantsTints(border, name, healthMode)
    return (border or name or healthMode == "HAPPINESS") and true or false
end

-- A colour edited (or reset) on the Colors page. A picker edits the colour table
-- in place, so a stamp still holds the same table and SetTints would see no
-- change: each tinted frame's stamps are marked stale (false) and its side works
-- them out again, which repaints every target.
function PH:ColorsChanged()
    for frame in pairs(PH.tinted) do
        local side = frame.dfHappinessSide
        if side and PH.HasTints(frame) then
            if frame.dfHappinessHealth ~= nil then frame.dfHappinessHealth = false end
            if frame.dfHappinessBorder ~= nil then frame.dfHappinessBorder = false end
            if frame.dfHappinessName ~= nil then frame.dfHappinessName = false end
            side.refresh(frame)
        end
    end
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

-- ------------------------------------------------------------
-- The group pet frame's tints (COLOUR BY HAPPINESS above). The settings are
-- petHappinessColorBorder / petHappinessColorName / petHappinessColorOnlyUnhappy
-- and the health mode petHealthColorMode = "HAPPINESS", whose painter is
-- DF:ApplyPetHealthColor (Pets.lua): the stamp, else the normal health colour.
-- ------------------------------------------------------------
local WHITE = { r = 1, g = 1, b = 1 }

local function GroupOwnerUnit(unit)
    local owner = unit:gsub("pet", "")
    if owner == "" then owner = "player" end
    return owner
end

local GROUP_SIDE = {}

function GROUP_SIDE.health(frame)
    if not (DF.ApplyPetHealthColor and frame.healthBar and type(frame.unit) == "string") then return end
    local db = DF:GetFrameDB(frame)
    if not db then return end
    if frame.dfIsTestFrame then
        -- The preview's own sample: the fraction already on the bar, the owner's class.
        local pct = frame.healthBar.GetValue and frame.healthBar:GetValue()
        local data = frame.ownerFrame and DF.GetTestDataForFrame and DF:GetTestDataForFrame(frame.ownerFrame)
        DF:ApplyPetHealthColor(frame, db, nil, frame.unit,
            { pct = type(pct) == "number" and pct or 1, class = data and data.class })
    else
        DF:ApplyPetHealthColor(frame, db, GroupOwnerUnit(frame.unit), frame.unit)
    end
end

function GROUP_SIDE.border(frame, c)
    if not frame.border then return end
    local db = DF:GetFrameDB(frame)
    if c then
        PH.PaintBorder(frame.border, c, db and db.petBorderColor)
    elseif db and DF.Border then
        DF.Border:Apply(frame.border, DF.Border:BuildSpec(db, "pet"))
    end
end

function GROUP_SIDE.name(frame, c)
    local fs = frame.nameText
    if not fs then return end
    if not c then
        local db = DF:GetFrameDB(frame)
        c = (db and type(db.petNameColor) == "table" and db.petNameColor) or WHITE
    end
    fs:SetTextColor(c.r, c.g, c.b)
end

function GROUP_SIDE.refresh(frame)
    PH:UpdateGroupFrame(frame)
end

PH.GROUP_SIDE = GROUP_SIDE

-- mood: the pet's (nil: not your pet, or nothing asks for it).
function PH.GroupTints(frame, db, mood)
    local tint = db and PH.Tint(mood, db.petHappinessColorOnlyUnhappy)
    local health = (tint and db.petHealthColorMode == "HAPPINESS") and tint or nil
    local border = (tint and db.petHappinessColorBorder) and tint or nil
    local name = (tint and db.petHappinessColorName) and tint or nil
    PH.SetTints(frame, GROUP_SIDE, health, border, name)
end

-- Lay out and paint one group pet frame's face and tints (Pets.lua calls this
-- when the frame is styled or updated). Forever only.
function PH:UpdateGroupFrame(frame)
    if not (DF.IS_FOREVER and frame) then return end
    local db = DF:GetFrameDB(frame)
    local test = frame.dfIsTestFrame
    local icon = frame.dfHappinessIcon
    if not test then
        PH:WatchGroup()
        PH:WatchFrameFade()
    end
    local own = db and PH.IsOwnPetFrame(frame)
    local showIcon = own and db.petHappinessIconEnabled
    local tints = own and PH.WantsTints(db.petHappinessColorBorder, db.petHappinessColorName, db.petHealthColorMode)
    local mood, rate
    if showIcon or tints then
        if test then
            local data = frame.ownerFrame and DF.GetTestDataForFrame and DF:GetTestDataForFrame(frame.ownerFrame)
            mood = (data and data.petHappiness) or PH.MOCK.mood
            rate = (data and data.petLoyaltyRate) or PH.MOCK.rate
        else
            local _
            mood, _, rate = PH:Read()
        end
    end
    if showIcon then
        icon = icon or PH.NewGroupIcon(frame)
        PH.LayoutGroupIcon(icon, frame, db)
        local face, dir = PH.Resolve(mood, rate, db.petHappinessIconHideHappy, db.petHappinessIconTrend, test)
        PH.PaintGroupIcon(icon, face)
        PH.PaintBadge(icon, face and dir or nil, db.petHappinessIconSize or 14)
    elseif icon then
        PH.PaintGroupIcon(icon, nil)
    end
    PH.GroupTints(frame, db, tints and mood or nil)
end

-- The live group pet frames that could be yours, repainted when the answer
-- changes (the shared event driver calls this).
local function GroupFramesChanged()
    if DF.petFrames and DF.petFrames.player then PH:UpdateGroupFrame(DF.petFrames.player) end
    for n = 1, 2 do
        local set = (n == 1) and DF.raidPetFrames or DF.arenaPetFrames
        if set then
            for i = 1, 40 do
                local f = set[i]
                -- A frame that had the face or a tint (to repaint or drop it), or the one that is yours now.
                if f and (f.dfHappinessIcon or PH.HasTints(f) or PH.IsOwnPetFrame(f)) then PH:UpdateGroupFrame(f) end
            end
        end
    end
end
PH.GroupFramesChanged = GroupFramesChanged

local GROUP_DB_GETTERS = { "GetDB", "GetRaidDB" }

-- Asks for the events while either group mode (party, raid) shows the face or
-- colours by happiness.
function PH:WantsGroup()
    if not DF.IS_FOREVER then return false end
    for _, get in ipairs(GROUP_DB_GETTERS) do
        local db = DF[get] and DF[get](DF)
        if db and db.petEnabled and (db.petHappinessIconEnabled
            or PH.WantsTints(db.petHappinessColorBorder, db.petHappinessColorName, db.petHealthColorMode)) then
            return true
        end
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

-- ============================================================
-- FRAME FADE: "SHOW WHEN PET IS NOT HAPPY" (frameFadeRevealUnhappyPet)
-- DF:GetFrameBaseAlpha reveals your own pet's frame through Frame Fade while
-- PH.fadeMood is below 3 (Content or Unhappy). It is on the health hot path,
-- so it reads this cached mood and never calls C_PetInfo itself; the consumer
-- below keeps the cache and repaints your pet's frames when the mood moves.
-- Alpha only, so it applies in combat too.
-- ============================================================
local FADE_KEY = "frame_fade"
PH.fadeMood = nil

function PH:WantsFrameFade()
    if not PH:IsSupported() then return false end
    for _, get in ipairs(GROUP_DB_GETTERS) do
        local db = DF[get] and DF[get](DF)
        if db and db.frameFadeRevealUnhappyPet then return true end
    end
    local UF = DF.UnitFrames
    local udb = UF and UF.GetUnitDB and UF:GetUnitDB("pet")
    return (udb and udb.frameFadeRevealUnhappyPet) and true or false
end

-- Your pet's frames: the group player-pet frame, your raid pet frame, the unit
-- frames pet frame. Group pet frames re-apply their fade only on a range-cache
-- miss, so their cache entry is dropped first.
local function RefreshOwnPetFrameFade()
    local function group(f)
        if not (f and f.unit and PH.IsOwnPetFrame(f)) then return end
        if DF.ClearRangeCacheForUnit then DF:ClearRangeCacheForUnit(f.unit) end
        if DF.UpdatePetRange then DF:UpdatePetRange(f) end
        if DF.UpdatePetHealthFade then DF:UpdatePetHealthFade(f) end
    end
    if DF.petFrames then group(DF.petFrames.player) end
    for _, set in ipairs({ DF.raidPetFrames or false, DF.arenaPetFrames or false }) do
        if set then
            for i = 1, 40 do group(set[i]) end
        end
    end
    local UF = DF.UnitFrames
    local uf = UF and UF.frames and UF.frames.pet
    if uf and uf.IsVisible and uf:IsVisible() then
        if DF.RefreshFrameFadeOn then DF.RefreshFrameFadeOn(uf) end
        if DF.UpdateHealthFade then DF:UpdateHealthFade(uf) end
    end
end

local function FadeMoodChanged()
    local mood = PH:Read()
    if mood == PH.fadeMood then return end
    PH.fadeMood = mood
    RefreshOwnPetFrameFade()
end

-- Called from the Fading page's checkbox, from every group pet frame update (next
-- to WatchGroup) and on entering the world.
function PH:WatchFrameFade()
    local on = PH:WantsFrameFade()
    if on == PH.fadeOn and not (on and not PH.registered) then return end
    PH.fadeOn = on
    PH:SetConsumer(FADE_KEY, on, FadeMoodChanged)
    if on then
        FadeMoodChanged()
    elseif PH.fadeMood ~= nil then
        PH.fadeMood = nil
        RefreshOwnPetFrameFade()
    end
end

if CreateFrame and DF.IS_FOREVER then
    local pew = CreateFrame("Frame")
    pew:RegisterEvent("PLAYER_ENTERING_WORLD")
    pew:SetScript("OnEvent", function() PH:WatchFrameFade() end)
end
