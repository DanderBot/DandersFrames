local NS = ...

-- ============================================================
-- A TEXT GROUP'S CARD HAS AN ITEMS SECTION
-- ------------------------------------------------------------
-- v5.4.0 turned an element's Content / Appearance / Position into cards built in
-- group mode, and BuildContentSection only builds a group's item list when NOT in
-- group mode. Nothing else called BuildGroupItemsSection, so a text group had no
-- item list, no Add Item and no per-item settings: its data could not be chosen.
-- This RUNS BuildElementSectionCards (cut out of TextDesigner/UI/Options.lua)
-- against stubs and pins:
--   ✓ a group element gets an Items card that calls BuildGroupItemsSection, in
--     group mode, between Content and Appearance;
--   ✓ a plain text element gets no Items card.
--   ✗ what the cards look like -- that is the in-game checklist.
-- ============================================================

local TD = options_file_source("TextDesigner/UI/Options.lua"):gsub("\r\n", "\n")

local function cut(src, startPlain, stopPlain)
    local s = src:find(startPlain, 1, true)
    if not s then return nil end
    local e = src:find(stopPlain, s, true)
    if not e then return nil end
    return src:sub(s, e + #stopPlain - 1)
end

print("-- TD: a text group's card has an Items section")

local sections = cut(TD, "local TD_SECTIONS = {", "\n}\n")
local builder = cut(TD, "local function BuildElementSectionCards(", "\nend\n")
check(sections ~= nil, "items: TD_SECTIONS can be cut out")
check(builder ~= nil, "items: BuildElementSectionCards can be cut out")
if not (sections and builder) then return end

local function Region()
    local r = {}
    function r:ClearAllPoints() end
    function r:SetPoint() end
    function r:SetHeight() end
    function r:SetWidth() end
    function r:Show() end
    function r:Hide() end
    function r:HookScript() end
    return r
end

local calls
local GUI = { SectionCard = { gap = 8 } }
function GUI:CreateCollapsibleSection(_, label)
    local s = Region()
    s.layoutHeight, s.expanded, s.label = 30, true, label
    function s:RegisterChild() end
    function s:SetExpanded(v) self.expanded = v end
    calls.sections[#calls.sections + 1] = label
    return s
end
function GUI:CreateSettingsGroup()
    local g = Region()
    g.calculatedHeight = 50
    function g:LayoutChildren() end
    return g
end

local L = setmetatable({}, { __index = function(_, k) return k end })
local function rec(name)
    return function(...)
        local args = { ... }
        calls.builders[#calls.builders + 1] = { name = name, group = args[#args] }
        return 0
    end
end

local src = "local GUI, L, BuildContentSection, BuildGroupItemsSection, BuildAppearanceSection,"
    .. " BuildPositionSection = ...\n"
    .. sections .. "\nlocal TD_SECTION_INSET = 8\n" .. builder
    .. "\nreturn BuildElementSectionCards\n"
local chunk, err = loadstring(src)
check(chunk ~= nil, "items: the cut parses (" .. tostring(err) .. ")")
if not chunk then return end
local Build = chunk(GUI, L, rec("content"), rec("items"), rec("appearance"), rec("position"))

local function run(elem)
    calls = { sections = {}, builders = {} }
    Build(GUI, Region(), elem, {}, {}, {}, {}, 400)
    return calls
end

local g = run({ contentType = "group", groupItems = { { contentType = "health_percent" } } })
eq(table.concat(g.sections, ","), "Content,Items,Appearance,Position", "group: Content, Items, Appearance, Position cards")
local itemsCall
for _, c in ipairs(g.builders) do if c.name == "items" then itemsCall = c end end
check(itemsCall ~= nil, "group: the Items card builds the item list")
check(itemsCall and type(itemsCall.group) == "table", "...in group mode (handed the card's settings group)")

local fresh = { contentType = "group" }
run(fresh)
check(type(fresh.groupItems) == "table", "group with no items: an empty item list is made, so Add Item works")

local t = run({ contentType = "health_percent" })
eq(table.concat(t.sections, ","), "Content,Appearance,Position", "plain text: no Items card")
for _, c in ipairs(t.builders) do
    check(c.name ~= "items", "plain text: the item list is never built")
end
