local addonName, DF = ...

-- ============================================================
-- DISPEL OVERLAY SYSTEM
-- Shows colored border/glow when unit has dispellable debuff
-- 
-- APPROACH: Per-element curves with custom colors and alphas.
-- - Each element (border, gradient, icon) has its own curve
-- - Curves use user-customizable colors per dispel type
-- - Alpha is baked into the curve based on element settings
-- - None (0) has alpha=0 = invisible
-- - Dispellable types have element's alpha = visible
-- ============================================================

-- Local caching of frequently used globals for performance
local pairs, ipairs, type, wipe = pairs, ipairs, type, wipe
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max
local CreateColorFromBytes = CreateColorFromBytes
local issecretvalue = issecretvalue

-- Edge gradient textures: each edge is solid at the outer edge and fades inward
-- Uses pre-baked gradient texture files + SetVertexColor (handles secret/tainted values)
-- instead of WHITE8x8 + SetGradient + CreateColor (which errors on secret values)
local EDGE_GRADIENT_TEXTURES = {
    TOP = "Interface\\AddOns\\DandersFrames\\Media\\DF_Gradient_V",        -- Solid top, fades down
    BOTTOM = "Interface\\AddOns\\DandersFrames\\Media\\DF_Gradient_V_Rev", -- Solid bottom, fades up
    LEFT = "Interface\\AddOns\\DandersFrames\\Media\\DF_Gradient_H",       -- Solid left, fades right
    RIGHT = "Interface\\AddOns\\DandersFrames\\Media\\DF_Gradient_H_Rev",  -- Solid right, fades left
}

-- Invalidate the shared debuff-type colour curve when dispel colour settings
-- change (Frames/Border.lua lazy-rebuilds it on next use).
function DF:InvalidateDispelColorCurve()
    DF.debuffBorderCurve = nil
    DF.dispelColorMap = nil
    -- Generation counter: SetAuraBorder carriers capture the map/curve OBJECT at
    -- bind time, so a palette edit must force a re-bind. Every bind site records
    -- the generation it bound with and re-binds when it moves.
    DF.dispelCurveGen = (DF.dispelCurveGen or 0) + 1
end


-- ============================================================
-- FALLBACK COLORS (for test mode and out-of-combat)
-- Uses custom colors from db
-- ============================================================

local function GetTestDispelColor(dispelType, db)
    -- When the overlay's custom mode is on, use the shared account palette
    -- (DF.db.dispelColors, Enrage folding into Bleed); else the game palette.
    if db and db.dispelOverlayCustomColors and DF.db and type(DF.db.dispelColors) == "table" then
        local c = DF.db.dispelColors[dispelType == "Enrage" and "Bleed" or dispelType]
        if c then return c.r, c.g, c.b end
    end
    local c = DF.DispelDefaultColors[dispelType]
    if c then return c.r, c.g, c.b end
    return 0.5, 0.5, 1.0
end

-- SetAuraBorder style enum: moved to Enum.CustomAuraButtonBorderStyle in 12.1 (the
-- old AuraButtonBorderStyle global was removed) — dual-detect so a configured Color
-- style can't silently degrade to Atlas.
local function DispelBorderStyle()
    return (Enum and Enum.CustomAuraButtonBorderStyle and Enum.CustomAuraButtonBorderStyle.Color)
        or (_G.AuraButtonBorderStyle and _G.AuraButtonBorderStyle.Color) or 1
end

-- Custom dispel-colour map for the overlay: when the overlay opts in
-- (db.dispelOverlayCustomColors) recolour ALL carriers from the shared account
-- palette via customDispelColorMap — keyed by dispel NAME, indexed private-side
-- against auraData.dispelName by Blizzard_CustomAuraButton.lua (secret-safe; no
-- enum IDs involved). nil otherwise → Blizzard's native palette. Ignored on
-- clients whose engine predates the field, so it's safe to pass everywhere.
local function DispelBorderMapFor(db)
    if db and db.dispelOverlayCustomColors and DF.GetDispelColorMap then
        return DF:GetDispelColorMap()
    end
    return nil
end

-- ============================================================
-- OVERLAY CREATION - Using StatusBar for secret color support
-- Blizzard-managed textures (from StatusBar) CAN handle secret colors
-- Addon-created textures CANNOT handle secret colors
-- ============================================================

-- Pulse = a looping alpha fade (full -> 0.3 -> full, 0.5s each way) attached to a
-- HOST FRAME, so it MULTIPLIES the alpha of every region parented under that host
-- (each region keeps its own configured alpha). ONE helper, reused everywhere so
-- "pulse" means the same thing on every path: the whole dispel overlay breathes,
-- not just one element. Legacy widget = three hosts (borders / gradient box / icon
-- box); 12.1 slot path = the main widget + each slot holder.
local function AttachDispelPulse(hostFrame)
    local anim = hostFrame:CreateAnimationGroup()
    anim:SetLooping("REPEAT")
    local fadeOut = anim:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1); fadeOut:SetToAlpha(0.3); fadeOut:SetDuration(0.5)
    fadeOut:SetOrder(1); fadeOut:SetSmoothing("IN_OUT")
    local fadeIn = anim:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0.3); fadeIn:SetToAlpha(1); fadeIn:SetDuration(0.5)
    fadeIn:SetOrder(2); fadeIn:SetSmoothing("IN_OUT")
    return anim
end

-- Slot-holder pulse (12.1 path): lazily build the group on the holder, then
-- play/stop it, resetting the holder alpha to 1 on stop. Stored on the holder so
-- every slot family (ring / edge / icon) shares this one code path.
local function ApplySlotPulse(holder, on)
    if not holder then return end
    if not holder._dfDispelPulse then holder._dfDispelPulse = AttachDispelPulse(holder) end
    if on then
        if not holder._dfDispelPulse:IsPlaying() then holder._dfDispelPulse:Play() end
    else
        if holder._dfDispelPulse:IsPlaying() then holder._dfDispelPulse:Stop() end
        holder:SetAlpha(1)
    end
end

-- Play/stop ALL of a legacy widget's pulse hosts together (borders + gradient box
-- + icon box). Started in the same call so they stay phase-locked; alpha reset to
-- 1 on stop.
local function SetLegacyOverlayPulse(overlay, on)
    local groups = { overlay.pulseAnim, overlay.gradientPulse, overlay.iconPulse }
    for i = 1, #groups do
        local g = groups[i]
        if g then
            if on then
                if not g:IsPlaying() then g:Play() end
            elseif g:IsPlaying() then
                g:Stop()
            end
        end
    end
    if not on then
        overlay:SetAlpha(1)
        if overlay.gradientPulseHost then overlay.gradientPulseHost:SetAlpha(1) end
        if overlay.iconPulseHost then overlay.iconPulseHost:SetAlpha(1) end
    end
end

-- Parent-agnostic widget constructor (§24 unified overlay): builds the full
-- overlay region set on any host. `host` = parent + anchor rect (a unit frame
-- today; an overlay-mode slot BUTTON on the 12.1 container path — overlay slots
-- are OUR-anchored so their dims stay readable). `gradientHost`/`iconHost` are
-- optional layering parents (the unit frame passes healthBar/contentOverlay;
-- a slot button passes nothing and everything hangs off the widget itself).
-- No caching here — callers own the widget's home.
local function BuildDispelOverlayWidget(host, gradientHost, iconHost)
    local overlay = CreateFrame("Frame", nil, host)
    overlay:SetAllPoints(host)
    -- Frame level hierarchy (low to high):
    -- Base frame elements (health bar, absorbs, etc.) - frame level +0 to +5
    -- Dispel gradient - parented to healthBar, level healthBar+2
    -- Dispel overlay - frame level +6
    -- Dispel borders - frame level +7
    -- Frame border - frame level +10
    -- Content overlay (text) - frame level +25
    -- Dispel icon - parented to contentOverlay, level +26
    -- Auras - frame level +50
    overlay:SetFrameLevel(host:GetFrameLevel() + 6)
    
    -- Create StatusBars for borders - their textures CAN handle secret colors
    -- Top border
    overlay.borderTop = CreateFrame("StatusBar", nil, overlay)
    overlay.borderTop:SetFrameLevel(overlay:GetFrameLevel() + 1)  -- Just above gradient
    overlay.borderTop:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    overlay.borderTop:SetMinMaxValues(0, 1)
    overlay.borderTop:SetValue(1)
    overlay.borderTop:GetStatusBarTexture():SetBlendMode("BLEND")  -- Opaque, not additive
    
    -- Bottom border
    overlay.borderBottom = CreateFrame("StatusBar", nil, overlay)
    overlay.borderBottom:SetFrameLevel(overlay:GetFrameLevel() + 1)
    overlay.borderBottom:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    overlay.borderBottom:SetMinMaxValues(0, 1)
    overlay.borderBottom:SetValue(1)
    overlay.borderBottom:GetStatusBarTexture():SetBlendMode("BLEND")  -- Opaque, not additive
    
    -- Left border
    overlay.borderLeft = CreateFrame("StatusBar", nil, overlay)
    overlay.borderLeft:SetFrameLevel(overlay:GetFrameLevel() + 1)
    overlay.borderLeft:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    overlay.borderLeft:SetMinMaxValues(0, 1)
    overlay.borderLeft:SetValue(1)
    overlay.borderLeft:GetStatusBarTexture():SetBlendMode("BLEND")  -- Opaque, not additive
    
    -- Right border
    overlay.borderRight = CreateFrame("StatusBar", nil, overlay)
    overlay.borderRight:SetFrameLevel(overlay:GetFrameLevel() + 1)
    overlay.borderRight:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    overlay.borderRight:SetMinMaxValues(0, 1)
    overlay.borderRight:SetValue(1)
    overlay.borderRight:GetStatusBarTexture():SetBlendMode("BLEND")  -- Opaque, not additive
    
    -- Dark background behind gradient (helps gradient show on light class colors)
    -- Parent to the gradient host (healthBar on unit frames) for proper layering.
    -- When a SEPARATE gradient host is supplied (legacy unit-frame path), the
    -- gradient family is NOT a child of `overlay`, so the border pulse can't reach
    -- it. Interpose an invisible pulse BOX at the host's OWN frame level (draw order
    -- unchanged: the box is a passthrough) that we can fade independently, in sync
    -- with the borders. On the slot path (gradientHost nil) the regions are children
    -- of `overlay` and ride its pulse directly — no box, no double-pulse.
    local gradientParent = gradientHost or overlay
    if gradientHost then
        local box = CreateFrame("Frame", nil, gradientHost)
        box:SetAllPoints(gradientHost)
        box:SetFrameLevel(gradientHost:GetFrameLevel())
        overlay.gradientPulseHost = box
        gradientParent = box
    end
    overlay.gradientDarken = gradientParent:CreateTexture(nil, "ARTWORK", nil, 1)
    overlay.gradientDarken:SetColorTexture(0, 0, 0, 0.5)
    overlay.gradientDarken:Hide()
    
    -- Gradient - use a StatusBar with gradient texture
    -- The texture has built-in alpha gradient, so we just tint it with color
    -- Parent to healthBar to ensure proper layering above health bar content.
    -- +7 clears the WHOLE health-content band: fill (healthBar itself), absorb
    -- (+4), heal-absorb (+5), overflow (+3) and reduced-max-health (+6) — the
    -- dispel wash tints all of it (Krathe's call: the alert renders on top;
    -- the old +2 left it under absorbs and the reduced-max region).
    overlay.gradient = CreateFrame("StatusBar", nil, gradientParent)
    overlay.gradient:SetFrameLevel(gradientParent:GetFrameLevel() + 7)
    overlay.gradient:SetMinMaxValues(0, 1)
    overlay.gradient:SetValue(1)
    
    -- Use Blizzard's gradient texture - this fades from solid to transparent
    -- "Interface\\BUTTONS\\WHITE8x8" is solid, we need a gradient
    -- Options: Create custom texture OR use existing WoW gradients
    overlay.gradient:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    overlay.gradient:GetStatusBarTexture():SetBlendMode("ADD")
    
    -- Store reference to set gradient texture later based on style
    overlay.gradientStyle = "FULL"
    
    -- EDGE style gradients (4 edges that fade inward using gradient textures)
    overlay.gradientTop = gradientParent:CreateTexture(nil, "ARTWORK", nil, 2)
    overlay.gradientTop:SetTexture(EDGE_GRADIENT_TEXTURES.TOP)
    overlay.gradientTop:Hide()
    
    overlay.gradientBottom = gradientParent:CreateTexture(nil, "ARTWORK", nil, 2)
    overlay.gradientBottom:SetTexture(EDGE_GRADIENT_TEXTURES.BOTTOM)
    overlay.gradientBottom:Hide()
    
    overlay.gradientLeft = gradientParent:CreateTexture(nil, "ARTWORK", nil, 2)
    overlay.gradientLeft:SetTexture(EDGE_GRADIENT_TEXTURES.LEFT)
    overlay.gradientLeft:Hide()
    
    overlay.gradientRight = gradientParent:CreateTexture(nil, "ARTWORK", nil, 2)
    overlay.gradientRight:SetTexture(EDGE_GRADIENT_TEXTURES.RIGHT)
    overlay.gradientRight:Hide()
    
    -- ============================================================
    -- DISPEL TYPE ICONS
    -- Each icon uses a separate curve where only its type has alpha=1
    -- The curve's alpha controls visibility - we never "know" the type
    -- ============================================================
    
    -- Icon layering parent (contentOverlay at +25 on unit frames; the host itself otherwise).
    -- Same pulse-box treatment as the gradient family: on the legacy path the icons
    -- live under contentOverlay (not `overlay`), so wrap them in an invisible box at
    -- the same level that we can fade in sync with the rest of the overlay.
    local iconParent = iconHost or host
    if iconHost then
        local box = CreateFrame("Frame", nil, iconHost)
        box:SetAllPoints(iconHost)
        box:SetFrameLevel(iconHost:GetFrameLevel())
        overlay.iconPulseHost = box
        iconParent = box
    end
    local iconLevel = iconParent:GetFrameLevel() + 1  -- Just above the icon parent's base
    
    -- Helper to create icon StatusBar with atlas
    local function CreateIconStatusBar(atlasName)
        local icon = CreateFrame("StatusBar", nil, iconParent)
        icon:SetFrameLevel(iconLevel)
        icon:SetMinMaxValues(0, 1)
        icon:SetValue(1)
        icon:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
        icon:GetStatusBarTexture():SetAtlas(atlasName)
        icon:Hide()
        return icon
    end
    
    -- Helper to create simple icon frame with texture (for bleed/enrage)
    local function CreateIconTexture(atlasName)
        local icon = CreateFrame("Frame", nil, iconParent)
        icon:SetFrameLevel(iconLevel)
        icon.texture = icon:CreateTexture(nil, "OVERLAY")
        icon.texture:SetAllPoints()
        icon.texture:SetAtlas(atlasName)
        icon:Hide()
        -- Add methods to match StatusBar API
        icon.GetStatusBarTexture = function(self) return self.texture end
        return icon
    end
    
    -- Create icons for each dispel type
    -- Note: Bleed uses simple texture frame for reliability
    overlay.icons = {
        magic = CreateIconStatusBar("RaidFrame-Icon-DebuffMagic"),
        curse = CreateIconStatusBar("RaidFrame-Icon-DebuffCurse"),
        disease = CreateIconStatusBar("RaidFrame-Icon-DebuffDisease"),
        poison = CreateIconStatusBar("RaidFrame-Icon-DebuffPoison"),
        bleed = CreateIconTexture("RaidFrame-Icon-DebuffBleed"),  -- Bleed atlas
    }
    
    -- Pulse animation. The border group lives on `overlay` (borders are its
    -- children); the gradient/icon families ride their own boxes when present, so
    -- the whole overlay breathes as one. All groups share identical timing and are
    -- played together (SetLegacyOverlayPulse) to stay phase-locked. On the slot path
    -- only `overlay.pulseAnim` exists (no boxes); the slot holders pulse separately.
    overlay.pulseAnim = AttachDispelPulse(overlay)
    if overlay.gradientPulseHost then
        overlay.gradientPulse = AttachDispelPulse(overlay.gradientPulseHost)
    end
    if overlay.iconPulseHost then
        overlay.iconPulse = AttachDispelPulse(overlay.iconPulseHost)
    end

    overlay:Hide()
    return overlay
