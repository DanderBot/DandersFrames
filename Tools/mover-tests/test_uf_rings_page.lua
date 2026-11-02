local NS = ...

-- ============================================================
-- UNIT FRAMES SETTINGS -- THE FRAME STYLE PAGE'S RINGS CARD
-- DandersFrames_Options/UnitFrames/Pages.lua, the FRAME STYLE section, cut out and
-- RUN (UFO.BuildRingsPage) over stub widgets and the real Rings.lua. Checked: the
-- summary lines, the overlap maths, one ring open at a time, the rows and their
-- order, add / remove / move, the limits, the hide and grey wiring, what each
-- control writes (the saved shape unchanged), and that clicking around makes no new
-- frames once each widget exists. The band is a stub, so this is not a layout test
-- and says nothing about how the card looks: that is for the game.
-- ============================================================

local G, G_NAMES = {}, { "DandersFrames", "CreateFrame", "issecretvalue", "LibStub", "C_Timer" }
for _, k in ipairs(G_NAMES) do G[k] = _G[k] end

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

issecretvalue = function() return false end
LibStub = nil
local deferred = {}
C_Timer = { After = function(_, fn) deferred[#deferred + 1] = fn end }

-- ---- stub frames: counted, so a leak shows ------------------------------------
local made = 0
local function noop() end
local FrameMT = { __index = function(_, k)
    if type(k) == "string" and k:match("^%u") then return noop end
end }
local function Frame()
    made = made + 1
    local f = setmetatable({ shown = true, alpha = 1, scripts = {} }, FrameMT)
    f.Show = function(self) self.shown = true end
    f.Hide = function(self) self.shown = false end
    f.SetShown = function(self, v) self.shown = v and true or false end
    f.IsShown = function(self) return self.shown end
    f.SetAlpha = function(self, a) self.alpha = a end
    f.SetText = function(self, t) self.textValue = t end
    f.SetScript = function(self, n, fn) self.scripts[n] = fn end
    f.CreateFontString = function() return Frame() end
    return f
end

-- ---- the real ring maths ------------------------------------------------------
local DF = { PartyDefaults = {}, registered = {} }
DF.L = setmetatable({}, { __index = function(_, k) return k end })
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable(key, spec) self.registered[key] = spec; return true end
function DF:ListDesignerPresets() return { "Default", "A" } end
DandersFrames = DF
CreateFrame = nil
local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Defaults.lua", UF)
CreateFrame = function() return Frame() end
load_uf_file_into("Elements.lua", UF)
load_uf_file_into("Rings.lua", UF)
DF.UnitFrames = UF
local R = UF.Rings

print("-- Rings page: the overlap maths")
do
    local function ring(...) return { sections = { ... } } end
    local function S(cov, pos) return { bar = "HEALTH", coverage = cov, position = pos } end
    check(not R.RingOverlaps(ring(S("FULL"))), "one section never overlaps")
    check(not R.RingOverlaps(ring()), "no sections")
    check(not R.RingOverlaps({}), "a ring with no list")
    check(not R.RingOverlaps(ring(S("HALF", "TOP"), S("HALF", "BOTTOM"))), "top and bottom halves meet, no overlap")
    check(not R.RingOverlaps(ring(S("HALF", "LEFT"), S("HALF", "RIGHT"))), "left and right halves")
    check(R.RingOverlaps(ring(S("HALF", "TOP"), S("HALF", "TOP"))), "two arcs on the same side overlap")
    check(R.RingOverlaps(ring(S("HALF", "TOP"), S("HALF", "LEFT"))), "top and left halves share a quarter")
    check(R.RingOverlaps(ring(S("FULL"), S("QUARTER", "TOP"))), "a full ring plus anything")
    check(R.RingOverlaps(ring(S("QUARTER", "BOTTOM"), S("FULL"))), "...in either order")
    check(not R.RingOverlaps(ring(S("QUARTER", "TOP"), S("QUARTER", "BOTTOM"))), "opposite quarters")
    check(not R.RingOverlaps(ring(S("QUARTER", "TOP"), S("QUARTER", "LEFT"))), "neighbouring quarters only touch")
    check(R.RingOverlaps(ring(S("QUARTER", "TOP"), S("QUARTER", "TOPLEFT"))), "a side and the corner beside it")
    check(R.RingOverlaps(ring(S("HALF", "BOTTOM"), S("QUARTER", "BOTTOM"))), "wrapping through the bottom still counts")
    check(not R.RingOverlaps(ring(S("HALF", "TOP"), S("QUARTER", "BOTTOM"))), "a quarter clear of a half")
    check(not R.RingOverlaps(ring(S("QUARTER", "TOP"), S("QUARTER", "RIGHT"), S("QUARTER", "BOTTOM"), S("QUARTER", "LEFT"))),
          "four quarters round the ring")
    check(R.ArcsOverlap(0.9, 0.2, 0.05, 0.1), "ArcsOverlap: an arc wrapping past 0")
    check(not R.ArcsOverlap(0.25, 0.25, 0.5, 0.25), "ArcsOverlap: touching ends do not")
end

-- ---- the stub kit -------------------------------------------------------------
local function Bound(kind, label, get, set, cb)
    local w = Frame()
    w.kind, w.labelText, w.get, w.set, w.cb = kind, label, get, set, cb
    w.refreshed = 0
    w.refreshValue = function(self) self.refreshed = self.refreshed + 1 end
    w.SetEnabled = function(self, on) self.enabledState = on end
    return w
end

local GUI = {
    Colors = { element = { r = 0.1, g = 0.1, b = 0.1 }, border = { r = 0.3, g = 0.3, b = 0.3 },
               text = { r = 1, g = 1, b = 1 } },
}
function GUI:CreateElementBackdrop() end
function GUI:SetSettingsFont() end
function GUI:ToneHex() return "ffffaa00" end
function GUI:ShowTooltip(_, spec) self.lastTip = spec end
function GUI:HideTooltip() end
function GUI:CreateGlyphButton(_, opts)
    local b = Frame()
    b.opts, b.tipValue = opts, opts.tooltip
    b.SetGlyphEnabled = function(self, on) self.glyphOn = on end
    return b
end
function GUI:CreateCloseButton(_, opts)
    local b = Frame()
    b.opts = opts
    b.SetEnabled = function(self, on) self.enabledState = on end
    return b
end
function GUI:StyleButton(btn, opts)
    btn.styled = opts
    btn.Text = Frame()
    btn.Text:SetText(opts.text)
    btn.SetEnabled = function(self, on) self.enabledState = on end
end
function GUI:CreateDropdown(_, label, options, db, key, cb, get, set, opts)
    local w = Bound("dropdown", label, get or function() return db[key] end, set or function(v) db[key] = v end, cb)
    w.options, w.dropOpts = options, opts
    w.rebuilds = 0
    w.RebuildOptions = function(self, o) self.options = o; self.rebuilds = self.rebuilds + 1 end
    return w
end
function GUI:CreateSlider(_, label, lo, hi, step, db, key, cb, light, _, get, set)
    local w = Bound("slider", label, get or function() return db[key] end, set or function(v) db[key] = v end, cb)
    w.lo, w.hi, w.step, w.light = lo, hi, step, light
    return w
end
function GUI:CreateCheckbox(_, label, db, key, cb, get, set)
    return Bound("checkbox", label, get or function() return db[key] end, set or function(v) db[key] = v end, cb)
end
function GUI:CreateSegmentToggle(_, segments, _, _, _, opts)
    local w = Frame()
    w.segments, w.opts = segments, opts
    w.refreshes = 0
    w.Refresh = function(self) self.refreshes = self.refreshes + 1 end
    w.SetEnabled = function(self, on) self.enabledState = on end
    return w
end
function GUI:CreateHeader(_, text)
    local w = Frame()
    w.kind, w.labelText = "header", text
    return w
end
function GUI:CreateLabel(_, text)
    local w = Frame()
    w.kind, w.labelText = "label", text
    return w
end
function GUI:CreateNote(_, text, opts)
    local w = Frame()
    w.kind, w.labelText, w.noteOpts = "note", text, opts
    return w
end
GUI.StampFullRows = function(band)
    for _, e in ipairs(band.groupChildren) do
        if rawget(e.widget, "refreshValue") == nil and rawget(e.widget, "fullRow") == nil then e.widget.fullRow = true end
    end
end
GUI.quietRuns = 0
GUI.QuietLabels = function() GUI.quietRuns = GUI.quietRuns + 1 end

-- The band: the kit's own child list and grey sweep, reduced to what this page asks.
local function Band()
    local b = Frame()
    b.groupChildren = {}
    b.dfTwoTrack, b.dfQuietLabels = true, true
    function b:AddWidget(w, height)
        self.groupChildren[#self.groupChildren + 1] = { widget = w, height = height }
        w.settingsGroup = self
        return w
    end
    function b:Sweep(db)
        for _, e in ipairs(self.groupChildren) do
            local w = e.widget
            w:Show()
            if rawget(w, "SetEnabled") and rawget(w, "disableOn") then
                local off = w.disableOn(db)
                w:SetEnabled(not off)
                rawset(w, "dfGreyed", off and true or nil)
            end
            if rawget(w, "refreshContent") and w:IsShown() then w:refreshContent(db) end
        end
    end
    return b
end

-- ---- the page section, cut out and run ----------------------------------------
local src = options_file_source("UnitFrames/Pages.lua"):gsub("\r\n", "\n")
local s0 = src:find("function UFO.FrameStyleOptions()", 1, true)
local s1 = src:find("-- Resting / PvP / Elite & Rare", 1, true)
assert(s0 and s1, "the FRAME STYLE section in Pages.lua")

local refreshes, pushes, live = 0, {}, {}
local UFO = { gateReasons = setmetatable({}, { __mode = "k" }) }
function UFO.Explain(test, reason)
    local function gate(d) return test(d) and true or false end
    UFO.gateReasons[gate] = function(d) return gate(d) and reason(d) or nil end
    return gate
end
function UFO.AddPageHead() end
function UFO.RefreshTextStyleNote() end
function UFO.ApplyTemplateRequests() end
function UFO.PushLinks(u) pushes[#pushes + 1] = u end
function UFO.LiveSlider(u, key, kind) return function() live[#live + 1] = { u, key, kind } end end

local bands = {}
local function Tools()
    local function Open(label, key, col)
        local b = Band()
        b.title, b.key, b.col = label, key, col
        bands[key] = b
        return b
    end
    return Open, function() end
end

local chunk = assert((loadstring or load)(
    "local DF, GUI, UFO, L, format, concat, Tools, RefreshFrames, CreateFrame = ...\n" .. src:sub(s0, s1 - 1),
    "@Pages:FrameStyle"))
chunk(DF, GUI, UFO, DF.L, string.format, table.concat, Tools, function() refreshes = refreshes + 1 end,
      function() return Frame() end)

-- A fixed list: this file checks the card, not the shipped defaults.
local TWO_RINGS = {
    { thickness = 8, gap = 2, sections = { { bar = "HEALTH", coverage = "FULL", position = "TOP" } } },
    { thickness = 4, gap = 2, sections = { { bar = "POWER", coverage = "FULL", position = "TOP" } } },
}

local db = { frameStyle = "RING", portraitEnabled = true, portraitMode = "3D",
             rings = deepcopy(TWO_RINGS) }
local page = { child = Frame() }
function page:RefreshStates()
    for _, b in pairs(bands) do b:Sweep(db) end
end

-- The page's handle on the list: BuildRingsPage does not return one, so the list
-- builder is wrapped to catch it.
local list
local build = UFO.BuildRingList
UFO.BuildRingList = function(...)
    list = build(...)
    return list
end
UFO.BuildRingsPage(page, db, function() end, {}, "player")
page:RefreshStates()

local band = bands.uf_rings_list
local function Rows() return list.Rows() end
local function Index(w)
    for i, x in ipairs(Rows()) do if x == w then return i end end
    return nil
end
local function Click(btn) btn.opts.onClick(btn) end
local function CustClick(bar) bar.custBtn.scripts.OnClick(bar.custBtn) end
local function UpClick(bar) Click(bar.upBtn) end
local function DownClick(bar) Click(bar.downBtn) end

print("-- Rings page: the text template dropdowns")
do
    local function find(label)
        for _, e in ipairs(bands.uf_rings_style.groupChildren) do
            if e.widget.labelText == label then return e.widget end
        end
    end
    local bars, ring = find("Bars Text Template"), find("Ring Text Template")
    check(bars and ring, "one dropdown per style on the Style card")
    eq(ring.dropOpts.optionsFunc, UFO.TextTemplateOptions, "the list is re-read when the menu opens")
    eq(table.concat(UFO.TextTemplateOptions()._order, ","), "Default,A", "...from the Text Designer library")
    ring.set("A")
    eq(db.ringTextDesignerPreset, "A", "Ring writes the ring key")
    eq(db.textDesignerPreset, nil, "...not the Bars key")
    bars.set("Default")
    eq(db.textDesignerPreset, "Default", "Bars writes the Bars key")
    local asked
    local apply = UFO.ApplyTemplateRequests
    UFO.ApplyTemplateRequests = function(u, n) asked = n end
    local p, r = #pushes, refreshes
    ring.cb()
    eq(asked, "A", "a pick applies what the template asks for")
    check(#pushes == p + 1 and refreshes == r + 1, "...pushes the link and re-stamps the frames")
    UFO.ApplyTemplateRequests = apply
    db.ringTextDesignerPreset, db.textDesignerPreset = nil, nil
end

print("-- Rings page: the cards")
eq(bands.uf_rings_style.col, "both", "the Style card is full width")
eq(band.col, "both", "the Rings card too: a summary line needs the room")

print("-- Rings page: the summaries")
do
    local S = UFO.RingSummary
    eq(S({ sections = { { bar = "HEALTH", coverage = "FULL" } } }), "Health - Full ring", "one full ring")
    eq(S({ sections = { { bar = "HEALTH", coverage = "HALF", position = "TOP" },
                        { bar = "POWER", coverage = "HALF", position = "BOTTOM" } } }),
       "Health - Top half + Power - Bottom half", "two halves")
    eq(S({ sections = { { bar = "CLASSPOWER", coverage = "QUARTER", position = "TOPLEFT" } } }),
       "Class Power - Top Left quarter", "a corner quarter")
    eq(S({ sections = {} }), "No bars", "an empty ring")
    eq(S({}), "No bars", "...or one with no list")
    eq(S({ sections = { {} } }), "Health - Full ring", "missing keys read as their defaults")
    eq(list.Bars[1].text.textValue, "1  Health - Full ring", "bar 1's label: innermost first")
    eq(list.Bars[2].text.textValue, "2  Power - Full ring", "bar 2's label")
end

print("-- Rings page: the collapsed list")
do
    local rows = Rows()
    eq(#rows, 4, "a note, two bars, Add Ring")
    eq(rows[1].labelText, "The innermost ring is at the top.", "the note says which way up it is")
    check(rows[2] == list.Bars[1] and rows[3] == list.Bars[2], "the bars in ring order")
    eq(rows[4].button.styled.text, "Add Ring", "Add Ring last")
    check(rows[4].button.styled.primary and rows[4].button.styled.icon.texture:find("add.png", 1, true), "...primary, with the add icon")
    local b1, b2 = list.Bars[1], list.Bars[2]
    check(not b1.upBtn.shown and b1.downBtn.shown, "the innermost cannot move further in")
    check(b2.upBtn.shown and not b2.downBtn.shown, "the outermost cannot move further out")
    eq(b1.upBtn.opts.rotation, math.pi, "one arrow texture, turned for up")
    eq(b1.removeBtn.opts.tone, "danger", "a red X")
    check(b1.custBtn.styled.tinted, "Customise: the tinted button")
    eq(b1.custBtn.Text.textValue, "Customise", "...reading Customise")
    eq(list.Editor(), nil, "no editor until one is opened")
end

print("-- Rings page: one ring open at a time")
do
    local rings = db.rings
    CustClick(list.Bars[1])
    eq(list.OpenRing(), rings[1], "Customise opens ring 1")
    eq(list.Bars[1].custBtn.Text.textValue, "Done", "...its button reads Done")
    local ed = list.Editor()
    check(Index(ed.thickness) == 3 and Index(ed.gap) == 4, "Thickness and Gap straight under its bar")
    check(Index(list.Bars[2]) > Index(ed.soft or ed.sections[1].soft), "the next bar after its editor")
    eq(ed.thickness.kind, "slider", "full settings sliders")
    eq(ed.heading.labelText, "Bars in this ring", "the sections' heading")
    CustClick(list.Bars[2])
    eq(list.OpenRing(), rings[2], "Customise on another: it opens...")
    eq(list.Bars[1].custBtn.Text.textValue, "Customise", "...and the first shuts")
    check(Index(ed.thickness) > Index(list.Bars[2]), "the one editor moved under it")
    check(ed.thickness.refreshed > 0, "...its widgets repainted for this ring")
    eq(ed.thickness.get(), 4, "...and read this ring's values")
    CustClick(list.Bars[2])
    eq(list.OpenRing(), nil, "Done shuts it")
    check(not ed.thickness.shown, "the editor's rows hide")
    eq(Index(ed.thickness), nil, "...and leave the band")
    check(UFO.RingToggleOpen("a", "a") == nil and UFO.RingToggleOpen("a", "b") == "b", "RingToggleOpen")
end

print("-- Rings page: what the controls write")
do
    local rings = db.rings
    CustClick(list.Bars[1])
    local ed = list.Editor()
    local e = ed.sections[1]
    ed.thickness.set(12)
    eq(rings[1].thickness, 12, "Thickness: the ring's thickness")
    ed.gap.set(5)
    eq(rings[1].gap, 5, "Gap: the ring's gap")
    eq(ed.gap.lo .. ":" .. ed.gap.hi, "0:20", "...in its range")
    local p, r = #pushes, refreshes
    ed.thickness.cb()
    check(#pushes == p + 1 and pushes[#pushes] == "player" and refreshes == r + 1, "a change pushes the link and repaints")
    ed.thickness.light()
    eq(live[#live][2], "rings", "dragging repaints live on the rings' element")
    e.drop.set("POWER")
    e.drop.cb()
    eq(rings[1].sections[1].bar, "POWER", "Bar: the section's bar")
    eq(list.Bars[1].text.textValue, "1  Power - Full ring", "...and the summary follows")
    eq(e.bar.text.textValue, "1  Power - Full ring", "...on the section's bar too")
    e.rev.set(true)
    eq(rings[1].sections[1].reverse, true, "Reverse Fill: reverse")
    e.rev.set(false)
    eq(rawget(rings[1].sections[1], "reverse"), nil, "...off stores nothing")
    e.soft.set(0.3)
    eq(rings[1].sections[1].feather, 0.3, "Soft Edge: the key stays feather")
    eq(e.soft.labelText, "Soft Edge", "...under its new name")
    e.soft.set(0)
    eq(rawget(rings[1].sections[1], "feather"), nil, "...0 stores nothing")
end

print("-- Rings page: shape and position")
do
    local rings = db.rings
    local ed = list.Editor()
    local e = ed.sections[1]
    local sec = rings[1].sections[1]
    eq(Index(e.pos), nil, "Full: no Position")
    local tog = e.shape.toggle
    check(tog.opts.rounded, "the shape toggle is the rounded one")
    eq(tog.segments[1].value .. tog.segments[2].value .. tog.segments[3].value, "FULLHALFQUARTER", "Full, Half, Quarter")
    tog.opts.customSet("QUARTER")
    eq(sec.coverage, "QUARTER", "the key stays coverage")
    check(Index(e.pos) ~= nil, "Quarter: Position appears")
    check(e.pos.options.TOPLEFT ~= nil, "...with the corners")
    e.pos.set("TOPLEFT")
    e.pos.cb()
    eq(sec.position, "TOPLEFT", "a corner picked")
    eq(list.Bars[1].text.textValue, "1  Power - Top Left quarter", "the summary follows")
    tog.opts.customSet("HALF")
    eq(sec.position, "TOP", "Half: a corner falls back to Top")
    eq(e.pos.options.TOPLEFT, nil, "...and the corners leave the list")
    local n = e.pos.rebuilds
    e.pos.set("LEFT")
    e.pos.cb()
    eq(e.pos.rebuilds, n, "picking a Position does not rebuild its own menu")
    tog.opts.customSet("FULL")
    eq(Index(e.pos), nil, "Full: Position goes again")
    eq(sec.position, "LEFT", "...its choice kept")
    check(tog.opts.customGet() == "FULL", "the toggle reads the section")
end

print("-- Rings page: bars in a ring, and the overlap note")
do
    local rings = db.rings
    local ed = list.Editor()
    eq(Index(ed.overlap), nil, "no note without an overlap")
    eq(ed.addBar.button.styled.text, "Add Bar", "Add Bar")
    ed.addBar.button.scripts.OnClick()
    eq(#rings[1].sections, 2, "adds a section")
    check(ed.sections[2] ~= nil and Index(ed.sections[2].bar) ~= nil, "...with its own rows")
    check(Index(ed.overlap) ~= nil, "a full ring plus a half: the note shows")
    check(Index(ed.overlap) < Index(ed.sections[1].bar), "...at the top of the bars")
    eq(ed.overlap.noteOpts.tone, "warning", "...as a warning")
    check(list.Bars[1].text.textValue:find("(overlap)", 1, true) ~= nil, "the collapsed bar hints at it too")
    eq(list.Bars[1].dfState.plain, "Power - Full ring + Health - Left half", "...its tooltip reads the plain line")
    ed.sections[1].shape.toggle.opts.customSet("HALF")
    ed.sections[1].pos.set("RIGHT")
    ed.sections[1].pos.cb()
    eq(Index(ed.overlap), nil, "halves apart: the note goes")
    check(list.Bars[1].text.textValue:find("(overlap)", 1, true) == nil, "...and the hint")
    ed.addBar.button.scripts.OnClick()
    ed.addBar.button.scripts.OnClick()
    eq(#rings[1].sections, 4, "up to four")
    page:RefreshStates()
    eq(ed.addBar.button.enabledState, false, "Add Bar greys at the limit")
    eq(ed.addBar.disableReason(db), "A ring holds at most 4 bars.", "...and says why")
    Click(ed.sections[4].bar.removeBtn)
    Click(ed.sections[3].bar.removeBtn)
    eq(#rings[1].sections, 2, "the X removes a section")
    page:RefreshStates()
    eq(ed.addBar.button.enabledState, true, "Add Bar comes back")
    Click(ed.sections[2].bar.removeBtn)
    Click(ed.sections[1].bar.removeBtn)
    eq(#rings[1].sections, 0, "the last one too (as before)")
    eq(list.Bars[1].text.textValue, "1  No bars", "the summary says so")
    ed.addBar.button.scripts.OnClick()
end

print("-- Rings page: moving, adding, removing rings")
do
    local rings = db.rings
    local one, two = rings[1], rings[2]
    DownClick(list.Bars[1])
    check(rings[1] == two and rings[2] == one, "down moves it out")
    eq(list.OpenRing(), one, "the open ring stays open through the move")
    check(Index(list.Editor().thickness) > Index(list.Bars[2]), "...its editor under its new bar")
    UpClick(list.Bars[2])
    check(rings[1] == one, "up moves it back in")
    list.Bars[2].custBtn.scripts.OnClick(list.Bars[2].custBtn)
    eq(list.OpenRing(), two, "open ring 2")
    Click(list.Bars[2].removeBtn)
    eq(#rings, 1, "the X removes a ring")
    eq(list.OpenRing(), nil, "removing the open ring shuts it")
    eq(list.Bars[1].removeBtn.enabledState, false, "the X greys at one ring")
    Click(list.Bars[1].removeBtn)
    eq(#rings, 1, "...and cannot remove it")
    local add = Rows()[#Rows()]
    for _ = 1, 3 do add.button.scripts.OnClick() end
    eq(#rings, 4, "Add Ring up to four")
    page:RefreshStates()
    eq(add.button.enabledState, false, "Add Ring greys at the limit")
    eq(add.disableReason(db), "At most 4 rings.", "...and says why")
    eq(list.Bars[1].removeBtn.enabledState, true, "the X is back with more than one")
    Click(list.Bars[4].removeBtn)
    eq(Index(list.Bars[4]), nil, "a removed ring's bar leaves the band")
    check(not list.Bars[4].shown, "...and hides")
end

print("-- Rings page: nothing is made per click")
do
    CustClick(list.Bars[1])
    local ed = list.Editor()
    if #db.rings[1].sections < 4 then
        for _ = #db.rings[1].sections + 1, 4 do ed.addBar.button.scripts.OnClick() end
    end
    local add = Rows()[#Rows()]
    if #db.rings < 4 then add.button.scripts.OnClick() end
    local before = made
    for _ = 1, 20 do
        CustClick(list.Bars[2])
        CustClick(list.Bars[1])
        DownClick(list.Bars[1])
        UpClick(list.Bars[2])
        Click(ed.sections[4].bar.removeBtn)
        ed.addBar.button.scripts.OnClick()
        Click(list.Bars[4].removeBtn)
        add.button.scripts.OnClick()
        list.Rebuild()
    end
    eq(made, before, "a hundred and eighty clicks: no new frame")
end

print("-- Rings page: every row greys unless Frame Style is Ring")
do
    db.frameStyle = "BARS"
    page:RefreshStates()
    local ed = list.Editor()
    local all = { ed.thickness, ed.gap, ed.sections[1].drop, ed.sections[1].shape, ed.sections[1].rev,
                  ed.sections[1].soft, ed.addBar, Rows()[#Rows()] }
    local greyed = true
    for _, w in ipairs(all) do
        if not rawget(w, "disableOn") or not w.disableOn(db) then greyed = false end
    end
    check(greyed, "the controls answer grey")
    eq(ed.thickness.enabledState, false, "the sweep greys a slider")
    eq(ed.sections[1].shape.toggle.enabledState, false, "...and the shape toggle through its row")
    eq(ed.addBar.button.enabledState, false, "...and Add Bar")
    local b = list.Bars[1]
    eq(b.custBtn.enabledState, false, "a ring bar: Customise greys")
    eq(b.removeBtn.enabledState, false, "...the X")
    eq(b.downBtn.glyphOn, false, "...the arrows")
    eq(b.text.alpha, 0.4, "...the label dims")
    eq(UFO.gateReasons[ed.thickness.disableOn](db), "Set Frame Style to Ring to change this.", "the reason")
    eq(ed.addBar.disableReason(db), "Set Frame Style to Ring to change this.", "...on the limit-gated rows too")
    db.frameStyle = "RING"
    page:RefreshStates()
    eq(b.custBtn.enabledState, true, "back to Ring: live again")
    eq(b.text.alpha, 1, "...the label too")
end

print("-- Rings page: a list swapped behind the page")
do
    local n = #deferred
    db.rings = deepcopy(TWO_RINGS)
    page:RefreshStates()
    eq(#deferred, n + 1, "the state pass notices and defers a rebuild")
    deferred[#deferred]()
    eq(list.OpenRing(), nil, "the old open ring is gone")
    eq(#Rows(), 4, "the rows follow the new list")
    eq(list.Bars[1].text.textValue, "1  Health - Full ring", "...and the summaries")
end

print("-- Rings page: the saved shape, and no RowList left")
do
    local ok = true
    local allowed = { thickness = true, gap = true, sections = true }
    local secAllowed = { bar = true, coverage = true, position = true, reverse = true, feather = true, trackColor = true }
    for _, ring in ipairs(db.rings) do
        for k in pairs(ring) do if not allowed[k] then ok = false end end
        for _, s in ipairs(ring.sections) do
            for k in pairs(s) do if not secAllowed[k] then ok = false end end
        end
    end
    check(ok, "only the keys the runtime reads are stored")
    local section = src:sub(s0, s1 - 1)
    check(not section:find("CreateRowList", 1, true) and not section:find("AddButtons", 1, true), "the card no longer uses RowList")
    local kit = ui_file_source("RowList.lua")
    check(not kit:find("AddButtons", 1, true), "RowList is the popup widget again")
end

for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
