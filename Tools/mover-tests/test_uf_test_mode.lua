local NS = ...

-- ============================================================
-- UNIT FRAMES -- THE UNITS MODE OF THE TEST POPUP
-- DandersFrames_Options/UnitFrames/TestMode.lua over the real companion
-- (Core / Links / Defaults / Preview), the REAL registry (TestMode/Modes.lua),
-- the REAL popup (lifted out of TestMode/TestMode.lua, Party and Raid
-- included), the real icon rail and row list, and fake frames. Checks: Units
-- registers as a mode (label, icon, order, sections), every row reads and
-- writes the units test settings (or the boss table for the boss rows), greys
-- as the old panel's did, entering turns the units preview on and leaving /
-- closing turns it off, party / raid and units never run together, the popup
-- follows a Unit Frames page (isCurrent) both ways, the Test button and
-- /df test units open it on Units, and the old panel is gone.
--
-- ⚠ Fakes, not WoW: a green run says the wiring holds, not that it renders.
-- ☠ Every global it replaces is restored at the end.
-- ============================================================

local saved = {
    CreateFrame = CreateFrame, PlaySound = PlaySound, SOUNDKIT = SOUNDKIT, UIParent = UIParent,
    UISpecialFrames = UISpecialFrames, tinsert = tinsert, C_Timer = C_Timer,
    geterrorhandler = geterrorhandler, DandersFrames = DandersFrames, hooksecurefunc = hooksecurefunc,
    InCombatLockdown = InCombatLockdown,
}

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

-- ---- fake frames (test_test_popup.lua's) ----------------------------------
local function noop() end
local FIELDS = { LabelHit = true, Chevron = true, Control = true, Value = true, Label = true,
                 Fill = true, Knob = true, Slider = true, Thumb = true, ScrollBar = true,
                 Scroll = true, Child = true, Text = true, Icon = true, Plate = true, Badge = true }
local FrameMT = { __index = function(_, k)
    if type(k) == "string" and k:match("^%u") and not FIELDS[k] then return noop end
end }
local function Frame(kind)
    local f = setmetatable({ kind = kind, shown = true, scripts = {}, points = {}, mouse = true,
                             alpha = 1, w = 0, h = 0 }, FrameMT)
    function f:SetScript(n, fn) self.scripts[n] = fn end
    function f:GetScript(n) return self.scripts[n] end
    function f:HookScript(n, fn) self.scripts["hook:" .. n] = fn end
    function f:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function f:ClearAllPoints() self.points = {} end
    function f:Show()
        if self.shown then return end
        self.shown = true
        if self.scripts.OnShow then self.scripts.OnShow(self) end
    end
    function f:Hide()
        if not self.shown then return end
        self.shown = false
        if self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    function f:IsShown() return self.shown end
    function f:SetSize(w, h) self.w, self.h = w, h end
    function f:SetWidth(w) self.w = w end
    function f:SetHeight(h) self.h = h end
    function f:GetWidth() return self.w end
    function f:GetHeight() return self.h end
    function f:SetAlpha(a) self.alpha = a end
    function f:EnableMouse(v) self.mouse = v and true or false end
    function f:SetText(t) self.text = t end
    function f:GetText() return self.text end
    function f:SetTextColor(r, g, b) self.color = { r, g, b } end
    function f:SetVertexColor(r, g, b, a) self.color = { r, g, b, a } end
    function f:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
    function f:SetTexture(t) self.texture = t end
    function f:GetStringWidth() return #(self.text or "") * 5 end
    function f:GetFrameLevel() return 1 end
    function f:CreateTexture() return Frame("Texture") end
    function f:CreateFontString() return Frame("FontString") end
    if kind == "Slider" then
        f.value, f.lo, f.hi = 0, 0, 1
        function f:SetMinMaxValues(lo, hi)
            self.lo, self.hi = lo, hi
            local v = math.min(math.max(self.value, lo), hi)
            if v ~= self.value then self:SetValue(v) end
        end
        function f:SetValue(v)
            v = math.min(math.max(v, self.lo), self.hi)
            if v == self.value then return end
            self.value = v
            if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v) end
        end
        function f:GetValue() return self.value end
    end
    if kind == "ScrollFrame" then
        f.ScrollBar = Frame("Frame")
        function f:SetScrollChild(c) self.child = c end
        function f:SetVerticalScroll(v) self.scrollY = v end
    end
    return f
