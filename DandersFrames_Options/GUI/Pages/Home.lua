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
-- ============================================================

local TOP = 92            -- greeting (two lines) + the search box, above the scroll
local GAP = 10
local TILE_H, TILE_MIN = 46, 200
local PANEL_MIN = 260     -- below two of these the panels stack
local PAD = 12            -- inside a panel
local TAG_W = 66

local C = GUI.Colors
local view
local W = {}
local tiles = {}
local links = {}          -- slot -> { [text] = link frame }

local function Tint(fs, c, a)
    fs:SetTextColor(c.r, c.g, c.b, a or 1)
end

-- GUI:CreateLink is fixed-layout (it flows once), so a line whose text changes
-- is a new link; each distinct text is built once and kept.
local function LinkFor(slot, parent, text, onClick, width)
    local cache = links[slot]
    if not cache then cache = {}; links[slot] = cache end
    for _, f in pairs(cache) do f:Hide() end
    local f = cache[text]
    if not f then
        f = GUI:CreateLink(parent, text, { width = width, onLinkClick = onClick, padTop = 0, padBottom = 0 })
        cache[text] = f
    end
    f:Show()
    return f
end

local function LinkMarkup(data, text)
    -- The |cffffffff is CreateLink's parser placeholder; it tints the link itself.
    return format("|cffffffff|H%s|h%s|h|r", data, (tostring(text or ""):gsub("|", "")))
end

-- ---- tiles ------------------------------------------------------------
-- A tile is a list button: bespoke content (icon, name, a status line) on the
-- shared StyleButton backdrop and hover wash.
local function MakeTile()
    local t = CreateFrame("Button", nil, view.body, "BackdropTemplate")
    t:SetSize(TILE_MIN, TILE_H)
    GUI:StyleButton(t, { height = TILE_H })
    local icon = t:CreateTexture(nil, "ARTWORK")
    icon:SetSize(22, 22)
    icon:SetPoint("LEFT", t, "LEFT", 12, 0)
    t.TileIcon = icon
    local name = t:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
    name:SetPoint("TOPLEFT", t, "TOPLEFT", 46, -8)
    name:SetPoint("RIGHT", t, "RIGHT", -10, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    t.TileName = name
    local status = t:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    status:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -3)
    status:SetPoint("RIGHT", t, "RIGHT", -10, 0)
    status:SetJustifyH("LEFT")
    status:SetWordWrap(false)
    Tint(status, C.textDim)
    t.TileStatus = status
    t:SetScript("OnClick", function(self)
        if self.target then GUI:SelectModule(self.target) end
    end)
    return t
end

-- ---- panels -------------------------------------------------------------
local function MakePanel()
    local p = CreateFrame("Frame", nil, view.body, "BackdropTemplate")
    GUI:CreatePanelBackdrop(p, { bgColor = C.panel, borderColor = C.border })
    local title = p:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    title:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, -PAD)
    title:SetJustifyH("LEFT")
    Tint(title, C.text)
    p.Title = title
    local aside = p:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    aside:SetPoint("LEFT", title, "RIGHT", 8, 0)
    Tint(aside, C.textDim)
    p.Aside = aside
    p.rows = {}
    return p
end

-- One wrapped text line inside a panel row; returns its height at `w`.
local function SetWrapped(fs, text, w)
    fs:SetWidth(w)
    fs:SetText(text or "")
    return (text and text ~= "") and (fs:GetStringHeight() or 14) or 0
end

local function PanelRow(p, i)
    local r = p.rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, p)
    local tag = r:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    tag:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
    tag:SetWidth(TAG_W)
    tag:SetJustifyH("LEFT")
    Tint(tag, C.textCaption or C.textDim)
    r.Tag = tag
    local title = r:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    title:SetJustifyH("LEFT")
    title:SetWordWrap(true)
    Tint(title, C.text)
    r.TitleFS = title
    local text = r:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    text:SetJustifyH("LEFT")
    text:SetWordWrap(true)
    Tint(text, C.textDim)
    r.TextFS = text
    p.rows[i] = r
    return r
end

