-- ☠ Companion addon: `...` yields THIS addon's private table, not the parent's.
-- Take the parent's table from the global it publishes (see GUI/Panel.lua).
local DF = DandersFrames
local GUI = DF and DF.GUI
if not GUI then return end
local UFO = GUI.UnitFrameOptions
if not UFO then return end
local L = DF.L

local ipairs, pairs, type, tostring = ipairs, pairs, type, tostring

-- ============================================================
-- THE UNITS TEST MODE -- a mode of the shared test popup
-- The Unit Frames module's test mode (UF.Preview's "test" owner, Preview.lua)
-- registered with the test popup (DF:RegisterTestMode, TestMode/Modes.lua)
-- next to Party and Raid. Its settings stay apart from the party / raid test
-- settings (UF:GetTestDB -> DF.db.unitframes.global.testMode).
--
-- ★ REGISTERED HERE, IN THE OPTIONS COMPANION. The popup only exists once
-- this addon is loaded, and the rows need what only the options side has (the
-- unit pages a label opens, the unit names). The registry is resident, so the
-- runtime companion could register too, but it would have nothing to link to.
--
-- Following the settings window: Units is current while the window shows a
-- Unit Frames page (isCurrent), so the Test button opens the popup on Units
-- there and on Party / Raid everywhere else. Picking Units in the popup moves
-- the window onto Unit Frames, as picking Raid moves it onto Raid.
-- Entering turns the units preview on (which releases a party / raid one,
-- Preview.lua); leaving or closing turns it off. Combat entry ends it and
-- leaves the popup open, switched off.
-- ============================================================

local MODE_ID = "units"
UFO.TEST_MODE_ID = MODE_ID

local ICONS = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"

local function UF() return DF.UnitFrames end

local function Preview()
    local uf = UF()
    return uf and uf.Preview or nil
end

local function TestDB()
    local uf = UF()
    return uf and uf.GetTestDB and uf:GetTestDB() or nil
end

-- A switch or dropdown moved: repaint the previews that are up.
local function Repaint()
    local P = Preview()
    if P and P.Refresh then P:Refresh() end
end

-- A slider moved (maybe mid-drag): one repaint per rendered frame.
local function RepaintSoon()
    local P = Preview()
    if P and P.RequestRefresh then P:RequestRefresh() elseif P and P.Refresh then P:Refresh() end
end

-- A key of the boss unit's own table (its page's Show Placeholder Frames in
-- Test Mode and Preview Frames): one setting shown in two places.
local function BossGet(key)
    local uf = UF()
    local db = uf and uf.GetUnitDB and uf:GetUnitDB("boss")
    return db and db[key]
end

local function BossSet(key, v)
    local uf = UF()
    local stored = uf and uf.GetStoredUnit and uf:GetStoredUnit("boss")
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

local function Linked(spec, pageId)
    if pageId and DF.TestModeSettingsLink then
        spec.link, spec.linkHint = DF:TestModeSettingsLink(pageId)
    end
    return spec
end

local function Switch(rows, label, key, pageId, extra)
    local spec = Linked({ label = label, key = key, default = true, onChanged = Repaint }, pageId)
    if extra then for k, v in pairs(extra) do spec[k] = v end end
    return rows:AddSwitch(spec)
end

local function TestOff(key)
    return function()
        local t = TestDB()
        return t ~= nil and t[key] == false
    end
end

-- ============================================================
-- SECTIONS -- the old units panel's, one for one, on the same keys
-- ============================================================

local function BuildGeneral(rows)
    rows:AddSwitch({ label = L["Animate Health"], key = "testAnimateHealth", default = false, onChanged = Repaint })
    rows:AddSwitch({ label = L["Fixed Health"], key = "fixedHealth", default = false, onChanged = Repaint })
    rows:AddSlider({
        label = L["Health"], key = "healthPercent", min = 1, max = 100, step = 1, default = 75,
        format = function(v) return tostring(v) .. "%" end,
        disabled = function() local t = TestDB(); return not (t and t.fixedHealth) end,
        onChanged = RepaintSoon,
    })
