-- ☠ Companion addon: `...` yields THIS addon's private table, not the parent's.
-- Take the parent's table from the global it publishes (see GUI/Panel.lua).
local DF = DandersFrames
local GUI = DF and DF.GUI
if not GUI then return end
local UFO = GUI.UnitFrameOptions
if not UFO then return end
local L = DF.L

local ipairs, pairs, type = ipairs, pairs, type
local abs = math.abs
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
-- Built from the shared settings widgets (collapsible settings groups, the
-- db-bound checkbox / slider / dropdown factories) rather than the party panel's
-- private ones. Only what the unit frames actually draw has a switch here.
-- ============================================================

local PANEL_WIDTH = 320
local PAD = 12
local CONTENT_WIDTH = PANEL_WIDTH - PAD * 2
local HEADER_TOP = 104   -- title + toggle + description

-- The sections, each a collapsible group. Collapse state is the kit's own store
-- (account-wide, like every collapsible group); the first open shows Frames only.
local SECTION_KEY = "ufTest:"
local SEEDED_KEY = "ufTest:seeded"

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

-- A key of the units test settings, as a widget's get / set pair.
local function Get(key)
    return function()
        local t = TestDB()
        return t and t[key]
    end
end

local function Set(key)
    return function(v)
        local t = TestDB()
        if t then t[key] = v end
    end
end

-- A key of the boss unit's own table (its page's Show Placeholder Frames in Test
-- Mode and Preview Frames): one setting shown in two places, never two settings.
local function BossGet(key)
    return function()
        local uf = UF()
        local db = uf and uf:GetUnitDB("boss")
        return db and db[key]
    end
end

local function BossSet(key)
    return function(v)
        local uf = UF()
        local stored = uf and uf:GetStoredUnit("boss")
        if stored then stored[key] = v end
    end
end

-- ============================================================
-- WIDGETS (the shared factories, unbound from any page: custom get / set, no
-- search entry -- a search result must be able to land on its widget)
-- ============================================================
local function Check(parent, label, key, get, set)
    return GUI:CreateCheckbox(parent, label, nil, nil, Repaint,
        get or Get(key), set or Set(key), nil, { noSearch = true })
end

local function Slider(parent, label, lo, hi, step, key, get, set)
    local s = GUI:CreateSlider(parent, label, lo, hi, step, nil, nil, Repaint,
        nil, nil, get or Get(key), set or Set(key))
    s.fullRow = true
    return s
end

local function Dropdown(parent, label, options, key)
    local d = GUI:CreateDropdown(parent, label, options, nil, nil, Repaint, Get(key), Set(key))
    d.fullRow = true
    return d
end

