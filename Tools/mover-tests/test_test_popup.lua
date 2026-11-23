local NS = ...

-- ============================================================
-- TEST MODE POPUP -- DandersFrames_Options/TestMode/TestMode.lua
-- ------------------------------------------------------------
-- The popup's section of TestMode.lua (from its header to the end of the
-- file, which is where Party and Raid register) is lifted and RUN over
-- recording fake frames, with the REAL registry (TestMode/Modes.lua), the
-- REAL icon rail (DandersUI/IconRail.lua) and the REAL row list
-- (DandersUI/RowList.lua) underneath it. What is pinned is behaviour: the
-- rail's modes and sections, following the settings window's Party / Raid,
-- mode switching and its enter / exit, per-mode section filtering and
-- memory, row writes into the same profile keys as before, presets, the
-- preview toggle, the open / close claims, and a third registered mode.
--
-- ⚠ Fakes, not WoW: a green run says the wiring holds, not that it renders.
-- ☠ Every global it replaces is restored at the end.
-- ============================================================

local saved = {
    CreateFrame = CreateFrame, PlaySound = PlaySound, SOUNDKIT = SOUNDKIT, UIParent = UIParent,
    UISpecialFrames = UISpecialFrames, tinsert = tinsert, C_Timer = C_Timer,
    geterrorhandler = geterrorhandler, DandersFrames = DandersFrames,
}

