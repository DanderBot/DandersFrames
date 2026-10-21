local addonName, DF = ...

-- ============================================================
-- TEXTURE LAYERS
-- ============================================================
-- Every bar keeps the texture it always had (the BASE layer) and may stack up to
-- two more on top -- fill + pattern, pattern + pattern, or either plus shading --
-- each with its own texture, colour, alpha, blend and tiling. Layers 2 and 3 sit
-- behind one switch per bar (<bar>TextureLayersEnabled, off by default): unticking it
-- restores the plain bar and keeps their settings for next time. The base layer's own
-- Tile and Tile Size belong to the bar's texture and apply whatever the switch says.
--
-- ☠ THE FILL'S SIZE IS NEVER READ. Absorb, heal absorb and reduced max health size
-- their fill from values that are SECRET in combat, so nothing here may measure it.
-- A clip frame is ANCHORED to the fill instead; the engine sizes it, and every layer
-- lives inside it, so a layer covers exactly the filled part in every bar mode.
--   * Native size (Auto, on a texture with no preset size): the texture is pinned to
--     the fill and tiles at its own pixel size, as Blizzard's raid frames do.
--   * Any other size -- the texture's preset, Custom, or Fit to Bar: the texture spans
--     the bar's FULL rect -- layout, never secret -- with repeating texcoords worked out
--     from that rect, and the clip frame cuts it to the fill. The pattern then holds
--     still while the fill grows and shrinks.
-- ============================================================

-- The bar list and layer numbers are defined with the defaults (Core/Config.lua).

-- Each bar's own texture key, so Auto can ask the registry for that texture's preset size.
local BASE_TEXTURE_KEY = {
    absorbBar = "absorbBarTexture", healAbsorbBar = "healAbsorbBarTexture",
    healPrediction = "healPredictionTexture", reducedMaxHealth = "reducedMaxHealthTexture",
    health = "healthTexture", resourceBar = "resourceBarTexture",
}

local KEYS = {}
for _, prefix in ipairs(DF.TEXTURE_LAYER_BARS) do
    local k = { on = prefix .. "TextureLayersEnabled", tex = BASE_TEXTURE_KEY[prefix],
                tileMode = prefix .. "TileMode", tileSize = prefix .. "TileSize" }
    for _, n in ipairs(DF.TEXTURE_LAYER_EXTRA) do
        local p = prefix .. "Layer" .. n
        k[n] = {
            enabled = p .. "Enabled", texture = p .. "Texture", color = p .. "Color",
            blend = p .. "BlendMode", tileMode = p .. "TileMode", tileSize = p .. "TileSize",
        }
    end
    KEYS[prefix] = k
end
DF.TEXTURE_LAYER_KEYS = KEYS

-- Drawn above the bar's own fill: the redrawn base first, then the two layers.
local SUBLEVEL = { base = 1, [2] = 3, [3] = 5 }

local issecretvalue = issecretvalue or function() return false end

local function Override(v)
    if v == nil or v == "AUTO" then return nil end
    return v
end

-- A stored Tile Size: above 0 is Custom, in pixels; FIT_TO_BAR makes one repeat as thick
-- as the bar; 0 is Auto -- the texture's preset size from the tiling registry, or its
-- file's own size (0, native) when it has none. Resolves to a pixel size, 0, or "FIT".
local FIT_TO_BAR = -1
DF.TILE_SIZE_FIT = FIT_TO_BAR

local function TileSize(v, path)
    v = tonumber(v)
    if v == FIT_TO_BAR then return "FIT" end
    if v and v > 0 then return v end
    return (path and DF.GetBarTextureTileSize and DF:GetBarTextureTileSize(path)) or 0
end

local function Sized(size) return size == "FIT" or size > 0 end

-- The user's own size (Custom or Fit) -- which asks a stretched texture to tile.
local function AskedSize(v)
    v = tonumber(v)
    return v == FIT_TO_BAR or (v ~= nil and v > 0)
end

-- True when this bar needs the layer pass: its own Tile or Tile Size does something,
-- or the switch is on with a layer ticked.
function DF:BarTextureLayersActive(db, prefix)
    local k = KEYS[prefix]
    if not (db and k) then return false end
    if Override(db[k.tileMode]) or Sized(TileSize(db[k.tileSize], k.tex and db[k.tex])) then return true end
    if not db[k.on] then return false end
    for _, n in ipairs(DF.TEXTURE_LAYER_EXTRA) do
        if db[k[n].enabled] then return true end
    end
    return false
end

-- Whether a caller needs to call ApplyBarTextureLayers at all: something is set, or
-- the bar still carries layer state that turning everything off must tear down.
-- Checked BEFORE building the options table, because some callers run per health tick.
function DF:BarTextureLayersWanted(bar, db, prefix)
    if not bar then return false end
    local state = bar.dfTextureLayers
    return (state ~= nil and state.active) or bar.dfTileOverride ~= nil
        or DF:BarTextureLayersActive(db, prefix)
end

