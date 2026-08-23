local addonName, NS = ...
local UI = NS.__DandersUI
if not UI then return end

-- ============================================================
-- POPUP SYSTEM
-- One alert / input dialog for every consumer. There is exactly ONE frame: a
-- second Show* while a dialog is open TAKES IT OVER rather than stacking (see
-- ResolveOutgoingInput). That is also why the frame is singular ACROSS hosts --
-- two consumers cannot both own the screen modal at once, and whichever one
-- called last supplies the locale and the accent.
-- ============================================================
local ipairs, tinsert, tremove, wipe = ipairs, table.insert, table.remove, table.wipe
local max, min = math.max, math.min
local CreateFrame, UIParent = CreateFrame, UIParent
local PlaySound, SOUNDKIT = PlaySound, SOUNDKIT
local BackdropTemplateMixin, Mixin = BackdropTemplateMixin, Mixin
local UISpecialFrames = UISpecialFrames

local C = UI.DialogColors

-- ============================================================
-- STYLED BUTTON HELPER
-- ============================================================

local function CreatePopupButton(host, parent, text, width, height)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    host:StyleButton(btn, { width = width or 120, height = height or 28 })

    btn.Text = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    -- Anchor to both left and right edges (with a small inset) so SetWordWrap
    -- can flow long labels onto multiple lines within the button.
    btn.Text:SetPoint("LEFT", 6, 0)
    btn.Text:SetPoint("RIGHT", -6, 0)
    btn.Text:SetJustifyH("CENTER")
    btn.Text:SetJustifyV("MIDDLE")
    btn.Text:SetWordWrap(true)
    btn.Text:SetText(text)
    btn.Text:SetTextColor(C.text.r, C.text.g, C.text.b)

    btn:SetScript("OnClick", function(self)
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        if self.onClick then self.onClick(self) end
    end)

    return btn
end

-- ============================================================
-- FRAME CONSTRUCTION (lazy, called once)
-- ============================================================

local PopupFrame = nil
local FRAME_WIDTH = 440
local CONTENT_PADDING = 20

-- Mode tracking
local popupMode = nil  -- "alert" or "input"

-- ============================================================
-- (Removed) TEST MODE & GUI INTEGRATION HELPERS plus the wizard step engine:
-- FlashContainer, CleanupTestMode, CleanupGUI, ProcessStepIntegration,
-- GetStepById, EvaluateBranches, GetNextStepId and CompleteWizard. All were
-- wizard-mode only; the alert and input paths never called any of them.
local function HideInputWidgets(f)
    if f.InputBox then f.InputBox:Hide() end
    if f.InputAreaBox then f.InputAreaBox:Hide() end
end

