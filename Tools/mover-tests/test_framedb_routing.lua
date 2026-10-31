local NS = ...

-- ============================================================
-- PER-FRAME SETTINGS READS GO THROUGH DF:GetFrameDB
-- Frames/Colors.lua (SetBarValue), Frames/Core.lua (SetHealthBarValue),
-- Frames/Bars.lua (RefreshAbsorbBarVisibility), Features/Dispel.lua (the
-- health-tracking overlay's smoothBars, the overlay level, the edge strips).
-- ------------------------------------------------------------
-- These five read `isRaidFrame ? raid : party` directly, which skipped a frame's
-- own table (pinned sets, standalone frames). GetFrameDB returns the same table
-- for an ordinary party or raid frame, so their behaviour there is unchanged.
-- ============================================================

local function body(src, startPat, len)
    src = src:gsub("\r\n", "\n")
    local a = src:find(startPat)
    check(a ~= nil, "found " .. startPat)
    return a and src:sub(a, a + (len or 1200)) or ""
end

print("-- Each site reads GetFrameDB")
local colors = body(df_file_source("Frames/Colors.lua"), "local function SetBarValue%(")
check(colors:find("DF:GetFrameDB%(frame%)"), "Colors SetBarValue: GetFrameDB")
check(not colors:find("isRaidFrame", 1, true), "Colors SetBarValue: no isRaidFrame branch")

local core = body(df_file_source("Frames/Core.lua"), "local function SetHealthBarValue%(", 700)
check(core:find("DF:GetFrameDB%(frame%)"), "Core SetHealthBarValue: GetFrameDB")
check(not core:find("isRaidFrame", 1, true), "Core SetHealthBarValue: no isRaidFrame branch")

local bars = body(df_file_source("Frames/Bars.lua"), "function DF:RefreshAbsorbBarVisibility%(", 600)
check(bars:find("DF:GetFrameDB%(frame%)"), "Bars RefreshAbsorbBarVisibility: GetFrameDB")
check(not bars:find("isRaidFrame", 1, true), "Bars RefreshAbsorbBarVisibility: no isRaidFrame branch")

local dsrc = df_file_source("Features/Dispel.lua")
local _, n = dsrc:gsub("isRaidFrame and DF%.GetRaidDB", "")
eq(n, 0, "Dispel: no `isRaidFrame and GetRaidDB` selection left")
check(not dsrc:find("if frame.isRaidFrame then\n%s*db = DF.GetRaidDB", 1), "Dispel: no isRaidFrame db branch left")
check(dsrc:find("local dispelDB = DF:GetFrameDB%(frame%)"), "Dispel overlay level: GetFrameDB")
check(dsrc:find("ResolveDispelGradientLevel%(frame:GetFrameLevel%(%), DF:GetFrameDB%(frame%)%)"),
      "Dispel edge strips: GetFrameDB")
check(dsrc:find("local db = DF.GetFrameDB and DF:GetFrameDB%(frame%)\n%s*local smoothEnabled"),
      "Dispel health-tracking overlay: GetFrameDB")

-- ---- behaviour: the same table for party/raid, the frame's own when set ----
print("-- SetBarValue reads smoothBars from the frame's table")
local src = df_file_source("Frames/Colors.lua"):gsub("\r\n", "\n")
local a = src:find("local function SetBarValue%(")
local b = a and src:find("\nend\n", a, true)
local chunk = (a and b) and (src:sub(a, b + 4) .. "\nreturn SetBarValue") or "return nil"
local partyDB, raidDB = { smoothBars = false }, { smoothBars = true }
local DF = {}
function DF:GetDB() return partyDB end
function DF:GetRaidDB() return raidDB end
function DF:GetFrameDB(f)
    if f and f.dfDB then return f.dfDB end
    if f and f.isRaidFrame then return raidDB end
    return partyDB
end
local f, err = loadstring(chunk, "=SetBarValue")
check(f ~= nil, "SetBarValue parses (" .. tostring(err) .. ")")
if f then
    setfenv(f, setmetatable({ DF = DF }, { __index = _G }))
    local SetBarValue = f()
    local calls = {}
    DF.SetBarValueSmoothed = function(_, _, smooth) calls[#calls + 1] = smooth and true or false end
    local bar = { SetValue = function() end }
    SetBarValue(bar, 1, {})
    SetBarValue(bar, 1, { isRaidFrame = true })
    SetBarValue(bar, 1, { dfDB = { smoothBars = true } })
    SetBarValue(bar, 1, nil)
    local shown = {}
    for i = 1, 4 do shown[i] = tostring(calls[i]) end
    check(#calls == 4, "SetBarValue: wrote four values")
    check(calls[1] ~= calls[2], "party and raid frames still read their own mode (" .. table.concat(shown, ",") .. ")")
    eq(calls[2], calls[3], "a frame's own table is read (smooth on, like raid)")
    eq(calls[1], calls[4], "no frame: the party table, as before")
end
