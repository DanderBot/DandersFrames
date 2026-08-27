local addonName, DF = ...

-- ============================================================
-- SETTINGS UNDO -- THE RECORDING ENGINE
-- ------------------------------------------------------------
-- One undo stack for the settings panel, filled from the WRITE BRACKET rather
-- than from the widgets. Every db-bound widget in the kit already asks the host
-- `interceptWrite` before it writes and tells it `onSettingWritten` after, so
-- those two hooks are the only place in the addon where "a setting changed" is
-- a single observable event. Recording there means a widget added tomorrow is
-- undoable the day it is wired to a db key, and a widget that writes AROUND the
-- bracket is invisible here -- which is the correct answer, because it is also
-- invisible to the auto-layout recorder.
--
-- THE PAIR
-- --------
-- `interceptWrite` fires BEFORE the write, so db[key] still holds the OLD value:
-- that is where the capture is taken. `onSettingWritten` fires after the write
-- landed: that is where the entry is committed. A write the auto-profile layer
-- REDIRECTS never reaches the second half, so its capture is simply never
-- committed -- no entry, which is right, because the live table did not move.
--
-- WHAT IS NOT RECORDED, AND WHY
-- -----------------------------
--   * A write that did not land PLAINLY. A dropdown with a `customSet` writes
--     somewhere else entirely and announces the value it chose; db[key] is then
--     not the store, and an entry built from it would restore a value into a
--     table nobody reads. Post-write `db[key] == value` is the test.
--   * A write that changed nothing. A zero-delta entry is an undo step that
--     visibly does nothing when the user presses it.
--   * Anything at all while SUSPENDED. Applying an undo is itself a bracketed
--     write, and a press-and-hold preview is a write the user never made.
--
-- AN ENTRY CARRIES THE APPLY, NOT JUST THE VALUE
-- ----------------------------------------------
-- `onSettingWritten` takes a fifth argument: the widget's own commit callback,
-- by reference. Restoring a value is not the same thing as reverting an edit --
-- for a great many settings the work that makes the change VISIBLE lives in
-- that callback, not in the generic sweep -- so the entry stores it and the
-- apply replays it. See Apply() for what happens when the closure has outlived
-- its page.
--
-- ONE GESTURE, ONE ENTRY
-- ----------------------
-- A slider fires `onSettingWritten` once per STEP CROSSED while it is dragged --
-- twenty entries for one drag across a bar. The host's drag pair brackets the
-- gesture, so while it is open commits ACCUMULATE per key (the first old value
-- is kept, the newest value replaces the last) and one entry is pushed when the
-- gesture closes. There is no coalescing ACROSS gestures: two separate drags of
-- the same slider are two entries, because they were two things the user did.
--
-- Session-scoped. Nothing here is saved: an undo stack that survived a reload
-- would offer to restore values against a profile that may no longer exist.
-- ============================================================

local type, pairs, ipairs, tostring, pcall = type, pairs, ipairs, tostring, pcall
local setmetatable, wipe = setmetatable, wipe
local upper, gsub, sub = string.upper, string.gsub, string.sub

DF.SettingsUndo = DF.SettingsUndo or {}
local SettingsUndo = DF.SettingsUndo

local STACK_LIMIT = 100

-- ============================================================
-- STATE
-- ============================================================

local stack                             -- the DandersUndo-1.0 stack, made on first use

-- Pre-write captures, keyed [db][key] = { old = <deep copy> }. WEAK on the outer
-- key: a redirected write leaves its capture behind (nothing ever commits it),
-- and a db table that goes away with a profile switch must not be pinned in
-- memory by a capture nobody will ever consume.
local pending = setmetatable({}, { __mode = "k" })

-- The open drag gesture. `order` is the push order for the (rare) case of a
-- gesture that moved more than one key; `byDB` is the lookup that merges a
-- repeat commit onto the entry already accumulating for that key.
local gestureDepth = 0
local gestureOrder = {}
local gestureByDB  = setmetatable({}, { __mode = "k" })

