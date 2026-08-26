local NS = ...

-- ============================================================
-- CLASSIC SETTINGS LAYOUT -- DandersFrames/Core/Config.lua
-- ------------------------------------------------------------
-- The transition toggle that falls the settings panel back to the old inline
-- rendering. Two things are worth pinning down headless, because neither is
-- visible in game until it has already gone wrong:
--
--   1. THE NIL-SV ANSWER. The accessor reads DandersFramesDB_v2 at ACCESS time
--      precisely because this file loads before the SavedVariable exists. With
--      no SV at all it must answer false (= the new layout), not error and not
--      accidentally latch classic for the rest of the session.
--   2. THE SETTER CREATES THE SV. A write can land before the table exists, and
--      it has to make one rather than throw -- the same guard the colour-picker
--      store carries.
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME ACROSS EVERY TEST FILE, and Config.lua
-- writes the `DandersFrames` global on load. Every global this file touches is
-- saved and restored at the end.
-- ============================================================

local savedCreateFrame     = CreateFrame
local savedGetLocale       = GetLocale
local savedDandersFrames   = DandersFrames
local savedDB              = DandersFramesDB_v2

-- Config.lua's file scope builds an event frame and a font-measuring frame, and
-- reads the client locale to pick its alphabet. Neither result matters here.
CreateFrame = function() return FakeUIFrame() end
GetLocale   = function() return "enUS" end

local DF = {}
load_df_file_into("Core/Config.lua", DF)

check(type(DF.IsClassicSettingsLayout) == "function", "IsClassicSettingsLayout installed")
check(type(DF.SetClassicSettingsLayout) == "function", "SetClassicSettingsLayout installed")

-- ---- no SavedVariable yet ------------------------------------------
do
    DandersFramesDB_v2 = nil
    eq(DF:IsClassicSettingsLayout(), false, "nil SV reads as the new layout")
end

-- ---- an SV with nothing set --------------------------------------
do
    DandersFramesDB_v2 = {}
    eq(DF:IsClassicSettingsLayout(), false, "absent key reads as the new layout")
end

-- ---- the two real values -------------------------------------------
do
    DandersFramesDB_v2 = { classicSettings = true }
    eq(DF:IsClassicSettingsLayout(), true, "classicSettings = true reads as classic")

    DandersFramesDB_v2 = { classicSettings = false }
    eq(DF:IsClassicSettingsLayout(), false, "classicSettings = false reads as the new layout")
end

-- ---- the setter round-trips, and stores a real boolean ---------------
do
    DandersFramesDB_v2 = {}
    DF:SetClassicSettingsLayout(true)
    eq(DandersFramesDB_v2.classicSettings, true, "setter writes true to the SV root")
    eq(DF:IsClassicSettingsLayout(), true, "setter is visible to the accessor")

    DF:SetClassicSettingsLayout(false)
    eq(DandersFramesDB_v2.classicSettings, false, "setter writes false to the SV root")
    eq(DF:IsClassicSettingsLayout(), false, "cleared setting reads as the new layout")

    -- Truthy-but-not-boolean must not reach SavedVariables verbatim.
    DF:SetClassicSettingsLayout("yes")
    eq(DandersFramesDB_v2.classicSettings, true, "setter normalises a truthy value to true")
    DF:SetClassicSettingsLayout(nil)
    eq(DandersFramesDB_v2.classicSettings, false, "setter normalises nil to false")
end

-- ---- a write before the SavedVariable exists creates it --------------
do
    DandersFramesDB_v2 = nil
    DF:SetClassicSettingsLayout(true)
    check(type(DandersFramesDB_v2) == "table", "setter creates the SV table when it is missing")
    eq(DF:IsClassicSettingsLayout(), true, "value survives the table creation")
end

-- ---- the pref is NOT profile state ----------------------------------
-- It hangs off the SV ROOT, beside .profiles rather than inside one, so a
-- profile switch cannot change how the panel draws underfoot.
do
    DandersFramesDB_v2 = { profiles = { Default = {} }, global = {} }
    DF:SetClassicSettingsLayout(true)
    eq(DandersFramesDB_v2.profiles.Default.classicSettings, nil, "not written into a profile")
    eq(DandersFramesDB_v2.global.classicSettings, nil, "not written into the global block")
    eq(DandersFramesDB_v2.classicSettings, true, "written at the SV root")
end

CreateFrame        = savedCreateFrame
GetLocale          = savedGetLocale
DandersFrames      = savedDandersFrames
DandersFramesDB_v2 = savedDB
