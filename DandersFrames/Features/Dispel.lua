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
    -- Generation counter: Blizzard securecopy's the colour map at BIND time, so a palette
    -- edit only lands once each carrier is re-bound. The counter is what marks carriers
    -- stale; InvalidateAuraLayout breaks DriveDispelOverlayFactory's fast-path latch so
    -- the drive re-runs and reaches the style pass.
    -- ★ 68914: this NO LONGER rebuilds the container. The generation is deliberately out
    -- of the overlay's plan signature — StyleDispelSlots re-binds each stale carrier IN
    -- PLACE (a tainted re-bind is legal now), so a colour tweak costs one re-bind instead
    -- of a full teardown+rebuild flicker. The debuff icon's ring re-binds off the same
    -- counter in its own style pass (Frames/AuraContainer.lua).
    DF.dispelCurveGen = (DF.dispelCurveGen or 0) + 1
    if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
end


-- ============================================================
-- FALLBACK COLORS (for test mode and out-of-combat)
-- Uses custom colors from db
-- ============================================================

local function GetTestDispelColor(dispelType)
    -- The overlay ALWAYS uses the shared account palette (DF.db.dispelColors, edited on
    -- the Colors page, Enrage folding into Bleed). Its defaults ARE the game palette, so
    -- an untouched palette matches the game exactly — there's no game-vs-custom mode.
    -- Body promoted to DF:ResolveDispelColor (Frames/Border.lua) so Core's lightweight
    -- repaint resolves identically instead of carrying its own drifted copy.
    return DF:ResolveDispelColor(dispelType)
end

