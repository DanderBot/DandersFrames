local NS = ...

-- ============================================================
-- THE DESIGNERS' CARDS WEAR THE SETTINGS CARD LOOK
-- ------------------------------------------------------------
-- Every settings page's sections became cards (GUI.SectionCard); the Aura and
-- Text Designers' own collapsible cards did not, and read as the old UI. They
-- now share GUI:CreateCardChrome (SettingsWidgets.lua), which hands a hand-built
-- card the section card's metrics, surface, hover, hairline and colours while
-- the card keeps its own click, fold store and header furniture.
--
-- 1. The chrome itself is RUN against stub frames: metrics, colours, the fold's
--    effect on rect / hairline / hover corners / summary, the dimmed grey.
-- 2. Every designer card is READ: it builds through the chrome, keeps its
--    furniture (icon, badge, warning, chip, eye, delete) and its fold keys.
-- ============================================================

local SW   = options_file_source("GUI/SettingsWidgets.lua"):gsub("\r\n", "\n")
local ADO  = options_file_source("AuraDesigner/UI/Options.lua"):gsub("\r\n", "\n")
local CARD = options_file_source("AuraDesigner/UI/Cards.lua"):gsub("\r\n", "\n")
local EDIT = options_file_source("AuraDesigner/UI/Editor.lua"):gsub("\r\n", "\n")
local TD   = options_file_source("TextDesigner/UI/Options.lua"):gsub("\r\n", "\n")

