-- ============================================================
-- TEXTURE LAYER CONTROLS (DandersFrames_Options/GUI/TextureLayerControls.lua)
-- The Quick Start looks and the short texture lists, lifted from the file by their
-- source text and run against a stub texture list and tiling registry.
-- ============================================================

local SRC = options_file_source("GUI/TextureLayerControls.lua")
local a = SRC:find("-- QUICK START LOOKS", 1, true)
local b = SRC:find("-- PREVIEW STRIP", 1, true)
check(a ~= nil and b ~= nil, "setup: found the looks and lists block")

-- The looks and the dot baseline live with the defaults; run that block for real.
local CFG = df_file_source("Core/Config.lua")
local ca = CFG:find("DF.TEXTURE_LAYER_BARS = {", 1, true)
local cb = CFG:find("-- RAID DEFAULTS", 1, true)
check(ca ~= nil and cb ~= nil, "setup: found the texture layer defaults and looks")

local MEDIA = "Interface\\AddOns\\DandersFrames\\Media\\"
local ALL = {
    [MEDIA .. "DF_Layer_Diagonal.png"] = "DF Layer Diagonal",
    [MEDIA .. "DF_Layer_Shade_Top.png"] = "DF Layer Shade Top",
    [MEDIA .. "DF_Gradient_H"] = "DF Gradient H",
    ["Interface\\Buttons\\WHITE8x8"] = "DF Flat",
    [MEDIA .. "DF_Minimalist"] = "DF Minimalist",
    ["Interface\\AddOns\\Other\\bar.tga"] = "Other Bar",
}
local DF = {
    PartyDefaults = {},
    TILED_BAR_TEXTURES = {
        [MEDIA .. "DF_Layer_Diagonal.png"] = "BOTH",
        [MEDIA .. "DF_Layer_Shade_Top.png"] = "HORIZ",
    },
    GetTextureList = function() local t = {} for k, v in pairs(ALL) do t[k] = v end return t end,
    GetTextureNameFromPath = function(_, path) return ALL[path] end,
}
assert(loadstring("local DF = ...\n" .. CFG:sub(ca, cb - 1), "@config"))(DF)
local LOOKS = DF.TEXTURE_LAYER_LOOKS
local chunk = assert(loadstring("local DF, L = ...\n" .. SRC:sub(a, b - 1)
    .. "\nreturn ApplyLook, NewList, FillList, LookOptions", "@lookslists"))
local ApplyLook, NewList, FillList, LookOptions = chunk(DF, setmetatable({}, { __index = function(_, k) return k end }))

