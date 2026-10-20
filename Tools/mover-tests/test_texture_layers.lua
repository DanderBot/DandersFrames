-- ============================================================
-- TEXTURE LAYERS (DandersFrames/Frames/TextureLayers.lua)
-- Loaded REAL into a fresh namespace, with the tiling resolvers lifted from
-- Core.lua by their source text. Frames and textures are recording fakes.
-- ============================================================

local saved = {}
local function stub(name, value) saved[name] = _G[name]; _G[name] = value end
local function restore() for k, v in pairs(saved) do _G[k] = v end; saved = {} end

-- ---- fakes -------------------------------------------------------------------
local function FakeTexture()
    local t = { shown = false, points = {}, calls = {} }
    function t:SetTexture(path, h, v) self.path, self.wrapH, self.wrapV = path, h, v; self.calls[#self.calls + 1] = "SetTexture" end
    function t:SetHorizTile(b) self.htile = b end
    function t:SetVertTile(b) self.vtile = b end
    function t:SetTexCoord(l, r, top, b) self.tc = { l, r, top, b } end
    function t:SetVertexColor(r, g, b, a) self.color = { r, g, b, a } end
    function t:SetBlendMode(m) self.blend = m end
    function t:SetDesaturated(d) self.desat = d end
    function t:Show() self.shown = true end
    function t:Hide() self.shown = false end
    function t:IsShown() return self.shown end
    function t:ClearAllPoints() self.points = {} end
    function t:SetAllPoints(f) self.points = { all = f } end
    function t:SetPoint(p, rel) self.points[p] = rel end
    function t:SetAlpha(a) self.alpha = a end
    return t
end

local function FakeFrame(w, h)
    local f = { shown = true, level = 5, w = w or 100, h = h or 20, points = {}, hooks = {}, regions = {} }
    function f:SetClipsChildren(b) self.clips = b end
    function f:SetAllPoints(rel) self.points = { all = rel } end
    function f:ClearAllPoints() self.points = {} end
    function f:SetPoint(p, rel) self.points[p] = rel end
    function f:SetFrameLevel(l) self.level = l end
    function f:GetFrameLevel() return self.level end
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:GetWidth() return self.w end
    function f:GetHeight() return self.h end
    function f:HookScript(script, fn) self.hooks[script] = fn end
    function f:CreateTexture() local t = FakeTexture(); self.regions[#self.regions + 1] = t; return t end
    return f
end

local function FakeBar(path)
    local bar = FakeFrame(120, 30)
    local fill = FakeTexture()
    fill.alpha = 1
    bar.fill = fill
    bar.dfAppliedTexture = path
    function bar:GetStatusBarTexture() return self.fill end
    return bar
end

-- ---- load -----------------------------------------------------------------------
local MEDIA = "Interface\\AddOns\\DandersFrames\\Media\\"
local PATTERN = MEDIA .. "DF_Layer_Diagonal.png"
local PATTERN_V = MEDIA .. "DF_Layer_Diagonal_Vert.png"
local SHADE = MEDIA .. "DF_Layer_Shade_Top.png"
local STRETCHED = MEDIA .. "DF_Minimalist"

local calls
local function load()
    calls = { tiling = 0, orientation = 0 }
    stub("CreateFrame", function(_, _, parent) return FakeFrame() end)
    stub("issecretvalue", function(v) return v == "SECRET" end)
    local DF = {
        TEXTURE_LAYER_BARS = { "absorbBar", "health" },
        TEXTURE_LAYER_EXTRA = { 2, 3 },
        TILED_BAR_TEXTURES = { [PATTERN] = "BOTH", [PATTERN_V] = "BOTH", [SHADE] = "HORIZ" },
        TILED_VERTICAL_COMPANION = { [PATTERN] = PATTERN_V },
        TileWrapArgs = function(mode)
            return (mode == "BOTH" or mode == "HORIZ") and "REPEAT" or "CLAMP",
                   (mode == "BOTH" or mode == "VERT") and "REPEAT" or "CLAMP"
        end,
        PixelPerfect = function(_, v) return v end,
    }
    function DF:ResolveBarTexture(path, isVertical)
        if isVertical then return self.TILED_VERTICAL_COMPANION[path] or path end
        return path
    end
    function DF:ApplyBarTextureTiling(bar, path) calls.tiling = calls.tiling + 1; calls.tilingOverride = bar.dfTileOverride end
    function DF:ApplyBarFillOrientation(bar, isVertical) calls.orientation = calls.orientation + 1 end
    -- the REAL resolvers, by their source text
    local core = df_file_source("Core.lua")
    local a = core:find("function DF:GetBarTextureTiling(path)", 1, true)
    local b = core:find("local function tileWrapArgs", a, true)
    check(a and b, "setup: lifted the tiling resolvers from Core.lua")
    assert(loadstring("local DF = ...\n" .. core:sub(a, b - 1), "@resolvers"))(DF)
    load_df_file_into("Frames/TextureLayers.lua", DF)
    return DF
end

-- The per-bar switch is ticked unless a case is about the switch itself.
local function defaults(switchOff)
    local db = {}
    for _, prefix in ipairs({ "absorbBar", "health" }) do
        db[prefix .. "TextureLayersEnabled"] = not switchOff
        db[prefix .. "TileMode"] = "AUTO"
        db[prefix .. "TileSize"] = 0
        for _, n in ipairs({ 2, 3 }) do
            local p = prefix .. "Layer" .. n
            db[p .. "Enabled"] = false
            db[p .. "Texture"] = (n == 2) and PATTERN or SHADE
            db[p .. "Color"] = { r = 1, g = 1, b = 1, a = 0.5 }
            db[p .. "BlendMode"] = "BLEND"
            db[p .. "TileMode"] = "AUTO"
            db[p .. "TileSize"] = 0
        end
    end
    return db
end

local function layerTex(bar, slot) return bar.dfTextureLayers and bar.dfTextureLayers.textures[slot] end

-- ------------------------------------------------------------
-- 1. Defaults change nothing
-- ------------------------------------------------------------
do
    local DF = load()
    local db, bar = defaults(true), FakeBar(STRETCHED)
    eq(DF:BarTextureLayersActive(db, "absorbBar"), false, "defaults: nothing active")
    eq(DF:BarTextureLayersWanted(bar, db, "absorbBar"), false, "defaults: callers skip the call entirely")
    DF:ApplyBarTextureLayers(bar, "absorbBar", db, { baseColor = { r = 1, g = 0, b = 0, a = 1 } })
    eq(bar.dfTextureLayers, nil, "defaults: no frames are created")
    eq(calls.tiling, 0, "defaults: the bar's tiling is not touched")
    eq(bar.fill.alpha, 1, "defaults: the bar's own fill stays visible")
    restore()
end

-- ------------------------------------------------------------
-- 2. A layer at native size sits on the fill and tiles at its own size
-- ------------------------------------------------------------
do
    local DF = load()
    local db, bar = defaults(), FakeBar(STRETCHED)
    db.absorbBarLayer2Enabled = true
    db.absorbBarLayer2Color = { r = 0.2, g = 0.4, b = 0.6, a = 0.7 }
    db.absorbBarLayer2BlendMode = "ADD"
    DF:ApplyBarTextureLayers(bar, "absorbBar", db, { span = FakeFrame(200, 40) })
    local st = bar.dfTextureLayers
    check(st ~= nil and st.clip.clips == true, "native: a clipping frame is built")
    eq(st.clip.points.all, bar.fill, "native: ...anchored to the fill, never measuring it")
    local t = layerTex(bar, 2)
    eq(t.points.all, st.clip, "native: the texture fills the clip area")
    eq(t.path, PATTERN, "native: the chosen texture")
    eq(t.wrapH .. "/" .. t.wrapV, "REPEAT/REPEAT", "native: wrap set with the file, from the texture's own mode")
    check(t.htile and t.vtile, "native: tiled both ways")
    eq(table.concat(t.color, ","), "0.2,0.4,0.6,0.7", "native: the layer's colour and alpha")
    eq(t.blend, "ADD", "native: the layer's blend")
    eq(t.shown, true, "native: shown")
    eq(bar.fill.alpha, 1, "native: the base fill is untouched")
    eq(layerTex(bar, 3), nil, "native: layer 3 stays unbuilt while off")
    restore()
end

-- ------------------------------------------------------------
-- 3. A custom tile size spans the bar's full rect with repeating texcoords
-- ------------------------------------------------------------
do
    local DF = load()
    local db, bar, span = defaults(), FakeBar(STRETCHED), FakeFrame(200, 40)
    db.absorbBarLayer2Enabled = true
    db.absorbBarLayer2TileSize = 20
    DF:ApplyBarTextureLayers(bar, "absorbBar", db, { span = span })
    local t = layerTex(bar, 2)
    eq(t.points.TOPLEFT, span, "custom: anchored to the span (TOPLEFT)")
    eq(t.points.BOTTOMRIGHT, span, "custom: ...and BOTTOMRIGHT")
    check(not t.htile and not t.vtile, "custom: no tile flags -- the texcoords decide the repeats")
    eq(t.wrapH .. "/" .. t.wrapV, "REPEAT/REPEAT", "custom: repeating wrap")
    eq(t.tc[2], 10, "custom: 200 wide / 20 = 10 repeats across")
    eq(t.tc[4], 2, "custom: 40 tall / 20 = 2 repeats down")
    span.w = 300
    span.hooks.OnSizeChanged(span)
    eq(t.tc[2], 15, "custom: a span resize re-derives the repeats")
    span.w = "SECRET"
    local ok = pcall(span.hooks.OnSizeChanged, span)
    check(ok, "custom: a secret size is skipped, not compared")
    eq(t.tc[2], 15, "custom: ...and the last good texcoords stay")
    restore()
end

do  -- shading tiles along the bar only, so a custom size repeats horizontally only
    local DF = load()
    local db, bar, span = defaults(), FakeBar(STRETCHED), FakeFrame(200, 40)
    db.absorbBarLayer3Enabled = true
    db.absorbBarLayer3TileSize = 50
    DF:ApplyBarTextureLayers(bar, "absorbBar", db, { span = span })
    local t = layerTex(bar, 3)
    eq(t.tc[2], 4, "shading: repeats along the bar")
    eq(t.tc[4], 1, "shading: stretched across it")
    restore()
end

do  -- a tile size on a stretched texture asks for tiling; Tile Off refuses it
    local DF = load()
    local db, bar = defaults(), FakeBar(STRETCHED)
    db.absorbBarLayer2Enabled = true
    db.absorbBarLayer2Texture = STRETCHED
    db.absorbBarLayer2TileSize = 10
    DF:ApplyBarTextureLayers(bar, "absorbBar", db, { span = FakeFrame(100, 20) })
    eq(layerTex(bar, 2).tc[2], 10, "a tile size tiles a stretched texture both ways")
    db.absorbBarLayer2TileMode = "OFF"
    DF:ApplyBarTextureLayers(bar, "absorbBar", db, { span = FakeFrame(100, 20) })
    local t = layerTex(bar, 2)
    check(not t.htile and not t.vtile and t.tc[2] == 1, "Tile Off stretches, whatever the size")
    restore()
end

-- ------------------------------------------------------------
-- 4. The base layer at a custom size, and its alpha handover
-- ------------------------------------------------------------
do
    local DF = load()
    local db, bar = defaults(), FakeBar(PATTERN)
    db.absorbBarTileSize = 32
    local color = { r = 0, g = 0.8, b = 1, a = 0.7 }
    DF:ApplyBarTextureLayers(bar, "absorbBar", db, { span = FakeFrame(64, 32), baseColor = color, baseBlend = "BLEND" })
    local base = layerTex(bar, "base")
    eq(base and base.path, PATTERN, "base size: the bar's own texture is redrawn")
    eq(table.concat(base.color, ","), "0,0.8,1,0.7", "base size: in the bar's own colour")
    eq(base.tc[2], 2, "base size: at the custom size")
    eq(bar.fill.alpha, 0, "base size: the engine fill is hidden, still deciding where it shows")
    db.absorbBarTileSize = 0
    DF:ApplyBarTextureLayers(bar, "absorbBar", db, { baseColor = color })
    eq(bar.fill.alpha, 1, "base size back to native: the fill is shown again")
    eq(base.shown, false, "base size back to native: the redraw is hidden")

    -- the game can swap the fill object when the texture is re-set
    db.absorbBarTileSize = 32
    DF:ApplyBarTextureLayers(bar, "absorbBar", db, { span = FakeFrame(64, 32), baseColor = color })
    local fresh = FakeTexture()
    fresh.alpha = 1
    bar.fill = fresh
    DF:ApplyBarTextureLayers(bar, "absorbBar", db, { span = FakeFrame(64, 32), baseColor = color })
    eq(fresh.alpha, 0, "base size: a swapped-in fill is hidden too, so nothing draws twice")
    eq(bar.dfTextureLayers.clip.points.all, fresh, "base size: ...and the clip follows the new fill")
    restore()
end

do  -- bars without a fixed colour keep their base at native size
    local DF = load()
    local db, bar = defaults(), FakeBar(PATTERN)
    db.healthTileSize = 32
    DF:ApplyBarTextureLayers(bar, "health", db, { span = FakeFrame(64, 32) })
    eq(bar.fill.alpha, 1, "no baseColor: the fill is never hidden")
    eq(layerTex(bar, "base"), nil, "no baseColor: no redraw")
    restore()
end

-- ------------------------------------------------------------
-- 5. The base Tile override rides the shared tiling path
-- ------------------------------------------------------------
do
    local DF = load()
    local db, bar = defaults(), FakeBar(STRETCHED)
    db.healthTileMode = "HORIZ"
    eq(DF:BarTextureLayersWanted(bar, db, "health"), true, "override: wanted")
    DF:ApplyBarTextureLayers(bar, "health", db, { isVertical = false })
    eq(bar.dfTileOverride, "HORIZ", "override: stamped on the bar for the safe setters")
    eq(calls.tiling, 1, "override: the fill's tiling is re-applied")
    eq(calls.tilingOverride, "HORIZ", "override: ...with the new mode")
    eq(calls.orientation, 1, "override: rotation re-decided")
    DF:ApplyBarTextureLayers(bar, "health", db, { isVertical = false })
    eq(calls.tiling, 1, "override: unchanged, so not re-applied")
    db.healthTileMode = "AUTO"
    DF:ApplyBarTextureLayers(bar, "health", db, { isVertical = false })
    eq(bar.dfTileOverride, nil, "override back to Default: cleared")
    eq(calls.tiling, 2, "override back to Default: the texture's own tiling restored")
    eq(DF:BarTextureLayersWanted(bar, db, "health"), false, "override back to Default: callers skip again")
    restore()
end

do  -- the resolver itself
    local DF = load()
    eq(DF:ResolveTileMode(STRETCHED, nil), nil, "resolver: Default on a stretched texture stretches")
    eq(DF:ResolveTileMode(PATTERN, "AUTO"), "BOTH", "resolver: Default follows the registry")
    eq(DF:ResolveTileMode(PATTERN, "OFF"), nil, "resolver: Off wins over the registry")
    eq(DF:ResolveTileMode(STRETCHED, "VERT"), "VERT", "resolver: the user's mode wins on any texture")
    restore()
end

-- ------------------------------------------------------------
-- 6. Teardown, and vertical companions
-- ------------------------------------------------------------
do
    local DF = load()
    local db, bar = defaults(), FakeBar(STRETCHED)
    db.absorbBarLayer2Enabled = true
    DF:ApplyBarTextureLayers(bar, "absorbBar", db, {})
    db.absorbBarLayer2Enabled = false
    DF:ApplyBarTextureLayers(bar, "absorbBar", db, {})
    eq(bar.dfTextureLayers.clip.shown, false, "teardown: the clip frame hides")
    eq(layerTex(bar, 2).shown, false, "teardown: the layer hides")
    eq(DF:BarTextureLayersWanted(bar, db, "absorbBar"), false, "teardown: callers skip again afterwards")
    restore()
end

do
    local DF = load()
    local db, bar = defaults(), FakeBar(STRETCHED)
    db.absorbBarLayer2Enabled = true
    DF:ApplyBarTextureLayers(bar, "absorbBar", db, { isVertical = true })
    eq(layerTex(bar, 2).path, PATTERN_V, "vertical: a leaning pattern swaps to its companion")
    restore()
end

-- ------------------------------------------------------------
-- 7. The per-bar switch
-- ------------------------------------------------------------
do  -- unticked, every other setting is ignored
    local DF = load()
    local db, bar = defaults(true), FakeBar(STRETCHED)
    db.absorbBarLayer2Enabled = true
    db.absorbBarTileMode = "BOTH"
    db.absorbBarTileSize = 16
    eq(DF:BarTextureLayersActive(db, "absorbBar"), false, "switch off: nothing counts as active")
    eq(DF:BarTextureLayersWanted(bar, db, "absorbBar"), false, "switch off: callers skip the call")
    DF:ApplyBarTextureLayers(bar, "absorbBar", db, { baseColor = { r = 1, g = 1, b = 1, a = 1 } })
    eq(bar.dfTextureLayers, nil, "switch off: no layers built")
    eq(bar.dfTileOverride, nil, "switch off: the Tile override is not applied")
    eq(bar.fill.alpha, 1, "switch off: the bar's fill stays visible")
    restore()
end

do  -- unticking after use restores the plain bar and keeps the settings
    local DF = load()
    local db, bar = defaults(), FakeBar(PATTERN)
    db.absorbBarLayer2Enabled = true
    db.absorbBarTileMode = "HORIZ"
    db.absorbBarTileSize = 16
    local color = { r = 1, g = 1, b = 1, a = 1 }
    DF:ApplyBarTextureLayers(bar, "absorbBar", db, { span = FakeFrame(64, 32), baseColor = color, isVertical = false })
    eq(bar.fill.alpha, 0, "switch on: the base is redrawn at its size")
    db.absorbBarTextureLayersEnabled = false
    DF:ApplyBarTextureLayers(bar, "absorbBar", db, { span = FakeFrame(64, 32), baseColor = color, isVertical = false })
    eq(bar.fill.alpha, 1, "switch off again: the engine fill is back")
    eq(bar.dfTileOverride, nil, "switch off again: the Tile override is cleared")
    eq(bar.dfTextureLayers.clip.shown, false, "switch off again: the layers are gone")
    eq(DF:BarTextureLayersWanted(bar, db, "absorbBar"), false, "switch off again: callers skip again")
    eq(db.absorbBarLayer2Enabled, true, "switch off again: the layer settings are kept for next time")
    restore()
end

-- ------------------------------------------------------------
-- 8. The layout-cache compare (the absorb skips its rebuild on it)
-- ------------------------------------------------------------
do
    local DF = load()
    local db, cache = defaults(), {}
    eq(DF:BarTextureLayersChanged(nil, db, "absorbBar"), true, "cache: nothing cached yet counts as changed")
    DF:CacheBarTextureLayers(cache, db, "absorbBar")
    eq(DF:BarTextureLayersChanged(cache, db, "absorbBar"), false, "cache: unchanged settings match")
    local steps = {
        { "absorbBarLayer2Enabled", true }, { "absorbBarLayer3Texture", "other" },
        { "absorbBarLayer2BlendMode", "ADD" }, { "absorbBarLayer3TileMode", "BOTH" },
        { "absorbBarLayer2TileSize", 24 }, { "absorbBarTileMode", "HORIZ" }, { "absorbBarTileSize", 8 },
    }
    for _, step in ipairs(steps) do
        db[step[1]] = step[2]
        eq(DF:BarTextureLayersChanged(cache, db, "absorbBar"), true, "cache: " .. step[1] .. " counts")
        DF:CacheBarTextureLayers(cache, db, "absorbBar")
    end
    db.absorbBarLayer3Color.a = 0.9
    eq(DF:BarTextureLayersChanged(cache, db, "absorbBar"), true, "cache: a colour edited in place counts")
    DF:CacheBarTextureLayers(cache, db, "absorbBar")
    db.absorbBarTextureLayersEnabled = false
    eq(DF:BarTextureLayersChanged(cache, db, "absorbBar"), true, "cache: the switch counts")
    DF:CacheBarTextureLayers(cache, db, "absorbBar")
    db.absorbBarLayer2BlendMode = "MOD"
    eq(DF:BarTextureLayersChanged(cache, db, "absorbBar"), false, "cache: with the switch off, layer edits do not")
    restore()
end

