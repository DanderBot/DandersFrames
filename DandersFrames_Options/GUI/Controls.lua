-- Part 4 of the GUI toolkit, split from the original GUI.lua.
-- These re-declarations are aliases of the SAME objects the first part
-- created; they add no state. See docs/reorg-tools/splits.manifest.
-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames
local GUI = DF.GUI
local L = DF.L
local S = GUI._state
local C_PANEL, C_ELEMENT, C_HOVER, C_TEXT, C_TEXT_DIM =
      GUI.Colors.panel, GUI.Colors.element, GUI.Colors.hover, GUI.Colors.text, GUI.Colors.textDim
local GetThemeColor = GUI.GetThemeColor
local SnapLen = GUI.SnapLen
local CreateElementBackdrop = GUI._priv.CreateElementBackdrop
local StyleScrollBar = GUI.StyleScrollBar
local AddOverrideIndicators = GUI._priv.AddOverrideIndicators
local AddOrderListOverrideIndicators = GUI._priv.AddOrderListOverrideIndicators
-- ============================================================
-- EXPIRATION CONTROLS (shared) — the 12.1-safe Expiration panel. Pairs with the
-- DF.Expiration engine (Features/Expiration.lua): the engine turns the expiryAlert* keys
-- into a secret-safe reveal, this builds the UI for them, so every consumer (AD icon/square
-- now; frame-level indicators later) renders the same flow with no hand-rolled copy.
--
-- Flow: a master Enable toggle, then Threshold, then a Type dropdown (Border / Tint / Text /
-- Glyph — no Off; Enable owns on/off), then the Type-specific controls.
--
-- HIDE-vs-GREY policy (the rework rule): a control that does NOT belong to the current Type is
-- HIDDEN (its row collapses via hideOn + the group's LayoutChildren + the caller's reflow); a
-- control that belongs but is momentarily inactive is GREYED via disableOn / the group's
-- disableChildrenOn (the standard grey-out). So:
--   Enable off -> everything below the toggle GREYS (stays visible to preview), like
--                 CreateBorderControls' "Show Border off => grey".
--   TEXT/GLYPH -> the text box / glyph dropdown + Anchor (plus Threshold/Offsets/Size).
--   BORDER     -> Match, Colour Mode, Colour (GREY under By-Time), Style, Inset, Opacity
--                 (plus Threshold/Offsets/Size — Size GREYS under Match). No Anchor (centres).
--   TINT       -> as BORDER but no Style (a wash has no thickness).
--
-- Keys are the fixed expiryAlert* set on the passed dbTable (the AD per-aura proxy, or any
-- consumer's table) — every consumer stores the same keys, so no key map is needed. hideOn/
-- disableOn predicates read dbTable directly (ignoring the arg LayoutChildren/RefreshChildStates
-- pass, which is DF.db[SelectedMode]) — the CreateBorderControls convention, and the only way
-- a per-aura proxy's state is seen.
--
-- opts:
--   parent         REQUIRED — the card/page scroll child (widgets parent to it).
--   fullUpdate     value-change callback (re-render preview + live frames).
--   refreshStates  relayout callback — MUST re-run hideOn (LayoutChildren), disableOn
--                  (RefreshChildStates) and the sibling reflow so a mode change collapses the
--                  now-irrelevant rows and slides neighbours. The mode / match / colour-mode
--                  controls fire it. Called once by the caller after build for the initial state.
--   include        { text, glyph, border, tint } — default all true; a consumer can drop modes.
--   anchorOptions  the Anchor dropdown's option table (default: the standard 9-anchor set).
-- Returns the widget table keyed by role so a consumer can attach extra gates.
-- ============================================================
function GUI:CreateExpirationControls(group, dbTable, opts)
    opts = opts or {}
    local parent        = opts.parent
    local include       = opts.include or {}
    local fullUpdate    = opts.fullUpdate or function() end
    local refreshStates = opts.refreshStates or function() end
    local L = DF.L

    -- include.match (default true): square consumers (icon/square) offer Match Icon Size + a
    -- manual Size for frame modes. A RECTANGULAR consumer (bar/health) passes match=false — its
    -- Tint always fills the target, so there's no Match toggle and no manual Size for it.
    local includeMatch = include.match ~= false
    local function enabled() return dbTable.expiryAlertEnabled and true or false end
    local function mode() return dbTable.expiryAlertMode or "BORDER" end
    local function isFrame() local m = mode(); return m == "BORDER" or m == "TINT" end
    -- A Type / Match / Colour-Mode change alters which rows show and which grey, so it must
    -- relayout + reflow AND re-render. (Value-only edits ride fullUpdate alone.)
    local function onStructural() refreshStates(); fullUpdate() end

    local w = {}

    -- Master enable. When off, the whole section GREYS (group.disableChildrenOn below) — the
    -- controls stay visible so the panel still previews them, matching CreateBorderControls'
    -- "Show Border off => grey, don't hide". keepEnabled keeps this toggle itself clickable.
    w.enable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable"], dbTable,
        "expiryAlertEnabled", onStructural), 28)
    w.enable.keepEnabled = true

    -- Threshold + its UNIT (right under Enable): the "show when remaining time drops below
    -- N" gate every type shares. The unit is PER INDICATOR — a glyph revealing at 5 seconds
    -- and a border revealing at 30% are both legitimate — and it also selects which shared
    -- Colours-page ramp a by-time Border/Tint reads, because the threshold and the bands
    -- are ONE formatter sampled against ONE duration property (see Features/Auras.lua).
    -- Percent tops out at 100; seconds keep the original 60s ceiling.
    -- ONE STORED VALUE PER UNIT (mirrors the ramps, and DF.Expiration:Threshold reads the
    -- same pair): a threshold cannot be reinterpreted between units, so each keeps its own
    -- and switching back finds it untouched.
    -- The shared threshold row (AD's design, six other cards already use it): the slider
    -- with a compact unit button sitting directly above its value box, so the number and
    -- the unit read as one control. unitKeys gives it the per-unit key pair, so toggling
    -- swaps which value is live rather than reinterpreting one.
    -- Structural: the formatter is bind-frozen, so a unit change must Rebuild the companion
    -- (DF.Expiration:StructSig folds the unit in) — refreshPage carries onStructural, and
    -- the row also re-captions and re-ranges itself in place.
    w.threshold = group:AddWidget(GUI:CreateExpiringThresholdRow(parent, dbTable, {
        thresholdModeKey = "expiryAlertThresholdUnit",
        unitKeys  = { SECONDS = "expiryAlertThreshold", PERCENT = "expiryAlertThresholdPercent" },
        labels    = { SECONDS = L["Alert Below (seconds)"], PERCENT = L["Alert Below (%)"] },
        ranges    = { SECONDS = { min = 1, max = 60, step = 1 },
                      PERCENT = { min = 1, max = 100, step = 1 } },
        -- Seeded on first use: an unset percent threshold would read 1 and hide the
        -- reveal in the final 1% of the aura.
        defaults  = { SECONDS = 5,
                      PERCENT = (DF.Expiration and DF.Expiration.PERCENT_THRESHOLD_DEFAULT) or 30 },
        refreshPage = onStructural,
    }), 54)

    -- Type — the reveal kind (no Off; the Enable toggle owns on/off). Border / Tint lead (the
    -- primary reveals), then the Text / Glyph payloads. Consumers can drop types via include.
    local modeOptions = { _order = {} }
    local function addMode(key, label, on)
        if on == false then return end
        modeOptions[key] = label
        modeOptions._order[#modeOptions._order + 1] = key
    end
    addMode("BORDER", L["Border"], include.border)
    addMode("TINT", L["Tint"], include.tint)
    addMode("TEXT", L["Custom Text"], include.text)
    addMode("GLYPH", L["Glyph"], include.glyph)
    w.mode = group:AddWidget(GUI:CreateDropdown(parent, L["Type"], modeOptions,
        dbTable, "expiryAlertMode", onStructural), 54)

    -- TEXT: the custom alert string.
    w.text = group:AddWidget(GUI:CreateEditBox(parent, L["Alert Text"], dbTable, "expiryAlertText"), 48)
    w.text.hideOn = function() return mode() ~= "TEXT" end

    -- GLYPH: the glyph dropdown. Labels embed the atlas escape as a live preview via the
    -- shared escape builder, so the dropdown can never drift from the live band string.
    local glyphOptions = { _order = {} }
    for i, gl in ipairs(DF.ExpiryAlertGlyphs) do
        glyphOptions[gl.key] = DF:GetExpiryAlertGlyphEscape(gl.key, 16) .. " " .. L[gl.name]
        glyphOptions._order[i] = gl.key
    end
    w.glyph = group:AddWidget(GUI:CreateDropdown(parent, L["Glyph"], glyphOptions, dbTable, "expiryAlertGlyph"), 54)
    w.glyph.hideOn = function() return mode() ~= "GLYPH" end

    -- ── BORDER / TINT appearance: a secret-safe |T overlay revealed below the threshold,
    -- tinted statically OR stepped through the same Colours-page breakpoints the duration text
    -- uses. Colour Mode, Colour, Style, Opacity — every row here hides outside the frame modes.
    local function hideNonFrame() return not isFrame() end

    w.colorMode = group:AddWidget(GUI:CreateDropdown(parent, L["Color Mode"],
        { STATIC = L["Static"], BYTIME = L["Color by Time Remaining"] },
        dbTable, "expiryAlertBorderColorMode", onStructural), 54)   -- By-Time greys the picker
    w.colorMode.hideOn = hideNonFrame

    -- Cross-link to the shared Colours-page editor those By-Time breakpoints live in. Frame
    -- modes only (like Color Mode itself) — a rectangular consumer with no Border/Tint (bar)
    -- never reaches here, so its fixed ramp gets no link. Fixed-layout note, so size it up front.
    local expLinkW = GUI:GroupInnerWidth(group)
    w.colorsLink = GUI:CreateColorsPageLink(parent, expLinkW)
    group:AddWidget(w.colorsLink, (w.colorsLink.layoutHeight or 16) + 2)
    w.colorsLink.hideOn = hideNonFrame

    -- Say the blend limitation WHERE the by-time mode is chosen, not only on the
    -- Colours page: the reveal's |T escapes ignore the vertex colour a curve writes,
    -- so it steps even while duration text blends.
    w.stepNote = group:AddWidget(GUI:CreateNote(parent,
        L["The expiry border and tint always step between colors."], { width = expLinkW }))
    w.stepNote.hideOn = function()
        return not isFrame() or dbTable.expiryAlertBorderColorMode ~= "BYTIME"
    end

    w.color = group:AddWidget(GUI:CreateColorPicker(parent, L["Border Color"], dbTable,
        "expiryAlertBorderColor", false, fullUpdate, fullUpdate, true), 28)
    w.color.hideOn = hideNonFrame
    -- By-Time follows the Colours page, so the static picker is inert then — GREY (not hide)
    -- so it reads as "switch to Static to use this".
    w.color.disableOn = function() return dbTable.expiryAlertBorderColorMode == "BYTIME" end

    -- Style = the frame outline art (Thin/Medium/Thick — a scaled bitmap can't vary its own
    -- line weight, hence discrete arts). BORDER only; a Tint is a solid wash with no thickness.
    w.style = group:AddWidget(GUI:CreateDropdown(parent, L["Style"],
        { THIN = L["Thin"], MEDIUM = L["Medium"], THICK = L["Thick"], _order = { "THIN", "MEDIUM", "THICK" } },
        dbTable, "expiryAlertBorderThickness"), 54)
    w.style.hideOn = function() return mode() ~= "BORDER" end

    -- Opacity: region alpha on the |T overlay (0 = invisible, 1 = full). Multiplies the art's
    -- own alpha, so a Tint (50% art) tops out at a 50% wash while a frame can be fully opaque.
    -- Grouped with the other appearance controls, NOT the placement run further down.
    w.opacity = group:AddWidget(GUI:CreateSlider(parent, L["Opacity"], 0, 1, 0.05, dbTable, "expiryAlertBorderAlpha"), 54)
    w.opacity.hideOn = hideNonFrame

    -- ── Size: Match Icon Size (auto) sits directly above Size (manual). Match is the auto/manual
    -- switch and Size greys under it, so their adjacency shows the relationship. A rectangular
    -- consumer (include.match = false) has no Match — its Tint always fills the target.
    if includeMatch then
        w.match = group:AddWidget(GUI:CreateCheckbox(parent, L["Match Icon Size"], dbTable,
            "expiryAlertBorderMatchIcon", onStructural), 28)   -- BORDER/TINT only
        w.match.hideOn = hideNonFrame
    end

    -- Size: TEXT/GLYPH use it as the font/glyph size. For a frame/tint it's the manual square
    -- size — HIDDEN for a rectangular consumer (the tint auto-fills), and GREYED for a square
    -- one while Match is on (auto-sized).
    w.size = group:AddWidget(GUI:CreateSlider(parent, L["Size"], 6, 48, 1, dbTable, "expiryAlertSize"), 54)
    w.size.hideOn = function() return not includeMatch and isFrame() end
    w.size.disableOn = function() return includeMatch and isFrame() and dbTable.expiryAlertBorderMatchIcon ~= false end

    -- ── Placement: Inset (a frame/tint's fit off the icon edge), Anchor (Text/Glyph), Offsets.
    w.inset = group:AddWidget(GUI:CreateSlider(parent, L["Inset"], -10, 10, 1, dbTable, "expiryAlertBorderInset"), 54)
    w.inset.hideOn = hideNonFrame
    w.inset.tooltip = L["How far inside the icon edge the reveal sits. Negative values push it outward, so it rings the icon rather than sitting on it."]

    -- Anchor: Text/Glyph only — a frame/tint always centres (the engine forces CENTER), so
    -- hide it in those modes rather than let a stale anchor de-centre the overlay.
    w.anchor = group:AddWidget(GUI:CreateDropdown(parent, L["Anchor"],
        opts.anchorOptions or {
            CENTER = L["Center"], TOP = L["Top"], BOTTOM = L["Bottom"], LEFT = L["Left"], RIGHT = L["Right"],
            TOPLEFT = L["Top Left"], TOPRIGHT = L["Top Right"], BOTTOMLEFT = L["Bottom Left"], BOTTOMRIGHT = L["Bottom Right"],
            _order = { "TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT" },
        }, dbTable, "expiryAlertAnchor"), 54)
    w.anchor.hideOn = function() local m = mode(); return m ~= "TEXT" and m ~= "GLYPH" end

    -- 0.5 step: the reveal rides the text engine (sub-pixel positioning we can't snap), so
    -- half-steps let the user split a stubborn half-pixel offset integer steps jump over.
    w.offsetX = group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -150, 150, 0.5, dbTable, "expiryAlertOffsetX"), 54)
    w.offsetY = group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -150, 150, 0.5, dbTable, "expiryAlertOffsetY"), 54)

    -- Master gate: Enable off greys every control below the toggle (keepEnabled spares it).
    -- Composes with each control's own disableOn (By-Time colour, Match-Icon size).
    group.disableChildrenOn = function() return not enabled() end

    return w
end

