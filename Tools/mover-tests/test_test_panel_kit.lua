local NS = ...

-- ============================================================
-- TEST PANEL WIDGET KIT -- DandersFrames_Options/TestMode/TestMode.lua
-- ------------------------------------------------------------
-- DF:CreateTestPanelKit is lifted out of TestMode.lua by its section header and
-- run over permissive stub frames. Pins what a panel relies on: a checkbox
-- writes its key into the panel's table (or through setValue), calls its
-- callback with the panel's argument, then the panel's afterToggle, and counts
-- toward its section's badge; a section folds through the panel's own store and
-- asks it to re-lay out; the party / raid panel builds its widgets from it.
-- ============================================================

local saved = { CreateFrame = CreateFrame, PlaySound = PlaySound, SOUNDKIT = SOUNDKIT }

local src = options_file_source("TestMode/TestMode.lua"):gsub("\r\n", "\n")
local a = src:find("-- TEST PANEL WIDGET KIT", 1, true)
local b = src:find("function DF:CreateTestPanel()", 1, true)
check(a and b and a < b, "kit: section found ahead of the party panel")
if not (a and b) then return end

local function noop() end
local FrameMT = { __index = function(_, k)
    if type(k) == "string" and k:match("^%u") then return noop end
end }
local function Frame()
    local f = setmetatable({ shown = true, scripts = {}, points = {} }, FrameMT)
    f.SetScript = function(self, n, fn) self.scripts[n] = fn end
    f.GetScript = function(self, n) return self.scripts[n] end
    f.HookScript = function(self, n, fn) self.scripts["hook:" .. n] = fn end
    f.SetPoint = function(self, ...) self.points[#self.points + 1] = { ... } end
    f.Show = function(self) self.shown = true end
    f.Hide = function(self) self.shown = false end
    f.IsShown = function(self) return self.shown end
    f.SetShown = function(self, v) self.shown = v and true or false end
    f.CreateFontString = function()
        local fs = Frame()
        fs.SetText = function(self, t) self.text = t end
        fs.GetStringWidth = function() return 40 end
        return fs
    end
    f.CreateTexture = function() return Frame() end
    f.GetValue = function() return 0 end
    return f
end
CreateFrame = function() return Frame() end
PlaySound = noop
SOUNDKIT = {}

local DF = { L = setmetatable({}, { __index = function(_, k) return k end }) }
local accent = { r = 0.1, g = 0.2, b = 0.3 }
local col = { r = 1, g = 1, b = 1 }
DF.GUI = {
    Colors = { panel = col, element = col, border = col, hover = col, text = col, textDim = col },
    StyleCheckButton = function() return Frame() end,
    CreateElementBackdrop = noop, ShowTooltip = noop, HideTooltip = noop,
}
local chunk = assert(loadstring("local DF, L = ...\n" .. src:sub(a, b - 1), "@test_panel_kit"))
chunk(DF, DF.L)
check(type(DF.CreateTestPanelKit) == "function", "kit: DF:CreateTestPanelKit defined")

local store, calls, relayouts, saves = {}, {}, 0, {}
local kit = DF:CreateTestPanelKit({
    contentWidth = 296,
    themeColor = function() return accent end,
    getDB = function() return store end,
    callbackArg = function() return "ARG" end,
    afterToggle = function(cb) calls[#calls + 1] = "after:" .. tostring(cb.dbKey) end,
    saveSection = function(k, v) saves[k] = v end,
    relayout = function() relayouts = relayouts + 1 end,
})
check(kit.Checkbox and kit.Slider and kit.Section, "kit: checkbox, slider, section")

local sec = kit.Section(Frame(), "Bars", "bars")
eq(kit.sections[1], sec, "kit: sections are listed in build order")
eq(sec.titleText.text, "BARS", "section: the title in capitals, the party look")
eq(sec.expanded, false, "section: starts folded")
local one = sec:AddCheckbox("Absorbs", "testShowAbsorbs", function(on, arg) calls[#calls + 1] = "cb:" .. tostring(on) .. ":" .. arg end)
local two = sec:AddCheckbox("Heal Prediction", "testShowHealPrediction")
local three = sec:AddCheckbox("Count", "testCount", nil, nil, function(db, on) db.testCount = on and 1 or 0 end)
eq(one.points[1][4], 4, "grid: first column")
eq(two.points[1][4], 4 + (296 - 8) / 2, "grid: second column")
eq(three.points[1][5], -(24 + 4), "grid: third box starts the second row")

one.box.scripts.OnClick(one.box)
eq(store.testShowAbsorbs, true, "checkbox: writes its key into the panel's table")
eq(table.concat(calls, ","), "cb:true:ARG,after:testShowAbsorbs", "checkbox: callback (with the panel's arg), then afterToggle")
eq(sec.badgeText.text, "1", "badge: one box on")
three.box.scripts.OnClick(three.box)
eq(store.testCount, 1, "checkbox: setValue writes instead of the plain key")
eq(sec.badgeText.text, "2", "badge: two on")
one:SetEnabled(false)
one.box.scripts.OnClick(one.box)
eq(store.testShowAbsorbs, true, "a greyed box ignores clicks")
sec:UpdateBadge()
eq(sec.badgeText.text, "1", "badge: a greyed box does not count")

sec.header.scripts.OnClick()
eq(sec.expanded, true, "header click unfolds")
eq(saves.bars, true, "...saved through the panel's store")
eq(relayouts, 1, "...and the panel re-lays out")
eq(sec:GetContentHeight(), 2 * 24 + 8, "content height: two grid rows")
local row = Frame()
sec:AddWidget(row, 22)
eq(sec:GetContentHeight(), 2 * 24 + 8 + 22, "AddWidget: rows below the grid")

local s = kit.Slider(Frame(), 55, 0, 5, 1)
check(s.slider and s.UpdateTheme and s.SetEnabled, "slider: the mini slider")
s:SetEnabled(false)
eq(s.dfDisabled, true, "slider: greys")

-- the party / raid panel builds from it
local body = src:sub(b)
check(body:find("DF:CreateTestPanelKit({", 1, true), "party panel: built from the kit")
check(not body:find("local function CreateThemedCheckbox", 1, true), "party panel: no private checkbox copy left")
check(not body:find("local function CreateSection", 1, true), "party panel: no private section copy left")
check(body:find("DF.db.testPanelSections[key] = expanded", 1, true), "party panel: its sections still fold into testPanelSections")

CreateFrame, PlaySound, SOUNDKIT = saved.CreateFrame, saved.PlaySound, saved.SOUNDKIT
