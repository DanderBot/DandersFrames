-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's. Take the parent's table from the global it publishes. See the
-- same note at the head of GUI/Panel.lua and GUI/ModuleRegistry.lua.
local DF = DandersFrames
local GUI = DF.GUI
local L = DF.L

local ipairs, pairs, type, pcall, tostring = ipairs, pairs, type, pcall, tostring
local format, floor, max = string.format, math.floor, math.max
local concat = table.concat
local CreateFrame = CreateFrame

-- ============================================================
-- THE HOME PAGE
-- The `home` rail item (GUI/ModuleRegistry.lua). Top to bottom:
--   * a greeting, the current profile (a link to Profiles) and the active
--     Auto Layout;
--   * a large search box driving the EXISTING settings search -- same index,
--     same results panel, same navigation. While Home shows, the results
--     panel is hosted under this box (see HOSTING THE SEARCH below);
--   * "Your modules": a tile per module that is on, the rest folded into one
--     "N more" tile that opens the Modules page;
--   * Needs attention (filled by Phase 3's DF.Attention, or
--     GUI:SetHomeAttentionItems) and What's new (the newest changelog section,
--     through the changelog overlay's own parser), side by side when there is
--     room, stacked when there is not.
--
-- ☠ ITS OWN FILE ON PURPOSE: DF:CreateGUI (GUI/Panel.lua) sits near Lua's
-- 200-locals-per-function limit. The pure parts (Home.TileModel,
-- Home.WhatsNew, Home.AttentionItems) are on GUI.Home for the headless tests.
-- ============================================================

local Home = {}
GUI.Home = Home

