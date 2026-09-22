local NS = ...

-- ============================================================
-- SETTINGS-PANEL LEAKS: THE SYNC, THE WINDOW OPEN AND THE REBUILDING CALL SITES
-- ------------------------------------------------------------
-- WoW never frees a frame, so every settings page rebuild parks the previous
-- page's widgets in GUI._trashFrame for the rest of the session (~800 KB a
-- page, measured in game 2026-09-18). test_mode_builds.lua pins the retained
-- builds themselves and test_index_reuse.lua the search index; this file pins
-- the paths that used to throw a valid build away or rebuild on top of one:
--   1. the Party/Raid Sync REPLACED the other mode's tables, so every switch
--      invalidated (and rebuilt) every synced page -- it now copies INTO them
--      (BEHAVIOURAL: the real Core/Profile.lua copy under the real Panel.lua
--      wrapper);
--   2. opening the window forced a rebuild of the page on screen
--      (BEHAVIOURAL: the real DF:ToggleGUI, cut out of GUI/Controls.lua);
--   3. the call sites converted from a rebuild to a state pass / value sweep /
--      the cache (source shape -- the pages cannot be built headless).
-- ============================================================

local panel    = options_file_source("GUI/Panel.lua")
local profile  = df_file_source("Core/Profile.lua")
local controls = options_file_source("GUI/Controls.lua")

