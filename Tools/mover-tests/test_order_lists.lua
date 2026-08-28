local NS = ...

-- ============================================================
-- THE THREE DRAG-ORDER LISTS ANSWER THE GROUP-WIDE VALUE SWEEP
-- DandersFrames_Options/GUI/Controls.lua
-- ------------------------------------------------------------
-- DandersUI Sections' RefreshChildValues (Sections.lua ~769) walks a group's
-- children and calls `widget:refreshValue()` on every one that exposes it. That
-- is the ONE path where a setting was written behind the widget's back -- a
-- group Reset, a press-and-hold defaults preview, or the undo of either -- and a
-- factory that does not opt in is a control left showing the old value inside an
-- open popout pane while everything beside it repaints.
--
-- CreateGroupOrderList was aliased when the Frame page's Group Display Order row
-- wired those verbs. The role and class lists were not, and the Sorting page's
-- Role Priority and Class Priority rows wire exactly the same two buttons -- so
-- all three are pinned here rather than one at a time as each page converts.
--
-- Source-level, like the page-builder tests: these factories build real frames
-- and cannot run headlessly, so what is checked is that the alias is written and
-- that it points at the list's own Refresh rather than at some other function.
-- ============================================================

local SRC = options_file_source("GUI/Controls.lua")

-- One factory's body, from its `function GUI:Create<X>` header to the next
-- top-level `end` at column zero. The three factories are consecutive in the
-- file, so a body read this way cannot borrow its neighbour's alias.
local function factoryBody(name)
    local head = "function GUI:" .. name .. "("
    local a = SRC:find(head, 1, true)
    check(a ~= nil, "source: Controls.lua declares " .. name)
    if not a then return "" end
    local b = SRC:find("\nend\n", a, true)
    check(b ~= nil and b > a, "source: ..." .. name .. " closes at the file's own indent")
    return SRC:sub(a, b or a)
end

print("-- Order lists: every drag list opts into the group-wide value sweep")
for _, name in ipairs({ "CreateRoleOrderList", "CreateClassOrderList", "CreateGroupOrderList" }) do
    local body = factoryBody(name)
    -- The list's own repaint exists...
    check(body:find("container.Refresh = function()", 1, true) ~= nil,
          name .. ": the list declares its own repaint")
    -- ...and is exposed under the name the sweep looks for. ONE alias, pointing
    -- at that repaint by reference: a second function here would be a copy that
    -- nothing keeps in step with the first.
    check(body:find("container.refreshValue = container.Refresh", 1, true) ~= nil,
          name .. ": ...and answers to RefreshChildValues under the shared name")
end

-- ...and the sweep really does ask for that name, so the alias is not aimed at
-- a spelling the kit stopped using.
do
    local sections = ui_file_source("Sections.lua")
    check(sections:find("group.RefreshChildValues = function(self)", 1, true) ~= nil,
          "order lists: the kit's value sweep is where the page expects it")
    check(sections:find("if widget and widget.refreshValue then", 1, true) ~= nil,
          "order lists: ...and it is `refreshValue` it asks every child for")
end

-- ============================================================
-- THE FONT DROPDOWN ANSWERS IT TOO
-- ------------------------------------------------------------
-- Same rule, next trigger. GUI:CreateFontDropdown is the other hand-rolled
-- control in this file -- a searchable, scrollable preview menu that predates
-- the kit's own dropdown and shares none of its code -- and it was the ONE
-- widget a Font Settings pane mounts that had not opted in. The Group Labels
-- page now mounts it inside a popout pane with Reset Group and Hold: Defaults
-- on the row, so a caption still naming the previous font after a reset is a
-- thing a user can now see.
--
-- ⚠ THE ALIAS POINTS AT THE WHOLE DISPLAY, NOT AT UpdateText. This factory
-- splits its repaint in two -- UpdateText paints the button's caption and
-- preview font, the override indicators beside the label are painted separately
-- -- and a reset moves both. RefreshDisplay is the pair, named once and used by
-- the container's OnShow as well, so the sweep and a re-show cannot drift.
-- ============================================================
print("-- Font dropdown: the hand-rolled preview menu opts into the value sweep")
do
    local body = factoryBody("CreateFontDropdown")
    check(body:find("local function RefreshDisplay()", 1, true) ~= nil,
          "font dropdown: the full repaint is a named function")
    check(body:find("container.refreshValue = RefreshDisplay", 1, true) ~= nil,
          "font dropdown: ...and answers to RefreshChildValues under the shared name")
    -- ONE body for both callers. An OnShow closure duplicating the two lines
    -- would be a second copy that nothing keeps in step with the alias.
    check(body:find('container:SetScript("OnShow", RefreshDisplay)', 1, true) ~= nil,
          "font dropdown: ...and the re-show path runs the same function, not a copy")
    -- Both halves are in it: the caption/preview, and the override indicators.
    local refresh = body:match("local function RefreshDisplay%(%)(.-)\n    end")
    check(refresh ~= nil, "font dropdown: the repaint's body is readable")
    if refresh then
        check(refresh:find("UpdateText()", 1, true) ~= nil,
              "font dropdown: ...it repaints the caption and its preview font")
        check(refresh:find("container:UpdateOverrideIndicators(", 1, true) ~= nil,
              "font dropdown: ...and the override indicators a reset can also move")
    end
