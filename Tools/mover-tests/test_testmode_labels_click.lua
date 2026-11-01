local NS = ...

-- ============================================================
-- TEST MODE "INDICATOR INFO" -- CLICK AN ELEMENT TO OPEN ITS SETTINGS
-- DandersFrames_Options/TestMode/Labels.lua (+ TestFramePool.lua's OnClick)
-- ------------------------------------------------------------
-- Two halves, both against the REAL files:
--   (a) SOURCE: every target's page id is a registered settings page, its
--       breadcrumb matches that page's real category and tab labels, and its
--       section text is a real section header on that page.
--   (b) BEHAVIOUR over fake frames: smallest region wins (an icon over the
--       health bar), a scaled icon is hit-tested where it draws, a click opens
--       the right page + mode + section, and it does nothing with labels off,
--       in combat, during a mover session or on a right click. The extension
--       seam registers a target and a frame source with its own open callback.
--
-- ⚠ Fakes, not WoW: a green run says the wiring holds, not that it renders.
-- ☠ ONE LUA RUNTIME IS SHARED BY EVERY SUITE. Every global replaced here is put
-- back at the end.
-- ============================================================

-- ============================================================
-- (a) SOURCE -- pages, breadcrumbs, sections
-- ============================================================
local PAGE_FILES = { "Auras", "Frames", "Indicators", "Modules", "Options", "Profiles" }
local PAGES = {}
for _, name in ipairs(PAGE_FILES) do
    PAGES[name] = options_file_source("GUI/Pages/" .. name .. ".lua"):gsub("\r\n", "\n")
end

-- page id -> { var, cat, tab }
local function pageInfo(id)
    for _, src in pairs(PAGES) do
        local var, cat, tab = src:match("local (%w+) = CreateSubTab%(\"([%w_]+)\", \"" .. id .. "\", L%[\"(.-)\"%]%)")
        if var then return { var = var, cat = cat, tab = tab } end
    end
end

local function categoryLabel(cat)
    for _, src in pairs(PAGES) do
        local label = src:match("CreateCategory%(\"" .. cat .. "\", L%[\"(.-)\"%]%)")
        if label then return label end
    end
end

-- The page's builder: from `BuildPage(<var>,` to the next BuildPage( in that file.
local function builderSlice(var)
    for _, src in pairs(PAGES) do
        local a = src:find("BuildPage(" .. var .. ",", 1, true)
        if a then
            local b = src:find("BuildPage(", a + 1, true)
            return src:sub(a, (b or #src + 1) - 1)
        end
    end
end

local function hasSection(slice, section)
    local lit = 'L["' .. section .. '"]'
    return slice:find("OpenSection(" .. lit, 1, true) ~= nil
        or slice:find("section = " .. lit, 1, true) ~= nil
end

-- ============================================================
-- (b) FAKES
-- ============================================================
local saved = {
    CreateFrame = CreateFrame, C_Timer = C_Timer, GameTooltip = GameTooltip,
    GetCursorPosition = GetCursorPosition, DandersFrames = DandersFrames,
    InCombatLockdown = InCombatLockdown,
}

local created = {}
local mouseOn = {}

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

-- rect = { l, r, b, t } in the frame's OWN space; scale = its effective scale.
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
C_Timer = { After = function() end }
GameTooltip = frame("GameTooltip")
local CX, CY = 0, 0
GetCursorPosition = function() return CX, CY end
local combat = false
InCombatLockdown = function() return combat end

-- ---- the frames ----------------------------------------------------
-- Party frame 100..220 x 100..160, health bar over its top 50px, a role icon at
-- scale 2 drawn at 105..123 x 140..158 in the FRAME's space (half that in its own).
local party = frame("Button", { 100, 220, 100, 160 })
party.isRaidFrame = false
party.healthBar = frame("StatusBar", { 100, 220, 110, 160 })
party.roleIcon = frame("Frame", { 52.5, 61.5, 70, 79 }, 2)
party.leaderIcon = frame("Frame", { 200, 210, 140, 150 })
party.leaderIcon:Hide()              -- hidden: must never be a target
local raid = frame("Button", { 300, 420, 100, 160 })
raid.isRaidFrame = true
raid.healthBar = frame("StatusBar", { 300, 420, 110, 160 })

local partyDb, raidDb = { testShowLabels = true }, { testShowLabels = true }
local DFt = {
    L = setmetatable({}, { __index = function(_, k) return k end }),
    testMode = true, raidTestMode = true,
    testPartyFrames = { [0] = party },
    testRaidFrames = { [1] = raid },
}
function DFt:GetDB() return partyDb end
function DFt:GetRaidDB() return raidDb end

-- ---- the settings window ------------------------------------------------
local calls = {}
local GUIt = { SelectedMode = "party" }
function GUIt:SelectModule(id, mode) calls[#calls + 1] = { "module", id, mode }; self.SelectedMode = mode end
function GUIt:LinkToSetting(t) calls[#calls + 1] = { "link", t.page, t.section } end
GUIt.SelectTab = function(p) calls[#calls + 1] = { "tab", p } end
DFt.GUI = GUIt
DFt.GUIFrame = frame("Frame")
DandersFrames = DFt

local src = options_file_source("TestMode/Labels.lua")
assert(loadstring(src, "@Labels.lua"))()
local TL = DFt.TestLabels

-- ============================================================
-- (a) every target, against the real pages
-- ============================================================
local described = TL:DescribeTargets()
check(#described >= 25, "click: every element has a target (" .. #described .. ")")
local seenKeys = {}
for _, t in ipairs(described) do
    check(not seenKeys[t.key], "click: target key " .. t.key .. " is unique")
    seenKeys[t.key] = true
    local info = t.page and pageInfo(t.page)
    check(info ~= nil, "click: " .. t.key .. " opens a registered page (" .. tostring(t.page) .. ")")
    if info then
        local crumbText = categoryLabel(info.cat) .. " > " .. info.tab
        eq(t.crumb, crumbText, "click: " .. t.key .. " breadcrumb matches the real category and tab labels")
        if t.section then
            local slice = builderSlice(info.var)
            check(slice ~= nil, "click: " .. t.page .. " has a page builder")
            check(slice and hasSection(slice, t.section),
                  "click: " .. t.key .. " section '" .. t.section .. "' is a section header on " .. t.page)
        end
    end
end
for _, key in ipairs({ "buff", "debuff", "defensive", "missing", "ad", "role", "leader", "raidTarget",
                       "readyCheck", "ping", "summon", "resurrection", "phased", "afk", "vehicle",
                       "raidRole", "bgCarrier", "combat", "rested", "text", "absorb", "healabsorb",
                       "healpred", "missinghealth", "power", "health", "dispel", "frame" }) do
    check(seenKeys[key], "click: target present -- " .. key)
end
eq(described[#described].key, "frame", "click: the frame fallback is the last target")
-- The one per-region section override.
do
    local info = pageInfo("auras_dispel")
    check(hasSection(builderSlice(info.var), "Dispel Symbol"), "click: 'Dispel Symbol' is a section on auras_dispel")
end

-- TestFramePool wires the click without replacing hover.
do
    local pool = options_file_source("TestMode/TestFramePool.lua")
    check(pool:find('SetScript("OnClick"', 1, true) ~= nil, "click: test frames get an OnClick")
    check(pool:find("TL:HandleClick(self, button)", 1, true) ~= nil, "click: ...which hands off to Indicator Info")
    check(pool:find('SetScript("OnEnter"', 1, true) and pool:find('SetScript("OnLeave"', 1, true),
          "click: ...and OnEnter / OnLeave are still set")
end

-- ============================================================
-- (b) behaviour
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
check(driver ~= nil, "click: the hover driver runs")
local function tick(n) for _ = 1, (n or 1) do driver._scripts.OnUpdate(driver, 0.06) end end
local function ownTip()
    for _, f in ipairs(created) do if f._kind == "GameTooltip" and f ~= GameTooltip then return f end end
end
local function last() return calls[#calls] end
local function clear() for i = #calls, 1, -1 do calls[i] = nil end end

-- Smallest wins: the role icon over the health bar over the frame.
CX, CY = 110, 150
tick(3)
local w = party.dfTestLabels and party.dfTestLabels.role
check(w and w.host:IsShown(), "click: hovering the icon marks the icon, not the bar under it")
check(not (party.dfTestLabels.health and party.dfTestLabels.health.host:IsShown()), "click: ...and not the health bar")
local hasHint = false
for _, line in ipairs(ownTip()._lines or {}) do if line == "Click to open settings" then hasHint = true end end
check(hasHint, "click: the tooltip says the element can be clicked")
eq(#mouseOn, 0, "click: still nothing Indicator Info creates takes the mouse")

-- Click opens the Icons page at the role card, party mode, no mode switch.
clear()
check(TL:HandleClick(party, "LeftButton"), "click: a left click on a marked icon opens settings")
eq(#calls, 1, "click: ...with one navigation and no mode switch")
eq(last()[2], "indicators_icons", "click: ...on the Icons page")
eq(last()[3], "Role Icon", "click: ...at the Role Icon card")

-- The health bar outside the icon.
CX, CY = 200, 120
clear()
TL:HandleClick(party, "LeftButton")
eq(last()[2], "bars_health", "click: the health bar opens the Health Bar page")
eq(last()[3], nil, "click: ...with no section")

-- The hidden leader icon's spot answers as the health bar.
CX, CY = 205, 145
clear()
TL:HandleClick(party, "LeftButton")
eq(last()[2], "bars_health", "click: a hidden icon is never a target")

-- Anywhere else on the frame: the fallback.
CX, CY = 200, 104
clear()
TL:HandleClick(party, "LeftButton")
eq(last()[2], "general_frame", "click: elsewhere on the frame opens the Frame page")

-- A raid frame switches the window to raid first.
CX, CY = 350, 130
clear()
TL:HandleClick(raid, "LeftButton")
eq(#calls, 2, "click: a raid frame with the window on party switches mode then navigates")
eq(calls[1][1], "module", "click: ...mode switch first")
eq(calls[1][2], "group", "click: ...through the group module")
eq(calls[1][3], "raid", "click: ...to raid")
eq(calls[2][2], "bars_health", "click: ...then the page")

-- Refusals.
CX, CY = 110, 150
clear()
check(not TL:HandleClick(party, "RightButton"), "click: a right click does nothing")
combat = true
check(not TL:HandleClick(party, "LeftButton"), "click: in combat it does nothing")
tick()
local hintInCombat = false
for _, line in ipairs(ownTip()._lines or {}) do if line == "Click to open settings" then hintInCombat = true end end
check(not hintInCombat, "click: ...and the tooltip stops offering it")
combat = false
unlocked = true
check(not TL:HandleClick(party, "LeftButton"), "click: during a mover session it does nothing")
unlocked = false
partyDb.testShowLabels = false
check(not TL:HandleClick(party, "LeftButton"), "click: with Indicator Info off it does nothing")
DFt:UpdateTestLabels()
check(not TL:HandleClick(party, "LeftButton"), "click: ...also after a rebuild")
eq(#calls, 0, "click: no refusal navigated anywhere")
partyDb.testShowLabels = true

-- Window closed: it is opened first.
DFt.GUIFrame = nil
local toggled = 0
function DFt:ToggleGUI() toggled = toggled + 1; DFt.GUIFrame = frame("Frame") end
DFt:UpdateTestLabels()
clear()
TL:HandleClick(party, "LeftButton")
eq(toggled, 1, "click: a closed window is opened")
eq(last()[2], "indicators_icons", "click: ...then navigated")

-- ============================================================
-- the extension seam
-- ============================================================
local extraObj = frame("Frame", { 150, 156, 112, 118 })
check(TL:RegisterTarget({
    key = "extra", page = "general_frame", section = "Frame Size", label = "Extra", crumb = "General > Frame",
    find = function(f, add) if f == party then add(extraObj) end end,
}), "seam: a target registers")
check(not TL:RegisterTarget({ key = "extra", page = "x", find = function() end }), "seam: a duplicate key is refused")
check(not TL:RegisterTarget({ key = "nofind", page = "x" }), "seam: a target without find is refused")

local other = frame("Button", { 500, 600, 100, 160 })
local otherWants = true
local opened
check(TL:RegisterFrameSource({
    id = "other",
    each = function(fn) fn(other) end,
    wants = function() return otherWants end,
    open = function(f, target, section) opened = { f, target.key, target.page, section } end,
}), "seam: a frame source registers")
check(not TL:RegisterFrameSource({ id = "other", each = function() end, wants = function() end }),
      "seam: a duplicate source id is refused")
check(not TL:RegisterFrameSource({ id = "party", each = function() end, wants = function() end }),
      "seam: a built-in source id is refused")

DFt:UpdateTestLabels()
CX, CY = 152, 115
clear()
TL:HandleClick(party, "LeftButton")
eq(last()[2], "general_frame", "seam: a registered target opens its page")
eq(last()[3], "Frame Size", "seam: ...at its section")
eq(described[#described].key, "frame", "seam: (described before registering)")
local after = TL:DescribeTargets()
eq(after[#after].key, "frame", "seam: the frame fallback stays last")
eq(after[#after - 1].key, "extra", "seam: ...with the registered target just before it")

CX, CY = 550, 130
clear()
check(TL:HandleClick(other, "LeftButton"), "seam: a source's frame is clickable")
check(opened and opened[1] == other, "seam: ...and its own open callback gets the frame")
eq(opened and opened[2], "frame", "seam: ...the target")
eq(opened and opened[3], "general_frame", "seam: ...and the target's page")
eq(#calls, 0, "seam: ...instead of the group navigation")
otherWants = false
opened = nil
check(not TL:HandleClick(other, "LeftButton"), "seam: a source that stops wanting is not clickable")

-- ============================================================
-- TEARDOWN
-- ============================================================
DFt:ClearTestLabels()
if fakeLib then Mover.IsUnlocked = nil else Mover.IsUnlocked = prevIsUnlocked end
CreateFrame, C_Timer, GameTooltip = saved.CreateFrame, saved.C_Timer, saved.GameTooltip
GetCursorPosition, DandersFrames = saved.GetCursorPosition, saved.DandersFrames
InCombatLockdown = saved.InCombatLockdown
