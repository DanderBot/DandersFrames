local NS = ...

-- ============================================================
-- AUTO-LAYOUT EDITS SURVIVE A DANDERSMOVER SESSION
-- ------------------------------------------------------------
-- A layout's Unlock enters an edit of that layout and opens a DandersMover session,
-- and the session hides the settings window. The window's OnHide ends an edit, so the
-- drag landed on the base profile and the layout never got it. Pinned here:
--   1. the session hide is flagged, and OnHide does not end the edit for it;
--   2. the session's Locked finishes a layout-unlock edit;
--   3. a window-close exit still re-applies the layout (EvaluateAndApply runs before
--      the skipUIUpdates return).
-- Source shape: the session and the window cannot be driven headless.
-- ============================================================

local function norm(s) return (s:gsub("\r\n", "\n")) end
local panel  = norm(options_file_source("GUI/Panel.lua"))
local bridge = norm(df_file_source("Features/MoverBridge.lua"))
local auto   = norm(df_file_source("Core/AutoProfiles.lua"))

-- 1
local hideAt = bridge:find("DF._guiHiddenForMoverSession = true\n        DF.GUIFrame:Hide()\n        DF._guiHiddenForMoverSession = nil", 1, true)
check(hideAt ~= nil, "mover edit: the session's window hide is flagged on both sides of the Hide")
check(panel:find("AutoProfilesUI:IsEditing() and not DF._guiHiddenForMoverSession then\n            AutoProfilesUI:ExitEditing(true)", 1, true) ~= nil,
      "mover edit: the window's OnHide does not end an edit when a session hid it")

-- 2
local lockedAt = bridge:find('Mover.RegisterCallback(Bridge, "Locked"', 1, true)
local exitAt = lockedAt and bridge:find("if DF.raidLayoutEditUnlock then\n        DF.raidLayoutEditUnlock = nil", lockedAt, true)
local reopenAt = lockedAt and bridge:find("local page, mode = Bridge.closedGUIPage, Bridge.closedGUIMode", lockedAt, true)
check(exitAt ~= nil, "mover edit: Locked finishes a layout-unlock edit")
check(exitAt and reopenAt and exitAt < reopenAt, "mover edit: ...before the window is reopened")

-- 3
local fnAt = auto:find("function AutoProfilesUI:ExitEditing(skipUIUpdates)", 1, true)
local evalAt = fnAt and auto:find("AutoProfilesUI:EvaluateAndApply()", fnAt, true)
local skipAt = fnAt and auto:find("if skipUIUpdates then return end", fnAt, true)
check(evalAt and skipAt and evalAt < skipAt, "mover edit: a window-close exit still re-applies the active layout")