end
PlaySound = noop
SOUNDKIT = {}
UIParent = Frame("Frame")
UISpecialFrames = {}
tinsert = table.insert
C_Timer = { After = noop }
local IN_COMBAT = false
InCombatLockdown = function() return IN_COMBAT end
local reported = {}
geterrorhandler = function() return function(e) reported[#reported + 1] = tostring(e) end end
hooksecurefunc = function(t, name, fn)
    local orig = t[name]
    t[name] = function(...) local r = orig(...); fn(...); return r end
end

-- ---- the host (DF.GUI) -----------------------------------------------------
local col = { r = 0.5, g = 0.5, b = 0.5, a = 0.95 }
local GUI = {
    MEDIA = "Media\\",
    Colors = { background = col, panel = col, element = col, border = col, hover = col,
               notice = col, text = { r = 0.9, g = 0.9, b = 0.9 }, textDim = { r = 0.6, g = 0.6, b = 0.6 } },
    Scroll = { bar = 10, pad = 4 },
    StyleScrollBar = noop, PinScrollBar = noop,
    SelectedMode = "party",
    UnitsAccent = { r = 0.2, g = 0.8, b = 0.4 },
}
function GUI:GetAccent() return col end
function GUI.GetThemeColorFor() return col end
function GUI:ShowTooltip() end
function GUI:HideTooltip() end
function GUI:CreateElementBackdrop() end
function GUI:CreatePanelBackdrop() end
function GUI:IsModulePickLocked() return false end
function GUI:CreateSelectionMarker()
    local m = Frame("Texture")
    function m:SetTo(target) self.owner = target end
    function m:Clear() self.owner = nil end
    return m
end
function GUI:CreateCloseButton(parent, opts)
    local b = Frame("Button")
    b.scripts.OnClick = function() opts.onClick(b) end
    return b
end
function GUI:CreateGlyphButton(parent, opts)
    local b = Frame("Button")
    b.opts = opts
    function b:SetGlyph(tex) self.glyph = tex end
    return b
end
function GUI:StyleButton(btn, opts)
    btn.Text = btn:CreateFontString()
    btn.Text:SetText(opts.text)
    function btn:SetActive(v) self.active = v end
    return btn
end
function GUI:CreateDropdownNative(_, opts)
    local c = Frame("Frame")
    c.opts = opts
    c.RebuildOptions = function(self, o) self.options = o end
    c.UpdateText, c.SetEnabled = noop, noop
    return c
end
-- The settings window's modules: Party / Raid (group) and Unit Frames, whose
-- def names its own test mode (Pages.lua testModeId).
local modules = { group = { id = "group" }, units = { id = "units", testModeId = "units" } }
local currentModule = "group"
function GUI.CurrentModuleId() return currentModule end
function GUI:GetModule(id) return modules[id or currentModule] end
local selectCalls = {}
function GUI:SelectModule(id, tab)
    selectCalls[#selectCalls + 1] = id .. ":" .. tostring(tab)
    currentModule = id
    if id == "group" and tab then GUI.SelectedMode = tab end
    -- The real switch repaints the window, which refreshes the popup from
    -- INSIDE the switch -- the re-entrant path the popup has to survive.
    if DandersFrames.TestPanel and DandersFrames.TestPanel:IsShown() then
        DandersFrames.TestPanel:UpdateStateNoCallback()
    end
    return true
end
local buttonUpdates = 0
GUI.UpdateTestButtonState = function() buttonUpdates = buttonUpdates + 1 end
local pagesOpened = {}
GUI.SelectTab = function(page) pagesOpened[#pagesOpened + 1] = page end

local uiNS = { __DandersUI = GUI }
CreateFrame = function(kind) return Frame(kind) end
load_ui_file_into("IconRail.lua", uiNS)
load_ui_file_into("RowList.lua", uiNS)

-- ---- DF ------------------------------------------------------------------
local DF = { PartyDefaults = {}, L = setmetatable({}, { __index = function(_, k) return k end }) }
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable() return true end
DF.RegisterCallback = function() end
local said = {}
function DF:Say(msg) said[#said + 1] = msg end
DandersFrames = DF
load_df_file_into("TestMode/Modes.lua", DF)
DF.GUI = GUI
DF.GUIFrame = Frame("Frame")
local dbP, dbR = {}, {}
function DF:GetDB() return dbP end
function DF:GetRaidDB() return dbR end
local ws = {}
function DF:GetWindowState() return ws end
local owners = { party = {}, raid = {} }
function DF:SetTestModeOwner(scope, owner, wanted) owners[scope][owner] = wanted and true or nil end
function DF:IsTestModeOwnedBy(scope, owner) return owners[scope][owner] and true or false end
function DF:ToggleTestMode()
    local s = GUI.SelectedMode == "raid" and "raid" or "party"
    DF:SetTestModeOwner(s, "user", not DF:IsTestModeOwnedBy(s, "user"))
end
function DF:ApplyTestPreset() end
function DF:GetActiveTestPreset() return nil end
DF.OnSliderDragStart, DF.OnSliderDragStop = noop, noop
DF.testMode, DF.raidTestMode = false, false

-- ---- the companion (its file-scope event wiring skipped) -------------------
CreateFrame = nil
local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Links.lua", UF)
load_uf_file_into("Defaults.lua", UF)
load_uf_file_into("Preview.lua", UF)
DF.db = { unitframes = deepcopy(UF.ProfileDefaults) }
UF.frames = {}
local P = UF.Preview
P:Init()
P.Show = function() P.shown = true end
P.Hide = function() P.shown = false end
local refreshes, soon = 0, 0
P.Refresh = function() refreshes = refreshes + 1 end
P.RequestRefresh = function() soon = soon + 1 end
DF.UnitFrames = UF
CreateFrame = function(kind) return Frame(kind) end

-- ---- the popup, lifted (test_test_popup.lua's way) --------------------------
local src = options_file_source("TestMode/TestMode.lua"):gsub("\r\n", "\n")
local t0 = src:find("local TEST_TOGGLE_DEFAULT_ON = {", 1, true)
local t1 = t0 and src:find("\n}\n", t0, true)
local p0 = src:find("-- TEST MODE POPUP", 1, true)
check(t0 and t1 and p0, "lift: the popup section is found")
if not (t0 and t1 and p0) then return end
p0 = src:sub(1, p0):match(".*()\n%-%- =") or p0
assert(loadstring("local DF, L = ...\n" .. src:sub(t0, t1 + 2) .. src:sub(p0), "@test_popup"))(DF, DF.L)

-- ---- the Unit Frames options table, as far as the mode reads it (Pages.lua) --
local UFO = { MODULE = "units" }
GUI.UnitFrameOptions = UFO
function UFO.UnitLabel(u) return "label:" .. u end
function UFO.IsTestModeOn() return P:IsTestMode() end
function UFO.SetTestMode(on) return P:SetTestMode(on) end
function UFO.ToggleTestMode() return UFO.SetTestMode(not UFO.IsTestModeOn()) end
function UFO.IsInstalled() return true end
function UFO.IsEnabled() return true end
UFO.pagesByUnit = { player = { absorbs = "uf_player_absorbs", castbar = "uf_player_castbar", buffs = "uf_player_buffs" } }
function UFO.FirstPageOf(u) return "uf_" .. u .. "_frame" end

load_options_file_into("UnitFrames/TestMode.lua", NS)

print("-- Units: registered as a mode of the popup")
local mode = DF:GetTestMode("units")
check(mode ~= nil, "registered as 'units'")
if not mode then return end
eq(mode.label(), "Units", "label: Units (the rail's)")
eq(mode.order, 30, "after Party (10) and Raid (20)")
check(tostring(mode.icon):find("person.png", 1, true), "icon: the settings rail's unit frames icon")
local secIds = {}
for _, s in ipairs(DF:GetTestModeSections("units")) do secIds[#secIds + 1] = s.id end
eq(table.concat(secIds, ","), "general,frames,target,bars,auras,icons", "sections: the old panel's, in order")
eq(mode.presets, nil, "no presets (the old panel had none)")
eq(DF:IsTestModeAvailable("units"), true, "available while the companion is loaded")
local toc = options_file_source("DandersFrames_Options.toc")
check(toc:find("UnitFrames\\TestMode.lua", 1, true), "the file is in the options TOC")
check(not toc:find("UnitFrames\\TestPanel.lua", 1, true), "...and the old panel is not")
check(io.open("DandersFrames_Options/UnitFrames/TestPanel.lua", "r") == nil, "the old panel's file is gone")

print("-- Following the settings window: Party there, Units on a Unit Frames page")
local panel = DF:CreateTestPanel()
DF:ToggleTestPanel()
eq(panel.state.modeId, "party", "a group page: the popup opens on Party")
eq(owners.party.user, true, "...claiming the party preview")
eq(P:IsTestMode(), false, "...the units preview is off")
GUI:SelectModule("units")
eq(panel.state.modeId, "units", "the window goes to Unit Frames: the popup follows to Units")
eq(P:IsTestMode(), true, "...the units preview comes on")
check(not owners.party.user and not owners.raid.user, "...and the party / raid preview goes (never both)")
check(panel:IsShown(), "...the popup stays open")
local railIds = table.concat(panel.rail:GetItemIds(), ",")
eq(railIds, "mode:party,mode:raid,mode:units,sec:general,sec:frames,sec:target,sec:bars,sec:auras,sec:icons",
   "rail: Party, Raid, Units, then the Units sections")
check(panel.rail:IsFilled("mode:units"), "rail: Units filled")
check(panel.previewBtn:IsShown() and panel.previewBtn.glyph:find("preview.png", 1, true), "header: the preview is on")

print("-- Picking Party leaves Unit Frames; picking Units goes back")
panel:OnRailPick("mode:party")
eq(panel.state.modeId, "party", "Party picked")
eq(currentModule, "group", "...the window left Unit Frames for Party")
eq(selectCalls[#selectCalls], "group:party", "...through the window's own switch")
eq(P:IsTestMode(), false, "...the units preview is off")
eq(owners.party.user, true, "...and the party preview is claimed")
panel:OnRailPick("mode:units")
eq(panel.state.modeId, "units", "Units picked")
eq(currentModule, "units", "...the window went to Unit Frames")
eq(P:IsTestMode(), true, "...units on")
check(not owners.party.user, "...party released")
panel:OnRailPick("mode:raid")
eq(GUI.SelectedMode, "raid", "Raid picked from Units: the window lands on Raid")
eq(owners.raid.user, true, "...claiming raid")
eq(P:IsTestMode(), false, "...units off")
panel:OnRailPick("mode:units")
GUI.SelectedMode = "party"

print("-- Closing turns the units preview off; opening on a Unit Frames page turns it on")
panel:Hide()
eq(P:IsTestMode(), false, "closed: units off")
DF:ToggleTestPanel()
eq(panel.state.modeId, "units", "reopened on a Unit Frames page: Units")
eq(P:IsTestMode(), true, "...units on")

print("-- Every old units test setting has a row, on the same key")
local keys = {}
for _, sec in ipairs(DF:GetTestModeSections("units")) do
    panel:OnRailPick("sec:" .. sec.id)
    for _, row in ipairs(panel.list:GetRows()) do
        if row.spec and row.spec.key then keys[row.spec.key] = sec.id end
    end
end
local want = {
    testAnimateHealth = "general", fixedHealth = "general", healthPercent = "general",
    showPlayer = "frames", showTarget = "frames", showTargetTarget = "frames", showFocus = "frames",
    showFocusTarget = "frames", showPet = "frames", bossPreviewCount = "frames", bossPreviewNum = "frames",
    classification = "target", reaction = "target",
    testShowAbsorbs = "bars", testShowHealPrediction = "bars", showCastBars = "bars", showClassPower = "bars",
    testShowAuras = "auras", testBuffCount = "auras", testDebuffCount = "auras",
    testShowStatusIcons = "icons", showRaidTarget = "icons", showLeader = "icons", showCombat = "icons",
}
for k, s in pairs(want) do eq(keys[k], s, "row: " .. k .. " under " .. s) end

local tdb = UF:GetTestDB()
print("-- Rows read and write the units test settings")
panel:OnRailPick("sec:frames")
local pet = panel.list:GetRow("showPet")
eq(pet.Control:GetChecked(), true, "Pet: on from the units test settings")
eq(pet.Label.text, "label:pet", "...labelled with the unit's name")
local r0 = refreshes
pet.Control.scripts.OnClick(pet.Control)
eq(tdb.showPet, false, "Pet: written to the units test settings")
check(refreshes > r0, "...and the preview repaints")
pet.Control.scripts.OnClick(pet.Control)
eq(tdb.showPet, true, "...and back")
check(panel.list:GetRow("showTarget").spec.link ~= nil, "a unit's label opens its first page")
panel.list:GetRow("showTarget").spec.link()
eq(pagesOpened[#pagesOpened], "uf_target_frame", "...the target's")
local boss = panel.list:GetRow("bossPreviewCount")
local count = panel.list:GetRow("bossPreviewNum")
eq(boss.Control:GetChecked(), true, "Boss: on by default")
boss.Control.scripts.OnClick(boss.Control)
eq(UF:GetStoredUnit("boss").bossPreviewCount, false, "Boss: the boss page's own Show Placeholder Frames")
eq(rawget(tdb, "bossPreviewCount"), nil, "...never a units test key")
check(count.off, "...and its Frame Count greys")
boss.Control.scripts.OnClick(boss.Control)
check(not count.off, "Boss back on: the count comes alive")
local s0 = soon
count.Control.Slider:SetValue(3)
eq(UF:GetStoredUnit("boss").bossPreviewNum, 3, "Frame Count: the boss page's own count")
check(soon > s0, "...one repaint per rendered frame while it moves")

panel:OnRailPick("sec:general")
local health, fixed = panel.list:GetRow("healthPercent"), panel.list:GetRow("fixedHealth")
check(health.off, "Fixed Health off: the Health slider greys")
fixed.Control.scripts.OnClick(fixed.Control)
eq(tdb.fixedHealth, true, "Fixed Health on")
check(not health.off, "...the Health slider comes alive")
eq(health.Value.text, "75%", "...showing the percent")
fixed.Control.scripts.OnClick(fixed.Control)

panel:OnRailPick("sec:target")
local cls = panel.list:GetRow("classification")
eq(cls.Control.options._order[1], "normal", "Classification: normal / elite / rare / rare elite / boss")
cls.Control.opts.set("rare")
eq(tdb.classification, "rare", "Classification written")
panel.list:GetRow("reaction").Control.opts.set("friendly")
eq(tdb.reaction, "friendly", "Reaction written")

panel:OnRailPick("sec:auras")
local buffs, showAuras = panel.list:GetRow("testBuffCount"), panel.list:GetRow("testShowAuras")
eq(buffs.Label.text, "Buffs", "the popup's Buffs label (no colon)")
buffs.Control.Slider:SetValue(4)
eq(tdb.testBuffCount, 4, "Buffs written")
showAuras.Control.scripts.OnClick(showAuras.Control)
eq(tdb.testShowAuras, false, "Show Auras off")
check(buffs.off and panel.list:GetRow("testDebuffCount").off, "...Buffs / Debuffs grey")
showAuras.Control.scripts.OnClick(showAuras.Control)

panel:OnRailPick("sec:icons")
local icons = panel.list:GetRow("testShowStatusIcons")
icons.Control.scripts.OnClick(icons.Control)
eq(tdb.testShowStatusIcons, false, "Icons off")
check(panel.list:GetRow("showLeader").off, "...the icon switches grey")
icons.Control.scripts.OnClick(icons.Control)
eq(rawget(DF.db.unitframes.global, "testMode"), tdb, "stored under the module table, apart from party / raid")

print("-- The header's preview toggle: off closes the popup")
panel.previewBtn.opts.onClick()
eq(P:IsTestMode(), false, "units off")
check(not panel:IsShown(), "...and the popup closes")

print("-- Combat ends the units preview and leaves the popup open")
DF:ToggleTestPanel()
eq(P:IsTestMode(), true, "open: on")
P:OnCombat()
eq(P:IsTestMode(), false, "combat: off")
check(panel:IsShown(), "...the popup stays open")
check(panel.previewBtn.glyph:find("preview_off.png", 1, true), "...its header says off")
IN_COMBAT = true
panel.previewBtn.opts.onClick()
eq(P:IsTestMode(), false, "in combat the preview cannot come back")
IN_COMBAT = false
panel:Hide()

print("-- The Test button: the popup, landing on Units")
local panelSrc = options_file_source("GUI/Panel.lua")
check(not panelSrc:find("ModuleTestRoute", 1, true), "the per-module panel route is gone")
check(panelSrc:find("GUI.ModuleTestMode = function()", 1, true), "the button asks the module for its mode id")
check(options_file_source("UnitFrames/Pages.lua"):find('testModeId = "units"', 1, true),
      "Unit Frames names its mode")

print("-- /df test units")
currentModule = "group"
UFO.ToggleTestPopup()
check(panel:IsShown(), "closed popup on a group page: opens")
eq(currentModule, "units", "...the window goes to Unit Frames")
eq(panel.state.modeId, "units", "...on Units")
eq(P:IsTestMode(), true, "...units on")
UFO.ToggleTestPopup()
check(not panel:IsShown(), "again: closes")
eq(P:IsTestMode(), false, "...units off")
currentModule = "group"
DF:ToggleTestPanel()
eq(panel.state.modeId, "party", "popup open on Party")
UFO.ToggleTestPopup()
eq(panel.state.modeId, "units", "/df test units moves it to Units")
check(panel:IsShown(), "...without closing it")
check(not owners.party.user, "...releasing party")
panel:Hide()
local core = (function()
    local fh = io.open("DandersFrames/Core.lua", "r")
    local s = fh and fh:read("*a") or ""
    if fh then fh:close() end
    return s
end)()
check(core:find("UFO.ToggleTestPopup()", 1, true), "/df test units calls the popup toggle")

print("-- A party claim from elsewhere turns units off")
DF:ToggleTestPanel()
eq(P:IsTestMode(), true, "units on")
DF:SetTestModeOwner("party", "user", true)
eq(P:IsTestMode(), false, "the user's party claim turns it off")
owners.party.user = nil
panel:Hide()

print("-- Unavailable without the companion")
DF.UnitFrames = nil
local ok, why = DF:IsTestModeAvailable("units")
eq(ok, false, "not loaded: unavailable")
eq(why, "Reload to finish turning on Unit Frames.", "...enabled but waiting for a reload says so")
UFO.IsEnabled = function() return false end
ok, why = DF:IsTestModeAvailable("units")
eq(why, "Unit Frames is not loaded.", "...switched off says so")
DF.UnitFrames = UF

eq(#reported, 0, "no errors reported through the popup")
for _, e in ipairs(reported) do print("  reported: " .. e) end

CreateFrame, PlaySound, SOUNDKIT, UIParent = saved.CreateFrame, saved.PlaySound, saved.SOUNDKIT, saved.UIParent
UISpecialFrames, tinsert, C_Timer = saved.UISpecialFrames, saved.tinsert, saved.C_Timer
geterrorhandler, DandersFrames, hooksecurefunc = saved.geterrorhandler, saved.DandersFrames, saved.hooksecurefunc
InCombatLockdown = saved.InCombatLockdown
