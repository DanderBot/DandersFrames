local addonName, DF = ...

-- ============================================================
-- UNIFIED BORDER BACKEND (DF.Border)
--
-- One border widget used across the addon so every border shares the same
-- capabilities and code path. A widget supports two render modes behind a
-- single colour API:
--   * Solid (default): four ColorTexture edges — pixel-perfect.
--   * Texture: a BackdropTemplate child using a LibSharedMedia border edgeFile.
--
-- Usage:
--   local b = DF.Border:New(parent[, opts])   -- create the widget once
--   DF.Border:Apply(b, spec)                  -- (re)configure from a spec
--   b:SetColor(r, g, b, a)                    -- live recolour (routes to mode)
--
-- The frame border is the first consumer; `frame.border` keeps the same shape
-- (top/bottom/left/right edges, a lazily-created `bd` backdrop child, and a
-- :SetBorderColor alias) so existing callers are unaffected.
--
-- FUTURE (later phases) — the spec is intentionally open for: inset, shadow,
-- gradient, and glow (LibCustomGlow). Only the current frame-border feature set
-- (enabled / style / texture / size / colour) is implemented here for now.
-- ============================================================

local CreateFrame = CreateFrame
local ipairs = ipairs
-- Midnight-safe: test a colour channel for secretness before feeding it to
-- CreateColor()/SetGradient (which reject secret values).
local issecretvalue = issecretvalue or function() return false end

DF.Border = DF.Border or {}
local Border = DF.Border

-- Create a border widget anchored to `parent` (or opts.anchorTo).
-- opts:
--   anchorTo          frame to cover (default: parent)
--   frameLevelOffset  level above parent (default: 10)
--   layer             texture draw layer for the solid edges (default: "BORDER")
--   solidOnly         hot-path SOLID border that never uses a gradient. Skips the
--                     SetGradient/CreateColor gradient-clear in both Apply (SOLID)
--                     and SetColor, so live recolours are a bare SetColorTexture —
--                     cheap AND safe for secret-tinted colours (e.g. debuff
--                     dispel-type colours), where CreateColor()/comparisons would
--                     taint. Do NOT set for borders that can switch to GRADIENT.
function Border:New(parent, opts)
    opts = opts or {}
    local border = CreateFrame("Frame", nil, parent)
    border._solidOnly = opts.solidOnly and true or false
    -- Remember anchorTo on the widget so :Apply can re-anchor when an offsetX/Y
    -- is supplied (SetAllPoints below is the offsetX=offsetY=0 default; :Apply
    -- replaces it with two SetPoint calls translated by the offset).
    border.anchorTo = opts.anchorTo or parent
    border:SetAllPoints(border.anchorTo)
    border:SetFrameLevel(parent:GetFrameLevel() + (opts.frameLevelOffset or 10))

    local layer = opts.layer or "BORDER"
    border.top = border:CreateTexture(nil, layer)
    border.top:SetPoint("TOPLEFT", 0, 0)
    border.top:SetPoint("TOPRIGHT", 0, 0)
    border.bottom = border:CreateTexture(nil, layer)
    border.bottom:SetPoint("BOTTOMLEFT", 0, 0)
    border.bottom:SetPoint("BOTTOMRIGHT", 0, 0)
    border.left = border:CreateTexture(nil, layer)
    border.left:SetPoint("TOPLEFT", 0, 0)
    border.left:SetPoint("BOTTOMLEFT", 0, 0)
    border.right = border:CreateTexture(nil, layer)
    border.right:SetPoint("TOPRIGHT", 0, 0)
    border.right:SetPoint("BOTTOMRIGHT", 0, 0)

    -- Recolour whichever mode is currently active (used by live colour updates,
    -- aggro/threat/dispel overlays, etc.).
    border.SetColor = function(self, r, g, b, a)
        a = a or 1
        if self.activeTexture then
            if self.bd then self.bd:SetBackdropBorderColor(r, g, b, a) end
        else
            local bm = self._blendMode or "BLEND"
            local edges = { self.top, self.bottom, self.left, self.right }
            -- Clear any prior gradient — SetColorTexture does NOT reset it, so a
            -- leftover gradient (set when the border was first painted, even in
            -- SOLID mode) would tint the recolour and wash it out.  Paint a
            -- solid gradient of the new colour first (same pattern Apply uses).
            -- solidOnly borders never set a gradient (Apply skips it too), so we
            -- skip this — keeps the recolour a bare SetColorTexture, which is
            -- both cheaper and safe for secret-tinted colours (CreateColor on a
            -- secret value taints execution).
            if not self._solidOnly and CreateColor then
                -- Reset any leftover gradient before the solid SetColorTexture.
                -- Use the real colour when non-secret (so a Blizzard pipeline that
                -- leaves the gradient in place still shows the right colour), but
                -- fall back to white when ANY channel is SECRET — CreateColor on a
                -- secret makes SetGradient throw "bad argument" (the expiring path
                -- passes secret colours in combat). SetColorTexture below paints
                -- the real, secret-safe colour either way.
                local clear = (issecretvalue(r) or issecretvalue(g) or issecretvalue(b) or issecretvalue(a))
                    and CreateColor(1, 1, 1, 1) or CreateColor(r, g, b, a)
                for _, e in ipairs(edges) do
                    if e.SetGradient then e:SetGradient("HORIZONTAL", clear, clear) end
                end
            end
            for _, e in ipairs(edges) do
                e:SetColorTexture(r, g, b, a)
                e:SetBlendMode(bm)
            end
        end
    end
    -- Back-compat alias: existing frame-border consumers call :SetBorderColor.
    border.SetBorderColor = border.SetColor

    return border
end

-- Resolve a colour from either an array {r,g,b,a} or a keyed {r=,g=,b=,a=}
-- table, so consumers can pass whichever they already store.
local function readColor(color)
    if not color then return 0, 0, 0, 1 end
    return color[1] or color.r or 0,
           color[2] or color.g or 0,
           color[3] or color.b or 0,
           color[4] or color.a or 1
end

