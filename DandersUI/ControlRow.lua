local addonName, NS = ...
local UI = NS.__DandersUI
if not UI then return end

-- ============================================================
-- CONTROL ROW -- a SINGLE-control setting wearing a popout row's plate.
--
-- A page in the new layout is a column of full-width plates: each one is a
-- POPOUT ROW standing for a group of fifteen controls (PopoutRow.lua). But a
-- page is never only groups. Half a dozen settings on any page are one control
-- and nothing else -- a tick, a dropdown, a number -- and there is no group for
-- them to be the way in TO. Those used to stay behind in a 280px inline box
-- beside the bands, which is the one thing a column of plates cannot absorb: a
-- narrower rectangle with its own border, its own title and its own left edge,
-- sitting in a list whose whole argument is that every row starts at the same x.
--
-- So a single-control setting becomes a CONTROL ROW: the SAME plate, carrying
-- the control itself instead of a summary and a way in.
--
--   * a CHECKBOX row draws its tick on the LEFT, at exactly the inset and size a
--     popout row's toggle sits at, and carries NOTHING on the right. That is the
--     whole point of the shape -- a page of popout rows and control rows has ONE
--     vertical line of ticks down its left edge, and a tick that had been moved
--     to the right to "balance" the row would break it.
--   * every OTHER kind puts its label on the left, at the same x a toggle-less
--     popout row's label starts, and its control right-aligned in a fixed column
--     ending M.padX from the plate's right edge -- which is where a popout row's
--     chevron ends.
--
-- ⚠ NO ACTIVE STATE. A popout row has three plate states because it OPENS
-- something and has to say so. A control row opens nothing, so it has two: rest
-- and hover. The accent wash is deliberately absent rather than unimplemented.
--
-- ☠ SHADOW HAZARD -- ALWAYS CALL THE *Native FACTORY NAMES FROM THIS FILE, for
-- exactly the reason Sections.lua and PopoutRow.lua spell out at their heads: a
-- consumer may define POSITIONAL CreateSlider / CreateDropdown / CreateCheckbox /
-- CreateEditBox / CreateButton / CreateLabel on its own host, which shadows the
-- pack's native factories for that consumer only. Everything embedded below goes
-- through the *Native alias. StyleCheckButton, CreateElementBackdrop and
-- OpenColorPicker have no shadowable twin and are called by their plain names.
--
-- ☠ NO CONSUMER MAY BE NAMED HERE, AND NO STRING EITHER. This is the shared
-- library: no addon globals, no SavedVariables, and -- unlike PopoutRow, which
-- has to supply the word "Off" and takes it from `host.hooks.L` -- no
-- user-visible default string of its own. EVERY string a control row draws (its
-- label, a button's caption, a dropdown's options, a tooltip) is handed in by the
-- consumer, already localised, and a button with no caption falls back to the
-- row's own label rather than to a word invented here. If a default is ever
-- needed it comes from `host.hooks.L`, the way PopoutRow's does -- never from a
-- literal in this file.
--
-- Canonical source lives at <repo>/DandersUI; never edit the copies under
-- */Libs/.
-- ============================================================
local CreateFrame = CreateFrame
local type, xpcall, geterrorhandler, tostring = type, xpcall, geterrorhandler, tostring
local format = string.format

local C_TEXT, C_TEXT_DIM = UI.Colors.text, UI.Colors.textDim
local C_ELEMENT, C_BORDER = UI.Colors.element, UI.Colors.border
local C_HOVER = UI.Colors.hover

-- EVERY metric this file draws with is the POPOUT ROW's, read from Theme.lua
-- rather than restated. That is not tidiness -- it is the entire contract of the
-- shape: a control row and a popout row are ONE plate drawn twice, so a retune
-- of the plate height, the corner inset or the rest/hover alphas has to move
-- both at once or the column they share visibly splits in two.
local M = UI.PopoutRow

-- The slot, and the visible PLATE inside it. M.gap of the slot is the gap BELOW
-- the row and nothing is painted there -- the same box model PopoutRow states.
local ROW_H   = M.slot
local PLATE_H = M.plate

-- ☠ THE LABEL'S x IS A CONSTANT, AND IT IS THE SAME CONSTANT ON EVERY KIND.
-- PopoutRow.lua reserves the tick's column whether or not a tick is drawn (see
-- its label anchor and the ☠ above it: a row with a toggle and a row without
-- both start their names here, or a mixed band reads as a ragged list). A
-- control row inherits that rule WHOLE -- a checkbox row draws a tick in the
-- column and a slider row leaves it empty, and both put their label at the same
-- x as each other AND as every popout row in the band.
local LABEL_X = M.padX + M.check + M.labelGap