end

local function BuildFrames(rows)
    local uf = UF()
    local P = Preview()
    local spawned = {}
    for _, unit in ipairs(uf and uf.SPAWNED_UNITS or {}) do spawned[unit] = true end
    for _, unit in ipairs({ "player", "target", "targettarget", "focus", "focustarget", "pet" }) do
        local key = P and P.SHOW_KEY and P.SHOW_KEY[unit]
        if key and spawned[unit] then Switch(rows, UFO.UnitLabel(unit), key, FirstPage(unit)) end
    end
    if spawned.boss then
        -- The boss page's own settings, never units test keys (the key is only
        -- the row's name: get / set win over the store).
        Switch(rows, L["Boss"], "bossPreviewCount", FirstPage("boss"), {
            get = function() return BossGet("bossPreviewCount") ~= false end,
            set = function(v) BossSet("bossPreviewCount", v and true or false) end,
        })
        rows:AddSlider({
            label = L["Frame Count"], key = "bossPreviewNum", min = 1, max = (uf and uf.BOSS_COUNT) or 5, step = 1,
            get = function() return BossGet("bossPreviewNum") end,
            set = function(v) BossSet("bossPreviewNum", v) end,
            disabled = function() return BossGet("bossPreviewCount") == false end,
            onChanged = RepaintSoon,
        })
    end
end

local function BuildTarget(rows)
    rows:AddDropdown({
        label = L["Classification"], key = "classification", default = "elite", onChanged = Repaint,
        options = function()
            return {
                normal = L["Normal"], elite = L["Elite"], rare = L["Rare"], rareelite = L["Rare Elite"],
                worldboss = L["Boss"],
                _order = { "normal", "elite", "rare", "rareelite", "worldboss" },
            }
        end,
    })
    rows:AddDropdown({
        label = L["Reaction"], key = "reaction", default = "hostile", onChanged = Repaint,
        options = function()
            return {
                hostile = L["Hostile"], neutral = L["Neutral"], friendly = L["Friendly"],
                _order = { "hostile", "neutral", "friendly" },
            }
        end,
    })
end

local function BuildBars(rows)
    Switch(rows, L["Absorbs"], "testShowAbsorbs", PageOf("absorbs"))
    Switch(rows, L["Heal Prediction"], "testShowHealPrediction", PageOf("healpred"))
    Switch(rows, L["Cast Bar"], "showCastBars", PageOf("castbar"))
    Switch(rows, L["Class Power"], "showClassPower", PageOf("classpower"))
end

local function BuildAuras(rows)
    Switch(rows, L["Show Auras"], "testShowAuras", PageOf("buffs"))
    local aurasOff = TestOff("testShowAuras")
    rows:AddSlider({
        label = L["Buffs"], key = "testBuffCount", min = 0, max = 5, step = 1, default = 2,
        disabled = aurasOff, onChanged = RepaintSoon,
    })
    rows:AddSlider({
        label = L["Debuffs"], key = "testDebuffCount", min = 0, max = 5, step = 1, default = 2,
        disabled = aurasOff, onChanged = RepaintSoon,
    })
end

-- Each icon also needs its own switch on the unit's Icons page.
local function BuildIcons(rows)
    Switch(rows, L["Icons"], "testShowStatusIcons", PageOf("icons"))
    local iconsOff = TestOff("testShowStatusIcons")
    Switch(rows, L["Raid Target Icon"], "showRaidTarget", nil, { disabled = iconsOff })
    Switch(rows, L["Leader Icon"], "showLeader", nil, { disabled = iconsOff })
    Switch(rows, L["Combat Icon"], "showCombat", nil, { disabled = iconsOff })
end

