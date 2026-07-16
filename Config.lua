local addonName, DF = ...

-- Expose as global for other files and external access
DandersFrames = DF

-- ============================================================
-- SHARED MEDIA SUPPORT
-- ============================================================

-- Helper function to get LibSharedMedia (fetched fresh each time to handle late-loading)
-- Cache the SharedMedia reference like MPlusTimer does
local LSM_Cached = nil
local function GetLSM()
    if not LSM_Cached then
        LSM_Cached = LibStub and LibStub("LibSharedMedia-3.0", true)
    end
    return LSM_Cached
end

-- Register our custom fonts and textures with SharedMedia
local function RegisterCustomMedia()
    local LSM = GetLSM()
    if not LSM then return end
    
    -- Register custom fonts (langmask covers all locales so fonts work on all clients)
    local ALL_LOCALES = LSM.LOCALE_BIT_western + LSM.LOCALE_BIT_koKR + LSM.LOCALE_BIT_ruRU + LSM.LOCALE_BIT_zhCN + LSM.LOCALE_BIT_zhTW
    LSM:Register(LSM.MediaType.FONT, "DF Expressway", "Interface\\AddOns\\DandersFrames\\Fonts\\Expressway.ttf", ALL_LOCALES)
    LSM:Register(LSM.MediaType.FONT, "DF Roboto SemiBold", "Interface\\AddOns\\DandersFrames\\Fonts\\Roboto-SemiBold.ttf", ALL_LOCALES)
    LSM:Register(LSM.MediaType.FONT, "DF Roboto Bold", "Interface\\AddOns\\DandersFrames\\Fonts\\Roboto-Bold.ttf", ALL_LOCALES)
    -- Monospaced (tabular) Roboto for timer/countdown text: equal-width digits so a
    -- counting-down number does not shift left/right as the digit values change.
    LSM:Register(LSM.MediaType.FONT, "DF Roboto Mono SemiBold", "Interface\\AddOns\\DandersFrames\\Fonts\\RobotoMono-SemiBold.ttf", ALL_LOCALES)
    LSM:Register(LSM.MediaType.FONT, "DF Roboto Mono Bold", "Interface\\AddOns\\DandersFrames\\Fonts\\RobotoMono-Bold.ttf", ALL_LOCALES)
    
    -- Register custom statusbar textures
    LSM:Register(LSM.MediaType.STATUSBAR, "DF Flat", "Interface\\Buttons\\WHITE8x8")
    LSM:Register(LSM.MediaType.STATUSBAR, "DF Gradient H", "Interface\\AddOns\\DandersFrames\\Media\\DF_Gradient_H")
    LSM:Register(LSM.MediaType.STATUSBAR, "DF Gradient V", "Interface\\AddOns\\DandersFrames\\Media\\DF_Gradient_V")
    LSM:Register(LSM.MediaType.STATUSBAR, "DF Gradient H Rev", "Interface\\AddOns\\DandersFrames\\Media\\DF_Gradient_H_Rev")
    LSM:Register(LSM.MediaType.STATUSBAR, "DF Gradient V Rev", "Interface\\AddOns\\DandersFrames\\Media\\DF_Gradient_V_Rev")
    LSM:Register(LSM.MediaType.STATUSBAR, "DF Stripes", "Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes")
    LSM:Register(LSM.MediaType.STATUSBAR, "DF Stripes Soft", "Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Soft")
    LSM:Register(LSM.MediaType.STATUSBAR, "DF Stripes Soft Wide", "Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Soft_Wide")
    LSM:Register(LSM.MediaType.STATUSBAR, "DF Stripes Sparse", "Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Sparse")
    LSM:Register(LSM.MediaType.STATUSBAR, "DF Stripes Medium", "Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Medium")
    LSM:Register(LSM.MediaType.STATUSBAR, "DF Stripes Dense", "Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Dense")
    LSM:Register(LSM.MediaType.STATUSBAR, "DF Stripes Very Dense", "Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Very_Dense")
    
    -- Health bar textures
    LSM:Register(LSM.MediaType.STATUSBAR, "DF Smooth", "Interface\\AddOns\\DandersFrames\\Media\\DF_Smooth")
    LSM:Register(LSM.MediaType.STATUSBAR, "DF Glossy", "Interface\\AddOns\\DandersFrames\\Media\\DF_Glossy")
    LSM:Register(LSM.MediaType.STATUSBAR, "DF Matte", "Interface\\AddOns\\DandersFrames\\Media\\DF_Matte")
    LSM:Register(LSM.MediaType.STATUSBAR, "DF Glass", "Interface\\AddOns\\DandersFrames\\Media\\DF_Glass")
    LSM:Register(LSM.MediaType.STATUSBAR, "DF Soft", "Interface\\AddOns\\DandersFrames\\Media\\DF_Soft")
    LSM:Register(LSM.MediaType.STATUSBAR, "DF Beveled", "Interface\\AddOns\\DandersFrames\\Media\\DF_Beveled")
    LSM:Register(LSM.MediaType.STATUSBAR, "DF Minimalist", "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist")

    -- Frame border textures (edgeFiles for the Texture border style)
    LSM:Register(LSM.MediaType.BORDER, "DF Glow", "Interface\\AddOns\\DandersFrames\\Media\\DF_Glow")
    LSM:Register(LSM.MediaType.BORDER, "DF Bevel", "Interface\\AddOns\\DandersFrames\\Media\\DF_Bevel")
    LSM:Register(LSM.MediaType.BORDER, "DF Inset", "Interface\\AddOns\\DandersFrames\\Media\\DF_Inset")
    LSM:Register(LSM.MediaType.BORDER, "DF Double", "Interface\\AddOns\\DandersFrames\\Media\\DF_Double")

    -- Register callback to clear font cache when new fonts are added
    LSM:RegisterCallback("LibSharedMedia_Registered", function(_, mediaType)
        if mediaType == LSM.MediaType.FONT then
            if DF.ClearFontCache then
                DF:ClearFontCache()
            end
        end
    end)
end

-- Try to register now, and also schedule for later in case LSM loads after us
RegisterCustomMedia()

