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
    function f:UnregisterEvent(e) self._events[e] = nil end
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
eq(mock[1].text, "Unhappy", "the test-mode sample (unhappy, losing loyalty) reads without a pet")
eq(mock[3].text, "Losing loyalty", "...losing loyalty, so the Losing Only arrow shows in test mode")
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
eq(PV.dfUFIcons.happiness.tex._atlas, "UI-PetMad", "...an unhappy pet")
PV.dfUFIcons.happiness:GetScript("OnEnter")(PV.dfUFIcons.happiness)
eq(#tip.lines, 7, "...its tooltip shows the sample lines")
PV.dfTestData = { petHappiness = 3 }
IN:Preview(PV)
eq(PV.dfUFIcons.happiness.tex._atlas, "UI-PetHappiness", "test data can pick the mood")
PV.dfTestData = nil
mood = 3
eq(#DF.errs, 0, "no element errored (" .. tostring(DF.errs[1]) .. ")")

-- ============================================================
print("-- Settings page (source)")
local pages = options_file_source("UnitFrames/Pages.lua")
check(pages:find('card = "pet_happiness", prefix = "happinessIcon"', 1, true), "a Pet Happiness card")
check(pages:find("forever = true", 1, true), "...Forever only")
check(pages:find('(DF.IS_FOREVER or not c.forever)', 1, true), "...skipped off Forever")
check(pages:find('"classBorder", "happinessIcon", "happinessColor" }', 1, true), "the page's keys include happinessIcon and happinessColor (links, reset)")
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

-- ============================================================
-- GROUP PET FRAMES (phase 2): Features/PetHappiness.lua GROUP PET FRAMES, driven
-- from Frames/Pets.lua.
-- ============================================================
print("-- Group pet frames: defaults and export")
local cfg = df_file_source("Core/Config.lua")
local exportSrc = options_file_source("Core/ExportCategories.lua")
for _, kv in ipairs({ { "petHappinessIconEnabled", "true" }, { "petHappinessIconSize", "14" },
                      { "petHappinessIconAnchor", '"OUTSIDE_RIGHT"' }, { "petHappinessIconX", "2" },
                      { "petHappinessIconY", "0" }, { "petHappinessIconTooltip", "true" } }) do
    check(cfg:find("    " .. kv[1] .. " = " .. kv[2] .. ",", 1, true), "PartyDefaults: " .. kv[1] .. " = " .. kv[2])
    check(exportSrc:find('"' .. kv[1] .. '",', 1, true), "export: " .. kv[1])
end

print("-- Group pet frames: own pet only")
local gdb = { petEnabled = true, petHappinessIconEnabled = true, petHappinessIconSize = 14,
              petHappinessIconAnchor = "OUTSIDE_RIGHT", petHappinessIconX = 2, petHappinessIconY = 0,
              petHappinessIconTooltip = true }
local rdb = { petEnabled = false, petHappinessIconEnabled = true }
function DF:GetDB() return gdb end
function DF:GetRaidDB() return rdb end
function DF:GetFrameDB(f) return f.isRaidFrame and rdb or gdb end
local yours = {}                     -- unit token -> is it your pet
function DF.UnitIsUnit(a, b)
    if b ~= "pet" then return nil end
    return yours[a] == true
end
local function PetFrame(unit, raid, test)
    local f = Make("Button", UIParent)
    f.unit, f.isRaidFrame, f.dfIsTestFrame, f.isPetFrame = unit, raid, test, true
    return f
end
DF.petFrames, DF.raidPetFrames, DF.arenaPetFrames, DF.partyPetFrames = {}, {}, {}, {}

local GP = DF.PetHappiness
local own = PetFrame("pet")
DF.petFrames.player = own
GP:UpdateGroupFrame(own)
local gi = own.dfHappinessIcon
check(gi and gi:IsShown(), "party: your pet's frame shows the face")
eq(gi.tex._atlas, "UI-PetHappiness", "...happy")
eq(gi._w, 14, "...14px")
local gpt = gi._points[#gi._points]
eq(gpt[1] .. ">" .. gpt[3], "LEFT>RIGHT", "...outside the right edge")
eq(gpt[2], own, "...of the pet frame")
eq(gpt[4], 2, "...2px out")
eq(gi._motion, true, "...hover reaches it")
eq(gi._clicks, false, "...clicks never stop at it")
check(GP.consumers.group_pet ~= nil, "the group side asks for the events under its own key")

local partyPet = PetFrame("partypet1")
GP:UpdateGroupFrame(partyPet)
eq(partyPet.dfHappinessIcon, nil, "a party member's pet: no face, nothing built")

local raidOther, raidMine = PetFrame("raidpet3", true), PetFrame("raidpet7", true)
DF.raidPetFrames[3], DF.raidPetFrames[7] = raidOther, raidMine
rdb.petEnabled = true
yours.raidpet7 = true
GP:UpdateGroupFrame(raidOther)
GP:UpdateGroupFrame(raidMine)
eq(raidOther.dfHappinessIcon, nil, "raid: someone else's pet gets no face")
check(raidMine.dfHappinessIcon and raidMine.dfHappinessIcon:IsShown(), "raid: the raidpet<N> that is yours gets it")
yours.raidpet7 = nil
GP:UpdateGroupFrame(raidMine)
check(not raidMine.dfHappinessIcon:IsShown(), "raid: the roster moved, that frame is not yours now: hidden")
yours.raidpet7 = true
local heldUIU = DF.UnitIsUnit
DF.UnitIsUnit = function() return nil end    -- withheld (secret / not comparable)
GP:UpdateGroupFrame(raidMine)
check(not raidMine.dfHappinessIcon:IsShown(), "raid: an unanswerable comparison reads as not yours")
DF.UnitIsUnit = heldUIU
GP:UpdateGroupFrame(raidMine)

print("-- Group pet frames: events and repaints")
mood = 1
GP:OnEvent("UNIT_HAPPINESS")
eq(gi.tex._atlas, "UI-PetMad", "UNIT_HAPPINESS: the party pet frame repainted")
eq(raidMine.dfHappinessIcon.tex._atlas, "UI-PetMad", "...and your raid pet frame")
mood = 3
GP:OnEvent("UNIT_HAPPINESS")
hunterPet = false
GP:UpdateGroupFrame(own)
check(not gi:IsShown(), "not a hunter pet (vehicle / demon): hidden")
hunterPet = true
GP:UpdateGroupFrame(own)

gdb.petHappinessIconTooltip = false
GP:UpdateGroupFrame(own)
eq(gi._motion, false, "tooltip off: the mouse passes through")
tip:Hide()
gi:GetScript("OnEnter")(gi)
check(not tip.shown, "...no tooltip")
gdb.petHappinessIconTooltip = true
GP:UpdateGroupFrame(own)
gi:GetScript("OnEnter")(gi)
check(tip.shown and tip.lines[1] == "Happy" and tip.owner == gi, "hover: the tooltip on the face")
gi:GetScript("OnLeave")(gi)
check(not tip.shown, "leave: hidden")

gdb.petHappinessIconAnchor, gdb.petHappinessIconX, gdb.petHappinessIconY = "TOPLEFT", 1, -1
GP:UpdateGroupFrame(own)
gpt = gi._points[#gi._points]
eq(gpt[1] .. gpt[3] .. gpt[4] .. gpt[5], "TOPLEFTTOPLEFT1-1", "an inside point with its offsets")
gdb.petHappinessIconAnchor, gdb.petHappinessIconX, gdb.petHappinessIconY = "OUTSIDE_RIGHT", 2, 0

gdb.petHappinessIconEnabled = false
GP:UpdateGroupFrame(own)
check(not gi:IsShown(), "party switched off: hidden")
check(GP.consumers.group_pet ~= nil, "...raid still shows it, so the events stay")
rdb.petHappinessIconEnabled = false
GP:UpdateGroupFrame(own)
eq(GP.consumers.group_pet, nil, "both off: the group side lets the events go")
gdb.petHappinessIconEnabled, rdb.petHappinessIconEnabled = true, true

print("-- Group pet frames: test mode")
mood = nil                                   -- no pet at all
local tParty, tRaid1, tRaid2 = PetFrame("pet", false, true), PetFrame("raidpet1", true, true), PetFrame("raidpet2", true, true)
GP:UpdateGroupFrame(tParty); GP:UpdateGroupFrame(tRaid1); GP:UpdateGroupFrame(tRaid2)
check(tParty.dfHappinessIcon and tParty.dfHappinessIcon:IsShown(), "party preview: the player's slot shows the sample without a pet")
eq(tParty.dfHappinessIcon.tex._atlas, "UI-PetMad", "...the unhappy sample")
check(tRaid1.dfHappinessIcon and tRaid1.dfHappinessIcon:IsShown(), "raid preview: slot 1 (the player) shows it")
eq(tRaid2.dfHappinessIcon, nil, "raid preview: other slots do not")
tParty.dfHappinessIcon:GetScript("OnEnter")(tParty.dfHappinessIcon)
eq(#tip.lines, 7, "the preview's tooltip shows the sample lines")
mood = 3

print("-- Group pet frames: retail")
do
    local R = NewDF(false)
    function R:GetFrameDB() return gdb end
    local rf = PetFrame("pet")
    R.PetHappiness:UpdateGroupFrame(rf)
    eq(rf.dfHappinessIcon, nil, "retail: nothing built")
    eq(R.PetHappiness.consumers.group_pet, nil, "...no consumer")
end

print("-- Group pet frames: wiring (source)")
local pets = df_file_source("Frames/Pets.lua"):gsub("\r\n", "\n")
local hookCalls = 0
for _ in pets:gmatch("DF%.PetHappiness:UpdateGroupFrame%(frame%)") do hookCalls = hookCalls + 1 end
eq(hookCalls, 3, "Pets.lua: styled, live update and preview update all paint the face")
local opts = options_file_source("GUI/Pages/Options.lua"):gsub("\r\n", "\n")
check(opts:find('OpenSection(L["Pet Happiness"], "pets_happiness", 2', 1, true), "a Pet Happiness card on the pet page")
check(opts:find("if DF.IS_FOREVER then\n            local function ApplyPetHappiness()", 1, true), "...built on Forever only")
for _, k in ipairs({ "petHappinessIconSize", "petHappinessIconAnchor", "petHappinessIconX", "petHappinessIconY",
                     "petHappinessIconTooltip" }) do
    check(opts:find('"' .. k .. '"', 1, true), "a control for " .. k)
end
local disables = 0
for _ in opts:gmatch("%.disableOn = HappinessOff") do disables = disables + 1 end
eq(disables, 7, "every control greys while the face is off")
eq(#DF.errs, 0, "no element errored")

-- ============================================================
-- PHASE 3: the loyalty trend badge and Hide While Happy, on both sides.
-- ============================================================
print("-- Phase 3: core")
eq(PH.TrendArrow(-1, "LOSING"), -1, "losing / Losing Only: down")
eq(PH.TrendArrow(1, "LOSING"), nil, "gaining / Losing Only: nothing")
eq(PH.TrendArrow(0, "LOSING"), nil, "steady: nothing")
eq(PH.TrendArrow(-1, "BOTH"), -1, "losing / Both: down")
eq(PH.TrendArrow(1, "BOTH"), 1, "gaining / Both: up")
eq(PH.TrendArrow(0, "BOTH"), nil, "steady / Both: nothing")
eq(PH.TrendArrow(-1, "OFF"), nil, "Off: never")
eq(PH.TrendArrow(-1, nil), -1, "no mode stored: the default (Losing Only)")
eq(PH.TrendArrow(nil, "BOTH"), nil, "no readable rate: nothing")
local rm, rd = PH.Resolve(3, -1, true, "LOSING", false)
eq(rm, nil, "Hide While Happy: a happy pet hides"); eq(rd, nil, "...its arrow with it")
rm, rd = PH.Resolve(3, -1, true, "LOSING", true)
eq(rm, 3, "...but never in test mode"); eq(rd, -1, "...arrow and all")
rm, rd = PH.Resolve(1, -1, true, "LOSING", false)
eq(rm, 1, "Hide While Happy: an unhappy pet still shows"); eq(rd, -1, "...with its arrow")
eq((PH.Resolve(2, 0, true, "LOSING", false)), 2, "...a content pet too")
eq((PH.Resolve(nil, -1, false, "BOTH", false)), nil, "no pet: nothing")
local topts = PH.TrendOptions()
eq(topts.LOSING, "Losing Only", "options: localised labels"); eq(topts.BOTH, "Both", "..."); eq(topts.OFF, "Off", "...")
eq(table.concat(topts._order, ","), "LOSING,BOTH,OFF", "...in order, raw keys stored")

local bi = Make("Frame")
PH.PaintBadge(bi, -1, 16)
local bb = bi.dfTrend
check(bb and bb:IsShown(), "badge: built and shown")
eq(bb._texture, PH.BADGE_ART[-1], "...the addon's own down chevron")
eq(bb._w, 7, "...45% of a 16px face")
eq(bb._vertex.r, PH.TITLE_COLORS[1][1], "...tinted red")
check(bb.shadow:IsShown() and bb.shadow._vertex.r == 0, "...with a dark copy behind")
local bpt = bb._points[#bb._points]
eq(bpt[1] .. ">" .. bpt[3], "CENTER>BOTTOMRIGHT", "...on the face's bottom-right corner")
eq(bpt[2], bi, "...of the face")
bb._texture = "sentinel"
PH.PaintBadge(bi, -1, 16)
eq(bb._texture, "sentinel", "the same arrow: not repainted")
PH.PaintBadge(bi, 1, 16)
eq(bb._texture, PH.BADGE_ART[1], "up: the up chevron")
eq(bb._vertex.g, PH.TITLE_COLORS[3][2], "...tinted green")
PH.PaintBadge(bi, nil, 16)
check(not bb:IsShown() and not bb.shadow:IsShown(), "no arrow: hidden")
PH.PaintBadge(bi, -1, 30)
eq(bb._w, 14, "resized with the face")
-- A build that refuses the addon's file falls back to Blizzard's arrow.
local fb = Make("Frame")
local heldCT = fb.CreateTexture
fb.CreateTexture = function(self)
    local t = heldCT(self)
    function t:SetTexture(p) if p and p:find("AddOns", 1, true) then return false end self._texture = p return true end
    return t
end
PH.PaintBadge(fb, -1, 16)
eq(fb.dfTrend._texture, PH.BADGE_FALLBACK[-1], "the file refused: Blizzard's arrow")
check(fb.dfTrend:IsShown(), "...shown")
local nb = Make("Frame")
nb.CreateTexture = function(self)
    local t = heldCT(self)
    function t:SetTexture() return false end
    return t
end
PH.PaintBadge(nb, -1, 16)
check(not nb.dfTrend:IsShown(), "no art at all: the badge stays hidden")

print("-- Phase 3: unit frames")
eq(pdb.happinessIconTrend, "LOSING", "UF default: Losing Only")
eq(pdb.happinessIconHideHappy, false, "UF default: Hide While Happy off")
mood, rate = 1, -1
IN:Update(PET)
check(icon:IsShown(), "unhappy and losing: the face")
check(icon.dfTrend and icon.dfTrend:IsShown(), "...with the arrow")
eq(icon.dfTrend.dfDir, -1, "...down")
mood, rate = 3, 1
IN:Update(PET)
check(icon:IsShown() and not icon.dfTrend:IsShown(), "happy and gaining, Losing Only: the face, no arrow")
pdb.happinessIconTrend = "BOTH"
IN:Update(PET)
eq(icon.dfTrend:IsShown() and icon.dfTrend.dfDir, 1, "Both: the up arrow")
pdb.happinessIconTrend = "OFF"
mood, rate = 1, -1
IN:Update(PET)
check(icon:IsShown() and not icon.dfTrend:IsShown(), "Off: no arrow even while losing")
pdb.happinessIconTrend = "LOSING"
pdb.happinessIconHideHappy = true
mood, rate = 3, 1
IN:Update(PET)
check(not icon:IsShown(), "Hide While Happy: hidden while happy")
mood, rate = 2, 0
IN:Update(PET)
check(icon:IsShown(), "...content: shown")
eq(icon.tex._atlas, "UI-PetNeutral", "...the content face")
mood, rate = 3, 1
IN:Update(PET)
check(not icon:IsShown(), "...happy again: hidden")
mood = nil
local PV3 = Owner("pet")
PV3.dfUFPreview = true
IN:Attach(PV3)
PV3.dfTestData = { petHappiness = 3 }
IN:Preview(PV3)
check(PV3.dfUFIcons.happiness:IsShown(), "test mode: a happy sample still shows with Hide While Happy on")
PV3.dfTestData = nil
IN:Preview(PV3)
local pvb = PV3.dfUFIcons.happiness.dfTrend
check(pvb and pvb:IsShown() and pvb.dfDir == -1, "test mode: the sample's down arrow shows under Losing Only")
pdb.happinessIconHideHappy = false
mood, rate = 3, 1
IN:Update(PET)

print("-- Phase 3: group pet frames")
for _, kv in ipairs({ { "petHappinessIconTrend", '"LOSING"' }, { "petHappinessIconHideHappy", "false" } }) do
    check(cfg:find("    " .. kv[1] .. " = " .. kv[2] .. ",", 1, true), "PartyDefaults: " .. kv[1] .. " = " .. kv[2])
    check(exportSrc:find('"' .. kv[1] .. '",', 1, true), "export: " .. kv[1])
end
mood, rate = 1, -1
GP:UpdateGroupFrame(own)
check(gi:IsShown() and gi.dfTrend and gi.dfTrend:IsShown(), "group: unhappy and losing, face and arrow")
eq(gi.dfTrend._w, 6, "...45% of the 14px face")
gdb.petHappinessIconTrend = "OFF"
GP:UpdateGroupFrame(own)
check(not gi.dfTrend:IsShown(), "group Off: no arrow")
gdb.petHappinessIconTrend = "BOTH"
mood, rate = 3, 1
GP:UpdateGroupFrame(own)
eq(gi.dfTrend:IsShown() and gi.dfTrend.dfDir, 1, "group Both: the up arrow")
gdb.petHappinessIconHideHappy = true
GP:UpdateGroupFrame(own)
check(not gi:IsShown(), "group Hide While Happy: hidden while happy")
mood, rate = 1, -1
GP:OnEvent("UNIT_HAPPINESS")
check(gi:IsShown() and gi.dfTrend.dfDir == -1, "...the event: unhappy again, shown with the down arrow")
mood = nil
local tP3 = PetFrame("pet", false, true)
GP:UpdateGroupFrame(tP3)
check(tP3.dfHappinessIcon:IsShown(), "group test mode: shown with Hide While Happy on")
check(tP3.dfHappinessIcon.dfTrend and tP3.dfHappinessIcon.dfTrend:IsShown(), "...with the sample's arrow")
gdb.petHappinessIconHideHappy, gdb.petHappinessIconTrend = false, "LOSING"
mood, rate = 3, 1

print("-- Phase 3: settings (source)")
local pages3 = options_file_source("UnitFrames/Pages.lua")
check(pages3:find('"happinessIconTrend"', 1, true), "UF: a Loyalty Arrow control")
check(pages3:find('"happinessIconHideHappy"', 1, true), "UF: a Hide While Happy control")
local opts3 = options_file_source("GUI/Pages/Options.lua")
check(opts3:find('"petHappinessIconTrend"', 1, true), "group: a Loyalty Arrow control")
check(opts3:find('"petHappinessIconHideHappy"', 1, true), "group: a Hide While Happy control")
local enUS3 = df_file_source("Locales/enUS.lua")
for _, k in ipairs({ "Loyalty Arrow", "Losing Only", "Hide While Happy", "Both", "Off",
                     "A small arrow on the face's corner while your pet is losing (or gaining) loyalty.",
                     "Show the face only when your pet is content or unhappy. Test mode always shows it." }) do
    check(enUS3:find('L["' .. k .. '"] = true', 1, true), "enUS: " .. k)
end
eq(#DF.errs, 0, "no element errored")

-- ============================================================
-- PHASE 4: colour by happiness (border, name, health bar) on both sides.
-- ============================================================
print("-- Phase 4: the colours (core)")
do
    local spec = DF.registered.petHappinessColors
    check(spec ~= nil, "Forever: petHappinessColors is a registered profile-root table")
    eq(spec and spec.exportCategory, "colors", "...it travels with the Colors export category")
    eq(spec and spec.defaults.unhappy.r, 0.95, "...defaults: unhappy red")
    eq(spec and spec.defaults.content.g, 0.75, "...content amber")
    eq(spec and spec.defaults.happy.g, 0.85, "...happy green")
    local R = NewDF(false)
    eq(R.registered.petHappinessColors, nil, "retail: not registered")
end
local savedDB = DF.db
DF.db.petHappinessColors = { happy = { r = 0, g = 1, b = 0 }, content = { r = 1, g = 1, b = 0 },
                             unhappy = { r = 1, g = 0, b = 0 } }
local COL = DF.db.petHappinessColors
eq(PH.Color(1), COL.unhappy, "the profile's unhappy colour")
eq(PH.Tint(1, true), COL.unhappy, "unhappy: tinted")
eq(PH.Tint(2, true), COL.content, "content: tinted")
eq(PH.Tint(3, true), nil, "happy, Only When Not Happy: not tinted")
eq(PH.Tint(3, nil), nil, "...nil counts as on (the default)")
eq(PH.Tint(3, false), COL.happy, "happy, Only When Not Happy off: the happy colour")
eq(PH.Tint(nil, false), nil, "no pet: never tinted")
COL.content = "junk"
eq(PH.Color(2).r, PH.COLOR_DEFAULTS.content.r, "an unusable stored colour: the default")
COL.content = { r = 1, g = 1, b = 0 }
eq(PH.WantsTints(false, false, "HEALTH"), false, "nothing coloured: no tints wanted")
eq(PH.WantsTints(false, false, "HAPPINESS"), true, "the health mode alone wants them")
eq(PH.WantsTints(true, false, "CLASS"), true, "the border alone wants them")

print("-- Phase 4: unit frames")
eq(pdb.happinessColorBorder, false, "UF default: border off")
eq(pdb.happinessColorName, false, "UF default: name off")
eq(pdb.happinessColorOnlyUnhappy, true, "UF default: Only When Not Happy on")
local healthPaints, tdHints, borderApplies = 0, {}, 0
function DF:UpdateHealthBarAppearance() healthPaints = healthPaints + 1 end
function DF:UpdateTextDesigner(f, hint) tdHints[#tdHints + 1] = hint end
function DF:ApplyFrameBorder() borderApplies = borderApplies + 1 end
local function Border()
    local b = {}
    function b:SetColor(r, g, b2, a) self.c = { r, g, b2, a } end
    return b
end
PET.border = Border()
pdb.frameBorderColor = { r = 0, g = 0, b = 0, a = 0.5 }
mood, rate = 1, -1
IN:Update(PET)
eq(PET.dfHappinessBorder, nil, "every target off: nothing stamped")
eq(PET.border.c, nil, "...nothing painted")
eq(healthPaints + #tdHints + borderApplies, 0, "...no painter run")
pdb.happinessIconEnabled = false
pdb.happinessColorBorder = true
IN:Layout(PET)
check(DF.PetHappiness.consumers.uf_pet ~= nil, "the face off, the border coloured: the events are still asked for")
eq(PET.dfHappinessBorder, COL.unhappy, "unhappy: the border stamped red")
eq(PET.border.c and (PET.border.c[1] .. "," .. PET.border.c[2] .. "," .. PET.border.c[4]), "1,0,0.5",
   "...painted through the border's SetColor, with the frame border's own alpha")
PET.border.c = nil
IN:Update(PET)
eq(PET.border.c, nil, "the same answer: not repainted")
mood, rate = 3, 1
IN:Update(PET)
eq(PET.dfHappinessBorder, nil, "happy, Only When Not Happy: the stamp goes")
eq(borderApplies, 1, "...and the normal border is put back")
pdb.happinessColorOnlyUnhappy = false
IN:Update(PET)
eq(PET.dfHappinessBorder, COL.happy, "Only When Not Happy off: the happy colour")
pdb.happinessColorOnlyUnhappy = true
mood = 2
PET.unit = "player"            -- a vehicle
IN:Update(PET)
eq(PET.dfHappinessBorder, nil, "in a vehicle: no tint")
PET.unit = "pet"
IN:Update(PET)
eq(PET.dfHappinessBorder, COL.content, "back from the vehicle: content amber")
pdb.happinessColorName = true
IN:Update(PET)
eq(PET.dfHappinessName, COL.content, "name: stamped")
eq(tdHints[#tdHints], "name", "...the Text Designer's name elements re-render")
local hp = healthPaints
pdb.healthColorMode = "HAPPINESS"
IN:Update(PET)
eq(PET.dfHappinessHealth, COL.content, "health mode Pet Happiness: stamped")
eq(healthPaints, hp + 1, "...the health bar repainted")
-- A colour edited in place on the Colors page: the stamp is the same table,
-- so the edit marks it stale and everything is repainted.
COL.content.r = 0.5
local before = healthPaints
PET.border.c = nil
PH:ColorsChanged()
eq(PET.border.c and PET.border.c[1], 0.5, "a colour edit: the border repainted in the new colour")
eq(healthPaints, before + 1, "...the health bar too")
eq(PET.dfHappinessHealth, COL.content, "...the stamps hold the colour again")
-- The answer changes: the event path repaints the tints.
mood = 1
PH:OnEvent("UNIT_HAPPINESS")
eq(PET.dfHappinessBorder, COL.unhappy, "UNIT_HAPPINESS: the tints follow the new mood")
-- Off again: everything back to normal.
pdb.happinessColorBorder, pdb.happinessColorName, pdb.healthColorMode = false, false, "CLASS"
IN:Update(PET)
check(PET.dfHappinessBorder == nil and PET.dfHappinessName == nil and PET.dfHappinessHealth == nil,
      "every target off: the stamps go")
pdb.happinessIconEnabled = nil
IN:Layout(PET)
-- Test mode: the sample (unhappy) shows the tint without a pet.
mood = nil
local PV4 = Owner("pet")
PV4.dfUFPreview = true
PV4.border = Border()
IN:Attach(PV4)
pdb.happinessColorBorder = true
IN:Preview(PV4)
eq(PV4.dfHappinessBorder, COL.unhappy, "test mode: the unhappy sample tints the border")
pdb.happinessColorBorder = false
IN:Preview(PV4)
eq(PV4.dfHappinessBorder, nil, "...off: untinted")
mood, rate = 3, 1
IN:Update(PET)

print("-- Phase 4: group pet frames")
for _, kv in ipairs({ { "petHappinessColorBorder", "false" }, { "petHappinessColorName", "false" },
                      { "petHappinessColorOnlyUnhappy", "true" } }) do
    check(cfg:find("    " .. kv[1] .. " = " .. kv[2] .. ",", 1, true), "PartyDefaults: " .. kv[1] .. " = " .. kv[2])
    check(exportSrc:find('"' .. kv[1] .. '",', 1, true), "export: " .. kv[1])
end
local petHealthCalls = {}
function DF:ApplyPetHealthColor(f, db, owner, unit, test)
    petHealthCalls[#petHealthCalls + 1] = { f = f, owner = owner, unit = unit, test = test }
end
local applies = 0
DF.Border = { Apply = function() applies = applies + 1 end, BuildSpec = function() return {} end }
local function NameText(f)
    local fs = Make("FontString", f)
    function fs:SetTextColor(r, g, b) self.c = { r, g, b } end
    return fs
end
own.border = Border()
own.healthBar = Make("StatusBar", own)
own.nameText = NameText(own)
gdb.petBorderColor = { r = 0, g = 0, b = 0, a = 1 }
gdb.petNameColor = { r = 0.9, g = 0.9, b = 0.9 }
mood, rate = 1, -1
GP:UpdateGroupFrame(own)
eq(own.dfHappinessBorder, nil, "group, every target off: nothing stamped")
eq(own.nameText.c, nil, "...the name untouched")
gdb.petHappinessIconEnabled, rdb.petHappinessIconEnabled = false, false
gdb.petHappinessColorBorder, gdb.petHappinessColorName = true, true
GP:UpdateGroupFrame(own)
check(GP.consumers.group_pet ~= nil, "group: the face off, a colour on: the events are still asked for")
eq(own.dfHappinessBorder, COL.unhappy, "group: the border stamped")
eq(own.border.c and own.border.c[1], 1, "...painted red")
eq(own.nameText.c and own.nameText.c[2], 0, "...the name red")
check(not own.dfHappinessIcon:IsShown(), "...the face stays hidden")
gdb.petHealthColorMode = "HAPPINESS"
GP:UpdateGroupFrame(own)
eq(own.dfHappinessHealth, COL.unhappy, "group health mode Pet Happiness: stamped")
local lastHealth = petHealthCalls[#petHealthCalls]
eq(lastHealth and lastHealth.owner, "player", "...repainted through ApplyPetHealthColor, owner = you")
mood, rate = 3, 1
PH:OnEvent("UNIT_HAPPINESS")
eq(own.dfHappinessBorder, nil, "the event, happy: no tint")
eq(own.nameText.c and own.nameText.c[1], 0.9, "...the name back to its own colour")
check(applies > 0, "...the normal border put back")
eq(own.dfHappinessHealth, nil, "...the health stamp gone (the painter falls back to the health colour)")
-- Not yours: never tinted.
local p1 = PetFrame("partypet1")
p1.border = Border()
mood = 1
GP:UpdateGroupFrame(p1)
eq(p1.dfHappinessBorder, nil, "a party member's pet: never tinted")
eq(p1.border.c, nil, "...its border untouched")
-- A raid pet frame that stops being yours loses its tint on the next event.
raidMine.border = Border()
raidMine.nameText = NameText(raidMine)
rdb.petHappinessColorBorder = true            -- a raid pet frame reads the raid settings
PH:OnEvent("UNIT_HAPPINESS")
eq(raidMine.dfHappinessBorder, COL.unhappy, "your raid pet frame: tinted")
yours.raidpet7 = nil
PH:Notify(true)
eq(raidMine.dfHappinessBorder, nil, "the roster moved, not yours now: the tint goes")
yours.raidpet7 = true
rdb.petHappinessColorBorder = nil
-- Test mode: the player's slot shows the sample's tint.
mood = nil
local t4 = PetFrame("pet", false, true)
t4.border = Border()
t4.healthBar = Make("StatusBar", t4)
GP:UpdateGroupFrame(t4)
eq(t4.dfHappinessBorder, COL.unhappy, "group test mode: the unhappy sample tints the player's slot")
local t4h = petHealthCalls[#petHealthCalls]
check(t4h and t4h.f == t4 and type(t4h.test) == "table", "...health repainted with the preview's sample data")
gdb.petHappinessColorBorder, gdb.petHappinessColorName, gdb.petHealthColorMode = false, false, "HEALTH"
gdb.petHappinessIconEnabled, rdb.petHappinessIconEnabled = true, true
mood, rate = 3, 1
GP:UpdateGroupFrame(own)

print("-- Phase 4: the group health painter (Pets.lua)")
do
    local src = df_file_source("Frames/Pets.lua"):gsub("\r\n", "\n")
    local a = src:find("local PET_HEALTH_STOPS", 1, true)
    local b = src:find("-- Get or create a health gradient curve", 1, true)
    check(a and b, "found ApplyPetHealthColor")
    local H = {}
    function H:GetClassColor() return { r = 0.1, g = 0.2, b = 0.3 } end
    function H:GetPetHealthGradientCurve() return nil end
    local fn = assert(loadstring("local DF, UnitClass, pcall, UnitHealthPercent = ... " .. src:sub(a, b - 1)))
    fn(H, function() return "Hunter", "HUNTER" end, pcall, nil)
    local bar = Make("StatusBar")
    function bar:SetStatusBarColor(r, g, b2) self.c = { r, g, b2 } end
    bar.tex = Make("Texture", bar)
    function bar:GetStatusBarTexture() return self.tex end
    local pf = { healthBar = bar }
    H:ApplyPetHealthColor(pf, { petHealthColorMode = "HAPPINESS" }, "player", "pet", { pct = 1 })
    eq(bar.tex._vertex and bar.tex._vertex.g, 0.8, "HAPPINESS, no stamp: the health gradient (the fixed fallback)")
    pf.dfHappinessHealth = { r = 1, g = 0, b = 0 }
    H:ApplyPetHealthColor(pf, { petHealthColorMode = "HAPPINESS" }, "player", "pet", { pct = 1 })
    eq(bar.c and (bar.c[1] .. "," .. bar.c[2]), "1,0", "HAPPINESS, stamped: the tint")
    H:ApplyPetHealthColor(pf, { petHealthColorMode = "CLASS" }, "player", "pet")
    eq(bar.c and bar.c[3], 0.3, "another mode ignores a stamp")
end

print("-- Phase 4: painters (source)")
local ea = df_file_source("Features/ElementAppearance.lua")
check(ea:find('elseif colorMode == "HAPPINESS" then', 1, true), "UF health: a HAPPINESS branch")
check(ea:find("if not c then c = GetClassColor(frame) end", 1, true), "...falling back to class")
local colorsSrc = df_file_source("Frames/Colors.lua")
check(colorsSrc:find('elseif mode == "CLASS" or mode == "HAPPINESS" then', 1, true), "ApplyHealthColors: HAPPINESS rides the class branch")
local create = df_file_source("Frames/Create.lua")
check(create:find("if frame.dfHappinessBorder and DF.PetHappiness then", 1, true), "ApplyFrameBorder: a standing tint is laid back")
local render = df_file_source("TextDesigner/Render.lua")
check(render:find('elseif cat == "name" and frame.dfHappinessName then', 1, true), "Text Designer: the name tint, under an AD override")
local pets4 = df_file_source("Frames/Pets.lua")
check(pets4:find("frame.dfHappinessName or db.petNameColor", 1, true), "Pets.lua: the styled name keeps a standing tint")
check(pets4:find("DF.PetHappiness.PaintBorder(frame.border, frame.dfHappinessBorder, db.petBorderColor)", 1, true),
      "Pets.lua: the styled border keeps a standing tint")

print("-- Phase 4: settings (source)")
local auras4 = options_file_source("GUI/Pages/Auras.lua")
check(auras4:find('OpenSection(L["Pet Happiness"], "colors_pet_happiness", 1', 1, true), "Colors page: a Pet Happiness card")
check(auras4:find("local PH = DF.IS_FOREVER and DF.PetHappiness", 1, true), "...Forever only")
check(auras4:find("PH:ColorsChanged()", 1, true), "...an edit repaints the tinted frames")
local pages4 = options_file_source("UnitFrames/Pages.lua")
check(pages4:find('section = L["Pet Happiness"]', 1, true), "the link lands on that card")
check(pages4:find('page    = "display_classcolors"', 1, true), "...on the Colors page")
check(pages4:find('pg.extraHealthColorModes.HAPPINESS = L["Pet Happiness"]', 1, true), "UF Health page: the Pet Happiness mode")
check(pages4:find('if u == "pet" and DF.IS_FOREVER then', 1, true), "...pet on Forever only")
check(pages4:find("UFO.BuildHappinessColorsCard(self, db, Open, Close, changed, col)", 1, true), "UF: a Color by Pet Happiness card")
check(not pages4:find("CreateColorPicker", pages4:find("function UFO.HappinessColorsText", 1, true), true)
      or pages4:find("CreateColorPicker", pages4:find("function UFO.HappinessColorsText", 1, true), true)
         > pages4:find("function UFO.BuildUnitIconsPage", 1, true),
      "UF: the card has no colour pickers of its own")
local opts4 = options_file_source("GUI/Pages/Options.lua")
check(opts4:find('if DF.IS_FOREVER then healthColorValues.HAPPINESS = L["Pet Happiness"] end', 1, true), "group: the Pet Happiness health mode, Forever only")
check(opts4:find('OpenSection(L["Color by Pet Happiness"], "pets_happiness_colors", 2', 1, true), "group: a Color by Pet Happiness card")
check(opts4:find("UFO.AddHappinessColorControls(group, parent, db, colorKeys", 1, true), "...the shared controls (and link)")
local enUS4 = df_file_source("Locales/enUS.lua")
for _, k in ipairs({ "A happy pet keeps its normal colors.", "Color by Pet Happiness", "Only When Not Happy",
                     "Set the Pet Happiness colors on the %s.",
                     "The colors your hunter pet's frame takes when it is happy, content or unhappy, wherever Color by Pet Happiness is on.",
                     "To color the health bar too, pick Pet Happiness as its color." }) do
    check(enUS4:find('L["' .. k .. '"] = true', 1, true), "enUS: " .. k)
end
DF.db = savedDB
eq(#DF.errs, 0, "no element errored")

-- ============================================================
-- PHASE 5: TEXT DESIGNER TOKENS
-- The core's accessors, the data events registered only while a pet token is
-- placed, the sources (live: the "pet" unit only; mock / test: the sample) and
-- the resolvers, then the wiring by source.
-- ============================================================
print("-- Phase 5: core accessors")
do
    local T = NewDF(true)
    local P5 = T.PetHappiness
    mood, damage, rate = 2, 100, -1
    loyalty, foods, tp, xp = "Loyalty Level 6 (Best Friend)", { "Meat", "Fish" }, { 150, 30 }, { 1200, 4800 }
    eq(P5:Loyalty(), "Loyalty Level 6 (Best Friend)", "Loyalty: the API's words")
    eq(P5.DietText(P5:Diet()), "Meat, Fish", "Diet: joined with Blizzard's delimiter")
    eq(P5:TrainingPoints(), 120, "TrainingPoints: total - used")
    local c, n = P5:Experience()
    eq(c, 1200, "Experience: current"); eq(n, 4800, "...and next")
    eq(P5.MoodText(2), "Content", "MoodText: Blizzard's global")
    eq(P5.MoodText(9), nil, "MoodText: an unknown mood is nothing")
    hunterPet = false
    eq(P5:Loyalty(), nil, "not a hunter pet: no loyalty")
    eq(P5:Diet(), nil, "...no diet"); eq(P5:TrainingPoints(), nil, "...no points"); eq(P5:Experience(), nil, "...no XP")
    hunterPet = true
    loyalty, foods, tp, xp = Secret("loy"), Secret("foods"), { Secret("tp"), 0 }, { 10, 0 }
    eq(P5:Loyalty(), nil, "a secret loyalty: nothing")
    eq(P5:Diet(), nil, "a secret diet: nothing")
    eq(P5:TrainingPoints(), nil, "secret points: nothing")
    eq(P5:Experience(), nil, "at the level cap (next XP 0): nothing")
    eq(P5.DietText({ "Meat", Secret("x"), 5 }), "Meat", "DietText skips a secret or non-string food")
    eq(P5.DietText({}), nil, "DietText: empty is nothing")
    loyalty, foods, tp, xp = "Loyalty Level 6 (Best Friend)", { "Meat", "Fish" }, { 150, 30 }, { 1200, 4800 }
    eq(P5:Loyalty(true), "Loyalty Level 6", "mock loyalty: the sample")
    eq(P5.DietText(P5:Diet(true)), "Meat, Fish", "mock diet")
    eq(P5:TrainingPoints(true), 120, "mock points")
    eq(select(2, P5:Experience(true)), 4800, "mock XP")

    print("-- Phase 5: data events only while a token is placed")
    local frame = Make("Frame")
    frame.dfUFUnit = "pet"
    local renders = 0
    function T:UpdateTextDesigner(f, hint)
        if f == frame and hint == "pet" then renders = renders + 1 end
    end
    P5:WatchTokens(frame, false)
    eq(P5.registered, nil, "no token: nothing registered")
    P5:WatchTokens(frame, true)
    eq(P5.registered, true, "a token placed: events on")
    local ev = P5.driver._events
    check(ev.UNIT_PET_EXPERIENCE and ev.UNIT_PET_TRAINING_POINTS, "...with the XP and training point events")
    check(ev.UNIT_HAPPINESS and ev.UNIT_PET, "...and the base events")
    P5:OnEvent("UNIT_PET_EXPERIENCE")
    eq(renders, 1, "XP gained: the pet tokens re-render")
    P5:OnEvent("UNIT_PET_TRAINING_POINTS")
    eq(renders, 2, "training points: re-render")
    P5:OnEvent("UNIT_HAPPINESS")
    P5:OnEvent("UNIT_HAPPINESS")
    eq(renders, 4, "every UNIT_HAPPINESS too (loyalty level has no event of its own)")
    P5:OnEvent("UNIT_PET")
    eq(renders, 5, "a new pet: re-render")
    frame._shown = false
    P5:OnEvent("UNIT_PET_EXPERIENCE")
    eq(renders, 5, "a hidden frame is not rendered")
    frame._shown = true
    -- An icon consumer as well: turning the tokens off keeps the base events.
    local iconCalls = 0
    P5:SetConsumer("icon", true, function() iconCalls = iconCalls + 1 end)
    P5:OnEvent("UNIT_PET_EXPERIENCE")
    eq(iconCalls, 0, "an icon consumer is not told about XP")
    P5:WatchTokens(frame, false)
    eq(P5.registered, true, "tokens off, icon on: base events stay")
    check(not P5.driver._events.UNIT_PET_EXPERIENCE and not P5.driver._events.UNIT_PET_TRAINING_POINTS,
          "...the XP and training point events go")
    check(P5.driver._events.UNIT_HAPPINESS, "...UNIT_HAPPINESS stays")
    P5:WatchTokens(frame, true)
    check(P5.driver._events.UNIT_PET_EXPERIENCE, "tokens back: XP event back")
    P5:SetConsumer("icon", false)
    P5:WatchTokens(frame, false)
    eq(P5.registered, false, "nothing left: everything off")
    eq(next(P5.driver._events), nil, "...every event unregistered")
    local R = NewDF(false)
    R.PetHappiness:WatchTokens(frame, true)
    eq(R.PetHappiness.registered, nil, "retail: a token never registers anything")

    print("-- Phase 5: sources and resolvers")
    AbbreviateNumbers = function(v) return string.format("%.1fk", v / 1000) end
    function T:DebugActive() return false end
    function T:UTF8Len(s) return #s end
    function T:UTF8Sub(s, i, j) return s:sub(i, j) end
    load_df_file_into("TextDesigner/MidnightSafe.lua", T)
    load_df_file_into("TextDesigner/DataSource.lua", T)
    load_df_file_into("TextDesigner/Resolver.lua", T)
    local TD = T.TextDesigner
    local Res = TD.Resolver
    local function rs(ct, source, extra)
        local elem = { contentType = ct }
        for k, v in pairs(extra or {}) do elem[k] = v end
        return Res:Resolve(elem, source)
    end
    local KEYS = { "pet_mood", "pet_mood_color", "pet_damage", "pet_loyalty_trend", "pet_loyalty",
                   "pet_training_points", "pet_xp", "pet_xp_percent", "pet_diet" }
    for _, k in ipairs(KEYS) do check(Res._RESOLVERS[k] ~= nil, "resolver: " .. k) end

    mood, damage, rate = 3, 125, -1
    local live = TD.DataSource.Live({ unit = "pet" })
    eq(rs("pet_mood", live), "Happy", "live: mood")
    eq(rs("pet_mood_color", live), "|cff59d959Happy|r", "live: mood in the happiness colour (the default happy green)")
    eq(rs("pet_damage", live), "125%", "live: damage")
    local arrow = rs("pet_loyalty_trend", live)
    check(arrow:find("expand_more.png", 1, true) and arrow:find("^|T"), "live: losing loyalty = the down arrow (texture escape)")
    rate = 1
    check(rs("pet_loyalty_trend", live):find("expand_less.png", 1, true), "live: gaining = the up arrow")
    rate = 0
    eq(rs("pet_loyalty_trend", live), "", "live: steady = nothing")
    rate = -1
    eq(rs("pet_loyalty", live), "Loyalty Level 6 (Best Friend)", "live: loyalty")
    eq(rs("pet_training_points", live), "120", "live: training points")
    eq(rs("pet_xp", live), "1.2k / 4.8k", "live: XP, abbreviated by default")
    eq(rs("pet_xp", live, { abbreviate = false }), "1200 / 4800", "live: XP, Abbreviate off")
    eq(rs("pet_xp_percent", live), "25%", "live: XP %")
    eq(rs("pet_xp_percent", live, { hidePercent = true }), "25", "live: XP %, Hide % Symbol")
    eq(rs("pet_diet", live), "Meat, Fish", "live: diet")

    -- Every other unit, no pet, a secret: every token renders empty, never an error.
    local function allEmpty(source, why)
        for _, k in ipairs(KEYS) do eq(rs(k, source), "", why .. ": " .. k) end
    end
    allEmpty(TD.DataSource.Live({ unit = "player" }), "the player's own frame (a vehicle-swapped pet frame)")
    allEmpty(TD.DataSource.Live({ unit = "party1" }), "another unit")
    mood = nil; hunterPet = false; xp = { 0, 0 }
    allEmpty(live, "no hunter pet")
    hunterPet = true
    mood, damage, rate = Secret("m"), Secret("d"), Secret("r")
    loyalty, foods, tp = Secret("l"), Secret("f"), { Secret("t"), 0 }
    allEmpty(live, "every answer secret")
    mood, damage, rate = 3, 125, -1
    loyalty, foods, tp, xp = "Loyalty Level 6 (Best Friend)", { "Meat", "Fish" }, { 150, 30 }, { 1200, 4800 }
    local saveP = C_PetInfo
    C_PetInfo = { GetPetHappiness = saveP.GetPetHappiness }
    GetPetExperience = nil
    eq(rs("pet_loyalty", live), "", "an API missing on this build: empty")
    eq(rs("pet_diet", live), "", "...diet"); eq(rs("pet_training_points", live), "", "...points")
    eq(rs("pet_xp", live), "", "...XP")
    C_PetInfo = saveP
    GetPetExperience = function() return xp[1], xp[2] end

    -- Off Forever the live source answers nothing, whatever the API says.
    T.IS_FOREVER = false
    allEmpty(live, "retail")
    T.IS_FOREVER = true

    -- The designer preview and the unit frames pet's test frame: the sample.
    local mock = TD.DataSource.Mock()
    eq(rs("pet_mood", mock), "Unhappy", "mock: the sample (unhappy)")
    eq(rs("pet_mood_color", mock), "|cfff24d4dUnhappy|r", "mock: in the unhappy colour")
    eq(rs("pet_damage", mock), "75%", "mock: damage")
    check(rs("pet_loyalty_trend", mock):find("expand_more.png", 1, true), "mock: losing loyalty")
    eq(rs("pet_loyalty", mock), "Loyalty Level 6", "mock: loyalty")
    eq(rs("pet_training_points", mock), "120", "mock: points")
    eq(rs("pet_xp", mock), "1.2k / 4.8k", "mock: XP")
    eq(rs("pet_xp_percent", mock), "25%", "mock: XP %")
    eq(rs("pet_diet", mock), "Meat, Fish", "mock: diet")
    mood = nil   -- no pet at all: the previews still show the sample
    local petTest = TD.DataSource.Test({ dfUFUnit = "pet", dfTestData = { name = "Wolf" } })
    eq(rs("pet_mood", petTest), "Unhappy", "test (UF pet preview): the sample, without a pet")
    eq(rs("pet_diet", petTest), "Meat, Fish", "test: diet")
    local happyTest = TD.DataSource.Test({ dfUFUnit = "pet", dfTestData = { petHappiness = 3, petLoyaltyRate = 1 } })
    eq(rs("pet_mood", happyTest), "Happy", "test: the sample's own fields win")
    check(rs("pet_loyalty_trend", happyTest):find("expand_less.png", 1, true), "test: its own loyalty rate")
    allEmpty(TD.DataSource.Test({ dfUFUnit = "player", dfTestData = {} }), "test: another unit's preview")
    allEmpty(TD.DataSource.Test({ dfTestData = {} }), "test: a party test frame")
    mood = 3
    -- In a group (a text group joins its items' text).
    eq(rs("group", live, { groupItems = { "pet_mood", "pet_damage" }, groupSeparator = " " }), "Happy 125%",
       "a text group of pet tokens")
    eq(#T.errs, 0, "phase 5: no errors")
    AbbreviateNumbers = nil
end

print("-- Phase 5: wiring (source)")
local function norm5(s) return (s:gsub("\r\n", "\n")) end
local render5 = norm5(df_file_source("TextDesigner/Render.lua"))
for _, k in ipairs({ "pet_mood", "pet_mood_color", "pet_damage", "pet_loyalty_trend", "pet_loyalty",
                     "pet_training_points", "pet_xp", "pet_xp_percent", "pet_diet" }) do
    check(render5:find("\n%s*" .. k .. "%s*= \"pet\","), "refresh hint " .. k .. " = pet")
end
check(render5:find('if hint == "all" or not tdDB.enabled then watchPetTokens(frame, tdDB, isPreview) end', 1, true),
      "a full render tells the core whether a pet token is placed")
check(render5:find('if not DF.IS_FOREVER or isPreview or frame.dfUFUnit ~= "pet" then return end', 1, true),
      "...the live unit frames pet frame only, Forever only")
local opts5 = norm5(options_file_source("TextDesigner/UI/Options.lua"))
check(opts5:find('if DF.IS_FOREVER then table.insert(CONTENT_CATEGORIES, #CONTENT_CATEGORIES, "pet") end', 1, true),
      "picker: a Pet Happiness category, Forever only")
for _, k in ipairs({ "pet_mood", "pet_mood_color", "pet_damage", "pet_loyalty_trend", "pet_loyalty",
                     "pet_training_points", "pet_xp", "pet_xp_percent", "pet_diet" }) do
    check(opts5:find('{ key = "' .. k .. '",', 1, true), "picker offers " .. k)
end
check(opts5:find('pet      = L["Pet Happiness"],', 1, true), "the category reads Pet Happiness")
check(opts5:find('return cat ~= "pet" or P.offerPetTokens == true', 1, true), "the category is offered only where asked")
check(opts5:find("P.offerPetTokens = (DF.IS_FOREVER and target and target.petTokens) and true or false", 1, true),
      "...on a designer whose target asks for it, on Forever")
check(opts5:find('if (activePill == "_all" or activePill == cat) and CategoryOffered(cat) then', 1, true),
      "the picker's list skips it elsewhere")
check(opts5:find('if cat ~= "group" and CategoryOffered(cat) then', 1, true), "so do the filter chips")
check(opts5:find('or ct.key == "pet_xp"\n', 1, true), "Pet XP: Abbreviate")
check(opts5:find('or ct.key == "pet_xp_percent" then', 1, true), "Pet XP %: decimals and Hide % Symbol")
local pages5 = norm5(options_file_source("UnitFrames/Pages.lua"))
check(pages5:find('target.petTokens = (unit == "pet" and DF.IS_FOREVER) and true or nil', 1, true),
      "the unit frames pet's designer asks for the pet tokens")
local enUS5 = norm5(df_file_source("Locales/enUS.lua"))
for _, k in ipairs({ "Diet", "Happiness", "Happiness (Color)", "Loyalty Level", "Loyalty Trend", "Pet Damage %",
                     "Pet XP", "Pet XP %", "Training Points" }) do
    local _, n = enUS5:gsub('\nL%["' .. k:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0") .. '"%] = true', "")
    eq(n, 1, "enUS: " .. k)
end

for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