local function cut(src, startNeedle, stopNeedle, label)
    local s = src:find(startNeedle, 1, true)
    local e = s and src:find(stopNeedle, s + #startNeedle, true)
    check(s ~= nil and e ~= nil, "leaks: " .. label .. " can be cut out of its file")
    if not (s and e) then return nil end
    return src:sub(s, e - 1)
end

local function deepEq(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if not deepEq(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

-- ============================================================
-- 1. THE SYNC KEEPS TABLES
-- ============================================================
local copySrc = table.concat({
    cut(profile, "function DF:DeepCopy(src, seen)", "\n-- ============", "DF:DeepCopy") or "",
    cut(profile, "function DF:SectionOwnsKey(prefixes, key)", "\n-- Copies matching settings", "DF:SectionOwnsKey") or "",
    cut(profile, "function DF:CopySectionSettingsRaw(prefixes, srcMode)", "\n-- Copies a specific section", "DF:CopySectionSettingsRaw") or "",
}, "\n")
local wrapAt = panel:find("\ndo\n    local function ReplaceInPlace(dst, src, seen)", 1, true)
check(wrapAt ~= nil, "leaks: GUI/Panel.lua carries THE SYNC KEEPS TABLES")
local wrapSrc = wrapAt and panel:sub(wrapAt)

local function NewSyncHost()
    local DF = {}
    local fn = assert(loadstring("local DF = ...\n" .. copySrc, "@Profile.lua:copy"))
    fn(DF)
    DF.SectionRegistry = { bars_health = { "healthColor" }, other_page = { "other" } }
    DF.db = {
        party = {
            healthColorStops = { { p = 0, c = { r = 1, g = 0, b = 0 } }, { p = 1, c = { r = 0, g = 1, b = 0 } } },
            healthColorLow   = 5,
            otherThing       = { x = 1 },
        },
        raid = {
            healthColorStops = { { p = 0, c = { r = 0, g = 0, b = 1 } } },
            healthColorLow   = 3,
            healthColorGone  = { y = 1 },
            otherThing       = { x = 2 },
        },
    }
    return DF
end

do
    -- Without the wrapper: the copy REPLACES the table -- the bug's cause, pinned
    -- so the wrapper's reason cannot silently disappear.
    local DF = NewSyncHost()
    local before = DF.db.raid.healthColorStops
    DF:CopySectionSettingsRaw(DF.SectionRegistry.bars_health, "party")
    check(DF.db.raid.healthColorStops ~= before,
          "sync: the resident copy on its own gives the destination a NEW table")
end

if wrapSrc then
    local DF = NewSyncHost()
    local GUI = {}
    local wrap, err = loadstring("local DF, GUI = ...\n" .. wrapSrc, "@Panel.lua:SyncKeepsTables")
    check(wrap ~= nil, "sync: the wrapper block compiles (" .. tostring(err) .. ")")
    if wrap then
        wrap(DF, GUI)
        local raid = DF.db.raid
        local stops, stop1, c1 = raid.healthColorStops, raid.healthColorStops[1], raid.healthColorStops[1].c
        local other = raid.otherThing

        DF:CopySectionSettingsRaw(DF.SectionRegistry.bars_health, "party")

        check(raid.healthColorStops == stops, "sync: the destination KEEPS its table -- a retained build stays bound")
        check(raid.healthColorStops[1] == stop1 and raid.healthColorStops[1].c == c1,
              "sync: ...and its nested tables, where they line up")
        check(deepEq(raid.healthColorStops, DF.db.party.healthColorStops),
              "sync: ...holding exactly the source's data (a stop added too)")
        check(raid.healthColorStops ~= DF.db.party.healthColorStops
              and raid.healthColorStops[2] ~= DF.db.party.healthColorStops[2],
              "sync: ...and sharing nothing with the source")
        eq(raid.healthColorLow, 5, "sync: scalars are copied as before")
        eq(raid.healthColorGone and raid.healthColorGone.y, 1,
           "sync: a destination key the source lacks is left alone, as before")
        check(raid.otherThing == other and raid.otherThing.x == 2, "sync: a key the section does not own is untouched")

        -- The auto-profile proxy: writes land in the real table.
        local real = raid
        local proxy = setmetatable({}, {
            __realTable = real,
            __index = function(_, k) return real[k] end,
            __newindex = function(_, k, v) real[k] = v end,
        })
        DF.db.raid = proxy
        DF.db.party.healthColorStops[1].c.r = 0.5
        DF:CopySectionSettingsRaw(DF.SectionRegistry.bars_health, "party")
        check(real.healthColorStops == stops and real.healthColorStops[1].c == c1,
              "sync: through the raid proxy the real table keeps its identity too")
        eq(real.healthColorStops[1].c.r, 0.5, "sync: ...and takes the new value")

        -- A cyclic payload (DeepCopy supports them) must not recurse forever.
        local cyc = {}
        cyc.self = cyc
        DF.db.party.healthColorCycle = cyc
        real.healthColorCycle = { self = {} }
        local ok = pcall(function() DF:CopySectionSettingsRaw(DF.SectionRegistry.bars_health, "party") end)
        check(ok, "sync: a cyclic table is copied without running away")
    end
end

-- ============================================================
-- 2. OPENING THE WINDOW GOES THROUGH THE CACHE
-- ============================================================
do
    local body = cut(controls, "function DF:ToggleGUI()", "\n\n\n-- ====", "DF:ToggleGUI")
    if body then
        local fn, err = loadstring("local DF, GUI = ...\n" .. body, "@Controls.lua:ToggleGUI")
        check(fn ~= nil, "open: DF:ToggleGUI compiles on its own (" .. tostring(err) .. ")")
        if fn then
            local calls = { cached = 0, forced = 0 }
            local shown = false
            local DF = { VERSION = "x" }
            DF.GUIFrame = { IsShown = function() return shown end, Show = function() shown = true end,
                            Hide = function() shown = false end }
            local GUI = {
                SetAccent = function() end,
                GetThemeColorFor = function() return {} end,
                RefreshCurrentPage = function() calls.forced = calls.forced + 1 end,
                RefreshCurrentPageCached = function() calls.cached = calls.cached + 1 end,
            }
            local savedIsInRaid, savedSV = IsInRaid, DandersFramesDB_v2
            IsInRaid = function() return false end
            DandersFramesDB_v2 = { lastSeenVersion = "x" }
            fn(DF, GUI)
            for _ = 1, 10 do
                DF:ToggleGUI()          -- open
                DF:ToggleGUI()          -- close
            end
            eq(calls.forced, 0, "open: ten opens of the window rebuild nothing")
            eq(calls.cached, 10, "open: ...each goes through the page cache")
            IsInRaid, DandersFramesDB_v2 = savedIsInRaid, savedSV
        end
    end
end

-- What makes that safe, pinned where it lives.
check(panel:find("GUI.RefreshCurrentPageCached = function()\n        GUI._refreshCurrentPageCached = true\n        GUI:RefreshCurrentPage()\n        GUI._refreshCurrentPageCached = nil", 1, true) ~= nil,
      "open: the cached refresh goes through GUI:RefreshCurrentPage by name (the Auto Layouts wrapper)")
check(panel:find("AutoProfilesUI:ExitEditing(true)  -- Skip UI updates since GUI is closing\n"
    .. "            -- ...which also skips its InvalidateAllPages.", 1, true) ~= nil
    and panel:find("            if GUI.InvalidateAllPages then GUI:InvalidateAllPages() end\n        end\n        -- Popout rows stand OUTSIDE", 1, true) ~= nil,
      "open: closing the window mid auto-layout edit invalidates the builds made while editing")

-- ============================================================
-- 3. THE CONVERTED CALL SITES
-- ============================================================
local options = options_file_source("GUI/Pages/Options.lua")
local modules = options_file_source("GUI/Pages/Modules.lua")
local frames  = options_file_source("GUI/Pages/Frames.lua")
local auras   = options_file_source("GUI/Pages/Auras.lua")
local api     = df_file_source("Core/API.lua")

local function count(src, needle)
    local n, i = 0, 1
    while true do
        local a = src:find(needle, i, true)
        if not a then return n end
        n, i = n + 1, a + #needle
    end
end

-- After a FullProfileRefresh: the second rebuild became a cache hit.
local AFTER = "GUI.RefreshCurrentPageAfterFullRefresh()"
for _, site in ipairs({
    { options, "DF:CopySectionSettings(prefixes, mode)\n", "the Copy section button" },
    { options, "DF:ResetSectionSettings(prefixes, mode)\n", "the Reset Page button" },
    { modules, "DF:SetProfile(p) \n", "the profile list" },
    { modules, "DF:SetProfile(text) \n", "Create Empty" },
    { modules, "if DF:DuplicateProfile(text) then\n", "Duplicate Current" },
    { modules, "DF:ResetFullProfile()\n", "Reset Profile to Defaults" },
    { modules, "DF:CopyProfile(src, dest)\n", "Copy Party/Raid" },
    { panel,   "DF:SetProfile(name)\n", "the title-bar profile chip" },
}) do
    local src, needle, label = site[1], site[2], site[3]
    local a = src:find(needle, 1, true)
    check(a ~= nil, "after-full-refresh: " .. label .. " is found")
    while a do
        local tail = src:sub(a, a + 400)
        local afterAt = tail:find(AFTER, 1, true)
        local forcedAt = tail:find("GUI:RefreshCurrentPage()", 1, true)
        check(afterAt ~= nil and (not forcedAt or forcedAt > afterAt),
              "after-full-refresh: " .. label .. " no longer rebuilds on top of FullProfileRefresh's rebuild")
        a = src:find(needle, a + 1, true)
    end
end
eq(count(options, "DF:CopySectionSettings(prefixes, mode)\n"), 2, "after-full-refresh: Copy AND Sync are both covered")
check(panel:find("GUI.RefreshCurrentPageAfterFullRefresh = function()\n        if InCombatLockdown() then\n            GUI:RefreshCurrentPage()", 1, true) ~= nil,
      "after-full-refresh: ...except in combat, where FullProfileRefresh returned early and the rebuild is the refresh")
check(modules:find("if ok and applied == true and GUI.RefreshCurrentPageAfterFullRefresh then", 1, true) ~= nil,
      "after-full-refresh: an import only skips the rebuild when it completed (a failed one keeps it)")
check(api:find("DF.GUI.RefreshCurrentPageAfterFullRefresh()", 1, true) ~= nil,
      "after-full-refresh: the public import API too")

-- Gates: a state pass, not a rebuild.
check(options:find("                refreshStates = function() GUI.RelayoutCurrentPage() end,\n                shadowDisableWhen = BorderOff,", 1, true) ~= nil,
      "state pass: the Frame page's classic border controls re-lay, not rebuild")
local pinned = frames:match("local borderCheck = CreateRefreshableCheckbox(.-)layoutGroup:AddWidget%(borderCheck")
check(pinned ~= nil, "state pass: the pinned Override Border toggle is found")
if pinned then
    local toggle = pinned:match("^(.-)%-%- Reset%-to%-inherited icon")
    check(toggle and toggle:find("GUI.RelayoutCurrentPage()", 1, true) ~= nil
          and not toggle:find("GUI:RefreshCurrentPage()", 1, true),
          "state pass: ...and re-lays the page instead of rebuilding it")
end
check(frames:find("            refreshStates = function() GUI.RelayoutCurrentPage() end,\n            hideWhen   = function() return not (GetCurrentSet() and GetCurrentSet().borderOverride) end,", 1, true) ~= nil,
      "state pass: the pinned border controls re-lay, not rebuild")

-- Palette resets: the value sweep, not a rebuild.
local repaint = auras:match("local function RepaintSwatches%(tools2%)(.-)\n        end")
check(repaint and repaint:find("tools2.group:RefreshChildValues()", 1, true) ~= nil,
      "value sweep: classic's palette reset repaints its box instead of rebuilding the page")
check(auras:find("                elseif group.RefreshChildValues then\n                    group:RefreshChildValues()\n                    if tools then tools.ReflowMounted(true) end\n                elseif pageResource and pageResource.Refresh then", 1, true) ~= nil,
      "value sweep: ...and the power colours' reset too (a modern card also repaints any pinned copy)")
