local addonName, DF = ...

-- ============================================================
-- CLIENT FLAVOR
-- Which game DandersFrames is running in. Loaded FIRST (before Core\Config.lua)
-- so defaults, the spell database and profile code can all branch on it.
--
-- WoW Forever (Blizzard game type "camelot") is the 12.1 engine with vanilla to
-- Cataclysm content, and reports a 1.60+ interface number (16001). There is no
-- API that names the flavor (Enum.GameMode only has Standard / Plunderstorm /
-- WoWHack), so the interface range is the signal. Classic Era reports 115xx and
-- retail 12xxxx, so the ranges never meet.
--
-- Two separate questions, two flags: Forever is BOTH "Forever" and "the modern
-- engine". Every "is this 12.1+" check means the engine, so it must read
-- IS_MODERN_ENGINE — a bare `interface >= 120100` is false on Forever.
--
-- Fail-open: an unreadable interface number gives retail behaviour.
-- ============================================================

local iface = select(4, GetBuildInfo())
if type(iface) ~= "number" then iface = 0 end

DF.CLIENT_INTERFACE = iface
DF.IS_FOREVER       = iface >= 16000 and iface < 20000
DF.IS_MODERN_ENGINE = DF.IS_FOREVER or iface >= 120100 or iface == 0
DF.CLIENT_FLAVOR    = DF.IS_FOREVER and "forever" or "retail"
