local addonName, NS = ...
local UI = NS.__DandersUI
if not UI then return end

-- ============================================================
-- DF FONT OBJECT SYSTEM
-- ------------------------------------------------------------
-- Creates a DF-prefixed font object for every Blizzard GameFont*
-- template the addon's settings UI relies on. At load these are
-- exact copies of their Blizzard equivalents so the panel looks
-- identical. host:ApplySettingsFont() rewrites them from the host font
-- hooks, so a single consumer
-- setting re-skins the entire settings panel AND every FontString
-- inheriting from a DFFont automatically gains the roman/korean/
-- chinese/russian fallback family — fixing Cyrillic squares for
-- every widget that uses DFFont*.
-- ============================================================

-- Cache globals
local CreateFont = CreateFont
local _G = _G
local type, pcall, ipairs = type, pcall, ipairs

local DEFAULT_FONT_SIZE = 10
local DEFAULT_FONT_PATH = "Fonts\\FRIZQT__.TTF"

-- The Blizzard templates the settings UI uses (see the font audit).
-- Order does not matter; this is just the source-of-truth list.
local TEMPLATES = {
    "GameFontHighlightSmall",        -- small white body text (most common)
    "GameFontHighlight",             -- white body text
    "GameFontNormal",                -- yellow header text
    "GameFontNormalSmall",           -- small yellow button text
    "GameFontNormalLarge",           -- large yellow title text
    "GameFontNormalHuge",            -- one-off oversized header
    "GameFontHighlightSmallOutline", -- small white with outline
    "GameFontDisableSmall",          -- greyed-out small hint text
    "GameFontDisable",               -- greyed-out normal hint text
}

-- ============================================================
-- SAFE SET
-- The one place that actually writes a font onto an object. A consumer with a
-- multi-alphabet family builder supplies hooks.safeSetFont and gets the CJK /
-- Cyrillic fallbacks it built; everyone else gets a plain SetFont against the
-- resolved path, wrapped so a bad path is a no-op rather than an error.
-- EditBoxes are the reason for the pcall: they are FontInstances without
-- SetTextScale, so a family-based setter can legitimately refuse them.
-- ============================================================
local function SafeSet(host, obj, fontName, size, flags)
    local viaHook = host:Hook("safeSetFont")
    if viaHook then
        local ok, handled = pcall(viaHook, obj, fontName, size, flags)
        if ok and handled ~= false then return true end
    end
    local resolve = host:Hook("resolveFontPath")
    local path = (resolve and resolve(fontName)) or fontName
    if type(path) ~= "string" or path == "" then path = DEFAULT_FONT_PATH end
    return (pcall(obj.SetFont, obj, path, size, flags)) and true or false
end

-- Registry of DFFont objects (DFFont<suffix> = font object)
UI.FontObjects = UI.FontObjects or {}

-- Create one DFFont<Suffix> object per template, copying the
-- Blizzard template as-is. The per-template colour/size/outline
-- is preserved; only the font file can be swapped later.
local function CreateFontObjects()
    for _, templateName in ipairs(TEMPLATES) do
        local suffix = templateName:gsub("^Game", "")   -- "FontHighlightSmall" etc.
        local objName = "DF" .. suffix                 -- "DFFontHighlightSmall"

        if not _G[objName] then
            local blizzFont = _G[templateName]
            if blizzFont then
                local font = CreateFont(objName)
                font:CopyFontObject(blizzFont)
                UI.FontObjects[objName] = font
            end
        else
            UI.FontObjects[objName] = _G[objName]
        end
    end
end

CreateFontObjects()

-- ============================================================
-- APPLY / REFRESH
-- Apply the user's chosen settings font to all DFFont objects,
-- and force visible settings FontStrings to re-render.
-- ============================================================

