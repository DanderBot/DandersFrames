local addonName, NS = ...

-- ============================================================
-- LOCALE
-- Keys are the English text. Missing keys fall back to the key itself.
-- ============================================================
local L = setmetatable({}, { __index = function(t, k) return k end })
NS.L = L

-- Strings are added here as tasks introduce them (alphabetical).
L["Anchor %s"] = true
L["Anchor point %s"] = true
L["Anchored to %s"] = true
L["Anchoring would create a loop."] = true
L["Cancel"] = true
L["Center"] = true
L["Center %s"] = true
L["DandersMover"] = true
L["Detach"] = true
L["Detach %s"] = true
L["Discard"] = true
L["Grid Size"] = true
L["Keyboard nudge"] = true
L["Move %s"] = true
L["Movers cannot be unlocked in combat."] = true
L["Movers suspended for combat."] = true
L["Nudge %s"] = true
L["Redo"] = true
L["Reset"] = true
L["Reset %s"] = true
L["Save"] = true
L["Save & Exit"] = true
L["Show grid"] = true
L["Show movers for hidden frames"] = true
L["Snap to frames"] = true
L["Snap to grid"] = true
L["Snap to screen"] = true
L["Undo"] = true
L["Usage: /mover [unlock|lock|config|demo]"] = true
L["(unavailable)"] = true
L["You have unsaved mover changes."] = true
