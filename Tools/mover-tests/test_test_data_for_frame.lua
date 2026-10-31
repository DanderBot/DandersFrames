local NS = ...

-- ============================================================
-- PER-FRAME TEST DATA: DF:GetTestDataForFrame(frame, ...)
-- A frame carrying frame.dfTestData paints that; every other frame gets the
-- shared test-unit lookup with exactly the arguments its caller used to pass.
-- ============================================================

local function norm(s) return (s:gsub("\r\n", "\n")) end
local src = norm(df_file_source("Frames/Core.lua"))
local a = src:find("function DF:GetTestDataForFrame%(")
local b = a and src:find("\nend\n", a, true)
check(a ~= nil and b ~= nil, "GetTestDataForFrame is defined in Frames/Core.lua")

local DF = {}
local calls = {}
function DF:GetTestUnitData(...)
    local n = select("#", ...)
    calls[#calls + 1] = { n = n, ... }
    return { tag = "pool", args = { ... } }
end
if a and b then
    local f, err = loadstring(src:sub(a, b + 4), "=GetTestDataForFrame")
    check(f ~= nil, "parses (" .. tostring(err) .. ")")
    setfenv(f, setmetatable({ DF = DF }, { __index = _G }))
    f()
end

print("-- no own data: the shared lookup, same arguments as before")
local fr = { index = 3, isRaidFrame = true, isPinnedBossFrame = nil }
local d = DF:GetTestDataForFrame(fr)
eq(d and d.tag, "pool", "frame only: the pool lookup")
eq(calls[1] and calls[1][1], 3, "frame only: frame.index")
eq(calls[1] and calls[1][2], true, "frame only: frame.isRaidFrame")
eq(calls[1] and calls[1].n, 3, "frame only: three arguments, boss flag included")
DF:GetTestDataForFrame(fr, 7, false)
eq(calls[2] and calls[2][1], 7, "explicit: the index passed")
eq(calls[2] and calls[2][2], false, "explicit: the raid flag passed")
eq(calls[2] and calls[2].n, 2, "explicit: exactly the arguments passed")
DF:GetTestDataForFrame(fr, nil)
eq(calls[3] and calls[3].n, 1, "an explicit nil index is still passed through, not replaced")

print("-- own data wins, and needs no lookup")
local own = { name = "Own", healthPercent = 0.5 }
local n0 = #calls
eq(DF:GetTestDataForFrame({ dfTestData = own, index = 1 }), own, "frame.dfTestData returned")
eq(DF:GetTestDataForFrame({ dfTestData = own }, 2, true), own, "even when the caller passes slot arguments")
eq(#calls, n0, "the shared lookup is not asked")

print("-- no lookup loaded")
local saved = DF.GetTestUnitData
DF.GetTestUnitData = nil
eq(DF:GetTestDataForFrame(fr), nil, "nil without the companion")
eq(DF:GetTestDataForFrame({ dfTestData = own }), own, "own data still answers")
DF.GetTestUnitData = saved
eq(DF:GetTestDataForFrame(nil), nil, "nil frame, no arguments: nil")

print("-- the inline callers go through it")
local function count(s, pat) local _, n = s:gsub(pat, "") return n end
local sites = {
    { "Frames/Border.lua", 2 }, { "Core.lua", 2 }, { "Frames/StatusIcons.lua", 1 },
    { "Frames/Create.lua", 2 }, { "Frames/Update.lua", 2 }, { "Features/Dispel.lua", 1 },
    { "Frames/Pets.lua", 1 }, { "TextDesigner/DataSource.lua", 1 },
}
for _, s in ipairs(sites) do
    eq(count(norm(df_file_source(s[1])), "DF:GetTestDataForFrame%("), s[2], s[1] .. ": routed calls")
end
local border = norm(df_file_source("Frames/Border.lua"))
eq(count(border, "DF:GetTestUnitData%("), 0, "Border: no direct lookup left")
eq(count(norm(df_file_source("Frames/Create.lua")), "DF:GetTestUnitData%("), 0, "Create: no direct lookup left")
eq(count(norm(df_file_source("Frames/Update.lua")), "DF:GetTestUnitData%("), 0, "Update: no direct lookup left")
local ds = norm(df_file_source("TextDesigner/DataSource.lua"))
check(ds:find("if frame and frame%.dfTestData then\n%s*instance%.data = frame%.dfTestData"),
      "Text Designer's test source reads a frame's own data")
