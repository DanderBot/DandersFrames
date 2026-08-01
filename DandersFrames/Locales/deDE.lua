-- Populate DF_AllLocales["deDE"] so Core.lua's ADDON_LOADED handler
-- can apply this locale's translations as an overlay if the user's
-- languageOverride selects it. No AceLocale interaction here — the
-- overlay step happens once the SavedVariable is actually populated,
-- which is only guaranteed at ADDON_LOADED time (not file-scope).
DF_AllLocales = DF_AllLocales or {}
DF_AllLocales.deDE = {}
local L = DF_AllLocales.deDE
--@localization(locale="deDE", format="lua_additive_table", handle-unlocalized="comment")@