-- For a caller that caches its layout and skips the rebuild while nothing changed:
-- whether this bar's layer settings moved since CacheBarTextureLayers filled `cache`.
-- Compares in place rather than building a key, because the absorb asks per event.
local function ColorParts(c)
    if type(c) ~= "table" then return nil, nil, nil, nil end
    return c.r, c.g, c.b, c.a
end

function DF:BarTextureLayersChanged(cache, db, prefix)
    local k = KEYS[prefix]
    if not (cache and k) then return true end
    if cache.tileMode ~= db[k.tileMode] or cache.tileSize ~= db[k.tileSize] then return true end
    local on = db[k.on] and true or false
    if cache.on ~= on then return true end
    if not on then return false end
    for _, n in ipairs(DF.TEXTURE_LAYER_EXTRA) do
        local kn, c = k[n], cache[n]
        if c.enabled ~= db[kn.enabled] or c.texture ~= db[kn.texture] or c.blend ~= db[kn.blend]
           or c.tileMode ~= db[kn.tileMode] or c.tileSize ~= db[kn.tileSize] then
            return true
        end
        local r, g, b, a = ColorParts(db[kn.color])
        if c.r ~= r or c.g ~= g or c.b ~= b or c.a ~= a then return true end
    end
    return false
end

function DF:CacheBarTextureLayers(cache, db, prefix)
    local k = KEYS[prefix]
    if not (cache and k) then return end
    cache.on = db[k.on] and true or false
    cache.tileMode, cache.tileSize = db[k.tileMode], db[k.tileSize]
    for _, n in ipairs(DF.TEXTURE_LAYER_EXTRA) do
        local kn = k[n]
        local c = cache[n] or {}
        cache[n] = c
        c.enabled, c.texture, c.blend = db[kn.enabled], db[kn.texture], db[kn.blend]
        c.tileMode, c.tileSize = db[kn.tileMode], db[kn.tileSize]
        c.r, c.g, c.b, c.a = ColorParts(db[kn.color])
    end
end

-- Repeating texcoords for the custom-size textures, from the span's (layout) size.
local function UpdateTexCoords(state)
    local span = state.span
    if not span then return end
    local w, h = span:GetWidth(), span:GetHeight()
    if issecretvalue(w) or issecretvalue(h) or not w or not h or w <= 0 or h <= 0 then return end
    for _, tex in pairs(state.textures) do
        local size = tex.dfCustomSize
        if size and tex:IsShown() then
            -- Fit to Bar: one repeat is the bar's thickness, re-derived on every resize.
            if size == "FIT" then size = state.isVertical and w or h end
            local unit = (DF.PixelPerfect and DF:PixelPerfect(size)) or size
            if unit <= 0 then unit = size end
            local mode = tex.dfTileModeApplied
            local u = (mode == "BOTH" or mode == "HORIZ") and (w / unit) or 1
            local v = (mode == "BOTH" or mode == "VERT") and (h / unit) or 1
            tex:SetTexCoord(0, u, 0, v)
        end
    end
end

-- One OnSizeChanged hook per span frame, fanning out to every bar using it.
local spanUsers = setmetatable({}, { __mode = "k" })
local function WatchSpan(state, span)
    if state.span == span then return end
    if state.span and spanUsers[state.span] then spanUsers[state.span][state] = nil end
    state.span = span
    if not span then return end
    local users = spanUsers[span]
    if not users then
        users = setmetatable({}, { __mode = "k" })
        spanUsers[span] = users
        span:HookScript("OnSizeChanged", function(f)
            for s in pairs(spanUsers[f]) do UpdateTexCoords(s) end
        end)
    end
    users[state] = true
end

local function EnsureState(bar, fill)
    local state = bar.dfTextureLayers
    if not state then
        local clip = CreateFrame("Frame", nil, bar)
        clip:SetClipsChildren(true)
        local canvas = CreateFrame("Frame", nil, clip)
        canvas:SetAllPoints(clip)
        state = { clip = clip, canvas = canvas, textures = {} }
        bar.dfTextureLayers = state
    end
    if state.fill ~= fill then
        state.clip:ClearAllPoints()
        state.clip:SetAllPoints(fill)
        state.fill = fill
        -- A new fill object arrives visible; the base pass below hides it again if needed.
        state.baseHidden = nil
    end
    local level = bar:GetFrameLevel()
    state.clip:SetFrameLevel(level + 1)
    state.canvas:SetFrameLevel(level + 1)
    return state
end

local function GetTexture(state, slot)
    local tex = state.textures[slot]
    if not tex then
        tex = state.canvas:CreateTexture(nil, "ARTWORK", nil, SUBLEVEL[slot])
        state.textures[slot] = tex
    end
    return tex
end