-- Fix button on an attention row, built on first need.
local function RowButton(r)
    if r.Fix then return r.Fix end
    local b = CreateFrame("Button", nil, r, "BackdropTemplate")
    GUI:StyleButton(b, { text = "", width = 80, height = 22 })
    b:SetPoint("TOPRIGHT", r, "TOPRIGHT", 0, 0)
    b:SetScript("OnClick", function(self)
        local fix = self.fix
        if not fix then return end
        if InCombatLockdown() and not fix.combatSafe then return end
        if type(fix.run) == "function" then
            local ok, err = pcall(fix.run)
            if not ok and err then geterrorhandler()(err) end
        elseif fix.page then
            if GUI:GetModule(fix.page) then
                GUI:SelectModule(fix.page)
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
    b:SetPoint("TOPRIGHT", r, "TOPRIGHT", 0, 0)
    r.Dismiss = b
    return b
end

-- Lay a panel out at width pw; returns its height.
local function LayoutAttention(p, pw)
    local items = Home.AttentionItems(true)
    p.Title:SetText(L["Needs attention"])
    p.Aside:SetText(#items > 0 and tostring(#items) or "")
    local inner = pw - PAD * 2
    local y = PAD + 22
    for _, r in ipairs(p.rows) do r:Hide() end
    if #items == 0 then
        local r = PanelRow(p, 1)
        r.Tag:SetText("")
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
        r.Tag:SetText("")
        local fix = type(item.fix) == "table" and item.fix or nil
        local canDismiss = item.dismiss ~= nil and item.id ~= nil
        local rightW = (fix and 90 or 0) + (canDismiss and 22 or 0)
        local textW = inner - rightW
        r.TitleFS:ClearAllPoints()
        r.TitleFS:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
        Tint(r.TitleFS, C.text)
        local h1 = SetWrapped(r.TitleFS, item.title, textW)
        r.TextFS:ClearAllPoints()
        r.TextFS:SetPoint("TOPLEFT", r.TitleFS, "BOTTOMLEFT", 0, -2)
        local h2 = SetWrapped(r.TextFS, item.detail, textW)
        if fix then
            local b = RowButton(r)
            b.fix = fix
            if b.Text then b.Text:SetText(fix.label or "") end
            b:SetEnabled(not (combat and not fix.combatSafe))
            b:ClearAllPoints()
            b:SetPoint("TOPRIGHT", r, "TOPRIGHT", canDismiss and -22 or 0, 0)
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
        local h = max(h1 + (h2 > 0 and h2 + 2 or 0), fix and 22 or 0, canDismiss and 16 or 0)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, -y)
        r:SetSize(inner, h)
        r:Show()
        y = y + h + 10
    end
    return y - 10 + PAD
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

local function LayoutWhatsNew(p, pw)
    local inner = pw - PAD * 2
    local news = WhatsNewData()
    p.Title:SetText(format(L["What's new in %s"], news and news.version or (VersionBase(DF.VERSION) or "")))
    p.Aside:SetText("")
    for _, r in ipairs(p.rows) do r:Hide() end
    local y = PAD + 22
    local entries = news and news.entries or {}
    local textW = inner - TAG_W
    for i, e in ipairs(entries) do
        local r = PanelRow(p, i)
        local tl = TAG_LABEL[e.tag]
        r.Tag:SetText(tl and tl() or "")
        r.TitleFS:ClearAllPoints()
        r.TitleFS:SetPoint("TOPLEFT", r, "TOPLEFT", TAG_W, 0)
        Tint(r.TitleFS, C.text)
        local h1 = SetWrapped(r.TitleFS, e.title, textW)
        r.TextFS:ClearAllPoints()
        if h1 > 0 then
            r.TextFS:SetPoint("TOPLEFT", r.TitleFS, "BOTTOMLEFT", 0, -2)
        else
            r.TextFS:SetPoint("TOPLEFT", r, "TOPLEFT", TAG_W, 0)
        end
        local h2 = SetWrapped(r.TextFS, e.text, textW)
        local h = max(h1 + (h1 > 0 and h2 > 0 and 2 or 0) + h2, 14)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, -y)
        r:SetSize(inner, h)
        r:Show()
        y = y + h + 10
    end
    -- "Full changelog": the existing overlay, as it was.
    local link = LinkFor("changelog", p, LinkMarkup("dfChangelog", L["Full changelog"]),
        function() if GUI.ShowChangelog then GUI:ShowChangelog() end end, inner)
    link:ClearAllPoints()
    link:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, -y)
    return y + (link.layoutHeight or 14) + PAD
end

-- ---- the whole page ---------------------------------------------------------
local function PaintHeader()
    local name = UnitName and UnitName("player") or nil
    W.hello:SetText(name and format(L["Hello, %s"], name) or L["Home"])

    local profile = DF.GetCurrentProfile and DF:GetCurrentProfile() or nil
    local text = format(L["Profile: %s"], LinkMarkup("dfProfiles", profile or L["Profiles"]))
    local AP = DF.AutoProfilesUI
    local layout = AP and AP.IsLayoutActive and AP:IsLayoutActive()
        and AP.GetActiveLayoutName and AP:GetActiveLayoutName()
    if layout then
        text = text .. "  \194\183  " .. format(L["Layout: %s"], (tostring(layout):gsub("|", "")))
    end
    local w = max((view:GetWidth() or 0) - 4, 200)
    local link = LinkFor("profile", view, text, function() GUI:SelectModule("profiles", "profiles_manage") end, w)
    link:ClearAllPoints()
    link:SetPoint("TOPLEFT", W.hello, "BOTTOMLEFT", 0, -6)
