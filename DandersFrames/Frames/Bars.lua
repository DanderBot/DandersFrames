local addonName, DF = ...

-- ============================================================
-- FRAMES BARS MODULE
-- Contains resource bar and absorb bar logic
-- ============================================================

-- Local caching of frequently used globals for performance
local InCombatLockdown = InCombatLockdown
local UnitIsAFK = UnitIsAFK
local UnitGroupRolesAssigned = UnitGroupRolesAssigned
local UnitIsGroupLeader = UnitIsGroupLeader
local UnitIsGroupAssistant = UnitIsGroupAssistant
local GetRaidTargetIndex = GetRaidTargetIndex
local GetReadyCheckStatus = GetReadyCheckStatus
local SetRaidTargetIconTexture = SetRaidTargetIconTexture
local UnitClass = UnitClass
local issecretvalue = issecretvalue or function() return false end
local pcall = pcall

local ResolveBarTextureForFill = function(...) return DF:ResolveBarTextureForFill(...) end

-- ============================================================
-- RESOURCE BAR LOGIC
-- ============================================================

-- Centralized role and class filter check for resource bar visibility
-- Returns true if the resource bar should be shown for this unit
-- Unit must pass BOTH role filter AND class filter
-- `roleOverride` supplies the role as DATA instead of resolving it from a real unit,
-- which is how test mode drives this. The preview must run the LIVE gate: it used to
-- carry its own copy of the role logic and that copy had drifted, losing BOTH solo arms
-- below. resourceBarShowInSoloMode defaults to true and test mode is almost always driven
-- solo, so live showed the bar on every frame while the preview showed it only on the
-- role-filtered subset -- a setting you could not judge from the preview at all.
function DF:ShouldShowResourceBar(unit, db, roleOverride, classOverride)
    if not db.resourceBarEnabled then return false end

    -- Role filter
    local roleAllowed = false
    local hasAnyRoleFilter = db.resourceBarShowHealer or db.resourceBarShowTank or db.resourceBarShowDPS

    if hasAnyRoleFilter then
        -- ☠ DF:GetUnitRole, not UnitGroupRolesAssigned. The raw call returns
        -- "NONE" for the player whenever the group has not assigned a role --
        -- solo, open world, and inside a delve until a spec change forces one --
        -- and the NONE arm below reads as DAMAGER. So a solo Holy Paladin was
        -- gated by the DPS toggle: the Healers checkbox did nothing, and ticking
        -- DPS showed the bar for every spec. GetUnitRole falls the PLAYER back to
        -- the spec role; other units have no public spec API and still arrive
        -- NONE, which is why the arm stays.
        local role = roleOverride or DF:GetUnitRole(unit)
        local inSoloMode = not IsInGroup() and not IsInRaid()

        if inSoloMode and db.resourceBarShowInSoloMode then
            roleAllowed = true
        elseif role == "HEALER" then
            roleAllowed = db.resourceBarShowHealer == true
        elseif role == "TANK" then
            roleAllowed = db.resourceBarShowTank == true
        elseif role == "DAMAGER" then
            roleAllowed = db.resourceBarShowDPS == true
        elseif not role or role == "NONE" then
            -- Still unresolved: another unit with no assigned role. Treat as DPS.
            roleAllowed = db.resourceBarShowDPS == true
        end
    else
        local inSoloMode = not IsInGroup() and not IsInRaid()
        roleAllowed = inSoloMode and db.resourceBarShowInSoloMode == true
    end

    if not roleAllowed then return false end

    -- Class filter (unit must also pass)
    local classFilter = db.resourceBarClassFilter
    if classFilter then
        -- classOverride is the DATA half of the same arrangement as roleOverride: with a
        -- nil unit UnitClass returns nil and this filter would silently never apply, so a
        -- preview would have to re-implement it -- which is how these copies start.
        local classToken = classOverride
        -- ⚠ `and unit`: the preview hands unit=nil with class as DATA — and a
        -- boss-NPC preview has no class either, so both are nil and this fell
        -- through to UnitClass(nil), which 12.1 rejects with a Usage error (the
        -- old "returns nil" behaviour this comment block relied on is gone).
        -- No token = the filter silently doesn't apply, per the contract above.
        if not classToken and unit then
            local _
            _, classToken = UnitClass(unit)
            -- Secret class (boss units): may not key the filter table. Treat as
            -- "no token" — the filter silently doesn't apply, same as a unit
            -- with no class. This site was masked by the GetUnitRole throw
            -- above until that was guarded; it is the very next error in line.
            if issecretvalue(classToken) then classToken = nil end
        end
        if classToken and classFilter[classToken] == false then
            return false
        end
    end

    return true
end

