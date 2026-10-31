-- ☠ Companion addon: `...` yields THIS addon's private table, not the parent's.
-- Take the parent's table from the global it publishes (see GUI/Panel.lua).
local DF = DandersFrames
local GUI = DF and DF.GUI
if not GUI then return end
local UFO = GUI.UnitFrameOptions
if not UFO then return end
local L = DF.L

local ipairs, pairs, type, tostring = ipairs, pairs, type, tostring
local floor, max = math.floor, math.max
local format = string.format
local tinsert = table.insert
-- Looked up per call, not cached: a headless test swaps the global in after the
-- file has loaded.
local function CreateFrame(...) return _G.CreateFrame(...) end

-- ============================================================
-- THE UNITS TEST PANEL
-- The Unit Frames module's own test panel: the units test mode (UF.Preview's
-- "test" owner, Preview.lua) and its options, stored apart from the party / raid
-- test settings (UF:GetTestDB -> DF.db.unitframes.global.testMode). Opened by
-- the window's Test button on any Unit Frames page (def.testMode, Pages.lua) and
-- by /df test units. Like DandersFrames' own test panel: opening it turns the
-- test mode on, closing it turns it off, and its toggle turns it off and closes.
--
-- ★ BUILT LIKE THE PARTY / RAID PANEL, from the same pieces: its header (title,
-- badge, toggle, the same description), its widgets and sections
-- (DF:CreateTestPanelKit, TestMode/TestMode.lua), its slider rows, and the
-- party panel's labels wherever the two share a concept (Animate Health,
-- Absorbs, Heal Prediction, Show Auras, Buffs: / Debuffs:, Icons, Frame Count,
-- and the section names). Only what the unit frames draw has a switch here; the
-- units-only concepts (which previews, the sample target) follow the same style.
-- Like the party panel, a label opens its settings page (the Player's).
-- ============================================================

local PANEL_WIDTH   = 320
local CONTENT_WIDTH = PANEL_WIDTH - 24   -- 12px padding each side
local HEADER_TOP    = 108                -- title + toggle + description + separator

local function UF() return DF.UnitFrames end

local function TestDB()
    local uf = UF()
    return uf and uf.GetTestDB and uf:GetTestDB() or nil
end

local function Preview()
    local uf = UF()
    return uf and uf.Preview or nil
end

-- A switch moved: repaint the previews that are up.
local function Repaint()
    local P = Preview()
    if P and P.Refresh then P:Refresh() end
end

-- A slider moved (maybe mid-drag): one repaint per rendered frame.
local function RepaintSoon()
    local P = Preview()
    if P and P.RequestRefresh then P:RequestRefresh() elseif P and P.Refresh then P:Refresh() end
end

-- A key of the boss unit's own table (its page's Show Placeholder Frames in Test
-- Mode and Preview Frames): one setting shown in two places, never two settings.
local function BossGet(key)
    local uf = UF()
    local db = uf and uf:GetUnitDB("boss")
    return db and db[key]
end

local function BossSet(key, v)
    local uf = UF()
    local stored = uf and uf:GetStoredUnit("boss")
    if stored then stored[key] = v end
end

-- The settings page a label opens: the Player's page of that kind, or a unit's
-- first page. nil (a plain label) when the page does not exist in this build.
local function PageOf(kind, unit)
    local pages = UFO.pagesByUnit and UFO.pagesByUnit[unit or "player"]
    return pages and pages[kind] or nil
end

local function FirstPage(unit)
    return UFO.FirstPageOf and UFO.FirstPageOf(unit) or nil
end