-- ============================================================
-- PANDEMIC CONTROLS (shared) — the refresh-window cue. Pairs with the DF.Pandemic engine
-- (Features/Pandemic.lua) exactly as CreateExpirationControls pairs with DF.Expiration:
-- the engine turns the pandemic* keys into a region spec, this builds the UI for them, and
-- every consumer (AD indicator cards, the Buffs/Debuffs pages) gets the same flow.
--
-- ☠ NO THRESHOLD CONTROLS, deliberately. The window is the GAME's — it opens exactly when
-- a refresh would clip nothing, per spell — so there is nothing to tune. A slider here
-- would be a lie. The explainer note says so where the missing control would have been,
-- because "why can't I set when this fires" is the obvious first question. It also says
-- that many auras never light, which is the other obvious first question (a charge-based
-- aura like Prayer of Mending has no refresh window at all).
--
-- ☠ NO COLOUR MODE. The engine reports a boolean window, not a remaining time, so there is
-- no ramp to walk. That is the one thing Expiration can do and this cannot — and conversely
-- a static wash is trivial here and impossible there, which is why the two are
-- complementary rather than redundant. Keep both.
--
-- ★ TWO TYPES. Custom Text and Glyph were built and dropped (Krathe, 2026-08-05): a
-- boolean "now" cue wants to read at a glance from the edge of vision, which is what a ring
-- or a wash does and what a glyph competes with the icon to do.
--
-- ★ THE BORDER IS THE HOUSE BORDER. GUI:CreateBorderControls over the engine's own key
-- prefix — the same panel the frame border, defensive icon and AD indicators use, with the
-- same style/thickness/inset/offset/colour controls. Nothing about it is special-cased
-- here: DF.Pandemic:BorderPrefix resolves to "pandemic" / "buffPandemic", and DF.Border's
-- standard "<prefix>Border*" keys hang off that.
--
-- opts:
--   parent         REQUIRED — the card/page scroll child.
--   prefix         "" / nil for per-indicator records (Aura Designer), or a row prefix
--                  ("buff" / "debuff") for the flat profile table. Same split the engine
--                  uses; DF.Pandemic:Key is the single source for the resulting names.
--   fullUpdate     value-change callback (re-render preview + live frames).
--   refreshStates  relayout callback — MUST re-run hideOn (LayoutChildren) and disableOn
--                  (RefreshChildStates) plus the sibling reflow, so a Type change collapses
--                  the now-irrelevant rows. Enable / Type fire it.
--   expiryCollision  true only where an Expiration section ALSO exists on the same table
--                  (the AD cards). The rows have no expiry alert at all, so they pass
--                  nothing and never build the collision notes.
--   masterGate     optional predicate(db) for a PAGE-level feature switch above this
--                  section — "Show Buffs" on the row pages. Folded in here rather than
--                  wrapped by the caller for two reasons: a caller wrapping
--                  group.disableChildrenOn has to remember to compose with the one this
--                  helper already installed (drop it and the capability/enable grey stops
--                  working), and it must ALSO reach inside for w.enable, which carries
--                  keepEnabled and so is deliberately spared by the group gate. Both are
--                  easy to get half-right at a call site; there is exactly one correct
--                  answer, so it belongs in the helper.
-- Returns the widget table keyed by role.
-- ============================================================
function GUI:CreatePandemicControls(group, dbTable, opts)
    opts = opts or {}
    local parent        = opts.parent
    local prefix        = opts.prefix
    local fullUpdate    = opts.fullUpdate or function() end
    local refreshStates = opts.refreshStates or function() end
    local L = DF.L
    local P = DF.Pandemic

    local function K(suffix) return P:Key(prefix, suffix) end
    -- Read the STORED type, not the engine's resolved Mode(): Mode returns nil on a client
    -- without the API, and the editor still has to lay its rows out coherently while the
    -- whole section sits greyed with the unsupported note showing.
    -- ☠ The unset fallback comes from the ENGINE's constant, not a literal here. Those two
    -- diverging is exactly how a dropdown ends up displaying a type the renderer never draws.
    local function mode() return dbTable[K("Mode")] or DF.Pandemic.DEFAULT_MODE end
    local function isTint() return mode() == "TINT" end
    local function isBorder() return mode() == "BORDER" end
    local function enabled() return dbTable[K("Enabled")] and true or false end
    local supported = P:IsSupported()
    local masterGate = opts.masterGate
    local function gated(db) return masterGate and masterGate(db) or false end
    local function onStructural() refreshStates(); fullUpdate() end

    local w = {}
    local noteW = GUI:GroupInnerWidth(group)

    w.enable = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable"], dbTable,
        K("Enabled"), onStructural), 28)
    -- keepEnabled spares this toggle from the GROUP gate below (so "Enable off" doesn't grey
    -- the switch you need to turn it back on) — it does NOT spare it from its own disableOn,
    -- which is why the two compose here rather than fight.
    w.enable.keepEnabled = true
    -- On a client without the registrar the toggle itself must go dead, or a user can switch
    -- on a feature that provably cannot render (the silent-capability-skip rule). The page's
    -- master switch greys it too — nothing above it being on means nothing below it applies.
    w.enable.disableOn = function(db) return not supported or gated(db) end

    -- Says why there is no threshold, and why a given spell may never light. Sits directly
    -- under Enable, where the Alert Below slider lives in the Expiration section —
    -- answering both questions in the place the missing control would have occupied.
    w.explain = group:AddWidget(GUI:CreateNote(parent,
        L["Highlights an aura once you can refresh it without losing any of its remaining time. The game decides when that is, and it differs per spell — auras that can't be refreshed never light up."],
        { width = noteW }))

    -- Shown only on a pre-PTR-8 client. Explicit, because the alternative is a section of
    -- greyed controls with no stated reason.
    w.unsupported = group:AddWidget(GUI:CreateNote(parent,
        L["This game build does not support refresh-window highlights."],
        { tone = "caution", prefix = "Note", width = noteW }))
    w.unsupported.hideOn = function() return supported end

    w.mode = group:AddWidget(GUI:CreateDropdown(parent, L["Type"],
        { BORDER = L["Border"], TINT = L["Tint"], _order = { "BORDER", "TINT" } },
        dbTable, K("Mode"), onStructural), 54)

    -- FLASH: a looping alpha pulse. Structural in the engine (the group is built and
    -- started in the secure init pass), so BOTH controls rebuild the slot rather than
    -- restyling — hence onStructural on the toggle and on the speed slider.
    --
    -- ☠ ONE EFFECT, and that is the honest ceiling here for now.
    --   * DF.Border's set (Proc, Wipe, Ripple, Segment Reveal, Sides, Corners, DF Dash)
    --     cannot attach: every one rides Border.lua's shared per-frame OnUpdate, which
    --     writes to the border's pieces from tainted Lua and errors on a button child
    --     while auras are secret.
    --   * A native Scale animation WAS built and tried in game and did nothing, where the
    --     Alpha one works — see the note in Features/Pandemic.lua.
    --   * Blizzard have said pandemic animation is being looked at for 12.1.5, so this is
    --     not worth working around; a supported version is likely to land.
    w.flash = group:AddWidget(GUI:CreateCheckbox(parent, L["Flash"], dbTable,
        K("Flash"), onStructural), 28)
    w.flash.tooltip = L["Pulses the highlight in and out instead of holding it steady."]
    w.flashSpeed = group:AddWidget(GUI:CreateSlider(parent, L["Flash Speed"], 0.2, 3, 0.1,
        dbTable, K("FlashSpeed"), nil, onStructural, true), 54)
    w.flashSpeed.disableOn = function() return not dbTable[K("Flash")] end

    -- ── TINT: a solid wash. Colour, opacity and inset — three controls, because that is
    -- genuinely all a wash has.
    local function hideTint() return not isTint() end
    w.tintColor = group:AddWidget(GUI:CreateColorPicker(parent, L["Color"], dbTable,
        K("TintColor"), false, fullUpdate, fullUpdate, true), 28)
    w.tintColor.hideOn = hideTint
    w.tintAlpha = group:AddWidget(GUI:CreateSlider(parent, L["Opacity"], 0, 1, 0.05,
        dbTable, K("TintAlpha")), 54)
    w.tintAlpha.hideOn = hideTint
    w.tintInset = group:AddWidget(GUI:CreateSlider(parent, L["Inset"], -10, 10, 1,
        dbTable, K("TintInset")), 54)
    w.tintInset.hideOn = hideTint
    w.tintInset.tooltip = L["How far inside the icon edge the highlight sits. Negative values push it outward, so it rings the icon rather than sitting on it."]

    -- ── BORDER: the house border panel over the engine's key prefix.
    --   noShowToggle — the section's own Enable IS the master; a second "Show Border"
    --                  checkbox under it would be a switch that does nothing on its own.
    --   include      — ☠ EVERY KEY HERE IS OPT-IN. Passing `{ animation = false }` did not
    --                  drop animations, it dropped Inset, Offset, Blend Mode, Gradient,
    --                  Shadow and Alpha as well, leaving three controls. This is the same
    --                  set the AD icon/square/bar border cards pass, so a pandemic ring now
    --                  offers exactly what any other icon border does.
    --                  Deliberately NOT opted in:
    --                    animate     — stripped unconditionally on container borders (it
    --                                  cannot run on a button child while auras are secret),
    --                                  so it would be a control that provably never renders.
    --                    classColor / roleColor — a refresh cue is about the AURA, not who
    --                                  is wearing it; and the resolver needs a unit the AD
    --                                  path never threads.
    --                    colorByTime — there is no ramp: the window is boolean.
    --                    colorByType — dispel colouring, unrelated.
    --   hideWhen — collapses the whole border run outside BORDER mode, matching the tint
    --                  run above. CreateBorderControls applies this to every child it makes,
    --                  which is exactly why it is passed rather than set per widget here.
    w.border = GUI:CreateBorderControls(group, dbTable, P:BorderPrefix(prefix), {
        parent       = parent,
        noShowToggle = true,
        include      = {
            inset = true, offset = true, blendMode = true,
            gradient = true, shadow = true, alpha = true,
        },
        hideWhen     = function() return not isBorder() end,
        fullUpdate   = fullUpdate,
        refreshStates = refreshStates,
    })

    -- ── COLLISION NOTES (only where an Expiration section shares this table).
    --
    -- ☠ Warn on the same SPACE, never on the same TIME. The two windows overlapping is the
    -- POINT: on a 15s HoT the refresh window opens at 4.5s and a 20% expiry threshold at
    -- 3.0s, so the expiry alert fires INSIDE the refresh window — a user who wants "refresh
    -- me / now you've lost it" gets exactly that. Warning about that would be warning about
    -- the feature working. What actually goes wrong is two reveals occupying the same
    -- pixels, and only in two shapes now that the payload types are gone: two washes, or
    -- two rings at the same inset. A tint and a border never collide.
    if opts.expiryCollision then
        local function bothOn()
            return (enabled() and dbTable.expiryAlertEnabled and dbTable.expiryAlertMode) and true or false
        end

        -- Two tints cover the whole icon, so whichever draws second wins outright and the
        -- other is not merely cluttered — it is gone. No inset can separate them, so this is
        -- the one case that is always wrong rather than merely worth a nudge.
        w.tintClash = group:AddWidget(GUI:CreateNote(parent,
            L["Expiration and Pandemic are both set to Tint. They cover the same area, so only one will ever be seen."],
            { tone = "caution", prefix = "Warning", width = noteW }))
        w.tintClash.hideOn = function()
            return not (bothOn() and isTint() and dbTable.expiryAlertMode == "TINT")
        end

        -- Two rings at the SAME inset sit on top of each other; at different insets they
        -- nest, which is a deliberate and rather good look. So this is a hint, not a warning,
        -- and it names the fix. The pandemic inset here is DF.Border's own key, not a
        -- pandemic-specific one — the border IS a DF.Border.
        w.borderClash = group:AddWidget(GUI:CreateNote(parent,
            L["Expiration and Pandemic both draw a border at this inset. Give one of them a different Inset to show both at once."],
            { tone = "info", prefix = "Tip", width = noteW }))
        w.borderClash.hideOn = function()
            if not (bothOn() and isBorder() and dbTable.expiryAlertMode == "BORDER") then return true end
            local mine = tonumber(dbTable[P:BorderPrefix(prefix) .. "BorderInset"]) or 0
            return mine ~= (tonumber(dbTable.expiryAlertBorderInset) or 0)
        end
    end

    -- Master gate: an unsupported client, the page's own feature switch, or Enable off greys
    -- everything below the toggle. Composed here so a caller never has to wrap this and risk
    -- dropping one of the three.
    group.disableChildrenOn = function(db)
        return not supported or gated(db) or not enabled()
    end

    return w
end

-- Small dim inline subheader (section divider inside a SettingsGroup), matching
-- AD's "State Overrides" / "Icon Effects" dividers.
function GUI:CreateExpiringSubheader(parent, text)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(18)
    local label = frame:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(label, 8, "")
    label:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 2, 1)
    label:SetText(text)
    local c = GetThemeColor()
    label:SetTextColor(c.r, c.g, c.b, 0.75)
    return frame
end

-- Threshold slider + a compact s / % SEGMENT TOGGLE sitting directly above the
-- slider's value box, so the number and the unit read as one control. The slider's
-- label/range switch with the mode, so the row rebuilds the page on toggle via
-- opts.refreshPage. Keys are parameterised (thresholdKey / thresholdModeKey) so any
-- consumer's DB schema works.
--
-- ⚠ IN PRACTICE ONLY THE unitKeys PATH IS USED. The one caller
-- (CreateExpirationControls) always passes unitKeys, and nothing in either addon ever
-- assigns thresholdKey, resetValues, modeText or modeSegmentWidth -- so the
-- single-key half of this contract, and those four knobs, are advertised but
-- unexercised. Treat the paragraph below as a description of intent, not of tested
-- behaviour, and see the ☠ note on the else branch further down.
--
-- opts.unitKeys = { SECONDS = key, PERCENT = key } switches the row to ONE STORED
-- VALUE PER UNIT instead of a single key reinterpreted between them. A threshold
-- cannot be reinterpreted (5 seconds is not 5 percent), so with this set the toggle
-- swaps which value is live and leaves the other untouched — no clamping, no reset.
-- The slider then binds through customGet/customSet and re-labels/re-ranges itself
-- from refreshContent, so the row is correct even if a consumer's refresh does not
-- rebuild it. opts.labels / opts.ranges override the slider caption and range per
-- unit; opts.modeText overrides the segment labels (default s / %); opts.resetValues
-- the single-key reset pair. Every default preserves the original behaviour.
function GUI:CreateExpiringThresholdRow(parent, dbTable, opts)
    opts = opts or {}
    local tKey = opts.thresholdKey
    local mKey = opts.thresholdModeKey
    local unitKeys = opts.unitKeys
    local refresh = opts.refreshPage or function() end
    local width = opts.width or 248
    local labels = opts.labels or {}
    local ranges = opts.ranges or {}
    local modeText = opts.modeText or {}
    local function secondsNow() return mKey and dbTable[mKey] == "SECONDS" or false end
    local isSeconds = secondsNow()

    local container = CreateFrame("Frame", nil, parent)
    container:SetHeight(54)
    container:SetWidth(width)

    -- Caption + range for a unit. Ranges default to the original pair (seconds
    -- 1-60 step 1; percent 5-100 step 5).
    local function unitSpec(sec)
        local r = ranges[sec and "SECONDS" or "PERCENT"]
        if sec then
            return labels.SECONDS or L["Expiring Threshold (seconds)"],
                   (r and r.min) or 1, (r and r.max) or 60, (r and r.step) or 1
        end
        return labels.PERCENT or L["Expiring Threshold (%)"],
               (r and r.min) or 5, (r and r.max) or 100, (r and r.step) or 5
    end

    local label, minV, maxV, step = unitSpec(isSeconds)
    local slider
    if unitKeys then
        -- Per-unit keys: resolve on EVERY access so a toggle can never write one
        -- unit's number into the other's key, and seed a unit's value on first use.
        local function keyNow() return secondsNow() and unitKeys.SECONDS or unitKeys.PERCENT end
        local function readValue()
            local k = keyNow()
            local v = tonumber(dbTable and dbTable[k])
            if v == nil then
                local _, dMin = unitSpec(secondsNow())
                v = (opts.defaults and opts.defaults[secondsNow() and "SECONDS" or "PERCENT"]) or dMin
                if dbTable then dbTable[k] = v end
            end
            return v
        end
        slider = GUI:CreateSlider(container, label, minV, maxV, step,
            nil, nil, nil, nil, nil,
            readValue, function(v) if dbTable then dbTable[keyNow()] = v end end)
        slider.refreshContent = function(self)
            local sec = secondsNow()
            local lbl, lo, hi = unitSpec(sec)
            if self.label then self.label:SetText(lbl) end
            self:SetRange(lo, hi)   -- also re-reads the value through customGet
        end
    else
        -- ☠ UNREACHABLE TODAY, and left in place deliberately rather than deleted.
        -- This factory has exactly ONE caller (CreateExpirationControls, above), and
        -- it always passes unitKeys -- so `thresholdKey`/`tKey`, this whole branch,
        -- and opts.resetValues below it cannot run. Nothing assigns thresholdKey or
        -- resetValues anywhere in either addon.
        --
        -- ⚠ Not removed because deleting it collapses the if/else and turns a
        -- two-mode factory into a single-mode one -- a restructure of a live widget,
        -- not a dead-code removal, and the header two paragraphs up still advertises
        -- the parameterised-keys contract. Decide the contract first, then cut.
        --
        -- Single key reinterpreted between units: clamp it into the new range.
        if isSeconds then
            if tKey and dbTable[tKey] and dbTable[tKey] > maxV then dbTable[tKey] = 10 end
        else
            if tKey and dbTable[tKey] and dbTable[tKey] < minV then dbTable[tKey] = 30 end
        end
        slider = GUI:CreateSlider(container, label, minV, maxV, step, dbTable, tKey)
    end
    slider:SetPoint("TOPLEFT", 0, 0)
    slider:SetWidth(width)

    -- Unit picker: a two-segment toggle with the units ON the buttons, boxed in one
    -- track, sitting directly above the slider's value box. Terse labels (s / %) keep
    -- it to the button's footprint; each segment tooltips its full name.
    local modeBtn = GUI:CreateSegmentToggle(container, {
        { value = "SECONDS", label = modeText.SECONDS or L["s"], tooltip = L["Seconds"] },
        { value = "PERCENT", label = modeText.PERCENT or L["%"], tooltip = L["Percent"] },
    }, dbTable, mKey, function(newVal)
        local toSeconds = (newVal == "SECONDS")
        -- Reset the value ONLY when one key is being reinterpreted between units.
        -- With unitKeys each unit keeps its own, so switching back finds it intact.
        if not unitKeys and tKey then
            local r = opts.resetValues or {}
            dbTable[tKey] = toSeconds and (r.SECONDS or 10) or (r.PERCENT or 30)
        end
        refresh()
        -- Re-sync in place as well as asking for a rebuild: a consumer whose refresh
        -- only re-evaluates states would otherwise leave a stale caption and range.
        if slider.refreshContent then slider:refreshContent() end
    end, {
        segmentWidth = opts.modeSegmentWidth or 26,
        fallbackValue = "PERCENT",   -- matches isSeconds: an unset mode key reads as percent
        tooltipLines = { L["Threshold Mode"] },
    })
    modeBtn:SetPoint("BOTTOMRIGHT", slider, "TOPRIGHT", -10, 2)

    -- Composite row: forward grey-out (disableOn) to its slider + unit toggle so the
    -- whole row dims when the expiring feature is off. The row dims uniformly via
    -- SetAlpha; each child blocks its own interaction (the toggle's SetEnabled dims and
    -- un-mouses its segments) — deliberately NOT SetDisabled or a raw Button:SetEnabled
    -- on the segments, both of which fight the shared hover wash / SetActive state.
    container.SetEnabled = function(_, enabled)
        container:SetAlpha(enabled and 1 or 0.4)
        if slider.SetEnabled then slider:SetEnabled(enabled) end
        modeBtn:SetEnabled(enabled)
    end
    -- Keep the unit toggle in sync on external changes (profile switch, page refresh).
    container.refreshContent = function()
        modeBtn:Refresh()
        if slider.refreshContent then slider:refreshContent() end
    end

    return container
end

-- (GUI:CreateExpiringControls removed 2026-07-25 with the pre-12.1 Expiring system:
--  it drove the remaining-time border/tint panel, which is unreadable on the 12.1
--  container path. The 12.1-safe panel is GUI:CreateExpirationControls above --
--  note the near-identical name; that one is current and engine-backed.)

-- ============================================================
-- GROWTH DIRECTION CONTROL
-- Three linked dropdowns (Orientation, Wrap, Direction) that
-- compose into a single growth value like "LEFT_UP"
-- ============================================================

-- Decompose "LEFT_UP" into {orientation, wrap, direction}
local function DecomposeGrowth(growth)
    local primary, secondary = strsplit("_", growth or "LEFT_UP")
    if not secondary then
        -- Malformed value (no underscore) — fall back to LEFT_UP
        return "HORIZONTAL", "UP", "LEFT"
    end
    if primary == "CENTER" then
        if secondary == "UP" or secondary == "DOWN" then
            return "HORIZONTAL", secondary, "CENTER"
        else
            return "VERTICAL", secondary, "CENTER"
        end
    elseif primary == "LEFT" or primary == "RIGHT" then
        return "HORIZONTAL", secondary, primary
    else
        return "VERTICAL", secondary, primary
    end
end

-- Compose {orientation, wrap, direction} back into "LEFT_UP"
local function ComposeGrowth(orientation, wrap, direction)
    -- Safety: if wrap is nil, pick a sensible default for the orientation
    if not wrap then
        wrap = (orientation == "HORIZONTAL") and "UP" or "LEFT"
    end
    if direction == "CENTER" then
        return "CENTER_" .. wrap
    else
        return direction .. "_" .. (wrap or "UP")
    end
end

-- Map values when switching orientation so the selection stays sensible
local ORIENTATION_MAP = {
    UP = "LEFT", DOWN = "RIGHT", LEFT = "UP", RIGHT = "DOWN",
}

