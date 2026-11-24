local NS = ...

-- ============================================================
-- Settings tooltip plan, batch 5: display and indicators.
-- Fading, Tooltips, Highlights and Icons.
--
-- Source-shape only, like the page suites: it proves each widget carries its
-- tooltip, the header-tick strings sit on both the tick and the in-body
-- checkbox, and every string ships in enUS. It does not build a frame.
-- ============================================================

local OPT  = options_file_source("GUI/Pages/Options.lua"):gsub("\r\n", "\n")
local MOD  = options_file_source("GUI/Pages/Modules.lua"):gsub("\r\n", "\n")
local ENUS = df_file_source("Locales/enUS.lua"):gsub("\r\n", "\n")

local OOR = "Fades each part of an out-of-range frame by its own amount instead of the whole frame at once. Useful for keeping names readable while the health bar dims."
local DSP = "Brings a faded frame back to full view while that player has a debuff you can dispel, so the fade never hides it. Only works while the Dispel Overlay is turned on."
local BND = "When you hover a frame, shows a list of your click-casting bindings, so you can check what each click or key will cast."
local AGM = "How a player with threat is shown. Health Bar Color tints their health bar by threat level instead of drawing a border or glow, and Hidden turns it off."
local ORG = "Used when an enemy is attacking the player but someone else has more threat on it, so it may soon switch targets."
local RDY = "How long the ready check result stays on the frames after the check ends. 0 clears it as soon as the check finishes."
local LFG = "When a player is in a separate group from you, such as a dungeon finder group, shows the dungeon finder eye instead of the usual phased icon."

local function count(src, needle)
    local n, i = 0, 1
    while true do
        local s, e = src:find(needle, i, true)
        if not s then return n end
        n, i = n + 1, e + 1
    end
end

print("-- Display tooltips: Fading")
do
    check(OPT:find('GUI:WithTooltip(GUI:CreateCheckbox(parent, L["Enable Element-Specific Alpha"], db, "oorEnabled"', 1, true) ~= nil,
          "tooltips: Element-Specific Alpha in-body checkbox is wrapped")
    check(OPT:find('label = L["Enable Element-Specific Alpha"],\n                tooltip = L["' .. OOR .. '"]', 1, true) ~= nil,
          "tooltips: Element-Specific Alpha header tick")
    eq(count(OPT, 'L["' .. OOR .. '"]'), 2, "tooltips: Element-Specific Alpha text on the tick and the in-body checkbox only")

    check(OPT:find('GUI:WithTooltip(GUI:CreateCheckbox(parent, L["Cancel Fade on Dispellable Debuff"], db, "hfCancelOnDispel"', 1, true) ~= nil,
          "tooltips: Cancel Fade on Dispellable Debuff is wrapped")
    eq(count(OPT, 'L["' .. DSP .. '"]'), 1, "tooltips: Cancel Fade on Dispellable Debuff text once")
end

print("-- Display tooltips: Binding Tooltips")
do
    check(OPT:find('bindTooltipEnable.tooltip = L["' .. BND .. '"]', 1, true) ~= nil,
          "tooltips: Binding Tooltips in-body checkbox")
    check(OPT:find('label = L["Enable Binding Tooltips"],\n                tooltip = L["' .. BND .. '"]', 1, true) ~= nil,
          "tooltips: Binding Tooltips header tick")
    eq(count(OPT, 'L["' .. BND .. '"]'), 2, "tooltips: Binding Tooltips text on the tick and the in-body checkbox only")
end

print("-- Indicator tooltips: Highlights")
do
    check(MOD:find('GUI:WithTooltip(GUI:CreateDropdown(parent, L["Mode"], aggroModes, db, "aggroHighlightMode"', 1, true) ~= nil,
          "tooltips: Aggro Mode dropdown is wrapped")
    eq(count(MOD, 'L["' .. AGM .. '"]'), 1, "tooltips: Aggro Mode text once")
    check(MOD:find('colorHighestThreat.tooltip = L["' .. ORG .. '"]', 1, true) ~= nil,
          "tooltips: Highest Threat colour")
end

print("-- Indicator tooltips: Icons")
do
    check(MOD:find('GUI:WithTooltip(GUI:CreateSlider(parent, L["Persist (seconds)"], 0, 15, 1, db, "readyCheckIconPersist"), L["' .. RDY .. '"])', 1, true) ~= nil,
          "tooltips: Ready Check Persist")
    check(MOD:find('GUI:WithTooltip(GUI:CreateCheckbox(parent, L["Show LFG Eye for Cross-Instance"], db, "phasedIconShowLFGEye", OnIconEnabled), L["' .. LFG .. '"])', 1, true) ~= nil,
          "tooltips: Show LFG Eye for Cross-Instance")
end

print("-- Display and indicator tooltips: every string ships in enUS, once")
do
    for _, s in ipairs({ OOR, DSP, BND, AGM, ORG, RDY, LFG }) do
        eq(count(ENUS, 'L["' .. s .. '"] = true'), 1, "locale: enUS ships L[\"" .. s:sub(1, 40) .. "...\"] once")
    end
end
