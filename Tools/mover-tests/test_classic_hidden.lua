local NS = ...

-- ============================================================
-- CLASSIC SETTINGS LAYOUT, HIDDEN -- the one switch (2026-09-26)
-- ------------------------------------------------------------
-- DF.CLASSIC_SETTINGS_AVAILABLE (DandersFrames/Core/Config.lua) is the single
-- line that hides Classic. With it false:
--   1. DF:IsClassicSettingsLayout() answers false for everyone, and a saved
--      classicSettings = true is left in the SavedVariable untouched;
--   2. the title-bar layout picker (GUI/Panel.lua) is not built, and the
--      profile chip takes its place beside the scale glyph;
--   3. the Settings page's "Use classic settings layout" tick
--      (GUI/Pages/Options.lua, BuildPanelAppearanceGroup) is not built.
-- Flipping it to true restores all three.
--
-- 2 and 3 RUN THE REAL SOURCE: the picker's block and the Panel Appearance
-- builder are cut out of their files and executed against stubs, with the REAL
-- Config.lua DF supplying the switch.
--
-- ☠ ONE LUA RUNTIME FOR EVERY TEST FILE: every global touched is restored.
-- ============================================================

local savedCreateFrame   = CreateFrame
local savedGetLocale     = GetLocale
local savedDandersFrames = DandersFrames
local savedDB            = DandersFramesDB_v2

CreateFrame = function() return FakeUIFrame() end
GetLocale   = function() return "enUS" end

local DF = {}
load_df_file_into("Core/Config.lua", DF)

local L = setmetatable({}, { __index = function(_, k) return k end })

-- ============================================================
-- 1. THE ACCESSOR
-- ============================================================
print("-- classic hidden: the switch forces Modern")
do
    local cfg = df_file_source("Core/Config.lua"):gsub("\r\n", "\n")
    local _, n = cfg:gsub("\nDF%.CLASSIC_SETTINGS_AVAILABLE = false\n", "")
    eq(n, 1, "switch: Config.lua ships exactly one `DF.CLASSIC_SETTINGS_AVAILABLE = false`")
    eq(DF.CLASSIC_SETTINGS_AVAILABLE, false, "switch: off as loaded")
    eq(DF:ClassicSettingsAvailable(), false, "switch: ClassicSettingsAvailable() reads it")

    DandersFramesDB_v2 = { classicSettings = true }
    eq(DF:IsClassicSettingsLayout(), false, "switch off: a saved classicSettings = true still reads as Modern")
    eq(DandersFramesDB_v2.classicSettings, true, "switch off: ...and the saved value is left untouched")

    DF.CLASSIC_SETTINGS_AVAILABLE = true
    eq(DF:IsClassicSettingsLayout(), true, "switch on: the saved classicSettings = true is honoured again")
    DandersFramesDB_v2 = { classicSettings = false }
    eq(DF:IsClassicSettingsLayout(), false, "switch on: classicSettings = false still reads as Modern")
    DF.CLASSIC_SETTINGS_AVAILABLE = false
end

-- ============================================================
-- 2. THE TITLE-BAR PICKER
-- ============================================================
print("-- classic hidden: the title-bar layout picker")
local PANEL = options_file_source("GUI/Panel.lua"):gsub("\r\n", "\n")

