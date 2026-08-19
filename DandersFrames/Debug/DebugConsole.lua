local addonName, DF = ...

-- ============================================================
-- DEBUG CONSOLE
-- Persistent debug logging system with settings UI integration
-- Provides DF:Debug(), DF:DebugWarn(), DF:DebugError() API
-- Logs persist in SavedVariables across /rl
-- ============================================================

local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tinsert, wipe = table.insert, wipe
local format = string.format
local date, time = date, time

local DebugConsole = {}
DF.DebugConsole = DebugConsole

-- ============================================================
-- CONSTANTS
-- ============================================================

local SEVERITY = {
    INFO  = { level = 1, label = "INFO",  color = "|cff88ccff" },  -- Light blue
    WARN  = { level = 2, label = "WARN",  color = "|cffffff66" },  -- Yellow
    ERROR = { level = 3, label = "ERROR", color = "|cffff6666" },  -- Red
}

-- (Removed) SEVERITY_ORDER — never read. RefreshDisplay and GetExportText compare
-- SEVERITY[x].level numerically rather than walking an ordered list.

-- ============================================================
-- DECLARED CATEGORY REGISTRY
-- All categories used by DF:Debug calls anywhere in the addon are
-- declared here so the Debug Console can show them BEFORE any logs
-- exist. The user can pre-disable noisy categories before triggering
-- the bug they're trying to capture, ensuring the relevant trace
-- never gets evicted by the maxLines cap.
--
-- New categories that aren't in this registry are still auto-
-- discovered the first time they log, and appear under "Other".
-- Order within each group is preserved as written.
-- ============================================================

