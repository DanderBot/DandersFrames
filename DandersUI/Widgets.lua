local addonName, NS = ...
local UI = NS.__DandersUI
if not UI then return end

local S = UI._state
local P = UI._priv
local C_PANEL, C_ELEMENT, C_BORDER, C_HOVER, C_TEXT, C_TEXT_DIM =
      UI.Colors.panel, UI.Colors.element, UI.Colors.border, UI.Colors.hover, UI.Colors.text, UI.Colors.textDim
local SnapLen = UI.SnapLen
local SnapHeightEven = UI.SnapHeightEven
local CreateElementBackdrop = UI._priv.CreateElementBackdrop
local CreatePanelBackdrop = UI._priv.CreatePanelBackdrop
local StyleScrollBar = UI.StyleScrollBar
local MEDIA = UI.MEDIA

local CreateFrame, PixelUtil, GameTooltip = CreateFrame, PixelUtil, GameTooltip
local ipairs, pairs, type, format, unpack, wipe = ipairs, pairs, type, string.format, unpack, wipe
local math, tinsert, tostring, tonumber = math, table.insert, tostring, tonumber
local PlaySound, SOUNDKIT, InCombatLockdown, C_Timer = PlaySound, SOUNDKIT, InCombatLockdown, C_Timer
local strtrim, _G = strtrim, _G

-- Counterpart to ShowTooltip: hide the shared GameTooltip. Wrapped so callers
-- route through the toolkit instead of poking GameTooltip directly.
function UI:HideTooltip()
    GameTooltip:Hide()
end

-- ============================================================
-- ATTACHING a tooltip to a settings widget — ONE way, for every factory.
--
-- Three factories used to each have their own idea, and on one page the same
-- gesture did three different things:
--     checkbox   .tooltip       hover the container   ANCHOR_CURSOR
--     dropdown   .tooltip       hover the BUTTON      ANCHOR_CURSOR
--     slider     .tooltipText   hover the SLIDER      ANCHOR_RIGHT
-- Worse, on a dropdown and a slider the LABEL sits above the control, outside
-- its hit rect, so hovering the words never did anything — while on a checkbox
-- (label beside the box, inside the container) it did. Five more factories —
-- colour picker, font / texture dropdown, input, growth control — had no
-- tooltip support at all, so ~136 controls could not carry one.
--
-- The rule now: THE HIT AREA IS THE LABEL, and only the label.
--
-- ⚠ This is deliberately NOT the whole widget. The first version of this hovered
-- the control too, which is the obvious reading of "make the label work" — but a
-- cursor-anchored tooltip then sits on top of the slider or dropdown you are
-- trying to read and operate, and no amount of offsetting it fully solves that,
-- because the thing you point at IS the thing being covered. Krathe's call,
-- 2026-07-27, after trying both. Reading and adjusting are separate gestures:
-- point at the words to find out what it does, point at the control to use it.
--
-- The label is a FontString and cannot take mouse input, so each widget gets one
-- invisible frame sized to the label's own rect. That also handles a label wider
-- than its container for free (the checkbox case) — the frame follows the TEXT,
-- not the box, so there is no hit-rect arithmetic to keep in sync.
--
-- The anchor is whatever ShowTooltip defaults to — set in ONE place so no page
-- can drift. Nothing here passes an anchor, deliberately.
--
-- The spec is read AT HOVER TIME, not when it is attached — every call site
-- sets it after creation, on the container the factory returned:
--     widget.tooltip = "body"                  title = the widget's own label
--     widget.tooltip = { title=, lines=, tone= }   the full ShowTooltip shape
--     widget.tooltipText / .tooltipSubText     legacy pair, still honoured
-- ============================================================
local function ResolveTooltipSpec(widget, label)
    local t = widget.tooltip
    if type(t) == "table" then
        -- Full spec from the caller. Default the title to the label so the
        -- common case only has to say what the setting DOES.
        if t.title == nil then t.title = label end
        return t
    end
    if type(t) == "string" and t ~= "" then
        return { title = label, lines = { t } }
    end
    -- Legacy pair. Deliberately NOT re-titled from the label: these read as
    -- title-then-subtitle by design (the Frame Level explainer, the override
    -- markers), and re-titling them would change tooltips that are already
    -- correct. New code should use .tooltip.
    if widget.tooltipText then
        return {
            title = widget.tooltipText,
            lines = widget.tooltipSubText and { widget.tooltipSubText } or nil,
        }
    end
    return nil
end

--   widget       the frame the caller holds and sets .tooltip on (the container)
--   label        the default title
--   labelRegion  the label FontString — the hit frame is built over ITS rect
function UI:AttachTooltip(widget, label, labelRegion)
    local host = self
    if not labelRegion then return end

    local hit = CreateFrame("Frame", nil, widget)
    -- Two-corner anchored to the FontString, so it tracks the text if the label
    -- is ever re-set or re-fonted. The 2px vertical bleed makes a single line of
    -- small text comfortable to hit without reaching the control below it.
    hit:SetPoint("TOPLEFT", labelRegion, "TOPLEFT", 0, 2)
    hit:SetPoint("BOTTOMRIGHT", labelRegion, "BOTTOMRIGHT", 0, -2)
    hit:EnableMouse(true)
    -- Above the widget's own children so the label area wins the mouse, but it
    -- only ever covers the TEXT, so nothing clickable is behind it.
    hit:SetFrameLevel((widget:GetFrameLevel() or 0) + 5)

    hit:SetScript("OnEnter", function()
        -- ★ GAME-DATA TOOLTIPS ride the same hit frame: a widget stamped with
        -- .tooltipSpellID shows the SPELL's own tooltip (via host:ShowGameTooltip,
        -- which owns the cold-cache retry) instead of a text spec. Wanted first by
        -- the Tracked IDs rows, where two ids share one NAME and the tooltip
        -- body is the only thing that tells them apart. Duck-typed guard because
        -- ShowGameTooltip is optional and consumer-supplied; a host without it
        -- falls through to the text path.
        if widget.tooltipSpellID and host.ShowGameTooltip then
            host:ShowGameTooltip(hit, {
                spellID       = widget.tooltipSpellID,
                fallbackTitle = widget.tooltipSpellFallback,
            })
            return
        end
        local spec = ResolveTooltipSpec(widget, label)
        if spec then host:ShowTooltip(hit, spec) end
    end)
    hit:SetScript("OnLeave", function() host:HideTooltip() end)

    widget.dfTooltipHit = hit   -- exposed for a caller that needs to re-anchor it
    return hit
end

