local DF = DandersFrames
local GUI = DF.GUI
local L = DF.L

-- ============================================================
-- TEXTURE LAYER CONTROLS
-- ============================================================
-- One builder for the Texture Layers section every bar card ends with
-- (Frames/TextureLayers.lua), so six cards cannot drift apart. A basic user sees one
-- tick per card; ticking it opens the section, and ticking a layer opens that layer.
-- The tick is the bar's real switch, not a view preference: a section that is closed
-- is also switched off, so no hidden setting can change a bar.
--   add(widget, height)   the card's own AddWidget wrapper
--   opts.baseSize         the bar can repeat its own texture at a custom size
--                         (false for bars whose colour other code sets per update)
--   opts.refreshStates    the page's state pass, so a layer tick shows its controls
-- The bar's own Tile and Tile Size are not in the section: GUI:AddBarTileControls puts
-- them with the bar's texture, since they apply whether or not the layers are on.
-- ============================================================

-- Each bar's own texture, colour and blend, for the preview strip.
local BAR = {
    absorbBar        = { texture = "absorbBarTexture", color = "absorbBarColor", blend = "absorbBarBlendMode" },
    healAbsorbBar    = { texture = "healAbsorbBarTexture", color = "healAbsorbBarColor", blend = "healAbsorbBarBlendMode" },
    healPrediction   = { texture = "healPredictionTexture", color = "healPredictionMyColor", blend = "healPredictionBlendMode" },
    reducedMaxHealth = { texture = "reducedMaxHealthTexture", color = "reducedMaxHealthColor", blend = "reducedMaxHealthBlendMode" },
    health           = { texture = "healthTexture", color = "healthColor" },
    resourceBar      = { texture = "resourceBarTexture" },
}

local function TileOptions()
    return {
        AUTO  = L["Auto (texture's own)"],
        OFF   = L["Off (Stretch)"],
        BOTH  = L["Both Directions"],
        HORIZ = L["Horizontal"],
        VERT  = L["Vertical"],
    }
end

local function BlendOptions()
    return {
        BLEND = L["Normal (BLEND)"],
        ADD   = L["Additive (ADD)"],
        MOD   = L["Multiply (MOD)"],
    }
end

local function TileTooltip()
    return L["How the texture repeats. Auto uses the texture's own setting (DandersFrames' patterned textures repeat, everything else stretches); Off stretches it to fit; the others repeat it in those directions."]
end

local function MirrorTooltip()
    return L["Leans the texture's stripes the other way."]
end

local function TileSizeTooltip()
    return L["How big one repeat of the texture is drawn. Auto uses the texture's own preset size; Fit to Bar makes one repeat as thick as the bar; Custom sets it in pixels."]
end

-- ============================================================
-- TILE SIZE: a choice plus a slider over ONE stored number
-- ============================================================
-- 0 = Auto, -1 = Fit to Bar, above 0 = Custom (Frames/TextureLayers.lua). The menu's
-- option keys ARE those numbers and the getter returns the stored one, so the raid
-- redirect, undo and the changed dot all see the real value; every size above 0 reads
-- "Custom" through the options' fallback. CUSTOM is the menu row standing for a custom
-- size: picking it starts from the texture's preset size, or 32, and the slider takes
-- over from there.
local FIT = DF.TILE_SIZE_FIT or -1
local CUSTOM = 32

local function TileSizeOptions()
    return setmetatable({
        _order = { 0, FIT, CUSTOM },
        [0] = L["Auto (texture's own)"],
        [FIT] = L["Fit to Bar"],
        [CUSTOM] = L["Custom"],
    }, { __index = function(_, k) if type(k) == "number" and k > 0 then return L["Custom"] end end })
end

-- pathOf(db) names the texture whose preset size a fresh Custom starts from; hidden(db)
-- hides both rows; refresh(statesToo) repaints.
local function AddTileSize(add, parent, db, key, pathOf, hidden, refresh)
    local function current() return tonumber(db[key]) or 0 end
    local function startSize()
        local path = pathOf and pathOf(db)
        return (path and DF.GetBarTextureTileSize and DF:GetBarTextureTileSize(path)) or CUSTOM
    end
    local choice = add(GUI:CreateDropdown(parent, L["Tile Size"], TileSizeOptions(), db, key,
        function() refresh(true) end,
        current,
        function(id)
            if id == CUSTOM then
                if current() <= 0 then db[key] = startSize() end
            else
                db[key] = id
            end
        end), 55)
    choice.tooltip = TileSizeTooltip()
    choice.hideOn = hidden
    local size = add(GUI:CreateSlider(parent, L["Size"], 4, 128, 1, db, key, function() refresh(false) end), 55)
    size.hideOn = function(d) return hidden(d) or (tonumber(d[key]) or 0) <= 0 end
    return choice, size
