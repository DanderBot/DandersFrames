local NS = ...

-- ============================================================
-- SEGMENT TOGGLE TOOLTIPS / ACCENTS, AND A PAGE'S OWN MINIMUM WIDTH
--   DandersFrames_Options/GUI/SettingsWidgets.lua  GUI:CreateSegmentToggle
--   DandersFrames_Options/GUI/Panel.lua            GUI:PageMinWidth, PageChromeWidth,
--                                                  ApplyPageWidthBounds
-- The functions are cut out of their files and run against stubs: neither file
-- loads headless as a whole.
-- ============================================================

local function cut(src, marker, closer)
    src = src:gsub("\r\n", "\n")
    local s = src:find(marker, 1, true)
    assert(s, "marker not found: " .. marker)
    local e = src:find("\n" .. closer .. "\n", s, true)
    assert(e, "closer not found after: " .. marker)
    return src:sub(s, e + #closer)
end

local prevCreateFrame = CreateFrame

-- ---- the segment toggle -------------------------------------------------------
print("-- Segment toggle: per-segment tooltips, accents and a label size")
do
    local styled, fonts, shown, created, surfaces = {}, {}, {}, {}, {}
    local GUI = { Colors = { background = { r = 0.08, g = 0.08, b = 0.08, a = 0.95 } } }
    function GUI:CreateRoundedSurface(frame, o) surfaces[#surfaces + 1] = { frame = frame, opts = o }; return {} end
    function GUI:StyleButton(btn, opts)
        styled[#styled + 1] = opts
        btn.Text = FakeUIFrame()
        btn.SetActive = function(self, on) self._active = on end
    end
    function GUI:SetSettingsFont(fs, size) fonts[#fonts + 1] = size end
    function GUI:ShowTooltip(owner, spec) shown[#shown + 1] = spec end
    function GUI:HideTooltip() end
    CreateFrame = function()
        local f = FakeUIFrame()
        local hooks = {}
        f.HookScript = function(self, name, fn) hooks[name] = fn end
        f.FireHook = function(self, name) if hooks[name] then hooks[name](self) end end
        created[#created + 1] = f
        return f
    end
    local C = { r = 1, g = 1, b = 1 }
    local src = options_file_source("GUI/SettingsWidgets.lua")
    local chunk = "local GUI, CreateFrame, CreateElementBackdrop, C_TEXT, C_TEXT_DIM, C_BORDER = ...\n"
        .. cut(src, "function GUI:CreateSegmentToggle(parent, segments, dbTable, dbKey, callback, opts)", "end")
    local BORDER = { r = 0.25, g = 0.25, b = 0.25 }
    assert(loadstring(chunk))(GUI, CreateFrame, function() end, C, C, BORDER)

    local value = "same"
    local named = "Player"
    local parent = FakeUIFrame()
    parent.ThemeListeners = {}
    local NEUTRAL = { r = 0.5, g = 0.5, b = 0.5 }
    local seg = GUI:CreateSegmentToggle(parent, {
        { value = "same", label = "Same", tooltip = { title = "Same: Health", lines = { "Shared." } } },
        { value = "mirror", label = "Mirrored", tooltip = function() return { title = "Mirrored", lines = { named } } end },
        { value = "own", label = "Separate", tooltip = "Separate", accent = NEUTRAL },
    }, nil, nil, nil, { segmentWidth = 58, height = 22, fontSize = 10, tooltipLines = { "shared line" },
        customGet = function() return value end, customSet = function(v) value = v end })
    eq(seg:GetWidth(), 58 * 3 + 2, "three segments, each segmentWidth wide, in a 1px lip")
    eq(fonts[1], 10, "opts.fontSize sizes the labels")
    eq(styled[3].accent, NEUTRAL, "a segment's own accent reaches StyleButton")
    eq(styled[1].accent, nil, "...and the others keep the theme's")

    local b1, b2, b3 = created[2], created[3], created[4]
    b1:FireHook("OnEnter")
    eq(shown[1] and shown[1].title, "Same: Health", "a table tooltip is shown as given")
    eq(shown[1] and shown[1].lines[1], "Shared.", "...lines and all")
    b2:FireHook("OnEnter")
    eq(shown[2] and shown[2].lines[1], "Player", "a function tooltip is asked at hover time")
    named = "Focus"
    b2:FireHook("OnEnter")
    eq(shown[3] and shown[3].lines[1], "Focus", "...so it names what it acts on now")
    b3:FireHook("OnEnter")
    eq(shown[4] and shown[4].title, "Separate", "a string tooltip is the title, as before")
    eq(shown[4] and shown[4].lines[1], "shared line", "...with the shared opts.tooltipLines")
    eq(b1._active, true, "the stored value's segment is lit")
    eq(b3._active, false, "...and only it")

    -- An older caller: a string tooltip and no font size.
    fonts = {}
    GUI:CreateSegmentToggle(parent, { { value = 1, label = "s", tooltip = "Seconds" } }, { k = 1 }, "k")
    eq(fonts[1], 9, "no opts.fontSize: the terse 9 it always used")
    eq(#surfaces, 0, "no opts.rounded: no rounded track (the square boxes, unchanged)")
    eq(styled[#styled].segment, nil, "...square buttons, not pills")
    eq(styled[#styled].fitText, nil, "...which still fit their text")

    -- The rounded track.
    styled, created = {}, {}
    local r = GUI:CreateSegmentToggle(parent, {
        { value = "same", label = "Same" }, { value = "mirror", label = "Mirrored" }, { value = "own", label = "Separate" },
    }, nil, nil, nil, { segmentWidth = 60, height = 22, rounded = true,
        customGet = function() return "own" end, customSet = function() end })
    eq(#surfaces, 1, "opts.rounded: one rounded surface...")
    eq(surfaces[1].frame, r, "...on the track itself")
    eq(surfaces[1].opts.radius, 6, "...radius 6")
    eq(surfaces[1].opts.borderWidth, 1, "...a 1px ring")
    eq(surfaces[1].opts.fill[1], 0.08, "...filled with the darker ground (GUI.Colors.background)")
    eq(surfaces[1].opts.fill[4], 1, "...opaque")
    eq(surfaces[1].opts.border[1], BORDER.r, "...ringed in the border colour")
    eq(r:GetWidth(), 3 * 60 + 2 * 2 + 2 * 2, "three pills, 2px apart, in a 2px lip")
    eq(r:GetHeight(), 22 + 4, "...and the lip top and bottom")
    eq(styled[1].segment, true, "each choice is a segment pill")
    eq(styled[1].rounded, 4, "...rounded, radius 4")
    eq(styled[1].fitText, false, "...that keeps the width it was given")
    local _, _, _, x2 = created[3]:GetPoint(1)
    eq(x2, 2 + 60 + 2, "the second pill sits one pill and one gap in")
    eq(created[4]._active, true, "the stored value's pill is the selected one")
end
CreateFrame = prevCreateFrame

-- ---- a page's own minimum width ----------------------------------------------
print("-- Panel: a page's own minimum window width")
do
    local GUI = {}
    local DF = { GUI = GUI }
    local SettingsBox = { colMargin = 5 }
    local src = options_file_source("GUI/Panel.lua")
    local chunk = "local GUI, DF, SettingsBox, pcall, type = ...\n"
        .. cut(src, "function GUI.PageUsableWidth(childWidth)", "end") .. "\n"
        .. cut(src, "GUI.PageMinWidths = GUI.PageMinWidths or {}", "end") .. "\n"
        .. cut(src, "function GUI.PageChromeWidth()", "end")
    assert(loadstring(chunk))(GUI, DF, SettingsBox, pcall, type)
    function GUI.PageChildWidth(cw) return cw - 8 - 14 end
    eq(GUI:PageMinWidth("anything"), nil, "no entry: no minimum of its own")
    GUI.PageMinWidths.fixed = 640
    eq(GUI:PageMinWidth("fixed"), 640, "a number")
    GUI.PageMinWidths.measured = function() return 701 end
    eq(GUI:PageMinWidth("measured"), 701, "a function, asked each time")
    GUI.PageMinWidths.broken = function() error("boom") end
    eq(GUI:PageMinWidth("broken"), nil, "a function that throws: no minimum, no error")
    GUI.PageMinWidths.junk = "wide"
    eq(GUI:PageMinWidth("junk"), nil, "not a number: ignored")

    eq(GUI.PageChromeWidth(), nil, "no window yet: no chrome width")
    DF.GUIFrame = FakeUIFrame(700, 600)
    GUI.contentFrame = FakeUIFrame(451, 500)
    -- 451 content -> 429 child -> 419 usable; 700 - 419 = 281.
    eq(GUI.PageChromeWidth(), 281, "chrome = window width less the page's usable width")

    local panel = src:gsub("\r\n", "\n")
    local a = panel:find("local own = GUI:PageMinWidth(name)", 1, true)
    local b = panel:find("frame:SetResizeBounds(wanted, minHeight, maxWidth, maxHeight)", a or 1, true)
    check(a and b and a < b, "ApplyPageWidthBounds raises the floor to the page's own minimum before applying it")
    check(panel:find("GUI.ApplyPageWidthBounds = ApplyPageWidthBounds", 1, true), "...and is published")
end