local CATEGORY_GROUPS = {
    {
        name = "Frames & Layout",
        categories = {
            { key = "ROSTER",     desc = "Group composition changes, throttling, sorting decisions" },
            { key = "RAIDPOS",    desc = "Raid container position writes (jumping/stuck-position bug)" },
            { key = "POSITION",   desc = "Secure position handler trigger and snippet runs" },
            { key = "LAYOUT",     desc = "Frame size, spacing, growth direction, container resize" },
            { key = "HEADERS",    desc = "Secure header creation, attributes and re-anchoring" },
            { key = "VISIBILITY", desc = "Header show/hide and state-driver changes" },
            { key = "HEALTH",     desc = "Health bar value writes, including Reduced Max Health" },
            { key = "FLATRAID",   desc = "Flat raid layout and sorting", noisy = true },
            { key = "FRAMESORT",  desc = "FrameSort addon integration" },
            { key = "SECURESORT", desc = "Spec cache, inspect queue and the raid geometry calculators", noisy = true },
            -- noisy: driven by UNIT_IN_RANGE_UPDATE per unit, and fans out to pinned
            -- and boss frames — a moving raid produces a steady stream.
            { key = "RANGE",      desc = "Range fading checks and cache decisions", noisy = true },
            { key = "PINNED",     desc = "Pinned frames init, layout changes, boss handler, test mode" },
        },
    },
    {
        name = "Profiles",
        categories = {
            { key = "PROFILE",     desc = "Profile load, save, switch, full refresh" },
            { key = "AUTOPROFILE", desc = "Auto-profile evaluation and runtime overlay" },
        },
    },
    {
        name = "Auras",
        categories = {
            { key = "AD",            desc = "Aura Designer (incl. sounds)" },
            { key = "DISPEL",        desc = "Dispel overlay binds and colour resolution" },
            -- The DECISION layer above the container: which of Rebuild / ApplyTuning
            -- / ApplyStyle a settings change resolved to, and why. Edge-triggered
            -- only — the drivers run per UNIT_AURA, so anything per-call is a
            -- firehose. Replaces BLIZAURA, which was declared but never logged.
            { key = "AURAROW",       desc = "Aura row drivers: rebuild vs tuning vs style, retargets" },
            { key = "AURACONTAINER", desc = "12.1 AuraContainer factory (build, filters, capability gate)" },
            -- The identity gate's own lane, split out of AURACONTAINER so a tester
            -- chasing "auras vanished" can enable JUST the verdict trail: park/hide
            -- flips with the probe that broke trust, latches, recovery re-parses.
            -- Edge-triggered only, so it is quiet outside actual gate activity.
            { key = "IDGATE",        desc = "Identity gate: park/hide verdicts with reasons, latches, recovery" },
            -- ⚠ Was EMITTED BUT NOT REGISTERED, which defeats the point of this table:
            -- both of its sites are DebugWarn -- custom-filter import skipping an
            -- entry, and a scrub that could not reach ParseADFilterRef -- i.e. exactly
            -- the lines someone is trying to catch, and they only appeared under
            -- "Other" AFTER they had already fired.
            { key = "FILTER",        desc = "Filter registry: custom filter import, scrub and reference rewrites" },
        },
    },
    {
        name = "Other",
        categories = {
            { key = "API",          desc = "External API callback fires (OnFramesSorted, etc.)" },
            { key = "CLICK",        desc = "Click-casting binding apply, hover, PreClick state" },
            { key = "PET",          desc = "Pet frame lifecycle and visibility" },
            { key = "POPUP",        desc = "Popup and dialog config errors" },
            { key = "ROLE",         desc = "Role icon show/hide decisions and combat transitions" },
            { key = "SCRIPT",       desc = "Lua script errors and pcall failures" },
            { key = "SYSTEM",       desc = "Reload separators and init confirmation" },
            { key = "TARGETEDLIST", desc = "Targeted List cast pickup + why a cast was dropped, stop, interrupter lookup" },
            { key = "PERSONALTARGET", desc = "Personal Targeted Spells: cast pickup, target changes, and why a cast was skipped" },
            { key = "GUI",          desc = "Settings window internals — slider drag paths, relayout" },
            -- ⚠ Also previously emitted without being registered here: its one site is
            -- a DebugWarn for a breadcrumb that cannot navigate.
            { key = "SEARCH",       desc = "Settings search: breadcrumb resolution and navigation failures" },
            -- Kept out of GUI: the Blizzard-picker sync fires on every colour
            -- drag, so folding it in would make the whole GUI category noisy.
            { key = "COLORPICKER",  desc = "Colour picker handover to/from Blizzard's picker", noisy = true },
            -- noisy: emits per text ELEMENT per frame per render, and renders are
            -- driven from DF:UpdateHealthFast — i.e. per unit per health tick in combat.
            { key = "TD",           desc = "Text Designer render and mirror state", noisy = true },
            { key = "TEXTURE",      desc = "Texture and atlas resolution, including missing-file fallback" },
        },
    },
}

-- ============================================================
-- NOISY CATEGORIES — off unless the user asks for them
-- ============================================================
-- A category marked `noisy = true` above starts DISABLED. These emit per-frame
-- inside layout and sort loops, so a 40-player roster event can produce dozens
-- of lines each; left on, they evict the very trace the user opened the console
-- to capture, well before the maxLines cap is a fair sample.
--
-- The rule for the flag: does ONE user action produce more than a handful of
-- lines? If yes it is a firehose and belongs here — turn it on deliberately
-- while reproducing a layout or sorting bug, not by default.
local function seedNoisyFilters(filters)
    for _, group in ipairs(CATEGORY_GROUPS) do
        for _, cat in ipairs(group.categories) do
            if cat.noisy and filters[cat.key] == nil then
                filters[cat.key] = false
            end
        end
    end
    return filters
end

local DEFAULTS = {
    enabled = false,
    logLevel = "INFO",
    maxLines = 10000,
    chatEcho = false,
    filters = {},  -- absent category = visible; explicit false = hidden
    -- Days a captured log survives before it is dropped at login. The log lives in
    -- SavedVariables, so a forgotten one is parsed from disk at EVERY login for as
    -- long as it exists — turning debug off does not clear it. Nobody diagnoses a
    -- bug from a week-old log, so the default expires it for them. 0 = keep forever.
    logMaxAgeDays = 7,
}
-- NOT in DEFAULTS: `logStamp = nil` in a table constructor is an absent key, so the
-- pairs() seeding loop below could never see it. debugDb.logStamp holds epoch seconds
-- of the most recent write, and exists because log ENTRIES carry only "%H:%M:%S" with
-- no date — they cannot be aged individually.

