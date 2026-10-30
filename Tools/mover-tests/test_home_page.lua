local NS = ...

-- ============================================================
-- THE HOME PAGE -- the parts that are data
-- DandersFrames_Options/GUI/Pages/Home.lua (GUI.Home) over the real module
-- registry (GUI/ModuleRegistry.lua): which modules get a tile, the "N more"
-- fold, the status lines, What's new tagging through the changelog
-- overlay's own parser, and the Needs attention empty state.
-- ⚠ Headless: nothing here builds a frame. The view is checked in game.
-- ============================================================

local savedDF = DandersFrames

local GUI = {
    SelectedMode = "party",
    GlobalView = false,
    Colors = {
        text = { r = 1, g = 1, b = 1 }, textDim = { r = 0.6, g = 0.6, b = 0.6 },
        textCaption = { r = 0.7, g = 0.7, b = 0.7 },
    },
}
function GUI.IsGlobalPage() return false end
local DF = { GUI = GUI }
DF.L = setmetatable({}, { __index = function(_, k) return k end })
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
DandersFrames = DF

load_options_file_into("GUI/ModuleRegistry.lua", NS)
load_options_file_into("GUI/Pages/Home.lua", NS)
local Home = GUI.Home
check(Home and Home.TileModel and Home.WhatsNew and Home.AttentionItems and GUI.SetHomeAttentionItems
      and GUI.ShowHomeView and GUI.HideHomeView, "api: the Home page is published on GUI")

local function ids(list)
    local out = {}
    for i, def in ipairs(list) do out[i] = def.id end
    return table.concat(out, ",")
end

-- ---- tiles ------------------------------------------------------------
print("-- Home: Your modules")
DF.db = { partyEnabled = true, raidEnabled = true }
DF.ClickCast = { db = { enabled = true, bindings = { {}, {} } } }
local on, more, total = Home.TileModel()
eq(ids(on), "group,clicks,global", "tiles: one per module that is on, in rail order")
eq(ids(more), "units", "tiles: Unit Frames (coming soon) folds into the N more tile")
eq(total, 4, "tiles: Home, Modules and Profiles are never counted")
eq(GUI:ModuleStatus(on[1]), "Party \194\183 Raid", "status: Group Frames says which modes run")
eq(GUI:ModuleStatus(on[2]), "2 bindings", "status: Click-Casting counts its bindings")
eq(GUI:ModuleStatus(on[3]), "Fonts, colors and integrations", "status: Global says what it holds")
eq(GUI:ModuleStatus(more[1]), "Coming in a later update.", "status: Unit Frames is coming")