-- ============================================================
-- PURE: YOUR MODULES
-- on: every module that is ON (GUI:IsModuleOn); more: the rest, folded into
-- the "N more" tile. Home, Modules and Profiles are never tiles (noTile).
-- ============================================================
function Home.TileModel()
    local on, more = {}, {}
    for _, def in ipairs(GUI:GetModules()) do
        if not def.noTile then
            if GUI:IsModuleOn(def) then on[#on + 1] = def else more[#more + 1] = def end
        end
    end
    return on, more, #on + #more
end

-- ============================================================
-- PURE: WHAT'S NEW
-- The changelog has no tag convention of its own, so the tag comes from the
-- section an entry sits under (### New Features / Improvements / Changes /
-- Bug Fixes), else from its leading word, else IMPROVED.
-- ============================================================
function Home.TagFor(sectionName, text)
    local s = type(sectionName) == "string" and sectionName:lower() or ""
    if s:find("fix", 1, true) then return "FIX" end
    if s:find("new", 1, true) or s:find("feature", 1, true) or s:find("add", 1, true) then return "NEW" end
    if s:find("improve", 1, true) or s:find("change", 1, true) or s:find("update", 1, true)
        or s:find("performance", 1, true) then
        return "IMPROVED"
    end
    local word = type(text) == "string" and text:match("^[%s%*]*(%a+)") or nil
    word = word and word:lower() or ""
    if word == "fix" or word == "fixed" or word == "fixes" then return "FIX" end
    if word == "new" or word == "add" or word == "added" or word == "adds" then return "NEW" end
    return "IMPROVED"
end

-- The text a changelog line shows on Home: markdown emphasis stripped, then
-- its first sentence.
function Home.FirstSentence(text)
    if type(text) ~= "string" then return "" end
    local t = text:gsub("%*%*", ""):gsub("`", "")
    t = t:gsub("^%s+", ""):gsub("%s+$", "")
    local first = t:match("^(.-[%.!%?])%s")
    return first or t
end

local function VersionBase(v)
    return (tostring(v or ""):gsub("^v", "")):match("^(%d+%.%d+%.%d+)")
end

local function HasEntries(v)
    for _, sec in ipairs(v.sections or {}) do
        if sec.entries and #sec.entries > 0 then return true end
    end
    return false
end

-- versions: the changelog overlay's parse (GUI.ParseChangelog). Picks the
-- section for the running version, else the newest one with entries (an
-- alpha's notes sit under [Unreleased], which is named after the running
-- version). Returns { version, entries = { {tag, title, text}, ... } } or nil.
function Home.WhatsNew(versions, currentVersion, maxEntries)
    if type(versions) ~= "table" then return nil end
    maxEntries = maxEntries or 5
    local cur = VersionBase(currentVersion)
    local pick
    if cur then
        for _, v in ipairs(versions) do
            if VersionBase(v.version) == cur and HasEntries(v) then pick = v; break end
        end
    end
    if not pick then
        for _, v in ipairs(versions) do
            if HasEntries(v) then pick = v; break end
        end
    end
    if not pick then return nil end
    local out = { version = VersionBase(pick.version) or cur or pick.version, entries = {} }
    for _, sec in ipairs(pick.sections or {}) do
        for _, e in ipairs(sec.entries or {}) do
            if #out.entries >= maxEntries then return out end
            out.entries[#out.entries + 1] = {
                tag = Home.TagFor(sec.name, e.text),
                title = e.category,
                text = Home.FirstSentence(e.text),
            }
        end
    end
    return out
end

local TAG_LABEL = {
    NEW = function() return L["NEW"] end,
    IMPROVED = function() return L["IMPROVED"] end,
    FIX = function() return L["FIX"] end,
}

-- ============================================================
-- PURE: NEEDS ATTENTION
-- The resident registry (DandersFrames/Features/Attention.lua) answers
-- DF.Attention:GetActive(useCache) with items
-- { id, severity (1 conflict, 2 setup, 3 info), title, detail,
--   fix = { label, run | page, combatSafe }, dismiss }, sorted. A caller that
-- wants to show its own list uses GUI:SetHomeAttentionItems(list) (nil hands
-- back to DF.Attention). At most 4 show.
--
-- WHEN IT IS EVALUATED: the window opening (GUI:ModuleToOpen calls
-- GUI:EvaluateAttention), Home showing, and after a fix or a dismiss. Every
-- other re-layout (a resize step) reads the cached list. Never on a timer.
-- ============================================================
local MAX_ATTENTION = 4
local BADGE_SEVERITY = 2  -- the rail badge counts conflicts and setup items

function GUI:SetHomeAttentionItems(list)
    GUI._homeAttention = list
    if GUI.RefreshHomeView then GUI:RefreshHomeView() end
end

function Home.AttentionItems(useCache)
    local list = GUI._homeAttention
    if list == nil then
        local A = DF.Attention
        if A and A.GetActive then
            local ok, res = pcall(A.GetActive, A, useCache)
            if ok then list = res end
        end
    end
    local out = {}
    if type(list) ~= "table" then return out end
    for _, item in ipairs(list) do
        if #out >= MAX_ATTENTION then break end
        if type(item) == "table" then out[#out + 1] = item end
    end
    return out
end

-- How many items the Home rail item's badge counts (severity 1-2), from the
-- list as last evaluated -- the badge never runs the checks itself.
function Home.BadgeCount()
    local n = 0
    for _, item in ipairs(Home.AttentionItems(true)) do
        if type(item.severity) == "number" and item.severity <= BADGE_SEVERITY then n = n + 1 end
    end
    return n
end

-- Run the checks now and repaint the badge. The window's open path and Home
-- call this; nothing else should need to.
function GUI:EvaluateAttention()
    local items = Home.AttentionItems(false)
    if GUI.RefreshRailBadges then GUI:RefreshRailBadges() end
    return items
end

-- Q3's rule, for GUI:ModuleToOpen (GUI/Rail.lua): a conflict-level item opens
-- the window on Home. Reads the list as last evaluated (the open path
-- evaluates first).
function GUI:HomeHasConflict()
    for _, item in ipairs(Home.AttentionItems(true)) do
        if item.severity == 1 then return true end
    end
    return false
end

-- A fix or a dismiss changed something: re-run the checks, repaint.
local function AfterAttentionChange()
    GUI:EvaluateAttention()
    if GUI.RefreshHomeView then GUI:RefreshHomeView() end
end
Home.AfterAttentionChange = AfterAttentionChange

-- ============================================================
-- THE VIEW
-- Drawn to the approved mockup (docs/superpowers/specs/2026-10-30-settings-
-- nav-options.html, homeLaunch) at the live window's scale, 1 CSS px = 1 UI
-- unit. Every curved corner is the kit's rounded surface (DandersUI/Round.lua,
-- radii 4 / 6 / 8 -- the only ones baked); colours are GUI.Colors and the
-- module accents, never literals.
--
-- ⚠ BESPOKE ON PURPOSE: the tiles, panels and rows are pooled list pieces with
-- an icon box, two lines and a control -- no shared widget has that shape. Their
-- parts are the shared ones: CreateRoundedSurface, StyleButton,
-- CreateCloseButton, CreateLink, SetSettingsFont.
-- ============================================================

local MAX_W = 900         -- the content column, centred
local GAP = 14            -- between the blocks
local TILE_GAP, TILE_MIN = 8, 200
local TILE_PAD_X, TILE_PAD_Y = 12, 10
local ICON_BOX, ICON_GLYPH = 36, 20
local TILE_H = ICON_BOX + TILE_PAD_Y * 2
local PANEL_MIN = 640     -- below this content width the two panels stack
local PAD = 14            -- inside a panel
local ROW_GAP = 10        -- between a panel's rows
local NEWS_GAP = 11       -- between What's new lines
local TAG_W, TAG_H = 62, 16
local FIX_W = 90          -- room kept for an attention row's button
local HELLO_Y = 4
local SEARCH_Y = 62       -- greeting (18) + the profile line (12) + the gap
local SEARCH_H = 52
local TOP = SEARCH_Y + SEARCH_H + GAP   -- above the scroll

local ICONS = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"

local C = GUI.Colors
local view
local W = {}
local tiles = {}
local links = {}          -- slot -> { [text] = link frame }

local function Tint(fs, c, a)
    fs:SetTextColor(c.r, c.g, c.b, a or 1)
end

local function RGBA(c, a)
    return { c.r, c.g, c.b, a or 1 }
end

local function Hex(c)
    return format("|cff%02x%02x%02x", floor(c.r * 255 + 0.5), floor(c.g * 255 + 0.5), floor(c.b * 255 + 0.5))
end

-- A sized label in the settings font.
local function Label(parent, size, color, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", "DFFontHighlight")
    GUI:SetSettingsFont(fs, size)
    fs:SetJustifyH("LEFT")
    Tint(fs, color or C.text)
    return fs
end

-- A module's accent, resolved (a def's accent may be a function).
local function ModAccent(def)
    local a = def and def.accent
    if type(a) == "function" then a = a() end
    return a or GUI:GetAccent()
end

-- GUI:CreateLink is fixed-layout (it flows once), so a line whose text changes
-- is a new link; each distinct text is built once and kept.
local function LinkFor(slot, parent, text, onClick, width)
    local cache = links[slot]
    if not cache then cache = {}; links[slot] = cache end
    for _, f in pairs(cache) do f:Hide() end
    local f = cache[text]
    if not f then
        f = GUI:CreateLink(parent, text, { width = width, onLinkClick = onClick, padTop = 0, padBottom = 0,
                                           fontTemplate = "DFFontHighlight", lineHeight = 16 })
        cache[text] = f
    end
    f:Show()
    return f
end

local function LinkMarkup(data, text)
    -- The |cffffffff is CreateLink's parser placeholder; it tints the link itself.
    return format("|cffffffff|H%s|h%s|h|r", data, (tostring(text or ""):gsub("|", "")))
end

-- A link that is ONLY a link, shrunk to its own width so it can be pinned by
-- its right edge (the mockup's right-aligned "Manage modules" / "Full
-- changelog"). CreateLink's one link segment is its frame's one child.
local function ShrinkLink(f)
    local btn = f:GetChildren()
    local w = btn and btn.GetWidth and btn:GetWidth() or 0
    if w > 0 then f:SetWidth(w) end
    return f
end

-- ---- tiles ------------------------------------------------------------
-- A tile is a Button on a rounded panel surface: a 36px rounded icon box in
-- the module's accent (18% fill, the glyph full strength), the name and a
-- one-line status, a dim chevron. Hover lights the border and the chevron in
-- the accent.
local function PaintTileRest(t)
    local b = C.border
    if t.isMore then
        local d = C.textDim
        t.surface:SetBorderColor(d.r, d.g, d.b, t.hover and 0.8 or 0.35)
    elseif t.hover and t.accent then
        local a = t.accent
        t.surface:SetBorderColor(a.r, a.g, a.b, 1)
    else
        t.surface:SetBorderColor(b.r, b.g, b.b, 0.7)
    end
    local cc = (t.hover and t.accent and not t.isMore) and t.accent or C.textDim
    t.Chevron:SetVertexColor(cc.r, cc.g, cc.b)
end

local function MakeTile()
    local t = CreateFrame("Button", nil, view.body)
    t:SetSize(TILE_MIN, TILE_H)
    t.surface = GUI:CreateRoundedSurface(t, { radius = 6, fill = RGBA(C.panel, 1), border = RGBA(C.border, 0.7) })

    local box = CreateFrame("Frame", nil, t)
    box:SetSize(ICON_BOX, ICON_BOX)
    box:SetPoint("LEFT", t, "LEFT", TILE_PAD_X, 0)
    t.boxSurface = GUI:CreateRoundedSurface(box, { radius = 8, border = false, fill = RGBA(C.text, 0.05) })
    local icon = box:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON_GLYPH, ICON_GLYPH)
    icon:SetPoint("CENTER", box, "CENTER", 0, 0)
    t.TileIcon = icon

    local chev = t:CreateTexture(nil, "ARTWORK")
    chev:SetSize(18, 18)
    chev:SetPoint("RIGHT", t, "RIGHT", -10, 0)
    chev:SetTexture(ICONS .. "chevron_right.png")
    t.Chevron = chev

    local name = Label(t, 13, C.text)
    name:SetPoint("BOTTOMLEFT", box, "RIGHT", 12, 1)
    name:SetPoint("RIGHT", chev, "LEFT", -6, 0)
    name:SetWordWrap(false)
    t.TileName = name
    local status = Label(t, 11, C.textDim)
    status:SetPoint("TOPLEFT", box, "RIGHT", 12, -2)
    status:SetPoint("RIGHT", chev, "LEFT", -6, 0)
    status:SetWordWrap(false)
    t.TileStatus = status

    t:SetScript("OnEnter", function(self) self.hover = true; PaintTileRest(self) end)
    t:SetScript("OnLeave", function(self) self.hover = false; PaintTileRest(self) end)
    t:SetScript("OnClick", function(self)
        -- A locked module (Auto Layout editing) is refused, as on the rail.
        if self.target and not GUI:IsModulePickLocked(self.target) then
            GUI:SelectModule(self.target)
        end
    end)
    return t
end

local function PaintModuleTile(t, def)
    local a = ModAccent(def)
    t.isMore, t.accent = false, a
    t.target = def.id
    t.surface:SetFillShown(true)
    t.surface:SetFillColor(C.panel.r, C.panel.g, C.panel.b, 1)
    t.boxSurface:SetFillColor(a.r, a.g, a.b, 0.18)
    t.TileIcon:SetTexture(def.icon)
    t.TileIcon:SetVertexColor(a.r, a.g, a.b)
    t.Chevron:Show()
    -- Greyed and click-proof while the module is locked (Auto Layout editing),
    -- as its rail item is.
    local locked = GUI:IsModulePickLocked(def.id)
    t:SetEnabled(not locked)
    t:SetAlpha(locked and 0.4 or 1)
    t.TileName:SetText(GUI:ModuleLabel(def) or "")
    t.TileStatus:SetText(GUI:ModuleStatus(def))
    PaintTileRest(t)
end

-- Off and coming-soon modules, folded: opens the Modules page. No fill, a
-- faint border and a neutral "+" box. (The mockup's border is dashed; the kit
-- has no dashed surface, so it is a fainter solid one.)
local function PaintMoreTile(t, more)
    local names = {}
    for _, def in ipairs(more) do names[#names + 1] = GUI:ModuleLabel(def) or def.id end
    t.isMore, t.accent = true, nil
    t.target = "modules"
    t:SetEnabled(true)
    t:SetAlpha(1)
    t.surface:SetFillShown(false)
    t.boxSurface:SetFillColor(C.text.r, C.text.g, C.text.b, 0.05)
    t.TileIcon:SetTexture(ICONS .. "add.png")
    local cc = C.textCaption or C.textDim
    t.TileIcon:SetVertexColor(cc.r, cc.g, cc.b)
    t.Chevron:Hide()
    t.TileName:SetText(format(L["%d more"], #more))
    t.TileStatus:SetText(concat(names, " \194\183 "))
    PaintTileRest(t)
end

-- ---- panels -------------------------------------------------------------
local function MakePanel(iconName)
    local p = CreateFrame("Frame", nil, view.body)
    p.surface = GUI:CreateRoundedSurface(p, { radius = 8, fill = RGBA(C.panel, 1), border = RGBA(C.border, 0.7) })
    local icon = p:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, -PAD)
    icon:SetTexture(ICONS .. iconName .. ".png")
    p.Icon = icon
    local title = Label(p, 14, C.text)
    title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    p.Title = title
    -- The count pill (Needs attention): notice fill, dark text.
    local pill = CreateFrame("Frame", nil, p)
    pill:SetHeight(16)
    pill:SetPoint("LEFT", title, "RIGHT", 8, 0)
    pill.surface = GUI:CreateRoundedSurface(pill, { radius = 8, border = false, fill = RGBA(C.notice, 1) })
    local pt = Label(pill, 10, C.background)
    pt:SetPoint("CENTER", pill, "CENTER", 0, 0)
    pill.Text = pt
    pill:Hide()
    p.Pill = pill
    -- Right-aligned aside (What's new: the build, when it is not the section's).
    local aside = Label(p, 11, C.textDim)
    aside:SetPoint("RIGHT", p, "RIGHT", -PAD, 0)
    aside:SetPoint("TOP", icon, "TOP", 0, -4)
    aside:SetJustifyH("RIGHT")
    p.Aside = aside
    p.rows = {}
    return p
end

local function PaintPanelChrome(p)
    local a = GUI:GetAccent()
    p.Icon:SetVertexColor(a.r, a.g, a.b)
end

-- One wrapped text line inside a panel row; returns its height at `w`.
local function SetWrapped(fs, text, w)
    fs:SetWidth(w)
    fs:SetText(text or "")
    return (text and text ~= "") and (fs:GetStringHeight() or 14) or 0
end

-- A row: an optional rounded plate (attention items) or a tag pill (What's
-- new), a title and a detail line.
local function PanelRow(p, i)
    local r = p.rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, p)
    r.plate = GUI:CreateRoundedSurface(r, { radius = 4, fill = RGBA(C.text, 0.025), border = RGBA(C.border, 0.7) })
    -- The kind stripe: 3px, inside the ring and clear of the corner arcs.
    local stripe = r:CreateTexture(nil, "BORDER")
    stripe:SetWidth(3)
    stripe:SetPoint("TOPLEFT", r, "TOPLEFT", 1, -4)
    stripe:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 1, 4)
    r.Stripe = stripe
    local kind = r:CreateTexture(nil, "ARTWORK")
    kind:SetSize(20, 20)
    kind:SetPoint("LEFT", r, "LEFT", 10, 0)
    r.Kind = kind
    -- The tag pill (What's new).
    local tag = CreateFrame("Frame", nil, r)
    tag:SetSize(TAG_W, TAG_H)
    tag:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
    tag.surface = GUI:CreateRoundedSurface(tag, { radius = 4, border = false, fill = RGBA(C.text, 0.08) })
    local tt = Label(tag, 10, C.textDim)
    tt:SetPoint("CENTER", tag, "CENTER", 0, 0)
    tag.Text = tt
    r.Tag = tag
    local title = Label(r, 12, C.text)
    title:SetWordWrap(true)
    r.TitleFS = title
    local text = Label(r, 11, C.textDim)
    text:SetWordWrap(true)
    r.TextFS = text
    p.rows[i] = r
    return r
end

-- Fix button on an attention row, built on first need.
local function RowButton(r)
    if r.Fix then return r.Fix end
    local b = CreateFrame("Button", nil, r, "BackdropTemplate")
    GUI:StyleButton(b, { text = "", width = 80, height = 24 })
    b:SetScript("OnClick", function(self)
        local fix = self.fix
        if not fix then return end
        if InCombatLockdown() and not fix.combatSafe then return end
        if type(fix.run) == "function" then
            local ok, err = pcall(fix.run)
            if not ok and err then geterrorhandler()(err) end
        elseif fix.page then
            if GUI:GetModule(fix.page) then
                if not GUI:IsModulePickLocked(fix.page) then GUI:SelectModule(fix.page) end
            elseif GUI.LinkToSetting then
                GUI:LinkToSetting({ page = fix.page })
            end
        end
        -- A fix that reloads never gets here; one that opened a page has
        -- left Home, and the refresh below is a no-op then.
        AfterAttentionChange()
    end)
    r.Fix = b
    return b
end

-- The dismiss "x" on a dismissable attention row, built on first need.
local function RowDismiss(r)
    if r.Dismiss then return r.Dismiss end
    local b = GUI:CreateCloseButton(r, {
        size = 16,
        tooltip = L["Dismiss"],
        onClick = function(self)
            local A = DF.Attention
            if self.itemId and A and A.Dismiss then A:Dismiss(self.itemId) end
            AfterAttentionChange()
        end,
    })
    b:SetPoint("RIGHT", r, "RIGHT", -8, 0)
    r.Dismiss = b
    return b
end

-- Severity 1-2 (a conflict, a setup step) read as a warning in the notice
-- amber; 3 (info) in GLOBAL's teal.
local function KindFor(item)
    if type(item.severity) == "number" and item.severity <= BADGE_SEVERITY then
        return C.notice or C.text, ICONS .. "warning.png"
    end
    return GUI.GlobalAccent or C.text, ICONS .. "info.png"
end

local HEAD_H = 20         -- a panel's header row (the 20px icon)

-- Lay a panel out at width pw; returns its height.
local function LayoutAttention(p, pw)
    local items = Home.AttentionItems(true)
    if p.Title then p.Title:SetText(L["Needs attention"]) end
    if p.Pill then
        p.Pill:SetShown(#items > 0)
        if #items > 0 then
            p.Pill.Text:SetText(tostring(#items))
            p.Pill:SetWidth(max(16, (p.Pill.Text:GetStringWidth() or 6) + 10))
        end
    end
    if p.Aside then p.Aside:SetText("") end
    local inner = pw - PAD * 2
    local y = PAD + HEAD_H + ROW_GAP
    for _, r in ipairs(p.rows) do r:Hide() end
    if #items == 0 then
        local r = PanelRow(p, 1)
        r.plate:Hide()
        r.Stripe:Hide()
        r.Kind:Hide()
        r.Tag:Hide()
        r.TitleFS:ClearAllPoints()
        r.TitleFS:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
        local h = SetWrapped(r.TitleFS, L["All good. Nothing needs your attention."], inner)
        Tint(r.TitleFS, C.textDim)
        r.TextFS:SetText("")
        if r.Fix then r.Fix:Hide() end
        if r.Dismiss then r.Dismiss:Hide() end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, -y)
        r:SetSize(inner, h)
        r:Show()
        return y + h + PAD
    end
    local combat = InCombatLockdown()
    for i, item in ipairs(items) do
        local r = PanelRow(p, i)
        r.plate:Show()
        r.Tag:Hide()
        local kc, kicon = KindFor(item)
        r.Stripe:SetColorTexture(kc.r, kc.g, kc.b, 1)
        r.Stripe:Show()
        r.Kind:SetTexture(kicon)
        r.Kind:SetVertexColor(kc.r, kc.g, kc.b)
        r.Kind:Show()
        local fix = type(item.fix) == "table" and item.fix or nil
        local canDismiss = item.dismiss ~= nil and item.id ~= nil
        local rightW = (fix and FIX_W or 0) + (canDismiss and 24 or 0)
        local textX = 10 + 20 + 10
        local textW = inner - textX - 10 - rightW
        Tint(r.TitleFS, C.text)
        local h1 = SetWrapped(r.TitleFS, item.title, textW)
        local h2 = SetWrapped(r.TextFS, item.detail, textW)
        local textH = h1 + (h2 > 0 and h2 + 1 or 0)
        local h = max(textH, 24) + 18
        r.TitleFS:ClearAllPoints()
        r.TitleFS:SetPoint("TOPLEFT", r, "TOPLEFT", textX, -(9 + max(0, (max(textH, 24) - textH) / 2)))
        r.TextFS:ClearAllPoints()
        r.TextFS:SetPoint("TOPLEFT", r.TitleFS, "BOTTOMLEFT", 0, -1)
        if fix then
            local b = RowButton(r)
            b.fix = fix
            if b.Text then b.Text:SetText(fix.label or "") end
            b:SetEnabled(not (combat and not fix.combatSafe))
            b:ClearAllPoints()
            b:SetPoint("RIGHT", r, "RIGHT", canDismiss and -32 or -10, 0)
            b:Show()
        elseif r.Fix then
            r.Fix:Hide()
        end
        if canDismiss then
            local d = RowDismiss(r)
            d.itemId = item.id
            d:Show()
        elseif r.Dismiss then
            r.Dismiss:Hide()
        end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, -y)
        r:SetSize(inner, h)
        r:Show()
        y = y + h + 6
    end
    return y - 6 + PAD
end
Home.LayoutAttention = LayoutAttention   -- the headless tests drive it on a fake panel

-- The changelog text is fixed for the session and the parse walks all of it
-- (~180 KB), so it runs once -- not on every resize step.
local newsCache, newsParsed

local function WhatsNewData()
    if not newsParsed and GUI.ParseChangelog and DF.CHANGELOG_TEXT then
        newsParsed = true
        local ok, versions = pcall(GUI.ParseChangelog, DF.CHANGELOG_TEXT)
        if ok then newsCache = Home.WhatsNew(versions, DF.VERSION, 5) end
    end
    return newsCache
end

-- The tag pills: NEW in Binds' green, IMPROVED in GLOBAL's teal, FIX dim.
local function TagColors(tag)
    if tag == "NEW" then
        local g = GUI.ClicksAccent or GUI:GetAccent()
        return g, 0.25, g
    elseif tag == "IMPROVED" then
        local t = GUI.GlobalAccent or GUI:GetAccent()
        return t, 0.22, t
    end
    return C.text, 0.08, C.textDim
end

local function LayoutWhatsNew(p, pw)
    local inner = pw - PAD * 2
    local news = WhatsNewData()
    local shown = news and news.version or (VersionBase(DF.VERSION) or "")
    p.Title:SetText(format(L["What's new in %s"], shown))
    p.Pill:Hide()
    -- The build running, when it is not the section shown (an alpha).
    local running = tostring(DF.VERSION or "")
    p.Aside:SetText((running ~= "" and VersionBase(running) ~= running:gsub("^v", "")) and running or "")
    for _, r in ipairs(p.rows) do r:Hide() end
    local y = PAD + HEAD_H + ROW_GAP
    local entries = news and news.entries or {}
    for i, e in ipairs(entries) do
        local r = PanelRow(p, i)
        r.plate:Hide()
        r.Stripe:Hide()
        r.Kind:Hide()
        local tl = TAG_LABEL[e.tag]
        local fill, fa, ink = TagColors(e.tag)
        r.Tag.Text:SetText(tl and tl() or "")
        Tint(r.Tag.Text, ink)
        r.Tag.surface:SetFillColor(fill.r, fill.g, fill.b, fa)
        local tagW = max(TAG_W, (r.Tag.Text:GetStringWidth() or 0) + 12)
        r.Tag:SetWidth(tagW)
        r.Tag:Show()
        local textX = tagW + 10
        local textW = inner - textX
        r.TitleFS:ClearAllPoints()
        r.TitleFS:SetPoint("TOPLEFT", r, "TOPLEFT", textX, -1)
        Tint(r.TitleFS, C.text)
        local h1 = SetWrapped(r.TitleFS, e.title, textW)
        r.TextFS:ClearAllPoints()
        if h1 > 0 then
            r.TextFS:SetPoint("TOPLEFT", r.TitleFS, "BOTTOMLEFT", 0, -2)
        else
            r.TextFS:SetPoint("TOPLEFT", r, "TOPLEFT", textX, -1)
        end
        Tint(r.TextFS, C.textCaption or C.textDim)
        local h2 = SetWrapped(r.TextFS, e.text, textW)
        local h = max(h1 + (h1 > 0 and h2 > 0 and 2 or 0) + h2 + 1, TAG_H)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, -y)
        r:SetSize(inner, h)
        r:Show()
        y = y + h + NEWS_GAP
    end
    -- "Full changelog": the existing overlay, as it was.
    local link = ShrinkLink(LinkFor("changelog", p, LinkMarkup("dfChangelog", L["Full changelog"]),
        function() if GUI.ShowChangelog then GUI:ShowChangelog() end end, inner))
    link:ClearAllPoints()
    link:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, -y)
    return y + (link.layoutHeight or 16) + PAD
end

-- ---- the whole page ---------------------------------------------------------
-- x0 / cw: the centred content column (MAX_W at most).
local function PaintHeader(x0, cw)
    local name = UnitName and UnitName("player") or nil
    local cc = C.textCaption or C.text
    -- The name in the text colour on the caption-coloured line. The escape is
    -- outside L: the colour is ours, the words are the translator's.
    W.hello:SetText(name and format(L["Hello, %s"], Hex(C.text) .. name .. "|r") or L["Home"])
    Tint(W.hello, cc)
    W.hello:ClearAllPoints()
    W.hello:SetPoint("TOPLEFT", view, "TOPLEFT", x0, -HELLO_Y)

    local profile = DF.GetCurrentProfile and DF:GetCurrentProfile() or nil
    -- Profiles locked (an Auto Layout is being edited): the name is plain
    -- text, not a link, and a click does nothing.
    local locked = GUI:IsModulePickLocked("profiles", "profiles_manage")
    local shown = profile or L["Profiles"]
    local text = format(L["Profile: %s"], locked and (tostring(shown):gsub("|", "")) or LinkMarkup("dfProfiles", shown))
    local AP = DF.AutoProfilesUI
    local layout = AP and AP.IsLayoutActive and AP:IsLayoutActive()
        and AP.GetActiveLayoutName and AP:GetActiveLayoutName()
    if layout then
        text = text .. "  \194\183  " .. format(L["Layout: %s"], (tostring(layout):gsub("|", "")))
    end
    local link = LinkFor("profile", view, text, function()
        if GUI:IsModulePickLocked("profiles", "profiles_manage") then return end
        GUI:SelectModule("profiles", "profiles_manage")
    end, max(cw - 4, 200))
    link:ClearAllPoints()
    link:SetPoint("TOPLEFT", W.hello, "BOTTOMLEFT", 0, -6)

    if W.search then
        W.search:ClearAllPoints()
        W.search:SetPoint("TOPLEFT", view, "TOPLEFT", x0, -SEARCH_Y)
        W.search:SetSize(cw, SEARCH_H)
    end
end

function GUI:RefreshHomeView()
    if not (view and view:IsShown()) then return end
    local w = view.scroll:GetWidth() or 0
    if w < 50 then return end
    local body = view.body
    body:SetWidth(w)
    local cw = math.min(w, MAX_W)
    local x0 = floor((w - cw) / 2)
    PaintHeader(x0, cw)

    -- ---- Your modules ----
    local y = 0
    local on, more, total = Home.TileModel()
    W.secTitle:ClearAllPoints()
    W.secTitle:SetPoint("TOPLEFT", body, "TOPLEFT", x0, -(y + 2))
    -- Uppercase, as the mockup's section caption. string.upper only touches
    -- ASCII letters, so a translated title keeps its other characters.
    W.secTitle:SetText(string.upper(L["Your modules"]))
    W.secCount:SetText(format(L["%d of %d on"], #on, total))
    -- A real button, not a text link: turning modules on and off is easy to
    -- miss otherwise (author, 2026-10-31). Tinted so it reads as the way in.
    local mb = W.manageBtn
    if not mb then
        mb = CreateFrame("Button", nil, body, "BackdropTemplate")
        GUI:StyleButton(mb, {
            text = L["Manage modules"], height = 24, tinted = true,
            accent = GUI.Colors.text,
            icon = { texture = ICONS .. "extension.png", size = 16 },
        })
        mb:SetScript("OnClick", function()
            if not GUI:IsModulePickLocked("modules") then GUI:SelectModule("modules") end
        end)
        W.manageBtn = mb
    end
    mb:ClearAllPoints()
    mb:SetPoint("RIGHT", body, "TOPRIGHT", -(w - x0 - cw), -(y + 8))
    mb:Show()
    y = y + 24 + 8

    local list = {}
    for _, def in ipairs(on) do list[#list + 1] = { def = def } end
    if #more > 0 then list[#list + 1] = { more = more } end
    local cols = max(1, floor((cw + TILE_GAP) / (TILE_MIN + TILE_GAP)))
    local tileW = (cw - TILE_GAP * (cols - 1)) / cols
    for _, t in ipairs(tiles) do t:Hide() end
    for i, entry in ipairs(list) do
        local t = tiles[i]
        if not t then t = MakeTile(); tiles[i] = t end
        if entry.def then PaintModuleTile(t, entry.def) else PaintMoreTile(t, entry.more) end
        local col, row = (i - 1) % cols, floor((i - 1) / cols)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", body, "TOPLEFT", x0 + col * (tileW + TILE_GAP), -(y + row * (TILE_H + TILE_GAP)))
        t:SetSize(tileW, TILE_H)
        t:Show()
    end
    local tileRows = floor((#list + cols - 1) / cols)
    y = y + tileRows * (TILE_H + TILE_GAP) - TILE_GAP + GAP

    -- ---- Needs attention + What's new ----
    PaintPanelChrome(W.attention)
    PaintPanelChrome(W.news)
    local two = cw >= PANEL_MIN
    local pw = two and floor((cw - GAP) / 2) or cw
    local ha = LayoutAttention(W.attention, pw)
    local hn = LayoutWhatsNew(W.news, two and (cw - pw - GAP) or cw)
    W.attention:ClearAllPoints()
    W.news:ClearAllPoints()
    W.attention:SetPoint("TOPLEFT", body, "TOPLEFT", x0, -y)
    W.attention:SetSize(pw, ha)
    if two then
        W.news:SetPoint("TOPLEFT", body, "TOPLEFT", x0 + pw + GAP, -y)
        W.news:SetSize(cw - pw - GAP, hn)
        y = y + max(ha, hn)
    else
        y = y + ha + GAP
        W.news:SetPoint("TOPLEFT", body, "TOPLEFT", x0, -y)
        W.news:SetSize(cw, hn)
        y = y + hn
    end
    body:SetHeight(y + 8)
end

-- ============================================================
-- HOSTING THE SEARCH
-- Home's box is a second Search:CreateSearchBar; while Home shows it IS
-- Search.SearchBar (ShowResults re-reads the live query from it, a result
-- click clears it), and the one results panel is re-homed under it. Leaving
-- Home hands both back. The index, the cards and the navigation are the
-- search's own -- nothing here is a copy.
-- ============================================================

local function HostResults(host)
    local S = DF.Search
    local panel = S and S.ResultsPanel
    if not (panel and host) then return end
    if panel:IsShown() then S:HideResults() end
    panel._home = host
    -- Re-anchored now and parked again (hidden, out of the window's walk);
    -- the next ShowResults adopts it under `host`.
    panel._parked = nil
    panel:SetParent(host)
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
    panel:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, 0)
    if S._ParkResultsPanel then S:_ParkResultsPanel() end
end

local function AdoptSearch()
    local S = DF.Search
    if not (S and W.search) then return end
    local panel = S.ResultsPanel
    if panel and not W.searchHooked then
        W.searchHooked = true
        -- The page body makes way while results show under Home's box.
        panel:HookScript("OnShow", function(self)
            if self:GetParent() == W.resultsHost and view then view.scroll:Hide() end
        end)
        panel:HookScript("OnHide", function()
            if view then view.scroll:Show() end
        end)
    end
    W.adopted = true
    if S.SearchBar ~= W.search then W.sidebarSearch = S.SearchBar end
    -- A query left in the sidebar's box would read as still searching once
    -- its results are gone; clearing it also hides them (its OnTextChanged).
    local side = W.sidebarSearch and W.sidebarSearch.editbox
    if side and side:GetText() ~= "" then
        side:SetText("")
        side:ClearFocus()
    end
    S.SearchBar = W.search
    if panel then
        if not W.contentHome and panel._home ~= W.resultsHost then W.contentHome = panel._home end
        if panel._home ~= W.resultsHost then HostResults(W.resultsHost) end
    end
end

-- ⚠ Runs from every ShowNormalContent (GUI:HideModuleViews), so it must be a
-- no-op unless Home actually holds the search.
local function ReleaseSearch()
    local S = DF.Search
    if not (S and W.search and W.adopted) then return end
    W.adopted = nil
    -- Clearing the box hides any results (its own OnTextChanged).
    if W.search.editbox and W.search.editbox:GetText() ~= "" then
        W.search.editbox:SetText("")
    end
    W.search.editbox:ClearFocus()
    if S.SearchBar == W.search then S.SearchBar = W.sidebarSearch end
    local panel = S.ResultsPanel
    if panel and W.contentHome and panel._home == W.resultsHost then
        HostResults(W.contentHome)
    end
    if view then view.scroll:Show() end
end

-- ============================================================
-- BUILD / SHOW / HIDE
-- ============================================================
local function Build()
    view = GUI:CreateModuleView(TOP)
    if not view then return nil end

    -- 18px caption line, the player's name in the text colour (PaintHeader).
    W.hello = Label(view, 18, C.textCaption or C.text)

    local S = DF.Search
    if S and S.CreateSearchBar then
        -- CreateSearchBar makes the bar it builds THE bar; the sidebar's stays
        -- it until Home is shown (AdoptSearch). The mockup's big box: 52 tall,
        -- radius 8, a 24px glyph and 15px text (placed in PaintHeader).
        -- No key hint: the window has no search shortcut to name.
        local prev = S.SearchBar
        local bar = S:CreateSearchBar(view, { radius = 8, iconSize = 24, iconX = 16, fontSize = 15 })
        S.SearchBar = prev
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", view, "TOPLEFT", 0, -SEARCH_Y)
        bar:SetHeight(SEARCH_H)
        if bar.placeholder then bar.placeholder:SetText(L["Search every setting..."]) end
        W.search = bar
    end

    -- Where the results panel sits while Home shows: the body's rect.
    local host = CreateFrame("Frame", nil, view)
    host:SetPoint("TOPLEFT", view, "TOPLEFT", 0, -TOP)
    host:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", 0, 0)
    W.resultsHost = host

    -- "YOUR MODULES"  N of M on ...................... Manage modules
    W.secTitle = Label(view.body, 12, C.textCaption or C.text)
    W.secCount = Label(view.body, 11, C.textDim)
    W.secCount:SetPoint("BOTTOMLEFT", W.secTitle, "BOTTOMRIGHT", 8, 0)

    W.attention = MakePanel("notifications")
    W.news = MakePanel("auto_awesome")

    -- Fix buttons grey in combat and come back after it: repaint on the edges
    -- (the list itself is the cached one -- checks never run in combat).
    view:RegisterEvent("PLAYER_REGEN_DISABLED")
    view:RegisterEvent("PLAYER_REGEN_ENABLED")
    view:SetScript("OnEvent", function() GUI:RefreshHomeView() end)

    view:SetScript("OnSizeChanged", function()
        GUI:RefreshHomeView()
        -- Results are laid out against the panel's width too.
        local Sr = DF.Search
        if Sr and Sr.ResultsPanel and Sr.ResultsPanel:IsShown() and Sr.LayoutResults then
            Sr:LayoutResults()
        end
    end)
    return view
end

function GUI:ShowHomeView()
    if not view and not Build() then return end
    -- Binds leaves SelectedMode on "clicks", which the search index cannot be
    -- built for (every page reads DF.db[GUI.SelectedMode]). Home sits over the
    -- frame mode instead, as GUI:EnterView does on the way out of Binds.
    if GUI.SelectedMode == "clicks" then
        GUI.SelectedMode = GUI._lastFrameMode or "party"
        if GUI.CurrentAccent then GUI:SetAccent(GUI.CurrentAccent()) end
        if DF.Search and DF.Search.InvalidateRegistry then DF.Search:InvalidateRegistry() end
    end
    view:Show()
    AdoptSearch()
    -- Home showing is one of the moments the checks run.
    GUI:EvaluateAttention()
    GUI:RefreshHomeView()
end

function GUI:HideHomeView()
    if not view then return end
    ReleaseSearch()
    view:Hide()
end
