local NS = ...

-- ============================================================
-- THE AURA DESIGNER IS NOT REBUILT WHILE IT IS OFF SCREEN
-- DF:AuraDesigner_RefreshPage used to call S.page:Refresh() (a rebuild, parked in
-- GUI._trashFrame forever) from callers on OTHER pages -- a Colour-by-Time edit,
-- the global font apply, and a collapsible section toggled on ANY page. Off
-- screen it now only marks the page stale; the section hook asks first.
-- ============================================================

local editor = options_file_source("AuraDesigner/UI/Editor.lua")
local gui    = df_file_source("GUI/GUI.lua")

local s = editor:find("function DF:AuraDesigner_RefreshPage()", 1, true)
check(s ~= nil, "adoffscreen: AuraDesigner_RefreshPage exists")

check(editor:find("function DF:AuraDesigner_IsPageShown()", 1, true) ~= nil,
      "adoffscreen: the designer answers whether it is on screen")

local hook = gui:find("onSectionToggled = function(key, expanded)", 1, true)
check(hook ~= nil, "adoffscreen: the section-toggle hook exists")
if hook then
    local ask = gui:find("if DF.AuraDesigner_IsPageShown and not DF:AuraDesigner_IsPageShown() then return end", hook, true)
    local call = gui:find("DF:AuraDesigner_RefreshPage()", hook, true)
    check(ask and call and ask < call, "adoffscreen: a section toggle asks before redrawing the designer")
end