local SECTIONS = {
    { id = "general", label = function() return L["General"] end,
      icon = ICONS .. "tune.png", build = BuildGeneral },
    { id = "frames", label = function() return L["Frames"] end,
      icon = ICONS .. "dashboard.png", build = BuildFrames },
    { id = "target", label = function() return L["Target"] end,
      icon = ICONS .. "skull.png", build = BuildTarget },
    { id = "bars", label = function() return L["Bars"] end,
      title = function() return L["Bars & Overlays"] end,
      icon = ICONS .. "favorite.png", build = BuildBars },
    { id = "auras", label = function() return L["Auras"] end,
      icon = ICONS .. "auto_awesome.png", build = BuildAuras },
    { id = "icons", label = function() return L["Icons"] end,
      title = function() return L["Indicators & Icons"] end,
      icon = ICONS .. "widget_small.png", build = BuildIcons },
}

-- ============================================================
-- THE MODE
-- ============================================================

local function OnUnitFramesPage()
    local id = GUI.CurrentModuleId and GUI.CurrentModuleId()
    return id == UFO.MODULE
end

-- Put the settings window on Unit Frames (built hidden first if it never
-- opened -- the same as Party / Raid do), so isCurrent agrees with the pick.
local function ShowUnitFramesModule()
    if OnUnitFramesPage() then return end
    if not (GUI.GetModule and GUI:GetModule(UFO.MODULE)) then
        if not DF.GUIFrame and DF.CreateGUI then DF:CreateGUI() end
    end
    if GUI.GetModule and GUI:GetModule(UFO.MODULE) and GUI.SelectModule then
        GUI:SelectModule(UFO.MODULE)
    end
end

local function IsAvailable()
    local uf = UF()
    if not (uf and uf.Preview) then
        if UFO.IsEnabled and UFO.IsEnabled() then
            return false, L["Reload to finish turning on Unit Frames."]
        end
        return false, L["Unit Frames is not loaded."]
    end
    return true
end
UFO.IsTestModeAvailable = IsAvailable

function UFO.RegisterTestMode()
    return DF:RegisterTestMode(MODE_ID, {
        label = function() return L["Units"] end,
        title = function() return L["Unit Frames"] end,
        icon = ICONS .. "person.png",
        order = 30,
        accent = function() return GUI.UnitsAccent end,
        isAvailable = IsAvailable,
        isCurrent = OnUnitFramesPage,
        onEnter = function()
            ShowUnitFramesModule()
            if IsAvailable() and UFO.SetTestMode then UFO.SetTestMode(true) end
        end,
        onExit = function()
            if UFO.SetTestMode then UFO.SetTestMode(false) end
        end,
        store = TestDB,
        isPreviewOn = function() return UFO.IsTestModeOn and UFO.IsTestModeOn() or false end,
        togglePreview = function() if UFO.ToggleTestMode then UFO.ToggleTestMode() end end,
        sections = SECTIONS,
    })
end

-- /df test units: open the popup on Units, or close it if Units is showing.
function UFO.ToggleTestPopup()
    local panel = DF.TestPanel
    if panel and panel:IsShown() and panel.state and panel.state.modeId == MODE_ID then
        panel:Hide()
        return
    end
    ShowUnitFramesModule()
    panel = DF.TestPanel
    if panel and panel:IsShown() then
        panel:UpdateState()
    elseif DF.ToggleTestPanel then
        DF:ToggleTestPanel()
    end
end

-- The units preview moved by anyone (combat, a party claim, the toolbar's
-- right click): the popup's header follows.
local function HookPreview()
    local P = Preview()
    if not (P and P.AddListener) or UFO._testModeListening then return end
    UFO._testModeListening = true
    P:AddListener(function()
        local panel = DF.TestPanel
        if not (panel and panel:IsShown()) then return end
        if panel.state and panel.state.switching then return end
        panel:UpdateStateNoCallback()
    end)
end

-- Only for an installed Unit Frames addon: no greyed button for an addon the
-- user does not have.
if not UFO.IsInstalled or UFO.IsInstalled() then
    UFO.RegisterTestMode()
    HookPreview()
end
