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
local MAJOR, MINOR = "DandersUI-1.0", 7
local UI = LibStub:NewLibrary(MAJOR, MINOR)
if not UI then return end
-- The handshake the other four files read. `NS` is the HOST addon's private
-- table when embedded, so the key is namespaced to avoid colliding with the
-- host's own fields.
NS.__DandersUI = UI

local setmetatable, rawget, type, error, ipairs, print = setmetatable, rawget, type, error, ipairs, print
local tinsert, xpcall, geterrorhandler, tostring = table.insert, xpcall, geterrorhandler, tostring

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
--   interceptWrite(db, key, value) -> true when the write was redirected (skip refresh)
--   onSettingWritten(db, key, value)         after a plain write landed
--   refresh()                                throttled live refresh
--   refreshNow()                             unthrottled live refresh
--   onDragStart(lightFn, name, previewMode) / onDragStop() / isDragging() -> bool
--   registerSearch(kind, label, key, widget, meta)
--   onIndicatorsRefreshed()                  after a RefreshAllOverrideIndicators sweep
--   onPopupOpen()                            before a popup takes the singleton frame
--   pickerStore() -> store                   persistent colour-picker memory: a table with
--        fields saved (array), recent (array), square (boolean|nil); absent = session-only
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
-- ============================================================
function UI:SetAccent(r, g, b)
    local a = rawget(self, "accent")
    if not a then error("DandersUI: SetAccent must be called on a host, not on the library", 2) end
    if type(r) == "table" then r, g, b = r.r or r[1], r.g or r[2], r.b or r[3] end
    if not (r and g and b) then return end
    if a.r == r and a.g == g and a.b == b then return end
    a.r, a.g, a.b = r, g, b
    for _, fn in ipairs(self.accentListeners) do
        xpcall(fn, geterrorhandler(), a)
    end
end

function UI:GetAccent()
    return rawget(self, "accent") or DEFAULT_ACCENT
end

function UI:RegisterAccentListener(fn)
    if type(fn) ~= "function" then return end
    local list = rawget(self, "accentListeners")
    if not list then error("DandersUI: RegisterAccentListener must be called on a host", 2) end
    tinsert(list, fn)
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

function UI:Call(name, ...)
    local fn = self:Hook(name)
    if not fn then return nil end
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
