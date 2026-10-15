local NS = ...
local Undo = LibStub("DandersUndo-1.0")

-- basic push/undo/redo
do
    local s = Undo:New({ limit = 10 })
    local v = 0
    s:Push({ label = "set 1", undo = function() v = 0 end, redo = function() v = 1 end })
    v = 1
    check(s:CanUndo() and not s:CanRedo(), "can undo after push")
    eq(s:Peek(), "set 1", "peek label")
    s:Undo(); eq(v, 0, "undo restores")
    check(not s:CanUndo() and s:CanRedo(), "can redo after undo")
    eq(s:PeekRedo(), "set 1", "peek redo label")
    s:Redo(); eq(v, 1, "redo reapplies")
end

-- push truncates redo branch
do
    local s = Undo:New({})
    s:Push({ label = "a", undo = function() end, redo = function() end })
    s:Undo()
    s:Push({ label = "b", undo = function() end, redo = function() end })
    check(not s:CanRedo(), "redo branch dropped after new push")
    eq(s:Peek(), "b", "top is b")
end

-- limit drops oldest
do
    local s = Undo:New({ limit = 2 })
    for i = 1, 3 do s:Push({ label = "e" .. i, undo = function() end, redo = function() end }) end
    s:Undo(); s:Undo()
    check(not s:CanUndo(), "only 2 entries kept")
    eq(s:PeekRedo(), "e2", "oldest dropped was e1")
end

-- groups collapse to one step, nested flatten
do
    local s = Undo:New({})
    local log = {}
    s:BeginGroup("move")
    s:Push({ label = "x", undo = function() log[#log + 1] = "ux" end, redo = function() log[#log + 1] = "rx" end })
    s:BeginGroup("inner")
    s:Push({ label = "y", undo = function() log[#log + 1] = "uy" end, redo = function() log[#log + 1] = "ry" end })
    s:EndGroup()
    s:EndGroup()
    eq(s:Peek(), "move", "group label")
    s:Undo()
    eq(table.concat(log, ","), "uy,ux", "group undoes in reverse order")
    check(not s:CanUndo(), "group was one step")
    s:Redo()
    eq(table.concat(log, ","), "uy,ux,rx,ry", "group redoes in forward order")
end

-- empty group pushes nothing
do
    local s = Undo:New({})
    s:BeginGroup("empty"); s:EndGroup()
    check(not s:CanUndo(), "empty group ignored")
end

-- erroring closure is caught and entry removed
do
    local s = Undo:New({})
    s:Push({ label = "bad", undo = function() error("boom") end, redo = function() end })
    s:Undo()
    check(not s:CanUndo() and not s:CanRedo(), "broken entry removed, stack not wedged")
end

-- Changed callback fires
do
    local s = Undo:New({})
    local n = 0
    local obj = {}
    s.RegisterCallback(obj, "Changed", function() n = n + 1 end)
    s:Push({ label = "a", undo = function() end, redo = function() end })
    s:Undo(); s:Redo(); s:Clear()
    eq(n, 4, "Changed fired on push/undo/redo/clear")
end
