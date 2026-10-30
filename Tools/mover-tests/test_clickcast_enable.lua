local NS = ...

-- ============================================================
-- TURNING CLICK-CASTING ON FROM THE MODULES PAGE
-- DandersFrames_Options/ClickCasting/UI/Main.lua (CC:RequestEnabled) over the
-- real conflict popup (ClickCasting/UI/Dialogs.lua). With Clique or Clicked
-- loaded the enable goes through the conflict popup, and the caller's onDone
-- (the Modules page's repaint of itself and the settings rail) must still run
-- once the popup turns click-casting on.
-- ⚠ Headless: the popup's own frames are never built; its "already ignored"
-- path and the hand-over of onDone are what is checked.
-- ============================================================

local savedDF, savedAddOns, savedSlash = DandersFrames, C_AddOns, SlashCmdList
SlashCmdList = SlashCmdList or {}

local GUI = { Colors = {}, DialogColors = {} }
local CC = { PROFILE_TEMPLATE = { options = {} }, GetPlayerClass = function() return "PRIEST" end }
local DF = { GUI = GUI, ClickCast = CC }
DF.L = setmetatable({}, { __index = function(_, k) return k end })
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
function DF:Say() end
DandersFrames = DF

local enabledWrites = {}
function CC:SetEnabled(v) enabledWrites[#enabledWrites + 1] = v end

local loaded = {}
C_AddOns = { IsAddOnLoaded = function(name) return loaded[name] == true end }

load_options_file_into("ClickCasting/UI/Main.lua", NS)
load_options_file_into("ClickCasting/UI/Dialogs.lua", NS)
check(CC.RequestEnabled and CC.ShowClickCastConflictPopup, "api: RequestEnabled and the conflict popup are on CC")

local done = 0
local function onDone() done = done + 1 end

print("-- Click-casting enable: no conflict")
CC.db = { enabled = false, ignoreBlizzardWarning = true }
CC:RequestEnabled(true, nil, onDone)
check(CC.db.enabled == true and done == 1, "plain: enabled, and onDone ran")

print("-- Click-casting enable: through the conflict popup")
loaded.Clique = true
CC.db = { enabled = false, ignoreConflictWarning = true, ignoreBlizzardWarning = true }
done = 0
CC:RequestEnabled(true, nil, onDone)
check(CC.db.enabled == true, "conflict (ignored): click-casting is turned on")
eq(done, 1, "conflict (ignored): ...and onDone still runs, so the Modules page and the rail repaint")

-- The popup proper: onDone is handed to it.
local realPopup = CC.ShowClickCastConflictPopup
local handed
CC.ShowClickCastConflictPopup = function(_, conflicts, cb, fn) handed = { conflicts = conflicts, fn = fn } end
CC.db = { enabled = false }
CC:RequestEnabled(true, "CB", onDone)
check(handed and handed.conflicts[1] == "Clique" and handed.fn == onDone,
      "conflict: RequestEnabled hands its onDone to the popup")
CC.ShowClickCastConflictPopup = realPopup

-- The popup's Ignore -> Confirm path runs it too (its frames are not built here).
local DLG = options_file_source("ClickCasting/UI/Dialogs.lua"):gsub("\r\n", "\n")
local a = DLG:find("function CC:ShowClickCastConflictPopup(conflicts, enableCheckbox, onDone)", 1, true)
local b = a and DLG:find("\nfunction CC:ShowBlizzardClickCastWarning", a, true)
local body = (a and b) and DLG:sub(a, b) or ""
eq(select(2, body:gsub("if onDone then onDone%(%) end", "")), 2,
   "conflict: both popup paths that turn it on without a reload run onDone")

loaded.Clique = nil
DandersFrames, C_AddOns, SlashCmdList = savedDF, savedAddOns, savedSlash
