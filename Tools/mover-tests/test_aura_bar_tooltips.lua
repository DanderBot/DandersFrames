local NS = ...

-- ============================================================
-- Settings tooltip plan, batch 3: aura bars.
-- Buff Bar, Debuff Bar, Defensive Icon and Dispel Overlay, plus the two shared
-- builders every aura page mounts (pandemic controls, border animation).
--
-- Source-shape only, like the page suites: it proves each widget carries its
-- tooltip, each shared-builder string is written once, and every string ships
-- in enUS. It does not build a frame.
-- ============================================================

local IND  = options_file_source("GUI/Pages/Indicators.lua"):gsub("\r\n", "\n")
local MOD  = options_file_source("GUI/Pages/Modules.lua"):gsub("\r\n", "\n")
local CTRL = options_file_source("GUI/Controls.lua"):gsub("\r\n", "\n")
local SW   = options_file_source("GUI/SettingsWidgets.lua"):gsub("\r\n", "\n")
local ENUS = df_file_source("Locales/enUS.lua"):gsub("\r\n", "\n")

local SORT  = "The order icons appear in. Default keeps the game's own order with your auras first, Time Remaining puts the ones about to run out first, Alphabetical sorts by name, and Order Applied keeps each aura where it first landed so icons never jump around."
local COLOR = "Static uses your Texture and Bar Color. The other modes replace those and colour the bar from green to red as the aura runs out: DF Smooth blends between the colours, DF Stops changes in four clear steps, and Classic fades evenly along the whole bar."
local HIDE  = "Keeps the duration text hidden until the time left drops below the seconds set under it, so only auras close to running out show a number. Not available with the Percent format."
local FLASH = "How long one pulse out and back takes, in seconds. Higher values pulse more slowly."
local ANIM  = "Adds a moving effect to the border to draw the eye, such as a blink, a glow or sparkles running round it. Pick None to keep the border still."
local GSIZE = "How far the wash reaches in from the frame edge, as a share of the frame. Has no effect on Full Frame, which always covers the whole bar."
local BLEND = "Glow brightens what is underneath so the colour shines, and shows best over dark bars. Solid lays the colour on top exactly as picked, which reads better over bright class colours."

local function count(src, needle)
    local n, i = 0, 1
    while true do
        local s, e = src:find(needle, i, true)
        if not s then return n end
        n, i = n + 1, e + 1
    end
end

-- The wrapped call and its tooltip sit within one widget's worth of text.
local function wrapped(src, call, tip)
    local at = src:find("GUI:WithTooltip(" .. call, 1, true)
    local t = at and src:find('L["' .. tip .. '"]', at, true)
    return at ~= nil and t ~= nil and t - at < 600
end

print("-- Aura bar tooltips: Sort Order (Buff and Debuff)")
do
    check(wrapped(IND, 'GUI:CreateDropdown(parent, L["Sort Order"], buffSortOptions, db, "directBuffSortOrder"', SORT),
          "tooltips: Buff Sort Order")
    check(wrapped(IND, 'GUI:CreateDropdown(parent, L["Sort Order"], debuffSortOptions, db, "directDebuffSortOrder"', SORT),
          "tooltips: Debuff Sort Order")
    eq(count(IND, 'L["' .. SORT .. '"]'), 2, "tooltips: Sort Order text on exactly the two aura rows")
end

print("-- Aura bar tooltips: duration bar Color Mode (Buff, Debuff, Defensive)")
do
    for _, key in ipairs({ "buffDurationBarColorMode", "debuffDurationBarColorMode", "defensiveDurationBarColorMode" }) do
        check(wrapped(IND, 'GUI:CreateDropdown(parent, L["Color Mode"], DF:GetDurationBarColorModes(), db, "' .. key .. '"', COLOR),
              "tooltips: Color Mode on " .. key)
    end
    eq(count(IND, 'L["' .. COLOR .. '"]'), 3, "tooltips: Color Mode text on exactly the three duration bars")
end

print("-- Aura bar tooltips: Hide Above Threshold (Buff and Debuff)")
do
    eq(count(IND, 'durHideAbove.tooltip = L["' .. HIDE .. '"]'), 2, "tooltips: Hide Above Threshold on both duration text cards")
end

print("-- Aura bar tooltips: Dispel Overlay gradient")
do
    check(MOD:find('gradSize.tooltip = L["' .. GSIZE .. '"]', 1, true) ~= nil, "tooltips: Gradient Size")
    check(MOD:find('blendDropdown.tooltip = L["' .. BLEND .. '"]', 1, true) ~= nil, "tooltips: Dispel Blend Mode")
end

print("-- Aura bar tooltips: shared builders write their string once")
do
    check(CTRL:find('w.flashSpeed.tooltip = L["' .. FLASH .. '"]', 1, true) ~= nil,
          "tooltips: Flash Speed in GUI:CreatePandemicControls")
    eq(count(CTRL, FLASH), 1, "tooltips: ...written once")
    for _, src in ipairs({ IND, MOD, SW }) do
        eq(count(src, FLASH), 0, "tooltips: ...and no page carries its own copy")
    end

    check(SW:find('w.animationType.tooltip = L["' .. ANIM .. '"]', 1, true) ~= nil,
          "tooltips: Border Animation in GUI:CreateAnimationControls")
    eq(count(SW, ANIM), 1, "tooltips: ...written once")
    for _, src in ipairs({ IND, MOD, CTRL }) do
        eq(count(src, ANIM), 0, "tooltips: ...and no page carries its own copy")
    end
end

print("-- Aura bar tooltips: every string ships in enUS, once")
do
    for _, s in ipairs({ SORT, COLOR, HIDE, FLASH, ANIM, GSIZE, BLEND }) do
        eq(count(ENUS, 'L["' .. s .. '"] = true'), 1, "locale: enUS ships L[\"" .. s:sub(1, 40) .. "...\"] once")
    end
end