function GUI:CreateGrowthControl(parent, db, dbKey, callback)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 155)

    -- Read current decomposed state
    local curOrientation, curWrap, curDirection = DecomposeGrowth(db[dbKey] or "LEFT_UP")

    -- Option tables per orientation
    -- Display text is localized; the value-keys (HORIZONTAL, UP, …) and _order
    -- arrays are raw identifiers and must NOT be localized.
    local ORIENT_OPTIONS = {
        HORIZONTAL = L["Horizontal"],
        VERTICAL = L["Vertical"],
        _order = {"HORIZONTAL", "VERTICAL"},
    }
    local WRAP_OPTIONS = {
        HORIZONTAL = { UP = L["Up"], DOWN = L["Down"], _order = {"UP", "DOWN"} },
        VERTICAL = { LEFT = L["Left"], RIGHT = L["Right"], _order = {"LEFT", "RIGHT"} },
    }
    -- "From Center" (not "Center"): the row grows OUTWARD in both directions from the
    -- anchor — a behaviour, not a direction like Left/Right — so the label reads true.
    -- Stored value stays CENTER (a separate locale key from the generic L["Center"]
    -- used by anchor pickers elsewhere).
    local DIR_OPTIONS = {
        HORIZONTAL = { LEFT = L["Left"], CENTER = L["From Center"], RIGHT = L["Right"], _order = {"LEFT", "CENTER", "RIGHT"} },
        VERTICAL = { UP = L["Up"], CENTER = L["From Center"], DOWN = L["Down"], _order = {"UP", "CENTER", "DOWN"} },
    }

    -- Shared write-back: recompose and save
    local function WriteBack()
        db[dbKey] = ComposeGrowth(curOrientation, curWrap, curDirection)
        DF:UpdateAll()
        if callback then callback() end
        if parent.RefreshStates then parent:RefreshStates() end
    end

    -- Sub-dropdown builder (simplified version of CreateDropdown, no override indicators)
    local function BuildMiniDropdown(yOffset, label, options, getValue, setValue)
        local frame = CreateFrame("Frame", nil, container)
        frame:SetPoint("TOPLEFT", 0, yOffset)
        frame:SetPoint("TOPRIGHT", 0, yOffset)
        frame:SetHeight(50)

        local lbl = frame:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        lbl:SetPoint("TOPLEFT", 0, 0)
        lbl:SetText(label)
        lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

        local btn = CreateFrame("Button", nil, frame, "BackdropTemplate")
        btn:SetPoint("TOPLEFT", 0, -16)
        btn:SetPoint("TOPRIGHT", 0, -16)
        btn:SetHeight(24)
        CreateElementBackdrop(btn)

        btn.Text = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        btn.Text:SetPoint("LEFT", 8, 0)
        btn.Text:SetPoint("RIGHT", -20, 0)
        btn.Text:SetJustifyH("LEFT")
        btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

        local arrow = btn:CreateTexture(nil, "OVERLAY")
        arrow:SetPoint("RIGHT", -8, 0)
        arrow:SetSize(12, 12)
        arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
        arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

        local menuFrame = CreateFrame("Frame", nil, btn, "BackdropTemplate")
        menuFrame:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
        menuFrame:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
        menuFrame:SetFrameStrata("FULLSCREEN_DIALOG")
        GUI:RegisterMenu(menuFrame)
        menuFrame:SetClampedToScreen(true)
        CreateElementBackdrop(menuFrame)
        menuFrame:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.98)
        menuFrame:Hide()

        menuFrame:SetScript("OnHide", function()
            if S.currentOpenDropdown == menuFrame then
                S.currentOpenDropdown = nil
            end
        end)

        local menuButtons = {}

        -- Rebuild populates menu items from current options
        frame.Rebuild = function(self, newOptions)
            for _, mb in ipairs(menuButtons) do mb:Hide() end
            wipe(menuButtons)

            local sorted = {}
            if newOptions._order then
                for _, k in ipairs(newOptions._order) do
                    if newOptions[k] then
                        sorted[#sorted + 1] = { key = k, value = newOptions[k] }
                    end
                end
            else
                for k, v in pairs(newOptions) do
                    if k ~= "_order" then
                        sorted[#sorted + 1] = { key = k, value = v }
                    end
                end
                table.sort(sorted, function(a, b) return a.value < b.value end)
            end

            local menuHeight = 0
            for i, opt in ipairs(sorted) do
                local menuBtn = CreateFrame("Button", nil, menuFrame)
                menuBtn:SetPoint("TOPLEFT", 2, -2 - (i - 1) * 22)
                menuBtn:SetPoint("TOPRIGHT", -2, -2 - (i - 1) * 22)
                menuBtn:SetHeight(22)

                menuBtn.Text = menuBtn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                menuBtn.Text:SetPoint("LEFT", 8, 0)
                menuBtn.Text:SetText(opt.value)
                menuBtn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

                menuBtn.Highlight = menuBtn:CreateTexture(nil, "HIGHLIGHT")
                menuBtn.Highlight:SetAllPoints()
                local c = GetThemeColor()
                menuBtn.Highlight:SetColorTexture(c.r, c.g, c.b, 0.3)

                menuBtn:SetScript("OnClick", function()
                    setValue(opt.key)
                    WriteBack()
                    btn.Text:SetText(opt.value)
                    menuFrame:Hide()
                end)

                menuButtons[#menuButtons + 1] = menuBtn
                menuHeight = menuHeight + 22
            end
            menuFrame:SetHeight(menuHeight + 4)

            -- Update displayed text
            local curVal = getValue()
            btn.Text:SetText(newOptions[curVal] or tostring(curVal) or L["Select..."])
        end

        btn:SetScript("OnEnter", function(self)
            self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
        end)
        btn:SetScript("OnLeave", function(self)
            self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        end)

        btn:SetScript("OnClick", function(self)
            if menuFrame:IsShown() then
                menuFrame:Hide()
                S.currentOpenDropdown = nil
            else
                GUI:CloseAllMenus()
                -- Highlight current selection
                local curVal = getValue()
                local curDisplay = options[curVal]
                for _, mb in ipairs(menuButtons) do
                    if mb.Text:GetText() == curDisplay then
                        mb.Text:SetTextColor(GetThemeColor().r, GetThemeColor().g, GetThemeColor().b)
                    else
                        mb.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                    end
                end
                menuFrame:Show()
                S.currentOpenDropdown = menuFrame
            end
        end)

        -- Expose btn for external enable/disable, and the label so the tooltip
        -- attach at the bottom of this factory has a real region to sit on — lbl
        -- is local to THIS builder, so reaching for it out there is a nil global.
        frame.btn = btn
        frame.Label = lbl
        frame:Rebuild(options)
        return frame
    end

    -- Build the three dropdowns (forward-declare wrap/dir so orientation callback can reference them)
    local wrapDD, dirDD
    local orientDD = BuildMiniDropdown(0, L["Orientation"], ORIENT_OPTIONS,
        function() return curOrientation end,
        function(val)
            if val ~= curOrientation then
                -- Map wrap and direction to the new orientation
                curWrap = ORIENTATION_MAP[curWrap] or curWrap
                curDirection = (curDirection == "CENTER") and "CENTER" or (ORIENTATION_MAP[curDirection] or curDirection)
                curOrientation = val
                -- Rebuild dependent dropdowns with new options
                wrapDD:Rebuild(WRAP_OPTIONS[curOrientation])
                dirDD:Rebuild(DIR_OPTIONS[curOrientation])
            end
        end
    )

    wrapDD = BuildMiniDropdown(-50, L["Wrap"], WRAP_OPTIONS[curOrientation],
        function() return curWrap end,
        function(val) curWrap = val end
    )

    -- "Grow" (not "Direction"): the values describe how the row GROWS from the anchor
    -- (toward a side, or outward from center) — clearer than "Direction", which reads
    -- oddly against the "From Center" value.
    dirDD = BuildMiniDropdown(-100, L["Grow"], DIR_OPTIONS[curOrientation],
        function() return curDirection end,
        function(val) curDirection = val end
    )

    -- SetEnabled support for disableOn (disable the actual clickable buttons)
    container.SetEnabled = function(self, enabled)
        local alpha = enabled and 1.0 or 0.4
        self:SetAlpha(alpha)
        orientDD.btn:SetEnabled(enabled)
        wrapDD.btn:SetEnabled(enabled)
        dirDD.btn:SetEnabled(enabled)
    end

    -- Refresh from db (e.g., after profile switch)
    container.refreshContent = function(self)
        curOrientation, curWrap, curDirection = DecomposeGrowth(db[dbKey] or "LEFT_UP")
        orientDD:Rebuild(ORIENT_OPTIONS)
        wrapDD:Rebuild(WRAP_OPTIONS[curOrientation])
        dirDD:Rebuild(DIR_OPTIONS[curOrientation])
    end

    -- Tooltip: shared attach. This widget has no label of its own — it is three
    -- stacked mini dropdowns (Orientation / Wrap / Grow), each built by the local
    -- BuildMiniDropdown rather than CreateDropdown, so none of them carries an
    -- attach either. The top row's label stands in for the group.
    --
    -- ⚠ NOT `lbl`: that name IS in this file, but it is local to
    -- BuildMiniDropdown, so reading it here is a nil global — legal Lua, parses
    -- clean, and would have silently left this control with no tooltip at all.
    GUI:AttachTooltip(container, L["Growth Direction"], orientDD.Label)

    return container
end

-- ============================================================
-- TEXTURE DROPDOWN WITH PREVIEW
-- ============================================================

function GUI:CreateTextureDropdown(parent, label, dbTable, dbKey, callback, customOptions)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 50)

    -- Label
    local lbl = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    -- Add override indicators if dbKey is provided
    if dbKey and type(dbKey) == "string" then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(dbKey)
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(dbKey)
                if dbTable and dbKey then
                    dbTable[dbKey] = globalVal
                end
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(globalVal)
                end
                DF:UpdateAll()
                if callback then callback() end
            end
        end
        AddOverrideIndicators(GUI, container, lbl, dbKey, onReset, 6, nil, dbTable)
    end
    
    -- Button - use relative anchoring so it resizes with container
    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    btn:SetPoint("TOPLEFT", 0, -16)
    btn:SetPoint("TOPRIGHT", 0, -16)
    btn:SetHeight(24)
    CreateElementBackdrop(btn)
    
    -- Texture preview on button
    btn.Preview = btn:CreateTexture(nil, "ARTWORK")
    btn.Preview:SetPoint("LEFT", 4, 0)
    btn.Preview:SetSize(80, 16)
    
    btn.Text = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    btn.Text:SetPoint("LEFT", 90, 0)
    btn.Text:SetPoint("RIGHT", -20, 0)
    btn.Text:SetJustifyH("LEFT")
    btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Arrow indicator
    local arrow = btn:CreateTexture(nil, "OVERLAY")
    arrow:SetPoint("RIGHT", -8, 0)
    arrow:SetSize(12, 12)
    arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
    arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    local function UpdateText()
        if dbTable and dbKey then
            local val = dbTable[dbKey]
            local displayName
            if customOptions then
                -- Use custom options lookup
                displayName = customOptions[val]
            else
                -- Use robust SharedMedia lookup
                displayName = DF:GetTextureNameFromPath(val)
            end
            -- ☠ A MISSING TEXTURE IS NOT "NOTHING SELECTED". This lookup returns nil
            -- both when nothing has been chosen and when the choice points at a file
            -- that is gone — and "Select..." tells the wrong story about the second,
            -- which is the one the user needs to act on. Name the file instead; the
            -- bars have already fallen back to a stock texture by this point, so the
            -- dropdown is the only place the real state is visible.
            -- ☠ ASK ABOUT THE FILE, NOT ABOUT THE NAME. These are independent:
            --   * DISABLING the providing addon drops the SharedMedia registration
            --     but leaves the file on disk — unnamed, still renders perfectly.
            --     Tagging that "(missing)" would send someone reinstalling an addon
            --     to fix something that is not broken.
            --   * REMOVING it takes the file too — and GetTextureNameFromPath STILL
            --     returns something, because its last resort is the filename. So a
            --     resolved name proves nothing about whether the file exists.
            -- An earlier version keyed the tag off `not displayName`, which meant it
            -- only ever fired on the absorb dropdowns (those pass customOptions, which
            -- genuinely returns nil) and never on the plain ones.
            local isMissing = type(val) == "string" and val ~= "" and val ~= "Solid"
                and DF.IsTexturePresent and DF.IsTexturePresent(val) == false
            local shown = displayName
            if not shown and type(val) == "string" and val ~= "" and val ~= "Solid" then
                shown = val:match("([^\\]+)$") or val
            end
            if shown and isMissing then
                btn.Text:SetText(("|cffff7f3f%s|r %s"):format(shown, L["(missing)"]))
            else
                btn.Text:SetText(shown or L["Select..."])
            end
            -- Handle "Solid" special case (not a valid texture path)
            if val == "Solid" then
                btn.Preview:SetColorTexture(0.3, 0.3, 0.3, 1)
            else
                -- ☠ SAFE SETTER, NOT A RAW SetTexture. A raw call on a path whose
                -- file is gone renders WoW's missing-texture GREEN — and because
                -- the db stores resolved paths, that happens to real users whenever
                -- a texture is renamed or its addon removed. The frames already
                -- fall back to the stock texture, so a raw preview showed green
                -- next to bars that rendered fine, which reads as "DF is broken"
                -- rather than "this texture is gone".
                --   Showing the FALLBACK is also the honest preview: it is what the
                -- bar will actually render. The label independently degrades to
                -- "Select..." because GetTextureNameFromPath cannot name a dead
                -- path, so the missing state is still signalled.
                -- Also applies the texture's tiling: a tiled texture must PREVIEW
                -- tiled, even though an 80x16 swatch shows a crop of the tile.
                DF:SafeSetTexture(btn.Preview, val)
                btn.Preview:SetVertexColor(0.3, 0.7, 0.3)  -- Green tint for preview
            end
        end
    end
    
    -- Menu frame with scroll
    local menuFrame = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    menuFrame:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
    menuFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    GUI:RegisterMenu(menuFrame)
    menuFrame:SetClampedToScreen(true)
    CreateElementBackdrop(menuFrame)
    menuFrame:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.98)
    menuFrame:Hide()
    
    -- Search box at top of menu
    local SEARCH_HEIGHT = 26
    local searchBox = CreateFrame("EditBox", nil, menuFrame, "BackdropTemplate")
    searchBox:SetPoint("TOPLEFT", 4, -4)
    searchBox:SetPoint("TOPRIGHT", -4, -4)
    searchBox:SetHeight(22)
    searchBox:SetAutoFocus(false)
    searchBox:SetFontObject(DFFontHighlightSmall)
    searchBox:SetTextInsets(24, 8, 0, 0)
    CreateElementBackdrop(searchBox)
    searchBox:SetBackdropColor(0.1, 0.1, 0.1, 1)
    
    -- Search icon
    local searchIcon = searchBox:CreateTexture(nil, "OVERLAY")
    searchIcon:SetPoint("LEFT", 6, 0)
    searchIcon:SetSize(12, 12)
    searchIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\search")
    searchIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    -- Placeholder text
    local placeholder = searchBox:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    placeholder:SetPoint("LEFT", 24, 0)
    placeholder:SetText(L["Search textures..."])
    placeholder:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.6)
    
    searchBox:SetScript("OnEditFocusGained", function() placeholder:Hide() end)
    searchBox:SetScript("OnEditFocusLost", function() 
        if searchBox:GetText() == "" then placeholder:Show() end
    end)
    
    -- Clear tracking when hidden
    menuFrame:SetScript("OnHide", function()
        if S.currentOpenDropdown == menuFrame then
            S.currentOpenDropdown = nil
        end
        searchBox:SetText("")
        searchBox:ClearFocus()
        placeholder:Show()
    end)
    
    -- Scroll frame - positioned below search box
    local scrollFrame = CreateFrame("ScrollFrame", nil, menuFrame, "ScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 2, -(SEARCH_HEIGHT + 4))
    scrollFrame:SetPoint("BOTTOMRIGHT", -20, 2)
    
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(234)  -- Match button width for texture dropdown
    scrollFrame:SetScrollChild(scrollChild)
    
    StyleScrollBar(scrollFrame)

    local menuButtons = {}
    local ITEM_HEIGHT = 28
    local MAX_VISIBLE = 8
    
    -- Function to rebuild menu with current textures
    local function RebuildMenu(filterText)
        -- Clear old buttons
        for _, menuBtn in ipairs(menuButtons) do
            menuBtn:Hide()
            menuBtn:SetParent(nil)
        end
        wipe(menuButtons)
        
        -- Get fresh texture list (use custom options if provided)
        local options = customOptions or DF:GetTextureList()
        local sortedOptions = {}
        
        -- Apply filter if provided
        filterText = filterText and filterText:lower() or ""
        
        for k, v in pairs(options) do
            if filterText == "" or v:lower():find(filterText, 1, true) then
                table.insert(sortedOptions, {key = k, value = v})
            end
        end
        table.sort(sortedOptions, function(a, b) return a.value < b.value end)
        
        -- Resize menu and scroll child
        local menuHeight = math.min(#sortedOptions, MAX_VISIBLE) * ITEM_HEIGHT + SEARCH_HEIGHT + 8
        menuFrame:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
        menuFrame:SetHeight(menuHeight)
        scrollChild:SetHeight(#sortedOptions * ITEM_HEIGHT)
        
        -- Hide scrollbar if not needed
        if scrollBar then
            if #sortedOptions <= MAX_VISIBLE then
                scrollBar:Hide()
            else
                scrollBar:Show()
            end
        end
        
        -- Create new buttons
        for i, opt in ipairs(sortedOptions) do
            local menuBtn = CreateFrame("Button", nil, scrollChild)
            menuBtn:SetSize(234, ITEM_HEIGHT)
            menuBtn:SetPoint("TOPLEFT", 0, -(i - 1) * ITEM_HEIGHT)
            
            -- Texture preview
            menuBtn.Preview = menuBtn:CreateTexture(nil, "ARTWORK")
            menuBtn.Preview:SetPoint("LEFT", 4, 0)
            menuBtn.Preview:SetSize(80, 18)
            -- Handle "Solid" special case
            if opt.key == "Solid" then
                menuBtn.Preview:SetColorTexture(0.3, 0.3, 0.3, 1)
            else
                -- Safe setter + tiling, for the reasons on the button swatch above.
                -- Menu rows are built from REGISTERED media so a dead path is far
                -- less likely here, but a stale SharedTextures fallback entry can
                -- still produce one and it costs nothing to be consistent.
                DF:SafeSetTexture(menuBtn.Preview, opt.key)
                menuBtn.Preview:SetVertexColor(0.3, 0.7, 0.3)  -- Green tint for preview
            end
            
            menuBtn.Text = menuBtn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            menuBtn.Text:SetPoint("LEFT", 90, 0)
            menuBtn.Text:SetText(opt.value)
            
            -- Highlight selected item
            if dbTable[dbKey] == opt.key then
                menuBtn.Text:SetTextColor(GetThemeColor().r, GetThemeColor().g, GetThemeColor().b)
            else
                menuBtn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            end
            
            menuBtn.Highlight = menuBtn:CreateTexture(nil, "HIGHLIGHT")
            menuBtn.Highlight:SetAllPoints()
            local c = GetThemeColor()
            menuBtn.Highlight:SetColorTexture(c.r, c.g, c.b, 0.3)
            
            menuBtn:SetScript("OnClick", function()
                -- The host bracket (GUI.lua's interceptWrite / onSettingWritten),
                -- replacing the hand-written copy of it that stood here: the
                -- redirect gate and the override record are the same two rules,
                -- and going through the hooks is what makes the write visible to
                -- everything else wired to them -- the undo engine among them.
                if GUI:Call("interceptWrite", dbTable, dbKey, opt.key) then
                    UpdateText()
                    menuFrame:Hide()
                    if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators(opt.key) end
                    return
                end
                dbTable[dbKey] = opt.key
                -- ...carrying `callback`, this dropdown's own commit, so an undo
                -- of the pick replays the apply and not only the write.
                GUI:Call("onSettingWritten", dbTable, dbKey, opt.key, label, callback)
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(opt.key)
                end
                UpdateText()
                menuFrame:Hide()
                DF:UpdateAll()
                if callback then callback() end
            end)

            table.insert(menuButtons, menuBtn)
        end
    end
    
    -- Search box text changed handler
    searchBox:SetScript("OnTextChanged", function(self)
        RebuildMenu(self:GetText())
    end)
    
    -- Allow escape to close
    searchBox:SetScript("OnEscapePressed", function()
        menuFrame:Hide()
    end)
    
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    end)
    
    btn:SetScript("OnClick", function(self)
        if menuFrame:IsShown() then
            menuFrame:Hide()
            S.currentOpenDropdown = nil
        else
            -- Close any other open dropdown first
            GUI:CloseAllMenus()
            -- Rebuild menu with current SharedMedia textures
            RebuildMenu()
            menuFrame:Show()
            S.currentOpenDropdown = menuFrame
            -- Focus search box
            searchBox:SetFocus()
        end
    end)

    btn:SetScript("OnShow", UpdateText)
    UpdateText()

    -- ☠☠ ONE DEFERRED RE-APPLY, AND IT IS BUG #1071 AGAIN. ApplyTextureTiling's own note
    -- records the mechanism: on a FRESH SESSION the file may not be resident when
    -- SetTexture runs, and the region goes on rendering the PREVIOUS texture -- "the
    -- texture preview can bug out and not faithfully represent the selected texture,
    -- most noticeably after a /reload or start of session" (Renegade, 2026-08-22).
    -- #1071 fixed the half that was ours, a second SetTexture racing the first. This is
    -- the half that is the client's, and no care at call time avoids it: the file is
    -- simply not there yet.
    --
    -- ★ WHY THE OnShow HOOK ABOVE DOES NOT ALREADY COVER IT -- and why it is section-
    -- dependent, which is the part of the report that points at the cause. A dropdown
    -- inside a COLLAPSED section is hidden at build and gets a real OnShow when the user
    -- expands it, which re-runs this and repairs the swatch. One that is already visible
    -- when the page is built gets the build-time call and NOTHING AFTER IT: OnShow never
    -- fires for a frame that was never hidden. Hence "does not happen in the Heal Preview
    -- section" while both Absorbs dropdowns are wrong, and hence closing and reopening
    -- settings fixing all of them -- a rebuild gives every one a fresh pass.
    --
    -- ⚠ ONE-SHOT, at build only, not a ticker. The first SetTexture has kicked the load
    -- off, so a single retry on the next frame is enough, and a swatch is not worth
    -- polling for. Re-runs the whole of UpdateText rather than just the setter, so the
    -- label, the (missing) tag and the tint stay derived in one place.
    -- ⚠ TEXTURE DROPDOWNS ONLY. The font and sound dropdowns below carry the same
    -- OnShow/UpdateText shape, deliberately untouched: neither previews a FILE-BACKED
    -- TEXTURE, so neither can show a stale one.
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            -- The panel can be torn down between build and this frame.
            if btn and btn.Preview then UpdateText() end
        end)
    end

    -- Refresh override indicators on show
    container:SetScript("OnShow", function()
        UpdateText()
        if container.UpdateOverrideIndicators then
            container:UpdateOverrideIndicators(dbTable and dbTable[dbKey])
        end
    end)
    
    container.SetEnabled = function(self, enabled)
        -- Dim the whole widget so its preview/value (texture swatch, font preview,
        -- selected text) greys with the label rather than staying full-bright.
        self:SetAlpha(enabled and 1 or 0.4)
        btn:SetEnabled(enabled)
        if enabled then
            lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            lbl:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            btn.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
    end
    
    -- SEARCH: Register this setting (use current texture list)
    if DF.Search and dbKey and type(dbKey) == "string" then
        local currentOptions = customOptions or DF:GetTextureList()
        container.searchEntry = DF.Search:RegisterDropdown(label, dbKey, currentOptions, nil, callback)
        DF.Search:LinkSourceWidget(container)
    end

    -- Tooltip: shared attach on the LABEL only. Hand-rolled preview dropdown, so
    -- it never picked up CreateDropdown's tooltip support.
    GUI:AttachTooltip(container, label or L["Texture"], lbl)

    return container
end

-- ============================================================
-- FONT DROPDOWN WITH PREVIEW
-- ============================================================

-- inheritKey (optional): when dbTable[dbKey] is nil (no per-element override),
-- the dropdown DISPLAYS dbTable[inheritKey] instead so it shows the inherited
-- (e.g. global) font. Selecting a font still writes dbKey (the override).
function GUI:CreateFontDropdown(parent, label, dbTable, dbKey, callback, inheritKey)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 50)

    -- Label
    local lbl = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    -- Add override indicators if dbKey is provided
    if dbKey and type(dbKey) == "string" then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(dbKey)
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(dbKey)
                if dbTable and dbKey then
                    dbTable[dbKey] = globalVal
                end
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(globalVal)
                end
                DF:UpdateAll()
                if callback then callback() end
            end
        end
        AddOverrideIndicators(GUI, container, lbl, dbKey, onReset, 6, nil, dbTable)
    end
    
    -- Button - use relative anchoring so it resizes with container
    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    btn:SetPoint("TOPLEFT", 0, -16)
    btn:SetPoint("TOPRIGHT", 0, -16)
    btn:SetHeight(24)
    CreateElementBackdrop(btn)
    
    btn.Text = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    btn.Text:SetPoint("LEFT", 8, 0)
    btn.Text:SetPoint("RIGHT", -20, 0)
    btn.Text:SetJustifyH("LEFT")
    btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Arrow indicator
    local arrow = btn:CreateTexture(nil, "OVERLAY")
    arrow:SetPoint("RIGHT", -8, 0)
    arrow:SetSize(12, 12)
    arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
    arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    local function UpdateText()
        if dbTable and dbKey then
            local val = dbTable[dbKey] or (inheritKey and dbTable[inheritKey])
            -- Get font display name (handles both names and legacy paths)
            local displayName = DF:GetFontNameFromPath(val)
            btn.Text:SetText(displayName or L["Select..."])
            -- Try to set the button text to the selected font for preview
            local fontPath = DF:GetFontPath(val)
            if fontPath then
                local success = pcall(function()
                    btn.Text:SetFont(fontPath, 12, "")
                end)
                if not success then
                    btn.Text:SetFontObject(DFFontHighlightSmall)
                end
            end
        end
    end
    
    -- Menu frame with scroll
    local menuFrame = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    menuFrame:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
    menuFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    GUI:RegisterMenu(menuFrame)
    menuFrame:SetClampedToScreen(true)
    CreateElementBackdrop(menuFrame)
    menuFrame:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.98)
    menuFrame:Hide()
    
    -- Search box at top of menu
    local SEARCH_HEIGHT = 26
    local searchBox = CreateFrame("EditBox", nil, menuFrame, "BackdropTemplate")
    searchBox:SetPoint("TOPLEFT", 4, -4)
    searchBox:SetPoint("TOPRIGHT", -4, -4)
    searchBox:SetHeight(22)
    searchBox:SetAutoFocus(false)
    searchBox:SetFontObject(DFFontHighlightSmall)
    searchBox:SetTextInsets(24, 8, 0, 0)
    CreateElementBackdrop(searchBox)
    searchBox:SetBackdropColor(0.1, 0.1, 0.1, 1)
    
    -- Search icon
    local searchIcon = searchBox:CreateTexture(nil, "OVERLAY")
    searchIcon:SetPoint("LEFT", 6, 0)
    searchIcon:SetSize(12, 12)
    searchIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\search")
    searchIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    -- Placeholder text
    local placeholder = searchBox:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    placeholder:SetPoint("LEFT", 24, 0)
    placeholder:SetText(L["Search fonts..."])
    placeholder:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.6)
    
    searchBox:SetScript("OnEditFocusGained", function() placeholder:Hide() end)
    searchBox:SetScript("OnEditFocusLost", function() 
        if searchBox:GetText() == "" then placeholder:Show() end
    end)
    
    -- Clear tracking when hidden
    menuFrame:SetScript("OnHide", function()
        if S.currentOpenDropdown == menuFrame then
            S.currentOpenDropdown = nil
        end
        searchBox:SetText("")
        searchBox:ClearFocus()
        placeholder:Show()
    end)
    
    -- Scroll frame - positioned below search box
    local scrollFrame = CreateFrame("ScrollFrame", nil, menuFrame, "ScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 2, -(SEARCH_HEIGHT + 4))
    scrollFrame:SetPoint("BOTTOMRIGHT", -20, 2)
    
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(234)  -- Match button width for font dropdown
    scrollFrame:SetScrollChild(scrollChild)
    
    StyleScrollBar(scrollFrame)

    local menuButtons = {}
    local ITEM_HEIGHT = 24
    local MAX_VISIBLE = 10

    -- Function to rebuild menu with current fonts
    local function RebuildMenu(filterText)
        -- Clear old buttons
        for _, menuBtn in ipairs(menuButtons) do
            menuBtn:Hide()
            menuBtn:SetParent(nil)
        end
        wipe(menuButtons)
        
        -- Get fresh font list
        local options = DF:GetFontList()
        local sortedOptions = {}
        
        -- Apply filter if provided
        filterText = filterText and filterText:lower() or ""
        
        for k, v in pairs(options) do
            if filterText == "" or v:lower():find(filterText, 1, true) then
                table.insert(sortedOptions, {key = k, value = v})
            end
        end
        table.sort(sortedOptions, function(a, b) return a.value < b.value end)
        
        -- Resize menu and scroll child
        local menuHeight = math.min(#sortedOptions, MAX_VISIBLE) * ITEM_HEIGHT + SEARCH_HEIGHT + 8
        menuFrame:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
        menuFrame:SetHeight(menuHeight)
        scrollChild:SetHeight(#sortedOptions * ITEM_HEIGHT)
        
        -- Hide scrollbar if not needed
        if scrollBar then
            if #sortedOptions <= MAX_VISIBLE then
                scrollBar:Hide()
            else
                scrollBar:Show()
            end
        end
        
        -- Create new buttons
        for i, opt in ipairs(sortedOptions) do
            local menuBtn = CreateFrame("Button", nil, scrollChild)
            menuBtn:SetSize(234, ITEM_HEIGHT)
            menuBtn:SetPoint("TOPLEFT", 0, -(i - 1) * ITEM_HEIGHT)
            
            menuBtn.Text = menuBtn:CreateFontString(nil, "OVERLAY")
            menuBtn.Text:SetPoint("LEFT", 8, 0)
            menuBtn.Text:SetPoint("RIGHT", -8, 0)
            menuBtn.Text:SetJustifyH("LEFT")
            
            -- Set default font first, then try to use the actual font for preview
            menuBtn.Text:SetFontObject(DFFontHighlightSmall)
            
            -- Try to preview in the actual font
            local LSM = DF.GetLSM and DF.GetLSM()
            if LSM then
                local fontPath = LSM:Fetch("font", opt.key)
                if fontPath then
                    pcall(function()
                        menuBtn.Text:SetFont(fontPath, 12, "")
                    end)
                end
            end
            
            menuBtn.Text:SetText(opt.value)
            
            -- Highlight selected item (compare with stored font name)
            local currentValue = dbTable[dbKey]
            local currentName = DF:GetFontNameFromPath(currentValue)
            if currentName == opt.key or currentValue == opt.key then
                menuBtn.Text:SetTextColor(GetThemeColor().r, GetThemeColor().g, GetThemeColor().b)
            else
                menuBtn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            end
            
            menuBtn.Highlight = menuBtn:CreateTexture(nil, "HIGHLIGHT")
            menuBtn.Highlight:SetAllPoints()
            local c = GetThemeColor()
            menuBtn.Highlight:SetColorTexture(c.r, c.g, c.b, 0.3)
            
            menuBtn:SetScript("OnClick", function()
                -- The host bracket, same conversion and same reason as the
                -- texture dropdown above.
                if GUI:Call("interceptWrite", dbTable, dbKey, opt.key) then
                    UpdateText()
                    menuFrame:Hide()
                    if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators(opt.key) end
                    return
                end
                -- Store font NAME in database (not path)
                dbTable[dbKey] = opt.key
                -- ...and the commit callback rides along, same as the texture
                -- dropdown above.
                GUI:Call("onSettingWritten", dbTable, dbKey, opt.key, label, callback)
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(opt.key)
                end
                UpdateText()
                menuFrame:Hide()
                DF:UpdateAll()
                if callback then callback() end
            end)
            
            table.insert(menuButtons, menuBtn)
        end
    end
    
    -- Search box text changed handler
    searchBox:SetScript("OnTextChanged", function(self)
        RebuildMenu(self:GetText())
    end)
    
    -- Allow escape to close
    searchBox:SetScript("OnEscapePressed", function()
        menuFrame:Hide()
    end)
    
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    end)
    
    btn:SetScript("OnClick", function(self)
        if menuFrame:IsShown() then
            menuFrame:Hide()
            S.currentOpenDropdown = nil
        else
            -- Close any other open dropdown first
            GUI:CloseAllMenus()
            -- Rebuild menu with current SharedMedia fonts
            RebuildMenu()
            menuFrame:Show()
            S.currentOpenDropdown = menuFrame
            -- Focus search box
            searchBox:SetFocus()
        end
    end)
    
    btn:SetScript("OnShow", UpdateText)
    UpdateText()

    -- The WHOLE display: the button's caption and its preview font, plus the
    -- override indicators beside the label. UpdateText alone is half of it --
    -- the indicators are what say "an auto layout is overriding this key" -- so
    -- the pair is named once here rather than spelled twice.
    local function RefreshDisplay()
        UpdateText()
        if container.UpdateOverrideIndicators then
            container:UpdateOverrideIndicators(dbTable and dbTable[dbKey])
        end
    end

    -- Refresh override indicators on show
    container:SetScript("OnShow", RefreshDisplay)

    -- ...and under the group-wide value sweep's one name (DandersUI Sections'
    -- RefreshChildValues), for a caller that wrote this key behind the widget's
    -- back: a group Reset, a Hold: Defaults preview, or the undo of either.
    --
    -- ☠ THIS WAS THE ONE CONTROL IN A FONT PANE THAT DID NOT REPAINT. Every
    -- other widget a Font Settings group mounts opts in already -- the size
    -- slider and the outline dropdown through the kit (DandersUI/Widgets.lua),
    -- the shadow tick through GUI:CreateCheckbox, the colour swatch through
    -- GUI:CreateColorPicker -- so a Reset Group left this button alone, still
    -- naming and previewing the previous font, until the panel was closed and
    -- reopened and its OnShow fired. Pinned by test_order_lists.lua.
    container.refreshValue = RefreshDisplay

    container.SetEnabled = function(self, enabled)
        -- Dim the whole widget so its preview/value (texture swatch, font preview,
        -- selected text) greys with the label rather than staying full-bright.
        self:SetAlpha(enabled and 1 or 0.4)
        btn:SetEnabled(enabled)
        if enabled then
            lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            lbl:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            btn.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
    end
    
    -- SEARCH: Register this setting (use current font list)
    if DF.Search and dbKey and type(dbKey) == "string" then
        container.searchEntry = DF.Search:RegisterDropdown(label, dbKey, DF:GetFontList(), nil, callback)
        DF.Search:LinkSourceWidget(container)
    end

    -- Tooltip: shared attach on the LABEL only. Hand-rolled preview dropdown, so
    -- it never picked up CreateDropdown's tooltip support.
    GUI:AttachTooltip(container, label or L["Font"], lbl)

    return container
end

-- ============================================================
-- SOUND DROPDOWN (Searchable, scrollable — mirrors font dropdown)
-- ============================================================

function GUI:CreateSoundDropdown(parent, label, dbTable, dbKey, callback)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 50)

    -- Label
    local lbl = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    -- Button
    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    btn:SetPoint("TOPLEFT", 0, -16)
    btn:SetPoint("TOPRIGHT", 0, -16)
    btn:SetHeight(24)
    CreateElementBackdrop(btn)

    btn.Text = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    btn.Text:SetPoint("LEFT", 8, 0)
    btn.Text:SetPoint("RIGHT", -20, 0)
    btn.Text:SetJustifyH("LEFT")
    btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    -- Arrow indicator
    local arrow = btn:CreateTexture(nil, "OVERLAY")
    arrow:SetPoint("RIGHT", -8, 0)
    arrow:SetSize(12, 12)
    arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
    arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    local function UpdateText()
        if dbTable and dbKey then
            local val = dbTable[dbKey]
            btn.Text:SetText(val or L["Select..."])
        end
    end

    -- Menu frame with scroll
    local menuFrame = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    menuFrame:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
    menuFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    GUI:RegisterMenu(menuFrame)
    menuFrame:SetClampedToScreen(true)
    CreateElementBackdrop(menuFrame)
    menuFrame:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.98)
    menuFrame:Hide()

    -- Search box at top of menu
    local SEARCH_HEIGHT = 26
    local searchBox = CreateFrame("EditBox", nil, menuFrame, "BackdropTemplate")
    searchBox:SetPoint("TOPLEFT", 4, -4)
    searchBox:SetPoint("TOPRIGHT", -4, -4)
    searchBox:SetHeight(22)
    searchBox:SetAutoFocus(false)
    searchBox:SetFontObject(DFFontHighlightSmall)
    searchBox:SetTextInsets(24, 8, 0, 0)
    CreateElementBackdrop(searchBox)
    searchBox:SetBackdropColor(0.1, 0.1, 0.1, 1)

    -- Search icon
    local searchIcon = searchBox:CreateTexture(nil, "OVERLAY")
    searchIcon:SetPoint("LEFT", 6, 0)
    searchIcon:SetSize(12, 12)
    searchIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\search")
    searchIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    -- Placeholder text
    local searchPlaceholder = searchBox:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    searchPlaceholder:SetPoint("LEFT", 24, 0)
    searchPlaceholder:SetText(L["Search sounds..."])
    searchPlaceholder:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.6)

    searchBox:SetScript("OnEditFocusGained", function() searchPlaceholder:Hide() end)
    searchBox:SetScript("OnEditFocusLost", function()
        if searchBox:GetText() == "" then searchPlaceholder:Show() end
    end)

    menuFrame:SetScript("OnHide", function()
        if S.currentOpenDropdown == menuFrame then
            S.currentOpenDropdown = nil
        end
        searchBox:SetText("")
        searchBox:ClearFocus()
        searchPlaceholder:Show()
    end)

    -- Scroll frame
    local scrollFrame = CreateFrame("ScrollFrame", nil, menuFrame, "ScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 2, -(SEARCH_HEIGHT + 4))
    scrollFrame:SetPoint("BOTTOMRIGHT", -20, 2)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(234)
    scrollFrame:SetScrollChild(scrollChild)

    StyleScrollBar(scrollFrame)

    local menuButtons = {}
    local ITEM_HEIGHT = 22
    local MAX_VISIBLE = 10

    local function RebuildMenu(filterText)
        for _, menuBtn in ipairs(menuButtons) do
            menuBtn:Hide()
            menuBtn:SetParent(nil)
        end
        wipe(menuButtons)

        local options = DF:GetSoundList()
        local sortedOptions = {}

        filterText = filterText and filterText:lower() or ""

        for k, v in pairs(options) do
            if filterText == "" or v:lower():find(filterText, 1, true) then
                table.insert(sortedOptions, {key = k, value = v})
            end
        end
        table.sort(sortedOptions, function(a, b) return a.value < b.value end)

        local menuHeight = math.min(#sortedOptions, MAX_VISIBLE) * ITEM_HEIGHT + SEARCH_HEIGHT + 8
        menuFrame:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
        menuFrame:SetHeight(menuHeight)
        scrollChild:SetHeight(#sortedOptions * ITEM_HEIGHT)

        if scrollBar then
            if #sortedOptions <= MAX_VISIBLE then
                scrollBar:Hide()
            else
                scrollBar:Show()
            end
        end

        for i, opt in ipairs(sortedOptions) do
            local menuBtn = CreateFrame("Button", nil, scrollChild)
            menuBtn:SetSize(234, ITEM_HEIGHT)
            menuBtn:SetPoint("TOPLEFT", 0, -(i - 1) * ITEM_HEIGHT)

            menuBtn.Text = menuBtn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            menuBtn.Text:SetPoint("LEFT", 8, 0)
            menuBtn.Text:SetPoint("RIGHT", -8, 0)
            menuBtn.Text:SetJustifyH("LEFT")
            menuBtn.Text:SetText(opt.value)

            -- Highlight selected item
            local currentValue = dbTable[dbKey]
            if currentValue == opt.key then
                menuBtn.Text:SetTextColor(GetThemeColor().r, GetThemeColor().g, GetThemeColor().b)
            else
                menuBtn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            end

            menuBtn.Highlight = menuBtn:CreateTexture(nil, "HIGHLIGHT")
            menuBtn.Highlight:SetAllPoints()
            local c = GetThemeColor()
            menuBtn.Highlight:SetColorTexture(c.r, c.g, c.b, 0.3)

            menuBtn:SetScript("OnClick", function()
                dbTable[dbKey] = opt.key
                UpdateText()
                menuFrame:Hide()
                DF:UpdateAll()
                if callback then callback() end
            end)

            table.insert(menuButtons, menuBtn)
        end
    end

    searchBox:SetScript("OnTextChanged", function(self)
        RebuildMenu(self:GetText())
    end)

    searchBox:SetScript("OnEscapePressed", function()
        menuFrame:Hide()
    end)

    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    end)

    btn:SetScript("OnClick", function(self)
        if menuFrame:IsShown() then
            menuFrame:Hide()
            S.currentOpenDropdown = nil
        else
            GUI:CloseAllMenus()
            RebuildMenu()
            menuFrame:Show()
            S.currentOpenDropdown = menuFrame
            searchBox:SetFocus()
        end
    end)

    btn:SetScript("OnShow", UpdateText)
    UpdateText()

    return container
end

-- ============================================================
-- ROLE ORDER LIST (Drag-Drop)
-- ============================================================

function GUI:CreateRoleOrderList(parent, dbTable, dbKey, callback, separateMeleeRangedKey)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(220, 130)
    
    -- Role display info with colors
    local ROLE_INFO = {
        TANK = { name = L["Tank"], color = {0.53, 0.77, 0.84}, coords = {0, 19/64, 22/64, 41/64} },
        HEALER = { name = L["Healer"], color = {0.25, 0.78, 0.25}, coords = {20/64, 39/64, 1/64, 20/64} },
        MELEE = { name = L["Melee DPS"], color = {0.82, 0.65, 0.47}, coords = {20/64, 39/64, 22/64, 41/64} },
        RANGED = { name = L["Ranged DPS"], color = {1.0, 0.49, 0.04}, coords = {20/64, 39/64, 22/64, 41/64} },
        DAMAGER = { name = L["DPS"], color = {0.82, 0.65, 0.47}, coords = {20/64, 39/64, 22/64, 41/64} },
    }
    
    local roleItems = {}
    -- Snapped stride + gap: a raw 30-unit stride is 42.19 device px, so every
    -- row would sit on a different sub-pixel phase and the error would
    -- ACCUMULATE down the list (row 3 off by twice row 2). Rows are anchored
    -- by two corners, so nothing corrects them after the fact.
    local ITEM_HEIGHT = SnapLen(parent, 30) or 30
    local ITEM_GAP = SnapLen(parent, 2) or 2
    local draggingItem = nil
    local dragOffsetY = 0
    
    -- Check if we should show separate melee/ranged
    local function IsSeparateMeleeRanged()
        if separateMeleeRangedKey and dbTable then
            return dbTable[separateMeleeRangedKey]
        end
        return true
    end
    
    -- Get the roles to display
    local function GetDisplayRoles()
        if IsSeparateMeleeRanged() then
            return { "TANK", "HEALER", "MELEE", "RANGED" }
        else
            return { "TANK", "HEALER", "DAMAGER" }
        end
    end
    
    -- Get current order from db or use default
    local function GetCurrentOrder()
        local displayRoles = GetDisplayRoles()
        if dbTable and dbKey and dbTable[dbKey] then
            local order = {}
            for _, role in ipairs(dbTable[dbKey]) do
                for _, displayRole in ipairs(displayRoles) do
                    if role == displayRole or 
                       (displayRole == "DAMAGER" and (role == "MELEE" or role == "RANGED" or role == "DAMAGER")) then
                        local found = false
                        for _, existing in ipairs(order) do
                            if existing == displayRole then found = true break end
                        end
                        if not found then
                            table.insert(order, displayRole)
                        end
                        break
                    end
                end
            end
            for _, displayRole in ipairs(displayRoles) do
                local found = false
                for _, existing in ipairs(order) do
                    if existing == displayRole then found = true break end
                end
                if not found then
                    table.insert(order, displayRole)
                end
            end
            return order
        end
        return displayRoles
    end
    
    -- Save order to db
    local function SaveOrder(newOrder)
        if dbTable and dbKey then
            local saveOrder = {}
            for _, role in ipairs(newOrder) do
                if role == "DAMAGER" then
                    table.insert(saveOrder, "MELEE")
                    table.insert(saveOrder, "RANGED")
                else
                    table.insert(saveOrder, role)
                end
            end
            dbTable[dbKey] = saveOrder
            -- Track override when editing a profile
            if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and dbKey then
                local copy = {}
                for i, v in ipairs(saveOrder) do copy[i] = v end
                DF.AutoProfilesUI:SetProfileSetting(dbKey, copy)
            end
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(saveOrder)
            end
            if callback then callback() end
        end
    end
    
    -- Get index from Y position
    local function GetIndexFromY(y)
        local containerTop = container:GetTop()
        if not containerTop then return 1 end
        local relativeY = containerTop - y
        local index = math.floor(relativeY / ITEM_HEIGHT) + 1
        local order = GetCurrentOrder()
        return math.max(1, math.min(index, #order))
    end
    
    -- Update visual positions
    local function UpdateItemPositions()
        local order = GetCurrentOrder()
        local numRoles = #order
        
        container:SetHeight(numRoles * ITEM_HEIGHT + (SnapLen(container, 5) or 5))
        
        for _, item in pairs(roleItems) do
            item:Hide()
        end
        
        for i, role in ipairs(order) do
            local item = roleItems[role]
            if item then
                item:Show()
                item.posIndex = i
                item.numText:SetText(i .. ".")
                if item ~= draggingItem then
                    -- Anchored to BOTH sides: the container is created at a placeholder
                    -- width and only stretched to its real one by the settings group's
                    -- LayoutChildren, so a width captured here would be stale. Deriving it
                    -- from the anchors keeps the rows correct at every layout.
                    item:ClearAllPoints()
                    item:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((i - 1) * ITEM_HEIGHT))
                    item:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -((i - 1) * ITEM_HEIGHT))
                end
            end
        end
    end
    
    -- Create grip texture (3 horizontal lines)
    local function CreateGripTexture(parentFrame)
        local grip = CreateFrame("Frame", nil, parentFrame)
        grip:SetSize(12, 16)
        
        local icon = grip:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints(grip)
        icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\reorder")
        icon:SetVertexColor(0.5, 0.5, 0.5, 1)
        grip.icon = icon
        
        grip.SetGripColor = function(self, r, g, b)
            self.icon:SetVertexColor(r, g, b, 1)
        end
        
        return grip
    end
    
    -- Create a single role item
    local function CreateRoleItem(role)
        local info = ROLE_INFO[role]
        if not info then return nil end
        
        local item = CreateFrame("Frame", nil, container, "BackdropTemplate")
        item:SetHeight(ITEM_HEIGHT - ITEM_GAP)
        item:EnableMouse(true)
        CreateElementBackdrop(item, {
            bgColor     = { 0.12, 0.12, 0.12, 0.9 },
            borderColor = { 0.3, 0.3, 0.3, 1 },
        })
        
        -- Grip texture
        local grip = CreateGripTexture(item)
        grip:SetPoint("LEFT", 6, 0)
        item.grip = grip
        
        -- Priority number
        local numText = item:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
        numText:SetPoint("LEFT", grip, "RIGHT", 6, 0)
        numText:SetWidth(18)
        numText:SetJustifyH("LEFT")
        item.numText = numText
        
        -- Role icon
        local icon = item:CreateTexture(nil, "ARTWORK")
        icon:SetSize(16, 16)
        icon:SetPoint("LEFT", numText, "RIGHT", 2, 0)
        icon:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES")
        icon:SetTexCoord(unpack(info.coords))
        item.icon = icon
        
        -- Role name with color
        local text = item:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
        text:SetText(info.name)
        text:SetTextColor(info.color[1], info.color[2], info.color[3])
        item.text = text
        
        item.role = role
        item.posIndex = 1
        
        -- Mouse handlers for dragging
        item:SetScript("OnMouseDown", function(self, button)
            if button == "LeftButton" then
                draggingItem = self
                local cursorY = select(2, GUI:CursorPos(self))
                local itemTop = self:GetTop()
                dragOffsetY = itemTop - cursorY
                
                local tc = GetThemeColor()
                self:SetBackdropColor(tc.r * 0.6, tc.g * 0.6, tc.b * 0.6, 0.9)
                self:SetBackdropBorderColor(tc.r, tc.g, tc.b, 1)
                self:SetFrameLevel(container:GetFrameLevel() + 10)
                self.grip:SetGripColor(1, 1, 1)
            end
        end)
        
        item:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" and draggingItem == self then
                local cursorY = select(2, GUI:CursorPos(self))
                local dropIndex = GetIndexFromY(cursorY)
                
                local order = GetCurrentOrder()
                local currentIdx = self.posIndex
                
                if currentIdx ~= dropIndex then
                    local draggedRole = self.role
                    table.remove(order, currentIdx)
                    table.insert(order, dropIndex, draggedRole)
                    SaveOrder(order)
                end
                
                self:SetBackdropColor(0.12, 0.12, 0.12, 0.9)
                self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                self:SetFrameLevel(container:GetFrameLevel() + 1)
                self.grip:SetGripColor(0.5, 0.5, 0.5)
                
                draggingItem = nil
                UpdateItemPositions()
            end
        end)
        
        item:SetScript("OnUpdate", function(self)
            if draggingItem ~= self then return end
            
            local cursorY = select(2, GUI:CursorPos(self))
            local containerTop = container:GetTop()
            local containerBottom = container:GetBottom()
            
            if not containerTop or not containerBottom then return end
            
            local targetY = cursorY + dragOffsetY
            local offsetFromTop = containerTop - targetY
            
            local maxOffset = (containerTop - containerBottom) - ITEM_HEIGHT + 5
            offsetFromTop = math.max(0, math.min(offsetFromTop, maxOffset))
            
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -offsetFromTop)
            self:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -offsetFromTop)
            
            -- Update other items based on where this would drop
            local dropIndex = GetIndexFromY(cursorY)
            local order = GetCurrentOrder()
            
            local tempOrder = {}
            for i, r in ipairs(order) do
                if roleItems[r] ~= self then
                    table.insert(tempOrder, r)
                end
            end
            table.insert(tempOrder, dropIndex, self.role)
            
            for i, r in ipairs(tempOrder) do
                local otherItem = roleItems[r]
                if otherItem and otherItem ~= self then
                    otherItem:ClearAllPoints()
                    otherItem:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((i - 1) * ITEM_HEIGHT))
                    otherItem:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -((i - 1) * ITEM_HEIGHT))
                    otherItem.numText:SetText(i .. ".")
                end
            end
        end)
        
        -- Hover effects
        item:SetScript("OnEnter", function(self)
            if not draggingItem then
                self:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
                self.grip:SetGripColor(0.8, 0.8, 0.8)
            end
        end)
        
        item:SetScript("OnLeave", function(self)
            if draggingItem ~= self then
                self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                self.grip:SetGripColor(0.5, 0.5, 0.5)
            end
        end)
        
        return item
    end
    
    -- Create all role items
    for _, role in ipairs({"TANK", "HEALER", "MELEE", "RANGED", "DAMAGER"}) do
        roleItems[role] = CreateRoleItem(role)
    end
    
    -- Initial layout
    UpdateItemPositions()
    
    -- Refresh function
    container.Refresh = function()
        UpdateItemPositions()
    end
    -- ...and under the group-wide value sweep's one name (DandersUI Sections'
    -- RefreshChildValues), for a caller that wrote the key behind this widget's
    -- back -- a group Reset, a press-and-hold preview, or the undo of one. Same
    -- alias CreateGroupOrderList carries, and for the same reason: the Sorting
    -- page's Role Priority row wires those verbs, and without it the sweep
    -- repaints every widget in an open pane EXCEPT this list.
    container.refreshValue = container.Refresh

    -- Override indicators for profile editing
    if dbKey and type(dbKey) == "string" and not (dbTable and rawget(dbTable, "_skipOverrideIndicators")) then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(dbKey)
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(dbKey)
                if dbTable and type(globalVal) == "table" then
                    local copy = {}
                    for i, v in ipairs(globalVal) do copy[i] = v end
                    dbTable[dbKey] = copy
                end
                UpdateItemPositions()
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(dbTable[dbKey])
                end
                if callback then callback() end
            end
        end
        AddOrderListOverrideIndicators(GUI, container, dbKey, onReset, dbTable)

        container:SetScript("OnShow", function()
            UpdateItemPositions()
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(dbTable and dbTable[dbKey])
            end
        end)
    end

    return container