-- "Keep OUR asset, just recolour it by dispel type" — the style every DF overlay carrier
-- binds with (our gradient / ring / strip art, tinted; never Blizzard's border atlas).
-- Resolution (incl. the 68914 enum rename + renumber) is SHARED with the debuff-icon ring:
-- DF:ResolveDispelTextureStyle, Frames/Border.lua. Never resolve the enum here.
local function DispelBorderStyle()
    return DF:ResolveDispelTextureStyle("Color")
end

-- Options for the type-badge carrier. Style is fixed to Icon -- the clean
-- RaidFrame-Icon-Debuff* symbol Blizzard picks from the aura. The other two the API
-- offers (BorderWithIcon / Border) were tried and REMOVED on 2026-08-03: they are
-- ui-debuff-border-* art meant to frame an aura BUTTON, so on a unit frame they draw
-- as a square box around the symbol. Wrong tool -- they exist to border an icon, not
-- a frame. A customDispelAssetMap (dispel name -> our own texture per type) is the
-- route if DF ever ships badge art of its own -- it takes a full set, one per type.
local function BadgeCarrierOptions()
    return {
        style = DF:ResolveDispelTextureStyle("Icon"),
        showWhenHarmful = true,
        showWhenHelpful = false,
    }
end

-- Dispel-colour map for the overlay: ALWAYS recolour the carriers from the shared
-- account palette via customDispelColorMap — keyed by dispel NAME, indexed private-side
-- against auraData.dispelName by Blizzard_CustomAuraButton.lua (secret-safe; no enum IDs).
-- The palette's defaults ARE the game colours, so this matches the game look until edited;
-- there is no game-vs-custom mode — the Colors page + its "Reset to game defaults" is the
-- single source of truth. Ignored on clients whose engine predates the field.
local function DispelBorderMapFor()
    if DF.GetDispelColorMap then return DF:GetDispelColorMap() end
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
        -- Anchor the proxy to the WIDGET (overlay), never to `frame` directly.
        -- overlay:SetAllPoints(host), and host is the frame (legacy path) or the
        -- aura button (12.1 slot path — itself SetAllPoints(frame)), so the rect is
        -- byte-identical to the padded frame either way. The difference that matters
        -- is the anchor CHAIN: on the slot path it now terminates at the aura button.
        -- 68824's SetAuraBorder runs GetValidatedForbiddenObjectTable, which rejects
        -- any bound carrier whose anchor chain doesn't reach the button ("must inherit
        -- all forbidden layout aspects from owner"); the game-mode gradient/tint
        -- carriers pin onto this proxy, so it has to lead back to the button — not the
        -- unit frame, whose chain carries none of the button's forbidden aspects.
        gradientParent:SetPoint("TOPLEFT", overlay, "TOPLEFT", pad, -pad)
        gradientParent:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", -pad, pad)
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

        -- db-only (no frame.healthBar requirement): the tracking decision MUST match
        -- DispelSlotSecureInit, which binds the StatusBar fill vs a plain texture on
        -- this same condition at button-create time — before healthBar timing settles.
        -- The health hook feeds the bar from UnitHealth (not the healthBar widget), so
        -- no healthBar is needed for the clip; a mismatch here would orphan the carrier.
        if onCurrentHealth and frame then
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

-- ★★ THE ONE DEFINITION OF GRADIENT STRENGTH. Intensity is folded into ALPHA, not
-- into RGB, because the live slot path cannot touch RGB at all: Blizzard securecopy's
-- the colour map at bind time and owns the carrier's vertex colour from then on
-- (StyleGameMainSlot's own header says so). Alpha stays ours on both lanes, so it is
-- the only channel where preview and live can agree.
--
-- ☠ dispelGradientIntensity USED TO BE PREVIEW-ONLY. The test path multiplied RGB by
-- it in three places; StyleGameMainSlot and StyleGameEdgeSlot had no intensity term
-- whatsoever. Dragging the slider visibly brightened every preview frame and did
-- nothing in game — a setting that only existed in the mirror. ElementAppearance.lua
-- had already worked this out and folded it into alpha; this hoists that one line so
-- all four sites share it. (Audit, 2026-08-07.)
--
-- Clamped: alpha above 1 is meaningless and would silently cap on one lane only.
local function ResolveGradientAlpha(db)
    return math.min((db.dispelGradientAlpha or 0.5) * (db.dispelGradientIntensity or 1.0), 1.0)
end

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
    
    -- Shared account palette (its defaults = the game colours), matching the in-range
    -- overlay. Enrage folds into Bleed.
    local key = dispelType == "Enrage" and "Bleed" or dispelType
    local pal = (DF.db and type(DF.db.dispelColors) == "table" and DF.db.dispelColors)
        or (DF.GetGameDispelPalette and DF:GetGameDispelPalette()) or DF.DispelDefaultColors
    local c = pal[key]
    if not c or not c.r then return end

    local r, g, b = c.r, c.g, c.b
    -- Intensity rides ALPHA, matching the live slot path -- see ResolveGradientAlpha.
    local gradientAlpha = ResolveGradientAlpha(db)
    local blendMode = db.dispelGradientBlendMode or "ADD"
    local ri, gi, bi = r, g, b
    
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

-- (DISPEL NAME TEXT COLORING removed 2026-07-25. The pair of Apply/Revert helpers and
-- the dispelNameText setting are gone: the only caller was ShowOverlayWithRGB, which is
-- the LEGACY test-mode show path -- the 12.1 slot path styles via StyleOverlayRegions
-- alone and never tinted the name. So the toggle coloured the name in the preview and
-- did nothing on a live frame, which is worse than inert. Re-adding it needs an
-- occlusion-safe name tint on the slot overlay, not this.)

-- ============================================================
-- SHOW OVERLAY WITH RGB (for test mode)
-- ============================================================

-- Region styling ONLY (no Show/Hide of the widget itself, no name text, no
-- last-aura bookkeeping): everything an explicit-RGB overlay needs — layout,
-- borders, gradients, type icon, pulse anim state. `frame` is only consulted for
-- ApplyOverlayLayout's cache key and may be nil on a slot host.
-- ⚠ The header here used to claim "reused verbatim by the 12.1 slot path". It is
-- not: the slot path styles through StyleOneSlot -> StyleGame*Slot and never calls
-- this. Grep confirms one caller, ShowOverlayWithRGB, which is test-only.
local function StyleOverlayRegions(overlay, r, g, b, db, dispelType, oorAlphaMultiplier, frame)
    if not overlay then return end

    -- Store dispel type for lightweight color updates
    overlay.currentDispelType = dispelType
    
    -- Default OOR multiplier to 1.0 (no change)
    oorAlphaMultiplier = oorAlphaMultiplier or 1.0
    
    local borderAlpha = (db.dispelBorderAlpha or 0.8) * oorAlphaMultiplier
    -- Intensity rides ALPHA, matching the live slot path -- see ResolveGradientAlpha.
    local gradientAlpha = ResolveGradientAlpha(db) * oorAlphaMultiplier
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
            
            
            -- Show edge gradients with gradient textures + SetVertexColor
            if overlay.gradientTop then
                overlay.gradientTop:SetTexture(EDGE_GRADIENT_TEXTURES.TOP)
                overlay.gradientTop:SetVertexColor(r, g, b, gradientAlpha)
                overlay.gradientTop:SetBlendMode(blendMode)
                overlay.gradientTop:Show()
            end
            
            if overlay.gradientBottom then
                overlay.gradientBottom:SetTexture(EDGE_GRADIENT_TEXTURES.BOTTOM)
                overlay.gradientBottom:SetVertexColor(r, g, b, gradientAlpha)
                overlay.gradientBottom:SetBlendMode(blendMode)
                overlay.gradientBottom:Show()
            end
            
            if overlay.gradientLeft then
                overlay.gradientLeft:SetTexture(EDGE_GRADIENT_TEXTURES.LEFT)
                overlay.gradientLeft:SetVertexColor(r, g, b, gradientAlpha)
                overlay.gradientLeft:SetBlendMode(blendMode)
                overlay.gradientLeft:Show()
            end
            
            if overlay.gradientRight then
                overlay.gradientRight:SetTexture(EDGE_GRADIENT_TEXTURES.RIGHT)
                overlay.gradientRight:SetVertexColor(r, g, b, gradientAlpha)
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
            tex:SetVertexColor(r, g, b, gradientAlpha)
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

end

-- ============================================================
-- HIDE OVERLAY
-- ============================================================

local function HideOverlay(overlay)
    if not overlay then return end
    
    -- Stop the pulse through the SYMMETRIC stop, which covers all THREE groups
    -- (border + gradient + icon) and resets each host's alpha. Stopping only
    -- pulseAnim here left gradientPulse and iconPulse looping on a hidden overlay:
    -- SetLegacyOverlayPulse(on) only plays a group that is `not IsPlaying()`, so on
    -- the next show the border restarted at phase 0 while the survivors carried on
    -- at whatever phase they had reached -- permanently breaking the phase lock the
    -- three groups are built to keep, and leaking a running AnimationGroup per frame.
    SetLegacyOverlayPulse(overlay, false)

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
-- Me/all: "HARMFUL|RAID_PLAYER_DISPELLABLE" vs "HARMFUL" + candidateFilters
-- includeDispelTypes (the shared DF.DispelTypeMap). ☠ The old route here used a
-- ProcessAura policy + processedAuraType=Dispel and was described as "the native
-- all-dispellable classification" — it is NOT. That branch is gated on aura.isRaid
-- (= curable by YOU), so it was by-me wearing an all-dispellable label. See the
-- comment in dispelSlotPlan.
-- ============================================================

-- (Removed) DISPEL_ICON_TYPES and GAME_ICON_ATLAS. The badge no longer picks its own
-- art per type: it is one bound carrier and Blizzard supplies the atlas from the aura,
-- which is the same RaidFrame-Icon-Debuff* set this table listed by hand. Blizzard's
-- own copy lives in AuraUtil (dispelIconAtlas), so ours was a duplicate that could
-- drift. See BadgeCarrierOptions and the badge block in DispelSlotSecureInit.
local warnedTintBind = false
local warnedSlotStyle = false

-- Slot plan from settings.
local function dispelSlotPlan(db)
    local byMe = (db.dispelOverlayDispelType or 2) == 1

    -- ☠ "All Dispellable" must NOT depend on what the player can dispel.
    --
    -- It used to ask for ProcessAura's Dispel classification via
    -- candidateFilters.processedAuraType. That is player-relative BY DEFINITION:
    -- AuraUtil.ProcessAura only reaches its Dispel branch under
    -- `aura.isHarmful and aura.isRaid`, and isRaid is the RAID flag, which for a
    -- debuff means "curable by YOU". So All rendered identically to By Me --
    -- a Death Knight saw nothing at all on any spec, and an Evoker saw exactly
    -- its own spec's types (Preservation 5, Aug/Dev 4, no Magic). Reported on
    -- alpha 15; the dropdown had no observable effect.
    --
    -- Use the explicit dispel-type map instead -- the same one the debuff ROWS
    -- use for their own ALL mode (Features/Auras.lua). It names the types
    -- directly, so Blizzard never consults the player's spec.
    local dispelTypes = DF.DispelTypeMap
    if not byMe and type(dispelTypes) ~= "table" then
        -- Loud, not silent: an unfiltered HARMFUL slot would light the overlay
        -- on EVERY debuff, which reads as a styling bug rather than a missing
        -- map. By-me is the safe degrade. (The previous version of this guard
        -- degraded without a word, which is how the ProcessAura route could
        -- have failed the same way and never been noticed.)
        if DF.DebugError then
            DF:DebugError("DISPEL", "DF.DispelTypeMap missing - 'All Dispellable' degraded to 'Dispellable By Me'")
        end
        byMe = true
    end

    local baseFilter = byMe and "HARMFUL|RAID_PLAYER_DISPELLABLE" or "HARMFUL"
    local baseCF = (not byMe) and { includeDispelTypes = dispelTypes } or nil

    -- One overlay, the game's colours, engine-driven (the Custom Colors mode was
    -- removed 2026-07-11 — per-type slots with the pickers; the irreducible cost
    -- was one overlay PER type on multi-type units, judged not worth the
    -- confusion once game mode gained the border and edge glow).
    -- ★ ONE slot carries the whole any-dispellable overlay (68914). Every tinted piece
    -- — gradient/tint, the border ring, and the four EDGE strips — used to need its OWN
    -- slot, because the old bind API replaced the button's single tintable region and
    -- "one tintable region per slot" was the hard limit. Up to SIX same-filter slots
    -- existed purely to smuggle six textures onto one visual overlay, and they stayed in
    -- sync only because identical filters happen to fill with the same aura.
    -- AddDispelTypeTexture appends, so one button now carries them all: the sync is
    -- structural rather than incidental, and a frame declares one slot instead of six.
    -- `roles` says which carriers this slot builds (see DispelSlotSecureInit) and is
    -- serialized into the plan signature, so flipping any of them still rebuilds.
    local gradientOn = db.dispelShowGradient ~= false
    local gradientStyle = db.dispelGradientStyle or "FULL"
    local roles = {
        -- EDGE renders through the four strips; any other style renders one gradient
        -- carrier (health-tracking or plain — resolved at init). NOT gated on
        -- dispelShowGradient: the carrier is always built for non-EDGE styles and
        -- StyleGameMainSlot alphas it to 0 when the gradient is off, exactly as the
        -- pre-consolidation main slot did. Gating creation here would make "show
        -- gradient" structural and leave nothing to re-show without a rebuild.
        gradient = (gradientStyle ~= "EDGE") and gradientStyle or nil,
        border   = db.dispelShowBorder ~= false or nil,
        -- A single-region vignette was tried and rejected: TexCoord zoom shows a fading
        -- ramp's faint inner TAIL, so any Gradient Size below the baked band rendered
        -- near-invisible (live-caught; crop-scaling only works on SOLID bands like the
        -- border ring). Four separate strip textures, now on one button.
        edges    = (gradientOn and gradientStyle == "EDGE")
                   and { "TOP", "BOTTOM", "LEFT", "RIGHT" } or nil,
        -- The dispel-type badge rides the SAME slot as the rest of the overlay, so it
        -- always shows the type of the aura the overlay is showing. It used to be its
        -- own set of five per-type slots; see the note in DispelSlotSecureInit for why
        -- that could not be made to show only one.
        badge    = db.dispelShowIcon ~= false or nil,
    }
    local slots = {}
    slots[#slots + 1] = { key = "main", filter = baseFilter, candidateFilters = baseCF, roles = roles }
    -- (Removed) the five per-type icon slots. The 2026-07-10 rejection they existed to
    -- work around was of the DEFAULT bind style, BorderWithIcon -- a button border with
    -- a badge baked in. `Icon` gives the same clean RaidFrame-Icon-Debuff* atlas those
    -- slots drew by hand, on ONE carrier, with Blizzard choosing the type. See the
    -- badge block in DispelSlotSecureInit.
    return slots
end

-- Structural signature: me/all, border slot, icon slots — anything that changes
-- the SLOT SET (topology is add-only, so set changes are a rebuild).
-- Pure styling (alphas, geometry) hot-applies via the style pass instead.
local function dispelFactoryPlanAndSig(db)
    local slots = dispelSlotPlan(db)
    if not slots then return nil end
    -- Mode marker. Derived from the PLAN, not the setting, so the by-me degrade
    -- inside dispelSlotPlan is reflected here too. (Was "policy"/"nopolicy" back
    -- when All rode a container-level ProcessAura policy.)
    local parts = { (slots[1] and slots[1].candidateFilters) and "alltypes" or "byme" }
    for i = 1, #slots do
        parts[#parts + 1] = slots[i].key .. "=" .. slots[i].filter
        -- ROLES are structural: the carriers a slot builds are created + bound ONCE in
        -- the secure init, so toggling the ring / gradient / EDGE strips must rebuild.
        -- They used to be separate slot keys (and so rode the loop above); now that one
        -- slot carries them all they have to be serialized explicitly or the flip would
        -- silently no-op until the next unrelated rebuild.
        local r = slots[i].roles
        if r then
            parts[#parts + 1] = "r:g=" .. tostring(r.gradient)
                .. ",b=" .. tostring(r.border and true or false)
                .. ",e=" .. (r.edges and table.concat(r.edges, "/") or "none")
                .. ",bg=" .. tostring(r.badge and true or false)
        end
    end
    -- The bound carrier is created in the initializeFrame (DispelSlotSecureInit), so
    -- anything that changes WHICH carrier a slot binds or its texture must be in the
    -- signature — a change rebuilds the container and re-runs the init with the right
    -- carrier:
    --   gs = gradient style (plain texture file vs the strip textures),
    --   gh = health-tracking flag (StatusBar fill vs plain texture).
    -- ★ The palette generation is DELIBERATELY NOT here any more (68914). Blizzard
    -- securecopy's the colour map at bind time, so a Colours-page edit does need a
    -- re-bind — but a tainted re-bind is legal now (the access-constrained rule is gone;
    -- the current validator only rejects EXPLICITLY forbidden / protected /
    -- non-descendant objects, and /al accessbind proved it live), so StyleDispelSlots
    -- re-binds the existing carrier in place. Keeping "cm=" here would rebuild the whole
    -- container — a visible teardown flicker — for a colour tweak that now costs one
    -- re-bind. WHICH carrier is bound is unchanged by a palette edit, so the plan is
    -- genuinely identical and the rebuild bought nothing.
    parts[#parts + 1] = "gs=" .. tostring(db.dispelGradientStyle or "FULL")
    parts[#parts + 1] = "gh=" .. tostring(db.dispelGradientOnCurrentHealth ~= false)
    return table.concat(parts, ";"), slots
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

-- ============================================================
-- SECURE CARRIER INIT (runs INSIDE the container's initializeFrame)
-- ------------------------------------------------------------
-- SetAuraBorder validates the texture with GetValidatedForbiddenObjectTable
-- (Blizzard_CustomAuraButton.lua): a texture that is a child of the secret aura
-- button and was created in the TAINTED style pass is access-constrained and is
-- rejected at cab.lua:15 ("must not be an access-constrained object") — which is why
-- the old overlay (carriers built in Style*Slot) rendered white in game AND custom
-- modes. Blizzard invokes initializeFrame via securecallfunction, so a texture
-- created HERE is created in secure context and is NOT access-constrained. This is
-- the same pattern the debuff-row icon border, MSUF and oUF all use: create + bind
-- inside initializeFrame; only geometry/alpha happen later in the tainted style pass
-- (legal post-bind). WHICH carrier a slot binds (plain texture vs the tracking
-- StatusBar fill), its texture, and the colour map are all in the container SIGNATURE
-- (dispelFactoryPlanAndSig), so any change rebuilds and re-runs this with the right
-- carrier — no tainted re-bind is ever needed.
-- ★ 68914: SetAuraBorder is a DEPRECATED alias (Blizzard_CustomAuraButton.lua: "will be
-- removed after 12.1") that does ClearDispelTypeTextures() + AddDispelTypeTexture() —
-- i.e. it REPLACES the button's texture list, which is the whole reason a slot could only
-- ever carry one tintable region. Bind through the real API when present: AddDispelTypeTexture
-- APPENDS, so one button can carry several tinted carriers. Behaviour is identical for a
-- single carrier (the alias just clears an empty list first), so this is a drop-in swap.
-- Bind EVERY carrier this button owns, in one pass. Clears once, then appends each —
-- the ordering the appending API requires (a per-carrier clear would leave only the
-- last). This is what lets a single slot carry the gradient, the ring and the four EDGE
-- strips; the list is remembered so a palette edit can re-bind them all in place.
-- Pre-68914 fallback: the deprecated alias can only hold ONE region, so the first
-- carrier wins there (matching the old one-slot-per-carrier behaviour as closely as a
-- single slot can).
local function BindDispelCarriers(btn, carriers, db, key)
    if not (btn and carriers and carriers[1]) then return end
    btn._dfDispelCarriers = carriers
    -- _dfDispelCurveGen is stamped AFTER a SUCCESSFUL bind (below), not here. The only
    -- retry gate is StyleDispelSlots' `_dfDispelCurveGen ~= DF.dispelCurveGen` check,
    -- so stamping up front meant a failed bind consumed the very generation bump that
    -- was supposed to force the re-bind: the carrier was marked fresh and never
    -- retried, leaving the overlay on the previous palette (or untinted) until an
    -- unrelated structural change rebuilt the container. warnedTintBind is one-shot
    -- for the whole session, so every later failure was silent too.
    -- The TINT options, used by every carrier that wants Blizzard's dispel colour on
    -- our own art (gradient, edge strips, ring). A carrier may override them --
    -- AddDispelTypeTexture takes options PER TEXTURE, which is what lets the type
    -- badge ask for a different style on the same button (see BadgeCarrierOptions).
    local tintOpts = {
        style = DispelBorderStyle(),
        customDispelColorMap = DispelBorderMapFor(),
        showWhenHarmful = true,
        showWhenHelpful = false,
        showIcon = false,
    }
    local ok, err = pcall(function()
        if btn.AddDispelTypeTexture then
            if btn.ClearDispelTypeTextures then btn:ClearDispelTypeTextures() end
            for i = 1, #carriers do
                local c = carriers[i]
                btn:AddDispelTypeTexture(c.tex, c.opts or tintOpts)
            end
        else
            btn:SetAuraBorder(carriers[1].tex, carriers[1].opts or tintOpts)
        end
    end)
    DF._dispelBindErr = DF._dispelBindErr or {}
    DF._dispelBindErr[key or "?"] = ok and ("ok x" .. #carriers) or tostring(err)
    if ok then
        btn._dfDispelCurveGen = DF.dispelCurveGen
    elseif not warnedTintBind then
        warnedTintBind = true
        if DF.DebugWarn then DF:DebugWarn("DISPEL", "dispel bind %s failed: %s", tostring(key), tostring(err)) end
    end
end


-- Create the SetAuraBorder carrier(s) for one overlay slot and bind them, per the
-- slot's role (from its key / edgeSide). Each carrier is anchored to the button here
-- (SetAllPoints(btn)) so it inherits the button's forbidden aspects at bind time; the
-- tainted style pass re-positions it afterwards (validation already passed). Icon
-- slots bind nothing — their plain type-icon textures ride the slot's SetShown.
-- ★ 68914 re-verified: SECURE context is NO LONGER REQUIRED for the bind's legality —
-- the access-constrained rejection (old Blizzard_CustomAuraButton.lua:15) was replaced
-- by ValidateInboundScriptObject (forbidden/protected/descendant-of-owner only), and a
-- tainted create+bind passes (/al accessbind, live). This init STAYS in the secure
-- initializeFrame anyway because it is the only hook that fires AT SLOT CREATION —
-- Blizzard creates overlay buttons lazily, including MID-COMBAT when a unit's first
-- dispellable debuff lands, and the style pass can't touch live buttons in combat
-- (BUILD-ONCE-LEAVE-IT). Moving create+bind there would delay the overlay's debut to
-- regen — exactly the moment it exists for. Timing, not legality, is the reason.
local function DispelSlotSecureInit(btn, slotInfo, db, frame)
    -- Either bind API is enough (AddDispelTypeTexture is current; SetAuraBorder is the
    -- deprecated alias kept for pre-68914 clients) — see BindDispelCarriers.
    if not (btn and btn.CreateTexture and (btn.AddDispelTypeTexture or btn.SetAuraBorder)) then return end
    local key = slotInfo.key
    local roles = slotInfo.roles
    if not roles then return end   -- icon slots bind nothing (plain art on the slot's SetShown)
    local hbLvl = (frame.healthBar and frame.healthBar:GetFrameLevel())
        or (frame:GetFrameLevel() + 3)
    local w = EnsureSlotWidget(btn, frame)
    local carriers = {}

    -- GRADIENT / TINT. Health-tracking binds the widget StatusBar's FILL texture so the
    -- bar clips it to current health (UpdateDispelGradientHealth feeds the value);
    -- otherwise a plain texture. Anchored to the button so it inherits the button's
    -- layout aspects at bind time; StyleGameMainSlot re-pins onto the style rect.
    if roles.gradient then
        local style = roles.gradient
        local tracking = style == "FULL" and db.dispelGradientOnCurrentHealth ~= false
        if tracking then
            w.gradient:SetAllPoints(btn)
            w.gradient:SetStatusBarTexture(GRADIENT_TEXTURES.FULL)
            carriers[#carriers + 1] = { tex = w.gradient:GetStatusBarTexture() }
        else
            if not w.nativeGradient then
                w.nativeGradient = w:CreateTexture(nil, "ARTWORK", nil, 2)
            end
            w.nativeGradient:SetTexture(GRADIENT_TEXTURES[style] or GRADIENT_TEXTURES.FULL)
            w.nativeGradient:SetAllPoints(btn)
            carriers[#carriers + 1] = { tex = w.nativeGradient }
        end
        -- Name the gradient carrier explicitly. StyleGameMainSlot must dress THIS one;
        -- addressing it as "the bound carrier" only worked while a slot held exactly one,
        -- and would grab the ring on a button whose gradient role is absent (EDGE).
        btn._dfDispelGradientCarrier = carriers[#carriers].tex
    end

    -- EDGE strips: one carrier per side, keyed BY SIDE (they used to be one field each
    -- on four separate buttons; on a shared button they must not overwrite each other).
    if roles.edges then
        btn.dfDispelEdgeTex = btn.dfDispelEdgeTex or {}
        btn.dfDispelEdgeHolder = btn.dfDispelEdgeHolder or {}
        for _, edge in ipairs(roles.edges) do
            local holder = CreateFrame("Frame", nil, btn)
            holder:SetAllPoints(btn)
            holder:SetFrameLevel(hbLvl + 7)
            local tex = holder:CreateTexture(nil, "ARTWORK", nil, 2)
            tex:SetTexture(EDGE_GRADIENT_TEXTURES[edge])
            tex:SetAllPoints(btn)   -- anchored for the bind; StyleGameEdgeSlot positions the strip
            btn.dfDispelEdgeHolder[edge] = holder
            btn.dfDispelEdgeTex[edge] = tex
            carriers[#carriers + 1] = { tex = tex }
        end
    end

    -- BORDER ring (transparent centre). Above the strips, per the legacy layering.
    if roles.border then
        local holder = CreateFrame("Frame", nil, btn)
        holder:SetAllPoints(btn)
        holder:SetFrameLevel(hbLvl + 9)
        local ring = holder:CreateTexture(nil, "ARTWORK")
        ring:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\DF_SquareBorder")
        ring:SetAllPoints(btn)   -- anchored for the bind; StyleGameBorderSlot crops/insets
        btn.dfDispelRing = ring
        btn.dfDispelRingHolder = holder
        carriers[#carriers + 1] = { tex = ring }
    end

    -- TYPE BADGE. One carrier, bound with a style that asks Blizzard for the dispel
    -- ART and not just a colour, so it shows the type of the SAME aura the overlay is
    -- showing. They cannot disagree, because neither is our choice.
    --
    -- This replaces the old per-type slot set (one slot per dispel type, each with
    -- includeDispelTypes). Those could NOT be made mutually exclusive: an aura carries
    -- exactly ONE dispelName, so excluding Magic from the Curse slot removes nothing --
    -- unlike the debuff records, where one aura can hold several flags at once. And
    -- presence is Blizzard's (SetShown on the slot button), so we could never tell
    -- which slots were filled. A unit with two dispellable types lit two slots and drew
    -- both badges on the same corner. Laying them out was considered and rejected:
    -- without knowing which are shown, only fixed per-type cells are possible, which
    -- displaces the badge off the configured corner in the common single-type case.
    if roles.badge then
        local holder = CreateFrame("Frame", nil, btn)
        holder:SetAllPoints(btn)
        holder:SetFrameLevel(((frame.contentOverlay and frame.contentOverlay:GetFrameLevel())
            or (frame:GetFrameLevel() + 25)) + 1)
        local badge = holder:CreateTexture(nil, "OVERLAY")
        badge:SetAllPoints(btn)   -- anchored for the bind; StyleGameBadge sizes/places it
        btn.dfDispelBadge = badge
        btn.dfDispelBadgeHolder = holder
        carriers[#carriers + 1] = { tex = badge, opts = BadgeCarrierOptions() }
    end

    -- ONE bind pass for every carrier (clear-once-then-append; see BindDispelCarriers).
    BindDispelCarriers(btn, carriers, db, key)
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
    local w = EnsureSlotWidget(btn, frame)   -- created in DispelSlotSecureInit (secure)

    -- Shared geometry pass (borders/icons/gradient rects + gradientTracksHealth).
    ApplyOverlayLayout(w, db, frame)
    w.borderTop:Hide(); w.borderBottom:Hide(); w.borderLeft:Hide(); w.borderRight:Hide()
    if w.gradientTop then w.gradientTop:Hide() end
    if w.gradientBottom then w.gradientBottom:Hide() end
    if w.gradientLeft then w.gradientLeft:Hide() end
    if w.gradientRight then w.gradientRight:Hide() end
    for _, icon in pairs(w.icons) do icon:Hide() end

    local style = db.dispelGradientStyle or "FULL"
    local showGradient = db.dispelShowGradient ~= false

    -- Dress the carrier that DispelSlotSecureInit created + bound. This tainted pass
    -- ONLY does geometry/alpha/blend (legal post-bind); it must NEVER CreateTexture,
    -- SetAuraBorder, or SetStatusBarTexture (that recreates the bound fill) here —
    -- Blizzard owns the carrier's colour + Shown after the bind.
    if style == "EDGE" then
        -- EDGE renders through the four edge slots; keep the main widget's gradient
        -- regions hidden and fall through to darken/pulse. (No main carrier is bound.)
        w.gradient:Hide()
        if w.nativeGradient then w.nativeGradient:Hide() end
    else
        local carrier = btn._dfDispelGradientCarrier
        if carrier then
            if w.gradientTracksHealth then
                -- Tracking carrier = the StatusBar fill (texture set once in onInit);
                -- show the bar, UpdateDispelGradientHealth clips it via SetValue.
                w.gradient:Show()
                if w.nativeGradient then w.nativeGradient:Hide() end
            else
                w.gradient:Hide()
                carrier:ClearAllPoints()
                carrier:SetTexture(GRADIENT_TEXTURES[style] or GRADIENT_TEXTURES.FULL)
                carrier:SetTexCoord(0, 1, 0, 1)
                -- The hidden StatusBar holds the style's rect (strips / static FULL).
                carrier:SetAllPoints(w.gradient)
            end
            carrier:SetBlendMode(db.dispelGradientBlendMode or "ADD")
            -- Intensity rides alpha here; RGB is Blizzard's after the bind.
            carrier:SetAlpha(showGradient and ResolveGradientAlpha(db) or 0)
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
local function StyleGameBadge(btn, frame, db)
    -- Badge is created + bound in DispelSlotSecureInit (secure); this tainted pass
    -- only sizes, places and alphas it. It must NEVER SetAtlas/SetTexture here --
    -- Blizzard owns the art after the bind, which is the whole point: the badge shows
    -- the type of the same aura the overlay is showing, and we never read that type.
    local badge = btn.dfDispelBadge
    if not badge then return end
    btn.dfDispelBadgeHolder:SetFrameLevel(((frame.contentOverlay and frame.contentOverlay:GetFrameLevel())
        or (frame:GetFrameLevel() + 25)) + 1)
    local size = db.dispelIconSize or 20
    if db.pixelPerfect then size = DF:PixelPerfect(size) end
    local pos = db.dispelIconPosition or "CENTER"
    badge:ClearAllPoints()
    badge:SetPoint(pos, btn.dfDispelBadgeHolder, pos, db.dispelIconOffsetX or 0, db.dispelIconOffsetY or 0)
    badge:SetSize(size, size)
    badge:SetAlpha(db.dispelIconAlpha or 1)
    ApplySlotPulse(btn.dfDispelBadgeHolder, db.dispelAnimate)
end

-- GAME-COLOUR mode, border slot: ONE square-ring texture (solid band, transparent
-- centre — Media/DF_SquareBorder) bound as this slot's carrier; Blizzard tints and
-- shows it with the same aura the main slot carries. Nine-slice pins the band at a
-- uniform, configurable thickness on any frame shape (stretched ring art would
-- render thicker sides than top on wide frames); the solid band makes the slice
-- semantics-proof — any margin ≤ the 32px art band samples solid white.
local function StyleGameBorderSlot(btn, frame, db)
    -- Ring is created + bound in DispelSlotSecureInit (secure); this tainted pass only
    -- crops/positions it. If onInit hasn't populated it yet, skip — it always runs first.
    local ring = btn.dfDispelRing
    if not ring then return end
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
    ApplySlotPulse(btn.dfDispelRingHolder, db.dispelAnimate)
end

-- GAME mode, EDGE strip: one gradient strip texture per edge — all four now live on the
-- SAME slot button (keyed by side), positioned from settings on the padded frame rect
-- (immune to the reduced-max health-bar clip). Geometry mirrors ApplyOverlayLayout's
-- EDGE branch: strip depth = padded frame dimension × Gradient Size.
local function StyleGameEdgeSlot(btn, frame, db, edge)
    -- Strip tex is created + bound in DispelSlotSecureInit (secure); this pass only
    -- positions it. If onInit hasn't populated it yet, skip — it always runs first.
    local tex = btn.dfDispelEdgeTex and btn.dfDispelEdgeTex[edge]
    if not tex then return end
    tex:SetTexture(EDGE_GRADIENT_TEXTURES[edge])
    local pad = db.framePadding or 0
    local gradientSize = db.dispelGradientSize or 0.3
    local innerW = math.max((frame:GetWidth() or 80) - 2 * pad, 1)
    local innerH = math.max((frame:GetHeight() or 40) - 2 * pad, 1)
    local dH = innerH * gradientSize   -- strip depth, horizontal strips
    local dW = innerW * gradientSize   -- strip depth, vertical strips
    -- Rect from TWO DIAGONAL POINTS only (the ring's proven pattern on these
    -- holders) — no SetHeight/SetWidth on regions inside the button subtree.
    -- Anchor to `btn`, NOT `frame`: the button is SetAllPoints(frame) so the rect is
    -- identical, but the anchor chain must terminate at the aura button for 68824's
    -- SetAuraBorder validation ("must inherit all forbidden layout aspects from
    -- owner") — anchoring to the unit frame leaves this bound carrier orphaned (white).
    tex:ClearAllPoints()
    if edge == "TOP" then
        tex:SetPoint("TOPLEFT", btn, "TOPLEFT", pad, -pad)
        tex:SetPoint("BOTTOMRIGHT", btn, "TOPRIGHT", -pad, -(pad + dH))
    elseif edge == "BOTTOM" then
        tex:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", pad, pad + dH)
        tex:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -pad, pad)
    elseif edge == "LEFT" then
        tex:SetPoint("TOPLEFT", btn, "TOPLEFT", pad, -pad)
        tex:SetPoint("BOTTOMRIGHT", btn, "BOTTOMLEFT", pad + dW, pad)
    else -- RIGHT
        tex:SetPoint("TOPLEFT", btn, "TOPRIGHT", -(pad + dW), -pad)
        tex:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -pad, pad)
    end
    tex:SetBlendMode(db.dispelGradientBlendMode or "ADD")
    tex:SetAlpha(ResolveGradientAlpha(db))
    ApplySlotPulse(btn.dfDispelEdgeHolder and btn.dfDispelEdgeHolder[edge], db.dispelAnimate)
end

-- All the styling for ONE slot button. Split out of StyleDispelSlots so the whole
-- per-button pass can be pcall'd as a unit -- see the caller for why.
local function StyleOneSlot(btn, frame, db, info)
    -- IN-PLACE PALETTE RE-BIND (68914): Blizzard securecopy's the colour map at
    -- bind time, so a Colours-page edit needs the carrier RE-BOUND. That used to
    -- force a full container rebuild (the palette generation rode the plan
    -- signature) — a visible teardown/rebuild flicker on every colour tweak.
    -- AddDispelTypeTexture accepts a re-bind from this tainted pass now (the
    -- access-constrained rule is gone; /al accessbind + the 68914 validator,
    -- which only rejects EXPLICITLY forbidden / protected / non-descendant
    -- objects — our carrier is a descendant that merely INHERITS aspects), so
    -- re-bind the carrier we already have and skip the rebuild entirely.
    -- Icon slots bind nothing, so they never go stale. Re-binds the WHOLE
    -- carrier list for this button in one clear-then-append pass.
    if btn._dfDispelCarriers and btn._dfDispelCurveGen ~= DF.dispelCurveGen then
        BindDispelCarriers(btn, btn._dfDispelCarriers, db, info.key)
    end
    do
        -- ONE button, every role it owns (see dispelSlotPlan's `roles`). There is only
        -- the main slot now -- the per-type icon slots are gone, the badge is a role on
        -- this button like the ring and the strips.
        -- StyleGameMainSlot runs UNCONDITIONALLY: besides dressing the gradient
        -- carrier it owns the shared geometry pass (ApplyOverlayLayout), hides
        -- the legacy regions, and applies the darken/pulse — all of which the
        -- pre-consolidation main slot did in every style, EDGE included.
        StyleGameMainSlot(btn, frame, db)
        local r = info.roles
        if r and r.edges then
            for _, edge in ipairs(r.edges) do StyleGameEdgeSlot(btn, frame, db, edge) end
        end
        if r and r.border then StyleGameBorderSlot(btn, frame, db) end
        if r and r.badge then StyleGameBadge(btn, frame, db) end
    end
end

-- STALE SLOT ART (bug #1004's shape, second consumer). Every widget hung off a slot
-- button -- the overlay frame, its border StatusBars, the bound carriers -- is a
-- descendant of the SECRET aura button, and the client can turn that subtree forbidden
-- underneath us when it reclaims or re-initialises the slot. Nothing ever cleared
-- btn.dfDispelWidget, so the stash outlived the art: ApplyOverlayLayout's first touch
-- (borderLeft:ClearAllPoints) then threw on every state-changing refresh, which aborted
-- the whole style pass for that button and left the overlay dead. Reported 32x after a
-- dungeon and 98x on one Show Overlay For dropdown -- the same frames, once per refresh,
-- so it is persistent rather than transient. Frames\Core.lua's health mirror carries the
-- identical guard for the identical reason; this is that guard for the dispel art.
--
-- Read-only, and it touches the object that actually throws (borderLeft) rather than
-- IsForbidden() -- inside the secret container IsForbidden can hand back a SECRET on a
-- perfectly healthy widget, and the codebase's guard idiom reads a secret as "skip",
-- which would silently kill the overlay for everyone. Declared once, not inlined as a
-- closure, so the pcall below stays allocation-free on a per-slot-per-pass path.
local function ProbeSlotArt(w)
    return w:GetFrameLevel() and w.borderLeft:GetFrameLevel()
end

-- Drop EVERY stash hanging off the button. The tainted painters (icon, and the widget
-- itself via EnsureSlotWidget) rebuild lazily from nil; the bound carriers do not, which
-- is why the caller re-runs DispelSlotSecureInit behind this.
local function ResetSlotArt(btn)
    btn.dfDispelWidget = nil
    btn._dfDispelCarriers = nil
    btn._dfDispelCurveGen = nil
    btn._dfDispelGradientCarrier = nil
    btn.dfDispelEdgeTex = nil
    btn.dfDispelEdgeHolder = nil
    btn.dfDispelRing = nil
    btn.dfDispelRingHolder = nil
    btn.dfDispelBadge = nil
    btn.dfDispelBadgeHolder = nil
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
        -- Recover a button whose art went forbidden before anything tries to paint it.
        -- ONE retry per button: DispelSlotSecureInit rebuilds and re-binds from here
        -- (tainted create+bind is legal on 68914 -- see the re-bind note below), but if
        -- the fresh art comes back untouchable too, retrying every pass would trade an
        -- error spam for a rebuild spam. The latch clears the moment a probe passes, so
        -- a later reclaim is still recoverable.
        local artOK = true
        if btn and btn.dfDispelWidget and not pcall(ProbeSlotArt, btn.dfDispelWidget) then
            if btn._dfDispelArtStale then
                artOK = false
                if not frame.dfDispelArtForbiddenLogged then
                    frame.dfDispelArtForbiddenLogged = true
                    DF:DebugWarn("AURACONTAINER",
                        "StyleDispelSlots: slot art still forbidden after a rebuild, "
                        .. "skipping the dispel overlay on %s", tostring(frame.unit))
                end
            else
                btn._dfDispelArtStale = true
                ResetSlotArt(btn)
                -- pcall'd for the SAME reason as the style pass below (bug #1011):
                -- this reaches into the slot widgets to create and bind carriers, so
                -- it shares their exposure. Unprotected, a throw here escapes
                -- StyleDispelSlots entirely -- past the per-button pcall, which only
                -- wraps StyleOneSlot -- and out through DriveDispelOverlayFactory into
                -- FullFrameRefresh, abandoning every element after the dispel overlay.
                -- That is precisely the failure this recovery path exists to end, and
                -- it is the likeliest place to throw: the art was just found forbidden.
                if info.roles then
                    local okInit, errInit = pcall(DispelSlotSecureInit, btn, info, db, frame)
                    if not okInit and not warnedSlotStyle then
                        warnedSlotStyle = true
                        if DF.DebugWarn then
                            DF:DebugWarn("DISPEL", "slot re-init %s failed: %s",
                                tostring(info.key), tostring(errInit))
                        end
                    end
                end
            end
        elseif btn then
            btn._dfDispelArtStale = nil
        end
        if btn and artOK then
            -- `styled` means "a button existed and we ran the pass", NOT "the pass
            -- succeeded". It has to stay true even when the pass throws, or the
            -- caller never latches the version/generation and re-enters this same
            -- failing pass on EVERY drive -- i.e. per UNIT_AURA, per frame, forever
            -- (bug #1011: 68 identical errors from one key). A real change bumps
            -- ver/gen and retries; a deterministic failure now costs one error, not
            -- a permanent loop.
            styled = true
            -- pcall'd per BUTTON so one bad slot can't skip the others, and -- more
            -- importantly -- can't propagate out through DriveDispelOverlayFactory
            -- into FullFrameRefresh, which would abandon every element that runs
            -- after the dispel overlay (highlights, status icons, resource bar,
            -- absorbs, heal prediction). Allocation is fine here: this path is gated
            -- on a version/generation change, so it runs on rebuilds, not per aura.
            local ok, err = pcall(StyleOneSlot, btn, frame, db, info)
            if not ok then
                btn._dfDispelStyleErr = tostring(err)
                if not warnedSlotStyle then
                    warnedSlotStyle = true
                    if DF.DebugWarn then
                        DF:DebugWarn("DISPEL", "slot style %s failed: %s",
                            tostring(info.key), tostring(err))
                    end
                end
            else
                btn._dfDispelStyleErr = nil
            end
        end
    end
    -- Seed any health-tracking gradient bars now (both colour modes): the health
    -- hook only fires on health CHANGES, and the layout pass just neutralized the
    -- fill to full — without a seed a tracking bar renders full until the first
    -- health tick. Early-outs when nothing tracks.
    -- pcall'd for the same reason as the per-button pass: this reaches into the
    -- slot widgets' StatusBars, so it shares their exposure and must not be able
    -- to abort the caller.
    if styled and DF.UpdateDispelGradientHealth then
        pcall(DF.UpdateDispelGradientHealth, DF, frame)
    end
    return styled
end

-- Render gate (excludes test mode — the test paint previews on the shared art
-- with Blizzard palette colours; see UpdateDispelOverlay's test branch).
function DF:UseFactoryForDispelOverlay(frame, db)
    return DF.AuraContainer and DF.AuraContainer.IsSupported()
        and not (DF.testMode or DF.raidTestMode)
        -- Memory test: driveFactoryRowsNow (Features/Auras.lua) calls
        -- DriveDispelOverlayFactory DIRECTLY, bypassing UpdateDispelOverlay's own
        -- enableDispel guard — so without this term a GUI change would re-show
        -- the overlay with the box unticked.
        and not DF:MemTestDisabled("enableDispel")
end


-- Drive the factory overlay for one frame. Mirrors the row drives: lazy create,
-- recreate on a structural signature change, keep the container on the frame's unit,
-- re-style on a layout-version bump (out of combat). Cheap when nothing changed —
-- this runs per UNIT_AURA via UpdateDispelOverlay.
function DF:DriveDispelOverlayFactory(frame, db)
    -- No double render: the legacy overlay stays hidden while the factory owns.
    if frame.dfDispelOverlay and frame.dfDispelOverlay:IsShown() then
        HideOverlay(frame.dfDispelOverlay)
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

    -- EMPTY HEADER SLOT. A raid header keeps its whole child set alive and hands
    -- units out as the roster fills, so outside a full group most children carry
    -- no unit at all. They are hidden, they can never match a dispellable aura,
    -- and AuraContainer:Create defaults a nil unit to "player" -- so building
    -- here stood up a six-slot container per EMPTY slot and pointed each one at
    -- the wrong unit. UpdateAllDispelOverlays walks IterateAllFrames unfiltered
    -- (the aura rows come through FullFrameRefresh, which already returns on a
    -- unitless frame -- that is why they never paid this).
    -- Measured, login while solo: 41 containers built, 40 of them empty raid
    -- slots -- 10.8 MB of the 14.1 MB the addon spent standing containers up.
    -- Existing handles are deliberately LEFT ALONE: the roster churns, and
    -- SetUnit re-targets a live one for free when a unit lands in this slot.
    if not frame.unit then return end

    -- Fast path (this runs per UNIT_AURA in combat): already built AND styled at
    -- the current layout version + build generation -> only unit upkeep remains.
    -- Skips the per-call plan/signature allocation entirely; any settings change
    -- goes through InvalidateAuraLayout, which breaks the version latch.
    local ver = DF.auraLayoutVersion or 0
    if h and frame.dfDispelFactoryVersion == ver and frame.dfDispelStyledGen == (h._gen or 0) then
        if h:GetUnit() ~= frame.unit then h:SetUnit(frame.unit) end
        return
    end

    local sig, slots = dispelFactoryPlanAndSig(db)
    if not sig then return end

    if not h or frame.dispelFactorySig ~= sig then
        if h then h:Destroy() end
        local filterRecords = {}
        for i = 1, #slots do
            local si = slots[i]   -- fresh per-iteration capture for the onInit closure
            filterRecords[i] = { filter = si.filter, key = si.key,
                                 candidateFilters = si.candidateFilters,
                                 -- SECURE carrier create + SetAuraBorder bind, run inside
                                 -- the container's initializeFrame (the only context where
                                 -- a texture child of the secret button isn't access-
                                 -- constrained). Geometry/alpha stay in StyleGame*Slot.
                                 onInit = function(btn) DispelSlotSecureInit(btn, si, db, frame) end }
        end
        h = DF.AuraContainer:Create(frame, {
            unit = frame.unit,
            mode = "overlay",
            filter = filterRecords,
            -- No processingPolicy: the overlay no longer uses ProcessAura's Dispel
            -- classification for its "All" mode (it was player-relative -- see
            -- dispelSlotPlan). Filtering is filterString + includeDispelTypes now.
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

    -- MEMORY TEST: Skip if disabled
    if DF:MemTestDisabled("enableDispel") then
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
            -- Preview what the container path renders LIVE: the shared account palette
            -- (DF.db.dispelColors) on the shared art — the legacy widget's border/EDGE
            -- regions are geometry-matched stand-ins for the ring slot / vignette
            -- carrier. GetTestDispelColor resolves that palette and falls back to the
            -- GAME palette per type, which is also what an untouched palette holds.
            -- ⚠ This used to resolve the palette and then OVERWRITE it with
            -- AuraUtil.GetAuraBorderColor, so test mode always previewed Blizzard's
            -- colours while live rendered the user's — a leftover from the era when the
            -- overlay really did render the game palette and a game-vs-custom split
            -- existed. That split is gone (the overlay always follows the Colours page),
            -- so the override made the preview lie about live. Never re-add it.
            local r, g, b = GetTestDispelColor(testData.dispelType, db)

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
    local o = DF:Out("Dispel", "unit " .. unit)
    
    local db = DF:GetDB()
    o:Section("Settings")
    o:Field("dispelOverlayEnabled", tostring(db and db.dispelOverlayEnabled))
    o:Field("dispelOverlayDispelType", tostring(db and db.dispelOverlayDispelType))
    
    -- Get debuffs sorted by expiration
    local sortRule = Enum.UnitAuraSortRule and Enum.UnitAuraSortRule.Expiration or 3
    local auras = C_UnitAuras.GetUnitAuras(unit, "HARMFUL", nil, sortRule)
    
    if not auras or #auras == 0 then
        o:Line("No debuffs on this unit.", "NEUTRAL")
        o:Siblings("dispel")
        return
    end
    
    -- Show debuffs with dispelName
    o:Section("Debuffs", #auras .. " sorted by expiration")
    local lastDispellable = nil
    for i, aura in ipairs(auras) do
        if i > 10 then break end
        local auraName = aura.name or "?"
        local dispelName = aura.dispelName
        
        if dispelName ~= nil then
            o:Item("[" .. i .. "] " .. auraName, dispelName, "GOOD")
            lastDispellable = aura
        else
            -- Not dispellable is a FACT about the debuff, not a fault in DF.
            o:Item("[" .. i .. "] " .. auraName, "not dispellable", "NEUTRAL")
        end
    end
    
    if lastDispellable then
        o:Field("Last dispellable",
            (lastDispellable.name or "?") .. " (" .. lastDispellable.dispelName .. ")", "GOOD")
    else
        -- Nothing dispellable is a normal state, not an error.
        o:Line("No dispellable debuffs", "NEUTRAL")
    end

    o:Section("Frame / overlay status")
    local frame = FindFrameByUnit(unit)
    if frame then
        o:Field("Frame found", "yes", "GOOD")
        o:Field("Frame shown", tostring(frame:IsShown()))
        if frame.dfDispelOverlay then
            local overlay = frame.dfDispelOverlay
            o:Field("Overlay exists", "yes", "GOOD")
            o:Field("Overlay shown", overlay:IsShown() and "yes" or "no",
                overlay:IsShown() and "GOOD" or "NEUTRAL")
            o:Field("Overlay alpha", string.format("%.2f", overlay:GetAlpha()))
            if overlay.borderTop then
                o:Field("BorderTop shown", tostring(overlay.borderTop:IsShown()))
            end
            if overlay.icons then
                local iconsShown = {}
                for name, icon in pairs(overlay.icons) do
                    if icon:IsShown() then
                        table.insert(iconsShown, name)
                    end
                end
                o:Field("Icons shown", #iconsShown > 0 and table.concat(iconsShown, ", ") or "none",
                #iconsShown > 0 and "GOOD" or "NEUTRAL")
            end
        else
            o:Field("Overlay exists", "no", "NEUTRAL")
        end
    else
        -- No frame for the unit means nothing can render: that is a real fault.
        o:Field("Frame found", "no", "BAD")
    end
    
    -- Force update
    o:Section("Forced update")
    if frame then
        DF:UpdateDispelOverlay(frame)
        C_Timer.After(0.1, function()
            if frame.dfDispelOverlay then
                o:Field("overlay shown after update", tostring(frame.dfDispelOverlay:IsShown()))
            end
        end)
    end
    o:Siblings("dispel")
end

-- Dispel diagnostics. One command, one job: report what OUR overlay sees and
-- did for a unit.
-- (Removed) the ten Blizzard-setting probes that used to live here --
-- dump/dump2/dump3/dump4, cvar/cvar1/cvar0, indicator, setindicator and
-- profile. They were archaeology from the hunt for where the game stores its
-- dispel indicator setting. DF has not read that setting since the v4.3.4
-- dispel-source rework, and the last two paths that stamped it were deleted in
-- the v5 cleanup (see the notes in Core.lua and Features/Auras.lua), so they
-- answered a question that no longer touches anything DF renders. Nothing
-- outside this handler read raidFramesDispelIndicatorType, the dispellable-
-- debuff CVars, optionTable or GetRaidProfileOption. Two of them (cvar1/cvar0)
-- also WROTE a live game CVar, which a diagnostic has no business doing.
-- (Removed) "test" went with them: it read dispelName off the player's first
-- aura, which DF:DebugDispel prints for every debuff on any unit.
DF:RegisterDebugSlash("DFDISPEL", "Dispel overlay state: [unit], or ids | render", false, "/dfdispel")
SlashCmdList["DFDISPEL"] = function(msg)
    local arg = msg and msg:match("^%s*(%S+)") or nil
    if arg == "ids" then
        SlashCmdList["DANDERSFRAMES"]("debug dispelids")
    elseif arg == "render" then
        SlashCmdList["DANDERSFRAMES"]("debug dispeldbg")
    elseif arg == nil or UnitExists(arg) then
        DF:DebugDispel(arg or "player")
    else
        local o = DF:Out("Dispel", "unknown argument '" .. arg .. "'")
        o:Item("[unit]", "overlay state for a unit (default: player)")
        o:Item("ids", "Enum.AuraDispelType field dump")
        o:Item("render", "overlay render + frame-level state")
        o:Line("Ongoing dispel tracing is in the debug console - enable the DISPEL category.", "NEUTRAL")
        o:Siblings("dispel")
    end
end
