local NS = ...

-- ============================================================
-- DANDERSUI_OPTIONS.XML -- THE LOAD-ON-DEMAND HALF
-- ------------------------------------------------------------
-- Two things are worth a headless test here, and they are the two that only
-- ever run in a situation nobody plays in:
--
--   1. OptionsCore.lua's HANDSHAKE. It is the head of a manifest that normally
--      loads in a DIFFERENT addon from the base half, so it resolves the library
--      through LibStub and must go quietly inert -- one line, handshake unset --
--      when the library is missing or the wrong minor. Every failure mode is a
--      broken install, which is exactly what nobody has on their own machine.
--
--   2. ColorPicker.lua's PERSISTENCE SEAM. The pack owns no SavedVariables, so
--      the palettes live in whatever table the consumer hands back from the
--      `pickerStore` hook -- and a consumer that hands back nothing must still
--      get a working picker, just a forgetful one.
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME ACROSS EVERY TEST FILE. Every global this
-- file replaces (print, LibStub, CreateFrame, ...) is restored before the block
-- that replaced it ends, or the next file inherits it.
-- ============================================================

-- ---- print capture -------------------------------------------------
-- OptionsCore reports through the RAW global print (it has no library to print
-- through), so the only way to count its output is to be the print it calls.
local function capturing(fn)
    local lines = {}
    local realPrint = print
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        lines[#lines + 1] = table.concat(parts, " ")
    end
    local ok, err = pcall(fn)
    print = realPrint
    if not ok then check(false, "capturing: unexpected error -- " .. tostring(err)) end
    return lines
end

-- ---- LibStub swap --------------------------------------------------
-- run.py loads the REAL LibStub, and other suites use it. Swapped per block and
-- put straight back.
local function withLibStub(answer, fn)
    local realLibStub = LibStub
    local asked = {}
    LibStub = function(name, silent)
        asked[#asked + 1] = { name = name, silent = silent }
        return answer
    end
    local out = fn(asked)
    LibStub = realLibStub
    return out
end

local function loadOptionsCore(ns)
    return capturing(function() load_ui_file_into("OptionsCore.lua", ns) end)
end

-- ---- the pinned minor ----------------------------------------------
-- ☠ READ OUT OF THE SOURCE, never typed in here. These blocks used to hardcode
-- the number, so the first MINOR bump after they were written failed four
-- assertions that had nothing to do with the change -- and the fix each time is
-- to edit a test to match a constant it does not own. The whole point of the
-- check under test is that the two numbers track each other; this reads the one
-- the manifest actually pins and derives the neighbours from it.
local EXPECTED = tonumber(ui_file_source("OptionsCore.lua"):match("EXPECTED_MINOR%s*=%s*(%d+)"))
check(EXPECTED ~= nil, "setup: EXPECTED_MINOR is readable out of OptionsCore.lua")
local OLDER, NEWER = EXPECTED - 2, EXPECTED + 1

-- ============================================================
-- 1. THE HANDSHAKE, RESOLVED THROUGH LIBSTUB
-- The normal case: the options manifest rides its own addon, so its NS is empty
-- and the base half has to be found through the one registry both halves share.
-- ============================================================
do
    local base = { MINOR = EXPECTED, name = "base-expected" }
    local ns = {}
    local lines = withLibStub(base, function(asked)
        local out = loadOptionsCore(ns)
        eq(asked[1].name, "DandersUI-1.0", "handshake: it asks LibStub for the base library")
        check(asked[1].silent == true, "handshake: ...silently -- a missing library is handled, not thrown")
        return out
    end)
    check(ns.__DandersUI == base, "handshake: the library LibStub answered with IS the handshake")
    eq(#lines, 0, "handshake: a good load says nothing")
end

-- ============================================================
-- 2. NO BASE LIBRARY -> INERT, AND EXACTLY ONE LINE
-- The handshake is left UNSET on purpose: every later file in the manifest opens
-- with `if not UI then return end`, so an unset key is what turns the rest of the
-- manifest into a no-op instead of one fresh Lua error per file.
-- ============================================================
do
    local ns = {}
    local lines = withLibStub(nil, function() return loadOptionsCore(ns) end)
    check(ns.__DandersUI == nil, "missing: the handshake is left unset, so the manifest goes inert")
    eq(#lines, 1, "missing: exactly one line -- the user is told once, not once per file")
    check(lines[1]:find("DandersUI_Options") ~= nil, "missing: the line names the module that failed")
    check(lines[1]:lower():find("not found") ~= nil, "missing: ...and says the base library is missing")
end

-- A LibStub that is not there AT ALL is the same story, not a nil-index error:
-- the call site is guarded (`LibStub and LibStub(...)`).
do
    local ns = {}
    local realLibStub = LibStub
    LibStub = nil
    local lines = loadOptionsCore(ns)
    LibStub = realLibStub
    check(ns.__DandersUI == nil, "nolibstub: still inert")
    eq(#lines, 1, "nolibstub: still one line, not a Lua error")
end

-- ============================================================
-- 3. MINOR MISMATCH -> INERT, AND THE LINE NAMES BOTH NUMBERS
-- Some other addon's older copy of the base half won the LibStub race. The
-- surfaces this manifest builds on may have changed shape, so it refuses up
-- front rather than erroring halfway through a page build -- and the message has
-- to carry both numbers, because "update your addons" is useless without them.
-- ============================================================
do
    local old = { MINOR = OLDER, name = "base-older" }
    local ns = {}
    local lines = withLibStub(old, function() return loadOptionsCore(ns) end)
    check(ns.__DandersUI == nil, "mismatch: an older base half does NOT get the handshake")
    eq(#lines, 1, "mismatch: one line")
    check(lines[1]:find(tostring(OLDER), 1, true) ~= nil, "mismatch: the line names the minor it found")
    check(lines[1]:find(tostring(EXPECTED), 1, true) ~= nil, "mismatch: ...and the minor it wanted")
end

-- A NEWER base half is refused on exactly the same terms: the check is
-- `~=`, not `<`, because a shape change cuts both ways.
do
    local newer = { MINOR = NEWER }
    local ns = {}
    local lines = withLibStub(newer, function() return loadOptionsCore(ns) end)
    check(ns.__DandersUI == nil, "mismatch: a NEWER base half is refused too")
    eq(#lines, 1, "mismatch: ...with one line")
    check(lines[1]:find(tostring(NEWER), 1, true) ~= nil, "mismatch: naming the newer minor it found")
end

-- ============================================================
-- 4. SAME-ADDON SHORT-CIRCUIT
-- When both manifests happen to load in ONE addon, Core.lua has already set
-- NS.__DandersUI and that is the copy to use -- LibStub might answer with some
-- other addon's copy that won the race.
-- ============================================================
do
    local mine = { MINOR = EXPECTED, name = "same-addon" }
    local theirs = { MINOR = EXPECTED, name = "someone-else" }
    local ns = { __DandersUI = mine }
    local lines = withLibStub(theirs, function(asked)
        local out = loadOptionsCore(ns)
        eq(#asked, 0, "sameaddon: LibStub is not even consulted")
        return out
    end)
    check(ns.__DandersUI == mine, "sameaddon: the in-addon copy is kept")
    eq(#lines, 0, "sameaddon: and nothing is printed")
end

-- The minor check runs on the pre-set table too, and a mismatch CLEARS the
-- handshake rather than leaving it: a pre-set key with the wrong minor means a
-- mixed-version install, and leaving it set would let the rest of this manifest
-- run against the mismatched base. (Unreachable in a healthy install -- a
-- pre-set key means Core.lua ran in this same addon, so the minors come from
-- the same folder -- which is exactly why it must fail safe when it does
-- happen.) The resident half is unaffected: its files read the key at their own
-- load time, which has already passed.
do
    local stale = { MINOR = OLDER, name = "stale-in-addon" }
    local ns = { __DandersUI = stale }
    local lines = withLibStub(nil, function() return loadOptionsCore(ns) end)
    eq(#lines, 1, "stale: a mismatched in-addon copy is still reported")
    check(ns.__DandersUI == nil, "stale: and the pre-set handshake is cleared, inerting the manifest")
end

-- ============================================================
-- 5. THE PICKER'S PERSISTENCE SEAM
-- ------------------------------------------------------------
-- ColorPicker.lua keeps the two palettes and the square/wheel preference in file
-- locals and adopts the consumer's store -- `host:Hook("pickerStore")` -> a table
-- with `saved` / `recent` / `square` -- on the FIRST OpenColorPicker, before the
-- frame that reads them is built.
--
-- ☠ THE STORE RESOLVES ONCE PER LOAD, and `store` / `storeResolved` are file
-- locals. That is what makes both cases testable in one runtime: each
-- load_ui_file_into gets its own copy of those locals, so a no-store picker and
-- a seeded-store picker can be driven side by side without either seeing the
-- other's state.
-- ============================================================

-- The whole WoW/host surface the picker build touches. Deliberately explicit:
-- if the picker grows a new host call, this stub must grow with it, and that is
-- the point -- a catch-all __index would hide the growth.
local function pickerHost(storeHook)
    local rec = { frames = {}, hookAsks = 0 }
    local UI = {}
    local function col(r, g, b) return { r = r, g = g, b = b, a = 1 } end
    UI.MEDIA  = ""
    UI.Colors = { element = col(0.2, 0.2, 0.2), border = col(0.3, 0.3, 0.3),
                  accent = col(0.45, 0.45, 0.95), text = col(0.9, 0.9, 0.9),
                  textDim = col(0.5, 0.5, 0.5) }
    function UI:CreateElementBackdrop(frame) return frame end
    function UI:StyleButton(frame) return frame end
    function UI:StyleEditBox(frame) return frame end
    function UI:ShowTooltip() end
    function UI:HideTooltip() end
    function UI:RegisterScaledSurface() end
    function UI:CreateCloseButton() return FakeUIFrame(16, 16) end
    function UI:CreateEditBoxNative() return FakeUIFrame(60, 20) end
    -- The square/wheel pill is not settings-bound -- the preference is a file
    -- local persisted through the store -- so it binds by customGet/customSet.
    -- Keeping those is how a test reads and writes that preference without a
    -- real widget.
    function UI:CreateSegmentToggle(_, _, _, _, onChange, opts)
        rec.pillOpts, rec.pillChanged = opts, onChange
        return FakeUIFrame(60, 20)
    end
    function UI:Hook(name)
        if name == "pickerStore" then rec.hookAsks = rec.hookAsks + 1 end
        return self.hooks and self.hooks[name]
    end

    local L = setmetatable({}, { __index = function(_, k) return k end })
    local host = setmetatable({ hooks = { L = L, pickerStore = storeHook } }, { __index = UI })
    return UI, host, rec
end

-- How many swatch buttons a refresh built. The palettes themselves are file
-- locals with no reader, so "the picker adopted N colours" is observed as the N
-- swatch frames it laid out for them.
local function countButtons(rec, fn)
    for i = #rec.frames, 1, -1 do rec.frames[i] = nil end
    fn()
    local n = 0
    for _, kind in ipairs(rec.frames) do if kind == "Button" then n = n + 1 end end
    return n
end

-- The globals the build reaches for. Saved and restored around each block.
local function withPickerGlobals(rec, fn)
    local prev = { CreateFrame = CreateFrame, CreateColor = CreateColor,
                   GetCursorPosition = GetCursorPosition, UISpecialFrames = UISpecialFrames,
                   LOCALIZED_CLASS_NAMES_MALE = LOCALIZED_CLASS_NAMES_MALE }
    -- The shim's FakeUIFrame plus a real parent link: the picker walks back up
    -- from an edit box to the container it built (`aInput:GetParent()`), and the
    -- shim's no-op fallback would hand back nil there.
    CreateFrame = function(kind, _, parent)
        rec.frames[#rec.frames + 1] = kind
        local f = FakeUIFrame(100, 100)
        f._parent = parent
        function f:GetParent() return self._parent end
        return f
    end
    CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
    GetCursorPosition = function() return 0, 0 end
    UISpecialFrames = {}
    LOCALIZED_CLASS_NAMES_MALE = nil
    local ok, err = pcall(fn)
    CreateFrame, CreateColor = prev.CreateFrame, prev.CreateColor
    GetCursorPosition, UISpecialFrames = prev.GetCursorPosition, prev.UISpecialFrames
    LOCALIZED_CLASS_NAMES_MALE = prev.LOCALIZED_CLASS_NAMES_MALE
    if not ok then check(false, "picker: unexpected error -- " .. tostring(err)) end
    return ok
end

-- Read the square/wheel preference off the pill the picker built. Guarded, so a
-- picker that never built one reports a failed assertion instead of a nil index.
local function pillValue(rec)
    return rec.pillOpts and rec.pillOpts.customGet and rec.pillOpts.customGet() or nil
end

-- The no-store picker's frame, kept so the seeded block below can prove the two
-- loads really are two: separate file locals, separate everything.
local noStoreFrame

local RED   = { r = 1, g = 0, b = 0, a = 1 }
local GREEN = { r = 0, g = 1, b = 0, a = 1 }

-- ---- 5a. NO STORE: the picker works, and it remembers nothing past the run ----
-- A consumer with no SavedVariables to lend (or one that simply does not supply
-- the hook) must still get a picker. The palettes then live in the file locals:
-- everything works for the session and there is nothing to write back to.
do
    local UI, host, rec = pickerHost(nil)
    local frame
    local ok = withPickerGlobals(rec, function()
        load_ui_file_into("ColorPicker.lua", { __DandersUI = UI })
        host:OpenColorPicker(RED, true)
        frame = host:GetColorPickerFrame()
        noStoreFrame = frame
    end)
    check(ok, "nostore: opening the picker with no store raises nothing")
    check(frame ~= nil and frame:IsShown(), "nostore: ...and the picker is up")
    eq(rec.hookAsks, 1, "nostore: the store hook was asked for, once")
    eq(pillValue(rec), "square",
        "nostore: the square/wheel preference falls back to the file default")

    -- The session palette still accumulates: the colour the picker opened on went
    -- into recent, and the next one goes in front of it.
    withPickerGlobals(rec, function()
        local n = countButtons(rec, function() frame.AddToRecent(0, 1, 0, 1) end)
        eq(n, 2, "nostore: recent holds the opening colour and the new one, in session")
        n = countButtons(rec, function() frame.AddToRecent(0, 1, 0, 1) end)
        eq(n, 2, "nostore: re-adding the same colour moves it, it does not duplicate")
    end)

    -- Nothing was written anywhere a consumer could see, because there is nowhere.
    withPickerGlobals(rec, function()
        rec.pillOpts.customSet("circle")
        rec.pillChanged()
    end)
    eq(pillValue(rec), "circle", "nostore: the preference still changes in session")
    eq(rec.hookAsks, 1, "nostore: and the hook is never asked a second time")
end

-- ---- 5b. A SEEDED STORE: adopted on open, written through on change ----
-- The store's arrays are taken BY REFERENCE, so a save is a re-assignment of the
-- same object -- which is what makes a consumer's SavedVariables table carry the
-- swatches without the pack ever knowing what SavedVariables are.
do
    local seededSaved  = { { r = 1, g = 0, b = 0, a = 1 }, { r = 0, g = 0, b = 1, a = 1 } }
    local seededRecent = { { r = 0.5, g = 0.5, b = 0.5, a = 1 } }
    local store = { saved = seededSaved, recent = seededRecent, square = false }
    local UI, host, rec = pickerHost(function() return store end)
    local frame
    local ok = withPickerGlobals(rec, function()
        load_ui_file_into("ColorPicker.lua", { __DandersUI = UI })
        host:OpenColorPicker(GREEN, true)
        frame = host:GetColorPickerFrame()
    end)
    check(ok, "store: opening against a seeded store raises nothing")
    eq(rec.hookAsks, 1, "store: the hook was asked once")
    eq(pillValue(rec), "circle", "store: the stored square/wheel preference was adopted")

    withPickerGlobals(rec, function()
        local n = countButtons(rec, function() frame.RefreshSavedSwatches() end)
        eq(n, #seededSaved, "store: the saved palette was adopted -- a swatch per stored colour")
    end)

    -- Adoption is BY REFERENCE, so the open's own colour landed in the very table
    -- the consumer handed over, in front of what was already there.
    eq(store.recent, seededRecent, "store: recent is still the consumer's own table")
    eq(#store.recent, 2, "store: the colour the picker opened on was written through")
    -- Indexed defensively: if the write-through ever breaks these are the
    -- assertions that catch it, and they have to REPORT rather than take the
    -- whole harness down with a nil index.
    eq(store.recent[1] and store.recent[1].g, 1, "store: ...at the front")
    eq(store.recent[2] and store.recent[2].r, 0.5, "store: ...and the seeded colour is still behind it")

    -- The preference round-trips: the pill writes the local, the change hook
    -- saves, and the consumer's table has the new value.
    withPickerGlobals(rec, function()
        rec.pillOpts.customSet("square")
        rec.pillChanged()
    end)
    eq(store.square, true, "store: flipping the pill writes the preference through")
    eq(store.saved, seededSaved, "store: ...without swapping the consumer's arrays for new ones")

    -- Two loads, two sets of file locals -- which is what makes both cases honest
    -- in one runtime. The no-store picker above never saw any of this.
    check(frame ~= nil and frame ~= noStoreFrame,
        "store: a second load built its OWN picker, not the no-store one")
end

-- ============================================================
-- 6. THE MANIFEST COMPILES
-- Compile-only (loadstring), not load: Sections.lua and ColorPicker.lua build
-- their pages against a real host, and running them again here would prove
-- nothing the blocks above do not. A syntax error in any of the three is a
-- whole settings panel that never opens.
-- ============================================================
do
    for _, name in ipairs({ "OptionsCore.lua", "Sections.lua", "ColorPicker.lua" }) do
        local src = ui_file_source(name)
        check(src ~= nil and #src > 0, "compile: " .. name .. " has source")
        local chunk, err = (loadstring or load)(src, "@" .. name)
        check(chunk ~= nil, "compile: " .. name .. " -- " .. tostring(err))
    end
end