-- Apply the user's chosen settings font + outline to every DF
-- font object. Called once at load (after DB is ready) and on
-- any subsequent change via GUI:RefreshSettingsFont().
--
-- Implementation: for each DFFont object, read its current size
-- (from the Blizzard copy), build the multi-alphabet FAMILY for the
-- chosen font at that size through Config.lua's family builder, and
-- make the DFFont inherit it — the same relationship Blizzard's own
-- GameFont* objects have with their SystemFont_* families. Every
-- FontString inheriting the DFFont then gets the fallback per alphabet.
--
-- ☠ THIS USED TO CALL dfFont:SetFont(fontPath, ...) DIRECTLY — one file, no
-- family — while the header comment above described the family path. So the
-- fallback the header promised never existed for DFFont inheritors: on a
-- zhTW / zhCN / koKR client, any Settings Font without CJK glyphs rendered
-- those widgets as boxes (#1054, Click Casting tab labels), and the DEFAULT
-- font ("DF Roboto SemiBold") is exactly such a font — so every CJK user hit
-- it out of the box. Widgets routed through GUI:SetSettingsFont were fine
-- because SafeSetFont already builds the family; only direct inheritors broke.
--
-- Colour is re-applied after the inherit: SetFontObject takes everything
-- from the parent, and the family is white, but the templates carry their
-- own colours (yellow headers, grey disabled). Falls back to the old direct
-- SetFont if the family cannot be built or the inherit is refused, so this
-- can only ever be an improvement over what shipped.
function UI:ApplySettingsFont()
    local getSetting = self:Hook("getFontSetting")
    local fontName, outline
    if getSetting then fontName, outline = getSetting() end
    outline = outline or ""
    if outline == "NONE" then outline = "" end

    local resolve = self:Hook("resolveFontPath")
    local fontPath = fontName and resolve and resolve(fontName) or nil
    -- Fall back to the client locale-aware font when the consumer has no font
    -- setting at all, or its media library cannot resolve the name.
    if type(fontPath) ~= "string" or fontPath == "" then fontPath = DEFAULT_FONT_PATH end

    for _, templateName in ipairs(TEMPLATES) do
        local suffix = templateName:gsub("^Game", "")
        local objName = "DF" .. suffix
        local font = UI.FontObjects[objName]
        if font then
            -- Preserve the template's existing size (different templates
            -- have different sizes — Small vs Normal vs Large).
            local _, size = font:GetFont()
            size = size or DEFAULT_FONT_SIZE
            -- The user's outline choice is absolute: "None" means no outline
            -- on every DFFont, including templates that originally had an
            -- outline (e.g. GameFontHighlightSmallOutline). Users expect
            -- the dropdown to directly control the outline state.
            local r, g, b, a = font:GetTextColor()
            local applied = false
            -- The family arm is the consumer job: only it knows how to build a
            -- multi-alphabet family for its own font setting. hooks.fontFamily
            -- returns the family OBJECT (or its global name); absent, the plain
            -- path below applies and CJK inheritors fall back to the client font.
            local familyHook = self:Hook("fontFamily")
            local family = familyHook and familyHook(fontPath, outline, size)
            if type(family) == "string" then family = _G[family] end
            if family then
                applied = pcall(font.SetFontObject, font, family)
                if applied then
                    pcall(font.SetTextColor, font, r or 1, g or 1, b or 1, a or 1)
                end
            end
            if not applied then
                pcall(font.SetFont, font, fontPath, size, outline)
            end
        end
    end
end

-- ============================================================
-- INLINE FONT TRACKER
-- For settings-UI widgets that need explicit size/outline control
-- (e.g. custom-sized button text, small status labels) the addon
-- historically called fontString:SetFont("Fonts\\FRIZQT__.TTF",
-- size, outline) directly. That bypasses any template inheritance,
-- so the Settings Font dropdown cannot affect them. SetSettingsFont
-- replaces those calls: it applies the user's current settings font
-- with the given size/outline, AND registers the FontString so
-- RefreshSettingsFont can re-apply the new font later.
-- ============================================================

-- fontString -> { size, outline }, to re-apply on refresh.
--
-- ☠ WEAK KEYS, and that is the whole point. This was an ARRAY of {fs, size, outline}
-- tuples holding STRONG references, under a comment claiming "entries with a
-- garbage-collected FontString become nil and are skipped naturally" -- which could never
-- happen, because the registry itself was the thing keeping them alive. The cleanup arm in
-- RefreshSettingsFont was unreachable, the table only ever grew as settings pages rebuilt
-- their widgets, and every font change re-applied to fontstrings long gone from the screen.
--
-- Keying by the fontstring also retires the linear scan that used to run on every
-- SetSettingsFont call to find an existing entry.
UI._settingsFontStrings = UI._settingsFontStrings or setmetatable({}, { __mode = "k" })

