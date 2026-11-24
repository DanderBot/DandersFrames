local NS = ...

-- ============================================================
-- THE SETTINGS SEARCH MATCHER -- DandersFrames_Options/Features/SearchMatch.lua
-- ------------------------------------------------------------
-- Drives the REAL Search.lua + SearchSynonyms.lua + SearchMatch.lua against a
-- stub host: entries are registered the way page builders register them (a
-- current tab and section, then Register), and the matcher is asked directly.
-- ☠ ONE LUA RUNTIME FOR EVERY SUITE: the DandersFrames global and GetLocale are
-- swapped here and restored at the end.
-- ============================================================

local savedDF, savedLocale = DandersFrames, GetLocale

local KEYS = {
    "frameFadeAlpha", "frameFadeEnabled", "rangeFadeAlpha", "frameWidth", "frameShowBorder",
    "showBuffs", "showDebuffs", "healthTextSize", "healthColor", "tooltipFrameCombat",
    "oorHealthBarAlpha", "sortEnabled", "ruAlpha", "deLabel",
}

local function NewHost(locale)
    local DF = {}
    DF.L = setmetatable({}, { __index = function(_, k) return k end })
    DF.PartyDefaults, DF.RaidDefaults = {}, {}
    for _, k in ipairs(KEYS) do DF.PartyDefaults[k] = 0; DF.RaidDefaults[k] = 0 end
    function DF:DebugWarn() end
    DF.GUI = {
        SelectedMode = "party", CurrentPageName = "p", Pages = {},
        SettingsBox = { pad = 10, group = 280, colMargin = 15, minCol = 290, colGutter = 20 },
    }
    DandersFrames = DF
    GetLocale = function() return locale or "enUS" end
    load_options_file_into("Features/Search.lua", NS)
    load_options_file_into("Features/SearchSynonyms.lua", NS)
    load_options_file_into("Features/SearchMatch.lua", NS)
    DandersFrames = savedDF
    return DF, DF.Search
end

local function Reg(S, tab, tabLabel, section, label, dbKey, tooltip)
    S:SetCurrentTab(tab, tabLabel)
    S:SetCurrentSection(section)
    local src = { tooltip = tooltip }
    local e = S:Register({ label = label, dbKey = dbKey, type = "slider" })
    e.sourceWidget = src
    return e
end

local function has(list, entry)
    for _, e in ipairs(list) do if e == entry then return true end end
    return false
end
local function setHas(set, entry) return set[entry] ~= nil end

local DF, S = NewHost()
local I = S._MatchInternals

-- ============================================================
-- 1. THE PURE PIECES
-- ============================================================
print("-- Search match: words normalise to one form")
eq(I.Norm("fading"), I.Norm("fade"), "norm: fading = fade")
eq(I.Norm("faded"), I.Norm("fade"), "norm: faded = fade")
eq(I.Norm("scaling"), I.Norm("scale"), "norm: scaling = scale")
eq(I.Norm("buffs"), "buff", "norm: buffs -> buff")
eq(I.Norm("class"), "class", "norm: class keeps its s")
eq(I.Norm("textures"), I.Norm("texture"), "norm: textures = texture")
eq(I.Norm("speed"), "speed", "norm: speed is not a past tense")
eq(I.Norm("x"), "x", "norm: one letter stays")

