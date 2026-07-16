local addonName, DF = ...

-- ============================================================
-- DF.TextStyle — the shared TEXT-STYLE engine (font/size/outline/shadow/anchor/
-- offsets/justify/colour) for every styled FontString in the addon.
--
-- Mirrors the DF.Border precedent: ONE engine + declarative specs; features are
-- consumers, never hand-rolled copies (the buff/debuff/defensive text blocks were
-- the Nth copy of the same code — this replaces them). GUI:CreateTextControls is
-- the matching Options builder, so a new text capability (e.g. Justify) lands
-- addon-wide by adding it HERE, not per page.
--
-- SPEC (plain table; BuildSpec assembles one from db keys, consumers may extend):
--   font      = LSM font name (nil -> DF default via SafeSetFont)
--   size      = final point size (BuildSpec: baseSize * <prefix>Scale)
--   outline   = "NONE"/"OUTLINE"/... (+ DF's shadow suffix convention — SafeSetFont
--               owns the shadow-rides-the-font-object rule; see font_shadow gotcha)
--   anchor    = point on the anchor frame (default "CENTER")
--   offsetX/Y = point offsets
--   justifyH  = "LEFT"/"CENTER"/"RIGHT" or nil  ─┐ when EITHER is set the string
--   justifyV  = "TOP"/"MIDDLE"/"BOTTOM" or nil  ─┘ becomes a BOX (boxW×boxH,
--               word-wrap on) so justification has something to align within —
--               the DF_AuraLab-proven pattern. nil/"" = legacy auto-sized string.
--   boxW/boxH = the justify box (consumers pass the icon/button size)
--   stableCenter = countdown-timer mode: a fixed, over-wide box centred on the anchor
--               with NO wrap, so centring references the box, not the changing glyph run
--               — no shadow/outline drift, no per-tick wobble. A user Justify still wins.
--   color     = {r,g,b,a} or nil. nil = DON'T touch colour (a formatter/curve or
--               the consumer owns it) — never force white here.
--
-- Apply() is IDEMPOTENT and update-in-place (safe on ApplyStyle re-runs): turning
-- justify off resets the string to auto-size. It never Show()/Hides the string
-- (regions handed to native aura setters must keep Blizzard-owned visibility).
-- ============================================================

local type = type

DF.TextStyle = DF.TextStyle or {}
local TextStyle = DF.TextStyle

-- Read a "<prefix><Suffix>" key block into a spec. opts:
--   baseSize      = point size at Scale 1 (default 10 — the aura-row convention)
--   defaultAnchor = fallback anchor (default "CENTER")
--   defaultOffsetX/defaultOffsetY = fallback offsets (default 0)
--   boxW, boxH    = justify box size (consumers pass icon size; default 0 = none)
-- Key convention (existing db keys): Font, Scale, Outline, Anchor, X, Y — plus the
-- TextStyle additions JustifyH, JustifyV, Color. "" justify = off (legacy render).
function TextStyle:BuildSpec(db, prefix, opts)
    opts = opts or {}
    local function g(suffix) return db[prefix .. suffix] end
    local jH, jV = g("JustifyH"), g("JustifyV")
    if jH == "" then jH = nil end
    if jV == "" then jV = nil end
    return {
        font     = g("Font"),
        size     = (opts.baseSize or 10) * (g("Scale") or 1),
        outline  = g("Outline"),
        anchor   = g("Anchor") or opts.defaultAnchor or "CENTER",
        offsetX  = g("X") or opts.defaultOffsetX or 0,
        offsetY  = g("Y") or opts.defaultOffsetY or 0,
        justifyH = jH,
        justifyV = jV,
        boxW     = opts.boxW,
        boxH     = opts.boxH,
        color    = g("Color"),
    }
end

