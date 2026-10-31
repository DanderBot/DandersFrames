-- ☠ Companion addon: `...` yields THIS addon's private table, not the parent's.
-- Take the parent's table from the global it publishes (see GUI/Panel.lua).
local DF = DandersFrames
local GUI = DF and DF.GUI
if not GUI then return end
local UFO = GUI.UnitFrameOptions
if not UFO then return end
local L = DF.L

local ipairs, pairs, type, tostring, select = ipairs, pairs, type, tostring, select
local format, concat = string.format, table.concat
local max, min, ceil, floor = math.max, math.min, math.ceil, math.floor
-- Looked up per call, not cached: this page is built rarely, and a headless test
-- swaps the global in after the file has loaded.
local function CreateFrame(...) return _G.CreateFrame(...) end

-- ============================================================
-- THE LINKED FRAMES PAGE (uf_links, under Unit Frames, below Settings)
-- One card per link: the two frames ("linked with"), how many parts are linked,
-- Mirror All / Copy All / Separate All / Unlink, then one row per part both
-- frames have -- its name, a Position & Direction segment (Same / Mirrored /
-- Separate, or Same / Separate for a part that cannot mirror), a Size & Style
-- segment (Same / Separate) and a plain-English result. "+ Link Two Frames"
-- opens a draft card to pick a new pair. The engine is the companion's
-- Links.lua; every change that copies settings asks first.
--
-- ★ TWO LAYOUTS, picked per width (UFO.LinkCardLayout, pure and tested):
--   wide     Part | Position & Direction | Size & Style | Result, one line a row
--   stacked  line 1: part name + result; line 2: the two segments, under one
--            caption line aligned to them ("Part" / "Result" captions dropped)
-- The window's minimum while this page shows is what the stacked layout needs
-- (GUI.PageMinWidths, UFO.LinksMinWindowWidth), so nothing overlaps or clips at
-- the smallest size; the wide layout takes over whenever it fits.
--
-- ⚠ BESPOKE LAYOUT, built from the shared pieces only: kit dropdowns,
-- StyleButton buttons, GUI:CreateSegmentToggle, kit labels and backdrops,
-- ShowTooltip, GUI.Colors. No helper lays out a reflowing table of rows, and the
-- page's own column layout is two settings columns, which this is not.
-- ============================================================

UFO.LINKS_PAGE = "uf_links"
local ICONS = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"

local M = {               -- the card's fixed metrics
    pad = 16,             -- card edge -> content
    gap = 16,             -- between columns / controls: ONE gap, so the columns read apart
    radius = 8,           -- the card's and the tiles' corners
    ddW = 120, ddH = 24,  -- the two frame pickers
    segH = 22,            -- a segment pill's height (the track adds its 2px lip)
    segLip = 2, segGap = 2,  -- GUI:CreateSegmentToggle's rounded track geometry
    segMin = 56,          -- a segment's minimum width
    rowMin = 34,          -- a wide row's minimum height
    capBand = 24,         -- the column-caption band's height
    headingGap = 14,      -- space above a group heading
    resultMin = 130,      -- a wide row's result column, at least
    resultMinStacked = 110,
    nameMin = 100, nameMax = 170,
    tileMin = 160, tileGap = 10,
    btnH = 24, btnGap = 6,
    blockGap = 14,        -- between the page's blocks
}
UFO.LINK_METRICS = M

-- A rounded segment track's width for n segments (CreateSegmentToggle, rounded).
function UFO.SegTrackWidth(n, segW)
    return n * segW + (n - 1) * M.segGap + 2 * M.segLip
end

local function C(name) return (GUI.Colors and GUI.Colors[name]) or { r = 1, g = 1, b = 1 } end
-- The section cards' own recipe (GUI.SectionCard, GUI:CreateCardChrome): the card
-- fill is GUI.Colors.panel, its ring GUI.Colors.border at the card's borderAlpha,
-- hairlines at its lineAlpha and a header strip GUI.Colors.hover at headerAlpha.
local function Card() return GUI.SectionCard or { borderAlpha = 0.6, lineAlpha = 0.4, headerAlpha = 0.35 } end

-- A card surface: rounded, the settings pages' card ground and ring.
local function CardSurface(frame)
    local panel, border, card = C("panel"), C("border"), Card()
    if not GUI.CreateRoundedSurface then return nil end
    return GUI:CreateRoundedSurface(frame, {
        radius = M.radius, borderWidth = 1,
        fill = { panel.r, panel.g, panel.b, 1 },
        border = { border.r, border.g, border.b, card.borderAlpha },
    })
end
local function Accent() return (GUI.GetAccent and GUI:GetAccent()) or GUI.UnitsAccent or C("text") end
local function Paint(fs, c) if fs and c then fs:SetTextColor(c.r, c.g, c.b) end end

local function Label(parent, text, size, color, wrap)
    local fs = GUI:CreateLabelNative(parent, { text = text or "", size = size, color = color or C("text") })
    if fs.SetWordWrap then fs:SetWordWrap(wrap and true or false) end
    if fs.SetJustifyV then fs:SetJustifyV("TOP") end
    return fs
end

-- Text width / wrapped height, with an estimate while the font is not ready
-- (GetStringWidth answers 0 until it has resolved).
local function TextW(fs, fallbackPerChar)
    local w = fs and fs.GetStringWidth and fs:GetStringWidth() or 0
    if w <= 0 then w = #(fs and fs.GetText and fs:GetText() or "") * (fallbackPerChar or 6) end
    return ceil(w)
end
local function WrappedH(fs, width, lineH)
    lineH = lineH or 14
    fs:SetWidth(max(width, 1))
    local h = fs.GetStringHeight and fs:GetStringHeight() or 0
    if h <= 0 then
        local w = TextW(fs)
        h = lineH * max(1, ceil(w / max(width, 1)))
    end
    return ceil(h)
end

-- A plain hover region over `region` (a FontString or texture), motion only, so
-- it never takes a click from what is underneath.
local function HoverTip(parent, region, spec, regionEnd)
    local hit = CreateFrame("Frame", nil, parent)
    hit:SetPoint("TOPLEFT", region, "TOPLEFT", -2, 2)
    hit:SetPoint("BOTTOMRIGHT", regionEnd or region, "BOTTOMRIGHT", 2, -2)
    if hit.SetMouseMotionEnabled then hit:SetMouseMotionEnabled(true) end
    if hit.SetMouseClickEnabled then hit:SetMouseClickEnabled(false) end
    hit:SetScript("OnEnter", function(self)
        local s = type(spec) == "function" and spec() or spec
        if s then GUI:ShowTooltip(self, s) end
    end)
    hit:SetScript("OnLeave", function() GUI:HideTooltip() end)
    return hit
end

local function TipButton(parent, btn, spec)
    btn:HookScript("OnEnter", function(self)
        local s = type(spec) == "function" and spec() or spec
        if s then GUI:ShowTooltip(self, s) end
    end)
    btn:HookScript("OnLeave", function() GUI:HideTooltip() end)
end

