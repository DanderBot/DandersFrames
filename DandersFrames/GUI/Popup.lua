local addonName, DF = ...

-- ============================================================
-- POPUP SUPPORT
-- The alert / input framework lives in DandersUI. What stays here is the
-- settings-highlight overlay (DF:HighlightWidget, DF:ClearSettingHighlights),
-- which is DandersFrames chrome pointed at DandersFrames pages, plus the three
-- delegates that keep the existing DF:ShowPopup* call sites working.
-- ============================================================

local ipairs, tinsert, tremove, wipe = ipairs, table.insert, table.remove, table.wipe
local L = DF.L
local CreateFrame = CreateFrame
local UIParent = UIParent
local BackdropTemplateMixin = BackdropTemplateMixin
local Mixin = Mixin

-- ============================================================
-- THEME COLORS (matching GUI/GUI.lua)
-- ============================================================

-- The shared dialog palette (GUI.lua loads first). Neutrals are the same tables
-- as GUI.Colors so they theme-track in lockstep; the dialog-specific tones
-- (denser background, selected, green, red) live there too, so there is exactly
-- one copy in the addon. (A third copy lived in WizardBuilder.lua, since deleted.)
local C = DF.GUI.DialogColors

-- ============================================================
-- BACKDROP HELPERS
-- ============================================================

-- Thin wrapper over the shared GUI backdrop so this file's positional call style
-- keeps working. The look, and the pixel-grid snapping, come from the one place.
local function ApplyBackdrop(frame, bgColor, borderColor, edgeSize)
    DF.GUI:CreateElementBackdrop(frame, {
        bgColor     = bgColor,
        borderColor = borderColor,
        edgeSize    = edgeSize,
    })
end

-- Settings-highlight pools. Used by DF:HighlightWidget, whose live caller is
-- FilterRegistry/Options.lua.
local highlightPool = {}
local activeHighlights = {}

-- ============================================================
-- SETTINGS HIGHLIGHT SYSTEM
-- Highlights specific controls in the settings GUI with a
-- pulsing orange background that fades out after a few seconds.
-- ============================================================

-- FALLBACK ONLY. This was the highlight's actual colour, hard-coded, and it reads
-- as the RAID theme -- so a pulse fired while Party was active looked like the GUI
-- had switched modes under you (Krathe, 2026-08-10, following an Aura Designer edit
-- link). ApplyHighlightOverlay now tints from the live theme; this stands in only if
-- the theme cannot be resolved.
local HIGHLIGHT_COLOR = {r = 1.0, g = 0.5, b = 0.1}  -- orange
local HIGHLIGHT_PULSES = 4      -- number of pulse cycles
local HIGHLIGHT_PULSE_DUR = 0.4 -- seconds per half-cycle

local function CreateHighlightOverlay()
    local overlay = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    ApplyBackdrop(overlay, HIGHLIGHT_COLOR, HIGHLIGHT_COLOR, 2)
    overlay:SetBackdropColor(HIGHLIGHT_COLOR.r, HIGHLIGHT_COLOR.g, HIGHLIGHT_COLOR.b, 0.15)
    overlay:SetBackdropBorderColor(HIGHLIGHT_COLOR.r, HIGHLIGHT_COLOR.g, HIGHLIGHT_COLOR.b, 0.8)

    -- Pulse animation: flash a few times then fade out
    local ag = overlay:CreateAnimationGroup()

    -- Pulse cycles (bright -> dim -> bright ...)
    for i = 1, HIGHLIGHT_PULSES do
        local fadeUp = ag:CreateAnimation("Alpha")
        fadeUp:SetFromAlpha(0.3)
        fadeUp:SetToAlpha(1)
        fadeUp:SetDuration(HIGHLIGHT_PULSE_DUR)
        fadeUp:SetOrder(i * 2 - 1)

        local fadeDown = ag:CreateAnimation("Alpha")
        fadeDown:SetFromAlpha(1)
        fadeDown:SetToAlpha(0.3)
        fadeDown:SetDuration(HIGHLIGHT_PULSE_DUR)
        fadeDown:SetOrder(i * 2)
    end

    -- Final fade out to invisible
    local fadeOut = ag:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(0.3)
    fadeOut:SetToAlpha(0)
    fadeOut:SetDuration(0.6)
    fadeOut:SetOrder(HIGHLIGHT_PULSES * 2 + 1)

    ag:SetScript("OnFinished", function()
        overlay:SetAlpha(0)
    end)

    overlay.pulseAnim = ag
    overlay:Hide()
    return overlay
