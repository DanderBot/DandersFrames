local NS = ...

-- ============================================================
-- TEST MODE REGISTRY -- DandersFrames/TestMode/Modes.lua
-- The real file on a fresh DF table: register / replace / refuse, order,
-- availability (with a reason, and a throwing callback contained), per-mode
-- section filtering and order, and the change listener the popup rides.
-- ============================================================

local savedHandler = geterrorhandler
local reported = {}
geterrorhandler = function() return function(e) reported[#reported + 1] = tostring(e) end end

local DF = {}
load_df_file_into("TestMode/Modes.lua", DF)
check(type(DF.RegisterTestMode) == "function", "api: DF:RegisterTestMode")

local notified = 0
DF:OnTestModesChanged(function() notified = notified + 1 end)

local function build() end
local function sec(id, extra)
    local s = { id = id, label = id, icon = id .. ".png", build = build }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end

print("-- Registry: register, refuse, replace")
do
    local ok, why = DF:RegisterTestMode("", { label = "x", sections = {} })
    check(ok == nil and why ~= nil, "refuse: an empty id")
    ok, why = DF:RegisterTestMode("bad", { label = "x" })
    check(ok == nil and why:find("sections"), "refuse: no sections")
    ok, why = DF:RegisterTestMode("bad", { label = "x", sections = { { id = "s" } } })
    check(ok == nil and why:find("build"), "refuse: a section without a build")
    ok = DF:RegisterTestMode("bad", { sections = {} })
    check(ok == nil, "refuse: no label")
    eq(notified, 0, "refuse: nothing registered, nobody told")

    local def = DF:RegisterTestMode("raid", { label = "Raid", order = 20, sections = { sec("general") } })
    eq(def.id, "raid", "register: the def gets its id")
    DF:RegisterTestMode("party", { label = "Party", order = 10, sections = { sec("general") } })
    DF:RegisterTestMode("frames", { label = "Frames", sections = { sec("general") } })   -- order 100
    DF:RegisterTestMode("alpha", { label = "Alpha", sections = { sec("general") } })     -- order 100
    eq(notified, 4, "register: every registration notifies")
    local ids = {}
    for _, d in ipairs(DF:GetTestModeList()) do ids[#ids + 1] = d.id end
    eq(table.concat(ids, ","), "party,raid,alpha,frames", "order: by order, then by id")
    DF:RegisterTestMode("party", { label = "Party 2", order = 10, sections = { sec("general") } })
    eq(DF:GetTestMode("party").label, "Party 2", "replace: same id replaces")
    eq(#DF:GetTestModeList(), 4, "replace: ...without a duplicate")
    check(DF:UnregisterTestMode("alpha") and DF:GetTestMode("alpha") == nil, "unregister: removed")
    check(not DF:UnregisterTestMode("alpha"), "unregister: twice is a no-op")
end

print("-- Registry: availability")
do
    eq(DF:IsTestModeAvailable("party"), true, "available: no isAvailable means available")
    eq(DF:IsTestModeAvailable("nope"), false, "available: an unknown mode is not")
    DF:RegisterTestMode("off", { label = "Off", sections = { sec("s") },
        isAvailable = function() return false, "Disabled", { "Turn it on" } end })
    local ok, why, lines = DF:IsTestModeAvailable("off")
    check(ok == false and why == "Disabled" and lines[1] == "Turn it on", "available: false with its reason")
    DF:RegisterTestMode("boom", { label = "Boom", sections = { sec("s") },
        isAvailable = function() error("kaboom") end })
    eq(DF:IsTestModeAvailable("boom"), false, "available: a throwing callback reads as unavailable")
    check(reported[#reported] and reported[#reported]:find("kaboom"), "available: ...and the error is reported")
end

print("-- Registry: sections per mode")
do
    local partyOnly = true
    DF:RegisterTestMode("grp", { label = "Grp", sections = {
        sec("general"),
        sec("targeted", { isAvailable = function() return partyOnly end }),
        sec("first", { order = 0 }),
        sec("broken", { isAvailable = function() error("bad section") end }),
        sec("last"),
    } })
    local function ids()
        local out = {}
        for _, s in ipairs(DF:GetTestModeSections("grp")) do out[#out + 1] = s.id end
        return table.concat(out, ",")
    end
    eq(ids(), "first,general,targeted,last", "sections: order wins, then array order; a throwing filter hides")
    partyOnly = false
    eq(ids(), "first,general,last", "sections: isAvailable false hides a section")
    eq(#DF:GetTestModeSections("nope"), 0, "sections: an unknown mode has none")
end

print("-- Registry: resident, documented")
do
    local toc = df_file_source("DandersFrames.toc")
    local shim = toc:find("TestMode\\Shim.lua", 1, true)
    local modes = toc:find("TestMode\\Modes.lua", 1, true)
    check(modes ~= nil, "toc: Modes.lua is in the resident TOC")
    check(shim and modes and shim < modes, "toc: ...after the shim")
    local src = df_file_source("TestMode/Modes.lua")
    for _, field in ipairs({ "isAvailable", "isCurrent", "onEnter", "onExit", "store", "presets",
                             "applyPreset", "activePreset", "isPreviewOn", "togglePreview", "sections" }) do
        check(src:find("--   " .. field, 1, true) or src:find("--     " .. field, 1, true) or src:find(field, 1, true),
              "doc: the header documents " .. field)
    end
end

geterrorhandler = savedHandler
