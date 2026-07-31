local addonName, DF = ...

-- Local caching of frequently used globals for performance
local pairs, ipairs, type, tonumber, tostring = pairs, ipairs, type, tonumber, tostring
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max
local format, sub, len, byte = string.format, string.sub, string.len, string.byte

-- Expose addon table globally
_G[addonName] = DF

-- Version - read from TOC file
local GetAddOnMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
DF.VERSION = GetAddOnMetadata(addonName, "Version") or "Unknown"

-- Localization
DF.L = LibStub("AceLocale-3.0"):GetLocale("DandersFrames")
local L = DF.L

-- ============================================================
-- LOCALE REFRESH REGISTRY
-- Some modules build label/option tables at file scope, which reads
-- L["..."] before the languageOverride overlay is applied at
-- ADDON_LOADED (see the overlay in the ADDON_LOADED handler below).
-- Those file-scope reads would otherwise freeze on the enUS baseline.
-- A module registers a rebuild fn here; Core re-runs them all once,
-- right after the overlay, so the tables pick up the active locale.
-- ============================================================
DF._localeRefreshers = DF._localeRefreshers or {}
function DF:RegisterLocaleRefresh(fn)
    DF._localeRefreshers[#DF._localeRefreshers + 1] = fn
end
function DF:RunLocaleRefreshers()
    for i = 1, #DF._localeRefreshers do
        local ok, err = pcall(DF._localeRefreshers[i])
        if not ok and DF.DebugError then
            DF:DebugError("SCRIPT", "LocaleRefresh failed: %s", tostring(err))
        end
    end
end

-- Locale warnings: silent by default (see Locales/enUS.lua for rationale).
-- Call DF:SetLocaleWarnings(true) — or use /df debug localewarn — to enable
-- error-handler warnings on missing L["..."] keys for the current session.
DF.localeWarningsEnabled = false
function DF:SetLocaleWarnings(enabled)
    if enabled then
        setmetatable(DF.L, { __index = function(self, key)
            rawset(self, key, key)
            geterrorhandler()(("AceLocale-3.0: DandersFrames: Missing entry for '%s'"):format(tostring(key)))
            return key
        end })
    else
        setmetatable(DF.L, { __index = function(self, key)
            rawset(self, key, key)
            return key
        end })
    end
    DF.localeWarningsEnabled = enabled and true or false
end

-- Debug flags
-- ☠ (Removed) DF.debugEnabled. It was WRITE-ONLY: declared here and assigned in
-- three places, but read nowhere once consumers moved to DF:DebugActive(category)
-- — which is per-category, so a single global boolean could not express the
-- question anyway. Three comments in the addon still record "was gated on
-- DF.debugEnabled". A flag that is maintained but never consulted is worse than
-- no flag: it reads as a live gate. Ask DF:DebugActive(cat) — there is no global
-- accessor, because no consumer ever wanted one (DebugConsole:IsEnabled() was
-- added for that and removed unused).
DF.demoMode = false
DF.demoPercent = 1
DF.initialized = false  -- Set to true after frames are created and ready

-- Returns true if the current profile's partyEnabled/raidEnabled flags
-- differ from the state captured when the addon loaded. A reload is
-- required to actually create or destroy frame headers, so callers use
-- this to decide whether to prompt the user.
function DF:EnableFlagsDifferFromLoaded()
    if not DF.db then return false end
    local curParty = DF.db.partyEnabled ~= false
    local curRaid  = DF.db.raidEnabled  ~= false
    return curParty ~= (DF.loadedPartyEnabled ~= false)
        or curRaid  ~= (DF.loadedRaidEnabled  ~= false)
end

-- Show the standard "reload to apply enable changes" popup if the flags
-- have diverged from the loaded state. Safe to call from any context.
function DF:PromptReloadIfEnableFlagsChanged()
    if not DF:EnableFlagsDifferFromLoaded() then return end
    if not DF.ShowPopupAlert then return end
    local L = DF.L
    DF:ShowPopupAlert({
        title = L["Reload Required"],
        message = L["The new profile changes which frame modes are enabled. A UI reload is required to apply this.\n\nReload now?"],
        buttons = {
            { label = L["Reload Now"], onClick = function() ReloadUI() end },
            { label = L["Later"] },
        },
    })
end

-- ============================================================
-- DEBUG SLASH COMMAND REGISTRY
-- ============================================================
-- Every debug slash command declares itself here instead of setting its
-- SLASH_* global directly. The registry is what `/df debug` prints, so the
-- listing can never drift from reality, and dev-only commands are simply not
-- registered on release builds (the SlashCmdList handler still exists but no
-- slash alias maps to it). RELEASE_CHANNEL is stamped by CI in Changelog.lua,
-- which loads before this file.
DF.DebugCommands = {}

function DF:IsDevBuild()
    return DF.RELEASE_CHANNEL ~= "release"
end

-- key = the SlashCmdList key; desc = one-liner for /df debug; devOnly = only
-- register on alpha/beta builds; ... = the slash alias(es) ("/dfauras", ...).
-- The handler stays a plain `SlashCmdList[key] = function` at the call site.
-- The command's NAME is derived by stripping "/df" from its first alias, so
-- "/dfauraexp" becomes "auraexp" and is typed as "/df debug auraexp".
--
-- ☠ THE STANDALONE /dfXXX BINDS ARE NO LONGER REGISTERED. They used to be, and
-- the /df debug listing carried them in grey as a second form. That put ~25 DF
-- commands into the GLOBAL slash namespace — where they collide with other
-- addons and clutter every slash autocomplete — to document a spelling nobody
-- needed twice. One documented form now: "/df debug <command>".
--
-- The one exception is an alias that is NOT /df-prefixed: "/rl" has no "/df"
-- form to fall back to, so a bind is the only way to reach it. That is the rule
-- below, not a hardcoded name — add another such alias and it keeps working.
--
-- ☠ "/df <name>" (no "debug") does NOT answer for diagnostics. This comment used to
-- claim it did, "unlisted, so macros and muscle memory survive" — that was the intent
-- at the time, and THE GATE further down (search: "☠ THE GATE") was written later and
-- deliberately closed it: anything that is not an everyday command and did not arrive
-- via "/df debug" opens the settings window instead. The gate is the behaviour that
-- ships; this note is kept as a warning because the changelog and CLAUDE.md both
-- inherited the old claim and had to be corrected. A diagnostic is "/df debug <name>".
--
-- A derived name that collides with a hand-written branch in the /df debug dispatcher
-- loses: the dispatcher is checked first and the registry is the fallback. The
-- three real collisions (auras, dispel, headers) are merged into single
-- commands rather than left to shadow each other silently.
DF.DebugSlashBySub = {}

function DF:RegisterDebugSlash(key, desc, devOnly, ...)
    local entry = { key = key, desc = desc, dev = devOnly, cmds = { ... } }
    entry.active = not devOnly or DF:IsDevBuild()
    local first = select("#", ...) > 0 and (select(1, ...)) or nil
    entry.sub = type(first) == "string" and first:match("^/df(.+)$") or nil
    table.insert(DF.DebugCommands, entry)
    if entry.active then
        local n = 0
        for i = 1, select("#", ...) do
            local alias = select(i, ...)
            if type(alias) == "string" then
                local word = alias:match("^/df(.+)$")
                if word then
                    -- EVERY /df-prefixed alias routes, not just the first: a
                    -- command registered with both a long and a short spelling
                    -- must answer to both, and keying only off entry.sub
                    -- silently dropped every alias after the first.
                    DF.DebugSlashBySub[word] = key
                else
                    -- No "/df <name>" route to fall back on (e.g. "/rl"), so a real
                    -- slash bind is the only way to reach it.
                    n = n + 1
                    _G["SLASH_" .. key .. n] = alias
                end
            end
        end
    end
end

-- ============================================================
-- WHERE A COMMAND LIVES
-- ============================================================
-- Everyday commands keep the short "/df <name>" form and are documented by
-- "/df help". Everything else is a diagnostic and is typed "/df debug <name>",
-- documented by "/df debug". ONE table decides, so the listing, the Siblings
-- footer and the help text can never disagree about where a command lives —
-- which is exactly how the old build ended up listing everyday commands under
-- /df debug and debug commands under /df help.
DF.EVERYDAY_COMMANDS = {
    help = true, console = true, users = true, reset = true, resetgui = true,
    test = true, hide = true, lock = true, unlock = true, raidlock = true,
    raidunlock = true, clearoverride = true,
}

--- The typeable path for a command word, e.g. "dispel" -> "/df debug dispel".
function DF:CmdPath(word)
    return (DF.EVERYDAY_COMMANDS[word] and "/df " or "/df debug ") .. word
end

-- (Removed) DF:IsDebugCommand. Written so "the listing, the Siblings footer and the
-- help text can never disagree", but each of those was subsequently rewritten to
-- read what it needs directly — the listing walks the two registries itself and
-- Out:Siblings uses DF:CmdPath — leaving it with zero callers.

-- ============================================================
-- /df SUBCOMMAND REGISTRY
-- ============================================================
-- The /dfXXX half of "/df debug" is generated from DebugCommands above, so it
-- cannot drift. The /df SUBCOMMAND half used to be eight hand-written print()
-- lines carrying the comment "keep in sync with this handler" — and it had
-- drifted BOTH ways: it advertised "/df debug auratimer", which was never
-- implemented, while omitting ~45 subcommands that were (pixelcheck, gapcheck,
-- navprobe, idgate, ppdump, zorder, localewarn, every test*, …).
--
-- This registry is now the single source for that listing. Adding a branch to
-- the dispatcher without registering it here means it stays invisible, so
-- register alongside the branch.
--
-- `args` documents the argument shape for the listing ("<sec>", "on|off"),
-- nil for bare commands. `dev` hides it on release builds, matching the slash
-- half. Order is preserved for display — grouped, not alphabetical.
DF.DebugSubCommands = {}

-- ☠ `dev` USED TO MEAN "hidden from the list" AND NOTHING ELSE.
-- The slash half really does block: RegisterDebugSlash sets entry.active and
-- skips both the /df route and the SLASH_* globals, so a dev command has no
-- reachable token on release. The sub() half only bucketed the row into a "dev"
-- section of the printed listing — every branch stayed fully runnable via
-- "/df debug <word>", including ones that force debug art onto LIVE frames
-- (raidbg, ppbadge) and one that switches on locale warning spam (localewarn).
-- This lookup is what the dispatcher gate consults so the two halves now match.
DF.DEBUG_SUB_DEV = {}

-- ============================================================
-- CHAT OUTPUT HOUSE STYLE  (DF:Out)
-- ============================================================
-- Every slash command prints through this. Before it there were SEVEN competing
-- conventions across ~1000 print() calls — "DandersFrames:" in five different
-- colours, plus [DF SecureSort], [DF Headers], [DFRange], [DF Flat Debug],
-- "DF PerfTest:" and some with no prefix at all — and banner rules in three
-- different widths.
--
-- The shape (one title line, indented sections, a footer of what to type next):
--
--   DandersFrames · Pinned Frames          <- brand purple + module, ONCE
--     Module state                         <- section, gold
--       initialized: no                    <- field, 4-space indent
--     Sets (3 configured, 2 enabled)       <- section with a count
--       1  Kesara — 2 units, enabled
--       … 37 more — /df debug pinned map full    <- capped list + escape hatch
--     More: /df debug pinned info · /df debug pinned test
--
-- ☠ TWO RULES THAT ARE EASY TO GET WRONG
-- 1. The chat font is PROPORTIONAL. Space-padded columns DO NOT line up in game
--    — they drift the moment a value is a different width. Use "key: value" and
--    indentation for structure, never padding for alignment.
-- 2. Colour marks STATUS, not datatype. `false` is not automatically red:
--    "debug: off" is neutral, "handler missing" is bad. Red must mean "look
--    here" or it means nothing. That confusion is why the old SecureSort dump
--    showed inCombat:no green and handlerExists:false red — same shape,
--    opposite colours.
DF.OUT = {
    BRAND   = "|cff7373f2",   -- the addon name, once per output
    TITLE   = "|cffffffff",   -- the module name — must OUTRANK SECTION, see below
    SECTION = "|cffffcc00",   -- a group heading
    GOOD    = "|cff40d073",   -- working, active, present
    BAD     = "|cffff6b5e",   -- A PROBLEM. not merely "false"
    WARN    = "|cffffa832",   -- works, but worth knowing
    NEUTRAL = "|cff909090",   -- off, unused, n/a — NOT a fault
    CMD     = "|cffeda55f",   -- something you can type
}
local O = DF.OUT
-- ☠ CASE-INSENSITIVE ON PURPOSE. DF.OUT is keyed in caps, but roughly fifty call
-- sites across Core, Bars, Headers, ColorPicker, AutoProfiles and TextDesigner pass
-- "good"/"bad"/"warn" in lower case — several files mix both spellings within
-- themselves, so it is a typo class rather than a second convention. A miss used to
-- resolve to "", and because `status` was still truthy the Out writers appended a
-- bare "|r" anyway: the line rendered with no colour and nothing looked broken. That
-- silently killed the colour coding in the very commands that were rewritten to add
-- it. Normalising here fixes every site at once; fixing them individually would only
-- last until the next one is written.
local function tone(t) return O[t] or (t and O[t:upper()]) or "" end

local Out = {}
Out.__index = Out

-- The leading rule. Run two commands in a row and the previous output's footer
-- sits flush against the next title with nothing between them — the eye has no
-- edge to catch when scrolling chat back. One short rule fixes that for one line.
--
-- ☠ FIXED WIDTH ON PURPOSE. A full-width rule WRAPS on a narrow chat frame and
-- becomes two ragged lines; that is what makes the old
-- "========================================" banners look broken, not the idea
-- of a rule. Do not "improve" this by making it span the frame — the frame width
-- is not knowable here, and this fits any usable chat size.
--
-- ☠ EM DASH (U+2014) ON PURPOSE, not a box-drawing character. The em dash is
-- already used ~200 times across the addon and is confirmed to render in the
-- chat frame; U+2500 and friends are NOT used anywhere, and WoW's default fonts
-- do not reliably carry box-drawing glyphs — a missing glyph here would put a
-- tofu box above every single command's output.
local RULE = O.NEUTRAL .. ("—"):rep(14) .. "|r"

--- Start an output block. Prints a separator rule and the title line immediately;
--- a command with nothing further to say is simply a title and stops there (the
--- old "one-liner" shape is this with no body, not a separate format).
--- @param module string  the subsystem name, e.g. "Pinned Frames"
--- @param suffix string|nil  trailing detail for the title, e.g. a unit token
--- ☠ The module name is UPPERCASED and printed in TITLE (pure white), not left as
--- sentence case. Chat has no bold and no font-size control, so the only levers
--- for weight are capitalisation and contrast — and the title needs both, because
--- without them it loses to its own children: gold SECTION heads at sentence case
--- were visually louder than the title above them, inverting the hierarchy. Pure
--- white outranks gold on a dark ground, and caps carry the rest.
--- The suffix stays lowercase and NEUTRAL so it reads as an aside, not a second title.
function DF:Out(module, suffix)
    print(RULE)
    print(O.BRAND .. "DandersFrames|r " .. O.NEUTRAL .. "·|r "
        .. O.TITLE .. (module or ""):upper() .. "|r"
        .. (suffix and (" " .. O.NEUTRAL .. suffix .. "|r") or ""))
    return setmetatable({ module = module }, Out)
end

--- A group heading. `count` is optional trailing detail, e.g. "3 configured".
function Out:Section(name, count)
    print("  " .. O.SECTION .. name .. "|r"
        .. (count and (" " .. O.NEUTRAL .. "(" .. count .. ")|r") or ""))
    return self
end

--- key: value. `status` is one of the DF.OUT tone names ("GOOD"/"BAD"/"WARN"/
--- "NEUTRAL"); omit it for an uncoloured value. Booleans render as yes/no.
function Out:Field(key, value, status)
    if type(value) == "boolean" then value = value and "yes" or "no" end
    print("    " .. key .. ": " .. tone(status) .. tostring(value) .. (status and "|r" or ""))
    return self
end

--- A free line inside a section, already indented. `status` tones the whole line.
function Out:Line(text, status)
    print("    " .. tone(status) .. text .. (status and "|r" or ""))
    return self
end

--- A list item: "  1  Kesara — 2 units, enabled".
function Out:Item(label, detail, status)
    print("    " .. label
        .. (detail and (" " .. O.NEUTRAL .. "—|r " .. tone(status) .. detail .. (status and "|r" or "")) or ""))
    return self
end

--- Print at most `max` items, then a tail pointing at the full form. Unbounded
--- dumps scroll the useful part off screen and hit chat's backlog cap, so every
--- list longer than a screenful goes through here.
--- @param items table  array of strings (already formatted)
--- @param max number
--- @param fullCmd string|nil  the command that prints all of them
function Out:More(items, max, fullCmd)
    local n = #items
    for i = 1, math.min(n, max) do print("    " .. items[i]) end
    if n > max then
        print("    " .. O.NEUTRAL .. "… " .. (n - max) .. " more|r"
            .. (fullCmd and (" " .. O.NEUTRAL .. "—|r " .. O.CMD .. fullCmd .. "|r") or ""))
    end
    return self
end

-- ============================================================
-- SIBLING COMMANDS — the footer every dump ends with
-- ============================================================
-- ☠ A REGISTRY, NOT A HAND-WRITTEN LINE PER DUMP, because hand-written footers
-- went wrong three separate ways: some dumps never got one; /df debug secure listed
-- two of its sixteen; and /df debug dispel's sat after an early `return`, so it
-- printed only when the unit HAD debuffs — the one case where you did not need
-- it. One table, one call, and Siblings takes no state so it is safe to call
-- from an early return.
--
-- Key is the /df debug word. Entries are what you can type after it; "<unit>" and
-- friends are ARGUMENT SHAPES rather than literal subcommands, which is what a
-- reader actually wants to see.
DF.COMMAND_SIBLINGS = {
    auras     = { "<unit>" },
    auradata  = { "<unit>" },
    dispel    = { "<unit>", "ids", "render" },
    idgate    = {},   -- no args; present so o:Siblings is a no-op, not a nil index
    guiwidth  = {},
    gapcheck  = { "all", "clear" },
    pixelcheck = {},
    admissing = { "mark" },
    -- The dev list here MUST stay in step with HEADER_MUTATORS in Frames/Headers.lua,
    -- which is what actually refuses them on a release build. Listing one without
    -- the other is how a command ends up advertised and then rejected.
    headers   = { "info", "map", dev = { "init", "refresh", "sort <type>", "horizontal|vertical", "grow <pos>", "center", "self <pos>" } },
    pinned    = { "info", "test", "reinit", "bosstest <1-8>", "bossspawn demo" },
    range     = { "stats", "spell", "dump", "clear" },
    sort      = { "refresh", "clear" },
    -- Public half is read-only. The dev half must stay in step with
    -- SECURE_MUTATORS in Features/SecureSort.lua, which is what refuses them.
    -- "init" leads the dev list because every other one needs the handler.
    secure    = { "help", "status", dev = { "init", "party", "raid", "all", "register",
                  "test", "swap", "swapback", "debug", "ui", "show", "hide",
                  "showbutton", "hidebutton" } },
    flatraid  = { "info", "reinit", "test" },
    -- (No "cc" entry.) /df debug cc's BARE form already prints its full subcommand
    -- table — that is its entire job — so a Siblings footer would repeat it.
    api       = { "test", "fire", "snippet", "watch", "list" },
    colorhook = { "on", "off", "api" },
    spelldump = { "<search term>" },
}

--- Footer listing what else this command takes. Safe from an early return.
--- ☠ The array part is what EVERYONE sees. A `dev` sub-table is appended only on
--- a dev build, so a release user is never shown a command their client refuses —
--- the same drift that once listed everyday commands under /df debug, and that
--- put "/dfheaders hide" in a help block with no handler behind it.
--- @param cmd string  the /df debug word, e.g. "dispel"
function Out:Siblings(cmd)
    local list = DF.COMMAND_SIBLINGS[cmd]
    if not list then return self end
    -- Built from DF:CmdPath, never a literal "/df " — the footer has to name the
    -- form the user can actually type, and that moved to "/df debug <cmd>".
    local path = DF:CmdPath(cmd)
    local parts = {}
    for _, sub in ipairs(list) do
        parts[#parts + 1] = O.CMD .. path .. " " .. sub .. "|r"
    end
    if list.dev and DF:IsDevBuild() then
        for _, sub in ipairs(list.dev) do
            parts[#parts + 1] = O.CMD .. path .. " " .. sub .. "|r"
        end
    end
    if #parts == 0 then return self end
    print("  " .. O.NEUTRAL .. "Also:|r " .. table.concat(parts, " " .. O.NEUTRAL .. "·|r "))
    return self
end

--- Closing line of typeable next steps. Pass command strings.
function Out:Hints(...)
    local n = select("#", ...)
    if n == 0 then return self end
    local parts = {}
    for i = 1, n do parts[i] = O.CMD .. (select(i, ...)) .. "|r" end
    print("  " .. O.NEUTRAL .. "More:|r " .. table.concat(parts, " " .. O.NEUTRAL .. "·|r "))
    return self
end

-- Say/Err deliberately do NOT print the rule. A separator above "Pinned frames
-- reinitialised" is heavier than the message it introduces, and these fire far
-- more often than dumps do. The cost is that two visual shapes exist — a ruled
-- block and a bare line — but the line still carries the same brand prefix, so
-- they read as one family and the rule stays meaningful as "a block starts here".

--- Title-only output: the house style with no body. Use for confirmations.
function DF:Say(text, value, status)
    print(O.BRAND .. "DandersFrames|r " .. O.NEUTRAL .. "·|r " .. text
        .. (value and (" " .. tone(status or "GOOD") .. value .. "|r") or ""))
end

--- Title-only output in the BAD tone. Use for refusals and failures.
function DF:Err(text)
    print(O.BRAND .. "DandersFrames|r " .. O.NEUTRAL .. "·|r " .. O.BAD .. text .. "|r")
end

-- ============================================================
-- DEBUG COMMAND GROUPING
-- ============================================================
-- /df debug used to print three sections split by REGISTRATION MECHANISM —
-- "Support / diagnostics" and "Dev tools" (both from RegisterDebugSlash) and
-- "/df diagnostics" (from RegisterDebugSub). That is an implementation detail
-- nobody reading the list cares about: it put /df debug auras and /df debug auradata in
-- different sections while they answer the same question, and it made the
-- first and third sections look like they should be one list.
--
-- The split that matters is WHO RUNS IT (dev gate) and WHAT IT IS ABOUT
-- (subsystem). Both registries resolve their group from the one map below, so
-- there is a single place to edit and anything unmapped lands visibly in
-- "Other" rather than silently disappearing.
DF.DEBUG_GROUP_ORDER = { "auras", "frames", "click", "gui", "data", "system", "other" }
DF.DEBUG_GROUP_NAMES = {
    auras  = "Auras, dispel and the aura container",
    frames = "Frames, layout and sorting",
    click  = "Click-casting",
    gui    = "Settings window",
    data   = "Profiles, spell data and exports",
    system = "System, API and performance",
    other  = "Other",
}
-- Keyed by the /df <word> form (for a command with no /df debug form, its alias minus
-- the leading slash). Covers BOTH registries.
DF.DEBUG_GROUP_OF = {
    auras = "auras", auradata = "auras", dispel = "auras", auraexp = "auras",
    duration = "auras", idgate = "auras", ppdump = "auras", ppbadge = "auras",
    admissing = "auras", cbt = "auras",

    headers = "frames", flatraid = "frames", secure = "frames", sort = "frames",
    roster = "frames", pinned = "frames", range = "frames", arena = "frames",
    attached = "frames", zorder = "frames", mousefoci = "frames",
    flatdebug = "frames", flatoverlay = "frames", raidbg = "frames",
    rostertest = "frames",

    cc = "click", clickcast = "click", spelldump = "click",
    casthistory = "click", clearhistory = "click", resetconflict = "click",

    pixelcheck = "gui", gapcheck = "gui", navprobe = "gui", guiwidth = "gui",
    tdmirror = "gui", colorhook = "gui", overridedebug = "gui", atlas = "gui",
    icons = "gui",

    auditspells = "data", exportaudit = "data", overrides = "data",
    localewarn = "data", testids = "data", autotest = "data",

    api = "system", profiler = "system", profile = "system",
    memtest = "system", debugrested = "system",
    -- Media availability, not a settings-window probe — it answers "does this
    -- client have the font at all", which matters everywhere fonts are drawn.
    debugfonts = "system",
}

-- `hidden` keeps a command ANSWERING, and registered here for the drift check, but
-- off the /df debug listing. Two reasons qualify:
--   1. It is an everyday command already listed by /df help (test, reset, lock...).
--      Each command should be documented in exactly ONE list — the one its audience
--      reads — or the two drift apart, which is how pixelcheck ended up in both.
--   2. (Removed 2026-07-29) There used to be a second reason: console-migration
--      signposts that toggled nothing. Those commands are gone rather than hidden
--      — a command whose whole job is to say "this moved" is one more spelling to
--      learn, and the console page already says where tracing lives.
function DF:RegisterDebugSub(cmd, desc, devOnly, args, hidden)
    table.insert(DF.DebugSubCommands, { cmd = cmd, desc = desc, dev = devOnly, args = args, hidden = hidden })
    -- Registering IS the gate. Populated here rather than at the branch so a
    -- command cannot be marked dev in the listing while staying runnable on
    -- release — the two can no longer drift apart.
    if devOnly then DF.DEBUG_SUB_DEV[cmd] = true end
end

-- ============================================================
-- MEMORY TEST GATE
-- ============================================================
-- The ONLY way any system may consult a memory-test flag. Never read
-- DF.MemTest directly in a guard — see the three conditions below, each of
-- which is load-bearing.
--
-- ☠ WHY THIS LIVES IN Core.lua AND NOT IN Debug/MemoryTest.lua
-- The flag table is declared at TOC line 160; every consumer of it loads
-- earlier (Border 91, Icons 99, Auras 110, AD Factory 125, TD Render 134). The
-- old idiom was `DF.MemTest and not DF.MemTest.enableX`, which reads a MISSING
-- key as nil -> `not nil` -> true -> DISABLED. So any window where a consumer
-- knew about a flag the table did not yet declare silently switched that system
-- off on live frames, and it took a second reload to come back. A partial or
-- failed load of MemoryTest.lua would do the same thing. Absence must mean
-- ENABLED, and the gate must exist before anything that calls it.
--
--   1. MemTestArmed   — only true while the panel is actually OPEN. Closing it
--      restores every flag, so a forgotten tick can never outlive the window.
--   2. table present   — if MemoryTest.lua fails to load at all, nothing
--      is disabled rather than everything.
--   3. `== false`      — STRICT. nil, missing, or any other value is enabled.
--      This is the polarity fix; do not relax it to `not v`.
function DF:MemTestDisabled(key)
    return DF.MemTestArmed == true
        and DF.MemTest ~= nil
        and DF.MemTest[key] == false
end

-- Aura layout version: incremented when any layout-affecting setting changes.
-- Frames track the version they were last laid out with to avoid redundant work.
DF.auraLayoutVersion = 1

function DF:InvalidateAuraLayout()
    DF.auraLayoutVersion = (DF.auraLayoutVersion or 0) + 1
    -- 12.1 factory rows: the drives that consume this version run inside the aura
    -- update cycle (next UNIT_AURA), so without an immediate re-drive a GUI layout
    -- change applies "one aura event late". Drive them now (OOC; no-op pre-12.1).
    if DF.RefreshFactoryRows then DF:RefreshFactoryRows() end

    -- ⚠ TEST MODE NEEDS ITS OWN PASS. RefreshFactoryRows goes through
    -- driveFactoryRowsNow -> UseFactoryFor{Buffs,Debuffs,Defensive,MissingBuff}, and
    -- ALL FOUR of those predicates contain `not (DF.testMode or DF.raidTestMode)` —
    -- deliberately, because the test drives call the factories themselves. The effect
    -- was that every container setting re-drove live frames and skipped the preview:
    -- change a buff/debuff/defensive setting while previewing and nothing moved until
    -- test mode was reopened. Aura Designer looked like the only thing that worked
    -- because it is the one surface whose "update every test frame" helper was wired up.
    --
    -- Each helper below self-guards on test mode, so this is inert on the live path.
    if DF.UpdateAllTestAuras then DF:UpdateAllTestAuras() end
    if DF.UpdateAllTestMissingBuff then DF:UpdateAllTestMissingBuff() end
    if DF.UpdateAllTestDefensiveBar then DF:UpdateAllTestDefensiveBar() end
end

-- ============================================================
-- TARGETED SLIDER UPDATE SYSTEM
-- ============================================================
-- Optimizes slider dragging by only updating the specific property being changed.
-- During slider drag: only update the one property (e.g., just frame height)
-- On slider release: perform full frame update to ensure everything is in sync

-- Debug flag for slider updates (enable the GUI category in the debug console)

-- Track active slider dragging state
DF.sliderDragging = false
DF.sliderLightweightFunc = nil  -- The lightweight update function to call during drag
DF.sliderLightweightName = nil  -- Name of the lightweight function for debug
DF.sliderUpdateCallCount = 0    -- Call counter for debugging

-- Preview mode constants
local SIZE_UPDATE_INTERVAL = 0.033  -- ~30 FPS update rate for smooth dragging
local lastSizeUpdate = 0

-- Called when a slider starts being dragged
-- lightweightFunc: optional function that only updates the specific property
-- funcName: optional name for debug output
-- usePreviewMode: if true, hide frame elements for better performance
function DF:OnSliderDragStart(lightweightFunc, funcName, usePreviewMode)
    DF.sliderDragging = true
    DF.sliderLightweightFunc = lightweightFunc
    DF.sliderLightweightName = funcName or "unknown"
    DF.sliderUpdateCallCount = 0  -- Reset counter
    
    DF:Debug("GUI", "Slider drag START - %s%s",
        lightweightFunc and ("lightweight: " .. tostring(DF.sliderLightweightName))
            or "no lightweight function (will skip until release)",
        usePreviewMode and " (PREVIEW MODE)" or "")
end

-- Called when a slider stops being dragged (mouse up)
function DF:OnSliderDragStop()
    DF:Debug("GUI", "Slider drag STOP - %s lightweight calls, now FULL UpdateAll()",
        tostring(DF.sliderUpdateCallCount))
    
    DF.sliderDragging = false
    DF.sliderLightweightFunc = nil
    DF.sliderLightweightName = nil
    
    -- Perform full update now that dragging has stopped
    local isRaidMode = DF.GUI and DF.GUI.SelectedMode == "raid"
    
    if isRaidMode and DF.raidTestMode then
        if DF.UpdateRaidTestFrames then
            DF:UpdateRaidTestFrames()
        end
        if DF.UpdateAllRaidPetFrames then
            DF:UpdateAllRaidPetFrames()
        end
    else
        DF:UpdateAll()
        -- UpdateAll already calls UpdateAllPetFrames
    end
end

-- Called during slider value changes
-- If dragging with a lightweight function, call it directly (throttled)
-- If dragging without lightweight function, skip entirely until release
-- If not dragging, call UpdateAll directly (no throttle)
function DF:ThrottledUpdateAll()
    if DF.sliderDragging then
        if DF.sliderLightweightFunc then
            -- During drag with lightweight function, call it (has its own throttle)
            DF.sliderLightweightFunc()
        end
        -- If no lightweight func, just skip until release
        return
    end
    
    -- Not dragging - just call UpdateAll directly
    DF:UpdateAll()
end

-- ============================================================
-- LIGHTWEIGHT UPDATE FUNCTIONS
-- ============================================================
-- These update only specific properties during slider drag for performance

-- Helper to iterate frames in current mode via iterators
-- Automatically uses test frames when in test mode
local function IterateFramesInMode(mode, updateFunc)
    if mode == "raid" then
        -- Check for raid test mode first
        if DF.raidTestMode and DF.testRaidFrames then
            local raidDb = DF:GetRaidDB()
            local testFrameCount = raidDb and raidDb.raidTestFrameCount or 10
            for i = 1, testFrameCount do
                local frame = DF.testRaidFrames[i]
                if frame and frame:IsShown() then
                    if updateFunc(frame, i, "raid" .. i) then return end
                end
            end
        elseif DF.IterateRaidFrames then
            -- Live raid frames via iterator
            DF:IterateRaidFrames(updateFunc)
        end
    else
        -- Check for party test mode first
        if DF.testMode and DF.testPartyFrames then
            local db = DF:GetDB()
            local testFrameCount = db and db.testFrameCount or 5
            for i = 0, testFrameCount - 1 do
                local frame = DF.testPartyFrames[i]
                if frame and frame:IsShown() then
                    local unit = (i == 0) and "player" or ("party" .. i)
                    if updateFunc(frame, i, unit) then return end
                end
            end
        elseif DF.IteratePartyFrames then
            -- Live party frames via iterator
            DF:IteratePartyFrames(updateFunc)
        end
    end
end

-- Update frame sizes AND layout positions
function DF:LightweightUpdateFrameSize()
    -- Frame-skip throttle
    local now = GetTime()
    if now - lastSizeUpdate < SIZE_UPDATE_INTERVAL then
        return
    end
    lastSizeUpdate = now
    
    DF.sliderUpdateCallCount = DF.sliderUpdateCallCount + 1
    
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    
    if mode == "raid" then
        -- Check for raid test mode
        if DF.raidTestMode then
            -- Full layout refresh including borders, health bars, fonts etc.
            if DF.RefreshTestFramesWithLayout then
                DF:RefreshTestFramesWithLayout()
            end
        else
            -- Call real layout function for live frames
            if DF.UpdateRaidLayout then
                DF:UpdateRaidLayout()
            end
        end
    else
        -- Party frames - resize frame and update health bar with padding
        local db = DF.db[mode]
        if not db then return end

        -- Party test frames: do the full layout refresh (mirroring the raid
        -- branch above) so overlay bars (absorb, heal prediction, reduced-max)
        -- re-position too. The lightweight path below only re-anchors the health
        -- bar, leaving the overlays stale mid-drag until the slider is released.
        if DF.testMode and DF.RefreshTestFramesWithLayout then
            DF:RefreshTestFramesWithLayout()
            return
        end

        local frameWidth = db.frameWidth or 120
        local frameHeight = db.frameHeight or 50
        local padding = db.framePadding or 0
        
        local function UpdateFrame(frame)
            if not frame then return end
            frame:SetSize(frameWidth, frameHeight)
            if frame.healthBar then
                frame.healthBar:ClearAllPoints()
                frame.healthBar:SetPoint("TOPLEFT", frame, "TOPLEFT", padding, -padding)
                frame.healthBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -padding, padding)
            end
            -- Update resource bar width to match new frame size
            if db.resourceBarMatchWidth and frame.dfPowerBar and DF.ApplyResourceBarLayout then
                DF:ApplyResourceBarLayout(frame)
            end
        end

        IterateFramesInMode(mode, UpdateFrame)

        -- Re-apply header settings so the container and header anchors
        -- update to match the new frame dimensions during slider drag
        if DF.headersInitialized and DF.ApplyHeaderSettings then
            DF:ApplyHeaderSettings()
        end

        -- Update positioning for test frames
        if DF.testMode and DF.LightweightPositionPartyTestFrames then
            local testFrameCount = db.testFrameCount or 5
            DF:LightweightPositionPartyTestFrames(testFrameCount)
        end
        
        -- Also update pet frames to re-center on new frame sizes
        if DF.UpdateAllPetFrames then
            DF:UpdateAllPetFrames(true)
        end
    end
end

-- Spacing/layout changes - needs to re-layout frames
function DF:LightweightUpdateFrameSpacing()
    -- Frame-skip throttle
    local now = GetTime()
    if now - lastSizeUpdate < SIZE_UPDATE_INTERVAL then
        return
    end
    lastSizeUpdate = now
    
    -- Update secure headers if active (only for live frames, not test mode)
    if not DF.testMode and not DF.raidTestMode then
        if DF.headersInitialized and DF.ApplyHeaderSettings then
            DF:ApplyHeaderSettings()
        end
    end
    
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    
    if mode == "raid" then
        -- Check for raid test mode
        if DF.raidTestMode then
            -- Full layout refresh including borders, health bars, fonts etc.
            if DF.RefreshTestFramesWithLayout then
                DF:RefreshTestFramesWithLayout()
            end
        else
            if DF.UpdateRaidLayout then
                DF:UpdateRaidLayout()
            end
        end
    else
        -- Party mode
        if DF.testMode then
            -- Update test frame positioning
            if DF.LightweightPositionPartyTestFrames then
                local db = DF:GetDB()
                local testFrameCount = db and db.testFrameCount or 5
                DF:LightweightPositionPartyTestFrames(testFrameCount)
            elseif DF.UpdateAllFrames then
                DF:UpdateAllFrames()
            end
        else
            -- Live frames - need to call UpdateAllFrames to recalculate positions
            if DF.UpdateAllFrames then
                DF:UpdateAllFrames()
            end
        end
        -- Also update pet frames
        if DF.UpdateAllPetFrames then
            DF:UpdateAllPetFrames()
        end
    end
end

function DF:LightweightUpdateRaidLayout()
    DF:LightweightUpdateFrameSize()
end

function DF:LightweightUpdateFrameScale()
    -- Frame-skip throttle
    local now = GetTime()
    if now - lastSizeUpdate < SIZE_UPDATE_INTERVAL then
        return
    end
    lastSizeUpdate = now

    local mode = DF.GUI and DF.GUI.SelectedMode or "party"

    if mode == "raid" then
        DF:UpdateRaidContainerPosition()
        if DF.raidTestMode then
            if DF.RefreshTestFramesWithLayout then
                DF:RefreshTestFramesWithLayout()
            end
        elseif DF.UpdateRaidLayout then
            DF:UpdateRaidLayout()
        end
    else
        DF:UpdateContainerPosition()
        if DF.testMode and DF.LightweightPositionPartyTestFrames then
            local db = DF:GetDB()
            local testFrameCount = db and db.testFrameCount or 5
            DF:LightweightPositionPartyTestFrames(testFrameCount)
        end
        if DF.UpdateAllPetFrames then
            DF:UpdateAllPetFrames(true)
        end
    end

    -- Update permanent mover anchors (they reference scaled containers)
    DF:UpdatePermanentMoverAnchor("party")
    DF:UpdatePermanentMoverAnchor("raid")
end

-- ============================================================
-- SAFE TEXTURE SETTERS — graceful missing-texture fallback
-- A configured texture can be missing when a profile imported from another user
-- references a 3rd-party/SharedMedia texture this client doesn't have (or the
-- providing addon was removed) — leaving a black/blank bar. C_UIFileAsset
-- (NEW in WoW 12.0.7) — IsKnownFile(asset) reports whether a path is known to
-- the client (shipped OR a known loose addon file); when it says the asset is
-- unknown we substitute a guaranteed-present stock texture. (Note: the API
-- doesn't verify a known loose file still exists on disk, but an uninstalled
-- addon's path is simply not "known", which is exactly the import case we want.)
--   The SetTexture/SetStatusBarTexture `success` bool does NOT work for this —
--   it returns true for any well-formed path even when the file is absent.
--   Feature-detected: on clients without C_UIFileAsset this is INERT (behaves
--   exactly as before), so it's safe to ship now and self-activates on 12.0.7.
-- ============================================================
-- DF's own bundled default bar texture — ships with the addon, so it's always
-- present when our code runs. This is the "fall back to our default" target.
DF.STOCK_BAR_TEXTURE = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist"
local _df_warnedMissingTexture = {}

-- false -> asset (texture path or fileID) is definitively NOT known to the client
-- true  -> known/present
-- nil   -> validation API unavailable (caller leaves the texture as-is)
local function textureKnown(asset)
    if asset == nil then return nil end
    local api = C_UIFileAsset
    if not (api and api.IsKnownFile) then return nil end
    local ok, known = pcall(api.IsKnownFile, asset)
    if not ok then return nil end
    return known and true or false
end

local function warnMissingTexture(path)
    if not path or _df_warnedMissingTexture[path] then return end
    _df_warnedMissingTexture[path] = true
    if DF.Debug then DF:Debug("TEXTURE", "Missing texture '%s' — using stock fallback", tostring(path)) end
    if not DF._warnedAnyMissingTexture then
        DF._warnedAnyMissingTexture = true
        print("|cff66ccffDandersFrames|r: a configured texture couldn't be loaded and was replaced with a stock texture. Check your texture settings (an imported profile may reference a texture you don't have).")
    end
end

-- StatusBar texture with stock fallback. Returns true if the requested texture
-- loaded, false if the stock fallback was substituted, nil if bar was missing.
function DF:SafeSetStatusBarTexture(bar, path, stock)
    if not bar then return end
    if textureKnown(path) == false then
        bar:SetStatusBarTexture(stock or DF.STOCK_BAR_TEXTURE)
        warnMissingTexture(path)
        return false
    end
    bar:SetStatusBarTexture(path)
    return true
end

-- Plain Texture region with stock fallback (same semantics).
function DF:SafeSetTexture(region, path, stock)
    if not region then return end
    if textureKnown(path) == false then
        region:SetTexture(stock or DF.STOCK_BAR_TEXTURE)
        warnMissingTexture(path)
        return false
    end
    region:SetTexture(path)
    return true
end

-- Update only font shadows on all text elements
function DF:LightweightUpdateFontShadows()
    -- 12.0.7: fontstring-level SetShadowOffset/SetShadowColor no longer render —
    -- a font's drop shadow now lives on its font-family per-alphabet font objects.
    -- The old per-frame fontstring poke was a silent no-op, so update the already
    -- built font families in place instead (live preview, no full font rebuild).
    if DF.RefreshFontFamilyShadows then DF:RefreshFontFamilyShadows() end
    -- A font-object shadow change doesn't repaint already-rendered fontstrings —
    -- only continuously-ticked test frames pick it up on their own. Re-apply fonts
    -- so live + pinned frames repaint too.
    -- Legacy name/health/status text (used when the Text Designer is off):
    if DF.RefreshAllFonts then DF:RefreshAllFonts() end
    -- The Text Designer renders the visible text on its own overlay, which the
    -- above doesn't touch; re-render it so its shadow repaints on live + pinned.
    if DF.TextDesigner and DF.TextDesigner.Preview and DF.TextDesigner.Preview.RefreshLiveFrames then
        DF.TextDesigner.Preview:RefreshLiveFrames()
    end
end

-- Update only power/resource bar height
function DF:LightweightUpdatePowerBarSize()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local height = db.resourceBarHeight or 4
    local width = db.resourceBarWidth or 50
    
    local function UpdateBar(frame)
        if frame and frame.dfPowerBar then
            frame.dfPowerBar:SetHeight(height)
            if not db.resourceBarMatchWidth then
                frame.dfPowerBar:SetWidth(width)
            end
        end
    end
    
    IterateFramesInMode(mode, UpdateBar)
end

-- Update only border thickness
-- Re-apply the frame border (size, style, texture, colour, show/hide) to every
-- live frame in the current mode. The full update path only re-styles party
-- frames (UpdateAllFrames -> ApplyFrameLayout); the raid path (UpdateRaidLayout)
-- only repositions headers, so border changes wouldn't reach live raid frames
-- without a reload. This mirrors LightweightUpdateBorderColor but reconfigures
-- the whole border via ApplyFrameBorder, so it covers both party and raid.
function DF:LightweightUpdateBorder()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db or not DF.ApplyFrameBorder then return end

    local function UpdateBorder(frame)
        if not frame or not frame.border then return end
        DF:ApplyFrameBorder(frame, db)
    end

    IterateFramesInMode(mode, UpdateBorder)
end



-- Update icon scale/position
function DF:LightweightUpdateIconPosition(iconType)
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local function UpdateIcon(frame)
        if not frame then return end
        
        local icon, scale, x, y, anchor
        if iconType == "role" then
            icon = frame.roleIcon
            scale = db.roleIconScale or 1
            x = db.roleIconX or 0
            y = db.roleIconY or 0
            anchor = db.roleIconAnchor or "TOPLEFT"
        elseif iconType == "raidTarget" then
            icon = frame.raidTargetIcon
            scale = db.raidTargetIconScale or 1
            x = db.raidTargetIconX or 0
            y = db.raidTargetIconY or 0
            anchor = db.raidTargetIconAnchor or "CENTER"
        elseif iconType == "readyCheck" then
            icon = frame.readyCheckIcon
            scale = db.readyCheckIconScale or 1
            x = db.readyCheckIconX or 0
            y = db.readyCheckIconY or 0
            anchor = db.readyCheckIconAnchor or "CENTER"
        elseif iconType == "leader" then
            icon = frame.leaderIcon
            scale = db.leaderIconScale or 1
            x = db.leaderIconX or 0
            y = db.leaderIconY or 0
            anchor = db.leaderIconAnchor or "TOPLEFT"
        elseif iconType == "summon" then
            icon = frame.summonIcon
            scale = db.summonIconScale or 1
            x = db.summonIconX or 0
            y = db.summonIconY or 0
            anchor = db.summonIconAnchor or "CENTER"
        elseif iconType == "resurrection" then
            icon = frame.resurrectionIcon
            scale = db.resurrectionIconScale or 1
            x = db.resurrectionIconX or 0
            y = db.resurrectionIconY or 0
            anchor = db.resurrectionIconAnchor or "CENTER"
        elseif iconType == "phased" then
            icon = frame.phasedIcon
            scale = db.phasedIconScale or 1
            x = db.phasedIconX or 0
            y = db.phasedIconY or 0
            anchor = db.phasedIconAnchor or "TOPRIGHT"
        elseif iconType == "afk" then
            icon = frame.afkIcon
            scale = db.afkIconScale or 1
            x = db.afkIconX or 0
            y = db.afkIconY or 0
            anchor = db.afkIconAnchor or "CENTER"
        elseif iconType == "vehicle" then
            icon = frame.vehicleIcon
            scale = db.vehicleIconScale or 1
            x = db.vehicleIconX or 0
            y = db.vehicleIconY or 0
            anchor = db.vehicleIconAnchor or "BOTTOMRIGHT"
        elseif iconType == "raidRole" then
            icon = frame.raidRoleIcon
            scale = db.raidRoleIconScale or 1
            x = db.raidRoleIconX or 0
            y = db.raidRoleIconY or 0
            anchor = db.raidRoleIconAnchor or "BOTTOMLEFT"
        end
        
        if icon then
            icon:SetScale(scale)
            icon:ClearAllPoints()
            icon:SetPoint(anchor, frame, anchor, x, y)
            DF:SnapPointToPixelGrid(icon, db.pixelPerfect)
        end
    end

    IterateFramesInMode(mode, UpdateIcon)
end

-- Lightweight alpha update for icons (no full frame rebuild)
function DF:LightweightUpdateIconAlpha(iconType)
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local function UpdateAlpha(frame)
        if not frame then return end
        
        local icon, alpha
        if iconType == "role" then
            icon = frame.roleIcon
            alpha = db.roleIconAlpha or 1
        elseif iconType == "raidTarget" then
            icon = frame.raidTargetIcon
            alpha = db.raidTargetIconAlpha or 1
        elseif iconType == "readyCheck" then
            icon = frame.readyCheckIcon
            alpha = db.readyCheckIconAlpha or 1
        elseif iconType == "leader" then
            icon = frame.leaderIcon
            alpha = db.leaderIconAlpha or 1
        elseif iconType == "summon" then
            icon = frame.summonIcon
            alpha = db.summonIconAlpha or 1
        elseif iconType == "resurrection" then
            icon = frame.resurrectionIcon
            alpha = db.resurrectionIconAlpha or 1
        elseif iconType == "phased" then
            icon = frame.phasedIcon
            alpha = db.phasedIconAlpha or 1
        elseif iconType == "afk" then
            icon = frame.afkIcon
            alpha = db.afkIconAlpha or 1
        elseif iconType == "vehicle" then
            icon = frame.vehicleIcon
            alpha = db.vehicleIconAlpha or 1
        elseif iconType == "raidRole" then
            icon = frame.raidRoleIcon
            alpha = db.raidRoleIconAlpha or 1
        end
        
        if icon then
            icon:SetAlpha(alpha)
        end
    end
    
    IterateFramesInMode(mode, UpdateAlpha)
end

-- Update aura position/size
function DF:LightweightUpdateAuraPosition(auraType)
    -- 12.1: the container rows own this styling; bump the layout version and
    -- re-drive them so the change applies live (sig-gated, cheap when unchanged).
    DF:InvalidateAuraLayout()
end

-- Update highlight thickness/inset
function DF:LightweightUpdateHighlight(highlightType)
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local function UpdateHighlight(frame)
        if not frame then return end
        
        local highlight, thickness, inset, alpha, color
        if highlightType == "selection" then
            highlight = frame.selectionHighlight or frame.dfSelectionHighlight
            thickness = db.selectionHighlightThickness or 2
            inset = db.selectionHighlightInset or 0
            alpha = db.selectionHighlightAlpha or 1
            color = db.selectionHighlightColor or {r = 1, g = 1, b = 1}
        elseif highlightType == "hover" then
            highlight = frame.hoverHighlight or frame.dfHoverHighlight
            thickness = db.hoverHighlightThickness or 2
            inset = db.hoverHighlightInset or 0
            alpha = db.hoverHighlightAlpha or 0.8
            color = db.hoverHighlightColor or {r = 1, g = 1, b = 1}
        elseif highlightType == "aggro" then
            highlight = frame.aggroHighlight or frame.dfAggroHighlight
            thickness = db.aggroHighlightThickness or 2
            inset = db.aggroHighlightInset or 0
            alpha = db.aggroHighlightAlpha or 1
            -- Aggro color depends on threat status - use stored color or get current threat
            if frame.dfAggroColor then
                color = frame.dfAggroColor
            else
                -- Determine color from threat status (or use tanking color for test/default)
                local status = frame.unit and UnitThreatSituation(frame.unit) or 3
                if db.aggroUseCustomColors then
                    if status == 3 then
                        color = db.aggroColorTanking or {r = 1, g = 0, b = 0}
                    elseif status == 2 then
                        color = db.aggroColorHighestThreat or {r = 1, g = 0.5, b = 0}
                    elseif status == 1 then
                        color = db.aggroColorHighThreat or {r = 1, g = 1, b = 0}
                    else
                        color = db.aggroColorTanking or {r = 1, g = 0, b = 0}
                    end
                else
                    -- Default Blizzard colors
                    if status == 3 then
                        color = {r = 1, g = 0, b = 0}
                    elseif status == 2 then
                        color = {r = 1, g = 0.5, b = 0}
                    elseif status == 1 then
                        color = {r = 1, g = 1, b = 0}
                    else
                        color = {r = 1, g = 0, b = 0}
                    end
                end
            end
        end
        
        -- If highlight doesn't exist, call full UpdateHighlights to create it
        if not highlight then
            if DF.UpdateHighlights then
                DF:UpdateHighlights(frame)
            end
            -- Re-get the highlight after creation
            if highlightType == "selection" then
                highlight = frame.selectionHighlight or frame.dfSelectionHighlight
            elseif highlightType == "hover" then
                highlight = frame.hoverHighlight or frame.dfHoverHighlight
            elseif highlightType == "aggro" then
                highlight = frame.aggroHighlight or frame.dfAggroHighlight
            end
        end
        
        if highlight and highlight:IsShown() then
            highlight:SetAlpha(alpha)
            
            -- Update border textures - check both naming conventions
            local top = highlight.top or highlight.topLine
            local bottom = highlight.bottom or highlight.bottomLine
            local left = highlight.left or highlight.leftLine
            local right = highlight.right or highlight.rightLine
            
            if top then
                top:SetHeight(thickness)
                top:ClearAllPoints()
                top:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset)
                top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -inset, -inset)
                top:SetColorTexture(color.r, color.g, color.b, 1)
            end
            if bottom then
                bottom:SetHeight(thickness)
                bottom:ClearAllPoints()
                bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", inset, inset)
                bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
                bottom:SetColorTexture(color.r, color.g, color.b, 1)
            end
            if left then
                left:SetWidth(thickness)
                left:ClearAllPoints()
                left:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset)
                left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", inset, inset)
                left:SetColorTexture(color.r, color.g, color.b, 1)
            end
            if right then
                right:SetWidth(thickness)
                right:ClearAllPoints()
                right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -inset, -inset)
                right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
                right:SetColorTexture(color.r, color.g, color.b, 1)
            end
        end
    end
    
    IterateFramesInMode(mode, UpdateHighlight)