-- ---- Quick Start ------------------------------------------------------------
do
    local db = {
        absorbBarTexture = "keep-me", absorbBarColor = "keep-me-too",
        absorbBarTileMode = "BOTH", absorbBarTileSize = 24,
        absorbBarLayer2Enabled = false, absorbBarLayer3Enabled = true,
    }
    ApplyLook(db, "absorbBar", "DIAGONAL_GLOSS")
    eq(db.absorbBarLayer2Enabled, true, "look: the pattern layer is switched on")
    eq(db.absorbBarLayer2Texture, MEDIA .. "DF_Layer_Diagonal.png", "look: ...with the diagonal")
    eq(db.absorbBarLayer3Enabled, true, "look: the shading layer is switched on")
    eq(db.absorbBarLayer3Texture, MEDIA .. "DF_Layer_Shade_Top.png", "look: ...with the gloss")
    eq(db.absorbBarTileMode, "BOTH", "look: layer 1's own Tile is not the look's to change")
    eq(db.absorbBarTileSize, 24, "look: ...nor its Tile Size")
    eq(db.absorbBarTexture, "keep-me", "look: the bar's own texture is untouched")
    eq(db.absorbBarColor, "keep-me-too", "look: the bar's own colour is untouched")
    check(db.absorbBarLayer2Color ~= LOOKS.DIAGONAL_GLOSS[2].color, "look: the colour is a copy, not the shared table")

    eq(db.absorbBarTextureLook, "DIAGONAL_GLOSS", "look: the pick is remembered")
    ApplyLook(db, "absorbBar", "GLOSS")
    eq(db.absorbBarLayer2Enabled, false, "look: a shading-only look turns the pattern layer off")
    ApplyLook(db, "absorbBar", "CUSTOM")
    eq(db.absorbBarLayer3Enabled, true, "look: picking Custom keeps the settings")
    eq(db.absorbBarTextureLook, "CUSTOM", "look: ...and records Custom")

    -- Every setting goes through the writer it is handed (the options' write bracket).
    local seen, n = {}, 0
    ApplyLook(db, "absorbBar", "DIAGONAL_GLOSS", function(key, value) seen[key] = value n = n + 1 end)
    eq(n, 15, "look: the pick and all fourteen layer settings go through the writer")
    eq(seen.absorbBarLayer2Enabled, true, "look: ...with their values")
    eq(db.absorbBarLayer2Enabled, false, "look: ...and nothing is written around it")
end

-- ---- the menu: Custom, a line, then every look A-Z --------------------------------
do
    local opts = LookOptions()
    local function text(id) local v = opts[id] return type(v) == "table" and v.text or v end
    eq(opts._order[1], "CUSTOM", "menu: Custom is the first entry")
    eq(opts[opts._order[2]].separatorAbove, true, "menu: ...with a line under it")
    local listed, prev = {}, nil
    for i = 2, #opts._order do
        local id = opts._order[i]
        check(LOOKS[id] ~= nil and text(id) ~= nil, "menu: " .. id .. " is a look with a label")
        if prev then check(prev < text(id), "menu: " .. id .. " is in A-Z order") end
        prev = text(id)
        listed[id] = true
    end
    for id in pairs(LOOKS) do check(listed[id], "menu: look " .. id .. " is in the order") end
end

-- ---- short lists ---------------------------------------------------------------
do
    local list = NewList()
    FillList(list, 2, false)
    local names = {}
    for _, v in pairs(list) do names[#names + 1] = v end
    table.sort(names)
    eq(table.concat(names, ", "), "DF Layer Diagonal", "pattern list: only textures that repeat both ways")

    FillList(list, 3, false)
    names = {}
    for _, v in pairs(list) do names[#names + 1] = v end
    table.sort(names)
    eq(table.concat(names, ", "), "DF Flat, DF Gradient H, DF Layer Shade Top",
        "shading list: along-the-bar textures, flat and gradients")

    eq(list["Interface\\AddOns\\Other\\bar.tga"], "Other Bar",
        "a texture outside the short list still shows its name on the button")

    FillList(list, 3, true)
    local n = 0
    for _ in pairs(list) do n = n + 1 end
    eq(n, 6, "Show All Textures: the whole list")
end

-- ---- the dots measure against the picked look -----------------------------------
do
    eq(DF.PartyDefaults.absorbBarTextureLook, "CUSTOM", "baseline: a bar starts on Custom")
    local base = DF.DEFAULT_BASELINES
    check(base.absorbBarTextureLayersEnabled == nil, "baseline: the switch keeps its shipped default")
    check(base.absorbBarTextureLook == nil, "baseline: so does the pick itself")
    check(base.absorbBarTexture == nil, "baseline: and the bar's own texture")

    local db = {}
    for key in pairs(DF.PartyDefaults) do db[key] = DF.PartyDefaults[key] end
    local function against(key) return base[key](db) end
    eq(against("absorbBarLayer2Enabled"), nil, "baseline: on Custom nothing is measured")

    ApplyLook(db, "absorbBar", "BEVEL")
    eq(against("absorbBarLayer3Enabled"), true, "baseline: the look's layer is on")
    eq(against("absorbBarLayer2Enabled"), false, "baseline: the layer it leaves out is off")
    eq(against("absorbBarLayer2Texture"), nil, "baseline: and that layer's other settings are not measured")
    eq(against("absorbBarLayer3Texture"), db.absorbBarLayer3Texture, "baseline: settings match right after the pick")
    eq(against("absorbBarLayer3Color").a, 0.3, "baseline: the colour is the look's")
    check(base.absorbBarTileMode == nil and base.absorbBarTileSize == nil,
          "baseline: layer 1's tiling is not measured against a look")
    db.absorbBarLayer3Color.a = 0.9
    eq(db.absorbBarTextureLook, "BEVEL", "baseline: an edit does not leave the look")
    eq(LOOKS.BEVEL[3].color.a, 0.3, "baseline: ...nor change the look itself")
    eq(against("healthLayer3Enabled"), nil, "baseline: another bar on Custom is not affected")
end
