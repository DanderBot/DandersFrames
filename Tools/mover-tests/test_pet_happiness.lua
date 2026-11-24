-- ============================================================
-- PET HAPPINESS (WoW Forever only)
-- DandersFrames/Features/PetHappiness.lua (the shared core) and the unit frames
-- pet icon (DandersFrames_UnitFrames/Indicators.lua, PET HAPPINESS).
-- ------------------------------------------------------------
-- The core: gated to Forever + a hunter pet, a secret answer reads as nil, the
-- atlas with the old texture as the fallback, the tooltip's lines (Blizzard's
-- globals first, our fallbacks, missing answers left out), events registered
-- only while a consumer is on and the consumer told only on a change.
-- The UF side: the pet gets the icon on Forever only, the defaults, the outside
-- position, hidden in a vehicle, the preview sample. The settings page by source.
-- ============================================================

local G, G_NAMES = {}, { "DandersFrames", "CreateFrame", "issecretvalue", "LibStub", "IsResting",
    "UnitIsPVP", "UnitIsPVPFreeForAll", "UnitFactionGroup", "UnitClassification", "UnitExists",
    "C_PetInfo", "HasPetUI", "UnitClass", "C_Texture", "GameTooltip", "GetPetExperience",
    "PET_HAPPINESS1", "PET_HAPPINESS2", "PET_HAPPINESS3", "PET_DAMAGE_PERCENTAGE", "GAINING_LOYALTY",
    "LOSING_LOYALTY", "PET_DIET_TEMPLATE", "PET_FOOD_DELIMIT", "TRAINING_POINTS", "XP_STATUS_BAR_TEXT",
    "BreakUpLargeNumbers", "C_Timer", "InCombatLockdown" }
for _, k in ipairs(G_NAMES) do G[k] = _G[k] end

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

local secrets = setmetatable({}, { __mode = "k" })
local function Secret(label) local t = { label = label }; secrets[t] = true; return t end
issecretvalue = function(v) return type(v) == "table" and secrets[v] == true end

-- Frames that record their event registrations.
local function Make(kind, parent)
    local f = setmetatable(FakeUIFrame(0, 0), nil)
    f._kind, f._shown = kind, true
    f._events = {}
    f:SetFakeParent(parent)
    function f:SetParent(p) self:SetFakeParent(p) end
    function f:RegisterEvent(e) self._events[e] = true end
    function f:RegisterUnitEvent(e) self._events[e] = true end
    function f:UnregisterAllEvents() self._events = {} end
    function f:CreateTexture() return Make("Texture", self) end
    function f:CreateFontString() return Make("FontString", self) end
    function f:SetAtlas(a) self._atlas = a end
    function f:SetTextColor() end
    function f:EnableMouseMotion(on) self._motion = on end
    function f:SetMouseClickEnabled(on) self._clicks = on end
    return f
end
CreateFrame = function(kind, _, parent) return Make(kind, parent) end
LibStub = nil
InCombatLockdown = function() return false end
C_Timer = { After = function(_, fn) fn() end }
BreakUpLargeNumbers = function(n) return tostring(n) end

-- The pet API, as the Forever docs describe it.
local mood, damage, rate = 3, 125, 1
local hasUI, hunterPet = true, true
local atlases = { ["UI-PetHappiness"] = true, ["UI-PetNeutral"] = true, ["UI-PetMad"] = true }
local loyalty, foods, tp, xp = "Loyalty Level 6 (Best Friend)", { "Meat", "Fish" }, { 150, 30 }, { 1200, 4800 }
C_PetInfo = {
    GetPetHappiness = function() if mood == nil then return end return mood, damage, rate end,
    GetPetLoyalty = function() return loyalty end,
    GetPetFoodTypes = function() return foods end,
    GetPetTrainingPoints = function() return tp[1], tp[2] end,
}
GetPetExperience = function() return xp[1], xp[2] end
HasPetUI = function() return hasUI, hunterPet end
local class = "HUNTER"
UnitClass = function() return "Hunter", class end
C_Texture = { GetAtlasInfo = function(a) return atlases[a] and {} or nil end }
UnitExists = function() return true end
IsResting = function() return false end
UnitIsPVP = function() return false end
UnitIsPVPFreeForAll = function() return false end
UnitFactionGroup = function() return "Horde" end
UnitClassification = function() return "normal" end