local suspendDepth = 0

-- The open GROUP, mirroring the lib's own refcount. Only the OUTERMOST group
-- carries an apply, because only the outermost one becomes an entry.
local groupDepth = 0
local groupApply

-- ============================================================
-- HELPERS
-- ============================================================

-- DF:DeepCopy is resident and loads before this file, so it is always there in
-- game -- but a headless load of this module alone is not. The local fallback is
-- the same shape without the proxy unwrap; the values copied here are stored
-- settings, never a db proxy. (Same pattern, same reason, as GroupActions.lua.)
local function DeepCopy(v)
    if type(v) ~= "table" then return v end
    if DF.DeepCopy then return DF:DeepCopy(v) end
    local t = {}
    for k, x in pairs(v) do t[k] = DeepCopy(x) end
    return t
end

-- Equal BY VALUE. `==` is the whole answer for a number, a string or a boolean;
-- a colour is a table whose twin holds the same four numbers, and calling that a
-- change would record an entry for every reset that reset nothing.
local function DeepEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if not DeepEqual(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

-- "frameWidth" -> "Frame Width". The FALLBACK label, for a write whose widget
-- did not name itself. Deliberately not localised: a db key is not a translated
-- string, and inventing a locale entry per setting key to prettify one would be
-- a translation burden for text the user should rarely see.
local function PrettifyKey(key)
    if type(key) ~= "string" or key == "" then return tostring(key) end
    local s = gsub(key, "(%l)(%u)", "%1 %2")
    return upper(sub(s, 1, 1)) .. sub(s, 2)
end

-- Which side of the profile `db` is, so an undo applied while the OTHER mode's
-- page is on screen does not repaint a page showing different settings. nil is
-- a legal answer, not a failure: a designer proxy or a scratch table is neither
-- side, and an entry carrying nil simply refreshes whenever the window is open.
local function ResolveMode(db)
    local root = DF.db
    if not root then return nil end
    if db == root.raid or (DF._realRaidDB and db == DF._realRaidDB) then return "raid" end
    if db == root.party then return "party" end
    return nil
end

-- The lib, resolved on first use. The TOC loads Libs\DandersUI before Core, so a
-- load-time LibStub call would be safe in game -- lazily is what lets a headless
-- test load this module in any order, and costs one branch per push.
local function GetStack()
    if stack then return stack end
    if not (LibStub and LibStub.GetLibrary) then return nil end
    -- SILENT, i.e. nil rather than an error if the lib is absent: an undo stack
    -- is a convenience, and a missing library must not take the settings panel
    -- down with it.
    local lib = LibStub:GetLibrary("DandersUndo-1.0", true)
    if not lib then return nil end
    stack = lib:New({ limit = STACK_LIMIT })
    SettingsUndo.stack = stack
    return stack
end

-- ============================================================
-- APPLY -- AN UNDO IS A WRITE LIKE ANY OTHER
-- ------------------------------------------------------------
-- The SAME bracket the widgets use, so an auto layout that would have redirected
-- the user's own edit redirects the undo of it too, and a layout being edited
-- records the undo as the override edit it is. Recording is suspended across it:
-- an undo that pushed an entry would be un-undoable by construction.
--
-- Value REPLACEMENT, not a field merge -- the same semantics
-- GroupActions:ResetKeys already ships. The copy is what lands, so a later edit
-- of the setting cannot reach back into the stored entry.
--
-- ☠ AND THE WRITE IS ONLY HALF OF WHAT THE USER'S EDIT DID. For a great many
-- settings the REAL apply is not the generic sweep below -- it is the commit
-- callback the widget runs after its own write: a version bump the frames read
-- (InvalidateAuraLayout), a targeted refresher the sweep does not cover
-- (LightweightUpdateBorder is the only path that re-borders live RAID frames),
-- a secure-header re-apply. An undo that wrote the value and ran only the sweep
-- moved the number and left the frames where they were, which is exactly what
-- the user reported. So the entry carries `apply` -- the widget's own commit
-- callback, by reference -- and replaying it is what makes an undo the mirror
-- image of the edit rather than an approximation of it.
--
-- pcall'd, because that closure belongs to the PAGE that built the widget and
-- may capture objects the page has since torn down (a row's Refresh, a mounted
-- pane). A dead closure must cost the undo nothing: on failure this falls
-- through silently and the fallback sweep below still runs.
-- ============================================================

-- Replay a stored commit callback with recording SUSPENDED. Suspension is not
-- optional: a callback may itself write settings (a linked-section sync writes
-- the mirrored key), and those writes are part of the apply, not new edits.
local function RunApply(applyFn)
    if type(applyFn) ~= "function" then return end
    SettingsUndo:Suspend()
    pcall(applyFn)
    SettingsUndo:Resume()
end

local function Apply(db, key, value, mode, applyFn)
    if type(db) ~= "table" or key == nil then return end

    SettingsUndo:Suspend()
    local host = DF.GUI
    local copy = DeepCopy(value)
    if host and host.Call and host:Call("interceptWrite", db, key, copy) then
        -- Redirected to the baseline: the live table did not change, so neither
        -- the plain write nor the announcement happens.
    else
        db[key] = copy
        if host and host.Call then host:Call("onSettingWritten", db, key, copy) end
    end
    -- Inside the SAME suspension as the write it belongs to -- see RunApply.
    if applyFn then pcall(applyFn) end
    SettingsUndo:Resume()

    -- KEPT UNCONDITIONALLY, apply or no apply. A live widget commit is the same
    -- pair: its callback AND the coalescing sweep the kit's refresh hooks arm.
    -- Dropping the sweep when an apply is present would make an undo do LESS
    -- than the edit it reverses, and UpdateAll is an arm-stub (ApplyScheduler),
    -- so the two together are one drained pass, not two.
    if DF.UpdateAll then DF:UpdateAll() end

    -- The PAGE, and only when there is one to repaint. RefreshCurrentPage is
    -- safe with the window closed, but rebuilding a page nobody is looking at --
    -- or one showing the other mode's settings -- is work for nothing.
    local GUI = DF.GUI
    if GUI and GUI.RefreshCurrentPage and DF.GUIFrame and DF.GUIFrame:IsShown() then
        if mode == nil or mode == GUI.SelectedMode then
            GUI:RefreshCurrentPage()
        end
    end
end

-- Turn committed data into the entry the lib stores. The data table IS the
-- entry: its meta fields (db/key/old/new/mode/label/apply) ride along beside the
-- two closures so a toast can read what moved without unpacking a closure.
local function PushEntry(data)
    local s = GetStack()
    if not s then return end
    local db, key, old, new, mode = data.db, data.key, data.old, data.new, data.mode
    local applyFn = data.apply
    data.undo = function() Apply(db, key, old, mode, applyFn) end
    data.redo = function() Apply(db, key, new, mode, applyFn) end
    s:Push(data)
end

-- Push everything a closed gesture accumulated, in the order the keys first
-- moved. In practice that is one entry -- a drag moves one slider -- but the
-- gesture bracket is refcounted and a colour session holds it open too, so the
-- multi-key case is spelled out rather than assumed away.
local function FlushGesture()
    for _, data in ipairs(gestureOrder) do
        if not DeepEqual(data.old, data.new) then PushEntry(data) end
    end
    wipe(gestureOrder)
    wipe(gestureByDB)
end

-- ============================================================
-- THE BRACKET HOOKS
-- ============================================================

-- Called from the host's interceptWrite hook BEFORE the redirect decision, so
-- the capture is taken while db[key] still holds the old value. A capture that
-- is never committed (redirected write, customSet, zero delta) is dropped by the
-- commit half or overwritten by the next write to the same key.
function SettingsUndo:OnInterceptWrite(db, key, value)
    if suspendDepth > 0 then return end
    if type(db) ~= "table" or key == nil then return end
    local t = pending[db]
    if not t then t = {}; pending[db] = t end
    t[key] = { old = DeepCopy(db[key]) }
end

-- ...and the commit half, from the host's onSettingWritten hook. `label` is the
-- widget's display name, forwarded by the kit; absent, the key is prettified.
--
-- `applyFn` is the widget's OWN commit callback, by reference -- the exact
-- function it runs after this write. Optional, and optional at both ends: a
-- surface that does not forward one records an entry that falls back to the
-- generic sweep, which is what every entry did before this argument existed.
function SettingsUndo:OnSettingWritten(db, key, value, label, applyFn)
    if suspendDepth > 0 then return end
    if type(db) ~= "table" or key == nil then return end

    local t = pending[db]
    local capture = t and t[key]
    if not capture then return end
    t[key] = nil                                  -- consumed either way

    -- The write landed PLAINLY, i.e. db[key] is the store. A customSet widget
    -- announces a value that lives somewhere else entirely.
    if not DeepEqual(db[key], value) then return end
    local old = capture.old
    if DeepEqual(old, value) then return end      -- nothing moved

    local data = {
        db    = db,
        key   = key,
        old   = old,
        new   = DeepCopy(value),
        label = label or PrettifyKey(key),
        mode  = ResolveMode(db),
        apply = type(applyFn) == "function" and applyFn or nil,
    }

    if gestureDepth > 0 then
        local g = gestureByDB[db]
        if not g then g = {}; gestureByDB[db] = g end
        local open = g[key]
        if open then
            -- Same key, same gesture: the FIRST old value is what the user had
            -- before they touched it, and the newest value is where they are now.
            open.new = data.new
            -- ...and the apply travels with `new` rather than with `old`: it is
            -- the callback the widget is running NOW. In practice every tick of
            -- one gesture is the same widget and so the same reference; taking
            -- the newest is what keeps that true if it ever is not.
            if data.apply then open.apply = data.apply end
        else
            g[key] = data
            gestureOrder[#gestureOrder + 1] = data
        end
        return
    end

    PushEntry(data)
end

-- ============================================================
-- GESTURES
-- Refcounted, mirroring the host-side drag pair in Core.lua: the widget kit is
-- not the only surface that holds a drag open, and every start is matched by
-- exactly one stop.
-- ============================================================

function SettingsUndo:OnDragStart()
    gestureDepth = gestureDepth + 1
end

function SettingsUndo:OnDragStop()
    if gestureDepth == 0 then return end
    gestureDepth = gestureDepth - 1
    if gestureDepth == 0 then FlushGesture() end
end

-- The same pair under the name a non-drag session wants (the colour picker opens
-- one for the length of a picking session, so a cancelled pick is a zero-delta
-- gesture and pushes nothing).
SettingsUndo.BeginGesture = SettingsUndo.OnDragStart
SettingsUndo.EndGesture   = SettingsUndo.OnDragStop

-- ============================================================
-- GROUPS
-- Straight through to the lib, which collapses everything pushed between the
-- two calls into ONE entry carrying the group's label. Commits still run every
-- rule above on the way in, so a group of writes that all changed nothing is an
-- empty group -- and the lib drops those.
--
-- ONE APPLY FOR THE WHOLE GROUP, not one per key. The writes inside a group
-- come from GroupActions, which does no applying of its own -- the caller (the
-- popout footer's Reset button) runs the group's apply ONCE after the loop, and
-- undoing a reset has to do the same. Passing it here rather than letting the
-- N collapsed child entries each carry their own is the same decision the
-- caller already made: thirteen keys is one apply, not thirteen.
-- ============================================================

function SettingsUndo:BeginGroup(label, applyFn)
    groupDepth = groupDepth + 1
    if groupDepth == 1 and type(applyFn) == "function" then groupApply = applyFn end
    local s = GetStack()
    if s then s:BeginGroup(label) end
end

function SettingsUndo:EndGroup()
    if groupDepth > 0 then groupDepth = groupDepth - 1 end
    local s = GetStack()
    if not s then
        if groupDepth == 0 then groupApply = nil end
        return
    end

    -- Read BEFORE closing: the lib pushes the collapsed entry from inside
    -- EndGroup, so "is the top of the stack a new entry" is the only way to tell
    -- a group that collapsed to something from one the lib dropped as empty.
    local before = s.PeekEntry and s:PeekEntry() or nil
    s:EndGroup()
    if groupDepth > 0 then return end          -- an inner group closed, not ours

    local applyFn = groupApply
    groupApply = nil
    if not applyFn then return end
    local entry = s.PeekEntry and s:PeekEntry() or nil
    if not entry or entry == before then return end   -- empty group: nothing pushed

    -- The lib's group closures walk the child entries; the apply runs once
    -- AFTER them, in both directions, so the frames are told about the finished
    -- state rather than about each key on the way through.
    entry.apply = applyFn
    local undo, redo = entry.undo, entry.redo
    entry.undo = function() undo(); RunApply(applyFn) end
    entry.redo = function() redo(); RunApply(applyFn) end
end

-- ============================================================
-- SUSPENSION
-- Refcounted, because the reasons to suspend nest: an undo apply inside a
-- press-and-hold restore is not a case we ship, but a Resume that undid an outer
-- Suspend would silently start recording a preview.
-- ============================================================

function SettingsUndo:Suspend()
    suspendDepth = suspendDepth + 1
    -- Any capture taken before this moment belongs to a write that is now going
    -- to land unrecorded; holding it would let the NEXT recorded write commit
    -- against a stale old value.
    wipe(pending)
end

function SettingsUndo:Resume()
    if suspendDepth > 0 then suspendDepth = suspendDepth - 1 end
end

function SettingsUndo:IsSuspended() return suspendDepth > 0 end

-- ============================================================
-- THE PUBLIC VERBS
-- ============================================================

-- Returns (true, entry) so the caller can name what it just undid, or false when
-- there was nothing to undo. The entry is read BEFORE the apply, because the
-- apply is what moves it off the stack.
function SettingsUndo:Undo()
    local s = GetStack()
    if not s or not s:CanUndo() then return false end
    local entry = s.PeekEntry and s:PeekEntry() or nil
    s:Undo()
    return true, entry
end

function SettingsUndo:Redo()
    local s = GetStack()
    if not s or not s:CanRedo() then return false end
    local entry = s.PeekRedoEntry and s:PeekRedoEntry() or nil
    s:Redo()
    return true, entry
end

function SettingsUndo:CanUndo() return (stack and stack:CanUndo()) and true or false end
function SettingsUndo:CanRedo() return (stack and stack:CanRedo()) and true or false end

-- The fence. Every entry describes a value in a table that belonged to a
-- particular profile, so the moment the profile the user is editing is replaced
-- -- switched, imported over, reset, or swapped under them by an auto layout --
-- the whole stack is talking about settings that are no longer on screen.
-- Clearing is the honest answer; the alternative is an undo button that restores
-- a number into the profile the user just left.
--
-- Wipes the in-flight state too: a capture or a half-open gesture from the old
-- profile must not commit against the new one.
function SettingsUndo:Clear()
    wipe(pending)
    gestureDepth = 0
    wipe(gestureOrder)
    wipe(gestureByDB)
    groupDepth = 0
    groupApply = nil
    if stack then stack:Clear() end
end

-- The lib stack itself, for a consumer that wants its "Changed" callback (fired
-- on push, undo, redo and clear) -- e.g. header buttons that grey when there is
-- nothing left to undo. nil until the first entry is pushed, so a consumer that
-- registers early asks for it rather than reading the field once.
function SettingsUndo:GetStack() return GetStack() end