end

-- Legacy per-frame entry (unchanged interface): builds once, caches on the frame,
-- with the unit frame's layering parents. The 12.1 slot path calls
-- BuildDispelOverlayWidget directly with the slot button as host.
local function CreateDispelOverlay(frame)
    if frame.dfDispelOverlay then
        return frame.dfDispelOverlay
    end
    local overlay = BuildDispelOverlayWidget(frame, frame.healthBar, frame.contentOverlay)
    frame.dfDispelOverlay = overlay
    return overlay
end

-- ============================================================
-- OVERLAY LAYOUT
-- ============================================================

-- ============================================================
-- LAYOUT CHANGE DETECTION
-- The layout only actually changes when the user adjusts dispel
-- options or the parent frame is resized — rare events. Compare the 15 relevant settings + parent
-- dimensions against values cached on the overlay; if all match,
-- skip the layout pass entirely.
-- ============================================================
-- Gradient GEOMETRY target: on the legacy path the gradient regions are PARENTED to
-- the healthBar, so anchoring "to the parent" lands on the health bar. On the 12.1
-- slot path regions are parented under the slot BUTTON (visibility must ride it), so
-- the consumer sets overlay.gradientAnchorTarget = frame.healthBar and the layout
-- anchors there while parenting stays slot-side. Nil = legacy behaviour.
-- Measure a gradient anchor rect without tripping 12.1 restricted-rect
-- propagation: a slot-hosted widget's rect derives from the secret aura
-- button, and GetHeight/GetWidth on it THROW from addon code. The GetParent()
-- fallback below reaches exactly such a widget when both anchor candidates
-- are nil — live-caught zoning out of an M+ key, where a half-initialized
-- frame left gradientAnchorTarget unstamped for one pass. nil = "couldn't
-- measure"; callers fall back to the defaults and self-heal next drive.
local function SafeRectSize(region)
    if not region then return nil, nil end
    local okH, h = pcall(region.GetHeight, region)
    local okW, w = pcall(region.GetWidth, region)
    if not okH or not okW then return nil, nil end
    -- GetHeight/GetWidth can return a SECRET number without throwing (restricted
    -- content); a secret dimension is not a usable measure. issecretvalue is the
    -- real global for this (canaccessvalue is not a callable global — it's only a
    -- documented return-field name).
    if issecretvalue(h) or issecretvalue(w) then
        return nil, nil
    end
    return h, w
end

local function LayoutStateChanged(overlay, db)
    -- Measure the padded-frame anchor proxy when it exists (the rect the layout
    -- actually uses); the healthBar fallback only applies before the first pass.
    local gradientParent = overlay.dfGradientAnchorProxy or overlay.gradientAnchorTarget
        or (overlay.gradient and overlay.gradient:GetParent())
    local parentH, parentW = SafeRectSize(gradientParent)
    parentH = parentH or 40
    parentW = parentW or 80
    return overlay.dfL_borderSize              ~= db.dispelBorderSize
        or overlay.dfL_framePadding            ~= db.framePadding
        or overlay.dfL_borderInset             ~= db.dispelBorderInset
        or overlay.dfL_pixelPerfect            ~= db.pixelPerfect
        or overlay.dfL_iconSize                ~= db.dispelIconSize
        or overlay.dfL_iconAlpha               ~= db.dispelIconAlpha
        or overlay.dfL_iconPosition            ~= db.dispelIconPosition
        or overlay.dfL_iconOffsetX             ~= db.dispelIconOffsetX
        or overlay.dfL_iconOffsetY             ~= db.dispelIconOffsetY
        or overlay.dfL_showIcon                ~= db.dispelShowIcon
        or overlay.dfL_gradientStyle           ~= db.dispelGradientStyle
        or overlay.dfL_gradientSize            ~= db.dispelGradientSize
        or overlay.dfL_gradientOnCurrentHealth ~= db.dispelGradientOnCurrentHealth
        or overlay.dfL_healthOrientation       ~= db.healthOrientation
        or overlay.dfL_parentH                 ~= parentH
        or overlay.dfL_parentW                 ~= parentW
end

local function CacheLayoutState(overlay, db)
    local gradientParent = overlay.dfGradientAnchorProxy or overlay.gradientAnchorTarget
        or (overlay.gradient and overlay.gradient:GetParent())
    overlay.dfL_framePadding            = db.framePadding
    overlay.dfL_borderSize              = db.dispelBorderSize
    overlay.dfL_borderInset             = db.dispelBorderInset
    overlay.dfL_pixelPerfect            = db.pixelPerfect
    overlay.dfL_iconSize                = db.dispelIconSize
    overlay.dfL_iconAlpha               = db.dispelIconAlpha
    overlay.dfL_iconPosition            = db.dispelIconPosition
    overlay.dfL_iconOffsetX             = db.dispelIconOffsetX
    overlay.dfL_iconOffsetY             = db.dispelIconOffsetY
    overlay.dfL_showIcon                = db.dispelShowIcon
    overlay.dfL_gradientStyle           = db.dispelGradientStyle
    overlay.dfL_gradientSize            = db.dispelGradientSize
    overlay.dfL_gradientOnCurrentHealth = db.dispelGradientOnCurrentHealth
    overlay.dfL_healthOrientation       = db.healthOrientation
    local parentH, parentW = SafeRectSize(gradientParent)
    overlay.dfL_parentH                 = parentH or 40
    overlay.dfL_parentW                 = parentW or 80
end