end

local function GetHighlightOverlay()
    local overlay = tremove(highlightPool)
    if not overlay then
        overlay = CreateHighlightOverlay()
    end
    return overlay
end

function DF:ClearSettingHighlights()
    for _, overlay in ipairs(activeHighlights) do
        overlay.pulseAnim:Stop()
        overlay:SetAlpha(1)
        overlay:ClearAllPoints()
        overlay:SetParent(UIParent)
        overlay:Hide()
        tinsert(highlightPool, overlay)
    end
    wipe(activeHighlights)
end

-- Apply a pulsing highlight overlay to one widget. Shared by
-- DF:HighlightSettings (dbKey-matched controls) and DF:HighlightWidget.
local function ApplyHighlightOverlay(widget)
    local overlay = GetHighlightOverlay()
    -- ⚠ RE-TINT ON EVERY USE, not once at creation. Two reasons, and either alone
    -- would be enough: the overlay is POOLED, so one built during a Raid session
    -- would keep that colour for every later Party pulse; and the mode can change
    -- between two pulses of the same overlay.
    local c = (DF.GUI and DF.GUI.GetThemeColor and DF.GUI.GetThemeColor()) or HIGHLIGHT_COLOR
    overlay:SetBackdropColor(c.r, c.g, c.b, 0.15)
    overlay:SetBackdropBorderColor(c.r, c.g, c.b, 0.8)
    overlay:SetParent(widget)
    overlay:SetFrameLevel(widget:GetFrameLevel() + 10)
    overlay:ClearAllPoints()
    overlay:SetPoint("TOPLEFT", widget, "TOPLEFT", -3, 3)
    overlay:SetPoint("BOTTOMRIGHT", widget, "BOTTOMRIGHT", 3, -3)
    overlay:SetAlpha(1)
    overlay:Show()
    overlay.pulseAnim:Play()
    tinsert(activeHighlights, overlay)
end

-- Highlight one arbitrary widget (no dbKey matching) with the same pulsing
-- overlay as HighlightSettings. Used by cross-page affordances that guide the
-- user to a specific button (e.g. the Aura Designer's "Create Filter" button
-- pulsing the Filter Designer's New Filter button after navigating there).
function DF:HighlightWidget(widget)
    DF:ClearSettingHighlights()
    if not widget or not widget.GetFrameLevel then return end
    ApplyHighlightOverlay(widget)
end

-- (Removed) DF:HighlightSettings — the dbKey-matched variant of the highlight
-- system. It had no callers: only DF:HighlightWidget (above) is used, from
-- FilterRegistry/Options.lua. The shared machinery it used — CreateHighlightOverlay,
-- GetHighlightOverlay, ApplyHighlightOverlay, DF:ClearSettingHighlights and the
-- highlightPool / activeHighlights pools — all STAYS for HighlightWidget.

-- (Removed) SETTINGS PICKER MODE — DF:EnterSettingsPickerMode,
-- DF:ApplyPickerOverlaysToCurrentPage, DF:ClearSettingsPicker,
-- DF:CancelSettingsPickerMode, the CreatePickerOverlay / CreatePickerBanner
-- builders and the pickerOverlays / pickerBanner / PICKER_COLOR /
-- DF.settingsPickerMode / DF.settingsPickerCallback state.
--
-- It let the wizard builder capture a setting by clicking it in the live GUI, so
-- its only entry point died with WizardBuilder.lua.
--
-- ☠ WHY IT SURVIVED THE WIZARD-RUNTIME COMMIT, AND THE LESSON. GUI.lua still
-- referenced ApplyPickerOverlaysToCurrentPage, which read like a live external
-- caller. But that reference was gated on DF.settingsPickerMode, and the ONLY
-- writer of that flag was EnterSettingsPickerMode — which nothing called. An
-- uncalled writer makes every reader unreachable no matter how live the call
-- site looks: when a reference is behind a flag, check what SETS the flag.

-- ============================================================
-- POPUP DELEGATES
-- ~30 existing call sites say DF:ShowPopupAlert / DF:ShowPopupInput. These keep
-- every one of them working against the pack implementation.
-- ============================================================
function DF:ShowPopupAlert(config) return DF.GUI:ShowPopupAlert(config) end
function DF:ShowPopupInput(config) return DF.GUI:ShowPopupInput(config) end
function DF:IsPopupShown() return DF.GUI:IsPopupShown() end
