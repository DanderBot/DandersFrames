local NS = ...

-- ============================================================
-- interceptWrite ROUTES ONLY RAID-TABLE WRITES -- DandersFrames/GUI/GUI.lua
-- ------------------------------------------------------------
-- With Raid up and an auto layout running, a write is handed to the layout's
-- runtime handler, which matches by KEY NAME. Any other table written while Raid
-- was up (a nested table, a page with its own settings table) whose key was also
-- an overridden raid key was swallowed into the raid baseline. The hook now
-- routes only writes to the raid table itself (the proxy or the real table).
-- The hook is lifted out of the host table and run against recorders.
-- ============================================================

local SRC = df_file_source("GUI/GUI.lua"):gsub("\r\n", "\n")
local a = SRC:find("    interceptWrite = function(db, key, value)\n", 1, true)
local b = a and SRC:find("\n    end,\n", a, true)
check(a ~= nil and b ~= nil, "lift: found the interceptWrite hook")
if not (a and b) then return end
-- Up to and including the closing `end` (the `,` after it belongs to the table).
local body = SRC:sub(a, b + 7):gsub("^%s*interceptWrite = ", "return ")

local runtime = {}
local undo = {}
local GUI = { SelectedMode = "raid" }
local realRaid, partyDB = { healthTexture = "A" }, {}
local raidProxy = setmetatable({}, { __index = realRaid, __newindex = realRaid })
local DF = {
    db = { party = partyDB, raid = raidProxy },
    _realRaidDB = realRaid,
    SettingsUndo = { OnInterceptWrite = function(_, db, key) undo[#undo + 1] = key end },
    AutoProfilesUI = { HandleRuntimeWrite = function(_, key, value) runtime[#runtime + 1] = key; return true end },
}
local f, err = loadstring(body, "=interceptWrite")
check(f ~= nil, "lift: the hook parses (" .. tostring(err) .. ")")
if not f then return end
setfenv(f, setmetatable({ DF = DF, GUI = GUI }, { __index = _G }))
local interceptWrite = f()

print("-- Raid pages: unchanged")
eq(interceptWrite(raidProxy, "healthTexture", "B"), true, "the raid proxy: routed to the layout handler")
eq(interceptWrite(realRaid, "healthTexture", "B"), true, "the real raid table: routed")
eq(#runtime, 2, "...both reached the handler")

print("-- Any other table: never routed")
local own = { healthTexture = "A" }
eq(interceptWrite(own, "healthTexture", "B"), false, "a page's own table with a raid key name: written normally")
eq(interceptWrite(realRaid.nested or {}, "healthTexture", "B"), false, "a nested table: written normally")
eq(interceptWrite(partyDB, "healthTexture", "B"), false, "the party table under Raid mode: written normally")
eq(interceptWrite(nil, "healthTexture", "B"), false, "no table: not routed")
eq(#runtime, 2, "the handler saw none of them")
eq(#undo, 6, "...but undo captured every write, routed or not (the capture comes first)")

print("-- Party mode: unchanged")
GUI.SelectedMode = "party"
eq(interceptWrite(raidProxy, "healthTexture", "B"), false, "party mode: never routed")
eq(#runtime, 2, "...handler untouched")
