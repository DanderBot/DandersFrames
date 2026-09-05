local addonName, NS = ...

-- ============================================================
-- DANDERSUI-1.0
-- A shared settings-UI toolkit. Every consumer takes a HOST via NewHost and
-- calls the factories on that: `host:CreateSlider(parent, opts)`. The host's
-- metatable __index is this library table, so one function body serves every
-- consumer and reads what differs -- locale, accent, fonts, settings hooks --
-- off `self.hooks` / `self.accent`.
--
-- Nothing in this library may name a consumer. State that must be SINGULAR
-- (open menus, the popup frame, the font objects) lives here on the library,
-- never on a host.
--
-- Embedded library. Hosts include Libs\DandersUI\DandersUI.xml after LibStub.
-- Canonical source lives at <repo>/DandersUI; never edit the copies under
-- */Libs/.
-- ============================================================
-- ☠ Bumping MINOR means bumping EXPECTED_MINOR in OptionsCore.lua in the SAME
-- commit -- the options manifest compares the two for equality and goes inert on
-- a mismatch. See the README's split-loading section.
local MAJOR, MINOR = "DandersUI-1.0", 15
local UI = LibStub:NewLibrary(MAJOR, MINOR)
if not UI then return end
-- The handshake the other four files read. `NS` is the HOST addon's private
-- table when embedded, so the key is namespaced to avoid colliding with the
-- host's own fields.
NS.__DandersUI = UI

local setmetatable, rawget, type, error, ipairs, print = setmetatable, rawget, type, error, ipairs, print
local tinsert, tremove, xpcall, geterrorhandler, tostring =
      table.insert, table.remove, xpcall, geterrorhandler, tostring
local pairs, format, sort, concat = pairs, string.format, table.sort, table.concat
-- The hook counters below are the only caller, and they are the only thing in
-- this file that needs a client global. Stubbed rather than assumed so the file
-- stays loadable outside the game.
local debugprofilestop = debugprofilestop or function() return 0 end

-- Media resolves inside the EMBEDDING addon: `addonName` here is the host's
-- name, not "DandersUI", because the copy lives at <Host>\Libs\DandersUI\.
UI.MEDIA = "Interface\\AddOns\\" .. addonName .. "\\Libs\\DandersUI\\Media\\"
-- Library revision, not an addon version -- an embedded copy has no TOC of its
-- own to read a version from.
UI.MAJOR, UI.MINOR = MAJOR, MINOR
UI.VERSION = MINOR

-- ============================================================
-- SHARED STATE
-- ------------------------------------------------------------
-- _state is ONE table for the whole pack and is deliberately NOT shadowed per
-- host: it holds live mutable values (the currently open dropdown, the
-- override debug flag) that both the pack and a consumer read AND write. A
-- per-host overlay would let a consumer write shadow the value the pack keeps
-- reading -- a bug with no symptom until a menu refuses to close.
--
-- _priv is the opposite: it only ever receives function publishes, so each
-- host gets its own overlay (created in NewHost) and can publish private
-- helpers of its own without writing into the shared table.
-- ============================================================
UI._state = UI._state or {}
UI._priv  = UI._priv or {}

-- ============================================================
-- HOSTS
-- ============================================================
UI.hosts = UI.hosts or {}

local hostMeta = { __index = UI }

local DEFAULT_ACCENT = { r = 0.45, g = 0.45, b = 0.95, a = 1 }   -- the party purple-blue

