local NS = ...

-- ============================================================
-- UNIT FRAMES -- INDICATOR INFO ON THE PREVIEWS (click to open settings)
-- DandersFrames_Options/UnitFrames/TestLabels.lua over the REAL Labels.lua and
-- the REAL unit page data (UnitFrames/PageData.lua, GENERATED).
-- ------------------------------------------------------------
--   (a) SOURCE: every target maps to a real unit page kind, every party target
--       is mapped or deliberately skipped, every section a unit page is handed
--       is a real section on that page for that unit, every element a unit
--       draws resolves to that unit's page; Preview.lua wires OnClick beside
--       OnEnter / OnLeave; the units test settings carry their own
--       testShowLabels; the Units popup has the row; the TOC loads it after
--       Labels.lua.
--   (b) BEHAVIOUR over fake previews: portrait / cast bar / dragon beat the
--       health bar where they overlap; a click opens uf_<unit>_<kind> (boss
--       slots the boss page) with no party / raid mode switch; a section only
--       where that unit's page has it; elements without a unit page fall
--       through; labels off / test mode off / combat / mover / right click do
--       nothing; a party frame still opens the group page.
--
-- ⚠ Fakes, not WoW: a green run says the wiring holds, not that it renders.
-- ☠ ONE LUA RUNTIME IS SHARED BY EVERY SUITE. Every global replaced here is put
-- back at the end.
-- ============================================================

local saved = {
    CreateFrame = CreateFrame, C_Timer = C_Timer, GameTooltip = GameTooltip,
    GetCursorPosition = GetCursorPosition, DandersFrames = DandersFrames,
    InCombatLockdown = InCombatLockdown, hooksecurefunc = hooksecurefunc,
}

local PAGES_SRC = options_file_source("UnitFrames/Pages.lua"):gsub("\r\n", "\n")
local MODULES_SRC = options_file_source("GUI/Pages/Modules.lua"):gsub("\r\n", "\n")
local PARTY_PAGE_FILES = { "Auras", "Frames", "Indicators", "Modules", "Options", "Profiles" }
local PARTY = {}
for _, name in ipairs(PARTY_PAGE_FILES) do
    PARTY[name] = options_file_source("GUI/Pages/" .. name .. ".lua"):gsub("\r\n", "\n")
end

-- ============================================================
-- FAKES
-- ============================================================
local created, mouseOn = {}, {}

local function methodsOnly(_, k)
    if type(k) == "string" and k:find("^%u") then return function() end end
    return nil
end

local function region()
    local r = { _shown = false }
    function r:Show() self._shown = true end
    function r:Hide() self._shown = false end
    function r:IsShown() return self._shown end
    function r:SetText(t) self._text = t end
    function r:GetText() return self._text end
    function r:GetStringWidth() return 40 end
    return setmetatable(r, { __index = function() return function() end end })
end

