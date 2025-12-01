local addonName, DF = ...

-- ============================================================
-- FONTS & TEXTURES
-- ============================================================

-- Standard WoW Fonts
DF.SharedFonts = {
    ["Fonts\\FRIZQT__.TTF"] = "Friz Quadrata TT",
    ["Fonts\\ARIALN.TTF"] = "Arial Narrow",
    ["Fonts\\skurri.ttf"] = "Skurri",
    ["Fonts\\MORPHEUS.TTF"] = "Morpheus",
    [615968] = "2002",               -- FileID for 2002.TTF
    [615974] = "AR ZhongkaiGBK Medium", -- FileID for ARKai_T.ttf
}

-- This table will store only the fonts that pass the validation test
DF.ValidFonts = {}

-- Standard WoW Textures (Expanded List)
DF.SharedTextures = {
    -- Basic
    ["Interface\\TargetingFrame\\UI-StatusBar"] = "Blizzard",
    ["Interface\\Buttons\\WHITE8x8"] = "Flat",
    
    -- Raid & Unit Frames
    ["Interface\\RaidFrame\\Raid-Bar-Hp-Fill"] = "Raid",
    ["Interface\\RaidFrame\\Raid-Bar-Resource-Fill"] = "Raid Resource",
    ["Interface\\TargetingFrame\\UI-TargetingFrame-BarFill"] = "Targeting",
    ["Interface\\RaidFrame\\Shield-Overlay"] = "Shield Overlay", 
    
    -- Info Panels
    ["Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar"] = "Skills",
    ["Interface\\PaperDollInfoFrame\\UI-Character-Reputation-Bar"] = "Reputation",
    
    -- Misc UI
    ["Interface\\HelpFrame\\HelpFrame-Bar-Fill"] = "Smooth",
    ["Interface\\Archeology\\Arch-Progress-Fill"] = "Archeology",
    ["Interface\\GuildFrame\\GuildFrame-Progress"] = "Guild",
    ["Interface\\ChatFrame\\ChatFrameBackground"] = "Chat",
    
    -- Casting
    ["Interface\\CastingBar\\UI-CastingBar-Flash"] = "Cast Flash",
    
    -- Minimal
    ["Interface\\Tooltips\\UI-Tooltip-Background"] = "Tooltip",
    ["Interface\\WorldStateFrame\\ColumnIcon-FlagCapture2"] = "Glossy",

    -- SPECIAL PROCEDURAL TEXTURES
    ["DF_STRIPES"] = "Procedural Stripes",
    ["DF_STRIPES_FLIP"] = "Procedural Stripes (Flipped)",
    
    -- ADDON TEXTURES
    ["Interface\\AddOns\\DandersFrames\\DF_Stripes_Soft"] = "Soft Stripes",
    ["Interface\\AddOns\\DandersFrames\\DF_Stripes_Soft_Wide"] = "Soft Stripes (Wide)",
}

-- Helper to fetch all textures (Defaults + SharedMedia)
function DF:GetTextureList()
    local list = {}
    for k, v in pairs(DF.SharedTextures) do
        list[k] = v
    end
    
    local LSM = LibStub("LibSharedMedia-3.0", true)
    if LSM then
        local textures = LSM:HashTable("statusbar")
        if textures then
            for name, path in pairs(textures) do
                list[path] = name
            end
        end
    end
    return list
end

