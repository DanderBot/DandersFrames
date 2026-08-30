local NS = ...

-- ============================================================
-- THE "+ ADD INDICATOR" PANEL -- DRIVEN, NOT READ
-- DandersFrames_Options/AuraDesigner/UI/Cards.lua  (S.BuildAddIndicatorPane)
-- DandersFrames_Options/AuraDesigner/UI/Rows.lua   (the addMount builder)
-- DandersFrames_Options/GUI/Controls.lua           (PopoutContent)
-- DandersUI/Sections.lua                           (the settings group)
-- ------------------------------------------------------------
-- This panel shipped opening EMPTY twice, and both diagnoses were about HEIGHT:
-- first that the builder never sized its pane, then that the height it reported
-- was swallowed by a `ready` flag. Neither was the fault, and this file is the
-- reason we now know that -- it drives the REAL builder through the REAL mount
-- into the REAL group and measures what comes out, rather than reading the
-- source and believing it.
--
-- ☠ THE ACTUAL FAULT IS AN ANCHOR, AND IT IS INVISIBLE TO A HEIGHT TEST.
-- Every step of the flow is a pane made by NewPane, which gives it a width and
-- NO HEIGHT, and every choice card on those steps is anchored
--
--     card:SetPoint("TOPLEFT", 0, y)
--     card:SetPoint("RIGHT", pane, "RIGHT", 0, 0)
--
-- "RIGHT" is (right edge, VERTICAL MIDDLE), and the vertical middle of a
-- zero-height frame is its TOP edge. So the second anchor pins the card's own
-- mid-height to the top of the step -- against a TOPLEFT that puts its top edge
-- `y` BELOW that same top. Two vertical constraints, and they disagree: the card
-- is dragged up out of the panel and stretched to twice its offset instead of
-- sitting at cardH. On step 2 and step 3 EVERY visible object is one of those
-- cards, so the panel draws nothing at all.
--
-- The pane's own height was always right -- 120px, reported once, carried to the
-- popout intact -- which is exactly why two height fixes changed nothing.
--
-- ⚠ A HEADLESS RUN CANNOT SEE THE MISPLACEMENT: the fake frames record anchors
-- rather than resolving them, so no assertion here can watch a card land in the
-- wrong place. What it CAN pin is the precondition -- a frame with something
-- anchored to its RIGHT has to have a resolved height -- which is the invariant
-- the fix restores and the one thing that separates this pane from the Layout
-- Groups pane beside it (S.BuildAddLayoutGroupPane), whose cards take the same
-- RIGHT anchor against a host that IS sized.
-- ============================================================

-- ---- a private kit, so nothing here leaks into the shared suites ----
-- Same arrangement as test_sections_group.lua, and for the same reason: this
-- file loads Sections.lua, and loading it into the SHARED table would swap the
-- object the popout suites' live closures were built from.
local UI = {
    MEDIA = "",
    Colors = {
        background = { r = 0.08, g = 0.08, b = 0.08, a = 0.95 },
        text       = { r = 0.9,  g = 0.9,  b = 0.9 },
        textDim    = { r = 0.5,  g = 0.5,  b = 0.5 },
        element    = { r = 0.20, g = 0.21, b = 0.22 },
        border     = { r = 0.31, g = 0.32, b = 0.33 },
        notice     = { r = 0.91, g = 0.66, b = 0.25 },
    },
    RowGap = 14, RowGapTight = 6, RowCompact = {},
    SettingsBox = { group = 280, pad = 10, colMargin = 5, minCol = 285, colGutter = 20,
                    innerGap = 10 },
    PopoutContentWidth = 260,
    PopoutPad = 10,
    PopoutRow = { plate = 44, gap = 6, padX = 10, restFill = 0.55, restBorder = 0.5 },
    _state = {},
    _priv = {
        INFO_BANNER_TONES = {},
        AddTooltipLines = function() end,
        CURSOR_LIFT_X = 0, CURSOR_LIFT_Y = 0,
        CreateElementBackdrop = function(frame, opts) frame._elementOpts = opts return frame end,
    },
}
do
    local SHARED = NS.__DandersUI
    for _, name in ipairs({ "SurfaceStyle", "ResolveSurfaceStyle", "SetSurfaceStyle",
                            "GetSurfaceStyle", "HidePixelBorder",
                            "CreateRoundedSurface", "GetRoundedSurface",
                            "ApplyRoundedChrome", "RemoveRoundedChrome" }) do
        UI[name] = SHARED[name]
    end
end
-- No snapping: every number below is asserted as the arithmetic the layout did.
function UI.SnapLen(_, n) return n end
function UI.ResolveRowHeight(widget, height)
    if widget and widget.fixedRowHeight and widget.preferredHeight then
        return widget.preferredHeight
    end
    return height or (widget and widget.preferredHeight) or 55
