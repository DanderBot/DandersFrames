local addonName, DF = ...

-- ============================================================
-- TEST MODE REGISTRY -- the MODES the test popup offers
-- ============================================================
-- The test popup (DandersFrames_Options/TestMode/TestMode.lua) is a rail of
-- MODES (Party, Raid, ...) over a rail of SECTIONS, with the active section's
-- settings listed beside them. Every mode -- Party and Raid included -- comes
-- through this registry, so another module, or another addon, can add its own
-- without touching the popup.
--
-- Resident on purpose: the popup is load-on-demand, but a registration must
-- work at any time, including from an addon that loads long before anyone
-- opens settings. The popup reads the registry when it builds and follows
-- every later change.
--
--   DandersFrames:RegisterTestMode(id, def)      -- (DF:RegisterTestMode inside DF)
--
-- def (every field optional except label, icon and sections):
--   label         string | fn -> string   short rail label ("Party")
--   title         string | fn             longer name: rail tooltip title
--   icon          texture path            white 32px glyph, tinted at runtime
--   order         number (100)            rail position; Party 10, Raid 20
--   accent        {r,g,b} | fn -> {r,g,b} the mode's colour (filled rail button,
--                                         section marker, switches, sliders);
--                                         the settings accent when absent
--   isAvailable   fn -> ok[, whyTitle[, whyLines]]
--                                         false greys the rail button (with the
--                                         reason as its tooltip)
--   isCurrent     fn -> bool              optional: the popup FOLLOWS this -- a
--                                         mode reporting false is left for one
--                                         reporting true (Party / Raid follow
--                                         the settings window's own mode)
--   onEnter       fn(fromId)              the popup switched TO this mode;
--                                         fromId nil = the popup just opened
--   onExit        fn(toId)                the popup switched AWAY; toId nil =
--                                         the popup closed
--   store         fn -> table             where rows with a `key` read / write
--   onChanged     fn(key, value, spec)    after any row write in this mode
--   presets       { {id=, label=}, ... } | fn -> that list   preset chips
--   applyPreset   fn(presetId)
--   activePreset  fn -> presetId | nil    which chip is lit (derive it from
--                                         state, not from the last click)
--   isPreviewOn   fn -> bool              optional: shows the header's preview
--   togglePreview fn()                    toggle; the popup closes when a click
--                                         turns the preview OFF
--   sections      array of:
--     { id = "general", label = "General" (short, rail), title = "..." (header;
--       label when absent), icon = path, order = n (array order when absent),
--       isAvailable = fn -> bool (hidden from the rail when false),
--       build = fn(rows, mode) }
--
-- build(rows, mode) fills the section. `rows` is a DandersUI row list
-- (UI:CreateRowList, DandersUI/RowList.lua) already bound to the mode's store:
--   rows:AddHeading(text)
--   rows:AddSwitch  { label, key, default, onChanged, link, linkHint, tooltip,
--                     disabled, hidden, get, set }
--   rows:AddSlider  { ..., min, max, step, format, onDragStart, onDragStop }
--   rows:AddDropdown{ ..., options }
-- DF:TestModeSettingsLink(pageId) (the popup's file) gives a ready `link` +
-- `linkHint` pair that opens a DandersFrames settings page.
--
-- Calls into a mode are protected: an error in one is reported through the
-- normal error handler and does not take the popup down with it.
-- ============================================================

local type, pairs, ipairs, tostring = type, pairs, ipairs, tostring
local sort = table.sort

DF._testModes = DF._testModes or {}
DF._testModeListeners = DF._testModeListeners or {}

local function Notify()
    for _, fn in ipairs(DF._testModeListeners) do
        local ok, err = pcall(fn)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end
end

-- Register (or replace) a mode. Returns the def, or nil plus a reason when
-- the def is unusable -- a bad registration is refused rather than half-shown.
function DF:RegisterTestMode(id, def)
    if type(id) ~= "string" or id == "" then return nil, "id must be a non-empty string" end
    if type(def) ~= "table" then return nil, "def must be a table" end
    if def.label == nil then return nil, "def.label is required" end
    if type(def.sections) ~= "table" then return nil, "def.sections must be a table" end
    for i, sec in ipairs(def.sections) do
        if type(sec) ~= "table" or type(sec.id) ~= "string" or type(sec.build) ~= "function" then
            return nil, "section " .. i .. " needs an id and a build function"
        end
    end
    def.id = id
    DF._testModes[id] = def
    Notify()
    return def
end

function DF:UnregisterTestMode(id)
    if DF._testModes[id] == nil then return false end
    DF._testModes[id] = nil
    Notify()
    return true
end

function DF:GetTestMode(id) return DF._testModes[id] end

-- Every registered mode, sorted by order then id (available or not).
function DF:GetTestModeList()
    local out = {}
    for _, def in pairs(DF._testModes) do out[#out + 1] = def end
    sort(out, function(a, b)
        local oa, ob = a.order or 100, b.order or 100
        if oa ~= ob then return oa < ob end
        return tostring(a.id) < tostring(b.id)
    end)
    return out
end

-- Can the user pick this mode? ok, whyTitle, whyLines.
function DF:IsTestModeAvailable(id)
    local def = DF._testModes[id]
    if not def then return false end
    if not def.isAvailable then return true end
    local ok, avail, why, lines = pcall(def.isAvailable)
    if not ok then
        if geterrorhandler then geterrorhandler()(avail) end
        return false
    end
    if avail == false or avail == nil then return false, why, lines end
    return true
end

-- The sections a mode shows right now: available ones, by order (array order
-- breaks ties and is the order when none is given).
function DF:GetTestModeSections(id)
    local def = DF._testModes[id]
    local out = {}
    if not def then return out end
    for i, sec in ipairs(def.sections) do
        local show = true
        if sec.isAvailable then
            local ok, avail = pcall(sec.isAvailable)
            if not ok then
                if geterrorhandler then geterrorhandler()(avail) end
                show = false
            else
                show = avail and true or false
            end
        end
        if show then out[#out + 1] = { sec = sec, index = i } end
    end
    sort(out, function(a, b)
        local oa, ob = a.sec.order or a.index, b.sec.order or b.index
        if oa ~= ob then return oa < ob end
        return a.index < b.index
    end)
    for i, e in ipairs(out) do out[i] = e.sec end
    return out
end

-- The popup listens here; any register / unregister reaches it.
function DF:OnTestModesChanged(fn)
    if type(fn) == "function" then
        DF._testModeListeners[#DF._testModeListeners + 1] = fn
    end
end
