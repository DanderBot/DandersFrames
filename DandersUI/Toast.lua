local addonName, NS = ...
local UI = NS.__DandersUI
if not UI then return end

-- ============================================================
-- TOAST
-- A small transient readout at the foot of a surface, naming something that
-- just happened -- "Undid: Frame Width" -- and then going away on its own.
--
-- ONE FRAME PER HOST, not one per call site and not one for the whole library.
-- Per host because the frame carries that consumer's font, chrome and colours,
-- and a library-wide one would be re-dressed on every hand-off between two
-- addons that happen to be open together. ONE because a toast is a
-- NOTIFICATION, and two of them stacked is a queue the reader has to work
-- through: a second ShowToast while one is up REPLACES its text and restarts the
-- clock, so a run of Ctrl+Z presses reads as one toast keeping up rather than as
-- five toasts piling on top of each other. That is the same bargain Popup.lua
-- makes with its single dialog, for the same reason.
--
-- The frame is reparented and re-anchored on EVERY call rather than being pinned
-- to whatever surface first raised one -- a consumer with more than one window
-- (a settings panel and a standalone editor) toasts on the one it is talking
-- about, and the alternative was a toast drawn over a window that is not there.
--
-- Non-interactive by construction: it takes no mouse, so it can never eat a
-- click meant for the control underneath it.
-- ============================================================
local CreateFrame, UIParent = CreateFrame, UIParent
local C_Timer = C_Timer
local max, type = math.max, type

local HOLD = 2          -- seconds the toast holds before it starts fading
local FADE_IN = 0.1
local FADE_OUT = 0.2
local PAD = 12          -- horizontal breathing room either side of the text
local HEIGHT = 24
local BOTTOM_GAP = 14   -- clear of the surface's own bottom edge, INSIDE it
local MIN_WIDTH = 80
local LEVEL_LIFT = 20   -- above the parent's own content

-- The toast this host owns, built on first use.
--
-- ⚠ rawget/rawset, for the reason UI:SetSurfaceStyle uses them: a host's
-- __index IS this library, so a plain read on a host that has never raised a
-- toast would fall through and find whatever the library holds under that key --
-- and every host would then share the first host's frame.
local function GetToast(host)
    local t = rawget(host, "_dfToast")
    if t then return t end

    t = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    t:EnableMouse(false)
    t:Hide()

    local text = t:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    text:SetPoint("CENTER")
    text:SetJustifyH("CENTER")
    t.Text = text

    rawset(host, "_dfToast", t)
    return t
end

-- The chrome, in whichever shape this consumer wears -- the minimal version of
-- Popout.lua's _PaintChrome, and the same two arms: rounded takes the square
-- backdrop down (ApplyRoundedChrome does it), square takes the rounded surface
-- down, so switching between them leaves nothing of the other behind.
--
-- Repainted on every show rather than once at build, because a host that
-- re-themes or switches surface style between two toasts has nothing else to
-- call: the frame outlives both.
local function Paint(host, t)
    local C = UI.Colors
    local s = UI.ResolveSurfaceStyle and UI.ResolveSurfaceStyle(host, nil) or nil
    if s then
        UI:ApplyRoundedChrome(t, {
            radius      = s.radius,
            borderWidth = s.borderWidth,
            fill        = { C.panel.r, C.panel.g, C.panel.b, 1 },
            border      = { C.border.r, C.border.g, C.border.b, 1 },
        })
    else
        if UI.RemoveRoundedChrome then UI:RemoveRoundedChrome(t) end
        host:CreateElementBackdrop(t, {
            bgColor     = { C.panel.r, C.panel.g, C.panel.b, 1 },
            borderColor = { C.border.r, C.border.g, C.border.b, 1 },
        })
    end
    t.Text:SetTextColor(C.text.r, C.text.g, C.text.b)
end

-- Show a toast on `opts.parent`, naming `opts.text`, holding for
-- `opts.duration` seconds before it fades out.
--
--   parent     REQUIRED. The surface it is drawn on, and the thing it belongs
--              to -- the toast anchors inside that frame's bottom edge.
--   text       REQUIRED. One short line; the frame sizes itself to it.
--   duration   seconds of HOLD, not counting the fades. Default 2.
--
-- Returns the frame, so a consumer that wants to nudge it can; returns nil
-- rather than erroring on a call with nothing to say.
function UI:ShowToast(opts)
    if type(opts) ~= "table" then return nil end
    local parent, text = opts.parent, opts.text
    if not parent or type(text) ~= "string" or text == "" then return nil end

    local t = GetToast(self)

    -- Reparent and re-anchor FIRST: everything below (the frame level, the fade)
    -- is measured against where it is about to be drawn, not where it last was.
    t:SetParent(parent)
    t:ClearAllPoints()
    t:SetPoint("BOTTOM", parent, "BOTTOM", 0, BOTTOM_GAP)
    if parent.GetFrameLevel then
        t:SetFrameLevel((parent:GetFrameLevel() or 1) + LEVEL_LIFT)
    end

    t.Text:SetText(text)
    self:SetSettingsFont(t.Text, 11)
    Paint(self, t)
    t:SetSize(max(MIN_WIDTH, (t.Text:GetStringWidth() or 0) + PAD * 2), HEIGHT)

    -- FadeIn stops a fade-out that was already running, and that fade's OnStop
    -- drops its onDone -- so a replacement raised mid-exit cannot be hidden a
    -- moment later by the fade it interrupted. The token below covers the other
    -- half: a hold timer from the previous toast that has not fired yet.
    UI.Fx.FadeIn(t, FADE_IN)

    local token = (rawget(self, "_dfToastToken") or 0) + 1
    rawset(self, "_dfToastToken", token)
    local hold = (type(opts.duration) == "number" and opts.duration >= 0) and opts.duration or HOLD
    if C_Timer and C_Timer.After then
        C_Timer.After(hold, function()
            if rawget(self, "_dfToastToken") ~= token then return end
            -- ☠ IsVISIBLE, not IsShown. A toast whose parent window was closed
            -- under it keeps its own shown flag, so IsShown still answers true --
            -- and a fade on a frame nobody is drawing never finishes, so the
            -- callback that hides it never runs and the toast comes straight
            -- back with the window on its next Show. Hidden outright instead.
            if not t:IsVisible() then t:Hide() return end
            UI.Fx.FadeOut(t, FADE_OUT, function() t:Hide() end)
        end)
    end
    return t
end
