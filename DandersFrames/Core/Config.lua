local addonName, DF = ...

-- Expose as global for other files and external access
DandersFrames = DF

-- ============================================================
-- MELEE / RANGED CLASSIFICATION — ONE TABLE, THREE FORMER COPIES
-- ============================================================
-- Used by "Separate Melee & Ranged DPS". Only consulted when role == DAMAGER, so
-- the tank specs listed below are inert and kept only so the set reads complete.
--
-- ☠ THIS EXISTED THREE TIMES AND THE COPIES DISAGREED, one of them live:
--   * Frames/Headers.lua  (live party + grouped raid) -- omitted PALADIN from the
--     class fallback AND [255] Survival Hunter from the spec table
--   * Features/FlatRaidFrames.lua (live flat raid)    -- had both
--   * Features/Sort.lua   (test preview)              -- had both, under a comment
--     claiming it "matches live fallback". It did not.
-- So a Ret Paladin whose spec was not yet inspected sorted MELEE in the preview and
-- in flat raid, and RANGED in live party and grouped raid. A Survival Hunter split
-- the same way. Headers was the outlier and the wrong one: a Paladin DAMAGER is
-- Retribution, which is melee. (Audit, 2026-08-07.)
DF.MELEE_SPECS = {
    [250] = true, [251] = true, [252] = true,   -- Death Knight (Blood/Frost/Unholy)
    [577] = true, [581] = true,                 -- Demon Hunter (Havoc/Vengeance)
    [103] = true,                               -- Druid    Feral
    [255] = true,                               -- Hunter   Survival
    [269] = true,                               -- Monk     Windwalker
    [70]  = true,                               -- Paladin  Retribution
    [259] = true, [260] = true, [261] = true,   -- Rogue
    [263] = true,                               -- Shaman   Enhancement
    [71]  = true, [72]  = true,                 -- Warrior  Arms/Fury
}

-- Class fallback for a DAMAGER whose spec is not known yet: only classes whose
-- damage spec is ALWAYS melee.
DF.MELEE_CLASSES = {
    DEATHKNIGHT = true, DEMONHUNTER = true, ROGUE = true, WARRIOR = true, PALADIN = true,
}

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

-- Raw outline string -> { shadow, flags, slug }. See the ☠ note in DF:SafeSetFont:
-- the parse allocates a capture string per call and that call is per FontString per
-- frame. Pure function of the key, so entries never go stale.
local outlineParseMemo = {}

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

-- Preload/validate a font to ensure WoW has it loaded.
--
-- Memoised per path. This runs on EVERY DF:SafeSetFont call, and SafeSetFont is one of
-- the hottest functions in the addon (5.7% of a boss trace's allocation just here), but
-- a path only ever needs loading once -- the file does not unload and the mapping from
-- path to file never changes. Keyed on ATTEMPTED rather than succeeded, which matches
-- the old behaviour exactly: the pcall result was discarded, so a failed load was never
-- retried anyway.
--
-- pcall(fn, args...) not pcall(function() ... end): the closure form allocated one
-- closure per call on that same hot path.
local preloadedFonts = {}
local function PreloadFont(fontPath)
    if not fontPath or preloadedFonts[fontPath] then return end
    preloadedFonts[fontPath] = true
    -- Attempt to set the font - this forces WoW to load the font file
    pcall(fontValidationString.SetFont, fontValidationString, fontPath, 12, "")
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
--
-- Sizes are QUANTIZED to half-point steps before keying/building. Two reasons:
-- (a) float noise — saved scales carry float32 artifacts (buffDurationScale default is
--     1.2000000476837), so 10*scale from two paths can differ in the 10th decimal and
--     would mint two families for the same visual size; (b) bounding — families are
--     permanent global font objects and scale sliders are continuous, so a drag with
--     per-tick updates would otherwise mint one family per tick. Half a point is below
--     visual perception at UI text sizes; the residual is absorbed, never SetTextScale'd.
local function QuantizeFontSize(size)
    size = tonumber(size) or BASE_FONT_SIZE
    return math.floor(size * 2 + 0.5) / 2
end
-- Single source of truth for the cache key: GetOrCreateFontFamily builds with it and
-- SafeSetFont's broken-family eviction must reproduce it exactly (a mismatched evict
-- key would strand the broken entry). Shadow stays LAST so RefreshFontFamilyShadows'
-- "|shadow" suffix check still identifies shadowed families.
-- ☠ The key STRING is memoised, not just the family it looks up.
-- GetOrCreateFontFamily calls this on every SafeSetFont to probe its cache, so
-- the four concats ran on every cache HIT too -- once per FontString per frame.
-- The input set is tiny (a handful of fonts x a few outlines x quantized sizes),
-- so a nested table costs three small tables per NEW combination and nothing
-- ever again, while the returned key stays a plain string: fontFamilies is still
-- string-keyed and the eviction in SafeSetFont still finds its entry.
local fontKeyMemo = {}
local function FontFamilyKey(fontPath, outline, useShadow, quantizedSize)
    local p = fontPath or "default"
    local byOutline = fontKeyMemo[p]
    if not byOutline then byOutline = {}; fontKeyMemo[p] = byOutline end
    local o = outline or ""
    local bySize = byOutline[o]
    if not bySize then bySize = {}; byOutline[o] = bySize end
    local byShadow = bySize[quantizedSize]
    if not byShadow then byShadow = {}; bySize[quantizedSize] = byShadow end
    local sh = useShadow and true or false
    local key = byShadow[sh]
    if not key then
        key = p:lower() .. "|" .. o .. "|" .. tostring(quantizedSize) .. "|" .. (sh and "shadow" or "noshadow")
        byShadow[sh] = key
    end
    return key