function UI:StyleButton(btn, opts)
    local host = self
    opts = opts or {}
    if opts.width or opts.height then
        btn:SetSize(opts.width or btn:GetWidth(), opts.height or btn:GetHeight())
    end
    -- Land the height on an EVEN number of device pixels, whether it came from
    -- opts or the caller sized the button itself. Buttons are chained with
    -- centre-aligning anchors (Copy <- Sync <- Reset, Clicks <- Test <- Unlock),
    -- so an odd height puts the whole row on a half pixel -- and since nothing
    -- corrects a control's position at runtime, getting the size right at
    -- construction is the only thing that keeps their edges crisp.
    -- Construction-time and once, so it cannot drive an OnSizeChanged cascade.
    local bh = btn:GetHeight()
    if bh and bh > 0 then
        local sh = SnapHeightEven(btn, bh)
        if sh and math.abs(sh - bh) > 1e-4 then btn:SetHeight(sh) end
    end
    CreateElementBackdrop(btn)  -- mixes in BackdropTemplate if needed

    -- Optional label + leading icon. opts.icon = { texture, size (14),
    -- color {r,g,b}, gap (4) }. opts.align controls layout:
    --   "center" (default) — centre the icon+label as a GROUP (text-only centres
    --     the label; icon-only centres the icon). Best for compact buttons whose
    --     width ~ their content.
    --   "left" — pin the icon at opts.leftPad (12) with the label after it. Best
    --     for wide / full-width list-style buttons, where centred content floats
    --     in a sea of empty space.
    local iconOpt = opts.icon
    local iconGap = (iconOpt and iconOpt.gap) or 4
    local iconW = (iconOpt and (iconOpt.size or 18)) or 0
    local hasText = opts.text ~= nil and opts.text ~= ""
    local align = opts.align or "center"
    local leftPad = opts.leftPad or 12
    -- Toned buttons (danger / success): neutral at rest with an accent-coloured
    -- label+icon — soft red for destructive, soft green for affirmative — plus the
    -- accent hover wash. A coloured-text button, NOT a filled CTA (the accent set
    -- below drives the hover). Mirrors each other so Delete/Save read as a pair.
    local toneLabel = (opts.tone == "danger" and { 0.9, 0.45, 0.45 })
        or (opts.tone == "success" and { 0.4, 0.85, 0.5 }) or nil

    if opts.text ~= nil then
        if not btn.Text then
            btn.Text = btn:CreateFontString(nil, "OVERLAY", opts.font or "DFFontHighlightSmall")
            -- Register it as the button's font string so the NATIVE Button:SetText
            -- / GetText keep working. Without this, a caller that relabels later
            -- (a Start/Stop or Pause/Resume toggle) silently no-ops and the button
            -- freezes on its first label -- an easy regression when converting a
            -- Blizzard-template button, which always had one.
            if btn.SetFontString then btn:SetFontString(btn.Text) end
        end
        btn.Text:SetText(opts.text)
        if toneLabel then
            btn.Text:SetTextColor(toneLabel[1], toneLabel[2], toneLabel[3])
        else
            btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        end

        -- ★ A DECLARED WIDTH IS A MINIMUM, NOT A FIXED SIZE (localisation).
        --
        -- Every `width = N` in this addon was measured against the ENGLISH label, so a
        -- longer translation overflowed its button: German "SCHLACHTZUG" in a 70px tab,
        -- "Freischalten" in an Unlock button, and ~80 more across the options addon.
        --
        -- ⚠ A NO-OP IN ENGLISH ONLY BECAUSE THE TEST BELOW IS EXACT. The English label
        -- fits the width it was designed against, so a fit test measuring what the layout
        -- actually occupies leaves it alone -- which is why this can be the default rather
        -- than opted into at 82 call sites. That guarantee is NOT free: it held only after
        -- the padding was moved out of the test (see the note there). Assume a slack
        -- allowance and this silently resizes buttons that were already correct.
        --
        -- ⚠ Deferred, because GetStringWidth() returns 0 until the font object has
        -- resolved -- measuring at construction is what collapsed the Aura Designer's
        -- "Edit in Filter Designer" link to its 10px floor. Same converge-next-frame shape
        -- as CreateLabel and CreateInfoBanner.
        --
        -- Opt out with `fitText = false` where equal widths are the POINT (a two-column
        -- grid, a row of buttons that must align); there, growing one is worse than
        -- clipping it.
        if opts.fitText ~= false then
            -- ☠ TEST "WOULD IT CLIP", THEN PAD. Do NOT add padding before the test.
            --
            -- This first shipped as `want = tw + 32` for an icon button, compared against
            -- the declared width -- which assumed every button carried ~8px of slack
            -- either side. Plenty do not: the click-casting macro row declares width 86
            -- for a 12px icon plus "Quick Macro", i.e. packed with none. So the formula
            -- grew buttons whose labels already fitted -- Import by 10 and Quick Macro
            -- by 18 -- and since that row anchors its left buttons rightward and its
            -- right buttons leftward, the two chains closed on each other and collided.
            -- The comment here claimed it was "a no-op in English by construction". It
            -- was not, and the screenshot that proved it was worth more than the claim.
            --
            -- The minimum that avoids clipping is exactly what the layout occupies:
            -- icon + gap + text. Nothing else is required, so nothing else is assumed.
            -- Padding is added only to a button that has ALREADY failed that test, where
            -- it buys breathing room instead of moving a button that was fine.
            --
            -- `opts.icon` rather than btn.Icon: the icon is attached further down this
            -- function and does not exist yet.
            local occupied = opts.icon and (iconW + iconGap) or 0
            local function FitToLabel()
                if not btn.Text then return end
                local tw = btn.Text:GetStringWidth() or 0
                -- 0 = the font object has not resolved yet. Leave the declared width and
                -- let the deferred pass settle it; never shrink to a bogus measurement.
                if tw <= 0 then return end
                local needed = math.ceil(tw) + occupied
                -- GROW ONLY, measured against the CURRENT width, so the declared value is
                -- the floor and repeated StyleButton calls (Start/Stop toggles relabel
                -- through here) cannot ratchet a button smaller mid-session.
                if needed > (btn:GetWidth() or 0) then btn:SetWidth(needed + 10) end
            end
            FitToLabel()
            -- One converge next frame, guarded so repeated styling of the same button
            -- cannot stack timers.
            if not btn._dfFitScheduled and C_Timer and C_Timer.After then
                btn._dfFitScheduled = true
                C_Timer.After(0, function()
                    btn._dfFitScheduled = nil
                    FitToLabel()
                end)
            end
        end
    end

    if iconOpt then
        btn.Icon = btn.Icon or btn:CreateTexture(nil, "OVERLAY")
        btn.Icon:SetTexture(iconOpt.texture)
        btn.Icon:SetSize(iconW, iconW)
        if iconOpt.color then
            btn.Icon:SetVertexColor(iconOpt.color.r, iconOpt.color.g, iconOpt.color.b)
        elseif toneLabel then
            btn.Icon:SetVertexColor(toneLabel[1], toneLabel[2], toneLabel[3])
        end
    end

    -- Anchor the icon/label per alignment.
    if align == "left" then
        if iconOpt then
            btn.Icon:ClearAllPoints()
            btn.Icon:SetPoint("LEFT", leftPad, 0)
        end
        if btn.Text then
            btn.Text:ClearAllPoints()
            if iconOpt then
                btn.Text:SetPoint("LEFT", btn.Icon, "RIGHT", iconGap, 0)
            else
                btn.Text:SetPoint("LEFT", leftPad, 0)
            end
        end
    else
        if btn.Text then
            btn.Text:ClearAllPoints()
            -- Offset right by half the icon+gap so the icon+label GROUP centres.
            btn.Text:SetPoint("CENTER", btn, "CENTER", (iconOpt and hasText) and (iconW + iconGap) / 2 or 0, 0)
        end
        if iconOpt then
            btn.Icon:ClearAllPoints()
            if hasText then
                btn.Icon:SetPoint("RIGHT", btn.Text, "LEFT", -iconGap, 0)
            else
                btn.Icon:SetPoint("CENTER", btn, "CENTER", 0, 0)
            end
        end
    end

    -- Hover: an accent wash via the native HIGHLIGHT layer (auto-shown on
    -- mouseover, like StyleCheckButton / the menu buttons) PLUS a darker accent
    -- border for definition. `primary` buttons additionally keep a persistent
    -- accent-tinted fill + accent border at rest. Accent = explicit opts.accent
    -- (e.g. ClickCasting green) or the mode accent (party purple / raid orange).
    local accent = opts.accent
    -- tone presets: a destructive "danger" button reuses ALL the accent
    -- machinery (hover wash, hover border, primary fill) with a fixed FF4444 red.
    -- So a plain danger button is neutral-at-rest with a red hover, and
    -- danger+primary is a filled red CTA. Fixed colour ⇒ it won't theme-track
    -- (correct — destructive red shouldn't follow the party/raid accent).
    if not accent then
        if opts.tone == "danger" then
            accent = { r = 1, g = 0.27, b = 0.27 }
        elseif opts.tone == "success" then
            accent = { r = 0.3, g = 0.8, b = 0.45 }
        end
    end
    local primary = opts.primary
    local fadeActiveText = opts.fadeActiveText
    -- Underline TAB style (opts.tab): the button is transparent (no fill/border)
    -- and its active cue is a 2px accent stripe along the bottom + an accent label
    -- (dim label when inactive). Driven by SetActive, like a toggle. Distinct from
    -- the legacy `isTab` filled-sidebar branch in restBackdrop.
    local isTabStyle = opts.tab
    -- opts.tabStripe = false: an underline tab in every other respect -- the
    -- transparent cell, the accent label, the same SetActive -- but with NO stripe
    -- of its own. For a group whose selection is carried by ONE shared bar that
    -- GLIDES between members (UI:CreateSelectionMarker) rather than N stripes
    -- switching off here and on there. Everything downstream already guards on
    -- `btn.dfTabStripe`, so a button without one is a no-op at every site.
    local wantStripe = isTabStyle and opts.tabStripe ~= false
    -- Ghost action (opts.ghost): transparent like a tab but with no underline — an
    -- accent label + faint hover wash. For quiet inline actions (e.g. "+ Add").
    local ghost = opts.ghost
    -- Persistent semantic accent (opts.tinted): the accent is meaningful and stays
    -- ON at rest — faint accent fill + accent border + accent label — rather than
    -- being a neutral button with an accent hover. For role quick-add buttons etc.
    -- where the colour IS the button's identity. Pass a fixed opts.accent.
    local tinted = opts.tinted
    -- Neutral hover (opts.hoverTone = "neutral"): the wash is the plain C_HOVER
    -- grey and the border does NOT go accent. For surfaces that are a PLACE
    -- rather than an action -- a card header, a list row -- where an accent
    -- hover would read as "this is a call to action". Card headers and dropdown
    -- rows previously hand-rolled this as an OnEnter/OnLeave SetBackdropColor
    -- swap, which duplicated the rest colours at every site.
    local neutralHover = opts.hoverTone == "neutral"
    -- opts.restBorderColor: let a consumer keep its OWN border identity at rest --
    -- e.g. an Aura/Text group card header tinted by that group's colour -- while
    -- fill, hover, selection and disabled all stay shared. Applies ONLY to the
    -- neutral rest branch; active / primary / tinted keep their accent-derived
    -- borders, so the override can't fight a state the button is in.
    local restBorder = opts.restBorderColor
    local hl = btn:GetHighlightTexture() or btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture("Interface\\Buttons\\WHITE8x8")
    hl:SetAllPoints(btn)
    btn.Highlight = hl

    if wantStripe then
        local stripe = btn:CreateTexture(nil, "OVERLAY")
        stripe:SetTexture("Interface\\Buttons\\WHITE8x8")
        stripe:SetHeight(3)
        stripe:SetPoint("BOTTOMLEFT", 0, 0)   -- full-width underline (no insets)
        stripe:SetPoint("BOTTOMRIGHT", 0, 0)
        stripe:Hide()
        btn.dfTabStripe = stripe
    end

    -- The resting backdrop the button returns to on mouse-out (and that primary
    -- buttons also wear permanently): accent-tinted for primary, the active-tab
    -- panel colour for active tabs, otherwise the neutral element colour.
    local function restBackdrop(self, a)
        if isTabStyle then
            -- Underline tab: a faint neutral cell when inactive (so every tab's
            -- bounds stay visible and the active one doesn't appear to "grow"),
            -- and a stronger accent fill when active (a held-hover highlight)
            -- beneath its stripe.
            if self.dfActive then
                self:SetBackdropColor(a.r, a.g, a.b, 0.18)
            else
                self:SetBackdropColor(1, 1, 1, 0.05)
            end
            self:SetBackdropBorderColor(0, 0, 0, 0)
            return
        end
        if ghost then
            -- Ghost action: a faint neutral cell (matching inactive tabs) with an
            -- accent label, so it sits consistently in a tab strip; the wash
            -- brightens it on hover.
            self:SetBackdropColor(1, 1, 1, 0.05)
            self:SetBackdropBorderColor(0, 0, 0, 0)
            return
        end
        if tinted then
            -- Persistent semantic accent: faint accent fill + medium accent border
            -- at rest (label/icon accent-coloured in ApplyThemeColor). Hover adds a
            -- full-accent border + the wash brightens the fill.
            self:SetBackdropColor(a.r * 0.15, a.g * 0.15, a.b * 0.15, 0.9)
            self:SetBackdropBorderColor(a.r * 0.5, a.g * 0.5, a.b * 0.5, 0.8)
            return
        end
        if self.dfActive then
            -- Selected toggle/segmented button: a subtle accent fill + a clear
            -- accent border (more than the muted hover border, but toned down from
            -- full so it doesn't read as a heavy bright outline).
            self:SetBackdropColor(a.r * 0.3, a.g * 0.3, a.b * 0.3, 1)
            self:SetBackdropBorderColor(a.r * 0.6, a.g * 0.6, a.b * 0.6, 1)
        elseif primary then
            -- Filled accent CTA: a medium accent fill with a slightly darker
            -- accent border (the same border-darker-than-fill relationship as the
            -- standard hover) so it reads like an emphasised standard button, not
            -- a dark fill ringed by a harsh bright outline.
            self:SetBackdropColor(a.r * 0.5, a.g * 0.5, a.b * 0.5, 1)
            self:SetBackdropBorderColor(a.r * 0.4, a.g * 0.4, a.b * 0.4, 1)
        elseif self.isTab and self.isActive then
            self:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 1)
            self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
        else
            self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
            if restBorder then
                self:SetBackdropBorderColor(restBorder.r or restBorder[1],
                                            restBorder.g or restBorder[2],
                                            restBorder.b or restBorder[3],
                                            restBorder.a or restBorder[4] or 1)
            else
                self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
            end
        end
    end

    -- The hover wash's colour, factored out so it can be re-resolved at HOVER time
    -- rather than only at build time. The theme listener registered below lands on
    -- the button's PARENT, and a button parented into a scroll child -- every row
    -- in the Filter Designer, the spell list, the binding editor -- hangs it on a
    -- frame no theme walk ever visits. Its wash then stays frozen at whatever the
    -- accent was when the page was built, so a raid-mode hover drew an orange
    -- border (computed live in OnEnter) over a party-blue fill. The border was
    -- always right; the wash simply wasn't asking again.
    local function applyWash(c)
        if neutralHover then
            hl:SetVertexColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 0.55)
        else
            hl:SetVertexColor(c.r, c.g, c.b, (isTabStyle or ghost) and 0.15 or 0.30)
        end
    end

    btn.ApplyThemeColor = function(c)
        applyWash(c)
        if isTabStyle then
            restBackdrop(btn, c)  -- keep the tab transparent (no fill/border)
            -- refresh the stripe colour + the active label to the new accent
            if btn.dfTabStripe then btn.dfTabStripe:SetColorTexture(c.r, c.g, c.b, 1) end
            if btn.dfActive and btn.Text then btn.Text:SetTextColor(c.r, c.g, c.b) end
        elseif ghost or tinted then
            restBackdrop(btn, c)  -- faint cell / tinted fill; accent-coloured label
            if btn.Text then btn.Text:SetTextColor(c.r, c.g, c.b) end
            if btn.Icon then btn.Icon:SetVertexColor(c.r, c.g, c.b) end  -- icon matches the accent label
        elseif primary or btn.dfActive then
            restBackdrop(btn, c)  -- refresh persistent accent
        end
    end

    -- Toggle/segmented selection: btn:SetActive(true) marks the button as the
    -- current selection (prominent accent border via restBackdrop); false returns
    -- it to its normal rest. The owning group is responsible for clearing the
    -- previously-active button. Works on any StyleButton'd button.
    btn.SetActive = function(self, active)
        self.dfActive = active and true or false
        restBackdrop(self, accent or host:GetAccent())
        if isTabStyle then
            -- Underline tab: show the accent stripe + accent label when active,
            -- dim label when inactive.
            local a = accent or host:GetAccent()
            if self.dfTabStripe then
                self.dfTabStripe:SetColorTexture(a.r, a.g, a.b, 1)
                self.dfTabStripe:SetShown(self.dfActive)
            end
            if self.Text then
                if self.dfActive then
                    self.Text:SetTextColor(a.r, a.g, a.b)
                else
                    self.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                end
            end
        end
        if fadeActiveText then
            -- Status toggles: the active fill+border carry the "on" emphasis, so
            -- the label/icon recede slightly when active (settled) and stay bright
            -- when inactive (a clearer call to action). Alpha keeps this
            -- independent of whatever colour the owner sets on the text/icon.
            local a = self.dfActive and 0.7 or 1
            if self.Text then self.Text:SetAlpha(a) end
            if self.Icon then self.Icon:SetAlpha(a) end
        end
    end

    -- Disabled / "greyed out": a dim backdrop + faint border, label/icon dimmed
    -- via alpha (keeps their own colour, just recedes), and the hover wash +
    -- border suppressed. The button stays natively enabled so a HookScript
    -- tooltip can still explain WHY it's disabled; the owner's OnClick must
    -- early-out on self.dfDisabled. SetDisabled(false) restores the normal/
    -- active/primary rest.
    btn.SetDisabled = function(self, disabled)
        disabled = disabled and true or false
        -- Idempotent: bail when the state isn't actually changing. Tab refresh
        -- paths (the Aura Designer's UpdateLayoutTabState) call SetDisabled(false)
        -- on the sub-tabs on EVERY rebuild. Re-running the enable-restore below on
        -- an already-enabled tab left the AD Effects/Layout tabs diverging from a
        -- never-disabled tab (Global) and broke their hover wash — the only code
        -- that ran on them but not on Global was this call. Skipping the no-op keeps
        -- an enabled tab identical to one SetDisabled never touched.
        if (self.dfDisabled and true or false) == disabled then return end
        self.dfDisabled = disabled
        if self.dfDisabled then
            self:SetBackdropColor(C_ELEMENT.r * 0.55, C_ELEMENT.g * 0.55, C_ELEMENT.b * 0.55, 0.6)
            self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.25)
            -- Kill the hover wash through its VERTEX alpha — the same channel
            -- ApplyThemeColor uses for the wash's rest STRENGTH. The old object-
            -- alpha toggle (hl:SetAlpha 0/1) mixed two alpha channels, so a
            -- disable->enable cycle could restore the wash at FULL strength
            -- instead of 0.30 (seen live on the Filter Designer add/rename/
            -- delete buttons when switching a preset -> a custom filter).
            local wc = accent or host:GetAccent()
            hl:SetVertexColor(wc.r, wc.g, wc.b, 0)
            if self.Text then self.Text:SetAlpha(0.35) end
            if self.Icon then self.Icon:SetAlpha(0.35) end
        else
            self.ApplyThemeColor(accent or host:GetAccent())  -- re-assert the wash's rest colour + alpha (0.30 / 0.15)
            restBackdrop(self, accent or host:GetAccent())
            if self.Text then self.Text:SetAlpha(1) end
            if self.Icon then self.Icon:SetAlpha(1) end
        end
    end
    -- The grey loop (RefreshChildStates) greys gated children via widget:SetEnabled.
    -- Native Button:SetEnabled blocks clicks but won't dim a custom-backdrop button
    -- (its backdrop/Text are custom, not native button regions), so layer a SetAlpha
    -- dim on top. We route through native + SetAlpha, NOT SetDisabled — SetDisabled
    -- stays natively clickable (it relies on an OnClick dfDisabled early-out the
    -- consumer may not have) and fights the hover wash on SetActive toggles.
    local nativeSetEnabled = btn.SetEnabled
    btn.SetEnabled = function(self, enabled)
        nativeSetEnabled(self, enabled)
        self:SetAlpha(enabled and 1 or 0.4)
    end

    btn.ApplyThemeColor(accent or host:GetAccent())
    if not accent then
        btn.UpdateTheme = function() btn.ApplyThemeColor(host:GetAccent()) end
        local root = opts.themeRoot or btn:GetParent()
        if root then
            root.ThemeListeners = root.ThemeListeners or {}
            table.insert(root.ThemeListeners, btn)
        end
    end

    -- WHAT HOVERED LOOKS LIKE — the single implementation, so the mouse and a
    -- proxying owner cannot drift apart. OnEnter/OnLeave below are thin wrappers.
    --
    -- ⚠ NO CURRENT CONSUMER. Its one caller went with a feature merge.
    -- Kept because the pattern recurs and the Lock/UnlockHighlight subtlety below
    -- is not obvious enough to want rediscovered.
    --
    -- Call btn:SetHovered(true/false) when something ELSE owns the hit area and
    -- forwards the click: a list row whose OnClick fires this button's action.
    -- The row lighting its button says "this is what clicking the row does", and
    -- it separates the button from the row's highlight by HUE, which is far more
    -- robust than the couple of hundredths of grey that sit between C_HOVER and
    -- C_ELEMENT (a dense list of hoverable rows is exactly that case).
    --
    -- ⚠ Only wire this where the owner's click REALLY performs this button's
    -- action. A control the owner does not fire must not light up with it —
    -- priming a destructive button that the row will not actually trigger is
    -- worse than the legibility problem it would be solving.
    --
    -- The wash lives on the HIGHLIGHT layer, which the client shows only for the
    -- frame under the mouse, so a proxied hover needs Lock/UnlockHighlight — it
    -- cannot just Show() the texture. The real mouseover is unaffected either
    -- way: locking an already-hovered button is a no-op, and unlocking one still
    -- under the mouse leaves the client's own highlight up.
    local function applyHoverState(self, hovered)
        if not hovered then
            if isTabStyle or ghost then return end
            if self:IsEnabled() and not self.dfDisabled then
                restBackdrop(self, accent or host:GetAccent())
            end
            return
        end
        -- Re-resolve the wash against the CURRENT theme, exactly as the border does
        -- below (see applyWash). Skipped when the caller pinned a fixed accent, and
        -- while disabled -- SetDisabled parks the wash at alpha 0 and it must stay
        -- parked, or a disabled button would light up under the mouse.
        if not accent and not self.dfDisabled then applyWash(host:GetAccent()) end
        -- tab/ghost/neutral: only the auto wash, no accent border
        if isTabStyle or ghost or neutralHover then return end
        if self:IsEnabled() and not self.dfDisabled then
            local a = accent or host:GetAccent()
            if tinted then
                self:SetBackdropBorderColor(a.r, a.g, a.b, 1)  -- full accent border on hover
            elseif self.dfActive then
                -- keep the active border on hover (the wash still brightens the
                -- fill, giving the hover cue).
                self:SetBackdropBorderColor(a.r * 0.6, a.g * 0.6, a.b * 0.6, 1)
            else
                -- border darkens to a shade of the accent; the HIGHLIGHT wash
                -- brightens the fill. The wash is translucent (0.3), so the
                -- full-opacity border still reads DARKER than the fill. Same for
                -- primary — it keeps its edge and the brightening fill is the cue.
                self:SetBackdropBorderColor(a.r * 0.4, a.g * 0.4, a.b * 0.4, 1)
            end
        end
    end

    -- The proxied entry point. Lock/Unlock is HERE and not in applyHoverState so
    -- a real mouseover never locks: a pooled button hidden mid-hover (a list
    -- refreshing under a stationary mouse) would miss its OnLeave and come back
    -- lit. An owner calling SetHovered accepts that responsibility instead and
    -- must clear it when it rebinds the row.
    function btn:SetHovered(hovered)
        -- Lock/UnlockHighlight are Button-only, and StyleButton is applied to a
        -- few plain Frames too; those still get the border half of the state.
        if self.LockHighlight then
            if hovered then self:LockHighlight() else self:UnlockHighlight() end
        end
        applyHoverState(self, hovered)
    end

    btn:SetScript("OnEnter", function(self) applyHoverState(self, true) end)
    btn:SetScript("OnLeave", function(self) applyHoverState(self, false) end)
    -- ☠ OnLeave DOES NOT FIRE FOR A BUTTON HIDDEN UNDER THE CURSOR, so a button hidden
    -- mid-hover comes back lit — stuck fill, border and text colour until you hover and
    -- leave it again. The SetHovered comment above already names this hazard; this is the
    -- half that actually clears it.
    -- Reported on a standing frame a page
    -- SetShown()s per tab and per Party/Raid switch — hover it, switch mode, and it is
    -- hidden before the mouse ever leaves (Krathe, 2026-08-09). Fixed here rather than
    -- there: nothing about it is specific to that button, and several pooled/standing
    -- buttons in this addon are shown and hidden under a stationary mouse.
    -- ⚠ HookScript, not SetScript: OnHide is a script a CALLER may already own (unlike
    -- OnEnter/OnLeave, which StyleButton owns by contract) — this composes instead of
    -- silently replacing theirs.
    btn:HookScript("OnHide", function(self) applyHoverState(self, false) end)
    return btn
end

-- ============================================================
-- A GROUP'S SELECTION MARKER
-- ------------------------------------------------------------
-- ONE accent bar for a whole group of tabs or nav rows, which GLIDES from the
-- member that was selected to the one that now is -- in place of a per-member
-- stripe that blinks off here and on there.
--
-- Why a shared bar and not N stripes, beyond the motion: two textures switching
-- in the same frame is a pair that has to be synchronised, and Lua cannot
-- observe which of the two changes the client lands first. That is the same
-- argument the settings nav's single hover PLATE was built on. A bar that only
-- ever moves has no pair, so no frame can show two markers or none.
--
-- opts:
--   axis       "x" -- an UNDERLINE spanning the member's bottom edge (a row of
--              mode tabs), or "y" -- a RAIL down its left edge (a list of nav
--              rows). Default "x".
--   thickness  the bar's short dimension. Default 3, matching the tab stripe
--              StyleButton draws when a group does NOT share one of these.
--   duration   the glide, in seconds. Default 0.12.
--   color      the resting colour; SetTo's own colour argument wins per call.
--
-- Parented to the group's CONTAINER, never to a member: it has to be able to sit
-- BETWEEN two members mid-glide, and it has to outlive any one of them being
-- re-anchored by a relayout.
--
-- marker:SetTo(target, color, instant)   glide onto `target`; nil clears it
-- marker:Clear()                         hide it (the next SetTo is instant)
-- marker:ClearIf(target)                 hide it only if it marks `target`
-- marker:GetOwner()                      the member it currently marks, or nil
--
-- ⚠ INSTANT UNLESS BOTH ENDS ARE VISIBLE. A marker with no previous member, one
-- whose previous member has since been hidden (a collapsed nav category), or one
-- that is not itself on screen, has nowhere to glide FROM -- it would sweep in
-- from a stale position, which reads worse than the blink it replaces. Passing
-- `instant` forces the same, and that is what a window that is not shown yet
-- should pass.
function UI:CreateSelectionMarker(parent, opts)
    opts = opts or {}
    local host = self
    local axis = opts.axis == "y" and "y" or "x"
    local thickness = opts.thickness or 3
    local dur = opts.duration or 0.12

    local marker = CreateFrame("Frame", nil, parent)
    -- Above the members it marks: a member's own backdrop is drawn at the
    -- container's level, and the bar rides its edge.
    marker:SetFrameLevel((parent:GetFrameLevel() or 1) + 5)
    marker:EnableMouse(false)      -- must never take a click off the tab it marks
    if axis == "x" then marker:SetHeight(thickness) else marker:SetWidth(thickness) end
    local tex = marker:CreateTexture(nil, "OVERLAY")
    tex:SetTexture("Interface\\Buttons\\WHITE8x8")
    tex:SetAllPoints(marker)
    marker.Texture = tex
    marker:Hide()

    -- The two anchors the axis implies. The bar takes the member's full length
    -- on the long axis, so it grows and shrinks with a translated label without
    -- anyone measuring anything.
    local function Place(target)
        marker:ClearAllPoints()
        if axis == "x" then
            marker:SetPoint("BOTTOMLEFT", target, "BOTTOMLEFT", 0, 0)
            marker:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", 0, 0)
        else
            marker:SetPoint("TOPLEFT", target, "TOPLEFT", 0, 0)
            marker:SetPoint("BOTTOMLEFT", target, "BOTTOMLEFT", 0, 0)
        end
    end

    -- ⚠ THE MARKER IS NOT A CHILD OF WHAT IT MARKS, so hiding that member no
    -- longer takes the bar down with it -- a per-member stripe got that for free.
    -- Collapsing the nav category the selected page lives in would otherwise
    -- leave the rail floating beside whichever row moved up into its place.
    -- Hooked once per member; the hooks only ever act while that member is still
    -- the one being marked.
    --
    -- ☠ THE OWNER IS AN UPVALUE, NOT A FIELD ON THE MARKER. Reading it back off
    -- the frame would be one more place where "has this been set" is asked of a
    -- frame -- and every consumer of this kit that runs headless answers an unset
    -- field with a truthy no-op function, so `local prev = self.owner` would hand
    -- the glide test a function to call IsShown on. Private state stays private;
    -- GetOwner is the read.
    local owner
    local hooked = {}
    local function Follow(target)
        if hooked[target] then return end
        hooked[target] = true
        target:HookScript("OnHide", function(s) if owner == s then marker:Hide() end end)
        target:HookScript("OnShow", function(s) if owner == s then marker:Show() end end)
    end

    function marker:SetTo(target, color, instant)
        if not target then return self:Clear() end
        local c = color or opts.color or host:GetAccent()
        -- The colour swaps at the START of the glide, so the bar leaves the old
        -- member already wearing the new one's accent. A party -> raid switch
        -- then reads as one movement rather than as a colour event and a
        -- position event that happen to overlap.
        if c then tex:SetColorTexture(c.r, c.g, c.b, c.a or 1) end
        local prev = owner
        owner = target
        Follow(target)
        local canGlide = not instant and prev and prev ~= target and self:IsShown()
            and prev.IsShown and prev:IsShown()
        if canGlide and UI.Fx and UI.Fx.MoveTo then
            UI.Fx.MoveTo(self, function() Place(target) end, dur)
        else
            Place(target)
        end
        self:Show()
        return self
    end

    function marker:Clear()
        if UI.Fx and UI.Fx.Cancel then UI.Fx.Cancel(self) end
        owner = nil
        self:Hide()
        return self
    end

    -- "Stop marking this one, if it is the one you are marking." For a member
    -- that is being taken out of play (a nav row disabled while an auto profile
    -- is being edited) without the group having decided what is selected instead.
    function marker:ClearIf(target)
        if target and owner == target then self:Clear() end
        return self
    end

    function marker:GetOwner() return owner end

    return marker
end
UI.CreateSelectionMarkerNative = UI.CreateSelectionMarker


