local addonName, NS = ...
local UI = NS.__DandersUI
if not UI then return end

-- ============================================================
-- COLOUR PICKER -- the shared swatch editor.
-- A square/wheel picker with hue, value and alpha bars, live RGBA and hex
-- readouts, a class palette and two persisted palettes (saved and recent).
-- Part of the load-on-demand options manifest: a consumer only needs it once a
-- settings panel is open and a swatch is clicked.
--
-- ONE frame for the whole pack. Like the popup dialog, the picker is a
-- singleton: a second OpenColorPicker while one is up takes the frame over
-- rather than stacking a second window. So every piece of picker state lives in
-- a file-scope local here, never on a host.
--
-- ☠ SHADOW HAZARD -- ALWAYS CALL THE *Native FACTORY NAMES FROM THIS FILE.
-- A consumer may define POSITIONAL CreateSlider / CreateDropdown /
-- CreateAnchorGrid / CreateCheckbox / CreateEditBox / CreateButton / CreateLabel
-- on its own HOST table, which shadows the pack's native factories for that
-- consumer only. A bare `self:CreateEditBox` call from library code would then
-- land on the consumer's positional shim, which reads argument 2 as a plain
-- string, so the opts table is silently mis-parsed and the widget comes back
-- wrong with no error. This file happens to call NONE of the seven -- it builds
-- its own EditBox/Button frames and hands them to StyleEditBox / StyleButton,
-- which nothing shadows -- but anything added later must go through the *Native
-- alias (host:CreateEditBoxNative(parent, {...})).
--
-- ☠ TWO of the surfaces used below live on the CONSUMER'S host, not in the pack:
-- RegisterScaledSurface (the picker is parented to UIParent, so it does not
-- inherit a consumer's panel scale and has to be registered for it) and
-- CreateSegmentToggle (the square/circle pill). Both are reached off the
-- captured host and both are guarded, so a consumer that supplies neither still
-- gets a working picker -- it just does not follow that consumer's UI scale, and
-- opens in whichever mode was last persisted with no pill to change it.
--
-- Canonical source lives at <repo>/DandersUI; never edit the copies under
-- */Libs/.
-- ============================================================

-- Shared palette. The one colour that stays local is the ground: the picker
-- floats OVER a settings window, so it deliberately sits between background
-- (0.08) and panel (0.12) to read as a layer above both. Not drift -- don't
-- "normalise" it.
local C_ELEMENT  = UI.Colors.element
local C_BORDER   = UI.Colors.border
local C_ACCENT   = UI.Colors.accent
local C_TEXT     = UI.Colors.text
local C_TEXT_DIM = UI.Colors.textDim
local C_BG = {r = 0.1, g = 0.1, b = 0.1}

-- Media resolves inside whichever addon carries the BASE copy of the pack.
local MEDIA = UI.MEDIA
local ICON_PATH = UI.MEDIA .. "Icons\\"

local CreateFrame, UIParent, CreateColor = CreateFrame, UIParent, CreateColor
local GetCursorPosition = GetCursorPosition
local ipairs, pairs, tonumber, type = ipairs, pairs, tonumber, type
local tinsert, tremove, wipe = table.insert, table.remove, wipe
local format = string.format
local math = math
-- ☠ RAW print, not UI:Print. These six lines are the picker's own chat
-- confirmations ("Color saved: #RRGGBB", "Color already saved", ...) and they
-- have always gone out unadorned. Routing them through the print hook would
-- stamp a consumer's chat prefix onto every one of them -- a visible change to
-- output that is not this file's to make.
local print = print

local testFrame = nil

-- Palettes. Both start as fresh locals and are REPLACED by the persisted arrays
-- when a store is available, so every mutation below lands in the consumer's
-- SavedVariables in place. With no store they stay these locals and the picker
-- simply remembers for the session.
local savedColors = {}
local recentColors = {}
local preferSquarePicker = true   -- true = square, false = wheel
local savedPosition = nil         -- session-only: where the user dragged it
local MAX_RECENT = 27  -- 3 rows of 9
local MAX_SAVED = 27   -- 3 rows of 9

-- Swatch layout constants
local SWATCH_SIZE = 30
local SWATCH_GAP = 2
local SWATCHES_PER_ROW = 9

-- Class colors. The swatch tooltip name is resolved from the CLIENT's own
-- localised class table rather than a locale key -- the game already ships
-- these in every language, so 13 keys per locale would be duplicated work that
-- could drift. `name` is the English fallback for the (never seen in practice)
-- case of a token the client doesn't know.
local CLASS_COLORS = {
    {token = "WARRIOR",     name = "Warrior",      r = 0.78, g = 0.61, b = 0.43},
    {token = "PALADIN",     name = "Paladin",      r = 0.96, g = 0.55, b = 0.73},
    {token = "HUNTER",      name = "Hunter",       r = 0.67, g = 0.83, b = 0.45},
    {token = "ROGUE",       name = "Rogue",        r = 1.00, g = 0.96, b = 0.41},
    {token = "PRIEST",      name = "Priest",       r = 1.00, g = 1.00, b = 1.00},
    {token = "DEATHKNIGHT", name = "Death Knight", r = 0.77, g = 0.12, b = 0.23},
    {token = "SHAMAN",      name = "Shaman",       r = 0.00, g = 0.44, b = 0.87},
    {token = "MAGE",        name = "Mage",         r = 0.41, g = 0.80, b = 0.94},
    {token = "WARLOCK",     name = "Warlock",      r = 0.58, g = 0.51, b = 0.79},
    {token = "MONK",        name = "Monk",         r = 0.00, g = 1.00, b = 0.59},
    {token = "DRUID",       name = "Druid",        r = 1.00, g = 0.49, b = 0.04},
    {token = "DEMONHUNTER", name = "Demon Hunter", r = 0.64, g = 0.19, b = 0.79},
    {token = "EVOKER",      name = "Evoker",       r = 0.20, g = 0.58, b = 0.50},
}

-- Localised class name for a swatch tooltip, from the client's table.
local function ClassDisplayName(class)
    local byToken = class.token and LOCALIZED_CLASS_NAMES_MALE
        and LOCALIZED_CLASS_NAMES_MALE[class.token]
    return byToken or class.name
end

-- ============================================================
-- PERSISTENCE
-- ------------------------------------------------------------
-- The pack has no SavedVariables of its own, so the two palettes and the
-- square/wheel preference live in a store the consumer supplies through the
-- `pickerStore` hook: a table with the fields `saved` (array), `recent` (array)
-- and `square` (boolean). A consumer that supplies none gets the file locals
-- above and the picker remembers nothing past a reload.
--
-- ☠ THE STORE IS FETCHED THROUGH THE HOST AT CALL TIME, NOT AT FILE LOAD. This
-- file loads with no host in scope -- hosts are created by the consumer, and a
-- load-time read would have nothing to read from. It is fetched once, on the
-- first OpenColorPicker, which is still before anything reads the palettes:
-- the frame is built inside that same call.
--
-- ☠ THIS DELIBERATELY DOES NOT WAIT FOR ADDON_LOADED. The options half is
-- load-on-demand, so by the time it runs the consumer that owns the
-- SavedVariables has long since loaded and that event will never fire again --
-- waiting would leave the palettes empty and the next save would overwrite the
-- user's swatches with nothing.
--
-- The arrays are taken BY REFERENCE, so every insert/remove below mutates the
-- stored table in place and the save is a re-assignment of the same object --
-- which is also what creates the key the first time a consumer's store has none.
local store = nil
local storeResolved = false

local function LoadPickerStore(host)
    if storeResolved then return end
    storeResolved = true
    local fn = host and host.Hook and host:Hook("pickerStore")
    store = fn and fn() or nil
    if not store then return end
    if store.saved then savedColors = store.saved end
    if store.recent then recentColors = store.recent end
    if store.square ~= nil then preferSquarePicker = store.square end
end

local function SavePickerStore()
    if not store then return end
    store.saved  = savedColors
    store.recent = recentColors
    store.square = preferSquarePicker
end

-- Helper to create a unique color key
local function ColorKey(r, g, b, a)
    return format("%.2f,%.2f,%.2f,%.2f", r, g, b, a or 1)
end

-- ============================================================
-- HSV <-> RGB Conversion
-- ============================================================

local function HSVtoRGB(h, s, v)
    if s == 0 then return v, v, v end
    h = h / 60
    local i = math.floor(h)
    local f = h - i
    local p = v * (1 - s)
    local q = v * (1 - s * f)
    local t = v * (1 - s * (1 - f))
    i = i % 6
    if i == 0 then return v, t, p
    elseif i == 1 then return q, v, p
    elseif i == 2 then return p, v, t
    elseif i == 3 then return p, q, v
    elseif i == 4 then return t, p, v
    else return v, p, q end
end

local function RGBtoHSV(r, g, b)
    local max = math.max(r, g, b)
    local min = math.min(r, g, b)
    local h, s, v = 0, 0, max
    local d = max - min
    if max ~= 0 then s = d / max end
    if max ~= min then
        if max == r then
            h = (g - b) / d
            if g < b then h = h + 6 end
        elseif max == g then
            h = (b - r) / d + 2
        else
            h = (r - g) / d + 4
        end
        h = h * 60
    end
    return h, s, v
end

local function RGBtoHex(r, g, b, a)
    if a then
        return format("#%02X%02X%02X%02X",
            math.floor(r * 255 + 0.5),
            math.floor(g * 255 + 0.5),
            math.floor(b * 255 + 0.5),
            math.floor(a * 255 + 0.5))
    else
        return format("#%02X%02X%02X",
            math.floor(r * 255 + 0.5),
            math.floor(g * 255 + 0.5),
            math.floor(b * 255 + 0.5))
    end
end

local function HexToRGB(hex)
    hex = hex:gsub("#", "")
    if #hex == 8 then  -- RRGGBBAA
        local r = tonumber(hex:sub(1, 2), 16) / 255
        local g = tonumber(hex:sub(3, 4), 16) / 255
        local b = tonumber(hex:sub(5, 6), 16) / 255
        local a = tonumber(hex:sub(7, 8), 16) / 255
        return r or 1, g or 1, b or 1, a or 1
    elseif #hex == 6 then  -- RRGGBB
        local r = tonumber(hex:sub(1, 2), 16) / 255
        local g = tonumber(hex:sub(3, 4), 16) / 255
        local b = tonumber(hex:sub(5, 6), 16) / 255
        return r or 1, g or 1, b or 1, nil
    end
    return 1, 1, 1, nil
end

-- ============================================================
-- Color Picker Frame
-- ============================================================

-- ☠ `host` is CAPTURED as an upvalue, not read off `self` later. Every closure
-- below is installed on a FRAME (the button handlers, the swatch refreshers,
-- testFrame's own methods), and those take the frame as their own `self`.
local function CreateColorPickerFrame(host, hasAlpha)
    if testFrame then
        testFrame.hasAlpha = hasAlpha
        testFrame:UpdateAlphaVisibility()
        if testFrame.RefreshSavedSwatches then
            testFrame.RefreshSavedSwatches()
        end
        testFrame:Show()
        return
    end

    local L = host.hooks.L

    hasAlpha = hasAlpha ~= false  -- Default to true for testing

    -- Current color state
    local currentHue = 0
    local currentSat = 1
    local currentVal = 1
    local currentAlpha = 1
    local activeTab = "saved"
    local useSquarePicker = preferSquarePicker
    local isUpdatingInputs = false  -- Prevent recursive updates

    -- Main frame
    -- ⚠ THE GLOBAL NAME IS LOAD-BEARING. "DFColorPickerTest" is registered in
    -- UISpecialFrames (that is what makes Escape close the picker) and is the
    -- name anything outside the pack knows this frame by. It is also a MISNOMER
    -- -- "Test" is historical; this is the real picker every swatch opens, and
    -- the name once got it skipped as a debug surface in a scale sweep, so it
    -- kept rendering at 100% over a scaled panel. Don't trust it, and don't
    -- rename it.
    testFrame = CreateFrame("Frame", "DFColorPickerTest", UIParent, "BackdropTemplate")
    -- Parented to UIParent, so it does not inherit a consumer's panel scale --
    -- register it if the consumer keeps a scaled-surface list.
    if host.RegisterScaledSurface then host:RegisterScaledSurface(testFrame) end
    testFrame:SetSize(320, 450)
    host:CreateElementBackdrop(testFrame, {
        bgColor     = { C_BG.r, C_BG.g, C_BG.b, 1 },
        borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, 1 },
    })
    testFrame:SetMovable(true)
    testFrame:EnableMouse(true)
    testFrame:SetFrameStrata("FULLSCREEN_DIALOG")  -- High strata but below TOOLTIP so GameTooltip shows above
    testFrame:SetFrameLevel(500)
    testFrame:SetToplevel(true)
    testFrame.hasAlpha = hasAlpha

    -- Position using saved location, or center on screen if first open
    local function UpdatePosition()
        testFrame:ClearAllPoints()
        if savedPosition then
            -- Use saved position from previous open
            testFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", savedPosition.x, savedPosition.y)
        else
            -- First open this session - center on screen
            testFrame:SetPoint("CENTER")
        end
    end

    -- Save current position
    local function SavePosition()
        local left = testFrame:GetLeft()
        local bottom = testFrame:GetBottom()
        local width = testFrame:GetWidth()
        local height = testFrame:GetHeight()
        if left and bottom and width and height then
            savedPosition = {
                x = left + width / 2,
                y = bottom + height / 2
            }
        end
    end

    testFrame.UpdatePosition = UpdatePosition
    testFrame.SavePosition = SavePosition
    UpdatePosition()

    -- Make Escape key close the picker (and treat as cancel)
    tinsert(UISpecialFrames, "DFColorPickerTest")

    -- Track if we're closing via apply (vs cancel/escape)
    testFrame.appliedColor = false

    -- OnHide handler - treat as cancel if not applied
    testFrame:SetScript("OnHide", function(self)
        if not self.appliedColor then
            -- Closing via Escape or other means - treat as cancel
            if self.onCancelCallback then
                self.onCancelCallback()
            end
        end
        self.appliedColor = false
        self.skipOnChange = false
        self:ClearCallbacks()
    end)

    -- Header
    local header = CreateFrame("Frame", nil, testFrame)
    header:SetHeight(28)
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", 0, 0)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() testFrame:StartMoving() end)
    header:SetScript("OnDragStop", function()
        testFrame:StopMovingOrSizing()
        SavePosition()
    end)

    -- ☠ The title text comes from the consumer, through the `pickerTitle` hook
    -- (a string, or a function returning one). The pack must not name whoever
    -- embeds it, and it has no locale key of its own to fall back on -- so with
    -- no hook the title is simply left blank rather than invented.
    local title = header:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    title:SetPoint("LEFT", 10, 0)
    local titleHook = host:Hook("pickerTitle")
    local titleText = type(titleHook) == "function" and titleHook() or titleHook
    if type(titleText) == "string" then title:SetText(titleText) end
    title:SetTextColor(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b)

    -- OnHide treats a close as cancel.
    local closeBtn = host:CreateCloseButton(header, { onClick = function() testFrame:Hide() end })
    closeBtn:SetPoint("RIGHT", -4, 0)

    -- Square/Circle picker mode. Transient UI state (a local, persisted through
    -- SavePickerStore) rather than a settings key, so it drives the shared
    -- segment toggle through customGet/customSet. Forward-declared here because
    -- it anchors to closeBtn but can only be built once UpdatePickerMode exists,
    -- further down.
    local pillContainer

    -- Content area
    local content = CreateFrame("Frame", nil, testFrame)
    content:SetPoint("TOPLEFT", 10, -38)
    content:SetPoint("BOTTOMRIGHT", -10, 45)

    local squareSize = 160
    local hueBarWidth = 20
    local alphaBarWidth = 20

    -- ============================================================
    -- Square Picker Container
    -- ============================================================

    local squareContainer = CreateFrame("Frame", nil, content)
    squareContainer:SetSize(290, 170)
    squareContainer:SetPoint("TOPLEFT", 0, 0)

    -- Color Square (Saturation/Value)
    local squareFrame = CreateFrame("Frame", nil, squareContainer, "BackdropTemplate")
    squareFrame:SetSize(squareSize, squareSize)
    squareFrame:SetPoint("TOPLEFT", 0, 0)
    host:CreateElementBackdrop(squareFrame, {
        fill = false,
        borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, 1 },
    })

    local hueLayer = squareFrame:CreateTexture(nil, "BACKGROUND")
    hueLayer:SetAllPoints()
    hueLayer:SetColorTexture(1, 1, 1, 1)

    local blackLayer = squareFrame:CreateTexture(nil, "ARTWORK")
    blackLayer:SetAllPoints()
    blackLayer:SetColorTexture(1, 1, 1, 1)
    blackLayer:SetGradient("VERTICAL", CreateColor(0, 0, 0, 1), CreateColor(0, 0, 0, 0))

    local picker = squareFrame:CreateTexture(nil, "OVERLAY")
    picker:SetSize(14, 14)
    picker:SetTexture("Interface\\Buttons\\UI-ColorPicker-Buttons")
    picker:SetTexCoord(0, 0.15625, 0, 0.625)

    -- Hue Bar
    local hueBar = CreateFrame("Frame", nil, squareContainer, "BackdropTemplate")
    hueBar:SetSize(hueBarWidth, squareSize)
    hueBar:SetPoint("LEFT", squareFrame, "RIGHT", 8, 0)
    host:CreateElementBackdrop(hueBar, {
        fill = false,
        borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, 1 },
    })

    local hueColors = {{1,0,0}, {1,1,0}, {0,1,0}, {0,1,1}, {0,0,1}, {1,0,1}, {1,0,0}}
    local numSegments = 6
    local segmentHeight = squareSize / numSegments
    for i = 1, numSegments do
        local segment = hueBar:CreateTexture(nil, "BACKGROUND")
        segment:SetSize(hueBarWidth, segmentHeight)
        segment:SetPoint("TOPLEFT", 0, -((i-1) * segmentHeight))
        segment:SetColorTexture(1, 1, 1, 1)
        local c1, c2 = hueColors[i], hueColors[i + 1]
        segment:SetGradient("VERTICAL", CreateColor(c2[1], c2[2], c2[3], 1), CreateColor(c1[1], c1[2], c1[3], 1))
    end

    local hueIndicator = hueBar:CreateTexture(nil, "OVERLAY", nil, 2)
    hueIndicator:SetSize(hueBarWidth + 4, 6)
    hueIndicator:SetColorTexture(1, 1, 1, 1)

    local hueIndicatorBorder = hueBar:CreateTexture(nil, "OVERLAY", nil, 1)
    hueIndicatorBorder:SetSize(hueBarWidth + 6, 8)
    hueIndicatorBorder:SetColorTexture(0, 0, 0, 1)

    -- Alpha Bar
    local alphaBar = CreateFrame("Frame", nil, squareContainer, "BackdropTemplate")
    alphaBar:SetSize(alphaBarWidth, squareSize)
    alphaBar:SetPoint("LEFT", hueBar, "RIGHT", 8, 0)
    host:CreateElementBackdrop(alphaBar, {
        fill = false,
        borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, 1 },
    })

    -- Checkerboard background for alpha (inset by 1 to match gradient)
    local checkerSize = 8
    local checkerWidth = alphaBarWidth - 2
    local checkerHeight = squareSize - 2
    for row = 0, math.ceil(checkerHeight / checkerSize) - 1 do
        for col = 0, math.ceil(checkerWidth / checkerSize) - 1 do
            local checker = alphaBar:CreateTexture(nil, "BACKGROUND")
            local w = math.min(checkerSize, checkerWidth - col * checkerSize)
            local h = math.min(checkerSize, checkerHeight - row * checkerSize)
            checker:SetSize(w, h)
            checker:SetPoint("TOPLEFT", 1 + col * checkerSize, -1 - row * checkerSize)
            local isLight = (row + col) % 2 == 0
            checker:SetColorTexture(isLight and 0.4 or 0.2, isLight and 0.4 or 0.2, isLight and 0.4 or 0.2, 1)
        end
    end

    local alphaGradient = alphaBar:CreateTexture(nil, "ARTWORK")
    alphaGradient:SetPoint("TOPLEFT", 1, -1)
    alphaGradient:SetPoint("BOTTOMRIGHT", -1, 1)
    alphaGradient:SetColorTexture(1, 1, 1, 1)

    local alphaIndicator = alphaBar:CreateTexture(nil, "OVERLAY", nil, 2)
    alphaIndicator:SetSize(alphaBarWidth + 4, 6)
    alphaIndicator:SetColorTexture(1, 1, 1, 1)

    local alphaIndicatorBorder = alphaBar:CreateTexture(nil, "OVERLAY", nil, 1)
    alphaIndicatorBorder:SetSize(alphaBarWidth + 6, 8)
    alphaIndicatorBorder:SetColorTexture(0, 0, 0, 1)

    -- ============================================================
    -- Circle Picker Container (Custom implementation for full edge access)
    -- ============================================================

    local circleContainer = CreateFrame("Frame", nil, content)
    circleContainer:SetSize(290, 170)
    circleContainer:SetPoint("TOPLEFT", 0, 0)
    circleContainer:Hide()

    -- Custom wheel frame (not using ColorSelect for better control)
    local wheelFrame = CreateFrame("Frame", nil, circleContainer)
    wheelFrame:SetSize(squareSize, squareSize)
    wheelFrame:SetPoint("TOPLEFT", 0, 0)

    local wheelTexture = wheelFrame:CreateTexture(nil, "ARTWORK")
    wheelTexture:SetTexture(MEDIA .. "DF_ColorWheel")
    wheelTexture:SetAllPoints()
    wheelTexture:SetTexelSnappingBias(0)
    wheelTexture:SetSnapToPixelGrid(false)

    -- Wheel thumb indicator
    -- Create wheel selector using custom ring texture
    local wheelThumbSize = 16
    local wheelThumb = CreateFrame("Frame", nil, wheelFrame)
    wheelThumb:SetSize(wheelThumbSize, wheelThumbSize)
    wheelThumb:SetFrameLevel(wheelFrame:GetFrameLevel() + 5)

    -- Ring texture
    local thumbRing = wheelThumb:CreateTexture(nil, "OVERLAY", nil, 2)
    thumbRing:SetTexture(MEDIA .. "DF_Ring")
    thumbRing:SetAllPoints()

    -- Custom Value bar for circle picker (no checkerboard - just gradient)
    local circleValueBar = CreateFrame("Frame", nil, circleContainer, "BackdropTemplate")
    circleValueBar:SetSize(hueBarWidth, squareSize)
    circleValueBar:SetPoint("TOPLEFT", squareSize + 8, 0)
    host:CreateElementBackdrop(circleValueBar, {
        fill = false,
        borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, 1 },
    })

    local circleValueGradient = circleValueBar:CreateTexture(nil, "BACKGROUND")
    circleValueGradient:SetPoint("TOPLEFT", 1, -1)
    circleValueGradient:SetPoint("BOTTOMRIGHT", -1, 1)
    circleValueGradient:SetColorTexture(1, 1, 1, 1)

    local circleValueIndicator = circleValueBar:CreateTexture(nil, "OVERLAY", nil, 2)
    circleValueIndicator:SetSize(hueBarWidth + 4, 6)
    circleValueIndicator:SetColorTexture(1, 1, 1, 1)

    local circleValueIndicatorBorder = circleValueBar:CreateTexture(nil, "OVERLAY", nil, 1)
    circleValueIndicatorBorder:SetSize(hueBarWidth + 6, 8)
    circleValueIndicatorBorder:SetColorTexture(0, 0, 0, 1)

    -- Alpha bar for circle picker
    local circleAlphaBar = CreateFrame("Frame", nil, circleContainer, "BackdropTemplate")
    circleAlphaBar:SetSize(alphaBarWidth, squareSize)
    circleAlphaBar:SetPoint("LEFT", circleValueBar, "RIGHT", 8, 0)
    host:CreateElementBackdrop(circleAlphaBar, {
        fill = false,
        borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, 1 },
    })

    -- Checkerboard for circle alpha (inset by 1 to match gradient)
    for row = 0, math.ceil(checkerHeight / checkerSize) - 1 do
        for col = 0, math.ceil(checkerWidth / checkerSize) - 1 do
            local checker = circleAlphaBar:CreateTexture(nil, "BACKGROUND")
            local w = math.min(checkerSize, checkerWidth - col * checkerSize)
            local h = math.min(checkerSize, checkerHeight - row * checkerSize)
            checker:SetSize(w, h)
            checker:SetPoint("TOPLEFT", 1 + col * checkerSize, -1 - row * checkerSize)
            local isLight = (row + col) % 2 == 0
            checker:SetColorTexture(isLight and 0.4 or 0.2, isLight and 0.4 or 0.2, isLight and 0.4 or 0.2, 1)
        end
    end

    local circleAlphaGradient = circleAlphaBar:CreateTexture(nil, "ARTWORK")
    circleAlphaGradient:SetPoint("TOPLEFT", 1, -1)
    circleAlphaGradient:SetPoint("BOTTOMRIGHT", -1, 1)
    circleAlphaGradient:SetColorTexture(1, 1, 1, 1)

    local circleAlphaIndicator = circleAlphaBar:CreateTexture(nil, "OVERLAY", nil, 2)
    circleAlphaIndicator:SetSize(alphaBarWidth + 4, 6)
    circleAlphaIndicator:SetColorTexture(1, 1, 1, 1)

    local circleAlphaIndicatorBorder = circleAlphaBar:CreateTexture(nil, "OVERLAY", nil, 1)
    circleAlphaIndicatorBorder:SetSize(alphaBarWidth + 6, 8)
    circleAlphaIndicatorBorder:SetColorTexture(0, 0, 0, 1)

    -- ============================================================
    -- Preview Swatch
    -- ============================================================

    local previewFrame = CreateFrame("Frame", nil, content, "BackdropTemplate")
    previewFrame:SetSize(55, 55)
    previewFrame:SetPoint("TOPLEFT", squareContainer, "TOPRIGHT", -50, 0)
    host:CreateElementBackdrop(previewFrame, {
        fill = false,
        borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, 1 },
    })

    -- Checkerboard behind preview for alpha (inset by 1 for border)
    local previewInner = 53  -- 55 - 2 for border
    for row = 0, math.ceil(previewInner / 8) - 1 do
        for col = 0, math.ceil(previewInner / 8) - 1 do
            local checker = previewFrame:CreateTexture(nil, "BACKGROUND")
            local w = math.min(8, previewInner - col * 8)
            local h = math.min(8, previewInner - row * 8)
            checker:SetSize(w, h)
            checker:SetPoint("TOPLEFT", 1 + col * 8, -1 - row * 8)
            local isLight = (row + col) % 2 == 0
            checker:SetColorTexture(isLight and 0.4 or 0.2, isLight and 0.4 or 0.2, isLight and 0.4 or 0.2, 1)
        end
    end

    local previewTexture = previewFrame:CreateTexture(nil, "ARTWORK")
    previewTexture:SetPoint("TOPLEFT", 1, -1)
    previewTexture:SetPoint("BOTTOMRIGHT", -1, 1)

    -- ============================================================
    -- RGBA Editable Inputs
    -- ============================================================

    local inputFrame = CreateFrame("Frame", nil, content)
    inputFrame:SetSize(290, 24)
    inputFrame:SetPoint("TOPLEFT", squareContainer, "BOTTOMLEFT", 0, -8)

    local function CreateRGBAInput(parent, label, color, xOffset, width)
        local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        container:SetSize(width, 22)
        container:SetPoint("LEFT", xOffset, 0)
        host:CreateElementBackdrop(container, {
            outline = false,
            bgColor     = { C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1 },
        })

        local lbl = container:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        lbl:SetPoint("LEFT", 4, 0)
        lbl:SetText(label)
        lbl:SetTextColor(color.r, color.g, color.b)

        local editBox = CreateFrame("EditBox", nil, container)
        editBox:SetSize(width - 22, 18)
        editBox:SetPoint("LEFT", lbl, "RIGHT", 2, 0)
        editBox:SetFontObject("DFFontNormalSmall")
        editBox:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        editBox:SetAutoFocus(false)
        editBox:SetNumeric(true)
        editBox:SetMaxLetters(3)
        editBox:SetJustifyH("LEFT")

        editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

        return editBox
    end

    local rInput = CreateRGBAInput(inputFrame, "R", {r=1, g=0.4, b=0.4}, 0, 60)
    local gInput = CreateRGBAInput(inputFrame, "G", {r=0.4, g=1, b=0.4}, 64, 60)
    local bInput = CreateRGBAInput(inputFrame, "B", {r=0.4, g=0.6, b=1}, 128, 60)
    local aInput = CreateRGBAInput(inputFrame, "A%", {r=0.8, g=0.8, b=0.8}, 192, 60)
    aInput:GetParent().alphaInput = true

    -- Hex input
    local hexFrame = CreateFrame("Frame", nil, content, "BackdropTemplate")
    hexFrame:SetSize(118, 22)  -- Wider to accommodate copy button
    hexFrame:SetPoint("TOPLEFT", inputFrame, "BOTTOMLEFT", 0, -4)
    host:CreateElementBackdrop(hexFrame, {
        outline = false,
        bgColor     = { C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1 },
    })

    local hexLabel = hexFrame:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    hexLabel:SetPoint("LEFT", 4, 0)
    hexLabel:SetText(L["Hex"])
    hexLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    local hexInput = CreateFrame("EditBox", nil, hexFrame)
    hexInput:SetSize(70, 18)
    hexInput:SetPoint("LEFT", hexLabel, "RIGHT", 4, 0)
    hexInput:SetFontObject("DFFontNormalSmall")
    hexInput:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    hexInput:SetAutoFocus(false)
    hexInput:SetMaxLetters(9)  -- #RRGGBBAA
    hexInput:SetJustifyH("LEFT")
    hexInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- Copy button
    local copyBtn = CreateFrame("Button", nil, hexFrame, "BackdropTemplate")
    copyBtn:SetPoint("LEFT", hexInput, "RIGHT", 2, 0)
    host:StyleButton(copyBtn, {
        width = 18, height = 18,
        icon = {
            texture = ICON_PATH .. "content_copy",
            size    = 12,
            color   = C_TEXT,
        },
    })

    -- Create a copy popup that appears within the color picker
    local copyPopup = CreateFrame("Frame", nil, testFrame, "BackdropTemplate")
    copyPopup:SetSize(180, 70)
    copyPopup:SetPoint("CENTER", testFrame, "CENTER", 0, 0)
    host:CreateElementBackdrop(copyPopup, {
        bgColor     = { C_BG.r, C_BG.g, C_BG.b, 1 },
        borderColor = { C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 1 },
    })
    copyPopup:SetFrameLevel(testFrame:GetFrameLevel() + 10)
    copyPopup:Hide()

    local copyPopupLabel = copyPopup:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    copyPopupLabel:SetPoint("TOP", 0, -8)
    copyPopupLabel:SetText(L["Press Ctrl+C to copy:"])
    copyPopupLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    local copyPopupEdit = CreateFrame("EditBox", nil, copyPopup, "BackdropTemplate")
    copyPopupEdit:SetSize(160, 22)
    copyPopupEdit:SetPoint("TOP", copyPopupLabel, "BOTTOM", 0, -6)
    -- skipFont: keeps this field's own centred DFFontNormalSmall (it displays a
    -- hex string to copy, not a normal input), but takes the shared input chrome.
    host:StyleEditBox(copyPopupEdit, { skipFont = true })
    copyPopupEdit:SetFontObject("DFFontNormalSmall")
    copyPopupEdit:SetTextColor(1, 1, 1)
    copyPopupEdit:SetAutoFocus(false)
    copyPopupEdit:SetJustifyH("CENTER")
    copyPopupEdit:SetScript("OnEscapePressed", function() copyPopup:Hide() end)
    copyPopupEdit:SetScript("OnEnterPressed", function() copyPopup:Hide() end)

    -- Hover accent (border + wash) is StyleButton's job now, so these buttons
    -- only carry their own click behaviour and tooltip.
    local copyPopupClose = CreateFrame("Button", nil, copyPopup, "BackdropTemplate")
    copyPopupClose:SetPoint("BOTTOM", 0, 6)
    host:StyleButton(copyPopupClose, { width = 50, height = 18, text = L["Close"], font = "DFFontNormalSmall" })
    copyPopupClose:SetScript("OnClick", function() copyPopup:Hide() end)

    copyBtn:HookScript("OnEnter", function(self)
        host:ShowTooltip(self, { title = L["Copy hex to clipboard"], anchor = "ANCHOR_RIGHT" })
    end)
    copyBtn:HookScript("OnLeave", function() host:HideTooltip() end)
    copyBtn:SetScript("OnClick", function()
        local hex = hexInput:GetText()
        if hex and hex ~= "" then
            copyPopupEdit:SetText(hex)
            copyPopup:Show()
            copyPopupEdit:SetFocus()
            copyPopupEdit:HighlightText()
        end
    end)

    -- ============================================================
    -- Update Functions
    -- ============================================================

    local function UpdateHueGradient()
        local r, g, b = HSVtoRGB(currentHue, 1, 1)
        hueLayer:SetGradient("HORIZONTAL", CreateColor(1, 1, 1, 1), CreateColor(r, g, b, 1))
    end

    local function UpdateAlphaGradient()
        local r, g, b = HSVtoRGB(currentHue, currentSat, currentVal)
        alphaGradient:SetGradient("VERTICAL", CreateColor(r, g, b, 0), CreateColor(r, g, b, 1))
        circleAlphaGradient:SetGradient("VERTICAL", CreateColor(r, g, b, 0), CreateColor(r, g, b, 1))
    end

    local function UpdatePickerPosition()
        local x = currentSat * squareSize
        local y = currentVal * squareSize
        picker:ClearAllPoints()
        picker:SetPoint("CENTER", squareFrame, "BOTTOMLEFT", x, y)
    end

    local function UpdateHueIndicator()
        local y = (currentHue / 360) * squareSize
        hueIndicator:ClearAllPoints()
        hueIndicator:SetPoint("CENTER", hueBar, "TOP", 0, -y)
        hueIndicatorBorder:ClearAllPoints()
        hueIndicatorBorder:SetPoint("CENTER", hueIndicator)
    end

    local function UpdateAlphaIndicator()
        local y = (1 - currentAlpha) * squareSize
        alphaIndicator:ClearAllPoints()
        alphaIndicator:SetPoint("CENTER", alphaBar, "TOP", 0, -y)
        alphaIndicatorBorder:ClearAllPoints()
        alphaIndicatorBorder:SetPoint("CENTER", alphaIndicator)

        circleAlphaIndicator:ClearAllPoints()
        circleAlphaIndicator:SetPoint("CENTER", circleAlphaBar, "TOP", 0, -y)
        circleAlphaIndicatorBorder:ClearAllPoints()
        circleAlphaIndicatorBorder:SetPoint("CENTER", circleAlphaIndicator)
    end

    local function UpdateCircleValueGradient()
        -- Create gradient from current hue/sat color to black
        local r, g, b = HSVtoRGB(currentHue, currentSat, 1)
        circleValueGradient:SetGradient("VERTICAL", CreateColor(0, 0, 0, 1), CreateColor(r, g, b, 1))
    end

    local function UpdateCircleValueIndicator()
        local y = (1 - currentVal) * squareSize
        circleValueIndicator:ClearAllPoints()
        circleValueIndicator:SetPoint("CENTER", circleValueBar, "TOP", 0, -y)
        circleValueIndicatorBorder:ClearAllPoints()
        circleValueIndicatorBorder:SetPoint("CENTER", circleValueIndicator)
    end

    local function UpdateWheelThumbPosition()
        -- Convert hue/sat to x,y position on wheel
        local radius = squareSize / 2
        local angle = (currentHue / 360) * 2 * math.pi - math.pi  -- -pi to pi
        local dist = currentSat * radius
        local x = radius + math.cos(angle) * dist
        local y = radius + math.sin(angle) * dist  -- Matches texture: y - center convention
        wheelThumb:ClearAllPoints()
        wheelThumb:SetPoint("CENTER", wheelFrame, "TOPLEFT", x, -y)
    end

    local function UpdateInputs()
        if isUpdatingInputs then return end
        isUpdatingInputs = true

        local r, g, b = HSVtoRGB(currentHue, currentSat, currentVal)
        rInput:SetText(math.floor(r * 255 + 0.5))
        gInput:SetText(math.floor(g * 255 + 0.5))
        bInput:SetText(math.floor(b * 255 + 0.5))
        aInput:SetText(math.floor(currentAlpha * 100 + 0.5))

        if testFrame.hasAlpha then
            hexInput:SetText(RGBtoHex(r, g, b, currentAlpha))
        else
            hexInput:SetText(RGBtoHex(r, g, b))
        end

        isUpdatingInputs = false
    end

    local function UpdateAllColors()
        local r, g, b = HSVtoRGB(currentHue, currentSat, currentVal)
        previewTexture:SetColorTexture(r, g, b, currentAlpha)

        UpdateHueGradient()
        UpdateAlphaGradient()
        UpdatePickerPosition()
        UpdateHueIndicator()
        UpdateAlphaIndicator()
        UpdateCircleValueGradient()
        UpdateCircleValueIndicator()
        UpdateWheelThumbPosition()
        UpdateInputs()

        -- Call live preview callback if set (but not during initialization)
        if testFrame.onChangeCallback and not testFrame.skipOnChange then
            testFrame.onChangeCallback({
                r = r,
                g = g,
                b = b,
                a = testFrame.hasAlpha and currentAlpha or 1
            })
        end
    end

    -- Initialize gradient
    UpdateHueGradient()

    -- ============================================================
    -- Input Handlers
    -- ============================================================

    local function OnRGBAInputChanged()
        if isUpdatingInputs then return end

        local r = (tonumber(rInput:GetText()) or 0) / 255
        local g = (tonumber(gInput:GetText()) or 0) / 255
        local b = (tonumber(bInput:GetText()) or 0) / 255
        local a = (tonumber(aInput:GetText()) or 100) / 100

        r = math.max(0, math.min(1, r))
        g = math.max(0, math.min(1, g))
        b = math.max(0, math.min(1, b))
        a = math.max(0, math.min(1, a))

        currentHue, currentSat, currentVal = RGBtoHSV(r, g, b)
        currentAlpha = a
        UpdateAllColors()
    end

    rInput:SetScript("OnEnterPressed", function(self) OnRGBAInputChanged(); self:ClearFocus() end)
    gInput:SetScript("OnEnterPressed", function(self) OnRGBAInputChanged(); self:ClearFocus() end)
    bInput:SetScript("OnEnterPressed", function(self) OnRGBAInputChanged(); self:ClearFocus() end)
    aInput:SetScript("OnEnterPressed", function(self) OnRGBAInputChanged(); self:ClearFocus() end)

    -- Live update as user types
    rInput:SetScript("OnTextChanged", function(self, userInput) if userInput then OnRGBAInputChanged() end end)
    gInput:SetScript("OnTextChanged", function(self, userInput) if userInput then OnRGBAInputChanged() end end)
    bInput:SetScript("OnTextChanged", function(self, userInput) if userInput then OnRGBAInputChanged() end end)
    aInput:SetScript("OnTextChanged", function(self, userInput) if userInput then OnRGBAInputChanged() end end)

    hexInput:SetScript("OnEnterPressed", function(self)
        if isUpdatingInputs then return end
        local hex = self:GetText()
        local r, g, b, a = HexToRGB(hex)
        currentHue, currentSat, currentVal = RGBtoHSV(r, g, b)
        if a and testFrame.hasAlpha then
            currentAlpha = a
        end
        UpdateAllColors()
        self:ClearFocus()
    end)

    -- Live update hex as user types
    hexInput:SetScript("OnTextChanged", function(self, userInput)
        if not userInput or isUpdatingInputs then return end
        local hex = self:GetText()
        -- Only update if it looks like a valid hex (starts with # and has enough chars)
        if hex:match("^#%x%x%x%x%x%x") then
            local r, g, b, a = HexToRGB(hex)
            if r and g and b then
                currentHue, currentSat, currentVal = RGBtoHSV(r, g, b)
                if a and testFrame.hasAlpha then
                    currentAlpha = a
                end
                UpdateAllColors()
            end
        end
    end)

    -- ============================================================
    -- Mouse Handlers
    -- ============================================================

    local isDraggingSquare, isDraggingHue, isDraggingAlpha, isDraggingCircleValue = false, false, false, false

    squareFrame:EnableMouse(true)
    squareFrame:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            isDraggingSquare = true
            local scale = self:GetEffectiveScale()
            local cursorX, cursorY = GetCursorPosition()
            cursorX, cursorY = cursorX / scale, cursorY / scale
            currentSat = math.max(0, math.min(1, (cursorX - self:GetLeft()) / squareSize))
            currentVal = math.max(0, math.min(1, (cursorY - self:GetBottom()) / squareSize))
            UpdateAllColors()
        end
    end)
    squareFrame:SetScript("OnMouseUp", function() isDraggingSquare = false end)
    squareFrame:SetScript("OnUpdate", function(self)
        if isDraggingSquare then
            local scale = self:GetEffectiveScale()
            local cursorX, cursorY = GetCursorPosition()
            cursorX, cursorY = cursorX / scale, cursorY / scale
            currentSat = math.max(0, math.min(1, (cursorX - self:GetLeft()) / squareSize))
            currentVal = math.max(0, math.min(1, (cursorY - self:GetBottom()) / squareSize))
            UpdateAllColors()
        end
    end)

    hueBar:EnableMouse(true)
    hueBar:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            isDraggingHue = true
            local scale = self:GetEffectiveScale()
            local _, cursorY = GetCursorPosition()
            cursorY = cursorY / scale
            currentHue = math.max(0, math.min(360, ((self:GetTop() - cursorY) / squareSize) * 360))
            UpdateAllColors()
        end
    end)
    hueBar:SetScript("OnMouseUp", function() isDraggingHue = false end)
    hueBar:SetScript("OnUpdate", function(self)
        if isDraggingHue then
            local scale = self:GetEffectiveScale()
            local _, cursorY = GetCursorPosition()
            cursorY = cursorY / scale
            currentHue = math.max(0, math.min(360, ((self:GetTop() - cursorY) / squareSize) * 360))
            UpdateAllColors()
        end
    end)

    -- Alpha bar handlers (for both square and circle mode)
    local function SetupAlphaBarHandlers(bar)
        bar:EnableMouse(true)
        bar:SetScript("OnMouseDown", function(self, button)
            if button == "LeftButton" then
                isDraggingAlpha = true
                local scale = self:GetEffectiveScale()
                local _, cursorY = GetCursorPosition()
                cursorY = cursorY / scale
                currentAlpha = math.max(0, math.min(1, 1 - ((self:GetTop() - cursorY) / squareSize)))
                UpdateAllColors()
            end
        end)
        bar:SetScript("OnMouseUp", function() isDraggingAlpha = false end)
        bar:SetScript("OnUpdate", function(self)
            if isDraggingAlpha then
                local scale = self:GetEffectiveScale()
                local _, cursorY = GetCursorPosition()
                cursorY = cursorY / scale
                currentAlpha = math.max(0, math.min(1, 1 - ((self:GetTop() - cursorY) / squareSize)))
                UpdateAllColors()
            end
        end)
    end

    SetupAlphaBarHandlers(alphaBar)
    SetupAlphaBarHandlers(circleAlphaBar)

    -- Circle value bar handlers
    circleValueBar:EnableMouse(true)
    circleValueBar:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            isDraggingCircleValue = true
            local scale = self:GetEffectiveScale()
            local _, cursorY = GetCursorPosition()
            cursorY = cursorY / scale
            currentVal = math.max(0, math.min(1, 1 - ((self:GetTop() - cursorY) / squareSize)))
            UpdateAllColors()
        end
    end)
    circleValueBar:SetScript("OnMouseUp", function() isDraggingCircleValue = false end)
    circleValueBar:SetScript("OnUpdate", function(self)
        if isDraggingCircleValue then
            local scale = self:GetEffectiveScale()
            local _, cursorY = GetCursorPosition()
            cursorY = cursorY / scale
            currentVal = math.max(0, math.min(1, 1 - ((self:GetTop() - cursorY) / squareSize)))
            UpdateAllColors()
        end
    end)

    -- Custom wheel handler (updates hue and saturation)
    local isDraggingWheel = false
    local wheelRadius = squareSize / 2

    local function UpdateWheelFromCursor(frame)
        local scale = frame:GetEffectiveScale()
        local cursorX, cursorY = GetCursorPosition()
        cursorX, cursorY = cursorX / scale, cursorY / scale

        local centerX = frame:GetLeft() + wheelRadius
        local centerY = frame:GetTop() - wheelRadius

        local dx = cursorX - centerX
        local dy = centerY - cursorY  -- Inverted: WoW Y is up, texture Y is down
        local dist = math.sqrt(dx*dx + dy*dy)

        -- Clamp to wheel radius
        if dist > wheelRadius then
            dx = dx * wheelRadius / dist
            dy = dy * wheelRadius / dist
            dist = wheelRadius
        end

        -- Calculate hue from angle
        local angle = math.atan2(dy, dx)
        currentHue = ((angle + math.pi) / (2 * math.pi)) * 360

        -- Calculate saturation from distance
        currentSat = dist / wheelRadius

        UpdateAllColors()
    end

    wheelFrame:EnableMouse(true)
    wheelFrame:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            isDraggingWheel = true
            UpdateWheelFromCursor(self)
        end
    end)
    wheelFrame:SetScript("OnMouseUp", function() isDraggingWheel = false end)
    wheelFrame:SetScript("OnUpdate", function(self)
        if isDraggingWheel then
            UpdateWheelFromCursor(self)
        end
    end)

    -- ============================================================
    -- Mode Toggle
    -- ============================================================

    -- Selection highlight + hover now belong to the segment toggle, so this only
    -- swaps which picker is on screen.
    local function UpdatePickerMode()
        if useSquarePicker then
            squareContainer:Show()
            circleContainer:Hide()
        else
            squareContainer:Hide()
            circleContainer:Show()
            UpdateWheelThumbPosition()
        end
        if pillContainer then pillContainer:Refresh() end
    end

    -- The Square/Circle pill (declared next to the close button it anchors to).
    -- Not settings-bound: useSquarePicker is a local and the preference is
    -- persisted through SavePickerStore, so it binds via customGet/customSet.
    -- The toggle is a CONSUMER-supplied surface -- guarded, and its absence just
    -- means the mode cannot be changed by hand.
    if host.CreateSegmentToggle then
        pillContainer = host:CreateSegmentToggle(header, {
            { value = "square", label = L["Square"] },
            { value = "circle", label = L["Circle"] },
        }, nil, nil, function()
            SavePickerStore()
            UpdatePickerMode()
            UpdateAllColors()
        end, {
            segmentWidth = 54,
            height       = 16,
            customGet    = function() return useSquarePicker and "square" or "circle" end,
            customSet    = function(value)
                useSquarePicker    = (value == "square")
                preferSquarePicker = useSquarePicker
            end,
        })
        pillContainer:SetPoint("RIGHT", closeBtn, "LEFT", -8, 0)
    end

    -- ============================================================
    -- Alpha Visibility
    -- ============================================================

    function testFrame:UpdateAlphaVisibility()
        local showAlpha = self.hasAlpha
        alphaBar:SetShown(showAlpha)
        circleAlphaBar:SetShown(showAlpha)
        aInput:GetParent():SetShown(showAlpha)

        -- Adjust preview position based on alpha visibility
        if showAlpha then
            previewFrame:SetPoint("TOPLEFT", squareContainer, "TOPRIGHT", -50, 0)
        else
            previewFrame:SetPoint("TOPLEFT", squareContainer, "TOPRIGHT", -78, 0)
        end
    end

    -- ============================================================
    -- Tabs
    -- ============================================================

    local tabFrame = CreateFrame("Frame", nil, content)
    tabFrame:SetSize(300, 42)
    tabFrame:SetPoint("TOPLEFT", hexFrame, "BOTTOMLEFT", 0, -8)

    local tabButtons = {}
    local tabContent = CreateFrame("Frame", nil, content)
    tabContent:SetSize(300, 96)  -- 3 rows of 30px swatches + 2px gaps
    tabContent:SetPoint("TOPLEFT", tabFrame, "BOTTOMLEFT", 0, -4)

    -- Shared underline-tab style: StyleButton{tab=true} owns the accent stripe,
    -- the bright/dim label and the hover wash, all driven by :SetActive().
    local function CreateTab(name, label, xOffset)
        local btn = CreateFrame("Button", nil, tabFrame, "BackdropTemplate")
        btn:SetPoint("LEFT", xOffset, 0)
        host:StyleButton(btn, {
            width = 55, height = 20,
            text = label, font = "DFFontNormalSmall",
            tab = true,
        })
        btn.name = name
        tabButtons[name] = btn
        return btn
    end

    CreateTab("saved", L["Saved"], 0)
    CreateTab("recent", L["Recent"], 60)
    CreateTab("class", L["Class"], 120)

    -- Save button in tab row (top-right)
    local saveBtn = CreateFrame("Button", nil, tabFrame, "BackdropTemplate")
    saveBtn:SetPoint("TOPRIGHT", 0, 0)
    host:StyleButton(saveBtn, { width = 50, height = 18, text = L["Save"], font = "DFFontNormalSmall" })

    -- Default button: stacked below Save, same width
    local defaultBtn = CreateFrame("Button", nil, tabFrame, "BackdropTemplate")
    defaultBtn:SetPoint("TOP", saveBtn, "BOTTOM", 0, -2)
    host:StyleButton(defaultBtn, { width = 50, height = 18, text = L["Default"], font = "DFFontNormalSmall" })
    defaultBtn:SetScript("OnClick", function()
        local d = testFrame.defaultColor
        if not d then return end
        -- SetColor triggers UpdateAllColors which fires onChangeCallback for live preview
        testFrame:SetColor(d.r, d.g, d.b, d.a or 1)
    end)
    defaultBtn:Hide()
    testFrame.defaultBtn = defaultBtn

    local classContent = CreateFrame("Frame", nil, tabContent)
    classContent:SetAllPoints()
    classContent:Hide()

    local savedContent = CreateFrame("Frame", nil, tabContent)
    savedContent:SetAllPoints()

    local recentContent = CreateFrame("Frame", nil, tabContent)
    recentContent:SetAllPoints()
    recentContent:Hide()

    -- Swatch tooltips route through the shared tooltip helpers. GameTooltip is
    -- TOOLTIP strata, above our FULLSCREEN_DIALOG, so it shows over the picker.
    local function HideTooltip()
        host:HideTooltip()
    end

    local function SelectColor(r, g, b)
        currentHue, currentSat, currentVal = RGBtoHSV(r, g, b)
        UpdateAllColors()
    end

    local function CreateColorSwatch(parent, index, r, g, b, tooltip)
        local row = math.floor((index - 1) / SWATCHES_PER_ROW)
        local col = (index - 1) % SWATCHES_PER_ROW

        local swatch = CreateFrame("Button", nil, parent, "BackdropTemplate")
        swatch:SetSize(SWATCH_SIZE, SWATCH_SIZE)
        swatch:SetPoint("TOPLEFT", col * (SWATCH_SIZE + SWATCH_GAP), -row * (SWATCH_SIZE + SWATCH_GAP))
        host:CreateElementBackdrop(swatch, {
            bgColor     = { r, g, b, 1 },
            borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, 1 },
        })

        swatch:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(1, 1, 1, 1)
            if tooltip then
                host:ShowTooltip(self, { title = tooltip })
            end
        end)
        swatch:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 1)
            HideTooltip()
        end)
        swatch:SetScript("OnClick", function() SelectColor(r, g, b) end)

        return swatch
    end

    for i, class in ipairs(CLASS_COLORS) do
        CreateColorSwatch(classContent, i, class.r, class.g, class.b, ClassDisplayName(class))
    end

    -- ============================================================
    -- Saved Colors Tab
    -- ============================================================

    local savedSwatches = {}
    local savedEmptyText = savedContent:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    savedEmptyText:SetPoint("CENTER", 0, 0)
    savedEmptyText:SetText(L["No saved colors yet"] .. "\n" .. L["Click 'Save' to add current color"])
    savedEmptyText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    savedEmptyText:SetJustifyH("CENTER")

    local function RefreshSavedSwatches()
        -- Clear existing swatches
        for _, swatch in ipairs(savedSwatches) do
            swatch:Hide()
            swatch:SetParent(nil)
        end
        wipe(savedSwatches)

        -- Show/hide empty text
        savedEmptyText:SetShown(#savedColors == 0)

        -- Create swatches for saved colors
        for i, color in ipairs(savedColors) do
            local row = math.floor((i - 1) / SWATCHES_PER_ROW)
            local col = (i - 1) % SWATCHES_PER_ROW

            local swatch = CreateFrame("Button", nil, savedContent, "BackdropTemplate")
            swatch:SetSize(SWATCH_SIZE, SWATCH_SIZE)
            swatch:SetPoint("TOPLEFT", col * (SWATCH_SIZE + SWATCH_GAP), -row * (SWATCH_SIZE + SWATCH_GAP))
            host:CreateElementBackdrop(swatch, {
                bgColor     = { color.r, color.g, color.b, 1 },
                borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, 1 },
            })
            swatch.colorIndex = i

            swatch:SetScript("OnEnter", function(self)
                self:SetBackdropBorderColor(1, 1, 1, 1)
                host:ShowTooltip(self, {
                    title = L["Left-click to select"],
                    lines = { L["Right-click to delete"] },
                })
            end)
            swatch:SetScript("OnLeave", function(self)
                self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 1)
                HideTooltip()
            end)
            swatch:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            swatch:SetScript("OnClick", function(self, button)
                if button == "LeftButton" then
                    SelectColor(color.r, color.g, color.b)
                    -- Only apply alpha if picker has alpha, otherwise force to 1
                    if testFrame.hasAlpha and color.a then
                        currentAlpha = color.a
                    else
                        currentAlpha = 1
                    end
                    UpdateAllColors()
                elseif button == "RightButton" then
                    -- Get hex code before removing
                    local deletedColor = savedColors[self.colorIndex]
                    local hexCode = RGBtoHex(deletedColor.r, deletedColor.g, deletedColor.b, deletedColor.a)

                    tremove(savedColors, self.colorIndex)
                    SavePickerStore()
                    RefreshSavedSwatches()

                    -- Print confirmation with hex code
                    print(format(L["Color deleted: %s"], "|cffffffff" .. hexCode .. "|r"))
                end
            end)

            tinsert(savedSwatches, swatch)
        end
    end

    -- Store on frame for reuse when reopening
    testFrame.RefreshSavedSwatches = RefreshSavedSwatches

    saveBtn:SetScript("OnClick", function()
        if #savedColors >= MAX_SAVED then
            print(format(L["Maximum saved colors reached (%d)"], MAX_SAVED))
            return
        end

        local r, g, b = HSVtoRGB(currentHue, currentSat, currentVal)
        local a = testFrame.hasAlpha and currentAlpha or nil
        local key = ColorKey(r, g, b, a or 1)

        -- Check if color already exists (compare without alpha for RGB-only pickers)
        for _, color in ipairs(savedColors) do
            if ColorKey(color.r, color.g, color.b, color.a or 1) == key then
                print(L["Color already saved"])
                return
            end
        end

        tinsert(savedColors, 1, {r = r, g = g, b = b, a = a})
        SavePickerStore()
        RefreshSavedSwatches()

        -- Switch to saved tab
        testFrame.SetActiveTab("saved")

        -- Print confirmation with hex code
        local hexCode = RGBtoHex(r, g, b, a)
        print(format(L["Color saved: %s"], "|cffffffff" .. hexCode .. "|r"))
    end)

    -- ============================================================
    -- Recent Colors Tab
    -- ============================================================

    local recentSwatches = {}
    local recentEmptyText = recentContent:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    recentEmptyText:SetPoint("CENTER", 0, 0)
    recentEmptyText:SetText(L["No recent colors yet"] .. "\n" .. L["Colors appear here when you apply them"])
    recentEmptyText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    recentEmptyText:SetJustifyH("CENTER")

    local function RefreshRecentSwatches()
        -- Clear existing swatches
        for _, swatch in ipairs(recentSwatches) do
            swatch:Hide()
            swatch:SetParent(nil)
        end
        wipe(recentSwatches)

        -- Show/hide empty text
        recentEmptyText:SetShown(#recentColors == 0)

        -- Create swatches for recent colors
        for i, color in ipairs(recentColors) do
            local row = math.floor((i - 1) / SWATCHES_PER_ROW)
            local col = (i - 1) % SWATCHES_PER_ROW

            local swatch = CreateFrame("Button", nil, recentContent, "BackdropTemplate")
            swatch:SetSize(SWATCH_SIZE, SWATCH_SIZE)
            swatch:SetPoint("TOPLEFT", col * (SWATCH_SIZE + SWATCH_GAP), -row * (SWATCH_SIZE + SWATCH_GAP))
            host:CreateElementBackdrop(swatch, {
                bgColor     = { color.r, color.g, color.b, 1 },
                borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, 1 },
            })
            swatch.colorData = color

            swatch:SetScript("OnEnter", function(self)
                self:SetBackdropBorderColor(1, 1, 1, 1)
                host:ShowTooltip(self, {
                    title = L["Left-click to select"],
                    lines = { L["Right-click to save"] },
                })
            end)
            swatch:SetScript("OnLeave", function(self)
                self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 1)
                HideTooltip()
            end)
            swatch:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            swatch:SetScript("OnClick", function(self, button)
                if button == "LeftButton" then
                    SelectColor(color.r, color.g, color.b)
                    -- Only apply alpha if picker has alpha, otherwise force to 1
                    if testFrame.hasAlpha and color.a then
                        currentAlpha = color.a
                    else
                        currentAlpha = 1
                    end
                    UpdateAllColors()
                elseif button == "RightButton" then
                    -- Save to saved colors
                    if #savedColors >= MAX_SAVED then
                        print(format(L["Maximum saved colors reached (%d)"], MAX_SAVED))
                        return
                    end

                    -- Only save alpha if picker has alpha
                    local a = testFrame.hasAlpha and color.a or nil
                    local key = ColorKey(color.r, color.g, color.b, a or 1)
                    for _, saved in ipairs(savedColors) do
                        if ColorKey(saved.r, saved.g, saved.b, saved.a or 1) == key then
                            print(L["Color already saved"])
                            return
                        end
                    end

                    tinsert(savedColors, 1, {r = color.r, g = color.g, b = color.b, a = a})
                    SavePickerStore()
                    RefreshSavedSwatches()

                    -- Switch to saved tab
                    testFrame.SetActiveTab("saved")

                    -- Print confirmation with hex code
                    local hexCode = RGBtoHex(color.r, color.g, color.b, a)
                    print(format(L["Color saved: %s"], "|cffffffff" .. hexCode .. "|r"))
                end
            end)

            tinsert(recentSwatches, swatch)
        end
    end

    -- Function to add color to recent (called on Apply and on open)
    local function AddToRecent(r, g, b, a)
        local key = ColorKey(r, g, b, a)

        -- Remove if already exists (will re-add at front)
        for i, color in ipairs(recentColors) do
            if ColorKey(color.r, color.g, color.b, color.a) == key then
                tremove(recentColors, i)
                break
            end
        end

        -- Add to front
        tinsert(recentColors, 1, {r = r, g = g, b = b, a = a})

        -- Trim to max (auto-delete oldest)
        while #recentColors > MAX_RECENT do
            tremove(recentColors)
        end

        -- Persist
        SavePickerStore()

        RefreshRecentSwatches()
    end

    -- Store on testFrame for external access
    testFrame.AddToRecent = AddToRecent

    local function UpdateTabs()
        for name, btn in pairs(tabButtons) do
            btn:SetActive(name == activeTab)   -- stripe + label state, both shared
        end
        classContent:SetShown(activeTab == "class")
        savedContent:SetShown(activeTab == "saved")
        recentContent:SetShown(activeTab == "recent")
    end

    -- Store on testFrame for access from earlier-defined handlers
    testFrame.UpdateTabs = UpdateTabs
    testFrame.SetActiveTab = function(tab)
        activeTab = tab
        UpdateTabs()
    end

    for name, btn in pairs(tabButtons) do
        btn:SetScript("OnClick", function()
            activeTab = name
            UpdateTabs()
        end)
    end

    -- ============================================================
    -- Footer
    -- ============================================================

    local footer = CreateFrame("Frame", nil, testFrame, "BackdropTemplate")
    footer:SetHeight(40)
    footer:SetPoint("BOTTOMLEFT", 0, 0)
    footer:SetPoint("BOTTOMRIGHT", 0, 0)
    host:CreateElementBackdrop(footer, {
        outline = false,
        bgColor     = { C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1 },
    })

    -- Apply button on the left (matches Blizzard's color picker layout)
    local applyBtn = CreateFrame("Button", nil, footer, "BackdropTemplate")
    applyBtn:SetPoint("RIGHT", footer, "CENTER", -5, 0)
    -- primary = the filled accent CTA this already was by hand.
    host:StyleButton(applyBtn, {
        width = 80, height = 26,
        text = L["Okay"], font = "DFFontNormalSmall",
        primary = true,
    })

    -- NOTE: both buttons had their OnClick set twice — the real handlers are
    -- installed further down, after the callback API exists, so the earlier pair
    -- was dead (SetScript replaces). The dead apply handler is removed here rather
    -- than left to look authoritative; its chat print went with it.

    -- Cancel button on the right (matches Blizzard's color picker layout)
    local cancelBtn = CreateFrame("Button", nil, footer, "BackdropTemplate")
    cancelBtn:SetPoint("LEFT", footer, "CENTER", 5, 0)
    host:StyleButton(cancelBtn, { width = 80, height = 26, text = L["Cancel"], font = "DFFontNormalSmall" })

    -- ============================================================
    -- API Methods
    -- ============================================================

    -- Set color from RGBA (0-1 range)
    function testFrame:SetColor(r, g, b, a)
        local h, s, v = RGBtoHSV(r, g, b)
        currentHue = h
        currentSat = s
        currentVal = v
        currentAlpha = a or 1
        UpdateAllColors()
    end

    -- Set callbacks
    function testFrame:SetCallbacks(onAccept, onCancel, onChange)
        self.onAcceptCallback = onAccept
        self.onCancelCallback = onCancel
        self.onChangeCallback = onChange
    end

    -- Clear callbacks
    function testFrame:ClearCallbacks()
        self.onAcceptCallback = nil
        self.onCancelCallback = nil
        self.onChangeCallback = nil
    end

    -- Update Apply button to use callback
    applyBtn:SetScript("OnClick", function()
        local r, g, b = HSVtoRGB(currentHue, currentSat, currentVal)

        -- Add to recent colors
        AddToRecent(r, g, b, testFrame.hasAlpha and currentAlpha or nil)

        -- Mark as applied so OnHide doesn't treat it as cancel
        testFrame.appliedColor = true

        -- Call callback if set
        if testFrame.onAcceptCallback then
            testFrame.onAcceptCallback({
                r = r,
                g = g,
                b = b,
                a = testFrame.hasAlpha and currentAlpha or 1
            })
        end

        testFrame:ClearCallbacks()
        testFrame:Hide()
    end)

    -- Update Cancel button to use callback
    cancelBtn:SetScript("OnClick", function()
        -- OnHide will call onCancelCallback
        testFrame:Hide()
    end)

    -- ============================================================
    -- Initialize
    -- ============================================================

    currentHue = 25
    currentSat = 0.8
    currentVal = 0.9
    currentAlpha = 1

    UpdatePickerMode()
    UpdateTabs()
    RefreshSavedSwatches()
    RefreshRecentSwatches()
    testFrame:UpdateAlphaVisibility()
    UpdateAllColors()

    testFrame:Show()
end

-- ============================================================
-- PUBLIC API
-- ============================================================

-- Open the colour picker with an initial colour, alpha support and callbacks.
-- @param initialColor: table with r, g, b, a (0-1 range)
-- @param hasAlpha: boolean - show the alpha bar
-- @param onAccept: function(newColor) - called with {r, g, b, a} on accept
-- @param onCancel: function() - called on cancel
-- @param onChange: function(newColor) - live preview on every change
-- @param defaultColor: table with r, g, b, a - shows the Default button
function UI:OpenColorPicker(initialColor, hasAlpha, onAccept, onCancel, onChange, defaultColor)
    -- Persisted palettes, resolved through this host on first use. Must run
    -- BEFORE the frame is built: the build reads the square/wheel preference and
    -- lays out both palettes.
    LoadPickerStore(self)

    -- Ensure the picker is created
    CreateColorPickerFrame(self, hasAlpha)

    -- If picker is already visible, hide it first without triggering cancel callback
    -- This prevents state leakage when quickly switching between color pickers
    if testFrame:IsShown() then
        testFrame.appliedColor = true  -- Prevent OnHide from calling old cancel callback
        testFrame:Hide()
    end

    -- Clear any previous callbacks to prevent state leakage
    testFrame:ClearCallbacks()
    testFrame.appliedColor = false
    testFrame.skipOnChange = false

    -- Store default colour and show/hide the Default button accordingly
    testFrame.defaultColor = defaultColor or nil
    if testFrame.defaultBtn then
        if defaultColor then
            testFrame.defaultBtn:Show()
        else
            testFrame.defaultBtn:Hide()
        end
    end

    -- Set new callbacks
    testFrame:SetCallbacks(onAccept, onCancel, onChange)

    -- Set initial color (skip onChange callback during initialization)
    if initialColor then
        testFrame.skipOnChange = true
        testFrame:SetColor(
            initialColor.r or 1,
            initialColor.g or 1,
            initialColor.b or 1,
            initialColor.a or 1
        )
        testFrame.skipOnChange = false

        -- Add initial color to recent colors
        if testFrame.AddToRecent then
            testFrame.AddToRecent(
                initialColor.r or 1,
                initialColor.g or 1,
                initialColor.b or 1,
                hasAlpha and (initialColor.a or 1) or nil
            )
        end
    end

    -- Set alpha mode
    testFrame.hasAlpha = hasAlpha
    testFrame:UpdateAlphaVisibility()

    -- Update position relative to the screen
    if testFrame.UpdatePosition then
        testFrame.UpdatePosition()
    end

    -- Show
    testFrame:Show()
end

-- The picker frame itself, or nil before the first open. Published for a
-- consumer that has to react to the picker being up or going away -- e.g. one
-- that drives the stock colour picker behind it and needs to put that back when
-- ours closes. Do NOT rebuild picker state through it; it is a handle, not an
-- extension point.
function UI:GetColorPickerFrame()
    return testFrame
end
