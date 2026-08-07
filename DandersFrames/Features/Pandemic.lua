local addonName, DF = ...

-- ============================================================
-- DF.Pandemic — the refresh-window reveal (12.1.0 PTR 8, build 69111)
-- ============================================================
-- Turns a "pandemic*" config block into a style.pandemic spec that the AuraContainer
-- engine hands to CustomAuraButton:AddPandemicRegion. The engine stamps
-- Enum.SecretAspect.Shown on the registered object and drives SetShown itself from its
-- own window maths, so this is attach-and-inherit exactly like SetIcon: we build the art,
-- the game decides when it is visible, and nothing here reads an aura.
--
-- WHAT THE WINDOW IS. Blizzard computes it (Blizzard_CustomAuraButton.lua:612):
--     carriedOverToNewCast = GetRefreshExtendedDuration(u,id) - GetAuraBaseDuration(u,id)
--     window exists when carriedOverToNewCast > 0
--     start = expirationTime - carriedOverToNewCast ;  end = expirationTime
-- i.e. it lights exactly while a refresh would clip NOTHING. In practice that is the last
-- 30% of the base duration, but it is the GAME's number per spell, not ours — there is
-- deliberately no threshold control anywhere in this feature.
--
-- ⚠ MANY AURAS HAVE NO WINDOW AT ALL, and that is not a bug. Only a refreshable
-- duration has one. Charge-based auras (Prayer of Mending), fixed-duration procs, food,
-- flasks and anything you did not cast all return nil and stay dark forever. Confirmed in
-- game 2026-08-05 — a cue that never lights on a given spell is the feature working.
--
-- ☠ ADD, NEVER REPLACE. This does NOT supersede DF.Expiration, and the two are meant to
-- run together:
--   * expiry alert  = "about to fall off" — a USER threshold, any aura, zero per-frame cost,
--                     and the only one that can walk a colour ramp.
--   * pandemic      = "right moment to refresh" — the game's window, refreshable auras only,
--                     a boolean show/hide with no ramp, and a per-frame OnUpdate on the
--                     button while a window is open.
-- A 30s HoT enters its refresh window with ~9s left, which no sensible expiry threshold
-- would catch. They overlap in TIME on purpose; the editor only warns about SPACE.
--
-- ★ TWO TYPES, BORDER AND TINT. Custom Text and Glyph were built and then dropped
-- (Krathe, 2026-08-05): a boolean "now" cue wants to read at a glance from the edge of
-- vision, which is what a ring or a wash does and what a glyph competes with the icon to
-- do. Keeping two also means every control on the panel applies to both, so nothing hides.
--
-- ★ THE BORDER IS A REAL DF.Border. Not a fixed-weight TGA — the full house toolkit
-- (style, thickness, inset, offsets, colour, gradient, shadow), keyed exactly like every
-- other DF border so CreateBorderControls drives it with no special case. See BuildSpec
-- for why this is registered as a FRAME rather than as its four edge textures.
--
-- CONTRACT:
--   cfg     the settings table holding the keys (the AD indicator record, or DF.db[mode]).
--   prefix  "" / nil for the Aura Designer (bare `pandemicEnabled`), or a row prefix
--           ("buff", "debuff") for the flat profile table (`buffPandemicEnabled`).
-- ============================================================

local tconcat = table.concat

DF.Pandemic = DF.Pandemic or {}
local Pandemic = DF.Pandemic

-- The two reveal types. Both cover the whole button, so both work on any indicator shape
-- (icon, square, bar) and on a row icon without a single per-shape branch anywhere.
local MODES = { BORDER = true, TINT = true }

-- The type a MISSING key resolves to. ☠ The editor's dropdown reads this same constant,
-- so the panel can never show a type the renderer does not draw. That divergence is the
-- bug class resolveDefCBT exists for in the AD factory.
Pandemic.DEFAULT_MODE = "BORDER"

-- Key resolution. AD indicators store bare `pandemicX`; the flat profile table needs a row
-- prefix, so "buff" + "Mode" -> `buffPandemicMode`. One place, so the engine, the editor
-- and the export categories can never disagree about a key name.
function Pandemic:Key(prefix, suffix)
    if prefix and prefix ~= "" then return prefix .. "Pandemic" .. suffix end
    return "pandemic" .. suffix
end
local function get(cfg, prefix, suffix)
    if not cfg then return nil end
    return cfg[Pandemic:Key(prefix, suffix)]
end

-- The DF.Border key prefix for this consumer — "pandemic" / "buffPandemic". Border:BuildSpec
-- appends its own "Border*" suffixes, so the border's keys are `pandemicBorderStyle`,
-- `buffPandemicBorderColor` and so on: the standard shape, which is exactly why
-- GUI:CreateBorderControls needs no special case for this section.
function Pandemic:BorderPrefix(prefix) return self:Key(prefix, "") end

