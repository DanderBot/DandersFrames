local NS = ...

-- ============================================================
-- TEST HOST -- UI:CreateSlider's PREVIEW/COMMIT SPLIT, and the colour
-- picker's drag participation.
--
-- What is under test is WHEN work runs, not what it does:
--
--   * a drag writes its value every tick, previews at most once per rendered
--     frame, and COMMITS EXACTLY ONCE, on release;
--   * a typed value is a commit too -- once, with no preview fallback;
--   * a slider with no lightweight previews nothing and still commits once;
--   * a mouseup that never reaches the bar (another frame took it) still ends
--     the drag, and the real mouseup that follows does not commit a second time;
--   * a host with no drag hooks keeps the older per-change behaviour;
--   * every colour-picker bar announces its drag, balanced 1:1.
--
-- ⚠ A FRESH NAMESPACE, NOT THE SHARED ONE. run.py loads every test_*.lua into
-- one runtime against one `NS.__DandersUI`, and this file installs the REAL
-- Widgets.lua and ColorPicker.lua -- which would replace factories the popout
-- and panel suites built their fixtures from. `load_ui_file_into` takes a
-- namespace of the caller's choosing, so everything below is private to this
-- file.
--
-- ☠ Every global this file replaces (CreateFrame, C_Timer, ...) is restored at
-- the end, or the next file inherits it.
-- ============================================================

local prevCreateFrame, prevTimer = CreateFrame, C_Timer
local prevCreateColor, prevCursor = CreateColor, GetCursorPosition
local prevSpecial, prevMouseDown = UISpecialFrames, IsMouseButtonDown

-- ---- the library table this file owns ------------------------------
local ns = {}
local UI = {
    _state = {},
    _priv  = {},
    MEDIA  = "",
    Colors = {
        panel   = { r = 0.12, g = 0.12, b = 0.12, a = 1 },
        element = { r = 0.18, g = 0.18, b = 0.18, a = 1 },
        border  = { r = 0.25, g = 0.25, b = 0.25, a = 1 },
        hover   = { r = 0.22, g = 0.22, b = 0.22, a = 1 },
        -- ColorPicker.lua reads this one at FILE SCOPE (the title colour), so a
        -- palette that stops at the slider's six would nil-index on load.
        accent  = { r = 0.45, g = 0.45, b = 0.95, a = 1 },
        text    = { r = 0.9,  g = 0.9,  b = 0.9 },
        textDim = { r = 0.5,  g = 0.5,  b = 0.5 },
        -- The amber notice token, mirrored from Theme.lua's C_NOTICE. Widgets.lua
        -- reads it at FILE SCOPE for the modified-default dot.
        notice  = { r = 0.91, g = 0.66, b = 0.25, a = 1 },
    },
    -- The slot heights Theme.lua owns. CreateSlider stamps the slider one onto
    -- its container at build time, so it has to exist before the load.
    RowHeight = { slider = 50, checkbox = 35 },
    RowGap = 14,
}
ns.__DandersUI = UI

-- Pixel snapping is Theme.lua's (not loadable headless), and CreateSlider reads
-- it at FILE SCOPE. Identity is the right stand-in: the tests are about call
-- counts, not about where the bar lands to the half pixel.
function UI.SnapLen(_, n) return n end
function UI.SnapHeightEven(_, n) return n end
function UI.StyleScrollBar() end
function UI._priv.CreateElementBackdrop(frame) return frame end
function UI._priv.CreatePanelBackdrop(frame) return frame end

local ACCENT = { r = 0.45, g = 0.45, b = 0.95, a = 1 }
function UI:GetAccent() return ACCENT end

-- The hook plumbing, verbatim from Core.lua (a headless run never loads it).
function UI:Hook(name)
    local h = rawget(self, "hooks")
    return h and h[name] or nil
end
function UI:Call(name, ...)
    local fn = self:Hook(name)
    if not fn then return nil end
    return fn(...)
end

-- ---- frame stub -----------------------------------------------------
-- ☠ A MISSING DATA FIELD MUST READ nil, NOT A FUNCTION. FakeUIFrame answers
-- every unknown key with a no-op function, which is right for METHODS and wrong
-- for STATE: `if not parent.ThemeListeners then ... end` would keep that
-- function and table.insert would error on it.
local DATA_KEYS = {
    ThemeListeners = true, UpdateOverrideIndicators = true, tooltip = true,
    tooltipText = true, tooltipSubText = true, tooltipSpellID = true,
    searchEntry = true, alphaInput = true, colorData = true, colorIndex = true,
    onChangeCallback = true, onAcceptCallback = true, onCancelCallback = true,
    appliedColor = true, skipOnChange = true, defaultColor = true,
    hasAlpha = true, RefreshSavedSwatches = true, AddToRecent = true,
    defaultBtn = true, RegisterScaledSurface = true, CreateSegmentToggle = true,
    dragBubble = true,
}
local function dataAwareMeta(_, k)
    if DATA_KEYS[k] then return nil end
    if type(k) == "string" and k:byte(1) == 95 then return nil end   -- "_"
    return function() end
end

