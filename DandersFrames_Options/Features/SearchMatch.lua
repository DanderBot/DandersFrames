-- ☠ Companion addon: take the parent's table from the global it publishes
-- (see the same note at the head of Features/Search.lua).
local DF = DandersFrames
local Search = DF.Search

local pairs, ipairs, type, next, setmetatable = pairs, ipairs, type, next, setmetatable
local sub, gsub, gmatch, byte, find, char =
    string.sub, string.gsub, string.gmatch, string.byte, string.find, string.char
local sort = table.sort
local min, abs = math.min, math.abs

-- ============================================================
-- SETTINGS SEARCH -- THE MATCHER
-- Turns the registry (Features/Search.lua) into a word index once, then answers
-- each query from it. Two consumers:
--   * Search:Find          Home's ranked results (every word first, then any word)
--   * Search:MatchEntries  the page list's in-place filter (every word, no rank)
--
-- WHAT A SETTING ANSWERS TO, strongest first:
--   label > per-setting tags (Search.Tags) > card title > page > key > tooltip
-- plus, for the label, its tags and its card title, every word in the same
-- concept group (Search.Concepts) and the narrower words a broad one reaches
-- (Search.Narrower). Words are case-folded and normalised (plural, -ing, -ed
-- and a trailing e come off), so "fading" finds "Fade".
--
-- A QUERY WORD matches its own word, any indexed word it STARTS (so the filter
-- follows the typing: "opac" already finds Opacity), the concepts of those, and
-- -- only when none of that hits anything -- the indexed words within a small
-- edit distance of it (a typo: "trasparency", "helath").
--
-- ★ ONE INDEX PER REGISTRY. The registry is replaced wholesale on every build,
-- so the index is keyed on its identity and length and rebuilt when either
-- moves. Building it is cheap: word splitting and normalising are cached per
-- string, and labels repeat heavily ("Offset X" is on dozens of pages).
-- ============================================================

-- Field weights. A concept or narrower hit is worth a fraction of the field it
-- landed in (see the multipliers in Compile).
local W_LABEL, W_TAG, W_SECTION, W_PAGE, W_KEY, W_TIP = 100, 80, 40, 30, 25, 20
-- A whole query found in the label, as typed: the strongest single signal for
-- a ranked list.
local PHRASE_BONUS = 300

-- ------------------------------------------------------------
-- CASE FOLDING
-- string.lower only knows ASCII. The client languages that have case beyond it
-- are the Latin-1 ones (deDE, frFR, esES, itIT, ptBR) and ruRU, all two-byte in
-- UTF-8, so a table over those pairs is the whole job. Korean and Chinese have
-- no case.
-- ------------------------------------------------------------
local FOLD = {}
do
    local C3, D0, D1 = char(0xC3), char(0xD0), char(0xD1)
    -- U+00C0..U+00DE (not U+00D7, the multiplication sign) -> +0x20
    for b = 0x80, 0x9E do
        if b ~= 0x97 then FOLD[C3 .. char(b)] = C3 .. char(b + 0x20) end
    end
    -- U+0410..U+041F -> U+0430..U+043F (same lead byte)
    for b = 0x90, 0x9F do FOLD[D0 .. char(b)] = D0 .. char(b + 0x20) end
    -- U+0420..U+042F -> U+0440..U+044F (next lead byte)
    for b = 0xA0, 0xAF do FOLD[D0 .. char(b)] = D1 .. char(b - 0x20) end
    -- U+0400..U+040F (Ё and friends) -> U+0450..U+045F
    for b = 0x80, 0x8F do FOLD[D0 .. char(b)] = D1 .. char(b + 0x10) end
end
local FOLD_PATTERN = "[" .. char(0xC3) .. char(0xD0) .. "][" .. char(0x80) .. "-" .. char(0xBF) .. "]"
local HIGH_PATTERN = "[" .. char(0x80) .. "-" .. char(0xFF) .. "]"

