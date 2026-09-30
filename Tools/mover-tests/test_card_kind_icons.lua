local NS = ...

-- ============================================================
-- A SETTINGS CARD'S KIND ICON
-- ------------------------------------------------------------
-- GUI:CreateCollapsibleSection with opts.card takes opts.kind and draws that
-- kind's glyph between the chevron and the tick/title. The kind -> texture map
-- is GUI.SectionCard.kinds; the icon's colour is one switch,
-- GUI.SectionCard.iconAccent (false = dim, true = the mode's accent; default true).
--
-- The factory is CUT out of SettingsWidgets.lua and RUN against stub frames,
-- the way test_designer_cards.lua runs CreateCardChrome. The page-side tagging
-- (GUI.SectionKindByKey) and the files on disk are checked by
-- test_card_kind_icons.py.
-- ============================================================

local SW   = options_file_source("GUI/SettingsWidgets.lua"):gsub("\r\n", "\n")
local CTRL = options_file_source("GUI/Controls.lua"):gsub("\r\n", "\n")

local function cut(src, startPlain, stopPlain)
    local s = src:find(startPlain, 1, true)
    if not s then return nil end
    local e = src:find(stopPlain, s, true)
    if not e then return nil end
    return src:sub(s, e + #stopPlain - 1)
end

print("-- Card kind icons: chevron -> icon -> tick -> title, one colour switch")
local cardTableSrc = cut(SW, "GUI.SectionCard = {", "\n}\n")
local kindsSrc = cut(SW, "do\n    local ICONS = ", "\nend\n")
local fnSrc = cut(SW, "function GUI:CreateCollapsibleSection(parent, text, defaultExpanded, width, opts)", "\nend\n")
check(cardTableSrc ~= nil, "kind: GUI.SectionCard can be cut out of SettingsWidgets.lua")
check(kindsSrc ~= nil, "kind: ...and the kind -> texture map beside it")
check(fnSrc ~= nil, "kind: ...and GUI:CreateCollapsibleSection")

-- The map is optional to the RUN, so the header checks below still execute
-- (and fail) against a factory that has no kind icon at all.
if cardTableSrc and fnSrc then
    local C_PANEL    = { r = 0.12, g = 0.12, b = 0.12 }
    local C_BORDER   = { r = 0.30, g = 0.30, b = 0.30 }
    local C_HOVER    = { r = 0.20, g = 0.20, b = 0.20 }
    local C_TEXT     = { r = 0.90, g = 0.90, b = 0.90 }
    local C_TEXT_DIM = { r = 0.60, g = 0.60, b = 0.60 }
    local ACCENT     = { r = 0.10, g = 0.60, b = 0.90 }

    -- ⚠ FakeUIFrame answers EVERY unset key with a no-op function, so a plain
    -- `section.kindIcon` / `section.previewDimmed` would read truthy on a card
    -- that never set it. Here only a Capitalised key (a widget method) falls
    -- back to the no-op; a field reads nil, the way it does in game.
    local METHODS_ONLY = { __index = function(_, k)
        if type(k) == "string" and k:match("^%u") then return function() end end
        return nil
    end }
    local function MakeFrame(w, h)
        local f = setmetatable(FakeUIFrame(w, h), METHODS_ONLY)
        f.ThemeListeners = {}
        f.CreateFontString = function(_, _, _, template)
            local fs = setmetatable(FakeUIFrame(), METHODS_ONLY)
            fs._template = template
            fs.SetTextColor = function(self, r, g, b) self._tc = { r = r, g = g, b = b } end
            return fs
        end
        return f
    end
    local function RoundedStub()
        local s = { shown = true }
        function s:Hide() self.shown = false end
        function s:Show() self.shown = true end
        function s:SetFillColor() end
        function s:SetBorderColor() end
        function s:SetCorners() end
        return s
    end
    local collapsed = {}
    local GUI = {
        RoundStripSublevel = -3,
        GetSurfaceStyle = function() return { borderWidth = 1 } end,
        CreateRoundedSurface = function() return RoundedStub() end,
        CreateElementBackdrop = function() end,
        GetCollapsedGroups = function() return collapsed end,
        CreateCheckbox = function(_, parent)
            local cb = MakeFrame(18, 18)
            cb.checkButton = MakeFrame(18, 18)
            cb.Refresh = function() end
            return cb
        end,
    }
    local chunk, err = loadstring(
        "local GUI, DF, L, C_PANEL, C_BORDER, C_HOVER, C_TEXT, C_TEXT_DIM, GetThemeColor, CreateFrame = ...\n"
        .. cardTableSrc .. "\n" .. (kindsSrc or "") .. "\n" .. fnSrc)
    check(chunk ~= nil, "kind: the cut parses (" .. tostring(err) .. ")")
    if chunk then
        chunk(GUI, {}, setmetatable({}, { __index = function(_, k) return k end }),
              C_PANEL, C_BORDER, C_HOVER, C_TEXT, C_TEXT_DIM,
              function() return ACCENT end,
              function(_, _, parent) return MakeFrame() end)
        local CARD = GUI.SectionCard
        local KINDS = CARD.kinds or {}
        -- The spec numbers, so a factory missing them is measured against what
        -- it should be rather than erroring on nil arithmetic.
        local ICON, GLYPH, IGAP = CARD.icon or 16, CARD.iconGlyph or 14, CARD.iconGap or 8

        -- ---- metrics, named, in the card table ----
        eq(CARD.icon, 16, "metrics: the icon's slot is 16")
        eq(CARD.iconGlyph, 14, "metrics: ...the glyph inside it 14")
        eq(CARD.iconGap, 8, "metrics: ...and 8 to the tick/title")
        eq(CARD.iconAccent, true, "switch: the icon colour defaults to the ACCENT")
        check(type(CARD.kinds) == "table" and CARD.kinds.layout ~= nil,
              "map: GUI.SectionCard.kinds is the one kind -> texture table")

        local function leftX(region)
            local p = region and region._points[1]
            if not (p and p[1] == "LEFT") then return nil end
            -- SetPoint("LEFT", x, y) and SetPoint("LEFT", rel, "LEFT", x, y)
            if type(p[2]) == "number" then return p[2] end
            return p[4]
        end
        local function build(opts)
            local page = MakeFrame(500, 800)
            local base = { card = true, collapseKey = "t_" .. tostring(opts and opts.kind) }
            for k, v in pairs(opts or {}) do base[k] = v end
            return GUI:CreateCollapsibleSection(page, "Title", true, 500, base), page
        end

        -- ---- a kinded card ----
        local s = build({ kind = "layout" })
        check(s.kindIcon ~= nil, "kinded: the header builds the icon")
        eq(s.kind, "layout", "kinded: ...and remembers its kind")
        eq(s.kindIcon and s.kindIcon:GetTexture(), KINDS.layout, "kinded: ...with the mapped texture")
        eq(s.kindIcon and s.kindIcon:GetWidth(), GLYPH, "kinded: ...at the glyph size")
        local chevX = leftX(s.arrow)
        local iconX = leftX(s.kindIcon)
        local titleX = leftX(s.title)
        eq(chevX, CARD.edge, "order: the chevron keeps its edge inset")
        eq(iconX, CARD.edge + CARD.chevron + CARD.titleGap + (ICON - GLYPH) / 2,
           "order: the icon is one chevron-gap after the chevron, centred in its slot")
        eq(titleX, CARD.edge + CARD.chevron + CARD.titleGap + ICON + IGAP,
           "order: the title follows the icon slot and its gap")
        check(chevX and iconX and titleX and chevX < iconX and iconX < titleX,
              "order: chevron -> icon -> title")

        -- ---- colours ----
        CARD.iconAccent = false
        s.title.UpdateTheme()
        local v = s.kindIcon and s.kindIcon._vertex
        check(v and v.r == C_TEXT_DIM.r and v.b == C_TEXT_DIM.b,
              "colour: iconAccent=false tints the icon dim")
        s:SetPreviewDimmed(true)
        v = s.kindIcon and s.kindIcon._vertex
        check(v and v.r == 0.5 and v.g == 0.5 and v.b == 0.5,
              "colour: a greyed card greys the icon with the title and chevron")
        s:SetPreviewDimmed(false)

        CARD.iconAccent = true
        s.title.UpdateTheme()
        v = s.kindIcon and s.kindIcon._vertex
        check(v and v.r == ACCENT.r and v.g == ACCENT.g and v.b == ACCENT.b,
              "colour: iconAccent=true tints the icon the accent")
        -- A party/raid switch: the accent changes and the page's theme pass runs
        -- the section's listener.
        ACCENT.r, ACCENT.g, ACCENT.b = 0.95, 0.55, 0.10
        s.title.UpdateTheme()
        v = s.kindIcon and s.kindIcon._vertex
        check(v and v.r == 0.95 and v.g == 0.55 and v.b == 0.10,
              "colour: ...and re-tints on a theme repaint, like the chevron")
        local av = s.arrow._vertex
        check(av and av.r == 0.95, "colour: ...(the chevron took the same accent)")
        s:SetPreviewDimmed(true)
        v = s.kindIcon and s.kindIcon._vertex
        check(v and v.r == 0.5 and v.b == 0.5, "colour: greyed wins over the accent too")
        s:SetPreviewDimmed(false)
        -- The fold re-tints (it swaps the chevron's art), and must keep the icon's.
        s:SetExpanded(false)
        v = s.kindIcon and s.kindIcon._vertex
        check(v and v.r == 0.95, "colour: a fold keeps the icon's tint")
        CARD.iconAccent = false
        s.title.UpdateTheme()
        v = s.kindIcon and s.kindIcon._vertex
        check(v and v.r == C_TEXT_DIM.r, "colour: flipping the switch back returns it to dim")

        -- ---- the theme listener is the title's (what a mode switch walks) ----
        local _, page = build({ kind = "border" })
        local found = false
        for _, l in ipairs(page.ThemeListeners or {}) do
            if l.UpdateTheme then found = true end
        end
        check(found, "listener: the card registers a theme listener on its page")

        -- ---- an unkinded card keeps the slot, empty ----
        local u = build({})
        check(u.kindIcon == nil, "unkinded: no icon is built")
        eq(leftX(u.title), CARD.edge + CARD.chevron + CARD.titleGap + ICON + IGAP,
           "unkinded: ...but the slot is kept, so titles line up down the page")
        local bogus = build({ kind = "not_a_kind" })
        check(bogus.kindIcon == nil, "unknown kind: no icon, no error")

        -- ---- a ticked card: chevron -> icon -> tick -> title ----
        local t = build({ kind = "border",
                          toggle = { db = {}, key = "k", label = "Enable" } })
        local tickX = leftX(t.headerToggle)
        local tIconX = leftX(t.kindIcon)
        local tTitleX = leftX(t.title)
        eq(tickX, CARD.edge + CARD.chevron + CARD.titleGap + ICON + IGAP,
           "ticked: the tick sits after the icon slot")
        check(tIconX and tickX and tTitleX and tIconX < tickX and tickX < tTitleX,
              "ticked: chevron -> icon -> tick -> title")

        -- ---- a plain (non-card) section never grows a slot ----
        local plain = GUI:CreateCollapsibleSection(MakeFrame(500, 800), "Plain", true, 500, { kind = "layout" })
        check(plain.kindIcon == nil, "plain: a non-card section ignores kind")
        eq(leftX(plain.title), 26, "plain: ...and its title stays at 26")
    end
end

-- ---- the page tools pass the kind through ----
local open = (CTRL:match("\n    local function OpenSection%(Add, .-\n    end\n") or ""):gsub("%s+", " ")
check(open:find("kind = (extra and extra.kind) or GUI.SectionKindByKey[key] }", 1, true) ~= nil,
      "tools: OpenSection hands the card its kind, from the collapseKey table (never the title)")