local function Button(parent, text, opts)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    opts = opts or {}
    GUI:StyleButton(b, { text = text, height = M.btnH, width = opts.width or 60, tone = opts.tone,
                         primary = opts.primary, icon = opts.icon, rounded = true })
    return b
end

-- A hairline: the card's header/body line, or (soft) the line between two rows.
local function Line(parent, soft)
    local t = parent:CreateTexture(nil, "BORDER")
    local c = C("border")
    t:SetColorTexture(c.r, c.g, c.b, Card().lineAlpha * (soft and 0.6 or 1))
    t:SetHeight(1)
    return t
end

-- The column captions' band: the header-strip shade, a step off the card.
local function Band(parent)
    local t = parent:CreateTexture(nil, "BACKGROUND", nil, 1)
    local c = C("hover")
    t:SetColorTexture(c.r, c.g, c.b, Card().headerAlpha)
    return t
end

-- ============================================================
-- WORDS (functions, never file-scope tables of L[...]: a language override must
-- be read when it is shown, not frozen at load)
-- ============================================================
local function U(unit) return UFO.UnitLabel(unit) end

-- What each part's two columns cover, and why a part starts separate.
function UFO.LinkPartText(id)
    if id == "health" then
        return L["Where its text and markers sit, left and right offsets."], L["Height, texture, colours, background."]
    elseif id == "resource" then
        return L["Which edge it sits on, offsets."], L["Height, texture, colours."]
    elseif id == "portrait" then
        return L["Which side of the frame it is on, offsets."], L["Size, style (3D, 2D, class), zoom, border."]
    elseif id == "castbar" then
        return L["Icon side, spell name and timer sides, offsets."], L["Height, colours, texture, interrupt marker."]
    elseif id == "text" then
        return L["Which side each text sits on. Mirrored text is flipped when drawn; the Text Designer template itself is not changed."],
            L["The Text Designer template, fonts and colours."]
    elseif id == "buffs" or id == "debuffs" then
        return L["The corner it starts from, growth direction, offsets."], L["Icon size, how many, rows, borders, timers."]
    elseif id == "border" then
        return nil, L["Thickness, colour, glow."]
    elseif id == "absorbs" then
        return L["Where the shield sits on the bar."], L["Texture, colour, overshield glow."]
    elseif id == "healpred" then
        return L["Where incoming heals sit on the bar."], L["Texture, colour."]
    elseif id == "icons" then
        return L["Corner and offsets of each icon."], L["Icon size and which icons show."]
    elseif id == "unitIcons" then
        return L["Corner and offsets of the PvP and elite/rare icons."], L["Size and style."]
    elseif id == "tooltips" then
        return L["Where the tooltip opens."], L["When it shows."]
    elseif id == "visibility" then
        return nil, L["When the frame shows (combat, group, target)."]
    elseif id == "fading" then
        return nil, L["Out of range and out of combat fading."]
    elseif id == "frame" then
        return nil, L["Width, height, scale and frame fading."]
    elseif id == "highlights" then
        return nil, L["Selection, hover, aggro and threat highlights."]
    elseif id == "auradesigner" then
        return nil, L["Whether the Aura Designer is on."]
    elseif id == "classpower" or id == "defensive" or id == "dispel" or id == "bosslayout" then
        return L["Where it sits, offsets."], L["Size, colours and what it shows."]
    end
    return nil, nil
end

-- Why a part starts separate (the "separate by default" group).
function UFO.LinkPartWhy(id)
    if id == "absorbs" then return L["Separate by default because it follows the way health fills, which mirroring does not flip."] end
    if id == "healpred" then return L["Separate by default for the same reason as Absorbs."] end
    if id == "icons" then return L["Player and Target show different icons (resting, combat, leader)."] end
    if id == "unitIcons" then return L["Elite and rare marks only matter on Target."] end
    if id == "visibility" then return L["Target only exists when you have a target, so its rules usually differ."] end
    return nil
end

-- What a link keeps apart in this part (link.except), in words; nil if nothing.
local EXCEPT_PART = { healthColorMode = "health", castbarDetached = "castbar", castbarLatency = "castbar" }
function UFO.LinkExceptText(link, id)
    local except = link and type(link.except) == "table" and link.except
    if not except then return nil end
    local Lk = UFO.Links()
    local any = false
    for key in pairs(except) do
        if (EXCEPT_PART[key] or (Lk and Lk.OwnerOf(key))) == id then any = true break end
    end
    if not any then return nil end
    if id == "health" then return L["Health colour mode, so Target can colour by reaction."] end
    if id == "castbar" then return L["Detached or attached, and latency (Player only)."] end
    if id == "buffs" then return L["Which buffs show (Player shows yours, Target shows all)."] end
    if id == "debuffs" then return L["Which debuffs show (Target shows enemy debuffs)."] end
    return L["Settings that start out different on each frame."]
end

-- The result line for one part.
function UFO.LinkResult(elem, layout, look, follower, leader)
    local hasLayout = elem and elem.layout
    if not hasLayout then
        return look == "same" and L["Same on both frames."] or L["Not linked. Each frame has its own."]
    end
    if layout == "mirror" and look == "same" then return format(L["%s is a mirror image of %s."], U(follower), U(leader)) end
    if layout == "mirror" then return format(L["Positions mirror. %s keeps its own size and style."], U(follower)) end
    if layout == "same" and look == "same" then return L["Identical on both frames."] end
    if layout == "same" then return format(L["Same positions. %s keeps its own size and style."], U(follower)) end
    if look == "same" then return L["Same size and style. Each frame places it on its own."] end
    return L["Not linked. Each frame has its own."]
end

local function PositionTip(value, follower, leader)
    if value == "same" then return L["Both frames put it in the same place. Moving it on either frame moves it on both."] end
    if value == "mirror" then
        return format(L["Flipped left to right. If it sits on %s's left, it sits on %s's right, and growth directions reverse. Up and down stay the same."],
            U(leader), U(follower))
    end
    return L["Each frame places it on its own. Moving it on one frame leaves the other alone."]
end

local function LookTip(value)
    if value == "same" then return L["Both frames share its size and style. Change it on either frame and both change."] end
    return L["Each frame keeps its own size and style."]
end

-- ============================================================
-- LAYOUT DECISIONS (pure)
-- m: { pad, gap, nameW, posW, lookW, resultMin, resultMinStacked,
--      pickersW, summaryW, buttonsW }
-- ============================================================
function UFO.LinkCardNeeds(m)
    local inner = function(w) return w + 2 * m.pad end
    local wide = inner(m.nameW + m.gap + m.posW + m.gap + m.lookW + m.gap + m.resultMin)
    local header = max(m.pickersW or 0, m.summaryW or 0, m.buttonsW or 0)
    local stacked = inner(max(m.posW + m.gap + m.lookW, m.nameW + m.gap + m.resultMinStacked, header))
    return wide, stacked
end

