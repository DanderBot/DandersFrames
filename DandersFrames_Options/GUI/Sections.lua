-- ============================================================
-- SECTIONS -- DandersFrames glue only.
-- ------------------------------------------------------------
-- The body of this file moved into the shared toolkit: settings groups, the
-- info banner, the link/note flows, the section-jump notes and the game-data
-- tooltip now live in Libs\DandersUI\Sections.lua (canonical source at
-- <repo>/DandersUI/Sections.lua), published on the host as UI methods -- so
-- every `GUI:CreateSettingsGroup(...)` / `GUI:CreateInfoBanner(...)` call site
-- resolves through the host metatable exactly as before.
--
-- What is left is the pair that could NOT move:
--
-- ☠ GUI:CreateLabel is a POSITIONAL SHADOW of the pack's own UI:CreateLabel,
-- and the two return different things -- ours a self-measuring FRAME that owns
-- a wrapped FontString, the pack's a bare FontString. It stays here (like the
-- other positional shims in Compat.lua / SettingsWidgets.lua) until the ~130
-- call sites move to the opts form and the shadow can be lifted. It delegates
-- the FontString itself to GUI.CreateLabelNative so only the frame + measure
-- machinery is ours.
--
-- GUI:CreateNote returns a CreateLabel FRAME, so it is pinned here by the same
-- shadow: library code may not call the shadowed name, and the native label
-- cannot stand in for the measured frame this returns.
-- ============================================================

local DF = DandersFrames
local GUI = DF.GUI
local L = DF.L
local C_TEXT_DIM = GUI.Colors.textDim

