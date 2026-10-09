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

print("-- Kit fonts: a refresh re-applies our font object under every root, keeping the widget's own styling")
do
    local shared = UI.FontObjects.DFFontHighlightSmall
    local function label(fo, text)
        local fs = { _fo = fo, _text = text, _setObj = 0, _c = { 0.9, 0.2, 0.2, 1 },
                     _jh = "LEFT", _jv = "TOP", _sc = { 0, 0, 0, 1 }, _so = { 1, -1 }, _sp = 3 }
        function fs:GetObjectType() return "FontString" end
        function fs:GetFontObject() return self._fo end
        function fs:SetFontObject(o)
            -- What the client does: the object's own colour/justify/shadow/spacing land too.
            self._fo, self._setObj = o, self._setObj + 1
            self._c, self._jh, self._jv = { 1, 1, 1, 1 }, "CENTER", "MIDDLE"
            self._sc, self._so, self._sp = { 0, 0, 0, 0 }, { 0, 0 }, 0
        end
        function fs:GetTextColor() return unpack(self._c) end
        function fs:SetTextColor(r, g, b, a) self._c = { r, g, b, a } end
        function fs:GetJustifyH() return self._jh end
        function fs:SetJustifyH(v) self._jh = v end
        function fs:GetJustifyV() return self._jv end
        function fs:SetJustifyV(v) self._jv = v end
        function fs:GetShadowColor() return unpack(self._sc) end
        function fs:SetShadowColor(r, g, b, a) self._sc = { r, g, b, a } end
        function fs:GetShadowOffset() return unpack(self._so) end
        function fs:SetShadowOffset(x, y) self._so = { x, y } end
        function fs:GetSpacing() return self._sp end
        function fs:SetSpacing(v) self._sp = v end
        function fs:GetText() return self._text end
        function fs:SetText(t) self._text = t end
        return fs
    end
    local ours = label(shared, "Delete Current Profile")
    local foreign = label({}, "Styled elsewhere")
    local button = { GetObjectType = function() return "Button" end,
                     GetChildren = function() end,
                     GetRegions = function() return ours, foreign end }
    local root = { GetObjectType = function() return "Frame" end,
                   GetChildren = function() return button end,
                   GetRegions = function() end }

    local h = host({})
    h:AddFontRoot(root)
    h:RefreshSettingsFont()
    eq(ours._setObj, 1, "refresh: a label under a registered root has our font object re-applied")
    eq(ours._c[1], 0.9, "refresh: ...keeping its own colour")
    eq(ours._jh, "LEFT", "refresh: ...its justification")
    eq(ours._so[1], 1, "refresh: ...its shadow offset")
    eq(ours._sp, 3, "refresh: ...and its spacing")
    eq(ours._text, "Delete Current Profile", "refresh: ...and its text")
    eq(foreign._setObj, 0, "refresh: a label on someone else's font object is left alone")
end

for k, v in pairs(saved) do _G[k] = v end
