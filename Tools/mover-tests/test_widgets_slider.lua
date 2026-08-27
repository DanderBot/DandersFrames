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

-- ---- clamped inside the row ----------------------------------------
-- At either end the bubble's centre would sit on the container's edge, putting
-- half the box outside the settings group -- where the page's scroll frame clips
-- it. The stub resolves no anchors, but it records the OFFSET, and that is the
-- number the clamp produces.
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
    -- the container's left -- which is what lets one x serve both.
    local track
    for _, child in ipairs(s._children) do
        if child._kind == "Frame" and child ~= s.dragBubble then track = child break end
    end
    check(track ~= nil, "bubble: found the track the arithmetic is measured off")
    track:SetWidth(200)

    fire(sl, "OnMouseDown", "LeftButton")
    local b = s.dragBubble
    local half = b:GetWidth() / 2

    local function bubbleX()
        local p, _, _, x = b:GetPoint(1)
        eq(p, "BOTTOM", "bubble: it hangs by its bottom edge, above the thumb")
        return x
    end

    sl:SetValue(50)
    eq(bubbleX(), 1 + 0.5 * 198, "bubble: mid-bar it sits on the fill's leading edge")

    sl:SetValue(0)
    eq(bubbleX(), half, "bubble: at the LEFT end it is clamped inside the row")

    -- The RIGHT end of a real row does not need the clamp -- the track stops at
    -- the value box, well inside the container -- so the bubble stays on the
    -- fill's edge there. The clamp is not a no-op though: widen the track to the
    -- whole row (which is what a bar with no value box beside it would be) and
    -- the far end starts to overhang.
    sl:SetValue(100)
    eq(bubbleX(), 199, "bubble: at the right end of a normal row it is NOT clamped")
    track:SetWidth(260)
    sl:SetValue(99); sl:SetValue(100)      -- re-run the placement at the new width
    eq(bubbleX(), 260 - half, "bubble: ...but a full-width track is clamped inside the other edge")
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

-- ---- restore the globals -------------------------------------------
CreateFrame, C_Timer = prevCreateFrame, prevTimer
CreateColor, GetCursorPosition = prevCreateColor, prevCursor
UISpecialFrames, IsMouseButtonDown = prevSpecial, prevMouseDown
