local NS = ...

-- ============================================================
-- TEST MODE PANEL, DEFENSIVES PAIR -- DandersFrames_Options/TestMode/TestMode.lua
-- ------------------------------------------------------------
-- Source census, because the panel is not headlessly buildable -- it is one
-- 5,000-line builder over the real settings window.
--
-- The rule being pinned (bug #1118 item 1): nothing on this panel may grey a
-- control on a LIVE PROFILE setting. RefreshDependentEnabled runs from exactly
-- two places -- the Show Auras tick and UpdateState -- so a grey taken from a
-- setting that lives on a settings page outlives whatever caused it: switch the
-- Defensive Icon back on and the box stayed dead, and being disabled it also
-- swallowed its own click-through to the page that would have fixed it.
--
-- Test Mode's own flags are fine to gate on (Show Auras drives the aura sliders,
-- raid-vs-party drives the Targeted List pair) -- the panel owns those and
-- refreshes when they change. The two checks below say exactly that: the profile
-- key is gone from the refresh, and the panel-owned gates are still there.
-- ============================================================

local src = options_file_source("TestMode/TestMode.lua")

-- Comments out first, or the census answers to the note explaining the fix
-- rather than to the code -- the name it is looking for is written in both.
local function code(text)
    local out = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line:gsub("%-%-.*$", "")
    end
    return table.concat(out, "\n")
end

-- The refresh body, from its declaration to the `end` that closes it at the same
-- indent -- so the census reads the function rather than the whole file.
local refreshBody
do
    local s = src:find("panel.RefreshDependentEnabled = function()", 1, true)
    check(s ~= nil, "RefreshDependentEnabled is still where the panel declares it")
    if s then
        local e = src:find("\n    end\n", s, true)
        check(e ~= nil, "RefreshDependentEnabled body is closed at panel indent")
        refreshBody = code(src:sub(s, e or #src))
    end
end

if refreshBody then
    check(refreshBody:find("defensiveIconEnabled", 1, true) == nil,
        "the panel refresh reads no live profile setting (defensiveIconEnabled)")
    check(refreshBody:find("testShowAuras", 1, true) ~= nil,
        "the aura sliders still gate on Test Mode's own Show Auras flag")
    check(refreshBody:find("showTargetedListCheck:SetEnabled", 1, true) ~= nil,
        "the Targeted List pair still greys in raid mode")
end

-- ...and nothing anywhere else in the panel greys the pair either.
local body = code(src)
check(body:find("showDefensivesCheck:SetEnabled", 1, true) == nil,
    "nothing disables the Defensives box")
check(body:find("defSlider:SetEnabled", 1, true) == nil,
    "nothing disables the Defensives count slider")