-- Which layout a card of `width` uses, and where its columns go.
function UFO.LinkCardLayout(width, m)
    local wideNeed = UFO.LinkCardNeeds(m)
    local x0 = m.pad
    if width >= wideNeed then
        local pos = x0 + m.nameW + m.gap
        local look = pos + m.posW + m.gap
        local result = look + m.lookW + m.gap
        return { mode = "wide", name = x0, pos = pos, look = look, result = result,
                 resultW = width - m.pad - result }
    end
    return { mode = "stacked", name = x0, result = x0 + m.nameW + m.gap,
             resultW = width - m.pad - (x0 + m.nameW + m.gap),
             pos = x0, look = x0 + m.posW + m.gap }
end

-- How a card header breaks: one line, two (buttons below) or three (summary,
-- then buttons, each on its own line).
function UFO.LinkHeaderLines(width, m)
    local inner = width - 2 * m.pad
    if m.pickersW + m.gap + m.summaryW + m.gap + m.buttonsW <= inner then return 1 end
    if m.pickersW + m.gap + m.summaryW <= inner then return 2 end
    return 3
end

-- The narrowest page width (widget width) everything still fits at.
function UFO.LinksMinUsableWidth(m)
    local _, stacked = UFO.LinkCardNeeds(m)
    return max(stacked, m.headW or 0, m.tileMin or 0)
end

-- ...and as a WINDOW width, through the window's measured chrome.
function UFO.LinksMinWindowWidth(m, chrome)
    m = m or UFO.linkMeasured or UFO.LinkDefaultMeasures()
    chrome = chrome or (GUI.PageChromeWidth and GUI.PageChromeWidth()) or 281
    return ceil(chrome + UFO.LinksMinUsableWidth(m))
end

