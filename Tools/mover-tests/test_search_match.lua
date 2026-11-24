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
check(S:_MatchIndex() ~= ix1, "index: rebuilt when the registry grows")
check(has(find("class"), late), "index: ...and the new entry is found")
S.Registry = { fadeAlpha }
check(#find("width") == 0, "index: rebuilt when the registry is replaced")

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

DandersFrames, GetLocale = savedDF, savedLocale
