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
-- gradient, and DF-owned border animations. Only the current frame-border feature
-- set (enabled / style / texture / size / colour) is implemented here for now.
-- ============================================================

local CreateFrame = CreateFrame
local ipairs = ipairs
-- Midnight-safe: test a colour channel for secretness before feeding it to
-- CreateColor()/SetGradient (which reject secret values).
local issecretvalue = issecretvalue or function() return false end
-- Hot-path anim tick math (procTick/flashTick and the flipbook stepper they
-- call run every OnUpdate per active border) — cache off the math table.
local floor = math.floor
local min = math.min

DF.Border = DF.Border or {}
local Border = DF.Border

-- Create a border widget anchored to `parent` (or opts.anchorTo).
-- opts:
--   anchorTo          frame to cover (default: parent)
--   frameLevelOffset  level above parent (default: 2 — NOT 10, which this line claimed
--                     long after the default changed. Any parent that stacks CHILD
--                     FRAMES over its own rect must pass this explicitly: unit and pet
--                     frames pass 10, aura buttons pass DF.AuraButtonLevels.BORDER.
--                     See the note at the default itself for why.)
--   layer             texture draw layer for the solid edges (default: "BORDER")
--   solidOnly         hot-path SOLID border: skips the SetGradient/CreateColor
--                     gradient-clear in both Apply (SOLID) and SetColor, so live
--                     recolours are a bare SetColorTexture — cheap AND safe for
--                     secret-tinted colours (e.g. debuff dispel-type colours),
--                     where CreateColor()/comparisons would taint. If a GRADIENT
--                     style apply does land on the widget (shared GUI prefixes),
--                     _gradientPainted forces the next solid clear so the
--                     gradient can't stick; keep spec colours non-secret on any
--                     widget whose style can reach GRADIENT.
--   secretRect        the host's rect may be SECRET or unresolved when Apply runs
--                     (12.1 aura-container buttons: Blizzard anchors them with
--                     secret-wrapped offsets, and initializeFrame fires before any
--                     anchor exists). TEXTURE style then renders via the anchor-only
--                     8-piece path instead of BackdropTemplate, whose Lua tiling
--                     math breaks on such rects. See the piece renderer above Apply.
function Border:New(parent, opts)
    opts = opts or {}
    local border = CreateFrame("Frame", nil, parent)
    border._solidOnly = opts.solidOnly and true or false
    border._secretRect = opts.secretRect and true or false
    -- Remember anchorTo on the widget so :Apply can re-anchor when an offsetX/Y
    -- is supplied (SetAllPoints below is the offsetX=offsetY=0 default; :Apply
    -- replaces it with two SetPoint calls translated by the offset).
    border.anchorTo = opts.anchorTo or parent
    border:SetAllPoints(border.anchorTo)
    -- DEFAULT +2. Sized for a LEAF parent — an aura button, a badge, an icon — whose own
    -- content is regions (textures/fontstrings) rather than child frames. At parent+2 the
    -- border clears the parent's regions and a cooldown swipe, and stays inside the tight
    -- band the aura rows budget for it (Factory.ALERT_ROW_LIFT is measured against this
    -- number — re-measure it if this moves).
    --
    -- ☠ THIS DEFAULT IS WRONG FOR A FRAME THAT STACKS CHILD FRAMES OVER ITS OWN RECT, and
    -- such a parent MUST pass frameLevelOffset explicitly. The comment that used to sit here
    -- claimed "+2 clears both" because it reasoned about regions on the parent and about
    -- SIBLING frames, and never considered a CHILD frame covering the same rect. A unit
    -- frame is exactly that: healthBar is a child at frame+3 with SetAllPoints and
    -- framePadding defaulting to 0, so it covers the whole rect and buries a border at +2 —
    -- completely at 100% health, half of it at 50%. Shipped that way briefly in alpha 15;
    -- caught in review, never released. The measured unit-frame stack (/df debug zorder,
    -- 2026-08-14) is health +3, heal-absorb +8, heal prediction +10, absorb +11,
    -- overflow +11, overshield host +13, power +20, contentOverlay +25 — hence the
    -- explicit +14 those consumers now pass, the free slot between the bars and the
    -- resource/text/icon layer.
    -- ⚠ This paragraph drifted once already: it said "+12 / +13" from when the prediction
    -- still sat ABOVE the absorb, and stayed that way after the band was rebuilt and the
    -- offset became 14. A band description is only worth having if it is re-measured with
    -- the band — read /df debug zorder before trusting the list.
    -- ☠ THAT NUMBER WAS +10, AND IT WENT STALE UNDER A GROWING BAND. It was right while
    -- the band ended at absorb +7 / heal-absorb +8; the 2026-08-13 z-order convergence
    -- lifted absorb to +11 and prediction to +12 without moving the frame border, so both
    -- drew OVER it until 2026-08-14. A consumer's offset is a claim about its PARENT'S
    -- CHILDREN, and it expires when they move.
    --
    -- ⚠ The rule, for anyone adding a consumer: read the PARENT's children, not its regions,
    -- and not its siblings. If any child covers the parent's rect, this default will hide
    -- your border and nothing will error.
    border:SetFrameLevel(parent:GetFrameLevel() + (opts.frameLevelOffset or 2))

    local layer = opts.layer or "BORDER"
    border._layer = layer   -- texture-piece renderer creates on the same layer
    -- ☠ SNAPPING OFF on the four solid edges, same as the texture-piece path
    -- (and NineSlice.lua). Default pixel-grid snapping can COLLAPSE a 1px edge
    -- that straddles a fractional physical-pixel coordinate to zero columns —
    -- live secure-header frames are never grid-snapped (only test-mode paths
    -- get SnapPointToPixelGrid), so a fractionally-positioned container lost a
    -- whole side while its opposite edge survived (#1013: "left border missing
    -- on every frame"). With snapping off the worst case is an antialiased
    -- edge across two columns — visible, never gone.
    local function edge()
        local t = border:CreateTexture(nil, layer)
        if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
        if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false) end
        return t
    end
    border.top = edge()
    border.top:SetPoint("TOPLEFT", 0, 0)
    border.top:SetPoint("TOPRIGHT", 0, 0)
    border.bottom = edge()
    border.bottom:SetPoint("BOTTOMLEFT", 0, 0)
    border.bottom:SetPoint("BOTTOMRIGHT", 0, 0)
    border.left = edge()
    border.left:SetPoint("TOPLEFT", 0, 0)
    border.left:SetPoint("BOTTOMLEFT", 0, 0)
    border.right = edge()
    border.right:SetPoint("TOPRIGHT", 0, 0)
    border.right:SetPoint("BOTTOMRIGHT", 0, 0)

    -- Recolour whichever mode is currently active (used by live colour updates,
    -- aggro/threat/dispel overlays, etc.).
    border.SetColor = function(self, r, g, b, a)
        a = a or 1
        if self.activeTexture then
            if self._secretRect and self.texPieces then
                -- Anchor-only piece render: plain SetVertexColor per piece —
                -- render-side setter, safe for secret-tinted colours.
                for _, t in pairs(self.texPieces) do t:SetVertexColor(r, g, b, a) end
            elseif self.bd then
                self.bd:SetBackdropBorderColor(r, g, b, a)
            end
        else
            local bm = self._blendMode or "BLEND"
            local edges = { self.top, self.bottom, self.left, self.right }
            -- Clear any prior gradient — SetColorTexture does NOT reset it, so a
            -- leftover gradient (set when the border was first painted, even in
            -- SOLID mode) would tint the recolour and wash it out.  Paint a
            -- solid gradient of the new colour first (same pattern Apply uses).
            -- solidOnly borders normally never set a gradient, so we skip this —
            -- keeps the recolour a bare SetColorTexture, which is both cheaper
            -- and safe for secret-tinted colours (CreateColor on a secret value
            -- taints execution). _gradientPainted overrides the skip: a GRADIENT
            -- style apply CAN land on a solidOnly widget (shared GUI prefixes),
            -- and its state must be cleared here too.
            if (not self._solidOnly or self._gradientPainted) and CreateColor then
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
                self._gradientPainted = nil
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