-- Estimates for before anything is measured (English at the panel's font).
function UFO.LinkDefaultMeasures()
    local segW = 60
    return {
        pad = M.pad, gap = M.gap, nameW = 130, segW = segW,
        posW = UFO.SegTrackWidth(3, segW), lookW = UFO.SegTrackWidth(2, segW),
        resultMin = M.resultMin, resultMinStacked = M.resultMinStacked,
        pickersW = M.ddW * 2 + 2 * 8 + 80, summaryW = 130, buttonsW = 4 * 76 + 3 * M.btnGap,
        headW = 280, tileMin = M.tileMin,
    }
end

-- The width this page's widgets get right now.
function UFO.LinksPageWidth()
    local cf = GUI.contentFrame
    local cw = cf and cf.GetWidth and cf:GetWidth() or 0
    if cw <= 0 then return 560 end
    return GUI.PageUsableWidth(GUI.PageChildWidth(cw))
end

-- ============================================================
-- ACTIONS (every change that copies settings asks first)
-- ============================================================
local function Lk() return UFO.Links() end
local function Root() return UFO.Root() end

function UFO.LinksPage()
    return GUI.Pages and GUI.Pages[UFO.LINKS_PAGE]
end

-- After a part changes: frames, marks, banners elsewhere, and this page's rows.
local function AfterAspect(follower, leader)
    UFO.InvalidateUnitPages(follower)
    UFO.InvalidateUnitPages(leader)
    local UF = DF.UnitFrames
    if UF and UF.RequestRefresh then UF:RequestRefresh() end
    UFO.RefreshLinkMarks()
    local page = UFO.LinksPage()
    if page and GUI.CurrentPageName == UFO.LINKS_PAGE and page.RefreshStates then page:RefreshStates() end
end

-- After a link is made, moved or removed: everything above, and the page is
-- rebuilt (its cards are one per link).
local function AfterLinks(...)
    for i = 1, select("#", ...) do
        local u = select(i, ...)
        if u then UFO.InvalidateUnitPages(u) end
    end
    local UF = DF.UnitFrames
    if UF and UF.RequestRefresh then UF:RequestRefresh() end
    UFO.RefreshLinkMarks()
    local page = UFO.LinksPage()
    if page then
        if GUI.CurrentPageName == UFO.LINKS_PAGE and page.Refresh then page:Refresh()
        elseif page.Invalidate then page:Invalidate() end
    end
end
UFO.AfterLinks = AfterLinks

local function Popup(title, message, okLabel, onOk, onCancel)
    DF:ShowPopupAlert({
        title = title, message = message,
        buttons = {
            { label = okLabel, onClick = onOk },
            { label = L["Cancel"], onClick = onCancel },
        },
    })
end

-- Link `follower` to `leader` (from the draft card, or a card's picker moving
-- one end). `elements` nil: the pair's starting point (Links.StartingElements).
function UFO.ConfirmLinkPair(follower, leader, elements, done)
    local lk, root = Lk(), Root()
    done = done or function() end
    if not (lk and root) or follower == leader or not (UFO.IsUnit(follower) and UFO.IsUnit(leader)) then return done() end
    local message = format(L["Link %s to %s?\n\n%s's linked settings are copied to %s now, and from then on a change on either one changes the other."],
        U(follower), U(leader), U(leader), U(follower))
    local oldF, oldL = lk:Partner(root, follower), lk:Partner(root, leader)
    if (oldF and oldF ~= leader) or (oldL and oldL ~= follower) then
        message = message .. "\n\n" .. L["A frame links to one other frame, so this replaces their current links."]
    end
    Popup(L["Linked Frames"], message, L["Link"], function()
        local els, except
        if elements then
            els = elements
            local d = lk.DEFAULT
            local isPair = (follower == d.follower and leader == d.leader) or (follower == d.leader and leader == d.follower)
            except = isPair and lk.DeliberateDifferences(follower, leader, els) or nil
        else
            els, except = lk.StartingElements(follower, leader)
        end
        lk:SetLink(root, follower, leader, els, except)
        UFO.linkDraft = nil
        AfterLinks(follower, leader, oldF, oldL)
        done()
    end, done)
end

function UFO.ConfirmUnlink(unit, done)
    local lk, root = Lk(), Root()
    done = done or function() end
    local partner = lk and root and lk:Partner(root, unit)
    if not partner then return done() end
    Popup(L["Unlink"], format(L["Unlink %s and %s?\n\nBoth keep their settings as they are now. They just stop changing together."],
        U(unit), U(partner)), L["Unlink"], function()
        lk:Unlink(root, unit)
        AfterLinks(unit, partner)
        done()
    end, done)
end

-- One part's aspect. Separate copies nothing, so it just happens.
function UFO.SetLinkAspect(follower, elem, aspect, value)
    local lk, root = Lk(), Root()
    if not (lk and root) then return end
    local link, _, leader = lk:LinkOf(root, follower)
    if not link then return end
    local layout, look = lk:Aspects(root, follower, elem.id)
    if aspect == "layout" then layout = value else look = value end
    local function apply()
        lk:SetElement(root, follower, elem.id, layout, look)
        AfterAspect(follower, leader)
    end
    if value == "own" then return apply() end
    Popup(L["Linked Frames"], format(L["Link %s?\n\n%s's %s settings are copied to %s now."],
        L[elem.title], U(leader), L[elem.title], U(follower)), L["Link"], apply)
end

function UFO.SetAllAspects(follower, layout, look, label)
    local lk, root = Lk(), Root()
    if not (lk and root) then return end
    local link, _, leader = lk:LinkOf(root, follower)
    if not link then return end
    local ids = {}
    for _, e in ipairs(UFO.SharedElements(follower, leader)) do ids[#ids + 1] = e.id end
    local function apply()
        lk:SetAll(root, follower, ids, layout, look)
        AfterAspect(follower, leader)
    end
    if layout == "own" and look == "own" then return apply() end
    Popup(label, format(L["%s's settings for every linked part are copied to %s now."], U(leader), U(follower)),
        label, apply)
end

-- ============================================================
-- WHICH PARTS, AND IN WHAT ORDER
-- The page lists the default link's parts first (as the mockup reads: bars,
-- portrait, cast bar, text, auras, border), then the rest.
-- ============================================================
UFO.LINK_PAGE_ORDER = {
    "health", "resource", "portrait", "castbar", "text", "buffs", "debuffs", "border",
    "absorbs", "healpred", "icons", "unitIcons", "tooltips", "visibility", "fading",
    "frame", "highlights", "auradesigner", "classpower", "defensive", "dispel", "bosslayout",
}

-- The parts both frames have, split into the two groups, in page order.
function UFO.LinkPageGroups(a, b)
    local lk = Lk()
    local linked, separate = {}, {}
    if not lk then return linked, separate end
    local shared = {}
    for _, e in ipairs(UFO.SharedElements(a, b)) do shared[e.id] = e end
    for _, id in ipairs(UFO.LINK_PAGE_ORDER) do
        local e = shared[id]
        if e then
            if lk.IsDefaultElement(id) then linked[#linked + 1] = e else separate[#separate + 1] = e end
            shared[id] = nil
        end
    end
    -- An element added later and missing from the order still shows, at the end.
    for _, e in ipairs(lk.ELEMENTS) do
        if shared[e.id] then separate[#separate + 1] = e end
    end
    return linked, separate
end

function UFO.LinkedPartCount(follower, leader)
    local lk, root = Lk(), Root()
    local n, total = 0, 0
    for _, e in ipairs(UFO.SharedElements(follower, leader)) do
        total = total + 1
        if lk and root and lk:ElementLinked(root, follower, e.id) then n = n + 1 end
    end
    return n, total
end

-- ============================================================
-- ONE PART'S ROW
-- ============================================================
local SEG_FONT = 10

local function PartRow(card, e, ctx)
    local row = CreateFrame("Frame", nil, card)
    row.elem = e
    local function link() return ctx.follower, ctx.leader end

    row.name = Label(row, L[e.title], 12, C("text"))
    row.badge = Label(row, "", 10, C("textDim"))
    row.nameTip = HoverTip(row, row.name, function()
        local pos, size = UFO.LinkPartText(e.id)
        local lines = {
            { text = format("%s: %s", L["Position & Direction"], pos or L["None"]) },
            { text = format("%s: %s", L["Size & Style"], size or "") },
        }
        local lk, root = Lk(), Root()
        local lnk = lk and root and lk:LinkOf(root, ctx.follower)
        local except = UFO.LinkExceptText(lnk, e.id)
        if except then
            lines[#lines + 1] = { text = format("%s: %s", L["Always separate"], except), accent = true }
        elseif not (lk and lk.IsDefaultElement(e.id)) then
            local why = UFO.LinkPartWhy(e.id)
            if why then lines[#lines + 1] = { text = why, accent = true } end
        end
        return { title = L[e.title], lines = lines }
    end)

    local neutral = C("textDim")
    if e.layout then
        local segs = { { value = "same", label = L["Same"] } }
        local lk = Lk()
        if lk and lk.CanMirror(e.id) then segs[#segs + 1] = { value = "mirror", label = L["Mirrored"] } end
        segs[#segs + 1] = { value = "own", label = L["Separate"], accent = neutral }
        for _, s in ipairs(segs) do
            local v = s.value
            s.tooltip = function()
                local f, l = link()
                return { title = format(L["%s: %s position"], s.label, L[e.title]), lines = { PositionTip(v, f, l) } }
            end
        end
        row.pos = GUI:CreateSegmentToggle(row, segs, nil, nil, nil, {
            segmentWidth = ctx.m.segW, height = M.segH, fontSize = SEG_FONT, rounded = true,
            customGet = function() return (Lk():Aspects(Root(), ctx.follower, e.id)) end,
            customSet = function(v) UFO.SetLinkAspect(ctx.follower, e, "layout", v) end,
        })
        row.posW = UFO.SegTrackWidth(#segs, ctx.m.segW)
    else
        row.noPos = Label(row, L["No position settings"], 11, C("textDim"))
        row.noPosTip = HoverTip(row, row.noPos, {
            title = L[e.title], lines = { L["This part has nothing to place, so only its size and style can be linked."] } })
        row.posW = TextW(row.noPos)
    end
    local looks = {
        { value = "same", label = L["Same"] },
        { value = "own", label = L["Separate"], accent = neutral },
    }
    for _, s in ipairs(looks) do
        local v = s.value
        s.tooltip = function()
            return { title = format(L["%s: %s size & style"], s.label, L[e.title]), lines = { LookTip(v) } }
        end
    end
    row.look = GUI:CreateSegmentToggle(row, looks, nil, nil, nil, {
        segmentWidth = ctx.m.segW, height = M.segH, fontSize = SEG_FONT, rounded = true,
        customGet = function() return select(2, Lk():Aspects(Root(), ctx.follower, e.id)) end,
        customSet = function(v) UFO.SetLinkAspect(ctx.follower, e, "look", v) end,
    })
    row.result = Label(row, "", 11, C("textDim"), true)

    -- Repaint from the link: segments, badge, result.
    function row:Refresh()
        local lk, root = Lk(), Root()
        if not (lk and root) then return end
        local layout, look = lk:Aspects(root, ctx.follower, e.id)
        local pos = rawget(self, "pos")
        if pos and pos.Refresh then pos:Refresh() end
        if self.look and self.look.Refresh then self.look:Refresh() end
        local lnk = lk:LinkOf(root, ctx.follower)
        self.badge:SetText(UFO.LinkExceptText(lnk, e.id) and "+1" or "")
        self.result:SetText(UFO.LinkResult(e, layout, look, ctx.follower, ctx.leader))
        Paint(self.result, (layout ~= "own" or look ~= "own") and C("text") or C("textDim"))
    end

    -- The thin line above the row (shown for every row but a group's first).
    row.sep = Line(row, true)

    -- Lay out for the card's columns; returns the row's height. `first`: the
    -- first row under a group heading, which carries no separator.
    function row:Layout(cols, width, first)
        self:SetWidth(width)
        self.sep:ClearAllPoints()
        self.sep:SetPoint("TOPLEFT", self, "TOPLEFT", ctx.m.pad, 0)
        self.sep:SetPoint("TOPRIGHT", self, "TOPRIGHT", -ctx.m.pad, 0)
        self.sep:SetShown(not first)
        self.name:ClearAllPoints()
        self.badge:ClearAllPoints()
        self.result:ClearAllPoints()
        -- rawget: a row has one or the other, and the missing one must read nil.
        local noPos = rawget(self, "noPos")
        local posFrame = rawget(self, "pos") or noPos
        posFrame:ClearAllPoints()
        self.look:ClearAllPoints()
        local resultH = WrappedH(self.result, max(cols.resultW, 40))
        -- The name never runs into the next column: a long translation is cut
        -- short (the tooltip still names it in full), leaving room for the badge.
        self.name:SetWidth(min(TextW(self.name), ctx.m.nameW - 22))
        local h
        if cols.mode == "wide" then
            h = max(M.rowMin, resultH + 10)
            self.name:SetPoint("LEFT", self, "TOPLEFT", cols.name, -h / 2)
            self.badge:SetPoint("LEFT", self.name, "RIGHT", 4, 0)
            posFrame:SetPoint("LEFT", self, "TOPLEFT", cols.pos, -h / 2)
            self.look:SetPoint("LEFT", self, "TOPLEFT", cols.look, -h / 2)
            self.result:SetPoint("TOPLEFT", self, "TOPLEFT", cols.result, -(h - resultH) / 2)
        else
            local line1 = max(16, resultH)
            self.name:SetPoint("TOPLEFT", self, "TOPLEFT", cols.name, -8)
            self.badge:SetPoint("LEFT", self.name, "RIGHT", 4, 0)
            self.result:SetPoint("TOPLEFT", self, "TOPLEFT", cols.result, -8)
            local y2 = 8 + line1 + 6
            local trackH = M.segH + 2 * M.segLip
            posFrame:SetPoint("TOPLEFT", self, "TOPLEFT", cols.pos, -(y2 + (noPos and 6 or 0)))
            self.look:SetPoint("TOPLEFT", self, "TOPLEFT", cols.look, -y2)
            h = y2 + trackH + 8
        end
        self:SetHeight(h)
        return h
    end

    row:Refresh()
    return row
end

-- ============================================================
-- A LINK'S CARD (or the draft card a new link is picked in)
-- ============================================================
local function UnitOptions(except)
    local opts = { _order = {} }
    for _, u in ipairs(UFO.UNITS) do
        if u ~= except then
            opts[u] = U(u)
            opts._order[#opts._order + 1] = u
        end
    end
    return opts
end

-- A frame picker. Its hover reads dd.tooltip (the kit's label hover), which the
-- card's Refresh keeps naming the frames it is about.
local function Picker(card, label, get, set, optionsFn)
    local dd = GUI:CreateDropdown(card, label, optionsFn(), nil, nil, nil, get, set,
        { inline = true, optionsFunc = optionsFn })
    dd:SetSize(M.ddW, M.ddH)
    return dd
end

function UFO.CreateLinkCard(parent, follower, leader, m, draft)
    local card = CreateFrame("Frame", nil, parent)
    CardSurface(card)
    local ctx = { follower = follower, leader = leader, m = m, draft = draft }
    card.ctx = ctx

    -- ---- header: [leader] linked with [follower]   N of M   buttons ----------
    -- ★ THE FIRST PICKER IS THE LEADER: the card reads "<leader> linked with
    -- <follower>", and the results are phrased from the follower's side ("Target
    -- is a mirror image of Player"). Both pickers offer every frame: picking the
    -- frame the OTHER picker shows swaps the two round (the leader becomes the
    -- follower), anything else moves that end of the link. A real link asks first.
    local function Elements()
        local lk, root = Lk(), Root()
        local lnk = lk and root and lk:LinkOf(root, ctx.follower)
        return lnk and lnk.elements
    end
    local function Pick(isLeader, v)
        if draft then
            if isLeader then
                if v == ctx.follower then ctx.follower = ctx.leader end
                ctx.leader = v
            else
                if v == ctx.leader then ctx.leader = ctx.follower end
                ctx.follower = v
            end
            UFO.linkDraft.leader, UFO.linkDraft.follower = ctx.leader, ctx.follower
            if card.leaderDD.UpdateText then card.leaderDD:UpdateText() end
            if card.followerDD.UpdateText then card.followerDD:UpdateText() end
            return
        end
        local mine = isLeader and ctx.leader or ctx.follower
        local other = isLeader and ctx.follower or ctx.leader
        if v == mine then return end
        if v == other then
            -- Swap: the follower leads, the leader follows.
            return UFO.ConfirmLinkPair(ctx.leader, ctx.follower, Elements())
        end
        if isLeader then
            UFO.ConfirmLinkPair(ctx.follower, v, Elements())
        else
            UFO.ConfirmLinkPair(v, ctx.leader, Elements())
        end
    end
    card.leaderDD = Picker(card, L["First frame"],
        function() return ctx.leader end,
        function(v) Pick(true, v) end,
        function() return UnitOptions(nil) end)
    card.linkIcon = card:CreateTexture(nil, "OVERLAY")
    card.linkIcon:SetTexture(UFO.LINK_ICON)
    card.linkIcon:SetSize(14, 14)
    local acc = Accent()
    card.linkIcon:SetVertexColor(acc.r, acc.g, acc.b)
    card.linkedWith = Label(card, L["linked with"], 11, acc)
    card.followerDD = Picker(card, L["Second frame"],
        function() return ctx.follower end,
        function(v) Pick(false, v) end,
        function() return UnitOptions(nil) end)
    card.summary = Label(card, "", 11, C("textDim"))

    card.buttons = {}
    local function AddButton(text, opts, onClick, tip)
        local b = Button(card, text, opts)
        b:SetScript("OnClick", onClick)
        if tip then TipButton(card, b, tip) end
        card.buttons[#card.buttons + 1] = b
        return b
    end
    if draft then
        AddButton(L["Link"], { primary = true }, function()
            UFO.ConfirmLinkPair(ctx.follower, ctx.leader, nil)
        end)
        AddButton(L["Cancel"], nil, function()
            UFO.linkDraft = nil
            AfterLinks()
        end)
        card.summary:SetText(L["Pick two frames, then Link."])
    else
        AddButton(L["Mirror All"], nil, function() UFO.SetAllAspects(ctx.follower, "mirror", "same", L["Mirror All"]) end,
            function() return { title = L["Mirror All"], lines = { format(L["Every part shares its size and style, and its position is mirrored. %s becomes a mirror image of %s."],
                U(ctx.follower), U(ctx.leader)) } } end)
        AddButton(L["Copy All"], nil, function() UFO.SetAllAspects(ctx.follower, "same", "same", L["Copy All"]) end,
            { title = L["Copy All"], lines = { L["Every part is the same on both frames, nothing flipped."] } })
        AddButton(L["Separate All"], nil, function() UFO.SetAllAspects(ctx.follower, "own", "own", L["Separate All"]) end,
            { title = L["Separate All"], lines = { L["Keeps the link but shares nothing. Each frame keeps its current settings."] } })
        AddButton(L["Unlink"], { tone = "danger" }, function() UFO.ConfirmUnlink(ctx.follower) end,
            { title = L["Unlink"], lines = { L["Removes this link. Both frames keep the settings they have now. Nothing is reset."] } })
    end

    card.rows = {}
    if not draft then
        -- ---- column captions --------------------------------------------------
        card.capPart = Label(card, L["Part"], 10, C("textDim"))
        card.capPos = Label(card, L["Position & Direction"], 10, C("textDim"))
        card.capLook = Label(card, L["Size & Style"], 10, C("textDim"))
        card.capResult = Label(card, L["Result"], 10, C("textDim"))
        -- The two captions that explain something carry an info glyph, and the
        -- hover covers caption and glyph together.
        local function InfoGlyph(after)
            local t = card:CreateTexture(nil, "OVERLAY")
            t:SetTexture(ICONS .. "info.png")
            t:SetSize(11, 11)
            local d = C("textDim")
            t:SetVertexColor(d.r, d.g, d.b)
            t:SetPoint("LEFT", after, "RIGHT", 3, 0)
            return t
        end
        card.capPosInfo = InfoGlyph(card.capPos)
        card.capLookInfo = InfoGlyph(card.capLook)
        card.capPosTip = HoverTip(card, card.capPos, { title = L["Position & Direction"],
            lines = { L["Where things sit on the frame: which side, which corner, offsets, and which way icons grow."] } },
            card.capPosInfo)
        card.capLookTip = HoverTip(card, card.capLook, { title = L["Size & Style"],
            lines = { L["Everything else: sizes, colours, textures, fonts, borders, counts and timers."] } },
            card.capLookInfo)
        card.headLine = Line(card)
        card.capBand = Band(card)
        card.bandLine = Line(card)

        local linked, separate = UFO.LinkPageGroups(ctx.follower, ctx.leader)
        card.groupLinked = Label(card, L["Linked by default"], 12, C("text"))
        for _, e in ipairs(linked) do card.rows[#card.rows + 1] = PartRow(card, e, ctx) end
        card.firstSeparate = #card.rows + 1
        card.groupSeparate = Label(card, L["Separate by default"], 12, C("text"))
        card.groupSeparateSub = Label(card, L["These usually differ between the two frames. You can still link them."], 11, C("textDim"), true)
        for _, e in ipairs(separate) do card.rows[#card.rows + 1] = PartRow(card, e, ctx) end
        card.hasLinkedGroup, card.hasSeparateGroup = #linked > 0, #separate > 0
        card.footLine = Line(card)
        card.footIcon = card:CreateTexture(nil, "OVERLAY")
        card.footIcon:SetTexture(ICONS .. "info.png")
        card.footIcon:SetSize(12, 12)
        local d = C("textDim")
        card.footIcon:SetVertexColor(d.r, d.g, d.b)
        card.foot = Label(card, L["Never linked: where each frame sits on screen, and whether it uses DandersFrames or Blizzard's frame."], 11, d, true)
    end

    function card:Refresh()
        self.leaderDD.tooltip = { title = L["First frame"],
            lines = { L["Choose which frame this link starts from. Mirrored parts are flipped relative to this frame."] } }
        self.followerDD.tooltip = { title = L["Second frame"],
            lines = { format(L["Choose the frame linked to %s. Changing this asks first, then copies %s's shared parts onto it."],
                U(ctx.leader), U(ctx.leader)) } }
        if not ctx.draft then
            local n, total = UFO.LinkedPartCount(ctx.follower, ctx.leader)
            self.summary:SetText(format(L["%d of %d parts linked"], n, total))
        end
        for _, r in ipairs(self.rows) do r:Refresh() end
        if self.leaderDD.UpdateText then self.leaderDD:UpdateText() end
        if self.followerDD.UpdateText then self.followerDD:UpdateText() end
    end

    -- Lay the card out at `width`; returns its height.
    function card:Layout(width)
        self:SetWidth(width)
        local pad, gap = M.pad, M.gap
        local y = pad
        -- header
        local lines = UFO.LinkHeaderLines(width, m)
        self.leaderDD:ClearAllPoints()
        self.leaderDD:SetPoint("TOPLEFT", self, "TOPLEFT", pad, -y)
        self.linkIcon:ClearAllPoints()
        self.linkIcon:SetPoint("LEFT", self.leaderDD, "RIGHT", 8, 0)
        self.linkedWith:ClearAllPoints()
        self.linkedWith:SetPoint("LEFT", self.linkIcon, "RIGHT", 4, 0)
        self.followerDD:ClearAllPoints()
        self.followerDD:SetPoint("LEFT", self.linkedWith, "RIGHT", 8, 0)
        self.summary:ClearAllPoints()
        local lineH = M.ddH
        local buttonsY
        if lines == 1 then
            self.summary:SetPoint("LEFT", self.followerDD, "RIGHT", gap, 0)
            buttonsY = y
        elseif lines == 2 then
            self.summary:SetPoint("LEFT", self.followerDD, "RIGHT", gap, 0)
            buttonsY = y + lineH + 8
        else
            self.summary:SetPoint("TOPLEFT", self, "TOPLEFT", pad, -(y + lineH + 6))
            buttonsY = y + lineH + 6 + 14 + 8
        end
        -- buttons: right-aligned on the header line, else left-aligned below
        local prev
        for i = #self.buttons, 1, -1 do
            local b = self.buttons[i]
            b:ClearAllPoints()
            if lines == 1 then
                if prev then b:SetPoint("RIGHT", prev, "LEFT", -M.btnGap, 0)
                else b:SetPoint("TOPRIGHT", self, "TOPRIGHT", -pad, -y) end
                prev = b
            end
        end
        if lines ~= 1 then
            prev = nil
            for _, b in ipairs(self.buttons) do
                if prev then b:SetPoint("LEFT", prev, "RIGHT", M.btnGap, 0)
                else b:SetPoint("TOPLEFT", self, "TOPLEFT", pad, -buttonsY) end
                prev = b
            end
        end
        y = buttonsY + M.btnH + pad
        if ctx.draft then
            self:SetHeight(y)
            return y
        end

        -- The caption band: right under the header, edge to edge inside the ring
        -- (it never reaches the card's corners, so it is square), the header-strip
        -- shade. The captions sit centred in it at their columns' x.
        local cols = UFO.LinkCardLayout(width, m)
        self.mode = cols.mode
        self.headLine:ClearAllPoints()
        self.headLine:SetPoint("TOPLEFT", self, "TOPLEFT", 1, -y)
        self.headLine:SetPoint("TOPRIGHT", self, "TOPRIGHT", -1, -y)
        self.capBand:ClearAllPoints()
        self.capBand:SetPoint("TOPLEFT", self, "TOPLEFT", 1, -(y + 1))
        self.capBand:SetPoint("TOPRIGHT", self, "TOPRIGHT", -1, -(y + 1))
        self.capBand:SetHeight(M.capBand)
        local capY = y + 1 + M.capBand / 2
        for _, fs in ipairs({ self.capPart, self.capPos, self.capLook, self.capResult }) do fs:ClearAllPoints() end
        self.capPos:SetPoint("LEFT", self, "TOPLEFT", cols.pos, -capY)
        self.capLook:SetPoint("LEFT", self, "TOPLEFT", cols.look, -capY)
        if cols.mode == "wide" then
            self.capPart:SetPoint("LEFT", self, "TOPLEFT", cols.name, -capY)
            self.capResult:SetPoint("LEFT", self, "TOPLEFT", cols.result, -capY)
            self.capPart:Show(); self.capResult:Show()
        else
            -- Stacked: one caption line, aligned to the segments on each row's
            -- second line; "Part" and "Result" need no caption there.
            self.capPart:Hide(); self.capResult:Hide()
        end
        y = y + 1 + M.capBand
        self.bandLine:ClearAllPoints()
        self.bandLine:SetPoint("TOPLEFT", self, "TOPLEFT", 1, -y)
        self.bandLine:SetPoint("TOPRIGHT", self, "TOPRIGHT", -1, -y)

        local function Group(fs, sub)
            y = y + M.headingGap
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", self, "TOPLEFT", pad, -y)
            y = y + 18
            if sub then
                sub:ClearAllPoints()
                local h = WrappedH(sub, width - 2 * pad)
                sub:SetPoint("TOPLEFT", self, "TOPLEFT", pad, -y)
                y = y + h + 4
            end
        end
        self.groupLinked:SetShown(self.hasLinkedGroup)
        self.groupSeparate:SetShown(self.hasSeparateGroup)
        self.groupSeparateSub:SetShown(self.hasSeparateGroup)
        for i, r in ipairs(self.rows) do
            local first = false
            if i == 1 and self.hasLinkedGroup then Group(self.groupLinked); first = true end
            if i == self.firstSeparate then Group(self.groupSeparate, self.groupSeparateSub); first = true end
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", self, "TOPLEFT", 0, -y)
            y = y + r:Layout(cols, width, first)
        end
        y = y + 8
        self.footLine:ClearAllPoints()
        self.footLine:SetPoint("TOPLEFT", self, "TOPLEFT", 1, -y)
        self.footLine:SetPoint("TOPRIGHT", self, "TOPRIGHT", -1, -y)
        y = y + 12
        self.footIcon:ClearAllPoints()
        self.footIcon:SetPoint("TOPLEFT", self, "TOPLEFT", pad, -(y + 1))
        self.foot:ClearAllPoints()
        local fh = WrappedH(self.foot, width - 2 * pad - 18)
        self.foot:SetPoint("TOPLEFT", self, "TOPLEFT", pad + 18, -y)
        y = y + fh + pad
        self:SetHeight(y)
        return y
    end

    card:Refresh()
    return card
end

-- ============================================================
-- THE PAGE'S HEAD AND THE THREE EXPLAINERS
-- ============================================================
local function HeadBlock(parent)
    local f = CreateFrame("Frame", nil, parent)
    f.title = Label(f, L["Linked Frames"], 16, C("text"))
    f.intro = Label(f, L["Link two frames so that changing one also changes the other. For each part of the frame, choose what the two frames share."],
        12, C("textDim"), true)
    f.add = Button(f, L["Link Two Frames"], { primary = true, width = 140,
        icon = { texture = ICONS .. "add.png", size = 14 } })
    f.add:SetScript("OnClick", function() UFO.StartLinkDraft() end)
    TipButton(f, f.add, { title = L["Link Two Frames"],
        lines = { L["Pick two frames to link, like Focus and Target. A frame can be linked to one other frame at a time."] } })
    function f:Layout(width)
        self:SetWidth(width)
        local tw, bw = TextW(self.title, 9), self.add:GetWidth() or 140
        self.title:ClearAllPoints(); self.add:ClearAllPoints(); self.intro:ClearAllPoints()
        self.title:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0)
        local y = 24
        if tw + M.gap + bw <= width then
            self.add:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, 0)
        else
            self.add:SetPoint("TOPLEFT", self, "TOPLEFT", 0, -y)
            y = y + M.btnH + 8
        end
        local ih = WrappedH(self.intro, width)
        self.intro:SetPoint("TOPLEFT", self, "TOPLEFT", 0, -y)
        y = y + ih
        self:SetHeight(y)
        return y
    end
    return f
end

local function Tile(parent, iconPath, rotate, tint, title, body, tip)
    local t = CreateFrame("Frame", nil, parent)
    CardSurface(t)
    t.icon = t:CreateTexture(nil, "OVERLAY")
    t.icon:SetTexture(iconPath)
    t.icon:SetSize(22, 22)
    if rotate and t.icon.SetRotation then t.icon:SetRotation(rotate) end
    t.icon:SetVertexColor(tint.r, tint.g, tint.b)
    t.title = Label(t, title, 13, C("text"))
    t.body = Label(t, body, 11, C("textDim"), true)
    if t.SetMouseMotionEnabled then t:SetMouseMotionEnabled(true) end
    if t.SetMouseClickEnabled then t:SetMouseClickEnabled(false) end
    t:SetScript("OnEnter", function(self) GUI:ShowTooltip(self, tip) end)
    t:SetScript("OnLeave", function() GUI:HideTooltip() end)
    function t:Layout(width)
        self:SetWidth(width)
        self.icon:ClearAllPoints(); self.title:ClearAllPoints(); self.body:ClearAllPoints()
        self.icon:SetPoint("TOPLEFT", self, "TOPLEFT", 12, -12)
        self.title:SetPoint("TOPLEFT", self, "TOPLEFT", 46, -12)
        local bh = WrappedH(self.body, width - 46 - 12)
        self.body:SetPoint("TOPLEFT", self, "TOPLEFT", 46, -30)
        local h = max(12 + 22 + 12, 30 + bh + 12)
        return h
    end
    return t
end

local function TilesBlock(parent)
    local f = CreateFrame("Frame", nil, parent)
    local acc, dim = Accent(), C("textDim")
    f.tiles = {
        Tile(f, UFO.LINK_ICON, nil, acc, L["Same"], L["Both frames match. Change either one and the other follows."],
            { title = L["Same"], lines = { L["The setting is shared. Editing it on either frame changes both."] } }),
        Tile(f, ICONS .. "swap_vert.png", math.pi / 2, acc, L["Mirrored"], L["Shared, but flipped left to right, so the frames face each other."],
            { title = L["Mirrored"], lines = { L["A portrait on one frame's left sits on the other frame's right. Buffs growing right grow left. Up and down never flip, and shadows keep their direction."],
                { text = L["Only for position and direction."], accent = true } } }),
        Tile(f, ICONS .. "sync_disabled.png", nil, dim, L["Separate"], L["Not linked. Each frame keeps its own setting."],
            { title = L["Separate"], lines = { L["Changes stay on the frame you edit. Use it when one part should differ, like buffs in a different spot on Target."] } }),
    }
    function f:Layout(width)
        self:SetWidth(width)
        local cols = (width >= 3 * M.tileMin + 2 * M.tileGap) and 3 or 1
        local tw = (cols == 3) and floor((width - 2 * M.tileGap) / 3) or width
        local y, rowH = 0, 0
        for i, t in ipairs(self.tiles) do
            local h = t:Layout(tw)
            if cols == 3 then rowH = max(rowH, h) end
            t.h = h
        end
        for i, t in ipairs(self.tiles) do
            t:ClearAllPoints()
            if cols == 3 then
                t:SetPoint("TOPLEFT", self, "TOPLEFT", (i - 1) * (tw + M.tileGap), 0)
                t:SetHeight(rowH)
            else
                t:SetPoint("TOPLEFT", self, "TOPLEFT", 0, -y)
                t:SetHeight(t.h)
                y = y + t.h + M.tileGap
            end
        end
        local h = (cols == 3) and rowH or (y - M.tileGap)
        self:SetHeight(h)
        return h
    end
    return f
end

-- ============================================================
-- MEASURING (what the narrow layout needs, from the real widgets)
-- ============================================================
local function Measure(probeParent)
    local m = UFO.LinkDefaultMeasures()
    local probe = Label(probeParent, "", SEG_FONT, C("text"))
    local function W(text, size)
        if size then GUI:SetSettingsFont(probe, size, "") end
        probe:SetText(text)
        local w = probe.GetStringWidth and probe:GetStringWidth() or 0
        return w
    end
    local segText = 0
    for _, s in ipairs({ L["Same"], L["Mirrored"], L["Separate"] }) do segText = max(segText, W(s, SEG_FONT)) end
    if segText > 0 then m.segW = max(M.segMin, ceil(segText) + 16) end
    m.posW, m.lookW = UFO.SegTrackWidth(3, m.segW), UFO.SegTrackWidth(2, m.segW)
    local nameText = 0
    local lk = Lk()
    for _, e in ipairs(lk and lk.ELEMENTS or {}) do nameText = max(nameText, W(L[e.title], 12)) end
    if nameText > 0 then m.nameW = min(M.nameMax, max(M.nameMin, ceil(nameText) + 24)) end
    local lw = W(L["linked with"], 11)
    if lw > 0 then m.pickersW = 2 * M.ddW + 8 + 14 + 4 + ceil(lw) + 8 end
    local sw = W(format(L["%d of %d parts linked"], 22, 22), 11)
    if sw > 0 then m.summaryW = ceil(sw) end
    local tw = W(L["Linked Frames"], 16)
    if tw > 0 then m.headW = ceil(tw) end
    probe:Hide()
    return m
end

-- The buttons' real widths (StyleButton's fitText grows a long translation).
local function MeasureButtons(card, m)
    if not card or #card.buttons == 0 then return end
    local w = 0
    for i, b in ipairs(card.buttons) do w = w + (b:GetWidth() or 0) + (i > 1 and M.btnGap or 0) end
    if w > 0 then m.buttonsW = ceil(w) end
end

-- ============================================================
-- THE PAGE
-- ============================================================
function UFO.StartLinkDraft()
    local lk, root = Lk(), Root()
    local free = {}
    for _, u in ipairs(UFO.UNITS) do
        if not (lk and root and lk:Partner(root, u)) then free[#free + 1] = u end
    end
    UFO.linkDraft = { leader = free[1] or "player", follower = free[2] or "target" }
    if UFO.linkDraft.leader == UFO.linkDraft.follower then UFO.linkDraft.follower = "target" end
    AfterLinks()
end

-- Every link, leader first, in unit order.
function UFO.AllLinks()
    local lk, root = Lk(), Root()
    local out = {}
    local t = root and root.global and root.global.unitLinks
    if type(t) ~= "table" then return out end
    for _, u in ipairs(UFO.UNITS) do
        local link = t[u]
        if type(link) == "table" and UFO.IsUnit(link.to) then
            out[#out + 1] = { follower = u, leader = link.to }
        end
    end
    return out
end

-- A page block: something with Layout(width) -> height, laid out by its own
-- refreshContent at the width the page pass will give it, so its layoutHeight is
-- right before the pass places it.
local function Block(w, Add)
    w.refreshContent = function(self)
        local h = self:Layout(UFO.LinksPageWidth())
        self.layoutHeight = h + M.blockGap
    end
    w:refreshContent()
    return Add(w, w.layoutHeight, "both")
end

function UFO.BuildLinksPage(self, db, Add)
    -- No setting on this page is a search target of its own: the page is found
    -- by its name, and dozens of anonymous segment entries would only be noise.
    local Search = DF.Search
    local held = Search and Search.SuppressRegistration
    if Search then Search.SuppressRegistration = true end

    local m = Measure(self.child)
    UFO.linkMeasured = m
    Block(HeadBlock(self.child), Add)
    Block(TilesBlock(self.child), Add)
    local cards = {}
    if UFO.linkDraft then
        local d = UFO.linkDraft
        local card = UFO.CreateLinkCard(self.child, d.follower, d.leader, m, true)
        MeasureButtons(card, m)
        Block(card, Add)
    end
    local links = UFO.AllLinks()
    for _, l in ipairs(links) do
        local card = UFO.CreateLinkCard(self.child, l.follower, l.leader, m, false)
        MeasureButtons(card, m)
        cards[#cards + 1] = card
        card.dfLinkCard = true
        Block(card, Add)
    end
    if #links == 0 and not UFO.linkDraft then
        local note = CreateFrame("Frame", nil, self.child)
        note.text = Label(note, L["No frames are linked. Use Link Two Frames to link two."], 12, C("textDim"), true)
        note.text:SetPoint("TOPLEFT", note, "TOPLEFT", 0, 0)
        function note:Layout(width) self:SetWidth(width); local h = WrappedH(self.text, width); self:SetHeight(h); return h end
        Block(note, Add)
    end
    -- Each card repaints its rows on every state pass (a part changed elsewhere).
    for _, card in ipairs(cards) do
        local layoutFn = card.refreshContent
        card.refreshContent = function(c, d) c:Refresh(); layoutFn(c, d) end
    end
    UFO.linkCards = cards

    if Search then Search.SuppressRegistration = held end

    -- The window can now take the measured minimum, if it is bigger than the
    -- estimate the page was opened at.
    -- Next frame, so the window never resizes in the middle of this build.
    if GUI.ApplyPageWidthBounds and C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            if GUI.CurrentPageName == UFO.LINKS_PAGE then GUI.ApplyPageWidthBounds(UFO.LINKS_PAGE) end
        end)
    end
end

-- Registered from UFO.BuildPages (Pages.lua), right below the module Settings page.
function UFO.RegisterLinksPage(CreateSubTab, BuildPage)
    local UF = DF.UnitFrames
    local pg = CreateSubTab("uf_module", UFO.LINKS_PAGE, L["Linked Frames"])
    if not pg then return nil end
    pg.buildKey = function() return "uf:links" end
    pg.buildDb = function() return UF and UF:GetGlobalDB() end
    pg.searchTabLabel = format("%s%s%s", L["Unit Frames"], " \194\183 ", L["Linked Frames"])
    GUI:SetPageModule(UFO.LINKS_PAGE, UFO.MODULE)
    UFO.pageMeta[UFO.LINKS_PAGE] = { kind = "links" }
    GUI.PageMinWidths = GUI.PageMinWidths or {}
    GUI.PageMinWidths[UFO.LINKS_PAGE] = function() return UFO.LinksMinWindowWidth() end
    BuildPage(pg, function(self, db, Add) UFO.BuildLinksPage(self, db, Add) end)
    return pg
end