local function CreatePopupFrame(host)
    if PopupFrame then return PopupFrame end

    local f = CreateFrame("Frame", "DFPopupFrame", UIParent, "BackdropTemplate")
    -- ☠ PARENTED TO UIParent, SO IT DOES NOT INHERIT A CONSUMER WINDOW SCALE.
    -- hooks.getScale is how a consumer that scales its own chrome keeps this in
    -- step. Seeded HERE because the frame is created lazily on first use: a
    -- popup first opened after the scale moved would otherwise never have been
    -- told the scale at all.
    f:SetScale(host:Call("getScale") or 1)
    -- Ride the shared GUI pixel grid: this surface is parented to UIParent, so it
    f:SetSize(FRAME_WIDTH, 300)
    f:SetPoint("CENTER")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetFrameLevel(250)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:Hide()
    host:CreateElementBackdrop(f, { bgColor = C.background, borderColor = { 0, 0, 0, 1 }, edgeSize = 2 })

    -- ============================================================
    -- TITLE BAR
    -- ============================================================

    local titleBar = CreateFrame("Frame", nil, f, "BackdropTemplate")
    titleBar:SetPoint("TOPLEFT", 2, -2)
    titleBar:SetPoint("TOPRIGHT", -2, -2)
    titleBar:SetHeight(32)
    if not titleBar.SetBackdrop then Mixin(titleBar, BackdropTemplateMixin) end
    host:CreateElementBackdrop(titleBar, {
        outline = false,
        bgColor     = { C.panel.r, C.panel.g, C.panel.b, 1 },
    })
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() f:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    titleBar:EnableMouse(true)

    -- Accent stripe at very top
    local stripe = f:CreateTexture(nil, "OVERLAY")
    stripe:SetPoint("TOPLEFT", 2, -2)
    stripe:SetPoint("TOPRIGHT", -2, -2)
    stripe:SetHeight(2)
    local ac = host:GetAccent()
    stripe:SetColorTexture(ac.r, ac.g, ac.b, 1)
    f.AccentStripe = stripe

    -- Title text
    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
    titleText:SetPoint("CENTER")
    titleText:SetTextColor(C.text.r, C.text.g, C.text.b)
    f.TitleText = titleText

    -- Close button
    local closeBtn = host:CreateCloseButton(titleBar, { onClick = function()
        host:Call("onPopupOpen")
        f:Hide()
    end })
    closeBtn:SetPoint("RIGHT", -6, 0)

    -- ============================================================
    -- CONTENT AREA
    -- ============================================================

    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", CONTENT_PADDING, -CONTENT_PADDING)
    content:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", -CONTENT_PADDING, -CONTENT_PADDING)
    -- Bottom anchor added after buttonBar is created (see below)
    f.Content = content


    -- Message text (alert mode)
    local messageText = content:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    messageText:SetPoint("TOPLEFT")
    messageText:SetPoint("TOPRIGHT")
    messageText:SetJustifyH("LEFT")
    messageText:SetSpacing(3)
    messageText:SetTextColor(C.text.r, C.text.g, C.text.b)
    f.MessageText = messageText

    -- Alert icon (alert mode, optional)
    local alertIcon = content:CreateTexture(nil, "OVERLAY")
    alertIcon:SetSize(32, 32)
    alertIcon:SetPoint("TOPLEFT")
    alertIcon:Hide()
    f.AlertIcon = alertIcon




    -- ============================================================
    -- BUTTON BAR (bottom)
    -- ============================================================

    local buttonBar = CreateFrame("Frame", nil, f)
    buttonBar:SetPoint("BOTTOMLEFT", 2, 2)
    buttonBar:SetPoint("BOTTOMRIGHT", -2, 2)
    buttonBar:SetHeight(36)
    if not buttonBar.SetBackdrop then Mixin(buttonBar, BackdropTemplateMixin) end
    host:CreateElementBackdrop(buttonBar, {
        outline = false,
        bgColor     = { C.panel.r, C.panel.g, C.panel.b, 1 },
    })
    f.ButtonBar = buttonBar

    -- Now anchor content bottom to button bar top (content needs height to render children)
    content:SetPoint("BOTTOMLEFT", buttonBar, "TOPLEFT", CONTENT_PADDING, CONTENT_PADDING)
    content:SetPoint("BOTTOMRIGHT", buttonBar, "TOPRIGHT", -CONTENT_PADDING, CONTENT_PADDING)


    -- Alert buttons (dynamically created)
    f.alertButtonFrames = {}

    -- ============================================================
    -- ESCAPE KEY HANDLING
    -- ============================================================

    -- Add to special frames table so Escape closes it
    tinsert(UISpecialFrames, "DFPopupFrame")

    PopupFrame = f
    return f
end

-- (Removed) UpdateNavButtons — the wizard's Back/Next/Finish row. Its body went
-- with the wizard runtime, leaving an empty stub with zero callers.
--
-- ☠ It had also lost its forward `local` declaration in that cut, so `function()`
-- assigned to a BARE GLOBAL named UpdateNavButtons — a very collidable name in
-- the shared _G namespace. Same class as the highlightPool / activeHighlights /
-- alertConfig declarations that commit repaired; this was the instance it missed,
-- and it is invisible to the parser because Lua accepts undeclared globals.