end
local fontFamilyCounter = 0
local function GetOrCreateFontFamily(fontPath, outline, useShadow, size)
    -- Check if CreateFontFamily API is available (WoW 11.x+)
    if not CreateFontFamily then
        return nil
    end
    size = QuantizeFontSize(size)

    local key = FontFamilyKey(fontPath, outline, useShadow, size)
    
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

-- Hoisted out of DF:SafeSetFont so the pcall below takes the allocation-free
-- pcall(fn, args...) form. It is two statements (the GameFontNormal set first is
-- deliberate — see the call site), so it cannot be inlined as a bare method reference.
local function setFontObjectPair(fontString, familyObject)
    fontString:SetFontObject(GameFontNormal)
    fontString:SetFontObject(familyObject)
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
    --
    -- ☠ MEMOISED because string.match WITH A CAPTURE ALLOCATES the captured
    -- substring on every call -- and this runs once per FontString per frame, twice
    -- over for any element carrying an AD mirror. It was 40.9% of all boss-fight
    -- allocation. The parse is a pure function of the raw outline string and the
    -- stored values come from a handful of dropdown options, so the memo fills once
    -- and never needs invalidating: a given string always parses the same way.
    local parsed = outlineParseMemo[outline]
    if not parsed then
        local shadow, flags = false, outline
        local rest = outline:match("^SHADOW;(.*)$")
        if rest then
            shadow, flags = true, rest
        elseif outline == "SHADOW" then
            shadow, flags = true, ""
        end
        -- Normalize "NONE" to empty string (NONE is not a valid WoW font flag)
        if flags == "NONE" then flags = "" end
        -- The SLUG variant is derived from `flags` alone, so it caches with it --
        -- the concat below used to run per call for every slug-eligible element.
        parsed = {
            shadow = shadow,
            flags  = flags,
            slug   = (flags == "") and "SLUG" or (flags .. ", SLUG"),
        }
        outlineParseMemo[outline] = parsed
    end
    local useShadow = parsed.shadow
    outline = parsed.flags

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
        -- Cached alongside the parse above; fontSlug only selects between the two
        -- precomputed variants, so toggling it needs no invalidation.
        actualOutline = parsed.slug
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
        local ok = pcall(setFontObjectPair, fontString, _G[fontFamilyName])
        if not ok then
            -- Evict the broken cache entry so it gets recreated later. Shared key
            -- builder + same size quantization as GetOrCreateFontFamily — a
            -- hand-rolled key here would drift (raw vs quantized size) and strand
            -- the broken entry in the cache forever.
            fontFamilies[FontFamilyKey(fontPath, actualOutline, useShadow, QuantizeFontSize(fontSize))] = nil
        else
            -- The family is built at the real point size now (per-size cache), so the
            -- glyphs render natively. Clear any fractional scale a prior SafeSetFont left
            -- on this fontstring — the old BASE_FONT_SIZE + SetTextScale(size/12) path was
            -- the source of the sub-pixel blur / off-centre drift that got worse with size.
            fontString:SetTextScale(1)

            -- Force WoW to re-render the text with new font properties
            -- This is needed because switching between font families with different outline flags
            -- may not immediately update the rendered text without a text refresh
            -- Note: the text may be a SECRET string (native cooldown countdown
            -- text, health text, unit names in combat). COMPARING a secret
            -- (text ~= "") is BLOCKED, and each blocked compare logs a
            -- DandersFrames taint incident even inside pcall — bugs #987/#988
            -- (hundreds/minute in PvP instances on live); on 12.1 this runs in
            -- the SecureGroupHeader's child-refresh path, so the taint poisoned
            -- the secure header + aura containers and froze auras in combat
            -- (taint.log: 168× Config.lua:773). Skip the re-render for secret
            -- text: issecretvalue runs BEFORE any boolean use of the value, and
            -- secret-text fontstrings rewrite on every update anyway, so the
            -- font change lands on the next natural SetText. The old `~= ""`
            -- guard is dropped as redundant — GetText() returns nil, never "",
            -- for empty text.
            pcall(function()
                local text = fontString:GetText()
                if not (issecretvalue and issecretvalue(text)) and text then
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


-- ============================================================
-- GLOBAL (account-wide) DEFAULTS
-- Not per-profile. Lives at DandersFramesDB_v2.global.
-- ============================================================

DF.GlobalDefaults = {
    notifyOutdated = true,
    -- The one-line greeting printed at login. Account-wide like its Notifications
    -- sibling above: it is chat chrome, not a per-profile visual. Default ON so a
    -- new user still learns `/df` exists; anyone who already knows can silence it.
    showLoginMessage = true,
    -- Colour picker. Account-wide, not per-mode: "use DF's picker" is a UI-chrome
    -- preference with no party/raid meaning, and the hooks that consume it are
    -- installed once for the whole session. Previously these lived in PartyDefaults,
    -- which generated an independent (and permanently ignored) raid copy.
    --   colorPickerOverride       -- DF's own colour swatches use DF's picker
    --   colorPickerGlobalOverride -- every OTHER addon's picker becomes DF's too
    colorPickerOverride = true,
    colorPickerGlobalOverride = false,
    -- Aura duration-text update rate (buff/debuff/defensive rows + Aura Designer).
    -- Stored as a raw key; the mapping to the native binding's updateInterval seconds
    -- lives in Features/Auras.lua (DF:GetAuraDurationUpdateInterval): SMOOTH = 0.1,
    -- PERFORMANCE = 1.0, NORMAL = emit nothing (Blizzard's own default cadence —
    -- behavior-neutral, since the C-side default value is undocumented).
    auraDurationUpdateInterval = "NORMAL",
    -- Colour-by-time breakpoints (account-wide; shared by the buff/debuff/defensive rows
    -- AND the Aura Designer indicators — they all key off the same duration formatter). Each
    -- stop applies its colour to remaining durations AT OR ABOVE its threshold (seconds); the
    -- highest threshold <= remaining wins, so threshold 0 is the base band. The default is a
    -- low "warn on expiry" ladder tuned for the common case (short HoTs, ~15-30s): a fresh
    -- HoT reads green and only ramps hot in its final seconds. Editable on the Colours page.
    durationColorByTimeBreakpoints = {
        -- Vivid traffic-light: brighter and more saturated than the softened set — clearer at
        -- a glance in combat without going pure-primary neon. Keep in sync with
        -- DEFAULT_DURATION_BREAKPOINTS (Features/Auras.lua) so "Reset to Default" and the engine
        -- fallback agree. Hex: 5fe05f/ffd23d/ff9838/f75555.
        -- 9/6/3 on the strip's 12s preview domain = EVEN QUARTERS, the same bar the percent
        -- ramp's 75/50/25 draws — flipping the Colours-page tabs shows one identical default.
        { threshold = 9, color = { r = 0.373, g = 0.878, b = 0.373 } },  -- green  (fresh / healthy, >=9s)
        { threshold = 6, color = { r = 1.0,   g = 0.824, b = 0.239 } },  -- gold   (6-9s)
        { threshold = 3, color = { r = 1.0,   g = 0.596, b = 0.22  } },  -- orange (3-6s)
        { threshold = 0, color = { r = 0.969, g = 0.333, b = 0.333 } },  -- red    (<3s, about to fall off)
    },
    -- PERCENT ramp for duration TEXT. Thresholds are PERCENT OF TOTAL REMAINING (0-100),
    -- so every aura tells the same relative story regardless of length — a 30-minute raid
    -- buff ramps exactly like a 6-second HoT, which a seconds ladder can never do (a long
    -- buff sits in the "fresh" band essentially forever). Same "highest threshold <=
    -- remaining wins" rule as the seconds ramp above.
    durationColorByPercentBreakpoints = {
        -- Same vivid traffic-light palette as the seconds ladder, spread over the whole
        -- life of the aura. Keep in sync with DEFAULT_PERCENT_BREAKPOINTS (Features/Auras.lua).
        -- 75/50/25 = EVEN QUARTERS, mirroring the seconds ladder's 9/6/3 on its 12s
        -- preview domain — the two default bars are identical.
        { threshold = 75, color = { r = 0.373, g = 0.878, b = 0.373 } },  -- green  (>=75% left)
        { threshold = 50, color = { r = 1.0,   g = 0.824, b = 0.239 } },  -- gold   (50-75%)
        { threshold = 25, color = { r = 1.0,   g = 0.596, b = 0.22  } },  -- orange (25-50%)
        { threshold = 0,  color = { r = 0.969, g = 0.333, b = 0.333 } },  -- red    (<25%, about to fall off)
    },
    -- ============================================================
    -- HOW the duration-text ramp is READ (account-wide, Colours page)
    -- ============================================================
    -- The ramp's colours and the way they're read belong together, so both live here
    -- rather than on each aura page — a row only carries an on/off. Text supports all
    -- four combinations; the expiry border/tint supports only stepped (see below).
    durationTextColorSmooth = true,        -- true = blend between stops, false = snap to the stop at or below
    durationTextColorScale  = "PERCENT",   -- "PERCENT" | "SECONDS" — which ramp text reads
    -- The expiry BORDER/TINT reveal has NO ramp of its own — it reads the two above, the
    -- same lists the duration text uses, picked by the reveal's own per-indicator unit
    -- (expiryAlertThresholdUnit). One set of colours for "time is running out".
    -- The reveal cannot BLEND between them: its colours are baked into |T inline-texture
    -- escapes, and inline textures IGNORE the fontstring vertex colour the smooth curve
    -- writes (probe-verified). So durationTextColorSmooth above is text-only by nature.
    -- A stop at or above an indicator's Alert Below threshold never renders — the reveal
    -- doesn't exist up there, the same way a text stop past the aura's duration never
    -- shows. /df debug cbt lists the affected stops per indicator.
    -- (Removed 2026-07-24: durationBorderColorScale + durationBorderColorStops +
    -- durationBorderColorPercentStops. A separate border palette bought nothing once the
    -- defaults were asked to match the text, and the account-wide scale could not express
    -- a glyph at 5 seconds next to a border at 30%.)
}

-- ============================================================
-- DEFAULT SETTINGS (exported from profile v2.9.8)
-- ============================================================

-- Shared default dispel-type palette (the game colours). One source of truth for
-- the db colour defaults below, the test/OOR fallbacks (Features/Dispel.lua) and
-- the custom-colour resolver (Frames/Colors.lua). Enrage defaults to Bleed's red;
-- both get their own picker so they can be told apart.
DF.DispelDefaultColors = {
    Magic   = { r = 0.2, g = 0.6, b = 1.0 },
    Curse   = { r = 0.6, g = 0.0, b = 1.0 },
    Disease = { r = 0.6, g = 0.4, b = 0.0 },
    Poison  = { r = 0.0, g = 0.6, b = 0.0 },
    Bleed   = { r = 0.8, g = 0.0, b = 0.0 },
    Enrage  = { r = 0.8, g = 0.0, b = 0.0 },   -- shares Bleed's red
    None    = { r = 0.0, g = 0.0, b = 0.0 },   -- None / Physical (icon border only)
}

DF.PartyDefaults = {
    -- Global Font Shadow Settings (applies when outline is SHADOW)
    fontShadowOffsetX = 1,
    fontShadowOffsetY = -1,
    fontShadowColor = {r = 0, g = 0, b = 0, a = 1},

    -- Absorb Bar
    absorbBarAnchor = "TOPRIGHT",
    absorbBarAttachedClampMode = 1,
    absorbBarBackgroundColor = {r = 0, g = 0, b = 0, a = 1},
    absorbBarBlendMode = "BLEND",
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
    absorbBarTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes",
    absorbBarWidth = 46,
    absorbBarX = 0,
    absorbBarY = 0,

    -- AFK Icon
    afkIconAlpha = 0.8,
    afkIconAnchor = "CENTER",
    afkIconEnabled = true,
    afkIconFrameLevel = 30,
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
    buffDeduplicateDefensives = true,
    buffDurationAnchor = "CENTER",
    buffDurationColor = {r = 1, g = 1, b = 1},
    -- Colour-by-time is a plain ON/OFF here. HOW it reads (smooth vs stepped, percent vs
    -- seconds) and the colours themselves are account-wide on the Colours page — the mode
    -- is a property of the ramp, not of this row (see durationTextColorSmooth below).
    buffDurationColorByTime = true,
    buffDurationHideAboveEnabled = false,
    buffDurationHideAboveThreshold = 10,
    buffDurationHideOnPermanent = true,   -- no timer text on permanent (duration-0) auras
    -- Native 12.1 max-TOTAL-duration filter (candidateFilters.maxDuration); minutes.
    buffMaxDurationEnabled = false,
    buffMaxDurationMinutes = 5,
    -- Hide duration-0 auras (max-finite maxDuration; Hide Long Buffs subsumes it)
    buffHidePermanent = false,
    buffDurationFont = "DF Roboto SemiBold",
    buffDurationFormat = "NUMBER",
    buffDurationOutline = "SHADOW;OUTLINE",
    buffDurationScale = 1.2000000476837,
    buffDurationX = 0,
    buffDurationY = 2,
    -- Duration bar (12.1 factory rows): a strip below/above each icon that
    -- drains with the aura's remaining time (native SetDurationBar fill —
    -- render-side, works on secret auras). Geometry (position/height/gap) is
    -- structural (layout reservation); texture/colours restyle in place.
    buffDurationBarEnabled = false,
    buffDurationBarPosition = "BOTTOM",       -- "BOTTOM" / "TOP"
    buffDurationBarHeight = 4,
    buffDurationBarGap = 1,
    buffDurationBarColorMode = "STATIC",      -- STATIC / DF / DFSTOPS / CLASSIC (see BuildDurationBarSpec)
    buffDurationBarTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist",
    buffDurationBarColor = {r = 0.2, g = 0.9, b = 0.3, a = 1},
    buffDurationBarBGColor = {r = 0, g = 0, b = 0, a = 0.8},
    buffDurationBarReverseFill = false,
    -- Pandemic (12.1 PTR 8): the GAME's refresh window — lit while a refresh would
    -- clip nothing, roughly the last 30% of the base duration. Deliberately has no
    -- threshold setting of any kind: the window is per spell and Blizzard's to define
    -- (Features/Pandemic.lua). Off by default; only refreshable auras ever light.
    buffPandemicEnabled = false,
    buffPandemicMode = "BORDER",              -- BORDER / TINT
    -- Flash: a looping alpha pulse on the whole cue. Creation-frozen (the animation is
    -- built and played in the secure init pass), so both keys are structural.
    buffPandemicFlash = false,
    buffPandemicFlashSpeed = 1,               -- seconds per dim-and-back cycle (0.2-3)
    -- TINT: a solid wash over the icon.
    buffPandemicTintColor = {r = 0.2, g = 1, b = 0.2, a = 1},
    buffPandemicTintAlpha = 0.4,
    buffPandemicTintInset = 0,                -- +inward, -outward halo (DF.Border convention)
    -- BORDER: a real DF.Border, keyed the standard way (prefix .. "Border*") so
    -- DF.Border:BuildSpec and GUI:CreateBorderControls both drive it with no special case.
    -- ☠ SEED THE WHOLE SET, not just the keys the default style uses. CreateBorderControls
    -- builds every control it was opted into regardless of the current Style, and an unset
    -- key renders as a dropdown reading "nil" or a slider with an empty value box (Krathe,
    -- 2026-08-05). Values mirror the AD icon card's Border block so a pandemic ring opens
    -- on the same numbers any other icon border does.
    buffPandemicShowBorder = true,            -- the Pandemic Enable toggle is the real master
    buffPandemicBorderStyle = "SOLID",
    buffPandemicBorderSize = 2,
    buffPandemicBorderInset = 0,
    buffPandemicBorderOffsetX = 0,
    buffPandemicBorderOffsetY = 0,
    buffPandemicBorderColor = {r = 0.2, g = 1, b = 0.2, a = 1},
    buffPandemicBorderBlendMode = "BLEND",
    buffPandemicBorderTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist",
    buffPandemicBorderGradientStartColor = {r = 0, g = 0, b = 0, a = 1},
    buffPandemicBorderGradientEndColor = {r = 0.5, g = 0.5, b = 0.5, a = 1},
    buffPandemicBorderGradientDirection = "HORIZONTAL",
    buffPandemicBorderShadowEnabled = false,
    buffPandemicBorderShadowColor = {r = 0, g = 0, b = 0, a = 0.8},
    buffPandemicBorderShadowSize = 1,
    buffPandemicBorderShadowOffsetX = 1,
    buffPandemicBorderShadowOffsetY = -1,
    -- Expiring Animation (AD-style full toolkit) — replaces the legacy

    -- Aura Source Mode

    -- Direct Mode: Buff Filters
    directBuffShowAll = false,                -- Show all buffs (ignores sub-filters)
    directBuffOnlyMine = true,               -- Restrict all buff filters to player-cast only
    buffFilterSelection = {
        -- Raid Buffs came off the default with the v5 spell DB: they are permanent
        -- always-on auras that only ever occupied icon slots. Existing profiles keep
        -- whatever they had -- see the _buffPresetBaselineV1 migration in Core.lua,
        -- which only ADDS the three new presets and never removes one.
        presets = { healing = true, raidDefensives = true, offensiveCooldowns = true, powerExternals = true },
        customs = {},
        uncategorised = false,
    },
    defensiveFilterSelection = {
        presets = { defensives = true, externalDefensives = true },
        customs = {},
        uncategorised = false,
    },
    directBuffSortOrder = "TIME",             -- "DEFAULT" / "TIME" / "NAME"
    directBuffSortMineFirst = false,          -- Own auras before others' (TIME/NAME sorts; DEFAULT is already mine-first)
    directBuffSortReverse = false,            -- Reverse the sort direction

    -- Direct Mode: Debuff Filters
    directDebuffShowAll = true,               -- Show all debuffs (DEFAULT ON — Blizzard's category tokens miss untagged debuffs even with all enabled, so "all" is the only complete option; category mode stays available)
    debuffDeduplicateDesigner = true,         -- Hide debuffs an Aura Designer group already shows (was silent+unconditional pre-5.0; now a visible toggle, and it finally applies in Show All mode too)
    debuffFilterBoss = true,                  -- Boss debuffs (native isBossAura)
    debuffFilterRole = true,                  -- Role debuffs (native isRoleAura)
    debuffFilterPriority = true,              -- Priority debuffs (native isPriorityAura)
    debuffFilterCrowdControl = true,          -- Crowd control (CROWD_CONTROL token)
    debuffFilterRaid = false,                 -- Other raid-flagged debuffs (RAID token)
    debuffFilterDispellable = true,           -- Dispellable debuffs (mode below)
    -- IMPORTANT DEBUFF HIGHLIGHT. Boss/role and priority auras already render as their
    -- OWN aura groups (keys "bossrole"/"priority" in BuildDirectDebuffFilters) and those
    -- groups are declared first, so they already lead the row. These keys style them.
    -- Membership of the group IS the "is this important" test — nothing reads aura data,
    -- which is what makes this expressible at all under the 12.1 secret rules.
    -- ON by default from v5: the aura row is rebuilt on this lane anyway, so there is no
    -- established look to preserve, and a boss/priority debuff standing out is the
    -- behaviour most users would pick. Off is one tick away on the Debuffs page.
    debuffImportantHighlight = true,          -- master toggle for the treatment below
    debuffImportantScale = 1.25,              -- icon size step for important debuffs (1 = same as the rest)
    debuffImportantBadge = true,              -- corner "!" badge
    debuffImportantBadgeSize = 10,            -- badge diameter in px (centred inside the corner, inset by size/4)
    debuffImportantBadgePoint = "TOPRIGHT",   -- which icon corner the badge sits on
    debuffImportantBadgeX = 0,                -- nudge from that corner (ADDED to the default inward inset)
    debuffImportantBadgeY = 0,
    debuffImportantBadgeColor = {r = 1, g = 0.616, b = 0.18, a = 1},   -- disc
    debuffImportantMarkColor = {r = 0.08, g = 0.055, b = 0.024, a = 1}, -- the "!" itself
    -- Debuff blacklist: hide these non-secret debuffs from the debuff row (12.1
    -- excludeSpellIDs, friendly-safe — NeverSecret only). Default hides the
    -- post-Lust family (Sated/Exhaustion/Temporal Displacement/Fatigued/Insanity);
    -- Deserters + Ride Along are opt-in on the Aura Blacklist page. Buffs are NOT
    -- here by design — they're opt-in via the Filter Designer.
    debuffBlacklist = { [57724] = true, [57723] = true, [80354] = true, [160455] = true, [95809] = true },
    directDebuffDispellableMode = "PLAYER",  -- "PLAYER" (dispellable by me) / "ALL" (dispellable type map) / "ANY" (native DISPELLABLE token, PTR-5+)
    debuffMaxDurationEnabled = false,         -- Hide long debuffs
    debuffMaxDurationMinutes = 5,             -- ... threshold (base duration)
    debuffMaxDurationKeepImportant = true,    -- ... but keep Boss/Role/Priority visible
    directDebuffSortOrder = "TIME",           -- "DEFAULT" / "TIME" / "NAME"
    directDebuffSortMineFirst = false,        -- Own auras before others' (TIME/NAME sorts; DEFAULT is already mine-first)
    directDebuffSortReverse = false,          -- Reverse the sort direction

    buffGrowth = "LEFT_UP",
    buffHideSwipe = false,
    buffMax = 4,
    buffOffsetX = -2,
    buffOffsetY = 6,
    buffPaddingX = 2,
    buffPaddingY = 2,
    buffScale = 1,
    buffShowDuration = true,
    buffSize = 20,
    buffStackAnchor = "BOTTOMRIGHT",
    buffStackColor = {r = 1, g = 0.82, b = 0},
    buffStackFont = "DF Roboto SemiBold",
    buffStackOutline = "SHADOW;OUTLINE",
    buffStackScale = 1,
    buffStackX = 3,
    buffStackY = -2,
    buffWrap = 2,
    showBuffs = true,

    -- Class Color
    classColorAlpha = 1,
    -- colorPickerOverride / colorPickerGlobalOverride moved to GlobalDefaults
    -- (account-wide). They were never per-mode in practice — both hooks only ever
    -- read db.party — so a raid-tab tick saved a value nothing read.
    -- DF:MigrateColorPickerToGlobal carries the old per-mode values forward.

    -- Dead/Fade Settings
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
    debuffBorderColorPoison = {r = 0, g = 0.6, b = 0},
    debuffShowBorder = true,
    debuffDispelBorderInset = 0,    -- native dispel ring: + inward / - outward halo
    -- Dispel symbol (Wave 5b, colourblind aid): the engine writes the dispel-type
    -- letter into a DF-owned FontString (native SetAuraSymbol; zero aura reads).
    -- Renders in-game ONLY while WoW's colorblindMode CVar is on (GUI tooltip caveat).
    -- ☠ NAME DIVERGENCE, DELIBERATE -- do not "tidy" these to match the label.
    -- These drive the feature the UI calls DISPEL TEXT: the two-letter dispel code
    -- (Ma/Po/Cu) on a debuff icon. The keys still say Symbol because that was the
    -- pre-68914 API name; Blizzard itself renamed it (SetDispelTypeText is current,
    -- SetAuraSymbol is the deprecated alias) and the UI followed. Renaming the keys
    -- would need a migration over everyone's saved data plus import handling for the
    -- export strings already in the wild -- all for an internal name nobody sees.
    --
    -- ⚠ Not to be confused with the DISPEL SYMBOL on the dispel overlay -- the
    -- Magic/Curse/Poison glyph drawn on the FRAME. That one is keyed dispelIcon*.
    -- The two features diverge in opposite directions; that is not a mistake.
    debuffDispelSymbolAnchor = "CENTER",
    debuffDispelSymbolColor = {r = 1, g = 1, b = 1},
    debuffDispelSymbolEnabled = false,
    debuffDispelSymbolFont = "DF Roboto SemiBold",
    debuffDispelSymbolOutline = "SHADOW;OUTLINE",
    debuffDispelSymbolScale = 1,
    debuffDispelSymbolX = 0,
    debuffDispelSymbolY = 0,
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
    debuffDurationAnchor = "CENTER",
    debuffDurationColorByTime = false,
    debuffDurationHideAboveEnabled = false,
    debuffDurationHideAboveThreshold = 10,
    debuffDurationHideOnPermanent = true,   -- no timer text on permanent (duration-0) auras
    debuffDurationFont = "DF Roboto SemiBold",
    debuffDurationOutline = "SHADOW;OUTLINE",
    debuffDurationScale = 1,
    debuffDurationX = 0,
    debuffDurationY = 0,
    -- Duration bar (12.1 factory rows) — see the buff block above.
    debuffDurationBarEnabled = false,
    debuffDurationBarPosition = "BOTTOM",     -- "BOTTOM" / "TOP"
    debuffDurationBarHeight = 4,
    debuffDurationBarGap = 1,
    debuffDurationBarColorMode = "STATIC",
    debuffDurationBarTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist",
    debuffDurationBarColor = {r = 0.2, g = 0.9, b = 0.3, a = 1},
    debuffDurationBarBGColor = {r = 0, g = 0, b = 0, a = 0.8},
    debuffDurationBarReverseFill = false,
    debuffGrowth = "RIGHT_UP",
    debuffHideSwipe = false,
    debuffMax = 5,
    debuffOffsetX = 2,
    debuffOffsetY = 5,
    debuffPaddingX = 2,
    debuffPaddingY = 2,
    debuffScale = 1,
    debuffShowDuration = false,
    debuffSize = 20,
    debuffStackAnchor = "BOTTOMRIGHT",
    debuffStackFont = "DF Roboto SemiBold",
    debuffStackOutline = "SHADOW;OUTLINE",
    debuffStackScale = 1,
    debuffStackX = 0,
    debuffStackY = 0,
    debuffWrap = 3,
    showDebuffs = true,

    -- Defensive Bar
    defensiveBarGrowth = "RIGHT_DOWN",
    defensiveBarMax = 4,
    defensiveBarSpacing = 2,
    defensiveBarWrap = 5,

    -- Duration bar (12.1 factory rows) — see the buff block above.
    defensiveDurationBarEnabled = false,
    defensiveDurationBarPosition = "BOTTOM",  -- "BOTTOM" / "TOP"
    defensiveDurationBarHeight = 4,
    defensiveDurationBarGap = 1,
    defensiveDurationBarColorMode = "STATIC",
    defensiveDurationBarTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist",
    defensiveDurationBarColor = {r = 0.2, g = 0.9, b = 0.3, a = 1},
    defensiveDurationBarBGColor = {r = 0, g = 0, b = 0, a = 0.8},
    defensiveDurationBarReverseFill = false,

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
    defensiveIconDurationHideOnPermanent = true,   -- no timer text on permanent (duration-0) auras
    defensiveIconDurationOutline = "SHADOW;OUTLINE",
    defensiveIconDurationScale = 1.4,
    defensiveIconDurationX = 0,
    defensiveIconDurationY = 0,
    defensiveIconEnabled = true,
    defensiveIconDurationFormat = "NUMBER",   -- NUMBER / SHORT / PERCENT (icon-sized formats)
    defensiveIconFrameLevel = 65,
    defensiveIconHideSwipe = false,
    defensiveIconScale = 1,
    defensiveIconShowBorder = true,
    defensiveIconShowDuration = true,
    defensiveIconSize = 30,
    defensiveIconX = 0,
    defensiveIconY = 0,
    defensiveSortOrder = "EXTERNALS",         -- "DEFAULT" / "TIME" / "EXTERNALS" (EXTERNALS = the shipped BigDefensive order)

    -- Dispel Overlay. Dispel-type colours come from the shared account palette
    -- DF.db.dispelColors (edited on the Colors page; defaults = the game palette),
    -- applied always — there is no game-vs-custom toggle (Reset on the Colors page
    -- restores the game colours). The debuff icon opts in via "Color by Dispel Type".
    dispelAnimate = false,
    dispelBorderAlpha = 1,
    dispelBorderInset = 0,
    dispelBorderSize = 2,
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

    -- (Removed) GUI State: guiHeight / guiScale / guiWidth. Settings-window
    -- geometry is account-wide machine state now -- DandersFramesDB_v2.windowState,
    -- reached via DF:GetWindowState. As per-profile DEFAULTS they actively caused
    -- a bug: a new profile is born from this table, so creating one silently
    -- reset the window's scale and size while the open window kept the old ones.

    -- Heal Absorb Bar
    healAbsorbBarAnchor = "BOTTOM",
    healAbsorbBarBackgroundColor = {r = 0, g = 0, b = 0, a = 0.4570315182209},
    healAbsorbBarBlendMode = "BLEND",
    healAbsorbBarColor = {r = 1, g = 0.25098040699959, b = 0.25098040699959, a = 0.77604186534882},
    healAbsorbBarHeight = 6,
    healAbsorbBarMode = "OVERLAY",
    healAbsorbBarOrientation = "HORIZONTAL",
    healAbsorbBarOverlayReverse = false,
    healAbsorbBarReverse = false,
    healAbsorbBarTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Stripes",
    healAbsorbBarWidth = 50,
    healAbsorbBarX = 0,
    healAbsorbBarY = -10,

    -- Heal Prediction
    healPredictionAllColor = {r = 0, g = 0.7, b = 0.4, a = 0.7},
    healPredictionAnchor = "CENTER",
    healPredictionBackgroundColor = {r = 0, g = 0, b = 0, a = 0.5},
    healPredictionBlendMode = "BLEND",
    healPredictionEnabled = true,
    healPredictionFrameLevel = 12,
    healPredictionHeight = 6,
    healPredictionMode = "OVERLAY",
    healPredictionMyColor = {r = 0, g = 0.8, b = 0.2, a = 0.7},
    healPredictionOrientation = "HORIZONTAL",
    healPredictionOthersColor = {r = 0, g = 0.5, b = 0.8, a = 0.7},
    healPredictionReverse = false,
    healPredictionShowMode = "MINE",
    healPredictionShowOverheal = false,
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
    leaderIconFrameLevel = 30,
    leaderIconHideInCombat = true,
    leaderIconScale = 1,
    leaderIconX = 0,
    leaderIconY = 6,

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
    missingBuffIconEnabled = true,
    -- Above the aura band, below defensive. A row is 13 levels thick, so buff/debuff
    -- art at base 40 reaches 56 and AD indicators reach ~59; defensive sits at 65.
    -- Was 35, which only ever looked right because buildMissingCellConfig omitted
    -- frameLevelOffset and ApplyZOrder's `or 40` fallback silently added 40. Existing
    -- profiles move by _missingBuffBaselineV3 (Core.lua), value-targeted on 35.
    missingBuffIconFrameLevel = 60,
    missingBuffIconScale = 1.2000000476837,
    missingBuffIconShowBorder = true,
    missingBuffIconSize = 24,
    missingBuffIconX = 0,
    missingBuffIconY = 0,

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
    oorIconsAlpha = 0.5,
    oorMissingBuffAlpha = 0.5,
    oorMissingHealthAlpha = 0.20000000298023,
    -- oorNameTextAlpha / oorHealthTextAlpha are retired: oorTextAlpha governs
    -- ALL unit text (TD elements, pet/legacy fontstrings and test previews
    -- alike). MigrateOORTextAlpha folds the old name value, then strips both.
    oorTextAlpha = 0.55,
    oorPowerBarAlpha = 0.20000000298023,
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
    personalTargetedSpellHighlightImportant = true,
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
    phasedIconFrameLevel = 30,
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
    raidRoleIconFrameLevel = 30,
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
    raidTargetIconFrameLevel = 30,
    raidTargetIconHideInCombat = false,
    raidTargetIconScale = 1.1000000238419,
    raidTargetIconX = 36,
    raidTargetIconY = 5,
    raidTestFrameCount = 40,
    raidUseGroups = true,

    -- Range Check
    rangeAlpha = 0.5,
    rangeCheckSpellID = 0,
    rangeFadeAlpha = 0.40000000596046,
    rangeUpdateInterval = 0.5,

    -- Ready Check Icon
    readyCheckIconAlpha = 1,
    readyCheckIconAnchor = "CENTER",
    readyCheckIconEnabled = true,
    readyCheckIconFrameLevel = 30,
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
    restedIndicatorGlow = false,
    restedIndicatorIcon = true,
    restedIndicatorOffsetX = -18,
    restedIndicatorOffsetY = -14,
    restedIndicatorSize = 20,

    -- Resurrection Icon
    resurrectionIconAlpha = 1,
    resurrectionIconAnchor = "CENTER",
    resurrectionIconEnabled = true,
    resurrectionIconFrameLevel = 30,
    resurrectionIconScale = 1.600000023841858,
    resurrectionIconShowText = false,
    resurrectionIconTextCasting = "Res...",
    resurrectionIconTextColor = {r = 0.2, g = 1, b = 0.2},
    resurrectionIconX = 0,
    resurrectionIconY = 0,

    -- Role Icon
    roleIconAlpha = 1,
    roleIconAnchor = "TOPLEFT",
    roleIconFrameLevel = 30,
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
    summonIconFrameLevel = 30,
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
    bgCarrierIconFrameLevel = 30,
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
    combatIconFrameLevel = 30,
    combatIconScale = 1.2,
    combatIconX = 0,
    combatIconY = 6,

    -- ⚰ DEPRECATED-TARGETED-SPELLS — this whole block goes when the feature does
    -- See the block comment at the top of Features\TargetedSpells.lua.
    -- Targeted Spells (on-frame)

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
    --
    -- The toggle defaults below MIRROR TEST_PRESETS.DEFAULT (TestMode/TestMode.lua),
    -- so a fresh profile actually matches the preset the panel shows as selected
    -- (testPreset = "DEFAULT"). They drifted apart once; if DEFAULT changes, change
    -- these to match. The sliders (testBuffCount/testDebuffCount/testFrameCount)
    -- are deliberately outside the preset - a working preference, not part of its
    -- visual identity - so they have no DEFAULT counterpart.
    testShowTargetedList = true,
    testAnimateTargetedList = true,
    testAnimateHealth = false,
    testBuffCount = 2,
    testDebuffCount = 2,
    testFrameCount = 5,
    testPreset = "DEFAULT",
    testShowAbsorbs = false,
    testShowAggro = false,
    testShowAuras = false,
    testShowDispelGlow = false,
    testShowExternalDef = false,
    testShowHealPrediction = false,
    testShowMissingBuff = false,
    testShowOutOfRange = true,
    testShowPets = true,
    testShowReducedMaxHealth = false,
    testShowSelection = false,
    testShowStatusIcons = false,
    testShowPersonalTargeted = true,
    testShowAuraDesigner = false,
    testShowTextDesigner = true,

    -- Tooltip settings
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
    -- Aura Designer tooltips. All OFF: AD surfaces are things you built, so a
    -- tooltip is opt-in rather than the sensible default the aura ROWS get.
    -- Groups are the ones worth turning on — their contents come from a filter,
    -- so you did not pick the individual icons. Indicators/Bars are exposed
    -- anyway; there is no harm in someone wanting them, and withholding the
    -- option is a judgement call we do not need to make for them.
    tooltipADGroupsEnabled = false,       -- Filter Groups + Debuff Groups
    tooltipADIndicatorsEnabled = false,   -- placed icon / square indicators
    tooltipADBarsEnabled = false,         -- the Aura Designer bar
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
    vehicleIconFrameLevel = 30,
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
            durationFont = "DF Roboto SemiBold",
            durationScale = 1.2,
            durationOutline = "SHADOW;OUTLINE",
            durationAnchor = "CENTER",
            durationX = 0,
            durationY = 0,
            stackFont = "DF Roboto SemiBold",
            stackScale = 1.0,
            stackOutline = "SHADOW;OUTLINE",
            stackAnchor = "BOTTOMRIGHT",
            stackX = 2,
            stackY = -2,
            iconBorderEnabled = true,
            iconBorderThickness = 1,
            durationColorByTime = true,
            durationColor = {r = 1, g = 1, b = 1, a = 1},
            stackColor = {r = 1, g = 1, b = 1, a = 1},
            hideIcon = false,
            -- Global AD indicator z-order defaults. The stored number is an ABSOLUTE
            -- offset from the unit frame — the render uses it as-is (resolveDefs in
            -- AuraDesigner\Factory.lua, `or 40`), it does not add a base to it. 40 is
            -- therefore a no-op at its shipped value: an indicator that has never had a
            -- level set renders exactly where it does today, below the defensive row.
            -- Was 30 — which the editor displayed as the default while the render ignored
            -- it entirely. Baseline changed rather than migrated: saved profiles keep
            -- whatever they hold. Keep this in step with the render fallback and with the
            -- backfill seed in Core.lua; all three must agree.
            indicatorFrameLevel = 40,
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
    defensiveIconSize = 20,   -- party: 30
}

local PARTY_ONLY_PREFIX = "targetedList"
local PARTY_ONLY_KEYS = {
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
            -- DeepCopy table defaults so the SavedVariable never shares a reference with
            -- DF.GlobalDefaults (else editing the saved value would mutate the template).
            DandersFramesDB_v2.global[k] = (type(v) == "table" and DF.DeepCopy) and DF:DeepCopy(v) or v
        end
    end
    return DandersFramesDB_v2.global
end
