-- Part 3 of the GUI toolkit, split from the original GUI.lua.
-- These re-declarations are aliases of the SAME objects the first part
-- created; they add no state. See docs/reorg-tools/splits.manifest.
local addonName, DF = ...
local GUI = DF.GUI
local L = DF.L
local S = GUI._state
local P = GUI._priv
local C_PANEL, C_ELEMENT, C_BORDER, C_HOVER, C_TEXT, C_TEXT_DIM =
      GUI.Colors.panel, GUI.Colors.element, GUI.Colors.border, GUI.Colors.hover, GUI.Colors.text, GUI.Colors.textDim
local CloseOpenDropdown = GUI._priv.CloseOpenDropdown
local GetThemeColorFor = GUI.GetThemeColorFor
local GetThemeColor = GUI.GetThemeColor
local SnapLen = GUI.SnapLen
local SnapHeightEven = GUI.SnapHeightEven
local CreateElementBackdrop = GUI._priv.CreateElementBackdrop
local CreatePanelBackdrop = GUI._priv.CreatePanelBackdrop
local StyleScrollBar = GUI.StyleScrollBar
local INFO_BANNER_TONES = GUI._priv.INFO_BANNER_TONES

-- Counterpart to ShowTooltip: hide the shared GameTooltip. Wrapped so callers
-- route through GUI instead of poking GameTooltip directly.
function GUI:HideTooltip()
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
function GUI:AttachTooltip(widget, label, labelRegion)
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
        local spec = ResolveTooltipSpec(widget, label)
        if spec then GUI:ShowTooltip(hit, spec) end
    end)
    hit:SetScript("OnLeave", function() GUI:HideTooltip() end)

    widget.dfTooltipHit = hit   -- exposed for a caller that needs to re-anchor it
    return hit
end