-- ============================================================
-- CONFIGURE FOR ALERT
-- ============================================================

-- ☠ SINGLETON HANDOVER. There is exactly ONE popup frame, so a second Show* while a
-- dialog is still open does not stack — it takes the frame over. The OnHide hook that
-- delivers an unresolved input's onCancel only fires when the frame actually HIDES, and a
-- re-entrant show never hides it: the new config simply overwrote inputConfig/inputResolved
-- and the outgoing dialog's onCancel was dropped. Any caller using onCancel to release
-- state (a pending rename, a held selection, a setting to restore) leaked it. Switching to
-- ALERT mode stranded it the same way, because the OnHide guard is gated on
-- popupMode == "input".
-- Resolve-then-notify order matters: a cancel handler may legally open another popup, and
-- the flag must already be set so this cannot recurse.
local inputConfig, inputResolved   -- assigned by the INPUT MODE section below
local function ResolveOutgoingInput()
    if popupMode == "input" and not inputResolved and inputConfig then
        inputResolved = true
        local prev = inputConfig
        if prev.onCancel then prev.onCancel() end
    end
end

local function ConfigureForAlert(host, config)
    local L = host.hooks.L
    ResolveOutgoingInput()
    local f = CreatePopupFrame(host)

    -- Re-tint the top accent stripe to the live theme (party purple / raid
    -- orange) on each open; the frame itself is only built once.
    if f.AccentStripe then
        local ac = host:GetAccent()
        f.AccentStripe:SetColorTexture(ac.r, ac.g, ac.b, 1)
    end

    -- Reset state
    host:Call("onPopupOpen")
    popupMode = "alert"

    -- Set title
    f.TitleText:SetText(config.title or L["Notice"])
    -- config.tone tints the TITLE, matching how a toned line reads inline and in
    -- GUI:ShowTooltip. Warnings that used to open with a coloured lead line in
    -- the body put that emphasis in the header instead. Reset every time: the
    -- frame is a singleton, so an untoned alert must not inherit the last tint.
    if config.tone and host.GetToneColor then
        local c = host:GetToneColor(config.tone)
        f.TitleText:SetTextColor(c[1], c[2], c[3])
    else
        f.TitleText:SetTextColor(C.text.r, C.text.g, C.text.b)
    end

    -- Set frame width
    local width = config.width or FRAME_WIDTH
    f:SetWidth(width)

    -- Park the widgets this mode does not use. The popup frame is a singleton, so
    -- a stale field must not survive into a plain alert. Input mode re-shows its
    -- own field immediately after calling this.
    HideInputWidgets(f)

    -- Alert icon (optional)
    f.MessageText:ClearAllPoints()
    if config.icon then
        f.AlertIcon:SetTexture(config.icon)
        f.AlertIcon:Show()
        f.MessageText:SetPoint("TOPLEFT", f.AlertIcon, "TOPRIGHT", 10, 0)
        f.MessageText:SetPoint("TOPRIGHT", f.Content, "TOPRIGHT")
    else
        f.AlertIcon:Hide()
        f.MessageText:SetPoint("TOPLEFT", f.Content, "TOPLEFT")
        f.MessageText:SetPoint("TOPRIGHT", f.Content, "TOPRIGHT")
    end

    -- Set message
    f.MessageText:SetText(config.message or "")
    f.MessageText:Show()

    -- Create/reuse alert buttons
    local buttons = config.buttons or {}
    local numButtons = #buttons
    local btnWidth = config.buttonWidth or 100
    local btnHeight = config.buttonHeight or 26
    local btnSpacing = 8
    local totalBtnWidth = numButtons * btnWidth + (numButtons - 1) * btnSpacing
    local startX = -totalBtnWidth / 2 + btnWidth / 2

    -- Resize the ButtonBar to fit taller buttons (default bar is 36px)
    local desiredBarHeight = math.max(36, btnHeight + 10)
    f.ButtonBar:SetHeight(desiredBarHeight)

    -- Hide old alert buttons
    for _, btn in ipairs(f.alertButtonFrames) do
        btn:Hide()
    end

    for i, btnConfig in ipairs(buttons) do
        local btn = f.alertButtonFrames[i]
        if not btn then
            btn = CreatePopupButton(host, f.ButtonBar, "", btnWidth, btnHeight)
            f.alertButtonFrames[i] = btn
        end

        btn.Text:SetText(btnConfig.label or L["OK"])
        btn:SetSize(btnWidth, btnHeight)
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", f.ButtonBar, "CENTER", startX + (i - 1) * (btnWidth + btnSpacing), 0)
        btn.onClick = function()
            if btnConfig.onClick then
                btnConfig.onClick()
            end
            f:Hide()
        end
        btn:Show()
    end

    -- If no buttons provided, add a default OK button
    if numButtons == 0 then
        local btn = f.alertButtonFrames[1]
        if not btn then
            btn = CreatePopupButton(host, f.ButtonBar, L["OK"], btnWidth, 26)
            f.alertButtonFrames[1] = btn
        end
        btn.Text:SetText(L["OK"])
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", f.ButtonBar, "CENTER", 0, 0)
        btn.onClick = function() f:Hide() end
        btn:Show()
    end

    -- Resize frame
    local messageHeight = f.MessageText:GetStringHeight() or 18
    local iconHeight = config.icon and 32 or 0
    -- extraContentHeight: room for something anchored BELOW the message that the
    -- alert layout doesn't know about. Input mode uses it for its field.
    local contentHeight = max(messageHeight, iconHeight) + (config.extraContentHeight or 0)
    -- Account for dynamically-sized ButtonBar (36 default, more when buttons are taller)
    local barHeight = (f.ButtonBar and f.ButtonBar:GetHeight()) or 36
    local totalHeight = 34 + CONTENT_PADDING + contentHeight + CONTENT_PADDING + (barHeight + 2)
    totalHeight = max(totalHeight, 140)
    totalHeight = min(totalHeight, 500)
    f:SetHeight(totalHeight)

    f:ClearAllPoints()
    f:SetPoint("CENTER")
    f:Show()