DF.db = { partyEnabled = false, raidEnabled = false }
DF.ClickCast = { db = { enabled = false } }
on, more, total = Home.TileModel()
eq(ids(on), "global", "tiles: with both turned off only Global is a tile")
eq(ids(more), "group,units,clicks", "tiles: ...and the N more tile holds the three")
eq(#more, 3, "tiles: N = 3")
DF.db = { raidEnabled = false }
DF.ClickCast = { db = {} }
on, more = Home.TileModel()
eq(ids(on), "group,global", "tiles: Party alone keeps Group Frames on; an unset click-cast flag is off")
eq(GUI:ModuleStatus(on[1]), "Party only", "status: ...and says Party only")

-- ---- What's new ----------------------------------------------------------
print("-- Home: What's new tagging")
eq(Home.TagFor("New Features", "x"), "NEW", "tag: ### New Features is NEW")
eq(Home.TagFor("Improvements", "x"), "IMPROVED", "tag: ### Improvements is IMPROVED")
eq(Home.TagFor("Changes", "x"), "IMPROVED", "tag: ### Changes is IMPROVED")
eq(Home.TagFor("Bug Fixes", "x"), "FIX", "tag: ### Bug Fixes is FIX")
eq(Home.TagFor("", "Fixed a stuck frame"), "FIX", "tag: no group, a leading Fixed is FIX")
eq(Home.TagFor(nil, "Fix the thing"), "FIX", "tag: ...and Fix")
eq(Home.TagFor("", "Added a toggle"), "NEW", "tag: no group, a leading Added is NEW")
eq(Home.TagFor("", "**New** pattern textures"), "NEW", "tag: ...markdown and all")
eq(Home.TagFor("", "Smoother raids"), "IMPROVED", "tag: otherwise IMPROVED")
eq(Home.TagFor("WoW 12.1 (Midnight) Rework", "Fixed range"), "FIX", "tag: an unknown group falls back to the words")
eq(Home.FirstSentence("A **Mirror** option leans stripes. It also does more."), "A Mirror option leans stripes.",
   "text: emphasis stripped, first sentence only")
eq(Home.FirstSentence("No full stop here"), "No full stop here", "text: one sentence is kept whole")

-- The changelog overlay's own parser, lifted out of DF:CreateGUI.
local PANEL = options_file_source("GUI/Panel.lua"):gsub("\r\n", "\n")
local pa = PANEL:find("    local function ParseChangelog(text)\n", 1, true)
local pb = pa and PANEL:find("\n        return versions\n    end\n", pa, true)
check(pa and pb, "parser: found ParseChangelog in GUI/Panel.lua")
check(PANEL:find("GUI.ParseChangelog = ParseChangelog", 1, true) ~= nil,
      "parser: the panel publishes it for Home (no second parser)")
local Parse
if pa and pb then
    local src = PANEL:sub(pa, pb + #"\n        return versions\n    end" - 1) .. "\nreturn ParseChangelog"
    local f, err = loadstring(src, "=ParseChangelog")
    check(f ~= nil, "parser: it loads on its own (" .. tostring(err) .. ")")
    if f then Parse = f() end
end

local SAMPLE = table.concat({
    "# DandersFrames Changelog",
    "",
    "## [Unreleased]",
    "",
    "## [5.6.0]",
    "",
    "### New Features",
    "",
    "- (Bars) New **Tile** option for bar textures. More text here. (by Krathe)",
    "- (Bars) A **Mirror** option.",
    "",
    "### Improvements",
    "",
    "- (Performance) Smoother raids. No more freezes. (by Krathe)",
    "",
    "### Bug Fixes",
    "",
    "- (Range) Range fading now checks all your range spells. Devourer too.",
    "- (Raid Frames) Joins appear after combat.",
    "- (Fonts) Fonts are right after a reload.",
    "",
    "## [5.5.0]",
    "",
    "### Bug Fixes",
    "",
    "- (Auras) Old fix.",
}, "\n")

if Parse then
    print("-- Home: What's new from a changelog section")
    local versions = Parse(SAMPLE)
    local news = Home.WhatsNew(versions, "v5.7.0-alpha.1", 5)
    check(news ~= nil, "news: a section was found")
    eq(news and news.version, "5.6.0", "news: an empty [Unreleased] is skipped for the newest release")
    eq(news and #news.entries, 5, "news: at most five entries")
    local tags = {}
    for i, e in ipairs(news and news.entries or {}) do tags[i] = e.tag end
    eq(table.concat(tags, ","), "NEW,NEW,IMPROVED,FIX,FIX", "news: tags from the ### groups")
    eq(news.entries[1].title, "Bars", "news: the (Category) is the title")
    eq(news.entries[1].text, "New Tile option for bar textures.", "news: first sentence, no markdown, no author")
    eq(news.entries[3].text, "Smoother raids.", "news: ...for every entry")

    local old = Home.WhatsNew(versions, "5.5.0", 5)
    eq(old and old.version, "5.5.0", "news: the running version's own section wins")
    eq(old and old.entries[1].tag, "FIX", "news: ...tagged from its group")

    local alpha = Home.WhatsNew(Parse("## [Unreleased]\n\n### New Features\n\n- (Home) A home page.\n\n## [5.6.0]\n- (X) y\n"),
                                "v5.7.0-alpha.3", 5)
    eq(alpha and alpha.version, "5.7.0", "news: an alpha's [Unreleased] notes are named after the running version")
    eq(alpha and alpha.entries[1].tag, "NEW", "news: ...and tagged")

    local flat = Home.WhatsNew(Parse("## [1.0.0]\n- Fixed a bug\n- Added a thing\n- Tweaked the bar\n"), "1.0.0", 5)
    local ftags = {}
    for i, e in ipairs(flat and flat.entries or {}) do ftags[i] = e.tag end
    eq(table.concat(ftags, ","), "FIX,NEW,IMPROVED", "news: no ### groups, tags inferred from the leading word")
    eq(flat and flat.entries[1].title, nil, "news: no (Category), no title")

    eq(Home.WhatsNew(Parse(""), "1.0.0"), nil, "news: an empty changelog gives nothing")
    eq(#Home.WhatsNew(versions, "5.6.0", 2).entries, 2, "news: the cap is honoured")
end
eq(Home.WhatsNew(nil, "1.0.0"), nil, "news: no parse gives nothing")

-- ---- Needs attention ---------------------------------------------------------
print("-- Home: Needs attention")
eq(#Home.AttentionItems(), 0, "attention: no DF.Attention yet -- the empty state")
check(GUI:HomeHasConflict() == false, "attention: ...and nothing to open Home for")
DF.Attention = {
    GetActive = function()
        return {
            { id = "a", severity = 2, title = "A" }, { id = "b", severity = 1, title = "B" },
            { id = "c", severity = 3, title = "C" }, { id = "d", severity = 3, title = "D" },
            { id = "e", severity = 3, title = "E" },
        }
    end,
}
eq(#Home.AttentionItems(), 4, "attention: Phase 3's registry is read, at most four")
check(GUI:HomeHasConflict() == true, "attention: a severity-1 item is a conflict (Q3)")
DF.Attention = { GetActive = function() error("boom") end }
eq(#Home.AttentionItems(), 0, "attention: a failing registry shows the empty state, not an error")
GUI:SetHomeAttentionItems({ { id = "x", severity = 3, title = "X" } })
eq(#Home.AttentionItems(), 1, "attention: SetHomeAttentionItems supplies the list")
check(GUI:HomeHasConflict() == false, "attention: ...an info item is no conflict")
GUI:SetHomeAttentionItems(nil)
DF.Attention = nil
eq(#Home.AttentionItems(), 0, "attention: nil hands back to DF.Attention")

-- ---- source shape -------------------------------------------------------------
print("-- Home: reuses the search, does not fork it")
local HOME = options_file_source("GUI/Pages/Home.lua"):gsub("\r\n", "\n")
check(HOME:find("S:CreateSearchBar(view)", 1, true) ~= nil, "search: Home's box is the search's own bar")
check(HOME:find("function Search:", 1, true) == nil and HOME:find(":Find(", 1, true) == nil,
      "search: ...and Home runs no query of its own")
check(HOME:find("S.SearchBar = W.search", 1, true) ~= nil and HOME:find("S.SearchBar = W.sidebarSearch", 1, true) ~= nil,
      "search: Home takes the bar while it shows and hands it back")
local TOC = options_file_source("DandersFrames_Options.toc")
check(TOC:find("GUI\\Pages\\Home.lua", 1, true) ~= nil and TOC:find("GUI\\Pages\\ModulesPage.lua", 1, true) ~= nil,
      "toc: both pages are listed")

DF.db, DF.ClickCast = nil, nil
DandersFrames = savedDF
