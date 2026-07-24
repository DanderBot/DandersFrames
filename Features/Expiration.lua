local addonName, DF = ...

-- ============================================================
-- DF.Expiration — 12.1-safe expiration engine
-- ============================================================
-- The reusable, secret-safe layer that turns an "expiry alert" config block into a
-- 1-slot companion's duration spec (or an editor preview). It is the 12.1 replacement
-- for the pre-12.1 "Expiring" system (the ~3 Hz border/tint ticker in Frames/Border.lua
-- + Features/Highlights.lua + Core.lua's LightweightUpdate*): remaining time is SECRET
-- on 12.1, so nothing here reads it — the reveal is a native SetDurationText band
-- formatter evaluated C-side (proved live 2026-07-20; see patch_12_1_aura_lockdown.md).
--
-- WHY A SEPARATE ENGINE: the AD placed icon/square build this inline in the factory, and
-- the frame-level indicators (health-bar wash, frame border) will want the SAME reveal
-- with different geometry. Centralising it here means one place owns the geometry
-- calibration + formatter selection + placement, and every consumer just calls in — no
-- per-feature hand-rolling (the standing engine/helpers rule).
--
-- BOUNDARY (Stage 1): the low-level reveal FORMATTERS + border art live in Features/
-- Auras.lua as public DF: methods (GetExpiryBorderElementFormatter / GetExpiryAlert-
-- ElementFormatter / GetExpiryBorderEscape / GetExpiryAlertPayload / GetExpiryAlertFmtKey),
-- because they share the duration-text engine's formatter cache + colour breakpoints and
-- the inline-alert-on-countdown feature. This engine COMPOSES them; it does not duplicate
-- them. The dependency is one-way (Expiration -> Auras).
--
-- CONTRACT:
--   cfg      = the settings block holding the expiryAlert* keys (the AD indicator record,
--              or any consumer's equivalent). DB keys are unchanged from the inline version.
--   geometry = the target the reveal overlays: { baseSize = <icon side px>, font = <font> }
--              for icons/squares; a bar consumer would pass its own base dimension. The
--               x0.75 |T calibration + inset + match all happen here, so callers never
--              repeat them.
-- ============================================================

local tconcat = table.concat
local mfloor, mmax = math.floor, math.max

-- A |T inline texture inside a fontstring measures ~0.75x the icon container's pixels for
-- the same on-screen size (a fixed rendering offset, not scale-dependent — both ride the
-- same UI scale). So a Border that auto-matches the icon bakes size = iconSide x 0.75.
local BORDER_ICON_RATIO = 0.75

-- Stable colour signature for a cache/struct key. Byte-identical to the factory's colSig
-- (readADColor's {r,g,b,a} defaults, then joined by ",") so a border-colour edit still
-- moves the struct key and rebuilds the bind-frozen formatter. "" when unset.
local function readColor(c)
    if type(c) ~= "table" then return 1, 1, 1, 1 end
    return c[1] or c.r or 1, c[2] or c.g or 1, c[3] or c.b or 1, c[4] or c.a or 1
end
local function colorSig(c)
    if type(c) ~= "table" then return "" end
    local r, g, b, a = readColor(c)
    return tconcat({ tostring(r), tostring(g), tostring(b), tostring(a) }, ",")
end

DF.Expiration = DF.Expiration or {}
local Expiration = DF.Expiration

-- Active reveal type or nil. Gated by the master expiryAlertEnabled toggle first (off = nil =
-- no companion), then the stored type: TEXT / GLYPH / BORDER (a frame outline) / TINT (a solid
-- wash). A missing/unknown type also yields nil.
function Expiration:Mode(cfg)
    if not (cfg and cfg.expiryAlertEnabled) then return nil end
    local m = cfg.expiryAlertMode
    if m == "TEXT" or m == "GLYPH" or m == "BORDER" or m == "TINT" then return m end
    return nil
end

-- BORDER and TINT are the two "frame-ish" reveals: a |T overlay that auto-matches the icon,
-- centres, tints statically / by-time, and takes an opacity. They differ ONLY in the art —
-- BORDER picks a frame outline by thickness (Thin/Medium/Thick); TINT is always the solid
-- FILL wash (no thickness control), so it resolves to the FILL texture.
local function isFrameMode(m) return m == "BORDER" or m == "TINT" end
local function resolveThickness(cfg, mode)
    if mode == "TINT" then return "FILL" end
    return cfg.expiryAlertBorderThickness or "MEDIUM"
end

-- Baked |T width, height for the reveal — TWO values (equal for a square target). TEXT/GLYPH
-- use the manual square Size. Frame modes (BORDER/TINT):
--   * RECTANGULAR target (geometry.width + .height, e.g. a bar / health bar): always fit its
--     dimensions x0.75 (a square manual Size is meaningless there — only TINT is offered).
--   * SQUARE target (geometry.baseSize, an icon): match baseSize x0.75, or the manual Size when
--     Match is off.
-- Inset nudges every edge inward. One source so the struct key, companion and preview agree.
function Expiration:EffectiveSize(cfg, geometry)
    if not isFrameMode(self:Mode(cfg)) then
        local s = mmax(1, mfloor(tonumber(cfg.expiryAlertSize) or 14))
        return s, s
    end
    local inset = tonumber(cfg.expiryAlertBorderInset) or 0
    local gw = tonumber(geometry and geometry.width)
    local gh = tonumber(geometry and geometry.height)
    if gw and gh then
        return mmax(1, mfloor(gw * BORDER_ICON_RATIO - inset + 0.5)),
               mmax(1, mfloor(gh * BORDER_ICON_RATIO - inset + 0.5))
    end
    local base = (cfg.expiryAlertBorderMatchIcon ~= false)
        and ((tonumber(geometry and geometry.baseSize) or 24) * BORDER_ICON_RATIO)
        or (tonumber(cfg.expiryAlertSize) or 18)
    local s = mmax(1, mfloor(base - inset + 0.5))
    return s, s
end

-- The unit this reveal is measured in — PER INDICATOR, not account-wide. Its bands and
-- its Alert Below threshold are ONE formatter sampled against ONE duration property, so
-- the two must agree; but nothing makes two different indicators agree with each other,
-- and a TEXT/GLYPH reveal has no colour ramp at all, so its unit is purely "when does
-- this appear". A glyph at 5 seconds alongside a border at 30% is a legitimate setup.
function Expiration:Unit(cfg)
    return (cfg and cfg.expiryAlertThresholdUnit == "PERCENT") and "PERCENT" or "SECONDS"
end

-- The reveal threshold, in this indicator's unit. ONE STORED VALUE PER UNIT, exactly like
-- the colour ramps: a threshold cannot be reinterpreted between units (5 seconds is not
-- 5 percent), and reading a seconds value as a percentage pins the reveal to the last 5%
-- of an aura, which reads as "the border disappeared". Switching the unit therefore swaps
-- which threshold is live and leaves the other intact.
function Expiration:Threshold(cfg)
    if self:Unit(cfg) == "PERCENT" then
        return tonumber(cfg and cfg.expiryAlertThresholdPercent) or 30
    end
    return tonumber(cfg and cfg.expiryAlertThreshold) or 5
end
Expiration.PERCENT_THRESHOLD_DEFAULT = 30

-- A frame/tint overlays the icon concentrically, so it is ALWAYS centred (its Anchor control
-- is hidden) — any other anchor just de-centres it. TEXT/GLYPH keep the user's chosen anchor.
function Expiration:EffectiveAnchor(cfg)
    if isFrameMode(self:Mode(cfg)) then return "CENTER" end
    return cfg.expiryAlertAnchor or "TOP"
end

-- STRUCTURAL identity of the reveal ("" when off): the companion's formatter is bind-frozen
-- and its text placement is a button-child write (forbidden post-init while auras are secret,
-- PTR-5), so ANY change here must Rebuild the companion slot. Folds mode/threshold/payload
-- (shared fmt-key helper) + baked size + anchor/offsets, and for a frame mode (BORDER/TINT)
-- the colour identity (static colour sig, or the breakpoints sig for by-time so a Colours-page
-- edit rebuilds) + thickness/style + opacity. Consumers append this to their own struct sig.
function Expiration:StructSig(cfg, geometry)
    local mode = self:Mode(cfg)
    if not mode then return "" end
    local sw, sh = self:EffectiveSize(cfg, geometry)
    local key = (DF.GetExpiryAlertFmtKey and DF:GetExpiryAlertFmtKey(mode,
            self:Threshold(cfg), cfg.expiryAlertText, cfg.expiryAlertGlyph) or "")
        -- The unit is part of the formatter's identity (it picks the sampled property and,
        -- for BYTIME, the ramp) and the formatter is bind-frozen -> a unit change must
        -- Rebuild, not just restyle.
        .. ":U" .. self:Unit(cfg)
        .. ":S" .. tostring(sw) .. "x" .. tostring(sh)
        .. ":P" .. self:EffectiveAnchor(cfg)
        .. "," .. tostring(tonumber(cfg.expiryAlertOffsetX) or 0)
        .. "," .. tostring(tonumber(cfg.expiryAlertOffsetY) or 0)
    if isFrameMode(mode) then
        local cm = cfg.expiryAlertBorderColorMode or "STATIC"
        key = key .. ":B" .. cm .. ":" .. ((cm == "BYTIME")
            -- The shared ramp FOR THIS INDICATOR'S UNIT, so a Colours-page edit to that
            -- ramp rebuilds the bind-once formatter (and an edit to the other one doesn't).
            and (DF.GetDurationBreakpointsSig and DF.GetDurationRampKey
                 and DF:GetDurationBreakpointsSig(DF:GetDurationRampKey(self:Unit(cfg))) or "")
            or colorSig(cfg.expiryAlertBorderColor))
            .. ":T" .. tostring(resolveThickness(cfg, mode))
            .. ":A" .. tostring(tonumber(cfg.expiryAlertBorderAlpha) or 1)
    end
    return key
end

-- The style.duration block for the reveal companion (or nil when off / no formatter API).
-- This IS the reusable seam: a consumer wraps it in its own 1-slot container config
-- (invisible button, this as its duration text). A frame mode (BORDER/TINT) uses the |T
-- frame/tint element formatter; TEXT/GLYPH use the payload element formatter. alpha (region
-- alpha, scales the inline |T) applies for the frame modes only — see Frames/TextStyle.lua.
-- level 7 = one above a normal duration holder (6), so the alert draws over the icon / bar fill.
function Expiration:BuildDurationSpec(cfg, geometry)
    local mode = self:Mode(cfg)
    if not mode then return nil end
    local w, h = self:EffectiveSize(cfg, geometry)
    local formatter
    if isFrameMode(mode) then
        formatter = DF.GetExpiryBorderElementFormatter and DF:GetExpiryBorderElementFormatter(
            self:Threshold(cfg), w, h,
            cfg.expiryAlertBorderColorMode, cfg.expiryAlertBorderColor,
            resolveThickness(cfg, mode), self:Unit(cfg))
    else
        formatter = DF.GetExpiryAlertElementFormatter and DF:GetExpiryAlertElementFormatter(
            mode, self:Threshold(cfg),
            cfg.expiryAlertText, cfg.expiryAlertGlyph, w)   -- TEXT/GLYPH: square, w == h
    end
    if not formatter then return nil end   -- pre-12.1 formatter API missing: no companion
    -- PERCENT unit: the reveal's bands (and its Alert Below threshold, which rides the
    -- same formatter) are percentages, so the binding must sample RemainingPercent rather
    -- than the default remaining seconds. textFormat is the only route to a non-default
    -- property — a lone "{}" substituted by one component naming property + formatter.
    local textFormat
    if self:Unit(cfg) == "PERCENT" and Enum and Enum.DurationTextBindingProperty then
        textFormat = { formatString = "{}", components = {
            { property = Enum.DurationTextBindingProperty.RemainingPercent, formatter = formatter },
        } }
    end
    return {
        show      = true,
        formatter = formatter,
        textFormat = textFormat,
        font      = (geometry and geometry.font) or cfg.durationFont,
        size      = h,   -- font / line-box size; == the square size for icons and text/glyph
        outline   = "OUTLINE",
        anchor    = self:EffectiveAnchor(cfg),
        offsetX   = tonumber(cfg.expiryAlertOffsetX) or 0,
        offsetY   = tonumber(cfg.expiryAlertOffsetY) or 0,
        alpha     = isFrameMode(mode) and (tonumber(cfg.expiryAlertBorderAlpha) or 1) or nil,
        level     = 7,
    }
end

-- Editor-canvas sample: the STATIC payload at the configured anchor/offset/size so
-- positioning is WYSIWYG while editing. Composed by the SAME payload/escape helpers the
-- live formatter uses, so preview and live can never drift. nil when the alert is off OR
-- the config is in show-when-missing mode (no companion is built there — nothing counts down).
function Expiration:BuildPreview(cfg, geometry)
    local mode = self:Mode(cfg)
    if cfg.showWhenMissing then return nil end
    if not mode then return nil end
    local w, h = self:EffectiveSize(cfg, geometry)
    local payload
    if isFrameMode(mode) then
        -- Static: the picked colour. By-time: the canvas is one still frame, so show the
        -- "about to expire" end (red) — the most representative moment.
        local col = (cfg.expiryAlertBorderColorMode == "BYTIME")
            and { r = 1, g = 0.2, b = 0.2 } or cfg.expiryAlertBorderColor
        payload = DF.GetExpiryBorderEscape and DF:GetExpiryBorderEscape(w, h, col, resolveThickness(cfg, mode))
    elseif DF.GetExpiryAlertPayload then
        payload = DF:GetExpiryAlertPayload(mode, cfg.expiryAlertText, cfg.expiryAlertGlyph, w)
    end
    if not payload then return nil end
    return {
        payload = payload,
        anchor  = self:EffectiveAnchor(cfg),
        offsetX = tonumber(cfg.expiryAlertOffsetX) or 0,
        offsetY = tonumber(cfg.expiryAlertOffsetY) or 0,
        size    = h,
        alpha   = isFrameMode(mode) and (tonumber(cfg.expiryAlertBorderAlpha) or 1) or nil,
        font    = (geometry and geometry.font) or cfg.durationFont,
    }
end