-- Build a ready-to-Apply spec from a dbTable using the canonical key naming
-- mirror of CreateBorderControls: prefix .. "BorderSize" / "BorderStyle" /
-- "BorderGradientStartColor" etc. Each consumer's Apply call site collapses
-- to `DF.Border:Apply(border, DF.Border:BuildSpec(db, prefix))` (with optional
-- post-hoc overrides like a locally pixel-perfected size). Missing keys fall
-- back to sensible defaults — same defaults the Config blocks would seed.
--
-- ctx (optional, Stage 2): { unit, auraInstanceID, remaining, totalDuration,
-- timeMode = "SECONDS"|"PERCENT", timeCurve, roleColors }. When a colour-
-- resolver toggle is enabled in db (`UseClassColor` / `UseRoleColor` /
-- `ColorByTime` / `ColorByType`), BuildSpec resolves the colour via the
-- matching Border:Resolve* helper. Priority order (most specific wins):
--   type > time > class > role > static spec.color
-- Resolvers silently fall through when their required ctx is missing, so a
-- consumer that only knows the unit can still flip on classColor without
-- worrying about time/type ctx.
function Border:BuildSpec(dbTable, prefix, ctx)
    if not dbTable or not prefix then return {} end
    local function k(suffix) return prefix .. suffix end

    -- Style is the top-level choice: SOLID | GRADIENT | TEXTURE.
    -- GRADIENT owns its own colours (start/end pickers) so the colour-source
    -- resolver chain is skipped for it — applying class/role/time/type tinting
    -- on top of a gradient produced visual conflicts (you'd pick "class
    -- colour" then watch the gradient stomp it). The model is: one style →
    -- one colour expression.
    local style = dbTable[k("BorderStyle")] or "SOLID"

    -- Resolve colour. Static `<prefix>BorderColor` is the fallback for every
    -- resolver, so flipping the source back to STATIC restores the picker
    -- colour without the consumer doing anything.
    --
    -- `<prefix>BorderColorSource` ("STATIC" | "CLASS" | "ROLE") replaces the
    -- previous independent boolean toggles (UseClassColor / UseRoleColor). The
    -- old keys are migrated on db load (MigrateFrameBorderKeys); we still
    -- honour them here as a fallback in case migration hasn't run for some
    -- code path yet. ColorByTime / ColorByType remain independent and stack
    -- ON TOP of the source — they override during aura state, then drop back
    -- to whichever source the user picked.
    local fallbackColor = dbTable[k("BorderColor")]
    local color = fallbackColor
    local source = dbTable[k("BorderColorSource")]
    if not source then
        if dbTable[k("BorderUseClassColor")]     then source = "CLASS"
        elseif dbTable[k("BorderUseRoleColor")]  then source = "ROLE"
        else                                          source = "STATIC" end
    end
    if ctx and style ~= "GRADIENT" then
        if dbTable[k("BorderColorByType")] and ctx.unit and ctx.auraInstanceID then
            local r, g, b, a = self:ResolveTypeColor(ctx.unit, ctx.auraInstanceID, fallbackColor)
            color = { r = r, g = g, b = b, a = a }
        elseif dbTable[k("BorderColorByTime")] and ctx.timeCurve and ctx.remaining and ctx.totalDuration then
            local r, g, b, a = self:ResolveTimeColor(ctx.timeCurve, ctx.remaining, ctx.totalDuration, ctx.timeMode, fallbackColor)
            color = { r = r, g = g, b = b, a = a }
        elseif source == "CLASS" and (ctx.unit or ctx.frame) then
            -- Resolver supplies RGB from the class colour; alpha comes from
            -- the picker (`<prefix>BorderColor.a`). The Border Alpha slider
            -- (when the consumer opts into include.alpha) edits the SAME
            -- key, so picker and slider stay in sync automatically.
            -- ctx.frame lets test frames look up class via GetTestUnitData
            -- (Stage 4.0 — defensive icon test-mode preview).
            local r, g, b, _ = self:ResolveClassColor(ctx.unit, fallbackColor, ctx.frame)
            local a = (fallbackColor and (fallbackColor.a or fallbackColor[4])) or 1
            color = { r = r, g = g, b = b, a = a }
        elseif source == "ROLE" and (ctx.unit or ctx.frame) then
            -- Role colours live at DF.db.roleColors (profile-level, shared with
            -- the Colors settings page). Consumer can still override via
            -- ctx.roleColors if it has a special-case set. Alpha from the
            -- picker, same reasoning as CLASS.
            local rc = ctx.roleColors or (DF.db and DF.db.roleColors)
            if rc then
                local r, g, b, _ = self:ResolveRoleColor(ctx.unit, fallbackColor, rc, ctx.frame)
                local a = (fallbackColor and (fallbackColor.a or fallbackColor[4])) or 1
                color = { r = r, g = g, b = b, a = a }
            end
        end
    end

    local spec = {
        enabled       = dbTable[k("ShowBorder")] ~= false,
        style         = style,
        texture       = dbTable[k("BorderTexture")],
        size          = dbTable[k("BorderSize")] or 1,
        color         = color,
        inset         = dbTable[k("BorderInset")] or 0,
        offsetX       = dbTable[k("BorderOffsetX")] or 0,
        offsetY       = dbTable[k("BorderOffsetY")] or 0,
        blendMode     = dbTable[k("BorderBlendMode")] or "BLEND",
        pixelPerfect  = dbTable.pixelPerfect,
    }
    -- Gradient is now a STYLE (selected via the Border Style dropdown) rather
    -- than an independent toggle. The legacy `<prefix>BorderGradientEnabled`
    -- boolean is migrated to `<prefix>BorderStyle = "GRADIENT"` on db load
    -- (MigrateFrameBorderKeys / equivalent) but we still honour a stale
    -- `true` here as a safety net in case the migration hasn't run on some
    -- code path.
    if style == "GRADIENT" or dbTable[k("BorderGradientEnabled")] then
        spec.style = "GRADIENT"
        spec.gradient = {
            enabled    = true,
            startColor = dbTable[k("BorderGradientStartColor")],
            endColor   = dbTable[k("BorderGradientEndColor")],
            direction  = dbTable[k("BorderGradientDirection")] or "HORIZONTAL",
        }
    end
    if dbTable[k("BorderShadowEnabled")] then
        spec.shadow = {
            enabled  = true,
            color    = dbTable[k("BorderShadowColor")],
            size     = dbTable[k("BorderShadowSize")] or 1,
            offsetX  = dbTable[k("BorderShadowOffsetX")] or 0,
            offsetY  = dbTable[k("BorderShadowOffsetY")] or 0,
        }
    end
    -- Animation (Stage 3): LCG-backed glow effects. spec.animation is set only
    -- when the consumer picked a non-NONE type — Apply uses presence to drive
    -- StartAnimation, absence to drive StopAnimation. Tunables map 1:1 to
    -- LCG.PixelGlow_Start / AutoCastGlow_Start / ButtonGlow_Start args, with
    -- sensible defaults applied at Start time.
    local animType = dbTable[k("BorderAnimationType")]
    if animType and animType ~= "NONE" then
        spec.animation = {
            type         = animType,
            color        = dbTable[k("BorderAnimationColor")],
            frequency    = dbTable[k("BorderAnimationFrequency")],
            particles    = dbTable[k("BorderAnimationParticles")],
            length       = dbTable[k("BorderAnimationLength")],
            thickness    = dbTable[k("BorderAnimationThickness")],
            scale        = dbTable[k("BorderAnimationScale")],
            inset        = dbTable[k("BorderAnimationInset")],
            offsetX      = dbTable[k("BorderAnimationOffsetX")],
            offsetY      = dbTable[k("BorderAnimationOffsetY")],
            mask         = dbTable[k("BorderAnimationMask")],
            sidesAxis    = dbTable[k("BorderAnimationSidesAxis")],
            cornerLength = dbTable[k("BorderAnimationCornerLength")],
            -- PROC only: play the one-shot "proc start" flash on each start.
            -- Opt-in (default off) because PROC is used here as a CONTINUOUS
            -- border animation that re-applies often; the flash is a one-shot
            -- effect and re-fires/doubles on rapid re-apply when enabled.
            procStart    = dbTable[k("BorderAnimationProcStart")],
        }
    end
    -- Icon consumers (ctx.iconMode) frame the art with an OUTWARD band — the
    -- opposite of the inward convention frame outlines / status bars use.  Route
    -- through the shared icon-geometry helper so every icon border reads the same
    -- (AD icon/square, aura icons, defensive / missing-buff / targeted-spell).
    if ctx and ctx.iconMode then
        self:IconGeometry(spec, spec.size, spec.inset)
    end
    return spec
end

-- ============================================================
-- ICON BORDER GEOMETRY (shared convention)
-- One geometry model for every icon-shaped consumer — AD icon/square, buff/
-- debuff aura icons, and the defensive / missing-buff / targeted-spell icons —
-- so they all read identically: a `thickness`-wide band that FRAMES the art,
-- nudged OUTWARD by BorderInset (spec.inset = -inset), with the art inset by
-- the thickness when the border is on.  (Frame outlines and status bars keep
-- the inward BuildSpec convention — a different, correct family.)
-- ============================================================

-- Stamp the icon geometry onto an already-built spec (from BuildSpec or a
-- hand-built table).  Mutates + returns spec.
function Border:IconGeometry(spec, thickness, borderInset)
    spec.size  = thickness
    spec.inset = -(borderInset or 0)
    return spec
end

-- Inset an icon's art/texture so the band frames it: by `thickness` when the
-- border is enabled, 0 when it's off (art fills the slot).
function Border:SetIconArtInset(texture, thickness, enabled)
    if not texture then return end
    local i = (enabled and thickness) or 0
    texture:ClearAllPoints()
    texture:SetPoint("TOPLEFT",     i, -i)
    texture:SetPoint("BOTTOMRIGHT", -i,  i)
end

-- ============================================================
-- COLOUR RESOLVERS (Stage 2)
-- Reusable per-element colour computations consumers can opt into via toggle
-- keys (`<prefix>BorderUseClassColor`, `<prefix>BorderColorByTime`, etc.).
-- Each returns r,g,b,a and falls back to `fallback` when context is missing or
-- resolution doesn't yield a colour. `fallback` accepts the same {r,g,b,a} or
-- {r=,g=,b=,a=} shape that the rest of DF.Border uses.
-- ============================================================

-- Class colour of `unit`, with `fallback`'s alpha preserved (the colour
-- picker's alpha shouldn't change when the toggle flips to class colour).
-- Optional 3rd arg `frame`: if it has dfIsTestFrame=true, the class is
-- pulled from the test data (DF:GetTestUnitData) instead of UnitClass(unit).
-- This lets test mode preview Class colour correctly even though test
-- frames don't have real unit IDs. Live frames go through the unit path.
function Border:ResolveClassColor(unit, fallback, frame)
    local fr, fg, fb, fa = readColor(fallback)

    local classToken
    if frame and frame.dfIsTestFrame then
        local testData = DF.GetTestUnitData and DF:GetTestUnitData(frame.index, frame.isRaidFrame)
        classToken = testData and testData.class
    elseif unit and UnitExists and UnitExists(unit) then
        classToken = select(2, UnitClass(unit))
    end

    if classToken and DF.GetClassColor then
        local c = DF:GetClassColor(classToken)
        if c then return c.r or fr, c.g or fg, c.b or fb, fa end
    end
    return fr, fg, fb, fa
end

-- Role colour from a shared {TANK=, HEALER=, DAMAGER=} table, with fallback
-- alpha preserved. roleColors is typically `{tank = db.roleBorderColorTank,
-- healer = db.roleBorderColorHealer, damager = db.roleBorderColorDamager}`
-- supplied by the caller from the global db block. Optional 4th arg `frame`:
-- mirrors ResolveClassColor — test frames go through GetTestUnitData,
-- live frames through UnitGroupRolesAssigned.
function Border:ResolveRoleColor(unit, fallback, roleColors, frame)
    local fr, fg, fb, fa = readColor(fallback)
    if not roleColors then return fr, fg, fb, fa end

    local role
    if frame and frame.dfIsTestFrame then
        local testData = DF.GetTestUnitData and DF:GetTestUnitData(frame.index, frame.isRaidFrame)
        role = testData and testData.role
    elseif unit and UnitExists and UnitExists(unit) and UnitGroupRolesAssigned then
        role = UnitGroupRolesAssigned(unit)
        -- UnitGroupRolesAssigned returns "NONE" outside instances where roles
        -- aren't assigned (solo, world content, open-world groups). For the
        -- player, fall back to the spec role so role colour is meaningful
        -- regardless of group context. Other units expose no public spec API,
        -- so they stay on the picker fallback when role is NONE.
        if (not role or role == "NONE") and UnitIsUnit and UnitIsUnit(unit, "player")
           and GetSpecialization and GetSpecializationRole then
            local spec = GetSpecialization()
            if spec then role = GetSpecializationRole(spec) end
        end
    end

    local c = role and role ~= "NONE" and (roleColors[role] or roleColors[string.lower(role)])
    if c then return c.r or fr, c.g or fg, c.b or fb, fa end
    return fr, fg, fb, fa
end

-- Colour-by-time-remaining via a C_CurveUtil colour curve. Caller supplies the
-- pre-built curve (e.g. DF.expiringCurves[...]). totalDuration > 0 required
-- so we can pass either a remaining-percent (curve expects [0,1]) or a
-- remaining-duration (curve expects seconds) — `mode` picks which API to call.
function Border:ResolveTimeColor(curve, remaining, totalDuration, mode, fallback)
    local fr, fg, fb, fa = readColor(fallback)
    if not curve or not remaining or not totalDuration or totalDuration <= 0 then
        return fr, fg, fb, fa
    end
    -- Curves return ColorMixins via EvaluateRemainingDuration / Percent. The
    -- two helpers exist on the curve object directly (Midnight 12.0+).
    local result
    if mode == "SECONDS" and curve.EvaluateRemainingDuration then
        result = curve:EvaluateRemainingDuration(remaining)
    elseif curve.EvaluateRemainingPercent then
        local pct = remaining / totalDuration
        if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
        result = curve:EvaluateRemainingPercent(pct)
    end
    if result and result.GetRGBA then
        local r, g, b, a = result:GetRGBA()
        return r or fr, g or fg, b or fb, a or fa
    end
    return fr, fg, fb, fa