-- Cut `startPlain ... <stopPlain>` out of a source (stopPlain included).
local function cut(src, startPlain, stopPlain)
    local s = src:find(startPlain, 1, true)
    if not s then return nil end
    local e = src:find(stopPlain, s, true)
    if not e then return nil end
    return src:sub(s, e + #stopPlain - 1)
end
local function has(src, plain) return src and src:find(plain, 1, true) ~= nil end

-- ============================================================
-- 1. THE CHROME, RUN
-- ============================================================
print("-- Designer cards: GUI:CreateCardChrome draws the section card's look")
local cardTableSrc = cut(SW, "GUI.SectionCard = {", "\n}\n")
local chromeSrc = cut(SW, "function GUI:CreateCardChrome(card, header, opts)", "\nend\n")
check(cardTableSrc ~= nil, "chrome: GUI.SectionCard can be cut out of SettingsWidgets.lua")
check(chromeSrc ~= nil, "chrome: GUI:CreateCardChrome is declared in SettingsWidgets.lua")

if cardTableSrc and chromeSrc then
    local C_PANEL    = { r = 0.12, g = 0.12, b = 0.12 }
    local C_BORDER   = { r = 0.30, g = 0.30, b = 0.30 }
    local C_HOVER    = { r = 0.20, g = 0.20, b = 0.20 }
    local C_TEXT     = { r = 0.90, g = 0.90, b = 0.90 }
    local C_TEXT_DIM = { r = 0.60, g = 0.60, b = 0.60 }
    local ACCENT     = { r = 0.10, g = 0.60, b = 0.90 }
    local surfaces = {}
    local GUI = {
        RoundStripSublevel = -3,
        GetSurfaceStyle = function() return { borderWidth = 1 } end,
        CreateRoundedSurface = function(_, frame, o)
            local s = { frame = frame, opts = o, shown = true }
            function s:Hide() self.shown = false end
            function s:Show() self.shown = true end
            function s:SetFillColor(r, g, b, a) self.fill = { r, g, b, a } end
            function s:SetBorderColor(r, g, b, a) self.border = { r, g, b, a } end
            function s:SetCorners(c) self.corners = c end
            surfaces[#surfaces + 1] = s
            return s
        end,
    }
    local function MakeFrame(w, h)
        local f = FakeUIFrame(w, h)
        f.CreateFontString = function(_, _, _, template)
            local fs = FakeUIFrame()
            fs._template = template
            fs.SetTextColor = function(self, r, g, b) self._tc = { r = r, g = g, b = b } end
            return fs
        end
        return f
    end
    local chunk, err = loadstring(
        "local GUI, C_PANEL, C_BORDER, C_HOVER, C_TEXT, C_TEXT_DIM, GetThemeColor, CreateFrame = ...\n"
        .. cardTableSrc .. "\n" .. chromeSrc)
    check(chunk ~= nil, "chrome: the cut parses (" .. tostring(err) .. ")")
    if chunk then
        chunk(GUI, C_PANEL, C_BORDER, C_HOVER, C_TEXT, C_TEXT_DIM,
              function() return ACCENT end, function() return MakeFrame() end)
        local CARDM = GUI.SectionCard
        local card, header, body = MakeFrame(300, 0), MakeFrame(300, 0), MakeFrame(300, 120)
        local chrome = GUI:CreateCardChrome(card, header, { expanded = false })

        -- Metrics: the section card's, not the old 30px bar.
        eq(header:GetHeight(), CARDM.header, "chrome: the header is the section card's height")
        eq(CARDM.header, 40, "chrome: ...which is 40")
        local p = chrome.chevron._points[1]
        check(p and p[1] == "LEFT" and p[2] == header and p[4] == CARDM.edge,
              "chrome: the chevron sits the card's edge in from the left")
        eq(chrome.chevron:GetWidth(), CARDM.chevron, "chrome: the chevron is the card's chevron size")
        eq(chrome.title._template, "DFFontNormal", "chrome: the title is the card's medium weight")
        eq(chrome.summary._template, "DFFontHighlightSmall", "chrome: the summary is the small face")

        -- Surface: rounded, drawn on the CARD (under every child), rect not the header.
        local surf, hov = surfaces[1], surfaces[2]
        check(surf and surf.frame == card and surf.opts.anchorTo == chrome.rect,
              "chrome: the card surface lives on the card and stretches over the rect")
        eq(surf and surf.opts.radius, CARDM.radius, "chrome: ...at the card radius")
        eq(surf and surf.border and surf.border[4], CARDM.borderAlpha, "chrome: ...with the card's ring alpha")
        check(hov and hov.frame == card and hov.opts.anchorTo == header
              and hov.opts.sublevel == GUI.RoundStripSublevel and hov.opts.border == false,
              "chrome: the hover wash is under the ring, over the header only")
        eq(hov and hov.fill and hov.fill[4], CARDM.headerAlpha,
           "chrome: ...at the header's resting alpha: the header is its own strip")
        check(CARDM.headerAlpha < CARDM.hoverAlpha, "chrome: rest is a step under hover")

        -- Colours: TEXT title, accent chevron, dim summary.
        eq(chrome.title._tc and chrome.title._tc.r, C_TEXT.r, "chrome: the title is TEXT, not accent")
        eq(chrome.chevron._vertex and chrome.chevron._vertex.b, ACCENT.b, "chrome: the chevron is the accent")
        eq(chrome.summary._tc and chrome.summary._tc.r, C_TEXT_DIM.r, "chrome: the summary is dim")

        -- Hover: the strip is always drawn, brighter under the mouse.
        check(hov.shown, "chrome: the header strip is drawn at rest")
        header._scripts.OnEnter()
        eq(hov.fill and hov.fill[4], CARDM.hoverAlpha, "chrome: entering the header brightens it")
        header._scripts.OnLeave()
        eq(hov.fill and hov.fill[4], CARDM.headerAlpha, "chrome: leaving puts it back to rest")
        check(hov.shown, "chrome: ...still drawn")

        -- Title / summary layout, clear of the caller's buttons.
        local anchor = MakeFrame()
        chrome:LayoutText(anchor, 6, 52)
        local sp = chrome.summary._points[1]
        check(sp and sp[1] == "RIGHT" and sp[2] == header and sp[4] == -52,
              "layout: the summary ends the caller's inset from the right")
        local tl, tr = chrome.title._points[1], chrome.title._points[2]
        check(tl and tl[1] == "LEFT" and tl[2] == anchor and tl[3] == "RIGHT" and tl[4] == 6,
              "layout: the title starts after the caller's last piece of furniture")
        check(tr and tr[1] == "RIGHT" and tr[2] == chrome.summary and tr[3] == "LEFT",
              "layout: ...and stops short of the summary")

        -- Summary: only while folded, capped at 45% of the header.
        chrome:SetSummary("Top Left")
        eq(chrome.summary:GetText(), "Top Left", "summary: drawn while folded")
        chrome:SetSummary(string.rep("x", 100))
        eq(chrome.summary:GetWidth(), math.floor(300 * 0.45), "summary: capped at 45% of the header")

        -- Fold: open onto a body, then shut.
        chrome:SetExpanded(true, body)
        eq(chrome.summary:GetText(), "", "fold: open, the summary is not drawn")
        check(chrome.line:IsShown(), "fold: open, the hairline shows")
        eq(hov.corners, CARDM.cornersTop, "fold: open, the wash rounds its top corners only")
        local bottomToBody = false
        for _, pt in ipairs(chrome.rect._points) do
            if pt[1] == "BOTTOM" and pt[2] == body then bottomToBody = true end
        end
        check(bottomToBody, "fold: open, the card runs down to the body's bottom")
        eq(chrome.chevron:GetTexture(), "Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more.png",
           "fold: open, the chevron points down")
        chrome:SetExpanded(false, body)
        check(not chrome.line:IsShown(), "fold: shut, no hairline")
        eq(hov.corners, CARDM.cornersAll, "fold: shut, the wash rounds all four corners")
        local bottomToHeader = false
        for _, pt in ipairs(chrome.rect._points) do
            if pt[1] == "BOTTOM" and pt[2] == header then bottomToHeader = true end
        end
        check(bottomToHeader, "fold: shut, the card is the header alone")
        eq(chrome.chevron:GetTexture(), "Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right.png",
           "fold: shut, the chevron points right")

        -- Disabled.
        chrome:SetDimmed(true)
        eq(chrome.title._tc.r, 0.5, "dimmed: the title greys")
        eq(chrome.chevron._vertex.r, 0.5, "dimmed: the chevron greys")
        eq(chrome.summary._tc.r, C_TEXT_DIM.r, "dimmed: the summary keeps its readable dim")
        chrome:SetDimmed(false)
        eq(chrome.title._tc.r, C_TEXT.r, "dimmed: undimmed, the title is TEXT again")
    end
end

-- ============================================================
-- 2. THE AURA DESIGNER'S SHELL AND ITS THREE CARDS, READ
-- ============================================================
print("-- Designer cards: the Aura Designer's shell and cards use the chrome")
local shell = cut(ADO, "local function CreateCardShell(parent, opts)", "\nend\n")
check(has(shell, "GUI:CreateCardChrome(card, header,"), "AD shell: builds through GUI:CreateCardChrome")
check(not has(shell, "ApplyBackdrop(header"), "AD shell: the old flat header backdrop is gone")
check(has(ADO, "local function CreateCardBody(card, header)"), "AD shell: an open body comes from CreateCardBody")
check(has(cut(ADO, "local function CreateCardBody(card, header)", "\nend\n"), "SetExpanded(true, body)"),
      "AD shell: ...which opens the chrome onto it")
check(has(ADO, "y = y - card:GetHeight() - P.CardGap()"), "AD stack: the reflow uses the card gap")

local effect = cut(CARD, "S.CreateEffectCard = function(parent, yPos, effect)", "\nend\n")
check(effect ~= nil, "effect card: S.CreateEffectCard can be cut out of Cards.lua")
check(has(effect, "CreateCardShell(parent, {"), "effect card: uses the shell")
check(has(effect, "P.CreateCardBody(card, header)"), "effect card: its body is the card's own")
check(not has(effect, "SetBackdropColor(C_HOVER"), "effect card: no hand-rolled hover")
check(has(effect, "chrome:LayoutText("), "effect card: title and summary laid out by the chrome")
check(has(effect, "chrome:SetDimmed(true)"), "effect card: a hidden effect greys its title")
check(has(effect, "return yPos - totalCardH - P.CardGap()"), "effect card: the card gap")
-- Furniture kept.
for _, piece in ipairs({ "local iconSlot = CreateFrame(", "local badgeBg = CreateFrame(",
                         "AttachWarningBadge(header, warnKey,", "GUI:CreateCloseButton(header,",
                         "DF.GUI:CreateGlyphButton(header,", "local collapseBar = CreateFrame(" }) do
    check(has(effect, piece), "effect card: keeps " .. piece)
end
-- Fold keys unchanged.
check(has(effect, 'cardKey = "placed:" .. keyPrefix .. effect.auraName .. "#" .. effect.indicatorID'),
      "effect card: the placed fold key is unchanged")
check(has(effect, 'cardKey = "frame:" .. effect.typeKey .. ":" .. keyPrefix .. effect.auraName'),
      "effect card: the frame-level fold key is unchanged")
check(has(effect, "expandedCards[cardKey] = not expandedCards[cardKey]"),
      "effect card: the header still flips expandedCards")

local lg = cut(EDIT, "S.CreateLayoutGroupCard = function(parent, yPos, group, stack, opts)", "\nend\n")
check(lg ~= nil, "group card: S.CreateLayoutGroupCard can be cut out of Editor.lua")
check(has(lg, "CreateCardShell(parent, {") and has(lg, "P.CreateCardBody(card, header)"),
      "group card: shell and body")
check(not has(lg, "SetBackdropColor(C_HOVER") and not has(lg, "chevronColor"),
      "group card: no hand-rolled hover, no amber chevron")
check(has(lg, "GUI:CreateCloseButton(header,") and has(lg, "DF.GUI:CreateGlyphButton(header,"),
      "group card: keeps its delete and eye")
check(has(lg, "expandedGroups[expandKey] = not expandedGroups[expandKey]"),
      "group card: the fold key is unchanged")
check(has(lg, "chrome:SetSummary("), "group card: what it holds is the folded summary")

local dg = cut(EDIT, "S.BuildDebuffGroupsTab = function()", "\nend\n")
check(dg ~= nil, "debuff card: S.BuildDebuffGroupsTab can be cut out of Editor.lua")
check(has(dg, "CreateCardShell(parent, {") and has(dg, "P.CreateCardBody(card, header)"),
      "debuff card: shell and body")
check(not has(dg, "SetBackdropColor(C_HOVER") and not has(dg, "chevronColor"),
      "debuff card: no hand-rolled hover, no amber chevron")
check(has(dg, 'local cardKey = "dgroup:" .. group.id')
      and has(dg, "expandedGroups[cardKey] = not expandedGroups[cardKey]"),
      "debuff card: the fold key is unchanged")
check(has(dg, "GUI:CreateCloseButton(header,") and has(dg, "DF.GUI:CreateGlyphButton(header,"),
      "debuff card: keeps its delete and eye")

-- ============================================================
-- 3. THE TEXT DESIGNER'S TWO CARDS, READ
-- ============================================================
print("-- Designer cards: the Text Designer's cards use the chrome")
for _, spec in ipairs({
    { name = "element card", start = "local function CreateTextElementCard(GUI, parent, yPos, elem, tdDB, state, page)",
      key = 'local cardKey = "td_elem_" .. tostring(elem.id)' },
    { name = "group card", start = "local function CreateGroupCard(GUI, parent, yPos, elem, tdDB, state, page)",
      key = 'local cardKey = "td_group_" .. tostring(elem.id)' },
}) do
    local src = cut(TD, spec.start, "\nend\n")
    check(src ~= nil, "TD " .. spec.name .. ": can be cut out of TextDesigner/UI/Options.lua")
    check(has(src, "GUI:CreateCardChrome(card, header,"), "TD " .. spec.name .. ": builds through the chrome")
    check(has(src, "local HEADER_HEIGHT = GUI.SectionCard.header"), "TD " .. spec.name .. ": the card header height")
    check(not has(src, "StyleButton(header"), "TD " .. spec.name .. ": the old button-styled header is gone")
    check(not has(src, "CreateElementBackdrop(body"), "TD " .. spec.name .. ": the body has no backdrop of its own")
    check(has(src, "chrome:SetExpanded(not card.collapsed, body)"), "TD " .. spec.name .. ": the fold drives the chrome")
    check(has(src, "chrome:SetDimmed(not elem.enabled)"), "TD " .. spec.name .. ": a hidden card greys its title")
    check(has(src, spec.key), "TD " .. spec.name .. ": the fold key is unchanged")
    check(has(src, "GUI:GetCollapsedGroups()[cardKey] = card.collapsed or nil"),
          "TD " .. spec.name .. ": the fold still persists to collapsedGroups")
    check(has(src, "local chip = header:CreateTexture(") and has(src, "GUI:CreateCloseButton(header,")
          and has(src, "DF.GUI:CreateGlyphButton(header,"),
          "TD " .. spec.name .. ": keeps its chip, delete and eye")
end
check(not has(TD, "C_BODY_BG"), "TD: the old two-layer body colour is gone")

-- No header previews anywhere in the new chrome (test mode is the preview).
check(not has(chromeSrc, "SetPreviewIcons"), "chrome: draws no preview swatches")