-- ---- fake frames ---------------------------------------------------------
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
CreateFrame = function(kind) return Frame(kind) end
PlaySound = noop
SOUNDKIT = {}
UIParent = Frame("Frame")
UISpecialFrames = {}
tinsert = table.insert
C_Timer = { After = noop }     -- the next-frame settles are not run
local reported = {}
geterrorhandler = function() return function(e) reported[#reported + 1] = tostring(e) end end

-- ---- the host (DF.GUI): real rail + row list over stub chrome --------------
local PURPLE, ORANGE = { r = 0.6, g = 0.3, b = 0.9 }, { r = 1, g = 0.5, b = 0.1 }
local col = { r = 0.5, g = 0.5, b = 0.5, a = 0.95 }
local GUI = {
    MEDIA = "Media\\",
    Colors = { background = col, panel = col, element = col, border = col, hover = col,
               notice = col, text = { r = 0.9, g = 0.9, b = 0.9 }, textDim = { r = 0.6, g = 0.6, b = 0.6 } },
    Scroll = { bar = 10, pad = 4 },
    StyleScrollBar = noop, PinScrollBar = noop,
    SelectedMode = "party",
}
function GUI:GetAccent() return self.SelectedMode == "raid" and ORANGE or PURPLE end
function GUI.GetThemeColorFor(isRaid) return isRaid and ORANGE or PURPLE end
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
    function b:SetGlyph(tex, c) self.glyph = tex end
    return b
end
function GUI:StyleButton(btn, opts)
    btn.Text = btn:CreateFontString()
    btn.Text:SetText(opts.text)
    function btn:SetActive(v) self.active = v end
    return btn
end
function GUI:CreateDropdownNative()
    local c = Frame("Frame")
    c.RebuildOptions, c.UpdateText, c.SetEnabled = noop, noop, noop
    return c
end
local selectCalls = {}
function GUI:SelectModule(id, tab)
    selectCalls[#selectCalls + 1] = id .. ":" .. tostring(tab)
    GUI.SelectedMode = tab
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
load_ui_file_into("IconRail.lua", uiNS)
load_ui_file_into("RowList.lua", uiNS)

-- ---- DF ------------------------------------------------------------------
local DF = { L = setmetatable({}, { __index = function(_, k) return k end }) }
DandersFrames = DF
load_df_file_into("TestMode/Modes.lua", DF)
DF.GUI = GUI
DF.GUIFrame = Frame("Frame")
local dbP = { testShowAuras = false, testDefensiveCount = 2, testFrameCount = 4 }
local dbR = { testShowAuras = true, raidTestFrameCount = 25 }
DF.db = {}
function DF:GetDB() return dbP end
function DF:GetRaidDB() return dbR end
local ws = {}
function DF:GetWindowState() return ws end
local owners = { party = {}, raid = {} }
local claims = {}
function DF:SetTestModeOwner(scope, owner, wanted)
    owners[scope][owner] = wanted and true or nil
    claims[#claims + 1] = scope .. ":" .. tostring(wanted and true or false)
end
function DF:IsTestModeOwnedBy(scope, owner) return owners[scope][owner] and true or false end
function DF:ToggleTestMode()
    local s = GUI.SelectedMode == "raid" and "raid" or "party"
    DF:SetTestModeOwner(s, "user", not DF:IsTestModeOwnedBy(s, "user"))
end
local applied, activePreset = {}, nil
function DF:ApplyTestPreset(id) applied[#applied + 1] = id; activePreset = id end
function DF:GetActiveTestPreset() return activePreset end
DF.UpdateTextDesigner = noop
DF.OnSliderDragStart, DF.OnSliderDragStop = noop, noop
DF.testMode, DF.raidTestMode = false, false

-- ---- lift and run --------------------------------------------------------
local src = options_file_source("TestMode/TestMode.lua"):gsub("\r\n", "\n")
local t0 = src:find("local TEST_TOGGLE_DEFAULT_ON = {", 1, true)
local t1 = t0 and src:find("\n}\n", t0, true)
local p0 = src:find("-- TEST MODE POPUP", 1, true)
check(t0 and t1 and p0, "lift: the default-on table and the popup section are found")
if not (t0 and t1 and p0) then return end
-- back up to the "-- ===" line above the header
p0 = src:sub(1, p0):match(".*()\n%-%- =") or p0
local chunk = assert(loadstring("local DF, L = ...\n" .. src:sub(t0, t1 + 2) .. src:sub(p0),
                                "@test_popup"))
chunk(DF, DF.L)

print("-- Popup: party and raid register through the registry")
check(DF:GetTestMode("party") and DF:GetTestMode("raid"), "registry: party and raid registered")
eq(DF:GetTestMode("party").order, 10, "registry: party first")
eq(DF:GetTestMode("raid").order, 20, "registry: raid second")
eq(type(DF.TestModeSettingsLink), "function", "api: DF:TestModeSettingsLink for row links")

local panel = DF:CreateTestPanel()
eq(DF.TestPanel, panel, "panel: DF.TestPanel")
check(not panel:IsShown(), "panel: built hidden")

print("-- Popup: open")
DF:ToggleTestPanel()
check(panel:IsShown(), "open: shown")
eq(panel.state.modeId, "party", "open: follows the settings window's mode")
eq(owners.party.user, true, "open: claims the party preview for the user")
local function railIds()
    return table.concat(panel.rail:GetItemIds(), ",")
end
eq(railIds(), "mode:party,mode:raid,sec:general,sec:bars,sec:auras,sec:icons,sec:highlights",
   "rail: modes, then the mode's sections")
check(panel.rail:IsFilled("mode:party") and not panel.rail:IsFilled("mode:raid"), "rail: the active mode is filled")
eq(panel.rail:GetSelected(), "sec:general", "rail: first section marked on a first open")
eq(panel.title.text, "General", "header: the section's title")
eq(panel.h, panel.rail:GetContentHeight() + 2, "height: the rail's own")
check(buttonUpdates > 0, "open: the toolbar Test button is told")

-- every key a section offers, by mode
local function keysFor(mode)
    local keys = {}
    for _, sec in ipairs(DF:GetTestModeSections(mode)) do
        panel:OnRailPick("sec:" .. sec.id)
        for _, row in ipairs(panel.list:GetRows()) do
            if row.spec and row.spec.key then keys[row.spec.key] = (keys[row.spec.key] or 0) + 1 end
        end
    end
    return keys
end

print("-- Popup: every old test setting still has a control")
local partyKeys = keysFor("party")
for _, k in ipairs({ "testShowPets", "testAnimateHealth", "testShowLabels", "testFrameCount",
                     "testShowAbsorbs", "testShowHealPrediction", "testShowOutOfRange",
                     "testShowReducedMaxHealth", "testShowTextDesigner",
                     "testShowAuras", "testBuffCount", "testDebuffCount", "testShowDispelGlow",
                     "testShowMissingBuff", "testShowAuraDesigner",
                     "testDefensiveCount", "testShowTargetedList", "testAnimateTargetedList",
                     "testShowPersonalTargeted", "testShowStatusIcons",
                     "testShowSelection", "testShowAggro" }) do
    check(partyKeys[k], "party: a control for " .. k)
end
eq(partyKeys.testDefensiveCount, 2, "party: Defensives switch + count")

print("-- Popup: section memory and mode switching")
panel:OnRailPick("sec:auras")
eq(ws.testPopup.sections.party, "auras", "memory: the section is remembered for the mode")
panel:OnRailPick("mode:raid")
eq(selectCalls[#selectCalls], "group:raid", "switch: Raid goes through the settings window's own switch")
eq(panel.state.modeId, "raid", "switch: now raid")
check(panel.rail:IsFilled("mode:raid") and not panel.rail:IsFilled("mode:party"), "switch: the fill moves")
eq(owners.party.user, true, "switch: party <-> raid claims nothing new (the switch carries the preview)")
local raidKeys = keysFor("raid")
check(raidKeys.raidTestFrameCount and not raidKeys.testFrameCount, "raid: its own frame count key")
check(not raidKeys.testShowTargetedList and not raidKeys.testAnimateTargetedList,
      "raid: the party-only Targeted List rows are not offered")
check(raidKeys.testShowPersonalTargeted, "raid: Personal Targeted stays (no raid gate)")
panel:OnRailPick("sec:general")
local fc = panel.list:GetRow("raidTestFrameCount")
eq(fc.Control:GetValue(), 25, "raid: frame count reads the raid profile")
fc.Control.Slider:SetValue(30)
eq(dbR.raidTestFrameCount, 30, "raid: ...and writes it")
eq(fc.Control.Slider.hi, 40, "raid: frame count goes to 40")
panel:OnRailPick("sec:icons")
panel:OnRailPick("mode:party")
eq(panel.state.sectionId, "auras", "memory: back on party, its own last section")
eq(GUI.SelectedMode, "party", "switch: the settings window followed back")

print("-- Popup: rows write the same keys")
panel:OnRailPick("sec:auras")
local buffs = panel.list:GetRow("testBuffCount")
check(buffs.off, "auras: Buffs greyed while Show Auras is off")
local showAuras = panel.list:GetRow("testShowAuras")
showAuras.Control.scripts.OnClick(showAuras.Control)
eq(dbP.testShowAuras, true, "auras: Show Auras writes testShowAuras")
check(not buffs.off, "auras: ...and the counts come alive")
eq(buffs.Control:GetValue(), 3, "auras: an unset buff count shows 3, as before")

panel:OnRailPick("sec:icons")
local defSwitch, defCount
for _, row in ipairs(panel.list:GetRows()) do
    if row.spec and row.spec.key == "testDefensiveCount" then
        if row.kind == "switch" then defSwitch = row else defCount = row end
    end
end
check(defSwitch and defCount, "icons: the Defensives pair")
check(not defSwitch.spec.disabled and not defCount.spec.disabled, "icons: the Defensives pair is never gated")
eq(defSwitch.Control:GetChecked(), true, "defensives: on while the count is above 0")
defSwitch.Control.scripts.OnClick(defSwitch.Control)
eq(dbP.testDefensiveCount, 0, "defensives: off writes 0")
eq(defCount.Control:GetValue(), 0, "defensives: ...and the count row follows")
defSwitch.Control.scripts.OnClick(defSwitch.Control)
eq(dbP.testDefensiveCount, 2, "defensives: on restores the remembered count")
defCount.Control.Slider:SetValue(0)
eq(defSwitch.Control:GetChecked(), false, "defensives: dragging the count to 0 turns the switch off")
check(defSwitch.spec.link ~= nil, "defensives: the label still opens its page")
defSwitch.spec.link()
eq(pagesOpened[#pagesOpened], "auras_defensiveicon", "link: opens the Defensive Icon page")

panel:OnRailPick("sec:general")
local pets = panel.list:GetRow("testShowPets")
eq(pets.Control:GetChecked(), true, "default-on: an unset Show Pets shows on")
pets.Control.scripts.OnClick(pets.Control)
eq(dbP.testShowPets, false, "general: Show Pets writes testShowPets")

print("-- Popup: presets")
eq(#panel.chips, 5, "presets: five chips")
eq(panel.chips[1].Text.text, "Default", "presets: Default first")
panel.chips[2].scripts.OnClick(panel.chips[2])
eq(applied[#applied], "AURAS", "presets: a chip applies its preset")
check(panel.chips[2].active and not panel.chips[1].active, "presets: the matching chip is lit")
activePreset = nil
pets.Control.scripts.OnClick(pets.Control)
check(not panel.chips[2].active, "presets: a toggle re-derives the lit chip")

print("-- Popup: following the settings window")
GUI.SelectedMode = "raid"
panel:UpdateStateNoCallback()
eq(panel.state.modeId, "raid", "follow: the window went to Raid, the popup follows")
GUI.SelectedMode = "party"
panel:UpdateStateNoCallback()
eq(panel.state.modeId, "party", "follow: ...and back")

print("-- Popup: the preview toggle and close")
check(panel.previewBtn.glyph and panel.previewBtn.glyph:find("preview.png", 1, true), "preview: on shows the preview glyph")
panel.previewBtn.opts.onClick()
check(not panel:IsShown(), "preview: turning it off closes the popup")
check(not owners.party.user and not owners.raid.user, "close: both user claims released")

print("-- Popup: a third mode from outside")
local framesDB, entered, exited = { fShow = true }, {}, {}
DF:RegisterTestMode("frames", {
    label = "Frames", icon = "f.png", order = 30,
    store = function() return framesDB end,
    onEnter = function(from) entered[#entered + 1] = tostring(from) end,
    onExit = function(to) exited[#exited + 1] = tostring(to) end,
    sections = {
        { id = "one", label = "One", icon = "1.png", build = function(rows, mode)
            rows:AddHeading("Bits")
            rows:AddSwitch({ label = "Show", key = "fShow" })
            rows:AddSlider({ label = "Size", key = "fSize", min = 1, max = 9, default = 4 })
        end },
        { id = "two", label = "Two", icon = "2.png", isAvailable = function() return false end,
          build = function() end },
        { id = "bad", label = "Bad", icon = "3.png", build = function() error("third-party bug") end },
    },
})
DF:RegisterTestMode("locked", { label = "Locked", icon = "l.png", order = 40,
    isAvailable = function() return false, "Not now" end,
    sections = { { id = "x", label = "X", build = function() end } } })
DF:ToggleTestPanel()
eq(railIds():sub(1, 48), "mode:party,mode:raid,mode:frames,mode:locked,sec", "third: its rail button after Party / Raid")
check(panel.rail:IsDisabled("mode:locked"), "third: an unavailable mode is greyed")
panel:OnRailPick("mode:locked")
eq(panel.state.modeId, "party", "third: ...and cannot be picked")
local before = #claims
panel:OnRailPick("mode:frames")
eq(panel.state.modeId, "frames", "third: picked")
eq(exited[1], nil, "third: (nothing exited it yet)")
eq(entered[#entered], "party", "third: onEnter(from)")
check(not owners.party.user, "third: leaving Party for it drops the group preview")
eq(GUI.SelectedMode, "party", "third: the settings window is left alone")
eq(railIds(), "mode:party,mode:raid,mode:frames,mode:locked,sec:one,sec:bad",
   "third: only its available sections")
local show = panel.list:GetRow("fShow")
check(show ~= nil, "third: its rows")
show.Control.scripts.OnClick(show.Control)
eq(framesDB.fShow, false, "third: rows write into its own store")
eq(panel.list:GetRow("fSize").Control:GetValue(), 4, "third: defaults")
eq(#panel.chips > 0 and panel.chips[1]:IsShown(), false, "third: no presets, no chips")
check(not panel.previewBtn:IsShown(), "third: no preview toggle without isPreviewOn")
GUI.SelectedMode = "raid"
panel:UpdateStateNoCallback()
eq(panel.state.modeId, "frames", "third: a mode without isCurrent is not pulled away")
GUI.SelectedMode = "party"
local nRep = #reported
panel:OnRailPick("sec:bad")
check(#reported > nRep and reported[#reported]:find("third-party bug", 1, true), "third: a throwing build is reported")
eq(panel.state.sectionId, "bad", "third: ...and the popup carries on")
panel:OnRailPick("mode:party")
eq(exited[#exited], "party", "third: leaving it runs onExit(to)")
eq(owners.party.user, true, "third: back on Party the preview is claimed again")
panel:Hide()
DF:ToggleTestPanel()
eq(panel.state.modeId, "party", "reopen: the last mode")
panel:OnRailPick("mode:frames")
panel:Hide()
eq(exited[#exited], "nil", "close: the current mode's onExit(nil)")
DF:ToggleTestPanel()
eq(panel.state.modeId, "frames", "reopen: a mode without isCurrent reopens where it was left")
eq(entered[#entered], "nil", "reopen: ...entered with onEnter(nil)")
panel:Hide()

print("-- Popup: old panel gone, legacy kit kept")
do
    local body = src:sub(p0)
    check(not body:find("DF:CreateTestPanelKit(", 1, true), "popup: no longer built from the legacy kit")
    check(not body:find("testPanelSections", 1, true), "popup: no fold state")
    check(src:find("function DF:CreateTestPanelKit(opts)", 1, true) ~= nil, "legacy: the kit is still defined")
    check(body:find("DF:RegisterTestMode(scope, {", 1, true) ~= nil, "popup: party / raid register like any mode")
end

CreateFrame, PlaySound, SOUNDKIT, UIParent = saved.CreateFrame, saved.PlaySound, saved.SOUNDKIT, saved.UIParent
UISpecialFrames, tinsert, C_Timer = saved.UISpecialFrames, saved.tinsert, saved.C_Timer
geterrorhandler, DandersFrames = saved.geterrorhandler, saved.DandersFrames