end

-- Dispel-type colour for a debuff, via C_UnitAuras.GetAuraDispelTypeColor.
-- Lazy-builds `DF.debuffBorderCurve` from C_CurveUtil if it isn't already
-- present (Auras.lua / Dispel.lua build the same one independently today;
-- this serves as a shared lazy fallback).
function Border:ResolveTypeColor(unit, auraInstanceID, fallback)
    local fr, fg, fb, fa = readColor(fallback)
    if not unit or not auraInstanceID or not C_UnitAuras or not C_UnitAuras.GetAuraDispelTypeColor then
        return fr, fg, fb, fa
    end
    if not DF.debuffBorderCurve and C_CurveUtil and C_CurveUtil.CreateColorCurve then
        -- Same curve spec the buff/debuff aura system uses (extracted later if
        -- we need to expose customisation; for now a sensible default).
        DF.debuffBorderCurve = C_CurveUtil.CreateColorCurve({
            { 0,   CreateColor(0.6, 0.0, 0.0, 1) },
            { 1,   CreateColor(0.6, 0.0, 0.0, 1) },
        })
    end
    if not DF.debuffBorderCurve then return fr, fg, fb, fa end
    local result = C_UnitAuras.GetAuraDispelTypeColor(unit, auraInstanceID, DF.debuffBorderCurve)
    if result and result.GetRGBA then
        local r, g, b, a = result:GetRGBA()
        return r or fr, g or fg, b or fb, fa  -- keep fallback alpha (picker controls it)
    end
    return fr, fg, fb, fa
end

-- ============================================================
-- ANIMATIONS (Stage 3)
--
-- spec.animation = { type, color, frequency, particles, length, thickness,
-- scale, cornerLength, sidesAxis }. `type` is the only required field;
-- the rest fall back to per-effect defaults.
--
-- Effects split into three implementation families:
--
-- 1. LCG-driven glows — target border.anchorTo (the unit frame) so the
--    glow reads as "this unit is highlighted" rather than "this thin 1px
--    strip is highlighted".
--      "PULSATE"   → LCG.PixelGlow_Start    pixel-art ring of N particles
--      "CHASE"     → LCG.AutoCastGlow_Start rotating particle ring
--      "FLASH"     → LCG.ButtonGlow_Start   Blizzard button-glow pulse
--      "PROC"      → LCG.ProcGlow_Start     Blizzard proc start+loop flash
--
-- 2. Custom OnUpdate animators — operate directly on the 4 edge textures
--    by modulating SetAlpha each frame. No LCG involved. Tick functions
--    live in `customTicks` below; the shared driver frame is created
--    lazily via ensureDriver(border).
--      "WIPE"           sweep a bright highlight clockwise around perimeter
--      "RIPPLE"         all edges pulse alpha with per-edge phase offsets
--      "SEGMENT_REVEAL" edges fade in sequentially top→right→bottom→left
--
-- 3. Static shape modes — no animation, just a different render layout
--    held for as long as the type is active.
--      "SIDES_ONLY"   hide one perpendicular edge pair (axis option)
--      "CORNERS_ONLY" show only short pieces at each of the 4 corners
--                     (lazy-creates 4 extra textures so each corner has
--                     a horizontal + a vertical short piece)
--
--      "NONE"         silently stops any running effect
--
-- Stop semantics: Apply ALWAYS calls StopAnimation first to clear any prior
-- effect before starting a new one (avoids leaving a stale Pulsate running
-- under a freshly-started Chase, or stale CORNERS_ONLY textures visible
-- under a freshly-started WIPE). Idempotent for the no-active-anim case.
-- ============================================================

local function getLCG()
    return LibStub and LibStub("LibCustomGlow-1.0", true)
end

-- Lazy-create the shared OnUpdate driver for custom animations.
local function ensureDriver(border)
    if border.animDriver then return border.animDriver end
    local d = CreateFrame("Frame", nil, border)
    d.elapsed = 0
    border.animDriver = d
    return d
end

-- Reset all four edges to fully opaque. Called from StopAnimation so the
-- next Apply pass renders normally; custom animators set non-1 alpha values
-- that would otherwise persist on the edges (relevant for SIDES_ONLY, which
-- modulates edge alpha directly rather than via overlays).
local function resetEdgeAlphas(border)
    local edges = { border.top, border.bottom, border.left, border.right }
    for _, e in ipairs(edges) do
        if e then e:SetAlpha(1) end
    end
end

-- ===== ANIMATION OVERLAYS =====
-- For the OnUpdate-driven custom effects (WIPE / RIPPLE / SEGMENT_REVEAL) we
-- render 4 dedicated overlay textures that sit immediately OUTSIDE the
-- border's outer edge — top overlay above the border's top, bottom below,
-- left to the left of the border's left, right to the right. The overlays
-- have their own thickness (anim.thickness) and colour (anim.color), so the
-- effect's visibility is INDEPENDENT of the border's own thickness. This
-- matches user expectation that picking "Wipe" at borderSize 1 still
-- produces an obvious sweeping highlight.
--
-- Overlays live on the OVERLAY draw layer so they render above the border
-- itself (BORDER layer in :New) and any shadow. Width is extended by
-- `thickness` at each end of the horizontal overlays so the corners join
-- cleanly with the vertical overlays without visible gaps.

-- Forward declaration. ensureAnimRect's body lives below the overlay setup
-- (where the inset/offset documentation reads more naturally next to the
-- overlay code that uses it). Declared up here so the closures in
-- setupAnimOverlay / applyCornersOnly / StartAnimation see the local
-- binding rather than falling through to a global lookup that returns nil.
local ensureAnimRect

local function ensureAnimOverlay(border)
    if border.animOverlay then return border.animOverlay end
    local o = {}
    o.top    = border:CreateTexture(nil, "OVERLAY")
    o.bottom = border:CreateTexture(nil, "OVERLAY")
    o.left   = border:CreateTexture(nil, "OVERLAY")
    o.right  = border:CreateTexture(nil, "OVERLAY")
    border.animOverlay = o
    return o
end

local function setupAnimOverlay(border, anim)
    local o = ensureAnimOverlay(border)
    local th = anim.thickness or 2
    if th < 1 then th = 1 end
    local rect = ensureAnimRect(border, anim.inset, anim.offsetX, anim.offsetY)

    -- Anchor each overlay just outside the animRect's matching edge, with
    -- ends extended by `th` so the corners visually overlap rather than
    -- showing 4 disjoint stripes with gaps. animRect carries the inset /
    -- offset adjustments, so the overlay positioning composes with the
    -- border's own offset without each overlay needing its own offset
    -- arithmetic.
    o.top:ClearAllPoints()
    o.top:SetPoint("BOTTOMLEFT",  rect, "TOPLEFT",  -th, 0)
    o.top:SetPoint("BOTTOMRIGHT", rect, "TOPRIGHT",  th, 0)
    o.top:SetHeight(th)

    o.bottom:ClearAllPoints()
    o.bottom:SetPoint("TOPLEFT",  rect, "BOTTOMLEFT",  -th, 0)
    o.bottom:SetPoint("TOPRIGHT", rect, "BOTTOMRIGHT",  th, 0)
    o.bottom:SetHeight(th)

    o.left:ClearAllPoints()
    o.left:SetPoint("TOPRIGHT",    rect, "TOPLEFT",     0,  th)
    o.left:SetPoint("BOTTOMRIGHT", rect, "BOTTOMLEFT",  0, -th)
    o.left:SetWidth(th)

    o.right:ClearAllPoints()
    o.right:SetPoint("TOPLEFT",    rect, "TOPRIGHT",    0,  th)
    o.right:SetPoint("BOTTOMLEFT", rect, "BOTTOMRIGHT", 0, -th)
    o.right:SetWidth(th)

    local r, g, b, a = readColor(anim.color or { r = 0.95, g = 0.95, b = 0.32, a = 1 })
    for _, e in ipairs({ o.top, o.bottom, o.left, o.right }) do
        e:SetColorTexture(r, g, b, a)
        e:SetAlpha(0)  -- tick functions raise alpha as the effect plays
        e:Show()
    end
    return o
end

local function hideAnimOverlay(border)
    if not border.animOverlay then return end
    for _, e in pairs(border.animOverlay) do e:Hide() end
end

-- 8-piece corner overlay set for CORNERS_ONLY. Lazy-created and parented to
-- the border on the OVERLAY draw layer (above the regular border edges).
-- Two textures per corner — a horizontal piece extending inward along the
-- top/bottom edge, and a vertical piece extending inward along the
-- left/right edge.
local function ensureCornerOverlays(border)
    if border.cornerOverlays then return border.cornerOverlays end
    local co = {}
    local names = { "tlh", "tlv", "trh", "trv", "blh", "blv", "brh", "brv" }
    for _, n in ipairs(names) do
        co[n] = border:CreateTexture(nil, "OVERLAY")
    end
    border.cornerOverlays = co
    return co
end

local function hideCornerOverlays(border)
    if not border.cornerOverlays then return end
    for _, e in pairs(border.cornerOverlays) do e:Hide() end
end

-- ===== DF_DASH (dashed / marching-ants border) =====
-- Ported from the unit-frame highlight system (Features/Highlights.lua) so
-- DF.Border can render a dashed border — static OR marching.  One effect: the
-- Animation Frequency is the march SPEED (0 = static "dashed", >0 = animated).
-- Draws a pool of dash textures per edge on the OVERLAY layer; the dashes use
-- the animation's own colour / thickness / inset, so a dashes-ONLY look is the
-- base Border Thickness 0 plus this effect.
local DF_DASH_LEN     = 6
local DF_DASH_GAP     = 6
local DF_DASH_PATTERN = DF_DASH_LEN + DF_DASH_GAP
local DF_DASH_SPEED   = 20   -- px/sec at frequency 1 (matches the highlight)