end

-- ============================================================
-- AND SO DOES THE TEXTURE DROPDOWN
-- ------------------------------------------------------------
-- The third hand-rolled preview menu in this file, and the last of them to opt
-- in. Same shape as the font dropdown, same reason it was missed -- it predates
-- the kit's dropdown and shares none of its code -- and the same trigger: the
-- Pet Frames Appearance row mounts one inside a popout pane with Reset Group
-- and Hold: Defaults on the row, so a swatch still previewing the previous
-- texture after a reset is a thing a user can now see.
--
-- ⚠ THE ALIAS POINTS AT THE WHOLE DISPLAY, NOT AT UpdateText. As with the font
-- dropdown the repaint is in two halves -- UpdateText paints the caption, the
-- swatch and the (missing) tag; the override indicators beside the label are
-- painted separately -- and a reset moves both.
-- ============================================================
print("-- Texture dropdown: the preview swatch opts into the value sweep")
do
    local body = factoryBody("CreateTextureDropdown")
    check(body:find("local function RefreshDisplay()", 1, true) ~= nil,
          "texture dropdown: the full repaint is a named function")
    check(body:find("container.refreshValue = RefreshDisplay", 1, true) ~= nil,
          "texture dropdown: ...and answers to RefreshChildValues under the shared name")
    -- ONE body for both callers, as above.
    check(body:find('container:SetScript("OnShow", RefreshDisplay)', 1, true) ~= nil,
          "texture dropdown: ...and the re-show path runs the same function, not a copy")
    local refresh = body:match("local function RefreshDisplay%(%)(.-)\n    end")
    check(refresh ~= nil, "texture dropdown: the repaint's body is readable")
    if refresh then
        check(refresh:find("UpdateText()", 1, true) ~= nil,
              "texture dropdown: ...it repaints the caption, the swatch and the (missing) tag")
        check(refresh:find("container:UpdateOverrideIndicators(", 1, true) ~= nil,
              "texture dropdown: ...and the override indicators a reset can also move")
    end
end

-- ============================================================
-- ...AND THE FOUR FACTORIES BESIDE IT ALREADY DID
-- ------------------------------------------------------------
-- The rest of a Font Settings group. Checked here so "the font dropdown was the
-- only gap" is a test result rather than a claim in a commit message -- and so
-- that a factory quietly losing its opt-in fails in the same place.
--
-- Two of the five reach the sweep by DELEGATION rather than by declaring it:
-- CreateOutlineDropdown and CreateShadowCheckbox are thin wrappers that hand a
-- custom get/set pair to CreateDropdown / CreateCheckbox and return whatever
-- comes back, so what has to hold is that they still return the shared control
-- rather than building one of their own.
-- ============================================================
print("-- Font panes: the four controls beside the font dropdown")
do
    local widgets = options_file_source("GUI/SettingsWidgets.lua")

    -- The two DF-owned factories declare it themselves.
    check(widgets:find("container.refreshValue = UpdateState", 1, true) ~= nil,
          "checkbox: GUI:CreateCheckbox opts into the value sweep")
    check(widgets:find("container.refreshValue = UpdateSwatch", 1, true) ~= nil,
          "colour picker: GUI:CreateColorPicker opts into the value sweep")

    -- The two wrappers delegate, and the delegation is the opt-in.
    check(widgets:find("return GUI:CreateDropdown(parent, label or L[\"Outline\"], options, dbTable, dbKey, callback, get, set)", 1, true) ~= nil,
          "outline dropdown: it returns the shared dropdown, so it inherits the sweep")
    check(widgets:find("return GUI:CreateCheckbox(parent, label or L[\"Shadow\"], dbTable, dbKey, callback, get, set)", 1, true) ~= nil,
          "shadow tick: it returns the shared checkbox, so it inherits the sweep")

    -- ...and the two shared controls those wrappers land on are the kit's, which
    -- opt in at their own end. GUI:CreateDropdown / GUI:CreateSlider are the
    -- positional shims in DandersFrames/GUI/Compat.lua over these two.
    local kit = ui_file_source("Widgets.lua")
    check(kit:find("container.refreshValue = UpdateText", 1, true) ~= nil,
          "kit dropdown: UI:CreateDropdown opts into the value sweep")
    check(kit:find("container.refreshValue = container.RefreshValue", 1, true) ~= nil,
          "kit slider: UI:CreateSlider opts into the value sweep")
    local compat = df_file_source("GUI/Compat.lua")
    check(compat:find("return GUI.CreateDropdownNative(self, parent, {", 1, true) ~= nil,
          "shims: GUI:CreateDropdown really is the kit's dropdown under a positional signature")
    check(compat:find("return GUI.CreateSliderNative(self, parent, {", 1, true) ~= nil,
          "shims: ...and GUI:CreateSlider the kit's slider")
end
