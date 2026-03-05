local addonName, DF = ...

-- ============================================================
-- AURA DESIGNER - OPTIONS GUI
-- Custom page layout: left content area + fixed 280px right panel
-- Called from Options/Options.lua via DF.BuildAuraDesignerPage()
-- ============================================================

local pairs, ipairs, type = pairs, ipairs, type
local format = string.format
local wipe = wipe
local tinsert = table.insert
local tremove = table.remove
local max, min = math.max, math.min
local sort = table.sort

-- Local references set during BuildAuraDesignerPage
local GUI
local page
local db
local Adapter

-- State
local selectedSpec = nil         -- Current spec key being viewed

-- Reusable color constants (mirrors GUI.lua)
local C_BACKGROUND = {r = 0.08, g = 0.08, b = 0.08, a = 0.95}
local C_PANEL      = {r = 0.12, g = 0.12, b = 0.12, a = 1}
local C_ELEMENT    = {r = 0.18, g = 0.18, b = 0.18, a = 1}
local C_BORDER     = {r = 0.25, g = 0.25, b = 0.25, a = 1}
local C_HOVER      = {r = 0.22, g = 0.22, b = 0.22, a = 1}
local C_TEXT       = {r = 0.9, g = 0.9, b = 0.9, a = 1}
local C_TEXT_DIM   = {r = 0.6, g = 0.6, b = 0.6, a = 1}

-- Indicator type definitions
local INDICATOR_TYPES = {
    { key = "icon",       label = "Icon",             placed = true  },
    { key = "square",     label = "Square",           placed = true  },
    { key = "bar",        label = "Bar",              placed = true  },
    { key = "border",     label = "Border",           placed = false },
    { key = "healthbar",  label = "Health Bar Color", placed = false },
    { key = "nametext",   label = "Name Text Color",  placed = false },
    { key = "healthtext", label = "Health Text Color", placed = false },
    { key = "framealpha", label = "Frame Alpha",      placed = false },
}

local ANCHOR_OPTIONS = {
    CENTER = "Center", TOP = "Top", BOTTOM = "Bottom", LEFT = "Left", RIGHT = "Right",
    TOPLEFT = "Top Left", TOPRIGHT = "Top Right", BOTTOMLEFT = "Bottom Left", BOTTOMRIGHT = "Bottom Right",
    _order = {"TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT"},
}

local GROWTH_OPTIONS = {
    RIGHT = "Right", LEFT = "Left", UP = "Up", DOWN = "Down",
    _order = {"RIGHT", "LEFT", "UP", "DOWN"},
}

local BORDER_STYLE_OPTIONS = {
    SOLID = "Solid Border", ANIMATED = "Animated Border", DASHED = "Dashed Border",
    GLOW = "Glow", CORNERS = "Corners Only",
    _order = {"SOLID", "ANIMATED", "DASHED", "GLOW", "CORNERS"},
}

local HEALTHBAR_MODE_OPTIONS = {
    Replace = "Replace", Tint = "Tint",
    _order = {"Replace", "Tint"},
}

local BAR_ORIENT_OPTIONS = {
    HORIZONTAL = "Horizontal", VERTICAL = "Vertical",
    _order = {"HORIZONTAL", "VERTICAL"},
}

local OUTLINE_OPTIONS = {
    NONE = "None", OUTLINE = "Outline", THICKOUTLINE = "Thick Outline", SHADOW = "Shadow",
    _order = {"NONE", "OUTLINE", "THICKOUTLINE", "SHADOW"},
}

-- ============================================================
-- HELPERS
-- ============================================================

local function MigrateToSpecScoped(adDB)
    if not adDB or adDB._specScopedV1 then return end
    if not adDB.auras then adDB._specScopedV1 = true; return end
    local isFlat = false
    for _, val in pairs(adDB.auras) do
        if type(val) == "table" and (val.priority ~= nil or val.indicators ~= nil) then
            isFlat = true
            break
        end
    end
    if isFlat then
        local oldAuras = adDB.auras
        local newAuras = {}
        local auraToSpecs = {}
        local trackable = DF.AuraDesigner and DF.AuraDesigner.TrackableAuras
        if trackable then
            for specKey, auraList in pairs(trackable) do
                for _, info in ipairs(auraList) do
                    if not auraToSpecs[info.name] then auraToSpecs[info.name] = {} end
                    tinsert(auraToSpecs[info.name], specKey)
                end
            end
        end
        for auraName, auraCfg in pairs(oldAuras) do
            local specs = auraToSpecs[auraName]
            if specs then
                for _, specKey in ipairs(specs) do
                    if not newAuras[specKey] then newAuras[specKey] = {} end
                    newAuras[specKey][auraName] = DF:DeepCopy(auraCfg)
                end
            end
        end
        adDB.auras = newAuras
    end
    adDB._specScopedV1 = true
end

-- Expose for Engine.lua and post-import use
DF.MigrateAuraDesignerSpecScope = MigrateToSpecScoped

local function GetAuraDesignerDB()
    local adDB = db.auraDesigner
    if adDB and not adDB._specScopedV1 then
        MigrateToSpecScoped(adDB)
    end
    return adDB
end

local function GetThemeColor()
    return GUI.GetThemeColor()
end

local function ApplyBackdrop(frame, bgColor, borderColor)
    if not frame.SetBackdrop then Mixin(frame, BackdropTemplateMixin) end
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    if bgColor then
        frame:SetBackdropColor(bgColor.r, bgColor.g, bgColor.b, bgColor.a or 1)
    end
    if borderColor then
        frame:SetBackdropBorderColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1)
    end
end

-- ============================================================
-- BUFF COEXISTENCE POPUP
-- Shown once when the user enables Aura Designer, asking whether
-- to keep standard buff icons or let AD fully replace them.
-- ============================================================

local buffCoexistPopup

local function ShowBuffCoexistPopup(onConfirm, onCancel)
    if not buffCoexistPopup then
        local f = CreateFrame("Frame", "DFADBuffPopup", UIParent, "BackdropTemplate")
        f:SetSize(420, 130)
        f:SetPoint("CENTER")
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetFrameLevel(250)
        f:EnableMouse(true)
        local tc = GetThemeColor()
        ApplyBackdrop(f, {r = 0.10, g = 0.10, b = 0.10, a = 0.98}, {r = tc.r, g = tc.g, b = tc.b, a = 1})

        -- Thin accent stripe along the top
        local stripe = f:CreateTexture(nil, "OVERLAY")
        stripe:SetColorTexture(tc.r, tc.g, tc.b, 0.8)
        stripe:SetHeight(2)
        stripe:SetPoint("TOPLEFT", 1, -1)
        stripe:SetPoint("TOPRIGHT", -1, -1)
        f._stripe = stripe

        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", 0, -12)
        title:SetText("Aura Designer")
        title:SetTextColor(tc.r, tc.g, tc.b)

        local desc = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        desc:SetPoint("TOP", title, "BOTTOM", 0, -6)
        desc:SetWidth(390)
        desc:SetText("Would you like to keep standard buff icons alongside\nAura Designer, or let it fully replace them?")
        desc:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        desc:SetJustifyH("CENTER")

        local function MakeButton(parent, text, xOff)
            local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
            btn:SetSize(170, 28)
            btn:SetPoint("BOTTOM", parent, "BOTTOM", xOff, 14)
            ApplyBackdrop(btn, C_ELEMENT, C_BORDER)
            btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            btn.text:SetPoint("CENTER")
            btn.text:SetText(text)
            btn:SetScript("OnEnter", function(self)
                local tc = GetThemeColor()
                self:SetBackdropBorderColor(tc.r, tc.g, tc.b, 1)
            end)
            btn:SetScript("OnLeave", function(self)
                self:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, C_BORDER.a)
            end)
            return btn
        end

        f.keepBtn = MakeButton(f, "Keep Buffs", -95)
        f.replaceBtn = MakeButton(f, "Replace Buffs", 95)

        -- Close on Escape
        f:SetScript("OnKeyDown", function(self, key)
            if key == "ESCAPE" then
                self:SetPropagateKeyboardInput(false)
                self:Hide()
                if self._onCancel then self._onCancel() end
            else
                self:SetPropagateKeyboardInput(true)
            end
        end)

        buffCoexistPopup = f
    end

    local f = buffCoexistPopup
    f._onCancel = onCancel

    f.keepBtn:SetScript("OnClick", function()
        f:Hide()
        if onConfirm then onConfirm(true) end
    end)
    f.replaceBtn:SetScript("OnClick", function()
        f:Hide()
        if onConfirm then onConfirm(false) end
    end)

    f:Show()
end

-- Get or resolve the active spec key from settings
local function ResolveSpec()
    local adDB = GetAuraDesignerDB()
    if adDB.spec == "auto" then
        return Adapter:GetPlayerSpec()
    end
    return adDB.spec
end

-- Returns the spec-scoped auras sub-table, creating it if needed
local function GetSpecAuras(spec)
    local adDB = GetAuraDesignerDB()
    if not adDB then return {} end
    if not adDB.auras then adDB.auras = {} end
    spec = spec or ResolveSpec()
    if not spec then return {} end
    if not adDB.auras[spec] then adDB.auras[spec] = {} end
    return adDB.auras[spec]
end

-- Ensure an aura config table exists, creating it with defaults if needed
local function EnsureAuraConfig(auraName)
    local specAuras = GetSpecAuras()
    if not specAuras[auraName] then
        specAuras[auraName] = {
            priority = 5,
        }
    end
    return specAuras[auraName]
end

-- Ensure a type sub-table exists within an aura config
local function EnsureTypeConfig(auraName, typeKey)
    local auraCfg = EnsureAuraConfig(auraName)
    if not auraCfg[typeKey] then
        -- Read global defaults so new configs inherit user-configured values
        local adDB = GetAuraDesignerDB()
        local gd = adDB and adDB.defaults or {}

        -- Create default config for each type
        if typeKey == "icon" then
            auraCfg[typeKey] = {
                -- Placement
                anchor = "TOPLEFT", offsetX = 0, offsetY = 0,
                -- Size & appearance (from global defaults)
                size = gd.iconSize or 24, scale = gd.iconScale or 1.0, alpha = 1.0,
                -- Border
                borderEnabled = true, borderThickness = 1, borderInset = 1,
                hideSwipe = false,
                -- Duration text
                showDuration = gd.showDuration ~= false,
                durationFont = gd.durationFont or "Fonts\\FRIZQT__.TTF",
                durationScale = gd.durationScale or 1.0,
                durationOutline = gd.durationOutline or "OUTLINE",
                durationAnchor = "CENTER", durationX = 0, durationY = 0,
                durationColorByTime = true,
                -- Stack count
                showStacks = gd.showStacks ~= false, stackMinimum = 2,
                stackFont = gd.stackFont or "Fonts\\FRIZQT__.TTF",
                stackScale = gd.stackScale or 1.0,
                stackOutline = gd.stackOutline or "OUTLINE",
                stackAnchor = "BOTTOMRIGHT",
                stackX = 0, stackY = 0,
                -- Expiring
                expiringEnabled = false, expiringThreshold = 30,
                expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
            }
        elseif typeKey == "square" then
            auraCfg[typeKey] = {
                -- Placement
                anchor = "TOPLEFT", offsetX = 0, offsetY = 0,
                -- Appearance (from global defaults)
                size = gd.iconSize or 24, scale = gd.iconScale or 1.0, alpha = 1.0,
                color = {r = 1, g = 1, b = 1, a = 1},
                -- Border
                showBorder = true, borderThickness = 1, borderInset = 1,
                hideSwipe = false,
                -- Duration text
                showDuration = gd.showDuration ~= false,
                durationFont = gd.durationFont or "Fonts\\FRIZQT__.TTF",
                durationScale = gd.durationScale or 1.0,
                durationOutline = gd.durationOutline or "OUTLINE",
                durationAnchor = "CENTER", durationX = 0, durationY = 0,
                durationColorByTime = true,
                -- Stack count
                showStacks = gd.showStacks ~= false, stackMinimum = 2,
                stackFont = gd.stackFont or "Fonts\\FRIZQT__.TTF",
                stackScale = gd.stackScale or 1.0,
                stackOutline = gd.stackOutline or "OUTLINE",
                stackAnchor = "BOTTOMRIGHT",
                stackX = 0, stackY = 0,
                -- Expiring
                expiringEnabled = false, expiringThreshold = 30,
                expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
            }
        elseif typeKey == "bar" then
            auraCfg[typeKey] = {
                -- Placement
                anchor = "BOTTOM", offsetX = 0, offsetY = 0,
                -- Size & orientation
                orientation = "HORIZONTAL", width = 60, height = 6,
                matchFrameWidth = true, matchFrameHeight = false,
                -- Texture & colors
                texture = "Interface\\TargetingFrame\\UI-StatusBar",
                fillColor = {r = 1, g = 1, b = 1, a = 1},
                bgColor = {r = 0, g = 0, b = 0, a = 0.5},
                -- Border
                showBorder = true, borderThickness = 1,
                borderColor = {r = 0, g = 0, b = 0, a = 1},
                -- Alpha
                alpha = 1.0,
                -- Bar color by time
                barColorByTime = false,
                -- Expiring color
                expiringEnabled = false, expiringThreshold = 30,
                expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
                -- Duration text
                showDuration = true,
                durationFont = gd.durationFont or "Fonts\\FRIZQT__.TTF",
                durationScale = gd.durationScale or 1.0,
                durationOutline = gd.durationOutline or "OUTLINE",
                durationAnchor = "CENTER", durationX = 0, durationY = 0,
                durationColorByTime = true,
            }
        elseif typeKey == "border" then
            auraCfg[typeKey] = {
                style = "SOLID", color = {r = 1, g = 1, b = 1, a = 1},
                thickness = 2, inset = 0,
                expiringEnabled = false, expiringThreshold = 30,
                expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
            }
        elseif typeKey == "healthbar" then
            auraCfg[typeKey] = {
                mode = "Replace", color = {r = 1, g = 1, b = 1, a = 1}, blend = 0.5,
                expiringEnabled = false, expiringThreshold = 30,
                expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
            }
        elseif typeKey == "nametext" then
            auraCfg[typeKey] = {
                color = {r = 1, g = 1, b = 1, a = 1},
                expiringEnabled = false, expiringThreshold = 30,
                expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
            }
        elseif typeKey == "healthtext" then
            auraCfg[typeKey] = {
                color = {r = 1, g = 1, b = 1, a = 1},
                expiringEnabled = false, expiringThreshold = 30,
                expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
            }
        elseif typeKey == "framealpha" then
            auraCfg[typeKey] = {
                alpha = 0.5,
                expiringEnabled = false, expiringThreshold = 30,
                expiringAlpha = 1.0,
            }
        end
    end
    return auraCfg[typeKey]
end

-- Default values per type key, used as fallback when a saved config is missing new keys
local TYPE_DEFAULTS = {
    icon = {
        anchor = "TOPLEFT", offsetX = 0, offsetY = 0,
        size = 24, scale = 1.0, alpha = 1.0,
        borderEnabled = true, borderThickness = 1, borderInset = 1,
        hideSwipe = false,
        showDuration = true, durationFont = "Fonts\\FRIZQT__.TTF",
        durationScale = 1.0, durationOutline = "OUTLINE",
        durationAnchor = "CENTER", durationX = 0, durationY = 0,
        durationColorByTime = true,
        showStacks = true, stackMinimum = 2,
        stackFont = "Fonts\\FRIZQT__.TTF", stackScale = 1.0,
        stackOutline = "OUTLINE", stackAnchor = "BOTTOMRIGHT",
        stackX = 0, stackY = 0,
        expiringEnabled = false, expiringThreshold = 30,
        expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
    },
    square = {
        anchor = "TOPLEFT", offsetX = 0, offsetY = 0,
        size = 24, scale = 1.0, alpha = 1.0,
        color = {r = 1, g = 1, b = 1, a = 1},
        showBorder = true, borderThickness = 1, borderInset = 1,
        hideSwipe = false,
        showDuration = true, durationFont = "Fonts\\FRIZQT__.TTF",
        durationScale = 1.0, durationOutline = "OUTLINE",
        durationAnchor = "CENTER", durationX = 0, durationY = 0,
        durationColorByTime = true,
        showStacks = true, stackMinimum = 2,
        stackFont = "Fonts\\FRIZQT__.TTF", stackScale = 1.0,
        stackOutline = "OUTLINE", stackAnchor = "BOTTOMRIGHT",
        stackX = 0, stackY = 0,
        expiringEnabled = false, expiringThreshold = 30,
        expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
    },
    bar = {
        anchor = "BOTTOM", offsetX = 0, offsetY = 0,
        orientation = "HORIZONTAL", width = 60, height = 6,
        matchFrameWidth = true, matchFrameHeight = false,
        texture = "Interface\\TargetingFrame\\UI-StatusBar",
        fillColor = {r = 1, g = 1, b = 1, a = 1},
        bgColor = {r = 0, g = 0, b = 0, a = 0.5},
        showBorder = true, borderThickness = 1,
        borderColor = {r = 0, g = 0, b = 0, a = 1},
        alpha = 1.0,
        barColorByTime = false,
        expiringEnabled = false, expiringThreshold = 5,
        expiringColor = {r = 1, g = 0.2, b = 0.2, a = 1},
        showDuration = true, durationFont = "Fonts\\FRIZQT__.TTF",
        durationScale = 1.0, durationOutline = "OUTLINE",
        durationAnchor = "CENTER", durationX = 0, durationY = 0,
        durationColorByTime = true,
    },
}

-- ============================================================
-- INSTANCE-BASED INDICATOR HELPERS
-- Placed indicators (icon/square/bar) are stored as instances
-- in auraCfg.indicators[] with stable IDs.
-- ============================================================

-- Create a new indicator instance for an aura, returns the instance table
local function CreateIndicatorInstance(auraName, typeKey)
    local auraCfg = EnsureAuraConfig(auraName)
    if not auraCfg.indicators then
        auraCfg.indicators = {}
    end
    if not auraCfg.nextIndicatorID then
        auraCfg.nextIndicatorID = 1
    end

    -- Only store id, type, and anchor — all other settings fall through
    -- to global defaults then TYPE_DEFAULTS via CreateInstanceProxy
    local defaults = TYPE_DEFAULTS[typeKey]

    -- Create minimal instance: just id + type + anchor placement
    local instance = {
        anchor = defaults and defaults.anchor or "TOPLEFT",
        offsetX = 0,
        offsetY = 0,
    }

    instance.id = auraCfg.nextIndicatorID
    instance.type = typeKey
    auraCfg.nextIndicatorID = auraCfg.nextIndicatorID + 1

    tinsert(auraCfg.indicators, instance)
    return instance
end

-- Find an indicator instance by its stable ID
local function GetIndicatorByID(auraName, indicatorID)
    local auraCfg = GetSpecAuras()[auraName]
    if not auraCfg or not auraCfg.indicators then return nil end
    for _, inst in ipairs(auraCfg.indicators) do
        if inst.id == indicatorID then
            return inst
        end
    end
    return nil
end

-- Remove an indicator instance by its stable ID
local function RemoveIndicatorInstance(auraName, indicatorID)
    local auraCfg = GetSpecAuras()[auraName]
    if not auraCfg or not auraCfg.indicators then return end
    for i, inst in ipairs(auraCfg.indicators) do
        if inst.id == indicatorID then
            table.remove(auraCfg.indicators, i)
            return
        end
    end
end

-- Change an instance's type (icon/square/bar), keeping anchor/offset
local function ChangeInstanceType(auraName, indicatorID, newType)
    local inst = GetIndicatorByID(auraName, indicatorID)
    if not inst then return end

    -- Preserve placement
    local savedID = inst.id
    local savedAnchor = inst.anchor
    local savedOffX = inst.offsetX
    local savedOffY = inst.offsetY

    -- Wipe everything, keep minimal: id + type + placement
    -- All other settings fall through to global defaults → TYPE_DEFAULTS via proxy
    wipe(inst)
    inst.id = savedID
    inst.type = newType
    inst.anchor = savedAnchor or (TYPE_DEFAULTS[newType] and TYPE_DEFAULTS[newType].anchor) or "TOPLEFT"
    inst.offsetX = savedOffX or 0
    inst.offsetY = savedOffY or 0
end

-- Keys to skip when copying appearance between indicators (identity + placement)
local COPY_SKIP_KEYS = { id = true, type = true, anchor = true, offsetX = true, offsetY = true }

-- Deep-copy a value (handles nested tables like color = {r,g,b,a})
local function DeepCopyValue(val)
    if type(val) == "table" then
        local copy = {}
        for k, v in pairs(val) do
            copy[k] = DeepCopyValue(v)
        end
        return copy
    end
    return val
end

-- Copy appearance settings from one placed indicator to another of the same type.
-- Copies all keys except identity (id, type) and placement (anchor, offsetX, offsetY).
-- Keys present on source are deep-copied; keys absent on source are removed from
-- destination so they fall through to defaults via the proxy chain.
local function CopyIndicatorAppearance(srcAuraName, srcIndicatorID, dstAuraName, dstIndicatorID)
    local src = GetIndicatorByID(srcAuraName, srcIndicatorID)
    local dst = GetIndicatorByID(dstAuraName, dstIndicatorID)
    if not src or not dst then return end
    if src.type ~= dst.type then return end

    -- Collect all non-skip keys from both source and destination
    local allKeys = {}
    for k in pairs(src) do
        if not COPY_SKIP_KEYS[k] then allKeys[k] = true end
    end
    for k in pairs(dst) do
        if not COPY_SKIP_KEYS[k] then allKeys[k] = true end
    end

    -- Sync: copy from src, clear from dst what src doesn't have
    for k in pairs(allKeys) do
        if src[k] ~= nil then
            dst[k] = DeepCopyValue(src[k])
        else
            dst[k] = nil
        end
    end
end

-- Forward declaration: lightweight preview refresh (defined after RefreshPreviewEffects)
-- Called from proxy __newindex so every setting change updates the preview in real-time
local RefreshPreviewLightweight

-- Global-default key mapping: which global default keys apply to placed types
local GLOBAL_DEFAULT_MAP = {
    icon   = {
        size = "iconSize", scale = "iconScale", showDuration = "showDuration", showStacks = "showStacks",
        durationFont = "durationFont", durationScale = "durationScale", durationOutline = "durationOutline",
        durationAnchor = "durationAnchor", durationX = "durationX", durationY = "durationY",
        durationColorByTime = "durationColorByTime",
        stackFont = "stackFont", stackScale = "stackScale", stackOutline = "stackOutline",
        stackAnchor = "stackAnchor", stackX = "stackX", stackY = "stackY",
        stackMinimum = "stackMinimum",
        hideSwipe = "hideSwipe",
    },
    square = {
        size = "iconSize", scale = "iconScale", showDuration = "showDuration", showStacks = "showStacks",
        durationFont = "durationFont", durationScale = "durationScale", durationOutline = "durationOutline",
        durationAnchor = "durationAnchor", durationX = "durationX", durationY = "durationY",
        durationColorByTime = "durationColorByTime",
        stackFont = "stackFont", stackScale = "stackScale", stackOutline = "stackOutline",
        stackAnchor = "stackAnchor", stackX = "stackX", stackY = "stackY",
        stackMinimum = "stackMinimum",
        hideSwipe = "hideSwipe",
    },
    bar    = {
        durationFont = "durationFont", durationScale = "durationScale", durationOutline = "durationOutline",
        durationAnchor = "durationAnchor", durationX = "durationX", durationY = "durationY",
        durationColorByTime = "durationColorByTime",
    },
}

-- Create a proxy table that maps flat key access to an indicator instance
-- Fallback chain: instance value → global defaults → TYPE_DEFAULTS
local function CreateInstanceProxy(auraName, indicatorID)
    return setmetatable({}, {
        __index = function(_, k)
            local inst = GetIndicatorByID(auraName, indicatorID)
            if inst then
                local val = inst[k]
                if val ~= nil then return val end
            end
            -- Fall back to global defaults for applicable keys
            local fallback
            if inst and inst.type then
                local gdMap = GLOBAL_DEFAULT_MAP[inst.type]
                if gdMap then
                    local gdKey = gdMap[k]
                    if gdKey then
                        local adDB = GetAuraDesignerDB()
                        local gd = adDB and adDB.defaults
                        if gd and gd[gdKey] ~= nil then fallback = gd[gdKey] end
                    end
                end
                -- Then fall back to TYPE_DEFAULTS
                if fallback == nil then
                    local defaults = TYPE_DEFAULTS[inst.type]
                    if defaults then fallback = defaults[k] end
                end
            end
            -- Copy-on-read: if fallback is a table, copy it into the instance
            -- so that sub-key mutations (e.g. proxy.color.r = 1) persist
            if type(fallback) == "table" and inst then
                local copy = {}
                for fk, fv in pairs(fallback) do copy[fk] = fv end
                inst[k] = copy
                return copy
            end
            return fallback
        end,
        __newindex = function(_, k, v)
            local inst = GetIndicatorByID(auraName, indicatorID)
            if not inst then return end
            inst[k] = v
            if RefreshPreviewLightweight then RefreshPreviewLightweight() end
        end,
    })
end