end
function UI:GetAccent() return { r = 0.45, g = 0.45, b = 0.95, a = 1 } end
function UI:Hook(name) local h = rawget(self, "hooks") return h and h[name] or nil end
function UI:Call(name, ...) local fn = self:Hook(name) if not fn then return nil end return fn(...) end

-- ---- WoW globals -------------------------------------------------
-- A parent-tracking CreateFrame: PopoutContent MOVES frames between holders and
-- groups, so the tree has to be walkable for the mount to be measurable at all.
local prevCreateFrame = CreateFrame
CreateFrame = function(kind, _, parent)
    local f = FakeUIFrame()
    f._kind = kind
    f._parent = parent
    f._kids = {}
    f.GetParent = function(self) return rawget(self, "_parent") end
    f.SetParent = function(self, p)
        local old = rawget(self, "_parent")
        if type(old) == "table" and rawget(old, "_kids") then
            for i, k in ipairs(old._kids) do
                if k == self then table.remove(old._kids, i) break end
            end
        end
        self._parent = p
        if type(p) == "table" and rawget(p, "_kids") then p._kids[#p._kids + 1] = self end
    end
    f.GetChildren = function(self) return unpack(rawget(self, "_kids") or {}) end
    if type(parent) == "table" and rawget(parent, "_kids") then
        parent._kids[#parent._kids + 1] = f
    end
    return f
end

load_ui_file_into("Sections.lua", { __DandersUI = UI })

local settingsDB = {}
local kitHost = setmetatable({ hooks = { getSettingsDB = function() return settingsDB end } },
                             { __index = UI })

-- ---- the DF-side GUI, delegating the group to the REAL kit --------
local GUI = {
    PopoutContentWidth = 260,
    SelectedMode = "party",
    Colors = UI.Colors,
    RowHeight = { labelPad = 10 },
}
function GUI:CreateSettingsGroup(parent, width, opts)
    return kitHost:CreateSettingsGroup(parent, width, opts)
end
function GUI:CloseAllPopoutRows() end
function GUI:CreateGlyphButton(parent) return CreateFrame("Button", nil, parent) end
function GUI:StyleButton() end
-- The card records the ANCHORS it was given, which is the whole of what this
-- file is about: a card is only observable here as where it was pinned.
function GUI:CreateChoiceCard(parent, opts)
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(58)
    c.layoutHeight = 58
    c._choiceTitle = opts and opts.title
    return c
end
-- The real one walks up for a page or a pane; here it does the half the mount
-- depends on -- re-stamp the slot and re-lay the group out.
local relayouts = {}
function GUI:RelayoutHost(widget, slotHeight)
    relayouts[#relayouts + 1] = slotHeight
    local g = widget and widget.settingsGroup
    if g and g.LayoutChildren then
        for _, entry in ipairs(g.groupChildren or {}) do
            if entry.widget == widget then entry.height = slotHeight break end
        end
        g:LayoutChildren()
    end
end

local DF = { db = { party = {} }, Say = function() end,
             MakeADFilterRef = function() return "ref" end,
             AuraDesigner = { SpecInfo = {} } }
DF.GUIFrame = CreateFrame("Frame", nil, nil)
function DF:IsClassicSettingsLayout() return false end

-- ============================================================
-- 1. THE REAL BUILDER, LIFTED OUT OF Cards.lua
-- Compiled into its own environment, exactly as test_popout_page_tools.lua
-- lifts CreatePopoutPageTools: the file's own locals are globals to a standalone
-- chunk, which is what setfenv is for.
-- ============================================================
local CARDS = options_file_source("AuraDesigner/UI/Cards.lua")
local CARDS_CHUNK = (function()
    local a = CARDS:find("S.BuildAddIndicatorPane = function(host, opts)", 1, true)
    check(a ~= nil, "source: Cards.lua declares S.BuildAddIndicatorPane")
    if not a then return "" end
    local b = CARDS:find("\nend\n", a, true)
    check(b ~= nil and b > a, "source: ...and it closes at the file's own indent")
    return b and CARDS:sub(a, b + 4) or ""
end)()

local S = { SwitchTab = function() end }
local cardsEnv = {
    CreateFrame = CreateFrame, max = math.max, ipairs = ipairs, pairs = pairs, type = type,
    L = setmetatable({}, { __index = function(_, k) return k end }),
    GUI = GUI, S = S, DF = DF,
    C_TEXT_DIM = UI.Colors.textDim, C_TEXT = UI.Colors.text,
    GetThemeColor = function() return { r = 0.4, g = 0.5, b = 0.9 } end,
    BADGE_COLORS = setmetatable({}, { __index = function() return { r = 1, g = 1, b = 1 } end }),
    -- Two items per scope, so a type step is taller than one card and its own
    -- height cannot pass by matching a neighbour's.
    AddFlowScopes = function()
        return {
            placed = { items = { { type = "icon",   label = "Icon",   desc = "d" },
                                 { type = "bar",    label = "Bar",    desc = "d" } },
                       title = "Placed", desc = "d" },
            frame  = { items = { { type = "border", label = "Border", desc = "d" } },
                       title = "Frame-Level Effect", desc = "d" },
            filter = { items = { { type = "border", label = "Border", desc = "d" } },
                       title = "From a Filter", desc = "d" },
        }
    end,
    OpenADPicker = function() end, BuildADPickerRecords = function() return {} end,
    ADCrossBlockText = function() end, ADResolveByID = function() end,
    IsOtherTab = function() return false end, ResolveSpec = function() return nil end,
    RefreshPlacedIndicators = function() end, RefreshPreviewEffects = function() end,
    OpenFilterPicker = function() end, HasFrameEffect = function() return false end,
    IsAuraTypePlaced = function() return false end, AddPickedSpell = function() end,
}
setmetatable(cardsEnv, { __index = _G })
do
    local fn = (loadstring or load)(CARDS_CHUNK, "@AddIndicatorPane")
    check(fn ~= nil, "source: ...and the builder compiles on its own")
    if fn then setfenv(fn, cardsEnv) fn() end
end
check(type(S.BuildAddIndicatorPane) == "function",
      "live: the builder installs itself on the ui-state table")

-- ============================================================
-- 2. THE PANE, DRIVEN
-- ============================================================
print("-- Add Indicator: the pane reports one height, and it is not 1")
local api, host, reported
do
    local holder = CreateFrame("Frame", nil, nil)
    holder:Hide()
    host = CreateFrame("Frame", nil, holder)
    host:SetWidth(260)
    reported = {}
    api = S.BuildAddIndicatorPane(host, {
        width = 260,
        SetHeight = function(h) reported[#reported + 1] = h end,
        Close = function() end,
    })

    check(type(api) == "table" and type(api.Show) == "function",
          "pane: the builder hands back its Show verb")
    eq(#reported, 1, "pane: the first step reports its height exactly once")
    -- ☠ THE NUMBER THAT KILLED TWO FIXES. The pane is 120px at build and always
    -- was -- `Show` sizes the host itself -- so `AddWidget` was never measuring
    -- an unsized frame and the 1px slot both earlier diagnoses described could
    -- not have happened. Pinned as a floor rather than a literal: the note above
    -- the button is unmeasurable before it is drawn and falls back to 12, and a
    -- client that DID measure it would legitimately report more.
    check((reported[1] or 0) >= 100,
          "pane: ...a real height, not the 1px slot the old diagnosis blamed")
    eq(host:GetHeight(), reported[1],
       "pane: ...and the host is sized to the same number it reported")
end

print("-- Add Indicator: every step is a frame with a RESOLVED HEIGHT")
do
    -- ☠ THE BUG. Each step is a NewPane -- a frame given a width and, until this
    -- fix, no height at all. Its choice cards take `SetPoint("RIGHT", pane,
    -- "RIGHT", 0, 0)`, and RIGHT is (right edge, VERTICAL MIDDLE): on a
    -- zero-height frame that middle IS the top edge, so the card's mid-height is
    -- pinned to the top of the step while its TOPLEFT puts its top edge below
    -- that. The two disagree and the card is dragged out of the panel.
    --
    -- Asserted on EVERY step, not just the one on screen: steps 2 and 3 are
    -- nothing BUT choice cards, which is why the panel reads as empty rather
    -- than as merely wrong.
    local steps = {}
    for _, k in ipairs(host._kids) do steps[#steps + 1] = k end
    check(#steps >= 2, "steps: the builder made a step frame per flow step")
    for i, p in ipairs(steps) do
        local want = rawget(p, "paneHeight")
        check(type(want) == "number" and want > 1,
              "steps: step " .. i .. " knows how tall it is")
        eq(p:GetHeight(), want,
           "steps: step " .. i .. " IS that tall, so its RIGHT edge has a middle")
    end
end

print("-- Add Indicator: the scope step is registered, not fallen back to")
do
    -- ⚠ REFUTES A STANDING DIAGNOSIS. `panes` is REASSIGNED to a fresh table
    -- holding both the spell and scope steps, and TypePane's
    -- `panes["type:"..key]` only ever runs from inside Show -- i.e. after that
    -- reassignment -- so both the reassignment AND the type steps land in the
    -- same table. Moving the reassignment below TypePane's first call, or making
    -- TypePane run at build, would strand one of them; this is what says so.
    local spellH = host:GetHeight()
    api.Show("scope")
    local scopeH = host:GetHeight()
    check(scopeH ~= spellH,
          "flow: Show('scope') advances to the scope step rather than re-showing step 1")

    local shown = {}
    for _, p in ipairs(host._kids) do
        if p:IsShown() then shown[#shown + 1] = p end
    end
    eq(#shown, 1, "flow: ...and exactly one step is up at a time")
    eq(shown[1]:GetHeight(), rawget(shown[1], "paneHeight"),
       "flow: ...the one that is up being sized to its own height")

    -- A type step is built on demand and has to arrive sized like the rest.
    api.Show("type:placed")
    local up
    for _, p in ipairs(host._kids) do if p:IsShown() then up = p end end
    check(up ~= nil, "flow: a type step opens")
    if up then
        eq(up:GetHeight(), rawget(up, "paneHeight"),
           "flow: ...and it is sized too, though it was built lazily")
    end
    api.Show("spell")
end

-- ============================================================
-- 3. THE MOUNT, END TO END
-- The real addMount builder out of Rows.lua, through the real PopoutContent, into
-- the real settings group. This is what proves the height chain is sound -- and
-- therefore that a height fix could never have cured the empty panel.
-- ============================================================
print("-- Add Indicator: the reported height reaches the popout pane intact")
do
    local ROWS = options_file_source("AuraDesigner/UI/Rows.lua")
    local ra = ROWS:find("local addMount = tools.PopoutContent(function(g, holder)", 1, true)
    check(ra ~= nil, "source: Rows.lua mounts the pane through PopoutContent")
    local rb = ra and ROWS:find("\n    end)\n", ra, true)
    check(rb ~= nil, "source: ...and the builder literal closes at the tab's indent")

    local addMountBuilder
    if ra and rb then
        -- Up to and including the literal's own `end`, which is 7 characters past
        -- the newline the match started at ("\n" + four spaces + "end").
        local LIT = ROWS:sub(ROWS:find("function(g, holder)", ra, true), rb + 7)
        local rowsEnv = setmetatable({
            CreateFrame = CreateFrame, max = math.max, ipairs = ipairs, pairs = pairs,
            type = type, L = cardsEnv.L, GUI = GUI, S = S, DF = DF,
            PopoutWidth = function() return GUI.PopoutContentWidth or 260 end,
            addRow = nil,
        }, { __index = _G })
        local mk = (loadstring or load)("return " .. LIT, "@addMountBuilder")
        check(mk ~= nil, "source: ...and that literal compiles on its own")
        if mk then setfenv(mk, rowsEnv) addMountBuilder = mk() end
    end

    local CTRL = options_file_source("GUI/Controls.lua")
    local ta = CTRL:find("function GUI:CreatePopoutPageTools(page)", 1, true)
    local tb = ta and CTRL:find("\nend\n", ta, true)
    check(ta ~= nil and tb ~= nil, "source: Controls.lua declares the popout page tools")
    if ta and tb then
        local fn = (loadstring or load)(CTRL:sub(ta, tb + 4), "@CreatePopoutPageTools")
        if fn then
            setfenv(fn, setmetatable({ GUI = GUI, DF = DF, L = cardsEnv.L }, { __index = _G }))
            fn()
        end
    end

    if addMountBuilder and GUI.CreatePopoutPageTools then
        local page = { child = CreateFrame("Frame", nil, nil), children = {} }
        page.child:SetWidth(410)
        function page:RefreshStates() end
        local tools = GUI:CreatePopoutPageTools(page)
        check(tools ~= nil, "mount: the popout layout hands back the tools")

        local addMount, eager = tools.PopoutContent(addMountBuilder)
        eq(#eager.groupChildren, 1, "mount: the eager group holds exactly the pane")
        -- Guarded on the SHAPE before the number: a mutant that stops the pane
        -- reaching the group at all leaves nothing here, and a bare index would
        -- abort the run with a traceback instead of failing an assertion.
        local slot = eager.groupChildren[1]
        check(type(slot) == "table" and type(slot.height) == "number",
              "mount: the eager group's one child is a measured slot")
        if type(slot) == "table" and type(slot.height) == "number" then
            check(slot.height >= 100,
                  "mount: ...at the size the builder asked for, not a 1px one")
            eq(eager:GetHeight(), slot.height,
               "mount: ...so the group is as tall as its one child")
        end

        -- And the panel's own pane, which is what the popout measures on open.
        local outer = CreateFrame("Frame", nil, CreateFrame("Frame", nil, nil))
        outer:SetWidth(260)
        outer:SetHeight(1)
        addMount({}, outer)
        eq(outer:GetHeight(), slot.height,
           "mount: the popout's pane ends the mount at the builder's own height")
    end
end

CreateFrame = prevCreateFrame
