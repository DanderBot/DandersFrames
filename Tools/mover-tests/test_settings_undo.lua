local NS = ...

-- ============================================================
-- SETTINGS UNDO -- DandersFrames/Core/SettingsUndo.lua
-- ------------------------------------------------------------
-- The recording engine behind the settings write bracket. It never sees a
-- widget: it sees the host's two hooks, `interceptWrite` (fired BEFORE the write,
-- while db[key] is still the old value) and `onSettingWritten` (fired after it
-- landed), and everything it knows about an edit comes from that pair.
--
-- What is pinned here is what fails SILENTLY in game -- an undo button that
-- restores a value into a table nothing reads, a drag that leaves twenty entries
-- behind it, a press-and-hold preview that the user can "undo":
--
--   1. THE PAIR IS THE RECORD. A capture with no commit is nothing, and a commit
--      with no capture is nothing. A REDIRECTED write (an auto layout claiming
--      it) never reaches the second half, so it never becomes an entry.
--   2. ONLY A PLAIN WRITE COUNTS. A customSet widget announces a value that is
--      not in db[key]; an entry built from it would restore into the wrong place.
--   3. ONE GESTURE, ONE ENTRY. A slider fires the commit hook once per step
--      CROSSED. The gesture bracket merges them; two separate gestures stay two
--      entries.
--   4. AN UNDO IS ITSELF A BRACKETED WRITE, and it is recorded by nobody -- the
--      engine suspends itself across the apply, or undo would be un-undoable.
--   5. VALUES ARE DEEP-COPIED IN BOTH DIRECTIONS. A colour is a table, and an
--      entry holding the LIVE one describes whatever the setting became later.
--
-- The stack itself (DandersUndo-1.0) is the real library, loaded by run.py.
-- ============================================================

local DF = {}
load_df_file_into("Core/SettingsUndo.lua", DF)
local SU = DF.SettingsUndo

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