-- Create a proxy table that maps flat key access to nested aura config
local function CreateProxy(auraName, typeKey)
    local defaults = TYPE_DEFAULTS[typeKey]
    return setmetatable({}, {
        __index = function(_, k)
            local auraCfg = GetSpecAuras()[auraName]
            if auraCfg and auraCfg[typeKey] then
                local val = auraCfg[typeKey][k]
                if val ~= nil then return val end
            end
            -- Fall back to defaults for missing keys
            local fallback = defaults and defaults[k] or nil
            -- Copy-on-read: if fallback is a table, copy it into the config
            -- so that sub-key mutations (e.g. proxy.color.r = 1) persist
            if type(fallback) == "table" then
                local typeCfg = EnsureTypeConfig(auraName, typeKey)
                local copy = {}
                for fk, fv in pairs(fallback) do copy[fk] = fv end
                typeCfg[k] = copy
                return copy
            end
            return fallback
        end,
        __newindex = function(_, k, v)
            local typeCfg = EnsureTypeConfig(auraName, typeKey)
            typeCfg[k] = v
            if RefreshPreviewLightweight then RefreshPreviewLightweight() end
        end,
    })
end

-- Create a proxy for the aura-level config (priority, expiring)
local function CreateAuraProxy(auraName)
    return setmetatable({}, {
        __index = function(_, k)
            local auraCfg = GetSpecAuras()[auraName]
            if auraCfg then return auraCfg[k] end
            return nil
        end,
        __newindex = function(_, k, v)
            local auraCfg = EnsureAuraConfig(auraName)
            auraCfg[k] = v
            if RefreshPreviewLightweight then RefreshPreviewLightweight() end
        end,
    })
end

-- Get spell icon texture for an aura
-- Uses static texture IDs to avoid C_Spell.GetSpellTexture returning
-- the wrong icon when talent choice nodes replace a spell.
local function GetAuraIcon(specKey, auraName)
    -- Static icon table — always returns the correct icon regardless of talents
    local icons = DF.AuraDesigner.IconTextures
    if icons and icons[auraName] then
        return icons[auraName]
    end
    -- Fallback to dynamic API for any aura not in the static table
    local spellIDs = DF.AuraDesigner.SpellIDs
    if not spellIDs or not specKey then return nil end
    local specIDs = spellIDs[specKey]
    if not specIDs then return nil end
    local spellID = specIDs[auraName]
    if not spellID or spellID == 0 then return nil end
    if C_Spell and C_Spell.GetSpellTexture then
        return C_Spell.GetSpellTexture(spellID)
    elseif GetSpellTexture then
        return GetSpellTexture(spellID)
    end
    return nil
end

-- Count active effects for an aura (instances + frame-level types)
local function CountActiveEffects(auraName)
    local auraCfg = GetSpecAuras()[auraName]
    if not auraCfg then return 0 end
    local count = 0
    -- Count placed indicator instances
    if auraCfg.indicators then
        count = count + #auraCfg.indicators
    end
    -- Count frame-level types
    for _, typeDef in ipairs(INDICATOR_TYPES) do
        if not typeDef.placed and auraCfg[typeDef.key] then
            count = count + 1
        end
    end
    return count
end

-- ============================================================
-- MULTI-TRIGGER HELPERS
-- Functions for managing trigger auras on frame-level effects
-- ============================================================

-- Get triggers for a frame effect (returns owning aura name in a table if no explicit triggers)
local function GetFrameEffectTriggers(auraName, typeKey)
    local auraCfg = GetSpecAuras()[auraName]
    local typeCfg = auraCfg and auraCfg[typeKey]
    if typeCfg and typeCfg.triggers then
        return typeCfg.triggers
    end
    return { auraName }  -- Default: just the owning aura
end

-- Add a trigger aura to a frame effect
local function AddFrameEffectTrigger(auraName, typeKey, triggerName)
    local typeCfg = EnsureTypeConfig(auraName, typeKey)
    if not typeCfg.triggers then
        typeCfg.triggers = { auraName }  -- Initialize with owner
    end
    -- Check not already present
    for _, t in ipairs(typeCfg.triggers) do
        if t == triggerName then return end
    end
    tinsert(typeCfg.triggers, triggerName)
end

-- Remove a trigger aura from a frame effect (minimum 1 trigger required)
local function RemoveFrameEffectTrigger(auraName, typeKey, triggerName)
    local auraCfg = GetSpecAuras()[auraName]
    local typeCfg = auraCfg and auraCfg[typeKey]
    if not typeCfg or not typeCfg.triggers or #typeCfg.triggers <= 1 then return end
    for i, t in ipairs(typeCfg.triggers) do
        if t == triggerName then
            tremove(typeCfg.triggers, i)
            break
        end
    end
end

-- ============================================================
-- LAYOUT GROUP HELPERS
-- Functions for managing layout groups
-- ============================================================

-- State for expanded layout group cards
local expandedGroups = {}

-- Find which layout group (if any) an indicator belongs to
local function GetIndicatorLayoutGroup(auraName, indicatorID)
    local adDB = GetAuraDesignerDB()
    if not adDB or not adDB.layoutGroups then return nil end
    for _, group in ipairs(adDB.layoutGroups) do
        if group.members then
            for _, member in ipairs(group.members) do
                if member.auraName == auraName and member.indicatorID == indicatorID then
                    return group
                end
            end
        end
    end
    return nil
end

-- Get all placed indicators NOT in any layout group
local function GetUngroupedIndicators()
    local adDB = GetAuraDesignerDB()
    if not adDB then return {} end
    -- Build set of grouped indicators
    local grouped = {}
    if adDB.layoutGroups then
        for _, group in ipairs(adDB.layoutGroups) do
            if group.members then
                for _, member in ipairs(group.members) do
                    grouped[member.auraName .. "#" .. member.indicatorID] = true
                end
            end
        end
    end
    -- Collect ungrouped
    local result = {}
    local spec = ResolveSpec()
    local trackable = spec and Adapter and Adapter:GetTrackableAuras(spec)
    local displayNames = {}
    if trackable then
        for _, info in ipairs(trackable) do
            displayNames[info.name] = info.display
        end
    end
    for auraName, auraCfg in pairs(GetSpecAuras(spec)) do
        if auraCfg.indicators then
            for _, ind in ipairs(auraCfg.indicators) do
                local key = auraName .. "#" .. ind.id
                if not grouped[key] then
                    tinsert(result, {
                        auraName = auraName,
                        displayName = displayNames[auraName] or auraName,
                        indicatorID = ind.id,
                        typeKey = ind.type,
                    })
                end
            end
        end
    end
    return result
end

-- Create a new layout group
local function CreateLayoutGroup(name)
    local adDB = GetAuraDesignerDB()
    if not adDB then return nil end
    if not adDB.layoutGroups then adDB.layoutGroups = {} end
    if not adDB.nextLayoutGroupID then adDB.nextLayoutGroupID = 1 end
    local id = adDB.nextLayoutGroupID
    adDB.nextLayoutGroupID = id + 1
    local group = {
        id = id,
        name = name or ("Group " .. id),
        anchor = "TOPLEFT",
        offsetX = 0,
        offsetY = 0,
        growDirection = "RIGHT",
        spacing = 2,
        members = {},
    }
    tinsert(adDB.layoutGroups, group)
    return group
end

-- Delete a layout group by ID
local function DeleteLayoutGroup(groupID)
    local adDB = GetAuraDesignerDB()
    if not adDB or not adDB.layoutGroups then return end
    for i, group in ipairs(adDB.layoutGroups) do
        if group.id == groupID then
            -- Delete all member indicators when deleting the group
            if group.members then
                for _, member in ipairs(group.members) do
                    RemoveIndicatorInstance(member.auraName, member.indicatorID)
                end
            end
            tremove(adDB.layoutGroups, i)
            break
        end
    end
    expandedGroups[groupID] = nil
end

-- Find a layout group by ID
local function GetLayoutGroupByID(groupID)
    local adDB = GetAuraDesignerDB()
    if not adDB or not adDB.layoutGroups then return nil end
    for _, group in ipairs(adDB.layoutGroups) do
        if group.id == groupID then return group end
    end
    return nil
end

-- Add a member to a layout group
local function AddGroupMember(groupID, auraName, indicatorID)
    local group = GetLayoutGroupByID(groupID)
    if not group then return end
    if not group.members then group.members = {} end
    -- Check not already in this group
    for _, m in ipairs(group.members) do
        if m.auraName == auraName and m.indicatorID == indicatorID then return end
    end
    tinsert(group.members, { auraName = auraName, indicatorID = indicatorID })
end

-- Remove a member from a layout group
local function RemoveGroupMember(groupID, auraName, indicatorID)
    local group = GetLayoutGroupByID(groupID)
    if not group or not group.members then return end
    for i, m in ipairs(group.members) do
        if m.auraName == auraName and m.indicatorID == indicatorID then
            tremove(group.members, i)
            break
        end
    end
end

-- Swap two members in a layout group (for reordering)
local function SwapGroupMembers(groupID, idx1, idx2)
    local group = GetLayoutGroupByID(groupID)
    if not group or not group.members then return end
    if idx1 < 1 or idx1 > #group.members or idx2 < 1 or idx2 > #group.members then return end
    group.members[idx1], group.members[idx2] = group.members[idx2], group.members[idx1]
end

-- Anchor dot pool (populated during CreateFramePreview, used by drag system)
local anchorDots = {}

-- Anchor point positions relative to the mock frame
local ANCHOR_POSITIONS = {
    TOPLEFT     = { x = 0,   y = 0,    ax = "TOPLEFT",     ay = "TOPLEFT"     },
    TOP         = { x = 0.5, y = 0,    ax = "TOP",         ay = "TOP"         },
    TOPRIGHT    = { x = 1,   y = 0,    ax = "TOPRIGHT",    ay = "TOPRIGHT"    },
    LEFT        = { x = 0,   y = 0.5,  ax = "LEFT",        ay = "LEFT"        },
    CENTER      = { x = 0.5, y = 0.5,  ax = "CENTER",      ay = "CENTER"      },
    RIGHT       = { x = 1,   y = 0.5,  ax = "RIGHT",       ay = "RIGHT"       },
    BOTTOMLEFT  = { x = 0,   y = 1,    ax = "BOTTOMLEFT",  ay = "BOTTOMLEFT"  },
    BOTTOM      = { x = 0.5, y = 1,    ax = "BOTTOM",      ay = "BOTTOM"      },
    BOTTOMRIGHT = { x = 1,   y = 1,    ax = "BOTTOMRIGHT", ay = "BOTTOMRIGHT" },
}

-- ============================================================
-- FRAME REFERENCES (populated during build)
-- Declared early so drag/indicator/effects code can capture them
-- ============================================================
local mainFrame           -- The root frame for the entire page
local leftPanel           -- Left content area (frame preview)
local rightPanel          -- Right settings panel (tabbed)
local enableBanner        -- Enable toggle banner
local coexistBanner       -- "Buffs are also visible" info strip
local framePreview        -- Mock unit frame preview
local dragHintText        -- Dynamic hint text below frame preview

-- Layout anchors — stored during build so RefreshPage can shift content
-- when the coexistence banner is shown/hidden
local COEXIST_BANNER_H = 24
local COEXIST_GAP       = 4
local contentBaseY          -- yPos where content starts (below enable banner)
local contentRightInset     -- Right inset for left-side panels
local origY_framePreview    -- original yPos of framePreview
local currentBannerShift = 0 -- tracks current coexist banner offset

-- ============================================================
-- UI STATE (v4 redesign — tabbed right panel)
-- ============================================================
local activeTab = "effects"       -- "effects" | "layout" | "global"
local activeFilter = "all"        -- Filter chip state
local expandedCards = {}           -- { ["placed:AuraName#1"] = true, ["frame:border:AuraName"] = true }
local spellPickerActive = false    -- Is spell picker overlay showing
local spellPickerType = nil        -- "icon" | "square" | "bar"

-- Tab system frame references
local tabBar                -- Tab bar frame (Effects | Layout Groups | Global)
local tabButtons = {}       -- { effects = btn, layout = btn, global = btn }
local tabContentFrame       -- Scrollable content area below tabs
local tabScrollFrame        -- ScrollFrame wrapping tabContentFrame
local spellPickerView       -- Overlay view for spell picker (replaces tabs when active)
local effectCardPool = {}   -- Reusable card frames

-- ============================================================
-- EFFECTS LIST DATA COLLECTION
-- Gathers all effects across all auras into a flat list for
-- the new Effects tab. Replaces the old per-aura view.
-- ============================================================

local FRAME_LEVEL_TYPE_KEYS = { "border", "healthbar", "nametext", "healthtext", "framealpha" }

local FRAME_LEVEL_LABELS = {
    border     = "Border",
    healthbar  = "Health Bar",
    nametext   = "Name Text",
    healthtext = "Health Text",
    framealpha = "Frame Alpha",
}

local PLACED_TYPE_LABELS = {
    icon   = "Icon",
    square = "Square",
    bar    = "Bar",
}

local BADGE_COLORS = {
    icon       = { r = 0.36, g = 0.72, b = 0.94 },  -- Blue
    square     = { r = 0.51, g = 0.86, b = 0.51 },  -- Green
    bar        = { r = 0.94, g = 0.71, b = 0.24 },  -- Orange
    border     = { r = 0.80, g = 0.50, b = 0.80 },  -- Purple
    healthbar  = { r = 0.94, g = 0.31, b = 0.31 },  -- Red
    nametext   = { r = 0.72, g = 0.72, b = 0.94 },  -- Light blue
    healthtext = { r = 0.72, g = 0.72, b = 0.94 },  -- Light blue
    framealpha = { r = 0.60, g = 0.60, b = 0.60 },  -- Grey
}

-- Collect all configured effects into a flat, sorted list
-- Returns: { { source="placed"|"frame", auraName, typeKey, ... }, ... }
local function CollectAllEffects()
    local effects = {}

    local spec = ResolveSpec()
    local trackable = spec and Adapter and Adapter:GetTrackableAuras(spec)
    -- Build display name lookup (only auras belonging to current spec)
    local displayNames = {}
    if trackable then
        for _, info in ipairs(trackable) do
            displayNames[info.name] = info.display
        end
    end

    for auraName, auraCfg in pairs(GetSpecAuras(spec)) do
        -- Only show effects for auras belonging to the current spec
        if displayNames[auraName] then
            -- Placed indicators
            if auraCfg.indicators then
                for _, indicator in ipairs(auraCfg.indicators) do
                    tinsert(effects, {
                        source      = "placed",
                        auraName    = auraName,
                        displayName = displayNames[auraName],
                        indicatorID = indicator.id,
                        typeKey     = indicator.type,
                        config      = indicator,
                        anchor      = indicator.anchor or "CENTER",
                    })
                end
            end

            -- Frame-level effects (current per-aura model)
            for _, typeKey in ipairs(FRAME_LEVEL_TYPE_KEYS) do
                if auraCfg[typeKey] then
                    tinsert(effects, {
                        source      = "frame",
                        auraName    = auraName,
                        displayName = displayNames[auraName],
                        typeKey     = typeKey,
                        config      = auraCfg[typeKey],
                    })
                end
            end
        end
    end

    -- Sort: newest first (reverse by insertion order — higher IDs first for placed)
    sort(effects, function(a, b)
        -- Placed before frame-level
        if a.source ~= b.source then
            return a.source == "placed"
        end
        -- Within placed: higher indicatorID first (newest)
        if a.source == "placed" and b.source == "placed" then
            return (a.indicatorID or 0) > (b.indicatorID or 0)
        end
        -- Within frame-level: alphabetical by type
        return a.typeKey < b.typeKey
    end)

    return effects
end

-- Check if a specific aura + type combo already has a placed indicator
local function IsAuraTypePlaced(auraName, typeKey)
    local auraCfg = GetSpecAuras()[auraName]
    if not auraCfg or not auraCfg.indicators then return false end
    for _, indicator in ipairs(auraCfg.indicators) do
        if indicator.type == typeKey then return true end
    end
    return false
end

-- ============================================================
-- DRAG AND DROP SYSTEM
-- Modeled after DandersCDM's ghost-based drag pattern:
--   Ghost frame (TOOLTIP strata, EnableMouse false) follows cursor
--   Anchor dots act as drop targets via OnEnter/OnLeave
--   OnUpdate frame polls IsMouseButtonDown for drop detection
-- ============================================================

local dragState = {
    isDragging = false,
    auraName = nil,         -- Which aura is being dragged
    auraInfo = nil,         -- Full aura info table
    specKey = nil,          -- Spec key for icon lookup
    dropAnchor = nil,       -- Currently hovered anchor name
    moveIndicatorID = nil,  -- Set when re-dragging an existing placed indicator
    indicatorType = nil,    -- "icon" | "square" | "bar" — type to create on drop
}

local dragGhost = nil
local dragUpdateFrame = nil

local function CreateDragGhost()
    if dragGhost then return dragGhost end

    dragGhost = CreateFrame("Frame", "DFAuraDesignerDragGhost", UIParent, "BackdropTemplate")
    dragGhost:SetSize(36, 36)
    dragGhost:SetFrameStrata("TOOLTIP")
    dragGhost:SetFrameLevel(1000)
    dragGhost:EnableMouse(false)  -- KEY: mouse events pass through to drop targets
    dragGhost:Hide()

    if not dragGhost.SetBackdrop then Mixin(dragGhost, BackdropTemplateMixin) end
    dragGhost:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
    })
    dragGhost:SetBackdropColor(0.05, 0.05, 0.05, 0.9)

    -- Spell icon
    local icon = dragGhost:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 3, -3)
    icon:SetPoint("BOTTOMRIGHT", -3, 3)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    dragGhost.icon = icon

    -- Name label under ghost
    local label = dragGhost:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOP", dragGhost, "BOTTOM", 0, -2)
    label:SetTextColor(1, 1, 1, 0.8)
    dragGhost.label = label

    return dragGhost
end

local EndDrag  -- forward declaration (defined below StartDrag)

local function StartDrag(auraName, auraInfo, specKey, indicatorType)
    if dragState.isDragging then return end

    dragState.isDragging = true
    dragState.auraName = auraName
    dragState.auraInfo = auraInfo
    dragState.specKey = specKey
    dragState.dropAnchor = nil
    dragState.indicatorType = indicatorType or "icon"

    -- Setup ghost
    local ghost = CreateDragGhost()
    local tc = GetThemeColor()
    ghost:SetBackdropBorderColor(tc.r, tc.g, tc.b, 1)

    -- Set icon
    local iconTex = GetAuraIcon(specKey, auraName)
    if iconTex then
        ghost.icon:SetTexture(iconTex)
    else
        ghost.icon:SetColorTexture(auraInfo.color[1] * 0.4, auraInfo.color[2] * 0.4, auraInfo.color[3] * 0.4, 1)
    end
    ghost.label:SetText(auraInfo.display)
    ghost:Show()

    -- Show drag hint
    if dragHintText then
        local tc = GetThemeColor()
        dragHintText:SetText("Drop on an anchor point to place " .. auraInfo.display)
        dragHintText:SetTextColor(tc.r, tc.g, tc.b, 0.9)
    end

    -- Show and enlarge all anchor dots to signal they are drop targets
    for _, dotFrame in pairs(anchorDots) do
        dotFrame:Show()
        dotFrame.dot:SetSize(10, 10)
        dotFrame.dot:SetColorTexture(0.45, 0.45, 0.95, 0.5)
    end

    -- Start cursor following
    if not dragUpdateFrame then
        dragUpdateFrame = CreateFrame("Frame")
    end
    dragUpdateFrame:SetScript("OnUpdate", function()
        if not dragState.isDragging then
            dragUpdateFrame:Hide()
            return
        end

        local x, y = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        local cursorX, cursorY = x / scale, y / scale

        -- Offset ghost below-right of cursor so drop target is visible
        ghost:ClearAllPoints()
        ghost:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cursorX + 10, cursorY - 10)

        -- Detect mouse release
        if not IsMouseButtonDown("LeftButton") then
            EndDrag()
        end
    end)
    dragUpdateFrame:Show()
end

-- Start a move-drag for an existing placed indicator.
-- Reuses the same ghost + cursor-following + anchor-dot system as StartDrag.
local function StartMoveDrag(auraName, indicatorID, specKey)
    if dragState.isDragging then return end

    dragState.isDragging = true
    dragState.auraName = auraName
    dragState.moveIndicatorID = indicatorID
    dragState.specKey = specKey
    dragState.dropAnchor = nil

    -- Build minimal auraInfo for hints
    local adDB = GetAuraDesignerDB()
    local auraList = Adapter and Adapter:GetTrackableAuras(ResolveSpec())
    local displayName = auraName
    if auraList then
        for _, info in ipairs(auraList) do
            if info.name == auraName then
                dragState.auraInfo = info
                displayName = info.display or auraName
                break
            end
        end
    end

    -- Setup ghost
    local ghost = CreateDragGhost()
    local tc = GetThemeColor()
    ghost:SetBackdropBorderColor(tc.r, tc.g, tc.b, 1)

    local iconTex = GetAuraIcon(specKey, auraName)
    if iconTex then
        ghost.icon:SetTexture(iconTex)
    else
        ghost.icon:SetColorTexture(0.3, 0.3, 0.3, 1)
    end
    ghost.label:SetText(displayName)
    ghost:Show()

    -- Show drag hint
    if dragHintText then
        dragHintText:SetText("Drop on an anchor point to move " .. displayName)
        dragHintText:SetTextColor(tc.r, tc.g, tc.b, 0.9)
    end

    -- Show and enlarge all anchor dots
    for _, dotFrame in pairs(anchorDots) do
        dotFrame:Show()
        dotFrame.dot:SetSize(10, 10)
        dotFrame.dot:SetColorTexture(0.45, 0.45, 0.95, 0.5)
    end

    -- Start cursor following
    if not dragUpdateFrame then
        dragUpdateFrame = CreateFrame("Frame")
    end
    dragUpdateFrame:SetScript("OnUpdate", function()
        if not dragState.isDragging then
            dragUpdateFrame:Hide()
            return
        end

        local x, y = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        local cursorX, cursorY = x / scale, y / scale

        ghost:ClearAllPoints()
        ghost:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cursorX + 10, cursorY - 10)

        if not IsMouseButtonDown("LeftButton") then
            EndDrag()
        end
    end)
    dragUpdateFrame:Show()
end

