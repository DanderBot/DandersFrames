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
L["Anchor to…"] = true
L["Anchor root"] = true
L["Anchored"] = true
L["Anchored to %s"] = true
L["Anchoring would create a loop."] = true
L["Arrow keys move the selected element. Shift ×10, Ctrl ×100."] = true
L["Auto"] = true
L["Backup anchor"] = true
L["Backup anchor %s"] = true
L["Bottom"] = true
L["Cancel"] = true
L["Clear backup %s"] = true
L["Click to select, arrow keys to nudge (Shift ×10, Ctrl ×100)."] = true
L["Close"] = true
L["Collapse"] = true
L["Configure"] = true
L["Copy to %s"] = true
L["Open this element's own settings."] = true
L["Fold the strip away to a small tab at the top of the screen."] = true
L["Drag to move. Shift locks to horizontal, Ctrl to vertical."] = true
L["Drop into a zone to re-anchor; pull far away or Detach to free it."] = true
L["Press Esc or use the top strip to lock."] = true
L["Center"] = true
L["Center %s"] = true
L["DandersMover"] = true
L["Demo cannot be started or stopped in combat."] = true
L["Demo dynamic target now points at %s."] = true
L["Demo started. /mover to unlock. /mover demo off | refresh | reset"] = true
L["Demo stopped."] = true
L["Detach"] = true
L["Detach %s"] = true
L["Detached — backup anchor cleared"] = true
L["Discard"] = true
L["End"] = true
L["Free"] = true
L["Editor"] = true
L["Grid"] = true
L["Grid Size"] = true
L["hidden"] = true
L["Hold Shift for 10 units, Ctrl for 100."] = true
L["Keyboard nudge"] = true
L["Left"] = true
L["Move %s"] = true
L["Movers cannot be unlocked in combat."] = true
L["Movers suspended for combat."] = true
L["No addons have registered movers yet."] = true
L["None"] = true
L["Nudge"] = true
L["Nudge %s"] = true
L["Offset X"] = true
L["Offset Y"] = true
L["Panel side"] = true
L["Redo"] = true
L["Registered addons"] = true
L["Reset"] = true
L["Reset %s"] = true
L["Right"] = true
L["Save"] = true
L["Save & Exit"] = true
L["Settings"] = true
L["Shift: horizontal · Ctrl: vertical · Esc: lock"] = true
L["Show distance measures"] = true
L["Show grid"] = true
L["Show grid snap lines"] = true
L["Show movers for hidden frames"] = true
L["Show other addons' movers"] = true
L["Show snap zones within"] = true
L["Snap distance"] = true
L["Snap to frames"] = true
L["Snap to grid"] = true
L["Snap to screen"] = true
L["Snapping"] = true
L["Snapping, grid and per-addon mover toggles."] = true
L["Start"] = true
L["Top"] = true
L["Redid: %s"] = true
L["Undid: %s"] = true
L["Undo"] = true
L["Usage: /mover [unlock|lock|config|demo]"] = true
L["X"] = true
L["Y"] = true
L["(backup)"] = true
L["(hidden)"] = true
L["(unavailable)"] = true
L["You have unsaved mover changes."] = true

-- `= true` marks a key as "same as the English text". Convert so lookups return
-- the string itself; the metatable above only covers keys that are absent.
for key, value in pairs(L) do
    if value == true then rawset(L, key, key) end
end