end

-- ============================================================
-- CLASS ORDER LIST (Drag-Drop) - For class sorting within roles
-- ============================================================

function GUI:CreateClassOrderList(parent, dbTable, dbKey, callback)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(220, 340)  -- Taller to fit all 13 classes
    
    -- Class display info with colors (using Blizzard class colors)
    local CLASS_INFO = {
        DEATHKNIGHT = { name = L["Death Knight"], color = {0.77, 0.12, 0.23} },
        DEMONHUNTER = { name = L["Demon Hunter"], color = {0.64, 0.19, 0.79} },
        DRUID = { name = L["Druid"], color = {1.0, 0.49, 0.04} },
        EVOKER = { name = L["Evoker"], color = {0.20, 0.58, 0.50} },
        HUNTER = { name = L["Hunter"], color = {0.67, 0.83, 0.45} },
        MAGE = { name = L["Mage"], color = {0.25, 0.78, 0.92} },
        MONK = { name = L["Monk"], color = {0.0, 1.0, 0.59} },
        PALADIN = { name = L["Paladin"], color = {0.96, 0.55, 0.73} },
        PRIEST = { name = L["Priest"], color = {1.0, 1.0, 1.0} },
        ROGUE = { name = L["Rogue"], color = {1.0, 0.96, 0.41} },
        SHAMAN = { name = L["Shaman"], color = {0.0, 0.44, 0.87} },
        WARLOCK = { name = L["Warlock"], color = {0.53, 0.53, 0.93} },
        WARRIOR = { name = L["Warrior"], color = {0.78, 0.61, 0.43} },
    }
    
    local ALL_CLASSES = {
        "DEATHKNIGHT", "DEMONHUNTER", "DRUID", "EVOKER", "HUNTER",
        "MAGE", "MONK", "PALADIN", "PRIEST", "ROGUE",
        "SHAMAN", "WARLOCK", "WARRIOR"
    }
    
    local classItems = {}
    -- Snapped; see CreateRoleOrderList.
    local ITEM_HEIGHT = SnapLen(parent, 24) or 24   -- smaller, to fit all classes
    local ITEM_GAP = SnapLen(parent, 2) or 2
    local draggingItem = nil
    local dragOffsetY = 0
    
    -- Get current order from db or use default
    local function GetCurrentOrder()
        if dbTable and dbKey and dbTable[dbKey] then
            -- Ensure all classes are present
            local order = {}
            local seen = {}
            for _, class in ipairs(dbTable[dbKey]) do
                if CLASS_INFO[class] and not seen[class] then
                    table.insert(order, class)
                    seen[class] = true
                end
            end
            -- Add any missing classes
            for _, class in ipairs(ALL_CLASSES) do
                if not seen[class] then
                    table.insert(order, class)
                end
            end
            return order
        end
        return ALL_CLASSES
    end
    
    -- Save order to db
    local function SaveOrder(newOrder)
        if dbTable and dbKey then
            dbTable[dbKey] = newOrder
            -- Track override when editing a profile
            if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and dbKey then
                local copy = {}
                for i, v in ipairs(newOrder) do copy[i] = v end
                DF.AutoProfilesUI:SetProfileSetting(dbKey, copy)
            end
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(newOrder)
            end
            if callback then callback() end
        end
    end
    
    -- Get index from Y position
    local function GetIndexFromY(y)
        local containerTop = container:GetTop()
        if not containerTop then return 1 end
        local relativeY = containerTop - y
        local index = math.floor(relativeY / ITEM_HEIGHT) + 1
        local order = GetCurrentOrder()
        return math.max(1, math.min(index, #order))
    end
    
    -- Update visual positions
    local function UpdateItemPositions()
        local order = GetCurrentOrder()
        local numClasses = #order
        
        container:SetHeight(numClasses * ITEM_HEIGHT + (SnapLen(container, 5) or 5))
        
        for _, item in pairs(classItems) do
            item:Hide()
        end
        
        for i, class in ipairs(order) do
            local item = classItems[class]
            if item then
                item:Show()
                item.posIndex = i
                item.numText:SetText(i .. ".")
                if item ~= draggingItem then
                    -- Anchored to BOTH sides: the container is created at a placeholder
                    -- width and only stretched to its real one by the settings group's
                    -- LayoutChildren, so a width captured here would be stale. Deriving it
                    -- from the anchors keeps the rows correct at every layout.
                    item:ClearAllPoints()
                    item:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((i - 1) * ITEM_HEIGHT))
                    item:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -((i - 1) * ITEM_HEIGHT))
                end
            end
        end
    end
    
    -- Create grip texture (3 horizontal lines)
    local function CreateGripTexture(parentFrame)
        local grip = CreateFrame("Frame", nil, parentFrame)
        grip:SetSize(10, 12)
        
        local icon = grip:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints(grip)
        icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\reorder")
        icon:SetVertexColor(0.5, 0.5, 0.5, 1)
        grip.icon = icon
        
        grip.SetGripColor = function(self, r, g, b)
            self.icon:SetVertexColor(r, g, b, 1)
        end
        
        return grip
    end
    
    -- Create a single class item
    local function CreateClassItem(class)
        local info = CLASS_INFO[class]
        if not info then return nil end
        
        local item = CreateFrame("Frame", nil, container, "BackdropTemplate")
        item:SetHeight(ITEM_HEIGHT - ITEM_GAP)
        item:EnableMouse(true)
        CreateElementBackdrop(item, {
            bgColor     = { 0.12, 0.12, 0.12, 0.9 },
            borderColor = { 0.3, 0.3, 0.3, 1 },
        })
        
        -- Grip texture
        local grip = CreateGripTexture(item)
        grip:SetPoint("LEFT", 4, 0)
        item.grip = grip
        
        -- Priority number
        local numText = item:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        numText:SetPoint("LEFT", grip, "RIGHT", 4, 0)
        numText:SetWidth(20)
        numText:SetJustifyH("LEFT")
        item.numText = numText
        
        -- Class color bar
        local colorBar = item:CreateTexture(nil, "ARTWORK")
        colorBar:SetSize(3, ITEM_HEIGHT - 6)
        colorBar:SetPoint("LEFT", numText, "RIGHT", 2, 0)
        colorBar:SetColorTexture(info.color[1], info.color[2], info.color[3], 1)
        item.colorBar = colorBar
        
        -- Class name with color
        local text = item:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        text:SetPoint("LEFT", colorBar, "RIGHT", 6, 0)
        text:SetText(info.name)
        text:SetTextColor(info.color[1], info.color[2], info.color[3])
        item.text = text
        
        item.class = class
        item.posIndex = 1
        
        -- Mouse handlers for dragging
        item:SetScript("OnMouseDown", function(self, button)
            if button == "LeftButton" then
                draggingItem = self
                local cursorY = select(2, GUI:CursorPos(self))
                local itemTop = self:GetTop()
                dragOffsetY = itemTop - cursorY
                
                local tc = GetThemeColor()
                self:SetBackdropColor(tc.r * 0.6, tc.g * 0.6, tc.b * 0.6, 0.9)
                self:SetBackdropBorderColor(tc.r, tc.g, tc.b, 1)
                self:SetFrameLevel(container:GetFrameLevel() + 10)
                self.grip:SetGripColor(1, 1, 1)
            end
        end)
        
        item:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" and draggingItem == self then
                local cursorY = select(2, GUI:CursorPos(self))
                local dropIndex = GetIndexFromY(cursorY)
                
                local order = GetCurrentOrder()
                local currentIdx = self.posIndex
                
                if currentIdx ~= dropIndex then
                    local draggedClass = self.class
                    table.remove(order, currentIdx)
                    table.insert(order, dropIndex, draggedClass)
                    SaveOrder(order)
                end
                
                self:SetBackdropColor(0.12, 0.12, 0.12, 0.9)
                self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                self:SetFrameLevel(container:GetFrameLevel() + 1)
                self.grip:SetGripColor(0.5, 0.5, 0.5)
                
                draggingItem = nil
                UpdateItemPositions()
            end
        end)
        
        item:SetScript("OnUpdate", function(self)
            if draggingItem ~= self then return end
            
            local cursorY = select(2, GUI:CursorPos(self))
            local containerTop = container:GetTop()
            local containerBottom = container:GetBottom()
            
            if not containerTop or not containerBottom then return end
            
            local targetY = cursorY + dragOffsetY
            local offsetFromTop = containerTop - targetY
            
            local maxOffset = (containerTop - containerBottom) - ITEM_HEIGHT + 5
            offsetFromTop = math.max(0, math.min(offsetFromTop, maxOffset))
            
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -offsetFromTop)
            self:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -offsetFromTop)
            
            -- Update other items based on where this would drop
            local dropIndex = GetIndexFromY(cursorY)
            local order = GetCurrentOrder()
            
            local tempOrder = {}
            for i, c in ipairs(order) do
                if classItems[c] ~= self then
                    table.insert(tempOrder, c)
                end
            end
            table.insert(tempOrder, dropIndex, self.class)
            
            for i, c in ipairs(tempOrder) do
                local otherItem = classItems[c]
                if otherItem and otherItem ~= self then
                    otherItem:ClearAllPoints()
                    otherItem:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((i - 1) * ITEM_HEIGHT))
                    otherItem:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -((i - 1) * ITEM_HEIGHT))
                    otherItem.numText:SetText(i .. ".")
                end
            end
        end)
        
        -- Hover effects
        item:SetScript("OnEnter", function(self)
            if not draggingItem then
                self:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
                self.grip:SetGripColor(0.8, 0.8, 0.8)
            end
        end)
        
        item:SetScript("OnLeave", function(self)
            if draggingItem ~= self then
                self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                self.grip:SetGripColor(0.5, 0.5, 0.5)
            end
        end)
        
        return item
    end
    
    -- Create all class items
    for _, class in ipairs(ALL_CLASSES) do
        classItems[class] = CreateClassItem(class)
    end
    
    -- Initial layout
    UpdateItemPositions()
    
    -- Refresh function
    container.Refresh = function()
        UpdateItemPositions()
    end
    -- ...and under the group-wide value sweep's one name, exactly as the role
    -- and group lists carry it: the Sorting page's Class Priority row wires
    -- Reset Group and Hold: Defaults, and without this alias those write the
    -- key and leave the thirteen rows showing the order the user had before.
    container.refreshValue = container.Refresh

    -- Override indicators for profile editing
    if dbKey and type(dbKey) == "string" and not (dbTable and rawget(dbTable, "_skipOverrideIndicators")) then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(dbKey)
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(dbKey)
                if dbTable and type(globalVal) == "table" then
                    local copy = {}
                    for i, v in ipairs(globalVal) do copy[i] = v end
                    dbTable[dbKey] = copy
                end
                UpdateItemPositions()
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(dbTable[dbKey])
                end
                if callback then callback() end
            end
        end
        AddOrderListOverrideIndicators(GUI, container, dbKey, onReset, dbTable)

        container:SetScript("OnShow", function()
            UpdateItemPositions()
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(dbTable and dbTable[dbKey])
            end
        end)
    end

    return container