end

-- Update power bar position
function DF:LightweightUpdatePowerBarPosition()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local anchor = db.resourceBarAnchor or "BOTTOM"
    local x = db.resourceBarX or 0
    local y = db.resourceBarY or 0
    
    local function UpdateBar(frame)
        if frame and frame.dfPowerBar then
            frame.dfPowerBar:ClearAllPoints()
            frame.dfPowerBar:SetPoint(anchor, frame, anchor, x, y)
        end
    end
    
    IterateFramesInMode(mode, UpdateBar)
end

-- Update absorb bar size/position
function DF:LightweightUpdateAbsorbBar()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local width = db.absorbBarWidth or 50
    local height = db.absorbBarHeight or 6
    local anchor = db.absorbBarAnchor or "BOTTOM"
    local x = db.absorbBarX or 0
    local y = db.absorbBarY or 0
    
    local function UpdateBar(frame)
        if frame and frame.dfAbsorbBar then
            frame.dfAbsorbBar:SetSize(width, height)
            frame.dfAbsorbBar:ClearAllPoints()
            frame.dfAbsorbBar:SetPoint(anchor, frame, anchor, x, y)
        end
    end
    
    IterateFramesInMode(mode, UpdateBar)
end

-- Update heal absorb bar
function DF:LightweightUpdateHealAbsorbBar()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local width = db.healAbsorbBarWidth or 50
    local height = db.healAbsorbBarHeight or 6
    local anchor = db.healAbsorbBarAnchor or "BOTTOM"
    local x = db.healAbsorbBarX or 0
    local y = db.healAbsorbBarY or -10
    
    local function UpdateBar(frame)
        if frame and frame.dfHealAbsorbBar then
            frame.dfHealAbsorbBar:SetSize(width, height)
            frame.dfHealAbsorbBar:ClearAllPoints()
            frame.dfHealAbsorbBar:SetPoint(anchor, frame, anchor, x, y)
        end
    end
    
    IterateFramesInMode(mode, UpdateBar)
end

-- Update dispel overlay settings
function DF:LightweightUpdateDispelOverlay()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end

    -- TEST MODE: route the drag tick through the REAL paint — UpdateDispelOverlay's
    -- test branch carries the mode-aware pieces (game-palette proxy, intensity
    -- frozen at 1 in game mode, borders/EDGE custom-only, the clip-proof anchor
    -- proxy). The hand-rolled repaint below predates the Game/Custom split and
    -- had drifted mode-blind: dragging Opacity in Game mode flashed the custom
    -- picker colours × intensity and re-showed the borders until release
    -- (live-caught). Test previews never carry their own copy of styling or
    -- geometry (mirrors LightweightUpdateDefensiveIcons); the loop below stays
    -- for pre-12.1 LIVE drags only, where avoiding a full aura re-scan per tick
    -- is the reason this lightweight path exists.
    if DF.testMode or DF.raidTestMode then
        if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        return
    end

    -- 12.1 factory overlay: re-drive immediately so colour/alpha/geometry tweaks
    -- apply live (mirrors LightweightUpdateDefensiveIcons). The legacy loop below
    -- only touches the hidden legacy overlays.
    if DF.UseFactoryForDispelOverlay and DF:UseFactoryForDispelOverlay(nil, db) then
        DF:InvalidateAuraLayout()
    end

    local borderSize = db.dispelBorderSize or 2
    local borderInset = db.dispelBorderInset or 0
    local borderAlpha = db.dispelBorderAlpha or 1
    local gradientAlpha = db.dispelGradientAlpha or 0.5
    local gradientIntensity = db.dispelGradientIntensity or 1.0
    local gradientStyle = db.dispelGradientStyle or "FULL"
    local gradientSize = db.dispelGradientSize or 0.3
    local blendMode = db.dispelGradientBlendMode or "ADD"
    local darkenAlpha = db.dispelGradientDarkenAlpha or 0.5
    local iconSize = db.dispelIconSize or 20
    local iconAlpha = db.dispelIconAlpha or 1
    local iconPosition = db.dispelIconPosition or "CENTER"
    local iconOffsetX = db.dispelIconOffsetX or 0
    local iconOffsetY = db.dispelIconOffsetY or 0
    
    local function UpdateDispel(frame)
        if not frame or not frame.dfDispelOverlay then return end
        
        local overlay = frame.dfDispelOverlay
        
        -- Get current color from overlay's stored dispel type
        local r, g, b = 1, 1, 1
        if overlay.currentDispelType then
            local dispelColors = {
                Magic = db.dispelMagicColor or {r = 0, g = 0.6, b = 1},
                Curse = db.dispelCurseColor or {r = 0.6, g = 0, b = 1},
                Poison = db.dispelPoisonColor or {r = 0, g = 0.6, b = 0},
                Disease = db.dispelDiseaseColor or {r = 0.6, g = 0.4, b = 0},
                Bleed = db.dispelBleedColor or {r = 1, g = 0, b = 0},
            }
            local color = dispelColors[overlay.currentDispelType]
            if color then
                r, g, b = color.r, color.g, color.b
            end
        end
        
        -- Calculate OOR alpha multiplier for test mode
        local oorMultiplier = 1.0
        if (DF.testMode or DF.raidTestMode) and frame.testData and frame.testData.outOfRange then
            oorMultiplier = db.oorDispelOverlayAlpha or 0.55
        end
        
        local effectiveBorderAlpha = borderAlpha * oorMultiplier
        local effectiveGradientAlpha = gradientAlpha * oorMultiplier
        
        -- Update border positions, sizes, and alpha
        if overlay.borderLeft then
            overlay.borderLeft:ClearAllPoints()
            overlay.borderLeft:SetPoint("TOPLEFT", overlay, "TOPLEFT", -borderInset, borderInset)
            overlay.borderLeft:SetPoint("BOTTOMLEFT", overlay, "BOTTOMLEFT", -borderInset, -borderInset)
            overlay.borderLeft:SetWidth(borderSize)
            local tex = overlay.borderLeft:GetStatusBarTexture()
            if tex then tex:SetVertexColor(r, g, b, effectiveBorderAlpha) end
        end
        
        if overlay.borderRight then
            overlay.borderRight:ClearAllPoints()
            overlay.borderRight:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", borderInset, borderInset)
            overlay.borderRight:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", borderInset, -borderInset)
            overlay.borderRight:SetWidth(borderSize)
            local tex = overlay.borderRight:GetStatusBarTexture()
            if tex then tex:SetVertexColor(r, g, b, effectiveBorderAlpha) end
        end
        
        if overlay.borderTop then
            overlay.borderTop:ClearAllPoints()
            overlay.borderTop:SetPoint("TOPLEFT", overlay, "TOPLEFT", -borderInset + borderSize, borderInset)
            overlay.borderTop:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", borderInset - borderSize, borderInset)
            overlay.borderTop:SetHeight(borderSize)
            local tex = overlay.borderTop:GetStatusBarTexture()
            if tex then tex:SetVertexColor(r, g, b, effectiveBorderAlpha) end
        end
        
        if overlay.borderBottom then
            overlay.borderBottom:ClearAllPoints()
            overlay.borderBottom:SetPoint("BOTTOMLEFT", overlay, "BOTTOMLEFT", -borderInset + borderSize, -borderInset)
            overlay.borderBottom:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", borderInset - borderSize, -borderInset)
            overlay.borderBottom:SetHeight(borderSize)
            local tex = overlay.borderBottom:GetStatusBarTexture()
            if tex then tex:SetVertexColor(r, g, b, effectiveBorderAlpha) end
        end
        
        -- Update gradient alpha and edge gradients
        if gradientStyle == "EDGE" then
            -- Update EDGE style gradient textures
            local ri, gi, bi = r * gradientIntensity, g * gradientIntensity, b * gradientIntensity
            local gradientParent = overlay.gradient and overlay.gradient:GetParent()
            local parentHeight = gradientParent and gradientParent:GetHeight() or 40
            local parentWidth = gradientParent and gradientParent:GetWidth() or 80
            local edgeSize = parentHeight * gradientSize
            local edgeWidth = parentWidth * gradientSize
            
            if overlay.gradientTop then
                overlay.gradientTop:SetVertexColor(ri, gi, bi, effectiveGradientAlpha)
                overlay.gradientTop:SetBlendMode(blendMode)
                overlay.gradientTop:ClearAllPoints()
                overlay.gradientTop:SetPoint("TOPLEFT", gradientParent, "TOPLEFT", 0, 0)
                overlay.gradientTop:SetPoint("TOPRIGHT", gradientParent, "TOPRIGHT", 0, 0)
                overlay.gradientTop:SetHeight(edgeSize)
            end
            if overlay.gradientBottom then
                overlay.gradientBottom:SetVertexColor(ri, gi, bi, effectiveGradientAlpha)
                overlay.gradientBottom:SetBlendMode(blendMode)
                overlay.gradientBottom:ClearAllPoints()
                overlay.gradientBottom:SetPoint("BOTTOMLEFT", gradientParent, "BOTTOMLEFT", 0, 0)
                overlay.gradientBottom:SetPoint("BOTTOMRIGHT", gradientParent, "BOTTOMRIGHT", 0, 0)
                overlay.gradientBottom:SetHeight(edgeSize)
            end
            if overlay.gradientLeft then
                overlay.gradientLeft:SetVertexColor(ri, gi, bi, effectiveGradientAlpha)
                overlay.gradientLeft:SetBlendMode(blendMode)
                overlay.gradientLeft:ClearAllPoints()
                overlay.gradientLeft:SetPoint("TOPLEFT", gradientParent, "TOPLEFT", 0, 0)
                overlay.gradientLeft:SetPoint("BOTTOMLEFT", gradientParent, "BOTTOMLEFT", 0, 0)
                overlay.gradientLeft:SetWidth(edgeWidth)
            end
            if overlay.gradientRight then
                overlay.gradientRight:SetVertexColor(ri, gi, bi, effectiveGradientAlpha)
                overlay.gradientRight:SetBlendMode(blendMode)
                overlay.gradientRight:ClearAllPoints()
                overlay.gradientRight:SetPoint("TOPRIGHT", gradientParent, "TOPRIGHT", 0, 0)
                overlay.gradientRight:SetPoint("BOTTOMRIGHT", gradientParent, "BOTTOMRIGHT", 0, 0)
                overlay.gradientRight:SetWidth(edgeWidth)
            end
        elseif overlay.gradient then
            -- Non-EDGE styles - update main gradient
            local tex = overlay.gradient:GetStatusBarTexture()
            if tex then
                -- Apply intensity boost via vertex color (matching ShowOverlayWithRGB logic)
                local intensityBoost = math.max(1.0, gradientIntensity)
                tex:SetVertexColor(r * intensityBoost, g * intensityBoost, b * intensityBoost, effectiveGradientAlpha)
            end
            -- Update darken alpha
            if overlay.gradientDarken and overlay.gradientDarken:IsShown() then
                overlay.gradientDarken:SetColorTexture(0, 0, 0, darkenAlpha * oorMultiplier)
            end
        end
        
        -- Update icons
        if overlay.icons then
            for _, icon in pairs(overlay.icons) do
                icon:ClearAllPoints()
                icon:SetPoint(iconPosition, overlay, iconPosition, iconOffsetX, iconOffsetY)
                icon:SetSize(iconSize, iconSize)
                icon:SetAlpha(iconAlpha)
            end
        end
    end
    
    IterateFramesInMode(mode, UpdateDispel)
end

-- Update defensive icon settings
function DF:LightweightUpdateDefensiveIcons()
    -- 12.1: the container rows own this styling; bump the layout version and
    -- re-drive them so the change applies live (sig-gated, cheap when unchanged).
    DF:InvalidateAuraLayout()
end

-- Update missing buff icon
function DF:LightweightUpdateMissingBuff()
    -- 12.1: the missing-buff strip owns the feature; bump the layout version
    -- and re-drive so size/scale/position/border changes apply live.
    DF:InvalidateAuraLayout()
end

-- Update group label settings (lightweight version for slider dragging)
-- Calls the full UpdateRaidGroupLabels since we need to recalculate positions
function DF:LightweightUpdateGroupLabels()
    if not DF.raidGroupLabels then return end
    if not DF.raidContainer then return end
    
    -- Just call the full update - it handles all the position calculation
    DF:UpdateRaidGroupLabels()
end

-- Update aura stack text settings
function DF:LightweightUpdateAuraStackText(auraType)
    -- 12.1: the container rows own this styling; bump the layout version and
    -- re-drive them so the change applies live (sig-gated, cheap when unchanged).
    DF:InvalidateAuraLayout()
end

-- Update aura duration text settings
function DF:LightweightUpdateAuraDurationText(auraType)
    -- 12.1: the container rows own this styling; bump the layout version and
    -- re-drive them so the change applies live (sig-gated, cheap when unchanged).
    DF:InvalidateAuraLayout()
end

-- Sync linked sections between party and raid modes
function DF:SyncLinkedSections()
    if not DF.GUI or not DF.db or not DF.db.linkedSections then return end
    if not next(DF.db.linkedSections) then return end
    -- Skip sync during auto layout editing — _realRaidDB contains preview
    -- overrides and syncing would contaminate the other mode's settings
    local apu = DF.AutoProfilesUI
    if apu and apu:IsEditing() then return end
    local mode = DF.GUI.SelectedMode
    if mode ~= "party" and mode ~= "raid" then return end

    for pageId, prefixes in pairs(DF.SectionRegistry or {}) do
        if DF.db.linkedSections[pageId] then
            DF:CopySectionSettingsRaw(prefixes, mode)
        end
    end
end

-- Update aura border settings (both regular and expiring borders)
function DF:LightweightUpdateAuraBorder(auraType)
    -- 12.1: the container rows own this styling; bump the layout version and
    -- re-drive them so the change applies live (sig-gated, cheap when unchanged).
    DF:InvalidateAuraLayout()
end

-- Update frame levels for various elements
function DF:LightweightUpdateFrameLevel(elementType)
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end

    -- 12.1 factory rows: the defensive row's frame level is applied by the drive
    -- (frameLevelOffset) — re-drive immediately so the slider previews live. The
    -- missing-buff strip's level is applied the same way (layoutMissingStrip).
    if (elementType == "defensive" and DF.UseFactoryForDefensive and DF:UseFactoryForDefensive(nil, db))
       or (elementType == "missingBuff" and DF.UseFactoryForMissingBuff and DF:UseFactoryForMissingBuff(nil, db)) then
        DF:InvalidateAuraLayout()
    end

    -- Status icons whose full-render frame level (ApplyIconSettings) is
    -- (parent-of-parent level + value); mirror that here so the Frame Level
    -- slider previews live, matching Scale/Alpha. Keyed elementType -> frame field.
    local SIMPLE_LEVEL_ICONS = {
        resurrection = "resurrectionIcon",
        phased       = "phasedIcon",
        afk          = "afkIcon",
        vehicle      = "vehicleIcon",
        raidRole     = "raidRoleIcon",
        summon       = "summonIcon",
        -- These two had a slider and an export entry but no live consumer: their
        -- Frame Level only ever applied in test mode. Wired here 2026-07-25.
        bgCarrier    = "bgCarrierIcon",
        combat       = "combatIcon",
    }

    local function UpdateLevel(frame)
        if not frame then return end
        
        local baseLevel = frame.contentOverlay and frame.contentOverlay:GetFrameLevel() or frame:GetFrameLevel()
        local frameBaseLevel = frame:GetFrameLevel()
        
        if elementType == "absorb" and frame.dfAbsorbBar then
            frame.dfAbsorbBar:SetFrameLevel(frame:GetFrameLevel() + (db.absorbBarFrameLevel or 11))
        elseif elementType == "role" and frame.roleIcon then
            frame.roleIcon:SetFrameLevel(frameBaseLevel + (db.roleIconFrameLevel or 30))
        elseif elementType == "leader" and frame.leaderIcon then
            frame.leaderIcon:SetFrameLevel(frameBaseLevel + (db.leaderIconFrameLevel or 30))
        elseif elementType == "raidTarget" and frame.raidTargetIcon then
            frame.raidTargetIcon:SetFrameLevel(frameBaseLevel + (db.raidTargetIconFrameLevel or 30))
        elseif elementType == "readyCheck" and frame.readyCheckIcon then
            frame.readyCheckIcon:SetFrameLevel(frameBaseLevel + (db.readyCheckIconFrameLevel or 30))
        else
            -- resurrection / phased / afk / vehicle / raidRole / summon icons
            local field = SIMPLE_LEVEL_ICONS[elementType]
            local icon = field and frame[field]
            if icon then
                local level = db[field .. "FrameLevel"] or 30
                icon:SetFrameLevel(icon:GetParent():GetParent():GetFrameLevel() + level)
            end
        end
    end
    
    IterateFramesInMode(mode, UpdateLevel)
end

-- ============================================================
-- CLASS COLOR OVERRIDE
-- Returns custom class color if set, otherwise falls back to
-- Blizzard's RAID_CLASS_COLORS. Used everywhere in the addon.
-- ============================================================

local DEFAULT_CLASS_COLOR = { r = 0.5, g = 0.5, b = 0.5 }

function DF:GetClassColor(class)
    if not class then return DEFAULT_CLASS_COLOR end
    -- Check for user override
    if DF.db and DF.db.classColors and DF.db.classColors[class] then
        return DF.db.classColors[class]
    end
    return RAID_CLASS_COLORS[class] or DEFAULT_CLASS_COLOR
end

-- Resolve the frame border colour: the static borderColor by default, or
-- (Stage 2.1+) the unit's class / role colour with its own alpha slider when
-- the canonical frameBorderColorSource picks one. Non-player / unknown-class
-- units fall back to the static colour. Handles test frames via fake class
-- and role data. Mirrors Border:BuildSpec so the lightweight live-update
-- path (LightweightUpdateBorderColor) renders identically to the full Apply
-- path on every drag tick of the colour picker / alpha slider.
function DF:GetFrameBorderColor(frame, db)
    local base = db.frameBorderColor or DEFAULT_CLASS_COLOR
    local br, bg, bb, ba = base.r or 0, base.g or 0, base.b or 0, base.a or 1

    -- Resolve source the same way Border:BuildSpec does, so the lightweight
    -- live-update path (LightweightUpdateBorderColor) renders identically to
    -- the full Apply path. ColorSource is the canonical Stage 2 key; the
    -- legacy booleans are honoured as fallback in case the migration shim
    -- hasn't run yet for some code path.
    local source = db.frameBorderColorSource
    if not source then
        if db.frameBorderUseClassColor     then source = "CLASS"
        elseif db.frameBorderUseRoleColor  then source = "ROLE"
        else                                    source = "STATIC" end
    end
    if source == "STATIC" or not frame then
        return br, bg, bb, ba
    end

    -- CLASS / ROLE: RGB from the resolver, alpha from the picker's own alpha
    -- component (frameBorderColor.a — same `ba` above). The unified Border
    -- Alpha slider (Stage 2.4) edits this same component, so picker and
    -- slider stay in sync automatically; no separate alpha key to read.
    local a = ba

    if source == "CLASS" then
        local class
        if frame.dfIsTestFrame then
            local testData = DF.GetTestUnitData and DF:GetTestUnitData(frame.index, frame.isRaidFrame)
            class = testData and testData.class
        elseif frame.unit and UnitExists(frame.unit) then
            -- No UnitIsPlayer gate: class-based NPC party members (e.g.
            -- follower dungeon companions) have a class token too. Units
            -- with no class token fall back to the static colour.
            class = select(2, UnitClass(frame.unit))
        end
        if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
            local c = DF:GetClassColor(class)
            return c.r, c.g, c.b, a
        end
        return br, bg, bb, a
    elseif source == "ROLE" then
        local rc = DF.db and DF.db.roleColors
        local role
        if frame.dfIsTestFrame then
            local testData = DF.GetTestUnitData and DF:GetTestUnitData(frame.index, frame.isRaidFrame)
            role = testData and testData.role
        elseif frame.unit and UnitExists(frame.unit) and UnitGroupRolesAssigned then
            role = UnitGroupRolesAssigned(frame.unit)
            -- UnitGroupRolesAssigned returns "NONE" outside instances where
            -- roles aren't assigned (solo, world content). For the player,
            -- fall back to spec role so role colour stays meaningful. Other
            -- units expose no public spec API; they stay on picker fallback.
            if (not role or role == "NONE") and UnitIsUnit and UnitIsUnit(frame.unit, "player")
               and GetSpecialization and GetSpecializationRole then
                local spec = GetSpecialization()
                if spec then role = GetSpecializationRole(spec) end
            end
        end
        local c = rc and role and role ~= "NONE" and (rc[role] or rc[string.lower(role)])
        if c then
            return c.r or br, c.g or bg, c.b or bb, a
        end
        return br, bg, bb, a
    end

    return br, bg, bb, ba
