local NS = ...

-- ============================================================
-- UNIT FRAMES: DECK-2 TABS VS THE UNDO / TEST / UNLOCK CLUSTER
-- Six unit tabs at 70 px (452 px of row) overlapped the right-hand cluster
-- (~229 px) at both the 580 minimum and the 700 default. The module now narrows
-- its tabs (def.tabWidth) and, while its view shows, the window minimum is the
-- measured tab row + gap + cluster (GUI:ModuleDeckMinWidth), floored at the
-- module's minWindowWidth.
-- ============================================================

local function norm(s) return (s:gsub("\r\n", "\n")) end
local RAIL = norm(options_file_source("GUI/Rail.lua"))
local PAGES = norm(options_file_source("UnitFrames/Pages.lua"))
local PANEL = norm(options_file_source("GUI/Panel.lua"))

-- ---- lift BuildDeckTabs + the width helpers out of Rail.lua ----
local a = RAIL:find("local function BuildDeckTabs%(def%)")
local b = RAIL:find("\n%-%- =+\n%-%- BUILD\n", a or 1)
check(a ~= nil and b ~= nil, "lift: BuildDeckTabs .. the BUILD header")
if not (a and b) then return end

local function button(w)
    local btn = { w = w, shown = true }
    function btn:GetWidth() return self.w end
    function btn:SetWidth(v) self.w = v end
    function btn:IsShown() return self.shown end
    function btn:SetPoint() end
    function btn:SetScript() end
    return btn
end

local GUI = { RailWidth = 62 }
function GUI.SnapLen(_, v) return v end
function GUI:StyleButton(btn, o) btn.w = o.width end
function GUI:AttachModuleButton() end
function GUI:SelectModule() end
local env = setmetatable({
    GUI = GUI,
    deckFrame = button(0),
    CreateFrame = function() return button(0) end,
    Resolve = function(v) if type(v) == "function" then return v() end return v end,
}, { __index = _G })
local f, err = loadstring(RAIL:sub(a, b) .. "\nreturn BuildDeckTabs\n", "=RailDeck")
check(f ~= nil, "lift: parses (" .. tostring(err) .. ")")
if not f then return end
setfenv(f, env)
local BuildDeckTabs = f()

-- ---- the units module's own numbers, read from its source ----
local tabW = tonumber(PAGES:match("UFO%.TAB_WIDTH = (%d+)"))
local floorW = tonumber(PAGES:match("UFO%.MIN_WINDOW_WIDTH = (%d+)"))
local tabList = PAGES:match("UFO%.TABS = (%b{})")
check(tabW and floorW and tabList, "Pages.lua declares TAB_WIDTH, MIN_WINDOW_WIDTH and TABS")
check(PAGES:find("tabWidth = UFO.TAB_WIDTH,", 1, true) and PAGES:find("minWindowWidth = UFO.MIN_WINDOW_WIDTH,", 1, true),
      "the units module passes both to the registry")
local tabs = {}
for id in (tabList or ""):gmatch('"(%w+)"') do tabs[#tabs + 1] = { id = id, label = id } end
eq(#tabs, 6, "six unit tabs")

print("-- tab width: tab, then module, then 70")
local plain = { id = "p", tabs = { { id = "x" }, { id = "y", width = 90 } } }
BuildDeckTabs(plain)
eq(plain._deckTabs.x.w, 70, "no width anywhere: 70")
eq(plain._deckTabs.y.w, 90, "a tab's own width wins")
local def = { id = "units", tabs = tabs, tabWidth = tabW, minWindowWidth = floorW }
BuildDeckTabs(def)
eq(def._deckTabs.player.w, tabW, "units tabs take the module's width")

-- ---- the right-hand cluster, English widths (label + 38, glyphs 22) ----
GUI.LockButton, GUI.TestButton = button(72), button(60)
GUI.UndoButton, GUI.RedoButton = button(22), button(22)

local function fits(window)
    local deck = window - GUI.RailWidth
    return GUI:ModuleDeckTabsWidth(def) + GUI.DECK_ROW_GAP + GUI:DeckClusterWidth() <= deck
end

print("-- the enforced minimum holds the row and the cluster")
local minW = GUI:ModuleDeckMinWidth(def)
check(minW and minW >= floorW, "minimum is at least the module's floor (" .. tostring(minW) .. ")")
check(fits(minW), "row + cluster fit deck 2 at the enforced minimum")
check(not fits(580), "...and would NOT fit at the old 580 minimum (why the floor exists)")
eq(GUI:ModuleDeckTabsWidth(def), 12 + 6 * tabW + 5 * 4, "tab row = 12 + n x width + gaps")

print("-- a translated label that grows the cluster raises the minimum")
GUI.LockButton.w = 160
local grown = GUI:ModuleDeckMinWidth(def)
check(grown > floorW, "measured beyond the floor (" .. tostring(grown) .. ")")
check(fits(grown), "row + cluster still fit at the raised minimum")
GUI.LockButton.w = 72
GUI.UndoButton.shown = false
check(GUI:DeckClusterWidth() < 229, "hidden undo/redo leave the cluster narrower")
GUI.UndoButton.shown = true

print("-- a module without tabs asks for nothing; group frames unchanged")
eq(GUI:ModuleDeckMinWidth({ id = "home" }), nil, "no tabs, no floor: nil")

print("-- the panel applies it")
check(PANEL:find("GUI:ModuleDeckMinWidth(view)", 1, true)
      and PANEL:find("local view = GUI.ModuleView and", 1, true),
      "ApplyPageWidthBounds raises the minimum for the module view showing")
