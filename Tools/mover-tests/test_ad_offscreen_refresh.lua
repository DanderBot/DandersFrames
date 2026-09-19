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
if s then
    local rows = editor:find("if S.rowsMode then", s, true)
    local guard = editor:find("if S.page and S.page.IsVisible and not S.page:IsVisible() then", s, true)
    local inval = editor:find("if S.page.Invalidate then S.page:Invalidate() end", s, true)
    local rebuild = editor:find("if S.page and S.page.Refresh then S.page:Refresh() end", s, true)
    check(rows and guard and guard > rows, "adoffscreen: the rows branch checks visibility")
    check(guard and inval and rebuild and guard < inval and inval < rebuild,
          "adoffscreen: off screen invalidates and returns BEFORE the rebuild")
end

check(editor:find("function DF:AuraDesigner_IsPageShown()", 1, true) ~= nil,
      "adoffscreen: the designer answers whether it is on screen")

local hook = gui:find("onSectionToggled = function(key, expanded)", 1, true)
check(hook ~= nil, "adoffscreen: the section-toggle hook exists")
if hook then
    local ask = gui:find("if DF.AuraDesigner_IsPageShown and not DF:AuraDesigner_IsPageShown() then return end", hook, true)
    local call = gui:find("DF:AuraDesigner_RefreshPage()", hook, true)
    check(ask and call and ask < call, "adoffscreen: a section toggle asks before redrawing the designer")
end