-- rect = { l, r, b, t }
local function frame(kind, rect, scale)
    local f = { _kind = kind, _shown = true, _alpha = 1, _scripts = {}, _strata = "MEDIUM", _level = 1,
                _scale = scale or 1 }
    if kind == "GameTooltip" then f._shown = false end
    function f:Show() self._shown = true end
    function f:Hide() self._shown = false end
    function f:SetShown(v) self._shown = v and true or false end
    function f:IsShown() return self._shown end
    function f:IsVisible() return self._shown end
    function f:SetAlpha(a) self._alpha = a end
    function f:GetAlpha() return self._alpha end
    function f:SetScript(n, fn) self._scripts[n] = fn end
    function f:GetScript(n) return self._scripts[n] end
    function f:HookScript(n, fn) self._scripts[n] = fn end
    function f:EnableMouse(v) if v then mouseOn[#mouseOn + 1] = self end end
    function f:SetFrameStrata(s) self._strata = s end
    function f:GetFrameStrata() return self._strata end
    function f:SetFrameLevel(l) self._level = l end
    function f:GetFrameLevel() return self._level end
    function f:GetEffectiveScale() return self._scale end
    function f:CreateTexture() return region() end
    function f:CreateFontString() return region() end
    function f:SetOwner(o) self._owner = o end
    function f:GetOwner() return self._owner end
    function f:ClearLines() self._lines = {} end
    function f:AddLine(t) self._lines = self._lines or {}; self._lines[#self._lines + 1] = t end
    if rect then
        function f:GetLeft() return rect[1] end
        function f:GetRight() return rect[2] end
        function f:GetBottom() return rect[3] end
        function f:GetTop() return rect[4] end
    end
    created[#created + 1] = f
    return setmetatable(f, { __index = methodsOnly })
end

CreateFrame = function(kind) return frame(kind) end
local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
local function flushTimers()
    local list = timers
    timers = {}
    for _, fn in ipairs(list) do fn() end
end
GameTooltip = frame("GameTooltip")
local CX, CY = 0, 0
GetCursorPosition = function() return CX, CY end
local combat = false
InCombatLockdown = function() return combat end
hooksecurefunc = function(t, name, fn)
    local orig = t[name]
    t[name] = function(...) local a, b, c = orig(...); fn(...); return a, b, c end
end

-- ---- previews --------------------------------------------------------------
-- A preview: frame + health bar over its top 50px, at x0.
local function preview(unit, x0, slot)
    local f = frame("Button", { x0, x0 + 120, 100, 160 })
    f.dfUFUnit, f.dfUFSlot, f.dfUFPreview, f.dfIsTestFrame, f.isRaidFrame = unit, slot, true, true, false
    f.healthBar = frame("StatusBar", { x0, x0 + 120, 110, 160 })
    return f
end

local target = preview("target", 100)
-- Inside portrait over the health bar's left end.
target.dfUFPortrait = frame("Frame", { 102, 130, 112, 158 })
-- A cast bar laid across the health bar.
target.dfUFCastBar = frame("Frame", { 140, 200, 112, 120 })
-- The dragon: the top piece wholly ABOVE the frame, the bottom piece reaching down
-- over the health bar's right end. The left pieces hidden.
local dTop = frame("Texture", { 160, 220, 160, 180 })
local dBottom = frame("Texture", { 205, 219, 150, 165 })
local dHidden = frame("Texture", { 100, 110, 150, 165 }); dHidden:Hide()
target.dfUFIcons = {
    dragon = { tex = { RIGHT = { TOP = dTop, BOTTOM = dBottom }, LEFT = { TOP = dHidden, BOTTOM = dHidden } } },
    -- A role icon the target's Icons page has no card for, at 150..156 x 140..146.
}
target.roleIcon = frame("Frame", { 150, 156, 140, 146 })
-- A missing-buff strip (no unit page): never labelled, the health bar answers.
target.missingBuffStrip = frame("Frame", { 170, 190, 125, 135 })
target.missingFactory = {}

local pet = preview("pet", 300)
pet.dfHealAbsorbBar = frame("StatusBar", { 300, 330, 112, 118 })
function pet.dfHealAbsorbBar:GetStatusBarTexture() return self end
pet.dfAbsorbBar = frame("StatusBar", { 380, 410, 112, 118 })
function pet.dfAbsorbBar:GetStatusBarTexture() return self end

local player = preview("player", 500)
player.dfUFClassPower = frame("Frame", { 500, 620, 92, 98 })      -- below the frame
player.dfHealAbsorbBar = frame("StatusBar", { 500, 530, 112, 118 })
function player.dfHealAbsorbBar:GetStatusBarTexture() return self end

local boss1 = preview("boss", 700, 1)
local bTop = frame("Texture", { 760, 820, 160, 180 })
local edges = {
    top = frame("Texture", { 700, 820, 159, 160 }), bottom = frame("Texture", { 700, 820, 100, 101 }),
    left = frame("Texture", { 700, 701, 101, 159 }), right = frame("Texture", { 819, 820, 101, 159 }),
}
boss1.dfUFIcons = { dragon = { tex = { RIGHT = { TOP = bTop } } }, classBorder = { edges = edges } }

-- A party test frame, to prove the group path is untouched.
local party = frame("Button", { 900, 1020, 100, 160 })
party.isRaidFrame = false
party.healthBar = frame("StatusBar", { 900, 1020, 110, 160 })

-- ---- the units test mode -----------------------------------------------------
local testDB = { testShowLabels = true }
local calls = {}
local P = { shown = true, frames = { target = target, pet = pet, player = player }, _test = true }
function P:IsTestMode() return self._test end
function P:TestOn(key) return testDB[key] ~= false end
function P:Show() calls[#calls + 1] = { "P:Show" } end
function P:Hide() calls[#calls + 1] = { "P:Hide" } end
function P:Refresh() calls[#calls + 1] = { "P:Refresh" } end
local B = { preview = { [1] = boss1 } }
function B:PreviewRefresh() end
local UFt = { Preview = P, Boss = B, BOSS_COUNT = 5,
              SPAWNED_UNITS = { "player", "target", "targettarget", "focus", "focustarget", "pet", "boss" } }

-- ---- DF + the settings window ----------------------------------------------------
local partyDb = { testShowLabels = true }
local DFt = {
    L = setmetatable({}, { __index = function(_, k) return k end }),
    testMode = true, raidTestMode = false,
    testPartyFrames = { [0] = party },
    UnitFrames = UFt,
}
function DFt:GetDB() return partyDb end
function DFt:GetRaidDB() return {} end
local GUIt = { SelectedMode = "party" }
function GUIt:SelectModule(id, mode) calls[#calls + 1] = { "module", id, mode } end
function GUIt:LinkToSetting(t) calls[#calls + 1] = { "link", t.page, t.section } end
GUIt.SelectTab = function(p) calls[#calls + 1] = { "tab", p } end
DFt.GUI = GUIt
DFt.GUIFrame = frame("Frame")
local relabels = 0

-- UFO: the two pure helpers lifted out of the REAL Pages.lua, the unit label stubbed.
local UFO = {}
GUIt.UnitFrameOptions = UFO
local function lift(name)
    local body = PAGES_SRC:match("(function UFO%." .. name .. "%(.-\nend)\n")
        or PAGES_SRC:match("(function UFO%." .. name .. "%([^\n]-end)\n")
    check(body ~= nil, "uf labels: Pages.lua defines UFO." .. name)
    local fn = assert(loadstring(body or "", "@Pages.lua:" .. name))
    setfenv(fn, { UFO = UFO })
    fn()
end
lift("PageName")
lift("CardAllowed")
function UFO.UnitLabel(unit) return unit end

DandersFrames = DFt
assert(loadstring(options_file_source("UnitFrames/PageData.lua"), "@PageData.lua"))()
local DATA = DFt.UnitFramePageData
check(DATA ~= nil, "uf labels: the real page data loads")
assert(loadstring(options_file_source("TestMode/Labels.lua"), "@Labels.lua"))()
local TL = DFt.TestLabels
-- What the group targets are, before the units file registers its own.
local GROUP = TL:DescribeTargets()
assert(loadstring(options_file_source("UnitFrames/TestLabels.lua"), "@TestLabels.lua"))()
local realUpdate = DFt.UpdateTestLabels
DFt.UpdateTestLabels = function(self) relabels = relabels + 1; return realUpdate(self) end

-- ============================================================
-- (a) SOURCE
-- ============================================================
local KINDS = UFO.LABEL_KINDS
check(type(KINDS) == "table" and type(UFO.LabelTarget) == "function", "uf labels: the mapping is published")

local recByKind = {}
for _, rec in ipairs(DATA.pages) do recByKind[rec.kind] = rec end

-- Every mapping names a real unit page kind; every card it names is a real card
-- of that page.
for key, e in pairs(KINDS) do
    local rec = recByKind[e.kind]
    check(rec ~= nil and not rec.later, "uf labels: " .. key .. " -> a built unit page kind (" .. tostring(e.kind) .. ")")
    for lkey, card in pairs(e.sections or {}) do
        check(rec and rec.cards and rec.cards[card] ~= nil,
              "uf labels: " .. key .. " section '" .. lkey .. "' is card " .. card .. " of " .. e.kind)
    end
end

-- Every group target is mapped, or deliberately skipped (no unit page at all).
local SKIPPED = { missing = true, rested = true }
for _, t in ipairs(GROUP) do
    check(KINDS[t.key] ~= nil or SKIPPED[t.key], "uf labels: group target " .. t.key .. " is mapped or skipped")
    if SKIPPED[t.key] then check(KINDS[t.key] == nil, "uf labels: " .. t.key .. " has no unit page") end
end

-- The unit-only targets are registered, before the frame fallback.
local described = TL:DescribeTargets()
eq(described[#described].key, "frame", "uf labels: the frame fallback stays last")
local registered = {}
for _, t in ipairs(described) do registered[t.key] = t end
for _, key in ipairs({ "ufPortrait", "ufCastBar", "ufClassPower", "ufResting", "ufPvP",
                       "ufClassification", "ufDragon", "ufClassBorder" }) do
    check(registered[key] ~= nil, "uf labels: unit target registered -- " .. key)
    check(registered[key] and registered[key].label ~= key, "uf labels: " .. key .. " has a name")
end

-- Each section text really is a section header on that page.
-- DF-sourced pages: the party builder's OpenSection(L["..."], "<card>") (icons:
-- the spec line's key + section). The module's own pages: Open(L["..."] /
-- the unit icon card list.
local function partyHasSection(card, text)
    if card:find("^icons_") then
        local field = card:sub(7)
        for line in MODULES_SRC:gmatch("[^\n]+") do
            if line:find('key = "' .. field .. '"', 1, true) and line:find('section = L["' .. text .. '"]', 1, true) then
                return true
            end
        end
        return false
    end
    local lit = 'OpenSection(L["' .. text .. '"], "' .. card .. '"'
    for _, src in pairs(PARTY) do
        if src:find(lit, 1, true) then return true end
    end
    return false
end
local function ownHasSection(card, text)
    if PAGES_SRC:find('card = "' .. card .. '"', 1, true) then
        for line in PAGES_SRC:gmatch("[^\n]+") do
            if line:find('card = "' .. card .. '"', 1, true) and line:find('L["' .. text .. '"]', 1, true) then
                return true
            end
        end
    end
    if card == "class_decorations" then
        return PAGES_SRC:find('CardShown(rec, unit, "class_decorations")', 1, true) ~= nil
            and PAGES_SRC:find('Open(L["' .. text .. '"]', 1, true) ~= nil
    end
    return false
end
for key, e in pairs(KINDS) do
    local rec = recByKind[e.kind]
    for lkey, card in pairs(e.sections or {}) do
        local ok
        if rec and rec.source then ok = partyHasSection(card, lkey) else ok = ownHasSection(card, lkey) end
        check(ok, "uf labels: '" .. lkey .. "' is a section header on the " .. e.kind .. " page (" .. key .. ")")
    end
end

-- Pages and sections per unit, before the window has built its maps (from the data)
-- and after (UFO.pagesByUnit), which must agree.
local function builtMaps()
    UFO.data = DATA
    UFO.pagesByUnit, UFO.pageByKind = {}, {}
    for _, rec in ipairs(DATA.pages) do
        UFO.pageByKind[rec.kind] = rec
        if not rec.later then
            for _, unit in ipairs(DATA.units) do
                if rec.units[unit] then
                    UFO.pagesByUnit[unit] = UFO.pagesByUnit[unit] or {}
                    UFO.pagesByUnit[unit][rec.kind] = UFO.PageName(unit, rec.kind)
                end
            end
        end
    end
end
local before = {}
for _, unit in ipairs(UFt.SPAWNED_UNITS) do
    for key, e in pairs(KINDS) do
        local section
        for lkey in pairs(e.sections or {}) do section = lkey end
        local page, sec = UFO.LabelTarget(unit, key, section)
        before[unit .. "/" .. key] = tostring(page) .. "|" .. tostring(sec)
        local rec = recByKind[e.kind]
        local has = rec.units[unit] and true or false
        eq(page ~= nil, has, "uf labels: " .. unit .. " " .. key .. " resolves iff the unit has a " .. e.kind .. " page")
        if page then eq(page, "uf_" .. unit .. "_" .. e.kind, "uf labels: " .. unit .. " " .. key .. " opens its own unit's page") end
        if section and page then
            local card = e.sections[section]
            eq(sec ~= nil, (rec.cards[card] and rec.cards[card][unit]) and true or false,
               "uf labels: " .. unit .. " " .. key .. " gets section '" .. section .. "' iff its page shows it")
        end
    end
end
builtMaps()
for _, unit in ipairs(UFt.SPAWNED_UNITS) do
    for key, e in pairs(KINDS) do
        local section
        for lkey in pairs(e.sections or {}) do section = lkey end
        local page, sec = UFO.LabelTarget(unit, key, section)
        eq(tostring(page) .. "|" .. tostring(sec), before[unit .. "/" .. key],
           "uf labels: " .. unit .. " " .. key .. " resolves the same once the window built its pages")
        if page then check(UFO.pagesByUnit[unit][e.kind] == page, "uf labels: " .. page .. " is a registered page") end
    end
end

-- Every element a unit DRAWS resolves to that unit's page (the element files' own
-- unit lists).
local function unitSet(src, pattern)
    local body = src:match(pattern)
    local set = {}
    for u in (body or ""):gmatch("(%w+) = true") do set[u] = true end
    return set
end
local drawn = {
    ufPortrait = unitSet(uf_file_source("Portrait.lua"), "PO%.UNITS = (%b{})"),
    ufCastBar = unitSet(uf_file_source("CastBar.lua"), "CB%.UNITS = (%b{})"),
    ufClassPower = unitSet(uf_file_source("ClassPower.lua"), "CP%.UNITS = (%b{})"),
}
local IN_SRC = uf_file_source("Indicators.lua")
drawn.ufResting = unitSet(IN_SRC, "resting = (%b{})")
drawn.ufPvP = unitSet(IN_SRC, "pvp = (%b{})")
drawn.ufClassification = unitSet(IN_SRC, "classification = (%b{}),")
drawn.ufDragon, drawn.ufClassBorder = drawn.ufClassification, drawn.ufClassification
for key, set in pairs(drawn) do
    check(next(set) ~= nil, "uf labels: read " .. key .. "'s unit list")
    for unit in pairs(set) do
        check(UFO.LabelTarget(unit, key) ~= nil, "uf labels: " .. unit .. " draws " .. key .. " and has its page")
    end
end
check(drawn.ufClassification.boss, "uf labels: boss draws the classification decorations")

-- Wiring in the companion, the units test settings and the TOC.
do
    local pv = uf_file_source("Preview.lua")
    check(pv:find('f:SetScript("OnClick", OnClick)', 1, true) ~= nil, "uf labels: previews get an OnClick")
    check(pv:find("TL:HandleClick(self, button)", 1, true) ~= nil, "uf labels: ...which hands off to Indicator Info")
    check(pv:find('f:SetScript("OnEnter", OnEnter)', 1, true) and pv:find('f:SetScript("OnLeave", OnLeave)', 1, true),
          "uf labels: ...and OnEnter / OnLeave are still set")
    check(pv:find("testShowLabels = true", 1, true) ~= nil, "uf labels: testShowLabels is a units test key")
    local defaults = uf_file_source("Defaults.lua")
    local td = defaults:match("UF%.TestDefaults = (%b{})")
    check(td and td:find("testShowLabels = true", 1, true), "uf labels: the units test defaults switch it on")
    local tm = options_file_source("UnitFrames/TestMode.lua")
    local general = tm:match("local function BuildGeneral%(rows%)(.-)\nend")
    check(general and general:find('label = L["Indicator Info"], key = "testShowLabels"', 1, true),
          "uf labels: the Units popup's General section has the Indicator Info row")
    local toc = options_file_source("DandersFrames_Options.toc"):gsub("\r\n", "\n")
    local a = toc:find("TestMode\\Labels.lua", 1, true)
    local b = toc:find("UnitFrames\\TestLabels.lua", 1, true)
    check(a and b and b > a, "uf labels: the TOC loads it after Labels.lua")
end

-- ============================================================
-- (b) BEHAVIOUR
-- ============================================================
local Mover = LibStub("DandersMover-1.0", true)
local fakeLib = false
if not Mover then
    Mover = LibStub:NewLibrary("DandersMover-1.0", 0)
    fakeLib = true
end
local prevIsUnlocked = rawget(Mover, "IsUnlocked")
local unlocked = false
Mover.IsUnlocked = function() return unlocked end

DFt:UpdateTestLabels()
local driver
for _, f in ipairs(created) do if f._scripts.OnUpdate then driver = f end end
check(driver ~= nil, "uf labels: the hover driver runs")
local function tick(n) for _ = 1, (n or 1) do driver._scripts.OnUpdate(driver, 0.06) end end
local function ownTip()
    for _, f in ipairs(created) do if f._kind == "GameTooltip" and f ~= GameTooltip then return f end end
end
local function clear() for i = #calls, 1, -1 do calls[i] = nil end end
local function click(f, x, y, button)
    CX, CY = x, y
    clear()
    return TL:HandleClick(f, button or "LeftButton")
end
local function opened()
    eq(#calls, 1, "uf labels: one navigation, no mode switch")
    local c = calls[#calls] or {}
    return c[2], c[3], c[1]
end

-- Smallest wins: portrait, cast bar and dragon over the health bar.
CX, CY = 110, 150
tick(3)
local w = target.dfTestLabels and target.dfTestLabels.ufPortrait
check(w and w.host:IsShown(), "uf labels: hovering the portrait marks the portrait")
check(not (target.dfTestLabels.health and target.dfTestLabels.health.host:IsShown()), "uf labels: ...not the health bar")
local lines = ownTip()._lines or {}
eq(lines[1], "Portrait", "uf labels: the tooltip names the portrait")
eq(lines[2], "target > Portrait", "uf labels: ...and the unit's page")
eq(lines[3], "Click to open settings", "uf labels: ...and says it can be clicked")
eq(#mouseOn, 0, "uf labels: nothing Indicator Info creates takes the mouse")

check(click(target, 110, 150), "uf labels: a click on the portrait opens settings")
local page, section, how = opened()
eq(how, "link", "uf labels: ...through the shared link action")
eq(page, "uf_target_portrait", "uf labels: ...on the target's Portrait page")
eq(section, nil, "uf labels: ...at the top")

click(target, 170, 116)
page = opened()
eq(page, "uf_target_castbar", "uf labels: the cast bar over the health bar opens the target's Cast Bar page")

click(target, 210, 155)
page, section = opened()
eq(page, "uf_target_unitIcons", "uf labels: the dragon over the health bar opens the target's Unit Icons page")
eq(section, "Elite Dragon", "uf labels: ...at Elite Dragon")

click(target, 180, 175)
page, section = opened()
eq(page, "uf_target_unitIcons", "uf labels: the dragon piece above the frame is measured where it draws")

-- A hidden dragon piece is never a target.
click(target, 105, 155)
page = opened()
eq(page, "uf_target_portrait", "uf labels: a hidden dragon piece is skipped")

-- The health bar, and the frame.
click(target, 160, 140)
page, section = opened()
eq(page, "uf_target_health", "uf labels: the health bar opens the target's Health Bar page")
eq(section, nil, "uf labels: ...with no section")
click(target, 160, 104)
page = opened()
eq(page, "uf_target_frame", "uf labels: elsewhere on the preview opens the target's Frame page")

-- A role icon: the target's Icons page has no Role Icon card -> the page, no section.
click(target, 153, 143)
page, section = opened()
eq(page, "uf_target_icons", "uf labels: an icon opens the unit's Icons page")
eq(section, nil, "uf labels: ...without a section that page does not show")

-- Missing Buffs has no unit page: the health bar under it answers.
target.missingBuffStrip:Show()
DFt:UpdateTestLabels()
click(target, 180, 130)
page = opened()
eq(page, "uf_target_health", "uf labels: an element without a unit page is never labelled")

-- Sections only where the unit's page shows them.
click(pet, 310, 115)
page, section = opened()
eq(page, "uf_pet_absorbs", "uf labels: the pet's heal absorb opens the pet's Absorbs page")
eq(section, nil, "uf labels: ...with no Heal Absorb section (the pet's page has none)")
click(player, 510, 115)
page, section = opened()
eq(page, "uf_player_absorbs", "uf labels: the player's heal absorb opens the player's Absorbs page")
eq(section, "Heal Absorb", "uf labels: ...at Heal Absorb")
click(pet, 390, 115)
page, section = opened()
eq(section, "Absorb Shield", "uf labels: the pet's absorb shield gets its section")

-- Class power below the player's frame (hover measures it; see the report on clicks
-- outside a frame's own rect).
click(player, 560, 95)
page = opened()
eq(page, "uf_player_classpower", "uf labels: the class power bar opens the player's Class Power page")

-- Boss slots open the boss pages.
click(boss1, 760, 130)
page = opened()
eq(page, "uf_boss_health", "uf labels: a boss slot opens the boss's Health Bar page")
click(boss1, 790, 170)
page, section = opened()
eq(page, "uf_boss_unitIcons", "uf labels: the boss dragon opens the boss's Unit Icons page")
eq(section, "Elite Dragon", "uf labels: ...at Elite Dragon")
click(boss1, 760, 100.5)
page, section = opened()
eq(page, "uf_boss_unitIcons", "uf labels: the class border edge opens Unit Icons")
eq(section, "Classification Border", "uf labels: ...at Classification Border")

-- The window closed: opened first.
DFt.GUIFrame = nil
local toggled = 0
function DFt:ToggleGUI() toggled = toggled + 1; DFt.GUIFrame = frame("Frame") end
click(target, 160, 140)
eq(toggled, 1, "uf labels: a closed window is opened")
eq(calls[#calls] and calls[#calls][2], "uf_target_health", "uf labels: ...then navigated")

-- Party is untouched.
click(party, 950, 130)
eq(#calls, 1, "uf labels: a party frame navigates once")
eq(calls[1] and calls[1][2], "bars_health", "uf labels: ...to the group Health Bar page")

-- Refusals.
check(not click(target, 110, 150, "RightButton"), "uf labels: a right click does nothing")
combat = true
check(not click(target, 110, 150), "uf labels: in combat it does nothing")
combat = false
unlocked = true
check(not click(target, 110, 150), "uf labels: during a mover session it does nothing")
unlocked = false
testDB.testShowLabels = false
check(not click(target, 110, 150), "uf labels: with the units Indicator Info off it does nothing")
DFt:UpdateTestLabels()
check(not click(target, 110, 150), "uf labels: ...also after a rebuild")
check(click(party, 950, 130), "uf labels: ...while party keeps its own switch")
testDB.testShowLabels = true
P._test = false
DFt:UpdateTestLabels()
check(not click(target, 110, 150), "uf labels: with the units test mode off (a mover-only preview) it does nothing")
P._test = true
clear()

-- Every repaint, show and hide asks for one coalesced rebuild next tick.
flushTimers()
relabels = 0
P:Refresh(); P:Refresh(); B:PreviewRefresh()
eq(relabels, 0, "uf labels: the rebuild waits a tick")
flushTimers()
eq(relabels, 1, "uf labels: ...and coalesces into one")
P:Hide(); flushTimers()
eq(relabels, 2, "uf labels: a hide rebuilds")
P:Show(); flushTimers()
eq(relabels, 3, "uf labels: a show rebuilds")
check(click(target, 110, 150), "uf labels: still clickable after the rebuilds")

-- ============================================================
-- TEARDOWN
-- ============================================================
DFt:ClearTestLabels()
if fakeLib then Mover.IsUnlocked = nil else Mover.IsUnlocked = prevIsUnlocked end
CreateFrame, C_Timer, GameTooltip = saved.CreateFrame, saved.C_Timer, saved.GameTooltip
GetCursorPosition, DandersFrames = saved.GetCursorPosition, saved.DandersFrames
InCombatLockdown, hooksecurefunc = saved.InCombatLockdown, saved.hooksecurefunc