-- ============================================================
-- THE PANEL
-- ============================================================
function UFO.CreateTestPanel()
    if UFO.testPanel then return UFO.testPanel end
    local C = GUI.Colors
    local C_BG, C_TEXT, C_TEXT_DIM = C.background, C.text, C.textDim

    local function GetThemeColor()
        return (GUI.GetThemeColor and GUI.GetThemeColor()) or C.accent
    end

    local panel = CreateFrame("Frame", "DandersFramesUnitTestPanel", UIParent, "BackdropTemplate")
    panel:SetSize(PANEL_WIDTH, 420)
    panel:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
    panel:SetFrameStrata("FULLSCREEN_DIALOG")
    panel:SetFrameLevel(100)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    GUI:CreatePanelBackdrop(panel, { bgAlpha = C_BG.a, borderColor = { r = 0, g = 0, b = 0, a = 1 } })
    panel:Hide()
    tinsert(UISpecialFrames, "DandersFramesUnitTestPanel")

    -- Closing the panel ends the test mode, as the party panel's does. The test
    -- mode's own listener (below) keeps the toggle and the Test button in step.
    panel:SetScript("OnHide", function()
        if UFO.SetTestMode then UFO.SetTestMode(false) end
        if GUI.UpdateTestButtonState then GUI.UpdateTestButtonState() end
    end)

    -- ---- header: the party panel's ----
    local title = panel:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText(L["Test Mode"])
    panel.title = title

    -- The mode badge (the party panel's Party / Raid): which test mode this is.
    local badge = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    badge:SetSize(40, 18)
    badge:SetPoint("LEFT", title, "RIGHT", 8, 0)
    if GUI.CreateElementBackdrop then GUI:CreateElementBackdrop(badge) end
    badge.text = badge:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    badge.text:SetPoint("CENTER", 0, 0)
    badge.text:SetText(L["Unit Frames"])
    panel.badge = badge

    local closeBtn = GUI:CreateCloseButton(panel, { size = 22, onClick = function() panel:Hide() end })
    closeBtn:SetPoint("TOPRIGHT", -8, -6)

    local headerSep = panel:CreateTexture(nil, "ARTWORK")
    headerSep:SetPoint("TOPLEFT", 0, -32)
    headerSep:SetPoint("TOPRIGHT", 0, -32)
    headerSep:SetHeight(1)
    headerSep:SetColorTexture(1, 1, 1, 0.06)

    -- The toggle: the same action as the Test button -- off, and the panel closes.
    local toggle = CreateFrame("Button", nil, panel, "BackdropTemplate")
    toggle:SetPoint("TOPLEFT", 12, -38)
    GUI:StyleButton(toggle, { width = CONTENT_WIDTH, height = 30, font = "DFFontHighlight",
                              text = L["Enable Test Mode"] })
    toggle:SetScript("OnClick", function()
        if UFO.IsTestModeOn() then
            panel:Hide()
        else
            UFO.SetTestMode(true)
            panel:UpdateState()
        end
    end)
    panel.toggle = toggle
    panel.toggleBtn = toggle

    local desc = panel:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    desc:SetPoint("TOPLEFT", 12, -74)
    desc:SetPoint("TOPRIGHT", -12, -74)
    desc:SetJustifyH("LEFT")
    desc:SetSpacing(2)
    desc:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.8)
    desc:SetText(L["Expand sections to toggle features. Click label text to jump to its settings page."])

    -- ---- the shared widgets ----
    -- Checkboxes write the units test settings; a section's fold is kept there too
    -- (panelSections), apart from the party panel's.
    local kit = DF:CreateTestPanelKit({
        contentWidth = CONTENT_WIDTH,
        themeColor = GetThemeColor,
        getDB = TestDB,
        afterToggle = function()
            Repaint()
            if panel.RefreshDependentEnabled then panel.RefreshDependentEnabled() end
        end,
        saveSection = function(key, expanded)
            local t = TestDB()
            if not t then return end
            if type(t.panelSections) ~= "table" then t.panelSections = {} end
            t.panelSections[key] = expanded
        end,
        relayout = function() panel:RecalculateLayout() end,
    })
    local Section, Slider = kit.Section, kit.Slider
    local sections = kit.sections
    panel.checks = {}       -- key -> checkbox, for UpdateState
    panel.rows = {}         -- every slider / dropdown row, for UpdateState and greying

    local function Check(sec, label, key, pageId, setValue)
        local cb = sec:AddCheckbox(label, key, nil, pageId, setValue)
        panel.checks[#panel.checks + 1] = cb
        return cb
    end

    -- A slider row in the party panel's two layouts:
    --   "wide"  label, value, slider (140)  -- the party panel's Frame Count row
    --   pairs   "Buffs:" slider (55) value  -- the party panel's Buffs: / Debuffs: row
    -- spec: { label, min, max, step, get(), set(v), suffix, disabled() }
    local updating = false
    local function SliderPart(row, anchor, spec, width, wide)
        local text = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        text:SetText(spec.label)
        text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        if anchor then text:SetPoint("LEFT", anchor, "RIGHT", 12, 0) else text:SetPoint("LEFT", 0, 0) end
        local value = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        local s = Slider(row, width, spec.min, spec.max, spec.step)
        if wide then
            value:SetPoint("LEFT", text, "RIGHT", 6, 0)
            s:SetPoint("LEFT", value, "RIGHT", 8, 0)
        else
            s:SetPoint("LEFT", text, "RIGHT", 5, 0)
            value:SetPoint("LEFT", s, "RIGHT", 4, 0)
            value:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        end
        local part = { text = text, value = value, slider = s, spec = spec, wide = wide }
        function part.Show(v)
            value:SetText(format("%d%s", v or 0, spec.suffix or ""))
        end
        s:HookScript("OnValueChanged", function(_, v)
            v = floor((v or 0) + 0.5)
            part.Show(v)
            if updating then return end
            spec.set(v)
            RepaintSoon()
        end)
        panel.rows[#panel.rows + 1] = part
        return part, value
    end

    local function WideSliderRow(sec, spec)
        local row = CreateFrame("Frame", nil, sec.content)
        row:SetHeight(28)
        SliderPart(row, nil, spec, 140, true)
        sec:AddWidget(row, 28)
        return row
    end

    local function PairSliderRow(sec, a, b)
        local row = CreateFrame("Frame", nil, sec.content)
        row:SetHeight(18)
        local _, value = SliderPart(row, nil, a, 55, false)
        SliderPart(row, value, b, 55, false)
        sec:AddWidget(row, 22)
        return row
    end

    -- A label and a compact dropdown (the shared inline dropdown), one row.
    local function DropdownRow(sec, label, options, get, set)
        local row = CreateFrame("Frame", nil, sec.content)
        row:SetHeight(24)
        local text = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        text:SetPoint("LEFT", 0, 0)
        text:SetText(label)
        text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        local dd = GUI:CreateDropdown(row, label, options, nil, nil, Repaint, get, set, { inline = true })
        dd:SetSize(150, 20)
        dd:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        panel.rows[#panel.rows + 1] = { dropdown = dd, text = text }
        sec:AddWidget(row, 26)
        return dd
    end

    local function TestKey(key) return function() local t = TestDB(); return t and t[key] end end
    local function SetTestKey(key) return function(v) local t = TestDB(); if t then t[key] = v end end end

    -- Built with search registration held off: none of this is a page.
    local Search = DF.Search
    local hadSuppress = Search and Search.SuppressRegistration
    if Search then Search.SuppressRegistration = true end

    -- --- GENERAL (the party panel's: Animate Health; the units' fixed health) ---
    local secGeneral = Section(panel, L["General"], "general")
    Check(secGeneral, L["Animate Health"], "testAnimateHealth")
    Check(secGeneral, L["Fixed Health"], "fixedHealth")
    WideSliderRow(secGeneral, {
        label = L["Health"], min = 1, max = 100, step = 1, suffix = "%",
        get = TestKey("healthPercent"), set = SetTestKey("healthPercent"),
        disabled = function() local t = TestDB(); return not (t and t.fixedHealth) end,
    })

    -- --- FRAMES (units only: which previews show; a mover session shows them all) ---
    local secFrames = Section(panel, L["Frames"], "frames")
    local uf = UF()
    local spawned = {}
    for _, unit in ipairs(uf and uf.SPAWNED_UNITS or {}) do spawned[unit] = true end
    local P = Preview()
    for _, unit in ipairs({ "player", "target", "targettarget", "focus", "focustarget", "pet" }) do
        local key = P and P.SHOW_KEY and P.SHOW_KEY[unit]
        if key and spawned[unit] then Check(secFrames, UFO.UnitLabel(unit), key, FirstPage(unit)) end
    end
    if spawned.boss then
        local boss = Check(secFrames, L["Boss"], "bossPreviewCount", FirstPage("boss"),
            function(_, on) BossSet("bossPreviewCount", on and true or false) end)
        boss.isBoss = true
        WideSliderRow(secFrames, {
            label = L["Frame Count"], min = 1, max = (uf and uf.BOSS_COUNT) or 5, step = 1,
            get = function() return BossGet("bossPreviewNum") end,
            set = function(v) BossSet("bossPreviewNum", v) end,
            disabled = function() return BossGet("bossPreviewCount") == false end,
        })
    end

    -- --- TARGET (units only: what the sample target is; focus keeps its rare) ---
    local secTarget = Section(panel, L["Target"], "target")
    DropdownRow(secTarget, L["Classification"], {
        normal = L["Normal"], elite = L["Elite"], rare = L["Rare"], rareelite = L["Rare Elite"],
        worldboss = L["Boss"],
        _order = { "normal", "elite", "rare", "rareelite", "worldboss" },
    }, TestKey("classification"), SetTestKey("classification"))
    DropdownRow(secTarget, L["Reaction"], {
        hostile = L["Hostile"], neutral = L["Neutral"], friendly = L["Friendly"],
        _order = { "hostile", "neutral", "friendly" },
    }, TestKey("reaction"), SetTestKey("reaction"))

    -- --- BARS & OVERLAYS ---
    local secBars = Section(panel, L["Bars & Overlays"], "bars")
    Check(secBars, L["Absorbs"], "testShowAbsorbs", PageOf("absorbs"))
    Check(secBars, L["Heal Prediction"], "testShowHealPrediction", PageOf("healpred"))
    Check(secBars, L["Cast Bar"], "showCastBars", PageOf("castbar"))
    Check(secBars, L["Class Power"], "showClassPower", PageOf("classpower"))

    -- --- AURAS ---
    local secAuras = Section(panel, L["Auras"], "auras")
    Check(secAuras, L["Show Auras"], "testShowAuras", PageOf("buffs"))
    local aurasOff = function() local t = TestDB(); return t and t.testShowAuras == false end
    PairSliderRow(secAuras,
        { label = L["Buffs:"], min = 0, max = 5, step = 1, disabled = aurasOff,
          get = TestKey("testBuffCount"), set = SetTestKey("testBuffCount") },
        { label = L["Debuffs:"], min = 0, max = 5, step = 1, disabled = aurasOff,
          get = TestKey("testDebuffCount"), set = SetTestKey("testDebuffCount") })

    -- --- INDICATORS & ICONS (each icon also needs its own switch on the unit's
    -- Icons page) ---
    local secIcons = Section(panel, L["Indicators & Icons"], "indicators")
    Check(secIcons, L["Icons"], "testShowStatusIcons", PageOf("icons"))
    local iconsOff = function() local t = TestDB(); return t and t.testShowStatusIcons == false end
    for _, row in ipairs({ { L["Raid Target Icon"], "showRaidTarget" }, { L["Leader Icon"], "showLeader" },
                           { L["Combat Icon"], "showCombat" } }) do
        local cb = Check(secIcons, row[1], row[2])
        cb.disabledBy = iconsOff
    end

    if Search then Search.SuppressRegistration = hadSuppress end

    -- ---- grey-when-disabled (the party panel's RefreshDependentEnabled) ----
    function panel.RefreshDependentEnabled()
        for _, cb in ipairs(panel.checks) do
            if cb.disabledBy then cb:SetEnabled(not cb.disabledBy()) end
        end
        for _, part in ipairs(panel.rows) do
            if part.slider then
                local off = part.spec.disabled and part.spec.disabled() or false
                part.slider:SetEnabled(not off)
                local c = off and C_TEXT_DIM or C_TEXT
                part.text:SetTextColor(c.r, c.g, c.b)
            end
        end
        for _, sec in ipairs(sections) do sec:UpdateBadge() end
    end

    -- ---- layout (the party panel's, without its presets footer) ----
    function panel:RecalculateLayout()
        local y = -HEADER_TOP
        for _, sec in ipairs(sections) do
            sec:ClearAllPoints()
            sec:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, y)
            sec.content:SetHeight(sec:GetContentHeight())
            sec:SetHeight(sec:GetTotalHeight())
            y = y - sec:GetTotalHeight()
        end
        self:SetHeight(max(-y + 12, 200))
    end

    -- ---- state: every value re-read on each show (a profile switch, the boss
    -- page, a combat exit may have moved one) ----
    function panel:UpdateState()
        local t = TestDB() or {}
        local themeColor = GetThemeColor()
        local on = UFO.IsTestModeOn()

        self.title:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
        self.badge:SetSize(self.badge.text:GetStringWidth() + 14, 18)
        if self.badge.SetBackdropColor then
            self.badge:SetBackdropColor(themeColor.r * 0.15, themeColor.g * 0.15, themeColor.b * 0.15, 1)
            self.badge:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 0.3)
        end
        self.badge.text:SetTextColor(themeColor.r, themeColor.g, themeColor.b)

        if toggle.ApplyThemeColor then toggle.ApplyThemeColor(themeColor) end
        if toggle.SetActive then toggle:SetActive(on) end
        if toggle.Text then
            toggle.Text:SetText(on and L["Disable Test Mode"] or L["Enable Test Mode"])
            local c = on and themeColor or C_TEXT
            toggle.Text:SetTextColor(c.r, c.g, c.b)
        end

        for _, cb in ipairs(self.checks) do
            if cb.isBoss then
                cb:SetChecked(BossGet("bossPreviewCount") ~= false)
            else
                cb:SetChecked(t[cb.dbKey] and true or false)
            end
        end
        updating = true
        for _, part in ipairs(self.rows) do
            if part.slider then
                local v = part.spec.get() or part.spec.min
                part.slider:SetValue(v)
                part.Show(v)
                if part.wide then part.value:SetTextColor(themeColor.r, themeColor.g, themeColor.b) end
                if part.slider.UpdateTheme then part.slider:UpdateTheme() end
            elseif part.dropdown and part.dropdown.UpdateText then
                part.dropdown:UpdateText()
            end
        end
        updating = false
        self.RefreshDependentEnabled()

        local saved = t.panelSections
        for _, sec in ipairs(sections) do
            if type(saved) == "table" and saved[sec.sectionKey] ~= nil then sec:SetExpanded(saved[sec.sectionKey]) end
            sec:UpdateBadge()
        end
        self:RecalculateLayout()
    end

    -- Follow the test mode whoever moves it: the party / raid test mode taking
    -- over closes this panel; combat leaves it open, switched off.
    if P and P.AddListener then
        P:AddListener(function(on, reason)
            if not panel:IsShown() then return end
            if not on and reason == "group" then panel:Hide() else panel:UpdateState() end
        end)
    end

    -- The settings window's scale, as the party panel takes it (read on every open).
    function panel:ApplyScale()
        local ws = DF.GetWindowState and DF:GetWindowState()
        self:SetScale((ws and ws.scale) or 1)
    end

    UFO.testPanel = panel
    return panel
end

function UFO.IsTestPanelShown()
    return UFO.testPanel and UFO.testPanel:IsShown() or false
end

-- Opening turns the test mode on (it exists to show one); closing turns it off.
function UFO.ToggleTestPanel()
    local panel = UFO.CreateTestPanel()
    if panel:IsShown() then
        panel:Hide()
    else
        UFO.SetTestMode(true)
        panel:ApplyScale()
        panel:Show()
        panel:UpdateState()
    end
    if GUI.UpdateTestButtonState then GUI.UpdateTestButtonState() end
end
