local addonName, UF = ...

--@do-not-package@
-- ============================================================
-- ROUND BAR PROBE (dev only, never packaged)
-- /dfring [unit]  toggles a test panel of 12.1 radial status bars driven by the
-- unit's real health (default player). It answers, in game:
--   * does the client have the radial API at all;
--   * does a radial bar take SECRET health in combat without erroring;
--   * what start/end offsets, feather and reverse actually look like;
--   * does a mask cut a linear bar into a shape.
-- Results are written on the panel itself (no chat output). Every API call is
-- pcall'd and counted, so an error shows as a number, not a Lua error popup.
-- ============================================================

local pcall, tostring, format = pcall, tostring, string.format

local WHITE = "Interface\\Buttons\\WHITE8X8"
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local ROUNDED = "Interface\\Common\\common-iconmask"

local P = { bars = {}, errors = 0, updates = 0, lastError = nil }

local function try(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        P.errors = P.errors + 1
        P.lastError = label .. ": " .. tostring(err)
    end
    return ok
end

local function radialSupported()
    return Enum and Enum.StatusBarRenderMode and Enum.StatusBarRenderMode.Radial ~= nil
end

-- One radial bar: a white square fill clipped to a disc, with a darker disc on
-- top when `ring` is set so only the outer band shows.
local function RadialBar(parent, size, label, setup, ring)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(size, size + 14)

    local bg = holder:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(WHITE)
    bg:SetVertexColor(0.15, 0.15, 0.15, 1)
    bg:SetSize(size, size)
    bg:SetPoint("TOP")
    local bgMask = holder:CreateMaskTexture()
    bgMask:SetTexture(DISC, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    bgMask:SetAllPoints(bg)
    bg:AddMaskTexture(bgMask)

    local bar = CreateFrame("StatusBar", nil, holder)
    bar:SetAllPoints(bg)
    bar:SetStatusBarTexture(WHITE)
    bar:SetStatusBarColor(0.2, 0.85, 0.3, 1)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    local tex = bar:GetStatusBarTexture()
    local mask = bar:CreateMaskTexture()
    mask:SetTexture(DISC, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(bar)
    try("AddMaskTexture", tex.AddMaskTexture, tex, mask)
    try("SetRenderMode", bar.SetRenderMode, bar, Enum.StatusBarRenderMode.Radial)
    if setup then setup(tex) end

    if ring then
        local hole = bar:CreateTexture(nil, "OVERLAY")
        hole:SetTexture(WHITE)
        hole:SetVertexColor(0.05, 0.05, 0.05, 1)
        hole:SetPoint("CENTER")
        hole:SetSize(size * 0.72, size * 0.72)
        local holeMask = bar:CreateMaskTexture()
        holeMask:SetTexture(DISC, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        holeMask:SetAllPoints(hole)
        hole:AddMaskTexture(holeMask)
    end

    local text = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("BOTTOM")
    text:SetText(label)

    P.bars[#P.bars + 1] = bar
    return holder
end

-- A normal linear bar cut by a rounded-corner mask: the shape test.
local function ShapedLinearBar(parent)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetSize(220, 22)
    bar:SetStatusBarTexture(WHITE)
    bar:SetStatusBarColor(0.2, 0.85, 0.3, 1)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(WHITE)
    bg:SetVertexColor(0.15, 0.15, 0.15, 1)
    local mask = bar:CreateMaskTexture()
    mask:SetTexture(ROUNDED, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(bar)
    try("AddMaskTexture (linear)", bar:GetStatusBarTexture().AddMaskTexture, bar:GetStatusBarTexture(), mask)
    bg:AddMaskTexture(mask)
    P.bars[#P.bars + 1] = bar
    return bar
end

local function Build()
    local f = CreateFrame("Frame", "DandersFramesRingProbe", UIParent, "BackdropTemplate")
    f:SetSize(520, 260)
    f:SetPoint("CENTER", 0, 120)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if f.SetBackdrop then
        f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
        f:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
        f:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetText("Round bar probe (drag to move, /dfring to close)")

    P.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    P.status:SetPoint("BOTTOMLEFT", 10, 8)
    P.status:SetPoint("BOTTOMRIGHT", -10, 8)
    P.status:SetJustifyH("LEFT")
    P.frame = f

    if not radialSupported() then
        P.status:SetText("Radial API missing on this client: Enum.StatusBarRenderMode.Radial is nil.")
        return f
    end

    local x = 12
    local function place(holder)
        holder:SetPoint("TOPLEFT", x, -32)
        x = x + holder:GetWidth() + 14
    end
    place(RadialBar(f, 80, "Full disc", nil, false))
    place(RadialBar(f, 80, "Ring", nil, true))
    place(RadialBar(f, 80, "Half arc", function(tex)
        try("SetStartOffset", tex.SetRadialProgressBarStartOffset, tex, 0.25)
        try("SetEndOffset", tex.SetRadialProgressBarEndOffset, tex, 0.75)
    end, true))
    place(RadialBar(f, 80, "Feather", function(tex)
        try("SetFeather", tex.SetRadialProgressBarFeather, tex, 0.15)
    end, true))
    place(RadialBar(f, 80, "Reverse", function(tex)
        try("SetReverse", tex.SetRadialProgressBarReverse, tex, true)
    end, true))

    local linear = ShapedLinearBar(f)
    linear:SetPoint("TOPLEFT", 12, -150)
    local lt = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lt:SetPoint("LEFT", linear, "RIGHT", 10, 0)
    lt:SetText("Linear bar, rounded mask")
    return f
end

-- Feed the unit's real health straight in: no Lua maths on it, so this is the
-- same path a secret value takes in combat.
local function Feed()
    local unit = P.unit
    if not UnitExists(unit) then return end
    local cur, max = UnitHealth(unit), UnitHealthMax(unit)
    for _, bar in ipairs(P.bars) do
        try("SetMinMaxValues", bar.SetMinMaxValues, bar, 0, max)
        try("SetValue", bar.SetValue, bar, cur)
    end
    P.updates = P.updates + 1
    local secret = issecretvalue and issecretvalue(cur) and "yes" or "no"
    P.status:SetText(format("Unit %s | in combat: %s | health secret: %s | updates: %d | errors: %d%s",
        unit, InCombatLockdown() and "yes" or "no", secret, P.updates, P.errors,
        P.lastError and ("\nLast error: " .. P.lastError) or ""))
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, unit)
    if event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        if unit == P.unit then Feed() end
    else
        Feed()
    end
end)

local function Toggle(msg)
    local unit = msg and msg:match("^%s*(%S+)") or "player"
    if P.frame and P.frame:IsShown() and unit == P.unit then
        P.frame:Hide()
        events:UnregisterAllEvents()
        return
    end
    P.unit = unit
    if not P.frame then Build() end
    P.frame:Show()
    if not radialSupported() then return end
    events:RegisterEvent("UNIT_HEALTH")
    events:RegisterEvent("UNIT_MAXHEALTH")
    events:RegisterEvent("PLAYER_TARGET_CHANGED")
    events:RegisterEvent("PLAYER_REGEN_DISABLED")
    events:RegisterEvent("PLAYER_REGEN_ENABLED")
    Feed()
end

SLASH_DANDERSFRAMESRINGPROBE1 = "/dfring"
SlashCmdList.DANDERSFRAMESRINGPROBE = Toggle
--@end-do-not-package@