EndDrag = function()
    if not dragState.isDragging then return end

    local auraName = dragState.auraName
    local dropAnchor = dragState.dropAnchor
    local moveID = dragState.moveIndicatorID
    local indicatorType = dragState.indicatorType or "icon"

    -- Clear state
    dragState.isDragging = false
    dragState.auraName = nil
    dragState.auraInfo = nil
    dragState.specKey = nil
    dragState.dropAnchor = nil
    dragState.moveIndicatorID = nil
    dragState.indicatorType = nil

    -- Hide ghost
    if dragGhost then dragGhost:Hide() end

    -- Stop cursor following
    if dragUpdateFrame then
        dragUpdateFrame:Hide()
        dragUpdateFrame:SetScript("OnUpdate", nil)
    end

    -- Clear drag hint
    if dragHintText then
        dragHintText:SetText("")
    end

    -- Hide anchor dots (only visible during drag)
    for _, dotFrame in pairs(anchorDots) do
        dotFrame:Hide()
        dotFrame.dot:SetSize(6, 6)
        dotFrame.dot:SetColorTexture(0.45, 0.45, 0.95, 0.3)
    end

    -- Process the drop
    if auraName and dropAnchor then
        if moveID then
            -- Move existing indicator to the new anchor
            local inst = GetIndicatorByID(auraName, moveID)
            if inst then
                inst.anchor = dropAnchor
                inst.offsetX = 0
                inst.offsetY = 0
            end
        else
            -- Create a new indicator instance at the dropped anchor
            local inst = CreateIndicatorInstance(auraName, indicatorType)
            if inst then
                inst.anchor = dropAnchor
            end
        end

        -- Expand the new indicator card in the Effects tab
        local auraCfg = GetSpecAuras()[auraName]
        local lastInst = auraCfg and auraCfg.indicators and auraCfg.indicators[#auraCfg.indicators]
        if lastInst then
            local cardKey = "placed:" .. auraName .. "#" .. lastInst.id
            expandedCards[cardKey] = true
        end
    end

    -- Refresh everything
    DF:AuraDesigner_RefreshPage()
end

-- ============================================================
-- PLACED INDICATORS ON PREVIEW
-- Small icons/squares/bars rendered at anchor positions
-- ============================================================

local placedIndicators = {}

local function ClearPlacedIndicators()
    for _, ind in ipairs(placedIndicators) do
        ind:Hide()
    end
    wipe(placedIndicators)

    -- Clean up AD indicator maps on the mockFrame
    if framePreview and framePreview.mockFrame then
        local mock = framePreview.mockFrame
        if mock.dfAD_icons then
            for _, icon in pairs(mock.dfAD_icons) do icon:Hide() end
            wipe(mock.dfAD_icons)
        end
        if mock.dfAD_squares then
            for _, sq in pairs(mock.dfAD_squares) do sq:Hide() end
            wipe(mock.dfAD_squares)
        end
        if mock.dfAD_bars then
            for _, bar in pairs(mock.dfAD_bars) do bar:Hide() end
            wipe(mock.dfAD_bars)
        end
        mock.dfAD = nil
    end
end

local function RefreshPlacedIndicators()
    ClearPlacedIndicators()
    if not framePreview then return end

    local mockFrame = framePreview.mockFrame
    if not mockFrame then return end

    local adDB = GetAuraDesignerDB()
    local spec = ResolveSpec()
    if not spec then return end

    local auraList = Adapter and Adapter:GetTrackableAuras(spec)
    if not auraList then return end

    -- Build lookup
    local infoLookup = {}
    for _, info in ipairs(auraList) do
        infoLookup[info.name] = info
    end

    local Indicators = DF.AuraDesigner and DF.AuraDesigner.Indicators
    if not Indicators then return end

    -- Build layout group position lookup for preview
    -- In preview all indicators are visible, so compute positions for all members
    local groupPositions = {}  -- "auraName#indicatorID" → { anchor, offsetX, offsetY }
    if adDB.layoutGroups then
        for _, group in ipairs(adDB.layoutGroups) do
            if group.members then
                for memberIdx, member in ipairs(group.members) do
                    local key = member.auraName .. "#" .. member.indicatorID
                    -- Compute position based on group settings
                    local activeIdx = memberIdx - 1  -- 0-based
                    -- Need to find the indicator's size to compute step
                    local memberCfg = GetSpecAuras()[member.auraName]
                    local indCfg = nil
                    if memberCfg and memberCfg.indicators then
                        for _, ind in ipairs(memberCfg.indicators) do
                            if ind.id == member.indicatorID then
                                indCfg = ind
                                break
                            end
                        end
                    end
                    local size = (indCfg and indCfg.size) or (adDB.defaults and adDB.defaults.iconSize) or 24
                    local scale = (indCfg and indCfg.scale) or (adDB.defaults and adDB.defaults.iconScale) or 1.0
                    local step = (size * scale) + (group.spacing or 2)

                    local oX, oY = group.offsetX or 0, group.offsetY or 0
                    local dir = group.growDirection or "RIGHT"
                    if dir == "RIGHT" then
                        oX = oX + (activeIdx * step)
                    elseif dir == "LEFT" then
                        oX = oX - (activeIdx * step)
                    elseif dir == "DOWN" then
                        oY = oY - (activeIdx * step)
                    elseif dir == "UP" then
                        oY = oY + (activeIdx * step)
                    end
                    groupPositions[key] = {
                        anchor = group.anchor or "TOPLEFT",
                        offsetX = oX,
                        offsetY = oY,
                    }
                end
            end
        end
    end

    -- Iterate all configured auras, find placed indicator instances
    for auraName, auraCfg in pairs(GetSpecAuras(spec)) do
        local info = infoLookup[auraName]
        if info and auraCfg.indicators then
            for _, indicator in ipairs(auraCfg.indicators) do
                local instanceKey = auraName .. "#" .. indicator.id
                local capturedAura = auraName
                local capturedID = indicator.id

                -- Apply layout group position override if applicable
                local effectiveConfig = indicator
                local gPos = groupPositions[instanceKey]
                if gPos then
                    effectiveConfig = setmetatable({
                        anchor = gPos.anchor,
                        offsetX = gPos.offsetX,
                        offsetY = gPos.offsetY,
                    }, { __index = indicator })
                end

                if indicator.type == "icon" then
                    local tex = GetAuraIcon(spec, auraName)
                    local mockAuraData = {
                        spellId = info.spellIds and info.spellIds[1] or 0,
                        icon = tex,
                        duration = 15,
                        expirationTime = GetTime() + 10,
                        stacks = 3,
                    }
                    Indicators:ApplyIcon(mockFrame, effectiveConfig, mockAuraData, adDB.defaults, instanceKey)

                    local iconMap = mockFrame.dfAD_icons
                    local icon = iconMap and iconMap[instanceKey]
                    if icon then
                        icon:SetFrameLevel(mockFrame:GetFrameLevel() + 8)
                        icon:EnableMouse(true)
                        if icon.SetMouseClickEnabled then
                            icon:SetMouseClickEnabled(true)
                        end
                        icon:SetScript("OnMouseUp", function(_, button)
                            if dragState.isDragging then return end
                            if button == "RightButton" then
                                -- Don't delete grouped indicators (managed by layout group)
                                if not GetIndicatorLayoutGroup(capturedAura, capturedID) then
                                    RemoveIndicatorInstance(capturedAura, capturedID)
                                    DF:AuraDesigner_RefreshPage()
                                end
                            elseif button == "LeftButton" then
                                -- Collapse all cards and expand only the clicked one
                                local cardKey = "placed:" .. capturedAura .. "#" .. capturedID
                                wipe(expandedCards)
                                expandedCards[cardKey] = true
                                activeTab = "effects"
                                DF:AuraDesigner_RefreshPage()
                            end
                        end)
                        icon:RegisterForDrag("LeftButton")
                        icon:SetScript("OnDragStart", function()
                            StartMoveDrag(capturedAura, capturedID, spec)
                        end)
                        tinsert(placedIndicators, icon)
                    end

                elseif indicator.type == "square" then
                    local mockAuraData = {
                        spellId = info.spellIds and info.spellIds[1] or 0,
                        icon = GetAuraIcon(spec, auraName),
                        duration = 15,
                        expirationTime = GetTime() + 10,
                        stacks = 3,
                    }
                    Indicators:ApplySquare(mockFrame, effectiveConfig, mockAuraData, adDB.defaults, instanceKey)

                    local sqMap = mockFrame.dfAD_squares
                    local sq = sqMap and sqMap[instanceKey]
                    if sq then
                        sq:SetFrameLevel(mockFrame:GetFrameLevel() + 8)
                        sq:EnableMouse(true)
                        sq:SetScript("OnMouseUp", function(_, button)
                            if dragState.isDragging then return end
                            if button == "RightButton" then
                                if not GetIndicatorLayoutGroup(capturedAura, capturedID) then
                                    RemoveIndicatorInstance(capturedAura, capturedID)
                                    DF:AuraDesigner_RefreshPage()
                                end
                            elseif button == "LeftButton" then
                                -- Collapse all cards and expand only the clicked one
                                local cardKey = "placed:" .. capturedAura .. "#" .. capturedID
                                wipe(expandedCards)
                                expandedCards[cardKey] = true
                                activeTab = "effects"
                                DF:AuraDesigner_RefreshPage()
                            end
                        end)
                        sq:RegisterForDrag("LeftButton")
                        sq:SetScript("OnDragStart", function()
                            StartMoveDrag(capturedAura, capturedID, spec)
                        end)
                        tinsert(placedIndicators, sq)
                    end

                elseif indicator.type == "bar" then
                    local mockAuraData = {
                        spellId = info.spellIds and info.spellIds[1] or 0,
                        icon = GetAuraIcon(spec, auraName),
                        duration = 15,
                        expirationTime = GetTime() + 10,
                        stacks = 0,
                    }
                    Indicators:ApplyBar(mockFrame, effectiveConfig, mockAuraData, adDB.defaults, instanceKey)

                    local barMap = mockFrame.dfAD_bars
                    local bar = barMap and barMap[instanceKey]
                    if bar then
                        bar:SetFrameLevel(mockFrame:GetFrameLevel() + 7)
                        bar:EnableMouse(true)
                        bar:SetScript("OnMouseUp", function(_, button)
                            if dragState.isDragging then return end
                            if button == "RightButton" then
                                if not GetIndicatorLayoutGroup(capturedAura, capturedID) then
                                    RemoveIndicatorInstance(capturedAura, capturedID)
                                    DF:AuraDesigner_RefreshPage()
                                end
                            elseif button == "LeftButton" then
                                -- Collapse all cards and expand only the clicked one
                                local cardKey = "placed:" .. capturedAura .. "#" .. capturedID
                                wipe(expandedCards)
                                expandedCards[cardKey] = true
                                activeTab = "effects"
                                DF:AuraDesigner_RefreshPage()
                            end
                        end)
                        bar:RegisterForDrag("LeftButton")
                        bar:SetScript("OnDragStart", function()
                            StartMoveDrag(capturedAura, capturedID, spec)
                        end)
                        tinsert(placedIndicators, bar)
                    end
                end
            end
        end
    end
end

-- ============================================================
-- PREVIEW EFFECTS
-- Apply frame-level effects (border, healthbar, text, alpha)
-- for the currently selected aura on the mock frame
-- ============================================================

local function RefreshPreviewEffects()
    if not framePreview then return end
    local mockFrame = framePreview.mockFrame
    if not mockFrame then return end

    -- Reset to defaults
    if framePreview.borderOverlay and DF.ApplyHighlightStyle then
        DF.ApplyHighlightStyle(framePreview.borderOverlay, "NONE", 2, 0, 1, 1, 1, 1)
    end
    if framePreview.healthFill then
        framePreview.healthFill:SetVertexColor(0.18, 0.80, 0.44, 0.85)
    end
    if framePreview.nameText then
        framePreview.nameText:SetTextColor(0.18, 0.80, 0.44, 1)
    end
    if framePreview.hpText then
        framePreview.hpText:SetTextColor(0.87, 0.87, 0.87, 1)
    end
    mockFrame:SetAlpha(1)

    -- Show frame-level effects from all configured auras
    -- (new UI has no single selectedAura — preview shows all effects)

    for _, auraCfg in pairs(GetSpecAuras()) do

    -- Border effect (uses highlight system for all 6 styles)
    if auraCfg.border and framePreview.borderOverlay and DF.ApplyHighlightStyle then
        local clr = auraCfg.border.color or {r = 1, g = 1, b = 1, a = 1}
        local thickness = auraCfg.border.thickness or 2
        local inset = auraCfg.border.inset or 0
        -- Migrate old style names (Solid→SOLID, Glow→GLOW, Pulse→SOLID)
        local style = auraCfg.border.style or "SOLID"
        if style == "Solid" then style = "SOLID"
        elseif style == "Glow" then style = "GLOW"
        elseif style == "Pulse" then style = "SOLID" end
        DF.ApplyHighlightStyle(framePreview.borderOverlay, style, thickness, inset,
            clr.r or 1, clr.g or 1, clr.b or 1, clr.a or 1)
    end

    -- Health bar color
    if auraCfg.healthbar and framePreview.healthFill then
        local clr = auraCfg.healthbar.color or {r = 1, g = 1, b = 1, a = 1}
        local blend = auraCfg.healthbar.blend or 0.5
        if auraCfg.healthbar.mode == "Replace" then
            framePreview.healthFill:SetVertexColor(clr.r, clr.g, clr.b, clr.a or 1)
        else
            -- Tint: blend original green with the configured color
            local r = 0.18 * (1 - blend) + clr.r * blend
            local g = 0.80 * (1 - blend) + clr.g * blend
            local b = 0.44 * (1 - blend) + clr.b * blend
            framePreview.healthFill:SetVertexColor(r, g, b, 0.85)
        end
    end

    -- Name text color
    if auraCfg.nametext and framePreview.nameText then
        local clr = auraCfg.nametext.color or {r = 1, g = 1, b = 1, a = 1}
        framePreview.nameText:SetTextColor(clr.r, clr.g, clr.b, clr.a or 1)
    end

    -- Health text color
    if auraCfg.healthtext and framePreview.hpText then
        local clr = auraCfg.healthtext.color or {r = 1, g = 1, b = 1, a = 1}
        framePreview.hpText:SetTextColor(clr.r, clr.g, clr.b, clr.a or 1)
    end

    -- Frame alpha
    if auraCfg.framealpha then
        mockFrame:SetAlpha(auraCfg.framealpha.alpha or 0.5)
    end

    end  -- for _, auraCfg
end

-- ============================================================
-- LIGHTWEIGHT PREVIEW REFRESH
-- Re-applies indicator settings to existing preview frames without
-- destroying/recreating them. Called from proxy __newindex so every
-- slider drag tick, checkbox toggle, or dropdown change is live.
-- ============================================================

RefreshPreviewLightweight = function()
    if not framePreview or not framePreview.mockFrame then return end
    local mockFrame = framePreview.mockFrame
    local Indicators = DF.AuraDesigner and DF.AuraDesigner.Indicators
    if not Indicators then return end

    local adDB = GetAuraDesignerDB()
    local spec = ResolveSpec()
    if not spec then return end

    -- Build layout group position lookup (same as RefreshPlacedIndicators)
    local groupPositions = {}
    if adDB.layoutGroups then
        for _, group in ipairs(adDB.layoutGroups) do
            if group.members then
                for memberIdx, member in ipairs(group.members) do
                    local key = member.auraName .. "#" .. member.indicatorID
                    local activeIdx = memberIdx - 1
                    local memberCfg = GetSpecAuras()[member.auraName]
                    local indCfg = nil
                    if memberCfg and memberCfg.indicators then
                        for _, ind in ipairs(memberCfg.indicators) do
                            if ind.id == member.indicatorID then indCfg = ind; break end
                        end
                    end
                    local size = (indCfg and indCfg.size) or (adDB.defaults and adDB.defaults.iconSize) or 24
                    local scale = (indCfg and indCfg.scale) or (adDB.defaults and adDB.defaults.iconScale) or 1.0
                    local step = (size * scale) + (group.spacing or 2)
                    local oX, oY = group.offsetX or 0, group.offsetY or 0
                    local dir = group.growDirection or "RIGHT"
                    if dir == "RIGHT" then oX = oX + (activeIdx * step)
                    elseif dir == "LEFT" then oX = oX - (activeIdx * step)
                    elseif dir == "DOWN" then oY = oY - (activeIdx * step)
                    elseif dir == "UP" then oY = oY + (activeIdx * step) end
                    groupPositions[key] = { anchor = group.anchor or "TOPLEFT", offsetX = oX, offsetY = oY }
                end
            end
        end
    end

    -- Re-apply placed indicator instances using current settings
    for auraName, auraCfg in pairs(GetSpecAuras()) do
        if auraCfg.indicators then
            for _, indicator in ipairs(auraCfg.indicators) do
                local instanceKey = auraName .. "#" .. indicator.id

                -- Apply layout group position override if applicable
                local effectiveConfig = indicator
                local gPos = groupPositions[instanceKey]
                if gPos then
                    effectiveConfig = setmetatable({
                        anchor = gPos.anchor, offsetX = gPos.offsetX, offsetY = gPos.offsetY,
                    }, { __index = indicator })
                end

                if indicator.type == "icon" then
                    local iconMap = mockFrame.dfAD_icons
                    local icon = iconMap and iconMap[instanceKey]
                    if icon then
                        local tex = GetAuraIcon(spec, auraName)
                        local mockAuraData = {
                            spellId = 0, icon = tex,
                            duration = 15, expirationTime = GetTime() + 10,
                            stacks = 3,
                        }
                        Indicators:ApplyIcon(mockFrame, effectiveConfig, mockAuraData, adDB.defaults, instanceKey)
                        -- Re-enable mouse (ApplyIcon disables it for real unit frames)
                        icon:EnableMouse(true)
                        if icon.SetMouseClickEnabled then icon:SetMouseClickEnabled(true) end
                    end
                elseif indicator.type == "square" then
                    local sqMap = mockFrame.dfAD_squares
                    local sq = sqMap and sqMap[instanceKey]
                    if sq then
                        local mockAuraData = {
                            spellId = 0, icon = nil,
                            duration = 15, expirationTime = GetTime() + 10,
                            stacks = 3,
                        }
                        Indicators:ApplySquare(mockFrame, effectiveConfig, mockAuraData, adDB.defaults, instanceKey)
                        sq:EnableMouse(true)
                    end
                elseif indicator.type == "bar" then
                    local barMap = mockFrame.dfAD_bars
                    local bar = barMap and barMap[instanceKey]
                    if bar then
                        local mockAuraData = {
                            spellId = 0, icon = nil,
                            duration = 15, expirationTime = GetTime() + 10,
                            stacks = 0,
                        }
                        Indicators:ApplyBar(mockFrame, effectiveConfig, mockAuraData, adDB.defaults, instanceKey)
                        -- Re-enable mouse (ApplyBar disables it for real unit frames)
                        bar:EnableMouse(true)
                        if bar.SetMouseClickEnabled then bar:SetMouseClickEnabled(true) end
                    end
                end
            end
        end
    end

    -- Also refresh frame-level preview effects (border, healthbar color, text colors, alpha)
    RefreshPreviewEffects()
end

-- ============================================================
-- INDICATOR TYPE WIDGET BUILDER
-- (Tile strip removed in v4 redesign)
-- ============================================================

-- Build the widget content for a given indicator type
-- optProxy: optional proxy table; if nil, creates one via CreateProxy (frame-level types)
-- yOffset: optional vertical offset to start content below other elements (e.g. trigger tags)
-- layoutGroup: optional layout group table; if set, anchor/offset controls are replaced with a note
-- indicatorID: optional indicator ID for placed indicators (used by Copy From)
local function BuildTypeContent(parent, typeKey, auraName, width, optProxy, yOffset, layoutGroup, indicatorID)
    local proxy = optProxy or CreateProxy(auraName, typeKey)
    local contentWidth = width or 248
    local widgets = {}
    local totalHeight = 10 + (yOffset or 0)  -- top padding + optional offset

    local function AddWidget(widget, height)
        widget:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -totalHeight)
        if widget.SetWidth then widget:SetWidth(contentWidth - 10) end
        tinsert(widgets, widget)
        totalHeight = totalHeight + (height or 30)
    end

    local function AddDivider()
        totalHeight = totalHeight + 6
        local div = parent:CreateTexture(nil, "ARTWORK")
        div:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -totalHeight)
        div:SetSize(contentWidth - 20, 1)
        div:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.4)
        totalHeight = totalHeight + 8
    end

    -- ── COPY FROM (placed indicators only: icon, square, bar) ──
    if indicatorID and (typeKey == "icon" or typeKey == "square" or typeKey == "bar") then
        local copyContainer = CreateFrame("Frame", nil, parent)
        copyContainer:SetHeight(36)

        local copyLabel = copyContainer:CreateFontString(nil, "OVERLAY")
        copyLabel:SetFont("Fonts\\FRIZQT__.TTF", 8, "")
        copyLabel:SetPoint("TOPLEFT", 1, -1)
        copyLabel:SetText("COPY APPEARANCE FROM")
        copyLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

        local copyBtn = CreateFrame("Button", nil, copyContainer, "BackdropTemplate")
        copyBtn:SetHeight(20)
        copyBtn:SetPoint("TOPLEFT", 0, -12)
        copyBtn:SetPoint("RIGHT", copyContainer, "RIGHT", 0, 0)
        ApplyBackdrop(copyBtn,
            {r = 0.12, g = 0.12, b = 0.12, a = 1},
            {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.6})

        local copyBtnText = copyBtn:CreateFontString(nil, "OVERLAY")
        copyBtnText:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
        copyBtnText:SetPoint("LEFT", 6, 0)
        copyBtnText:SetText("Select indicator...")
        copyBtnText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

        local chevron = copyBtn:CreateTexture(nil, "OVERLAY")
        chevron:SetSize(10, 10)
        chevron:SetPoint("RIGHT", -6, 0)
        chevron:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
        chevron:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

        copyBtn:SetScript("OnEnter", function(self)
            self:SetBackdropColor(0.18, 0.18, 0.18, 1)
            copyBtnText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        end)
        copyBtn:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0.12, 0.12, 0.12, 1)
            copyBtnText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end)

        local capturedAuraName = auraName
        local capturedIndicatorID = indicatorID
        local capturedTypeKey = typeKey

        copyBtn:SetScript("OnClick", function()
            -- Build list of other placed indicators of the same type
            local spec = ResolveSpec()
            local trackable = spec and Adapter and Adapter:GetTrackableAuras(spec)
            local displayNames = {}
            if trackable then
                for _, info in ipairs(trackable) do
                    displayNames[info.name] = info.display
                end
            end

            local sources = {}
            for srcAura, auraCfg in pairs(GetSpecAuras()) do
                if auraCfg.indicators then
                    for _, ind in ipairs(auraCfg.indicators) do
                        if ind.type == capturedTypeKey then
                            -- Skip self
                            if not (srcAura == capturedAuraName and ind.id == capturedIndicatorID) then
                                tinsert(sources, {
                                    auraName = srcAura,
                                    displayName = displayNames[srcAura] or srcAura,
                                    indicatorID = ind.id,
                                })
                            end
                        end
                    end
                end
            end

            if #sources == 0 then return end
            sort(sources, function(a, b) return a.displayName < b.displayName end)

            -- Create or reuse picker dropdown
            local dropName = "DFADCopyFromPicker"
            local drop = _G[dropName]
            if not drop then
                drop = CreateFrame("Frame", dropName, UIParent, "BackdropTemplate")
                drop:SetFrameStrata("FULLSCREEN_DIALOG")
                drop:SetClampedToScreen(true)
            end
            if drop:IsShown() and drop._ownerBtn == copyBtn then
                drop:Hide()
                return
            end
            drop._ownerBtn = copyBtn

            -- Clear previous children
            for _, child in ipairs({drop:GetChildren()}) do child:Hide(); child:SetParent(nil) end
            for _, rgn in ipairs({drop:GetRegions()}) do
                if rgn:GetObjectType() == "FontString" then rgn:Hide() end
            end

            drop:SetWidth(200)
            ApplyBackdrop(drop, C_BACKGROUND, C_BORDER)

            local dy = -4
            for _, src in ipairs(sources) do
                local btn = CreateFrame("Button", nil, drop)
                btn:SetHeight(20)
                btn:SetPoint("TOPLEFT", 4, dy)
                btn:SetPoint("RIGHT", drop, "RIGHT", -4, 0)

                local lbl = btn:CreateFontString(nil, "OVERLAY")
                lbl:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
                lbl:SetPoint("LEFT", 6, 0)
                lbl:SetText(src.displayName)
                lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

                local hl = btn:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(1, 1, 1, 0.05)

                local capturedSrc = src
                btn:SetScript("OnClick", function()
                    CopyIndicatorAppearance(capturedSrc.auraName, capturedSrc.indicatorID, capturedAuraName, capturedIndicatorID)
                    drop:Hide()
                    DF:AuraDesigner_RefreshPage()
                end)

                dy = dy - 20
            end
            drop:SetHeight(-dy + 4)

            drop:ClearAllPoints()
            drop:SetPoint("TOPLEFT", copyBtn, "BOTTOMLEFT", 0, -2)
            drop:Show()

            drop:SetScript("OnHide", function() drop._ownerBtn = nil end)
        end)

        AddWidget(copyContainer, 38)
        AddDivider()
    end

    if typeKey == "icon" then
        -- Placement (or managed-by-group note)
        if layoutGroup then
            local groupNote = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            groupNote:SetTextColor(0.91, 0.66, 0.25, 0.8)
            groupNote:SetText("Position managed by: " .. (layoutGroup.name or "Layout Group"))
            AddWidget(groupNote, 18)
        else
            AddWidget(GUI:CreateDropdown(parent, "Anchor", ANCHOR_OPTIONS, proxy, "anchor", function() DF:AuraDesigner_RefreshPage() end), 54)
            AddWidget(GUI:CreateSlider(parent, "Offset X", -50, 50, 1, proxy, "offsetX"), 54)
            AddWidget(GUI:CreateSlider(parent, "Offset Y", -50, 50, 1, proxy, "offsetY"), 54)
        end
        AddDivider()
        -- Sizing & appearance
        AddWidget(GUI:CreateSlider(parent, "Size", 8, 64, 1, proxy, "size"), 54)
        AddWidget(GUI:CreateSlider(parent, "Scale", 0.5, 3.0, 0.05, proxy, "scale"), 54)
        AddWidget(GUI:CreateSlider(parent, "Alpha", 0, 1, 0.05, proxy, "alpha"), 54)
        AddDivider()
        -- Border
        AddWidget(GUI:CreateCheckbox(parent, "Show Border", proxy, "borderEnabled"), 28)
        AddWidget(GUI:CreateSlider(parent, "Border Thickness", 1, 5, 1, proxy, "borderThickness"), 54)
        AddWidget(GUI:CreateSlider(parent, "Border Inset", -3, 5, 1, proxy, "borderInset"), 54)
        AddWidget(GUI:CreateCheckbox(parent, "Hide Cooldown Swipe", proxy, "hideSwipe"), 28)
        AddDivider()
        -- Duration text
        AddWidget(GUI:CreateCheckbox(parent, "Show Duration Text", proxy, "showDuration"), 28)
        AddWidget(GUI:CreateFontDropdown(parent, "Duration Font", proxy, "durationFont"), 54)
        AddWidget(GUI:CreateSlider(parent, "Duration Scale", 0.5, 2.0, 0.1, proxy, "durationScale"), 54)
        AddWidget(GUI:CreateDropdown(parent, "Duration Outline", OUTLINE_OPTIONS, proxy, "durationOutline"), 54)
        AddWidget(GUI:CreateDropdown(parent, "Duration Anchor", ANCHOR_OPTIONS, proxy, "durationAnchor"), 54)
        AddWidget(GUI:CreateSlider(parent, "Duration Offset X", -20, 20, 1, proxy, "durationX"), 54)
        AddWidget(GUI:CreateSlider(parent, "Duration Offset Y", -20, 20, 1, proxy, "durationY"), 54)
        AddWidget(GUI:CreateCheckbox(parent, "Color Duration by Time", proxy, "durationColorByTime"), 28)
        AddDivider()
        -- Stack count
        AddWidget(GUI:CreateCheckbox(parent, "Show Stacks", proxy, "showStacks"), 28)
        AddWidget(GUI:CreateSlider(parent, "Stack Minimum", 1, 10, 1, proxy, "stackMinimum"), 54)
        AddWidget(GUI:CreateFontDropdown(parent, "Stack Font", proxy, "stackFont"), 54)
        AddWidget(GUI:CreateSlider(parent, "Stack Scale", 0.5, 2.0, 0.1, proxy, "stackScale"), 54)
        AddWidget(GUI:CreateDropdown(parent, "Stack Outline", OUTLINE_OPTIONS, proxy, "stackOutline"), 54)
        AddWidget(GUI:CreateDropdown(parent, "Stack Anchor", ANCHOR_OPTIONS, proxy, "stackAnchor"), 54)
        AddWidget(GUI:CreateSlider(parent, "Stack Offset X", -20, 20, 1, proxy, "stackX"), 54)
        AddWidget(GUI:CreateSlider(parent, "Stack Offset Y", -20, 20, 1, proxy, "stackY"), 54)
        AddDivider()
        -- Expiring (changes icon border color when aura is about to expire)
        AddWidget(GUI:CreateCheckbox(parent, "Expiring Color Override", proxy, "expiringEnabled"), 28)
        AddWidget(GUI:CreateSlider(parent, "Expiring Threshold %", 5, 100, 5, proxy, "expiringThreshold"), 54)
        AddWidget(GUI:CreateColorPicker(parent, "Expiring Color", proxy, "expiringColor", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)

    elseif typeKey == "square" then
        -- Placement (or managed-by-group note)
        if layoutGroup then
            local groupNote = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            groupNote:SetTextColor(0.91, 0.66, 0.25, 0.8)
            groupNote:SetText("Position managed by: " .. (layoutGroup.name or "Layout Group"))
            AddWidget(groupNote, 18)
        else
            AddWidget(GUI:CreateDropdown(parent, "Anchor", ANCHOR_OPTIONS, proxy, "anchor", function() DF:AuraDesigner_RefreshPage() end), 54)
            AddWidget(GUI:CreateSlider(parent, "Offset X", -50, 50, 1, proxy, "offsetX"), 54)
            AddWidget(GUI:CreateSlider(parent, "Offset Y", -50, 50, 1, proxy, "offsetY"), 54)
        end
        AddDivider()
        -- Sizing & appearance
        AddWidget(GUI:CreateSlider(parent, "Size", 4, 64, 1, proxy, "size"), 54)
        AddWidget(GUI:CreateSlider(parent, "Scale", 0.5, 3.0, 0.05, proxy, "scale"), 54)
        AddWidget(GUI:CreateColorPicker(parent, "Color", proxy, "color", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)
        AddWidget(GUI:CreateSlider(parent, "Alpha", 0, 1, 0.05, proxy, "alpha"), 54)
        AddDivider()
        -- Border
        AddWidget(GUI:CreateCheckbox(parent, "Show Border", proxy, "showBorder"), 28)
        AddWidget(GUI:CreateSlider(parent, "Border Thickness", 1, 5, 1, proxy, "borderThickness"), 54)
        AddWidget(GUI:CreateSlider(parent, "Border Inset", -3, 5, 1, proxy, "borderInset"), 54)
        AddWidget(GUI:CreateCheckbox(parent, "Hide Cooldown Swipe", proxy, "hideSwipe"), 28)
        AddDivider()
        -- Duration text
        AddWidget(GUI:CreateCheckbox(parent, "Show Duration Text", proxy, "showDuration"), 28)
        AddWidget(GUI:CreateFontDropdown(parent, "Duration Font", proxy, "durationFont"), 54)
        AddWidget(GUI:CreateSlider(parent, "Duration Scale", 0.5, 2.0, 0.1, proxy, "durationScale"), 54)
        AddWidget(GUI:CreateDropdown(parent, "Duration Outline", OUTLINE_OPTIONS, proxy, "durationOutline"), 54)
        AddWidget(GUI:CreateDropdown(parent, "Duration Anchor", ANCHOR_OPTIONS, proxy, "durationAnchor"), 54)
        AddWidget(GUI:CreateSlider(parent, "Duration Offset X", -20, 20, 1, proxy, "durationX"), 54)
        AddWidget(GUI:CreateSlider(parent, "Duration Offset Y", -20, 20, 1, proxy, "durationY"), 54)
        AddWidget(GUI:CreateCheckbox(parent, "Color Duration by Time", proxy, "durationColorByTime"), 28)
        AddDivider()
        -- Stack count
        AddWidget(GUI:CreateCheckbox(parent, "Show Stacks", proxy, "showStacks"), 28)
        AddWidget(GUI:CreateSlider(parent, "Stack Minimum", 1, 10, 1, proxy, "stackMinimum"), 54)
        AddWidget(GUI:CreateFontDropdown(parent, "Stack Font", proxy, "stackFont"), 54)
        AddWidget(GUI:CreateSlider(parent, "Stack Scale", 0.5, 2.0, 0.1, proxy, "stackScale"), 54)
        AddWidget(GUI:CreateDropdown(parent, "Stack Outline", OUTLINE_OPTIONS, proxy, "stackOutline"), 54)
        AddWidget(GUI:CreateDropdown(parent, "Stack Anchor", ANCHOR_OPTIONS, proxy, "stackAnchor"), 54)
        AddWidget(GUI:CreateSlider(parent, "Stack Offset X", -20, 20, 1, proxy, "stackX"), 54)
        AddWidget(GUI:CreateSlider(parent, "Stack Offset Y", -20, 20, 1, proxy, "stackY"), 54)
        AddDivider()
        -- Expiring
        AddWidget(GUI:CreateCheckbox(parent, "Expiring Color Override", proxy, "expiringEnabled"), 28)
        AddWidget(GUI:CreateSlider(parent, "Expiring Threshold %", 5, 100, 5, proxy, "expiringThreshold"), 54)
        AddWidget(GUI:CreateColorPicker(parent, "Expiring Color", proxy, "expiringColor", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)

    elseif typeKey == "bar" then
        -- Placement (or managed-by-group note)
        if layoutGroup then
            local groupNote = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            groupNote:SetTextColor(0.91, 0.66, 0.25, 0.8)
            groupNote:SetText("Position managed by: " .. (layoutGroup.name or "Layout Group"))
            AddWidget(groupNote, 18)
        else
            AddWidget(GUI:CreateDropdown(parent, "Anchor", ANCHOR_OPTIONS, proxy, "anchor", function() DF:AuraDesigner_RefreshPage() end), 54)
            AddWidget(GUI:CreateSlider(parent, "Offset X", -50, 50, 1, proxy, "offsetX"), 54)
            AddWidget(GUI:CreateSlider(parent, "Offset Y", -50, 50, 1, proxy, "offsetY"), 54)
        end
        AddDivider()
        -- Size & orientation
        AddWidget(GUI:CreateDropdown(parent, "Orientation", BAR_ORIENT_OPTIONS, proxy, "orientation", function()
            -- Swap width/height and matchFrame settings when orientation changes
            local w = proxy.width
            local h = proxy.height
            proxy.width = h
            proxy.height = w
            local mw = proxy.matchFrameWidth
            local mh = proxy.matchFrameHeight
            proxy.matchFrameWidth = mh
            proxy.matchFrameHeight = mw
            DF:AuraDesigner_RefreshPage()
        end), 54)
        AddWidget(GUI:CreateSlider(parent, "Width", 0, 200, 1, proxy, "width"), 54)
        AddWidget(GUI:CreateSlider(parent, "Height", 1, 30, 1, proxy, "height"), 54)
        AddWidget(GUI:CreateCheckbox(parent, "Match Frame Width", proxy, "matchFrameWidth"), 28)
        AddWidget(GUI:CreateCheckbox(parent, "Match Frame Height", proxy, "matchFrameHeight"), 28)
        AddDivider()
        -- Texture
        AddWidget(GUI:CreateTextureDropdown(parent, "Bar Texture", proxy, "texture"), 54)
        AddDivider()
        -- Colors
        AddWidget(GUI:CreateColorPicker(parent, "Fill Color", proxy, "fillColor", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)
        AddWidget(GUI:CreateColorPicker(parent, "Background Color", proxy, "bgColor", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)
        AddWidget(GUI:CreateSlider(parent, "Alpha", 0, 1, 0.05, proxy, "alpha"), 54)
        AddDivider()
        -- Border
        AddWidget(GUI:CreateCheckbox(parent, "Show Border", proxy, "showBorder"), 28)
        AddWidget(GUI:CreateSlider(parent, "Border Thickness", 1, 4, 1, proxy, "borderThickness"), 54)
        AddWidget(GUI:CreateColorPicker(parent, "Border Color", proxy, "borderColor", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)
        AddDivider()
        -- Bar color by time
        AddWidget(GUI:CreateCheckbox(parent, "Color Bar by Duration", proxy, "barColorByTime"), 28)
        AddDivider()
        -- Expiring color
        AddWidget(GUI:CreateCheckbox(parent, "Expiring Color Override", proxy, "expiringEnabled"), 28)
        AddWidget(GUI:CreateSlider(parent, "Expiring Threshold %", 5, 100, 5, proxy, "expiringThreshold"), 54)
        AddWidget(GUI:CreateColorPicker(parent, "Expiring Color", proxy, "expiringColor", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)
        AddDivider()
        -- Duration text
        AddWidget(GUI:CreateCheckbox(parent, "Show Duration Text", proxy, "showDuration"), 28)
        AddWidget(GUI:CreateFontDropdown(parent, "Duration Font", proxy, "durationFont"), 54)
        AddWidget(GUI:CreateSlider(parent, "Duration Scale", 0.5, 2.0, 0.1, proxy, "durationScale"), 54)
        AddWidget(GUI:CreateDropdown(parent, "Duration Outline", OUTLINE_OPTIONS, proxy, "durationOutline"), 54)
        AddWidget(GUI:CreateDropdown(parent, "Duration Anchor", ANCHOR_OPTIONS, proxy, "durationAnchor"), 54)
        AddWidget(GUI:CreateSlider(parent, "Duration Offset X", -20, 20, 1, proxy, "durationX"), 54)
        AddWidget(GUI:CreateSlider(parent, "Duration Offset Y", -20, 20, 1, proxy, "durationY"), 54)
        AddWidget(GUI:CreateCheckbox(parent, "Color Duration by Time", proxy, "durationColorByTime"), 28)

    elseif typeKey == "border" then
        AddWidget(GUI:CreateDropdown(parent, "Style", BORDER_STYLE_OPTIONS, proxy, "style"), 54)
        AddWidget(GUI:CreateColorPicker(parent, "Color", proxy, "color", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)
        AddWidget(GUI:CreateSlider(parent, "Thickness", 1, 8, 1, proxy, "thickness"), 54)
        AddWidget(GUI:CreateSlider(parent, "Inset", 0, 8, 1, proxy, "inset"), 54)
        AddDivider()
        -- Expiring
        AddWidget(GUI:CreateCheckbox(parent, "Expiring Color Override", proxy, "expiringEnabled"), 28)
        AddWidget(GUI:CreateSlider(parent, "Expiring Threshold %", 5, 100, 5, proxy, "expiringThreshold"), 54)
        AddWidget(GUI:CreateColorPicker(parent, "Expiring Color", proxy, "expiringColor", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)

    elseif typeKey == "healthbar" then
        local blendSlider
        AddWidget(GUI:CreateDropdown(parent, "Mode", HEALTHBAR_MODE_OPTIONS, proxy, "mode", function()
            if blendSlider then
                local isReplace = (proxy.mode or "Replace") == "Replace"
                if isReplace then blendSlider:Hide() else blendSlider:Show() end
            end
        end), 54)
        AddWidget(GUI:CreateColorPicker(parent, "Color", proxy, "color", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)
        blendSlider = GUI:CreateSlider(parent, "Blend %", 0, 1, 0.05, proxy, "blend")
        AddWidget(blendSlider, 54)
        -- Hide blend slider when Replace mode is selected (overlay is forced to full opacity)
        if (proxy.mode or "Replace") == "Replace" then blendSlider:Hide() end
        AddDivider()
        -- Expiring
        AddWidget(GUI:CreateCheckbox(parent, "Expiring Color Override", proxy, "expiringEnabled"), 28)
        AddWidget(GUI:CreateSlider(parent, "Expiring Threshold %", 5, 100, 5, proxy, "expiringThreshold"), 54)
        AddWidget(GUI:CreateColorPicker(parent, "Expiring Color", proxy, "expiringColor", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)

    elseif typeKey == "nametext" then
        AddWidget(GUI:CreateColorPicker(parent, "Color", proxy, "color", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)
        AddDivider()
        -- Expiring
        AddWidget(GUI:CreateCheckbox(parent, "Expiring Color Override", proxy, "expiringEnabled"), 28)
        AddWidget(GUI:CreateSlider(parent, "Expiring Threshold %", 5, 100, 5, proxy, "expiringThreshold"), 54)
        AddWidget(GUI:CreateColorPicker(parent, "Expiring Color", proxy, "expiringColor", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)

    elseif typeKey == "healthtext" then
        AddWidget(GUI:CreateColorPicker(parent, "Color", proxy, "color", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)
        AddDivider()
        -- Expiring
        AddWidget(GUI:CreateCheckbox(parent, "Expiring Color Override", proxy, "expiringEnabled"), 28)
        AddWidget(GUI:CreateSlider(parent, "Expiring Threshold %", 5, 100, 5, proxy, "expiringThreshold"), 54)
        AddWidget(GUI:CreateColorPicker(parent, "Expiring Color", proxy, "expiringColor", true,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            function() if RefreshPreviewLightweight then RefreshPreviewLightweight() end end,
            true), 28)

    elseif typeKey == "framealpha" then
        AddWidget(GUI:CreateSlider(parent, "Alpha", 0, 1, 0.05, proxy, "alpha"), 54)
        AddDivider()
        -- Expiring
        AddWidget(GUI:CreateCheckbox(parent, "Expiring Alpha Override", proxy, "expiringEnabled"), 28)
        AddWidget(GUI:CreateSlider(parent, "Expiring Threshold %", 5, 100, 5, proxy, "expiringThreshold"), 54)
        AddWidget(GUI:CreateSlider(parent, "Expiring Alpha", 0, 1, 0.05, proxy, "expiringAlpha"), 54)
    end

    totalHeight = totalHeight + 8  -- bottom padding
    parent:SetHeight(totalHeight)
    return widgets, totalHeight
end

-- ============================================================
-- GLOBAL VIEW (used by Global tab)
-- ============================================================

-- Hardcoded fallbacks for global defaults (used when profile is missing new keys)
local GLOBAL_DEFAULTS_FALLBACK = {
    iconSize = 24, iconScale = 1.0,
    showDuration = true, showStacks = true,
    durationFont = "Fonts\\FRIZQT__.TTF", durationScale = 1.0,
    durationOutline = "OUTLINE", durationAnchor = "CENTER",
    durationX = 0, durationY = 0, durationColorByTime = false,
    stackFont = "Fonts\\FRIZQT__.TTF", stackScale = 1.0,
    stackOutline = "OUTLINE", stackAnchor = "BOTTOMRIGHT",
    stackX = 0, stackY = 0,
    iconBorderEnabled = true, iconBorderThickness = 1,
    stackMinimum = 2,
    hideSwipe = false,
}

local function BuildGlobalView(parent)
    local adDB = GetAuraDesignerDB()
    local rawDefaults = adDB.defaults
    -- Proxy so every write triggers a full preview rebuild
    -- (global defaults affect ALL indicators, need full teardown/rebuild)
    -- Falls back to GLOBAL_DEFAULTS_FALLBACK for keys missing from existing profiles
    local defaults = setmetatable({}, {
        __index = function(_, k)
            local v = rawDefaults[k]
            if v ~= nil then return v end
            return GLOBAL_DEFAULTS_FALLBACK[k]
        end,
        __newindex = function(_, k, v)
            rawDefaults[k] = v
            RefreshPlacedIndicators()
            RefreshPreviewEffects()
        end,
    })
    local yPos = -8
    local parentW = parent:GetWidth()
    if parentW < 50 then parentW = 280 end
    local contentWidth = parentW - 16  -- 8px padding each side
    local c = GetThemeColor()

    -- Title
    local title = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, yPos)
    title:SetText("Global Defaults")
    title:SetTextColor(c.r, c.g, c.b)
    yPos = yPos - 18

    local iconSize = GUI:CreateSlider(parent, "Default Icon Size", 8, 64, 1, defaults, "iconSize")
    iconSize:SetPoint("TOPLEFT", 5, yPos)
    iconSize:SetWidth(contentWidth - 10)
    yPos = yPos - 50

    local iconScale = GUI:CreateSlider(parent, "Default Scale", 0.5, 3.0, 0.05, defaults, "iconScale")
    iconScale:SetPoint("TOPLEFT", 5, yPos)
    iconScale:SetWidth(contentWidth - 10)
    yPos = yPos - 50

    local showDuration = GUI:CreateCheckbox(parent, "Show Duration", defaults, "showDuration")
    showDuration:SetPoint("TOPLEFT", 5, yPos)
    yPos = yPos - 24

    local showStacks = GUI:CreateCheckbox(parent, "Show Stack Count", defaults, "showStacks")
    showStacks:SetPoint("TOPLEFT", 5, yPos)
    yPos = yPos - 24

    local hideSwipeCb = GUI:CreateCheckbox(parent, "Hide Cooldown Swipe", defaults, "hideSwipe")
    hideSwipeCb:SetPoint("TOPLEFT", 5, yPos)
    yPos = yPos - 28

    -- ===== FONT SETTINGS =====
    local fontDiv = parent:CreateTexture(nil, "ARTWORK")
    fontDiv:SetPoint("TOPLEFT", 10, yPos)
    fontDiv:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
    fontDiv:SetHeight(1)
    fontDiv:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    yPos = yPos - 10

    local fontTitle = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fontTitle:SetPoint("TOPLEFT", 10, yPos)
    fontTitle:SetText("Font Settings")
    fontTitle:SetTextColor(c.r, c.g, c.b)
    yPos = yPos - 20

    local durFontLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    durFontLabel:SetPoint("TOPLEFT", 10, yPos)
    durFontLabel:SetText("Duration Text")
    durFontLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    yPos = yPos - 14

    local durFont = GUI:CreateFontDropdown(parent, "Font", defaults, "durationFont")
    durFont:SetPoint("TOPLEFT", 5, yPos)
    durFont:SetWidth(contentWidth - 10)
    yPos = yPos - 50

    local durScale = GUI:CreateSlider(parent, "Scale", 0.5, 2.0, 0.1, defaults, "durationScale")
    durScale:SetPoint("TOPLEFT", 5, yPos)
    durScale:SetWidth(contentWidth - 10)
    yPos = yPos - 50

    local durOutline = GUI:CreateDropdown(parent, "Outline", OUTLINE_OPTIONS, defaults, "durationOutline")
    durOutline:SetPoint("TOPLEFT", 5, yPos)
    durOutline:SetWidth(contentWidth - 10)
    yPos = yPos - 54

    local durAnchor = GUI:CreateDropdown(parent, "Anchor", ANCHOR_OPTIONS, defaults, "durationAnchor")
    durAnchor:SetPoint("TOPLEFT", 5, yPos)
    durAnchor:SetWidth(contentWidth - 10)
    yPos = yPos - 54

    local durOffX = GUI:CreateSlider(parent, "Offset X", -20, 20, 1, defaults, "durationX")
    durOffX:SetPoint("TOPLEFT", 5, yPos)
    durOffX:SetWidth(contentWidth - 10)
    yPos = yPos - 50

    local durOffY = GUI:CreateSlider(parent, "Offset Y", -20, 20, 1, defaults, "durationY")
    durOffY:SetPoint("TOPLEFT", 5, yPos)
    durOffY:SetWidth(contentWidth - 10)
    yPos = yPos - 54

    local stackFontLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    stackFontLabel:SetPoint("TOPLEFT", 10, yPos)
    stackFontLabel:SetText("Stack Text")
    stackFontLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    yPos = yPos - 14

    local stkFont = GUI:CreateFontDropdown(parent, "Font", defaults, "stackFont")
    stkFont:SetPoint("TOPLEFT", 5, yPos)
    stkFont:SetWidth(contentWidth - 10)
    yPos = yPos - 50

    local stkScale = GUI:CreateSlider(parent, "Scale", 0.5, 2.0, 0.1, defaults, "stackScale")
    stkScale:SetPoint("TOPLEFT", 5, yPos)
    stkScale:SetWidth(contentWidth - 10)
    yPos = yPos - 50

    local stkOutline = GUI:CreateDropdown(parent, "Outline", OUTLINE_OPTIONS, defaults, "stackOutline")
    stkOutline:SetPoint("TOPLEFT", 5, yPos)
    stkOutline:SetWidth(contentWidth - 10)
    yPos = yPos - 54

    local stkAnchor = GUI:CreateDropdown(parent, "Anchor", ANCHOR_OPTIONS, defaults, "stackAnchor")
    stkAnchor:SetPoint("TOPLEFT", 5, yPos)
    stkAnchor:SetWidth(contentWidth - 10)
    yPos = yPos - 54

    local stkOffX = GUI:CreateSlider(parent, "Offset X", -20, 20, 1, defaults, "stackX")
    stkOffX:SetPoint("TOPLEFT", 5, yPos)
    stkOffX:SetWidth(contentWidth - 10)
    yPos = yPos - 50

    local stkOffY = GUI:CreateSlider(parent, "Offset Y", -20, 20, 1, defaults, "stackY")
    stkOffY:SetPoint("TOPLEFT", 5, yPos)
    stkOffY:SetWidth(contentWidth - 10)
    yPos = yPos - 54

    -- ===== IMPORT FROM BUFFS TAB =====
    local div0 = parent:CreateTexture(nil, "ARTWORK")
    div0:SetPoint("TOPLEFT", 10, yPos)
    div0:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
    div0:SetHeight(1)
    div0:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    yPos = yPos - 10

    local importTitle = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    importTitle:SetPoint("TOPLEFT", 10, yPos)
    importTitle:SetText("Import from Buffs Tab")
    importTitle:SetTextColor(c.r, c.g, c.b)
    yPos = yPos - 18

    local importDesc = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    importDesc:SetPoint("TOPLEFT", 10, yPos)
    importDesc:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
    importDesc:SetJustifyH("LEFT")
    importDesc:SetWordWrap(true)
    importDesc:SetText("Import your existing Buffs tab settings as defaults for all auras. Compatible settings will be applied automatically.")
    importDesc:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    yPos = yPos - 36

    -- Compatibility list
    local compatItems = {
        {true,  "Icon size, scale & border"},
        {true,  "Duration & stack display"},
        {true,  "Font settings"},
        {false, "Position & anchors"},
        {false, "Per-aura overrides"},
    }
    for _, item in ipairs(compatItems) do
        local isCompat = item[1]
        local itemLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        itemLabel:SetPoint("TOPLEFT", 18, yPos)
        if isCompat then
            itemLabel:SetText("|TInterface\\AddOns\\DandersFrames\\Media\\Icons\\check:12:12|t  " .. item[2])
        else
            itemLabel:SetText("|TInterface\\AddOns\\DandersFrames\\Media\\Icons\\close:12:12|t  " .. item[2])
        end
        itemLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        yPos = yPos - 16
    end
    yPos = yPos - 6

    -- Import button
    local importBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    importBtn:SetHeight(26)
    importBtn:SetPoint("TOPLEFT", 10, yPos)
    importBtn:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
    ApplyBackdrop(importBtn, C_ELEMENT, C_BORDER)

    local importBtnText = importBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    importBtnText:SetPoint("CENTER", 0, 0)
    importBtnText:SetText("Import Buffs Tab Defaults")
    importBtnText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    importBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
    end)
    importBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    end)
    importBtn:SetScript("OnClick", function()
        -- Import compatible settings from the Buffs tab
        local mode = (GUI and GUI.SelectedMode) or "party"
        local buffsDB = DF:GetDB(mode)
        if buffsDB and defaults then
            -- Icon size/scale
            if buffsDB.buffSize then defaults.iconSize = buffsDB.buffSize end
            if buffsDB.buffScale then defaults.iconScale = buffsDB.buffScale end
            -- Duration/stacks
            if buffsDB.buffShowDuration ~= nil then defaults.showDuration = buffsDB.buffShowDuration end
            if buffsDB.buffShowStacks ~= nil then defaults.showStacks = buffsDB.buffShowStacks end
            -- Border
            if buffsDB.buffBorder ~= nil then defaults.iconBorderEnabled = buffsDB.buffBorder end
            -- Duration font
            if buffsDB.buffDurationFont then defaults.durationFont = buffsDB.buffDurationFont end
            if buffsDB.buffDurationScale then defaults.durationScale = buffsDB.buffDurationScale end
            if buffsDB.buffDurationOutline then defaults.durationOutline = buffsDB.buffDurationOutline end
            -- Stack font
            if buffsDB.buffStackFont then defaults.stackFont = buffsDB.buffStackFont end
            if buffsDB.buffStackScale then defaults.stackScale = buffsDB.buffStackScale end
            if buffsDB.buffStackOutline then defaults.stackOutline = buffsDB.buffStackOutline end
            DF:Debug("Aura Designer: Imported Buffs tab defaults")
            importBtnText:SetText("Imported!")
            C_Timer.After(1.5, function()
                importBtnText:SetText("Import Buffs Tab Defaults")
            end)
            DF:AuraDesigner_RefreshPage()
        end
    end)
    yPos = yPos - 34

    -- ===== DIVIDER =====
    local divider = parent:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT", 10, yPos)
    divider:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
    divider:SetHeight(1)
    divider:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
    yPos = yPos - 12

    -- ===== ACTIONS =====
    local actionsTitle = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    actionsTitle:SetPoint("TOPLEFT", 10, yPos)
    actionsTitle:SetText("Actions")
    actionsTitle:SetTextColor(c.r, c.g, c.b)
    yPos = yPos - 24

    -- Copy Settings to Other Mode button
    local currentMode = (GUI and GUI.SelectedMode) or "party"
    local targetMode = (currentMode == "party") and "raid" or "party"
    local targetLabel = (targetMode == "raid") and "Raid" or "Party"

    local copyBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    copyBtn:SetHeight(26)
    copyBtn:SetPoint("TOPLEFT", 10, yPos)
    copyBtn:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
    ApplyBackdrop(copyBtn, C_ELEMENT, C_BORDER)

    local copyText = copyBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    copyText:SetPoint("CENTER", 0, 0)
    copyText:SetText("Copy Settings to " .. targetLabel)
    copyText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    copyBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
    end)
    copyBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    end)
    copyBtn:SetScript("OnClick", function()
        local srcMode = (GUI and GUI.SelectedMode) or "party"
        local dstMode = (srcMode == "party") and "raid" or "party"
        local source = DF:GetDB(srcMode).auraDesigner
        local dest = DF:GetDB(dstMode).auraDesigner
        -- Deep copy
        local function DeepCopy(src)
            if type(src) ~= "table" then return src end
            local copy = {}
            for k, v in pairs(src) do copy[k] = DeepCopy(v) end
            return copy
        end
        local newCopy = DeepCopy(source)
        for k, v in pairs(newCopy) do dest[k] = v end
        local dstLabel = (dstMode == "raid") and "raid" or "party"
        DF:Debug("Aura Designer: Copied " .. srcMode .. " settings to " .. dstLabel)
    end)
    yPos = yPos - 32

    -- Reset All button
    local resetBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    resetBtn:SetHeight(26)
    resetBtn:SetPoint("TOPLEFT", 10, yPos)
    resetBtn:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
    ApplyBackdrop(resetBtn, {r = 0.3, g = 0.12, b = 0.12, a = 1}, {r = 0.5, g = 0.2, b = 0.2, a = 1})

    local resetText = resetBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    resetText:SetPoint("CENTER", 0, 0)
    resetText:SetText("Reset All Aura Configs")
    resetText:SetTextColor(1, 0.7, 0.7)

    resetBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.4, 0.15, 0.15, 1)
    end)
    resetBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.3, 0.12, 0.12, 1)
    end)
    resetBtn:SetScript("OnClick", function()
        wipe(GetAuraDesignerDB().auras)
        DF:AuraDesigner_RefreshPage()
        DF:Debug("Aura Designer: Reset all aura configurations")
    end)
    yPos = yPos - 40

    parent:SetHeight(-yPos + 10)
end

-- BuildPerAuraView + RefreshRightPanel removed in v4 redesign
-- Per-aura configuration is now done via flat effect cards in the Effects tab

-- Dummy stubs — needed to avoid nil reference if anything accidentally calls them
local function BuildPerAuraView() end
local function RefreshRightPanel() end

-- ============================================================
-- ENABLE BANNER
-- ============================================================

local function CreateEnableBanner(parent)
    local banner = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    banner:SetHeight(36)
    banner:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    banner:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    ApplyBackdrop(banner, {r = 0.14, g = 0.14, b = 0.14, a = 1}, {r = 0.30, g = 0.30, b = 0.30, a = 0.5})

    -- Themed checkbox (matches GUI:CreateCheckbox style)
    local cb = CreateFrame("CheckButton", nil, banner, "BackdropTemplate")
    cb:SetSize(18, 18)
    cb:SetPoint("LEFT", 10, 0)
    ApplyBackdrop(cb, C_ELEMENT, {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5})

    cb.Check = cb:CreateTexture(nil, "OVERLAY")
    cb.Check:SetTexture("Interface\\Buttons\\WHITE8x8")
    local tc = GetThemeColor()
    cb.Check:SetVertexColor(tc.r, tc.g, tc.b)
    cb.Check:SetPoint("CENTER")
    cb.Check:SetSize(10, 10)
    cb:SetCheckedTexture(cb.Check)

    local adDB = GetAuraDesignerDB()
    cb:SetChecked(adDB.enabled)
    cb:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        if checked then
            -- Show popup asking about buff coexistence
            ShowBuffCoexistPopup(function(keepBuffs)
                GetAuraDesignerDB().enabled = true
                db.showBuffs = keepBuffs
                DF:AuraDesigner_RefreshPage()
                DF:InvalidateAuraLayout()
                DF:UpdateAllFrames()
            end, function()
                -- Cancelled — revert checkbox
                self:SetChecked(false)
            end)
        else
            GetAuraDesignerDB().enabled = false
            DF:AuraDesigner_RefreshPage()
            DF:InvalidateAuraLayout()
            DF:UpdateAllFrames()
        end
    end)

    local cbLabel = banner:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cbLabel:SetPoint("LEFT", cb, "RIGHT", 8, 2)
    cbLabel:SetText("Enable Aura Designer")
    cbLabel:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    local cbSubLabel = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cbSubLabel:SetPoint("TOPLEFT", cbLabel, "BOTTOMLEFT", 0, -1)
    cbSubLabel:SetText("Custom buff and frame effect indicators")
    cbSubLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    local specLabel = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    specLabel:SetPoint("RIGHT", banner, "RIGHT", -145, 0)
    specLabel:SetText("Spec:")
    specLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    local specBtn = CreateFrame("Button", nil, banner, "BackdropTemplate")
    specBtn:SetSize(130, 22)
    specBtn:SetPoint("LEFT", specLabel, "RIGHT", 4, 0)
    ApplyBackdrop(specBtn, C_ELEMENT, C_BORDER)

    specBtn.text = specBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    specBtn.text:SetPoint("LEFT", 6, 0)
    specBtn.text:SetPoint("RIGHT", -16, 0)
    specBtn.text:SetJustifyH("LEFT")

    local arrow = specBtn:CreateTexture(nil, "OVERLAY")
    arrow:SetPoint("RIGHT", -4, 0)
    arrow:SetSize(10, 10)
    arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
    arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    local function UpdateSpecText()
        local adDB = GetAuraDesignerDB()
        if adDB.spec == "auto" then
            local autoSpec = Adapter:GetPlayerSpec()
            if autoSpec then
                specBtn.text:SetText("Auto (" .. Adapter:GetSpecDisplayName(autoSpec) .. ")")
            else
                specBtn.text:SetText("Auto (detect)")
            end
        else
            specBtn.text:SetText(Adapter:GetSpecDisplayName(adDB.spec))
        end
    end

    local specMenu = CreateFrame("Frame", nil, specBtn, "BackdropTemplate")
    specMenu:SetFrameStrata("FULLSCREEN_DIALOG")
    specMenu:SetPoint("TOPLEFT", specBtn, "BOTTOMLEFT", 0, -1)
    specMenu:SetWidth(200)
    ApplyBackdrop(specMenu, C_PANEL, {r = 0.35, g = 0.35, b = 0.35, a = 1})
    specMenu:Hide()

    local function BuildSpecMenu()
        for _, child in ipairs({specMenu:GetChildren()}) do
            child:Hide()
            child:SetParent(nil)
        end

        local yOffset = -4
        local options = {{"auto", "Auto (detect spec)"}}
        for _, specKey in ipairs({
            "PreservationEvoker", "AugmentationEvoker", "RestorationDruid",
            "DisciplinePriest", "HolyPriest", "MistweaverMonk",
            "RestorationShaman", "HolyPaladin"
        }) do
            options[#options + 1] = {specKey, Adapter:GetSpecDisplayName(specKey)}
        end

        for _, opt in ipairs(options) do
            local btn = CreateFrame("Button", nil, specMenu)
            btn:SetHeight(20)
            btn:SetPoint("TOPLEFT", 4, yOffset)
            btn:SetPoint("TOPRIGHT", -4, yOffset)

            local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            label:SetPoint("LEFT", 4, 0)
            label:SetText(opt[2])
            label:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

            btn:SetScript("OnEnter", function() label:SetTextColor(1, 1, 1) end)
            btn:SetScript("OnLeave", function() label:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b) end)
            btn:SetScript("OnClick", function()
                GetAuraDesignerDB().spec = opt[1]
                specMenu:Hide()
                UpdateSpecText()
                -- Clear expanded cards (auras change with spec)
                wipe(expandedCards)
                DF:AuraDesigner_RefreshPage()
            end)

            yOffset = yOffset - 20
        end
        specMenu:SetHeight(-yOffset + 4)
    end

    specBtn:SetScript("OnClick", function()
        if specMenu:IsShown() then
            specMenu:Hide()
        else
            BuildSpecMenu()
            specMenu:Show()
        end
    end)

    banner.UpdateSpecText = UpdateSpecText
    banner.checkbox = cb
    banner.specLabel = specLabel
    banner.specBtn = specBtn
    return banner
end



-- ============================================================
-- FRAME PREVIEW
-- Mock unit frame with health bar, power bar, name, health %,
-- and 9 anchor point dots for indicator placement
-- ============================================================

local function CreateFramePreview(parent, yOffset, rightPanelRef)
    -- Read current frame settings for the preview
    local mode = (GUI and GUI.SelectedMode) or "party"
    local frameDB = DF:GetDB(mode) or DF.PartyDefaults
    local FRAME_W = frameDB.frameWidth or 125
    local FRAME_H = frameDB.frameHeight or 64
    local POWER_H = frameDB.powerBarHeight or 4
    local showPower = frameDB.showPowerBar

    -- Preview scale from AD settings
    local adDB = GetAuraDesignerDB()
    local previewScale = adDB.previewScale or 1.0

    -- Outer container with label
    local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    local INSTR_COUNT = 3  -- number of instruction rows
    local INSTR_ROW_H = 18
    local rightInset = rightPanelRef and (rightPanelRef:GetWidth() + 6) or 0
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    container:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -rightInset, yOffset)
    container:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
    container:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -rightInset, 0)
    ApplyBackdrop(container, {r = 0.12, g = 0.12, b = 0.12, a = 1}, C_BORDER)

    -- "Frame Preview" label
    local previewLabel = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    previewLabel:SetPoint("TOPLEFT", 8, -4)
    previewLabel:SetText("FRAME PREVIEW")
    previewLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    -- Mock unit frame (centered in container)
    local mockFrame = CreateFrame("Frame", nil, container, "BackdropTemplate")
    mockFrame:SetSize(FRAME_W, FRAME_H)
    mockFrame:SetPoint("CENTER", container, "CENTER", 0, -4)
    mockFrame:SetScale(previewScale)
    ApplyBackdrop(mockFrame, {r = 0.07, g = 0.07, b = 0.07, a = 1}, {r = 0.27, g = 0.27, b = 0.27, a = 1})
    container.mockFrame = mockFrame

    -- Resolve health texture
    local healthTexPath = frameDB.healthTexture or "Interface\\Buttons\\WHITE8x8"

    -- Health bar background
    local healthBg = mockFrame:CreateTexture(nil, "BACKGROUND")
    healthBg:SetPoint("TOPLEFT", 1, -1)
    if showPower then
        healthBg:SetPoint("BOTTOMRIGHT", mockFrame, "BOTTOMRIGHT", -1, POWER_H + 1)
    else
        healthBg:SetPoint("BOTTOMRIGHT", mockFrame, "BOTTOMRIGHT", -1, 1)
    end
    healthBg:SetColorTexture(0, 0, 0, 0.4)

    -- Health bar fill (72% health)
    local healthFill = mockFrame:CreateTexture(nil, "ARTWORK")
    healthFill:SetPoint("TOPLEFT", 1, -1)
    if showPower then
        healthFill:SetPoint("BOTTOMLEFT", mockFrame, "BOTTOMLEFT", 1, POWER_H + 1)
    else
        healthFill:SetPoint("BOTTOMLEFT", mockFrame, "BOTTOMLEFT", 1, 1)
    end
    healthFill:SetWidth(FRAME_W * 0.72)
    healthFill:SetTexture(healthTexPath)
    healthFill:SetVertexColor(0.18, 0.80, 0.44, 0.85)
    container.healthFill = healthFill

    -- Missing health region
    local missingHealth = mockFrame:CreateTexture(nil, "ARTWORK")
    missingHealth:SetPoint("TOPRIGHT", mockFrame, "TOPRIGHT", -1, -1)
    if showPower then
        missingHealth:SetPoint("BOTTOMRIGHT", mockFrame, "BOTTOMRIGHT", -1, POWER_H + 1)
    else
        missingHealth:SetPoint("BOTTOMRIGHT", mockFrame, "BOTTOMRIGHT", -1, 1)
    end
    missingHealth:SetWidth(FRAME_W * 0.28)
    missingHealth:SetColorTexture(0, 0, 0, 0.4)

    -- Power bar (only if enabled in settings)
    if showPower then
        local powerBg = mockFrame:CreateTexture(nil, "ARTWORK")
        powerBg:SetPoint("BOTTOMLEFT", 1, 1)
        powerBg:SetPoint("BOTTOMRIGHT", mockFrame, "BOTTOMRIGHT", -1, 0)
        powerBg:SetHeight(POWER_H)
        powerBg:SetColorTexture(0.07, 0.07, 0.07, 1)

        local powerFill = mockFrame:CreateTexture(nil, "ARTWORK", nil, 1)
        powerFill:SetPoint("BOTTOMLEFT", 1, 1)
        powerFill:SetHeight(POWER_H)
        powerFill:SetWidth(FRAME_W * 0.85)
        powerFill:SetColorTexture(0.27, 0.53, 1, 0.9)

        -- Power bar top border
        local powerBorder = mockFrame:CreateTexture(nil, "ARTWORK", nil, 2)
        powerBorder:SetPoint("BOTTOMLEFT", mockFrame, "BOTTOMLEFT", 1, POWER_H)
        powerBorder:SetPoint("BOTTOMRIGHT", mockFrame, "BOTTOMRIGHT", -1, POWER_H)
        powerBorder:SetHeight(1)
        powerBorder:SetColorTexture(0.2, 0.2, 0.2, 1)
    end

    -- Resolve fonts from settings
    local nameFontPath = DF:GetFontPath(frameDB.nameFont) or "Fonts\\FRIZQT__.TTF"
    local nameFontSize = frameDB.nameFontSize or 11
    local healthFontPath = DF:GetFontPath(frameDB.healthFont) or "Fonts\\FRIZQT__.TTF"
    local healthFontSize = frameDB.healthFontSize or 10

    -- Name text (uses user's font + anchor settings)
    local nameAnchor = frameDB.nameTextAnchor or "TOP"
    local nameOffX = frameDB.nameTextX or 0
    local nameOffY = frameDB.nameTextY or -10

    local nameText = mockFrame:CreateFontString(nil, "OVERLAY")
    nameText:SetFont(nameFontPath, nameFontSize, "OUTLINE")
    nameText:SetPoint(nameAnchor, mockFrame, nameAnchor, nameOffX, nameOffY)
    nameText:SetText("Danders")
    nameText:SetTextColor(0.18, 0.80, 0.44, 1)
    container.nameText = nameText

    -- Health percentage (uses user's font + anchor settings)
    local healthAnchor = frameDB.healthTextAnchor or "CENTER"
    local healthOffX = frameDB.healthTextX or 0
    local healthOffY = frameDB.healthTextY or 4

    local hpText = mockFrame:CreateFontString(nil, "OVERLAY")
    hpText:SetFont(healthFontPath, healthFontSize, "OUTLINE")
    hpText:SetPoint(healthAnchor, mockFrame, healthAnchor, healthOffX, healthOffY)
    hpText:SetText("72%")
    hpText:SetTextColor(0.87, 0.87, 0.87, 1)
    container.hpText = hpText

    -- Border overlay (used when border effect is active)
    -- Uses highlight-compatible structure so DF.ApplyHighlightStyle can render all 6 modes
    container.borderOverlay = CreateFrame("Frame", nil, mockFrame)
    container.borderOverlay:SetAllPoints()
    container.borderOverlay:SetFrameLevel(mockFrame:GetFrameLevel() + 5)
    container.borderOverlay.topLine = container.borderOverlay:CreateTexture(nil, "OVERLAY")
    container.borderOverlay.bottomLine = container.borderOverlay:CreateTexture(nil, "OVERLAY")
    container.borderOverlay.leftLine = container.borderOverlay:CreateTexture(nil, "OVERLAY")
    container.borderOverlay.rightLine = container.borderOverlay:CreateTexture(nil, "OVERLAY")
    container.borderOverlay:Hide()

    -- Click background — no-op in new UI (was used to deselect aura in old tile view)
    local bgClick = CreateFrame("Button", nil, mockFrame)
    bgClick:SetAllPoints()
    bgClick:SetFrameLevel(mockFrame:GetFrameLevel() + 1)  -- Below dots and indicators
    bgClick:RegisterForClicks("LeftButtonUp")

    -- ========================================
    -- 9 ANCHOR POINT DOTS
    -- ========================================
    wipe(anchorDots)
    for anchorName, pos in pairs(ANCHOR_POSITIONS) do
        local dotFrame = CreateFrame("Frame", nil, mockFrame)
        dotFrame:SetSize(20, 20)
        dotFrame:SetFrameLevel(mockFrame:GetFrameLevel() + 10)

        -- Position the dot zone
        dotFrame:SetPoint(pos.ax, mockFrame, pos.ay, 0, 0)

        -- The visible dot
        local dot = dotFrame:CreateTexture(nil, "OVERLAY")
        dot:SetSize(6, 6)
        dot:SetPoint("CENTER", 0, 0)
        dot:SetColorTexture(0.45, 0.45, 0.95, 0.3)
        dotFrame.dot = dot

        -- Hover zone (invisible button) -- also acts as drop target during drag
        local hoverBtn = CreateFrame("Button", nil, dotFrame)
        hoverBtn:SetAllPoints()
        local capturedAnchorName = anchorName
        hoverBtn:SetScript("OnEnter", function()
            if dragState.isDragging then
                -- Drag hover: enlarge and accent-color the dot
                local tc = GetThemeColor()
                dot:SetSize(14, 14)
                dot:SetColorTexture(tc.r, tc.g, tc.b, 0.9)
                dragState.dropAnchor = capturedAnchorName
                -- Update hint to show target anchor
                if dragHintText and dragState.auraInfo then
                    dragHintText:SetText("Place " .. dragState.auraInfo.display .. " at " .. capturedAnchorName)
                end
            else
                dot:SetSize(10, 10)
                dot:SetColorTexture(0.45, 0.45, 0.95, 0.7)
            end
        end)
        hoverBtn:SetScript("OnLeave", function()
            if dragState.isDragging then
                -- Revert to drag-active state (not default)
                dot:SetSize(10, 10)
                dot:SetColorTexture(0.45, 0.45, 0.95, 0.5)
                dragState.dropAnchor = nil
                -- Revert hint to generic drag message
                if dragHintText and dragState.auraInfo then
                    local tc = GetThemeColor()
                    dragHintText:SetText("Drop on an anchor point to place " .. dragState.auraInfo.display)
                    dragHintText:SetTextColor(tc.r, tc.g, tc.b, 0.9)
                end
            else
                dot:SetSize(6, 6)
                dot:SetColorTexture(0.45, 0.45, 0.95, 0.3)
            end
        end)

        dotFrame.anchorName = anchorName
        dotFrame:Hide()  -- Only visible during active drags
        anchorDots[anchorName] = dotFrame
    end

    -- Instructions with keyboard badge styling
    local instrRows = {
        { key = "Click",       desc = "an indicator on the frame to expand its settings" },
        { key = "Drag",        desc = "a placed indicator to reposition it on the frame" },
        { key = "Right-click", desc = "a placed indicator to remove it from the frame" },
    }

    local instrCount = #instrRows
    for i, row in ipairs(instrRows) do
        local rowBottomOffset = 10 + (instrCount - i) * 18

        -- Key badge background
        local badge = CreateFrame("Frame", nil, container, "BackdropTemplate")
        badge:SetHeight(13)
        badge:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 8, rowBottomOffset)
        ApplyBackdrop(badge, C_ELEMENT, C_BORDER)

        local keyText = badge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        keyText:SetPoint("CENTER", 0, 0)
        keyText:SetText(row.key)
        keyText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        local keyWidth = keyText:GetStringWidth()
        badge:SetWidth(max(keyWidth + 10, 20))

        -- Description text (word-wrapped within container bounds)
        local descText = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        descText:SetPoint("LEFT", badge, "RIGHT", 5, 0)
        descText:SetPoint("RIGHT", container, "RIGHT", -8, 0)
        descText:SetWordWrap(true)
        descText:SetJustifyH("LEFT")
        descText:SetText(row.desc)
        descText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.8)
    end

    -- ========================================
    -- PREVIEW SCALE SLIDER
    -- ========================================
    local scaleSlider = GUI:CreateSlider(container, "Preview Scale", 0.75, 2.5, 0.05, adDB, "previewScale",
        -- callback (on release)
        function()
            local s = adDB.previewScale or 1.0
            mockFrame:SetScale(s)
        end,
        -- lightweightUpdate (during drag)
        function()
            local s = adDB.previewScale or 1.0
            mockFrame:SetScale(s)
        end
    )
    scaleSlider:SetPoint("TOPLEFT", previewLabel, "BOTTOMLEFT", -4, -4)
    scaleSlider:SetSize(220, 30)

    -- Drag-state hint text (shows contextual guidance during drag operations)
    dragHintText = container:CreateFontString(nil, "OVERLAY")
    dragHintText:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
    dragHintText:SetPoint("TOP", mockFrame, "BOTTOM", 0, -6)
    dragHintText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.8)
    dragHintText:SetText("")

    return container
end


-- ============================================================
-- TAB SYSTEM, SPELL PICKER & EFFECT CARDS (v4 redesign)
-- Functions for the new tabbed right panel, spell picker overlay,
-- and collapsible effect card rendering.
-- ============================================================

-- Forward declarations (mutually referencing functions)
local SwitchTab, ShowSpellPicker, HideSpellPicker
local BuildEffectsTab, BuildGlobalTab, BuildLayoutGroupsTab
local PopulateSpellGrid, CreateEffectCard

local spellPickerMode = "placed"   -- "placed" | "frame"

-- Check if a specific aura has a frame-level effect of given type
local function HasFrameEffect(auraName, typeKey)
    local auraCfg = GetSpecAuras()[auraName]
    return auraCfg and auraCfg[typeKey] ~= nil
end

-- Clear all child frames and regions from the tab content area
local function ClearTabContent()
    if not tabContentFrame then return end
    local children = { tabContentFrame:GetChildren() }
    for _, child in ipairs(children) do
        child:Hide()
        child:ClearAllPoints()
    end
    local regions = { tabContentFrame:GetRegions() }
    for _, region in ipairs(regions) do
        region:Hide()
    end
end

-- ── HIDE SPELL PICKER ──
HideSpellPicker = function()
    if not spellPickerView then return end
    spellPickerActive = false
    spellPickerType = nil
    spellPickerView:Hide()
    if tabBar then tabBar:Show() end
    if tabScrollFrame then tabScrollFrame:Show() end
end

-- ── SHOW SPELL PICKER ──
-- typeKey: "icon"|"square"|"bar" (placed) or "border"|"healthbar"|etc. (frame)
-- mode: "placed" (default) or "frame"
ShowSpellPicker = function(typeKey, mode)
    if not spellPickerView then return end
    spellPickerActive = true
    spellPickerType = typeKey
    spellPickerMode = mode or "placed"

    if tabBar then tabBar:Hide() end
    if tabScrollFrame then tabScrollFrame:Hide() end

    if spellPickerMode == "placed" then
        spellPickerView.title:SetText("Select a spell")
    else
        local effectLabel = FRAME_LEVEL_LABELS[typeKey] or typeKey
        spellPickerView.title:SetText("Select trigger for " .. effectLabel)
    end

    local badgeColor = BADGE_COLORS[typeKey] or BADGE_COLORS.icon
    local typeLabel = PLACED_TYPE_LABELS[typeKey] or FRAME_LEVEL_LABELS[typeKey] or typeKey
    spellPickerView.typeBadge:SetText(typeLabel)
    spellPickerView.typeBadge:SetTextColor(badgeColor.r, badgeColor.g, badgeColor.b)

    PopulateSpellGrid()
    spellPickerView:Show()
end

-- ── SWITCH TAB ──
SwitchTab = function(tabKey)
    activeTab = tabKey
    if spellPickerActive then
        HideSpellPicker()
    end

    for key, btn in pairs(tabButtons) do
        if key == tabKey then
            btn.accent:Show()
            btn.label:SetTextColor(btn.tabColor.r, btn.tabColor.g, btn.tabColor.b)
        else
            btn.accent:Hide()
            btn.label:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
    end

    ClearTabContent()

    if tabKey == "effects" then
        BuildEffectsTab()
    elseif tabKey == "layout" then
        BuildLayoutGroupsTab()
    elseif tabKey == "global" then
        BuildGlobalTab()
    end

    if tabScrollFrame then
        tabScrollFrame:SetVerticalScroll(0)
    end
end

-- ── POPULATE SPELL GRID ──
PopulateSpellGrid = function()
    if not spellPickerView or not spellPickerView.gridFrame then return end
    local grid = spellPickerView.gridFrame

    local children = { grid:GetChildren() }
    for _, child in ipairs(children) do child:Hide() end
    local regions = { grid:GetRegions() }
    for _, region in ipairs(regions) do region:Hide() end

    local spec = ResolveSpec()
    if not spec then return end

    local auras = Adapter:GetTrackableAuras(spec)
    if not auras or #auras == 0 then return end

    local CARD_SIZE = 78
    local CARD_GAP = 6
    local PADDING = 8
    local gridWidth = grid:GetWidth()
    if gridWidth < 100 then gridWidth = 260 end
    local cols = max(2, math.floor((gridWidth - PADDING * 2 + CARD_GAP) / (CARD_SIZE + CARD_GAP)))

    for i, auraInfo in ipairs(auras) do
        local row = math.floor((i - 1) / cols)
        local col = (i - 1) % cols
        local x = PADDING + col * (CARD_SIZE + CARD_GAP)
        local y = -(PADDING + row * (CARD_SIZE + CARD_GAP))

        local alreadyUsed
        if spellPickerMode == "placed" then
            alreadyUsed = IsAuraTypePlaced(auraInfo.name, spellPickerType)
        else
            alreadyUsed = HasFrameEffect(auraInfo.name, spellPickerType)
        end

        local card = CreateFrame("Button", nil, grid, "BackdropTemplate")
        card:SetSize(CARD_SIZE, CARD_SIZE)
        card:SetPoint("TOPLEFT", x, y)

        if alreadyUsed then
            ApplyBackdrop(card, {r = 0.10, g = 0.10, b = 0.10, a = 0.5}, {r = 0.20, g = 0.20, b = 0.20, a = 0.5})
        else
            ApplyBackdrop(card, {r = 0.14, g = 0.14, b = 0.14, a = 1}, {r = 0.28, g = 0.28, b = 0.28, a = 1})
        end

        -- Spell icon
        local iconTex = GetAuraIcon(spec, auraInfo.name)
        local icon = card:CreateTexture(nil, "ARTWORK")
        icon:SetSize(42, 42)
        icon:SetPoint("TOP", 0, -6)
        if iconTex then
            icon:SetTexture(iconTex)
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        else
            icon:SetColorTexture(auraInfo.color[1] * 0.4, auraInfo.color[2] * 0.4, auraInfo.color[3] * 0.4, 1)
        end
        if alreadyUsed then icon:SetAlpha(0.35) end

        -- Letter fallback
        if not iconTex then
            local letter = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            letter:SetPoint("CENTER", icon, "CENTER", 0, 0)
            letter:SetText(auraInfo.display:sub(1, 1))
            letter:SetTextColor(auraInfo.color[1], auraInfo.color[2], auraInfo.color[3])
            if alreadyUsed then letter:SetAlpha(0.35) end
        end

        -- Spell name
        local name = card:CreateFontString(nil, "OVERLAY")
        name:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE")
        name:SetPoint("BOTTOM", 0, 4)
        name:SetWidth(CARD_SIZE - 6)
        name:SetMaxLines(2)
        name:SetWordWrap(true)
        name:SetText(auraInfo.display)
        name:SetTextColor(1, 1, 1)
        name:SetJustifyH("CENTER")
        if alreadyUsed then name:SetAlpha(0.35) end

        -- "Placed" / "Active" overlay
        if alreadyUsed then
            local usedLabel = card:CreateFontString(nil, "OVERLAY")
            usedLabel:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
            usedLabel:SetPoint("CENTER", icon, "CENTER", 0, 0)
            usedLabel:SetText(spellPickerMode == "placed" and "Placed" or "Active")
            usedLabel:SetTextColor(0.6, 0.6, 0.6)
        end

        -- Interaction behavior
        if not alreadyUsed then
            card:SetScript("OnEnter", function(self)
                local tc = GetThemeColor()
                self:SetBackdropBorderColor(tc.r, tc.g, tc.b, 1)
            end)
            card:SetScript("OnLeave", function(self)
                self:SetBackdropBorderColor(0.28, 0.28, 0.28, 1)
            end)

            if spellPickerMode == "placed" then
                -- Placed indicators: drag-and-drop onto the frame preview
                local capturedAuraInfo = auraInfo
                local capturedType = spellPickerType
                card:RegisterForDrag("LeftButton")
                card:SetScript("OnDragStart", function()
                    local spec = ResolveSpec()
                    HideSpellPicker()
                    SwitchTab("effects")
                    StartDrag(capturedAuraInfo.name, capturedAuraInfo, spec, capturedType)
                end)
                -- Click also works — place at default anchor (CENTER)
                card:SetScript("OnClick", function()
                    local instance = CreateIndicatorInstance(capturedAuraInfo.name, capturedType)
                    if instance then
                        local cardKey = "placed:" .. capturedAuraInfo.name .. "#" .. instance.id
                        expandedCards[cardKey] = true
                    end
                    HideSpellPicker()
                    SwitchTab("effects")
                    RefreshPlacedIndicators()
                    RefreshPreviewEffects()
                end)
            else
                -- Frame-level effects: click to add directly
                card:SetScript("OnClick", function()
                    EnsureTypeConfig(auraInfo.name, spellPickerType)
                    local cardKey = "frame:" .. spellPickerType .. ":" .. auraInfo.name
                    expandedCards[cardKey] = true
                    HideSpellPicker()
                    SwitchTab("effects")
                    RefreshPlacedIndicators()
                    RefreshPreviewEffects()
                end)
            end
        end
    end

    -- Set grid height
    local totalRows = math.ceil(#auras / cols)
    grid:SetHeight(PADDING * 2 + totalRows * (CARD_SIZE + CARD_GAP))
end

-- ── CREATE EFFECT CARD ──
-- Creates a collapsible card for one effect in the effects list.
-- Returns the new yPos after the card.
CreateEffectCard = function(parent, yPos, effect)
    local isPlaced = (effect.source == "placed")
    local cardKey
    if isPlaced then
        cardKey = "placed:" .. effect.auraName .. "#" .. effect.indicatorID
    else
        cardKey = "frame:" .. effect.typeKey .. ":" .. effect.auraName
    end

    local isExpanded = expandedCards[cardKey] or false

    -- Card container
    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    card:SetPoint("TOPLEFT", 6, yPos)
    card:SetPoint("RIGHT", parent, "RIGHT", -6, 0)

    -- ── HEADER ──
    local header = CreateFrame("Button", nil, card, "BackdropTemplate")
    header:SetHeight(30)
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", 0, 0)
    ApplyBackdrop(header, C_ELEMENT, {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5})

    -- Chevron
    local chevron = header:CreateTexture(nil, "OVERLAY")
    chevron:SetSize(12, 12)
    chevron:SetPoint("LEFT", 8, 0)
    if isExpanded then
        chevron:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
    else
        chevron:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
    end
    chevron:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    -- Spell icon (small, before type badge)
    local spec = ResolveSpec()
    local iconTex = GetAuraIcon(spec, effect.auraName)
    local spellIcon = header:CreateTexture(nil, "ARTWORK")
    spellIcon:SetSize(20, 20)
    spellIcon:SetPoint("LEFT", chevron, "RIGHT", 6, 0)
    if iconTex then
        spellIcon:SetTexture(iconTex)
        spellIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    else
        -- Color swatch fallback using aura color
        local trackable3 = spec and Adapter and Adapter:GetTrackableAuras(spec)
        local auraColor = nil
        if trackable3 then
            for _, ai in ipairs(trackable3) do
                if ai.name == effect.auraName then auraColor = ai.color; break end
            end
        end
        if auraColor then
            spellIcon:SetColorTexture(auraColor[1] * 0.5, auraColor[2] * 0.5, auraColor[3] * 0.5, 1)
        else
            spellIcon:SetColorTexture(0.25, 0.25, 0.25, 1)
        end
    end

    -- Type badge
    local badgeColor = BADGE_COLORS[effect.typeKey] or BADGE_COLORS.icon
    local typeLabel = isPlaced
        and (PLACED_TYPE_LABELS[effect.typeKey] or effect.typeKey)
        or (FRAME_LEVEL_LABELS[effect.typeKey] or effect.typeKey)

    local badgeBg = CreateFrame("Frame", nil, header, "BackdropTemplate")
    badgeBg:SetHeight(16)
    badgeBg:SetPoint("LEFT", spellIcon, "RIGHT", 4, 0)
    ApplyBackdrop(badgeBg,
        {r = badgeColor.r * 0.20, g = badgeColor.g * 0.20, b = badgeColor.b * 0.20, a = 1},
        {r = badgeColor.r * 0.45, g = badgeColor.g * 0.45, b = badgeColor.b * 0.45, a = 0.8})

    local badgeText = badgeBg:CreateFontString(nil, "OVERLAY")
    badgeText:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE")
    badgeText:SetPoint("CENTER", 0, 0)
    badgeText:SetText(typeLabel)
    badgeText:SetTextColor(1, 1, 1)
    badgeBg:SetWidth(max(badgeText:GetStringWidth() + 12, 32))

    -- Aura name + anchor/trigger/group info
    local infoStr = effect.displayName
    local indicatorGroup = nil  -- layout group this indicator belongs to
    if isPlaced then
        indicatorGroup = GetIndicatorLayoutGroup(effect.auraName, effect.indicatorID)
        if indicatorGroup then
            infoStr = infoStr .. "  -  " .. indicatorGroup.name
        elseif effect.anchor then
            infoStr = infoStr .. "  -  " .. (ANCHOR_OPTIONS[effect.anchor] or effect.anchor)
        end
    else
        -- Show trigger count for frame-level effects
        local triggers = GetFrameEffectTriggers(effect.auraName, effect.typeKey)
        if #triggers > 1 then
            infoStr = infoStr .. "  -  +" .. (#triggers - 1) .. " trigger" .. (#triggers > 2 and "s" or "")
        end
    end
    local infoText = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    infoText:SetPoint("LEFT", badgeBg, "RIGHT", 6, 0)
    infoText:SetPoint("RIGHT", header, "RIGHT", indicatorGroup and -8 or -30, 0)
    infoText:SetMaxLines(1)
    infoText:SetText(infoStr)
    if indicatorGroup then
        -- Use dimmed text for grouped indicators — they're managed by the group
        infoText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    else
        infoText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    end

    -- Delete button — hidden for grouped indicators (managed by layout group)
    if not indicatorGroup then
        local delBtn = CreateFrame("Button", nil, header, "BackdropTemplate")
        delBtn:SetSize(22, 22)
        delBtn:SetPoint("RIGHT", -4, 0)
        delBtn:SetFrameLevel(header:GetFrameLevel() + 2)

        -- Draw a thick × using two rotated texture lines
        local xSize = 12
        local xThick = 2
        local line1 = delBtn:CreateTexture(nil, "OVERLAY")
        line1:SetSize(xSize, xThick)
        line1:SetPoint("CENTER", 0, 0)
        line1:SetColorTexture(0.55, 0.20, 0.20, 1)
        line1:SetRotation(math.rad(45))
        local line2 = delBtn:CreateTexture(nil, "OVERLAY")
        line2:SetSize(xSize, xThick)
        line2:SetPoint("CENTER", 0, 0)
        line2:SetColorTexture(0.55, 0.20, 0.20, 1)
        line2:SetRotation(math.rad(-45))

        delBtn:SetScript("OnEnter", function()
            line1:SetColorTexture(1, 0.35, 0.35, 1)
            line2:SetColorTexture(1, 0.35, 0.35, 1)
        end)
        delBtn:SetScript("OnLeave", function()
            line1:SetColorTexture(0.55, 0.20, 0.20, 1)
            line2:SetColorTexture(0.55, 0.20, 0.20, 1)
        end)
        delBtn:SetScript("OnClick", function()
            if isPlaced then
                RemoveIndicatorInstance(effect.auraName, effect.indicatorID)
            else
                local auraCfg = GetSpecAuras()[effect.auraName]
                if auraCfg then auraCfg[effect.typeKey] = nil end
            end
            expandedCards[cardKey] = nil
            SwitchTab("effects")
            RefreshPlacedIndicators()
            RefreshPreviewEffects()
        end)
    end

    -- Header click → toggle expansion
    header:SetScript("OnClick", function()
        expandedCards[cardKey] = not expandedCards[cardKey]
        SwitchTab("effects")
    end)
    header:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
    end)
    header:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    end)

    local totalCardH = 30

    -- ── BODY (only when expanded) ──
    if isExpanded then
        local body = CreateFrame("Frame", nil, card, "BackdropTemplate")
        body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
        body:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
        ApplyBackdrop(body, {r = 0.09, g = 0.09, b = 0.09, a = 1},
            {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.3})

        -- Create the appropriate proxy
        local proxy
        if isPlaced then
            proxy = CreateInstanceProxy(effect.auraName, effect.indicatorID)
        else
            proxy = CreateProxy(effect.auraName, effect.typeKey)
        end

        -- Build type-specific widgets (derive width from parent scroll frame)
        local bodyWidth = (tabContentFrame and tabContentFrame:GetWidth() or 260) - 24
        if bodyWidth < 100 then bodyWidth = 240 end

        local triggersH = 0

        -- ── TRIGGER TAGS (frame-level effects only) ──
        if not isPlaced then
            local triggers = GetFrameEffectTriggers(effect.auraName, effect.typeKey)
            local trigContainer = CreateFrame("Frame", nil, body)
            trigContainer:SetPoint("TOPLEFT", 8, -6)
            trigContainer:SetPoint("RIGHT", body, "RIGHT", -8, 0)

            local trigLabel = trigContainer:CreateFontString(nil, "OVERLAY")
            trigLabel:SetFont("Fonts\\FRIZQT__.TTF", 8, "")
            trigLabel:SetPoint("TOPLEFT", 0, 0)
            trigLabel:SetText("TRIGGERED BY")
            trigLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

            -- Build display name lookup for tags
            local spec = ResolveSpec()
            local trackable = spec and Adapter and Adapter:GetTrackableAuras(spec)
            local displayNames = {}
            if trackable then
                for _, info in ipairs(trackable) do
                    displayNames[info.name] = info.display
                end
            end

            -- Tag flow layout
            local TAG_H = 20
            local TAG_GAP = 4
            local TAG_ROW_GAP = 3
            local tagX, tagY = 0, -(12 + 4)  -- below label
            local canRemove = #triggers > 1

            for ti, trigName in ipairs(triggers) do
                local tagFrame = CreateFrame("Frame", nil, trigContainer, "BackdropTemplate")
                tagFrame:SetHeight(TAG_H)

                local tagText = tagFrame:CreateFontString(nil, "OVERLAY")
                tagText:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
                tagText:SetPoint("LEFT", 6, 0)
                tagText:SetText(displayNames[trigName] or trigName)
                tagText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

                local tagW = tagText:GetStringWidth() + 12
                if canRemove then tagW = tagW + 16 end  -- room for × button
                tagW = max(tagW, 40)

                -- Wrap to next row if needed
                local containerW = trigContainer:GetWidth()
                if containerW < 50 then containerW = bodyWidth - 16 end
                if tagX > 0 and (tagX + tagW) > containerW then
                    tagX = 0
                    tagY = tagY - (TAG_H + TAG_ROW_GAP)
                end

                tagFrame:SetPoint("TOPLEFT", trigContainer, "TOPLEFT", tagX, tagY)
                tagFrame:SetWidth(tagW)
                ApplyBackdrop(tagFrame,
                    {r = 0.14, g = 0.14, b = 0.17, a = 1},
                    {r = 0.30, g = 0.30, b = 0.35, a = 0.8})

                -- Remove × button on each tag (unless it's the last one)
                if canRemove then
                    local removeBtn = CreateFrame("Button", nil, tagFrame)
                    removeBtn:SetSize(14, 14)
                    removeBtn:SetPoint("RIGHT", -2, 0)
                    local rx1 = removeBtn:CreateTexture(nil, "OVERLAY")
                    rx1:SetSize(8, 1.5)
                    rx1:SetPoint("CENTER", 0, 0)
                    rx1:SetColorTexture(0.50, 0.30, 0.30, 1)
                    rx1:SetRotation(math.rad(45))
                    local rx2 = removeBtn:CreateTexture(nil, "OVERLAY")
                    rx2:SetSize(8, 1.5)
                    rx2:SetPoint("CENTER", 0, 0)
                    rx2:SetColorTexture(0.50, 0.30, 0.30, 1)
                    rx2:SetRotation(math.rad(-45))
                    removeBtn:SetScript("OnEnter", function()
                        rx1:SetColorTexture(1, 0.40, 0.40, 1)
                        rx2:SetColorTexture(1, 0.40, 0.40, 1)
                    end)
                    removeBtn:SetScript("OnLeave", function()
                        rx1:SetColorTexture(0.50, 0.30, 0.30, 1)
                        rx2:SetColorTexture(0.50, 0.30, 0.30, 1)
                    end)
                    local capturedTrigName = trigName
                    removeBtn:SetScript("OnClick", function()
                        RemoveFrameEffectTrigger(effect.auraName, effect.typeKey, capturedTrigName)
                        SwitchTab("effects")
                        RefreshPreviewEffects()
                    end)
                end

                tagX = tagX + tagW + TAG_GAP
            end

            -- "+ Add Trigger" button
            local addTrigW = 80
            if tagX > 0 and (tagX + addTrigW) > (bodyWidth - 16) then
                tagX = 0
                tagY = tagY - (TAG_H + TAG_ROW_GAP)
            end
            local addTrigBtn = CreateFrame("Button", nil, trigContainer, "BackdropTemplate")
            addTrigBtn:SetSize(addTrigW, TAG_H)
            addTrigBtn:SetPoint("TOPLEFT", trigContainer, "TOPLEFT", tagX, tagY)
            ApplyBackdrop(addTrigBtn,
                {r = 0.10, g = 0.12, b = 0.10, a = 1},
                {r = 0.25, g = 0.40, b = 0.25, a = 0.8})
            local addTrigText = addTrigBtn:CreateFontString(nil, "OVERLAY")
            addTrigText:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
            addTrigText:SetPoint("CENTER", 0, 0)
            addTrigText:SetText("+ Add Trigger")
            addTrigText:SetTextColor(0.5, 0.8, 0.5)
            addTrigBtn:SetScript("OnEnter", function(self)
                self:SetBackdropColor(0.15, 0.20, 0.15, 1)
                addTrigText:SetTextColor(0.7, 1.0, 0.7)
            end)
            addTrigBtn:SetScript("OnLeave", function(self)
                self:SetBackdropColor(0.10, 0.12, 0.10, 1)
                addTrigText:SetTextColor(0.5, 0.8, 0.5)
            end)

            -- Trigger picker dropdown
            addTrigBtn:SetScript("OnClick", function()
                -- Build dropdown with trackable auras not already in triggers
                local spec2 = ResolveSpec()
                local auraList = spec2 and Adapter and Adapter:GetTrackableAuras(spec2)
                if not auraList then return end

                local currentTriggers = GetFrameEffectTriggers(effect.auraName, effect.typeKey)
                local trigLookup = {}
                for _, t in ipairs(currentTriggers) do trigLookup[t] = true end

                -- Create or reuse dropdown frame
                local dropName = "DFADTriggerPicker"
                local drop = _G[dropName]
                if not drop then
                    drop = CreateFrame("Frame", dropName, UIParent, "BackdropTemplate")
                    drop:SetFrameStrata("FULLSCREEN_DIALOG")
                    drop:SetClampedToScreen(true)
                end
                -- Hide if already showing for this button
                if drop:IsShown() and drop._ownerBtn == addTrigBtn then
                    drop:Hide()
                    return
                end
                drop._ownerBtn = addTrigBtn

                -- Clear children
                for _, child in ipairs({drop:GetChildren()}) do child:Hide(); child:SetParent(nil) end
                for _, rgn in ipairs({drop:GetRegions()}) do
                    if rgn:GetObjectType() == "FontString" then rgn:Hide() end
                end

                drop:SetWidth(180)
                ApplyBackdrop(drop, C_BACKGROUND, C_BORDER)

                local dy = -4
                local count = 0
                for _, auraInfo in ipairs(auraList) do
                    local alreadyAdded = trigLookup[auraInfo.name]
                    local btn = CreateFrame("Button", nil, drop)
                    btn:SetHeight(20)
                    btn:SetPoint("TOPLEFT", 4, dy)
                    btn:SetPoint("RIGHT", drop, "RIGHT", -4, 0)

                    local lbl = btn:CreateFontString(nil, "OVERLAY")
                    lbl:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
                    lbl:SetPoint("LEFT", 6, 0)
                    lbl:SetText(auraInfo.display or auraInfo.name)
                    if alreadyAdded then
                        lbl:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.5)
                        btn:Disable()
                    else
                        lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
                        hl:SetAllPoints()
                        hl:SetColorTexture(1, 1, 1, 0.05)
                        local capturedName = auraInfo.name
                        btn:SetScript("OnClick", function()
                            AddFrameEffectTrigger(effect.auraName, effect.typeKey, capturedName)
                            drop:Hide()
                            SwitchTab("effects")
                            RefreshPreviewEffects()
                        end)
                    end
                    dy = dy - 20
                    count = count + 1
                end
                drop:SetHeight(-dy + 4)

                -- Position below the add button
                drop:ClearAllPoints()
                drop:SetPoint("TOPLEFT", addTrigBtn, "BOTTOMLEFT", 0, -2)
                drop:Show()

                -- Auto-hide when clicking elsewhere
                drop:SetScript("OnHide", function() drop._ownerBtn = nil end)
            end)

            triggersH = -(tagY) + TAG_H + 8  -- total height of trigger section
            trigContainer:SetHeight(triggersH)

            -- Priority slider (frame-level effects only — resolves conflicts when
            -- multiple auras set the same frame effect, e.g. two health bar colors)
            local auraProxy = CreateAuraProxy(effect.auraName)
            local priSlider = GUI:CreateSlider(body, "Priority", 1, 10, 1, auraProxy, "priority")
            priSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(triggersH + 4))
            priSlider:SetWidth(bodyWidth - 10)
            triggersH = triggersH + 54
        end

        local _, bodyH = BuildTypeContent(body, effect.typeKey, effect.auraName, bodyWidth, proxy, triggersH, indicatorGroup, effect.indicatorID)
        body:SetHeight((bodyH or 50) + triggersH)
        totalCardH = totalCardH + (bodyH or 50) + triggersH
    end

    card:SetHeight(totalCardH)
    return yPos - totalCardH - 5