function GUI:CreateLabel(parent, text, width, color)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width or 380, 40)

    -- ☠ CreateLabelNative, not CreateLabel: the plain name is shadowed by THIS
    -- very function, so calling it would recurse.
    local lbl = GUI.CreateLabelNative(self, frame, { text = text, color = color or C_TEXT_DIM })
    -- Anchor both top corners so the wrap width tracks the frame's width. The
    -- layout engine (settings-group LayoutChildren / page column sizing) resizes
    -- the frame to the available width, so the text now uses the full width and
    -- wraps when the window is narrow instead of overflowing/clipping at a fixed
    -- width. Standalone (un-laid-out) labels keep the frame's initial `width`.
    lbl:SetPoint("TOPLEFT", 0, -5)
    lbl:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -5)
    lbl:SetWordWrap(true)

    -- MEASURED slot height. A label is a variable-height widget, so ResolveRowHeight
    -- prefers the call-site number and falls back to preferredHeight — stamping a
    -- measured one here leaves every existing call site byte-identical while letting a
    -- NEW one omit the number entirely and get a slot that fits the text however it
    -- wraps. Hand-guessed numbers are exactly what let a 4-line blurb overlap the
    -- dropdown beneath it (Colours page, Color by Time).
    local function Remeasure()
        local h = lbl:GetStringHeight()
        if not h or h <= 0 then return false end
        local newH = math.ceil(h) + (GUI.RowHeight.labelPad or 10)
        if frame.preferredHeight == newH then return false end
        frame.preferredHeight = newH
        frame:SetHeight(newH)
        return true
    end
    -- Force the FontString to re-flow at its CURRENT width. A dual-anchored string
    -- resolves its wrap lazily, so one that was laid out before its frame reached
    -- final width keeps the old single-line layout and renders ellipsised
    -- ("Customize class colors used throughout DandersFra…") even though the frame
    -- measures a correct 260 — /df debug guiwidth reports zero suspect frames while the
    -- text is visibly truncated. Scrolling the settings window dirties it and the
    -- text snaps back, which is the tell that it is a stale layout, not a bad size.
    -- Clearing the text first matters: SetText with an unchanged string can early-out
    -- without marking the string dirty.
    local function Reflow()
        local t = lbl:GetText()
        if t and t ~= "" then
            lbl:SetText("")
            lbl:SetText(t)
        end
    end
    -- The layout engine resizes this frame to the column's available width (see the
    -- anchor note above), and GetStringHeight can return a stale single-line value until
    -- the FontString has rendered at that final width — so converge ONCE on the next
    -- frame, after LayoutChildren has run. Re-flow only when this label OWNS its slot:
    -- inside a SettingsGroup (nothing else tracks a stored height) and with no call-site
    -- number (_slotHeightExplicit, stamped by AddWidget) to override. Deliberately NOT an
    -- OnSizeChanged binding — that cascade is the Aura Designer indicator-card lockup
    -- documented on CreateInfoBanner; the cost is that a label added with no height does
    -- not re-measure if its width changes again later.
    -- ☠ Do NOT try to Reflow()+Remeasure() synchronously here to get a correct height at
    -- creation. Tried 2026-08-05 and it does not work: nothing has been drawn yet at card
    -- build time, so GetStringHeight still returns 0 whatever the wrap state. Worse, if it
    -- ever DID succeed it would make the deferred Remeasure below return false (no change),
    -- which is what arms the RelayoutHost that tells the host its slot moved — so a partial
    -- success would silently disable the correction. The converge is the mechanism; let it.
    local function Measure()
        Remeasure()
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                if not frame:IsShown() then return end
                -- Re-flow FIRST, and for EVERY label — the height converge below is
                -- gated (it only runs for labels that own their slot), but a stale
                -- wrap can strand any label, and the ones with a call-site height are
                -- exactly the ones nothing else ever touches again.
                Reflow()
                if frame.settingsGroup and not frame._slotHeightExplicit and Remeasure() then
                    GUI:RelayoutHost(frame, frame.preferredHeight)
                end
            end)
        end
    end
    Measure()

    -- A rebuilt page hides then re-shows its widgets, and a label re-shown at a width
    -- it was not laid out at comes back with the stale single-line wrap. Re-flow on the
    -- frame AFTER the show settles. Safe against the OnSizeChanged cascade that locked
    -- up the AD indicator cards: Reflow re-applies the same string and never resizes,
    -- so it cannot feed itself.
    frame:SetScript("OnShow", function()
        if C_Timer and C_Timer.After then C_Timer.After(0, Reflow) end
    end)

    -- ☠ THE FONTSTRING ITSELF, for callers that must MEASURE the wrapped text.
    -- This wrapper's own height only converges inside a settings group (see the
    -- gate on frame.settingsGroup below); a label anchored straight to a panel
    -- keeps the placeholder 40 for the life of the page, so GetHeight() on the
    -- FRAME is a hard-coded number wearing a measurement's clothes. The STRING
    -- always wraps correctly -- Reflow runs for every label -- so its
    -- GetStringHeight is the honest number, and this is how you reach it.
    -- (The Filter Designer's spell-database freshness note is the caller that
    -- needed it; calling GetStringHeight on the frame threw a nil-value error.)
    frame.fontString = lbl

    frame.SetText = function(self, newText) lbl:SetText(newText); Measure() end
    return frame
end

-- CreateNote: a lightweight LEVELLED note (NO box — that is CreateInfoBanner's
-- job) for an inline caveat/tip attached to a field or section. It is the middle
-- tier between a plain CreateLabel and a full banner.
--   opts.tone    info | caution | danger | success — tints the note from the
--                SAME palette as the banners (via ToneHex), so notes and banners
--                speak one colour language. Omit for a neutral dim note.
--   opts.prefix  optional lead word ("Note", "Warning", "Recommendation") shown
--                in the tone colour, followed by ": " and the body in dim text.
--   opts.width   wrap width.
-- Returns a CreateLabel frame, so it is a drop-in anywhere a label goes.
function GUI:CreateNote(parent, text, opts)
    opts = opts or {}
    local str
    if opts.tone and opts.prefix then
        -- Route the prefix through L so "Note"/"Tip"/etc. are localizable (the
        -- locale metatable returns the key unchanged when a locale lacks it).
        local prefix = (L and L[opts.prefix]) or opts.prefix
        str = "|c" .. self:ToneHex(opts.tone) .. prefix .. ":|r " .. text
    elseif opts.tone then
        str = "|c" .. self:ToneHex(opts.tone) .. text .. "|r"
    else
        str = text
    end
    return self:CreateLabel(parent, str, opts.width)
end
