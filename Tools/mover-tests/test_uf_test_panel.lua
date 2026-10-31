local NS = ...

-- ============================================================
-- UNIT FRAMES -- THE UNITS TEST PANEL
-- DandersFrames_Options/UnitFrames/TestPanel.lua over the real companion
-- (Core / Links / Defaults / Preview) and stub widgets that record what the
-- panel asks the shared factories for. Checks: every section and control is
-- there, each control reads and writes the UNITS test settings (or the boss
-- table for the boss rows), opening turns the units test mode on and closing
-- turns it off, the party / raid test mode taking over closes it, and nothing
-- is registered with settings search.
-- ============================================================

local saved = {
    DandersFrames = DandersFrames, CreateFrame = CreateFrame, C_Timer = C_Timer,
    UISpecialFrames = UISpecialFrames, UIParent = UIParent, hooksecurefunc = hooksecurefunc,
}
C_Timer = { After = function(_, fn) fn() end }
UISpecialFrames = {}
UIParent = UIParent or {}

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

-- ---- stub frames -------------------------------------------------------------
local function noop() end
local FrameMT = { __index = function(_, k)
    if type(k) == "string" and k:match("^%u") then return noop end
end }
local function Frame()
    local f = setmetatable({ shown = true, scripts = {} }, FrameMT)
    f.Hide = function(self)
        local was = self.shown
        self.shown = false
        if was and self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    f.Show = function(self) self.shown = true end
    f.IsShown = function(self) return self.shown end
    f.SetScript = function(self, name, fn) self.scripts[name] = fn end
    f.SetParent = function(self, p) self.parent = p end
    f.SetHeight = function(self, h) self.height = h end
    f.CreateFontString = function()
        local fs = setmetatable({}, FrameMT)
        fs.SetText = function(self, t) self.text = t end
        return fs
    end
    f.CreateTexture = function() return setmetatable({}, FrameMT) end
    return f
end