-- ============================================================
-- RUNTIME STATE
-- ============================================================

local debugDb       -- reference to DandersFramesDB_v2.debug
local debugLog      -- reference to DandersFramesDB_v2.debugLog
local knownCategories = {}  -- set: { ["PET"] = true, ["FONT"] = true, ... }
-- Rebuilt lazily. Init used to walk the whole persisted log (up to maxLines = 10000
-- entries) to fill this on EVERY login, enabled or not — pure load-time cost for a
-- table only the console UI reads. The walk now happens on first access instead.
local categoriesDirty = true
local liveEditBox         -- EditBox reference when debug tab is visible
local needsRefresh = false  -- flag to batch refresh when tab is visible

--- Reset every category to the recommended baseline: declared categories on,
--- except the ones marked `noisy`. Auto-discovered categories are cleared back
--- to visible.
---
--- This exists because the noisy seeding only ever fills in categories the user
--- has never touched — deliberately, so a considered choice survives a reload.
--- That leaves no way back to a sane baseline once you have been clicking
--- around, which is exactly when you want one: mid-investigation, log full of
--- sort spam, wanting the useful signal back without hand-unticking two dozen
--- rows.
---
--- Declared below debugDb on purpose: it closes over that local, and defining it
--- above the declaration would silently read a nil global instead.
function DebugConsole:ApplyDefaultFilters()
    if not debugDb or not debugDb.filters then return false end
    local filters = debugDb.filters
    for k in pairs(filters) do filters[k] = nil end
    for _, group in ipairs(CATEGORY_GROUPS) do
        for _, cat in ipairs(group.categories) do
            filters[cat.key] = not cat.noisy
        end
    end
    return true
end

-- ============================================================
-- INITIALIZATION
-- ============================================================