CreateFrame = function(kind, _, parent)
    local f = FakeUIFrame()
    setmetatable(f, { __index = dataAwareMeta })
    f._kind = kind
    f._children = {}
    f._parent = parent
    f.GetParent = function(self) return self._parent end
    f.SetParent = function(self, p) self._parent = p end
    if kind == "Slider" then
        -- SetValue FIRES OnValueChanged, as the real widget does -- that is how a
        -- drag tick reaches the handler, and it is also what makes the file's own
        -- `suppressCallback = true; SetValue(v)` guard mean anything here.
        f._value = 0
        f.SetValue = function(self, v)
            self._value = v
            local fn = self._scripts.OnValueChanged
            if fn then fn(self, v) end
        end
        f.GetValue = function(self) return self._value end
    end
    if type(parent) == "table" then
        local kids = rawget(parent, "_children")
        if not kids then kids = {}; parent._children = kids end
        kids[#kids + 1] = f
    end
    return f
end
C_Timer = { After = function(_, fn) fn() end }

load_ui_file_into("Widgets.lua", ns)

-- ---- a recording host ----------------------------------------------
-- The hooks a slider fires, counted. `dragging` is the host's OWN answer to
-- isDragging, which the widget asks before committing a non-drag change; it
-- follows onDragStart/onDragStop the way the real host's refcount does.
local function newHost(withDragHooks)
    local log = { refresh = 0, refreshNow = 0, onDragStart = 0, onDragStop = 0, count = 0 }
    local hooks = {
        L = setmetatable({}, { __index = function(_, k) return k end }),
        refresh    = function() log.refresh = log.refresh + 1 end,
        refreshNow = function() log.refreshNow = log.refreshNow + 1 end,
    }
    if withDragHooks then
        hooks.onDragStart = function(lightFn, name)
            log.onDragStart = log.onDragStart + 1
            log.count = log.count + 1
            log.lastName = name
            log.lastLight = lightFn
        end
        hooks.onDragStop = function()
            log.onDragStop = log.onDragStop + 1
            log.count = log.count - 1
        end
        hooks.isDragging = function() return log.count > 0 end
    end
    return setmetatable({ hooks = hooks }, { __index = UI }), log
end

-- The EditBox a slider builds for its numeric readout. The factory does not
-- publish it, so it is found by kind among the container's children rather than
-- by index -- an extra child (the tooltip hit frame) must not move it.
local function inputOf(container)
    for _, child in ipairs(container._children) do
        if child._kind == "EditBox" then return child end
    end
end

-- The thumb texture the drag bubble is anchored to. Found by its SIZE rather
-- than by index: it is the only 12x16 region the bar builds, and an extra
-- texture appearing on the slider (an override indicator, a future state
-- overlay) must not silently hand the anchor assertions a different object.
local function thumbOf(sl)
    for _, t in ipairs(sl._textures) do
        if t:GetWidth() == 12 and t:GetHeight() == 16 then return t end
    end
end

-- A parent built by THIS file's CreateFrame, not the shim's bare FakeUIFrame:
-- CreateSlider registers on `parent.ThemeListeners`, and the shim's catch-all
-- __index answers a FUNCTION for that key, which table.insert cannot take.
local function pane() return CreateFrame("Frame") end

local function fire(frame, script, ...) return frame:GetScript(script)(frame, ...) end

-- ============================================================
-- 1. ONE DRAG: many ticks, few previews, exactly one commit
-- The shape of the whole change. The value is written on EVERY tick (anything
-- reading the setting mid-drag has to see the live number), the preview runs at
-- most once per rendered frame AND only when the value actually moved, and the
-- expensive callback runs once, at the end.
-- ============================================================
do
    local host, log = newHost(true)
    local value, light, commit = 10, 0, 0
    local s = host:CreateSlider(pane(), {
        label = "Width", min = 0, max = 100, step = 1,
        get = function() return value end,
        set = function(v) value = v end,
        lightweight = function() light = light + 1 end,
        onChanged   = function() commit = commit + 1 end,
    })
    local sl = s.slider
    local baseRefresh = log.refresh   -- the initial UpdateValue is suppressed, but be exact

    fire(sl, "OnMouseDown", "LeftButton")
    eq(log.onDragStart, 1, "drag: mousedown told the host a drag started")
    check(log.lastLight ~= nil, "drag: ...and handed it the lightweight function")
    check(sl:GetScript("OnUpdate") ~= nil, "drag: the preview pump is running")

    -- N = 5 value ticks, M = 4 rendered frames, deliberately interleaved so one
    -- frame sees no change at all.
    local function tick(v) sl:SetValue(v) end
    local function frame() fire(sl, "OnUpdate") end
    tick(11); tick(12)
    eq(value, 12, "drag: the db is written on EVERY tick, not deferred")
    frame()                                  -- previews 12
    tick(13); tick(14); frame()              -- previews 14
    frame()                                  -- nothing moved: no preview
    tick(15); frame()                        -- previews 15

    eq(light, 3, "drag: previewed once per frame that saw a NEW value -- 3 of 4 frames")
    eq(commit, 0, "drag: and the commit callback never ran during the drag")
    eq(log.refresh - baseRefresh, 0, "drag: the refresh hook was not touched once during the drag")
    eq(log.refreshNow, 0, "drag: nor the full sweep")

    fire(sl, "OnMouseUp", "LeftButton")
    eq(commit, 1, "release: the commit callback ran EXACTLY once")
    eq(log.refreshNow, 1, "release: ...followed by one full sweep")
    eq(log.onDragStop, 1, "release: and the host's drag bookkeeping was released")
    eq(log.count, 0, "release: start and stop balance 1:1")
    eq(log.refresh - baseRefresh, 0, "release: the per-tick refresh hook is gone for good")
    eq(value, 15, "release: the committed value is the last one dragged to")
    eq(sl:GetScript("OnUpdate"), nil, "release: the preview pump stopped")
end

-- ============================================================
-- 2. A TYPED VALUE IS A COMMIT
-- Same event, different gesture. One onChanged, one full sweep -- and NO
-- lightweight: the preview callback is for drags, and falling back to it would
-- run a partial update where a complete one belongs.
-- ============================================================
do
    local host, log = newHost(true)
    local value, light, commit = 10, 0, 0
    local s = host:CreateSlider(pane(), {
        label = "Width", min = 0, max = 100, step = 1,
        get = function() return value end,
        set = function(v) value = v end,
        lightweight = function() light = light + 1 end,
        onChanged   = function() commit = commit + 1 end,
    })
    local input = inputOf(s)
    check(input ~= nil, "typed: the slider has a numeric input box")
    input:SetText("42")
    fire(input, "OnEnterPressed")
    eq(value, 42, "typed: the value was written")
    eq(commit, 1, "typed: the commit callback ran once")
    eq(log.refreshNow, 1, "typed: with one full sweep after it")
    eq(light, 0, "typed: and NO preview -- lightweight is drag-only now")
end

-- A typed value on a slider that has ONLY a lightweight still must not preview:
-- the refreshNow is the apply, and a partial update in its place would be wrong.
do
    local host, log = newHost(true)
    local value, light = 10, 0
    local s = host:CreateSlider(pane(), {
        label = "Width", min = 0, max = 100, step = 1,
        get = function() return value end,
        set = function(v) value = v end,
        lightweight = function() light = light + 1 end,
    })
    local input = inputOf(s)
    input:SetText("7")
    fire(input, "OnEnterPressed")
    eq(value, 7, "typed: the value landed")
    eq(light, 0, "typed: no lightweight fallback, even with no onChanged to run")
    eq(log.refreshNow, 1, "typed: the full sweep is what applies it")
end

-- ============================================================
-- 3. A DRAG WITH NO LIGHTWEIGHT PREVIEWS NOTHING
-- Sanctioned, and the reason `lightweight` is worth adding to a slider: with no
-- preview function the bar moves, the number moves, and the frames do not --
-- until release, which still commits exactly once.
-- ============================================================
do
    local host, log = newHost(true)
    local value, commit = 10, 0
    local s = host:CreateSlider(pane(), {
        label = "Height", min = 0, max = 100, step = 1,
        get = function() return value end,
        set = function(v) value = v end,
        onChanged = function() commit = commit + 1 end,
    })
    local sl = s.slider
    fire(sl, "OnMouseDown", "LeftButton")
    eq(log.lastLight, nil, "no-preview: the host was told there is no lightweight")
    sl:SetValue(20); fire(sl, "OnUpdate")
    sl:SetValue(30); fire(sl, "OnUpdate")
    sl:SetValue(40); fire(sl, "OnUpdate")
    eq(commit, 0, "no-preview: nothing ran during the drag")
    eq(log.refresh, 0, "no-preview: the refresh hook is not a fallback")
    eq(log.refreshNow, 0, "no-preview: nor the full sweep")
    eq(value, 40, "no-preview: but the value still tracked every tick")
    fire(sl, "OnMouseUp", "LeftButton")
    eq(commit, 1, "no-preview: and release still commits exactly once")
    eq(log.refreshNow, 1, "no-preview: with its one full sweep")
    eq(log.count, 0, "no-preview: balanced")
end

-- ============================================================
-- 4. THE STOLEN MOUSEUP
-- The button is released over some other frame, so the bar's own OnMouseUp
-- never fires. The preview pump notices the button is up and treats it as the
-- release it was -- and the real OnMouseUp, if it ever arrives, must not commit
-- a second time.
--
-- ⚠ IsMouseButtonDown is read as a GLOBAL at call time. Absent (every other
-- block in this file) means "cannot ask" and the check is skipped, which is what
-- lets those drags be driven by hand. Installing one that answers `false` is how
-- a stolen mouseup is simulated.
-- ============================================================
do
    local host, log = newHost(true)
    local value, light, commit = 10, 0, 0
    local s = host:CreateSlider(pane(), {
        label = "Width", min = 0, max = 100, step = 1,
        get = function() return value end,
        set = function(v) value = v end,
        lightweight = function() light = light + 1 end,
        onChanged   = function() commit = commit + 1 end,
    })
    local sl = s.slider
    fire(sl, "OnMouseDown", "LeftButton")
    sl:SetValue(20)
    fire(sl, "OnUpdate")
    eq(light, 1, "stolen: the drag previewed normally while the button was held")

    IsMouseButtonDown = function() return false end
    fire(sl, "OnUpdate")
    IsMouseButtonDown = nil

    eq(commit, 1, "stolen: the next frame noticed and committed")
    eq(log.refreshNow, 1, "stolen: with one full sweep")
    eq(log.onDragStop, 1, "stolen: the host's drag was released")
    eq(log.count, 0, "stolen: start and stop still balance 1:1")
    eq(light, 1, "stolen: the release frame did not sneak in another preview")
    eq(sl:GetScript("OnUpdate"), nil, "stolen: and the pump stopped")

    -- The mouseup finally arrives.
    fire(sl, "OnMouseUp", "LeftButton")
    eq(commit, 1, "stolen: a late mouseup does NOT commit a second time")
    eq(log.refreshNow, 1, "stolen: ...nor sweep again")
    eq(log.onDragStop, 1, "stolen: ...nor unbalance the host's count")
    eq(log.count, 0, "stolen: which is still zero")
end

-- A drag whose frame is hidden mid-gesture releases its bookkeeping too -- a
-- refcounting host never gets a missing stop back. Bookkeeping only: a page
-- teardown is not a settings commit.
do
    local host, log = newHost(true)
    local commit = 0
    local value = 10
    local s = host:CreateSlider(pane(), {
        label = "Width", min = 0, max = 100, step = 1,
        get = function() return value end,
        set = function(v) value = v end,
        onChanged = function() commit = commit + 1 end,
    })
    local sl = s.slider
    fire(sl, "OnMouseDown", "LeftButton")
    sl:SetValue(30)
    fire(sl, "OnHide")
    eq(log.onDragStop, 1, "hidden: the drag was released")
    eq(log.count, 0, "hidden: balanced")
    eq(commit, 0, "hidden: and nothing was committed out of a teardown")
    fire(sl, "OnMouseUp", "LeftButton")
    eq(log.count, 0, "hidden: a mouseup afterwards cannot unbalance it")
    eq(commit, 0, "hidden: ...nor commit late")
end

-- ============================================================
-- 5. A HOST WITH NO DRAG HOOKS KEEPS THE OLD BEHAVIOUR
-- The split needs a consumer that publishes onDragStart; one that does not
-- (DandersMover, say) would never be told the drag ended, so a deferred commit
-- would simply never arrive. Those hosts commit per change, exactly as before.
-- ============================================================
do
    local host, log = newHost(false)
    local value, commit = 10, 0
    local s = host:CreateSlider(pane(), {
        label = "Width", min = 0, max = 100, step = 1,
        get = function() return value end,
        set = function(v) value = v end,
        onChanged = function() commit = commit + 1 end,
    })
    local sl = s.slider
    fire(sl, "OnMouseDown", "LeftButton")
    eq(sl:GetScript("OnUpdate"), nil, "legacy: no preview pump -- there is nothing to defer to")
    sl:SetValue(11); sl:SetValue(12); sl:SetValue(13)
    eq(commit, 3, "legacy: the callback fired on every value change, as it always did")
    eq(log.refresh, 3, "legacy: and so did the refresh hook")
    fire(sl, "OnMouseUp", "LeftButton")
    eq(commit, 3, "legacy: release adds no extra commit")
    eq(log.refreshNow, 0, "legacy: and asks for no extra sweep")
end

-- ============================================================
-- 5b. THE DRAG BUBBLE
-- A readout that floats over the thumb while the bar is HELD, so reading a drag
-- does not mean looking away to the value box at the far right of the row.
--
-- What is under test is its LIFECYCLE and the number in it -- built on the first
-- drag and not before, up for the whole gesture, gone after it, and always
-- formatted by the same function the value box uses. Where it lands on screen is
-- arithmetic the stub cannot check (it resolves no anchors), so the clamp is
-- pinned by the ONE thing the stub does record: the offset handed to SetPoint.
-- ============================================================
do
    local host = newHost(true)
    local value = 10
    local s = host:CreateSlider(pane(), {
        label = "Width", min = 0, max = 100, step = 1,
        get = function() return value end,
        set = function(v) value = v end,
    })
    local sl = s.slider
    eq(s.dragBubble, nil, "bubble: a slider that has never been dragged has not built one")

    fire(sl, "OnMouseDown", "LeftButton")
    local b = s.dragBubble
    check(b ~= nil, "bubble: pressing the bar builds it")
    check(b:IsShown(), "bubble: ...and puts it up at once, with the bar already jumped")
    eq(b._flags.mouse, false, "bubble: it never takes the mouse off the gesture that summoned it")
    eq(b:GetHeight(), 16, "bubble: one row's worth of readout")
    eq(b.Text:GetText(), "10", "bubble: showing the value the bar is on")

    -- The bar moves: the number tracks every tick, through UpdateFill -- the one
    -- path every value change already goes down.
    sl:SetValue(37)
    eq(b.Text:GetText(), "37", "bubble: the number tracks the drag")
    sl:SetValue(38)
    eq(b.Text:GetText(), "38", "bubble: ...on every tick")

    -- A fixed box, sized once. Digits are not equal width in any WoW font object,
    -- so a box that fitted its text would breathe on every tick.
    local w = b:GetWidth()
    sl:SetValue(100)
    eq(b:GetWidth(), w, "bubble: the box does not resize as the number gets longer")

    fire(sl, "OnMouseUp", "LeftButton")
    check(not b:IsShown(), "bubble: the release takes it down")

    -- A second drag reuses the SAME bubble rather than building another.
    fire(sl, "OnMouseDown", "LeftButton")
    eq(s.dragBubble, b, "bubble: a second drag reuses the one it built")
    check(b:IsShown(), "bubble: ...and puts it back up")
    eq(b:GetAlpha(), 1, "bubble: at full alpha, whatever a cancelled fade-out left behind")
    fire(sl, "OnMouseUp", "LeftButton")
end

-- The FORMAT is the value box's, not a second opinion. A sub-1 step is where the
-- two would diverge if the bubble had its own idea of precision.
do
    local host = newHost(true)
    local value = 0.5
    local s = host:CreateSlider(pane(), {
        label = "Alpha", min = 0, max = 1, step = 0.05,
        get = function() return value end,
        set = function(v) value = v end,
    })
    local sl, input = s.slider, inputOf(s)
    fire(sl, "OnMouseDown", "LeftButton")
    sl:SetValue(0.65)
    eq(s.dragBubble.Text:GetText(), input:GetText(),
       "bubble: the bubble and the value box always show the same string")
    eq(s.dragBubble.Text:GetText(), "0.65", "bubble: ...at the step's own precision")
    fire(sl, "OnMouseUp", "LeftButton")
end

-- ---- riding the thumb, clamped only at the edges ---------------------
-- The bubble is ANCHORED TO THE THUMB and then left alone: WoW moves the thumb
-- itself and the layout engine carries anything anchored to it along, so a bar
-- dragged through the middle of its range costs NO anchor calls at all (5c
-- below counts them).
--
-- The clamp is the only thing left to decide. At either end the bubble's centre
-- would sit on the container's edge, putting half the box outside the settings
-- group -- where the page's scroll frame clips it -- so there it comes OFF the
-- thumb and pins to the container instead. Three states, swapped on a boundary
-- crossing rather than a number recomputed every frame. The stub resolves no
-- anchors, but it records what SetPoint was handed, and that is the whole of
-- what the state machine produces.
do
    local host = newHost(true)
    local value = 50
    local s = host:CreateSlider(pane(), {
        label = "Width", min = 0, max = 100, step = 1,
        get = function() return value end,
        set = function(v) value = v end,
    })
    local sl = s.slider
    -- Give the stub a real row and track to measure against.
    s:SetWidth(260)
    -- The track is anchored TOPLEFT 0 and RIGHT to the value box, so its left IS
    -- the container's left -- which is what lets one x answer "would it overhang".
    local track
    for _, child in ipairs(s._children) do
        if child._kind == "Frame" and child ~= s.dragBubble then track = child break end
    end
    check(track ~= nil, "bubble: found the track the arithmetic is measured off")
    track:SetWidth(200)
    local thumb = thumbOf(sl)
    check(thumb ~= nil, "bubble: found the thumb it rides")

    fire(sl, "OnMouseDown", "LeftButton")
    local b = s.dragBubble
    local half = b:GetWidth() / 2

    -- (point, relativeTo, relativePoint, x) off the ONE anchor it ever has.
    local function anchor()
        local p, rel, relP, x = b:GetPoint(1)
        eq(p, "BOTTOM", "bubble: it hangs by its bottom edge, above the thumb")
        eq(b:GetNumPoints(), 1, "bubble: and by exactly one point, never a stack of them")
        return rel, relP, x
    end

    sl:SetValue(50)
    local rel, relP, x = anchor()
    eq(rel, thumb, "bubble: mid-bar it is anchored to the THUMB, not to a computed x")
    eq(relP, "TOP", "bubble: ...sitting on top of it")
    eq(x, 0, "bubble: with no offset -- nothing to recompute as the bar moves")

    -- ⚠ THE CLAMPED ANCHOR IS THE SLIDER, NOT THE CONTAINER, and the two are
    -- interchangeable for X on purpose: the bar is pinned to the container's
    -- TOPLEFT, so their left edges are the same line. Y is what forces the
    -- choice -- the height has to come from the bar the thumb centres on, or the
    -- box hops half a pixel the moment it clamps.
    sl:SetValue(0)
    rel, relP, x = anchor()
    eq(rel, sl, "bubble: at the LEFT end it comes off the thumb and pins to the bar")
    eq(relP, "TOPLEFT", "bubble: ...measured from its top-left, which is the row's")
    eq(x, half, "bubble: ...clamped half a box inside it")

    -- The RIGHT end of a real row does not need the clamp -- the track stops at
    -- the value box, well inside the container -- so the bubble goes back on the
    -- thumb there. The clamp is not a no-op though: widen the track to the whole
    -- row (which is what a bar with no value box beside it would be) and the far
    -- end starts to overhang.
    sl:SetValue(100)
    rel, _, x = anchor()
    eq(rel, thumb, "bubble: at the right end of a normal row it is back on the thumb")
    eq(x, 0, "bubble: ...unclamped")
    track:SetWidth(260)
    sl:SetValue(99); sl:SetValue(100)      -- re-run the placement at the new width
    rel, relP, x = anchor()
    eq(rel, sl, "bubble: ...but a full-width track pins it to the other edge")
    eq(x, 260 - half, "bubble: ...clamped half a box inside that one")

    -- ⚠ THE CLAMP COORDINATE IS PART OF THE STATE, not just the state name. A
    -- panel resized while the bubble is pinned to an edge moves that edge, and a
    -- comparison on the name alone would leave the box behind.
    s:SetWidth(300); track:SetWidth(300)
    sl:SetValue(99); sl:SetValue(100)
    _, _, x = anchor()
    eq(x, 300 - half, "bubble: a row widened under a clamped bubble moves it to the new edge")
    fire(sl, "OnMouseUp", "LeftButton")
end

-- ============================================================
-- 5c. WHAT A HELD DRAG COSTS PER TICK
-- The regression this pins down. The first cut of the bubble re-issued its text
-- AND re-anchored itself (ClearAllPoints + SetPoint) on every single value
-- change -- including the many ticks of a slow drag that land on the same
-- snapped value. Two costs, both real in game:
--
--   * the bubble is a backdrop frame with a pixel border, so it carries six
--     anchored regions -- a fill, four border strips and the font string -- and
--     dirtying its rect made the layout engine re-solve all six, inside the same
--     frame that was already writing the fill and the value box;
--   * the offset it was re-anchored to was a FLOAT, so the box landed on a fresh
--     sub-pixel position every tick and shimmered against the bar under it.
--
-- Counted rather than described: "it feels smoother" is not a test. The budget
-- for a held drag is ONE fill write, AT MOST one SetText, and NO anchor calls.
-- ============================================================
do
    local host = newHost(true)
    local value = 100
    -- A wide bar in a normal row: 40..400 over a 200px track is what "Frame
    -- Width" actually is, and one step there is half a pixel of thumb travel --
    -- the case where a per-tick re-anchor buys the least and costs the most.
    local s = host:CreateSlider(pane(), {
        label = "Frame Width", min = 40, max = 400, step = 1,
        get = function() return value end,
        set = function(v) value = v end,
    })
    local sl = s.slider
    s:SetWidth(260)
    local track
    for _, child in ipairs(s._children) do
        if child._kind == "Frame" and child ~= s.dragBubble then track = child break end
    end
    track:SetWidth(200)

    fire(sl, "OnMouseDown", "LeftButton")
    local b = s.dragBubble

    -- Built, shown AND anchored by the press, before the gesture's first tick:
    -- nothing in the drag itself pays for the first of any of them.
    check(b ~= nil and b:IsShown(), "cost: the press built it and put it up")
    eq(b:GetNumPoints(), 1, "cost: ...and anchored it, before the first tick")
    eq(b.Text:GetText(), "100", "cost: ...showing the value the bar was pressed on")

    -- Count from here, with the opening repaint already behind us.
    local n = { text = 0, clear = 0, point = 0 }
    local rawText, rawClear, rawPoint = b.Text.SetText, b.ClearAllPoints, b.SetPoint
    b.Text.SetText   = function(self, t) n.text  = n.text  + 1 return rawText(self, t) end
    b.ClearAllPoints = function(self)    n.clear = n.clear + 1 return rawClear(self) end
    b.SetPoint       = function(self, ...) n.point = n.point + 1 return rawPoint(self, ...) end

    -- (a) TEN TICKS THAT DO NOT MOVE THE VALUE. A drag whose mouse is moving less
    -- than a step -- or not at all -- still ticks. None of them may repaint.
    for _ = 1, 10 do sl:SetValue(200) end
    eq(n.text, 1, "cost: ten ticks on the same value wrote the text ONCE")
    eq(n.clear, 0, "cost: ...and never re-anchored")
    eq(n.point, 0, "cost: ...at all")

    -- (b) TEN TICKS THAT EACH MOVE THE BAR. The text has to follow -- that is the
    -- whole point of the readout -- but the anchor still must not be touched: the
    -- thumb moved, and the bubble is hung off the thumb.
    n.text, n.clear, n.point = 0, 0, 0
    for i = 1, 10 do sl:SetValue(200 + i) end
    eq(n.text, 10, "cost: ten ticks that each changed the value wrote the text ten times")
    eq(n.clear, 0, "cost: ...and STILL never re-anchored")
    eq(n.point, 0, "cost: ...at all -- the thumb carries it")
    eq(b.Text:GetText(), "210", "cost: ...while the number stayed correct throughout")

    -- (c) A SWEEP INTO THE LEFT END crosses into the clamp, which is the one
    -- thing that IS allowed to re-anchor -- once, on the crossing, and not again
    -- for every tick spent inside it. (The RIGHT end of a normal row never
    -- clamps: the track stops at the value box, well inside the row. See the
    -- block above.)
    --
    -- The boundary is where the bubble's centre would reach half a box in from
    -- the row's left edge: x = 1 + pct * 198 = 15.5, i.e. value ~66 on a 40..400
    -- bar. Ten steps from 70 down to 61 cross it exactly once.
    n.text, n.clear, n.point = 0, 0, 0
    for i = 0, 9 do sl:SetValue(70 - i) end
    eq(n.clear, 1, "cost: a sweep into the end clamp re-anchors exactly once")
    eq(n.point, 1, "cost: ...on the crossing, not on every tick past it")

    b.Text.SetText, b.ClearAllPoints, b.SetPoint = rawText, rawClear, rawPoint
    fire(sl, "OnMouseUp", "LeftButton")
end

-- ---- a drag hidden mid-gesture ---------------------------------------
-- The bubble comes down INSTANTLY here, not on a fade: the deferred Hide at the
-- end of one would land on a page that has already been rebuilt, which is how a
-- readout gets stranded over a row with no slider under it.
do
    local host = newHost(true)
    local value = 10
    local s = host:CreateSlider(pane(), {
        label = "Width", min = 0, max = 100, step = 1,
        get = function() return value end,
        set = function(v) value = v end,
    })
    local sl = s.slider
    fire(sl, "OnMouseDown", "LeftButton")
    check(s.dragBubble:IsShown(), "bubble: up, mid-drag")
    fire(sl, "OnHide")
    check(not s.dragBubble:IsShown(), "bubble: a page torn down under a held bar takes it with it")
end

-- ---- the stolen mouseup takes it down too ----------------------------
do
    local host = newHost(true)
    local value = 10
    local s = host:CreateSlider(pane(), {
        label = "Width", min = 0, max = 100, step = 1,
        get = function() return value end,
        set = function(v) value = v end,
    })
    local sl = s.slider
    fire(sl, "OnMouseDown", "LeftButton")
    IsMouseButtonDown = function() return false end
    fire(sl, "OnUpdate")
    IsMouseButtonDown = nil
    check(not s.dragBubble:IsShown(), "bubble: a mouseup that went elsewhere still takes it down")
end

-- ---- and a LEGACY host (no drag hooks) gets one as well --------------
-- Kit-wide by design: a consumer that does not take part in the preview/commit
-- split still drags sliders, and the readout is about the gesture, not the
-- commit strategy.
do
    local host = newHost(false)
    local value = 10
    local s = host:CreateSlider(pane(), {
        label = "Width", min = 0, max = 100, step = 1,
        get = function() return value end,
        set = function(v) value = v end,
    })
    local sl = s.slider
    fire(sl, "OnMouseDown", "LeftButton")
    check(s.dragBubble and s.dragBubble:IsShown(), "bubble: a legacy host's slider shows one too")
    sl:SetValue(44)
    eq(s.dragBubble.Text:GetText(), "44", "bubble: ...and it tracks")
    fire(sl, "OnMouseUp", "LeftButton")
    check(not s.dragBubble:IsShown(), "bubble: ...and comes down on release")
end

-- ============================================================
-- 6. THE COLOUR PICKER'S BARS ANNOUNCE THEIR DRAGS
-- Every bar in the picker is a drag, and a consumer that defers work during
-- drags cannot know one is happening unless it is told. Each pair is balanced on
-- its own: a mouseup on a bar that never started a drag decrements nothing.
--
-- ☠ THE LIGHTWEIGHT SLOT IS nil FOR ALL OF THEM. The picker previews through its
-- own onChange callback; handing that back as a lightweight would re-enter the
-- consumer through a second door on every frame.
-- ============================================================
do
    -- The consumer surfaces ColorPicker.lua reaches off its host. All recorders
    -- or no-ops: what is under test is the drag wiring, not the chrome.
    function UI:CreateElementBackdrop(frame) return frame end
    function UI:StyleButton(btn, opts)
        if opts and opts.text then btn:SetText(opts.text) end
        btn.SetActive = function() end
        return btn
    end
    function UI:StyleEditBox(eb) return eb end
    function UI:CreateCloseButton(parent) return CreateFrame("Button", nil, parent) end
    function UI:ShowTooltip() end
    function UI:HideTooltip() end

    CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
    UISpecialFrames = {}
    -- The stub resolves no anchors, so a bar built by CreateFrame sits at the
    -- origin: a 160px square spans -80..80 on both axes. The cursor has to be
    -- INSIDE that, or every position clamps to the same corner and "the colour
    -- moved" can never be true.
    local cursorX, cursorY = 0, 0
    GetCursorPosition = function() return cursorX, cursorY end

    load_ui_file_into("ColorPicker.lua", ns)

    local host, log = newHost(true)
    local previews = 0
    host:OpenColorPicker({ r = 1, g = 0, b = 0, a = 1 }, true,
        nil, nil, function() previews = previews + 1 end)

    local picker = host:GetColorPickerFrame()
    check(picker ~= nil, "picker: it opened")
    eq(log.onDragStart, 0, "picker: opening one is not a drag")

    -- The square (saturation/value). Its OnMouseDown and its OnUpdate both drive
    -- the colour, so the drag pair is the whole gesture.
    local square, hue
    for _, child in ipairs(picker._children) do
        for _, gk in ipairs(child._children or {}) do
            for _, bar in ipairs(gk._children or {}) do
                if bar:GetScript("OnUpdate") and bar:GetScript("OnMouseDown") then
                    if not square then square = bar elseif not hue then hue = bar end
                end
            end
        end
    end
    check(square ~= nil, "picker: found a bar with a drag pair on it")

    local before = previews
    fire(square, "OnMouseDown", "LeftButton")
    eq(log.onDragStart, 1, "picker: pressing a bar starts a drag on the host")
    eq(log.lastLight, nil, "picker: with NO lightweight -- the picker previews through its own callback")
    check(previews > before, "picker: and the press previewed the colour it landed on")

    -- Held still: the bar's OnUpdate runs every frame, but an unchanged colour
    -- must not re-fire the consumer's callback.
    local held = previews
    fire(square, "OnUpdate")
    fire(square, "OnUpdate")
    eq(previews, held, "picker: a cursor held still previews nothing new")

    -- Moved: one preview.
    cursorX, cursorY = 40, -20
    fire(square, "OnUpdate")
    eq(previews, held + 1, "picker: a moved cursor previews exactly once")

    fire(square, "OnMouseUp", "LeftButton")
    eq(log.onDragStop, 1, "picker: releasing ends the drag")
    eq(log.count, 0, "picker: start and stop balance 1:1")

    -- A mouseup on a bar nobody pressed decrements nothing.
    fire(square, "OnMouseUp", "LeftButton")
    eq(log.onDragStop, 1, "picker: a stray mouseup on an unpressed bar is ignored")
    eq(log.count, 0, "picker: so the count cannot go negative")

    -- A second bar is its own pair.
    if hue then
        fire(hue, "OnMouseDown", "LeftButton")
        eq(log.onDragStart, 2, "picker: a second bar starts its own drag")
        fire(hue, "OnMouseUp", "LeftButton")
        eq(log.onDragStop, 2, "picker: ...and ends it")
        eq(log.count, 0, "picker: still balanced")
    end

    -- A bar still held when the picker is closed must release: a refcounting
    -- consumer never gets the missing stop back.
    fire(square, "OnMouseDown", "LeftButton")
    eq(log.count, 1, "picker: a drag is held")
    picker:Hide()
    fire(picker, "OnHide", picker)
    eq(log.count, 0, "picker: closing the window released it")

    -- The stolen mouseup, same door as the slider's.
    fire(square, "OnMouseDown", "LeftButton")
    eq(log.count, 1, "picker: held again")
    IsMouseButtonDown = function() return false end
    fire(square, "OnUpdate")
    IsMouseButtonDown = nil
    eq(log.count, 0, "picker: the pump noticed the button was up and released")
end

-- ============================================================
-- 7. THE GLIDE -- A THUMB THAT MOVES BETWEEN STEPS, A VALUE THAT DOES NOT
-- ------------------------------------------------------------
-- SetObeyStepOnDrag used to have the ENGINE snap the handle to a step while the
-- bar was held, which on any bar whose step is worth several pixels of track is
-- a handle that jumps in chunks under a mouse that is moving smoothly. It is off
-- now, and the step is applied on the way OUT of the widget instead.
--
-- So there are two numbers where there used to be one, and every assertion below
-- is about keeping them apart:
--
--   slider:GetValue()  the THUMB. A screen position, to the pixel. Read by the
--                      fill and by the bubble's placement, and by nothing else.
--   Quantize(...)      the VALUE. What the db, the value box, the bubble's text,
--                      the preview guard and the commit all see.
--
-- ⚠ The stub's SetValue stores exactly what it is handed and fires
-- OnValueChanged with it -- which is what the real widget does with the step no
-- longer obeyed, so a fractional SetValue here IS a sub-step drag tick.
-- ============================================================
do
    local host, log = newHost(true)
    local value, light, commit = 3, 0, 0
    local s = host:CreateSlider(pane(), {
        label = "Group Spacing", min = 0, max = 10, step = 1,
        get = function() return value end,
        set = function(v) value = v end,
        lightweight = function() light = light + 1 end,
        onChanged   = function() commit = commit + 1 end,
    })
    local sl, input = s.slider, inputOf(s)

    fire(sl, "OnMouseDown", "LeftButton")
    -- Land on a step and let the pump see it, so everything below is measured
    -- from a bar already sitting on 3 rather than from a bar arriving there.
    sl:SetValue(3); fire(sl, "OnUpdate")
    local basePreviews = light
    eq(value, 3, "glide: the bar starts on its step")

    -- (a) THREE TICKS INSIDE ONE STEP. The thumb follows the mouse the whole way
    -- and NOTHING else moves -- not the db, not the box, not the bubble.
    sl:SetValue(3.2)
    eq(sl:GetValue(), 3.2, "glide: the THUMB holds the raw position it was dragged to")
    eq(value, 3, "glide: ...while the value written is still the step")
    sl:SetValue(3.4); sl:SetValue(3.49)
    eq(sl:GetValue(), 3.49, "glide: the thumb keeps following the mouse, pixel by pixel")
    eq(value, 3, "glide: ...and three sub-step ticks wrote nothing new")
    eq(input:GetText(), "3", "glide: the value box shows the step, never the raw position")
    eq(s.dragBubble.Text:GetText(), "3", "glide: and the bubble agrees with it")

    fire(sl, "OnUpdate"); fire(sl, "OnUpdate"); fire(sl, "OnUpdate")
    eq(light - basePreviews, 0, "glide: three rendered frames inside one step previewed NOTHING")

    -- (b) CROSSING A STEP is the only thing the preview pump reacts to.
    sl:SetValue(3.6)
    eq(value, 4, "glide: past the half-step the value rounds on to the next one")
    fire(sl, "OnUpdate")
    eq(light - basePreviews, 1, "glide: crossing a step previews exactly once")
    fire(sl, "OnUpdate")
    eq(light - basePreviews, 1, "glide: ...and not again while the thumb sits inside it")
    eq(commit, 0, "glide: and nothing committed mid-drag")

    -- (c) RELEASE commits the quantized value once and SETTLES the handle on to
    -- it -- the bar the user is left looking at has to agree with the number.
    sl:SetValue(6.8)
    eq(sl:GetValue(), 6.8, "glide: held between two steps at the moment of release")
    fire(sl, "OnMouseUp", "LeftButton")
    eq(commit, 1, "release: exactly one commit")
    eq(value, 7, "release: of the QUANTIZED value, not the raw thumb position")
    eq(sl:GetValue(), 7, "release: and the thumb settled on to it")
    eq(input:GetText(), "7", "release: box and thumb tell the same story")
    eq(log.refreshNow, 1, "release: one full sweep, exactly as before the glide")
    eq(log.count, 0, "release: start and stop still balance 1:1")
end

-- ---- the legacy host keeps its contract across the glide -------------
-- A host with no drag hooks commits on EVERY value change. With the engine no
-- longer stepping, "every value change" would be every pixel of thumb travel --
-- dozens of full settings applies per second on the same number. The guard in
-- OnValueChanged is what keeps that at one per step CROSSED, which is what
-- obeying the step on drag used to buy it for free.
do
    local host, log = newHost(false)
    local value, commit = 3, 0
    local s = host:CreateSlider(pane(), {
        label = "Group Spacing", min = 0, max = 10, step = 1,
        get = function() return value end,
        set = function(v) value = v end,
        onChanged = function() commit = commit + 1 end,
    })
    local sl = s.slider
    fire(sl, "OnMouseDown", "LeftButton")
    sl:SetValue(3)
    eq(commit, 1, "legacy glide: landing on a step commits, exactly as it always did")
    eq(log.refresh, 1, "legacy glide: with its refresh")

    sl:SetValue(3.2); sl:SetValue(3.4); sl:SetValue(3.49)
    eq(commit, 1, "legacy glide: three ticks INSIDE that step add no commits")
    eq(log.refresh, 1, "legacy glide: ...and no refreshes either")
    eq(value, 3, "legacy glide: the db still holds the step")

    sl:SetValue(3.6)
    eq(commit, 2, "legacy glide: crossing into the next step commits once")
    eq(value, 4, "legacy glide: ...with the quantized value")

    sl:SetValue(4.4)
    fire(sl, "OnMouseUp", "LeftButton")
    eq(commit, 2, "legacy glide: release adds no commit of its own")
    eq(log.refreshNow, 0, "legacy glide: nor a sweep it never asked for")
    eq(sl:GetValue(), 4, "legacy glide: but the thumb still settles on to its value")
    eq(value, 4, "legacy glide: which is the one in the db")
end

-- ---- the repeat guard cannot go stale across a gesture ---------------
-- ☠ THE GUARD IS DRAG STATE, AND EVERY OTHER PATH TO THE VALUE BYPASSES IT: a
-- typed entry and every programmatic UpdateValue set the bar with the callback
-- suppressed, so OnValueChanged never runs and never learns the new number. Left
-- holding the value from the LAST drag, the guard would read the first tick of
-- the NEXT one as a repeat and skip the write -- leaving the db on the typed
-- value while the thumb sat somewhere else. Cleared at drag start instead.
do
    local host = newHost(true)
    local value = 7
    local s = host:CreateSlider(pane(), {
        label = "Width", min = 0, max = 100, step = 1,
        get = function() return value end,
        set = function(v) value = v end,
    })
    local sl, input = s.slider, inputOf(s)

    -- A drag that leaves the guard holding 7.
    fire(sl, "OnMouseDown", "LeftButton")
    sl:SetValue(7)
    fire(sl, "OnMouseUp", "LeftButton")

    -- A typed value goes in behind OnValueChanged's back.
    input:SetText("7.3")
    fire(input, "OnEnterPressed")
    check(value == 7.3, "stale guard: the typed value landed, unseen by the value handler")

    -- ...and the next drag must still write, even though it lands on the 7 the
    -- guard is holding.
    fire(sl, "OnMouseDown", "LeftButton")
    sl:SetValue(7.1)
    check(value == 7, "stale guard: the next drag wrote its step, guard or no guard")
    eq(input:GetText(), "7", "stale guard: and the box came back into line with it")
    fire(sl, "OnMouseUp", "LeftButton")
end

-- ---- a programmatic SetValue is NOT deduplicated ---------------------
-- The drag guard is gated on isDragging for a reason. A slider bound through
-- customGet to whichever key a dial currently selects gets SetValue'd to the
-- same NUMBER when that dial moves, and the write must still happen: what
-- changed is the thing being written into, not the value.
do
    local host = newHost(false)
    local writes = 0
    local s = host:CreateSlider(pane(), {
        label = "Width", min = 0, max = 100, step = 1,
        get = function() return 20 end,
        set = function() writes = writes + 1 end,
    })
    local sl = s.slider
    sl:SetValue(20); sl:SetValue(20); sl:SetValue(20)
    eq(writes, 3, "programmatic: three SetValues to the same number all wrote")
end

-- ============================================================
-- 7b. A FLOAT STEP DOES NOT DRIFT
-- The number that made this block exist: three 0.05 steps is 0.15, and 3 * 0.05
-- in binary floating point is 0.15000000000000002. Both print as "0.15", so a
-- settings file holding the second one looks right for as long as nobody
-- COMPARES it -- against a default table, an export written by hand, or the
-- other half of a "did this actually change" check.
-- ============================================================
do
    local host = newHost(true)
    local value = 0
    local s = host:CreateSlider(pane(), {
        label = "Alpha", min = 0, max = 1, step = 0.05,
        get = function() return value end,
        set = function(v) value = v end,
    })
    local sl, input = s.slider, inputOf(s)
    fire(sl, "OnMouseDown", "LeftButton")

    sl:SetValue(0.153)
    check(value == 0.15, "float step: a raw 0.153 is written as EXACTLY 0.15, the literal")
    eq(input:GetText(), "0.15", "float step: and the box shows two clean decimals")
    eq(s.dragBubble.Text:GetText(), "0.15", "float step: as does the bubble")

    -- Every step of the series, not just the one that bites.
    for i = 0, 20 do
        local want = i / 20                    -- 0, 0.05, 0.10 ... 1
        sl:SetValue(want + 0.013)              -- somewhere inside that step
        check(value == want, "float step: step " .. i .. " landed on its exact value")
    end

    -- ⚠ EXACTLY HALF A STEP ALONG, which is where the rule has to be WRITTEN
    -- DOWN rather than inherited from whatever the arithmetic happens to do.
    -- 0.075 is dead centre between 0.05 and 0.10 on paper; in binary
    -- 0.075 / 0.05 is 1.4999999999999998, so a bare round lands it on 0.05 --
    -- a bar that rounds up at every other midpoint and down at this one. Half-up
    -- everywhere is the rule, and the epsilon in Quantize is what enforces it.
    sl:SetValue(0.075)
    check(value == 0.1, "float step: a position exactly half a step along rounds UP")
    sl:SetValue(0.5); sl:SetValue(0.525)
    check(value == 0.55, "float step: ...at every midpoint, not just the exact ones")

    sl:SetValue(0.62)
    fire(sl, "OnMouseUp", "LeftButton")
    check(value == 0.6, "float step: release commits the quantized value")
    check(sl:GetValue() == 0.6, "float step: and settles the thumb on it")
end

-- ============================================================
-- 7c. THE GRID IS min + k * step -- BOTH HALVES OF THAT
-- Which was the engine's job while it obeyed the step, and is Quantize's now.
-- The rounding it replaced was `math.floor(value + 0.5)` for any step >= 1 --
-- correct only for a step of exactly 1, on a bar starting at a whole number.
-- ============================================================
do
    local host = newHost(true)
    local value = 10
    local s = host:CreateSlider(pane(), {
        label = "Columns", min = 10, max = 50, step = 5,
        get = function() return value end,
        set = function(v) value = v end,
    })
    local sl = s.slider
    fire(sl, "OnMouseDown", "LeftButton")
    sl:SetValue(22)
    eq(value, 20, "wide step: a step of 5 snaps to multiples of 5, not to whole numbers")
    sl:SetValue(23)
    eq(value, 25, "wide step: ...rounding to the NEAREST of them")
    fire(sl, "OnMouseUp", "LeftButton")
    eq(sl:GetValue(), 25, "wide step: and the thumb settles on the multiple")
end

-- ...and the grid starts where min does, at min's own precision.
do
    local host = newHost(true)
    local value = 0.5
    local s = host:CreateSlider(pane(), {
        label = "Delay", min = 0.5, max = 5.5, step = 1,
        get = function() return value end,
        set = function(v) value = v end,
    })
    local sl, input = s.slider, inputOf(s)
    fire(sl, "OnMouseDown", "LeftButton")
    sl:SetValue(2.4)
    check(value == 2.5, "offset grid: a 0.5-min bar stepping by 1 stays on halves")
    eq(input:GetText(), "2.5", "offset grid: and the box shows the half")
    fire(sl, "OnMouseUp", "LeftButton")
    check(sl:GetValue() == 2.5, "offset grid: the thumb settles on it, not on the whole number")
end

-- SetRange re-scales the grid AND the precision it is rounded to: a bar flipped
-- on to a range that starts on a half has to round on to halves from then on.
do
    local host = newHost(true)
    local value = 2
    local s = host:CreateSlider(pane(), {
        label = "Delay", min = 1, max = 10, step = 1,
        get = function() return value end,
        set = function(v) value = v end,
    })
    local sl = s.slider
    s:SetRange(0.5, 5.5)
    fire(sl, "OnMouseDown", "LeftButton")
    sl:SetValue(3.4)
    check(value == 3.5, "SetRange: the new min moved the grid, and its precision with it")
    fire(sl, "OnMouseUp", "LeftButton")
end

-- ============================================================
-- 8. THE MODIFIED-DEFAULT DOT
-- A SECOND indicator kind on the same widget, answering a different question
-- from the override star: not "does this differ from the auto-layout global"
-- but "does this differ from the value the addon SHIPS". It rides
-- AddOverrideIndicators -- which every db-bound factory in the kit already goes
-- through -- and reads ONE optional host hook, isModifiedDefault, so a consumer
-- that does not publish it never draws one.
--
-- These build SLIDERS with a dbRef, which is what makes the factory call
-- AddOverrideIndicators at all; the mechanism under test is the shared one, and
-- the dropdown / checkbox / colour picker / edit box reach it by the same door.
-- ============================================================
local function dotHost(answer)
    local host, log = newHost(false)
    log.asked = {}
    host.hooks.isModifiedDefault = function(db, key)
        log.asked[#log.asked + 1] = { db = db, key = key }
        return answer(db, key)
    end
    return host, log
end

local function boundSlider(host, db, key)
    return host:CreateSlider(pane(), {
        label = "Width", min = 0, max = 100, step = 1,
        get = function() return db[key] end,
        set = function(v) db[key] = v end,
        dbRef = { db = db, key = key },
    })
end

-- A host with NO hook draws nothing and errors on nothing -- which is every
-- consumer that has not opted in, DandersMover included.
do
    local host = newHost(false)
    local db = { frameBorderSize = 3 }
    local s = boundSlider(host, db, "frameBorderSize")
    check(s.modifiedDot ~= nil, "no hook: the dot is still BUILT (one hidden texture)")
    check(not s.modifiedDot:IsShown(), "no hook: ...and never shown")
    s:UpdateOverrideIndicators(3)
    check(not s.modifiedDot:IsShown(), "no hook: an update does not conjure one")
    fire(s.slider, "OnMouseDown", "LeftButton")
    s.slider:SetValue(9)
    fire(s.slider, "OnMouseUp", "LeftButton")
    check(not s.modifiedDot:IsShown(), "no hook: nor does a whole drag")
end

-- The hook's answer IS the dot, both ways round, and nothing is cached.
do
    local modified = true
    local host = dotHost(function() return modified end)
    local s = boundSlider(host, { frameBorderSize = 3 }, "frameBorderSize")
    check(s.modifiedDot:IsShown(), "hook true: the dot is up as soon as the widget is built")

    modified = false
    s:UpdateOverrideIndicators(3)
    check(not s.modifiedDot:IsShown(), "hook false: and it comes down again")

    modified = true
    s:UpdateOverrideIndicators(3)
    check(s.modifiedDot:IsShown(), "hook true: ...and back up on the next repaint")
end

-- What it is asked ABOUT: the (db, key) pair the factory was BOUND to, not the
-- value it happens to be showing.
do
    local host, log = dotHost(function() return true end)
    local db = { frameBorderSize = 3 }
    boundSlider(host, db, "frameBorderSize")
    check(#log.asked > 0, "hook args: the hook was asked")
    check(log.asked[1].db == db, "hook args: ...about the bound TABLE")
    eq(log.asked[1].key, "frameBorderSize", "hook args: ...and the bound key")
end

-- ☠ THE PARTY CASE, and the regression an early return would have caused.
-- getOverrideState answers "none" for the whole of party mode by design, and
-- the override half of UpdateOverrideIndicators returns immediately on that. The
-- dot is painted ABOVE that return, or the modified marks would appear in raid
-- only -- half the panel, and the half nobody would think to check.
do
    local host = dotHost(function() return true end)
    host.hooks.getOverrideState = function() return "none" end
    local s = boundSlider(host, { frameBorderSize = 3 }, "frameBorderSize")
    check(s.modifiedDot:IsShown(), "party: the dot shows even though the override state is 'none'")
    check(not s.overrideStar:IsShown(), "party: ...while the override star correctly does not")
    check(not s.overrideResetBtn:IsShown(), "party: ...nor the reset button")
    s:UpdateOverrideIndicators(3)
    check(s.modifiedDot:IsShown(), "party: and a repaint through the same return keeps it")
end

-- The colour is the palette's amber NOTICE token -- not the star's gold
-- (UI.OVERRIDE_MARKER_COLOR), not the accent, and not a literal.
do
    local host = dotHost(function() return true end)
    local s = boundSlider(host, { frameBorderSize = 3 }, "frameBorderSize")
    local v = s.modifiedDot._vertex
    check(v ~= nil, "colour: the dot was tinted")
    eq(v.r, UI.Colors.notice.r, "colour: from UI.Colors.notice -- red")
    eq(v.g, UI.Colors.notice.g, "colour: ...green")
    eq(v.b, UI.Colors.notice.b, "colour: ...blue")
    check(v.r ~= UI.OVERRIDE_MARKER_COLOR[1] or v.g ~= UI.OVERRIDE_MARKER_COLOR[2],
        "colour: and it is NOT the override star's gold")
    eq(s.modifiedDot:GetWidth(), 6, "size: 6px against the star's 12 -- information, not a control")
    check(s.modifiedDot:GetTexture():find("dot", 1, true) ~= nil, "art: the shared dot texture")
end

-- IT FOLLOWS THE WRITE PATH, through the factory's own setter. A drag settle is
-- the case that matters: the value lands, the widget repaints, and the dot is
-- re-answered from the db that was just written.
do
    local db = { frameBorderSize = 3 }
    local DEFAULT = 3
    local host = dotHost(function(t, k) return t[k] ~= DEFAULT end)
    local s = boundSlider(host, db, "frameBorderSize")
    check(not s.modifiedDot:IsShown(), "write path: at the shipped value, no dot")

    fire(s.slider, "OnMouseDown", "LeftButton")
    s.slider:SetValue(7)
    fire(s.slider, "OnMouseUp", "LeftButton")
    eq(db.frameBorderSize, 7, "write path: the drag landed")
    check(s.modifiedDot:IsShown(), "write path: ...and the dot lit, with nothing invalidated by hand")

    local input = inputOf(s)
    input:SetText("3")
    fire(input, "OnEnterPressed")
    eq(db.frameBorderSize, 3, "write path: typed back to the default")
    check(not s.modifiedDot:IsShown(), "write path: and the dot went out again")
end

-- WHERE IT SITS: at the END OF THE LABEL'S VISIBLE TEXT, re-anchored on every
-- update because the string width is not knowable until the text is laid out
-- and moves again whenever the settings font does.
do
    local host = dotHost(function() return true end)
    local s = boundSlider(host, { frameBorderSize = 3 }, "frameBorderSize")
    local pts = s.modifiedDot._points
    local p = pts[#pts]
    eq(p[1], "LEFT", "anchor: the dot's LEFT edge...")
    check(p[2] == s.label, "anchor: ...against the LABEL")
    eq(p[3], "LEFT", "anchor: ...measured from the label's own left")
    eq(p[4], s.label:GetStringWidth() + 4, "anchor: by the text width -- where the words END, plus a gap")

    -- The proof that it is RE-anchored rather than pinned: move the text and the
    -- dot moves with it on the next repaint, with no rebuild in between. (A font
    -- change is the real-world version of this; the stub's width is 7px a
    -- character, so a longer label is the same lever.)
    s.label:SetText("A Considerably Longer Label")
    s:UpdateOverrideIndicators(3)
    local moved = s.modifiedDot._points[#s.modifiedDot._points]
    eq(moved[4], s.label:GetStringWidth() + 4, "anchor: re-measured on every update, not pinned at build")
end

-- ...and it DISPLACES the "(Global: x)" text rather than sitting under it. That
-- text anchors to the label's ANCHOR right edge, which on a left-anchored label
-- IS the end of the words -- exactly where the dot now is.
do
    local modified = true
    local host = dotHost(function() return modified end)
    host.hooks.getOverrideState = function() return "overridden", 5 end
    local s = boundSlider(host, { frameBorderSize = 3 }, "frameBorderSize")
    check(s.modifiedDot:IsShown() and s.overrideGlobalText:IsShown(),
        "global text: both indicators are up at once")
    local gp = s.overrideGlobalText._points
    check(gp[#gp][2] == s.modifiedDot, "global text: it starts after the DOT while the dot is up")

    modified = false
    s:UpdateOverrideIndicators(3)
    gp = s.overrideGlobalText._points
    check(gp[#gp][2] == s.label, "global text: and back to the label the moment the dot goes")
end

-- ============================================================
-- 9. THE COMMIT CALLBACK RIDES THE WRITE ANNOUNCEMENT
-- ------------------------------------------------------------
-- `onSettingWritten(db, key, value, label, applyFn)` -- the fifth argument is
-- the widget's OWN commit callback, by reference.
--
-- Why the kit has to hand it over rather than let the host find it: the host
-- only ever sees (db, key, value). For a great many settings the work that makes
-- the change VISIBLE is not the host's generic sweep, it is exactly this
-- callback -- so a host replaying an edit later (an undo stack) that has only
-- the value writes the number and leaves the frames where they were. This is
-- the door that fixes that, and it is the widget's job because the widget is the
-- only thing that knows which function it runs as its commit.
--
-- BY REFERENCE, not wrapped: the host stores it on an entry that may outlive the
-- gesture, and a fresh closure per tick would be a new object per step crossed.
-- ============================================================
do
    local host, log = newHost(true)
    log.written = {}
    host.hooks.onSettingWritten = function(db, key, value, label, applyFn)
        log.written[#log.written + 1] =
            { db = db, key = key, value = value, label = label, apply = applyFn }
    end

    local db = { frameBorderSize = 3 }
    local commit = 0
    local onChanged = function() commit = commit + 1 end
    local s = host:CreateSlider(pane(), {
        label     = "Border Thickness",
        min = 0, max = 10, step = 1,
        get       = function() return db.frameBorderSize end,
        set       = function(v) db.frameBorderSize = v end,
        onChanged = onChanged,
        dbRef     = { db = db, key = "frameBorderSize" },
    })
    local sl = s.slider

    -- ---- a drag: every step crossed announces, and every announcement carries
    -- the same reference. (The commit itself still runs once, on release --
    -- forwarding it is not running it.)
    fire(sl, "OnMouseDown", "LeftButton")
    sl:SetValue(5)
    sl:SetValue(7)
    check(#log.written == 2, "apply hand-off: a step crossed is an announcement")
    check(log.written[1].apply == onChanged,
        "apply hand-off: ☠ the fifth argument is the widget's own onChanged, BY REFERENCE")
    check(log.written[2].apply == log.written[1].apply,
        "apply hand-off: ...the same object every tick, not a fresh wrapper")
    eq(log.written[2].label, "Border Thickness", "apply hand-off: and the label still rides in front of it")
    eq(commit, 0, "apply hand-off: forwarding the commit is not running it")

    fire(sl, "OnMouseUp", "LeftButton")
    eq(commit, 1, "apply hand-off: the release is what runs it -- once, as before")

    -- ---- a typed value: the other commit path, same fifth argument
    local input = inputOf(s)
    input:SetText("2")
    fire(input, "OnEnterPressed")
    local last = log.written[#log.written]
    eq(last.value, 2, "apply hand-off: a typed value announces too")
    check(last.apply == onChanged, "apply hand-off: ...carrying the same commit callback")
end

-- A slider with NO onChanged announces a nil apply rather than inventing one --
-- the host then falls back to whatever it does for an unrecorded apply.
do
    local host, log = newHost(true)
    log.written = {}
    host.hooks.onSettingWritten = function(db, key, value, label, applyFn)
        log.written[#log.written + 1] = { value = value, apply = applyFn }
    end
    local db = { frameWidth = 100 }
    local s = host:CreateSlider(pane(), {
        label = "Width", min = 0, max = 200, step = 1,
        get   = function() return db.frameWidth end,
        set   = function(v) db.frameWidth = v end,
        dbRef = { db = db, key = "frameWidth" },
    })
    local input = inputOf(s)
    input:SetText("140")
    fire(input, "OnEnterPressed")
    local last = log.written[#log.written]
    eq(last.value, 140, "no onChanged: the write is still announced")
    check(last.apply == nil, "no onChanged: ...with nothing in the apply slot")
end

-- ...and a host that only reads THREE arguments is unaffected. The hook is
-- positional and the two trailing arguments are additive, so every consumer
-- written before they existed keeps working -- which is the whole reason this
-- was added to the end of the signature rather than to a table.
do
    local host, log = newHost(true)
    log.seen = {}
    host.hooks.onSettingWritten = function(db, key, value)
        log.seen[#log.seen + 1] = value
    end
    local db = { frameWidth = 100 }
    local s = host:CreateSlider(pane(), {
        label = "Width", min = 0, max = 200, step = 1,
        get   = function() return db.frameWidth end,
        set   = function(v) db.frameWidth = v end,
        onChanged = function() end,
        dbRef = { db = db, key = "frameWidth" },
    })
    local input = inputOf(s)
    input:SetText("160")
    fire(input, "OnEnterPressed")
    eq(log.seen[#log.seen], 160, "legacy host: a three-argument hook sees exactly what it always did")
    eq(db.frameWidth, 160, "legacy host: ...and the write landed")
end

-- ---- restore the globals -------------------------------------------
CreateFrame, C_Timer = prevCreateFrame, prevTimer
CreateColor, GetCursorPosition = prevCreateColor, prevCursor
UISpecialFrames, IsMouseButtonDown = prevSpecial, prevMouseDown