end

-- ============================================================
-- PUBLIC API
-- ============================================================

function UI:ShowPopupAlert(config)
    if not config then
        self:Error("ShowPopupAlert: config is required")
        return
    end
    ConfigureForAlert(self, config)
end

-- ============================================================
-- INPUT MODE
-- The one dialog shape this popup lacked, and the only reason ~8 surfaces were
-- still on Blizzard's StaticPopup: a prompt with a text field. Built on the
-- alert layout, so the frame, title bar, theme stripe, button bar and button
-- styling are literally the same widgets — only the field is new, and that is
-- the standard edit box chrome (StyleEditBox).
-- ============================================================

local INPUT_WIDTH      = 380   -- short prompts: a name, a label
local INPUT_WIDTH_WIDE = 500   -- blobs: export / import strings
local INPUT_FIELD_H    = 24
local INPUT_AREA_H     = 96

-- (inputConfig / inputResolved are declared ABOVE ConfigureForAlert so the shared
-- ResolveOutgoingInput handover can see them. Re-declaring them here would shadow those,
-- leaving the handover permanently looking at two nils.)
inputResolved = false

local function EnsureInputWidgets(host, f)
    if f.InputBox then return end

    -- Single line.
    local eb = CreateFrame("EditBox", nil, f.Content)
    eb:SetHeight(INPUT_FIELD_H)
    eb:SetAutoFocus(false)
    host:StyleEditBox(eb)
    eb:Hide()
    f.InputBox = eb

    -- Multi line: the shared text area, so a settings blob reads the same in a
    -- dialog as it does on a settings page. Read-only mode is NOT set here —
    -- this is a singleton reconfigured per call, so ShowPopupInput installs it.
    local box = host:CreateTextArea(f.Content)
    box:Hide()
    f.InputArea, f.InputAreaBox = box.EditBox, box

    -- Escape closes via UISpecialFrames, which just HIDES the frame — no button
    -- handler runs. Without this, dismissing with Escape would silently skip
    -- onCancel. Guarded on input mode so alerts and wizards are unaffected.
    f:HookScript("OnHide", function()
        if popupMode == "input" and not inputResolved then
            inputResolved = true
            if inputConfig and inputConfig.onCancel then inputConfig.onCancel() end
        end
    end)