-- Greyed like every other widget's SetEnabled: 0.4 on the whole thing. The same
-- number PopoutRow.lua dims a dependent-grey row to.
local DIM_ALPHA = 0.4

local DEFAULT_KIND = "checkbox"

-- ============================================================
-- THE CONTROL COLUMN
-- ------------------------------------------------------------
-- ☠ FIXED WIDTHS, ONE PER KIND, AND NOT ONE OF THEM MEASURED. The right edge is
-- shared -- M.padX in from the plate, which is where a popout row's chevron ends
-- -- so a band of control rows right-aligns its controls against one another and
-- against the chevrons of the popout rows between them. A control sized to its
-- content would put every row's control at a different x, which is the ragged
-- list PopoutRow.lua made its own right-hand columns fixed to avoid.
--
-- WHERE THE NUMBERS COME FROM. A band is built at the page's usable width, so
-- these have to be read against a REAL plate rather than against the kit's 280
-- default. At the shipped default window (640 wide) the arithmetic is:
--
--     640 window
--   -  12 window pad  - 155 nav pane - 8 nav gap - 12 window pad  = 453 content
--   -   8 page inset  -  14 scrollbar gutter                      = 431 child
--   -  10 (2 x 5 page column margin)                              = 421 band
--   -  20 (2 x 10 settings-group inset)                           = 401 PLATE
--
-- 401px of plate, of which the label lane gets what the control leaves. The
-- widest kind below (the slider at 170) leaves 401 - LABEL_X(36) - padX(10) -
-- 170 - colGap(6) = 179px of label, which is comfortably more than any settings
-- label in the pack needs. At the FLOOR -- a band built before the content frame
-- has a width falls back to the settings group's own 280, i.e. a 260px plate --
-- the same slider row still leaves 38px of label, so the row degrades by
-- truncating its name rather than by overlapping its control.
--
-- SLIDER = 170. The slider factory pins a 50px value box to its container's
-- right edge and stretches the track to meet it 8px short, so 170 buys
-- 170 - 50 - 8 = 112px of live track. That is the number this width was chosen
-- for: 112px is roughly a pixel per step on the 0-100 ranges this kit's sliders
-- mostly carry, which is the point where a drag stops feeling like a nudge.
-- DROPDOWN = 160, wide enough for the longest option captions in the pack
-- without the opener's own 8px text inset and 20px arrow gutter clipping them.
-- EDITBOX = 80, a number field: four or five digits of the small face plus the
-- box's text insets. A wider one reads as an invitation to type prose.
-- COLOR = 44 x 18, the swatch's own proportions -- a chip, not a button.
-- BUTTON = 90, the kit button's default height at a width that holds two words.
-- ============================================================
local CONTROL_W = {
    checkbox = 0,      -- no right-side control at all: the tick is on the LEFT
    dropdown = 160,
    slider   = 170,
    editbox  = 80,
    color    = 44,
    button   = 90,
}
local CONTROL_H = {
    checkbox = 0,
    -- ⚠ READ FROM THE THEME, NOT RESTATED. A popout row's hoisted control lines
    -- embed the same two factories into the same plate, so these two numbers now
    -- have two readers and exactly one home (Theme.lua's UI.PopoutRow).
    dropdown = M.dropdownH,   -- the standalone opener's own height
    slider   = M.sliderH,     -- the slider factory's own container height (see below)
    editbox  = 20,
    color    = 18,
    button   = 22,
}

-- ☠ THE SLIDER IS CENTRED BY ITS BAR, NOT BY ITS CONTAINER, and 22 is what that
-- costs. Widgets.lua's CreateSlider lays its track at y = -18 with a height of 8
-- (centre -22) and its value box at y = -12 with a height of 20 (centre -22)
-- inside a 50-tall container whose top 18px hold a label this row hides. Centring
-- the CONTAINER on the plate would therefore park the bar 3px low and leave the
-- hidden label's dead space doing the balancing.
--
-- ⚠ COUPLED TO TWO NUMBERS THAT ARE FILE-LOCALS OVER THERE, not tokens. If the
-- slider's internal offsets are ever retuned this has to follow; the test suite
-- pins the resulting anchor so the drift is a red suite rather than a crooked
-- row.
--
-- ⚠ AND IT LIVES IN THE THEME NOW, for the reason the two heights above do: a
-- popout row's hoisted control lines centre the same embedded slider the same
-- way, so the number has two readers and one home.
local SLIDER_BAR_MID = M.sliderBarMid

local function safeCall(fn, ...)
    if type(fn) ~= "function" then return end
    local a, b = ...
    return xpcall(function() return fn(a, b) end, geterrorhandler())
end

-- opts.db may be a TABLE or a FUNCTION returning one, and it is re-resolved on
-- EVERY read rather than captured once -- PopoutRow.lua's rule, for its reason: a
-- consumer whose settings table is swapped underneath it (a party/raid mode
-- switch) would otherwise keep reading the table it was built against forever.
local function resolveDB(v)
    if type(v) == "function" then return v() end
    return v
end

-- {r,g,b[,a]} or {[1],[2],[3][,4]} -> a plain {r,g,b,a}; nil for anything else.
-- (The same normaliser Popout.lua and PopoutRow.lua keep; one shape of colour
-- across the popout family.)
local function normColor(c)
    if type(c) ~= "table" then return nil end
    local r, g, b = c.r or c[1], c.g or c[2], c.b or c[3]
    if not (r and g and b) then return nil end
    return { r = r, g = g, b = b, a = c.a or c[4] or 1 }
end

-- ============================================================
-- THE BINDING
-- ------------------------------------------------------------
-- Three ways a row can be bound to a value, and the answer to all three is one
-- get/set pair plus -- for the case that has one -- the `dbRef` the widget
-- factories take.
--
--   opts.get / opts.set        forwarded verbatim. set() IS the consumer's write
--                              path and the kit does not gate it, exactly as
--                              PopoutRow leaves a {get,set} toggle alone.
--   opts.db (TABLE) + key      the FACTORY's own binding as well as ours. It
--                              reads and writes the table itself and brackets
--                              the write with interceptWrite / onSettingWritten
--                              -- and it is the only form the override markers
--                              and the search index can address, because both
--                              want a stable (table, key) pair.
--   opts.db (FUNCTION) + key   re-resolved on every read, and the hooks are
--                              bracketed HERE. NO dbRef: a table that changes
--                              under the widget cannot be registered as a search
--                              target or marked as overridden, and handing the
--                              factory the table it happened to resolve to at
--                              build time would silently pin it to that one.
--
-- ☠ THE FACTORY-BOUND KINDS TAKE dbRef *OR* get/set, NEVER BOTH. Widgets.lua's
-- slider and dropdown fire interceptWrite / onSettingWritten themselves whenever
-- a dbKey is present and route the value through customSet when there is one --
-- so passing both would run the consumer's setting hooks twice for one edit.
--
-- The fourth return says whether the SETTER IS THE KIT'S. Only a setter written
-- here can honestly report a redirected write (see `commit` below), and a
-- consumer's own set() returning false has to keep meaning nothing.
-- ============================================================
local function makeBinding(host, opts, label)
    if opts.get or opts.set then return opts.get, opts.set, nil, false end

    local key = opts.key
    if key == nil or opts.db == nil then return nil, nil, nil, false end

    local isTable = (type(opts.db) == "table")

    local function get()
        local t = resolveDB(opts.db)
        if t == nil then return nil end
        return t[key]
    end

    -- ☠ A {db, key} BINDING IS A SETTING, AND SETTINGS GO THROUGH THE HOST'S
    -- SETTING HOOKS -- the rule PopoutRow._Write states at length. A consumer may
    -- be running a runtime overlay (the write belongs to a baseline table rather
    -- than the live one) or editing a layout (the write also has to be recorded
    -- as an override), and a control that wrote the key bare would disagree with
    -- every other control bound to the same key.
    -- Answers whether the write LANDED. False means redirected, which the caller
    -- has to hear: a consumer's commit must not run for an edit that never
    -- reached the live table.
    local function set(v)
        local t = resolveDB(opts.db)
        if t == nil then return false end
        -- REDIRECTED: the live value did not change, so the write and the
        -- consumer's own commit are both skipped -- what the slider, the dropdown
        -- and the popout row's tick all do.
        if host:Call("interceptWrite", t, key, v) then return false end
        t[key] = v
        -- The row's label names the control: it has no caption of its own (it IS
        -- the row), so the row's heading is the only thing a consumer could show
        -- for it. `onChanged` rides along as the fifth argument -- by reference --
        -- so a host replaying the edit (an undo stack) can run the apply and not
        -- just the write.
        host:Call("onSettingWritten", t, key, v, label, opts.onChanged)
        return true
    end

    return get, set, (isTable and { db = opts.db, key = key } or nil), true
