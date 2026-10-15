local NS = ...

-- ============================================================
-- A DISMISSED BANNER FOLDS TO A "SHOW TIP" CHIP
-- DandersUI/Sections.lua (UI:CreateInfoBanner, opts.dismissKey)
-- ------------------------------------------------------------
-- An explainer banner given a dismissKey carries a x; the x folds it to a small
-- chip in its own place, remembered in the host's tipStore, and the chip brings
-- it back. The real factory is cut out of Sections.lua and run over fake frames.
-- ============================================================

local SRC = ui_file_source("Sections.lua"):gsub("\r\n", "\n")
local a = SRC:find("function UI:CreateInfoBanner(parent, opts)", 1, true)
local e = a and SRC:find("\nend\n", a, true)
check(a ~= nil and e ~= nil, "banner: the factory is found")
if not (a and e) then do return end end
local fnSrc = SRC:sub(a, e + 4)
local ra = SRC:find("function UI:RefreshTips()", 1, true)
local re = ra and SRC:find("\nend\n", ra, true)
check(ra ~= nil and re ~= nil, "banner: UI:RefreshTips is found")
if ra and re then fnSrc = fnSrc .. "\n" .. SRC:sub(ra, re + 4) end

local function region(kind)
    local r = { _shown = true, kind = kind }
    function r:Show() self._shown = true end
    function r:Hide() self._shown = false end
    function r:SetShown(v) self._shown = v and true or false end
    function r:IsShown() return self._shown end
    function r:IsVisible() return self._shown end
    function r:SetText(t) self._text = t end
    function r:GetText() return self._text end
    function r:GetTexture() return self._tex end
    function r:SetTexture(t) self._tex = t end
    function r:GetVertexColor() return 1, 1, 1 end
    function r:GetStringWidth() return 7 * #(self._text or "") end
    function r:GetStringHeight() return 14 end
    -- Methods (Capitalised) fall back to a no-op; a field reads nil, as in game.
    return setmetatable(r, { __index = function(_, k)
        if type(k) == "string" and k:match("^%u") then return function() end end
    end })
end
local function frame()
    local f = region("frame")
    f._h, f._w, f.scripts = 0, 400, {}
    function f:SetHeight(h) self._h = h end
    function f:GetHeight() return self._h end
    function f:GetWidth() return self._w end
    function f:SetScript(n, fn) self.scripts[n] = fn end
    function f:HookScript(n, fn) self.scripts[n] = fn end
    function f:GetScript(n) return self.scripts[n] end
    function f:SetBackdropColor(...) self._bg = { ... } end
    function f:SetBackdropBorderColor(...) self._border = { ... } end
    function f:CreateFontString() return region("fs") end
    function f:CreateTexture() return region("tex") end
    return f
end

local store = {}
local relayouts = 0
local host = {
    hooks = { L = setmetatable({}, { __index = function(_, k) return k end }),
              tipStore = function() return store end },
}
function host:Hook(n) return self.hooks[n] end
function host:CreateCloseButton(parent, opts) local b = frame(); b.onClick = opts.onClick; return b end
function host:StyleButton(b, opts) b.Text = region("fs"); b.Text:SetText(opts.text); b.styled = opts end
function host:ShowTooltip(owner, opts) self.tip = opts end
function host:HideTooltip() self.tip = nil end
function host:SetSettingsFont() end
function host:GetAccent() return { r = 1, g = 1, b = 1 } end
function host:RelayoutHost() relayouts = relayouts + 1 end

local TONES = { info = { icon = "info", bg = { 0.1, 0.1, 0.2, 1 }, border = { 0.3, 0.3, 0.6, 1 } },
                caution = { icon = "warning", bg = { 0.2, 0.15, 0, 1 }, border = { 0.6, 0.5, 0, 1 } } }
local chunk = loadstring("local UI, CreateElementBackdrop, INFO_BANNER_TONES, ICON_PATH, SnapLen, FlowSpaceWidth, ParseHTMLSegments, CreateFrame, C_Timer = ...\n"
    .. fnSrc .. "\nreturn UI", "@Sections.lua:CreateInfoBanner")