end

-- ── BUILD EFFECTS TAB ──
BuildEffectsTab = function()
    if not tabContentFrame then return end
    local parent = tabContentFrame
    local yPos = -10
    local tc = GetThemeColor()

    -- "+ Add Indicator" button (prominent, theme-colored border)
    local addBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    addBtn:SetHeight(32)
    addBtn:SetPoint("TOPLEFT", 8, yPos)
    addBtn:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    ApplyBackdrop(addBtn,
        {r = tc.r * 0.10, g = tc.g * 0.10, b = tc.b * 0.10, a = 1},
        {r = tc.r * 0.50, g = tc.g * 0.50, b = tc.b * 0.50, a = 1})

    local addBtnText = addBtn:CreateFontString(nil, "OVERLAY")
    addBtnText:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    addBtnText:SetPoint("CENTER", 0, 0)
    addBtnText:SetText("+ Add Indicator")
    addBtnText:SetTextColor(tc.r, tc.g, tc.b)

    addBtn:SetScript("OnEnter", function(self)
        local c = GetThemeColor()
        self:SetBackdropColor(c.r * 0.20, c.g * 0.20, c.b * 0.20, 1)
        self:SetBackdropBorderColor(c.r * 0.80, c.g * 0.80, c.b * 0.80, 1)
        addBtnText:SetTextColor(1, 1, 1)
    end)
    addBtn:SetScript("OnLeave", function(self)
        local c = GetThemeColor()
        self:SetBackdropColor(c.r * 0.10, c.g * 0.10, c.b * 0.10, 1)
        self:SetBackdropBorderColor(c.r * 0.50, c.g * 0.50, c.b * 0.50, 1)
        addBtnText:SetTextColor(c.r, c.g, c.b)
    end)

    -- Dropdown menu for add button
    local menuFrame = CreateFrame("Frame", nil, addBtn, "BackdropTemplate")
    menuFrame:SetPoint("TOPLEFT", addBtn, "BOTTOMLEFT", 0, -2)
    menuFrame:SetPoint("TOPRIGHT", addBtn, "BOTTOMRIGHT", 0, -2)
    menuFrame:SetFrameStrata("DIALOG")
    menuFrame:SetFrameLevel(100)
    ApplyBackdrop(menuFrame, {r = 0.10, g = 0.10, b = 0.10, a = 0.98}, C_BORDER)
    menuFrame:Hide()
    menuFrame:EnableMouse(true)

    local PLACED_ITEMS = {
        { label = "Icon",   type = "icon"   },
        { label = "Square", type = "square" },
        { label = "Bar",    type = "bar"    },
    }
    local FRAME_ITEMS = {
        { label = "Border",            type = "border"     },
        { label = "Health Bar Color",  type = "healthbar"  },
        { label = "Name Text Color",   type = "nametext"   },
        { label = "Health Text Color", type = "healthtext" },
        { label = "Frame Alpha",       type = "framealpha" },
    }

    local my = -4

    -- Section: Placed on Frame
    local placedHeader = menuFrame:CreateFontString(nil, "OVERLAY")
    placedHeader:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
    placedHeader:SetPoint("TOPLEFT", 10, my)
    placedHeader:SetText("PLACED ON FRAME")
    placedHeader:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    my = my - 14

    for _, item in ipairs(PLACED_ITEMS) do
        local menuBtn = CreateFrame("Button", nil, menuFrame)
        menuBtn:SetHeight(24)
        menuBtn:SetPoint("TOPLEFT", 4, my)
        menuBtn:SetPoint("RIGHT", menuFrame, "RIGHT", -4, 0)
        local bc = BADGE_COLORS[item.type]
        local lbl = menuBtn:CreateFontString(nil, "OVERLAY")
        lbl:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
        lbl:SetPoint("LEFT", 8, 0)
        lbl:SetText(item.label)
        lbl:SetTextColor(bc.r, bc.g, bc.b)
        local hl = menuBtn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.05)
        local capturedType = item.type
        menuBtn:SetScript("OnClick", function()
            menuFrame:Hide()
            ShowSpellPicker(capturedType, "placed")
        end)
        my = my - 24
    end

    -- Divider
    my = my - 4
    local mdiv = menuFrame:CreateTexture(nil, "ARTWORK")
    mdiv:SetPoint("TOPLEFT", 8, my)
    mdiv:SetPoint("RIGHT", menuFrame, "RIGHT", -8, 0)
    mdiv:SetHeight(1)
    mdiv:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.6)
    my = my - 6

    -- Section: Frame-level Effects
    local frameHeader = menuFrame:CreateFontString(nil, "OVERLAY")
    frameHeader:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
    frameHeader:SetPoint("TOPLEFT", 10, my)
    frameHeader:SetText("FRAME-LEVEL EFFECTS")
    frameHeader:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    my = my - 14

    for _, item in ipairs(FRAME_ITEMS) do
        local menuBtn = CreateFrame("Button", nil, menuFrame)
        menuBtn:SetHeight(24)
        menuBtn:SetPoint("TOPLEFT", 4, my)
        menuBtn:SetPoint("RIGHT", menuFrame, "RIGHT", -4, 0)
        local bc = BADGE_COLORS[item.type]
        local lbl = menuBtn:CreateFontString(nil, "OVERLAY")
        lbl:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
        lbl:SetPoint("LEFT", 8, 0)
        lbl:SetText(item.label)
        lbl:SetTextColor(bc.r, bc.g, bc.b)
        local hl = menuBtn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.05)
        local capturedType = item.type
        menuBtn:SetScript("OnClick", function()
            menuFrame:Hide()
            ShowSpellPicker(capturedType, "frame")
        end)
        my = my - 24
    end

    menuFrame:SetHeight(-my + 6)

    addBtn:SetScript("OnClick", function()
        if menuFrame:IsShown() then
            menuFrame:Hide()
        else
            menuFrame:Show()
        end
    end)

    yPos = yPos - 44

    -- ── ACTIVE INDICATORS heading ──
    local activeHeader = parent:CreateFontString(nil, "OVERLAY")
    activeHeader:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
    activeHeader:SetPoint("TOPLEFT", 10, yPos)
    activeHeader:SetText("ACTIVE INDICATORS")
    activeHeader:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    yPos = yPos - 16

    -- ── FILTER CHIPS (wrapping layout) ──
    local chipsFrame = CreateFrame("Frame", nil, parent)
    chipsFrame:SetPoint("TOPLEFT", 8, yPos)
    chipsFrame:SetPoint("RIGHT", parent, "RIGHT", -8, 0)

    local FILTER_CHIPS = {
        { key = "all",         label = "All"    },
        { key = "icon",        label = "Icon"   },
        { key = "square",      label = "Square" },
        { key = "bar",         label = "Bar"    },
        { key = "border",      label = "Border" },
        { key = "healthbar",   label = "Health" },
        { key = "nametext",    label = "Name"   },
        { key = "healthtext",  label = "HP"     },
        { key = "framealpha",  label = "Alpha"  },
    }

    local CHIP_H = 22
    local CHIP_GAP = 4
    local CHIP_ROW_GAP = 4
    local chipBtns = {}

    for _, chip in ipairs(FILTER_CHIPS) do
        local chipBtn = CreateFrame("Button", nil, chipsFrame, "BackdropTemplate")
        chipBtn:SetHeight(CHIP_H)

        local chipTxt = chipBtn:CreateFontString(nil, "OVERLAY")
        chipTxt:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        chipTxt:SetPoint("CENTER", 0, 0)
        chipTxt:SetText(chip.label)

        local tw = chipTxt:GetStringWidth()
        chipBtn:SetWidth(max(tw + 16, 32))

        if activeFilter == chip.key then
            ApplyBackdrop(chipBtn,
                {r = tc.r * 0.20, g = tc.g * 0.20, b = tc.b * 0.20, a = 1},
                {r = tc.r * 0.50, g = tc.g * 0.50, b = tc.b * 0.50, a = 1})
            chipTxt:SetTextColor(tc.r, tc.g, tc.b)
        else
            ApplyBackdrop(chipBtn,
                {r = 0.14, g = 0.14, b = 0.14, a = 1},
                {r = 0.25, g = 0.25, b = 0.25, a = 1})
            chipTxt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        end

        local capturedKey = chip.key
        chipBtn:SetScript("OnClick", function()
            activeFilter = capturedKey
            SwitchTab("effects")
        end)
        chipBtn:SetScript("OnEnter", function(self)
            if activeFilter ~= capturedKey then
                self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
            end
        end)
        chipBtn:SetScript("OnLeave", function(self)
            if activeFilter ~= capturedKey then
                self:SetBackdropColor(0.14, 0.14, 0.14, 1)
            end
        end)

        tinsert(chipBtns, chipBtn)
    end

    -- Flow-layout: position chips with wrapping on parent resize
    local function LayoutChips()
        local maxW = chipsFrame:GetWidth()
        if maxW < 20 then maxW = 260 end
        local cx, cy = 0, 0
        for _, btn in ipairs(chipBtns) do
            local bw = btn:GetWidth()
            if cx > 0 and (cx + bw) > maxW then
                cx = 0
                cy = cy - (CHIP_H + CHIP_ROW_GAP)
            end
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", chipsFrame, "TOPLEFT", cx, cy)
            cx = cx + bw + CHIP_GAP
        end
        chipsFrame:SetHeight(max(-cy + CHIP_H, CHIP_H))
    end
    LayoutChips()
    chipsFrame:SetScript("OnSizeChanged", LayoutChips)

    yPos = yPos - (chipsFrame:GetHeight() + 10)

    -- ── EFFECTS LIST ──
    local effects = CollectAllEffects()

    -- Apply filter
    local filtered = {}
    for _, effect in ipairs(effects) do
        if activeFilter == "all" or effect.typeKey == activeFilter then
            tinsert(filtered, effect)
        end
    end

    if #filtered == 0 then
        local empty = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        empty:SetPoint("TOP", parent, "TOP", 0, yPos - 30)
        empty:SetWidth(220)
        empty:SetText(activeFilter == "all"
            and "No effects configured yet.\nClick '+ Add Indicator' to get started."
            or "No " .. (PLACED_TYPE_LABELS[activeFilter] or FRAME_LEVEL_LABELS[activeFilter] or activeFilter) .. " effects configured.")
        empty:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.7)
        empty:SetJustifyH("CENTER")
    else
        for _, effect in ipairs(filtered) do
            yPos = CreateEffectCard(parent, yPos, effect)
        end
    end

    parent:SetHeight(max(-yPos + 20, 200))