-- Also try after ADDON_LOADED in case SharedMedia addons load later
local registrationFrame = CreateFrame("Frame")
registrationFrame:RegisterEvent("ADDON_LOADED")
registrationFrame:SetScript("OnEvent", function(self, event, loadedAddon)
    -- Try to register our media whenever any addon loads (in case it's SharedMedia)
    RegisterCustomMedia()
    -- Once LSM is available, we're done - stop listening
    local LSM = GetLSM()
    if LSM then
        self:UnregisterAllEvents()
    end
end)

-- Store reference for other modules (use getter function)
DF.GetLSM = GetLSM

-- ============================================================
-- FONTS & TEXTURES (SharedMedia integration)
-- ============================================================

-- Fallback fonts if SharedMedia not available
DF.SharedFonts = {
    ["Fonts\\FRIZQT__.TTF"] = "Friz Quadrata TT",
    ["Fonts\\ARIALN.TTF"] = "Arial Narrow",
    ["Fonts\\skurri.ttf"] = "Skurri",
    ["Fonts\\MORPHEUS.TTF"] = "Morpheus",
    ["Interface\\AddOns\\DandersFrames\\Fonts\\Expressway.ttf"] = "DF Expressway",
    ["Interface\\AddOns\\DandersFrames\\Fonts\\Roboto-SemiBold.ttf"] = "DF Roboto SemiBold",
    ["Interface\\AddOns\\DandersFrames\\Fonts\\Roboto-Bold.ttf"] = "DF Roboto Bold",
}

-- Fallback textures if SharedMedia not available
DF.SharedTextures = {
    ["Solid"] = "Solid (No Texture)",  -- Special option for solid color backgrounds
    ["Interface\\TargetingFrame\\UI-StatusBar"] = "Blizzard",
    ["Interface\\Buttons\\WHITE8x8"] = "Flat",
    ["Interface\\RaidFrame\\Raid-Bar-Hp-Fill"] = "Raid",
    ["Interface\\AddOns\\DandersFrames\\Media\\DF_Gradient_H"] = "DF Gradient H",
    ["Interface\\AddOns\\DandersFrames\\Media\\DF_Gradient_V"] = "DF Gradient V",
    ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes"] = "DF Stripes",
    ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Soft"] = "DF Stripes Soft",
    ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Soft_Wide"] = "DF Stripes Soft Wide",
    ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Sparse"] = "DF Stripes Sparse",
    ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Medium"] = "DF Stripes Medium",
    ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Dense"] = "DF Stripes Dense",
    ["Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes_Very_Dense"] = "DF Stripes Very Dense",
}

-- Fonts to exclude (known problematic fonts)
-- Font validation removed - show all SharedMedia fonts like MPlusTimer does

function DF:GetFontList()
    -- Returns a table of fontName -> fontName for dropdown compatibility
    -- We now store font NAMES in the database, not paths
    -- Show all fonts like MPlusTimer does - no filtering
    local list = {}
    local LSM = GetLSM()
    
    if LSM then
        -- Use SharedMedia fonts - use lowercase "font" like MPlusTimer
        local fonts = LSM:List("font")
        for _, name in ipairs(fonts) do
            list[name] = name
        end
    else
        -- Fallback to built-in font names
        for path, name in pairs(DF.SharedFonts) do
            list[name] = name
        end
    end
    
    return list
end

-- Fetch actual font path from SharedMedia by name (like MPlusTimer does)
function DF:GetFontPath(fontName)
    if not fontName then return "Fonts\\FRIZQT__.TTF" end
    
    -- If fontName looks like a path already (legacy support), return it
    if fontName:find("\\") or fontName:find("/") then
        return fontName
    end
    
    -- Use SharedMedia to get path - exactly like MPlusTimer does
    local LSM = GetLSM()
    if LSM then
        return LSM:Fetch("font", fontName)
    end
    
    -- Fallback
    return "Fonts\\FRIZQT__.TTF"
end

-- Get font display name from stored value (handles both names and legacy paths)
function DF:GetFontNameFromPath(fontValue)
    if not fontValue then return nil end
    
    local list = DF:GetFontList()
    
    -- If it's already a font name in our list, return it directly
    if list[fontValue] then
        return fontValue
    end
    
    -- Legacy path support: if it looks like a path, try to find the font name
    if fontValue:find("\\") or fontValue:find("/") then
        local LSM = GetLSM()
        if LSM then
            local fonts = LSM:List("font")
            for _, name in ipairs(fonts) do
                local registeredPath = LSM:Fetch("font", name)
                if registeredPath then
                    -- Compare paths (case-insensitive, slash-normalized)
                    local normRegistered = registeredPath:lower():gsub("/", "\\")
                    local normInput = fontValue:lower():gsub("/", "\\")
                    if normRegistered == normInput then
                        return name
                    end
                    -- Also try comparing just filenames
                    local regFilename = registeredPath:match("([^/\\]+)$")
                    local inputFilename = fontValue:match("([^/\\]+)$")
                    if regFilename and inputFilename and regFilename:lower() == inputFilename:lower() then
                        return name
                    end
                end
            end
        end
        
        -- Return filename without extension as fallback
        local filename = fontValue:match("([^/\\]+)$")
        if filename then
            return filename:gsub("%.[tT][tT][fF]$", ""):gsub("%.[oO][tT][fF]$", "")
        end
    end
    
    return fontValue
end

-- ============================================================
-- FONT FAMILY SYSTEM (Multi-alphabet support like Platynator)
-- ============================================================

-- Cache for created font families
local fontFamilies = {}

-- Clear font cache (kept for compatibility)
function DF:ClearFontCache()
    -- Clear font families when new fonts are registered
    wipe(fontFamilies)
end

-- Alphabets supported by WoW font families
local alphabets = {"roman", "korean", "simplifiedchinese", "traditionalchinese", "russian"}

-- Determine user's alphabet based on locale
local locale = GetLocale()
local userAlphabet = "roman"
if locale == "koKR" then
    userAlphabet = "korean"
elseif locale == "zhCN" then
    userAlphabet = "simplifiedchinese"
elseif locale == "zhTW" then
    userAlphabet = "traditionalchinese"
elseif locale == "ruRU" then
    userAlphabet = "russian"
end

-- Font alphabet support map
-- Fonts not listed here are assumed to support only "roman"
-- Blizzard fonts and fonts with full Unicode support should include all alphabets
local fontAlphabetSupport = {
    -- Blizzard fonts - only list alphabets they actually contain glyphs for.
    -- For unlisted alphabets (e.g. Korean, Chinese), GetFontFamilyMembers will
    -- fall back to the proper locale-specific font from GameFontNormal.
    ["Fonts\\FRIZQT__.TTF"] = {"roman", "russian"},
    ["Fonts\\ARIALN.TTF"] = {"roman", "russian"},
    ["Fonts\\MORPHEUS.TTF"] = {"roman"},
    ["Fonts\\SKURRI.TTF"] = {"roman"},
    
    -- Our custom fonts
    ["Interface\\AddOns\\DandersFrames\\Fonts\\Expressway.ttf"] = {"roman"},  -- Latin only
    ["Interface\\AddOns\\DandersFrames\\Fonts\\Roboto-SemiBold.ttf"] = {"roman", "russian"},  -- Latin + Cyrillic
    ["Interface\\AddOns\\DandersFrames\\Fonts\\Roboto-Bold.ttf"] = {"roman", "russian"},  -- Latin + Cyrillic
}

-- Allow registering font alphabet support (for SharedMedia fonts from other addons)
-- Usage: DF:RegisterFontAlphabetSupport("Interface\\AddOns\\MyAddon\\Fonts\\MyFont.ttf", {"roman", "russian"})
function DF:RegisterFontAlphabetSupport(fontPath, supportedAlphabets)
    if not fontPath or not supportedAlphabets then return end
    local normalizedPath = fontPath:lower():gsub("/", "\\")
    fontAlphabetSupport[normalizedPath] = supportedAlphabets
    -- Clear font cache so new families are created with updated support
    wipe(fontFamilies)
end

-- Check if a font supports a given alphabet
local function FontSupportsAlphabet(fontPath, alphabet)
    if not fontPath or not alphabet then return false end
    
    -- Normalize path for comparison (case insensitive, handle both slash types)
    local normalizedPath = fontPath:lower():gsub("/", "\\")
    
    -- Check our known fonts
    for knownPath, supportedAlphabets in pairs(fontAlphabetSupport) do
        if normalizedPath == knownPath:lower() then
            for _, supported in ipairs(supportedAlphabets) do
                if supported == alphabet then
                    return true
                end
            end
            return false
        end
    end
    
    -- Unknown fonts: assume they only support roman alphabet
    -- This is safer - better to fall back to Blizzard than show boxes
    return alphabet == "roman"
end

-- Base font size used for font families (we'll scale from this)
local BASE_FONT_SIZE = 12

-- Hidden frame used for font preloading/validation
-- Needed early because GetOrCreateFontFamily uses it
local fontValidationFrame = CreateFrame("Frame")
fontValidationFrame:Hide()
local fontValidationString = fontValidationFrame:CreateFontString(nil, "OVERLAY")

-- Preload/validate a font to ensure WoW has it loaded
local function PreloadFont(fontPath)
    if not fontPath then return end
    -- Attempt to set the font - this forces WoW to load the font file
    pcall(function()
        fontValidationString:SetFont(fontPath, 12, "")
    end)
end

-- Build font family members for CreateFontFamily
-- Uses custom font for supported alphabets, Blizzard fallbacks for others
local function GetFontFamilyMembers(customFontPath, outline, size)
    local members = {}
    local coreFont = GameFontNormal
    size = size or BASE_FONT_SIZE
    
    -- Check if GetFontObjectForAlphabet exists (WoW 11.x+)
    if not coreFont or not coreFont.GetFontObjectForAlphabet then
        return nil
    end
    
    for _, alphabet in ipairs(alphabets) do
        local forAlphabet = coreFont:GetFontObjectForAlphabet(alphabet)
        if not forAlphabet then
            return nil  -- API not fully available
        end
        local blizzFile, _, _ = forAlphabet:GetFont()
        if not blizzFile then
            return nil  -- Can't get font info
        end
        
        -- Check if custom font supports this alphabet
        if FontSupportsAlphabet(customFontPath, alphabet) then
            -- Use custom font for this alphabet
            table.insert(members, {
                alphabet = alphabet,
                file = customFontPath,
                height = size,
                flags = outline,
            })
        else
            -- Use Blizzard's default font for unsupported alphabets
            table.insert(members, {
                alphabet = alphabet,
                file = blizzFile,
                height = size,
                flags = outline,
            })
        end
    end
    
    return members
end

-- Create or get a cached font family (keyed by font + outline + size + shadow).
-- The family is built at the REAL point size (not a scaled base) so text renders
-- natively — no fractional SetTextScale — while keeping multi-alphabet support.
-- One family per distinct size in use; sizes are discrete (a handful), so bounded.
local fontFamilyCounter = 0
local function GetOrCreateFontFamily(fontPath, outline, useShadow, size)
    -- Check if CreateFontFamily API is available (WoW 11.x+)
    if not CreateFontFamily then
        return nil
    end
    size = size or BASE_FONT_SIZE

    -- Create unique key for this font configuration. Shadow stays LAST so
    -- RefreshFontFamilyShadows' "|shadow" suffix check still identifies it.
    local key = (fontPath or "default"):lower() .. "|" .. (outline or "") .. "|" .. tostring(size) .. "|" .. (useShadow and "shadow" or "noshadow")
    
    if fontFamilies[key] then
        return fontFamilies[key]
    end
    
    -- Get font family members
    local members = GetFontFamilyMembers(fontPath, outline or "", size)
    if not members then
        return nil  -- API not available or failed
    end
    
    -- Preload all fonts in the family to ensure they're available
    -- This is important for fonts that haven't been used yet
    for _, member in ipairs(members) do
        if member.file and fontValidationString then
            pcall(function()
                fontValidationString:SetFont(member.file, 12, "")
            end)
        end
    end
    
    -- Generate unique global name
    fontFamilyCounter = fontFamilyCounter + 1
    local globalName = "DFFont" .. fontFamilyCounter
    
    -- Create font family with multi-alphabet support
    local success, fontFamily = pcall(CreateFontFamily, globalName, members)
    
    if success and fontFamily then
        fontFamily:SetTextColor(1, 1, 1)
        
        -- Apply shadow to all alphabet font objects if needed (like Platynator does)
        if useShadow then
            -- Get shadow settings from current db (party or raid mode)
            local db
            if DF.GetDB then
                db = DF:GetDB()
            elseif DF.db then
                local mode = (DF.GUI and DF.GUI.SelectedMode) or "party"
                db = DF.db[mode]
            end
            local shadowX = db and db.fontShadowOffsetX or 1
            local shadowY = db and db.fontShadowOffsetY or -1
            local shadowColor = db and db.fontShadowColor or {r = 0, g = 0, b = 0, a = 1}
            for _, alphabet in ipairs(alphabets) do
                local fontObj = fontFamily:GetFontObjectForAlphabet(alphabet)
                if fontObj then
                    fontObj:SetShadowOffset(shadowX, shadowY)
                    fontObj:SetShadowColor(shadowColor.r or 0, shadowColor.g or 0, shadowColor.b or 0, shadowColor.a or 1)
                end
            end
        end
        
        fontFamilies[key] = globalName
        return globalName
    end

    return nil
end

-- 12.0.7: a font's drop shadow lives on its font-family per-alphabet font
-- objects, not the fontstring (fontstring-level SetShadow* is a silent no-op).
-- Update the already-built families' shadow in place so the Shadow X/Y/Color
-- sliders preview live, without a full ClearFontCache + frame rebuild.
function DF:RefreshFontFamilyShadows()
    if not CreateFontFamily then return end
    local db = (DF.GetDB and DF:GetDB())
        or (DF.db and DF.db[(DF.GUI and DF.GUI.SelectedMode) or "party"])
    local shadowX = (db and db.fontShadowOffsetX) or 1
    local shadowY = (db and db.fontShadowOffsetY) or -1
    local sc = (db and db.fontShadowColor) or {r = 0, g = 0, b = 0, a = 1}
    for key, globalName in pairs(fontFamilies) do
        -- Only families built with a shadow (cache-key suffix "|shadow") carry one.
        if key:sub(-7) == "|shadow" then
            local fam = _G[globalName]
            if fam and fam.GetFontObjectForAlphabet then
                for _, alphabet in ipairs(alphabets) do
                    local fontObj = fam:GetFontObjectForAlphabet(alphabet)
                    if fontObj then
                        fontObj:SetShadowOffset(shadowX, shadowY)
                        fontObj:SetShadowColor(sc.r or 0, sc.g or 0, sc.b or 0, sc.a or 1)
                    end
                end
            end
        end
    end
end

function DF:GetTextureList(includeSolid)
    local list = {}
    local LSM = GetLSM()
    
    -- Add Solid option for backgrounds if requested
    if includeSolid then
        list["Solid"] = "Solid (No Texture)"
    end
    
    if LSM then
        -- Use SharedMedia statusbar textures
        local textures = LSM:List(LSM.MediaType.STATUSBAR)
        for _, name in ipairs(textures) do
            local path = LSM:Fetch(LSM.MediaType.STATUSBAR, name)
            if path then
                list[path] = name
            end
        end
    else
        -- Fallback to built-in textures
        for k, v in pairs(DF.SharedTextures) do
            if k ~= "Solid" or includeSolid then  -- Only include Solid if requested
                list[k] = v
            end
        end
    end

    return list
end

-- SharedMedia border textures for the "Texture" border style dropdown. The
-- built-in pixel-perfect four-edge border is the separate "Solid" style and is
-- intentionally not listed here. LibSharedMedia ships a few defaults (e.g.
-- "Blizzard Tooltip"/"Blizzard Dialog"), so this is normally non-empty.
function DF:GetBorderList()
    local list = {}
    local LSM = GetLSM()
    if LSM then
        for _, name in ipairs(LSM:List(LSM.MediaType.BORDER)) do
            list[name] = name
        end
    end
    return list
end

-- Resolve a stored border value to an edgeFile path. "SOLID"/""/nil → nil
-- (the caller uses the four-edge solid border instead).
function DF:GetBorderTexturePath(key)
    if not key or key == "SOLID" or key == "" then return nil end
    local LSM = GetLSM()
    if LSM then
        return LSM:Fetch(LSM.MediaType.BORDER, key)
    end
    return nil
end

-- Get texture display name from path (with fuzzy matching for SharedMedia compatibility)
function DF:GetTextureNameFromPath(texturePath)
    if not texturePath then return nil end
    
    -- Special case for Solid
    if texturePath == "Solid" then
        return "Solid (No Texture)"
    end
    
    -- First try direct lookup in current texture list
    local list = DF:GetTextureList()
    if list[texturePath] then
        return list[texturePath]
    end
    
    -- Try with normalized path (replace forward slashes with backslashes)
    local normalizedPath = texturePath:gsub("/", "\\")
    if list[normalizedPath] then
        return list[normalizedPath]
    end
    
    -- Try reverse - backslashes to forward slashes
    normalizedPath = texturePath:gsub("\\", "/")
    if list[normalizedPath] then
        return list[normalizedPath]
    end
    
    -- Try case-insensitive search
    local lowerPath = texturePath:lower()
    for path, name in pairs(list) do
        if path:lower() == lowerPath then
            return name
        end
    end
    
    -- Try matching without "Interface\" or "Interface/" prefix
    local strippedPath = texturePath:gsub("^[Ii]nterface[/\\]", ""):lower()
    for path, name in pairs(list) do
        local strippedListPath = path:gsub("^[Ii]nterface[/\\]", ""):lower()
        if strippedPath == strippedListPath then
            return name
        end
    end
    
    -- Last resort: Ask SharedMedia directly
    local LSM = GetLSM()
    if LSM then
        local textures = LSM:List(LSM.MediaType.STATUSBAR)
        for _, name in ipairs(textures) do
            local registeredPath = LSM:Fetch(LSM.MediaType.STATUSBAR, name)
            if registeredPath then
                local normRegistered = registeredPath:lower():gsub("/", "\\")
                local normInput = texturePath:lower():gsub("/", "\\")
                if normRegistered == normInput then
                    return name
                end
                -- Also try comparing just filenames
                local regFilename = registeredPath:match("([^/\\]+)$")
                local inputFilename = texturePath:match("([^/\\]+)$")
                if regFilename and inputFilename and regFilename:lower() == inputFilename:lower() then
                    return name
                end
            end
        end
    end
    
    -- If still no match, return just the filename portion as a cleaner display
    local filename = texturePath:match("([^/\\]+)$")
    if filename then
        return filename
    end
    
    return nil
end

-- ============================================================
-- SHARED MEDIA: SOUNDS
-- ============================================================

function DF:GetSoundList()
    -- Returns a table of soundName -> soundName for dropdown compatibility
    -- Excludes entries whose LSM fetch returns a non-string (e.g. "None" returns integer 1)
    local list = {}
    local LSM = GetLSM()
    if LSM then
        local sounds = LSM:List(LSM.MediaType.SOUND)
        for _, name in ipairs(sounds) do
            if type(LSM:Fetch(LSM.MediaType.SOUND, name)) == "string" then
                list[name] = name
            end
        end
    end
    return list
end

function DF:GetSoundPath(soundName)
    if not soundName then return nil end
    -- If it looks like a path already, return it
    if soundName:find("\\") or soundName:find("/") then
        return soundName
    end
    local LSM = GetLSM()
    if LSM then
        local path = LSM:Fetch(LSM.MediaType.SOUND, soundName)
        if type(path) == "string" and path ~= "" then
            return path
        end
        return nil
    end
    return nil
end

-- Get font path by name (for SharedMedia compatibility)
function DF:GetFont(name)
    local LSM = GetLSM()
    if LSM then
        return LSM:Fetch("font", name) or name
    end
    -- Check if name is already a path
    if DF.SharedFonts[name] then
        return name
    end
    -- Try to find path by display name
    for path, displayName in pairs(DF.SharedFonts) do
        if displayName == name then
            return path
        end
    end
    return name
end

-- Default fallback font
local FALLBACK_FONT = "Fonts\\FRIZQT__.TTF"

-- Safely set a font on a fontstring with fallback
-- Uses font families for multi-alphabet support (Cyrillic, CJK, etc.) when available
-- Returns true if successful, false if had to use fallback
-- Outline/shadow value helpers.
-- A stored outline value is one of: a plain WoW flag ("", "NONE", "OUTLINE",
-- "THICKOUTLINE", "MONOCHROME", "MONOCHROME, OUTLINE", "MONOCHROME, THICKOUTLINE"),
-- the legacy "SHADOW" (shadow only), or a composite "SHADOW;<flag>" (shadow plus a
-- flag). These let the GUI bind a flag dropdown and a shadow checkbox to a single
-- stored value without a destructive migration of existing profiles.

-- Returns the flag portion (always "NONE" rather than "" for dropdown matching).
function DF:OutlineFlag(stored)
    stored = stored or "NONE"
    local rest = stored:match("^SHADOW;(.*)$")
    if rest then stored = rest end
    if stored == "" or stored == "SHADOW" then return "NONE" end
    return stored
end

-- Returns true if the stored value includes a drop shadow.
function DF:OutlineHasShadow(stored)
    if not stored then return false end
    return stored == "SHADOW" or stored:match("^SHADOW;") ~= nil
end

-- Builds a stored value from a flag token and a shadow boolean.
function DF:ComposeOutline(flag, shadow)
    if not flag or flag == "" then flag = "NONE" end
    if shadow then return "SHADOW;" .. flag end
    return flag
end

function DF:SafeSetFont(fontString, fontNameOrPath, fontSize, outline)
    if not fontString then return false end

    -- Harden against wrong-typed profile values: raw db values reach here from
    -- every caller, and a corrupted import can store a boolean/number/table in
    -- a font key. Coerce instead of crashing (a bad outline once broke frame
    -- layout addon-wide on login): bad font name -> fallback font, bad size ->
    -- default, bad outline -> no flags.
    if type(fontNameOrPath) ~= "string" then fontNameOrPath = nil end
    fontSize = tonumber(fontSize) or 10
    if fontSize <= 0 then fontSize = 10 end
    if type(outline) ~= "string" then outline = "" end

    -- The stored outline value may carry a "SHADOW;" prefix (Grid2-style: a drop
    -- shadow combined with any flag, e.g. "SHADOW;MONOCHROME, OUTLINE"). The legacy
    -- value "SHADOW" on its own means shadow with no outline. Shadow is rendered via
    -- SetShadow* below, never as a font flag, so strip it out of the flag string.
    local useShadow = false
    local rest = outline:match("^SHADOW;(.*)$")
    if rest then
        useShadow = true
        outline = rest
    elseif outline == "SHADOW" then
        useShadow = true
        outline = ""
    end

    -- Normalize "NONE" to empty string (NONE is not a valid WoW font flag)
    if outline == "NONE" then outline = "" end

    local actualOutline = outline

    -- SDF / "slug" crisp rendering (opt-in, Retail). Only applies to plain
    -- styles — not Monochrome, Thick Outline, or Shadow — since the SDF
    -- renderer doesn't combine cleanly with those. Appending the SLUG flag
    -- and switching the fontString to vertex scale animation gives sharper
    -- text at any size.
    local useSlug = DF.db and DF.db.fontSlug
        and not useShadow
        and (actualOutline == "" or actualOutline == "OUTLINE")
    if useSlug then
        actualOutline = (actualOutline == "") and "SLUG" or (actualOutline .. ", SLUG")
    end
    if fontString.SetScaleAnimationMode and FontStringScaleAnimationMode then
        fontString:SetScaleAnimationMode(useSlug and FontStringScaleAnimationMode.Vertex or FontStringScaleAnimationMode.FontSize)
    end

    local LSM = GetLSM()
    local fontPath
    
    -- If it looks like a path, use it directly (legacy support)
    if fontNameOrPath and (fontNameOrPath:find("\\") or fontNameOrPath:find("/")) then
        fontPath = fontNameOrPath
    elseif LSM and fontNameOrPath then
        -- Get path from SharedMedia
        fontPath = LSM:Fetch("font", fontNameOrPath)
    end
    
    -- Use fallback if no font path
    if not fontPath then
        fontPath = FALLBACK_FONT
    end
    
    -- Preload the font to ensure it's available
    PreloadFont(fontPath)
    
    -- Try to use font family for multi-alphabet support (WoW 11.x+)
    local fontFamilyName = GetOrCreateFontFamily(fontPath, actualOutline, useShadow, fontSize)

    if fontFamilyName and _G[fontFamilyName] then
        -- Validate the font family object is usable before calling SetFontObject.
        -- During early login, CreateFontFamily can succeed but the internal C++ font
        -- data may not be initialized yet, causing an ACCESS_VIOLATION crash when
        -- SetFontObject tries to read it.  Wrap in pcall to fall through to the
        -- direct SetFont() path if the object is broken.
        local ok = pcall(function()
            fontString:SetFontObject(GameFontNormal)
            fontString:SetFontObject(_G[fontFamilyName])
        end)
        if not ok then
            -- Evict the broken cache entry so it gets recreated later (key format
            -- must match GetOrCreateFontFamily: font|outline|size|shadow).
            local key = (fontPath or "default"):lower() .. "|" .. (actualOutline or "") .. "|" .. tostring(fontSize) .. "|" .. (useShadow and "shadow" or "noshadow")
            fontFamilies[key] = nil
        else
            -- The family is built at the real point size now (per-size cache), so the
            -- glyphs render natively. Clear any fractional scale a prior SafeSetFont left
            -- on this fontstring — the old BASE_FONT_SIZE + SetTextScale(size/12) path was
            -- the source of the sub-pixel blur / off-centre drift that got worse with size.
            fontString:SetTextScale(1)

            -- Force WoW to re-render the text with new font properties
            -- This is needed because switching between font families with different outline flags
            -- may not immediately update the rendered text without a text refresh
            -- Note: Some fontStrings have "secret" text that cannot be read or compared,
            -- so we wrap this in pcall to handle those cases safely
            -- 12.1: a fontstring's text can be SECRET (e.g. a unit name in combat). Reading it
            -- is fine, but COMPARING a secret (text ~= "") is BLOCKED and TAINTS DandersFrames.
            -- This runs in the SecureGroupHeader's child-refresh path (Text Designer), so the
            -- taint poisons the secure header + the 12.1 aura containers → froze auras in combat
            -- (taint.log: 168× Config.lua:773). Skip the re-render for secret text (issecretvalue
            -- short-circuits BEFORE any boolean/compare use of the secret).
            pcall(function()
                local text = fontString:GetText()
                if not (issecretvalue and issecretvalue(text)) and text and text ~= "" then
                    fontString:SetText("")
                    fontString:SetText(text)
                end
            end)

            -- IMPORTANT (12.0.7): the drop shadow lives on the font-family's
            -- per-alphabet font objects (set in GetOrCreateFontFamily). Do NOT also
            -- set a fontstring-level shadow here: once a fontstring carries its own
            -- shadow it stops inheriting the font object's, and fontstring-level
            -- SetShadow* no longer renders on 12.0.7 — so the net result is NO shadow
            -- (this is what hid the AFK timer / status-icon shadows). Leaving the
            -- fontstring untouched lets it inherit the font object's shadow.
            return true
        end
    end
    
    -- Fallback: Direct SetFont (no multi-alphabet support, or older WoW version)
    local success = fontString:SetFont(fontPath, fontSize, actualOutline)
    
    -- Reset text scale in case it was set before by font family code
    if fontString.SetTextScale then
        fontString:SetTextScale(1)
    end
    
    if not success then
        -- Ultimate fallback
        fontString:SetFont(FALLBACK_FONT, fontSize, actualOutline)
    end
    
    -- Apply or clear shadow
    if useShadow then
        -- Get shadow settings from current db (party or raid mode)
        local db
        if DF.GetDB then
            db = DF:GetDB()
        elseif DF.db then
            local mode = (DF.GUI and DF.GUI.SelectedMode) or "party"
            db = DF.db[mode]
        end
        local shadowX = db and db.fontShadowOffsetX or 1
        local shadowY = db and db.fontShadowOffsetY or -1
        local shadowColor = db and db.fontShadowColor or {r = 0, g = 0, b = 0, a = 1}
        fontString:SetShadowOffset(shadowX, shadowY)
        fontString:SetShadowColor(shadowColor.r or 0, shadowColor.g or 0, shadowColor.b or 0, shadowColor.a or 1)
    else
        fontString:SetShadowOffset(0, 0)
    end
    
    return success
end

-- Get texture path by name (for SharedMedia compatibility)
function DF:GetTexture(name)
    -- Special case for Solid - shouldn't reach here but safeguard
    if name == "Solid" then
        return nil
    end
    
    local LSM = GetLSM()
    if LSM then
        return LSM:Fetch(LSM.MediaType.STATUSBAR, name) or name
    end
    -- Check if name is already a path
    if DF.SharedTextures[name] then
        return name
    end
    -- Try to find path by display name
    for path, displayName in pairs(DF.SharedTextures) do
        if displayName == name then
            return path
        end
    end
    return name
end

-- ============================================================
-- GLOBAL (account-wide) DEFAULTS
-- Not per-profile. Lives at DandersFramesDB_v2.global.
-- ============================================================

DF.GlobalDefaults = {
    notifyOutdated = true,
}

-- ============================================================
-- DEFAULT SETTINGS (exported from profile v2.9.8)
-- ============================================================

DF.PartyDefaults = {
    -- Internal migration flags
    _blizzDispelIndicator = 1,
    _defensiveIconMigrated = true,

    -- Global Font Shadow Settings (applies when outline is SHADOW)
    fontShadowOffsetX = 1,
    fontShadowOffsetY = -1,
    fontShadowColor = {r = 0, g = 0, b = 0, a = 1},

    -- Absorb Bar
    absorbBarAnchor = "TOPRIGHT",
    absorbBarAttachedClampMode = 1,
    absorbBarBackgroundColor = {r = 0, g = 0, b = 0, a = 1},
    absorbBarBlendMode = "BLEND",
    absorbBarBorderColor = {r = 1, g = 0, b = 0.29803922772408, a = 1},
    absorbBarBorderEnabled = true,
    absorbBarBorderSize = 4,
    absorbBarColor = {r = 0, g = 0.83529418706894, b = 1, a = 0.80208319425583},
    absorbBarFrameLevel = 11,
    absorbBarHeight = 7,
    absorbBarMode = "ATTACHED_OVERFLOW",
    absorbBarOrientation = "HORIZONTAL",
    absorbBarOverlayReverse = false,
    absorbBarOvershieldAlpha = 0.8,
    absorbBarOvershieldColor = nil,
    absorbBarOvershieldReverse = false,
    absorbBarOvershieldStyle = "SPARK",
    absorbBarReverse = false,
    absorbBarShowOvershield = false,
    absorbBarStrata = "MEDIUM",
    absorbBarTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes",
    absorbBarWidth = 46,
    absorbBarX = 0,
    absorbBarY = 0,
    showAbsorbBar = true,

    -- AFK Icon
    afkIconAlpha = 0.8,
    afkIconAnchor = "CENTER",
    afkIconEnabled = true,
    afkIconFrameLevel = 0,
    afkIconHideInCombat = true,
    afkIconScale = 0.7,
    afkIconShowText = false,
    afkIconShowTimer = true,
    afkIconText = "AFK",
    afkIconTextColor = {r = 1, g = 0.5, b = 0, a = 1},
    afkIconTimerColor = {r = 1, g = 0.5, b = 0, a = 1},
    -- afkIconTimerFont intentionally unset: the timer inherits the global status-icon
    -- font. The countdown no longer wobbles because ApplyTimerTextSettings LEFT-
    -- justifies it (the changing seconds sit on the right with nothing to push). A
    -- monospace font is still selectable if perfectly zero movement is wanted.
    afkIconTimerFontSize = 16,
    afkIconTimerX = 0,
    afkIconTimerY = 1,
    afkIconX = 0,
    afkIconY = 0,

    -- Aggro Highlight
    aggroColorHighThreat = {r = 1, g = 1, b = 0.47},
    aggroColorHighestThreat = {r = 1, g = 0.6, b = 0},
    aggroColorTanking = {r = 1, g = 0, b = 0},
    aggroHighlightAlpha = 0.7500000596046448,
    aggroHighlightInset = 0,
    aggroHighlightMode = "GLOW",
    aggroHighlightThickness = 1,
    aggroOnlyTanking = false,
    aggroHideOnTanks = false,
    aggroUseCustomColors = false,

    -- Anchor/Position
    anchorPoint = "CENTER",
    anchorX = 0,
    anchorY = -325,

    -- Background
    backgroundClassAlpha = 1,
    backgroundColor = {r = 0.5137255191802979, g = 0.5137255191802979, b = 0.5137255191802979, a = 0.7531240582466125},
    backgroundColorMode = "CUSTOM",
    backgroundMode = "BACKGROUND",
    backgroundTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist",
    missingHealthClassAlpha = 0.8,
    missingHealthColor = {r = 0.5, g = 0, b = 0, a = 0.8},
    missingHealthColorHigh = {r = 0.05098039656877518, g = 1, b = 0, a = 1},
    missingHealthColorHighUseClass = false,
    missingHealthColorHighWeight = 1,
    missingHealthColorLow = {r = 1, g = 0, b = 0, a = 1},
    missingHealthColorLowUseClass = false,
    missingHealthColorLowWeight = 2,
    missingHealthColorMedium = {r = 1, g = 1, b = 0, a = 1},
    missingHealthColorMediumUseClass = false,
    missingHealthColorMediumWeight = 2,
    missingHealthColorMode = "CUSTOM",
    missingHealthGradientAlpha = 0.8,
    missingHealthTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist",

    -- Frame Border (canonical "frame" prefix; CreateBorderControls + BuildSpec
    -- convention. Existing user configs with legacy keys (`borderSize`,
    -- `showFrameBorder`, `borderClassColor`, etc.) are migrated to these via
    -- DF:MigrateFrameBorderKeys on db load.)
    -- (No frameBorderAnimation* keys: the Frame Border is structural chrome, not an
    -- alert surface, so it deliberately has no animation control — see the include
    -- table in Options.lua. The keys were only ever a by-product of the shared border
    -- key scheme; no UI could set them and BuildSpec always read "NONE".)
    frameBorderBlendMode = "BLEND",
    frameBorderColor = {r = 0, g = 0, b = 0, a = 1},
    frameBorderGradientDirection = "HORIZONTAL",
    frameBorderGradientEnabled = false,
    frameBorderGradientEndColor = {r = 0.5, g = 0.5, b = 0.5, a = 1},
    frameBorderGradientStartColor = {r = 0, g = 0, b = 0, a = 1},
    frameBorderInset = 0,
    frameBorderOffsetX = 0,
    frameBorderOffsetY = 0,
    frameBorderShadowColor = {r = 0, g = 0, b = 0, a = 0.8},
    frameBorderShadowEnabled = false,
    frameBorderShadowOffsetX = 1,
    frameBorderShadowOffsetY = -1,
    frameBorderShadowSize = 1,
    frameBorderSize = 1,
    frameBorderStyle = "SOLID",
    frameBorderTexture = "SOLID",
    frameBorderUseClassColor = false,
    frameShowBorder = true,

    -- ColorSource: which colour-resolver feeds the frame border. Replaces the
    -- legacy frameBorderUseClassColor / UseRoleColor booleans (migrated on
    -- db load by DF:MigrateFrameBorderKeys).
    frameBorderColorSource = "STATIC",
    -- Alpha slider used when ColorSource is CLASS or ROLE — the resolver
    -- supplies RGB and this slider supplies alpha, since the picker (which
    -- normally carries alpha) is hidden in those modes.
    -- Role colours live at profile level (DF.db.roleColors), managed from the
    -- Display → Colors page. DF:MigrateRoleBorderColors seeds defaults at the
    -- profile level on first load; per-mode defaults intentionally absent.

    -- Boss Debuffs

    -- Buff settings
    buffAlpha = 1,
    buffAnchor = "BOTTOMRIGHT",
    buffShowBorder = true,
    buffBorderInset = 0,
    buffBorderSize = 1,
    -- Canonical border toolkit (Stage 5.5 Phase 2): plugs into BuildSpec +
    -- CreateBorderControls.  Colour alpha 0.8 preserves the legacy opacity.
    buffBorderColor = {r = 0, g = 0, b = 0, a = 0.8},
    buffBorderStyle = "SOLID",
    buffBorderTexture = "SOLID",
    buffBorderBlendMode = "BLEND",
    buffBorderOffsetX = 0,
    buffBorderOffsetY = 0,
    buffBorderGradientStartColor = {r = 0, g = 0, b = 0, a = 1},
    buffBorderGradientEndColor = {r = 0.5, g = 0.5, b = 0.5, a = 1},
    buffBorderGradientDirection = "HORIZONTAL",
    buffBorderShadowEnabled = false,
    buffBorderShadowColor = {r = 0, g = 0, b = 0, a = 0.8},
    buffBorderShadowSize = 1,
    buffBorderShadowOffsetX = 1,
    buffBorderShadowOffsetY = -1,
    buffCountdownFont = "Friz Quadrata TT",
    buffCountdownOutline = "OUTLINE",
    buffCountdownScale = 1,
    buffCountdownX = 0,
    buffCountdownY = 0,
    buffDeduplicateDefensives = true,
    buffDurationAnchor = "CENTER",
    buffDurationColor = {r = 1, g = 1, b = 1},
    buffDurationColorByTime = true,
    buffDurationHideAboveEnabled = false,
    buffDurationHideAboveThreshold = 10,
    -- Native 12.1 max-TOTAL-duration filter (candidateFilters.maxDuration); minutes.
    buffMaxDurationEnabled = false,
    buffMaxDurationMinutes = 5,
    buffDurationFont = "DF Roboto SemiBold",
    buffDurationFormat = "NUMBER",
    buffDurationOutline = "SHADOW;OUTLINE",
    buffDurationScale = 1.2000000476837,
    buffDurationX = 0,
    buffDurationY = 2,
    buffExpiringBorderColor = {r = 1, g = 0.50196081399918, b = 0, a = 1},
    buffExpiringBorderColorByTime = false,
    buffExpiringBorderEnabled = true,
    buffExpiringBorderInset = 0,
    buffExpiringBorderPulsate = true,
    buffExpiringBorderThickness = 2,
    -- Expiring Animation (AD-style full toolkit) — replaces the legacy
    -- buffExpiringBorderPulsate boolean (migrated: true -> DF_PULSATE).
    buffExpiringBorderAnimationType = "DF_PULSATE",
    buffExpiringBorderAnimationColor = {r = 1, g = 0.5, b = 0, a = 1},
    buffExpiringBorderAnimationFrequency = 2,
    buffExpiringBorderAnimationParticles = 8,
    buffExpiringBorderAnimationLength = 8,
    buffExpiringBorderAnimationThickness = 3,
    buffExpiringBorderAnimationScale = 1,
    buffExpiringBorderAnimationInset = 0,
    buffExpiringBorderAnimationOffsetX = 0,
    buffExpiringBorderAnimationOffsetY = 0,
    buffExpiringBorderAnimationMask = false,
    buffExpiringBorderAnimationSidesAxis = "HORIZONTAL",
    buffExpiringBorderAnimationCornerLength = 10,
    buffExpiringEnabled = true,
    buffExpiringThreshold = 30,
    buffExpiringThresholdMode = "PERCENT",
    buffExpiringTintColor = {r = 1, g = 0, b = 0.12156863510609, a = 0.46354159712791},
    buffExpiringTintEnabled = false,
    buffFilterCancelable = false,
    buffFilterMode = "BLIZZARD",
    buffFilterPlayer = true,
    buffFilterRaid = false,

    -- Aura Source Mode

    -- Direct Mode: Buff Filters
    directBuffShowAll = false,                -- Show all buffs (ignores sub-filters)
    directBuffOnlyMine = true,               -- Restrict all buff filters to player-cast only
    buffFilterSelection = {
        presets = { healing = true, raidBuffs = true },
        customs = {},
        uncategorised = false,
    },
    defensiveFilterSelection = {
        presets = { defensives = true, externalDefensives = true },
        customs = {},
        uncategorised = false,
    },
    directBuffSortOrder = "TIME",             -- "DEFAULT" / "TIME" / "NAME"

    -- Direct Mode: Debuff Filters
    directDebuffShowAll = false,              -- Show all debuffs (ignores category filters)
    debuffFilterBoss = true,                  -- Boss debuffs (native isBossAura)
    debuffFilterRole = true,                  -- Role debuffs (native isRoleAura)
    debuffFilterPriority = true,              -- Priority debuffs (native isPriorityAura)
    debuffFilterCrowdControl = true,          -- Crowd control (CROWD_CONTROL token)
    debuffFilterRaid = false,                 -- Other raid-flagged debuffs (RAID token)
    debuffFilterDispellable = true,           -- Dispellable debuffs (mode below)
    directDebuffDispellableMode = "PLAYER",  -- "PLAYER" (dispellable by me) or "ALL" (any dispel type)
    debuffMaxDurationEnabled = false,         -- Hide long debuffs
    debuffMaxDurationMinutes = 5,             -- ... threshold (base duration)
    debuffMaxDurationKeepImportant = true,    -- ... but keep Boss/Role/Priority visible
    directDebuffSortOrder = "TIME",           -- "DEFAULT" / "TIME" / "NAME"

    buffGrowth = "LEFT_UP",
    buffHideSwipe = false,
    buffMax = 4,
    buffOffsetX = -2,
    buffOffsetY = 6,
    buffPaddingX = 2,
    buffPaddingY = 2,
    buffScale = 1,
    buffShowCountdown = false,
    buffShowDuration = true,
    buffSize = 20,
    buffStackAnchor = "BOTTOMRIGHT",
    buffStackColor = {r = 1, g = 0.82, b = 0},
    buffStackFont = "DF Roboto SemiBold",
    buffStackMinimum = 2,
    buffStackOutline = "SHADOW;OUTLINE",
    buffStackScale = 1,
    buffStackX = 3,
    buffStackY = 0,
    buffWrap = 2,
    buffWrapOffsetX = 0,
    buffWrapOffsetY = 0,
    showBuffs = true,

    -- Center Status Icon
    centerStatusIconAnchor = "CENTER",
    centerStatusIconEnabled = true,
    centerStatusIconFrameLevel = 0,
    centerStatusIconHide = false,
    centerStatusIconScale = 1,
    centerStatusIconX = 0,
    centerStatusIconY = 0,

    -- Class Color
    classColorAlpha = 1,
    colorPickerGlobalOverride = false,
    colorPickerOverride = true,

    -- Dead/Fade Settings
    deadBackgroundAlpha = 0.3,
    deadBackgroundColor = {r = 0.2, g = 0.2, b = 0.2, a = 1},
    deadFadeEnabled = false,
    deadHealthBarAlpha = 0.3,
    deadHealthTextAlpha = 0.3,
    deadNameAlpha = 0.5,
    deadUseCustomBgColor = false,
    fadeDeadAuras = 1,
    fadeDeadBackground = 1,
    fadeDeadBackgroundColor = {r = 1, g = 0, b = 0, a = 1},
    fadeDeadFrames = true,
    fadeDeadHealthBar = 1,
    fadeDeadIcons = 1,
    fadeDeadName = 1,
    fadeDeadPowerBar = 0,
    fadeDeadStatusText = 1,
    fadeDeadUseCustomColor = false,

    -- Health threshold fading (fade when health above threshold)
    healthFadeEnabled = false,
    healthFadeAlpha = 0.5,
    healthFadeThreshold = 100,
    hfCancelOnDispel = true,

    -- Debuff settings
    debuffAlpha = 1,
    debuffAnchor = "BOTTOMLEFT",
    debuffBorderColorBleed = {r = 1, g = 0, b = 0},
    debuffBorderColorByType = true,
    debuffBorderColorCurse = {r = 0.6, g = 0, b = 1},
    debuffBorderColorDisease = {r = 0.6, g = 0.4, b = 0},
    debuffBorderColorMagic = {r = 0.2, g = 0.6, b = 1},
    debuffBorderColorNone = {r = 0, g = 0, b = 0, a = 1},
    debuffBorderColorPoison = {r = 0, g = 0.6, b = 0},
    debuffShowBorder = true,
    debuffDispelBorderInset = 0,    -- native dispel ring: + inward / - outward halo
    debuffDurationFormat = "NUMBER",
    debuffDurationColor = {r = 1, g = 1, b = 1},
    debuffStackColor = {r = 1, g = 0.82, b = 0},
    debuffBorderInset = 0,
    debuffBorderSize = 2,
    -- Canonical border toolkit (Stage 5.5 Phase 2).  Static colour, used when
    -- debuffBorderColorByType is OFF (the by-type system overrides when on).
    debuffBorderColor = {r = 0.8, g = 0, b = 0, a = 0.8},
    debuffBorderStyle = "SOLID",
    debuffBorderTexture = "SOLID",
    debuffBorderBlendMode = "BLEND",
    debuffBorderOffsetX = 0,
    debuffBorderOffsetY = 0,
    debuffBorderGradientStartColor = {r = 0, g = 0, b = 0, a = 1},
    debuffBorderGradientEndColor = {r = 0.5, g = 0.5, b = 0.5, a = 1},
    debuffBorderGradientDirection = "HORIZONTAL",
    debuffBorderShadowEnabled = false,
    debuffBorderShadowColor = {r = 0, g = 0, b = 0, a = 0.8},
    debuffBorderShadowSize = 1,
    debuffBorderShadowOffsetX = 1,
    debuffBorderShadowOffsetY = -1,
    debuffCountdownFont = "Friz Quadrata TT",
    debuffCountdownOutline = "OUTLINE",
    debuffCountdownScale = 1,
    debuffCountdownX = 0,
    debuffCountdownY = 0,
    debuffDurationAnchor = "CENTER",
    debuffDurationColorByTime = false,
    debuffDurationHideAboveEnabled = false,
    debuffDurationHideAboveThreshold = 10,
    debuffDurationFont = "DF Roboto SemiBold",
    debuffDurationOutline = "SHADOW;OUTLINE",
    debuffDurationScale = 1,
    debuffDurationX = 0,
    debuffDurationY = 0,
    debuffExpiringBorderColor = {r = 1, g = 0.27843138575554, b = 0, a = 1},
    debuffExpiringBorderColorByTime = false,
    debuffExpiringBorderEnabled = true,
    debuffExpiringBorderInset = 1,
    debuffExpiringBorderPulsate = true,
    debuffExpiringBorderThickness = 2,
    debuffExpiringEnabled = false,
    debuffExpiringThreshold = 90,
    debuffExpiringThresholdMode = "PERCENT",
    debuffExpiringTintColor = {r = 1, g = 0.30196079611778, b = 0.30196079611778, a = 0.81119740009308},
    debuffExpiringTintEnabled = true,
    debuffGrowth = "RIGHT_UP",
    debuffHideSwipe = false,
    debuffMax = 5,
    debuffOffsetX = 2,
    debuffOffsetY = 5,
    debuffPaddingX = 2,
    debuffPaddingY = 2,
    debuffScale = 1,
    debuffShowAll = false,
    debuffShowCountdown = false,
    debuffShowDuration = false,
    debuffSize = 20,
    debuffStackAnchor = "BOTTOMRIGHT",
    debuffStackFont = "DF Roboto SemiBold",
    debuffStackMinimum = 2,
    debuffStackOutline = "SHADOW;OUTLINE",
    debuffStackScale = 1,
    debuffStackX = 0,
    debuffStackY = 0,
    debuffWrap = 3,
    debuffWrapOffsetX = 0,
    debuffWrapOffsetY = 0,
    showDebuffs = true,

    -- Defensive Bar
    defensiveBarAnchor = "CENTER",
    defensiveBarBorderColor = {r = 0, g = 0.8, b = 0, a = 1},
    defensiveBarBorderSize = 2,
    defensiveBarEnabled = true,
    defensiveBarFrameLevel = 0,
    defensiveBarGrowth = "RIGHT_DOWN",
    defensiveBarIconSize = 24,
    defensiveBarMax = 4,
    defensiveBarScale = 1.5,
    defensiveBarShowDuration = true,
    defensiveBarSpacing = 2,
    defensiveBarWrap = 5,
    defensiveBarX = 0,
    defensiveBarY = 0,

    -- Defensive Icon
    defensiveIconAnchor = "CENTER",
    defensiveIconBorderAnimationColor = {r = 0.95, g = 0.95, b = 0.32, a = 1},
    defensiveIconBorderAnimationCornerLength = 10,
    defensiveIconBorderAnimationFrequency = 0.25,
    defensiveIconBorderAnimationInset = 0,
    defensiveIconBorderAnimationLength = 8,
    defensiveIconBorderAnimationMask = false,
    defensiveIconBorderAnimationOffsetX = 0,
    defensiveIconBorderAnimationOffsetY = 0,
    defensiveIconBorderAnimationParticles = 8,
    defensiveIconBorderAnimationProcStart = false,
    defensiveIconBorderAnimationScale = 1,
    defensiveIconBorderAnimationSidesAxis = "HORIZONTAL",
    defensiveIconBorderAnimationThickness = 3,
    defensiveIconBorderAnimationType = "NONE",
    defensiveIconBorderBlendMode = "BLEND",
    defensiveIconBorderColor = {r = 0, g = 0.8, b = 0, a = 1},
    defensiveIconBorderColorSource = "STATIC",
    defensiveIconBorderGradientDirection = "HORIZONTAL",
    defensiveIconBorderGradientEnabled = false,
    defensiveIconBorderGradientEndColor = {r = 0, g = 0.4, b = 0.8, a = 1},
    defensiveIconBorderGradientStartColor = {r = 0, g = 0.8, b = 0, a = 1},
    defensiveIconBorderInset = 0,
    defensiveIconBorderOffsetX = 0,
    defensiveIconBorderOffsetY = 0,
    defensiveIconBorderShadowColor = {r = 0, g = 0, b = 0, a = 0.8},
    defensiveIconBorderShadowEnabled = false,
    defensiveIconBorderShadowOffsetX = 1,
    defensiveIconBorderShadowOffsetY = -1,
    defensiveIconBorderShadowSize = 1,
    defensiveIconBorderSize = 2,
    defensiveIconBorderStyle = "SOLID",
    defensiveIconBorderTexture = "SOLID",
    defensiveIconDurationAnchor = "CENTER",
    defensiveIconDurationColor = {r = 1, g = 1, b = 1},
    defensiveIconDurationColorByTime = false,
    defensiveIconDurationFont = "DF Roboto SemiBold",
    defensiveIconDurationOutline = "SHADOW;OUTLINE",
    defensiveIconDurationScale = 1.4,
    defensiveIconDurationX = 0,
    defensiveIconDurationY = 0,
    defensiveIconEnabled = true,
    defensiveIconFrameLevel = 0,
    defensiveIconHideSwipe = false,
    defensiveIconScale = 1,
    defensiveIconShowBorder = true,
    defensiveIconShowDuration = true,
    defensiveIconSize = 30,
    defensiveIconX = 0,
    defensiveIconY = 0,

    -- Dispel Overlay (game-palette colours only — the Custom Colors mode and its
    -- per-type pickers/intensity were removed 2026-07-11; see Features/Dispel.lua)
    dispelAnimate = false,
    dispelAnimateSpeed = 0.5,
    dispelBorderAlpha = 1,
    dispelBorderInset = 0,
    dispelBorderSize = 2,
    dispelBorderStyle = "OUTER",
    dispelFrameLevel = 10,
    dispelGradientAlpha = 1,
    dispelGradientBlendMode = "BLEND",
    dispelGradientDarkenAlpha = 0.40000000596046,
    dispelGradientDarkenEnabled = false,
    dispelGradientOnCurrentHealth = true,
    dispelGradientSize = 0.5,
    dispelGradientStyle = "TOP",
    dispelIconAlpha = 1,
    dispelIconOffsetX = 0,
    dispelIconOffsetY = 0,
    dispelIconPosition = "TOPRIGHT",
    dispelIconSize = 20,
    dispelShowBorder = true,
    dispelShowGradient = true,
    dispelShowIcon = true,
    dispelNameText = false,

    -- Unified dispel overlay (12.1 container-slot driven, Features/Dispel.lua)
    dispelOverlayEnabled = true,
    -- "Show Overlay For": 1 = Dispellable By Me, 2 = All Dispellable (Blizzard convention)
    dispelOverlayDispelType = 2,

    -- External Defensive

    -- Frame Dimensions & Layout
    frameHeight = 64,
    framePadding = 0,
    frameSpacing = 1,
    frameScale = 1.0,
    frameWidth = 125,
    gridSize = 25,
    growDirection = "HORIZONTAL",
    growthAnchor = "CENTER",
    locked = true,
    permanentMover = false,
    permanentMoverActionLeft = "OPEN_SETTINGS",
    permanentMoverActionRight = "SWITCH_PROFILE",
    permanentMoverActionShiftLeft = "TOGGLE_TEST",
    permanentMoverActionShiftRight = "SWITCH_CC_PROFILE",
    permanentMoverAnchor = "RIGHT",
    permanentMoverAttachTo = "CONTAINER",
    permanentMoverColor = {r = 0.45, g = 0.45, b = 0.95},
    permanentMoverCombatColor = {r = 0.8, g = 0.15, b = 0.15},
    permanentMoverHeight = 60,
    permanentMoverHideInCombat = false,
    permanentMoverOffsetX = 20,
    permanentMoverOffsetY = 0,
    permanentMoverPullTimerDuration = 10,
    permanentMoverShowOnHover = false,
    permanentMoverWidth = 15,
    pixelPerfect = true,
    snapToGrid = true,
    pinnedSnapToGrid = false,
    pinnedHideMover = false,
    hideDragOverlay = false,

    -- Group Labels
    groupLabelColor = {r = 1, g = 1, b = 1, a = 1},
    groupLabelEnabled = true,
    groupLabelFont = "DF Roboto SemiBold",
    groupLabelFontSize = 12,
    groupLabelFormat = "SHORT",
    groupLabelOffsetX = 0,
    groupLabelOffsetY = 5,
    groupLabelOutline = "SHADOW",
    groupLabelPosition = "START",

    -- GUI State
    guiHeight = 693.33349609375,
    guiScale = 1,
    guiWidth = 816.6666259765625,

    -- Heal Absorb Bar
    healAbsorbBarAnchor = "BOTTOM",
    healAbsorbBarAttachedClampMode = 1,
    healAbsorbBarBackgroundColor = {r = 0, g = 0, b = 0, a = 0.4570315182209},
    healAbsorbBarBlendMode = "BLEND",
    healAbsorbBarBorderColor = {r = 0, g = 0, b = 0, a = 1},
    healAbsorbBarBorderEnabled = false,
    healAbsorbBarBorderSize = 1,
    healAbsorbBarColor = {r = 1, g = 0.25098040699959, b = 0.25098040699959, a = 0.77604186534882},
    healAbsorbBarHeight = 6,
    healAbsorbBarMode = "OVERLAY",
    healAbsorbBarOrientation = "HORIZONTAL",
    healAbsorbBarOverlayReverse = false,
    healAbsorbBarOvershieldAlpha = 0.8,
    healAbsorbBarOvershieldColor = nil,
    healAbsorbBarOvershieldReverse = false,
    healAbsorbBarOvershieldStyle = "SPARK",
    healAbsorbBarReverse = false,
    healAbsorbBarShowOvershield = false,
    healAbsorbBarTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes",
    healAbsorbBarWidth = 50,
    healAbsorbBarX = 0,
    healAbsorbBarY = -10,

    -- Heal Prediction
    healPredictionAllColor = {r = 0, g = 0.7, b = 0.4, a = 0.7},
    healPredictionAnchor = "CENTER",
    healPredictionBackgroundColor = {r = 0, g = 0, b = 0, a = 0.5},
    healPredictionBlendMode = "BLEND",
    healPredictionClampMode = 1,
    healPredictionEnabled = true,
    healPredictionFrameLevel = 12,
    healPredictionHeight = 6,
    healPredictionMode = "OVERLAY",
    healPredictionMyColor = {r = 0, g = 0.8, b = 0.2, a = 0.7},
    healPredictionOrientation = "HORIZONTAL",
    healPredictionOthersColor = {r = 0, g = 0.5, b = 0.8, a = 0.7},
    healPredictionOverflowPercent = 0,
    healPredictionOverlayReverse = false,
    healPredictionReverse = false,
    healPredictionShowMode = "MINE",
    healPredictionShowOverheal = false,
    healPredictionStrata = "SANDWICH",
    healPredictionTexture = "Interface\\Buttons\\WHITE8x8",
    healPredictionWidth = 50,
    healPredictionX = 0,
    healPredictionY = 0,

    -- Health Bar & Text
    healthColor = {r = 0.5607843399047852, g = 0.7490196228027344, b = 0.1843137294054031, a = 1},
    healthColorHigh = {r = 0.05098039656877518, g = 1, b = 0, a = 1},
    healthColorHighUseClass = false,
    healthColorHighWeight = 1,
    healthColorLow = {r = 1, g = 0, b = 0, a = 1},
    healthColorLowUseClass = false,
    healthColorLowWeight = 2,
    healthColorMedium = {r = 1, g = 1, b = 0, a = 1},
    healthColorMediumUseClass = false,
    healthColorMediumWeight = 2,
    healthColorMode = "CLASS",
    healthFont = "DF Roboto SemiBold",
    healthFontSize = 12,
    healthOrientation = "HORIZONTAL",
    healthTextAbbreviate = true,
    healthTextAnchor = "CENTER",
    healthTextColor = {r = 1, g = 1, b = 1, a = 1},
    healthTextFormat = "CURRENTMAX",
    healthTextHidePercent = false,
    healthTextOutline = "SHADOW",
    healthTextUseClassColor = false,
    healthTextX = 0,
    healthTextY = 6,
    healthTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist",
    showHealthText = false,

    -- Reduced Max Health Bar
    reducedMaxHealthBlendMode = "BLEND",
    reducedMaxHealthClipHealthBar = true,
    reducedMaxHealthColor = {r = 0.502, g = 0.502, b = 0.502, a = 0.8039},
    reducedMaxHealthEnabled = true,
    reducedMaxHealthTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes",

    -- Blizzard Frame Hiding
    hideBlizzardFrames = true,
    hideBlizzardPartyFrames = true,
    hideBlizzardRaidFrames = true,
    hideDefaultPlayerFrame = false,
    hidePlayerFrame = false,
    showBlizzardSideMenu = true,

    -- Hover Highlight
    hoverHighlightAlpha = 0.8,
    hoverHighlightColor = {r = 1, g = 1, b = 1, a = 1},
    hoverHighlightInset = 0,
    hoverHighlightMode = "CORNERS",
    hoverHighlightThickness = 2,

    -- Leader Icon
    leaderIconAlpha = 1,
    leaderIconAnchor = "TOPLEFT",
    leaderIconEnabled = true,
    leaderIconFrameLevel = 0,
    leaderIconHide = false,
    leaderIconHideInCombat = true,
    leaderIconScale = 1,
    leaderIconX = 0,
    leaderIconY = 6,

    -- Masque
    masqueBorderControl = false,

    -- Minimap
    minimapIcon = {
        hide = false,
        minimapPos = 207.168514387028,
    },
    showMinimapButton = true,

    -- Missing Buff
    missingBuffCheckAttackPower = true,
    missingBuffCheckBronze = true,
    missingBuffCheckIntellect = true,
    missingBuffCheckSkyfury = true,
    missingBuffCheckStamina = true,
    missingBuffCheckVersatility = true,
    missingBuffClassDetection = true,
    missingBuffHideFromBar = true,
    missingBuffIconAnchor = "CENTER",
    missingBuffIconBorderAnimationColor = {r = 0.95, g = 0.95, b = 0.32, a = 1},
    missingBuffIconBorderAnimationCornerLength = 10,
    missingBuffIconBorderAnimationFrequency = 0.25,
    missingBuffIconBorderAnimationInset = 0,
    missingBuffIconBorderAnimationLength = 8,
    missingBuffIconBorderAnimationMask = false,
    missingBuffIconBorderAnimationOffsetX = 0,
    missingBuffIconBorderAnimationOffsetY = 0,
    missingBuffIconBorderAnimationParticles = 8,
    missingBuffIconBorderAnimationProcStart = false,
    missingBuffIconBorderAnimationScale = 1,
    missingBuffIconBorderAnimationSidesAxis = "HORIZONTAL",
    missingBuffIconBorderAnimationThickness = 3,
    missingBuffIconBorderAnimationType = "NONE",
    missingBuffIconBorderBlendMode = "BLEND",
    missingBuffIconBorderColor = {r = 1, g = 0, b = 0, a = 1},
    missingBuffIconBorderColorSource = "STATIC",
    missingBuffIconBorderGradientDirection = "HORIZONTAL",
    missingBuffIconBorderGradientEndColor = {r = 0.5, g = 0.5, b = 0.5, a = 1},
    missingBuffIconBorderGradientStartColor = {r = 0, g = 0, b = 0, a = 1},
    missingBuffIconBorderInset = 0,
    missingBuffIconBorderOffsetX = 0,
    missingBuffIconBorderOffsetY = 0,
    missingBuffIconBorderShadowColor = {r = 0, g = 0, b = 0, a = 0.8},
    missingBuffIconBorderShadowEnabled = false,
    missingBuffIconBorderShadowOffsetX = 1,
    missingBuffIconBorderShadowOffsetY = -1,
    missingBuffIconBorderShadowSize = 1,
    missingBuffIconBorderSize = 2,
    missingBuffIconBorderStyle = "SOLID",
    missingBuffIconBorderTexture = "SOLID",
    missingBuffIconDebug = false,
    missingBuffIconEnabled = true,
    missingBuffIconFrameLevel = 0,
    missingBuffIconScale = 1.2000000476837,
    missingBuffIconShowBorder = true,
    missingBuffIconSize = 24,
    missingBuffIconX = 0,
    missingBuffIconY = 0,

    -- My Buff Indicator (DEPRECATED — hidden from UI, force-disabled on load)

    -- Name Text
    nameColorClass = false,
    nameFont = "DF Roboto SemiBold",
    nameFontSize = 13,
    nameTextAnchor = "TOP",
    nameTextColor = {r = 1, g = 1, b = 1, a = 1},
    nameTextLength = 10,
    nameTextOutline = "SHADOW",
    nameTextTruncateMode = "ELLIPSIS",
    nameTextUseClassColor = false,
    nameTextX = 0,
    nameTextY = -6,

    -- Out of Range
    oorAbsorbBarAlpha = 0.20000000298023,
    oorAurasAlpha = 0.20000000298023,
    oorBackgroundAlpha = 0.10000000149012,
    oorBorderAlpha = 0.20000000298023,
    oorDefensiveIconAlpha = 0.5,
    oorDispelOverlayAlpha = 0.20000000298023,
    oorEnabled = false,
    oorHealthBarAlpha = 0.20000000298023,
    oorHealthTextAlpha = 0.25,
    oorIconsAlpha = 0.5,
    oorMissingBuffAlpha = 0.5,
    oorMissingHealthAlpha = 0.20000000298023,
    oorNameTextAlpha = 1,
    oorTextAlpha = 0.55,  -- unified OOR alpha for ALL Text Designer text (replaces the per-element name/health text alphas, which are legacy)
    oorPowerBarAlpha = 0.20000000298023,
    oorTargetedSpellAlpha = 0.5,
    oorAuraDesignerAlpha = 0.20000000298023,

    -- Personal Targeted Spells (Nameplate)
    personalTargetedSpellAlpha = 1,
    personalTargetedSpellBorderAnimationColor = {r = 0.95, g = 0.95, b = 0.32, a = 1},
    personalTargetedSpellBorderAnimationCornerLength = 10,
    personalTargetedSpellBorderAnimationFrequency = 0.25,
    personalTargetedSpellBorderAnimationInset = 0,
    personalTargetedSpellBorderAnimationLength = 8,
    personalTargetedSpellBorderAnimationMask = false,
    personalTargetedSpellBorderAnimationOffsetX = 0,
    personalTargetedSpellBorderAnimationOffsetY = 0,
    personalTargetedSpellBorderAnimationParticles = 8,
    personalTargetedSpellBorderAnimationProcStart = false,
    personalTargetedSpellBorderAnimationScale = 1,
    personalTargetedSpellBorderAnimationSidesAxis = "HORIZONTAL",
    personalTargetedSpellBorderAnimationThickness = 3,
    personalTargetedSpellBorderAnimationType = "NONE",
    personalTargetedSpellBorderBlendMode = "BLEND",
    personalTargetedSpellBorderColor = {r = 1, g = 0.3, b = 0, a = 1},
    personalTargetedSpellBorderGradientDirection = "HORIZONTAL",
    personalTargetedSpellBorderGradientEndColor = {r = 0.5, g = 0.5, b = 0.5, a = 1},
    personalTargetedSpellBorderGradientStartColor = {r = 0, g = 0, b = 0, a = 1},
    personalTargetedSpellBorderInset = 0,
    personalTargetedSpellBorderShadowColor = {r = 0, g = 0, b = 0, a = 0.8},
    personalTargetedSpellBorderShadowEnabled = false,
    personalTargetedSpellBorderShadowOffsetX = 1,
    personalTargetedSpellBorderShadowOffsetY = -1,
    personalTargetedSpellBorderShadowSize = 1,
    personalTargetedSpellBorderSize = 2,
    personalTargetedSpellBorderStyle = "SOLID",
    personalTargetedSpellBorderTexture = "SOLID",
    personalTargetedSpellDurationColor = {r = 1, g = 1, b = 1},
    personalTargetedSpellDurationFont = "DF Roboto SemiBold",
    personalTargetedSpellDurationOutline = "SHADOW",
    personalTargetedSpellDurationScale = 1.2,
    personalTargetedSpellDurationX = 0,
    personalTargetedSpellDurationY = 0,
    personalTargetedSpellEnabled = false,
    personalTargetedSpellGrowth = "RIGHT",
    personalTargetedSpellHighlightColor = {r = 1, g = 0.8, b = 0},
    personalTargetedSpellHighlightImportant = true,
    personalTargetedSpellHighlightInset = 3,
    personalTargetedSpellHighlightSize = 3,
    personalTargetedSpellHighlightStyle = "glow",
    personalTargetedSpellImportantBorderAnimationColor = {r = 1, g = 0.8, b = 0, a = 1},
    personalTargetedSpellImportantBorderAnimationCornerLength = 10,
    personalTargetedSpellImportantBorderAnimationFrequency = 1,
    personalTargetedSpellImportantBorderAnimationInset = 2,
    personalTargetedSpellImportantBorderAnimationLength = 8,
    personalTargetedSpellImportantBorderAnimationMask = false,
    personalTargetedSpellImportantBorderAnimationOffsetX = 0,
    personalTargetedSpellImportantBorderAnimationOffsetY = 0,
    personalTargetedSpellImportantBorderAnimationParticles = 8,
    personalTargetedSpellImportantBorderAnimationProcStart = true,
    personalTargetedSpellImportantBorderAnimationScale = 1,
    personalTargetedSpellImportantBorderAnimationSidesAxis = "HORIZONTAL",
    personalTargetedSpellImportantBorderAnimationThickness = 3,
    personalTargetedSpellImportantBorderAnimationType = "DF_PROC",
    personalTargetedSpellImportantBorderBlendMode = "BLEND",
    personalTargetedSpellImportantBorderColor = {r = 1, g = 0.8, b = 0, a = 0.5},
    personalTargetedSpellImportantBorderGradientDirection = "HORIZONTAL",
    personalTargetedSpellImportantBorderGradientEndColor = {r = 0.5, g = 0.5, b = 0.5, a = 1},
    personalTargetedSpellImportantBorderGradientStartColor = {r = 0, g = 0, b = 0, a = 1},
    personalTargetedSpellImportantBorderInset = -2,
    personalTargetedSpellImportantBorderShadowColor = {r = 0, g = 0, b = 0, a = 0.8},
    personalTargetedSpellImportantBorderShadowEnabled = false,
    personalTargetedSpellImportantBorderShadowOffsetX = 1,
    personalTargetedSpellImportantBorderShadowOffsetY = -1,
    personalTargetedSpellImportantBorderShadowSize = 1,
    personalTargetedSpellImportantBorderSize = 2,
    personalTargetedSpellImportantBorderStyle = "SOLID",
    personalTargetedSpellImportantBorderTexture = "SOLID",
    personalTargetedSpellImportantOnly = false,
    personalTargetedSpellInArena = true,
    personalTargetedSpellInBattlegrounds = true,
    personalTargetedSpellInDungeons = true,
    personalTargetedSpellInOpenWorld = true,
    personalTargetedSpellInRaids = true,
    personalTargetedSpellInterruptedDuration = 0.5,
    personalTargetedSpellInterruptedShowX = true,
    personalTargetedSpellInterruptedTintAlpha = 0.5,
    personalTargetedSpellInterruptedTintColor = {r = 1, g = 0, b = 0},
    personalTargetedSpellInterruptedXColor = {r = 1, g = 0, b = 0},
    personalTargetedSpellInterruptedXSize = 20,
    personalTargetedSpellMaxIcons = 5,
    personalTargetedSpellScale = 1,
    personalTargetedSpellShowBorder = true,
    personalTargetedSpellShowDuration = true,
    personalTargetedSpellShowInterrupted = true,
    personalTargetedSpellShowSwipe = true,
    personalTargetedSpellSize = 40,
    personalTargetedSpellSpacing = 6,
    personalTargetedSpellX = 0,
    personalTargetedSpellY = -150,

    -- Pet Frames
    petAnchor = "BOTTOM",
    petBackgroundColor = {r = 0.9254902601242065, g = 0.9254902601242065, b = 0.9254902601242065, a = 0.800000011920929},
    petBorderBlendMode = "BLEND",
    petBorderColor = {r = 0, g = 0, b = 0, a = 1},
    petBorderGradientDirection = "HORIZONTAL",
    petBorderGradientEndColor = {r = 0.5, g = 0.5, b = 0.5, a = 1},
    petBorderGradientStartColor = {r = 0, g = 0, b = 0, a = 1},
    petBorderInset = 0,
    petBorderShadowColor = {r = 0, g = 0, b = 0, a = 0.8},
    petBorderShadowEnabled = false,
    petBorderShadowOffsetX = 1,
    petBorderShadowOffsetY = -1,
    petBorderShadowSize = 1,
    petBorderSize = 1,
    petBorderStyle = "SOLID",
    petBorderTexture = "SOLID",
    petEnabled = false,
    petFrameHeight = 22,
    petFrameWidth = 130,
    petGroupAnchor = "BOTTOM",
    petGroupGrowth = "HORIZONTAL",
    petGroupLabel = "Pets",
    petGroupMode = "ATTACHED",
    petGroupOffsetX = 5,
    petGroupOffsetY = -10,
    petGroupShowLabel = true,
    petGroupSpacing = 2,
    petHealthAnchor = "RIGHT",
    petHealthBgColor = {r = 0.2, g = 0.2, b = 0.2, a = 0.8},
    petHealthColor = {r = 0, g = 0, b = 0, a = 1},
    petHealthColorMode = "HEALTH",
    petHealthFont = "DF Roboto SemiBold",
    petHealthFontOutline = "SHADOW",
    petHealthFontSize = 10,
    petHealthTextColor = {r = 1, g = 1, b = 1},
    petHealthX = -2,
    petHealthY = 0,
    petMatchOwnerHeight = false,
    petMatchOwnerWidth = true,
    petNameAnchor = "CENTER",
    petNameColor = {r = 1, g = 1, b = 1},
    petNameFont = "DF Roboto SemiBold",
    petNameFontOutline = "SHADOW",
    petNameFontSize = 11,
    petNameMaxLength = 8,
    petNameX = 0,
    petNameY = 0,
    petOffsetX = 0,
    petOffsetY = -1,
    petPowerBarHeight = 4,
    petPowerColor = {r = 0.2, g = 0.4, b = 0.9},
    petPowerColorMode = "POWER",
    petShowBorder = true,
    petShowHealthText = true,
    petShowPowerBar = false,
    petTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist",

    -- Phased Icon
    phasedIconAlpha = 1,
    phasedIconAnchor = "CENTER",
    phasedIconEnabled = true,
    phasedIconFrameLevel = 0,
    phasedIconHideInCombat = true,
    phasedIconScale = 1.5,
    phasedIconShowLFGEye = true,
    phasedIconShowText = false,
    phasedIconText = "Phased",
    phasedIconTextColor = {r = 0.5, g = 0.5, b = 1},
    phasedIconX = 0,
    phasedIconY = 0,

    -- Power Bar
    powerBarHeight = 4,
    showPowerBar = false,

    -- Raid Layout
    raidAnchorX = -6.666610717773438,
    raidAnchorY = -25,
    raidEnabled = true,
    raidFlatColumnAnchor = "START",
    raidFlatFrameAnchor = "START",
    raidFlatGrowthAnchor = "TOPLEFT",
    raidFlatHorizontalSpacing = 2,
    raidFlatPlayerAnchor = "CENTER",
    raidFlatReverseFillOrder = false,
    raidFlatVerticalSpacing = 2,
    raidGroupAnchor = "CENTER",
    raidGroupDisplayOrder = {1, 2, 3, 4, 5, 6, 7, 8},
    raidGroupOrder = "NORMAL",
    raidGroupRowGrowth = "START",
    raidGroupSpacing = -1,
    raidGroupVisible = {true, true, true, true, true, true, true, true},
    raidGroupsPerRow = 8,
    raidLocked = true,
    raidPlayerAnchor = "START",
    raidPlayersPerRow = 5,
    raidRoleIconAlpha = 1,
    raidRoleIconAnchor = "BOTTOMLEFT",
    raidRoleIconEnabled = false,
    raidRoleIconFrameLevel = 0,
    raidRoleIconHideInCombat = true,
    raidRoleIconScale = 1.400000095367432,
    raidRoleIconShowAssist = true,
    raidRoleIconShowTank = true,
    raidRoleIconShowText = false,
    raidRoleIconTextAssist = "MA",
    raidRoleIconTextColor = {r = 1, g = 1, b = 0},
    raidRoleIconTextTank = "MT",
    raidRoleIconX = 5,
    raidRoleIconY = 3,
    raidRowColSpacing = 30,
    raidTargetIconAlpha = 1,
    raidTargetIconAnchor = "TOP",
    raidTargetIconEnabled = true,
    raidTargetIconFrameLevel = 0,
    raidTargetIconHide = false,
    raidTargetIconHideInCombat = false,
    raidTargetIconScale = 1.1000000238419,
    raidTargetIconX = 36,
    raidTargetIconY = 5,
    raidTestFrameCount = 40,
    raidUseGroups = true,

    -- Range Check
    rangeAlpha = 0.5,
    rangeCheckEnabled = true,
    rangeCheckSpellID = 0,
    rangeFadeAlpha = 0.40000000596046,
    rangeUpdateInterval = 0.5,

    -- Ready Check Icon
    readyCheckIconAlpha = 1,
    readyCheckIconAnchor = "CENTER",
    readyCheckIconEnabled = true,
    readyCheckIconFrameLevel = 0,
    readyCheckIconHide = false,
    readyCheckIconHideInCombat = false,
    readyCheckIconPersist = 6,
    readyCheckIconScale = 1.6000000238419,
    readyCheckIconX = 0,
    readyCheckIconY = 0,

    -- Resource Bar
    resourceBarAnchor = "BOTTOM",
    resourceBarBackgroundColor = {r = 0, g = 0, b = 0, a = 0.80000001192093},
    resourceBarBackgroundEnabled = true,
    resourceBarBorderBlendMode = "BLEND",
    resourceBarBorderColor = {r = 0, g = 0, b = 0, a = 1},
    resourceBarBorderColorSource = "STATIC",
    resourceBarBorderEnabled = false,
    resourceBarBorderGradientDirection = "HORIZONTAL",
    resourceBarBorderGradientEndColor = {r = 0.5, g = 0.5, b = 0.5, a = 1},
    resourceBarBorderGradientStartColor = {r = 0, g = 0, b = 0, a = 1},
    resourceBarBorderInset = 0,
    resourceBarBorderShadowColor = {r = 0, g = 0, b = 0, a = 0.8},
    resourceBarBorderShadowEnabled = false,
    resourceBarBorderShadowOffsetX = 1,
    resourceBarBorderShadowOffsetY = -1,
    resourceBarBorderShadowSize = 1,
    resourceBarBorderSize = 1,
    resourceBarBorderStyle = "SOLID",
    resourceBarBorderTexture = "SOLID",
    resourceBarShowBorder = false,
    resourceBarClassFilter = {
        DEATHKNIGHT = true,
        DEMONHUNTER = true,
        DRUID = true,
        EVOKER = true,
        HUNTER = true,
        MAGE = true,
        MONK = true,
        PALADIN = true,
        PRIEST = true,
        ROGUE = true,
        SHAMAN = true,
        WARLOCK = true,
        WARRIOR = true,
    },
    resourceBarClassColor = false,
    resourceBarColorMode = "POWER_TYPE",
    resourceBarCustomColor = {r = 0, g = 0.5, b = 1, a = 1},
    resourceBarEnabled = true,
    resourceBarFrameLevel = 20,
    resourceBarHeight = 4,
    resourceBarMatchWidth = true,
    resourceBarOrientation = "HORIZONTAL",
    resourceBarReverseFill = false,
    resourceBarShowDPS = false,
    resourceBarShowHealer = true,
    resourceBarShowInSoloMode = true,
    resourceBarShowTank = false,
    resourceBarSmooth = true,
    resourceBarTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist",
    resourceBarWidth = 60,
    resourceBarX = 0,
    resourceBarY = 1,

    -- Rested Indicator
    restedIndicator = false,
    restedIndicatorAnchor = "TOPRIGHT",
    restedIndicatorGlow = false,
    restedIndicatorIcon = true,
    restedIndicatorOffsetX = -18,
    restedIndicatorOffsetY = -14,
    restedIndicatorSize = 20,

    -- Resurrection Icon
    resurrectionIconAlpha = 1,
    resurrectionIconAnchor = "CENTER",
    resurrectionIconEnabled = true,
    resurrectionIconFrameLevel = 0,
    resurrectionIconScale = 1.600000023841858,
    resurrectionIconShowText = false,
    resurrectionIconTextCasting = "Res...",
    resurrectionIconTextColor = {r = 0.2, g = 1, b = 0.2},
    resurrectionIconTextPending = "Res Ready",
    resurrectionIconX = 0,
    resurrectionIconY = 0,

    -- Role Icon
    roleIconAlpha = 1,
    roleIconAnchor = "TOPLEFT",
    roleIconFrameLevel = 0,
    roleIconHide = false,
    roleIconHideDPS = true,
    roleIconHideHealer = false,
    roleIconHideOnlyInCombat = true,
    roleIconHideTank = true,
    roleIconExternalDPS = "",
    roleIconExternalHealer = "",
    roleIconExternalTank = "",
    roleIconHideInCombat = false,
    roleIconScale = 1,
    roleIconShowDPS = true,
    roleIconShowHealer = true,
    roleIconShowTank = true,
    roleIconStyle = "CUSTOM",
    roleIconX = 2,
    roleIconY = -2,
    showRoleIcon = true,

    -- Selection Highlight
    selectionHighlightAlpha = 1,
    selectionHighlightColor = {r = 1, g = 1, b = 1, a = 1},
    selectionHighlightInset = 0,
    selectionHighlightMode = "SOLID",
    selectionHighlightThickness = 1,

    -- Smooth Bars & Solo Mode
    smoothBars = true,
    soloMode = true,

    -- Sorting
    sortAlphabetical = false,
    sortByClass = false,
    sortClassOrder = {
        "DEATHKNIGHT",
        "DEMONHUNTER",
        "DRUID",
        "EVOKER",
        "HUNTER",
        "MAGE",
        "MONK",
        "PALADIN",
        "PRIEST",
        "SHAMAN",
        "ROGUE",
        "WARLOCK",
        "WARRIOR",
    },
    sortEnabled = true,
    sortRoleOrder = {"TANK", "HEALER", "MELEE", "RANGED"},
    sortSelfPosition = "SORTED",
    sortSeparateMeleeRanged = false,
    useFrameSort = false,

    -- Status Icon & Text
    statusIconFont = "DF Roboto SemiBold",
    statusIconFontOutline = "SHADOW",
    statusIconFontSize = 11,
    statusTextAnchor = "CENTER",
    statusTextColor = {r = 1, g = 1, b = 1, a = 1},
    statusTextEnabled = true,
    statusTextFont = "DF Roboto SemiBold",
    statusTextFontSize = 14,
    statusTextOutline = "SHADOW",
    statusTextX = 0,
    statusTextY = 6,

    -- Summon Icon
    summonIconAlpha = 1,
    summonIconAnchor = "CENTER",
    summonIconEnabled = true,
    summonIconFrameLevel = 0,
    summonIconHideInCombat = false,
    summonIconScale = 1.5,
    summonIconShowText = false,
    summonIconTextAccepted = "Accepted",
    summonIconTextColor = {r = 0.6, g = 0.2, b = 1},
    summonIconTextDeclined = "Declined",
    summonIconTextPending = "Summon",
    summonIconX = 0,
    summonIconY = 0,

    -- BG Objective Carrier Icon (flag / orb carrier)
    bgCarrierIconAlpha = 1,
    bgCarrierIconAnchor = "CENTER",
    bgCarrierIconEnabled = true,
    bgCarrierIconFrameLevel = 0,
    bgCarrierIconScale = 1,
    bgCarrierIconShowText = false,
    bgCarrierIconText = "FC",
    bgCarrierIconTextColor = {r = 1, g = 0.82, b = 0},
    bgCarrierIconX = 0,
    bgCarrierIconY = 0,
    -- Combat icon (crossed swords shown when a unit is in combat)
    combatIconAlpha = 1,
    combatIconAnchor = "TOP",
    combatIconEnabled = false,
    combatIconFrameLevel = 0,
    combatIconScale = 1.2,
    combatIconX = 0,
    combatIconY = 6,

    -- Targeted Spells (on-frame)
    targetedSpellAlpha = 1,
    targetedSpellAnchor = "BOTTOM",
    targetedSpellBorderAnimationColor = {r = 0.95, g = 0.95, b = 0.32, a = 1},
    targetedSpellBorderAnimationCornerLength = 10,
    targetedSpellBorderAnimationFrequency = 0.25,
    targetedSpellBorderAnimationInset = 0,
    targetedSpellBorderAnimationLength = 8,
    targetedSpellBorderAnimationMask = false,
    targetedSpellBorderAnimationOffsetX = 0,
    targetedSpellBorderAnimationOffsetY = 0,
    targetedSpellBorderAnimationParticles = 8,
    targetedSpellBorderAnimationProcStart = false,
    targetedSpellBorderAnimationScale = 1,
    targetedSpellBorderAnimationSidesAxis = "HORIZONTAL",
    targetedSpellBorderAnimationThickness = 3,
    targetedSpellBorderAnimationType = "NONE",
    targetedSpellBorderBlendMode = "BLEND",
    targetedSpellBorderColor = {r = 1, g = 0.3, b = 0},
    targetedSpellBorderGradientDirection = "HORIZONTAL",
    targetedSpellBorderGradientEndColor = {r = 0.5, g = 0.5, b = 0.5, a = 1},
    targetedSpellBorderGradientStartColor = {r = 0, g = 0, b = 0, a = 1},
    targetedSpellBorderInset = 0,
    targetedSpellBorderShadowColor = {r = 0, g = 0, b = 0, a = 0.8},
    targetedSpellBorderShadowEnabled = false,
    targetedSpellBorderShadowOffsetX = 1,
    targetedSpellBorderShadowOffsetY = -1,
    targetedSpellBorderShadowSize = 1,
    targetedSpellBorderSize = 2,
    targetedSpellBorderStyle = "SOLID",
    targetedSpellBorderTexture = "SOLID",
    targetedSpellImportantBorderAnimationColor = {r = 1, g = 0.8, b = 0, a = 1},
    targetedSpellImportantBorderAnimationCornerLength = 10,
    targetedSpellImportantBorderAnimationFrequency = 1,
    targetedSpellImportantBorderAnimationInset = 2,
    targetedSpellImportantBorderAnimationLength = 8,
    targetedSpellImportantBorderAnimationMask = false,
    targetedSpellImportantBorderAnimationOffsetX = 0,
    targetedSpellImportantBorderAnimationOffsetY = 0,
    targetedSpellImportantBorderAnimationParticles = 8,
    targetedSpellImportantBorderAnimationProcStart = true,
    targetedSpellImportantBorderAnimationScale = 1,
    targetedSpellImportantBorderAnimationSidesAxis = "HORIZONTAL",
    targetedSpellImportantBorderAnimationThickness = 3,
    targetedSpellImportantBorderAnimationType = "DF_PROC",
    targetedSpellImportantBorderBlendMode = "BLEND",
    targetedSpellImportantBorderColor = {r = 1, g = 0.8, b = 0, a = 0.5},
    targetedSpellImportantBorderGradientDirection = "HORIZONTAL",
    targetedSpellImportantBorderGradientEndColor = {r = 0.5, g = 0.5, b = 0.5, a = 1},
    targetedSpellImportantBorderGradientStartColor = {r = 0, g = 0, b = 0, a = 1},
    targetedSpellImportantBorderInset = -2,
    targetedSpellImportantBorderShadowColor = {r = 0, g = 0, b = 0, a = 0.8},
    targetedSpellImportantBorderShadowEnabled = false,
    targetedSpellImportantBorderShadowOffsetX = 1,
    targetedSpellImportantBorderShadowOffsetY = -1,
    targetedSpellImportantBorderShadowSize = 1,
    targetedSpellImportantBorderSize = 2,
    targetedSpellImportantBorderStyle = "SOLID",
    targetedSpellImportantBorderTexture = "SOLID",
    targetedSpellDurationColor = {r = 1, g = 1, b = 1},
    targetedSpellDurationFont = "DF Roboto SemiBold",
    targetedSpellDurationOutline = "SHADOW",
    targetedSpellDurationScale = 1,
    targetedSpellDurationX = 0,
    targetedSpellDurationY = 0,
    targetedSpellEnabled = false,
    targetedSpellFrameLevel = 0,
    targetedSpellGrowth = "CENTER_H",
    targetedSpellHideSwipe = false,
    targetedSpellHighlightColor = {r = 1, g = 0.8, b = 0},
    targetedSpellHighlightImportant = true,
    targetedSpellHighlightInset = 2,
    targetedSpellHighlightSize = 3,
    targetedSpellHighlightStyle = "glow",
    targetedSpellImportantOnly = false,
    targetedSpellInArena = true,
    targetedSpellInBattlegrounds = true,
    targetedSpellInDungeons = true,
    targetedSpellInOpenWorld = true,
    targetedSpellInRaids = true,
    targetedSpellInterruptedDuration = 0.5,
    targetedSpellInterruptedShowX = true,
    targetedSpellInterruptedTintAlpha = 0.5,
    targetedSpellInterruptedTintColor = {r = 1, g = 0, b = 0},
    targetedSpellInterruptedXColor = {r = 1, g = 0, b = 0},
    targetedSpellInterruptedXSize = 16,
    targetedSpellMaxIcons = 3,
    targetedSpellNameplateOffscreen = false,
    targetedSpellScale = 1,
    targetedSpellShowBorder = true,
    targetedSpellShowDuration = true,
    targetedSpellShowInterrupted = true,
    targetedSpellSize = 24,
    targetedSpellSortByTime = true,
    targetedSpellSortNewestFirst = true,
    targetedSpellSpacing = 6,
    targetedSpellWarnDuplicates = true,
    targetedSpellX = 0,
    targetedSpellY = -30,

    -- Targeted List (party-mode only)
    -- Stacked cast-bar display showing enemy casts targeting party members.
    -- User-facing name ("Targeted List") is intentionally decoupled from the
    -- internal `targetedList*` db prefix so the feature can be renamed later
    -- by editing locale strings only. Party-mode only by design.
    -- Position uses an absolute mover (targetedListX/Y), not an anchor point.
    targetedListBackgroundAlpha = 0.5,
    targetedListBorderBlendMode = "BLEND",
    targetedListBorderColor = {r = 0.18, g = 0.18, b = 0.18, a = 1},
    targetedListBorderGradientDirection = "HORIZONTAL",
    targetedListBorderGradientEndColor = {r = 0.5, g = 0.5, b = 0.5, a = 1},
    targetedListBorderGradientStartColor = {r = 0, g = 0, b = 0, a = 1},
    targetedListBorderInset = 0,
    targetedListBorderShadowColor = {r = 0, g = 0, b = 0, a = 0.8},
    targetedListBorderShadowEnabled = false,
    targetedListBorderShadowOffsetX = 1,
    targetedListBorderShadowOffsetY = -1,
    targetedListBorderShadowSize = 1,
    targetedListBorderSize = 1,
    targetedListBorderStyle = "SOLID",
    targetedListBorderTexture = "SOLID",
    targetedListEnabled = false,
    targetedListFadeOutDuration = 0.25,
    targetedListFont = "DF Roboto SemiBold",
    targetedListFontOutline = "SHADOW",
    targetedListFontSize = 11,
    targetedListSpellNameFontSize = 0,
    targetedListTargetNameFontSize = 0,
    targetedListGrowth = "DOWN",
    targetedListHeight = 22,
    targetedListHideOwnCasts = false,
    targetedListHideOutOfCombat = true,
    targetedListHighlightImportant = true,
    targetedListHighlightColor = {r = 1, g = 0.8, b = 0, a = 1},
    targetedListIconPosition = "LEFT",
    targetedListImportantOnly = false,
    targetedListInArena = true,
    targetedListInBattlegrounds = true,
    targetedListInDungeons = true,
    targetedListInOpenWorld = true,
    targetedListInRaids = false,
    targetedListInterruptedFlashDuration = 2.0,
    targetedListInterruptibleColor = {r = 1, g = 0.494, b = 0.137, a = 1},
    targetedListMaxBars = 6,
    targetedListShowArrowPrefix = true,
    targetedListShowArrowSuffix = false,
    targetedListShowBorder = true,
    targetedListShowUntargeted = true,
    targetedListShowDuration = true,
    targetedListShowIcon = true,
    targetedListShowSpellName = true,
    targetedListShowTargetName = true,
    targetedListSortOrder = "OLDEST",
    targetedListSpacing = 6,
    targetedListStylePreset = "DEFAULT",
    targetedListTargetNameClassColor = true,
    targetedListTexture = "Interface\\Buttons\\WHITE8x8",
    targetedListUninterruptibleColor = {r = 0.8, g = 0.302, b = 0.302, a = 1},
    targetedListSelfTargetColorEnabled = true,
    targetedListSelfTargetColor = {r = 0.02, g = 0.776, b = 0.4, a = 0.2},
    targetedListWidth = 240,
    targetedListX = 0,
    targetedListY = -10,
    targetedListZoomIcon = true,
    -- Per-text-element anchor + offset. Anchor is a point name
    -- (LEFT / CENTER / RIGHT) applied within the bar's progress
    -- region. X / Y are pixel offsets from that anchor.
    targetedListSpellNameAnchor = "LEFT",
    targetedListSpellNameAlign = "LEFT",
    targetedListSpellNameWidth = 0,
    targetedListSpellNameX = 4,
    targetedListSpellNameY = 0,
    targetedListTargetNameAnchor = "RIGHT",
    targetedListTargetNameAlign = "RIGHT",
    targetedListTargetNameWidth = 0,
    targetedListTargetNameX = -4,
    targetedListTargetNameY = 0,
    targetedListDurationAnchor = "RIGHT",
    targetedListDurationAlign = "RIGHT",
    targetedListDurationFontSize = 17,
    targetedListDurationX = 30,
    targetedListDurationY = 0,
    targetedListInterruptTextAnchor = "CENTER",
    targetedListInterruptTextAlign = "CENTER",
    targetedListInterruptTextFontSize = 12,
    targetedListInterruptTextWidth = 0,
    targetedListInterruptTextX = 0,
    targetedListInterruptTextY = 0,

    -- Test Mode
    -- testShowTargetedList drives the Targeted List demo bars in party
    -- test mode. There is no raid-mode equivalent because the
    -- Targeted List itself is party-only.
    testShowTargetedList = false,
    testAnimateTargetedList = true,
    testAnimateHealth = false,
    testBuffCount = 2,
    testDebuffCount = 2,
    testFrameCount = 5,
    testPreset = "STATIC",
    testShowAbsorbs = false,
    testShowAggro = false,
    testShowAuras = false,
    testShowDispelGlow = false,
    testShowExternalDef = false,
    testShowHealPrediction = false,
    testShowMissingBuff = false,
    testShowOutOfRange = false,
    testShowPets = true,
    testShowReducedMaxHealth = true,
    testShowSelection = false,
    testShowStatusIcons = true,
    testShowTargetedSpell = true,
    testShowPersonalTargeted = true,
    testShowAuraDesigner = false,
    testShowTextDesigner = true,

    -- Tooltip settings
    tooltipAuraAnchor = "DEFAULT",
    tooltipAuraDisableInCombat = false,
    tooltipAuraEnabled = true,
    tooltipAuraX = 0,
    tooltipAuraY = 0,
    tooltipBuffAnchor = "FRAME",
    tooltipBuffAnchorPos = "BOTTOMRIGHT",
    tooltipBuffDisableInCombat = true,
    tooltipBuffEnabled = true,
    tooltipBuffX = 0,
    tooltipBuffY = -10,
    tooltipDebuffAnchor = "FRAME",
    tooltipDebuffAnchorPos = "BOTTOMLEFT",
    tooltipDebuffDisableInCombat = false,
    tooltipDebuffEnabled = true,
    tooltipDebuffX = 0,
    tooltipDebuffY = -10,
    tooltipDefensiveAnchor = "CURSOR",
    tooltipDefensiveAnchorPos = "BOTTOMRIGHT",
    tooltipDefensiveDisableInCombat = false,
    tooltipDefensiveEnabled = true,
    tooltipResurrectionEnabled = false,
    tooltipDefensiveX = 0,
    tooltipDefensiveY = 0,
    tooltipBindingAnchor = "FRAME",
    tooltipBindingAnchorPos = "TOPRIGHT",
    tooltipBindingDisableInCombat = false,
    tooltipBindingEnabled = false,
    tooltipBindingX = 4,
    tooltipBindingY = 0,
    tooltipFrameAnchor = "DEFAULT",
    tooltipFrameAnchorPos = "BOTTOMRIGHT",
    tooltipFrameDisableInCombat = true,
    tooltipFrameEnabled = true,
    tooltipFrameX = 0,
    tooltipFrameY = 0,

    -- Secure Headers
    useSecureHeaders = true,

    -- Vehicle Icon
    vehicleIconAlpha = 1,
    vehicleIconAnchor = "BOTTOMRIGHT",
    vehicleIconEnabled = true,
    vehicleIconFrameLevel = 0,
    vehicleIconHideInCombat = false,
    vehicleIconScale = 1.5,
    vehicleIconShowText = true,
    vehicleIconText = "Vehicle",
    vehicleIconTextColor = {r = 0.4, g = 0.8, b = 1},
    vehicleIconX = -12,
    vehicleIconY = 1,

    -- Pinned Frames
    -- NOTE: scale and width/height are intentionally omitted — pinned frames
    -- INHERIT those from the Based-on mode's main frames unless the user overrides
    -- them per set (set.scale / customWidth / customHeight). growDirection,
    -- unitsPerRow, spacing and the frame/column anchors are pinned-ONLY settings.
    pinnedFrames = {
        -- Keep pinned frames dormant in all instanced PvP (arena + battlegrounds).
        -- The runtime gate reads the current mode's copy (arena resolves to party
        -- config, BG to raid), so the "Disable in PvP" toggle writes both modes in
        -- lockstep to act as one global switch — hence the key lives in each mode's
        -- defaults. Default true: pinned is a party/raid feature and the PvP event
        -- storm could exhaust the per-frame budget ("script ran too long").
        disableInPvP = true,
        sets = {
            [1] = {
                enabled = false,
                frameType = "player",
                testCount = 3,
                name = "Pinned 1",
                players = {},
                growDirection = "HORIZONTAL",
                unitsPerRow = 5,
                horizontalSpacing = 2,
                verticalSpacing = 2,
                position = { point = "CENTER", x = 0, y = 200 },
                showLabel = false,
                columnAnchor = "START",
                frameAnchor = "START",
                autoAddTanks = false,
                autoAddHealers = false,
                autoAddDPS = false,
                keepOfflinePlayers = false,
                manualPlayers = {},
            },
            [2] = {
                enabled = false,
                frameType = "player",
                testCount = 3,
                name = "Pinned 2",
                players = {},
                growDirection = "HORIZONTAL",
                unitsPerRow = 5,
                horizontalSpacing = 2,
                verticalSpacing = 2,
                position = { point = "CENTER", x = 0, y = -200 },
                showLabel = false,
                columnAnchor = "START",
                frameAnchor = "START",
                autoAddTanks = false,
                autoAddHealers = false,
                autoAddDPS = false,
                keepOfflinePlayers = false,
                manualPlayers = {},
            },
        },
    },

    -- Aura Designer
    auraDesigner = {
        enabled = false,
        spec = "auto",
        previewScale = 1.0,
        soundEnabled = true,
        soundChannel = "Master",
        defaults = {
            iconSize = 24,
            iconScale = 1.0,
            showDuration = true,
            showStacks = true,
            durationFont = "Friz Quadrata TT",
            durationScale = 1.0,
            durationOutline = "OUTLINE",
            durationAnchor = "CENTER",
            durationX = 0,
            durationY = 0,
            stackFont = "Friz Quadrata TT",
            stackScale = 1.0,
            stackOutline = "OUTLINE",
            stackAnchor = "BOTTOMRIGHT",
            stackX = 0,
            stackY = 0,
            iconBorderEnabled = true,
            iconBorderThickness = 1,
            stackMinimum = 2,
            durationColorByTime = false,
            durationColor = {r = 1, g = 1, b = 1, a = 1},
            stackColor = {r = 1, g = 1, b = 1, a = 1},
            hideIcon = false,
            indicatorFrameLevel = 30,
            indicatorFrameStrata = "INHERIT",
        },
        auras = {},
        layoutGroups = {},
        nextLayoutGroupID = 1,
    },

}

-- ============================================================
-- RAID DEFAULTS — GENERATED from PartyDefaults
-- ============================================================
-- Party and raid share every default except the handful below, and the old
-- hand-maintained ~1,250-line raid copy was pure duplication that could
-- silently drift (a key added to party but forgotten for raid). The raid
-- table is now BUILT from PartyDefaults at load time, so drift is impossible
-- by construction:
--   * RAID_DEFAULT_OVERRIDES  — keys whose raid default VALUE differs
--   * party-only keys         — the Targeted List feature family (party-scoped)
--     via prefix, plus three named stragglers
-- Table values are deep-copied so party/raid never share table references.

local RAID_DEFAULT_OVERRIDES = {
    defensiveBarMax = 3,      -- party: 4
    defensiveBarScale = 1.0,  -- party: 1.5
    defensiveIconSize = 20,   -- party: 30
}

local PARTY_ONLY_PREFIX = "targetedList"
local PARTY_ONLY_KEYS = {
    targetedSpellWarnDuplicates = true,
    testAnimateTargetedList = true,
    testShowTargetedList = true,
}

local function CopyDefaultsDeep(src)
    local t = {}
    for k, v in pairs(src) do
        if type(v) == "table" then
            t[k] = CopyDefaultsDeep(v)
        else
            t[k] = v
        end
    end
    return t
end

DF.RaidDefaults = (function()
    local t = CopyDefaultsDeep(DF.PartyDefaults)
    local remove = {}
    for k in pairs(t) do
        if k:sub(1, #PARTY_ONLY_PREFIX) == PARTY_ONLY_PREFIX or PARTY_ONLY_KEYS[k] then
            remove[#remove + 1] = k
        end
    end
    for _, k in ipairs(remove) do t[k] = nil end
    for k, v in pairs(RAID_DEFAULT_OVERRIDES) do t[k] = v end
    return t
end)()

-- ============================================================
-- RAID AUTO PROFILES DEFAULTS
-- ============================================================
-- Auto profiles allow automatic switching of raid frame settings
-- based on content type (instanced, open world, mythic) and raid size

DF.RaidAutoProfilesDefaults = {
    enabled = false,  -- Master enable for auto profiles feature
    
    -- Instanced/PvP content (raids, dungeons, battlegrounds, arenas)
    -- Range: 1-40 players
    instanced = {
        profiles = {}  -- Array of profiles: {name, min, max, overrides = {}}
    },
    
    -- Open World content (world bosses, outdoor groups)
    -- Range: 1-40 players
    openWorld = {
        profiles = {}  -- Array of profiles: {name, min, max, overrides = {}}
    },
    
    -- Mythic raiding (difficulty ID 16)
    -- Fixed at 20 players, no range needed
    mythic = {
        profile = nil  -- Single profile: {name = "Mythic Setup", overrides = {}} or nil if not configured
    },
}

function DF:GetGlobalDB()
    DandersFramesDB_v2 = DandersFramesDB_v2 or {}
    DandersFramesDB_v2.global = DandersFramesDB_v2.global or {}
    for k, v in pairs(DF.GlobalDefaults) do
        if DandersFramesDB_v2.global[k] == nil then
            DandersFramesDB_v2.global[k] = v
        end
    end
    return DandersFramesDB_v2.global
end