local function cut(src, head, tail, tag)
    local a = src:find(head, 1, true)
    local b = a and src:find(tail, a, true)
    check(a ~= nil and b ~= nil, tag .. ": located in the source")
    if not (a and b) then return nil end
    return src:sub(a, b + #tail - 1)
end

local pickerSrc = cut(PANEL, "    local layoutChip\n    if DF:ClassicSettingsAvailable() then\n",
                      "    end -- DF:ClassicSettingsAvailable()\n", "picker block")
local anchorSrc = cut(PANEL, "    if layoutChip then\n        profileChip:SetPoint(",
                      "    end\n", "profile chip anchor")

local function FakeChip()
    local c = { points = {} }
    function c:SetSize() end
    function c:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function c:UpdateText() self.painted = (self.painted or 0) + 1 end
    return c
end

-- Runs the real picker block + the real anchor block; returns what they built.
local function RunPicker()
    local made = 0
    local GUI = {}
    function GUI:CreateDropdown() made = made + 1 return FakeChip() end
    local env = setmetatable({ GUI = GUI, L = L, DF = DF }, { __index = _G })
    local chunk = assert(loadstring(
        "local titleBar, scaleBtn, profileChip = ...\n" .. (pickerSrc or "") .. (anchorSrc or "")
        .. "\nreturn layoutChip", "=picker"))
    setfenv(chunk, env)
    local titleBar, scaleBtn, profileChip = {}, {}, FakeChip()
    local layoutChip = chunk(titleBar, scaleBtn, profileChip)
    local anchoredTo = profileChip.points[1] and profileChip.points[1][2]
    return {
        made = made, chip = layoutChip, GUI = GUI,
        anchoredToScale = (anchoredTo == scaleBtn),
        anchoredToChip  = (layoutChip ~= nil and anchoredTo == layoutChip),
    }
end

if pickerSrc and anchorSrc then
    DF.CLASSIC_SETTINGS_AVAILABLE = false
    local off = RunPicker()
    eq(off.made, 0, "switch off: no layout dropdown is created")
    eq(off.chip, nil, "switch off: ...so there is no layoutChip")
    eq(off.GUI.LayoutButton, nil, "switch off: GUI.LayoutButton is not published")
    eq(off.GUI.PaintLayoutButton, nil, "switch off: nor GUI.PaintLayoutButton (FlipSettingsLayout guards it)")
    check(off.anchoredToScale, "switch off: the profile chip anchors to the scale glyph instead")

    DF.CLASSIC_SETTINGS_AVAILABLE = true
    local on = RunPicker()
    eq(on.made, 1, "switch on: the layout dropdown is built again")
    check(on.chip ~= nil and on.GUI.LayoutButton == on.chip, "switch on: ...and published as GUI.LayoutButton")
    check(type(on.GUI.PaintLayoutButton) == "function", "switch on: ...with its repaint hook")
    check(on.anchoredToChip, "switch on: the profile chip sits beside it as before")
    DF.CLASSIC_SETTINGS_AVAILABLE = false
end

do
    local fa = PANEL:find("function GUI:FlipSettingsLayout", 1, true)
    local flip = fa and PANEL:sub(fa, PANEL:find("\nend\n", fa, true) or #PANEL) or ""
    check(flip:find("if GUI.PaintLayoutButton then GUI.PaintLayoutButton() end", 1, true) ~= nil,
          "picker: FlipSettingsLayout still guards the repaint, so a missing picker is safe")
end

-- ============================================================
-- 3. THE SETTINGS PAGE TICK
-- ============================================================
print("-- classic hidden: the Settings page's classic tick")
local OPTS = options_file_source("GUI/Pages/Options.lua"):gsub("\r\n", "\n")
local builderSrc = cut(OPTS, "        local function BuildPanelAppearanceGroup(tools2)\n",
                       "\n        end\n", "Panel Appearance builder")

local function RunAppearance()
    local labels = {}
    local function W(label) return { label = label } end
    local GUI = {}
    function GUI:CreateFontDropdown(_, label) return W(label) end
    function GUI:CreateOutlineDropdown(_, label) return W(label) end
    function GUI:CreateLabel(_, label) return W(label) end
    function GUI:CreateCheckbox(_, label) return W(label) end
    local group = {}
    function group:AddWidget(w) labels[#labels + 1] = w.label return w end
    local env = setmetatable({ GUI = GUI, L = L, DF = DF }, { __index = _G })
    local chunk = assert(loadstring((builderSrc or "") .. "\nreturn BuildPanelAppearanceGroup", "=appearance"))
    setfenv(chunk, env)
    DF.db = DF.db or {}
    chunk()({ group = group, parent = {}, refreshStates = function() end })
    local has = false
    for _, l in ipairs(labels) do if l == "Use classic settings layout" then has = true end end
    return has, #labels
end

if builderSrc then
    DF.CLASSIC_SETTINGS_AVAILABLE = false
    local has, n = RunAppearance()
    check(not has, "switch off: the classic tick is not built")
    eq(n, 3, "switch off: ...the card keeps its font dropdown, outline dropdown and note")

    DF.CLASSIC_SETTINGS_AVAILABLE = true
    has, n = RunAppearance()
    check(has, "switch on: the classic tick is built again")
    eq(n, 4, "switch on: ...as the card's fourth widget")
    DF.CLASSIC_SETTINGS_AVAILABLE = false
end

CreateFrame        = savedCreateFrame
GetLocale          = savedGetLocale
DandersFrames      = savedDandersFrames
DandersFramesDB_v2 = savedDB
