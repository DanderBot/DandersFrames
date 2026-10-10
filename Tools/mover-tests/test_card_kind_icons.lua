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
        -- The modified mark is its own factory (test_modified_dot.lua).
        AttachCardModifiedMark = function() end,
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
    -- The atlas-or-path setter, recording what it was handed and the swatch's
    -- desaturation (the fake texture answers SetDesaturated with a no-op).
    local DFt = { SetIconTextureOrAtlas = function(_, tex, t)
        tex:SetTexture(t)
        rawset(tex, "SetDesaturated", function(self, v) self._desat = v and true or false end)
    end }
    if chunk then
        chunk(GUI, DFt, setmetatable({}, { __index = function(_, k) return k end }),
              C_PANEL, C_BORDER, C_HOVER, C_TEXT, C_TEXT_DIM,
              function() return ACCENT end,
              function(_, _, parent) return MakeFrame() end)
        local CARD = GUI.SectionCard
        local KINDS = CARD.kinds or {}
        -- The spec numbers, so a factory missing them is measured against what
        -- it should be rather than erroring on nil arithmetic.
        local ICON, GLYPH, IGAP = CARD.icon or 16, CARD.iconGlyph or 14, CARD.iconGap or 8
        local LEAD = CARD.titleLead or 12

        -- ---- metrics, named, in the card table ----
        eq(CARD.icon, 16, "metrics: the icon's slot is 16")
        eq(CARD.iconGlyph, 14, "metrics: ...the glyph inside it 14")
        eq(CARD.iconGap, 8, "metrics: ...and 8 to the tick")
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
        -- The tick's slot (an 18px box after iconGap) is reserved on every card too.
        local TITLE_AT = CARD.edge + CARD.chevron + CARD.titleGap + ICON + CARD.iconGap + 18 + LEAD
        eq(titleX, TITLE_AT,
           "order: the title follows the icon and tick slots by the title lead, room for the dot")
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
        eq(leftX(u.title), TITLE_AT,
           "unkinded: ...but the slots are kept, so titles line up down the page")
        -- ...and a ticked card's title sits exactly where an unticked one's does.
        local t = build({ toggle = { key = "k", db = {}, label = "On" } })
        eq(leftX(t.title), TITLE_AT, "ticked: the title lands where an unticked card's does")
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
        eq(CARD.titleLead, 12, "metrics: a title lead of 12, room for the modified dot")
        eq(tTitleX, (tickX or 0) + 18 + LEAD,
           "ticked: the title sits the same lead after the 18px box")

        -- ---- a plain (non-card) section never grows a slot ----
        local plain = GUI:CreateCollapsibleSection(MakeFrame(500, 800), "Plain", true, 500, { kind = "layout" })
        check(plain.kindIcon == nil, "plain: a non-card section ignores kind")
        eq(leftX(plain.title), 26, "plain: ...and its title stays at 26")

        -- ---- a card's PREVIEW takes the icon slot (the Icons page) ----
        local pv = build({ kind = "layout" })
        pv:SetPreviewIcons({ { texture = "off", desaturate = true }, { text = "MT" }, { texture = "live" } })
        local slot = rawget(pv, "previewSlot")
        check(slot ~= nil, "preview: a card draws its preview in the header's icon slot")
        eq(slot and slot:GetTexture(), "live", "preview: ...ONE swatch, the first live entry")
        eq(slot and slot:GetWidth(), ICON, "preview: ...at the slot's size")
        local sp = slot and slot._points[1]
        eq(sp and sp[4], CARD.edge + CARD.chevron + CARD.titleGap + ICON / 2,
           "preview: ...centred in the slot, so the title does not move")
        eq(pv.kindIcon and pv.kindIcon._shown, false, "preview: ...in place of the kind icon")
        eq(slot and slot._desat, false, "preview: a live entry is in colour")
        pv:SetPreviewIcons({ { texture = "a", desaturate = true }, { texture = "b", desaturate = true } })
        eq(slot and slot:GetTexture(), "a", "preview: nothing live -- the first entry, ...")
        eq(slot and slot._desat, true, "preview: ...greyed")
        pv:SetPreviewIcons({ { text = "AFK" } })
        eq(slot and slot._shown, false, "preview: text only -- no swatch")
        eq(pv.kindIcon and pv.kindIcon._shown, true, "preview: ...and the kind icon is back")
        eq(#pv.previewIcons, 0, "preview: a card never builds the right-end swatches")

        -- ---- a LAYERED entry: the Important Debuffs marker, disc then glyph ----
        local lay = build({})
        local function marker(off)
            return { { size = 14, desaturate = off, layers = {
                { texture = "disc", color = { r = 1, g = 0.5, b = 0 } },
                { texture = "mark", color = { r = 1, g = 1, b = 1 } } } } }
        end
        lay:SetPreviewIcons(marker(false))
        local ly = rawget(lay, "previewLayers") or {}
        eq(#ly, 2, "layered: one texture per layer, in the one slot")
        eq(ly[1] and ly[1]:GetTexture(), "disc", "layered: ...the disc first")
        eq(ly[2] and ly[2]:GetTexture(), "mark", "layered: ...the glyph over it")
        eq(ly[1] and ly[1]:GetWidth(), 14, "layered: ...at the entry's own size")
        local v1 = ly[1] and ly[1]._vertex
        check(v1 and v1.r == 1 and v1.g == 0.5 and v1.b == 0, "layered: each layer takes its own tint")
        lay:SetPreviewIcons(marker(true))
        v1 = ly[1] and ly[1]._vertex
        local v2 = ly[2] and ly[2]._vertex
        check(v1 and v2 and v1.r == v1.g and v1.g == v1.b and v1.r < v2.r,
              "layered: greyed, each layer keeps its brightness in grey, so the glyph still reads on its disc")
        lay:SetPreviewIcons({ { texture = "single" } })
        eq(ly[2] and ly[2]._shown, false, "layered: a plain entry after it hides the extra layer")

        -- ---- the Debuff Bar's Important Debuffs card uses it ----
        local IND = options_file_source("GUI/Pages/Indicators.lua")
        check(IND:find("section:SetPreviewIcons({ { size = 14, layers = ImportantMarkerLayers(d),", 1, true) ~= nil,
              "layered: the Important Debuffs card previews its marker in the icon slot")
        check(IND:find("impSwatch:SetSwatch(ImportantMarkerLayers(d), ImportantMarkerOff(d))", 1, true) ~= nil,
              "layered: ...from the same layers and gate as classic's header swatch")

        -- ---- more icons than the slot: a hover lists them all ----
        local shownPopup
        GUI.ShowCardPreviewPopup = function(_, owner, title, entries) shownPopup = { owner = owner, title = title, entries = entries } end
        GUI.HideCardPreviewPopup = function() shownPopup = nil end
        local many = build({})
        many:SetPreviewIcons({ { texture = "t", desaturate = true }, { texture = "h" }, { text = "x" }, { texture = "d" } })
        local mhit = rawget(many, "previewHit")
        check(mhit ~= nil, "popup: a card with several icons gets a hover over its swatch")
        eq(mhit and mhit._shown, true, "popup: ...shown")
        eq(mhit and mhit._flags and mhit._flags.mouseClick, false, "popup: ...that takes motion, never clicks (the swatch still folds the card)")
        local onEnter = mhit and mhit:GetScript("OnEnter")
        if onEnter then onEnter(mhit) end
        eq(shownPopup and #shownPopup.entries, 3, "popup: the hover lists every icon entry")
        eq(shownPopup and shownPopup.entries[1].texture, "t", "popup: ...in order, an off one included")
        eq(shownPopup and shownPopup.title, "Title", "popup: ...under the card's title")
        local onLeave = mhit and mhit:GetScript("OnLeave")
        if onLeave then onLeave(mhit) end
        eq(shownPopup, nil, "popup: leaving the swatch hides it")
        many:SetPreviewIcons({ { texture = "only" } })
        eq(mhit and mhit._shown, false, "popup: one icon -- no hover")
        local one = build({})
        one:SetPreviewIcons({ { texture = "only" } })
        eq(rawget(one, "previewHit"), nil, "popup: a one-icon card never builds it")
    end
end

-- ---- the page tools pass the kind through ----
local open = (CTRL:match("\n    local function OpenSection%(Add, .-\n    end\n") or ""):gsub("%s+", " ")
check(open:find("kind = (extra and extra.kind) or GUI.SectionKindByKey[key] }", 1, true) ~= nil,
      "tools: OpenSection hands the card its kind, from the collapseKey table (never the title)")

-- ---- the popup itself: every icon in a row under the card's title ----
local popSrc = cut(SW, "local previewPopup\nfunction GUI:ShowCardPreviewPopup", "\nfunction GUI:HideCardPreviewPopup()\n    if previewPopup then previewPopup:Hide() end\nend\n")
check(popSrc ~= nil, "popup: GUI:ShowCardPreviewPopup can be cut out of SettingsWidgets.lua")
if popSrc then
    local made
    local G2 = { CreatePanelBackdrop = function() end, RegisterScaledSurface = function(_, f) f._scaled = true end }
    local DF2 = { SetIconTextureOrAtlas = function(_, tex, t) tex:SetTexture(t)
        rawset(tex, "SetDesaturated", function(self, v) self._desat = v and true or false end) end }
    local chunk = loadstring("local GUI, DF, C_TEXT, CreateFrame, UIParent = ...\n" .. popSrc)
    check(chunk ~= nil, "popup: the cut parses")
    if chunk then
        chunk(G2, DF2, { r = 1, g = 1, b = 1 },
              function(_, _, parent) made = FakeUIFrame(); made._parent = parent; return made end, "UIParent")
        local owner = FakeUIFrame()
        G2:ShowCardPreviewPopup(owner, "Ping Icon", { { texture = "a" }, { texture = "b", desaturate = true }, { texture = "c" } })
        check(made ~= nil and made._parent == "UIParent", "popup: one frame, off UIParent so the page cannot clip it")
        eq(made and made._scaled, true, "popup: ...registered for the GUI scale")
        eq(made and made.title:GetText(), "Ping Icon", "popup: titled with the card's name")
        local sw = made and made.swatches or {}
        eq(#sw, 3, "popup: a swatch per icon")
        eq(sw[2] and sw[2]:GetTexture(), "b", "popup: ...in order")
        eq(sw[2] and sw[2]._desat, true, "popup: ...an off one greyed")
        eq(sw[1] and sw[1]._desat, false, "popup: ...a live one in colour")
        eq(made and made._shown, true, "popup: shown")
        G2:ShowCardPreviewPopup(owner, "Raid Role", { { texture = "x" } })
        eq(sw[2] and sw[2]._shown, false, "popup: a shorter list hides the spare swatches")
        G2:HideCardPreviewPopup()
        eq(made and made._shown, false, "popup: hidden on request")
    end
end

-- ---- an atlas icon after a sheet slice: the crop is cleared first ----
-- The popup's swatches are reused across cards; a raid marker leaves a
-- SetTexCoord slice behind, and SetAtlas keeps it.
do
    local CORE = df_file_source("Frames/Core.lua"):gsub("\r\n", "\n")
    local fn = cut(CORE, "function DF:SetIconTextureOrAtlas(region, value, l, r, t, b)", "\nend\n")
    check(fn ~= nil, "atlas: DF:SetIconTextureOrAtlas can be cut out of Frames/Core.lua")
    if fn then
        local DF3 = {}
        local chunk = loadstring("local DF, C_Texture = ...\n" .. fn)
        chunk(DF3, { GetAtlasInfo = function(v) return v == "an-atlas" and {} or nil end })
        local calls = {}
        local region = {
            SetTexCoord = function(_, ...) calls[#calls + 1] = { "coord", ... } end,
            SetAtlas = function(_, v) calls[#calls + 1] = { "atlas", v } end,
            SetTexture = function(_, v) calls[#calls + 1] = { "texture", v } end,
        }
        DF3:SetIconTextureOrAtlas(region, "sheet", 0.25, 0.5, 0.25, 0.5)
        calls = {}
        DF3:SetIconTextureOrAtlas(region, "an-atlas")
        local c1, c2 = calls[1], calls[2]
        check(c1 and c1[1] == "coord" and c1[2] == 0 and c1[3] == 1 and c1[4] == 0 and c1[5] == 1,
              "atlas: the crop is reset to the whole texture...")
        check(c2 and c2[1] == "atlas" and c2[2] == "an-atlas", "atlas: ...before the atlas is set")
    end
end
