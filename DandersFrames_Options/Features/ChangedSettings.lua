-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames

-- ============================================================
-- CHANGED-SETTINGS LEDGER
-- One generated page listing every setting in the CURRENT mode whose stored
-- value differs from the shipped default, grouped by the page that owns it,
-- with a click-to-jump on every row and a plain-text version to paste into a
-- support thread.
--
-- WHY IT IS A REPORT, NOT A PAGE OF CONTROLS
-- -----------------------------------------
-- Nothing here is cached and nothing here edits. The whole content is rebuilt
-- on every page Refresh, because a Refresh is already the moment the answer can
-- change (an undo, a group reset, a profile switch, an edit on another page
-- followed by navigating back). A cached ledger would be a report that quietly
-- describes a configuration the user no longer has, which is worse than no
-- report at all.
--
-- WHERE THE TWO HALVES COME FROM
-- ------------------------------
--   * WHICH keys exist, what they are CALLED and which page owns them --
--     the settings SEARCH registry (Features/Search.lua). It is the only index
--     in the addon that maps a db key to a human label and a home page, and it
--     is built by re-running every page's builder, so it cannot drift from what
--     the pages actually show.
--   * WHETHER a key is modified and what the shipped value is --
--     DF.Defaults (DandersFrames/Core/Defaults.lua), through DiffKeys, which
--     owns the float epsilon, the deep table comparison and the auto-profile
--     overlay unwrap. None of that is re-implemented here.
--
-- ☠ THE KNOWN GAP IS STATED ON THE PAGE, NOT HIDDEN. The registry only carries
-- a key for a control the shared factories BOUND to one (checkbox / slider /
-- dropdown / colour picker with a dbKey). A control wired through a closure
-- get/set -- Border Alpha is the one users hit -- and an ordered list are both
-- invisible to it, so they are invisible here. A ledger that silently omits
-- them would be read as "nothing else changed", so the page carries a footnote
-- saying otherwise rather than quietly under-reporting.
--
-- ☠ THIS PAGE IS SKIPPED BY THE REGISTRY BUILD (page.skipSearchIndex, honoured
-- in Search:BuildFullRegistry). Two reasons, and both are real:
--   1. RECURSION. Building the registry re-runs every page's builder; this
--      builder asks for the registry. Without the skip that is unbounded.
--   2. RE-ENTRANCY. Even one level deep would be wrong: a nested Refresh on
--      THIS page retires the widgets the outer Refresh already placed
--      (BuildPage's DoBuild resets self.children), so the outer pass would go
--      on appending to a list whose earlier entries are already in the trash.
-- It also happens to satisfy "the ledger must not index its own rows", though
-- that falls out for free -- labels and buttons never register.
-- ============================================================

local L = DF.L

local type, pairs, ipairs, tostring = type, pairs, ipairs, tostring
local format, floor, abs = string.format, math.floor, math.abs
local tsort, tconcat = table.sort, table.concat

local ChangedSettings = {}
DF.ChangedSettings = ChangedSettings

-- The page id, in the existing profiles-page naming style (profiles_auto,
-- profiles_manage, profiles_importexport). Declared here so the page builder,
-- the always-accessible whitelist and any future cross-link agree on one
-- spelling.
ChangedSettings.PAGE_ID = "profiles_changed"

-- ============================================================
-- VALUE FORMATTING
-- ============================================================

-- Is this the addon's colour shape? Both spellings are in the profile: the
-- shipped defaults are {r,g,b[,a]} tables, and a couple of older imported
-- values are plain {1,1,1} arrays. Anything else is not a colour.
local function ColorChannels(v)
    if type(v.r) == "number" and type(v.g) == "number" and type(v.b) == "number" then
        return v.r, v.g, v.b
    end
    if type(v[1]) == "number" and type(v[2]) == "number" and type(v[3]) == "number" then
        return v[1], v[2], v[3]
    end
    return nil
end

local function Channel255(c)
    if c < 0 then c = 0 elseif c > 1 then c = 1 end
    return floor(c * 255 + 0.5)
end

-- ============================================================
-- MEDIA PATHS
-- ============================================================

-- File extensions the media library's own art carries. Stripped from a filename
-- fallback because "Minimalist" and "Minimalist.tga" say the same thing to a
-- reader and only one of them fits in a cell.
local MEDIA_EXT = { tga = true, blp = true, ttf = true, otf = true, ogg = true, mp3 = true }

-- Is this string a MEDIA PATH rather than a setting value, and if so, what does
-- a person call it?
--
-- ☠ THE REPORTED BUG: a statusbar texture is STORED as its full path, so a
-- changed one printed as
--   Interface\AddOns\DandersFrames\Media\Textures\DF_Smooth.tga
-- in a two-column row 244 pixels wide -- which ran off the right of the page.
--
-- ⚠ THE TEST IS A BACKSLASH (or an "Interface/" prefix), NOT "contains a
-- slash". Settings hold user-authored strings too, and the Text Designer's
-- formats are full of forward slashes -- "%cur/%max" is a setting, not a file,
-- and shortening it to "%max" would be a report that lies about the value. No
-- WoW media path lacks a backslash, so the narrower test costs nothing.
--
-- The NAME comes from DF:GetTextureNameFromPath, which is the addon's existing
-- path->display-name resolver (it walks the LibSharedMedia statusbar list, with
-- separator, case and Interface-prefix normalisation, and falls back to the bare
-- filename). Not re-implemented here: a second resolver would be free to
-- disagree with the dropdown the user picked the texture from, and the whole
-- point of the ledger is that it names things the way the pages do.
--
-- Returns nil for anything that is not a path, so the caller falls through to
-- the string as stored.
local function MediaName(v)
    if not (v:find("\\", 1, true) or v:find("^[Ii]nterface/")) then return nil end

    local name = DF.GetTextureNameFromPath and DF:GetTextureNameFromPath(v) or nil
    if type(name) ~= "string" or name == "" then
        -- Fonts, borders and sounds do not go through that resolver, and an
        -- unregistered texture falls out of the bottom of it. The last segment
        -- of the path is what a person would call the file either way.
        name = v:match("([^/\\]+)$")
    end
    if type(name) ~= "string" or name == "" then return nil end

    -- The resolver's own last resort hands back the filename WITH its extension,
    -- and this cannot tell that apart from a registered name -- so the strip runs
    -- on both. It is a no-op on a real display name ("Blizzard Raid Bar" ends in
    -- no extension) and only ever fires on something that looks like a file.
    local base, ext = name:match("^(.+)%.(%w+)$")
    if base and base ~= "" and MEDIA_EXT[ext:lower()] then name = base end

    return name
end

-- One setting value -> one short display string.
--
--   numbers        as-is: whole numbers plain, fractions to six significant
--                  figures (%.6g, which prints 0.35 as "0.35" and 26 as "26"
--                  without inventing trailing zeros on either).
--   booleans       On / Off
--   media paths    the name the media dropdown shows, never the path
--   colour tables  #RRGGBB
--   other tables   an ellipsis -- a nested block (the aura designer's, a
--                  position) has no honest one-line form, and pretending
--                  otherwise reads worse than admitting it.
--
-- ☠ THE ELLIPSIS IS THREE DOTS, NOT U+2026. It used to be the single character
-- on the page and ASCII only in the copy block, and the page half rendered as an
-- EMPTY BOX in game: the settings panel draws in the user's Settings Font and
-- the shipped default ("DF Roboto SemiBold") carries Latin, digits and
-- punctuation and nothing else -- the same reason the ledger's arrow had to
-- become an icon. An arrow has art to fall back on; an ellipsis does not need
-- any, because "..." says the identical thing in a glyph every font has.
--
-- `ascii` therefore no longer changes this branch -- it is now only about the
-- localised words (On/Off), which the copy block drops so a pasted report reads
-- the same in a support thread whatever locale wrote it.
-- NaN is named rather than run through %g, whose output for it is
-- platform-dependent and would make the tests answer differently per machine.
function ChangedSettings.FormatValue(v, ascii)
    if v == nil then return "-" end

    local t = type(v)

    if t == "boolean" then
        if ascii then return v and "On" or "Off" end
        return v and L["On"] or L["Off"]
    end

    if t == "number" then
        if v ~= v then return "nan" end
        if v == math.huge then return "inf" end
        if v == -math.huge then return "-inf" end
        -- Whole numbers print as integers: %.6g turns 1000000 into "1e+06",
        -- which is not what a setting worth a million (a spell id, a frame
        -- level) should look like.
        if v == floor(v) and abs(v) < 1e15 then return format("%d", v) end
        return format("%.6g", v)
    end

    -- ⚠ THE SHORT FORM IN BOTH, `ascii` or not. The copy block is pasted into a
    -- support thread and read by someone who did not write it, and an 80-column
    -- texture path is no more use to them than it was on the page -- what they
    -- want to know is which texture, which is the name.
    if t == "string" then return MediaName(v) or v end

    if t == "table" then
        local r, g, b = ColorChannels(v)
        if r then return format("#%02X%02X%02X", Channel255(r), Channel255(g), Channel255(b)) end
        return "..."
    end

    return tostring(v)
end

-- ============================================================
-- THE DIFF WALK -- PURE
-- Everything below takes plain tables and returns plain tables. No frame, no
-- DF read, no GUI read: the shape the settings page renders is decided here so
-- it can be asserted headlessly (Tools/mover-tests/test_changed_settings.lua).
-- ============================================================

-- Every distinct db key the registry BINDS, in registry order.
--
-- A registry entry with only a searchKey is a custom control the factories
-- never bound to a db key (SettingsWidgets' keyless checkbox); there is no
-- stored value to compare, so it is not a ledger row.
function ChangedSettings.BoundKeys(registry)
    local keys, seen = {}, {}
    for i = 1, #(registry or {}) do
        local e = registry[i]
        local key = e and e.dbKey
        if type(key) == "string" and not seen[key] then
            seen[key] = true
            keys[#keys + 1] = key
        end
    end
    return keys
end

-- registry + nav order + a DiffKeys result -> the report the page renders.
--
--   registry   the search registry array (entries carry dbKey/label/tab/
--              tabLabel/section)
--   pageOrder  tab names in NAV order; anything not in it sorts after
--              everything that is, in registry order, so a page that is hidden
--              from the sidebar still reports rather than vanishing
--   diffMap    exactly DF.Defaults:DiffKeys' shape -- { [key] = { current,
--              default } } for the MODIFIED keys only
--
-- Returns { count = <number of settings>, groups = { { tab, label, rows } } }.
--
-- ⚠ ONE ROW PER SETTING, NOT PER REGISTRATION. The same db key can be
-- registered from more than one page (and is), so counting registrations would
-- report "9 settings differ" over 7 settings and list two of them twice. The
-- first registration in NAV order wins, which is also the page a user would
-- most naturally look on.
function ChangedSettings.Collect(registry, pageOrder, diffMap)
    local rank = {}
    for i = 1, #(pageOrder or {}) do
        local tab = pageOrder[i]
        if rank[tab] == nil then rank[tab] = i end
    end

    -- Registry order is build order, which is page order, which is not nav
    -- order -- BuildFullRegistry walks GUI.Pages with pairs(). So the entries
    -- are bucketed first and the buckets sorted afterwards; picking "the first
    -- registration" off the raw registry would pick an arbitrary page.
    local hits = {}
    for i = 1, #(registry or {}) do
        local e = registry[i]
        local key = e and e.dbKey
        local diff = (type(key) == "string" and diffMap) and diffMap[key] or nil
        if diff then
            local tab = e.tab or "?"
            local r = rank[tab] or (1e6 + i)
            local prev = hits[key]
            if not prev or r < prev.rank then
                hits[key] = {
                    key     = key,
                    rank    = r,
                    seq     = i,
                    tab     = tab,
                    label   = e.label or key,
                    tabLabel = e.tabLabel or tab,
                    section = e.section,
                    current = diff.current,
                    default = diff.default,
                }
            end
        end
    end

    local flat = {}
    for _, hit in pairs(hits) do flat[#flat + 1] = hit end
    -- seq breaks the tie inside a page, so rows read in the order the page
    -- itself lays its controls out. pairs() above is unordered, so without it
    -- the row order would vary run to run.
    tsort(flat, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.seq < b.seq
    end)

    local groups, byTab = {}, {}
    for i = 1, #flat do
        local hit = flat[i]
        local g = byTab[hit.tab]
        if not g then
            g = { tab = hit.tab, label = hit.tabLabel, rows = {} }
            byTab[hit.tab] = g
            groups[#groups + 1] = g
        end
        g.rows[#g.rows + 1] = {
            key     = hit.key,
            label   = hit.label,
            section = hit.section,
            current = hit.current,
            default = hit.default,
        }
    end

    return { count = #flat, groups = groups }
end

-- The report as a block of plain text, for the copy popup.
--
-- ⚠ THE SCAFFOLDING IS DELIBERATELY ENGLISH AND ASCII -- the title, the count
-- sentence, "default:", and the value spellings (no arrow glyph, no ellipsis).
-- This block exists to be pasted into a support thread and read by someone who
-- is probably not the person who wrote it, so its structure has to survive any
-- client and any forum. That does mean the count sentence here and the L[] one
-- on the page are the same sentence twice; they are not the same audience.
--
-- The LABELS are whatever the user's locale gave them, and so are NOT
-- guaranteed ASCII. That is on purpose: they cannot be translated back from
-- here, and a German user pasting German labels is exactly what a
-- German-speaking helper wants to read.
--
--   opts.title      first line (defaults to the addon name)
--   opts.modeLabel  appended to the title line in brackets
function ChangedSettings.BuildText(report, opts)
    opts = opts or {}
    local out = {}

    local title = opts.title or "DandersFrames"
    -- The version rides in the header: this text ends up in bug reports, and
    -- "what version are you on" is the first question it can pre-answer.
    if opts.version then title = title .. " v" .. tostring(opts.version) end
    if opts.modeLabel then title = title .. " (" .. opts.modeLabel .. ")" end
    out[#out + 1] = title

    if not report or report.count == 0 then
        out[#out + 1] = "0 settings differ from defaults."
        return tconcat(out, "\n")
    end

    out[#out + 1] = format("%d settings differ from defaults.", report.count)
    out[#out + 1] = ""

    for _, group in ipairs(report.groups) do
        for _, row in ipairs(group.rows) do
            out[#out + 1] = format("%s > %s: %s (default: %s)",
                tostring(group.label),
                tostring(row.label),
                ChangedSettings.FormatValue(row.current, true),
                ChangedSettings.FormatValue(row.default, true))
        end
    end

    return tconcat(out, "\n")
end

-- ============================================================
-- LIVE WIRING
-- The two reads the pure half deliberately does not do.
-- ============================================================

-- Tab names in the order the sidebar shows them: categories in CategoryOrder,
-- pages in the order they were added to each category.
--
-- A page created `hidden` is never added to cat.children, so it is absent here
-- -- Collect sorts anything absent to the end rather than dropping it.
function ChangedSettings:PageOrder(GUI)
    local order = {}
    if not GUI or not GUI.Categories then return order end
    for _, catName in ipairs(GUI.CategoryOrder or {}) do
        local cat = GUI.Categories[catName]
        for _, btn in ipairs((cat and cat.children) or {}) do
            if btn.tabName then order[#order + 1] = btn.tabName end
        end
    end
    return order
end

-- The whole report for the mode currently selected in the settings window.
--
-- Returns `nil, reason` when it cannot answer, and the page renders the reason
-- as a one-line hint rather than as "nothing changed" -- an empty ledger and an
-- unbuilt one look identical on screen and mean opposite things.
--   "combat"   a registry build is due and we will not run one mid-fight
--   "building" a budgeted build is under way; the page refreshes itself when it
--              lands (see the waiter below)
--   "unbuilt"  the panel cannot produce a registry at all yet
function ChangedSettings:BuildReport(GUI)
    local Search = DF.Search
    if not Search then return nil, "unbuilt" end

    -- ⚠ THE FLAG IS CHECKED AS WELL AS THE STALENESS, and it is not redundant
    -- belt-and-braces. A build in flight has already emptied Search.Registry, so
    -- today RegistryIsStale answers true for both -- but the thing that must
    -- never happen here is reading a HALF-FILLED index and printing it as the
    -- user's configuration, and that deserves to be said rather than inferred
    -- from another function's implementation.
    if Search:RegistryIsStale() or Search.RegistryBuilding then
        -- ☠ NO REGISTRY BUILD IN COMBAT. Building it re-runs all ~34 page
        -- builders -- the same reason the search box refuses to search mid-fight
        -- -- and a report is never worth a hitch in the middle of a pull. An
        -- ALREADY-built registry costs nothing, so the guard is on the build,
        -- not on the page: open the ledger before the pull and it keeps working
        -- through it.
        if InCombatLockdown() then return nil, "combat" end

        -- ☠ BUDGETED, NOT SYNCHRONOUS. This call is what "the ledger lags like
        -- crazy when opening" was: a cold registry means ~34 page builders, and
        -- running them inside this page's own build put every one of them in the
        -- frame that drew the page. Now the page renders its "building" state
        -- immediately and rebuilds itself when the last slice lands.
        --
        -- ⚠ THE WAITER RE-CHECKS WHAT IS ON SCREEN. A build takes several
        -- frames, and the user can navigate away inside them; refreshing the
        -- page they left would rebuild a page nobody is looking at, and
        -- RefreshCurrentPage would rebuild the WRONG one.
        Search:EnsureRegistryAsync(function(ok)
            if not ok then return end
            if not (GUI and GUI.CurrentPageName == ChangedSettings.PAGE_ID) then return end
            local page = GUI.Pages and GUI.Pages[ChangedSettings.PAGE_ID]
            if page and page.Refresh and page:IsShown() then page:Refresh() end
        end)
        -- Unconditionally: EnsureRegistryAsync defers every path, so there is no
        -- arm of it that can hand this call a usable registry before it returns.
        return nil, "building"
    end

    local registry = Search.Registry
    if not registry or #registry == 0 then return nil, "unbuilt" end

    local mode = (GUI and GUI.SelectedMode) or "party"
    local db = DF.db and DF.db[mode]
    if not db then return nil, "unbuilt" end

    -- ☠ DiffKeys, not a per-key IsModified plus a db read. It is the same
    -- comparison either way, but DiffKeys hands back the STORED value -- which
    -- is not db[key] while a runtime auto profile is active, because DF.db.raid
    -- is then a read-through proxy over DF._realRaidDB. Reading the proxy would
    -- print the layout's override as the user's setting.
    local diffMap = DF.Defaults:DiffKeys(db, ChangedSettings.BoundKeys(registry))
    return ChangedSettings.Collect(registry, self:PageOrder(GUI), diffMap)
end