end

-- Returns custom power color if set, otherwise falls back to
-- Blizzard's PowerBarColor. Checks token first, then numeric type.
function DF:GetPowerColor(powerToken, powerType)
    -- Check for user override by token
    if powerToken and DF.db and DF.db.powerColors and DF.db.powerColors[powerToken] then
        return DF.db.powerColors[powerToken]
    end
    -- Fall back to Blizzard defaults
    if powerToken then
        local info = PowerBarColor[powerToken]
        if info then return info end
    end
    if powerType then
        local info = PowerBarColor[powerType]
        if info then return info end
    end
    return DEFAULT_CLASS_COLOR
end

-- Resolve the resource bar's fill colour for a unit per the configured colour
-- mode. Returns r, g, b (0-1).
--   POWER_TYPE → the power-type colour (user override or Blizzard default)
--   CLASS      → the unit's class colour
--   CUSTOM     → the user's resourceBarCustomColor
-- Honours the legacy resourceBarClassColor boolean when resourceBarColorMode
-- isn't set yet (pre-migration profiles). Uses the same UnitClass/UnitPowerType
-- calls the old inline logic did, so it carries no new secret-value risk.
function DF:GetResourceBarColor(unit, db)
    local mode = db.resourceBarColorMode
    if not mode then
        mode = db.resourceBarClassColor and "CLASS" or "POWER_TYPE"
    end

    if mode == "CUSTOM" then
        local c = db.resourceBarCustomColor or {r = 0, g = 0.5, b = 1, a = 1}
        return c.r or 0, c.g or 0.5, c.b or 1
    elseif mode == "CLASS" then
        local _, classToken = UnitClass(unit)
        local cc = classToken and DF:GetClassColor(classToken)
        if cc then return cc.r, cc.g, cc.b end
        -- No class colour available — fall through to the power-type colour.
    end

    -- POWER_TYPE (and the CLASS fallback above)
    local pType, pToken, altR, altG, altB = UnitPowerType(unit)
    local info = DF:GetPowerColor(pToken, pType)
    if info then return info.r, info.g, info.b end
    if altR then return altR, altG, altB end
    return 0, 0, 1
end

-- Migrate the legacy resourceBarClassColor boolean to the new
-- resourceBarColorMode tri-state. Idempotent; leaves the legacy key in place
-- (the render helper still honours it as a fallback) — same pattern as the
-- border-key migrations.
function DF:MigrateResourceBarColorMode(modeDb)
    if not modeDb then return end
    if modeDb.resourceBarColorMode == nil and modeDb.resourceBarClassColor ~= nil then
        modeDb.resourceBarColorMode = modeDb.resourceBarClassColor and "CLASS" or "POWER_TYPE"
    end
end

-- Pinned frames decouple (2026-06-07): pinned settings are no longer saved as
-- per-raid-layout overrides — only the per-set `enabled` flag is. Strip any
-- stale "pinned.N.<setting>" override keys (setting != enabled) left in saved
-- auto-layout profiles by the old behaviour. Idempotent: once clean, re-running
-- is a no-op, so it is safe to call on every load. Walks ALL DandersFrames
-- profiles (not just the active one), since each carries its own raidAutoProfiles.
function DF:MigratePinnedLayoutOverrides()
    if not DandersFramesDB_v2 or not DandersFramesDB_v2.profiles then return end
    local stripped = 0
    for _, profile in pairs(DandersFramesDB_v2.profiles) do
        local autoDb = profile.raidAutoProfiles
        if type(autoDb) == "table" then
            for _, ct in pairs(autoDb) do
                if type(ct) == "table" and type(ct.profiles) == "table" then
                    for _, layout in ipairs(ct.profiles) do
                        local ov = layout.overrides
                        if type(ov) == "table" then
                            for key in pairs(ov) do
                                local _, setting = key:match("^pinned%.(%d+)%.(.+)$")
                                if setting and setting ~= "enabled" then
                                    ov[key] = nil  -- safe: clearing current key during pairs is allowed
                                    stripped = stripped + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if stripped > 0 then
        DF:Debug("LAYOUT", "MigratePinnedLayoutOverrides: stripped %d stale pinned override(s)", stripped)
    end
end

-- Pinned frames "Match" baseline (2026-06-07): each pinned set inherits its
-- baseline look (size, later border/background) from a mode chosen by
-- set.matchMode ("party"/"raid"). It defaults to the set's OWN mode (a party set
-- mirrors party frames, a raid set mirrors raid frames); the other value lets a
-- set cross-match the opposite mode. nil already resolves to the own mode at
-- runtime, but seed it explicitly so the Match dropdown shows a value. Also
-- converts the short-lived "auto" value to the own mode.
--
-- Width/Height moved from a "Custom Size" toggle to per-key Match overrides:
-- set.customWidth/customHeight are now the override values (nil = inherit Match).
-- Drop the obsolete set.useCustomSize, and where it was off, clear any
-- customWidth/Height that were only seeded for the toggle so they don't read as
-- spurious overrides. Walks ALL profiles (party + raid pinnedFrames.sets).
-- Idempotent.
function DF:MigratePinnedMatchMode()
    if not DandersFramesDB_v2 or not DandersFramesDB_v2.profiles then return end
    for _, profile in pairs(DandersFramesDB_v2.profiles) do
        for _, mode in ipairs({ "party", "raid" }) do
            local modeDb = profile[mode]
            local pf = modeDb and modeDb.pinnedFrames
            if pf and type(pf.sets) == "table" then
                for _, set in pairs(pf.sets) do
                    if type(set) == "table" then
                        if set.matchMode ~= "party" and set.matchMode ~= "raid" then
                            set.matchMode = mode  -- default / repair → the set's own mode
                        end
                        -- One-shot per set (flag): the old-default-to-inherit
                        -- conversions below collide with deliberate values — a
                        -- user setting scale back to exactly 1.0 (or spacing to
                        -- 2) as an override had it cleared to "inherit" on
                        -- every reload. Convert once, then leave the set alone.
                        if not set._matchOverridesV1 then
                            if set.useCustomSize ~= nil then
                                if set.useCustomSize ~= true then
                                    set.customWidth = nil
                                    set.customHeight = nil
                                end
                                set.useCustomSize = nil
                            end
                            -- Scale inherits from the Based-on mode unless overridden:
                            -- a value still at the old hard default (1.0) is treated as
                            -- "inherit" (cleared); a changed value is kept as override.
                            if set.scale == 1.0 then set.scale = nil end
                            -- Spacing inherits the Based-on mode's frameSpacing unless
                            -- overridden: the old hard default was 2, so a value still
                            -- at 2 is treated as "inherit" (cleared); a non-2 value is
                            -- kept as a deliberate override.
                            if set.horizontalSpacing == 2 then set.horizontalSpacing = nil end
                            if set.verticalSpacing == 2 then set.verticalSpacing = nil end
                            set._matchOverridesV1 = true
                        end
                        -- growDirection is a plain pinned-only setting; an earlier
                        -- build briefly cleared its HORIZONTAL default to nil, so
                        -- restore a concrete value for the dropdown.
                        if set.growDirection == nil then set.growDirection = "HORIZONTAL" end
                    end
                end
            end
        end
    end
end

-- ============================================================
-- STATE DRIVERS FOR TEST MODE COMBAT SAFETY
-- When test mode is active, state drivers are registered on all
-- secure frames so that if combat starts, the correct live
-- frames auto-show via the secure state system (no taint).
-- Also handles party<->raid transitions during combat.
-- ============================================================

-- Register state drivers that hide frames out of combat (test mode)
-- but auto-show the correct frames when combat starts.
-- Party frames: show in combat when NOT in a raid group
-- Raid frames: show in combat when in a raid group
function DF:SetTestModeStateDrivers()
    -- Party: hide normally; in combat show unless in a raid group
    -- Uses multi-clause pattern instead of [nogroup:raid] which isn't reliably supported
    local partyCondition = "[combat,group:raid] hide; [combat] show; hide"
    local raidCondition = "[combat,group:raid] show; hide"
    
    -- Party side
    if DF.partyContainer then
        RegisterStateDriver(DF.partyContainer, "visibility", partyCondition)
    end
    if DF.partyHeader then
        RegisterStateDriver(DF.partyHeader, "visibility", partyCondition)
    end
    
    -- Raid side - only register on the correct headers for current mode
    -- Registering on BOTH flat and separated headers causes both to become
    -- visible simultaneously, overlapping frames and corrupting positions
    local raidDb = DF:GetRaidDB()
    local useFlatMode = raidDb and not raidDb.raidUseGroups
    
    if DF.raidContainer then
        RegisterStateDriver(DF.raidContainer, "visibility", raidCondition)
    end
    if useFlatMode then
        -- Flat mode: only register on flat header
        if DF.FlatRaidFrames then
            if DF.FlatRaidFrames.header then
                RegisterStateDriver(DF.FlatRaidFrames.header, "visibility", raidCondition)
            end
            if DF.FlatRaidFrames.innerContainer then
                RegisterStateDriver(DF.FlatRaidFrames.innerContainer, "visibility", raidCondition)
            end
        end
    else
        -- Grouped mode: only register on separated headers
        if DF.raidSeparatedHeaders then
            for i = 1, 8 do
                if DF.raidSeparatedHeaders[i] then
                    RegisterStateDriver(DF.raidSeparatedHeaders[i], "visibility", raidCondition)
                end
            end
        end
    end
    
    DF.testModeStateDriversActive = true
end

-- Register group transition state drivers
-- Shows/hides party vs raid frames based on group type (regardless of combat state)
-- Used when party<->raid conversion happens during combat, and when
-- switching from test mode drivers after combat starts (flicker-free transition)
function DF:SetGroupTransitionStateDrivers()
    -- ARENA FIX: Don't register state drivers in arena.
    -- [group:raid] is true in arena (arena uses raid units), so the state driver
    -- would hide partyContainer (killing the arena header) and show raidContainer.
    if DF.IsInArena and DF:IsInArena() then
        -- If state drivers are already active, clear them
        if DF.testModeStateDriversActive then
            DF:ClearTestModeStateDrivers()
        end
        return
    end
    
    local partyCondition = "[group:raid] hide; show"
    local raidCondition = "[group:raid] show; hide"
    
    -- Party side
    if DF.partyContainer then
        RegisterStateDriver(DF.partyContainer, "visibility", partyCondition)
    end
    if DF.partyHeader then
        RegisterStateDriver(DF.partyHeader, "visibility", partyCondition)
    end
    
    -- Raid side - only register on the correct headers for current mode
    -- Registering on BOTH flat and separated headers causes both to become
    -- visible simultaneously, overlapping frames and corrupting positions
    local raidDb = DF:GetRaidDB()
    local useFlatMode = raidDb and not raidDb.raidUseGroups
    
    if DF.raidContainer then
        RegisterStateDriver(DF.raidContainer, "visibility", raidCondition)
    end
    if useFlatMode then
        -- Flat mode: only register on flat header
        if DF.FlatRaidFrames then
            if DF.FlatRaidFrames.header then
                RegisterStateDriver(DF.FlatRaidFrames.header, "visibility", raidCondition)
            end
            if DF.FlatRaidFrames.innerContainer then
                RegisterStateDriver(DF.FlatRaidFrames.innerContainer, "visibility", raidCondition)
            end
        end
    else
        -- Grouped mode: only register on separated headers
        if DF.raidSeparatedHeaders then
            for i = 1, 8 do
                if DF.raidSeparatedHeaders[i] then
                    RegisterStateDriver(DF.raidSeparatedHeaders[i], "visibility", raidCondition)
                end
            end
        end
    end
    
    DF.testModeStateDriversActive = true
end

-- Unregister all test mode state drivers and reset frame visibility
-- so UpdateHeaderVisibility can manage normally.
-- MUST only be called out of combat.
function DF:ClearTestModeStateDrivers()
    if not DF.testModeStateDriversActive then return end
    
    -- Party side
    if DF.partyContainer then
        UnregisterStateDriver(DF.partyContainer, "visibility")
    end
    if DF.partyHeader then
        UnregisterStateDriver(DF.partyHeader, "visibility")
    end
    
    -- Raid side
    if DF.raidContainer then
        UnregisterStateDriver(DF.raidContainer, "visibility")
    end
    if DF.raidSeparatedHeaders then
        for i = 1, 8 do
            if DF.raidSeparatedHeaders[i] then
                UnregisterStateDriver(DF.raidSeparatedHeaders[i], "visibility")
            end
        end
    end
    if DF.FlatRaidFrames then
        if DF.FlatRaidFrames.header then
            UnregisterStateDriver(DF.FlatRaidFrames.header, "visibility")
        end
        if DF.FlatRaidFrames.innerContainer then
            UnregisterStateDriver(DF.FlatRaidFrames.innerContainer, "visibility")
        end
    end
    
    DF.testModeStateDriversActive = false
end

-- Lightweight color updates for various frame elements
function DF:LightweightUpdateHealthColor()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    -- Check if we're in the relevant test mode
    local inTestMode = (mode == "raid" and DF.raidTestMode) or (mode == "party" and DF.testMode)
    
    -- For gradient mode, we need to rebuild the color curve when colors change
    if db.healthColorMode == "PERCENT" then
        DF:UpdateColorCurve()
    end
    
    local function UpdateFrame(frame, index)
        if not frame or not frame.healthBar then return end
        -- Aura Designer replace mode owns the bar colour exclusively (single layer).
        -- Don't stomp it with the normal health colour while its indicator is active.
        if frame.dfAD and frame.dfAD.healthbar and frame.dfAD.healthbarMode == "replace" then return end

        if db.healthColorMode == "CUSTOM" and db.healthColor then
            local c = db.healthColor
            frame.healthBar:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
        elseif db.healthColorMode == "PERCENT" and inTestMode then
            -- For gradient mode in test mode, get the test data health value
            local isRaid = frame.isRaidFrame
            local testData = DF:GetTestUnitData(index, isRaid)
            if testData then
                local health = testData.healthPercent or testData.health or 0.75
                local color = DF:GetHealthGradientColor(health, db, testData.class)
                if color then
                    frame.healthBar:SetStatusBarColor(color.r, color.g, color.b)
                end
            end
        elseif db.healthColorMode == "CLASS" and inTestMode then
            -- For class color mode in test mode
            local isRaid = frame.isRaidFrame
            local testData = DF:GetTestUnitData(index, isRaid)
            if testData and testData.class then
                local classColor = DF:GetClassColor(testData.class)
                if classColor then
                    frame.healthBar:SetStatusBarColor(classColor.r, classColor.g, classColor.b)
                end
            end
        end
    end
    
    IterateFramesInMode(mode, function(frame) UpdateFrame(frame, 0) end)
    
    -- For live frames with PERCENT or CLASS mode, trigger a full update
    -- since we can't directly set colors due to taint/secret value restrictions
    -- Skip during slider drag to avoid recursion (ThrottledUpdateAll calls back into us)
    if not inTestMode and not DF.sliderDragging and (db.healthColorMode == "PERCENT" or db.healthColorMode == "CLASS") then
        DF:ThrottledUpdateAll()
    end
end

function DF:LightweightUpdateBackgroundColor()
    -- Set flag to prevent UpdateBackgroundAppearance from overwriting during color adjustment
    DF.isAdjustingBackgroundColor = true
    
    -- Clear flag after a short delay (longer than the range update interval of 0.2s)
    if DF.bgColorAdjustTimer then
        DF.bgColorAdjustTimer:Cancel()
    end
    DF.bgColorAdjustTimer = C_Timer.NewTimer(0.3, function()
        DF.isAdjustingBackgroundColor = false
    end)
    
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local bgTexture = db.backgroundTexture or "Solid"
    local bgMode = db.backgroundColorMode or "CUSTOM"
    
    local function UpdateFrame(frame, testClass)
        if not frame or not frame.background then return end
        
        -- Clear the background key cache so the new settings will be applied
        frame.dfCurrentBgKey = nil
        
        -- Determine class color for CLASS mode
        local cr, cg, cb = 0, 0, 0
        if bgMode == "CLASS" then
            local cc
            if testClass then
                -- Test mode - use provided class
                cc = DF:GetClassColor(testClass)
            elseif frame.unit and UnitExists(frame.unit) then
                -- Live mode - get from unit
                local _, class = UnitClass(frame.unit)
                cc = class and DF:GetClassColor(class)
            end
            if cc then cr, cg, cb = cc.r, cc.g, cc.b end
        end
        
        if bgTexture == "Solid" or bgTexture == "" then
            -- Solid color mode - update cache and key
            frame.dfCurrentBgTexture = "Solid"
            if bgMode == "CUSTOM" and db.backgroundColor then
                local c = db.backgroundColor
                frame.background:SetColorTexture(c.r, c.g, c.b, c.a or 0.8)
                frame.dfCurrentBgKey = string.format("CUSTOM:%.2f:%.2f:%.2f:%.2f", c.r, c.g, c.b, c.a or 0.8)
            elseif bgMode == "CLASS" then
                local bgAlpha = db.backgroundClassAlpha or 0.3
                frame.background:SetColorTexture(cr, cg, cb, bgAlpha)
                frame.dfCurrentBgKey = string.format("CLASS:%.2f:%.2f:%.2f:%.2f", cr, cg, cb, bgAlpha)
            else
                -- Fallback - use default background
                local c = db.backgroundColor or {r = 0.1, g = 0.1, b = 0.1, a = 0.8}
                frame.background:SetColorTexture(c.r, c.g, c.b, c.a or 0.8)
                frame.dfCurrentBgKey = string.format("CUSTOM:%.2f:%.2f:%.2f:%.2f", c.r, c.g, c.b, c.a or 0.8)
            end
        else
            -- Textured background - always apply when called from settings (user is changing texture)
            -- Update cache so UpdateUnitFrame knows the current texture
            frame.background:SetTexture(bgTexture)
            frame.background:SetHorizTile(false)
            frame.background:SetVertTile(false)
            frame.dfCurrentBgTexture = bgTexture
            
            -- Ensure SetAlpha is 1.0 for textured backgrounds (alpha controlled via vertex color only)
            frame.background:SetAlpha(1.0)
            
            if bgMode == "CUSTOM" and db.backgroundColor then
                local c = db.backgroundColor
                frame.background:SetVertexColor(c.r, c.g, c.b, c.a or 0.8)
            elseif bgMode == "CLASS" then
                local bgAlpha = db.backgroundClassAlpha or 0.3
                frame.background:SetVertexColor(cr, cg, cb, bgAlpha)
            else
                -- Fallback - use default background
                local c = db.backgroundColor or {r = 0.1, g = 0.1, b = 0.1, a = 0.8}
                frame.background:SetVertexColor(c.r, c.g, c.b, c.a or 0.8)
            end
        end
    end
    
    IterateFramesInMode(mode, function(frame) UpdateFrame(frame, nil) end)
end

function DF:LightweightUpdateBorderColor()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end

    local function UpdateFrame(frame)
        if not frame or not frame.border then return end
        -- Route through SetBorderColor so it recolours whichever mode (solid
        -- edges or texture backdrop) is currently active. Resolved per-frame
        -- via GetFrameBorderColor so class / role colours pick up each
        -- unit's resolved colour. Border alpha rides frameBorderColor.a
        -- (there is no separate alpha key) and is honoured on every drag tick.
        if frame.border.SetBorderColor then
            frame.border:SetBorderColor(DF:GetFrameBorderColor(frame, db))
        end
    end

    IterateFramesInMode(mode, UpdateFrame)
end


function DF:LightweightUpdateAbsorbBarColor()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local function UpdateFrame(frame)
        if not frame then return end
        
        -- Update main absorb bar
        if frame.dfAbsorbBar and db.absorbBarColor then
            local c = db.absorbBarColor
            frame.dfAbsorbBar:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
        end
        if frame.dfAbsorbBar and frame.dfAbsorbBar.bg and db.absorbBarBackgroundColor then
            local c = db.absorbBarBackgroundColor
            frame.dfAbsorbBar.bg:SetColorTexture(c.r, c.g, c.b, c.a or 1)
        end
        
        -- Update overflow bar (for ATTACHED_OVERFLOW mode)
        if frame.absorbOverflowBar and db.absorbBarColor then
            local c = db.absorbBarColor
            frame.absorbOverflowBar:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
        end
    end
    
    IterateFramesInMode(mode, UpdateFrame)
end

function DF:LightweightUpdateReducedMaxHealthColor()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db or not db.reducedMaxHealthColor then return end
    local c = db.reducedMaxHealthColor

    local function UpdateFrame(frame)
        if frame and frame.dfReducedMaxHealthBar then
            frame.dfReducedMaxHealthBar:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
        end
    end

    IterateFramesInMode(mode, UpdateFrame)
end

function DF:LightweightUpdateHealAbsorbBarColor()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local function UpdateFrame(frame)
        if not frame or not frame.dfHealAbsorbBar then return end
        if db.healAbsorbBarColor then
            local c = db.healAbsorbBarColor
            frame.dfHealAbsorbBar:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
        end
        if frame.dfHealAbsorbBar.bg and db.healAbsorbBarBackgroundColor then
            local c = db.healAbsorbBarBackgroundColor
            frame.dfHealAbsorbBar.bg:SetColorTexture(c.r, c.g, c.b, c.a or 1)
        end
    end
    
    IterateFramesInMode(mode, UpdateFrame)
end

function DF:LightweightUpdateSelectionHighlightColor()
    -- Just call the generic highlight update for selection
    DF:LightweightUpdateHighlight("selection")
end

-- (LightweightUpdateExpiringBorderColor / ...TintColor removed 2026-07-25 with the
-- pre-12.1 Expiring system: both had already degenerated to empty stubs because
-- remaining time is secret on the container rows. The 12.1-safe reveal is the
-- DF.Expiration engine, which re-specs through the normal drive.)

-- Update missing buff icon border color
function DF:LightweightUpdateMissingBuffBorderColor()
    -- 12.1: badge borders re-spec through the strip drive.
    DF:InvalidateAuraLayout()
end

-- Update defensive icon colors (border and duration text)
function DF:LightweightUpdateDefensiveIconColors()
    -- 12.1: the defensive container re-styles through the drive.
    DF:InvalidateAuraLayout()
    -- Test previews restyle through the same drive on their next pass.
    if (DF.testMode or DF.raidTestMode) and DF.UpdateAllTestDefensiveBar then
        DF:UpdateAllTestDefensiveBar()
    end
end

-- Update group label color
function DF:LightweightUpdateGroupLabelColor()
    if not DF.raidGroupLabels then return end
    
    local db = DF:GetRaidDB()
    local color = db.groupLabelColor or {r = 1, g = 1, b = 1, a = 1}
    
    for _, label in pairs(DF.raidGroupLabels) do
        if label then
            label:SetTextColor(color.r, color.g, color.b, color.a or 1)
        end
    end
end

-- Update resource/power bar background color
function DF:LightweightUpdateResourceBarBackgroundColor()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local bgColor = db.resourceBarBackgroundColor or {r = 0.1, g = 0.1, b = 0.1, a = 0.8}
    
    local function UpdateFrame(frame)
        if not frame or not frame.dfPowerBar or not frame.dfPowerBar.bg then return end
        frame.dfPowerBar.bg:SetColorTexture(bgColor.r, bgColor.g, bgColor.b, bgColor.a or 0.8)
    end
    
    IterateFramesInMode(mode, UpdateFrame)
end

-- Update resource bar border visibility and color
function DF:LightweightUpdateResourceBarBorder()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end

    local function UpdateFrame(frame)
        if not frame or not frame.dfPowerBar or not frame.dfPowerBar.border then return end
        -- Route through BuildSpec + Apply (Stage 4.2) so the live drag-
        -- update path renders identically to ApplyResourceBarLayout.
        -- ctx.unit / ctx.frame let Class / Role resolvers fire.
        DF.Border:Apply(frame.dfPowerBar.border,
            DF.Border:BuildSpec(db, "resourceBar", {
                unit  = frame.unit,
                frame = frame,
            }))
    end

    IterateFramesInMode(mode, UpdateFrame)
end

-- Update resource bar border color only
function DF:LightweightUpdateResourceBarBorderColor()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end

    local function UpdateFrame(frame)
        if not frame or not frame.dfPowerBar or not frame.dfPowerBar.border then return end
        DF.Border:Apply(frame.dfPowerBar.border,
            DF.Border:BuildSpec(db, "resourceBar", {
                unit  = frame.unit,
                frame = frame,
            }))
    end

    IterateFramesInMode(mode, UpdateFrame)
end

-- Update resource bar frame level
function DF:LightweightUpdateResourceBarFrameLevel()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local frameLevelOffset = db.resourceBarFrameLevel or 20
    
    local function UpdateFrame(frame)
        if not frame or not frame.dfPowerBar then return end
        local bar = frame.dfPowerBar
        local baseLevel = frame:GetFrameLevel()
        bar:SetFrameLevel(baseLevel + frameLevelOffset)
        -- Border needs to be above the bar
        if bar.border then
            bar.border:SetFrameLevel(bar:GetFrameLevel() + 1)
        end
    end
    
    IterateFramesInMode(mode, UpdateFrame)
end

-- Update dispel overlay colors directly (for test mode preview only)
-- IMPORTANT: Only updates test mode frames to preserve secret color handling on live frames
-- (DF:LightweightUpdateDispelColors was removed with the dispel Custom Colors
-- mode, 2026-07-11 — its per-type picker callbacks were its only callers.)


-- ============================================================
-- UTF-8 STRING HELPERS
-- ============================================================
-- Standard string.len and string.sub operate on bytes, not characters.
-- Cyrillic, Asian, and other non-ASCII characters are multi-byte in UTF-8.

-- Count actual UTF-8 characters (not bytes)
function DF:UTF8Len(str)
    if not str then return 0 end
    
    -- Check for secret values (WoW privacy system for arena opponents)
    if issecretvalue and issecretvalue(str) then return 0 end
    
    local len = 0
    local i = 1
    local strLen = #str
    while i <= strLen do
        local byte = string.byte(str, i)
        if not byte then break end  -- Safety check
        if byte < 128 then
            -- ASCII (0-127): 1 byte
            i = i + 1
        elseif byte < 224 then
            -- 2-byte sequence (128-2047)
            i = i + 2
        elseif byte < 240 then
            -- 3-byte sequence (2048-65535)
            i = i + 3
        else
            -- 4-byte sequence (65536+)
            i = i + 4
        end
        len = len + 1
    end
    return len
end

-- UTF-8 aware substring (by character count, not bytes)
function DF:UTF8Sub(str, startChar, endChar)
    if not str then return "" end
    
    -- Check for secret values (WoW privacy system for arena opponents)
    if issecretvalue and issecretvalue(str) then return "" end
    
    local strLen = #str
    local charCount = 0
    local startByte = 1
    local endByte = strLen
    
    local i = 1
    while i <= strLen do
        charCount = charCount + 1
        
        -- Find start byte
        if charCount == startChar then
            startByte = i
        end
        
        -- Determine byte length of current character
        local byte = string.byte(str, i)
        local charBytes
        if byte < 128 then
            charBytes = 1
        elseif byte < 224 then
            charBytes = 2
        elseif byte < 240 then
            charBytes = 3
        else
            charBytes = 4
        end
        
        -- Find end byte
        if charCount == endChar then
            endByte = i + charBytes - 1
            break
        end
        
        i = i + charBytes
    end
    
    return string.sub(str, startByte, endByte)
end

-- ============================================================
-- UNIT NAME API (hookable by external addons)
-- ============================================================
-- SECRET VALUE HANDLING (Midnight 12.0)
-- ============================================================

-- ============================================================
-- AURA DEBUG
-- ============================================================