-- Accepts both colour shapes DF stores: {r,g,b,a} records (profile tables) and {1,2,3,4}
-- arrays (Aura Designer records).
local function readColor(c, dr, dg, db, da)
    if type(c) ~= "table" then return dr or 1, dg or 1, db or 1, da or 1 end
    return c[1] or c.r or dr or 1, c[2] or c.g or dg or 1,
           c[3] or c.b or db or 1, c[4] or c.a or da or 1
end
local function colorSig(c)
    if type(c) ~= "table" then return "" end
    local r, g, b, a = readColor(c)
    return tconcat({ tostring(r), tostring(g), tostring(b), tostring(a) }, ",")
end

-- Is this client new enough to drive a pandemic region at all? THE single capability
-- chokepoint — Mode() gates on it, so render, sigs and editor inherit one answer and none
-- of them can build half the feature.
function Pandemic:IsSupported()
    local AC = DF.AuraContainer
    return (AC and AC.HasPandemic and AC.HasPandemic()) and true or false
end

-- Active reveal type, or nil when off. Capability, then the master toggle, then the type.
-- An UNSET type takes DEFAULT_MODE; a SET but unknown one (a stale or hand-edited profile
-- value) is off rather than silently substituted.
function Pandemic:Mode(cfg, prefix)
    if not self:IsSupported() then return nil end
    if not get(cfg, prefix, "Enabled") then return nil end
    local m = get(cfg, prefix, "Mode")
    if m == nil then return self.DEFAULT_MODE end
    if MODES[m] then return m end
    return nil
end

-- ANIMATION.
--
-- ☠ WHY NOT DF.Border's ANIMATION SET (Wipe / Ripple / Segment Reveal / Sides / Corners /
-- DF Dash / Proc). Every one of them rides Border.lua's single shared OnUpdate driver,
-- which calls back per frame into tainted Lua and writes SetVertexColor / SetPoint / Hide
-- on the border's pieces. On a container button child that errors on every frame while
-- auras are secret — which is exactly the content this feature exists for. That is why
-- animation is stripped unconditionally from every container border, and it is not
-- something the working flash changes.
--
-- ★ WHAT DOES WORK: a native AnimationGroup, built and :Play()ed ONCE inside
-- initializeFrame (secure context) and then run entirely C-side — zero Lua per frame, and
-- nothing tainted touching the button after init.
--
-- ☠ ...but ONLY an Alpha animation. Scale was tried and does NOT run on the registered
-- holder (in game, 2026-08-05: FLASH pulsed, a Scale-based PULSE and a combined BREATHE
-- did nothing at all). The holder carries SecretAspect.Shown plus the forbidden aspects
-- AddPandemicRegion stamps on it, and a scale transform evidently does not survive that
-- where an alpha one does. Not worth pushing further: Blizzard have said pandemic
-- animation is being looked at for 12.1.5, so anything clever built here now is likely to
-- be replaced by something supported. ⚠ Re-test Scale on a later build before assuming it
-- is permanently dead — this is an empirical result, not a documented rule.
--
-- CREATION-FROZEN, hence part of StructSig: the group's animation and its duration are
-- baked when it is built, and reaching back in later would be a tainted write to a
-- forbidden child. So the toggle AND the speed both rebuild the slot.
function Pandemic:Flash(cfg, prefix)
    if not get(cfg, prefix, "Flash") then return nil end
    -- Seconds for a full dim-and-back cycle. Clamped: below ~0.2 reads as a strobe rather
    -- than a pulse, and above ~3 is slow enough that a refresh window can open and close
    -- without the cue ever reaching full brightness.
    local s = tonumber(get(cfg, prefix, "FlashSpeed")) or 1
    if s < 0.2 then s = 0.2 elseif s > 3 then s = 3 end
    return s
end

-- STRUCTURAL identity — what forces a Rebuild rather than an in-place restyle. Three
-- things about a pandemic cue are frozen after creation: which WIDGET it is (a DF.Border
-- inside the holder, or a plain tint texture), the AddPandemicRegion bind, and the flash
-- animation. Everything else is a plain region write that re-runs each style pass.
function Pandemic:StructSig(cfg, prefix)
    local mode = self:Mode(cfg, prefix)
    if not mode then return "" end
    return mode .. ":F" .. tostring(self:Flash(cfg, prefix))
end

-- The DF.Border keys whose values must move the COSMETIC signature. Deliberately excludes
-- the Border*Animation* family: animations are stripped unconditionally on container
-- borders (they cannot run on a button child while auras are secret), so hashing them
-- would churn the sig for settings that provably cannot render.
local BORDER_KEYS = {
    "BorderStyle", "BorderTexture", "BorderSize", "BorderInset",
    "BorderOffsetX", "BorderOffsetY", "BorderBlendMode",
    "BorderGradientDirection",
    "BorderShadowEnabled", "BorderShadowSize", "BorderShadowOffsetX", "BorderShadowOffsetY",
    "BorderColorSource",
}
local BORDER_COLOR_KEYS = {
    "BorderColor", "BorderGradientStartColor", "BorderGradientEndColor", "BorderShadowColor",
}
-- Shared scratch, same discipline as the factory's placedBorderSigParts: this runs per
-- indicator per UNIT_AURA, and a fresh array each time was measurable trash. Safe as a
-- single table because nothing here recurses.
local sigParts = {}