check(chunk ~= nil, "banner: the factory compiles on its own")
if not chunk then do return end end
local UIt = chunk({}, function() end, TONES, "Icons\\", function(_, v) return v end,
    function() return 3 end, function() return {} end, function() return frame() end,
    { After = function(_, fn) fn() end })
local function make(opts) return UIt.CreateInfoBanner(host, frame(), opts) end

print("-- Banner: the x folds it to a chip, the chip brings it back")
local plain = make({ tone = "info", text = "Tip text." })
check(plain.closeButton == nil and plain.tipChip == nil, "plain: a banner with no dismissKey has no x and no chip")

local b = make({ tone = "info", text = "Profiles hold |cffffd200both|r modes.", dismissKey = "k1" })
check(b.closeButton ~= nil and b.closeButton._shown, "x: a dismissKey banner carries a x")
check(b.tipChip ~= nil and not b.tipChip._shown, "x: ...and its chip waits hidden")
check(b.tipChip.styled and b.tipChip.styled.text == nil and b.tipChip.styled.icon and b.tipChip.styled.icon.size == 18,
      "chip: the tone glyph alone, at 18 -- no label")
b.closeButton.onClick()
eq(store.k1, true, "x: pressing it remembers the dismissal")
check(b._folded and b.tipChip._shown and not b.body._shown and not b.icon._shown and not b.closeButton._shown,
      "x: ...and folds the banner to its chip")
check(SRC:find('chip:SetPoint("TOPRIGHT", banner, "TOPRIGHT", 0, 0)', 1, true) ~= nil,
      "chip: it sits where the x was, top right")
eq(b:GetHeight(), 24, "fold: the banner shrinks to the chip's height")
eq(b.layoutHeight, 30, "fold: ...and its slot with it")
check(b._bg and b._bg[4] == 0 and b._border and b._border[4] == 0, "fold: the box goes with the text")
check(relayouts > 0, "fold: the page is told to re-lay out")
b:SetTone("info")
check(b._bg[4] == 0, "fold: a theme repaint while folded does not redraw the box")
b:SetText("New text.")
check(not b.body._shown, "fold: new text while folded stays hidden")
b.tipChip:GetScript("OnEnter")(b.tipChip)
eq(host.tip and host.tip.title, "Tip", "chip: hovering it says it is a tip")
eq(host.tip and host.tip.lines[1], "New text.", "chip: ...and shows the tip, markup stripped")
local hint = host.tip and host.tip.lines[3]
check(host.tip.lines[2] == " " and type(hint) == "table" and hint.hint
      and hint.text == "Click to show the full banner on the page again.",
      "chip: ...and, apart and dimmed, what a click does")
b.closeButton:GetScript("OnEnter")(b.closeButton)
local xl = host.tip and host.tip.lines and host.tip.lines[1]
check(host.tip.title == "Hide tip" and type(xl) == "table" and xl.hint
      and xl.text == "It shrinks to an icon you can hover or click to bring back.",
      "x: its hover says the text is not lost, in the hint style")
b.tipChip:GetScript("OnClick")()
eq(store.k1, false, "chip: clicking it remembers the banner as opened")
check(not b._folded and b.body._shown and b.icon._shown and b.closeButton._shown and not b.tipChip._shown,
      "chip: ...and the banner is back")
check(b._bg and b._bg[4] == 1, "chip: ...with its box")

store.k2 = true
local c = make({ tone = "info", text = "Remembered.", dismissKey = "k2" })
check(c._folded and c.tipChip._shown, "remembered: a banner dismissed last session is built folded")
eq(c.layoutHeight, 30, "remembered: ...at the chip's slot height, before the page first lays it out")

-- ---- the global Page Tips mode ----
print("-- Banner: GLOBAL > Settings > Page Tips")
local mode = "show"
host.hooks.tipMode = function() return mode end
for k in pairs(store) do store[k] = nil end
local d = make({ tone = "info", text = "Tip.", dismissKey = "m1" })
check(not d._folded, "show: a tip starts open")
mode = "fold"; UIt.RefreshTips(host)
check(d._folded and d.tipChip._shown, "closed: every tip folds to its chip")
d.tipChip:GetScript("OnClick")()
check(not d._folded, "closed: a tip the user opens stays open...")
mode = "off"; UIt.RefreshTips(host)
check(d._folded and d._tipsOff and not d.tipChip._shown and d:GetHeight() == 1 and d.layoutHeight == 0,
      "hidden: a tip takes no room and leaves no chip -- a pixel tall, never 0")