function UI:CreateCloseButton(parent, opts)
    local host = self
    opts = opts or {}
    local size = opts.size or 20
    -- Rest/hover glyph colours: grey→white for dismiss, red→brighter-red for inline
    -- destructive removes. The StyleButton red wash + border is shared by both.
    local restColor  = (opts.tone == "danger") and { r = 0.9, g = 0.45, b = 0.45 } or C_TEXT_DIM
    local hoverColor = (opts.tone == "danger") and { r = 1, g = 0.4, b = 0.4 } or { r = 1, g = 1, b = 1 }
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    host:StyleButton(btn, {
        width = size, height = size,
        tone = "danger",
        icon = {
            texture = MEDIA .. "Icons\\close",
            size = math.max(8, math.floor(size * 0.55)),
            color = restColor,
        },
    })
    btn:HookScript("OnEnter", function(self) self.Icon:SetVertexColor(hoverColor.r, hoverColor.g, hoverColor.b) end)
    btn:HookScript("OnLeave", function(self) self.Icon:SetVertexColor(restColor.r, restColor.g, restColor.b) end)
    btn:SetScript("OnClick", function(self)
        if opts.onClick then opts.onClick(self) end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    -- ⚠ ACCEPTS A FULL SPEC, not just a title. This took `opts.tooltip` as a bare string
    -- and built `{ title = it }`, so EVERY caller was structurally forced into a
    -- title-only tooltip -- the house style wants a title AND a line saying what the
    -- thing does, and its sibling CreateOverrideResetButton already took both. That is
    -- an API gap rather than call-site drift, so the fix belongs here.
    --
    -- A string still means title-only, which is correct for a close button whose title
    -- already says everything ("Close", "Remove"): the house rule prefers silence to a
    -- correct-but-heavy explanation. Existing callers are unchanged.
    if opts.tooltip then
        btn:HookScript("OnEnter", function(self)
            if type(opts.tooltip) == "table" then
                host:ShowTooltip(self, opts.tooltip)
            else
                host:ShowTooltip(self, { title = opts.tooltip, lines = opts.tooltipDesc and { opts.tooltipDesc } or nil })
            end
        end)
        btn:HookScript("OnLeave", function() host:HideTooltip() end)
    end
    return btn
end

-- A bare clickable GLYPH: an icon with a hover cue and NO chrome. This is the
-- small affordance that lives inside a row or a card header -- reorder arrows, an
-- eye visibility toggle, a clear-search "x" -- where a button box would be
-- heavier than the thing it acts on.
--
-- Deliberately its own helper: StyleButton always draws chrome, and
-- CreateCloseButton is specifically the chromed "x". Before this existed, ~16
-- sites hand-rolled the same three lines (create texture, tint it dim, brighten
-- it in OnEnter and restore in OnLeave).
--
-- NOT this: a labelled row that merely CONTAINS an icon (a collapsible section
-- header with a title + chevron, a collapse bar). There the click target is the
-- whole row, not the glyph.
--
-- opts:
--   texture     icon path            tooltip / onClick
--   size        both dims (16)       width / height  -- button box, when the hit
--                                    area is deliberately bigger than the art
--   iconSize    art size (= size)    rotation  -- radians, so one arrow texture
--                                    can serve both directions
--   color       rest tint (C_TEXT_DIM)          hoverColor (white)
--
-- Returns the button with .Icon plus:
--   :SetGlyph(texture, color)  re-point the art for a state change. The colour
--       passed becomes the new REST colour, so a later OnLeave restores the
--       state rather than snapping back to the original default.
--   :SetGlyphHover(bool)  suppress the hover brighten -- an "off" state should
--       not light up under the mouse.
function UI:CreateGlyphButton(parent, opts)
    local host = self
    opts = opts or {}
    local size = opts.size or 16
    local iconSize = opts.iconSize or size

    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(opts.width or size, opts.height or size)

    local icon = btn:CreateTexture(nil, "OVERLAY")
    icon:SetSize(iconSize, iconSize)
    icon:SetPoint("CENTER", 0, 0)
    if opts.texture then icon:SetTexture(opts.texture) end
    if opts.rotation then icon:SetRotation(opts.rotation) end
    btn.Icon = icon

    local function unpackColor(c, dr, dg, db)
        if not c then return dr, dg, db end
        return c.r or c[1], c.g or c[2], c.b or c[3]
    end
    local hr, hg, hb = unpackColor(opts.hoverColor, 1, 1, 1)
    btn._glyphHover = true
    btn._glyphRest = { unpackColor(opts.color, C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b) }
    icon:SetVertexColor(unpack(btn._glyphRest))

    function btn:SetGlyph(texture, color)
        if texture then self.Icon:SetTexture(texture) end
        if color then self._glyphRest = { unpackColor(color) } end
        self.Icon:SetVertexColor(unpack(self._glyphRest))
    end

    function btn:SetGlyphHover(enabled)
        self._glyphHover = enabled and true or false
    end

    -- opts.tooltip takes EITHER a bare title string or a full ShowTooltip spec
    -- { title=, lines=, tone= }.
    --
    -- ⚠ The table form is what new call sites should use. A title on its own draws a
    -- single bold line with no description, which is not the house tooltip shape --
    -- and an icon-only button is precisely the control that cannot get away with it,
    -- because the title only restates the glyph you are already looking at.
    local function GlyphTooltipSpec()
        local t = opts.tooltip
        if type(t) == "table" then return t end
        if type(t) == "string" and t ~= "" then return { title = t } end
        return nil
    end
    btn:SetScript("OnEnter", function(self)
        if self._glyphHover then self.Icon:SetVertexColor(hr, hg, hb) end
        local spec = GlyphTooltipSpec()
        if spec then host:ShowTooltip(self, spec) end
    end)
    btn:SetScript("OnLeave", function(self)
        self.Icon:SetVertexColor(unpack(self._glyphRest))
        if opts.tooltip then host:HideTooltip() end
    end)
    if opts.onClick then
        btn:SetScript("OnClick", function(self) opts.onClick(self) end)
    end
    return btn
end

-- Shared panel/dialog root backdrop: a solid dark panel with an optional 1px
-- border. Centralises the inline SetBackdrop blocks scattered across dialogs and
-- floating panels. opts = { bgAlpha (0.95), border (true), borderColor {r,g,b,a}
-- or {r,g,b,a array} }.
function UI:CreatePanelBackdrop(frame, opts)
    opts = opts or {}
    local bg = opts.bgColor or C_PANEL
    -- A panel's border is a full-strength 1px line, where the element default is
    -- half-alpha, so the border colour is always passed explicitly rather than
    -- left to CreateElementBackdrop's default.
    local bc = opts.borderColor
    return CreateElementBackdrop(frame, {
        outline     = opts.border ~= false,
        bgColor     = { bg.r or bg[1], bg.g or bg[2], bg.b or bg[3],
                        opts.bgAlpha or bg.a or 0.95 },
        borderColor = bc and { bc.r or bc[1], bc.g or bc[2], bc.b or bc[3],
                               bc.a or bc[4] or 1 }
                          or { C_BORDER.r, C_BORDER.g, C_BORDER.b, 1 },
    })
end

-- Mover chrome: the translucent tinted plate a drag surface wears while the frames
-- are unlocked. This is a SEPARATE helper from CreateElementBackdrop, not a flag on
-- it, because a mover has the opposite job from settings chrome -- it is meant to
-- shout. Giving movers the neutral element look would be a bug, not consistency.
--
-- The hue comes from the host accent (or hooks.accentFor for a pinned pole)
-- instead of a hardcoded literal, so retheming moves the movers too.
--
-- ⚠ Which POLE is the caller choice, not the host accent, because a mover
-- belongs to the thing it moves: the raid mover must stay orange even while the
-- options window happens to be showing a party page. Pass isRaid where the site
-- knows; omit it only where the mover genuinely has no mode, and it will follow
-- the selected mode.
--
-- opts:
--   isRaid       true/false pins the pole via hooks.accentFor; omit to follow the host accent
--   color        {r,g,b} or {[1],[2],[3]} -- explicit override, for a mover whose
--                colour is a user setting rather than the theme
--   fillAlpha    default 0.30      borderAlpha  default 0.80
--   fill = false outline only      edgeSize     default 2
--
-- ⚠ NO :RefreshMoverTint(). One was defined here and documented as "call it if the
-- mode changes while a mover is shown"; nothing ever called it, in either addon. Movers
-- are rebuilt through CreateMoverBackdrop on a mode change instead, which is the same
-- work by a different route -- so the method was a second entry point to it, advertised
-- and unused. opts.color / opts.fill / opts.edgeSize are likewise never passed by any
-- of the four call sites; the defaults below are what every mover actually gets.
function UI:CreateMoverBackdrop(frame, opts)
    opts = opts or {}
    local c = opts.color
    if not c then
        if opts.isRaid ~= nil then local f = self:Hook("accentFor"); c = (f and f(opts.isRaid)) or self:GetAccent()
        else                       c = self:GetAccent() end
    end
    local r, g, b = c.r or c[1], c.g or c[2], c.b or c[3]
    CreateElementBackdrop(frame, {
        fill        = opts.fill,
        edgeSize    = opts.edgeSize or 2,
        bgColor     = { r, g, b, opts.fillAlpha or 0.30 },
        borderColor = { r, g, b, opts.borderAlpha or 0.80 },
    })
    return frame
end

-- The element backdrop, exposed to consumer files (the stylers in this file use
-- the local directly). Nothing outside should be calling SetBackdrop itself --
-- route it through here so the look, and the border mechanism, stay in one
-- place. See the local for the opts contract: fill, outline, bgColor, borderColor,
-- edgeSize and inset. (It used to list backdropEdge and omit edgeSize and inset --
-- backwards on both counts: edgeSize and inset are passed by real callers, while
-- backdropEdge is passed by none.)
function UI:CreateElementBackdrop(frame, opts)
    return CreateElementBackdrop(frame, opts)
end

-- A titled group box: the LOOK of a DandersFrames settings group (faint white
-- fill, 8% white outline, accent title, padded content) without the layout
-- engine behind it. The options addon's CreateSettingsGroup owns row stacking,
-- collapse state and grey-gating for DF's pages; this is the plain container
-- for a consumer that lays its own rows out -- it gives back a `content` frame
-- to anchor into and sizes the box around it.
--
-- opts:
--   title     header text (accent-coloured DFFontNormal; re-tints on SetAccent)
--   width     box width (280)
--   padding   inset on all four sides (UI.Space.section)
--
-- Returns the box with:
--   .title              the header FontString
--   .content            the padded inner frame; anchor rows to its TOPLEFT,
--                       width follows the box
--   :SetContentHeight(h)  size the content frame and the box around it
function UI:CreateGroupBox(parent, opts)
    local host = self
    opts = opts or {}
    local pad = opts.padding or UI.Space.section
    local titleH = UI.RowHeight.groupTitle
    local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    box:SetSize(opts.width or 280, pad * 2 + titleH)
    box.padding = pad
    -- Same fill/outline as the options addon's settings group.
    CreateElementBackdrop(box, {
        bgColor     = { 1, 1, 1, 0.03 },
        borderColor = { 1, 1, 1, 0.08 },
    })

    local title = box:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    title:SetPoint("TOPLEFT", box, "TOPLEFT", pad, -pad)
    title:SetPoint("TOPRIGHT", box, "TOPRIGHT", -pad, -pad)
    title:SetJustifyH("LEFT")
    title:SetText(opts.title or "")
    local a = host:GetAccent()
    title:SetTextColor(a.r, a.g, a.b)
    -- Accent is per host and can change for the session (DF flips it on the
    -- party/raid switch), so the title follows it like a section header does.
    --
    -- ⚠ REGISTERED AGAINST THE BOX, and kept on it. This used to hand the host a
    -- bare closure that nothing could ever take back off the listener list, so a
    -- panel that rebuilds its group boxes left one dead listener per box behind
    -- every time and SetAccent walked a list that only grew. Naming the owner
    -- makes the entry droppable -- `host:UnregisterAccentListener(box)` from a
    -- teardown path, and automatically once the box itself is collectible.
    box._accentListener = function(c) title:SetTextColor(c.r, c.g, c.b) end
    host:RegisterAccentListener(box._accentListener, box)
    box.title = title

    local content = CreateFrame("Frame", nil, box)
    content:SetPoint("TOPLEFT", box, "TOPLEFT", pad, -(pad + titleH))
    content:SetPoint("TOPRIGHT", box, "TOPRIGHT", -pad, -(pad + titleH))
    content:SetHeight(1)
    box.content = content

    function box:SetContentHeight(h)
        h = math.max(h or 0, 1)
        content:SetHeight(h)
        self:SetHeight(pad + titleH + h + pad)
    end
    return box
end


-- The addon's ONE name prompt. This was hand-rolled twice against Blizzard's
-- StaticPopup edit box — here and in the Filter Designer — each copy carrying
-- the same `self.EditBox or self.editBox or self:GetEditBox()` fallback for a
-- field name that moves between client versions. Both now come through here and
-- get toolkit chrome, so there is nothing left to keep in step.
-- opts = { title, message, default, acceptLabel, maxLetters, onAccept(text) }
function UI:PromptName(opts)
    opts = opts or {}
    self:ShowPopupInput({
        title       = opts.title,
        message     = opts.message,
        text        = opts.default or "",
        acceptLabel = opts.acceptLabel,
        maxLetters  = opts.maxLetters or 40,
        onAccept    = function(text)
            -- Trim here so every caller's uniqueness check and empty-name
            -- fallback sees the same thing.
            if opts.onAccept then opts.onAccept(strtrim(text or "")) end
        end,
    })
end






-- =========================================================================
-- OVERRIDE INDICATORS FOR AUTO PROFILES
-- =========================================================================
-- Helper function to add override indicators (star, reset button, global value text)
-- to widget containers when editing an auto profile

-- Debug flag - when true, shows all reset buttons regardless of override state
S.overrideDebugMode = false

-- Track all widgets with override indicators for refresh
local overrideWidgets = {}

-- Function to check if debug mode is active (exposed for other files)
local function IsOverrideDebugMode()
    return S.overrideDebugMode
end
UI.IsOverrideDebugMode = IsOverrideDebugMode

-- Function to refresh all override indicators
function UI:RefreshAllOverrideIndicators()
    for _, widget in ipairs(overrideWidgets) do
        if widget and widget.UpdateOverrideIndicators then
            widget:UpdateOverrideIndicators()
        end
    end
    -- A position panel and tab stars are consumer chrome; both are optional.
    if self.UpdatePositionOverrideIndicator then self.UpdatePositionOverrideIndicator() end
    self:Call("onIndicatorsRefreshed")
end

-- Allow other files to register widgets with override indicators
function UI.RegisterOverrideWidget(widget)
    table.insert(overrideWidgets, widget)
end


-- ============================================================
-- SHARED OVERRIDE CONTROLS
-- One "override active" marker (a coloured dot) + one "reset to global" button
-- (red, icon-only, danger tone — reads like the Reset Page button), so every
-- override control across the addon speaks one visual language. Callers create
-- them, position the returned frames, and toggle Show/Hide.
-- ============================================================
-- Single source of truth for the override-marker colour.
UI.OVERRIDE_MARKER_COLOR = { 1, 0.8, 0.2 }

-- A coloured dot marking "this setting is overridden". Returns a hidden Button
-- so the caller can set .tooltipText / .tooltipSubText for a hover tooltip.
-- `size` = dot diameter in px (default 12); the hit frame is a touch larger.
function UI:CreateOverrideMarker(parent, size)
    local host = self
    size = size or 12
    local c = UI.OVERRIDE_MARKER_COLOR
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(size + 6, size + 6)
    -- Only ever a hover-tooltip target; let clicks fall through so a marker
    -- placed on a clickable parent (e.g. a nav tab) doesn't eat its clicks.
    -- SetPropagateMouseClicks is PROTECTED on 12.1 (ADDON_ACTION_BLOCKED if called
    -- under combat lockdown — e.g. opening/refreshing settings in combat); skip it
    -- there. Only matters when the marker sits on a clickable parent, and combat
    -- GUI edits are the rare case.
    if btn.SetPropagateMouseClicks and not InCombatLockdown() then btn:SetPropagateMouseClicks(true) end
    local icon = btn:CreateTexture(nil, "OVERLAY")
    icon:SetPoint("CENTER")
    icon:SetSize(size, size)
    icon:SetTexture(MEDIA .. "Icons\\dot")
    icon:SetVertexColor(c[1], c[2], c[3])
    btn.icon = icon
    btn:SetScript("OnEnter", function(s)
        if s.tooltipText then
            host:ShowTooltip(s, { title = s.tooltipText, lines = s.tooltipSubText and { s.tooltipSubText } or nil })
        end
    end)
    btn:SetScript("OnLeave", function() host:HideTooltip() end)
    btn:Hide()
    return btn
end


-- A "reset to global" button — red, icon-only, danger tone (matches the Reset
-- Page button). Returns a hidden Button. opts: { size = 18, tooltip = title,
-- tooltipDesc = line, onClick = fn }.
function UI:CreateOverrideResetButton(parent, opts)
    local host = self
    opts = opts or {}
    local size = opts.size or 18
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    host:StyleButton(btn, {
        width = size, height = size,
        tone = "danger",
        icon = { texture = MEDIA .. "Icons\\refresh", size = size - 6 },
    })
    btn:Hide()
    -- StyleButton owns OnEnter (hover wash); hook the tooltip on top.
    btn:HookScript("OnEnter", function(self)
        if opts.tooltip then
            host:ShowTooltip(self, { title = opts.tooltip, lines = opts.tooltipDesc and { opts.tooltipDesc } or nil })
        end
    end)
    btn:HookScript("OnLeave", function() host:HideTooltip() end)
    if opts.onClick then btn:SetScript("OnClick", opts.onClick) end
    return btn
end

local function AddOverrideIndicators(host, container, lbl, dbKey, onReset, verticalOffset, optionsMap, dbTable)
    local L = host.hooks.L
    -- Skip for proxy tables (e.g. a designer proxy) that do not support per-key override tracking
    if dbTable and rawget(dbTable, "_skipOverrideIndicators") then return end
    verticalOffset = verticalOffset or 0
    container.overrideOptionsMap = optionsMap
    
    -- Reset button (red, icon-only) at top-right; the override marker (dot)
    -- sits to its left. Both are shared helpers (UI:CreateOverride*).
    local resetBtn = host:CreateOverrideResetButton(container, {
        tooltip = L["Reset to Global"],
        tooltipDesc = L["Reset this setting to its global value."],
        onClick = function() if onReset then onReset() end end,
    })
    resetBtn:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, verticalOffset)
    container.overrideResetBtn = resetBtn

    local starBtn = host:CreateOverrideMarker(container)
    starBtn:SetPoint("RIGHT", resetBtn, "LEFT", -2, 0)
    container.overrideStar = starBtn

    -- Global value text (shown when in edit mode) - positioned inline after label
    local globalText = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    globalText:SetPoint("LEFT", lbl, "RIGHT", 4, 0)
    globalText:SetTextColor(0.4, 0.4, 0.4)
    globalText:Hide()
    container.overrideGlobalText = globalText
    
    -- Checkmark icon for matching global value
    local checkIcon = container:CreateTexture(nil, "OVERLAY")
    checkIcon:SetSize(8, 8)
    checkIcon:SetTexture(MEDIA .. "Icons\\check")
    checkIcon:SetVertexColor(0.3, 0.7, 0.3)
    checkIcon:Hide()
    container.overrideCheckIcon = checkIcon
    
    -- Store dbKey for reference
    container.overrideDbKey = dbKey
    
    -- Function to update override indicators
    container.UpdateOverrideIndicators = function(self, currentValue)
        -- Debug mode shows all buttons
        if S.overrideDebugMode then
            self.overrideStar:Show()
            self.overrideResetBtn:Show()
            self.overrideGlobalText:SetText("(debug)")
            self.overrideGlobalText:SetTextColor(1, 0.8, 0.2)
            self.overrideGlobalText:Show()
            self.overrideCheckIcon:Hide()
            return
        end

        local state, globalValue = host:Call("getOverrideState", dbTable, dbKey)
        if not state or state == "none" then
            self.overrideStar:Hide()
            self.overrideResetBtn:Hide()
            self.overrideGlobalText:Hide()
            self.overrideCheckIcon:Hide()
            return
        end

        -- "runtime" is an overlay the user cannot reset from the control (the
        -- owning profile has to be edited), so it gets the star and the value
        -- but no reset button.
        if state == "runtime" then
            self.overrideStar.tooltipText = L["Override active"]
            self.overrideStar.tooltipSubText = L["This setting is being overridden by the active auto layout profile. To change it, edit the profile in the Auto Layouts tab."]
            self.overrideStar:Show()
            self.overrideResetBtn:Hide()
        elseif state == "overridden" then
            self.overrideStar.tooltipText = L["Override active"]
            self.overrideStar.tooltipSubText = L["This setting differs from the global profile value. Click the reset button to revert."]
            self.overrideStar:Show()
            self.overrideResetBtn:Show()
        else   -- "editing", value matches the global
            self.overrideStar:Hide()
            self.overrideResetBtn:Hide()
        end

        local globalDisplay
        if type(globalValue) == "boolean" then
            globalDisplay = globalValue and L["Yes"] or L["No"]
        elseif type(globalValue) == "number" then
            if globalValue == math.floor(globalValue) then
                globalDisplay = tostring(globalValue)
            else
                globalDisplay = format("%.2f", globalValue)
            end
        elseif type(globalValue) == "table" then
            globalDisplay = globalValue.r and L["Color"] or "..."
        elseif type(globalValue) == "string" and self.overrideOptionsMap and self.overrideOptionsMap[globalValue] then
            local mapped = self.overrideOptionsMap[globalValue]
            globalDisplay = (type(mapped) == "table" and (mapped.text or mapped.label or globalValue)) or tostring(mapped)
        else
            globalDisplay = tostring(globalValue or L["None"])
        end

        self.overrideGlobalText:SetText(format(L["(Global: %s)"], globalDisplay))
        self.overrideGlobalText:ClearAllPoints()
        self.overrideGlobalText:SetPoint("LEFT", lbl, "RIGHT", 4, 0)

        -- The check icon marks "matches the global", which is only meaningful
        -- while editing: a runtime overlay is by definition a difference.
        if state == "editing" then
            self.overrideGlobalText:SetTextColor(0.3, 0.6, 0.3)
            self.overrideCheckIcon:ClearAllPoints()
            self.overrideCheckIcon:SetPoint("LEFT", self.overrideGlobalText, "RIGHT", 2, 0)
            self.overrideCheckIcon:Show()
        else
            self.overrideGlobalText:SetTextColor(0.5, 0.5, 0.5)
            self.overrideCheckIcon:Hide()
        end
        self.overrideGlobalText:Show()
    end
    
    -- Register this widget for refresh tracking
    table.insert(overrideWidgets, container)
    
    return container