-- hooks (all optional except L):
--   L                REQUIRED. Locale table; every user-facing string reads from it.
--   print(msg)                       user-visible notice          default: print
--   error(msg)                       developer error              default: geterrorhandler()
--   getFontSetting() -> name, outline                             default: client font, no outline
--   resolveFontPath(name) -> path                                 default: the name itself
--   safeSetFont(obj, name, size, flags) -> handled                default: plain SetFont
--   fontFamily(path, outline, size) -> fontObject|globalName      default: none
--   getScale() -> number             UI scale for floating chrome default: 1
--   accentFor(isRaid) -> {r,g,b}     a pinned accent pole         default: the host accent
--   getOverrideState(db, key) -> state, globalValue
--        state is "none" | "runtime" | "overridden" | "editing"; absent = no indicators
--   resetOverride(db, key) -> globalValue    also writes db[key] back to global
--   isModifiedDefault(db, key) -> bool  the STORED value differs from the value the
--        consumer ships as its default; absent = no modified-dots are ever drawn
--   interceptWrite(db, key, value) -> true when the write was redirected (skip refresh)
--   onSettingWritten(db, key, value, label, applyFn)   after a plain write landed
--        label is the widget's display name; applyFn is the widget's own commit
--        callback BY REFERENCE, so a host that replays edits (an undo stack) can
--        run the apply and not just the write. Both trailing args are optional --
--        a host that reads three is unaffected by a widget that passes five.
--   refresh()                                throttled live refresh
--   refreshNow()                             unthrottled live refresh
--   onDragStart(lightFn, name, previewMode) / onDragStop() / isDragging() -> bool
--   registerSearch(kind, label, key, widget, meta)
--   onIndicatorsRefreshed()                  after a RefreshAllOverrideIndicators sweep
--   onPopupOpen()                            before a popup takes the singleton frame
--   pickerStore() -> store                   persistent colour-picker memory: a table with
--        fields saved (array), recent (array), square (boolean|nil); absent = session-only
--   pickerTitle                              the colour picker's window title: a STRING, or a
--        function returning one (read once, when the picker frame is first built).
--        Absent = the picker carries no title text -- the library may not name a consumer
--        and has no locale key of its own to fall back on
--   debug(cat) -> printer|nil                category debug printer factory; absent = silent
--   getSettingsDB() -> db                    the settings table a page's hideOn / disableOn /
--        refreshContent predicates are evaluated against (the consumer decides what "current"
--        means -- e.g. which mode is selected); absent = those predicates never fire
--   onSectionToggled(key, expanded)          after a collapsible section toggles
--   scrollToSection(page, section) -> widget jump the settings scroll to a section; absent =
--        link-to-setting controls don't render
function UI:NewHost(name, hooks)
    if type(name) ~= "string" or name == "" then
        error("DandersUI: NewHost needs a consumer name", 2)
    end
    local existing = UI.hosts[name]
    if existing then return existing end
    if type(hooks) ~= "table" then
        error("DandersUI: NewHost(" .. name .. ") needs a hooks table", 2)
    end
    if type(hooks.L) ~= "table" then
        error("DandersUI: NewHost(" .. name .. ") requires hooks.L -- locale is mandatory", 2)
    end

    local host = setmetatable({}, hostMeta)
    host.name = name
    host.hooks = hooks
    host.accent = { r = DEFAULT_ACCENT.r, g = DEFAULT_ACCENT.g, b = DEFAULT_ACCENT.b, a = 1 }
    host.accentListeners = {}
    host._priv = setmetatable({}, { __index = UI._priv })
    UI.hosts[name] = host
    return host
end

function UI:GetHost(name) return UI.hosts[name] end

-- ============================================================
-- ACCENT
-- One colour per host. The TABLE is mutated in place rather than replaced, so
-- a caller that cached it (`local c = host:GetAccent()`) keeps seeing the live
-- value -- and so the listener list is only needed for surfaces that have to
-- REPAINT, not for ones that merely read.
--
-- ☠ THE LISTENER LIST ONLY EVER GREW. It held bare functions, and nothing could
-- take one off again -- so CreateGroupBox, which registers one closure per box
-- to re-tint its title, left another dead listener behind on every rebuild of
-- every panel that uses one, and every later SetAccent walked and called the
-- lot. It holds ENTRIES now -- { fn = <listener>, hasOwner = <bool> } -- with
-- the OWNER (the widget the listener is FOR) held in a weak-valued side table,
-- so an owner that goes away takes its entry with it on the next SetAccent.
--
-- ⚠ WoW NEVER COLLECTS A FRAME, so the weak half does not fire for a frame
-- owner and this is not on its own a cure for the growth. Naming an owner is
-- what makes the entry ADDRESSABLE: a consumer with a real teardown path calls
-- UnregisterAccentListener(owner) and the entry goes immediately, which is the
-- half that actually bounds the list. The weak table saves a plain-table owner
-- and stops the registry itself pinning anything alive.
-- ============================================================
-- entry -> owner. Weak in the VALUE, so a collected owner leaves a hole the
-- compaction below can see. Library-wide rather than per host: entries are
-- unique tables, so one map serves every host without them being able to
-- collide.
local listenerOwners = setmetatable({}, { __mode = "v" })