end

-- ── BUILD GLOBAL TAB ──
-- Wraps the existing BuildGlobalView into the tab content frame
BuildGlobalTab = function()
    if not tabContentFrame then return end
    BuildGlobalView(tabContentFrame)
end

-- ── BUILD LAYOUT GROUPS TAB ──
BuildLayoutGroupsTab = function()
    if not tabContentFrame then return end
    local parent = tabContentFrame
    local yPos = -10
    local tc = GetThemeColor()

    -- Grow direction options
    local GROW_DIRECTIONS = {
        RIGHT = "Right", LEFT = "Left", UP = "Up", DOWN = "Down",
        _order = { "RIGHT", "LEFT", "UP", "DOWN" },
    }

    -- "+ Create Group" button (prominent, theme-colored)
    local addBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    addBtn:SetHeight(32)
    addBtn:SetPoint("TOPLEFT", 8, yPos)
    addBtn:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    local gc = { r = 0.91, g = 0.66, b = 0.25 }  -- Layout Groups tab color
    ApplyBackdrop(addBtn,
        {r = gc.r * 0.10, g = gc.g * 0.10, b = gc.b * 0.10, a = 1},
        {r = gc.r * 0.50, g = gc.g * 0.50, b = gc.b * 0.50, a = 1})
    local addBtnText = addBtn:CreateFontString(nil, "OVERLAY")
    addBtnText:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    addBtnText:SetPoint("CENTER", 0, 0)
    addBtnText:SetText("+ Create Group")
    addBtnText:SetTextColor(gc.r, gc.g, gc.b)
    addBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(gc.r * 0.20, gc.g * 0.20, gc.b * 0.20, 1)
        self:SetBackdropBorderColor(gc.r * 0.80, gc.g * 0.80, gc.b * 0.80, 1)
        addBtnText:SetTextColor(1, 1, 1)
    end)
    addBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(gc.r * 0.10, gc.g * 0.10, gc.b * 0.10, 1)
        self:SetBackdropBorderColor(gc.r * 0.50, gc.g * 0.50, gc.b * 0.50, 1)
        addBtnText:SetTextColor(gc.r, gc.g, gc.b)
    end)
    addBtn:SetScript("OnClick", function()
        local group = CreateLayoutGroup()
        if group then
            expandedGroups[group.id] = true
            SwitchTab("layout")
            RefreshPlacedIndicators()
        end
    end)
    yPos = yPos - 42

    -- Get groups
    local adDB = GetAuraDesignerDB()
    local groups = adDB and adDB.layoutGroups or {}

    -- Display name lookup
    local spec = ResolveSpec()
    local trackable = spec and Adapter and Adapter:GetTrackableAuras(spec)
    local displayNames = {}
    if trackable then
        for _, info in ipairs(trackable) do
            displayNames[info.name] = info.display
        end
    end

    if #groups == 0 then
        -- Empty state
        local empty = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        empty:SetPoint("TOP", parent, "TOP", 0, yPos - 30)
        empty:SetWidth(220)
        empty:SetText("No layout groups created yet.\nClick '+ Create Group' to get started.")
        empty:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.7)
        empty:SetJustifyH("CENTER")
    else
        -- Render group cards
        for _, group in ipairs(groups) do
            local isExpanded = expandedGroups[group.id] or false
            local groupCardKey = "group:" .. group.id

            -- Card container
            local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
            card:SetPoint("TOPLEFT", 6, yPos)
            card:SetPoint("RIGHT", parent, "RIGHT", -6, 0)

            -- ── HEADER ──
            local header = CreateFrame("Button", nil, card, "BackdropTemplate")
            header:SetHeight(30)
            header:SetPoint("TOPLEFT", 0, 0)
            header:SetPoint("TOPRIGHT", 0, 0)
            ApplyBackdrop(header, C_ELEMENT, {r = gc.r * 0.35, g = gc.g * 0.35, b = gc.b * 0.35, a = 0.5})

            -- Chevron
            local chevron = header:CreateTexture(nil, "OVERLAY")
            chevron:SetSize(12, 12)
            chevron:SetPoint("LEFT", 8, 0)
            if isExpanded then
                chevron:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
            else
                chevron:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
            end
            chevron:SetVertexColor(gc.r, gc.g, gc.b)

            -- Group name
            local nameText = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            nameText:SetPoint("LEFT", chevron, "RIGHT", 6, 0)
            nameText:SetPoint("RIGHT", header, "RIGHT", -60, 0)
            nameText:SetMaxLines(1)
            local memberCount = group.members and #group.members or 0
            nameText:SetText(group.name .. "  -  " .. memberCount .. " indicator" .. (memberCount ~= 1 and "s" or ""))
            nameText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

            -- Delete button
            local delBtn = CreateFrame("Button", nil, header, "BackdropTemplate")
            delBtn:SetSize(22, 22)
            delBtn:SetPoint("RIGHT", -4, 0)
            delBtn:SetFrameLevel(header:GetFrameLevel() + 2)
            local xSize, xThick = 12, 2
            local line1 = delBtn:CreateTexture(nil, "OVERLAY")
            line1:SetSize(xSize, xThick)
            line1:SetPoint("CENTER", 0, 0)
            line1:SetColorTexture(0.55, 0.20, 0.20, 1)
            line1:SetRotation(math.rad(45))
            local line2 = delBtn:CreateTexture(nil, "OVERLAY")
            line2:SetSize(xSize, xThick)
            line2:SetPoint("CENTER", 0, 0)
            line2:SetColorTexture(0.55, 0.20, 0.20, 1)
            line2:SetRotation(math.rad(-45))
            delBtn:SetScript("OnEnter", function()
                line1:SetColorTexture(1, 0.35, 0.35, 1)
                line2:SetColorTexture(1, 0.35, 0.35, 1)
            end)
            delBtn:SetScript("OnLeave", function()
                line1:SetColorTexture(0.55, 0.20, 0.20, 1)
                line2:SetColorTexture(0.55, 0.20, 0.20, 1)
            end)
            local capturedGroupID = group.id
            delBtn:SetScript("OnClick", function()
                DeleteLayoutGroup(capturedGroupID)
                SwitchTab("layout")
                RefreshPlacedIndicators()
            end)

            -- Header click → toggle expansion
            header:SetScript("OnClick", function()
                expandedGroups[group.id] = not expandedGroups[group.id]
                SwitchTab("layout")
            end)
            header:SetScript("OnEnter", function(self)
                self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
            end)
            header:SetScript("OnLeave", function(self)
                self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
            end)

            local totalCardH = 30

            -- ── BODY (when expanded) ──
            if isExpanded then
                local body = CreateFrame("Frame", nil, card, "BackdropTemplate")
                body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
                body:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
                ApplyBackdrop(body, {r = 0.09, g = 0.09, b = 0.09, a = 1},
                    {r = gc.r * 0.20, g = gc.g * 0.20, b = gc.b * 0.20, a = 0.3})

                local by = -10
                local bodyWidth = (tabContentFrame and tabContentFrame:GetWidth() or 260) - 24
                if bodyWidth < 100 then bodyWidth = 240 end

                -- Group Name (editable)
                local nameLabel = body:CreateFontString(nil, "OVERLAY")
                nameLabel:SetFont("Fonts\\FRIZQT__.TTF", 8, "")
                nameLabel:SetPoint("TOPLEFT", 8, by)
                nameLabel:SetText("GROUP NAME")
                nameLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 16

                local nameEdit = CreateFrame("EditBox", nil, body, "BackdropTemplate")
                nameEdit:SetHeight(22)
                nameEdit:SetPoint("TOPLEFT", 8, by)
                nameEdit:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                nameEdit:SetFontObject("GameFontHighlightSmall")
                nameEdit:SetAutoFocus(false)
                nameEdit:SetText(group.name)
                nameEdit:SetMaxLetters(30)
                ApplyBackdrop(nameEdit, {r = 0.12, g = 0.12, b = 0.12, a = 1}, C_BORDER)
                nameEdit:SetTextInsets(6, 6, 0, 0)
                nameEdit:SetScript("OnEnterPressed", function(self)
                    local val = self:GetText()
                    if val and val ~= "" then
                        group.name = val
                    end
                    self:ClearFocus()
                    SwitchTab("layout")
                end)
                nameEdit:SetScript("OnEscapePressed", function(self)
                    self:SetText(group.name)
                    self:ClearFocus()
                end)
                by = by - 32

                -- ── MEMBERS SECTION ──
                local memLabel = body:CreateFontString(nil, "OVERLAY")
                memLabel:SetFont("Fonts\\FRIZQT__.TTF", 8, "")
                memLabel:SetPoint("TOPLEFT", 8, by)
                memLabel:SetText("MEMBERS")
                memLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 18

                if group.members and #group.members > 0 then
                    for mi, member in ipairs(group.members) do
                        local memberRow = CreateFrame("Frame", nil, body, "BackdropTemplate")
                        memberRow:SetHeight(34)
                        memberRow:SetPoint("TOPLEFT", 8, by)
                        memberRow:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                        ApplyBackdrop(memberRow,
                            {r = 0.11, g = 0.11, b = 0.11, a = 1},
                            {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.3})

                        -- Up/Down buttons for reordering (stacked vertically on left)
                        local canMoveUp = mi > 1
                        local canMoveDown = mi < #group.members
                        local capturedMi = mi

                        if canMoveUp then
                            local upBtn = CreateFrame("Button", nil, memberRow)
                            upBtn:SetSize(20, 16)
                            upBtn:SetPoint("TOPLEFT", 2, -1)
                            local upIcon = upBtn:CreateTexture(nil, "OVERLAY")
                            upIcon:SetSize(14, 14)
                            upIcon:SetPoint("CENTER", 0, 0)
                            upIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
                            upIcon:SetRotation(math.rad(180))  -- flip to point up
                            upIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                            upBtn:SetScript("OnClick", function()
                                SwapGroupMembers(capturedGroupID, capturedMi, capturedMi - 1)
                                SwitchTab("layout")
                                RefreshPlacedIndicators()
                            end)
                            upBtn:SetScript("OnEnter", function() upIcon:SetVertexColor(1, 1, 1) end)
                            upBtn:SetScript("OnLeave", function() upIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b) end)
                        end
                        if canMoveDown then
                            local downBtn = CreateFrame("Button", nil, memberRow)
                            downBtn:SetSize(20, 16)
                            downBtn:SetPoint("BOTTOMLEFT", 2, 1)
                            local downIcon = downBtn:CreateTexture(nil, "OVERLAY")
                            downIcon:SetSize(14, 14)
                            downIcon:SetPoint("CENTER", 0, 0)
                            downIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
                            downIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                            downBtn:SetScript("OnClick", function()
                                SwapGroupMembers(capturedGroupID, capturedMi, capturedMi + 1)
                                SwitchTab("layout")
                                RefreshPlacedIndicators()
                            end)
                            downBtn:SetScript("OnEnter", function() downIcon:SetVertexColor(1, 1, 1) end)
                            downBtn:SetScript("OnLeave", function() downIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b) end)
                        end

                        -- Spell icon
                        local memberSpec = ResolveSpec()
                        local memberIconTex = GetAuraIcon(memberSpec, member.auraName)
                        local mSpellIcon = memberRow:CreateTexture(nil, "ARTWORK")
                        mSpellIcon:SetSize(22, 22)
                        mSpellIcon:SetPoint("LEFT", 26, 0)
                        if memberIconTex then
                            mSpellIcon:SetTexture(memberIconTex)
                            mSpellIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                        else
                            -- Color swatch fallback
                            local auraInfo2 = nil
                            local trackable2 = memberSpec and Adapter and Adapter:GetTrackableAuras(memberSpec)
                            if trackable2 then
                                for _, ai in ipairs(trackable2) do
                                    if ai.name == member.auraName then auraInfo2 = ai; break end
                                end
                            end
                            if auraInfo2 then
                                mSpellIcon:SetColorTexture(auraInfo2.color[1] * 0.5, auraInfo2.color[2] * 0.5, auraInfo2.color[3] * 0.5, 1)
                            else
                                mSpellIcon:SetColorTexture(0.25, 0.25, 0.25, 1)
                            end
                        end

                        -- Type badge
                        local memberType = nil
                        local memberAuraCfg = GetSpecAuras()[member.auraName]
                        if memberAuraCfg and memberAuraCfg.indicators then
                            for _, ind in ipairs(memberAuraCfg.indicators) do
                                if ind.id == member.indicatorID then
                                    memberType = ind.type
                                    break
                                end
                            end
                        end
                        local mBadgeColor = BADGE_COLORS[memberType or "icon"] or BADGE_COLORS.icon
                        local mBadgeLabel = PLACED_TYPE_LABELS[memberType or "icon"] or "Icon"

                        local mBadge = CreateFrame("Frame", nil, memberRow, "BackdropTemplate")
                        mBadge:SetHeight(16)
                        mBadge:SetPoint("LEFT", mSpellIcon, "RIGHT", 4, 0)
                        ApplyBackdrop(mBadge,
                            {r = mBadgeColor.r * 0.20, g = mBadgeColor.g * 0.20, b = mBadgeColor.b * 0.20, a = 1},
                            {r = mBadgeColor.r * 0.45, g = mBadgeColor.g * 0.45, b = mBadgeColor.b * 0.45, a = 0.6})
                        local mBadgeText = mBadge:CreateFontString(nil, "OVERLAY")
                        mBadgeText:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE")
                        mBadgeText:SetPoint("CENTER", 0, 0)
                        mBadgeText:SetText(mBadgeLabel)
                        mBadgeText:SetTextColor(1, 1, 1)
                        mBadge:SetWidth(max(mBadgeText:GetStringWidth() + 12, 32))

                        -- Aura name
                        local mName = memberRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                        mName:SetPoint("LEFT", mBadge, "RIGHT", 6, 0)
                        mName:SetPoint("RIGHT", memberRow, "RIGHT", -24, 0)
                        mName:SetMaxLines(1)
                        mName:SetText(displayNames[member.auraName] or member.auraName)
                        mName:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

                        -- Remove button (using close icon)
                        local remBtn = CreateFrame("Button", nil, memberRow)
                        remBtn:SetSize(18, 18)
                        remBtn:SetPoint("RIGHT", -4, 0)
                        local remIcon = remBtn:CreateTexture(nil, "OVERLAY")
                        remIcon:SetSize(12, 12)
                        remIcon:SetPoint("CENTER", 0, 0)
                        remIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\close")
                        remIcon:SetVertexColor(0.55, 0.30, 0.30, 1)
                        remBtn:SetScript("OnEnter", function()
                            remIcon:SetVertexColor(1, 0.40, 0.40, 1)
                        end)
                        remBtn:SetScript("OnLeave", function()
                            remIcon:SetVertexColor(0.55, 0.30, 0.30, 1)
                        end)
                        local capturedMember = member
                        remBtn:SetScript("OnClick", function()
                            RemoveGroupMember(capturedGroupID, capturedMember.auraName, capturedMember.indicatorID)
                            -- Also delete the placed indicator itself
                            RemoveIndicatorInstance(capturedMember.auraName, capturedMember.indicatorID)
                            SwitchTab("layout")
                            RefreshPlacedIndicators()
                            RefreshPreviewEffects()
                        end)

                        by = by - 38
                    end
                else
                    local noMem = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    noMem:SetPoint("TOPLEFT", 12, by)
                    noMem:SetText("No members yet")
                    noMem:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.6)
                    by = by - 20
                end

                -- "+ Add aura" button
                by = by - 6
                local addMemBtn = CreateFrame("Button", nil, body, "BackdropTemplate")
                addMemBtn:SetHeight(22)
                addMemBtn:SetPoint("TOPLEFT", 8, by)
                addMemBtn:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                ApplyBackdrop(addMemBtn,
                    {r = 0.10, g = 0.12, b = 0.10, a = 1},
                    {r = 0.25, g = 0.40, b = 0.25, a = 0.6})
                local addMemText = addMemBtn:CreateFontString(nil, "OVERLAY")
                addMemText:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
                addMemText:SetPoint("CENTER", 0, 0)
                addMemText:SetText("+ Add aura")
                addMemText:SetTextColor(0.5, 0.8, 0.5)
                addMemBtn:SetScript("OnEnter", function(self)
                    self:SetBackdropColor(0.15, 0.20, 0.15, 1)
                    addMemText:SetTextColor(0.7, 1.0, 0.7)
                end)
                addMemBtn:SetScript("OnLeave", function(self)
                    self:SetBackdropColor(0.10, 0.12, 0.10, 1)
                    addMemText:SetTextColor(0.5, 0.8, 0.5)
                end)
                addMemBtn:SetScript("OnClick", function()
                    -- Show ALL trackable auras with type buttons (Icon/Square/Bar)
                    local spec = ResolveSpec()
                    local auras = spec and Adapter and Adapter:GetTrackableAuras(spec)
                    if not auras or #auras == 0 then return end

                    -- Build set of auras already in this group (by auraName)
                    local grp = GetLayoutGroupByID(capturedGroupID)
                    local alreadyInGroup = {}
                    if grp and grp.members then
                        for _, m in ipairs(grp.members) do
                            alreadyInGroup[m.auraName] = true
                        end
                    end

                    -- Create/reuse dropdown
                    local dropName = "DFADGroupMemberPicker"
                    local drop = _G[dropName]
                    if not drop then
                        drop = CreateFrame("Frame", dropName, UIParent, "BackdropTemplate")
                        drop:SetFrameStrata("FULLSCREEN_DIALOG")
                        drop:SetClampedToScreen(true)
                        -- Click-outside overlay to close dropdown (#444)
                        local overlay = CreateFrame("Button", nil, UIParent)
                        overlay:SetAllPoints(UIParent)
                        overlay:SetFrameStrata("FULLSCREEN")
                        overlay:Hide()
                        overlay:SetScript("OnClick", function()
                            drop:Hide()
                            overlay:Hide()
                        end)
                        drop._overlay = overlay
                        -- ESC closes dropdown (#444)
                        drop:EnableKeyboard(true)
                        drop:SetPropagateKeyboardInput(true)
                        drop:SetScript("OnKeyDown", function(self, key)
                            if key == "ESCAPE" then
                                self:SetPropagateKeyboardInput(false)
                                self:Hide()
                            else
                                self:SetPropagateKeyboardInput(true)
                            end
                        end)
                        drop:SetScript("OnHide", function(self)
                            self._ownerBtn = nil
                            if self._overlay then self._overlay:Hide() end
                        end)
                    end
                    if drop:IsShown() and drop._ownerBtn == addMemBtn then
                        drop:Hide()
                        return
                    end
                    drop._ownerBtn = addMemBtn

                    local DROP_W = 240
                    local MAX_H = 300
                    drop:SetWidth(DROP_W)
                    ApplyBackdrop(drop, C_BACKGROUND, C_BORDER)

                    -- Inner scroll frame for long lists
                    if not drop._scrollFrame then
                        local sf = CreateFrame("ScrollFrame", nil, drop)
                        sf:SetPoint("TOPLEFT", 0, 0)
                        sf:SetPoint("BOTTOMRIGHT", 0, 0)
                        drop._scrollFrame = sf
                        local sc = CreateFrame("Frame", nil, sf)
                        sc:SetWidth(DROP_W)
                        sf:SetScrollChild(sc)
                        drop._scrollChild = sc
                        sf:SetScript("OnMouseWheel", function(self2, delta2)
                            local cur = self2:GetVerticalScroll()
                            local maxS = max(0, self2:GetVerticalScrollRange())
                            self2:SetVerticalScroll(max(0, min(maxS, cur - (delta2 * 24))))
                        end)
                    end
                    local scrollChild = drop._scrollChild
                    local scrollFrame = drop._scrollFrame
                    scrollChild:SetWidth(DROP_W)
                    -- Clear old children
                    for _, child in ipairs({scrollChild:GetChildren()}) do child:Hide(); child:SetParent(nil) end
                    for _, rgn in ipairs({scrollChild:GetRegions()}) do
                        if rgn:GetObjectType() == "FontString" or rgn:GetObjectType() == "Texture" then rgn:Hide() end
                    end
                    scrollFrame:Show()
                    -- Forward mouse wheel from scroll child to scroll frame
                    scrollChild:EnableMouseWheel(true)
                    scrollChild:SetScript("OnMouseWheel", function(_, delta2)
                        scrollFrame:GetScript("OnMouseWheel")(scrollFrame, delta2)
                    end)

                    local dy2 = -4
                    for _, auraInfo in ipairs(auras) do
                        local isExisting = alreadyInGroup[auraInfo.name]
                        local ROW_H = 24
                        local row = CreateFrame("Frame", nil, scrollChild)
                        row:SetHeight(ROW_H)
                        row:SetPoint("TOPLEFT", 4, dy2)
                        row:SetPoint("RIGHT", scrollChild, "RIGHT", -4, 0)

                        -- Color dot
                        local dot = row:CreateTexture(nil, "ARTWORK")
                        dot:SetSize(6, 6)
                        dot:SetPoint("LEFT", 4, 0)
                        dot:SetColorTexture(auraInfo.color[1], auraInfo.color[2], auraInfo.color[3], 1)

                        -- Aura name
                        local rName = row:CreateFontString(nil, "OVERLAY")
                        rName:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
                        rName:SetPoint("LEFT", dot, "RIGHT", 6, 0)
                        rName:SetText(auraInfo.display)

                        if isExisting then
                            rName:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.5)
                            dot:SetAlpha(0.4)
                        else
                            rName:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

                            -- Type buttons (Icon / Square only — bars not supported in layout groups)
                            local PLACED_TYPES = { "icon", "square" }
                            local btnX = -4
                            for ti = #PLACED_TYPES, 1, -1 do
                                local typeKey = PLACED_TYPES[ti]
                                local bc = BADGE_COLORS[typeKey] or BADGE_COLORS.icon
                                local typeLbl = PLACED_TYPE_LABELS[typeKey] or typeKey

                                local typeBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
                                typeBtn:SetSize(36, 16)
                                typeBtn:SetPoint("RIGHT", row, "RIGHT", btnX, 0)
                                ApplyBackdrop(typeBtn,
                                    {r = bc.r * 0.15, g = bc.g * 0.15, b = bc.b * 0.15, a = 1},
                                    {r = bc.r * 0.4, g = bc.g * 0.4, b = bc.b * 0.4, a = 0.6})

                                local tLbl = typeBtn:CreateFontString(nil, "OVERLAY")
                                tLbl:SetFont("Fonts\\FRIZQT__.TTF", 7.5, "OUTLINE")
                                tLbl:SetPoint("CENTER", 0, 0)
                                tLbl:SetText(typeLbl)
                                tLbl:SetTextColor(bc.r, bc.g, bc.b)

                                typeBtn:SetScript("OnEnter", function(self)
                                    self:SetBackdropBorderColor(bc.r, bc.g, bc.b, 1)
                                    tLbl:SetTextColor(1, 1, 1)
                                end)
                                typeBtn:SetScript("OnLeave", function(self)
                                    self:SetBackdropBorderColor(bc.r * 0.4, bc.g * 0.4, bc.b * 0.4, 0.6)
                                    tLbl:SetTextColor(bc.r, bc.g, bc.b)
                                end)

                                local capturedAuraName = auraInfo.name
                                local capturedTypeKey = typeKey
                                typeBtn:SetScript("OnClick", function()
                                    -- Create placed indicator for this aura+type if needed
                                    local instance = CreateIndicatorInstance(capturedAuraName, capturedTypeKey)
                                    if instance then
                                        AddGroupMember(capturedGroupID, capturedAuraName, instance.id)
                                    end
                                    drop:Hide()
                                    SwitchTab("layout")
                                    RefreshPlacedIndicators()
                                end)

                                btnX = btnX - 40
                            end

                            -- Row highlight
                            local hl = row:CreateTexture(nil, "BACKGROUND")
                            hl:SetAllPoints()
                            hl:SetColorTexture(1, 1, 1, 0)
                            row:SetScript("OnEnter", function() hl:SetColorTexture(1, 1, 1, 0.03) end)
                            row:SetScript("OnLeave", function() hl:SetColorTexture(1, 1, 1, 0) end)
                        end
                        dy2 = dy2 - ROW_H
                    end
                    local totalH = -dy2 + 4
                    scrollChild:SetHeight(totalH)
                    drop:SetHeight(math.min(totalH, MAX_H))

                    drop:ClearAllPoints()
                    drop:SetPoint("TOPLEFT", addMemBtn, "BOTTOMLEFT", 0, -2)
                    drop:Show()
                    if drop._overlay then drop._overlay:Show() end
                end)
                by = by - 28

                -- ── PLACEMENT SECTION ──
                by = by - 10
                local placeLabel = body:CreateFontString(nil, "OVERLAY")
                placeLabel:SetFont("Fonts\\FRIZQT__.TTF", 8, "")
                placeLabel:SetPoint("TOPLEFT", 8, by)
                placeLabel:SetText("PLACEMENT")
                placeLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 18

                -- Use GUI widgets with the group table as the proxy
                local anchorDrop = GUI:CreateDropdown(body, "Anchor", ANCHOR_OPTIONS, group, "anchor", function()
                    RefreshPlacedIndicators()
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end)
                anchorDrop:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                if anchorDrop.SetWidth then anchorDrop:SetWidth(bodyWidth - 10) end
                by = by - 54

                local oxSlider = GUI:CreateSlider(body, "Offset X", -50, 50, 1, group, "offsetX", function()
                    RefreshPlacedIndicators()
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end, function()
                    RefreshPlacedIndicators()
                end)
                oxSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                if oxSlider.SetWidth then oxSlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                local oySlider = GUI:CreateSlider(body, "Offset Y", -50, 50, 1, group, "offsetY", function()
                    RefreshPlacedIndicators()
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end, function()
                    RefreshPlacedIndicators()
                end)
                oySlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                if oySlider.SetWidth then oySlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                -- ── GROWTH SECTION ──
                by = by - 10
                local growLabel = body:CreateFontString(nil, "OVERLAY")
                growLabel:SetFont("Fonts\\FRIZQT__.TTF", 8, "")
                growLabel:SetPoint("TOPLEFT", 8, by)
                growLabel:SetText("GROWTH")
                growLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 18

                local dirDrop = GUI:CreateDropdown(body, "Grow Direction", GROW_DIRECTIONS, group, "growDirection", function()
                    RefreshPlacedIndicators()
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end)
                dirDrop:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                if dirDrop.SetWidth then dirDrop:SetWidth(bodyWidth - 10) end
                by = by - 54

                local spacingSlider = GUI:CreateSlider(body, "Spacing", 0, 20, 1, group, "spacing", function()
                    RefreshPlacedIndicators()
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end, function()
                    RefreshPlacedIndicators()
                end)
                spacingSlider:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(-by))
                if spacingSlider.SetWidth then spacingSlider:SetWidth(bodyWidth - 10) end
                by = by - 54

                local bodyH = -by + 12
                body:SetHeight(bodyH)
                totalCardH = totalCardH + bodyH
            end

            card:SetHeight(totalCardH)
            yPos = yPos - totalCardH - 5
        end
    end

    parent:SetHeight(max(-yPos + 20, 200))
