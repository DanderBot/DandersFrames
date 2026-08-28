local NS = ...

-- ============================================================
-- GROUP ACTIONS -- DandersFrames_Options/GUI/GroupActions.lua
-- ------------------------------------------------------------
-- The WRITE half of the popout footer: "put every setting behind this row back
-- to the value the addon ships", and the press-and-hold preview that shows the
-- user what that would look like before they commit to it.
--
-- Four things are pinned here, and all four fail SILENTLY in game -- a reset
-- that looks like it worked, a layout that quietly grew an edit nobody made:
--
--   1. EVERY WRITE GOES THROUGH THE BRACKET. interceptWrite first (true = an
--      auto layout redirected it to the baseline, so the plain write and the
--      notification must BOTH be skipped), onSettingWritten after (which is what
--      records the change as a layout override edit while a layout is being
--      edited). Half a bracket is how a reset ends up half-recorded.
--   2. ☠ A TABLE DEFAULT IS DEEP-COPIED BEFORE IT IS WRITTEN. GetDefault hands
--      back the LIVE reference out of DF.PartyDefaults / DF.RaidDefaults.
--      Written raw, the profile and the shipped default become the same table --
--      and the next edit to that setting rewrites the DEFAULT for the rest of
--      the session, after which every "is this modified" answer agrees with the
--      damage.
--   3. A KEY ALREADY AT ITS DEFAULT IS NOT WRITTEN. A write is an EVENT here, so
--      writing one would record an edit the user never made.
--   4. THE HOLD ROUND-TRIPS. What BeginHold took, EndHold puts back -- equal by
--      value, and never as a reference into the defaults table.
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME. Config.lua needs CreateFrame / GetLocale
-- and claims the global `DandersFrames`; GroupActions.lua reads that global at
-- LOAD time (it is a companion file -- its `...` is the companion's own table,
-- not the parent's), so the global is set deliberately across that load and
-- restored afterwards.
-- ============================================================

local savedCreateFrame   = CreateFrame
local savedGetLocale     = GetLocale
local savedDandersFrames = DandersFrames

-- The REAL engine on the REAL shipped defaults, exactly as test_defaults_diff
-- loads it -- these actions are only correct against the defaults that actually
-- ship, and a fixture would agree with itself.
local DF
do
    DF = {}
    CreateFrame = function() return FakeUIFrame() end
    GetLocale = function() return "enUS" end
    load_df_file_into("Core/Config.lua", DF)
    CreateFrame, GetLocale = savedCreateFrame, savedGetLocale
    load_df_file_into("Core/Defaults.lua", DF)
    -- ⚠ The companion file takes its DF off the GLOBAL, so this assignment IS
    -- the wiring. Restored at the foot of the file.
    DandersFrames = DF
    load_options_file_into("GUI/GroupActions.lua", {})
    DandersFrames = savedDandersFrames
end

local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = deepcopy(x) end
    return t
end

local function deepsame(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if not deepsame(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

-- A profile that is a byte-for-byte fresh install, deep-copied so nothing shares
-- a reference with the defaults tables.
local function freshProfile()
    local party, raid = {}, {}
    for k, v in pairs(DF.PartyDefaults) do party[k] = deepcopy(v) end
    for k, v in pairs(DF.RaidDefaults)  do raid[k]  = deepcopy(v) end
    DF.db = { party = party, raid = raid }
    DF._realRaidDB = nil
    return party, raid
end

-- The bracket, as a recorder. `redirect` is the set of keys interceptWrite
-- claims -- i.e. the keys a running auto layout would send to the baseline
-- instead of to the live table.
local function fakeHost(redirect)
    local h = { intercepted = {}, written = {} }
    h.hooks = {
        interceptWrite = function(db, key, value)
            h.intercepted[#h.intercepted + 1] = { db = db, key = key, value = value }
            return redirect and redirect[key] and true or false
        end,
        onSettingWritten = function(db, key, value)
            h.written[#h.written + 1] = { db = db, key = key, value = value }
        end,
    }
    function h:Call(name, ...)
        local fn = self.hooks[name]
        if not fn then return nil end
        return fn(...)
    end
    -- The LAST announcement for a key, not the first: a hold announces the same
    -- key twice (defaults out, the user's value back), and the interesting one
    -- is always the most recent.
    function h:Written(key)
        local found
        for _, w in ipairs(self.written) do if w.key == key then found = w end end
        return found
    end
    return h
end

local GA = DF.GroupActions

-- ============================================================
-- THE MODULE LOADED AT ALL
-- ============================================================
do
    check(type(GA) == "table", "GroupActions: the module loaded and installed DF.GroupActions")
    check(type(GA.ResetKeys) == "function", "GroupActions: ResetKeys is there")
    check(type(GA.BeginHold) == "function", "GroupActions: BeginHold is there")
    check(type(GA.EndHold) == "function", "GroupActions: EndHold is there")
end

-- ============================================================
-- 1. RESET -- WHAT CHANGES, WHAT DOES NOT, AND WHAT IS RECORDED
-- ============================================================
do
    local party = freshProfile()
    local host = fakeHost()

    -- Two keys off their defaults, one left alone.
    local defSize  = DF.PartyDefaults.frameBorderSize
    local defStyle = DF.PartyDefaults.frameBorderStyle
    party.frameBorderSize  = defSize + 3
    party.frameBorderStyle = (defStyle == "SOLID") and "GRADIENT" or "SOLID"

    local keys = { "frameBorderSize", "frameBorderStyle", "frameShowBorder" }
    local changes = GA:ResetKeys(host, party, keys, "party")

    eq(party.frameBorderSize, defSize, "reset: the modified number is back to the shipped default")
    eq(party.frameBorderStyle, defStyle, "reset: ...and so is the modified string")

    -- The changes table: undo-toast shaped, and only the keys that MOVED.
    check(changes.frameBorderSize ~= nil, "reset: the changed key is in the changes table")
    eq(changes.frameBorderSize.old, defSize + 3, "reset: ...with what was there as `old`")
    eq(changes.frameBorderSize.new, defSize, "reset: ...and the default as `new`")
    check(changes.frameShowBorder == nil,
        "reset: a key already at its default is NOT in the changes table")

    -- Rule 3, and it is about the RECORD, not about speed: a write is an event
    -- the auto-layout recorder is listening to, so writing an unchanged key
    -- would put it into a layout's override set untouched.
    check(host:Written("frameBorderSize") ~= nil, "reset: the changed key was announced")
    check(host:Written("frameShowBorder") == nil,
        "reset: ☠ the already-default key was never written, so nothing was announced for it")
    local sawIntercept = false
    for _, i in ipairs(host.intercepted) do
        if i.key == "frameShowBorder" then sawIntercept = true end
    end
    check(not sawIntercept, "reset: ...and it never even reached the bracket")

    -- The bracket ran in the right order for the keys that did move: asked
    -- first, announced after, with the value that landed.
    eq(#host.intercepted, 2, "reset: the bracket was asked once per changed key")
    eq(#host.written, 2, "reset: ...and announced once per changed key")
    eq(host:Written("frameBorderStyle").value, defStyle,
       "reset: the announcement carries the value that was written")
end

-- ============================================================
-- 2. THE REDIRECT -- A RUNNING AUTO LAYOUT OWNS THE WRITE
-- interceptWrite answering true means the value went to the stored baseline and
-- the live table did NOT change. The plain write must not happen, the
-- announcement must not happen, and the key must not be reported as changed --
-- reporting it would offer an undo of something this code never did.
-- ============================================================
do
    local party = freshProfile()
    local defSize = DF.PartyDefaults.frameBorderSize
    party.frameBorderSize = defSize + 5
    party.frameBorderStyle = "GRADIENT"

    local host = fakeHost({ frameBorderSize = true })
    local changes = GA:ResetKeys(host, party, { "frameBorderSize", "frameBorderStyle" }, "party")

    eq(party.frameBorderSize, defSize + 5, "redirect: the live table is untouched for the claimed key")
    check(changes.frameBorderSize == nil, "redirect: ...and it is not reported as changed")
    check(host:Written("frameBorderSize") == nil,
        "redirect: ☠ no onSettingWritten for a write that was redirected")
    check(host:Written("frameBorderStyle") ~= nil,
        "redirect: ...while the key the layout did not claim went through normally")
    eq(party.frameBorderStyle, DF.PartyDefaults.frameBorderStyle,
       "redirect: ...and landed")
end

-- ============================================================
-- 3. ☠ TABLE DEFAULTS ARE COPIED, NEVER REFERENCED
-- The one that rewrites the shipped default for the rest of the session if it
-- is wrong, and answers "not modified" for ever after -- i.e. it hides itself.
-- ============================================================
do
    local party = freshProfile()
    local host = fakeHost()
    local defColor = DF.PartyDefaults.frameBorderColor
    check(type(defColor) == "table", "table default: frameBorderColor is a table (the case that matters)")

    party.frameBorderColor = { r = 1, g = 0, b = 0, a = 1 }
    GA:ResetKeys(host, party, { "frameBorderColor" }, "party")

    check(deepsame(party.frameBorderColor, defColor), "table default: the value is the default's")
    check(party.frameBorderColor ~= defColor,
        "table default: ☠ ...but it is a DIFFERENT TABLE -- the profile does not alias the shipped default")

    -- The proof of why: mutating the profile's copy must not move the default.
    local before = defColor.r
    party.frameBorderColor.r = (before == 0) and 1 or 0
    eq(DF.PartyDefaults.frameBorderColor.r, before,
       "table default: ...so editing the setting afterwards cannot rewrite what the addon ships")

    -- The announcement carries the copy, not the live reference either.
    local w = host:Written("frameBorderColor")
    check(w ~= nil and w.value ~= defColor,
        "table default: the announcement carries the copy too")
end

-- ============================================================
-- 4. THE MODE DECIDES WHICH DEFAULT
-- Party and raid ship different numbers for the same key (Config.lua generates
-- raid from party with overrides), so a reset that read the wrong table would
-- write a plausible number that is simply not this mode's.
-- ============================================================
do
    local _, raid = freshProfile()
    local host = fakeHost()
    eq(DF.PartyDefaults.defensiveIconSize, 26, "mode: party ships 26")
    eq(DF.RaidDefaults.defensiveIconSize, 24, "mode: raid overrides it to 24")

    raid.defensiveIconSize = 40
    GA:ResetKeys(host, raid, { "defensiveIconSize" }, "raid")
    eq(raid.defensiveIconSize, 24, "mode: a raid reset lands on the RAID default")

    -- A key the mode does not ship at all is skipped rather than written as nil,
    -- which would delete the setting.
    local tlKey
    for k in pairs(DF.PartyDefaults) do
        if type(k) == "string" and k:sub(1, 12) == "targetedList" then tlKey = k break end
    end
    check(tlKey ~= nil, "mode: there is a party-only Targeted List key to test with")
    check(DF.RaidDefaults[tlKey] == nil, "mode: ...and raid does not ship it")
    raid[tlKey] = "something"
    GA:ResetKeys(host, raid, { tlKey }, "raid")
    eq(raid[tlKey], "something", "mode: a key the mode does not ship is left alone, not nil'd")
end

-- ============================================================
-- 5. THE HOLD ROUND-TRIP
-- ============================================================
do
    local party = freshProfile()
    local host = fakeHost()

    local defSize  = DF.PartyDefaults.frameBorderSize
    local defColor = DF.PartyDefaults.frameBorderColor
    party.frameBorderSize  = defSize + 7
    party.frameBorderColor = { r = 0.1, g = 0.2, b = 0.3, a = 0.4 }
    local mine = deepcopy(party.frameBorderColor)

    local keys = { "frameBorderSize", "frameBorderColor", "frameShowBorder" }
    local snap = GA:BeginHold(host, party, keys, "party")

    eq(party.frameBorderSize, defSize, "hold: the preview puts the group at its defaults")
    check(deepsame(party.frameBorderColor, defColor), "hold: ...tables included")
    check(party.frameBorderColor ~= defColor, "hold: ...still by copy, never by reference")

    -- Every key the mode ships is in the SNAPSHOT, including the ones that were
    -- already default: a key left out is a key EndHold cannot restore.
    check(snap.frameShowBorder ~= nil,
        "hold: an unmodified key is still snapshotted -- the snapshot is what the user HAD")
    check(host:Written("frameShowBorder") == nil,
        "hold: ...but it was not written, so no edit was recorded for it")
    check(snap.frameBorderColor ~= mine and deepsame(snap.frameBorderColor, mine),
        "hold: the snapshot's table is a copy of what was there, not the live reference")

    local writesIn = #host.written
    GA:EndHold(host, party, keys, snap)

    eq(party.frameBorderSize, defSize + 7, "hold: the release puts the user's number back")
    check(deepsame(party.frameBorderColor, mine), "hold: ...and their colour, value for value")
    check(party.frameBorderColor ~= defColor,
        "hold: ☠ ...as a table of its own, NOT a reference into the shipped defaults")
    check(#host.written > writesIn, "hold: the restore went through the bracket too")
    local last = host:Written("frameBorderSize")
    eq(last.value, defSize + 7, "hold: ...announcing the restored value")

    -- ...and the restore is redirected exactly as the outward leg would be.
    local party2 = freshProfile()
    party2.frameBorderSize = defSize + 2
    local host2 = fakeHost({ frameBorderSize = true })
    local snap2 = GA:BeginHold(host2, party2, { "frameBorderSize" }, "party")
    eq(party2.frameBorderSize, defSize + 2, "hold: a claimed key is not previewed either")
    GA:EndHold(host2, party2, { "frameBorderSize" }, snap2)
    check(host2:Written("frameBorderSize") == nil,
        "hold: ☠ and nothing is announced in either direction for a redirected key")
end

-- ============================================================
-- 6. THE TABLES IT CANNOT REASON ABOUT
-- The engine answers "not modified" for any table it does not recognise, and
-- these actions are built on that answer -- so a scratch table, an aura proxy or
-- a nil must come back untouched rather than being filled with party defaults.
-- ============================================================
do
    freshProfile()
    local host = fakeHost()
    local stranger = { frameBorderSize = 999 }
    GA:ResetKeys(host, stranger, { "frameBorderSize" }, "party")
    eq(stranger.frameBorderSize, 999, "unknown table: nothing is reset in a table the engine cannot place")
    eq(#host.written, 0, "unknown table: ...and nothing is announced")

    local ok = pcall(function() GA:ResetKeys(host, nil, { "frameBorderSize" }, "party") end)
    check(ok, "unknown table: a nil db is a no-op, not an error")
    ok = pcall(function() GA:EndHold(host, nil, nil, nil) end)
    check(ok, "unknown table: ...and so is a hold with nothing in it")
end

-- ============================================================
-- 7. THE RESET'S APPLY REACHES THE UNDO ENGINE
-- ------------------------------------------------------------
-- ☠ THE ASYMMETRY THIS EXISTS FOR. Nothing in this file applies anything: the
-- caller (the popout footer's Reset button) writes through here and then runs
-- the group's apply ONCE. An UNDO of that reset has no button press behind it to
-- do the same -- so the apply is handed to BeginGroup with the label, and the
-- collapsed entry carries it. Without it an undo of a thirteen-key reset puts
-- thirteen values back and refreshes nothing the caller's own apply refreshes,
-- which reads as "undo did nothing".
--
-- The engine itself is tested in test_settings_undo.lua; what is pinned here is
-- that this file HANDS IT OVER, and that it hands over the same reference it was
-- given rather than a wrapper the engine would have to keep alive.
-- ============================================================
do
    local savedSU = DF.SettingsUndo
    local log = { begun = {}, ended = 0 }
    DF.SettingsUndo = {
        BeginGroup = function(_, label, applyFn)
            log.begun[#log.begun + 1] = { label = label, apply = applyFn }
        end,
        EndGroup = function() log.ended = log.ended + 1 end,
        Suspend  = function() end,
        Resume   = function() end,
    }

    local party = freshProfile()
    local defSize = DF.Defaults:GetDefault("party", "frameBorderSize")
    party.frameBorderSize = defSize + 5
    local host = fakeHost()

    local applied = 0
    local applyFn = function() applied = applied + 1 end
    GA:ResetKeys(host, party, { "frameBorderSize" }, "party", "Border", applyFn)

    eq(#log.begun, 1, "reset apply: the group was opened once")
    eq(log.begun[1].label, "Border", "reset apply: ...named by the row, as before")
    check(log.begun[1].apply == applyFn,
        "reset apply: ☠ ...and carrying the caller's apply, BY REFERENCE")
    eq(log.ended, 1, "reset apply: and closed again")
    eq(applied, 0,
        "reset apply: ☠ handing it over is not running it -- the caller still applies for itself")
    eq(party.frameBorderSize, defSize, "reset apply: (the reset itself did what it always did)")

    -- Optional, at both ends: a caller with nothing to apply opens an unnamed,
    -- apply-less group exactly as it did before the argument existed.
    log.begun, log.ended = {}, 0
    party.frameBorderSize = defSize + 5
    GA:ResetKeys(host, party, { "frameBorderSize" }, "party")
    eq(#log.begun, 1, "reset apply: a caller that passes neither still opens a group")
    check(log.begun[1].label == nil and log.begun[1].apply == nil,
        "reset apply: ...with nothing in either slot")

    DF.SettingsUndo = savedSU
end

-- ============================================================
-- THE READ-BACK HALF -- source, not behaviour
-- ------------------------------------------------------------
-- ☠ THE BUG: with the popout open, Reset Group wrote every key, moved the
-- frames and repainted the row summary -- and left every control INSIDE the
-- panel showing the values it had before. The undo of that reset had the same
-- gap, because it replays the same apply.
--
-- A write is only half the verb. The other half is telling the widgets, and the
-- widgets cannot know: the factories paint a tick, a thumb, a caption and a
-- swatch at build and on their own OnShow, on the assumption that nothing writes
-- a setting except the widget bound to it -- which is exactly what a group reset
-- breaks.
--
-- The behaviour is tested where it lives: RefreshChildValues against the real
-- group in test_sections_group.lua, and the slider's and dropdown's own hooks
-- against the real factories in test_widgets_slider.lua. What ONLY the source
-- can say is that the page WIRED it, and that the two factories neither of those
-- files can build carry the hook -- GUI/Pages/Options.lua is far too tangled in
-- the live panel to load, and the settings-panel checkbox and colour picker are
-- in the load-on-demand companion.
-- ============================================================
do
    -- ⚠ THE REFLOW MOVED HOUSE. Both lines below were the Frame page's own inline
    -- machinery when this block was written; they are GUI:CreatePopoutPageTools'
    -- now (Controls.lua), and every converted page reaches them through it. The
    -- claims are unchanged -- only where they are read from is.
    local tools = options_file_source("GUI/Controls.lua")
    local function hasPage(needle, msg)
        check(tools:find(needle, 1, true) ~= nil, "readback: " .. msg)
    end

    hasPage("if values and g.RefreshChildValues then g:RefreshChildValues() end",
            "the pane reflow can repaint bound values")
    hasPage("ReflowMounted(true)",
            "...and the group's post-write apply asks it to")
    -- ⚠ OPT-IN, and this is the assertion that keeps it so. ReflowMounted also
    -- runs on a hideOn change while a slider inside the pane is being dragged,
    -- and a value repaint mid-drag snaps the thumb from the mouse back to the
    -- last committed step -- every step. Exactly one caller may pass true.
    --
    -- Counted over the helper AND the page that calls it most, because the callers
    -- are now split across the two: the helper holds the one opted-in call, the
    -- page holds the bare `tools.ReflowMounted()` toggles.
    do
        local both = tools .. options_file_source("GUI/Pages/Options.lua")
        local n, from = 0, 1
        while true do
            local s = both:find("ReflowMounted(", from, true)
            if not s then break end
            n, from = n + 1, s + 1
        end
        check(n >= 2, "readback: ReflowMounted has more than one caller")
        local trues, from2 = 0, 1
        while true do
            local s = both:find("ReflowMounted(true)", from2, true)
            if not s then break end
            trues, from2 = trues + 1, s + 1
        end
        eq(trues, 1, "readback: ...and exactly one of them asks for the value sweep")
    end

    -- The two factories that cannot be built headlessly.
    local widgets = options_file_source("GUI/SettingsWidgets.lua")
    check(widgets:find("container.refreshValue = UpdateState", 1, true) ~= nil,
          "readback: the settings checkbox carries the value hook")
    check(widgets:find("container.refreshValue = UpdateSwatch", 1, true) ~= nil,
          "readback: ...and so does the colour picker")
end

DandersFrames = savedDandersFrames
