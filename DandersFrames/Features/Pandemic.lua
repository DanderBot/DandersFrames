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
-- WHAT THE WINDOW IS. Blizzard computes it (AuraContainerUtil.GetPandemicWindow):
--     carriedOverToNewCast = GetRefreshCarryOverDuration(u,id)      -- 12.1.5 PTR 3 (69952)
--       (before 69952: GetRefreshExtendedDuration(u,id) - GetAuraBaseDuration(u,id), which
--        mis-timed auras pushed past the refresh cap, e.g. Lifebloom under Tranquility)
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

-- ============================================================
-- SPELL-LEVEL CAPABILITY — does THIS aura have a refresh window at all?
-- ============================================================
-- ⚠ A DIFFERENT QUESTION FROM IsSupported ABOVE, and the two must not be merged. That one
-- asks whether the CLIENT can drive a pandemic region; this asks whether a particular
-- SPELL ever has a window to drive it with. A user on a supported client configuring
-- Prayer of Mending passes the first and fails the second, and gets a panel full of live
-- controls attached to a cue that can never light — which is exactly the report this
-- exists to stop, and an hour of my own debugging before that.
--
-- Measurements live in Features/PandemicWindows.lua; read that file for why the data
-- cannot be an API call and what the sample honestly covers.

-- The LEARNED store — what this install has measured for itself, account-wide. Seeded
-- empty; the sampler below fills it as you play. Not per-profile: a spell either has the
-- mechanic or it does not, and that answer has nothing to do with which frames profile is
-- loaded.
local function learnedStore(create)
    local db = _G.DandersFramesDB_v2
    if not db then return nil end
    if not db.pandemicWindows and create then db.pandemicWindows = {} end
    return db.pandemicWindows
end

-- true / false / nil. ☠ nil is UNKNOWN and is NOT false — the shipped table is a
-- proof-of-concept sample, not a survey, so "we have never seen this spell" must behave
-- like "no opinion".
--
-- ★ RESOLUTION ORDER, AND IT IS NOT "LOCAL WINS". Any YES beats any NO, from either
-- source; only then does a NO count. Greying a feature that actually works is the one
-- failure direction that hurts a user — they cannot tell it from intended behaviour — so
-- every tie resolves toward the panel staying live:
--   learned yes -> yes      (a stale shipped NO self-heals the moment we see it work)
--   shipped yes -> yes      (a local NO can never grey something the shipped data vouches for)
--   learned no  -> no
--   shipped no  -> no
--   otherwise   -> unknown
-- ⚠ Note what is deliberately absent: local SILENCE never adds a no. A spell nobody has
-- cast this week must not start greying itself.
function Pandemic:SpellWindowState(id)
    id = tonumber(id)
    if not id then return nil end
    local seeded = DF.PandemicWindows and DF.PandemicWindows[id]
    local store = learnedStore(false)
    local learned = store and store[id]
    if learned == true or seeded == true then return true end
    if learned == false or seeded == false then return false end
    return nil
end