function DF:DebugAuraFilters(unit)
    if not UnitExists(unit) then
        DF:Err("Unit '" .. unit .. "' does not exist.")
        return
    end
    
    local filters = {
        "HELPFUL",
        "HELPFUL|PLAYER",
        "HELPFUL|RAID",
        "HELPFUL|PLAYER|RAID",
        "HELPFUL|CANCELABLE",
    }
    
    local o = DF:Out("Aura Data", "unit " .. unit)
    
    for _, filter in ipairs(filters) do
        local count = 0
        local found = {}
        for i = 1, 40 do
            local auraData = nil
            if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
                auraData = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)
            end
            if not auraData then break end
            
            local name = "?"
            local spellId = "?"
            pcall(function() name = auraData.name or "?" end)
            pcall(function() spellId = auraData.spellId or "?" end)
            
            found[#found + 1] = { i, tostring(name) .. " (ID: " .. tostring(spellId) .. ")" }
            count = count + 1
        end
        o:Section(filter, count)
        for _, row in ipairs(found) do
            o:Item(row[1], row[2])
        end
        if count == 0 then
            -- An empty pool is normal, not a fault: the unit simply has no aura
            -- matching that filter right now.
            o:Line("none", "neutral")
        end
    end
    
    -- Check what Blizzard filter functions are available.
    -- CompactUnitFrame_UtilShouldDisplayBuff is NOT probed any more: it does not
    -- exist anywhere in the 12.1 client source, so the old test could only ever
    -- report "N/A" for every aura.
    o:Section("Blizzard filter functions")
    local hasSDB = AuraUtil and AuraUtil.ShouldDisplayBuff ~= nil
    local hasFEA = AuraUtil and AuraUtil.ForEachAura ~= nil
    o:Field("AuraUtil.ShouldDisplayBuff", hasSDB and "present" or "absent", hasSDB and "good" or "warn")
    o:Field("AuraUtil.ForEachAura", hasFEA and "present" or "absent", hasFEA and "good" or "warn")

    o:Section("ShouldDisplayBuff per aura")
    if AuraUtil and AuraUtil.ForEachAura then
        local rows = {}
        -- usePackedAura MUST be true. The signature is
        --   ForEachAura(unit, filter, batchSize, func, usePackedAura)
        -- and without that last argument the callback receives the legacy
        -- UNPACKED arg list, so `auraData` was the aura NAME STRING — which is
        -- why every row printed "? (ID: ?)".
        AuraUtil.ForEachAura(unit, "HELPFUL", nil, function(auraData)
            local name, spellId, verdict = "?", "?", "N/A"
            pcall(function() name = auraData.name or "?" end)
            pcall(function() spellId = auraData.spellId or "?" end)

            -- Real signature: ShouldDisplayBuff(unitCaster, spellId, canApplyAura).
            -- The old call passed the whole auraData table as unitCaster, which
            -- fell through to the final `else` and returned false for everything.
            if AuraUtil.ShouldDisplayBuff then
                local ok, result = pcall(function()
                    return AuraUtil.ShouldDisplayBuff(auraData.sourceUnit, auraData.spellId, auraData.canApplyAura)
                end)
                verdict = ok and tostring(result) or ("ERROR: " .. tostring(result))
            end

            table.insert(rows, { name = name, spellId = spellId, verdict = verdict })
            return false  -- continue iteration
        end, true)

        if #rows == 0 then
            o:Line("none", "neutral")
        end
        for _, r in ipairs(rows) do
            -- The verdict is the ANSWER, not a health signal - only a pcall
            -- failure is a fault, so plain false stays untinted.
            o:Item(tostring(r.name) .. " (ID: " .. tostring(r.spellId) .. ")", r.verdict,
                r.verdict:match("^ERROR") and "bad" or nil)
        end
    else
        o:Line("AuraUtil.ForEachAura not available", "bad")
    end

    o:Siblings("auradata")
end

-- ============================================================
-- DATABASE MANAGEMENT
-- ============================================================

function DF:GetDB(mode)
    if not DF.db then
        return mode == "raid" and DF.RaidDefaults or DF.PartyDefaults
    end
    return DF.db[mode or "party"]
end

function DF:GetRaidDB()
    return DF:GetDB("raid")
end

-- ============================================================
-- CONTENT TYPE DETECTION
-- Unified approach using IsInInstance() for all content detection
-- ============================================================

-- Cache for content type (updated on zone change)
DF.cachedContentType = nil
DF.cachedInstanceType = nil

-- Debug: Force arena mode for testing (toggle with /df debug arena)
DF.forceArenaMode = false

-- Get the current content type for frame/profile switching
-- Returns: "arena", "battleground", "mythic", "instanced", "openWorld", or nil
function DF:GetContentType()
    -- DEBUG: Force arena mode for testing
    if DF.forceArenaMode then
        DF.cachedContentType = "arena"
        return "arena"
    end

    -- ARENA RELOAD FIX: snapshot the saved content-type hint ONCE, before any
    -- detection branch below can overwrite it. Early calls (e.g.
    -- FinalizeHeaderInit → UpdateHeaderVisibility at ADDON_LOADED on a reload)
    -- run while IsInInstance()/IsInRaid() may still be unreliable; without the
    -- snapshot, those calls wiped DandersFramesCharDB.lastContentType (or
    -- overwrote it with "openWorld") before the reload fallback could use it.
    if not DF._contentTypeHintCaptured and DandersFramesCharDB then
        DF._contentTypeHintCaptured = true
        DF._contentTypeHintAtLoad = DandersFramesCharDB.lastContentType
    end

    local inInstance, instanceType = IsInInstance()
    
    -- Cache instance type for other uses
    DF.cachedInstanceType = instanceType
    
    -- Arena - always uses party-style frames (but with raid unit IDs)
    if instanceType == "arena" then
        DF.cachedContentType = "arena"
        DF.useContentTypeFallback = nil  -- Clear fallback, real detection working
        if DandersFramesCharDB then DandersFramesCharDB.lastContentType = "arena" end
        return "arena"
    end
    
    -- Battleground (PvP instance)
    if instanceType == "pvp" then
        DF.cachedContentType = "battleground"
        DF.useContentTypeFallback = nil
        if DandersFramesCharDB then DandersFramesCharDB.lastContentType = "battleground" end
        return "battleground"
    end
    
    -- Not in a raid group - no raid content type applies
    if not IsInRaid() then
        -- ARENA RELOAD FIX: If IsInInstance() AND IsInRaid() both return false after a
        -- reload, WoW's APIs haven't recovered yet. Check the saved content type from
        -- before the reload. Only trust "arena" — other types recover fine on their own.
        if DF.useContentTypeFallback and not inInstance
           and (instanceType == "none" or instanceType == nil)
           and DF._contentTypeHintAtLoad == "arena" then
            DF.cachedContentType = "arena"
            return "arena"
        end
        
        DF.cachedContentType = nil
        DF.useContentTypeFallback = nil
        if DandersFramesCharDB then DandersFramesCharDB.lastContentType = nil end
        return nil
    end
    
    -- Raid instance
    if instanceType == "raid" then
        local difficultyID = select(3, GetInstanceInfo())
        if difficultyID == 16 then
            DF.cachedContentType = "mythic"
            DF.useContentTypeFallback = nil
            if DandersFramesCharDB then DandersFramesCharDB.lastContentType = "mythic" end
            return "mythic"
        end
        DF.cachedContentType = "instanced"
        DF.useContentTypeFallback = nil
        if DandersFramesCharDB then DandersFramesCharDB.lastContentType = "instanced" end
        return "instanced"
    end
    
    -- In a raid group but not in an instance = open world (world boss, etc.)
    if IsInRaid() then
        -- ARENA RELOAD FIX (part 2): IsInRaid() can recover before
        -- IsInInstance() after a reload in arena (arena groups ARE raid
        -- groups). Without this, the not-yet-recovered instanceType made us
        -- conclude "openWorld" — showing raid frames over the arena header
        -- and overwriting the saved arena hint.
        if DF.useContentTypeFallback and not inInstance
           and (instanceType == "none" or instanceType == nil)
           and DF._contentTypeHintAtLoad == "arena" then
            DF.cachedContentType = "arena"
            return "arena"
        end

        DF.cachedContentType = "openWorld"
        DF.useContentTypeFallback = nil
        if DandersFramesCharDB then DandersFramesCharDB.lastContentType = "openWorld" end
        return "openWorld"
    end
    
    DF.cachedContentType = nil
    DF.useContentTypeFallback = nil
    if DandersFramesCharDB then DandersFramesCharDB.lastContentType = nil end
    return nil
end

-- Check if we're in arena (convenience function)
function DF:IsInArena()
    local contentType = DF:GetContentType()
    return contentType == "arena"
end

-- Check if we're in a battleground (convenience function)
function DF:IsInBattleground()
    local contentType = DF:GetContentType()
    return contentType == "battleground"
end

-- ============================================================
-- DEBUG: Force Arena Mode
-- Usage: /df debug arena - Toggle arena mode for testing.
-- ⚠ The "/dfarena" alias below is the REGISTRY SPELLING, not a working bind: it is
-- /df-prefixed, so RegisterDebugSlash routes it to DebugSlashBySub["arena"] and
-- deliberately creates no SLASH_ global (only non-/df aliases like "/rl" get one).
-- Typing "/dfarena" does nothing. That is the intended shape — one command form —
-- but it read as a promise, so both the comment above and CLAUDE.md claimed it worked.
-- Requires being in a raid group to see frames
-- ============================================================
DF:RegisterDebugSlash("DFARENA", "Toggle arena test mode (raid group)", false, "/dfarena")
SlashCmdList["DFARENA"] = function(msg)
    if InCombatLockdown() then
        DF:Say(L["Cannot toggle arena mode during combat"])
        return
    end
    
    DF.forceArenaMode = not DF.forceArenaMode
    
    if DF.forceArenaMode then
        local o = DF:Out("Arena", "test mode enabled")
        o:Line(L["Join a raid group (2-5 players works best)"], "NEUTRAL")
        o:Line(L["Arena header will show using raid1-5 unit IDs"], "NEUTRAL")
        o:Line(L["Uses party frame settings/position"], "NEUTRAL")
        -- NOT o:Hints("/df debug arena"): a "More:" footer naming the command you just
        -- ran reads as a bug. Toggles say so in words instead.
        o:Line(format(L["Run %s again to turn this off."], "/df debug arena"), "NEUTRAL")
    else
        DF:Say(format(L["Arena mode %sDISABLED%s"], "|cffff0000", "|r"))
    end
    
    -- Apply full header settings (includes orientation, grow from center, etc.)
    if DF.ApplyHeaderSettings then
        DF:ApplyHeaderSettings()
    end
    
    -- Update frame visibility
    if DF.UpdateHeaderVisibility then
        DF:UpdateHeaderVisibility()
    end
    
    -- Trigger a roster update to refresh everything
    if DF.ProcessRosterUpdate then
        DF:ProcessRosterUpdate()
    end
    
    -- Refresh all live frames to apply party styling
    if DF.RefreshLiveFrames then
        C_Timer.After(0.1, function()
            DF:RefreshLiveFrames()
        end)
    end
end

-- Get current mode based on group size
function DF:GetCurrentMode()
    if IsInRaid() then
        return "raid"
    end
    return "party"
end

-- Deep copy helper (also defined in Profile.lua, but needed here too)
-- Note: DeepCopy, ResetProfile and CopyProfile are defined in Profile.lua

-- (Removed) DF:ApplySavedCVarSettings — it force-stamped Blizzard's
-- raidFramesDispelIndicatorType CVar from _blizzDispelIndicator, a key no
-- GUI has written since the v4.3.4 dispel-source rework (the visible
-- dropdown writes dispelOverlayDispelType, which only drives DF's own
-- overlay). The stamp silently re-imposed a frozen value on Blizzard's
-- frames every login and fought changes made anywhere else. The saved key
-- is stripped in the v5 legacy-aura cleanup below.

-- Deep equality check for the proxy contamination guard.
-- Lua's == is reference equality for tables, so a new table with identical
-- contents would bypass the guard and leak override values into _realRaidDB.
local function DeepEquals(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not DeepEquals(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- ============================================================
-- DB OVERLAY PROXY
-- Wraps DF.db so auto-profile overrides are read-through without
-- mutating the real SavedVariables table.
-- ============================================================

function DF:WrapDB()
    -- Store references to the real (serializable) tables
    self._realProfile = self.db
    self._realRaidDB  = self._realProfile.raid

    -- Raid proxy: reads check raidOverrides first, writes go to real table
    local raidProxy = setmetatable({}, {
        __realTable = self._realRaidDB,
        __index = function(_, key)
            local overrides = DF.raidOverrides
            if overrides and overrides[key] ~= nil then
                return overrides[key]
            end
            return DF._realRaidDB[key]
        end,
        __newindex = function(_, key, value)
            -- Guard against override value contamination: if a runtime auto profile
            -- is active and the write value matches the override, it's a read-then-write
            -- loop (not an intentional user change) — block it to keep the global clean.
            local overrides = DF.raidOverrides
            if overrides and overrides[key] ~= nil then
                local apu = DF.AutoProfilesUI
                if apu and apu.activeRuntimeProfile and not apu:IsEditing() then
                    if DeepEquals(value, overrides[key]) then
                        return
                    end
                end
            end
            DF._realRaidDB[key] = value
        end,
    })
    self._raidProxy = raidProxy

    -- Profile proxy: intercepts .raid access, everything else falls through
    self.db = setmetatable({}, {
        __isDBProxy = true,
        __index = function(_, key)
            if key == "raid" then
                return raidProxy
            end
            return DF._realProfile[key]
        end,
        __newindex = function(_, key, value)
            if key == "raid" then
                -- Full raid table replacement (e.g. import)
                DF._realProfile.raid = value
                DF._realRaidDB = value
                -- Update the raid proxy's metatable reference
                local mt = getmetatable(raidProxy)
                mt.__realTable = value
            else
                DF._realProfile[key] = value
            end
        end,
    })
end

-- ============================================================
-- INITIALIZATION
-- ============================================================

-- ------------------------------------------------------------
-- Unsupported-version guard
-- This build is 12.1-only (TOC Interface 120100). WoW hides it as out-of-date
-- on older clients, but a user with "Load out of date AddOns" enabled would run
-- it on the wrong version and hit bugs. Warn them to install the matching build.
-- Uses its OWN frame so the popup fires even if the main init trips on the wrong
-- client. Only fires for OLDER clients (< 12.1); newer clients are left alone.
-- ------------------------------------------------------------
do
    local MIN_INTERFACE = 120100  -- 12.1.0
    local clientToc = select(4, GetBuildInfo())
    if type(clientToc) == "number" and clientToc < MIN_INTERFACE then
        local guardFrame = CreateFrame("Frame")
        guardFrame:RegisterEvent("PLAYER_LOGIN")
        guardFrame:SetScript("OnEvent", function(self)
            self:UnregisterAllEvents()
            local L = DF.L
            if DF.ShowPopupAlert then
                DF:ShowPopupAlert({
                    title = L["Unsupported Game Version"],
                    message = L["DandersFrames doesn't support this version of the game.\n\nThis build is made for World of Warcraft 12.1. Please install the version that matches your client from CurseForge or Wago."],
                    icon = "Interface\\Icons\\INV_Misc_QuestionMark",
                    buttons = {
                        { label = L["OK"], onClick = nil },
                    },
                })
            end
        end)
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_ROLES_ASSIGNED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")  -- Fires when spec changes
eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")  -- Fires when talents change
eventFrame:RegisterEvent("UNIT_PET")  -- Fires when a pet is summoned/dismissed
eventFrame:RegisterEvent("PLAYER_UPDATE_RESTING")  -- Fires when entering/leaving rested area

-- One-shot copy of legacy Frame Border saved-variable keys to the canonical
-- `frame*Border*` naming the unified DF.Border / CreateBorderControls helpers
-- expect. Called per-mode from ADDON_LOADED. Idempotent: if the new key
-- already exists in the profile we leave it (the user has saved with the new
-- key); otherwise we adopt the legacy value. Legacy keys are NOT deleted so
-- the migration can be safely re-run and old profiles stay readable by a
-- previous addon version if the user rolls back.
function DF:MigrateFrameBorderKeys(modeDb)
    if not modeDb then return end
    local function adopt(newKey, oldKey)
        if modeDb[newKey] == nil and modeDb[oldKey] ~= nil then
            modeDb[newKey] = modeDb[oldKey]
        end
    end
    adopt("frameShowBorder",         "showFrameBorder")
    adopt("frameBorderSize",         "borderSize")
    adopt("frameBorderColor",        "borderColor")
    adopt("frameBorderStyle",        "borderStyle")
    adopt("frameBorderTexture",      "borderTexture")
    adopt("frameBorderUseClassColor","borderClassColor")

    -- ColorSource (single segmented key) supersedes the independent
    -- UseClassColor / UseRoleColor booleans. Copy whichever was true into
    -- the new key; leave the booleans intact so an old client can still
    -- read them.
    if modeDb.frameBorderColorSource == nil then
        if modeDb.frameBorderUseClassColor     then modeDb.frameBorderColorSource = "CLASS"
        elseif modeDb.frameBorderUseRoleColor  then modeDb.frameBorderColorSource = "ROLE"
        end
    end

    -- Gradient was previously an independent boolean (`<prefix>BorderGradientEnabled`)
    -- that overlaid on top of Style; Stage 2.3 folded it into Style as a
    -- third option so the user can't get conflicting "Solid + Class Color +
    -- Gradient" combinations. Adopt: if the old boolean is true and the
    -- style isn't already explicitly set to TEXTURE (which would be a
    -- deliberate other-mode choice), promote to "GRADIENT". Old boolean is
    -- left in place for rollback safety.
    local function adoptGradientStyle(prefix)
        local styleKey   = prefix .. "BorderStyle"
        local enabledKey = prefix .. "BorderGradientEnabled"
        if modeDb[enabledKey] == true and modeDb[styleKey] ~= "TEXTURE"
                and modeDb[styleKey] ~= "GRADIENT" then
            modeDb[styleKey] = "GRADIENT"
        end
    end
    adoptGradientStyle("frame")
    adoptGradientStyle("defensiveIcon")
end

-- Move the role-border colour set from per-mode storage (Stage 2 default
-- placement) up to profile level under DF.db.roleColors so the global Colors
-- settings page can manage them alongside class colours. Idempotent: only
-- adopts a mode-level value into profile-level when profile-level doesn't
-- already have one set, and only seeds defaults when neither exists. Called
-- once per ADDON_LOADED after both modes have been migrated.
function DF:MigrateRoleBorderColors()
    if not DF.db then return end
    if not DF.db.roleColors then DF.db.roleColors = {} end
    local rc = DF.db.roleColors

    local DEFAULTS = {
        TANK    = {r = 0.20, g = 0.55, b = 0.95, a = 1},
        HEALER  = {r = 0.20, g = 0.80, b = 0.30, a = 1},
        DAMAGER = {r = 0.85, g = 0.20, b = 0.20, a = 1},
    }

    -- Adopt from whichever mode-level set was customised first.
    local sources = { DF.db.party, DF.db.raid }
    local function adopt(role, modeKey)
        if rc[role] then return end
        for _, m in ipairs(sources) do
            if m and m[modeKey] then rc[role] = m[modeKey]; return end
        end
        rc[role] = DEFAULTS[role]
    end
    adopt("TANK",    "roleBorderColorTank")
    adopt("HEALER",  "roleBorderColorHealer")
    adopt("DAMAGER", "roleBorderColorDamager")
end

-- Adopt the legacy `resourceBarBorderEnabled` boolean into the canonical
-- `resourceBarShowBorder` key the unified DF.Border helper expects. Same
-- pattern as MigrateFrameBorderKeys — idempotent, leaves the legacy key
-- in place for rollback safety. Stage 4.2.
function DF:MigrateResourceBarBorderKeys(modeDb)
    if not modeDb then return end
    if modeDb.resourceBarShowBorder == nil and modeDb.resourceBarBorderEnabled ~= nil then
        modeDb.resourceBarShowBorder = modeDb.resourceBarBorderEnabled
    end
end

-- Aura icon borders: rename the legacy buff/debuff keys to the canonical
-- ShowBorder / BorderSize so they plug into BuildSpec + CreateBorderControls
-- (Stage 5.5 Phase 2 — full border toolkit for buff/debuff). Same idempotent,
-- leaves-the-legacy-key pattern as MigrateFrameBorderKeys.
function DF:MigrateAuraBorderKeys(modeDb)
    if not modeDb then return end
    for _, p in ipairs({ "buff", "debuff" }) do
        if modeDb[p .. "ShowBorder"] == nil and modeDb[p .. "BorderEnabled"] ~= nil then
            modeDb[p .. "ShowBorder"] = modeDb[p .. "BorderEnabled"]
        end
        if modeDb[p .. "BorderSize"] == nil and modeDb[p .. "BorderThickness"] ~= nil then
            modeDb[p .. "BorderSize"] = modeDb[p .. "BorderThickness"]
        end
    end
    -- (The buffExpiringBorderPulsate -> ...AnimationType migration was removed with the
    -- pre-12.1 Expiring system on 2026-07-25 — both keys are gone, so there is nothing
    -- left to migrate between.)
end

-- ============================================================
-- BORDER INSET FOLD / ZERO  (appearance-preserving migration)
--
-- The unified-border rework changed two border families' inset semantics, so
-- older profiles render oddly under the new (correct) offset model. One-time,
-- per-profile guarded; rewrites the stored values to keep the pre-rework look.
--
-- 1) AURA DESIGNER icon/square (_borderInsetFoldV1): old visible band was
--    BorderSize + BorderInset (inset EXTENDED the band, straddling the edge);
--    new = BorderSize alone, inset a pure outward offset (spec.inset =
--    -BorderInset), so a stored inset now floats the band in a gap. Fold the
--    inset back into size (BorderSize += BorderInset, likewise
--    ExpiringBorderSize; BorderInset = 0), clamped to the slider cap. No-op at 0.
--
-- 2) BUFF/DEBUFF icons (_buffDebuffInsetZeroV1): changed the OPPOSITE way — old
--    band = 2*thickness - inset (inset REDUCED width, hugging the edge); new =
--    the same icon-mode model, so the stored inset floats it in a gap. Fix is to
--    ZERO the inset, written EXPLICITLY (the render falls back to the legacy
--    `or 1` when the key is absent, which would keep the gap), and stripped from
--    raid auto-layout overrides so each layout inherits the zeroed base.
--
-- Iterates the raw SavedVariables profiles directly (never the WrapDB proxy).
-- The preset-library walk is nil-guarded, so this is correct with or without
-- the Designer Presets feature present.
-- ============================================================
local AD_BORDER_SIZE_MAX = 5   -- AD border-size slider cap (AuraDesigner/Options.lua)

local function FoldIndicatorBorderInset(ind, seen)
    if type(ind) ~= "table" then return end
    if seen[ind] then return end       -- a materialised inline config and its
    seen[ind] = true                   -- library copy may share this table ref
    local t = ind.type
    if t ~= "icon" and t ~= "square" then return end
    local inset = ind.BorderInset or ind.borderInset
    if not inset or inset == 0 then
        -- Nothing to fold; drop any lingering legacy inset key so a render
        -- fallback can't later resurrect a stale value.
        ind.borderInset = nil
        return
    end
    local function foldSize(v)
        local folded = (v or 1) + inset
        if folded < 0 then folded = 0 end
        if folded > AD_BORDER_SIZE_MAX then folded = AD_BORDER_SIZE_MAX end
        return folded
    end
    ind.BorderSize = foldSize(ind.BorderSize or ind.borderThickness)
    if ind.ExpiringBorderSize then
        ind.ExpiringBorderSize = foldSize(ind.ExpiringBorderSize)
    end
    ind.BorderInset = 0
    -- Clear legacy duplicates so the render fallback can't reintroduce pre-fold
    -- geometry.
    ind.borderThickness = nil
    ind.borderInset = nil
end

local function FoldAuraDesignerConfig(cfg, seen)
    if type(cfg) ~= "table" or type(cfg.auras) ~= "table" then return end
    for _, entry in pairs(cfg.auras) do
        if type(entry) == "table" then
            if entry.indicators then
                -- Flat (V1) shape: auras[auraName] = auraCfg
                for _, ind in ipairs(entry.indicators) do
                    FoldIndicatorBorderInset(ind, seen)
                end
            else
                -- Per-spec shape: auras[spec][auraName] = auraCfg
                for _, auraCfg in pairs(entry) do
                    if type(auraCfg) == "table" and type(auraCfg.indicators) == "table" then
                        for _, ind in ipairs(auraCfg.indicators) do
                            FoldIndicatorBorderInset(ind, seen)
                        end
                    end
                end
            end
        end
    end
end