-- COSMETIC identity — the complement of StructSig. Everything BuildSpec reads that is not
-- the mode or the flash, so an edit hot-applies through ApplyStyle.
-- ☠ Keep in step with BuildSpec by construction: a key BuildSpec reads and this omits is
-- the classic "the slider does nothing until something else rebuilds" bug.
function Pandemic:CoSig(cfg, prefix)
    local mode = self:Mode(cfg, prefix)
    if not mode then return "" end
    local parts = sigParts
    wipe(parts)
    parts[1] = mode
    if mode == "TINT" then
        parts[2] = colorSig(get(cfg, prefix, "TintColor"))
        parts[3] = tostring(tonumber(get(cfg, prefix, "TintAlpha")) or 1)
        parts[4] = tostring(tonumber(get(cfg, prefix, "TintInset")) or 0)
    else
        local bp = self:BorderPrefix(prefix)
        for _, k in ipairs(BORDER_KEYS) do
            parts[#parts + 1] = tostring(cfg and cfg[bp .. k])
        end
        for _, k in ipairs(BORDER_COLOR_KEYS) do
            parts[#parts + 1] = colorSig(cfg and cfg[bp .. k])
        end
    end
    return tconcat(parts, ",")
end

-- The style.pandemic block, or nil when off (which includes an unsupported client —
-- Mode() carries that gate, so nothing downstream repeats the probe).
--
-- ☠ BOTH TYPES REGISTER A FRAME, never a texture. Confirmed in game 2026-08-05:
-- `Frame:IsObjectType("Region")` is true, so AddPandemicRegion accepts one. That matters
-- for BORDER specifically: DF.Border's applyTexPieces calls Show() on every edge piece on
-- every Apply, so registering the PIECES would hand their Shown aspect to the engine and
-- turn DF.Border's own routine writes into forbidden writes on a button child. Registering
-- the holder frame instead leaves DF.Border in full control of everything inside it, and
-- gives the flash animation a frame to live on. TINT uses the same shape for one code path.
--
-- ctx carries what a border spec needs but the config cannot know: the slot's configured
-- pixel size (DF_DASH lays its dashes out from it — the button's real rect is SECRET) and
-- the container's render scale.
function Pandemic:BuildSpec(cfg, prefix, ctx)
    local mode = self:Mode(cfg, prefix)
    if not mode then return nil end

    local spec = { mode = mode, flash = self:Flash(cfg, prefix) }

    -- ☠ THE TWO TYPES WANT OPPOSITE Z-ORDER, so the level is per mode.
    --   BORDER 15 — one above the stack count (14), the top-most content region. A ring
    --               traces the edge, so it has to read over the icon's own border (10) and
    --               the dispel ring (12) or it is simply hidden behind them.
    --   TINT    9 — BELOW the duration text (13), the stack count (14), the dispel ring
    --               (12) and DF.Border (10), but above the icon art and the cooldown swipe.
    --               A wash covers the whole button, so at 15 it washed over the timer and
    --               the stack count and made both hard to read (Krathe, 2026-08-05). Tint
    --               the ICON, not the information on top of it.
    -- See zorder_layer_map: these are ABSOLUTE offsets from the button, not nudges.
    spec.level = (mode == "TINT") and 9 or 15

    if mode == "TINT" then
        local r, g, b = readColor(get(cfg, prefix, "TintColor"), 0.2, 1, 0.2)
        spec.tintColor = { r, g, b }
        spec.tintAlpha = tonumber(get(cfg, prefix, "TintAlpha")) or 0.4
        -- Positive pulls every edge inward, negative haloes outward — the DF.Border sign
        -- convention, so the two controls read the same way.
        spec.tintInset = tonumber(get(cfg, prefix, "TintInset")) or 0
    else
        if not (DF.Border and DF.Border.BuildSpec) then return nil end
        spec.border = DF.Border:BuildSpec(cfg, self:BorderPrefix(prefix), ctx)
        if spec.border then
            -- Animation is stripped here as well as at the container's own chokepoint.
            -- Belt and braces on purpose: this spec is built by consumers that may not go
            -- through that path (the AD canvas preview), and an animated border on a
            -- button child spams a per-frame forbidden error in exactly the content this
            -- feature is for.
            spec.border.animation = nil
        end
    end

    return spec
end

-- Does this config have a pandemic reveal of a given TYPE? The editor's collision check
-- asks both engines this so the warning logic lives in one vocabulary rather than reaching
-- into each system's keys. nil type = "any".
function Pandemic:UsesType(cfg, prefix, mode)
    local m = self:Mode(cfg, prefix)
    if not m then return false end
    return mode == nil or m == mode
end