end

-- config:
--   title, message           header + prompt line (message optional)
--   text                     initial contents
--   acceptLabel/cancelLabel  default OK / Cancel (Close when readOnly)
--   maxLetters               single line only
--   multiline                tall scrolling field instead of one line
--   readOnly                 show-and-copy (export): no accept button, no edits
--   width                    override; defaults 380, or 500 when multiline
--   onAccept(text), onCancel()
function UI:ShowPopupInput(config)
    if not config then
        self:Error("ShowPopupInput: config is required")
        return
    end
    local host, L = self, self.hooks.L
    ResolveOutgoingInput()   -- singleton handover — see ResolveOutgoingInput
    local f = CreatePopupFrame(host)
    EnsureInputWidgets(host, f)

    local multiline = config.multiline and true or false
    local width = config.width or (multiline and INPUT_WIDTH_WIDE or INPUT_WIDTH)
    local fieldH = multiline and INPUT_AREA_H or INPUT_FIELD_H
    local eb = multiline and f.InputArea or f.InputBox
    local widget = multiline and f.InputAreaBox or f.InputBox

    inputConfig, inputResolved = config, false

    local function Accept()
        inputResolved = true
        if config.onAccept then config.onAccept(eb:GetText()) end
    end
    local function Cancel()
        inputResolved = true
        if config.onCancel then config.onCancel() end
    end

    local buttons = {}
    if not config.readOnly then
        buttons[#buttons + 1] = { label = config.acceptLabel or L["OK"], onClick = Accept }
    end
    buttons[#buttons + 1] = {
        label = config.cancelLabel or (config.readOnly and L["Close"] or L["Cancel"]),
        onClick = Cancel,
    }

    ConfigureForAlert(host, {
        title              = config.title,
        message            = config.message,
        width              = width,
        buttons            = buttons,
        extraContentHeight = fieldH + 10,
    })
    popupMode = "input"

    -- Park the shape we're not using, then hang the live one under the message.
    ;(multiline and f.InputBox or f.InputAreaBox):Hide()
    widget:ClearAllPoints()
    widget:SetPoint("TOPLEFT", f.MessageText, "BOTTOMLEFT", 0, -10)
    widget:SetPoint("TOPRIGHT", f.MessageText, "BOTTOMRIGHT", 0, -10)
    widget:SetHeight(fieldH)
    widget:Show()

    -- The multi-line shape needs nothing here: the text area sizes its own
    -- scroll child off the well we just anchored. Only the single line does.
    if not multiline then
        f.InputBox:SetMaxLetters(config.maxLetters or 0)
        f.InputBox:SetScript("OnEnterPressed", function()
            if not config.readOnly then Accept() end
            f:Hide()
        end)
        f.InputBox:SetScript("OnEscapePressed", function() f:Hide() end)
    end

    local initial = config.text or ""
    eb:SetText(initial)
    -- WoW has no read-only EditBox: let the caret and Ctrl+A work, but put the
    -- text back the moment a keystroke changes it.
    eb:SetScript("OnTextChanged", config.readOnly and function(s, user)
        if user and s:GetText() ~= initial then
            s:SetText(initial)
            s:HighlightText()
        end
    end or nil)
    eb:HighlightText()
    eb:SetFocus()
end

-- Restored, having been cut from the resident copy as callerless: a SHARED
-- singleton needs an "is someone else using it" probe -- a consumer that opens
-- a dialog from a timer has no other way to know.
function UI:IsPopupShown()
    return (PopupFrame and PopupFrame:IsShown()) and true or false
end
