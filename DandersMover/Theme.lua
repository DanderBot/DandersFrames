local addonName, NS = ...

-- ============================================================
-- THEME
-- Colours and tiny widget factories. The lib cannot use DandersFrames' GUI
-- toolkit, so this is the whole UI kit — keep it small.
-- ============================================================
local T = {}
NS.Theme = T

local CreateFrame = CreateFrame
local WHITE = "Interface\\Buttons\\WHITE8x8"
local FONT = "Fonts\\FRIZQT__.TTF"

T.MEDIA = "Interface\AddOns\DandersMover\Media\\"
T.DEFAULT_ICON = T.MEDIA .. "DF_Icon"

T.C = {
    bg       = { 0.08, 0.08, 0.08, 0.95 },
    panel    = { 0.12, 0.12, 0.12, 0.98 },
    element  = { 0.18, 0.18, 0.18, 1 },
    border   = { 0.25, 0.25, 0.25, 1 },
    accent   = { 0.18, 0.612, 0.792, 1 },
    anchored = { 0.55, 0.40, 0.85, 1 },
    hover    = { 0.22, 0.22, 0.22, 1 },
    text     = { 0.9, 0.9, 0.9, 1 },
    muted    = { 0.6, 0.6, 0.6, 1 },
    danger   = { 0.8, 0.2, 0.2, 1 },
}

local function unpackColor(c) return c[1], c[2], c[3], c[4] or 1 end
T.Unpack = unpackColor

function T.Backdrop(frame, bg, border)
    if not frame.SetBackdrop then Mixin(frame, BackdropTemplateMixin) end
    frame:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    frame:SetBackdropColor(unpackColor(bg or T.C.panel))
    frame:SetBackdropBorderColor(unpackColor(border or T.C.border))
end

function T.Label(parent, text, size)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT, size or 12, "OUTLINE")
    fs:SetTextColor(unpackColor(T.C.text))
    fs:SetText(text or "")
    return fs
end

function T.Button(parent, text, w, h, onClick)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w, h)
    T.Backdrop(b, T.C.element, T.C.border)
    b.label = T.Label(b, text, 11)
    b.label:SetPoint("CENTER")
    b:SetScript("OnEnter", function(self) self:SetBackdropColor(unpackColor(T.C.hover)) end)
    b:SetScript("OnLeave", function(self) self:SetBackdropColor(unpackColor(self.baseColor or T.C.element)) end)
    b:SetScript("OnClick", onClick)
    function b:SetEnabledState(on)
        self:SetEnabled(on)
        self.label:SetTextColor(unpackColor(on and T.C.text or T.C.muted))
    end
    -- Resting colour for selected/active state; survives hover, unlike a raw
    -- SetBackdropColor which OnLeave would repaint to the default.
    function b:SetBaseColor(c)
        self.baseColor = c
        self:SetBackdropColor(unpackColor(c or T.C.element))
    end
    return b
end

function T.Checkbox(parent, label, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "BackdropTemplate")
    cb:SetSize(16, 16)
    T.Backdrop(cb, T.C.element, T.C.border)
    local tick = cb:CreateTexture(nil, "OVERLAY")
    tick:SetPoint("CENTER"); tick:SetSize(8, 8)
    tick:SetColorTexture(unpackColor(T.C.accent))
    cb:SetCheckedTexture(tick)
    cb.label = T.Label(cb, label, 11)
    cb.label:SetPoint("LEFT", cb, "RIGHT", 6, 0)
    cb:SetChecked(get())
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    function cb:Refresh() self:SetChecked(get()) end
    return cb
end

function T.EditBox(parent, w, onCommit)
    local e = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    e:SetSize(w, 20)
    T.Backdrop(e, T.C.element, T.C.border)
    e:SetFont(FONT, 11, "OUTLINE")
    e:SetTextColor(unpackColor(T.C.text))
    e:SetAutoFocus(false)
    e:SetTextInsets(4, 4, 0, 0)
    e:SetScript("OnEnterPressed", function(self) onCommit(self:GetText()); self:ClearFocus() end)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return e
end

function T.Slider(parent, w, minV, maxV, step, get, set)
    local s = CreateFrame("Slider", nil, parent, "BackdropTemplate")
    s:SetSize(w, 12)
    s:SetOrientation("HORIZONTAL")
    T.Backdrop(s, T.C.element, T.C.border)
    s:SetThumbTexture(WHITE)
    local thumb = s:GetThumbTexture()
    thumb:SetSize(8, 12); thumb:SetColorTexture(unpackColor(T.C.accent))
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step); s:SetObeyStepOnDrag(true)
    s:SetValue(get())
    s.value = T.Label(s, tostring(get()), 10)
    s.value:SetPoint("LEFT", s, "RIGHT", 6, 0)
    s:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v / step + 0.5) * step
        self.value:SetText(tostring(v))
        if v ~= get() then set(v) end
    end)
    function s:Refresh() self:SetValue(get()) end
    return s
end