check(d.fixedRowHeight and d.preferredHeight == 0,
      "hidden: ...and its row stays empty whatever height the page adds it at")
check(d.layoutSkip == true, "hidden: ...and a card drops the row and its gap")
local SECT_SRC = ui_file_source("Sections.lua"):gsub("\r\n", "\n")
local ev = SECT_SRC:match("local function EntryVisible%(.-\nend\n")
check(ev and ev:find('if rawget(w, "layoutSkip") then return false end', 1, true) ~= nil,
      "hidden: the card layout reads the skip")
mode = "show"; store.m1 = nil; UIt.RefreshTips(host)
check(not d._folded and d.body._shown, "show again: it is back")
check(d.layoutSkip == nil and not d.fixedRowHeight, "show again: ...with its row back, at its own height")
local e2 = make({ tone = "info", text = "Away.", dismissKey = "m2" })
e2._chipAway = true
local told = 0
e2.onFoldChanged = function() told = told + 1 end
e2.closeButton.onClick()
check(not e2.tipChip._shown and e2:GetHeight() == 1 and e2.layoutHeight == 0, "adopted: a chip another row shows is left to that row, the banner takes no room")
eq(told, 1, "adopted: ...and the page is told the banner folded")
host.hooks.tipMode = nil

local CTRL = options_file_source("GUI/Controls.lua")
check(CTRL:find("strip.AdoptTip = function(banner)", 1, true) ~= nil
  and CTRL:find('chip:SetPoint("LEFT", prev and prev.chip or collapseBtn, "RIGHT", 6, 0)', 1, true) ~= nil,
      "strip: the Expand All row takes a folded tip's chip, after Collapse All")
check(options_file_source("GUI/Pages/Indicators.lua"):find("controls.AdoptTip(adPromoBanner)", 1, true) ~= nil,
      "strip: ...and the Buff Bar hands it the Aura Designer promo")
local OPT = options_file_source("GUI/Pages/Options.lua")
check(OPT:find('L["Page Tips"]', 1, true) ~= nil and OPT:find("wipe(DandersFramesDB_v2.hiddenTips)", 1, true) ~= nil
  and OPT:find("GUI:RefreshTips()", 1, true) ~= nil,
      "setting: Page Tips is on GLOBAL > Settings, and picking one resets every tip to it")
check(df_file_source("Core/Config.lua"):find('pageTips = "show",', 1, true) ~= nil,
      "setting: ...shown by default")

-- ---- a NOTICE ignores Page Tips, and only the user's x closes it ----
print("-- Banner: notices")
host.hooks.tipMode = function() return "off" end
local n1 = make({ tone = "caution", text = "In combat.", dismissKey = "n1", notice = true })
check(not n1._folded and n1.closeButton._shown, "notice: Page Tips 'Hidden' does not hide it")
n1.closeButton.onClick()
check(n1._folded and n1.tipChip._shown, "notice: ...but its own x folds it to its chip")
host.hooks.tipMode = nil

-- ---- the chip's title says what kind of text it holds ----
print("-- Banner: the chip names its kind")
local kinds = { { { tone = "caution" }, "Warning", "Hide warning" }, { { tone = "info", notice = true }, "Notice", "Hide notice" },
                { { tone = "info" }, "Tip", "Hide tip" } }
for i, k in ipairs(kinds) do
    local o = k[1]
    local kb = make({ tone = o.tone, notice = o.notice, text = "x", dismissKey = "kind" .. i })
    kb.closeButton:GetScript("OnEnter")(kb.closeButton)
    eq(host.tip and host.tip.title, k[3], "kind: ...its x is titled " .. k[3])
    kb.closeButton.onClick()
    kb.tipChip:GetScript("OnEnter")(kb.tipChip)
    eq(host.tip and host.tip.title, k[2], "kind: a " .. (o.notice and "notice" or o.tone) .. " banner's chip is titled " .. k[2])