end

-- Raid Group Order List (drag-and-drop)
function GUI:CreateGroupOrderList(parent, dbTable, dbKey, callback, playerGroupFirstKey)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(180, 250)
    
    -- Group colors for visual distinction
    local GROUP_COLORS = {
        [1] = {0.95, 0.40, 0.40},  -- Red
        [2] = {0.40, 0.95, 0.40},  -- Green
        [3] = {0.40, 0.60, 0.95},  -- Blue
        [4] = {0.95, 0.95, 0.40},  -- Yellow
        [5] = {0.95, 0.40, 0.95},  -- Magenta
        [6] = {0.40, 0.95, 0.95},  -- Cyan
        [7] = {0.95, 0.70, 0.40},  -- Orange
        [8] = {0.70, 0.40, 0.95},  -- Purple
    }
    
    local groupItems = {}
    -- Snapped; see CreateRoleOrderList.
    local ITEM_HEIGHT = SnapLen(parent, 28) or 28
    local ITEM_GAP = SnapLen(parent, 2) or 2
    local draggingItem = nil
    local dragOffsetY = 0
    
    -- Get current order from db or use default
    local function GetCurrentOrder()
        if dbTable and dbKey and dbTable[dbKey] then
            -- Validate and return existing order
            local order = {}
            local seen = {}
            for _, groupNum in ipairs(dbTable[dbKey]) do
                if groupNum >= 1 and groupNum <= 8 and not seen[groupNum] then
                    table.insert(order, groupNum)
                    seen[groupNum] = true
                end
            end
            -- Add any missing groups
            for i = 1, 8 do
                if not seen[i] then
                    table.insert(order, i)
                end
            end
            return order
        end
        return {1, 2, 3, 4, 5, 6, 7, 8}
    end
    
    -- Save order to db
    local function SaveOrder(newOrder)
        if dbTable and dbKey then
            dbTable[dbKey] = newOrder
            -- Track override when editing a profile
            if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and dbKey then
                local copy = {}
                for i, v in ipairs(newOrder) do copy[i] = v end
                DF.AutoProfilesUI:SetProfileSetting(dbKey, copy)
            end
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(newOrder)
            end
            if callback then callback() end
        end
    end
    
    -- Get index from Y position
    local function GetIndexFromY(y)
        local containerTop = container:GetTop()
        if not containerTop then return 1 end
        local relativeY = containerTop - y
        local index = math.floor(relativeY / ITEM_HEIGHT) + 1
        return math.max(1, math.min(index, 8))
    end
    
    -- Update visual positions
    local function UpdateItemPositions()
        local order = GetCurrentOrder()
        
        for _, item in pairs(groupItems) do
            item:Hide()
        end
        
        for displayPos, groupNum in ipairs(order) do
            local item = groupItems[groupNum]
            if item then
                item:Show()
                item.displayPos = displayPos
                item.numText:SetText(displayPos .. ".")
                if item ~= draggingItem then
                    -- Anchored to BOTH sides: the container is created at a placeholder
                    -- width and only stretched to its real one by the settings group's
                    -- LayoutChildren, so a width captured here would be stale. Deriving it
                    -- from the anchors keeps the rows correct at every layout.
                    item:ClearAllPoints()
                    item:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((displayPos - 1) * ITEM_HEIGHT))
                    item:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -((displayPos - 1) * ITEM_HEIGHT))
                end
            end
        end
    end
    
    -- Create grip texture (3 horizontal lines)
    local function CreateGripTexture(parentFrame)
        local grip = CreateFrame("Frame", nil, parentFrame)
        grip:SetSize(12, 14)
        
        local icon = grip:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints(grip)
        icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\reorder")
        icon:SetVertexColor(0.5, 0.5, 0.5, 1)
        grip.icon = icon
        
        grip.SetGripColor = function(self, r, g, b)
            self.icon:SetVertexColor(r, g, b, 1)
        end
        
        return grip
    end
    
    -- Create a single group item
    local function CreateGroupItem(groupNum)
        local color = GROUP_COLORS[groupNum]
        
        local item = CreateFrame("Frame", nil, container, "BackdropTemplate")
        item:SetHeight(ITEM_HEIGHT - ITEM_GAP)
        item:EnableMouse(true)
        CreateElementBackdrop(item, {
            bgColor     = { 0.12, 0.12, 0.12, 0.9 },
            borderColor = { 0.3, 0.3, 0.3, 1 },
        })
        
        -- Grip texture
        local grip = CreateGripTexture(item)
        grip:SetPoint("LEFT", 6, 0)
        item.grip = grip
        
        -- Display position number
        local numText = item:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
        numText:SetPoint("LEFT", grip, "RIGHT", 6, 0)
        numText:SetWidth(18)
        numText:SetJustifyH("LEFT")
        item.numText = numText
        
        -- Color swatch
        local swatch = item:CreateTexture(nil, "ARTWORK")
        swatch:SetSize(14, 14)
        swatch:SetPoint("LEFT", numText, "RIGHT", 4, 0)
        swatch:SetColorTexture(color[1], color[2], color[3], 1)
        item.swatch = swatch
        
        -- Group name
        local text = item:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        text:SetPoint("LEFT", swatch, "RIGHT", 6, 0)
        text:SetText(string.format(L["Group %d"], groupNum))
        text:SetTextColor(color[1], color[2], color[3])
        item.text = text
        
        item.groupNum = groupNum
        item.displayPos = groupNum
        
        -- Mouse handlers for dragging
        item:SetScript("OnMouseDown", function(self, button)
            if button == "LeftButton" then
                draggingItem = self
                local cursorY = select(2, GUI:CursorPos(self))
                local itemTop = self:GetTop()
                dragOffsetY = itemTop - cursorY
                
                local tc = GetThemeColor()
                self:SetBackdropColor(tc.r * 0.6, tc.g * 0.6, tc.b * 0.6, 0.9)
                self:SetBackdropBorderColor(tc.r, tc.g, tc.b, 1)
                self:SetFrameLevel(container:GetFrameLevel() + 10)
                self.grip:SetGripColor(1, 1, 1)
            end
        end)
        
        item:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" and draggingItem == self then
                local cursorY = select(2, GUI:CursorPos(self))
                local newIndex = GetIndexFromY(cursorY)
                
                -- Reorder
                local currentOrder = GetCurrentOrder()
                local oldIndex = self.displayPos
                
                if newIndex ~= oldIndex then
                    table.remove(currentOrder, oldIndex)
                    table.insert(currentOrder, newIndex, self.groupNum)
                    SaveOrder(currentOrder)
                end
                
                draggingItem = nil
                self:SetBackdropColor(0.12, 0.12, 0.12, 0.9)
                self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                self:SetFrameLevel(container:GetFrameLevel() + 1)
                self.grip:SetGripColor(0.5, 0.5, 0.5)
                
                UpdateItemPositions()
            end
        end)
        
        item:SetScript("OnUpdate", function(self)
            if draggingItem ~= self then return end
            
            local cursorY = select(2, GUI:CursorPos(self))
            local containerTop = container:GetTop()
            local containerBottom = container:GetBottom()
            
            if not containerTop or not containerBottom then return end
            
            local targetY = cursorY + dragOffsetY
            local offsetFromTop = containerTop - targetY
            
            local maxOffset = (containerTop - containerBottom) - ITEM_HEIGHT + 5
            offsetFromTop = math.max(0, math.min(offsetFromTop, maxOffset))
            
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -offsetFromTop)
            self:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -offsetFromTop)
            
            -- Update other items based on where this would drop
            local dropIndex = GetIndexFromY(cursorY)
            local order = GetCurrentOrder()
            
            -- Build temp order: remove self, insert at drop position
            local tempOrder = {}
            for i, g in ipairs(order) do
                if groupItems[g] ~= self then
                    table.insert(tempOrder, g)
                end
            end
            table.insert(tempOrder, dropIndex, self.groupNum)
            
            -- Position all other items according to temp order
            for i, g in ipairs(tempOrder) do
                local otherItem = groupItems[g]
                if otherItem and otherItem ~= self then
                    otherItem:ClearAllPoints()
                    otherItem:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((i - 1) * ITEM_HEIGHT))
                    otherItem:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, -((i - 1) * ITEM_HEIGHT))
                    otherItem.numText:SetText(i .. ".")
                end
            end
        end)
        
        item:SetScript("OnEnter", function(self)
            if draggingItem ~= self then
                self:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
                self.grip:SetGripColor(0.8, 0.8, 0.8)
            end
        end)
        
        item:SetScript("OnLeave", function(self)
            if draggingItem ~= self then
                self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                self.grip:SetGripColor(0.5, 0.5, 0.5)
            end
        end)
        
        return item
    end
    
    -- Create all group items
    for i = 1, 8 do
        groupItems[i] = CreateGroupItem(i)
    end
    
    -- Initial layout
    UpdateItemPositions()
    
    -- Refresh function
    container.Refresh = function()
        UpdateItemPositions()
    end
    -- ...and under the group-wide value sweep's one name (DandersUI Sections'
    -- RefreshChildValues), for a caller that wrote the key behind this widget's
    -- back -- a group Reset, a press-and-hold preview, or the undo of one. The
    -- Frame page's Group Display Order row wires those verbs, and without the
    -- alias a reset moved the raid and left the eight rows showing the order
    -- the user had before it.
    container.refreshValue = container.Refresh
    
    -- Override indicators for profile editing
    if dbKey and type(dbKey) == "string" and not (dbTable and rawget(dbTable, "_skipOverrideIndicators")) then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(dbKey)
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(dbKey)
                if dbTable and type(globalVal) == "table" then
                    local copy = {}
                    for i, v in ipairs(globalVal) do copy[i] = v end
                    dbTable[dbKey] = copy
                end
                UpdateItemPositions()
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(dbTable[dbKey])
                end
                if callback then callback() end
            end
        end
        AddOrderListOverrideIndicators(GUI, container, dbKey, onReset, dbTable)

        container:SetScript("OnShow", function()
            UpdateItemPositions()
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(dbTable and dbTable[dbKey])
            end
        end)
    end

    return container