-- ============================================================
-- THE HOST, WIRED THE WAY DandersFrames/GUI/GUI.lua WIRES IT
-- The engine calls are INSIDE the hooks rather than beside them, so the order
-- the real host uses is the order under test: the capture is taken as the FIRST
-- thing interceptWrite does (before the redirect answer), and the commit is the
-- LAST thing onSettingWritten does (after the auto-profile half).
-- ============================================================
local host
local function fakeHost(redirect)
    local h = { intercepted = {}, written = {}, refreshed = 0, SelectedMode = "party" }
    h.hooks = {
        interceptWrite = function(db, key, value)
            h.intercepted[#h.intercepted + 1] = { db = db, key = key, value = value }
            SU:OnInterceptWrite(db, key, value)
            return redirect and redirect[key] and true or false
        end,
        onSettingWritten = function(db, key, value, label)
            h.written[#h.written + 1] = { db = db, key = key, value = value, label = label }
            SU:OnSettingWritten(db, key, value, label)
        end,
    }
    function h:Call(name, ...)
        local fn = self.hooks[name]
        if not fn then return nil end
        return fn(...)
    end
    function h:RefreshCurrentPage() h.refreshed = h.refreshed + 1 end
    return h
end

-- The kit's bracket, spelled once: this is what every db-bound widget does.
local function widgetWrite(db, key, value, label)
    if host:Call("interceptWrite", db, key, value) then return false end
    db[key] = value
    host:Call("onSettingWritten", db, key, value, label)
    return true
end

-- ...and the shape a `customSet` widget makes: the bracket runs in full, but the
-- value goes somewhere that is not db[key].
local function customSetWrite(db, key, value, elsewhere)
    if host:Call("interceptWrite", db, key, value) then return false end
    elsewhere[key] = value
    host:Call("onSettingWritten", db, key, value)
    return true
end

local party, raid, updates

-- A clean world: fresh tables, a fresh host, an empty stack. Called at the head
-- of every block, because the engine is a singleton and a stack left full by the
-- block above would make the next block's counts read as passes.
local function reset(redirect)
    party = { frameWidth = 100, frameShowBorder = false,
              frameBorderColor = { r = 1, g = 0, b = 0, a = 1 } }
    raid  = { frameWidth = 60 }
    DF.db = { party = party, raid = raid }
    DF._realRaidDB = nil
    host = fakeHost(redirect)
    DF.GUI = host
    DF.GUIFrame = { _shown = true }
    function DF.GUIFrame:IsShown() return self._shown end
    updates = 0
    DF.UpdateAll = function() updates = updates + 1 end
    SU:Clear()
end

local function stack() return SU:GetStack() end
local function depth() local s = stack(); return #s.entries end

-- ============================================================
-- 1. THE MODULE LOADED, AND IT BROUGHT THE REAL STACK
-- ============================================================
do
    check(type(SU) == "table", "SettingsUndo: the module loaded and installed DF.SettingsUndo")
    for _, name in ipairs({ "OnInterceptWrite", "OnSettingWritten", "OnDragStart", "OnDragStop",
                            "BeginGesture", "EndGesture", "BeginGroup", "EndGroup",
                            "Suspend", "Resume", "Undo", "Redo", "Clear",
                            "CanUndo", "CanRedo", "GetStack" }) do
        check(type(SU[name]) == "function", "SettingsUndo: " .. name .. " is there")
    end
    check(SU.BeginGesture == SU.OnDragStart and SU.EndGesture == SU.OnDragStop,
        "SettingsUndo: BeginGesture/EndGesture are the drag pair under another name")

    local s = SU:GetStack()
    check(type(s) == "table" and type(s.Push) == "function",
        "SettingsUndo: it resolved the real DandersUndo-1.0 stack")
    check(SU.stack == s, "SettingsUndo: ...and published it for a consumer that wants its Changed callback")
end

-- ============================================================
-- 2. CAPTURE, COMMIT, AND THE UNDO THAT GOES BACK THROUGH THE BRACKET
-- ============================================================
do
    reset()
    check(SU:CanUndo() == false, "fresh: there is nothing to undo yet")

    widgetWrite(party, "frameWidth", 140, "Frame Width")

    eq(depth(), 1, "capture+commit: one bracketed write is one entry")
    local e = stack():PeekEntry()
    eq(e.old, 100, "capture+commit: `old` is what interceptWrite saw before the write")
    eq(e.new, 140, "capture+commit: ...and `new` is what landed")
    eq(e.label, "Frame Width", "capture+commit: the widget's label named the entry")
    eq(e.mode, "party", "capture+commit: the mode was derived from the table it wrote to")
    check(SU:CanUndo() and not SU:CanRedo(), "capture+commit: undo is now offered, redo is not")

    -- The undo is a WRITE, not an assignment: it goes back out through the same
    -- two hooks, so an auto layout redirects it exactly as it would the user's
    -- own edit and a layout being edited records it as the override it is.
    local interceptsBefore, writtenBefore = #host.intercepted, #host.written
    local updatesBefore = updates
    local ok, undone = SU:Undo()

    check(ok, "undo: it reported success")
    check(undone == e, "undo: ...and handed back the entry it undid, for the toast to name")
    eq(party.frameWidth, 100, "undo: the value is back")
    eq(#host.intercepted, interceptsBefore + 1, "undo: the apply asked interceptWrite")
    eq(#host.written, writtenBefore + 1, "undo: ...and announced onSettingWritten after it")
    eq(host.written[#host.written].value, 100, "undo: announcing the value it restored")
    check(updates == updatesBefore + 1, "undo: the frames were told to update")
    eq(host.refreshed, 1, "undo: ...and the open settings page was refreshed")

    -- ☠ THE ONE THAT MAKES UNDO WORK AT ALL. That apply ran the full bracket,
    -- which is the exact thing the engine records -- so without the suspension it
    -- would push an entry for its own undo, and the stack would never empty.
    eq(depth(), 0, "undo: ☠ the apply recorded NOTHING -- the engine suspends itself across it")
    check(SU:CanRedo(), "undo: the entry moved to the redo branch instead")
    check(SU:CanUndo() == false, "undo: ...and there is nothing left to undo")

    check(SU:Undo() == false, "undo: an empty stack answers false rather than erroring")
end

-- ============================================================
-- 3. THE WRITES THAT MUST NOT BECOME ENTRIES
-- Three different ways for a bracketed write to be something OTHER than "the
-- user changed this setting", and all three look identical from the hook.
-- ============================================================
do
    -- (a) REDIRECTED. interceptWrite answered true, so the live table never
    -- moved and onSettingWritten never fired. The capture is simply abandoned.
    reset({ frameWidth = true })
    local landed = widgetWrite(party, "frameWidth", 140, "Frame Width")
    check(landed == false, "redirect: the kit skipped the write, as it does in game")
    eq(party.frameWidth, 100, "redirect: the live table is untouched")
    eq(depth(), 0, "redirect: ☠ and no entry -- undoing a write that never happened is nonsense")

    -- (b) A COMMIT WITH NO CAPTURE. Nothing in the addon should do this, which is
    -- exactly why it must be inert rather than guessed at: an entry whose `old`
    -- was invented is an undo that writes a value the user never had.
    reset()
    party.frameWidth = 140
    host:Call("onSettingWritten", party, "frameWidth", 140, "Frame Width")
    eq(depth(), 0, "no capture: an announcement with no matching capture is ignored")

    -- (c) customSet. The bracket ran in full and the value is real -- but it is
    -- not in db[key], so db[key] is not the store and an entry would restore into
    -- a table nothing reads.
    reset()
    local elsewhere = {}
    customSetWrite(party, "frameWidth", 140, elsewhere)
    eq(elsewhere.frameWidth, 140, "customSet: the value went where the widget put it")
    eq(party.frameWidth, 100, "customSet: ...which is not db[key]")
    eq(depth(), 0, "customSet: ☠ so nothing was recorded")

    -- (d) ZERO DELTA. A write that changed nothing is an undo step that visibly
    -- does nothing when pressed.
    reset()
    widgetWrite(party, "frameWidth", 100, "Frame Width")
    eq(depth(), 0, "zero delta: writing the value that was already there records nothing")

    -- ...and the same for a TABLE that only LOOKS new. Two colour tables with the
    -- same four numbers are one colour; `==` would call it a change.
    reset()
    widgetWrite(party, "frameBorderColor", { r = 1, g = 0, b = 0, a = 1 }, "Colour")
    eq(depth(), 0, "zero delta: ☠ a colour table equal by VALUE is not a change either")
end

-- ============================================================
-- 4. ONE GESTURE, ONE ENTRY
-- A slider fires the commit hook once per STEP CROSSED, so a drag across a bar
-- is twenty announcements of one thing the user did.
-- ============================================================
do
    reset()
    SU:OnDragStart()
    widgetWrite(party, "frameWidth", 110, "Frame Width")
    widgetWrite(party, "frameWidth", 120, "Frame Width")
    widgetWrite(party, "frameWidth", 130, "Frame Width")
    eq(depth(), 0, "gesture: nothing is pushed while the drag is open")
    SU:OnDragStop()

    eq(depth(), 1, "gesture: the whole drag is ONE entry")
    local e = stack():PeekEntry()
    eq(e.old, 100, "gesture: `old` is what it was before the drag started, not before the last step")
    eq(e.new, 130, "gesture: ...and `new` is where the user let go")

    -- A SECOND drag of the same slider is a second thing the user did. Coalescing
    -- across gestures would make one undo press jump back over both.
    SU:OnDragStart()
    widgetWrite(party, "frameWidth", 160, "Frame Width")
    SU:OnDragStop()
    eq(depth(), 2, "gesture: a later drag of the SAME key is a separate entry")
    eq(stack():PeekEntry().old, 130, "gesture: ...starting where the first one finished")

    -- Undo walks them back one gesture at a time.
    SU:Undo()
    eq(party.frameWidth, 130, "gesture: one undo press rewinds one gesture")
    SU:Undo()
    eq(party.frameWidth, 100, "gesture: ...and the next rewinds the other")

    -- A drag that ends where it began is not an edit.
    reset()
    SU:OnDragStart()
    widgetWrite(party, "frameWidth", 130, "Frame Width")
    widgetWrite(party, "frameWidth", 100, "Frame Width")
    SU:OnDragStop()
    eq(depth(), 0, "gesture: a drag that lands back on its starting value records nothing")

    -- The pair is REFCOUNTED, mirroring the host: the colour picker holds a drag
    -- open across the kit's own, and an inner stop must not close the outer one.
    reset()
    SU:OnDragStart()
    SU:OnDragStart()
    widgetWrite(party, "frameWidth", 150, "Frame Width")
    SU:OnDragStop()
    eq(depth(), 0, "gesture: an inner stop does not close a nested gesture")
    SU:OnDragStop()
    eq(depth(), 1, "gesture: ...the outer one does")

    -- A gesture that moved two different keys is two entries, in the order they
    -- first moved -- one closure per key, because that is what an apply needs.
    reset()
    SU:OnDragStart()
    widgetWrite(party, "frameWidth", 150, "Frame Width")
    widgetWrite(party, "frameShowBorder", true, "Show Border")
    widgetWrite(party, "frameWidth", 170, "Frame Width")
    SU:OnDragStop()
    eq(depth(), 2, "gesture: two keys moved in one gesture are two entries")
    eq(stack().entries[1].key, "frameWidth", "gesture: pushed in the order the keys first moved")
    eq(stack().entries[1].new, 170, "gesture: ...the first key carrying its LAST value")
    eq(stack().entries[2].key, "frameShowBorder", "gesture: ...and the second key after it")
end

-- ============================================================
-- 5. GROUPS -- N WRITES, ONE PRESS TO PUT THEM BACK
-- What a "Reset Group" is: the user did one thing, so undoing it is one press.
-- ============================================================
do
    reset()
    SU:BeginGroup("Border")
    widgetWrite(party, "frameWidth", 150, "Frame Width")
    widgetWrite(party, "frameShowBorder", true, "Show Border")
    widgetWrite(party, "frameBorderColor", { r = 0, g = 1, b = 0, a = 1 }, "Colour")
    SU:EndGroup()

    eq(depth(), 1, "group: three writes collapsed into one entry")
    eq(stack():PeekEntry().label, "Border", "group: labelled with the group's name, not the last widget's")

    SU:Undo()
    eq(party.frameWidth, 100, "group: one press restored the first key")
    eq(party.frameShowBorder, false, "group: ...and the second")
    check(deepsame(party.frameBorderColor, { r = 1, g = 0, b = 0, a = 1 }),
        "group: ...and the third, table and all")
    eq(depth(), 0, "group: and the whole group left the undo stack together")

    SU:Redo()
    eq(party.frameWidth, 150, "group: redo puts all three back")
    check(deepsame(party.frameBorderColor, { r = 0, g = 1, b = 0, a = 1 }), "group: ...tables included")

    -- A group in which nothing actually changed is not an entry at all.
    reset()
    SU:BeginGroup("Border")
    widgetWrite(party, "frameWidth", 100, "Frame Width")
    SU:EndGroup()
    eq(depth(), 0, "group: a group whose writes all changed nothing pushes nothing")
end

-- ============================================================
-- 6. SUSPENSION -- THE WRITES THAT ARE NOT EDITS
-- A press-and-hold preview writes defaults out and the user's values back, both
-- through the bracket. Neither leg is something to undo.
-- ============================================================
do
    reset()
    SU:Suspend()
    widgetWrite(party, "frameWidth", 150, "Frame Width")
    widgetWrite(party, "frameShowBorder", true, "Show Border")
    SU:Resume()
    eq(party.frameWidth, 150, "suspend: the writes still land -- suspension is about the RECORD")
    eq(depth(), 0, "suspend: ...and nothing was recorded")

    check(SU:IsSuspended() == false, "suspend: balanced calls leave recording on")
    widgetWrite(party, "frameWidth", 160, "Frame Width")
    eq(depth(), 1, "suspend: recording resumed afterwards")
    eq(stack():PeekEntry().old, 150,
       "suspend: ☠ and the entry's `old` is the SUSPENDED value, not the one from before the hold")

    -- Refcounted: an inner Resume must not switch recording back on inside an
    -- outer suspension.
    reset()
    SU:Suspend()
    SU:Suspend()
    SU:Resume()
    check(SU:IsSuspended(), "suspend: an inner Resume does not lift a nested suspension")
    widgetWrite(party, "frameWidth", 150, "Frame Width")
    eq(depth(), 0, "suspend: ...so the write in between is still not recorded")
    SU:Resume()
    check(SU:IsSuspended() == false, "suspend: the outer Resume lifts it")

    -- A capture taken before a suspension is dropped, not held: the write it
    -- belonged to is about to land unrecorded, and keeping it would let the NEXT
    -- recorded write commit against a stale old value.
    reset()
    host:Call("interceptWrite", party, "frameWidth", 150)
    SU:Suspend()
    SU:Resume()
    party.frameWidth = 150
    host:Call("onSettingWritten", party, "frameWidth", 150, "Frame Width")
    eq(depth(), 0, "suspend: a capture taken before the suspension is dropped, not banked")
end

-- ============================================================
-- 7. ☠ VALUES ARE COPIED, IN BOTH DIRECTIONS
-- A colour is a table, and db[key] IS the table the widget handed over. An entry
-- that stored the live reference would describe whatever the setting became
-- later -- so undo would restore the value it was undoing.
-- ============================================================
do
    reset()
    local was = party.frameBorderColor          -- the table that is about to be replaced
    local handed = { r = 0, g = 1, b = 0, a = 1 }
    widgetWrite(party, "frameBorderColor", handed, "Colour")

    local e = stack():PeekEntry()
    check(e.old ~= was, "table value: `old` is a COPY of what was there, not the live reference")
    check(e.new ~= handed, "table value: ...and `new` is a copy of what was handed in")
    check(party.frameBorderColor == handed, "table value: (the live table did take the widget's own table)")

    -- The proof: mutate both the outgoing table and the live one, and the entry
    -- must still describe the edit that actually happened.
    was.r, was.g = 0.5, 0.5
    party.frameBorderColor.g = 0.25
    check(deepsame(e.old, { r = 1, g = 0, b = 0, a = 1 }),
        "table value: ☠ mutating the old table afterwards does not rewrite the entry")
    check(deepsame(e.new, { r = 0, g = 1, b = 0, a = 1 }),
        "table value: ☠ ...and neither does editing the setting again")

    SU:Undo()
    check(deepsame(party.frameBorderColor, { r = 1, g = 0, b = 0, a = 1 }),
        "table value: the undo restored the colour the user actually had")
    check(party.frameBorderColor ~= e.old,
        "table value: ...as a table of its own, so a later edit cannot rewrite the entry either")
end

-- ============================================================
-- 8. REDO, AND THE BRANCH A NEW EDIT THROWS AWAY
-- ============================================================
do
    reset()
    widgetWrite(party, "frameWidth", 140, "Frame Width")
    SU:Undo()
    eq(party.frameWidth, 100, "redo: undone first")

    local ok, entry = SU:Redo()
    check(ok, "redo: it reported success")
    check(entry ~= nil and entry.key == "frameWidth", "redo: ...and named what it redid")
    eq(party.frameWidth, 140, "redo: the value is forward again")
    eq(depth(), 1, "redo: the entry is back on the undo stack")
    check(SU:CanRedo() == false, "redo: and off the redo branch")
    check(SU:Redo() == false, "redo: an empty redo branch answers false")

    -- A fresh edit after an undo abandons the branch: the user chose a different
    -- future, and offering to redo the one they walked away from would apply a
    -- value they can no longer see anywhere.
    reset()
    widgetWrite(party, "frameWidth", 140, "Frame Width")
    SU:Undo()
    check(SU:CanRedo(), "redo branch: there is something to redo")
    widgetWrite(party, "frameWidth", 180, "Frame Width")
    check(SU:CanRedo() == false, "redo branch: ☠ a new edit discards it")
    eq(depth(), 1, "redo branch: ...leaving the new edit as the only entry")
end

-- ============================================================
-- 9. THE MODE GATE ON THE REFRESH
-- An entry knows which side of the profile it belongs to, because undoing a RAID
-- setting while the PARTY page is on screen must apply -- and must not repaint a
-- page showing different settings.
-- ============================================================
do
    reset()
    widgetWrite(raid, "frameWidth", 80, "Frame Width")
    eq(stack():PeekEntry().mode, "raid", "mode: a write to the raid table is a raid entry")

    host.SelectedMode = "party"
    host.refreshed = 0
    SU:Undo()
    eq(raid.frameWidth, 60, "mode: the undo applied even though the other mode is on screen")
    eq(host.refreshed, 0, "mode: ...but the party page was not repainted for it")
    check(updates > 0, "mode: the frames were updated regardless -- they show both")

    host.SelectedMode = "raid"
    host.refreshed = 0
    SU:Redo()
    eq(host.refreshed, 1, "mode: with the raid page on screen it IS repainted")

    -- A table that is neither side of the profile -- a designer proxy, a scratch
    -- table -- is a legal `nil` mode, and refreshes whenever the window is open.
    reset()
    local stranger = { frameWidth = 10 }
    widgetWrite(stranger, "frameWidth", 20, "Frame Width")
    check(stack():PeekEntry().mode == nil, "mode: a table that is neither side has no mode")
    host.SelectedMode = "raid"
    host.refreshed = 0
    SU:Undo()
    eq(host.refreshed, 1, "mode: ...and it refreshes whatever page is showing")

    -- Nothing is repainted when the window is closed.
    reset()
    widgetWrite(party, "frameWidth", 140, "Frame Width")
    DF.GUIFrame._shown = false
    host.refreshed = 0
    SU:Undo()
    eq(party.frameWidth, 100, "mode: an undo with the window closed still applies")
    eq(host.refreshed, 0, "mode: ...and refreshes no page")
end

-- ============================================================
-- 10. THE FALLBACK LABEL
-- For a write whose widget did not name itself. Not localised -- it is a db key
-- made readable, not a translated string.
-- ============================================================
do
    reset()
    widgetWrite(party, "frameWidth", 140)
    eq(stack():PeekEntry().label, "Frame Width", "label: an unlabelled write is named from its key")

    reset()
    widgetWrite(party, "frameShowBorder", true)
    eq(stack():PeekEntry().label, "Frame Show Border", "label: camelCase is split on every hump")
end

-- ============================================================
-- 11. THE FENCE
-- Clear is what a profile switch, an import, a reset and an auto-layout swap all
-- call: every entry names a table inside the profile being left behind.
-- ============================================================
do
    reset()
    widgetWrite(party, "frameWidth", 140, "Frame Width")
    widgetWrite(party, "frameShowBorder", true, "Show Border")
    SU:Undo()
    check(SU:CanUndo() and SU:CanRedo(), "clear: there is something on both stacks")

    SU:Clear()
    check(SU:CanUndo() == false, "clear: the undo stack is empty")
    check(SU:CanRedo() == false, "clear: ...and so is the redo branch")

    -- The in-flight state goes with it. A capture or a half-open gesture from the
    -- old profile must not commit against the new one.
    reset()
    SU:OnDragStart()
    widgetWrite(party, "frameWidth", 150, "Frame Width")
    SU:Clear()
    SU:OnDragStop()
    eq(depth(), 0, "clear: ☠ a gesture left open across the fence pushes nothing")

    reset()
    host:Call("interceptWrite", party, "frameWidth", 150)
    SU:Clear()
    party.frameWidth = 150
    host:Call("onSettingWritten", party, "frameWidth", 150, "Frame Width")
    eq(depth(), 0, "clear: ...and a capture taken before it can no longer commit")

    -- Recording still works afterwards: the fence empties the stack, it does not
    -- switch the engine off.
    widgetWrite(party, "frameWidth", 200, "Frame Width")
    eq(depth(), 1, "clear: the engine keeps recording after a fence")
end