end

-- ============================================================
-- QUICK START LOOKS
-- ============================================================
-- The looks themselves are defined with the defaults (Core/Config.lua), because the
-- changed-dots measure against them. Custom first, then a line, then the presets A-Z
-- by their (localised) names.
local function LookOptions()
    local opts = {
        DIAGONAL       = L["Diagonal Pattern"],
        DOTS           = L["Dots Pattern"],
        GRID           = L["Grid Pattern"],
        GLOSS          = L["Gloss"],
        BEVEL          = L["Bevel"],
        TUBE           = L["Tube"],
        SHADOW         = L["Shadow"],
        DIAGONAL_GLOSS = L["Diagonal Pattern + Gloss"],
    }
    local ids = {}
    for id in pairs(opts) do ids[#ids + 1] = id end
    table.sort(ids, function(x, y) return opts[x] < opts[y] end)
    opts[ids[1]] = { text = opts[ids[1]], separatorAbove = true }
    table.insert(ids, 1, "CUSTOM")
    opts.CUSTOM = L["Custom"]
    opts._order = ids
    return opts
end

-- Records the pick and, for a look, writes the settings it owns. Custom keeps every
-- setting as it is: it only stops the dots measuring against a look.
-- `write(key, value)` lands each setting; plain assignment when omitted.
local function ApplyLook(db, prefix, id, write)
    if id ~= "CUSTOM" and not DF.TEXTURE_LAYER_LOOKS[id] then return end
    write = write or function(key, value) db[key] = value end
    write(prefix .. "TextureLook", id)
    if id == "CUSTOM" then return end
    for _, key in ipairs(DF.TEXTURE_LOOK_KEYS[prefix]) do
        local v = DF:TextureLookValue(id, key)
        if type(v) == "table" then v = { r = v.r, g = v.g, b = v.b, a = v.a } end
        if v ~= nil then write(key, v) end
    end
end

-- ============================================================
-- SHORT TEXTURE LISTS
-- ============================================================
-- The Pattern layer opens on textures that repeat both ways, the Shading layer on
-- ones that repeat along the bar (plus flat and gradients). Read from the tiling
-- registry, so a new tiled texture lands in the right list without touching this.
--   ☠ THE TABLE ONLY LISTS THE SHORT SET; ANY OTHER PATH STILL GETS A NAME. pairs()
-- (the menu) ignores __index, the button's label lookup does not -- so a texture
-- picked from "Show All Textures" keeps its name after the list shrinks back.
local function ShortList(n)
    local list = {}
    for path, name in pairs(DF:GetTextureList()) do
        local mode = DF.TILED_BAR_TEXTURES and DF.TILED_BAR_TEXTURES[path]
        local keep
        if n == 2 then
            keep = mode == "BOTH"
        else
            keep = mode == "HORIZ" or path == "Interface\\Buttons\\WHITE8x8"
                or (type(path) == "string" and path:find("DF_Gradient_", 1, true) ~= nil)
        end
        if keep then list[path] = name end
    end
    return list
end

local function NewList()
    return setmetatable({}, { __index = function(_, path)
        return DF.GetTextureNameFromPath and DF:GetTextureNameFromPath(path) or nil
    end })
end

local function FillList(list, n, showAll)
    for k in pairs(list) do rawset(list, k, nil) end
    local source = showAll and DF:GetTextureList() or ShortList(n)
    for path, name in pairs(source) do rawset(list, path, name) end
end

-- ============================================================
-- PREVIEW STRIP
-- ============================================================
-- A sample bar, 60% full, drawn by the SAME code as the frames (the safe texture
-- setter and DF:ApplyBarTextureLayers), so it differs from a real bar only in data.
local function PreviewColor(db, prefix)
    local spec = BAR[prefix]
    if prefix == "health" and db.healthColorMode == "CLASS" then
        local _, class = UnitClass("player")
        local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
        if c then return { r = c.r, g = c.g, b = c.b, a = 1 } end
    end
    if prefix == "resourceBar" then
        local c = PowerBarColor and PowerBarColor["MANA"]
        if c then return { r = c.r, g = c.g, b = c.b, a = 1 } end
        return { r = 0, g = 0.44, b = 0.87, a = 1 }
    end
    local c = spec and spec.color and db[spec.color]
    if type(c) == "table" then return c end
    return { r = 0.3, g = 0.7, b = 0.3, a = 1 }
end

local function CreatePreview(parent, db, prefix, baseSize)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 54)
    local label = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    label:SetPoint("TOPLEFT", 0, 0)
    label:SetText(L["Preview"])
    local text = GUI.Colors and GUI.Colors.textDim
    if text then label:SetTextColor(text.r, text.g, text.b) end
    local bg = container:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", 0, -16)
    bg:SetPoint("BOTTOMRIGHT", 0, 14)
    bg:SetColorTexture(0.08, 0.08, 0.08, 1)
    local bar = CreateFrame("StatusBar", nil, container)
    bar:SetPoint("TOPLEFT", bg, "TOPLEFT", 1, -1)
    bar:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", -1, 1)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0.6)

    function container:Refresh()
        local spec = BAR[prefix] or {}
        local path = (spec.texture and db[spec.texture]) or DF.STOCK_BAR_TEXTURE
        DF:SafeSetStatusBarTexture(bar, path)
        local c = PreviewColor(db, prefix)
        bar:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
        local blend = spec.blend and db[spec.blend] or "BLEND"
        local fill = bar:GetStatusBarTexture()
        if fill then fill:SetBlendMode(blend) end
        DF:ApplyBarTextureLayers(bar, prefix, db, {
            span = bar, isVertical = false,
            baseColor = baseSize and c or nil, baseBlend = blend,
        })
    end
    container.refreshContent = function(self) self:Refresh() end
    container:Refresh()
    return container