-- ============================================================
-- THE SAMPLER — the table stops being something anyone maintains
-- ============================================================
-- ☠ WHY THIS CAN ONLY EVER BE OPPORTUNISTIC. GetRefreshExtendedDuration is
-- `RequiresValidUnitAuraInstance`: it needs a unit and a live auraInstanceID. There is no
-- spell-level query anywhere in C_Spell, C_SpellBook or C_UnitAuras (enumerated on 12.1.5,
-- not guessed), so we cannot ask about a spell that is not on anybody right now. We can
-- only answer for what we happen to see, and remember it.
--
-- ★ IT RIDES MACHINERY THAT ALREADY EXISTS. The caller is AuraContainer's 30s sweep, which
-- is already out-of-combat gated and already enumerates the player plus a rotating group
-- member for the park sentinel. That timing is what makes this safe rather than merely
-- convenient: GetRefreshExtendedDuration is `SecretWhenUnitAuraRestricted`, so OUT of
-- combat it returns a plain number we can test, and the whole class of secret-value traps
-- never arises. No new event path, no UNIT_AURA reader, no ForEachAura.
--
-- ☠ nil FROM THE EXTENDED CALL IS THE DEFINITIVE "NO MECHANIC". A refreshable aura always
-- carries over something (capped at 30% of base, so > 0 even on a fresh cast); the call
-- returns nil when the spell has no refresh behaviour at all. That is the same signal the
-- shipped table's NO_EXT rows were collected from, so both sources mean the same thing.
-- ⚠ Anything ambiguous is NOT recorded. A missing base duration or a non-positive
-- carry-over writes nothing rather than guessing — silence is always safe here, a wrong NO
-- is not.
local function sampleUnit(unit)
    local C = C_UnitAuras
    local okIDs, ids = pcall(C.GetUnitAuraInstanceIDs, unit, "HELPFUL")
    if not okIDs or type(ids) ~= "table" then return 0 end

    local store = learnedStore(true)
    if not store then return 0 end
    local learnedCount = 0

    for i = 1, #ids do
        local instID = ids[i]
        local okD, data = pcall(C.GetAuraDataByAuraInstanceID, unit, instID)
        -- ⚠ issecretvalue FIRST and as its own statement, on every value read out of a
        -- Blizzard table, before anything truth-tests it. A secret here is not an error, it
        -- just means this unit is restricted right now — skip and catch it another sweep.
        local dataSecret = issecretvalue and issecretvalue(data) or false
        if okD and not dataSecret and type(data) == "table" then
            local sid = data.spellId
            local sidSecret = issecretvalue and issecretvalue(sid) or false
            if not sidSecret and type(sid) == "number" and store[sid] == nil then
                local okE, ext = pcall(C.GetRefreshExtendedDuration, unit, instID)
                local extSecret = issecretvalue and issecretvalue(ext) or false
                if okE and not extSecret then
                    if ext == nil then
                        store[sid] = false          -- definitive: no refresh mechanic
                        learnedCount = learnedCount + 1
                    elseif C.GetRefreshCarryOverDuration then
                        -- ★ 12.1.5 PTR 3 (69952): the game's own carry-over, which is what
                        -- AuraContainerUtil.GetPandemicWindow now uses. The old derivation
                        -- below (extended minus base) was wrong for auras that can be pushed
                        -- past the normal refresh cap -- Blizzard's own example is Lifebloom
                        -- under Tranquility -- where it came out <= 0.
                        -- ⚠ ONLY THE YES COMES FROM HERE. A nil or 0 is NOT recorded as a no:
                        -- the call can fail to derive a duration (its optional spellID
                        -- argument exists for that), and the definitive no is the nil
                        -- extended duration above, which is unchanged. Nothing the old
                        -- formula stored needs re-measuring: its failure mode was
                        -- "ambiguous, record nothing", never a wrong answer.
                        local okC, carry = pcall(C.GetRefreshCarryOverDuration, unit, instID)
                        local carrySecret = issecretvalue and issecretvalue(carry) or false
                        if okC and not carrySecret and type(carry) == "number" and carry > 0 then
                            store[sid] = true       -- definitive: carries time over
                            learnedCount = learnedCount + 1
                        end
                        -- else: ambiguous, record nothing
                    else
                        -- Pre-69952 clients: the derivation the engine itself used then.
                        local okB, base = pcall(C.GetAuraBaseDuration, unit, instID)
                        local baseSecret = issecretvalue and issecretvalue(base) or false
                        if okB and not baseSecret and type(base) == "number"
                            and type(ext) == "number" and (ext - base) > 0 then
                            store[sid] = true       -- definitive: carries time over
                            learnedCount = learnedCount + 1
                        end
                        -- else: ambiguous, record nothing
                    end
                end
            end
        end
    end
    return learnedCount
end

-- ⚠ ONLY EVER FILLS GAPS. `store[sid] == nil` above means a spell is measured once and then
-- left alone, so this cannot thrash a value or re-decide something on a bad read. To
-- re-measure, clear the entry.
-- ⚠ Callers are expected to be out of combat. This does not assert it, because the secrecy
-- guards make a restricted call a skip rather than a fault — but the sweep's own gate is
-- what makes the sampler productive rather than merely harmless.
function Pandemic:SampleUnits(...)
    if not (C_UnitAuras and C_UnitAuras.GetUnitAuraInstanceIDs
        and C_UnitAuras.GetRefreshExtendedDuration and C_UnitAuras.GetAuraBaseDuration
        and C_UnitAuras.GetAuraDataByAuraInstanceID) then return 0 end
    local total = 0
    for i = 1, select("#", ...) do
        local unit = select(i, ...)
        if type(unit) == "string" and UnitExists(unit) then
            total = total + sampleUnit(unit)
        end
    end
    return total
end

