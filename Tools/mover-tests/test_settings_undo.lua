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
        -- FIVE arguments, as GUI.lua's hook takes them: the kit forwards the
        -- widget's own commit callback after the label, and the host passes it
        -- straight through.
        onSettingWritten = function(db, key, value, label, applyFn)
            h.written[#h.written + 1] =
                { db = db, key = key, value = value, label = label, apply = applyFn }
            SU:OnSettingWritten(db, key, value, label, applyFn)
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
-- `applyFn` is the widget's own commit callback -- what CreateSlider passes as
-- `callback`, what the popout row passes as `opts.onToggle`. Optional here for
-- the same reason it is optional there.
local function widgetWrite(db, key, value, label, applyFn)
    if host:Call("interceptWrite", db, key, value) then return false end
    db[key] = value
    host:Call("onSettingWritten", db, key, value, label, applyFn)
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
-- 5b. ONE APPLY FOR THE WHOLE GROUP
-- ------------------------------------------------------------
-- The writes inside a group come from GroupActions, which applies nothing of
-- its own: the popout footer's Reset button writes N keys and then runs the
-- group's apply ONCE. An undo of that reset has no button press behind it to do
-- the same, so the apply is handed to BeginGroup and the collapsed entry
-- carries it -- one for the group, not one per key.
-- ============================================================
do
    reset()
    local order = {}
    -- Reads the live table, so WHEN it ran is visible in what it saw.
    local groupApply = function() order[#order + 1] = party.frameWidth end

    SU:BeginGroup("Border", groupApply)
    widgetWrite(party, "frameWidth", 150, "Frame Width")
    widgetWrite(party, "frameShowBorder", true, "Show Border")
    SU:EndGroup()

    eq(depth(), 1, "group apply: still one collapsed entry")
    local e = stack():PeekEntry()
    eq(e.label, "Border", "group apply: ...still labelled with the group's name")
    check(e.apply == groupApply, "group apply: ...and carrying the group's apply, by reference")
    eq(#order, 0, "group apply: opening and closing a group does not run it")

    SU:Undo()
    eq(#order, 1, "group apply: ☠ one press, ONE apply -- not one per key")
    eq(order[1], 100, "group apply: ☠ ...and it ran AFTER the keys were restored, not between them")
    eq(party.frameShowBorder, false, "group apply: (both keys did go back)")

    SU:Redo()
    eq(#order, 2, "group apply: redo runs it again")
    eq(order[2], 150, "group apply: ...after the keys went forward")

    -- An EMPTY group is no entry, and its apply must not be left armed for
    -- whatever group opens next.
    reset()
    SU:BeginGroup("Border", groupApply)
    widgetWrite(party, "frameWidth", 100, "Frame Width")     -- zero delta
    SU:EndGroup()
    eq(depth(), 0, "group apply: a group that changed nothing is still no entry")

    SU:BeginGroup("Other")
    widgetWrite(party, "frameWidth", 150, "Frame Width")
    SU:EndGroup()
    eq(depth(), 1, "group apply: the next group pushed normally")
    check(stack():PeekEntry().apply == nil,
        "group apply: ☠ ...and the abandoned apply did not leak into it")

    -- NESTED groups mirror the lib's refcount: only the outermost becomes an
    -- entry, so only the outermost apply is the group's.
    reset()
    local outer = function() end
    local inner = function() end
    SU:BeginGroup("Outer", outer)
    SU:BeginGroup("Inner", inner)
    widgetWrite(party, "frameWidth", 150, "Frame Width")
    SU:EndGroup()
    eq(depth(), 0, "nested group apply: an inner close pushes nothing")
    SU:EndGroup()
    eq(depth(), 1, "nested group apply: the outer one does")
    check(stack():PeekEntry().apply == outer,
        "nested group apply: and the OUTER group's apply is the one that landed")

    -- The fence goes through a half-open group too: a group left open across a
    -- profile switch must not hand its apply to the next one.
    reset()
    SU:BeginGroup("Border", groupApply)
    widgetWrite(party, "frameWidth", 150, "Frame Width")
    SU:Clear()
    SU:EndGroup()
    eq(depth(), 0, "group apply: a group left open across the fence pushes nothing")
    widgetWrite(party, "frameWidth", 180, "Frame Width")
    eq(depth(), 1, "group apply: ...and the next plain write pushes immediately -- no group left open")
    check(stack():PeekEntry().apply == nil, "group apply: ...carrying no apply of the abandoned group's")
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

-- ============================================================
-- 11b. THE ENTRY CARRIES THE APPLY
-- ------------------------------------------------------------
-- ☠ THE BUG THIS EXISTS FOR: "undo and redo update the values but do not
-- refresh the frames." Restoring a value is not the same thing as reverting an
-- edit. For a great many settings the work that makes the change VISIBLE lives
-- in the WIDGET's commit callback -- a version bump the frames read, a targeted
-- refresher the generic sweep does not cover (LightweightUpdateBorder is the
-- only path that re-borders live RAID frames), a secure-header re-apply. The
-- user's own edit runs that callback; an undo that only wrote the value did not,
-- so the number moved and the frames did not.
--
-- So the kit forwards the callback as `onSettingWritten`'s fifth argument, the
-- entry stores it, and the apply replays it. The rules below are the ones that
-- make replaying it safe rather than a second way to break the undo stack.
-- ============================================================
do
    -- ---- it is stored, by reference ---------------------------------
    reset()
    local applied, suspendedDuring = 0, nil
    local applyFn = function()
        applied = applied + 1
        suspendedDuring = SU:IsSuspended()
    end
    widgetWrite(party, "frameBorderSize", 4, "Border Thickness", applyFn)

    local e = stack():PeekEntry()
    check(e.apply == applyFn, "apply: the entry carries the widget's commit callback, by reference")
    eq(applied, 0, "apply: recording it did not run it -- the widget already did")

    -- ---- undo replays it, once, suspended ---------------------------
    local updatesBefore = updates
    SU:Undo()
    eq(applied, 1, "apply: ☠ the undo replayed it -- exactly once")
    check(suspendedDuring == true,
        "apply: ☠ ...with recording SUSPENDED, because the callback may write settings of its own")
    check(SU:IsSuspended() == false, "apply: ...and the suspension was balanced on the way out")
    check(updates == updatesBefore + 1,
        "apply: ☠ the generic sweep STILL ran -- the apply is an addition to it, not a replacement")
    eq(depth(), 0, "apply: and the replay recorded nothing of its own")

    SU:Redo()
    eq(applied, 2, "apply: redo replays the same callback -- an undo and a redo are the same apply")

    -- ---- a write made BY the callback is part of the apply -----------
    -- A linked-section sync writes the mirrored key from inside the commit.
    -- Those writes are the apply finishing its job, not new edits, and an entry
    -- for one would be an undo press that the user cannot account for.
    reset()
    local syncing = function() widgetWrite(party, "frameShowBorder", true, "Show Border") end
    widgetWrite(party, "frameWidth", 140, "Frame Width", syncing)
    eq(depth(), 1, "callback write: one edit, one entry")
    SU:Undo()
    eq(party.frameWidth, 100, "callback write: the undo restored the value")
    check(party.frameShowBorder == true, "callback write: ...and the callback's own write landed")
    eq(depth(), 0, "callback write: ☠ but it was NOT recorded -- the apply runs suspended")
    check(SU:CanRedo(), "callback write: the entry went to the redo branch, as any other would")

    -- ---- a DEAD callback must cost the undo nothing ------------------
    -- The closure belongs to the PAGE that built the widget and may capture
    -- objects the page has since torn down. pcall'd for that reason: an undo
    -- that errored on a stale closure would leave the value restored, the frames
    -- unrefreshed and the entry stranded.
    reset()
    local dead = function() error("the page that built this is gone") end
    widgetWrite(party, "frameWidth", 140, "Frame Width", dead)
    updatesBefore, host.refreshed = updates, 0
    local ok = SU:Undo()
    check(ok, "dead apply: the undo still reported success")
    eq(party.frameWidth, 100, "dead apply: ...the value was still restored")
    check(updates == updatesBefore + 1, "dead apply: ☠ ...and the fallback sweep still ran")
    eq(host.refreshed, 1, "dead apply: ...and the page was still repainted")
    check(SU:CanRedo() and not SU:CanUndo(), "dead apply: the entry moved to the redo branch as normal")
    check(SU:IsSuspended() == false, "dead apply: ☠ and the suspension was balanced -- recording is back on")
    SU:Redo()
    eq(party.frameWidth, 140, "dead apply: redo still works over a callback that throws")

    -- ---- a gesture merges to ONE apply ------------------------------
    reset()
    applied = 0
    local drag = function() applied = applied + 1 end
    SU:OnDragStart()
    widgetWrite(party, "frameWidth", 110, "Frame Width", drag)
    widgetWrite(party, "frameWidth", 120, "Frame Width", drag)
    widgetWrite(party, "frameWidth", 130, "Frame Width", drag)
    SU:OnDragStop()
    eq(depth(), 1, "gesture apply: the drag is one entry, as ever")
    check(stack():PeekEntry().apply == drag, "gesture apply: carrying the widget's commit callback")
    SU:Undo()
    eq(applied, 1, "gesture apply: ☠ one press, one apply -- not one per step crossed")

    -- ---- a non-function in the slot is ignored ----------------------
    reset()
    widgetWrite(party, "frameWidth", 140, "Frame Width", "not a function")
    check(stack():PeekEntry().apply == nil, "apply: a non-function fifth argument is discarded, not stored")
    SU:Undo()
    eq(party.frameWidth, 100, "apply: ...and the undo is the plain one it always was")
end

-- ============================================================
-- 11c. A HOST THAT DOES NOT FORWARD ONE
-- The argument is additive and optional at BOTH ends: DandersMover's host
-- publishes a three-argument hook, and the kit calls every hook positionally.
-- An entry with no apply is exactly the entry this engine pushed before the
-- argument existed -- value plus the generic sweep.
-- ============================================================
do
    reset()
    -- The older hook shape, spelled out: three arguments, nothing forwarded.
    host.hooks.onSettingWritten = function(db, key, value)
        host.written[#host.written + 1] = { db = db, key = key, value = value }
        SU:OnSettingWritten(db, key, value)
    end

    local applyFn = function() error("this must never run") end
    widgetWrite(party, "frameWidth", 140, "Frame Width", applyFn)

    eq(depth(), 1, "legacy host: the write was recorded")
    local e = stack():PeekEntry()
    check(e.apply == nil, "legacy host: with no apply, because the host never forwarded one")
    eq(e.label, "Frame Width", "legacy host: ...and no label either, so the key was prettified")

    local updatesBefore = updates
    SU:Undo()
    eq(party.frameWidth, 100, "legacy host: the undo restores the value")
    check(updates == updatesBefore + 1, "legacy host: ...and the generic sweep is the whole apply")
    SU:Redo()
    eq(party.frameWidth, 140, "legacy host: redo likewise")
end

-- ============================================================
-- 12. THE OLD COLOUR PICKER'S SESSION
-- ------------------------------------------------------------
-- DandersFrames_Options/GUI/SettingsWidgets.lua's CreateColorPicker drives
-- Blizzard's ColorPickerFrame, and that widget does not WRITE a colour -- it
-- mutates the stored table field by field, dozens of times, as the user drags.
-- There is no single write to bracket, so that factory calls the engine's two
-- halves DIRECTLY around each mutation and holds a gesture open for the length
-- of the picking session.
--
-- The factory itself cannot be loaded here (it is 3000 lines of live client
-- surface), so what is pinned is the PATTERN it uses -- and the pattern is the
-- part that has to hold, because every one of its rules is an invariant the
-- engine provides rather than something the factory can check for itself:
--   * a session of N ticks is ONE entry, spanning the whole session;
--   * a CANCELLED session is no entry at all;
--   * a session re-entered while the picker is still up splits cleanly, and
--     leaves the gesture refcount where it found it.
--
-- ⚠ THE TABLE IS MUTATED IN PLACE AND COMMITTED BY REFERENCE. That is the shape
-- that makes this worth a test of its own: `value` and `db[key]` are the same
-- table, so the engine's landed-plainly check compares a table with itself, and
-- everything that makes the entry meaningful comes from the COPIES it takes on
-- either side.
-- ============================================================

-- One drag tick, exactly as swatchFunc / opacityFunc spell it.
local function pickerTick(db, key, r, g, b, a, label)
    SU:OnInterceptWrite(db, key, nil)      -- BEFORE: db[key] still holds the old colour
    local c = db[key]
    c.r, c.g, c.b, c.a = r, g, b, a        -- the mutation, in place
    SU:OnSettingWritten(db, key, db[key], label)   -- AFTER, by reference
end

do
    -- ---- a completed session ----------------------------------------
    reset()
    local live = party.frameBorderColor    -- the table the picker will mutate
    SU:BeginGesture()
    pickerTick(party, "frameBorderColor", 0.8, 0,   0,   1, "Border Colour")
    pickerTick(party, "frameBorderColor", 0.5, 0.2, 0,   1, "Border Colour")
    pickerTick(party, "frameBorderColor", 0,   0,   1,   1, "Border Colour")
    eq(depth(), 0, "colour session: nothing is pushed while the picker is open")

    SU:EndGesture()
    eq(depth(), 1, "colour session: ☠ three drag ticks are ONE entry")
    local e = stack():PeekEntry()
    check(deepsame(e.old, { r = 1, g = 0, b = 0, a = 1 }),
        "colour session: `old` is the colour from before the picker opened")
    check(deepsame(e.new, { r = 0, g = 0, b = 1, a = 1 }),
        "colour session: ...and `new` is the one the user settled on")
    check(party.frameBorderColor == live,
        "colour session: (the live table was mutated in place, never replaced)")
    check(e.old ~= live and e.new ~= live,
        "colour session: ☠ neither end of the entry is the live table, or both would read as the last tick")

    SU:Undo()
    check(deepsame(party.frameBorderColor, { r = 1, g = 0, b = 0, a = 1 }),
        "colour session: one undo press restores the colour the user started with")
    SU:Redo()
    check(deepsame(party.frameBorderColor, { r = 0, g = 0, b = 1, a = 1 }),
        "colour session: ...and redo puts the picked one back")

    -- ---- a cancelled session ----------------------------------------
    -- cancelFunc restores originalColor by the same mutate-and-commit, so to the
    -- engine it is one more tick that happens to land on the starting value. The
    -- merged entry is then zero-delta, and zero-delta entries are dropped.
    reset()
    SU:BeginGesture()
    pickerTick(party, "frameBorderColor", 0, 1, 0, 1, "Border Colour")
    pickerTick(party, "frameBorderColor", 0, 1, 1, 1, "Border Colour")
    pickerTick(party, "frameBorderColor", 1, 0, 0, 1, "Border Colour")   -- the cancel restore
    SU:EndGesture()
    eq(depth(), 0, "cancelled session: ☠ a cancelled pick leaves NOTHING to undo")
    check(deepsame(party.frameBorderColor, { r = 1, g = 0, b = 0, a = 1 }),
        "cancelled session: ...and the colour is back where it started")
    check(SU:CanUndo() == false, "cancelled session: the undo button has nothing to offer")

    -- ---- a session re-entered while the picker is still up -----------
    -- The factory's OnClick closes an already-open gesture before opening its
    -- own, because ColorPickerFrame is a singleton and a Setup on a shown picker
    -- never fires the OnHide that would otherwise have closed the first one.
    reset()
    SU:BeginGesture()
    pickerTick(party, "frameBorderColor", 0, 1, 0, 1, "Border Colour")
    SU:EndGesture()                        -- the re-entry guard, then the new session
    SU:BeginGesture()
    pickerTick(party, "frameBorderColor", 0, 0, 1, 1, "Border Colour")
    SU:EndGesture()

    eq(depth(), 2, "re-entered session: two sessions are two entries, not one merged blur")
    check(deepsame(stack().entries[1].new, { r = 0, g = 1, b = 0, a = 1 }),
        "re-entered session: the first entry ends where the first session did")
    check(deepsame(stack().entries[2].old, { r = 0, g = 1, b = 0, a = 1 }),
        "re-entered session: ...and the second starts there")

    -- ☠ NO DEPTH LEAK. An unbalanced guard would leave the refcount above zero,
    -- and every write for the rest of the session would silently accumulate into
    -- a gesture that never closes -- which looks exactly like "undo stopped
    -- working" and nothing else in this suite would catch it.
    widgetWrite(party, "frameWidth", 140, "Frame Width")
    eq(depth(), 3, "re-entered session: ☠ a plain write after it pushes immediately -- no gesture left open")
    SU:Undo(); SU:Undo(); SU:Undo()
    check(SU:CanUndo() == false, "re-entered session: three presses empty the stack -- the count was right")
end

-- ============================================================
-- 13. THE COMPANION'S WIDGETS GO THROUGH THE HOST HOOKS
-- ------------------------------------------------------------
-- SOURCE, not behaviour -- the settings-panel factories are load-on-demand
-- companion files full of live frame calls and cannot be loaded here. What they
-- USED to do is the whole reason this section exists: each of them wrote out the
-- runtime-redirect gate and the override record by hand, which is a second
-- spelling of what GUI.lua's two hooks already do -- and a write that skips the
-- hooks is a write the engine above never sees. Every checkbox, edit box and
-- media dropdown in the panel was un-undoable because of it.
--
-- The needles are CALL SHAPES, not line numbers and not bare names: the prose in
-- these files talks about HandleRuntimeWrite freely, so only the fully qualified
-- call is counted.
-- ============================================================
do
    local function countOf(src, needle)
        local n, from = 0, 1
        while true do
            local s = src:find(needle, from, true)
            if not s then return n end
            n, from = n + 1, s + 1
        end
    end

    local widgets  = options_file_source("GUI/SettingsWidgets.lua")
    local controls = options_file_source("GUI/Controls.lua")

    -- ---- the inlined gate is gone -----------------------------------
    eq(countOf(widgets, "DF.AutoProfilesUI:HandleRuntimeWrite("), 0,
       "companion: SettingsWidgets no longer calls the redirect gate by hand")
    eq(countOf(controls, "DF.AutoProfilesUI:HandleRuntimeWrite("), 0,
       "companion: ...and neither does Controls")

    -- ---- ...replaced by the bracket ---------------------------------
    -- Two apiece: the checkbox and the edit box in SettingsWidgets, the texture
    -- and font dropdowns in Controls. The colour picker is deliberately NOT one
    -- of them -- it has no redirect gate to route through and never had.
    eq(countOf(widgets, 'GUI:Call("interceptWrite"'), 2,
       "companion: the checkbox and the edit box ask the host before they write")
    eq(countOf(widgets, 'GUI:Call("onSettingWritten"'), 2,
       "companion: ...and tell it afterwards")
    eq(countOf(controls, 'GUI:Call("interceptWrite"'), 2,
       "companion: the texture and font dropdowns ask too")
    eq(countOf(controls, 'GUI:Call("onSettingWritten"'), 2,
       "companion: ...and announce")

    -- ---- the colour picker's direct wiring --------------------------
    -- Three mutation sites -- the swatch, the opacity bar and the cancel restore
    -- -- each bracketed by the engine's own pair, inside one gesture.
    eq(countOf(widgets, "SU:OnInterceptWrite(dbTable, dbKey"), 3,
       "companion: every colour mutation captures first")
    eq(countOf(widgets, "SU:OnSettingWritten(dbTable, dbKey"), 3,
       "companion: ...and commits after, the cancel restore included")
    check(countOf(widgets, "SU:BeginGesture()") == 1 and countOf(widgets, "SU:EndGesture()") == 1,
       "companion: the picking session opens and closes exactly one gesture")

    -- ☠ AND IT OPENS AFTER SETUP. Setting up an ALREADY SHOWN picker takes the
    -- frame down and puts it back, firing the OnHide that closes the gesture --
    -- so a gesture opened before the setup call is closed by the client
    -- mid-setup, and every drag tick that follows pushes an entry of its own.
    -- Nothing else here can see that: it is an ordering bug in a file this suite
    -- cannot load, and in game it looks like the undo stack filling with noise.
    local setupAt = widgets:find("ColorPickerFrame:SetupColorPickerAndShow(info)", 1, true)
    local beginAt = widgets:find("SU:BeginGesture()", 1, true)
    check(setupAt ~= nil and beginAt ~= nil and beginAt > setupAt,
       "companion: ☠ the picking gesture opens AFTER the picker is set up, not before")

    -- ---- ...and every one of them hands over its COMMIT ---------------
    -- The fifth argument, at every announcing site in the panel. Behaviour is
    -- pinned on the slider (test_widgets_slider.lua drives the real factory);
    -- these files cannot be loaded, so the CALL SHAPE is what stands in. A site
    -- that announces the write but not the callback is a control the user can
    -- undo and see nothing happen -- which is the bug this argument exists for,
    -- and it is invisible from every other angle.
    --
    -- Five in SettingsWidgets: the checkbox, the edit box, and the colour
    -- picker's three mutation sites. Two in Controls: the texture and font
    -- dropdowns.
    eq(countOf(widgets, ", label, callback)"), 5,
       "companion: every announcing site in SettingsWidgets hands over its commit callback")
    eq(countOf(controls, ", label, callback)"), 2,
       "companion: ...and both of Controls' media dropdowns do too")

    -- ---- the kit's own four, and the popout row's ---------------------
    local kit = ui_file_source("Widgets.lua")
    eq(countOf(kit, ", label, callback)"), 4,
       "kit: the slider (drag and typed), the align grid and the dropdown all forward their onChanged")
    local prow = ui_file_source("PopoutRow.lua")
    eq(countOf(prow, "row._title, opts.onToggle)"), 1,
       "kit: ...and the popout row's tick forwards onToggle, which is ITS commit")
end
