local NS = ...

-- ============================================================
-- RESET A MODULE TO DEFAULTS -- the registry hook and the Modules page
-- DandersFrames_Options/GUI/ModuleRegistry.lua (def.reset, GUI:GetModuleReset)
-- DandersFrames_Options/GUI/Pages/ModulesPage.lua (the Reset button, the warning)
-- ------------------------------------------------------------
-- A module with a reset gets a Reset button on its Modules page row; one without
-- gets none (Global, coming-soon). The button asks first: a danger popup whose
-- body lists exactly what the module's reset covers and keeps, names the profile
-- it applies to, says other profiles are untouched and that it cannot be undone.
-- Confirming runs the module's own reset, deferred off the popup, after any mover
-- session ends -- never in combat, never under the auto-layout editor.
-- Headless: the page is drawn over FakeUIFrame and recording kit stubs.
-- ============================================================

local savedDF, savedCF, savedTimer = DandersFrames, CreateFrame, C_Timer

local GUI = {
    SelectedMode = "party", GlobalView = false, GlobalAccent = { r = 0.25, g = 0.78, b = 0.85 },
    GlobalPages = { general_settings = true },
    Colors = {
        panel = { r = 0.1, g = 0.1, b = 0.1 }, border = { r = 0.2, g = 0.2, b = 0.2 },
        text = { r = 1, g = 1, b = 1 }, textDim = { r = 0.6, g = 0.6, b = 0.6 },
        textCaption = { r = 0.7, g = 0.7, b = 0.7 }, notice = { r = 1, g = 0.8, b = 0.2 },
    },
}
function GUI.IsGlobalPage(name) return GUI.GlobalPages[name] == true end
function GUI.GetThemeColorFor(isRaid) return isRaid and { r = 1, g = 0.5, b = 0 } or { r = 0.5, g = 0.4, b = 1 } end
function GUI:GetAccent() return { r = 0.5, g = 0.4, b = 1 } end
function GUI:SetSettingsFont() end