end
P.AddOverrideIndicators = AddOverrideIndicators

-- Override indicators for order list controls (drag lists)
-- These don't have traditional labels, so we use a compact star + reset + "Modified" badge
local function AddOrderListOverrideIndicators(host, container, dbKey, onReset, dbTable)
    local L = host.hooks.L
    -- Reset button (red, icon-only) + override marker (dot) — shared helpers.
    local resetBtn = host:CreateOverrideResetButton(container, {
        tooltip = L["Reset to Global Order"],
        onClick = function() if onReset then onReset() end end,
    })
    resetBtn:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 14)
    container.overrideResetBtn = resetBtn

    local starBtn = host:CreateOverrideMarker(container)
    starBtn:SetPoint("RIGHT", resetBtn, "LEFT", -2, 0)
    container.overrideStar = starBtn
    local starIcon = starBtn.icon  -- the "Modified" badge below anchors to the dot

    -- "Modified" text to the left of star
    local modifiedText = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    modifiedText:SetPoint("RIGHT", starIcon, "LEFT", -2, 0)
    modifiedText:SetText(L["Modified"])
    modifiedText:SetTextColor(1, 0.8, 0.2, 0.8)
    modifiedText:Hide()
    container.overrideModifiedText = modifiedText
    
    -- Store dbKey for reference
    container.overrideDbKey = dbKey
    
    -- Update function
    container.UpdateOverrideIndicators = function(self, currentValue)
        -- Debug mode
        if S.overrideDebugMode then
            self.overrideStar:Show()
            self.overrideResetBtn:Show()
            self.overrideModifiedText:SetText("Modified (debug)")
            self.overrideModifiedText:Show()
            return
        end
        
        local state = host:Call("getOverrideState", dbTable, dbKey)
        local on = (state == "overridden")
        self.overrideStar:SetShown(on)
        self.overrideResetBtn:SetShown(on)
        self.overrideModifiedText:SetShown(on)
        if on then
            self.overrideStar.tooltipText = L["Override active"]
            self.overrideStar.tooltipSubText = L["This setting differs from the global profile value. Click the reset button to revert."]
        end
    end

    -- Register for refresh tracking
    table.insert(overrideWidgets, container)
end
P.AddOrderListOverrideIndicators = AddOrderListOverrideIndicators

