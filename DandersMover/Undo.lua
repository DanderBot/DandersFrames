local addonName, NS = ...

-- ============================================================
-- DANDERSUNDO-1.0
-- Generic undo/redo stacks. No knowledge of movers. Entries are closures.
-- ============================================================
local MAJOR, MINOR = "DandersUndo-1.0", 1
local Undo = LibStub:NewLibrary(MAJOR, MINOR)
if not Undo then return end
local CallbackHandler = LibStub("CallbackHandler-1.0")

local tremove, tinsert = table.remove, table.insert
local pcall, geterrorhandler = pcall, geterrorhandler

local Stack = {}
Stack.__index = Stack

function Undo:New(opts)
    local s = setmetatable({
        limit = (opts and opts.limit) or 100,
        entries = {},     -- undo stack, top at end
        redo = {},        -- redo branch, top at end
        groupDepth = 0,
        group = nil,      -- { label, items } while grouping
    }, Stack)
    s.callbacks = CallbackHandler:New(s)
    return s
end

local function fire(s) s.callbacks:Fire("Changed") end

local function run(entry, fnName)
    local ok, err = pcall(entry[fnName])
    if not ok then geterrorhandler()(err) end
    return ok
end

function Stack:Push(entry)
    if self.group then
        tinsert(self.group.items, entry)
        return
    end
    tinsert(self.entries, entry)
    wipe(self.redo)
    while #self.entries > self.limit do tremove(self.entries, 1) end
    fire(self)
end

function Stack:BeginGroup(label)
    self.groupDepth = self.groupDepth + 1
    if self.groupDepth == 1 then self.group = { label = label, items = {} } end
end

function Stack:EndGroup()
    if self.groupDepth == 0 then return end
    self.groupDepth = self.groupDepth - 1
    if self.groupDepth > 0 then return end
    local group = self.group
    self.group = nil
    if #group.items == 0 then return end
    local items = group.items
    self:Push({
        label = group.label,
        undo = function() for i = #items, 1, -1 do items[i].undo() end end,
        redo = function() for i = 1, #items do items[i].redo() end end,
    })
end

function Stack:Undo()
    local entry = tremove(self.entries)
    if not entry then return false end
    if run(entry, "undo") then tinsert(self.redo, entry) end
    fire(self)
    return true
end

function Stack:Redo()
    local entry = tremove(self.redo)
    if not entry then return false end
    if run(entry, "redo") then tinsert(self.entries, entry) end
    fire(self)
    return true
end

function Stack:Clear()
    wipe(self.entries); wipe(self.redo)
    self.group = nil; self.groupDepth = 0
    fire(self)
end

function Stack:CanUndo() return #self.entries > 0 end
function Stack:CanRedo() return #self.redo > 0 end
function Stack:Peek() local e = self.entries[#self.entries]; return e and e.label end
function Stack:PeekRedo() local e = self.redo[#self.redo]; return e and e.label end