-- INTELLIGENT FONT VALIDATION
function DF:ValidateFonts()
    DF.ValidFonts = {}
    
    -- Create a hidden tester frame
    local tester = CreateFrame("Frame")
    tester:Hide()
    local fs = tester:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    
    -- Use a string with varied characters to ensure width differences
    local testString = "The quick brown fox jumps over the lazy dog 1234567890"
    fs:SetText(testString)
    
    -- 1. Establish Baseline (Friz Quadrata)
    fs:SetFont("Fonts\\FRIZQT__.TTF", 12, "NONE")
    local baselineWidth = fs:GetStringWidth()
    
    -- 2. Test Default List
    for path, name in pairs(DF.SharedFonts) do
        local isValid = false
        
        if name == "Friz Quadrata TT" then
            isValid = true
        else
            -- Try setting the font
            local success = pcall(function() fs:SetFont(path, 12, "NONE") end)
            
            if success then
                local width = fs:GetStringWidth()
                -- If width is significantly different from Friz, it's a real, unique font.
                -- If width is identical, it's likely the game falling back to Friz.
                if math.abs(width - baselineWidth) > 0.1 then
                    isValid = true
                end
            end
        end
        
        if isValid then
            DF.ValidFonts[path] = name
        elseif DF.debugEnabled then
            print("|cffeda55fDandersFrames:|r Excluding broken/fallback font: " .. name)
        end
    end
    
    -- 3. Add SharedMedia Fonts (Assume valid as they are externally registered)
    local LSM = LibStub("LibSharedMedia-3.0", true)
    if LSM then
        local fonts = LSM:HashTable("font")
        if fonts then
            for name, path in pairs(fonts) do
                DF.ValidFonts[path] = name
            end
        end
    end
end

-- Helper to fetch valid fonts only
function DF:GetFontList()
    -- Fallback if validation failed or hasn't run
    if not next(DF.ValidFonts) then return DF.SharedFonts end
    
    local list = {}
    for k, v in pairs(DF.ValidFonts) do
        list[k] = v
    end
    return list
end

-- ============================================================
-- DEFAULT SETTINGS
-- ============================================================