-- ============================================================
-- SHARED CHECK / RADIO LOOK — single source of truth
-- Applies the standard square look to a CheckButton: element
-- backdrop + a pixel-snapped, themed WHITE8x8 check. Every box
-- and radio (the full builders below AND the hand-rolled ones
-- elsewhere) should call this, so a restyle is ONE edit.
--   opts.size      box size (default 18)
--   opts.checkSize check-square size (default 10)
--   opts.accent    fixed tint {r,g,b} — e.g. ClickCasting's green.
--                  Omit to follow the party/raid theme (and auto-
--                  register a theme listener on opts.themeRoot).
--   opts.themeRoot frame whose .ThemeListeners drive recolor
--                  (default the button's parent); only used when
--                  no accent is given.
-- Returns the check texture (also stored as cb.Check).
-- ============================================================
function UI:StyleCheckButton(cb, opts)
    local host = self
    opts = opts or {}
    PixelUtil.SetSize(cb, opts.size or 18, opts.size or 18)
    CreateElementBackdrop(cb)

    local check = cb.Check or cb:CreateTexture(nil, "OVERLAY")
    check:SetTexture("Interface\\Buttons\\WHITE8x8")
    local cs = opts.checkSize or 10
    PixelUtil.SetSize(check, cs, cs)
    PixelUtil.SetPoint(check, "CENTER", cb, "CENTER", 0, 0)

    local accent = opts.accent
    local col = accent or host:GetAccent()
    cb.Check = check
    -- Native checkboxes let WoW show/hide the check via the checked state; a few
    -- consumers (and plain Button-based pseudo-checkboxes) drive it manually via
    -- cb.Check:SetShown(). opts.manualCheck supports those without SetCheckedTexture.
    if opts.manualCheck then
        check:Hide()
    else
        cb:SetCheckedTexture(check)
    end

    -- Hover feedback: a subtle accent wash on the native HIGHLIGHT layer. WoW
    -- shows it on mouseover automatically, so it works regardless of any OnEnter
    -- the consumer sets (no clobbering), and it doesn't recolor the 1px border
    -- (which can render unevenly at fractional UI scales).
    local hl = cb:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture("Interface\\Buttons\\WHITE8x8")
    hl:SetAllPoints(cb)
    cb.Highlight = hl

    -- Single source for the themed tint: check colour + hover-wash strength.
    -- Consumers that drive their own theme refresh call cb.ApplyThemeColor(c) too,
    -- so the wash alpha (0.35) is defined in exactly one place.
    cb.ApplyThemeColor = function(c)
        check:SetVertexColor(c.r, c.g, c.b)
        hl:SetVertexColor(c.r, c.g, c.b, 0.35)
    end
    cb.ApplyThemeColor(col)

    if not accent then
        cb.UpdateTheme = function()
            cb.ApplyThemeColor(host:GetAccent())
        end
        local root = opts.themeRoot or cb:GetParent()
        if root then
            root.ThemeListeners = root.ThemeListeners or {}
            table.insert(root.ThemeListeners, cb)
        end
    end
    return check
end


-- ============================================================
-- SEGMENT TOGGLE
-- A compact segmented control: the labels sit ON the buttons, all
-- of them boxed inside one recessed track so the pair reads as a
-- single control rather than two loose buttons. This is the
-- "Border Mode: [Shared][Custom]" idiom (AuraDesigner/Options.lua)
-- with the track added; use it for short mutually-exclusive values
-- that want to sit next to the field they qualify (s / %).
--
-- API: UI:CreateSegmentToggle(parent, segments, dbTable, dbKey, callback, opts)
--   segments : ordered { value =, label =, tooltip = } — label is what
--              shows on the button, tooltip the full name behind a terse one
--   opts.segmentWidth (26) / opts.height (18)
--   opts.fallbackValue : treated as selected when the stored value matches
--              no segment, so an unset key still lights the right button
--   opts.customGet / opts.customSet : same convention as CreateCheckbox /
--              CreateSlider / CreateDropdown — for a toggle over TRANSIENT UI
--              state (or one with its own save path) rather than a db key. Pass
--              dbTable/dbKey as nil when using these.
-- Returns the container with :Refresh(), :refreshContent() and :SetEnabled().
-- ============================================================


-- ============================================================
-- DEBUG CATEGORY ROW
-- A wide row with checkbox + bold category name + description.
-- The whole row is clickable, hover shows a background highlight,
-- and the description is also surfaced as a tooltip on hover so it
-- remains accessible even if it gets visually truncated.
--
-- Used by a Debug > Categories sub-tab. The categoryKey writes
-- directly to the consumer's own debug filter table.
-- ============================================================

-- The one input "well": translucent-black fill + dim edge. Shared by StyleEditBox
-- (the single-line field) and CreateTextArea (the scrolling multi-line container)
-- so a text area and a text field read as the same control at two sizes. Passed
-- straight to CreateElementBackdrop, which only reads them.
local INPUT_FILL = { 0, 0, 0, 0.5 }
local INPUT_EDGE = { 0.3, 0.3, 0.3, 1 }

-- StyleEditBox: normalize a bare (label-less) EditBox to the standard input
-- chrome used by CreateInput/CreateEditBox — translucent-black fill + dim border
-- + standard font/insets. The caller still owns size/position/scripts. Pass
-- opts.skipFont to keep a custom font (e.g. multi-line / monospace inputs).
function UI:StyleEditBox(eb, opts)
    opts = opts or {}
    CreateElementBackdrop(eb, {
        bgColor     = INPUT_FILL,
        borderColor = INPUT_EDGE,
    })
    if not opts.skipFont then
        eb:SetFontObject(DFFontHighlightSmall)
        eb:SetTextInsets(5, 5, opts.multiline and 5 or 0, opts.multiline and 5 or 0)
    end
    -- Multiline mode: for text areas (export/import blobs, macro bodies). The
    -- caller owns the ScrollFrame/sizing; this just flags the editbox + relaxes
    -- the vertical insets. Enter inserts a newline (no auto clear-focus).
    if opts.multiline then
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
    end
    return eb
end



-- ============================================================
-- LEADING ICON INSIDE AN EDIT BOX
-- The search-bar look from the main addon search (Features/Search.lua), made
-- available to any CreateEditBox rather than re-rolled per search field: the
-- glyph, the same 0.72 grey, and — the part that is easy to forget — the text
-- inset AND the placeholder both moved clear of it, so neither the typed text
-- nor the "Search..." hint runs underneath the icon.
--
-- Pass frame.EditBox, not the frame.
-- ============================================================

-- ============================================================
-- TEXT AREA — the multi-line cousin of CreateEditBox
-- A bordered well holding a scrolling multi-line EditBox. Eight surfaces built
-- this same container + ScrollFrame + EditBox stack by hand (export/import blobs,
-- the debug log viewer and script runner, the macro body, the popup's input mode,
-- the changelog), each picking its own well colour and three of them forgetting
-- the click-to-focus, so clicking the empty space below the text did nothing.
-- One owner, and the same well as every single-line input.
--
-- opts:
--   width, height        size the well; omit and anchor it yourself
--   text                 initial contents
--   fontObject           default DFFontHighlightSmall
--   fontSize, fontFlags  use the settings font at a size instead of a font object
--   maxLetters
--   readOnly             show-and-copy (export strings, the changelog): user
--                        edits bounce back, but it stays selectable + copyable
--   autoFocus            take focus and select all on creation (copy-me popups)
--   onTextChanged(text, userInput)
--   onEscape(editBox)    default: clear focus
--   bgColor, borderColor override the standard input well
--   plain                skip the well entirely — for a text area that fills a
--                        surface which already has its own panel (the changelog)
--   insets               text insets, default 4
-- Returns the well, with .EditBox / .ScrollFrame and SetText / GetText /
-- HighlightText / SetFocus / ClearFocus / SetEnabled forwarded to the field.
-- ============================================================
local TEXTAREA_PAD    = 4    -- gap between the well's edge and the scroll frame
local TEXTAREA_GUTTER = 18   -- room right of the scroll for the themed scrollbar

function UI:CreateTextArea(parent, opts)
    opts = opts or {}

    local well = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    if opts.width and opts.height then well:SetSize(opts.width, opts.height) end
    local pad = opts.plain and 0 or TEXTAREA_PAD
    if not opts.plain then
        CreateElementBackdrop(well, {
            bgColor     = opts.bgColor or INPUT_FILL,
            borderColor = opts.borderColor or INPUT_EDGE,
        })
    end

    local scroll = CreateFrame("ScrollFrame", nil, well, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", pad, -pad)
    scroll:SetPoint("BOTTOMRIGHT", -(pad + TEXTAREA_GUTTER), pad)
    StyleScrollBar(scroll)

    local eb = CreateFrame("EditBox", nil, scroll)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    if opts.fontSize then
        self:SetSettingsFont(eb, opts.fontSize, opts.fontFlags or "")
    else
        eb:SetFontObject(opts.fontObject or DFFontHighlightSmall)
    end
    eb:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    local inset = opts.insets or (opts.plain and 0 or TEXTAREA_PAD)
    eb:SetTextInsets(inset, inset, inset, inset)
    if opts.maxLetters then eb:SetMaxLetters(opts.maxLetters) end
    eb:SetScript("OnEscapePressed", opts.onEscape or function(s) s:ClearFocus() end)
    scroll:SetScrollChild(eb)

    -- A scroll child has to be told its size, and that is only known once the
    -- well has been sized or its anchors have resolved — which for an anchored
    -- (rather than SetSize'd) well is not this frame. So do it here AND on every
    -- resize, which is also what lets a text area sit in a resizable window
    -- without the caller re-setting the width by hand on every show.
    --
    -- Height is seeded ONCE and then left alone: after that the field owns it,
    -- growing its own rect as text is added, which is what makes the scroll
    -- frame scroll. Re-seeding on resize would clamp a grown field back down.
    local heightSeeded = false
    local function SyncSize(w, h)
        if w and w > 0 then eb:SetWidth(w) end
        if h and h > 0 and not heightSeeded then
            heightSeeded = true
            eb:SetHeight(h)
        end
    end
    scroll:SetScript("OnSizeChanged", function(_, w, h) SyncSize(w, h) end)
    SyncSize(scroll:GetWidth(), scroll:GetHeight())

    -- Clicking anywhere in the well lands in the field, not just on the text
    -- itself — the contents rarely fill the box.
    well:EnableMouse(true)
    well:SetScript("OnMouseDown", function() eb:SetFocus() end)
    scroll:EnableMouse(true)
    scroll:SetScript("OnMouseDown", function() eb:SetFocus() end)

    well.EditBox, well.ScrollFrame = eb, scroll
    well.GetText       = function(_) return eb:GetText() end
    well.HighlightText = function(_, ...) eb:HighlightText(...) end
    well.SetFocus      = function(_) eb:SetFocus() end
    well.ClearFocus    = function(_) eb:ClearFocus() end
    well.SetText       = function(_, text)
        eb:SetText(text or "")
        eb:SetCursorPosition(0)   -- long blobs open at the top, not the tail
    end

    -- Grey-when-disabled, per the GUI conventions: dim the whole widget AND stop
    -- it accepting edits.
    well.SetEnabled = function(self, enabled)
        self:SetAlpha(enabled and 1 or 0.4)
        eb:SetEnabled(enabled)
    end

    -- WoW has no read-only EditBox. Bouncing the text back on any USER change
    -- keeps Ctrl+A / Ctrl+C working, which EnableKeyboard(false) would not.
    if opts.readOnly then
        local locked = opts.text or ""
        eb:SetScript("OnTextChanged", function(s, user)
            if user and s:GetText() ~= locked then
                s:SetText(locked)
                s:HighlightText()
            end
        end)
        well.SetText = function(_, text)
            locked = text or ""
            eb:SetText(locked)
            eb:SetCursorPosition(0)
        end
    elseif opts.onTextChanged then
        eb:SetScript("OnTextChanged", function(s, user)
            opts.onTextChanged(s:GetText(), user)
        end)
    end

    if opts.text then well:SetText(opts.text) end
    if opts.autoFocus then
        eb:SetAutoFocus(true)
        eb:SetFocus()
        eb:HighlightText()
    end

    return well
end

-- PREVIEW vs COMMIT -- the two halves of a drag, and which opt is which.
-- ------------------------------------------------------------
-- A drag is a stream of values the user is still choosing between, ending in
-- ONE value they chose. Those are different events and they get different
-- callbacks (the same split Cell draws between its onValueChangedFn and
-- afterValueChangedFn):
--
--   opts.lightweight   PREVIEW. Runs only while the bar is being dragged, at
--                      most once per rendered frame, and only when the snapped
--                      value actually moved. Make it cheap and make it about
--                      the one property the slider changes.
--   opts.onChanged     COMMIT. Runs ONCE, on release -- and once on a typed
--                      value in the box. NEVER per drag tick.
--
-- The db write is NOT part of that split: the bound value is written on every
-- tick, exactly as before, so anything that reads the setting mid-drag sees the
-- live number. Only the WORK moves.
--
-- ⚠ A slider with no `lightweight` previews NOTHING during a drag except its own
-- value readout. It does not fall back to onChanged or to the refresh hook --
-- a per-tick full settings sweep is the cost this split exists to remove. Give
-- a slider a lightweight if its drag should be visible.
--
-- ⚠ The whole split needs a host that publishes `onDragStart`. A host without
-- one (a consumer that does not care about drag cost) gets the older behaviour
-- unchanged: refresh + onChanged on every value change.
--
-- opts:
--   label                       min, max, step        REQUIRED
--   get() -> value / set(value) the value binding; omit both for a read-only bar
--   onChanged()                 COMMIT callback -- release and typed entry only
--   lightweight()               PREVIEW callback -- per rendered frame, drag only
--   previewMode                 DEPRECATED and consumed by nothing. Still passed
--                               through to hooks.onDragStart for signature
--                               compatibility; deleted next minor. Do not add
--                               new call sites.
--   accent {r,g,b}              pinned accent instead of the host one
--   tooltip                     as before, read at hover time off the container
--   dbRef = { db, key }         optional settings metadata. A slider WITHOUT it
--                               never calls getOverrideState / interceptWrite /
--                               onSettingWritten / registerSearch, so a consumer
--                               with no settings hooks gets a plain slider and
--                               none of the indicator machinery.
function UI:CreateSlider(parent, opts)
    local host = self
    opts = opts or {}
    local label = opts.label or ""
    local minVal, maxVal, step = opts.min or 0, opts.max or 1, opts.step or 1
    local callback = opts.onChanged
    local lightweightUpdate = opts.lightweight
    local usePreviewMode = opts.previewMode
    local accentColor = opts.accent
    local customGet, customSet = opts.get, opts.set
    local dbTable = opts.dbRef and opts.dbRef.db or nil
    local dbKey = opts.dbRef and opts.dbRef.key or nil
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 50)
    container.preferredHeight = UI.RowHeight.slider   -- factory-owned slot height (see UI.RowHeight)
    container.rowKind = "slider"
    container.fixedRowHeight = true
    
    -- Label
    local lbl = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    -- Add override indicators if dbKey is provided (for auto profiles)
    -- Use vertical offset of 6 to align with label row (sliders have input box below)
    if dbKey and type(dbKey) == "string" then
        local function onReset()
            local globalVal = host:Call("resetOverride", dbTable, dbKey)
            if globalVal ~= nil then
                -- Update slider display
                if container.slider then
                    container.slider:SetValue(globalVal)
                end
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(globalVal)
                end
                host:Call("refreshNow")
            end
        end
        AddOverrideIndicators(host, container, lbl, dbKey, onReset, 6, nil, dbTable)
    end

    -- Background track.
    -- Left edge and height here; the RIGHT edge is pinned to the value box further
    -- down, once that exists. The track used to be a fixed 180px while a dropdown
    -- anchors TOPLEFT+TOPRIGHT and fills its container, so on any panel wider than
    -- the 260 default the two controls ended at visibly different x positions --
    -- and drifted further apart the wider the panel got. Both are container-driven
    -- now, so they line up at any width instead of at one magic number.
    local track = CreateFrame("Frame", nil, container, "BackdropTemplate")
    track:SetPoint("TOPLEFT", 0, SnapLen(track, -18) or -18)
    track:SetHeight(SnapLen(track, 8) or 8)
    CreateElementBackdrop(track)
    
    -- Fill track (colored portion)
    local fill = track:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("LEFT", 1, 0)
    fill:SetHeight(6)
    local c = accentColor or host:GetAccent()
    fill:SetColorTexture(c.r, c.g, c.b, 0.8)
    
    -- Slider
    local slider = CreateFrame("Slider", nil, container)
    -- Same snapped offset/height as the track it sits on, or the invisible hit
    -- area drifts off the visible bar by a fraction of a pixel.
    slider:SetPoint("TOPLEFT", 0, SnapLen(slider, -18) or -18)
    slider:SetHeight(SnapLen(slider, 8) or 8)   -- right edge pinned to the value box, same as the track
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)
    slider:SetHitRectInsets(-4, -4, -8, -8)
    container.slider = slider  -- Store reference for reset
    
    -- Track whether this slider is actively being dragged.
    -- ⚠ ALSO THE COMMIT-ONCE FLAG. The release path clears it FIRST, so a stolen
    -- mouseup and the real OnMouseUp that follows it cannot both commit.
    local isDragging = false

    -- Does this consumer take part in the preview/commit split at all? Answered
    -- from the host's hooks, which are fixed at NewHost time, so this is read
    -- once. A host with no onDragStart (DandersMover, say) never learns a drag is
    -- happening, so a deferred commit would simply never arrive -- those hosts
    -- keep the older per-change behaviour.
    local hasDragHooks = host:Hook("onDragStart") ~= nil

    -- The snapped value written this tick, and the one the last preview ran for.
    local pendingValue, lastPreviewed = nil, nil

    -- Store preview mode flag for this slider (deprecated -- see the opts block)
    local sliderUsePreviewMode = usePreviewMode or false
    
    -- Thumb
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(12, 16)
    thumb:SetColorTexture(c.r, c.g, c.b, 1)
    slider:SetThumbTexture(thumb)
    
    -- Value input
    local input = CreateFrame("EditBox", nil, container, "BackdropTemplate")
    input:SetSize(50, 20)
    -- Pinned to the container's RIGHT edge -- the same edge a dropdown's opener
    -- ends on -- and the track/slider then stretch from the left to meet it.
    -- y = -12 keeps the 20px box centred on the 8px track at -18.
    input:SetPoint("TOPRIGHT", 0, -12)
    track:SetPoint("RIGHT", input, "LEFT", -8, 0)
    slider:SetPoint("RIGHT", input, "LEFT", -8, 0)
    CreateElementBackdrop(input)
    input:SetFontObject(DFFontHighlightSmall)
    input:SetJustifyH("CENTER")
    input:SetAutoFocus(false)
    input:SetTextInsets(2, 2, 0, 0)
    
    -- The drag bubble's repaint, forward-declared: UpdateFill is the one place
    -- every path that moves the bar goes through (a drag tick, a typed value, a
    -- panel resize), so the bubble rides it rather than being poked from four
    -- call sites. Assigned further down, once FormatValue exists -- the guard
    -- covers the initial UpdateValue that runs before then.
    --
    -- Takes (pct, usable) so the caller that already has them does not make it
    -- measure the track a second time; both are optional and it measures for
    -- itself when they are absent (ShowBubble's opening repaint).
    local RefreshBubble

    local function UpdateFill()
        local val = slider:GetValue()
        local pct = (val - minVal) / (maxVal - minVal)
        -- Measured off the LIVE track, not the old hardcoded 178 (= the fixed 180
        -- track minus the fill's 1px inset each side). The track stretches now, so
        -- a constant here would under-fill on any panel wider than the default.
        local usable = (track:GetWidth() or 0) - 2
        if usable < 1 then usable = 1 end
        fill:SetWidth(math.max(1, pct * usable))
        -- HANDED the two numbers it would otherwise measure for itself. The
        -- bubble's clamp asks exactly the question this just answered, and a
        -- second `track:GetWidth()` per drag tick is the same arithmetic twice.
        if RefreshBubble then RefreshBubble(pct, usable) end
    end
    -- The track's width is only known once the page layout has resolved its
    -- anchors, and changes again if the panel is resized -- so repaint the fill
    -- whenever it does, or the bar renders at its pre-layout width.
    track:SetScript("OnSizeChanged", function() UpdateFill() end)
    
    container.SetEnabled = function(self, enabled)
        slider:SetEnabled(enabled)
        -- Grey the numeric value box too: it was only EnableMouse'd (clicks blocked
        -- but still full-bright + typeable), so it stayed lit while the track dimmed.
        input:EnableMouse(enabled)
        input:SetEnabled(enabled)
        input:SetAlpha(enabled and 1 or 0.4)
        local tc = accentColor or host:GetAccent()
        if enabled then
            lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            thumb:SetColorTexture(tc.r, tc.g, tc.b, 1)
            fill:SetColorTexture(tc.r, tc.g, tc.b, 0.8)
        else
            lbl:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            thumb:SetColorTexture(0.4, 0.4, 0.4, 1)
            fill:SetColorTexture(0.4, 0.4, 0.4, 0.5)
        end
    end
    
    -- Tint to an EXPLICIT colour. The same published name StyleButton and
    -- StyleCheckButton use, so anything driving a scoped repaint -- a popout
    -- cascading its own accent into the widgets mounted in it -- has one entry
    -- point across the kit. A slider built with its own accentColor still wins:
    -- that colour is the call site's choice, not something it inherited.
    container.ApplyThemeColor = function(c)
        local nc = accentColor or c
        if nc and slider:IsEnabled() then
            thumb:SetColorTexture(nc.r, nc.g, nc.b, 1)
            fill:SetColorTexture(nc.r, nc.g, nc.b, 0.8)
        end
    end
    -- ⚠ TAKES NO ARGUMENTS, and must not start: several call sites reach this
    -- through COLON syntax (`slider:UpdateTheme()`), which would hand a colour
    -- parameter the widget table itself. UpdateTheme means "repaint to the host
    -- accent"; ApplyThemeColor is the one that takes a colour.
    container.UpdateTheme = function()
        container.ApplyThemeColor(host:GetAccent())
    end
    if not parent.ThemeListeners then parent.ThemeListeners = {} end
    table.insert(parent.ThemeListeners, container)
    
    local suppressCallback = false
    
    -- Smart format: show whole numbers as integers, decimals with minimum precision needed
    local function FormatValue(val)
        if val == math.floor(val) then
            return string.format("%d", val)
        elseif val * 10 == math.floor(val * 10) then
            return string.format("%.1f", val)
        else
            return string.format("%.2f", val)
        end
    end
    
    -- ============================================================
    -- THE DRAG BUBBLE
    -- ------------------------------------------------------------
    -- While the bar is HELD, a small readout floats over the thumb and moves with
    -- it. The number in it is the same number the value box shows -- FormatValue,
    -- the one function -- so the two can never disagree about how many decimals a
    -- 0.05-step bar has.
    --
    -- Why it is worth having when the box already shows the value: the box is at
    -- the far RIGHT of the row and the thumb can be anywhere along it, so reading
    -- a drag means looking away from what you are doing. The bubble puts the
    -- number where the eye already is.
    --
    -- ⚠ BUILT ON THE FIRST DRAG, not at construction. A settings page is hundreds
    -- of rows and almost none of them are ever dragged; a bubble per slider up
    -- front is a frame and a font string each for nothing.
    --
    -- ⚠ NEVER TAKES THE MOUSE. It sits directly over the bar being dragged, so
    -- mouse input on it would be input stolen from the gesture that summoned it.
    --
    -- ⚠ FIXED WIDTH, sized once to the widest value the bar can show. WoW has no
    -- tabular-figure font object, so digits are NOT equal width and a box that
    -- fitted its text would breathe in and out on every tick -- far more
    -- distracting than the number it is showing. A fixed box with centred text is
    -- the achievable half of tabular numbers.
    --
    -- `lastText` is the string the font string is currently holding, kept in step
    -- with it from the moment it is first written, and compared before every
    -- write: SetText re-measures and re-lays a font string whether or not the
    -- characters changed, and a slow drag on a wide bar spends most of its ticks
    -- on the same snapped value.
    local bubble, lastText
    local function EnsureBubble()
        if bubble then return bubble end
        bubble = CreateFrame("Frame", nil, container, "BackdropTemplate")
        bubble:EnableMouse(false)
        bubble:SetFrameLevel((container:GetFrameLevel() or 0) + 10)
        CreateElementBackdrop(bubble)     -- the kit's own element fill + border
        bubble.Text = bubble:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        bubble.Text:SetPoint("CENTER", 0, 0)
        bubble.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        -- The widest thing it will ever have to hold: the longer of the two ends,
        -- plus the decimals a sub-1 step introduces between them (a 0..1 bar at
        -- step 0.05 formats its ENDS as "0" and "1" and its middle as "0.65").
        local sample = FormatValue(maxVal)
        if #FormatValue(minVal) > #sample then sample = FormatValue(minVal) end
        if step < 1 then sample = sample .. ".00" end
        bubble.Text:SetText(sample)
        lastText = sample          -- the cache starts out TRUE, not merely unset
        bubble:SetSize(math.max(28, math.ceil(bubble.Text:GetStringWidth() or 0) + 10), 16)
        bubble:Hide()
        container.dragBubble = bubble     -- exposed for the tests and for a consumer
        return bubble
    end

    -- Where it sits: ANCHORED TO THE THUMB, once, and then LEFT ALONE. WoW moves
    -- the thumb itself as the value changes and the layout engine carries
    -- anything anchored to it along for free -- so the common case, a bar being
    -- dragged through the middle of its range, costs ZERO anchor calls per tick.
    --
    -- ☠ THIS IS THE JITTER FIX, AND RE-ANCHORING PER TICK IS WHAT IT REPLACES.
    -- The first cut of this recomputed an x off the fill arithmetic and issued
    -- ClearAllPoints + SetPoint on EVERY drag tick. Two costs, both real:
    --   * the bubble is a backdrop frame with a pixel border, so it carries six
    --     anchored regions -- a fill, four border strips and the font string --
    --     and dirtying its rect made the layout engine re-solve all six, inside
    --     the same frame that was already writing the fill and the value box;
    --   * that x was a FLOAT, so the box landed on a fresh sub-pixel offset every
    --     tick and shimmered against the bar it was sitting on top of.
    -- Riding the thumb's own (already snapped, already solved) position removes
    -- both at once, and it is robust to the pixel snapping on the track offsets
    -- in a way a hardcoded -12 could never be.
    --
    -- The CLAMP is all that is left to decide, and it is a three-state machine
    -- rather than a per-tick number: free (on the thumb), or pinned half a box
    -- inside one container edge. Without it a bar at either end pushes half the
    -- box outside the settings group, where the page's scroll frame clips it.
    -- Anchors are only re-issued when the state CHANGES -- twice in a drag that
    -- sweeps the whole bar, never in one that does not reach an end.
    --
    -- Track-left IS container-left (the track is anchored TOPLEFT 0), which is
    -- what lets one x answer "would it overhang".
    local bubbleAnchor, bubbleClampX

    local function PlaceBubble(pct, usable)
        if not bubble then return end
        local span = maxVal - minVal
        if span <= 0 then
            pct = 0
        elseif not pct then
            pct = (slider:GetValue() - minVal) / span
        end
        if not usable then
            usable = (track:GetWidth() or 0) - 2
            if usable < 1 then usable = 1 end
        end
        local half = (bubble:GetWidth() or 0) / 2
        local cw = container:GetWidth() or 0
        local x = 1 + pct * usable
        local want, wx = "thumb", nil
        if cw > half * 2 then
            if x < half then want, wx = "left", half
            elseif x > cw - half then want, wx = "right", cw - half end
        end
        -- ⚠ THE CLAMP COORDINATE IS PART OF THE STATE, not just the state name.
        -- A panel resized while the bubble is pinned to an edge moves that edge,
        -- and a comparison on the name alone would leave the box behind.
        if want == bubbleAnchor and wx == bubbleClampX then return end
        bubbleAnchor, bubbleClampX = want, wx
        bubble:ClearAllPoints()
        if want == "thumb" then
            bubble:SetPoint("BOTTOM", thumb, "TOP", 0, 2)
        else
            -- The SAME height the thumb path resolves to, DERIVED rather than
            -- written down: the 16px thumb centres on the slider's (pixel-
            -- snapped) height, so its top sits (16 - h) / 2 above the slider's,
            -- and the bubble rides 2 above that. The hardcoded -12 this replaces
            -- was only right while SnapLen left the track on exactly -18/8, and
            -- being right by coincidence is how a box develops a half-pixel hop
            -- the moment it clamps.
            --
            -- Anchored off the SLIDER, not the container, for the same reason --
            -- but the x still reads as a container offset, because the slider is
            -- pinned to the container's TOPLEFT and the two left edges are one.
            local h = slider:GetHeight() or 8
            bubble:SetPoint("BOTTOM", slider, "TOPLEFT", wx, (16 - h) / 2 + 2)
        end
    end

    RefreshBubble = function(pct, usable)
        if not (bubble and bubble:IsShown()) then return end
        local s = FormatValue(slider:GetValue())
        if s ~= lastText then
            lastText = s
            bubble.Text:SetText(s)
        end
        PlaceBubble(pct, usable)
    end

    local function ShowBubble()
        local b = EnsureBubble()
        if UI.Fx and UI.Fx.Cancel then UI.Fx.Cancel(b) end   -- a fade-out still running
        b:Show()
        b:SetAlpha(1)
        RefreshBubble()
    end

    -- Fades rather than blinking out: the release is the end of a gesture, and a
    -- readout that vanishes on the same frame as the mouseup reads as a glitch.
    -- Via Fx so a second drag started inside the fade cancels it (ShowBubble
    -- above) instead of racing the deferred Hide.
    local function HideBubble()
        if not (bubble and bubble:IsShown()) then return end
        if UI.Fx and UI.Fx.FadeOut then
            UI.Fx.FadeOut(bubble, 0.15, function() bubble:Hide() end)
        else
            bubble:Hide()
        end
    end

    -- Wrapper for both pathways: customGet/Set when provided, dbTable[dbKey]
    -- otherwise. Centralising this avoids a sprinkling of `if customGet then`
    -- across every place the slider touches its value.
    local function ReadValue()
        if customGet then return customGet() end
        if dbTable then return dbTable[dbKey] end
        return nil
    end
    local function WriteValue(v)
        if customSet then return customSet(v) end
        if dbTable then dbTable[dbKey] = v end
    end

    local function UpdateValue(val)
        val = val or minVal
        suppressCallback = true
        slider:SetValue(val)
        suppressCallback = false
        input:SetText(FormatValue(val))
        UpdateFill()
        -- Update override indicators
        if container.UpdateOverrideIndicators then
            container:UpdateOverrideIndicators(val)
        end
    end
    
    -- Re-read the bound value (customGet or dbTable[dbKey]) and redraw. For a slider whose
    -- source can change under it — e.g. one bound through customGet to whichever key an
    -- account-wide unit dial currently selects — called from refreshContent.
    container.RefreshValue = function(self)
        local v = ReadValue()
        if v ~= nil then UpdateValue(math.max(minVal, math.min(maxVal, v))) end
    end
    -- Runtime range. A slider whose UNIT is decided elsewhere (seconds vs percent) is built
    -- once but must re-scale in place, or flipping that dial leaves a 1-60 track in front of
    -- a percentage until the panel is rebuilt. Pair with container.label for the caption.
    container.SetRange = function(self, newMin, newMax)
        if newMin ~= minVal or newMax ~= maxVal then
            minVal, maxVal = newMin, newMax
            slider:SetMinMaxValues(minVal, maxVal)
        end
        self:RefreshValue()
    end

    -- The end of a drag, from either door: the real OnMouseUp, or the OnUpdate
    -- noticing the button is no longer held (see OnDragUpdate).
    --
    -- ORDER MATTERS. isDragging is cleared FIRST -- it is the commit-once flag,
    -- and a stolen mouseup followed by the real OnMouseUp must produce one
    -- commit, not two. Then the host's drag bookkeeping is released (that call
    -- is pure bookkeeping now: nothing applies from it), then the commit runs,
    -- then the generic full sweep. `refreshNow` is the sweep every other widget
    -- asks for; the consumer is free to coalesce it with whatever onChanged
    -- already scheduled.
    local function ReleaseDrag()
        if not isDragging then return end
        isDragging = false
        slider:SetScript("OnUpdate", nil)
        pendingValue, lastPreviewed = nil, nil
        HideBubble()

        host:Call("onDragStop")
        if callback then callback() end
        host:Call("refreshNow")

        -- Update override indicators after drag ends
        if container.UpdateOverrideIndicators then
            container:UpdateOverrideIndicators(slider:GetValue())
        end
    end

    -- The preview pump. One of these per rendered frame while the bar is held,
    -- which is the whole point: OnValueChanged can fire many times inside one
    -- frame and none of them do any work now.
    local function OnDragUpdate()
        -- ☠ IsMouseButtonDown IS RESOLVED AS A GLOBAL, AT CALL TIME -- the same
        -- shape ApplyScheduler uses for InCombatLockdown, and for the same
        -- reason. A file-scope alias would freeze whatever the global was at
        -- load, and a stub that answers `false` would end every drag on its
        -- first frame. A NIL global means "cannot ask" (headless, or a client
        -- that does not publish it) and the check is SKIPPED rather than read as
        -- a release.
        if isDragging and IsMouseButtonDown and not IsMouseButtonDown("LeftButton") then
            -- The mouseup went somewhere else -- another frame took it, or the
            -- cursor left the window. Treat it as the release it was.
            ReleaseDrag()
            return
        end
        if pendingValue ~= nil and pendingValue ~= lastPreviewed then
            lastPreviewed = pendingValue
            if lightweightUpdate then lightweightUpdate() end
        end
    end

    -- Track drag start - pass the lightweight update function, name for debug, and preview mode
    slider:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            isDragging = true
            -- Up before anything else in the gesture: the bar has already jumped
            -- to where it was pressed, so the readout should be there with it.
            -- Kit-wide, so every consumer's sliders get it (the mover's included).
            ShowBubble()
            local funcName = lightweightUpdate and ((dbKey or label or "slider") .. " lightweight") or nil
            host:Call("onDragStart", lightweightUpdate, funcName, sliderUsePreviewMode)
            if hasDragHooks then
                pendingValue, lastPreviewed = nil, nil
                slider:SetScript("OnUpdate", OnDragUpdate)
            end
        end
    end)

    -- Track drag end - commit once when the slider is released
    slider:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        if hasDragHooks then
            -- A no-op if OnDragUpdate already released on a stolen mouseup.
            ReleaseDrag()
            return
        end
        -- LEGACY HOST (no onDragStart hook): unchanged from before the split --
        -- every value change already committed on its own, so there is nothing
        -- to do here but the bookkeeping and the indicators.
        if isDragging then
            isDragging = false
            HideBubble()
            host:Call("onDragStop")
            -- Update override indicators after drag ends
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(slider:GetValue())
            end
        end
    end)

    -- ☠ A DRAG THAT IS HIDDEN MID-GESTURE STILL HAS TO RELEASE. The host's drag
    -- state is a REFCOUNT now, so a start with no matching stop does not clear
    -- itself the next time some other slider is released -- it pins "a drag is
    -- in progress" on for the rest of the session. A page switch under a held
    -- bar (rare, but a keybind can do it) stops the OnUpdate, so the stolen-
    -- mouseup door above cannot answer for this one.
    --
    -- Bookkeeping ONLY, deliberately: no onChanged, no refreshNow. The db was
    -- written on every tick, and whatever hid the slider is rebuilding the page
    -- anyway; firing a settings commit out of a page teardown would be a
    -- surprise the user never asked for.
    slider:SetScript("OnHide", function()
        if isDragging then
            isDragging = false
            slider:SetScript("OnUpdate", nil)
            pendingValue, lastPreviewed = nil, nil
            host:Call("onDragStop")
        end
        -- ...and the bubble goes down INSTANTLY, outside the isDragging guard.
        -- A fade is an animation on a frame whose ancestor is being torn down, and
        -- the deferred Hide at the end of it would land on a page that has already
        -- been rebuilt -- which is how a readout gets stranded over a row that no
        -- longer has a slider under it.
        if bubble and bubble:IsShown() then
            if UI.Fx and UI.Fx.Cancel then UI.Fx.Cancel(bubble) end
            bubble:Hide()
        end
    end)

    slider:SetScript("OnShow", function()
        local v = ReadValue()
        if v ~= nil then UpdateValue(v) end
    end)

    slider:SetScript("OnValueChanged", function(self, value)
        if suppressCallback then return end
        if not (dbTable or customSet) then return end
        if step >= 1 then
            value = math.floor(value + 0.5)
        else
            value = math.floor(value / step + 0.5) * step
        end

        -- Runtime override protection: redirect to baseline, skip refresh
        if dbKey and host:Call("interceptWrite", dbTable, dbKey, value) then
            if not input:HasFocus() then input:SetText(FormatValue(value)) end
            UpdateFill()
            if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators(value) end
            return
        end

        WriteValue(value)

        -- If editing a profile, also set the override
        if dbKey then host:Call("onSettingWritten", dbTable, dbKey, value) end
        
        if not input:HasFocus() then
            input:SetText(FormatValue(value))
        end
        UpdateFill()

        -- DRAGGING: the value is now written (above) and the readout is current,
        -- and that is ALL this tick does. No refresh, no callback -- the preview
        -- is pumped once per rendered frame from OnDragUpdate and the commit
        -- happens once, on release.
        --
        -- ⚠ The old code called `refresh` here on every tick AND skipped the
        -- callback "because it will run via UpdateAll on release" -- which it
        -- never did: nothing on the release path called it. That is the bug this
        -- split fixes, and it is why onChanged now fires from ReleaseDrag.
        if hasDragHooks and isDragging then
            pendingValue = value
            return
        end

        -- NOT dragging (a programmatic SetValue -- the override reset above is
        -- one), or a host that does not publish drag hooks: commit per change,
        -- exactly as before.
        host:Call("refresh")
        if callback and not host:Call("isDragging") then
            callback()
        end
    end)
    
    input:SetScript("OnEnterPressed", function(self)
        local val = tonumber(self:GetText())
        if val then
            val = math.max(minVal, math.min(maxVal, val))

            -- Runtime override protection: redirect to baseline, skip refresh
            if dbKey and host:Call("interceptWrite", dbTable, dbKey, val) then
                self:SetText(FormatValue(val))
                suppressCallback = true
                slider:SetValue(val)
                suppressCallback = false
                UpdateFill()
                if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators(val) end
                self:ClearFocus()
                return
            end

            WriteValue(val)
            suppressCallback = true
            slider:SetValue(val)
            suppressCallback = false

            -- Update input text to show actual value entered
            self:SetText(FormatValue(val))
            UpdateFill()

            -- If editing a profile, also set the override
            if dbKey then host:Call("onSettingWritten", dbTable, dbKey, val) end

            -- Update override indicators
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(val)
            end

            -- A TYPED VALUE IS A COMMIT, so it runs onChanged -- once -- and
            -- nothing else.
            --
            -- ⚠ NO lightweight fallback here any more (it used to run when
            -- onChanged was absent). `lightweight` is the PREVIEW callback now:
            -- it exists to make a drag visible cheaply, and a slider that only
            -- has one is a slider whose full apply is the refreshNow below.
            -- Falling back to it would run a partial update in place of a
            -- complete one.
            if callback then
                callback()
            end

            -- Guaranteed full update (SetValue may not fire OnValueChanged if value didn't change)
            host:Call("refreshNow")
        else
            local v = ReadValue(); if v ~= nil then UpdateValue(v) end
        end
        self:ClearFocus()
    end)

    input:SetScript("OnEscapePressed", function(self)
        local v = ReadValue(); if v ~= nil then UpdateValue(v) end
        self:ClearFocus()
    end)

    local initial = ReadValue()
    if initial ~= nil then UpdateValue(initial) end
    
    -- SEARCH: Register this setting with slider metadata
    if dbKey and type(dbKey) == "string" then
        -- The hook is optional: a host with no search index supplies no
        -- registerSearch and this block is a no-op.
        host:Call("registerSearch", "slider", label, dbKey, container, { minVal = minVal, maxVal = maxVal, step = step, callback = callback })
    end
    
    -- Expose label for dynamic updates
    container.label = lbl

    -- Tooltip: shared attach on the LABEL only (see UI:AttachTooltip). Keeping it
    -- off the bar matters most here — a tooltip over a slider you are dragging is
    -- the worst case of the problem. Both .tooltip (title from the label) and the
    -- legacy .tooltipText/.tooltipSubText pair are honoured.
    host:AttachTooltip(container, label, lbl)

    return container
end

UI.CreateSliderNative = UI.CreateSlider




-- ============================================================
-- OPEN-MENU REGISTRY
-- Dropdown/preset menus anchor to their button and survive context switches
-- that leave the button visible (e.g. the Aura Designer changing tabs).
-- Every menu frame registers here at creation; CloseAllMenus() lets a
-- context switch dismiss whatever is open.
-- ============================================================
UI._menus = UI._menus or {}
function UI:RegisterMenu(frame) UI._menus[frame] = true end

-- The strata a dropdown menu floats on by default: high enough to clear the page
-- it was opened from, and below TOOLTIP so GameTooltip still shows over it.
local MENU_STRATA = "FULLSCREEN_DIALOG"

-- ☠ AT LEAST THE OPENER'S STRATA, not a fixed one.
--
-- A menu must draw over the thing it was opened from, full stop. Nailing it to
-- FULLSCREEN_DIALOG delivered that for as long as every opener sat below
-- FULLSCREEN_DIALOG, and that stopped being true: a popout docked OUTSIDE a
-- window takes one strata ABOVE that window's (see Popout.lua's OUTSIDE_LEVEL),
-- so a dropdown inside a popout docked off a FULLSCREEN_DIALOG window would be
-- forced DOWN, behind the very panel it belongs to.
--
-- TOOLTIP is the only strata above FULLSCREEN_DIALOG, so the check is that one
-- name rather than a ladder. The popout's raise caps there for the same reason.
--
-- Called at creation AND on every open: the opener's strata is not settled at
-- creation, because a pooled popout is raised when it is Follow'd -- long after
-- the widgets inside it were built.
--
-- The level only moves if it has to. A menu is created as a CHILD of its opener
-- and so already outranks it; this is the backstop for one that has ended up
-- level with or under the opener, not a level it is handed every time.
local function RaiseMenuOverOpener(menu, opener)
    local want = MENU_STRATA
    if opener.GetFrameStrata and opener:GetFrameStrata() == "TOOLTIP" then
        want = "TOOLTIP"
    end
    -- Unconditional, even when the menu already reads as `want`: setting it is what
    -- PINS the strata, so the menu keeps it if the popout around it later drops
    -- back to DIALOG. A read-first guard would leave that case merely inheriting.
    menu:SetFrameStrata(want)
    local ol = opener.GetFrameLevel and opener:GetFrameLevel() or 0
    if (menu:GetFrameLevel() or 0) <= ol then menu:SetFrameLevel(ol + 1) end