local errs, popups, tooltips = {}, {}, {}
local DF = { GUI = GUI }
DF.L = setmetatable({}, { __index = function(_, k) return k end })
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
function DF:Err(msg) errs[#errs + 1] = msg end
function DF:ShowPopupAlert(cfg) popups[#popups + 1] = cfg end
function DF:GetCurrentProfile() return "Raiding" end
DandersFrames = DF

-- The page caches CreateFrame at load, so the fake goes in first.
local buttons = {}
CreateFrame = function() return FakeUIFrame() end

-- C_Timer.After: queued, run on demand, so "deferred" is observable.
local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
local function flushTimers()
    local list = timers
    timers = {}
    for _, fn in ipairs(list) do fn() end
end

load_options_file_into("GUI/ModuleRegistry.lua", NS)

-- ---- the registry hook ------------------------------------------------
print("-- Module reset: the registry hook")
check(type(GUI.GetModuleReset) == "function", "api: GUI:GetModuleReset")
check(GUI:GetModuleReset("group") ~= nil, "hook: Group Frames has a reset")
DF.ClickCast = { db = { enabled = true }, ResetActiveProfile = function() return true end,
                 GetActiveProfileName = function() return "Holy" end }
check(GUI:GetModuleReset("clicks") ~= nil, "hook: Click-Casting has a reset (loaded)")
DF.ClickCast = nil
eq(GUI:GetModuleReset("clicks"), nil, "hook: ...and none while click-casting is not loaded (available)")
eq(GUI:GetModuleReset("global"), nil, "hook: Global has none")
eq(GUI:GetModuleReset("units"), nil, "hook: a coming-soon module has none")
eq(GUI:GetModuleReset("home"), nil, "hook: Home has none")
eq(GUI:GetModuleReset("profiles"), nil, "hook: Profiles has none")
eq(GUI:GetModuleReset("modules"), nil, "hook: Modules has none")
eq(GUI:GetModuleReset("nope"), nil, "hook: an unknown id has none")

GUI:RegisterModule({ id = "bad1", label = "Bad", reset = { run = function() end } })
eq(GUI:GetModuleReset("bad1"), nil, "hook: a reset without covers() is not a reset")
GUI:RegisterModule({ id = "bad2", label = "Bad", reset = { covers = function() return {} end } })
eq(GUI:GetModuleReset("bad2"), nil, "hook: ...nor one without run()")
GUI:RegisterModule({ id = "bad3", label = "Bad", comingSoon = true,
                     reset = { run = function() end, covers = function() return {} end } })
eq(GUI:GetModuleReset("bad3"), nil, "hook: a coming-soon module never has one, even if declared")
GUI:RegisterModule({ id = "bad4", label = "Bad",
                     reset = { run = function() end, covers = function() return {} end,
                               available = function() error("boom") end } })
eq(GUI:GetModuleReset("bad4"), nil, "hook: a throwing available() reads as unavailable")

-- A module of the test's own, with a switch, a reset and recorders.
local runs, moduleOn = 0, true
GUI:RegisterModule({
    id = "toy", label = function() return "Toy Frames" end, order = 50, slot = "top",
    isEnabled = function() return moduleOn end,
    setEnabled = function(on, _, done) moduleOn = on; if done then done() end end,
    reset = {
        covers = function() return { "Toy setting one", "Toy setting two" } end,
        keeps = function() return { "Toy colours" } end,
        run = function() runs = runs + 1; return true end,
    },
})
check(GUI:GetModuleReset("toy") ~= nil, "hook: a module that declares run + covers has a reset")

-- ---- the warning's text ------------------------------------------------
print("-- Module reset: the warning")
load_options_file_into("GUI/Pages/ModulesPage.lua", NS)
check(GUI.ModuleResetMessage and GUI.ConfirmModuleReset and GUI.RunModuleReset and GUI.ModuleResetBlocked,
      "api: the page publishes the warning and the runner")

local msg = GUI:ModuleResetMessage("toy") or ""
check(msg:find("These go back to their defaults:", 1, true) == 1, "text: it opens with what is reset")
check(msg:find("\226\128\162 Toy setting one", 1, true) and msg:find("\226\128\162 Toy setting two", 1, true),
      "text: every covered line is listed, one bullet each")
check(msg:find("\nNot reset: Toy colours\n", 1, true), "text: what it keeps reads after Not reset:")
check(msg:find("Only the current profile, Raiding, is reset. Your other profiles are untouched.", 1, true),
      "text: names the current profile and says the others are untouched")
check(msg:find("To keep a copy, export it first: Profiles > Import/Export.", 1, true),
      "text: points at the export first")
check(msg:find("This cannot be undone.", 1, true), "text: says it cannot be undone")
local cover, keep, scope = msg:find("Toy setting two", 1, true), msg:find("Toy colours", 1, true),
    msg:find("Raiding", 1, true)
check(cover < keep and keep < scope, "text: covers, then keeps, then the scope")

local gmsg = GUI:ModuleResetMessage("group") or ""
check(gmsg:find("Raiding", 1, true)
      and gmsg:find("All party and raid frame settings, including positions, pinned frames, auto layouts and synced sections", 1, true)
      and gmsg:find("The Party and Raid Aura Designer and Text Designer setups", 1, true),
      "text: Group Frames lists its own covers, grouped")
check(gmsg:find("Not reset: whether Party and Raid are on, settings on the Global page, and designer presets saved under other names", 1, true),
      "text: ...says Party and Raid stay on or off, and what else it keeps")

DF.ClickCast = { db = { enabled = true }, ResetActiveProfile = function() return true end,
                 GetActiveProfileName = function() return "Holy" end }
local cmsg = GUI:ModuleResetMessage("clicks") or ""
check(cmsg:find("Only the current click-casting profile, Holy, is reset.", 1, true),
      "text: Click-Casting names ITS profile (its own scope line)")
check(not cmsg:find("Raiding", 1, true), "text: ...and not the main profile, which it does not touch")
check(cmsg:find("Not reset: whether click-casting is on", 1, true), "text: ...and says it stays on or off")
DF.ClickCast = nil

-- WILL IT FIT: the popup is 440 wide (400px of text) and capped at 500 tall, and
-- 112px of that is its own chrome. Estimated pessimistically -- 55 characters a
-- line (bytes, so a bullet counts three), 16px a line -- and held to 400, which
-- leaves room for longer translations and the client's own wrap.
local function PopupHeight(text)
    local lines = 0
    for line in (text .. "\n"):gmatch("(.-)\n") do
        lines = lines + math.max(1, math.ceil(#line / 55))
    end
    return 112 + 16 * lines, lines
end
for name, text in pairs({ toy = msg, group = gmsg, clicks = cmsg }) do
    local h, lines = PopupHeight(text)
    check(h <= 400, "fit: the " .. name .. " warning fits the popup with room to spare (~"
          .. lines .. " lines, ~" .. h .. "px of 500)")
end
-- The guard has teeth: a list per setting, as the first draft had, does not pass.
do
    local long = { "These go back to their defaults:" }
    for i = 1, 12 do long[#long + 1] = "\226\128\162 One setting area, listed on its own, long enough to wrap onto two lines " .. i end
    check(PopupHeight(table.concat(long, "\n")) > 400, "fit: ...and a one-line-per-setting list would not")
end

-- ---- the page: a Reset button on every row with a reset ---------------
print("-- Module reset: the Modules page rows")
function GUI:StyleButton(b, o)
    b.styleOpts = o
    if o.text then buttons[#buttons + 1] = b end
end
function GUI:CreateRoundedSurface(_, o) local s = FakeUIFrame(); s.opts = o; return s end
function GUI:CreateCheckRow() local c = FakeUIFrame(); c.SetChecked = function(self, v) self._checked = v end; return c end
function GUI:IsModulePickLocked() return false end
function GUI:ShowTooltip(owner, spec) tooltips[#tooltips + 1] = { owner = owner, spec = spec } end
function GUI:HideTooltip() end
function GUI:CreateModuleView()
    local v = FakeUIFrame(600, 400)
    v.scroll = FakeUIFrame(600, 400)
    v.body = FakeUIFrame(600, 400)
    return v
end
DF.db = { partyEnabled = true, raidEnabled = true }
DF.ClickCast = { db = { enabled = true, bindings = {} }, ResetActiveProfile = function() return true end,
                 GetActiveProfileName = function() return "Holy" end }
GUI:ShowModulesView()

local function resetFor(id)
    for _, b in ipairs(buttons) do
        if b.styleOpts.text == "Reset" and b.def and b.def.id == id and b:IsShown() then return b end
    end
end
local resets = {}
for _, b in ipairs(buttons) do if b.styleOpts.text == "Reset" then resets[#resets + 1] = b end end
check(#resets > 0, "rows: Reset buttons are built")
local r1 = resets[1] and resets[1].styleOpts or {}
check(r1.rounded == true and r1.tone == "danger" and r1.height == 24,
      "rows: Reset is the kit's rounded, danger-toned button at the Open button's height")
check(resetFor("group") ~= nil, "rows: Group Frames' row shows Reset")
check(resetFor("clicks") ~= nil, "rows: Click-Casting's row shows Reset")
check(resetFor("toy") ~= nil, "rows: a registered module with a reset shows Reset")
local shownIds = {}
for _, b in ipairs(resets) do if b:IsShown() then shownIds[#shownIds + 1] = b.def and b.def.id or "?" end end
table.sort(shownIds)
eq(table.concat(shownIds, ","), "clicks,group,toy", "rows: ...and no other row does (Units is coming soon)")

-- An off module keeps its Reset: its settings are kept while it is off.
moduleOn = false
GUI:RefreshModulesView()
check(resetFor("toy") ~= nil, "rows: an OFF module's row still shows Reset")
moduleOn = true
GUI:RefreshModulesView()

-- The tooltip says what it resets.
local tb = resetFor("toy")
tooltips = {}
if tb and tb:GetScript("OnEnter") then tb:GetScript("OnEnter")(tb) end
local tip = tooltips[1] and tooltips[1].spec
check(tip and tip.title == "Reset to Defaults" and tip.lines and tip.lines[1] == "Toy setting one"
      and tip.lines[2] == "Toy setting two", "tooltip: titled Reset to Defaults, listing what it covers")

-- Greyed while an auto layout is edited.
DF.AutoProfilesUI = { IsEditing = function() return true end }
GUI:RefreshModulesView()
check(tb and tb:IsEnabled() == false, "rows: Reset is greyed under the auto-layout editor")
DF.AutoProfilesUI = nil
GUI:RefreshModulesView()
check(tb and tb:IsEnabled() == true, "rows: ...and live again after it")

-- ---- the click: the warning, then the run -----------------------------
print("-- Module reset: confirm and run")
popups, runs, timers, errs = {}, 0, {}, {}
if tb then tb:GetScript("OnClick")(tb) end
local cfg = popups[1]
check(cfg ~= nil, "click: the Reset button opens the warning")
eq(runs, 0, "click: ...and resets nothing by itself")
eq(cfg and cfg.title, "Reset Toy Frames?", "popup: titled with the module's name")
eq(cfg and cfg.tone, "danger", "popup: a danger popup")
eq(cfg and cfg.message, GUI:ModuleResetMessage("toy"), "popup: the body is the warning text")
local b1, b2 = cfg and cfg.buttons[1], cfg and cfg.buttons[2]
check(b1 and b1.label == "Reset" and b1.tone == "danger", "popup: Reset is the danger button")
check(b2 and b2.label == "Cancel" and b2.onClick == nil, "popup: Cancel only closes")

if b1 then b1.onClick() end
eq(runs, 0, "confirm: deferred off the popup (the popup hides after onClick)")
flushTimers()
eq(runs, 1, "confirm: then the module's reset runs, once")

print("-- Module reset: what stops it")
popups, runs, errs = {}, 0, {}
IN_COMBAT = true
eq(GUI:ConfirmModuleReset("toy"), false, "combat: no warning opens")
eq(#popups, 0, "combat: ...none shown")
eq(errs[1], "Cannot use this action in combat.", "combat: says why")
eq(GUI:RunModuleReset("toy"), false, "combat: the runner refuses too")
eq(runs, 0, "combat: nothing reset")
IN_COMBAT = false

errs = {}
DF.AutoProfilesUI = { IsEditing = function() return true end }
eq(GUI:ConfirmModuleReset("toy"), false, "editing: no warning under the auto-layout editor")
eq(errs[1], "Finish editing the auto layout first.", "editing: says why")
DF.AutoProfilesUI = nil

-- Combat starting while the warning is open: the deferred run re-checks.
popups, timers, errs = {}, {}, {}
GUI:ConfirmModuleReset("toy")
popups[1].buttons[1].onClick()
IN_COMBAT = true
flushTimers()
IN_COMBAT = false
eq(runs, 0, "late combat: a fight that started with the warning open stops the run")
eq(errs[1], "Cannot use this action in combat.", "late combat: says why")

-- A mover session is ended first; the reset waits for it.
local pending
DF.MoverBridge = {
    IsSessionActive = function() return true end,
    EndSessionThen = function(_, fn) pending = fn end,
}
runs = 0
GUI:RunModuleReset("toy")
eq(runs, 0, "mover: the reset waits while the session ends (Save / Discard)")
check(type(pending) == "function", "mover: ...it is handed to EndSessionThen")
if pending then pending() end
eq(runs, 1, "mover: and runs once the session has ended")
DF.MoverBridge = nil

eq(GUI:RunModuleReset("global"), false, "runner: a module without a reset does nothing")
eq(GUI:ConfirmModuleReset("global"), false, "confirm: ...and opens nothing")

DandersFrames, CreateFrame, C_Timer = savedDF, savedCF, savedTimer
IN_COMBAT = false
