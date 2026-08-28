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