-- ★ THE GATE. True unless EVERY id behind the aura is a measured NO.
-- Asymmetric on purpose: one YES or one unknown keeps the panel live, so an incomplete
-- table can never take a working feature away from someone. The only thing that greys a
-- panel is positive evidence about every id it could match.
-- ⚠ Accepts both shapes an identity map comes in: a SET ({[774] = true}, which is what
-- includeSpellIDs and BuildADIdentityFilters produce) and a plain array ({774, 8936}).
-- ⚠ No ids at all — an unresolved placement, an empty filter — is UNKNOWN, so it allows.
-- Refusing there would grey the panel for every aura the resolver could not name, which is
-- a resolution problem wearing a capability problem's clothes.
function Pandemic:MayHaveWindow(ids)
    if type(ids) ~= "table" then return true end
    local sawAny = false
    for k, v in pairs(ids) do
        local id = (type(v) == "number") and v or (type(k) == "number" and k or nil)
        if id then
            sawAny = true
            if self:SpellWindowState(id) ~= false then return true end
        end
    end
    return not sawAny
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
-- ☠☠ THIS SECTION USED TO SAY DF.Border's ANIMATION SET COULD NEVER COME HERE. THAT IS
-- NO LONGER TRUE, ON BOTH OF ITS PREMISES. It said every effect rides Border.lua's shared
-- OnUpdate driver (per-frame tainted Lua writing SetVertexColor / SetPoint / Hide on the
-- border's pieces, refused on a button child once auras are secret), and that animation
-- is therefore stripped unconditionally from every container border.
--
-- ★ WHAT CHANGED, IN ORDER:
--   1. DF grew DECLARATIVE paths. `border._secretRect` — true exactly when the border is
--      hosted on a container button — now selects a C-side AnimationGroup build per
--      effect instead of the tick (Border.lua: "CONTAINER-HOSTED BORDERS TAKE THE
--      DECLARATIVE PATH"). Animation on container borders is not stripped any more; it is
--      the shipping `config.adBorderAnim` opt-in on placed indicators, bars, mgroup
--      members and filter/debuff groups.
--   2. 12.1.5 added Enter/Active/Leave animation triggers to CustomAuraButton, so a
--      declarative group can be handed to the ENGINE and played only inside the refresh
--      window instead of looping from creation.
--
-- ⇒ The pandemic border now takes the ordinary DF.Border animation set. (1) is what makes
-- it legal at all and needs no 12.1.5; (2) is what makes it good, and is applied where the
-- border is bound — see the pandemic-border registration in Frames/AuraContainer.lua.
-- ⚠ A declarative builder that finds no usable geometry falls through to the tick, which
-- on a button child is refused, dropped with ONE warn, and re-armed on the next restyle.
-- Bounded, and pre-existing behaviour for every other animated container border.
--
-- ★ WHAT DOES WORK: a native AnimationGroup, built and :Play()ed ONCE inside
-- initializeFrame (secure context) and then run entirely C-side — zero Lua per frame, and
-- nothing tainted touching the button after init.
--
-- ☠ ...but ONLY an Alpha animation. Scale was tried and does NOT run on the registered
-- holder (in game, 2026-08-05: FLASH pulsed, a Scale-based PULSE and a combined BREATHE
-- did nothing at all). The holder carries SecretAspect.Shown plus the forbidden aspects
-- AddPandemicRegion stamps on it, and a scale transform evidently does not survive that
-- where an alpha one does. ⚠ That limit applies to the FLASH's own group on the registered
-- holder; the border set above animates the border's own regions and is not bound by it.
-- ⚠ Re-test Scale on a later build before assuming it is permanently dead — this is an
-- empirical result, not a documented rule. (The "Blizzard are looking at pandemic
-- animation for 12.1.5, so don't build anything clever" note that used to close this
-- paragraph has been overtaken: they shipped it, and the flash is now handed over rather
-- than self-played.)
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
-- The border-animation keys, in BuildSpec's own order (Frames/Border.lua, "Animation:
-- spec.animation is set only when the consumer picked a non-NONE type"). Kept as a list
-- rather than hashing the built spec: StructSig runs per indicator per UNIT_AURA and must
-- not call BuildSpec to answer a signature question.
-- ☠ Keep in step with BuildSpec. A key it reads and this omits is an edit that silently
-- does nothing until something else happens to rebuild the slot.
local ANIM_KEYS = {
    "BorderAnimationType", "BorderAnimationColor", "BorderAnimationFrequency",
    "BorderAnimationParticles", "BorderAnimationLength", "BorderAnimationThickness",
    "BorderAnimationScale", "BorderAnimationInset", "BorderAnimationOffsetX",
    "BorderAnimationOffsetY", "BorderAnimationMask", "BorderAnimationSidesAxis",
    "BorderAnimationCornerLength", "BorderAnimationProcStart",
}
local animParts = {}

-- ⚠ EMPTY WHEN UNCONFIGURED, not a run of "nil,nil,nil…". An always-populated token would
-- change this signature for every profile that has never touched a pandemic animation,
-- forcing a one-off rebuild of every pandemic slot on upgrade for no visible gain. Same
-- stability contract as the factory's rawBorderAnimStructTok.
local function animStructTok(cfg, bp)
    local t = cfg and cfg[bp .. "BorderAnimationType"]
    if not t or t == "NONE" then return "" end
    local parts = animParts
    wipe(parts)
    for i = 1, #ANIM_KEYS do
        local v = cfg[bp .. ANIM_KEYS[i]]
        parts[i] = (type(v) == "table") and colorSig(v) or tostring(v)
    end
    return "|A" .. tconcat(parts, ",")
end

function Pandemic:StructSig(cfg, prefix)
    local mode = self:Mode(cfg, prefix)
    if not mode then return "" end
    -- ☠ THE ANIMATION BELONGS HERE, NOT IN CoSig. A container border's animation groups
    -- are built once and frozen — reaching back into them later is a tainted write to a
    -- button child — so an animation edit must hand over a FRESH button. Putting these
    -- keys in the cosmetic signature instead would hot-apply an edit that provably cannot
    -- take effect, which is the "the slider does nothing" bug in its purest form.
    -- TINT mode has no border, so it contributes nothing and its signature is unchanged.
    local anim = (mode == "BORDER") and animStructTok(cfg, self:BorderPrefix(prefix)) or ""
    return mode .. ":F" .. tostring(self:Flash(cfg, prefix)) .. anim
end

-- The DF.Border keys whose values must move the COSMETIC signature. Still deliberately
-- excludes the Border*Animation* family, but ☠ THE REASON HAS CHANGED and the old one was
-- load-bearing: it used to be "animations are stripped on container borders, so hashing
-- them would churn the sig for settings that provably cannot render". They render now.
-- They are excluded here because they are STRUCTURAL — creation-frozen groups that need a
-- fresh button — so they live in StructSig instead. Excluded from the cosmetic sig either
-- way; hashed in exactly one place rather than none.
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
    --   BORDER — the TOP of the ladder. A ring traces the edge, so it has to read over
    --            the icon's own border and the dispel ring or it is simply hidden.
    --   TINT   — BELOW the duration text, the stack count, the dispel ring and
    --            DF.Border, but above the icon art and the cooldown swipe. A wash covers
    --            the whole button, so at the top it washed over the timer and the stack
    --            count and made both hard to read (Krathe, 2026-08-05). Tint the ICON,
    --            not the information on top of it.
    --
    -- ☠☠ THESE ARE READ FROM `DF.AuraButtonLevels` (Frames/AuraContainer.lua), NEVER
    -- HARDCODED. This block used to carry its own absolutes — 9 and 15, reasoned against
    -- a ladder of 10/12/13/14. The 2026-08-07 squash renumbered that ladder and did not
    -- touch this file, so TINT at 9 rose above ALL of it and re-broke the very thing the
    -- 2026-08-05 fix addressed. Read the table; do not re-derive the numbers here.
    -- Read at CALL time (this runs long after load; AuraContainer loads first anyway).
    local LEVELS = DF.AuraButtonLevels
    spec.level = (mode == "TINT") and LEVELS.PANDEMIC_TINT or LEVELS.PANDEMIC_BORDER

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
        -- ☠ THE ANIMATION STRIP THAT USED TO LIVE HERE IS GONE. It read
        -- `spec.border.animation = nil`, justified as belt-and-braces against a per-frame
        -- forbidden error on a button child. Both halves of that reasoning have expired:
        -- container-hosted borders take the DECLARATIVE path (no per-frame Lua at all),
        -- and the container's own chokepoint no longer strips either — animated container
        -- borders are a shipping feature. Leaving the strip in would mean the pandemic
        -- section is the ONE border in DF that silently ignores its animation controls.
        -- ⚠ The AD canvas preview, named in the old comment as the reason for belt AND
        -- braces, is a plain frame: _secretRect is false there, so it takes the OnUpdate
        -- tick exactly as every other previewed border does, and retunes live while a
        -- slider is dragged. That was an argument FOR passing the animation through, not
        -- against it.
        -- ⚠ Animation is CREATION-FROZEN on a container border, so the keys are
        -- STRUCTURAL — see StructSig, which hashes them so an edit rebuilds the slot
        -- rather than trying to retune a frozen group.
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
