local NS = ...

-- ============================================================
-- TEST MODE POPUP, DEFENSIVES PAIR -- DandersFrames_Options/TestMode/TestMode.lua
-- ------------------------------------------------------------
-- Source census of the Party / Raid section builders.
--
-- The rule being pinned (bug #1118 item 1): nothing in the test popup may grey
-- a control on a LIVE PROFILE setting. Nothing tells the popup such a setting
-- changed, so the grey outlived whatever caused it: switch the Defensive Icon
-- back on and the box stayed dead, and being disabled it also swallowed its
-- own click-through to the page that would have fixed it.
--
-- Test Mode's own flags are fine to gate on (Show Auras greys the aura
-- counts) -- the popup re-reads them on every write. Raid-vs-party is a
-- VARIANT, so the party-only Targeted List rows are simply not built for Raid
-- (the behaviour itself is run in test_test_popup.lua).
-- ============================================================

local src = options_file_source("TestMode/TestMode.lua"):gsub("\r\n", "\n")

-- Comments out first, or the census answers to the note explaining the fix
-- rather than to the code.
local function code(text)
    local out = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line:gsub("%-%-.*$", "")
    end
    return table.concat(out, "\n")
end

local function body(name)
    local s = src:find("local function " .. name .. "(rows, scope)", 1, true)
    check(s ~= nil, name .. " is where the popup declares it")
    if not s then return "" end
    local e = src:find("\nend\n", s, true)
    return code(src:sub(s, e or #src))
end

local icons = body("BuildIcons")
local auras = body("BuildAuras")
local all = code(src:sub((src:find("-- TEST MODE POPUP", 1, true) or 1)))

check(not all:find("defensiveIconEnabled", 1, true), "the popup reads no live profile setting (defensiveIconEnabled)")
check(not icons:find("disabled", 1, true), "nothing greys the Defensives switch or its count")
check(icons:find('label = L["Defensives"], key = "testDefensiveCount"', 1, true) ~= nil,
      "the Defensives switch is a view of testDefensiveCount")
check(icons:find('label = L["Max Icons"], key = "testDefensiveCount"', 1, true) ~= nil,
      "...beside the count it views")
check(auras:find("local function aurasOff() return not GroupDB(scope).testShowAuras end", 1, true) ~= nil,
      "the aura counts gate on Test Mode's own Show Auras flag")
local _, gated = auras:gsub("disabled = aurasOff", "")
eq(gated, 2, "...both of them")
check(icons:find('if scope == "party" then', 1, true) ~= nil
      and icons:find('"testShowTargetedList"', 1, true) ~= nil,
      "the Targeted List rows are party-only")
