local NS = ...

-- ============================================================
-- SETTINGS PAGE GROUPS -- DandersFrames_Options/GUI/Pages/*.lua
-- ------------------------------------------------------------
-- Every Modern card page with three or more cards puts its cards under group
-- headers, and every header name comes from the agreed set:
--
--   a page about ONE feature   Content, Layout, Appearance, Text, Effects
--                              (and Movement, the Frame page's own)
--   a page LISTING features    groups by subject (Frames / Interface, Unit
--                              Colors / Aura Colors, ...)
--
-- A page with one or two cards stays flat. Pinned Frames is exempt: its
-- Setup / Appearance / Members sub-tabs already group its cards.
--
-- Read from the SOURCE, as the page-builder tests are. A header counts when
-- the page adds it itself (Add(GUI:CreateHeader(...)) or a header local it
-- Adds) or names it in a group table (tools.MountCardGroups, ICON_GROUPS).
-- Classic boxes put their headers in a box (box:AddWidget(...)), which is
-- not a page header and is not counted.
-- ============================================================

local SHARED = { Content = true, Layout = true, Appearance = true, Text = true, Effects = true, Movement = true }
local SUBJECT = {
    Frames = true, Interface = true,                    -- Settings
    Sorting = true, Priority = true,                    -- Sorting
    ["Unit Colors"] = true, ["Aura Colors"] = true,     -- Colors
    Range = true, ["Unit State"] = true,                -- Fading
    ["Unit Frame"] = true, Auras = true,                -- Tooltips
    ["Group Roles"] = true, Markers = true,             -- Icons
    Status = true, Combat = true,
    Targeting = true, Threat = true,                    -- Highlights
    ["Reduced Max Health"] = true,                      -- Health Bar's own feature
}
-- Headers that title a whole page or section rather than a group of cards.
local PAGE_TITLES = { ["Targeted List"] = true, ["Auto Layouts"] = true }
local EXEMPT = { general_pinnedframes = "its Setup / Appearance / Members sub-tabs group its cards" }

local FILES = { "Auras.lua", "Frames.lua", "Indicators.lua", "Modules.lua", "Options.lua" }

-- A page is the body of BuildPage(pageVar, ...), which is not always in the
-- file that creates its tab (Buff Bar's and Icons' are not), so the tab ids
-- are collected from every file first.
local SRC, TAB_ID = {}, {}
for _, file in ipairs(FILES) do
    SRC[file] = options_file_source("GUI/Pages/" .. file)
    for var, id in SRC[file]:gmatch('local (page%w+) = CreateSubTab%([^,]+,%s*"([%w_]+)"') do TAB_ID[var] = id end
end

print("-- Settings page groups: every card page with three or more cards is grouped")
local pagesChecked = 0
for _, file in ipairs(FILES) do
    local src = SRC[file]
    local tabs = {}
    for at, var in src:gmatch('()BuildPage%((page%w+),') do tabs[#tabs + 1] = { at = at, id = TAB_ID[var] or var } end
    for i, t in ipairs(tabs) do
        local seg = src:sub(t.at, (tabs[i + 1] and tabs[i + 1].at or #src + 1) - 1)

        local cards = 0
        for _ in seg:gmatch('OpenSection%(L%["') do cards = cards + 1 end
        for _ in seg:gmatch('MountIcon%({') do cards = cards + 1 end

        local names = {}
        for name, col in seg:gmatch('[^:%w]Add%(GUI:CreateHeader%(self%.child, L%["([^"]+)"%]%), 40, ([%w"]+)%)') do
            names[#names + 1] = { name = name, col = col }
        end
        for var, name in seg:gmatch('local (%w+) = GUI:CreateHeader%(self%.child, L%["([^"]+)"%]%)') do
            if seg:find("[^:%w]Add%(" .. var .. ", 40", 1) then names[#names + 1] = { name = name, col = "?" } end
        end
        for tbl in seg:gmatch("tools%.MountCardGroups%(Add, (%b{})%)") do
            for name in tbl:gmatch('label = L%["([^"]+)"%]') do names[#names + 1] = { name = name, col = "?" } end
        end
        for tbl in seg:gmatch("local ICON_GROUPS = (%b{})") do
            for name in tbl:gmatch('label = L%["([^"]+)"%]') do names[#names + 1] = { name = name, col = "?" } end
        end

        local groups = 0
        for _, h in ipairs(names) do
            if not PAGE_TITLES[h.name] then
                groups = groups + 1
                check(SHARED[h.name] or SUBJECT[h.name],
                      t.id .. ": the group header \"" .. h.name .. "\" is one of the agreed names")
            end
        end

        if cards >= 3 then
            pagesChecked = pagesChecked + 1
            if EXEMPT[t.id] then
                check(groups == 0, t.id .. ": exempt (" .. EXEMPT[t.id] .. "), so it adds no group headers")
            else
                check(groups > 0, t.id .. ": " .. cards .. " cards, so they sit under group headers")
            end
        end
    end
end
check(pagesChecked >= 20, "the scan finds the card pages (saw " .. pagesChecked .. ")")
