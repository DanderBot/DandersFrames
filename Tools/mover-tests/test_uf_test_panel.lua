local NS = ...

-- ============================================================
-- UNIT FRAMES -- THE UNITS TEST PANEL
-- DandersFrames_Options/UnitFrames/TestPanel.lua over the real companion
-- (Core / Links / Defaults / Preview), the REAL test panel kit (lifted out of
-- TestMode/TestMode.lua, as the party / raid panel builds from it) and stub
-- frames. Checks: built like the party panel (its kit, its section names and
-- labels where the concepts are shared, its description), every control reads
-- and writes the UNITS test settings (or the boss table for the boss rows),
-- greys like the party panel's, opening turns the units test mode on and
-- closing turns it off, the party / raid test mode taking over closes it, and
-- nothing is registered with settings search.
-- ============================================================

local saved = {
    DandersFrames = DandersFrames, CreateFrame = CreateFrame, C_Timer = C_Timer,
    UISpecialFrames = UISpecialFrames, UIParent = UIParent, hooksecurefunc = hooksecurefunc,
    PlaySound = PlaySound, SOUNDKIT = SOUNDKIT,
}
C_Timer = { After = function(_, fn) fn() end }
UISpecialFrames = {}
UIParent = UIParent or {}
PlaySound = function() end
SOUNDKIT = {}

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

