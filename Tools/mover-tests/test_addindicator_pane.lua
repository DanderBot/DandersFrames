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
function GUI:SetSettingsFont() end
function GUI:ShowTooltip() end
function GUI:HideTooltip() end
-- The two state verbs the panel drives every tile and every anchor cell with.
-- Recorded rather than drawn: a tile is only observable here as the state it was
-- last put in.
function GUI:StyleButton(btn, opts)
    opts = opts or {}
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
local placed, frameEff = {}, {}   -- the world the panel asks about
local cardsEnv = {
    CreateFrame = CreateFrame, max = math.max, floor = math.floor,
    ipairs = ipairs, pairs = pairs, type = type, tostring = tostring,
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