local tip = { lines = {} }
function tip:SetOwner(o, a) self.owner, self.anchor = o, a end
function tip:ClearLines() self.lines = {} end
function tip:AddLine(t) self.lines[#self.lines + 1] = t end
function tip:Show() self.shown = true end
function tip:Hide() self.shown = false end
GameTooltip = tip

-- Blizzard's globals (localised by the client).
PET_HAPPINESS1, PET_HAPPINESS2, PET_HAPPINESS3 = "Unhappy", "Content", "Happy"
PET_DAMAGE_PERCENTAGE = "Pet is doing %d%% damage"
GAINING_LOYALTY, LOSING_LOYALTY = "Gaining loyalty", "Losing loyalty"
PET_DIET_TEMPLATE, PET_FOOD_DELIMIT = "Diet: %s", ", "
TRAINING_POINTS = "Training Points: %d"
XP_STATUS_BAR_TEXT = "XP: %s/%s"

local function NewDF(forever)
    local DF = { PartyDefaults = { frameWidth = 125, frameHeight = 40 }, registered = {}, IS_FOREVER = forever }
    DF.L = setmetatable({}, { __index = function(_, k) return k end })
    function DF:Debug() end
    function DF:DebugWarn() end
    DF.errs = {}
    function DF:DebugError(_, fmt, ...) DF.errs[#DF.errs + 1] = string.format(fmt, ...) end
    function DF:DeepCopy(t) return deepcopy(t) end
    function DF:RegisterProfileRootTable(key, spec) self.registered[key] = spec; return true end
    function DF:SafeSetFont() end
    function DF:UpdateCombatIcon() end
    load_df_file_into("Features/PetHappiness.lua", DF)
    return DF
end

-- ============================================================
print("-- Core: gating")
do
    local R = NewDF(false)
    local PH = R.PetHappiness
    check(PH ~= nil, "retail: the table exists (callers stay nil-safe)")
    eq(PH:IsSupported(), false, "retail: not supported")
    eq(PH:Read(), nil, "retail: no answer")
    PH:SetConsumer("x", true, function() end)
    eq(PH.registered, nil, "retail: a consumer registers no events")
    eq(PH.driver, nil, "...and builds no frame")
end

local DF = NewDF(true)
local PH = DF.PetHappiness
eq(PH:IsSupported(), true, "Forever: supported")
eq(select("#", PH:Read()), 3, "three answers")
local m, d, r = PH:Read()
eq(m, 3, "happy"); eq(d, 125, "125%"); eq(r, 1, "gaining")
hunterPet = false
eq(PH:Read(), nil, "not a hunter pet (a warlock's demon): nothing")
hunterPet = true
mood = nil
eq(PH:Read(), nil, "no pet: the API returns nothing")
mood = 4
eq(PH:Read(), nil, "out of range: nothing")
mood = Secret("mood")
eq(PH:Read(), nil, "a secret mood: hidden, never guessed")
mood = 2
damage, rate = Secret("dmg"), Secret("rate")
m, d, r = PH:Read()
eq(m, 2, "secret damage / rate: the mood still reads")
eq(d, nil, "...damage left out"); eq(r, nil, "...rate left out")
damage, rate = 100, 0

print("-- Core: art")
local tex = Make("Texture")
check(PH:SetArt(tex, 3), "happy: painted")
eq(tex._atlas, "UI-PetHappiness", "the happy atlas")
PH:SetArt(tex, 2); eq(tex._atlas, "UI-PetNeutral", "content atlas")
PH:SetArt(tex, 1); eq(tex._atlas, "UI-PetMad", "unhappy atlas")
atlases["UI-PetMad"] = nil
local t2 = Make("Texture")
PH:SetArt(t2, 1)
eq(t2._atlas, nil, "no atlas on this build: no SetAtlas")
eq(t2._texture, PH.FILE, "...the old paper-doll texture")
eq(t2._texCoord[1], 0.375, "...cropped to the unhappy face")
atlases["UI-PetMad"] = true
eq(PH:SetArt(t2, 7), false, "an unknown mood: nothing painted")

print("-- Core: tooltip")
mood, damage, rate = 3, 125, 1
local lines = PH:TooltipLines()
local texts = {}
for i, l in ipairs(lines) do texts[i] = l.text end
eq(texts[1], "Happy", "title: the mood")
eq(texts[2], "Pet is doing 125% damage", "damage")
eq(texts[3], "Gaining loyalty", "loyalty trend")
eq(texts[4], "Loyalty Level 6 (Best Friend)", "loyalty level, as the API words it")
eq(texts[5], "Diet: Meat, Fish", "diet")
eq(texts[6], "Training Points: 120", "training points available (total - used)")
eq(texts[7], "XP: 1200/4800", "experience")
eq(#texts, 7, "seven lines")
eq(lines[1].r, PH.TITLE_COLORS[3][1], "title coloured by mood")
rate = -1
eq(PH:TooltipLines()[3].text, "Losing loyalty", "losing loyalty")
rate = 0
eq(PH:TooltipLines()[3].text, "Loyalty Level 6 (Best Friend)", "no trend: no trend line")
rate = 1
-- Missing answers drop their lines; a missing global falls back to ours.
loyalty, foods, xp = nil, {}, { 0, 0 }
TRAINING_POINTS = nil
PET_DAMAGE_PERCENTAGE = "Damage"           -- a build whose string has no %d
lines = PH:TooltipLines()
texts = {}
for i, l in ipairs(lines) do texts[i] = l.text end
eq(texts[2], "Damage 125", "a global without its placeholder keeps the number")
eq(texts[4], "Training Points: 120", "missing global: our fallback")
eq(#texts, 4, "no loyalty, diet or XP (max level): those lines left out")
loyalty, foods, xp = "Loyalty Level 6 (Best Friend)", { "Meat", "Fish" }, { 1200, 4800 }
TRAINING_POINTS, PET_DAMAGE_PERCENTAGE = "Training Points: %d", "Pet is doing %d%% damage"
mood = nil
eq(#PH:TooltipLines(), 0, "no pet: no lines")
local mock = PH:TooltipLines(true)
eq(mock[1].text, "Happy", "the test-mode sample reads without a pet")
eq(#mock, 7, "...every line")
mood = 3
local owner = Make("Frame")
PH:ShowTooltip(owner)
check(tip.shown and tip.owner == owner, "ShowTooltip: on the icon")
eq(tip.anchor, "ANCHOR_RIGHT", "...to its right, like Blizzard's")
eq(#tip.lines, 7, "...with the lines")
PH:HideTooltip()
check(not tip.shown, "HideTooltip")

print("-- Core: events and change-only repaints")
eq(PH.registered, nil, "no consumer: no events")
local calls = 0
PH:SetConsumer("a", true, function() calls = calls + 1 end)
eq(PH.registered, true, "a consumer: events on")
local ev = PH.driver._events
check(ev.UNIT_HAPPINESS and ev.UNIT_PET and ev.PLAYER_ENTERING_WORLD, "UNIT_HAPPINESS, UNIT_PET, PLAYER_ENTERING_WORLD")
PH:OnEvent("UNIT_HAPPINESS")
eq(calls, 1, "first answer: told")
PH:OnEvent("UNIT_HAPPINESS")
eq(calls, 1, "the same answer again: not told")
mood = 1
PH:OnEvent("UNIT_HAPPINESS")
eq(calls, 2, "the mood changed: told")
rate = 2
PH:OnEvent("UNIT_HAPPINESS")
eq(calls, 2, "a different gain rate, same trend: not told")
PH:OnEvent("UNIT_PET")
eq(calls, 3, "a new pet: always told")
PH:OnEvent("PLAYER_ENTERING_WORLD")
eq(calls, 4, "after a loading screen: told once (deferred)")
PH:SetConsumer("a", false)
eq(PH.registered, false, "the last consumer off: events off")
eq(next(PH.driver._events), nil, "...every event unregistered")
-- Not a hunter: never registered.
do
    class = "WARLOCK"
    local W = NewDF(true)
    W.PetHappiness:SetConsumer("a", true, function() end)
    eq(W.PetHappiness.registered, nil, "a warlock: no events")
    class = "HUNTER"
end
mood, rate = 3, 1

-- ============================================================
print("-- Unit frames: the pet icon")
local function LoadUF(host)
    DandersFrames = host
    local UF = {}
    load_uf_file_into("Core.lua", UF)
    load_uf_file_into("Defaults.lua", UF)
    host.db = { unitframes = deepcopy(host.registered.unitframes.defaults) }
    load_uf_file_into("Elements.lua", UF)
    load_uf_file_into("Indicators.lua", UF)
    return UF
end

do
    local RUF = LoadUF(NewDF(false))
    eq(RUF.Indicators.ICONS.happiness, nil, "retail: no happiness icon at all")
end

local UF = LoadUF(DF)
local IN = UF.Indicators
local function Owner(unit)
    local f = Make("Button", UIParent)
    f.dfUFUnit, f.unit = unit, unit
    f.dfDB = UF:GetUnitDB(unit)
    return f
end
local PET = Owner("pet")
IN:Attach(PET)
check(PET.dfUFIcons and PET.dfUFIcons.happiness, "Forever: the pet gets the icon")
eq(IN.ICONS.happiness.player, nil, "...the player does not")
eq(IN.ICONS.happiness.target, nil, "...nor the target")

local pdb = UF:GetUnitDB("pet")
eq(pdb.happinessIconEnabled, true, "default: on")
eq(pdb.happinessIconSize, 16, "default: 16px")
eq(pdb.happinessIconAnchor, "OUTSIDE_RIGHT", "default: outside the right edge")
eq(pdb.happinessIconX, 2, "...2px out"); eq(pdb.happinessIconY, 0, "...centred")
eq(pdb.happinessIconTooltip, true, "default: tooltip on")

local icon = PET.dfUFIcons.happiness
IN:Layout(PET)
local pt = icon._points[#icon._points]
eq(pt[1], "LEFT", "outside right: the icon's left edge...")
eq(pt[2], PET, "...on the pet frame's...")
eq(pt[3], "RIGHT", "...right edge")
eq(pt[4], 2, "...2px out")
eq(icon._w, 16, "16px")
eq(icon._motion, true, "tooltip on: hover reaches the icon")
eq(icon._clicks, false, "...clicks never stop at it")
check(icon:IsShown(), "a happy hunter pet: shown")
eq(icon.tex._atlas, "UI-PetHappiness", "...the happy face")
check(DF.PetHappiness.consumers.uf_pet ~= nil, "the live pet frame asks for the events")

mood = 1
DF.PetHappiness:OnEvent("UNIT_HAPPINESS")
eq(icon.tex._atlas, "UI-PetMad", "UNIT_HAPPINESS: repainted unhappy")
icon.tex._atlas = "sentinel"
IN:Update(PET)
eq(icon.tex._atlas, "sentinel", "the same mood: not repainted")
mood = 3
IN:Update(PET)
eq(icon.tex._atlas, "UI-PetHappiness", "a new mood: repainted")

PET.unit = "player"           -- a vehicle: the pet frame shows you
IN:Update(PET)
check(not icon:IsShown(), "in a vehicle: hidden")
PET.unit = "pet"
hunterPet = false
IN:Update(PET)
check(not icon:IsShown(), "not a hunter pet: hidden")
hunterPet = true

pdb.happinessIconAnchor = "TOPLEFT"
pdb.happinessIconX, pdb.happinessIconY = 3, -4
IN:Layout(PET)
pt = icon._points[#icon._points]
eq(pt[1] .. pt[3], "TOPLEFTTOPLEFT", "an inside point")
eq(pt[4] .. "," .. pt[5], "3,-4", "...with its offsets")
pdb.happinessIconAnchor, pdb.happinessIconX, pdb.happinessIconY = nil, nil, nil

pdb.happinessIconTooltip = false
IN:Layout(PET)
eq(icon._motion, false, "tooltip off: the mouse passes through")
icon:GetScript("OnEnter")(icon)
check(not tip.shown, "...and no tooltip")
pdb.happinessIconTooltip = nil
IN:Layout(PET)
icon:GetScript("OnEnter")(icon)
check(tip.shown and tip.lines[1] == "Happy", "hover: the tooltip")
icon:GetScript("OnLeave")(icon)
check(not tip.shown, "leave: hidden")

pdb.happinessIconEnabled = false
IN:Layout(PET)
check(not icon:IsShown(), "switched off: hidden")
eq(DF.PetHappiness.consumers.uf_pet, nil, "...and no longer asks for events")
eq(DF.PetHappiness.registered, false, "...so they are unregistered")
pdb.happinessIconEnabled = nil

print("-- Unit frames: preview")
mood = nil                    -- no pet at all
local PV = Owner("pet")
PV.dfUFPreview = true
IN:Attach(PV)
IN:Preview(PV)
check(PV.dfUFIcons.happiness:IsShown(), "test mode: the sample shows without a pet")
eq(PV.dfUFIcons.happiness.tex._atlas, "UI-PetHappiness", "...a happy pet")
PV.dfUFIcons.happiness:GetScript("OnEnter")(PV.dfUFIcons.happiness)
eq(#tip.lines, 7, "...its tooltip shows the sample lines")
PV.dfTestData = { petHappiness = 1 }
IN:Preview(PV)
eq(PV.dfUFIcons.happiness.tex._atlas, "UI-PetMad", "test data can pick the mood")
mood = 3
eq(#DF.errs, 0, "no element errored (" .. tostring(DF.errs[1]) .. ")")

-- ============================================================
print("-- Settings page (source)")
local pages = options_file_source("UnitFrames/Pages.lua")
check(pages:find('card = "pet_happiness", prefix = "happinessIcon"', 1, true), "a Pet Happiness card")
check(pages:find("forever = true", 1, true), "...Forever only")
check(pages:find('(DF.IS_FOREVER or not c.forever)', 1, true), "...skipped off Forever")
check(pages:find('"classBorder", "happinessIcon" }', 1, true), "the page's keys include happinessIcon (links, reset)")
check(pages:find('"happinessIconTooltip"', 1, true), "a Show Tooltip control")
check(pages:find("UFO.AddForeverPetIcons(DF.UnitFramePageData)", 1, true), "the pet gets the page on Forever")
-- The page-data patch itself.
do
    local held = DandersFrames
    local data = { pages = { { kind = "unitIcons", units = { player = true }, cards = {} }, { kind = "frame", units = {} } } }
    local a = pages:find("function UFO.AddForeverPetIcons", 1, true)
    local b = pages:find("UFO.AddForeverPetIcons(DF.UnitFramePageData)", 1, true)
    local UFO = {}
    local fn = assert(loadstring("local UFO, DF, ipairs = ... " .. pages:sub(a, b - 1)))
    fn(UFO, { IS_FOREVER = false }, ipairs)
    UFO.AddForeverPetIcons(data)
    eq(data.pages[1].units.pet, nil, "retail: no pet Unit Icons page")
    fn(UFO, { IS_FOREVER = true }, ipairs)
    UFO.AddForeverPetIcons(data)
    eq(data.pages[1].units.pet, true, "Forever: the pet has the page")
    eq(data.pages[1].cards.pet_happiness.pet, true, "...with the card")
    eq(data.pages[2].units.pet, nil, "...other pages untouched")
    DandersFrames = held
end

print("-- Strings")
local enUS = df_file_source("Locales/enUS.lua")
for _, k in ipairs({ "Pet Happiness", "Show Tooltip", "Outside Right", "Outside Left", "Outside Top",
                     "Outside Bottom", "Happy", "Content", "Unhappy", "Gaining loyalty", "Losing loyalty",
                     "Pet is doing %d%% damage", "Diet: %s", "Training Points: %d", "XP: %s / %s",
                     "Loyalty Level %d", "Meat", "Fish",
                     "Hover the face to see your pet's damage, loyalty, diet, training points and experience.",
                     "Show whether your hunter pet is happy, content or unhappy, beside the pet frame." }) do
    check(enUS:find('L["' .. k .. '"] = true', 1, true), "enUS: " .. k)
end
check(df_file_source("DandersFrames.toc"):find("Features\\PetHappiness.lua", 1, true), "listed in the resident TOC")

for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