local function ensureDashPool(border)
    if border.dashPool then return border.dashPool end
    local function makeEdge(n)
        local t = {}
        for i = 1, n do
            local d = border:CreateTexture(nil, "OVERLAY")
            d:SetColorTexture(1, 1, 1, 1)
            d:Hide()
            t[i] = d
        end
        return t
    end
    border.dashPool = {
        top = makeEdge(24), bottom = makeEdge(24),
        left = makeEdge(24), right = makeEdge(24),
    }
    return border.dashPool
end

local function hideDashPool(border)
    if not border.dashPool then return end
    for _, edge in pairs(border.dashPool) do
        for _, d in ipairs(edge) do d:Hide() end
    end
end

local function drawDashEdgeH(border, dashes, isTop, edgeOffset, width, th, inset, r, g, b, a)
    local numDashes = math.ceil(width / DF_DASH_PATTERN) + 2
    for i = numDashes + 1, #dashes do dashes[i]:Hide() end
    local startPos = -(edgeOffset % DF_DASH_PATTERN)
    for i = 1, numDashes do
        local dashStart = startPos + (i - 1) * DF_DASH_PATTERN
        local visStart  = math.max(0, dashStart)
        local visEnd    = math.min(width, dashStart + DF_DASH_LEN)
        local d = dashes[i]
        if d and visEnd > visStart then
            d:ClearAllPoints()
            d:SetSize(visEnd - visStart, th)
            if isTop then
                d:SetPoint("TOPLEFT", border, "TOPLEFT", inset + visStart, -inset)
            else
                d:SetPoint("BOTTOMLEFT", border, "BOTTOMLEFT", inset + visStart, inset)
            end
            d:SetColorTexture(r, g, b, a)
            d:Show()
        elseif d then
            d:Hide()
        end
    end
end

local function drawDashEdgeV(border, dashes, isRight, edgeOffset, height, th, inset, r, g, b, a)
    local numDashes = math.ceil(height / DF_DASH_PATTERN) + 2
    for i = numDashes + 1, #dashes do dashes[i]:Hide() end
    local startPos = -(edgeOffset % DF_DASH_PATTERN)
    for i = 1, numDashes do
        local dashStart = startPos + (i - 1) * DF_DASH_PATTERN
        local visStart  = math.max(0, dashStart)
        local visEnd    = math.min(height, dashStart + DF_DASH_LEN)
        local d = dashes[i]
        if d and visEnd > visStart then
            d:ClearAllPoints()
            d:SetSize(th, visEnd - visStart)
            if isRight then
                d:SetPoint("TOPRIGHT", border, "TOPRIGHT", -inset, -inset - visStart)
            else
                d:SetPoint("TOPLEFT", border, "TOPLEFT", inset, -inset - visStart)
            end
            d:SetColorTexture(r, g, b, a)
            d:Show()
        elseif d then
            d:Hide()
        end
    end
end

-- Redraw all four edges' dashes at a marching offset (counter-clockwise:
-- bottom → left → top → right, matching the highlight system).
local function drawDashes(border, offset, th, inset, r, g, b, a)
    local pool = ensureDashPool(border)
    local fw, fh = border:GetWidth(), border:GetHeight()
    if not fw or not fh or fw <= 0 or fh <= 0 then return end
    local width  = fw - inset * 2
    local height = fh - inset * 2
    if width <= 0 or height <= 0 then return end
    drawDashEdgeH(border, pool.bottom, false, offset,                      width,  th, inset, r, g, b, a)
    drawDashEdgeV(border, pool.left,   false, width + offset,              height, th, inset, r, g, b, a)
    drawDashEdgeH(border, pool.top,    true,  width + height - offset,     width,  th, inset, r, g, b, a)
    drawDashEdgeV(border, pool.right,  true,  2 * width + height - offset, height, th, inset, r, g, b, a)
end