local function ApplyOverlayLayout(overlay, db, frame)
    if not overlay then return end

    -- Fast path: skip the entire layout pass if nothing that affects
    -- it has changed since last call. Typical in-combat outcome.
    if not LayoutStateChanged(overlay, db) then return end

    local borderSize = db.dispelBorderSize or 2
    local borderInset = db.dispelBorderInset or 0

    -- Apply pixel-perfect adjustments
    if db.pixelPerfect then
        borderSize = DF:PixelPerfect(borderSize)
        borderInset = DF:PixelPerfect(borderInset)
    end
    
    overlay.borderLeft:ClearAllPoints()
    overlay.borderLeft:SetPoint("TOPLEFT", overlay, "TOPLEFT", -borderInset, borderInset)
    overlay.borderLeft:SetPoint("BOTTOMLEFT", overlay, "BOTTOMLEFT", -borderInset, -borderInset)
    overlay.borderLeft:SetWidth(borderSize)
    
    overlay.borderRight:ClearAllPoints()
    overlay.borderRight:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", borderInset, borderInset)
    overlay.borderRight:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", borderInset, -borderInset)
    overlay.borderRight:SetWidth(borderSize)
    
    overlay.borderTop:ClearAllPoints()
    overlay.borderTop:SetPoint("TOPLEFT", overlay, "TOPLEFT", -borderInset + borderSize, borderInset)
    overlay.borderTop:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", borderInset - borderSize, borderInset)
    overlay.borderTop:SetHeight(borderSize)
    
    overlay.borderBottom:ClearAllPoints()
    overlay.borderBottom:SetPoint("BOTTOMLEFT", overlay, "BOTTOMLEFT", -borderInset + borderSize, -borderInset)
    overlay.borderBottom:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", borderInset - borderSize, -borderInset)
    overlay.borderBottom:SetHeight(borderSize)
    
    -- Icon positioning
    local iconSize = db.dispelIconSize or 20
    local iconAlpha = db.dispelIconAlpha or 1.0
    local iconPosition = db.dispelIconPosition or "CENTER"
    local iconOffsetX = db.dispelIconOffsetX or 0
    local iconOffsetY = db.dispelIconOffsetY or 0
    local showIcon = db.dispelShowIcon ~= false
    
    -- Apply pixel-perfect to icon size
    if db.pixelPerfect then
        iconSize = DF:PixelPerfect(iconSize)
    end
    
    if overlay.icons and showIcon then
        -- Position anchor points
        local anchorPoint = iconPosition
        local relativePoint = iconPosition
        
        for _, icon in pairs(overlay.icons) do
            icon:ClearAllPoints()
            icon:SetPoint(anchorPoint, overlay, relativePoint, iconOffsetX, iconOffsetY)
            icon:SetSize(iconSize, iconSize)
            icon:SetAlpha(iconAlpha)
        end
    end
    
    -- Gradient positioning. Anchor rect = the frame minus framePadding — the
    -- UN-CLIPPED health area (identical to the healthBar's normal rect,
    -- Create.lua). Never anchor to the healthBar itself: reduced-max-health
    -- "Clip Health Bar" mode re-anchors the healthBar to just the un-reduced
    -- portion (ReducedMaxHealth.lua), which shrank every gradient with it —
    -- the wash must span the WHOLE bar, reduced region included (live-caught:
    -- Top Edge stopping at the clip edge). The proxy is a pure anchor target
    -- (no regions, nothing renders); parenting of the art stays as built
    -- (healthBar on the legacy path, the slot widget on the 12.1 path).
    local gradientStyle = db.dispelGradientStyle or "FULL"
    local gradientSize = db.dispelGradientSize or 0.3
    local gradientParent
    if frame then
        gradientParent = overlay.dfGradientAnchorProxy
        if not gradientParent then
            gradientParent = CreateFrame("Frame", nil, overlay)
            overlay.dfGradientAnchorProxy = gradientParent
        end
        local pad = db.framePadding or 0
        gradientParent:ClearAllPoints()
        gradientParent:SetPoint("TOPLEFT", frame, "TOPLEFT", pad, -pad)
        gradientParent:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -pad, pad)
    else
        gradientParent = overlay.gradientAnchorTarget or overlay.gradient:GetParent()
    end
    local parentHeight, parentWidth = SafeRectSize(gradientParent)
    parentHeight = parentHeight or 40
    parentWidth = parentWidth or 80
    
    overlay.gradient:ClearAllPoints()
    if overlay.gradientDarken then
        overlay.gradientDarken:ClearAllPoints()
    end
    
    -- Clear edge gradients
    if overlay.gradientTop then overlay.gradientTop:ClearAllPoints() end
    if overlay.gradientBottom then overlay.gradientBottom:ClearAllPoints() end
    if overlay.gradientLeft then overlay.gradientLeft:ClearAllPoints() end
    if overlay.gradientRight then overlay.gradientRight:ClearAllPoints() end
    
    -- Reset health tracking - only FULL style with onCurrentHealth will set this true
    overlay.gradientTracksHealth = false

    -- Neutralize the FILL state every pass, not just for FULL: the strip styles
    -- (TOP/BOTTOM/LEFT/RIGHT) render through this same StatusBar, and a stale
    -- tracking fill left behind by FULL + On Current Health (value = a health
    -- snapshot, minmax = 0..maxHealth, health-matched orientation/reverse)
    -- clipped the strips into health-shaped fragments after a style switch
    -- (live-caught: Top Edge covering only part of the bar — frozen at the last
    -- fed health on live, at each unit's test health in test mode). The
    -- FULL+tracking branch below re-configures orientation/reverse and the
    -- health hook re-feeds minmax/value.
    overlay.gradient:SetOrientation("HORIZONTAL")
    overlay.gradient:SetReverseFill(false)
    overlay.gradient:SetMinMaxValues(0, 1)
    overlay.gradient:SetValue(1)

    if gradientStyle == "EDGE" then
        -- EDGE style - gradients from each edge fading inward
        local edgeSize = parentHeight * gradientSize
        local edgeWidth = parentWidth * gradientSize
        
        if overlay.gradientTop then
            overlay.gradientTop:SetPoint("TOPLEFT", gradientParent, "TOPLEFT", 0, 0)
            overlay.gradientTop:SetPoint("TOPRIGHT", gradientParent, "TOPRIGHT", 0, 0)
            overlay.gradientTop:SetHeight(edgeSize)
        end
        
        if overlay.gradientBottom then
            overlay.gradientBottom:SetPoint("BOTTOMLEFT", gradientParent, "BOTTOMLEFT", 0, 0)
            overlay.gradientBottom:SetPoint("BOTTOMRIGHT", gradientParent, "BOTTOMRIGHT", 0, 0)
            overlay.gradientBottom:SetHeight(edgeSize)
        end
        
        if overlay.gradientLeft then
            overlay.gradientLeft:SetPoint("TOPLEFT", gradientParent, "TOPLEFT", 0, 0)
            overlay.gradientLeft:SetPoint("BOTTOMLEFT", gradientParent, "BOTTOMLEFT", 0, 0)
            overlay.gradientLeft:SetWidth(edgeWidth)
        end
        
        if overlay.gradientRight then
            overlay.gradientRight:SetPoint("TOPRIGHT", gradientParent, "TOPRIGHT", 0, 0)
            overlay.gradientRight:SetPoint("BOTTOMRIGHT", gradientParent, "BOTTOMRIGHT", 0, 0)
            overlay.gradientRight:SetWidth(edgeWidth)
        end
        
        -- Hide darken and main gradient for EDGE style
        if overlay.gradientDarken then
            overlay.gradientDarken:Hide()
        end
    elseif gradientStyle == "TOP" then
        overlay.gradient:SetPoint("TOPLEFT", gradientParent, "TOPLEFT")
        overlay.gradient:SetPoint("TOPRIGHT", gradientParent, "TOPRIGHT")
        overlay.gradient:SetHeight(parentHeight * gradientSize)
        if overlay.gradientDarken then
            overlay.gradientDarken:SetPoint("TOPLEFT", gradientParent, "TOPLEFT")
            overlay.gradientDarken:SetPoint("TOPRIGHT", gradientParent, "TOPRIGHT")
            overlay.gradientDarken:SetHeight(parentHeight * gradientSize)
        end
    elseif gradientStyle == "BOTTOM" then
        overlay.gradient:SetPoint("BOTTOMLEFT", gradientParent, "BOTTOMLEFT")
        overlay.gradient:SetPoint("BOTTOMRIGHT", gradientParent, "BOTTOMRIGHT")
        overlay.gradient:SetHeight(parentHeight * gradientSize)
        if overlay.gradientDarken then
            overlay.gradientDarken:SetPoint("BOTTOMLEFT", gradientParent, "BOTTOMLEFT")
            overlay.gradientDarken:SetPoint("BOTTOMRIGHT", gradientParent, "BOTTOMRIGHT")
            overlay.gradientDarken:SetHeight(parentHeight * gradientSize)
        end
    elseif gradientStyle == "LEFT" then
        overlay.gradient:SetPoint("TOPLEFT", gradientParent, "TOPLEFT")
        overlay.gradient:SetPoint("BOTTOMLEFT", gradientParent, "BOTTOMLEFT")
        overlay.gradient:SetWidth(parentWidth * gradientSize)
        if overlay.gradientDarken then
            overlay.gradientDarken:SetPoint("TOPLEFT", gradientParent, "TOPLEFT")
            overlay.gradientDarken:SetPoint("BOTTOMLEFT", gradientParent, "BOTTOMLEFT")
            overlay.gradientDarken:SetWidth(parentWidth * gradientSize)
        end
    elseif gradientStyle == "RIGHT" then
        overlay.gradient:SetPoint("TOPRIGHT", gradientParent, "TOPRIGHT")
        overlay.gradient:SetPoint("BOTTOMRIGHT", gradientParent, "BOTTOMRIGHT")
        overlay.gradient:SetWidth(parentWidth * gradientSize)
        if overlay.gradientDarken then
            overlay.gradientDarken:SetPoint("TOPRIGHT", gradientParent, "TOPRIGHT")
            overlay.gradientDarken:SetPoint("BOTTOMRIGHT", gradientParent, "BOTTOMRIGHT")
            overlay.gradientDarken:SetWidth(parentWidth * gradientSize)
        end
    else
        -- FULL style - can optionally track current health
        local onCurrentHealth = gradientStyle == "FULL" and db.dispelGradientOnCurrentHealth ~= false
        
        if onCurrentHealth and frame and frame.healthBar then
            -- Position gradient to match health bar
            overlay.gradient:SetAllPoints(gradientParent)
            if overlay.gradientDarken then
                overlay.gradientDarken:SetAllPoints(gradientParent)
            end
            
            -- Match health bar orientation and fill direction
            local healthOrient = db.healthOrientation or "HORIZONTAL"
            if healthOrient == "HORIZONTAL" then
                overlay.gradient:SetOrientation("HORIZONTAL")
                overlay.gradient:SetReverseFill(false)
            elseif healthOrient == "HORIZONTAL_INV" then
                overlay.gradient:SetOrientation("HORIZONTAL")
                overlay.gradient:SetReverseFill(true)
            elseif healthOrient == "VERTICAL" then
                overlay.gradient:SetOrientation("VERTICAL")
                overlay.gradient:SetReverseFill(false)
            elseif healthOrient == "VERTICAL_INV" then
                overlay.gradient:SetOrientation("VERTICAL")
                overlay.gradient:SetReverseFill(true)
            end
            
            -- Mark this gradient as tracking health
            overlay.gradientTracksHealth = true
        else
            -- Standard full frame overlay (fill state already neutralized in the
            -- every-pass reset above)
            overlay.gradient:SetAllPoints(gradientParent)
            if overlay.gradientDarken then
                overlay.gradientDarken:SetAllPoints(gradientParent)
            end
            overlay.gradientTracksHealth = false
        end
    end

    -- Cache the current layout settings so subsequent calls can
    -- short-circuit via LayoutStateChanged.
    CacheLayoutState(overlay, db)
end

-- ============================================================
-- UPDATE DISPEL GRADIENT HEALTH VALUE
-- Called when health changes to update the gradient overlay
-- ============================================================

function DF:UpdateDispelGradientHealth(frame)
    if not frame then return end

    -- Health-tracking gradient StatusBars: the legacy overlay and/or the 12.1 slot
    -- widgets. BOTH colour modes ride this on 12.1 — custom drives the StatusBar's
    -- fill colour itself; game mode binds the StatusBar's fill TEXTURE as the
    -- Blizzard-tinted carrier and this hook clips it to health via the bar's value
    -- (secret-safe: values pass straight to SetValue). Zero-alloc: runs every
    -- health tick.
    local legacy = frame.dfDispelOverlay
    if legacy and not (legacy.gradient and legacy.gradientTracksHealth and legacy:IsShown()) then
        legacy = nil
    end
    local buttons
    local anySlot = false
    local h = frame.dispelFactory
    if h and h.GetOverlaySlots then
        buttons = h:GetOverlaySlots()
        if buttons then
            for _, btn in pairs(buttons) do
                local w = btn.dfDispelWidget
                if w and w.gradient and w.gradientTracksHealth then
                    anySlot = true
                    break
                end
            end
        end
    end
    if not legacy and not anySlot then return end

    local unit = frame.unit
    if not unit or not UnitExists(unit) then return end

    -- Get the appropriate db for this frame to check smoothBars setting
    local db
    if frame.isRaidFrame then
        db = DF.GetRaidDB and DF:GetRaidDB()
    else
        db = DF.GetDB and DF:GetDB()
    end
    local smoothEnabled = db and db.smoothBars

    -- StatusBar API handles secret values internally via SetMinMaxValues/SetValue
    -- No need to compare values - just pass them directly
    local maxHealth = UnitHealthMax(unit)
    local currentHealth = UnitHealth(unit, true)

    -- Use same smooth interpolation as health bar when enabled
    local interp
    if smoothEnabled and Enum and Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut then
        interp = Enum.StatusBarInterpolation.ExponentialEaseOut
    end
    if legacy then
        legacy.gradient:SetMinMaxValues(0, maxHealth)
        if interp then legacy.gradient:SetValue(currentHealth, interp)
        else legacy.gradient:SetValue(currentHealth) end
    end
    if anySlot then
        for _, btn in pairs(buttons) do
            local w = btn.dfDispelWidget
            if w and w.gradient and w.gradientTracksHealth then
                w.gradient:SetMinMaxValues(0, maxHealth)
                if interp then w.gradient:SetValue(currentHealth, interp)
                else w.gradient:SetValue(currentHealth) end
            end
        end
    end
end

-- ============================================================
-- APPLY DISPEL OVERLAY APPEARANCE
-- Called by ElementAppearance when range changes
-- Handles EDGE gradients which need SetVertexColor re-applied with OOR alpha
-- ============================================================

function DF:ApplyDispelOverlayAppearance(frame)
    if not frame or not frame.dfDispelOverlay then return end
    
    local overlay = frame.dfDispelOverlay
    if not overlay:IsShown() then return end
    
    local db = DF:GetFrameDB(frame)
    if not db then return end
    
    local gradientStyle = db.dispelGradientStyle or "FULL"
    
    -- Only need special handling for EDGE style
    -- Non-EDGE styles use SetAlphaFromBoolean which is handled by ElementAppearance
    if gradientStyle ~= "EDGE" then return end
    if not db.dispelShowGradient then return end
    
    -- Get OOR settings (dfInRange may be secret from UnitInRange fallback)
    local inRange = frame.dfInRange
    if not (issecretvalue and issecretvalue(inRange)) and inRange == nil then inRange = true end
    local oorAlpha = db.oorDispelOverlayAlpha or 0.2
    
    -- Get current dispel color from stored type
    local dispelType = overlay.currentDispelType
    if not dispelType then return end
    
    -- Game palette (shared constant). Custom-mode OOR colour is a Stage-4 concern
    -- (when the overlay's custom toggle is wired); for now the OOR fade uses the
    -- game colours, matching the in-range overlay's game-mode default.
    local c = DF.DispelDefaultColors[dispelType]
    if not c then return end

    local r, g, b = c.r, c.g, c.b
    local gradientAlpha = db.dispelGradientAlpha or 0.5
    local intensity = db.dispelGradientIntensity or 1.0
    local blendMode = db.dispelGradientBlendMode or "ADD"
    
    -- Apply intensity to colors
    local ri, gi, bi = r * intensity, g * intensity, b * intensity
    
    -- Calculate final alpha with OOR
    local finalAlpha = gradientAlpha
    if db.oorEnabled and not inRange then
        finalAlpha = gradientAlpha * oorAlpha
    end
    
    -- Re-apply EDGE gradients with OOR alpha
    if overlay.gradientTop then
        overlay.gradientTop:SetTexture(EDGE_GRADIENT_TEXTURES.TOP)
        overlay.gradientTop:SetVertexColor(ri, gi, bi, finalAlpha)
        overlay.gradientTop:SetBlendMode(blendMode)
    end
    
    if overlay.gradientBottom then
        overlay.gradientBottom:SetTexture(EDGE_GRADIENT_TEXTURES.BOTTOM)
        overlay.gradientBottom:SetVertexColor(ri, gi, bi, finalAlpha)
        overlay.gradientBottom:SetBlendMode(blendMode)
    end
    
    if overlay.gradientLeft then
        overlay.gradientLeft:SetTexture(EDGE_GRADIENT_TEXTURES.LEFT)
        overlay.gradientLeft:SetVertexColor(ri, gi, bi, finalAlpha)
        overlay.gradientLeft:SetBlendMode(blendMode)
    end
    
    if overlay.gradientRight then
        overlay.gradientRight:SetTexture(EDGE_GRADIENT_TEXTURES.RIGHT)
        overlay.gradientRight:SetVertexColor(ri, gi, bi, finalAlpha)
        overlay.gradientRight:SetBlendMode(blendMode)
    end
end

-- ============================================================
-- SHOW OVERLAY WITH SECRET COLOR
-- StatusBar textures CAN handle secret colors via GetRGB()
-- The color's alpha from the curve determines visibility
-- ============================================================

-- Gradient texture paths (relative to addon folder)
local GRADIENT_TEXTURES = {
    LEFT = "Interface\\AddOns\\DandersFrames\\Media\\DF_Gradient_H",      -- Fades left to right (solid left)
    RIGHT = "Interface\\AddOns\\DandersFrames\\Media\\DF_Gradient_H_Rev",  -- Fades right to left (solid right)
    TOP = "Interface\\AddOns\\DandersFrames\\Media\\DF_Gradient_V",        -- Fades top to bottom (solid top)
    BOTTOM = "Interface\\AddOns\\DandersFrames\\Media\\DF_Gradient_V_Rev", -- Fades bottom to top (solid bottom)
    FULL = "Interface\\Buttons\\WHITE8x8",                          -- Solid fill
}

-- ============================================================
-- DISPEL NAME TEXT COLORING
-- Colors the unit name text with dispel type color
-- ============================================================

local function ApplyDispelNameText(frame, r, g, b)
    local nameText = frame.nameText
    if not nameText then return end
    if not frame.dfDispelNameTextOrigColor then
        local cr, cg, cb, ca = nameText:GetTextColor()
        frame.dfDispelNameTextOrigColor = { r = cr, g = cg, b = cb, a = ca }
    end
    nameText:SetTextColor(r, g, b, 1)
    frame.dfDispelNameTextActive = true
end

local function RevertDispelNameText(frame)
    if not frame or not frame.dfDispelNameTextActive then return end
    local nameText = frame.nameText
    if not nameText then return end
    -- If AD nametext is active, restore to AD's color
    local adState = frame.dfAD
    if adState and adState.nametext and adState.savedNameColor then
        local c = adState.savedNameColor
        nameText:SetTextColor(c.r, c.g, c.b, c.a or 1)
    elseif frame.dfDispelNameTextOrigColor then
        local c = frame.dfDispelNameTextOrigColor
        nameText:SetTextColor(c.r, c.g, c.b, c.a or 1)
    end
    frame.dfDispelNameTextOrigColor = nil
    frame.dfDispelNameTextActive = false
end

-- ============================================================
-- SHOW OVERLAY WITH RGB (for test mode)
-- ============================================================

-- Region styling ONLY (no Show/Hide of the widget itself, no name text, no
-- last-aura bookkeeping): everything an explicit-RGB overlay needs — layout,
-- borders, gradients, type icon, pulse anim state. Reused verbatim by the 12.1
-- slot path, where the widget's visibility rides the slot button and this runs
-- ONCE at style time (build-once-leave-it). `frame` is only consulted for
-- ApplyOverlayLayout's cache key and may be nil on a slot host.
local function StyleOverlayRegions(overlay, r, g, b, db, dispelType, oorAlphaMultiplier, frame)
    if not overlay then return end

    -- Store dispel type for lightweight color updates
    overlay.currentDispelType = dispelType
    
    -- Default OOR multiplier to 1.0 (no change)
    oorAlphaMultiplier = oorAlphaMultiplier or 1.0
    
    local borderAlpha = (db.dispelBorderAlpha or 0.8) * oorAlphaMultiplier
    local gradientAlpha = (db.dispelGradientAlpha or 0.5) * oorAlphaMultiplier
    local showBorder = db.dispelShowBorder ~= false
    local showGradient = db.dispelShowGradient ~= false
    local showIcon = db.dispelShowIcon ~= false
    
    ApplyOverlayLayout(overlay, db, frame)
    
    if showBorder then
        -- StatusBars use GetStatusBarTexture():SetVertexColor()
        local tex = overlay.borderTop:GetStatusBarTexture()
        tex:SetVertexColor(r, g, b, borderAlpha)
        overlay.borderTop:Show()
        
        tex = overlay.borderBottom:GetStatusBarTexture()
        tex:SetVertexColor(r, g, b, borderAlpha)
        overlay.borderBottom:Show()
        
        tex = overlay.borderLeft:GetStatusBarTexture()
        tex:SetVertexColor(r, g, b, borderAlpha)
        overlay.borderLeft:Show()
        
        tex = overlay.borderRight:GetStatusBarTexture()
        tex:SetVertexColor(r, g, b, borderAlpha)
        overlay.borderRight:Show()
    else
        overlay.borderTop:Hide()
        overlay.borderBottom:Hide()
        overlay.borderLeft:Hide()
        overlay.borderRight:Hide()
    end
    
    if showGradient then
        local gradientStyle = db.dispelGradientStyle or "FULL"
        local intensity = db.dispelGradientIntensity or 1.0
        local blendMode = db.dispelGradientBlendMode or "ADD"
        local darkenEnabled = db.dispelGradientDarkenEnabled
        local darkenAlpha = db.dispelGradientDarkenAlpha or 0.5
        
        if gradientStyle == "EDGE" then
            -- EDGE style - 4 edge gradients using gradient texture files
            -- Hide main gradient and darken for EDGE style
            overlay.gradient:Hide()
            if overlay.gradientDarken then
                overlay.gradientDarken:Hide()
            end
            
            -- Apply intensity to colors
            local ri, gi, bi = r * intensity, g * intensity, b * intensity
            
            -- Show edge gradients with gradient textures + SetVertexColor
            if overlay.gradientTop then
                overlay.gradientTop:SetTexture(EDGE_GRADIENT_TEXTURES.TOP)
                overlay.gradientTop:SetVertexColor(ri, gi, bi, gradientAlpha)
                overlay.gradientTop:SetBlendMode(blendMode)
                overlay.gradientTop:Show()
            end
            
            if overlay.gradientBottom then
                overlay.gradientBottom:SetTexture(EDGE_GRADIENT_TEXTURES.BOTTOM)
                overlay.gradientBottom:SetVertexColor(ri, gi, bi, gradientAlpha)
                overlay.gradientBottom:SetBlendMode(blendMode)
                overlay.gradientBottom:Show()
            end
            
            if overlay.gradientLeft then
                overlay.gradientLeft:SetTexture(EDGE_GRADIENT_TEXTURES.LEFT)
                overlay.gradientLeft:SetVertexColor(ri, gi, bi, gradientAlpha)
                overlay.gradientLeft:SetBlendMode(blendMode)
                overlay.gradientLeft:Show()
            end
            
            if overlay.gradientRight then
                overlay.gradientRight:SetTexture(EDGE_GRADIENT_TEXTURES.RIGHT)
                overlay.gradientRight:SetVertexColor(ri, gi, bi, gradientAlpha)
                overlay.gradientRight:SetBlendMode(blendMode)
                overlay.gradientRight:Show()
            end
        else
            -- Non-EDGE styles - use main gradient
            -- Hide edge gradients
            if overlay.gradientTop then overlay.gradientTop:Hide() end
            if overlay.gradientBottom then overlay.gradientBottom:Hide() end
            if overlay.gradientLeft then overlay.gradientLeft:Hide() end
            if overlay.gradientRight then overlay.gradientRight:Hide() end
            
            -- Show/hide darken background
            if overlay.gradientDarken then
                if darkenEnabled then
                    overlay.gradientDarken:SetColorTexture(0, 0, 0, darkenAlpha * oorAlphaMultiplier)
                    overlay.gradientDarken:Show()
                else
                    overlay.gradientDarken:Hide()
                end
            end
            
            -- Set the appropriate gradient texture
            local texturePath = GRADIENT_TEXTURES[gradientStyle] or GRADIENT_TEXTURES.FULL
            overlay.gradient:SetStatusBarTexture(texturePath)
            
            local tex = overlay.gradient:GetStatusBarTexture()
            -- Apply intensity by multiplying RGB values (makes gradient brighter/dimmer)
            tex:SetVertexColor(r * intensity, g * intensity, b * intensity, gradientAlpha)
            tex:SetBlendMode(blendMode)
            overlay.gradient:Show()
        end
    else
        overlay.gradient:Hide()
        if overlay.gradientDarken then
            overlay.gradientDarken:Hide()
        end
        -- Hide edge gradients
        if overlay.gradientTop then overlay.gradientTop:Hide() end
        if overlay.gradientBottom then overlay.gradientBottom:Hide() end
        if overlay.gradientLeft then overlay.gradientLeft:Hide() end
        if overlay.gradientRight then overlay.gradientRight:Hide() end
    end
    
    -- Show icon for test mode based on dispelType
    if showIcon and overlay.icons and dispelType then
        local iconAlpha = (db.dispelIconAlpha or 1.0) * oorAlphaMultiplier
        
        -- Hide all icons first
        for _, icon in pairs(overlay.icons) do
            icon:Hide()
        end
        
        -- Show the matching icon
        local iconKey = string.lower(dispelType)
        if iconKey == "enrage" then iconKey = "bleed" end  -- Enrage uses bleed icon
        
        if overlay.icons[iconKey] then
            local tex = overlay.icons[iconKey]:GetStatusBarTexture()
            -- Tint bleed icon with red (since it uses disease atlas)
            if iconKey == "bleed" then
                tex:SetVertexColor(r, g, b, 1)  -- Use the passed color (bleed color)
            else
                tex:SetVertexColor(1, 1, 1, 1)  -- White for standard icons
            end
            overlay.icons[iconKey]:SetAlpha(iconAlpha)
            overlay.icons[iconKey]:Show()
        end
    elseif overlay.icons then
        for _, icon in pairs(overlay.icons) do
            icon:Hide()
        end
    end

    -- Pulse the WHOLE overlay (borders + gradient + icons), not just the borders:
    -- each family rides its own phase-locked group.
    SetLegacyOverlayPulse(overlay, db.dispelAnimate)
end

-- Legacy show path: full styling + the widget lifecycle (Show, test-mode health
-- value, name tint). The 12.1 slot path uses StyleOverlayRegions alone.
local function ShowOverlayWithRGB(overlay, r, g, b, db, dispelType, oorAlphaMultiplier, frame, testData)
    if not overlay then return end

    StyleOverlayRegions(overlay, r, g, b, db, dispelType, oorAlphaMultiplier, frame)

    overlay:Show()
    
    -- Update gradient health value if tracking current health (test mode)
    if overlay.gradientTracksHealth and frame then
        -- For test mode, use the testData's health percent
        local testHealth = (testData and testData.healthPercent) or 0.75
        overlay.gradient:SetMinMaxValues(0, 1)
        overlay.gradient:SetValue(testHealth)
    end

    -- Name text coloring — uses the explicit RGB passed to this function
    if db.dispelNameText and frame then
        ApplyDispelNameText(frame, r, g, b)
    end
end

-- ============================================================
-- HIDE OVERLAY
-- ============================================================

local function HideOverlay(overlay)
    if not overlay then return end
    
    -- Stop animation first
    if overlay.pulseAnim and overlay.pulseAnim:IsPlaying() then
        overlay.pulseAnim:Stop()
    end
    
    -- Reset alpha
    overlay:SetAlpha(1)
    
    -- Hide all border textures
    overlay.borderTop:Hide()
    overlay.borderBottom:Hide()
    overlay.borderLeft:Hide()
    overlay.borderRight:Hide()
    
    -- Hide gradient and its darken background
    overlay.gradient:Hide()
    if overlay.gradientDarken then
        overlay.gradientDarken:Hide()
    end
    
    -- Hide edge gradients
    if overlay.gradientTop then overlay.gradientTop:Hide() end
    if overlay.gradientBottom then overlay.gradientBottom:Hide() end
    if overlay.gradientLeft then overlay.gradientLeft:Hide() end
    if overlay.gradientRight then overlay.gradientRight:Hide() end
    
    -- Hide all icons
    if overlay.icons then
        for _, icon in pairs(overlay.icons) do
            icon:Hide()
        end
    end
    
    -- Hide the overlay frame itself
    overlay:Hide()
end

-- ============================================================
-- MAIN UPDATE FUNCTION
-- Simple approach: One curve with all types, None has alpha=0
-- Just apply the color - alpha handles visibility
-- ============================================================

-- Hide the dispel overlay and clear the last-rendered-aura cache so
-- the next valid UpdateDispelOverlay call re-renders the overlay.
-- Used by every early-return path inside UpdateDispelOverlay — without
-- clearing dfLastDispelAuraID here, the last-rendered-aura skip below
-- would incorrectly early-return after the user re-enabled the overlay.
local function HideDispelAndInvalidate(frame)
    if frame.dfDispelOverlay then
        HideOverlay(frame.dfDispelOverlay)
    end
    RevertDispelNameText(frame)
    frame.dfLastDispelAuraID = nil
end

-- ============================================================
-- 12.1 CONTAINER PATH (§24 unified overlay)
-- ONE overlay system driven by native aura slots: Blizzard owns presence (the slot
-- button's SetShown) and — in game-colour mode — the palette (SetAuraBorder Color
-- vertex-tint); DF owns the art. Two colour-source modes:
--   "game" (default) = ONE any-dispellable slot; the native tint rides a dedicated
--     carrier texture (ONE region per slot — CustomAuraButton stores a single
--     AuraBorder, source-verified), so game mode is gradient (+darken/pulse) + a
--     second slot carrying Blizzard's bordered type icon. One overlay at a time,
--     Blizzard-identical.
--   "custom" = one slot per dispel type (includeDispelTypes); type known at declare
--     time, so the FULL art styles statically from the DF pickers (borders, EDGE
--     gradients, intensity, type icons). Rare dual-type overlap accepted.
-- Me/all: "HARMFUL|RAID_PLAYER_DISPELLABLE" vs HARMFUL + ProcessAura policy +
-- processedAuraType=Dispel (the native all-dispellable classification; raid-flagged
-- harmful auras with a dispellable dispelName — incl. private auras, natively).
-- ============================================================

local DISPEL_ICON_TYPES = { "Magic", "Curse", "Disease", "Poison", "Bleed" }
-- Game-mode icon art: the same clean atlases the DF widget's own icons use (the
-- native SetAuraBorder Atlas style renders a boxed border-with-badge instead).
local GAME_ICON_ATLAS = {
    Magic   = "RaidFrame-Icon-DebuffMagic",
    Curse   = "RaidFrame-Icon-DebuffCurse",
    Disease = "RaidFrame-Icon-DebuffDisease",
    Poison  = "RaidFrame-Icon-DebuffPoison",
    Bleed   = "RaidFrame-Icon-DebuffBleed",
}
local warnedTintBind = false

-- Slot plan from settings. Returns nil when the native classification route is
-- required but missing (API drift) and no degrade applies.
local function dispelSlotPlan(db)
    local byMe = (db.dispelOverlayDispelType or 2) == 1
    local baseFilter = byMe and "HARMFUL|RAID_PLAYER_DISPELLABLE" or "HARMFUL"

    local dispelEnum = AuraUtil and AuraUtil.AuraUpdateChangedType and AuraUtil.AuraUpdateChangedType.Dispel
    if dispelEnum == nil then
        -- API drift: no ProcessAura classification — degrade to by-me semantics
        -- (pure filter string) rather than an unfiltered HARMFUL slot.
        baseFilter = "HARMFUL|RAID_PLAYER_DISPELLABLE"
        byMe = true
    end
    local needPolicy = not byMe
    local baseCF = (not byMe) and { processedAuraType = dispelEnum } or nil

    -- One overlay, the game's colours, engine-driven (the Custom Colors mode was
    -- removed 2026-07-11 — per-type slots with the pickers; the irreducible cost
    -- was one overlay PER type on multi-type units, judged not worth the
    -- confusion once game mode gained the border and edge glow).
    local slots = {}
    slots[#slots + 1] = { key = "main", filter = baseFilter, candidateFilters = baseCF }
    -- BORDER: a SECOND any-dispellable slot whose bound carrier is a single
    -- square-ring texture (transparent centre). One tintable region per slot is
    -- the hard limit — so the border rides its own slot; the identical filter
    -- fills it with the same aura as the main slot (no cross-slot dedup),
    -- keeping border and gradient perfectly in sync.
    if db.dispelShowBorder ~= false then
        slots[#slots + 1] = { key = "gameborder", filter = baseFilter, candidateFilters = baseCF }
    end
    -- EDGE gradient: FOUR strip slots, one per edge, each binding its own strip
    -- texture (the same DF_Gradient_* art the legacy EDGE uses). A single-region
    -- vignette was tried and rejected: TexCoord zoom shows a fading ramp's faint
    -- inner TAIL, so any Gradient Size below the baked band rendered
    -- near-invisible (live-caught; crop-scaling only works on SOLID bands like
    -- the border ring). Same-filter slots all fill with the same aura (proven
    -- live: main + gameborder), so the four strips stay in sync. Structural:
    -- the keys put the style flip in the plan signature.
    if db.dispelShowGradient ~= false and (db.dispelGradientStyle == "EDGE") then
        for _, edge in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
            slots[#slots + 1] = { key = "edge" .. edge, filter = baseFilter,
                candidateFilters = baseCF, edgeSide = edge }
        end
    end
    -- Type icon: per-type slots (includeDispelTypes = type knowledge WITHOUT a
    -- native bind) carrying DF's clean RaidFrame-Icon atlases. The native Atlas
    -- style was tried first and rejected: its ui-debuff-border-*-icon art is a
    -- BUTTON BORDER with a badge — renders as a boxed icon (Krathe, 2026-07-10).
    -- Bleed self-gates: byMe filter only matches if the player can dispel bleeds;
    -- all-mode includes it via the classification route.
    if db.dispelShowIcon ~= false then
        for i = 1, #DISPEL_ICON_TYPES do
            local t = DISPEL_ICON_TYPES[i]
            local cf = { includeDispelTypes = { [t] = true } }
            if baseCF then cf.processedAuraType = dispelEnum end
            slots[#slots + 1] = { key = "icon" .. t, filter = baseFilter, candidateFilters = cf, iconType = t }
        end
    end
    return slots, needPolicy
end

-- Structural signature: me/all, border slot, icon slots — anything that changes
-- the SLOT SET (topology is add-only, so set changes are a rebuild).
-- Pure styling (alphas, geometry) hot-applies via the style pass instead.
local function dispelFactoryPlanAndSig(db)
    local slots, needPolicy = dispelSlotPlan(db)
    if not slots then return nil end
    local parts = { needPolicy and "policy" or "nopolicy" }
    for i = 1, #slots do parts[#parts + 1] = slots[i].key .. "=" .. slots[i].filter end
    return table.concat(parts, ";"), slots, needPolicy
end

-- Build the full DF art on a slot button ONCE. Visibility rides the BUTTON (Blizzard
-- SetShown's it per aura presence); the widget itself stays permanently shown. Frame
-- levels are set absolutely to reproduce the legacy layering (levels are absolute
-- within a strata even across subtrees): gradient band below the frame border and
-- text, dispel borders just above the overlay band, type icons above the text.
local function EnsureSlotWidget(btn, frame)
    local w = btn.dfDispelWidget
    if not w then
        w = BuildDispelOverlayWidget(btn)
        btn.dfDispelWidget = w
        w:Show()
        local base = frame:GetFrameLevel()
        -- Levels are derived from the REAL healthBar level (frame+3, Create.lua),
        -- mirroring the legacy widget whose gradient is a healthBar CHILD at
        -- healthBar+2. The old hardcoded base+2/base+3 assumed healthBar sat at
        -- frame+1 — that level-tied the gradient with the health bar itself, so
        -- the (secret-driven) fill rendered OVER the strip on live frames and
        -- the overlay only showed across the missing-health area (live-caught:
        -- Top Edge covering the deficit only).
        local hbLvl = (frame.healthBar and frame.healthBar:GetFrameLevel()) or (base + 3)
        -- +7/+8 clear the whole health-content band (fill, absorb +4, heal-absorb
        -- +5, overflow +3, reduced-max +6) — matches the legacy widget's gradient
        -- at healthBar+7. w carries the game-mode tint CARRIER (and darken/edge
        -- textures), which must clear the band too; the gradient bar sits one
        -- above so its fill is never level-tied with its own parent.
        w:SetFrameLevel(hbLvl + 7)
        w.gradient:SetFrameLevel(hbLvl + 8)
        w.borderTop:SetFrameLevel(base + 7)    -- legacy overlay(+6)+1
        w.borderBottom:SetFrameLevel(base + 7)
        w.borderLeft:SetFrameLevel(base + 7)
        w.borderRight:SetFrameLevel(base + 7)
        local iconLevel = ((frame.contentOverlay and frame.contentOverlay:GetFrameLevel())
            or (base + 25)) + 1                -- legacy contentOverlay+26
        for _, icon in pairs(w.icons) do icon:SetFrameLevel(iconLevel) end
    end
    -- Geometry anchors to the health bar; parenting stays slot-side (see the
    -- gradientAnchorTarget note on LayoutStateChanged). Keep a previous good
    -- target if the frame is mid-initialization (healthBar nil for one pass
    -- during zone transitions) — a nil stamp dropped the layout measure onto
    -- the slot widget's restricted rect.
    w.gradientAnchorTarget = frame.healthBar or w.gradientAnchorTarget
    return w
end

-- GAME-COLOUR mode, main slot. The ONE natively-tintable region per slot (source-
-- verified: CustomAuraButton keeps a single AuraBorder) is a dedicated carrier
-- texture: Blizzard owns its vertex RGBA + Shown (SetAuraBorderColor/SetShown run
-- secure-side with the real dispel type); OUR knobs ride region alpha, texture file
-- and blend mode — properties the native path never touches. Geometry comes from the
-- shared ApplyOverlayLayout pass (it positions the hidden gradient StatusBar; the
-- carrier pins to its rect). EDGE rides four dedicated strip slots
-- (StyleGameEdgeSlot); the border rides its OWN slot (StyleGameBorderSlot) —
-- one bindable region per slot.
local function StyleGameMainSlot(btn, frame, db)
    local w = EnsureSlotWidget(btn, frame)
    if not w.nativeGradient then
        -- ARTWORK sub-layer 2: above the darken texture (sub 1) on the same widget.
        w.nativeGradient = w:CreateTexture(nil, "ARTWORK", nil, 2)
    end

    -- Shared geometry pass (borders/icons/gradient rects + gradientTracksHealth).
    -- It SHOWS nothing we don't re-show below; every colour-carrying region stays
    -- hidden in game mode except the tracking StatusBar (whose FILL texture is the
    -- Blizzard-driven carrier — see below).
    ApplyOverlayLayout(w, db, frame)
    w.borderTop:Hide(); w.borderBottom:Hide(); w.borderLeft:Hide(); w.borderRight:Hide()
    if w.gradientTop then w.gradientTop:Hide() end
    if w.gradientBottom then w.gradientBottom:Hide() end
    if w.gradientLeft then w.gradientLeft:Hide() end
    if w.gradientRight then w.gradientRight:Hide() end
    for _, icon in pairs(w.icons) do icon:Hide() end

    -- Dress the carrier. Show/Hide of the carrier is Blizzard-owned -> a disabled
    -- gradient is expressed as alpha 0, never Hide(). Intensity is palette-inert by
    -- design ("game colours" = Blizzard's exact palette).
    --
    -- "On current health" (FULL + dispelGradientOnCurrentHealth, flagged by
    -- ApplyOverlayLayout as gradientTracksHealth): the carrier is the widget
    -- StatusBar's own FILL TEXTURE — Blizzard tints/shows it, while
    -- UpdateDispelGradientHealth drives the bar's value with the unit's (secret)
    -- health, so the bar clips the tint to current health. This replaces
    -- anchoring a plain texture to the HEALTH bar's fill-texture rect: our own
    -- bar's clipping is guaranteed regardless of how 12.1's secret-health
    -- StatusBars expose (or don't expose) their fill through the texture rect.
    local style = db.dispelGradientStyle or "FULL"
    local showGradient = db.dispelShowGradient ~= false
    local carrier
    if w.gradientTracksHealth then
        w.gradient:SetStatusBarTexture(GRADIENT_TEXTURES[style] or GRADIENT_TEXTURES.FULL)
        carrier = w.gradient:GetStatusBarTexture()   -- re-fetch AFTER SetStatusBarTexture
        w.gradient:Show()
        -- The plain-texture carrier may be left SHOWN by Blizzard's last
        -- SetShown before a rebind — it's unmanaged after the rebind, hide it.
        w.nativeGradient:Hide()
    else
        -- NOTE: never Show() the carrier here — its shown state is Blizzard's
        -- presence gate (a forced Show would tint aura-less units until the next
        -- aura event). The rebind below re-asserts it via UpdateAuraDisplay.
        carrier = w.nativeGradient
        w.gradient:Hide()
        w.nativeGradient:ClearAllPoints()
        if style == "EDGE" then
            -- EDGE renders through FOUR dedicated strip slots (StyleGameEdgeSlot)
            -- — a single bound region can't carry a size-scalable four-edge ramp:
            -- TexCoord-zooming a gradient shows only the ramp's faint inner tail
            -- (live-caught; crop-scaling works on the border's SOLID band only).
            -- Park the main carrier with NO ANCHORS: a rect-less region cannot
            -- render, PERIOD. (Parking on a full-frame rect at alpha 0 was
            -- live-caught rendering at alpha 1 — something in the update flow
            -- restored the region alpha; anchor-less parking can't be stomped.)
            w.nativeGradient:SetTexCoord(0, 1, 0, 1)
        else
            w.nativeGradient:SetTexture(GRADIENT_TEXTURES[style] or GRADIENT_TEXTURES.FULL)
            w.nativeGradient:SetTexCoord(0, 1, 0, 1)
            -- The hidden StatusBar holds the style's rect (TOP/BOTTOM/LEFT/RIGHT
            -- strips, static FULL) — pin the carrier onto it.
            w.nativeGradient:SetAllPoints(w.gradient)
        end
    end
    carrier:SetBlendMode(db.dispelGradientBlendMode or "ADD")
    carrier:SetAlpha((showGradient and style ~= "EDGE") and (db.dispelGradientAlpha or 0.5) or 0)

    -- (Re)bind whenever the carrier region changed (style/tracking flip):
    -- SetAuraBorder REPLACES the registered region (Blizzard_CustomAuraButton.lua:82,
    -- single-region), so a stale bind would tint the wrong texture.
    if (btn._dfDispelBoundCarrier ~= carrier or btn._dfDispelCurveGen ~= DF.dispelCurveGen) and btn.SetAuraBorder then
        btn._dfDispelBoundCarrier = carrier
        btn._dfDispelCurveGen = DF.dispelCurveGen
        local ok, err = pcall(function()
            btn:SetAuraBorder(carrier, {
                style = DispelBorderStyle(),
                customDispelColorMap = DispelBorderMapFor(db),
                showWhenHarmful = true,
                showWhenHelpful = false,
                showIcon = false,
            })
        end)
        DF._dispelBindErr = DF._dispelBindErr or {}
        DF._dispelBindErr.tint = ok and "ok" or tostring(err)
        if not ok and not warnedTintBind then
            warnedTintBind = true
            if DF.DebugWarn then DF:DebugWarn("Dispel", "SetAuraBorder tint bind failed: %s", tostring(err)) end
        end
    end

    -- Darken + pulse are type-independent -> fully supported in game mode. They only
    -- render while the slot button is shown (= a dispellable aura matched).
    if w.gradientDarken then
        if showGradient and db.dispelGradientDarkenEnabled and style ~= "EDGE" then
            w.gradientDarken:SetColorTexture(0, 0, 0, db.dispelGradientDarkenAlpha or 0.5)
            w.gradientDarken:Show()
        else
            w.gradientDarken:Hide()
        end
    end
    -- Pulse the main widget (gradient + darken). The border ring, edge strips and
    -- type icons pulse via their OWN slot holders (ApplySlotPulse) so the whole
    -- overlay breathes together — all groups share the same timing and are (re)played
    -- in the same style pass, keeping them phase-locked.
    if db.dispelAnimate then
        if not w.pulseAnim:IsPlaying() then w.pulseAnim:Play() end
    else
        if w.pulseAnim:IsPlaying() then w.pulseAnim:Stop() end
        w:SetAlpha(1)
    end
end

-- GAME-COLOUR mode, per-type icon slot: presence is gated Blizzard-side by the
-- slot's includeDispelTypes filter, so the type is known at declare time and the
-- icon is a plain DF texture — no native bind at all. Positioned from the DF icon
-- settings; sits above the name/health text like the legacy icons. Dual-type units
-- overlap two icons at the same anchor (rare; mirrors the custom-mode trade-off).
local function StyleGameTypeIconSlot(btn, frame, db, typeName)
    if not btn.dfDispelIconTex then
        local holder = CreateFrame("Frame", nil, btn)
        holder:SetAllPoints(btn)
        btn.dfDispelIconHolder = holder
        btn.dfDispelIconTex = holder:CreateTexture(nil, "OVERLAY")
    end
    btn.dfDispelIconHolder:SetFrameLevel(((frame.contentOverlay and frame.contentOverlay:GetFrameLevel())
        or (frame:GetFrameLevel() + 25)) + 1)
    local tex = btn.dfDispelIconTex
    tex:SetAtlas(GAME_ICON_ATLAS[typeName] or GAME_ICON_ATLAS.Magic)
    if typeName == "Bleed" then
        -- The bleed atlas ships untinted (legacy tinted it too) — use the game
        -- palette's bleed colour to stay "game colours" here.
        local c = AuraUtil and AuraUtil.GetAuraBorderColor and AuraUtil.GetAuraBorderColor("Bleed")
        if c then tex:SetVertexColor(c:GetRGB()) else tex:SetVertexColor(1, 0, 0) end
    else
        tex:SetVertexColor(1, 1, 1)
    end
    local size = db.dispelIconSize or 20
    if db.pixelPerfect then size = DF:PixelPerfect(size) end
    local pos = db.dispelIconPosition or "CENTER"
    tex:ClearAllPoints()
    tex:SetPoint(pos, btn.dfDispelIconHolder, pos, db.dispelIconOffsetX or 0, db.dispelIconOffsetY or 0)
    tex:SetSize(size, size)
    tex:SetAlpha(db.dispelIconAlpha or 1)
    ApplySlotPulse(btn.dfDispelIconHolder, db.dispelAnimate)
end

-- GAME-COLOUR mode, border slot: ONE square-ring texture (solid band, transparent
-- centre — Media/DF_SquareBorder) bound as this slot's carrier; Blizzard tints and
-- shows it with the same aura the main slot carries. Nine-slice pins the band at a
-- uniform, configurable thickness on any frame shape (stretched ring art would
-- render thicker sides than top on wide frames); the solid band makes the slice
-- semantics-proof — any margin ≤ the 32px art band samples solid white.
local function StyleGameBorderSlot(btn, frame, db)
    local ring = btn.dfDispelRing
    if not ring then
        local holder = CreateFrame("Frame", nil, btn)
        holder:SetAllPoints(btn)
        -- Just above the gradient band (hbLvl+7/+8, EnsureSlotWidget) — mirrors
        -- the custom borders sitting above the custom gradient.
        local hbLvl = (frame.healthBar and frame.healthBar:GetFrameLevel())
            or (frame:GetFrameLevel() + 3)
        holder:SetFrameLevel(hbLvl + 9)
        ring = holder:CreateTexture(nil, "ARTWORK")
        ring:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\DF_SquareBorder")
        btn.dfDispelRing = ring
        btn.dfDispelRingHolder = holder
    end
    local thickness = db.dispelBorderSize or 2
    if db.pixelPerfect then thickness = DF:PixelPerfect(thickness) end
    local inset = db.dispelBorderInset or 0
    -- Positive inset EXPANDS outward — same convention as the legacy borders.
    ring:ClearAllPoints()
    ring:SetPoint("TOPLEFT", btn, "TOPLEFT", -inset, inset)
    ring:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", inset, -inset)
    ring:SetAlpha(db.dispelBorderAlpha or 0.8)
    ring:SetBlendMode("BLEND")
    -- Uniform thickness via ASYMMETRIC TexCoord crop (the DF_SquareRing
    -- technique): zoom into the art independently per axis so the 25% art band
    -- renders at exactly `thickness` px on every edge regardless of the frame's
    -- aspect ratio. Solve (B - c)/(1 - 2c) = t/dim for the crop c per axis.
    -- (SetTextureSliceMargins was tried first and rejected: its margins cut the
    -- SOURCE texture, so any margin below the art band leaves band pixels in
    -- the stretchable centre — the border blew up to a quarter of the frame,
    -- live-caught.) The frame rect is OURS (readable); style re-runs on layout
    -- version bumps, so a frame resize catches up on the next dispel pass.
    local rw = (frame:GetWidth() or 80) + 2 * inset
    local rh = (frame:GetHeight() or 40) + 2 * inset
    local B = 0.25   -- art band fraction (32px of the 128px file)
    local function cropFor(dim)
        local f = thickness / math.max(dim, 1)
        if f >= B then return 0 end   -- degenerate (tiny frame): draw the art uncropped
        return (B - f) / (1 - 2 * f)
    end
    local cx, cy = cropFor(rw), cropFor(rh)
    ring:SetTexCoord(cx, 1 - cx, cy, 1 - cy)
    if (btn._dfDispelBoundCarrier ~= ring or btn._dfDispelCurveGen ~= DF.dispelCurveGen) and btn.SetAuraBorder then
        btn._dfDispelBoundCarrier = ring
        btn._dfDispelCurveGen = DF.dispelCurveGen
        local ok, err = pcall(function()
            btn:SetAuraBorder(ring, {
                style = DispelBorderStyle(),
                customDispelColorMap = DispelBorderMapFor(db),
                showWhenHarmful = true,
                showWhenHelpful = false,
                showIcon = false,
            })
        end)
        DF._dispelBindErr = DF._dispelBindErr or {}
        DF._dispelBindErr.ring = ok and "ok" or tostring(err)
        if not ok and not warnedTintBind then
            warnedTintBind = true
            if DF.DebugWarn then DF:DebugWarn("Dispel", "SetAuraBorder ring bind failed: %s", tostring(err)) end
        end
    end
    ApplySlotPulse(btn.dfDispelRingHolder, db.dispelAnimate)
end

-- GAME mode, EDGE strip slot: one slot per edge, each binding its own gradient
-- strip texture, positioned from settings on the padded frame rect (immune to
-- the reduced-max health-bar clip). Geometry mirrors ApplyOverlayLayout's EDGE
-- branch: strip depth = padded frame dimension × Gradient Size.
local function StyleGameEdgeSlot(btn, frame, db, edge)
    local tex = btn.dfDispelEdgeTex
    if not tex then
        local holder = CreateFrame("Frame", nil, btn)
        holder:SetAllPoints(btn)
        local hbLvl = (frame.healthBar and frame.healthBar:GetFrameLevel())
            or (frame:GetFrameLevel() + 3)
        holder:SetFrameLevel(hbLvl + 7)   -- the gradient band (EnsureSlotWidget scheme)
        tex = holder:CreateTexture(nil, "ARTWORK", nil, 2)
        btn.dfDispelEdgeTex = tex
        btn.dfDispelEdgeHolder = holder
    end
    tex:SetTexture(EDGE_GRADIENT_TEXTURES[edge])
    local pad = db.framePadding or 0
    local gradientSize = db.dispelGradientSize or 0.3
    local innerW = math.max((frame:GetWidth() or 80) - 2 * pad, 1)
    local innerH = math.max((frame:GetHeight() or 40) - 2 * pad, 1)
    local dH = innerH * gradientSize   -- strip depth, horizontal strips
    local dW = innerW * gradientSize   -- strip depth, vertical strips
    -- Rect from TWO DIAGONAL POINTS only (the ring's proven pattern on these
    -- holders) — no SetHeight/SetWidth on regions inside the button subtree.
    tex:ClearAllPoints()
    if edge == "TOP" then
        tex:SetPoint("TOPLEFT", frame, "TOPLEFT", pad, -pad)
        tex:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -pad, -(pad + dH))
    elseif edge == "BOTTOM" then
        tex:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", pad, pad + dH)
        tex:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -pad, pad)
    elseif edge == "LEFT" then
        tex:SetPoint("TOPLEFT", frame, "TOPLEFT", pad, -pad)
        tex:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", pad + dW, pad)
    else -- RIGHT
        tex:SetPoint("TOPLEFT", frame, "TOPRIGHT", -(pad + dW), -pad)
        tex:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -pad, pad)
    end
    tex:SetBlendMode(db.dispelGradientBlendMode or "ADD")
    tex:SetAlpha(db.dispelGradientAlpha or 0.5)
    if (btn._dfDispelBoundCarrier ~= tex or btn._dfDispelCurveGen ~= DF.dispelCurveGen) and btn.SetAuraBorder then
        btn._dfDispelBoundCarrier = tex
        btn._dfDispelCurveGen = DF.dispelCurveGen
        local ok, err = pcall(function()
            btn:SetAuraBorder(tex, {
                style = DispelBorderStyle(),
                customDispelColorMap = DispelBorderMapFor(db),
                showWhenHarmful = true,
                showWhenHelpful = false,
                showIcon = false,
            })
        end)
        DF._dispelBindErr = DF._dispelBindErr or {}
        DF._dispelBindErr.edge = ok and "ok" or tostring(err)
        if not ok and not warnedTintBind then
            warnedTintBind = true
            if DF.DebugWarn then DF:DebugWarn("Dispel", "SetAuraBorder edge bind failed: %s", tostring(err)) end
        end
    end
    ApplySlotPulse(btn.dfDispelEdgeHolder, db.dispelAnimate)
end

-- Style every live slot button per the plan. Returns false while no buttons exist
-- (combat-deferred build / fake backend) so the caller doesn't latch the version.
local function StyleDispelSlots(frame, db, h, slots)
    local buttons = h.GetOverlaySlots and h:GetOverlaySlots()
    if not buttons or not next(buttons) then return false end
    local styled = false
    for i = 1, #slots do
        local info = slots[i]
        local btn = buttons[info.key]
        if btn then
            styled = true
            if info.iconType then
                StyleGameTypeIconSlot(btn, frame, db, info.iconType)
            elseif info.edgeSide then
                StyleGameEdgeSlot(btn, frame, db, info.edgeSide)
            elseif info.key == "gameborder" then
                StyleGameBorderSlot(btn, frame, db)
            else
                StyleGameMainSlot(btn, frame, db)
            end
        end
    end
    -- Seed any health-tracking gradient bars now (both colour modes): the health
    -- hook only fires on health CHANGES, and the layout pass just neutralized the
    -- fill to full — without a seed a tracking bar renders full until the first
    -- health tick. Early-outs when nothing tracks.
    if styled and DF.UpdateDispelGradientHealth then
        DF:UpdateDispelGradientHealth(frame)
    end
    return styled
end

-- Render gate (excludes test mode — the test paint previews on the shared art
-- with Blizzard palette colours; see UpdateDispelOverlay's test branch).
function DF:UseFactoryForDispelOverlay(frame, db)
    return DF.AuraContainer and DF.AuraContainer.IsSupported()
        and not (DF.testMode or DF.raidTestMode)
end

-- GUI-facing predicate (does NOT exclude test mode — mirrors FactoryOwnsBuffRow).
function DF:FactoryOwnsDispelOverlay(db)
    return (DF.AuraContainer and DF.AuraContainer.IsSupported()) or false
end

-- Drive the factory overlay for one frame. Mirrors the row drives: lazy create,
-- recreate on a structural signature change, keep the container on the frame's unit,
-- re-style on a layout-version bump (out of combat). Cheap when nothing changed —
-- this runs per UNIT_AURA via UpdateDispelOverlay.
function DF:DriveDispelOverlayFactory(frame, db)
    -- No double render: the legacy overlay stays hidden while the factory owns.
    if frame.dfDispelOverlay and frame.dfDispelOverlay:IsShown() then
        HideOverlay(frame.dfDispelOverlay)
        RevertDispelNameText(frame)
    end
    frame.dfLastDispelAuraID = nil

    local h = frame.dispelFactory
    local enabled = db.dispelOverlayEnabled ~= false
    if not enabled then
        if h then
            h:Destroy()   -- self-defers to regen in lockdown
            frame.dispelFactory = nil
            frame.dispelFactorySig = nil
        end
        return
    end

    -- Fast path (this runs per UNIT_AURA in combat): already built AND styled at
    -- the current layout version + build generation -> only unit upkeep remains.
    -- Skips the per-call plan/signature allocation entirely; any settings change
    -- goes through InvalidateAuraLayout, which breaks the version latch.
    local ver = DF.auraLayoutVersion or 0
    if h and frame.dfDispelFactoryVersion == ver and frame.dfDispelStyledGen == (h._gen or 0) then
        if h:GetUnit() ~= frame.unit then h:SetUnit(frame.unit) end
        return
    end

    local sig, slots, needPolicy = dispelFactoryPlanAndSig(db)
    if not sig then return end

    if not h or frame.dispelFactorySig ~= sig then
        if h then h:Destroy() end
        local filterRecords = {}
        for i = 1, #slots do
            filterRecords[i] = { filter = slots[i].filter, key = slots[i].key,
                                 candidateFilters = slots[i].candidateFilters }
        end
        h = DF.AuraContainer:Create(frame, {
            unit = frame.unit,
            mode = "overlay",
            filter = filterRecords,
            processingPolicy = needPolicy and { policy = "ProcessAura" } or nil,
            frameLevelOffset = 0,   -- widget levels are set absolutely (legacy layering)
            enabled = true,
        })
        frame.dispelFactory = h
        frame.dispelFactorySig = h and sig or nil
        frame.dfDispelFactoryVersion = nil   -- force a style pass on the new buttons
    end
    if not h then return end

    if h:GetUnit() ~= frame.unit then h:SetUnit(frame.unit) end

    -- Style pass: regions are create-once, styling is re-runnable. Gated on the
    -- layout version (GUI changes bump it; colour tweaks clear the latch directly)
    -- AND the handle's build generation — every native rebuild (regen-deferred
    -- build, test-mode round trip) creates FRESH buttons that carry none of our
    -- decorations, so a stale version latch alone would leave them invisible.
    -- OOC only; not latched until buttons exist.
    local gen = h._gen or 0
    if (frame.dfDispelFactoryVersion ~= ver or frame.dfDispelStyledGen ~= gen)
        and not InCombatLockdown() then
        if StyleDispelSlots(frame, db, h, slots) then
            frame.dfDispelFactoryVersion = ver
            frame.dfDispelStyledGen = gen
        end
    end
end

function DF:UpdateDispelOverlay(frame)
    if not frame then return end

    -- PERF TEST: Skip if disabled
    if DF.PerfTest and not DF.PerfTest.enableDispel then
        HideDispelAndInvalidate(frame)
        return
    end

    -- Use raid DB for raid frames, party DB for party frames
    local db = DF:GetFrameDB(frame)

    -- Check if in test mode first (allows preview even when dispel overlay is disabled)
    local isRaidFrame = frame.isRaidFrame
    local inRelevantTestMode = (isRaidFrame and DF.raidTestMode) or (not isRaidFrame and DF.testMode)

    -- 12.1 container path: Blizzard drives presence + colour via overlay slots; this
    -- call only keeps the bridge current (cheap when nothing changed). Excludes test
    -- mode — the test paint keeps the legacy RGB path below until P5.
    if DF:UseFactoryForDispelOverlay(frame, db) then
        DF:DriveDispelOverlayFactory(frame, db)
        return
    end

    -- Decide whether the legacy overlay path should run (only reachable when
    -- the factory doesn't own — dev toggle off / unsupported client). In test
    -- mode we honour testShowDispelGlow; otherwise the enable toggle.
    local shouldRun
    if inRelevantTestMode then
        shouldRun = db and db.testShowDispelGlow
    else
        shouldRun = db and db.dispelOverlayEnabled ~= false
    end

    if not shouldRun then
        -- Only run the cleanup path when there's DF overlay state that actually
        -- needs clearing. On a fresh frame with the overlay off, every flag
        -- below is falsy and we skip HideDispelAndInvalidate entirely. This
        -- matters in combat where UpdateDispelOverlay fires many times per
        -- second per frame.
        local hasState = (frame.dfDispelOverlay and frame.dfDispelOverlay:IsShown())
                       or frame.dfDispelNameTextActive
                       or (frame.dfLastDispelAuraID ~= nil)
        if hasState then
            HideDispelAndInvalidate(frame)
        end
        return
    end

    local unit = frame.unit

    -- Handle test mode - only show dispels on the correct frame type
    if inRelevantTestMode then
        local testIndex = frame.index
        if testIndex == nil then
            if frame.unit == "player" then
                testIndex = 0
            elseif frame.unit then
                testIndex = tonumber(frame.unit:match("%d+")) or 0
            else
                testIndex = 0
            end
        end

        local testData = DF.GetTestUnitData and DF:GetTestUnitData(testIndex, frame.isRaidFrame)

        if testData and testData.dispelType then
            local overlay = CreateDispelOverlay(frame)
            -- Preview what the container path renders live: Blizzard's palette
            -- colour on the shared art (the game engine owns the RGB live; the
            -- legacy widget's border/EDGE regions are geometry-matched
            -- stand-ins for the ring slot / vignette carrier). GetTestDispelColor
            -- is the fallback when the palette API is unavailable.
            local r, g, b = GetTestDispelColor(testData.dispelType, db)
            if AuraUtil and AuraUtil.GetAuraBorderColor then
                local ok, c = pcall(AuraUtil.GetAuraBorderColor, testData.dispelType)
                if ok and c then r, g, b = c:GetRGB() end
            end

            -- Calculate OOR alpha multiplier for test mode
            local oorMultiplier = 1.0
            if db.testShowOutOfRange and testData.outOfRange and not testData.status then
                local oorDispelAlpha = db.oorDispelOverlayAlpha or 0.55
                oorMultiplier = oorDispelAlpha
            end

            ShowOverlayWithRGB(overlay, r, g, b, db, testData.dispelType, oorMultiplier, frame, testData)
            -- Test mode doesn't use the last-rendered-aura skip — it has
            -- its own lifecycle and can re-render every tick cheaply.
            frame.dfLastDispelAuraID = nil
        else
            HideDispelAndInvalidate(frame)
        end
        return
    end

    -- If we're in a test mode but this frame type doesn't match, hide any overlay and skip
    if (DF.raidTestMode and not isRaidFrame) or (DF.testMode and isRaidFrame) then
        HideDispelAndInvalidate(frame)
        return
    end

    -- Live path: the container path above owns all live rendering on 12.1
    -- (the only way here is the transient in-combat IsSupported()=false window
    -- before the login warm) -- leave state untouched; the next call re-drives.
end

-- ============================================================
-- UPDATE ALL OVERLAYS
-- ============================================================

function DF:UpdateAllDispelOverlays()
    -- In test mode, only update test frames.  Live frames are hidden behind the
    -- test container and must not receive overlay state derived from test data —
    -- if they do, the overlay appears "stuck" on live frames after test mode
    -- closes.  When test mode exits, DF.testMode is set to false *before* the
    -- cleanup C_Timer fires, so the live-frame cleanup pass still runs correctly.
    if DF.testMode or DF.raidTestMode then
        if DF.testMode and DF.testPartyFrames then
            local db = DF:GetDB()
            local count = db and db.testFrameCount or 5
            for i = 0, count - 1 do
                local frame = DF.testPartyFrames[i]
                if frame and frame:IsShown() then
                    DF:UpdateDispelOverlay(frame)
                end
            end
        end
        if DF.raidTestMode and DF.testRaidFrames then
            local raidDb = DF:GetRaidDB()
            local count = raidDb and raidDb.raidTestFrameCount or 10
            for i = 1, count do
                local frame = DF.testRaidFrames[i]
                if frame and frame:IsShown() then
                    DF:UpdateDispelOverlay(frame)
                end
            end
        end
        return
    end
    DF:IterateAllFrames(function(frame)
        if frame then
            DF:UpdateDispelOverlay(frame)
        end
    end)
end

-- ============================================================
-- FRAME LOOKUP
-- ============================================================

local function FindFrameByUnit(unit)
    if not unit then return nil end
    
    -- Fast path: use unitFrameMap
    if DF.unitFrameMap and DF.unitFrameMap[unit] then
        return DF.unitFrameMap[unit]
    end
    
    local foundFrame = nil
    
    DF:IterateAllFrames(function(frame)
        if frame and frame.unit == unit then
            foundFrame = frame
            return true  -- Stop iteration
        end
    end)
    
    return foundFrame
end

-- ============================================================
-- EVENT HANDLING
-- ============================================================

local eventFrame = CreateFrame("Frame")
-- PERFORMANCE FIX 2025-01-20: UNIT_AURA is now handled by the frame's own event handler
-- in Create.lua, which calls UpdateDispelOverlay directly. This avoids this frame
-- receiving ALL UNIT_AURA events in the game world just to filter them down.
-- eventFrame:RegisterEvent("UNIT_AURA")  -- REMOVED - handled by frame events now
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(0.5, function()
            DF:UpdateAllDispelOverlays()
        end)
    end
end)

-- ============================================================
-- DEBUG COMMAND
-- ============================================================

function DF:DebugDispel(unit)
    unit = unit or "player"
    print("|cff00ff00DandersFrames:|r Dispel Debug for " .. unit)
    
    local db = DF:GetDB()
    print("  dispelOverlayEnabled: " .. tostring(db and db.dispelOverlayEnabled))
    print("  dispelOverlayDispelType: " .. tostring(db and db.dispelOverlayDispelType))
    
    -- Get debuffs sorted by expiration
    local sortRule = Enum.UnitAuraSortRule and Enum.UnitAuraSortRule.Expiration or 3
    local auras = C_UnitAuras.GetUnitAuras(unit, "HARMFUL", nil, sortRule)
    
    if not auras or #auras == 0 then
        print("  No debuffs found")
        return
    end
    
    print("  Found " .. #auras .. " debuffs (sorted by expiration)")
    
    -- Show debuffs with dispelName
    print("  |cffffcc00Debuffs:|r")
    local lastDispellable = nil
    for i, aura in ipairs(auras) do
        if i > 10 then break end
        local auraName = aura.name or "?"
        local dispelName = aura.dispelName
        
        if dispelName ~= nil then
            print(string.format("    [%d] %s - |cff00ff00%s|r", i, auraName, dispelName))
            lastDispellable = aura
        else
            print(string.format("    [%d] %s - |cffff0000nil (not dispellable)|r", i, auraName))
        end
    end
    
    if lastDispellable then
        print("  |cff00ff00Last dispellable:|r " .. (lastDispellable.name or "?") .. " (" .. lastDispellable.dispelName .. ")")
    else
        print("  |cffff0000No dispellable debuffs|r")
    end
    
    print("  |cffffcc00Frame/Overlay Status:|r")
    local frame = FindFrameByUnit(unit)
    if frame then
        print("    Frame found: YES")
        print("    Frame shown: " .. tostring(frame:IsShown()))
        if frame.dfDispelOverlay then
            local overlay = frame.dfDispelOverlay
            print("    Overlay exists: YES")
            print("    Overlay shown: " .. (overlay:IsShown() and "|cff00ff00YES|r" or "|cffff0000NO|r"))
            print("    Overlay alpha: " .. string.format("%.2f", overlay:GetAlpha()))
            if overlay.borderTop then
                print("    BorderTop shown: " .. tostring(overlay.borderTop:IsShown()))
            end
            if overlay.icons then
                local iconsShown = {}
                for name, icon in pairs(overlay.icons) do
                    if icon:IsShown() then
                        table.insert(iconsShown, name)
                    end
                end
                print("    Icons shown: " .. (#iconsShown > 0 and table.concat(iconsShown, ", ") or "none"))
            end
        else
            print("    Overlay exists: NO")
        end
    else
        print("    Frame found: NO")
    end
    
    -- Force update
    print("  |cffffcc00Forcing update...|r")
    if frame then
        DF:UpdateDispelOverlay(frame)
        C_Timer.After(0.1, function()
            if frame.dfDispelOverlay then
                print("  After update - Overlay shown: " .. tostring(frame.dfDispelOverlay:IsShown()))
            end
        end)
    end
end

DF:RegisterDebugSlash("DFDISPEL", "Dispel overlay diagnostics", false, "/dfdispel")
SlashCmdList["DFDISPEL"] = function(msg)
    if msg == "debug" then
        DF.debugDispel = not DF.debugDispel
        print("|cff00ff00DandersFrames:|r Dispel debug " .. (DF.debugDispel and "|cff00ff00ENABLED|r" or "|cffff0000DISABLED|r"))
    elseif msg == "test" then
        -- Test dispelName field
        print("|cff00ff00DandersFrames:|r Testing dispelName field...")
        
        -- Test against first BUFF (should have nil dispelName)
        local buff = C_UnitAuras.GetAuraDataByIndex("player", 1, "HELPFUL")
        if buff then
            print("  Buff: " .. (buff.name or "?"))
            print("  dispelName: " .. (buff.dispelName and ("|cff00ff00" .. buff.dispelName .. "|r") or "|cffff0000nil|r"))
        else
            print("  No buff found")
        end
        
        -- Test against first DEBUFF
        local debuff = C_UnitAuras.GetAuraDataByIndex("player", 1, "HARMFUL")
        if debuff then
            print("  Debuff: " .. (debuff.name or "?"))
            print("  dispelName: " .. (debuff.dispelName and ("|cff00ff00" .. debuff.dispelName .. "|r") or "|cffff0000nil|r"))
        else
            print("  No debuff found")
        end
    elseif msg == "cvar" then
        -- Test/discover dispel-related CVars
        print("|cff00ff00DandersFrames:|r Checking dispel-related CVars...")
        
        -- Known CVars to check
        local cvarsToCheck = {
            "raidFramesDisplayOnlyDispellableDebuffs",
            "showDispelDebuffs",
            "showCastableBuffs",
            "raidFramesDisplayDebuffs",
            "raidFramesDisplayDispellableDebuffs",
            "raidOptionDisplayOnlyDispellableDebuffs",
            "raidFramesDispelMode",
        }
        
        for _, cvarName in ipairs(cvarsToCheck) do
            local value = GetCVar(cvarName)
            if value then
                print(string.format("  %s = |cff00ff00%s|r", cvarName, tostring(value)))
            else
                print(string.format("  %s = |cffff0000not found|r", cvarName))
            end
        end
        
        -- Try to find the dropdown setting via Settings API
        print("")
        print("|cffffcc00Checking Settings API...|r")
        if Settings and Settings.GetValue then
            -- Try various possible setting names
            local settingsToCheck = {
                "PROXY_RAID_FRAMES_DISPLAY_ONLY_DISPELLABLE_DEBUFFS",
                "raidFramesDisplayOnlyDispellableDebuffs", 
                "dispelDebuffDisplayMode",
                "raidFramesDispelDebuffDisplayMode",
                "displayDispellableDebuffs",
            }
            for _, settingName in ipairs(settingsToCheck) do
                local ok, value = pcall(function() return Settings.GetValue(settingName) end)
                if ok and value ~= nil then
                    print(string.format("  Settings.%s = |cff00ff00%s|r", settingName, tostring(value)))
                end
            end
        end
        
        -- Check C_CVar for all cvars containing "dispel" or "debuff"
        print("")
        print("|cffffcc00Searching all CVars for 'dispel'...|r")
        if C_CVar and C_CVar.GetCVarInfo then
            -- Can't enumerate all CVars, but we can try specific ones
            local moreToCheck = {
                "raidFramesDisplayDispelDebuffs",
                "partyFramesDisplayOnlyDispellableDebuffs",
                "displayOnlyDispellableDebuffs",
                "dispelDebuffIndicatorMode",
                "raidOptionDispelDebuffIndicator",
            }
            for _, cvarName in ipairs(moreToCheck) do
                local value = GetCVar(cvarName)
                if value then
                    print(string.format("  %s = |cff00ff00%s|r", cvarName, tostring(value)))
                end
            end
        end
        
        -- Check EditMode settings if available
        print("")
        print("|cffffcc00Checking EditMode/CompactUnitFrame settings...|r")
        if EditModeManagerFrame then
            print("  EditModeManagerFrame exists")
        end
        
        -- Try to find the setting on CompactRaidFrameContainer
        if CompactRaidFrameContainer then
            print("  CompactRaidFrameContainer exists")
            if CompactRaidFrameContainer.displayOnlyDispellableDebuffs ~= nil then
                print("    .displayOnlyDispellableDebuffs = " .. tostring(CompactRaidFrameContainer.displayOnlyDispellableDebuffs))
            end
            if CompactRaidFrameContainer.dispelDebuffDisplayMode ~= nil then
                print("    .dispelDebuffDisplayMode = " .. tostring(CompactRaidFrameContainer.dispelDebuffDisplayMode))
            end
        end
        
        -- Check DefaultCompactUnitFrameSetupOptions
        if DefaultCompactUnitFrameSetupOptions then
            print("  DefaultCompactUnitFrameSetupOptions exists")
            for k, v in pairs(DefaultCompactUnitFrameSetupOptions) do
                if type(k) == "string" and (k:lower():find("dispel") or k:lower():find("debuff")) then
                    print(string.format("    .%s = %s", k, tostring(v)))
                end
            end
        end
        
        -- Check the raid profile settings
        if GetRaidProfileOption then
            print("")
            print("|cffffcc00Checking Raid Profile options...|r")
            local profile = GetActiveRaidProfile and GetActiveRaidProfile() or nil
            if profile then
                print("  Active profile: " .. tostring(profile))
                local optionsToCheck = {
                    "displayOnlyDispellableDebuffs",
                    "dispelDebuffDisplayMode",
                    "displayDebuffs",
                }
                for _, opt in ipairs(optionsToCheck) do
                    local ok, value = pcall(function() return GetRaidProfileOption(profile, opt) end)
                    if ok and value ~= nil then
                        print(string.format("    %s = |cff00ff00%s|r", opt, tostring(value)))
                    end
                end
            end
        end
        
    elseif msg == "cvar1" then
        -- Set to show only dispellable debuffs
        print("|cff00ff00DandersFrames:|r Setting raidFramesDisplayOnlyDispellableDebuffs = 1")
        SetCVar("raidFramesDisplayOnlyDispellableDebuffs", 1)
        
    elseif msg == "cvar0" then
        -- Set to show all debuffs
        print("|cff00ff00DandersFrames:|r Setting raidFramesDisplayOnlyDispellableDebuffs = 0")
        SetCVar("raidFramesDisplayOnlyDispellableDebuffs", 0)
        
    elseif msg == "indicator" then
        -- Check and show the raidFramesDispelIndicatorType setting
        print("|cff00ff00DandersFrames:|r Checking raidFramesDispelIndicatorType...")
        
        local indicatorType = nil
        
        -- Find a Blizzard compact unit frame to check
        local blizzFrame = nil
        for i = 1, 4 do
            local frame = _G["CompactPartyFrameMember" .. i]
            if frame and frame.optionTable then
                blizzFrame = frame
                break
            end
        end
        if not blizzFrame then
            for i = 1, 40 do
                local frame = _G["CompactRaidFrame" .. i]
                if frame and frame.optionTable then
                    blizzFrame = frame
                    break
                end
            end
        end
        
        if blizzFrame and blizzFrame.optionTable then
            indicatorType = blizzFrame.optionTable.raidFramesDispelIndicatorType
            print("  Current value: " .. tostring(indicatorType))
            if indicatorType == 0 then
                print("  Mode: |cffff0000DISABLED|r")
            elseif indicatorType == 1 then
                print("  Mode: |cff00ff00DISPELLABLE BY ME|r (optimal for PLAYER_DISPELLABLE)")
            elseif indicatorType == 2 then
                print("  Mode: |cffffaa00SHOW ALL|r")
            end
        else
            print("  |cffff0000Could not find Blizzard frame to check|r")
        end
        
    elseif msg == "setindicator" then
        -- This command has been disabled as modifying optionTable causes errors
        print("|cff00ff00DandersFrames:|r setindicator command disabled.")
        print("  Modifying frame.optionTable causes protected value errors in combat.")
        print("  Use the 'Show Overlay For' dropdown in DandersFrames settings instead.")
        print("  Our addon handles filtering internally based on that setting.")
        
    elseif msg == "dump" then
        -- Dump ALL properties from key objects
        print("|cff00ff00DandersFrames:|r Comprehensive dump...")
        
        -- Dump DefaultCompactUnitFrameSetupOptions
        print("")
        print("|cffffcc00DefaultCompactUnitFrameSetupOptions:|r")
        if DefaultCompactUnitFrameSetupOptions then
            for k, v in pairs(DefaultCompactUnitFrameSetupOptions) do
                print(string.format("  %s = %s (%s)", tostring(k), tostring(v), type(v)))
            end
        else
            print("  nil")
        end
        
        -- Dump DefaultCompactMiniFrameSetUpOptions
        print("")
        print("|cffffcc00DefaultCompactMiniFrameSetUpOptions:|r")
        if DefaultCompactMiniFrameSetUpOptions then
            for k, v in pairs(DefaultCompactMiniFrameSetUpOptions) do
                print(string.format("  %s = %s (%s)", tostring(k), tostring(v), type(v)))
            end
        else
            print("  nil")
        end
        
    elseif msg == "dump2" then
        -- Dump CompactRaidFrameManager settings
        print("|cff00ff00DandersFrames:|r Dumping CompactRaidFrameManager...")
        
        if CompactRaidFrameManager then
            print("  CompactRaidFrameManager exists")
            -- Check for setting-related properties
            for k, v in pairs(CompactRaidFrameManager) do
                if type(k) == "string" and type(v) ~= "function" and type(v) ~= "table" then
                    print(string.format("    %s = %s", k, tostring(v)))
                end
            end
            
            -- Check container
            if CompactRaidFrameManager.container then
                print("")
                print("  |cffffcc00.container properties:|r")
                for k, v in pairs(CompactRaidFrameManager.container) do
                    if type(k) == "string" and type(v) ~= "function" and type(v) ~= "table" then
                        print(string.format("    %s = %s", k, tostring(v)))
                    end
                end
            end
        else
            print("  nil")
        end
        
        -- Check CompactUnitFrameProfiles
        print("")
        print("|cffffcc00CompactUnitFrameProfiles:|r")
        if CompactUnitFrameProfiles then
            print("  exists")
            if CompactUnitFrameProfiles.selectedProfile then
                print("  selectedProfile = " .. tostring(CompactUnitFrameProfiles.selectedProfile))
            end
        else
            print("  nil")
        end
        
    elseif msg == "dump3" then
        -- Try to find the setting by checking a Blizzard compact frame directly
        print("|cff00ff00DandersFrames:|r Checking Blizzard frame options...")
        
        -- Find a Blizzard compact unit frame
        local blizzFrame = nil
        if CompactRaidFrameContainer then
            -- Try to get first raid frame
            for i = 1, 40 do
                local frameName = "CompactRaidFrame" .. i
                local frame = _G[frameName]
                if frame then
                    blizzFrame = frame
                    break
                end
            end
        end
        
        if not blizzFrame then
            -- Try party frames
            for i = 1, 4 do
                local frameName = "CompactPartyFrameMember" .. i
                local frame = _G[frameName]
                if frame then
                    blizzFrame = frame
                    break
                end
            end
        end
        
        if blizzFrame then
            print("  Found frame: " .. blizzFrame:GetName())
            
            -- Check optionTable
            if blizzFrame.optionTable then
                print("")
                print("  |cffffcc00.optionTable:|r")
                for k, v in pairs(blizzFrame.optionTable) do
                    if type(v) ~= "function" and type(v) ~= "table" then
                        local vStr = tostring(v)
                        if k:lower():find("dispel") or k:lower():find("debuff") then
                            print(string.format("    |cff00ff00%s = %s|r", k, vStr))
                        else
                            print(string.format("    %s = %s", k, vStr))
                        end
                    end
                end
            end
        else
            print("  No Blizzard compact frame found")
        end
        
    elseif msg == "dump4" then
        -- Deep search for dispel indicator setting source
        print("|cff00ff00DandersFrames:|r Searching for dispel indicator setting...")
        
        -- Check all GetCVarInfo for dispel-related CVars
        print("")
        print("|cffffcc00Searching CVars:|r")
        local cvarNames = {
            "raidFramesDispelIndicatorType",
            "raidFramesDisplayDispelDebuffs", 
            "showDispelDebuffs",
            "raidFramesDispelMode",
            "compactUnitFrameDispelIndicator",
        }
        for _, name in ipairs(cvarNames) do
            local val = GetCVar(name)
            if val then
                print("  " .. name .. " = " .. tostring(val))
            end
        end
        
        -- Check Settings API for dispel-related settings
        print("")
        print("|cffffcc00Checking Settings API:|r")
        if Settings then
            -- Try to find dispel-related settings
            local settingNames = {
                "raidFramesDispelIndicatorType",
                "PROXY_RAID_FRAMES_DISPEL_INDICATOR_TYPE",
                "RaidFramesDispelIndicator",
            }
            for _, name in ipairs(settingNames) do
                local ok, val = pcall(function() return Settings.GetValue(name) end)
                if ok and val ~= nil then
                    print("  Settings." .. name .. " = " .. tostring(val))
                end
            end
            
            -- Try to enumerate settings categories
            if Settings.GetAllCategories then
                local categories = Settings.GetAllCategories()
                if categories then
                    print("  Found " .. #categories .. " settings categories")
                end
            end
        else
            print("  Settings API not available")
        end
        
        -- Check DefaultCompactUnitFrameSetupOptions
        print("")
        print("|cffffcc00DefaultCompactUnitFrameSetupOptions:|r")
        if DefaultCompactUnitFrameSetupOptions then
            for k, v in pairs(DefaultCompactUnitFrameSetupOptions) do
                if type(k) == "string" and k:lower():find("dispel") then
                    print("  " .. k .. " = " .. tostring(v))
                end
            end
        end
        
        -- Check EditModeManagerFrame
        print("")
        print("|cffffcc00EditModeManagerFrame:|r")
        if EditModeManagerFrame then
            print("  exists")
            if EditModeManagerFrame.GetAccountSettingValue then
                local ok, val = pcall(function() 
                    return EditModeManagerFrame:GetAccountSettingValue(Enum.EditModeAccountSetting.ShowDispelDebuffs)
                end)
                if ok then
                    print("  ShowDispelDebuffs = " .. tostring(val))
                end
            end
        end
        
        -- Check if there's a function that provides the optionTable
        print("")
        print("|cffffcc00Checking option providers:|r")
        if DefaultCompactUnitFrameOptions then
            print("  DefaultCompactUnitFrameOptions exists")
            if type(DefaultCompactUnitFrameOptions) == "table" then
                for k, v in pairs(DefaultCompactUnitFrameOptions) do
                    if type(k) == "string" and k:lower():find("dispel") then
                        print("    " .. k .. " = " .. tostring(v))
                    end
                end
            end
        end
        
        if CompactUnitFrameProfilesGetAutoActivationState then
            print("  CompactUnitFrameProfilesGetAutoActivationState exists")
        end
        
        -- Check EditModeSettingDisplayInfoManager for dispel settings
        if EditModeSettingDisplayInfoManager then
            print("  EditModeSettingDisplayInfoManager exists")
        end

    elseif msg == "profile" then
        -- Dump all raid profile options
        print("|cff00ff00DandersFrames:|r Dumping Raid Profile options...")
        
        if GetActiveRaidProfile and GetRaidProfileOption then
            local profile = GetActiveRaidProfile()
            print("  Active profile: " .. tostring(profile))
            
            -- Try to get all options by checking known option names
            local knownOptions = {
                "keepGroupsTogether", "displayHealPrediction", "displayAggroHighlight",
                "displayBorder", "displayMainTankAndAssist", "displayPowerBar",
                "useClassColors", "displayPets", "sortBy", "healthText",
                "horizontalGroups", "displayNonBossDebuffs", "displayOnlyDispellableDebuffs",
                "frameWidth", "frameHeight", "autoActivate2Players", "autoActivate3Players",
                "autoActivate5Players", "autoActivate10Players", "autoActivate15Players",
                "autoActivate25Players", "autoActivate40Players", "locked",
            }
            
            for _, opt in ipairs(knownOptions) do
                local ok, value = pcall(function() return GetRaidProfileOption(profile, opt) end)
                if ok and value ~= nil then
                    print(string.format("    %s = %s", opt, tostring(value)))
                end
            end
            
            -- Also try dispel-specific ones
            print("")
            print("  |cffffcc00Dispel-related:|r")
            local dispelOptions = {
                "displayOnlyDispellableDebuffs",
                "dispelDebuffDisplayMode",
                "displayDispellableDebuffs",
                "dispelMode",
                "debuffDisplayMode",
            }
            for _, opt in ipairs(dispelOptions) do
                local ok, value = pcall(function() return GetRaidProfileOption(profile, opt) end)
                if ok and value ~= nil then
                    print(string.format("    %s = |cff00ff00%s|r", opt, tostring(value)))
                end
            end
        else
            print("  |cffff0000GetActiveRaidProfile or GetRaidProfileOption not available|r")
        end
        
    else
        DF:DebugDispel(msg ~= "" and msg or "player")
    end
end