end

function GUI:RefreshHomeView()
    if not (view and view:IsShown()) then return end
    local w = view.scroll:GetWidth() or 0
    if w < 50 then return end
    local body = view.body
    body:SetWidth(w)
    PaintHeader()

    -- ---- Your modules ----
    local y = 0
    local on, more, total = Home.TileModel()
    W.secTitle:ClearAllPoints()
    W.secTitle:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
    W.secTitle:SetText(L["Your modules"])
    local countText = format(L["%d of %d on"], #on, total)
    local secLink = LinkFor("modules", body,
        countText .. "  \194\183  " .. LinkMarkup("dfModules", L["Manage modules"]),
        function() GUI:SelectModule("modules") end, max(w - 160, 120))
    secLink:ClearAllPoints()
    secLink:SetPoint("LEFT", W.secTitle, "RIGHT", 12, 0)
    y = y + 24

    local list = {}
    for _, def in ipairs(on) do list[#list + 1] = { def = def } end
    if #more > 0 then list[#list + 1] = { more = more } end
    local cols = max(1, floor((w + GAP) / (TILE_MIN + GAP)))
    local tileW = (w - GAP * (cols - 1)) / cols
    for _, t in ipairs(tiles) do t:Hide() end
    for i, entry in ipairs(list) do
        local t = tiles[i]
        if not t then t = MakeTile(); tiles[i] = t end
        if entry.def then
            local def = entry.def
            t.target = def.id
            t.TileIcon:SetTexture(def.icon)
            t.TileIcon:SetAlpha(1)
            t.TileName:SetText(GUI:ModuleLabel(def) or "")
            t.TileStatus:SetText(GUI:ModuleStatus(def))
        else
            -- Off and coming-soon modules, folded: opens the Modules page.
            local names = {}
            for _, def in ipairs(entry.more) do names[#names + 1] = GUI:ModuleLabel(def) or def.id end
            local mod = GUI:GetModule("modules")
            t.target = "modules"
            t.TileIcon:SetTexture(mod and mod.icon or nil)
            t.TileIcon:SetAlpha(0.6)
            t.TileName:SetText(format(L["%d more"], #entry.more))
            t.TileStatus:SetText(concat(names, " \194\183 "))
        end
        local col, row = (i - 1) % cols, floor((i - 1) / cols)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", body, "TOPLEFT", col * (tileW + GAP), -(y + row * (TILE_H + GAP)))
        t:SetSize(tileW, TILE_H)
        t:Show()
    end
    local tileRows = floor((#list + cols - 1) / cols)
    y = y + tileRows * (TILE_H + GAP) + 8

    -- ---- Needs attention + What's new ----
    local two = w >= PANEL_MIN * 2 + GAP
    local pw = two and floor((w - GAP) / 2) or w
    local ha = LayoutAttention(W.attention, pw)
    local hn = LayoutWhatsNew(W.news, pw)
    W.attention:ClearAllPoints()
    W.news:ClearAllPoints()
    W.attention:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
    W.attention:SetSize(pw, ha)
    if two then
        W.news:SetPoint("TOPLEFT", body, "TOPLEFT", pw + GAP, -y)
        W.news:SetSize(w - pw - GAP, hn)
        y = y + max(ha, hn)
    else
        y = y + ha + GAP
        W.news:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
        W.news:SetSize(pw, hn)
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

    local hello = view:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
    hello:SetPoint("TOPLEFT", view, "TOPLEFT", 2, -4)
    hello:SetJustifyH("LEFT")
    Tint(hello, C.text)
    W.hello = hello

    local gutter = (GUI.Scroll and GUI.Scroll.gutter) or 14
    local S = DF.Search
    if S and S.CreateSearchBar then
        -- CreateSearchBar makes the bar it builds THE bar; the sidebar's stays
        -- it until Home is shown (AdoptSearch).
        local prev = S.SearchBar
        local bar = S:CreateSearchBar(view)
        S.SearchBar = prev
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", view, "TOPLEFT", 0, -50)
        bar:SetPoint("TOPRIGHT", view, "TOPRIGHT", -gutter, -50)
        bar:SetHeight(32)
        if DFFontHighlight and bar.editbox then bar.editbox:SetFontObject(DFFontHighlight) end
        if bar.placeholder then bar.placeholder:SetText(L["Search every setting..."]) end
        W.search = bar
    end

    -- Where the results panel sits while Home shows: the body's rect.
    local host = CreateFrame("Frame", nil, view)
    host:SetPoint("TOPLEFT", view, "TOPLEFT", 0, -TOP)
    host:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", 0, 0)
    W.resultsHost = host

    local secTitle = view.body:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    secTitle:SetJustifyH("LEFT")
    Tint(secTitle, C.textCaption or C.text)
    W.secTitle = secTitle

    W.attention = MakePanel()
    W.news = MakePanel()

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