-- ============================================================
-- THE PANEL
-- ============================================================
function UFO.CreateTestPanel()
    if UFO.testPanel then return UFO.testPanel end
    local C = GUI.Colors
    local C_TEXT_DIM = C.textDim

    local panel = CreateFrame("Frame", "DandersFramesUnitTestPanel", UIParent, "BackdropTemplate")
    panel:SetSize(PANEL_WIDTH, 420)
    panel:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
    panel:SetFrameStrata("FULLSCREEN_DIALOG")
    panel:SetFrameLevel(100)
    panel:SetMovable(true)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    GUI:CreatePanelBackdrop(panel, { bgAlpha = C.background.a, borderColor = { r = 0, g = 0, b = 0, a = 1 } })
    panel:Hide()
    tinsert(UISpecialFrames, "DandersFramesUnitTestPanel")

    -- Closing the panel ends the test mode, as the party panel's does. The test
    -- mode's own listener (below) keeps the toggle and the Test button in step.
    panel:SetScript("OnHide", function()
        if UFO.SetTestMode then UFO.SetTestMode(false) end
        if GUI.UpdateTestButtonState then GUI.UpdateTestButtonState() end
    end)

    -- ---- header ----
    local title = panel:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    title:SetPoint("TOPLEFT", PAD, -10)
    title:SetText(L["Test Mode"])
    local sub = panel:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    sub:SetPoint("LEFT", title, "RIGHT", 8, 0)
    sub:SetText(L["Unit Frames"])
    sub:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    local closeBtn = GUI:CreateCloseButton(panel, { size = 22, onClick = function() panel:Hide() end })
    closeBtn:SetPoint("TOPRIGHT", -8, -6)

    local sep = panel:CreateTexture(nil, "ARTWORK")
    sep:SetPoint("TOPLEFT", 0, -32)
    sep:SetPoint("TOPRIGHT", 0, -32)
    sep:SetHeight(1)
    sep:SetColorTexture(C.border.r, C.border.g, C.border.b, 0.6)

    -- The toggle: the same action as the Test button -- off, and the panel closes.
    local toggle = CreateFrame("Button", nil, panel, "BackdropTemplate")
    toggle:SetPoint("TOPLEFT", PAD, -38)
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

    local desc = panel:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    desc:SetPoint("TOPLEFT", PAD, -74)
    desc:SetPoint("TOPRIGHT", -PAD, -74)
    desc:SetJustifyH("LEFT")
    desc:SetSpacing(2)
    desc:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    desc:SetText(L["Shows sample unit frames. Party and raid test frames stay hidden while this is on."])

    -- ---- sections ----
    local content = CreateFrame("Frame", nil, panel)
    content:SetPoint("TOPLEFT", PAD, -HEADER_TOP)
    content:SetWidth(CONTENT_WIDTH)
    content:SetHeight(10)
    panel.content = content
    panel.groups = {}

    -- First open: every section but Frames starts folded (the kit stores only
    -- "collapsed", so the default is seeded once, account-wide).
    local saved = GUI:GetCollapsedGroups()
    if saved and not saved[SEEDED_KEY] then
        for _, id in ipairs({ "target", "health", "bars", "auras", "icons" }) do
            saved[SECTION_KEY .. id] = true
        end
        saved[SEEDED_KEY] = true
    end

    local function Section(id, label, columns)
        local g = GUI:CreateSettingsGroup(content, CONTENT_WIDTH, {
            collapsible = true, collapseKey = SECTION_KEY .. id, innerColumns = columns,
        })
        g:AddWidget(GUI:CreateHeader(content, label))
        panel.groups[#panel.groups + 1] = g
        return g
    end

    -- Built with search registration held off: none of this is a page.
    local Search = DF.Search
    local hadSuppress = Search and Search.SuppressRegistration
    if Search then Search.SuppressRegistration = true end

    -- FRAMES: which previews show (a mover session shows every one regardless).
    local g = Section("frames", L["Frames"], 2)
    local uf = UF()
    local spawned = {}
    for _, unit in ipairs(uf and uf.SPAWNED_UNITS or {}) do spawned[unit] = true end
    local P = Preview()
    for _, unit in ipairs({ "player", "target", "targettarget", "focus", "focustarget", "pet" }) do
        local key = P and P.SHOW_KEY and P.SHOW_KEY[unit]
        if key and spawned[unit] then g:AddWidget(Check(content, UFO.UnitLabel(unit), key)) end
    end
    local bossCheck, bossCount
    if spawned.boss then
        bossCheck = Check(content, L["Boss"], nil, BossGet("bossPreviewCount"), BossSet("bossPreviewCount"))
        g:AddWidget(bossCheck)
        bossCount = Slider(content, L["Preview Frames"], 1, (uf and uf.BOSS_COUNT) or 5, 1, nil,
            BossGet("bossPreviewNum"), BossSet("bossPreviewNum"))
        bossCount.disableOn = function() return BossGet("bossPreviewCount")() == false end
        g:AddWidget(bossCount)
    end

    -- TARGET: what the sample target is (the focus keeps its own rare sample).
    g = Section("target", L["Target"])
    g:AddWidget(Dropdown(content, L["Classification"], {
        normal = L["Normal"], elite = L["Elite"], rare = L["Rare"], rareelite = L["Rare Elite"],
        worldboss = L["Boss"],
        _order = { "normal", "elite", "rare", "rareelite", "worldboss" },
    }, "classification"))
    g:AddWidget(Dropdown(content, L["Reaction"], {
        hostile = L["Hostile"], neutral = L["Neutral"], friendly = L["Friendly"],
        _order = { "hostile", "neutral", "friendly" },
    }, "reaction"))

    -- HEALTH
    g = Section("health", L["Health"])
    g:AddWidget(Check(content, L["Animate Health"], "testAnimateHealth"))
    g:AddWidget(Check(content, L["Fixed Health"], "fixedHealth"))
    local healthSlider = Slider(content, L["Health"], 1, 100, 1, "healthPercent")
    healthSlider.disableOn = function() local t = TestDB(); return not (t and t.fixedHealth) end
    g:AddWidget(healthSlider)

    -- BARS
    g = Section("bars", L["Bars"], 2)
    g:AddWidget(Check(content, L["Absorbs"], "testShowAbsorbs"))
    g:AddWidget(Check(content, L["Heal Prediction"], "testShowHealPrediction"))
    g:AddWidget(Check(content, L["Cast Bar"], "showCastBars"))
    g:AddWidget(Check(content, L["Class Power"], "showClassPower"))

    -- AURAS
    g = Section("auras", L["Auras"])
    g:AddWidget(Check(content, L["Show Auras"], "testShowAuras"))
    local auraOff = function() local t = TestDB(); return t and t.testShowAuras == false end
    local buffs = Slider(content, L["Buffs"], 0, 5, 1, "testBuffCount")
    buffs.disableOn = auraOff
    g:AddWidget(buffs)
    local debuffs = Slider(content, L["Debuffs"], 0, 5, 1, "testDebuffCount")
    debuffs.disableOn = auraOff
    g:AddWidget(debuffs)

    -- ICONS: the status icons the frames draw (each also needs its own icon
    -- switched on for the unit, on its Icons page).
    g = Section("icons", L["Icons"], 2)
    g:AddWidget(Check(content, L["Status Icons"], "testShowStatusIcons"))
    local iconsOff = function() local t = TestDB(); return t and t.testShowStatusIcons == false end
    for _, row in ipairs({ { L["Raid Target Icon"], "showRaidTarget" }, { L["Leader Icon"], "showLeader" },
                           { L["Combat Icon"], "showCombat" } }) do
        local w = Check(content, row[1], row[2])
        w.disableOn = iconsOff
        g:AddWidget(w)
    end

    if Search then Search.SuppressRegistration = hadSuppress end

    -- ---- layout / state ----
    -- Grey-when-disabled, by the widgets' own disableOn. Done here rather than
    -- through the groups' RefreshChildStates, which asks the PAGE for its table.
    local function RefreshGrey()
        for _, grp in ipairs(panel.groups) do
            for _, entry in ipairs(grp.groupChildren) do
                local w = entry.widget
                if w.disableOn and w.SetEnabled then
                    local off = w.disableOn() and true or false
                    w:SetEnabled(not off)
                    rawset(w, "dfGreyed", off or nil)
                end
            end
        end
    end

    function panel:Relayout()
        local y = 0
        for _, grp in ipairs(self.groups) do
            grp:ClearAllPoints()
            grp:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
            y = y - (grp:LayoutChildren() or 0)
        end
        content:SetHeight(abs(y) + 1)
        self:SetHeight(HEADER_TOP + abs(y) + PAD)
    end

    -- The groups' collapse click and every checkbox call this (no self on the
    -- collapse path).
    content.RefreshStates = function()
        RefreshGrey()
        panel:Relayout()
    end

    -- Values the panel did not write (a profile switch, the boss page, a combat
    -- exit) are re-read on every show.
    function panel:UpdateState()
        local on = UFO.IsTestModeOn()
        local accent = GUI.GetThemeColor and GUI.GetThemeColor() or C.accent
        if toggle.ApplyThemeColor then toggle.ApplyThemeColor(accent) end
        if toggle.SetActive then toggle:SetActive(on) end
        if toggle.Text then
            toggle.Text:SetText(on and L["Disable Test Mode"] or L["Enable Test Mode"])
            local c = on and accent or C.text
            toggle.Text:SetTextColor(c.r, c.g, c.b)
        end
        for _, grp in ipairs(self.groups) do
            if grp.RefreshChildValues then grp:RefreshChildValues() end
        end
        -- The headers and fold arrows take the accent of the module showing now.
        local listeners = rawget(content, "ThemeListeners")
        if type(listeners) == "table" then
            for _, l in ipairs(listeners) do
                if type(l.UpdateTheme) == "function" then l.UpdateTheme() end
            end
        end
        content.RefreshStates()
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