function UI:SetAccent(r, g, b)
    local a = rawget(self, "accent")
    if not a then error("DandersUI: SetAccent must be called on a host, not on the library", 2) end
    if type(r) == "table" then r, g, b = r.r or r[1], r.g or r[2], r.b or r[3] end
    if not (r and g and b) then return end
    if a.r == r and a.g == g and a.b == b then return end
    a.r, a.g, a.b = r, g, b

    local list = rawget(self, "accentListeners")
    if not list then return end
    -- Compact FIRST, in place, then fire. Two passes rather than one because a
    -- listener is free to register or unregister another from inside itself,
    -- and rewriting the array underneath that would drop entries silently.
    local count, n = #list, 0
    for i = 1, count do
        local e = list[i]
        if (not e.hasOwner) or listenerOwners[e] ~= nil then
            n = n + 1
            list[n] = e
        end
    end
    for i = count, n + 1, -1 do list[i] = nil end
    for i = 1, n do
        xpcall(list[i].fn, geterrorhandler(), a)
    end
end

function UI:GetAccent()
    return rawget(self, "accent") or DEFAULT_ACCENT
end

-- `owner` is optional and backwards compatible: RegisterAccentListener(fn)
-- still registers a permanent listener exactly as it always did. Pass the
-- widget the listener repaints and the entry becomes droppable -- by that
-- owner, or automatically once nothing else references it.
-- Returns the entry, which is also a valid handle for UnregisterAccentListener.
function UI:RegisterAccentListener(fn, owner)
    if type(fn) ~= "function" then return end
    local list = rawget(self, "accentListeners")
    if not list then error("DandersUI: RegisterAccentListener must be called on a host", 2) end
    local entry = { fn = fn }
    if owner ~= nil then
        entry.hasOwner = true
        listenerOwners[entry] = owner
    end
    tinsert(list, entry)
    return entry
end

-- Drop a listener early. Takes the OWNER it was registered against, the
-- listener function itself, or the entry Register handed back. Removes every
-- match, so unregistering an owner clears all of its listeners at once.
function UI:UnregisterAccentListener(what)
    if what == nil then return self end
    local list = rawget(self, "accentListeners")
    if not list then return self end
    for i = #list, 1, -1 do
        local e = list[i]
        if e == what or e.fn == what or listenerOwners[e] == what then
            listenerOwners[e] = nil
            tremove(list, i)
        end
    end
    return self
end

-- ============================================================
-- HOOK PLUMBING
-- Every optional hook is reached through one of these, so a factory never has
-- to write `self.hooks.x and self.hooks.x(...)` and a missing hook can never
-- be a nil-call.
-- ============================================================
function UI:Hook(name)
    local h = rawget(self, "hooks")
    return h and h[name] or nil
end

-- ============================================================
-- HOOK PERF COUNTERS
-- ------------------------------------------------------------
-- Every hook a factory fires goes through UI:Call, which makes this the one
-- place a consumer's settings-apply work can be COUNTED without the library
-- knowing anything about that consumer. What it answers: how many times a
-- slider drag drove `refresh`, and how much wall time went into it.
--
-- OFF by default and gated on a single rawget, so a host that never calls
-- PerfStart pays one field read per hook fired. Nothing is allocated, and no
-- timer runs, until PerfStart.
--
-- The printer comes from the `debug` hook, so the output lands wherever the
-- consumer's own debug logging goes. "PERF" is passed straight to that hook;
-- what the consumer does with the category is its own business.
-- ============================================================