-- Put one texture on screen: file + wrap + tiling + geometry, then colour and blend.
local function PaintLayer(state, slot, path, tileOverride, tileSize, asked, color, blend, desaturate)
    local tex = GetTexture(state, slot)
    local mode = DF:ResolveTileMode(path, tileOverride)
    -- A size the user picked asks for tiling: a texture that would otherwise stretch
    -- tiles both ways, unless Tile is explicitly Off.
    if not mode and asked and tileOverride ~= "OFF" then mode = "BOTH" end
    local custom = (mode ~= nil and Sized(tileSize)) and tileSize or nil
    local span = custom and state.span or nil
    if tex.dfPath ~= path or tex.dfTileModeApplied ~= mode or tex.dfCustomSize ~= custom
       or tex.dfSpan ~= span then
        tex:ClearAllPoints()
        if custom then
            -- Wrap without the tile flags: the texcoords decide how many repeats.
            tex:SetTexture(path, "REPEAT", "REPEAT")
            tex:SetHorizTile(false)
            tex:SetVertTile(false)
            tex:SetPoint("TOPLEFT", state.span, "TOPLEFT")
            tex:SetPoint("BOTTOMRIGHT", state.span, "BOTTOMRIGHT")
        else
            tex:SetAllPoints(state.clip)
            if mode then
                tex:SetTexture(path, DF.TileWrapArgs(mode))
            else
                tex:SetTexture(path)
            end
            tex:SetHorizTile(mode == "BOTH" or mode == "HORIZ")
            tex:SetVertTile(mode == "BOTH" or mode == "VERT")
            if not mode then tex:SetTexCoord(0, 1, 0, 1) end
        end
        tex.dfPath, tex.dfTileModeApplied, tex.dfCustomSize, tex.dfSpan = path, mode, custom, span
    end
    local c = color or {}
    tex:SetVertexColor(c.r or 1, c.g or 1, c.b or 1, c.a or 1)
    tex:SetBlendMode(blend or "BLEND")
    tex:SetDesaturated(desaturate and true or false)
    tex:Show()
end

local function Teardown(bar, state)
    state.active = false
    state.clip:Hide()
    for _, tex in pairs(state.textures) do tex:Hide() end
    if state.baseHidden and state.fill then
        state.fill:SetAlpha(1)
        state.baseHidden = nil
    end
end

-- Apply a bar's layer settings. Cheap when nothing is set: a few db reads and out.
--   opts.span        the frame a sized repeat measures, Fit to Bar included (default:
--                    the bar)
--   opts.isVertical  the bar fills vertically (picks vertical companions; restores
--                    rotation if the Tile override changes)
--   opts.baseColor   the bar's own fill colour {r,g,b,a}. Supplying it allows a
--                    custom tile size on the BASE layer, which needs the fill
--                    redrawn here; bars whose colour other code changes per update
--                    leave it nil and keep their base at native size.
--   opts.baseBlend, opts.baseDesaturated   carried over to the redrawn base
function DF:ApplyBarTextureLayers(bar, prefix, db, opts)
    local k = KEYS[prefix]
    if not (bar and k and db and bar.GetStatusBarTexture) then return end
    opts = opts or {}

    -- The base layer's own Tile override rides the shared tiling path, so every
    -- later re-set of the file keeps honouring it.
    local on = db[k.on] and true or false
    local override = Override(db[k.tileMode])
    if bar.dfTileOverride ~= override then
        bar.dfTileOverride = override
        if bar.dfAppliedTexture then
            DF:ApplyBarTextureTiling(bar, bar.dfAppliedTexture)
        end
        if opts.isVertical ~= nil then
            DF:ApplyBarFillOrientation(bar, opts.isVertical)
        end
    end

    local basePath = bar.dfAppliedTexture
    local baseSize = (opts.baseColor and override ~= "OFF")
        and TileSize(db[k.tileSize], bar.dfBaseTexture or basePath) or 0
    local any = Sized(baseSize)
    if on and not any then
        for _, n in ipairs(DF.TEXTURE_LAYER_EXTRA) do
            if db[k[n].enabled] then any = true break end
        end
    end
    local state = bar.dfTextureLayers
    if not any then
        if state then Teardown(bar, state) end
        return
    end

    local fill = bar:GetStatusBarTexture()
    if not fill then return end
    state = EnsureState(bar, fill)
    WatchSpan(state, opts.span or bar)
    state.isVertical = opts.isVertical and true or false
    state.active = true
    state.clip:Show()

    -- Base at a custom size: hide the bar's own fill and redraw it here, so the
    -- engine-sized fill still decides WHERE it shows while we decide how it repeats.
    if Sized(baseSize) and basePath then
        PaintLayer(state, "base", basePath, override, baseSize, AskedSize(db[k.tileSize]),
            opts.baseColor, opts.baseBlend, opts.baseDesaturated)
        if not state.baseHidden then
            fill:SetAlpha(0)
            state.baseHidden = true
        end
    else
        if state.textures.base then state.textures.base:Hide() end
        if state.baseHidden then
            fill:SetAlpha(1)
            state.baseHidden = nil
        end
    end

    for _, n in ipairs(DF.TEXTURE_LAYER_EXTRA) do
        local kn = k[n]
        if on and db[kn.enabled] and db[kn.texture] then
            local path = DF:ResolveBarTexture(db[kn.texture], opts.isVertical)
            PaintLayer(state, n, path, Override(db[kn.tileMode]), TileSize(db[kn.tileSize], path),
                AskedSize(db[kn.tileSize]), db[kn.color], db[kn.blend])
        elseif state.textures[n] then
            state.textures[n]:Hide()
        end
    end

    UpdateTexCoords(state)
end
