local NS = ...

-- ============================================================
-- Settings tooltip plan, batch 4: targeted spells.
-- Targeted List and Personal Targeted Spells.
--
-- Source-shape only, like the page suites: it proves each widget carries its
-- tooltip, the shared strings sit on exactly the widgets they serve, and every
-- string ships in enUS. It does not build a frame.
-- ============================================================

local IND  = options_file_source("GUI/Pages/Indicators.lua"):gsub("\r\n", "\n")
local ENUS = df_file_source("Locales/enUS.lua"):gsub("\r\n", "\n")

local IMP   = "Only shows casts the game itself marks as important, usually ones worth interrupting or avoiding, and hides the rest."
local UNT   = "Also lists casts with no target, such as ground effects and area spells. With this off, only casts aimed at someone in your group appear."
local SORT  = "The order the bars appear in. Newest First puts the latest cast first, Oldest First keeps the earliest first, and Static gives each cast a fixed spot so bars never move, which can leave gaps as casts end."
local STYLE = "Applies a ready-made look in one go, setting bar size, spacing, icon, which text shows, border, background opacity and font size. You can still change any of them afterwards."
local PRE   = "Puts a > before the target's name, like an arrow pointing at them."
local SUF   = "Puts a < after the target's name, like an arrow pointing back at them."
local WID   = "The widest this text can be before it is cut short. 0 uses the full width of the bar."

local function count(src, needle)
    local n, i = 0, 1
    while true do
        local s, e = src:find(needle, i, true)
        if not s then return n end
        n, i = n + 1, e + 1
    end
end

print("-- Targeted spells tooltips: Targeted List")
do
    for _, pair in ipairs({
        { "tlImportantOnly",  IMP },
        { "tlShowUntargeted", UNT },
        { "tlSort",           SORT },
        { "tlPreset",         STYLE },
        { "tlArrow",          PRE },
        { "tlArrowSuffix",    SUF },
        { "tlSNWidth",        WID },
        { "tlTNWidth",        WID },
        { "tlIntWidth",       WID },
    }) do
        check(IND:find(pair[1] .. '.tooltip = L["' .. pair[2] .. '"]', 1, true) ~= nil,
              "tooltips: Targeted List " .. pair[1])
    end
    eq(count(IND, 'L["' .. WID .. '"]'), 3, "tooltips: Max Text Width text on exactly the three text cards")
end

print("-- Targeted spells tooltips: Personal Targeted Spells")
do
    local call = 'GUI:WithTooltip(GUI:CreateCheckbox(parent, L["Important Spells Only"], db, "personalTargetedSpellImportantOnly", PersonalTargetedUpdate), L["' .. IMP .. '"])'
    check(IND:find(call, 1, true) ~= nil, "tooltips: Personal Important Spells Only")
    eq(count(IND, 'L["' .. IMP .. '"]'), 2, "tooltips: Important Spells Only text shared by the two pages, nowhere else")
end

print("-- Targeted spells tooltips: every string ships in enUS, once")
do
    for _, s in ipairs({ IMP, UNT, SORT, STYLE, PRE, SUF, WID }) do
        eq(count(ENUS, 'L["' .. s .. '"] = true'), 1, "locale: enUS ships L[\"" .. s:sub(1, 40) .. "...\"] once")
    end
end