-- Shared read-only fallbacks for `readColor(anim.color or <default>)`. Seven sites
-- built one of these two tables inline, so an animation whose colour is unset
-- allocated a throwaway table on every driver tick. readColor only ever reads its
-- argument, and nothing downstream retains it, so one instance each is safe.
-- (ANIM_GOLD is the shared default for the border effects; ANIM_WHITE keeps the
-- proc atlas's own art untinted -- see the desaturate note in setupProcGlow.)
local ANIM_GOLD  = { r = 0.95, g = 0.95, b = 0.32, a = 1 }
local ANIM_WHITE = { r = 1, g = 1, b = 1, a = 1 }

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
-- Memoised db-key strings, per prefix. BuildSpec calls k() 37 times and each call
-- used to concatenate a fresh string -- 37 allocations per BuildSpec, on a function
-- that shows up in both the steady-state traces (2.7% of a boss run) and the rebuild
-- traces (2.6%). The prefix set is tiny and fixed, and prefix .. suffix is
-- deterministic, so the built keys are cached and reused forever.
local borderKeyMemo = {}

-- Key builder for BuildSpec, hoisted OUT of it so there is no closure per call.
-- 395af09f killed the 37 string concats but left one allocation behind: `k`
-- captured memo and prefix, so a fresh closure was built on every call -- and
-- BuildSpec runs per bordered element per tick (4.6% of trash allocation, 4.3%
-- of boss).
--
-- THE UPVALUES ARE SHARED, so BuildSpec saves and restores them around its body
-- (see below) and reentrancy is CORRECT rather than merely forbidden. It cannot
-- currently happen -- the body reaches DF:GetClassColor, DF:GetTestUnitData,
-- DF:GetUnitRole and the Border:Resolve* helpers, and none of those calls
-- BuildSpec -- but relying on that was a comment enforcing an invariant nothing
-- checked. A resolver that ever did build a spec would have started reading
-- another prefix's keys: a wrong border, silently, with nothing at the call site
-- to explain it. Stack discipline costs two locals and no allocation, which is
-- cheaper than the assert that would only have caught it on a debug build.
local bsMemo, bsPrefix
local function k(suffix)
    local key = bsMemo[suffix]
    if not key then key = bsPrefix .. suffix; bsMemo[suffix] = key end
    return key
end

function Border:BuildSpec(dbTable, prefix, ctx)
    if not dbTable or not prefix then return {} end
    local memo = borderKeyMemo[prefix]
    if not memo then memo = {}; borderKeyMemo[prefix] = memo end
    -- Save/restore rather than plain assignment: see the note above k().
    local prevMemo, prevPrefix = bsMemo, bsPrefix
    bsMemo, bsPrefix = memo, prefix

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
    -- Animation: spec.animation is set only when the consumer picked a non-NONE
    -- type — Apply uses presence to drive StartAnimation, absence to drive
    -- StopAnimation. Tunables (type / color / frequency / particles / length /
    -- thickness / scale / inset / offset) are read straight from the dbTable.
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
    bsMemo, bsPrefix = prevMemo, prevPrefix
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
        local testData = DF.GetTestUnitData and DF:GetTestUnitData(frame.index, frame.isRaidFrame, frame.isPinnedBossFrame)
        classToken = testData and testData.class
    elseif unit and UnitExists and UnitExists(unit) then
        classToken = select(2, UnitClass(unit))
        -- Secret class (boss units): keep the picker fallback below rather
        -- than the default-grey table GetClassColor returns for it.
        if issecretvalue(classToken) then classToken = nil end
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
        local testData = DF.GetTestUnitData and DF:GetTestUnitData(frame.index, frame.isRaidFrame, frame.isPinnedBossFrame)
        role = testData and testData.role
    else
        -- Player falls back to the spec role when the group assigned none;
        -- other units stay NONE and drop to the picker fallback below.
        role = DF:GetUnitRole(unit)
    end

    local c = role and role ~= "NONE" and (roleColors[role] or roleColors[string.lower(role)])
    if c then return c.r or fr, c.g or fg, c.b or fb, fa end
    return fr, fg, fb, fa
end

-- Colour-by-time-remaining via a C_CurveUtil colour curve. Caller supplies the
-- pre-built curve via ctx.timeCurve. totalDuration > 0 required
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
-- Account-wide dispel-type colour curve, built from DF.db.dispelColors (edited on
-- the Colors page; seeded from the old debuff-border palette). Per the API doc,
-- GetAuraDispelTypeColor "remaps the dispel type to a colour via a curve, with the
-- dispel type ID used as the 'x' value" — so the curve's X positions ARE the
-- Enum.AuraDispelType values. Feature-detected: returns nil (caller keeps the
-- game/native colour) when C_CurveUtil / the enum is absent. Cached on
-- DF.debuffBorderCurve; DF:InvalidateDispelColorCurve() nils it on any change.
-- ⚠ The Enum.AuraDispelType field set needs an in-game confirm (/df debug dispelids).
-- Name-keyed colour map for SetAuraBorder's customDispelColorMap: Blizzard indexes
-- auraData.dispelName ("Magic"/"Curse"/... ; live 69382 keys `dispelName or "None"`,
-- and map[""] is kept as a belt-and-braces alias of None) straight into this table
-- private-side. NO enum IDs involved (unlike the curve form, whose X axis is the
-- Enum.AuraDispelType values). Values are ColorMixin objects (their code calls
-- color:GetRGBA()). Cached; invalidated with the curve by DF:InvalidateDispelColorCurve().
-- ☠ FALLBACK, not primary — this comment used to call the map "the primary
-- custom-colour carrier for both the overlay and the debuff-icon ring", and that framing
-- hid a real bug: the private-side index is a RAW TABLE LOOKUP, so a SECRET dispelName
-- matches no key and the colour apply no-ops, leaving the style step's white base coat
-- (the "dispel overlay goes white in dungeons" field report, 2026-08-19). The
-- SECRET-SAFE tint is the curve — resolved C-side by auraInstanceID — and both bind
-- sites (the overlay in Features/Dispel.lua, the row ring in Frames/AuraContainer.lua)
-- pass both, the curve winning when present.
-- Blizzard's LIVE dispel-type border palette, queried from AuraUtil.GetAuraBorderColor
-- (the exact colours the game paints), cached. Per-type fallback to DF.DispelDefaultColors
-- (which mirror the classic DebuffTypeColor values) if the API is missing / returns nil.
-- This is what every default, the Colors-page "Reset", and each fallback resolve to, so an
-- untouched palette is byte-identical to the game's own dispel colours. None/Physical is
-- kept only for the map's "" fallback (never user-editable — the border is hidden on
-- no-dispel-type auras and the overlay never fires on them).
-- SHARED dispel-texture style resolver (the debuff-icon ring + every overlay carrier
-- resolve through this one function — never a local copy).
-- DF names its two styles the way the ORIGINAL 12.1 enum did:
--   "Color" = keep OUR asset, recolour it by dispel type  (gradient / ring / strips)
--   "Atlas" = draw Blizzard's own dispel-type border art
-- ★ 68914 renamed AND renumbered the enum: CustomAuraButtonBorderStyle{Atlas=0,Color=1}
-- became CustomAuraButtonDispelTypeTextureStyle{Border=0,BorderWithIcon=1,Icon=2,
-- PreserveAsset=3,CustomAsset=4}. Blizzard's own shim (Blizzard_Deprecated/
-- Deprecated_12_1_0.lua) maps Atlas->BorderWithIcon and Color->PreserveAsset, and is
-- flagged for removal — so resolve against the CURRENT enum first and keep the shim
-- only as a pre-68914 fallback. The old numeric fallbacks were the real hazard: `1`
-- now means BorderWithIcon (Blizzard's art WITH a badge, drawn over our gradient) and
-- `0` means Border — either would silently replace our own art, so the last-resort
-- literals below are the NEW values, not the old ones.
-- ★ Atlas maps to Border, NOT to the shim's BorderWithIcon: the shim mirrors the OLD
-- default (showIcon defaulted true), but both DF bind sites pass showIcon = false, so
-- the faithful equivalent of DF's "Atlas" is the badge-LESS variant. `showIcon` no
-- longer exists on 68914's options, so the style is the only place that intent can
-- live. Use "BorderWithIcon" here if a corner dispel badge is ever wanted.
-- ★ `Icon` below is that "if": it lets a carrier ask Blizzard for the dispel-type
-- ART rather than just its colour, which is what lets one badge on the dispel
-- overlay's slot agree with the overlay by construction -- same aura, Blizzard picks
-- both -- instead of us guessing a type we cannot read.
--
-- The enum's other two art styles, BorderWithIcon and Border, are deliberately NOT
-- mapped: they are ui-debuff-border-* art meant to frame an aura BUTTON, so on a unit
-- frame they render as a square box around the symbol (tried live 2026-08-03).
--
-- Resolved BY NAME, never by literal: the numbers were RENUMBERED for 68914, so any
-- hardcoded `style = 1` that used to mean "Color" now draws BorderWithIcon instead. The
-- literal table is a last resort for clients without the enum at all.
local DISPEL_STYLE_NEW = {
    Color = "PreserveAsset", Atlas = "Border",
    Icon = "Icon",
}
local DISPEL_STYLE_LITERAL = {
    Color = 3, Atlas = 0,
    Icon = 2,
}
function DF:ResolveDispelTextureStyle(styleName)
    if DISPEL_STYLE_NEW[styleName] == nil then styleName = "Atlas" end
    local newEnum = Enum and Enum.CustomAuraButtonDispelTypeTextureStyle
    local v = newEnum and newEnum[DISPEL_STYLE_NEW[styleName]]
    if v ~= nil then return v end
    local oldEnum = Enum and Enum.CustomAuraButtonBorderStyle          -- pre-68914
    v = oldEnum and oldEnum[styleName]
    if v ~= nil then return v end
    v = _G.AuraButtonBorderStyle and _G.AuraButtonBorderStyle[styleName]   -- Blizzard's shim
    if v ~= nil then return v end
    return DISPEL_STYLE_LITERAL[styleName]
end

function DF:GetGameDispelPalette()
    if DF._gameDispelPalette then return DF._gameDispelPalette end
    local D = DF.DispelDefaultColors
    local getC = AuraUtil and AuraUtil.GetAuraBorderColor
    local function resolve(typeName, fb)
        if getC then
            local ok, c = pcall(getC, typeName)
            if ok and c and c.GetRGB then
                local r, g, b = c:GetRGB()
                if r then return { r = r, g = g, b = b } end
            end
        end
        return { r = fb.r, g = fb.g, b = fb.b }
    end
    local pal = {
        Magic   = resolve("Magic",   D.Magic),
        Curse   = resolve("Curse",   D.Curse),
        Disease = resolve("Disease", D.Disease),
        Poison  = resolve("Poison",  D.Poison),
        Bleed   = resolve("Bleed",   D.Bleed),
        Enrage  = resolve("Bleed",   D.Enrage),   -- shares Bleed's colour
        None    = { r = D.None.r, g = D.None.g, b = D.None.b },
    }
    if getC then DF._gameDispelPalette = pal end   -- don't cache a pre-AuraUtil fallback
    return pal
end

-- The dispel-type LETTERS ("Ma", "Po", …), read from the client's own localised
-- globals so they match what WoW itself would draw, in every language.
--
-- ☠ WHY THIS EXISTS: Blizzard only draws these when the player's `colorblindMode`
-- CVar is on — `AuraUtil.SetAuraSymbol` is the sole place that CVar is read, and it
-- Hide()s the fontstring otherwise. But `SetDispelTypeText` takes a
-- `customDispelTextMap`, and when a key resolves, `ApplyDispelTypeText` does
-- SetText()+Show() DIRECTLY and never reaches SetAuraSymbol. Feeding it the same
-- letters the game would have used therefore changes nothing visually while
-- removing the CVar dependency entirely — and we never write the CVar itself
-- (it is a global accessibility setting; not ours to touch).
--
-- Map key is `auraData.dispelName or "None"` (Blizzard_CustomAuraButton
-- GetDispelTypeMapKey). ⚠ The generated API doc claims an EMPTY key covers auras
-- with no dispel type — the code says otherwise; trust the code. In practice
-- "None" is unreachable for us anyway: ShouldShowDispelTypeForAura rejects a nil
-- dispelName before the text path unless `showWithoutDispelType` is passed.
--
-- Per-key fallthrough: a missing key falls back to the CVar-gated path for THAT
-- type only, so the fallbacks below matter — a nil global must not silently
-- reintroduce the gate.
local DISPEL_TEXT_FALLBACK = {
    Magic = "Ma", Curse = "Cu", Disease = "Di", Poison = "Po", Bleed = "Bl",
}

function DF:GetGameDispelTextMap()
    if DF._gameDispelTextMap then return DF._gameDispelTextMap end
    local map, sawGlobal = {}, false
    for typeName, fb in pairs(DISPEL_TEXT_FALLBACK) do
        local s = _G["DEBUFF_SYMBOL_" .. typeName:upper()]
        if type(s) == "string" and s ~= "" then
            map[typeName], sawGlobal = s, true
        else
            map[typeName] = fb
        end
    end
    -- Only cache once the client's strings were actually available; a pre-load
    -- read would otherwise freeze the fallbacks in for the session.
    if sawGlobal then DF._gameDispelTextMap = map end
    return map
end

-- ============================================================
-- LEGACY (v4) DISPEL COLOURS -> the shared account palette
-- ============================================================
-- v4 shipped TWO independent, separately-editable sets of dispel colours, each with its
-- own pickers and its own Reset:
--
--   debuffBorderColor{Magic,Curse,Disease,Poison,Bleed}  -- the debuff ICON BORDER
--   dispel{Magic,Curse,Disease,Poison,Bleed}Color        -- the DISPEL OVERLAY
--
-- v5 collapses both onto ONE account-wide table (DF.db.dispelColors, edited on the
-- Colors page), so a profile carrying both has to resolve to a single value per type.
--
-- ☠ RESOLUTION IS PER TYPE, AND "SET" MEANS "DIFFERS FROM THE v4 DEFAULT" -- NOT
-- "EXISTS". v4's Config seeds BOTH families into every profile, so both keys are
-- present on essentially every v4 profile whether or not the user ever opened that
-- picker. A presence test would hand the overlay family the win for everybody and
-- silently discard the border customisation of every user who only ever touched the
-- border -- the same data loss as doing nothing, pointed the other way.
--
-- Order per type: OVERLAY if customised -> BORDER if customised -> game palette.
-- Krathe's call (2026-08-06). The conflict case is narrow by construction -- it needs
-- BOTH families customised to DIFFERENT colours -- and the overlay is the more visible
-- element of the two, so it takes the tiebreak.
--
-- Party is read before raid because v5's palette is account-wide and party is the
-- surface a solo/party user configures; a raid-only customiser would otherwise be lost
-- entirely, which is why raid is a fallback rather than being ignored.
DF.LegacyDispelDefaults = {   -- v4's shipped defaults; IDENTICAL across both families
    Magic   = { r = 0.2, g = 0.6, b = 1 },
    Curse   = { r = 0.6, g = 0,   b = 1 },
    Disease = { r = 0.6, g = 0.4, b = 0 },
    Poison  = { r = 0,   g = 0.6, b = 0 },
    Bleed   = { r = 1,   g = 0,   b = 0 },
}

-- Deliberately loose (1e-3): a colour-picker round-trip can perturb the low bits, and a
-- user who nudged a slider and put it back should read as untouched. A false "untouched"
-- costs nothing here -- it falls through to the other family or the game palette, which
-- for an at-default value is the same colour either way.
-- ☠ ALL THREE CHANNELS ARE TYPE-CHECKED, not just r. This used to guard `c.r` alone and
-- then read c.g and c.b in the `or` chain below, so a partial table -- {r = <default>},
-- which reaches the second term because the first compares equal -- threw "attempt to
-- perform arithmetic on a nil value". That throw lands inside ADDON_LOADED, which aborts
-- the rest of the migration chain for that login and leaves a half-migrated profile with
-- no recovery path. Guarding the one field you happen to read first is not a guard.
local function dispelColorCustomised(c, def)
    if type(c) ~= "table" then return false end
    if type(c.r) ~= "number" or type(c.g) ~= "number" or type(c.b) ~= "number" then
        return false
    end
    return math.abs(c.r - def.r) > 1e-3
        or math.abs(c.g - def.g) > 1e-3
        or math.abs(c.b - def.b) > 1e-3
end

-- Build a v5 dispelColors table from a v4 profile's per-mode tables. Returns a fresh
-- table, always fully populated. Shared by the login migration (Core.lua) and the
-- profile IMPORT path (Core/Profile.lua) -- an import string written by v4 carries the
-- legacy keys and no dispelColors, so without this the import silently lands nothing.
-- ☠ Candidates are passed as VARARGS, not as a table walked with ipairs. Any of them
-- can legitimately be nil -- a v5-native profile has no legacy keys at all, and a
-- partial import may carry one mode and not the other -- and ipairs STOPS at the first
-- nil, which would have silently skipped every later candidate. Missing the first one
-- would have meant the border fallback was never reached.
local function pickDispelColor(def, ...)
    for i = 1, select("#", ...) do
        local c = select(i, ...)
        if dispelColorCustomised(c, def) then
            return { r = c.r, g = c.g, b = c.b }
        end
    end
end

function DF:BuildDispelColorsFromLegacy(party, raid)
    party, raid = party or {}, raid or {}
    local game = (DF.GetGameDispelPalette and DF:GetGameDispelPalette()) or DF.DispelDefaultColors
    local out = {}
    for _, t in ipairs({ "Magic", "Curse", "Disease", "Poison", "Bleed" }) do
        local def = DF.LegacyDispelDefaults[t]
        -- Overlay first, then border; party before raid within each.
        local picked = pickDispelColor(def,
            party["dispel" .. t .. "Color"],
            raid["dispel" .. t .. "Color"],
            party["debuffBorderColor" .. t],
            raid["debuffBorderColor" .. t])
        if not picked then
            local g = (game and game[t]) or def
            picked = { r = g.r, g = g.g, b = g.b }
        end
        out[t] = picked
    end
    return out
end

-- Resolve ONE dispel type to r,g,b. The single source of truth for "what colour is a
-- Magic debuff", shared by the dispel overlay's test path and Core's lightweight
-- repaint. Order: the shared account palette (DF.db.dispelColors, edited on the Colors
-- page) -> the game palette -> a neutral. Enrage folds into Bleed, as everywhere else.
--
-- ☠ This exists because Core's LightweightUpdateDispelOverlay had its OWN copy of this
-- table, built from per-mode `db.dispelMagicColor`-style keys that the v5 migration
-- DELETES. Those reads were always nil, so it always fell through to hardcoded literals
-- that disagreed with this palette (Bleed 1,0,0 vs 0.8,0,0) -- meaning dragging the
-- dispel colour wheel repainted the overlay to a colour the user had not picked.
-- Resolve here, never inline: a second copy is what caused the bug.
function DF:ResolveDispelColor(dispelType)
    local key = dispelType == "Enrage" and "Bleed" or dispelType
    if DF.db and type(DF.db.dispelColors) == "table" then
        local c = DF.db.dispelColors[key]
        if c and c.r then return c.r, c.g, c.b end
    end
    local pal = (DF.GetGameDispelPalette and DF:GetGameDispelPalette()) or DF.DispelDefaultColors
    local c = pal and pal[key]
    if c then return c.r, c.g, c.b end
    return 0.5, 0.5, 1.0
end

function DF:GetDispelColorMap()
    if DF.dispelColorMap then return DF.dispelColorMap end
    if not CreateColor then return nil end
    local D = DF:GetGameDispelPalette()
    local colors = (DF.db and DF.db.dispelColors) or D
    local function C(c, fb)
        if type(c) ~= "table" or not c.r then c = fb end
        return CreateColor(c.r or 1, c.g or 1, c.b or 1, 1)
    end
    local map = {
        Magic   = C(colors.Magic,   D.Magic),
        Curse   = C(colors.Curse,   D.Curse),
        Disease = C(colors.Disease, D.Disease),
        Poison  = C(colors.Poison,  D.Poison),
        Bleed   = C(colors.Bleed,   D.Bleed),
        Enrage  = C(colors.Enrage or colors.Bleed, D.Enrage),
        None    = C(colors.None,    D.None),
    }
    map[""] = map.None
    DF.dispelColorMap = map
    return map
end

-- The dispel-type enum's NAME is unconfirmed (Enum.AuraDispelType probed nil on
-- 68824; a shape-scan only found the JournalEncounterIconFlags false positive) —
-- kept for Border:ResolveTypeColor's GetAuraDispelTypeColor path, which has no map
-- form. Scan Enum once for a table carrying numeric Magic/Curse/Disease/Poison
-- fields, preferring names that mention "dispel". Cached; false = none found.
function DF:FindDispelTypeEnum()
    if DF._dispelTypeEnum ~= nil then
        return DF._dispelTypeEnum or nil
    end
    local found, foundName
    if type(Enum) == "table" then
        for name, t in pairs(Enum) do
            if type(t) == "table" and type(t.Magic) == "number" and type(t.Curse) == "number"
                and type(t.Disease) == "number" and type(t.Poison) == "number"
                -- reject bitflag lookalikes (Enum.JournalEncounterIconFlags carries
                -- Magic/Curse/... alongside role fields — a live-caught false positive)
                and t.Tank == nil and t.Healer == nil then
                if tostring(name):lower():find("dispel") then
                    found, foundName = t, name
                    break
                end
                if not found then found, foundName = t, name end
            end
        end
    end
    -- ☠☠ NO Enum TABLE EXISTS — FALL BACK TO THE DB2 VALUES, or the curve can never be
    -- built and every curve-based tint silently degrades to the name-keyed map.
    --
    -- The scan above has never found anything: probed nil on 68824, and confirmed again on
    -- live 69382 by /df debug dispelids ("no Enum table with Magic/Curse/Disease/Poison
    -- found", "curve built: no") while GetAuraDispelTypeColor reported PRESENT. So the
    -- dispel overlay kept falling back to customDispelColorMap and kept rendering white on
    -- secret dispel names — the fix in 81122cb1 was a no-op for exactly this reason
    -- (Krathe, 2026-08-19).
    --
    -- These are the SpellDispelType DB2 ids, i.e. game data rather than anyone's
    -- invention, and they are the same values another 12.1 unit-frame addon hardcodes for
    -- its own dispel curve (citing the same DB2 table). The gaps are real: 5-8 and 10 are
    -- unused by the dispel types we colour.
    -- ⚠ The SCAN STILL WINS. If Blizzard ever ships a real enum, it is authoritative and
    -- this table is dead weight; do not reorder that.
    -- ⚠ Curve X values must be the dispel-type IDs, which is what makes exact-integer
    -- lookups land on their own point (see GetDispelColorCurve's Linear note).
    if not found then
        found = { None = 0, Magic = 1, Curse = 2, Disease = 3, Poison = 4, Enrage = 9, Bleed = 11 }
        foundName = "DB2 fallback (SpellDispelType)"
    end
    DF._dispelTypeEnum = found or false
    DF._dispelTypeEnumName = foundName
    return found
end

function DF:GetDispelColorCurve()
    if DF.debuffBorderCurve then return DF.debuffBorderCurve end
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve) then return nil end
    local E = DF:FindDispelTypeEnum()
    if not E then return nil end
    -- ☠☠ PER-KEY FALLBACK, NOT A WHOLE-TABLE `or`. GetDispelColorMap has always done
    -- this; the curve did not, and the difference was a live bug.
    -- `db.dispelColors` has NO defaults entry, so it does not exist until the user edits
    -- a dispel colour -- and the Colors page only ever writes the five DISPELLABLE types
    -- (Magic/Curse/Disease/Poison/Bleed). The moment it exists it SHADOWED the complete
    -- game palette wholesale, so `colors.None` was nil and the loop below skipped the
    -- point at index 0 entirely. Verified against a live profile carrying exactly those
    -- five keys (2026-08-20).
    --
    -- ☠☠ WHY A HOLE AT 0 MATTERS MORE THAN IT LOOKS: the engine lets the curve
    -- UNCONDITIONALLY OVERRIDE the colour map --
    -- `if options.customDispelColorCurve then color = GetAuraDispelTypeColor(...) end`,
    -- Blizzard_CustomAuraButton.lua:410-412, no test on the map result. So a curve with a
    -- hole is WORSE than no curve at all: it discards a perfectly good map lookup and
    -- substitutes whatever the curve clamps to. An aura with no dispel type keys "None",
    -- which the map resolves correctly and the holed curve did not.
    local D = DF:GetGameDispelPalette()
    local colors = (DF.db and DF.db.dispelColors) or D
    local function pick(c, fb) return (type(c) == "table" and c.r) and c or fb end
    local candidates = {
        { E.Magic,   pick(colors.Magic,   D.Magic) },
        { E.Curse,   pick(colors.Curse,   D.Curse) },
        { E.Disease, pick(colors.Disease, D.Disease) },
        { E.Poison,  pick(colors.Poison,  D.Poison) },
        { E.Bleed,   pick(colors.Bleed,   D.Bleed) },
        { E.Enrage,  pick(colors.Enrage or colors.Bleed, D.Enrage) },
        { E.None,    pick(colors.None,    D.None) },
    }
    local points = {}
    local haveZero = false
    for _, pair in ipairs(candidates) do
        local x, c = pair[1], pair[2]
        if type(x) == "number" and type(c) == "table" then
            points[#points + 1] = { x, CreateColor(c.r or 0, c.g or 0, c.b or 0, 1) }
            if x == 0 then haveZero = true end
        end
    end
    -- ★ ANCHOR INDEX 0 EVEN IF THE ENUM LOOKUP FOR "None" FAILED. Index 0 is the
    -- no-dispel-type case, and on a debuff row it is the value the curve is evaluated at
    -- most often -- so it must never be one the curve has to extrapolate towards. An
    -- unanchored 0 does not read as missing either: the curve still returns a colour, just
    -- the wrong one, which is why this was invisible until the palette was compared
    -- against the point set.
    if not haveZero then
        local n = pick(colors.None, D.None)
        if type(n) == "table" then
            table.insert(points, 1, { 0, CreateColor(n.r or 0, n.g or 0, n.b or 0, 1) })
        end
    end
    if #points == 0 then return nil end
    table.sort(points, function(a, b) return a[1] < b[1] end)
    -- CreateColorCurve takes NO constructor args (a passed table is ignored →
    -- an EMPTY curve that evaluates to white); build via SetType + AddPoint,
    -- the same pattern as Colors.lua / HealthFade.lua. Exact-integer X hits
    -- land on their point, so Linear is safe for the discrete type IDs.
    local curve = C_CurveUtil.CreateColorCurve()
    if not curve then
        -- Without the curve every dispel tint falls back to the name-keyed map, which
        -- no-ops on a secret dispel name. Say so once; this is the one residual route
        -- back to an untinted carrier and it must not be silent.
        if not DF._warnedNoDispelCurve then
            DF._warnedNoDispelCurve = true
            if DF.DebugWarn then DF:DebugWarn("DISPEL", "CreateColorCurve returned nil - dispel tint is falling back to the colour map") end
        end
        return nil
    end
    if curve.SetType and Enum.LuaCurveType then curve:SetType(Enum.LuaCurveType.Linear) end
    for _, p in ipairs(points) do
        curve:AddPoint(p[1], p[2])
    end
    DF.debuffBorderCurve = curve
    return DF.debuffBorderCurve
end

function Border:ResolveTypeColor(unit, auraInstanceID, fallback)
    local fr, fg, fb, fa = readColor(fallback)
    if not unit or not auraInstanceID or not C_UnitAuras or not C_UnitAuras.GetAuraDispelTypeColor then
        return fr, fg, fb, fa
    end
    local curve = DF:GetDispelColorCurve()
    if not curve then return fr, fg, fb, fa end
    local result = C_UnitAuras.GetAuraDispelTypeColor(unit, auraInstanceID, curve)
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
-- Every effect is DF-owned (no external glow library) and runs on our own
-- textures via the shared UIParent driver, so all are taint-safe on 12.1 aura
-- container buttons. Effects split into three implementation families:
--
-- 1. DF particle / flipbook effects — DF_ORBIT (orbiting sparkles), DF_PIXEL
--    (chasing bars), DF_PROC (proc flipbook), DF_FLASH (glow flash). Own
--    textures parented to the animRect, positioned/stepped each frame.
--
-- 2. Custom OnUpdate animators — modulate dedicated overlay textures each frame.
--    Tick functions live in `customTicks` below; the shared driver frame is
--    created lazily via registerAnimTick.
--      "BLINK"          hard on/off strobe on all four overlays together
--
-- 3. Static shape mode — no animation, just a different render layout
--    held for as long as the type is active.
--      "CORNERS_ONLY" show only short pieces at each of the 4 corners
--                     (lazy-creates 4 extra textures so each corner has
--                     a horizontal + a vertical short piece)
--
--      "NONE"         silently stops any running effect
--
-- Stop semantics: Apply ALWAYS calls StopAnimation first to clear any prior
-- effect before starting a new one (avoids leaving a stale Pulsate running
-- under a freshly-started Chase, or stale CORNERS_ONLY textures visible
-- under a freshly-started Blink). Idempotent for the no-active-anim case.
-- ============================================================


-- Lazy-create the shared OnUpdate driver for custom animations.
--
-- Parenting: normal borders parent the driver to `border`, so it inherits the
-- border's shown-state and stops ticking automatically when the border hides.
-- secretRect borders (AD / aura-container slot children) live inside a
-- CustomAuraButton subtree whose intrinsic onUpdateMode="disabled" suppresses
-- OnUpdate through EVERY descendant -- a driver parented under `border` there
-- would install its OnUpdate but never fire (Blink / DF_PULSATE and the DF
-- particle effects all looked frozen). Host those drivers on UIParent so their
-- OnUpdate actually dispatches; the tick closures capture `border` by reference
-- and keep driving the border's own child textures (render-side SetAlpha /
-- SetPoint on OUR textures -- no secret read, no secure op). Visibility still
-- rides the slot's secret show/hide (the textures are slot children); only the
-- MOTION now comes from the external driver.
--
-- Cost of the external host: the driver no longer auto-hides with the border,
-- so its teardown is EXPLICIT. StopAnimation (below) clears the OnUpdate +
-- Hides it, and the aura-container teardown path calls StopAnimation on every
-- slot border so a de-configured / winner-changed / rebuilt AD border leaves no
-- orphaned ticking driver.
-- Shared OnUpdate driver: ONE UIParent-hosted frame ticks a registry of every
-- animated border, instead of a CreateFrame + OnUpdate per border. secretRect
-- borders (AD / aura-container slot children) MUST be driven externally — the
-- button subtree's onUpdateMode="disabled" suppresses OnUpdate through every
-- descendant, so a driver parented under the border there would install but never
-- fire. A single shared host keeps the per-border cost to one registry entry.
--
-- Each entry carries its own accumulated elapsed; ticks get (border, elapsed, dt)
-- — elapsed for offset/phase-from-absolute effects (custom overlays, DF_DASH), dt
-- for the DF_PULSATE phase accumulator. A NORMAL border is skipped while hidden
-- (preserving the old per-border driver's auto-hide); secretRect borders always
-- tick (their textures' visibility rides the slot's secret show/hide, and a tick
-- on a hidden texture is a harmless SetAlpha — same as the prior UIParent driver).
local animRegistry = {}   -- [border] = { fn = fn, elapsed = number }
local sharedAnimDriver
-- ☠ FORWARD DECLARATION, not a stray local. The driver's OnUpdate below drops a border
-- that refuses its tick, and unregisterAnimTick is defined AFTER it -- without this the
-- closure would capture a nil GLOBAL and fail only at the moment it is needed. Same trap
-- this file has been bitten by twice; see the header notes.
local unregisterAnimTick
-- One-time latch: a refused tick logs once, not once per frame per border.
local warnedTickRefused = false
local function ensureSharedAnimDriver()
    if sharedAnimDriver then return sharedAnimDriver end
    sharedAnimDriver = CreateFrame("Frame", nil, UIParent)
    sharedAnimDriver:SetScript("OnUpdate", function(_, dt)
        -- MEMORY TEST (enableAnimations): one check for every animated border in
        -- the game, since they all ride this single driver. Borders keep their
        -- registry entry and resume mid-phase when the flag comes back on.
        if DF:MemTestDisabled("enableAnimations") then return end
        for border, e in pairs(animRegistry) do
            if border._secretRect or border:IsShown() then
                e.elapsed = e.elapsed + dt
                if border._secretRect then
                    -- ☠ A secretRect border's edge textures are DESCENDANTS of a Blizzard
                    -- aura button, which refuses tainted writes while auras are secret
                    -- (DenyTaintedAccessWhenAurasAreSecret, descendants included since
                    -- 12.1.0.69382). A tick that writes into a refused subtree throws
                    -- EVERY FRAME, in exactly the content these borders exist for -- which
                    -- is why container animation was retired wholesale rather than guarded.
                    --
                    -- Guard rather than forbid: probe under pcall and DROP the border on the
                    -- first refusal, so the cost of being wrong is one error and a stopped
                    -- effect instead of a per-frame flood. Nothing re-arms it here; the next
                    -- Apply does, via StartAnimation's dead-driver recovery (a DRIVER_ANIMS
                    -- type whose registry entry has gone re-registers even though the spec
                    -- hash is unchanged). So leaving an instance and restyling restores it.
                    --
                    -- ⚠ Deliberately NOT gated on CanBeAccessedInContext(): that answers for
                    -- the object it is called on, and what we need to know is whether a WRITE
                    -- to this border's own regions lands. Only the write answers that.
                    if not pcall(e.fn, border, e.elapsed, dt) then
                        unregisterAnimTick(border)
                        if not warnedTickRefused then
                            warnedTickRefused = true
                            if DF.DebugWarn then
                                DF:DebugWarn("AURACONTAINER",
                                    "border animation tick refused on a restricted subtree - effect dropped until the next restyle")
                            end
                        end
                    end
                else
                    e.fn(border, e.elapsed, dt)
                end
            end
        end
    end)
    return sharedAnimDriver
end
-- Register/replace this border's per-frame tick. initialElapsed seeds the
-- accumulator (DF_DASH resumes its march across restarts; others start at 0).
local function registerAnimTick(border, fn, initialElapsed)
    ensureSharedAnimDriver():Show()
    local e = animRegistry[border]
    if not e then e = {}; animRegistry[border] = e end
    e.fn = fn
    e.elapsed = initialElapsed or 0
end
function unregisterAnimTick(border)
    animRegistry[border] = nil
    -- ☠ Hide the driver once the last animated border goes. An OnUpdate on a
    -- shown frame runs every frame forever; emptying the registry alone left
    -- it paying a MemTestDisabled call and an empty pairs() loop for the rest
    -- of the session once any border had animated even once.
    if sharedAnimDriver and next(animRegistry) == nil then
        sharedAnimDriver:Hide()
    end
end

-- Reset all four edges to fully opaque. Called from StopAnimation so the
-- next Apply pass renders normally, in case any past or future animator left a
-- non-1 alpha on the border's own edges (current effects paint overlays, but
-- this stays as cheap insurance).
local function resetEdgeAlphas(border)
    local edges = { border.top, border.bottom, border.left, border.right }
    for _, e in ipairs(edges) do
        if e then e:SetAlpha(1) end
    end