end

-- ============================================================
-- MAIN PAGE BUILD
-- ============================================================

function DF.BuildAuraDesignerPage(guiRef, pageRef, dbRef)
    local prevDB = db  -- capture before overwrite to detect mode switch
    GUI = guiRef
    page = pageRef
    db = dbRef
    Adapter = DF.AuraDesigner.Adapter

    local parent = page.child

    -- ========================================
    -- REUSE: If mainFrame already exists and db hasn't changed (same mode),
    -- just re-parent, show, and refresh. Avoids full teardown on resize.
    -- A mode switch (Party↔Raid) changes db, so we must rebuild in that case.
    -- ========================================
    if mainFrame and prevDB == dbRef then
        mainFrame:SetParent(parent)
        mainFrame:SetAllPoints()
        mainFrame:Show()
        DF:AuraDesigner_RefreshPage()
        return
    end

    -- Full build (first time, or mode switch)
    if mainFrame then
        mainFrame:Hide()
        mainFrame:SetParent(nil)
    end
    wipe(placedIndicators)
    wipe(expandedCards)
    wipe(effectCardPool)

    activeTab = "effects"
    activeFilter = "all"
    spellPickerActive = false
    spellPickerType = nil

    -- Layout constants
    local BANNER_H = 36
    local SECTION_GAP = 8

    -- ========================================
    -- MAIN FRAME
    -- ========================================
    mainFrame = CreateFrame("Frame", nil, parent)
    mainFrame:SetAllPoints()

    -- Override RefreshStates: Aura Designer uses its own layout system
    page.RefreshStates = function(self)
        local pageH = self:GetHeight()
        self.child:SetHeight(math.max(pageH, 600))
        if self.child and GUI.contentFrame then
            self.child:SetWidth(GUI.contentFrame:GetWidth() - 30)
        end
        DF:AuraDesigner_RefreshPage()
    end

    local yPos = 0

    -- ========================================
    -- ENABLE BANNER (full width)
    -- ========================================
    enableBanner = CreateEnableBanner(mainFrame)
    enableBanner:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, yPos)
    enableBanner:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, yPos)
    enableBanner.UpdateSpecText()

    if GUI.CreateCopyButton then
        local copyBtn = GUI.CreateCopyButton(enableBanner, {"auraDesigner"}, "Aura Designer", "auras_auradesigner")
        copyBtn:ClearAllPoints()
        copyBtn:SetPoint("RIGHT", enableBanner, "RIGHT", -5, 0)
        enableBanner.specBtn:SetSize(135, 22)
        enableBanner.specBtn:ClearAllPoints()
        enableBanner.specBtn:SetPoint("RIGHT", enableBanner, "RIGHT", -256, 0)
        enableBanner.specLabel:ClearAllPoints()
        enableBanner.specLabel:SetPoint("RIGHT", enableBanner.specBtn, "LEFT", -4, 0)
    end

    yPos = yPos - (BANNER_H + 4)

    -- ========================================
    -- COEXISTENCE INFO BANNER
    -- ========================================
    contentBaseY = yPos
    coexistBanner = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
    coexistBanner:SetHeight(COEXIST_BANNER_H)
    coexistBanner:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, yPos)
    coexistBanner:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, yPos)
    ApplyBackdrop(coexistBanner, {r = 0.14, g = 0.14, b = 0.14, a = 1}, {r = 0.30, g = 0.30, b = 0.30, a = 0.5})

    local coexistText = coexistBanner:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    coexistText:SetPoint("LEFT", 10, 0)
    coexistText:SetText("Standard Buffs are also visible on frames.")
    coexistText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    local tc = GetThemeColor()
    local disableBuffsBtn = CreateFrame("Button", nil, coexistBanner)
    disableBuffsBtn:SetSize(90, 18)
    disableBuffsBtn:SetPoint("LEFT", coexistText, "RIGHT", 8, 0)
    disableBuffsBtn.text = disableBuffsBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    disableBuffsBtn.text:SetAllPoints()
    disableBuffsBtn.text:SetText("Disable Buffs")
    disableBuffsBtn.text:SetTextColor(tc.r, tc.g, tc.b)
    disableBuffsBtn:SetScript("OnEnter", function(self) self.text:SetTextColor(1, 1, 1) end)
    disableBuffsBtn:SetScript("OnLeave", function(self)
        local tc2 = GetThemeColor()
        self.text:SetTextColor(tc2.r, tc2.g, tc2.b)
    end)
    disableBuffsBtn:SetScript("OnClick", function()
        db.showBuffs = false
        DF:AuraDesigner_RefreshPage()
        DF:InvalidateAuraLayout()
        DF:UpdateAllFrames()
        local buffsPage = GUI and GUI.Pages and GUI.Pages["auras_buffs"]
        if buffsPage and buffsPage.RefreshStates then buffsPage:RefreshStates() end
    end)
    coexistBanner:Hide()

    -- ========================================
    -- 50/50 SPLIT: LEFT PANEL + RIGHT PANEL
    -- ========================================
    local splitContainer = CreateFrame("Frame", nil, mainFrame)
    splitContainer:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, yPos)
    splitContainer:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, 0)
    mainFrame.splitContainer = splitContainer

    -- ── LEFT PANEL (frame preview) ──
    leftPanel = CreateFrame("Frame", nil, splitContainer, "BackdropTemplate")
    leftPanel:SetPoint("TOPLEFT", 0, 0)
    leftPanel:SetPoint("BOTTOMLEFT", 0, 0)
    leftPanel:SetPoint("RIGHT", splitContainer, "CENTER", -2, 0)
    ApplyBackdrop(leftPanel, C_PANEL, C_BORDER)

    -- Frame preview (reuses existing CreateFramePreview with adapted anchoring)
    origY_framePreview = 0
    framePreview = CreateFramePreview(leftPanel, 0, nil)
    contentRightInset = 0  -- No right inset needed in new layout

    -- ── RIGHT PANEL (tabbed settings) ──
    rightPanel = CreateFrame("Frame", nil, splitContainer, "BackdropTemplate")
    rightPanel:SetPoint("TOPRIGHT", 0, 0)
    rightPanel:SetPoint("BOTTOMRIGHT", 0, 0)
    rightPanel:SetPoint("LEFT", splitContainer, "CENTER", 2, 0)
    ApplyBackdrop(rightPanel, {r = 0.10, g = 0.10, b = 0.10, a = 1}, {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5})

    -- ── TAB BAR ──
    tabBar = CreateFrame("Frame", nil, rightPanel, "BackdropTemplate")
    tabBar:SetHeight(28)
    tabBar:SetPoint("TOPLEFT", 0, 0)
    tabBar:SetPoint("TOPRIGHT", 0, 0)
    ApplyBackdrop(tabBar, {r = 0.09, g = 0.09, b = 0.09, a = 1}, {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5})

    local TAB_DEFS = {
        { key = "effects", label = "Effects",        color = GetThemeColor() },
        { key = "layout",  label = "Layout Groups",  color = { r = 0.91, g = 0.66, b = 0.25 } },
        { key = "global",  label = "Global",         color = { r = 0.51, g = 0.86, b = 0.51 } },
    }

    wipe(tabButtons)
    for i, def in ipairs(TAB_DEFS) do
        local btn = CreateFrame("Button", nil, tabBar)
        btn:SetHeight(28)
        if i == 1 then
            btn:SetPoint("TOPLEFT", 0, 0)
        else
            btn:SetPoint("TOPLEFT", tabButtons[TAB_DEFS[i-1].key], "TOPRIGHT", 0, 0)
        end
        btn:SetWidth(tabBar:GetWidth() / #TAB_DEFS)  -- Equal width

        -- Bottom accent line
        btn.accent = btn:CreateTexture(nil, "OVERLAY")
        btn.accent:SetHeight(2)
        btn.accent:SetPoint("BOTTOMLEFT", 0, 0)
        btn.accent:SetPoint("BOTTOMRIGHT", 0, 0)
        btn.accent:SetColorTexture(def.color.r, def.color.g, def.color.b, 1)
        btn.accent:Hide()

        btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        btn.label:SetPoint("CENTER", 0, 1)
        btn.label:SetText(def.label)
        btn.label:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

        -- Highlight
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.03)

        btn.tabKey = def.key
        btn.tabColor = def.color
        btn:SetScript("OnClick", function(self)
            SwitchTab(self.tabKey)
        end)

        tabButtons[def.key] = btn
    end

    -- Make tab buttons equal width on parent resize
    tabBar:SetScript("OnSizeChanged", function(self, w, h)
        local tabW = w / #TAB_DEFS
        for _, def in ipairs(TAB_DEFS) do
            local btn = tabButtons[def.key]
            if btn then btn:SetWidth(tabW) end
        end
    end)

    -- ── TAB CONTENT (scrollable) ──
    tabScrollFrame = CreateFrame("ScrollFrame", nil, rightPanel, "UIPanelScrollFrameTemplate")
    tabScrollFrame:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, 0)
    tabScrollFrame:SetPoint("BOTTOMRIGHT", -22, 0)

    tabContentFrame = CreateFrame("Frame", nil, tabScrollFrame)
    -- Pre-compute initial width from parent geometry so SwitchTab() has
    -- accurate dimensions before the first layout pass fires OnSizeChanged.
    local earlyW = parent:GetWidth()
    if earlyW < 100 then earlyW = (GUI.contentFrame and GUI.contentFrame:GetWidth() or 600) - 30 end
    tabContentFrame:SetWidth(max(1, (earlyW / 2) - 2 - 22))
    tabContentFrame:SetHeight(800)
    tabScrollFrame:SetScrollChild(tabContentFrame)

    -- Match scroll child width to scroll frame
    tabScrollFrame:SetScript("OnSizeChanged", function(self, w, h)
        tabContentFrame:SetWidth(w)
    end)

    local scrollBar = tabScrollFrame.ScrollBar
    if scrollBar then
        scrollBar:ClearAllPoints()
        scrollBar:SetPoint("TOPLEFT", tabScrollFrame, "TOPRIGHT", 2, -16)
        scrollBar:SetPoint("BOTTOMLEFT", tabScrollFrame, "BOTTOMRIGHT", 2, 16)
    end

    -- Smooth scroll
    local SCROLL_STEP = 30
    tabScrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local maxScroll = max(0, self:GetVerticalScrollRange())
        local newScroll = max(0, min(maxScroll, current - (delta * SCROLL_STEP)))
        self:SetVerticalScroll(newScroll)
    end)
    tabContentFrame:EnableMouseWheel(true)
    tabContentFrame:SetScript("OnMouseWheel", function(self, delta)
        local p = self:GetParent()
        if p and p:GetScript("OnMouseWheel") then
            p:GetScript("OnMouseWheel")(p, delta)
        end
    end)

    -- ── SPELL PICKER VIEW (hidden by default, overlays tabs when active) ──
    spellPickerView = CreateFrame("Frame", nil, rightPanel, "BackdropTemplate")
    spellPickerView:SetPoint("TOPLEFT", 0, 0)
    spellPickerView:SetPoint("BOTTOMRIGHT", 0, 0)
    ApplyBackdrop(spellPickerView, {r = 0.10, g = 0.10, b = 0.10, a = 1}, {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5})
    spellPickerView:Hide()

    -- Spell picker header
    local pickerHeader = CreateFrame("Frame", nil, spellPickerView, "BackdropTemplate")
    pickerHeader:SetHeight(28)
    pickerHeader:SetPoint("TOPLEFT", 0, 0)
    pickerHeader:SetPoint("TOPRIGHT", 0, 0)
    ApplyBackdrop(pickerHeader, {r = 0.09, g = 0.09, b = 0.09, a = 1}, {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5})

    local backBtn = CreateFrame("Button", nil, pickerHeader)
    backBtn:SetSize(24, 24)
    backBtn:SetPoint("LEFT", 4, 0)
    backBtn.icon = backBtn:CreateTexture(nil, "OVERLAY")
    backBtn.icon:SetSize(14, 14)
    backBtn.icon:SetPoint("CENTER", 0, 0)
    backBtn.icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
    backBtn.icon:SetRotation(math.rad(180))  -- flip to point left
    backBtn.icon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    backBtn:SetScript("OnClick", function() HideSpellPicker() end)
    backBtn:SetScript("OnEnter", function(self) self.icon:SetVertexColor(1, 1, 1) end)
    backBtn:SetScript("OnLeave", function(self) self.icon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b) end)

    spellPickerView.title = pickerHeader:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    spellPickerView.title:SetPoint("LEFT", backBtn, "RIGHT", 4, 0)
    spellPickerView.title:SetText("Select a spell")
    spellPickerView.title:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    spellPickerView.typeBadge = pickerHeader:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    spellPickerView.typeBadge:SetPoint("LEFT", spellPickerView.title, "RIGHT", 6, 0)

    -- Spell picker hint
    local pickerHint = spellPickerView:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pickerHint:SetPoint("TOPLEFT", pickerHeader, "BOTTOMLEFT", 12, -8)
    pickerHint:SetText("Click a spell to place it on the frame")
    pickerHint:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    -- Spell picker scroll frame for the grid
    local pickerScroll = CreateFrame("ScrollFrame", nil, spellPickerView, "UIPanelScrollFrameTemplate")
    pickerScroll:SetPoint("TOPLEFT", pickerHeader, "BOTTOMLEFT", 0, -24)
    pickerScroll:SetPoint("BOTTOMRIGHT", -22, 0)

    spellPickerView.gridFrame = CreateFrame("Frame", nil, pickerScroll)
    spellPickerView.gridFrame:SetWidth(1)
    spellPickerView.gridFrame:SetHeight(400)
    pickerScroll:SetScrollChild(spellPickerView.gridFrame)

    pickerScroll:SetScript("OnSizeChanged", function(self, w, h)
        spellPickerView.gridFrame:SetWidth(w)
    end)

    local pickerScrollBar = pickerScroll.ScrollBar
    if pickerScrollBar then
        pickerScrollBar:ClearAllPoints()
        pickerScrollBar:SetPoint("TOPLEFT", pickerScroll, "TOPRIGHT", 2, -16)
        pickerScrollBar:SetPoint("BOTTOMLEFT", pickerScroll, "BOTTOMRIGHT", 2, 16)
    end

    spellPickerView.scrollFrame = pickerScroll

    -- ========================================
    -- POPULATE (new UI)
    -- ========================================

    -- Force initial width sync: OnSizeChanged won't fire until the frame renders,
    -- but SwitchTab needs accurate widths now for slider/dropdown sizing.
    -- Compute initial scroll content width from parent geometry.
    -- rightPanel:GetWidth() returns 0 before the first layout pass, so we
    -- calculate from the parent which already has valid geometry on a mode
    -- switch (Party↔Raid).
    local parentW = parent:GetWidth()
    if parentW < 100 then parentW = (GUI.contentFrame and GUI.contentFrame:GetWidth() or 600) - 30 end
    local initW = (parentW / 2) - 2 - 22  -- half split minus gap minus scrollbar
    if initW > 50 then
        tabContentFrame:SetWidth(initW)
    end

    SwitchTab("effects")
    RefreshPlacedIndicators()
    RefreshPreviewEffects()
