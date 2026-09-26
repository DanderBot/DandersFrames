-- ============================================================
-- CLIENT FLAVOR (DandersFrames/Core/ClientFlavor.lua)
-- Retail vs WoW Forever, from the interface number. Loaded REAL, once per
-- interface value, into a fresh namespace each time.
-- ============================================================

local function flavorFor(iface)
    local prev = GetBuildInfo
    GetBuildInfo = function() return "x", "1", "Sep 1 2026", iface end
    local t = {}
    load_df_file_into("Core/ClientFlavor.lua", t)
    GetBuildInfo = prev
    return t
end

do  -- WoW Forever (game type "camelot"): Forever AND the 12.1 engine
    local t = flavorFor(16001)
    eq(t.IS_FOREVER, true, "16001 is Forever")
    eq(t.IS_MODERN_ENGINE, true, "16001 runs the 12.1 engine")
    eq(t.CLIENT_FLAVOR, "forever", "16001 flavor string")
    eq(t.CLIENT_INTERFACE, 16001, "interface is recorded")
end

do  -- Forever range edges
    eq(flavorFor(16000).IS_FOREVER, true, "16000 is the bottom of the Forever range")
    eq(flavorFor(19999).IS_FOREVER, true, "19999 is still Forever")
    eq(flavorFor(20000).IS_FOREVER, false, "20000 is past the Forever range")
end

do  -- Classic Era: neither Forever nor the modern engine
    local t = flavorFor(11507)
    eq(t.IS_FOREVER, false, "11507 is not Forever")
    eq(t.IS_MODERN_ENGINE, false, "11507 is not the 12.1 engine")
    eq(t.CLIENT_FLAVOR, "retail", "non-Forever flavor string")
end

do  -- retail 12.1 and later
    for _, iface in ipairs({ 120100, 120105, 130000 }) do
        local t = flavorFor(iface)
        eq(t.IS_FOREVER, false, iface .. " is not Forever")
        eq(t.IS_MODERN_ENGINE, true, iface .. " is the 12.1 engine")
    end
    eq(flavorFor(120007).IS_MODERN_ENGINE, false, "12.0.7 predates the 12.1 engine")
end

do  -- fail-open: an unreadable interface number behaves as retail
    local t = flavorFor("not a number")
    eq(t.IS_FOREVER, false, "unreadable interface is not Forever")
    eq(t.IS_MODERN_ENGINE, true, "unreadable interface keeps retail (modern) behaviour")
    eq(t.CLIENT_FLAVOR, "retail", "unreadable interface flavor string")
end