end

-- ============================================================
-- THE PLATE
-- ------------------------------------------------------------
-- ☠ THIS BLOCK IS A DUPLICATE OF PopoutRow.lua's PLATE, AND IT SHOULD BE
-- FACTORED OUT INTO A SHARED PRIMITIVE (a `UI._priv.CreateRowPlate(row, opts)`
-- handing back the frame, applyPlateShape and paintPlate). It is duplicated
-- rather than shared TODAY for one reason and one only: PopoutRow.lua is owned
-- by another change in flight and cannot be edited in this commit. Whoever
-- touches either file next should do the extraction -- and until then, treat any
-- edit here as an edit that must be made in BOTH places.
--
-- What keeps the two from drifting in the meantime is that every colour and
-- every metric is a Theme.lua token (UI.PopoutRow.*) rather than a literal: the
-- duplication is of the CODE, not of the numbers, so a retheme still moves both
-- shapes together. The tests assert that directly.
--
-- The shape lives in ONE function that the state paint calls with four numbers
-- twice, rather than in shimmed SetBackdropColor methods -- PopoutRow's own
-- reasoning, and it is the half of that file most worth copying faithfully.
-- ============================================================

-- ============================================================
-- THE ROW
-- ============================================================

-- opts:
--   label      REQUIRED. The setting's name (a display string; the consumer
--              localises it). Drawn on the LEFT at the shared label column, and
--              also handed to the embedded factory so the tooltip title, the
--              override markers and the search index all name the same thing
--   kind       "checkbox" | "dropdown" | "slider" | "editbox" | "color" |
--              "button". Default "checkbox". An unrecognised kind builds a plate
--              with a label and no control, and says so through the debug hook
--   db         the settings table, a TABLE or a FUNCTION -> table
--   key        the settings key inside it. See THE BINDING above
--   get/set    an explicit binding instead of db/key
--   onChanged  fn(value) after a committed edit
--   hideOn     fn(db) -> bool. Stamped on the returned frame, so a settings
--              group's LayoutChildren skips the row exactly as it skips any
--              other widget carrying one -- the slot collapses, it does not
--              leave a hole
--   enabled    bool or fn(db) -> bool. False greys the WHOLE row (0.4, the same
--              depth every other widget's SetEnabled lands at) AND disables the
--              embedded control, so a greyed row cannot be edited through
--   accent     {r,g,b[,a]} per-row accent override (else the host accent)
--   surface    the SURFACE STYLE this row's plate wears (Theme.lua's
--              UI.SurfaceStyle). A table rounds the plate at that radius and the
--              style's rowBorderWidth; `false` forces square on a host that has
--              opted in; OMIT and the row takes the host's own declaration
--   tooltip    a spec, or a bare string titled with the row's label. Shown on the
--              ROW's own hover (see the ☠ at the interaction block for why it
--              cannot be left to the embedded factory), and forwarded to that
--              factory as well
--
--   per kind, forwarded to the embedded factory:
--     slider    min, max, step (REQUIRED), lightweight, dbRef is derived
--     dropdown  options, optionsFunc
--     editbox   numeric, maxLetters, placeholder
--     button    text (defaults to the row's label), style, tone, icon, onClick
--     color     hasAlpha, defaultColor
--
-- Returns the row frame with .Refresh() / .refreshContent(db) / .refreshValue(),
-- :SetEnabled(bool), :SetAccent(c), :SetSurface(style) / :GetSurface(),
-- .control (the embedded widget), .plate, .label and .checkButton.
function UI:CreateControlRow(parent, opts)
    local host = self
    opts = opts or {}

    local kind = opts.kind or DEFAULT_KIND
    local labelText = opts.label or ""

    -- A FRAME, not the Button PopoutRow builds. A popout row's click target is
    -- the WHOLE row because the row's one job is to open a panel; a control row's
    -- job belongs to the control, and a plate that also swallowed clicks would
    -- give the user two things to aim at for one setting. The mouse is enabled
    -- anyway -- that is what makes the hover paint below reachable.
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(260, ROW_H)
    row.preferredHeight = ROW_H
    row.fixedRowHeight = true
    row:EnableMouse(true)
    row.isControlRow = true
    row.controlKind = kind
    row._label = labelText

    -- WHICH PART OF THIS FRAME IS INK -- PopoutRow's own note. The row's frame is
    -- its whole layout SLOT and the bottom M.gap of that slot is the gap to the
    -- next row; nothing is painted there. Declared so anything that measures a
    -- row's ink (the popout shell's insetOf, a selection marker) reads the PLATE
    -- rather than the slot around it.
    row.popoutInset = { 0, 0, 0, M.gap }

    -- ⚠ NO rowKind, for PopoutRow's reason: rowKind drives UI.RowCompact's
    -- run-tightening, and a value that is not IN RowCompact silently breaks a run
    -- of checkboxes it sits between. This row's slot already carries the gap it
    -- wants below it.

    -- Stamped, not called: a settings group's LayoutChildren reads `hideOn` off
    -- the widget and evaluates it against the host's own settings db.
    if type(opts.hideOn) == "function" then row.hideOn = opts.hideOn end

    -- ---- chrome ---------------------------------------------------
    -- A FRAME rather than a texture, for PopoutRow's two reasons: the plate
    -- carries a real element backdrop (fill AND a 1px pixel border, which is four
    -- textures on a frame, and a texture cannot own one), and a child frame draws
    -- ABOVE its parent's own layers -- with the control left on the row, the
    -- plate's fill would cover it.
    local plate = CreateFrame("Frame", nil, row, "BackdropTemplate")
    plate:SetPoint("TOPLEFT", 0, 0)
    plate:SetPoint("TOPRIGHT", 0, 0)
    plate:SetHeight(PLATE_H)
    row.plate = plate

    local plateSurface          -- the rounded handle, nil while square

    local function applyPlateShape()
        local s = row._surface
        if not s then
            plateSurface = nil
            UI:RemoveRoundedChrome(plate)
            -- The ORIGINAL call. CreateElementBackdrop re-issues the backdrop AND
            -- re-shows the pixel border, so square is restored rather than
            -- approximated.
            host:CreateElementBackdrop(plate, {
                bgColor     = { C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, M.restFill },
                borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, M.restBorder },
            })
            return
        end
        plateSurface = UI:ApplyRoundedChrome(plate, {
            radius      = s.radius,
            -- The ROW weight, not the panel's -- see UI.SurfaceStyle on why the
            -- one token carries both.
            borderWidth = s.rowBorderWidth or s.borderWidth,
            fill        = { C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, M.restFill },
            border      = { C_BORDER.r, C_BORDER.g, C_BORDER.b, M.restBorder },
        })
    end

    local function paintPlate(fr, fg, fb, fa, br, bg, bb, ba)
        if plateSurface then
            plateSurface:SetFillColor(fr, fg, fb, fa)
            plateSurface:SetBorderColor(br, bg, bb, ba)
        else
            plate:SetBackdropColor(fr, fg, fb, fa)
            plate:SetBackdropBorderColor(br, bg, bb, ba)
        end
    end

    row._surface = UI.ResolveSurfaceStyle(host, opts.surface)
    applyPlateShape()

    row._accent = normColor(opts.accent)

    -- ---- the binding ----------------------------------------------
    local get, set, dbRef, kitOwnsSet = makeBinding(host, opts, labelText)

    -- THE ONE WRITE PATH FOR THE HAND-BUILT KINDS (the tick and the colour chip).
    -- The factory-built kinds have their own -- that is what dbRef buys them --
    -- and this exists so the two behave the same at the one place they can
    -- disagree: a REDIRECTED write must not run the consumer's commit, because
    -- the live value never moved. Only the kit's own setter can say so, which is
    -- what `kitOwnsSet` is for: a consumer's set() returning false keeps meaning
    -- nothing at all.
    local function commit(v)
        local landed = true
        if set then
            local ok = set(v)
            if kitOwnsSet and ok == false then landed = false end
        end
        if landed then safeCall(opts.onChanged, v) end
        return landed
    end

    -- ---- the control ----------------------------------------------
    local width  = CONTROL_W[kind] or 0
    local height = CONTROL_H[kind] or 0

    -- Anchor a built control into the row's control column: right-aligned M.padX
    -- in from the plate's right edge, and centred on the plate's midline. `midY`
    -- is how far the control's TOP sits above that midline, which is half its
    -- height for everything except the slider (see SLIDER_BAR_MID).
    local function placeControl(w, midY)
        w:SetSize(width, height)
        w:ClearAllPoints()
        w:SetPoint("TOPRIGHT", plate, "RIGHT", -M.padX, midY or (height / 2))
    end

    local control          -- the embedded widget, nil for a checkbox row
    local cb               -- the tick, only on a checkbox row
    local swatchFill       -- the colour chip's inner texture, only on a colour row

    if kind == "checkbox" then
        -- ☠ HAND-BUILT FROM THE SHARED STYLER, NOT FROM CreateCheckboxNative, and
        -- that is the one deliberate departure from "embed the kit factory".
        -- CreateCheckbox builds a 35-tall CONTAINER with an 18px box at its top
        -- left and its own caption 6px to the right of that -- three numbers that
        -- are all different from the plate's (M.check 16, M.labelGap 10, a 44px
        -- plate), so embedding it would put this row's tick and name a few pixels
        -- off every popout row's in the same band, which is precisely the
        -- misalignment this whole shape exists to remove.
        --
        -- StyleCheckButton IS the shared factory for a tick -- Widgets.lua says so
        -- itself ("a checkbox created here and a hand-rolled one styled with
        -- StyleCheckButton are the same control"), and it is the same call
        -- PopoutRow makes for its toggle. So this is the same tick as a popout
        -- row's, at the same size, at the same inset.
        cb = CreateFrame("CheckButton", nil, plate, "BackdropTemplate")
        cb:SetPoint("LEFT", plate, "LEFT", M.padX, 0)
        host:StyleCheckButton(cb, { size = M.check, checkSize = M.checkTick,
                                    accent = row._accent, themeRoot = parent })
        row.checkButton = cb
        control = cb

    elseif kind == "dropdown" then
        -- `inline` is the dropdown's own embedded mode: the caption is hidden and
        -- the opener fills the container, so the caller's SetSize decides the
        -- opener's size and its vertical centring. The label is still PASSED --
        -- hidden, not omitted -- because the factory hands it to the override
        -- markers and to the search index, and an empty one would register this
        -- setting under no name at all.
        control = host:CreateDropdownNative(plate, {
            label       = labelText,
            inline      = true,
            options     = opts.options,
            optionsFunc = opts.optionsFunc,
            get         = (not dbRef) and get or nil,
            set         = (not dbRef) and set or nil,
            dbRef       = dbRef,
            onChanged   = opts.onChanged,
            accent      = row._accent,
            tooltip     = opts.tooltip,
        })
        placeControl(control)

    elseif kind == "slider" then
        control = host:CreateSliderNative(plate, {
            label       = labelText,
            min         = opts.min, max = opts.max, step = opts.step,
            get         = (not dbRef) and get or nil,
            set         = (not dbRef) and set or nil,
            dbRef       = dbRef,
            onChanged   = opts.onChanged,
            lightweight = opts.lightweight,
            accent      = row._accent,
            tooltip     = opts.tooltip,
        })
        -- The factory has no `inline`, so its caption is hidden after the fact.
        -- Passed and then hidden for the dropdown's reason: the search index and
        -- the override markers both read it.
        if control.label then control.label:Hide() end
        placeControl(control, SLIDER_BAR_MID)

    elseif kind == "editbox" then
        control = host:CreateEditBoxNative(plate, {
            width      = width, height = height,
            get        = get, set = set,
            onCommit   = opts.onChanged,
            numeric    = opts.numeric,
            maxLetters = opts.maxLetters,
            placeholder = opts.placeholder,
            tooltip    = opts.tooltip,
        })
        placeControl(control)

    elseif kind == "button" then
        control = host:CreateButtonNative(plate, {
            -- A button row's plate already carries the setting's name on the
            -- left, so the caption defaults to it rather than to nothing -- a
            -- consumer that wants a verb ("Reset") passes one.
            text      = opts.text or labelText,
            width     = width, height = height,
            style     = opts.style, tone = opts.tone, icon = opts.icon,
            onClick   = opts.onClick,
            accent    = row._accent,
            themeRoot = parent,
            tooltip   = opts.tooltip,
        })
        placeControl(control)

    elseif kind == "color" then
        -- ☠ HAND-BUILT, BECAUSE THE KIT HAS NO COLOUR-SWATCH FACTORY. The picker
        -- itself is the kit's (UI:OpenColorPicker, ColorPicker.lua) -- it is the
        -- swatch that lives in consumer code today. So the chip is assembled from
        -- the kit's own primitives: an element backdrop for the border, one
        -- texture for the colour, and the kit's picker on click. If a swatch
        -- factory is ever promoted into Widgets.lua this block should be replaced
        -- by a call to it.
        local sw = CreateFrame("Button", nil, plate, "BackdropTemplate")
        host:CreateElementBackdrop(sw, {
            borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, M.restBorder },
        })
        swatchFill = sw:CreateTexture(nil, "ARTWORK")
        swatchFill:SetPoint("TOPLEFT", 1, -1)
        swatchFill:SetPoint("BOTTOMRIGHT", -1, 1)
        sw.swatch = swatchFill

        -- `dfDisabled`, without an underscore, against this pack's usual
        -- private-field convention: it is the name Widgets.lua's own buttons
        -- already early-out on, so a chip that is one day replaced by a kit button
        -- keeps the same refusal without anyone having to notice the rename.
        sw:SetScript("OnClick", function(self)
            if self.dfDisabled then return end
            local cur = normColor(get and get()) or { r = 1, g = 1, b = 1, a = 1 }
            host:OpenColorPicker(cur, opts.hasAlpha and true or false,
                function(c)
                    commit({ r = c.r, g = c.g, b = c.b, a = c.a })
                    row.RefreshValue()
                end,
                nil,
                function(c)
                    -- LIVE PREVIEW. The picker's onChange fires on every drag of
                    -- its wheel, so the chip follows the cursor rather than
                    -- waiting for Accept -- and the write goes with it, because
                    -- the preview a consumer draws is read off the setting.
                    if set then set({ r = c.r, g = c.g, b = c.b, a = c.a }) end
                    if swatchFill then swatchFill:SetColorTexture(c.r, c.g, c.b, 1) end
                end,
                normColor(opts.defaultColor))
        end)

        -- The kit's own grey-when-disabled shape, published under the name every
        -- other widget uses so the row's SetEnabled does not have to know what
        -- kind of control it is holding.
        sw.SetEnabled = function(self, enabled)
            self.dfDisabled = (not enabled) or nil
            self:EnableMouse(enabled and true or false)
            self:SetAlpha(enabled and 1 or DIM_ALPHA)
        end
        sw.refreshValue = function()
            local c = normColor(get and get())
            if c and swatchFill then swatchFill:SetColorTexture(c.r, c.g, c.b, 1) end
        end

        control = sw
        placeControl(control)

    else
        -- An unrecognised kind is a call-site mistake, and the honest answer is a
        -- plate with a name on it plus one line where the consumer's debug output
        -- goes -- not an error thrown at a user reading a settings page.
        local dbg = host:Call("debug", "controlrow")
        if dbg then
            dbg(format("%s: unknown control kind %s", tostring(labelText), tostring(kind)))
        end
    end

    row.control = control

    -- ---- the label ------------------------------------------------
    -- Anchored at BOTH ends rather than sized from its text: the left edge is the
    -- shared column, and the right edge stops M.colGap short of the control (or
    -- M.padX short of the plate on a checkbox row, which has none). A label that
    -- measured itself would run underneath the control on a narrow band instead
    -- of truncating.
    local label = host:CreateLabelNative(plate, { size = M.labelSize, color = C_TEXT })
    label:SetText(labelText)
    label:SetPoint("LEFT", plate, "LEFT", LABEL_X, 0)
    if control and kind ~= "checkbox" then
        label:SetPoint("RIGHT", control, "LEFT", -M.colGap, 0)
    else
        label:SetPoint("RIGHT", plate, "RIGHT", -M.padX, 0)
    end
    label:SetJustifyH("LEFT")
    if label.SetWordWrap then label:SetWordWrap(false) end
    row.label = label

    -- ---- the plate's paint ----------------------------------------
    -- Two states, not PopoutRow's three: rest and hover. See the ⚠ at the head --
    -- a control row never opens a panel, so it has nothing to be ACTIVE about.
    local function paintState()
        local f = row._hovered and C_HOVER or C_ELEMENT
        paintPlate(f.r, f.g, f.b,
                   row._hovered and M.hoverFill or M.restFill,
                   C_BORDER.r, C_BORDER.g, C_BORDER.b, M.restBorder)
        local c = row._enabled == false and C_TEXT_DIM or C_TEXT
        label:SetTextColor(c.r, c.g, c.b, 1)
    end

    -- ---- state ----------------------------------------------------

    local function isEnabled(db)
        if row._enabledOverride ~= nil then return row._enabledOverride end
        local e = opts.enabled
        if e == nil then return true end
        if type(e) == "function" then return e(db) and true or false end
        return e and true or false
    end

    -- Re-read the BOUND VALUE and repaint the control, and nothing else.
    --
    -- ☠ THE FOUR SPELLINGS ARE THE FACTORIES', NOT AN INVENTION HERE. Sections'
    -- RefreshChildValues settled on ONE name -- `refreshValue` -- and the
    -- factories alias their private repaints onto it (the slider's RefreshValue,
    -- the dropdown's UpdateText, the checkbox's Refresh). This delegates to that
    -- name first and falls back to the older public ones, so a control row keeps
    -- working against a kit copy where a factory has not opted in yet.
    function row.RefreshValue()
        local w = control
        if not w then return end
        if kind == "checkbox" then
            if cb then cb:SetChecked(get and get() and true or false) end
            return
        end
        if type(w.refreshValue) == "function" then return safeCall(w.refreshValue, w) end
        if type(w.RefreshValue) == "function" then return safeCall(w.RefreshValue, w) end
        if type(w.Refresh) == "function" then return safeCall(w.Refresh, w) end
        if type(w.refreshContent) == "function" then return safeCall(w.refreshContent, w) end
    end
    -- The group-wide value sweep's one name (Sections' RefreshChildValues). Takes
    -- and ignores its `self`, so `row.refreshValue()` and `row:refreshValue()`
    -- land on the same body.
    row.refreshValue = function() return row.RefreshValue() end

    -- Re-render everything the row displays: the value, the grey state and the
    -- plate. Takes (and ignores) any arguments, so `row.Refresh()`,
    -- `row:Refresh()` and a settings group's `widget:refreshContent(db)` all land
    -- on the same body -- the db is re-resolved here regardless.
    function row.Refresh()
        local db = resolveDB(opts.db)
        local enabled = isEnabled(db)
        row._enabled = enabled

        row.RefreshValue()

        -- Both halves of the grey. The alpha is the statement -- the same 0.4
        -- PopoutRow dims a dependent-grey row to -- and the control's own
        -- SetEnabled is what makes it true: a plate that only faded would still
        -- take the click.
        row:SetAlpha(enabled and 1 or DIM_ALPHA)
        if control and type(control.SetEnabled) == "function" then
            control:SetEnabled(enabled)
        end
        paintState()
    end
    row.refreshContent = function() return row.Refresh() end

    -- Consistent with every other widget's grey path: an explicit call OVERRIDES
    -- opts.enabled from here on, so a page driving disableOn and a row carrying
    -- its own predicate cannot fight each other every refresh.
    function row:SetEnabled(enabled)
        row._enabledOverride = enabled and true or false
        row.Refresh()
        return row
    end

    -- ---- interaction ----------------------------------------------
    -- ☠ THE ROW SHOWS ITS OWN TOOLTIP, BECAUSE FOR HALF THE KINDS NOTHING ELSE
    -- CAN. `tooltip` is forwarded to the embedded factory, and every factory hangs
    -- it on the LABEL it was handed -- which this shape hides, because the row
    -- draws the name itself -- so the attach lands on a hidden, zero-wide region
    -- and can never fire. A CHECKBOX row does not even get that far: its tick is
    -- hand-built from the shared styler, for the reason stated up at that branch,
    -- and never sees the option at all. The plate is the one thing every kind has,
    -- and it already owns the hover.
    --
    -- ⚠ NO HIT FRAME, which is the one place this departs from AttachTooltip. That
    -- helper lays a MOUSE-ENABLED frame over the label region, and a mouse-enabled
    -- child inside the plate takes the hover away from the row -- so the plate
    -- would drop back to rest across the whole width of its own label, which on a
    -- checkbox row is most of it. The row's own OnEnter is already here; it costs
    -- nothing and it cannot fight the paint.
    --
    -- A bare string is wrapped into a spec titled with the row's name -- the same
    -- normalisation the kit's own opener tooltip does, so a consumer may pass
    -- either form.
    row.tooltip = opts.tooltip

    row:SetScript("OnEnter", function()
        row._hovered = true
        paintState()
        local spec = row.tooltip
        if not spec then return end
        if type(spec) == "string" then spec = { title = labelText, lines = { spec } } end
        host:ShowTooltip(row, spec)
    end)
    row:SetScript("OnLeave", function()
        row._hovered = false
        paintState()
        if row.tooltip then host:HideTooltip() end
    end)

    if cb then
        cb:SetScript("OnClick", function(self)
            -- The Refresh runs whether the write landed or not: the tick has
            -- already moved ITSELF by the time this fires, and only a re-read puts
            -- a redirected one back on the live value.
            commit(self:GetChecked() and true or false)
            row.Refresh()
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)
    end

    -- Re-tint the row. nil clears the override and hands it back to the host
    -- accent. Same shape as PopoutRow:SetAccent, minus the bound-panel walk --
    -- this row has nothing open to take with it.
    --
    -- ⚠ A row built WITHOUT an accent registered a theme listener on its tick
    -- (StyleCheckButton does that for an unaccented box), so a later host theme
    -- change will pull that tick back to the host colour even if SetAccent has
    -- since given the row one of its own. Rows whose colour is their own should
    -- pass opts.accent at build.
    function row:SetAccent(c)
        row._accent = normColor(c)
        local col = row._accent or host:GetAccent()
        if cb and cb.ApplyThemeColor then cb.ApplyThemeColor(col) end
        -- `control ~= cb`: on a checkbox row the tick IS the control, and tinting
        -- it twice is the kind of thing that only stays harmless by luck.
        if control and control ~= cb and control.ApplyThemeColor then
            control.ApplyThemeColor(col)
        end
        paintState()
        return row
    end

    -- Change the row's SHAPE. The plate re-issues its chrome and the state paint
    -- REPLAYS through the new shape -- applyPlateShape only writes the rest
    -- colours, so a hovered plate would otherwise come back in the wrong one.
    --
    -- `false` forces square on a host that has opted in; nil hands the row back to
    -- whatever the host declares.
    function row:SetSurface(style)
        row._surface = UI.ResolveSurfaceStyle(host, style)
        applyPlateShape()
        row.Refresh()
        return row
    end

    function row:GetSurface() return row._surface end

    row:SetAccent(opts.accent)
    row.Refresh()
    return row
end
