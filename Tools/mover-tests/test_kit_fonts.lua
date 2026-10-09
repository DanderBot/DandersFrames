local NS = ...

-- ============================================================
-- KIT FONTS -- DandersUI/Fonts.lua, SetSettingsFont
-- ------------------------------------------------------------
-- A host that owns a font setting (DandersFrames) applies it; a host that has
-- none (DandersMover) follows the shared DFFont objects the first one
-- re-skins, so a sized label matches the template-built labels beside it
-- instead of falling back to the client font.
-- ============================================================

local function fontObject(path, size, flags)
    local o = { _path = path, _size = size, _flags = flags }
    function o:GetFont() return self._path, self._size, self._flags end
    function o:SetFont(p, s, f) self._path, self._size, self._flags = p, s, f end
    function o:CopyFontObject(src) self._path, self._size, self._flags = src:GetFont() end
    function o:GetTextColor() return 1, 1, 1, 1 end
    function o:SetTextColor() end
    function o:GetObjectType() return "FontString" end
    return o
end

local saved = {}
for _, k in ipairs({ "CreateFont", "GameFontHighlightSmall", "DFFontHighlightSmall" }) do saved[k] = _G[k] end
GameFontHighlightSmall = fontObject("Fonts\\FRIZQT__.TTF", 10, "")
DFFontHighlightSmall = nil
CreateFont = function(name)
    local o = fontObject()
    _G[name] = o
    return o
end

local UI = { FontObjects = {} }
function UI:Hook(name)
    local h = rawget(self, "hooks")
    return h and h[name] or nil
end
load_ui_file_into("Fonts.lua", { __DandersUI = UI })

local function host(hooks)
    return setmetatable({ hooks = hooks }, { __index = UI })
end

print("-- Kit fonts: a sized label follows the shared font when its host has no setting")
do
    check(UI.FontObjects.DFFontHighlightSmall ~= nil, "fonts: the shared DFFont object exists")
    -- The owning host re-skins the shared object.
    UI.FontObjects.DFFontHighlightSmall:SetFont("Fonts\\Roboto.ttf", 10, "OUTLINE")

    local mover = host({})
    local fs = fontObject()
    mover:SetSettingsFont(fs, 11)
    local path, size, flags = fs:GetFont()
    eq(path, "Fonts\\Roboto.ttf", "fonts: a host with no font setting takes the shared object's font")
    eq(size, 11, "fonts: ...at the label's own size")
    eq(flags, "OUTLINE", "fonts: ...and the shared outline")

    local owner = host({
        getFontSetting = function() return "Mine", "" end,
        resolveFontPath = function(name) return name == "Mine" and "Fonts\\Mine.ttf" or nil end,
    })
    local fs2 = fontObject()
    owner:SetSettingsFont(fs2, 12)
    eq((fs2:GetFont()), "Fonts\\Mine.ttf", "fonts: a host with a setting still applies its own")
end

for k, v in pairs(saved) do _G[k] = v end