-- Shared resource-bar GEOMETRY + appearance: texture, orientation/fill, size
-- (incl. the border inset), anchor, frame level, background, and border. Both the
-- live layout (DF:ApplyResourceBarLayout) and the test render (DF:UpdateTestPowerBar)
-- call this so the two can never drift. The caller does the enabled/role checks and
-- sets the bar VALUE + fill COLOUR (live UnitPower vs test mock) — the only per-caller
-- part. Assumes the bar should be shown.
function DF:LayoutResourceBar(frame, db)
    local bar = frame and frame.dfPowerBar
    if not bar then return end

    bar:Show()
    bar:ClearAllPoints()

    -- Fill texture (configurable; defaults to the DF house texture)
    DF:SafeSetStatusBarTexture(bar, db.resourceBarTexture or "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist")

    -- Orientation & Fill Direction
    local resourceOrient = db.resourceBarOrientation or "HORIZONTAL"
    bar:SetOrientation(resourceOrient)
    bar:SetReverseFill(db.resourceBarReverseFill)
    -- Suppresses rotation for a tiled texture and swaps in its rotated companion.
    -- Safe to call unconditionally — a stretched texture just rotates as before.
    DF:ApplyBarFillOrientation(bar, resourceOrient == "VERTICAL")

    local isVertical = (db.resourceBarOrientation == "VERTICAL")
    local length = db.resourceBarWidth or 50
    local thickness = db.resourceBarHeight or 4
    local ppLength = db.pixelPerfect and DF:PixelPerfect(length) or length
    local ppThickness = db.pixelPerfect and DF:PixelPerfect(thickness) or thickness

    -- Compute health bar dimensions from settings instead of GetWidth/GetHeight
    -- which can return stale values before WoW's layout engine processes anchor changes.
    -- Prefer a pinned set's resolved size (Match baseline + Width/Height override) so a
    -- "Match Frame Width" resource bar tracks the pinned frame, not the shared per-mode
    -- db width. Main frames have no stamp and use the mode db.
    local padding = db.framePadding or 0
    local frameWidth = frame.dfPinnedWidth or db.frameWidth or 120
    local frameHeight = frame.dfPinnedHeight or db.frameHeight or 50
    if db.pixelPerfect and DF.PixelPerfect then
        frameWidth = DF:PixelPerfect(frameWidth)
        frameHeight = DF:PixelPerfect(frameHeight)
        padding = DF:PixelPerfect(padding)
    end
    local healthBarWidth = frameWidth - (2 * padding)
    local healthBarHeight = frameHeight - (2 * padding)

    -- Account for frame border inset (matches other bar calculations)
    local borderInset = 0
    if db.frameShowBorder ~= false then
        borderInset = db.frameBorderSize or 1
    end
    -- When Pixel Perfect is on, borderInset must be snapped to a whole screen pixel
    -- before being subtracted from healthBarWidth — otherwise barW is fractional and
    -- WoW rounds it differently per frame, producing a 1px gap alternating left/right.
    local bInset = db.pixelPerfect and DF:PixelPerfect(borderInset) or borderInset

    local anchor = db.resourceBarAnchor or "CENTER"
    local offX = db.resourceBarX or 0
    local offY = db.resourceBarY or 0
    -- Match Width defines the bar by its ENDS, anchored to the same frame
    -- corners the border edges use. The old single-point anchor + SetWidth
    -- spread the bar from its anchor, so each end could round onto a different
    -- physical pixel than the corner-anchored border band — a hairline gap of
    -- health bar beside the border at small border sizes (UI-scale dependent;
    -- the bInset snap above fixed only the fractional-width half of it).
    -- Corner-relative ends round identically to the border by construction.
    -- The anchor's other axis still places the bar; X/Y offsets still shift it.
    -- max(), not sum: the historical padding + borderInset inset pushed the bar
    -- one border-width PAST the border's inner edge whenever framePadding > 0,
    -- leaving a constant padding-wide sliver of health bar beside the bar at
    -- every border size (field-confirmed: bar x = 1.6 vs border width = 0.8).
    -- Flush against whichever boundary is innermost: the border band when it
    -- is thicker than the padding, the health bar's own inset otherwise.
    local edgeInset = math.max(padding, bInset)

    if isVertical then
        -- SWAP: "Width" applies to Height (Length), "Height" applies to Width (Thickness)
        bar:SetWidth(ppThickness)
        if db.resourceBarMatchWidth and healthBarHeight > 1 then
            local topPoint, bottomPoint
            if anchor:find("LEFT") then topPoint, bottomPoint = "TOPLEFT", "BOTTOMLEFT"
            elseif anchor:find("RIGHT") then topPoint, bottomPoint = "TOPRIGHT", "BOTTOMRIGHT"
            else topPoint, bottomPoint = "TOP", "BOTTOM" end
            bar:SetPoint(topPoint, frame, topPoint, offX, -edgeInset + offY)
            bar:SetPoint(bottomPoint, frame, bottomPoint, offX, edgeInset + offY)
        else
            bar:SetHeight(ppLength)
            bar:SetPoint(anchor, frame, anchor, offX, offY)
        end
    else
        bar:SetHeight(ppThickness)
        if db.resourceBarMatchWidth and healthBarWidth > 1 then
            local leftPoint, rightPoint
            if anchor:find("TOP") then leftPoint, rightPoint = "TOPLEFT", "TOPRIGHT"
            elseif anchor:find("BOTTOM") then leftPoint, rightPoint = "BOTTOMLEFT", "BOTTOMRIGHT"
            else leftPoint, rightPoint = "LEFT", "RIGHT" end
            bar:SetPoint(leftPoint, frame, leftPoint, edgeInset + offX, offY)
            bar:SetPoint(rightPoint, frame, rightPoint, -edgeInset + offX, offY)
        else
            bar:SetWidth(ppLength)
            bar:SetPoint(anchor, frame, anchor, offX, offY)
        end
    end

    -- Frame level - relative to the main frame. The default 20 puts it ABOVE the frame
    -- border (+13, see Frames/Create.lua CreateFrameBorder); below 13 renders under it.
    -- ⚠ This comment used to read "Default 2 ... below the frame border (at +10)" — the
    -- default has been 20 on the line below, and the border moved to 13 on 2026-08-14.
    local frameLevelOffset = db.resourceBarFrameLevel or 20
    bar:SetFrameLevel(frame:GetFrameLevel() + frameLevelOffset)
    if bar.border then
        bar.border:SetFrameLevel(bar:GetFrameLevel() + 1)
    end

    -- Background visibility and color
    if bar.bg then
        if db.resourceBarBackgroundEnabled ~= false then  -- Default to enabled
            bar.bg:Show()
            local bgC = db.resourceBarBackgroundColor or {r = 0.1, g = 0.1, b = 0.1, a = 0.8}
            bar.bg:SetColorTexture(bgC.r, bgC.g, bgC.b, bgC.a or 0.8)
        else
            bar.bg:Hide()
        end
    end

    -- Border via unified DF.Border backend (Stage 4.2). ctx.unit / ctx.frame let the
    -- Class / Role colour resolvers fire on live and test frames alike (test frames
    -- resolve via ctx.frame's dfIsTestFrame).
    if bar.border then
        DF.Border:Apply(bar.border, DF.Border:BuildSpec(db, "resourceBar", {
            unit  = frame.unit,
            frame = frame,
        }))
    end
end

function DF:ApplyResourceBarLayout(frame)
    if not frame then return end

    -- Use raid DB for raid frames, party DB for party frames
    local db = DF:GetFrameDB(frame)

    -- The power bar is created in Frames/Create.lua
    if not frame.dfPowerBar then return end
    local bar = frame.dfPowerBar

    -- Enabled + unit + role gates
    if not db.resourceBarEnabled then bar:Hide() return end
    if not frame.unit then bar:Hide() return end
    if not DF:ShouldShowResourceBar(frame.unit, db) then bar:Hide() return end

    -- Shared geometry/appearance (size, anchor, level, background, border).
    DF:LayoutResourceBar(frame, db)

    -- Live value + fill colour (the only part the test path does differently).
    local unit = frame.unit
    if unit and UnitExists(unit) then
        local power = UnitPower(unit)
        local maxPower = UnitPowerMax(unit)
        bar:SetMinMaxValues(0, maxPower)
        DF.SetBarValue(bar, power, frame, db.resourceBarSmooth)
        local cr, cg, cb = DF:GetResourceBarColor(unit, db)
        bar:SetStatusBarColor(cr, cg, cb, 1)
    end
end

function DF:UpdateResourceBar(frame)
    if not frame or not frame.unit then return end
    
    -- Use raid DB for raid frames, party DB for party frames
    local db = DF:GetFrameDB(frame)
    if not db.resourceBarEnabled then return end
    if not frame.dfPowerBar or not frame.dfPowerBar:IsShown() then return end
    
    local bar = frame.dfPowerBar
    local unit = frame.unit
    
    -- Only process player, party, and raid units
    if unit ~= "player" and not unit:match("^party%d$") and not unit:match("^raid%d+$") then
        bar:Hide()
        return
    end
    
    -- Check unit exists
    if not UnitExists(unit) then 
        bar:Hide()
        return 
    end
    
    -- Get power values - check if they're secret values
    local power = UnitPower(unit)
    local maxPower = UnitPowerMax(unit)
    
    if maxPower then
        bar:SetMinMaxValues(0, maxPower)
        DF.SetBarValue(bar, power, frame, db.resourceBarSmooth)

        -- Resolve fill colour per the configured colour mode (power / class / custom).
        local cr, cg, cb = DF:GetResourceBarColor(unit, db)
        bar:SetStatusBarColor(cr, cg, cb, 1)
    else
        bar:Hide()
    end
end

-- ============================================================
-- ABSORB BAR LOGIC
-- ============================================================
--
-- UpdateAbsorb performance pattern (2026-04-09):
--
-- UpdateAbsorb fires on UNIT_ABSORB_AMOUNT_CHANGED (plus cascading
-- calls from UpdateHealthFast, UpdateUnitFrame, FullFrameRefresh, and
-- several other sites). In raid combat it hits 90-100 calls per game
-- frame during Peak/tk bursts.
--
-- Pre-refactor the function did a full layout rebuild on every call:
-- 20+ frame API calls for anchors/strata/level/orientation, texture/
-- color/blend mode re-apply, overshield glow repositioning (another
-- 12+ API calls), etc. Almost all of this is layout state that only
-- changes when the user adjusts settings or the parent frame resizes.
-- The only things that genuinely change per-event are:
--
--   * maxHealth (UnitHealthMax) — occasionally (level up, stat procs)
--   * absorbs (UnitGetTotalAbsorbs) — every event (that's why we fire)
--   * For ATTACHED modes: `isClamped` from the absorb calculator —
--     this is secret-safe and changes per-event independently of
--     absorbs (the absorb amount vs current-missing-health ratio)
--
-- Fix: AbsorbLayoutStateChanged compares ~25 layout settings + parent
-- frame dimensions against values cached on frame.dfAbsorbState. If
-- nothing changed, we take a minimal fast path that only does the
-- value-related work. If anything changed, we run the full rebuild
-- (same code as before this refactor) and cache the new state at the
-- end.
--
-- This is the same pattern as the Dispel overlay refactor (commit
-- cd6746e), applied to UpdateAbsorb.
-- ============================================================

local DEFAULT_ABSORB_COLOR = {r = 0, g = 0.835, b = 1, a = 0.7}
local DEFAULT_ABSORB_BG_COLOR = {r = 0, g = 0, b = 0, a = 0.5}

-- Compare current absorb-bar layout settings against the cached state
-- on the frame. Returns true if anything that affects layout has
-- changed since the last full rebuild — which means we need to run
-- the full rebuild path. Returns false when everything matches, which
-- means we can take the minimal fast path.
local function AbsorbLayoutStateChanged(frame, db)
    local s = frame.dfAbsorbState
    if not s then return true end

    -- Mode + appearance (all modes)
    if s.mode            ~= (db.absorbBarMode or "OVERLAY")               then return true end
    -- ☠ THE ONE INPUT HERE THAT IS NOT A DB SETTING. Test frames are POOLED, nothing
    -- clears this cache on a test toggle, and the bar is usually still IsShown() from the
    -- last session -- so the first pass of a new session took the fast path with anchors
    -- left over from a torn-down layout, and the shield did not appear until you toggled
    -- test mode again. The token is bumped where testMode/raidTestMode are set.
    if s.testSession     ~= (DF.testSessionId or 0)                       then return true end
    -- ☠☠ THE FILL TEXTURE OBJECT IS REPLACED when a health bar texture is applied
    -- (styling on test entry, texture dropdown live) -- EllesmereUI carries the same
    -- lesson: "must be called whenever SetStatusBarTexture replaces the fill object".
    -- The attached absorb anchors to that OBJECT, so a swap orphans its anchors: the
    -- bar keeps rendering against a dead rect (usually invisible), and this cache --
    -- which compared only db settings -- said "nothing changed" forever after. THAT is
    -- why absorbs were missing on first test entry until any toggle, on exactly the
    -- non-clamped units: the clamped ones show the OVERFLOW bar, which anchors to the
    -- stable healthBar frame and never breaks. The prediction survives the same swap
    -- because it has no cache and re-anchors on every call. Comparing the live object
    -- identity makes the next UpdateAbsorb call take the full path and re-anchor.
    if s.healthFillTex   ~= (frame.healthBar and frame.healthBar:GetStatusBarTexture()) then return true end
    -- Which chain segment the absorb hangs off (live-derived, never a stamp).
    if s.chainEnd        ~= DF.ChainEndKey(frame, db)                     then return true end
    if s.texture         ~= (db.absorbBarTexture or DF.STOCK_BAR_TEXTURE)  then return true end
    if s.blendMode       ~= (db.absorbBarBlendMode or "BLEND")            then return true end
    if s.pixelPerfect    ~= db.pixelPerfect                               then return true end
    if s.oorEnabled      ~= db.oorEnabled                                 then return true end
    if s.oorAlpha        ~= (db.oorAbsorbBarAlpha or 0.5)                 then return true end
    local col = db.absorbBarColor or DEFAULT_ABSORB_COLOR
    if s.colR ~= col.r or s.colG ~= col.g or s.colB ~= col.b or s.colA ~= (col.a or 0.7) then return true end

    -- Border settings (affect inset calculations for attached/overlay modes).
    -- Alpha matters too: GetAbsorbEdgeInset flips flush(0) <-> inset at the
    -- opaque<->translucent threshold, so a Border Alpha change must invalidate.
    if s.frameShowBorder ~= (db.frameShowBorder ~= false)                 then return true end
    if s.frameBorderSize ~= (db.frameBorderSize or 1)                     then return true end
    if s.frameBorderAlpha ~= ((db.frameBorderColor and (db.frameBorderColor.a or db.frameBorderColor[4])) or 1) then return true end

    -- Floating-mode specific
    if s.orientation     ~= (db.absorbBarOrientation or "HORIZONTAL")     then return true end
    if s.width           ~= (db.absorbBarWidth or 50)                     then return true end
    if s.height          ~= (db.absorbBarHeight or 6)                     then return true end
    if s.anchor          ~= (db.absorbBarAnchor or "CENTER")              then return true end
    if s.offsetX         ~= (db.absorbBarX or 0)                          then return true end
    if s.offsetY         ~= (db.absorbBarY or 0)                          then return true end
    if s.reverse         ~= db.absorbBarReverse                           then return true end
    if s.frameLevel      ~= (db.absorbBarFrameLevel or 11)                then return true end
    local bgC = db.absorbBarBackgroundColor or DEFAULT_ABSORB_BG_COLOR
    if s.bgR ~= bgC.r or s.bgG ~= bgC.g or s.bgB ~= bgC.b or s.bgA ~= bgC.a then return true end

    -- Attached/overlay-mode specific
    if s.healthOrient    ~= (db.healthOrientation or "HORIZONTAL")        then return true end
    if s.overlayReverse  ~= db.absorbBarOverlayReverse                    then return true end
    if s.clampMode       ~= (db.absorbBarAttachedClampMode or 1)          then return true end

    -- Parent dimensions (detects frame resize — relevant for attached/overlay modes)
    if frame.healthBar then
        if s.parentW ~= frame.healthBar:GetWidth()  then return true end
        if s.parentH ~= frame.healthBar:GetHeight() then return true end
    end

    -- Overshield settings (ATTACHED mode)
    if s.showOvershield    ~= db.absorbBarShowOvershield                  then return true end
    if s.overshieldStyle   ~= (db.absorbBarOvershieldStyle or "SPARK")    then return true end
    if s.overshieldAlpha   ~= (db.absorbBarOvershieldAlpha or 0.8)        then return true end
    if s.overshieldReverse ~= db.absorbBarOvershieldReverse               then return true end
    local osc = db.absorbBarOvershieldColor or db.absorbBarColor or DEFAULT_ABSORB_COLOR
    if s.overshieldR ~= osc.r or s.overshieldG ~= osc.g or s.overshieldB ~= osc.b then return true end

    return false
end

-- Cache the current layout settings on frame.dfAbsorbState. Called at
-- the end of a full rebuild so subsequent calls can short-circuit via
-- AbsorbLayoutStateChanged.
local function CacheAbsorbLayoutState(frame, db)
    local s = frame.dfAbsorbState
    if not s then
        s = {}
        frame.dfAbsorbState = s
    end
    s.mode            = db.absorbBarMode or "OVERLAY"
    s.testSession     = DF.testSessionId or 0   -- not a db setting; see the note above
    -- Frame state, re-derived from the same reads the comparisons use.
    s.healthFillTex   = frame.healthBar and frame.healthBar:GetStatusBarTexture()
    s.chainEnd        = DF.ChainEndKey(frame, db)
    s.texture         = db.absorbBarTexture or DF.STOCK_BAR_TEXTURE
    s.blendMode       = db.absorbBarBlendMode or "BLEND"
    s.pixelPerfect    = db.pixelPerfect
    s.oorEnabled      = db.oorEnabled
    s.oorAlpha        = db.oorAbsorbBarAlpha or 0.5
    local col = db.absorbBarColor or DEFAULT_ABSORB_COLOR
    s.colR, s.colG, s.colB, s.colA = col.r, col.g, col.b, col.a or 0.7
    s.frameShowBorder = db.frameShowBorder ~= false
    s.frameBorderSize = db.frameBorderSize or 1
    s.frameBorderAlpha = (db.frameBorderColor and (db.frameBorderColor.a or db.frameBorderColor[4])) or 1
    s.orientation     = db.absorbBarOrientation or "HORIZONTAL"
    s.width           = db.absorbBarWidth or 50
    s.height          = db.absorbBarHeight or 6
    s.anchor          = db.absorbBarAnchor or "CENTER"
    s.offsetX         = db.absorbBarX or 0
    s.offsetY         = db.absorbBarY or 0
    s.reverse         = db.absorbBarReverse
    s.frameLevel      = db.absorbBarFrameLevel or 11
    local bgC = db.absorbBarBackgroundColor or DEFAULT_ABSORB_BG_COLOR
    s.bgR, s.bgG, s.bgB, s.bgA = bgC.r, bgC.g, bgC.b, bgC.a
    s.healthOrient    = db.healthOrientation or "HORIZONTAL"
    s.overlayReverse  = db.absorbBarOverlayReverse
    s.clampMode       = db.absorbBarAttachedClampMode or 1
    if frame.healthBar then
        s.parentW = frame.healthBar:GetWidth()
        s.parentH = frame.healthBar:GetHeight()
    end
    s.showOvershield    = db.absorbBarShowOvershield
    s.overshieldStyle   = db.absorbBarOvershieldStyle or "SPARK"
    s.overshieldAlpha   = db.absorbBarOvershieldAlpha or 0.8
    s.overshieldReverse = db.absorbBarOvershieldReverse
    local osc = db.absorbBarOvershieldColor or db.absorbBarColor or DEFAULT_ABSORB_COLOR
    s.overshieldR, s.overshieldG, s.overshieldB = osc.r, osc.g, osc.b
end

-- Edge inset for absorb / heal-absorb overlays. Returns 0 (flush to the health
-- bar) when the frame border is off or fully OPAQUE. This works by Z-ORDER, not
-- geometry: the border frame draws at parent frame level +13 while the absorb
-- overlay sits at +11, so an opaque border paints OVER a flush overlay and the
-- shield covers the health fill exactly with nothing showing through — no inset
-- needed.
-- ☠ THIS PREMISE WAS SILENTLY FALSE between 2026-08-13 and 2026-08-14: the z-order
-- convergence lifted the absorb overlay to +11 and left the border at +10, so the
-- border stopped painting over it and this function kept returning 0 for a case it
-- no longer covered. The border moving to +13 is what makes the sentence above true
-- again. If either number moves, RE-READ THIS — it is a dependency, not a note. Returns the pixel-snapped border size only when the border is
-- TRANSLUCENT, so the shield doesn't bleed through the border's edge band.
-- dfReducedMaxHealthClipping => 0 (the clip edge is internal, no border there).
function DF:GetAbsorbEdgeInset(frame, db)
    if not db or db.frameShowBorder == false then return 0 end
    local bc = db.frameBorderColor
    local alpha = (bc and (bc.a or bc[4])) or 1
    if alpha >= 1 then return 0 end
    local inset = (frame and frame.dfReducedMaxHealthClipping) and 0 or (db.frameBorderSize or 1)
    if db.pixelPerfect and DF.PixelPerfect then inset = DF:PixelPerfect(inset) end
    return inset
end

-- ☠ THE ONE DERIVATION OF THE ABSORB BAR'S FRAME LEVEL. Two paths set it and they
-- disagreed: this file's layout pass (mode-aware) and the Frame Level slider's live
-- preview in Core.lua, which applied absorbBarFrameLevel UNCONDITIONALLY -- even
-- though that slider is FLOATING-only by design (Pages/Auras.lua, levelSlider.hideOn).
-- A bound bar therefore landed at frame+11, BELOW the dispel overlay's gradient at
-- ~frame+17, and UpdateAbsorb's fast path returns before the level block, so the wrong
-- value stuck for the rest of the session.
--
-- Field-reported (Kaldoran, 5.1.0): with a shield up and a dispellable debuff applied,
-- the absorb vanished behind the dispel wash. ★ It only became visible when the
-- day-one fix made "Show On Current Health Only" clip correctly to the FILLED health
-- -- which is exactly where a bound absorb lives. The layering conflict predates that
-- fix; the fix is what gave it something to collide with.
--
-- A bound absorb MUST sit above the wash: the wash covers the filled health, so an
-- absorb underneath it is invisible for as long as any dispellable debuff is up --
-- i.e. the shield is hidden precisely when the frame matters most (Krathe's call).
-- FLOATING is a free-standing bar the user places and levels themselves, so it keeps
-- the slider.
function DF:ResolveAbsorbBarLevel(frame, db)
    if not frame or not frame.GetFrameLevel then return nil end
    local mode = (db and db.absorbBarMode) or "ATTACHED_OVERFLOW"
    if mode == "FLOATING" then
        return frame:GetFrameLevel() + ((db and db.absorbBarFrameLevel) or 11)
    end
    -- Bound to the health bar (OVERLAY / ATTACHED / ATTACHED_OVERFLOW): the ladder's
    -- own slot, +11 (see the map in Features/Dispel.lua). NOT the slider -- that is
    -- FLOATING-only, so reading it here would drag a bound bar to wherever a floating
    -- bar was last placed.
    --
    -- ☠ This deliberately does NOT try to out-rank the dispel wash. An earlier cut did
    -- (+15 off the health bar, landing above the gradient) and that was wrong: it made
    -- the absorb poke through FULL FRAME too, which is the mode whose whole point is
    -- covering the frame. Whether the wash hides the absorb is the WASH's business, and
    -- it is now conditional on "Show On Current Health Only" -- see
    -- DF:ResolveDispelGradientLevel in Features/Dispel.lua.
    return frame:GetFrameLevel() + 11
end

-- ★ THE OTHER TWO BOUND BARS. Same contract as the absorb resolver above and for the
-- same reason: the ladder is stated ONCE, here, and every mode branch asks for its slot
-- rather than doing its own arithmetic off the health bar.
--
-- ☠ What these replace was not a near-miss, it was a different ladder. Each updater
-- computed a level up top, applied it, then EVERY mode branch overwrote it with
-- healthLevel + 1..3. The real band was health +3, prediction +4, heal-absorb +5,
-- absorb +5, overflow +6 -- packed into four levels -- while the comments, the db keys
-- and DF:ResolveDispelGradientLevel all reasoned about +8/+11/+12. The dispel wash's
-- current-health slot of +4 was chosen to sit under that documented band and in fact
-- TIED with heal prediction; it drew correctly on creation order alone
-- (/df debug zorder on a live frame, 2026-08-13).
-- ⚠ The old branch comments justified themselves with "below dispel overlay (+6) and
-- aggro highlight (+9)". The overlay has been at +16 since 2026-08-07, and there is no
-- aggro-highlight level anywhere in the addon -- both numbers were fiction, and fiction
-- is what the arithmetic was protecting.
function DF:ResolveHealAbsorbBarLevel(frame, db)
    if not frame or not frame.GetFrameLevel then return nil end
    return frame:GetFrameLevel() + 8
end

-- ⚠ The key is user-facing so it wins; 12 is the ladder's slot and the shipped default.
function DF:ResolveHealPredictionBarLevel(frame, db)
    if not frame or not frame.GetFrameLevel then return nil end
    -- ☠ DEFAULT 10, AND IT MUST STAY UNDER THE ABSORB (+11). Krathe's rule, 2026-08-14:
    -- "incoming heals ... never sitting above absorbs, as they are more important." The
    -- two bars share the missing-health region, so whichever is higher HIDES the other
    -- where they overlap -- and the shield is the one you must not lose. This was 12,
    -- which put the heal on top and buried the absorb behind it.
    -- Band around it: heal-absorb +8 · >> heal prediction +10 << · absorb / overflow +11.
    -- ⚠ Still a user slider (0-100): raising it past 11 puts the heal back over the
    -- shield, which is then the user's explicit choice rather than the default.
    return frame:GetFrameLevel() + ((db and db.healPredictionFrameLevel) or 10)
end

-- ★ THE HEALTH BAR IS A CHAIN: health -> incoming heals -> absorb. All three references
-- agree. Blizzard's CompactUnitFrameUtil_UpdateFillBar walks a running cursor, anchoring
-- each segment to the previous one's far edge and returning the cursor unchanged for an
-- empty segment. Grid2's IndicatorMultiBar carries the same cursor as prevTex. oUF
-- (ElvUI) chains its healthprediction segments the same way and defaults
-- damageAbsorbClampMode to Enum 0, MissingHealth -- the heals-subtracted clamp.
--
-- ONE live read, used by the resolver, the cache and the prediction-tail prompt alike.
-- ☠ A cache key MUST derive from the same read as the thing it guards: an earlier cut
-- compared a stamp written only at UpdateHealPrediction's tail, which four hide paths
-- bypass, and the cache froze on "segment 1" while the resolver picked "fill".
-- ☠☠ TOMBSTONE: BLIZZARD'S HEAL-ABSORB NETTING WAS BUILT HERE AND REVERTED SAME-DAY
-- (2026-08-14). The model is right — a consuming heal absorb eats the first N points
-- of an incoming heal, so Blizzard back-shifts the heal to start at the heal-absorb
-- region's inner edge and hangs the shield at the health edge. The anchor-only
-- implementation rode the ATTACHED heal-absorb bar's fill texture. IT CANNOT BE MADE
-- SAFE ON LIVE: the heal-absorb amount is SECRET, so Lua can never ask "is it zero",
-- the bar stays shown once created, and the whole design silently rested on a
-- zero-value fill texture's rect collapsing exactly to the health edge. Krathe's
-- in-game test disproved that trust in minutes — Healsworth's heal moved with a heal
-- absorb of ZERO. ⇒ Do not rebuild this on IsShown()+fill-rect; it needs a handle
-- that is reliable at zero, or it stays divergent-from-Blizzard by design.
local function ChainEndKey(frame, db)
    if not frame then return "fill" end
    -- A FLOATING prediction is not on the health bar, so it never joins the chain.
    if db and (db.healPredictionMode or "OVERLAY") == "FLOATING" then return "fill" end
    local s2, s1 = frame.dfHealPredictionBar2, frame.dfHealPredictionBar
    if s2 and s2.IsShown and s2:IsShown() then return "seg2" end
    if s1 and s1.IsShown and s1:IsShown() then return "seg1" end
    return "fill"
end
DF.ChainEndKey = ChainEndKey   -- read by the /df debug zorder line

-- The texture the attached absorb hangs off: the last VISIBLE heal-prediction segment,
-- else the health fill. Returning a TEXTURE keeps the engine re-resolving the absorb
-- whenever the prediction resizes -- no arithmetic, no update-order coupling, and
-- nothing here can touch a secret value. ⚠ A hidden StatusBar keeps its last rect, so
-- the visible test is the whole trick (Blizzard's "return previousTexture" rule).
function DF:ResolveAbsorbChainAnchor(frame, db)
    local hb = frame and frame.healthBar
    local fill = hb and hb.GetStatusBarTexture and hb:GetStatusBarTexture() or nil
    local key = ChainEndKey(frame, db)
    frame.dfAbsorbChainPick = key   -- diagnostic only; the cache re-derives, never reads this
    local seg = (key == "seg2" and frame.dfHealPredictionBar2)
        or (key == "seg1" and frame.dfHealPredictionBar) or nil
    if seg and seg.GetStatusBarTexture then
        local t = seg:GetStatusBarTexture()
        if t then return t end
    end
    return fill
end

-- ☠ TEST FRAMES ARE PAINTED ONLY BY CALLERS THAT BRING TEST DATA. Styling and
-- health-change passes call the three bar updaters WITHOUT testIndex; on a test
-- frame whose unit happens to exist for real (the player's own), that call fell
-- through to the live branch and repainted the bar from real values -- solo, zero:
-- the heal prediction the test drive had just painted was hidden again, and the
-- chained absorb was left hanging behind an empty segment (the "black gap"). The
-- test drives are the only writers for a test frame; everyone else must leave it
-- alone. Previews differ in DATA, never in which caller happens to run last.
local function testFrameNeedsData(frame, testIndex)
    return (DF.testMode or DF.raidTestMode) and testIndex == nil
        and frame and frame.dfIsTestFrame
end

function DF:UpdateAbsorb(frame, testIndex)
    if not frame then return end
    if not frame.healthBar then return end
    if testFrameNeedsData(frame, testIndex) then return end

    -- MEMORY TEST: Skip if disabled (but allow test mode to still work)
    if DF:MemTestDisabled("enableAbsorbs") and not DF.testMode and not DF.raidTestMode then
        if frame.absorbBar then frame.absorbBar:Hide() end
        if frame.absorbOvershieldGlow then frame.absorbOvershieldGlow:Hide() end
        if frame.absorbOverflowBar then frame.absorbOverflowBar:Hide() end
        frame.dfAbsorbState = nil  -- invalidate so re-enabling does a full rebuild
        return
    end

    local unit = frame.unit
    local db = DF:GetFrameDB(frame)
    local mode = db.absorbBarMode or "OVERLAY"

    -- Get values - either from test data or real unit
    local maxHealth, absorbs
    -- testIncomingPercent / testReducedPct feed the clamp: chained behind the incoming
    -- heal, the space left to the shield is missing health minus that heal -- and the bar
    -- physically ends at the reduced max, so the reduced share is never available either.
    local isTestRender, testHealthPercent, testIncomingPercent, testReducedPct = false, nil, nil, nil

    if DF.testMode and testIndex ~= nil then
        -- testIndex may be a numeric index or a ready testData TABLE (the
        -- TestMode render/animation loop passes its per-tick data directly)
        local testData = type(testIndex) == "table" and testIndex or DF:GetTestUnitData(testIndex)
        if testData then
            maxHealth = testData.maxHealth
            absorbs = testData.absorbPercent * maxHealth
            isTestRender = true
            testHealthPercent = testData.healthPercent or 1
            testIncomingPercent = testData.healPredictionPercent or 0
            testReducedPct = testData.reducedMaxPct or 0
        else
            maxHealth = 100000
            absorbs = 0
        end
    elseif DF.raidTestMode and testIndex ~= nil then
        local testData = type(testIndex) == "table" and testIndex or DF:GetTestUnitData(testIndex, true)  -- true = raid
        if testData then
            maxHealth = testData.maxHealth
            absorbs = testData.absorbPercent * maxHealth
            isTestRender = true
            testHealthPercent = testData.healthPercent or 1
            testIncomingPercent = testData.healPredictionPercent or 0
            testReducedPct = testData.reducedMaxPct or 0
        else
            maxHealth = 100000
            absorbs = 0
        end
    else
        -- Only process player, party, and raid units for real data
        if not unit or (unit ~= "player" and not unit:match("^party%d$") and not unit:match("^raid%d+$")) then
            return
        end

        -- Ensure unit exists before querying
        if not UnitExists(unit) then
            return
        end

        -- Get values - StatusBar API handles secret values internally via SetMinMaxValues
        maxHealth = UnitHealthMax(unit)
        absorbs = UnitGetTotalAbsorbs(unit)
    end

    -- ========================================================
    -- FAST PATH: layout state unchanged since last rebuild
    -- ========================================================
    -- The common case in combat: settings/mode/dimensions are stable,
    -- only the absorb value (and possibly isClamped for ATTACHED modes)
    -- has changed. Skip ~90% of the function body.
    local customBar = frame.dfAbsorbBar
    -- Diagnostic for /df debug zorder: did this call short-circuit or re-anchor?
    frame.dfAbsorbFastPath = false
    if customBar and customBar:IsShown() and not AbsorbLayoutStateChanged(frame, db) then
        frame.dfAbsorbFastPath = true
        if mode == "ATTACHED" or mode == "ATTACHED_OVERFLOW" then
            -- Need the calculator for clamped state (secret, can't cache).
            -- The calculator object itself is already cached on the frame.
            local attachedAbsorbs = absorbs
            local isClamped = false
            if isTestRender then
                -- Test data: the calculator can only query the REAL unit (0 solo),
                -- so derive the clamped value from the mock percentages instead.
                -- ☠ SAME SUM AND SAME GATE AS THE FULL PATH, always. This fast-path copy
                -- once kept an older formula and the shield's length depended on which
                -- path ran; then it missed the clamp-mode gate the same way. One rule:
                -- only "Missing Health" (1) space-clamps; clipping-aware reduced share
                -- (see the full path's ONE RULER note); heals subtracted only when the
                -- shield chains behind them.
                if (db.absorbBarAttachedClampMode or 1) == 1 then
                    local reducedShare = ((db.reducedMaxHealthEnabled ~= false)
                        and not frame.dfReducedMaxHealthClipping) and (testReducedPct or 0) or 0
                    local usable = maxHealth * (1 - reducedShare)
                    local curHealth = testHealthPercent * maxHealth
                    local incoming = (DF.ChainEndKey(frame, db) ~= "fill") and (testIncomingPercent or 0) * maxHealth or 0
                    local available = usable - curHealth - incoming
                    if absorbs > available then
                        attachedAbsorbs = math.max(0, available)
                        isClamped = true
                    end
                end
            elseif frame.absorbCalculator and unit and CreateUnitHealPredictionCalculator then
                UnitGetDetailedHealPrediction(unit, nil, frame.absorbCalculator)
                if frame.absorbCalculator.GetDamageAbsorbs then
                    local r1, r2 = frame.absorbCalculator:GetDamageAbsorbs()
                    if r1 then
                        attachedAbsorbs = r1
                        isClamped = r2
                    end
                end
            end

            customBar:SetMinMaxValues(0, maxHealth)
            DF.SetBarValue(customBar, attachedAbsorbs, frame)

            if mode == "ATTACHED_OVERFLOW" and frame.absorbOverflowBar then
                -- Overflow bar gets the unclamped absorb amount
                frame.absorbOverflowBar:SetMinMaxValues(0, maxHealth)
                DF.SetBarValue(frame.absorbOverflowBar, absorbs, frame)

                -- Compute the OOR-adjusted "visible" alpha
                local visAlpha = 1
                if db.oorEnabled then
                    local inRange = frame.dfInRange
                    if not (issecretvalue and issecretvalue(inRange)) and inRange == false then
                        visAlpha = db.oorAbsorbBarAlpha or 0.5
                    end
                end

                -- Secret-safe visibility toggle via visibility helpers.
                -- When clamped: show overflow, hide attached.
                -- When not clamped: show attached, hide overflow.
                if customBar.visibilityHelper then
                    customBar.visibilityHelper:SetAlphaFromBoolean(isClamped, 0, visAlpha)
                    customBar:SetAlpha(customBar.visibilityHelper:GetAlpha())
                end
                if frame.absorbOverflowBar.visibilityHelper then
                    frame.absorbOverflowBar.visibilityHelper:SetAlphaFromBoolean(isClamped, visAlpha, 0)
                    frame.absorbOverflowBar:SetAlpha(frame.absorbOverflowBar.visibilityHelper:GetAlpha())
                end
            elseif mode == "ATTACHED" and frame.absorbOvershieldGlow and db.absorbBarShowOvershield then
                -- ATTACHED mode: overshield glow visibility toggles with isClamped
                frame.absorbOvershieldGlow:SetAlphaFromBoolean(isClamped, db.absorbBarOvershieldAlpha or 0.8, 0)
            end
        else
            -- OVERLAY / FLOATING mode: simplest fast path — just value + OOR
            customBar:SetMinMaxValues(0, maxHealth)
            DF.SetBarValue(customBar, absorbs, frame)
        end

        -- OOR alpha refresh on the main bar. Range state can change
        -- independently of settings (Range.lua updates frame.dfInRange
        -- from the range ticker), so we always re-apply even on the
        -- fast path.
        if db.oorEnabled and customBar.SetAlphaFromBoolean then
            local inRange = frame.dfInRange
            if not (issecretvalue and issecretvalue(inRange)) and inRange == nil then inRange = true end
            -- ATTACHED_OVERFLOW's visibility helpers already encode OOR into
            -- their alpha calculation above, so don't double-apply there.
            if mode ~= "ATTACHED_OVERFLOW" then
                customBar:SetAlphaFromBoolean(inRange, 1, db.oorAbsorbBarAlpha or 0.5)
            end
        end

        return
    end

    -- ========================================================
    -- FULL REBUILD PATH (something changed, reapply all layout)
    -- ========================================================

    -- ALWAYS hide overshield glow and overflow bar when switching modes
    -- This must happen before any early returns to prevent stuck visuals
    if frame.absorbOvershieldGlow then
        frame.absorbOvershieldGlow:Hide()
    end
    if frame.absorbOverflowBar then
        frame.absorbOverflowBar:Hide()
    end

    -- NOTE (2026-04-09): the old code used to hide frame.totalAbsorb,
    -- frame.overAbsorbGlow, and frame.totalAbsorbOverlay here. Those
    -- fields are Blizzard CompactUnitFrame elements and DF frames are
    -- built from SecureUnitButtonTemplate, not CompactUnitFrame — so
    -- those fields are ALWAYS nil on our frames. The old Hide() calls
    -- were literally no-ops guarded by always-nil checks. Removed.
    
    -- Create custom absorb bar if needed
    if not frame.dfAbsorbBar then
        frame.dfAbsorbBar = CreateFrame("StatusBar", nil, frame)
        frame.dfAbsorbBar:SetMinMaxValues(0, 1)
        frame.dfAbsorbBar:EnableMouse(false)
        
        -- Background for floating mode
        local bg = frame.dfAbsorbBar:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(true)
        bg:SetColorTexture(0, 0, 0, 0.5)
        frame.dfAbsorbBar.bg = bg
    end
    
    local customBar = frame.dfAbsorbBar
    
    -- Level. In the health-bar-BOUND modes (OVERLAY / ATTACHED / ATTACHED_OVERFLOW) the
    -- level is DERIVED, by design: the Frame Level slider is FLOATING-only
    -- (Pages/Auras.lua, `levelSlider.hideOn`), because a bar pinned to the health bar has
    -- no meaningful level of its own to expose. FLOATING and ATTACHED override this below.
    --
    -- ☠ This +15 used to be one of three branches selected by an `absorbBarStrata` key that
    -- had NO UI, no migration and no writer of any kind -- so every profile held the
    -- "MEDIUM" default and the other two branches (+3 / +1) were unreachable. Collapsed to
    -- the value that actually shipped. NOTHING MOVED; see the commit for the audit.
    -- ⚠ OPEN, deliberately not changed here: healthBar sits at frame+3, so this lands the
    -- bar at ~frame+18 -- above the dispel overlay's +16/+17 band -- while
    -- absorbBarFrameLevel (the FLOATING slider), Core.lua's re-level and the z-order map all
    -- say +11. Whether the bound modes SHOULD move to +11 is a design call needing in-game
    -- measurement, not arithmetic. See [[zorder_layer_map]].
    local healthLevel = frame.healthBar:GetFrameLevel()
    local absorbLevel = DF:ResolveAbsorbBarLevel(frame, db) or (healthLevel + 15)

    customBar:SetParent(frame)
    customBar:SetFrameStrata(frame:GetFrameStrata())
    customBar:SetFrameLevel(absorbLevel)
    
    -- Texture and color
    local tex = db.absorbBarTexture or DF.STOCK_BAR_TEXTURE
    local isVerticalFill
    tex, isVerticalFill = ResolveBarTextureForFill(db, tex, mode, "absorbBarOrientation")
    local col = db.absorbBarColor or {r = 0, g = 0.835, b = 1, a = 0.7}
    local blendMode = db.absorbBarBlendMode or "BLEND"
    
    -- Apply texture only if changed to prevent flickering
    if customBar.currentTexture ~= tex then
        customBar.currentTexture = tex
        if tex == "Interface\\RaidFrame\\Shield-Overlay" then
            customBar:SetStatusBarTexture(tex)
            local barTex = customBar:GetStatusBarTexture()
            if barTex then
                -- Wrap set WITH the file, as Blizzard's own template declares for
                -- this texture (UnitFrame.xml, horizTile/vertTile on the node) --
                -- SetStatusBarTexture alone leaves the sampler clamped. Same rule
                -- as DF's tiled textures; see ☠ in DF:ApplyBarTextureTiling.
                barTex:SetTexture(tex, "REPEAT", "REPEAT")
                barTex:SetHorizTile(true)
                barTex:SetVertTile(true)
                barTex:SetTexCoord(0, 2, 0, 1)
                barTex:SetDesaturated(true)
                barTex:SetDrawLayer("ARTWORK", 2)
            end
        else
            -- Tiling follows the texture that actually LANDED: if the safe setter
            -- substituted the stock fallback, tile against that, not the path we
            -- asked for (the fallback is a stretched texture).
            local applied = DF:SafeSetStatusBarTexture(customBar, tex)
            DF:ApplyBarTextureTiling(customBar, applied == false and DF.STOCK_BAR_TEXTURE or tex)
            local barTex = customBar:GetStatusBarTexture()
            if barTex then
                barTex:SetDesaturated(false)
                barTex:SetDrawLayer("ARTWORK", 1)
            end
        end
    end
    
    -- Always apply blend mode (may have changed without texture change)
    local barTex = customBar:GetStatusBarTexture()
    if barTex then
        barTex:SetBlendMode(blendMode)
    end
    
    -- Always apply color (fast operation, doesn't cause flicker)
    if tex == "Interface\\RaidFrame\\Shield-Overlay" and blendMode == "ADD" then
        customBar:SetStatusBarColor(col.r * 2, col.g * 2, col.b * 2, 1)
    else
        customBar:SetStatusBarColor(col.r, col.g, col.b, col.a or 0.7)
    end
    
    customBar:Show()
    customBar:ClearAllPoints()
    -- Reset frame alpha (may have been set to 0 by ATTACHED_OVERFLOW mode)
    -- Respect OOR fade: use SetAlphaFromBoolean to handle secret values from UnitInRange
    if db.oorEnabled and customBar.SetAlphaFromBoolean then
        local inRange = frame.dfInRange
        if not (issecretvalue and issecretvalue(inRange)) and inRange == nil then inRange = true end
        customBar:SetAlphaFromBoolean(inRange, 1, db.oorAbsorbBarAlpha or 0.5)
    else
        customBar:SetAlpha(1)
    end
    
    -- ============================================================
    -- MODE: FLOATING
    -- ============================================================
    if mode == "FLOATING" then
        -- Clear any existing anchors first
        customBar:ClearAllPoints()
        
        -- Set parent first
        customBar:SetParent(frame)
        
        -- Apply strata - must be done after SetParent
        -- Hide briefly to force strata change to take effect
        local wasShown = customBar:IsShown()
        if wasShown then customBar:Hide() end

        -- ☠ MEDIUM, not the parent's strata. This is the ONE place absorbBarStrata was a
        -- real frame strata rather than a level selector, and with the key unwritable its
        -- value was always "MEDIUM" -- so a floating bar has always been pinned to MEDIUM
        -- regardless of the frame's own strata. Preserved verbatim; see the commit.
        -- ⚠ Latent oddity, NOT changed here: frames on a higher strata would render OVER
        -- their own floating absorb bar. Nobody has reported it, and "follow the parent"
        -- is a behaviour change, so it wants a decision rather than a quiet fix. Note that
        -- heal prediction, whose key defaulted to SANDWICH, takes the opposite branch and
        -- DOES follow the parent -- the asymmetry is accident, not design.
        customBar:SetFrameStrata("MEDIUM")

        -- Use user-configured frame level for floating mode
        customBar:SetFrameLevel(frame:GetFrameLevel() + (db.absorbBarFrameLevel or 11))
        
        if wasShown then customBar:Show() end
        
        -- Dimensions & Orientation
        local orientation = db.absorbBarOrientation or "HORIZONTAL"
        customBar:SetOrientation(orientation)
        customBar:SetReverseFill(db.absorbBarReverse or false)
        
        local w = db.absorbBarWidth or 50
        local h = db.absorbBarHeight or 6
        
        -- Apply pixel-perfect adjustments
        if db.pixelPerfect then
            w = DF:PixelPerfect(w)
            h = DF:PixelPerfect(h)
        end
        
        if orientation == "VERTICAL" then
            customBar:SetWidth(h)
            customBar:SetHeight(w)
        else
            customBar:SetWidth(w)
            customBar:SetHeight(h)
        end
        
        local anchor = db.absorbBarAnchor or "CENTER"
        local x = db.absorbBarX or 0
        local y = db.absorbBarY or 0
        customBar:SetPoint(anchor, frame, anchor, x, y)
        
        customBar:SetMinMaxValues(0, maxHealth)
        
        if customBar.bg then
            customBar.bg:Show()
            local bgC = db.absorbBarBackgroundColor or {r = 0, g = 0, b = 0, a = 0.5}
            customBar.bg:SetColorTexture(bgC.r, bgC.g, bgC.b, bgC.a)
        end
        
        -- Hide any existing border elements
        if customBar.border then customBar.border:Hide() end
        customBar:SetScript("OnUpdate", nil)
        
        -- Set bar value
        DF.SetBarValue(customBar, absorbs, frame)
        
    -- ============================================================
    -- MODE: ATTACHED (anchors to health bar fill texture)
    -- Uses SetDamageAbsorbClampMode(2) for max health clamping
    -- ============================================================
    elseif mode == "ATTACHED" then
        customBar:ClearAllPoints()
        customBar:SetParent(frame.healthBar)
        customBar:SetFrameStrata(frame:GetFrameStrata())
        -- ☠ The ladder's absorb slot, resolved once at the top of this function.
        -- Was healthLevel + 2 (frame+5), justified by a dispel overlay at +6 that has
        -- been at +16 since 2026-08-07 -- see DF:ResolveHealAbsorbBarLevel.
        customBar:SetFrameLevel(absorbLevel)
        
        -- Re-assert the texture's tiling mode. This block used to force tiling OFF
        -- unconditionally "to prevent dense repeating in narrow bars" — which is
        -- still the right default, and ApplyBarTextureTiling keeps it for every
        -- stretched texture. But it runs AFTER the texture is applied above, so a
        -- blanket SetHorizTile(false) here silently undid the tiling for textures
        -- that opt into it (DF.TILED_BAR_TEXTURES). Ask the texture instead.
        DF:ApplyBarTextureTiling(customBar, tex)
        
        if customBar.bg then customBar.bg:Hide() end
        
        local healthFillTexture = frame.healthBar:GetStatusBarTexture()
        if not healthFillTexture then
            customBar:Hide()
            return
        end
        
        -- Use the calculator API for ATTACHED mode
        local attachedAbsorbs = absorbs
        local isClamped = false
        
        -- Create/reuse the calculator (test data: derive from mock percentages
        -- instead — the calculator can only query the REAL unit, 0 when solo)
        if isTestRender then
            -- Preview values are plain numbers, so the sum the live path defers to the
            -- calculator is done directly. The space left to the shield is the USABLE bar
            -- (reduced max subtracted -- the bar physically ends there) minus current
            -- health minus, when the shield is chained behind it, the incoming heal.
            -- ☠ ONE RULER. When reduced-max CLIPPING is active the health bar is
            -- physically shrunk to the usable width, so every test percentage already
            -- renders on the USABLE ruler -- subtracting the reduced share here as well
            -- double-counts it, and the shield reads "no room" on a bar with visible
            -- missing health (Xx: black + overshield at once; the per-frame forensics
            -- proved it -- same 25% heal, 27px of fill on an unclipped bar, 17px on
            -- Xx's clipped one). Only a non-clipped reduced render, where percentages
            -- still span the full bar and the striped zone merely overlays it, needs
            -- the subtraction.
            -- Honour the Clamp Mode setting, mirroring live: only "Missing Health" (1)
            -- space-clamps. "None" (0) and "Max Health" (2) don't constrain the preview
            -- (test values never exceed max), so the shield may overrun — exactly what
            -- those settings mean on live frames.
            if (db.absorbBarAttachedClampMode or 1) == 1 then
                local reducedShare = ((db.reducedMaxHealthEnabled ~= false)
                    and not frame.dfReducedMaxHealthClipping) and (testReducedPct or 0) or 0
                local usable = maxHealth * (1 - reducedShare)
                local curHealth = testHealthPercent * maxHealth
                local incoming = (DF.ChainEndKey(frame, db) ~= "fill") and (testIncomingPercent or 0) * maxHealth or 0
                local available = usable - curHealth - incoming
                if absorbs > available then
                    attachedAbsorbs = math.max(0, available)
                    isClamped = true
                end
            end
        elseif CreateUnitHealPredictionCalculator and unit then
            if not frame.absorbCalculator then
                frame.absorbCalculator = CreateUnitHealPredictionCalculator()
            end
            local calc = frame.absorbCalculator
            
            -- Clamp mode from settings. ☠ DF's DROPDOWN LABELS ARE NOT BLIZZARD'S ENUM:
            -- the UI says 0=None / 1=Missing Health / 2=Max Health, but the value goes
            -- straight to SetDamageAbsorbClampMode, where Blizzard defines
            -- 0=MissingHealth (incoming heals SUBTRACTED), 1=MissingHealthWithoutIncomingHeals,
            -- 2=MaximumHealth. So the user's "Missing Health" (1) ignores heals -- fine
            -- while the shield started at the health fill, but chained BEHIND the heal it
            -- hands the bar a length that no longer fits and it runs off the end. When the
            -- chain is active, 1 is promoted to 0: the same "Missing Health" intent the
            -- label promises, heals-aware -- and the clamp oUF itself defaults to. The
            -- arithmetic stays inside the calculator, where secret values are legal.
            -- 0 ("None") and 2 ("Max Health") pass through untouched.
            local clampMode = db.absorbBarAttachedClampMode or 1
            if clampMode == 1 and DF.ChainEndKey(frame, db) ~= "fill" then clampMode = 0 end
            -- DF's "None (no clamping)" stores 0 — which in BLIZZARD's enum is
            -- MissingHealth-with-heals, the HARSHEST clamp, the opposite of the label.
            -- The enum has no true "off"; MaximumHealth (2) is the nearest thing (the
            -- bar can never draw past max anyway), so "None" maps there.
            if (db.absorbBarAttachedClampMode or 1) == 0 then clampMode = 2 end
            if calc.SetDamageAbsorbClampMode then calc:SetDamageAbsorbClampMode(clampMode) end

            -- Populate the calculator
            UnitGetDetailedHealPrediction(unit, nil, calc)

            -- Get clamped absorbs and clamped bool
            if calc.GetDamageAbsorbs then
                local result1, result2 = calc:GetDamageAbsorbs()
                if result1 then
                    attachedAbsorbs = result1
                    isClamped = result2  -- This is a secret bool in M+
                end
            end
        end

        -- Create/update overshield glow at max health position
        if db.absorbBarShowOvershield then
            -- ★ THE GLOW NEEDS ITS OWN HOST, ABOVE THE WHOLE BAND.
            -- It used to be a texture created straight on frame.healthBar (frame+3). A
            -- draw layer only orders textures WITHIN one frame, so against any bar that
            -- is a separate frame the level wins and the glow was buried whatever OVERLAY
            -- sublevel it was given. Blizzard puts the equivalent (overAbsorbGlow) at
            -- ARTWORK sublevel 2, above the prediction and the absorb both: it is the
            -- alert that the shield ran past the bar, so it is the one element that wins.
            -- ⚠ Every glow anchor below names frame.healthBar explicitly, so re-parenting
            -- the texture moves nothing.
            if not frame.dfOvershieldHost then
                frame.dfOvershieldHost = CreateFrame("Frame", nil, frame)
                frame.dfOvershieldHost:SetAllPoints(frame.healthBar)
            end
            frame.dfOvershieldHost:SetFrameLevel(frame:GetFrameLevel() + 13)
            frame.dfOvershieldHost:Show()
            if not frame.absorbOvershieldGlow then
                frame.absorbOvershieldGlow = frame.dfOvershieldHost:CreateTexture(nil, "OVERLAY", nil, 7)
            end
            
            local glow = frame.absorbOvershieldGlow
            local glowStyle = db.absorbBarOvershieldStyle or "SPARK"
            -- Default to absorb bar color if not set
            local glowColor = db.absorbBarOvershieldColor or db.absorbBarColor or {r = 1, g = 1, b = 1}
            local glowAlpha = db.absorbBarOvershieldAlpha or 0.8
            local reversePos = db.absorbBarOvershieldReverse or false
            
            local healthOrient = db.healthOrientation or "HORIZONTAL"
            local isHorizontal = (healthOrient == "HORIZONTAL" or healthOrient == "HORIZONTAL_INV")
            local isReversed = (healthOrient == "HORIZONTAL_INV" or healthOrient == "VERTICAL_INV")
            
            -- For absorbs, default is max HP side. Reverse option flips to no HP side.
            local atMaxHP = not reversePos
            -- Determine which side based on orientation and whether we want max HP side
            local atEnd = (atMaxHP ~= isReversed)  -- XOR: if both true or both false, we're at right/top
            
            glow:ClearAllPoints()
            glow:SetRotation(0)
            glow:SetTexCoord(0, 1, 0, 1)
            
            if glowStyle == "LINE" then
                glow:SetTexture("Interface\\Buttons\\WHITE8x8")
                glow:SetBlendMode("ADD")
                if isHorizontal then
                    if atEnd then
                        glow:SetPoint("TOPRIGHT", frame.healthBar, "TOPRIGHT", 0, 0)
                        glow:SetPoint("BOTTOMRIGHT", frame.healthBar, "BOTTOMRIGHT", 0, 0)
                    else
                        glow:SetPoint("TOPLEFT", frame.healthBar, "TOPLEFT", 0, 0)
                        glow:SetPoint("BOTTOMLEFT", frame.healthBar, "BOTTOMLEFT", 0, 0)
                    end
                    glow:SetWidth(db.pixelPerfect and DF:PixelPerfect(2) or 2)
                else
                    if atEnd then
                        glow:SetPoint("TOPLEFT", frame.healthBar, "TOPLEFT", 0, 0)
                        glow:SetPoint("TOPRIGHT", frame.healthBar, "TOPRIGHT", 0, 0)
                    else
                        glow:SetPoint("BOTTOMLEFT", frame.healthBar, "BOTTOMLEFT", 0, 0)
                        glow:SetPoint("BOTTOMRIGHT", frame.healthBar, "BOTTOMRIGHT", 0, 0)
                    end
                    glow:SetHeight(db.pixelPerfect and DF:PixelPerfect(2) or 2)
                end
                
            elseif glowStyle == "GRADIENT" then
                glow:SetBlendMode("ADD")
                if isHorizontal then
                    glow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\" .. (atEnd and "DF_Gradient_H_Rev" or "DF_Gradient_H"))
                    if atEnd then
                        glow:SetPoint("TOPRIGHT", frame.healthBar, "TOPRIGHT", 0, 0)
                        glow:SetPoint("BOTTOMRIGHT", frame.healthBar, "BOTTOMRIGHT", 0, 0)
                    else
                        glow:SetPoint("TOPLEFT", frame.healthBar, "TOPLEFT", 0, 0)
                        glow:SetPoint("BOTTOMLEFT", frame.healthBar, "BOTTOMLEFT", 0, 0)
                    end
                    glow:SetWidth(20)
                else
                    glow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\" .. (atEnd and "DF_Gradient_V_Rev" or "DF_Gradient_V"))
                    if atEnd then
                        glow:SetPoint("TOPLEFT", frame.healthBar, "TOPLEFT", 0, 0)
                        glow:SetPoint("TOPRIGHT", frame.healthBar, "TOPRIGHT", 0, 0)
                    else
                        glow:SetPoint("BOTTOMLEFT", frame.healthBar, "BOTTOMLEFT", 0, 0)
                        glow:SetPoint("BOTTOMRIGHT", frame.healthBar, "BOTTOMRIGHT", 0, 0)
                    end
                    glow:SetHeight(20)
                end
                
            elseif glowStyle == "GLOW" then
                glow:SetBlendMode("ADD")
                if isHorizontal then
                    glow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\" .. (atEnd and "DF_Gradient_H_Rev" or "DF_Gradient_H"))
                    if atEnd then
                        glow:SetPoint("TOPRIGHT", frame.healthBar, "TOPRIGHT", 0, 0)
                        glow:SetPoint("BOTTOMRIGHT", frame.healthBar, "BOTTOMRIGHT", 0, 0)
                    else
                        glow:SetPoint("TOPLEFT", frame.healthBar, "TOPLEFT", 0, 0)
                        glow:SetPoint("BOTTOMLEFT", frame.healthBar, "BOTTOMLEFT", 0, 0)
                    end
                    glow:SetWidth(10)
                else
                    glow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\" .. (atEnd and "DF_Gradient_V_Rev" or "DF_Gradient_V"))
                    if atEnd then
                        glow:SetPoint("TOPLEFT", frame.healthBar, "TOPLEFT", 0, 0)
                        glow:SetPoint("TOPRIGHT", frame.healthBar, "TOPRIGHT", 0, 0)
                    else
                        glow:SetPoint("BOTTOMLEFT", frame.healthBar, "BOTTOMLEFT", 0, 0)
                        glow:SetPoint("BOTTOMRIGHT", frame.healthBar, "BOTTOMRIGHT", 0, 0)
                    end
                    glow:SetHeight(10)
                end
                
            elseif glowStyle == "SPARK" then
                glow:SetBlendMode("ADD")
                if isHorizontal then
                    glow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\" .. (atEnd and "DF_Gradient_H_Rev" or "DF_Gradient_H"))
                    if atEnd then
                        glow:SetPoint("TOPRIGHT", frame.healthBar, "TOPRIGHT", 0, 0)
                        glow:SetPoint("BOTTOMRIGHT", frame.healthBar, "BOTTOMRIGHT", 0, 0)
                    else
                        glow:SetPoint("TOPLEFT", frame.healthBar, "TOPLEFT", 0, 0)
                        glow:SetPoint("BOTTOMLEFT", frame.healthBar, "BOTTOMLEFT", 0, 0)
                    end
                    glow:SetWidth(5)
                else
                    glow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\" .. (atEnd and "DF_Gradient_V_Rev" or "DF_Gradient_V"))
                    if atEnd then
                        glow:SetPoint("TOPLEFT", frame.healthBar, "TOPLEFT", 0, 0)
                        glow:SetPoint("TOPRIGHT", frame.healthBar, "TOPRIGHT", 0, 0)
                    else
                        glow:SetPoint("BOTTOMLEFT", frame.healthBar, "BOTTOMLEFT", 0, 0)
                        glow:SetPoint("BOTTOMRIGHT", frame.healthBar, "BOTTOMRIGHT", 0, 0)
                    end
                    glow:SetHeight(5)
                end
            end
            
            glow:SetVertexColor(glowColor.r, glowColor.g, glowColor.b, 1)
            glow:Show()
            -- In test mode or if clamped, show the glow
            if testIndex then
                glow:SetAlpha(glowAlpha)
            else
                glow:SetAlphaFromBoolean(isClamped, glowAlpha, 0)
            end
        elseif frame.absorbOvershieldGlow then
            frame.absorbOvershieldGlow:Hide()
        end
        
        local healthOrient = db.healthOrientation or "HORIZONTAL"
        local inset = 0
        if db.frameShowBorder ~= false then
            inset = frame.dfReducedMaxHealthClipping and 0 or (db.frameBorderSize or 1)  -- 0 when clipped: the clip edge is internal, no frame border there
        end
        if db.pixelPerfect and DF.PixelPerfect then inset = DF:PixelPerfect(inset) end
        
        local barWidth = frame.healthBar:GetWidth() - (inset * 2)
        local barHeight = frame.healthBar:GetHeight() - (inset * 2)
        
        -- Use StatusBar API to handle proportional fill - no manual division needed.
        -- Pixel-perfect: pin the CROSS axis to the health fill's two edges so the
        -- shield matches the fill with no sliver/gap. edgeInset insets that axis ONLY
        -- when the frame border is translucent (so the shield doesn't show through it);
        -- it is 0 for an opaque/absent border. The PRIMARY axis keeps its sized extent.
        local edgeInset = DF:GetAbsorbEdgeInset(frame, db)
        -- ★ CHAIN: hang off the last visible heal-prediction segment so the shield sits
        -- BESIDE the incoming heal (Blizzard order: health -> heals -> absorb). With no
        -- heal inbound the anchor IS the health fill, so that case is unchanged.
        local chainTex = DF:ResolveAbsorbChainAnchor(frame, db) or healthFillTexture
        if healthOrient == "HORIZONTAL" then
            customBar:SetOrientation("HORIZONTAL")
            customBar:SetReverseFill(false)
            customBar:SetWidth(barWidth)
            customBar:SetPoint("TOPLEFT", chainTex, "TOPRIGHT", 0, -edgeInset)
            customBar:SetPoint("BOTTOMLEFT", chainTex, "BOTTOMRIGHT", 0, edgeInset)
        elseif healthOrient == "HORIZONTAL_INV" then
            customBar:SetOrientation("HORIZONTAL")
            customBar:SetReverseFill(true)
            customBar:SetWidth(barWidth)
            customBar:SetPoint("TOPRIGHT", chainTex, "TOPLEFT", 0, -edgeInset)
            customBar:SetPoint("BOTTOMRIGHT", chainTex, "BOTTOMLEFT", 0, edgeInset)
        elseif healthOrient == "VERTICAL" then
            customBar:SetOrientation("VERTICAL")
            customBar:SetReverseFill(false)
            customBar:SetHeight(barHeight)
            customBar:SetPoint("BOTTOMLEFT", chainTex, "TOPLEFT", edgeInset, 0)
            customBar:SetPoint("BOTTOMRIGHT", chainTex, "TOPRIGHT", -edgeInset, 0)
        elseif healthOrient == "VERTICAL_INV" then
            customBar:SetOrientation("VERTICAL")
            customBar:SetReverseFill(true)
            customBar:SetHeight(barHeight)
            customBar:SetPoint("TOPLEFT", chainTex, "BOTTOMLEFT", edgeInset, 0)
            customBar:SetPoint("TOPRIGHT", chainTex, "BOTTOMRIGHT", -edgeInset, 0)
        end
        
        -- Let WoW's StatusBar handle the percentage calculation internally
        customBar:SetMinMaxValues(0, maxHealth)
        DF.SetBarValue(customBar, attachedAbsorbs, frame)
        
        if customBar.border then customBar.border:Hide() end
        customBar:SetScript("OnUpdate", nil)

    -- ============================================================
    -- MODE: ATTACHED_OVERFLOW (attached bar + overlay when clamped)
    -- ============================================================
    elseif mode == "ATTACHED_OVERFLOW" then
        customBar:ClearAllPoints()
        customBar:SetParent(frame.healthBar)
        customBar:SetFrameStrata(frame:GetFrameStrata())
        -- ☠ The ladder's absorb slot, resolved once at the top of this function.
        -- Was healthLevel + 2 (frame+5), justified by a dispel overlay at +6 that has
        -- been at +16 since 2026-08-07 -- see DF:ResolveHealAbsorbBarLevel.
        customBar:SetFrameLevel(absorbLevel)
        
        -- Re-assert the texture's tiling mode. This block used to force tiling OFF
        -- unconditionally "to prevent dense repeating in narrow bars" — which is
        -- still the right default, and ApplyBarTextureTiling keeps it for every
        -- stretched texture. But it runs AFTER the texture is applied above, so a
        -- blanket SetHorizTile(false) here silently undid the tiling for textures
        -- that opt into it (DF.TILED_BAR_TEXTURES). Ask the texture instead.
        DF:ApplyBarTextureTiling(customBar, tex)
        
        if customBar.bg then customBar.bg:Hide() end
        
        local healthFillTexture = frame.healthBar:GetStatusBarTexture()
        if not healthFillTexture then
            customBar:Hide()
            if frame.absorbOverflowBar then frame.absorbOverflowBar:Hide() end
            return
        end
        
        -- Use the calculator API for ATTACHED mode
        local attachedAbsorbs = absorbs
        local isClamped = false
        
        -- Create/reuse the calculator (test data: derive from mock percentages
        -- instead — the calculator can only query the REAL unit, 0 when solo)
        if isTestRender then
            -- Preview values are plain numbers, so the sum the live path defers to the
            -- calculator is done directly. The space left to the shield is the USABLE bar
            -- (reduced max subtracted -- the bar physically ends there) minus current
            -- health minus, when the shield is chained behind it, the incoming heal.
            -- ☠ ONE RULER. When reduced-max CLIPPING is active the health bar is
            -- physically shrunk to the usable width, so every test percentage already
            -- renders on the USABLE ruler -- subtracting the reduced share here as well
            -- double-counts it, and the shield reads "no room" on a bar with visible
            -- missing health (Xx: black + overshield at once; the per-frame forensics
            -- proved it -- same 25% heal, 27px of fill on an unclipped bar, 17px on
            -- Xx's clipped one). Only a non-clipped reduced render, where percentages
            -- still span the full bar and the striped zone merely overlays it, needs
            -- the subtraction.
            -- Honour the Clamp Mode setting, mirroring live: only "Missing Health" (1)
            -- space-clamps. "None" (0) and "Max Health" (2) don't constrain the preview
            -- (test values never exceed max), so the shield may overrun — exactly what
            -- those settings mean on live frames.
            if (db.absorbBarAttachedClampMode or 1) == 1 then
                local reducedShare = ((db.reducedMaxHealthEnabled ~= false)
                    and not frame.dfReducedMaxHealthClipping) and (testReducedPct or 0) or 0
                local usable = maxHealth * (1 - reducedShare)
                local curHealth = testHealthPercent * maxHealth
                local incoming = (DF.ChainEndKey(frame, db) ~= "fill") and (testIncomingPercent or 0) * maxHealth or 0
                local available = usable - curHealth - incoming
                if absorbs > available then
                    attachedAbsorbs = math.max(0, available)
                    isClamped = true
                end
            end
        elseif CreateUnitHealPredictionCalculator and unit then
            if not frame.absorbCalculator then
                frame.absorbCalculator = CreateUnitHealPredictionCalculator()
            end
            local calc = frame.absorbCalculator
            
            -- Clamp mode from settings. ☠ DF's DROPDOWN LABELS ARE NOT BLIZZARD'S ENUM:
            -- the UI says 0=None / 1=Missing Health / 2=Max Health, but the value goes
            -- straight to SetDamageAbsorbClampMode, where Blizzard defines
            -- 0=MissingHealth (incoming heals SUBTRACTED), 1=MissingHealthWithoutIncomingHeals,
            -- 2=MaximumHealth. So the user's "Missing Health" (1) ignores heals -- fine
            -- while the shield started at the health fill, but chained BEHIND the heal it
            -- hands the bar a length that no longer fits and it runs off the end. When the
            -- chain is active, 1 is promoted to 0: the same "Missing Health" intent the
            -- label promises, heals-aware -- and the clamp oUF itself defaults to. The
            -- arithmetic stays inside the calculator, where secret values are legal.
            -- 0 ("None") and 2 ("Max Health") pass through untouched.
            local clampMode = db.absorbBarAttachedClampMode or 1
            if clampMode == 1 and DF.ChainEndKey(frame, db) ~= "fill" then clampMode = 0 end
            -- DF's "None (no clamping)" stores 0 — which in BLIZZARD's enum is
            -- MissingHealth-with-heals, the HARSHEST clamp, the opposite of the label.
            -- The enum has no true "off"; MaximumHealth (2) is the nearest thing (the
            -- bar can never draw past max anyway), so "None" maps there.
            if (db.absorbBarAttachedClampMode or 1) == 0 then clampMode = 2 end
            if calc.SetDamageAbsorbClampMode then calc:SetDamageAbsorbClampMode(clampMode) end

            -- Populate the calculator
            UnitGetDetailedHealPrediction(unit, nil, calc)

            -- Get clamped absorbs and clamped bool
            if calc.GetDamageAbsorbs then
                local result1, result2 = calc:GetDamageAbsorbs()
                if result1 then
                    attachedAbsorbs = result1
                    isClamped = result2  -- This is a secret bool in M+
                end
            end
        end

        local healthOrient = db.healthOrientation or "HORIZONTAL"
        local inset = 0
        if db.frameShowBorder ~= false then
            inset = frame.dfReducedMaxHealthClipping and 0 or (db.frameBorderSize or 1)  -- 0 when clipped: the clip edge is internal, no frame border there
        end
        if db.pixelPerfect and DF.PixelPerfect then inset = DF:PixelPerfect(inset) end
        
        local barWidth = frame.healthBar:GetWidth() - (inset * 2)
        local barHeight = frame.healthBar:GetHeight() - (inset * 2)
        
        -- Use StatusBar API to handle proportional fill - no manual division needed.
        -- Pixel-perfect: pin the CROSS axis to the health fill's two edges so the
        -- shield matches the fill with no sliver/gap. edgeInset insets that axis ONLY
        -- when the frame border is translucent (so the shield doesn't show through it).
        local edgeInset = DF:GetAbsorbEdgeInset(frame, db)
        -- ★ CHAIN: hang off the last visible heal-prediction segment so the shield sits
        -- BESIDE the incoming heal (Blizzard order: health -> heals -> absorb). With no
        -- heal inbound the anchor IS the health fill, so that case is unchanged.
        local chainTex = DF:ResolveAbsorbChainAnchor(frame, db) or healthFillTexture
        if healthOrient == "HORIZONTAL" then
            customBar:SetOrientation("HORIZONTAL")
            customBar:SetReverseFill(false)
            customBar:SetWidth(barWidth)
            customBar:SetPoint("TOPLEFT", chainTex, "TOPRIGHT", 0, -edgeInset)
            customBar:SetPoint("BOTTOMLEFT", chainTex, "BOTTOMRIGHT", 0, edgeInset)
        elseif healthOrient == "HORIZONTAL_INV" then
            customBar:SetOrientation("HORIZONTAL")
            customBar:SetReverseFill(true)
            customBar:SetWidth(barWidth)
            customBar:SetPoint("TOPRIGHT", chainTex, "TOPLEFT", 0, -edgeInset)
            customBar:SetPoint("BOTTOMRIGHT", chainTex, "BOTTOMLEFT", 0, edgeInset)
        elseif healthOrient == "VERTICAL" then
            customBar:SetOrientation("VERTICAL")
            customBar:SetReverseFill(false)
            customBar:SetHeight(barHeight)
            customBar:SetPoint("BOTTOMLEFT", chainTex, "TOPLEFT", edgeInset, 0)
            customBar:SetPoint("BOTTOMRIGHT", chainTex, "TOPRIGHT", -edgeInset, 0)
        elseif healthOrient == "VERTICAL_INV" then
            customBar:SetOrientation("VERTICAL")
            customBar:SetReverseFill(true)
            customBar:SetHeight(barHeight)
            customBar:SetPoint("TOPLEFT", chainTex, "BOTTOMLEFT", edgeInset, 0)
            customBar:SetPoint("TOPRIGHT", chainTex, "BOTTOMRIGHT", -edgeInset, 0)
        end
        
        -- Let WoW's StatusBar handle the percentage calculation internally
        customBar:SetMinMaxValues(0, maxHealth)
        DF.SetBarValue(customBar, attachedAbsorbs, frame)
        
        if customBar.border then customBar.border:Hide() end
        customBar:SetScript("OnUpdate", nil)
        
        -- Create visibility helper for the attached bar if needed
        if not customBar.visibilityHelper then
            customBar.visibilityHelper = customBar:CreateTexture(nil, "BACKGROUND")
            customBar.visibilityHelper:SetSize(1, 1)
            customBar.visibilityHelper:SetColorTexture(0, 0, 0, 0)
        end
        
        -- Handle overflow bar (shown when clamped)
        if not frame.absorbOverflowBar then
            frame.absorbOverflowBar = CreateFrame("StatusBar", nil, frame.healthBar)
            frame.absorbOverflowBar:SetMinMaxValues(0, 1)
            frame.absorbOverflowBar:EnableMouse(false)
        end
        
        -- Ensure overflow bar has visibility helper (may have been created by test mode without it)
        if not frame.absorbOverflowBar.visibilityHelper then
            frame.absorbOverflowBar.visibilityHelper = frame.absorbOverflowBar:CreateTexture(nil, "BACKGROUND")
            frame.absorbOverflowBar.visibilityHelper:SetSize(1, 1)
            frame.absorbOverflowBar.visibilityHelper:SetColorTexture(0, 0, 0, 0)
        end
        
        local overflowBar = frame.absorbOverflowBar

        -- ☠ THE OVERFLOW BAR HAD NO LEVEL OF ITS OWN. Created as a healthBar child and
        -- never levelled, it inherited frame+3 -- the health bar's own level -- while its
        -- sibling (the attached bar) sits at +11. That was invisible for as long as the
        -- dispel wash lived above the whole band, and surfaced the moment the wash
        -- dropped under it for "Show On Current Health Only": the attached absorb came
        -- through and the overflow stripe stayed washed (field-caught, Krathe).
        -- Two halves of ONE readout must share a level; anything else is a coin-flip the
        -- next z-order change re-tosses.
        local overflowVisHelper = overflowBar.visibilityHelper
        local attachedVisHelper = customBar.visibilityHelper

        -- Configure the overflow bar (always, so it's ready when needed)
        overflowBar:ClearAllPoints()
        -- ☠ DERIVED FROM THE ATTACHED BAR, one above it. The two are halves of one
        -- readout, and their ORDER is the contract -- the absolute number is not.
        -- A DF:ResolveAbsorbBarLevel call used to sit ten lines above this one and was
        -- overwritten right here on every pass: dead code that read as a fix, and it
        -- survived an in-game confirmation because what actually fixed that report was
        -- the dispel wash dropping to +4, not this bar moving. Proved by
        -- /df debug zorder -- attached +5, overflow +6, resolver claims +11 (2026-08-13).
        -- ⚠ The comment here used to say "below dispel overlay (+6)". The overlay has
        -- been at +16 since the 2026-08-07 z-order review, so that number was fiction
        -- and it is what justified the hardcoded arithmetic.
        -- ☠ SHARES the attached bar's level rather than sitting one above it. At the
        -- old squashed levels +1 was free; on the real ladder absorb is +11 and +12 is
        -- heal prediction's slot. The two segments are adjacent and never overlap, so
        -- one level is correct and needs no tie-break.
        overflowBar:SetFrameLevel(customBar:GetFrameLevel())
        
        -- Apply same texture/color as main absorb bar
        local texture = db.absorbBarTexture or DF.STOCK_BAR_TEXTURE
        if type(texture) == "table" then
            texture = texture.path or DF.STOCK_BAR_TEXTURE
        end
        -- Same vertical-companion resolution as the main bar. It has to match, or
        -- the two halves of a single shield would use different art.
        texture = DF:ResolveBarTexture(texture, isVerticalFill)
        local overflowApplied = DF:SafeSetStatusBarTexture(overflowBar, texture)

        local color = db.absorbBarColor or {r = 1, g = 1, b = 1, a = 0.7}
        overflowBar:SetStatusBarColor(color.r, color.g, color.b, color.a or 0.7)

        -- Tiling per the texture (off for everything except DF.TILED_BAR_TEXTURES).
        -- The overflow bar must match the main absorb bar or the pattern breaks
        -- across the seam where one hands over to the other.
        DF:ApplyBarTextureTiling(overflowBar, overflowApplied == false and DF.STOCK_BAR_TEXTURE or texture)
        
        -- Position like OVERLAY mode — flush when opaque/off, inset when translucent
        local overflowInset = DF:GetAbsorbEdgeInset(frame, db)
        overflowBar:SetPoint("TOPLEFT", frame.healthBar, "TOPLEFT", overflowInset, -overflowInset)
        overflowBar:SetPoint("BOTTOMRIGHT", frame.healthBar, "BOTTOMRIGHT", -overflowInset, overflowInset)
        overflowBar:SetMinMaxValues(0, maxHealth)
        
        -- Match health bar orientation for overlay
        local overlayReverse = db.absorbBarOverlayReverse or false
        
        if healthOrient == "HORIZONTAL" then
            overflowBar:SetOrientation("HORIZONTAL")
            overflowBar:SetReverseFill(not overlayReverse)
        elseif healthOrient == "HORIZONTAL_INV" then
            overflowBar:SetOrientation("HORIZONTAL")
            overflowBar:SetReverseFill(overlayReverse)
        elseif healthOrient == "VERTICAL" then
            overflowBar:SetOrientation("VERTICAL")
            overflowBar:SetReverseFill(not overlayReverse)
        elseif healthOrient == "VERTICAL_INV" then
            overflowBar:SetOrientation("VERTICAL")
            overflowBar:SetReverseFill(overlayReverse)
        end
        
        -- Set bar value to full absorbs (not clamped)
        DF.SetBarValue(overflowBar, absorbs, frame)
        
        -- Use SetAlphaFromBoolean to toggle between attached and overflow bars
        -- Frame alpha: visAlpha when visible, 0 when hidden (bar texture alpha controlled by SetStatusBarColor)
        -- When clamped: show overflow, hide attached
        -- When not clamped: hide overflow, show attached
        -- Respect OOR fade: use OOR alpha instead of 1 when unit is out of range
        -- dfInRange may be a secret boolean from UnitInRange fallback
        local visAlpha = 1
        if db.oorEnabled then
            local inRange = frame.dfInRange
            if not (issecretvalue and issecretvalue(inRange)) then
                if inRange == false then
                    visAlpha = db.oorAbsorbBarAlpha or 0.5
                end
            end
            -- Secret values: can't compare, leave visAlpha at 1 (OOR handled by frame-level fade)
        end
        overflowVisHelper:Show()
        overflowVisHelper:SetAlphaFromBoolean(isClamped, visAlpha, 0)
        overflowBar:SetAlpha(overflowVisHelper:GetAlpha())
        overflowBar:Show()

        attachedVisHelper:Show()
        attachedVisHelper:SetAlphaFromBoolean(isClamped, 0, visAlpha)  -- Inverse: 0 when clamped, visAlpha when not
        customBar:SetAlpha(attachedVisHelper:GetAlpha())

    -- ============================================================
    -- MODE: OVERLAY
    -- ============================================================
    else
        -- Clear any existing anchors first
        customBar:ClearAllPoints()
        
        -- Set parent to health bar for overlay mode
        customBar:SetParent(frame.healthBar)
        customBar:SetFrameStrata(frame:GetFrameStrata())
        -- ☠ The ladder's absorb slot, resolved once at the top of this function.
        -- Was healthLevel + 2 (frame+5) -- see DF:ResolveHealAbsorbBarLevel.
        customBar:SetFrameLevel(absorbLevel)
        
        if customBar.bg then customBar.bg:Hide() end
        
        -- Cover the health fill: flush when the border is opaque/off, inset by the
        -- (snapped) border size when the border is translucent so the shield doesn't
        -- bleed through the border's edge band.
        local overlayInset = DF:GetAbsorbEdgeInset(frame, db)
        customBar:SetPoint("TOPLEFT", frame.healthBar, "TOPLEFT", overlayInset, -overlayInset)
        customBar:SetPoint("BOTTOMRIGHT", frame.healthBar, "BOTTOMRIGHT", -overlayInset, overlayInset)
        customBar:SetMinMaxValues(0, maxHealth)
        
        -- Match health bar orientation
        local healthOrient = db.healthOrientation or "HORIZONTAL"
        local overlayReverse = db.absorbBarOverlayReverse or false
        
        if healthOrient == "HORIZONTAL" then
            customBar:SetOrientation("HORIZONTAL")
            customBar:SetReverseFill(not overlayReverse)
        elseif healthOrient == "HORIZONTAL_INV" then
            customBar:SetOrientation("HORIZONTAL")
            customBar:SetReverseFill(overlayReverse)
        elseif healthOrient == "VERTICAL" then
            customBar:SetOrientation("VERTICAL")
            customBar:SetReverseFill(not overlayReverse)
        elseif healthOrient == "VERTICAL_INV" then
            customBar:SetOrientation("VERTICAL")
            customBar:SetReverseFill(overlayReverse)
        end
        
        -- Hide any existing border elements
        if customBar.borderLines then
            for i = 1, 4 do
                customBar.borderLines[i]:Hide()
            end
        end
        if customBar.border then
            customBar.border:Hide()
        end
        customBar:SetScript("OnUpdate", nil)

        -- Set bar value
        DF.SetBarValue(customBar, absorbs, frame)
    end

    -- Cache the current layout settings so subsequent calls can
    -- short-circuit via AbsorbLayoutStateChanged. Done at the end of
    -- the full rebuild so the cache reflects the state the bar was
    -- just configured for.
    CacheAbsorbLayoutState(frame, db)
end

-- Re-apply ATTACHED_OVERFLOW absorb visibility on every range tick.
--
-- Why this exists: in ATTACHED_OVERFLOW mode the attached/overflow bar alphas
-- are written by UpdateAbsorb above, which only fires on UNIT_ABSORB events
-- (and friends). Between those events, range transitions don't touch the
-- overflow bar — so OOR fade can stay stuck at the last value UpdateAbsorb
-- gave it (typically full opacity if the user was in range at the previous
-- absorb tick). The range ticker (UpdateAbsorbBarAppearance in
-- Features/ElementAppearance.lua) calls this on every tick to refresh.
--
-- We re-run the visibility helpers with a freshly-computed isClamped (cheap:
-- the calculator object is already cached on the frame) and a freshly-
-- computed visAlpha. We CANNOT cache isClamped as a number and read it back
-- on the next tick to combine with a fresh visAlpha — a number obtained from
-- SetAlphaFromBoolean(secretBool, ...) is itself secret and arithmetic on it
-- taints execution.
function DF:RefreshAbsorbBarVisibility(frame)
    if not frame or not frame.dfAbsorbBar or not frame.absorbOverflowBar then return end
    if not frame.dfAbsorbBar:IsShown() then return end
    if DF.testMode or DF.raidTestMode then return end

    local db
    if frame.isRaidFrame and DF.GetRaidDB then
        db = DF:GetRaidDB()
    elseif DF.GetDB then
        db = DF:GetDB()
    end
    if not db then return end
    if (db.absorbBarMode or "OVERLAY") ~= "ATTACHED_OVERFLOW" then return end

    -- Refresh isClamped via the cached calculator (same call UpdateAbsorb makes).
    -- Mirror UpdateAbsorb's pattern exactly — gating the secret r2 assignment on
    -- truthy r1 — to stay on a known-safe code path with secret return values.
    local isClamped = false
    local unit = frame.unit
    if frame.absorbCalculator and unit and CreateUnitHealPredictionCalculator then
        UnitGetDetailedHealPrediction(unit, nil, frame.absorbCalculator)
        if frame.absorbCalculator.GetDamageAbsorbs then
            local r1, r2 = frame.absorbCalculator:GetDamageAbsorbs()
            if r1 then
                isClamped = r2
            end
        end
    end

    -- visAlpha matches UpdateAbsorb's fast-path logic at the helper-apply step.
    -- The secret-bool branch deliberately leaves visAlpha at 1: the safe path
    -- there is frame-level OOR fade (set by the OOR system upstream); we'd need
    -- a separate cascade to fade individually in element-specific mode for
    -- secret-bool classes, which is a wider change than this fix.
    local visAlpha = 1
    if db.oorEnabled then
        local inRange = frame.dfInRange
        if not (issecretvalue and issecretvalue(inRange)) and inRange == false then
            visAlpha = db.oorAbsorbBarAlpha or 0.5
        end
    end

    -- Apply via the existing visibility helpers (created lazily by UpdateAbsorb's
    -- full-rebuild path; if absent, this frame hasn't been laid out yet — skip).
    local attachedHelper = frame.dfAbsorbBar.visibilityHelper
    local overflowHelper = frame.absorbOverflowBar.visibilityHelper
    if attachedHelper then
        attachedHelper:SetAlphaFromBoolean(isClamped, 0, visAlpha)
        frame.dfAbsorbBar:SetAlpha(attachedHelper:GetAlpha())
    end
    if overflowHelper then
        overflowHelper:SetAlphaFromBoolean(isClamped, visAlpha, 0)
        frame.absorbOverflowBar:SetAlpha(overflowHelper:GetAlpha())
    end
end

-- ============================================================
-- HEAL ABSORB BAR LOGIC (Necrotic, etc.)
-- ============================================================
-- NOTE: In WoW Midnight (12.0), UnitGetTotalHealAbsorbs() returns a
-- "secret value" that cannot be compared with ANY Lua operators.
-- We must pass it directly to SetValue() without any checks.
-- The StatusBar will show 0 width if the value is 0, effectively hiding it.
-- ============================================================

function DF:UpdateHealAbsorb(frame, testIndex)
    if not frame then return end
    if not frame.healthBar then return end
    -- Test frames only accept test data — see testFrameNeedsData above UpdateAbsorb.
    if (DF.testMode or DF.raidTestMode) and testIndex == nil and frame.dfIsTestFrame then return end
    
    local unit = frame.unit
    local db = DF:GetFrameDB(frame)
    local mode = db.healAbsorbBarMode or "OVERLAY"
    
    -- Get values - either from test data or real unit
    local maxHealth, healAbsorb
    
    if DF.testMode and testIndex ~= nil then
        -- testIndex may be a numeric index or a ready testData TABLE (the
        -- TestMode render/animation loop passes its per-tick data directly)
        local testData = type(testIndex) == "table" and testIndex or DF:GetTestUnitData(testIndex)
        if testData then
            maxHealth = testData.maxHealth
            healAbsorb = testData.healAbsorbPercent * maxHealth
        else
            maxHealth = 100000
            healAbsorb = 0
        end
    elseif DF.raidTestMode and testIndex ~= nil then
        local testData = type(testIndex) == "table" and testIndex or DF:GetTestUnitData(testIndex, true)  -- true = raid
        if testData then
            maxHealth = testData.maxHealth
            healAbsorb = testData.healAbsorbPercent * maxHealth
        else
            maxHealth = 100000
            healAbsorb = 0
        end
    else
        -- Only process player, party, and raid units for real data
        if not unit or (unit ~= "player" and not unit:match("^party%d$") and not unit:match("^raid%d+$")) then
            return
        end
        
        -- Ensure unit exists before querying
        if not UnitExists(unit) then
            if frame.dfHealAbsorbBar then frame.dfHealAbsorbBar:Hide() end
            return
        end
        
        -- Get values - StatusBar API handles secret values internally via SetMinMaxValues
        maxHealth = UnitHealthMax(unit)
        healAbsorb = UnitGetTotalHealAbsorbs(unit)
    end
    
    -- Always hide Blizzard elements since we use custom bars
    if frame.myHealAbsorb then frame.myHealAbsorb:Hide() end
    if frame.myHealAbsorbLeftShadow then frame.myHealAbsorbLeftShadow:Hide() end
    if frame.myHealAbsorbRightShadow then frame.myHealAbsorbRightShadow:Hide() end
    if frame.myHealAbsorbOverlay then frame.myHealAbsorbOverlay:Hide() end
    
    -- Create custom bar if needed
    if not frame.dfHealAbsorbBar then
        frame.dfHealAbsorbBar = CreateFrame("StatusBar", nil, frame)
        frame.dfHealAbsorbBar:SetMinMaxValues(0, 1)
        frame.dfHealAbsorbBar:EnableMouse(false)
        
        -- Background for floating mode
        local bg = frame.dfHealAbsorbBar:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(true)
        bg:SetColorTexture(0, 0, 0, 0.5)
        frame.dfHealAbsorbBar.bg = bg
    end
    
    local bar = frame.dfHealAbsorbBar
    local healthLevel = frame.healthBar:GetFrameLevel()
    local healAbsorbLevel = DF:ResolveHealAbsorbBarLevel(frame, db) or (healthLevel + 5)
    
    bar:SetParent(frame)
    bar:SetFrameStrata(frame:GetFrameStrata())
    bar:SetFrameLevel(healAbsorbLevel)
    
    -- Texture and color
    local tex = ResolveBarTextureForFill(db, db.healAbsorbBarTexture or DF.STOCK_BAR_TEXTURE,
        mode, "healAbsorbBarOrientation")
    local col = db.healAbsorbBarColor or {r = 0.4, g = 0.1, b = 0.1, a = 0.7}
    local blendMode = db.healAbsorbBarBlendMode or "BLEND"
    
    -- Apply texture only if changed to prevent flickering
    if bar.currentTexture ~= tex then
        bar.currentTexture = tex
        -- Tiling and texcoords are set by SafeSetStatusBarTexture from the
        -- texture's own mode; only the bits it can't know are set here.
        DF:SafeSetStatusBarTexture(bar, tex)
        local barTex = bar:GetStatusBarTexture()
        if barTex then
            barTex:SetDesaturated(false)
            barTex:SetDrawLayer("ARTWORK", 1)
        end
    end
    
    -- Always apply blend mode (may have changed without texture change)
    local barTex = bar:GetStatusBarTexture()
    if barTex then
        barTex:SetBlendMode(blendMode)
    end
    
    bar:SetStatusBarColor(col.r, col.g, col.b, col.a or 0.7)
    
    bar:ClearAllPoints()
    
    -- ============================================================
    -- MODE: FLOATING
    -- ============================================================
    if mode == "FLOATING" then
        bar:SetParent(frame)
        bar:SetFrameLevel(healAbsorbLevel)
        
        if bar.bg then
            bar.bg:Show()
            local bgC = db.healAbsorbBarBackgroundColor or {r = 0, g = 0, b = 0, a = 0.5}
            bar.bg:SetColorTexture(bgC.r, bgC.g, bgC.b, bgC.a)
        end
        
        -- Hide any existing border elements
        if bar.border then bar.border:Hide() end
        bar:SetScript("OnUpdate", nil)
        
        -- Dimensions & Orientation
        local orientation = db.healAbsorbBarOrientation or "HORIZONTAL"
        bar:SetOrientation(orientation)
        bar:SetReverseFill(db.healAbsorbBarReverse or false)
        
        local w = db.healAbsorbBarWidth or 50
        local h = db.healAbsorbBarHeight or 6
        
        -- Apply pixel-perfect adjustments
        if db.pixelPerfect then
            w = DF:PixelPerfect(w)
            h = DF:PixelPerfect(h)
        end
        
        if orientation == "VERTICAL" then
            bar:SetWidth(h)
            bar:SetHeight(w)
        else
            bar:SetWidth(w)
            bar:SetHeight(h)
        end
        
        local anchor = db.healAbsorbBarAnchor or "CENTER"
        local x = db.healAbsorbBarX or 0
        local y = db.healAbsorbBarY or 0
        bar:SetPoint(anchor, frame, anchor, x, y)
        
    -- ============================================================
    -- MODE: ATTACHED (anchors to health bar fill texture)
    -- Extends inward toward 0 health, clamps at current health
    -- ============================================================
    elseif mode == "ATTACHED" then
        bar:ClearAllPoints()
        bar:SetParent(frame.healthBar)
        -- ☠ The resolved slot, not healthLevel + 3 -- see DF:ResolveHealAbsorbBarLevel.
        bar:SetFrameLevel(healAbsorbLevel)
        
        -- Re-assert the texture's own tiling. This used to force it OFF outright
        -- "to prevent dense repeating in narrow bars", which is still the default
        -- for every stretched texture — but it runs after the texture is applied,
        -- so a blanket clear here silently undid tiling for the textures that opt
        -- into it. Ask the texture instead.
        DF:ApplyBarTextureTiling(bar, bar.dfAppliedTexture)
        
        if bar.bg then bar.bg:Hide() end
        
        local healthFillTexture = frame.healthBar:GetStatusBarTexture()
        if not healthFillTexture then
            bar:Hide()
            return
        end
        
        -- Use the calculator API for ATTACHED mode
        local attachedHealAbsorb = healAbsorb
        
        if CreateUnitHealPredictionCalculator and unit then
            if not frame.healAbsorbCalculator then
                frame.healAbsorbCalculator = CreateUnitHealPredictionCalculator()
            end
            local calc = frame.healAbsorbCalculator
            
            -- Set clamp mode: 0 = CurrentHealth (don't go past 0 health)
            if calc.SetHealAbsorbClampMode then calc:SetHealAbsorbClampMode(0) end
            -- Set heal absorb mode: 1 = Total (return raw absorb values without
            -- subtracting incoming heals). Default mode 0 reduces heal absorbs by
            -- incoming heal amount, causing the bar to show less than actual absorb.
            if calc.SetHealAbsorbMode then calc:SetHealAbsorbMode(1) end
            
            -- Populate the calculator
            UnitGetDetailedHealPrediction(unit, nil, calc)
            
            -- Get clamped heal absorbs
            if calc.GetHealAbsorbs then
                local result = calc:GetHealAbsorbs()
                if result then
                    attachedHealAbsorb = result
                end
            end
        end
        
        -- Hide any existing overshield glow (not used for heal absorbs)
        if frame.healAbsorbOvershieldGlow then
            frame.healAbsorbOvershieldGlow:Hide()
        end
        
        local healthOrient = db.healthOrientation or "HORIZONTAL"
        local inset = 0
        if db.frameShowBorder ~= false then
            inset = frame.dfReducedMaxHealthClipping and 0 or (db.frameBorderSize or 1)  -- 0 when clipped: the clip edge is internal, no frame border there
        end
        if db.pixelPerfect and DF.PixelPerfect then inset = DF:PixelPerfect(inset) end
        
        local barWidth = frame.healthBar:GetWidth() - (inset * 2)
        local barHeight = frame.healthBar:GetHeight() - (inset * 2)
        
        -- Use StatusBar API to handle proportional fill - no manual division needed.
        -- Position: anchor to health fill edge, extend INWARD toward 0 health.
        -- Pixel-perfect: pin the CROSS axis to the health fill's two edges so it
        -- matches the fill with no sliver/gap. edgeInset insets that axis ONLY when
        -- the frame border is translucent (so the shield doesn't show through it).
        local edgeInset = DF:GetAbsorbEdgeInset(frame, db)
        if healthOrient == "HORIZONTAL" then
            bar:SetOrientation("HORIZONTAL")
            bar:SetReverseFill(true)  -- Fill toward 0 (left)
            bar:SetWidth(barWidth)
            bar:SetPoint("TOPRIGHT", healthFillTexture, "TOPRIGHT", 0, -edgeInset)
            bar:SetPoint("BOTTOMRIGHT", healthFillTexture, "BOTTOMRIGHT", 0, edgeInset)
        elseif healthOrient == "HORIZONTAL_INV" then
            bar:SetOrientation("HORIZONTAL")
            bar:SetReverseFill(false)  -- Fill toward 0 (right)
            bar:SetWidth(barWidth)
            bar:SetPoint("TOPLEFT", healthFillTexture, "TOPLEFT", 0, -edgeInset)
            bar:SetPoint("BOTTOMLEFT", healthFillTexture, "BOTTOMLEFT", 0, edgeInset)
        elseif healthOrient == "VERTICAL" then
            bar:SetOrientation("VERTICAL")
            bar:SetReverseFill(true)  -- Fill toward 0 (down)
            bar:SetHeight(barHeight)
            bar:SetPoint("TOPLEFT", healthFillTexture, "TOPLEFT", edgeInset, 0)
            bar:SetPoint("TOPRIGHT", healthFillTexture, "TOPRIGHT", -edgeInset, 0)
        elseif healthOrient == "VERTICAL_INV" then
            bar:SetOrientation("VERTICAL")
            bar:SetReverseFill(false)  -- Fill toward 0 (up)
            bar:SetHeight(barHeight)
            bar:SetPoint("BOTTOMLEFT", healthFillTexture, "BOTTOMLEFT", edgeInset, 0)
            bar:SetPoint("BOTTOMRIGHT", healthFillTexture, "BOTTOMRIGHT", -edgeInset, 0)
        end
        
        -- Let WoW's StatusBar handle the percentage calculation internally
        bar:SetMinMaxValues(0, maxHealth)
        DF.SetBarValue(bar, attachedHealAbsorb, frame)
        
        if bar.border then bar.border:Hide() end
        bar:SetScript("OnUpdate", nil)
        bar:Show()
        return
        
    -- ============================================================
    -- MODE: OVERLAY
    -- ============================================================
    else
        bar:SetParent(frame.healthBar)
        -- ☠ The resolved slot, not healthLevel + 2 -- see DF:ResolveHealAbsorbBarLevel.
        bar:SetFrameLevel(healAbsorbLevel)
        
        if bar.bg then bar.bg:Hide() end
        
        -- Cover the health fill: flush when the border is opaque/off, inset when the
        -- border is translucent so the shield doesn't bleed through the border edge.
        local overlayInset = DF:GetAbsorbEdgeInset(frame, db)
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", frame.healthBar, "TOPLEFT", overlayInset, -overlayInset)
        bar:SetPoint("BOTTOMRIGHT", frame.healthBar, "BOTTOMRIGHT", -overlayInset, overlayInset)
        
        -- Match health bar orientation
        -- Heal absorbs fill from low HP side (opposite of regular absorbs)
        local healthOrient = db.healthOrientation or "HORIZONTAL"
        local overlayReverse = db.healAbsorbBarOverlayReverse or false
        
        if healthOrient == "HORIZONTAL" then
            bar:SetOrientation("HORIZONTAL")
            bar:SetReverseFill(overlayReverse)
        elseif healthOrient == "HORIZONTAL_INV" then
            bar:SetOrientation("HORIZONTAL")
            bar:SetReverseFill(not overlayReverse)
        elseif healthOrient == "VERTICAL" then
            bar:SetOrientation("VERTICAL")
            bar:SetReverseFill(overlayReverse)
        elseif healthOrient == "VERTICAL_INV" then
            bar:SetOrientation("VERTICAL")
            bar:SetReverseFill(not overlayReverse)
        end
        
        -- Hide any existing border elements
        if bar.borderLines then
            for i = 1, 4 do
                bar.borderLines[i]:Hide()
            end
        end
        if bar.border then
            bar.border:Hide()
        end
        bar:SetScript("OnUpdate", nil)
    end
    
    -- CRITICAL: Set min/max BEFORE SetValue, and always show the bar
    -- The bar will render with 0 width if healAbsorb is 0
    bar:SetMinMaxValues(0, maxHealth)
    DF.SetBarValue(bar, healAbsorb, frame)
    bar:Show()
end

-- ============================================================
-- HEAL PREDICTION BAR
-- Uses the new UnitHealPredictionCalculator API (11.1+)
-- IMPORTANT: All health/heal values may be secret in M+, so we CANNOT do
-- any arithmetic on them. We anchor to the health bar fill texture and
-- pass values directly to StatusBar:SetValue().
--
-- SPLIT mode ("Attached to Health" only) draws two chained segments — your
-- heals then everyone else's — by anchoring the second segment's leading edge
-- to the first segment's fill-texture trailing edge. Same secret-safe trick as
-- the single bar (no arithmetic; the StatusBar fills itself from SetValue).
-- ============================================================

-- Anchor a segment's leading edge to the trailing edge of a previous fill
-- texture (the health fill, or the prior segment), per health orientation.
local function AnchorHealPredSegment(seg, prevTex, orient, w, h)
    seg:ClearAllPoints()
    if orient == "HORIZONTAL_INV" then
        seg:SetOrientation("HORIZONTAL"); seg:SetReverseFill(true); seg:SetWidth(w)
        seg:SetPoint("TOPRIGHT", prevTex, "TOPLEFT", 0, 0)
        seg:SetPoint("BOTTOMRIGHT", prevTex, "BOTTOMLEFT", 0, 0)
    elseif orient == "VERTICAL" then
        seg:SetOrientation("VERTICAL"); seg:SetReverseFill(false); seg:SetHeight(h)
        seg:SetPoint("BOTTOMLEFT", prevTex, "TOPLEFT", 0, 0)
        seg:SetPoint("BOTTOMRIGHT", prevTex, "TOPRIGHT", 0, 0)
    elseif orient == "VERTICAL_INV" then
        seg:SetOrientation("VERTICAL"); seg:SetReverseFill(true); seg:SetHeight(h)
        seg:SetPoint("TOPLEFT", prevTex, "BOTTOMLEFT", 0, 0)
        seg:SetPoint("TOPRIGHT", prevTex, "BOTTOMRIGHT", 0, 0)
    else  -- HORIZONTAL (default)
        seg:SetOrientation("HORIZONTAL"); seg:SetReverseFill(false); seg:SetWidth(w)
        seg:SetPoint("TOPLEFT", prevTex, "TOPRIGHT", 0, 0)
        seg:SetPoint("BOTTOMLEFT", prevTex, "BOTTOMRIGHT", 0, 0)
    end
end

-- Get/create the second heal-prediction segment ("others' heals" in SPLIT mode).
local function GetOrCreateHealPredSegment2(frame)
    if not frame.dfHealPredictionBar2 then
        local seg = CreateFrame("StatusBar", nil, frame)
        seg:SetMinMaxValues(0, 1)
        seg:EnableMouse(false)
        frame.dfHealPredictionBar2 = seg
    end
    return frame.dfHealPredictionBar2
end

-- Style a segment to match the primary bar (texture, blend, draw layer, colour).
local function StyleHealPredSegment(seg, tex, blendMode, color)
    if seg.currentTexture ~= tex then
        seg.currentTexture = tex
        DF:SafeSetStatusBarTexture(seg, tex)   -- also sets tiling + texcoords
        local t = seg:GetStatusBarTexture()
        if t then t:SetDrawLayer("ARTWORK", 1) end
    end
    local t = seg:GetStatusBarTexture()
    if t then t:SetBlendMode(blendMode) end
    seg:SetStatusBarColor(color.r, color.g, color.b, color.a or 0.7)
end

function DF:UpdateHealPrediction(frame, testIndex)
    if not frame or not frame.healthBar then return end
    -- Test frames only accept test data — see testFrameNeedsData above UpdateAbsorb.
    if (DF.testMode or DF.raidTestMode) and testIndex == nil and frame.dfIsTestFrame then return end
    
    -- MEMORY TEST: Skip if disabled (but allow test mode to still work)
    if DF:MemTestDisabled("enableHealPrediction") and not DF.testMode and not DF.raidTestMode then
        if frame.dfHealPredictionBar then frame.dfHealPredictionBar:Hide() end
        return
    end
    
    local unit = frame.unit
    local db = DF:GetFrameDB(frame)
    
    -- Check if heal prediction is enabled
    if not db.healPredictionEnabled then
        if frame.dfHealPredictionBar then
            frame.dfHealPredictionBar:Hide()
        end
        if frame.dfHealPredictionBar2 then
            frame.dfHealPredictionBar2:Hide()
        end
        return
    end
    
    local mode = db.healPredictionMode or "OVERLAY"
    local showMode = db.healPredictionShowMode or "ALL"
    -- SPLIT draws my heals + others' heals as two chained segments, in both
    -- Attached-to-Health (overlay) and Floating display modes.
    local isSplit = (showMode == "SPLIT")

    -- Get values - either from test data or real unit
    local maxHealth, incomingHeals
    local myHeals, othersHeals          -- Per-source breakdown (SPLIT mode)
    -- ⚠ There is deliberately NO isTestMode flag any more. It existed only to pick
    -- a different render path, and every one of those forks was a bug waiting to
    -- happen. If you find yourself wanting it back, the answer is almost certainly
    -- to feed the shared path a different NUMBER instead.

    -- ★★ THE PREVIEW SUPPLIES AMOUNTS, NEVER GEOMETRY. Everything below this block
    -- is shared with live: same anchors, same StatusBar values, same clamp.
    --
    -- ☠ IT USED TO FORK AT THE RENDER, and that is what this replaced. The overlay
    -- had a whole parallel geometry branch computing widths from
    -- healthBar:GetWidth() minus the border inset -- which is NOT the basis the
    -- health FILL uses (the fill spans the bar's full width). The two therefore
    -- disagreed by inset * (1 - 2 * health): a hidden overlap at a static health,
    -- and a visible gap between health and prediction the moment Animate Health
    -- swung it the other way (Krathe, 2026-08-07). The clamp added hours earlier had
    -- gone into that same duplicated geometry rather than onto the amount, where
    -- live's calculator puts it -- the fourth divergence of this shape in two days.
    --
    -- ★ Nothing in live's path is secret-bound here, so there is no reason to fork:
    -- test values are plain numbers, and a StatusBar fed a plain value behaves the
    -- same as one fed a secret. Standing rule -- test follows live wherever it can.
    local function applyTestHeals(testData)
        maxHealth = (testData and testData.maxHealth) or 100000
        local healthPct = (testData and testData.healthPercent) or 0.75
        local healPct = (testData and testData.healPredictionPercent) or 0
        local total = healPct * maxHealth   -- safe: nothing is secret in test
        -- Mirrors SetIncomingHealClampMode. With overheal off the calculator would
        -- never report more than the missing health, so neither may the preview;
        -- with it on the overhang is the point and the bar is parented to the frame
        -- rather than the health bar so it can spill.
        if not db.healPredictionShowOverheal then
            total = math.min(total, math.max(0, maxHealth - healthPct * maxHealth))
        end
        -- The breakdown live gets from the calculator. An even split is the only
        -- honest preview: there is no real healer to attribute to.
        myHeals, othersHeals = total * 0.5, total * 0.5
        frame.dfTotalHeals, frame.dfMyHeals, frame.dfOthersHeals = total, myHeals, othersHeals
        if showMode == "MINE" or showMode == "SPLIT" then
            incomingHeals = myHeals
        elseif showMode == "OTHERS" then
            incomingHeals = othersHeals
        else
            incomingHeals = total
        end
    end

    if DF.testMode and testIndex ~= nil then
        -- testIndex may be a numeric index or a ready testData TABLE (the
        -- TestMode render/animation loop passes its per-tick data directly)
        applyTestHeals(type(testIndex) == "table" and testIndex or DF:GetTestUnitData(testIndex))
    elseif DF.raidTestMode and testIndex ~= nil then
        applyTestHeals(type(testIndex) == "table" and testIndex or DF:GetTestUnitData(testIndex, true))
    else
        -- Only process valid units for real data
        if not unit or (unit ~= "player" and not unit:match("^party%d$") and not unit:match("^raid%d+$")) then
            return
        end
        
        -- Ensure unit exists before querying
        if not UnitExists(unit) then
            if frame.dfHealPredictionBar then frame.dfHealPredictionBar:Hide() end
            if frame.dfHealPredictionBar2 then frame.dfHealPredictionBar2:Hide() end
            return
        end
        
        -- Get maxHealth - StatusBar API handles secret values internally via SetMinMaxValues
        maxHealth = UnitHealthMax(unit)
        
        -- Use the new Heal Prediction Calculator API (11.1+) if available
        -- This supports clamp modes and overflow percent
        if CreateUnitHealPredictionCalculator then
            if not frame.healPredictionCalculator then
                frame.healPredictionCalculator = CreateUnitHealPredictionCalculator()
            end
            
            local calc = frame.healPredictionCalculator
            
            -- Configure the calculator based on settings
            -- Overflow always at 100% (1.0)
            -- Show Overheal checked = clamp to Missing Health (1)
            -- Show Overheal unchecked = clamp to Max Health (0)
            local clampMode = db.healPredictionShowOverheal and 1 or 0
            
            calc:SetIncomingHealClampMode(clampMode)
            calc:SetIncomingHealOverflowPercent(1.0)  -- Always 100%
            
            -- SPLIT needs the per-source breakdown, so query with the player as
            -- the healer for MINE/OTHERS/SPLIT.
            local healerUnit = nil
            if showMode == "MINE" or showMode == "OTHERS" or showMode == "SPLIT" then
                healerUnit = "player"
            end

            UnitGetDetailedHealPrediction(unit, healerUnit, calc)

            local amount, amountFromHealer, amountFromOthers, clamped = calc:GetIncomingHeals()
            myHeals, othersHeals = amountFromHealer, amountFromOthers

            -- TD stash: expose the heal breakdown so the TextDesigner LiveSource
            -- reads it without a second calculator pass. dfTotalHeals is the
            -- ALL-incoming total (not the showMode-filtered value), so the
            -- incoming_heal text is correct regardless of the bar's mode.
            --
            -- ⚠ Only dfTotalHeals and dfMyHeals have a reader today
            -- (TextDesigner/DataSource.lua). dfOthersHeals is written for the
            -- symmetry of the trio and is currently unconsumed -- one assignment, so
            -- it stays, but do not read this block as evidence that an
            -- others-heals text token exists.
            frame.dfTotalHeals = amount
            frame.dfMyHeals = amountFromHealer
            frame.dfOthersHeals = amountFromOthers

            if showMode == "MINE" then
                incomingHeals = amountFromHealer
            elseif showMode == "OTHERS" then
                incomingHeals = amountFromOthers
            elseif showMode == "SPLIT" then
                -- Primary segment = my heals; others are drawn as the second segment.
                incomingHeals = amountFromHealer
            else
                incomingHeals = amount
            end
        else
            -- Fallback to simple API if calculator not available (no breakdown,
            -- so SPLIT degrades to a single combined bar).
            if showMode == "MINE" then
                incomingHeals = UnitGetIncomingHeals(unit, "player")
            else
                incomingHeals = UnitGetIncomingHeals(unit)
            end
        end
        
        -- If nil, hide the bar and return
        if not incomingHeals then
            if frame.dfHealPredictionBar then
                frame.dfHealPredictionBar:Hide()
            end
            return
        end
    end
    
    -- Get color based on show mode. The primary bar uses My colour when split;
    -- the second segment (bar2) uses Others colour. Floating split shows the
    -- combined total, so it uses the All colour.
    local color
    local othersColor = db.healPredictionOthersColor or {r = 0.0, g = 0.5, b = 0.8, a = 0.7}
    if showMode == "MINE" or isSplit then
        color = db.healPredictionMyColor or {r = 0.0, g = 0.8, b = 0.2, a = 0.7}
    elseif showMode == "OTHERS" then
        color = othersColor
    else
        color = db.healPredictionAllColor or {r = 0.0, g = 0.7, b = 0.4, a = 0.7}
    end
    
    -- Create heal prediction bar if needed
    if not frame.dfHealPredictionBar then
        frame.dfHealPredictionBar = CreateFrame("StatusBar", nil, frame)
        frame.dfHealPredictionBar:SetMinMaxValues(0, 1)
        frame.dfHealPredictionBar:EnableMouse(false)
        
        -- Background for floating mode
        local bg = frame.dfHealPredictionBar:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(true)
        bg:SetColorTexture(0, 0, 0, 0.5)
        frame.dfHealPredictionBar.bg = bg
    end
    
    local bar = frame.dfHealPredictionBar

    -- Hide the second segment unless we're actively rendering a split overlay.
    if not isSplit and frame.dfHealPredictionBar2 then
        frame.dfHealPredictionBar2:Hide()
    end

    -- Level: just below the resource bar (which sits at health +2).
    -- ☠ Was three branches on a `healPredictionStrata` key with NO UI and no writer, so the
    -- stored value was always the "SANDWICH" default. Two of the three branches produced
    -- the SAME +1 anyway, and the third (+14) was unreachable. Collapsed; nothing moved.
    local healthLevel = frame.healthBar:GetFrameLevel()
    -- ☠ The ladder's slot (healPredictionFrameLevel, default 10), not healthLevel + 1.
    -- The FLOATING branch below already read the key; every other branch used +1, so the
    -- same bar sat eight levels apart depending only on mode.
    local predictionLevel = DF:ResolveHealPredictionBarLevel(frame, db) or (healthLevel + 1)

    -- Texture and color
    local tex = ResolveBarTextureForFill(db, db.healPredictionTexture or DF.STOCK_BAR_TEXTURE,
        mode, "healPredictionOrientation")
    local blendMode = db.healPredictionBlendMode or "BLEND"
    
    -- Apply texture
    if bar.currentTexture ~= tex then
        bar.currentTexture = tex
        DF:SafeSetStatusBarTexture(bar, tex)   -- also sets tiling + texcoords
        local barTex = bar:GetStatusBarTexture()
        if barTex then
            barTex:SetDrawLayer("ARTWORK", 1)
        end
    end
    
    local barTex = bar:GetStatusBarTexture()
    if barTex then
        barTex:SetBlendMode(blendMode)
    end
    
    bar:SetStatusBarColor(color.r, color.g, color.b, color.a or 0.7)
    bar:ClearAllPoints()
    
    -- ============================================================
    -- MODE: FLOATING
    -- ============================================================
    if mode == "FLOATING" then
        bar:SetParent(frame)
        
        -- Follows the frame's own strata. (The removed healPredictionStrata key defaulted to
        -- SANDWICH, which selected exactly this branch; the other one was unreachable.)
        bar:SetFrameStrata(frame:GetFrameStrata())

        bar:SetFrameLevel(frame:GetFrameLevel() + (db.healPredictionFrameLevel or 10))
        
        -- Dimensions & Orientation
        local orientation = db.healPredictionOrientation or "HORIZONTAL"
        bar:SetOrientation(orientation)
        bar:SetReverseFill(db.healPredictionReverse or false)
        
        local w = db.healPredictionWidth or 50
        local h = db.healPredictionHeight or 6
        
        if db.pixelPerfect then
            w = DF:PixelPerfect(w)
            h = DF:PixelPerfect(h)
        end
        
        if orientation == "VERTICAL" then
            bar:SetWidth(h)
            bar:SetHeight(w)
        else
            bar:SetWidth(w)
            bar:SetHeight(h)
        end
        
        local anchor = db.healPredictionAnchor or "CENTER"
        local x = db.healPredictionX or 0
        local y = db.healPredictionY or 0
        bar:SetPoint(anchor, frame, anchor, x, y)
        
        bar:SetMinMaxValues(0, maxHealth)
        
        if bar.bg then
            bar.bg:Show()
            local bgC = db.healPredictionBackgroundColor or {r = 0, g = 0, b = 0, a = 0.5}
            bar.bg:SetColorTexture(bgC.r, bgC.g, bgC.b, bgC.a)
        end

        -- Use secret-aware SetBarValue. SPLIT already halved incomingHeals upstream
        -- (live via the calculator's per-healer breakdown, preview via
        -- applyTestHeals), so there is nothing test-specific left to do here.
        DF.SetBarValue(bar, incomingHeals, frame)
        bar:Show()

        -- SPLIT: others' segment, chained after the primary within the floating bar.
        if isSplit and othersHeals then
            local seg2 = GetOrCreateHealPredSegment2(frame)
            StyleHealPredSegment(seg2, tex, blendMode, othersColor)
            seg2:SetParent(frame)
            seg2:SetFrameStrata(bar:GetFrameStrata())
            seg2:SetFrameLevel(bar:GetFrameLevel() + 1)
            if seg2.bg then seg2.bg:Hide() end
            -- Map floating orientation + reverse fill to the segment anchor side.
            local segOrient
            if orientation == "VERTICAL" then
                segOrient = db.healPredictionReverse and "VERTICAL_INV" or "VERTICAL"
            else
                segOrient = db.healPredictionReverse and "HORIZONTAL_INV" or "HORIZONTAL"
            end
            -- w is the bar's length in both orientations; AnchorHealPredSegment uses
            -- whichever (width for horizontal, height for vertical).
            AnchorHealPredSegment(seg2, bar:GetStatusBarTexture(), segOrient, w, w)
            seg2:SetMinMaxValues(0, maxHealth)
            DF.SetBarValue(seg2, othersHeals, frame)
            seg2:Show()
        elseif frame.dfHealPredictionBar2 then
            frame.dfHealPredictionBar2:Hide()
        end

    -- ============================================================
    -- MODE: OVERLAY (anchors to health bar fill texture)
    -- No arithmetic on secret values - anchor and let StatusBar handle it
    -- ============================================================
    else
        -- Parent to frame (not healthBar) to avoid clipping when showing overheal
        bar:SetParent(frame)
        bar:SetFrameStrata(frame:GetFrameStrata())
        bar:SetFrameLevel(predictionLevel)
        
        if bar.bg then bar.bg:Hide() end
        
        -- Get the health bar's fill texture - we'll anchor relative to it
        local healthFillTexture = frame.healthBar:GetStatusBarTexture()
        if not healthFillTexture then
            bar:Hide()
            return
        end
        
        local healthOrient = db.healthOrientation or "HORIZONTAL"
        local inset = 0
        if db.frameShowBorder ~= false then
            inset = frame.dfReducedMaxHealthClipping and 0 or (db.frameBorderSize or 1)  -- 0 when clipped: the clip edge is internal, no frame border there
        end
        if db.pixelPerfect and DF.PixelPerfect then inset = DF:PixelPerfect(inset) end
        
        -- ★ ONE PATH, TEST AND LIVE. Anchoring to the health FILL TEXTURE is what
        -- makes the prediction start exactly where health ends, at any health value
        -- and in any orientation, without knowing the value at all. The preview used
        -- to compute the same position from healthBar:GetWidth() minus the border
        -- inset -- a different basis to the one the fill actually uses -- and the two
        -- drifted apart by inset * (1 - 2 * health): overlap below half health, a
        -- visible gap above it. See the note on the test-data block above.
        local barWidth = frame.healthBar:GetWidth() - (inset * 2)
        local barHeight = frame.healthBar:GetHeight() - (inset * 2)

        -- (Heal-absorb netting was here and was reverted — see the tombstone above
        -- ChainEndKey. The prediction starts at the health fill edge, always.)
        if healthOrient == "HORIZONTAL" then
            bar:SetOrientation("HORIZONTAL")
            bar:SetReverseFill(false)
            bar:SetWidth(barWidth)
            -- Use two-point anchoring to match health fill texture height exactly
            bar:SetPoint("TOPLEFT", healthFillTexture, "TOPRIGHT", 0, 0)
            bar:SetPoint("BOTTOMLEFT", healthFillTexture, "BOTTOMRIGHT", 0, 0)
        elseif healthOrient == "HORIZONTAL_INV" then
            bar:SetOrientation("HORIZONTAL")
            bar:SetReverseFill(true)
            bar:SetWidth(barWidth)
            bar:SetPoint("TOPRIGHT", healthFillTexture, "TOPLEFT", 0, 0)
            bar:SetPoint("BOTTOMRIGHT", healthFillTexture, "BOTTOMLEFT", 0, 0)
        elseif healthOrient == "VERTICAL" then
            bar:SetOrientation("VERTICAL")
            bar:SetReverseFill(false)
            bar:SetHeight(barHeight)
            bar:SetPoint("BOTTOMLEFT", healthFillTexture, "TOPLEFT", 0, 0)
            bar:SetPoint("BOTTOMRIGHT", healthFillTexture, "TOPRIGHT", 0, 0)
        elseif healthOrient == "VERTICAL_INV" then
            bar:SetOrientation("VERTICAL")
            bar:SetReverseFill(true)
            bar:SetHeight(barHeight)
            bar:SetPoint("TOPLEFT", healthFillTexture, "BOTTOMLEFT", 0, 0)
            bar:SetPoint("TOPRIGHT", healthFillTexture, "BOTTOMRIGHT", 0, 0)
        end

        -- Let WoW's StatusBar handle the percentage calculation internally
        bar:SetMinMaxValues(0, maxHealth)
        DF.SetBarValue(bar, incomingHeals, frame)

        bar:Show()

        -- ============================================================
        -- SPLIT: second segment ("others' heals"), chained after the
        -- primary (my) segment by anchoring to its fill-texture edge.
        -- Secret-safe: no arithmetic, the StatusBar fills from SetValue.
        -- ============================================================
        -- othersHeals is only available from the calculator path; if absent
        -- (no calculator), there's no breakdown to draw a second segment from.
        if isSplit and othersHeals then
            local seg2 = GetOrCreateHealPredSegment2(frame)
            StyleHealPredSegment(seg2, tex, blendMode, othersColor)
            seg2:SetParent(frame)
            seg2:SetFrameStrata(frame:GetFrameStrata())
            seg2:SetFrameLevel(predictionLevel)
            local prevTex = bar:GetStatusBarTexture()
            local barWidth = frame.healthBar:GetWidth() - (inset * 2)
            local barHeight = frame.healthBar:GetHeight() - (inset * 2)
            -- Full-width segment; StatusBar fills the others' proportion. The preview
            -- reaches here with othersHeals already set (applyTestHeals), so it takes
            -- the same path -- it used to size the segment by hand and inherited the
            -- primary's drift on top of its own.
            AnchorHealPredSegment(seg2, prevTex, healthOrient, barWidth, barHeight)
            seg2:SetMinMaxValues(0, maxHealth)
            DF.SetBarValue(seg2, othersHeals, frame)
            seg2:Show()
        elseif frame.dfHealPredictionBar2 then
            frame.dfHealPredictionBar2:Hide()
        end
    end

    -- The absorb hangs off these segments (DF:ResolveAbsorbChainAnchor), and the engine
    -- follows a segment's RESIZE but cannot re-pick WHICH texture to follow — so when the
    -- end of the chain changes, prompt an absorb re-anchor. This is only a PROMPT: the
    -- absorb's own cache re-derives ChainEndKey and the fill-texture identity on every
    -- call, so a missed prompt costs latency (until the next health tick or event), never
    -- correctness. ⚠ EDGE-TRIGGERED — this runs on every UNIT_HEAL_PREDICTION; an
    -- unconditional call would redo the absorb several times a second.
    -- ⚠ testIndex IS FORWARDED: the preview's absorb amount is a parameter of the same
    -- live function, and dropping it repaints a test frame's shield from live (zero) data.
    local chainEnd = DF.ChainEndKey and DF.ChainEndKey(frame, db) or "fill"
    if frame.dfHealPredChainEnd ~= chainEnd then
        frame.dfHealPredChainEnd = chainEnd
        if DF.UpdateAbsorb then DF:UpdateAbsorb(frame, testIndex) end
    end
end

-- `testName` is the only preview fork and it is pure DATA: the name a fabricated unit
-- token cannot answer (DF:GetFrameName reaches UnitName / Nicknames on a real player).
-- Truncation, the ELLIPSIS/CUT mode and the legacy-text suppression then run identically
-- for both. The preview used to restate the truncation block byte-for-byte, so a change
-- to the format only had to land in one of the two copies to desync them. Same shape as
-- DF:UpdatePetName(frame, testName).
function DF:UpdateName(frame, testName)
    if not frame or not frame.unit then return end

    -- TD legacy-text suppression: when ON, hide name + health text and skip.
    -- Lets Phase C live TD rendering be tested without overlap.
    if DF:IsLegacyTextHidden(frame) then
        if frame.nameText then frame.nameText:Hide() end
        if frame.healthText then frame.healthText:Hide() end
        return
    elseif frame.nameText and not frame.nameText:IsShown() then
        frame.nameText:Show()
    end

    -- Use raid DB for raid frames, party DB for party frames
    local db = DF:GetFrameDB(frame)
    local name = testName or DF:GetFrameName(frame.unit)

    -- Truncate name if needed (UTF-8 aware)
    if name then
        local maxLen = db.nameTextLength or 0
        local truncMode = db.nameTextTruncateMode or "ELLIPSIS"
        
        if maxLen > 0 and DF:UTF8Len(name) > maxLen then
            if truncMode == "CUT" then
                name = DF:UTF8Sub(name, 1, maxLen)
            else -- ELLIPSIS
                name = DF:UTF8Sub(name, 1, maxLen) .. "..."
            end
        end
    end
    
    frame.nameText:SetText(name)
    
    -- Defer color AND alpha to the appearance system so OOR element fading is respected.
    -- UpdateName fires on UNIT_NAME_UPDATE which would otherwise reset alpha to 1.0.
    if DF.UpdateNameTextAppearance then
        DF:UpdateNameTextAppearance(frame)
    else
        -- Fallback if appearance system not loaded yet
        local nameAlpha = 1
        if db.fadeDeadFrames and frame.dfDeadFadeApplied then
            nameAlpha = db.fadeDeadName or 1.0
        end
        if db.nameTextUseClassColor then
            local _, class = UnitClass(frame.unit)
            local classColor = class and DF:GetClassColor(class)
            if classColor then
                frame.nameText:SetTextColor(classColor.r, classColor.g, classColor.b, nameAlpha)
            else
                frame.nameText:SetTextColor(1, 1, 1, nameAlpha)
            end
        else
            local c = db.nameTextColor
            frame.nameText:SetTextColor(c.r, c.g, c.b, nameAlpha)
        end
    end
    
    -- Health text class color (independent of name color setting)
    if db.healthTextUseClassColor and frame.healthText then
        if DF.UpdateHealthTextAppearance then
            DF:UpdateHealthTextAppearance(frame)
        else
            local _, class = UnitClass(frame.unit)
            local classColor = class and DF:GetClassColor(class)
            if classColor then
                frame.healthText:SetTextColor(classColor.r, classColor.g, classColor.b, 1)
            end
        end
    end

    -- NOTE: the TextDesigner "name" refresh is driven from the central event
    -- dispatcher (Frames/Headers.lua UNIT_NAME_UPDATE branch), not here, for
    -- consistency with the other live text hooks.
end

-- The role the role ICON should display for `unit` -- may be nil or "NONE",
-- both meaning "show nothing".
--
-- ☠ THE GROUP TEST IS THE POINT, not a cheap guard. In a group the icon answers
-- "what is this unit here to do", so the player's spec role is the right answer
-- when the group has assigned none -- the case throughout a delve, where Brann
-- makes IsInGroup() true but no role is ever assigned, so the icon stayed hidden
-- until a spec change forced one. Solo, that question is not being asked at all:
-- resolving there would put a permanent role icon on your own frame in the open
-- world, where there has never been one. Hence group-only, deliberately NOT the
-- same policy as the resource bar, which wants the spec role everywhere.
--
-- ☠ ProcessRoleUpdate's dirty check MUST call this, not UnitGroupRolesAssigned.
-- That cache decides whether UpdateRoleIcon runs at all, so keying it on the raw
-- value while the icon displays a resolved one makes the resolution unreachable:
-- across a whole delve the raw value never leaves "NONE", the cache sees no
-- change, and the icon is never asked to redraw.
function DF:GetRoleIconRole(unit)
    if not unit then return nil end
    if IsInGroup() or IsInRaid() then
        return DF:GetUnitRole(unit)
    end
    -- ☠ The raw path needs its own guard: this branch bypasses GetUnitRole (and
    -- its secret handling) entirely, and a pinned boss frame renders solo — a
    -- world boss or solo delve boss reaches here with a secret role.
    local role = UnitGroupRolesAssigned(unit)
    if issecretvalue(role) then return nil end
    return role
end

-- ★ roleOverride lets the PREVIEW drive this without a real unit, the same shape
-- ShouldShowResourceBar and GetResourceBarColor use. The per-role visibility filter,
-- the MemTest gate, the texture pick and the positioning are then all live's.
--
-- ☠ Do not reinstate a copy in TestMode. The one that was there duplicated the
-- roleIconShowTank/Healer/DPS filter verbatim and omitted the MemTestDisabled gate
-- entirely, so running the Memory Test panel with role/leader icons unticked left
-- them lit on every test frame while live hid them.
function DF:UpdateRoleIcon(frame, source, roleOverride)
    if DF.RosterDebugCount then 
        DF:RosterDebugCount("UpdateRoleIcon")
        if source then
            DF:RosterDebugCount("UpdateRoleIcon:" .. source)
        end
    end
    if not frame or not frame.unit or not frame.roleIcon then return end

    -- MEMORY TEST (enableRoleLeaderIcons): hide rather than skip, so the icon
    -- leaves the frame instead of freezing in place.
    if DF:MemTestDisabled("enableRoleLeaderIcons") then
        frame.roleIcon:Hide()
        return
    end

    -- Use raid DB for raid frames, party DB for party frames
    local db = DF:GetFrameDB(frame)
    
    local role = roleOverride or DF:GetRoleIconRole(frame.unit)

    -- Use our tracked combat state (set by PLAYER_REGEN events)
    local inCombat = DF.playerInCombat or false

    if not role or role == "NONE" then
        frame.roleIcon:Hide()
        return
    end
    
    -- Per-role visibility filter (global — which roles ever show an icon).
    local shouldShow = false
    if role == "TANK" then
        shouldShow = db.roleIconShowTank ~= false
    elseif role == "HEALER" then
        shouldShow = db.roleIconShowHealer ~= false
    elseif role == "DAMAGER" then
        shouldShow = db.roleIconShowDPS ~= false
    end

    -- Hide-in-combat timing gate — independent of the role filter. Refreshed on
    -- combat transitions because Core's PLAYER_REGEN handlers call
    -- UpdateAllRoleIcons.
    if db.roleIconHideInCombat and inCombat then
        shouldShow = false
    end

    -- Edge-triggered. This used to be TWO unconditional lines per call, and
    -- UpdateAllRoleIcons walks every party and raid frame from nine GUI option
    -- callbacks — so dragging the role-icon scale slider emitted ~80 lines per drag
    -- frame, none of which said anything had changed. Only a transition is a fact.
    if frame.dfLastRoleShown ~= shouldShow or frame.dfLastRole ~= role then
        DF:Debug("ROLE", "%s: role=%s show=%s (hideInCombat=%s inCombat=%s)",
            tostring(frame.unit), tostring(role), tostring(shouldShow),
            tostring(db.roleIconHideInCombat), tostring(inCombat))
        frame.dfLastRoleShown = shouldShow
        frame.dfLastRole = role
    end

    if not shouldShow then
        frame.roleIcon:Hide()
        return
    end
    
    DF:SetIconTextureOrAtlas(frame.roleIcon.texture, DF:GetRoleIconTexture(db, role))
    
    frame.roleIcon:Show()
    
    -- Apply positioning
    local scale = db.roleIconScale or 1.0
    local anchor = db.roleIconAnchor or "TOPLEFT"
    local x = db.roleIconX or 2
    local y = db.roleIconY or -2
    local alpha = db.roleIconAlpha or 1
    
    frame.roleIcon:SetScale(scale)
    frame.roleIcon:ClearAllPoints()
    frame.roleIcon:SetPoint(anchor, frame, anchor, x, y)
    frame.roleIcon:SetAlpha(alpha)
    
    -- Apply frame level
    frame.roleIcon:SetFrameLevel(frame:GetFrameLevel() + (db.roleIconFrameLevel or 30))
end

function DF:UpdateAllRoleIcons()
    if DF.RosterDebugCount then DF:RosterDebugCount("UpdateAllRoleIcons") end
    
    -- Use our tracked combat state
    local inCombat = DF.playerInCombat or false
    
    DF:Debug("ROLE", "UpdateAllRoleIcons: inCombat=%s", tostring(inCombat))
    
    local function updateFrame(frame)
        if frame and frame:IsShown() then
            DF:UpdateRoleIcon(frame, "UpdateAllRoleIcons")
            DF:UpdateLeaderIcon(frame)
        end
    end
    
    -- Party frames via iterator
    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(updateFrame)
    end
    
    -- Raid frames via iterator
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(updateFrame)
    end
end

function DF:UpdateLeaderIcon(frame)
    if not frame or not frame.unit or not frame.leaderIcon then return end

    -- MEMORY TEST (enableRoleLeaderIcons): shares the role-icon flag.
    if DF:MemTestDisabled("enableRoleLeaderIcons") then
        frame.leaderIcon:Hide()
        return
    end

    -- Use raid DB for raid frames, party DB for party frames
    local db = DF:GetFrameDB(frame)
    
    -- Check if enabled
    if not db.leaderIconEnabled then
        frame.leaderIcon:Hide()
        return
    end
    
    -- Hide in combat check.
    -- ☠ DF.playerInCombat, NOT InCombatLockdown(). InCombatLockdown() answers "are
    -- secure frames locked?", which is NOT the same question as "is the player in
    -- combat?" -- using it as a combat proxy left this icon (and MT/MA, and five
    -- others) visible in combat with the option ticked, while the role icon, which
    -- has always read the tracked flag, hid correctly. Proven in game 2026-08-14 by
    -- A/B: role hid, leader and MT/MA did not, and the ONLY difference is this call.
    -- DF.playerInCombat is set in Core.lua from PLAYER_REGEN_DISABLED/ENABLED, and
    -- is set BEFORE the icon refreshes those handlers drive.
    -- ⇒ One combat-state source for the whole addon. Do not reintroduce the other.
    if db.leaderIconHideInCombat and DF.playerInCombat then
        frame.leaderIcon:Hide()
        return
    end
    
    local unit = frame.unit
    local isLeader = UnitIsGroupLeader(unit)
    local isAssist = UnitIsGroupAssistant(unit) and not isLeader
    
    if isLeader then
        frame.leaderIcon.texture:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
        frame.leaderIcon.texture:SetTexCoord(0, 1, 0, 1)
        frame.leaderIcon:Show()
    elseif isAssist then
        frame.leaderIcon.texture:SetTexture("Interface\\GroupFrame\\UI-Group-AssistantIcon")
        frame.leaderIcon.texture:SetTexCoord(0, 1, 0, 1)
        frame.leaderIcon:Show()
    else
        frame.leaderIcon:Hide()
        return
    end
    
    -- Apply positioning
    local scale = db.leaderIconScale or 1.0
    local anchor = db.leaderIconAnchor or "TOPLEFT"
    local x = db.leaderIconX or -2
    local y = db.leaderIconY or 2
    local alpha = db.leaderIconAlpha or 1
    
    frame.leaderIcon:SetScale(scale)
    frame.leaderIcon:ClearAllPoints()
    frame.leaderIcon:SetPoint(anchor, frame, anchor, x, y)
    frame.leaderIcon:SetAlpha(alpha)
    
    -- Apply frame level
    frame.leaderIcon:SetFrameLevel(frame:GetFrameLevel() + (db.leaderIconFrameLevel or 30))
end

function DF:UpdateRaidTargetIcon(frame)
    if not frame or not frame.unit or not frame.raidTargetIcon then return end
    
    -- Use raid DB for raid frames, party DB for party frames
    local db = DF:GetFrameDB(frame)
    
    -- Check if enabled
    if not db.raidTargetIconEnabled then
        frame.raidTargetIcon:Hide()
        return
    end
    
    -- Hide in combat check
    if db.raidTargetIconHideInCombat and DF.playerInCombat then
        frame.raidTargetIcon:Hide()
        return
    end
    
    -- Get raid target index (secret-safe)
    local index = nil
    local isSecret = false
    pcall(function()
        index = GetRaidTargetIndex(frame.unit)
    end)
    
    -- Check if it's a secret value
    if issecretvalue and issecretvalue(index) then
        isSecret = true
    end
    
    if isSecret then
        -- In Midnight, use SetSpriteSheetCell for secret values
        frame.raidTargetIcon.texture:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
        if frame.raidTargetIcon.texture.SetSpriteSheetCell then
            pcall(function()
                frame.raidTargetIcon.texture:SetSpriteSheetCell(index, 4, 4, 64, 64)
            end)
        end
        frame.raidTargetIcon:Show()
    elseif index then
        -- Normal case - index is accessible
        frame.raidTargetIcon.texture:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
        SetRaidTargetIconTexture(frame.raidTargetIcon.texture, index)
        frame.raidTargetIcon:Show()
    else
        frame.raidTargetIcon:Hide()
        return
    end
    
    -- Apply positioning
    local scale = db.raidTargetIconScale or 1.5
    local anchor = db.raidTargetIconAnchor or "TOP"
    local x = db.raidTargetIconX or 0
    local y = db.raidTargetIconY or 2
    local alpha = db.raidTargetIconAlpha or 1
    
    frame.raidTargetIcon:SetScale(scale)
    frame.raidTargetIcon:ClearAllPoints()
    frame.raidTargetIcon:SetPoint(anchor, frame, anchor, x, y)
    frame.raidTargetIcon:SetAlpha(alpha)
    
    -- Apply frame level
    frame.raidTargetIcon:SetFrameLevel(frame:GetFrameLevel() + (db.raidTargetIconFrameLevel or 30))
end

function DF:UpdateReadyCheckIcon(frame)
    if not frame or not frame.unit or not frame.readyCheckIcon then return end
    
    -- Use raid DB for raid frames, party DB for party frames
    local db = DF:GetFrameDB(frame)
    
    -- Check if enabled
    if not db.readyCheckIconEnabled then
        frame.readyCheckIcon:Hide()
        return
    end
    
    -- Hide in combat check
    if db.readyCheckIconHideInCombat and DF.playerInCombat then
        frame.readyCheckIcon:Hide()
        return
    end
    
    local readyCheckStatus = GetReadyCheckStatus(frame.unit)
    
    if readyCheckStatus == "ready" then
        DF:SetUpgradedStatusIcon(frame.readyCheckIcon.texture, "Interface\\RaidFrame\\ReadyCheck-Ready")
        frame.readyCheckIcon:Show()
    elseif readyCheckStatus == "notready" then
        DF:SetUpgradedStatusIcon(frame.readyCheckIcon.texture, "Interface\\RaidFrame\\ReadyCheck-NotReady")
        frame.readyCheckIcon:Show()
    elseif readyCheckStatus == "waiting" then
        -- Check if player is AFK while waiting (enhanced ready check)
        local isAFK = nil
        pcall(function()
            isAFK = UnitIsAFK(frame.unit)
        end)
        
        -- Use issecretvalue check
        local afkAccessible = isAFK ~= nil and not (issecretvalue and issecretvalue(isAFK))
        
        if afkAccessible and isAFK then
            -- AFK state - show not ready icon (they likely won't respond)
            DF:SetUpgradedStatusIcon(frame.readyCheckIcon.texture, "Interface\\RaidFrame\\ReadyCheck-NotReady")
        else
            DF:SetUpgradedStatusIcon(frame.readyCheckIcon.texture, "Interface\\RaidFrame\\ReadyCheck-Waiting")
        end
        frame.readyCheckIcon:Show()
    else
        frame.readyCheckIcon:Hide()
        return
    end
    
    -- Apply positioning
    local scale = db.readyCheckIconScale or 1.0
    local anchor = db.readyCheckIconAnchor or "CENTER"
    local x = db.readyCheckIconX or 0
    local y = db.readyCheckIconY or 0
    local alpha = db.readyCheckIconAlpha or 1
    
    frame.readyCheckIcon:SetScale(scale)
    frame.readyCheckIcon:ClearAllPoints()
    frame.readyCheckIcon:SetPoint(anchor, frame, anchor, x, y)
    frame.readyCheckIcon:SetAlpha(alpha)
    
    -- Apply frame level
    frame.readyCheckIcon:SetFrameLevel(frame:GetFrameLevel() + (db.readyCheckIconFrameLevel or 30))
end

-- Schedule ready check icon to hide after a delay
function DF:ScheduleReadyCheckHide(frame)
    if not frame or not frame.readyCheckIcon then return end
    
    -- Use raid DB for raid frames, party DB for party frames
    local db = DF:GetFrameDB(frame)
    local delay = db.readyCheckIconPersist or 6  -- Default 6 seconds
    
    -- Cancel any existing timer for this frame
    if frame.readyCheckHideTimer then
        frame.readyCheckHideTimer:Cancel()
        frame.readyCheckHideTimer = nil
    end
    
    -- Schedule hiding after delay
    frame.readyCheckHideTimer = C_Timer.NewTimer(delay, function()
        if frame.readyCheckIcon then
            frame.readyCheckIcon:Hide()
        end
        frame.readyCheckHideTimer = nil
    end)
end

function DF:UpdateCenterStatusIcon(frame)
    if not frame or not frame.unit then return end
    
    -- Use raid DB for raid frames, party DB for party frames
    local db = DF:GetFrameDB(frame)
    
    -- Update new individual icons
    if DF.UpdateSummonIcon then DF:UpdateSummonIcon(frame) end
    if DF.UpdateResurrectionIcon then DF:UpdateResurrectionIcon(frame) end
    if DF.UpdatePhasedIcon then DF:UpdatePhasedIcon(frame) end
    if DF.UpdateAFKIcon then DF:UpdateAFKIcon(frame) end
    if DF.UpdateVehicleIcon then DF:UpdateVehicleIcon(frame) end
    if DF.UpdateRaidRoleIcon then DF:UpdateRaidRoleIcon(frame) end
end

-- ============================================================
-- RESTED INDICATOR (Solo Mode)
-- ============================================================

function DF:UpdateRestedIndicator()
    -- Only applies to player frame in solo mode
    local playerFrame = DF:GetPlayerFrame()
    if not playerFrame then return end
    if not playerFrame.restedIndicator then return end
    
    local db = DF:GetDB()
    if not db then return end
    
    -- Check if rested indicator is enabled and we're in solo mode
    local inGroup = IsInGroup() or IsInRaid()
    local soloModeEnabled = db.soloMode == true
    local restedEnabled = db.restedIndicator ~= false  -- Default to true if nil
    local showIndicator = restedEnabled and soloModeEnabled and not inGroup
    
    -- Get individual icon/glow settings (default to true)
    local showIcon = db.restedIndicatorIcon ~= false
    local showGlow = db.restedIndicatorGlow ~= false
    
    if not showIndicator then
        playerFrame.restedIndicator:Hide()
        if playerFrame.restedGlow then
            playerFrame.restedGlow:Hide()
        end
        return
    end
    
    -- Check if player is resting and player frame is visible
    if IsResting() and playerFrame:IsShown() then
        -- Show/hide icon based on setting
        if showIcon then
            playerFrame.restedIndicator:Show()
        else
            playerFrame.restedIndicator:Hide()
        end
        
        -- Show/hide glow based on setting
        if playerFrame.restedGlow then
            if showGlow then
                playerFrame.restedGlow:Show()
            else
                playerFrame.restedGlow:Hide()
            end
        end
    else
        playerFrame.restedIndicator:Hide()
        if playerFrame.restedGlow then
            playerFrame.restedGlow:Hide()
        end
    end
end

-- Debug function for rested indicator
function DF:DebugRestedIndicator()
    local o = DF:Out("Rested Indicator")
    local playerFrame = DF:GetPlayerFrame()
    o:Section("Widgets")
    -- No player frame means nothing downstream can render: that IS the fault.
    o:Field("playerFrame", playerFrame and "exists" or "missing", playerFrame and "good" or "bad")
    if playerFrame then
        o:Field("playerFrame shown", playerFrame:IsShown() and "yes" or "no",
            playerFrame:IsShown() and "good" or "neutral")
        o:Field("restedIndicator", playerFrame.restedIndicator and "exists" or "missing",
            playerFrame.restedIndicator and "good" or "neutral")
        if playerFrame.restedIndicator then
            o:Field("restedIndicator shown", playerFrame.restedIndicator:IsShown() and "yes" or "no",
                playerFrame.restedIndicator:IsShown() and "good" or "neutral")
        end
        o:Field("restedGlow", playerFrame.restedGlow and "exists" or "missing",
            playerFrame.restedGlow and "good" or "neutral")
        if playerFrame.restedGlow then
            o:Field("restedGlow shown", playerFrame.restedGlow:IsShown() and "yes" or "no",
                playerFrame.restedGlow:IsShown() and "good" or "neutral")
        end
    end
    local db = DF:GetDB()
    if db then
        o:Section("Settings")
        -- These are user choices, so OFF is never a fault - only ever neutral.
        local function opt(label, v)
            o:Field(label, v and "on" or "off", v and "good" or "neutral")
        end
        opt("soloMode", db.soloMode)
        opt("restedIndicator", db.restedIndicator)
        opt("restedIndicatorIcon", db.restedIndicatorIcon)
        opt("restedIndicatorGlow", db.restedIndicatorGlow)
    end
    o:Section("Game state")
    o:Field("IsResting()", IsResting() and "yes" or "no", IsResting() and "good" or "neutral")
    o:Field("IsInGroup()", IsInGroup() and "yes" or "no", IsInGroup() and "good" or "neutral")
    o:Field("IsInRaid()", IsInRaid() and "yes" or "no", IsInRaid() and "good" or "neutral")
end

-- Raid buff definitions: {spellID, configKey, name, class}
-- Icons are looked up dynamically using GetSpellTexture
-- Raid buff definitions: {spellID or {spellID, spellID2, ...}, configKey, name, class}
-- Some buffs have multiple spell IDs (e.g., cast spell vs applied buff)
DF.RaidBuffs = {
    {{1459, 432778}, "missingBuffCheckIntellect", "Arcane Intellect", "MAGE"},
    {21562, "missingBuffCheckStamina", "Power Word: Fortitude", "PRIEST"},
    {6673, "missingBuffCheckAttackPower", "Battle Shout", "WARRIOR"},
    {{1126, 432661}, "missingBuffCheckVersatility", "Mark of the Wild", "DRUID"},
    {462854, "missingBuffCheckSkyfury", "Skyfury", "SHAMAN"},
    -- Blessing of the Bronze: 13 variant buff IDs from different Evoker augment specs
    {{381732, 381741, 381746, 381748, 381749, 381750, 381751, 381752, 381753, 381754, 381756, 381757, 381758}, "missingBuffCheckBronze", "Blessing of the Bronze", "EVOKER"},
}

-- Map player class to their raid buff config key
DF.ClassToRaidBuff = {
    ["MAGE"] = "missingBuffCheckIntellect",
    ["PRIEST"] = "missingBuffCheckStamina",
    ["WARRIOR"] = "missingBuffCheckAttackPower",
    ["DRUID"] = "missingBuffCheckVersatility",
    ["SHAMAN"] = "missingBuffCheckSkyfury",
    ["EVOKER"] = "missingBuffCheckBronze",
}

-- Non-secret raid buff spell IDs (Blizzard-whitelisted, remain readable in combat)
-- Source: Ellesmere whitelist, cross-referenced with our RaidBuffs
DF.NonSecretRaidBuffIDs = {}
do
    local WHITELISTED = {
        [1126]=true, [432661]=true, [1459]=true, [432778]=true,
        [21562]=true, [6673]=true, [462854]=true,
        [381732]=true, [381741]=true, [381746]=true, [381748]=true, [381749]=true,
        [381750]=true, [381751]=true, [381752]=true, [381753]=true, [381754]=true,
        [381756]=true, [381757]=true, [381758]=true,
    }
    for _, buffInfo in ipairs(DF.RaidBuffs) do
        local ids = type(buffInfo[1]) == "table" and buffInfo[1] or {buffInfo[1]}
        for _, id in ipairs(ids) do
            if WHITELISTED[id] then DF.NonSecretRaidBuffIDs[id] = true end
        end
    end
end

-- Get raid buff icons for fallback filtering (when spellId is secret)
-- This is cached after first call