-- Write 0 EXPLICITLY (don't just leave absent): the render falls back to the
-- legacy `or 1` when the key is missing (Update.lua), which would keep the gap.
local function ZeroBuffDebuffBorderInset(profile)
    for _, modeKey in ipairs({ "party", "raid" }) do
        local mode = profile[modeKey]
        if type(mode) == "table" then
            mode.buffBorderInset = 0
            mode.debuffBorderInset = 0
        end
    end
    -- Raid auto-layout overrides: strip the inset keys so each layout inherits
    -- the now-zeroed base (mirrors CleanupLegacyTextLayoutOverrides' traversal).
    -- Pinned sets don't override buff/debuff keys, so they inherit the base.
    local autoDb = profile.raidAutoProfiles
    if type(autoDb) == "table" then
        local function stripLayout(layout)
            local ov = layout and layout.overrides
            if type(ov) ~= "table" then return end
            ov.buffBorderInset = nil
            ov.debuffBorderInset = nil
        end
        for _, ctKey in ipairs({ "instanced", "openWorld" }) do
            local ct = autoDb[ctKey]
            if type(ct) == "table" and type(ct.profiles) == "table" then
                for _, layout in pairs(ct.profiles) do stripLayout(layout) end
            end
        end
        if type(autoDb.mythic) == "table" then stripLayout(autoDb.mythic.profile) end
    end
end

-- Fold the legacy per-element OOR name-text alpha into the unified oorTextAlpha.
-- The Text Designer now renders all unit text, so a single OOR "Text Alpha" dims
-- every TD element out of range. Carry the user's old name-text value only when
-- they changed it from the prior default (1); default-config users get the new
-- oorTextAlpha default instead. Per-profile guarded so later oorTextAlpha edits stick.
function DF:MigrateOORTextAlpha()
    if not DandersFramesDB_v2 or not DandersFramesDB_v2.profiles then return end
    for _, profile in pairs(DandersFramesDB_v2.profiles) do
        if type(profile) == "table" then
            for _, modeKey in ipairs({ "party", "raid" }) do
                local m = profile[modeKey]
                if type(m) == "table" then
                    -- Fold the retired per-element name-alpha into the unified
                    -- oorTextAlpha whenever it is PRESENT (a non-default value),
                    -- not gated on the _oorTextAlphaV1 flag: a v4 export imported
                    -- over an already-migrated profile reintroduces
                    -- oorNameTextAlpha, and a flag-gated fold would skip it while
                    -- the strip below still deletes it — silently resetting the
                    -- imported OOR alpha. oorNameTextAlpha only ever exists on
                    -- un-folded data (this pass strips it), so presence is the
                    -- correct trigger and can't clobber a deliberate oorTextAlpha.
                    if m.oorNameTextAlpha ~= nil and m.oorNameTextAlpha ~= 1 then
                        m.oorTextAlpha = m.oorNameTextAlpha
                    end
                    -- The per-element keys are retired (every reader now uses
                    -- oorTextAlpha; stale values were still driving the pet /
                    -- legacy fontstring and test-preview paths, unreachable by
                    -- any control). Strip AFTER the fold above has consumed the
                    -- name value; idempotent, and with the Config defaults gone
                    -- the backfill can't reseed them.
                    m.oorNameTextAlpha = nil
                    m.oorHealthTextAlpha = nil
                end
            end
            profile._oorTextAlphaV1 = true
        end
    end
end
-- One-shot per-profile, two independently-guarded steps so a profile already
-- through step 1 still receives step 2. Both steps are value-idempotent.
function DF:MigrateBorderInsetFold()
    if not DandersFramesDB_v2 or not DandersFramesDB_v2.profiles then return end
    for _, profile in pairs(DandersFramesDB_v2.profiles) do
        if type(profile) == "table" then
            -- Step 1: AD icon/square fold (preset libraries + inline configs).
            if not profile._borderInsetFoldV1 then
                local seen = {}
                -- Canonical store when Designer Presets exist (nil-guarded so this
                -- stays correct where they don't).
                local lib = profile.auraDesignerPresets
                if type(lib) == "table" then
                    for _, presetCfg in pairs(lib) do
                        FoldAuraDesignerConfig(presetCfg, seen)
                    end
                end
                if type(profile.party) == "table" then
                    FoldAuraDesignerConfig(profile.party.auraDesigner, seen)
                end
                if type(profile.raid) == "table" then
                    FoldAuraDesignerConfig(profile.raid.auraDesigner, seen)
                end
                profile._borderInsetFoldV1 = true
            end
            -- Step 2: zero buff/debuff border inset (mode-level + raid overrides).
            if not profile._buffDebuffInsetZeroV1 then
                ZeroBuffDebuffBorderInset(profile)
                profile._buffDebuffInsetZeroV1 = true
            end
        end
    end
end

-- One-time cleanup: the legacy raidGroupOrder ("NORMAL"/"REVERSE") toggle is
-- deprecated -- group order now comes solely from the Group Display Order /
-- My Group First feature (raidGroupDisplayOrder), which every positioner honours.
-- The live header path never applied raidGroupOrder, but the test/legacy Lua
-- positioner did, so a stale "REVERSE" made test/legacy disagree with live. The
-- reverse code is gone; NORMAL-ize any lingering value so it can't mislead
-- exports/debug. Per-profile guarded; idempotent. (Re-reverse via Group Display Order.)
function DF:MigrateDeprecateRaidGroupOrder()
    if not DandersFramesDB_v2 or not DandersFramesDB_v2.profiles then return end
    for _, profile in pairs(DandersFramesDB_v2.profiles) do
        if type(profile) == "table" and not profile._raidGroupOrderRetiredV1 then
            if type(profile.party) == "table" and profile.party.raidGroupOrder == "REVERSE" then
                profile.party.raidGroupOrder = "NORMAL"
            end
            if type(profile.raid) == "table" and profile.raid.raidGroupOrder == "REVERSE" then
                profile.raid.raidGroupOrder = "NORMAL"
            end
            profile._raidGroupOrderRetiredV1 = true
        end
    end
end


-- One-time conversion to ABSOLUTE frame levels (v5.0.0-alpha.12).
-- Before: 0 was a SENTINEL meaning "use my built-in default", and that default differed
-- per element (status icons contentOverlay+5, missing buff contentOverlay+10, defensive 51),
-- while the Aura Designer slider was an offset silently added to 40. Two sliders both
-- reading 0 therefore rendered at different heights, and 0 was unreachable as a real value.
-- After: the stored number IS the offset from the unit frame everywhere, so 50 sits above 40.
-- Converts stored values so nothing MOVES; only the number shown changes. Per-profile
-- guarded and idempotent.
local ABS_LEVEL_SENTINEL_DEFAULT = {
    roleIconFrameLevel = 30, leaderIconFrameLevel = 30, raidTargetIconFrameLevel = 30,
    readyCheckIconFrameLevel = 30, resurrectionIconFrameLevel = 30,
    phasedIconFrameLevel = 30, afkIconFrameLevel = 30, vehicleIconFrameLevel = 30,
    raidRoleIconFrameLevel = 30, summonIconFrameLevel = 30, bgCarrierIconFrameLevel = 30,
    combatIconFrameLevel = 30, missingBuffIconFrameLevel = 35, defensiveIconFrameLevel = 65,
}
-- (Removed) ABS_LEVEL_ADDEND = { targetedSpellFrameLevel = 30 }. Its only key belonged
-- to the group-frame display and has no readers left.
--
-- ☠ It was not merely inert. The loop applied `(tonumber(modeDb[key]) or 0) + addend`
-- UNCONDITIONALLY, so for any profile without the migration flag it CREATED
-- targetedSpellFrameLevel = 30 in both the party and raid tables — including profiles
-- that never had the key. A migration that invents a key nothing reads is not covered
-- by change-the-baseline: that rule preserves what the user set.

function DF:MigrateAbsoluteFrameLevels()
    if not DandersFramesDB_v2 or not DandersFramesDB_v2.profiles then return end
    for _, profile in pairs(DandersFramesDB_v2.profiles) do
        if type(profile) == "table" and not profile._absoluteFrameLevelsV1 then
            for _, mode in ipairs({ "party", "raid" }) do
                local modeDb = profile[mode]
                if type(modeDb) == "table" then
                    for key, builtin in pairs(ABS_LEVEL_SENTINEL_DEFAULT) do
                        -- Only 0 carried the sentinel meaning; a real value was already an
                        -- offset from the unit frame and is left exactly as the user set it.
                        if modeDb[key] == 0 or modeDb[key] == nil then modeDb[key] = builtin end
                    end
                    -- Aura Designer global default: the render added 40 to it.
                    local ad = modeDb.auraDesigner
                    if type(ad) == "table" and type(ad.defaults) == "table" then
                        ad.defaults.indicatorFrameLevel = (tonumber(ad.defaults.indicatorFrameLevel) or 0) + 40
                    end
                end
            end
            profile._absoluteFrameLevelsV1 = true
        end

        -- V2 (alpha-only correction). V1 wrote the defensive baseline as 51, the legacy
        -- value. A /df debug zorder dump then showed 51 is BROKEN: an aura row is ~16 levels
        -- thick, so the buff/debuff rows (base 40) reach 60 and draw over the defensive
        -- button at 57. The baseline moved to 65, but a profile that already ran V1 has a
        -- stored 51 that nothing would ever revisit -- Config defaults only fill MISSING
        -- keys. Correct that one value in place.
        --
        -- Deliberately NOT folded into V1: V1 also shifts targetedSpell by +30 and the AD
        -- default by +40, so re-running it under a new flag would double-shift both.
        --
        -- Only touches the exact broken value, and only on a profile V1 has stamped, so a
        -- fresh install (already 65) and a deliberate non-51 choice are both left alone.
        if type(profile) == "table" and profile._absoluteFrameLevelsV1
           and not profile._defensiveBaselineV2 then
            for _, mode in ipairs({ "party", "raid" }) do
                local modeDb = profile[mode]
                if type(modeDb) == "table" and modeDb.defensiveIconFrameLevel == 51 then
                    modeDb.defensiveIconFrameLevel = 65
                end
            end
            profile._defensiveBaselineV2 = true
        end
    end
end

-- A profile created from Config defaults is ALREADY in the current shape, so every
-- one-time migration has to treat it as done. Most migrations here derive from a
-- legacy value and are naturally no-ops on a fresh profile (the rule stated in the
-- ADDON_LOADED block). The exceptions are the ones that write UNCONDITIONALLY behind
-- a profile-stored flag -- and because that flag is not part of Config, a brand-new
-- profile did not carry it and got shifted:
--   * MigrateAbsoluteFrameLevels  -- auraDesigner.defaults.indicatorFrameLevel
--     40 -> 80 (already ABSOLUTE in Config; the render's own `or 40` fallback proves
--     it). It also shifted targetedSpellFrameLevel until that key's reader went with
--     the group display and the addend was removed.
--   * MigratePersonalContainerPosition -- personalTargetedSpellX 0 -> 92.
-- On a fresh install the AD value was then folded into the Party/Raid designer
-- preset on first login, making it permanent.
--
-- The flag cannot simply be added to PartyDefaults: the defaults backfill runs
-- BEFORE MigratePersonalContainerPosition, so legacy profiles would be stamped as
-- migrated before they actually migrated. Stamp at CREATION instead.
--
-- Any future migration that cannot derive its answer from a legacy value must list
-- its flag here as well as writing it.
local FRESH_PROFILE_MIGRATION_FLAGS = {
    _absoluteFrameLevelsV1 = true,
    _defensiveBaselineV2   = true,
}
local FRESH_PROFILE_PARTY_MIGRATION_FLAGS = {
    _personalContainerCenterMigrated = true,
}

function DF:StampFreshProfileMigrations(profile)
    if type(profile) ~= "table" then return end
    for k, v in pairs(FRESH_PROFILE_MIGRATION_FLAGS) do
        profile[k] = v
    end
    if type(profile.party) == "table" then
        for k, v in pairs(FRESH_PROFILE_PARTY_MIGRATION_FLAGS) do
            profile.party[k] = v
        end
    end
end

-- Transition shim (unreleased-only): an earlier iteration of the priority flip
-- converted values to the new higher-wins scale and then stamped a COARSE flag —
-- profile-level for Aura Designer, store-level for Click Casting. The replacement
-- lazy migrations (DF.MigrateAuraDesignerPrioritiesLazy / CC:MigratePrioritiesLazy)
-- key off a FINER flag (per resolved adDB table / per CC profile). Forward the
-- coarse flags to the fine ones WITHOUT touching any value, so data already
-- converted by the old pass is never double-flipped. Purely additive + idempotent
-- (only sets flags); a no-op for anyone who never ran the old pass. Auto-layout
-- overlays are intentionally left unstamped — the old pass never converted them,
-- so the lazy migration must still flip those on first resolve.
function DF:ForwardPriorityMigrationFlags()
    local function stamp(adDB) if type(adDB) == "table" then adDB._priorityHigherWinsV1 = true end end
    if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
        for _, profile in pairs(DandersFramesDB_v2.profiles) do
            if type(profile) == "table" and profile._priorityHigherWinsV1 then
                if type(profile.party) == "table" then stamp(profile.party.auraDesigner) end
                if type(profile.raid) == "table" then stamp(profile.raid.auraDesigner) end
                if type(profile.auraDesignerPresets) == "table" then
                    for _, presetCfg in pairs(profile.auraDesignerPresets) do stamp(presetCfg) end
                end
            end
        end
    end
    local ccdb = DandersFramesClickCastingDB
    if ccdb and ccdb._priorityHigherWinsV1 and type(ccdb.classes) == "table" then
        for _, classData in pairs(ccdb.classes) do
            if type(classData) == "table" and type(classData.profiles) == "table" then
                for _, profile in pairs(classData.profiles) do
                    if type(profile) == "table" then profile._priorityHigherWinsV1 = true end
                end
            end
        end
    end
end

-- One-time: carry the old bespoke important-spell highlight settings
-- (targetedSpellHighlightStyle/Color/Size/Inset) into the new Important Spell
-- Border key set (targetedSpellImportantBorder*), which is a second DF.Border
-- gated by the Highlight-Important toggle. Defaults already match the old
-- defaults, so untouched profiles need nothing; this only preserves customised
-- highlights. Per-profile guarded. Style maps onto a DF.Border animation type.
function DF:MigrateTargetedSpellImportantBorder()
    if not DandersFramesDB_v2 or not DandersFramesDB_v2.profiles then return end
    local styleToAnim = { glow = "DF_PROC", marchingAnts = "DF_DASH", pulse = "DF_PULSATE",
                          solidBorder = "NONE", none = "NONE" }
    -- Copy a feature's old <prefix>Highlight* keys into its new
    -- <prefix>ImportantBorder* set. Gated ONLY by the per-profile _…V1 flag in the
    -- caller (so it runs exactly once); do NOT also guard on the new key being nil —
    -- the ADDON_LOADED default-merge fills the new …ImportantBorder* keys before this
    -- runs, so a nil-guard would never fire and the old highlight settings would be
    -- lost. At first run the user can't have set the new keys yet, so overwriting the
    -- just-merged defaults with their old highlight values is exactly the intent.
    -- Mirrors MigrateBorderInsetFold. Shared by the group (targetedSpell) and personal
    -- (personalTargetedSpell) sets.
    local function mapHighlight(m, p)
        if m[p.."HighlightColor"] ~= nil then
            -- Copy into independent tables: the color picker mutates color
            -- tables in place, so sharing one reference would link the static
            -- and animation colors (editing one would change the other).
            local c = m[p.."HighlightColor"]
            m[p.."ImportantBorderColor"] = { r = c.r, g = c.g, b = c.b, a = c.a }
            m[p.."ImportantBorderAnimationColor"] = { r = c.r, g = c.g, b = c.b, a = c.a }
        end
        if m[p.."HighlightSize"] ~= nil then
            m[p.."ImportantBorderSize"] = m[p.."HighlightSize"]
        end
        if m[p.."HighlightInset"] ~= nil then
            m[p.."ImportantBorderInset"] = m[p.."HighlightInset"]
        end
        if m[p.."HighlightStyle"] ~= nil then
            m[p.."ImportantBorderAnimationType"] = styleToAnim[m[p.."HighlightStyle"]] or "DF_PROC"
        end
    end
    for _, profile in pairs(DandersFramesDB_v2.profiles) do
        if type(profile) == "table" then
            -- Group/party Targeted Spells. Guarded independently from personal so a
            -- profile already through this step still receives the personal one.
            -- (Removed) the group half, mapHighlight(m, "targetedSpell"). It mapped the
            -- old highlight keys onto targetedSpellImportantBorder*, which has no
            -- readers now the group display is gone. Conditional on the legacy key, so
            -- unlike the frame-level addend it only touched old profiles — but it still
            -- wrote keys nothing will read. The _tsImportantBorderV1 flag is left on
            -- profiles that already have it; it is never read again.
            -- Personal Targeted Spell — LIVE, do not touch.
            if not profile._personalTsImportantBorderV1 then
                for _, modeKey in ipairs({ "party", "raid" }) do
                    local m = profile[modeKey]
                    if type(m) == "table" then mapHighlight(m, "personalTargetedSpell") end
                end
                profile._personalTsImportantBorderV1 = true
            end
        end
    end
end

-- The handler body is stored on DF as _MainEventDispatcher so the profiler
-- can swap it for an instrumented version at runtime. The frame's actual
-- script is a thin trampoline that calls through DF — re-binding takes
-- effect immediately without re-running SetScript.
DF._MainEventDispatcher = function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        -- Initialize saved variables with profile support
        if not DandersFramesDB_v2 then
            DandersFramesDB_v2 = {
                currentProfile = "Default",
                profiles = {
                    ["Default"] = {
                        party = DF:DeepCopy(DF.PartyDefaults),
                        raid = DF:DeepCopy(DF.RaidDefaults),
                    }
                },
            }
            -- Born from current defaults => every one-time migration is already done.
            DF:StampFreshProfileMigrations(DandersFramesDB_v2.profiles["Default"])
        end
        
        -- Initialize per-character saved variables
        if not DandersFramesCharDB then
            DandersFramesCharDB = {
                enableSpecSwitch = false,
                specProfiles = {},
                currentProfile = nil,  -- seeded from account-wide on first login
            }
        end
        
        -- Migrate from old DandersFramesDB_v2.char to per-character DB (one-time migration)
        if DandersFramesDB_v2.char then
            -- Only migrate if this character hasn't been set up yet
            if not DandersFramesCharDB.enableSpecSwitch and DandersFramesDB_v2.char.enableSpecSwitch then
                DandersFramesCharDB.enableSpecSwitch = DandersFramesDB_v2.char.enableSpecSwitch
            end
            -- Note: We don't migrate specProfiles because the old data was shared
            -- and likely incorrect for this character anyway
        end
        
        -- Ensure structure exists in per-character DB
        if DandersFramesCharDB.specProfiles == nil then DandersFramesCharDB.specProfiles = {} end

        -- ARENA RELOAD FIX: snapshot the saved content-type hint before any
        -- GetContentType call can overwrite it (GetContentType also
        -- self-captures; this pins the earliest possible point), and arm the
        -- fallback NOW on a /reload — the player only already exists at
        -- ADDON_LOADED on a reload (same detection Headers.lua uses for the
        -- combat-safe finalize). PLAYER_ENTERING_WORLD also arms it
        -- (isReloadingUi), but that's too late for the FinalizeHeaderInit →
        -- UpdateHeaderVisibility call that runs inside the ADDON_LOADED
        -- combat-safe window on a combat reload in arena.
        -- Fresh logins must NOT arm it: a stale "arena" hint from a previous
        -- session would misclassify the login zone (the fallback only clears
        -- once real detection returns a definite answer).
        if not DF._contentTypeHintCaptured then
            DF._contentTypeHintCaptured = true
            DF._contentTypeHintAtLoad = DandersFramesCharDB.lastContentType
        end
        if UnitExists("player") then
            DF.useContentTypeFallback = true
        end

        -- Language override lives per-character because the locale files
        -- need to read it at file-load time, before any profile resolution
        -- happens. SavedVariablesPerCharacter is available at that stage.
        if DandersFramesCharDB.languageOverride == nil then
            -- Migrate from the earlier per-profile slot if any profile had it set
            local migrated = "AUTO"
            if DandersFramesDB_v2.profiles then
                for _, profile in pairs(DandersFramesDB_v2.profiles) do
                    if profile.languageOverride and profile.languageOverride ~= "AUTO" then
                        migrated = profile.languageOverride
                        break
                    end
                end
            end
            DandersFramesCharDB.languageOverride = migrated
        end
        -- Clean up legacy per-profile key (no longer read anywhere)
        if DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                profile.languageOverride = nil
            end
        end

        -- Apply language override: the locale files populated
        -- DF_AllLocales[locale] at file-scope; we now overlay the chosen
        -- locale's strings onto AceLocale's app table. Non-enUS client
        -- locales also flow through here (they populate only the side
        -- table, not AceLocale directly, so the app otherwise has just
        -- the enUS baseline).
        if DF_AllLocales then
            local override = DandersFramesCharDB.languageOverride
            local active = (override and override ~= "AUTO") and override or GetLocale()
            if active ~= "enUS" and DF_AllLocales[active] then
                local aceL = DF.L
                for k, v in pairs(DF_AllLocales[active]) do
                    -- AceLocale stores L["key"] = true as L["key"] = "key"
                    -- (the key string); we preserve that convention for
                    -- any `true` values in DF_AllLocales, though real
                    -- translations are already strings.
                    rawset(aceL, k, v == true and k or v)
                end
            end
            -- Free the side-table now that the overlay is applied. Changing
            -- languageOverride requires a /reload (enforced by the dropdown
            -- popup), which re-populates DF_AllLocales on the next load, so
            -- we don't need to keep it around for subsequent lookups.
            DF_AllLocales = nil
        end

        -- Rebuild any file-scope label tables now that the locale
        -- overlay has been applied (see DF:RegisterLocaleRefresh above).
        DF:RunLocaleRefreshers()

        -- Seed per-character profile from account-wide on first login for this character
        if not DandersFramesCharDB.currentProfile then
            DandersFramesCharDB.currentProfile = DandersFramesDB_v2.currentProfile
        end

        -- Migrate from old format (profile.party/raid) to new format (profiles)
        if DandersFramesDB_v2.profile and not DandersFramesDB_v2.profiles then
            DandersFramesDB_v2.profiles = {
                ["Default"] = DandersFramesDB_v2.profile
            }
            DandersFramesDB_v2.currentProfile = "Default"
            DandersFramesDB_v2.profile = nil  -- Remove old format
        end
        
        -- Ensure structure exists
        if not DandersFramesDB_v2.profiles then DandersFramesDB_v2.profiles = {} end
        if not DandersFramesDB_v2.currentProfile then DandersFramesDB_v2.currentProfile = "Default" end
        -- (Removed) wizardConfigs was seeded here for WizardBuilder.lua, which is
        -- gone. Nothing ever READ the table — it was write-only even while the
        -- builder was reachable — so there is nothing to migrate. Any key already
        -- in a user's SavedVariables is simply ignored and left alone.
        if not DandersFramesDB_v2.global then DandersFramesDB_v2.global = {} end

        -- Track last seen version for auto-showing changelog on update
        if not DandersFramesDB_v2.lastSeenVersion then
            DandersFramesDB_v2.lastSeenVersion = DF.VERSION
        end
        if not DandersFramesDB_v2.profiles["Default"] then
            DandersFramesDB_v2.profiles["Default"] = {
                party = DF:DeepCopy(DF.PartyDefaults),
                raid = DF:DeepCopy(DF.RaidDefaults),
                raidAutoProfiles = DF:DeepCopy(DF.RaidAutoProfilesDefaults),
                classColors = {},
                powerColors = {},
                linkedSections = {},
                partyEnabled = true,
                raidEnabled = true,
                -- Current default, not the pre-Roboto face: seeding Friz here made a
                -- freshly created profile flip its settings font by itself on the
                -- next reload (the _settingsFontRobotoDefaultV1 pass below).
                settingsFont = "DF Roboto SemiBold",
                settingsFontOutline = "NONE",
            }
            -- Born from current defaults => every one-time migration is already done.
            DF:StampFreshProfileMigrations(DandersFramesDB_v2.profiles["Default"])
        end
        
        -- Set current profile (per-character takes priority over account-wide)
        local currentProfile = DandersFramesCharDB.currentProfile or DandersFramesDB_v2.currentProfile
        if not DandersFramesDB_v2.profiles[currentProfile] then
            currentProfile = "Default"
        end
        -- Keep both in sync
        DandersFramesCharDB.currentProfile = currentProfile
        DandersFramesDB_v2.currentProfile = currentProfile

        DF.db = DandersFramesDB_v2.profiles[currentProfile]
        
        -- Ensure both modes exist in current profile
        if not DF.db.party then DF.db.party = DF:DeepCopy(DF.PartyDefaults) end
        if not DF.db.raid then DF.db.raid = DF:DeepCopy(DF.RaidDefaults) end
        
        -- Ensure raidAutoProfiles exists in current profile
        if not DF.db.raidAutoProfiles then
            DF.db.raidAutoProfiles = DF:DeepCopy(DF.RaidAutoProfilesDefaults)
        end

        -- Migrate legacy Frame Border keys (borderSize / showFrameBorder /
        -- borderColor / borderStyle / borderTexture / borderClassColor /
        -- frameBorderUseClassColor / frameBorderUseRoleColor) to the canonical
        -- `frame*Border*` naming + new frameBorderColorSource segmented key.
        -- One-shot copy per mode: if a new key already exists we leave it
        -- (user has already saved with the new key); otherwise we adopt the
        -- old value.
        if DF.MigrateFrameBorderKeys then
            DF:MigrateFrameBorderKeys(DF.db.party)
            DF:MigrateFrameBorderKeys(DF.db.raid)
        end
        -- Resource Bar: resourceBarBorderEnabled → resourceBarShowBorder
        -- (Stage 4.2 wire-up to the unified DF.Border helper).
        if DF.MigrateResourceBarBorderKeys then
            DF:MigrateResourceBarBorderKeys(DF.db.party)
            DF:MigrateResourceBarBorderKeys(DF.db.raid)
        end
        -- Resource Bar: resourceBarClassColor (bool) → resourceBarColorMode (tri-state).
        if DF.MigrateResourceBarColorMode then
            DF:MigrateResourceBarColorMode(DF.db.party)
            DF:MigrateResourceBarColorMode(DF.db.raid)
        end
        -- Pinned frames decouple: strip stale pinned.N.<setting> auto-layout
        -- overrides (everything except the per-set `enabled` flag).
        if DF.MigratePinnedLayoutOverrides then
            DF:MigratePinnedLayoutOverrides()
        end
        -- Pinned frames: seed matchMode (each set's own mode) on existing sets so
        -- the Match baseline dropdown shows a value (nil already resolves to it).
        if DF.MigratePinnedMatchMode then
            DF:MigratePinnedMatchMode()
        end
        -- Aura icons: buff/debuffBorderEnabled → ShowBorder, BorderThickness →
        -- BorderSize (Stage 5.5 Phase 2 — full toolkit for buff/debuff borders).
        if DF.MigrateAuraBorderKeys then
            DF:MigrateAuraBorderKeys(DF.db.party)
            DF:MigrateAuraBorderKeys(DF.db.raid)
        end
        -- Promote role border colours from per-mode storage to profile-level
        -- DF.db.roleColors so the global Colors settings page manages them.
        if DF.MigrateRoleBorderColors then
            DF:MigrateRoleBorderColors()
        end
        -- Frame Level sliders now store an ABSOLUTE offset from the unit frame
        -- rather than 0-as-sentinel; convert stored values so nothing moves.
        if DF.MigrateAbsoluteFrameLevels then
            DF:MigrateAbsoluteFrameLevels()
        end
        
        -- Ensure classColors table exists (shared across party/raid)
        if not DF.db.classColors then
            DF.db.classColors = {}
        end
        
        -- Ensure powerColors table exists (shared across party/raid)
        if not DF.db.powerColors then
            DF.db.powerColors = {}
        end

        -- Ensure linkedSections table exists (shared across party/raid)
        if not DF.db.linkedSections then
            DF.db.linkedSections = {}
        end

        -- Ensure mode-enable flags exist (default true for backward compatibility)
        if DF.db.partyEnabled == nil then DF.db.partyEnabled = true end
        if DF.db.raidEnabled == nil then DF.db.raidEnabled = true end

        -- Ensure settings-panel font defaults exist (default DF Roboto SemiBold;
        -- the old-default flip for existing profiles runs in the per-profile loop below)
        if DF.db.settingsFont        == nil then DF.db.settingsFont        = "DF Roboto SemiBold" end
        -- Outline "None" is stored canonically as "NONE" everywhere; normalise the
        -- legacy empty-string the old hand-rolled settings dropdown wrote.
        if DF.db.settingsFontOutline == nil or DF.db.settingsFontOutline == "" then DF.db.settingsFontOutline = "NONE" end

        -- Ensure top-level font preferences exist (SDF rendering toggle from PR #115)
        if DF.db.fontSlug == nil then DF.db.fontSlug = false end

        -- Snapshot the enable-flag state at load time. After profile switches
        -- or imports, we compare against this to decide whether to prompt for
        -- a UI reload. The actual headers are created based on this state and
        -- can only be (un)created on /reload.
        DF.loadedPartyEnabled = DF.db.partyEnabled ~= false
        DF.loadedRaidEnabled  = DF.db.raidEnabled  ~= false

        -- Apply user's Settings Panel font (safe no-op if GUI/DFFonts.lua hasn't loaded yet;
        -- SetupGUIPages also calls this again after the GUI frame exists)
        if DF.GUI and DF.GUI.ApplySettingsFont then
            DF.GUI:ApplySettingsFont()
        end

        -- Ensure auraBlacklist table exists (profile-level, shared across party/raid)
        if not DF.db.auraBlacklist then
            DF.db.auraBlacklist = { buffs = {}, debuffs = {} }
        end
        if not DF.db.auraBlacklist.buffs then DF.db.auraBlacklist.buffs = {} end
        if not DF.db.auraBlacklist.debuffs then DF.db.auraBlacklist.debuffs = {} end

        -- Migrate legacy blacklist entries: true → { combat = true, ooc = true }
        for _, key in ipairs({"buffs", "debuffs"}) do
            for spellId, val in pairs(DF.db.auraBlacklist[key]) do
                if val == true then
                    DF.db.auraBlacklist[key][spellId] = { combat = true, ooc = true }
                end
            end
        end

        -- Migrate any missing settings from defaults (all profiles)
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                if profile.party then
                    for key, value in pairs(DF.PartyDefaults) do
                        if profile.party[key] == nil then
                            profile.party[key] = DF:DeepCopy(value)
                        end
                    end
                end
                if profile.raid then
                    for key, value in pairs(DF.RaidDefaults) do
                        if profile.raid[key] == nil then
                            profile.raid[key] = DF:DeepCopy(value)
                        end
                    end
                end
                -- Dispel colours are account-wide (per profile, mode-independent —
                -- edited on the Colors page; sibling of classColors). Seed ONCE from
                -- the profile's existing per-mode debuff-border palette so any
                -- customisations carry over; otherwise the game palette. The per-mode
                -- debuffBorderColor* keys are left in place.
                if type(profile.dispelColors) ~= "table" then
                    local src = profile.party or {}
                    -- Defaults = Blizzard's live game palette (GetGameDispelPalette). No
                    -- None key — the None/Physical border is hidden on no-dispel-type auras.
                    local D = (DF.GetGameDispelPalette and DF:GetGameDispelPalette()) or DF.DispelDefaultColors
                    local function seedColor(key, d)
                        local c = src[key]
                        if type(c) == "table" and c.r then return { r = c.r, g = c.g, b = c.b } end
                        return { r = d.r, g = d.g, b = d.b }
                    end
                    profile.dispelColors = {
                        Magic   = seedColor("debuffBorderColorMagic",   D.Magic),
                        Curse   = seedColor("debuffBorderColorCurse",   D.Curse),
                        Disease = seedColor("debuffBorderColorDisease", D.Disease),
                        Poison  = seedColor("debuffBorderColorPoison",  D.Poison),
                        Bleed   = seedColor("debuffBorderColorBleed",   D.Bleed),
                    }
                end
                -- Ensure mode-enable flags exist on every profile
                if profile.partyEnabled == nil then profile.partyEnabled = true end
                if profile.raidEnabled == nil then profile.raidEnabled = true end

                -- Ensure settings-panel font defaults exist on every profile
                if profile.settingsFont        == nil then profile.settingsFont        = "DF Roboto SemiBold" end
                -- One-time: the settings-panel font default changed from the WoW
                -- default (Friz Quadrata) to DF Roboto SemiBold. Flip profiles that
                -- still carry the old auto-written default — nobody picks Friz over
                -- DF Roboto deliberately — but only ONCE, so a later explicit Friz
                -- choice sticks.
                if not profile._settingsFontRobotoDefaultV1 then
                    if profile.settingsFont == "Friz Quadrata TT" then
                        profile.settingsFont = "DF Roboto SemiBold"
                    end
                    profile._settingsFontRobotoDefaultV1 = true
                end
                if profile.settingsFontOutline == nil or profile.settingsFontOutline == "" then profile.settingsFontOutline = "NONE" end

                -- Backfill missing auraDesigner.defaults keys.
                -- The top-level migration (pairs(PartyDefaults) above) skips auraDesigner
                -- when the subtable already exists, leaving new nested keys un-migrated.
                for _, mode in ipairs({ "party", "raid" }) do
                    local ad = profile[mode] and profile[mode].auraDesigner
                    if ad then
                        if not ad.defaults then ad.defaults = {} end
                        if ad.defaults.indicatorFrameStrata == nil then
                            ad.defaults.indicatorFrameStrata = "INHERIT"
                        end
                        -- 40, matching the Config baseline. This value is ABSOLUTE:
                        -- AuraDesigner/Factory.lua resolves it as
                        --   level = (d and tonumber(d.indicatorFrameLevel)) or 40
                        -- so nothing adds a base to it, and the `or 40` is only a
                        -- fallback for a MISSING key. Seeding 0 therefore did not mean
                        -- "baseline" — 0 is truthy in Lua, so it beat the fallback and
                        -- dropped every untouched indicator from 40 to 0.
                        --
                        -- Reachable for any profile with an auraDesigner subtable but no
                        -- defaults table: MigrateAbsoluteFrameLevels skips those (it
                        -- requires defaults to already be a table), which leaves this
                        -- seed as the only thing that ever fills the key.
                        --
                        -- Only ever SEEDS a missing key — a stored value is left alone.
                        if ad.defaults.indicatorFrameLevel == nil then
                            ad.defaults.indicatorFrameLevel = 40
                        end
                    end
                end
            end
        end

        -- Migrate any missing settings for raidAutoProfiles
        for key, value in pairs(DF.RaidAutoProfilesDefaults) do
            if DF.db.raidAutoProfiles[key] == nil then
                DF.db.raidAutoProfiles[key] = DF:DeepCopy(value)
            end
        end
        
        -- (Removed) The externalDef* -> defensiveIcon* adoption migration. It
        -- was UNREACHABLE for its entire life: the defaults backfill above
        -- seeded its `_defensiveIconMigrated = true` guard from PartyDefaults
        -- before it could ever run (true in v4 as well). The flag left the
        -- defaults with this removal, and the externalDef* keys plus the flag
        -- are stripped by the v5 legacy-aura cleanup below.


        -- (Removed) The v4.0.9 / v4.0.9b one-time FORCED filter stamps used to
        -- live here and below. Unlike every other migration they were not
        -- no-ops on fresh defaults: a profile reset wipes the migration flags
        -- along with everything else, so on the next reload both stamps
        -- re-fired and overwrote the freshly reset filters with 4.0.9-era
        -- values (All Debuffs off, Big/External Defensives on). Their one-time
        -- job is long done — upgraded profiles carry the flags, fresh/reset
        -- profiles get the current Config defaults. Migrations added here MUST
        -- be no-ops on a fresh default profile (derive from legacy values;
        -- never unconditional writes behind a profile-stored flag).

        -- Migrate the single border dropdown to the Style + Texture split.
        -- Previously borderTexture held either "SOLID" (the built-in border) or an
        -- LSM key. A non-SOLID key means the user had a texture selected, so flip
        -- borderStyle to TEXTURE. One-time so picking Solid later isn't reverted.
        local function migrateBorderStyle(modeDb)
            if modeDb and not modeDb._borderStyleMigrated then
                local tex = modeDb.borderTexture
                if tex and tex ~= "SOLID" and tex ~= "" then
                    modeDb.borderStyle = "TEXTURE"
                end
                modeDb._borderStyleMigrated = true
            end
        end
        for _, mode in ipairs({"party", "raid"}) do
            migrateBorderStyle(DF.db[mode])
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    migrateBorderStyle(profile[mode])
                end
            end
        end

        -- Recolour the Reduced Max Health bar off solid black.
        -- The old shipped default was opaque black {0,0,0,1}, which reads as empty
        -- space on a dark bar. Flip any profile still on one of our prior defaults
        -- — that black, OR the short-lived in-development grey #757575CB — to the
        -- new #808080CD (50% grey @ ~80% alpha). One-time per mode (flag) so a
        -- later deliberate colour choice isn't reverted; non-matching (customised)
        -- colours are left alone. (The #757575CB branch only matters to in-dev
        -- testers; no released build ever shipped that value.)
        local function recolorReducedMaxHealth(modeDb)
            if modeDb and not modeDb._reducedMaxHealthRecolorV2 then
                local c = modeDb.reducedMaxHealthColor
                local isOldBlack = c and c.r == 0 and c.g == 0 and c.b == 0 and c.a == 1
                local isDevGrey  = c and c.r == 0.4588 and c.g == 0.4588 and c.b == 0.4588 and c.a == 0.7961
                if isOldBlack or isDevGrey then
                    modeDb.reducedMaxHealthColor = { r = 0.502, g = 0.502, b = 0.502, a = 0.8039 }
                end
                modeDb._reducedMaxHealthRecolorV2 = true
            end
        end
        for _, mode in ipairs({"party", "raid"}) do
            recolorReducedMaxHealth(DF.db[mode])
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    recolorReducedMaxHealth(profile[mode])
                end
            end
        end

        -- The split test-mode toggles "Status / Ready" (testShowStatusIcons) and
        -- "Role / Leader" (testShowIcons) merged into one "Icons" toggle keyed on
        -- testShowStatusIcons (now default on). Flip existing profiles that were on
        -- the old default (status off) to on once, so role/leader icons don't vanish
        -- in test mode. One-time per mode (flag); a later deliberate off isn't reverted.
        local function mergeIconsToggle(modeDb)
            if modeDb and not modeDb._iconsToggleMergeV1 then
                if modeDb.testShowStatusIcons == false then
                    modeDb.testShowStatusIcons = true
                end
                modeDb._iconsToggleMergeV1 = true
            end
        end
        for _, mode in ipairs({"party", "raid"}) do
            mergeIconsToggle(DF.db[mode])
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    mergeIconsToggle(profile[mode])
                end
            end
        end

        -- Migrate the legacy `groupLabelShadow` (duplicate-fontstring shadow) into
        -- the new composite outline encoding from PR #115. If the user previously
        -- had the legacy shadow on, prepend "SHADOW;" to groupLabelOutline so they
        -- keep a shadow (now via SetShadowOffset on the primary fontstring).
        local function migrateGroupLabelShadow(modeDb)
            if modeDb and modeDb.groupLabelShadow ~= nil then
                if modeDb.groupLabelShadow == true then
                    local outline = modeDb.groupLabelOutline or ""
                    if not outline:find("^SHADOW") then
                        modeDb.groupLabelOutline = "SHADOW;" .. outline
                    end
                end
                modeDb.groupLabelShadow = nil
            end
        end
        for _, mode in ipairs({"party", "raid"}) do
            migrateGroupLabelShadow(DF.db[mode])
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    migrateGroupLabelShadow(profile[mode])
                end
            end
        end

        -- (Removed) v4.0.9b forced filter stamp — see the note at the v4.0.9
        -- stamp's former location above (re-fired after profile resets and
        -- clobbered fresh defaults).

        -- Migrate texture paths from old format to new Media folder format (v3.2.0)
        local function MigrateTexturePath(path)
            if type(path) ~= "string" then return path end
            -- Check if it's an old DandersFrames texture path without Media
            if path:find("AddOns\\DandersFrames\\DF_") or path:find("AddOns/DandersFrames/DF_") then
                -- Insert Media folder into the path
                path = path:gsub("DandersFrames\\DF_", "DandersFrames\\Media\\DF_")
                path = path:gsub("DandersFrames/DF_", "DandersFrames/Media/DF_")
            end
            return path
        end
        
        -- List of texture settings that need migration
        local textureSettings = {
            "healthBarTexture", "healthTexture", "backgroundTexture", 
            "absorbBarTexture", "healAbsorbBarTexture", "healPredictionTexture", 
            "powerBarTexture", "powerBarBackgroundTexture", "petTexture"
        }
        
        for _, mode in ipairs({"party", "raid"}) do
            local modeDb = DF.db[mode]
            if modeDb then
                for _, setting in ipairs(textureSettings) do
                    if modeDb[setting] then
                        modeDb[setting] = MigrateTexturePath(modeDb[setting])
                    end
                end
            end
        end
        
        -- Also migrate any profile that might have old paths
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for profileName, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    local modeDb = profile[mode]
                    if modeDb then
                        for _, setting in ipairs(textureSettings) do
                            if modeDb[setting] then
                                modeDb[setting] = MigrateTexturePath(modeDb[setting])
                            end
                        end
                    end
                end
            end
        end
        
        -- Note: Texture validation removed - SharedMedia textures are validated by LSM
        -- If a texture doesn't exist, WoW will display a fallback texture automatically
        
        -- Migrate BLIZZARD background color mode to CUSTOM with black color (v3.2.x)
        -- The "Black" option has been removed - we now just use CUSTOM with black as default
        local function MigrateBlizzardBackground(modeDb)
            if modeDb and modeDb.backgroundColorMode == "BLIZZARD" then
                modeDb.backgroundColorMode = "CUSTOM"
                modeDb.backgroundColor = {r = 0, g = 0, b = 0, a = 1}
            end
        end
        
        -- Migrate current profile
        MigrateBlizzardBackground(DF.db.party)
        MigrateBlizzardBackground(DF.db.raid)
        
        -- Migrate all profiles
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for profileName, profile in pairs(DandersFramesDB_v2.profiles) do
                MigrateBlizzardBackground(profile.party)
                MigrateBlizzardBackground(profile.raid)
            end
        end
        
        -- Migrate raidReverseGroupOrder (boolean) to raidGroupOrder (dropdown) (v3.2.x)
        local function MigrateGroupOrder(modeDb)
            if modeDb and modeDb.raidReverseGroupOrder ~= nil then
                modeDb.raidGroupOrder = modeDb.raidReverseGroupOrder and "REVERSE" or "NORMAL"
                modeDb.raidReverseGroupOrder = nil
            end
        end
        
        -- Migrate current profile
        MigrateGroupOrder(DF.db.raid)
        
        -- Migrate all profiles
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for profileName, profile in pairs(DandersFramesDB_v2.profiles) do
                MigrateGroupOrder(profile.raid)
            end
        end
        
        -- Migrate old groupLabelAnchor/groupLabelRelativeAnchor to new groupLabelPosition (v3.2.x)
        local function MigrateGroupLabelPosition(modeDb)
            if modeDb and (modeDb.groupLabelAnchor ~= nil or modeDb.groupLabelRelativeAnchor ~= nil) then
                -- Convert old anchor system to new position system
                -- Old system had separate label anchor and relative anchor
                -- New system uses START/CENTER/END based on layout direction
                -- Default to START for migration (most common use case was label above/left of group)
                if not modeDb.groupLabelPosition then
                    modeDb.groupLabelPosition = "START"
                end
                -- Clean up old settings
                modeDb.groupLabelAnchor = nil
                modeDb.groupLabelRelativeAnchor = nil
            end
        end
        
        -- Migrate current profile
        MigrateGroupLabelPosition(DF.db.raid)
        
        -- Migrate all profiles
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for profileName, profile in pairs(DandersFramesDB_v2.profiles) do
                MigrateGroupLabelPosition(profile.raid)
            end
        end
        
        -- Migrate sortAlphabetical from boolean to dropdown value (v3.3.x)
        -- Old format: true/false (boolean)
        -- New format: false (off), "AZ" (A→Z), "ZA" (Z→A)
        -- Users with old boolean true get reset to false since we can't know their preference
        local function MigrateSortAlphabetical(modeDb)
            if modeDb and type(modeDb.sortAlphabetical) == "boolean" then
                modeDb.sortAlphabetical = false
            end
        end
        
        -- Migrate current profile
        MigrateSortAlphabetical(DF.db.party)
        MigrateSortAlphabetical(DF.db.raid)
        
        -- Migrate all profiles
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for profileName, profile in pairs(DandersFramesDB_v2.profiles) do
                MigrateSortAlphabetical(profile.party)
                MigrateSortAlphabetical(profile.raid)
            end
        end
        
        -- Migrate resourceBarHealerOnly to per-role settings (v4.1.x)
        -- Old format: resourceBarHealerOnly = true/false
        -- New format: resourceBarShowHealer, resourceBarShowTank, resourceBarShowDPS
        local function MigrateResourceBarRoleFilter(modeDb)
            if modeDb and modeDb.resourceBarHealerOnly ~= nil then
                if modeDb.resourceBarHealerOnly then
                    modeDb.resourceBarShowHealer = true
                    modeDb.resourceBarShowTank = false
                    modeDb.resourceBarShowDPS = false
                else
                    modeDb.resourceBarShowHealer = true
                    modeDb.resourceBarShowTank = true
                    modeDb.resourceBarShowDPS = true
                end
                modeDb.resourceBarHealerOnly = nil
            end
        end

        -- Migrate current profile
        MigrateResourceBarRoleFilter(DF.db.party)
        MigrateResourceBarRoleFilter(DF.db.raid)

        -- Migrate all profiles
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for profileName, profile in pairs(DandersFramesDB_v2.profiles) do
                MigrateResourceBarRoleFilter(profile.party)
                MigrateResourceBarRoleFilter(profile.raid)
            end
        end

        -- Migrate Aura Designer from type-keyed to instance-based format (v4.1.x)
        -- Old format: auraCfg.icon = { anchor = ..., size = ... }
        -- New format: auraCfg.indicators = { { id = 1, type = "icon", anchor = ..., size = ... } }
        local AD_PLACED_TYPE_KEYS = { "icon", "square", "bar" }

        -- Inner migration: converts a flat auras table from type-keyed to instance-based
        local function MigrateAuraConfigs(aurasTable)
            for auraName, auraCfg in pairs(aurasTable) do
                if type(auraCfg) == "table" and not auraCfg.indicators then
                    -- Only migrate if it has old-style placed type keys
                    local hasOldKeys = false
                    for _, typeKey in ipairs(AD_PLACED_TYPE_KEYS) do
                        if auraCfg[typeKey] then hasOldKeys = true; break end
                    end
                    if hasOldKeys then
                        local indicators = {}
                        local nextID = 1
                        for _, typeKey in ipairs(AD_PLACED_TYPE_KEYS) do
                            if auraCfg[typeKey] then
                                local instance = DF:DeepCopy(auraCfg[typeKey])
                                instance.id = nextID
                                instance.type = typeKey
                                indicators[#indicators + 1] = instance
                                nextID = nextID + 1
                                auraCfg[typeKey] = nil
                            end
                        end
                        if #indicators > 0 then
                            auraCfg.indicators = indicators
                        end
                        auraCfg.nextIndicatorID = nextID
                    end
                end
            end
        end

        local function MigrateAuraDesignerToInstances(modeDb)
            local adDB = modeDb and modeDb.auraDesigner
            if not adDB or not adDB.auras then return end

            -- Detect format: check first entry to see if it's flat aura configs or spec-scoped
            for key, val in pairs(adDB.auras) do
                if type(val) == "table" then
                    if val.priority ~= nil or val.indicators ~= nil or val.border ~= nil then
                        -- Flat format (pre-spec-scoping): migrate directly
                        MigrateAuraConfigs(adDB.auras)
                    else
                        -- Spec-scoped format: iterate each spec's auras
                        for specKey, specAuras in pairs(adDB.auras) do
                            if type(specAuras) == "table" then
                                MigrateAuraConfigs(specAuras)
                            end
                        end
                    end
                end
                break  -- Only check first entry
            end
        end

        -- Expose for use after profile imports
        DF.MigrateAuraDesignerToInstances = MigrateAuraDesignerToInstances

        -- Migrate current profile
        MigrateAuraDesignerToInstances(DF.db.party)
        MigrateAuraDesignerToInstances(DF.db.raid)

        -- Migrate all profiles
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for profileName, profile in pairs(DandersFramesDB_v2.profiles) do
                MigrateAuraDesignerToInstances(profile.party)
                MigrateAuraDesignerToInstances(profile.raid)
            end
        end

        -- Stage 5.1b: rename per-aura icon border keys to canonical
        -- ShowBorder / BorderSize / BorderInset.  Idempotent; safe to
        -- run on already-migrated configs.  Defined in
        -- AuraDesigner/Options.lua; load order guarantees that file
        -- has registered DF.MigrateAuraDesignerIconBorderKeys by here.
        if DF.MigrateAuraDesignerIconBorderKeys then
            DF.MigrateAuraDesignerIconBorderKeys(DF.db.party)
            DF.MigrateAuraDesignerIconBorderKeys(DF.db.raid)
            -- Designer Presets relocated AD configs onto the profile root; walk
            -- those too (the mode-DB calls above miss preset-nested border blocks,
            -- which left imported legacy borders rendering via the old `style` path).
            if DF.MigrateAuraDesignerPresetBorderKeys then
                DF.MigrateAuraDesignerPresetBorderKeys(DF.db)
            end
            if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
                for _, profile in pairs(DandersFramesDB_v2.profiles) do
                    DF.MigrateAuraDesignerIconBorderKeys(profile.party)
                    DF.MigrateAuraDesignerIconBorderKeys(profile.raid)
                    if DF.MigrateAuraDesignerPresetBorderKeys then
                        DF.MigrateAuraDesignerPresetBorderKeys(profile)
                    end
                end
            end
        end

        -- Reset seenTabs so "New" badges show for 4.3.0 features (one-time)
        if DandersFramesDB_v2 and not DandersFramesDB_v2._seenTabsReset_430 then
            DandersFramesDB_v2.seenTabs = nil
            DandersFramesDB_v2._seenTabsReset_430 = true
        end

        -- Migrate dispellable filter from two booleans to single mode string (v4.3.x)
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for profileName, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    local modeDb = profile[mode]
                    if modeDb and modeDb.directDebuffDispellableMode == nil then
                        if modeDb.directDebuffFilterAllDispellable == true then
                            modeDb.directDebuffDispellableMode = "ALL"
                        else
                            modeDb.directDebuffDispellableMode = "PLAYER"
                        end
                        modeDb.directDebuffFilterRaidPlayerDispellable = nil
                        modeDb.directDebuffFilterAllDispellable = nil
                    end
                end
            end
        end

        -- Recover from crash/disconnect during auto layout editing.
        -- If the recovery flag exists, the previous session was editing an auto layout
        -- when it crashed — _realRaidDB may still contain override values baked in.
        -- Compare each key against the profile's overrides and reset contaminated ones.
        if DF.db.raidAutoEditingRecovery then
            local recovery = DF.db.raidAutoEditingRecovery
            local autoDb = DF.db.raidAutoProfiles
            local profile
            if recovery.contentType == "mythic" then
                profile = autoDb and autoDb.mythic and autoDb.mythic.profile
            else
                local ct = autoDb and autoDb[recovery.contentType]
                profile = ct and ct.profiles and ct.profiles[recovery.profileIndex]
            end
            if profile and profile.overrides and recovery.snapshotKeys then
                local recovered = 0
                for _, key in ipairs(recovery.snapshotKeys) do
                    local overrideVal = profile.overrides[key]
                    if overrideVal ~= nil and DeepEquals(DF.db.raid[key], overrideVal) then
                        -- This value matches the override — reset to default
                        local default = DF.RaidDefaults[key]
                        if default ~= nil then
                            if type(default) == "table" then
                                DF.db.raid[key] = DF:DeepCopy(default)
                            else
                                DF.db.raid[key] = default
                            end
                            recovered = recovered + 1
                        end
                    end
                end
                if recovered > 0 then
                    DF:Say(format(L["Recovered %d raid settings from interrupted auto layout editing session."], recovered))
                end
            end
            DF.db.raidAutoEditingRecovery = nil
        end

        -- (Removed) The HARF-era cleanup that deleted AD entries for
        -- then-untrackable externals (Pain Suppression, Life Cocoon, ...). Its
        -- premise is obsolete on 12.1 — those spells are live AD registry
        -- entries again (identity-gated spell-ID tracking) — and the one case
        -- where it still fired (an ancient pre-preset inline import) would
        -- have deleted spells v5 CAN track, before conversion. Modern preset
        -- data was never touched (it only walked the legacy inline store).

        -- One-time: force hideBlizzardRaidFrames = true for existing users
        for _, mode in ipairs({"party", "raid"}) do
            local modeDb = DF.db[mode]
            if modeDb and not modeDb._hideBlizzRaidV407 then
                modeDb.hideBlizzardRaidFrames = true
                modeDb._hideBlizzRaidV407 = true
            end
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    if profile[mode] and not profile[mode]._hideBlizzRaidV407 then
                        profile[mode].hideBlizzardRaidFrames = true
                        profile[mode]._hideBlizzRaidV407 = true
                    end
                end
            end
        end

        -- v4.3.4: Dispel Overlay Source migration
        -- Collapses the two legacy toggles (dispelOverlayEnabled +
        -- bossDebuffsContainerOverlayEnabled) into a single dispelOverlaySource
        -- selector with values "off" / "dandersframes" / "blizzard" / "both".
        -- Also unifies the dispel-type dropdown — _blizzDispelIndicator (party-only,
        -- 1=All, 2=ByMe) and bossDebuffsContainerOverlayDispelMode (per-mode,
        -- 1=ByMe, 2=All) are replaced by dispelOverlayDispelType (per-mode,
        -- Blizzard convention: 1=ByMe, 2=All).
        local function ComputeDispelSource(modeDb)
            -- Fresh installs have no legacy keys (removed from defaults in
            -- v4.3.4). If both are nil there's no legacy state to migrate —
            -- return nil so the default ("both") is preserved.
            if modeDb.dispelOverlayEnabled == nil and modeDb.bossDebuffsContainerOverlayEnabled == nil then
                return nil
            end
            local dfOn = modeDb.dispelOverlayEnabled and true or false
            local blizOn = modeDb.bossDebuffsContainerOverlayEnabled and true or false
            if dfOn and blizOn then return "both"
            elseif dfOn then return "dandersframes"
            elseif blizOn then return "blizzard"
            else return "off" end
        end
        local function MigrateDispelSource(modeDb, partyDb)
            if modeDb._dispelSourceMigratedV434 then return end
            local src = ComputeDispelSource(modeDb)
            if src then modeDb.dispelOverlaySource = src end
            -- Translate legacy _blizzDispelIndicator (1=All, 2=ByMe) to the new
            -- Blizzard convention (1=ByMe, 2=All). Reads from party DB since the
            -- legacy key was party-only. If unset, leave the default untouched.
            local legacyInd = partyDb and partyDb._blizzDispelIndicator
            if legacyInd ~= nil then
                modeDb.dispelOverlayDispelType = (legacyInd == 2) and 1 or 2
            end
            modeDb._dispelSourceMigratedV434 = true
        end
        for _, mode in ipairs({"party", "raid"}) do
            local modeDb = DF.db[mode]
            if modeDb then
                MigrateDispelSource(modeDb, DF.db.party)
            end
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                local partyDb = profile.party
                for _, mode in ipairs({"party", "raid"}) do
                    if profile[mode] then
                        MigrateDispelSource(profile[mode], partyDb)
                    end
                end
            end
        end

        -- AFK text colour: the AFK text was previously hardcoded orange and
        -- afkIconTextColor (its colour picker) was ignored. The picker is now
        -- live; convert profiles still on the old peachy default to the orange
        -- the text actually showed, so there's no visible change.
        local function MigrateAFKTextColor(modeDb)
            local c = modeDb and modeDb.afkIconTextColor
            if type(c) == "table"
               and math.abs((c.g or 0) - 0.7725490927696228) < 0.0001
               and math.abs((c.b or 0) - 0.5411764979362488) < 0.0001 then
                modeDb.afkIconTextColor = { r = 1, g = 0.5, b = 0, a = 1 }
            end
        end
        for _, mode in ipairs({"party", "raid"}) do
            MigrateAFKTextColor(DF.db[mode])
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    MigrateAFKTextColor(profile[mode])
                end
            end
        end

        -- AFK timer font: an earlier build force-stamped the monospace timer font
        -- onto every profile to stop the countdown wobble. The wobble is actually
        -- fixed by LEFT-justifying the timer (see ApplyTimerTextSettings) — the
        -- mono font is no longer needed or defaulted. Clear that stamp ONCE so the
        -- timer goes back to inheriting the global font; guard with a flag so a
        -- deliberate mono choice made later is not wiped on the next reload.
        if DandersFramesDB_v2 and not DandersFramesDB_v2.afkTimerMonoUnstamped then
            local function UnstampAFKTimerFont(modeDb)
                if modeDb and modeDb.afkIconTimerFont == "DF Roboto Mono SemiBold" then
                    modeDb.afkIconTimerFont = nil
                end
            end
            for _, mode in ipairs({"party", "raid"}) do
                UnstampAFKTimerFont(DF.db[mode])
            end
            if DandersFramesDB_v2.profiles then
                for _, profile in pairs(DandersFramesDB_v2.profiles) do
                    for _, mode in ipairs({"party", "raid"}) do
                        UnstampAFKTimerFont(profile[mode])
                    end
                end
            end
            DandersFramesDB_v2.afkTimerMonoUnstamped = true
        end

        -- v4.3.4: One-time forced upgrade of "dandersframes" mode users to
        -- "both" (Hybrid). Hybrid covers boss debuffs via Blizzard's
        -- container overlay, which DandersFrames-only mode misses entirely.
        -- Runs once per profile/mode; users can switch back afterwards.
        local function MigrateDandersToHybrid(modeDb)
            if modeDb._dandersToHybridV434 then return end
            if modeDb.dispelOverlaySource == "dandersframes" then
                modeDb.dispelOverlaySource = "both"
            end
            modeDb._dandersToHybridV434 = true
        end
        for _, mode in ipairs({"party", "raid"}) do
            local modeDb = DF.db[mode]
            if modeDb then
                MigrateDandersToHybrid(modeDb)
            end
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    if profile[mode] then
                        MigrateDandersToHybrid(profile[mode])
                    end
                end
            end
        end

        -- v5.0 (12.1): Unified dispel overlay — the Blizzard container-overlay
        -- wrapper is retired (the container slot path covers private auras
        -- natively), so the v4.3.4 source selector collapses back to a single
        -- enable bool. NOTE: dispelOverlayEnabled deliberately REUSES the
        -- pre-v4.3.4 key name — MigrateDispelSource above consumed the legacy
        -- value into dispelOverlaySource, and this write derives from that
        -- source, so any stale legacy value is overwritten, never read. Also
        -- drops the wrapper-only settings and the never-consumed dispelShow*
        -- family (Config/export-only since inception — 2026-07 audit).
        local function MigrateDispelSourceToEnabled(modeDb)
            if modeDb._dispelEnabledV5 then return end
            modeDb.dispelOverlayEnabled = (modeDb.dispelOverlaySource or "both") ~= "off"
            modeDb.dispelOverlaySource = nil
            -- Wrapper-only settings (feature deleted).
            modeDb.bossDebuffsContainerOverlayEnabled = nil
            modeDb.bossDebuffsContainerOverlayGradientDir = nil
            modeDb.bossDebuffsContainerOverlayAlpha = nil
            modeDb.bossDebuffsContainerOverlayFrameLevel = nil
            modeDb.bossDebuffsContainerOverlayStrata = nil
            modeDb.bossDebuffsContainerOverlaySizeAdjust = nil
            modeDb.bossDebuffsContainerOverlayPulse = nil
            modeDb.bossDebuffsContainerOverlayDispelMode = nil
            -- Dead keys (never consumed by any render path).
            modeDb.dispelOverlayMode = nil
            modeDb.dispelOnlyPlayerTypes = nil
            modeDb.dispelShowMagic = nil
            modeDb.dispelShowCurse = nil
            modeDb.dispelShowDisease = nil
            modeDb.dispelShowPoison = nil
            modeDb.dispelShowBleed = nil
            modeDb.dispelShowEnrage = nil
            modeDb._dispelEnabledV5 = true
        end
        for _, mode in ipairs({"party", "raid"}) do
            local modeDb = DF.db[mode]
            if modeDb then
                MigrateDispelSourceToEnabled(modeDb)
            end
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    if profile[mode] then
                        MigrateDispelSourceToEnabled(profile[mode])
                    end
                end
            end
        end

        -- v5 legacy-aura cleanup: strip saved values for retired features/toggles.
        -- My Buff Indicators (deprecated + force-disabled since 4.0.12, deleted in
        -- 5.0.0) and the hidden *UseFactory dev toggles (factory is unconditional).
        local LEGACY_AURA_KEYS = {
            "myBuffIndicatorAnimate", "myBuffIndicatorBorderAlpha",
            "myBuffIndicatorBorderInset", "myBuffIndicatorBorderSize",
            "myBuffIndicatorColor", "myBuffIndicatorEnabled",
            "myBuffIndicatorGradientAlpha", "myBuffIndicatorGradientOnCurrentHealth",
            "myBuffIndicatorGradientSize", "myBuffIndicatorGradientStyle",
            "myBuffIndicatorShowBorder", "myBuffIndicatorShowGradient",
            "oorMyBuffIndicatorAlpha", "testShowMyBuffIndicator",
            "buffUseFactory", "debuffUseFactory", "defensiveUseFactory",
            "missingBuffUseFactory", "dispelOverlayUseFactory", "adUseFactory",
            -- Boss Debuffs (separate display retired in 5.0.0 -- the game feeds
            -- boss/private auras through the regular debuff row on 12.1).
            "bossDebuffHighlight", "bossDebuffScale", "bossDebuffsAnchor",
            "bossDebuffsBorderScale", "bossDebuffsEnabled", "bossDebuffsFrameLevel",
            "bossDebuffsStrata", "bossDebuffsGrowth", "bossDebuffsHideTooltip",
            "bossDebuffsIconSize", "bossDebuffsIconWidth", "bossDebuffsIconHeight",
            "bossDebuffsMax", "bossDebuffsOffsetX", "bossDebuffsOffsetY",
            "bossDebuffsShowCountdown", "bossDebuffsShowNumbers",
            "bossDebuffsSpacing", "bossDebuffsTextScale", "testShowBossDebuffs",
            "bossDebuffsLegacyAnchors", "testBossDebuffCount", "_paIconSizeMigrated", "_paStrataHighV434",
            -- Blizzard-frame dispel-indicator CVar stamp (party-only key; its
            -- v4.3.4 fold into dispelOverlayDispelType runs before this strip).
            "_blizzDispelIndicator",
            -- Masque integration control (removed in 5.0 — Masque can't skin the
            -- 12.1 container aura buttons; the saved toggle drives nothing now).
            "masqueBorderControl",
            -- Old external-defensive icon (its widget died with the legacy pools;
            -- the settings migrated into defensiveIcon* long ago).
            "externalDefAnchor", "externalDefBorderColor", "externalDefBorderSize",
            "externalDefEnabled", "externalDefFrameLevel", "externalDefScale",
            "externalDefShowDuration", "externalDefStrata", "externalDefX",
            "externalDefY", "_defensiveIconMigrated",
        }
        local function StripLegacyAuraKeys(modeDb)
            for _, key in ipairs(LEGACY_AURA_KEYS) do
                modeDb[key] = nil
            end
        end
        for _, mode in ipairs({"party", "raid"}) do
            if DF.db[mode] then StripLegacyAuraKeys(DF.db[mode]) end
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    if profile[mode] then StripLegacyAuraKeys(profile[mode]) end
                end
            end
        end
        -- The *UseFactory dev toggles lived at the profile ROOT (DF.db.adUseFactory,
        -- not per-mode), so strip them there too. Harmless orphans otherwise.
        local ROOT_LEGACY_KEYS = { "buffUseFactory", "debuffUseFactory",
            "defensiveUseFactory", "missingBuffUseFactory", "dispelOverlayUseFactory",
            "adUseFactory" }
        local function StripRootLegacyKeys(root)
            if not root then return end
            for _, key in ipairs(ROOT_LEGACY_KEYS) do root[key] = nil end
        end
        StripRootLegacyKeys(DF.db)
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                StripRootLegacyKeys(profile)
            end
        end

        -- v5.0 (12.1): remap any retired border-animation-type value to a live one.
        --   * The LibCustomGlow-backed glows (Pulsate / Chase / Flash / Proc) were
        --     replaced by DF-owned equivalents (the library was removed), so map
        --     each to its DF counterpart to keep an existing selection animating.
        --   * Comet, Sides Only, Wipe, Ripple and Segment Reveal were removed
        --     outright, so map them to NONE. (Corners Only is kept in the engine —
        --     just hidden from the picker — so it is deliberately NOT remapped.)
        -- Recursive so it catches mode tables, pinned sets, AD indicators and the
        -- expiring-border keys alike. Idempotent (a live value is left untouched).
        local RETIRED_ANIM_REMAP = { PULSATE = "DF_PIXEL", CHASE = "DF_ORBIT",
                                     FLASH = "DF_FLASH", PROC = "DF_PROC",
                                     COMET = "NONE", SIDES_ONLY = "NONE",
                                     WIPE = "NONE", RIPPLE = "NONE",
                                     SEGMENT_REVEAL = "NONE" }
        local function remapRetiredAnims(t, seen)
            if type(t) ~= "table" or seen[t] then return end
            seen[t] = true
            for k, v in pairs(t) do
                if type(v) == "string" then
                    if type(k) == "string" and k:sub(-13) == "AnimationType" and RETIRED_ANIM_REMAP[v] then
                        t[k] = RETIRED_ANIM_REMAP[v]
                    end
                elseif type(v) == "table" then
                    remapRetiredAnims(v, seen)
                end
            end
        end
        remapRetiredAnims(DF.db, {})
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                remapRetiredAnims(profile, {})
            end
        end

        -- v5.0 (12.1): the dispel overlay's Custom Colors mode was removed during
        -- the alpha (never in any distributed build — belt-and-braces for alpha
        -- profiles only): drop the mode selector, the per-type pickers and the
        -- intensity multiplier. No-op on fresh defaults (none of these keys exist
        -- there any more).
        local function DropDispelCustomMode(modeDb)
            if modeDb._dispelCustomRemovedV5 then return end
            modeDb.dispelOverlayColorSource = nil
            modeDb.dispelGradientIntensity = nil
            modeDb.dispelMagicColor = nil
            modeDb.dispelCurseColor = nil
            modeDb.dispelDiseaseColor = nil
            modeDb.dispelPoisonColor = nil
            modeDb.dispelBleedColor = nil
            modeDb._dispelCustomRemovedV5 = true
        end
        for _, mode in ipairs({"party", "raid"}) do
            local modeDb = DF.db[mode]
            if modeDb then
                DropDispelCustomMode(modeDb)
            end
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    if profile[mode] then
                        DropDispelCustomMode(profile[mode])
                    end
                end
            end
        end

        -- Expose the v5 legacy passes for the profile-import path (mirrors the
        -- MigrateAuraDesignerToInstances export above). Without this, a v4
        -- export imported at runtime shows a wrong dispel-enable state and
        -- retired animation values until the next reload (all four passes only
        -- re-ran at ADDON_LOADED). Walks the RAW profile tables only — DF.db
        -- is proxied by the time an import runs, and the current profile is in
        -- DandersFramesDB_v2.profiles anyway. Each pass is flag-gated or
        -- value-idempotent, so re-running over untouched profiles is a no-op;
        -- v5 exports carry the guard flags and skip straight through.
        function DF:RunV5LegacyMigrations()
            if not (DandersFramesDB_v2 and DandersFramesDB_v2.profiles) then return end
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                if type(profile) == "table" then
                    for _, mode in ipairs({"party", "raid"}) do
                        local m = profile[mode]
                        if type(m) == "table" then
                            MigrateDispelSourceToEnabled(m)
                            StripLegacyAuraKeys(m)
                            DropDispelCustomMode(m)
                        end
                    end
                    StripRootLegacyKeys(profile)
                    remapRetiredAnims(profile, {})
                end
            end
        end

        -- Migrate personal targeted spells container centre to icon-block midpoint (bug 880).
        -- Previously the saved (x, y) was the position of icon 1 (container centre).
        -- Now (x, y) is the visual centre of the icon block; the container is offset so
        -- the block is centred there.  Shift existing positions by halfBlock in the growth
        -- direction so icon 1 stays at its old screen location for existing users.
        local function MigratePersonalContainerPosition(partyDb)
            if not partyDb or partyDb._personalContainerCenterMigrated then return end
            local iconSize = partyDb.personalTargetedSpellSize or 40
            local scale = partyDb.personalTargetedSpellScale or 1.0
            local maxIcons = partyDb.personalTargetedSpellMaxIcons or 5
            local spacing = partyDb.personalTargetedSpellSpacing or 4
            local growthDirection = partyDb.personalTargetedSpellGrowth or "RIGHT"
            local x = partyDb.personalTargetedSpellX or 0
            local y = partyDb.personalTargetedSpellY or -150

            local scaledSize = iconSize * scale
            local scaledSpacing = spacing * scale
            local halfBlock = (maxIcons - 1) / 2 * (scaledSize + scaledSpacing)

            if growthDirection == "RIGHT" then
                partyDb.personalTargetedSpellX = x + halfBlock
            elseif growthDirection == "LEFT" then
                partyDb.personalTargetedSpellX = x - halfBlock
            elseif growthDirection == "UP" then
                partyDb.personalTargetedSpellY = y + halfBlock
            elseif growthDirection == "DOWN" then
                partyDb.personalTargetedSpellY = y - halfBlock
            -- CENTER_H / CENTER_V: no shift needed
            end
            partyDb._personalContainerCenterMigrated = true
        end
        MigratePersonalContainerPosition(DF.db.party)
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                MigratePersonalContainerPosition(profile.party)
            end
        end

        -- Wrap DF.db with overlay proxy (must happen AFTER all migrations,
        -- BEFORE anything that reads through the proxy)
        DF:WrapDB()

        -- Initialize Debug Console (must happen after SavedVariables are ready)
        if DF.DebugConsole then
            DF.DebugConsole:Init()
        end

        print("|cff00ff00DandersFrames|r " .. format(L["v%s loaded. Type %s/df%s for settings, %s/df resetgui%s if window is offscreen."], (DF.VERSION:gsub("^[vV]", "")), "|cffeda55f", "|r", "|cffeda55f", "|r"))

        -- ============================================================
        -- CRITICAL: Initialize frames HERE at ADDON_LOADED
        -- ============================================================
        -- This is essential for combat reload support. At ADDON_LOADED:
        -- 1. Saved variables ARE available
        -- 2. InCombatLockdown() returns FALSE even during a combat /reload
        -- This special window lets us create all frames before the game
        -- starts blocking protected operations.
        -- ============================================================
        if DF.InitializeFrames then
            DF:InitializeFrames()
        end

    elseif event == "PLAYER_LOGIN" then
        -- Check for NephUI
        -- NOTE: NephUI previously contained stolen DandersFrames code. A compatibility
        -- popup was added to warn users. The copyright-infringing code has since been
        -- removed from NephUI, so the popup is disabled and compatibility is restored.
        -- Keeping this code in case it's needed again in the future.
        local nephUIPopupEnabled = false
        local nephUILoaded = false
        if C_AddOns and C_AddOns.IsAddOnLoaded then
            nephUILoaded = C_AddOns.IsAddOnLoaded("NephUI")
        elseif IsAddOnLoaded then
            nephUILoaded = IsAddOnLoaded("NephUI")
        end
        
        if nephUILoaded and nephUIPopupEnabled then
            -- Theme color for popup
            local themeColor = { r = 0.2, g = 0.8, b = 0.2 }
            
            -- Helper function to create styled buttons (routed through GUI:StyleButton)
            local function CreatePopupButton(parent, text, yOffset, isPrimary)
                local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
                if isPrimary then
                    DF.GUI:StyleButton(btn, { width = 220, height = 32, text = text, primary = true })
                else
                    DF.GUI:StyleButton(btn, { width = 220, height = 32, text = text })
                end
                btn:SetPoint("TOP", parent.warning, "BOTTOM", 0, yOffset)
                btn.label = btn.Text

                return btn
            end
            
            -- Create the popup frame
            local popup = CreateFrame("Frame", "DFNephUIPopup", UIParent, "BackdropTemplate")
            popup:SetSize(420, 240)
            popup:SetPoint("CENTER")
            DF.GUI:CreateElementBackdrop(popup, {
                edgeSize    = 2,
                bgColor     = { 0.1, 0.1, 0.1, 0.98 },
                borderColor = { themeColor.r, themeColor.g, themeColor.b, 1 },
            })
            popup:SetFrameStrata("FULLSCREEN_DIALOG")
            popup:SetFrameLevel(200)
            popup:EnableMouse(true)
            popup:SetMovable(true)
            popup:RegisterForDrag("LeftButton")
            popup:SetScript("OnDragStart", popup.StartMoving)
            popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
            
            -- Title
            local title = popup:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
            title:SetPoint("TOP", 0, -15)
            title:SetText("Addon Conflict Detected")
            title:SetTextColor(1, 0.3, 0.3)
            popup.title = title
            
            -- Warning icons on either side of title
            local leftWarning = popup:CreateTexture(nil, "OVERLAY")
            leftWarning:SetSize(20, 20)
            leftWarning:SetPoint("RIGHT", title, "LEFT", -8, 0)
            leftWarning:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\warning")
            leftWarning:SetVertexColor(1, 0.3, 0.3)
            popup.leftWarning = leftWarning
            
            local rightWarning = popup:CreateTexture(nil, "OVERLAY")
            rightWarning:SetSize(20, 20)
            rightWarning:SetPoint("LEFT", title, "RIGHT", 8, 0)
            rightWarning:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\warning")
            rightWarning:SetVertexColor(1, 0.3, 0.3)
            popup.rightWarning = rightWarning
            
            -- Message
            local msg = popup:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
            msg:SetPoint("TOP", title, "BOTTOM", 0, -15)
            msg:SetPoint("LEFT", 25, 0)
            msg:SetPoint("RIGHT", -25, 0)
            msg:SetJustifyH("CENTER")
            msg:SetText("Both |cff00ff00DandersFrames|r and |cffff6666NephUI|r are loaded.\n\nWhich addon would you like to use?")
            msg:SetTextColor(1, 1, 1)
            popup.msg = msg
            
            -- Warning text
            local warning = popup:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            warning:SetPoint("TOP", msg, "BOTTOM", 0, -10)
            warning:SetPoint("LEFT", 25, 0)
            warning:SetPoint("RIGHT", -25, 0)
            warning:SetJustifyH("CENTER")
            warning:SetText("Selecting an option will disable the other addon\nand reload your UI.")
            warning:SetTextColor(0.7, 0.7, 0.7)
            popup.warning = warning
            
            -- DandersFrames button (primary)
            local dfBtn = CreatePopupButton(popup, "Use DandersFrames", -20, true)
            dfBtn:SetScript("OnClick", function()
                if C_AddOns and C_AddOns.DisableAddOn then
                    C_AddOns.DisableAddOn("NephUI")
                elseif DisableAddOn then
                    DisableAddOn("NephUI")
                end
                ReloadUI()
            end)
            popup.dfBtn = dfBtn
            
            -- NephUI button (secondary - triggers wrong choice)
            local nephBtn = CreatePopupButton(popup, "Use NephUI", -57, false)
            nephBtn:SetScript("OnClick", function()
                -- Switch to "wrong choice" state
                title:SetText("That's the wrong choice!")
                title:SetTextColor(1, 0.4, 0.2)
                
                -- Hide warning icons for this screen
                leftWarning:Hide()
                rightWarning:Hide()
                
                msg:SetText("|cffff6666NephUI|r has stolen and copied |cff00ff00DandersFrames|r.\n\nThere is only one correct option here.")
                
                warning:SetText("")
                
                -- Hide the NephUI button
                nephBtn:Hide()
                
                -- Update DandersFrames button
                dfBtn.label:SetText("Use DandersFrames (The Original)")
                dfBtn:SetSize(260, 32)
                dfBtn:ClearAllPoints()
                dfBtn:SetPoint("TOP", msg, "BOTTOM", 0, -25)
            end)
            popup.nephBtn = nephBtn
            
            -- Store reference
            DF.nephUIPopup = popup
            
            -- Don't initialize DandersFrames if NephUI is loaded
            return
        end
        
        -- Enable raid buff filtering now that we're past ADDON_LOADED
        -- (avoids "secret value" errors during combat reload initialization)
        DF.raidBuffFilteringReady = true
        
        -- ============================================================
        -- /df SUBCOMMAND REGISTRATIONS
        -- ============================================================
        -- Drives the "/df diagnostics" section of /df debug. Register every
        -- branch added to the dispatcher below — an unregistered branch works
        -- but is invisible, which is exactly how ~45 of these went unlisted.
        -- Pure aliases are folded into the primary's description rather than
        -- listed twice.
        local sub = function(...) DF:RegisterDebugSub(...) end
        -- Support / general
        -- These six plus resetgui/test/hide/lock below are EVERYDAY commands and are
        -- already listed by /df help, so they carry hidden = true to stay out of the
        -- /df debug listing. Same duplication that got pixelcheck/navprobe/gapcheck
        -- pulled from help, resolved the other way round: each command is documented
        -- in exactly one list, the one its audience reads. They still answer, and
        -- they still need sub() entries so the drift check can see them.
        sub("help",         "command list", nil, nil, true)
        sub("console",      "open the debug console page", nil, nil, true)
        sub("users",        "group members running DandersFrames", nil, nil, true)
        sub("reset",        "reset the whole profile", nil, nil, true)
        -- Frame state
        -- headers and dispel are registered in BOTH registries — RegisterDebugSlash
        -- (which supplies the /dfXXX alias) and here (which supplies the argument
        -- hint). The old three-section listing printed each one twice and it read as
        -- deliberate because the copies sat in different sections; grouping by
        -- subsystem put them side by side and the duplication was obvious. Hidden
        -- here, with the argument hint folded into the slash description, so the
        -- entry survives for the drift check but appears once.
        sub("headers",      "secure header state dump, or a /dfheaders subcommand", nil, "[cmd]", true)
        sub("attached",     "foreign frames anchored to ours")
        sub("zorder",       "frame level / strata map")
        sub("mousefoci",    "identify the frame under the cursor after 2s")
        -- Auras (12.1 container era)
        sub("auradata",     "live aura data enumeration (add a unit token)", nil, "[unit]")
        sub("dispel",       "dispel overlay state: a unit token, or ids | render", nil, "[unit|cmd]", true)
        sub("idgate",       "container identity-gate dump", true)
        sub("ppdump",       "missing-buff layout-push dump", true)
        -- Not logging, despite the old wording: it window-parks the badge so the
        -- anchor stays live and the badge shows even when the buff is present.
        sub("ppbadge",      "force the missing-buff badge to stay visible (geometry probe)", true)
        sub("admissing",    "Aura Designer missing-buff trace (add 'mark')", true, "[mark]")
        sub("cbt",          "colour-by-time curve dump", true, "<spellID>")
        -- Data integrity. Both dev-gated for the same reason as /df debug duration: they
        -- check OUR curation data against the client, so the output only means
        -- something to whoever maintains that data.
        sub("auditspells",  "spell database curation drift check", true)
        sub("exportaudit",  "export category drift check", true)
        sub("overrides",    "active auto-layout overrides")
        sub("localewarn",   "toggle missing-locale-key warnings", true)
        -- GUI probes (stay useful as new surfaces are added)
        sub("pixelcheck",   "report GUI elements off the device pixel grid", true)
        sub("gapcheck",     "GUI spacing probe (add 'all' or 'clear')", true, "[all|clear]")
        sub("navprobe",     "nav menu row probe", true, "[n]")
        sub("guiwidth",     "GUI width dump", true)
        sub("tdmirror",     "Text Designer mirror state", true)
        -- Performance
        sub("profiler",     "open the profiler UI")
        sub("profile",      "quick profile for N seconds", nil, "<sec>")
        -- Feature state dumps (one-shot, pasteable)
        sub("debugfonts",   "font / SharedMedia availability dump")
        sub("debugrested",  "rested indicator state")
        -- Both moved under /df debug cc (see CC_SUBCOMMANDS). Hidden here rather than
        -- deleted: they still answer, and the drift check needs to see them.
        sub("clickcast",    "moved to /df debug cc registration", nil, nil, true)
        sub("casthistory",  "cast history")
        sub("clearhistory", "clear the cast history buffer")
        -- Ongoing traces still on their own flag (console migration pending)
        -- HIDDEN: both are console-migration signposts now. They toggle nothing, so
        -- listing them as "toggle X logging" offered a no-op; they still answer for
        -- anyone typing the old command.
        -- Config repair
        sub("resetgui",     "reset GUI scale, size and position", nil, nil, true)
        sub("resetconflict", "moved to /df debug cc resetconflict", nil, nil, true)
        -- Test / preview
        sub("test",         "toggle the test frame panel", nil, nil, true)
        sub("testids",      "audit test-pool spell IDs against this client", true)
        sub("hide",         "hide the test frames", nil, nil, true)
        sub("lock",         "lock frame movers (also: unlock, raidlock, raidunlock)", nil, nil, true)
        sub("raidbg",       "toggle raid debug backgrounds", true)
        SLASH_DANDERSFRAMES1 = "/df"
        SLASH_DANDERSFRAMES2 = "/dandersframes"
        SlashCmdList["DANDERSFRAMES"] = function(msg)
            local rawMsg = msg or ""
            msg = msg and msg:lower() or ""

            -- "/df clearoverride <key|prefix|all>" — remove a stuck auto-layout
            -- override from the target layout. Parsed from the raw message so the
            -- key keeps its original case (override keys are mixed-case).
            -- "/df debug <command> [args]" — THE form for every diagnostic.
            -- Handled before the if-chain because that chain matches the whole
            -- lowercased message exactly, so "debug auradata player" would fall
            -- past every branch and open the GUI. Args come off rawMsg so unit
            -- tokens and spell names keep their case.
            local dbgWord, dbgRest = rawMsg:match("^%s*[Dd][Ee][Bb][Uu][Gg]%s+(%S+)%s*(.-)%s*$")
            -- "on"/"off" are the logging toggle, not commands named on/off.
            if dbgWord and dbgWord:lower() ~= "on" and dbgWord:lower() ~= "off" then
                local dbgKey = DF.DebugSlashBySub[dbgWord:lower()]
                -- Several debug tools live in the companion and register their
                -- slashes only when it loads. If the word is unknown and the
                -- companion is not in yet, load it and retry once -- otherwise
                -- the first use of /df debug memtest fell through to the final
                -- else and opened the settings window instead of the tool.
                if not dbgKey and not DF._optionsAddonLoaded
                        and DF.EnsureOptionsLoaded and DF:EnsureOptionsLoaded() then
                    dbgKey = DF.DebugSlashBySub[dbgWord:lower()]
                end
                if dbgKey and SlashCmdList[dbgKey] then
                    SlashCmdList[dbgKey](dbgRest or "")
                else
                    -- Not in the slash registry, so it is a dispatcher branch:
                    -- re-enter with the "debug " prefix stripped. One line covers
                    -- all ~50 sub() commands instead of a case per branch. The flag
                    -- is what tells the gate below this arrived via /df debug.
                    DF._viaDebug = true
                    SlashCmdList["DANDERSFRAMES"](
                        dbgWord .. ((dbgRest and dbgRest ~= "") and (" " .. dbgRest) or ""))
                    DF._viaDebug = nil
                end
                return
            end

            -- ☠ THE GATE. Everything below this line is reachable ONLY via
            -- "/df debug <command>" or by being an everyday command. Anything else
            -- — a diagnostic typed bare, or a word /df does not know — opens the
            -- settings window, with no message naming a different spelling.
            --
            -- Written as "allow a known-good shape through" rather than "block the
            -- known debug words", because the block-list version kept leaking: it
            -- could only reject names it had a registry entry for, and commands
            -- reach this dispatcher three different ways (RegisterDebugSlash, the
            -- sub() table, and hand-written branches with no registration at all).
            -- "/df perf" survived three separate attempts to remove it that way.
            -- This shape needs no list of what to reject, so a branch added later
            -- with no registration is covered on the day it is written.
            local bareWord = rawMsg:match("^%s*(%S+)")
            local lw = bareWord and bareWord:lower()
            if lw and lw ~= "debug" and not DF.EVERYDAY_COMMANDS[lw] and not DF._viaDebug then
                if DF.ToggleGUI then DF:ToggleGUI() else DF:Err("GUI not loaded yet.") end
                return
            end

            -- ☠ SECOND HALF OF THE GATE: dev-only diagnostics.
            -- The check above only decides whether a word arrived by a legitimate
            -- route; it says nothing about whether this BUILD should have the word
            -- at all. sub()'s devOnly flag used to gate the printed listing alone,
            -- so every dev branch below stayed runnable on a release build through
            -- "/df debug <word>" — see the DEBUG_SUB_DEV note at the registry.
            -- Falls through to the settings window, exactly like an unknown word:
            -- a hidden command must not announce itself by refusing.
            if lw and DF.DEBUG_SUB_DEV[lw] and not DF:IsDevBuild() then
                if DF.ToggleGUI then DF:ToggleGUI() else DF:Err("GUI not loaded yet.") end
                return
            end

            local firstWord, restRaw = rawMsg:match("^%s*(%S+)%s*(.-)%s*$")
            if firstWord and firstWord:lower() == "clearoverride" then
                if DF.AutoProfilesUI and DF.AutoProfilesUI.ClearOverrideCommand then
                    DF.AutoProfilesUI:ClearOverrideCommand(restRaw ~= "" and restRaw or nil)
                else
                    DF:Say("Auto profiles module not loaded.")
                end
                return
            end

            -- "/df debug zorder" — dump the REAL resolved frame levels for every aura row on
            -- the first shown frame. Static reading says defensive (+51) must draw over
            -- debuffs (+40); when the screen disagrees, this says which link in the chain
            -- (anchor frame -> CustomAuraContainer -> button -> DF art host) breaks it.
            if msg == "zorder" then
                -- unitFrameMap is the addon-wide unit -> frame index (Headers.lua);
                -- prefer a frame that actually has a defensive row to report on.
                local frame
                for _, f in pairs(DF.unitFrameMap or {}) do
                    if f and f:IsShown() then
                        frame = frame or f
                        if f.defensiveFactory then frame = f break end
                    end
                end
                if not frame then
                    DF:Say("no shown frame — enable test mode first.", nil, "WARN")
                    return
                end
                local o = DF:Out("Z-Order", "unit " .. tostring(frame.unit))
                o:Section("Frame")
                o:Field("level", frame:GetFrameLevel(), "NEUTRAL")
                o:Field("strata", tostring(frame:GetFrameStrata()), "NEUTRAL")
                local rows = {
                    { "buff", frame.buffFactory }, { "debuff", frame.debuffFactory },
                    { "defensive", frame.defensiveFactory },
                }
                for _, row in ipairs(rows) do
                    local name, h = row[1], row[2]
                    if not h then
                        print(("  %-10s |cff888888(no handle)|r"):format(name))
                    else
                        local hf = h.GetFrame and h:GetFrame()
                        local cont = h.backend and h.backend.container
                        local btn = h.buttons and h.buttons[1]
                        print(("  %-10s anchor=%s  container=%s  button1=%s  cfgOffset=%s  strata=%s")
                            :format(name,
                                hf and tostring(hf:GetFrameLevel()) or "-",
                                cont and tostring(cont:GetFrameLevel()) or "-",
                                btn and tostring(btn:GetFrameLevel()) or "-",
                                tostring(h.config and h.config.frameLevelOffset or "nil(->40)"),
                                hf and tostring(hf:GetFrameStrata()) or "-"))
                        -- Any DF-owned art parented to the first button (border host etc.)
                        if btn then
                            for _, k in ipairs({ "dfBorderHost", "dfBorder", "dfCD", "dfBar" }) do
                                local w = btn[k]
                                if w and w.GetFrameLevel then
                                    print(("      .%-14s level=%d"):format(k, w:GetFrameLevel()))
                                end
                            end
                        end
                    end
                end

                -- AURA DESIGNER rows and groups. Everything above covers only the three
                -- BUILT-IN rows, which is why a "defensive draws under the Aura Designer"
                -- report could never be settled from this dump — the thing doing the
                -- overdrawing was not in it. Same fields, one line per live AD handle,
                -- bucketed by store key (AuraDesigner/Factory.lua: frame.dfADFactory).
                o:Section("Aura Designer")
                local adStore = frame.dfADFactory
                if not adStore then
                    print("  |cff888888(no AD factory store on this frame)|r")
                else
                    local any = false
                    for _, storeKey in ipairs({ "placed", "fgroups", "dgroups", "healthbar",
                                                "background", "border", "nametext", "healthtext" }) do
                        local t = adStore[storeKey]
                        if t then
                            for id, entry in pairs(t) do
                                local h = entry and entry.handle
                                if h then
                                    any = true
                                    local hf = h.GetFrame and h:GetFrame()
                                    local cont = h.backend and h.backend.container
                                    local btn = h.buttons and h.buttons[1]
                                    print(("  %-9s %-12s anchor=%s  container=%s  button1=%s  cfgOffset=%s  strata=%s")
                                        :format(storeKey, tostring(id):sub(1, 12),
                                            hf and tostring(hf:GetFrameLevel()) or "-",
                                            cont and tostring(cont:GetFrameLevel()) or "-",
                                            btn and tostring(btn:GetFrameLevel()) or "-",
                                            tostring(h.config and h.config.frameLevelOffset or "nil"),
                                            hf and tostring(hf:GetFrameStrata()) or "-"))
                                    if btn then
                                        for _, k in ipairs({ "dfBorderHost", "dfBorder", "dfADBorder",
                                                             "dfCD", "dfBar" }) do
                                            local w = btn[k]
                                            if w and w.GetFrameLevel then
                                                print(("      .%-14s level=%d"):format(k, w:GetFrameLevel()))
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if not any then
                        print("  |cff888888(store present but no live handles)|r")
                    end
                end

                -- The CONFIGURED values, so the dump shows setting-vs-reality side by side.
                -- That is the whole question in an "it says 30 but behaves like more" report.
                o:Section("Configured")
                local zdb = DF.GetDB and DF:GetDB()
                o:Field("defensiveIconFrameLevel", tostring(zdb and zdb.defensiveIconFrameLevel), "NEUTRAL")
                -- DF:ResolveAuraDesigner is the RENDER-side resolver (the same one
                -- Factory:SyncFrame uses). Options.lua's GetAuraDesignerDB is a file-local
                -- and is the EDITOR's view — reading that here would report the wrong table
                -- for a pinned/auto-layout frame.
                local zad = DF.ResolveAuraDesigner and DF:ResolveAuraDesigner(frame)
                local zdef = zad and zad.defaults
                o:Field("AD indicatorFrameLevel", tostring(zdef and zdef.indicatorFrameLevel), "NEUTRAL")
                o:Field("AD indicatorFrameStrata", tostring(zdef and zdef.indicatorFrameStrata), "NEUTRAL")
                return
            end
            if msg == "unlock" then
                if DF.UnlockFrames then DF:UnlockFrames() end
            elseif msg == "lock" then
                if DF.LockFrames then DF:LockFrames() end
            elseif msg == "raidunlock" then
                -- While an auto layout is active, base-position unlock is blocked
                -- (matches the disabled toolbar button) — point users to the active
                -- layout's own Unlock button so they don't move the base by accident.
                if DF.AutoProfilesUI and DF.AutoProfilesUI.IsLayoutActive and DF.AutoProfilesUI:IsLayoutActive() then
                    local name = DF.AutoProfilesUI.GetActiveLayoutName and DF.AutoProfilesUI:GetActiveLayoutName()
                    DF:Say(string.format(L["Auto layout \"%s\" is active. Unlock it from the Auto Layouts page to move its frames."], name or "?"))
                elseif DF.UnlockRaidFrames then
                    DF:UnlockRaidFrames()
                end
            elseif msg == "raidlock" then
                if DF.LockRaidFrames then DF:LockRaidFrames() end
            elseif msg == "reset" then
                DF:ResetFullProfile()
            elseif msg == "resetgui" then
                -- Reset GUI scale, size, and position to defaults
                if DF.db and DF.db.party then
                    DF.db.party.guiScale = 1.0
                    DF.db.party.guiWidth = 760
                    DF.db.party.guiHeight = 520
                    DF.db.party.guiPoint = nil
                    DF.db.party.guiRelPoint = nil
                    DF.db.party.guiX = nil
                    DF.db.party.guiY = nil
                end
                if DF.GUIFrame then
                    DF.GUIFrame:ClearAllPoints()
                    DF.GUIFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
                    DF.GUIFrame:SetSize(760, 520)
                    DF.GUIFrame:SetScale(1.0)
                    if DF.GUI and DF.GUI.ScaleSlider then
                        DF.GUI.ScaleSlider:SetValue(1.0)
                    end
                    DF.GUIFrame:Show()
                end
                DF:Say(L["GUI reset to default size, scale, and position."])
            elseif msg == "pixelcheck" then
                -- Measures the open settings page against the device pixel grid.
                -- Separates "border split across two rows" from "border cut off by
                -- the scroll frame's clip edge" -- the two look the same on screen.
                if DF.GUI and DF.GUI.PixelCheck then
                    DF.GUI.PixelCheck()
                else
                    DF:Say("GUI module not loaded.")
                end
            elseif msg == "gapcheck" or msg == "gapcheck all" or msg == "gapcheck clear" then
                -- Measures the vertical rhythm of the open page: how much slack
                -- each row type carries below it, and the gap that actually lands
                -- between stacked rows. RowHeight sets SLOTS, not gaps. Also
                -- persists the raw rows to DandersFramesDebugDB for offline
                -- analysis -- a hundred rows is not readable in the chat frame.
                if DF.GUI and DF.GUI.GapCheck then
                    DF.GUI.GapCheck(msg:match("^gapcheck%s+(%a+)$"))
                else
                    DF:Say("GUI module not loaded.")
                end
            elseif msg == "navprobe" or msg:match("^navprobe%s+%d+$") then
                -- Traces the left nav's hover state to separate a stale plate /
                -- focus thrash / a dead band between rows from a pure rendering
                -- artefact. All four look the same on screen.
                if DF.GUI and DF.GUI.NavProbe then
                    DF.GUI.NavProbe(tonumber(msg:match("(%d+)$")))
                else
                    DF:Say("GUI module not loaded.")
                end
            elseif msg == "overrides" then
                if DF.AutoProfilesUI and DF.AutoProfilesUI.PrintOverrides then
                    DF.AutoProfilesUI:PrintOverrides()
                else
                    DF:Say("Auto profiles module not loaded.")
                end
            elseif msg == "help" then
                -- The index wears the same header as every other command. Typeable
                -- commands carry O.CMD, the one tone reserved for "you can type this".
                local o = DF:Out("Commands")
                local C = DF.OUT.CMD
                local function cmd(text, desc, status)
                    o:Item(C .. text .. "|r", desc, status)
                end
                cmd("/df", L["open settings"])
                cmd("/df lock|r / " .. C .. "unlock", L["lock/unlock party frames"])
                cmd("/df raidlock|r / " .. C .. "raidunlock", L["lock/unlock raid frames"])
                cmd("/df test", L["toggle the test mode panel"])
                cmd("/df hide", L["hide test frames"])
                cmd("/df users", L["show DandersFrames users in your group"])
                cmd("/df clearoverride <key|all>", L["clear stuck auto-layout overrides"])
                cmd("/df resetgui", L["reset settings window size/position"])
                -- The only destructive entry in the list, so it is the only BAD one.
                cmd("/df reset", L["reset party + raid profiles to defaults"], "BAD")
                cmd("/df console", L["open the debug console page"])
                cmd("/df debug", L["list debug commands (on/off toggles debug logging)"])
                -- pixelcheck / navprobe / gapcheck used to be listed here as well
                -- as in the generated /df debug listing. They are dev diagnostics,
                -- not everyday commands, so help now points at the one list that
                -- is generated and cannot drift instead of duplicating a subset
                -- of it by hand.
            elseif msg == "test" then
                -- The test panel lives in the load-on-demand companion.
                -- Deliberate user command -> load it; the old nil-guard made
                -- /df test a silent no-op until the settings panel was opened.
                if DF.EnsureOptionsLoaded and not DF:EnsureOptionsLoaded() then return end
                if DF.ToggleTestPanel then DF:ToggleTestPanel() end
            elseif msg == "hide" then
                if DF.HideTestFrames then DF:HideTestFrames() end
            elseif msg == "debug" then
                -- Bare "/df debug" lists every available debug command. BOTH
                -- registries feed one list, grouped by subsystem and split only by
                -- the dev gate — see the DEBUG_GROUP_* tables for why the old
                -- three-section shape (which split by registration mechanism) went.
                -- Fully generated, so it cannot drift from what is registered.
                local dev = DF:IsDevBuild()
                local o = DF:Out(L["debug commands"], dev and ("(" .. L["dev build"] .. ")") or nil)
                o:Field(L["Debug logging"],
                    DF.OUT.CMD .. "/df debug on|r / " .. DF.OUT.CMD .. "/df debug off|r")
                o:Field(L["console page"], DF.OUT.CMD .. "/df console|r")

                -- Flatten both registries into one row shape: {name, desc}.
                -- ONE form per row now. The old listing carried a second grey
                -- "/dfXXX" column; those binds are gone, so a column showing them
                -- would be documenting commands the client no longer answers.
                -- An entry whose alias is not /df-prefixed (/rl) still owns a real
                -- bind, so it prints that alias verbatim.
                local byGroup = {}
                local function bucket(isDev, key, name, desc)
                    local g = DF.DEBUG_GROUP_OF[key or ""] or "other"
                    byGroup[isDev] = byGroup[isDev] or {}
                    byGroup[isDev][g] = byGroup[isDev][g] or {}
                    table.insert(byGroup[isDev][g], { name = name, desc = desc })
                end
                for _, e in ipairs(DF.DebugCommands) do
                    local key = e.sub or (e.cmds[1] or ""):match("^/(.+)$")
                    bucket(not not e.dev, key,
                        e.sub and DF:CmdPath(e.sub) or table.concat(e.cmds, " "), e.desc)
                end
                for _, e in ipairs(DF.DebugSubCommands) do
                    if not e.hidden then
                        bucket(not not e.dev, e.cmd,
                            DF:CmdPath(e.cmd) .. (e.args and (" " .. e.args) or ""), e.desc)
                    end
                end

                local function printSection(isDev, heading)
                    local groups = byGroup[isDev]
                    if not groups then return end
                    o:Section(heading)
                    for _, g in ipairs(DF.DEBUG_GROUP_ORDER) do
                        local rows = groups[g]
                        if rows then
                            -- ☠ RAW, NOT L[...]. Both of these used to route through
                            -- AceLocale, which put ~50 developer-only strings into the
                            -- locale table — "container identity-gate dump", "audit
                            -- test-pool spell IDs against this client" and the like.
                            -- CLAUDE.md's never-localize list names exactly this class,
                            -- and the Debug page's category descriptions on the same
                            -- screen were already raw, so the two disagreed.
                            --
                            -- ⚠ Time-sensitive, which is why it is not a style nit: the
                            -- packager's -S flag uploads English source strings to the
                            -- portal on the next build. Once developer text is in front
                            -- of translators for ten languages, removing it is a portal
                            -- cleanup rather than a git revert.
                            o:Line(DF.DEBUG_GROUP_NAMES[g], "NEUTRAL")
                            for _, r in ipairs(rows) do
                                -- One typeable form per row, in O.CMD.
                                o:Item(DF.OUT.CMD .. r.name .. "|r", r.desc)
                            end
                        end
                    end
                end
                printSection(false, L["Support / diagnostics"])
                if dev then printSection(true, L["Dev tools (alpha/beta builds only)"]) end
            elseif msg == "debug on" or msg == "debug off" then
                local newState = msg == "debug on"
                -- The else branch used to set DF.debugEnabled, which nothing read,
                -- and then reported success either way — so with the console module
                -- missing this said "Debug logging enabled" while enabling nothing.
                -- Say what actually happened instead.
                if not DF.DebugConsole then
                    DF:Err(L["Debug console module not loaded."])
                    return
                end
                DF.DebugConsole:SetEnabled(newState)
                DF:Say(format(L["Debug logging %s"], newState and L["enabled"] or L["disabled"]))
            elseif msg == "users" then
                if DF.VersionCheck then DF.VersionCheck:PrintUsers() end
            elseif msg == "console" then
                -- Open settings directly to Debug Console tab
                if not DF.GUIFrame then
                    DF:ToggleGUI()
                elseif not DF.GUIFrame:IsShown() then
                    DF:ToggleGUI()
                end
                if DF.GUI and DF.GUI.SelectTab then
                    DF.GUI.SelectTab("debug_console")
                end
            elseif msg == "debugrested" then
                if DF.DebugRestedIndicator then
                    DF:DebugRestedIndicator()
                end
            -- (Removed) /df debug debugraidbuffs. It dumped DF:GetRaidBuffIcons() and
            -- checked the player's buffs against it. That cache existed for ONE
            -- purpose — matching raid buffs by icon texture when the spell ID is
            -- secret — and that fallback was never wired to anything: the cache had
            -- no reader but this dump. 12.1 solved the same problem the other way,
            -- via the native excludeSpellIDs union with real spell IDs
            -- (missingBuffHideFromBar, Features/Auras.lua), so the icon-matching
            -- approach is superseded, not merely unused. Helper deleted with it.
            elseif msg == "auradata" then
                -- Live aura DATA enumeration (pre-container: reads via C_UnitAuras).
                -- Renamed off "auras" so /df debug auras can be the container-era pipeline
                -- dump — the two answer different questions and both are worth having.
                DF:DebugAuraFilters("player")
            elseif msg == "ppdump" then
                -- Pixel-perfect geometry ground truth for aura containers (physical-px
                -- rects + grid deviation per anchor-chain element)
                if DF.AuraContainer and DF.AuraContainer.DebugDumpPP then DF.AuraContainer.DebugDumpPP() end
            elseif msg == "ppbadge" then
                -- Diagnostic: window-park missing badges (bypasses the container's secret
                -- self-size) — proves/disproves the last missing-badge pp drift source
                if DF.AuraContainer and DF.AuraContainer.ToggleBadgeParkDebug then DF.AuraContainer.ToggleBadgeParkDebug() end
            elseif msg == "cbt" or msg:match("^cbt%s+%d") then
                -- Colour-by-time ground truth: curve-API reachability, the account-wide
                -- dials, the mode an enabled consumer composes, whether it built a real
                -- curve or fell back to the legacy seconds buckets, and the expiry
                -- reveal's threshold + which of its colour bands actually render.
                -- Optional number = try another reveal threshold ("/df debug cbt 60").
                if DF.DebugDumpColorByTime then DF:DebugDumpColorByTime(tonumber(msg:match("(%d+)"))) end
            elseif msg == "guiwidth" then
                -- Settings-layout ground truth: every frame on the open page with its
                -- live width, flagging any that lost one. Truncated / non-wrapping label
                -- text is always a width fault; this says WHICH frame caused it.
                if DF.GUI and DF.GUI.DebugDumpWidths then DF.GUI:DebugDumpWidths() end
            elseif msg == "idgate" then
                -- Identity-gate ground truth: per vulnerable handle, live UnitCanAssist
                -- vs the stored gate verdict vs actual window visibility
                if DF.AuraContainer and DF.AuraContainer.DebugDumpIdentityGate then DF.AuraContainer.DebugDumpIdentityGate() end
            elseif msg == "dispelids" then
                -- Custom dispel colours: the curve's X = the dispel type ID. The enum's
                -- NAME is build-dependent, so FindDispelTypeEnum scans Enum for the
                -- Magic/Curse/Disease/Poison shape; this probe shows what it found,
                -- the SetAuraBorder style enums (Color vs Atlas resolution), and
                -- whether the shared curve builds.
                local o = DF:Out("Dispel IDs", "colour probe")
                DF._dispelTypeEnum = nil   -- force a fresh scan
                local E = DF.FindDispelTypeEnum and DF:FindDispelTypeEnum()
                if E then
                    o:Section("Enum." .. tostring(DF._dispelTypeEnumName))
                    for name, val in pairs(E) do
                        o:Field(tostring(name), tostring(val))
                    end
                else
                    -- Without this enum the whole custom-colour path has no X axis.
                    o:Line("no Enum table with Magic/Curse/Disease/Poison found", "bad")
                end
                o:Section("Border style enums")
                local function dumpEnum(label, t)
                    if type(t) == "table" then
                        local parts = {}
                        for k, v in pairs(t) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
                        o:Field(label, table.concat(parts, "  "))
                    else
                        o:Field(label, "nil", "neutral")
                    end
                end
                dumpEnum("Enum.CustomAuraButtonBorderStyle", Enum and Enum.CustomAuraButtonBorderStyle)
                dumpEnum("AuraButtonBorderStyle (legacy global)", _G.AuraButtonBorderStyle)
                if DF.InvalidateDispelColorCurve then DF:InvalidateDispelColorCurve() end
                o:Section("Shared builders")
                local curve = DF.GetDispelColorCurve and DF:GetDispelColorCurve()
                o:Field("curve built", curve and "yes" or "no", curve and "good" or "bad")
                local map = DF.GetDispelColorMap and DF:GetDispelColorMap()
                o:Field("colour map built", map and "yes" or "no", map and "good" or "bad")
                local hasDTC = C_UnitAuras and C_UnitAuras.GetAuraDispelTypeColor ~= nil
                o:Field("GetAuraDispelTypeColor", hasDTC and "present" or "absent",
                    hasDTC and "good" or "warn")
                -- Overlay ground truth: each SetAuraBorder bind site's last attempt
                -- ("ok" / the pcall error / never attempted). Keyed by slot key
                -- (main / gameborder / edgeTOP / …).
                local be = DF._dispelBindErr
                o:Section("Overlay binds")
                if be then
                    for site, res in pairs(be) do
                        o:Field(tostring(site), tostring(res), res == "ok" and "good" or "bad")
                    end
                else
                    o:Line("no attempts recorded - no dispellable aura styled since reload?", "neutral")
                end
            elseif msg == "admissing" then
                -- Diagnostic for the Aura Designer show-when-missing push mechanism
                if DF.DebugADMissing then DF:DebugADMissing() end
            elseif msg == "admissing mark" then
                -- Visual push probe: markers that slide with the missing badges
                if DF.DebugADMissingMark then DF:DebugADMissingMark() end
            elseif msg == "tdmirror" then
                -- Text Designer mirror probe (AD name/health text colour groundwork)
                if DF.DebugTDMirror then DF:DebugTDMirror() end
            elseif msg == "debugfonts" then
                -- Debug command to show font info
                local o = DF:Out("Fonts")
                local LSM = DF.GetLSM and DF.GetLSM()
                if LSM then
                    local total = #LSM:List("font")
                    local available = 0
                    for _ in pairs(DF:GetFontList()) do available = available + 1 end
                    o:Field("Total in SharedMedia", total)
                    o:Field("Available in DandersFrames", available)
                else
                    -- No LibSharedMedia means the font list falls back to the
                    -- built-ins only, which is worth knowing rather than silent.
                    o:Line("LibSharedMedia not available", "warn")
                end
            elseif msg:match("^auradata ") then
                local unit = msg:match("^auradata (.+)")
                DF:DebugAuraFilters(unit)
            elseif msg == "clickcast" then
                -- Moved to /df debug cc registration; this spelling still answers so
                -- muscle memory keeps working, the same courtesy the eleven
                -- /dfccXXX commands got when they were folded in.
                if SlashCmdList["DFCCREGISTRATION"] then
                    SlashCmdList["DFCCREGISTRATION"]()
                else
                    DF:Err("Click-casting module not loaded")
                end
            elseif msg == "dispel" or msg:match("^dispel ") then
                -- Every dispel probe answers here. The arg routing (unit dump /
                -- "ids" / "render") lives ONCE, in Features/Dispel.lua's DFDISPEL
                -- handler, so this branch is a pure forward — the two used to
                -- carry near-identical copies of the same if-chain.
                local arg = msg:match("^dispel (.+)")
                if SlashCmdList["DFDISPEL"] then
                    SlashCmdList["DFDISPEL"](arg or "")
                else
                    DF:Err("Dispel debug not loaded")
                end
            elseif msg == "resetconflict" then
                -- Moved to /df debug cc resetconflict; old spelling still answers.
                if SlashCmdList["DFCCRESETCONFLICT"] then
                    SlashCmdList["DFCCRESETCONFLICT"]()
                else
                    DF:Err("Click-casting module not loaded")
                end
            elseif msg == "casthistory" then
                -- Show cast history (TEST feature for secret values)
                if DF.ShowCastHistory then
                    DF:ShowCastHistory()
                else
                    DF:Err("Cast history not available")
                end
            elseif msg == "clearhistory" then
                -- Clear cast history
                if DF.ClearCastHistory then
                    DF:ClearCastHistory()
                else
                    DF:Err("Cast history not available")
                end
            elseif msg == "headers" or msg:match("^headers ") then
                -- Bare "/df debug headers" is the state dump a user pastes back; with an
                -- argument it forwards to the /dfheaders tool (init, etc.). Merged
                -- so one name does not mean two different things.
                local arg = msg:match("^headers (.+)")
                if arg then
                    if SlashCmdList["DFHEADERS"] then
                        SlashCmdList["DFHEADERS"](arg)
                    else
                        DF:Err("Header tool not loaded")
                    end
                elseif DF.DumpHeaderInfo then
                    DF:DumpHeaderInfo()
                else
                    DF:Err("Header info not available")
                end
            elseif msg == "attached" then
                -- List other addons anchored/parented to DF unit frames
                if DF.ScanFrameAttachments then
                    DF:ScanFrameAttachments()
                else
                    DF:Err("Attachment scan not available")
                end
            elseif msg == "raidbg" then
                -- Toggle raid group debug backgrounds
                if DF.ToggleRaidDebugBackgrounds then
                    DF:ToggleRaidDebugBackgrounds()
                else
                    DF:Err("Raid debug not available")
                end
            elseif msg == "exportaudit" then
                -- Dev: verify every Config default is export-categorised or
                -- declared local-only (guards against export-list drift).
                if DF.AuditExportCategories then
                    DF:AuditExportCategories()
                end
            elseif msg == "auditspells" then
                -- Dev: flag Filter Registry spell-DB entries whose ids have
                -- no client data or no description (review candidates).
                if DF.FilterRegistry and DF.FilterRegistry.AuditSpellData then
                    DF.FilterRegistry:AuditSpellData()
                else
                    DF:Err("Filter Registry not available")
                end
            elseif msg == "testids" then
                -- Dev: audit the test pool's spell IDs against this client —
                -- what each stored ID resolves to, and whether a name lookup
                -- can find the current ID (for re-hardcoding after reshuffles).
                -- Results also land in the SavedVariables root (flushed by the
                -- next /reload) so they can be read from disk — no chat copy.
                -- DF.TestData lives in the companion; load it or bail.
                if DF.EnsureOptionsLoaded and not DF:EnsureOptionsLoaded() then return end
                if not DF.TestData then DF:Err("test data unavailable") return end
                local dump = {}
                local o = DF:Out("Test IDs", "spell-ID audit")
                for _, poolName in ipairs({ "buffs", "debuffs" }) do
                    o:Section(poolName, #(DF.TestData[poolName] or {}))
                    for i, e in ipairs(DF.TestData[poolName] or {}) do
                        local stored = "-"
                        if e.spellID then
                            local ok, nm = pcall(C_Spell.GetSpellName, e.spellID)
                            stored = e.spellID .. " -> " .. tostring(ok and nm or "ERR")
                        end
                        local byName = "-"
                        local ok2, info = pcall(C_Spell.GetSpellInfo, e.name)
                        if ok2 and type(info) == "table" and info.spellID then
                            byName = tostring(info.spellID) .. " (" .. tostring(info.name) .. ")"
                        end
                        local line = ("%s | %d. %s | stored: %s | byName: %s"):format(poolName, i, e.name, stored, byName)
                        -- A stored ID the client cannot resolve is the whole point
                        -- of this audit, so it is the one status worth colouring.
                        o:Item(i .. ". " .. e.name,
                            ("stored: %s | byName: %s"):format(stored, byName),
                            stored:match("ERR") and "bad" or nil)
                        dump[#dump + 1] = line
                    end
                end
                if DandersFramesDB_v2 then
                    DandersFramesDB_v2.testIDsDump = dump
                    DF:Say("dump saved — /reload to flush it to disk.")
                end
            elseif msg == "mousefoci" then
                -- Dev: after 2s, dump the frame stack under the cursor with mouse
                -- flags — pinpoints which frame is winning hover (tooltip leaks).
                DF:Say("hover the target for 2 seconds...")
                C_Timer.After(2, function()
                    local foci = GetMouseFoci and GetMouseFoci() or {}
                    DF:Out("Mouse Foci", #foci .. " frame(s) under the cursor")
                    for i, f in ipairs(foci) do
                        local name = "?"
                        pcall(function() name = f:GetName() or "(anon)" end)
                        local ftype = "?"
                        pcall(function() ftype = f:GetObjectType() end)
                        local motion, level = "?", "?"
                        pcall(function() motion = tostring(f:IsMouseMotionEnabled()) end)
                        pcall(function() level = tostring(f:GetFrameLevel()) end)
                        local isTip = ""
                        pcall(function()
                            if f._name or f._spellID then isTip = " " .. DF.OUT.NEUTRAL .. "(test tip: " .. tostring(f._name) .. ")|r" end
                        end)
                        print(("  %d. %s (%s) motion=%s level=%s%s"):format(i, name, ftype, motion, level, isTip))
                    end
                end)
            elseif msg == "dispeldbg" then
                -- Dev: dump the dispel gradient's REAL render state on every frame
                -- that has one (legacy overlay = test path; slot widgets = 12.1
                -- live path) — rect vs parent, fill value, blend, draw order.
                -- Ground-truth for "strip renders partial width" reports.
                local o = DF:Out("Dispel Render", "gradient state")
                local function num(v)
                    if v == nil then return "nil" end
                    if issecretvalue and issecretvalue(v) then return "SECRET" end
                    if type(v) == "number" then return string.format("%.1f", v) end
                    return tostring(v)
                end
                local function dumpBar(tag, bar, hostFrame)
                    if not bar then return end
                    local mn, mx, val, w, h, pw, lvl, blend, alpha, shown, orient, rev
                    pcall(function() mn, mx = bar:GetMinMaxValues() end)
                    pcall(function() val = bar:GetValue() end)
                    pcall(function() w, h = bar:GetSize() end)
                    pcall(function() lvl = bar:GetFrameLevel() end)
                    pcall(function() orient = bar:GetOrientation() end)
                    pcall(function() rev = bar:GetReverseFill() end)
                    pcall(function()
                        local t = bar.GetStatusBarTexture and bar:GetStatusBarTexture()
                        if t then blend = t:GetBlendMode(); alpha = t:GetAlpha(); shown = t:IsShown() end
                    end)
                    pcall(function() if hostFrame and hostFrame.healthBar then pw = hostFrame.healthBar:GetWidth() end end)
                    o:Line(("%s: shown=%s rect=%sx%s (hb w=%s) val=%s/%s-%s orient=%s rev=%s blend=%s texAlpha=%s texShown=%s lvl=%s"):format(
                        tag, tostring(bar:IsShown()), num(w), num(h), num(pw), num(val), num(mn), num(mx),
                        tostring(orient), tostring(rev), tostring(blend), num(alpha), tostring(shown), num(lvl)))
                end
                local function dumpTex(tag, tex)
                    if not tex then return end
                    local w, h, blend, alpha, shown, layer, sub
                    pcall(function() w, h = tex:GetSize() end)
                    pcall(function() blend = tex:GetBlendMode() end)
                    pcall(function() alpha = tex:GetAlpha() end)
                    pcall(function() shown = tex:IsShown() end)
                    pcall(function() layer, sub = tex:GetDrawLayer() end)
                    o:Line(("%s: shown=%s rect=%sx%s blend=%s alpha=%s layer=%s/%s"):format(
                        tag, tostring(shown), num(w), num(h), tostring(blend), num(alpha), tostring(layer), tostring(sub)))
                end
                local function dumpFrame(frame, label)
                    if not frame then return end
                    local db2 = DF:GetFrameDB(frame)
                    o:Section(label)
                    o:Line(("style=%s onCur=%s hbLvl=%s frameLvl=%s"):format(
                        tostring(db2 and db2.dispelGradientStyle),
                        tostring(db2 and db2.dispelGradientOnCurrentHealth),
                        frame.healthBar and tostring(frame.healthBar:GetFrameLevel()) or "?",
                        tostring(frame:GetFrameLevel())), "neutral")
                    local legacy = frame.dfDispelOverlay
                    if legacy then
                        o:Line(("legacy overlay shown=%s lvl=%s tracks=%s"):format(
                            tostring(legacy:IsShown()), tostring(legacy:GetFrameLevel()),
                            tostring(legacy.gradientTracksHealth)))
                        dumpBar("legacy.gradient", legacy.gradient, frame)
                    end
                    local hnd = frame.dispelFactory
                    local slots = hnd and hnd.GetOverlaySlots and hnd:GetOverlaySlots()
                    if slots then
                        for key, btn in pairs(slots) do
                            local wdg = btn.dfDispelWidget
                            if wdg then
                                o:Line(("slot[%s] widget shown=%s lvl=%s tracks=%s"):format(
                                    tostring(key), tostring(wdg:IsShown()), tostring(wdg:GetFrameLevel()),
                                    tostring(wdg.gradientTracksHealth)))
                                dumpBar("slot.gradient", wdg.gradient, frame)
                                dumpTex("slot.nativeGradient", wdg.nativeGradient)
                            end
                            if btn.dfDispelRing then dumpTex("slot[" .. tostring(key) .. "].ring", btn.dfDispelRing) end
                            -- Edge strips are keyed BY SIDE now (all four ride the one
                            -- overlay slot since the carriers were consolidated).
                            if type(btn.dfDispelEdgeTex) == "table" then
                                for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
                                    local et = btn.dfDispelEdgeTex[side]
                                    if et then dumpTex("slot[" .. tostring(key) .. "].edge" .. side, et) end
                                end
                            end
                            if btn._dfDispelCarriers then
                                o:Line(("slot[%s] bound carriers=%d"):format(tostring(key), #btn._dfDispelCarriers))
                            end
                        end
                    end
                    -- Neighbours that can overdraw the deficit area
                    dumpBar("healPrediction", frame.dfHealPredictionBar, frame)
                    dumpBar("absorb", frame.dfAbsorbBar, frame)
                end
                -- Live: every shown frame with any dispel state; Test: shown test frames
                if DF.IterateAllFrames then
                    DF:IterateAllFrames(function(f)
                        if f and f:IsShown() and (f.dfDispelOverlay or f.dispelFactory) then
                            dumpFrame(f, tostring(f.unit))
                        end
                    end)
                end
                if DF.testPartyFrames then
                    for i = 0, 4 do
                        local f = DF.testPartyFrames[i]
                        if f and f:IsShown() then dumpFrame(f, "test" .. i) end
                    end
                end
            elseif msg == "localewarn" then
                -- Toggle AceLocale missing-key warnings for this session
                DF:SetLocaleWarnings(not DF.localeWarningsEnabled)
                -- Status goes in the VALUE slot so Say tones it, rather than a
                -- hand-coloured span inside the sentence.
                DF:Say("Locale warnings for this session",
                    DF.localeWarningsEnabled and "enabled" or "disabled",
                    DF.localeWarningsEnabled and "GOOD" or "NEUTRAL")
            elseif msg == "profiler" then
                -- Toggle the function profiler UI
                if DF.Profiler then
                    DF.Profiler:ToggleUI()
                else
                    DF:Err("Profiler not loaded")
                end
            elseif msg == "profiler hook" then
                -- Toggle the OnUpdate hook (requires /rl)
                if not DandersFramesDB_v2 then DandersFramesDB_v2 = {} end
                local newState = not DandersFramesDB_v2.profilerOnUpdateHook
                DandersFramesDB_v2.profilerOnUpdateHook = newState
                if newState then
                    DF:Say("Profiler OnUpdate hook |cff00ff00ENABLED|r. Type |cffeda55f/rl|r to apply.")
                else
                    DF:Say("Profiler OnUpdate hook |cffff9900DISABLED|r. Type |cffeda55f/rl|r to apply.")
                end
            elseif msg == "profile" or msg:match("^profile %d") then
                -- Quick profile run: /df debug profile [seconds]
                if DF.Profiler then
                    local duration = tonumber(msg:match("(%d+)")) or 10
                    DF.Profiler:QuickProfile(duration)
                else
                    DF:Err("Profiler not loaded")
                end
            else
                -- ☠ NO BARE-NAME FALLBACK. "/df <name>" used to run any diagnostic,
                -- which meant two spellings for one command and neither of them said
                -- "this is a debug tool". Diagnostics are intercepted above; anything
                -- else unrecognised opens the settings window.
                if DF.ToggleGUI then
                    DF:ToggleGUI()
                else
                    DF:Err("GUI not loaded yet.")
                end
            end
        end
        
        -- Add convenient /rl reload command
        -- The one slash command that never went through RegisterDebugSlash, so it
        -- was the only one absent from /df debug. It is a convenience rather than
        -- a diagnostic, but being listed costs nothing and being invisible is how
        -- commands get forgotten.
        -- NOT via RegisterDebugSlash: /rl is universal muscle memory, so listing it
        -- under /df debug spends a row telling people something they already know.
        -- It is also the one command with no "/df debug <name>" form, which made it
        -- the odd row out in a list where every other entry shares one shape.
        SLASH_DFRL1 = "/rl"
        SlashCmdList["DFRL"] = function()
            ReloadUI()
        end

        if DF.VersionCheck then DF.VersionCheck:Init() end
        if DF.Nicknames then DF.Nicknames:Init() end

        -- Post-initialization updates (frames already created at ADDON_LOADED)
        -- These need a delay to let Blizzard addons settle and world to be ready
        C_Timer.After(0.5, function()
            -- One-time migration of legacy name/health/status text settings into
            -- Text Designer elements. Naturally idempotent (per-mode guard +
            -- migratedFromLegacy flag), so re-running on every login is a no-op
            -- once it has run. The function-exists guard is belt-and-suspenders;
            -- the Text Designer files now load in every build.
            -- Designer Presets: move every inline auraDesigner / textDesigner
            -- config (party/raid + each raid auto-layout override) into the
            -- named preset library. Runs BEFORE the TD-legacy migration below so
            -- that migration builds its elements straight into the "Party"/"Raid"
            -- presets (its guard flag then persists on the preset). Idempotent.
            if DF.MigrateDesignerPresets then
                DF:MigrateDesignerPresets()
            end

            -- Carry old important-spell highlight settings into the new
            -- Important Spell Border key set (per-profile guarded, no-op once run).
            if DF.MigrateTargetedSpellImportantBorder then
                DF:MigrateTargetedSpellImportantBorder()
            end

            if DF.MigrateTextDesignerFromLegacy then
                DF:MigrateTextDesignerFromLegacy()
            end
            -- One-time cleanup of stray health text the pre-fix migration injected
            -- onto profiles that had health text off (idempotent, self-guarded).
            if DF.CorrectStrayMigratedHealthText then
                DF:CorrectStrayMigratedHealthText()
            end

            -- Strip orphaned legacy text overrides from raid auto-layouts now that
            -- TD owns the built-in text (gated on migratedFromLegacy inside).
            if DF.CleanupLegacyTextLayoutOverrides then
                DF:CleanupLegacyTextLayoutOverrides()
            end

            -- Appearance-preserving border migration: fold AD icon/square inset
            -- into BorderSize and zero buff/debuff inset so the unified-border
            -- rework keeps the pre-rework look. Per-profile guarded (no-op once
            -- run); independent of Designer Presets (preset walk is nil-guarded).
            if DF.MigrateBorderInsetFold then
                DF:MigrateBorderInsetFold()
            end

            -- Fold the legacy OOR name-text alpha into the unified oorTextAlpha
            -- (Text Designer now renders all text). Per-profile guarded.
            if DF.MigrateOORTextAlpha then
                DF:MigrateOORTextAlpha()
            end

            -- Retire the deprecated raidGroupOrder reverse toggle (NORMAL-ize any
            -- stale "REVERSE"); group order now comes from Group Display Order.
            if DF.MigrateDeprecateRaidGroupOrder then
                DF:MigrateDeprecateRaidGroupOrder()
            end

            -- Priority higher-wins flip is now lazy/at-point-of-use — see
            -- DF.MigrateAuraDesignerPrioritiesLazy and CC:MigratePrioritiesLazy.
            -- Only forward the old coarse migration flags to the new fine-grained
            -- ones here (never flips a value), so data an earlier pass already
            -- converted is not double-flipped.
            if DF.ForwardPriorityMigrationFlags then
                DF:ForwardPriorityMigrationFlags()
            end

            -- CRITICAL: Update power bars now that unit data is available
            -- At ADDON_LOADED, UnitPower() etc may return 0 before player is loaded
            -- Power bar updates don't require combat protection
            if DF.UpdatePower then
                -- Party frames via iterator
                if DF.IteratePartyFrames then
                    DF:IteratePartyFrames(function(frame)
                        DF:UpdatePower(frame)
                    end)
                end
                -- Raid frames via iterator
                if DF.IterateRaidFrames then
                    DF:IterateRaidFrames(function(frame)
                        DF:UpdatePower(frame)
                    end)
                end
            end
            
            -- Full frame update if not in combat
            if not InCombatLockdown() then
                if IsInRaid() and not DF:IsInArena() then
                    if DF.UpdateLiveRaidFrames then
                        DF:UpdateLiveRaidFrames()
                    end
                else
                    if DF.UpdateAllFrames then
                        DF:UpdateAllFrames()
                    end
                end
            end
            
            -- Register click casting now that frames are ready
            if DF.RegisterClickCastFrames then
                DF:RegisterClickCastFrames()
            end
            if DF.RegisterRaidClickCastFrames then
                DF:RegisterRaidClickCastFrames()
            end
            
            -- Update rested indicator
            if DF.UpdateRestedIndicator then
                DF:UpdateRestedIndicator()
            end
            -- Update default player frame visibility
            if DF.UpdateDefaultPlayerFrame then
                DF:UpdateDefaultPlayerFrame()
            end
            
            -- Refresh fonts (may not have been fully available during ADDON_LOADED combat reload)
            if DF.RefreshAllFonts then
                if InCombatLockdown() then
                    -- Queue font refresh for after combat
                    DF.pendingFontRefresh = true
                else
                    DF:RefreshAllFonts()
                end
            end
            
            -- Flat layout refresh to ensure correct positioning on load
            local raidDb = DF:GetRaidDB()
            if IsInRaid() and not raidDb.raidUseGroups and not InCombatLockdown() then
                if DF.headersInitialized then
                    DF:ApplyHeaderSettings()
                end
                if DF.UpdateRaidLayout then
                    DF:UpdateRaidLayout()
                end
            end
            
            -- Update raid group labels (needs headers to be positioned first)
            if DF.UpdateRaidGroupLabels then
                DF:UpdateRaidGroupLabels()
            end
        end)

        -- ⚰ DEPRECATED-TARGETED-SPELLS — the once-per-account Targeted Spells
        -- setup wizard used to fire here, 5s after login, offering to turn the
        -- feature on. It could not stay: the feature was force-disabled at load and
        -- its settings page had left the sidebar, so the wizard would have sold a
        -- feature that could neither run nor be configured, and its "Open settings"
        -- button would have landed on a page with no nav row.
        --
        -- 2026-07-30: DF:ShowTargetedSpellSetupWizard is now gone too, with the rest
        -- of the group-frame feature, so there is nothing left to restore here. The
        -- saved flag DandersFramesDB_v2.targetedSpellWizardSeen is deliberately left
        -- alone (stripping saved keys is a separate call).

    elseif event == "GROUP_ROSTER_UPDATE" then
        if DF.RosterDebugEvent then DF:RosterDebugEvent("Core.lua:GROUP_ROSTER_UPDATE") end

        -- Headers.lua handles roster updates via ProcessRosterUpdate (container
        -- visibility, sorting). Frame updates happen via OnAttributeChanged (unit
        -- changes) and PLAYER_ROLES_ASSIGNED (role changes).
        --
        -- Missing buff icons are not cleared by OnAttributeChanged when a slot
        -- empties (unit → nil skips the refresh), and UNIT_AURA stops firing for
        -- units that left the group. Frames that remain visible (player frame,
        -- remaining group members) can be left with stale indicators. Sweep after
        -- the roster settles. The 0.1s throttle inside UpdateAllMissingBuffIcons
        -- prevents spam from rapid GRU bursts on group transitions.
        if DF.UpdateAllMissingBuffIcons then
            C_Timer.After(0.3, function()
                if not InCombatLockdown() then
                    DF:UpdateAllMissingBuffIcons()
                end
            end)
        end
        return
        
    elseif event == "PLAYER_ROLES_ASSIGNED" then
        -- Skip completely - headerChildEventFrame in Headers.lua handles this centrally
        -- No need to call UpdateAllRoleIcons which iterates all frames
        return
        
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" or event == "PLAYER_TALENT_UPDATE" then
        -- These fire in bursts (often 8+ times) on zone-in, login, and group
        -- join as the client syncs talent/spec data. Doing a full UpdateAllFrames
        -- + Aura Designer refresh on every fire caused a noticeable hitch when
        -- joining a large raid. Coalesce the burst into a single deferred refresh.
        if not DF._specTalentRefreshScheduled then
            DF._specTalentRefreshScheduled = true
            C_Timer.After(0.15, function()
                DF._specTalentRefreshScheduled = false
                -- Spec or talents changed - check for profile auto-switch
                if DF.CheckProfileAutoSwitch then
                    DF:CheckProfileAutoSwitch()
                end
                -- Update all frames (resource bar colors may change)
                if DF.UpdateAllFrames then
                    DF:UpdateAllFrames()
                end
                -- Re-anchor raid container — spec switch can change layout dimensions
                -- Must be outside combat: SetScale on the container is protected
                if DF.UpdateRaidContainerPosition and not InCombatLockdown() then
                    DF:UpdateRaidContainerPosition()
                end
                -- Refresh Aura Designer (per-spec aura lists may differ)
                -- Invalidate the adapter's per-spec spellId cache first — otherwise
                -- stale entries prevent the new spec's spell IDs (e.g., Earth Shield
                -- for Resto Shaman) from being recognized after a spec swap.
                if DF.AuraDesigner and DF.AuraDesigner.Adapter and DF.AuraDesigner.Adapter.InvalidateSpecCache then
                    DF.AuraDesigner.Adapter:InvalidateSpecCache()
                end
                if DF.AuraDesigner and DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end
            end)
        end

    elseif event == "UNIT_PET" then
        -- Pet summoned or dismissed - update pet frames
        if DF.HandleUnitPetEvent then
            DF:HandleUnitPetEvent(arg1)
        end
        
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Track combat state
        DF.playerInCombat = false

        -- Arena pet frames deferred by the combat guard in UpdateArenaPetFrames.
        -- Forced, because UpdateAllRaidPetFrames throttles to one run per frame and
        -- something else may already have consumed this frame's slot.
        if DF.pendingArenaPetUpdate then
            DF.pendingArenaPetUpdate = nil
            if DF.UpdateAllRaidPetFrames then DF:UpdateAllRaidPetFrames(true) end
        end

        -- Clean up after test mode was interrupted by combat
        if DF.testModeInterruptedByCombat then
            DF.testModeInterruptedByCombat = false
            -- Unregister state drivers so UpdateHeaderVisibility manages normally
            DF:ClearTestModeStateDrivers()
            -- Restore proper fine-grained header visibility
            if DF.UpdateHeaderVisibility then
                DF:UpdateHeaderVisibility()
            end
            -- Refresh live frame data
            if DF.UpdateAllDispelOverlays then
                C_Timer.After(0.2, function()
                    DF:UpdateAllDispelOverlays()
                end)
            end
            if DF.UpdateAllMissingBuffIcons then
                C_Timer.After(0.1, function()
                    if not InCombatLockdown() then
                        DF:UpdateAllMissingBuffIcons()
                    end
                end)
            end
            if DF.UpdateAllPetFrames then
                C_Timer.After(0.1, function()
                    DF:UpdateAllPetFrames()
                end)
            end
            if DF.UpdateAllRaidPetFrames then
                C_Timer.After(0.1, function()
                    DF:UpdateAllRaidPetFrames()
                end)
            end
        end
        
        DF:Debug("ROLE", "PLAYER_REGEN_ENABLED (leaving combat)")
        
        -- Process any pending unit watch registrations
        if DF.ProcessPendingUnitWatch then
            DF:ProcessPendingUnitWatch()
        end
        
        -- Apply queued updates after combat
        if DF.needsUpdate then
            DF.needsUpdate = false
            DF:UpdateAll()
        end
        
        -- Process pending font refresh (queued during combat reload)
        if DF.pendingFontRefresh then
            DF.pendingFontRefresh = false
            if DF.RefreshAllFonts then
                DF:RefreshAllFonts()
            end
        end
        
        -- Update missing buff icons now that we're out of combat
        if DF.UpdateAllMissingBuffIcons then
            DF:UpdateAllMissingBuffIcons()
        end
        -- Refresh auras now that we're out of combat
        if DF.UpdateAllAuras then
            DF:UpdateAllAuras()
        end
        -- Update role icons (in case hideInCombat is enabled)
        if DF.UpdateAllRoleIcons then
            DF:UpdateAllRoleIcons()
        end
        -- Update permanent mover combat state (color/visibility) — delayed to run
        -- after any deferred frame refreshes that might reset backdrop colors
        if DF.UpdatePermanentMoverCombatState then
            C_Timer.After(0.05, function() DF:UpdatePermanentMoverCombatState() end)
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Track combat state
        DF.playerInCombat = true
        
        -- Auto-exit test mode when combat starts
        -- State drivers (registered when test mode started) will auto-show
        -- the correct live frames now that [combat] condition is true
        if DF.testMode or DF.raidTestMode then
            DF.testModeInterruptedByCombat = true
            
            -- Hide party test frames (non-secure, safe in combat)
            if DF.testMode then
                DF.testMode = false
                DF:StopTestAnimation()
                for i = 0, 4 do
                    local frame = DF.testPartyFrames and DF.testPartyFrames[i]
                    if frame then
                        frame:Hide()
                        if frame.absorbAttachedTexture then frame.absorbAttachedTexture:Hide() end
                        if frame.healAbsorbAttachedTexture then frame.healAbsorbAttachedTexture:Hide() end
                        if frame.absorbOverflowBar then frame.absorbOverflowBar:Hide() end
                    end
                end
                if DF.testPartyContainer then
                    DF.testPartyContainer:Hide()
                end
                if DF.HideTestPersonalTargetedSpells then
                    DF:HideTestPersonalTargetedSpells()
                end
            end
            
            -- Hide raid test frames (non-secure, safe in combat)
            if DF.raidTestMode then
                DF.raidTestMode = false
                DF:StopTestAnimation()
                for i = 1, 40 do
                    local frame = DF.testRaidFrames and DF.testRaidFrames[i]
                    if frame then
                        frame:Hide()
                        if frame.absorbAttachedTexture then frame.absorbAttachedTexture:Hide() end
                        if frame.healAbsorbAttachedTexture then frame.healAbsorbAttachedTexture:Hide() end
                        if frame.absorbOverflowBar then frame.absorbOverflowBar:Hide() end
                    end
                end
                if DF.testRaidContainer then
                    DF.testRaidContainer:Hide()
                end
                if DF.HideTestPersonalTargetedSpells then
                    DF:HideTestPersonalTargetedSpells()
                end
                -- Hide group labels
                if DF.raidGroupLabels then
                    for g = 1, 8 do
                        if DF.raidGroupLabels[g] then
                            DF.raidGroupLabels[g]:Hide()
                            if DF.raidGroupLabels[g].shadow then
                                DF.raidGroupLabels[g].shadow:Hide()
                            end
                        end
                    end
                end
            end
            
            -- Both mode flags are down now, so hand the shared engine state back:
            -- the aura data provider and the pinned preview. This path clears the
            -- flags inline rather than going through HideTestFrames, and skipping
            -- the handback used to strand C_UnitAuras on the SAMPLE provider for
            -- the rest of the session -- and the state driver below shows the LIVE
            -- frames in combat, so they rendered fake auras.
            DF:TeardownTestModeEngines()

            DF:Say(L["Test mode ended — entering combat."])

            -- Switch from test mode state drivers ([combat] conditions) to group
            -- transition drivers ([group:raid] conditions) so frames stay visible
            -- when combat ends (avoids flicker before UpdateHeaderVisibility runs)
            DF:SetGroupTransitionStateDrivers()
            
            -- Update GUI buttons to reflect test mode is no longer active
            if DF.GUI then
                if DF.GUI.UpdateTestButtonState then DF.GUI.UpdateTestButtonState() end
                if DF.GUI.UpdateLockButtonState then DF.GUI.UpdateLockButtonState() end
            end
        end
        
        DF:Debug("ROLE", "PLAYER_REGEN_DISABLED (entering combat)")
        -- Update role icons (in case hideInCombat is enabled)
        if DF.UpdateAllRoleIcons then
            DF:UpdateAllRoleIcons()
        end
        -- Refresh auras so combat-aware blacklist filters apply immediately
        if DF.RefreshAllVisibleFrames then
            DF:RefreshAllVisibleFrames()
        end
        -- Update permanent mover combat state (color/visibility) — delayed to run
        -- after any deferred frame refreshes that might reset backdrop colors
        if DF.UpdatePermanentMoverCombatState then
            C_Timer.After(0.05, function() DF:UpdatePermanentMoverCombatState() end)
        end

    elseif event == "PLAYER_UPDATE_RESTING" then
        -- Update rested indicator on player frame
        if DF.UpdateRestedIndicator then
            DF:UpdateRestedIndicator()
        end
    end
end

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    return DF._MainEventDispatcher(self, event, arg1)
end)

-- ============================================================
-- UPDATE ALL
-- ============================================================

function DF:UpdateAll()
    if InCombatLockdown() then
        DF.needsUpdate = true
        return
    end
    
    DF:SyncLinkedSections()

    -- Invalidate aura layout so all frames re-apply layout on next aura update
    DF:InvalidateAuraLayout()
    
    DF:Debug("GUI", ">>> UpdateAll() <<<")
    
    -- Update color curves for gradient mode
    if DF.UpdateColorCurve then
        DF:UpdateColorCurve()
    end
    
    -- Check which mode we're editing in the GUI
    local editingRaid = DF.GUI and DF.GUI.SelectedMode == "raid"
    
    -- Update frames based on what's active
    if DF.raidTestMode then
        -- In raid test mode, update raid frames
        if DF.UpdateRaidTestFrames then
            DF:UpdateRaidTestFrames()
        end
        -- Update targeted spell test icons
        if DF.UpdateAllTestTargetedSpell then
            DF:UpdateAllTestTargetedSpell()
        end
    elseif DF.testMode then
        -- In party test mode, update party frames
        if DF.UpdateAllFrames then
            DF:UpdateAllFrames()
        end
        if DF.RefreshTestFrames then
            DF:RefreshTestFrames()
        end
        -- Update targeted spell test icons
        if DF.UpdateAllTestTargetedSpell then
            DF:UpdateAllTestTargetedSpell()
        end
    elseif editingRaid then
        -- Editing raid settings (not in test mode), update raid layout
        if DF.UpdateRaidLayout then
            DF:UpdateRaidLayout()
        end
    elseif IsInRaid() and not (DF.IsInArena and DF:IsInArena()) then
        -- In a live raid: update raid layout AND header visibility
        -- (UpdateHeaderVisibility may also fire from Headers.lua's REGEN handler
        -- via pendingVisibilityUpdate — that's harmless, the call is idempotent)
        if DF.UpdateRaidLayout then
            DF:UpdateRaidLayout()
        end
        if DF.UpdateHeaderVisibility then
            DF:UpdateHeaderVisibility()
        end
    else
        -- Default: update party frames
        if DF.UpdateAllFrames then
            DF:UpdateAllFrames()
        end
        -- Update rested indicator
        if DF.UpdateRestedIndicator then
            DF:UpdateRestedIndicator()
        end
    end
    
    -- FIX 2025-01-20: Refresh private aura anchors (boss debuffs) when settings change
    -- This is needed for profile switches where overlay size may have changed
end

-- ============================================================
-- FULL PROFILE REFRESH
-- Called when profiles are created, imported, reset, or switched
-- Updates BOTH party and raid frames regardless of current mode
-- ============================================================

function DF:FullProfileRefresh()
    if InCombatLockdown() then
        DF.needsUpdate = true
        return
    end
    
    -- Get both databases
    local partyDB = DF.db and DF.db.party or DF:GetDB()
    local raidDB = DF.db and DF.db.raid or DF:GetRaidDB()

    -- === MIGRATE IMPORTED/SWITCHED PROFILE SETTINGS ===
    -- Handle old resourceBarHealerOnly for imported profiles
    if partyDB and partyDB.resourceBarHealerOnly ~= nil then
        if partyDB.resourceBarHealerOnly then
            partyDB.resourceBarShowHealer = true
            partyDB.resourceBarShowTank = false
            partyDB.resourceBarShowDPS = false
        else
            partyDB.resourceBarShowHealer = true
            partyDB.resourceBarShowTank = true
            partyDB.resourceBarShowDPS = true
        end
        partyDB.resourceBarHealerOnly = nil
    end
    if raidDB and raidDB.resourceBarHealerOnly ~= nil then
        if raidDB.resourceBarHealerOnly then
            raidDB.resourceBarShowHealer = true
            raidDB.resourceBarShowTank = false
            raidDB.resourceBarShowDPS = false
        else
            raidDB.resourceBarShowHealer = true
            raidDB.resourceBarShowTank = true
            raidDB.resourceBarShowDPS = true
        end
        raidDB.resourceBarHealerOnly = nil
    end

    -- === CLEAR CACHES ===
    -- Invalidate aura layout (settings may have changed)
    DF:InvalidateAuraLayout()

    -- Rebuild aura filter strings from the new profile's settings
    if DF.RebuildDirectFilterStrings then
        DF:RebuildDirectFilterStrings()
    end

    -- Clear color curves (colors may have changed)
    if DF.UpdateColorCurve then
        DF:UpdateColorCurve()
    end

    -- Clear category lookup cache (for export/import)
    DF._categoryLookup = nil
    
    -- === UPDATE PARTY CONTAINER POSITION AND SIZE ===
    if DF.container then
        local scale = partyDB.frameScale or 1.0
        DF.container:SetScale(scale)
        DF.container:ClearAllPoints()
        DF.container:SetPoint("CENTER", UIParent, "CENTER", (partyDB.anchorX or 0) / scale, (partyDB.anchorY or 0) / scale)

        -- Recalculate container size for new profile's frame dimensions/orientation
        -- (mirrors SetPartyOrientation in Headers.lua)
        local fw = partyDB.frameWidth or 120
        local fh = partyDB.frameHeight or 50
        local sp = partyDB.frameSpacing or 2
        local maxCount = 5
        if partyDB.growDirection == "HORIZONTAL" then
            DF.container:SetSize(maxCount * (fw + sp) - sp, fh)
        else
            DF.container:SetSize(fw, maxCount * (fh + sp) - sp)
        end
    end

    -- === UPDATE RAID CONTAINER POSITION ===
    -- Use UpdateRaidContainerPosition so raidMoverFrame and testRaidContainer
    -- are synced in the same call (and CENTER-anchor compensation is applied).
    -- Falls back to direct SetPoint if the function isn't loaded yet.
    if DF.raidContainer then
        local scale = raidDB.frameScale or 1.0
        DF:Debug("RAIDPOS", "FullProfileRefresh: applying raid container pos (%.1f,%.1f) scale=%.3f autoActive=%s",
            raidDB.raidAnchorX or 0, raidDB.raidAnchorY or 0, scale,
            tostring(DF.AutoProfilesUI and DF.AutoProfilesUI.activeRuntimeProfile and DF.AutoProfilesUI.activeRuntimeProfile.name or "none"))
        if DF.UpdateRaidContainerPosition and not InCombatLockdown() then
            DF:UpdateRaidContainerPosition()
        else
            -- Combat fallback: move only the secure container (mover/test container
            -- can't be modified in combat anyway)
            DF.raidContainer:SetScale(scale)
            DF.raidContainer:ClearAllPoints()
            DF.raidContainer:SetPoint("CENTER", UIParent, "CENTER", (raidDB.raidAnchorX or 0) / scale, (raidDB.raidAnchorY or 0) / scale)
        end
    end
    
    -- === FORCE UPDATE INDIVIDUAL FRAMES VIA ITERATORS ===
    if DF.ApplyFrameStyle then
        -- Party frames via iterator
        if DF.IteratePartyFrames then
            DF:IteratePartyFrames(function(frame)
                DF:ApplyFrameStyle(frame)
            end)
        end
        
        -- Raid frames via iterator
        if DF.IterateRaidFrames then
            DF:IterateRaidFrames(function(frame)
                DF:ApplyFrameStyle(frame)
            end)
        end
        
        -- Pinned frames
        if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.headers then
            for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
                local header = DF.PinnedFrames.headers[setIndex]
                if header then
                    for i = 1, 40 do
                        local child = header:GetAttribute("child" .. i)
                        if child then
                            DF:ApplyFrameStyle(child)
                        end
                    end
                end
            end
        end
    end
    
    -- === RECONFIGURE HEADER ORIENTATION ===
    -- Must be called before layout updates so headers use the new profile's
    -- growDirection, growthAnchor, and selfPosition settings
    if DF.ApplyHeaderSettings then
        DF:ApplyHeaderSettings()
    end

    -- === UPDATE LAYOUTS ===
    -- Update party layout (this handles positioning, visibility, etc.)
    if DF.UpdateAllFrames then
        DF:UpdateAllFrames()
    end
    
    -- Update raid layout
    if DF.UpdateRaidLayout then
        DF:UpdateRaidLayout()
    end

    -- Re-apply Aura Designer indicators from the new profile: re-syncs the
    -- factory containers (sig-gated, so only what actually changed rebuilds).
    -- Safe here — FullProfileRefresh already bailed out above if in combat.
    if DF.AuraDesigner and DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
    end

    -- === REFRESH FLATRAIDFRAMES IF ACTIVE ===
    if DF.FlatRaidFrames then
        if DF.FlatRaidFrames.initialized then
            local raidDb = DF:GetRaidDB()
            if not raidDb.raidUseGroups then
                DF.FlatRaidFrames:ApplyLayoutSettings()
                DF.FlatRaidFrames:ResizeInnerContainer()
            end
        end
    end
    
    -- === REFRESH PINNED FRAMES IF ACTIVE ===
    if DF.PinnedFrames and DF.PinnedFrames.initialized then
        -- Reap sets the NEW profile no longer defines. Profile switching does
        -- NOT rebuild pinned frames (this function refreshes headers in place),
        -- so switching from a profile with more sets to one with fewer leaves
        -- the extra containers/movers live but untracked, and every hide path
        -- gates on the current profile's GetSetDB — so nothing removes them
        -- (the "stuck pinned box that survives everything" reports). Prune them
        -- before refreshing the survivors.
        if DF.PinnedFrames.PruneOrphanedSets then
            DF.PinnedFrames:PruneOrphanedSets()
        end
        -- Sync each set's visibility to the NEW profile FIRST — hide sets it
        -- disables, show/create sets it enables — so a set shown under the
        -- previous profile doesn't linger in a stale state after the switch.
        if DF.PinnedFrames.RefreshEnabledState then
            DF.PinnedFrames:RefreshEnabledState()
        end
        for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
            if DF.PinnedFrames.headers[setIndex] then
                DF.PinnedFrames:ApplyLayoutSettings(setIndex)
                DF.PinnedFrames:ResizeContainer(setIndex)
                DF.PinnedFrames:UpdateLabel(setIndex)
            end
        end
    end
    
    -- === SYNC HEADER VISIBILITY ===
    -- Replaces the previous UpdateLiveRaidFrames call. Auto profiles may change
    -- raidUseGroups, which requires toggling between flat and grouped headers.
    -- UpdateHeaderVisibility handles the full party/raid/arena visibility matrix
    -- and calls UpdateRaidHeaderVisibility internally.
    if DF.UpdateHeaderVisibility then
        DF:UpdateHeaderVisibility()
    end

    -- === POST-SWITCH LAYOUT SETTLE ===
    -- After a profile switch the headers are shown/hidden correctly, but their
    -- sorting attributes (groupFilter, nameList, sortMethod) may reflect the old
    -- profile. ApplyRaidGroupSorting rebuilds them from the new profile's settings.
    -- The deferred TriggerRaidPosition fires after SecureGroupHeaderTemplate has
    -- finished processing all attribute changes, giving a clean final reposition.
    local raidDbSettle = DF:GetRaidDB()
    if IsInRaid() or DF.raidTestMode then
        if raidDbSettle and raidDbSettle.raidUseGroups then
            if DF.ApplyRaidGroupSorting then
                DF:ApplyRaidGroupSorting()
            end
            C_Timer.After(0, function()
                if not InCombatLockdown() and DF.TriggerRaidPosition then
                    DF:TriggerRaidPosition()
                end
            end)
        elseif DF.FlatRaidFrames and DF.FlatRaidFrames.initialized then
            C_Timer.After(0, function()
                if not InCombatLockdown() then
                    DF.FlatRaidFrames:UpdateNameList()
                end
            end)
        end
    end

    -- === UPDATE TEST FRAMES IF ACTIVE ===
    -- Use full layout refresh so test frames re-read all settings through the
    -- proxy — picks up runtime auto-layout overrides or restored base values.
    if (DF.testMode or DF.raidTestMode) and DF.RefreshTestFramesWithLayout then
        DF:RefreshTestFramesWithLayout()
    elseif DF.testMode and DF.RefreshTestFrames then
        DF:RefreshTestFrames()
    elseif DF.raidTestMode and DF.UpdateRaidTestFrames then
        DF:UpdateRaidTestFrames()
    end
    
    -- === UPDATE PET FRAMES ===
    if DF.UpdateAllPetFrames then
        DF:UpdateAllPetFrames(true)  -- force: profile refresh
    end
    if DF.UpdateAllRaidPetFrames then
        DF:UpdateAllRaidPetFrames(true)  -- force: profile refresh
    end
    
    -- === REFRESH ELEMENT APPEARANCES (colors, alpha, etc.) ===
    if DF.UpdateAllFrameAppearances then
        DF:UpdateAllFrameAppearances()
    end
    
    -- === REFRESH AURAS ===
    if DF.UpdateAllAuras then
        DF:UpdateAllAuras()
    end
    
    -- === REFRESH PRIVATE AURAS ===
    
    -- === UPDATE RESTED INDICATOR ===
    if DF.UpdateRestedIndicator then
        DF:UpdateRestedIndicator()
    end
    
    -- === REFRESH NAME TRUNCATION ===
    -- UpdateAllFrames only pushes attribute changes; name truncation requires
    -- a full visible-frame pass to recalculate text widths.
    if DF.RefreshAllVisibleFrames then
        DF:RefreshAllVisibleFrames()
    end

    -- === UPDATE MINIMAP BUTTON ===
    if DF.UpdateMinimapButton then
        DF:UpdateMinimapButton()
    end

    -- === CLEAR GLOBAL FONT TEMP ===
    -- Force the Global Fonts page to re-read current DB values on next visit,
    -- so its dropdowns reflect any settings reset since the last page build.
    DF.GlobalFontTemp = nil

    -- === REFRESH GUI IF OPEN ===
    -- Invalidate all page caches first so each page rebuilds with the new
    -- profile's db reference rather than reusing stale captured closures.
    if DF.GUI and DF.GUI.InvalidateAllPages then
        DF.GUI:InvalidateAllPages()
    end
    if DF.GUIFrame and DF.GUIFrame:IsShown() then
        -- Re-sync sidebar category expand/collapse state to the new profile
        -- (categories read their state only at creation, so this is needed to
        -- reflect the switch without a /reload).
        if DF.GUI and DF.GUI.RefreshCategoryStates then
            DF.GUI:RefreshCategoryStates()
        end
        if DF.GUI and DF.GUI.RefreshCurrentPage then
            DF.GUI:RefreshCurrentPage()
        end
    end
end

-- (Removed) WIZARD SETTINGS APPLICATION — DF:ApplyWizardSettingsMap and its
-- orphaned local strsplit. It applied a wizard's settingsMap to the DB, was
-- called only from the popup wizard's CompleteWizard, and went with that runtime.
-- ============================================================
-- MINIMAP BUTTON (using LibDBIcon)
-- ============================================================

local LibDBIcon = LibStub("LibDBIcon-1.0", true)
local minimapButtonRegistered = false

-- LibDataBroker data object for the minimap button
local LDB = LibStub("LibDataBroker-1.1"):NewDataObject("DandersFrames", {
    type = "launcher",
    text = "DandersFrames",
    icon = "Interface\\AddOns\\DandersFrames\\Media\\DF_Icon",
    OnClick = function(self, button)
        if button == "LeftButton" then
            DF:ToggleGUI()
        elseif button == "RightButton" then
            -- Quick toggle solo mode
            local db = DF:GetDB()
            if db.soloMode ~= nil then
                db.soloMode = not db.soloMode
                DF:UpdateAllFrames()
                DF:Say(format(L["Solo mode %s"], db.soloMode and L["enabled"] or L["disabled"]))
            end
        end
    end,
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("DandersFrames")
        tooltip:AddLine("|cffffffffLeft-Click:|r Open settings", 0.8, 0.8, 0.8)
        tooltip:AddLine("|cffffffffRight-Click:|r Toggle solo mode", 0.8, 0.8, 0.8)
    end,
})

-- ============================================================
-- ADDON COMPARTMENT
-- Registers DandersFrames in Blizzard's addon compartment button
-- ============================================================

local addonCompartmentRegistered = false

function DF:CreateAddonCompartment()
    if addonCompartmentRegistered then return end
    if not AddonCompartmentFrame then return end

    AddonCompartmentFrame:RegisterAddon({
        text = "DandersFrames",
        icon = "Interface\\AddOns\\DandersFrames\\Media\\DF_Icon",
        registerForAnyClick = true,
        notCheckable = true,
        func = function(button, menuInputData, menu)
            if menuInputData.buttonName == "LeftButton" then
                DF:ToggleGUI()
            elseif menuInputData.buttonName == "RightButton" then
                local db = DF:GetDB()
                if db.soloMode ~= nil then
                    db.soloMode = not db.soloMode
                    DF:UpdateAllFrames()
                    DF:Say(format(L["Solo mode %s"], db.soloMode and L["enabled"] or L["disabled"]))
                end
            end
        end,
        funcOnEnter = function(button)
            -- 12.0.7 deprecates MenuUtil.ShowTooltip/HideTooltip in favour of
            -- the *Ex variants taking an explicit tooltip (the old ones only
            -- survive behind the loadDeprecationFallbacks CVar). Feature-detect
            -- so both 12.0.5 and 12.0.7 work.
            local fill = function(tooltip)
                tooltip:AddLine("DandersFrames")
                tooltip:AddLine("|cffffffffLeft-Click:|r Open settings", 0.8, 0.8, 0.8)
                tooltip:AddLine("|cffffffffRight-Click:|r Toggle solo mode", 0.8, 0.8, 0.8)
            end
            if MenuUtil.ShowTooltipEx then
                MenuUtil.ShowTooltipEx(button, GetAppropriateTooltip(), fill)
            else
                MenuUtil.ShowTooltip(button, fill)
            end
        end,
        funcOnLeave = function(button)
            if MenuUtil.HideTooltipEx then
                MenuUtil.HideTooltipEx(button, GetAppropriateTooltip())
            else
                MenuUtil.HideTooltip(button)
            end
        end,
    })

    addonCompartmentRegistered = true
end

function DF:CreateMinimapButton()
    if minimapButtonRegistered then return end
    if not LibDBIcon then return end
    
    local db = DF:GetDB()
    
    -- Initialize minimap button saved variables if needed
    if not db.minimapIcon then
        db.minimapIcon = {
            hide = false,
            minimapPos = 220,
        }
    end
    
    LibDBIcon:Register("DandersFrames", LDB, db.minimapIcon)
    minimapButtonRegistered = true
end

function DF:UpdateMinimapButton()
    local db = DF:GetDB()
    
    if not LibDBIcon then return end
    
    -- Ensure minimap button is created
    if not minimapButtonRegistered then
        DF:CreateMinimapButton()
    end
    
    if db.showMinimapButton then
        if db.minimapIcon then
            db.minimapIcon.hide = false
        end
        LibDBIcon:Show("DandersFrames")
    else
        if db.minimapIcon then
            db.minimapIcon.hide = true
        end
        LibDBIcon:Hide("DandersFrames")
    end
end

-- ========================================
-- Hide/Show Default Player Frame
-- ========================================
function DF:UpdateDefaultPlayerFrame()
    local db = DF:GetDB()
    if not db then return end
    
    -- Hide default player frame when the option is checked (independent of solo mode)
    local shouldHide = db.hideDefaultPlayerFrame
    
    if shouldHide then
        -- Hide the default player frame using the standard method
        if PlayerFrame and not InCombatLockdown() then
            PlayerFrame:Hide()
            DF.playerFrameHiddenByUs = true  -- Track that WE hid it
            -- Use a hook to keep it hidden
            if not DF.playerFrameHooked then
                hooksecurefunc(PlayerFrame, "Show", function(self)
                    local db = DF:GetDB()
                    if db and db.hideDefaultPlayerFrame then
                        if not InCombatLockdown() then
                            self:Hide()
                        end
                    end
                end)
                DF.playerFrameHooked = true
            end
        end
    else
        -- Only show the player frame if WE previously hid it
        -- Avoids unnecessarily triggering Blizzard's PetFrame update code
        -- which has bugs with secret values during MC scenarios
        if DF.playerFrameHiddenByUs and PlayerFrame and not InCombatLockdown() then
            PlayerFrame:Show()
            DF.playerFrameHiddenByUs = false
        end
    end
end

-- Initialize minimap button and addon compartment after PLAYER_LOGIN
C_Timer.After(1, function()
    local db = DF:GetDB()
    if db and db.showMinimapButton then
        DF:CreateMinimapButton()
    end
    DF:CreateAddonCompartment()
end)

-- ============================================================
-- PUBLIC API FOR OTHER ADDONS
-- ============================================================

DandersFrames.Api = DandersFrames.Api or {}

-- Get the frame currently displaying a specific unit
-- unit: e.g. "player", "party1", "party2", "raid1", "raid15", etc.
-- kind: "party" or "raid"
-- Note: "player" in kind == "party" refers to the player in the party frame, not a separate player frame
-- Returns the frame object or nil if not found
function DandersFrames.Api.GetFrameForUnit(unit, kind)
    if not unit then return nil end
    
    local foundFrame = nil
    
    if kind == "party" then
        -- Search party frames (player + party1-4) via iterator
        if DF.IteratePartyFrames then
            DF:IteratePartyFrames(function(frame)
                if frame.unit == unit then
                    foundFrame = frame
                end
            end)
        end
    elseif kind == "raid" then
        -- Search raid frames via iterator
        if DF.IterateRaidFrames then
            DF:IterateRaidFrames(function(frame)
                if frame.unit == unit then
                    foundFrame = frame
                end
            end)
        end
    end
    
    return foundFrame
end