-- Apply a spec to a FontString, anchored on anchorFrame (a holder or the button).
-- Everything is re-applied in place; no region creation here (consumers own that).
--
-- Default = AUTO-SIZE + anchor placement (never truncates — a fixed icon-width box
-- clips wide text like "59m"). Justify is opt-in per spec: only when the user picks a
-- Justify H/V does the string take a box to align within. (The slight glyph-box
-- centring offset on auto-sized text is accepted — truncation is worse.)
function TextStyle:Apply(fs, spec, anchorFrame)
    if not fs or type(spec) ~= "table" then return end
    anchorFrame = anchorFrame or fs:GetParent()

    local anchor = spec.anchor or "CENTER"
    local offX, offY = spec.offsetX or 0, spec.offsetY or 0

    -- stableCenter centring compensation. WoW centres the INK bounding box (glyphs +
    -- drop shadow), so a shadow offset of sx pushes the GLYPHS left by exactly sx/2.
    -- Add that half back so the glyphs — not glyph+shadow — sit centred. Pixel-exact
    -- for EVEN shadow offsets; odd offsets give a half-pixel, which we round (text on a
    -- half-pixel blurs), leaving an inherent <=0.5px residual. Outline ink is symmetric,
    -- so it needs no compensation. Only in stableCenter mode with no user Justify.
    if spec.stableCenter and not (spec.justifyH or spec.justifyV)
       and type(spec.outline) == "string" and spec.outline:find("SHADOW") then
        local db = (DF.GetDB and DF:GetDB())
            or (DF.db and DF.db[(DF.GUI and DF.GUI.SelectedMode) or "party"])
        local half = ((db and db.fontShadowOffsetX) or 1) / 2
        offX = offX + (half >= 0 and math.floor(half + 0.5) or math.ceil(half - 0.5))
    end

    fs:ClearAllPoints()
    fs:SetPoint(anchor, anchorFrame, anchor, offX, offY)

    if DF.SafeSetFont then
        DF:SafeSetFont(fs, spec.font, spec.size or 10, spec.outline or "NONE")
    end

    -- Centring strategy, in priority order:
    --   1. stableCenter (countdown timers) — a FIXED, over-wide box centred on the anchor
    --      with NO wrap, so the box (not the changing glyph run) is the centring reference.
    --      Kills the shadow/outline left-drift (box is symmetric) and the per-tick wobble
    --      (the box doesn't resize as digits change); over-wide so no value ever clips.
    --      A user-set Justify still wins (drops to box mode below).
    --   2. user Justify — box sized to the icon, word-wrap on, aligned as the user picked.
    --   3. default — auto-size + centre (legacy; the slight glyph-box offset is accepted).
    local userJustify = spec.justifyH or spec.justifyV
    if spec.stableCenter and not userJustify then
        local w = spec.boxW or 0
        local minW = (spec.size or 10) * 6      -- comfortably wider than any timer string
        if w < minW then w = minW end
        fs:SetSize(w, spec.boxH or 0)
        fs:SetWordWrap(false)
        fs:SetJustifyH("CENTER")
        fs:SetJustifyV("MIDDLE")
    elseif userJustify then
        fs:SetSize(spec.boxW or 0, spec.boxH or 0)
        fs:SetWordWrap(true)
        fs:SetJustifyH(spec.justifyH or "CENTER")
        fs:SetJustifyV(spec.justifyV or "MIDDLE")
    else
        fs:SetSize(0, 0)          -- width/height 0 = auto-size (legacy behaviour)
        fs:SetWordWrap(false)
        fs:SetJustifyH("CENTER")
        fs:SetJustifyV("MIDDLE")
    end

    -- Colour is OPTIONAL: nil means someone else owns it (duration formatter
    -- colour escapes, colour-by-time, class colours...) — never stomp it.
    local c = spec.color
    if type(c) == "table" then
        fs:SetTextColor(c.r or c[1] or 1, c.g or c[2] or 1, c.b or c[3] or 1, c.a or c[4] or 1)
    end
end