function DebugConsole:Init()
    -- Ensure debug settings table exists
    if not DandersFramesDB_v2.debug then
        DandersFramesDB_v2.debug = {}
    end

    -- Apply missing defaults (migration-safe)
    for key, value in pairs(DEFAULTS) do
        if DandersFramesDB_v2.debug[key] == nil then
            if type(value) == "table" then
                DandersFramesDB_v2.debug[key] = {}
            else
                DandersFramesDB_v2.debug[key] = value
            end
        end
    end

    -- Start the firehose categories off. Only seeds keys the user has never
    -- touched (nil), so an explicit choice either way is never overwritten —
    -- turning SECURESORT on and reloading keeps it on.
    seedNoisyFilters(DandersFramesDB_v2.debug.filters)

    -- Ensure log array exists
    if not DandersFramesDB_v2.debugLog then
        DandersFramesDB_v2.debugLog = {}
    end

    -- Set live references
    debugDb = DandersFramesDB_v2.debug
    debugLog = DandersFramesDB_v2.debugLog

    -- Drop a log that has aged out. Checked BEFORE anything else touches it so an
    -- expired log costs one comparison at login rather than a walk plus a prune.
    -- Uses debugDb.logStamp (see DEFAULTS): entries store no date of their own.
    local maxAge = debugDb.logMaxAgeDays or 0
    -- A log captured before this feature existed has no stamp. Without seeding one it
    -- would be immortal — the exact forgotten-log case this is meant to catch. Stamp
    -- it now so it ages from this login rather than being dropped unread.
    if #debugLog > 0 and not debugDb.logStamp then
        debugDb.logStamp = time()
    end
    if maxAge > 0 and #debugLog > 0 and debugDb.logStamp then
        local age = time() - debugDb.logStamp
        if age > maxAge * 86400 then
            local dropped = #debugLog
            wipe(debugLog)
            debugDb.logStamp = nil
            -- Reported only when debug is on: a user who left it off does not need
            -- to hear about a log they had forgotten, but one who is mid-investigation
            -- must not silently lose lines they were about to read.
            if debugDb.enabled then
                self:Log("INFO", "SYSTEM",
                    "Cleared %d log entries older than %d day(s)", dropped, maxAge)
            end
        end
    end

    -- Categories are rebuilt on demand, not here — see `categoriesDirty`.
    categoriesDirty = true

    -- Add reload separator if the log has prior entries AND logging is on.
    --
    -- ☠ THE `enabled` GATE IS LOAD-BEARING, not tidiness. This block is the only
    -- other writer of logStamp, and it used to run on every login regardless: a
    -- user who turned logging OFF and forgot their log would get a separator (and
    -- so a fresh stamp) at each login, which reset the age clock and made the log
    -- IMMORTAL — defeating logMaxAgeDays in precisely the case it exists for.
    -- Gating it is also right on its own terms: appending an entry to a log while
    -- logging is switched off is a write to a disabled log.
    if #debugLog > 0 and debugDb.enabled then
        tinsert(debugLog, {
            date("%H:%M:%S"),
            "INFO",
            "SYSTEM",
            "--- UI Reload ---"
        })
        -- No knownCategories write: the table is rebuilt on demand and this entry
        -- is in the log, so the rebuild picks SYSTEM up.
        debugDb.logStamp = time()
        self:PruneLog()
    end

    -- Log initialization status (confirms debug system is working)
    if debugDb.enabled then
        self:Log("INFO", "SYSTEM", "Debug Console initialized (enabled=%s, logLevel=%s, entries=%d)",
            tostring(debugDb.enabled), tostring(debugDb.logLevel), #debugLog)
    end
end

-- ============================================================
-- PUBLIC API
-- ============================================================

-- Per-category logging gate. An explicit `false` in filters disables the
-- category at the source so it never enters the log buffer — preventing
-- noise categories from evicting the relevant trace under the maxLines cap.
-- Absent (nil) or `true` = log it. Auto-discovery still works because new
-- categories aren't in `filters` until the user explicitly disables them.
local function IsCategoryLogged(category)
    local filters = debugDb and debugDb.filters
    if not filters or not category then return true end
    return filters[category] ~= false
end

--- Public predicate: would a DF:Debug call for this category actually be logged?
--- Call sites only need this when building the log arguments is itself expensive
--- (a debugstack, a table walk, a string join). DF:Debug already short-circuits,
--- but its arguments are evaluated by the caller before it can — so an unguarded
--- debugstack() in a hot path costs the same whether logging is on or off.
function DF:DebugActive(category)
    if not debugDb or not debugDb.enabled then return false end
    return IsCategoryLogged(category)
end

--- Returns true if the given value is a WoW "secret" (secret-tainted) value.
--- Secret values cannot be used in table.concat or most string operations
--- without errors. We use this to sanitize log messages so a tainted value
--- can never corrupt the debug log. Gracefully no-ops on builds without the API.
--- Declared here, above its first use, because DF:MakeDebugPrinter closes over it.
local isSecretValue = _G.issecretvalue or function() return false end

--- Returns a print()-style logger bound to a category: it takes loose varargs
--- rather than a format string, joins them with spaces, and routes the result
--- to the console.
---
--- This exists because several subsystems grew a file-local `DebugPrint(...)`
--- helper gated on their own boolean, with dozens to hundreds of call sites
--- each. Repointing the helper migrates every one of those sites at once, with
--- no change at the call site. Prefer DF:Debug with a real format string for
--- new code — this is the bridge for existing vararg call sites.
---
--- Secret-tainted values cannot be passed to tostring, so they are replaced
--- with a placeholder rather than being allowed to error inside a debug path.
function DF:MakeDebugPrinter(category)
    return function(...)
        if not DF:DebugActive(category) then return end
        local n = select("#", ...)
        if n == 0 then return end
        local parts = {}
        for i = 1, n do
            local v = select(i, ...)
            parts[i] = isSecretValue(v) and "<secret>" or tostring(v)
        end
        DF:Debug(category, "%s", table.concat(parts, " "))
    end
end

function DF:Debug(category, fmt, ...)
    if not debugDb or not debugDb.enabled then return end
    if not IsCategoryLogged(category) then return end
    DebugConsole:Log("INFO", category, fmt, ...)
end

function DF:DebugWarn(category, fmt, ...)
    if not debugDb or not debugDb.enabled then return end
    if not IsCategoryLogged(category) then return end
    DebugConsole:Log("WARN", category, fmt, ...)
end

function DF:DebugError(category, fmt, ...)
    if not debugDb or not debugDb.enabled then return end
    if not IsCategoryLogged(category) then return end
    DebugConsole:Log("ERROR", category, fmt, ...)
end

-- ============================================================
-- INTERNAL LOGGING
-- ============================================================

-- Sanitizes a message string for safe storage in the log. If the string
-- itself is secret-tainted (because one of the format args was a secret),
-- returns a non-secret placeholder instead.
local function sanitizeLogMessage(msg)
    if msg == nil then return "nil" end
    if type(msg) ~= "string" then
        msg = tostring(msg)
    end
    if isSecretValue(msg) then
        return "<SECRET — log arg was a secret value>"
    end
    return msg
end

function DebugConsole:Log(level, category, fmt, ...)
    -- Format the message. If any format arg is a secret-tainted value, the
    -- resulting string inherits the taint and cannot be safely concatenated
    -- later. sanitizeLogMessage replaces tainted messages with a placeholder.
    local msg
    if select("#", ...) > 0 then
        local ok, result = pcall(format, fmt, ...)
        msg = ok and result or (tostring(fmt) .. " [format error]")
    else
        msg = tostring(fmt)
    end
    msg = sanitizeLogMessage(msg)

    -- Create entry: {timestamp, level, category, message}
    local entry = {
        date("%H:%M:%S"),
        level,
        category or "GENERAL",
        msg,
    }

    tinsert(debugLog, entry)

    -- Age is measured from the last write, not the first: a log you are still
    -- filling is a log you are still using. One integer store per line.
    if debugDb then debugDb.logStamp = time() end

    -- Track new categories
    local cat = entry[3]
    if not knownCategories[cat] then
        knownCategories[cat] = true
        -- New category discovered — if filters table doesn't have it, it defaults to visible
    end

    -- Prune if over limit
    self:PruneLog()

    -- Echo to chat if enabled
    if debugDb.chatEcho then
        local sev = SEVERITY[level] or SEVERITY.INFO
        print(format("%s[DF %s]|r [%s] %s", sev.color, sev.label, cat, msg))
    end

    -- Flag refresh for live display
    if liveEditBox then
        needsRefresh = true
        -- Defer refresh to avoid spam during rapid logging
        if not self.refreshTimer then
            self.refreshTimer = C_Timer.NewTimer(0.05, function()
                self.refreshTimer = nil
                if needsRefresh and liveEditBox then
                    self:RefreshDisplay()
                end
            end)
        end
    end
end

-- ============================================================
-- LOG MANAGEMENT
-- ============================================================

-- How far the buffer may run over the cap before a compaction. Pruning on every
-- single Log() meant a table.remove per line once full, and each table.remove
-- shifts the whole array; the scan for the oldest INFO also had to walk past
-- every leading WARN/ERROR first. Both costs peak when the buffer is mostly
-- failures — exactly when the log is being relied on. Letting it overshoot and
-- compacting once turns that into a single pass per PRUNE_OVERSHOOT lines.
local PRUNE_OVERSHOOT = 500

function DebugConsole:PruneLog()
    if not debugLog or not debugDb then return end
    local maxLines = debugDb.maxLines or 500
    if #debugLog <= maxLines + PRUNE_OVERSHOOT then return end

    local total = #debugLog
    local excess = total - maxLines

    -- Level-aware eviction. The old policy removed the oldest entry regardless
    -- of level, so a flood of routine INFO (per-hover OnEnter/OnLeave during a
    -- raid) would bury and then EVICT the rare WARN/ERROR entries that actually
    -- diagnose a problem — the failure was gone by the time the log was read.
    --
    -- Oldest INFO goes first, and WARN/ERROR are not touched while any INFO
    -- remains. That is a deliberate call: a buffer full of warnings and errors
    -- is the useful kind, and INFO is largely noise the log fills with anyway.
    -- If the buffer genuinely is all WARN/ERROR and still over cap, the oldest
    -- of those go, so this degrades to FIFO rather than wedging.
    local drop, remaining = {}, excess
    for i = 1, total do
        if remaining == 0 then break end
        if debugLog[i][2] == "INFO" then
            drop[i] = true
            remaining = remaining - 1
        end
    end
    if remaining > 0 then
        for i = 1, total do
            if remaining == 0 then break end
            if not drop[i] then
                drop[i] = true
                remaining = remaining - 1
            end
        end
    end

    -- Compact in one pass rather than shifting the array once per removal.
    local write = 1
    for read = 1, total do
        if not drop[read] then
            debugLog[write] = debugLog[read]
            write = write + 1
        end
    end
    for i = total, write, -1 do
        debugLog[i] = nil
    end
end

function DebugConsole:ClearLog()
    if debugLog then
        wipe(debugLog)
    end
    if debugDb then debugDb.logStamp = nil end
    wipe(knownCategories)
    categoriesDirty = false   -- nothing to rebuild FROM; an empty set is correct
    if liveEditBox then
        self:RefreshDisplay()
    end
end

function DebugConsole:SetEnabled(enabled)
    if debugDb then
        debugDb.enabled = enabled
    end
    -- No DF.debugEnabled mirror: it was write-only (see the note in Core.lua).
    -- DF:DebugActive(cat) is the question consumers actually ask — 50 call sites.
    -- (Removed) DebugConsole:IsEnabled(), a `debugDb.enabled` accessor that read
    -- like the master switch but had zero callers. Restore it if an external
    -- consumer ever needs the global state rather than a per-category answer.
end

-- ============================================================
-- DISPLAY RENDERING
-- ============================================================

-- ☠ THE RENDER WINDOW IS A HARD CAP, NOT A NICETY. The EditBox grows its height
-- to numLines * lineHeight below, and past a few thousand lines that height
-- exceeds what the renderer will draw — the box goes COMPLETELY blank, with the
-- "no entries match" message nowhere in sight (field report: 10k entries, every
-- large category blanked the window, tiny ones like SYSTEM rendered fine). The
-- display code was built when maxLines defaulted to 500 (+500 overshoot); when
-- the retention default was raised to 10000 the blank appeared. The ceiling is
-- the region-size limit (~32,767px — roughly 2,700 lines at this font, but the
-- font is user-scalable, which drags the true line count down). 1000 is the
-- envelope the console demonstrably ran at for months, so it stays 1000
-- (Krathe's call). Retention and rendering are different budgets: keep all
-- 10000 in the log, show the newest window, and SAY the rest are held back.
-- The export pages in chunks of this same size, losing nothing.
local MAX_RENDER_LINES = 1000

-- Shared per-entry sanitize + format. Legacy entries (logged before the
-- write-time sanitizer existed) may hold nil or secret-tainted fields which
-- would crash format(); `colored` picks the console form vs the export form.
local function FormatLogEntry(entry, colored)
    local timestamp = entry[1] or "??:??:??"
    local level     = entry[2] or "INFO"
    local category  = entry[3] or "GENERAL"
    local message   = entry[4]
    if message == nil then
        message = "<nil>"
    elseif type(message) ~= "string" then
        message = tostring(message) or "<nonstring>"
    end
    if isSecretValue(message) then
        message = "<SECRET — legacy tainted entry>"
    end
    if type(timestamp) ~= "string" or isSecretValue(timestamp) then
        timestamp = "??:??:??"
    end
    if type(category) ~= "string" or isSecretValue(category) then
        category = "GENERAL"
    end
    -- ☠ ESCAPE THE PIPES, OR THE WHOLE CONSOLE RENDERS BLANK.
    --
    -- "|" is WoW's text-escape character, and log messages are full of raw ones: aura
    -- filters are pipe-separated ("HELPFUL|PLAYER") and AD slot keys use "|" as their own
    -- field separator ("PowerInfusion#1ic|||du|bd|fl=40|fs=MEDIUM||pd=BORDER:Fnil|tt=").
    -- Concatenated into the EditBox those read as escapes: "|T" opens a texture and "|t"
    -- closes one, while "|d"/"|b"/"|f" are not escapes at all. SetText fails on the
    -- malformed result and the box goes EMPTY -- not the offending line, the entire
    -- console, because every line shares one SetText.
    --
    -- ⚠ The guards above are all about VALUE safety (nil, non-string, secret) and none of
    -- them looks at content, which is why this got through: the pcall(format,...) below
    -- succeeds -- format has no problem with pipes -- and the failure surfaces later, in
    -- DebugConsole:RefreshDisplay, far from the entry that caused it.
    --
    -- Escape the message and category ONLY. The severity colour and the |r that closes it
    -- come from the format string below, and escaping those would print the codes instead
    -- of colouring the line.
    -- ⚠ Parens required: gsub returns (string, count) and the bare call would leak the
    -- count into the surrounding expression.
    message = (message:gsub("|", "||"):gsub("[%z\1-\31]", "?"))
    category = (category:gsub("|", "||"))
    local sev = SEVERITY[level] or SEVERITY.INFO
    local ok, formatted
    if colored then
        ok, formatted = pcall(format, "%s %s[%s]|r [%s] %s",
            timestamp, sev.color or "|cffffffff", sev.label, category, message)
    else
        ok, formatted = pcall(format, "%s [%s] [%s] %s",
            timestamp, type(level) == "string" and level or "INFO", category, message)
    end
    if ok and not isSecretValue(formatted) then
        return formatted
    end
    return timestamp .. " [" .. (sev.label or "?") .. "] [" .. category .. "] <unrenderable entry>"
end

-- Walk the log NEWEST-FIRST, format only the newest `cap` matching entries, and
-- keep counting the older matches without paying for their strings. Returns the
-- lines in chronological order plus the total match count. Shared by the live
-- display and the export so the two can never disagree about filtering again.
local function CollectFilteredLines(cap, colored)
    local minLevel = SEVERITY[(debugDb and debugDb.logLevel) or "INFO"]
    if not minLevel then minLevel = SEVERITY.INFO end
    local minLevelNum = minLevel.level
    local filters = (debugDb and debugDb.filters) or {}
    local lines, matched = {}, 0
    for i = #debugLog, 1, -1 do
        local entry = debugLog[i]
        local sev = SEVERITY[entry[2]]
        if sev and sev.level >= minLevelNum then
            -- Category filter (absent = visible, explicit false = hidden); the
            -- category is sanitized to GENERAL inside FormatLogEntry, so mirror
            -- that here or a tainted category would dodge the filter check.
            local category = entry[3]
            if type(category) ~= "string" or isSecretValue(category) then
                category = "GENERAL"
            end
            if filters[category] ~= false then
                matched = matched + 1
                if #lines < cap then
                    lines[#lines + 1] = FormatLogEntry(entry, colored)
                end
            end
        end
    end
    -- Collected newest-first: reverse into chronological order.
    local n = #lines
    for i = 1, math.floor(n / 2) do
        lines[i], lines[n + 1 - i] = lines[n + 1 - i], lines[i]
    end
    return lines, matched
end

function DebugConsole:RefreshDisplay()
    needsRefresh = false
    if not liveEditBox or not debugLog then return end

    local lines, matched = CollectFilteredLines(MAX_RENDER_LINES, true)
    if matched > #lines then
        tinsert(lines, 1, format(
            "|cff666666… %d older matching lines held back (newest %d shown — Copy to Clipboard exports every part, or narrow the filters)|r",
            matched - #lines, #lines))
    end

    local text = #lines > 0 and table.concat(lines, "\n") or "|cff666666No log entries match current filters.|r"
    liveEditBox:SetText(text)

    -- Update EditBox height to fit all text (enables scroll frame scrolling)
    -- EditBox doesn't have GetStringHeight, so calculate from line count + font size
    local numLines = 1
    for _ in text:gmatch("\n") do numLines = numLines + 1 end
    local _, fontSize = liveEditBox:GetFont()
    local lineHeight = (fontSize or 10) + 2
    liveEditBox:SetHeight(math.max(390, numLines * lineHeight + 10))

    -- Auto-scroll to bottom (delay to let scroll range recalculate after height change)
    local scrollFrame = liveEditBox:GetParent()
    if scrollFrame and scrollFrame.SetVerticalScroll then
        C_Timer.After(0.02, function()
            if scrollFrame and scrollFrame.GetVerticalScrollRange then
                scrollFrame:SetVerticalScroll(scrollFrame:GetVerticalScrollRange())
            end
        end)
    end
end

function DebugConsole:SetLiveEditBox(editBox)
    liveEditBox = editBox
    if editBox then
        self:RefreshDisplay()
    end
end

-- ============================================================
-- CATEGORY ACCESS
-- ============================================================

function DebugConsole:GetKnownCategories()
    -- The deferred Init walk happens here, once, the first time anything actually
    -- needs the set — in practice when the console page is opened.
    if categoriesDirty then
        categoriesDirty = false
        wipe(knownCategories)
        if debugLog then
            for _, entry in ipairs(debugLog) do
                local cat = entry[3]
                if cat and cat ~= "" then
                    knownCategories[cat] = true
                end
            end
        end
    end
    return knownCategories
end

-- Returns the declared category groups (ordered list of {name, categories}).
-- Used by the settings UI to render checkboxes grouped by feature.
function DebugConsole:GetCategoryGroups()
    return CATEGORY_GROUPS
end

-- Returns a set of every category declared in the registry.
-- Used to figure out which auto-discovered categories should appear under
-- the dynamic "Other" group (those not already in the registry).
function DebugConsole:GetRegisteredCategorySet()
    local set = {}
    for _, group in ipairs(CATEGORY_GROUPS) do
        for _, cat in ipairs(group.categories) do
            set[cat.key] = true
        end
    end
    return set
end

function DebugConsole:GetLogEntryCount()
    return debugLog and #debugLog or 0
end

-- ============================================================
-- EXPORT
-- ============================================================

-- The export loses NOTHING: every matching line is formatted, then sliced into
-- parts of MAX_RENDER_LINES — the popup's text area is a content-sized EditBox
-- with the same region-size ceiling as the live box, so one giant string would
-- blank it, but paged parts each render fine. One part = the common case (a
-- filtered slice is almost always under the window); the caller shows a "next
-- part" button only when there are more. Same filters, same formatter, same
-- window as the display (CollectFilteredLines), so the views cannot disagree.
function DebugConsole:GetExportChunks()
    if not debugLog then return { "No debug log available." } end

    local entries = CollectFilteredLines(math.huge, false)
    local total = #entries
    local numChunks = math.max(1, math.ceil(total / MAX_RENDER_LINES))
    local chunks = {}
    for c = 1, numChunks do
        local first = (c - 1) * MAX_RENDER_LINES + 1
        local last  = math.min(total, c * MAX_RENDER_LINES)
        local result = {}
        tinsert(result, "DandersFrames Debug Log")
        tinsert(result, "Version: " .. (DF.VERSION or "unknown"))
        tinsert(result, "Exported: " .. date("%Y-%m-%d %H:%M:%S"))
        if numChunks > 1 then
            tinsert(result, ("Part %d of %d — lines %d-%d of %d matched (%d total in log)")
                :format(c, numChunks, first, last, total, #debugLog))
        else
            tinsert(result, "Entries: " .. total .. " (filtered from " .. #debugLog .. " total)")
        end
        tinsert(result, "Min Level: " .. (debugDb and debugDb.logLevel or "INFO"))
        tinsert(result, "========================================")
        tinsert(result, "")
        for i = first, last do
            result[#result + 1] = entries[i]
        end
        chunks[#chunks + 1] = table.concat(result, "\n")
    end
    return chunks
end