-- Apply the user's settings font to a FontString with the given
-- size and outline, then register it for future refreshes.
--
-- `outline` semantics: if nil, the user's Settings Font Outline
-- choice wins (so the widget follows whatever the user picked).
-- If explicit (e.g. "OUTLINE"), it is respected as the minimum
-- outline — useful for widgets like drag-hint text that need an
-- outline regardless of user preference.
function UI:SetSettingsFont(fontString, size, outline)
    if not fontString then return end

    size = size or DEFAULT_FONT_SIZE
    local explicitOutline = outline  -- nil means "follow user"

    local getSetting = self:Hook("getFontSetting")
    local fontName, userOutline
    if getSetting then fontName, userOutline = getSetting() end
    userOutline = userOutline or ""
    if userOutline == "NONE" then userOutline = "" end

    local flagsToUse = explicitOutline or userOutline

    -- A family-aware setter uses CreateFontFamily + SetTextScale, which only
    -- FontStrings have. EditBoxes inherit from FontInstance (GetFont/SetFont
    -- work) but lack SetTextScale, so they take the plain path -- no
    -- multi-alphabet family, but also no crash. EditBox text is almost always
    -- user-typed ASCII anyway.
    local isFontString = fontString.GetObjectType and fontString:GetObjectType() == "FontString"
    if isFontString then
        SafeSet(self, fontString, fontName, size, flagsToUse)
    else
        local resolve = self:Hook("resolveFontPath")
        local fontPath = (fontName and resolve and resolve(fontName)) or DEFAULT_FONT_PATH
        pcall(fontString.SetFont, fontString, fontPath, size, flagsToUse)
    end

    -- Register for future refreshes (only once per fontString)
    -- Keyed, so a re-registration overwrites in place and no scan is needed.
    self._settingsFontStrings[fontString] = { size = size, outline = explicitOutline }
end

-- ============================================================
-- REFRESH
-- Called by the settings font/outline dropdown callbacks.
-- Re-applies the user's font to every registered FontString (the
-- inline-SetFont widgets) and nudges every FontString across every
-- settings page so template-inherited widgets re-render immediately.
-- ============================================================
function UI:RefreshSettingsFont()
    self:ApplySettingsFont()

    -- Re-apply settings font to every registered inline-SetFont FontString
    local registry = self._settingsFontStrings
    if registry then
        -- No removal arm: the table is weak-keyed, so a collected FontString drops out on
        -- its own. Safe to call SetSettingsFont from inside pairs() -- it OVERWRITES the
        -- key it is handed and never inserts a new one during the traversal.
        for fs, entry in pairs(registry) do
            if fs.GetObjectType then
                -- Re-apply with the same explicit outline semantics
                self:SetSettingsFont(fs, entry.size, entry.outline)
            end
        end
    end

    -- Force FontStrings to re-evaluate their inherited font.
    -- Setting the same text back forces a layout pass.
    if self.Pages then
        for _, page in pairs(self.Pages) do
            if page.child then
                local function nudge(frame)
                    if not frame then return end
                    local objType = frame.GetObjectType and frame:GetObjectType()
                    if objType == "FontString" then
                        local t = frame:GetText()
                        if t and t ~= "" then
                            frame:SetText("")
                            frame:SetText(t)
                        end
                        return  -- FontStrings are leaf nodes; no children or sub-regions
                    end
                    -- Only Frames have GetChildren / GetRegions
                    if frame.GetChildren then
                        for _, child in ipairs({frame:GetChildren()}) do
                            nudge(child)
                        end
                    end
                    if frame.GetRegions then
                        for _, region in ipairs({frame:GetRegions()}) do
                            nudge(region)
                        end
                    end
                end
                nudge(page.child)
            end
        end
    end
end