DF.PartyDefaults = {
    -- General
    soloMode = false,
    hidePartyTitle = false, 
    rangeFadeAlpha = 0.55, -- Default Blizzard Fade
    hideRangeIcon = false,
    
    -- Global Font Selector (Last selection)
    globalFont = "Fonts\\FRIZQT__.TTF",
    globalOutline = "OUTLINE",

    -- Frame Layout (replaces Edit Mode settings)
    enableFrameLayout = false,
    frameWidth = 72,
    frameHeight = 36,
    frameOpacity = 1.0,
    growCenter = false,
    
    -- Health Bar Layout
    framePadding = 3,
    useSpecificPadding = false,
    paddingTop = 3,
    paddingBottom = 3,
    paddingLeft = 3,
    paddingRight = 3,
    enableTextureColor = true,
    backgroundClassColor = false,
    textureColor = {r = 0.10196079313755, g = 0.10196079313755, b = 0.10196079313755, a = 0.30729147791862},
    
    -- Health Colors
    healthTexture = "Interface\\TargetingFrame\\UI-StatusBar", 
    healthOrientation = "HORIZONTAL", 
    healthColorMode = "CLASS",
    healthColorLow = {r = 1, g = 0, b = 0, a = 1},
    healthColorLowUseClass = false, 
    healthColorLowWeight = 1, 
    healthColorMedium = {r = 1, g = 1, b = 0, a = 1},
    healthColorMediumUseClass = false, 
    healthColorMediumWeight = 1, 
    healthColorHigh = {r = 0, g = 1, b = 0, a = 1},
    healthColorHighUseClass = false, 
    healthColorHighWeight = 1, 
    classColorAlpha = 1.0,
    healthColor = {r = 0, g = 1, b = 0, a = 1}, 

    -- Buffs
    raidBuffScale = 1,
    raidBuffAlpha = 1,
    raidBuffAnchor = "BOTTOMRIGHT",
    raidBuffGrowth = "LEFT_UP",
    raidBuffWrap = 3,
    raidBuffMax = 6,
    raidBuffOffsetX = -4,
    raidBuffOffsetY = 8,
    raidBuffClickThrough = false,
    raidBuffStackScale = 1.0,
    raidBuffStackFont = "Fonts\\FRIZQT__.TTF", 
    raidBuffStackAnchor = "BOTTOMRIGHT",
    raidBuffStackX = 0,
    raidBuffStackY = 0,
    raidBuffStackOutline = "OUTLINE",
    showAdvancedBuffOptions = false,
    raidBuffShowCountdown = false,
    raidBuffCountdownScale = 1.0,
    raidBuffCountdownFont = "Fonts\\FRIZQT__.TTF",
    raidBuffCountdownOutline = "OUTLINE",
    raidBuffCountdownX = 0,
    raidBuffCountdownY = 0,
    raidBuffHideSwipe = false,

    -- Debuffs
    raidDebuffScale = 1,
    raidDebuffAlpha = 1,
    raidDebuffAnchor = "BOTTOMLEFT",
    raidDebuffGrowth = "RIGHT_UP",
    raidDebuffWrap = 2,
    raidDebuffMax = 6,
    raidDebuffOffsetX = 4,
    raidDebuffOffsetY = 8,
    raidDebuffClickThrough = false,
    raidDebuffStackScale = 1.0,
    raidDebuffStackFont = "Fonts\\FRIZQT__.TTF", 
    raidDebuffStackAnchor = "BOTTOMRIGHT",
    raidDebuffStackX = 0,
    raidDebuffStackY = 0,
    raidDebuffStackOutline = "OUTLINE",
    showAdvancedDebuffOptions = false,
    raidDebuffShowCountdown = false,
    raidDebuffCountdownScale = 1.0,
    raidDebuffCountdownFont = "Fonts\\FRIZQT__.TTF",
    raidDebuffCountdownOutline = "OUTLINE",
    raidDebuffCountdownX = 0,
    raidDebuffCountdownY = 0,
    raidDebuffHideSwipe = false,
    
    -- Dispel Toggles
    showDispelIcon = true,
    showDispelOverlay = false, 
    showDispelBackground = true,
    showDispelBorder = true,
    showDispelGradient = true,
    dispelLevelOverlay = 3,
    dispelLevelIcon = 0,
    dispelLevelBackground = 0,
    dispelLevelBorder = 0,
    dispelLevelGradient = 0,

    -- Highlights (Aggro/Selection)
    selectionHighlightMode = "BLIZZARD",
    selectionHighlightThickness = 2,
    selectionHighlightInset = 0,
    selectionHighlightAlpha = 1.0,
    selectionHighlightColor = {r = 1, g = 1, b = 1, a = 1}, -- Default alpha 1, controlled by slider
    
    aggroHighlightMode = "BLIZZARD",
    aggroHighlightThickness = 2,
    aggroHighlightInset = 0,
    aggroHighlightAlpha = 1.0,

    -- Health Text
    healthTextHide = false,
    healthTextEnabled = true,
    healthTextFormat = "Percent",
    healthTextAbbreviate = false,
    healthTextScale = 1.4,
    healthTextFont = "Fonts\\FRIZQT__.TTF",
    healthTextOutline = "OUTLINE",
    healthTextAnchor = "CENTER",
    healthTextX = 0,
    healthTextY = 0,
    healthTextColor = {r = 1, g = 1, b = 1, a = 1},
    healthTextUseClassColor = false,
    showStatusText = true,

    -- Name Text
    nameTextHide = false,
    nameTextEnabled = true,
    nameTextShowRealm = false,
    nameTextLength = 0,
    nameTextTruncateMode = "ELLIPSIS", 
    nameTextWrapAlign = "CENTER",
    nameTextWrapDirection = "DOWN",
    nameTextFormat = "Current",
    nameTextScale = 1.1,
    nameTextFont = "Fonts\\FRIZQT__.TTF",
    nameTextOutline = "OUTLINE",
    nameTextAnchor = "TOP",
    nameTextX = 0,
    nameTextY = -13,
    nameTextColor = {r = 1, g = 1, b = 1, a = 1},
    nameTextUseClassColor = false,

    -- Icons
    leaderIconHide = false,
    leaderIconEnabled = true,
    leaderIconScale = 1.2,
    leaderIconAnchor = "TOPLEFT",
    leaderIconX = 0,
    leaderIconY = 4,

    roleIconHide = false,
    roleIconEnabled = true,
    roleIconScale = 1,
    roleIconAnchor = "TOPLEFT",
    roleIconX = 5,
    roleIconY = -5,

    raidIconHide = false,
    raidIconEnabled = true,
    raidIconScale = 1.8,
    raidIconAnchor = "TOP",
    raidIconX = -1,
    raidIconY = 2,

    readyCheckIconEnabled = false,
    readyCheckIconScale = 1,
    readyCheckIconAnchor = "CENTER",
    readyCheckIconX = 0,
    readyCheckIconY = 0,

    centerStatusIconEnabled = false,
    centerStatusIconScale = 1,
    centerStatusIconAnchor = "CENTER",
    centerStatusIconX = 0,
    centerStatusIconY = 0,

    -- Resource Bar
    resourceBarEnabled = true,
    resourceBarHealerOnly = true,
    resourceBarMatchWidth = true,
    resourceBarAnchor = "BOTTOM",
    resourceBarWidth = 50,
    resourceBarHeight = 4,
    resourceBarX = 0,
    resourceBarY = 4,
    resourceBarOrientation = "HORIZONTAL",
    resourceBarReverseFill = false,
    
    -- Absorb Bar
    absorbGlowAlpha = 1,
    absorbGlowAnchor = "RIGHT",
    absorbMatchHealthOrientation = true,
    absorbBarMode = "OVERLAY",
    absorbBarAnchor = "BOTTOM",
    absorbBarOrientation = "HORIZONTAL",
    absorbBarWidth = 50,
    absorbBarHeight = 6,
    absorbBarX = 0,
    absorbBarY = 0,
    absorbBarReverse = false,
    absorbBarMatchHealthOrientation = true,
    absorbBarTexture = "Interface\\AddOns\\DandersFrames\\DF_Stripes_Soft", 
    absorbBarColor = {r = 0, g = 0.835, b = 1, a = 0.7},
    absorbBarBackgroundColor = {r = 0, g = 0, b = 0, a = 0.5},
    absorbBarOverlayReverse = false,
    absorbBarStrata = "MEDIUM",
    
    -- Heal Absorb Bar (Necrotic)
    healAbsorbBarMode = "OVERLAY",
    healAbsorbBarAnchor = "BOTTOM",
    healAbsorbBarOrientation = "HORIZONTAL",
    healAbsorbBarWidth = 50,
    healAbsorbBarHeight = 6,
    healAbsorbBarX = 0,
    healAbsorbBarY = 0,
    healAbsorbBarReverse = false,
    healAbsorbBarTexture = "Interface\\AddOns\\DandersFrames\\DF_Stripes_Soft",
    healAbsorbBarColor = {r = 0.4, g = 0.1, b = 0.1, a = 0.7},
    healAbsorbBarBackgroundColor = {r = 0, g = 0, b = 0, a = 0.5},
    healAbsorbBarOverlayReverse = false,
    healAbsorbBarStrata = "MEDIUM",
}