end

-- ☠ Lives with the registry it iterates, deliberately. This was in a consumer
-- for a while, which left the pack able to REGISTER a menu but not close one --
-- and CreateDropdown below does register. Nothing broke, because one caller
-- lived in the pack and one in a consumer, but a bulk "dismiss whatever is
-- open" call that is nil half the time fails SILENTLY: the menu just stays
-- floating, which is the exact symptom this registry exists to prevent. Four
-- lines is not worth an addon boundary.
-- ☠ THE ONLY RELIABLE CLOSER, and why the single-slot tracker is not.
-- Every menu is parented to its own dropdown BUTTON, so a tab switch hides it via its
-- ancestor. That fires the menu's OnHide, which clears S.currentOpenDropdown -- but the
-- menu's OWN shown flag was never touched, so returning to that tab re-shows it, now
-- untracked. From then on CloseOpenDropdown() is a no-op against it: it stays floating,
-- overlaps whatever you open next, and only closes if you click its own button
-- (Krathe, 2026-08-09 -- all three dropdown symptoms are this one fault).
-- ⇒ Iterating the registry and calling Hide() clears the frame's own flag, which
-- ancestor-hiding never does. Prefer this over CloseOpenDropdown at every open site.
function UI:CloseAllMenus()
    for f in pairs(UI._menus) do
        if f:IsShown() then f:Hide() end
    end
    -- Keep the single-slot tracker honest: it is still read by the toggle handlers, and a
    -- stale reference here is what made a re-shown menu invisible to them.
    S.currentOpenDropdown = nil
end

