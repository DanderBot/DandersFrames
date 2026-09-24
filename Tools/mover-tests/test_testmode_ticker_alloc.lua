local NS = ...

-- ============================================================
-- TEST MODE ANIMATION TICKER, PER-TICK GARBAGE
-- DandersFrames_Options/TestMode/TestMode.lua
-- ------------------------------------------------------------
-- Source census, because TestMode.lua is not headlessly loadable (one 5,000-line
-- file over the live frame system).
--
-- The Animate Health ticker runs at 20 Hz and calls UpdateTestFrameHealthOnly for
-- every shown test frame, which calls GetTestUnitData. A mover session forces test
-- mode on, so this runs for as long as the movers are unlocked. Two per-call
-- allocations were pure waste and are pinned out here:
--   * GetTestUnitData rebuilt its constant lookup tables (six 40-entry raid lists
--     and the boss names) on every call;
--   * UpdateTestFrameHealthOnly copied the fresh result into a second table
--     field by field just to change one value.
-- ============================================================

local src = options_file_source("TestMode/TestMode.lua")

local function code(text)
    local out = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line:gsub("%-%-.*$", "")
    end
    return table.concat(out, "\n")
end

-- A top-level function's body: from its declaration to the first column-0 `end`.
local function body(decl)
    local s = src:find(decl, 1, true)
    check(s ~= nil, decl .. " is still declared")
    if not s then return nil end
    local e = src:find("\nend\n", s, true)
    check(e ~= nil, decl .. " body closes at column 0")
    return code(src:sub(s, e or #src))
end

local get = body("function DF:GetTestUnitData(")
if get then
    for _, name in ipairs({ "bossNames", "testNames", "testClasses", "testRoles",
                            "testSpecs", "testHealthPercents", "testPowerPercents" }) do
        check(not get:find("local%s+" .. name .. "%s*=%s*{"),
            "GetTestUnitData does not rebuild " .. name .. " per call")
        -- ...and it still reads it, so the hoisted copy is the one in use.
        check(get:find(name .. "[", 1, true) ~= nil, "GetTestUnitData still reads " .. name)
    end
end

-- The hoisted tables live at file scope, ahead of the function.
local fileCode = code(src)
local fnAt = fileCode:find("function DF:GetTestUnitData(", 1, true) or 0
for _, name in ipairs({ "bossNames", "testNames", "testPowerPercents" }) do
    local at = fileCode:find("\nlocal " .. name .. " = {", 1, true)
    check(at ~= nil and at < fnAt, name .. " is a file-scope local declared before GetTestUnitData")
end

local tick = body("function DF:UpdateTestFrameHealthOnly(")
if tick then
    check(not tick:find("animatedTestData%s*=%s*{"),
        "the health tick does not copy the unit data into a fresh table")
    check(not tick:find("for%s+k%s*,%s*v%s+in%s+pairs%(%s*testData%s*%)"),
        "the health tick does not walk testData to copy it")
end