end

-- ============================================================
-- THE SECTION
-- ============================================================
function GUI:AddTextureLayerControls(addToCard, parent, db, prefix, opts)
    opts = opts or {}
    local switch = prefix .. "TextureLayersEnabled"
    local function closed(d) return not d[switch] end

    -- ☠ A LOOK WRITES SETTINGS BEHIND THE CONTROLS' BACKS. The page's state pass
    -- re-runs show/hide but not values, so after a look the ticks, textures and
    -- colours kept showing the previous settings (a layer looked ticked yet would
    -- not open). Every control here re-reads its value -- and its dot, which now
    -- measures against the new pick -- after a look instead.
    local controls = {}
    local function add(widget, height)
        local w = addToCard(widget, height)
        controls[#controls + 1] = w
        return w
    end
    local function refreshValues()
        for _, w in ipairs(controls) do
            if w.refreshValue then w.refreshValue(w) end
            if rawget(w, "UpdateModifiedDot") then w:UpdateModifiedDot() end
        end
    end

    local preview, look
    local function refresh()
        DF:UpdateAllFrames()
        if preview then preview:Refresh() end
    end
    local function refreshAndStates()
        if opts.refreshStates then opts.refreshStates() end
        refresh()
    end

    -- The card's own divider: Texture Layers is a sub-feature of the bar above it.
    add(GUI:CreateSeparator(parent), 14)

    local master = add(GUI:CreateCheckbox(parent, L["Texture Layers"], db, switch, refreshAndStates), 25)
    master.tooltip = L["Advanced: stack up to two more textures on this bar. Unticking restores the plain bar and keeps these settings."]

    preview = add(CreatePreview(parent, db, prefix, opts.baseSize), 54)
    preview.hideOn = closed

    -- ☠ A LOOK WRITES THROUGH THE SAME BRACKET AS EVERY CONTROL. The dropdown has no
    -- key of its own, so the kit brackets nothing for it; written plainly, a look
    -- skipped the raid redirect under a running layout, the layout editor's override
    -- record and undo. One gesture, so a look is one undo step.
    local function bracketed(key, value)
        if GUI:Call("interceptWrite", db, key, value) then return end
        db[key] = value
        GUI:Call("onSettingWritten", db, key, value, L["Presets"], refresh)
    end
    look = add(GUI:CreateDropdown(parent, L["Presets"], LookOptions(), nil, nil,
        function() refreshAndStates() refreshValues() end,
        function() return db[prefix .. "TextureLook"] or "CUSTOM" end,
        function(id)
            local SU = DF.SettingsUndo
            if SU then SU:BeginGesture() end
            ApplyLook(db, prefix, id, bracketed)
            if SU then SU:EndGesture() end
        end), 55)
    look.tooltip = L["Fills in the layers below with a ready-made look, which you can then adjust. It does not change the bar's own texture or colour."]
    look.hideOn = closed

    for _, n in ipairs(DF.TEXTURE_LAYER_EXTRA) do
        local p = prefix .. "Layer" .. n
        local function off(d) return closed(d) or not d[p .. "Enabled"] end

        local heading = add(GUI:CreateHeader(parent, (n == 2) and L["Layer 2: Pattern"] or L["Layer 3: Shading"]), 25)
        heading.hideOn = closed

        local layerTick = add(GUI:CreateCheckbox(parent, L["Enable"], db, p .. "Enabled", refreshAndStates), 25)
        layerTick.hideOn = closed

        -- The short list for this layer's job; "Show All Textures" is a view toggle only.
        local showAll = false
        local list = NewList()
        FillList(list, n, showAll)
        local tex = add(GUI:CreateTextureDropdown(parent, L["Texture"], db, p .. "Texture", refreshAndStates, list), 55)
        tex.hideOn = off

        local all = add(GUI:CreateCheckbox(parent, L["Show All Textures"], nil, nil, function()
            FillList(list, n, showAll)
            if tex.refreshValue then tex.refreshValue() end
        end, function() return showAll end, function(v) showAll = v and true or false end), 25)
        all.hideOn = off

        local color = add(GUI:CreateColorPicker(parent, L["Color"], db, p .. "Color", true, refresh), 35)
        color.hideOn = off

        local blend = add(GUI:CreateDropdown(parent, L["Blend Mode"], BlendOptions(), db, p .. "BlendMode", refresh), 55)
        blend.hideOn = off

        local tile = add(GUI:CreateDropdown(parent, L["Tile"], TileOptions(), db, p .. "TileMode", refreshAndStates), 55)
        tile.tooltip = TileTooltip()
        tile.hideOn = off

        local mirror = add(GUI:CreateCheckbox(parent, L["Mirror"], db, p .. "TileMirror", refresh), 25)
        mirror.tooltip = MirrorTooltip()
        mirror.hideOn = function(d) return off(d) or not DF:CanMirrorTexture(d[p .. "Texture"]) end

        AddTileSize(add, parent, db, p .. "TileSize", function(d) return d[p .. "Texture"] end,
            function(d) return off(d) or d[p .. "TileMode"] == "OFF" end,
            function(states) if states then refreshAndStates() else refresh() end end)
    end
end

-- ============================================================
-- THE BAR'S OWN TILE AND TILE SIZE
-- ============================================================
-- Placed under the card's Texture, because they act on that texture and apply with
-- the Texture Layers switch off. Tile Size only where opts.baseSize allows it (see the
-- section's header for why health and resource cannot).
--   opts.refreshStates   the page's state pass (Tile Off hides the size rows)
--   opts.disableOn       greys both with the card's own enable, where it has one
function GUI:AddBarTileControls(addToCard, parent, db, prefix, opts)
    opts = opts or {}
    local texKey = BAR[prefix] and BAR[prefix].texture
    local function refresh(states)
        if states and opts.refreshStates then opts.refreshStates() end
        DF:UpdateAllFrames()
    end
    local tile = addToCard(GUI:CreateDropdown(parent, L["Tile"], TileOptions(), db, prefix .. "TileMode",
        function() refresh(true) end), 55)
    tile.tooltip = TileTooltip()
    tile.disableOn = opts.disableOn
    -- Offered only for a texture with a mirrored twin; the card's Texture dropdown
    -- re-runs the state pass, so it appears and goes as the texture changes.
    local mirror = addToCard(GUI:CreateCheckbox(parent, L["Mirror"], db, prefix .. "TileMirror",
        function() refresh(false) end), 25)
    mirror.tooltip = MirrorTooltip()
    mirror.hideOn = function(d) return not (texKey and DF:CanMirrorTexture(d[texKey])) end
    mirror.disableOn = opts.disableOn
    if opts.baseSize then
        local choice, size = AddTileSize(addToCard, parent, db, prefix .. "TileSize",
            function(d) return texKey and d[texKey] end,
            function(d) return d[prefix .. "TileMode"] == "OFF" end, refresh)
        choice.disableOn, size.disableOn = opts.disableOn, opts.disableOn
    end
end
