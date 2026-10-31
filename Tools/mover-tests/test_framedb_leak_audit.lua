local NS = ...

-- ============================================================
-- DESIGNER PRESET RESOLUTION READS A STANDALONE FRAME'S OWN TABLE
-- Designer/Presets.lua ResolvePreset (behind DF:ResolveAuraDesigner and
-- DF:ResolveTextDesigner) picked the template name from DF:GetDB(FrameMode(frame)),
-- so a standalone frame with no override stamp drew the party template. It now
-- reads the frame's own table for standalone frames only; party, raid and pinned
-- frames keep the mode read (a pinned frame's dfDB may sit on the other mode).
-- ============================================================

local function slice(src, startPat)
    src = src:gsub("\r\n", "\n")
    local a = src:find(startPat)
    check(a ~= nil, "found " .. startPat)
    local b = a and src:find("\nend\n", a, true)
    return (a and b) and src:sub(a, b + 4) or ""
end

print("-- ResolvePreset: source")
local body = slice(df_file_source("Designer/Presets.lua"), "local function ResolvePreset%(")
check(body:find("frame.dfStandalone and DF:GetFrameDB%(frame%)"), "ResolvePreset: standalone reads GetFrameDB")
check(body:find("or DF:GetDB%(mode%)"), "ResolvePreset: other frames keep the mode read")
check(not body:find("local modeDB = DF:GetDB%(mode%)\n"), "ResolvePreset: no bare mode read left")

print("-- ResolvePreset: behaviour")
local chunk = "local DF, FrameMode, DefaultPresetNameForMode = ...\n"
    .. body .. "\nreturn ResolvePreset"
local loader, err = loadstring(chunk, "=ResolvePreset")
check(loader ~= nil, "ResolvePreset parses (" .. tostring(err) .. ")")
if loader then
    local partyDB = { auraDesignerPreset = "P", textDesignerPreset = "PT" }
    local raidDB = { auraDesignerPreset = "R", textDesignerPreset = "RT" }
    local DF = { DEFAULT_PRESET = "Party" }
    function DF:GetDB(mode) return mode == "raid" and raidDB or partyDB end
    function DF:GetFrameDB(f)
        if f and f.dfDB then return f.dfDB end
        return f and f.isRaidFrame and raidDB or partyDB
    end
    local function FrameMode(f) return (f and f.isRaidFrame) and "raid" or "party" end
    local function DefaultName(mode) return mode == "raid" and "Raid" or "Party" end
    local ResolvePreset = loader(DF, FrameMode, DefaultName)
    local lib = { P = "lib-P", R = "lib-R", PT = "lib-PT", S = "lib-S", Party = "lib-Party" }

    eq(ResolvePreset({}, lib, "auraDesignerPreset"), "lib-P", "party frame: party preset")
    eq(ResolvePreset({ isRaidFrame = true }, lib, "auraDesignerPreset"), "lib-R", "raid frame: raid preset")
    -- Pinned on raid with a party-based proxy: still the mode's answer, as before.
    local pinned = { isRaidFrame = true, dfDB = setmetatable({}, { __index = partyDB }) }
    eq(ResolvePreset(pinned, lib, "auraDesignerPreset"), "lib-R", "pinned frame: mode preset unchanged")
    local own = { dfStandalone = true, dfDB = { auraDesignerPreset = "S" } }
    eq(ResolvePreset(own, lib, "auraDesignerPreset"), "lib-S", "standalone: its own preset")
    eq(ResolvePreset({ dfStandalone = true, dfDB = {} }, lib, "textDesignerPreset"), "lib-Party",
       "standalone with no key: library default, not party's choice")
    own.dfAuraPresetOverride = "R"
    eq(ResolvePreset(own, lib, "auraDesignerPreset"), "lib-R", "override stamp still wins")
end
