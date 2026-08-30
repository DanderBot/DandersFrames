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
-- ☠ THE ACTUAL FAULT WAS AN ANCHOR, AND IT IS INVISIBLE TO A HEIGHT TEST.
-- The old flow built every step with a frame that had a width and NO HEIGHT, and
-- pinned every card on it twice:
--
--     card:SetPoint("TOPLEFT", 0, y)
--     card:SetPoint("RIGHT", pane, "RIGHT", 0, 0)
--
-- "RIGHT" is (right edge, VERTICAL MIDDLE), and the vertical middle of a
-- zero-height frame is its TOP edge. So the second anchor pins the card's own
-- mid-height to the top of the step -- against a TOPLEFT that puts its top edge
-- `y` BELOW that same top. Two vertical constraints, and they disagree.
--
-- ⚠ A HEADLESS RUN CANNOT SEE THE MISPLACEMENT: the fake frames record anchors
-- rather than resolving them, so no assertion here can watch an object land in
-- the wrong place. What it CAN pin is the PRECONDITION -- every frame this panel
-- anchors something inside has both of its own dimensions -- which is the
-- invariant the fix restored and which the new panel has to keep.
--
-- ☠ AND THE PANEL IS NOT A WIZARD ANY MORE (spec section 26). Three numbered
-- sections stand on one surface: which aura, how it should show, where. The
-- scope step -- Placed on Frame / Frame-Level / From a Filter -- is exactly what
-- the approved design removes, so this file drives the flat flow end to end:
-- pick a source, pick an effect, pick an anchor, commit, and watch which
-- arguments reach the shared add verb.
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
    -- ...and font strings are RECORDED, which the shim does not do. A pane
    -- reports section 1's answer through one, and "the panel says what it was
    -- answered with" is otherwise unobservable in a headless run.
    --
    -- ⚠ AND SO IS TEXT COLOUR, for the reason test_control_row and test_popout_row
    -- already record it the same way: the shim has no SetTextColor, so the
    -- __index fallback swallows it into a no-op and "this line is legible rather
    -- than dimmed to nothing" -- the whole of spec section 28's third state --
    -- would be unobservable. Recorded here rather than in shim.lua so no other
    -- suite's frames change shape.
    f._fs = {}
    local baseCreateFontString = f.CreateFontString
    f.CreateFontString = function(self, ...)
        local fs = baseCreateFontString(self, ...)
        fs.SetTextColor = function(s, r, g, b, a)
            s._textColor = { r = r, g = g, b = b, a = a }
        end
        local t = rawget(self, "_fs")
        if t then t[#t + 1] = fs end
        return fs
    end
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
-- ☠ THE REAL ONE. The add panel's section outline is a RING-ONLY rounded surface
-- (`fill = false`), which is the kit's documented shape for "an outline traced
-- over something that has to stay visible under it" -- so nothing new went into
-- DandersUI, and stubbing it here would leave that claim untested. The shim
-- carries SetTextureSliceMargins/SetTextureSliceMode, so the sliced path is the
-- one taken.
function GUI:CreateRoundedSurface(frame, opts)
    return kitHost:CreateRoundedSurface(frame, opts)
end
-- ...and the host is OPTED IN to the rounded style, as DandersFrames' real one is
-- (GUI.lua's SetSurfaceStyle call). The outline reads its curve off this token
-- rather than carrying a number of its own, so the opted-in path is the one worth
-- driving.
UI.SurfaceStyle = { style = "rounded", radius = 8, borderWidth = 2, rowBorderWidth = 1 }
kitHost:SetSurfaceStyle(UI.SurfaceStyle)
function GUI:GetSurfaceStyle() return kitHost:GetSurfaceStyle() end
function GUI:CloseAllPopoutRows() end
function GUI:CreateGlyphButton(parent) return CreateFrame("Button", nil, parent) end
function GUI:SetSettingsFont() end
function GUI:ShowTooltip() end
function GUI:HideTooltip() end
-- The two state verbs the panel drives every tile and every anchor cell with.
-- Recorded rather than drawn: a tile is only observable here as the state it was
-- last put in.
function GUI:StyleButton(btn, opts)
    opts = opts or {}
    -- Kept, because one of them is load-bearing: a declared width is a MINIMUM to
    -- the real helper, which grows the button to fit a long label unless the
    -- caller opts out.
    btn._styleOpts = opts
    if opts.width or opts.height then
        btn:SetSize(opts.width or btn:GetWidth(), opts.height or btn:GetHeight())
    end
    if opts.text ~= nil then
        btn.Text = btn:CreateFontString()
        btn.Text:SetText(opts.text)
    end
    btn.dfActive, btn.dfDisabled = false, false
    btn.SetActive = function(self, a) self.dfActive = a and true or false end
    btn.SetDisabled = function(self, d) self.dfDisabled = d and true or false end
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

local said = {}
local DF = { db = { party = {} },
             Say = function(_, msg) said[#said + 1] = msg end,
             MakeADFilterRef = function(_, kind, key) return "@" .. kind .. ":" .. key end,
             ADFilterRefDisplayName = function(_, ref) return "Filter " .. ref end,
             AuraDesigner = { SpecInfo = {} } }
DF.GUIFrame = CreateFrame("Frame", nil, nil)
function DF:IsClassicSettingsLayout() return false end

-- ============================================================
-- 1. THE REAL BUILDER, LIFTED OUT OF Cards.lua
-- Compiled into its own environment, exactly as test_popout_page_tools.lua lifts
-- CreatePopoutPageTools: the file's own locals are globals to a standalone
-- chunk, which is what setfenv is for.
--
-- ⚠ THE SLICE STARTS AT THE FLAT EFFECT LIST, not at the builder. The panel's
-- tiles, its anchor picker and its numbered headings are file-locals declared
-- just above it, and stubbing them would test the stubs -- the picture tile in
-- particular is the thing that has to set both of its own dimensions.
-- ============================================================
local CARDS = options_file_source("AuraDesigner/UI/Cards.lua")
local CARDS_CHUNK = (function()
    local a = CARDS:find("local function AddFlowEffects()", 1, true)
    check(a ~= nil, "source: Cards.lua declares the flat effect list")
    local b = CARDS:find("S.BuildAddIndicatorPane = function(host, opts)", 1, true)
    check(b ~= nil and a and b > a, "source: ...above the panel builder that reads it")
    if not (a and b) then return "" end
    local c = CARDS:find("\nend\n", b, true)
    check(c ~= nil and c > b, "source: ...and the builder closes at the file's own indent")
    return c and CARDS:sub(a, c + 4) or ""
end)()

-- The thumbnail arm of the shared canvas, stubbed -- but the OPTS it is handed
-- are recorded, because "the picture is one of our own frames at a size that has
-- both dimensions" is the whole contract between the tile and the canvas.
local previewOpts = {}
local function FakeFramePreview(parent, yOffset, _right, o)
    previewOpts[#previewOpts + 1] = o
    local c = CreateFrame("Frame", nil, parent)
    if o and o.thumb then c:SetSize(o.thumb.w, o.thumb.h) end
    c:SetPoint("TOPLEFT", parent, "TOPLEFT", (o and o.thumb and o.thumb.x) or 0, yOffset)
    local mock = CreateFrame("Frame", nil, c)
    mock:SetSize(125, 64)
    c.mockFrame = mock
    c.healthFill, c.healthBg = mock:CreateTexture(), mock:CreateTexture()
    c.missingHealth = mock:CreateTexture()
    c.nameText, c.hpText = mock:CreateFontString(), mock:CreateFontString()
    return c
end

local S = { SwitchTab = function() end }
local P = {}
local added = {}          -- every AddPickedSpell call, in order
local adFilterOpens = {}  -- ...and every filter-overlay open, with its opts
local placed, frameEff = {}, {}   -- the world the panel asks about
-- The mouse-strip walk, which lives ~2,700 lines ABOVE the slice this file
-- lifts (it is shared with the canvas's thumbnail arm) and is therefore a global
-- to the chunk. A faithful copy rather than a no-op, because the property under
-- test is that the panel CALLS it on its decoration -- a mutant that drops the
-- call leaves a mouse-enabled frame here exactly as it would in game. The REAL
-- walk is pinned by source, in "a tile's picture takes no mouse" at the foot.
local function MakeMouseInert(f)
    if not f then return end
    if f.EnableMouse then f:EnableMouse(false) end
    if f.EnableMouseMotion then f:EnableMouseMotion(false) end
    if f.SetMouseClickEnabled then f:SetMouseClickEnabled(false) end
    if f.SetMouseMotionEnabled then f:SetMouseMotionEnabled(false) end
    if f.GetChildren then
        for i = 1, select("#", f:GetChildren()) do
            MakeMouseInert((select(i, f:GetChildren())))
        end
    end
end

local cardsEnv = {
    CreateFrame = CreateFrame, max = math.max, min = math.min, floor = math.floor,
    ipairs = ipairs, pairs = pairs, type = type, tostring = tostring,
    -- WoW publishes these as globals; the slice reads them as such.
    MakeMouseInert = MakeMouseInert,
    L = setmetatable({}, { __index = function(_, k) return k end }),
    GUI = GUI, S = S, P = P, DF = DF,
    C_TEXT_DIM = UI.Colors.textDim, C_TEXT = UI.Colors.text,
    PlaySound = function() end, SOUNDKIT = { IG_MAINMENU_OPTION_CHECKBOX_ON = 1 },
    GetThemeColor = function() return { r = 0.4, g = 0.5, b = 0.9 } end,
    BADGE_COLORS = setmetatable({}, { __index = function() return { r = 1, g = 1, b = 1 } end }),
    TYPE_DEFAULTS = { icon = { anchor = "TOPLEFT", size = 24 },
                      square = { anchor = "TOPLEFT", size = 24 },
                      bar = { anchor = "BOTTOM", height = 6 } },
    ANCHOR_POSITIONS = { TOPLEFT = { ax = "TOPLEFT", ay = "TOPLEFT" },
                         TOP = { ax = "TOP", ay = "TOP" },
                         TOPRIGHT = { ax = "TOPRIGHT", ay = "TOPRIGHT" },
                         LEFT = { ax = "LEFT", ay = "LEFT" },
                         CENTER = { ax = "CENTER", ay = "CENTER" },
                         RIGHT = { ax = "RIGHT", ay = "RIGHT" },
                         BOTTOMLEFT = { ax = "BOTTOMLEFT", ay = "BOTTOMLEFT" },
                         BOTTOM = { ax = "BOTTOM", ay = "BOTTOM" },
                         BOTTOMRIGHT = { ax = "BOTTOMRIGHT", ay = "BOTTOMRIGHT" } },
    OPTS = { ANCHOR_OPTIONS = {} },
    CreateFramePreview = FakeFramePreview,
    OpenADPicker = function() end, BuildADPickerRecords = function() return {} end,
    -- The filter route's opener. Recorded rather than stubbed blind: what the
    -- panel hands it is the whole of "the filter list opens the way the spell
    -- database does", and the alternative -- an anchored dropdown -- is a
    -- DIFFERENT call with a DIFFERENT argument (`anchor`).
    adFilterOpens = adFilterOpens,
    OpenADFilterPicker = function(o) adFilterOpens[#adFilterOpens + 1] = o end,
    ADCrossBlockText = function() end, ADResolveByID = function() end,
    IsOtherTab = function() return false end, ResolveSpec = function() return nil end,
    GetAuraIcon = function() return "Interface\\Icons\\Spell" end,
    RefreshPlacedIndicators = function() end, RefreshPreviewEffects = function() end,
    OpenFilterPicker = function() end,
    HasFrameEffect = function(name, t) return frameEff[name .. "|" .. t] or false end,
    IsAuraTypePlaced = function(name, t) return placed[name .. "|" .. t] or false end,
    AddPickedSpell = function(name, t, mode, anchor)
        added[#added + 1] = { name = name, type = t, mode = mode, anchor = anchor }
    end,
}
setmetatable(cardsEnv, { __index = _G })
do
    local fn = (loadstring or load)(CARDS_CHUNK, "@AddIndicatorPane")
    check(fn ~= nil, "source: ...and the whole block compiles on its own")
    if fn then setfenv(fn, cardsEnv) fn() end
end
check(type(S.BuildAddIndicatorPane) == "function",
      "live: the builder installs itself on the ui-state table")
check(type(P.CreateFrameTile) == "function",
      "live: ...and publishes the picture tile the Layout Groups panel reuses")

-- ============================================================
-- 2. THE PANEL, DRIVEN
-- ============================================================
print("-- Add Indicator: three sections on one surface, and a real height")
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

    check(type(api) == "table", "panel: the builder hands back its verbs")
    for _, verb in ipairs({ "Sync", "PickSpell", "PickFilter", "SelectType", "Commit" }) do
        check(type(api[verb]) == "function", "panel: ...including " .. verb)
    end
    -- ☠ NO STEP VERB. `Show` was the wizard's, and the wizard is what section 26
    -- removes; a panel that still hands one out is a panel that still has steps.
    check(api.Show == nil, "panel: ...and NOT a step verb, because there are no steps")

    eq(#reported, 1, "panel: the pane reports its height exactly once, at the end")
    -- Three sections, nine picture tiles, an anchor grid and a button do not fit
    -- in anything small. Pinned as a floor rather than a literal: the exact sum
    -- is layout arithmetic and moving a gap by 2px must not fail this file.
    check((reported[1] or 0) >= 380,
          "panel: ...a height with room for all three sections at once")
    eq(host:GetHeight(), reported[1],
       "panel: ...and the host is sized to the same number it reported")
end

print("-- Add Indicator: every frame it anchors inside has a HEIGHT")
do
    -- ☠ THE PRECONDITION THE OLD BUG BROKE, AND ONLY THAT ONE. A frame given a
    -- width and no HEIGHT has its vertical MIDDLE at its own top edge, so anything
    -- anchored LEFT or RIGHT inside it fights whatever TOPLEFT put there. Width is
    -- deliberately NOT asserted: a full-width control legitimately derives its
    -- width from a TOPLEFT/TOPRIGHT pair, which is the vertical answer's mirror
    -- image and is correct. Walked over the whole tree this build produced rather
    -- than over one suspect frame.
    local seen, unsized = 0, {}
    local function walk(f, depth)
        for _, k in ipairs(rawget(f, "_kids") or {}) do
            seen = seen + 1
            local h = k:GetHeight()
            if not (type(h) == "number" and h > 0) then
                unsized[#unsized + 1] = tostring(rawget(k, "_kind")) .. "@" .. depth
            end
            if depth < 4 then walk(k, depth + 1) end
        end
    end
    walk(host, 1)
    check(seen >= 12, "sizing: the panel built a tree worth checking")
    eq(#unsized, 0, "sizing: ...and not one frame in it has an unresolved height")
end

print("-- Add Indicator: section 2 is nine tiles, flat, and dim until asked")
do
    local tiles = {}
    for _, k in ipairs(rawget(host, "_kids") or {}) do
        if rawget(k, "SetTileState") then tiles[#tiles + 1] = k end
    end
    eq(#tiles, 9, "tiles: one per effect -- the taxonomy is gone, not the effects")
    -- ...and each one asked the shared canvas for a THUMBNAIL with a real box.
    eq(#previewOpts, 9, "tiles: every tile draws one of our own frames")
    local bad = 0
    for _, o in ipairs(previewOpts) do
        local t = o and o.thumb
        if not (t and type(t.w) == "number" and t.w > 0
                  and type(t.h) == "number" and t.h > 0) then bad = bad + 1 end
        if not (o and o.placement == false) then bad = bad + 1 end
    end
    eq(bad, 0, "tiles: ...at an explicit size, with the shared drop targets left alone")

    local disabled = 0
    for _, t in ipairs(tiles) do
        if rawget(t, "dfDisabled") then disabled = disabled + 1 end
    end
    eq(disabled, 9, "tiles: with nothing chosen every tile is dimmed...")
    -- ☠ AND ALL NINE HANG OFF THE PANE ITSELF. One surface is the whole point:
    -- a step would be a container between them and the pane, which is exactly the
    -- shape the wizard had and section 26 removes.
    local strays = 0
    for _, t in ipairs(tiles) do if t:GetParent() ~= host then strays = strays + 1 end end
    eq(strays, 0, "tiles: ...and every one is a direct child of the one pane")
end

print("-- Add Indicator: section 1's two routes are peers, and open the same way")
do
    -- ☠ TWO ANSWERS TO ONE QUESTION, DRAWN THE SAME SIZE (spec section 27.2).
    -- The filter route was a 20px ghost line under a 30px primary button and the
    -- user read it as exactly what that draws: "it almost looks like an
    -- afterthought". Measured rather than read, because "equal billing" is a
    -- claim about geometry and a source grep would only prove the words changed.
    local btns = {}
    for _, k in ipairs(rawget(host, "_kids") or {}) do
        local t = rawget(k, "Text")
        local txt = t and t.GetText and t:GetText() or nil
        if txt == "Select a spell" or txt == "Select a filter" then
            btns[txt] = k
        end
    end
    check(btns["Select a spell"] ~= nil, "peers: section 1 offers the spell route")
    check(btns["Select a filter"] ~= nil, "peers: ...and the filter route beside it")
    if btns["Select a spell"] and btns["Select a filter"] then
        eq(btns["Select a filter"]:GetHeight(), btns["Select a spell"]:GetHeight(),
           "peers: ...at the same height, so neither reads as the footnote")
        -- Half a pane each, less the gutter between them. Asserted as "within a
        -- pixel of each other" rather than as a literal: which half absorbs an
        -- odd pane width is layout arithmetic, and equal billing is the claim.
        local dw = (btns["Select a filter"]:GetWidth() or 0)
                 - (btns["Select a spell"]:GetWidth() or 0)
        check(dw >= -1 and dw <= 1, "peers: ...and the same width")

        -- ☠ AND NEITHER MAY GROW TO FIT ITS OWN LABEL. A declared width is a
        -- MINIMUM to the kit: it measures the rendered text and widens the button
        -- rather than clip a long translation. On a button standing alone that is
        -- right; on two pinned side by side it is a collision, because the right
        -- one is pinned by offset and cannot move out of the way. The kit
        -- documents the opt-out for exactly this shape, and both take it.
        local optedOut = 0
        for _, b in pairs(btns) do
            if rawget(b, "_styleOpts") and b._styleOpts.fitText == false then
                optedOut = optedOut + 1
            end
        end
        eq(optedOut, 2, "peers: ...which neither may grow out of for a long translation")
    end

    -- ☠ AND IT OPENS THE FULL OVERLAY, NOT AN ANCHORED DROPDOWN. The two are
    -- told apart by their ARGUMENTS, which is the only difference a headless run
    -- can see: a dropdown is hung under a button and takes `anchor`; the overlay
    -- covers the host the spell database covers and takes none.
    local fb = btns["Select a filter"]
    eq(#adFilterOpens, 0, "peers: nothing is open before the click")
    if fb then fb:GetScript("OnClick")(fb) end
    eq(#adFilterOpens, 1, "peers: clicking the filter route opens the shared overlay")
    local o = adFilterOpens[1] or {}
    eq(o.anchor, nil, "peers: ...with no anchor, because it is not a dropdown")
    check(type(o.onPick) == "function", "peers: ...and a way to take the answer")

    -- ...and that answer lands in section 1, not in a branch of its own. Read
    -- off the TILES, because "it answered section 1" and "it opened something
    -- else" differ precisely in whether section 2 woke: five live tiles -- the
    -- border and the four recolours -- is what a filter source looks like.
    if type(o.onPick) == "function" then o.onPick("preset", "healing") end
    local live = 0
    for _, k in ipairs(rawget(host, "_kids") or {}) do
        if rawget(k, "SetTileState") and not rawget(k, "dfDisabled") then live = live + 1 end
    end
    eq(live, 5, "peers: the overlay's pick answers section 1 and wakes section 2")
    -- Back to a spell, so the tests below start where they always did.
    api.PickSpell("Renew", "Renew")
end

print("-- Add Indicator: section 1 says what it was answered with")
do
    -- ⚠ THE ANSWER MOVED OFF THE BUTTON. It used to be the spell button's own
    -- label, which is what forced that button to span the pane; at half a pane it
    -- would truncate the very name it exists to confirm. Its own line can hold
    -- it, and both routes can write to it.
    --
    -- Read by SWEEPING every font string the pane built rather than by position:
    -- which frame the line lives on is layout, and the claim is that section 1
    -- reports its answer somewhere a reader can see.
    local function PaneSaid(text)
        for _, k in ipairs(rawget(host, "_kids") or {}) do
            for _, fs in ipairs(rawget(k, "_fs") or {}) do
                if fs:GetText() == text then return true end
            end
        end
        return false
    end
    check(PaneSaid("Renew"), "answer: the chosen spell is written under the two routes")
    -- ...and the buttons keep their own labels, because a question that renames
    -- itself to its own answer stops being offerable.
    local kept = 0
    for _, k in ipairs(rawget(host, "_kids") or {}) do
        local t = rawget(k, "Text")
        local txt = t and t.GetText and t:GetText() or nil
        if txt == "Select a spell" or txt == "Select a filter" then kept = kept + 1 end
    end
    eq(kept, 2, "answer: ...and both routes still say what they are")

    -- ...and with nothing chosen it says so, in the panel's own words -- the same
    -- sentence the dimmed tiles give as their reason, rather than a second
    -- phrasing of it for translators to keep in step.
    api.PickSpell(nil)
    check(PaneSaid("Renew"), "answer: a refused pick does not clear the answer")
    api.PickFilter("preset", "healing")
    check(PaneSaid("Filter @preset:healing"),
          "answer: ...and the filter route writes to the same line")
    api.PickSpell("Renew", "Renew")
end

print("-- Add Indicator: the Sound tile carries a mark")
do
    -- ☠ AN UNTOUCHED FRAME IS ALSO WHAT "NOTHING CHOSEN" LOOKS LIKE (spec
    -- section 27.1). Sound is the one effect that changes nothing about the
    -- frame, so its tile honestly draws an unaltered one -- and in a grid of
    -- eight tiles that all show a change, honest read as empty.
    local soundTile
    for _, k in ipairs(rawget(host, "_kids") or {}) do
        local lbl = rawget(k, "label")
        if rawget(k, "SetTileState") and lbl and lbl:GetText() == "Sound Alert" then
            soundTile = k
        end
    end
    check(soundTile ~= nil, "sound: the Sound tile is reachable")
    local mock = soundTile and soundTile.preview and soundTile.preview.mockFrame
    check(mock ~= nil, "sound: ...and draws one of our own frames, like its eight siblings")
    local note
    for _, t in ipairs(mock and rawget(mock, "_textures") or {}) do
        -- ⚠ rawget, NOT GetTexture(). The shim answers any unknown field with a
        -- no-op FUNCTION, so a colour-only texture's GetTexture returns one of
        -- those rather than nil and `or ""` never fires.
        local path = rawget(t, "_texture")
        if type(path) == "string" and path:find("music_note", 1, true) then note = t end
    end
    check(note ~= nil, "sound: ...with a note laid over it, so the tile says what it is")
    -- ☠ A TEXTURE, NOT A WIDGET. Anything on a tile that can take the mouse takes
    -- it across the whole picture -- which is the bug spec section 27 opens with,
    -- where a 220x30 slider over a 76x44 thumbnail made every tile clickable only
    -- in its margin. A texture is not a frame and cannot be clicked.
    local strays = 0
    for _, k in ipairs(rawget(mock, "_kids") or {}) do strays = strays + 1 end
    eq(strays, 0, "sound: ...and nothing clickable was added to the picture")
end

print("-- Add Indicator: a spell wakes section 2, and section 3 follows the type")
do
    placed["Blessing|icon"] = true          -- already placed, so its tile must stay dim
    api.PickSpell("Blessing", "Blessing of Protection")

    local tiles = {}
    for _, k in ipairs(rawget(host, "_kids") or {}) do
        if rawget(k, "SetTileState") then tiles[#tiles + 1] = k end
    end
    local live, dim = 0, 0
    for _, t in ipairs(tiles) do
        if rawget(t, "dfDisabled") then dim = dim + 1 else live = live + 1 end
    end
    eq(dim, 1, "spell: the one effect this aura already has stays dimmed")
    eq(live, 8, "spell: ...and the other eight wake up")

    -- ⚠ SPELL-FIRST REACHES A STATE THE OLD ORDER COULD NOT: a spell that
    -- already carries the chosen effect. The old picker greyed those rows because
    -- the type was known first; here the tile is dimmed AND the refusal is said
    -- out loud, so a click that lands on it is not silently swallowed.
    check(api.SelectType("icon") == false, "spell: an already-placed type is refused")
    eq(said[#said], "Already added.", "spell: ...out loud, not silently")
    check(api.Commit() == false, "spell: ...and nothing is selected to commit")

    check(api.SelectType("square") == true, "spell: a free placed type is selectable")
    check(api.Commit() == true, "spell: ...and commits")
    local last = added[#added]
    eq(last.name, "Blessing", "spell: the add names the aura")
    eq(last.type, "square", "spell: ...the effect")
    eq(last.mode, "placed", "spell: ...and the mode the store needs")
    -- ☠ SECTION 3'S ANSWER REACHES THE STORE. Seeded from the type's own default
    -- and passed through as the fourth argument -- the field every placed
    -- instance already carries, so no new shape.
    eq(last.anchor, "TOPLEFT", "spell: ...with the anchor section 3 was pre-picked to")

    -- ...and CHANGING it is taken. Sync re-asserts the grid from the panel's own
    -- `anchor` on every pass, so a handler that noted the click without keeping it
    -- would put the cell back where it was and the user would watch the click
    -- undo itself.
    do
        local grid
        for _, k in ipairs(rawget(host, "_kids") or {}) do
            if rawget(k, "SetGridEnabled") then grid = k end
        end
        check(grid ~= nil, "anchor: the grid is reachable")
        check(api.SelectType("bar") == true, "anchor: a placed effect opens it")
        local cell = grid and grid.buttons and grid.buttons.BOTTOMRIGHT
        check(cell ~= nil, "anchor: ...with a cell per anchor point")
        if cell then cell:GetScript("OnClick")(cell) end
        check(api.Commit() == true, "anchor: ...and the add commits")
        eq(added[#added].anchor, "BOTTOMRIGHT",
           "anchor: ...carrying the corner that was clicked, not the default")
    end
end

print("-- Add Indicator: a frame-level effect has no position, and says so")
do
    api.PickSpell("Barkskin", "Barkskin")
    check(api.SelectType("border") == true, "frame: a frame-level effect is selectable")
    check(api.Commit() == true, "frame: ...and commits")
    local last = added[#added]
    eq(last.mode, "frame", "frame: ...as a frame-level type config")
    eq(last.anchor, nil, "frame: ...with NO anchor, because it covers the whole frame")
end

print("-- Add Indicator: a filter answers section 1 too, and narrows section 2")
do
    api.PickFilter("preset", "defensive")
    local tiles = {}
    for _, k in ipairs(rawget(host, "_kids") or {}) do
        if rawget(k, "SetTileState") then tiles[#tiles + 1] = k end
    end
    local live = 0
    for _, t in ipairs(tiles) do
        if not rawget(t, "dfDisabled") then live = live + 1 end
    end
    -- Border plus the four recolours. The three placed types have no meaning for
    -- a whole filter, and sound would mean one registration per spell in it.
    eq(live, 5, "filter: only the effects a filter can drive stay live")

    check(api.SelectType("icon") == false,
          "filter: a placed effect cannot be asked of a whole filter")

    check(api.SelectType("healthbar") == true, "filter: a filterable effect is selectable")
    check(api.Commit() == true, "filter: ...and commits")
    local last = added[#added]
    eq(last.name, "@preset:defensive", "filter: the add names the FILTER, not a spell")
    eq(last.mode, "frame", "filter: ...as a frame-level effect")
end

print("-- Add Indicator: Sync re-reads the world an open panel cannot see move")
do
    -- ☠ THE POOLED-BUILD HAZARD. A popout's content is built ONCE per (panel,
    -- row) and the panel is pooled, so a panel that read "already added" only in
    -- its builder is wrong the second time it is opened. Both designer bugs in
    -- spec section 23 were this shape, and one of them shipped with no test.
    api.PickSpell("Rejuvenation", "Rejuvenation")
    local tiles = {}
    for _, k in ipairs(rawget(host, "_kids") or {}) do
        if rawget(k, "SetTileState") then tiles[#tiles + 1] = k end
    end
    local before = 0
    for _, t in ipairs(tiles) do if rawget(t, "dfDisabled") then before = before + 1 end end
    eq(before, 0, "sync: nothing is on this aura yet, so nothing is dimmed")

    -- ...and now the world moves underneath the panel.
    frameEff["Rejuvenation|border"] = true
    placed["Rejuvenation|bar"] = true
    api.Sync()
    local after = 0
    for _, t in ipairs(tiles) do if rawget(t, "dfDisabled") then after = after + 1 end end
    eq(after, 2, "sync: the verb re-derives what the aura has now, without a rebuild")

    -- A selection the world just invalidated is DROPPED, not merely refused at
    -- commit time. Watched through section 3, which is the only surface that can
    -- tell "no selection" from "a selection Commit would have blocked anyway":
    -- the anchor grid is live only while a PLACED effect is chosen.
    local grid
    for _, k in ipairs(rawget(host, "_kids") or {}) do
        if rawget(k, "SetGridEnabled") then grid = k end
    end
    check(grid ~= nil, "sync: the anchor grid is reachable")
    local function gridLive()
        local n = 0
        for _, b in pairs(grid and grid.buttons or {}) do
            if not rawget(b, "dfDisabled") then n = n + 1 end
        end
        return n
    end

    api.PickSpell("Lifebloom", "Lifebloom")
    check(api.SelectType("bar") == true, "sync: a placed effect is chosen")
    eq(gridLive(), 9, "sync: ...which opens section 3's nine cells")
    placed["Lifebloom|bar"] = true
    api.Sync()
    eq(gridLive(), 0, "sync: ...and the world taking it away closes section 3 again")

    local n = #added
    check(api.Commit() == false, "sync: ...with nothing left to commit")
    eq(#added, n, "sync: ...so nothing reached the store")
end

-- ============================================================
-- 2b. THREE STATES, NOT TWO
-- ------------------------------------------------------------
-- ☠ DIM WAS CARRYING TWO MEANINGS AND SAYING NEITHER (spec section 28). "Not
-- yet -- answer the section above" and "not needed -- a recolour has no
-- position" looked identical, and the second is the COMMON case: six of the
-- nine effects are frame-level, so for two thirds of choices section 3 is moot
-- and simply sat there grey, looking broken.
--
-- ⚠ AND "NOT NEEDED" IS NOT THE GREY-WHEN-DISABLED CONVENTION. That convention
-- is for a control that is switched off and could be switched on. A section that
-- does not apply to the choice just made will NEVER apply to it, so dimming it
-- to illegibility hides the fact instead of stating it.
--
-- Driven on a panel of its own: the blocks above have walked the shared one
-- through a dozen sources, and "what does this look like before anything has
-- been answered" is only askable of a fresh build.
-- ============================================================
print("-- Add Indicator: three states -- active, answered, not applicable")
do
    local holder2 = CreateFrame("Frame", nil, nil)
    holder2:Hide()
    local host2 = CreateFrame("Frame", nil, holder2)
    host2:SetWidth(260)
    local paneH2
    local api2 = S.BuildAddIndicatorPane(host2, {
        width = 260,
        SetHeight = function(h) paneH2 = h end,
        Close = function() end,
    })

    local heads, rings, pointer = {}, {}, nil
    for _, k in ipairs(rawget(host2, "_kids") or {}) do
        if rawget(k, "SetHeadState") then heads[#heads + 1] = k end
        if rawget(k, "SetSpan") then rings[#rings + 1] = k end
        for _, t in ipairs(rawget(k, "_textures") or {}) do
            -- ⚠ rawget, NOT GetTexture(): the shim answers any unset field with a
            -- truthy no-op FUNCTION, so `or ""` would never fire on a texture that
            -- has only ever been given a colour.
            local path = rawget(t, "_texture")
            if type(path) == "string" and path:find("expand_more", 1, true) then
                pointer = k
            end
        end
    end
    -- ☠ AND A HEADING NOBODY DRIVES KEEPS THE LOOK IT HAS ALWAYS HAD. The two
    -- Layout Groups panels (Editor.lua) build one of these, ask their single
    -- question and never call the state verb -- so a construction default of
    -- "not yet" would silently dim both of them for no reason.
    local lone = P.CreateNumberedHeading(CreateFrame("Frame", nil, nil), 1, "X", 0, 260)
    eq(lone.caption:GetAlpha(), 1,
       "states: a heading nobody drives is not dimmed by this verb existing")

    eq(#heads, 3, "states: all three numbered sections carry a state")
    eq(#rings, 3, "states: ...and one outline each")
    check(pointer ~= nil, "states: ...and the panel has an arrow toward the commit")

    -- Section 3's reason line, found by what it says rather than by where it is:
    -- which frame it hangs on is layout, and the claim is about its legibility.
    local function GridNote()
        for _, k in ipairs(rawget(host2, "_kids") or {}) do
            for _, fs in ipairs(rawget(k, "_fs") or {}) do
                local t = fs:GetText()
                if t == "This effect changes the whole frame."
                   or t == "Pick a look above." or t == "TOPLEFT" or t == "BOTTOM" then
                    return fs
                end
            end
        end
    end

    local function stateOf(i) return rawget(heads[i] or {}, "dfHeadState") end
    local function activeHeads()
        local n = 0
        for i = 1, 3 do if stateOf(i) == "active" then n = n + 1 end end
        return n
    end
    local function shownRings()
        local n = 0
        for _, r in ipairs(rings) do if r:IsShown() then n = n + 1 end end
        return n
    end

    -- ---- nothing answered ------------------------------------------
    eq(stateOf(1), "active", "states: with nothing chosen section 1 is the one to look at")
    eq(stateOf(2), "todo",   "states: ...section 2 is not yet")
    eq(stateOf(3), "todo",   "states: ...and so is section 3")
    eq(activeHeads(), 1, "states: EXACTLY one section is active at a time")
    eq(shownRings(), 1, "states: ...and exactly one outline is drawn")
    check(rings[1]:IsShown(), "states: ...the one round the section awaiting an answer")
    -- Kept for the frame-level check further down: the ring is lifted as it is
    -- shown, so this is the only moment ring 1 is the active one.
    local liftedLevel = rings[1]:GetFrameLevel()
    check(not pointer:IsShown(),
          "states: nothing points at the commit while the form is unanswered")
    -- ☠ "NOT YET" IS THE ONE STATE THAT MAY DIM, because it is the only one where
    -- dim is honest -- answer the section above and this wakes.
    local todoAlpha = heads[3].caption:GetAlpha()
    eq(todoAlpha, 0.4, "states: a not-yet section dims, which is what dim means here")
    -- ...and the active one is BRIGHT, which is the user's own suggestion: "maybe
    -- that text can highlight instead of being grey on grey".
    eq(rawget(heads[1].caption, "_textColor").r, UI.Colors.text.r,
       "states: the active section's heading is highlighted, not grey on grey")
    eq(rawget(heads[2].caption, "_textColor").r, UI.Colors.textDim.r,
       "states: ...where a not-yet one is not")

    -- ---- section 1 answered ----------------------------------------
    api2.PickSpell("Regrowth", "Regrowth")
    eq(stateOf(1), "answered", "states: answering section 1 marks it answered...")
    eq(stateOf(2), "active",   "states: ...and moves the outline to section 2")
    eq(stateOf(3), "todo",     "states: ...with section 3 still not yet")
    eq(activeHeads(), 1, "states: still exactly one active")
    check(rings[2]:IsShown() and not rings[1]:IsShown(),
          "states: ...and the outline moved rather than multiplied")
    check(not pointer:IsShown(), "states: the form is not answerable yet")

    -- ---- a PLACED effect: section 3 arrives ANSWERED ----------------
    -- ☠ NOT ACTIVE, AND NOT MERELY BECAUSE IT IS LAST. `anchor` is seeded from
    -- TYPE_DEFAULTS every time the type changes and the grid cannot clear it, so
    -- a placed effect reaches section 3 with its answer already in it. Outlining
    -- it would send the reader to a question nobody asked.
    check(api2.SelectType("square") == true, "states: a placed effect is chosen")
    eq(stateOf(3), "answered", "states: section 3 was PRE-PICKED, so it is answered")
    eq(activeHeads(), 0, "states: with nothing left to answer, no section is active")
    eq(shownRings(), 0, "states: ...and no outline is drawn")
    -- ☠ THE POINTER IS NOT THE NOT-APPLICABLE CASE'S DECORATION. A placed effect
    -- with a pre-picked anchor is just as finished as a recolour that never had
    -- one, and section 28 says so explicitly.
    check(pointer:IsShown(),
          "states: the arrow points at the commit whenever the form is answerable")
    check(heads[3].caption:GetAlpha() > todoAlpha,
          "states: ...and an ANSWERED section is not dimmed like a not-yet one")

    -- ---- a FRAME-LEVEL effect: section 3 does not apply -------------
    check(api2.SelectType("border") == true, "states: a frame-level effect is chosen")
    eq(stateOf(3), "na", "states: a border has no position, so section 3 does not apply")
    eq(activeHeads(), 0, "states: ...which is not something to go and answer")
    eq(shownRings(), 0, "states: ...so nothing is outlined")
    check(pointer:IsShown(), "states: ...and the form is finished, so the arrow shows")
    -- ☠ LEGIBLE, NOT DIMMED TO NOTHING. This is the whole complaint -- "grey on
    -- grey" -- and the fix is that the heading keeps full opacity and the reason
    -- is stated, rather than the section fading out of readability.
    eq(heads[3].caption:GetAlpha(), 1,
       "states: a not-applicable heading stays fully legible")
    check(heads[3].caption:GetAlpha() > todoAlpha,
          "states: ...which is what tells it apart from a not-yet one at a glance")
    eq(heads[3].tag:GetText(), "Not needed",
       "states: ...and it says so, beside the heading")
    -- ...while the sections that ARE answered keep the tag empty, so "not needed"
    -- is never written on a section that simply has its answer.
    eq(heads[1].tag:GetText(), "", "states: an answered section carries no such tag")
    eq(heads[2].tag:GetText(), "", "states: ...nor does the one that was just chosen")
    -- ☠ AND THE REASON ITSELF IS AT FULL TEXT COLOUR. "A recolour has no
    -- position" is the fact the reader needs; writing it in the same secondary
    -- grey as an ordinary hint is the half-fix that leaves the section reading
    -- as broken.
    local note = GridNote()
    check(note ~= nil, "states: the section's reason line is reachable")
    eq(note:GetText(), "This effect changes the whole frame.",
       "states: ...and it says WHY, not just that it is unavailable")
    eq(rawget(note, "_textColor").r, UI.Colors.text.r,
       "states: ...in full text colour, so it is legible")
    -- ...and the caption treatments differ from each other, not only from dim.
    eq(rawget(heads[3].caption, "_textColor").r, UI.Colors.text.r,
       "states: a not-applicable heading is drawn bright, not grey on grey")
    eq(rawget(heads[1].caption, "_textColor").r, UI.Colors.textDim.r,
       "states: ...where an answered one stays the quieter secondary colour")

    -- ...and it goes AWAY again for a placed effect. The pair is the claim: a
    -- source assertion could show the branch exists without ever showing that
    -- both sides of it are reachable.
    check(api2.SelectType("bar") == true, "states: back to a placed effect")
    eq(stateOf(3), "answered", "states: ...and section 3 applies again")
    eq(heads[3].tag:GetText(), "", "states: ...with the not-needed tag withdrawn")
    local note2 = GridNote()
    eq(note2 and rawget(note2, "_textColor").r, UI.Colors.textDim.r,
       "states: ...and the line goes back to being an ordinary hint")
    eq(rawget(heads[3].caption, "_textColor").r, UI.Colors.textDim.r,
       "states: ...as does the heading it belongs to")

    -- ---- the outline itself ----------------------------------------
    print("-- Add Indicator: the outline takes no mouse and never leaves the pane")
    for i, r in ipairs(rings) do
        -- ☠ EXACTLY THE PANE'S WIDTH. PopoutRow wraps a pane taller than 60% of
        -- the screen in a ScrollFrame of exactly the pane's width, and a
        -- ScrollFrame CLIPS -- so a ring drawn a few pixels proud would be whole
        -- on a tall screen and shaved on a short one. This panel is over that cap
        -- already, so the wrapped case is the ordinary one, not the exotic one.
        eq(r:GetWidth(), 260, "outline: section " .. i .. "'s ring is the pane's width")
        local _, _, ry = r:GetPoint(1)
        check(type(ry) == "number" and ry <= 0,
              "outline: ...anchored inside the pane's top edge")
        check(type(ry) == "number" and (ry - r:GetHeight()) >= -(paneH2 or 0),
              "outline: ...and ending inside its bottom one")
        -- ☠ NOTHING DRAWN OVER A CONTROL MAY TAKE ITS CLICKS. This frame covers
        -- nine tiles, two buttons and a nine-cell grid; a slider laid over a tile
        -- made the whole picture unclickable twice (spec section 27).
        -- ...and its curve is the kit's ONE surface token, not a number of its
        -- own. An inner surface carrying its own radius is the site left behind
        -- when the token is retuned.
        local surf = UI:GetRoundedSurface(r)
        check(surf ~= nil, "outline: ...drawn as a kit rounded surface")
        eq(surf and surf.radius, UI.SurfaceStyle.radius,
           "outline: ...at the host's own radius")
        eq(surf and surf.borderWidth, UI.SurfaceStyle.rowBorderWidth,
           "outline: ...and the inner-surface ring weight")
        eq(rawget(r, "_flags").mouse, false, "outline: ...and it takes no mouse")
        eq(#(rawget(r, "_kids") or {}), 0,
           "outline: ...being textures on one frame, with nothing clickable in it")
    end
    -- ...and the three do not overlap each other, which is what the gaps between
    -- the sections were widened for. Read off the anchors rather than asserted as
    -- literals: the spans are the layout's own running offsets.
    for i = 1, 2 do
        local _, _, top = rings[i]:GetPoint(1)
        local _, _, nextTop = rings[i + 1]:GetPoint(1)
        check(type(top) == "number" and type(nextTop) == "number"
              and (top - rings[i]:GetHeight()) > nextTop,
              "outline: section " .. i .. "'s ring clears section " .. (i + 1) .. "'s")
    end
    -- ☠ RAISED ABOVE THE CONTENT, because a texture cannot draw over a SIBLING
    -- frame at the same level -- draw layer loses to frame level, and the ring's
    -- left and right runs land on the outer tiles' own edges. Taken off ring 1,
    -- which the panel lifted on its very first Sync (see `liftedLevel` above,
    -- captured while it was the one on screen).
    local tileLevel
    for _, k in ipairs(rawget(host2, "_kids") or {}) do
        if rawget(k, "SetTileState") then tileLevel = k:GetFrameLevel() end
    end
    check(tileLevel ~= nil and liftedLevel ~= nil and liftedLevel > tileLevel,
          "outline: the active ring is raised above the controls it is drawn over")

    -- ☠ THE POINTER IS PURE DECORATION TOO. It sits directly over the panel's one
    -- primary button's approach, and a widget there would be the tile bug again.
    eq(rawget(pointer, "_flags").mouse, false, "pointer: the arrow takes no mouse")
    eq(#(rawget(pointer, "_kids") or {}), 0,
       "pointer: ...and is a texture and a string, not a control")
    -- ⚠ A RESERVED SLOT, not a grown one. The pane is pooled and reports its
    -- height ONCE; showing and hiding the pointer must not change that number.
    local before = paneH2
    api2.PickSpell("Regrowth", "Regrowth")
    api2.SelectType("border")
    check(pointer:IsShown(), "pointer: shown once the form is answerable")
    eq(paneH2, before, "pointer: ...without the pane re-reporting its height")
    eq(host2:GetHeight(), before, "pointer: ...or resizing itself")
end

-- ============================================================
-- 2c. THE STATES ARE DISTINGUISHABLE, AND ONLY ONE OF THEM DIMS
-- ------------------------------------------------------------
-- Colour is the half a headless run cannot see: the shim has no SetTextColor, so
-- the three treatments are indistinguishable to a driven assertion beyond their
-- alpha. Pinned by source instead -- and SCOPED to the verb's own body with its
-- comments stripped, because a file-wide search for "C_TEXT" answers "is this
-- token anywhere in 4,900 lines" and would pass however the verb was written.
-- ============================================================
print("-- Add Indicator: the three treatments differ, in the verb that draws them")
do
    local function StripComments(src)
        local out = {}
        for line in (src .. "\n"):gmatch("([^\n]*)\n") do
            if not line:match("^%s*%-%-") then out[#out + 1] = line end
        end
        return table.concat(out, "\n")
    end
    local function Body(startNeedle, endNeedle)
        local a = CARDS:find(startNeedle, 1, true)
        if not a then return "" end
        local b = CARDS:find(endNeedle, a, true)
        if not b then return "" end
        return StripComments(CARDS:sub(a, b))
    end

    local verb = Body("head.SetHeadState = function(self, state, tagText)",
                      "\n    head:SetHeadState(")
    check(verb ~= "", "treatment: the heading's state verb is reachable in source")
    check(verb:find("SEC_TODO", 1, true) ~= nil and verb:find("0.4", 1, true) ~= nil,
          "treatment: only the not-yet state dims")
    check(verb:find("SEC_ACTIVE", 1, true) ~= nil and verb:find("SEC_NA", 1, true) ~= nil,
          "treatment: active and not-applicable are named states, not one 'enabled'")
    check(verb:find("C_TEXT%.") ~= nil and verb:find("C_TEXT_DIM%.") ~= nil,
          "treatment: ...and they are drawn in two different colours")
    -- ☠ THE OLD BOOLEAN IS GONE. A SetHeadEnabled left standing beside the state
    -- verb is a second way to draw a section, and it can only ever draw two of
    -- the four -- the two that were being confused.
    check(CARDS:find("SetHeadEnabled", 1, true) == nil,
          "treatment: the two-state verb it replaces is gone, not left beside it")

    -- ...and the reason a not-applicable section gives stays readable. Scoped to
    -- the state block inside Sync for the same reason.
    local sync = Body("local sec3NA = (pick ~= nil) and not placedPick", "\n    end\n")
    check(sync ~= "", "treatment: Sync's state derivation is reachable")
    check(sync:find("sec3NA", 1, true) ~= nil and sync:find("SEC_NA", 1, true) ~= nil,
          "treatment: a frame-level effect makes section 3 not-applicable, not not-yet")
    check(sync:find("gridNote:SetTextColor(C_TEXT.r", 1, true) ~= nil,
          "treatment: ...and its reason is written in full text colour, not the dim one")

    -- ☠ AND THE OUTLINE IS THE KIT'S RING, NOT A HAND-ROLLED BOX. `fill = false`
    -- is CreateRoundedSurface's documented shape for "an outline traced over
    -- something that has to stay visible under it", so nothing new was added to
    -- DandersUI for this.
    local ring = Body("local function CreateSectionOutline(parent, width)",
                      "\nP.CreateSectionOutline")
    check(ring ~= "", "treatment: the outline factory is reachable")
    check(ring:find("GUI:CreateRoundedSurface", 1, true) ~= nil
          and ring:find("fill        = false", 1, true) ~= nil,
          "treatment: the outline is the kit's ring-only surface")
    check(ring:find("MakeMouseInert(ring)", 1, true) ~= nil,
          "treatment: ...walked mouse-inert after the surface exists")
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

    local addMountBuilder, collected
    if ra and rb then
        -- Up to and including the literal's own `end`, which is 7 characters past
        -- the newline the match started at ("\n" + four spaces + "end").
        local LIT = ROWS:sub(ROWS:find("function(g, holder)", ra, true), rb + 7)
        collected = {}
        local rowsEnv = setmetatable({
            CreateFrame = CreateFrame, max = math.max, ipairs = ipairs, pairs = pairs,
            type = type, L = cardsEnv.L, GUI = GUI, S = S, DF = DF,
            PopoutWidth = function() return GUI.PopoutContentWidth or 260 end,
            addRow = nil, addPanes = collected,
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
            check(slot.height >= 380,
                  "mount: ...at the size the builder asked for, not a 1px one")
            eq(eager:GetHeight(), slot.height,
               "mount: ...so the group is as tall as its one child")
        end

        -- ☠ AND THE MOUNT COLLECTED THE PANEL'S Sync VERB. Without this the row
        -- has nothing to call on open and the panel is stale on its second
        -- opening -- the bug spec section 23 records, in a new place.
        eq(#(collected or {}), 1, "mount: the row keeps the panel's Sync verb")
        check(collected and type(collected[1]) == "table"
              and type(collected[1].Sync) == "function",
              "mount: ...which is the verb, not the pane")

        -- And the panel's own pane, which is what the popout measures on open.
        -- Guarded on the slot being a real number for the reason the check above
        -- is: a mutant that stops the builder reporting leaves the group's slot
        -- unset, and mounting a second instance against it aborts the RUN inside
        -- the kit's layout pass instead of failing an assertion here.
        if type(slot) == "table" and type(slot.height) == "number" then
            local outer = CreateFrame("Frame", nil, CreateFrame("Frame", nil, nil))
            outer:SetWidth(260)
            outer:SetHeight(1)
            addMount({}, outer)
            eq(outer:GetHeight(), slot.height,
               "mount: the popout's pane ends the mount at the builder's own height")
        end
    end
end

-- ============================================================
-- 4. THE THUMBNAIL ARM OF THE SHARED CANVAS
-- Read rather than driven: CreateFramePreview is 500 lines of client-facing
-- geometry and lifting it whole would be testing the shim. What matters here is
-- the ONE property the tile depends on and the panel's old bug turned on -- the
-- box has both of its dimensions, set at construction.
-- ============================================================
print("-- Add Indicator: the canvas's thumbnail arm sizes its own box")
do
    check(CARDS:find("container:SetSize(thumb.w or 76, thumb.h or 44)", 1, true) ~= nil,
          "thumb: the thumbnail box takes an explicit width AND height")
    check(CARDS:find('container:SetPoint("TOPLEFT", parent, "TOPLEFT", thumb.x or 0, yOffset)',
                     1, true) ~= nil,
          "thumb: ...and one anchor, rather than the band form's four")
    -- ⚠ THE FIT MUST BE COMPUTABLE AT BUILD. A four-sided anchor answers 0 until
    -- the layout pass, which would send the fit down the early exit -- and a
    -- thumbnail never changes size, so OnSizeChanged would never rescue it.
    check(CARDS:find("if thumb then container.RefreshGeometry() end", 1, true) ~= nil,
          "thumb: ...so the fit is run once, at construction")
    -- ...and the user's Preview Scale is not obeyed by a 76px tile.
    check(CARDS:find("if cw < 2 or ch < 2 then place(0.5) return end", 1, true) ~= nil,
          "thumb: a thumbnail scales to its box")
    check(CARDS:find("place(math.max(0.1, math.min((cw - THUMB_PAD * 2) / w,", 1, true) ~= nil,
          "thumb: ...on both axes, ignoring the canvas's own slider")
end

CreateFrame = prevCreateFrame

-- ============================================================
-- A TILE'S PICTURE TAKES NO MOUSE
-- ------------------------------------------------------------
-- ☠ A tile is a Button and its preview is a child. Any descendant of that
-- preview that is mouse-enabled swallows the press over the very picture the
-- button exists to offer -- and the button never lights either, because the
-- hover never reaches it. Reported twice in game: "none of the images are
-- clickable, i have to click somewhere outside the image", then "dont even get a
-- hover highlight on the button when hovering".
--
-- ⚠ A WALK, NOT A LIST. The first attempt chased ONE taker (the canvas's scale
-- slider, which a thumbnail was building by falling through the non-compact arm)
-- and the tiles stayed dead. The preview builds a backdrop, a mock, a border
-- overlay and whatever the effect paints on top; naming them is a list that
-- rots.
--
-- ⚠ AND IT MUST RUN AFTER Paint -- the effect art is added once the preview
-- builder has returned, so a walk run inside it misses exactly the frames drawn
-- over the picture.
-- ============================================================
print("-- Add panel: a tile's picture takes no mouse")
do
    local CARDS = options_file_source("AuraDesigner/UI/Cards.lua")
    check(CARDS:find("function container.DisableMouseTree()", 1, true) ~= nil,
          "tile mouse: the preview publishes a verb that strips its whole subtree")
    check(CARDS:find("if f.GetChildren then", 1, true) ~= nil,
          "tile mouse: ...and it walks children rather than naming frames")
    local paintAt = CARDS:find("if opts.Paint then opts.Paint(pv) end", 1, true)
    local stripAt = CARDS:find("if pv.DisableMouseTree then pv.DisableMouseTree() end", 1, true)
    check(stripAt ~= nil, "tile mouse: the tile calls it")
    check(paintAt and stripAt and stripAt > paintAt,
          "tile mouse: ...AFTER Paint, so the effect art is stripped too")
end