-- ⚠ ASCII BY EXPLICIT RANGE, not string.lower or %u: both follow the C library's
-- locale, and under a single-byte code page they "lower" the lead bytes of UTF-8
-- letters into other bytes -- a Cyrillic label comes out as garbage.
local ASCII_LOWER = {}
for b = 65, 90 do ASCII_LOWER[char(b)] = char(b + 32) end

local function Fold(s)
    s = gsub(s, "[A-Z]", ASCII_LOWER)
    if find(s, HIGH_PATTERN) then s = gsub(s, FOLD_PATTERN, FOLD) end
    return s
end

-- Colour codes, textures, atlases and line breaks out of a tooltip or label.
local function StripMarkup(s)
    if not find(s, "|", 1, true) then return s end
    s = gsub(s, "|c%x%x%x%x%x%x%x%x", "")
    s = gsub(s, "|r", "")
    s = gsub(s, "|T.-|t", " ")
    s = gsub(s, "|A.-|a", " ")
    s = gsub(s, "|n", " ")
    return s
end

-- ------------------------------------------------------------
-- WORDS AND THEIR NORMAL FORM
-- A word is a run of anything that is not ASCII space or punctuation, so UTF-8
-- letters stay inside their word instead of splitting it.
-- ⚠ THE SEPARATORS ARE SPELLED OUT, not %s / %p: those classes follow the C
-- library's locale too, and under a single-byte code page every UTF-8 byte reads
-- as punctuation -- a Russian label splits into one "word" per letter.
-- ------------------------------------------------------------
-- Built from byte codes, every separator %-escaped (any non-alphanumeric byte
-- after % stands for itself), so there is no escape in the source to mangle.
local WORD
do
    local parts = { "[^" }
    for b = 1, 127 do
        local sep = b <= 32 or b == 127 or (b >= 33 and b <= 47) or (b >= 58 and b <= 64)
            or (b >= 91 and b <= 96) or (b >= 123 and b <= 126)
        if sep then parts[#parts + 1] = "%" .. char(b) end
    end
    parts[#parts + 1] = "]+"
    WORD = table.concat(parts)
end

local normCache = {}
local function Norm(w)
    local n = normCache[w]
    if n then return n end
    n = w
    local len = #n
    if byte(n, len) and byte(n, len) < 128 then
        if len > 4 and sub(n, -3) == "ies" then
            n = sub(n, 1, -4) .. "y"
        elseif len > 5 and sub(n, -3) == "ing" then
            n = sub(n, 1, -4)
        elseif len > 4 and sub(n, -2) == "ed" and sub(n, -3) ~= "eed" then
            n = sub(n, 1, -3)
        elseif len > 4 and sub(n, -2) == "es"
            and (find(sub(n, -3, -3), "[sxz]") or sub(n, -4, -3) == "ch" or sub(n, -4, -3) == "sh") then
            n = sub(n, 1, -3)
        elseif len > 3 and sub(n, -1) == "s" and not find(sub(n, -2, -2), "[su]") then
            n = sub(n, 1, -2)
        end
        if #n >= 4 and sub(n, -1) == "e" then n = sub(n, 1, -2) end
    end
    normCache[w] = n
    return n
end

-- Folded words of a string, cached per string (labels, titles and tooltips are
-- the same few strings over and over).
local wordsCache = {}
local function Words(text)
    local c = wordsCache[text]
    if c then return c end
    c = {}
    for w in gmatch(Fold(StripMarkup(text)), WORD) do c[#c + 1] = w end
    wordsCache[text] = c
    return c
end

-- A db key's words: "frameFadeAlpha" -> frame, fade, alpha. Always English.
local keyCache = {}
local function KeyWords(key)
    local c = keyCache[key]
    if c then return c end
    local spaced = gsub(gsub(gsub(key, "_", " "), "(%l)(%u)", "%1 %2"), "(%a)(%d)", "%1 %2")
    c = Words(spaced)
    keyCache[key] = c
    return c
end

local function IsAscii(s) return not find(s, HIGH_PATTERN) end

-- ------------------------------------------------------------
-- EDIT DISTANCE, bounded: optimal string alignment (a swap of two neighbours
-- is one edit), giving up as soon as a whole row is over the bound.
-- ------------------------------------------------------------
local rowA, rowB, rowC = {}, {}, {}
local function Dist(a, b, maxd)
    local la, lb = #a, #b
    if abs(la - lb) > maxd then return maxd + 1 end
    local prev2, prev, cur = rowA, rowB, rowC
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        cur[0] = i
        local rowMin = i
        local ai = byte(a, i)
        for j = 1, lb do
            local bj = byte(b, j)
            local v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + ((ai == bj) and 0 or 1))
            if i > 1 and j > 1 and ai == byte(b, j - 1) and byte(a, i - 1) == bj then
                v = min(v, prev2[j - 2] + 1)
            end
            cur[j] = v
            if v < rowMin then rowMin = v end
        end
        if rowMin > maxd then return maxd + 1 end
        prev2, prev, cur = prev, cur, prev2
    end
    return prev[lb]
end

local function TypoBound(len)
    if len >= 8 then return 2 end
    if len >= 5 then return 1 end
    return 0
end

-- ------------------------------------------------------------
-- CONCEPTS -- built once, on first use, from Search.Concepts / Narrower /
-- LocaleConcepts (Features/SearchSynonyms.lua).
-- ------------------------------------------------------------
local conceptsOf      -- norm -> { id, ... }
local narrowerOf      -- norm -> { norm, ... }
local conceptVocab    -- folded word -> norm, every word named in a group

local function AddConceptGroups(groups, firstId)
    local id = firstId
    for _, group in ipairs(groups or {}) do
        id = id + 1
        for _, phrase in ipairs(group) do
            for _, w in ipairs(Words(phrase)) do
                local n = Norm(w)
                conceptVocab[w] = n
                local list = conceptsOf[n]
                if not list then list = {}; conceptsOf[n] = list end
                local seen = false
                for _, x in ipairs(list) do if x == id then seen = true break end end
                if not seen then list[#list + 1] = id end
            end
        end
    end
    return id
end

local function EnsureConcepts()
    if conceptsOf then return end
    conceptsOf, narrowerOf, conceptVocab = {}, {}, {}
    local last = AddConceptGroups(Search.Concepts, 0)
    local locale = GetLocale and GetLocale()
    local extra = Search.LocaleConcepts and locale and Search.LocaleConcepts[locale]
    if extra then AddConceptGroups(extra, last) end
    for broad, list in pairs(Search.Narrower or {}) do
        local out = {}
        for _, w in ipairs(list) do
            for _, ww in ipairs(Words(w)) do out[#out + 1] = Norm(ww) end
        end
        for _, bw in ipairs(Words(broad)) do narrowerOf[Norm(bw)] = out end
    end
end

-- ------------------------------------------------------------
-- THE INDEX
-- words[norm][entry] = weight, cons[id][entry] = weight, vocab[folded] = norm.
-- ------------------------------------------------------------
local function TooltipText(w)
    if type(w) ~= "table" then return nil end
    local parts = {}
    local t = w.tooltip
    if type(t) == "string" then
        parts[#parts + 1] = t
    elseif type(t) == "table" then
        if type(t.title) == "string" then parts[#parts + 1] = t.title end
        if type(t.lines) == "table" then
            for _, line in ipairs(t.lines) do
                if type(line) == "string" then parts[#parts + 1] = line end
            end
        end
    end
    if type(w.tooltipText) == "string" then parts[#parts + 1] = w.tooltipText end
    if type(w.tooltipSubText) == "string" then parts[#parts + 1] = w.tooltipSubText end
    if #parts == 0 then return nil end
    return table.concat(parts, " ")
end

local function Post(map, k, entry, weight)
    local p = map[k]
    if not p then p = {}; map[k] = p end
    local cur = p[entry]
    if not cur or weight > cur then p[entry] = weight end
end

-- `rawOnly`: post the word as written, not its normal form (tooltips). A
-- tooltip is prose, and normalising prose finds settings by accident: "resting"
-- and "the rest of the icons" share the normal form "rest".
local function AddField(ix, entry, words, weight, withConcepts, skipStop, rawOnly)
    local stop = Search.StopWords
    for _, w in ipairs(words) do
        if not (skipStop and (stop[w] or #w < 3)) then
            local n = Norm(w)
            ix.vocab[w] = n
            if rawOnly then
                Post(ix.raw, w, entry, weight)
            else
                Post(ix.words, n, entry, weight)
            end
            if withConcepts then
                local ids = conceptsOf[n]
                if ids then
                    for _, id in ipairs(ids) do Post(ix.cons, id, entry, weight) end
                end
            end
        end
    end
end

local function IndexEntry(ix, entry)
    if ix.indexed then ix.indexed[entry] = true end
    if type(entry.label) == "string" then
        AddField(ix, entry, Words(entry.label), W_LABEL, true)
    end
    local key = (type(entry.dbKey) == "string" and entry.dbKey) or nil
    local tags = (key and Search.Tags and Search.Tags[key]) or entry.searchTags
    if type(tags) == "string" then
        AddField(ix, entry, Words(tags), W_TAG, true)
    end
    if type(entry.section) == "string" then
        AddField(ix, entry, Words(entry.section), W_SECTION, true)
    end
    if type(entry.tabLabel) == "string" then
        AddField(ix, entry, Words(entry.tabLabel), W_PAGE, false)
    end
    if type(entry.tab) == "string" then
        AddField(ix, entry, KeyWords(entry.tab), W_PAGE, false, true)
    end
    if key then
        AddField(ix, entry, KeyWords(key), W_KEY, false, true)
    end
    -- A prebuilt entry carries its tooltip as text (it has no widget yet).
    local tip = TooltipText(entry.sourceWidget) or (type(entry.tooltipText) == "string" and entry.tooltipText) or nil
    if tip then
        AddField(ix, entry, Words(tip), W_TIP, false, true, true)
    end
    -- ...and its English label beside the translated one, so an English word still
    -- finds it on a translated client (the same as a key's English words do).
    if type(entry.labelEn) == "string" and entry.labelEn ~= entry.label then
        AddField(ix, entry, Words(entry.labelEn), W_TAG, true)
    end
end

-- The index for the registry as it stands, built if it is out of date.
-- ★ GROWN, NEVER REBUILT, AND NEVER IN ONE GO. The registry only ever grows
-- by appending (a build adds page after page) or is replaced whole, so the
-- index keeps the count it has reached and adds the entries after it; only a
-- new registry starts it again. With `budgetMs` it stops once that much time is
-- spent and finishes on later frames (a few thousand entries cost ~100 ms in
-- one piece -- the freeze on clicking into the box). The partial index answers
-- for what it holds; Search:_OnIndexProgress is told as it grows. Without a
-- budget (tests, tools) it completes now.
-- ★ ANY LIST OF ENTRIES, in its own slot. The live registry (Home's results, the
-- ledger) is indexed in slot "_matchIndex"; the page list's filter indexes its own
-- list -- live entries of built pages plus prebuilt ones for the rest
-- (Features/SearchPrebuilt.lua) -- in "_filterIndex". Each slot grows and slices
-- on its own.
local INDEX_SLICE_MS = 4
function Search:_MatchIndexFor(reg, slot, budgetMs)
    EnsureConcepts()
    reg = reg or {}
    local ix = self[slot]
    if not ix or ix.reg ~= reg or ix.n > #reg then
        ix = { reg = reg, n = 0, words = {}, cons = {}, raw = {}, vocab = {}, indexed = {}, slot = slot }
        for w, n in pairs(conceptVocab) do ix.vocab[w] = n end
        self[slot] = ix
    end
    local total = #reg
    if ix.n < total then
        local clock = budgetMs and debugprofilestop
        local deadline = clock and (clock() + budgetMs)
        local i = ix.n
        while i < total do
            i = i + 1
            IndexEntry(ix, reg[i])
            if deadline and i % 16 == 0 and clock() > deadline then break end
        end
        ix.n = i
    end
    ix.complete = ix.n >= #reg
    if not ix.complete and budgetMs then self:_QueueIndexSlice(slot) end
    return ix
end

function Search:_MatchIndex(budgetMs)
    return self:_MatchIndexFor(self.Registry, "_matchIndex", budgetMs)
end

function Search:_QueueIndexSlice(slot)
    slot = slot or "_matchIndex"
    self._indexSliceQueued = self._indexSliceQueued or {}
    if self._indexSliceQueued[slot] or not C_Timer then return end
    self._indexSliceQueued[slot] = true
    C_Timer.After(0, function()
        self._indexSliceQueued[slot] = nil
        local cur = self[slot]
        if not cur then return end
        local ix = self:_MatchIndexFor(cur.reg, slot, INDEX_SLICE_MS)
        if self._OnIndexProgress then
            local ok, err = pcall(self._OnIndexProgress, self, ix.complete, slot)
            if not ok and err then geterrorhandler()(err) end
        end
    end)
end
Search.INDEX_SLICE_MS = INDEX_SLICE_MS

-- ------------------------------------------------------------
-- COMPILING A QUERY
-- Each query word becomes the words and concepts it accepts, each with a
-- multiplier on the field weight it lands on.
-- ------------------------------------------------------------
local M_EXACT, M_PREFIX, M_TYPO = 1.0, 0.8, 0.6
local M_CONCEPT, M_NARROW = 0.6, 0.7

local function Accept(map, k, m)
    if not map[k] or map[k] < m then map[k] = m end
end

local function HitsAnything(ix, acc)
    for n in pairs(acc.words) do if ix.words[n] then return true end end
    for id in pairs(acc.cons) do if ix.cons[id] then return true end end
    for w in pairs(acc.raw) do if ix.raw[w] then return true end end
    return false
end

local function AcceptConcepts(acc, n, m)
    local ids = conceptsOf[n]
    if ids then for _, id in ipairs(ids) do Accept(acc.cons, id, m) end end
end

-- `isLast`: the word still being typed. Only it matches the words it STARTS;
-- the words before it are finished, so "health text" no longer finds Texture.
local function CompileWord(ix, qw, isLast)
    local acc = { word = qw, words = {}, cons = {}, raw = {} }
    local n = Norm(qw)
    Accept(acc.words, n, M_EXACT)
    Accept(acc.raw, qw, M_EXACT)
    if #qw < 2 and not isLast then return acc end   -- "offset x": the x itself only

    if #qw >= 2 then
        AcceptConcepts(acc, n, M_CONCEPT)
        local narrow = narrowerOf[n]
        if narrow then
            for _, nn in ipairs(narrow) do Accept(acc.words, nn, M_NARROW) end
        end
    end

    -- Words this one starts (or, for a non-ASCII word, sits inside -- Chinese
    -- and Korean labels are one long word with no spaces to start at).
    local ascii = IsAscii(qw)
    if isLast then
        for raw, rn in pairs(ix.vocab) do
            if raw ~= qw then
                local at = find(raw, qw, 1, true)
                if at == 1 or (at and not ascii) then
                    Accept(acc.words, rn, M_PREFIX)
                    Accept(acc.raw, raw, M_PREFIX)
                    if #qw >= 4 then AcceptConcepts(acc, rn, M_CONCEPT * M_PREFIX) end
                end
            end
        end
    end

    -- A typo, only when nothing above reaches a single setting.
    if ascii and not HitsAnything(ix, acc) then
        local bound = TypoBound(#qw)
        if bound > 0 then
            for raw, rn in pairs(ix.vocab) do
                if IsAscii(raw) and Dist(qw, raw, bound) <= bound then
                    Accept(acc.words, rn, M_TYPO)
                    Accept(acc.raw, raw, M_TYPO)
                    AcceptConcepts(acc, rn, M_CONCEPT * M_TYPO)
                end
            end
        end
    end
    return acc
end

-- query -> compiled query, or nil when there is nothing to search for.
-- `reg`, `slot`: compile against that list's index (the page list's filter);
-- by default, the live registry's.
function Search:CompileQuery(query, reg, slot)
    if type(query) ~= "string" then return nil end
    local folded = Fold(query):gsub("^%s+", ""):gsub("%s+$", "")
    if #folded < 2 then return nil end
    local ix
    if reg then
        ix = self:_MatchIndexFor(reg, slot or "_filterIndex", INDEX_SLICE_MS)
    else
        ix = self:_MatchIndex(INDEX_SLICE_MS)
    end

    -- Phrases that name one thing ("target of target") become that thing's word.
    local text = folded
    for phrase, word in pairs(Search.Phrases or {}) do
        if find(text, phrase, 1, true) then
            text = gsub(text, "%f[%w]" .. gsub(phrase, "%p", "%%%0") .. "%f[%W]", word)
        end
    end

    local all, kept = {}, {}
    for w in gmatch(text, WORD) do all[#all + 1] = w end
    local stop = Search.StopWords
    for _, w in ipairs(all) do
        if not stop[w] then kept[#kept + 1] = w end
    end
    if #kept == 0 then kept = all end
    if #kept == 0 then return nil end

    local compiled = { text = folded, words = {}, index = ix }
    -- The last word is the one being typed, unless the query ends in a space.
    local typing = not find(query, "%s$")
    for i, w in ipairs(kept) do compiled.words[i] = CompileWord(ix, w, typing and i == #kept) end
    return compiled
end

-- entry -> best weight for one compiled word.
local function WordHits(ix, acc)
    local hits = {}
    for n, m in pairs(acc.words) do
        local p = ix.words[n]
        if p then
            for entry, w in pairs(p) do
                local s = w * m
                if not hits[entry] or s > hits[entry] then hits[entry] = s end
            end
        end
    end
    for id, m in pairs(acc.cons) do
        local p = ix.cons[id]
        if p then
            for entry, w in pairs(p) do
                local s = w * m
                if not hits[entry] or s > hits[entry] then hits[entry] = s end
            end
        end
    end
    for raw, m in pairs(acc.raw) do
        local p = ix.raw[raw]
        if p then
            for entry, w in pairs(p) do
                local s = w * m
                if not hits[entry] or s > hits[entry] then hits[entry] = s end
            end
        end
    end
    return hits
end

-- Does a piece of text (a card title, a page name) answer every word of a
-- compiled query? Used for the parts of a page that carry no search entry.
-- `texts` is a list; each query word may be met by any item. An item is a
-- string, or { text, literal = true } for text matched on its words alone, with
-- no concepts -- the way the index treats a page's name (a page called Fading
-- is not "about transparency" just because fade and transparency are synonyms).
function Search:TextMatchesAll(compiled, texts)
    if not compiled then return false end
    for _, acc in ipairs(compiled.words) do
        local ok = false
        for _, item in ipairs(texts) do
            local text, literal = item, false
            if type(item) == "table" then text, literal = item[1], item.literal end
            if type(text) == "string" then
                for _, w in ipairs(Words(text)) do
                    local n = Norm(w)
                    if acc.words[n] then ok = true break end
                    local ids = not literal and conceptsOf[n]
                    if ids then
                        for _, id in ipairs(ids) do
                            if acc.cons[id] then ok = true break end
                        end
                    end
                    if ok then break end
                end
            end
            if ok then break end
        end
        if not ok then return false end
    end
    return true
end

-- Does one entry answer every word? For an entry the index does not hold -- a
-- control whose setting the registry left out (no default in this mode), or a
-- page rebuilt since the index was -- judged on exactly the fields the index
-- would have given it, so the answer cannot differ from one the index gives.
-- `section`, `pageLabel` and `pageName` stand in for what an unregistered entry
-- was never stamped with (Register stamps them only on entries it keeps).
function Search:EntryMatchesAll(compiled, entry, section, pageLabel, pageName)
    if not (compiled and type(entry) == "table") then return false end
    local probe = entry
    if (section and not entry.section) or (pageLabel and not entry.tabLabel) or (pageName and not entry.tab) then
        probe = setmetatable({
            section  = entry.section or section,
            tabLabel = entry.tabLabel or pageLabel,
            tab      = entry.tab or pageName,
        }, { __index = entry })
    end
    local mini = { words = {}, cons = {}, raw = {}, vocab = {} }
    IndexEntry(mini, probe)
    for _, acc in ipairs(compiled.words) do
        local ok = false
        for n in pairs(acc.words) do
            if mini.words[n] then ok = true break end
        end
        if not ok then
            for id in pairs(acc.cons) do
                if mini.cons[id] then ok = true break end
            end
        end
        if not ok then
            for w in pairs(acc.raw) do
                if mini.raw[w] then ok = true break end
            end
        end
        if not ok then return false end
    end
    return true
end

-- ------------------------------------------------------------
-- THE TWO ANSWERS
-- ------------------------------------------------------------

-- Every entry that answers EVERY word: { [entry] = score }, and how many.
-- `scope(entry)`, when given, keeps only the entries it answers true for.
function Search:MatchEntries(compiled, scope)
    local out, count = {}, 0
    if not compiled then return out, 0 end
    local ix = compiled.index
    local first = true
    for _, acc in ipairs(compiled.words) do
        local hits = WordHits(ix, acc)
        if first then
            for entry, s in pairs(hits) do
                if not scope or scope(entry) then out[entry] = s end
            end
            first = false
        else
            for entry, s in pairs(out) do
                local h = hits[entry]
                if h then out[entry] = s + h else out[entry] = nil end
            end
        end
        if next(out) == nil then return out, 0 end
    end
    for _ in pairs(out) do count = count + 1 end
    return out, count
end

-- Home's ranked list. Entries that answer every word come first; only when no
-- entry does, entries that answer some of the words, most words first.
function Search:RankedMatches(query)
    local compiled = self:CompileQuery(query)
    if not compiled then return {} end
    local ix = compiled.index
    local nWords = #compiled.words

    local score, matched = {}, {}
    for _, acc in ipairs(compiled.words) do
        for entry, s in pairs(WordHits(ix, acc)) do
            score[entry] = (score[entry] or 0) + s
            matched[entry] = (matched[entry] or 0) + 1
        end
    end

    local anyAll = false
    for entry, m in pairs(matched) do
        if m >= nWords and not entry.isSection then anyAll = true break end
    end

    local list = {}
    for entry, s in pairs(score) do
        -- A card's own entry (isSection) has no control to show inline.
        if not entry.isSection and (not anyAll or matched[entry] >= nWords) then
            local label = type(entry.label) == "string" and Fold(entry.label) or ""
            if find(label, compiled.text, 1, true) then s = s + PHRASE_BONUS end
            list[#list + 1] = { entry = entry, score = s, words = matched[entry] }
        end
    end
    sort(list, function(a, b)
        if a.words ~= b.words then return a.words > b.words end
        if a.score ~= b.score then return a.score > b.score end
        return (a.entry.id or 0) < (b.entry.id or 0)
    end)

    local out = {}
    for i, r in ipairs(list) do out[i] = r.entry end
    return out
end

-- For the tests: the pure pieces, so their rules can be pinned on their own.
Search._MatchInternals = {
    Fold = Fold, Norm = Norm, Words = Words, KeyWords = KeyWords, Dist = Dist,
    ResetConcepts = function() conceptsOf = nil end,
}