end

-- ---- every banner can be closed ----
print("-- Banner: every banner carries a x")
local FILES = { "FilterRegistry/UI/Options.lua", "GUI/Pages/Frames.lua", "GUI/Pages/Indicators.lua",
                "GUI/Pages/Modules.lua", "GUI/Pages/NicknamesPage.lua", "GUI/Pages/Auras.lua",
                "GUI/Panel.lua", "GUI/SettingsWidgets.lua", "AuraDesigner/UI/Indicators.lua",
                "ClickCasting/UI/Dialogs.lua", "Debug/ProfilerUI.lua" }
local sites, keys = 0, {}
for _, f in ipairs(FILES) do
    local src = options_file_source(f)
    for at in src:gmatch("()CreateInfoBanner%(") do
        local call = src:sub(at, at + 300)
        local key = call:match('dismissKey = "([%w_]+)"')
        sites = sites + 1
        check(key ~= nil, f .. ": a banner without a dismissKey")
        if key then
            check(keys[key] == nil, "keys: " .. key .. " is used once")
            keys[key] = call:find("notice = true", 1, true) ~= nil
        end
    end
end
check(sites >= 19, "sites: the scan finds every banner (saw " .. sites .. ")")
-- Live state, so Page Tips leaves them alone: combat, the Aura Designer holding
-- buffs, a mode switched off, the click-cast dialog's warning, the profiler's.
for _, k in ipairs({ "combat_lockout", "buffbar_ad_state", "mode_disabled", "clickcast_warning", "profiler_hooks" }) do
    eq(keys[k], true, "notices: " .. k .. " is a notice")
end
for _, k in ipairs({ "filterdesigner_intro", "buffbar_adpromo", "nicknames_scope", "border_animation_perf" }) do
    eq(keys[k], false, "tips: " .. k .. " follows Page Tips")
end

-- ---- a hint line is smaller, and the shared line gets its font back ----
print("-- Tooltip: a hint line is a step smaller, and only for that tooltip")
do
    local WID = ui_file_source("Widgets.lua"):gsub("\r\n", "\n")
    local block = WID:match("\nlocal HINT_STEP = .-\nlocal function AddTooltipLines%(host, lines%).-\nend\n")
    check(block ~= nil, "hint: the line code can be read")
    if block then
        local cleared
        local lines = {}
        local function fontString()
            local fs = { obj = "GameTooltipText", file = "Roboto.ttf", size = 12, flags = "" }
            function fs:GetFont() return self.file, self.size, self.flags end
            function fs:SetFont(f, s, fl) self.file, self.size, self.flags = f, s, fl end
            function fs:GetFontObject() return self.obj end
            function fs:SetFontObject(o) self.obj = o end
            return fs
        end
        local G = { GameTooltipTextLeft1 = fontString(), GameTooltipTextLeft2 = fontString(),
                    GameTooltipTextLeft3 = fontString() }
        local TT = {}
        function TT:HookScript(ev, fn) if ev == "OnTooltipCleared" then cleared = fn end end
        function TT:NumLines() return #lines end
        function TT:AddLine(t, r, g, bb) lines[#lines + 1] = { t = t, r = r } end
        local chunk = loadstring("local GameTooltip, _G, pairs, ipairs, type = ...\n" .. block .. "\nreturn AddTooltipLines")
        local AddTooltipLines = chunk(TT, G, pairs, ipairs, type)
        AddTooltipLines({}, { "Body text.", " ", { text = "Click me.", hint = true } })
        eq(G.GameTooltipTextLeft2.size, 12, "hint: the body line keeps its size")
        eq(G.GameTooltipTextLeft3.size, 10, "hint: the hint line is a step smaller")
        check(lines[3].r < lines[1].r, "hint: ...and darker than the text")
        check(type(cleared) == "function", "hint: the tooltip clearing is hooked")
        cleared()
        eq(G.GameTooltipTextLeft3.size, 12, "hint: a cleared tooltip gives the line its size back")
        eq(G.GameTooltipTextLeft3.obj, "GameTooltipText", "hint: ...and its font object")
    end
end