-- One corner picker standing in for TWO Start/End dropdowns that were really two axes
-- of a single question: which corner of the reserved area does the block sit in?
--
-- ☠ WHY THIS EXISTS, so it does not get "simplified" back into two dropdowns.
-- The grouped raid box had "Groups Grow From" (Left/Center/Right) and "Row Order"
-- (Top/Bottom) three controls apart, in two different vocabularies. Nobody read them as
-- one thing, and Row Order in particular reads as a sequencing control while in the
-- common configuration it only moves the block to the other end of the reserved space.
-- Field-reported twice (Aphoex 2026-08-14, Krathe 2026-08-17).
--
-- keyH takes START/CENTER/END, keyV takes START/END -- hence 3x2, not 3x3. Giving the
-- vertical axis a CENTER means teaching all three positioners a CENTER branch for the
-- row index; until that exists, do not add a middle row here.
--
-- opts.verticalInertFn: return true when the vertical axis cannot do anything (a single
-- row of groups). The bottom cells grey and the top row reads as selected.
-- ⚠ It NEVER writes the key. A UI fallback that persists its own display value is a
-- silent second migration -- the stored END must survive being temporarily meaningless,
-- or lowering Groups Before Wrap would not restore what the user picked.
-- opts: label, getH/setH, getV/setV, onChanged, dbRef = { db, keyH, keyV },
--       plus transposedFn, verticalInertFn, wrapMirroredFn unchanged (each is
--       called with the db, which may be nil for a getter-only consumer).
function UI:CreateAnchorGrid(parent, opts)
    local host = self
    local L = host.hooks.L
    opts = opts or {}
    local label = opts.label or ""
    local callback = opts.onChanged
    local dbTable = opts.dbRef and opts.dbRef.db or nil
    local keyH = opts.dbRef and opts.dbRef.keyH or nil
    local keyV = opts.dbRef and opts.dbRef.keyV or nil
    local getH = opts.getH or function() return dbTable and dbTable[keyH] end
    local getV = opts.getV or function() return dbTable and dbTable[keyV] end
    local setH = opts.setH or function(v) if dbTable then dbTable[keyH] = v end end
    local setV = opts.setV or function(v) if dbTable then dbTable[keyV] = v end end
    local CELL_W, CELL_H, GUTTER = 34, 18, 2
    -- ☠ THE TWO KEYS SWAP SCREEN AXES WITH THE GROWTH DIRECTION. Do not hard-code one
    -- key to the columns. keyH (the ALIGN key, 3 values) moves things along the axis the
    -- groups run down; keyV (the WRAP key, 2 values) moves them along the axis the grid
    -- wraps on -- and which of those is left/right versus up/down flips:
    --   Columns growth: groups run ACROSS, so align = Left/Center/Right, wrap = Top/Bottom
    --   Rows growth:    groups run DOWN,   so align = Top/Center/Bottom, wrap = Left/Right
    -- Verified in the positioners, not inferred: the vertical arm computes
    -- `yOff = (totalHeight - rcH) + …` from groupAnchor and `rcX = xStart + rcIdx * …`
    -- from the row-growth key, i.e. exactly the transpose of the horizontal arm. Shipping
    -- this hard-coded made "Top right" drive bottom-right in Rows mode (Krathe,
    -- 2026-08-17). opts.transposedFn returns true when the grid must be drawn 2 wide x 3
    -- tall instead of 3 wide x 2 tall.
    local ALIGN = { "START", "CENTER", "END" }
    local WRAP  = { "START", "END" }
    -- Caption words, indexed [vertical][horizontal]. CENTER on the vertical axis only
    -- occurs transposed, and vice versa, but the table carries all nine so neither
    -- orientation can fall through to an empty string.
    local CAPTION = {
        START  = { START = L["Top Left"],    CENTER = L["Top Center"],    END = L["Top Right"] },
        CENTER = { START = L["Center Left"], CENTER = L["Center"],        END = L["Center Right"] },
        END    = { START = L["Bottom Left"], CENTER = L["Bottom Center"], END = L["Bottom Right"] },
    }
    -- When the wrap axis is inert there is only one real choice being made, so the caption
    -- names just that one. "Top center" at 8 groups before wrap described a corner that
    -- does not exist -- it is simply Center.
    local SOLO = {
        [false] = { START = L["Left"], CENTER = L["Center"], END = L["Right"] },
        [true]  = { START = L["Top"],  CENTER = L["Center"], END = L["Bottom"] },
    }

    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, UI.RowHeight.anchorgrid)
    container.rowKind = "anchorgrid"
    container.fixedRowHeight = true

    local lbl = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    container.label = lbl

    local transposed = opts.transposedFn and opts.transposedFn(dbTable) or false
    local COLS = transposed and WRAP or ALIGN
    local ROWS = transposed and ALIGN or WRAP

    -- ⚠ The slot height follows the ROW COUNT, which the transpose changes (2 rows one way,
    -- 3 the other). UI.RowHeight.anchorgrid is the untransposed case; the factory still
    -- owns the number, it just cannot be a single constant. The page rebuilds on a growth
    -- direction change, so this is only ever evaluated at construction.
    local gridH = #ROWS * CELL_H + (#ROWS + 1) * GUTTER
    local rowH = 16 + gridH + UI.RowGap
    container:SetHeight(rowH)
    container.preferredHeight = rowH

    local grid = CreateFrame("Frame", nil, container, "BackdropTemplate")
    grid:SetSize(#COLS * CELL_W + (#COLS + 1) * GUTTER, gridH)
    grid:SetPoint("TOPLEFT", 0, SnapLen(grid, -16) or -16)
    CreateElementBackdrop(grid)

    local caption = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    caption:SetPoint("LEFT", grid, "RIGHT", 8, 0)
    caption:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    local cells = {}
    for r, vy in ipairs(ROWS) do
        for c, vx in ipairs(COLS) do
            local btn = CreateFrame("Button", nil, grid, "BackdropTemplate")
            host:StyleButton(btn, { width = CELL_W, height = CELL_H })
            btn:SetPoint("TOPLEFT", grid, "TOPLEFT",
                GUTTER + (c - 1) * (CELL_W + GUTTER), -(GUTTER + (r - 1) * (CELL_H + GUTTER)))
            -- SCREEN position of the cell. The align half is also the key value; the wrap
            -- half is not, because it can be mirrored -- see WrapKey below.
            btn.vx, btn.vy = vx, vy
            btn.align = transposed and vy or vx
            btn.screenWrap = transposed and vx or vy
            btn:SetScript("OnClick", function(self)
                if container.wrapInert and self.screenWrap == "END" then return end
                -- Two keys, each through the SAME plumbing CreateDropdown gives one key:
                -- a raid-mode runtime override redirects the write to the baseline and
                -- skips the live refresh; an editing session records the override; a
                -- plain write lands in the db. Per key, because one of the pair may be
                -- overridden while the other is not.
                local liveWrite = container:WriteKey(keyH, self.align)
                if not container.wrapInert then
                    liveWrite = container:WriteKey(keyV, container:WrapKey(self.screenWrap)) or liveWrite
                end
                container:Refresh()
                container:UpdateOverrideIndicatorsBoth()
                if liveWrite and callback then callback() end
            end)
            cells[#cells + 1] = btn
        end
    end

    -- ☠ THE WRAP AXIS CAN BE MIRRORED, AND THE FIX IS HERE, NOT IN THE POSITIONERS.
    -- Players Grow From = End anchors each group to the FAR corner and measures the wrap
    -- offset back from it (BOTTOMLEFT with +yOff horizontally, TOPRIGHT with -xOff
    -- vertically), so the stored wrap value lands on the opposite side of the screen from
    -- the one it names. The align axis is untouched -- both arms measure it from the same
    -- edge whatever Players Grow From says.
    -- The obvious fix, decoupling them in the positioners, MOVES EXISTING PEOPLE'S FRAMES
    -- and is therefore off the table. So the grid speaks SCREEN POSITION and translates:
    -- same geometry, same keys, same saved values, honest picker. This is an involution,
    -- so one function converts in both directions.
    function container:WrapKey(v)
        if opts.wrapMirroredFn and opts.wrapMirroredFn(dbTable) then
            return v == "START" and "END" or "START"
        end
        return v
    end

    function container:Refresh()
        self.wrapInert = opts.verticalInertFn and opts.verticalInertFn(dbTable) or false
        local curAlign = getH() or "START"
        local curWrap  = getV() or "START"
        -- Display-only collapse: a stored value stays stored, it just cannot be shown.
        local shownWrap = self.wrapInert and "START" or self:WrapKey(curWrap)
        -- ⚠ HIDDEN, not dimmed. These cells are empty rectangles, so a 0.35 alpha on a dark
        -- panel is nearly indistinguishable from a live one -- the dead half read as
        -- selectable and got clicked. Hiding is also the honest picture: at 8 groups before
        -- wrap there IS only one row of slots, so the control should show one row.
        -- ⚠ Mouse state folds in SetEnabled: RefreshChildStates calls SetEnabled and THEN
        -- refreshContent, so a Refresh that re-armed every live cell undid the grey-out
        -- and left a 0.4-alpha grid fully clickable.
        local enabled = self.enabled ~= false
        for _, b in ipairs(cells) do
            local dead = self.wrapInert and b.screenWrap == "END"
            b:SetShown(not dead)
            b:SetActive(not dead and b.align == curAlign and b.screenWrap == shownWrap)
            b:EnableMouse(enabled and not dead)
        end
        -- Shrink the recessed track to the cells that remain, or it frames a phantom row.
        local liveCols = (self.wrapInert and transposed) and 1 or #COLS
        local liveRows = (self.wrapInert and not transposed) and 1 or #ROWS
        grid:SetSize(liveCols * CELL_W + (liveCols + 1) * GUTTER,
                     liveRows * CELL_H + (liveRows + 1) * GUTTER)
        -- The caption names the SCREEN position, so it reads off the row/column the live
        -- cell actually sits in -- never off the keys, which swap axes when transposed.
        if self.wrapInert then
            caption:SetText(SOLO[transposed][curAlign] or "")
        else
            local vy = transposed and curAlign or shownWrap
            local vx = transposed and shownWrap or curAlign
            caption:SetText((CAPTION[vy] and CAPTION[vy][vx]) or "")
        end
    end
    container.refreshContent = function(self) self:Refresh() end

    container.SetEnabled = function(self, enabled)
        self.enabled = enabled and true or false
        self:SetAlpha(enabled and 1 or 0.4)
        for _, b in ipairs(cells) do b:EnableMouse(self.enabled and not (self.wrapInert and b.screenWrap == "END")) end
    end

    -- One db write with the auto-profile plumbing every other helper has. Returns true
    -- when the value reached the LIVE table (the caller then refreshes frames); false
    -- when a raid-mode runtime override redirected it to the baseline, where a live
    -- refresh would only repaint the unchanged overlay.
    function container:WriteKey(key, value)
        if dbTable and host:Call("interceptWrite", dbTable, key, value) then
            return false
        end
        if key == keyH then setH(value) else setV(value) end
        if dbTable then host:Call("onSettingWritten", dbTable, key, value) end
        return true
    end

    -- Override indicators (star / reset / global value), one set PER KEY: the align key
    -- on the container itself (reset at the container's top-right, global text after
    -- the title), the wrap key on a small host just left of it (global text after the
    -- corner caption). Both register with RefreshAllOverrideIndicators through
    -- AddOverrideIndicators, so profile edits and runtime overlays light them like any
    -- dropdown's.
    local vHost
    if dbTable and keyH and keyV then
        vHost = CreateFrame("Frame", nil, container)
        vHost:SetSize(40, 16)
        vHost:SetPoint("TOPRIGHT", container, "TOPRIGHT", -44, 0)
        local function resetKey(indHost, key)
            return function()
                local v = host:Call("resetOverride", dbTable, key)
                if v == nil then return end
                container:Refresh()
                if indHost.UpdateOverrideIndicators then indHost:UpdateOverrideIndicators(key == keyH and getH() or getV()) end
                if callback then callback() end
            end
        end
        local alignWords = { START = SOLO[transposed].START, CENTER = SOLO[transposed].CENTER, END = SOLO[transposed].END }
        local wrapWords  = { START = L["Start"], END = L["End"] }
        AddOverrideIndicators(host, container, lbl, keyH, resetKey(container, keyH), 6, alignWords, dbTable)
        AddOverrideIndicators(host, vHost, caption, keyV, resetKey(vHost, keyV), 0, wrapWords, dbTable)
    end
    function container:UpdateOverrideIndicatorsBoth()
        if self.UpdateOverrideIndicators then self:UpdateOverrideIndicators(getH()) end
        if vHost and vHost.UpdateOverrideIndicators then vHost:UpdateOverrideIndicators(getV()) end
    end

    -- Tooltip: shared attach on the LABEL only (see UI:AttachTooltip), matching every
    -- other labelled factory. Hovering the cells themselves must stay quiet -- six of them
    -- popping the same tooltip would fight the click target.
    host:AttachTooltip(container, label, lbl)

    container.UpdateTheme = function() container:Refresh() end
    if not parent.ThemeListeners then parent.ThemeListeners = {} end
    table.insert(parent.ThemeListeners, container)

    container:Refresh()
    return container
end

UI.CreateAnchorGridNative = UI.CreateAnchorGrid

-- opts: label, options, get, set, onChanged, tooltip, dbRef = { db, key },
--       plus the display flags carried through unchanged: accent, inline,
--       optionsFunc, searchable, menuAlign, onRuntimeWrite.
function UI:CreateDropdown(parent, opts)
    local host = self
    local L = host.hooks.L
    opts = opts or {}
    local label = opts.label or ""
    local options = opts.options or {}
    local callback = opts.onChanged
    local customGet, customSet = opts.get, opts.set
    local dbTable = opts.dbRef and opts.dbRef.db or nil
    local dbKey = opts.dbRef and opts.dbRef.key or nil
    local accentColor = opts.accent
    local optionsFunc = opts.optionsFunc

    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, opts.inline and 24 or 50)
    -- Inline dropdowns embed in a caller-managed layout (label hidden), so only the standalone
    -- form owns a fixed slot height; inline keeps whatever height its host passes.
    if not opts.inline then
        container.preferredHeight = UI.RowHeight.dropdown   -- factory-owned slot (see UI.RowHeight)
        container.rowKind = "dropdown"
        container.fixedRowHeight = true
    end

    -- Label
    local lbl = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    -- Expose label so helpers like AddSectionNewBadge can anchor a badge to it.
    container.label = lbl
    if opts.inline then
        lbl:Hide()
    end
    
    -- Add override indicators if dbKey is provided (for auto profiles)
    if dbKey and type(dbKey) == "string" then
        local function onReset()
            local globalVal = host:Call("resetOverride", dbTable, dbKey)
            if globalVal ~= nil then
                if container.UpdateText then
                    container:UpdateText()
                end
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(globalVal)
                end
                host:Call("refreshNow")
            end
        end
        AddOverrideIndicators(host, container, lbl, dbKey, onReset, 6, options, dbTable)
    end

    -- Button - use relative anchoring so it resizes with container
    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    if opts.inline then
        -- Fill the container so the caller's SetSize(w, h) controls the opener
        -- size + vertical centering (inline callers add their own left label and
        -- size the container to match the surrounding row, e.g. 140x18 / 110x16).
        btn:SetAllPoints(container)
    else
        local dY = SnapLen(btn, -16) or -16
        btn:SetPoint("TOPLEFT", 0, dY)
        btn:SetPoint("TOPRIGHT", 0, dY)
        btn:SetHeight(SnapLen(btn, 24) or 24)
    end
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
    arrow:SetTexture(MEDIA .. "Icons\\expand_more")
    arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    -- SetDisplayOverride: a fixed opener caption that wins over the selected
    -- option's text (e.g. a disabled dropdown explaining WHY it's disabled,
    -- like the Aura Designer spec dropdown's "shared across specs" state).
    -- nil clears the override and restores the selected option's text.
    local displayOverride
    local function UpdateText()
        if displayOverride then
            btn.Text:SetText(displayOverride)
            return
        end
        if customGet or (dbTable and dbKey) then
            -- Not `customGet and customGet() or dbTable[dbKey]`: a get that
            -- legitimately answers nil (nothing selected yet) must NOT fall
            -- through to a dbTable this dropdown may not have.
            local val
            if customGet then val = customGet()
            elseif dbTable and dbKey then val = dbTable[dbKey] end
            local displayVal = options[val]
            -- Handle table format: {value = X, text = "text"} or {text = "text"}
            local optColor
            if type(displayVal) == "table" then
                optColor = displayVal.color
                displayVal = displayVal.text or displayVal.label or tostring(val)
            end
            -- val can be nil now (see above); tostring(nil) would caption the
            -- opener with the literal word "nil".
            btn.Text:SetText(displayVal or (val ~= nil and tostring(val)) or L["Select..."])
            -- Selected label mirrors its option row's colour when the option
            -- carries one (e.g. class-coloured specs); plain options reset to
            -- the standard text colour. Skipped while disabled so the
            -- grey-when-disabled treatment from SetEnabled stays intact.
            if btn:IsEnabled() then
                local tc = optColor or C_TEXT
                btn.Text:SetTextColor(tc.r, tc.g, tc.b)
            end
            -- Update override indicators
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(val)
            end
        end
    end
    container.UpdateText = UpdateText  -- Expose for reset
    container.SetDisplayOverride = function(self, text)
        displayOverride = text
        UpdateText()
    end
    
    -- Menu frame
    -- Menus hang from the opener's LEFT edge by default, so a wider-than-opener
    -- menu spills rightward. opts.menuAlign = "RIGHT" pins the menu's TOPRIGHT
    -- to the opener's BOTTOMRIGHT instead (surplus width grows leftward) — for
    -- openers sitting near a right edge, e.g. the Aura Designer spec dropdown.
    local menuFrame = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    if opts.menuAlign == "RIGHT" then
        menuFrame:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
    else
        menuFrame:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
    end
    RaiseMenuOverOpener(menuFrame, btn)
    host:RegisterMenu(menuFrame)
    menuFrame:SetClampedToScreen(true)
    CreateElementBackdrop(menuFrame)
    menuFrame:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.98)
    menuFrame:Hide()
    
    -- Searchable menus (opts.searchable): a search box pinned above a scrollable
    -- item list, mirroring the font/sound dropdowns. Option sets may also carry
    -- non-clickable group-header rows — `_order` entries whose option value is
    -- { header = true, text = ..., color = ... } (e.g. class-coloured spec
    -- groups). While filtering, a header only stays visible if at least one of
    -- its options matches.
    local searchable = opts.searchable
    local ITEM_HEIGHT = 22
    local SEARCH_HEIGHT = 26
    -- (No opts.maxVisible: nothing ever passed one, so 12 is what every dropdown got.)
    local MAX_VISIBLE = 12
    local searchBox, scrollFrame, scrollChild, searchPlaceholder
    if searchable then
        searchBox = CreateFrame("EditBox", nil, menuFrame, "BackdropTemplate")
        searchBox:SetPoint("TOPLEFT", 4, -4)
        searchBox:SetPoint("TOPRIGHT", -4, -4)
        searchBox:SetHeight(22)
        searchBox:SetAutoFocus(false)
        searchBox:SetFontObject(DFFontHighlightSmall)
        searchBox:SetTextInsets(24, 8, 0, 0)
        CreateElementBackdrop(searchBox)
        searchBox:SetBackdropColor(0.1, 0.1, 0.1, 1)

        local searchIcon = searchBox:CreateTexture(nil, "OVERLAY")
        searchIcon:SetPoint("LEFT", 6, 0)
        searchIcon:SetSize(12, 12)
        searchIcon:SetTexture(MEDIA .. "Icons\\search")
        searchIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

        searchPlaceholder = searchBox:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        searchPlaceholder:SetPoint("LEFT", 24, 0)
        searchPlaceholder:SetText(L["Search..."])
        searchPlaceholder:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.6)

        searchBox:SetScript("OnEditFocusGained", function() searchPlaceholder:Hide() end)
        searchBox:SetScript("OnEditFocusLost", function()
            if searchBox:GetText() == "" then searchPlaceholder:Show() end
        end)
        searchBox:SetScript("OnEscapePressed", function() menuFrame:Hide() end)

        scrollFrame = CreateFrame("ScrollFrame", nil, menuFrame, "ScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", 2, -(SEARCH_HEIGHT + 4))
        scrollFrame:SetPoint("BOTTOMRIGHT", -20, 2)
        scrollChild = CreateFrame("Frame", nil, scrollFrame)
        scrollChild:SetWidth(200)  -- resized to the menu width on each rebuild
        scrollFrame:SetScrollChild(scrollChild)
        StyleScrollBar(scrollFrame)
    end

    -- Clear tracking when hidden
    menuFrame:SetScript("OnHide", function()
        if S.currentOpenDropdown == menuFrame then
            S.currentOpenDropdown = nil
        end
        if searchBox then
            searchBox:SetText("")
            searchBox:ClearFocus()
            searchPlaceholder:Show()
        end
    end)

    local menuButtons = {}
    local menuHeight = 0
    local sortedOptions = {}

    -- Build (or rebuild) the menu buttons from the current `options` upvalue.
    -- Rows are POOLED (frames can't be garbage-collected) — rebuilds reuse
    -- existing buttons and hide the surplus, so dynamic/searchable dropdowns
    -- don't leak a row set per rebuild. Static callers build exactly once below.
    local menuContentW = 0   -- widest item text; sizes the menu to fit long options
    local function BuildMenuButtons(filterText)
        for _, b in ipairs(menuButtons) do b:Hide() end
        wipe(sortedOptions)
        menuHeight = 0

        -- Collect the ordered option list (header rows ride along)
        local ordered = {}
        -- Check for custom order array
        if options._order then
            -- Use specified order
            for _, k in ipairs(options._order) do
                local v = options[k]
                if v then
                    -- Handle both formats: KEY = "text" or KEY = {value=, text=, color=, header=}
                    local isTable = type(v) == "table"
                    table.insert(ordered, {
                        key = k,
                        value = isTable and (v.text or v.label or tostring(k)) or v,
                        color = isTable and v.color or nil,
                        header = isTable and v.header or nil,
                    })
                end
            end
        else
            -- Default: sort alphabetically by display value
            for k, v in pairs(options) do
                local isTable = type(v) == "table"
                table.insert(ordered, {
                    key = k,
                    value = isTable and (v.text or v.label or tostring(k)) or v,
                    color = isTable and v.color or nil,
                    header = isTable and v.header or nil,
                })
            end
            table.sort(ordered, function(a, b)
                local aVal = type(a.value) == "string" and a.value or tostring(a.key)
                local bVal = type(b.value) == "string" and b.value or tostring(b.key)
                return aVal < bVal
            end)
        end

        -- Apply the search filter (searchable menus): match option display text;
        -- keep a group header only when one of its options survives.
        local filter = filterText and filterText ~= "" and filterText:lower() or nil
        if filter then
            local pendingHeader
            for _, opt in ipairs(ordered) do
                if opt.header then
                    pendingHeader = opt
                else
                    local txt = type(opt.value) == "string" and opt.value:lower() or tostring(opt.key):lower()
                    if txt:find(filter, 1, true) then
                        if pendingHeader then
                            table.insert(sortedOptions, pendingHeader)
                            pendingHeader = nil
                        end
                        table.insert(sortedOptions, opt)
                    end
                end
            end
        else
            for _, opt in ipairs(ordered) do
                table.insert(sortedOptions, opt)
            end
        end

        local itemParent = scrollChild or menuFrame
        local currentVal = customGet and customGet() or (dbTable and dbKey and dbTable[dbKey])
        local selColor = accentColor or host:GetAccent()
        -- Once a group header has appeared, subsequent option rows indent under
        -- it (menus without headers keep the flat 8px inset).
        local seenHeader = false

        for i, opt in ipairs(sortedOptions) do
            local menuBtn = menuButtons[i]
            if not menuBtn then
                menuBtn = CreateFrame("Button", nil, itemParent)
                menuBtn:SetPoint("TOPLEFT", 2, -2 - (i - 1) * ITEM_HEIGHT)
                menuBtn:SetPoint("TOPRIGHT", -2, -2 - (i - 1) * ITEM_HEIGHT)
                menuBtn:SetHeight(ITEM_HEIGHT)

                menuBtn.Text = menuBtn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                menuBtn.Text:SetPoint("LEFT", 8, 0)

                -- Subtle separator above group-header rows (hidden on option rows
                -- and on a header that is the first visible row)
                menuBtn.Sep = menuBtn:CreateTexture(nil, "ARTWORK")
                menuBtn.Sep:SetHeight(1)
                menuBtn.Sep:SetPoint("TOPLEFT", 4, 1)
                menuBtn.Sep:SetPoint("TOPRIGHT", -4, 1)
                menuBtn.Sep:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.6)
                menuBtn.Sep:Hide()

                menuBtn.Highlight = menuBtn:CreateTexture(nil, "HIGHLIGHT")
                menuBtn.Highlight:SetAllPoints()

                menuBtn:SetScript("OnClick", function(self)
                    local optKey = self.optKey
                    -- Runtime override protection: redirect to baseline, skip refresh
                    -- The baseline value BEFORE the redirect, for opts.onRuntimeWrite:
                    -- a customSet that writes a second key in step with this one
                    -- (e.g. the raid wrap-axis compensation) needs the baseline's own
                    -- previous value to decide, since customSet itself is skipped on
                    -- this path.
                    local prevGlobal
                    if opts.onRuntimeWrite and dbKey then
                        local _, g = host:Call("getOverrideState", dbTable, dbKey)
                        prevGlobal = g
                    end
                    if dbKey and host:Call("interceptWrite", dbTable, dbKey, optKey) then
                        if opts.onRuntimeWrite then opts.onRuntimeWrite(optKey, prevGlobal) end
                        UpdateText()
                        menuFrame:Hide()
                        if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators(optKey) end
                        return
                    end

                    if customSet then
                        customSet(optKey)
                    else
                        dbTable[dbKey] = optKey
                    end

                    -- If editing a profile, also set the override
                    if dbKey then host:Call("onSettingWritten", dbTable, dbKey, customGet and customGet() or optKey) end

                    UpdateText()
                    menuFrame:Hide()
                    host:Call("refreshNow")
                    if callback then callback() end
                    if parent.RefreshStates then parent:RefreshStates() end
                end)

                menuButtons[i] = menuBtn
            end

            menuBtn.optKey = opt.key
            menuBtn.Text:SetText(opt.value)
            menuBtn.Highlight:SetColorTexture(selColor.r, selColor.g, selColor.b, 0.3)
            if opt.header then
                -- Non-clickable group label (no mouse ⇒ no hover highlight).
                -- Heading treatment: small uppercase label in the group colour,
                -- separator line above (except when it's the first row), and
                -- the option rows beneath it are indented — so headers read as
                -- section labels rather than selectable entries.
                menuBtn:EnableMouse(false)
                local hc = opt.color or C_TEXT_DIM
                menuBtn.Text:SetTextColor(hc.r, hc.g, hc.b)
                -- SetTextScale (not SetSettingsFont) so the pooled row resets
                -- cleanly when it's reused as a regular option row.
                menuBtn.Text:SetTextScale(0.85)
                if type(opt.value) == "string" then
                    menuBtn.Text:SetText(opt.value:upper())
                end
                menuBtn.Text:ClearAllPoints()
                menuBtn.Text:SetPoint("LEFT", 8, 0)
                menuBtn.Sep:SetShown(i > 1)
                seenHeader = true
            else
                menuBtn.Text:SetTextScale(1)
                menuBtn.Text:ClearAllPoints()
                menuBtn.Text:SetPoint("LEFT", seenHeader and 16 or 8, 0)
                menuBtn.Sep:Hide()
                menuBtn:EnableMouse(true)
                if opt.color then
                    -- per-option colour (e.g. class-coloured spec list) always wins
                    menuBtn.Text:SetTextColor(opt.color.r, opt.color.g, opt.color.b)
                elseif currentVal == opt.key then
                    menuBtn.Text:SetTextColor(selColor.r, selColor.g, selColor.b)
                else
                    menuBtn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                end
            end
            menuBtn:Show()
            menuHeight = menuHeight + ITEM_HEIGHT
        end

        -- Width fits the widest item so long options aren't clipped by a narrow
        -- opener (refined to max(opener, content) on open, once btn is sized).
        menuContentW = 0
        for i = 1, #sortedOptions do
            menuContentW = math.max(menuContentW, menuButtons[i].Text:GetStringWidth() or 0)
        end
        if searchable then
            local visible = math.min(#sortedOptions, MAX_VISIBLE)
            menuFrame:SetWidth(math.max(btn:GetWidth() or 0, menuContentW + 44))
            menuFrame:SetHeight(visible * ITEM_HEIGHT + SEARCH_HEIGHT + 8)
            scrollChild:SetWidth(menuFrame:GetWidth() - 24)
            scrollChild:SetHeight(menuHeight + 4)
            scrollFrame:SetVerticalScroll(0)
        else
            menuFrame:SetWidth(menuContentW + 24)
            menuFrame:SetHeight(menuHeight + 4)
        end
    end

    BuildMenuButtons()

    if searchBox then
        searchBox:SetScript("OnTextChanged", function(self)
            if menuFrame:IsShown() then BuildMenuButtons(self:GetText()) end
        end)
    end

    -- Allow dynamic dropdowns to swap their option set and regenerate buttons.
    container.RebuildOptions = function(_, newOptions)
        if newOptions then options = newOptions end
        BuildMenuButtons(searchBox and searchBox:GetText() or nil)
        UpdateText()
    end

    -- The opener is exposed for callers that need to hang state off the button
    -- itself (see .openerTooltip below).
    container.opener = btn

    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
        -- ★ OPENER TOOLTIP. The shared attach (host:AttachTooltip below) builds
        -- its hit frame over the LABEL, which an inline dropdown does not have --
        -- the caller draws its own label in its own row and the factory's is
        -- hidden and zero-wide, so `.tooltip` is unreachable on an inline
        -- dropdown. `.openerTooltip` hangs the same spec off the opener instead.
        -- Deliberately NOT a hit frame: one over the opener would eat the click
        -- that opens the menu.
        local spec = container.openerTooltip
        if spec then
            if type(spec) == "string" then spec = { title = label, lines = { spec } } end
            host:ShowTooltip(self, spec)
        end
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        if container.openerTooltip then host:HideTooltip() end
    end)
    
    btn:SetScript("OnClick", function(self)
        if menuFrame:IsShown() then
            menuFrame:Hide()
            S.currentOpenDropdown = nil
        else
            -- Close any other open dropdown first
            host:CloseAllMenus()
            -- Dynamic dropdowns regenerate their option list each open.
            if optionsFunc then
                container:RebuildOptions(optionsFunc())
            elseif searchable then
                -- Searchable menus reopen unfiltered (search cleared on hide)
                BuildMenuButtons()
            else
                -- Static menus: refresh selected-value colouring on the pooled rows
                local currentVal = customGet and customGet() or (dbTable and dbKey and dbTable[dbKey])
                local selColor = accentColor or host:GetAccent()
                for i, opt in ipairs(sortedOptions) do
                    local menuBtn = menuButtons[i]
                    if menuBtn and not opt.header then
                        if opt.color then
                            -- per-option colour (e.g. class-coloured spec list) always wins
                            menuBtn.Text:SetTextColor(opt.color.r, opt.color.g, opt.color.b)
                        elseif currentVal == opt.key then
                            menuBtn.Text:SetTextColor(selColor.r, selColor.g, selColor.b)
                        else
                            menuBtn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                        end
                    end
                end
            end
            if searchable then
                menuFrame:SetWidth(math.max(btn:GetWidth() or 0, menuContentW + 44))
                scrollChild:SetWidth(menuFrame:GetWidth() - 24)
            else
                menuFrame:SetWidth(math.max(btn:GetWidth() or 0, menuContentW + 24))
            end
            -- Re-asserted here, not just at creation: the opener may have been
            -- raised since (a pooled popout takes its strata when it is Follow'd,
            -- long after the widgets inside it were built).
            RaiseMenuOverOpener(menuFrame, btn)
            menuFrame:Show()
            S.currentOpenDropdown = menuFrame
            if searchBox then searchBox:SetFocus() end
        end
    end)
    
    btn:SetScript("OnShow", UpdateText)
    UpdateText()

    container.SetEnabled = function(self, enabled)
        -- Dim the whole widget so its preview/value (texture swatch, font preview,
        -- selected text) greys with the label rather than staying full-bright.
        self:SetAlpha(enabled and 1 or 0.4)
        btn:SetEnabled(enabled)
        if enabled then
            lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            UpdateText()  -- restore per-option colour on the selected label
        else
            lbl:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            btn.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
    end
    
    -- Tooltip: shared attach on the LABEL only (see UI:AttachTooltip). The label
    -- sits at the container's TOPLEFT, above the opener, so it is well clear of
    -- the menu you are about to click.
    host:AttachTooltip(container, label, lbl)

    -- SEARCH: Register this setting
    if dbKey and type(dbKey) == "string" then
        host:Call("registerSearch", "dropdown", label, dbKey, container, { options = options, callback = callback })
    end

    return container
end

UI.CreateDropdownNative = UI.CreateDropdown

-- ============================================================
-- NATIVE VALUE WIDGETS
-- The opts-based set, built on the stylers above -- so a checkbox created here
-- and a hand-rolled one styled with StyleCheckButton are the same control.
-- ============================================================

-- opts: label, get() -> bool, set(bool), onChanged(bool), tooltip, accent, size
-- Returns the container with :Refresh() and :SetEnabled(bool).
function UI:CreateCheckbox(parent, opts)
    local host = self
    opts = opts or {}
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, UI.RowHeight.checkbox)
    container.preferredHeight = UI.RowHeight.checkbox
    container.rowKind = "checkbox"
    container.fixedRowHeight = true

    local cb = CreateFrame("CheckButton", nil, container, "BackdropTemplate")
    cb:SetPoint("TOPLEFT", 0, -3)
    host:StyleCheckButton(cb, { accent = opts.accent, size = opts.size, themeRoot = parent })

    local lbl = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    lbl:SetPoint("LEFT", cb, "RIGHT", 6, 0)
    lbl:SetPoint("RIGHT", container, "RIGHT", 0, 0)
    lbl:SetJustifyH("LEFT")
    lbl:SetText(opts.label or "")
    lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    container.label = lbl
    container.checkButton = cb

    cb:SetScript("OnClick", function(self)
        local v = self:GetChecked() and true or false
        if opts.set then opts.set(v) end
        if opts.onChanged then opts.onChanged(v) end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)

    container.Refresh = function() cb:SetChecked(opts.get and opts.get() and true or false) end
    container.refreshContent = container.Refresh
    container.SetEnabled = function(self, enabled)
        cb:SetEnabled(enabled)
        self:SetAlpha(enabled and 1 or 0.4)
        local c = enabled and C_TEXT or C_TEXT_DIM
        lbl:SetTextColor(c.r, c.g, c.b)
    end
    container.tooltip = opts.tooltip
    host:AttachTooltip(container, opts.label, lbl)
    container:Refresh()
    return container
