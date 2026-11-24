local NS = ...

-- ============================================================
-- Settings tooltip plan, batch 6: bars.
-- Absorbs, Heal Prediction and Health Bar (Reduced Max Health).
--
-- Source-shape only, like the page suites: it proves each widget carries its
-- tooltip, the shared Blend Mode string sits on exactly its three bars, and
-- every string ships in enUS. It does not build a frame.
-- ============================================================

local AUR  = options_file_source("GUI/Pages/Auras.lua"):gsub("\r\n", "\n")
local ENUS = df_file_source("Locales/enUS.lua"):gsub("\r\n", "\n")

local BLEND = "How the bar's colour mixes with the health bar under it. Normal draws the colour as picked. Additive brightens what it covers for a glowing look, and shows best over dark bars."
local CLIP  = "Shortens the health bar so it stops where the reduced section begins, instead of drawing the reduced section over the end of it."
local RBL   = "How the reduced section's colour mixes with what is under it. Blend draws the colour as picked, Add brightens it into a glow, and Modulate darkens what is underneath."

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

print("-- Bar tooltips: Blend Mode (Absorb, Heal Absorb, Heal Prediction)")
do
    check(wrapped(AUR, 'GUI:CreateDropdown(parent, L["Blend Mode"], blendOptions, db, "absorbBarBlendMode"', BLEND),
          "tooltips: Absorb Blend Mode")
    check(wrapped(AUR, 'GUI:CreateDropdown(parent, L["Blend Mode"], healBlendOptions, db, "healAbsorbBarBlendMode"', BLEND),
          "tooltips: Heal Absorb Blend Mode")
    check(AUR:find('"healPredictionBlendMode", function() DF:UpdateAllFrames() end), 55)\n            blendDropdown.tooltip = L["' .. BLEND .. '"]', 1, true) ~= nil,
          "tooltips: Heal Prediction Blend Mode")
    eq(count(AUR, 'L["' .. BLEND .. '"]'), 3, "tooltips: bar Blend Mode text on exactly the three bars")
end

print("-- Bar tooltips: Reduced Max Health")
do
    check(wrapped(AUR, 'GUI:CreateCheckbox(parent, L["Clip Health Bar"], db, "reducedMaxHealthClipHealthBar"', CLIP),
          "tooltips: Clip Health Bar")
    check(wrapped(AUR, 'GUI:CreateDropdown(parent, L["Blend Mode"], reducedBlendOpts, db, "reducedMaxHealthBlendMode"', RBL),
          "tooltips: Reduced Max Health Blend Mode")
    eq(count(AUR, 'L["' .. CLIP .. '"]'), 1, "tooltips: Clip Health Bar text once")
    eq(count(AUR, 'L["' .. RBL .. '"]'), 1, "tooltips: Reduced Blend Mode text once")
end

print("-- Bar tooltips: every string ships in enUS, once")
do
    for _, s in ipairs({ BLEND, CLIP, RBL }) do
        eq(count(ENUS, 'L["' .. s .. '"] = true'), 1, "locale: enUS ships L[\"" .. s:sub(1, 40) .. "...\"] once")
    end
end