function GUI:StyleButton(btn, opts)
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

    if isTabStyle then
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
        restBackdrop(self, accent or GetThemeColor())
        if isTabStyle then
            -- Underline tab: show the accent stripe + accent label when active,
            -- dim label when inactive.
            local a = accent or GetThemeColor()
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
            local wc = accent or GetThemeColor()
            hl:SetVertexColor(wc.r, wc.g, wc.b, 0)
            if self.Text then self.Text:SetAlpha(0.35) end
            if self.Icon then self.Icon:SetAlpha(0.35) end
        else
            self.ApplyThemeColor(accent or GetThemeColor())  -- re-assert the wash's rest colour + alpha (0.30 / 0.15)
            restBackdrop(self, accent or GetThemeColor())
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

    btn.ApplyThemeColor(accent or GetThemeColor())
    if not accent then
        btn.UpdateTheme = function() btn.ApplyThemeColor(GetThemeColor()) end
        local root = opts.themeRoot or btn:GetParent()
        if root then
            root.ThemeListeners = root.ThemeListeners or {}
            table.insert(root.ThemeListeners, btn)
        end
    end

    -- WHAT HOVERED LOOKS LIKE — the single implementation, so the mouse and a
    -- proxying owner cannot drift apart. OnEnter/OnLeave below are thin wrappers.
    --
    -- ⚠ NO CURRENT CONSUMER. The Filter Designer's membership button was the one
    -- caller and went with the filters merge (FilterRegistry/Options.lua says so).
    -- Kept because the pattern recurs and the Lock/UnlockHighlight subtlety below
    -- is not obvious enough to want rediscovered.
    --
    -- Call btn:SetHovered(true/false) when something ELSE owns the hit area and
    -- forwards the click: a list row whose OnClick fires this button's action.
    -- The row lighting its button says "this is what clicking the row does", and
    -- it separates the button from the row's highlight by HUE, which is far more
    -- robust than the couple of hundredths of grey that sit between C_HOVER and
    -- C_ELEMENT (the Filter Designer's spell rows are exactly that case).
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
                restBackdrop(self, accent or GetThemeColor())
            end
            return
        end
        -- Re-resolve the wash against the CURRENT theme, exactly as the border does
        -- below (see applyWash). Skipped when the caller pinned a fixed accent, and
        -- while disabled -- SetDisabled parks the wash at alpha 0 and it must stay
        -- parked, or a disabled button would light up under the mouse.
        if not accent and not self.dfDisabled then applyWash(GetThemeColor()) end
        -- tab/ghost/neutral: only the auto wash, no accent border
        if isTabStyle or ghost or neutralHover then return end
        if self:IsEnabled() and not self.dfDisabled then
            local a = accent or GetThemeColor()
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
    return btn
end

function GUI:CreateButton(parent, text, width, height, func, iconName)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    local opts = { width = width or 120, height = height or 22, text = text }
    -- Optional leading icon by Media\Icons name (14px to suit the small buttons).
    if iconName then
        opts.icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\" .. iconName, size = 14 }
    end
    GUI:StyleButton(btn, opts)
    btn:SetScript("OnClick", function(self)
        if func then func(self) end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    return btn
end

-- Standard close/dismiss button: a small square danger-toned button showing a
-- "×" glyph. Replaces the many hand-rolled red close buttons on dialogs/panels.
-- opts = { size (20), onClick, tooltip, tone }.
--   tone = nil      → dim grey "×" at rest → white on hover (close/dismiss; default)
--   tone = "danger" → RED "×" at rest → brighter red on hover (inline destructive
--                     removes: list-item / tag removes). Both keep the red hover wash.
-- A horizontal row of buttons, chained left-to-right with one gap, sized as a
-- single layout slot. Pages were building this by hand every time -- a bare
-- CreateFrame, then SetPoint("LEFT", prev, "RIGHT", 6, 0) per button, plus the
-- HookScript/ShowTooltip pair on any button that needed a tooltip.
--
-- buttons = { { label, width, onClick, icon, tooltip, key }, ... }
--   tooltip is a ShowTooltip spec ({title, lines, tone}); a button IS its own
--   label, so it takes the whole-widget hover rather than AttachTooltip's
--   label-only hit area (AttachTooltip returns early without a label region).
--   key names the button on row.buttons for a caller that needs it later.
function GUI:CreateButtonRow(parent, buttons, opts)
    opts = opts or {}
    local gap, h = opts.gap or 6, opts.height or 24
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(opts.width or 540, opts.rowHeight or (h + 4))
    row.buttons = {}
    local prev
    for i, spec in ipairs(buttons) do
        local btn = GUI:CreateButton(row, spec.label, spec.width or 80, h, spec.onClick, spec.icon)
        if prev then
            btn:SetPoint("LEFT", prev, "RIGHT", gap, 0)
        else
            btn:SetPoint("LEFT", 0, 0)
        end
        if spec.tooltip then
            btn:HookScript("OnEnter", function(self) GUI:ShowTooltip(self, spec.tooltip) end)
            btn:HookScript("OnLeave", function() GUI:HideTooltip() end)
        end
        row.buttons[spec.key or i] = btn
        prev = btn
    end
    return row
end

function GUI:CreateCloseButton(parent, opts)
    opts = opts or {}
    local size = opts.size or 20
    -- Rest/hover glyph colours: grey→white for dismiss, red→brighter-red for inline
    -- destructive removes. The StyleButton red wash + border is shared by both.
    local restColor  = (opts.tone == "danger") and { r = 0.9, g = 0.45, b = 0.45 } or C_TEXT_DIM
    local hoverColor = (opts.tone == "danger") and { r = 1, g = 0.4, b = 0.4 } or { r = 1, g = 1, b = 1 }
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    GUI:StyleButton(btn, {
        width = size, height = size,
        tone = "danger",
        icon = {
            texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\close",
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
    if opts.tooltip then
        btn:HookScript("OnEnter", function(self)
            GUI:ShowTooltip(self, { title = opts.tooltip})
        end)
        btn:HookScript("OnLeave", function() GUI:HideTooltip() end)
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
function GUI:CreateGlyphButton(parent, opts)
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

    btn:SetScript("OnEnter", function(self)
        if self._glyphHover then self.Icon:SetVertexColor(hr, hg, hb) end
        if opts.tooltip then GUI:ShowTooltip(self, { title = opts.tooltip }) end
    end)
    btn:SetScript("OnLeave", function(self)
        self.Icon:SetVertexColor(unpack(self._glyphRest))
        if opts.tooltip then GUI:HideTooltip() end
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
function GUI:CreatePanelBackdrop(frame, opts)
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
-- The hue comes from the GUI theme constants (C_ACCENT party purple-blue / C_RAID
-- raid orange) instead of a hardcoded literal, so retheming moves the movers too.
--
-- ⚠ Which POLE is the caller's choice, not GUI.SelectedMode's, because a mover
-- belongs to the thing it moves: the raid mover must stay orange even while the
-- options window happens to be showing a party page. Pass isRaid where the site
-- knows; omit it only where the mover genuinely has no mode, and it will follow
-- the selected mode.
--
-- opts:
--   isRaid       true/false pins the pole; omit to follow GUI.SelectedMode
--   color        {r,g,b} or {[1],[2],[3]} -- explicit override, for a mover whose
--                colour is a user setting rather than the theme
--   fillAlpha    default 0.30      borderAlpha  default 0.80
--   fill = false outline only      edgeSize     default 2
--
-- The returned frame gains :RefreshMoverTint(), which re-resolves the hue against
-- the theme as it stands now -- call it if the mode changes while a mover is shown.
function GUI:CreateMoverBackdrop(frame, opts)
    opts = opts or {}
    local c = opts.color
    if not c then
        if opts.isRaid ~= nil then c = GetThemeColorFor(opts.isRaid)
        else                       c = GetThemeColor() end
    end
    local r, g, b = c.r or c[1], c.g or c[2], c.b or c[3]
    CreateElementBackdrop(frame, {
        fill        = opts.fill,
        edgeSize    = opts.edgeSize or 2,
        bgColor     = { r, g, b, opts.fillAlpha or 0.30 },
        borderColor = { r, g, b, opts.borderAlpha or 0.80 },
    })
    frame.RefreshMoverTint = function(self, newOpts)
        return GUI:CreateMoverBackdrop(self, newOpts or opts)
    end
    return frame
end

-- The element backdrop, exposed to consumer files (the stylers in this file use
-- the local directly). Nothing outside should be calling SetBackdrop itself --
-- route it through here so the look, and the border mechanism, stay in one
-- place. See the local for the opts contract: fill, outline, bgColor,
-- borderColor, backdropEdge.
function GUI:CreateElementBackdrop(frame, opts)
    return CreateElementBackdrop(frame, opts)
end

-- ============================================================
-- DESIGNER TEMPLATE BAR (shared by the Aura / Text Designer editors)
-- Compact row: "Template: [dropdown ▾]  [New][Duplicate][Rename][Delete]".
-- NOTE: the saved keys are still auraDesignerPreset(s) / textDesignerPreset(s) --
-- only the LABELS became "template". The keys are persisted and exported, so
-- renaming them would cost a profile migration for nothing a user can see.
-- "Preset" now means only the built-in filter sets (FilterRegistry) and the
-- export/test quick-picks.
-- Picking a template assigns it to the mode (opts.getMode()) AND retargets the
-- editor; the buttons manage the library. After any change the bar calls
-- opts.onChange() so the host page can rebuild + refresh live frames.
-- opts = { kind = "aura"|"text", getMode = fn->mode, onChange = fn }.
-- Returns the bar frame; call bar:Refresh() to resync.
-- ============================================================

-- The addon's ONE name prompt. This was hand-rolled twice against Blizzard's
-- StaticPopup edit box — here and in the Filter Designer — each copy carrying
-- the same `self.EditBox or self.editBox or self:GetEditBox()` fallback for a
-- field name that moves between client versions. Both now come through here and
-- get DF chrome, so there is nothing left to keep in step.
-- opts = { title, message, default, acceptLabel, maxLetters, onAccept(text) }
function GUI:PromptName(opts)
    opts = opts or {}
    DF:ShowPopupInput({
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

local function PromptPresetName(message, default, acceptLabel, callback)
    GUI:PromptName({
        title       = L["Template Name"],
        message     = message,
        default     = default,
        acceptLabel = acceptLabel,
        onAccept    = callback,
    })
end

local function ConfirmDeletePreset(kind, name, onDone)
    DF:ShowPopupAlert({
        title   = L["Delete Template"],
        message = format(L["Delete template \"%s\"? Anything using it reverts to Default."], name),
        buttons = {
            {
                label = L["Delete"],
                onClick = function()
                    if DF.DeleteDesignerPreset then
                        DF:DeleteDesignerPreset(kind, name)
                        if onDone then onDone() end
                    end
                end,
            },
            { label = L["Cancel"] },
        },
    })
end

function GUI:CreateDesignerPresetBar(parent, opts)
    opts = opts or {}
    local kind = opts.kind or "aura"
    local getMode = opts.getMode or function() return "party" end
    local onChange = opts.onChange or function() end

    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(24)

    local label = bar:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    label:SetPoint("LEFT", 0, 0)
    label:SetText(L["Template:"])
    label:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    local function CurrentName()
        return DF:GetModeDesignerPresetName(kind, getMode())
    end

    -- True while editing a raid auto-layout (the only context with an "inherit
    -- the global preset" choice — normal party/raid modes ARE the base).
    -- Mode-gated: auto-layouts are RAID-only, but the GUI can be reopened on
    -- the party tab while editing (ToggleGUI re-derives SelectedMode) — the
    -- PARTY preset bar must not show layout state, and its "Inherit (Global)"
    -- click must never clear the RAID layout's override.
    local function IsEditingLayout()
        return getMode() == "raid"
            and DF.AutoProfilesUI and DF.AutoProfilesUI.IsEditing and DF.AutoProfilesUI:IsEditing()
    end

    -- The label to show on the dropdown button: "Inherit (Global)" when the
    -- edited layout has no override, otherwise the resolved preset name.
    local function CurrentLabel()
        if IsEditingLayout() and DF.IsLayoutDesignerInheriting and DF:IsLayoutDesignerInheriting(kind) then
            return L["Inherit (Global)"]
        end
        return CurrentName()
    end

    -- Dropdown button + menu (rebuilt on each open so it always reflects the lib)
    local ddBtn = CreateFrame("Button", nil, bar, "BackdropTemplate")
    ddBtn:SetSize(150, 22)
    ddBtn:SetPoint("LEFT", label, "RIGHT", 6, 0)
    CreateElementBackdrop(ddBtn)
    ddBtn.text = ddBtn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    ddBtn.text:SetPoint("LEFT", 6, 0)
    ddBtn.text:SetPoint("RIGHT", -16, 0)
    ddBtn.text:SetJustifyH("LEFT")
    ddBtn.text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    local arrow = ddBtn:CreateTexture(nil, "OVERLAY")
    arrow:SetPoint("RIGHT", -4, 0)
    arrow:SetSize(10, 10)
    arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
    arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    local menu = CreateFrame("Frame", nil, ddBtn, "BackdropTemplate")
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    GUI:RegisterMenu(menu)
    menu:SetPoint("TOPLEFT", ddBtn, "BOTTOMLEFT", 0, -1)
    menu:SetWidth(150)
    CreatePanelBackdrop(menu)
    menu:Hide()

    -- Row pool: frames can't be garbage-collected in WoW, so recreating the
    -- items on every open (the old Hide+SetParent(nil) approach) leaked a row
    -- set per click. Reuse instead.
    local menuRows = {}
    local function BuildMenu()
        for _, row in ipairs(menuRows) do row:Hide() end
        local used = 0
        local y = -4
        local function AddItem(label, onClick)
            used = used + 1
            local item = menuRows[used]
            if not item then
                item = CreateFrame("Button", nil, menu)
                item:SetHeight(20)
                item.text = item:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                item.text:SetPoint("LEFT", 4, 0)
                item:SetScript("OnEnter", function(s) s.text:SetTextColor(1, 1, 1) end)
                item:SetScript("OnLeave", function(s) s.text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b) end)
                item:SetScript("OnClick", function(s)
                    s.onClick()
                    menu:Hide()
                    bar:Refresh()
                    onChange()
                end)
                menuRows[used] = item
            end
            item:ClearAllPoints()
            item:SetPoint("TOPLEFT", 4, y)
            item:SetPoint("TOPRIGHT", -4, y)
            item.text:SetText(label)
            item.text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            item.onClick = onClick
            item:Show()
            y = y - 20
        end
        -- "Inherit (Global)" — only while editing a raid auto-layout. Clears the
        -- layout's preset override so it follows your global preset.
        if IsEditingLayout() then
            AddItem(L["Inherit (Global)"], function()
                if DF.InheritLayoutDesignerPreset then DF:InheritLayoutDesignerPreset(kind) end
            end)
        end
        for _, name in ipairs(DF:ListDesignerPresets(kind)) do
            AddItem(name, function() DF:SetModeDesignerPreset(kind, getMode(), name) end)
        end
        menu:SetHeight(-y + 4)
    end
    ddBtn:SetScript("OnClick", function()
        if menu:IsShown() then menu:Hide() else BuildMenu(); menu:Show() end
    end)

    -- SHARING MARKER. A template can be pointed at by the other mode, a pinned
    -- set or an auto layout, and editing it then changes every one of them —
    -- which nothing on this bar used to say. The dropdown is a fixed 150px, so
    -- the FACT rides as a glyph and the NAMES go in the tooltip, which is free.
    --
    -- Deliberately NOT clickable. Splitting a shared template off for this mode
    -- is exactly what Duplicate does, two buttons to the right, and Duplicate
    -- also lets you name the copy.
    local shareIcon = ddBtn:CreateTexture(nil, "OVERLAY")
    shareIcon:SetSize(12, 12)
    shareIcon:SetPoint("RIGHT", arrow, "LEFT", -3, 0)
    shareIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\sync")
    shareIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    shareIcon:Hide()

    -- Read off the REFS, not the party/raid sync flag: sharing by hand (picking
    -- the other mode's preset from this dropdown) counts exactly the same, and a
    -- ref can't fall out of step with itself.
    local function SharedWith()
        if IsEditingLayout() and DF.IsLayoutDesignerInheriting and DF:IsLayoutDesignerInheriting(kind) then
            return {}   -- inheriting: this bar isn't sitting on a preset of its own
        end
        return (DF.ListDesignerPresetUsers and DF:ListDesignerPresetUsers(kind, CurrentName(), getMode())) or {}
    end

    -- The consumers (Party/Raid, Auto Layouts, Pinned Frames) are spread across
    -- three other pages, so naming them is the one thing this tooltip has to do
    -- — the bar itself already shows what a template is. "can" holds for all
    -- four: Auto Layouts and Pinned Frames may inherit their mode's instead
    -- (a nil ref), and Party/Raid resolve to a default when nothing is set.
    -- Names match their page titles so they are findable.
    ddBtn:SetScript("OnEnter", function(self)
        local lines = {
            L["Templates can be used by Party, Raid, Auto Layouts and Pinned Frames."],
        }
        local shared = SharedWith()
        if #shared > 0 then
            lines[#lines + 1] = " "
            lines[#lines + 1] = { text = format(L["Also used by: %s"], table.concat(shared, ", ")), accent = true }
            -- "there" points back at the list above, so the consequence needs no
            -- nouns of its own. It has to be said: a shared template's edits
            -- reach a screen you are not looking at, and naming the users is
            -- only the fact, not the warning.
            lines[#lines + 1] = L["Edits apply there too."]
        end
        GUI:ShowTooltip(self, { title = L["Templates"], lines = lines })
    end)
    ddBtn:SetScript("OnLeave", function() GUI:HideTooltip() end)

    -- When editing a raid auto-layout, default the NEW preset name to the
    -- layout's name (e.g. editing "31-40" → prefill "31-40") so making a
    -- per-layout preset is one click + Enter. nil (blank) otherwise. (Duplicate
    -- names after its source preset, not the layout.)
    local function EditingLayoutName()
        if not IsEditingLayout() then return nil end  -- mode-gated (raid only)
        local apu = DF.AutoProfilesUI
        if apu and apu.editingProfile then
            return apu.editingProfile.name
        end
        return nil
    end

    -- Action buttons. opts.iconButtons = true swaps the labeled buttons for
    -- compact tooltipped icon-only buttons (22x22) — used where the bar shares
    -- a row with other controls (Aura Designer header). Default stays labeled
    -- (Text Designer) so existing callers are untouched.
    local function CreateAction(labelText, iconName, width, onClick)
        if opts.iconButtons then
            local b = CreateFrame("Button", nil, bar, "BackdropTemplate")
            GUI:StyleButton(b, {
                width = 22, height = 22,
                icon = {
                    texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\" .. iconName,
                    size = 14, color = C_TEXT,
                },
            })
            b:SetScript("OnClick", function(self)
                onClick(self)
                PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            end)
            b:HookScript("OnEnter", function(self)
                GUI:ShowTooltip(self, { title = labelText})
            end)
            b:HookScript("OnLeave", function() GUI:HideTooltip() end)
            return b
        end
        return GUI:CreateButton(bar, labelText, width, 22, onClick)
    end

    local newBtn = CreateAction(L["New"], "add", 48, function()
        PromptPresetName(L["Name the new template:"], EditingLayoutName() or "", L["Create"], function(text)
            local n = DF:CreateDesignerPreset(kind, text)
            if n then
                DF:SetModeDesignerPreset(kind, getMode(), n)
                bar:Refresh(); onChange()
            end
        end)
    end)
    newBtn:SetPoint("LEFT", ddBtn, "RIGHT", 6, 0)

    local dupBtn = CreateAction(L["Duplicate"], "content_copy", 72, function()
        local cur = CurrentName()
        -- Duplicate defaults to "<source> copy" (New uses the layout name, but a
        -- duplicate is of a specific preset, so name it after the source).
        PromptPresetName(L["Name the duplicated template:"], cur .. " copy", L["Duplicate"], function(text)
            local n = DF:DuplicateDesignerPreset(kind, cur, text)
            if n then
                DF:SetModeDesignerPreset(kind, getMode(), n)
                bar:Refresh(); onChange()
            end
        end)
    end)
    dupBtn:SetPoint("LEFT", newBtn, "RIGHT", 4, 0)

    local renameBtn = CreateAction(L["Rename"], "edit", 62, function()
        local cur = CurrentName()
        if cur == DF.DEFAULT_PRESET then return end
        PromptPresetName(L["Rename template:"], cur, L["Rename"], function(text)
            DF:RenameDesignerPreset(kind, cur, text)
            bar:Refresh(); onChange()
        end)
    end)
    renameBtn:SetPoint("LEFT", dupBtn, "RIGHT", 4, 0)

    local delBtn = CreateAction(L["Delete"], "delete", 56, function()
        local cur = CurrentName()
        if cur == DF.DEFAULT_PRESET then return end
        ConfirmDeletePreset(kind, cur, function() bar:Refresh(); onChange() end)
    end)
    delBtn:SetPoint("LEFT", renameBtn, "RIGHT", 4, 0)

    local function SetActionEnabled(btn, on)
        if on then
            btn:Enable()
            if btn.Text then btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b) end
            if btn.Icon then btn.Icon:SetVertexColor(C_TEXT.r, C_TEXT.g, C_TEXT.b) end
        else
            btn:Disable()
            -- greyed: Default can't be renamed/deleted
            if btn.Text then btn.Text:SetTextColor(0.4, 0.4, 0.4) end
            if btn.Icon then btn.Icon:SetVertexColor(0.4, 0.4, 0.4) end
        end
    end

    function bar:Refresh()
        ddBtn.text:SetText(CurrentLabel())
        -- Make room for the share glyph only while it's up, so an unshared
        -- preset keeps the full label width.
        local isShared = #SharedWith() > 0
        shareIcon:SetShown(isShared)
        ddBtn.text:ClearAllPoints()
        ddBtn.text:SetPoint("LEFT", 6, 0)
        ddBtn.text:SetPoint("RIGHT", isShared and -30 or -16, 0)
        -- Rename/Delete act on the resolved preset; disable for the non-editable
        -- Default and while a layout is inheriting (you're following the global,
        -- not sitting on a layout-specific preset).
        local inheriting = IsEditingLayout() and DF.IsLayoutDesignerInheriting
            and DF:IsLayoutDesignerInheriting(kind)
        local canModify = (CurrentName() ~= DF.DEFAULT_PRESET) and not inheriting
        SetActionEnabled(renameBtn, canModify)
        SetActionEnabled(delBtn, canModify)
    end

    bar:Refresh()
    -- The sharing glyph reflects OTHER refs (the other mode, a pinned set, an
    -- auto layout), which can change without changing THIS mode's — and both
    -- designer pages early-return their rebuild when their own preset is
    -- unchanged, so the glyph would sit stale. Register the live bar so the
    -- shared page refresh can reach it. One slot per kind: a rebuilt page
    -- overwrites its own entry, and a torn-down bar is hidden, so nothing
    -- accumulates.
    GUI._designerPresetBars = GUI._designerPresetBars or {}
    GUI._designerPresetBars[kind] = bar
    return bar
end

function GUI:RefreshDesignerPresetBars()
    for _, bar in pairs(GUI._designerPresetBars or {}) do
        if bar.Refresh and bar:IsShown() then bar:Refresh() end
    end
end

-- Creates a button with an icon and text
-- iconName is the name of the icon file (without path/extension)
-- iconSize is optional (defaults to 16)
-- align: "center" (default) or "left". Pass "left" for wide / full-width
-- list-style buttons where centred content floats (see GUI:StyleButton).
function GUI:CreateIconButton(parent, iconName, text, width, height, func, iconSize, align)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    GUI:StyleButton(btn, {
        width = width or 120, height = height or 22,
        text = text,
        align = align,
        icon = {
            texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\" .. iconName,
            size = iconSize or 18,
            color = C_TEXT,
        },
    })

    btn:SetScript("OnClick", function(self)
        if func then func(self) end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    return btn
end

-- Creates a \"See Also:\" section with clickable links to related pages
-- links = { {pageId = \"display_tooltips\", label = \"Tooltips\"}, ... }
function GUI:CreateSeeAlso(parent, links)
    local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    container:SetHeight(32)
    -- The page's own footer: pinned to the bottom of the viewport on a SHORT
    -- page instead of floating wherever the content happened to end. See the
    -- footer block in the page layout.
    container.isPageFooter = true
    CreateElementBackdrop(container, {
        bgColor     = { 0.1, 0.1, 0.1, 0.5 },
        borderColor = { 0.3, 0.3, 0.3, 0.8 },
    })
    
    local label = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    label:SetPoint("TOPLEFT", 8, -10)
    label:SetText(L["See Also:"])
    label:SetTextColor(0.7, 0.7, 0.7)
    
    local linkButtons = {}
    local separators = {}
    
    for i, linkData in ipairs(links) do
        local link = CreateFrame("Button", nil, container)
        link:SetHeight(16)
        
        local linkText = link:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        linkText:SetPoint("TOPLEFT", 0, -1)
        linkText:SetText(linkData.label)
        local c = GetThemeColor()
        linkText:SetTextColor(c.r, c.g, c.b)
        link.text = linkText
        link.textWidth = linkText:GetStringWidth() + 4
        link:SetWidth(link.textWidth)
        
        link:SetScript("OnEnter", function(self)
            local h = GUI:LinkHoverColor(c)
            linkText:SetTextColor(h.r, h.g, h.b)
        end)
        link:SetScript("OnLeave", function(self)
            linkText:SetTextColor(c.r, c.g, c.b)
        end)
        link:SetScript("OnClick", function()
            if GUI.SelectTab then
                GUI.SelectTab(linkData.pageId)
            end
        end)
        
        table.insert(linkButtons, link)
        
        -- Create separator (hidden by default, shown as needed)
        if i < #links then
            local sep = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            sep:SetText("•")
            sep:SetTextColor(0.5, 0.5, 0.5)
            table.insert(separators, sep)
        end
    end
    
    -- Layout function that handles wrapping
    local function LayoutLinks()
        local containerWidth = container:GetWidth()
        if containerWidth < 50 then return end  -- Not sized yet
        
        local labelWidth = label:GetStringWidth() + 16
        local firstLinkX = labelWidth  -- Where first link starts
        local xOffset = labelWidth
        local yOffset = -9
        local lineHeight = 18
        local maxX = containerWidth - 10
        local rowCount = 1
        
        -- First pass: determine which links are on which row
        local linkRows = {}
        local tempX = labelWidth
        local currentRow = 1
        
        for i, link in ipairs(linkButtons) do
            local linkWidth = link.textWidth
            local sepWidth = (i < #linkButtons) and 14 or 0
            
            -- Check if we need to wrap
            if tempX + linkWidth > maxX and tempX > labelWidth then
                currentRow = currentRow + 1
                tempX = firstLinkX
            end
            
            linkRows[i] = currentRow
            tempX = tempX + linkWidth + sepWidth
        end
        
        rowCount = currentRow
        
        -- Second pass: position elements
        xOffset = labelWidth
        local lastRowForLink = 1
        
        for i, link in ipairs(linkButtons) do
            local linkWidth = link.textWidth
            
            -- Check if we need to wrap to new line
            if linkRows[i] > lastRowForLink then
                xOffset = firstLinkX
                yOffset = yOffset - lineHeight
                lastRowForLink = linkRows[i]
            end
            
            link:ClearAllPoints()
            link:SetPoint("TOPLEFT", container, "TOPLEFT", xOffset, yOffset)
            
            xOffset = xOffset + linkWidth + 2
            
            -- Position separator only if next link is on same row
            if separators[i] then
                if linkRows[i + 1] == linkRows[i] then
                    separators[i]:ClearAllPoints()
                    separators[i]:SetPoint("TOPLEFT", container, "TOPLEFT", xOffset, yOffset - 1)
                    separators[i]:Show()
                    xOffset = xOffset + 12
                else
                    separators[i]:Hide()
                end
            end
        end
        
        -- Adjust container height based on rows.
        --
        -- Snapped HERE, where the number is computed, because this widget
        -- MEASURES ITSELF: LayoutLinks runs from OnSizeChanged and from a
        -- C_Timer.After(0), i.e. a frame AFTER the page layout has run.
        -- Correcting the height after the fact cannot win -- whatever sets a
        -- grid-aligned height, this function overwrites it on the next frame,
        -- and the bar's bottom edge ends up split across two device rows.
        -- Measured: 28 units at 1.40625 px/unit is 39.375px, 0.375 off.
        local newHeight = SnapLen(container, 10 + (rowCount * lineHeight))
        container:SetHeight(newHeight)
        container.layoutHeight = newHeight + 5
    end
    
    container:SetScript("OnSizeChanged", LayoutLinks)
    
    -- Initial layout after a frame (to let width be set)
    C_Timer.After(0, LayoutLinks)
    
    return container
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
GUI.IsOverrideDebugMode = IsOverrideDebugMode

-- Function to refresh all override indicators
local function RefreshAllOverrideIndicators()
    for _, widget in ipairs(overrideWidgets) do
        if widget and widget.UpdateOverrideIndicators then
            widget:UpdateOverrideIndicators()
        end
    end
    -- Also refresh position override indicator
    if GUI.UpdatePositionOverrideIndicator then
        GUI.UpdatePositionOverrideIndicator()
    end
    -- Refresh tab override stars (auto-profiles)
    if DF.AutoProfilesUI and DF.AutoProfilesUI.RefreshTabOverrideStars then
        DF.AutoProfilesUI:RefreshTabOverrideStars()
    end
end
GUI.RefreshAllOverrideIndicators = RefreshAllOverrideIndicators

-- Allow other files to register widgets with override indicators
function GUI.RegisterOverrideWidget(widget)
    table.insert(overrideWidgets, widget)
end

-- NOT a dump, despite what the old description ("Auto layout override table
-- dump") claimed — it prints no table. It forces every reset button / override
-- marker visible regardless of override state, so you can see which controls
-- carry the machinery at all. S.overrideDebugMode is live: read by
-- GUI.IsOverrideDebugMode and three marker call sites.
DF:RegisterDebugSlash("DFOVERRIDEDEBUG", "Force-show every override marker and reset button", true, "/dfoverridedebug")
SlashCmdList["DFOVERRIDEDEBUG"] = function()
    S.overrideDebugMode = not S.overrideDebugMode
    DF:Say("Override debug mode " .. (S.overrideDebugMode and "ENABLED" or "DISABLED"))
    -- Refresh all override indicators
    RefreshAllOverrideIndicators()
    -- Also update position panel if open
    if DF.positionPanel and DF.positionPanel.UpdatePositionOverride then
        DF.positionPanel.UpdatePositionOverride()
    end
end

-- ============================================================
-- SHARED OVERRIDE CONTROLS
-- One "override active" marker (a coloured dot) + one "reset to global" button
-- (red, icon-only, danger tone — reads like the Reset Page button), so every
-- override control across the addon speaks one visual language. Callers create
-- them, position the returned frames, and toggle Show/Hide.
-- ============================================================
-- Single source of truth for the override-marker colour.
GUI.OVERRIDE_MARKER_COLOR = { 1, 0.8, 0.2 }

-- A coloured dot marking "this setting is overridden". Returns a hidden Button
-- so the caller can set .tooltipText / .tooltipSubText for a hover tooltip.
-- `size` = dot diameter in px (default 12); the hit frame is a touch larger.
function GUI:CreateOverrideMarker(parent, size)
    size = size or 12
    local c = GUI.OVERRIDE_MARKER_COLOR
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
    icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\dot")
    icon:SetVertexColor(c[1], c[2], c[3])
    btn.icon = icon
    btn:SetScript("OnEnter", function(s)
        if s.tooltipText then
            GUI:ShowTooltip(s, { title = s.tooltipText, lines = s.tooltipSubText and { s.tooltipSubText } or nil })
        end
    end)
    btn:SetScript("OnLeave", function() GUI:HideTooltip() end)
    btn:Hide()
    return btn
end

-- A bare checkbox sized for a LIST ROW — no label, no db binding, no settings-row
-- geometry. GUI:CreateCheckbox is a whole 30px settings row with its own label and
-- hit rect, which is the wrong shape entirely inside a 22px pooled list row that
-- already owns its own text, count and selection accent.
--
-- The caller drives it: :SetChecked(bool) to paint, opts.onClick to react. It does
-- NOT read or write the db itself, because a list row's meaning changes per bind
-- (a pooled row is a different filter every refresh) and a captured dbKey would go
-- stale the moment the pool rebinds.
--
-- ⚠ Clicks deliberately do NOT propagate. The override marker above lets them fall
-- through because it is a passive marker; this is a control, and on a clickable row
-- the two gestures must stay separate — tick the box to switch the filter on, click
-- anywhere else to select it. Nothing here calls SetPropagateMouseClicks, which is
-- PROTECTED on 12.1 anyway (see the note in CreateOverrideMarker).
--
-- ⚠ The BOX ITSELF is GUI:StyleCheckButton, the addon's one checkbox look — do not
-- hand-roll it again. This was hand-rolled once and drifted four ways: it drew the
-- Media\Icons\check GLYPH where every other checkbox in the addon draws a filled
-- WHITE8x8 square (a different SYMBOL, not a different style), it skipped PixelUtil
-- so it alone was unsnapped, it had no hover wash, and it recoloured its BORDER when
-- checked, which nothing else does. CreateDebugCategoryRow is the precedent for this
-- exact case — a list row with a checkbox — at the same size.
--
-- manualCheck because this is a plain Button, not a CheckButton: SetChecked below
-- drives the mark. A real CheckButton would draw its checked mark through the native
-- checked state, which has no disabled-checked texture here — so a greyed-but-ticked
-- row (every filter row while All Buffs is on) would lose its tick entirely.
--
-- opts: { size = 16, checkSize = 9, onClick = function(checked) end,
--         tooltip = title, tooltipDesc = line }
function GUI:CreateRowToggle(parent, opts)
    opts = opts or {}
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    GUI:StyleCheckButton(btn, {
        size        = opts.size or 16,
        checkSize   = opts.checkSize or 9,
        manualCheck = true,
    })

    btn.checked = false
    function btn:SetChecked(on)
        self.checked = on and true or false
        -- Re-tint on every paint. StyleCheckButton registers its theme listener on
        -- this button's PARENT, which for a pooled list row is a frame inside a
        -- scroll child that the page's theme walk never visits (same trap as
        -- StyleButton's wash). The list rebinds every row on refresh, and a refresh
        -- is what a mode switch produces, so painting the accent here is what
        -- actually carries party purple -> raid orange.
        self.ApplyThemeColor(GetThemeColor())
        self.Check:SetShown(self.checked)
    end

    btn:SetScript("OnClick", function(s)
        if s.onClick then s.onClick(not s.checked) end
    end)
    btn:SetScript("OnEnter", function(s)
        if s.tooltipText then
            GUI:ShowTooltip(s, { title = s.tooltipText, lines = s.tooltipDesc and { s.tooltipDesc } or nil })
        end
    end)
    btn:SetScript("OnLeave", function() GUI:HideTooltip() end)

    btn.onClick = opts.onClick
    btn.tooltipText = opts.tooltip
    btn.tooltipDesc = opts.tooltipDesc
    btn:SetChecked(false)
    return btn
end

-- A "reset to global" button — red, icon-only, danger tone (matches the Reset
-- Page button). Returns a hidden Button. opts: { size = 18, tooltip = title,
-- tooltipDesc = line, onClick = fn }.
function GUI:CreateOverrideResetButton(parent, opts)
    opts = opts or {}
    local size = opts.size or 18
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    GUI:StyleButton(btn, {
        width = size, height = size,
        tone = "danger",
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\refresh", size = size - 6 },
    })
    btn:Hide()
    -- StyleButton owns OnEnter (hover wash); hook the tooltip on top.
    btn:HookScript("OnEnter", function(self)
        if opts.tooltip then
            GUI:ShowTooltip(self, { title = opts.tooltip, lines = opts.tooltipDesc and { opts.tooltipDesc } or nil })
        end
    end)
    btn:HookScript("OnLeave", function() GUI:HideTooltip() end)
    if opts.onClick then btn:SetScript("OnClick", opts.onClick) end
    return btn
end

local function AddOverrideIndicators(container, lbl, dbKey, onReset, verticalOffset, optionsMap, dbTable)
    -- Skip for proxy tables (e.g. Aura Designer) that don't support per-key override tracking
    if dbTable and rawget(dbTable, "_skipOverrideIndicators") then return end
    verticalOffset = verticalOffset or 0
    container.overrideOptionsMap = optionsMap
    
    -- Reset button (red, icon-only) at top-right; the override marker (dot)
    -- sits to its left. Both are shared helpers (GUI:CreateOverride*).
    local resetBtn = GUI:CreateOverrideResetButton(container, {
        tooltip = L["Reset to Global"],
        tooltipDesc = L["Reset this setting to its global value."],
        onClick = function() if onReset then onReset() end end,
    })
    resetBtn:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, verticalOffset)
    container.overrideResetBtn = resetBtn

    local starBtn = GUI:CreateOverrideMarker(container)
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
    checkIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\check")
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
            self.overrideGlobalText:SetTextColor(1, 0.8, 0.2)  -- Yellow for visibility
            self.overrideGlobalText:Show()
            self.overrideCheckIcon:Hide()
            return
        end
        
        -- Only show when in raid mode
        local GUI = DF.GUI
        if not GUI or GUI.SelectedMode ~= "raid" then
            self.overrideStar:Hide()
            self.overrideResetBtn:Hide()
            self.overrideGlobalText:Hide()
            self.overrideCheckIcon:Hide()
            return
        end

        local AutoProfilesUI = DF.AutoProfilesUI
        local isEditing = AutoProfilesUI and AutoProfilesUI:IsEditing()
        local isRuntimeOverridden = AutoProfilesUI and AutoProfilesUI:IsOverriddenByRuntime(dbKey)

        -- Hide everything if not editing AND not runtime-overridden
        if not isEditing and not isRuntimeOverridden then
            self.overrideStar:Hide()
            self.overrideResetBtn:Hide()
            self.overrideGlobalText:Hide()
            self.overrideCheckIcon:Hide()
            return
        end

        -- Runtime override mode: show star + global value, but no reset button
        if isRuntimeOverridden and not isEditing then
            self.overrideStar.tooltipText = L["Override active"]
            self.overrideStar.tooltipSubText = L["This setting is being overridden by the active auto layout profile. To change it, edit the profile in the Auto Layouts tab."]
            self.overrideStar:Show()
            self.overrideResetBtn:Hide()  -- Can't reset runtime overrides from controls
            self.overrideCheckIcon:Hide()

            local globalValue = AutoProfilesUI:GetRuntimeGlobalValue(dbKey)

            -- Format global value for display
            local globalDisplay
            if type(globalValue) == "boolean" then
                globalDisplay = globalValue and L["Yes"] or L["No"]
            elseif type(globalValue) == "number" then
                if globalValue == math.floor(globalValue) then
                    globalDisplay = tostring(globalValue)
                else
                    globalDisplay = string.format("%.2f", globalValue)
                end
            elseif type(globalValue) == "table" then
                if globalValue.r then
                    globalDisplay = L["Color"]
                else
                    globalDisplay = "..."
                end
            elseif type(globalValue) == "string" and self.overrideOptionsMap and self.overrideOptionsMap[globalValue] then
                local mapped = self.overrideOptionsMap[globalValue]
                if type(mapped) == "table" then
                    globalDisplay = mapped.text or mapped.label or globalValue
                else
                    globalDisplay = tostring(mapped)
                end
            else
                globalDisplay = tostring(globalValue or L["None"])
            end

            self.overrideGlobalText:SetText(string.format(L["(Global: %s)"], globalDisplay))
            self.overrideGlobalText:ClearAllPoints()
            self.overrideGlobalText:SetPoint("LEFT", lbl, "RIGHT", 4, 0)
            self.overrideGlobalText:SetTextColor(0.5, 0.5, 0.5)
            self.overrideGlobalText:Show()
            return
        end

        -- Editing mode: existing behavior
        -- Check if setting is overridden
        local isOverridden = AutoProfilesUI:IsSettingOverridden(dbKey)
        local globalValue = AutoProfilesUI:GetGlobalValue(dbKey)

        -- Show/hide star and reset button
        if isOverridden then
            self.overrideStar.tooltipText = L["Override active"]
            self.overrideStar.tooltipSubText = L["This setting differs from the global profile value. Click the reset button to revert."]
            self.overrideStar:Show()
            self.overrideResetBtn:Show()
        else
            self.overrideStar:Hide()
            self.overrideResetBtn:Hide()
        end

        -- Format global value for display
        local globalDisplay
        if type(globalValue) == "boolean" then
            globalDisplay = globalValue and L["Yes"] or L["No"]
        elseif type(globalValue) == "number" then
            if globalValue == math.floor(globalValue) then
                globalDisplay = tostring(globalValue)
            else
                globalDisplay = string.format("%.2f", globalValue)
            end
        elseif type(globalValue) == "table" then
            -- Color table
            if globalValue.r then
                globalDisplay = L["Color"]
            else
                globalDisplay = "..."
            end
        elseif type(globalValue) == "string" and self.overrideOptionsMap and self.overrideOptionsMap[globalValue] then
            local mapped = self.overrideOptionsMap[globalValue]
            if type(mapped) == "table" then
                globalDisplay = mapped.text or mapped.label or globalValue
            else
                globalDisplay = tostring(mapped)
            end
        else
            globalDisplay = tostring(globalValue or L["None"])
        end

        -- Show global value inline with label
        self.overrideGlobalText:SetText(string.format(L["(Global: %s)"], globalDisplay))
        self.overrideGlobalText:ClearAllPoints()
        self.overrideGlobalText:SetPoint("LEFT", lbl, "RIGHT", 4, 0)

        if isOverridden then
            self.overrideGlobalText:SetTextColor(0.5, 0.5, 0.5)
            self.overrideCheckIcon:Hide()
        else
            self.overrideGlobalText:SetTextColor(0.3, 0.6, 0.3)
            -- Position check icon after text
            self.overrideCheckIcon:ClearAllPoints()
            self.overrideCheckIcon:SetPoint("LEFT", self.overrideGlobalText, "RIGHT", 2, 0)
            self.overrideCheckIcon:Show()
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
local function AddOrderListOverrideIndicators(container, dbKey, onReset)
    -- Reset button (red, icon-only) + override marker (dot) — shared helpers.
    local resetBtn = GUI:CreateOverrideResetButton(container, {
        tooltip = L["Reset to Global Order"],
        onClick = function() if onReset then onReset() end end,
    })
    resetBtn:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 14)
    container.overrideResetBtn = resetBtn

    local starBtn = GUI:CreateOverrideMarker(container)
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
        
        -- Only show when in raid mode and editing
        local GUI = DF.GUI
        if not GUI or GUI.SelectedMode ~= "raid" then
            self.overrideStar:Hide()
            self.overrideResetBtn:Hide()
            self.overrideModifiedText:Hide()
            return
        end
        
        local AutoProfilesUI = DF.AutoProfilesUI
        if not AutoProfilesUI or not AutoProfilesUI:IsEditing() then
            self.overrideStar:Hide()
            self.overrideResetBtn:Hide()
            self.overrideModifiedText:Hide()
            return
        end
        
        local isOverridden = AutoProfilesUI:IsSettingOverridden(dbKey)
        
        if isOverridden then
            self.overrideStar.tooltipText = L["Override active"]
            self.overrideStar.tooltipSubText = L["This setting differs from the global profile value. Click the reset button to revert."]
            self.overrideStar:Show()
            self.overrideResetBtn:Show()
            self.overrideModifiedText:Show()
        else
            self.overrideStar:Hide()
            self.overrideResetBtn:Hide()
            self.overrideModifiedText:Hide()
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
function GUI:StyleCheckButton(cb, opts)
    opts = opts or {}
    PixelUtil.SetSize(cb, opts.size or 18, opts.size or 18)
    CreateElementBackdrop(cb)

    local check = cb.Check or cb:CreateTexture(nil, "OVERLAY")
    check:SetTexture("Interface\\Buttons\\WHITE8x8")
    local cs = opts.checkSize or 10
    PixelUtil.SetSize(check, cs, cs)
    PixelUtil.SetPoint(check, "CENTER", cb, "CENTER", 0, 0)

    local accent = opts.accent
    local col = accent or GetThemeColor()
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
            cb.ApplyThemeColor(GetThemeColor())
        end
        local root = opts.themeRoot or cb:GetParent()
        if root then
            root.ThemeListeners = root.ThemeListeners or {}
            table.insert(root.ThemeListeners, cb)
        end
    end
    return check
end

function GUI:CreateCheckbox(parent, label, dbTable, dbKey, callback, customGet, customSet, overrideKey)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(220, 24)
    container.preferredHeight = GUI.RowHeight.checkbox   -- factory-owned slot height (see GUI.RowHeight)
    container.rowKind = "checkbox"       -- /df debug gapcheck groups the spacing report by this
    container.fixedRowHeight = true

    local cb = CreateFrame("CheckButton", nil, container, "BackdropTemplate")
    cb:SetPoint("LEFT", 0, 0)
    -- Box + themed check come from the shared styler (single source of truth).
    GUI:StyleCheckButton(cb, { themeRoot = parent })

    -- Label
    local txt = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    txt:SetPoint("LEFT", cb, "RIGHT", 8, 0)
    txt:SetText(label)
    txt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    container.label = txt  -- exposed so callers can re-font / anchor a subtitle

    -- Determine the key to use for override indicators
    local effectiveOverrideKey = overrideKey or dbKey
    
    -- Add override indicators if we have a key (either dbKey or overrideKey)
    if effectiveOverrideKey and type(effectiveOverrideKey) == "string" then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(effectiveOverrideKey)
                -- Refresh to global value
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(effectiveOverrideKey)
                cb:SetChecked(globalVal)
                if dbTable and dbKey then
                    dbTable[dbKey] = globalVal
                elseif customSet then
                    customSet(globalVal)
                end
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(globalVal)
                end
                DF:UpdateAll()
                if callback then callback() end
            end
        end
        AddOverrideIndicators(container, txt, effectiveOverrideKey, onReset, nil, nil, dbTable)
    end
    
    local function UpdateState()
        local val = false
        if customGet then val = customGet() elseif dbTable and dbKey then val = dbTable[dbKey] end
        cb:SetChecked(val)
        -- Update override indicators
        if container.UpdateOverrideIndicators then
            container:UpdateOverrideIndicators(val)
        end
    end
    
    container:SetScript("OnShow", UpdateState)
    -- Re-read the source and repaint the box, for a caller that changed the value
    -- behind the widget's back (a "set all" button). Same contract as
    -- CreateSegmentToggle:Refresh(); before this, call sites reached for a
    -- Hide()/Show() bounce to fire the OnShow above.
    container.Refresh = UpdateState
    cb:SetScript("OnClick", function(self)
        local val = self:GetChecked()
        -- Was gated on DF.debugEnabled and printed straight to CHAT, bypassing the
        -- console entirely. GUI is the right category and it is already declared.
        DF:Debug("GUI", "checkbox OnClick: dbKey=%s overrideKey=%s value=%s",
            tostring(dbKey), tostring(overrideKey), tostring(val))

        -- Runtime override protection: redirect to baseline, skip refresh
        if GUI.SelectedMode == "raid" and DF.AutoProfilesUI
           and DF.AutoProfilesUI:HandleRuntimeWrite(effectiveOverrideKey, val) then
            if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators(val) end
            return
        end

        if customSet then customSet(val) elseif dbTable and dbKey then dbTable[dbKey] = val end

        -- If editing a profile, also set the override (use effectiveOverrideKey)
        if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and effectiveOverrideKey then
            DF.AutoProfilesUI:SetProfileSetting(effectiveOverrideKey, val)
        end
        
        -- Update override indicators
        if container.UpdateOverrideIndicators then
            container:UpdateOverrideIndicators(val)
        end
        
        if callback then 
            DF:Debug("GUI", "checkbox OnClick: calling callback")
            callback() 
        end
        if parent.RefreshStates then 
            DF:Debug("GUI", "checkbox OnClick: calling RefreshStates")
            parent:RefreshStates() 
        end
        DF:Debug("GUI", "checkbox OnClick: calling DF:UpdateAll")
        DF:UpdateAll()
    end)
    
    container.SetEnabled = function(self, enabled)
        -- Dim the whole widget (box + check fill + label) so a disabled CHECKED
        -- box greys too: native SetEnabled has no DisabledCheckedTexture, so the
        -- accent check would otherwise stay full-bright.
        self:SetAlpha(enabled and 1 or 0.4)
        cb:SetEnabled(enabled)
        if enabled then
            txt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            txt:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
    end

    -- Tooltip: shared attach on the LABEL only (see GUI:AttachTooltip). The
    -- earlier hit-rect arithmetic here is gone with it — the hit frame is anchored
    -- to the FontString, so a label overflowing the fixed 220 container is covered
    -- for free rather than by widening the container's hit rect to match.
    GUI:AttachTooltip(container, label, txt)

    UpdateState()
    
    -- SEARCH: Register this setting
    if DF.Search then
        local hasCustomGetSet = (customGet ~= nil or customSet ~= nil)
        if dbKey and type(dbKey) == "string" then
            container.searchEntry = DF.Search:RegisterCheckbox(label, dbKey, nil, false, callback)
        elseif hasCustomGetSet then
            container.searchEntry = DF.Search:RegisterCheckbox(label, nil, nil, true, callback)
        end
    end
    
    return container
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
-- API: GUI:CreateSegmentToggle(parent, segments, dbTable, dbKey, callback, opts)
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
function GUI:CreateSegmentToggle(parent, segments, dbTable, dbKey, callback, opts)
    opts = opts or {}
    local segW = opts.segmentWidth or 26
    local h = opts.height or 18
    local pad = 1   -- track lip around the buttons

    local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    container:SetSize(segW * #segments + pad * 2, h + pad * 2)
    CreateElementBackdrop(container)   -- the recessed track behind every segment

    -- One read/write pair for both pathways, so the click handler and Refresh
    -- can't drift apart. Explicit ifs, not `a and b or c` — a stored value of
    -- false/nil is legitimate.
    local function GetValue()
        if opts.customGet then return opts.customGet() end
        if dbTable and dbKey then return dbTable[dbKey] end
    end
    local function SetValue(v)
        if opts.customSet then opts.customSet(v) return true end
        if dbTable and dbKey then dbTable[dbKey] = v return true end
        return false
    end

    local buttons = {}
    for i, seg in ipairs(segments) do
        local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
        GUI:StyleButton(btn, { width = segW, height = h, text = seg.label })
        GUI:SetSettingsFont(btn.Text, 9, "")
        btn:SetPoint("TOPLEFT", container, "TOPLEFT", pad + (i - 1) * segW, -pad)
        btn.value = seg.value
        if seg.tooltip then
            btn:HookScript("OnEnter", function(self)
                GUI:ShowTooltip(self, { title = seg.tooltip, lines = opts.tooltipLines })
            end)
            btn:HookScript("OnLeave", function() GUI:HideTooltip() end)
        end
        btn:SetScript("OnClick", function(self)
            if GetValue() == self.value then return end
            if not SetValue(self.value) then return end
            container:Refresh()
            if callback then callback(self.value) end
        end)
        buttons[i] = btn
    end

    -- Selection: the shared accent border/fill via SetActive, plus a bright/dim
    -- label so the state still reads at a glance in a themed accent that is close
    -- to the resting border colour.
    function container:Refresh()
        local cur = GetValue()
        local matched = false
        for _, b in ipairs(buttons) do if b.value == cur then matched = true end end
        if not matched then cur = opts.fallbackValue end
        for _, b in ipairs(buttons) do
            local on = (b.value == cur)
            b:SetActive(on)
            if b.Text then
                local c = on and C_TEXT or C_TEXT_DIM
                b.Text:SetTextColor(c.r, c.g, c.b)
            end
        end
    end
    container.refreshContent = function(self) self:Refresh() end

    container.SetEnabled = function(self, enabled)
        self:SetAlpha(enabled and 1 or 0.4)
        for _, b in ipairs(buttons) do b:EnableMouse(enabled) end
    end

    container.UpdateTheme = function() container:Refresh() end
    if not parent.ThemeListeners then parent.ThemeListeners = {} end
    table.insert(parent.ThemeListeners, container)

    container:Refresh()
    return container
end


-- ============================================================
-- DEBUG CATEGORY ROW
-- A wide row with checkbox + bold category name + description.
-- The whole row is clickable, hover shows a background highlight,
-- and the description is also surfaced as a tooltip on hover so it
-- remains accessible even if it gets visually truncated.
--
-- Used by the Debug > Categories sub-tab. The categoryKey writes
-- directly to DandersFramesDB_v2.debug.filters.
-- ============================================================
-- opts.noisy marks a firehose category: one user action can produce dozens of
-- lines, which evicts the trace the log was opened to capture. It renders as the
-- shared caution icon with its own tooltip rather than a "(noisy)" suffix baked
-- into the description string -- the suffix was untranslatable in place, and it
-- competed with the description for the same line of text.
function GUI:CreateDebugCategoryRow(parent, categoryKey, description, width, noisy)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(width or 520, 28)
    row:EnableMouse(true)

    -- Hover background
    row.hoverBg = row:CreateTexture(nil, "BACKGROUND")
    row.hoverBg:SetAllPoints()
    row.hoverBg:SetColorTexture(1, 1, 1, 0.05)
    row.hoverBg:Hide()

    -- Checkbox
    local cb = CreateFrame("CheckButton", nil, row, "BackdropTemplate")
    cb:SetPoint("LEFT", 4, 0)
    GUI:StyleCheckButton(cb, { size = 16, checkSize = 9, themeRoot = parent })
    cb:EnableMouse(false)  -- forward clicks to the row

    -- Category name (bold, full opacity)
    local nameTxt = row:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
    nameTxt:SetPoint("LEFT", cb, "RIGHT", 8, 0)
    nameTxt:SetWidth(86)
    nameTxt:SetJustifyH("LEFT")
    nameTxt:SetText(categoryKey)
    nameTxt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    -- Caution icon for a firehose category. Its own hit area, so it can carry a
    -- different tooltip from the row without stealing the row's click: the frame
    -- only enables mouse, it has no OnMouseUp, so a click still falls through to
    -- the row underneath and toggles the category like anywhere else on it.
    local noisyIcon
    if noisy then
        noisyIcon = CreateFrame("Frame", nil, row)
        noisyIcon:SetSize(14, 14)
        noisyIcon:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        noisyIcon:EnableMouse(true)
        noisyIcon:SetFrameLevel(row:GetFrameLevel() + 2)
        local tex = noisyIcon:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints()
        tex:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\warning")
        -- The caution tone's ICON colour, read straight from the shared tone table
        -- so this stays in step with every banner and note that uses it.
        local ic = INFO_BANNER_TONES.caution.iconColor
        tex:SetVertexColor(ic[1], ic[2], ic[3])
        noisyIcon:SetScript("OnEnter", function(self)
            -- Keep the row's wash up: the pointer is still over the row, and
            -- letting it drop would read as the row losing focus.
            row.hoverBg:Show()
            GUI:ShowTooltip(self, {
                title = L["Noisy category"],
                lines = { L["This category can fill the log very quickly, burying the entries you are looking for."],
                          L["Turn it on only while reproducing the bug it relates to."] },
                tone = "caution",
            })
        end)
        noisyIcon:SetScript("OnLeave", function()
            row.hoverBg:Hide()
            GUI:HideTooltip()
        end)
        row.noisyIcon = noisyIcon
    end

    -- Description (dim, fills remaining space, wraps if too long)
    if description and description ~= "" then
        local descTxt = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        descTxt:SetPoint("LEFT", nameTxt, "RIGHT", 12, 0)
        -- Stop short of the icon rather than running under it.
        if noisyIcon then
            descTxt:SetPoint("RIGHT", noisyIcon, "LEFT", -6, 0)
        else
            descTxt:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        end
        descTxt:SetJustifyH("LEFT")
        descTxt:SetText(description)
        descTxt:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        row.descTxt = descTxt
    end

    -- State helpers — read/write filters[categoryKey]
    -- Absent or true = logged, explicit false = not logged
    row.RefreshState = function()
        local filters = DandersFramesDB_v2 and DandersFramesDB_v2.debug and DandersFramesDB_v2.debug.filters
        local checked = (not filters) or filters[categoryKey] ~= false
        cb:SetChecked(checked)
    end

    local function ToggleState()
        local filters = DandersFramesDB_v2 and DandersFramesDB_v2.debug and DandersFramesDB_v2.debug.filters
        if not filters then return end
        -- Toggle: false -> true, anything else -> false
        if filters[categoryKey] == false then
            filters[categoryKey] = true
        else
            filters[categoryKey] = false
        end
        row.RefreshState()
        if DF.DebugConsole then DF.DebugConsole:RefreshDisplay() end
    end

    row:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then ToggleState() end
    end)

    row:SetScript("OnEnter", function(self)
        self.hoverBg:Show()
        if description and description ~= "" then
            GUI:ShowTooltip(self, { title = categoryKey, lines = { description } })
        end
    end)
    row:SetScript("OnLeave", function(self)
        self.hoverBg:Hide()
        GUI:HideTooltip()
    end)

    row:SetScript("OnShow", row.RefreshState)
    row.RefreshState()

    return row
end

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
function GUI:StyleEditBox(eb, opts)
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

function GUI:CreateInput(parent, label, width)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width or 180, 44)
    
    local lbl = frame:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    local editbox = CreateFrame("EditBox", nil, frame)
    -- Two-corner anchored, so the offset and the height are the ONLY levers --
    -- Nothing corrects a frame's position at runtime, and controls are not
    -- position-corrected at all any more. Snap both and all four edges land.
    local ebY = SnapLen(editbox, -15) or -15
    editbox:SetPoint("TOPLEFT", 0, ebY)
    editbox:SetPoint("TOPRIGHT", 0, ebY)
    editbox:SetHeight(SnapLen(editbox, 24) or 24)
    GUI:StyleEditBox(editbox)   -- shared input chrome: fill, border, font, insets
    editbox:SetAutoFocus(false)
    editbox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editbox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    -- Grey-when-disabled parity with CreateEditBox (cheap insurance if ever placed
    -- in a gated group): dim the whole widget + block editing.
    frame.SetEnabled = function(self, enabled)
        self:SetAlpha(enabled and 1 or 0.4)
        editbox:SetEnabled(enabled)
        if enabled then
            lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            lbl:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
    end

    frame.EditBox = editbox
    -- Tooltip: shared attach on the LABEL only. This factory carried no tooltip
    -- support at all, so a caller that set .tooltip on it got silence —
    -- Options.lua's custom range-spell input did exactly that, and its
    -- explanation never appeared. Keeping it off the edit box also means it can't
    -- cover what you are typing.
    GUI:AttachTooltip(frame, label, lbl)
    return frame
end

-- CreateEditBox: Text input with db binding (for settings like custom text)
function GUI:CreateEditBox(parent, label, dbTable, dbKey, callback, width, placeholder)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width or 180, 44)
    frame.preferredHeight = GUI.RowHeight.editbox   -- factory-owned slot height (see GUI.RowHeight)
    frame.rowKind = "editbox"
    frame.fixedRowHeight = true
    
    local lbl = frame:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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
                if frame.EditBox then
                    frame.EditBox:SetText(globalVal or "")
                end
                if frame.UpdateOverrideIndicators then
                    frame:UpdateOverrideIndicators(globalVal)
                end
                DF:UpdateAll()
                if callback then callback() end
            end
        end
        AddOverrideIndicators(frame, lbl, dbKey, onReset, 6, nil, dbTable)
    end
    
    local editbox = CreateFrame("EditBox", nil, frame)
    -- Two-corner anchored, so the offset and the height are the ONLY levers --
    -- Nothing corrects a frame's position at runtime, and controls are not
    -- position-corrected at all any more. Snap both and all four edges land.
    local ebY = SnapLen(editbox, -15) or -15
    editbox:SetPoint("TOPLEFT", 0, ebY)
    editbox:SetPoint("TOPRIGHT", 0, ebY)
    editbox:SetHeight(SnapLen(editbox, 24) or 24)
    GUI:StyleEditBox(editbox)   -- shared input chrome: fill, border, font, insets
    editbox:SetAutoFocus(false)

    -- Set initial value from db
    if dbTable and dbKey then
        editbox:SetText(dbTable[dbKey] or "")
    end
    
    -- Save on enter or focus lost
    local function SaveValue()
        if dbTable and dbKey then
            local val = editbox:GetText()
            -- Runtime override protection
            if GUI.SelectedMode == "raid" and DF.AutoProfilesUI
               and DF.AutoProfilesUI:HandleRuntimeWrite(dbKey, val) then
                if frame.UpdateOverrideIndicators then frame:UpdateOverrideIndicators(val) end
                return
            end
            dbTable[dbKey] = val
            -- Track override when editing a profile
            if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() then
                DF.AutoProfilesUI:SetProfileSetting(dbKey, val)
            end
            if frame.UpdateOverrideIndicators then
                frame:UpdateOverrideIndicators(val)
            end
            if callback then callback() end
        end
    end
    
    editbox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editbox:SetScript("OnEnterPressed", function(self)
        SaveValue()
        self:ClearFocus()
    end)
    editbox:SetScript("OnEditFocusLost", SaveValue)
    
    -- Optional placeholder: greyed example text shown while the box is empty
    -- and unfocused. Purely cosmetic — never written to the db.
    if placeholder and placeholder ~= "" then
        local ph = editbox:CreateFontString(nil, "ARTWORK", "DFFontHighlightSmall")
        ph:SetPoint("LEFT", 5, 0)
        ph:SetPoint("RIGHT", -5, 0)
        ph:SetJustifyH("LEFT")
        ph:SetText(placeholder)
        ph:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.55)
        local function UpdatePlaceholder()
            ph:SetShown(not editbox:HasFocus() and editbox:GetText() == "")
        end
        -- Exposed so a caller that puts something INSIDE the box (see
        -- GUI:AddEditBoxIcon) can move the placeholder clear of it.
        editbox.Placeholder = ph
        editbox.UpdatePlaceholder = UpdatePlaceholder
        editbox:HookScript("OnTextChanged", UpdatePlaceholder)
        editbox:HookScript("OnEditFocusGained", UpdatePlaceholder)
        editbox:HookScript("OnEditFocusLost", UpdatePlaceholder)
        UpdatePlaceholder()
    end

    -- Refresh override indicators on show
    frame:SetScript("OnShow", function()
        if dbTable and dbKey then
            editbox:SetText(dbTable[dbKey] or "")
        end
        if frame.UpdateOverrideIndicators then
            frame:UpdateOverrideIndicators(dbTable and dbTable[dbKey])
        end
        if editbox.UpdatePlaceholder then editbox.UpdatePlaceholder() end
    end)

    -- Grey-when-disabled: the grey loop (RefreshChildStates) calls widget:SetEnabled,
    -- but this frame had none, so a disabled group left the input full-bright AND
    -- editable. Dim the whole widget + block editing, matching the other helpers.
    frame.SetEnabled = function(self, enabled)
        self:SetAlpha(enabled and 1 or 0.4)
        editbox:SetEnabled(enabled)
        if enabled then
            lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            lbl:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
    end

    frame.EditBox = editbox
    return frame
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
function GUI:AddEditBoxIcon(editbox, texture, size)
    if not editbox or not texture then return end
    size = size or 14
    local icon = editbox:CreateTexture(nil, "OVERLAY")
    icon:SetSize(size, size)
    icon:SetPoint("LEFT", 6, 0)
    icon:SetTexture(texture)
    icon:SetVertexColor(0.72, 0.72, 0.72)
    editbox.Icon = icon

    local left = 6 + size + 5
    local _, right, top, bottom = editbox:GetTextInsets()
    editbox:SetTextInsets(left, right, top, bottom)
    if editbox.Placeholder then
        editbox.Placeholder:SetPoint("LEFT", left, 0)
    end
    return icon
end

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

function GUI:CreateTextArea(parent, opts)
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
        GUI:SetSettingsFont(eb, opts.fontSize, opts.fontFlags or "")
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

-- customGet / customSet (optional, matches CreateDropdown's pattern): when
-- provided, the slider routes its reads and writes through these functions
-- instead of dbTable[dbKey] directly. Used by widgets whose underlying value
-- lives inside a nested table (e.g. Border Alpha → <prefix>BorderColor.a),
-- where the plain `dbTable[dbKey] = v` path can't express the nesting.
-- Consumers that pass customSet typically pass dbKey = nil so the
-- auto-profile override system doesn't track a key that doesn't exist at the
-- top level of dbTable.
-- accentColor (optional {r,g,b}): fixed thumb/fill colour instead of the mode
-- theme — for ClickCasting (green) / Search (blue) which keep their identity.

function GUI:CreateSlider(parent, label, minVal, maxVal, step, dbTable, dbKey, callback, lightweightUpdate, usePreviewMode, customGet, customSet, accentColor)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 50)
    container.preferredHeight = GUI.RowHeight.slider   -- factory-owned slot height (see GUI.RowHeight)
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
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(dbKey)
                -- Refresh to global value
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(dbKey)
                dbTable[dbKey] = globalVal
                -- Update slider display
                if container.slider then
                    container.slider:SetValue(globalVal)
                end
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(globalVal)
                end
                DF:UpdateAll()
            end
        end
        AddOverrideIndicators(container, lbl, dbKey, onReset, 6, nil, dbTable)
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
    local c = accentColor or GetThemeColor()
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
    
    -- Track whether this slider is actively being dragged
    local isDragging = false
    
    -- Store preview mode flag for this slider
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
    
    local function UpdateFill()
        local val = slider:GetValue()
        local pct = (val - minVal) / (maxVal - minVal)
        -- Measured off the LIVE track, not the old hardcoded 178 (= the fixed 180
        -- track minus the fill's 1px inset each side). The track stretches now, so
        -- a constant here would under-fill on any panel wider than the default.
        local usable = (track:GetWidth() or 0) - 2
        if usable < 1 then usable = 1 end
        fill:SetWidth(math.max(1, pct * usable))
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
        local tc = accentColor or GetThemeColor()
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
    
    container.UpdateTheme = function()
        local nc = accentColor or GetThemeColor()
        if slider:IsEnabled() then
            thumb:SetColorTexture(nc.r, nc.g, nc.b, 1)
            fill:SetColorTexture(nc.r, nc.g, nc.b, 0.8)
        end
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

    -- Track drag start - pass the lightweight update function, name for debug, and preview mode
    slider:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            isDragging = true
            local funcName = lightweightUpdate and ((dbKey or label or "slider") .. " lightweight") or nil
            DF:OnSliderDragStart(lightweightUpdate, funcName, sliderUsePreviewMode)
        end
    end)
    
    -- Track drag end - do full update when slider is released
    slider:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and isDragging then
            isDragging = false
            DF:OnSliderDragStop()
            -- Update override indicators after drag ends
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(slider:GetValue())
            end
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
        if dbKey and GUI.SelectedMode == "raid" and DF.AutoProfilesUI
           and DF.AutoProfilesUI:HandleRuntimeWrite(dbKey, value) then
            if not input:HasFocus() then input:SetText(FormatValue(value)) end
            UpdateFill()
            if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators(value) end
            return
        end

        WriteValue(value)

        -- If editing a profile, also set the override
        if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and dbKey then
            DF.AutoProfilesUI:SetProfileSetting(dbKey, value)
        end
        
        if not input:HasFocus() then
            input:SetText(FormatValue(value))
        end
        UpdateFill()
        -- Use targeted update system - lightweight during drag, full on release
        DF:ThrottledUpdateAll()
        -- Skip callback during drag - it will run via UpdateAll on release
        if callback and not DF.sliderDragging then
            callback()
        end
    end)
    
    input:SetScript("OnEnterPressed", function(self)
        local val = tonumber(self:GetText())
        if val then
            val = math.max(minVal, math.min(maxVal, val))

            -- Runtime override protection: redirect to baseline, skip refresh
            if dbKey and GUI.SelectedMode == "raid" and DF.AutoProfilesUI
               and DF.AutoProfilesUI:HandleRuntimeWrite(dbKey, val) then
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
            if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and dbKey then
                DF.AutoProfilesUI:SetProfileSetting(dbKey, val)
            end

            -- Update override indicators
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(val)
            end

            -- FIX 2025-01-20: Call callback OR lightweightUpdate (some sliders have nil callback)
            if callback then
                callback()
            elseif lightweightUpdate then
                lightweightUpdate()
            end

            -- Guaranteed full update (SetValue may not fire OnValueChanged if value didn't change)
            DF:UpdateAll()
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
    if DF.Search and dbKey and type(dbKey) == "string" then
        container.searchEntry = DF.Search:RegisterSlider(label, dbKey, minVal, maxVal, step, nil, callback)
    end
    
    -- Expose label for dynamic updates
    container.label = lbl

    -- Tooltip: shared attach on the LABEL only (see GUI:AttachTooltip). Keeping it
    -- off the bar matters most here — a tooltip over a slider you are dragging is
    -- the worst case of the problem. Both .tooltip (title from the label) and the
    -- legacy .tooltipText/.tooltipSubText pair are honoured.
    GUI:AttachTooltip(container, label, lbl)

    return container
end

-- Stamp the shared Frame Level explanation onto a slider. One helper rather than the same
-- two strings at 21 call sites, and it keeps the wording in ONE place -- the old per-page
-- label went stale the moment the scale changed (it still read "0=Auto" afterwards).
-- Takes the CONTAINER that CreateSlider returns, which is what every call site has.
function GUI:SetFrameLevelTooltip(container)
    if not container then return end
    container.tooltipText    = L["Frame Level"]
    container.tooltipSubText = L["Higher numbers draw on top of lower ones. Every Frame Level in DandersFrames uses the same scale, counted up from the unit frame, so you can compare them directly."]
    return container   -- chainable, so it wraps a CreateSlider call in place
end

-- Dual-handle range slider: two draggable handles select a [lo, hi] sub-range of
-- [minRange, maxRange]. Self-contained — the caller anchors the returned track
-- frame and reads values via the onChange callback. (:GetValues() also exists and
-- completes the SetValues pair, but no current consumer polls it.) Drag is
-- tracked on the track's own OnUpdate (no dependence on parent scripts), and a
-- mouse-button check releases the drag even if the cursor leaves the handle.
-- opts:
--   width(336), accent({r,g,b}=theme), minRange, maxRange, lo, hi,
--   scaleLabels({...} optional tick labels), scaleMin/scaleMax (label scale,
--   default minRange/maxRange — lets ticks stay on a fixed scale while the
--   handle range changes), display(FontString updated each change),
--   formatRange(fn(lo,hi)->str), formatOne(fn(v)->str),
--   onChange(fn(lo,hi) — fired on user-driven changes only, not SetValues).
-- Methods on the returned frame: :SetRange(min,max), :SetValues(lo,hi),
-- :GetValues()->lo,hi.
function GUI:CreateRangeSlider(parent, opts)
    opts = opts or {}
    local width = opts.width or 336
    local accent = opts.accent or GetThemeColor()

    local track = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    track:SetSize(width, 12)
    CreateElementBackdrop(track, {
        bgColor     = { 0.03, 0.03, 0.03, 1 },
        borderColor = { 0.2, 0.2, 0.2, 1 },
    })

    track.minRange = opts.minRange or 1
    track.maxRange = opts.maxRange or 40
    track.lo = opts.lo or track.minRange
    track.hi = opts.hi or track.maxRange

    local rangeFill = track:CreateTexture(nil, "ARTWORK")
    rangeFill:SetTexture("Interface\\Buttons\\WHITE8x8")
    rangeFill:SetVertexColor(accent.r, accent.g, accent.b, 0.5)
    rangeFill:SetHeight(10)
    rangeFill:SetPoint("TOP", 0, -1)

    local function MakeHandle()
        local h = CreateFrame("Button", nil, track)
        h:SetSize(8, 16)
        h:EnableMouse(true)
        local tex = h:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints()
        tex:SetTexture("Interface\\Buttons\\WHITE8x8")
        tex:SetVertexColor(accent.r, accent.g, accent.b, 1)
        return h
    end
    local minHandle, maxHandle = MakeHandle(), MakeHandle()
    track.minHandle, track.maxHandle = minHandle, maxHandle

    local function ValueToPos(value)
        local pct = (value - track.minRange) / (track.maxRange - track.minRange)
        return pct * (width - 4) + 2
    end
    local function PosToValue(pos)
        local pct = (pos - 2) / (width - 4)
        return math.floor(pct * (track.maxRange - track.minRange) + track.minRange + 0.5)
    end

    local function Redraw()
        local minPos, maxPos = ValueToPos(track.lo), ValueToPos(track.hi)
        minHandle:ClearAllPoints()
        minHandle:SetPoint("CENTER", track, "LEFT", minPos, 0)
        maxHandle:ClearAllPoints()
        maxHandle:SetPoint("CENTER", track, "LEFT", maxPos, 0)
        rangeFill:ClearAllPoints()
        rangeFill:SetPoint("LEFT", track, "LEFT", minPos, 0)
        rangeFill:SetWidth(math.max(maxPos - minPos, 2))
        if opts.display then
            if track.lo == track.hi then
                opts.display:SetText(opts.formatOne and opts.formatOne(track.lo) or tostring(track.lo))
            else
                opts.display:SetText(opts.formatRange and opts.formatRange(track.lo, track.hi)
                    or (track.lo .. " - " .. track.hi))
            end
        end
    end

    local dragging = nil
    local function ApplyCursor()
        local x = select(1, GetCursorPosition()) / UIParent:GetEffectiveScale()
        local trackLeft = track:GetLeft()
        if not trackLeft then return end
        local pos = math.max(2, math.min(x - trackLeft, width - 2))
        local value = math.max(track.minRange, math.min(PosToValue(pos), track.maxRange))
        if dragging == "min" then
            if value <= track.hi then track.lo = value end
        elseif dragging == "max" then
            if value >= track.lo then track.hi = value end
        end
        Redraw()
        if opts.onChange then opts.onChange(track.lo, track.hi) end
    end

    minHandle:SetScript("OnMouseDown", function(_, b) if b == "LeftButton" then dragging = "min" end end)
    maxHandle:SetScript("OnMouseDown", function(_, b) if b == "LeftButton" then dragging = "max" end end)
    track:SetScript("OnUpdate", function()
        if not dragging then return end
        if not IsMouseButtonDown("LeftButton") then dragging = nil; return end
        ApplyCursor()
    end)

    track:EnableMouse(true)
    track:SetScript("OnMouseDown", function(_, b)
        if b ~= "LeftButton" then return end
        local x = select(1, GetCursorPosition()) / UIParent:GetEffectiveScale()
        local trackLeft = track:GetLeft()
        if not trackLeft then return end
        local value = PosToValue(x - trackLeft)
        if math.abs(value - track.lo) <= math.abs(value - track.hi) then
            if value <= track.hi then track.lo = math.max(track.minRange, value) end
        else
            if value >= track.lo then track.hi = math.min(track.maxRange, value) end
        end
        Redraw()
        if opts.onChange then opts.onChange(track.lo, track.hi) end
    end)

    if opts.scaleLabels then
        local sMin = opts.scaleMin or track.minRange
        local sMax = opts.scaleMax or track.maxRange
        for _, num in ipairs(opts.scaleLabels) do
            local pct = (num - sMin) / (sMax - sMin)
            local xPos = pct * (width - 4) + 2
            local lbl = track:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            lbl:SetText(num)
            lbl:SetTextColor(0.35, 0.35, 0.35)
            lbl:SetPoint("TOP", track, "BOTTOM", xPos - width / 2, -2)
        end
    end

    function track:SetRange(minR, maxR)
        self.minRange, self.maxRange = minR, maxR
        self.lo = math.max(minR, math.min(self.lo, maxR))
        self.hi = math.max(minR, math.min(self.hi, maxR))
        Redraw()
    end
    function track:SetValues(lo, hi)
        self.lo = math.max(self.minRange, math.min(lo, self.maxRange))
        self.hi = math.max(self.minRange, math.min(hi, self.maxRange))
        Redraw()
    end
    function track:GetValues() return self.lo, self.hi end

    Redraw()
    return track
end

function GUI:CreateColorPicker(parent, label, dbTable, dbKey, hasAlpha, callback, lightweightCallback, useLightweight)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 28)
    container.preferredHeight = GUI.RowHeight.colorpicker   -- factory-owned slot height (see GUI.RowHeight)
    container.rowKind = "colorpicker"
    container.fixedRowHeight = true
    
    -- Button - use relative anchoring so it resizes with container
    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    btn:SetPoint("TOPLEFT", 0, 0)
    btn:SetPoint("TOPRIGHT", 0, 0)
    btn:SetHeight(SnapLen(btn, 24) or 24)
    CreateElementBackdrop(btn)

    -- Label
    local txt = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    txt:SetPoint("LEFT", 8, 0)
    txt:SetText(label)
    txt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Color swatch
    local swatch = btn:CreateTexture(nil, "OVERLAY")
    swatch:SetSize(40, 16)
    swatch:SetPoint("RIGHT", -6, 0)
    
    -- Add override indicators if dbKey is provided (for auto profiles)
    if dbKey and type(dbKey) == "string" then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(dbKey)
                -- Refresh to global value
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(dbKey)
                if globalVal then
                    dbTable[dbKey].r = globalVal.r
                    dbTable[dbKey].g = globalVal.g
                    dbTable[dbKey].b = globalVal.b
                    dbTable[dbKey].a = globalVal.a or 1
                end
                if container.UpdateSwatch then
                    container:UpdateSwatch()
                end
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(dbTable[dbKey])
                end
                DF:UpdateAll()
            end
        end
        AddOverrideIndicators(container, txt, dbKey, onReset, nil, nil, dbTable)
    end
    
    local function UpdateSwatch()
        if dbTable and dbKey and dbTable[dbKey] then
            local c = dbTable[dbKey]
            swatch:SetColorTexture(c.r, c.g, c.b, c.a or 1)
            -- Update override indicators
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(c)
            end
        end
    end
    container.UpdateSwatch = UpdateSwatch  -- Expose for reset
    
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    end)

    -- Tooltip: shared attach on the LABEL only. This factory carried none, across
    -- 87 colour pickers. The btn keeps its own hover scripts untouched — the hit
    -- frame is over the text, not the swatch.
    GUI:AttachTooltip(container, label, txt)

    btn:SetScript("OnClick", function()
        if not dbTable then return end
        local c = dbTable[dbKey]
        if not c then 
            c = {r = 1, g = 1, b = 1, a = 1}
            dbTable[dbKey] = c
        end
        
        -- Store original values for cancel
        local originalColor = {r = c.r, g = c.g, b = c.b, a = c.a or 1}

        -- Blizzard's SetupColorPickerAndShow fires swatchFunc once DURING
        -- setup (its SetColorRGB triggers OnColorSelect — the source comments
        -- it). That spurious fire re-writes the unchanged colour and runs the
        -- change callbacks on mere open: it commits per-element override flags
        -- (Text Designer) and triggers a pointless full refresh. Suppress
        -- callbacks until setup has returned.
        local settingUp = true
        
        local info = {
            swatchFunc = function()
                if settingUp then return end
                local r, g, b = ColorPickerFrame:GetColorRGB()
                local a = 1
                if hasAlpha and ColorPickerFrame.GetColorAlpha then
                    a = ColorPickerFrame:GetColorAlpha() or 1
                end
                dbTable[dbKey].r = r
                dbTable[dbKey].g = g
                dbTable[dbKey].b = b
                dbTable[dbKey].a = a
                
                -- If editing a profile, also set the override
                if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and dbKey then
                    DF.AutoProfilesUI:SetProfileSetting(dbKey, {r = r, g = g, b = b, a = a})
                end
                
                UpdateSwatch()
                -- Use lightweight callback during dragging if available
                if useLightweight and lightweightCallback then
                    lightweightCallback()
                else
                    DF:ThrottledUpdateAll()
                    if callback then callback() end
                end
            end,
            hasOpacity = hasAlpha,
            opacityFunc = hasAlpha and function()
                if settingUp then return end
                if ColorPickerFrame.GetColorAlpha then
                    local a = ColorPickerFrame:GetColorAlpha()
                    if a then
                        dbTable[dbKey].a = a
                        UpdateSwatch()
                        -- Use lightweight callback during dragging if available
                        if useLightweight and lightweightCallback then
                            lightweightCallback()
                        else
                            DF:ThrottledUpdateAll()
                            if callback then callback() end
                        end
                    end
                end
            end or nil,
            cancelFunc = function(restore)
                -- Restore original color on cancel
                dbTable[dbKey].r = originalColor.r
                dbTable[dbKey].g = originalColor.g
                dbTable[dbKey].b = originalColor.b
                dbTable[dbKey].a = originalColor.a
                UpdateSwatch()
                DF:UpdateAll()
                if callback then callback() end
            end,
            r = c.r or 1, 
            g = c.g or 1, 
            b = c.b or 1, 
            opacity = hasAlpha and (c.a or 1) or nil,
        }
        
        -- Hook the OK button to run full update when confirmed
        if useLightweight and lightweightCallback then
            -- We need to run full update when picker is closed via OK
            -- Use a frame to detect when color picker closes
            if not container.colorPickerWatcher then
                container.colorPickerWatcher = CreateFrame("Frame")
            end
            container.colorPickerWatcher:SetScript("OnUpdate", function(self)
                if not ColorPickerFrame:IsShown() then
                    self:SetScript("OnUpdate", nil)
                    -- Only run if color changed (not cancelled)
                    local cur = dbTable[dbKey]
                    if cur.r ~= originalColor.r or cur.g ~= originalColor.g or 
                       cur.b ~= originalColor.b or cur.a ~= originalColor.a then
                        DF:UpdateAll()
                        if callback then callback() end
                    end
                end
            end)
        end
        
        -- Attach default colour so the picker can offer a Default button
        -- dbTable.__dfDefaults is set by callers (e.g. Aura Designer proxies) that
        -- store their defaults outside DF.PartyDefaults / DF.RaidDefaults. Read via
        -- rawget so proxies' __index doesn't see this lookup as a regular setting.
        local defaultVal = (dbTable and rawget(dbTable, "__dfDefaults") and dbTable.__dfDefaults[dbKey])
                        or (DF.PartyDefaults and DF.PartyDefaults[dbKey])
                        or (DF.RaidDefaults  and DF.RaidDefaults[dbKey])
        -- Fallback: power bar colours use WoW's PowerBarColor table as their default
        if not defaultVal and PowerBarColor and dbKey then
            defaultVal = PowerBarColor[dbKey]
        end
        if defaultVal and type(defaultVal) == "table" and defaultVal.r then
            info.dfDefaultColor = {r = defaultVal.r or 1, g = defaultVal.g or 1, b = defaultVal.b or 1, a = defaultVal.a or 1}
            -- Populate ElvUI's "Default" button (ColorPPDefault) so it enables and
            -- pastes the DF setting default when the native Blizzard picker is shown
            local elvDefault = _G["ColorPPDefault"]
            if elvDefault then
                elvDefault.colors = info.dfDefaultColor
            end
        end

        -- Mark this as a DandersFrames color picker call
        GUI:MarkColorPickerCall()
        ColorPickerFrame:SetupColorPickerAndShow(info)
        settingUp = false
    end)
    
    container.SetEnabled = function(self, enabled)
        -- Dim the whole widget so the colour swatch greys even when it's a dark
        -- colour (SetDesaturated alone is invisible on near-black swatches).
        self:SetAlpha(enabled and 1 or 0.4)
        btn:SetEnabled(enabled)
        if enabled then
            txt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            swatch:SetDesaturated(false)
        else
            txt:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            swatch:SetDesaturated(true)
        end
    end
    
    btn:SetScript("OnShow", UpdateSwatch)
    UpdateSwatch()
    
    -- SEARCH: Register this setting
    if DF.Search and dbKey and type(dbKey) == "string" then
        container.searchEntry = DF.Search:RegisterColorPicker(label, dbKey, hasAlpha, nil, callback)
    end
    
    return container
end

-- ============================================================
-- OPEN-MENU REGISTRY
-- Dropdown/preset menus anchor to their button and survive context switches
-- that leave the button visible (e.g. the Aura Designer changing tabs).
-- Every menu frame registers here at creation; CloseAllMenus() lets a
-- context switch dismiss whatever is open.
-- ============================================================
GUI._menus = GUI._menus or {}
function GUI:RegisterMenu(frame) self._menus[frame] = true end
function GUI:CloseAllMenus()
    for f in pairs(self._menus) do
        if f:IsShown() then f:Hide() end
    end
end

function GUI:CreateDropdown(parent, label, options, dbTable, dbKey, callback, customGet, customSet, opts)
    opts = opts or {}
    local accentColor = opts.accent
    local optionsFunc = opts.optionsFunc

    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, opts.inline and 24 or 50)
    -- Inline dropdowns embed in a caller-managed layout (label hidden), so only the standalone
    -- form owns a fixed slot height; inline keeps whatever height its host passes.
    if not opts.inline then
        container.preferredHeight = GUI.RowHeight.dropdown   -- factory-owned slot (see GUI.RowHeight)
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
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(dbKey)
                -- Refresh to global value
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(dbKey)
                dbTable[dbKey] = globalVal
                if container.UpdateText then
                    container:UpdateText()
                end
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(globalVal)
                end
                DF:UpdateAll()
            end
        end
        AddOverrideIndicators(container, lbl, dbKey, onReset, 6, options, dbTable)
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
    arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
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
            local val = customGet and customGet() or dbTable[dbKey]
            local displayVal = options[val]
            -- Handle table format: {value = X, text = "text"} or {text = "text"}
            local optColor
            if type(displayVal) == "table" then
                optColor = displayVal.color
                displayVal = displayVal.text or displayVal.label or tostring(val)
            end
            btn.Text:SetText(displayVal or tostring(val) or L["Select..."])
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
    menuFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    GUI:RegisterMenu(menuFrame)
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
    local MAX_VISIBLE = opts.maxVisible or 12
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
        searchIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\search")
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
        local selColor = accentColor or GetThemeColor()
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
                    if GUI.SelectedMode == "raid" and DF.AutoProfilesUI
                       and DF.AutoProfilesUI:HandleRuntimeWrite(dbKey, optKey) then
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
                    if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and dbKey then
                        DF.AutoProfilesUI:SetProfileSetting(dbKey, customGet and customGet() or optKey)
                    end

                    UpdateText()
                    menuFrame:Hide()
                    DF:UpdateAll()
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
            CloseOpenDropdown()
            -- Dynamic dropdowns regenerate their option list each open.
            if optionsFunc then
                container:RebuildOptions(optionsFunc())
            elseif searchable then
                -- Searchable menus reopen unfiltered (search cleared on hide)
                BuildMenuButtons()
            else
                -- Static menus: refresh selected-value colouring on the pooled rows
                local currentVal = customGet and customGet() or (dbTable and dbKey and dbTable[dbKey])
                local selColor = accentColor or GetThemeColor()
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
    
    -- Tooltip: shared attach on the LABEL only (see GUI:AttachTooltip). The label
    -- sits at the container's TOPLEFT, above the opener, so it is well clear of
    -- the menu you are about to click.
    GUI:AttachTooltip(container, label, lbl)

    -- SEARCH: Register this setting
    if DF.Search and dbKey and type(dbKey) == "string" then
        container.searchEntry = DF.Search:RegisterDropdown(label, dbKey, options, nil, callback)
    end

    return container
end

-- ============================================================
-- OUTLINE + SHADOW CONTROLS
-- A flag dropdown and a shadow checkbox that both bind to a single stored
-- outline value (see DF:OutlineFlag / OutlineHasShadow / ComposeOutline in
-- Config.lua). Shadow is decoupled from the outline flag so any flag can be
-- combined with a drop shadow, mirroring Grid2's font options.
-- ============================================================

local OUTLINE_FLAG_ORDER = { "NONE", "OUTLINE", "THICKOUTLINE", "MONOCHROME", "MONOCHROME, OUTLINE", "MONOCHROME, THICKOUTLINE" }

function GUI:CreateOutlineDropdown(parent, label, dbTable, dbKey, callback, inheritKey)
    local options = {
        NONE = L["None"],
        OUTLINE = L["Outline"],
        THICKOUTLINE = L["Thick Outline"],
        MONOCHROME = L["Monochrome"],
        ["MONOCHROME, OUTLINE"] = L["Monochrome Outline"],
        ["MONOCHROME, THICKOUTLINE"] = L["Monochrome Thick Outline"],
        _order = OUTLINE_FLAG_ORDER,
    }
    local get = function() return DF:OutlineFlag(dbTable[dbKey] or (inheritKey and dbTable[inheritKey])) end
    local set = function(flag) dbTable[dbKey] = DF:ComposeOutline(flag, DF:OutlineHasShadow(dbTable[dbKey] or (inheritKey and dbTable[inheritKey]))) end
    return GUI:CreateDropdown(parent, label or L["Outline"], options, dbTable, dbKey, callback, get, set)
end

function GUI:CreateShadowCheckbox(parent, label, dbTable, dbKey, callback)
    local get = function() return DF:OutlineHasShadow(dbTable[dbKey]) end
    local set = function(val) dbTable[dbKey] = DF:ComposeOutline(DF:OutlineFlag(dbTable[dbKey]), val) end
    return GUI:CreateCheckbox(parent, label or L["Shadow"], dbTable, dbKey, callback, get, set)
end

-- ============================================================
-- UNIFIED BORDER CONTROL SET
-- Drops the canonical Show / Style / Texture / Size / Colour controls plus
-- whichever optional Phase B controls the consumer opts into (offset, inset,
-- blendMode, gradient, shadow). Saved-variable keys are built from a single
-- camelCase `prefix` (e.g. "defensiveIcon" → "defensiveIconBorderSize"), so
-- consumers add one call instead of hand-rolling ~6-15 widgets each.
--
-- Each opts.include flag is per-element: "tailor-made to what makes logical
-- sense" — the API exposes everything, but consumers opt in only to what fits
-- their element. Returns a table of widget references so the caller can add
-- per-element extras (dispel-type colour, pulsate, etc.) afterwards.
--
-- opts = {
--   parent       = the panel widget (e.g. self.child) — same first arg the
--                  underlying CreateCheckbox/Slider/etc. take
--   include      = { offset=, inset=, blendMode=, gradient=, shadow=,
--                    classColor=, roleColor=, colorByTime=, colorByType= }
--   fullUpdate   = callback for full re-render (drop / value-set)
--   lightUpdate  = callback for slider-drag (size, offsets, shadow sliders)
--   lightColors  = callback for live colour-picker preview
--   refreshStates = optional hook fired when Show/Gradient/Shadow toggles
--                   change visibility of other widgets
--   disableWhen  = optional predicate fn(db) → bool. When true, EVERY widget
--                  (including the Show toggle itself) GREYS OUT in place. This
--                  is what a consumer whose border sits under a feature toggle
--                  wants — the addon-wide rule is that a deactivated control
--                  greys where it is, so the page doesn't reflow and you can
--                  still see what turning the feature on would give you.
--   hideWhen     = optional predicate fn(db) → bool. When true, EVERY widget
--                  (including the Show toggle itself) HIDES. Reserve this for a
--                  gate that changes WHAT the page offers — a variant switch
--                  like Pinned Frames' per-set border override, where the
--                  controls belong to a mode you are not in. A plain on/off
--                  feature toggle is disableWhen, not this.
--   sizeMin / sizeMax / sizeStep      = slider range overrides
--   offsetMin / offsetMax / offsetStep
-- }
-- ============================================================
-- CreateAnimationControls — the Border Animation control set
-- (Type dropdown + every per-effect tunable), extracted so the base
-- Border Animation panel (CreateBorderControls / include.animate) AND
-- Aura Designer's Expiring Animation override render an IDENTICAL set of
-- widgets from ONE source. Add or remove an effect / tunable here and both
-- panels update together — no drift.
--
--   group       = SettingsGroup the widgets are added to
--   dbTable     = db / proxy the widgets read & write
--   animPrefix  = key namespace; widgets target dbTable[animPrefix .. suffix]
--                 (base border: "<prefix>BorderAnimation"; AD expiring:
--                 "ExpiringAnimation")
-- opts:
--   parent        = frame parent for the widgets
--   fullUpdate    = heavy refresh callback (dropdown / slider-release / colour)
--   lightUpdate   = light refresh callback (slider-drag)
--   lightColors   = live colour-picker preview callback (needed for AD's
--                   proxy, whose sub-table colour writes skip __newindex)
--   typeLabel     = label for the Type dropdown
--   hideExtra     = optional predicate; when true the WHOLE block hides
--                   (the border panel folds the block under Show Border;
--                   the always-visible Expiring override omits it)
--   onTypeChange  = runs after the Type dropdown changes (re-layout / reflow)
--   perfBanner    = show the per-border FPS warning banner (default true)
-- Returns the widget table (animationType, animationColor, … ) so the caller
-- can merge the handles into its own control table.
-- ============================================================
function GUI:CreateAnimationControls(group, dbTable, animPrefix, opts)
    opts = opts or {}
    local parent       = opts.parent
    local fullUpdate   = opts.fullUpdate or function() end
    local lightUpdate  = opts.lightUpdate
    local lightColors  = opts.lightColors
    local typeLabel    = opts.typeLabel or L["Border Animation"]
    local excludeTypes = opts.excludeTypes   -- optional set of animation-type keys to omit from the dropdown
    local hideExtra    = opts.hideExtra
    local onTypeChange = opts.onTypeChange or function() end
    local showPerfBanner = opts.perfBanner ~= false

    local function aKey(suffix) return animPrefix .. suffix end
    local animTypeKey = aKey("Type")
    local function animType() return dbTable[animTypeKey] or "NONE" end
    local function extraOff() return (hideExtra and hideExtra()) or false end
    local function animOff()  return extraOff() or animType() == "NONE" end

    -- Sets of effect types each tunable applies to (truthiness on a
    -- string-keyed set). Mirrors the per-effect parameter map — keep in
    -- sync with StartAnimation's branches in Frames/Border.lua.
    -- DF_DASH: Frequency = march SPEED (0 = static dashed), Thickness = dash
    -- thickness, Inset = dash inset.
    local hasFrequency = { DF_PULSATE=1,
                           DF_DASH=1, BLINK=1, DF_ORBIT=1, DF_PROC=1, DF_FLASH=1, DF_PIXEL=1 }
    local hasParticles = { DF_ORBIT=1, DF_PIXEL=1 }
    -- CORNERS_ONLY is hidden from the type dropdown below, but keep its param
    -- entries so an indicator that still carries a saved CORNERS_ONLY value shows
    -- the right controls.
    local hasThickness = { CORNERS_ONLY=1, DF_DASH=1, BLINK=1, DF_PIXEL=1 }
    -- Inset / Offset apply to every non-NONE effect EXCEPT DF_PULSATE (which
    -- modulates the border's own edges and has no separate animRect).
    local hasPositioning = { CORNERS_ONLY=1, DF_DASH=1, BLINK=1, DF_ORBIT=1, DF_PROC=1, DF_FLASH=1, DF_PIXEL=1 }
    -- Scale slider = sparkle size (DF Chase).
    local hasScale     = { DF_ORBIT=1 }
    -- Length slider = bar length (DF Pixel's chasing bars).
    local hasLength    = { DF_PIXEL=1 }
    local cornersOnly  = { CORNERS_ONLY=1 }
    local function hideUnless(set)
        return function()
            if animOff() then return true end
            return not set[animType()]
        end
    end

    local w = {}

    -- All DF-owned border effects (no external glow library). The "DF " labels
    -- are kept from when they sat alongside the retired LCG glows.
    local animTypeOptions = {
        NONE = L["None"],
        DF_PULSATE = L["DF Pulsate"],
        DF_ORBIT = L["DF Chase"],
        DF_DASH = L["DF Dash"],
        DF_FLASH = L["DF Flash"],
        DF_PIXEL = L["DF Pixel"],
        DF_PROC = L["DF Proc"],
        BLINK = L["Blink"],
        -- None first (the "off" option), then alphabetical by label. CORNERS_ONLY
        -- is intentionally absent — it's kept in the engine (an existing saved
        -- value still renders) but no longer offered as a pickable animation.
        _order = { "NONE", "BLINK", "DF_ORBIT",
                   "DF_DASH", "DF_FLASH", "DF_PIXEL", "DF_PROC", "DF_PULSATE" },
    }
    -- Optional caller filter: drop any excluded type from both the value map and
    -- the display order (e.g. the Aura Designer border offers only the taint-safe,
    -- overlay-recoverable animations — no LCG glows).
    if excludeTypes then
        for k in pairs(excludeTypes) do animTypeOptions[k] = nil end
        local filteredOrder = {}
        for _, k in ipairs(animTypeOptions._order) do
            if not excludeTypes[k] then filteredOrder[#filteredOrder + 1] = k end
        end
        animTypeOptions._order = filteredOrder
    end
    w.animationType = group:AddWidget(GUI:CreateDropdown(parent, typeLabel,
        animTypeOptions,
        dbTable, animTypeKey, onTypeChange), 55)
    -- Type dropdown respects only the extra gate (e.g. Show Border). With no
    -- extra gate (Expiring override) it's always visible.
    w.animationType.hideOn = hideExtra or function() return false end

    -- Perf warning: animations run an OnUpdate (or LCG internal animation)
    -- per active border, which adds up in 20-30 player raids.
    if showPerfBanner then
        -- staticHeight ONLY where the host reflows widget WIDTHS on every layout
        -- pass — i.e. the Aura Designer indicator card (its parent carries
        -- dfAD_ReflowWidgets). There a self-sizing banner feeds a SetHeight ->
        -- OnSizeChanged -> relayout -> SetWidth loop that drops FPS, so we predict
        -- a fixed height instead. On normal settings pages the host lays out once,
        -- so the banner MUST self-size to its wrapped text: a fixed height
        -- overflows (text spills past the box) on narrow windows until a manual
        -- drag forces a relayout.
        local reflowingHost = parent and parent.dfAD_ReflowWidgets ~= nil
        local perfBanner = GUI:CreateInfoBanner(parent, {
            tone = "caution",
            text = L["Animations run per-border and may impact FPS in larger raids. Use sparingly on high-priority alerts."],
            staticHeight = reflowingHost or nil,
            minHeight    = 56,
        })
        w.animationPerfBanner = group:AddWidget(perfBanner, perfBanner.layoutHeight)
        w.animationPerfBanner.hideOn = animOff
    end

    -- Animation colour applies to every effect except DF_PULSATE (which
    -- modulates the border's own edge alpha — no separate colour). lightColors
    -- is threaded through so AD's proxy gets live preview while dragging.
    w.animationColor = group:AddWidget(GUI:CreateColorPicker(parent, L["Animation Color"],
        dbTable, aKey("Color"), true, fullUpdate, lightColors, lightColors ~= nil), 35)
    w.animationColor.hideOn = function()
        return animOff() or animType() == "DF_PULSATE"
    end

    -- Min 0: DF_DASH reads Frequency as march speed, so 0 = static dashed.
    -- The LCG glows treat 0 as their default rate (clamped in StartAnimation),
    -- and the OnUpdate effects fall back to a sensible default period at 0.
    w.animationFrequency = group:AddWidget(GUI:CreateSlider(parent, L["Animation Frequency"],
        0, 4, 0.05, dbTable, aKey("Frequency"),
        fullUpdate, lightUpdate, true), 55)
    w.animationFrequency.hideOn = hideUnless(hasFrequency)
    -- ⚠ This slider genuinely means different things per effect (see the comment
    -- above), which is exactly why it needs saying out loud — nobody discovers
    -- "0 = hold still" by dragging.
    w.animationFrequency.tooltip = L["How fast the effect runs. On DF Dash this is how quickly the dashes march around the edge, and 0 holds them still. On the others it is the pulse rate, where 0 means the effect's own default speed."]

    w.animationParticles = group:AddWidget(GUI:CreateSlider(parent, L["Animation Particles"],
        1, 16, 1, dbTable, aKey("Particles"),
        fullUpdate, lightUpdate, true), 55)
    w.animationParticles.hideOn = hideUnless(hasParticles)
    w.animationParticles.tooltip = L["How many separate lights travel around the border. More reads as busier and costs a little more to draw."]

    w.animationLength = group:AddWidget(GUI:CreateSlider(parent, L["Animation Length"],
        1, 30, 1, dbTable, aKey("Length"),
        fullUpdate, lightUpdate, true), 55)
    w.animationLength.hideOn = hideUnless(hasLength)
    w.animationLength.tooltip = L["How long each moving segment is. Short values read as darting sparks, long ones as a sweeping tail."]

    w.animationThickness = group:AddWidget(GUI:CreateSlider(parent, L["Animation Thickness"],
        1, 12, 1, dbTable, aKey("Thickness"),
        fullUpdate, lightUpdate, true), 55)
    w.animationThickness.hideOn = hideUnless(hasThickness)
    w.animationThickness.tooltip = L["How heavy the moving effect is. Separate from Border Thickness — the animation draws on its own layer, so it can be thicker or thinner than the border underneath."]

    w.animationScale = group:AddWidget(GUI:CreateSlider(parent, L["Animation Scale"],
        0.5, 3, 0.05, dbTable, aKey("Scale"),
        fullUpdate, lightUpdate, true), 55)
    w.animationScale.hideOn = hideUnless(hasScale)

    w.animationInset = group:AddWidget(GUI:CreateSlider(parent, L["Animation Inset"],
        -50, 50, 1, dbTable, aKey("Inset"),
        fullUpdate, lightUpdate, true), 55)
    w.animationInset.hideOn = hideUnless(hasPositioning)
    w.animationInset.tooltip = L["Moves the effect in or out from the edge, independently of the border. Push it outward to make a glow spill past the frame."]

    w.animationOffsetX = group:AddWidget(GUI:CreateSlider(parent, L["Animation Offset X"],
        -50, 50, 1, dbTable, aKey("OffsetX"),
        fullUpdate, lightUpdate, true), 55)
    w.animationOffsetX.hideOn = hideUnless(hasPositioning)

    w.animationOffsetY = group:AddWidget(GUI:CreateSlider(parent, L["Animation Offset Y"],
        -50, 50, 1, dbTable, aKey("OffsetY"),
        fullUpdate, lightUpdate, true), 55)
    w.animationOffsetY.hideOn = hideUnless(hasPositioning)

    -- DF Flash / DF Proc: skip the one-shot intro burst (glow-only).
    w.animationHideIntro = group:AddWidget(GUI:CreateCheckbox(parent, L["Hide Intro Flash"],
        dbTable, aKey("ProcStart"), fullUpdate), 30)
    w.animationHideIntro.hideOn = hideUnless({ DF_FLASH = 1, DF_PROC = 1 })
    w.animationHideIntro.tooltip = L["These effects open with a one-off burst before settling into their loop. Turn this on to skip the burst and go straight to the loop."]

    w.animationCornerLength = group:AddWidget(GUI:CreateSlider(parent, L["Corner Length"],
        2, 40, 1, dbTable, aKey("CornerLength"),
        fullUpdate, lightUpdate, true), 55)
    w.animationCornerLength.hideOn = hideUnless(cornersOnly)
    w.animationCornerLength.tooltip = L["How far the effect runs along each edge from the corner before stopping. Small values leave four short brackets instead of a full outline."]

    return w
end

-- ============================================================
function GUI:CreateBorderControls(group, dbTable, prefix, opts)
    opts = opts or {}
    local parent       = opts.parent
    local include      = opts.include or {}
    local fullUpdate   = opts.fullUpdate or function() end
    local lightUpdate  = opts.lightUpdate
    local lightColors  = opts.lightColors
    local refreshStates = opts.refreshStates
    local hideWhen     = opts.hideWhen
    local disableWhen  = opts.disableWhen

    local sizeMin, sizeMax, sizeStep = opts.sizeMin or 0, opts.sizeMax or 8, opts.sizeStep or 1
    local offMin, offMax, offStep    = opts.offsetMin or -50, opts.offsetMax or 50, opts.offsetStep or 1

    local function key(suffix) return prefix .. suffix end
    local showKey = key("ShowBorder")
    -- The Show toggle only respects the parent-level hideWhen. Everything
    -- else respects hideWhen OR the Show toggle being off.
    --
    -- hideOn predicates IGNORE the table arg LayoutChildren passes (which is
    -- always `DF.db[GUI.SelectedMode]`) and read from the captured `dbTable`
    -- instead.  For consumers whose dbTable == DF.db[mode] (Frame Border,
    -- Defensive Icon, etc.) the two are identical so behaviour is unchanged.
    -- For consumers with a different dbTable — notably Aura Designer's
    -- per-aura proxy — this is the only way the visibility predicates see
    -- the actual border state (e.g. proxy.BorderStyle, not the unrelated
    -- DF.db.party.BorderStyle which doesn't exist).
    local function hideShow() return hideWhen and hideWhen(dbTable) or false end
    -- Show Border OFF no longer HIDES the border controls — they stay visible and
    -- GREY OUT (disableOn = borderOff, applied by the loop at the end of this
    -- function) so the panel previews them. `hideOff` now means "hidden by the
    -- parent/variant gate only" (whatever the consumer passes via hideWhen); the
    -- name is kept so the existing `.hideOn = hideOff` references read unchanged.
    local function hideOff()  return hideShow() end
    local function borderOff() return dbTable[showKey] == false end

    local w = {}

    -- opts.noShowToggle: suppress the built-in "Show Border" checkbox for
    -- consumers that gate the whole border on an external toggle (e.g. the
    -- Targeted Spells "Highlight Important Spells" master). With the checkbox
    -- gone, showKey stays nil so hideOff() reduces to hideShow() — the toolkit
    -- shows/hides purely on the external hideWhen.
    if not opts.noShowToggle then
        w.show = group:AddWidget(GUI:CreateCheckbox(parent, L["Show Border"], dbTable, showKey, function()
            if refreshStates then refreshStates() end
            fullUpdate()
        end), 30)
        w.show.hideOn = hideShow
    end

    -- Slider label reads "Border Thickness" (more meaningful than "Size") but
    -- the underlying db key stays `<prefix>BorderSize` and spec.size in the
    -- backend stays the same — purely a user-facing rename, no migration.
    w.size = group:AddWidget(GUI:CreateSlider(parent, L["Border Thickness"], sizeMin, sizeMax, sizeStep,
        dbTable, key("BorderSize"), fullUpdate, lightUpdate, true), 55)
    w.size.hideOn = hideOff

    -- Gradient is a STYLE, not a separate toggle. When the consumer opts into
    -- gradient via include.gradient, we expose GRADIENT as a third dropdown
    -- option. Otherwise the dropdown is the original SOLID / TEXTURE pair.
    local styleOptions = { SOLID = L["Solid"], TEXTURE = L["Texture"],
        _order = { "SOLID", "TEXTURE" } }
    if include.gradient then
        styleOptions.GRADIENT = L["Gradient"]
        -- Insert GRADIENT between SOLID and TEXTURE so the order reads
        -- "simple colour → two colours → custom texture" in the dropdown.
        styleOptions._order = { "SOLID", "GRADIENT", "TEXTURE" }
    end
    w.style = group:AddWidget(GUI:CreateDropdown(parent, L["Border Style"],
        styleOptions, dbTable, key("BorderStyle"), function()
            -- Match the frame border: pick the first LSM border when switching
            -- to Texture without one configured.
            if dbTable[key("BorderStyle")] == "TEXTURE" then
                local list = DF.GetBorderList and DF:GetBorderList() or nil
                local t = dbTable[key("BorderTexture")]
                if list and (not t or t == "" or t == "SOLID") then
                    dbTable[key("BorderTexture")] = next(list)
                end
            end
            if refreshStates then refreshStates() end
            fullUpdate()
        end), 55)
    w.style.hideOn = hideOff

    -- isGradient is declared up here so the Style-dependent widget cluster
    -- (Texture under TEXTURE style, gradient pickers under GRADIENT style)
    -- can sit immediately below the Style dropdown — the consequence of the
    -- user's style choice reads top-to-bottom without scrolling past
    -- unrelated inset / offset / blend controls first.
    local function isGradient() return dbTable[key("BorderStyle")] == "GRADIENT" end

    w.texture = group:AddWidget(GUI:CreateDropdown(parent, L["Border Texture"],
        DF:GetBorderList(), dbTable, key("BorderTexture"), fullUpdate), 55)
    w.texture.hideOn = function()
        return hideOff() or dbTable[key("BorderStyle")] ~= "TEXTURE"
    end

    -- Gradient pickers — only visible under Style = GRADIENT.  Grouped here
    -- (between Texture and the Colour Source dropdown) so all style-dependent
    -- widgets sit directly under the Style dropdown that controls them.
    -- The standalone "Border Gradient" checkbox was removed when Style
    -- absorbed it; Style is now the single source of truth so it's not
    -- possible to pick "Solid + Class Color" then have a Gradient checkbox
    -- stomp the class colour (the previous UX bug).  Legacy
    -- `<prefix>BorderGradientEnabled = true` profiles are migrated to
    -- `<prefix>BorderStyle = "GRADIENT"` on db load.
    if include.gradient then
        local function gradHide() return hideOff() or not isGradient() end

        w.gradientStart = group:AddWidget(GUI:CreateColorPicker(parent, L["Gradient Start Color"],
            dbTable, key("BorderGradientStartColor"), true, fullUpdate), 35)
        w.gradientStart.hideOn = gradHide
        w.gradientEnd = group:AddWidget(GUI:CreateColorPicker(parent, L["Gradient End Color"],
            dbTable, key("BorderGradientEndColor"), true, fullUpdate), 35)
        w.gradientEnd.hideOn = gradHide
        w.gradientDirection = group:AddWidget(GUI:CreateDropdown(parent, L["Gradient Direction"],
            { HORIZONTAL = L["Horizontal"], VERTICAL = L["Vertical"] },
            dbTable, key("BorderGradientDirection"), fullUpdate), 55)
        w.gradientDirection.hideOn = gradHide
    end

    -- Colour Source dropdown sits ABOVE the colour picker so the relationship
    -- "source → resulting colour" reads top-to-bottom in the panel. The
    -- options table is built dynamically: Static is always present; Class
    -- and Role are added if the consumer opted in via the matching include.
    -- Hidden in GRADIENT style — gradient owns its own colours, no resolver
    -- chain applies (see Border:BuildSpec).
    local sourceKey = key("BorderColorSource")
    local hasSourceDropdown = include.classColor or include.roleColor
    if hasSourceDropdown then
        local sourceOptions = { STATIC = L["Static"], _order = { "STATIC" } }
        if include.classColor then
            sourceOptions.CLASS = L["Class"]
            sourceOptions._order[#sourceOptions._order + 1] = "CLASS"
        end
        if include.roleColor then
            sourceOptions.ROLE = L["Role"]
            sourceOptions._order[#sourceOptions._order + 1] = "ROLE"
        end
        -- Default the source from the legacy boolean keys when first opened.
        if dbTable[sourceKey] == nil then
            if dbTable[key("BorderUseClassColor")]     then dbTable[sourceKey] = "CLASS"
            elseif dbTable[key("BorderUseRoleColor")]  then dbTable[sourceKey] = "ROLE"
            else                                            dbTable[sourceKey] = "STATIC" end
        end
        w.colorSource = group:AddWidget(GUI:CreateDropdown(parent, L["Border Color Source"],
            sourceOptions, dbTable, sourceKey, function()
                if refreshStates then refreshStates() end
                fullUpdate()
            end), 55)
        w.colorSource.hideOn = function() return hideOff() or isGradient() end
        w.colorSource.tooltip = L["Where the border colour comes from. Static uses the colour below; Class and Role read it from the unit, so the border tells you who you are looking at without reading the name."]
    end

    -- Static colour picker — only visible when source is STATIC (or when the
    -- consumer didn't enable any resolver at all, so source doesn't exist).
    -- Hidden in GRADIENT style (gradient uses its own start/end pickers).
    w.color = group:AddWidget(GUI:CreateColorPicker(parent, L["Border Color"], dbTable, key("BorderColor"),
        true, fullUpdate, lightColors, lightColors ~= nil), 35)
    w.color.hideOn = function()
        if hideOff() or isGradient() then return true end
        if hasSourceDropdown then
            local src = dbTable[sourceKey] or "STATIC"
            return src ~= "STATIC"
        end
        return false
    end

    -- Unified Border Alpha slider — opt-in via include.alpha. Reads / writes
    -- the SAME alpha component the colour picker exposes
    -- (<prefix>BorderColor.a), so the slider is just a convenient handle for
    -- the picker's alpha bar — no separate alpha key to migrate or keep in
    -- sync. Visible in STATIC / CLASS / ROLE; hidden in GRADIENT (where the
    -- two gradient pickers each carry their own alpha, and a single slider
    -- has no obvious meaning).
    if include.alpha then
        -- Ensure the underlying colour table has an alpha component so the
        -- slider doesn't read nil on first open. The picker also seeds .a but
        -- we don't depend on widget-creation order.
        local c = dbTable[key("BorderColor")]
        if type(c) ~= "table" then
            c = { r = 0, g = 0, b = 0, a = 1 }
            dbTable[key("BorderColor")] = c
        end
        if c.a == nil then c.a = 1 end

        -- Read-time nil-guard: these closures fire on the slider's OnShow at
        -- arbitrary later times (tab/page re-show, mode switch), NOT just at
        -- creation. The seed above only guarantees the table exists NOW — a proxy
        -- dbTable can resolve BorderColor to nil later (e.g. re-showing the AD page
        -- for a mode whose config doesn't surface the key), so re-read and guard
        -- each call instead of assuming the table is still there.
        w.alpha = group:AddWidget(GUI:CreateSlider(parent, L["Border Alpha"], 0, 1, 0.05,
            nil, nil, fullUpdate, lightColors or lightUpdate, true,
            function()
                local bc = dbTable[key("BorderColor")]
                return (bc and bc.a) or 1
            end,
            function(v)
                local bc = dbTable[key("BorderColor")]
                if bc then bc.a = v end
            end), 55)
        w.alpha.hideOn = function() return hideOff() or isGradient() end
    end

    if include.inset then
        w.inset = group:AddWidget(GUI:CreateSlider(parent, L["Border Inset"], -20, 20, 1,
            dbTable, key("BorderInset"), fullUpdate, lightUpdate, true), 55)
        w.inset.hideOn = hideOff
        -- Thickness / Inset / Offset are three similar-sounding sliders that do
        -- different things; the tooltip lives here because Inset is the one
        -- nobody guesses.
        w.inset.tooltip = L["Pulls the border inward (positive) or pushes it outward (negative) from the edge. Thickness is how heavy the line is, Inset is how far in it sits, Offset slides the whole border sideways."]
    end

    if include.offset then
        w.offsetX = group:AddWidget(GUI:CreateSlider(parent, L["Border Offset X"], offMin, offMax, offStep,
            dbTable, key("BorderOffsetX"), fullUpdate, lightUpdate, true), 55)
        w.offsetX.hideOn = hideOff
        w.offsetY = group:AddWidget(GUI:CreateSlider(parent, L["Border Offset Y"], offMin, offMax, offStep,
            dbTable, key("BorderOffsetY"), fullUpdate, lightUpdate, true), 55)
        w.offsetY.hideOn = hideOff
        -- No tooltip on Offset X/Y, deliberately, and the same goes for every
        -- other Offset slider in the addon (~60 of them): an offset is a well
        -- understood control and a tooltip restating it is noise. Inset is the
        -- one that needs explaining, so the Thickness / Inset / Offset
        -- distinction is spelled out THERE, once. Krathe's call, 2026-07-27 —
        -- these two briefly had tooltips and Border Shadow's offsets did not,
        -- which is the inconsistency that prompted it.
    end

    if include.blendMode then
        w.blendMode = group:AddWidget(GUI:CreateDropdown(parent, L["Border Blend Mode"],
            { BLEND = L["Blend"], ADD = L["Add"], MOD = L["Modulate"], DISABLE = L["Disable"] },
            dbTable, key("BorderBlendMode"), fullUpdate), 55)
        w.blendMode.hideOn = hideOff
        w.blendMode.tooltip = L["How the border colour mixes with whatever is behind it. Blend is normal. Add brightens and is what makes a colour glow. Modulate darkens. Disable ignores opacity entirely and draws the colour flat."]
    end

    if include.shadow then
        local shadowOnKey = key("BorderShadowEnabled")
        w.shadowEnabled = group:AddWidget(GUI:CreateCheckbox(parent, L["Border Shadow"], dbTable, shadowOnKey, function()
            if refreshStates then refreshStates() end
            fullUpdate()
        end), 30)
        w.shadowEnabled.hideOn = hideOff
        -- Border Shadow OFF greys (not hides) its sub-controls — a nested boolean
        -- toggle, same grey-everything rule. The end-of-function loop OR-composes
        -- borderOff, so these also grey when Show Border is off.
        local function shadowOff() return dbTable[shadowOnKey] == false end

        w.shadowColor = group:AddWidget(GUI:CreateColorPicker(parent, L["Shadow Color"],
            dbTable, key("BorderShadowColor"), true, fullUpdate), 35)
        w.shadowColor.hideOn = hideOff
        w.shadowColor.disableOn = shadowOff
        w.shadowSize = group:AddWidget(GUI:CreateSlider(parent, L["Shadow Size"], 0, 10, 1,
            dbTable, key("BorderShadowSize"), fullUpdate, lightUpdate, true), 55)
        w.shadowSize.hideOn = hideOff
        w.shadowSize.disableOn = shadowOff
        w.shadowOffsetX = group:AddWidget(GUI:CreateSlider(parent, L["Shadow Offset X"], -10, 10, 1,
            dbTable, key("BorderShadowOffsetX"), fullUpdate, lightUpdate, true), 55)
        w.shadowOffsetX.hideOn = hideOff
        w.shadowOffsetX.disableOn = shadowOff
        w.shadowOffsetY = group:AddWidget(GUI:CreateSlider(parent, L["Shadow Offset Y"], -10, 10, 1,
            dbTable, key("BorderShadowOffsetY"), fullUpdate, lightUpdate, true), 55)
        w.shadowOffsetY.hideOn = hideOff
        w.shadowOffsetY.disableOn = shadowOff
    end

    -- ===== Animation (Stage 3) =====
    -- include.animate drops the full Border Animation control set (Type
    -- dropdown + per-effect tunables, each with a hideOn keyed to the effect
    -- it applies to). Built from the shared GUI:CreateAnimationControls so the
    -- base panel and AD's Expiring override never drift. The whole block folds
    -- under Show Border via hideExtra = hideOff. Widget handles are merged back
    -- onto `w` so existing references (w.animationType, …) are preserved.
    if include.animate then
        local aw = GUI:CreateAnimationControls(group, dbTable, key("BorderAnimation"), {
            parent       = parent,
            fullUpdate   = fullUpdate,
            lightUpdate  = lightUpdate,
            lightColors  = lightColors,
            typeLabel    = L["Border Animation"],
            -- Optional caller filter, forwarded from the CreateBorderControls call
            -- site (e.g. the Aura Designer border restricts to overlay-recoverable
            -- animation types). nil for every other caller → full type list.
            excludeTypes = opts.animExcludeTypes,
            hideExtra    = hideOff,
            onTypeChange = function()
                if refreshStates then refreshStates() end
                fullUpdate()
            end,
        })
        for k, v in pairs(aw) do w[k] = v end
    end

    -- ===== Colour resolver toggles (Stage 2) =====
    -- These flip BorderColor's source from the static picker to a per-unit /
    -- per-aura / per-tick computation. BuildSpec applies them in priority
    -- order (type > time > class > role > static) when the consumer passes
    -- ctx to BuildSpec. The static colour picker still controls the fallback
    -- (when ctx is missing or the resolver yields nil).

    -- (Colour Source dropdown + Static colour picker + Alpha slider are wired
    -- earlier, above the inset/offset/blendMode/gradient/shadow block, so the
    -- relationship "source → colour" reads top-to-bottom in the panel.)

    if include.colorByTime then
        w.colorByTime = group:AddWidget(GUI:CreateCheckbox(parent, L["Color by Time Remaining"], dbTable, key("BorderColorByTime"), fullUpdate), 30)
        w.colorByTime.hideOn = hideOff
        -- The actual colour curve picker is consumer-specific (e.g. AD's
        -- existing expiring colour curve) and is added by the consumer
        -- alongside this checkbox.
    end

    if include.colorByType then
        w.colorByType = group:AddWidget(GUI:CreateCheckbox(parent, L["Color by Aura Type"], dbTable, key("BorderColorByType"), fullUpdate), 30)
        w.colorByType.hideOn = hideOff
    end

    -- Two independent greys, both composed on top of whatever disableOn a control
    -- already carries (e.g. the shadow sub-controls), and both leaving the
    -- variant hideOn untouched:
    --   disableWhen — the CONSUMER's gate: the feature this border belongs to is
    --     switched off. Applies to EVERY widget including the Show Border
    --     checkbox, since with the feature off there is nothing for it to show.
    --   borderOff   — Show Border itself is off. Applies to everything EXCEPT the
    --     Show Border checkbox, which has to stay clickable to turn it back on.
    -- RefreshChildStates applies disableOn to group children, and CreateCheckbox
    -- auto-refreshes on toggle, so both greys update live.
    for k, widget in pairs(w) do
        if type(widget) == "table" and widget.SetEnabled then
            local prev = widget.disableOn
            local isShow = (k == "show")
            widget.disableOn = function(d)
                if disableWhen and disableWhen(dbTable) then return true end
                if not isShow and borderOff() then return true end
                return (prev and prev(d)) or false
            end
        end
    end

    return w
end

-- ============================================================
-- SHARED TEXT-STYLE CONTROLS (pairs with DF.TextStyle — the engine consumers
-- style FontStrings through). Mirrors CreateBorderControls: one builder, every
-- text block in the addon renders the same control flow instead of a hand-rolled
-- copy per page. Emits, in the pages' established order:
--   Font, Scale, Outline, Shadow, [Color], Anchor, Offset X/Y, [Justify H, Justify V]
-- Key convention: <prefix>Font/Scale/Outline/Anchor/X/Y/JustifyH/JustifyV/Color.
--
-- opts:
--   parent         REQUIRED — the page scroll child (self.child)
--   include        = { color = false, justify = true, anchor = true, offsets = true }
--   colorLabel     colour picker label (default L["Text Color"])
--   disableOn      predicate applied to EVERY created widget (page-level gate)
--   hideOn         predicate applied to EVERY created widget
--   colorDisableOn EXTRA disable gate for the colour picker only (e.g. colour-by-time on)
--   onChange       full-update callback (dropdowns / colour commit)
--   onDrag         lightweight slider-drag callback (also colour live-preview)
--   scaleMin/Max/Step, offsetMin/Max — slider ranges (defaults 0.5–2.0 ×0.05, ±150)
-- Returns the created widgets keyed { font, scale, outline, shadow, color, anchor,
-- offsetX, offsetY, justifyH, justifyV } so pages can attach extra gates.
-- ============================================================
function GUI:CreateTextControls(group, dbTable, prefix, opts)
    opts = opts or {}
    local parent   = opts.parent
    local include  = opts.include or {}
    local onChange = opts.onChange
    local onDrag   = opts.onDrag or onChange
    local L = DF.L

    local scaleMin, scaleMax, scaleStep = opts.scaleMin or 0.5, opts.scaleMax or 2.0, opts.scaleStep or 0.05
    local offMin, offMax = opts.offsetMin or -150, opts.offsetMax or 150

    local function key(suffix) return prefix .. suffix end
    local widgets = {}

    -- Apply the shared page gates to a widget, composing with any the widget factory set.
    local function gate(w)
        if opts.disableOn then
            local prev = w.disableOn
            w.disableOn = function(d) return (opts.disableOn(d) or (prev and prev(d))) and true or false end
        end
        if opts.hideOn then w.hideOn = opts.hideOn end
        return w
    end

    widgets.font = gate(group:AddWidget(GUI:CreateFontDropdown(parent, L["Font"], dbTable, key("Font"), onChange), 55))
    widgets.scale = gate(group:AddWidget(GUI:CreateSlider(parent, L["Scale"], scaleMin, scaleMax, scaleStep, dbTable, key("Scale"), nil, onDrag, true), 55))
    widgets.outline = gate(group:AddWidget(GUI:CreateOutlineDropdown(parent, L["Outline"], dbTable, key("Outline"), onChange), 55))
    widgets.shadow = gate(group:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], dbTable, key("Outline"), onChange), 30))

    if include.color then
        widgets.color = gate(group:AddWidget(GUI:CreateColorPicker(parent, opts.colorLabel or L["Text Color"], dbTable, key("Color"), false, onChange, onDrag, true), 35))
        if opts.colorDisableOn then
            local prev = widgets.color.disableOn
            widgets.color.disableOn = function(d) return (opts.colorDisableOn(d) or (prev and prev(d))) and true or false end
        end
    end

    if include.anchor ~= false then
        local anchorOptions = {
            CENTER = L["Center"], TOP = L["Top"], BOTTOM = L["Bottom"], LEFT = L["Left"], RIGHT = L["Right"],
            TOPLEFT = L["Top Left"], TOPRIGHT = L["Top Right"], BOTTOMLEFT = L["Bottom Left"], BOTTOMRIGHT = L["Bottom Right"],
        }
        widgets.anchor = gate(group:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], anchorOptions, dbTable, key("Anchor"), onChange), 55))
        -- Anchor vs Justify is the pair people get wrong: one places the text,
        -- the other arranges it within its own box. Both say so, from their side.
        widgets.anchor.tooltip = L["Which part of the element the text is pinned to. Offset X and Y then nudge it from there."]
    end

    if include.offsets ~= false then
        widgets.offsetX = gate(group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], offMin, offMax, 1, dbTable, key("X"), nil, onDrag, true), 55))
        widgets.offsetY = gate(group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], offMin, offMax, 1, dbTable, key("Y"), nil, onDrag, true), 55))
    end

    -- Justify is OPT-IN (include.justify = true). It's redundant with Anchor for short
    -- single-token text on a small icon (duration/stacks) and boxing to justify TRUNCATES
    -- wide text like "59m" — so the aura pages don't expose it. The DF.TextStyle engine
    -- still honors JustifyH/JustifyV keys for a future wide/fixed-region consumer.
    if include.justify then
        local justifyHOptions = { [""] = L["Default"], LEFT = L["Left"], CENTER = L["Center"], RIGHT = L["Right"] }
        local justifyVOptions = { [""] = L["Default"], TOP = L["Top"], MIDDLE = L["Middle"], BOTTOM = L["Bottom"] }
        widgets.justifyH = gate(group:AddWidget(GUI:CreateDropdown(parent, L["Justify H"], justifyHOptions, dbTable, key("JustifyH"), onChange), 55))
        widgets.justifyH.tooltip = L["How the text sits inside its own box, once Anchor has decided where that box goes. Only visible on text wide enough to have slack — Anchor is what moves it around the element."]
        widgets.justifyV = gate(group:AddWidget(GUI:CreateDropdown(parent, L["Justify V"], justifyVOptions, dbTable, key("JustifyV"), onChange), 55))
        widgets.justifyV.tooltip = L["How the text sits inside its own box, once Anchor has decided where that box goes. Only visible on text wide enough to have slack — Anchor is what moves it around the element."]
    end

    return widgets
end