end

UI.CreateCheckboxNative = UI.CreateCheckbox

-- opts: width, height, get() -> value, set(text), onCommit(text), numeric,
--       tooltip, maxLetters, placeholder
-- Returns the styled EditBox itself, with :Refresh().
function UI:CreateEditBox(parent, opts)
    local host = self
    opts = opts or {}
    local eb = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    eb:SetSize(opts.width or 80, opts.height or 20)
    eb:SetAutoFocus(false)
    host:StyleEditBox(eb)
    if opts.maxLetters then eb:SetMaxLetters(opts.maxLetters) end

    eb.Refresh = function(self)
        local v = opts.get and opts.get()
        self:SetText(v ~= nil and tostring(v) or "")
        self:SetCursorPosition(0)
    end

    -- SetNumeric is NOT used for opts.numeric: it bans "-" outright, which
    -- would make a negative offset untypeable. Validate on commit instead and
    -- bounce a non-number back to the stored value.
    eb:SetScript("OnEnterPressed", function(self)
        local text = self:GetText()
        if opts.numeric then
            local n = tonumber(text)
            if not n then self:Refresh() self:ClearFocus() return end
            text = n
        end
        if opts.set then opts.set(text) end
        if opts.onCommit then opts.onCommit(text) end
        self:ClearFocus()
    end)
    eb:SetScript("OnEscapePressed", function(self) self:Refresh() self:ClearFocus() end)

    local nativeSetEnabled = eb.SetEnabled
    eb.SetEnabled = function(self, enabled)
        nativeSetEnabled(self, enabled)
        self:EnableMouse(enabled)
        self:SetAlpha(enabled and 1 or 0.4)
    end

    if opts.placeholder then
        local ph = eb:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        ph:SetPoint("LEFT", 6, 0)
        ph:SetText(opts.placeholder)
        ph:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.6)
        eb:HookScript("OnTextChanged", function(self) ph:SetShown(self:GetText() == "") end)
        eb.Placeholder = ph
    end
    if opts.tooltip then
        eb:HookScript("OnEnter", function(self)
            host:ShowTooltip(self, type(opts.tooltip) == "table" and opts.tooltip or { title = opts.tooltip })
        end)
        eb:HookScript("OnLeave", function() host:HideTooltip() end)
    end
    eb:Refresh()
    return eb
end

UI.CreateEditBoxNative = UI.CreateEditBox

-- opts: text, width, height, onClick(btn), style = "primary"|"ghost"|"tab"|"tinted",
--       tone = "danger"|"success", icon, accent, align, fitText, themeRoot, tooltip
function UI:CreateButton(parent, opts)
    local host = self
    opts = opts or {}
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(opts.width or 100, opts.height or 22)
    local style = opts.style
    host:StyleButton(btn, {
        text = opts.text, width = opts.width, height = opts.height,
        icon = opts.icon, align = opts.align, accent = opts.accent, tone = opts.tone,
        primary = style == "primary" or nil,
        ghost   = style == "ghost" or nil,
        tab     = style == "tab" or nil,
        tinted  = style == "tinted" or nil,
        fitText = opts.fitText,
        themeRoot = opts.themeRoot,
    })
    if opts.onClick then
        btn:SetScript("OnClick", function(self)
            if self.dfDisabled then return end
            opts.onClick(self)
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)
    end
    if opts.tooltip then
        btn:HookScript("OnEnter", function(self)
            host:ShowTooltip(self, type(opts.tooltip) == "table" and opts.tooltip or { title = opts.tooltip })
        end)
        btn:HookScript("OnLeave", function() host:HideTooltip() end)
    end
    return btn
end

UI.CreateButtonNative = UI.CreateButton

-- opts: text, size (settings font at that size), color {r,g,b}, font (a font
--       OBJECT name, which wins over size), width (enables word wrap), justify
function UI:CreateLabel(parent, opts)
    opts = opts or {}
    local fs = parent:CreateFontString(nil, "OVERLAY", opts.font or "DFFontHighlightSmall")
    if opts.size and not opts.font then self:SetSettingsFont(fs, opts.size) end
    local c = opts.color or C_TEXT
    fs:SetTextColor(c.r or c[1], c.g or c[2], c.b or c[3], c.a or c[4] or 1)
    fs:SetText(opts.text or "")
    if opts.width then fs:SetWidth(opts.width) fs:SetWordWrap(true) end
    fs:SetJustifyH(opts.justify or "LEFT")
    return fs
end

UI.CreateLabelNative = UI.CreateLabel

-- ============================================================
-- TOOLTIPS AND BANNER TONES  (moved back from the companion)
-- ============================================================
-- ☠ These once lived in a consumer while HideTooltip sat here -- the pair
-- split across an addon boundary. Live code calls ShowTooltip from surfaces
-- the settings panel does not own, so with the panel unloaded every one of
-- those hovers errored.

-- ============================================================
-- CreateInfoBanner
-- ------------------------------------------------------------
-- A self-resizing banner with an icon, body text, and a "tone"
-- (info / caution / danger / success) that controls background,
-- border, default text colour, and default icon. ("warning" is a
-- legacy alias of "caution".) Do NOT pass fontTemplate — banners
-- share one font on purpose; only the tone should vary.
--
-- Usage:
--   local banner = UI:CreateInfoBanner(parent, { tone = "caution", text = "..." })
--   Add(banner, banner.layoutHeight, "both")
--
-- Methods on the returned frame:
--   :SetTone(name)                  apply a preset (see TONES below)
--   :SetText(text, optColor)        plain text mode, auto-wraps + auto-resizes
--   :SetHTML(html, onLinkClick)     flow-layout body with clickable link buttons
--   :SetIcon(texture, r, g, b)      icon texture + optional vertex colour
--   :SetIconTexture(path)           icon texture only
--   :SetIconColor(r, g, b)          icon vertex colour only
--
-- The body word-wraps automatically; banner height is recomputed via
-- OnSizeChanged so resizing the GUI (or calling SetText/SetHTML) grows
-- or shrinks the banner to fit. The host page is re-laid out so widgets
-- below the banner reposition.
-- ============================================================
-- Each tone carries FOUR colour roles so all three consumers (banners,
-- inline ToneHex text, and tooltips) stay in sync:
--   bg / border / textColor / icon+iconColor  drive the BANNER box itself.
--   accent                                     is the vivid emphasis colour
--     used for INLINE text (ToneHex) and tooltip titles, read against the
--     dark GUI background rather than the banner's own tinted bg. It is a
--     SEPARATE role from iconColor: e.g. the danger icon is a light warm so
--     the triangle pops on the orange banner, but inline "Warning" text must
--     be a real red to out-rank a caution — deriving one from the other
--     (the original bug) made inline danger paler than caution.
local INFO_BANNER_TONES = {
    info = {
        bg = {0.15, 0.18, 0.28, 1},
        useThemeBorder = true, borderAlpha = 0.5,
        icon = "info",
        textColor = {0.85, 0.85, 0.85},
        accent = {0.6, 0.8, 1},          -- light blue
    },
    -- NOTE: "warning" was merged into "caution" (they were near-duplicate golds).
    -- SetTone("warning") still resolves via the alias below for safety.
    caution = {
        bg = {0.5, 0.45, 0.1, 0.9},
        border = {0.7, 0.6, 0.1, 1},
        icon = "warning", iconColor = {1, 0.9, 0.3},
        textColor = {1, 0.95, 0.7},
        accent = {1, 0.82, 0},           -- gold
    },
    danger = {
        bg = {0.6, 0.3, 0.1, 0.9},
        border = {0.8, 0.4, 0.1, 1},
        -- icon kept a light warm (not the mid-orange bg hue) so the triangle pops
        icon = "warning", iconColor = {1, 0.9, 0.72},
        textColor = {1, 0.85, 0.7},
        accent = {1, 0.27, 0.27},        -- real red (destructive), NOT the pale icon warm
    },
    success = {
        bg = {0.1, 0.4, 0.2, 0.9},
        border = {0.2, 0.6, 0.3, 1},
        icon = "check", iconColor = {0.3, 1, 0.5},
        textColor = {0.7, 1, 0.8},
        accent = {0.4, 0.85, 0.5},       -- green
    },
}
-- Legacy alias: "warning" was merged into "caution" (near-duplicate golds).
INFO_BANNER_TONES.warning = INFO_BANNER_TONES.caution
P.INFO_BANNER_TONES = INFO_BANNER_TONES

-- The line grammar, shared by ShowTooltip and ShowGameTooltip so a toolkit
-- line appended under a spell tooltip reads exactly like one under a plain title.
local function AddTooltipLines(host, lines)
    if not lines then return end
    local acc
    for _, line in ipairs(lines) do
        if line == " " or line == "" then
            GameTooltip:AddLine(" ")
        elseif type(line) == "string" then
            GameTooltip:AddLine(line, 0.7, 0.7, 0.7, true)
        elseif type(line) == "table" and (line.text or line.left) then
            local r, g, b = 0.7, 0.7, 0.7
            if line.hint then
                r, g, b = 0.55, 0.55, 0.55
            elseif line.accent then
                acc = acc or host:GetAccent()
                r, g, b = acc.r, acc.g, acc.b
            elseif line.color then
                -- Accept {r=,g=,b=} or {r,g,b}: the palette uses the first, most
                -- call sites building a colour inline reach for the second.
                local c = line.color
                r, g, b = c.r or c[1], c.g or c[2], c.b or c[3]
            end
            if line.left then
                -- Two-column form (label … value), for key/value dumps. Never
                -- wraps -- AddDoubleLine has no wrap argument.
                GameTooltip:AddDoubleLine(line.left, line.right, r, g, b, 1, 1, 1)
            else
                GameTooltip:AddLine(line.text, r, g, b, true)
            end
        end
    end
end

-- How far the cursor-anchored tooltip is nudged off the pointer. ONE dial.
--
-- Small on purpose. This started at 24 while the tooltip could still appear over
-- a slider or dropdown, where it had to clear the whole control. Now that the
-- hover lives on the LABEL only (see UI:AttachTooltip) there is nothing
-- underneath worth clearing — the lift just has to keep the tooltip off the
-- words you are reading, so a nudge does it.
--
-- ⚠ ANCHOR_CURSOR_RIGHT, not ANCHOR_CURSOR — plain ANCHOR_CURSOR DISCARDS the
-- offsets. Verified against the client's own code rather than assumed:
-- Blizzard_AuraContainer/Blizzard_AuraButton.lua asserts the signature
-- SetOwner(point, offsetX, offsetY) with both offsets optional numbers, and
-- Blizzard's own callers only ever pass offsets alongside the _RIGHT / _LEFT
-- variants (QuestDataProvider "ANCHOR_CURSOR_RIGHT", 5, 2 — never with the plain
-- cursor anchor). Positive Y is up in WoW, so this lifts regardless of which
-- edge the anchor pins.
local CURSOR_LIFT_X, CURSOR_LIFT_Y = 0, 8

-- ☠ ShowTooltip lives here; ShowGameTooltip is consumer-supplied. The pair
-- straddles the addon boundary and must use the SAME lift -- a spell tooltip on
-- a settings row has to sit exactly where every other toolkit tooltip sits.
-- Published rather than duplicated so the two cannot drift apart, and because
-- a consumer reading these as bare globals silently got nil (they are
-- optional SetOwner args, so it dropped the lift with no error).
P.CURSOR_LIFT_X, P.CURSOR_LIFT_Y = CURSOR_LIFT_X, CURSOR_LIFT_Y

function UI:ShowTooltip(owner, opts)
    if not owner or not opts or not opts.title then return end
    if opts.anchor then
        GameTooltip:SetOwner(owner, opts.anchor)
    else
        GameTooltip:SetOwner(owner, "ANCHOR_CURSOR_RIGHT", CURSOR_LIFT_X, CURSOR_LIFT_Y)
    end
    -- Title colour is single-sourced from the tone's inline accent so a tooltip
    -- title reads the same as inline ToneHex text of the same tone. Untoned = white.
    local toneDef = opts.tone and INFO_BANNER_TONES[opts.tone]
    local ac = toneDef and toneDef.accent
    if ac then
        GameTooltip:SetText(opts.title, ac[1], ac[2], ac[3])
    else
        GameTooltip:SetText(opts.title, 1, 1, 1)
    end
    AddTooltipLines(self, opts.lines)
    GameTooltip:Show()
end

-- ============================================================
-- SHARED WITH THE SETTINGS-PANEL WIDGETS
-- ============================================================
-- ☠ Published on _priv rather than aliased from a public UI.X name: these
-- are file locals with no public counterpart, and where a public name does
-- exist it can be a method WRAPPER rather than the local itself. Aliasing the
-- wrapper is what broke CreateElementBackdrop in game once already.
P.AddTooltipLines = AddTooltipLines