-- Declared ahead of UI:Call: a local is only an upvalue for closures created
-- BELOW it, so defining this after Call would leave Call reading a nil global.
local function PerfCall(host, name, fn, ...)
    local p = host.perf
    -- A drag opens a FRESH bucket. "How many applies did that one drag cost"
    -- is the question this exists for, and a session-wide total cannot answer
    -- it. The onDragStart call itself lands in the bucket it opens, which is
    -- what makes a drag that never started visible as an absent bucket rather
    -- than as an empty one.
    if name == "onDragStart" then p.drags = {} end
    p.counts[name] = (p.counts[name] or 0) + 1
    local d = p.drags
    if d then d[name] = (d[name] or 0) + 1 end

    local t0 = debugprofilestop()
    -- Five returns, matching the wrappers elsewhere in this project: no hook in
    -- the contract above returns more than two, and going through `select` on
    -- the vararg would allocate on every hook fired while recording.
    local r1, r2, r3, r4, r5 = fn(...)
    p.ms[name] = (p.ms[name] or 0) + (debugprofilestop() - t0)

    if name == "onDragStop" then
        p.lastDrag = d
        p.drags = nil
        p.dragCount = p.dragCount + 1
    end
    return r1, r2, r3, r4, r5
end

-- Start (or restart) recording on this host. A second call starts a clean set
-- of counters rather than adding to the previous run's.
function UI:PerfStart()
    local mk = self:Hook("debug")
    local p = { counts = {}, ms = {}, dragCount = 0 }
    -- Resolved ONCE, here, rather than per call: the hook builds a closure.
    p.printer = mk and mk("PERF") or nil
    self.perf = p
    self._perfActive = true
    return p
end

-- Stop recording. The counters are kept so PerfReport still has something to
-- print afterwards.
function UI:PerfStop()
    self._perfActive = nil
    return rawget(self, "perf")
end

function UI:PerfReport()
    local p = rawget(self, "perf")
    local printer = p and p.printer
    local emit = printer or function(line) self:Print(line) end
    if not p then
        emit("DandersUI perf: nothing recorded -- call PerfStart first.")
        return
    end

    local rows, totalCalls, totalMs = {}, 0, 0
    for name, n in pairs(p.counts) do
        local ms = p.ms[name] or 0
        rows[#rows + 1] = { name = name, calls = n, ms = ms }
        totalCalls = totalCalls + n
        totalMs = totalMs + ms
    end
    sort(rows, function(a, b) return a.ms > b.ms end)

    emit(format("DandersUI perf (%s)%s -- %d hook calls, %.1fms, %d drag(s)",
        tostring(rawget(self, "name") or "?"),
        rawget(self, "_perfActive") and " [recording]" or " [stopped]",
        totalCalls, totalMs, p.dragCount))
    for _, r in ipairs(rows) do
        emit(format("  %-20s %6d calls  %8.1fms  %7.3fms avg",
            r.name, r.calls, r.ms, r.calls > 0 and (r.ms / r.calls) or 0))
    end

    -- The applies-per-drag line. One slider drag firing `refresh` dozens of
    -- times is the shape this whole block exists to make visible.
    local last = p.lastDrag
    if last then
        local parts = {}
        for name, n in pairs(last) do parts[#parts + 1] = format("%s x%d", name, n) end
        sort(parts)
        emit("  last drag: " .. (parts[1] and concat(parts, ", ") or "(no hooks fired)"))
    else
        emit("  last drag: none recorded")
    end
end

function UI:Call(name, ...)
    local fn = self:Hook(name)
    if not fn then return nil end
    -- One rawget when off. PerfStart is what puts the flag on the host, and
    -- rawget rather than a plain read so the library table can never carry a
    -- flag that switches recording on for every host at once.
    if rawget(self, "_perfActive") then return PerfCall(self, name, fn, ...) end
    return fn(...)
end

function UI:Print(msg)
    local fn = self:Hook("print")
    if fn then return fn(msg) end
    print(tostring(msg))
end

function UI:Error(msg)
    local fn = self:Hook("error")
    if fn then return fn(msg) end
    geterrorhandler()(tostring(msg))
end