end

-- ============================================================
-- HIGHLIGHT FRAMES ROSTER WIDGET
-- ============================================================
-- Dual-column widget for selecting players to highlight
-- Left: Current group roster
-- Right: Selected players (draggable for reorder)

function GUI:CreateHighlightRosterWidget(parent, getPlayersFunc, setPlayersFunc, onChangeCallback)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(460, 340)
    
    -- Snapped; see CreateRoleOrderList.
    local ITEM_HEIGHT = SnapLen(parent, 26) or 26
    local ITEM_GAP = SnapLen(parent, 2) or 2
    local COL_WIDTH = 224  -- Wider columns
    local COL_GAP = 12     -- Smaller gap between columns
    
    -- State
    local rosterItems = {}
    local highlightItems = {}
    local currentRoster = {}
    local draggingItem = nil
    local dragOffsetY = 0
    
    -- Custom role icons
    local ROLE_ICONS = {
        TANK = "Interface\\AddOns\\DandersFrames\\Media\\DF_Tank",
        HEALER = "Interface\\AddOns\\DandersFrames\\Media\\DF_Healer",
        DAMAGER = "Interface\\AddOns\\DandersFrames\\Media\\DF_DPS",
    }
    local ROLE_COLORS = {
        TANK = {0.35, 0.56, 0.82},
        HEALER = {0.29, 0.62, 0.29},
        DAMAGER = {0.70, 0.35, 0.35},
    }
    
    -- Icon paths
    local ICON_ARROW = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right"
    local ICON_CHECK = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\check"
    local ICON_CLOSE = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\close"
    
    -- ========== LEFT COLUMN: Group Roster ==========
    local leftHeader = container:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    leftHeader:SetPoint("TOPLEFT", 0, 0)
    leftHeader:SetText(L["Group Roster"])
    leftHeader:SetTextColor(0.7, 0.7, 0.7)
    
    local leftCount = container:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    leftCount:SetPoint("LEFT", leftHeader, "RIGHT", 8, 0)
    leftCount:SetTextColor(0.5, 0.5, 0.5)
    
    local leftBg = CreateFrame("Frame", nil, container, "BackdropTemplate")
    leftBg:SetPoint("TOPLEFT", 0, -18)
    leftBg:SetSize(COL_WIDTH, 240)
    GUI:CreateElementBackdrop(leftBg, { bgColor = GUI.Colors.background })
    
    local leftScroll = CreateFrame("ScrollFrame", nil, leftBg, "ScrollFrameTemplate")
    leftScroll:SetPoint("TOPLEFT", 4, -4)
    leftScroll:SetPoint("BOTTOMRIGHT", -24, 4)
    
    local leftContent = CreateFrame("Frame", nil, leftScroll)
    leftContent:SetSize(COL_WIDTH - 28, 1)
    leftScroll:SetScrollChild(leftContent)
    StyleScrollBar(leftScroll)

    -- ========== RIGHT COLUMN: Pinned Units ==========
    local rightHeader = container:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    rightHeader:SetPoint("TOPLEFT", leftBg, "TOPRIGHT", COL_GAP, 18)
    rightHeader:SetText(L["Pinned Units"])
    rightHeader:SetTextColor(0.7, 0.7, 0.7)
    
    local rightCount = container:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    rightCount:SetPoint("LEFT", rightHeader, "RIGHT", 8, 0)
    rightCount:SetTextColor(0.5, 0.5, 0.5)
    
    local rightBg = CreateFrame("Frame", nil, container, "BackdropTemplate")
    rightBg:SetPoint("TOPLEFT", leftBg, "TOPRIGHT", COL_GAP, 0)
    rightBg:SetSize(COL_WIDTH, 240)
    GUI:CreateElementBackdrop(rightBg, { bgColor = GUI.Colors.background })
    
    local rightScroll = CreateFrame("ScrollFrame", nil, rightBg, "ScrollFrameTemplate")
    rightScroll:SetPoint("TOPLEFT", 4, -4)
    rightScroll:SetPoint("BOTTOMRIGHT", -24, 4)
    
    local rightContent = CreateFrame("Frame", nil, rightScroll)
    rightContent:SetSize(COL_WIDTH - 28, 1)
    rightScroll:SetScrollChild(rightContent)
    StyleScrollBar(rightScroll)

    -- ========== HELPER FUNCTIONS ==========
    
    -- Get current group roster
    local function GetGroupRoster()
        local roster = {}
        local numMembers = GetNumGroupMembers()
        if numMembers == 0 then
            -- Solo - just show player
            local name = UnitName("player")
            local realm = GetRealmName()
            local _, class = UnitClass("player")
            table.insert(roster, {
                name = name,
                fullName = name .. "-" .. realm,
                class = class or "WARRIOR",
                role = "DAMAGER",
                group = 1,
            })
            return roster
        end
        
        local isRaid = IsInRaid()
        
        for i = 1, numMembers do
            local unit = isRaid and ("raid" .. i) or (i == 1 and "player" or "party" .. (i - 1))
            local name, realm = UnitName(unit)
            
            if name then
                realm = realm or GetRealmName()
                local fullName = name .. "-" .. realm
                local _, class = UnitClass(unit)
                local role = UnitGroupRolesAssigned(unit)
                if role == "NONE" then role = "DAMAGER" end
                local group = 1
                if isRaid then
                    local raidIndex = UnitInRaid(unit)
                    if raidIndex then
                        -- ☠ NO `+ 1`. UnitInRaid already returns an index that feeds
                        -- GetRaidRosterInfo directly — Blizzard passes it straight through in
                        -- both CompactUnitFrame (GetUnitFrameRaidRole) and
                        -- CompactRaidFrameManager. The +1 read the NEXT member's subgroup, so
                        -- every unit reported its neighbour's group and the last member in the
                        -- raid got nil and silently fell back to group 1. DF's three other
                        -- UnitInRaid consumers (TextDesigner/DataSource GetGroupNumber and both
                        -- Frames/Init sites) already pass it through unmodified; this was the
                        -- only site that disagreed.
                        local _, _, subgroup = GetRaidRosterInfo(raidIndex)
                        group = subgroup or 1
                    end
                end
                
                table.insert(roster, {
                    name = name,
                    fullName = fullName,
                    class = class or "WARRIOR",
                    role = role or "DAMAGER",
                    group = group,
                })
            end
        end
        
        -- Sort by group, then role, then name
        table.sort(roster, function(a, b)
            if a.group ~= b.group then return a.group < b.group end
            local roleOrder = { TANK = 1, HEALER = 2, DAMAGER = 3 }
            local aRole = roleOrder[a.role] or 3
            local bRole = roleOrder[b.role] or 3
            if aRole ~= bRole then return aRole < bRole end
            return a.name < b.name
        end)
        
        return roster
    end
    
    -- Check if player is in highlighted list
    local function IsPlayerHighlighted(fullName)
        local players = getPlayersFunc()
        for _, p in ipairs(players) do
            if p == fullName then return true end
        end
        return false
    end
    
    -- Check if player is in current group
    local function IsPlayerInGroup(fullName)
        for _, p in ipairs(currentRoster) do
            if p.fullName == fullName or p.name == fullName then
                return true, p
            end
        end
        return false, nil
    end
    
    -- Add player to highlight list
    local function AddPlayer(fullName)
        local players = getPlayersFunc()
        if not IsPlayerHighlighted(fullName) then
            table.insert(players, fullName)
            setPlayersFunc(players)
            if onChangeCallback then onChangeCallback() end
        end
    end
    
    -- Remove player from highlight list
    local function RemovePlayer(fullName)
        local players = getPlayersFunc()
        for i, p in ipairs(players) do
            if p == fullName then
                table.remove(players, i)
                setPlayersFunc(players)
                if onChangeCallback then onChangeCallback() end
                break
            end
        end
    end
    
    -- Create grip texture
    local function CreateGripTexture(parentFrame)
        local grip = CreateFrame("Frame", nil, parentFrame)
        grip:SetSize(12, 14)
        
        local icon = grip:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints(grip)
        icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\reorder")
        icon:SetVertexColor(0.5, 0.5, 0.5, 1)
        grip.icon = icon
        
        grip.SetGripColor = function(self, r, g, b)
            self.icon:SetVertexColor(r, g, b, 1)
        end
        
        return grip
    end
    
    -- Create role icon using custom textures
    local function CreateRoleIcon(parentFrame, role)
        local icon = parentFrame:CreateTexture(nil, "ARTWORK")
        icon:SetSize(14, 14)
        icon:SetTexture(ROLE_ICONS[role] or ROLE_ICONS.DAMAGER)
        return icon
    end
    
    -- ========== ROSTER ITEM (Left Column) ==========
    local function CreateRosterItem(playerData, index)
        local item = CreateFrame("Frame", nil, leftContent, "BackdropTemplate")
        item:SetHeight(ITEM_HEIGHT - ITEM_GAP)
        item:SetPoint("TOPLEFT", 0, -((index - 1) * ITEM_HEIGHT))
        item:SetPoint("TOPRIGHT", 0, -((index - 1) * ITEM_HEIGHT))
        -- Transparent plate: the hover/selected states tint it, so it needs a fill
        -- to colour but no outline of its own.
        CreateElementBackdrop(item, { outline = false, bgColor = { 0, 0, 0, 0 } })
        
        item.playerData = playerData
        
        -- Role icon
        local roleIcon = CreateRoleIcon(item, playerData.role)
        roleIcon:SetPoint("LEFT", 4, 0)
        item.roleIcon = roleIcon
        
        -- Name (class colored)
        local nameText = item:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        nameText:SetPoint("LEFT", roleIcon, "RIGHT", 6, 0)
        nameText:SetPoint("RIGHT", -70, 0)
        nameText:SetJustifyH("LEFT")
        nameText:SetText(playerData.name)
        local classColor = DF:GetClassColor(playerData.class)
        if classColor then
            nameText:SetTextColor(classColor.r, classColor.g, classColor.b)
        else
            nameText:SetTextColor(0.8, 0.8, 0.8)
        end
        item.nameText = nameText
        
        -- Group number
        local groupText = item:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        groupText:SetPoint("RIGHT", -34, 0)
        groupText:SetText("G" .. playerData.group)
        groupText:SetTextColor(0.4, 0.4, 0.4)
        item.groupText = groupText
        
        -- Add button
        local addBtn = CreateFrame("Button", nil, item, "BackdropTemplate")
        addBtn:SetSize(26, 20)
        addBtn:SetPoint("RIGHT", -4, 0)
        -- UpdateAddButton (called below, and on every state change) owns both
        -- colours, so this only supplies the chrome.
        CreateElementBackdrop(addBtn)

        local themeColor = GetThemeColor()
        
        -- Icon for button
        addBtn.icon = addBtn:CreateTexture(nil, "OVERLAY")
        addBtn.icon:SetSize(12, 12)
        addBtn.icon:SetPoint("CENTER", 0, 0)
        
        local function UpdateAddButton()
            local isHighlighted = IsPlayerHighlighted(playerData.fullName)
            if isHighlighted then
                addBtn:SetBackdropColor(0.15, 0.15, 0.15, 0.8)
                addBtn:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.5)
                addBtn.icon:SetTexture(ICON_CHECK)
                addBtn.icon:SetVertexColor(0.4, 0.4, 0.4)
                item:SetBackdropColor(0.1, 0.1, 0.1, 0.5)
                nameText:SetAlpha(0.5)
                groupText:SetAlpha(0.5)
                roleIcon:SetAlpha(0.5)
            else
                addBtn:SetBackdropColor(themeColor.r * 0.2, themeColor.g * 0.2, themeColor.b * 0.2, 0.8)
                addBtn:SetBackdropBorderColor(themeColor.r * 0.5, themeColor.g * 0.5, themeColor.b * 0.5, 0.8)
                addBtn.icon:SetTexture(ICON_ARROW)
                addBtn.icon:SetVertexColor(themeColor.r, themeColor.g, themeColor.b)
                item:SetBackdropColor(0, 0, 0, 0)
                nameText:SetAlpha(1)
                groupText:SetAlpha(1)
                roleIcon:SetAlpha(1)
            end
        end
        
        addBtn:SetScript("OnClick", function()
            if not IsPlayerHighlighted(playerData.fullName) then
                AddPlayer(playerData.fullName)
                container:Refresh()
            end
        end)
        
        addBtn:SetScript("OnEnter", function(self)
            if not IsPlayerHighlighted(playerData.fullName) then
                self:SetBackdropColor(themeColor.r * 0.3, themeColor.g * 0.3, themeColor.b * 0.3, 1)
                self:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 1)
            end
        end)
        
        addBtn:SetScript("OnLeave", function(self)
            UpdateAddButton()
        end)
        
        item.addBtn = addBtn
        item.UpdateAddButton = UpdateAddButton
        UpdateAddButton()
        
        return item
    end
    
    -- ========== HIGHLIGHT ITEM (Right Column - Draggable) ==========
    local function CreateHighlightItem(fullName, index, totalCount)
        local item = CreateFrame("Frame", nil, rightContent, "BackdropTemplate")
        item:SetHeight(ITEM_HEIGHT - ITEM_GAP)
        item:SetPoint("TOPLEFT", 0, -((index - 1) * ITEM_HEIGHT))
        item:SetPoint("TOPRIGHT", 0, -((index - 1) * ITEM_HEIGHT))
        item:EnableMouse(true)
        CreateElementBackdrop(item, {
            bgColor     = { 0.12, 0.12, 0.12, 0.9 },
            borderColor = { 0.25, 0.25, 0.25, 1 },
        })
        
        item.fullName = fullName
        item.index = index
        
        -- Check if player is in current group
        local inGroup, playerData = IsPlayerInGroup(fullName)
        
        -- Grip handle
        local grip = CreateGripTexture(item)
        grip:SetPoint("LEFT", 4, 0)
        item.grip = grip
        
        -- Position number
        local themeColor = GetThemeColor()
        local numText = item:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        numText:SetPoint("LEFT", grip, "RIGHT", 6, 0)
        numText:SetWidth(20)
        numText:SetJustifyH("LEFT")
        numText:SetText(index .. ".")
        numText:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
        item.numText = numText
        
        -- Role icon
        local role = playerData and playerData.role or "DAMAGER"
        local roleIcon = CreateRoleIcon(item, role)
        roleIcon:SetPoint("LEFT", numText, "RIGHT", 4, 0)
        item.roleIcon = roleIcon
        
        -- Name
        local displayName = fullName:match("([^%-]+)") or fullName  -- Get name before realm
        local nameText = item:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        nameText:SetPoint("LEFT", roleIcon, "RIGHT", 6, 0)
        nameText:SetPoint("RIGHT", -34, 0)
        nameText:SetJustifyH("LEFT")
        
        if playerData then
            nameText:SetText(playerData.name)
            local classColor = DF:GetClassColor(playerData.class)
            if classColor then
                nameText:SetTextColor(classColor.r, classColor.g, classColor.b)
            end
        else
            -- Player not in group
            nameText:SetText(displayName .. " " .. L["(offline)"])
            nameText:SetTextColor(0.5, 0.5, 0.5)
            item:SetBackdropColor(0.1, 0.1, 0.1, 0.7)
            grip:SetGripColor(0.35, 0.35, 0.35)
            roleIcon:SetAlpha(0.5)
        end
        item.nameText = nameText
        
        -- Remove button
        local removeBtn = CreateFrame("Button", nil, item, "BackdropTemplate")
        removeBtn:SetSize(26, 20)
        removeBtn:SetPoint("RIGHT", -4, 0)
        CreateElementBackdrop(removeBtn, {
            bgColor     = { 0.5, 0.15, 0.15, 0.5 },
            borderColor = { 0.6, 0.25, 0.25, 0.8 },
        })
        
        -- X icon for remove button
        removeBtn.icon = removeBtn:CreateTexture(nil, "OVERLAY")
        removeBtn.icon:SetSize(12, 12)
        removeBtn.icon:SetPoint("CENTER", 0, 0)
        removeBtn.icon:SetTexture(ICON_CLOSE)
        removeBtn.icon:SetVertexColor(0.8, 0.3, 0.3)
        
        removeBtn:SetScript("OnClick", function()
            RemovePlayer(fullName)
            container:Refresh()
        end)
        
        removeBtn:SetScript("OnEnter", function(self)
            self:SetBackdropColor(0.6, 0.2, 0.2, 0.8)
            self:SetBackdropBorderColor(0.8, 0.3, 0.3, 1)
        end)
        
        removeBtn:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0.5, 0.15, 0.15, 0.5)
            self:SetBackdropBorderColor(0.6, 0.25, 0.25, 0.8)
        end)
        
        item.removeBtn = removeBtn
        
        -- ========== DRAG HANDLERS ==========
        item:SetScript("OnMouseDown", function(self, button)
            if button == "LeftButton" then
                draggingItem = self
                local cursorY = select(2, GUI:CursorPos(self))
                local itemTop = self:GetTop()
                dragOffsetY = itemTop - cursorY
                
                self:SetBackdropColor(0.25, 0.25, 0.4, 0.95)
                self:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 1)
                self:SetFrameLevel(rightContent:GetFrameLevel() + 10)
                self.grip:SetGripColor(1, 1, 1)
            end
        end)
        
        item:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" and draggingItem == self then
                local cursorY = select(2, GUI:CursorPos(self))
                local contentTop = rightContent:GetTop()
                if contentTop then
                    local relativeY = contentTop - cursorY
                    local newIndex = math.floor(relativeY / ITEM_HEIGHT) + 1
                    newIndex = math.max(1, math.min(newIndex, totalCount))
                    
                    local oldIndex = self.index
                    if newIndex ~= oldIndex then
                        -- Reorder the players array
                        local players = getPlayersFunc()
                        local removed = table.remove(players, oldIndex)
                        table.insert(players, newIndex, removed)
                        setPlayersFunc(players)
                        if onChangeCallback then onChangeCallback() end
                    end
                end
                
                draggingItem = nil
                container:Refresh()
            end
        end)
        
        item:SetScript("OnUpdate", function(self)
            if draggingItem ~= self then return end
            
            local cursorY = select(2, GUI:CursorPos(self))
            local contentTop = rightContent:GetTop()
            local contentBottom = rightContent:GetBottom()
            
            if not contentTop or not contentBottom then return end
            
            local targetY = cursorY + dragOffsetY
            local offsetFromTop = contentTop - targetY
            
            local maxOffset = math.max(0, (totalCount - 1) * ITEM_HEIGHT)
            offsetFromTop = math.max(0, math.min(offsetFromTop, maxOffset))
            
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", rightContent, "TOPLEFT", 0, -offsetFromTop)
            self:SetPoint("TOPRIGHT", rightContent, "TOPRIGHT", 0, -offsetFromTop)
            
            -- Update visual positions of other items
            local dropIndex = math.floor(offsetFromTop / ITEM_HEIGHT) + 1
            dropIndex = math.max(1, math.min(dropIndex, totalCount))
            
            for _, otherItem in ipairs(highlightItems) do
                if otherItem ~= self then
                    local visualIndex = otherItem.index
                    if self.index < dropIndex then
                        -- Dragging down
                        if otherItem.index > self.index and otherItem.index <= dropIndex then
                            visualIndex = otherItem.index - 1
                        end
                    else
                        -- Dragging up
                        if otherItem.index < self.index and otherItem.index >= dropIndex then
                            visualIndex = otherItem.index + 1
                        end
                    end
                    otherItem:ClearAllPoints()
                    otherItem:SetPoint("TOPLEFT", rightContent, "TOPLEFT", 0, -((visualIndex - 1) * ITEM_HEIGHT))
                    otherItem:SetPoint("TOPRIGHT", rightContent, "TOPRIGHT", 0, -((visualIndex - 1) * ITEM_HEIGHT))
                    otherItem.numText:SetText(visualIndex .. ".")
                end
            end
        end)
        
        -- Hover effects
        item:SetScript("OnEnter", function(self)
            if draggingItem ~= self then
                self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
                self.grip:SetGripColor(0.8, 0.8, 0.8)
            end
        end)
        
        item:SetScript("OnLeave", function(self)
            if draggingItem ~= self then
                self:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
                if inGroup then
                    self.grip:SetGripColor(0.5, 0.5, 0.5)
                else
                    self.grip:SetGripColor(0.35, 0.35, 0.35)
                end
            end
        end)
        
        return item
    end
    
    -- ========== QUICK ADD BUTTONS ==========
    local buttonRow = CreateFrame("Frame", nil, container)
    buttonRow:SetSize(460, 28)
    buttonRow:SetPoint("TOPLEFT", leftBg, "BOTTOMLEFT", 0, -8)
    
    local function CreateQuickAddButton(text, role, color, xOffset)
        local btn = CreateFrame("Button", nil, buttonRow, "BackdropTemplate")
        btn:SetPoint("LEFT", xOffset, 0)
        -- Persistent role colour via the shared tinted variant — the colour IS the
        -- button's identity, so it stays on at rest and brightens on hover.
        GUI:StyleButton(btn, {
            width = 68, height = 24,
            tinted = true,
            accent = { r = color[1], g = color[2], b = color[3] },
            text = text,
        })
        btn:SetScript("OnClick", function()
            local players = getPlayersFunc()
            for _, player in ipairs(currentRoster) do
                if role == "ALL" or player.role == role then
                    if not IsPlayerHighlighted(player.fullName) then
                        table.insert(players, player.fullName)
                    end
                end
            end
            setPlayersFunc(players)
            if onChangeCallback then onChangeCallback() end
            container:Refresh()
        end)
        return btn
    end
    
    CreateQuickAddButton("+ " .. L["Tanks"], "TANK", ROLE_COLORS.TANK, 0)
    CreateQuickAddButton("+ " .. L["Healers"], "HEALER", ROLE_COLORS.HEALER, 72)
    CreateQuickAddButton("+ " .. L["DPS"], "DAMAGER", ROLE_COLORS.DAMAGER, 144)
    CreateQuickAddButton("+ " .. L["All"], "ALL", {0.6, 0.6, 0.6}, 216)
    
    -- Clear All button (right side) — persistent red via the tinted variant.
    local clearBtn = CreateFrame("Button", nil, buttonRow, "BackdropTemplate")
    clearBtn:SetPoint("RIGHT", 0, 0)
    GUI:StyleButton(clearBtn, {
        width = 68, height = 24,
        tinted = true,
        accent = { r = 0.85, g = 0.35, b = 0.35 },
        text = L["Clear All"],
    })
    clearBtn:SetScript("OnClick", function()
        setPlayersFunc({})
        if onChangeCallback then onChangeCallback() end
        container:Refresh()
    end)
    
    -- Remove Offline button (next to Clear All) — persistent gold via tinted.
    local removeOfflineBtn = CreateFrame("Button", nil, buttonRow, "BackdropTemplate")
    removeOfflineBtn:SetPoint("RIGHT", clearBtn, "LEFT", -6, 0)
    GUI:StyleButton(removeOfflineBtn, {
        width = 90, height = 24,
        tinted = true,
        accent = { r = 0.85, g = 0.65, b = 0.35 },
        text = L["Remove Offline"],
    })
    removeOfflineBtn:SetScript("OnClick", function()
        local players = getPlayersFunc()
        local newPlayers = {}
        
        -- Keep only players that are in the current roster
        for _, fullName in ipairs(players) do
            local inGroup = false
            for _, p in ipairs(currentRoster) do
                if p.fullName == fullName or p.name == fullName then
                    inGroup = true
                    break
                end
            end
            if inGroup then
                table.insert(newPlayers, fullName)
            end
        end
        
        setPlayersFunc(newPlayers)
        if onChangeCallback then onChangeCallback() end
        container:Refresh()
    end)

    -- ========== MANUAL PLAYER ENTRY ==========
    local themeColor = GetThemeColor()
    local manualHeader = container:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    manualHeader:SetPoint("TOPLEFT", buttonRow, "BOTTOMLEFT", 0, -12)
    manualHeader:SetText(L["Add Offline Player"])
    manualHeader:SetTextColor(themeColor.r, themeColor.g, themeColor.b)
    
    local manualHelp = container:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    manualHelp:SetPoint("TOPLEFT", manualHeader, "BOTTOMLEFT", 0, -2)
    manualHelp:SetText(L["Pre-configure players before they join the group"])
    manualHelp:SetTextColor(0.45, 0.45, 0.45)
    
    local manualInput = CreateFrame("EditBox", nil, container, "BackdropTemplate")
    manualInput:SetPoint("TOPLEFT", manualHelp, "BOTTOMLEFT", 0, -6)
    manualInput:SetSize(380, 24)
    GUI:StyleEditBox(manualInput, { skipFont = true })
    manualInput:SetFontObject(DFFontHighlight)
    manualInput:SetTextInsets(8, 8, 0, 0)
    manualInput:SetAutoFocus(false)
    manualInput:SetMaxLetters(50)
    
    manualInput:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    
    manualInput:SetScript("OnEnterPressed", function(self)
        local text = self:GetText():trim()
        if text ~= "" then
            -- Add realm if not present
            if not text:find("-") then
                text = text .. "-" .. GetRealmName()
            end
            AddPlayer(text)
            self:SetText("")
            container:Refresh()
        end
        self:ClearFocus()
    end)
    
    local addManualBtn = CreateFrame("Button", nil, container, "BackdropTemplate")
    addManualBtn:SetPoint("LEFT", manualInput, "RIGHT", 6, 0)
    GUI:StyleButton(addManualBtn, {
        width = 54, height = 24,
        tinted = true,
        text = L["Add"],
    })
    addManualBtn:SetScript("OnClick", function()
        local text = manualInput:GetText():trim()
        if text ~= "" then
            if not text:find("-") then
                text = text .. "-" .. GetRealmName()
            end
            AddPlayer(text)
            manualInput:SetText("")
            container:Refresh()
        end
    end)

    -- ========== REFRESH FUNCTION ==========
    function container:Refresh()
        -- Get current roster
        currentRoster = GetGroupRoster()
        local players = getPlayersFunc()
        
        -- Clear existing items
        for _, item in ipairs(rosterItems) do
            item:Hide()
            item:SetParent(nil)
        end
        wipe(rosterItems)
        
        for _, item in ipairs(highlightItems) do
            item:Hide()
            item:SetParent(nil)
        end
        wipe(highlightItems)
        
        -- Update counts
        leftCount:SetText("(" .. #currentRoster .. ")")
        rightCount:SetText("(" .. #players .. ")")
        
        -- Build left column (roster)
        for i, playerData in ipairs(currentRoster) do
            local item = CreateRosterItem(playerData, i)
            table.insert(rosterItems, item)
        end
        leftContent:SetHeight(math.max(1, #currentRoster * ITEM_HEIGHT))
        
        -- Build right column (highlighted)
        for i, fullName in ipairs(players) do
            local item = CreateHighlightItem(fullName, i, #players)
            table.insert(highlightItems, item)
        end
        rightContent:SetHeight(math.max(1, #players * ITEM_HEIGHT))
        
        -- Show hint if empty
        if #players == 0 then
            if not container.emptyHint then
                container.emptyHint = rightContent:CreateFontString(nil, "OVERLAY", "DFFontNormal")
                container.emptyHint:SetPoint("CENTER", rightBg, "CENTER", 0, 0)
                container.emptyHint:SetText(L["Add players from the roster\nor use quick add buttons"])
                container.emptyHint:SetTextColor(0.35, 0.35, 0.35)
                container.emptyHint:SetJustifyH("CENTER")
            end
            container.emptyHint:Show()
        elseif container.emptyHint then
            container.emptyHint:Hide()
        end
    end
    
    -- Register for roster updates
    container:RegisterEvent("GROUP_ROSTER_UPDATE")
    container:RegisterEvent("PLAYER_ENTERING_WORLD")
    container:SetScript("OnEvent", function(self, event)
        self:Refresh()
    end)
    
    -- Initial refresh
    container:Refresh()
    
    return container
end

-- Gradient Preview Bar
function GUI:CreateGradientBar(parent, width, height, db, prefix)
    prefix = prefix or "healthColor"
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f:SetSize(width or 360, height or 24)
    CreateElementBackdrop(f)
    
    local lbl = f:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmallOutline")
    lbl:SetPoint("LEFT", f, "LEFT", 8, 0)
    lbl:SetText("0%")
    lbl:SetTextColor(1, 1, 1, 1)
    
    local lbl2 = f:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmallOutline")
    lbl2:SetPoint("RIGHT", f, "RIGHT", -8, 0)
    lbl2:SetText("100%")
    lbl2:SetTextColor(1, 1, 1, 1)
    
    f.TexPool = {}
    
    f.UpdatePreview = function()
        if not db then return end
        
        for _, tex in ipairs(f.TexPool) do tex:Hide() end
        
        -- ☠ THE RAMP IS BUILT IN ONE PLACE, AND THIS IS NOT IT. This function used to
        -- hold a THIRD copy of the point-array build -- its own GetStageColor, its own
        -- weight expansion -- alongside the two in Frames/Colors.lua. When the health
        -- gradient moved to a stop list those two were converged and this one was
        -- missed, so the strip kept painting the legacy Low/Medium/High stages: editing
        -- a stop's colour changed the frames and did nothing to the preview above them.
        -- A preview that disagrees with what it previews is worse than no preview.
        --
        -- DF.BuildColorStops is the shared builder. It answers for BOTH shapes (stop
        -- list, or the legacy stages for a profile the migration has not reached), so
        -- this reads whatever the renderer would read, by construction.
        -- ⚠ THE PLAYER'S CLASS, NOT nil. A stop with useClass set resolves against the
        -- unit's class at render time; passing nil makes BuildColorStops ignore the flag
        -- and fall back to the stored colour, so the strip would show one thing and the
        -- frames another the moment class colouring was switched on. Sampling the
        -- player's own class is the preview differing in DATA, which is allowed -- it
        -- shows what a frame for someone of your class would look like.
        local _, previewClass = UnitClass("player")
        local stops = DF.BuildColorStops and DF.BuildColorStops(db, prefix, previewClass)
        if not stops or #stops < 2 then return end

        -- ⚠ MEASURED, SO IT MUST BE RE-MEASURED. Everything below is laid out in
        -- absolute pixels off this width, which is why OnSizeChanged has to re-run the
        -- whole function -- see the note at the bottom.
        --
        -- Defensive: a width at or under 4 would give a zero or negative segment width,
        -- laying segments out backwards over each other. Bail; the next pass repaints.
        local usable = (f:GetWidth() or 0) - 4
        if usable <= 0 then return end

        -- ⚠ SEGMENTS ARE PLACED BY THRESHOLD, NOT BY EQUAL SHARE. The old loop gave every
        -- segment `usable / numSegments`, which was only right because weights produced
        -- evenly spaced points. Stops carry their own positions, so a 0/50/90 ramp has a
        -- wide band and a narrow one -- dividing equally would draw a plausible gradient
        -- that simply is not the one being rendered on the frames.
        for i = 1, #stops - 1 do
            local s1, s2 = stops[i], stops[i + 1]
            local x0 = 2 + s1.pos * usable
            local segWidth = (s2.pos - s1.pos) * usable
            if segWidth < 1 then segWidth = 1 end   -- two stops a percent apart still draw

            local tex = f.TexPool[i]
            if not tex then
                tex = f:CreateTexture(nil, "ARTWORK")
                table.insert(f.TexPool, tex)
            end

            tex:Show()
            tex:ClearAllPoints()
            tex:SetPoint("LEFT", f, "LEFT", x0, 0)
            tex:SetSize(segWidth, f:GetHeight() - 4)

            local c1 = CreateColor(s1.r, s1.g, s1.b, 1)
            local c2 = CreateColor(s2.r, s2.g, s2.b, 1)
            
            tex:SetColorTexture(1, 1, 1, 1)
            tex:SetGradient("HORIZONTAL", c1, c2)
        end
    end
    
    -- ☠ ON RESIZE TOO, NOT JUST ON SHOW. This is a layoutCol = "both" widget, so the
    -- page layout calls SetWidth on it on every relayout -- and dragging the settings
    -- window edge relayouts continuously. UpdatePreview paints its segments at ABSOLUTE
    -- pixel offsets and sizes derived from GetWidth at the moment it runs, so with only
    -- an OnShow binding the frame took its new width while the segments kept the old
    -- one: the gradient filled part of the bar, and the stale segments sat at stale
    -- offsets, spilling past the frame's edge (textures are not clipped) as the window
    -- shrank. Both halves of "the fill goes half and it jumps around".
    --
    -- Safe against the SetHeight -> OnSizeChanged -> relayout cascade this file warns
    -- about elsewhere: UpdatePreview only ever sizes TEXTURES, never the frame, and a
    -- texture resize does not fire its parent's OnSizeChanged.
    f:SetScript("OnShow", f.UpdatePreview)
    f:SetScript("OnSizeChanged", f.UpdatePreview)
    f.UpdatePreview()
    return f
end

-- ☠ (Removed) four full section banners heading NO CODE: SELECTABLE LIST WIDGET,
-- SEARCHABLE DROPDOWN WIDGET, KEY-VALUE EDITOR WIDGET and BRANCH EDITOR WIDGET.
-- There is no CreateSelectableList, CreateSearchableDropdown, CreateKeyValueEditor or
-- CreateBranchEditor anywhere in the repo -- three of the four described the Wizard
-- Builder, which is gone (WizardBuilder.lua is deleted; see the notes in GUI.lua and
-- Popup.lua). Four banners in a row with nothing between them read as "these widgets
-- are somewhere in this file", which costs a search every time.

-- =========================================================================
-- MAIN GUI CREATION
-- =========================================================================

function DF:ToggleGUI()
    if DF.GUIFrame and DF.GUIFrame:IsShown() then
        DF.GUIFrame:Hide()
    else
        if not DF.GUIFrame then
            DF:CreateGUI()
        end
        
        -- Auto-detect mode based on current group status
        -- ARENA FIX: Arena returns IsInRaid()=true but uses party-style layout/settings.
        -- Check for arena first so the settings UI shows party settings, not raid.
        if DF.IsInArena and DF:IsInArena() then
            GUI.SelectedMode = "party"
        elseif IsInRaid() then
            GUI.SelectedMode = "raid"
        else
            GUI.SelectedMode = "party"
        end
        GUI:SetAccent(GUI.GetThemeColorFor(GUI.SelectedMode == "raid"))
        
        -- Update theme colors to match selected mode
        if GUI.UpdateThemeColors then
            GUI.UpdateThemeColors()
        end
        
        -- Show correct content for the selected mode
        if GUI.ShowNormalContent then
            GUI:ShowNormalContent()
        end
        
        -- Refresh editing UI state (re-enables tabs that were disabled when closed during editing)
        local AutoProfilesUI = DF.AutoProfilesUI
        if AutoProfilesUI and AutoProfilesUI.RefreshEditingUI then
            AutoProfilesUI:RefreshEditingUI()
        end

        -- Refresh override stars (shows if a runtime profile is active)
        if AutoProfilesUI and AutoProfilesUI.RefreshTabOverrideStars then
            AutoProfilesUI:RefreshTabOverrideStars()
        end
        
        DF.GUIFrame:Show()
        GUI:RefreshCurrentPage()

        -- Auto-show changelog on first open after update
        if DandersFramesDB_v2 and DandersFramesDB_v2.lastSeenVersion ~= DF.VERSION then
            DandersFramesDB_v2.lastSeenVersion = DF.VERSION
            if GUI.ShowChangelog then GUI:ShowChangelog() end
        end
    end
end


-- ============================================================
-- DURATION FORMAT: dropdown + live example line
-- ============================================================
-- One helper for all seven Duration Format dropdowns (buff/debuff/defensive rows, AD
-- indicator/square/group cards, AD bar), because the example only earns its place if it
-- appears on every one of them — a format list explained in some places and not others
-- is worse than one explained nowhere.
--
-- ★ WHY A LINE UNDER THE CONTROL, not examples in the labels or a per-row tooltip:
--   * A label example can only show ONE duration, and what people get wrong is the
--     ROLL-UP — "Standard (45)" says nothing about what happens past a minute. Three
--     samples is the minimum that explains the difference, and that is far too wide for
--     a dropdown row (and would sit in the closed control forever).
--   * CreateDropdown has no per-row tooltip support, so that route means changing a
--     widget every page depends on, for something you would then have to hover row by
--     row to compare.
--
-- Gap between the "Duration Format" caption and the example sharing its line. Wide
-- enough to clear the override-changed indicator, which AddOverrideIndicators pins just
-- past the caption.
local DURFMT_EXAMPLE_GAP = 16

function GUI:CreateDurationFormatControls(parent, group, options, dbTable, dbKey, callback, opts)
    opts = opts or {}
    local example
    local function CurrentFormat()
        if opts.get then return opts.get() end
        return dbTable and dbTable[dbKey] or "NUMBER"
    end
    local function RefreshExample()
        if not example then return end
        example:SetText(DF:GetDurationFormatExample(CurrentFormat()) or "")
    end

    local dd = GUI:CreateDropdown(parent, L["Duration Format"], options,
        dbTable, dbKey, function(...)
            -- Example first: the caller's callback may rebuild the page, and on some
            -- surfaces that discards this widget before we would have refreshed it.
            RefreshExample()
            if callback then callback(...) end
        end, opts.customGet, opts.customSet)

    -- ☠ THE EXAMPLE SHARES THE CAPTION'S LINE, right-aligned against the control's right
    -- edge. It was tried twice BELOW the opener — first as its own group row, then pinned
    -- tight underneath — and read as "a bit lost" both times (Krathe). Distance was never
    -- the problem: "45s · 3m · 63m" on its own is a fragment with no grammar, so wherever
    -- it sat the eye had nothing to attach it to. Pairing it with the caption gives it the
    -- one thing it lacked — caption-left / value-right is a settings idiom people already
    -- read — and it costs NO extra height, because the caption row is already there.
    --
    -- It also stays one widget with the dropdown, so hideOn and disableOn cover it for
    -- free; as a sibling row hideOn had to be duplicated by hand and disableOn could not
    -- work at all (the group gate calls SetEnabled, which a FontString/label lacks).
    example = dd:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    example:SetPoint("TOPRIGHT", dd, "TOPRIGHT", 0, 0)
    example:SetPoint("LEFT", dd.label, "RIGHT", DURFMT_EXAMPLE_GAP, 0)
    example:SetJustifyH("RIGHT")
    -- No wrap: the two horizontal anchors bound the width, so a narrow column clips the
    -- example quietly instead of wrapping it into the opener below.
    example:SetWordWrap(false)
    example:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 1)
    RefreshExample()

    group:AddWidget(dd)

    dd.dfExampleText = example
    dd.dfRefreshExample = RefreshExample
    return dd
end

-- ============================================================
-- THE POPOUT PAGE'S SHARED MACHINERY
-- ------------------------------------------------------------
-- Everything a settings page needs to mount its groups as popout feature rows,
-- lifted out of the Frame page, which built the first copy of it inline because
-- it was the first page converted and there was nothing yet to share. Five more
-- pages needed the same eight verbs; five more copies would drift, and the first
-- thing to drift would be one of the load-bearing notes rather than the code
-- under it. The Frame page came home last, in its own commit -- its census tests
-- pin that page's source line by line -- so this is now the ONLY copy, and the
-- essays below are the only place each piece is explained.
--
-- USAGE, at the top of a BuildPage builder and unconditionally:
--
--     local classicLayout = DF:IsClassicSettingsLayout()
--     local tools = GUI:CreatePopoutPageTools(self)
--
-- `tools` is nil in the classic layout, which is what makes the classic branch
-- of every converted group a plain `if classicLayout then` arm building the box
-- it always built.
--
-- WHAT COMES BACK (all closing over this page's own state -- its mounted panes,
-- its holders, its row map -- so two pages built in one session cannot reflow
-- each other's panels):
--
--   PopoutContent(buildInto, innerColumns) -> mount, eagerGroup
--   ClaimKeys(row, group, extra)
--   WireModifiedTick(row)
--   WireFooter(row, apply)
--   RegisterHoistedToggle(row, label, key, onToggle)
--   ReflowMounted(values)
--   RowDB()
--   BandWidth()
--   INLINE_BOX          -- the stay-inline box's band skin
-- ============================================================
function GUI:CreatePopoutPageTools(page)
    if not page then return nil end

    -- Cleared on EVERY build, classic included. It only ever has entries in the
    -- popout layout, and a map left behind by a previous new-UI build would
    -- point the settings-search jump at rows this build has retired.
    page._popoutRowForKey = nil

    -- ☠ CLOSE EVERY OPEN ROW PANEL FIRST, BEFORE ANYTHING IS BUILT. Every route
    -- into a page builder is a REBUILD -- a party/raid switch, a profile switch,
    -- the classic-layout flip, and the settings search registry, which is built
    -- by re-running every page's builder -- and an open popout from the PREVIOUS
    -- build is showing widgets wired to the db table THAT build captured. After
    -- a mode switch that table is the other mode's, so a slider dragged in a
    -- stale panel writes live settings into the wrong mode. Guarded rather than
    -- called bare, so an older embedded copy of the pack without the verb cannot
    -- break the page.
    --
    -- ☠ AND IT IS ABOVE THE CLASSIC BAIL, FOR THE SAME REASON THE MAP CLEAR IS.
    -- The flip TO classic is itself a rebuild, and it is the one rebuild that
    -- happens with a panel standing open -- the tick that flips it lives inside
    -- one. Left below the early return, the helper would hand the classic page
    -- back with an orphan panel still floating beside it, wired to a row this
    -- build has retired. Classic has nothing open otherwise, so on every other
    -- classic build this is a no-op over an empty registry.
    if GUI.CloseAllPopoutRows then GUI:CloseAllPopoutRows("rebuild") end

    if DF:IsClassicSettingsLayout() then return nil end

    -- Retire the previous build's holders. They are deliberately NOT in
    -- page.children -- anything in that list is laid out into one of the page's
    -- columns, and these must never appear ON the page -- so DoBuild's own
    -- retire loop never sees them and this is the only thing that does.
    if page._popoutHolders then
        local trash = GUI._trashFrame
        for _, holder in ipairs(page._popoutHolders) do
            holder:Hide()
            holder:ClearAllPoints()
            if trash then holder:SetParent(trash) end
        end
    end
    page._popoutHolders = {}

    -- What the settings SEARCH needs back, per row: (a) the hoisted toggles,
    -- whose checkbox factory was what registered them with search, and (b) which
    -- row owns a setting, so a hit on a popout-only control can open the panel
    -- it is behind. (a) is RegisterHoistedToggle below; this is (b)'s map.
    page._popoutRowForKey = {}

    local POPOUT_W = GUI.PopoutContentWidth or 260

    -- Every pane currently mounted in a panel, so a toggle can re-flow the group
    -- the user is looking at as well as the rows on the page. One list per PAGE
    -- rather than per group: a reset behind one row can change what another
    -- row's pane is showing, and a stale open panel costs more than a repaint.
    local mounted = {}

    -- Re-flow one mounted group and put the panel back around it. Sized from the
    -- group's own FRAME height, not LayoutChildren's return, which adds the
    -- between-groups margin a lone group in a popout has no use for.
    local function ReflowPane(st, values)
        local g = st.group
        if not g then return end
        g:LayoutChildren()
        g:RefreshChildStates()
        -- ☠ AND THE VALUES, when the caller says a write happened that these
        -- widgets could not have seen (a group Reset, a hold, the undo of one).
        -- RefreshChildStates is about STATE; a checkbox's tick, a slider's thumb
        -- and a dropdown's caption are painted at build and on OnShow, on the
        -- assumption nothing writes a setting except the widget bound to it.
        --
        -- ⚠ OPT-IN, not on every reflow: this also runs on a hideOn change while
        -- a slider inside the pane is being dragged, and a value repaint mid-drag
        -- snaps the thumb from the mouse back to the last committed step.
        if values and g.RefreshChildValues then g:RefreshChildValues() end
        if st.pane then st.pane:SetHeight(math.max(g:GetHeight() or 1, 1)) end
        -- ...and the panel around the pane. The kit fixes a pane's height at
        -- build, and a hideOn inside this group moves it afterwards.
        local po = st.po
        if po and not po.closed and po.SyncRowPaneHeight then po:SyncRowPaneHeight() end
    end

    -- `values` rides through to ReflowPane: see its header for why a value
    -- repaint is opt-in rather than part of every reflow.
    local function ReflowMounted(values)
        for _, st in ipairs(mounted) do
            if not (st.po and st.po.closed) then ReflowPane(st, values) end
        end
    end

    -- ONE row's popout content, built EAGERLY -- at page build time, into a
    -- hidden holder -- rather than on first open. Two reasons, either sufficient
    -- on its own:
    --   (a) the settings SEARCH registry is built by re-running every page's
    --       builder, so a widget that does not exist until the user opens a
    --       popout is a widget search can never find;
    --   (b) some builders SEED db keys at build time, and moving those writes to
    --       first-open would move WHEN a profile changes shape, which is exactly
    --       what the export byte-identity gate measures.
    --
    -- The shell runs a row's `build` ONCE PER INSTANCE, so a SECOND instance (pin
    -- one, then click the row again) asks for content a second time: the first
    -- call adopts the pre-built group, every later one builds a fresh one through
    -- the same builder. Which is why this is a factory rather than one captured
    -- group -- and why each group carries its own `st`, so the refresh wired into
    -- group one cannot re-flow group two.
    --
    -- `innerColumns` is the pane's own interior grid (DandersUI Sections'
    -- opts.innerColumns), per ROW rather than per page: a pane of sliders at half
    -- width is two stubby bars with their labels stranded, while a pane of
    -- one-word checkboxes is exactly the list the second track was written for.
    -- Omitted = absent = one track.
    local function PopoutContent(buildInto, innerColumns)
        local function fresh()
            local st = {}
            local holder = CreateFrame("Frame", nil, page.child)
            holder:SetSize(POPOUT_W, 1)
            holder:Hide()
            page._popoutHolders[#page._popoutHolders + 1] = holder
            -- chromeless + zero padding: the popout already draws a panel, and a
            -- faint bordered box inside one reads as a second, smaller panel. The
            -- width is the popout's own content width, so each control mounts at
            -- exactly the width it has inline on the page.
            st.group = GUI:CreateSettingsGroup(holder, POPOUT_W,
                                               { chromeless = true, padding = 0,
                                                 innerColumns = innerColumns })
            st.group:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
            -- What a builder's own dropdowns and checkboxes call. Cheap, and
            -- deliberately NOT a page rebuild: a rebuild retires the row the user
            -- is clicking through.
            buildInto(st.group, holder, function()
                ReflowPane(st)
                page:RefreshStates()
            end)
            return st
        end

        local pending = fresh()
        -- The eagerly built group comes back ALONGSIDE the mount function: it is
        -- the one instance that exists at page-build time, so it is the one whose
        -- children ClaimKeys can walk. Later instances build the same controls
        -- from the same builder, so nothing is missed by ignoring them.
        return function(po, pane)
            local st = pending or fresh()
            pending = nil
            st.po, st.pane = po, pane
            mounted[#mounted + 1] = st
            st.group:SetParent(pane)
            st.group:ClearAllPoints()
            st.group:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, 0)
            st.group:SetWidth(POPOUT_W)
            st.group:Show()
            ReflowPane(st)
        end, pending.group
    end

    -- db as a FUNCTION, which is what the kit contract asks for: the row
    -- re-resolves on every refresh, so a mode switch is followed rather than
    -- frozen at the table this build captured.
    local function RowDB() return DF.db and DF.db[GUI.SelectedMode] end

    -- Built by WALKING WHAT THE CONTENT ACTUALLY REGISTERED, not from a key list
    -- and not from a name prefix -- a prefix would claim keys no popout owns and
    -- would miss any spelled differently. Every shared factory stamps
    -- container.searchEntry, so a control added to any builder is covered
    -- without anyone having to remember this exists.
    --
    -- ...and the SAME walk answers which keys the row's amber modified-tick is
    -- about, collected onto row._claimedKeys so the tick can ask the diff engine
    -- "is any of these not the shipped default", which is exactly "does the pane
    -- behind this row contain a change".
    --
    -- ⚠ TWO SOURCES FOR THE KEY, and the second is not belt-and-braces.
    -- searchEntry is stamped by the SEARCH registration, which is guarded on
    -- DF.Search existing -- so on a build where search has not registered, every
    -- key would be missed. container.overrideDbKey is stamped by the toolkit's
    -- own AddOverrideIndicators, which every db-bound control goes through
    -- regardless, and it covers the colour pickers and checkboxes whose search
    -- entries are registered by a different route.
    --
    -- ⚠ `extra` IS NOT A CONVENIENCE. A control may be bound to a key the walk
    -- cannot see: custom-get/set ticks over ONE table setting each stamp a
    -- per-index override key the profile does not ship. Left to the walk alone
    -- the row would claim keys the defaults engine cannot answer for, so its
    -- amber tick would never light and Reset Group would write nothing while
    -- saying it had. The real key is named through this door instead.
    local function ClaimKeys(row, group, extra)
        if not (row and group and group.groupChildren) then return end
        local claimed = row._claimedKeys or {}
        row._claimedKeys = claimed
        for _, e in ipairs(group.groupChildren) do
            local w  = e.widget
            local se = w and w.searchEntry
            local k  = (se and (se.dbKey or se.searchKey)) or (w and w.overrideDbKey)
            if type(k) == "string" then
                page._popoutRowForKey[k] = row
                claimed[#claimed + 1] = k
            end
        end
        for _, k in ipairs(extra or {}) do
            page._popoutRowForKey[k] = row
            claimed[#claimed + 1] = k
        end
    end

    -- The tick's answer, for a row that has just had its keys claimed. Re-read on
    -- every refresh (the row calls this, not the other way round), so a write
    -- inside the popout lights it without anything having to be invalidated.
    -- DF.Defaults is guarded because these pages are in the load-on-demand
    -- companion and the engine is resident.
    local function WireModifiedTick(row)
        if not (row and row.SetModifiedCheck) then return end
        row:SetModifiedCheck(function(d)
            local D = DF.Defaults
            return (D and D:Count(d, row._claimedKeys or {}) or 0) > 0
        end)
    end

    -- What a write to any of a group's keys costs, in one place, so the two
    -- footer buttons and every future one apply the SAME work.
    --
    -- `apply` is the GROUP's own half -- the bodies its widgets' own callbacks
    -- drive, handed in per row because two groups' resets do not cost the same
    -- work. Everything after it is shared: ReflowMounted repaints the controls
    -- the user is looking at, and the row's own Refresh re-reads the summary and
    -- the modified tick.
    local function RefreshAfterGroupWrite(apply)
        if apply then apply() end
        -- ⚠ WITH THE VALUE SWEEP. This is the one path where the keys moved
        -- WITHOUT the widgets doing it -- a group reset, a hold, and the
        -- undo/redo of a reset (which replays ApplyGroup) -- so it is the one
        -- path that has to repaint what the controls read.
        ReflowMounted(true)
        if GUI.RefreshAllOverrideIndicators then
            GUI.RefreshAllOverrideIndicators()
        end
        page:RefreshStates()
    end

    -- Can these buttons be pressed at all, and if not, why. COMBAT greys both:
    -- every key behind these rows reaches a secure frame, and the addon's
    -- standing rule is that those writes are deferred in combat -- the footer
    -- does not fight that, it just says so.
    local function CombatReason()
        if InCombatLockdown() then return false, L["Cannot use this action in combat."] end
        return true
    end

    -- ...and HOLD alone is additionally off while the raid auto-layout machinery
    -- is live. Two different reasons, one gate:
    --
    --   EDITING a layout: every write is recorded as an override edit for that
    --   layout, and a hold writes twice -- defaults in, the user's values back
    --   out -- so a preview nobody committed to would land as two deliberate
    --   edits. A LAYOUT RUNNING: writes are redirected to the stored baseline
    --   instead of the live table, so the preview would change nothing on screen.
    --
    -- RESET stays available in BOTH states, and that is not an oversight. While
    -- editing, recording the defaults as this layout's override edits is exactly
    -- what the user asked for; while a layout is running, the redirect writes
    -- them into the stored baseline -- which is the table the modified dots and
    -- the row tick are reporting on, so the reset does what they say it will.
    local function HoldReason()
        local ok, why = CombatReason()
        if not ok then return false, why end
        local AP = DF.AutoProfilesUI
        if GUI.SelectedMode == "raid" and AP then
            local editing = AP.IsEditing and AP:IsEditing()
            local running = AP.IsLayoutActive and AP:IsLayoutActive()
            if editing or running then
                return false, L["Unavailable while an auto layout is active or being edited."]
            end
        end
        return true
    end

    -- The two verbs, wired onto a row whose keys have just been claimed. Both
    -- close over row._claimedKeys BY REFERENCE rather than reading it now:
    -- ClaimKeys fills that table after the row is built, and a copy taken here
    -- would be the empty one.
    local function WireFooter(row, apply)
        if not (row and row.SetActions) then return end
        local held                    -- the hold's snapshot, between the two halves

        -- THE GROUP'S APPLY, named once. Every verb runs it after it writes --
        -- and Reset hands the same reference to the undo engine, because an undo
        -- of a reset has no button press behind it to run this for it. Restoring
        -- the values and running only the generic sweep is what "undo changed the
        -- numbers but the frames did not move" looks like.
        local function ApplyGroup()
            RefreshAfterGroupWrite(apply)
            row.Refresh()
        end

        row:SetActions({
            {
                text        = L["Reset Group"],
                tooltipDesc = L["Reset every setting in this group to its default value."],
                enabled     = CombatReason,
                onClick     = function()
                    local GA = DF.GroupActions
                    if not GA then return end
                    -- The row's own heading names the collapsed undo entry: a
                    -- reset is one thing the user did to THIS group, and the
                    -- group is what they will look for.
                    GA:ResetKeys(GUI, RowDB(), row._claimedKeys or {}, GUI.SelectedMode,
                                 row._title or row._label, ApplyGroup)
                    ApplyGroup()
                end,
            },
            {
                text        = L["Hold: Defaults"],
                hold        = true,
                tooltipDesc = L["Press and hold to preview this group at its default values. Release to restore your settings."],
                enabled     = HoldReason,
                onHoldStart = function()
                    local GA = DF.GroupActions
                    if not GA then return end
                    held = GA:BeginHold(GUI, RowDB(), row._claimedKeys or {}, GUI.SelectedMode)
                    ApplyGroup()
                end,
                onHoldEnd   = function()
                    local GA = DF.GroupActions
                    if not (GA and held) then return end
                    GA:EndHold(GUI, RowDB(), row._claimedKeys or {}, held)
                    held = nil
                    -- The UNTHROTTLED apply on the way back, unlike the
                    -- coalescing one used going in: a release is the moment the
                    -- user is watching for their settings to come back, and a
                    -- frame of defaults left on screen after they let go reads as
                    -- the restore failing.
                    GUI:Call("refreshNow")
                    ApplyGroup()
                end,
            },
        })
    end

    -- The hoisted toggle's own search entry. Deliberately NOT added to the row
    -- map: the tick is ON the row, so the section jump already lands on the
    -- control the user searched for, and opening the panel on top of that would
    -- be noise. The callback is the one the suppressed checkbox would have
    -- carried, so an inline result behaves as the inline checkbox does in
    -- classic. Guarded on the METHOD, not just the table -- Search is in this
    -- companion but the page must not care.
    local function RegisterHoistedToggle(row, label, key, onToggle)
        local Search = DF.Search
        if not (Search and Search.RegisterCheckbox) then return end
        row.searchEntry = Search:RegisterCheckbox(label, key, nil, false, onToggle)
        if Search.LinkSourceWidget then Search:LinkSourceWidget(row) end
    end

    -- The width a full-width band is CONSTRUCTED at, asked for rather than
    -- guessed: GUI.PageUsableWidth is the same helper the layout pass stretches
    -- "both" widgets to. A group cannot be widened for free -- LayoutChildren
    -- sizes its children off the group's CURRENT width -- so a band built at 280
    -- and stretched by the layout pass would lay its rows out at the wrong width
    -- on the build and only correct them on the next refresh. Floored at a box's
    -- width so a page built before the content frame has a size still gets a sane
    -- container.
    local function BandWidth()
        return math.max(
            GUI.PageUsableWidth(GUI.PageChildWidth(
                GUI.contentFrame and GUI.contentFrame:GetWidth() or 0)),
            GUI.SettingsBox.group)
    end

    return {
        PopoutContent         = PopoutContent,
        RowDB                 = RowDB,
        ClaimKeys             = ClaimKeys,
        WireModifiedTick      = WireModifiedTick,
        WireFooter            = WireFooter,
        RegisterHoistedToggle = RegisterHoistedToggle,
        ReflowMounted         = ReflowMounted,
        BandWidth             = BandWidth,

        -- ☠ ONE TABLE, PASSED AT EVERY STAY-INLINE SITE. A single-option group
        -- that stays inline beside a page of bands is speaking the other visual
        -- language -- a title INSIDE a faint rectangle next to accent headers
        -- over fat row plates. bandStyle (DandersUI/Sections.lua) is the skin
        -- that settles it: the title moves out of the box and is drawn as the
        -- band's own header, and the box becomes a PopoutRow plate. Nothing
        -- inside changes. Read-only to the factory, which is what makes one
        -- shared table safe across every box on the page. Callers write
        -- `tools and tools.INLINE_BOX or nil`, so classic gets nil -- which is
        -- exactly what "no opts" already meant to CreateSettingsGroup.
        INLINE_BOX            = { bandStyle = true },
    }
end