DF.RaidDefaults = {
    -- General
    hideRaidGroupNumbers = false, 
    rangeFadeAlpha = 0.55, -- Default Blizzard Fade
    hideRangeIcon = false,
    
    -- Global Font Selector (Last selection)
    globalFont = "Fonts\\FRIZQT__.TTF",
    globalOutline = "OUTLINE",

    -- Frame Layout (replaces Edit Mode settings)
    enableFrameLayout = false,
    frameWidth = 72,
    frameHeight = 36,
    frameOpacity = 1.0,
    growCenter = false,
    
    -- Health Bar Layout
    framePadding = 3,
    useSpecificPadding = false,
    paddingTop = 3,
    paddingBottom = 3,
    paddingLeft = 3,
    paddingRight = 3,
    enableTextureColor = true,
    backgroundClassColor = false,
    textureColor = {r = 0.10196079313755, g = 0.10196079313755, b = 0.10196079313755, a = 0.30729147791862},

    -- Health Colors
    healthTexture = "Interface\\TargetingFrame\\UI-StatusBar", 
    healthOrientation = "HORIZONTAL", 
    healthColorMode = "CLASS",
    healthColorLow = {r = 1, g = 0, b = 0, a = 1},
    healthColorLowUseClass = false, 
    healthColorLowWeight = 1, 
    healthColorMedium = {r = 1, g = 1, b = 0, a = 1},
    healthColorMediumUseClass = false, 
    healthColorMediumWeight = 1, 
    healthColorHigh = {r = 0, g = 1, b = 0, a = 1},
    healthColorHighUseClass = false, 
    healthColorHighWeight = 1, 
    classColorAlpha = 1.0,
    healthColor = {r = 0, g = 1, b = 0, a = 1},

    -- Buffs
    raidBuffScale = 1,
    raidBuffAlpha = 1,
    raidBuffAnchor = "BOTTOMRIGHT",
    raidBuffGrowth = "LEFT_UP",
    raidBuffWrap = 3,
    raidBuffMax = 3,
    raidBuffOffsetX = -4,
    raidBuffOffsetY = 8,
    raidBuffClickThrough = false,
    raidBuffStackScale = 1.0,
    raidBuffStackFont = "Fonts\\FRIZQT__.TTF", 
    raidBuffStackAnchor = "BOTTOMRIGHT",
    raidBuffStackX = 0,
    raidBuffStackY = 0,
    raidBuffStackOutline = "OUTLINE",
    showAdvancedBuffOptions = false,
    raidBuffShowCountdown = false,
    raidBuffCountdownScale = 1.0,
    raidBuffCountdownFont = "Fonts\\FRIZQT__.TTF",
    raidBuffCountdownOutline = "OUTLINE",
    raidBuffCountdownX = 0,
    raidBuffCountdownY = 0,
    raidBuffHideSwipe = false,

    -- Debuffs
    raidDebuffScale = 1,
    raidDebuffAlpha = 1,
    raidDebuffAnchor = "BOTTOMLEFT",
    raidDebuffGrowth = "RIGHT_UP",
    raidDebuffWrap = 2,
    raidDebuffMax = 3,
    raidDebuffOffsetX = 4,
    raidDebuffOffsetY = 8,
    raidDebuffClickThrough = false,
    raidDebuffStackScale = 1.0,
    raidDebuffStackFont = "Fonts\\FRIZQT__.TTF", 
    raidDebuffStackAnchor = "BOTTOMRIGHT",
    raidDebuffStackX = 0,
    raidDebuffStackY = 0,
    raidDebuffStackOutline = "OUTLINE",
    showAdvancedDebuffOptions = false,
    raidDebuffShowCountdown = false,
    raidDebuffCountdownScale = 1.0,
    raidDebuffCountdownFont = "Fonts\\FRIZQT__.TTF",
    raidDebuffCountdownOutline = "OUTLINE",
    raidDebuffCountdownX = 0,
    raidDebuffCountdownY = 0,
    raidDebuffHideSwipe = false,
    
    -- Dispel Toggles
    showDispelIcon = true,
    showDispelOverlay = false, 
    showDispelBackground = true,
    showDispelBorder = true,
    showDispelGradient = true,
    dispelLevelOverlay = 3,
    dispelLevelIcon = 0,
    dispelLevelBackground = 0,
    dispelLevelBorder = 0,
    dispelLevelGradient = 0,

    -- Highlights (Aggro/Selection)
    selectionHighlightMode = "BLIZZARD",
    selectionHighlightThickness = 2,
    selectionHighlightInset = 0,
    selectionHighlightAlpha = 1.0,
    selectionHighlightColor = {r = 1, g = 1, b = 1, a = 1},
    
    aggroHighlightMode = "BLIZZARD",
    aggroHighlightThickness = 2,
    aggroHighlightInset = 0,
    aggroHighlightAlpha = 1.0,

    -- Health Text
    healthTextHide = true, 
    healthTextEnabled = true,
    healthTextFormat = "Percent",
    healthTextAbbreviate = false, 
    healthTextScale = 1.4,
    healthTextFont = "Fonts\\FRIZQT__.TTF",
    healthTextOutline = "OUTLINE",
    healthTextAnchor = "CENTER",
    healthTextX = 0,
    healthTextY = 0,
    healthTextColor = {r = 1, g = 1, b = 1, a = 1},
    healthTextUseClassColor = false,
    showStatusText = true,

    -- Name Text
    nameTextHide = false,
    nameTextEnabled = true,
    nameTextShowRealm = false,
    nameTextLength = 5, 
    nameTextTruncateMode = "ELLIPSIS", 
    nameTextWrapAlign = "CENTER",
    nameTextWrapDirection = "DOWN",
    nameTextFormat = "Current",
    nameTextScale = 1.1,
    nameTextFont = "Fonts\\FRIZQT__.TTF",
    nameTextOutline = "OUTLINE",
    nameTextAnchor = "CENTER", 
    nameTextX = 0,
    nameTextY = 0,
    nameTextColor = {r = 1, g = 1, b = 1, a = 1},
    nameTextUseClassColor = false,

    -- Icons
    leaderIconHide = false,
    leaderIconEnabled = true,
    leaderIconScale = 1.2,
    leaderIconAnchor = "TOPLEFT",
    leaderIconX = 0,
    leaderIconY = 4,

    roleIconHide = false,
    roleIconEnabled = true,
    roleIconScale = 1,
    roleIconAnchor = "TOPLEFT",
    roleIconX = 5,
    roleIconY = -5,

    raidIconHide = false,
    raidIconEnabled = true,
    raidIconScale = 1.8,
    raidIconAnchor = "TOP",
    raidIconX = -1,
    raidIconY = 2,

    readyCheckIconEnabled = false,
    readyCheckIconScale = 1,
    readyCheckIconAnchor = "CENTER",
    readyCheckIconX = 0,
    readyCheckIconY = 0,

    centerStatusIconEnabled = false,
    centerStatusIconScale = 1,
    centerStatusIconAnchor = "CENTER",
    centerStatusIconX = 0,
    centerStatusIconY = 0,

    -- Resource Bar
    resourceBarEnabled = true,
    resourceBarHealerOnly = true,
    resourceBarMatchWidth = true,
    resourceBarAnchor = "BOTTOM",
    resourceBarWidth = 50,
    resourceBarHeight = 4,
    resourceBarX = 0,
    resourceBarY = 4,
    resourceBarOrientation = "HORIZONTAL",
    resourceBarReverseFill = false,
    
    -- Absorb Bar
    absorbGlowAlpha = 1,
    absorbGlowAnchor = "RIGHT",
    absorbMatchHealthOrientation = true,
    absorbBarMode = "OVERLAY",
    absorbBarAnchor = "BOTTOM",
    absorbBarOrientation = "HORIZONTAL",
    absorbBarWidth = 50,
    absorbBarHeight = 6,
    absorbBarX = 0,
    absorbBarY = 0,
    absorbBarReverse = false,
    absorbBarMatchHealthOrientation = true,
    absorbBarTexture = "Interface\\AddOns\\DandersFrames\\DF_Stripes_Soft", 
    absorbBarColor = {r = 0, g = 0.835, b = 1, a = 0.7},
    absorbBarBackgroundColor = {r = 0, g = 0, b = 0, a = 0.5},
    absorbBarOverlayReverse = false,
    absorbBarStrata = "MEDIUM",
    
    -- Heal Absorb Bar (Necrotic)
    healAbsorbBarMode = "OVERLAY",
    healAbsorbBarAnchor = "BOTTOM",
    healAbsorbBarOrientation = "HORIZONTAL",
    healAbsorbBarWidth = 50,
    healAbsorbBarHeight = 6,
    healAbsorbBarX = 0,
    healAbsorbBarY = 0,
    healAbsorbBarReverse = false,
    healAbsorbBarTexture = "Interface\\AddOns\\DandersFrames\\DF_Stripes_Soft",
    healAbsorbBarColor = {r = 0.4, g = 0.1, b = 0.1, a = 0.7},
    healAbsorbBarBackgroundColor = {r = 0, g = 0, b = 0, a = 0.5},
    healAbsorbBarOverlayReverse = false,
    healAbsorbBarStrata = "MEDIUM",
}