-- Shared positioning rectangle for animation effects: anchored to the
-- border itself (so animations follow the border's own offset/inset) and
-- adjusted by anim.inset / anim.offsetX / anim.offsetY for animation-
-- specific positioning. All three families route through this:
--   - LCG glows (Pulsate / Chase / Flash) use animRect as their LCG target,
--     so the glow renders at this rectangle's geometry.
--   - Overlays (Wipe / Ripple / Segment Reveal / Sides Only / Corners Only)
--     anchor to animRect instead of border directly.
-- This makes Inset / Offset X / Offset Y consistent with the border's own
-- equivalent controls — same mental model, same sign conventions.
--
-- Inset sign: positive = INWARD (smaller rect, animation closer to centre);
-- negative = OUTWARD (larger rect, animation further from centre).
-- Matches Border Inset semantics. The previous "Extent" parameter was an
-- outward-only inset (Inset = -Extent).
-- (forward-declared above with `local ensureAnimRect` so callers earlier in
-- the file resolve through the local binding.)
function ensureAnimRect(border, inset, offsetX, offsetY)
    inset    = inset    or 0
    offsetX  = offsetX  or 0
    offsetY  = offsetY  or 0
    if not border.animRect then
        border.animRect = CreateFrame("Frame", nil, border)
    end
    local f = border.animRect
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT",     border, "TOPLEFT",      inset + offsetX, -inset + offsetY)
    f:SetPoint("BOTTOMRIGHT", border, "BOTTOMRIGHT", -inset + offsetX,  inset + offsetY)
    f:Show()
    return f
end

-- ===== CUSTOM ONUPDATE TICKS =====
-- Each tick function receives (border, anim, elapsed) and modulates the 4
-- edge SetAlpha values. Period defaults to anim.frequency-derived; a
-- frequency of 0 / nil produces a sensible 2-second cycle.

local function tickPeriod(anim, default)
    local f = anim.frequency
    if not f or f == 0 then return default end
    return 1 / f
end

-- All three OnUpdate-driven custom effects modulate the OVERLAY textures
-- created by setupAnimOverlay (separate from the border's own edges), so
-- their visibility is independent of borderSize. The border underneath
-- stays unchanged while the animation plays on top of / outside it.

local customTicks = {}

-- WIPE: a bright "highlight" peak travels around the perimeter clockwise.
-- Each overlay has a centre-phase (0 / 0.25 / 0.5 / 0.75); its alpha is a
-- base level plus a triangular pulse that peaks when the cycle phase t
-- matches the overlay's centre. Wraps cleanly via circular distance.
customTicks.WIPE = function(border, anim, elapsed)
    local o = border.animOverlay; if not o then return end
    local period = tickPeriod(anim, 2)
    local t = (elapsed % period) / period
    local base, peak = 0.0, 1.0
    local function pulse(c)
        local d = math.abs(t - c)
        if d > 0.5 then d = 1 - d end
        local p = math.max(0, 1 - d * 4)
        return base + (peak - base) * p
    end
    if o.top    then o.top:SetAlpha(pulse(0))    end
    if o.right  then o.right:SetAlpha(pulse(0.25)) end
    if o.bottom then o.bottom:SetAlpha(pulse(0.5)) end
    if o.left   then o.left:SetAlpha(pulse(0.75))  end
end

-- RIPPLE: all overlays pulse alpha sinusoidally with phase offsets so the
-- ripple appears to spread outward from the top in both rotational
-- directions. WIPE has a sharp travelling peak; RIPPLE has a smoother
-- "breathing" pattern across all four overlays.
customTicks.RIPPLE = function(border, anim, elapsed)
    local o = border.animOverlay; if not o then return end
    local period = tickPeriod(anim, 1.5)
    local t = (elapsed % period) / period
    local base, amp = 0.2, 0.8
    local twoPi = 2 * math.pi
    local function wave(phase) return base + amp * (0.5 + 0.5 * math.sin(twoPi * (t + phase))) end
    if o.top    then o.top:SetAlpha(wave(0))      end
    if o.right  then o.right:SetAlpha(wave(0.25)) end
    if o.bottom then o.bottom:SetAlpha(wave(0.5)) end
    if o.left   then o.left:SetAlpha(wave(0.25))  end  -- mirrors right
end

-- SEGMENT_REVEAL: overlays fade in one at a time (top → right → bottom →
-- left) over the period, then all fade out together in the last 15% of
-- the cycle before looping.
customTicks.SEGMENT_REVEAL = function(border, anim, elapsed)
    local o = border.animOverlay; if not o then return end
    local period = tickPeriod(anim, 2.5)
    local t = (elapsed % period) / period
    local order = { o.top, o.right, o.bottom, o.left }
    local revealSegment = 0.8
    local fadeStart = 0.85
    local perEdge = revealSegment / 4
    for i, e in ipairs(order) do
        if e then
            local segStart = (i - 1) * perEdge
            if t < segStart then
                e:SetAlpha(0)
            elseif t >= fadeStart then
                local fade = (t - fadeStart) / (1 - fadeStart)
                e:SetAlpha(math.max(0, 1 - fade))
            else
                local local_t = (t - segStart) / perEdge
                e:SetAlpha(math.min(1, local_t))
            end
        end
    end
end

-- ===== STATIC SHAPE MODES =====

-- SIDES_ONLY: reveal the overlay textures (anim.thickness, anim.color) on
-- one perpendicular pair only. The underlying border edges stay at full
-- alpha so the user's border is still visible underneath. Earlier rev
-- modulated SetAlpha on the edges themselves, but at borderSize 1 the
-- visible result was nearly nothing; using overlays makes the effect
-- visible regardless of border thickness.
local function applySidesOnly(border, anim)
    local o = setupAnimOverlay(border, anim)
    local axis = anim.sidesAxis or "HORIZONTAL"
    if axis == "HORIZONTAL" then
        o.top:SetAlpha(1);    o.bottom:SetAlpha(1)
        o.left:SetAlpha(0);   o.right:SetAlpha(0)
    else
        o.top:SetAlpha(0);    o.bottom:SetAlpha(0)
        o.left:SetAlpha(1);   o.right:SetAlpha(1)
    end
end

-- CORNERS_ONLY: 8 overlay pieces — 2 per corner (one horizontal extending
-- inward from the corner along the top/bottom edge, one vertical
-- extending inward along the left/right edge). Anchored just outside the
-- border itself (matches setupAnimOverlay's pattern) so thickness
-- (anim.thickness) is independent of borderSize. anim.cornerLength
-- controls how far each piece extends along its edge; default 8 pixels.
local function applyCornersOnly(border, anim)
    local co = ensureCornerOverlays(border)
    local th = anim.thickness or 2
    if th < 1 then th = 1 end
    local length = anim.cornerLength
    if not length or length <= 0 then length = 8 end
    local rect = ensureAnimRect(border, anim.inset, anim.offsetX, anim.offsetY)

    local r, g, b, a = readColor(anim.color or { r = 0.95, g = 0.95, b = 0.32, a = 1 })
    local function paint(e)
        e:SetColorTexture(r, g, b, a)
        e:SetAlpha(1)
        e:Show()
    end

    -- All 8 corner pieces anchor to animRect (which carries inset/offset),
    -- not directly to border — matches the setupAnimOverlay pattern.
    co.tlh:ClearAllPoints()
    co.tlh:SetPoint("BOTTOMLEFT", rect, "TOPLEFT", -th, 0)
    co.tlh:SetSize(length + th, th)
    paint(co.tlh)
    co.tlv:ClearAllPoints()
    co.tlv:SetPoint("TOPRIGHT",  rect, "TOPLEFT", 0,  th)
    co.tlv:SetSize(th, length + th)
    paint(co.tlv)

    co.trh:ClearAllPoints()
    co.trh:SetPoint("BOTTOMRIGHT", rect, "TOPRIGHT", th, 0)
    co.trh:SetSize(length + th, th)
    paint(co.trh)
    co.trv:ClearAllPoints()
    co.trv:SetPoint("TOPLEFT",  rect, "TOPRIGHT", 0,  th)
    co.trv:SetSize(th, length + th)
    paint(co.trv)

    co.blh:ClearAllPoints()
    co.blh:SetPoint("TOPLEFT", rect, "BOTTOMLEFT", -th, 0)
    co.blh:SetSize(length + th, th)
    paint(co.blh)
    co.blv:ClearAllPoints()
    co.blv:SetPoint("BOTTOMRIGHT",  rect, "BOTTOMLEFT", 0, -th)
    co.blv:SetSize(th, length + th)
    paint(co.blv)

    co.brh:ClearAllPoints()
    co.brh:SetPoint("TOPRIGHT", rect, "BOTTOMRIGHT", th, 0)
    co.brh:SetSize(length + th, th)
    paint(co.brh)
    co.brv:ClearAllPoints()
    co.brv:SetPoint("BOTTOMLEFT",  rect, "BOTTOMRIGHT", 0, -th)
    co.brv:SetSize(th, length + th)
    paint(co.brv)
end

-- Stop every LCG glow we might have started AND tear down any custom
-- animator state. Cheap: each Stop is a no-op when its glow frame isn't
-- present; the driver Hide is a no-op when no driver exists.
function Border:StopAnimation(border)
    if not border then return end
    -- Cancel any pending deferred LCG glow start (see StartAnimation) so a glow
    -- scheduled but not yet shown never fires after a stop.
    border._lcgStartToken = nil
    local LCG = getLCG()
    if LCG then
        local key = "DFBorder"
        -- Stop on BOTH the raw anchor AND the animRect wrapper since either
        -- could have been the last LCG target. Each Stop is a cheap no-op
        -- when its glow frame isn't present. (`glowExtent` is the legacy
        -- field from the pre-rename revision and is checked for users
        -- mid-upgrade who might still have a glow running on the old frame.)
        local anchor = border.anchorTo or border
        local function stopAll(t)
            -- Reset a reused ProcGlow frame's textures BEFORE releasing it.
            -- LCG's pool resetter only hides the frame + clears the reference;
            -- it leaves the ProcStart (big start-flash) / ProcLoop (small loop)
            -- texture visibility intact. So a frame re-acquired from the pool
            -- could come back with BOTH textures showing — the double glow
            -- (one inset, one further out) seen on alternate re-applies. Stop
            -- the animation groups and clear both textures so the next Acquire
            -- (and its OnShow) starts from a clean state.
            local pg = t and t["_ProcGlow" .. key]
            if pg then
                if pg.ProcStartAnim then pg.ProcStartAnim:Stop() end
                if pg.ProcLoopAnim  then pg.ProcLoopAnim:Stop()  end
                if pg.ProcStart then pg.ProcStart:SetAlpha(0); pg.ProcStart:Hide() end
                if pg.ProcLoop  then pg.ProcLoop:SetAlpha(0);  pg.ProcLoop:Hide()  end
            end
            if LCG.PixelGlow_Stop    then LCG.PixelGlow_Stop(t, key)    end
            if LCG.AutoCastGlow_Stop then LCG.AutoCastGlow_Stop(t, key) end
            if LCG.ButtonGlow_Stop   then LCG.ButtonGlow_Stop(t)        end
            if LCG.ProcGlow_Stop     then LCG.ProcGlow_Stop(t, key)     end
        end
        stopAll(anchor)
        if border.animRect    then stopAll(border.animRect)    end
        if border.glowExtent  then stopAll(border.glowExtent)  end
    end
    if border.animDriver then
        border.animDriver:SetScript("OnUpdate", nil)
        border.animDriver:Hide()
        border.animDriver.elapsed = 0
    end
    -- Hide all overlay sets from prior animation passes. The cornerExtras
    -- field is from a previous-rev CORNERS_ONLY implementation; we keep
    -- the Hide-loop for backward compat on profiles where the field was
    -- already populated, then mark it nil so it's not referenced again.
    hideAnimOverlay(border)
    hideCornerOverlays(border)
    hideDashPool(border)
    if border.cornerExtras then
        for _, e in ipairs(border.cornerExtras) do e:Hide() end
        border.cornerExtras = nil
    end
    border.cornersOnlyActive = nil
    resetEdgeAlphas(border)
    -- DF_PULSATE modulates the container frame's alpha (not per-edge); restore
    -- the container alpha to 1 so a NONE / different effect renders at full
    -- opacity -- but ONLY when such an animation was actually running.
    --
    -- The container alpha is ALSO the carrier for the range system's
    -- out-of-range fade (ApplyOORAlpha -> border:SetAlpha / SetAlphaFromBoolean
    -- on the wrapper, in element-specific OOR mode). Apply() ends EVERY
    -- non-animated render in StopAnimation, so resetting the alpha
    -- unconditionally clobbered that OOR fade: out-of-range borders flashed to
    -- full opacity on each re-render -- most visibly in the burst of relayouts
    -- when joining a raid whose members are in another zone -- until the next
    -- range tick re-dimmed them. DF_PULSATE is the only effect that touches the
    -- wrapper alpha (every other effect uses per-edge alpha / overlays / LCG
    -- glow), and activeAnimation still holds the prior effect here (it's cleared
    -- just below), so gate the reset on it.
    if border.activeAnimation == "DF_PULSATE" and border.SetAlpha then
        border:SetAlpha(1)
    end
    border.activeAnimation = nil
    border._animHash = nil  -- ensure the next StartAnimation runs the full path
end

-- Build a comparable hash of the animation spec so StartAnimation can no-op
-- when called with the same config the border is already running.  Consumer
-- refresh paths (AD's RefreshLiveFramesThrottled bumps adConfigVersion → next
-- UpdateFrame calls Configure on every visible AD-enabled frame → Apply on
-- every border → StartAnimation) fire many times per second.  Without this
-- dedupe, every call ran StopAnimation which reset the OnUpdate driver's
-- elapsed counter to 0 — DF_PULSATE in particular got stuck near phase 0
-- (visibly: a dim border that never pulsed back up to full alpha).
local function animSpecHash(anim)
    if not anim then return "nil" end
    local c = anim.color
    local cr = (c and (c.r or c[1])) or "_"
    local cg = (c and (c.g or c[2])) or "_"
    local cb = (c and (c.b or c[3])) or "_"
    local ca = (c and (c.a or c[4])) or "_"
    return table.concat({
        tostring(anim.type),
        tostring(anim.frequency), tostring(anim.particles),
        tostring(anim.length),    tostring(anim.thickness),
        tostring(anim.scale),
        tostring(anim.inset),     tostring(anim.offsetX), tostring(anim.offsetY),
        tostring(anim.mask),
        tostring(anim.sidesAxis), tostring(anim.cornerLength),
        tostring(anim.procStart),
        tostring(cr), tostring(cg), tostring(cb), tostring(ca),
    }, "|")
end

-- OnUpdate-driver effects: those whose motion is driven by border.animDriver's
-- OnUpdate (as opposed to LCG glows or the static shape modes). The dedupe in
-- StartAnimation verifies the driver is actually live for these before no-opping.
local DRIVER_ANIMS = { DF_DASH = true, WIPE = true, RIPPLE = true, SEGMENT_REVEAL = true, DF_PULSATE = true }

function Border:StartAnimation(border, spec)
    if not border or not spec or not spec.animation then
        self:StopAnimation(border); return
    end
    local anim = spec.animation
    if not anim.type or anim.type == "NONE" then
        self:StopAnimation(border); return
    end

    -- No-op when the same animation is already running with the same spec.
    -- Prevents redundant Stop+Start cycles from resetting elapsed-based
    -- effects mid-cycle.  Cleared by StopAnimation so a NONE → effect
    -- transition (or any genuine spec change) still goes through the full
    -- restart path below.
    local newHash = animSpecHash(anim)
    -- No-op when the same spec is already running — BUT only if the effect is
    -- genuinely still live. For OnUpdate-driver effects the hash can stay stamped
    -- while the driver has stopped (e.g. an AD border re-applied across a
    -- hide/show or pooled-icon cycle), and trusting the hash alone then leaves the
    -- animation frozen until a real spec change forces a restart (the "move the
    -- frequency slider off 1 and back" symptom). When the driver is dead, fall
    -- through and restart instead of no-opping.
    if border._animHash == newHash then
        local d = border.animDriver
        if not DRIVER_ANIMS[border.activeAnimation]
           or (d and d:IsShown() and d:GetScript("OnUpdate")) then
            return
        end
    end

    -- DF_PULSATE retune-in-place: the spec changed, but if a DF Pulsate is
    -- already running on this border, NEVER tear it down — just update its
    -- period.  A frequency change (or any unrelated spec churn from a
    -- consumer's refresh loop) then adjusts the pulse SPEED only.  This avoids
    -- two flicker sources:
    --   * StopAnimation sets border:SetAlpha(1) — a one-frame flash to full
    --     bright before the driver's OnUpdate resumes.
    --   * The OnUpdate accumulates PHASE (not absolute elapsed), so changing
    --     the period changes how fast the phase advances but never makes the
    --     phase value jump — the fade is never clipped or restarted mid-cycle.
    if anim.type == "DF_PULSATE" and border.activeAnimation == "DF_PULSATE" then
        local rawFreq = (anim.frequency and anim.frequency > 0) and anim.frequency or 1
        border._dfPulsatePeriod = 2 / rawFreq
        border._animHash = newHash
        return
    end
    -- Always clear before starting — see "Stop semantics" in the section
    -- header above.  StopAnimation NILs border._animHash, so the hash MUST be
    -- stamped AFTER it — otherwise every full start leaves the hash nil and the
    -- next Apply (AD re-applies ~3×/sec via the expiring ticker) mismatches and
    -- restarts the effect, making LCG glows (PROC etc.) flash over and over.
    self:StopAnimation(border)
    border._animHash = newHash

    -- LCG-driven effects (PULSATE / CHASE / FLASH). Glow target is the
    -- shared animRect (positioned by anim.inset / anim.offsetX/Y), so glow
    -- inset/offset works the same way as overlay inset/offset. Pulsate's
    -- `mask` (the dark backing card) is OFF by default now — earlier rev
    -- passed `true` unconditionally, which produced a visible dark square
    -- behind the particle ring that users didn't want.
    local LCG = getLCG()
    if LCG and (anim.type == "PULSATE" or anim.type == "CHASE" or anim.type == "FLASH" or anim.type == "PROC") then
        ensureAnimRect(border, anim.inset, anim.offsetX, anim.offsetY)
        local key = "DFBorder"
        local color
        if anim.color then
            local r, g, b, a = readColor(anim.color)
            color = { r, g, b, a }
        end
        -- The Animation Frequency slider can now reach 0 (so DF_DASH can be
        -- static).  LCG glows treat 0 as invalid, so pass nil → LCG uses its
        -- own default rate for these effects.
        local freq = (anim.frequency and anim.frequency > 0) and anim.frequency or nil

        -- The LCG glow reads its target's width/height at Start. On the very
        -- first attach the animRect was only just created, so the layout engine
        -- hasn't sized it yet (GetWidth() == 0) — the glow then renders huge /
        -- detached for one frame (the "full-screen flash"). Start it only once
        -- the target has a real size; if it isn't laid out yet, defer to the next
        -- frame (after the layout pass). A per-start token — replaced by a newer
        -- Start and cleared by StopAnimation — guarantees a deferred start that
        -- was superseded or stopped in the meantime never fires.
        local token = {}
        border._lcgStartToken = token
        local function startGlow()
            if border._lcgStartToken ~= token then return end
            local target = border.animRect
            if not target then return end
            if anim.type == "PULSATE" then
                -- PixelGlow `border` arg: false → no outer mask. anim.mask = true
                -- restores the backing card for users who want that look.
                local mask = anim.mask and true or false
                LCG.PixelGlow_Start(target, color, anim.particles, freq,
                    anim.length, anim.thickness, 0, 0, mask, key)
            elseif anim.type == "CHASE" then
                LCG.AutoCastGlow_Start(target, color, anim.particles, freq,
                    anim.scale, 0, 0, key)
            elseif anim.type == "FLASH" then
                LCG.ButtonGlow_Start(target, color, freq)
            elseif anim.type == "PROC" then
                -- ProcGlow takes an options table; map frequency → duration
                -- (1/freq = seconds-per-cycle) so its slider behaves like the
                -- other effects' Frequency control (cycles per second).
                local duration = (anim.frequency and anim.frequency > 0)
                    and (1 / anim.frequency) or 1
                -- The one-shot "proc start" flash is OPT-IN (anim.procStart).
                -- Default off: PROC is used here as a CONTINUOUS border animation
                -- that re-applies often, and the flash (begins large, shrinks to
                -- the border) re-fires on every re-apply — on rapid re-toggle the
                -- big start texture lingers alongside the loop, rendering two
                -- glows at two sizes. With it on, normal single-cast use plays it
                -- cleanly; only rapid re-toggling can double it.
                LCG.ProcGlow_Start(target, {
                    color     = color,
                    duration  = duration,
                    startAnim = anim.procStart and true or false,
                    key       = key,
                })
            end
        end

        if (border.animRect:GetWidth() or 0) > 0 then
            startGlow()
        else
            C_Timer.After(0, startGlow)
        end
        border.activeAnimation = anim.type
        return
    end

    -- Custom OnUpdate effects — render their own overlay textures, so the
    -- effect's visibility doesn't depend on the border's own thickness.
    local tick = customTicks[anim.type]
    if tick then
        setupAnimOverlay(border, anim)
        local d = ensureDriver(border)
        d.elapsed = 0
        d:Show()
        d:SetScript("OnUpdate", function(self, dt)
            self.elapsed = (self.elapsed or 0) + dt
            tick(border, anim, self.elapsed)
        end)
        border.activeAnimation = anim.type
        return
    end

    -- DF Pulsate: soft alpha fade pulse on the border's 4 edges.  Distinct
    -- from the LCG-driven Pulsate (which surrounds the border with a
    -- particle ring) — DF_PULSATE keeps the border itself visible and just
    -- fades its opacity smoothly between 0.05 and 1.0.  Inherited from
    -- AD's legacy expiring border pulse; exposed as a first-class animation
    -- type so it works as either a continuous Border Animation OR as the
    -- value the new Expiring Animation dropdown will swap in below
    -- threshold (Stage 5.1d.2+).  Uses ensureDriver's OnUpdate frame; on
    -- StopAnimation the existing resetEdgeAlphas() restores the edges
    -- back to alpha 1 so the next render is clean.
    if anim.type == "DF_PULSATE" then
        -- Frequency mapping is per-type.  LCG glow types interpret frequency
        -- as cycles-per-second of a particle animation; that maps 1:1 to the
        -- slider.  DF_PULSATE is a gentle alpha fade and reads better at
        -- ~half that rate, so we use period = 2 / freq.  Result:
        --   slider 0.5 → 4 s cycle (slow, ambient)
        --   slider 1.0 → 2 s cycle (matches the old AD legacy pulse rate)
        --   slider 2.0 → 1 s cycle (snappy)
        --   slider 4.0 → 0.5 s cycle (urgent)
        -- Users still get the full slider range; the scale just shifts so the
        -- default settles on a comfortable 2-second cycle.
        local rawFreq = (anim.frequency and anim.frequency > 0) and anim.frequency or 1
        -- Store period as a FIELD (not a closure upvalue) so the retune-in-place
        -- path at the top of StartAnimation can change the pulse speed on the
        -- already-running driver without re-SetScript'ing.
        border._dfPulsatePeriod = 2 / rawFreq
        local d = ensureDriver(border)
        d:Show()
        -- Advance a PHASE accumulator in [0,1) by dt/period each frame rather
        -- than deriving phase from absolute elapsed.  Two consequences:
        --   * Changing the period (frequency) only changes how fast the phase
        --     advances — the phase value itself stays continuous, so the fade
        --     never jumps or clips when the user drags Frequency.
        --   * The phase persists on the border across genuine restarts, so a
        --     NONE→DF_PULSATE or other→DF_PULSATE transition resumes the pulse
        --     from where it left off instead of snapping to the dim trough.
        -- wave = (1 - cos(2π·phase)) / 2 is a smooth 0→1→0 (full→low→full)
        -- curve with zero-slope endpoints, so each cycle blends seamlessly
        -- into the next with no visible seam at the loop point.
        d:SetScript("OnUpdate", function(self, dt)
            local p = border._dfPulsatePeriod or 2
            local ph = ((border._dfPulsatePhase or 0) + dt / p) % 1
            border._dfPulsatePhase = ph
            local wave = (1 - math.cos(ph * 2 * math.pi)) * 0.5
            -- Fade between 0.05 (dim trough) and 1.0 (full) — a gentle pulse.
            -- DF_PULSATE is the one effect that drives the widget's OWN alpha each
            -- frame, so it would clobber the range system's out-of-range fade
            -- (which dims the widget via SetAlpha). Multiply by dfRangeAlpha (set
            -- by the OOR appearance pass; defaults to 1 when in range / unset) so
            -- the pulse rides on top of the OOR dim instead of overwriting it.
            border:SetAlpha((0.05 + 0.95 * wave) * (border.dfRangeAlpha or 1))
        end)
        border.activeAnimation = anim.type
        return
    end

    -- DF Dash: a dashed border, static or marching.  Animation Frequency is the
    -- march SPEED — 0 = static ("dashed"), > 0 = marching ants ("animated").
    -- Dashes use the animation's own colour / thickness / inset (so a
    -- dashes-only look = base Border Thickness 0 + this effect).
    if anim.type == "DF_DASH" then
        -- Store the dash params as FIELDS so RecolorActive can recolour a
        -- running DF_DASH in place (the expiring ticker recolours ~3×/sec; a
        -- restart would tear down + redraw every dash each tick).
        local r, g, b, a = readColor(anim.color or { r = 0.95, g = 0.95, b = 0.32, a = 1 })
        border._dfDashTh = math.max(1, anim.thickness or 2)
        border._dfDashInset = anim.inset or 0
        border._dfDashR, border._dfDashG, border._dfDashB, border._dfDashA = r, g, b, a
        local rawFreq = anim.frequency or 0
        local marchSpeed = (rawFreq and rawFreq > 0) and (rawFreq * DF_DASH_SPEED) or 0
        if marchSpeed > 0 then
            -- Marching: OnUpdate advances the offset, reading colour/size from
            -- the fields so a live recolour is picked up next tick.  elapsed
            -- persists across restarts so a spec change doesn't snap the ants.
            local d = ensureDriver(border)
            d.elapsed = border._dfDashElapsed or 0
            d:Show()
            d:SetScript("OnUpdate", function(self, dt)
                self.elapsed = (self.elapsed or 0) + dt
                border._dfDashElapsed = self.elapsed
                local offset = (self.elapsed * marchSpeed) % DF_DASH_PATTERN
                drawDashes(border, offset, border._dfDashTh, border._dfDashInset,
                    border._dfDashR, border._dfDashG, border._dfDashB, border._dfDashA)
            end)
        else
            -- Static: draw once, no driver (cheaper).
            drawDashes(border, 0, border._dfDashTh, border._dfDashInset, r, g, b, a)
        end
        border.activeAnimation = anim.type
        return
    end

    -- Static shape modes — also render via overlays (not the border edges
    -- themselves) so they're visible at borderSize 1.
    if anim.type == "SIDES_ONLY" then
        applySidesOnly(border, anim)
        border.activeAnimation = anim.type
    elseif anim.type == "CORNERS_ONLY" then
        applyCornersOnly(border, anim)
        border.activeAnimation = anim.type
    end
end

-- Recolour the border AND whatever animation is currently running, WITHOUT a
-- restart.  The expiring ticker calls this ~3×/sec; routing through
-- StartAnimation would re-hash, Stop (tearing down every dash / overlay) and
-- redraw each tick.  Recolours: base edges (via SetColor), DF_DASH dashes
-- (field + live textures), CORNERS_ONLY / SIDES_ONLY corner-overlay textures,
-- and the WIPE/RIPPLE/SEGMENT_REVEAL overlays.  LCG glows (Pulsate/Chase/
-- Flash/Proc) can't be recoloured live by LCG, so they keep their colour (the
-- expiring tint still applies to the edges underneath).
function Border:RecolorActive(border, r, g, b, a)
    if not border then return end
    a = a or 1
    if border.SetColor then border:SetColor(r, g, b, a) end
    local active = border.activeAnimation
    if active == "DF_DASH" then
        border._dfDashR, border._dfDashG, border._dfDashB, border._dfDashA = r, g, b, a
        if border.dashPool then
            for _, edge in pairs(border.dashPool) do
                for _, d in ipairs(edge) do
                    if d:IsShown() then d:SetColorTexture(r, g, b, a) end
                end
            end
        end
    elseif active == "CORNERS_ONLY" or active == "SIDES_ONLY" then
        if border.cornerOverlays then
            for _, e in pairs(border.cornerOverlays) do e:SetColorTexture(r, g, b, a) end
        end
        if border.animOverlay then
            for _, e in pairs(border.animOverlay) do e:SetColorTexture(r, g, b, a) end
        end
    elseif border.animOverlay then
        for _, e in pairs(border.animOverlay) do e:SetColorTexture(r, g, b, a) end
    end
end

-- (Re)configure a border widget from a spec.
-- spec:
--   enabled       false hides the border entirely (default: true)
--   style         "SOLID" | "GRADIENT" | "TEXTURE" (default: "SOLID").
--                 GRADIENT and TEXTURE are mutually exclusive presentations of
--                 the border — the GUI exposes them all in a single Border
--                 Style dropdown so only one can be active at a time.
--   texture       LibSharedMedia border key (used only in TEXTURE style)
--   size          edge thickness / backdrop edgeSize (default: 1)
--   color         {r,g,b,a} or {r=,g=,b=,a=}; alpha lives in the colour
--   inset         signed pixels: positive moves edges INSIDE the parent's
--                 bounds; negative moves them outside. Default 0 (edges flush
--                 with parent corners as set up in :New). Honoured only in
--                 the SOLID 4-edge mode — backdrop-template mode anchors the
--                 backdrop child via SetPoint(-1,1)/(1,-1) implicitly.
--   offsetX       signed pixels: translates the WHOLE border widget along the
--                 X axis (positive = right). Independent of `inset`, which
--                 changes the border's relationship to its own bounds.
--   offsetY       signed pixels: translates the WHOLE border widget along the
--                 Y axis (positive = up, matching WoW UI convention used by
--                 other DF offset sliders). Works in both SOLID and TEXTURE
--                 modes because we translate the widget itself, not the edges.
--   blendMode     "BLEND" (default) | "ADD" | "DISABLE" | "MOD" — Blizzard
--                 texture blend modes. Applied per-edge in SOLID mode. TEXTURE
--                 mode renders through a BackdropTemplate whose edge textures
--                 aren't directly accessible to SetBlendMode, so the value is
--                 silently ignored there.
--   gradient      Optional. { enabled = true, startColor, endColor,
--                 direction = "HORIZONTAL"|"VERTICAL" }. When enabled, the two
--                 edges parallel to the gradient axis use Texture:SetGradient;
--                 the two perpendicular edges paint as solid startColor (one
--                 side) and endColor (the other), so the overall border reads
--                 as one continuous gradient across the unit. SOLID mode only;
--                 TEXTURE mode ignores. When disabled/missing, spec.color is
--                 used as a normal solid border.
--   shadow        Optional. { enabled = true, color, size, offsetX, offsetY }.
--                 A solid 4-edge ring rendered one frameLevel below the
--                 border itself, translated by (offsetX, offsetY) relative to
--                 the border's own anchorTo. Independent of border mode: a
--                 textured border still gets a solid shadow ring behind it.
--                 The shadow widget is lazy-created on first use and reused
--                 thereafter; spec.shadow nil/disabled simply hides it.
--   pixelPerfect  snap size and inset to whole screen pixels
function Border:Apply(border, spec)
    if not border then return end
    spec = spec or {}
    local edges = { border.top, border.bottom, border.left, border.right }

    -- Translate the whole border widget by (offsetX, offsetY). Two opposite
    -- corners fully constrain a rectangle in WoW, so two SetPoint calls suffice
    -- and idempotently replace :New's SetAllPoints when offsets are zero.
    local offsetX = spec.offsetX or 0
    local offsetY = spec.offsetY or 0
    if border.anchorTo then
        border:ClearAllPoints()
        border:SetPoint("TOPLEFT",     border.anchorTo, "TOPLEFT",     offsetX, offsetY)
        border:SetPoint("BOTTOMRIGHT", border.anchorTo, "BOTTOMRIGHT", offsetX, offsetY)
    end

    -- Hidden border: hide both modes (after the offset re-anchor so a later
    -- :Apply that re-enables the border picks up the same translation).
    if spec.enabled == false then
        for _, e in ipairs(edges) do if e then e:Hide() end end
        if border.bd then border.bd:Hide() end
        border.activeTexture = nil
        -- Tear down any running glow when the border is hidden, otherwise
        -- the LCG glow keeps rendering around the unit with no visible
        -- border underneath it.
        self:StopAnimation(border)
        return
    end

    local size = spec.size or 1
    local inset = spec.inset or 0
    if spec.pixelPerfect and DF.PixelPerfect then
        size = DF:PixelPerfect(size)
        if inset ~= 0 then inset = DF:PixelPerfect(inset) end
    end
    local cr, cg, cb, ca = readColor(spec.color)

    -- Style drives the render path: SOLID (4 colour edges), GRADIENT (4 edges
    -- with two carrying SetGradient and two solid in the start/end colours),
    -- TEXTURE (BackdropTemplate edgeFile). TEXTURE silently falls back to
    -- SOLID if the LSM key can't be resolved, so the border never vanishes.
    local style = spec.style or "SOLID"
    local texture = spec.texture
    local edgeFile = (style == "TEXTURE" and texture and texture ~= "" and texture ~= "SOLID" and DF.GetBorderTexturePath)
        and DF:GetBorderTexturePath(texture) or nil

    if not edgeFile then
        -- SOLID or GRADIENT — both render via the 4-edge mode. Texture mode
        -- silently degrades to SOLID here when the LSM key isn't resolvable.
        border.activeTexture = nil
        if border.bd then border.bd:Hide() end

        -- Re-anchor edges so inset takes effect (and so going inset != 0 → 0
        -- restores the flush layout). Done on every Apply: it's four cheap
        -- SetPoint pairs and avoids a "needs ClearAllPoints first time only"
        -- footgun. The corner overlap pattern (top/bottom span the full width;
        -- left/right are inset by `size` at top/bottom) matches :New's defaults.
        border.top:ClearAllPoints()
        border.top:SetPoint("TOPLEFT", inset, -inset)
        border.top:SetPoint("TOPRIGHT", -inset, -inset)
        border.top:SetHeight(size)

        border.bottom:ClearAllPoints()
        border.bottom:SetPoint("BOTTOMLEFT", inset, inset)
        border.bottom:SetPoint("BOTTOMRIGHT", -inset, inset)
        border.bottom:SetHeight(size)

        border.left:ClearAllPoints()
        border.left:SetPoint("TOPLEFT", inset, -inset - size)
        border.left:SetPoint("BOTTOMLEFT", inset, inset + size)
        border.left:SetWidth(size)

        border.right:ClearAllPoints()
        border.right:SetPoint("TOPRIGHT", -inset, -inset - size)
        border.right:SetPoint("BOTTOMRIGHT", -inset, inset + size)
        border.right:SetWidth(size)

        local blendMode = spec.blendMode or "BLEND"
        -- Remember it so SetColor (live recolour, e.g. expiring / OOR) can
        -- re-assert it — SetColorTexture can drop a non-default blend mode.
        border._blendMode = blendMode
        local gradient = spec.gradient
        if style == "GRADIENT" and gradient and CreateColor then
            -- Two parallel edges carry the gradient via SetGradient; the two
            -- perpendicular edges are painted in pure startColor / endColor
            -- so the four edges read as one continuous gradient.
            local sr, sg, sb, sa = readColor(gradient.startColor)
            local er, eg, eb, ea = readColor(gradient.endColor)
            local startMixin = CreateColor(sr, sg, sb, sa)
            local endMixin   = CreateColor(er, eg, eb, ea)
            local direction  = gradient.direction or "HORIZONTAL"

            -- Treat every edge — gradient-bearing OR solid cap — through the
            -- SAME two-call pattern: SetColorTexture(white) base, then
            -- SetGradient with the stops. For a solid cap, the stops are the
            -- same colour twice, which renders solid. This avoids the
            -- order-dependent SetColorTexture↔SetGradient interaction that
            -- left stale gradient state visible when swapping directions in
            -- the GUI (visible as "side caps with a horizontal gradient" in
            -- VERTICAL mode after the user had been on HORIZONTAL).
            local solidStart = CreateColor(sr, sg, sb, sa)
            local solidEnd   = CreateColor(er, eg, eb, ea)

            for _, e in ipairs(edges) do
                e:SetColorTexture(1, 1, 1, 1)
            end

            if direction == "HORIZONTAL" then
                -- WoW HORIZONTAL: min = LEFT, max = RIGHT. start→end naturally
                -- maps to left→right, no swap.
                border.top:SetGradient(   "HORIZONTAL", startMixin, endMixin)
                border.bottom:SetGradient("HORIZONTAL", startMixin, endMixin)
                border.left:SetGradient(  "HORIZONTAL", solidStart, solidStart)
                border.right:SetGradient( "HORIZONTAL", solidEnd,   solidEnd)
            else
                -- WoW VERTICAL: min = BOTTOM, max = TOP. The user picked
                -- start expecting it at the TOP of the gradient, so the
                -- arguments are swapped relative to HORIZONTAL — endMixin
                -- as min (bottom), startMixin as max (top).
                border.top:SetGradient(   "VERTICAL",   solidStart, solidStart)
                border.bottom:SetGradient("VERTICAL",   solidEnd,   solidEnd)
                border.left:SetGradient(  "VERTICAL",   endMixin,   startMixin)
                border.right:SetGradient( "VERTICAL",   endMixin,   startMixin)
            end
            for _, e in ipairs(edges) do
                e:SetBlendMode(blendMode)
                e:Show()
            end
        else
            -- Clear any leftover gradient state from a prior gradient-mode call
            -- before reverting to solid. Setting a constant-colour gradient is
            -- the reliable cross-version way to do this; SetColorTexture alone
            -- can leave the previous min/max colour interpolation in place on
            -- some Blizzard texture pipelines.
            -- solidOnly borders never enter the GRADIENT branch, so there's
            -- nothing to clear — skip it so the edges carry no gradient and a
            -- later bare-SetColorTexture recolour stays clean and secret-safe.
            if not border._solidOnly and CreateColor then
                -- Reset any leftover gradient before the solid SetColorTexture.
                -- Use the real colour when non-secret (so a Blizzard pipeline that
                -- leaves the gradient in place stays correct), but fall back to
                -- white when ANY channel is SECRET — on the expiring path in combat
                -- the colour curve resolves through the aura's secret Duration
                -- object, and CreateColor on a secret makes SetGradient throw "bad
                -- argument #2". SetColorTexture below paints the real, secret-safe
                -- colour either way.
                local clear = (issecretvalue(cr) or issecretvalue(cg) or issecretvalue(cb) or issecretvalue(ca))
                    and CreateColor(1, 1, 1, 1) or CreateColor(cr, cg, cb, ca)
                for _, e in ipairs(edges) do
                    if e.SetGradient then e:SetGradient("HORIZONTAL", clear, clear) end
                end
            end
            for _, e in ipairs(edges) do
                e:SetColorTexture(cr, cg, cb, ca)
                e:SetBlendMode(blendMode)
                e:Show()
            end
        end
        -- Thickness 0 collapses the edges to zero width/height; hide them
        -- outright so a degenerate texture can't leave a hairline. Animation
        -- overlays are separate frames and keep running (they're gated by the
        -- border being shown, not by thickness).
        if size <= 0 then
            for _, e in ipairs(edges) do if e then e:Hide() end end
        end
    else
        -- Texture mode: a BackdropTemplate child with the LSM border edgeFile.
        -- spec.blendMode is intentionally ignored here — see doc above.
        for _, e in ipairs(edges) do if e then e:Hide() end end
        if not border.bd then
            border.bd = CreateFrame("Frame", nil, border, "BackdropTemplate")
        end
        local bd = border.bd
        -- Re-anchor with the inset offsets on every Apply so texture borders honour
        -- BorderInset and update live, matching the solid/gradient edges above.
        -- (Previously SetAllPoints(border) once at creation: inset was ignored and
        -- never updated.) inset == 0 reproduces the old flush layout exactly.
        bd:ClearAllPoints()
        bd:SetPoint("TOPLEFT", border, "TOPLEFT", inset, -inset)
        bd:SetPoint("BOTTOMRIGHT", border, "BOTTOMRIGHT", -inset, inset)
        -- Thickness 0 = no border: hide the backdrop instead of clamping the
        -- edge to 1px (parity with the solid/gradient path above). The
        -- animation overlay is a separate frame and keeps running.
        if size <= 0 then
            bd:Hide()
            border.activeTexture = nil
        else
            bd:SetBackdrop({ edgeFile = edgeFile, edgeSize = size })
            bd:SetBackdropBorderColor(cr, cg, cb, ca)
            bd:Show()
            border.activeTexture = texture
        end
    end

    -- Drop shadow: solid 4-edge ring, lazy-created, parented next to the
    -- border. Within the border's frame level, the BACKGROUND draw layer
    -- puts the shadow behind the BORDER-layer edge textures — so the
    -- shadow reads as "behind the border" without needing a lower frame
    -- level. Earlier rev used border.level - 1 here, but that broke for
    -- StatusBar consumers (Resource Bar) where the bar's own statusbar
    -- texture sits at the bar's frame level and the shadow at bar.level
    -- ended up rendering BEHIND the opaque bar fill — invisible on
    -- in-range units, only peeking through when the bar's alpha dropped
    -- on OOR. Matching border.level lifts the shadow above the bar fill
    -- on all consumers without affecting Frame Border (its parent has
    -- no fill texture).
    local shadow = spec.shadow
    if shadow and shadow.enabled then
        local sf = border.shadow
        if not sf then
            sf = CreateFrame("Frame", nil, border:GetParent() or border)
            sf.top    = sf:CreateTexture(nil, "BACKGROUND")
            sf.bottom = sf:CreateTexture(nil, "BACKGROUND")
            sf.left   = sf:CreateTexture(nil, "BACKGROUND")
            sf.right  = sf:CreateTexture(nil, "BACKGROUND")
            border.shadow = sf
        end
        -- Re-sync the frame level every Apply because the border's level
        -- can be changed by consumer code AFTER Border:New (Resource Bar
        -- does this in ApplyResourceBarLayout). One-shot-at-creation
        -- left shadow stale at the pre-override level.
        sf:SetFrameLevel(border:GetFrameLevel())

        local shadowSize = shadow.size or 1
        local shadowOX   = shadow.offsetX or 0
        local shadowOY   = shadow.offsetY or 0
        if spec.pixelPerfect and DF.PixelPerfect then
            shadowSize = DF:PixelPerfect(shadowSize)
        end
        local shr, shg, shb, sha = readColor(shadow.color)

        -- Anchor the shadow widget to the border's own bounds + shadow offset.
        sf:ClearAllPoints()
        sf:SetPoint("TOPLEFT",     border, "TOPLEFT",     shadowOX, shadowOY)
        sf:SetPoint("BOTTOMRIGHT", border, "BOTTOMRIGHT", shadowOX, shadowOY)

        -- Layout the four shadow edges (same pattern as solid border edges).
        sf.top:ClearAllPoints()
        sf.top:SetPoint("TOPLEFT",  0, 0)
        sf.top:SetPoint("TOPRIGHT", 0, 0)
        sf.top:SetHeight(shadowSize)
        sf.top:SetColorTexture(shr, shg, shb, sha)

        sf.bottom:ClearAllPoints()
        sf.bottom:SetPoint("BOTTOMLEFT",  0, 0)
        sf.bottom:SetPoint("BOTTOMRIGHT", 0, 0)
        sf.bottom:SetHeight(shadowSize)
        sf.bottom:SetColorTexture(shr, shg, shb, sha)

        sf.left:ClearAllPoints()
        sf.left:SetPoint("TOPLEFT",    0, -shadowSize)
        sf.left:SetPoint("BOTTOMLEFT", 0,  shadowSize)
        sf.left:SetWidth(shadowSize)
        sf.left:SetColorTexture(shr, shg, shb, sha)

        sf.right:ClearAllPoints()
        sf.right:SetPoint("TOPRIGHT",    0, -shadowSize)
        sf.right:SetPoint("BOTTOMRIGHT", 0,  shadowSize)
        sf.right:SetWidth(shadowSize)
        sf.right:SetColorTexture(shr, shg, shb, sha)

        sf:Show()
    elseif border.shadow then
        border.shadow:Hide()
    end

    -- Animation: presence of spec.animation drives Start, absence drives
    -- Stop. Stop is also called when the border is hidden (spec.enabled
    -- false handled earlier returns before this point), so re-disabling the
    -- border tears down any running glow.
    if spec.animation then
        self:StartAnimation(border, spec)
    else
        self:StopAnimation(border)
    end
end