end

-- ===== ANIMATION OVERLAYS =====
-- For the OnUpdate-driven custom effects (Blink) we render 4 dedicated overlay
-- textures that sit immediately OUTSIDE the border's outer edge — top overlay
-- above the border's top, bottom below, left to the left of the border's left,
-- right to the right. The overlays have their own thickness (anim.thickness) and
-- colour (anim.color), so the effect's visibility is INDEPENDENT of the border's
-- own thickness. This matches user expectation that picking "Blink" at borderSize
-- 1 still produces an obvious strobe.
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

    local r, g, b, a = readColor(anim.color or ANIM_GOLD)
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

-- Shared positioning rectangle for animation effects: anchored to the
-- border itself (so animations follow the border's own offset/inset) and
-- adjusted by anim.inset / anim.offsetX / anim.offsetY for animation-
-- specific positioning. Both families route through this:
--   - Driver effects (DF Proc / DF Flash / DF Chase / DF Pixel / …) parent
--     their art to animRect, so they render at this rectangle's geometry.
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

-- ===== DF_ORBIT (orbiting sparkles — DF-owned AutoCastGlow stand-in) =====
-- A faithful reimplementation of LibCustomGlow's AutoCastGlow: N*4 shine
-- sparkles in four size layers orbit the border perimeter at four staggered
-- speeds, producing the shimmering "autocast" trail. It uses the SAME Blizzard
-- shine texture LCG does (a plain game asset, not a library-owned one), so the
-- look matches — but it runs on OUR shared OnUpdate driver off our own
-- textures parented to the animRect, so unlike the LCG glow it is taint-safe on
-- 12.1 aura container buttons (it never SetParents onto the native button, and
-- reads _knownW/_knownH so it never measures a secret rect).
local ORBIT_SHINE_TEX   = [[Interface\Artifacts\Artifacts]]
local ORBIT_SHINE_COORD = { 0.8115234375, 0.9169921875, 0.8798828125, 0.9853515625 }
local ORBIT_LAYER_SIZES = { 7, 6, 5, 4 }   -- four layers, outer→inner (LCG parity)
-- Seconds for one full orbit at Frequency 1 (the effect's natural resting pace).
-- Frequency scales this: freq 2 = twice as fast, freq 0.5 = half. The motion is
-- size-independent (advances in perimeter fractions), so this reads the same on a
-- small aura icon and a large AD border.
local ORBIT_BASE_PERIOD = 8

-- Stop every DECLARATIVE animation group this border owns, whichever effect built
-- them (see "DECLARATIVE EFFECTS" below). One list for all of them: only one effect
-- runs at a time, because StopAnimation always clears before a start.
--
-- Guarded per group: these live on regions under a container button, and teardown
-- runs at the very moment those go restricted -- an unguarded throw here would unwind
-- out of StopAnimation and skip the rest of its teardown, which is exactly the shape
-- of bug #1079.
local function stopDeclAnims(border)
    local groups = border._declAnims
    if not groups then return end
    for i = 1, #groups do
        local ag = groups[i]
        if ag then pcall(ag.Stop, ag) end
    end
    border._declAnims = nil
end

local function hideOrbitParticles(border)
    if not border.orbitTex then return end
    for _, t in ipairs(border.orbitTex) do t:Hide() end
end

local function setupOrbitParticles(border, anim)
    local host = ensureAnimRect(border, anim.inset, anim.offsetX, anim.offsetY)
    border._orbitHost = host
    local N = anim.particles
    if not N or N < 1 then N = 4 end
    if N > 16 then N = 16 end
    local total = N * 4
    local scale = anim.scale or 1
    local r, g, b, a = readColor(anim.color or ANIM_GOLD)
    border.orbitTex = border.orbitTex or {}
    local tex = border.orbitTex
    for i = 1, total do
        local t = tex[i]
        if not t then
            t = host:CreateTexture(nil, "OVERLAY")
            t:SetTexture(ORBIT_SHINE_TEX)
            t:SetTexCoord(ORBIT_SHINE_COORD[1], ORBIT_SHINE_COORD[2], ORBIT_SHINE_COORD[3], ORBIT_SHINE_COORD[4])
            t:SetDesaturated(true)
            t:SetBlendMode("ADD")
            tex[i] = t
        end
        t:SetParent(host)
        t:SetVertexColor(r, g, b, a)
        t:Show()
    end
    -- Layer k (1=outermost) holds N sparkles at ORBIT_LAYER_SIZES[k] * scale.
    for k = 1, 4 do
        local sz = ORBIT_LAYER_SIZES[k] * scale
        for i = 1, N do
            local t = tex[i + N * (k - 1)]
            if t then t:SetSize(sz, sz) end
        end
    end
    -- Park any surplus textures left over from a previous higher-N config.
    for i = total + 1, #tex do tex[i]:Hide() end
    border._orbitN = N
    border._orbitTimers = border._orbitTimers or { 0, 0, 0, 0 }
    -- Frequency is a MULTIPLIER on ORBIT_BASE_PERIOD, not a raw 1/freq: freq 1 =
    -- the calm designed pace, freq 2 = twice as fast. (The old 1/freq made freq 1
    -- a frantic 1-orbit-per-second — far past "normal".)
    local freq = (anim.frequency and anim.frequency > 0) and anim.frequency or 1
    border._orbitPeriod = ORBIT_BASE_PERIOD / freq
end

-- Position every sparkle around the perimeter; four layers advance at staggered
-- speeds (period*k) for the shimmer. Mirrors LCG acUpdate. Reads _knownW/_knownH
-- first so it never measures (and taints) a secret container-button rect.
local function orbitTick(border, anim, dt)
    local host = border._orbitHost; if not host then return end
    local tex = border.orbitTex;   if not tex then return end
    local w = border._knownW or host:GetWidth()
    local h = border._knownH or host:GetHeight()
    -- Particles anchor to the animRect (host), which ensureAnimRect insets by anim.inset
    -- (negative = larger). _knownW/_knownH are the BORDER's raw size (secret-rect safe), so
    -- inset-adjust them to the host's actual size — else the perimeter walk and the anchor
    -- box disagree and the loop "breaks" mid-cycle. (host:GetWidth() is already host-sized.)
    if border._knownW then w = w - 2 * (anim.inset or 0) end
    if border._knownH then h = h - 2 * (anim.inset or 0) end
    if not w or not h or w <= 0 or h <= 0 then return end
    local perimeter = 2 * (w + h)
    local bottomlim = h * 2 + w
    local rightlim  = h + w
    local N = border._orbitN or 4
    local space = perimeter / N
    local period = border._orbitPeriod or 8
    local timers = border._orbitTimers
    local idx = 0
    for k = 1, 4 do
        timers[k] = (timers[k] + dt / (period * k)) % 1
        local base = perimeter * timers[k]
        for i = 1, N do
            idx = idx + 1
            local t = tex[idx]
            if t then
                local pos = (space * i + base) % perimeter
                t:ClearAllPoints()
                if pos > bottomlim then
                    t:SetPoint("CENTER", host, "BOTTOMRIGHT", -pos + bottomlim, 0)
                elseif pos > rightlim then
                    t:SetPoint("CENTER", host, "TOPRIGHT", 0, -pos + rightlim)
                elseif pos > h then
                    t:SetPoint("CENTER", host, "TOPLEFT", pos - h, 0)
                else
                    t:SetPoint("CENTER", host, "BOTTOMLEFT", 0, pos)
                end
            end
        end
    end
end

-- ===== DF_ORBIT, DECLARATIVE (the same motion, driven C-side) =====
--
-- ☠ WHY THE SAME EFFECT EXISTS TWICE. orbitTick above walks the sparkles by SetPoint
-- from Lua on every frame. On a CONTAINER-hosted border those textures are descendants
-- of a Blizzard aura button, which refuses tainted writes while auras are secret -- so
-- the tick is refused in exactly the content the effect exists for. That is not a
-- theory: bug #1079 was a single SetAlpha on an edge texture throwing ~197 times on
-- entering an instance. An OnUpdate driver cannot win there.
--
-- A declarative AnimationGroup is not a script and is never touched after creation, so
-- it runs through the restriction untouched. Built and :Play()ed on the border's FIRST
-- Apply -- which for a container border is inside initializeFrame, the secure context.
--
-- ★ IT IS THE SAME WALK, deliberately. Leg order and start corner match orbitTick
-- exactly (up the left edge from BOTTOMLEFT, right along the top, down the right edge,
-- left along the bottom), so a sparkle at perimeter position `pos` lands where the tick
-- would put it, and layer k orbits in period*k seconds for the same shimmer stagger.
-- Keep the two in step if either is edited.
--
-- ⚠ CREATION-FROZEN. Nothing here can be retuned afterwards without a tainted write
-- into the button subtree, so for a container border every animation key is STRUCTURAL:
-- the AD factory folds them into the border's struct signature and a change rebuilds the
-- slot. Same contract as the pandemic FLASH.
--
-- ⚠ Geometry comes from _knownW/_knownH (plain config numbers fed by the caller), never
-- from measuring the host -- a container button's rect is secret. No geometry, no
-- declarative build: the caller falls back to the tick rather than guessing.

-- Perimeter leg directions, in walk order: up, right, down, left.
local ORBIT_LEG_DIRS = { { 0, 1 }, { 1, 0 }, { 0, -1 }, { -1, 0 } }
local ORBIT_EPS = 0.0001

-- Anchor a sparkle at perimeter position `pos` -- the exact branch orbitTick uses.
local function orbitAnchor(t, host, pos, w, h)
    local rightlim, bottomlim = h + w, h * 2 + w
    t:ClearAllPoints()
    if pos > bottomlim then
        t:SetPoint("CENTER", host, "BOTTOMRIGHT", -pos + bottomlim, 0)
    elseif pos > rightlim then
        t:SetPoint("CENTER", host, "TOPRIGHT", 0, -pos + rightlim)
    elseif pos > h then
        t:SetPoint("CENTER", host, "TOPLEFT", pos - h, 0)
    else
        t:SetPoint("CENTER", host, "BOTTOMLEFT", 0, pos)
    end
end

-- One full loop of ordered Translations starting from `pos`. The offsets sum to zero, so
-- a REPEAT group returns the sparkle to its anchor each cycle and never drifts -- which
-- is what makes the loop seamless without any Lua re-seeding it.
local function buildOrbitLoop(ag, pos, w, h, period)
    local perimeter = 2 * (w + h)
    local legLen = { h, w, h, w }
    -- Which leg `pos` sits in, and how far into it.
    local leg, into = 1, pos % perimeter
    for i = 1, 4 do
        if into < legLen[i] then leg = i; break end
        into = into - legLen[i]
    end
    local remaining, idx, skip, order = perimeter, leg, into, 0
    while remaining > ORBIT_EPS do
        -- skip is non-zero only on the first (partial) leg; every later leg is whole.
        -- legLen entries are > 0 (the caller rejects a degenerate rect), so d is always
        -- positive and the walk terminates.
        local d = legLen[idx] - skip
        skip = 0
        if d > remaining then d = remaining end
        if d > ORBIT_EPS then
            order = order + 1
            local dir = ORBIT_LEG_DIRS[idx]
            local tr = ag:CreateAnimation("Translation")
            tr:SetOffset(dir[1] * d, dir[2] * d)
            tr:SetDuration(period * d / perimeter)
            tr:SetOrder(order)
            tr:SetSmoothing("NONE")   -- constant speed; easing would pulse at each corner
        end
        remaining = remaining - d
        idx = idx % 4 + 1
    end
    return order
end

-- Returns true when the declarative orbit was built and started. False means "no usable
-- geometry" and the caller should fall back to the OnUpdate tick.
local function buildOrbitAnims(border, anim)
    local host, tex = border._orbitHost, border.orbitTex
    if not (host and tex) then return false end
    local w, h = border._knownW, border._knownH
    if not (w and h) then return false end
    -- Same inset adjustment orbitTick applies: _knownW/H are the BORDER's raw size, and
    -- the particles anchor to the animRect, which ensureAnimRect has already inset.
    w = w - 2 * (anim.inset or 0)
    h = h - 2 * (anim.inset or 0)
    if w <= 0 or h <= 0 then return false end
    local perimeter = 2 * (w + h)
    local N = border._orbitN or 4
    local space = perimeter / N
    local basePeriod = border._orbitPeriod or ORBIT_BASE_PERIOD
    local groups, idx = {}, 0
    for k = 1, 4 do
        -- Layer k takes period*k for one orbit -- the tick's dt/(period*k).
        local period = basePeriod * k
        for i = 1, N do
            idx = idx + 1
            local t = tex[idx]
            if t then
                local pos = (space * i) % perimeter
                orbitAnchor(t, host, pos, w, h)
                local ag = t:CreateAnimationGroup()
                ag:SetLooping("REPEAT")
                buildOrbitLoop(ag, pos, w, h, period)
                ag:Play()
                groups[#groups + 1] = ag
            end
        end
    end
    if #groups == 0 then return false end
    border._declAnims = groups
    return true
end

-- ===== DECLARATIVE EFFECTS — shared machinery =====
--
-- Everything below builds C-side AnimationGroups for an effect that normally runs on
-- the shared OnUpdate driver, for the one case where that driver cannot run: a border
-- whose regions are descendants of a Blizzard aura button. Same rules throughout:
-- built on the border's FIRST Apply (inside initializeFrame), never touched again,
-- geometry from _knownW/_knownH rather than measured, and every group pushed onto
-- border._declAnims so StopAnimation can stop them.
--
-- ★ THE MARCHING TRICK, used by DF Dash and DF Pixel. A per-edge CLIP frame is pinned
-- to the edge; a MOVER fills it; the quads hang off the mover at fixed positions, some
-- of them deliberately outside the clip; one Translation slides the mover by exactly
-- one spacing and loops. Because the quads are spaced by that same distance, the state
-- after one loop is identical to the state before it, so the snap-back is invisible and
-- nothing has to re-seed positions in Lua. The clip is what lets a quad leave the edge
-- and another enter without either being repositioned.
local function ensureMarchEdge(store, key, parent)
    local e = store[key]
    if not e then
        e = { quads = {} }
        e.clip = CreateFrame("Frame", nil, parent)
        e.clip:SetClipsChildren(true)
        e.mover = CreateFrame("Frame", nil, e.clip)
        e.mover:SetAllPoints(e.clip)
        store[key] = e
    end
    e.clip:Show()
    return e
end

-- One quad on the mover, created on demand. Surplus quads from a previous (larger)
-- configuration are hidden by the caller.
local function marchQuad(e, i)
    local q = e.quads[i]
    if not q then
        q = e.mover:CreateTexture(nil, "OVERLAY")
        e.quads[i] = q
    end
    q:Show()
    return q
end

-- Slide `e.mover` by (dx, dy) over `duration` seconds, forever.
local function playMarch(e, dx, dy, duration, groups)
    local ag = e.mover:CreateAnimationGroup()
    ag:SetLooping("REPEAT")
    local tr = ag:CreateAnimation("Translation")
    tr:SetOffset(dx, dy)
    tr:SetDuration(duration)
    tr:SetSmoothing("NONE")
    ag:Play()
    groups[#groups + 1] = ag
    return ag
end

-- Hold `region` at `from` then at `to`, forever — a hard on/off strobe rather than a
-- fade. An Alpha animation whose from and to match simply holds that value for its
-- duration, so two of them in order give a square wave with instant edges.
local function playStrobe(region, from, to, halfPeriod, groups)
    local ag = region:CreateAnimationGroup()
    ag:SetLooping("REPEAT")
    local on = ag:CreateAnimation("Alpha")
    on:SetFromAlpha(from); on:SetToAlpha(from)
    on:SetDuration(halfPeriod); on:SetOrder(1)
    local off = ag:CreateAnimation("Alpha")
    off:SetFromAlpha(to); off:SetToAlpha(to)
    off:SetDuration(halfPeriod); off:SetOrder(2)
    ag:Play()
    groups[#groups + 1] = ag
    return ag
end

-- Fade `region` from `lo` up to `hi` and back, forever. IN_OUT smoothing gives the
-- zero-slope endpoints the cosine wave in the pulsate tick produces, so each cycle
-- blends into the next with no seam at the loop point.
local function playFade(region, lo, hi, halfPeriod, groups)
    local ag = region:CreateAnimationGroup()
    ag:SetLooping("REPEAT")
    local down = ag:CreateAnimation("Alpha")
    down:SetFromAlpha(hi); down:SetToAlpha(lo)
    down:SetDuration(halfPeriod); down:SetOrder(1); down:SetSmoothing("IN_OUT")
    local up = ag:CreateAnimation("Alpha")
    up:SetFromAlpha(lo); up:SetToAlpha(hi)
    up:SetDuration(halfPeriod); up:SetOrder(2); up:SetSmoothing("IN_OUT")
    ag:Play()
    groups[#groups + 1] = ag
    return ag
end

-- A one-shot alpha ramp that STAYS where it lands (SetToFinalAlpha). Used to build the
-- intro choreography of DF Proc / DF Flash out of pure alpha, with no Lua timeline.
-- `hold` delays the ramp so several regions can hand off to each other in sequence.
local function playAlphaOnce(region, from, to, hold, dur, groups)
    local ag = region:CreateAnimationGroup()
    ag:SetToFinalAlpha(true)
    local order = 1
    if hold and hold > 0 then
        local wait = ag:CreateAnimation("Alpha")
        wait:SetFromAlpha(from); wait:SetToAlpha(from)
        wait:SetDuration(hold); wait:SetOrder(order)
        order = order + 1
    end
    local ramp = ag:CreateAnimation("Alpha")
    ramp:SetFromAlpha(from); ramp:SetToAlpha(to)
    ramp:SetDuration(dur or 0.001); ramp:SetOrder(order)
    ag:Play()
    groups[#groups + 1] = ag
    return ag
end

-- A looping flipbook over a grid, the native equivalent of the hand-stepped
-- SetTexCoord walks in DF Proc and DF Flash. frameW/frameH of 0 means "derive from the
-- texture's own rect", which is what makes it work on an ATLAS sub-rect — the recipe
-- LibCustomGlow uses on these very same Blizzard sheets.
local function playFlipBook(region, rows, cols, frames, frameW, frameH, duration, groups)
    local ag = region:CreateAnimationGroup()
    ag:SetLooping("REPEAT")
    local fb = ag:CreateAnimation("FlipBook")
    fb:SetDuration(duration)
    fb:SetOrder(1)
    fb:SetFlipBookRows(rows)
    fb:SetFlipBookColumns(cols)
    fb:SetFlipBookFrames(frames)
    fb:SetFlipBookFrameWidth(frameW or 0)
    fb:SetFlipBookFrameHeight(frameH or 0)
    ag:Play()
    groups[#groups + 1] = ag
    return ag
end

-- ===== DF_DASH (dashed / marching-ants border) =====
-- A dashed border, static OR marching. One effect — the Animation Frequency is
-- the march SPEED (0 = static "dashed", >0 = animated). Draws a pool of dash
-- textures per edge on the OVERLAY layer, each clipped to its edge so the pattern
-- flows around the corners; the dashes use the animation's own colour / thickness
-- / inset (fixed dash length + gap — no particle/length knobs). Reads
-- _knownW/_knownH so it never measures a secret container rect; runs on the shared
-- driver off our own textures (taint-safe on aura buttons).
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
    -- Declarative edges first: hiding the clip frame takes its mover and every dash
    -- with it, so the quads need no individual pass.
    if border._dashDecl then
        for _, e in pairs(border._dashDecl) do
            if e.clip then e.clip:Hide() end
        end
    end
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
    local fw, fh = border._knownW or border:GetWidth(), border._knownH or border:GetHeight()
    if not fw or not fh or fw <= 0 or fh <= 0 then return end
    local width  = fw - inset * 2
    local height = fh - inset * 2
    if width <= 0 or height <= 0 then return end
    drawDashEdgeH(border, pool.bottom, false, offset,                      width,  th, inset, r, g, b, a)
    drawDashEdgeV(border, pool.left,   false, width + offset,              height, th, inset, r, g, b, a)
    drawDashEdgeH(border, pool.top,    true,  width + height - offset,     width,  th, inset, r, g, b, a)
    drawDashEdgeV(border, pool.right,  true,  2 * width + height - offset, height, th, inset, r, g, b, a)
end

-- DF_DASH, DECLARATIVE. The tick above redraws every dash each frame by recomputing
-- its clipped extent; here the clipping is done by a frame instead, and one Translation
-- per edge slides a fixed set of dashes by exactly one pattern length.
--
-- ★ The seed phases reproduce the tick's cumulative perimeter offsets (bottom 0, left
-- `width`, top `width+height`, right `2*width+height`), so the pattern stays continuous
-- around the corners exactly as it does today. Direction matches too: clockwise on
-- screen — up the left edge, right along the top, down the right, left along the bottom.
--
-- ⚠ Static dashes (frequency 0) are NOT built here: with nothing to march there is no
-- animation to declare, and the tick path draws them once and stops. The caller checks.
local function buildDashAnims(border, anim, th, inset, r, g, b, a, marchSpeed)
    if not (marchSpeed and marchSpeed > 0) then return false end
    local fw, fh = border._knownW, border._knownH
    if not (fw and fh) then return false end
    local width, height = fw - inset * 2, fh - inset * 2
    if width <= 0 or height <= 0 then return false end
    local P = DF_DASH_PATTERN
    local dur = P / marchSpeed
    border._dashDecl = border._dashDecl or {}
    local store = border._dashDecl
    local groups = border._declAnims or {}
    -- key, edge length, seed offset, travel, and how the clip frame sits on the border.
    local edges = {
        { key = "bottom", len = width,  seed = 0,                    dx = -P, dy = 0,
          horiz = true,  point = "BOTTOMLEFT",  ox = inset,  oy = inset },
        { key = "left",   len = height, seed = width,                dx = 0,  dy = P,
          horiz = false, point = "TOPLEFT",     ox = inset,  oy = -inset },
        { key = "top",    len = width,  seed = width + height,       dx = P,  dy = 0,
          horiz = true,  point = "TOPLEFT",     ox = inset,  oy = -inset },
        { key = "right",  len = height, seed = 2 * width + height,   dx = 0,  dy = -P,
          horiz = false, point = "TOPRIGHT",    ox = -inset, oy = -inset },
    }
    for _, ed in ipairs(edges) do
        local e = ensureMarchEdge(store, ed.key, border)
        e.clip:ClearAllPoints()
        e.clip:SetPoint(ed.point, border, ed.point, ed.ox, ed.oy)
        e.clip:SetSize(ed.horiz and ed.len or th, ed.horiz and th or ed.len)
        local startPos = -(ed.seed % P)
        local count = math.ceil(ed.len / P) + 2
        for i = 1, count do
            local dashStart = startPos + (i - 1) * P
            local q = marchQuad(e, i)
            q:SetColorTexture(r, g, b, a)
            q:ClearAllPoints()
            if ed.horiz then
                q:SetSize(DF_DASH_LEN, th)
                q:SetPoint("BOTTOMLEFT", e.mover, "BOTTOMLEFT", dashStart, 0)
            else
                q:SetSize(th, DF_DASH_LEN)
                -- Vertical edges measure DOWNWARD from the top, matching drawDashEdgeV.
                q:SetPoint("TOPLEFT", e.mover, "TOPLEFT", 0, -dashStart)
            end
        end
        for i = count + 1, #e.quads do e.quads[i]:Hide() end
        playMarch(e, ed.dx, ed.dy, dur, groups)
    end
    border._declAnims = groups
    return true
end

-- ===== DF_PIXEL (chasing pixels — discrete bars) =====
-- N plain rectangles chase around the perimeter with even gaps, each oriented
-- along the edge it's on (a horizontal bar on top/bottom, a vertical bar on
-- left/right). Center-anchored, so it does NOT wrap the corners — that discrete
-- look is the point (DF Dash is the corner-wrapping marching variant). Shares the
-- taint-safe perimeter walk + _knownW/_knownH of DF Orbit.
local PIXEL_TEX = [[Interface\BUTTONS\WHITE8X8]]
-- Seconds for one full lap at Frequency 1 (the effect's natural resting pace).
-- Frequency scales this the same way DF Chase does; the walk advances in
-- perimeter fractions, so the pace is size-independent.
local PIXEL_BASE_PERIOD = 4

local function hidePixelParticles(border)
    -- Declarative edges first — see hideDashPool.
    if border._pixelDecl then
        for _, e in pairs(border._pixelDecl) do
            if e.clip then e.clip:Hide() end
        end
    end
    if not border.pixelTex then return end
    for _, t in ipairs(border.pixelTex) do t:Hide() end
end

local function setupPixelParticles(border, anim)
    local host = ensureAnimRect(border, anim.inset, anim.offsetX, anim.offsetY)
    border._pixelHost = host
    local N = anim.particles
    if not N or N < 1 then N = 8 end
    if N > 16 then N = 16 end
    local th = anim.thickness or 2; if th < 1 then th = 1 end
    local len = anim.length or 6;   if len < 1 then len = 1 end
    local r, g, b, a = readColor(anim.color or ANIM_GOLD)
    border.pixelTex = border.pixelTex or {}
    local tex = border.pixelTex
    for i = 1, N do
        local t = tex[i]
        if not t then
            t = host:CreateTexture(nil, "OVERLAY")
            t:SetTexture(PIXEL_TEX)
            tex[i] = t
        end
        t:SetParent(host)
        t:SetVertexColor(r, g, b, a)
        t:Show()
    end
    for i = N + 1, #tex do tex[i]:Hide() end
    border._pixelN = N
    border._pixelLen = len
    border._pixelTh = th
    border._pixelTimer = border._pixelTimer or 0
    -- Frequency multiplies PIXEL_BASE_PERIOD (freq 1 = calm, freq 2 = 2× faster),
    -- matching DF Chase — see ORBIT_BASE_PERIOD for the rationale.
    local freq = (anim.frequency and anim.frequency > 0) and anim.frequency or 1
    border._pixelPeriod = PIXEL_BASE_PERIOD / freq
end

local function pixelTick(border, anim, dt)
    local host = border._pixelHost; if not host then return end
    local tex = border.pixelTex;   if not tex then return end
    local w = border._knownW or host:GetWidth()
    local h = border._knownH or host:GetHeight()
    -- Particles anchor to the animRect (host), which ensureAnimRect insets by anim.inset
    -- (negative = larger). _knownW/_knownH are the BORDER's raw size (secret-rect safe), so
    -- inset-adjust them to the host's actual size — else the perimeter walk and the anchor
    -- box disagree and the loop "breaks" mid-cycle. (host:GetWidth() is already host-sized.)
    if border._knownW then w = w - 2 * (anim.inset or 0) end
    if border._knownH then h = h - 2 * (anim.inset or 0) end
    if not w or not h or w <= 0 or h <= 0 then return end
    local perimeter = 2 * (w + h)
    local bottomlim = h * 2 + w
    local rightlim  = h + w
    local N   = border._pixelN or 8
    local len = border._pixelLen or 6
    local th  = border._pixelTh or 2
    local space  = perimeter / N
    local period = border._pixelPeriod or 4
    border._pixelTimer = (border._pixelTimer + dt / period) % 1
    local base = perimeter * border._pixelTimer
    for i = 1, N do
        local t = tex[i]
        if t then
            local pos = (space * i + base) % perimeter
            t:ClearAllPoints()
            if pos > bottomlim then          -- bottom edge (horizontal bar)
                t:SetSize(len, th)
                t:SetPoint("CENTER", host, "BOTTOMRIGHT", -pos + bottomlim, 0)
            elseif pos > rightlim then       -- right edge (vertical bar)
                t:SetSize(th, len)
                t:SetPoint("CENTER", host, "TOPRIGHT", 0, -pos + rightlim)
            elseif pos > h then              -- top edge (horizontal bar)
                t:SetSize(len, th)
                t:SetPoint("CENTER", host, "TOPLEFT", pos - h, 0)
            else                             -- left edge (vertical bar)
                t:SetSize(th, len)
                t:SetPoint("CENTER", host, "BOTTOMLEFT", 0, pos)
            end
        end
    end
end

-- DF_PIXEL, DECLARATIVE.
--
-- ☠ THIS IS NOT THE ORBIT WITH DIFFERENT ART, and that is the whole difficulty. A
-- chasing pixel is a BAR that changes orientation at every corner — horizontal along
-- the top and bottom, vertical up the sides — and a Translation cannot resize its
-- target mid-flight. So the perimeter walk that carries DF Chase cannot carry this.
--
-- Instead each edge owns bars of its own fixed orientation, marching along it and
-- clipped to it: a bar leaving one edge is clipped away while the next enters at the
-- far end, which reads the same because every bar is identical. Spacing is seeded from
-- the CUMULATIVE perimeter position, so bars stay evenly spaced across the corners and
-- the lap time is unchanged.
--
-- ⚠ The one visible difference from the tick: the tick lets a bar overhang a corner
-- (it is centre-anchored on the edge line), while a clipped bar is cut at the corner
-- instead. On a bar the length of a pixel that is a couple of frames of travel.
local function buildPixelAnims(border, anim)
    local host = border._pixelHost
    if not host then return false end
    local w, h = border._knownW, border._knownH
    if not (w and h) then return false end
    w = w - 2 * (anim.inset or 0)
    h = h - 2 * (anim.inset or 0)
    if w <= 0 or h <= 0 then return false end
    local N      = border._pixelN or 8
    local len    = border._pixelLen or 6
    local th     = border._pixelTh or 2
    local period = border._pixelPeriod or PIXEL_BASE_PERIOD
    local perimeter = 2 * (w + h)
    local space = perimeter / N
    if space <= 0 or period <= 0 then return false end
    -- One spacing of travel per loop; a full lap therefore still takes `period`.
    local dur = period / N
    border._pixelDecl = border._pixelDecl or {}
    local store = border._pixelDecl
    local groups = border._declAnims or {}
    local r, g, b, a = readColor(anim.color or ANIM_GOLD)
    -- edgeStart = where this edge begins along the perimeter walk, so the bar spacing
    -- carries across corners exactly as pixelTick's single modulo does.
    local edges = {
        { key = "left",   start = 0,         len = h, vert = true,  from = "BOTTOM", dx = 0,      dy = space,  sx = th,  sy = len, cp = "LEFT"   },
        { key = "top",    start = h,         len = w, vert = false, from = "LEFT",   dx = space,  dy = 0,      sx = len, sy = th,  cp = "TOP"    },
        { key = "right",  start = h + w,     len = h, vert = true,  from = "TOP",    dx = 0,      dy = -space, sx = th,  sy = len, cp = "RIGHT"  },
        { key = "bottom", start = 2 * h + w, len = w, vert = false, from = "RIGHT",  dx = -space, dy = 0,      sx = len, sy = th,  cp = "BOTTOM" },
    }
    for _, ed in ipairs(edges) do
        local e = ensureMarchEdge(store, ed.key, host)
        e.clip:ClearAllPoints()
        -- The clip straddles the edge LINE (bars are centre-anchored on it), and is
        -- exactly one bar thick, so a bar on the line fits without being trimmed.
        e.clip:SetSize(ed.vert and th or ed.len, ed.vert and ed.len or th)
        e.clip:SetPoint("CENTER", host, ed.cp, 0, 0)
        -- First bar at or before the edge start, then every `space` along it.
        local first = ((-ed.start) % space) - space
        local count = math.ceil(ed.len / space) + 2
        for i = 1, count do
            local at = first + (i - 1) * space
            local q = marchQuad(e, i)
            q:SetTexture(PIXEL_TEX)
            q:SetVertexColor(r, g, b, a)
            q:SetSize(ed.sx, ed.sy)
            q:ClearAllPoints()
            if ed.vert then
                -- "left" measures UP from the bottom, "right" measures DOWN from the top.
                q:SetPoint("CENTER", e.mover, ed.from, 0, (ed.from == "BOTTOM") and at or -at)
            else
                -- "top" measures RIGHT from the left, "bottom" measures LEFT from the right.
                q:SetPoint("CENTER", e.mover, ed.from, (ed.from == "LEFT") and at or -at, 0)
            end
        end
        for i = count + 1, #e.quads do e.quads[i]:Hide() end
        playMarch(e, ed.dx, ed.dy, dur, groups)
    end
    border._declAnims = groups
    return true
end

-- ===== DF_PROC (proc flare — DF-owned ProcGlow stand-in) =====
-- Steps Blizzard's proc-loop flipbook atlas BY HAND on the shared driver: the
-- native FlipBook AnimationGroup won't tick inside a container-button subtree
-- (same reason the particle effects use the external driver), so we advance the
-- 6×5 = 30-frame grid ourselves via SetTexCoord. Renders the golden proc glow
-- taint-safe on aura buttons. Parented to the animRect (never the native button).
local PROC_ATLAS          = "UI-HUD-ActionBar-Proc-Loop-Flipbook"
local PROC_START_ATLAS    = "UI-HUD-ActionBar-Proc-Start-Flipbook"
local PROC_ROWS           = 6
local PROC_COLS           = 5
local PROC_FRAMES         = 30
local PROC_START_DURATION = 1.2      -- one-shot intro flash length. Blizzard's flipbook runs
                                     -- 0.7s on a 45px action button; on ~24px aura icons the
                                     -- same motion covers less screen and reads too fast, so
                                     -- we play it slower
local PROC_BURST_SCALE    = 150 / 42 -- intro burst size ×icon, centered — Blizzard anchors the
                                     -- 150px start art on a 42px button; its final frames
                                     -- contract exactly onto the 1.4× loop ring
local PROC_LOOP_SPILL     = 0.2      -- loop glow spills this fraction of the icon beyond each
                                     -- edge (button+20%) — a border glow, not icon-fill

-- Advance a 6×5 = 30-frame flipbook atlas to the frame for `phase` in [0,1) via
-- SetTexCoord (both proc atlases share the grid).
local function stepProcFlipbook(t, info, phase)
    if not info then return end
    local f   = floor(phase * PROC_FRAMES) % PROC_FRAMES
    local col = f % PROC_COLS
    local row = floor(f / PROC_COLS)
    local fw = (info.rightTexCoord - info.leftTexCoord) / PROC_COLS
    local fh = (info.bottomTexCoord - info.topTexCoord) / PROC_ROWS
    local l  = info.leftTexCoord + col * fw
    local tp = info.topTexCoord  + row * fh
    t:SetTexCoord(l, l + fw, tp, tp + fh)
end

local function hideProcGlow(border)
    if border.procTex then border.procTex:Hide() end
    if border.procStartTex then border.procStartTex:Hide() end
end

-- ☠ C_Texture.GetAtlasInfo RETURNS A FRESH TABLE ON EVERY CALL, and setupProcGlow
-- asked for two of them per call — on a path that runs per proc-glowing element
-- (3.0% of trash allocation, 5.6% of boss). Both atlases are compile-time
-- constants, so their info is fetched once and shared.
--
-- Safe to share: every consumer only READS (.file, and stepProcFlipbook's frame
-- maths) — swept _procAtlas / _procStartAtlas for writes and there are none
-- beyond these two assignments.
--
-- Resolved lazily rather than at file scope: C_Texture may not be ready when this
-- file loads, and the old code re-checked it on every call.
local procAtlasInfo, procStartAtlasInfo, procAtlasResolved

local function setupProcGlow(border, anim)
    local host = ensureAnimRect(border, anim.inset, anim.offsetX, anim.offsetY)
    border._procHost = host
    if not procAtlasResolved then
        local getInfo = C_Texture and C_Texture.GetAtlasInfo
        if getInfo then
            procAtlasInfo      = getInfo(PROC_ATLAS)
            procStartAtlasInfo = getInfo(PROC_START_ATLAS)
            -- Only latch once the API actually answered; a nil result before the
            -- texture system is up would otherwise cache "no atlas" permanently
            -- and the proc glow would never draw for the rest of the session.
            -- ☠ BOTH atlases, not just the loop one. Latching on procAtlasInfo
            -- alone let a single nil START result freeze in permanently: the loop
            -- glow drew normally while the intro burst was silently dead on every
            -- border for the rest of the session, which reads as a design change
            -- rather than a fault. The pre-memo code re-fetched both on every
            -- setup, so it always recovered on the next one.
            procAtlasResolved = (procAtlasInfo ~= nil) and (procStartAtlasInfo ~= nil)
        end
    end
    border._procAtlas      = procAtlasInfo
    border._procStartAtlas = procStartAtlasInfo
    -- Colour handling: white keeps the atlas's native golden gradient; any other
    -- colour DESATURATES the art first so the tint reads clean (multiplying a
    -- strong colour over gold goes muddy).
    local r, g, b, a = readColor(anim.color or ANIM_WHITE)
    local desat = not (r > 0.985 and g > 0.985 and b > 0.985)
    -- LCG-style hand-off: the LOOP fills the icon, while the intro BURST is a
    -- larger, CENTERED texture whose flipbook art contracts down onto the loop by
    -- its final frame — so playing the burst fully then swapping to the loop reads
    -- as one smooth motion (no cross-fade). Alpha-only visibility (never IsShown —
    -- a secret boolean on container buttons).
    local t = border.procTex
    if not t then
        t = host:CreateTexture(nil, "OVERLAY")
        t:SetBlendMode("ADD")
        border.procTex = t
    end
    t:SetParent(host); t:ClearAllPoints(); t:SetAllPoints(host)
    if border._procAtlas then t:SetTexture(border._procAtlas.file) end
    t:SetDesaturated(desat); t:SetVertexColor(r, g, b, a)
    local s = border.procStartTex
    if not s then
        s = host:CreateTexture(nil, "OVERLAY")
        s:SetBlendMode("ADD")
        border.procStartTex = s
    end
    s:SetParent(host); s:ClearAllPoints()
    s:SetPoint("CENTER", host, "CENTER", 0, 0)   -- size set in the tick (needs the rect)
    if border._procStartAtlas then s:SetTexture(border._procStartAtlas.file) end
    s:SetDesaturated(desat); s:SetVertexColor(r, g, b, a)
    -- anim.procStart = the "Hide Intro Flash" toggle (default nil/false plays it).
    local showIntro = not anim.procStart
    border._procStartElapsed = showIntro and 0 or PROC_START_DURATION
    border._procGeomW, border._procGeomH = nil, nil   -- tick re-applies spill + burst size
    s:Show(); t:Show()
    s:SetAlpha(showIntro and 1 or 0)
    t:SetAlpha(showIntro and 0 or 1)
    border._procTimer = border._procTimer or 0
    local freq = (anim.frequency and anim.frequency > 0) and anim.frequency or nil
    border._procPeriod = freq and (1 / freq) or 1   -- loop period (seconds)
end

local function procTick(border, anim, dt)
    local t = border.procTex; if not t then return end
    local s = border.procStartTex
    local host = border._procHost
    -- Apply LCG geometry once w is known: the loop spills PROC_LOOP_SPILL beyond the
    -- icon (a border glow, not icon-fill), and the burst is PROC_BURST_SCALE× centered
    -- so its art contracts onto the loop. _knownW first — never read the secret rect.
    local w = border._knownW or (host and host:GetWidth())
    -- _knownW is the BORDER's fed width; the anim rect (host) additionally carries
    -- the animation inset (positive = inward/smaller). Fold it in so the burst
    -- contracts exactly onto the loop's inset-adjusted rect — otherwise the intro
    -- lands where the loop WOULD be at inset 0 and visibly jumps. (The non-secret
    -- fallback host:GetWidth() is already inset-adjusted.)
    if w and border._knownW then w = w - 2 * (anim.inset or 0) end
    local h = border._knownH or (host and host:GetHeight())
    if h and border._knownH then h = h - 2 * (anim.inset or 0) end
    if host and w and w > 0 and h and h > 0
        and (border._procGeomW ~= w or border._procGeomH ~= h) then
        border._procGeomW, border._procGeomH = w, h
        -- ☠ SPILL AND BURST ARE PER-AXIS, and both used to come from WIDTH alone.
        -- That is invisible on a square aura icon — where this effect grew up — and
        -- wrong on anything else: on a wide unit-frame border a width-derived vertical
        -- spill made the glow several times the frame's height, and a square burst
        -- ignored the frame's shape completely. Deriving each axis from its own
        -- dimension keeps the glow the same shape as the thing it is glowing around,
        -- and is a no-op wherever w == h.
        -- ★ SCALE multiplies the reach. The band's midline lands on the frame edge at
        -- scale 1; there is no exact "on the border" beyond that, because the bright
        -- band is a soft gradient baked into the art — so the residual is a knob, not a
        -- constant. At scale 1 the loop rect is identical to the pre-slider render; the
        -- burst is within 2px of it (it now sizes off the ROUNDED loop, which lands the
        -- contract-onto-loop hand-off on our actual rect rather than the ideal one).
        local sc = anim.scale or 1
        local offX = floor(w * PROC_LOOP_SPILL * sc + 0.5)
        local offY = floor(h * PROC_LOOP_SPILL * sc + 0.5)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT",     host, "TOPLEFT",     -offX,  offY)
        t:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT",  offX, -offY)
        -- Burst sized off the LOOP rect so the intro still contracts exactly onto it
        -- at any scale (the art's hand-off is loop-relative, not host-relative).
        if s then
            local k = PROC_BURST_SCALE / (1 + 2 * PROC_LOOP_SPILL)
            s:SetSize((w + 2 * offX) * k, (h + 2 * offY) * k)
        end
    end
    local period = border._procPeriod or 1
    border._procTimer = (border._procTimer + dt / period) % 1
    if border._procAtlas then stepProcFlipbook(t, border._procAtlas, border._procTimer) end
    local se = (border._procStartElapsed or PROC_START_DURATION) + dt
    if se < PROC_START_DURATION and s and border._procStartAtlas then
        border._procStartElapsed = se
        stepProcFlipbook(s, border._procStartAtlas, se / PROC_START_DURATION)
        s:SetAlpha(1); t:SetAlpha(0)
        return
    end
    border._procStartElapsed = PROC_START_DURATION
    if s then s:SetAlpha(0) end
    t:SetAlpha(1)
end

-- DF_PROC, DECLARATIVE. The comment on stepProcFlipbook says the native FlipBook
-- "won't tick inside a container-button subtree" — that was the same wrong reading that
-- retired animation everywhere, and this is its replacement. A FlipBook animation is
-- declarative, so it runs there; only the hand-stepping did not.
--
-- ★ SetAtlas, NOT SetTexture(info.file). A FlipBook with frame width/height 0 derives
-- its grid from the region's own texture rect, which is what confines the walk to the
-- atlas sub-rect instead of the whole sheet. This is LibCustomGlow's recipe on these
-- exact Blizzard atlases, and it is why the manual texcoord maths is not needed here.
--
-- The intro burst is a second, NON-looping group: flipbook once, then alpha to 0, with
-- SetToFinalAlpha so it stays gone. The loop's own fade-in is delayed by the intro
-- length, which reproduces the tick's hand-off without a timeline in Lua.
local function buildProcAnims(border, anim)
    local t, s, host = border.procTex, border.procStartTex, border._procHost
    if not (t and host) then return false end
    local w, h = border._knownW, border._knownH
    if not (w and h) then return false end
    w = w - 2 * (anim.inset or 0)
    h = h - 2 * (anim.inset or 0)
    if w <= 0 or h <= 0 then return false end
    if not border._procAtlas then return false end
    -- Geometry is applied once here instead of per tick: every number is plain config.
    -- Per-axis, for the reason spelled out in procTick — a width-derived spill turns a
    -- wide frame's glow into a tall blob.
    t:SetAtlas(PROC_ATLAS)
    -- Scale multiplies the reach, exactly as procTick does — see the note there.
    local sc = anim.scale or 1
    local offX = floor(w * PROC_LOOP_SPILL * sc + 0.5)
    local offY = floor(h * PROC_LOOP_SPILL * sc + 0.5)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT",     host, "TOPLEFT",     -offX,  offY)
    t:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT",  offX, -offY)
    local groups = border._declAnims or {}
    local showIntro = (not anim.procStart) and s and border._procStartAtlas
    if showIntro then
        s:SetAtlas(PROC_START_ATLAS)
        local k = PROC_BURST_SCALE / (1 + 2 * PROC_LOOP_SPILL)
        s:SetSize((w + 2 * offX) * k, (h + 2 * offY) * k)
        s:SetAlpha(1)
        local ag = s:CreateAnimationGroup()
        ag:SetToFinalAlpha(true)
        local fb = ag:CreateAnimation("FlipBook")
        fb:SetDuration(PROC_START_DURATION); fb:SetOrder(1)
        fb:SetFlipBookRows(PROC_ROWS); fb:SetFlipBookColumns(PROC_COLS)
        fb:SetFlipBookFrames(PROC_FRAMES)
        fb:SetFlipBookFrameWidth(0); fb:SetFlipBookFrameHeight(0)
        local out = ag:CreateAnimation("Alpha")
        out:SetFromAlpha(1); out:SetToAlpha(0)
        out:SetDuration(0.001); out:SetOrder(2)
        ag:Play()
        groups[#groups + 1] = ag
        t:SetAlpha(0)
        playAlphaOnce(t, 0, 1, PROC_START_DURATION, 0.001, groups)
    else
        if s then s:SetAlpha(0) end
        t:SetAlpha(1)
    end
    playFlipBook(t, PROC_ROWS, PROC_COLS, PROC_FRAMES, 0, 0, border._procPeriod or 1, groups)
    border._declAnims = groups
    return true
end

-- ===== DF_FLASH (button-glow flash — DF-owned ButtonGlow stand-in) =====
-- The classic action-button glow METHOD, reimplemented on our shared driver
-- (native Animations don't tick in container-button subtrees): a 0.5s intro where
-- an outer glow collapses (2F→F) while an inner glow expands (F/2→F) under a
-- bright spark flare, then the inner glow fades out as Blizzard's crawling "ants"
-- fade in — the outer glow lands at F and STAYS as the steady state, so nothing
-- jumps at the hand-off. F = icon + 40% (the classic glow-frame factor). Own code
-- + Blizzard-default textures (the SpellActivationOverlay sheets); alpha-only
-- visibility (IsShown is a secret boolean on container buttons).
local FLASH_SHEET       = [[Interface\SpellActivationOverlay\IconAlert]]
local FLASH_ANTS_TEX    = [[Interface\SpellActivationOverlay\IconAlertAnts]]
local FLASH_ANTS_FRAMES = 22
local FLASH_ANTS_COLS   = 5           -- 256/48 = 5 columns in the ants sheet
local FLASH_ANTS_FW     = 48 / 256    -- one frame's size in UV units
local FLASH_INTRO_DUR   = 0.8         -- full intro length (the classic glow runs 0.5s on a
                                      -- 45px action button; slower reads right on small aura
                                      -- icons). Glows land at 60%, hand-off fills the rest.
local FLASH_FRAME_SCALE = 1.4         -- F: glow frame = icon + 20% each side
-- Crop rectangles inside the IconAlert sheet (facts of the asset's layout):
local FLASH_UV_SPARK    = { 0.00781250, 0.61718750, 0.00390625, 0.26953125 }
local FLASH_UV_GLOW     = { 0.00781250, 0.50781250, 0.27734375, 0.52734375 }
local FLASH_UV_GLOWOVER = { 0.00781250, 0.50781250, 0.53515625, 0.78515625 }

local function hideFlashGlow(border)
    if border.flashSpark     then border.flashSpark:Hide()     end
    if border.flashInner     then border.flashInner:Hide()     end
    if border.flashInnerOver then border.flashInnerOver:Hide() end
    if border.flashOuter     then border.flashOuter:Hide()     end
    if border.flashOuterOver then border.flashOuterOver:Hide() end
    if border.flashAnts      then border.flashAnts:Hide()      end
    if border.flashTex       then border.flashTex:Hide()       end   -- legacy, earlier builds
    if border.flashBurst     then border.flashBurst:Hide()     end   -- legacy, earlier builds
    if border.flashStartTex  then border.flashStartTex:Hide()  end   -- legacy, earlier builds
end

-- One centered crop of the IconAlert sheet (default blend — the art carries its
-- own alpha; sizes are driven by the tick).
local function flashSheetTexture(border, key, layer, sub, uv)
    local host = border._flashHost
    local t = border[key]
    if not t then
        t = host:CreateTexture(nil, layer, nil, sub)
        border[key] = t
    end
    t:SetParent(host); t:ClearAllPoints()
    t:SetPoint("CENTER", host, "CENTER", 0, 0)
    t:SetTexture(FLASH_SHEET)
    t:SetTexCoord(uv[1], uv[2], uv[3], uv[4])
    return t
end

local function setupFlashGlow(border, anim)
    local host = ensureAnimRect(border, anim.inset, anim.offsetX, anim.offsetY)
    border._flashHost = host
    -- Colour handling mirrors DF Proc: white keeps the native golden art; any
    -- other colour desaturates first so the tint reads clean.
    local r, g, b, a = readColor(anim.color or ANIM_WHITE)
    local desat = not (r > 0.985 and g > 0.985 and b > 0.985)
    local spark     = flashSheetTexture(border, "flashSpark",     "BACKGROUND", 0, FLASH_UV_SPARK)
    local inner     = flashSheetTexture(border, "flashInner",     "ARTWORK",    0, FLASH_UV_GLOW)
    local innerOver = flashSheetTexture(border, "flashInnerOver", "ARTWORK",    1, FLASH_UV_GLOWOVER)
    local outer     = flashSheetTexture(border, "flashOuter",     "ARTWORK",    2, FLASH_UV_GLOW)
    local outerOver = flashSheetTexture(border, "flashOuterOver", "ARTWORK",    3, FLASH_UV_GLOWOVER)
    -- The bright "over" passes ride their base glow's rect (they fade during the
    -- intro to sell the flash).
    innerOver:ClearAllPoints(); innerOver:SetAllPoints(inner)
    outerOver:ClearAllPoints(); outerOver:SetAllPoints(outer)
    local ants = border.flashAnts
    if not ants then
        ants = host:CreateTexture(nil, "OVERLAY")
        border.flashAnts = ants
    end
    ants:SetParent(host); ants:ClearAllPoints()
    ants:SetPoint("CENTER", host, "CENTER", 0, 0)   -- size set in the tick (0.85 × F)
    ants:SetTexture(FLASH_ANTS_TEX)
    for _, t in next, { spark, inner, innerOver, outer, outerOver, ants } do
        t:SetDesaturated(desat); t:SetVertexColor(r, g, b, 1); t:Show()
    end
    border._flashMaxA = a   -- the colour's alpha caps every layer
    -- anim.procStart = the "Hide Intro Flash" toggle (default nil/false plays it).
    local showIntro = not anim.procStart
    border._flashIntroElapsed = showIntro and 0 or FLASH_INTRO_DUR
    border._flashGeomW, border._flashGeomH = nil, nil   -- tick re-sizes once known
    border._flashSettled = nil
    spark:SetAlpha(0); inner:SetAlpha(0); innerOver:SetAlpha(0)
    outer:SetAlpha(showIntro and 0 or a); outerOver:SetAlpha(0)
    ants:SetAlpha(showIntro and 0 or a)
    border._flashTimer = border._flashTimer or 0
    local freq = (anim.frequency and anim.frequency > 0) and anim.frequency or nil
    border._flashPeriod = freq and (1 / freq) or 0.5   -- ants march speed (classic = brisk)
end

local function flashTick(border, anim, dt)
    local outer = border.flashOuter; if not outer then return end
    local host = border._flashHost
    local spark, inner = border.flashSpark, border.flashInner
    local innerOver, outerOver = border.flashInnerOver, border.flashOuterOver
    local ants = border.flashAnts
    local maxA = border._flashMaxA or 1
    -- Size everything off the icon width once it's known (F = icon + 40%).
    -- _knownW first — never read the secret rect on container buttons.
    local w = border._knownW or (host and host:GetWidth())
    -- _knownW is the BORDER's fed width; the anim rect (host) additionally carries
    -- the animation inset (positive = inward/smaller). Fold it in — every flash
    -- layer is centre-anchored and sized off F, so without this the effect ignores
    -- Inset entirely on container icons. (The non-secret fallback host:GetWidth()
    -- is already inset-adjusted.)
    if w and border._knownW then w = w - 2 * (anim.inset or 0) end
    -- ☠ PER-AXIS, same correction as DF Proc: F used to be a single width-derived
    -- number and every layer was sized (F, F), so on a wide unit-frame border the glow
    -- was a big square that ignored the frame's shape. No-op wherever w == h, which is
    -- every aura icon — the surface this effect was built for.
    local h = border._knownH or (host and host:GetHeight())
    if h and border._knownH then h = h - 2 * (anim.inset or 0) end
    local Fw, Fh = border._flashFw, border._flashFh
    if host and w and w > 0 and h and h > 0
        and (border._flashGeomW ~= w or border._flashGeomH ~= h) then
        border._flashGeomW, border._flashGeomH = w, h
        -- Scale multiplies the reach past the edge (the FLASH_FRAME_SCALE - 1 part),
        -- not the whole frame — so scale 1 is byte-identical to the pre-slider render
        -- and 0.5 halves the overhang rather than shrinking the glow inside the frame.
        local sc = anim.scale or 1
        local k = 1 + (FLASH_FRAME_SCALE - 1) * sc
        Fw, Fh = w * k, h * k
        border._flashFw, border._flashFh = Fw, Fh
        border._flashSettled = nil   -- re-park the steady glow at the new F
        if ants then ants:SetSize(Fw * 0.85, Fh * 0.85) end
    end
    if not (Fw and Fh) then return end   -- no size yet — nothing to draw against
    -- March the ants every frame (mid-crawl when they fade in).
    local period = border._flashPeriod or 0.5
    border._flashTimer = (border._flashTimer + dt / period) % 1
    if ants then
        local f   = floor(border._flashTimer * FLASH_ANTS_FRAMES) % FLASH_ANTS_FRAMES
        local col = f % FLASH_ANTS_COLS
        local row = floor(f / FLASH_ANTS_COLS)
        local l   = col * FLASH_ANTS_FW
        local tp  = row * FLASH_ANTS_FW
        ants:SetTexCoord(l, l + FLASH_ANTS_FW, tp, tp + FLASH_ANTS_FW)
    end
    local ie = (border._flashIntroElapsed or FLASH_INTRO_DUR) + dt
    if ie < FLASH_INTRO_DUR then
        border._flashIntroElapsed = ie
        border._flashSettled = nil
        -- The whole timeline runs on normalized progress k so FLASH_INTRO_DUR
        -- stretches the entire choreography. Classic proportions: glows land at
        -- 60%, spark peaks at 40% and is gone by 80%, hand-off fills 60→100%.
        local k = ie / FLASH_INTRO_DUR
        -- Glows (0 → 60%): the outer collapses 2F→F at full alpha — it lands on
        -- its steady rect and never moves again; the inner expands F/2→F, its
        -- bright "over" pass fading as they land.
        local kg = min(k / 0.6, 1)
        -- Sizes are a SCALE on each axis now, not one square number.
        local outerK = 2 - kg
        outer:SetSize(Fw * outerK, Fh * outerK)
        outer:SetAlpha(maxA)
        if outerOver then outerOver:SetAlpha(maxA * (1 - kg)) end
        if inner then
            local innerK = 0.5 + 0.5 * kg
            inner:SetSize(Fw * innerK, Fh * innerK)
            -- holds full until the glows land, then hands off over the last 40%
            local ia = k < 0.6 and 1 or (1 - (k - 0.6) / 0.4)
            inner:SetAlpha(maxA * ia)
        end
        if innerOver then innerOver:SetAlpha(maxA * (1 - kg)) end
        -- Spark flare over the top: grows F→1.5F while brightening, shrinks back
        -- fading — gone by 80%.
        if spark then
            local sK, sA
            if k < 0.4 then
                local ks = k / 0.4
                sK, sA = 1 + 0.5 * ks, ks
            elseif k < 0.8 then
                local ks = (k - 0.4) / 0.4
                sK, sA = 1.5 - 0.5 * ks, 1 - ks
            else
                sK, sA = 1, 0
            end
            spark:SetSize(Fw * sK, Fh * sK)
            spark:SetAlpha(maxA * sA)
        end
        -- Ants crawl in during the last 40%, taking over from the inner glow.
        if ants then ants:SetAlpha(k < 0.6 and 0 or maxA * ((k - 0.6) / 0.4)) end
        return
    end
    -- Steady: outer glow parked at F under the marching ants (set once).
    border._flashIntroElapsed = FLASH_INTRO_DUR
    if not border._flashSettled then
        border._flashSettled = true
        outer:SetSize(Fw, Fh)
        outer:SetAlpha(maxA)
        if outerOver then outerOver:SetAlpha(0) end
        if spark then spark:SetAlpha(0) end
        if inner then inner:SetAlpha(0) end
        if innerOver then innerOver:SetAlpha(0) end
        if ants then ants:SetAlpha(maxA) end
    end
end

-- 22 ants frames in a 5-column sheet -> 5 rows. 48px frames in a 256px sheet, which is
-- the same 48/256 UV step the tick walks by hand.
local FLASH_ANTS_ROWS = 5
local FLASH_ANTS_PX   = 48

-- A one-shot alpha rise then fall that ends where it started. Local to DF Flash: it is
-- the only effect whose intro needs a peak rather than a ramp.
local function playAlphaOnceInOut(region, peak, rise, fall, groups)
    local ag = region:CreateAnimationGroup()
    ag:SetToFinalAlpha(true)
    local up = ag:CreateAnimation("Alpha")
    up:SetFromAlpha(0); up:SetToAlpha(peak)
    up:SetDuration(rise); up:SetOrder(1)
    local down = ag:CreateAnimation("Alpha")
    down:SetFromAlpha(peak); down:SetToAlpha(0)
    down:SetDuration(fall); down:SetOrder(2)
    ag:Play()
    groups[#groups + 1] = ag
    return ag
end

-- DF_FLASH, DECLARATIVE.
--
-- ☠ THE INTRO IS SIMPLIFIED HERE, DELIBERATELY, AND THIS IS THE ONE EFFECT THAT IS NOT
-- A FAITHFUL PORT. The tick's intro is a SIZE choreography — the outer glow collapses
-- 2F->F while the inner expands F/2->F under a spark that grows and shrinks. Expressing
-- that declaratively needs Scale animations, and Scale was built and tried on a
-- container button child in August and did NOTHING while Alpha worked (pandemic FLASH,
-- 2026-08-05). Shipping a size timeline that might silently not run would leave the
-- outer glow parked at 2F and read as broken, so the sizes are set to their STEADY
-- values at build time and the intro is played in alpha alone: the glows fade up, the
-- spark peaks and goes, the ants crawl in behind it. The steady state — an outer glow
-- at F under marching ants — is identical to the tick's, and that is what is on screen
-- for all but the first fraction of a second.
-- ⚠ Re-test Scale on a later build; if it works, the size timeline can come back here.
local function buildFlashAnims(border, anim)
    local outer, ants, host = border.flashOuter, border.flashAnts, border._flashHost
    if not (outer and ants and host) then return false end
    local w, h = border._knownW, border._knownH
    if not (w and h) then return false end
    w = w - 2 * (anim.inset or 0)
    h = h - 2 * (anim.inset or 0)
    if w <= 0 or h <= 0 then return false end
    -- Per-axis with the Scale knob on the overhang, exactly as flashTick does it.
    local sc = anim.scale or 1
    local k = 1 + (FLASH_FRAME_SCALE - 1) * sc
    local Fw, Fh = w * k, h * k
    border._flashFw, border._flashFh = Fw, Fh
    border._flashGeomW, border._flashGeomH = w, h
    border._flashSettled = true
    local maxA = border._flashMaxA or 1
    local spark, inner = border.flashSpark, border.flashInner
    local innerOver, outerOver = border.flashInnerOver, border.flashOuterOver
    -- Steady sizes, set once.
    outer:SetSize(Fw, Fh)
    if outerOver then outerOver:ClearAllPoints(); outerOver:SetAllPoints(outer) end
    if inner then inner:SetSize(Fw, Fh) end
    if innerOver then innerOver:ClearAllPoints(); innerOver:SetAllPoints(inner) end
    if spark then spark:SetSize(Fw * 1.5, Fh * 1.5) end
    ants:SetSize(Fw * 0.85, Fh * 0.85)
    local groups = border._declAnims or {}
    playFlipBook(ants, FLASH_ANTS_ROWS, FLASH_ANTS_COLS, FLASH_ANTS_FRAMES,
                 FLASH_ANTS_PX, FLASH_ANTS_PX, border._flashPeriod or 0.5, groups)
    local showIntro = not anim.procStart
    if showIntro then
        local d = FLASH_INTRO_DUR
        -- Same proportions as the tick's timeline: glows land at 60%, the spark peaks
        -- at 40% and is gone by 80%, the ants take over across the last 40%.
        outer:SetAlpha(0)
        playAlphaOnce(outer, 0, maxA, 0, d * 0.6, groups)
        if outerOver then outerOver:SetAlpha(0) end
        if inner then
            inner:SetAlpha(0)
            playAlphaOnceInOut(inner, maxA, d * 0.6, d * 0.4, groups)
        end
        if innerOver then innerOver:SetAlpha(0) end
        if spark then
            spark:SetAlpha(0)
            playAlphaOnceInOut(spark, maxA, d * 0.4, d * 0.4, groups)
        end
        ants:SetAlpha(0)
        playAlphaOnce(ants, 0, maxA, d * 0.6, d * 0.4, groups)
    else
        outer:SetAlpha(maxA)
        ants:SetAlpha(maxA)
        if outerOver then outerOver:SetAlpha(0) end
        if inner then inner:SetAlpha(0) end
        if innerOver then innerOver:SetAlpha(0) end
        if spark then spark:SetAlpha(0) end
    end
    border._declAnims = groups
    return true
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

-- The OnUpdate-driven custom effects modulate the OVERLAY textures created by
-- setupAnimOverlay (separate from the border's own edges), so their visibility
-- is independent of borderSize. The border underneath stays unchanged while the
-- animation plays on top of / outside it.

local customTicks = {}

-- BLINK: a hard on/off strobe on all four edges together — a crisp "alert"
-- pulse, distinct from DF_PULSATE's smooth fade. Frequency is blinks/second.
customTicks.BLINK = function(border, anim, elapsed)
    local o = border.animOverlay; if not o then return end
    local period = tickPeriod(anim, 1)
    local on = ((elapsed % period) / period) < 0.5 and 1 or 0
    if o.top    then o.top:SetAlpha(on)    end
    if o.right  then o.right:SetAlpha(on)  end
    if o.bottom then o.bottom:SetAlpha(on) end
    if o.left   then o.left:SetAlpha(on)   end
end

-- BLINK, DECLARATIVE. Four square waves, one per overlay edge. They are separate groups
-- rather than one, because an animation drives the object its group was created on and
-- these are four independent textures; started in the same frame with identical
-- durations, they stay in step C-side.
local function buildBlinkAnims(border, anim)
    local o = border.animOverlay
    if not o then return false end
    local period = tickPeriod(anim, 1)
    if not period or period <= 0 then return false end
    local groups = border._declAnims or {}
    local half = period * 0.5
    local n = 0
    for _, e in ipairs({ o.top, o.right, o.bottom, o.left }) do
        if e then playStrobe(e, 1, 0, half, groups); n = n + 1 end
    end
    if n == 0 then return false end
    border._declAnims = groups
    return true
end

-- DF_PULSATE, DECLARATIVE.
--
-- ☠ IT ANIMATES THE BORDER'S CONTENT, NOT THE BORDER FRAME — and that difference is
-- load-bearing, not tidiness. The tick drives the WRAPPER's alpha, which is also the
-- carrier for the out-of-range fade, so it has to fold the fade in itself on every
-- frame (SetAlphaFromBoolean against a possibly-secret inRange). A declarative group
-- has no way to fold in a value that changes at runtime: an Alpha animation on the
-- wrapper would simply overwrite the range fade, and an out-of-range frame would pulse
-- back to full. Animating the edges and pieces instead leaves the wrapper's alpha free
-- for the range system, and the two multiply — so the pulse and the fade compose
-- instead of fighting, which is strictly better than what the tick manages.
local function buildPulsateAnims(border, anim)
    local rawFreq = (anim.frequency and anim.frequency > 0) and anim.frequency or 1
    -- period = 2/freq, then half of it per direction — the tick's mapping exactly.
    local half = (2 / rawFreq) * 0.5
    local groups = border._declAnims or {}
    local n = 0
    local function add(region)
        if region then playFade(region, 0.05, 1, half, groups); n = n + 1 end
    end
    add(border.top); add(border.bottom); add(border.left); add(border.right)
    -- TEXTURE style paints 8 pieces (or a backdrop child) instead of the four edges.
    if border.texPieces then
        for _, p in pairs(border.texPieces) do add(p) end
    end
    if border.bd then add(border.bd) end
    if n == 0 then return false end
    border._declAnims = groups
    return true
end

-- ===== STATIC SHAPE MODES =====

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

    local r, g, b, a = readColor(anim.color or ANIM_GOLD)
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

-- (Removed 2026-07-16: Register/UnregisterExternalAnimTick — generic external
-- access to the shared anim driver, added for the AD expiry-alert element's
-- alpha animations. The element's region is a button child now, and PTR-5
-- forbids animating a forbidden button's subtree while auras are secret, so
-- the feature died with its only consumer. Re-add the thin wrappers around
-- registerAnimTick/unregisterAnimTick if a DF-owned off-button frame ever
-- needs the shared driver again.)

-- Stop every LCG glow we might have started AND tear down any custom
-- animator state. Cheap: each Stop is a no-op when its glow frame isn't
-- present; the driver Hide is a no-op when no driver exists.
function Border:StopAnimation(border)
    if not border then return end
    -- ☠ NEVER-ANIMATED BORDERS: leave without touching a single region.
    -- Every write below (overlay Hides, resetEdgeAlphas' SetAlpha(1) on the four
    -- edges) is undoing state that ONLY StartAnimation creates, so on a border
    -- that never started an animation they are pure no-ops -- and on an aura
    -- CONTAINER border they are no-ops on a Blizzard aura button's descendants.
    -- Those buttons carry DenyTaintedAccessWhenAurasAreSecret; the 12.1.0.69382
    -- client (2026-08-18) refuses tainted writes on their DESCENDANTS too, where
    -- earlier builds refused only the button itself. Container borders have
    -- animation stripped unconditionally (AuraContainer's ANIMATION FILTER), so
    -- this reset was the one write _teardownContainer still made to a restricted
    -- subtree -- and it threw on entering an instance, aborting the whole
    -- FullFrameRefresh above it (bug #1079: 197x "calling 'SetAlpha' on bad self",
    -- dispel borders/overlays gone). Skipping is not a guard around a needed
    -- write; there is nothing to reset. Only borders that DID animate reach the
    -- teardown below, and those are DF-owned frames off the button.
    if not border._animEver then
        border.activeAnimation = nil
        border._animHash = nil
        return
    end
    unregisterAnimTick(border)
    -- Declarative groups next: they are the other half of "this border is animating",
    -- and unlike the driver they keep running on their own until stopped.
    stopDeclAnims(border)
    -- Hide all overlay sets from prior animation passes. The cornerExtras
    -- field is from a previous-rev CORNERS_ONLY implementation; we keep
    -- the Hide-loop for backward compat on profiles where the field was
    -- already populated, then mark it nil so it's not referenced again.
    hideAnimOverlay(border)
    hideCornerOverlays(border)
    hideOrbitParticles(border)
    hideDashPool(border)
    hidePixelParticles(border)
    hideProcGlow(border)
    hideFlashGlow(border)
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
        -- ⚠ RESTORE THE OOR FADE, NOT FULL OPACITY. This block already exists because a
        -- blanket reset flashed out-of-range borders to full on every re-render; gating it
        -- on DF_PULSATE narrowed that to the one effect that owns wrapper alpha, but the
        -- value written was still a hard 1 -- so stopping a pulse on an OUT-OF-RANGE border
        -- did exactly what the comment above says this guard was added to prevent, just in
        -- a narrower case.
        --
        -- Same mechanism as the tick: test the plain flag, forward the (possibly secret)
        -- boolean, let SetAlphaFromBoolean choose. Falls back to 1 when the OOR pass has
        -- not stamped this border (whole-frame mode, or never range-checked).
        if border.dfOORActive and border.dfOORAlpha and border.SetAlphaFromBoolean then
            border:SetAlphaFromBoolean(border.dfOORInRange, 1, border.dfOORAlpha)
        else
            border:SetAlpha(1)
        end
    end
    border.activeAnimation = nil
    border._animHash = nil  -- ensure the next StartAnimation runs the full path
end

-- Build a comparable hash of the animation spec so StartAnimation can no-op
-- when called with the same config the border is already running.  Consumer
-- refresh paths (AD's RefreshLiveFramesThrottled re-syncs the containers → next
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

-- OnUpdate-driver effects: those whose motion is driven by the shared anim
-- driver's OnUpdate (as opposed to LCG glows or the static shape modes). The dedupe in
-- StartAnimation verifies the driver is actually live for these before no-opping.
local DRIVER_ANIMS = { DF_DASH = true, DF_PULSATE = true, BLINK = true, DF_ORBIT = true, DF_PROC = true, DF_FLASH = true, DF_PIXEL = true }

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
    -- ⚠ A DECLARATIVE effect counts as live too. It has no animRegistry entry by design
    -- (nothing ticks it), so without _declAnims here the "driver is dead, restart" arm
    -- would fire on EVERY re-apply and rebuild its animation groups from scratch — on a
    -- container border that is also a tainted write into the button subtree.
    if border._animHash == newHash then
        if not DRIVER_ANIMS[border.activeAnimation] or animRegistry[border] or border._declAnims then
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
        -- ⚠ A DECLARATIVE pulse cannot be retuned in place: its groups are frozen at
        -- creation and reaching back in would be a tainted write to a button child. A
        -- genuine speed change arrives as a container Rebuild instead (the animation
        -- keys ride the border's struct signature), so the right move here is to leave
        -- the running pulse alone rather than tear it down and fail to rebuild it.
        if not (border._secretRect and border._declAnims) then
            local rawFreq = (anim.frequency and anim.frequency > 0) and anim.frequency or 1
            border._dfPulsatePeriod = 2 / rawFreq
        end
        border._animHash = newHash
        return
    end
    -- Always clear before starting — see "Stop semantics" in the section
    -- header above.  StopAnimation NILs border._animHash, so the hash MUST be
    -- stamped AFTER it — otherwise every full start leaves the hash nil and the
    -- next Apply (AD re-applies ~3×/sec via the expiring ticker) mismatches and
    -- restarts the effect, making it flicker on every re-apply.
    self:StopAnimation(border)
    border._animHash = newHash
    -- From here on this border owns animation state; StopAnimation must do its
    -- full teardown on it from now on (see the never-animated early-out there).
    border._animEver = true

    -- Custom OnUpdate effects — render their own overlay textures, so the
    -- effect's visibility doesn't depend on the border's own thickness.
    local tick = customTicks[anim.type]
    if tick then
        setupAnimOverlay(border, anim)
        -- BLINK is the only customTick effect, and it has a declarative twin.
        if border._secretRect and anim.type == "BLINK" and buildBlinkAnims(border, anim) then
            border.activeAnimation = anim.type
            return
        end
        registerAnimTick(border, function(b, el)
            tick(b, anim, el)
        end)
        border.activeAnimation = anim.type
        return
    end

    -- DF Orbit: DF-owned orbiting-sparkle effect (the AutoCastGlow stand-in).
    -- Runs on the shared driver off our own shine textures parented to the
    -- animRect, so it works on 12.1 aura container buttons where the LCG Chase
    -- glow can't (no SetParent onto the native button; _knownW/_knownH avoid
    -- secret-rect reads).
    if anim.type == "DF_ORBIT" then
        setupOrbitParticles(border, anim)
        -- ★ CONTAINER-HOSTED BORDERS TAKE THE DECLARATIVE PATH. Their textures sit under
        -- a Blizzard aura button, so a per-frame Lua walk is refused the moment auras go
        -- secret; C-side Translation groups are not. Everything else (unit-frame border,
        -- targeted-spell highlight, missing-buff badge, the AD editor canvas) keeps the
        -- tick, which retunes live while a slider is dragged.
        -- ⚠ A false return means no usable geometry, not a failure to build — fall through
        -- to the tick, which is what this border did before either way.
        if border._secretRect and buildOrbitAnims(border, anim) then
            border.activeAnimation = anim.type
            return
        end
        registerAnimTick(border, function(b, el, dt)
            orbitTick(b, anim, dt)
        end)
        border.activeAnimation = anim.type
        return
    end

    -- DF Dash: dashed border, static or marching. Frequency is the march SPEED
    -- (0 = static "dashed"). Fixed dash length/gap; thickness / inset / colour
    -- from the spec. Dashes clip per edge so the pattern flows around the corners.
    if anim.type == "DF_DASH" then
        local r, g, b, a = readColor(anim.color or ANIM_GOLD)
        border._dfDashTh = math.max(1, anim.thickness or 2)
        border._dfDashInset = anim.inset or 0
        border._dfDashR, border._dfDashG, border._dfDashB, border._dfDashA = r, g, b, a
        local rawFreq = anim.frequency or 0
        local marchSpeed = (rawFreq and rawFreq > 0) and (rawFreq * DF_DASH_SPEED) or 0
        -- Container-hosted and actually marching: clip-and-translate instead of
        -- redrawing every dash each frame. A STATIC dashed border needs no declarative
        -- path — it is drawn once below and never written again.
        if border._secretRect and marchSpeed > 0
            and buildDashAnims(border, anim, border._dfDashTh, border._dfDashInset,
                               r, g, b, a, marchSpeed) then
            border.activeAnimation = anim.type
            return
        end
        if marchSpeed > 0 then
            -- Marching: OnUpdate advances the offset, reading colour/size from the
            -- fields so a live recolour is picked up next tick. elapsed persists
            -- across restarts so a spec change doesn't snap the ants.
            registerAnimTick(border, function(border, el)
                border._dfDashElapsed = el
                local offset = (el * marchSpeed) % DF_DASH_PATTERN
                drawDashes(border, offset, border._dfDashTh, border._dfDashInset,
                    border._dfDashR, border._dfDashG, border._dfDashB, border._dfDashA)
            end, border._dfDashElapsed or 0)
        else
            drawDashes(border, 0, border._dfDashTh, border._dfDashInset, r, g, b, a)  -- static
        end
        border.activeAnimation = anim.type
        return
    end

    -- DF Pixel: DF-owned discrete chasing bars (does not wrap corners — that's
    -- DF Dash). Taint-safe perimeter walk on the shared driver.
    if anim.type == "DF_PIXEL" then
        setupPixelParticles(border, anim)
        if border._secretRect and buildPixelAnims(border, anim) then
            -- setupPixelParticles above built and SHOWED the perimeter-walk pool. The
            -- declarative build owns its own per-edge quads instead, so park the pool or
            -- its bars sit on top of the moving ones, frozen at their seed positions.
            if border.pixelTex then
                for _, t in ipairs(border.pixelTex) do t:Hide() end
            end
            border.activeAnimation = anim.type
            return
        end
        registerAnimTick(border, function(b, el, dt)
            pixelTick(b, anim, dt)
        end)
        border.activeAnimation = anim.type
        return
    end

    -- DF Proc: DF-owned golden proc flare (the ProcGlow stand-in). Hand-stepped
    -- flipbook on the shared driver, taint-safe on aura buttons.
    if anim.type == "DF_PROC" then
        setupProcGlow(border, anim)
        if border._secretRect and buildProcAnims(border, anim) then
            border.activeAnimation = anim.type
            return
        end
        registerAnimTick(border, function(b, el, dt)
            procTick(b, anim, dt)
        end)
        border.activeAnimation = anim.type
        return
    end

    -- DF Flash: DF-owned glow flash (the ButtonGlow stand-in). Additive glow
    -- halo that flashes on the shared driver, taint-safe on aura buttons.
    if anim.type == "DF_FLASH" then
        setupFlashGlow(border, anim)
        if border._secretRect and buildFlashAnims(border, anim) then
            border.activeAnimation = anim.type
            return
        end
        registerAnimTick(border, function(b, el, dt)
            flashTick(b, anim, dt)
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
    -- threshold (Stage 5.1d.2+).  Uses the shared anim driver; on
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
        if border._secretRect and buildPulsateAnims(border, anim) then
            border.activeAnimation = anim.type
            return
        end
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
        registerAnimTick(border, function(border, el, dt)
            local p = border._dfPulsatePeriod or 2
            local ph = ((border._dfPulsatePhase or 0) + dt / p) % 1
            border._dfPulsatePhase = ph
            local wave = (1 - math.cos(ph * 2 * math.pi)) * 0.5
            -- Fade between 0.05 (dim trough) and 1.0 (full) — a gentle pulse.
            --
            -- ☠ DF_PULSATE is the one effect that drives the widget's OWN alpha every
            -- frame, so it clobbers the out-of-range fade unless it folds it in itself.
            -- This used to multiply by `border.dfRangeAlpha`, which NOTHING ever wrote --
            -- the multiplier was permanently 1 and the OOR dim was simply overwritten.
            --
            -- It cannot be a number, because `inRange` may be SECRET: a secret boolean
            -- can't be tested here, so `pulse * (inRange and 1 or oor)` is impossible in
            -- Lua. DF:UpdateBorderAppearance instead stamps the secret plus a PLAIN
            -- companion flag; test the flag, forward the secret, and let
            -- SetAlphaFromBoolean pick between the two pre-multiplied values C-side.
            local pulse = 0.05 + 0.95 * wave
            local oor = border.dfOORAlpha
            if border.dfOORActive and oor and border.SetAlphaFromBoolean then
                border:SetAlphaFromBoolean(border.dfOORInRange, pulse, pulse * oor)
            else
                border:SetAlpha(pulse)
            end
        end)
        border.activeAnimation = anim.type
        return
    end

    -- Static shape mode — renders via overlays (not the border edges themselves)
    -- so it's visible at borderSize 1.
    if anim.type == "CORNERS_ONLY" then
        applyCornersOnly(border, anim)
        border.activeAnimation = anim.type
    end
end


-- ============================================================
-- ANCHOR-ONLY TEXTURE BORDER (secretRect widgets)
-- Renders an LSM border edgeFile as 8 plain textures — 4 fixed-size corner
-- squares at the widget's (inset-adjusted) corners + 4 edges anchored
-- corner-to-corner — using the STANDARD backdrop edgeFile UV layout copied
-- verbatim from Blizzard_SharedXML/Backdrop.lua (textureUVs), so any texture
-- that renders via BackdropTemplate renders identically here.
--
-- WHY: BackdropTemplate computes its edge-tiling texcoords in Lua from
-- GetWidth()/GetHeight()/GetEffectiveScale(). On hosts whose rect is SECRET
-- (12.1 aura-container buttons are anchored with secret-wrapped offsets) or
-- simply unresolved at Apply time, that math produces scattered tiles or
-- throws mid-setup. These pieces are pure anchors + constant sizes: nothing
-- ever reads the rect, so the render is immune to whatever Blizzard does to
-- the host's geometry. Edges STRETCH along their length instead of tiling —
-- the single-tile UV window [coordStart, coordEnd] — which also keeps a
-- multi-line edge art (e.g. a double border) crisp at small sizes.
-- ============================================================
local TEX_CS, TEX_CE = 0.0625, 0.9375   -- coordStart / coordEnd (Backdrop.lua)
-- 8-arg SetTexCoord order: ULx,ULy, LLx,LLy, URx,URy, LRx,LRy. Values are the
-- Backdrop.lua textureUVs with the repeatX/repeatY axis pinned to one tile.
local TEX_PIECE_UVS = {
    tl     = { 0.5078125, TEX_CS, 0.5078125, TEX_CE, 0.6171875, TEX_CS, 0.6171875, TEX_CE },
    tr     = { 0.6328125, TEX_CS, 0.6328125, TEX_CE, 0.7421875, TEX_CS, 0.7421875, TEX_CE },
    bl     = { 0.7578125, TEX_CS, 0.7578125, TEX_CE, 0.8671875, TEX_CS, 0.8671875, TEX_CE },
    br     = { 0.8828125, TEX_CS, 0.8828125, TEX_CE, 0.9921875, TEX_CS, 0.9921875, TEX_CE },
    top    = { 0.2578125, TEX_CE, 0.3671875, TEX_CE, 0.2578125, TEX_CS, 0.3671875, TEX_CS },
    bottom = { 0.3828125, TEX_CE, 0.4921875, TEX_CE, 0.3828125, TEX_CS, 0.4921875, TEX_CS },
    left   = { 0.0078125, TEX_CS, 0.0078125, TEX_CE, 0.1171875, TEX_CS, 0.1171875, TEX_CE },
    right  = { 0.1328125, TEX_CS, 0.1328125, TEX_CE, 0.2421875, TEX_CS, 0.2421875, TEX_CE },
}

local function ensureTexPieces(border)
    if border.texPieces then return border.texPieces end
    local p = {}
    for key in pairs(TEX_PIECE_UVS) do
        local t = border:CreateTexture(nil, border._layer or "BORDER")
        -- Thin border art must not snap to the pixel grid — snapping collapses
        -- sub-pixel lines (NineSlice.lua disables it on its pieces the same way;
        -- part of why fine detail like a double line washed out at small sizes).
        if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
        if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false) end
        p[key] = t
    end
    border.texPieces = p
    return p
end

local function hideTexPieces(border)
    if not border.texPieces then return end
    for _, t in pairs(border.texPieces) do t:Hide() end
end

-- Idempotent: re-anchors/re-paints in place on every Apply (create-once textures).
local function applyTexPieces(border, edgeFile, size, inset, cr, cg, cb, ca)
    local p = ensureTexPieces(border)
    -- Corners: size×size squares at the four inset-adjusted corners.
    p.tl:ClearAllPoints(); p.tl:SetPoint("TOPLEFT",     border, "TOPLEFT",      inset, -inset); p.tl:SetSize(size, size)
    p.tr:ClearAllPoints(); p.tr:SetPoint("TOPRIGHT",    border, "TOPRIGHT",    -inset, -inset); p.tr:SetSize(size, size)
    p.bl:ClearAllPoints(); p.bl:SetPoint("BOTTOMLEFT",  border, "BOTTOMLEFT",   inset,  inset); p.bl:SetSize(size, size)
    p.br:ClearAllPoints(); p.br:SetPoint("BOTTOMRIGHT", border, "BOTTOMRIGHT", -inset,  inset); p.br:SetSize(size, size)
    -- Edges: anchored corner-to-corner — thickness comes from the corners,
    -- length is fully anchor-driven (no size reads, ever).
    p.top:ClearAllPoints();    p.top:SetPoint("TOPLEFT", p.tl, "TOPRIGHT");        p.top:SetPoint("BOTTOMRIGHT", p.tr, "BOTTOMLEFT")
    p.bottom:ClearAllPoints(); p.bottom:SetPoint("BOTTOMLEFT", p.bl, "BOTTOMRIGHT"); p.bottom:SetPoint("TOPRIGHT", p.br, "TOPLEFT")
    p.left:ClearAllPoints();   p.left:SetPoint("TOPLEFT", p.tl, "BOTTOMLEFT");     p.left:SetPoint("BOTTOMRIGHT", p.bl, "TOPRIGHT")
    p.right:ClearAllPoints();  p.right:SetPoint("TOPRIGHT", p.tr, "BOTTOMRIGHT");  p.right:SetPoint("BOTTOMLEFT", p.br, "TOPLEFT")
    for key, t in pairs(p) do
        t:SetTexture(edgeFile)
        local uv = TEX_PIECE_UVS[key]
        t:SetTexCoord(uv[1], uv[2], uv[3], uv[4], uv[5], uv[6], uv[7], uv[8])
        t:SetVertexColor(cr, cg, cb, ca)
        t:Show()
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
--   renderScale   Optional (default 1). The extra SetScale between this border's
--                 frame and UIParent (e.g. an aura container's layout scale, a
--                 missing-badge window's indicator scale). PixelPerfect math lives
--                 in UIParent space; a border rendered inside a scaled subtree must
--                 fold that scale in (snap size*s, divide back out) or the "snapped"
--                 thickness renders at s x snapped physical pixels — fractional
--                 again (uneven fat/thin edges). Only consulted when pixelPerfect.

-- Snap a border thickness to whole PHYSICAL pixels in the border's actual render
-- space (see spec.renderScale above). Min one physical pixel — a thin border that
-- rounds to 0 must not vanish. PUBLIC: consumers that place art flush against the
-- border's inner edge (the AD factory's art insets) MUST size that inset through
-- this same function so art edge and border edge snap identically.
function Border:SnapThickness(value, pixelPerfect, renderScale)
    if not pixelPerfect or not DF.PixelPerfectThickness then return value end
    local s = tonumber(renderScale) or 1
    if s > 0 and s ~= 1 then
        return DF:PixelPerfectThickness(value * s) / s
    end
    return DF:PixelPerfectThickness(value)
end

function Border:Apply(border, spec)
    if not border then return end
    spec = spec or {}
    -- Optional caller-fed geometry: when the border wraps a frame whose live
    -- size can't be measured safely (e.g. an aura overlay slot whose rect is
    -- secret on 12.1), the caller passes knownWidth/knownHeight so the DF particle
    -- effects (DF Dash / DF Orbit) can size from a plain config number instead of
    -- GetWidth/Height.
    -- nil when the caller doesn't feed a size (measured path, unchanged).
    border._knownW = spec.knownWidth
    border._knownH = spec.knownHeight
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
        hideTexPieces(border)
        border.activeTexture = nil
        -- Tear down any running glow when the border is hidden, otherwise
        -- the LCG glow keeps rendering around the unit with no visible
        -- border underneath it.
        self:StopAnimation(border)
        -- ☠ AND THE SHADOW. Same reasoning as the glow above, and it was missed:
        -- border.shadow is a lazily-created frame parented to border:GetParent(), not to
        -- the border, so hiding the edges leaves it drawn. Its only teardown lives ~280
        -- lines below in the normal path, which this early return skips entirely.
        --
        -- Symptom: tick "Border Shadow", then untick "Show Border" -- the border goes and a
        -- solid black ring stays around the frame or icon. Recoverable only by working out
        -- that the still-enabled Shadow checkbox is the culprit.
        if border.shadow then border.shadow:Hide() end
        return
    end

    local size = spec.size or 1
    local inset = spec.inset or 0
    if spec.pixelPerfect and DF.PixelPerfect then
        local rs = tonumber(spec.renderScale) or 1
        size = self:SnapThickness(size, true, rs)
        if inset ~= 0 then
            if rs > 0 and rs ~= 1 then
                inset = DF:PixelPerfect(inset * rs) / rs
            else
                inset = DF:PixelPerfect(inset)
            end
        end
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
        hideTexPieces(border)

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

            -- Remember that these edges carry gradient state, so the solid
            -- path's clear runs even on a solidOnly widget. solidOnly consumers
            -- were assumed never to enter this branch, but several share their
            -- GUI prefix with widgets that DO offer the Gradient style (the
            -- aura icon borders render on solidOnly container-button widgets):
            -- switching Gradient -> Solid then skipped the clear and the
            -- gradient stuck until reload.
            border._gradientPainted = true

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
            -- solidOnly borders normally carry no gradient, so the clear is
            -- skipped to keep recolours a bare SetColorTexture (cheap and
            -- secret-safe) — UNLESS a GRADIENT apply actually painted these
            -- edges (_gradientPainted), in which case skipping left the
            -- gradient stuck on Gradient -> Solid style switches.
            if (not border._solidOnly or border._gradientPainted) and CreateColor then
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
                border._gradientPainted = nil
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
        -- Texture mode — TWO renderers behind the same spec:
        --
        --  * secretRect widgets (opts.secretRect in :New): 8 ANCHOR-ONLY pieces (4
        --    fixed-size corners + 4 corner-to-corner edges). The host's rect may be
        --    SECRET or unresolved — 12.1 CustomAuraContainer buttons are anchored by
        --    Blizzard's flow layout with secret-wrapped offsets, and at initializeFrame
        --    time have no anchors at all — and BackdropTemplate:SetupTextureCoordinates
        --    reads GetWidth/GetHeight/GetEffectiveScale in LUA to compute tile repeats.
        --    That math on a zero/secret rect scatters the edge tiles ("border breaks
        --    apart"), and a mid-setup throw leaves pieces uncoloured or missing until
        --    a /reload happens to re-lay them out of combat. The pieces here are pure
        --    anchors + constant sizes — NOTHING reads the rect, so Blizzard can anchor
        --    the host however and whenever it likes. Tradeoff: edges STRETCH instead
        --    of tile — indistinguishable for line-style borders at icon sizes.
        --
        --  * everyone else: the classic BackdropTemplate child (tiling preserved for
        --    long frame edges). spec.blendMode is intentionally ignored in texture
        --    mode — see doc above.
        for _, e in ipairs(edges) do if e then e:Hide() end end
        -- Thickness 0 = no border: hide the texture render instead of clamping the
        -- edge to 1px (parity with the solid/gradient path above). The animation
        -- overlay is a separate frame and keeps running.
        if size <= 0 then
            if border.bd then border.bd:Hide() end
            hideTexPieces(border)
            border.activeTexture = nil
        elseif border._secretRect then
            if border.bd then border.bd:Hide() end
            applyTexPieces(border, edgeFile, size, inset, cr, cg, cb, ca)
            border.activeTexture = texture
        else
            hideTexPieces(border)
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
        if spec.pixelPerfect then
            shadowSize = self:SnapThickness(shadowSize, true, spec.renderScale)
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