print("-- Search match: case folding reaches past ASCII")
eq(I.Fold("ÄÖÜ"), "äöü", "fold: German capitals")
eq(I.Fold("ПРОЗРАЧНОСТЬ"), "прозрачность", "fold: Cyrillic capitals")
eq(I.Fold("Ёлка"), "ёлка", "fold: Ё")
eq(#I.Words("Прозрачность рамки"), 2, "words: UTF-8 letters stay inside their word")
eq(I.Words("|cffff0000Red|r text")[1], "red", "words: colour codes come off")
local kw = I.KeyWords("frameFadeAlpha")
eq(kw[1] .. "," .. kw[2] .. "," .. kw[3], "frame,fade,alpha", "keys: camelCase splits")

print("-- Search match: bounded edit distance")
eq(I.Dist("helath", "health", 1), 1, "dist: a swapped pair is one edit")
eq(I.Dist("trasparency", "transparency", 2), 1, "dist: a dropped letter is one edit")
check(I.Dist("border", "order", 1) <= 1, "dist: border/order is one edit (so typos only fire on a miss)")
check(I.Dist("health", "width", 1) > 1, "dist: gives up past the bound")

-- ============================================================
-- 2. A SMALL REGISTRY
-- ============================================================
local fadeAlpha = Reg(S, "general_frame", "Frame", "Appearance", "Global Frame Fade", "frameFadeAlpha")
local fadeOn    = Reg(S, "general_frame", "Frame", "Appearance", "Enable Frame Fade", "frameFadeEnabled")
local rangeA    = Reg(S, "display_fading", "Fading", "Range", "Frame Alpha (Out of Range)", "rangeFadeAlpha")
local width     = Reg(S, "general_frame", "Frame", "Layout", "Width", "frameWidth")
local border    = Reg(S, "general_frame", "Frame", "Appearance", "Show Border", "frameShowBorder")
local buffs     = Reg(S, "auras_buffs", "Buff Bar", "Content", "Show Buffs", "showBuffs")
local debuffs   = Reg(S, "auras_debuffs", "Debuff Bar", "Content", "Show Debuffs", "showDebuffs")
local hpSize    = Reg(S, "bars_health", "Health Bar", "Text", "Font Size", "healthTextSize")
local hpColor   = Reg(S, "bars_health", "Health Bar", "Colors", "Bar Color", "healthColor")
local tipCombat = Reg(S, "display_tooltips", "Tooltips", "Unit Frame", "Show In Combat", "tooltipFrameCombat",
                      "Shows the unit tooltip while you are fighting.")
local oorHp     = Reg(S, "display_fading", "Fading", "Range", "Health Bar Alpha", "oorHealthBarAlpha")
local sortOn    = Reg(S, "general_sorting", "Sorting", "Sorting", "Enable Custom Sorting", "sortEnabled")
local ruAlpha   = Reg(S, "display_fading", "Затухание", "Дальность", "Прозрачность рамки", "ruAlpha")

check(#S.Registry == 13, "registry: every entry registered (" .. #S.Registry .. ")")

local function find(q) return S:RankedMatches(q) end
local function filter(q)
    local set = S:MatchEntries(S:CompileQuery(q))
    return set
end

print("-- Search match: synonyms")
local r = find("transparency")
check(has(r, fadeAlpha), "synonym: transparency finds the Frame Fade slider")
check(has(r, rangeA), "synonym: transparency finds an Alpha slider")
check(not has(r, width), "synonym: ...but not Width")
r = find("opacity")
check(has(r, oorHp) and has(r, fadeAlpha), "synonym: opacity finds Alpha and Fade")
r = find("hide")
check(has(r, border) and has(r, buffs), "synonym: hide finds the Show toggles")
r = find("aura")
check(has(r, buffs) and has(r, debuffs), "narrower: aura reaches buff and debuff settings")
r = find("buff")
check(has(r, buffs) and not has(r, debuffs), "narrower: buff does NOT find debuff settings")
r = find("size")
check(has(r, width) and has(r, hpSize), "synonym: size finds Width and Font Size")

print("-- Search match: tags, tooltips, keys")
r = find("dim")
check(has(r, fadeOn), "tag: a word only in the tag table finds the setting")
r = find("fighting")
check(has(r, tipCombat), "tooltip: a word only in the tooltip finds the setting")
r = find("alpha")
check(has(r, ruAlpha), "key: an English word in the key finds a translated label")
r = find("прозрачность")
check(has(r, ruAlpha), "label: a lower-case Cyrillic query finds its label")

print("-- Search match: partial words while typing")
r = find("opac")
check(has(r, fadeAlpha) and has(r, rangeA), "prefix: 'opac' already reaches the opacity concept")
r = find("bord")
check(has(r, border), "prefix: 'bord' finds Show Border")
r = find("тран")   -- no such word: nothing, not everything
check(#r == 0, "prefix: an unmatched fragment finds nothing")

print("-- Search match: typos")
r = find("helath")
check(has(r, hpSize) and has(r, hpColor), "typo: helath finds the Health Bar page")
r = find("trasparency")
check(has(r, fadeAlpha), "typo: trasparency still finds Frame Fade")
r = find("border")
check(has(r, border) and not has(r, sortOn), "typo: a word that hits is never typo-widened (border is not order)")

print("-- Search match: every word must match (filter)")
local set = filter("health alpha")
check(setHas(set, oorHp), "and: Health Bar Alpha answers both words")
check(not setHas(set, hpColor), "and: Health Bar's Bar Color answers only one")
check(not setHas(set, fadeAlpha), "and: Frame Fade answers only one")
set = filter("in combat")
check(setHas(set, tipCombat), "stopwords: 'in' is dropped, 'combat' still must match")
set = filter("fading")
check(setHas(set, rangeA) and setHas(set, oorHp), "page: a page name matches every setting on it")
check(S:CompileQuery("a") == nil, "short: one character is not a query")
local scoped = S:MatchEntries(S:CompileQuery("alpha"), function(e) return e.tab == "display_fading" end)
check(setHas(scoped, rangeA) and not setHas(scoped, fadeAlpha), "scope: only entries the scope keeps")

print("-- Search match: Home's ranking")
r = find("show border")
eq(r[1], border, "rank: the label that says it all comes first")
r = find("border zzzqqq")
check(has(r, border), "rank: with no entry answering every word, Home falls back to any word")
check(S:TextMatchesAll(S:CompileQuery("fade range"), { "Fading", "Range" }),
      "text: a card title plus its page answer the query together")
check(not S:TextMatchesAll(S:CompileQuery("fade width"), { "Fading", "Range" }),
      "text: ...and every word must be met")

print("-- Search match: one index per registry")
local ix1 = S:_MatchIndex()
check(S:_MatchIndex() == ix1, "index: reused while the registry stands")
local late = Reg(S, "general_sorting", "Sorting", "Sorting", "Sort by Class", "sortEnabled")
check(S:_MatchIndex() == ix1 and ix1.n == #S.Registry, "index: grows in place when the registry grows")
check(has(find("class"), late), "index: ...and the new entry is found")
S.Registry = { fadeAlpha }
check(#find("width") == 0, "index: rebuilt when the registry is replaced")

print("-- Search match: the index is built in slices, never in one go")
do
    local savedClock, savedTimer2 = debugprofilestop, C_Timer
    local now = 0
    debugprofilestop = function() now = now + 1; return now end   -- every read costs 1 ms
    local queued = {}
    C_Timer = { After = function(_, fn) queued[#queued + 1] = fn end }
    local _, S5 = NewHost()
    for i = 1, 100 do Reg(S5, "p" .. (i % 5), "Page", "Card", "Setting " .. i, "frameWidth") end
    local progress, done = 0, false
    function S5:_OnIndexProgress(complete) progress = progress + 1; if complete then done = true end end
    local ix = S5:_MatchIndex(5)
    check(ix.n < 100 and not ix.complete, "slice: a budgeted call stops early (" .. ix.n .. " of 100)")
    check(#queued == 1, "slice: ...and queues the rest for the next frame")
    local frames = 0
    while #queued > 0 and frames < 100 do
        local batch = queued; queued = {}
        for _, fn in ipairs(batch) do fn() end
        frames = frames + 1
    end
    check(done and S5:_MatchIndex().n == 100, "slice: later frames finish it (" .. frames .. " frames)")
    check(progress >= 1, "slice: ...and report as it grows")
    check(#S5:RankedMatches("setting 42") >= 1, "slice: the finished index answers")
    debugprofilestop, C_Timer = savedClock, savedTimer2
end

-- ============================================================
-- 3. A LOCALE'S OWN SYNONYMS
-- ============================================================
print("-- Search match: Search.LocaleConcepts")
do
    local DF2, S2 = NewHost("deDE")
    I = S2._MatchInternals
    S2.LocaleConcepts = { deDE = { { "durchsichtig", "transparenz" } } }
    I.ResetConcepts()
    local e = Reg(S2, "display_fading", "Verblassen", "Reichweite", "Transparenz", "deLabel")
    check(has(S2:RankedMatches("durchsichtig"), e), "locale: a group under the client's locale is used")
end

-- ============================================================
-- 4. WHAT THE UNIT FRAMES MODULE NEEDED (2026-11-24 in-game report)
-- ============================================================
print("-- Search match: a page with a table of its own registers its own keys")
do
    local DF3, S3 = NewHost()
    -- A unit frame page: builds against the unit's table, whose keys the party
    -- defaults do not have.
    local unitDb = { restingIconEnabled = false, restingIconSize = 16 }
    DF3.GUI.Pages.uf_player_icons = { tabName = "uf_player_icons" }
    DF3.GUI.PageBuildDb = function(page) if page.tabName == "uf_player_icons" then return unitDb end end
    S3:SetCurrentTab("uf_player_icons", "Player Unit Icons")
    S3:SetCurrentSection("Resting Icon")
    local e = S3:Register({ label = "Enable", dbKey = "restingIconEnabled" })
    check(e.id ~= nil, "own db: a unit-only key is registered")
    local stray = S3:Register({ label = "Nope", dbKey = "notAKeyAnywhere" })
    check(stray.id == nil, "own db: a key the page's table lacks is still dropped")
    check(has(S3:RankedMatches("resting"), e), "own db: 'resting' finds the Resting Icon card's setting")

    print("-- Search match: a card registers itself by title")
    local card = {}
    S3:SetCurrentSection("Combat Icon", card)
    local sec
    for _, r in ipairs(S3.Registry) do if r.isSection and r.label == "Combat Icon" then sec = r end end
    check(sec ~= nil and sec.sourceWidget == card, "section: the card is an entry, pointing at the card")
    local set = S3:MatchEntries(S3:CompileQuery("combat icon"))
    check(set[sec] ~= nil, "section: the filter finds the card by its title")
    for _, r in ipairs(S3:RankedMatches("combat icon")) do
        check(not r.isSection, "section: ...and Home's results leave it out")
    end
end

print("-- Search match: finished words match whole, the word being typed matches its start")
do
    local _, S4 = NewHost()
    local tex = Reg(S4, "bars_health", "Health Bar", "Settings", "Texture", "healthColor")
    local txt = Reg(S4, "bars_health", "Health Bar", "Text", "Health Text Size", "healthTextSize")
    local set = S4:MatchEntries(S4:CompileQuery("text health"))
    check(set[txt] and not set[tex], "prefix: a finished word ('text health') no longer finds Texture")
    set = S4:MatchEntries(S4:CompileQuery("health tex"))
    check(set[tex] and set[txt], "prefix: ...while 'tex' is still being typed it finds both")
    set = S4:MatchEntries(S4:CompileQuery("health t"))
    check(set[txt], "prefix: a one-letter word being typed still narrows by its start")

    print("-- Search match: tooltips match whole words, not their normal form")
    local step = Reg(S4, "auras_debuffs", "Debuff Bar", "Highlight", "Size Step", "frameWidth",
                     "Each icon after the first is this much smaller than the rest of the icons.")
    check(not S4:MatchEntries(S4:CompileQuery("resting"))[step], "tooltip: 'resting' does not find 'the rest of'")
    check(S4:MatchEntries(S4:CompileQuery("smaller"))[step], "tooltip: its own words still find it")

    print("-- Search match: phrases and the words players use")
    local tot = Reg(S4, "uf_targettarget_health", "Target of Target", "Colors", "Bar Color", "healthColor")
    local tgt = Reg(S4, "uf_target_health", "Target", "Colors", "Bar Color", "healthColor")
    set = S4:MatchEntries(S4:CompileQuery("target of target"))
    check(set[tot] and not set[tgt], "phrase: 'target of target' is that unit, not every target")
    set = S4:MatchEntries(S4:CompileQuery("tot"))
    check(set[tot] and not set[tgt], "narrower: 'tot' is target of target")
    local kickTick = Reg(S4, "uf_player_castbar", "Cast Bar", "Settings", "Interrupt Ready Mark", "frameShowBorder")
    check(S4:MatchEntries(S4:CompileQuery("kick"))[kickTick], "synonym: 'kick' finds interrupt settings")
end

DandersFrames, GetLocale = savedDF, savedLocale