-- ---- stub frames -------------------------------------------------------------
local function noop() end
local FrameMT = { __index = function(_, k)
    if type(k) == "string" and k:match("^%u") then return noop end
end }
local function Frame()
    local f = setmetatable({ shown = true, scripts = {}, hooks = {}, points = {} }, FrameMT)
    f.Hide = function(self)
        local was = self.shown
        self.shown = false
        if was and self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    f.Show = function(self) self.shown = true end
    f.IsShown = function(self) return self.shown end
    f.SetShown = function(self, v) self.shown = v and true or false end
    f.SetScript = function(self, name, fn) self.scripts[name] = fn end
    f.GetScript = function(self, name) return self.scripts[name] end
    f.HookScript = function(self, name, fn) self.hooks[#self.hooks + 1] = { name, fn } end
    f.SetParent = function(self, p) self.parent = p end
    f.SetHeight = function(self, h) self.height = h end
    f.SetPoint = function(self, ...) self.points[#self.points + 1] = { ... } end
    f.SetValue = function(self, v)
        self.value = v
        for _, h in ipairs(self.hooks) do if h[1] == "OnValueChanged" then h[2](self, v) end end
    end
    f.GetValue = function(self) return self.value or 0 end
    f.EnableMouse = function(self, on) self.mouse = on end
    f.CreateFontString = function()
        local fs = Frame()
        fs.SetText = function(self, t) self.text = t end
        fs.GetStringWidth = function() return 40 end
        fs.SetTextColor = function(self, r, g, b) self.color = { r, g, b } end
        return fs
    end
    f.CreateTexture = function() return Frame() end
    return f
end

-- ---- DandersFrames ------------------------------------------------------------
local DF = { PartyDefaults = {}, L = setmetatable({}, { __index = function(_, k) return k end }) }
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable() return true end
DF.RegisterCallback = function() end
DF._owners = { party = {}, raid = {} }
function DF:IsTestModeOwnedBy(scope, owner) return self._owners[scope][owner] and true or false end
function DF:SetTestModeOwner(scope, owner, wanted) self._owners[scope][owner] = wanted and true or nil end
DandersFrames = DF
hooksecurefunc = function(t, name, fn)
    local orig = t[name]
    t[name] = function(...) local r = orig(...); fn(...); return r end
end

CreateFrame = nil        -- the companion's file-scope event wiring is skipped
local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Links.lua", UF)
load_uf_file_into("Defaults.lua", UF)
load_uf_file_into("Preview.lua", UF)
DF.db = { unitframes = deepcopy(UF.ProfileDefaults) }
UF.frames = {}
local P = UF.Preview
P:Init()
-- The preview's frames are not what this suite is about.
P.Show = function() P.shown = true end
P.Hide = function() P.shown = false end
local refreshes, soon = 0, 0
P.Refresh = function() refreshes = refreshes + 1 end
P.RequestRefresh = function() soon = soon + 1 end
CreateFrame = function() return Frame() end

-- ---- the GUI the panel and the kit draw with ---------------------------------
local dropdowns, buttonState = {}, {}
local col = { r = 1, g = 1, b = 1 }
local G = { Colors = {
    text = col, textDim = { r = 0.5, g = 0.5, b = 0.5 }, accent = { r = 0.6, g = 0.4, b = 1 },
    background = { r = 0, g = 0, b = 0, a = 0.9 }, border = col, panel = col, element = col, hover = col,
} }
function G:CreateDropdown(parent, label, options, db, key, cb, get, set, opts)
    local d = Frame()
    d.label, d.options, d.db, d.key, d.cb, d.get, d.set, d.opts = label, options, db, key, cb, get, set, opts
    dropdowns[label] = d
    return d
end
function G:CreatePanelBackdrop() end
function G:CreateElementBackdrop() end
function G:CreateCloseButton() return Frame() end
function G:StyleCheckButton() return Frame() end
function G:ShowTooltip() end
function G:HideTooltip() end
function G:StyleButton(btn)
    btn.Text = btn:CreateFontString()
    btn.SetActive = function(self, on) self.active = on end
end
function G.GetThemeColor() return G.Colors.accent end
G.UpdateTestButtonState = function() buttonState[#buttonState + 1] = true end
DF.GUI = G
DF.Search = {}

-- The REAL kit, lifted out of TestMode.lua by its section header (the file builds
-- the party panel and test data at file scope, so it is not loaded whole).
do
    local src = options_file_source("TestMode/TestMode.lua"):gsub("\r\n", "\n")
    local a = src:find("-- TEST PANEL WIDGET KIT", 1, true)
    local b = src:find("function DF:CreateTestPanel()", 1, true)
    assert(a and b, "the kit section in TestMode.lua")
    assert(loadstring("local DF, L = ...\n" .. src:sub(a, b - 1), "@test_panel_kit"))(DF, DF.L)
end

-- The Unit Frames options table, as far as the panel reads it (Pages.lua).
local UFO = {}
G.UnitFrameOptions = UFO
DF.UnitFrames = UF
function UFO.UnitLabel(u) return "label:" .. u end
function UFO.IsTestModeOn() return P:IsTestMode() end
function UFO.SetTestMode(on) return P:SetTestMode(on) end
UFO.pagesByUnit = { player = { absorbs = "uf_player_absorbs", castbar = "uf_player_castbar", buffs = "uf_player_buffs" } }
function UFO.FirstPageOf(u) return "uf_" .. u .. "_frame" end

load_options_file_into("UnitFrames/TestPanel.lua", NS)
check(type(UFO.ToggleTestPanel) == "function", "the panel's toggle is published")
check(options_file_source("DandersFrames_Options.toc"):find("UnitFrames\\TestPanel.lua", 1, true),
      "...and the file is in the options TOC")
check(options_file_source("UnitFrames/TestPanel.lua"):find("DF:CreateTestPanelKit(", 1, true),
      "built from the party panel's own kit")

print("-- Opening: the units test mode on")
UFO.ToggleTestPanel()
local panel = UFO.testPanel
check(panel ~= nil, "built on first open")
eq(panel:IsShown(), true, "shown")
eq(P:IsTestMode(), true, "the units test mode is on")
eq(UFO.IsTestPanelShown(), true, "IsTestPanelShown")
eq(panel.toggle.Text.text, "Disable Test Mode", "its toggle offers to turn it off")
check(#buttonState > 0, "the window's Test button is told")
eq(DF.Search.SuppressRegistration, nil, "search registration is restored after the build")
eq(panel.title.text, "Test Mode", "the party panel's title")
eq(panel.badge.text.text, "Unit Frames", "...and its badge, naming this test mode")

print("-- Sections: the party panel's names where the two share them")
local function sectionTitles()
    local out = {}
    for _, cb in ipairs(panel.checks) do
        local t = cb.section and cb.section.titleText and cb.section.titleText.text
        if t and out[#out] ~= t then out[#out + 1] = t end
    end
    return table.concat(out, ",")
end
eq(sectionTitles(), "GENERAL,FRAMES,BARS & OVERLAYS,AURAS,INDICATORS & ICONS",
   "sections with switches, in the party panel's order (Target holds dropdowns)")
local byLabel = {}
for _, cb in ipairs(panel.checks) do byLabel[cb.labelText.text] = cb end
for _, l in ipairs({ "Animate Health", "Fixed Health", "label:player", "label:target", "label:targettarget",
                     "label:focus", "label:focustarget", "label:pet", "Boss", "Absorbs", "Heal Prediction",
                     "Cast Bar", "Class Power", "Show Auras", "Icons", "Raid Target Icon", "Leader Icon",
                     "Combat Icon" }) do
    check(byLabel[l] ~= nil, "checkbox: " .. l)
end
check(byLabel["Status Icons"] == nil, "the status icons switch is the party panel's Icons")
eq(byLabel["Animate Health"].section.titleText.text, "GENERAL", "Animate Health under General, as in the party panel")
eq(byLabel["Absorbs"].section.titleText.text, "BARS & OVERLAYS", "Absorbs under Bars & Overlays")
eq(byLabel["Icons"].section.titleText.text, "INDICATORS & ICONS", "Icons under Indicators & Icons")
local rowLabels = {}
for _, part in ipairs(panel.rows) do
    if part.text then rowLabels[#rowLabels + 1] = part.text.text end
end
eq(table.concat(rowLabels, ","), "Health,Frame Count,Classification,Reaction,Buffs:,Debuffs:",
   "slider / dropdown rows: the party panel's Frame Count and Buffs: / Debuffs: labels")
check(dropdowns.Classification and dropdowns.Classification.opts and dropdowns.Classification.opts.inline,
      "the sample target: compact inline dropdowns")
eq(dropdowns.Classification.db, nil, "...get / set, not bound to a page table")

print("-- Labels open settings pages, as the party panel's do")
check(byLabel["Absorbs"].labelBtn ~= nil, "Absorbs: a page link")
check(byLabel["label:target"].labelBtn ~= nil, "a unit: its first page")
check(byLabel["Animate Health"].labelBtn == nil, "Animate Health: no page, a plain label")

print("-- Controls read and write the units test settings")
local tdb = UF:GetTestDB()
local pet = byLabel["label:pet"]
eq(pet.checked, true, "Pet: shown from the units test settings")
local r0 = refreshes
pet.box.scripts.OnClick(pet.box)
eq(tdb.showPet, false, "Pet: written to the units test settings")
check(refreshes > r0, "...and the preview repaints")
pet.box.scripts.OnClick(pet.box)
eq(tdb.showPet, true, "...and back")
dropdowns.Classification.set("rare")
eq(tdb.classification, "rare", "Classification")
eq(dropdowns.Classification.options._order[1], "normal", "...normal / elite / rare / rare elite / boss")
local function Row(label)
    for _, part in ipairs(panel.rows) do if part.text.text == label then return part end end
end
local buffs = Row("Buffs:")
local s0 = soon
buffs.slider:SetValue(4)
eq(tdb.testBuffCount, 4, "Buffs:")
eq(buffs.value.text, "4", "...its value beside it")
check(soon > s0, "...one repaint per rendered frame, while dragging too")
eq(rawget(DF.db.unitframes.global, "testMode"), tdb, "stored under the module table, apart from party / raid")
local boss = byLabel["Boss"]
eq(boss.checked, true, "Boss: on by default")
boss.box.scripts.OnClick(boss.box)
eq(UF:GetStoredUnit("boss").bossPreviewCount, false, "Boss: the boss page's own Show Placeholder Frames")
eq(rawget(tdb, "bossPreviewCount"), nil, "...never a units test key")
local count = Row("Frame Count")
count.slider:SetValue(3)
eq(UF:GetStoredUnit("boss").bossPreviewNum, 3, "Frame Count: the boss page's own count")

print("-- Grey when disabled")
panel.RefreshDependentEnabled()
eq(count.slider.dfDisabled, true, "Boss off: its count greys")
local health = Row("Health")
eq(health.slider.dfDisabled, true, "Fixed Health off: the Health slider greys")
local fixed = byLabel["Fixed Health"]
fixed.box.scripts.OnClick(fixed.box)
eq(tdb.fixedHealth, true, "Fixed Health on")
eq(health.slider.dfDisabled, false, "...and the Health slider comes back with it")
local icons = byLabel["Icons"]
icons.box.scripts.OnClick(icons.box)
eq(tdb.testShowStatusIcons, false, "Icons off")
eq(byLabel["Leader Icon"].dfDisabled, true, "...the icon switches grey")
local showAuras = byLabel["Show Auras"]
showAuras.box.scripts.OnClick(showAuras.box)
eq(buffs.slider.dfDisabled, true, "Show Auras off: Buffs: / Debuffs: grey")
showAuras.box.scripts.OnClick(showAuras.box)
icons.box.scripts.OnClick(icons.box)
fixed.box.scripts.OnClick(fixed.box)
boss.box.scripts.OnClick(boss.box)

print("-- Sections fold into the units test settings, apart from the party panel's")
local sec = byLabel["Absorbs"].section
sec.header.scripts.OnClick()
eq(tdb.panelSections and tdb.panelSections.bars, true, "folded state kept with the units test settings")
eq(DF.db.testPanelSections, nil, "...never the party panel's store")

print("-- UpdateState re-reads every value")
tdb.testDebuffCount = 1
panel:UpdateState()
eq(Row("Debuffs:").value.text, "1", "a value written elsewhere shows on the next show")
eq(tdb.testDebuffCount, 1, "...and reading it back writes nothing")
eq(sec.expanded, true, "...and a section keeps its fold")

print("-- The toggle: off, and the panel closes")
panel.toggle.scripts.OnClick()
eq(panel:IsShown(), false, "closed")
eq(P:IsTestMode(), false, "the units test mode is off")

print("-- The party / raid test mode taking over closes it")
UFO.ToggleTestPanel()
eq(P:IsTestMode(), true, "open again: on")
DF:SetTestModeOwner("party", "user", true)
eq(P:IsTestMode(), false, "the user's party claim turns it off")
eq(panel:IsShown(), false, "...and closes the panel")
DF._owners.party.user = nil

print("-- Closing by the toolbar route (toggle again) turns it off")
UFO.ToggleTestPanel()
UFO.ToggleTestPanel()
eq(P:IsTestMode(), false, "off")

DandersFrames, CreateFrame, C_Timer = saved.DandersFrames, saved.CreateFrame, saved.C_Timer
UISpecialFrames, UIParent, hooksecurefunc = saved.UISpecialFrames, saved.UIParent, saved.hooksecurefunc
PlaySound, SOUNDKIT = saved.PlaySound, saved.SOUNDKIT