end

-- ============================================================
-- REFRESH
-- ============================================================

function DF:AuraDesigner_RefreshPage()
    if not mainFrame then return end

    -- Check if spec changed
    local currentSpec = ResolveSpec()
    if currentSpec ~= selectedSpec then
        selectedSpec = currentSpec
    end

    -- Rebuild the current tab to reflect data changes
    if activeTab and SwitchTab then
        SwitchTab(activeTab)
    end

    -- Refresh frame preview
    RefreshPlacedIndicators()
    RefreshPreviewEffects()

    -- Update enable state
    if enableBanner then
        enableBanner.checkbox:SetChecked(GetAuraDesignerDB().enabled)
        enableBanner.UpdateSpecText()
    end

    -- Show/hide coexistence banner and reposition content panels
    if coexistBanner and contentBaseY then
        local adEnabled = GetAuraDesignerDB().enabled
        local showBuffs = db and db.showBuffs
        local bannerVisible = adEnabled and showBuffs
        if bannerVisible then
            coexistBanner:Show()
        else
            coexistBanner:Hide()
        end

        -- Shift the split container when banner is visible
        local newShift = bannerVisible and (COEXIST_BANNER_H + COEXIST_GAP) or 0
        if newShift ~= currentBannerShift then
            currentBannerShift = newShift
            local delta = -newShift
            if mainFrame.splitContainer then
                mainFrame.splitContainer:ClearAllPoints()
                mainFrame.splitContainer:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, contentBaseY + delta)
                mainFrame.splitContainer:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, 0)
            end
        end
    end

    -- Refresh buffs tab banner state if visible
    local buffsPage = GUI and GUI.Pages and GUI.Pages["auras_buffs"]
    if buffsPage and buffsPage.RefreshStates then
        buffsPage:RefreshStates()
    end
end

-- ============================================================
-- TAB DISABLE STATE
-- Standalone function so it can be called from GUI.lua on open
-- and from RefreshPage when the enable checkbox toggles.
-- ============================================================

-- Disable the My Buff Indicators tab when AD is enabled (never compatible).
-- Buffs tab is always accessible — it can coexist with AD.
function DF:ApplyAuraDesignerTabState()
    local guiRef = DF.GUI
    if not guiRef or not guiRef.Tabs then return end
    if not DF.db then return end

    local mode = (guiRef.SelectedMode) or "party"
    local modeDB = DF:GetDB(mode)
    local adEnabled = modeDB and modeDB.auraDesigner and modeDB.auraDesigner.enabled

    -- My Buff Indicators tab removed — feature deprecated
end