-- ---- DandersFrames ------------------------------------------------------------
local says = {}
local DF = { PartyDefaults = {}, L = setmetatable({}, { __index = function(_, k) return k end }) }
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable() return true end
function DF:Say(msg) says[#says + 1] = msg end
DF.RegisterCallback = function() end
DF._owners = { party = {}, raid = {} }
function DF:IsTestModeOwnedBy(scope, owner) return self._owners[scope][owner] and true or false end
function DF:SetTestModeOwner(scope, owner, wanted) self._owners[scope][owner] = wanted and true or nil end
DandersFrames = DF
hooksecurefunc = function(t, name, fn)
    local orig = t[name]
    t[name] = function(...) local r = orig(...); fn(...); return r end
end

CreateFrame = nil        -- the companion's file-scope event wiring is skipped
local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Links.lua", UF)
load_uf_file_into("Defaults.lua", UF)
load_uf_file_into("Preview.lua", UF)
DF.db = { unitframes = deepcopy(UF.ProfileDefaults) }
UF.frames = {}
local P = UF.Preview
P:Init()
-- The preview's frames are not what this suite is about.
P.Show = function() P.shown = true end
P.Hide = function() P.shown = false end
local refreshes = 0
P.Refresh = function() refreshes = refreshes + 1 end
CreateFrame = function() return Frame() end

-- ---- the shared widgets, recorded -------------------------------------------
local widgets, groups, collapsed, buttonState = {}, {}, {}, {}
local G = { Colors = {
    text = { r = 1, g = 1, b = 1 }, textDim = { r = 0.5, g = 0.5, b = 0.5 }, accent = { r = 0.6, g = 0.4, b = 1 },
    background = { r = 0, g = 0, b = 0, a = 0.9 }, border = { r = 0.3, g = 0.3, b = 0.3 },
} }
local function Widget(kind, label, get, set, cb, extra)
    local w = Frame()
    w.kind, w.label, w.get, w.set, w.cb = kind, label, get, set, cb
    for k, v in pairs(extra or {}) do w[k] = v end
    w.SetEnabled = function(self, on) self.enabled = on end
    widgets[#widgets + 1] = w
    return w
end
function G:CreateCheckbox(parent, label, db, key, cb, get, set, ov, opts)
    return Widget("checkbox", label, get, set, cb, { db = db, key = key, opts = opts })
end
function G:CreateSlider(parent, label, lo, hi, step, db, key, cb, light, prev, get, set)
    return Widget("slider", label, get, set, cb, { db = db, key = key, lo = lo, hi = hi })
end
function G:CreateDropdown(parent, label, options, db, key, cb, get, set)
    return Widget("dropdown", label, get, set, cb, { db = db, key = key, options = options })
end
function G:CreateHeader(parent, text) local h = Frame(); h.text = { GetText = function() return text end }; h.header = text; return h end
function G:CreateSettingsGroup(parent, width, opts)
    local g = Frame()
    g.opts, g.groupChildren = opts, {}
    g.AddWidget = function(self, w) self.groupChildren[#self.groupChildren + 1] = { widget = w }; return w end
    g.LayoutChildren = function(self) return 40 end
    g.RefreshChildValues = function(self) self.valuesRefreshed = true end
    groups[#groups + 1] = g
    return g
end
function G:CreatePanelBackdrop() end
function G:CreateCloseButton() return Frame() end
function G:StyleButton(btn)
    btn.Text = btn:CreateFontString()
    btn.SetActive = function(self, on) self.active = on end
end
function G:GetCollapsedGroups() return collapsed end
function G.GetThemeColor() return G.Colors.accent end
G.UpdateTestButtonState = function() buttonState[#buttonState + 1] = true end
DF.GUI = G
DF.Search = {}

-- The Unit Frames options table, as far as the panel reads it (Pages.lua).
local UFO = {}
G.UnitFrameOptions = UFO
DF.UnitFrames = UF
function UFO.UnitLabel(u) return "label:" .. u end
function UFO.IsTestModeOn() return P:IsTestMode() end
function UFO.SetTestMode(on) return P:SetTestMode(on) end

load_options_file_into("UnitFrames/TestPanel.lua", NS)
check(type(UFO.ToggleTestPanel) == "function", "the panel's toggle is published")
check(options_file_source("DandersFrames_Options.toc"):find("UnitFrames\\TestPanel.lua", 1, true),
      "...and the file is in the options TOC")

print("-- Opening: the units test mode on")
UFO.ToggleTestPanel()
local panel = UFO.testPanel
check(panel ~= nil, "built on first open")
eq(panel:IsShown(), true, "shown")
eq(P:IsTestMode(), true, "the units test mode is on")
eq(UFO.IsTestPanelShown(), true, "IsTestPanelShown")
eq(panel.toggle.Text.text, "Disable Test Mode", "its toggle offers to turn it off")
check(#buttonState > 0, "the window's Test button is told")
eq(DF.Search.SuppressRegistration, nil, "search registration is restored after the build")

print("-- Sections and controls")
local headers = {}
for _, g in ipairs(groups) do
    headers[#headers + 1] = g.groupChildren[1].widget.header
    eq(g.opts.collapsible, true, g.groupChildren[1].widget.header .. ": collapsible")
end
eq(table.concat(headers, ","), "Frames,Target,Health,Bars,Auras,Icons", "the six sections")
eq(collapsed["ufTest:frames"], nil, "first open: Frames unfolded")
eq(collapsed["ufTest:auras"], true, "...the rest folded")
local byLabel = {}
for _, w in ipairs(widgets) do
    byLabel[w.label] = w
    eq(w.db, nil, w.label .. ": get / set, not bound to a page table")
    if w.kind == "checkbox" then eq(w.opts and w.opts.noSearch, true, w.label .. ": no search entry") end
end
for _, l in ipairs({ "label:player", "label:target", "label:targettarget", "label:focus", "label:focustarget",
                     "label:pet", "Boss", "Preview Frames", "Classification", "Reaction", "Animate Health",
                     "Fixed Health", "Health", "Absorbs", "Heal Prediction", "Cast Bar", "Class Power",
                     "Show Auras", "Buffs", "Debuffs", "Status Icons", "Raid Target Icon", "Leader Icon",
                     "Combat Icon" }) do
    check(byLabel[l] ~= nil, "control: " .. l)
end

print("-- Controls read and write the units test settings")
local tdb = UF:GetTestDB()
byLabel["label:pet"].set(false)
eq(tdb.showPet, false, "Pet: units test settings")
byLabel["label:pet"].cb()
check(refreshes > 0, "...and the preview repaints")
byLabel["label:pet"].set(true)
byLabel["Classification"].set("rare")
eq(tdb.classification, "rare", "Classification")
eq(byLabel["Classification"].options._order[1], "normal", "...normal / elite / rare / rare elite / boss")
byLabel["Buffs"].set(4)
eq(tdb.testBuffCount, 4, "Buffs")
eq(rawget(DF.db.unitframes.global, "testMode"), tdb, "stored under the module table, apart from party / raid")
byLabel["Boss"].set(false)
eq(UF:GetStoredUnit("boss").bossPreviewCount, false, "Boss: the boss page's own Show Placeholder Frames")
byLabel["Preview Frames"].set(3)
eq(UF:GetStoredUnit("boss").bossPreviewNum, 3, "Preview Frames: the boss page's own count")

print("-- Grey when disabled")
panel.content.RefreshStates()
eq(byLabel["Preview Frames"].enabled, false, "Boss off: its count greys")
eq(byLabel["Health"].enabled, false, "Fixed Health off: the Health slider greys")
tdb.fixedHealth = true
panel.content.RefreshStates()
eq(byLabel["Health"].enabled, true, "...and comes back with it")
tdb.testShowStatusIcons = false
panel.content.RefreshStates()
eq(byLabel["Leader Icon"].enabled, false, "Status Icons off: the icon switches grey")
tdb.testShowStatusIcons, tdb.fixedHealth = true, false
byLabel["Boss"].set(true)

print("-- The toggle: off, and the panel closes")
panel.toggle.scripts.OnClick()
eq(panel:IsShown(), false, "closed")
eq(P:IsTestMode(), false, "the units test mode is off")

print("-- The party / raid test mode taking over closes it")
UFO.ToggleTestPanel()
eq(P:IsTestMode(), true, "open again: on")
DF:SetTestModeOwner("party", "user", true)
eq(P:IsTestMode(), false, "the user's party claim turns it off")
eq(panel:IsShown(), false, "...and closes the panel")
DF._owners.party.user = nil

print("-- Closing by the toolbar route (toggle again) turns it off")
UFO.ToggleTestPanel()
UFO.ToggleTestPanel()
eq(P:IsTestMode(), false, "off")

DandersFrames, CreateFrame, C_Timer = saved.DandersFrames, saved.CreateFrame, saved.C_Timer
UISpecialFrames, UIParent, hooksecurefunc = saved.UISpecialFrames, saved.UIParent, saved.hooksecurefunc
